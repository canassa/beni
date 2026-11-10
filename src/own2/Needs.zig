//! L11: a label's need (`docs/design/ownership-v2.md` §2.11.3, *a need*). A callee that writes a label's answer cannot
//! judge the write: it publishes the answer's slot on the label, and each caller discharges it against the code it
//! hands. Read after a round's deliveries and again until nothing is new, so a group member is read as its facts stand.
//!
//! Obligations kept here: O1 (a function no caller can name answers nothing a need can rely on), O14's need half (a
//! need holds at each call that applies the label, outward).

const std = @import("std");
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const Contract = @import("Contract.zig");
const Distinct = @import("Distinct.zig");
const LabelChain = @import("LabelChain.zig");
const NeedArrivals = @import("NeedArrivals.zig");
const NeedFolds = @import("NeedFolds.zig");
const NeedCarry = @import("NeedCarry.zig");
const KeepsNot = @import("KeepsNot.zig");
const RunKeeps = @import("RunKeeps.zig");
const CallFolds = @import("CallFolds.zig");
const SlotWords = @import("SlotWords.zig");
const Graft = @import("Graft.zig");
const Value = @import("Value.zig");
const Eval = @import("Eval.zig");
const W = @import("Walk.zig");

const Allocator = std.mem.Allocator;
const Error = Eval.Error;
const Effect = Contract.Effect;
const Evaluation = Eval.Evaluation;
const Sink = Eval.Sink;
const none: u32 = Ids.none_int;

/// What was discharged already, across a round's passes, by evaluation.
pub const State = struct {
    seen: Ids.FixedDict(6) = .{},
    /// Per evaluation, the demands `HandedWrites.pass` has read.
    handed: std.ArrayList(u32) = .empty,

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.seen.deinit(gpa);
        s.handed.deinit(gpa);
    }

    fn first(s: *State, gpa: Allocator, key: [6]u32) Error!bool {
        return !(try s.seen.getOrPut(gpa, key)).found_existing;
    }
};

/// Label `cb`'s answer is written at `slot` (`j` 0), or what it is handed as its argument `j - 1` is, after
/// it was handed (§2.11.3, *a need on a supply*): said on the frame's label.
pub fn publish(s: *Sink, cb: u32, j: u32, slot: Slots.Rel, deep: bool) Error!bool {
    const at = try s.labelIndex(cb);
    return Contract.Draft.addEffect(&s.d.labels.items[at].need, s.arena, .{ .j = j, .slot = slot, .deep = deep });
}

/// Where a need on a supply passes on: the frame's label, argument `k`, whole.
const Pub = struct {
    e: *Evaluation,
    new: bool = false,
    pub fn on(p: *Pub, cb: u32, k: u32) Error!void {
        p.new = try publish(&p.e.sink, cb, k + 1, Slots.root, true) or p.new;
    }
};

/// Known code `v` keeps nothing of what need `n` covers of its argument `n.j - 1`, or refused (§2.11.3).
fn keeps(st: *State, e: *Evaluation, x: u32, q: u32, l: Contract.Label, v: u32, n: Effect) Error!bool {
    var p: Pub = .{ .e = e };
    const c = e.fr().calls.items[v].contract;
    if (c != none and try KeepsNot.nothing(&e.ev, c, v, n.j - 1, e.fr().slots.relWords(n.slot), n.deep, &p)) return p.new;
    try refuseOnce(st, e, x, q, l, v, n);
    return true;
}

/// A fold's run hands its accumulator to a label that passes on (#2386): `RunKeeps` relies on the need this
/// publishes on the frame's label, for each call `q` whose label hands a known code its own answer back.
fn fedOn(e: *Evaluation, q: u32) Error!bool {
    const call = e.fr().calls.items[q];
    var p: Pub = .{ .e = e };
    for (e.contracts.labelsOf(e.contracts.head(call.contract).labels), 0..) |l, li| if (e.ev.known.get(.{ q, @as(u32, @intCast(li)) })) |v| {
        for (e.contracts.suppliesOf(l.supplies)) |su| if (try KeepsNot.selfFed(&e.ev, q, @intCast(li), su.k)) {
            _ = try RunKeeps.nothing(&e.ev, v, su.k, true, &p);
        };
    };
    return p.new;
}

