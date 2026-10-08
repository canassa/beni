//! CLI entry (docs/design/frontend.md §1): parse arguments, dispatch, map
//! outcomes to exit codes. Nothing here is logic worth testing in isolation;
//! `Cli.zig` owns the parsing and `Session.zig` owns the work, and the
//! black-box suite drives this binary end to end.
//!
//! Exit codes: 0 no errors, 1 at least one error diagnostic, 2 usage or I/O
//! failure. stdout carries the product; stderr carries diagnostics and usage
//! errors and nothing else. **The rule is the binary's, not each
//! subcommand's**: `dump` still prints whatever it could dump for a file
//! with lexical, syntax or lowering errors — the token stream, the tree or
//! the lowered file, placeholders and all — and it still exits 1, because
//! it printed an `error` (`frontend.md` §1, `beni help`). It exited 0 until
//! 2026-09-19 on the argument that a dump of a broken file is still a dump,
//! which is true of the PRODUCT and was never true of the exit code: every
//! script and editor driving `dump` read a silent success over a file the
//! compiler had just refused. `check` and `dump --stage=interface|types` run the check phases
//! and therefore load AND type-check the core package; `--stage=bir` stops
//! after lowering and `--stage=tokens|ast` after the parser, so those dumps
//! carry only the diagnostics of the stages they show and pay none of
//! core's cost.

const std = @import("std");
const Io = std.Io;
const beni = @import("beni");
const Cli = beni.Cli;
const Session = beni.Session;
const SourceStore = beni.SourceStore;
const Manifest = beni.js.Manifest;

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const args = init.minimal.args.toSlice(arena) catch return fail(stderr, "beni: out of memory", .{});
    const rest = if (args.len == 0) args else args[1..];
    // `build` and `serve` take a project's `"build"` defaults from its
    // `beni.json` (`frontend.md` §10.1), read where `Session` reads the app
    // manifest: `--root`, else the working directory.
    var defaults: Cli.Defaults = .{};
    if (Cli.wantsProject(rest)) {
        const root = Cli.rootArg(rest) orelse ".";
        const manifest = Manifest.read(arena, io, root) catch |err| switch (err) {
            error.OutOfMemory => return fail(stderr, "beni: out of memory", .{}),
            else => return fail(stderr, "beni: cannot read '{s}': it is not a JSON object", .{Manifest.pathIn(arena, root)}),
        };
        if (manifest) |m| defaults = .{ .platform = m.build.platform, .paths = m.build.paths, .out = m.build.out, .base = m.build.base };
    }
    const parsed = Cli.parseWith(arena, rest, defaults) catch
        return fail(stderr, "beni: out of memory", .{});
    const command = switch (parsed) {
        .command => |c| c,
        .usage => |u| return fail(stderr, "{s}", .{u.message()}),
    };

    switch (command) {
        .version => {
            // The build id follows the version (`fast-compiler.md` §8): a
            // cache entry names the compiler that wrote it, so a bug report
            // has to be able to name it too.
            const id = beni.build_id.hex();
            stdout.print("beni {s} {s}\n", .{ beni.version, &id }) catch return 2;
            return 0;
        },
        .help => {
            stdout.writeAll(Cli.usage) catch return 2;
            return 0;
        },
        .build => |build| {
            if (build.watch) return beni.devloop.Watch.run(gpa, io, stdout, stderr, sessionOptions(build.common), build, null);
            return beni.build.Command.run(gpa, io, stdout, stderr, sessionOptions(build.common), build);
        },
        .serve => |serve| return beni.devloop.Serve.run(gpa, io, stdout, stderr, sessionOptions(serve.build.common), serve),
        .new => |new| return beni.devloop.New.run(io, stdout, stderr, new),
        .check => |check| return beni.check.Command.run(gpa, io, stdout, stderr, sessionOptions(check.common), check),
        .fmt => |fmt| {
            var options = sessionOptions(fmt.common);
            options.migrate_cons = fmt.migrate_cons;
            options.migrate_lambda = fmt.migrate_lambda;
            options.migrate_unicode = fmt.migrate_unicode;
            options.migrate_top = fmt.migrate_top;
            options.migrate_names = fmt.migrate_names;
            options.migrate_let = fmt.migrate_let;
            return beni.fmt.Command.run(gpa, io, stdout, stderr, options, fmt);
        },
        .dump => |dump| return runDump(gpa, io, stdout, stderr, dump),
    }
}

