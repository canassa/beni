//! What `zig build gates` refuses before it runs anything (`build.zig`,
//! `gatesRefusal`). A green gate says that every test ran and met the
//! budget as CLAUDE.md states it (*Every test has a budget*): one count, of
//! binaries built for the reference CPU in the gates' own mode, so a gate
//! held to another budget, built for another CPU or in another mode is not
//! the gate.
//!
//! Each test runs one child build in the repository root, which costs about
//! a billion instructions when nothing has to be compiled for it. Two things
//! are compiled for a `zig build`, and the child must find both:
//!
//! - The configure script, `build.zig` itself, lives in the local cache.
//!   The child gets this build's (the runner's `cache_dir`), where this build
//!   compiled it.
//! - The build runner Zig calls the maker lives in the global cache, keyed
//!   by Zig's version string and the files of its library. Every Zig of the
//!   same version on the machine shares that key, so a second build of Zig
//!   0.17.0 (another Nix derivation, another project's) evicts this one's
//!   maker, and a `zig build` started after that compiles it again: a
//!   ReleaseSafe LLVM build, about a minute on a quiet machine and several under
//!   load, far past the child's timeout. So on Linux the child does not ask
//!   `zig build` for a maker at all: it runs the one running this build, the
//!   parent process, through `/proc/<ppid>/exe` (which works even after the
//!   file is gone from the cache), with the four arguments Zig gave it. Off
//!   Linux, where the gates do not run, the child is `zig build`
//!   (`BENI_ZIG_EXE` comes from `build.zig`).
//!
//! The child also gets `BENI_GATES_REFUSAL_TEST`, so a gate that is not
//! refused fails before it builds anything, instead of running a whole gate
//! (and this test again) inside the test.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const world = @import("world.zig");
const runner = @import("root");

/// What `zig build` hands the maker ahead of the command's own arguments
/// (Zig's `main.zig`, `jitCmd`, for `build`), five entries: the command,
/// then the four arguments the maker reads before any other.
const maker_prefix = [_][]const u8{ "build", "--zig-lib=", "--zig=", "--global-cache=", "--seed=" };

/// Appends the start of a child build's argv: the maker running this build
/// with its own leading arguments on Linux, `zig build` elsewhere.
fn appendBuildCommand(arena: std.mem.Allocator, argv: *std.ArrayList([]const u8)) !void {
    if (builtin.os.tag != .linux) {
        try argv.appendSlice(arena, &.{ try testing.environ.getAlloc(arena, "BENI_ZIG_EXE"), "build" });
        return;
    }
    const ppid = std.os.linux.getppid();
    const cmdline_path = try std.fmt.allocPrint(arena, "/proc/{d}/cmdline", .{ppid});
    // Read as a stream: a `/proc` file's stat says it is empty.
    const cmdline_file = try std.Io.Dir.cwd().openFile(testing.io, cmdline_path, .{});
    defer cmdline_file.close(testing.io);
    var cmdline_reader = cmdline_file.readerStreaming(testing.io, &.{});
    const cmdline = try cmdline_reader.interface.allocRemaining(arena, .limited(world.max_stream_bytes));
    var args = std.mem.splitScalar(u8, std.mem.trimEnd(u8, cmdline, "\x00"), 0);
    _ = args.next(); // the maker's path in the global cache, which may be gone
    try argv.append(arena, try std.fmt.allocPrint(arena, "/proc/{d}/exe", .{ppid}));
    for (maker_prefix, 0..) |expected, i| {
        const arg = args.next() orelse "";
        const matches = if (i == 0) std.mem.eql(u8, arg, expected) else std.mem.startsWith(u8, arg, expected);
        if (!matches) {
            std.debug.print("this test runs under `zig build`, whose maker spawns it; process {d} is not one, or a new Zig lays out the maker's arguments differently (`maker_prefix`): {s}\n", .{ ppid, cmdline });
            return error.NotSpawnedByZigBuild;
        }
        try argv.append(arena, arg);
    }
}

/// `zig build gates <option>` in the repository root, which must fail
/// before it runs anything and name what to drop in its reason.
fn expectRefused(option: []const u8, named: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    try appendBuildCommand(arena, &argv);
    try argv.appendSlice(arena, &.{ "gates", option });
    if (runner.cache_dir.len != 0) try argv.appendSlice(arena, &.{ "--cache-dir", runner.cache_dir });
    var env = try testing.environ.createMap(arena);
    try env.put("BENI_GATES_REFUSAL_TEST", "1");

    const r = try world.spawnAndCaptureIn(arena, testing.io, argv.items, .inherit, world.default_timeout_ms, &env);

    if (r.exit_code == 0 or std.mem.indexOf(u8, r.stderr, named) == null)
        std.debug.print("--- stdout ---\n{s}\n--- stderr ---\n{s}\n", .{ r.stdout, r.stderr });
    try testing.expect(r.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "`gates` holds every test to the budget on the reference build") != null);
    try testing.expect(std.mem.indexOf(u8, r.stderr, named) != null);
}

test "gates refuses a run held to another budget" {
    try expectRefused("-Dtest-budget=9000", "drop -Dtest-budget");
}

test "gates refuses binaries built for another CPU" {
    try expectRefused("-Dcpu=baseline", "drop -Dcpu");
}

test "gates refuses binaries built in another mode" {
    try expectRefused("--release=fast", "drop -Doptimize and --release");
}