/// One pass over evaluation `x`'s calls; true when something new was made.
pub fn pass(st: *State, e: *Evaluation, x: u32) Error!bool {
    const f = e.fr();
    var new = false;
    var q: u32 = 0;
    while (q < f.calls.items.len) : (q += 1) {
        if (!e.inLast(q)) continue;
        const call = f.calls.items[q];
        if (call.contract == none) continue;
        new = try fedOn(e, q) or new;
        if (memberOf(e, call)) |m| {
            var i: usize = 0;
            while (i < m.draft.labels.items.len) : (i += 1) {
                var n: usize = 0;
                while (n < m.draft.labels.items[i].need.items.len) : (n += 1) {
                    const need = m.draft.labels.items[i].need.items[n];
                    const li = e.ev.live.?.labelIn(e.ev.live.?.ctx, call.code, @intCast(i), call.contract) orelse continue;
                    new = try atLabel(st, e, x, q, li, need) or new;
                }
            }
            continue;
        }
        const labels = e.contracts.labelsOf(e.contracts.head(call.contract).labels);
        for (labels, 0..) |l, li| for (e.contracts.effectsOf(l.need)) |need| {
            new = try atLabel(st, e, x, q, @intCast(li), need) or new;
        };
    }
    return new;
}

fn memberOf(e: *Evaluation, call: Value.Call) ?Eval.Group.Member {
    const sv = e.solver orelse return null;
    if (call.code == none) return null;
    return sv.member(sv.ctx, call.code);
}

/// Call `q`'s label `li` has need `n`.
fn atLabel(st: *State, e: *Evaluation, x: u32, q: u32, li: u32, n: Effect) Error!bool {
    const f = e.fr();
    const call = f.calls.items[q];
    const l = e.contracts.labelsOf(e.contracts.head(call.contract).labels)[li];
    if (l.j >= call.args.len or !try st.first(e.gpa(), .{ x, q, li, n.slot, @intFromBool(n.deep), none - n.j })) return false;
    // Each known code the label is applied to, one or an `alt`'s (#2322).
    if (e.ev.alts.codes(&e.ev.known, q, li)) |r| {
        var new = false;
        for (r[0]..r[0] + r[1]) |v| new = try (if (n.j == 0) discharge(st, e, x, q, l, @intCast(v), n) else keeps(st, e, x, q, l, @intCast(v), n)) or new;
        return new;
    }
    if (e.ev.label_map.get(.{ q, li })) |c| return publish(&e.sink, c, n.j, n.slot, n.deep);
    const v = f.val(try e.ev.valueAt(call.args[l.j], f.slots.relWords(l.slot)));
    // A fixed contract, read as `wants` reads one. A code's closure is applied
    // (`known`) and a fixed one is never an argument, so no walk reaches this today.
    if (n.j == 0 and v.kind == .built and v.form == .closure) if (NeedCarry.contractOf(e.ctx, v.head)) |c| if (try allFresh(e, c)) return false;
    try refuseOnce(st, e, x, q, l, none, n);
    return true;
}

/// Whether a fixed contract answers only fresh objects, all of them: it has no
/// place to say where a type's fold is, and a need may be short past one.
fn allFresh(e: *Evaluation, c: Contract.Id) Error!bool {
    var hs: std.ArrayList(NeedArrivals.At) = .empty;
    _ = try NeedArrivals.of(e, null, c, .none, &.{}, true, &hs);
    for (hs.items) |h| if (h.a.kind != .fresh) return false;
    return hs.items.len != 0;
}

/// Known code `v` answers at the need: each arrival by its kind (§2.11.3).
fn discharge(st: *State, e: *Evaluation, x: u32, q: u32, l: Contract.Label, v: u32, n: Effect) Error!bool {
    const f = e.fr();
    const vc = f.calls.items[v];
    const words = f.slots.relWords(n.slot);
    const m = memberOf(e, vc);
    var hs: std.ArrayList(NeedArrivals.At) = .empty;
    const met = try NeedArrivals.of(e, if (m) |mm| &mm.draft.res else null, vc.contract, f.roots.items[vc.root].place, words, n.deep, &hs);
    // A deep need reads each fold above its slot too (§2.1, *One below*).
    if (n.deep) try NeedFolds.of(e, if (m) |mm| &mm.draft.res else null, vc.contract, f.roots.items[vc.root].path, f.roots.items[vc.root].place, words, &hs);
    // A contract's tree also says each fold the caller's instance adds, read whole (§2.1, #2223).
    if (m == null) for (try CallFolds.of(&e.ev, v, none)) |s| if (SlotWords.startsAt(words, s.words) or (n.deep and SlotWords.startsAt(s.words, words)))
        try hs.append(e.ev.arena, .{ .a = s.a, .rest = &.{}, .whole = true });
    if (!met and hs.items.len == 0) {
        try refuseOnce(st, e, x, q, l, v, n);
        return true;
    }
    const own = vc.args.len - f.kidsOf(f.val(vc.callee_val)).len;
    var new = false;
    for (hs.items) |h| {
        const a = h.a;
        const rel = if (a.kind == .param or a.kind == .cb) try f.slots.relOfWords(e.gpa(), f.account, f.places, try std.mem.concat(e.ev.arena, u32, &.{ f.slots.relWords(a.slot), h.rest })) else n.slot;
        if (!try st.first(e.gpa(), .{ x, v, @backingInt(a.kind), a.j, rel, @intFromBool(n.deep or a.deep or h.whole) })) continue;
        new = true;
        const from = e.demands.items.len;
        var kept: ?Effect = null;
        switch (a.kind) {
            .fresh => {
                var ls: std.ArrayList(u32) = .empty;
                try e.ev.arrivalLeaves(v, vc.contract, a, &.{}, &ls);
                const t_start: u32 = @intCast(e.w.leaf_runs.items.len);
                try e.w.leaf_runs.appendSlice(e.gpa(), ls.items);
                var d = try base(e, q, l);
                d.targets = .{ .start = t_start, .len = @intCast(ls.items.len) };
                d.fresh_answer, d.record = .{ true, @import("Update.zig").ofNeed(f, vc, n) };
                try Eval.addDemand(e, d);
            },
            // The answer is what the code was handed: it keeps nothing of it, or the write is seen by what kept it (#2393).
            .param => if (a.j < own) {
                try Eval.callWrite(e, v, .{ .j = a.j, .slot = rel, .deep = n.deep or a.deep or h.whole });
                kept = .{ .j = a.j + 1, .slot = rel, .deep = n.deep or a.deep or h.whole };
            } else try refuseOnce(st, e, x, q, l, v, n),
            .cb => {
                const li = if (m != null) e.ev.live.?.labelIn(e.ev.live.?.ctx, vc.code, a.j, vc.contract) else a.j;
                if (li) |i| {
                    _ = try atLabel(st, e, x, v, i, .{ .j = 0, .slot = rel, .deep = n.deep or a.deep or h.whole });
                } else try refuseOnce(st, e, x, q, l, v, n);
            },
            else => try refuseOnce(st, e, x, q, l, v, n),
        }
        for (e.demands.items[from..]) |*d| {
            d.quiet = true;
            if (words.len != 0) d.res_of = v;
        }
        if (kept) |k| _ = try keeps(st, e, x, q, l, v, k);
    }
    return new;
}

