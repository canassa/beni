//! L3: the `⟲`s a walk below a result slot folds onto above it, split from
//! `LevelWide` (`docs/design/ownership-v2.md` §2.1, *A level read on a built value*).
//!
//! Obligations kept here: O6 (`⟲` covers every level of a result: no level above is missed).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");

const PathId = Ids.PathId;

/// Whether `p`'s cycle holds another place: on one place alone, every fold is below a slot.
pub fn hasMiddle(pl: *const Place.Table, p: Ids.PlaceId) bool {
    for (pl.steps(p).children) |c| if (c != p and pl.sameComponent(c, p)) return true;
    return false;
}

/// The `⟲`s above `q` a walk below it folds onto, and those above each. A step onto
/// `P` from below `x`, no `P` between, folds (`Place.extend`) onto the first `P` up
/// from `x` if it is a `⟲`, else onto its `⟲` if a second `P` is above: one fold a
/// place, so each slot a walk below `q` reaches is below `q` or below one of these.
pub fn of(f: anytype, g: std.mem.Allocator, arena: std.mem.Allocator, q: PathId, out: *std.ArrayList(PathId)) Ids.ChargeError!void {
    const pl = f.places;
    // `.{0, t}` a fold met; `.{i + 1, P}` `P`'s first path up from the `i`th, none once used.
    var met: Ids.FixedDict(2) = .{};
    defer met.deinit(g);
    const start = out.items.len;
    var i = start;
    while (true) : (i += 1) {
        const x = if (i == start) q else out.items[i - 1];
        var at = x;
        while (at != .none and pl.sameComponent(pl.pathPlace(at), pl.pathPlace(q))) : (at = pl.pathParent(at)) {
            try f.charge(.path, 1);
            const got = try met.getOrPut(g, .{ @intCast(i - start + 1), pl.pathPlace(at).int() });
            const d: PathId = if (got.found_existing) .from(got.value_ptr.*) else at;
            got.value_ptr.* = if (got.found_existing) Ids.none_int else at.int();
            if (d.int() == Ids.none_int or d == x) continue;
            const level = pl.pathParent(d) != .none and pl.pathStep(d).kind == .level;
            const t = if (!got.found_existing) (if (level) d else continue) else if (level) continue else try pl.foldOnto(g, f.account, d);
            if (!(try met.getOrPut(g, .{ 0, t.int() })).found_existing) try out.append(arena, t);
        }
        if (i == out.items.len) return if (std.debug.runtime_safety) @import("UpCheck.zig").agrees(f.places, q, out.items[start..]);
    }
}

/// Whether another target is above `t`: a reader below `t` meets it first, and goes on by the words.
pub fn coveredBy(pl: *const Place.Table, ts: []const PathId, t: PathId) bool {
    for (ts) |o| if (o != t and pl.isPrefix(o, t)) return true;
    return false;
}
