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
    // `prerender.md` §5.2: a program prerenders when its `main` says so,
    // with the lowering's `prerender` placement, in every build of it —
    // `build`, `--watch` and `serve` alike. The hidden, test-only
    // `--no-prerender` builds it as if it did not (the corpus compares the
    // two pages).
    const lowering = if (loaded.platform.lowering) |name| Emit.findLowering(name) else null;
    const spine: ?Emit.Prerenders = if (build.library or lowering == null) null else Emit.prerenders(&session, lowering.?);
    // `prerender.md` §8.10: a data site built with `--no-prerender` still
    // runs its data program, and writes each page with its value and no
    // view.
    const data_site = spine != null and spine.?.data;
    const says: ?Emit.Prerenders = if (build.no_prerender and !data_site) null else spine;
    // `prerender.md` §8.5 item 1: `Browser.prerenderData` needs a data
    // program, and a data program a `main` that says it.
    const app_manifest = Manifest.pathIn(arena, app_root);
    const data_config: ?Manifest.Build.Data = if (app) |m| m.build.data else null;
    // What the build renders with the client tree's diagnostics.
    var extra_late: std.ArrayList(Session.LateItem) = .empty;
    if (data_site and data_config == null) {
        const item: Session.LateItem = .{ .code = .prerender_needs_data, .file = @enumFromInt(0), .token = 0, .at = .{ .path = app_manifest }, .message =
        \\This program says `Browser.prerenderData`, so each of its pages is made from a value a
        \\data program gives, and this project names no data program.
        \\
        \\Add one to `"build"`: `"data": { "paths": ["data", "shared"] }`, the paths of a
        \\program built for `node` whose `main` is `Prerender.pages`
        \\(`docs/design/prerender.md` §8.2, §8.3).
        };
        _ = session.renderLate(&.{item}, stderr) catch return 2;
        return 1;
    }
    if (data_config != null and !data_site and !build.library and !Emit.mainCalls(&session, "Prerender", "pages")) {
        extra_late.append(arena, .{ .code = .prerender_data_ignored, .severity = .warning, .file = @enumFromInt(0), .token = 0, .at = .{ .path = app_manifest }, .message =
        \\This project names a data program in `"build"."data"`, and its `main` does not say
        \\`Browser.prerenderData`, so the build neither builds nor runs it. Make `main` a
        \\`Browser.prerenderData`, or take `"data"` out (`docs/design/prerender.md` §8.5).
        }) catch return fail(stderr, "beni: out of memory", .{});
    }
    // The data program's build, which lives until the build's last render
    // (`prerender.md` §8.5 item 2).
    var data: ?DataBuild = null;
    defer if (data) |*d| d.deinit(io);
    // `prerender.md` §5.1: the prerender tree first, run under Node, and
    // what it gave handed to the client tree's build, which writes the pages
    // or refuses the build.
    if (says) |s| {
        // `"build"."origin"` (`prerender.md` §7.3, `frontend.md` §10.1): what
        // an application's routes are `Url`s below.
        // A page below the root, `blog/hello.html`, names its entry by a
        // path from the base, so the base must be absolute (`prerender.md`
        // §5.3), and a route's `Url` has it in its path (§7.3).
        if (build.base.len == 0 or build.base[0] != '/') {
            return fail(stderr, "beni: this program prerenders, and beni.json's \"build\" \"base\" must then be an absolute URL path, beginning with '/', not '{s}'", .{build.base});
        }
        const origin: ?[]const u8 = if (app) |m| m.build.origin else null;
        if (origin) |o| if (!validOrigin(o)) {
            return fail(stderr, "beni: beni.json's \"build\" \"origin\" must be an http or https origin with no path, as \"https://example.com\", not '{s}'", .{o});
        };
        emit_options.origin = origin;
        emit_options.routed = s.routed;
        emit_options.app_root = app_root;
        if (origin) |o| emit_options.address = std.fmt.allocPrint(arena, "{s}{s}", .{ o, std.mem.trimEnd(u8, build.base, "/") }) catch
            return fail(stderr, "beni: out of memory", .{});
        emit_options.data = s.data;
        if (s.data) data = buildData(gpa, io, arena, options_in, build, app_root, data_config.?, options.cache, stderr) catch |err| switch (err) {
            error.OutOfMemory => return fail(stderr, "beni: out of memory", .{}),
            error.Failed => return 2,
        };
        const tree = prerender(gpa, io, arena, &session, emit_options, options.path, stderr, options.diagnostics == .text, if (data) |*d| d else null, !build.no_prerender) catch |err| switch (err) {
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
            .ran => |outcome| emit_options.prerender = if (build.no_prerender) .{ .fresh = outcome } else .{ .client = outcome },
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
        const late = gpa.alloc(Session.LateItem, result.diagnostics.len + extra_late.items.len) catch
            return fail(stderr, "beni: out of memory", .{});
        defer gpa.free(late);
        for (result.diagnostics, late[0..result.diagnostics.len]) |item, *slot| {
            slot.* = .{ .code = item.code, .file = item.file, .token = item.token, .end_token = item.end_token, .message = item.message, .at = item.at, .severity = item.severity };
        }
        @memcpy(late[result.diagnostics.len..], extra_late.items);
        // The data program's warnings, with the site's (§8.5 item 2).
        if (data) |d| session.foreign = d.foreign;
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
    \\appendFileSync(records, JSON.stringify({ routes }) + "\n");
    \\for (const route of routes) {
    \\  const page = render(route);
    \\  const record = typeof page === "string" ? { route, html: page } : { route, html: page[0], title: page[1] };
    \\  appendFileSync(records, JSON.stringify(record) + "\n");
    \\}
    \\
;

/// The runner of a data site's prerender tree (`prerender.md` §8.5 item
/// 5): the routes and each page's text are read from the file the build
/// wrote from the data program's records, and each page is
/// `render(route, text)` — the HTML, a document's `[html, title]`, or the
/// issues of a text the site's schema cannot decode, `{ issues }`.
const node_data_runner =
    \\// Generated by `beni build` (docs/design/prerender.md §8.5): a data site's
    \\// prerender tree run under Node, one record per page appended to the
    \\// records file, each rendered from its page's text.
    \\import { appendFileSync, readFileSync } from "node:fs";
    \\import { render } from "./
++ Emit.prerender_entry ++
    \\";
    \\
    \\const records = process.argv[2];
    \\const pages = readFileSync(process.argv[3], "utf8").split("\n").filter((line) => line !== "").map((line) => JSON.parse(line));
    \\appendFileSync(records, JSON.stringify({ routes: pages.map((page) => page.route) }) + "\n");
    \\for (const { route, text } of pages) {
    \\  const page = render(route, text);
    \\  const record = typeof page === "string" ? { route, html: page } : Array.isArray(page) ? { route, html: page[0], title: page[1] } : { route, issues: page.issues };
    \\  appendFileSync(records, JSON.stringify(record) + "\n");
    \\}
    \\
;

const node_runner_file = "_node.mjs";
const records_file = "_records.jsonl";
/// The pages of a data site, as the tree's runner reads them.
const pages_file = "_pages.jsonl";

/// A record of the prerender tree's run: the first is the route list, each
/// after it one route's page, a document's with its title, or a data site's
/// page whose text did not decode, with its issues.
const Record = struct {
    routes: ?[]const []const u8 = null,
    route: ?[]const u8 = null,
    html: ?[]const u8 = null,
    title: ?[]const u8 = null,
    issues: ?[]const []const u8 = null,
};

/// `prerender.md` §5.1, items 1, 2 and 4: the prerender tree built into a
/// directory of its own beside `--out`, run under the `node` on `PATH`,
/// and removed. A tree the build refuses — `prerender_impure`, a shell with
/// no `{{view}}` — is the build's failure, its diagnostics rendered; one
/// that ran gives the client tree what it needs to write the page or to
/// refuse the build.
///
/// A data site's (§8.5): `data`, the data program, built already, is
/// refused with the tree in one render; then it runs, its routes are
/// checked, and the tree renders each page from its text. Under
/// `--no-prerender` (`tree` false) no tree is built: the pages are the data
/// program's, with no view (§8.10).
fn prerender(gpa: Allocator, io: Io, arena: Allocator, session: *Session, client: Emit.Options, path: ?[]const u8, stderr: *Io.Writer, text: bool, data: ?*DataBuild, wanted: bool) (Emit.Error || error{NodeFailed})!Tree {
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
    if (wanted) if (Io.Dir.cwd().access(io, dir, .{})) |_| {
        Io.Dir.cwd().access(io, try std.fs.path.join(arena, &.{ dir, OutputRecord.file_name }), .{}) catch {
            stderr.print("beni: cannot prerender: '{s}' is there, and it is not a prerender tree beni wrote\n", .{dir}) catch {};
            return error.NodeFailed;
        };
    } else |_| {};
    var built: Emit.Result = if (wanted) try emitOnBigStack(gpa, arena, session, tree) else .{ .diagnostics = &.{}, .files_written = 0, .bytes_written = 0 };
    defer if (wanted) built.deinit(gpa);
    const refused = for (built.diagnostics) |d| {
        if (d.severity == .@"error") break true;
    } else false;
    // Written, the tree goes when the run is over, whatever it gave.
    defer if (wanted and !refused) Io.Dir.cwd().deleteTree(io, dir) catch {};
    // The site, the data program and the tree are one render (§8.5 item 2).
    if (refused or (data != null and data.?.refused)) {
        const late = try gpa.alloc(Session.LateItem, built.diagnostics.len);
        defer gpa.free(late);
        for (built.diagnostics, late) |item, *slot| {
            slot.* = .{ .code = item.code, .file = item.file, .token = item.token, .end_token = item.end_token, .message = item.message, .at = item.at, .severity = item.severity };
        }
        if (data) |d| session.foreign = d.foreign;
        _ = session.renderLate(late, stderr) catch return .{ .refused = 2 };
        return .{ .refused = 1 };
    }
    // Only `PATH` is searched: Zig's own search falls back to a default
    // path when there is none, and the build must not find a `node` there.
    const node = findOnPath(io, arena, path, "node") orelse return .{ .ran = .needs_node };
    // A data site's pages, from its data program's run (§8.5 items 3–4).
    var given: ?[]const Emit.Prerender.Page = null;
    if (data) |d| {
        switch (try runData(gpa, io, arena, d, node, stderr, text)) {
            .failed => |item| {
                session.foreign = try d.session.exportLate(arena, &.{item});
                _ = session.renderLate(&.{}, stderr) catch return .{ .refused = 2 };
                return .{ .refused = 1 };
            },
            .needs_node => return .{ .ran = .needs_node },
            .pages => |pages| given = pages,
        }
        // A route the rules refuse is refused before anything renders
        // (§8.5 item 4): the pages are the routes alone.
        for (given.?) |page| if (Emit.routeFault(page.route) != null) return .{ .ran = .{ .pages = given.? } };
        if (!wanted) return .{ .ran = .{ .pages = given.? } };
    }
    // The client tree's build reports its warnings again: the tree's are
    // the same, and dropped.
    const runner = try std.fs.path.join(arena, &.{ dir, node_runner_file });
    const records = try std.fs.path.join(arena, &.{ dir, records_file });
    Io.Dir.cwd().writeFile(io, .{ .sub_path = runner, .data = if (data != null) node_data_runner else node_runner }) catch |err| {
        session.io_failure = .{ .path = runner, .err = err };
        return error.OutputPath;
    };
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ node, runner, records });
    if (given) |pages| {
        // Each page's route and text, the text the page will hold (§8.5
        // item 5), a JSON line each.
        var lines: std.Io.Writer.Allocating = .init(arena);
        for (pages) |page| {
            std.json.Stringify.value(.{ .route = page.route, .text = page.data.? }, .{}, &lines.writer) catch return error.OutOfMemory;
            lines.writer.writeByte('\n') catch return error.OutOfMemory;
        }
        const file = try std.fs.path.join(arena, &.{ dir, pages_file });
        Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = lines.written() }) catch |err| {
            session.io_failure = .{ .path = file, .err = err };
            return error.OutputPath;
        };
        try argv.append(arena, file);
    }
    const ran = std.process.run(gpa, io, .{ .argv = argv.items }) catch |err| switch (err) {
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
    const not_records = "Its records file holds a line that is not a record of the prerender tree.";
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var routes: ?[]const []const u8 = null;
    var pages: std.ArrayList(Emit.Prerender.Page) = .empty;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const record = std.json.parseFromSliceLeaky(Record, arena, line, .{}) catch
            return .{ .ran = .{ .failed = .{ .route = null, .why = not_records } } };
        if (routes == null) {
            routes = record.routes orelse return .{ .ran = .{ .failed = .{ .route = null, .why = not_records } } };
            // A route the build would refuse is refused whatever its render
            // did (`prerender.md` §7.4): the pages are the routes alone.
            for (routes.?) |route| if (Emit.routeFault(route) != null) {
                const all = try arena.alloc(Emit.Prerender.Page, routes.?.len);
                for (all, routes.?) |*p, r| p.* = .{ .route = r, .html = "" };
                return .{ .ran = .{ .pages = all } };
            };
            continue;
        }
        const n = pages.items.len;
        const route = record.route orelse return .{ .ran = .{ .failed = .{ .route = null, .why = not_records } } };
        if (n >= routes.?.len or !std.mem.eql(u8, route, routes.?[n]))
            return .{ .ran = .{ .failed = .{ .route = null, .why = "Its records file holds a record of a route the build did not list, or out of the list's order." } } };
        // A page's text the site's schema cannot decode (§8.5 item 5).
        if (record.issues) |issues| return .{ .ran = .{ .invalid = .{ .route = route, .issues = issues } } };
        try pages.append(arena, .{
            .route = route,
            .html = record.html orelse return .{ .ran = .{ .failed = .{ .route = null, .why = not_records } } },
            .title = record.title,
            .data = if (given) |g| g[n].data else null,
        });
    }
    const listed = routes orelse {
        // No record at all: the route list threw, or Node did not run it.
        const why = if (exited) "Node ended with no record of the route list." else try thrown(arena, ran.stderr);
        return .{ .ran = .{ .failed = .{ .route = null, .why = why } } };
    };
    if (exited and pages.items.len == listed.len) return .{ .ran = .{ .pages = pages.items } };
    if (pages.items.len == listed.len) return .{ .ran = .{ .failed = .{ .route = null, .why = try thrown(arena, ran.stderr) } } };
    const why = if (exited) "Node ended with no record of it." else try thrown(arena, ran.stderr);
    return .{ .ran = .{ .failed = .{ .route = listed[pages.items.len], .why = why } } };
}

