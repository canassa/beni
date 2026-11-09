//! L3: the identity tree's one normal form (`docs/design/ownership-v2.md`
//! §2.11.2, *the identity control*): an open arrival `π_j·s` at a result
//! slot `p` says `π_j·(s·r)` at every slot `p·r` by structure, so a
//! contract does not say it there again. Read by `Contract.putRes`, so a
//! subtree read by structure and the same subtree read slot by slot give
//! one tree.
//!
//! Obligations kept here: none of §2.14's directly (a dropped arrival is one
//! the open arrival above it names).

const std = @import("std");
const Slots = @import("Slots.zig");
const SlotWords = @import("SlotWords.zig");
const Trees = @import("Trees.zig");

/// Whether entry `x`'s arrival `π_j·(s·r)` at slot `p·r` is an open,
/// non-deep `π_j·s` at `p` among `all` (entries with `slot`, `open`, `a`).
/// Never a level's copy: a read of every slot skips it (`Relation.feedAt`).
pub fn saidAbove(slots: *const Slots.Table, all: anytype, x: anytype) bool {
    for (all) |o| if (o.open and o.a.path != Trees.Arrival.level_copy and says(slots, o.slot, o.a, x.slot, x.a)) return true;
    return false;
}

/// Whether arrival `o`, open at slot `op`, says arrival `x` at slot `xq` by structure:
/// `o` is a non-deep `π_j·s`, `xq` is `op·r` with `r` not empty, and `x` is `π_j·(s·r)`.
pub fn says(slots: *const Slots.Table, op: Slots.Rel, o: Trees.Arrival, xq: Slots.Rel, x: Trees.Arrival) bool {
    if (x.kind != .param or x.deep or o.kind != .param or o.deep or o.j != x.j) return false;
    const wq, const ws = .{ slots.relWords(xq), slots.relWords(x.slot) };
    const wp, const wo = .{ slots.relWords(op), slots.relWords(o.slot) };
    if (wp.len >= wq.len or !SlotWords.startsAt(wq, wp) or ws.len != wo.len + wq.len - wp.len) return false;
    return SlotWords.startsAt(ws, wo) and SlotWords.same(ws[wo.len..], wq[wp.len..]);
}
