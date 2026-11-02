// DEBUG-SLOTBUILD: temporary phase profiler, removed before commit.
const std = @import("std");
const Ids = @import("Ids.zig");
pub var on: bool = false;
pub var plain: bool = false;
pub fn enabled() bool {
    return on;
}
pub const Snap = struct { t: u64, by: [Ids.Category.count]u64 };
pub fn snap(a: *const Ids.Account) Snap {
    var s: Snap = .{ .t = a.total(), .by = a.baseline_by };
    for (a.growth_by, 0..) |g, i| s.by[i] += g;
    return s;
}
pub fn report(label: []const u8, x: u32, a: *const Ids.Account, s0: Snap) void {
    if (!enabled()) return;
    const s1 = snap(a);
    std.debug.print("PROF {s} {d}: {d}", .{ label, x, s1.t - s0.t });
    for (s1.by, s0.by, 0..) |b, c, i| if (b != c) std.debug.print(" {t}={d}", .{ @as(Ids.Category, @enumFromInt(i)), b - c });
    std.debug.print("\n", .{});
}
