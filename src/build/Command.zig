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

    var session = Session.init(gpa, io, options) catch return fail(stderr, "beni: out of memory", .{});
    defer session.deinit();

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

    const emit_token = session.profile.begin();
    var result = emitOnBigStack(gpa, arena, &session, .{
        .out_dir = build.out,
        .platform = loaded.platform,
        .embedded = loaded.embedded,
        .library = build.library,
        .release = build.release,
        .allow_debug = build.allow_debug,
        .source_maps = build.source_maps,
    }) catch |err| switch (err) {
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
            slot.* = .{ .code = item.code, .file = item.file, .token = item.token, .message = item.message, .at = item.at };
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
    const thread = std.Thread.spawn(.{ .stack_size = Session.check_stack_size }, Runner.go, .{&runner}) catch {
        // No thread to be had: emit here and hope the trees are shallow,
        // which they are for everything but the pathological inputs.
        return Emit.run(gpa, arena, session, options, &session.io_failure);
    };
    thread.join();
    return runner.result;
}

fn fail(stderr: *Io.Writer, comptime format_string: []const u8, args: anytype) u8 {
    stderr.print(format_string ++ "\n", args) catch {};
    return 2;
}
