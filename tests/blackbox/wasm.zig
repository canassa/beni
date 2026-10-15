//! What `wasm_test.zig` and `playground_test.zig` share
//! (docs/design/playground.md §6): the compilers with no threads, and one
//! command run by two compilers and compared byte for byte.
//!
//! The command runs twice, on two copies of one project: `threaded/`, with
//! the compiler under test (`BENI_EXE`, the threaded ReleaseSafe one), and
//! `other/`, with a compiler with no threads — the native one
//! (`BENI_SINGLE_EXE`) or a `.wasm` (`BENI_WASM`) run as a command by
//! `tests/wasm/beni.mjs` on the playground's own WASI host. Then the exit
//! codes, both streams and every file of the two directories must be the
//! same bytes, except the persistent cache's directory: its keys name the
//! compiler that wrote it (`fast-compiler.md` §8).
//!
//! Nothing here imports a compiler internal: `std` and the harness.

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;

/// The script that runs a `.wasm` as a command, relative to the repo root
/// the build step pins as the test's working directory.
pub const driver = "tests/wasm/beni.mjs";

/// The cache directory a build writes by default, left out of the
/// comparison.
const cache_dir = ".beni-cache";

/// How a native compiler with no threads is started on Linux: from
/// `/bin/sh`, with the soft stack limit of a login shell, 8 MiB. The hard
/// limit stays the one the test inherits (unlimited where the gates run).
/// The test runner raises its own soft limit to 256 MiB and every child
/// inherits it, so without this a compiler that declares too small a main
/// stack would still pass. With it, Zig's start code raises the soft limit
/// to the stack the executable declares, as it does for a user
/// (`fast-compiler.md` §10, *A build with no threads*); a hard limit under
/// that stack would fail the test for a reason that is not the compiler's.
const shell_stack = "ulimit -S -s 8192 && exec \"$0\" \"$@\"";

/// The native compiler with no threads, by absolute path, when the run has
/// one (`build.zig` sets `BENI_SINGLE_EXE` on `wasm_test.zig`'s runs).
pub fn singleExePath(arena: std.mem.Allocator) ?[]const u8 {
    const value = testing.environ.getAlloc(arena, "BENI_SINGLE_EXE") catch return null;
    return if (value.len == 0) null else value;
}

/// The WebAssembly compiler, by absolute path, when the run has one: the
/// gates' ReleaseSafe build, or the playground's shipped one.
pub fn wasmPath(arena: std.mem.Allocator) ?[]const u8 {
    const value = testing.environ.getAlloc(arena, "BENI_WASM") catch return null;
    return if (value.len == 0) null else value;
}

/// The compiler the threaded one is compared with.
pub const Other = union(enum) {
    /// A native compiler, by absolute path. On Linux it starts as a login
    /// shell starts it (`shell_stack`).
    native: []const u8,
    /// A `.wasm`, by absolute path, run by `driver` under Node.
    wasm: []const u8,
};

/// One file of a project: where it goes, and its bytes.
pub const File = struct { path: []const u8, bytes: []const u8 };

/// Write `files` into `threaded/` and `other/` of the world's project. Run
/// once per project; a world compares any number of commands on it.
pub fn writeProject(w: *World, files: []const File) !void {
    const arena = w.arena.allocator();
    for ([_][]const u8{ "threaded", "other" }) |side| {
        for (files) |f| try w.write(try std.fs.path.join(arena, &.{ side, f.path }), f.bytes);
    }
}

/// `writeProject` with one file read from the repository (the test's
/// working directory), under its own name.
pub fn writeRepoFile(w: *World, repo_path: []const u8) !void {
    const arena = w.arena.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(w.io, repo_path, arena, .limited(16 * 1024 * 1024));
    try writeProject(w, &.{.{ .path = std.fs.path.basename(repo_path), .bytes = bytes }});
}

/// What one run left: its exit code and its two streams.
pub const Run = struct { exit_code: u8, stdout: []const u8, stderr: []const u8 };

/// Run `beni <args>` in `threaded/` with the compiler under test and in
/// `other/` with `other`, and fail unless both runs agree on everything:
/// the exit code, both streams, and every file of the two directories.
/// Returns the threaded run, for a test that also asserts what it did.
pub fn expectSame(w: *World, args: []const []const u8, other: Other) !Run {
    return expectSameIgnoring(w, args, other, &.{});
}

