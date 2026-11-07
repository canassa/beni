//! L4: what an open arrival says at the `⟲`s above it
//! (`docs/design/ownership-v2.md` §2.1, *A level read on a built value*).
//! A slot below an open node can fold out of the node's words: `#P.0⟲#Leaf.0`
//! is below `#P.0#Wrap.0`. A reader walks a slot's words from the root
//! (`Forest.atSlot`), so it meets that arrival only if it is said at the fold.
//!
//! Obligations kept here: O6 (`⟲` covers every level of a result).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const StepsTo = @import("StepsTo.zig");
const Trees = @import("Trees.zig");

const PathId = Ids.PathId;

pub const Said = struct { at: PathId, a: Trees.Arrival };

/// What arrival `a`, open at result slot `q`, says at each fold target above
/// `q`: at target `t`, the arrival's slot by every route to `t`'s place, and
/// by the levels below each.
pub fn of(f: anytype, g: std.mem.Allocator, arena: std.mem.Allocator, q: PathId, a: Trees.Arrival, out: *std.ArrayList(Said)) Ids.ChargeError!void {
    const pl = f.places;
    if (!hasMiddle(pl, pl.pathPlace(q)) or @import("Mutate.zig").on(.level_wide_off)) return;
    var ts: std.ArrayList(PathId) = .empty;
    try targets(f, g, arena, q, &ts);
    for (ts.items) |t| {
        if (coveredBy(pl, ts.items, t)) continue;
        if (a.kind != .param and a.kind != .lent) {
            try out.append(arena, .{ .at = t, .a = a });
            continue;
        }
        var routes: std.ArrayList([]const u32) = .empty;
        try StepsTo.of(g, arena, f.account, pl, try pl.rootPath(g, pl.pathPlace(q)), pl.pathPlace(t), &routes);
        const base = f.slots.relWords(a.slot);
        for (routes.items) |to| for ([_]bool{ false, true }) |level| {
            var w: std.ArrayList(u32) = .empty;
            try w.appendSlice(arena, base);
            try w.appendSlice(arena, to);
            if (level) try w.append(arena, Place.Step.level.word());
            var x = a;
            x.slot = try f.slots.relOfWords(g, f.account, pl, w.items);
            x.path = Ids.none_int;
            try out.append(arena, .{ .at = t, .a = x });
        };
    }
}

/// Whether `p`'s cycle holds another place: on a cycle of one place, a first
/// return's levels fold below it, so an open arrival has no fold outside its words.
fn hasMiddle(pl: *const Place.Table, p: Ids.PlaceId) bool {
    for (pl.steps(p).children) |c| if (c != p and pl.sameCycle(c, p)) return true;
    return false;
}

/// The levels above `q` on its cycle: each `⟲` and first return on the cycle
/// suffix of its path, a return by its level paths. As long as the suffix.
fn targets(f: anytype, g: std.mem.Allocator, arena: std.mem.Allocator, q: PathId, out: *std.ArrayList(PathId)) Ids.ChargeError!void {
    const pl = f.places;
    const place = pl.pathPlace(q);
    var at = pl.pathParent(q);
    while (at != .none and pl.pathParent(at) != .none and pl.sameCycle(pl.pathPlace(at), place)) : (at = pl.pathParent(at)) {
        try f.charge(.path, 1);
        if (pl.pathStep(at).kind == .level) {
            try out.append(arena, at);
        } else if (pl.isReturn(at)) {
            if (try pl.levelPaths(g, f.gc(), at)) |r| {
                var k: u32 = 0;
                while (k < r.len) : (k += 1) try out.append(arena, pl.foldPath(r.start + k));
            } else if (try pl.extend(g, f.gc(), at, Place.Step.level)) |t| try out.append(arena, t);
        }
    }
}

/// Whether another target is above `t`: its arrivals cover `t` by the rest of the words.
fn coveredBy(pl: *const Place.Table, ts: []const PathId, t: PathId) bool {
    for (ts) |o| if (o != t and pl.isPrefix(o, t)) return true;
    return false;
}
