//! L8: a chain of calls that hand one object on, read to its end for the
//! distinct check (`docs/design/ownership-v2.md` §2.9.3, *The rounds' state*),
//! split from `Relation`.
//!
//! Obligations kept here: none of §2.14's directly (the end names the
//! objects every call on the chain hands on, the least fixpoint's).

const Ids = @import("Ids.zig");
const Subtree = @import("Subtree.zig");
const Relation = @import("Relation.zig");

const Error = Relation.Error;
const Eval = Relation.Eval;
const none: u32 = Ids.none_int;

/// What leaf `x` of one object slot of a call's result ends at when each
/// call on the way has one leaf there: a chain of calls handing one object on
/// is one step for the distinct check (§2.9.3). Kept while no key grows.
pub fn endOf(e: *Eval, x: u32) Error!u32 {
    const l = e.f.leafAt(x);
    if (l.kind != .ref or l.tags != 0 or l.routes != 0 or e.f.roots.items[l.root].kind != .call) return x;
    const sl = Subtree.explicit(e.f.slots, l.slots);
    if (sl.len != 1 or Subtree.subs(e.f.slots, l.slots).len != 0) return x;
    // One object: never a family's slot, nor one no step below names.
    const pk = e.places().kind(e.places().pathPlace(.from(sl[0])));
    if (e.f.places.isSummary(.from(sl[0])) or pk == .@"var" or pk == .@"opaque") return x;
    if (e.end_memo.get(.{ x, e.grown })) |y| return y;
    try e.end_memo.put(e.gpa(), .{ x, e.grown }, x); // met again: itself
    const run = try e.instAt(e.f.roots.items[l.root].a, .from(sl[0]), none);
    const y = if (run.len == 1 and run[0] != x) try endOf(e, run[0]) else x;
    try e.end_memo.put(e.gpa(), .{ x, e.grown }, y);
    return y;
}
