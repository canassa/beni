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
const SourceStore = @import("../SourceStore.zig");
const Emit = @import("../js/Emit.zig");
const beni_profile = @import("../Profile.zig");
const Manifest = @import("../js/Manifest.zig");
const core_package = @import("core_package");
const platform_packages = @import("platform_packages");

pub fn run(gpa: Allocator, io: Io, stdout: *Io.Writer, stderr: *Io.Writer, options_in: Session.Options, build: Cli.Build) u8 {
    var options = options_in;
    // A build resolves every name against core and against the platform,
    // and type-checks: all three are part of the input (checker.md §4,
    // boundary.md §5.3).
    options.core_package = true;
    options.platform = build.platform;
    options.manifest_root = build.common.root orelse ".";
    // `check` and `build` are the two subcommands that emit the
    // informational warnings of static-dispatch-spike.md §10 (A.83) — which
    // is why the run's own wave is held back: the emit phase below can add
    // to it, and the two together are ONE array on stderr.
    options.informational = true;
    options.defer_render = true;

    var session = Session.init(gpa, io, options) catch return fail(stderr, "beni: out of memory", .{});
    defer session.deinit();

    const summary = session.run(build.paths, Session.check_phases, stderr) catch |err| switch (err) {
        error.InputPath => {
            const failure = session.io_failure.?;
            return fail(stderr, "beni: cannot read '{s}': {t}", .{ failure.path, failure.err });
        },
        else => |e| return fail(stderr, "beni: {t}", .{e}),
    };
    if (session.platform_error) {
        return fail(
            stderr,
            "beni: unknown platform '{s}'; give the name of a platform that ships with the compiler ({s}) or a directory holding one",
            .{ build.platform, embedded_names },
        );
    }
    if (summary.errors > 0) {
        _ = session.renderLate(&.{}, stderr) catch return 2;
        return 1;
    }

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const platform = resolvePlatform(arena, io, &session) catch |err| switch (err) {
        error.OutOfMemory => return fail(stderr, "beni: out of memory", .{}),
        error.NoManifest => return fail(
            stderr,
            "beni: '{s}' has no {s}; a platform package declares itself one with \"platform\": true",
            .{ build.platform, Manifest.file_name },
        ),
        error.NotAPlatform => return fail(
            stderr,
            "beni: '{s}' is not a platform package; its {s} must say \"platform\": true",
            .{ build.platform, Manifest.file_name },
        ),
        error.Incomplete => return fail(
            stderr,
            "beni: '{s}' does not declare what `main` is; its {s} needs \"program\" and \"runtime\"",
            .{ build.platform, Manifest.file_name },
        ),
        error.Malformed => return fail(
            stderr,
            "beni: cannot read '{s}/{s}': it is not a JSON object",
            .{ session.platform_root, Manifest.file_name },
        ),
    };

    const embedded = collectEmbedded(arena, &session) catch return fail(stderr, "beni: out of memory", .{});

    const emit_token = session.profile.begin();
    var result = emitOnBigStack(gpa, arena, &session, .{
        .out_dir = build.out,
        .platform = platform,
        .embedded = embedded,
        .library = build.library,
        .release = build.release,
    }) catch |err| switch (err) {
        error.OutOfMemory => return fail(stderr, "beni: out of memory", .{}),
        error.OutputPath => {
            const failure = session.io_failure.?;
            return fail(stderr, "beni: cannot write '{s}': {t}", .{ failure.path, failure.err });
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
            slot.* = .{ .code = item.code, .file = item.file, .token = item.token, .message = item.message };
        }
        const errors = session.renderLate(late, stderr) catch return 2;
        if (errors > 0) return 1;
    }

    // A successful build prints NOTHING, on either stream. `frontend.md` §1
    // gives stdout to the product and stderr to diagnostics and nothing
    // else, and a build's product is the files it wrote — so there is no
    // stream left for a summary line, and `check` already sets the
    // precedent. How much was written is a `--self-profile` counter, which
    // is also where M4's incrementality tests will read it.
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

const PlatformError = error{
    NoManifest,
    NotAPlatform,
    Incomplete,
    Malformed,
} || Allocator.Error;

/// What the platform package says about itself (boundary.md §5.2). The
/// embedded platforms carry their manifest bytes in the binary; a directory
/// is read from disk. Either way the answer comes from the manifest and not
/// from a table in the compiler, which is what makes a Bun or Deno platform
/// a package rather than a compiler change (§5.1).
fn resolvePlatform(arena: Allocator, io: Io, session: *Session) PlatformError!Emit.Platform {
    if (session.platform_manifest.len == 0) {
        const read = Manifest.read(arena, io, session.platform_root) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Malformed => return error.Malformed,
            error.ReadFailed => return error.NoManifest,
        } orelse return error.NoManifest;
        return finish(read, session.platform_root);
    }
    const manifest = Manifest.parse(arena, session.platform_manifest) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Malformed => return error.Malformed,
    };
    return finish(manifest, session.platform_root);
}

fn finish(manifest: Manifest, root: []const u8) PlatformError!Emit.Platform {
    if (!manifest.platform) return error.NotAPlatform;
    return .{
        .program = manifest.program orelse return error.Incomplete,
        .runtime = manifest.runtime orelse return error.Incomplete,
        .root = root,
    };
}

/// Every file the compiler carries that the build may have to copy out:
/// core's siblings, and the chosen platform's siblings and runtime. A
/// platform read from a directory contributes nothing here and is read from
/// disk instead.
fn collectEmbedded(arena: Allocator, session: *Session) Allocator.Error![]const Emit.Asset {
    var out: std.ArrayList(Emit.Asset) = .empty;
    // A `--core-root` run reads core from disk, so the embedded copy must
    // not shadow it.
    if (session.options.core_root == null) {
        for (core_package.assets) |asset| {
            try out.append(arena, .{ .path = asset.path, .bytes = asset.bytes });
        }
    }
    for (platform_packages.platforms) |platform| {
        if (!std.mem.eql(u8, platform.root, session.platform_root)) continue;
        for (platform.assets) |asset| {
            try out.append(arena, .{ .path = asset.path, .bytes = asset.bytes });
        }
    }
    return out.items;
}

/// The names `--platform` accepts without a directory, for the error
/// message. Built at comptime because the platform table is.
const embedded_names = blk: {
    var text: []const u8 = "";
    for (platform_packages.platforms, 0..) |platform, i| {
        text = text ++ (if (i == 0) "" else ", ") ++ platform.name;
    }
    break :blk text;
};

fn fail(stderr: *Io.Writer, comptime format_string: []const u8, args: anytype) u8 {
    stderr.print(format_string ++ "\n", args) catch {};
    return 2;
}
