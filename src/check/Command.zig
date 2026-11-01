//! `beni check [--platform=<name>] <path>...` (docs/design/frontend.md §1,
//! checker.md §2): parse, lower, resolve and type-check every module, report
//! diagnostics, write nothing.
//!
//! **`--platform` is not `build`'s alone** (boundary.md §5.3). Until this
//! command took it, `check` could not be pointed at any program that imports
//! its platform for `Program` — which is every program — so the one command
//! an editor, a pre-commit hook, CI, the daemon and an LSP all run did not
//! exist for real code. The flag resolves exactly as `build`'s does, through
//! `platform.zig`, so the two commands cannot disagree about what a platform
//! is.
//!
//! It is **not required** the way `build` requires it: a library, a single
//! module, or anything importing only core must stay checkable with no flag.
//! What a platform adds is the package in the import search path and
//! boundary.md §4's four sibling checks; what it does NOT add is the
//! entry-point search, because a build is a pair of ONE entry point and ONE
//! platform while `check` is handed whatever paths it is handed.
//!
//! Exit codes are `frontend.md` §1's: 0 no errors, 1 at least one error
//! diagnostic, 2 a usage or I/O failure. stdout carries the product, and a
//! check has none.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Cli = @import("../Cli.zig");
const Session = @import("../Session.zig");
const Emit = @import("../js/Emit.zig");
const platform = @import("../platform.zig");
const iface_bytes = @import("../resolve/iface_bytes.zig");
const Key = @import("../cache/Key.zig");
const CacheDir = @import("../cache/Dir.zig");
const Digest = @import("../cache/Digest.zig");
const TypeKeysDump = @import("../dump/typekeys.zig");
const ContinuationsDump = @import("../dump/continuations.zig");
const EntriesDump = @import("../dump/entries.zig");
const Controls = @import("../dump/checked_controls.zig");

