//! L2: one set of the folds above a slot (`docs/design/ownership-v2.md` §2.1, *One below*;
//! §2.7 `Up(p)`): `LevelTargets.of` reads them off the suffix, `Place.foldsUp` walks the
//! cycle, and under runtime safety every answer of the first holds the second's.
//!
//! Obligations kept here: O6 (`⟲` covers every level: no fold above a slot is missed).

const Ids = @import("Ids.zig");
const Place = @import("Place.zig");

const PathId = Ids.PathId;

/// Panics where `ts` misses a path of `Up(q)`, when `Up(q)` is made already. A pure read: it
/// fills no memo and makes no path, so a build with runtime safety names every path as one
/// without it does, and charges the same.
pub fn agrees(pl: *const Place.Table, q: PathId, ts: []const PathId) void {
    const i = pl.up_memo.get(q) orelse return;
    const r = pl.fold_runs.items[i];
    for (pl.fold_paths.items[r[0]..][0..r[1]]) |u| {
        for (ts) |t| {
            if (t == u) break;
        } else @panic("a fold above a slot that LevelTargets.of misses");
    }
}
