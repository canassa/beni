//! What `zig build gates` refuses before it runs anything (`build.zig`,
//! `gatesRefusal`). A green gate says that every test ran and met the
//! budget as CLAUDE.md states it (*Every test has a budget*): one count, of
//! binaries built for the reference CPU in the gates' own mode, so a gate
//! held to another budget, built for another CPU or in another mode is not
//! the gate.
//!
//! Each test runs one child `zig build` in the repository root, which costs
//! about a billion instructions when its build runner is cached. The child
//! gets this build's local cache (the runner's `cache_dir`) and inherits
//! its global one (`ZIG_GLOBAL_CACHE_DIR`, the only way `zig build` takes
//! one), where this build compiled that runner. `BENI_ZIG_EXE` comes from
//! `build.zig`.

const std = @import("std");
const testing = std.testing;
const world = @import("world.zig");
const runner = @import("root");

/// `zig build gates <option>` in the repository root, which must fail
/// before it runs anything and name what to drop in its reason.
fn expectRefused(option: []const u8, named: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ try testing.environ.getAlloc(arena, "BENI_ZIG_EXE"), "build", "gates", option });
    if (runner.cache_dir.len != 0) try argv.appendSlice(arena, &.{ "--cache-dir", runner.cache_dir });
    var env = try testing.environ.createMap(arena);

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
