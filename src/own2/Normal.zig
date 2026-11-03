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

/// Whether entry `x`'s arrival `π_j·(s·r)` at slot `p·r` is an open,
/// non-deep `π_j·s` at `p` among `all` (entries with `slot`, `open`, `a`).
pub fn saidAbove(slots: *const Slots.Table, all: anytype, x: anytype) bool {
    if (x.a.kind != .param or x.a.deep) return false;
    const wq, const ws = .{ slots.relWords(x.slot), slots.relWords(x.a.slot) };
    for (all) |o| if (o.open and o.a.kind == .param and !o.a.deep and o.a.j == x.a.j) {
        const wp, const wo = .{ slots.relWords(o.slot), slots.relWords(o.a.slot) };
        if (wp.len >= wq.len or !std.mem.startsWith(u32, wq, wp) or ws.len != wo.len + wq.len - wp.len) continue;
        if (std.mem.startsWith(u32, ws, wo) and std.mem.eql(u32, ws[wo.len..], wq[wp.len..])) return true;
    };
    return false;
}
