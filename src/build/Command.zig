//! `beni build --platform=<name> <path>...` (docs/design/backend.md §2,
//! boundary.md §5): the driver around `js/Emit.zig`.
//!
//! The order is the contract's: **nothing is emitted until the whole project
//! checks clean.** A build with an error diagnostic writes no file and
//! creates no directory — partial output from a failed build is worse than
//! no output, because a stale `out/` that looks fresh is what a watch
//! process serves.
//!
//! **A build is a pair of entry point and platform** (boundary.md §5.3). The
//! platform is named on the command line; the entry point is the module that
//! declares `main`, because in a project with one `main` the entry is not
//! information the user should have to repeat, and a project with two is two
//! builds. The platform package is enumerated alongside the app and core, so
//! a module that names a capability this platform does not offer fails to
//! RESOLVE — which is §5.3's "the diagnostic you want rather than a runtime
//! surprise".
//!
//! Exit codes are `frontend.md` §1's: 0 no errors, 1 at least one error
//! diagnostic, 2 a usage or I/O failure. stdout carries the product — here,
//! the one summary line naming what was written — and stderr the
//! diagnostics.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Cli = @import("../Cli.zig");
const Session = @import("../Session.zig");
const Arena = @import("../Arena.zig");
const SourceStore = @import("../SourceStore.zig");
const Emit = @import("../js/Emit.zig");
const beni_profile = @import("../Profile.zig");
const platform = @import("../platform.zig");
const CacheDir = @import("../cache/Dir.zig");
const Manifest = @import("../js/Manifest.zig");
const OutputRecord = @import("../js/OutputRecord.zig");

