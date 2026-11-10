//! L6: where a hoisted read is bound (`docs/design/ownership-v2.md` §2.8,
//! *Record lowering boundary*, *the hoist rows*). An accepted record write
//! hoists each of the frame's later reads of a written field: the lowering
//! binds the read to a temporary before the write. A row says the read by
//! its instructions and where the temporary is made.
//!
//! Obligations kept here: O12's placement half (a temporary is made after
//! the holder's binding and before the write that the read must not see).

const std = @import("std");
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Regions = @import("Regions.zig");

const none: u32 = Ids.none_int;

/// The rows of the events `events` (indices of `w.events`) that the write at instruction `point` hoists,
/// by their read, in `arena`.
pub fn rows(arena: std.mem.Allocator, w: anytype, regions: *const Regions.Tree, point: u32, events: []const u32) std.mem.Allocator.Error![]const Facts.Hoist {
    if (events.len == 0 or @import("Mutate.zig").on(.hoist_rows_lost)) return &.{};
    const out = try arena.alloc(Facts.Hoist, events.len);
    const update = w.bir.instTag(@fromBackingInt(point)) == .record_update;
    for (events, out) |ei, *o| {
        const ev = w.events.items[ei];
        // A field capture is read where its closure is made, and named by the access in the lambda.
        const at = placement(w, regions, point, ev.point);
        const read = if (ev.read != none) ev.read else ev.point;
        o.* = .{ .read = read, .outer = outer(w, read), .holder = ev.local, .binding = ev.binding, .capture = if (ev.read != none) ev.point else none, .placement = at, .phase = @intFromBool(update and at == point) };
    }
    std.mem.sort(Facts.Hoist, out, {}, struct {
        fn lt(_: void, a: Facts.Hoist, b: Facts.Hoist) bool {
            return a.outer < b.outer or (a.outer == b.outer and a.binding < b.binding);
        }
    }.lt);
    return out;
}

/// `before`, and a row for each field capture of walk `w`: read where its closure is made (§2.11.4).
pub fn captures(arena: std.mem.Allocator, w: anytype, before: []const Facts.Hoist) std.mem.Allocator.Error![]const Facts.Hoist {
    var n: usize = 0;
    for (w.events.items) |ev| n += @intFromBool(ev.read != none);
    if (n == 0 or @import("Mutate.zig").on(.capture_rows_lost)) return before;
    const out = try arena.alloc(Facts.Hoist, before.len + n);
    @memcpy(out[0..before.len], before);
    var at = before.len;
    for (w.events.items) |ev| if (ev.read != none) {
        // A capture alone reads its whole source chain when the closure is made (v1's row: the full path).
        const last = outer(w, ev.read);
        out[at] = .{ .read = last, .outer = last, .holder = ev.local, .capture = ev.point, .placement = ev.point, .phase = 0 };
        at += 1;
    };
    return out;
}

fn parentOf(w: anytype, inst: u32) u32 {
    const i = inst -% w.code.decl.inst_start.int();
    return if (i < w.parents.len) w.parents[i] else none;
}

/// The last access of the source chain that the access `read` is in: `r.a.b` for the read of `r.a`.
fn outer(w: anytype, read: u32) u32 {
    var at = read;
    while (true) {
        const p = parentOf(w, at);
        if (p == none) return at;
        const tag = w.bir.instTag(@fromBackingInt(p));
        if ((tag != .field_access and tag != .tuple_index) or w.bir.instData(@fromBackingInt(p)).lhs != at) return at;
        at = p;
    }
}

/// Where the read at `read` is bound for the write at `point`. A read in the write's region, or in one
/// inside it, comes after the write on every path: at the write. Else the two are in arms that part: before
/// the instruction that holds the write, below the lowest instruction that holds both.
fn placement(w: anytype, regions: *const Regions.Tree, point: u32, read: u32) u32 {
    const dr = regions.regionOf(point);
    var rr = regions.regionOf(read);
    while (rr != .none) : (rr = regions.get(rr).parent) if (rr == dr) return point;
    if (@import("Mutate.zig").on(.hoist_at_write)) return point;
    var x = point;
    while (true) {
        const p = parentOf(w, x);
        if (p == none) return point;
        var y = read;
        while (y != none) : (y = parentOf(w, y)) if (y == p) return x;
        x = p;
    }
}