/// A comparison has no caller to discharge a need (§2.13.13 item 13): with one on a label of its draft, after the fixed
/// point, each call that makes it is refused. A write of the answer itself has a line of its own.
pub fn compared(e: *Evaluation, d: *const Contract.Draft) Error!void {
    for (d.labels.items) |l| {
        if (l.need.items.len != 0) break;
    } else return;
    const f = e.fr();
    for (f.calls.items, 0..) |call, q| {
        if (call.contract == none or call.virtual) continue;
        for (e.contracts.labelsOf(e.contracts.head(call.contract).labels)) |l| if (l.need.len != 0) {
            var nd = try base(e, @intCast(q), l);
            nd.need = true;
            try Eval.addDemand(e, nd);
            break;
        };
    }
}

/// The demand a need makes at call `q`, for label `l`.
fn base(e: *Evaluation, q: u32, l: Contract.Label) Error!W.Demand {
    const f = e.fr();
    var wq = q;
    while (wq >= e.w.walk_calls) wq = (LabelChain.virtualOuter(e.chain(), wq) orelse break)[0];
    const walked = wq < e.w.walk_calls;
    const call = f.calls.items[wq];
    // Named as the function value's site where it has one: a field of a record handed whole.
    const fv = f.val(try e.ev.valueAt(f.calls.items[q].args[l.j], f.slots.relWords(l.slot)));
    const inst = if (fv.kind == .built and fv.site != none and wq == q) fv.site else if (wq == q) Graft.argInst(call, l.j) else call.inst;
    return .{ .point = call.point, .kind = .callsite, .token = Eval.tokenOf(e, call.inst), .base_inst = inst, .callee_inst = if (walked) call.head else none, .pending = if (walked) e.w.sites.items[wq].pending else none, .callback = true };
}

/// One refusal per call and label, however many of its needs fail, and one for a record's needs (`Update.ofNeed`, by known code `v`).
fn refuseOnce(st: *State, e: *Evaluation, x: u32, q: u32, l: Contract.Label, v: u32, n: Effect) Error!void {
    const rec = v != none and @import("Update.zig").ofNeed(e.fr(), e.fr().calls.items[v], n);
    if (!try st.first(e.gpa(), .{ x, q, l.slot, l.origin[2], none, none - 1 - @intFromBool(rec) })) return;
    var d = try base(e, q, l);
    d.need, d.supplied, d.record = .{ true, n.j != 0, rec };
    try Eval.addDemand(e, d);
}

/// After `finishDemands`: a need below the root asks the code's result separation.
pub fn finish(e: *Evaluation) Error!void {
    const f = e.fr();
    for (e.demands.items) |*d| {
        if (d.res_of == none) continue;
        const c = try e.contracts.resCond(e.ev.arena, f.calls.items[d.res_of].contract, false);
        d.relies = try Contract.Cond.conj(e.ev.arena, f.account, d.relies, try Distinct.instSel(&e.ev, c, d.res_of));
    }
}