pub fn run(gpa: Allocator, io: Io, stdout: *Io.Writer, stderr: *Io.Writer, options_in: Session.Options, build: Cli.Build) u8 {
    var options = options_in;
    // A build resolves every name against core and against the platform,
    // and type-checks: all three are part of the input (checker.md §4,
    // boundary.md §5.3).
    options.core_package = true;
    options.platform = build.platform;
    options.cache_build_id = build.cache.build_id;
    options.manifest_root = build.common.root orelse ".";
    // `check` and `build` are the two subcommands that emit the
    // informational warnings of static-dispatch-spike.md §10 (A.83) — which
    // is why the run's own wave is held back: the emit phase below can add
    // to it, and the two together are ONE array on stderr.
    options.informational = true;
    options.explain = build.common.explain;
    options.defer_render = true;

    // Opened here for the reason `check/Command.zig` gives: the one failure
    // a cache is allowed to have is a usage failure, and the command owns
    // the message. `build` caches no emitted byte — the entry holds
    // the check's result and nothing of `emit`'s, and the write-skip
    // `Emit.flush` wants is future work.
    var cache_failure: ?CacheDir.Failure = null;
    var cache: ?CacheDir = CacheDir.fromCli(io, build.cache, &cache_failure) catch {
        const f = cache_failure.?;
        return fail(stderr, "beni: cannot write '{s}': {t}", .{ f.path, f.err });
    };
    defer if (cache) |*c| c.close();
    // `--records-in-place` enforces as `--ownership-everywhere` does, so
    // its entries are that flag's.
    if (cache) |*c| if (build.common.ownership_everywhere or build.records_in_place) c.into("ownership-everywhere", &cache_failure) catch {
        const f = cache_failure.?;
        return fail(stderr, "beni: cannot write '{s}': {t}", .{ f.path, f.err });
    };
    if (cache) |*c| options.cache = c;

    // What lives for the whole build: the platform chain, the reachability
    // sets, the pending output. One module's working memory is the
    // emitter's own arena, reset between modules. Single-threaded, like every
    // arena here (fast-compiler.md §5 rule 3): one thread uses it at a time.
    var arena_state: Arena = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The platform chain, before any source is read: a manifest failure is
    // an exit-2 line and nothing else (`boundary.md` §9.1).
    var chain_failure: ?platform.Failure = null;
    const chain = platform.resolveChain(arena, io, build.platform, &chain_failure) catch |err| switch (err) {
        error.OutOfMemory => return fail(stderr, "beni: out of memory", .{}),
        error.Failed => return platform.report(stderr, chain_failure.?),
    };
    // A chain that declares no `program` is only depended on (§9.1): it
    // builds a library and never a program.
    if (!build.library and chain.first("program") == null) return platform.reportNoProgram(stderr, build.platform);
    options.chain = &chain;
    // `ownership-checker.md` §28.3: the pass runs when the chain edits
    // lists in place, and not otherwise.
    options.ownership = true;
    options.records_in_place = build.records_in_place;

    var session = Session.init(gpa, io, options) catch return fail(stderr, "beni: out of memory", .{});
    defer session.deinit();
    // The list sanitiser judges accepted writes, and only a build that
    // enforces has them: anywhere else it would pass every program while
    // checking none (`ownership-v2.md` §7.3).
    if (build.sanitize_lists and !session.enforce_ownership) {
        return fail(stderr, "beni: --sanitize-lists needs a build that enforces ownership: an in-place platform, --ownership-everywhere or --records-in-place", .{});
    }

    const summary = session.run(build.paths, Session.check_phases, stderr) catch |err| switch (err) {
        error.InputPath => {
            const failure = session.io_failure.?;
            return fail(stderr, "beni: cannot read '{s}': {t}", .{ failure.path, failure.err });
        },
        else => |e| return fail(stderr, "beni: {t}", .{e}),
    };
    if (summary.errors > 0) {
        _ = session.renderLate(&.{}, stderr) catch return 2;
        return 1;
    }

    var loaded = platform.load(arena, &session, &chain, !build.library) catch |err|
        return platform.reportLoad(stderr, build.platform, err);
    // The app's own page shell replaces the chain's (`backend.md` §2, *The
    // page shell*; `frontend.md` §10.1). Read here, every build, so that a
    // watch picks up an edit to it.
    const app_root = build.common.root orelse ".";
    const app = Manifest.read(arena, io, app_root) catch |err| switch (err) {
        error.OutOfMemory => return fail(stderr, "beni: out of memory", .{}),
        else => return fail(stderr, "beni: cannot read '{s}': it is not a JSON object", .{Manifest.pathIn(arena, app_root)}),
    };
    loaded.platform.base = build.base;
    if (app) |m| if (m.html) |html| {
        loaded.platform.html = html;
        loaded.platform.html_root = app_root;
    };
    // The app's `"exports"` is the entry file's list of named exports
    // (`boundary.md` §5.2, `frontend.md` §10.1); on an app a string is the
    // wrong JSON type, which is the manifest's exit-2 failure.
    if (app) |m| switch (m.exports) {
        .none => {},
        .names => |names| {
            loaded.platform.entry_exports = names;
            loaded.platform.app_root = app_root;
        },
        .mode => return fail(stderr, "beni: {s}'s \"exports\" must be a list of names, not a string", .{Manifest.pathIn(arena, app_root)}),
    };

    var emit_options: Emit.Options = .{
        .out_dir = build.out,
        .platform = loaded.platform,
        .embedded = loaded.embedded,
        .library = build.library,
        .release = build.release,
        .allow_debug = build.allow_debug,
        .test_hooks = build.test_hooks,
        .sanitize_records = build.sanitize_records,
        .sanitize_lists = build.sanitize_lists,
        .schema_library = build.schema_library,
        .schema_shapes = build.schema_shapes,
        .fuzz = build.fuzz,
        .points_to_largest = build.points_to_largest,
        .check_call_graph = build.check_call_graph,
        .rep_keys = build.rep_keys,
        .source_maps = build.source_maps,
    };
    // `prerender.md` §5.1: the prerender tree first, run under Node, and
    // what it gave handed to the client tree's build, which writes the page
    // or refuses the build.
    if (build.prerender) {
        const lowering = if (loaded.platform.lowering) |name| Emit.findLowering(name) else null;
        if (lowering == null or !lowering.?.prerenders) return fail(stderr, "beni: --prerender needs a platform whose markup lowering prerenders, as browser-inline's does", .{});
        const tree = prerender(gpa, io, arena, &session, emit_options, options.path, stderr, options.diagnostics == .text) catch |err| switch (err) {
            error.OutOfMemory => return fail(stderr, "beni: out of memory", .{}),
            error.OutputPath => {
                const failure = session.io_failure.?;
                return fail(stderr, "beni: cannot write '{s}': {t}", .{ failure.path, failure.err });
            },
            error.OutputRecordUnreadable => {
                const failure = session.io_failure.?;
                return fail(stderr, "beni: cannot read '{s}': {t}", .{ failure.path, failure.err });
            },
            error.NodeFailed => return 2,
        };
        switch (tree) {
            .refused => |code| return code,
            .ran => |outcome| emit_options.prerender = .{ .client = outcome },
        }
    }

    const emit_token = session.profile.begin();
    var result = emitOnBigStack(gpa, arena, &session, emit_options) catch |err| switch (err) {
        error.OutOfMemory => return fail(stderr, "beni: out of memory", .{}),
        error.OutputPath => {
            const failure = session.io_failure.?;
            return fail(stderr, "beni: cannot write '{s}': {t}", .{ failure.path, failure.err });
        },
        error.OutputRecordUnreadable => {
            const failure = session.io_failure.?;
            return fail(stderr, "beni: cannot read '{s}': {t}", .{ failure.path, failure.err });
        },
    };
    defer result.deinit(gpa);
    // `--points-to-largest`'s lines: a measuring instrument, not a diagnostic.
    stderr.writeAll(result.points_to) catch return 2;
    // `--rep-keys`' table (hidden): written to stdout, which the corpus reads.
    stdout.writeAll(result.rep_keys) catch return 2;
    session.profile.end(0, emit_token, .emit, beni_profile.Event.no_file, @intCast(result.bytes_written));

    // The one render of the stream: the emit phase's diagnostics and the
    // `warning`s `run` held back, sorted together into one array. Called
    // even when the emit phase said nothing, because the held-back wave
    // still has to reach the author.
    {
        const late = gpa.alloc(Session.LateItem, result.diagnostics.len) catch
            return fail(stderr, "beni: out of memory", .{});
        defer gpa.free(late);
        for (result.diagnostics, late) |item, *slot| {
            slot.* = .{ .code = item.code, .file = item.file, .token = item.token, .end_token = item.end_token, .message = item.message, .at = item.at, .severity = item.severity };
        }
        const errors = session.renderLate(late, stderr) catch return 2;
        if (errors > 0) return 1;
    }

    // A successful build prints NOTHING, on either stream. `frontend.md` §1
    // gives stdout to the product and stderr to diagnostics and nothing
    // else, and a build's product is the files it wrote — so there is no
    // stream left for a summary line, and `check` already sets the
    // precedent. How much was written is a `--self-profile` counter, which
    // is also where the incrementality tests read it.
    session.profile.addCounter(.emitted_files, result.files_written);
    session.profile.addCounter(.emitted_bytes, result.bytes_written);
    if (options.self_profile) |path| session.writeProfile(path) catch {};
    stdout.flush() catch return 2;
    return 0;
}

