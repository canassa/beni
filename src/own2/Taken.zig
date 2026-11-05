//! L7: a `taken` element out of its container (`docs/design/ownership-v2.md`
//! §2.11.3, *a taken supply*; §2.13.6). The result of a `taken` row
//! (`traverseAt`) is one element of its argument 1; for the rest of the
//! frame the body reads that container only through the traversal, once per
//! index (the index obligation, pinned). So a leaf of the container's root
//! holds the **others**: it meets the taken element only where the
//! container's separation fails, never by position.
//!
//! Obligations kept here: the relation's half of O9's split (a holder of
//! the container is apart from the taken element under the container's
//! selection; §2.14, Lemma 1's split clause).

const std = @import("std");
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const Contract = @import("Contract.zig");
const Value = @import("Value.zig");

const Leaf = Value.Leaf;
const none: u32 = Ids.none_int;

/// The container value `v` takes an element out of: `v` is the result of a
/// call of a `taken` row, read whole; its argument 1. Else `none`.
pub fn containerOf(f: *const Value.Frame, contracts: *const Contract.Table, v: u32) u32 {
    const x = f.vals.items[v];
    if (x.kind != .ref or x.family != Slots.empty) return none;
    return containerAt(f, contracts, x.root, x.pos);
}

fn containerAt(f: *const Value.Frame, contracts: *const Contract.Table, root: u32, pos: u32) u32 {
    const r = f.roots.items[root];
    if (r.kind != .call or pos != r.pos) return none;
    const c = f.calls.items[r.a];
    if (c.contract == none or c.args.len == 0 or !contracts.head(c.contract).flags.taken) return none;
    return c.args[0];
}

/// The root of the container leaf `l` takes an element out of, else `none`.
pub fn containerRoot(f: *const Value.Frame, contracts: *const Contract.Table, l: Leaf) u32 {
    if (l.kind != .ref) return none;
    const c = containerAt(f, contracts, l.root, l.pos);
    if (c == none) return none;
    const v = f.vals.items[c];
    return if (v.kind == .ref and v.family == Slots.empty) v.root else none;
}

/// Which of `x`, `t` is a taken element whose container's root the other
/// is a reference of: 0 for `x`, 1 for `t`; else null.
pub fn side(f: *const Value.Frame, contracts: *const Contract.Table, x: Leaf, t: Leaf) ?u1 {
    if (t.kind == .ref and containerRoot(f, contracts, x) == t.root) return 0;
    if (x.kind == .ref and containerRoot(f, contracts, t) == x.root) return 1;
    return null;
}

/// `Distinct.overlap` of `xi` and `ti` (`Ov`) when one is a taken element (`which`,
/// from `side`) and the other a leaf of its container's root: the element
/// read as what it is (the container's leaves at the element), each of those
/// of that root apart from the other leaf under the root's separation
/// (`apart`, §2.9.2), any other by the relation (`ov`).
pub fn apartFromOthers(comptime Ov: type, e: anytype, xi: u32, ti: u32, which: u1, target: bool, apart: anytype, ov: anytype) !Ov {
    const other = e.f.leafAt(if (which == 0) ti else xi).root;
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(e.gpa());
    try e.expand(if (which == 0) xi else ti, &ls);
    var acc: Ov = .no;
    for (ls.items) |l| {
        const a, const b = if (which == 0) .{ l, ti } else .{ xi, l };
        const o = if (e.f.leafAt(l).root == other) try apart(e, a, b, target) else try ov(e, a, b, target);
        acc = try Ov.join(e.arena, e.account(), acc, o);
        if (acc.kind == .may) return acc;
    }
    return acc;
}
