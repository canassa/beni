//! L11: a label's need (`docs/design/ownership-v2.md` §2.11.3, *a need*). A
//! callee that writes a label's answer cannot judge the write: it publishes
//! the answer's slot on the label, and each caller discharges it against the
//! code it hands. Read after a round's deliveries and again until nothing is
//! new, so a member of the group is read as its facts stand.
//!
//! Obligations kept here: O1 (a function no caller can name answers nothing
//! a need can rely on), O14's need half (a need holds at each call that
//! applies the label, outward).

const std = @import("std");
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const Forest = @import("Forest.zig");
const Contract = @import("Contract.zig");
const Distinct = @import("Distinct.zig");
const LabelChain = @import("LabelChain.zig");
const FoldCross = @import("FoldCross.zig");
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

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.seen.deinit(gpa);
    }

    fn first(s: *State, gpa: Allocator, key: [6]u32) Error!bool {
        return !(try s.seen.getOrPut(gpa, key)).found_existing;
    }
};

/// Label `cb`'s answer is written at `slot`: said on the frame's label.
pub fn publish(s: *Sink, cb: u32, slot: Slots.Rel, deep: bool) Error!bool {
    const at = try s.labelIndex(cb);
    return Contract.Draft.addEffect(&s.d.labels.items[at].need, s.arena, .{ .j = 0, .slot = slot, .deep = deep });
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
    if (l.j >= call.args.len or !try st.first(e.gpa(), .{ x, q, li, n.slot, @intFromBool(n.deep), none })) return false;
    if (e.ev.known.get(.{ q, li })) |v| {
        if (!try FoldCross.crosses(e.gpa(), f.places, f.roots.items[f.calls.items[v].root].place)) return discharge(st, e, x, q, l, v, n);
        // Past a fold no slot names a write, and a callee's contract can run short (§2.11.3).
        try refuse(e, q, l);
        return true;
    }
    if (e.ev.label_map.get(.{ q, li })) |c| return publish(&e.sink, c, n.slot, n.deep);
    const v = f.val(try e.ev.valueAt(call.args[l.j], f.slots.relWords(l.slot)));
    if (v.kind == .built and v.form == .closure and try allFresh(e, v.head & ~W.fixed_bit)) return false;
    try refuse(e, q, l);
    return true;
}

/// Whether a fixed contract answers only fresh objects, all of them: it has no
/// place to say where a type's fold is, and a need may be short past one.
fn allFresh(e: *Evaluation, c: Contract.Id) Error!bool {
    var hs: std.ArrayList(At) = .empty;
    try arrivals(e, null, c, &.{}, true, &hs);
    for (hs.items) |h| if (h.a.kind != .fresh) return false;
    return hs.items.len != 0;
}

/// An arrival of a result, with the words below it the need goes on to.
const At = struct { a: Contract.Arrival, rest: []const u32 };

/// The arrivals of a result at `words`, and below them when `deep`: `m`'s
/// draft as it stands, else contract `c`.
fn arrivals(e: *Evaluation, m: ?Eval.Group.Member, c: Contract.Id, words: []const u32, deep: bool, out: *std.ArrayList(At)) Error!void {
    const a = e.ev.arena;
    if (m == null) return tree(e, e.contracts.head(c).res_root, words, deep, out);
    const r = &m.?.draft.res;
    try tree(e, r.base, words, deep, out);
    for (r.items.items) |it| {
        const sw = e.fr().slots.relWords(it.slot);
        const above = std.mem.startsWith(u32, words, sw);
        if (it.node != 0) {
            if (above) try tree(e, it.node, words[sw.len..], deep, out) else if (deep and std.mem.startsWith(u32, sw, words)) try tree(e, it.node, &.{}, true, out);
            continue;
        }
        if (above and (sw.len == words.len or r.isOpen(it))) try out.append(a, .{ .a = it.a, .rest = words[sw.len..] }) else if (deep and std.mem.startsWith(u32, sw, words)) try out.append(a, .{ .a = it.a, .rest = &.{} });
    }
}

fn tree(e: *Evaluation, root: Contract.Node, words: []const u32, deep: bool, out: *std.ArrayList(At)) Error!void {
    if (root == 0) return;
    const a = e.ev.arena;
    const t = &e.contracts.trees;
    var hits: std.ArrayList(Contract.Hit) = .empty;
    _ = try Forest.atSlot(t, a, root, words, &hits);
    for (hits.items) |h| for (h.arrivals) |r| try out.append(a, .{ .a = r, .rest = words[h.depth..] });
    if (!deep) return;
    const n = Forest.at(t, root, words) orelse return;
    const es = try LabelChain.entriesOf(e.chain(), n);
    for (es.items.items) |y| if (es.wordsOf(y).len != 0) for (y.arrivals) |r| try out.append(a, .{ .a = r, .rest = &.{} });
}

