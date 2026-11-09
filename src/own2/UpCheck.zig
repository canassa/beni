//! L2: one set of the folds above a slot (`docs/design/ownership-v2.md` §2.1, *One below*;
//! §2.7 `Up(p)`): `LevelTargets.of` reads them off the suffix, `Place.foldsUp` walks the
//! cycle, and under runtime safety every answer of the first holds the second's.
//!
//! Obligations kept here: O6 (`⟲` covers every level: no fold above a slot is missed).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");

const PathId = Ids.PathId;

/// Whether `ts` holds every path of `Up(q)`; a panic otherwise. On an account of its own:
/// a memo's reader pays its fill cost however it was filled (§4.1), so no charge moves.
pub fn agrees(pl: *Place.Table, g: std.mem.Allocator, q: PathId, ts: []const PathId) Ids.ChargeError!void {
    var scratch: Ids.Account = .{ .allowance = std.math.maxInt(u32) };
    defer scratch.deinit(g);
    const r = pl.foldsUp(g, .growth(&scratch), q) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    var n: u32 = 0;
    while (n < r.len) : (n += 1) {
        const u = pl.foldPath(r.start + n);
        for (ts) |t| {
            if (t == u) break;
        } else @panic("a fold above a slot that LevelTargets.of misses");
    }
}
