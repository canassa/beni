//! `beni check [--platform=<name>] <path>...` (docs/design/frontend.md §1,
//! checker.md §2): parse, lower, resolve and type-check every module, report
//! diagnostics, write nothing.
//!
//! **`--platform` is not `build`'s alone** (boundary.md §5.3). Until this
//! command took it, `check` could not be pointed at any program that imports
//! its platform for `Program` — which is every program — so the one command
//! an editor, a pre-commit hook, CI, M4's daemon and M5's LSP all run did not
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

pub fn run(gpa: Allocator, io: Io, stdout: *Io.Writer, stderr: *Io.Writer, options_in: Session.Options, check: Cli.Check) u8 {
    var options = options_in;
    // A package may declare itself a platform (boundary.md §2), and then
    // `foreign` is legal in it. `check` has to honour that or a platform
    // package could not be checked at all.
    options.manifest_root = check.common.root orelse ".";
    // `check` resolves names across modules, and every module resolves
    // against core (checker.md §4): the package is part of the input.
    options.core_package = true;
    // `check` and `build` are the two subcommands that emit the
    // informational warnings of static-dispatch-spike.md §10 (A.83); a
    // `dump` or a `fmt` of the same file stays silent about them.
    options.informational = true;
    options.platform = check.platform;
    options.cache_build_id = check.cache.build_id;

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
    if (cache) |*c| options.cache = c;
    // With a platform there is a SECOND wave of diagnostics — §4's checks
    // run after `run` returns — and two renders on one stream are two JSON
    // arrays, which is not the format (§1.1). Without one there is no second
    // wave and `run` renders as it always has.
    options.defer_render = check.platform != null;

    var session = Session.init(gpa, io, options) catch return fail(stderr, "beni: out of memory", .{});
    defer session.deinit();

    const summary = session.run(check.paths, Session.check_phases, stderr) catch |err| switch (err) {
        error.InputPath => {
            const failure = session.io_failure.?;
            return fail(stderr, "beni: cannot read '{s}': {t}", .{ failure.path, failure.err });
        },
        else => |e| return fail(stderr, "beni: {t}", .{e}),
    };
    if (session.platform_error) return platform.reportUnknown(stderr, check.platform.?);
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
    if (summary.errors > 0) {
        _ = session.renderLate(&.{}, stderr) catch return 2;
        return 1;
    }
    const requested = check.platform orelse return 0;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The platform's own manifest is read even though nothing here uses its
    // `program` or `runtime`: `--platform=<dir>` naming something that is not
    // a platform package is the same exit-2 failure for `check` as for
    // `build`, and finding that out only at build time is the asymmetry this
    // flag exists to remove.
    const loaded = platform.load(arena, io, &session) catch |err|
        return platform.report(stderr, requested, &session, err);

    const items = Emit.checkContract(gpa, arena, &session, .{
        .out_dir = &.{}, // nothing is written; the field is `run`'s
        .platform = loaded.platform,
        .embedded = loaded.embedded,
    }) catch return fail(stderr, "beni: out of memory", .{});
    defer {
        for (items) |item| gpa.free(item.message);
        gpa.free(items);
    }

    // The one render of the stream: §4's diagnostics and the `warning`s
    // `run` held back, sorted together into one array. Called even when the
    // checks said nothing, because the held-back wave still has to reach the
    // author.
    const late = gpa.alloc(Session.LateItem, items.len) catch
        return fail(stderr, "beni: out of memory", .{});
    defer gpa.free(late);
    for (items, late) |item, *slot| {
        slot.* = .{ .code = item.code, .file = item.file, .token = item.token, .message = item.message, .at = item.at };
    }
    const errors = session.renderLate(late, stderr) catch return 2;
    return if (errors > 0) 1 else 0;
}

/// `--iface-hash`: one `<package>:<Module> <32 hex digits>` line per module
/// on stdout, `core` and the platform included, sorted by that key
/// (`fast-compiler.md` §8's *The interface hash, and slice zero*).
///
/// **Why it exists at all**: `dump --stage=raw` prints only the modules
/// named on the command line, so core's and the platform's records are
/// invisible to it — and the firewall's quantity is "did this record
/// change?", which is a hash and not a dump. `bench/churn.sh` reports
/// "importers re-checked" out of these lines.
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
        const m: @TypeOf(session.graph).Index = @enumFromInt(i);
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
        const m: @TypeOf(session.graph).Index = @enumFromInt(i);
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

fn fail(stderr: *Io.Writer, comptime format_string: []const u8, args: anytype) u8 {
    stderr.print(format_string ++ "\n", args) catch {};
    return 2;
}