fn fail(stderr: *Io.Writer, comptime fmt: []const u8, args: anytype) u8 {
    stderr.print(fmt ++ "\n", args) catch {};
    return 2;
}

fn sessionOptions(common: Cli.Common) Session.Options {
    const cpus: u32 = @intCast(@min(std.Thread.getCpuCount() catch 1, std.math.maxInt(u32) / 4));
    // More workers than this cannot help and does hurt: every worker costs
    // an `Arena`, an interner pre-seeded with the well-known symbols, and a
    // thread. `--jobs=20000` on a six-byte file spent 7.6 s building them.
    // Four per CPU leaves room for an oversubscribed build to ask for more
    // than it has cores without the flag becoming a way to hang the tool.
    const jobs: u32 = @min(common.jobs orelse cpus, cpus *| 4);
    return .{
        .jobs = @max(jobs, 1),
        // With no `--jobs`, the CPU count is only a ceiling, and the pools
        // are sized by how much source there is to work on.
        .size_by_work = common.jobs == null,
        .diagnostics = switch (common.diagnostics) {
            .text => .text,
            .json => .json,
        },
        .self_profile = common.self_profile,
        .root = common.root,
        .core = common.core,
        .core_root = common.core_root,
        .pattern_budget = common.pattern_budget orelse Session.default_pattern_budget,
        .roundtrip_interfaces = common.roundtrip_interfaces,
        .roundtrip_dispatch = common.roundtrip_dispatch,
        .roundtrip_frontend = common.roundtrip_frontend,
    };
}

/// Run `phases` over `paths`, mapping the driver's failure to the exit-2
/// message. Returns the summary, or the exit code to return.
fn runSession(session: *Session, stderr: *Io.Writer, paths: []const []const u8, phases: Session.Phases) union(enum) { summary: Session.Summary, exit: u8 } {
    const summary = session.run(paths, phases, stderr) catch |err| switch (err) {
        error.InputPath => {
            const failure = session.io_failure.?;
            return .{ .exit = fail(stderr, "beni: cannot read '{s}': {t}", .{ failure.path, failure.err }) };
        },
        else => |e| return .{ .exit = fail(stderr, "beni: {t}", .{e}) },
    };
    return .{ .summary = summary };
}

/// Run `function` on a thread with the stack a deep tree walk needs. The
/// same shape `Session` uses for the checker, and for the same reason: the
/// parser's nesting limit bounds the tree at `Parse.max_depth` levels, every
/// consumer walks it by recursion, and a main thread does not have room for
/// that many frames.
fn onBigStack(comptime function: anytype, args: anytype) anyerror!void {
    const Runner = struct {
        args: @TypeOf(args),
        result: anyerror!void = {},

        fn go(r: *@This()) void {
            r.result = @call(.auto, function, r.args);
        }
    };
    var runner: Runner = .{ .args = args };
    const thread = std.Thread.spawn(.{ .stack_size = Session.check_stack_size }, Runner.go, .{&runner}) catch |err| {
        // No thread to be had: do it here and hope the tree is shallow,
        // which it is for everything but the pathological inputs.
        if (err == error.OutOfMemory) return err;
        return @call(.auto, function, args);
    };
    thread.join();
    return runner.result;
}

