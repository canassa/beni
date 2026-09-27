//! Recursive groups (checker-v2.md §10.7, §10.8): D14's canonical pessimism,
//! and when a mismatch is D14's.
//!
//! **D14** (§10.7, as restated in round 4). In a recursive group — a value
//! SCC of two or more members, or a group that has merged (§10.4) — a wanted
//! resolved or attached while its receiver's root has rank ≤ `R` has its
//! method type lowered to `R`, and an obligation with a deciding variable at
//! rank ≤ `R` has all its variables lowered to `R`. `R` is the rank of the
//! top-level-kind frame the item was created under (its queue's frame), the
//! member's own frame even before a merged frame hands down (S4-1). The
//! hooks are `wanted`, in `Resolve.step` (the one resolution function, used
//! inline and by the drain, before the attach path), and `row`, where an
//! obligation is attached or decided. A wanted that stays open rides on a
//! group-level flex, and I15 lowers the same method type when that flex
//! meets another: the same pessimism, in the other order.
//!
//! **The hint** (§10.8): whether a mismatch is D14's is read when it is
//! reported (`involved`), before the report poisons it; the text is written
//! when the mismatch's class is final (`finish`, at the root's boundary),
//! from the program's text and that class only (`Producers.hintText`), so it
//! is the same in every declaration order (R7's review: F2, F3, S1).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const TypeStore = @import("TypeStore.zig");
const Evidence = @import("Evidence.zig");
const Obligations = @import("Obligations.zig");
const Solve = @import("Solve.zig");
const Walk = @import("Walk.zig");
const Producers = @import("Producers.zig");

const Var = TypeStore.Var;
const Error = Allocator.Error;

/// D14's `R` for an item created under queue `q`: the rank of the
/// top-level-kind frame it routes to, when that frame is a recursive group's.
pub fn recursiveRank(s: *Solve, q: u32) ?u32 {
    if (s.recursive_frames == 0) return null;
    const queue = &s.queues.items[q];
    if (!queue.live) return null;
    const f = &s.frames.items[queue.frame];
    return if (f.recursive) f.rank else null;
}

/// D14 on wanted `id`, before it is resolved or attached.
pub fn wanted(s: *Solve, id: Evidence.WantedId) Error!void {
    if (s.recursive_frames == 0) return;
    const w = s.evidence.get(id);
    const r = recursiveRank(s, w.frame) orelse return;
    const st = s.store();
    if (st.rank(st.find(w.receiver)) > r) return;
    try lower(s, w.method_type, r);
}

/// D14 on obligation `id`, where it is attached or decided: a deciding
/// variable at rank ≤ `R` lowers all of its variables. An `equatable` row
/// only flags variables, and lowers nothing that could be generalised.
pub fn row(s: *Solve, id: Obligations.Id) Error!void {
    if (s.recursive_frames == 0) return;
    const o = s.obligations.row(id);
    if (o.kind == .equatable) return;
    const r = recursiveRank(s, o.frame) orelse return;
    const st = s.store();
    for (o.vars[0..o.deciding()]) |v| {
        if (st.rank(st.find(v)) > r) continue;
        for (o.vars) |x| try lower(s, x, r);
        return;
    }
}

fn lower(s: *Solve, v: Var, r: u32) Error!void {
    try Walk.lowerTo(s.store(), &s.stacks, s.cx.gpa, v, r);
}

// ---------------------------------------------------------------------------
// The hint (§10.7, §10.8)
// ---------------------------------------------------------------------------

/// A reported mismatch D14 made: the diagnostic (its index in the module's
/// list), where it is, and the declaration whose merge class the hint names
/// once that class is final.
pub const Pending = struct { item: u32, decl: u32, region: Bir.Inst.Index, call: Bir.Inst.OptionalIndex };

/// Whether a mismatch between `expected` and `actual` is D14's: a wanted or
/// obligation of an open recursive group whose deciding variable is
/// group-level — which D14 lowered, or I15 on the flex it rides on, the same
/// lowering in the other order (§10.7) — reaches either side. A receiver
/// a `let` held back (§8.4 *As built by R14*, `report.monomorphic`) is
/// not D14's, and its error gets no hint (R7's adversarial review, F4). Only
/// items made since the lowest open recursive frame was pushed are read.
pub fn involved(s: *Solve, expected: Var, actual: Var) Error!bool {
    if (s.recursive_frames == 0) return false;
    const st = s.store();
    const lowest = for (s.frames.items) |*f| {
        if (f.recursive) break f;
    } else return false;
    for (s.evidence.wanteds.items[lowest.wanteds_start..]) |w| {
        const r = recursiveRank(s, w.frame) orelse continue;
        const receiver = st.find(w.receiver);
        if (st.rank(receiver) > r or heldByRuleA(s, receiver)) continue;
        if (try meets(s, w.method_type, expected, actual)) return true;
    }
    for (s.obligations.rows.items[lowest.rows_start..]) |o| {
        if (o.kind == .equatable) continue;
        const r = recursiveRank(s, o.frame) orelse continue;
        const group_level = for (o.vars[0..o.deciding()]) |v| {
            if (st.rank(st.find(v)) <= r) break true;
        } else false;
        if (!group_level) continue;
        for (o.vars) |v| if (try meets(s, v, expected, actual)) return true;
    }
    return false;
}

fn heldByRuleA(s: *Solve, receiver: Var) bool {
    const st = s.store();
    for (s.report.monomorphic.items) |m| if (st.find(m.v) == receiver) return true;
    return false;
}

/// Whether `v` reaches the root of `expected` or of `actual`.
fn meets(s: *Solve, v: Var, expected: Var, actual: Var) Error!bool {
    const st = s.store();
    return try Walk.reaches(st, &s.stacks, s.cx.gpa, v, expected) or try Walk.reaches(st, &s.stacks, s.cx.gpa, v, actual);
}

/// The diagnostic just emitted at index `item`, at `region`, is D14's: its
/// hint is written when the class of the declaration holding `region` is
/// final (`finish`), so it names that class and nothing that depended on
/// which member was checked first (R7's review: F2, F3, S1).
pub fn note(s: *Solve, item: usize, region: Bir.Inst.Index, call: Bir.Inst.OptionalIndex) Error!void {
    const decl = Producers.declOf(s.cx.bir, region) orelse return;
    try s.groups.hints.append(s.cx.gpa, .{ .item = @intCast(item), .decl = decl, .region = region, .call = call });
}

/// A class just generalised at its root's boundary, with members `done`:
/// the hints of its mismatches are written now.
pub fn finish(s: *Solve, done: []const u32) Error!void {
    const gs = s.groups;
    var i: usize = 0;
    while (i < gs.hints.items.len) {
        const h = gs.hints.items[i];
        if (std.mem.indexOfScalar(u32, done, h.decl) == null) {
            i += 1;
            continue;
        }
        _ = gs.hints.swapRemove(i);
        const text = try Producers.hintText(gs, h.decl, h.region, h.call);
        defer s.cx.gpa.free(text);
        try s.report.appendToItem(h.item, text);
    }
}