pub fn run(gpa: Allocator, io: Io, stdout: *Io.Writer, stderr: *Io.Writer, options_in: Session.Options, check: Cli.Check) u8 {
    var options = options_in;
    // A package may declare itself a platform (boundary.md §2), and then
    // `foreign` is legal in it. `check` has to honour that or a platform
    // package could not be checked at all.
    options.manifest_root = check.common.root orelse ".";
    // `check` resolves names across modules, and every module resolves
    // against core (checker.md §4): the package is part of the input.
    options.core_package = true;
    options.checked_controls = check.cache.checked_controls;
    options.native_realms = check.cache.entries;
    options.prepare_native_emission = check.platform != null;
    if (options.checked_controls) {
        options.ownership = true;
        options.ownership_everywhere = true;
        if (options.ownership_v2) options.ownership_v2_dump = .{ .summaries = true };
    }
    // `check` and `build` are the two subcommands that emit the
    // informational warnings of static-dispatch-spike.md §10 (A.83); a
    // `dump` or a `fmt` of the same file stays silent about them.
    options.informational = true;
    options.explain = check.common.explain;
    options.platform = check.platform;
    options.cache_build_id = check.cache.build_id;
    options.frontend_keys = check.cache.frontend_keys;
    options.cutoff_compare = check.cache.cutoff_compare;

    // The cache directory is opened HERE and not inside the session, because
    // the one failure a cache is allowed to have is a usage failure and the
    // command owns every usage message (`frontend.md` §1: created if it is
    // missing, and a failure to create it is 2 with the path named).
    var cache_failure: ?CacheDir.Failure = null;
    var cache: ?CacheDir = CacheDir.fromCli(io, check.cache, &cache_failure) catch {
        const f = cache_failure.?;
        return fail(stderr, "beni: cannot write '{s}': {t}", .{ f.path, f.err });
    };
    defer if (cache) |*c| c.close();
    if (cache) |*c| if (check.common.ownership_everywhere) c.into("ownership-everywhere", &cache_failure) catch {
        const f = cache_failure.?;
        return fail(stderr, "beni: cannot write '{s}': {t}", .{ f.path, f.err });
    };
    if (cache) |*c| options.cache = c;
    // With a platform there is a SECOND wave of diagnostics — §4's checks
    // run after `run` returns — and two renders on one stream are two JSON
    // arrays, which is not the format (§1.1). Without one there is no second
    // wave and `run` renders as it always has.
    options.defer_render = check.platform != null or check.cache.checked_controls;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The platform chain, read before any source is, exactly as `build`
    // reads it (`boundary.md` §9.1).
    var chain_failure: ?platform.Failure = null;
    const chain: ?platform.Chain = if (check.platform) |requested|
        platform.resolveChain(arena, io, requested, &chain_failure) catch |err| switch (err) {
            error.OutOfMemory => return fail(stderr, "beni: out of memory", .{}),
            error.Failed => return platform.report(stderr, chain_failure.?),
        }
    else
        null;
    if (chain) |*c| options.chain = c;
    // `ownership-checker.md` §28.3: the pass runs when the chain edits
    // lists in place, and not otherwise.
    options.ownership = true;

    var session = Session.init(gpa, io, options) catch return fail(stderr, "beni: out of memory", .{});
    defer session.deinit();

    const summary = session.run(check.paths, Session.check_phases, stderr) catch |err| switch (err) {
        error.InputPath => {
            const failure = session.io_failure.?;
            return fail(stderr, "beni: cannot read '{s}': {t}", .{ failure.path, failure.err });
        },
        else => |e| return fail(stderr, "beni: {t}", .{e}),
    };
    // Before the exit-code branch below, so a project with errors still
    // reports the hashes of the modules that do have an interface: the
    // firewall's question is "did this module's public face move?", and a
    // module whose dependent failed to compile still has one.
    if (check.common.iface_hash) {
        printInterfaceHashes(gpa, stdout, &session) catch return fail(stderr, "beni: out of memory", .{});
    }
    // Before the exit-code branch for `--iface-hash`'s reason: an edit
    // scenario asks "which modules did this change reach?", and a project
    // that does not compile has keys all the same.
    if (check.cache.keys) {
        printCacheKeys(gpa, stdout, &session) catch return fail(stderr, "beni: out of memory", .{});
    }
    // Before the exit-code branch for the same reason, and AFTER the module
    // keys so a fixture that passes both reads one block then the other.
    if (check.cache.frontend_keys) {
        printFrontendKeys(stdout, &session) catch return fail(stderr, "beni: out of memory", .{});
    }
    // Before the exit-code branch for `--iface-hash`'s reason, and after it in
    // the stream because the two are read as a pair: the hash is what a module
    // publishes and the digest is what its dependents read.
    if (check.cache.dep_digest) {
        printDependencyDigests(gpa, stdout, &session) catch return fail(stderr, "beni: out of memory", .{});
    }
    // Last, so a fixture that passes several flags reads the blocks in the
    // order the flags are documented in.
    if (check.cache.cutoff_compare) {
        printCompareKeys(gpa, stdout, &session) catch return fail(stderr, "beni: out of memory", .{});
    }
    // After the key blocks, for the same reason.
    if (check.cache.type_keys) {
        printTypeKeys(stdout, &session) catch return 2;
    }
    if (check.cache.continuations) {
        printContinuations(stdout, &session) catch return 2;
    }
    if (summary.errors > 0) {
        _ = session.renderLate(&.{}, stderr) catch return 2;
        return 1;
    }
    var prepared: ?Controls.Prepared = null;
    defer if (prepared) |*product| product.deinit(gpa);
    if (check.cache.checked_controls) {
        const tamper: @import("ControlBuild.zig").Tamper = if (check.cache.checked_controls_tamper) |t| (if (std.mem.eql(u8, t, "wrong-input-slot")) .wrong_input_slot else if (std.mem.eql(u8, t, "direct-input")) .direct_input else if (std.mem.eql(u8, t, "parked-input")) .parked_input else if (std.mem.eql(u8, t, "wrong-slot")) .wrong_slot else if (std.mem.eql(u8, t, "same-type-operand")) .same_type_operand else if (std.mem.eql(u8, t, "scaffold-return-slot")) .scaffold_return_slot else if (std.mem.eql(u8, t, "drop-region")) .drop_region else if (std.mem.eql(u8, t, "ownership-conflict")) .ownership_conflict else if (std.mem.eql(u8, t, "suspending-job")) .suspending_job else .duplicate_region) else .none;
        var failure_reported = false;
        prepared = Controls.prepare(gpa, arena, io, &session, tamper, stderr, &failure_reported) catch |err|
            return reportControlFailure(&session, err, failure_reported, stderr);
        session.foreign = prepared.?.foreign;
    }
    const requested = check.platform orelse {
        if (check.cache.entries) return fail(stderr, "beni: --entries requires --platform", .{});
        if (check.cache.checked_controls) {
            const errors = session.renderLate(&.{}, stderr) catch return 2;
            if (errors != 0) return 1;
        }
        if (prepared) |product| stdout.writeAll(product.bytes) catch return 2;
        return 0;
    };

    // The chain's output shape, which `check` needs for the checks of the
    // platform's own declarations and never for `main`: a platform that
    // declares no `program` is checked like any other.
    const loaded = platform.load(arena, &session, &chain.?, false) catch |err|
        return platform.reportLoad(stderr, requested, err);

    const inspect: *const @TypeOf(Emit.checkContract) = if (check.cache.entries) EntriesDump.inspect else Emit.checkContract;
    const items = inspect(gpa, arena, &session, .{
        .out_dir = &.{}, // nothing is written; the field is `run`'s
        .platform = loaded.platform,
        .embedded = loaded.embedded,
    }) catch {
        if (check.cache.entries) _ = EntriesDump.flushProfile(&session, stderr);
        return fail(stderr, "beni: out of memory", .{});
    };
    defer {
        for (items) |item| gpa.free(item.message);
        gpa.free(items);
    }

    // The one render of the stream: §4's diagnostics and the `warning`s
    // `run` held back, sorted together into one array. Called even when the
    // checks said nothing, because the held-back wave still has to reach the
    // author.
    const late = gpa.alloc(Session.LateItem, items.len) catch {
        if (check.cache.entries) _ = EntriesDump.flushProfile(&session, stderr);
        return fail(stderr, "beni: out of memory", .{});
    };
    defer gpa.free(late);
    for (items, late) |item, *slot| {
        slot.* = .{ .code = item.code, .file = item.file, .token = item.token, .end_token = item.end_token, .message = item.message, .at = item.at, .severity = item.severity };
    }
    const errors = session.renderLate(late, stderr) catch {
        if (check.cache.entries) _ = EntriesDump.flushProfile(&session, stderr);
        return 2;
    };
    if (errors != 0) {
        if (check.cache.entries and !EntriesDump.flushProfile(&session, stderr)) return 2;
        return 1;
    }
    if (check.cache.entries) {
        EntriesDump.write(stdout, &session) catch {
            _ = EntriesDump.flushProfile(&session, stderr);
            return 2;
        };
        if (!EntriesDump.flushProfile(&session, stderr)) return 2;
    }
    if (prepared) |product| stdout.writeAll(product.bytes) catch return 2;
    return 0;
}