fn runDump(gpa: std.mem.Allocator, io: Io, stdout: *Io.Writer, stderr: *Io.Writer, dump: Cli.Dump) u8 {
    var options = sessionOptions(dump.common);
    // Only the interface dump resolves names, and only it needs core
    // alongside the file (checker.md §4). The other three stages are a
    // function of the file's own bytes, and loading ~2,800 lines of core
    // into every one of them would be pure cost.
    options.core_package = Cli.stageResolvesImports(dump.stage);
    // A platform is the other package an import may resolve into
    // (boundary.md §5.3), so it is loaded for exactly the stages core is —
    // `parseDump` has already refused the flag on the others, so this is
    // never a silent drop.
    options.platform = if (Cli.stageResolvesImports(dump.stage)) dump.platform else null;
    // `--stage=types` prints local bindings' types, and a `Var` means
    // nothing once its store is gone (checker.md §5).
    options.keep_type_stores = dump.stage == .types;
    // The chain is read before any source, as `check` and `build` read it
    // (platform.zig): a `--platform` that names nothing is the same exit 2
    // and the same line.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var chain_failure: ?beni.platform.Failure = null;
    const chain: ?beni.platform.Chain = if (options.platform) |requested|
        beni.platform.resolveChain(arena_state.allocator(), io, requested, &chain_failure) catch |err| switch (err) {
            error.OutOfMemory => return fail(stderr, "beni: out of memory", .{}),
            error.Failed => return beni.platform.report(stderr, chain_failure.?),
        }
    else
        null;
    if (chain) |*c| options.chain = c;
    var session = Session.init(gpa, io, options) catch return fail(stderr, "beni: out of memory", .{});
    defer session.deinit();
    const phases: Session.Phases = switch (dump.stage) {
        .tokens, .ast => Session.parse_phases,
        .bir => Session.lower_phases,
        .interface, .raw, .types, .dispatch, .writes => Session.check_phases,
        // The graph is what `resolve_phases` builds first, and nothing
        // after it changes an edge (`static-dispatch-spike.md` §6.8), so
        // this dump stops before a single module is checked.
        .graph => Session.resolve_phases,
    };
    const summary = switch (runSession(&session, stderr, &.{dump.file}, phases)) {
        .summary => |s| s,
        .exit => |code| return code,
    };
    // `--stage=graph` is about the PROJECT and not about one file: it
    // takes whatever path the other stages take and prints the whole
    // module graph, so it never looks a dump target up.
    if (dump.stage == .graph) {
        beni.dump.graph.write(stdout, gpa, &session.graph, &session.interner) catch return 2;
        return dumpExit(summary, 0);
    }
    // `--stage=writes` is about the PROGRAM: every `main` under the path,
    // a file or a directory, with the whole program it reaches.
    if (dump.stage == .writes) {
        if (summary.errors > 0) return dumpExit(summary, 0);
        return dumpExit(summary, dumpWrites(gpa, &session, stdout, stderr, dump));
    }
    // `--stage=interface` takes a directory as well as a file: a project's
    // interfaces in path order are exactly what a `check/good` corpus
    // golden is (checker.md §3), and unlike the other three stages an
    // interface is a per-MODULE product that only exists once the whole
    // project has resolved.
    const file = dumpTarget(&session, dump.file) orelse {
        // `--stage=dispatch` takes a directory for the same reason
        // (static-dispatch-spike.md §7.3): the table is per module, and a
        // project's tables in path order are what a corpus golden is.
        if (dump.stage == .dispatch) return dumpExit(summary, dumpProjectDispatch(gpa, &session, stdout, stderr, dump.file));
        if (dump.stage != .interface and dump.stage != .raw) return fail(stderr, "beni: dump needs exactly one file", .{});
        return dumpExit(summary, dumpProjectInterfaces(gpa, &session, stdout, stderr, dump.file, dump.stage == .raw));
    };
    switch (dump.stage) {
        .tokens => beni.dump.tokens.write(
            stdout,
            session.store.bytes(file),
            session.artifacts.tokens(file),
            session.artifacts.comments(file),
            session.store.lineStarts(file),
        ) catch return 2,
        // The AST dump recurses once per NODE, and the parser will hand it
        // a tree `Parse.max_depth` levels deep on purpose
        // (`bench/pathological/`). That does not fit in the 8 MiB a main
        // thread gets — 4090 nested parentheses segfaulted it — so it runs
        // where every other tree walk in the compiler runs: on a thread
        // with an explicit stack (Session's `check_stack_size`).
        .ast => onBigStack(struct {
            fn go(w: *Io.Writer, sess: *Session, f: SourceStore.Index, positions: bool) anyerror!void {
                return beni.dump.ast.write(
                    w,
                    sess.store.bytes(f),
                    sess.artifacts.tokens(f),
                    sess.artifacts.comments(f),
                    sess.store.lineStarts(f),
                    sess.artifacts.ast(f),
                    .{ .positions = positions },
                );
            }
        }.go, .{ stdout, &session, file, dump.positions }) catch return 2,
        .bir => beni.dump.bir.write(
            stdout,
            session.store.bytes(file),
            session.artifacts.comments(file),
            session.artifacts.bir(file),
            .fromGlobal(&session.interner),
        ) catch return 2,
        .interface => {
            const m = moduleOf(&session, file) orelse return fail(stderr, "beni: '{s}' is not a module", .{dump.file});
            beni.dump.interface.write(
                stdout,
                gpa,
                session.store.moduleName(file),
                &session.resolution.interfaces[m.int()],
                session.checked.types.refIds(m),
                &session.checked.types,
                &session.interner,
            ) catch return 2;
        },
        .raw => {
            const m = moduleOf(&session, file) orelse return fail(stderr, "beni: '{s}' is not a module", .{dump.file});
            beni.dump.interface.writeRaw(
                stdout,
                session.store.moduleName(file),
                &session.resolution.interfaces[m.int()],
                &session.interner,
            ) catch return 2;
        },
        // `--stage=dispatch` is per module, like `--stage=types`, and needs
        // no store: everything in the table is an index or a name (§7.1).
        .dispatch => {
            const m = moduleOf(&session, file) orelse return fail(stderr, "beni: '{s}' is not a module", .{dump.file});
            if (m.int() >= session.checked.dispatch.len) return fail(stderr, "beni: '{s}' was not checked", .{dump.file});
            beni.dump.dispatch.write(
                gpa,
                stdout,
                session.store.moduleName(file),
                session.artifacts.bir(file),
                &session.checked.dispatch[m.int()],
                &session.graph,
                session.resolution.interfaces,
                &session.checked.types,
                &session.interner,
            ) catch return 2;
        },
        .graph, .writes => unreachable, // handled above: neither is one file's
        .types => {
            const m = moduleOf(&session, file) orelse return fail(stderr, "beni: '{s}' is not a module", .{dump.file});
            if (m.int() >= session.checked.modules.len) return fail(stderr, "beni: '{s}' was not checked", .{dump.file});
            beni.dump.types.write(
                stdout,
                gpa,
                session.store.moduleName(file),
                session.artifacts.bir(file),
                &session.checked.modules[m.int()],
                &session.checked.types,
                &session.interner,
            ) catch return 2;
        },
    }
    return dumpExit(summary, 0);
}

