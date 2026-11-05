//! L3: the answers occurrence (`docs/design/ownership-v2.md` §2.11.3, *a
//! traversal's supply*), a `fed` occurrence of its own.
//!
//! Obligations kept here: none of §2.14's directly.

const Conds = @import("Conds.zig");

/// A `fed` occurrence of the answers (§2.11.3, *a traversal's supply*): the
/// function answers only parts of its argument `k` and objects it makes,
/// each run's objects once, and what it hands itself as `k` is asked plain
/// where it answers it. Marked in `k`'s top bit.
const ans_bit: u32 = 0x1000;
const ans_fresh: u32 = 0x1ffe;
pub fn occ(j: u32, r: Conds.Rel, k: u32) u64 {
    return Conds.occFed(j, r, if (k == Conds.fresh_arg) ans_fresh else k | ans_bit);
}
pub fn is(o: u64) bool {
    return Conds.isFed(o) and Conds.fedArg(o) != Conds.fresh_arg and Conds.fedArg(o) & ans_bit != 0;
}
pub fn arg(o: u64) u32 {
    return if (Conds.fedArg(o) == ans_fresh) Conds.fresh_arg else Conds.fedArg(o) & ~ans_bit;
}
/// A `fed` occurrence's mark in a contract's text.
pub fn text(w: anytype, o: u64) !void {
    const k = if (is(o)) arg(o) else Conds.fedArg(o);
    try w.writeAll(if (is(o)) "!!" else "!");
    if (k != Conds.fresh_arg) try w.print("{d}", .{k + 1});
}