/// Known code `v` answers at the need: each arrival by its kind (§2.11.3).
fn discharge(st: *State, e: *Evaluation, x: u32, q: u32, l: Contract.Label, v: u32, n: Effect) Error!bool {
    const f = e.fr();
    const vc = f.calls.items[v];
    const words = f.slots.relWords(n.slot);
    const m = memberOf(e, vc);
    var hs: std.ArrayList(At) = .empty;
    try arrivals(e, m, vc.contract, words, n.deep, &hs);
    const own = vc.args.len - f.kidsOf(f.val(vc.callee_val)).len;
    var new = false;
    for (hs.items) |h| {
        const a = h.a;
        const rel = if (a.kind == .param or a.kind == .cb) try f.slots.relOfWords(e.gpa(), f.account, f.places, try std.mem.concat(e.ev.arena, u32, &.{ f.slots.relWords(a.slot), h.rest })) else n.slot;
        if (!try st.first(e.gpa(), .{ x, v, @backingInt(a.kind), a.j, rel, @intFromBool(n.deep or a.deep) })) continue;
        new = true;
        const from = e.demands.items.len;
        switch (a.kind) {
            .fresh => {
                var ls: std.ArrayList(u32) = .empty;
                try e.ev.arrivalLeaves(v, vc.contract, a, &.{}, &ls);
                const t_start: u32 = @intCast(e.w.leaf_runs.items.len);
                try e.w.leaf_runs.appendSlice(e.gpa(), ls.items);
                var d = try base(e, q, l);
                d.targets = .{ .start = t_start, .len = @intCast(ls.items.len) };
                d.fresh_answer = true;
                try Eval.addDemand(e, d);
            },
            .param => if (a.j < own) try Eval.callWrite(e, v, .{ .j = a.j, .slot = rel, .deep = n.deep or a.deep }) else try refuse(e, q, l),
            .cb => {
                const li = if (m != null) e.ev.live.?.labelIn(e.ev.live.?.ctx, vc.code, a.j, vc.contract) else a.j;
                if (li) |i| _ = try atLabel(st, e, x, v, i, .{ .j = 0, .slot = rel, .deep = n.deep or a.deep });
            },
            else => try refuse(e, q, l),
        }
        for (e.demands.items[from..]) |*d| {
            d.quiet = true;
            if (words.len != 0) d.res_of = v;
        }
    }
    return new;
}

/// A comparison has no caller to discharge a need (§2.13.13 item 13): with one
/// on a label of its draft, after the fixed point, each call that makes it is
/// refused. A write of the answer itself has a line of its own.
pub fn compared(e: *Evaluation, d: *const Contract.Draft) Error!void {
    for (d.labels.items) |l| {
        if (l.need.items.len != 0) break;
    } else return;
    const f = e.fr();
    for (f.calls.items, 0..) |call, q| {
        if (call.contract == none or call.virtual) continue;
        for (e.contracts.labelsOf(e.contracts.head(call.contract).labels)) |l| if (l.need.len != 0) {
            try refuse(e, @intCast(q), l);
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

fn refuse(e: *Evaluation, q: u32, l: Contract.Label) Error!void {
    var d = try base(e, q, l);
    d.need = true;
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

/// A closure with a need where it escapes: no caller reads its contract.
pub fn escaped(e: *Evaluation) Error!void {
    const f = e.fr();
    const gpa = e.gpa();
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);
    var read = false;
    for (e.w.closures.items) |cl| {
        const c = e.ctx.contractOf(e.ctx.ctx, cl.code) orelse continue;
        const wants = for (e.contracts.labelsOf(e.contracts.head(c).labels)) |l| {
            if (l.need.len != 0) break true;
        } else false;
        if (!wants) continue;
        if (!read and e.w.result != none) try e.ev.leavesOf(e.w.result, 0, &out);
        read = true;
        const left = blk: {
            for ([_][]const Eval.Escape{ e.escapes.items, e.fn_escapes.items }) |list| for (list) |es| {
                if (f.leafAt(es.leaf).kind == .site and f.leafAt(es.leaf).atom == cl.inst) break :blk true;
            };
            for (out.items) |lf| if (f.leafAt(lf).kind == .site and f.leafAt(lf).atom == cl.inst) break :blk true;
            break :blk false;
        };
        if (left) try e.demands.append(gpa, .{ .point = cl.point, .kind = .callsite, .token = Eval.tokenOf(e, cl.inst), .base_inst = cl.inst, .callback = true, .need = true });
    }
}
