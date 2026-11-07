//! L8: a construction over its base (`docs/design/ownership-v2.md` §2.13.2,
//! R-2.3), split from `Walk`: the walker is `k`.
//!
//! Obligations kept here: none of §2.14's directly (it makes a demand).

const std = @import("std");
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Place = @import("Place.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");

const Error = Ids.ChargeError;
const none: u32 = Ids.none_int;
const Step = Place.Step;

/// A construction over its base (R-2.3): the base's storage is written
/// in place, the other items are its new elements.
/// `spread`: which items are lists whose elements go in (every one of a
/// `++` chain); the others are elements.
pub fn of(k: anytype, i: u32, items: []const u32, kind: Facts.DemandKind, base: u32, spread: ?[]const bool) Error!u32 {
    const fr = k.f();
    var ev: Relation.Eval = .{ .f = fr, .contracts = undefined, .arena = fr.arena };
    defer ev.deinit();
    const bv = try k.valueOf(base);
    const t_start: u32 = @intCast(k.w.leaf_runs.items.len);
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(k.gpa);
    try ev.storageOf(bv, 0, &ls);
    try k.w.leaf_runs.appendSlice(k.gpa, ls.items);
    const o_start: u32 = @intCast(k.w.value_runs.items.len);
    var ks: std.ArrayList(u32) = .empty;
    defer ks.deinit(k.gpa);
    const flags = try fr.arena.alloc(u32, items.len);
    for (items, 0..) |e, n| {
        const v = try k.valueOf(e);
        const sp = if (spread) |sps| sps[n] else true;
        flags[n] = @intFromBool(sp or e == base);
        if (e != base) try k.w.value_runs.append(k.gpa, v);
        // A spread item gives its elements, a family of unknown length.
        try ks.append(k.gpa, if (sp or e == base) try k.project(v, .plain, Step.elem.word(), 0) else v);
        try k.consume(e, i);
    }
    const pend = try k.pendingRun();
    try k.w.demands.append(k.gpa, .{
        .point = i,
        .kind = kind,
        .token = k.token(i),
        .base_inst = base,
        .targets = .{ .start = t_start, .len = @intCast(ls.items.len) },
        .operands = .{ .start = o_start, .len = @intCast(k.w.value_runs.items.len - o_start) },
        .pending = pend,
        .base_value = bv,
    });
    // The result is the base's storage holding every item's elements.
    return fr.mk(.{ .kind = .built, .form = .list, .site = none, .head = bv + 1, .place = try k.placeOf(i), .kids = try fr.mkKids(ks.items), .extra = flags });
}