/// The exit code of a dump: whatever went wrong PRINTING it, if anything;
/// else 1 when the session produced an `error`-severity diagnostic, else 0.
///
/// `frontend.md` §1 and `beni help` state the exit codes for the binary,
/// with no `dump` carve-out, and a `warning` is the only severity that
/// cannot change one. The dump itself is still written — error recovery
/// means a broken file has a tree worth looking at, and that is exactly the
/// file a person runs `dump` on.
fn dumpExit(summary: Session.Summary, printing: u8) u8 {
    if (printing != 0) return printing;
    return if (summary.errors > 0) 1 else 0;
}

/// The file the dump is of: the one the argument named. Every other file in
/// the store is a core module the run pulled in, and naming one of those is
/// still legal — `dump --stage=interface core/List.beni` dumps `List`.
/// Null when the argument was a directory (or is not in the store at all).
fn dumpTarget(session: *const Session, arg: []const u8) ?SourceStore.Index {
    var buffer: [SourceStore.max_path_bytes]u8 = undefined;
    if (session.store.find(storePath(&buffer, arg))) |file| return file;
    return if (session.store.count() == 1) @fromBackingInt(@intCast(0)) else null;
}

/// The argument as the STORE spells it. Enumeration normalises every path
/// lexically (`SourceStore.normalize`), so an argument that is looked up or
/// prefix-matched against `store.paths()` has to be normalised the same way
/// or `beni dump --stage=interface ./src` finds nothing.
fn storePath(buffer: []u8, arg: []const u8) []const u8 {
    if (arg.len > buffer.len) return arg;
    return SourceStore.normalize(buffer, arg);
}

