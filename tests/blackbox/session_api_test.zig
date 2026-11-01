//! Source-on-disk closed-box coverage for public resident Session clients.
const std = @import("std");
const world = @import("world.zig");
const testing = std.testing;

test "resident Session corpus replaces cached warning error and repaired diagnostics" {
    const a = testing.allocator;
    const exe = try testing.environ.getAlloc(a, "BENI_SESSION_DRIVER");
    defer a.free(exe);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const golden = try std.Io.Dir.cwd().readFileAlloc(testing.io, "tests/corpus/session/diagnostic-wave/expected.json", a, .unlimited);
    defer a.free(golden);
    for ([_][]const u8{ "1", "8" }) |jobs| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDir(testing.io, "fixtures", .default_dir);
        for ([_][]const u8{ "warning.beni", "error.beni", "repaired.beni" }) |name| {
            const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, try std.fs.path.join(arena.allocator(), &.{ "tests/corpus/session/diagnostic-wave", name }), arena.allocator(), .unlimited);
            try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fs.path.join(arena.allocator(), &.{ "fixtures", name }), .data = source });
        }
        const r = try world.spawnAndCapture(arena.allocator(), a, testing.io, &.{ exe, "fixtures", jobs }, .{ .dir = tmp.dir }, world.default_timeout_ms);
        if (r.exit_code != 0) std.debug.print("{s}\n", .{r.stderr});
        try testing.expectEqual(@as(u8, 0), r.exit_code);
        try testing.expectEqualStrings("", r.stderr);
        try testing.expectEqualStrings(golden, r.stdout);
    }
}