/// `expectSame`, leaving the files `ignore` names (paths relative to each
/// side) out of the comparison: a `--self-profile` trace, whose times differ
/// from run to run.
pub fn expectSameIgnoring(w: *World, args: []const []const u8, other: Other, ignore: []const []const u8) !Run {
    const arena = w.arena.allocator();
    const threaded = try w.runWith(args, .{
        .raw_diagnostics = true,
        .cwd = .{ .path = try w.projectSubPath(arena, "threaded") },
    });
    const theirs = switch (other) {
        .native => |exe| try runNative(w, exe, args),
        .wasm => |path| try runWasm(w, path, args),
    };
    const command = try std.mem.join(arena, " ", args);
    if (theirs.term != .exited) {
        std.debug.print("`beni {s}` with no threads did not exit: {any}\n--- stderr ---\n{s}\n", .{ command, theirs.term, theirs.stderr });
        return error.CompilerCrashed;
    }
    errdefer std.debug.print("`beni {s}` differs between the threaded compiler and the one with no threads\n", .{command});
    try testing.expectEqual(threaded.exit_code, theirs.exit_code);
    try testing.expectEqualStrings(threaded.stdout, theirs.stdout);
    try testing.expectEqualStrings(threaded.stderr, theirs.stderr);
    const ours = try treeOf(w, "threaded", ignore);
    const their_files = try treeOf(w, "other", ignore);
    if (!sameList(ours, their_files)) {
        for (ours) |path| if (!contains(their_files, path)) std.debug.print("only the threaded compiler wrote {s}\n", .{path});
        for (their_files) |path| if (!contains(ours, path)) std.debug.print("only the compiler with no threads wrote {s}\n", .{path});
        return error.DifferentFiles;
    }
    for (ours, their_files) |a, b| {
        try testing.expectEqualStrings(a, b);
        const left = try w.read(try std.fs.path.join(arena, &.{ "threaded", a }));
        const right = try w.read(try std.fs.path.join(arena, &.{ "other", b }));
        if (!std.mem.eql(u8, left, right)) {
            std.debug.print("{s} differs\n", .{a});
            try testing.expectEqualStrings(left, right);
        }
    }
    return .{ .exit_code = threaded.exit_code, .stdout = threaded.stdout, .stderr = threaded.stderr };
}

/// `<exe> <args>` in `other/`, from `/bin/sh` on Linux (`shell_stack`).
fn runNative(w: *World, exe: []const u8, args: []const []const u8) !world.Result {
    const arena = w.arena.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    if (@import("builtin").os.tag == .linux) try argv.appendSlice(arena, &.{ "/bin/sh", "-c", shell_stack });
    try argv.append(arena, exe);
    try argv.appendSlice(arena, args);
    return world.spawnAndCapture(arena, w.gpa, w.io, argv.items, .{ .path = try w.projectSubPath(arena, "other") }, world.default_timeout_ms);
}

/// `node --liftoff-only tests/wasm/beni.mjs <wasm> <args>` in `other/`.
fn runWasm(w: *World, wasm: []const u8, args: []const []const u8) !world.Result {
    const arena = w.arena.allocator();
    const node = w.node_exe orelse return error.NodeNotOnPath;
    const script = try std.Io.Dir.cwd().realPathFileAlloc(w.io, driver, arena);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ node, "--liftoff-only", script, wasm });
    try argv.appendSlice(arena, args);
    return world.spawnAndCapture(arena, w.gpa, w.io, argv.items, .{ .path = try w.projectSubPath(arena, "other") }, world.default_timeout_ms);
}

fn contains(paths: []const []const u8, path: []const u8) bool {
    for (paths) |p| if (std.mem.eql(u8, p, path)) return true;
    return false;
}

fn sameList(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// Every file under `side`, as sorted paths relative to it, without the
/// cache's and without those `ignore` names.
fn treeOf(w: *World, side: []const u8, ignore: []const []const u8) ![]const []const u8 {
    const all = try w.listFiles(side);
    var kept: std.ArrayList([]const u8) = .empty;
    for (all) |path| {
        if (std.mem.startsWith(u8, path, cache_dir ++ "/")) continue;
        if (contains(ignore, path)) continue;
        try kept.append(w.arena.allocator(), path);
    }
    return kept.items;
}

/// Counter `name` of the `--self-profile` trace at `trace` in the project of
/// `side` (`threaded` or `other`): the value of its `C` event
/// (`fast-compiler.md` §12, `src/Profile.zig`).
pub fn profileCounter(w: *World, side: []const u8, trace: []const u8, name: []const u8) !i64 {
    const arena = w.arena.allocator();
    const bytes = try w.read(try std.fs.path.join(arena, &.{ side, trace }));
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    const events = root.object.get("traceEvents") orelse return error.NotATrace;
    for (events.array.items) |event| {
        const ph = event.object.get("ph") orelse continue;
        const event_name = event.object.get("name") orelse continue;
        if (!std.mem.eql(u8, ph.string, "C") or !std.mem.eql(u8, event_name.string, name)) continue;
        const args = event.object.get("args") orelse return error.NotATrace;
        const value = args.object.get(name) orelse return error.NotATrace;
        return value.integer;
    }
    std.debug.print("{s}/{s} has no counter {s}\n", .{ side, trace, name });
    return error.NoSuchCounter;
}