/// Whether the enumerated path `p` lies under the directory argument `dir`,
/// both normalised. `.` is the source root itself, so everything the walk
/// found is under it — everything, that is, that the walk found: an
/// `embedded` core or platform module is filtered out by the caller.
fn underDir(p: []const u8, dir: []const u8) bool {
    if (std.mem.eql(u8, dir, ".")) return !std.mem.startsWith(u8, p, "/") and !std.mem.startsWith(u8, p, "../");
    return p.len > dir.len and std.mem.startsWith(u8, p, dir) and p[dir.len] == '/';
}

/// Every module under the directory `arg`, in path order: the interface
/// golden of a whole project. Modules the run pulled in from elsewhere —
/// the core package — are not under it and are not printed.
fn dumpProjectInterfaces(gpa: std.mem.Allocator, session: *Session, stdout: *Io.Writer, stderr: *Io.Writer, arg: []const u8, raw: bool) u8 {
    var buffer: [SourceStore.max_path_bytes]u8 = undefined;
    const dir = storePath(&buffer, arg);
    var printed: u32 = 0;
    for (session.store.byPath()) |f| {
        const p = session.store.path(f);
        if (session.store.isEmbedded(f) or !underDir(p, dir)) continue;
        const m = moduleOf(session, f) orelse continue;
        const iface = &session.resolution.interfaces[m.int()];
        if (raw)
            beni.dump.interface.writeRaw(stdout, session.store.moduleName(f), iface, &session.interner) catch return 2
        else
            beni.dump.interface.write(stdout, gpa, session.store.moduleName(f), iface, session.checked.types.refIds(m), &session.checked.types, &session.interner) catch return 2;
        printed += 1;
    }
    if (printed == 0) return fail(stderr, "beni: dump needs at least one module", .{});
    return 0;
}

/// Every module under the directory `arg`, in path order: the dispatch
/// golden of a whole project (§7.3).
fn dumpProjectDispatch(gpa: std.mem.Allocator, session: *Session, stdout: *Io.Writer, stderr: *Io.Writer, arg: []const u8) u8 {
    var buffer: [SourceStore.max_path_bytes]u8 = undefined;
    const dir = storePath(&buffer, arg);
    var printed: u32 = 0;
    for (session.store.byPath()) |f| {
        const p = session.store.path(f);
        if (session.store.isEmbedded(f) or !underDir(p, dir)) continue;
        const m = moduleOf(session, f) orelse continue;
        if (m.int() >= session.checked.dispatch.len) continue;
        beni.dump.dispatch.write(
            gpa,
            stdout,
            session.store.moduleName(f),
            session.artifacts.bir(f),
            &session.checked.dispatch[m.int()],
            &session.graph,
            session.resolution.interfaces,
            &session.checked.types,
            &session.interner,
        ) catch return 2;
        printed += 1;
    }
    if (printed == 0) return fail(stderr, "beni: dump needs at least one module", .{});
    return 0;
}

