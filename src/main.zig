//! CLI entry (docs/design/frontend.md §1): parse arguments, dispatch, map
//! outcomes to exit codes. Nothing here is logic worth testing in isolation;
//! `Cli.zig` owns the parsing and `Session.zig` owns the work, and the
//! black-box suite drives this binary end to end.
//!
//! Exit codes: 0 no errors, 1 at least one error diagnostic, 2 usage or I/O
//! failure. stdout carries the product; stderr carries diagnostics and usage
//! errors and nothing else. `dump` exits 0 even when the file has lexical,
//! syntax or lowering errors: its product is the token stream, the tree or
//! the lowered file, placeholders and all, and the diagnostics still go to
//! stderr. `check` and `dump --stage=interface|types` run the check phases
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
    const parsed = Cli.parse(arena, if (args.len == 0) args else args[1..]) catch
        return fail(stderr, "beni: out of memory", .{});
    const command = switch (parsed) {
        .command => |c| c,
        .usage => |u| return fail(stderr, "{s}", .{u.message()}),
    };

    switch (command) {
        .version => {
            stdout.print("beni {s}\n", .{beni.version}) catch return 2;
            return 0;
        },
        .help => {
            stdout.writeAll(Cli.usage) catch return 2;
            return 0;
        },
        .build => |build| return beni.build.Command.run(gpa, io, stdout, stderr, sessionOptions(build.common), build),
        .check => |check| return runCheck(gpa, io, stderr, check),
        .fmt => |fmt| return beni.fmt.Command.run(gpa, io, stdout, stderr, sessionOptions(fmt.common), fmt),
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
        .diagnostics = switch (common.diagnostics) {
            .text => .text,
            .json => .json,
        },
        .self_profile = common.self_profile,
        .root = common.root,
        .core = common.core,
        .core_root = common.core_root,
        .pattern_budget = common.pattern_budget orelse Session.default_pattern_budget,
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

fn runCheck(gpa: std.mem.Allocator, io: Io, stderr: *Io.Writer, check: Cli.Check) u8 {
    var options = sessionOptions(check.common);
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
    var session = Session.init(gpa, io, options) catch return fail(stderr, "beni: out of memory", .{});
    defer session.deinit();
    const summary = switch (runSession(&session, stderr, check.paths, Session.check_phases)) {
        .summary => |s| s,
        .exit => |code| return code,
    };
    return if (summary.errors > 0) 1 else 0;
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
    options.core_package = dump.stage == .interface or dump.stage == .raw or dump.stage == .types or dump.stage == .graph or dump.stage == .dispatch;
    // `--stage=types` prints local bindings' types, and a `Var` means
    // nothing once its store is gone (checker.md §5).
    options.keep_type_stores = dump.stage == .types;
    var session = Session.init(gpa, io, options) catch return fail(stderr, "beni: out of memory", .{});
    defer session.deinit();
    const phases: Session.Phases = switch (dump.stage) {
        .tokens, .ast => Session.parse_phases,
        .bir => Session.lower_phases,
        .interface, .raw, .types, .dispatch => Session.check_phases,
        // The graph is what `resolve_phases` builds first, and nothing
        // after it changes an edge (`static-dispatch-spike.md` §6.8), so
        // this dump stops before a single module is checked.
        .graph => Session.resolve_phases,
    };
    switch (runSession(&session, stderr, &.{dump.file}, phases)) {
        .summary => {},
        .exit => |code| return code,
    }
    // `--stage=graph` is about the PROJECT and not about one file: it
    // takes whatever path the other stages take and prints the whole
    // module graph, so it never looks a dump target up.
    if (dump.stage == .graph) {
        beni.dump.graph.write(stdout, gpa, &session.graph, &session.interner) catch return 2;
        return 0;
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
        if (dump.stage == .dispatch) return dumpProjectDispatch(&session, stdout, stderr, dump.file);
        if (dump.stage != .interface and dump.stage != .raw) return fail(stderr, "beni: dump needs exactly one file", .{});
        return dumpProjectInterfaces(gpa, &session, stdout, stderr, dump.file, dump.stage == .raw);
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
        .graph => unreachable, // handled above: the graph is not one file's
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
    return 0;
}

/// The file the dump is of: the one the argument named. Every other file in
/// the store is a core module the run pulled in, and naming one of those is
/// still legal — `dump --stage=interface core/List.beni` dumps `List`.
/// Null when the argument was a directory (or is not in the store at all).
fn dumpTarget(session: *const Session, arg: []const u8) ?SourceStore.Index {
    if (session.store.find(std.mem.trimEnd(u8, arg, "/"))) |file| return file;
    return if (session.store.count() == 1) @enumFromInt(0) else null;
}

/// Every module under the directory `arg`, in path order: the interface
/// golden of a whole project. Modules the run pulled in from elsewhere —
/// the core package — are not under it and are not printed.
fn dumpProjectInterfaces(gpa: std.mem.Allocator, session: *Session, stdout: *Io.Writer, stderr: *Io.Writer, arg: []const u8, raw: bool) u8 {
    const dir = std.mem.trimEnd(u8, arg, "/");
    var printed: u32 = 0;
    for (0..session.store.count()) |i| {
        const f: SourceStore.Index = @enumFromInt(i);
        const p = session.store.path(f);
        if (!(p.len > dir.len and std.mem.startsWith(u8, p, dir) and p[dir.len] == '/')) continue;
        const m = moduleOf(session, f) orelse continue;
        const iface = &session.resolution.interfaces[m.int()];
        if (raw)
            beni.dump.interface.writeRaw(stdout, session.store.moduleName(f), iface, &session.interner) catch return 2
        else
            beni.dump.interface.write(stdout, gpa, session.store.moduleName(f), iface, &session.checked.types, &session.interner) catch return 2;
        printed += 1;
    }
    if (printed == 0) return fail(stderr, "beni: dump needs at least one module", .{});
    return 0;
}

/// Every module under the directory `arg`, in path order: the dispatch
/// golden of a whole project (§7.3).
fn dumpProjectDispatch(session: *Session, stdout: *Io.Writer, stderr: *Io.Writer, arg: []const u8) u8 {
    const dir = std.mem.trimEnd(u8, arg, "/");
    var printed: u32 = 0;
    for (0..session.store.count()) |i| {
        const f: SourceStore.Index = @enumFromInt(i);
        const p = session.store.path(f);
        if (!(p.len > dir.len and std.mem.startsWith(u8, p, dir) and p[dir.len] == '/')) continue;
        const m = moduleOf(session, f) orelse continue;
        if (m.int() >= session.checked.dispatch.len) continue;
        beni.dump.dispatch.write(
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

fn moduleOf(session: *const Session, file: SourceStore.Index) ?beni.resolve.Graph.Index {
    for (0..session.graph.count()) |i| {
        const m: beni.resolve.Graph.Index = @enumFromInt(i);
        if (session.graph.moduleFile(m) == file) return m;
    }
    return null;
}