// ---- The data program (`prerender.md` §8.2, §8.3, §8.5) -------------------

/// A data site's data program, built for `node` into its own directory
/// beside `--out`, by a second session over the same cache. It lives until
/// the build's last render: its diagnostics are rendered with the site's,
/// and their paths and texts are its own.
const DataBuild = struct {
    session: *Session,
    /// `.<out>.data` (§8.3), removed with the build.
    dir: []const u8,
    /// The data program's diagnostics, for the site's render.
    foreign: Session.Foreign = .{},
    /// It has an error: the build stops before anything runs.
    refused: bool = false,
    /// Where its `main` is, which `prerender_data_failed` points at.
    main: ?struct { file: SourceStore.Index, token: u32 } = null,

    fn deinit(d: *DataBuild, io: Io) void {
        Io.Dir.cwd().deleteTree(io, d.dir) catch {};
        d.session.deinit();
    }
};

/// The data program built (§8.5 item 2): `"build"."data"`'s paths, below the
/// project root, checked and emitted for `node` in development mode with
/// no source maps, whatever the site's mode. A path that cannot be read is
/// the build's exit-2 failure, written here; `error.Failed` then.
fn buildData(gpa: Allocator, io: Io, arena: Allocator, options_in: Session.Options, build: Cli.Build, app_root: []const u8, config: Manifest.Build.Data, cache: ?*const CacheDir, stderr: *Io.Writer) (Allocator.Error || error{Failed})!DataBuild {
    var options = options_in;
    options.core_package = true;
    options.platform = "node";
    options.cache_build_id = build.cache.build_id;
    options.manifest_root = app_root;
    // Its paths are below the project root and each its own source root:
    // the site's `--root`, which names the site's modules, is not theirs.
    options.root = null;
    options.informational = true;
    options.explain = build.common.explain;
    options.defer_render = true;
    options.cache = cache;
    var chain_failure: ?platform.Failure = null;
    const chain = try arena.create(platform.Chain);
    chain.* = platform.resolveChain(arena, io, "node", &chain_failure) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => {
            _ = platform.report(stderr, chain_failure.?);
            return error.Failed;
        },
    };
    options.chain = chain;
    options.ownership = true;
    const here = app_root.len == 0 or std.mem.eql(u8, app_root, ".");
    const paths = try arena.alloc([]const u8, config.paths.len);
    for (config.paths, paths) |p, *slot| slot.* = if (here) p else try std.fs.path.join(arena, &.{ app_root, p });
    const session = try arena.create(Session);
    session.* = Session.init(gpa, io, options) catch return error.OutOfMemory;
    var d: DataBuild = .{ .session = session, .dir = try dataDir(arena, build.out) };
    errdefer d.deinit(io);
    d.main = null;
    const summary = session.run(paths, Session.check_phases, stderr) catch |err| switch (err) {
        error.InputPath => {
            const failure = session.io_failure.?;
            _ = fail(stderr, "beni: cannot read '{s}': {t}", .{ failure.path, failure.err });
            return error.Failed;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| {
            _ = fail(stderr, "beni: {t}", .{e});
            return error.Failed;
        },
    };
    if (Emit.mainPlace(session)) |m| d.main = .{ .file = m.file, .token = m.token };
    if (summary.errors > 0) {
        d.foreign = try session.exportLate(arena, &.{});
        d.refused = true;
        return d;
    }
    var loaded = platform.load(arena, session, chain, true) catch |err| {
        _ = platform.reportLoad(stderr, "node", err);
        return error.Failed;
    };
    loaded.platform.base = build.base;
    var result = emitOnBigStack(gpa, arena, session, .{
        .out_dir = d.dir,
        .platform = loaded.platform,
        .embedded = loaded.embedded,
        .release = false,
        .source_maps = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OutputPath, error.OutputRecordUnreadable => {
            const failure = session.io_failure.?;
            _ = fail(stderr, "beni: cannot write '{s}': {t}", .{ failure.path, failure.err });
            return error.Failed;
        },
    };
    defer result.deinit(gpa);
    const late = try arena.alloc(Session.LateItem, result.diagnostics.len);
    for (result.diagnostics, late) |item, *slot| {
        slot.* = .{ .code = item.code, .file = item.file, .token = item.token, .end_token = item.end_token, .message = try arena.dupe(u8, item.message), .at = item.at, .severity = item.severity };
        if (item.severity == .@"error") d.refused = true;
    }
    d.foreign = try session.exportLate(arena, late);
    return d;
}

/// What running the data program gave (§8.3): each page's route and text,
/// escaped as the page holds it (§8.6), or `prerender_data_failed` as an
/// item of the data program's session.
const DataRun = union(enum) {
    pages: []const Emit.Prerender.Page,
    needs_node,
    failed: Session.LateItem,
};

/// A record of the data program's run (§8.3).
const DataRecord = struct {
    route: ?[]const u8 = null,
    data: ?[]const u8 = null,
    issues: ?[]const []const u8 = null,
    @"error": ?[]const u8 = null,
    end: ?u64 = null,
};

/// The data program run under Node, its working directory the project's
/// root and its records written to a file of its directory (§8.3, §8.5
/// item 3).
fn runData(gpa: Allocator, io: Io, arena: Allocator, d: *DataBuild, node: []const u8, stderr: *Io.Writer, text: bool) (Emit.Error || error{NodeFailed})!DataRun {
    const entry = Io.Dir.cwd().realPathFileAlloc(io, try std.fs.path.join(arena, &.{ d.dir, Emit.default_entry_file }), arena) catch |err| {
        d.session.io_failure = .{ .path = d.dir, .err = err };
        return error.OutputRecordUnreadable;
    };
    const records = try std.fs.path.join(arena, &.{ std.fs.path.dirname(entry).?, records_file });
    const root = d.session.options.manifest_root orelse ".";
    const ran = std.process.run(gpa, io, .{ .argv = &.{ node, entry, records }, .cwd = .{ .path = root } }) catch |err| switch (err) {
        error.FileNotFound => return .needs_node,
        else => {
            stderr.print("beni: cannot run node: {t}\n", .{err}) catch {};
            return error.NodeFailed;
        },
    };
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    // What the data program wrote — a `Debug.log`, a `Log` line — goes to
    // the build's standard error, as the tree's does (§5.1).
    if (text) {
        stderr.writeAll(ran.stdout) catch {};
        stderr.writeAll(ran.stderr) catch {};
    }
    const bytes: []const u8 = Io.Dir.cwd().readFileAlloc(io, records, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => "",
        else => {
            d.session.io_failure = .{ .path = records, .err = err };
            return error.OutputRecordUnreadable;
        },
    };
    var pages: std.ArrayList(Emit.Prerender.Page) = .empty;
    var ended = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const record = std.json.parseFromSliceLeaky(DataRecord, arena, line, .{}) catch
            return failedRun(d, arena, "it wrote a line that is not one of its records: its `main` must be `Prerender.pages`.", .{});
        if (ended) return failedRun(d, arena, "it wrote a line after its last record.", .{});
        if (record.@"error") |why| return failedRun(d, arena, "its body gave `Err`:\n\n{s}", .{why});
        if (record.issues) |issues| return failedRun(d, arena, "its schema cannot encode the value it gave for the route `{s}`:\n\n{s}", .{ record.route orelse "?", try std.mem.join(arena, "\n", issues) });
        if (record.end) |n| {
            if (n != pages.items.len) return failedRun(d, arena, "its last record counts {d} pages, and it wrote {d}.", .{ n, pages.items.len });
            ended = true;
            continue;
        }
        const route = record.route orelse return failedRun(d, arena, "it wrote a line that is not one of its records: its `main` must be `Prerender.pages`.", .{});
        const raw = record.data orelse return failedRun(d, arena, "it wrote a line that is not one of its records: its `main` must be `Prerender.pages`.", .{});
        const escaped = pageText(arena, raw) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotRecords => return failedRun(d, arena, "the text it gave for the route `{s}` holds a control character or is not UTF-8, which `Prerender.pages` never writes.", .{route}),
        };
        try pages.append(arena, .{ .route = route, .html = "", .data = escaped });
    }
    if (ended) {
        const exited = switch (ran.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (exited) return .{ .pages = pages.items };
    }
    const why = if (ran.term == .exited and ran.term.exited == 0)
        "it ended without its records: its `main` must be `Prerender.pages`."
    else
        try std.fmt.allocPrint(arena, "it ended with an error:\n\n{s}", .{try thrown(arena, ran.stderr)});
    return failedRun(d, arena, "{s}", .{why});
}