/// The write-set pass over every program whose `main` is in the file or
/// under the directory `dump.file` names (write-sets.md §8.1).
fn dumpWrites(gpa: std.mem.Allocator, session: *Session, stdout: *Io.Writer, stderr: *Io.Writer, dump: Cli.Dump) u8 {
    const Writes = beni.writes.Writes;
    const n = session.graph.count();
    var buffer: [SourceStore.max_path_bytes]u8 = undefined;
    const target = storePath(&buffer, dump.file);
    const birs = gpa.alloc(*const beni.Bir, n) catch return fail(stderr, "beni: out of memory", .{});
    defer gpa.free(birs);
    const names = gpa.alloc([]const u8, n) catch return fail(stderr, "beni: out of memory", .{});
    defer gpa.free(names);
    const packages = gpa.alloc(SourceStore.Package, n) catch return fail(stderr, "beni: out of memory", .{});
    defer gpa.free(packages);
    const targets = gpa.alloc(bool, n) catch return fail(stderr, "beni: out of memory", .{});
    defer gpa.free(targets);
    var any = false;
    for (0..n) |i| {
        const m: beni.resolve.Graph.Index = @fromBackingInt(@intCast(i));
        const f = session.graph.moduleFile(m);
        birs[i] = session.artifacts.bir(f);
        names[i] = session.store.moduleName(f);
        packages[i] = session.graph.modulePackage(m);
        const p = session.store.path(f);
        targets[i] = !session.store.isEmbedded(f) and (std.mem.eql(u8, p, target) or underDir(p, target));
        any = any or targets[i];
    }
    if (!any) return fail(stderr, "beni: dump needs at least one module", .{});
    const token = session.profile.begin();
    const a = Writes.init(.{
        .gpa = gpa,
        .graph = &session.graph,
        .birs = birs,
        .provenance = session.resolution.provenance,
        .dispatch = session.checked.dispatch,
        .interner = &session.interner,
        .module_names = names,
        .packages = packages,
        .targets = targets,
        .work_cap = dump.writes_work orelse Writes.default_work,
    }) catch return fail(stderr, "beni: out of memory", .{});
    defer a.deinit();
    const result = onBigStackResult(struct {
        fn go(w: *Writes) Writes.Error!Writes.Run {
            return w.run();
        }
    }.go, .{a}) catch |err| switch (err) {
        error.OutOfMemory => return fail(stderr, "beni: out of memory", .{}),
        error.WorkCap => return fail(stderr, "beni: the write-set pass ran out of work outside a key", .{}),
    };
    session.profile.end(0, token, .writes, beni.Profile.Event.no_file, 0);
    const Pos = struct {
        fn get(ctx: *const anyopaque, module: u32, tok: u32) beni.dump.writes.Position {
            const s: *const Session = @ptrCast(@alignCast(ctx));
            const f = s.graph.moduleFile(@fromBackingInt(@intCast(module)));
            const line_starts = s.store.lineStarts(f);
            const spans = s.artifacts.spans(f);
            if (line_starts.len == 0 or tok >= spans.len()) return .{ .line = 1, .col = 1 };
            const pos = @import("diagnostic").position(line_starts, s.store.bytes(f), spans.starts[tok]);
            return .{ .line = pos.line, .col = pos.col };
        }
    };
    beni.dump.writes.write(stdout, gpa, a, result, .{ .ctx = session, .get = Pos.get }) catch return 2;
    if (dump.common.self_profile) |path| session.writeProfile(path) catch {};
    return 0;
}

/// `onBigStack` for a function with a result: the pass walks expression
/// trees by recursion, as every other tree walk does.
fn onBigStackResult(comptime function: anytype, args: anytype) @typeInfo(@TypeOf(function)).@"fn".return_type.? {
    const R = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const Runner = struct {
        args: @TypeOf(args),
        result: R = undefined,

        fn go(r: *@This()) void {
            r.result = @call(.auto, function, r.args);
        }
    };
    var runner: Runner = .{ .args = args };
    const thread = std.Thread.spawn(.{ .stack_size = Session.check_stack_size }, Runner.go, .{&runner}) catch
        return @call(.auto, function, args);
    thread.join();
    return runner.result;
}

fn moduleOf(session: *const Session, file: SourceStore.Index) ?beni.resolve.Graph.Index {
    for (0..session.graph.count()) |i| {
        const m: beni.resolve.Graph.Index = @fromBackingInt(@intCast(i));
        if (session.graph.moduleFile(m) == file) return m;
    }
    return null;
}