fn controlFailureExit(err: Controls.Error) u8 {
    return switch (err) {
        error.MissingEvidence, error.InvalidControlProvenance, error.GeneratedCheckFailed, error.MissingGeneratedRoot, error.InvalidRuntimeSource => 1,
        else => 2, // usage, allocator, input, thread and writer failures
    };
}

fn reportControlFailure(session: *Session, err: Controls.Error, reported: bool, stderr: *Io.Writer) u8 {
    const exit = controlFailureExit(err);
    if (reported or err == error.WriteFailed) return exit;
    var message: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&message, "Checked-control preparation failed ({s}). No checked-control receipt was printed.", .{@errorName(err)}) catch return 2;
    _ = session.renderLate(&.{.{ .code = .internal, .file = @fromBackingInt(0), .token = 0, .message = text, .at = .{ .path = "<checked-controls>" } }}, stderr) catch return 2;
    return exit;
}

/// `--iface-hash`: one `<package>:<Module> <32 hex digits>` line per module
/// on stdout, `core` and the platform included, sorted by that key
/// (`fast-compiler.md` §8's *The interface hash*).
///
/// **Why it exists at all**: `dump --stage=raw` prints only the modules
/// named on the command line, so core's and the platform's records are
/// invisible to it — and the firewall's quantity is "did this record
/// change?", which is a hash and not a dump.
///
/// The package is part of the key because a module's identity is
/// `(package, name)` and not the name alone (`Graph`'s header), and the
/// sort is on the key's TEXT — a function of the sources, like every other
/// order in this slice, and never of `--jobs`.
fn printInterfaceHashes(gpa: Allocator, stdout: *Io.Writer, session: *Session) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Line = struct {
        key: []const u8,
        digits: [32]u8,

        fn lessThan(_: void, a: @This(), b: @This()) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    };
    const lines = try arena.alloc(Line, session.graph.count());
    for (lines, 0..) |*line, i| {
        const m: @TypeOf(session.graph).Index = @fromBackingInt(@intCast(i));
        const file = session.graph.moduleFile(m);
        const iface = &session.resolution.interfaces[i];
        const bytes = try iface_bytes.write(gpa, iface, &session.interner);
        defer gpa.free(bytes);
        line.* = .{
            .key = try std.fmt.allocPrint(arena, "{t}:{s}", .{
                session.store.package(file),
                session.interner.slice(session.graph.moduleName(m)),
            }),
            .digits = iface_bytes.hashHex(iface_bytes.hash(bytes)),
        };
    }
    std.mem.sort(Line, lines, {}, Line.lessThan);
    for (lines) |line| try stdout.print("{s} {s}\n", .{ line.key, &line.digits });
    try stdout.flush();
}