fn failedRun(d: *DataBuild, arena: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!DataRun {
    const why = try std.fmt.allocPrint(arena, fmt, args);
    const message = try std.fmt.allocPrint(arena,
        \\This is the data program of a site whose pages are made from its values, and {s}
        \\
        \\The build runs it once, under Node, before it writes any page
        \\(`docs/design/prerender.md` §8.3).
    , .{why});
    const m = d.main orelse return .{ .failed = .{ .code = .prerender_data_failed, .file = @enumFromInt(0), .token = 0, .at = .{ .path = d.dir }, .message = message } };
    return .{ .failed = .{ .code = .prerender_data_failed, .file = m.file, .token = m.token, .message = message } };
}

/// A data program's JSON text as a page holds it (§8.6): every `<` as
/// `\u003c` and every character past U+007E as a `\u` escape, a character
/// past U+FFFF as its two surrogates, so the text is ASCII and no `</script`
/// or `<!--` can end the script. A character below U+0020, or bytes that
/// are not UTF-8, were not written by `Prerender.pages`.
fn pageText(arena: Allocator, raw: []const u8) (Allocator.Error || error{NotRecords})![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c < 0x20) return error.NotRecords;
        if (c == '<') {
            try out.appendSlice(arena, "\\u003c");
            i += 1;
            continue;
        }
        if (c < 0x7f) {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch return error.NotRecords;
        if (i + len > raw.len) return error.NotRecords;
        const point = std.unicode.utf8Decode(raw[i .. i + len]) catch return error.NotRecords;
        if (point > 0xffff) {
            const v = point - 0x10000;
            try out.print(arena, "\\u{x:0>4}\\u{x:0>4}", .{ 0xd800 + (v >> 10), 0xdc00 + (v & 0x3ff) });
        } else try out.print(arena, "\\u{x:0>4}", .{point});
        i += len;
    }
    return out.items;
}

