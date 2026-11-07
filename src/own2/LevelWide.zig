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
const Replay = @import("Replay.zig");
const PathsTo = @import("PathsTo.zig");
const Trees = @import("Trees.zig");
const LevelTargets = @import("LevelTargets.zig");

const PathId = Ids.PathId;

pub const Said = struct { at: PathId, a: Trees.Arrival };

/// What arrival `a`, open at result slot `q`, says at each fold target above
/// `q`: at target `t`, each canonical path a walk from `a`'s own path first
/// reaches `t`'s place on (`PathsTo`), and the levels below each. The walk
/// starts at the path, so a third lap is one of its folds, and a slot routes
/// fold onto is met once.
pub fn of(f: anytype, g: std.mem.Allocator, arena: std.mem.Allocator, q: PathId, a: Trees.Arrival, out: *std.ArrayList(Said)) Ids.ChargeError!void {
    const pl = f.places;
    if (!LevelTargets.hasMiddle(pl, pl.pathPlace(q)) or @import("Mutate.zig").on(.level_wide_off)) return;
    var ts: std.ArrayList(PathId) = .empty;
    try LevelTargets.of(f, g, arena, q, &ts);
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(g);
    var ps: std.ArrayList(u32) = .empty;
    defer ps.deinit(g);
    for (ts.items) |t| {
        if (LevelTargets.coveredBy(pl, ts.items, t)) continue;
        if (!hasSteps(pl, a)) {
            try out.append(arena, .{ .at = t, .a = a });
            continue;
        }
        if (std.debug.runtime_safety) std.debug.assert(pl.pathPlace(.from(a.path)) == pl.pathPlace(q));
        seen.clearRetainingCapacity();
        ps.clearRetainingCapacity();
        try PathsTo.of(g, f.account, pl, .from(a.path), pl.pathPlace(t), &ps);
        const arrivals = ps.items.len;
        for (0..arrivals) |i| try Replay.replay(g, f.account, pl, .from(ps.items[i]), &.{Place.Step.level.word()}, &ps);
        for (ps.items) |p| {
            if ((try seen.getOrPut(g, .{p})).found_existing) continue;
            var x = a;
            x.slot = try f.slots.relOf(g, f.account, pl, .from(p));
            x.path = p;
            try out.append(arena, .{ .at = t, .a = x });
        }
    }
}

/// Whether a step taken at `a` names another object than `a` itself. Not an
/// atom's, which is the same at every slot. Not a deep arrival's at a type
/// variable or an opaque, or `self` (`Made`): all of it at any step, so it is
/// said as it is. A label's answer has no path: its only way here is what a
/// `⊤` lies inside (`ReadOff.describeOrigin`), and that `⊤` is said at every
/// target first, so what a reader takes from the answer can only add.
fn hasSteps(pl: *const Place.Table, a: Trees.Arrival) bool {
    if (a.path == Ids.none_int) return false;
    const k = pl.kind(pl.pathPlace(.from(a.path)));
    return k != .@"var" and k != .@"opaque";
}