/// `--cache-keys`: one `<package>:<Module> <32 hex digits>` line per module
/// on stdout, sorted by that key (`fast-compiler.md` §8, `frontend.md` §1).
///
/// `--iface-hash`'s twin, and deliberately the same shape, because the two
/// answer the two halves of the same question: the hash says whether a
/// module's public face moved, and the key says whether its own check would
/// have to run again. An edit-scenario fixture asserts exactly which keys
/// moved, with no cache directory in sight — which is what lets the whole
/// invalidation table be pinned before a byte is ever written to disk.
fn printCacheKeys(gpa: Allocator, stdout: *Io.Writer, session: *Session) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Line = struct {
        key: []const u8,
        digits: [32]u8,

        fn lessThan(_: void, a: @This(), b: @This()) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    };
    const lines = try arena.alloc(Line, session.graph.count());
    for (lines, 0..) |*line, i| {
        const m: @TypeOf(session.graph).Index = @fromBackingInt(@intCast(i));
        const file = session.graph.moduleFile(m);
        line.* = .{
            .key = try std.fmt.allocPrint(arena, "{t}:{s}", .{
                session.store.package(file),
                session.interner.slice(session.graph.moduleName(m)),
            }),
            .digits = Key.hex(session.keys.of(m)),
        };
    }
    std.mem.sort(Line, lines, {}, Line.lessThan);
    for (lines) |line| try stdout.print("{s} {s}\n", .{ line.key, &line.digits });
    try stdout.flush();
}

/// `--cutoff-compare`: one `<package>:<Module> <32 hex digits>` line per module
/// on stdout, sorted by that key — the key under the CUTOFF recipe, beside the
/// one the run actually used.
///
/// It exists for ONE assertion, over two runs of an edited tree: **old key
/// equal ⇒ new key equal** (`Cli.Cache.cutoff_compare`). A test that compared
/// only the keys in use could not make it, because the run is driven by one
/// recipe at a time.
fn printCompareKeys(gpa: Allocator, stdout: *Io.Writer, session: *Session) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Line = struct {
        key: []const u8,
        digits: [32]u8,

        fn lessThan(_: void, a: @This(), b: @This()) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    };
    const lines = try arena.alloc(Line, session.graph.count());
    for (lines, 0..) |*line, i| {
        const m: @TypeOf(session.graph).Index = @fromBackingInt(@intCast(i));
        const file = session.graph.moduleFile(m);
        line.* = .{
            .key = try std.fmt.allocPrint(arena, "{t}:{s}", .{
                session.store.package(file),
                session.interner.slice(session.graph.moduleName(m)),
            }),
            .digits = Key.hex(if (i < session.compare_keys.len) session.compare_keys[i] else Key.none),
        };
    }
    std.mem.sort(Line, lines, {}, Line.lessThan);
    for (lines) |line| try stdout.print("{s} {s}\n", .{ line.key, &line.digits });
    try stdout.flush();
}