/// Lowering and printing both walk an expression TREE by recursion, and the
/// parser accepts `Parse.max_depth` levels of nesting (language.md §10): a
/// chain of 4 000 nested calls is one of the shapes `bench/pathological/`
/// keeps on purpose. Those frames do not fit in the 8 MiB a main thread
/// gets, and the failure mode is a segfault rather than a diagnostic — which
/// is the one failure mode the house rules do not permit. So the emit phase
/// runs where every other tree walk in the compiler runs: on a thread with
/// the stack `Session.check_stack_size` names.
fn emitOnBigStack(gpa: Allocator, arena: Allocator, session: *Session, options: Emit.Options) Emit.Error!Emit.Result {
    const Runner = struct {
        gpa: Allocator,
        arena: Allocator,
        session: *Session,
        options: Emit.Options,
        result: Emit.Error!Emit.Result = undefined,

        fn go(r: *@This()) void {
            r.result = Emit.run(r.gpa, r.arena, r.session, r.options, &r.session.io_failure);
        }
    };
    var runner: Runner = .{ .gpa = gpa, .arena = arena, .session = session, .options = options };
    // A build with no threads emits here: its main stack is sized for it
    // (fast-compiler.md §10, *A build with no threads*).
    if (builtin.single_threaded) return Emit.run(gpa, arena, session, options, &session.io_failure);
    const thread = std.Thread.spawn(.{ .stack_size = Session.check_stack_size }, Runner.go, .{&runner}) catch {
        // No thread to be had: emit here and hope the trees are shallow,
        // which they are for everything but the pathological inputs.
        return Emit.run(gpa, arena, session, options, &session.io_failure);
    };
    thread.join();
    return runner.result;
}

/// What building and running the prerender tree gave: the build's exit
/// code, its diagnostics rendered, or what the client tree's build is
/// handed (`prerender.md` §5.1).
const Tree = union(enum) { refused: u8, ran: Emit.Prerender.Outcome };

