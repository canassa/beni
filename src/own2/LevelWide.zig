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
    if (!pl.cyclic(pl.pathPlace(q)) or @import("Mutate.zig").on(.level_wide_off)) return;
    const r = try pl.foldsUp(g, f.gc(), q);
    var k: u32 = 0;
    while (k < r.len) : (k += 1) {
        const t = pl.foldPath(r.start + k);
        if (coveredBy(pl, r, t)) continue;
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

/// Whether another target is above `t`: its arrivals cover `t` by the rest of the words.
fn coveredBy(pl: *const Place.Table, r: Ids.Range, t: PathId) bool {
    var k: u32 = 0;
    while (k < r.len) : (k += 1) {
        const o = pl.foldPath(r.start + k);
        if (o != t and pl.isPrefix(o, t)) return true;
    }
    return false;
}
