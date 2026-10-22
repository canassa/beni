//! Gates refuse filters and deliberate checker mutations.
//! Child builds reuse the parent maker on Linux and its local cache.

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
    try testing.expect(std.mem.indexOf(u8, r.stderr, named) != null);
}

test "gates refuses an ownership checker broken on purpose" {
    try expectRefused("-Downership-record-mutation=hoist-whole", "drop -Downership-record-mutation");
}

test "gates refuses a corpus filter" {
    try expectRefused("-Dcorpus=Adt", "drop -Dtest-filter and -Dcorpus");
}

test "gates accepts a CPU without the former reference features" {
    // The sentinel stops this child before it builds or runs another suite.
    try expectRefused("-Dcpu=baseline", "`gates` was not refused");
}

test "a hung test times out and names itself" {
    try expectProbe("timeout", 1, "FAIL: test timed out: hang guard probe");
}

test "a finished test cancels its hang guard" {
    try expectProbe("cancel", 0, "");
}

fn expectProbe(mode: []const u8, exit_code: u8, stderr: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const option = try std.fmt.allocPrint(arena, "--hang-guard-probe={s}", .{mode});
    const r = try world.spawnAndCapture(arena, testing.allocator, testing.io, &.{ runner.executable, option }, .inherit, world.default_timeout_ms);
    try testing.expectEqual(exit_code, r.exit_code);
    if (exit_code == 0) try testing.expectEqualStrings(stderr, r.stderr) else try testing.expect(std.mem.indexOf(u8, r.stderr, stderr) != null);
}