/// `--dep-digest`: one `<package>:<Module> <32 hex digits>` line per module on
/// stdout, sorted by that key (`checker.md` §7, *The dependency digest*).
///
/// `--iface-hash`'s twin, and deliberately the same shape, because the two
/// answer the two halves of "what can a dependent see?": the record is what a
/// module PUBLISHES and the digest is what its dependents READ. An edit that
/// moves the digest and not the hash is exactly the case an interface-hash-only
/// firewall answers exit 0 to, so a fixture that reads both is the only one
/// that can tell the two gaps apart.
fn printDependencyDigests(gpa: Allocator, stdout: *Io.Writer, session: *Session) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Line = struct {
        key: []const u8,
        digits: [32]u8,

        fn lessThan(_: void, a: @This(), b: @This()) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    };
    const lines = try arena.alloc(Line, session.graph.count());
    for (lines, 0..) |*line, i| {
        const m: @TypeOf(session.graph).Index = @fromBackingInt(@intCast(i));
        const file = session.graph.moduleFile(m);
        line.* = .{
            .key = try std.fmt.allocPrint(arena, "{t}:{s}", .{
                session.store.package(file),
                session.interner.slice(session.graph.moduleName(m)),
            }),
            .digits = Digest.hex(if (i < session.digests.len) session.digests[i] else Digest.none),
        };
    }
    std.mem.sort(Line, lines, {}, Line.lessThan);
    for (lines) |line| try stdout.print("{s} {s}\n", .{ line.key, &line.digits });
    try stdout.flush();
}

/// `--frontend-keys`: one `<path> <32 hex digits>` line per FILE on stdout,
/// sorted by path (`fast-compiler.md` §8, `frontend.md` §1), for every file
/// the run lowered.
///
/// `--cache-keys`' twin, and deliberately the same shape, because the two
/// answer the two halves of the question incremental rebuilds ask: the module key says
/// whether a module's CHECK would have to run again, and the file key whether
/// its front end would. A body edit in a leaf moves one of these and three of
/// those, and an edit-scenario fixture asserts exactly that, with no cache
/// directory in sight.
///
/// Keyed on the PATH and not on the module name, because the front end is per
/// file: a path that names no module still has tokens and a line table. The
/// file index is not path order (`SourceStore.finish`), so this walks the
/// store's path-sorted view.
fn printFrontendKeys(stdout: *Io.Writer, session: *Session) !void {
    const FileKey = @import("../cache/FileKey.zig");
    for (session.store.byPath()) |file| {
        const i = file.int();
        // A core module no wave reached has no front end and so no key
        // (checker.md §4.1, amended 2026-10-01).
        if (!session.lowered[i]) continue;
        try stdout.print("{s} {s}\n", .{ session.store.path(file), &FileKey.hex(session.file_keys[i]) });
    }
    try stdout.flush();
}

fn fail(stderr: *Io.Writer, comptime format_string: []const u8, args: anytype) u8 {
    stderr.print(format_string ++ "\n", args) catch {};
    return 2;
}

