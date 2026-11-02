//! Source-on-disk closed-box coverage for public resident Session clients.
const std = @import("std");
const world = @import("world.zig");
const testing = std.testing;

test "resident Session corpus replaces diagnostics while retaining embedded core" {
    try residentDiagnostics(null);
}

test "resident Session corpus replaces diagnostics while retaining disk core" {
    const a = testing.allocator;
    const core = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, "core", a);
    defer a.free(core);
    try residentDiagnostics(core);
}

fn residentDiagnostics(core_root: ?[]const u8) !void {
    const a = testing.allocator;
    const exe = try testing.environ.getAlloc(a, "BENI_SESSION_DRIVER");
    defer a.free(exe);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const golden = try std.Io.Dir.cwd().readFileAlloc(testing.io, "tests/corpus/session/diagnostic-wave/expected.jsonl", a, .unlimited);
    defer a.free(golden);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "fixtures", .default_dir);
    for ([_][]const u8{ "warning.beni", "error.beni", "repaired.beni" }) |name| {
        const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, try std.fs.path.join(arena.allocator(), &.{ "tests/corpus/session/diagnostic-wave", name }), arena.allocator(), .unlimited);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fs.path.join(arena.allocator(), &.{ "fixtures", name }), .data = source });
    }
    const argv: []const []const u8 = if (core_root) |core| &.{ exe, "fixtures", core } else &.{ exe, "fixtures" };
    const r = try world.spawnAndCapture(arena.allocator(), a, testing.io, argv, .{ .dir = tmp.dir }, world.default_timeout_ms);

    if (r.exit_code != 0) std.debug.print("{s}\n", .{r.stderr});
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stderr);
    try testing.expectEqualStrings(golden, r.stdout);
}
