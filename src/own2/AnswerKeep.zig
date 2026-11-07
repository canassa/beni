//! L8: what holds a label's answer handed on to a label
//! (`docs/design/ownership-v2.md` §2.11.3, *An answer handed on*). The
//! answer is unknown code's, so nothing written of it is known; what a write
//! of it must not reach is what the frame holds. A holder of that answer
//! holds it; anything else meets it only where the function may answer
//! something that existed, so it is apart when the function answers only
//! objects it makes (the `fed` occurrence with `fresh_arg`).
//!
//! Obligations kept here: the relation's half of O14's rule for an answer
//! handed on (a holder of the answer keeps the supply).

const std = @import("std");
const Contract = @import("Contract.zig");
const Value = @import("Value.zig");

/// Label call `ci`'s function answers only objects it makes.
pub fn fresh(e: anytype, ci: u32) !Contract.Cond {
    const cb = e.f.cbs.items[ci];
    const run = try e.arena.alloc(u64, 1);
    run[0] = Contract.occFed(cb.j, cb.slot, Contract.fresh_arg);
    return Contract.Cond.of(e.account(), run);
}

/// The label call answer leaf `l` is of.
pub fn callOf(f: *const Value.Frame, l: Value.Leaf) u32 {
    return if (l.kind == .answer) l.atom else f.roots.items[l.root].a;
}

/// Whether label call `ci`'s function runs more than once in the frame.
/// `SupplyAnswers.repeated` then asks what it answers, whatever holds it.
/// `cbs` keeps every label an evaluation met, so only what runs in this one
/// counts: a direct call, or a label passed on now. An answer of `true` lets
/// a holder off, so a label an earlier evaluation met must not add to it.
pub fn repeats(e: anytype, ci: u32) bool {
    const f = e.f;
    const c = f.cbs.items[ci];
    var n: u32 = 0;
    for (f.cbs.items, 0..) |o, oi| if (o.j == c.j and o.slot == c.slot) {
        if (o.inst == Value.none and e.passed.get(.{@intCast(oi)}) == null and !@import("Mutate.zig").on(.repeats_stale_labels)) continue;
        n += @max(1, o.calls);
    };
    return n > 1;
}

/// Holder leaf `xi` against answer leaf `ti` (`Distinct.overlap` while
/// `keeping`): the same answer, or one a holder's own answer was handed,
/// meets it, unless that function answers only objects it makes; a call's
/// result as its expansion; anything else by what the answer may hold
/// (`holds`), and where that may be anything, under `fresh`.
pub fn kept(comptime Ov: type, e: anytype, xi: u32, ti: u32, ov: anytype, holds: anytype) !Ov {
    if (@import("Mutate.zig").on(.answer_keep_no)) return .no;
    const x = e.f.leafAt(xi);
    const t = e.f.leafAt(ti);
    const ci = callOf(e.f, t);
    const x_answer = x.kind == .answer or (x.kind == .ref and e.f.roots.items[x.root].kind == .cb);
    if (x_answer) {
        const xc = callOf(e.f, x);
        if (xc == ci) return .may;
        var acc: Ov = .no;
        var sl: std.ArrayList(u32) = .empty;
        defer sl.deinit(e.gpa());
        for (e.f.cbs.items[xc].args) |sv| try e.leavesOf(sv, 0, &sl);
        for (sl.items) |l| {
            const o: Ov = try ov(e, l, ti, true);
            acc = try Ov.join(e.arena, e.account(), acc, if (o.kind == .may) .{ .kind = .under, .cond = try fresh(e, xc) } else o);
        }
        return Ov.join(e.arena, e.account(), acc, .{ .kind = .under, .cond = try fresh(e, ci) });
    }
    if (x.kind == .ref and e.expandable(x)) {
        var ls: std.ArrayList(u32) = .empty;
        defer ls.deinit(e.gpa());
        try e.expand(xi, &ls);
        var acc: Ov = .no;
        for (ls.items) |l| {
            acc = try Ov.join(e.arena, e.account(), acc, try ov(e, l, ti, true));
            if (acc.kind == .may) return acc;
        }
        return acc;
    }
    // Unknown code may answer it, a selection of the parameters or not: a
    // selection of a loop's accumulator could not hold at the recursive call.
    const c = e.f.cbs.items[ci];
    if (x.kind == .ref and e.f.roots.items[x.root].kind == .param and e.f.roots.items[x.root].a == c.j and repeats(e, ci)) return .no;
    const o: Ov = try holds(e, t, xi, true);
    return if (o.kind == .no) .no else .{ .kind = .under, .cond = try fresh(e, ci) };
}
