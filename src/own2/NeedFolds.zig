//! L6: what a deep need meets at the folds above its slot (`docs/design/ownership-v2.md`
//! §2.1, *One below*; §2.11.3, *a need*), split from `Needs`: a need read below a slot reads
//! the known code's tree at each fold a walk below the slot reaches, not only by its words.
//!
//! Obligations kept here: O6 and O14's need half (every arrival at the need is found).

const std = @import("std");
const Ids = @import("Ids.zig");
const Contract = @import("Contract.zig");
const Replay = @import("Replay.zig");
const BelowAnchors = @import("BelowAnchors.zig");
const NeedArrivals = @import("NeedArrivals.zig");

/// The arrivals of a result at each fold above the slot `words` names from root path `rp`
/// (place `root`), in the reading frame's graph, when the need is deep (`NeedArrivals.of`'s
/// arguments otherwise). No steps from the need's slot name a slot below the fold, so every
/// entry met there is read whole, at no words.
pub fn of(e: anytype, res: ?*const Contract.Draft.Res, c: Contract.Id, rp: Ids.PathId, root: Ids.PlaceId, words: []const u32, out: *std.ArrayList(NeedArrivals.At)) Ids.ChargeError!void {
    const f = e.fr();
    var ps: std.ArrayList(u32) = .empty;
    defer ps.deinit(e.gpa());
    try Replay.replay(e.gpa(), f.account, f.places, rp, words, &ps);
    for (ps.items) |p| for (try BelowAnchors.of(f, e.gpa(), e.ev.arena, .from(p))) |t| if (t.int() != p) {
        const tw = try e.ev.arena.dupe(u32, f.slots.relWords(try f.slots.relOf(e.gpa(), f.account, f.places, t)));
        const start = out.items.len;
        _ = try NeedArrivals.of(e, res, c, root, tw, true, out);
        for (out.items[start..]) |*x| x.* = .{ .a = x.a, .rest = &.{}, .whole = true };
    };
}
