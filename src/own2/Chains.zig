//! L8: what the distinct check reads of its rounds, split from `Distinct`
//! (`docs/design/ownership-v2.md` §2.9.3): an entry's chain of expansions,
//! the inline order of entries, a condition's occurrences gathered once, and
//! whether an atom was made after a call.
//!
//! Obligations kept here: none of §2.14's directly (each answer is the
//! least fixpoint's or an order; a skipped leaf names objects read already).

const std = @import("std");
const Contract = @import("Contract.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");
const Entries = @import("Entries.zig");
const Jumps = @import("Jumps.zig");

const Error = Relation.Error;
const Cond = Contract.Cond;
const Eval = Relation.Eval;
const Leaf = Value.Leaf;
const Occs = Entries.Occs;
const none = std.math.maxInt(u32);

/// Whether atom `a` (a literal's or a call's fresh objects) was made
/// after the call whose result `l` is: then the result holds none of it.
pub fn madeAfter(e: *Eval, a: Leaf, l: Leaf) bool {
    if (l.kind != .ref or e.f.roots.items[l.root].kind != .call) return false;
    const at = switch (a.kind) {
        .site => a.atom,
        .fresh => e.f.calls.items[a.atom].point,
        else => return false,
    };
    return e.f.calls.items[e.f.roots.items[l.root].a].point < at;
}

/// Whether entry `at` or one it was expanded from has leaf `x`; a step
/// each, charged, and only for a leaf some entry has. The chain's leaves are
/// distinct (a leaf met again is never added), so it is at most the leaves long.
pub fn onChain(e: *Eval, st: *const Entries.Rounds, at: u32, x: u32) Error!bool {
    // A leaf no entry has is on no chain: one lookup, no walk.
    if (st.has_leaf.get(.{x}) == null) return false;
    var a = at;
    while (a != none) : (a = st.par.items[a][0]) {
        try e.charge(.cond, 1);
        if (st.ents.items[a].leaf == x) return true;
    }
    return false;
}

/// `xs` in the inline order of the check's entries (an insertion sort by
/// `Jumps.before`, its comparisons charged).
pub fn sortInline(e: *Eval, st: *const Entries.Rounds, xs: []u32) Error!void {
    var i: usize = 1;
    while (i < xs.len) : (i += 1) {
        var k = i;
        while (k > 0 and try Jumps.before(e.f, st.par.items, st.jump.items, xs[k], xs[k - 1])) : (k -= 1) std.mem.swap(u32, &xs[k], &xs[k - 1]);
    }
}

/// Add condition `c`'s occurrences to `occs`; whether it is `no`.
/// A condition gathered again (one interned run) is not read again.
pub fn gather(e: *Eval, occs: *Occs, c: Cond) Error!bool {
    if (c.no) return true;
    if (c.sel.len == 0) return false;
    try e.charge(.cond, 1);
    const key: u64 = @intFromPtr(c.sel.ptr) ^ (@as(u64, c.sel.len) << 48);
    if ((try occs.seen.getOrPut(e.gpa(), key | (1 << 63))).found_existing) return false;
    try e.charge(.cond, @intCast(c.sel.len));
    for (c.sel) |x| try occs.add(e.gpa(), x);
    return false;
}