/// The Node runner of the prerender tree (`prerender.md` §5.1 item 2),
/// written beside its entry: every route rendered in order, one record per
/// route — the route and its HTML, as a line of JSON — appended to the
/// records file the build names. It has no `catch` (CLAUDE.md rule 9, §5.5):
/// a throw ends Node with the error on its standard error, and the records
/// written before it stay. It is the one file of the tree that uses Node's
/// own API; the entry runs on any engine that runs ES modules.
const node_runner =
    \\// Generated by `beni build` (docs/design/prerender.md §5.1): the prerender
    \\// tree run under Node, one record per route appended to the records file.
    \\import { appendFileSync } from "node:fs";
    \\import { routes, render } from "./
++ Emit.prerender_entry ++
    \\";
    \\
    \\const records = process.argv[2];
    \\for (const route of routes) appendFileSync(records, JSON.stringify({ route, html: render(route) }) + "\n");
    \\
;

const node_runner_file = "_node.mjs";
const records_file = "_records.jsonl";

/// A record of the prerender tree's run.
const Record = struct { route: []const u8, html: []const u8 };

/// `prerender.md` §5.1, items 1, 2 and 4: the prerender tree built into a
/// directory of its own beside `--out`, run under the `node` on `PATH`,
/// and removed. A tree the build refuses — `prerender_impure`, a shell with
/// no `{{view}}` — is the build's failure, its diagnostics rendered; one
/// that ran gives the client tree what it needs to write the page or to
/// refuse the build.
fn prerender(gpa: Allocator, io: Io, arena: Allocator, session: *Session, client: Emit.Options, path: ?[]const u8, stderr: *Io.Writer, text: bool) (Emit.Error || error{NodeFailed})!Tree {
    const dir = try prerenderDir(arena, client.out_dir);
    var tree = client;
    tree.out_dir = dir;
    tree.prerender = .tree;
    tree.platform.entry = Emit.prerender_entry;
    // It runs in no page (`boundary.md` §5.2's `"host"`).
    tree.platform.page = false;
    tree.source_maps = false;
    // The directory is removed whole once the tree has run, so one that is
    // there already must be a tree a build left: it holds beni's record,
    // which the tree's build reads as any output's (`backend.md` §2).
    if (Io.Dir.cwd().access(io, dir, .{})) |_| {
        Io.Dir.cwd().access(io, try std.fs.path.join(arena, &.{ dir, OutputRecord.file_name }), .{}) catch {
            stderr.print("beni: cannot prerender: '{s}' is there, and it is not a prerender tree beni wrote\n", .{dir}) catch {};
            return error.NodeFailed;
        };
    } else |_| {}
    var built = try emitOnBigStack(gpa, arena, session, tree);
    defer built.deinit(gpa);
    const refused = for (built.diagnostics) |d| {
        if (d.severity == .@"error") break true;
    } else false;
    // Written, the tree goes when the run is over, whatever it gave.
    defer if (!refused) Io.Dir.cwd().deleteTree(io, dir) catch {};
    if (refused) {
        const late = try gpa.alloc(Session.LateItem, built.diagnostics.len);
        defer gpa.free(late);
        for (built.diagnostics, late) |item, *slot| {
            slot.* = .{ .code = item.code, .file = item.file, .token = item.token, .end_token = item.end_token, .message = item.message, .at = item.at, .severity = item.severity };
        }
        _ = session.renderLate(late, stderr) catch return .{ .refused = 2 };
        return .{ .refused = 1 };
    }
    // The client tree's build reports its warnings again: the tree's are
    // the same, and dropped.
    const runner = try std.fs.path.join(arena, &.{ dir, node_runner_file });
    const records = try std.fs.path.join(arena, &.{ dir, records_file });
    Io.Dir.cwd().writeFile(io, .{ .sub_path = runner, .data = node_runner }) catch |err| {
        session.io_failure = .{ .path = runner, .err = err };
        return error.OutputPath;
    };
    // Only `PATH` is searched: Zig's own search falls back to a default
    // path when there is none, and the build must not find a `node` there.
    const node = findOnPath(io, arena, path, "node") orelse return .{ .ran = .needs_node };
    const ran = std.process.run(gpa, io, .{ .argv = &.{ node, runner, records } }) catch |err| switch (err) {
        error.FileNotFound => return .{ .ran = .needs_node },
        else => {
            stderr.print("beni: cannot run node: {t}\n", .{err}) catch {};
            return error.NodeFailed;
        },
    };
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    // What Node wrote — a `Debug.log`'s lines among it (§3.1) — is passed on
    // to the build's standard error, where a JSON stream of diagnostics
    // has no room for it.
    if (text) {
        stderr.writeAll(ran.stdout) catch {};
        stderr.writeAll(ran.stderr) catch {};
    }
    const bytes: []const u8 = Io.Dir.cwd().readFileAlloc(io, records, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => "",
        else => {
            session.io_failure = .{ .path = records, .err = err };
            return error.OutputRecordUnreadable;
        },
    };
    const exited = switch (ran.term) {
        .exited => |code| code == 0,
        else => false,
    };
    // The routes, until the route list (slice P3): `/` alone.
    const routes = [_][]const u8{"/"};
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var view: ?[]const u8 = null;
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const record = std.json.parseFromSliceLeaky(Record, arena, line, .{}) catch
            return .{ .ran = .{ .failed = .{ .route = null, .why = "Its records file holds a line that is not a record of the prerender tree." } } };
        if (count >= routes.len or !std.mem.eql(u8, record.route, routes[count]))
            return .{ .ran = .{ .failed = .{ .route = null, .why = "Its records file holds a record of a route the build did not list, or out of the list's order." } } };
        count += 1;
        view = record.html;
    }
    if (exited and count == routes.len) return .{ .ran = .{ .view = view.? } };
    const why = if (exited) "Node ended with no record of it." else try thrown(arena, ran.stderr);
    return .{ .ran = .{ .failed = .{ .route = routes[count], .why = why } } };
}