test "a page's text is ASCII, with no `<`" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("{\"a\":\"\\u003c/script>\"}", try pageText(a, "{\"a\":\"</script>\"}"));
    try std.testing.expectEqualStrings("\"caf\\u00e9 \\u2028 \\ud83d\\ude00 \\u007f\"", try pageText(a, "\"café \u{2028} \u{1F600} \x7f\""));
    try std.testing.expectError(error.NotRecords, pageText(a, "\"a\nb\""));
    try std.testing.expectError(error.NotRecords, pageText(a, "\"\xff\""));
}

/// The data program's directory: `.<out>.data` beside `--out`, named and
/// placed as the prerender tree's is (§8.3, §5.1 item 1, amended).
fn dataDir(arena: Allocator, out: []const u8) Allocator.Error![]const u8 {
    const trimmed = std.mem.trimEnd(u8, out, "/");
    const base = std.fs.path.basename(trimmed);
    const parent = std.fs.path.dirname(trimmed) orelse ".";
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return std.fs.path.join(arena, &.{ if (trimmed.len == 0) "/" else trimmed, ".beni-data" });
    return std.fs.path.join(arena, &.{ parent, try std.fmt.allocPrint(arena, ".{s}.data", .{base}) });
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

/// Whether `origin` is what `"build"."origin"` names (`frontend.md` §10.1):
/// `http://` or `https://`, a host of ASCII letters, digits, `.` and `-`,
/// and at most a port — no path, query or fragment, nor anything that
/// could end the string a page's code holds it in.
pub fn validOrigin(origin: []const u8) bool {
    const rest = if (std.mem.startsWith(u8, origin, "https://"))
        origin["https://".len..]
    else if (std.mem.startsWith(u8, origin, "http://"))
        origin["http://".len..]
    else
        return false;
    const colon = std.mem.indexOfScalar(u8, rest, ':');
    const host = rest[0 .. colon orelse rest.len];
    if (host.len == 0) return false;
    for (host) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-') return false;
    if (colon) |at| {
        const port = rest[at + 1 ..];
        if (port.len == 0 or port.len > 5) return false;
        for (port) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

test "an origin is a scheme, a host and at most a port" {
    try std.testing.expect(validOrigin("https://example.com"));
    try std.testing.expect(validOrigin("http://localhost:8000"));
    try std.testing.expect(!validOrigin("https://example.com/"));
    try std.testing.expect(!validOrigin("ftp://example.com"));
    try std.testing.expect(!validOrigin("https://"));
    try std.testing.expect(!validOrigin("https://a\"b"));
}

fn fail(stderr: *Io.Writer, comptime format_string: []const u8, args: anytype) u8 {
    stderr.print(format_string ++ "\n", args) catch {};
    return 2;
}
