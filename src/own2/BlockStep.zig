//! L13: one step of a relative slot in a block (`docs/design/ownership-v2.md` §3.6),
//! split from `Block`. A step is `(kind, a, b)`, a row's excluded names following it.
//!
//! Obligations kept here: none of §2.14's directly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Place = @import("Place.zig");
const RowSets = @import("RowSets.zig");

const Step = Place.Step;

/// One step as `(kind, a, b)`.
pub fn write(w: anytype, wd: u32) Allocator.Error!void {
    const s = Step.fromWord(wd);
    switch (s.kind) {
        .field => try w.out.appendSlice(w.gpa, &.{ @backingInt(s.kind), w.names.field(w.names.ctx, s.payload), 0 }),
        .ctor_arg => {
            const ca = w.places.ctorArgOf(s);
            try w.out.appendSlice(w.gpa, &.{ @backingInt(s.kind), ca[0], ca[1] });
        },
        .row => {
            try w.out.appendSlice(w.gpa, &.{ @backingInt(s.kind), 0, 0 });
            try RowSets.write(w.gpa, w.out, w.places.rowNames(s), w.names.ctx, w.names.field);
        },
        else => try w.out.appendSlice(w.gpa, &.{ @backingInt(s.kind), s.payload, 0 }),
    }
}

/// One step `(kind, a, b)` as this module's step word.
pub fn read(r: anytype) !u32 {
    const kind = try r.next();
    const a = try r.next();
    const b = try r.next();
    if (kind > @backingInt(Place.StepKind.row)) return error.BadBlock;
    const k: Place.StepKind = @fromBackingInt(@intCast(kind));
    const s: Step = switch (k) {
        .field => blk: {
            const rank = r.remap.field(r.remap.ctx, a) orelse return error.BadBlock;
            (try r.field_string.getOrPut(r.gpa, .{rank})).value_ptr.* = a;
            break :blk try Step.field(r.account, rank);
        },
        .ctor_arg => try r.places.ctorStep(r.gpa, r.account, a, b),
        .row => blk: {
            const ranks = try r.arena.alloc(u32, try r.count());
            for (ranks) |*n| n.* = try rowName(r);
            std.mem.sort(u32, ranks, {}, std.sort.asc(u32));
            break :blk try r.places.rowStep(r.gpa, r.account, ranks);
        },
        else => .{ .kind = k, .payload = @intCast(a & 0x0fff_ffff) },
    };
    return s.word();
}

fn rowName(r: anytype) !u32 {
    const st = try r.next();
    const rank = r.remap.field(r.remap.ctx, st) orelse return error.BadBlock;
    (try r.field_string.getOrPut(r.gpa, .{rank})).value_ptr.* = st;
    return rank;
}
