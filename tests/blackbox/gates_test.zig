//! What `zig build gates` refuses before it runs anything (`build.zig`,
//! `gatesRefusal`). A green gate says that every test ran and met the
//! budget as CLAUDE.md states it (*Every test has a budget*): one count, of
//! binaries built for the reference CPU, so a gate held to another budget
//! or built for another CPU is not the gate.
//!
//! Each test runs one child `zig build` in the repository root, which costs
//! about a billion instructions with the build runner cached; the build
//! that runs this test has cached it. `BENI_ZIG_EXE` comes from `build.zig`.

const std = @import("std");
const testing = std.testing;
const world = @import("world.zig");

/// `zig build gates <option>` in the repository root, which must fail
/// before it runs anything and name `option` in the reason.
fn expectRefused(option: []const u8, named: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zig = try testing.environ.getAlloc(arena, "BENI_ZIG_EXE");
    var env = try testing.environ.createMap(arena);

    const r = try world.spawnAndCaptureIn(arena, testing.io, &.{ zig, "build", "gates", option }, .inherit, world.default_timeout_ms, &env);

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
