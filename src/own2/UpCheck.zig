//! L2: one set of the folds above a slot (`docs/design/ownership-v2.md` §2.1, *One below*;
//! §2.7 `Up(p)`): `LevelTargets.of` reads them off the suffix, `Place.foldsUp` walks the
//! cycle, and under `-Downership-full-cross-check` every answer of the first holds the second's.
//!
//! Obligations kept here: O6 (`⟲` covers every level: no fold above a slot is missed).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");

const PathId = Ids.PathId;

/// The check runs: a safety build with `-Downership-full-cross-check`, whose path numbers may
/// differ from a build without it, as the flag's other cross-checks' may.
pub const on = std.debug.runtime_safety and @import("ownership_options").full_cross_check;

/// Without `on`, nothing. With it, panics where `ts` misses a path of `Up(q)`, which it makes on
/// an account of its own, filling `Place`'s memos and making paths: a memo's reader pays its
/// fill cost however it was filled (§4.1), so no charge moves.
pub fn agrees(pl: *Place.Table, g: std.mem.Allocator, q: PathId, ts: []const PathId) Ids.ChargeError!void {
    if (!on) return;
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
