//! L4: what an open arrival says at the `⟲`s above it
//! (`docs/design/ownership-v2.md` §2.1, *A level read on a built value*).
//! A slot below an open node can fold out of the node's words: `#P.0⟲#Leaf.0`
//! is below `#P.0#Wrap.0`. A reader walks a slot's words from the root
//! (`Forest.atSlot`), so it meets that arrival only if it is said at the fold.
//!
//! Obligations kept here: O6 (`⟲` covers every level of a result, and each
//! slot of a level is said once).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Trees = @import("Trees.zig");
const LevelTargets = @import("LevelTargets.zig");

const PathId = Ids.PathId;

pub const Said = struct { at: PathId, a: Trees.Arrival };

/// What arrival `a`, open at result slot `q`, says at each fold target above
/// `q`: `t` itself, the topmost of them only. An arrival a step goes on from
/// is the parameter read at its own slot (`ReadOff`): a result slot below `q`
/// is the same parameter slot, since `Place.extend` reads only the path and
/// the step, so `t` needs no walk, and `coveredBy` holds by the words. At `t`
/// above `q` it is `t`'s own; elsewhere a copy (`Arrival.level_copy`), which
/// a read of every slot skips (`Relation.feedAt`): `q`'s holds all it holds.
pub fn of(f: anytype, g: std.mem.Allocator, arena: std.mem.Allocator, q: PathId, a: Trees.Arrival, out: *std.ArrayList(Said)) Ids.ChargeError!void {
    const pl = f.places;
    if (!LevelTargets.hasMiddle(pl, pl.pathPlace(q)) or @import("Mutate.zig").on(.level_wide_off)) return;
    var ts: std.ArrayList(PathId) = .empty;
    try LevelTargets.of(f, g, arena, q, &ts);
    for (ts.items) |t| {
        if (LevelTargets.coveredBy(pl, ts.items, t)) continue;
        if (!hasSteps(pl, a)) {
            try out.append(arena, .{ .at = t, .a = a });
            continue;
        }
        if (std.debug.runtime_safety) std.debug.assert(a.path == q.int());
        var x = a;
        x.slot = try f.slots.relOf(g, f.account, pl, t);
        x.path = if (pl.isPrefix(t, q)) t.int() else Trees.Arrival.level_copy;
        try out.append(arena, .{ .at = t, .a = x });
    }
}

/// Whether a step taken at `a` names another object than `a` itself. Not an
/// atom's, which is the same at every slot. Not a deep arrival's at a type
/// variable or an opaque, or `self` (`Made`): all of it at any step, so it is
/// said as it is. A label's answer has no path: its only way here is what a
/// `⊤` lies inside (`ReadOff.describeOrigin`), and that `⊤` is said at every
/// target first, so what a reader takes from the answer can only add.
fn hasSteps(pl: *const Place.Table, a: Trees.Arrival) bool {
    if (a.path == Ids.none_int or a.path == Trees.Arrival.level_copy) return false;
    const k = pl.kind(pl.pathPlace(.from(a.path)));
    return k != .@"var" and k != .@"opaque";
}
