//! What reading a column of a `MultiArrayList` costs against a plain slice,
//! for the node shape of `Shape.Table` (4 M random reads over 60 k six-field
//! nodes): `items(.kind)[i]` (what `Shape.Table.kind` does), `get(i).place`
//! (what `Shape.Table.get` does), a plain `ArrayList` column, and a column
//! hoisted once. Compare the self-hosted backend with LLVM:
//!
//!     zig build-exe -OReleaseFast -fno-llvm soa.zig && ./soa
//!     zig build-exe -OReleaseFast soa.zig && ./soa
//!
//! Not a gate: nothing runs it.

const std = @import("std");
const Kind = enum(u8) { a, b, c, d, e, f, g, h };
const Node = struct { kind: Kind, place: u32, cells: u32, a: u32, b: u32, reach: u32 };
fn now() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
const T = struct {
    nodes: std.MultiArrayList(Node) = .empty,
    kinds: std.ArrayList(Kind) = .empty, // the same column, kept on its own
    fn kindMal(t: *const T, n: u32) Kind {
        return t.nodes.items(.kind)[n];
    }
    fn getMal(t: *const T, n: u32) Node {
        return t.nodes.get(n);
    }
    fn kindCol(t: *const T, n: u32) Kind {
        return t.kinds.items[n];
    }
};
pub fn main() !void {
    const gpa = std.heap.smp_allocator;
    var t: T = .{};
    const n: u32 = 60_000;
    var x: u32 = 1;
    for (0..n) |i| {
        x = x *% 1664525 +% 1013904223;
        try t.nodes.append(gpa, .{ .kind = @fromBackingInt(@intCast(x >> 29)), .place = x, .cells = x >> 3, .a = @intCast(i), .b = x >> 7, .reach = 0 });
        try t.kinds.append(gpa, @fromBackingInt(@intCast(x >> 29)));
    }
    const idx = try gpa.alloc(u32, 4_000_000);
    for (idx) |*p| {
        x = x *% 1664525 +% 1013904223;
        p.* = x % n;
    }
    var sink: u64 = 0;
    var best = [4]u64{ ~@as(u64, 0), ~@as(u64, 0), ~@as(u64, 0), ~@as(u64, 0) };
    for (0..5) |_| {
        var t0 = now();
        for (idx) |i| sink +%= @backingInt(t.kindMal(i));
        best[0] = @min(best[0], now() - t0);
        t0 = now();
        for (idx) |i| sink +%= t.getMal(i).place;
        best[1] = @min(best[1], now() - t0);
        t0 = now();
        for (idx) |i| sink +%= @backingInt(t.kindCol(i));
        best[2] = @min(best[2], now() - t0);
        t0 = now();
        const s = t.nodes.slice();
        const ks = s.items(.kind);
        for (idx) |i| sink +%= @backingInt(ks[i]);
        best[3] = @min(best[3], now() - t0);
    }
    const f = @as(f64, @floatFromInt(idx.len));
    std.debug.print("MAL.items(.kind)[i]={d:.2}ns  MAL.get(i).place={d:.2}ns  column[i]={d:.2}ns  slice-once[i]={d:.2}ns  (sink {d})\n", .{ @as(f64, @floatFromInt(best[0])) / f, @as(f64, @floatFromInt(best[1])) / f, @as(f64, @floatFromInt(best[2])) / f, @as(f64, @floatFromInt(best[3])) / f, sink % 7 });
}