/// `--type-keys` (hidden): every source module's type keys, in path order,
/// exactly as `dump --stage=typekeys` prints them (checker-v2.md §36).
fn printTypeKeys(stdout: *Io.Writer, session: *Session) !void {
    for (session.store.byPath()) |f| {
        if (session.store.isEmbedded(f)) continue;
        for (0..session.graph.count()) |i| {
            const m: @TypeOf(session.graph).Index = @fromBackingInt(@intCast(i));
            if (session.graph.moduleFile(m) != f or session.graph.modulePackage(m) != .app) continue;
            if (i >= session.checked.type_keys.len) continue;
            try TypeKeysDump.write(
                stdout,
                session.store.moduleName(f),
                session.artifacts.bir(f),
                &session.checked.type_keys[i],
                &session.checked.types,
                &session.interner,
            );
        }
    }
    try stdout.flush();
}

/// Hidden inspector of published source-module artifacts, including cache hits.
fn printContinuations(stdout: *Io.Writer, session: *Session) !void {
    for (session.store.byPath()) |file| {
        if (session.store.isEmbedded(file)) continue;
        for (0..session.graph.count()) |i| {
            const module: @TypeOf(session.graph).Index = @fromBackingInt(@intCast(i));
            if (session.graph.moduleFile(module) != file or session.graph.modulePackage(module) != .app) continue;
            if (i >= session.checked.dispatch.len) continue;
            try ContinuationsDump.write(stdout, session.store.moduleName(file), session.artifacts.bir(file), &session.checked.dispatch[i], &session.checked.types, &session.interner);
        }
    }
    try stdout.flush();
}

test "checked control command failures preserve structured diagnostics and exit classes" {
    var session = try Session.init(std.testing.allocator, std.testing.io, .{ .jobs = 1, .diagnostics = .json, .defer_render = true });
    defer session.deinit();
    const Case = struct { err: Controls.Error, exit: u8 };
    for ([_]Case{
        .{ .err = error.UnsupportedTamper, .exit = 2 },
        .{ .err = error.MissingEvidence, .exit = 1 },
        .{ .err = error.OutOfMemory, .exit = 2 },
        .{ .err = error.InputPath, .exit = 2 },
    }) |case| {
        var diagnostics: Io.Writer.Allocating = .init(std.testing.allocator);
        defer diagnostics.deinit();
        try std.testing.expectEqual(case.exit, reportControlFailure(&session, case.err, false, &diagnostics.writer));
        const parsed = try std.json.parseFromSlice([]const @import("diagnostic").Diagnostic, std.testing.allocator, diagnostics.written(), .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 1), parsed.value.len);
        const item = parsed.value[0];
        try std.testing.expectEqual(.internal, item.code);
        try std.testing.expectEqual(.@"error", item.severity);
        try std.testing.expectEqualStrings("<checked-controls>", item.span.file);
        try std.testing.expect(std.mem.indexOf(u8, item.message, @errorName(case.err)) != null);
    }
    var rendered: Io.Writer.Allocating = .init(std.testing.allocator);
    defer rendered.deinit();
    try rendered.writer.writeAll("[]\n");
    try std.testing.expectEqual(@as(u8, 1), reportControlFailure(&session, error.GeneratedCheckFailed, true, &rendered.writer));
    try std.testing.expectEqualStrings("[]\n", rendered.written());
}

test "checked control command failure rendering preserves allocation failure exit and cleanup" {
    var session = try Session.init(std.testing.allocator, std.testing.io, .{ .jobs = 1, .diagnostics = .json, .defer_render = true });
    defer session.deinit();
    var allocation_failure = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const original = session.gpa;
    session.gpa = allocation_failure.allocator();
    defer session.gpa = original;
    var diagnostics: Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectEqual(@as(u8, 2), reportControlFailure(&session, error.MissingEvidence, false, &diagnostics.writer));
    try std.testing.expectEqualStrings("", diagnostics.written());
}

test "checked control command failure rendering preserves exhausted writer exit" {
    var session = try Session.init(std.testing.allocator, std.testing.io, .{ .jobs = 1, .diagnostics = .json, .defer_render = true });
    defer session.deinit();
    var buffer: [0]u8 = .{};
    var diagnostics: Io.Writer = .fixed(&buffer);
    try std.testing.expectEqual(@as(u8, 2), reportControlFailure(&session, error.MissingEvidence, false, &diagnostics));
}
