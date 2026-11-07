//! L4: where an open arrival is said above its slot, split from `LevelWide`
//! (`docs/design/ownership-v2.md` §2.1, *A level read on a built value*): the
//! levels above a result slot on its cycle.
//!
//! Obligations kept here: O6 (`⟲` covers every level of a result: no level above is missed).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");

const PathId = Ids.PathId;

/// Whether `p`'s cycle holds another place: on a cycle of one place, a first
/// return's levels fold below it, so an open arrival has no fold outside its words.
pub fn hasMiddle(pl: *const Place.Table, p: Ids.PlaceId) bool {
    for (pl.steps(p).children) |c| if (c != p and pl.sameCycle(c, p)) return true;
    return false;
}

/// The levels above `q` on its cycle: each `⟲` and first return on the cycle
/// suffix of its path, a return by its level paths. As long as the suffix.
pub fn of(f: anytype, g: std.mem.Allocator, arena: std.mem.Allocator, q: PathId, out: *std.ArrayList(PathId)) Ids.ChargeError!void {
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
pub fn coveredBy(pl: *const Place.Table, ts: []const PathId, t: PathId) bool {
    for (ts) |o| if (o != t and pl.isPrefix(o, t)) return true;
    return false;
}