/// The prerender tree's directory: beside `--out`, never inside it, so no
/// file of it is a file of the output, and named after it, so builds of two
/// outputs do not share one (`prerender.md` §5.1 item 1, amended). An
/// output named only `.` or `..` has no name to take: its tree is
/// `.beni-prerender` inside it, which the build removes before it writes
/// the output, so no project's tree is another's.
/// The first executable file called `name` in a directory of `path`, as an
/// absolute path where it can be made one; null when `path` is null or none
/// has one. An empty entry is skipped.
fn findOnPath(io: Io, arena: Allocator, path: ?[]const u8, name: []const u8) ?[]const u8 {
    var entries = std.mem.splitScalar(u8, path orelse return null, std.fs.path.delimiter);
    while (entries.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fs.path.join(arena, &.{ dir, name }) catch return null;
        const stat = Io.Dir.cwd().statFile(io, candidate, .{}) catch continue;
        if (stat.kind == .directory) continue;
        Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch continue;
        return Io.Dir.cwd().realPathFileAlloc(io, candidate, arena) catch candidate;
    }
    return null;
}

fn prerenderDir(arena: Allocator, out: []const u8) Allocator.Error![]const u8 {
    const trimmed = std.mem.trimEnd(u8, out, "/");
    const base = std.fs.path.basename(trimmed);
    const parent = std.fs.path.dirname(trimmed) orelse ".";
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return std.fs.path.join(arena, &.{ if (trimmed.len == 0) "/" else trimmed, ".beni-prerender" });
    return std.fs.path.join(arena, &.{ parent, try std.fmt.allocPrint(arena, ".{s}.prerender", .{base}) });
}

/// What a render threw, from what Node wrote to its standard error: the
/// error's own lines, without the source line Node quotes above them, the
/// stack below them, or Node's version — the parts that name paths of the
/// prerender tree and the machine (§5.5; mapping the stack to `.beni`
/// positions is a later improvement).
fn thrown(arena: Allocator, stderr: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    // Node quotes the line that threw first, under its path, then a blank
    // line.
    var quoted = std.mem.startsWith(u8, stderr, "file://") or std.mem.startsWith(u8, stderr, "/");
    while (lines.next()) |line| {
        if (quoted) {
            if (std.mem.trim(u8, line, " \r").len == 0) quoted = false;
            continue;
        }
        if (std.mem.startsWith(u8, line, "    at ") or std.mem.startsWith(u8, line, "Node.js v")) continue;
        if (out.items.len != 0) try out.append(arena, '\n');
        try out.appendSlice(arena, std.mem.trimEnd(u8, line, " \r"));
    }
    const text = std.mem.trim(u8, out.items, "\n ");
    return if (text.len == 0) "Node ended with an error and wrote nothing about it." else text;
}

fn fail(stderr: *Io.Writer, comptime format_string: []const u8, args: anytype) u8 {
    stderr.print(format_string ++ "\n", args) catch {};
    return 2;
}
