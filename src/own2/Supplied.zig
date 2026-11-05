//! L11: a supplied part judged at a label's call
//! (`docs/design/ownership-v2.md` §2.11.3). A part that comes partly from
//! unknown code (a fold's accumulator) is `unknown` whole, yet its known
//! objects are still kept where they are held after the call, each judged
//! on its own; a label's answer is judged for its holders, and what the
//! answer may be for theirs, under `fresh` (*An answer handed on*).
//!
//! Obligations kept here: O14's frame half for an answer handed on: a
//! holder of what a label may write keeps the supply, or the function
//! answers only objects it makes.

const std = @import("std");
const Ids = @import("Ids.zig");
const Value = @import("Value.zig");
const Holders = @import("Holders.zig");
const Forest = @import("Forest.zig");
const AnswerKeep = @import("AnswerKeep.zig");
const LabelChain = @import("LabelChain.zig");
const Eval = @import("Eval.zig");
const FnRun = @import("FnRun.zig");
const Across = @import("Across.zig");

const Error = Eval.Error;
const none: u32 = Ids.none_int;

fn answerLeaf(f: *const Value.Frame, l: Value.Leaf) bool {
    return l.kind == .answer or (l.kind == .ref and f.roots.items[l.root].kind == .cb);
}

/// The leaves label call `ci` was supplied: a direct call's arguments, a
/// passed-on label's parts of the calls that pass it.
fn suppliedTo(e: *Eval.Evaluation, ci: u32, out: *std.ArrayList(u32)) Error!void {
    const f = e.fr();
    const cb = f.cbs.items[ci];
    // What the function holds, it may answer: its parameter's slot.
    for (f.roots.items, 0..) |pr, ri| if (pr.kind == .param and pr.a == cb.j and !AnswerKeep.repeats(f, ci)) {
        try e.ev.leavesOf(try e.ev.valueAt(try f.refRoot(@intCast(ri)), f.slots.relWords(cb.slot)), 0, out);
    };
    if (cb.inst != none) {
        for (cb.args) |a| try e.ev.leavesOf(a, 0, out);
        return;
    }
    for (e.passes.items) |p| {
        if (p[0] != ci) continue;
        const call = f.calls.items[p[1]];
        const lab = e.contracts.labelsOf(e.contracts.head(call.contract).labels)[p[2]];
        for (e.contracts.suppliesOf(lab.supplies)) |su| {
            const es = try Eval.entriesOf(e, su.res_root);
            for (es.items.items) |rs| for (rs.arrivals) |a| {
                if (a.kind == .param and a.j < call.args.len) try e.ev.leavesOf(try e.ev.valueAt(call.args[a.j], f.slots.relWords(a.slot)), 0, out);
                if (a.kind == .cb and a.j != p[2]) try FnRun.supplyLeaves(&e.ev, p[1], a, out);
            };
        }
    }
}

/// Part `t` of a label's argument, judged (`leaf`: the check of one leaf).
pub fn judge(comptime Line: type, r: anytype, t: u32, leaf: anytype) Error!Line {
    var l = try leaf.of(r, t);
    if (l.outcome.verdict != .refused or !l.outcome.cause.unseen()) return l;
    const fr = r.f();
    const g = r.gpa();
    var extra: Holders.Gather = .{};
    defer extra.deinit(g);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(g);
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(g);
    try stack.append(g, t);
    while (stack.pop()) |x| {
        if ((try seen.getOrPut(g, .{x})).found_existing) continue;
        const xl = fr.leafAt(x);
        if (answerLeaf(fr, xl)) {
            r.ev().keeping = true;
            const a = try leaf.of(r, x);
            r.ev().keeping = false;
            if (a.outcome.verdict == .refused) return a;
            try extra.add(g, fr.account, a.extra);
            if (try r.mayBeHeld(x, leaf)) try extra.add(g, fr.account, try AnswerKeep.fresh(r.ev(), AnswerKeep.callOf(fr, xl)));
            continue;
        }
        switch (xl.kind) {
            .top, .host => continue,
            .ref => switch (fr.roots.items[xl.root].kind) {
                .cb => unreachable,
                .call, .supply => {
                    try r.ev().expand(x, &stack);
                    continue;
                },
                .param => {},
            },
            else => {},
        }
        const lb = try leaf.of(r, x);
        if (lb.outcome.verdict == .refused and !lb.outcome.cause.unseen()) return lb;
    }
    l.extra = try extra.cond(r.ev().arena, fr.account);
    return l;
}

/// Whether anything answer `x` may be, by what its calls were supplied, is
/// held after the call.
pub fn mayBeHeld(r: anytype, x: u32, leaf: anytype) Error!bool {
    const fr = r.f();
    const g = r.gpa();
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(g);
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(g);
    try stack.append(g, x);
    while (stack.pop()) |y| {
        if ((try seen.getOrPut(g, .{y})).found_existing) continue;
        const yl = fr.leafAt(y);
        if (answerLeaf(fr, yl)) {
            try suppliedTo(r.e, AnswerKeep.callOf(fr, yl), &stack);
            continue;
        }
        switch (yl.kind) {
            .top, .host => continue,
            .ref => if (fr.roots.items[yl.root].kind != .param) {
                try r.ev().expand(y, &stack);
                continue;
            },
            else => {},
        }
        const b = try leaf.of(r, y);
        if (b.outcome.verdict == .refused and !b.outcome.cause.unseen()) return true;
        if (!b.extra.isYes()) return true;
    }
    return false;
}

/// Whether a capture at a code run more than once is held for the next
/// run: part of argument `aj` of pass call `q`, a virtual call.
pub fn heldByClosure(e: *Eval.Evaluation, q: u32, aj: u32) bool {
    const f = e.fr();
    const call = f.calls.items[q];
    if (aj == none or !call.virtual or !Across.capture(f, q, aj)) return false;
    return LabelChain.outwardMany(e.chain(), q);
}

/// What a part supplied at pass call `q` is judged against: the call's
/// arguments for a part of argument `aj` (`none`: an answer in the callee,
/// the callee's to judge), and, for a capture or an answer of a known code a
/// callee runs, what that callee may hold across the run.
pub fn operandsOf(e: *Eval.Evaluation, q: u32, aj: u32) Error![]const u32 {
    const f = e.fr();
    const call = f.calls.items[q];
    if (!call.virtual) return if (aj == none) &.{} else call.args;
    if (aj != none and !Across.capture(f, q, aj)) return call.args;
    var out: std.ArrayList(u32) = .empty;
    if (aj != none) try out.appendSlice(e.ev.arena, call.args);
    var rest: std.ArrayList(u32) = .empty;
    defer rest.deinit(e.gpa());
    try Across.operands(e.chain(), q, aj == none, &rest);
    try out.appendSlice(e.ev.arena, rest.items);
    return out.items;
}
