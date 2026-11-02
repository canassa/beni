//! L8: an evaluation of one walk (`docs/design/ownership-v2.md` §2.10–§2.12).
//!
//! **An evaluation** reads a walk (`Walk`) under the contracts its calls
//! read now (a group's candidates during the fixed point, the final ones at
//! the end): it maps each callee's labels, applies known codes to them
//! (virtual calls), makes each call's write demands, and reads the code's
//! contract off (§2.10 *Read-off*). `Resolve` judges the demands.
//!
//! Obligations kept here: O1 (unknown provenance: an unknown callee's
//! result is `⊤` and its arguments escape), O14 (a call is instantiated
//! once, its fresh objects one atom).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Subtree = @import("Subtree.zig");
const Contract = @import("Contract.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");
const Distinct = @import("Distinct.zig");
const W = @import("Walk.zig");

pub const Error = Ids.ChargeError;
pub const PathId = Ids.PathId;
pub const PlaceId = Ids.PlaceId;
const Step = Place.Step;
const Cond = Contract.Cond;
const none: u32 = Ids.none_int;
const Walk = W.Walk;
const Context = W.Context;
const Demand = W.Demand;
pub const Escape = W.Escape;
const CallSite = W.CallSite;
const fixed_bit = W.fixed_bit;

// ===========================================================================
// An evaluation (§2.10 *Read-off*, §2.11, §2.12)
// ===========================================================================

/// One evaluation of a walk under the contracts its calls read now.
pub const Evaluation = struct {
    w: *Walk,
    ev: Relation.Eval,
    contracts: *Contract.Table,
    ctx: Context,
    /// The walk's demands, then the calls' (this evaluation's).
    demands: std.ArrayList(Demand) = .empty,
    escapes: std.ArrayList(Escape) = .empty,
    /// Per frame label: the calls whose callee's label passes on to it, as
    /// `(call, callee label)` pairs, for the read-off of its supplies.
    passes: std.ArrayList([3]u32) = .empty,
    /// The group being solved, and this code's index in it (§2.12).
    solver: ?*const Group = null,
    x: u32 = none,
    /// The read-off under way (`factsOff`): later demands and escapes go
    /// into it as they are made.
    sink: Sink = undefined,
    facts_on: bool = false,

    pub fn deinit(e: *Evaluation) void {
        const g = e.w.f.gpa;
        e.ev.deinit();
        e.demands.deinit(g);
        e.escapes.deinit(g);
        e.passes.deinit(g);
        if (e.facts_on) {
            e.sink.label_at.deinit(g);
            e.sink.described.deinit(g);
            e.sink.effected.deinit(g);
        }
    }

    pub fn gpa(e: *Evaluation) Allocator {
        return e.w.f.gpa;
    }
    pub fn fr(e: *Evaluation) *Value.Frame {
        return &e.w.f;
    }
    fn account(e: *Evaluation) *Ids.Account {
        return e.w.f.account;
    }
};

/// Begin an evaluation of `w`: every call's contract read now, each
/// callee's labels mapped or applied, the calls' demands and escapes made.
pub fn evaluate(w: *Walk, contracts: *Contract.Table, ctx: Context, arena: Allocator, solver: ?*const Group, x: u32, e: *Evaluation) Error!void {
    e.* = .{ .w = w, .ev = .{ .f = &w.f, .contracts = contracts, .arena = arena }, .contracts = contracts, .ctx = ctx, .solver = solver, .x = x };
    if (solver) |sv| e.ev.live = sv.live;
    const f = &w.f;
    const gpa = f.gpa;
    try e.demands.appendSlice(gpa, w.demands.items);
    try e.escapes.appendSlice(gpa, w.escapes.items);
    // The contracts the walk's calls read now.
    for (f.calls.items[0..w.walk_calls]) |*c| {
        if (c.code != none) c.contract = (ctx.contractOf(ctx.ctx, c.code)) orelse try ctx.pessimistic(ctx.ctx, @intCast(c.args.len));
        if (c.contract == none) c.contract = try ctx.pessimistic(ctx.ctx, @intCast(c.args.len));
    }
    // A virtual call made by an earlier evaluation reads its code's contract now.
    for (f.calls.items[w.walk_calls..]) |*c| {
        if (c.code != none) c.contract = (ctx.contractOf(ctx.ctx, c.code)) orelse try ctx.pessimistic(ctx.ctx, @intCast(c.args.len));
    }
    // A construction's targets under the contracts read now.
    for (e.demands.items) |*d| if (d.base_value != none) {
        const t_start: u32 = @intCast(w.leaf_runs.items.len);
        var ls: std.ArrayList(u32) = .empty;
        defer ls.deinit(gpa);
        try e.ev.storageOf(d.base_value, 0, &ls);
        try w.leaf_runs.appendSlice(gpa, ls.items);
        d.targets = .{ .start = t_start, .len = @intCast(ls.items.len) };
    };
    var q: u32 = 0;
    while (q < f.calls.items.len) : (q += 1) try labelsOf(e, q);
    q = 0;
    while (q < f.calls.items.len) : (q += 1) try callEffects(e, q);
    try onceDemands(e);
}

/// Whether a type variable's or an opaque place is at or below `p`: a
/// place no step below it can name.
fn wildBelow(gpa: Allocator, places: *const Place.Table, p: PlaceId) Allocator.Error!bool {
    if (p == .none) return false;
    var seen: std.AutoHashMapUnmanaged(PlaceId, void) = .empty;
    defer seen.deinit(gpa);
    var stack: std.ArrayList(PlaceId) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, p);
    while (stack.pop()) |x| {
        if ((try seen.getOrPut(gpa, x)).found_existing) continue;
        switch (places.kind(x)) {
            .@"var", .@"opaque" => return true,
            else => {},
        }
        try stack.appendSlice(gpa, places.steps(x).children);
    }
    return false;
}

/// Map or apply the labels of call `q`'s callee (§2.11.3).
fn labelsOf(e: *Evaluation, q: u32) Error!void {
    const f = e.fr();
    const gpa = e.gpa();
    const call = f.calls.items[q];
    if (call.contract == none) return;
    const h = e.contracts.head(call.contract);
    for (e.contracts.labelsOf(h.labels), 0..) |l, li| {
        if (l.j >= call.args.len) continue;
        const arg = call.args[l.j];
        const fv = try e.ev.valueAt(arg, f.slots.relWords(l.slot));
        const x = f.val(fv);
        if (x.kind == .built and x.form == .closure and x.head & fixed_bit == 0) {
            // A known code: a virtual call of it on the label's supplies.
            const got = try e.w.virt.getOrPut(gpa, .{ q, @intCast(li) });
            if (!got.found_existing) {
                const sig = try e.ctx.codeSig(e.ctx.ctx, x.head);
                // The supplies and the answer at the call site's function
                // type, never the code's own: a polymorphic code (`a → a`)
                // has a type variable's place, which no step below it can
                // name (`.values` of an `R → R` label). Where the site's
                // type is not to hand, a code with such a place is unknown.
                var site: std.ArrayList(PlaceId) = .empty;
                defer site.deinit(gpa);
                const site_result: ?PlaceId = if (f.slots.relWords(l.slot).len == 0 and l.j < call.arg_insts.len) try e.ctx.siteSig(e.ctx.ctx, call.arg_insts[l.j], &site) else null;
                const at_site = site_result != null and site.items.len == sig.own;
                var wild = false;
                if (!at_site) for (sig.params[0..@min(sig.own, sig.params.len)]) |p| {
                    wild = wild or try wildBelow(gpa, f.places, p);
                };
                if (!at_site) wild = wild or try wildBelow(gpa, f.places, sig.result);
                var args: std.ArrayList(u32) = .empty;
                defer args.deinit(gpa);
                for (0..sig.own) |k| {
                    const sk = try e.w.supply_of.getOrPut(gpa, .{ q, @intCast(li), @intCast(k) });
                    if (!sk.found_existing) {
                        const si: u32 = @intCast(f.supplies.items.len);
                        const root = try f.addRoot(.supply, si, if (at_site) site.items[k] else if (k < sig.params.len) sig.params[k] else .none);
                        try f.supplies.append(gpa, .{ .call = q, .label = @intCast(li), .k = @intCast(k), .root = root });
                        sk.value_ptr.* = si;
                    }
                    try args.append(gpa, try f.refRoot(f.supplies.items[sk.value_ptr.*].root));
                }
                try args.appendSlice(gpa, f.kidsOf(x));
                const vi: u32 = @intCast(f.calls.items.len);
                const root = try f.addRoot(.call, vi, if (at_site) site_result.? else sig.result);
                const kids = try f.mkKids(args.items);
                try f.calls.append(gpa, .{ .inst = call.inst, .point = call.point, .args = kids, .arg_insts = &.{}, .root = root, .code = if (wild) none else x.head, .virtual = true, .answers = @intCast(li), .callee_val = fv });
                got.value_ptr.* = vi;
                f.calls.items[vi].contract = (if (wild) null else e.ctx.contractOf(e.ctx.ctx, x.head)) orelse try e.ctx.pessimistic(e.ctx.ctx, @intCast(kids.len));
            }
            try e.ev.known.put(gpa, .{ q, @intCast(li) }, got.value_ptr.*);
            continue;
        }
        if (x.kind == .ref and x.family == Slots.empty and f.roots.items[x.root].kind == .param) {
            // The frame's own parameter: the label passes on (one label per
            // origin and function slot, whatever call met it).
            const slot = try f.slots.relOf(gpa, f.account, f.places, f.pos.items[x.pos].slot);
            const j = f.roots.items[x.root].a;
            const got = try e.w.derived.getOrPut(gpa, .{ j, slot, l.origin[0], l.origin[1], l.origin[2] });
            if (!got.found_existing) {
                got.value_ptr.* = @intCast(f.cbs.items.len);
                try f.cbs.append(gpa, .{ .j = j, .slot = slot, .origin = l.origin });
            }
            try e.ev.label_map.put(gpa, .{ q, @intCast(li) }, got.value_ptr.*);
            try e.passes.append(gpa, .{ got.value_ptr.*, q, @intCast(li) });
            continue;
        }
        // Unknown code: its answer is unknown, and what it is handed escapes.
        for (e.contracts.suppliesOf(l.supplies)) |s| for (e.contracts.resOf(s.res)) |rs| {
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(gpa);
            const saved = e.ev.cur_sub;
            e.ev.cur_sub = .{ .kind = .escape, .a = call.point };
            defer e.ev.cur_sub = saved;
            for (e.contracts.arrivalsOf(rs.arrivals)) |a| try supplyLeaves(e, q, a, &ls);
            e.ev.cur_sub = saved;
            for (ls.items) |lf| try addEscape(e, lf, call.point);
        };
    }
}

/// An arrival of call `q`'s supply, as leaves (`Relation.arrivalLeaves`'
/// rule, read from outside).
fn supplyLeaves(e: *Evaluation, q: u32, a: Contract.Arrival, out: *std.ArrayList(u32)) Error!void {
    const f = e.fr();
    const call = f.calls.items[q];
    switch (a.kind) {
        .param => {
            if (a.j >= call.args.len) return out.append(e.gpa(), try f.leaf(.{ .kind = .top }));
            var ps: std.ArrayList(Relation.Proj) = .empty;
            defer ps.deinit(e.gpa());
            try e.ev.project(call.args[a.j], f.slots.relWords(a.slot), true, 0, 0, &ps);
            for (ps.items) |p| try out.append(e.gpa(), p.leaf);
        },
        else => try e.ev.arrivalLeaves(q, call.contract, a, &.{}, out),
    }
}

/// The base text's instruction and the write path of argument `j` at call `q`.
fn argBase(e: *Evaluation, q: u32, j: u32) u32 {
    const f = e.fr();
    const call = f.calls.items[q];
    if (j < call.arg_insts.len and call.arg_insts[j] != none) return call.arg_insts[j];
    return call.inst;
}

/// Call `q`'s writes and escapes (§2.11.2 items 4, 5): demands and escapes.
/// A member of the group being solved gives its draft's as they stand, and
/// the rest as its draft gains them (§2.12 *Deliveries*).
fn callEffects(e: *Evaluation, q: u32) Error!void {
    const f = e.fr();
    const call = f.calls.items[q];
    if (call.contract == none) return;
    if (e.solver) |sv| if (call.code != none) if (sv.member(sv.ctx, call.code)) |m| {
        try sv.watchEffects(sv.ctx, m.x, e.x, q);
        var i: usize = 0;
        while (i < m.draft.escapes.items.len) : (i += 1) try callEscape(e, q, m.draft.escapes.items[i]);
        i = 0;
        while (i < m.draft.writes.items.len) : (i += 1) try callWrite(e, q, m.draft.writes.items[i]);
        return;
    };
    const h = e.contracts.head(call.contract);
    for (e.contracts.effectsOf(h.escapes)) |x| try callEscape(e, q, x);
    for (e.contracts.effectsOf(h.writes)) |x| try callWrite(e, q, x);
}

/// An escape of call `q`'s callee: its projections escape at the call.
pub fn callEscape(e: *Evaluation, q: u32, x: Contract.Effect) Error!void {
    const f = e.fr();
    const gpa = e.gpa();
    const call = f.calls.items[q];
    if (x.j >= call.args.len) return;
    var ps: std.ArrayList(Relation.Proj) = .empty;
    defer ps.deinit(gpa);
    try e.ev.project(call.args[x.j], f.slots.relWords(x.slot), true, 0, 0, &ps);
    for (ps.items) |p| try addEscapeAt(e, p.leaf, call.point, q);
}

/// A write of call `q`'s callee: a demand at the call. What it relies on
/// is instantiated once the group's facts are in (`finishDemands`).
pub fn callWrite(e: *Evaluation, q: u32, x: Contract.Effect) Error!void {
    const f = e.fr();
    const gpa = e.gpa();
    const call = f.calls.items[q];
    const site: ?CallSite = if (q < e.w.walk_calls) e.w.sites.items[q] else null;
    if (x.j >= call.args.len) return;
    const arg = call.args[x.j];
    const words = f.slots.relWords(x.slot);
    const t_start: u32 = @intCast(e.w.leaf_runs.items.len);
    if (x.deep) {
        var ps: std.ArrayList(Relation.Proj) = .empty;
        defer ps.deinit(gpa);
        try e.ev.project(arg, words, true, 0, 0, &ps);
        for (ps.items) |p| try e.w.leaf_runs.append(gpa, p.leaf);
    } else if (words.len != 0 and Step.fromWord(words[words.len - 1]).kind == .contents) {
        // A cell's `◆` (§2.13.7): the contents position of each cell the
        // argument names, whatever its contents' type.
        var ps: std.ArrayList(Relation.Proj) = .empty;
        defer ps.deinit(gpa);
        try e.ev.project(arg, words[0 .. words.len - 1], false, 0, 0, &ps);
        for (ps.items) |p| {
            const l = f.leafAt(p.leaf);
            if (l.kind == .ref) if (try f.child(l.pos, .plain, Step.contents.word(), 0)) |cp| {
                const set = try f.slots.internSorted(gpa, f.account, &.{f.pos.items[cp].slot.int()});
                try e.w.leaf_runs.append(gpa, try f.leaf(.{ .kind = .ref, .root = l.root, .pos = cp, .slots = set, .tags = l.tags, .at_pos = true }));
                continue;
            };
            try e.w.leaf_runs.append(gpa, p.leaf);
        }
    } else if (words.len == 0) {
        var ls: std.ArrayList(u32) = .empty;
        defer ls.deinit(gpa);
        try e.ev.storageOf(arg, 0, &ls);
        try e.w.leaf_runs.appendSlice(gpa, ls.items);
    } else {
        var ps: std.ArrayList(Relation.Proj) = .empty;
        defer ps.deinit(gpa);
        try e.ev.project(arg, words, false, 0, 0, &ps);
        for (ps.items) |p| try e.w.leaf_runs.append(gpa, p.leaf);
    }
    // A write of nothing (a crossing value consumed) is no demand.
    if (e.w.leaf_runs.items.len == t_start) return;
    const base = argBase(e, q, x.j);
    const write_path: PathId = if (base != call.inst and q < e.w.walk_calls) try pathAt(e, try e.ctx.placeOfInst(e.ctx.ctx, base), words) else .none;
    // A capture a known code writes is named by its local.
    const caps: []const u32 = if (!call.virtual and call.code != none and x.j >= call.arg_insts.len) e.ctx.capturesOf(e.ctx.ctx, call.code) else &.{};
    var d: Demand = .{
        .point = call.point,
        .base_local = if (caps.len != 0 and x.j - call.arg_insts.len < caps.len) caps[x.j - call.arg_insts.len] else none,
        .kind = if (x.deep) .consumed else .writer,
        .token = e.w.code.decl.inst_start.int(),
        .base_inst = base,
        .write_path = write_path,
        .callee_inst = if (call.virtual) none else call.head,
        .targets = .{ .start = t_start, .len = @intCast(e.w.leaf_runs.items.len - t_start) },
        .deep = x.deep,
        .pending = if (site) |st| st.pending else .{},
        .call = q,
        .arg = x.j,
    };
    // The other arguments are its operands (§2.11.2 item 4): a write must
    // not reach what the call is also handed (`List.set b 0 (Node b)`).
    if (!call.virtual) {
        const o_start: u32 = @intCast(e.w.value_runs.items.len);
        for (call.args, 0..) |a, k| if (k != x.j) try e.w.value_runs.append(gpa, a);
        d.operands = .{ .start = o_start, .len = @intCast(e.w.value_runs.items.len - o_start) };
    }
    d.token = tokenOf(e, call.inst);
    if (call.virtual) {
        // A known code writes what a label supplies (§2.11.3): the
        // supply's distinctness condition is relied on too; a kept slot
        // refuses.
        d.callback = true;
        d.kind = .callsite;
        const outer = virtualOuter(e, q);
        if (outer) |o| {
            d.pending = e.w.sites.items[o[0]].pending;
            const oc = f.calls.items[o[0]];
            const lab = e.contracts.labelsOf(e.contracts.head(oc.contract).labels)[o[1]];
            for (e.contracts.suppliesOf(lab.supplies)) |su| if (su.k == x.j) {
                for (e.contracts.effectsOf(su.kept)) |kp| if (std.mem.startsWith(u32, words, f.slots.relWords(kp.slot)) or std.mem.startsWith(u32, f.slots.relWords(kp.slot), words)) {
                    d.kept = true;
                };
            };
            d.callee_inst = oc.head;
            const sa = (try supplyingArg(e, o[0], lab, x.j, words)) orelse Named{ .inst = oc.inst, .path = .none };
            d.base_inst = sa.inst;
            d.write_path = sa.path;
        }
    }
    try addDemand(e, d);
}

/// What each callee write relies on (§2.11.2 item 4), instantiated on its
/// call's arguments: after the group's facts are delivered, since the
/// distinct check reads every expansion whole.
pub fn finishDemands(e: *Evaluation) Error!void {
    const f = e.fr();
    for (0..e.demands.items.len) |di| {
        const d = &e.demands.items[di];
        if (d.call == none) continue;
        const call = f.calls.items[d.call];
        const h = e.contracts.head(call.contract);
        d.relies = try Distinct.instSel(&e.ev, try e.contracts.cond(e.ev.arena, h.req), d.call);
        if (!call.virtual) continue;
        const outer = virtualOuter(e, d.call) orelse continue;
        const oc = f.calls.items[outer[0]];
        const lab = e.contracts.labelsOf(e.contracts.head(oc.contract).labels)[outer[1]];
        const j = d.arg;
        for (e.contracts.suppliesOf(lab.supplies)) |su| if (su.k == j) {
            d.relies = try Cond.conj(e.ev.arena, f.account, d.relies, try Distinct.instSel(&e.ev, try e.contracts.cond(e.ev.arena, su.cond), outer[0]));
        };
    }
}

fn addDemand(e: *Evaluation, d: Demand) Error!void {
    try e.demands.append(e.gpa(), d);
    if (e.facts_on) try demandFacts(e, e.demands.items.len - 1);
}

fn addEscape(e: *Evaluation, leaf: u32, point: u32) Error!void {
    return addEscapeAt(e, leaf, point, none);
}

fn addEscapeAt(e: *Evaluation, leaf: u32, point: u32, call: u32) Error!void {
    try e.escapes.append(e.gpa(), .{ .leaf = leaf, .point = point, .call = call });
    if (e.facts_on) try paramEffects(&e.sink, leaf, true, .escapes);
}

/// A virtual call's base as v1 names it: `List.foldl acc`.
const Named = struct { inst: u32, path: PathId };
/// Call `q`'s argument supplying `lab`'s parameter `k` written at `words`.
fn supplyingArg(e: *Evaluation, q: u32, lab: Contract.Label, k: u32, words: []const u32) Error!?Named {
    const f = e.fr();
    const call = f.calls.items[q];
    for (e.contracts.suppliesOf(lab.supplies)) |su| {
        if (su.k != k) continue;
        for (e.contracts.resOf(su.res)) |rs| {
            const at = f.slots.relWords(rs.slot);
            if (!std.mem.startsWith(u32, words, at)) continue;
            for (e.contracts.arrivalsOf(rs.arrivals)) |a| {
                if (a.kind != .param or a.j >= call.arg_insts.len or call.arg_insts[a.j] == none) continue;
                const inst = call.arg_insts[a.j];
                const ws = try std.mem.concat(e.ev.arena, u32, &.{ f.slots.relWords(a.slot), words[at.len..] });
                return .{ .inst = inst, .path = if (q < e.w.walk_calls) try pathAt(e, try e.ctx.placeOfInst(e.ctx.ctx, inst), ws) else .none };
            }
        }
    }
    return null;
}

/// The path `words` replays to below place `at`, for a demand's text.
fn pathAt(e: *Evaluation, at: Place.PlaceId, words: []const u32) Error!PathId {
    if (words.len == 0) return .none;
    const f = e.fr();
    var ps: std.ArrayList(u32) = .empty;
    defer ps.deinit(e.gpa());
    try Slots.replay(e.gpa(), f.account, f.places, try f.places.rootPath(e.gpa(), at), words, &ps);
    return if (ps.items.len != 0) .from(ps.items[0]) else .none;
}

/// The walk's call a virtual call applies a label of: `(call, label)`.
pub fn virtualOuter(e: *Evaluation, q: u32) ?[2]u32 {
    var it = e.w.virt.keys.items;
    var i: usize = 0;
    while (i + 1 < it.len) : (i += 2) {
        if (e.w.virt.values.items[i / 2] == q) return .{ it[i], it[i + 1] };
    }
    _ = &it;
    return null;
}

pub fn tokenOf(e: *Evaluation, inst: u32) u32 {
    return e.w.bir.insts.items(.main_token)[inst];
}

/// A closure whose code writes a capture (§2.11.4, R-2.8): a `once`
/// demand at its creation on each written capture.
fn onceDemands(e: *Evaluation) Error!void {
    const f = e.fr();
    const gpa = e.gpa();
    for (e.w.closures.items) |cl| {
        const c = (e.ctx.contractOf(e.ctx.ctx, cl.code)) orelse continue;
        const h = e.contracts.head(c);
        if (!h.flags.once) continue;
        const sig = try e.ctx.codeSig(e.ctx.ctx, cl.code);
        const x = f.val(cl.value);
        const caps = f.kidsOf(x);
        for (e.contracts.effectsOf(h.writes)) |wr| {
            if (wr.j < sig.own or wr.j - sig.own >= caps.len) continue;
            const t_start: u32 = @intCast(e.w.leaf_runs.items.len);
            var ps: std.ArrayList(Relation.Proj) = .empty;
            defer ps.deinit(gpa);
            try e.ev.project(caps[wr.j - sig.own], f.slots.relWords(wr.slot), wr.deep, 0, 0, &ps);
            for (ps.items) |p| try e.w.leaf_runs.append(gpa, p.leaf);
            const cap_local = e.ctx.capturesOf(e.ctx.ctx, cl.code)[wr.j - sig.own];
            const write_path: PathId = if (cap_local != none) try pathAt(e, try e.ctx.placeOfLocal(e.ctx.ctx, cap_local), f.slots.relWords(wr.slot)) else .none;
            try e.demands.append(gpa, .{
                .point = cl.point,
                .kind = .once,
                .token = tokenOf(e, cl.inst),
                .base_inst = cl.inst,
                .base_local = cap_local,
                .write_path = write_path,
                .targets = .{ .start = t_start, .len = @intCast(e.w.leaf_runs.items.len - t_start) },
                .deep = wr.deep,
            });
        }
    }
}

// ---- read-off --------------------------------------------------------------

/// Where the read-off puts arrivals: the result's, or label `label`'s
/// supply `k` (an index into the draft's labels, never a pointer: the
/// lists grow while the facts are delivered).
const ResList = struct { label: u32 = none, k: u32 = 0 };
/// Where a parameter effect goes.
const EffList = enum(u8) { reads, writes, escapes };

/// The read-off's sink: a draft and the frame's labels' indices in it.
const Sink = struct {
    e: *Evaluation,
    d: *Contract.Draft,
    arena: Allocator,
    /// Per frame label (`cbs`): its index in the draft's labels.
    label_at: std.ArrayList(u32) = .empty,
    /// `(leaf, slot, list label, list k)`: a call's leaf already described
    /// there. Describing it again adds nothing, and a fold's answer that
    /// feeds itself would describe it without end.
    described: Ids.FixedDict(4) = .{},
    /// `(leaf, deep, list)`: a leaf whose parameter effects are said
    /// already. Effects only grow, so saying them again adds nothing.
    effected: Ids.FixedDict(3) = .{},
};

fn labelIndex(s: *Sink, cb: u32) Error!u32 {
    const gpa = s.e.gpa();
    while (s.label_at.items.len <= cb) try s.label_at.append(gpa, none);
    if (s.label_at.items[cb] != none) return s.label_at.items[cb];
    const c = s.e.fr().cbs.items[cb];
    const at = try s.d.labelOf(s.arena, c.j, c.slot, c.origin);
    s.label_at.items[cb] = at;
    return at;
}

fn resList(s: *Sink, l: ResList) Error!*std.ArrayList(Contract.Draft.DraftSlot) {
    if (l.label == none) return &s.d.res;
    return &(try s.d.labels.items[l.label].supplyOf(s.arena, l.k)).res;
}

fn effList(s: *Sink, l: EffList) *std.ArrayList(Contract.Effect) {
    return switch (l) {
        .reads => &s.d.reads,
        .writes => &s.d.writes,
        .escapes => &s.d.escapes,
    };
}

/// Run `expand` for consumer `sub`: it gets what the keys hold now (in
/// `out`) and, while a group is solved, every leaf they gain later.
fn expandFor(e: *Evaluation, li: u32, sub: Relation.Sub, out: *std.ArrayList(u32)) Error!void {
    const saved = e.ev.cur_sub;
    e.ev.cur_sub = if (e.solver != null) sub else null;
    defer e.ev.cur_sub = saved;
    try e.ev.expand(li, out);
}

/// Describe value `v` at result slot `q` of the result's root into `out`
/// (§2.10 *Read-off*): what arrives at each object slot.
fn describe(s: *Sink, v: u32, q: PathId, out: ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    const Item = struct { v: u32, q: PathId };
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, .{ .v = v, .q = q });
    while (stack.pop()) |it| {
        try f.charge(.inspection, 1);
        const x = f.val(it.v);
        switch (x.kind) {
            .scalar, .bot => {},
            .alt => {
                const ks = f.kidsOf(x);
                var i: usize = 0;
                while (i < ks.len) : (i += 2) try stack.append(gpa, .{ .v = ks[i + 1], .q = it.q });
            },
            .built => {
                if (x.site != none and Slots.isObject(f.places, it.q)) try arrive(s, it.q, .{ .kind = .fresh }, out);
                if (x.form == .list and x.head != 0) {
                    var ls: std.ArrayList(u32) = .empty;
                    defer ls.deinit(gpa);
                    try e.ev.storageOf(x.head - 1, 0, &ls);
                    for (ls.items) |l| try describeLeaf(s, l, it.q, false, out);
                }
                const ks = f.kidsOf(x);
                for (ks, 0..) |kv, n| {
                    const st: ?Step = switch (x.form) {
                        .tuple => try Step.index(f.account, @intCast(n)),
                        .ctor => try f.places.ctorStep(gpa, f.account, x.head, @intCast(n)),
                        .list => Step.elem,
                        .record => try Step.field(f.account, f.wordsOf(x.extra)[n]),
                        .closure => Step.env,
                        .opaque_ => null,
                    };
                    if (st) |stp| {
                        if (try f.places.extend(gpa, f.gc(), it.q, stp)) |nq| {
                            try stack.append(gpa, .{ .v = kv, .q = nq });
                            continue;
                        }
                    }
                    // A part the result's place does not name (an opaque
                    // value's): every object of it arrives at this slot.
                    var ls: std.ArrayList(u32) = .empty;
                    defer ls.deinit(gpa);
                    try e.ev.leavesOf(kv, 0, &ls);
                    for (ls.items) |l| try describeLeaf(s, l, it.q, true, out);
                }
            },
            .ref, .top, .shared => {
                var ls: std.ArrayList(u32) = .empty;
                defer ls.deinit(gpa);
                try e.ev.leavesOf(it.v, 0, &ls);
                for (ls.items) |l| try describeLeaf(s, l, it.q, false, out);
            },
        }
    }
}

/// An arrival at `q` and, by structure, at every slot below it.
fn arriveWide(s: *Sink, q: PathId, a: Contract.Arrival, out: ResList) Error!void {
    const f = s.e.fr();
    const r = try f.slots.relOf(s.e.gpa(), f.account, f.places, q);
    const list = try resList(s, out);
    try f.charge(.edge, 1);
    if (try Contract.Draft.addWide(list, s.arena, r, a)) {
        if (out.label == none) if (s.e.solver) |sv| try sv.resFact(sv.ctx, s.e.x, r, true, a);
    }
}

fn arrive(s: *Sink, q: PathId, a: Contract.Arrival, out: ResList) Error!void {
    const f = s.e.fr();
    const r = try f.slots.relOf(s.e.gpa(), f.account, f.places, q);
    const list = try resList(s, out);
    const open = f.places.kind(f.places.pathPlace(q)) == .@"var";
    if (open) try Contract.Draft.markOpen(list, s.arena, r);
    try f.charge(.edge, 1);
    if (try Contract.Draft.addArrival(list, s.arena, r, a)) {
        // A new fact of a member: delivered to what reads it (§2.12).
        if (out.label == none) if (s.e.solver) |sv| try sv.resFact(sv.ctx, s.e.x, r, open, a);
    }
}

/// A leaf at result slot `q`: its arrivals at `q` and below it. `whole`:
/// every object of it arrives at `q` itself.
fn describeLeaf(s: *Sink, li: u32, q: PathId, whole: bool, out: ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    const l = f.leafAt(li);
    switch (l.kind) {
        .site, .fresh => try arrive(s, q, .{ .kind = .fresh }, out),
        .shared => try arrive(s, q, .{ .kind = .shared, .j = l.atom, .slot = l.extra }, out),
        .top => try arrive(s, q, .{ .kind = .top }, out),
        .answer => try arrive(s, q, .{ .kind = .cb, .j = try labelIndex(s, l.atom), .slot = l.extra }, out),
        .ref => {
            const r = f.roots.items[l.root];
            const pslot = f.pos.items[l.pos].slot;
            // A value read back at its own place is read by its own
            // structure: an unstepped cast at a place structurally identical
            // to its inner's restores the inner exactly (§2.13.9), so the
            // result's storage is the position's, not every object below it.
            const by_structure = !whole or f.places.pathPlace(pslot) == f.places.pathPlace(q);
            // A call's or a supply's whole subtree read by structure is read
            // through one key below its position, never one per slot below it
            // (§2.10 *Read-off*).
            if (by_structure and (r.kind == .call or r.kind == .supply) and Subtree.wholeOf(f.slots, l.slots) == pslot) return describeCallWide(s, l, pslot, q, out);
            // A whole subtree (`↓p`, §2.3.1): a call's or a supply's through
            // one key below `p`, a parameter's read at `q` itself one deep
            // arrival; else named slot by slot, as a contract names each
            // result slot (§2.10).
            const held = r.kind == .call or r.kind == .supply or (r.kind == .param and !by_structure);
            if (held) for (Subtree.subs(f.slots, l.slots)) |el| {
                const x = Slots.pathOf(el);
                if (r.kind == .param) {
                    try arrive(s, q, .{ .kind = .param, .j = r.a, .slot = try f.slots.relOf(gpa, f.account, f.places, x), .deep = true }, out);
                } else try describeSub(s, l, pslot, x, q, by_structure, out);
            };
            for (if (held) Subtree.explicit(f.slots, l.slots) else f.slots.items(try Subtree.writeOut(f.slots, gpa, f.account, f.places, l.slots))) |sl| {
                // The result slot of this object: q, below by the steps from
                // the position to the slot.
                var at = q;
                if (by_structure) {
                    const rel = (try f.slots.relBelow(gpa, f.account, f.places, pslot, .from(sl))) orelse Slots.root;
                    var ps: std.ArrayList(u32) = .empty;
                    defer ps.deinit(gpa);
                    try Slots.replay(gpa, f.account, f.places, q, f.slots.relWords(rel), &ps);
                    if (ps.items.len == 0) {
                        at = q;
                    } else {
                        for (ps.items[1..]) |p2| try describeOne(s, l, r, sl, .from(p2), out);
                        at = .from(ps.items[0]);
                    }
                }
                try describeOne(s, l, r, sl, at, out);
            }
        },
    }
}

/// A call's or a supply's whole subtree `↓x` (§2.3.1) at result slot
/// `q`: by structure through one key below `x`, else all of it at `q`.
fn describeSub(s: *Sink, l: Value.Leaf, pslot: PathId, x: PathId, q: PathId, by_structure: bool, out: ResList) Error!void {
    const f = s.e.fr();
    const gpa = s.e.gpa();
    var dests: std.ArrayList(u32) = .empty;
    defer dests.deinit(gpa);
    if (by_structure) {
        const rel = (try f.slots.relBelow(gpa, f.account, f.places, pslot, x)) orelse Slots.root;
        try Slots.replay(gpa, f.account, f.places, q, f.slots.relWords(rel), &dests);
    }
    for (dests.items) |d| try describeCallWide(s, l, x, .from(d), out);
    if (dests.items.len != 0) return;
    const sub = try f.leaf(.{ .kind = .ref, .root = l.root, .pos = l.pos, .slots = try f.slots.internSorted(gpa, f.account, &.{x.int() | Slots.sub_bit}), .tags = l.tags });
    var xs: std.ArrayList(u32) = .empty;
    defer xs.deinit(gpa);
    try expandFor(s.e, sub, .{ .kind = .describe, .a = out.label, .b = q.int(), .c = out.k, .tags = l.tags }, &xs);
    for (xs.items) |y| try describeLeaf(s, y, q, true, out);
}

/// The subtree at `prefix` of a call's or a supply's root `root`, described
/// at result slot `q` through one key below the prefix (§2.10 *Read-off*).
fn describeBelow(s: *Sink, root: u32, prefix: PathId, tags: u32, q: PathId, out: ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const r = f.roots.items[root];
    const call: u32, const which: u32 = switch (r.kind) {
        .call => .{ r.a, none },
        .supply => blk: {
            const su = f.supplies.items[r.a];
            break :blk .{ su.call, (su.label << 16) | su.k };
        },
        .param, .cb => unreachable,
    };
    const saved = e.ev.cur_sub;
    e.ev.cur_sub = if (e.solver != null) .{ .kind = .describe_below, .a = out.label, .b = q.int(), .c = out.k, .d = prefix.int(), .tags = tags } else null;
    const ki = e.ev.instBelow(call, prefix, which) catch |err| {
        e.ev.cur_sub = saved;
        return err;
    };
    e.ev.cur_sub = saved;
    if ((try s.described.getOrPut(e.gpa(), .{ ki | Relation.open_bit, q.int(), out.label, out.k })).found_existing) return;
    var i: usize = 0;
    while (i < e.ev.keyItems(ki)[0].len) : (i += 1) {
        const items = e.ev.keyItems(ki);
        const y = (try f.withTags(items[0][i], tags)) orelse continue;
        try describeItem(s, y, items[1][i], prefix, q, out);
    }
}

/// An item of a key below `prefix` (leaf `li` at slot `at`), described at
/// the result slot the steps from the prefix take `q` to.
fn describeItem(s: *Sink, li: u32, at: u32, prefix: PathId, q: PathId, out: ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    const slot: PathId = .from(at & ~Relation.open_bit);
    const open = at & Relation.open_bit != 0;
    var ps: std.ArrayList(u32) = .empty;
    defer ps.deinit(gpa);
    if (slot == prefix) try ps.append(gpa, q.int()) else {
        const rel = (try f.slots.relBelow(gpa, f.account, f.places, prefix, slot)) orelse Slots.root;
        try Slots.replay(gpa, f.account, f.places, q, f.slots.relWords(rel), &ps);
        if (ps.items.len == 0) try ps.append(gpa, q.int());
    }
    for (ps.items) |dest| {
        // A type variable's slot has no structure below it: what is open
        // there is all of it at the slot, which `arrive` keeps open.
        const wide = open and f.places.kind(f.places.pathPlace(.from(dest))) != .@"var";
        if (wide) try describeWide(s, li, .from(dest), out) else try describeLeaf(s, li, .from(dest), true, out);
    }
}

/// The subtree of a call or a supply at its slot `sl`, at result slot
/// `dest` and below by structure. A slot that an opaque or a type
/// variable's place holds is read on through the call's arrivals (§2.13.9,
/// *On slots*), one result slot at a time, where the result's place is not
/// its own.
fn describeCallWide(s: *Sink, l: Value.Leaf, sl: PathId, dest: PathId, out: ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    try describeBelow(s, l.root, sl, l.tags, dest, out);
    const k = f.places.kind(f.places.pathPlace(sl));
    if ((k != .@"opaque" and k != .@"var") or f.places.pathPlace(sl) == f.places.pathPlace(dest)) return;
    for (f.slots.items(try Subtree.belowAll(f.slots, gpa, f.account, f.places, dest))) |qs| {
        const rel = (try f.slots.relBelow(gpa, f.account, f.places, dest, .from(qs))) orelse continue;
        const words = f.slots.relWords(rel);
        if (words.len == 0) continue;
        var ps: std.ArrayList(Relation.Proj) = .empty;
        defer ps.deinit(gpa);
        if (!try e.ev.throughCall(l.root, sl, words, false, l.tags, 0, &ps)) {
            const all = try f.leaf(.{ .kind = .ref, .root = l.root, .pos = l.pos, .slots = try Subtree.below(f.slots, gpa, f.account, f.places, sl), .tags = l.tags });
            try describeLeaf(s, all, .from(qs), true, out);
            continue;
        }
        for (ps.items) |p| try describeLeaf(s, p.leaf, .from(qs), true, out);
    }
}

/// Leaf `li` at result slot `q` and, by structure, at every slot below it.
fn describeWide(s: *Sink, li: u32, q: PathId, out: ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    const l = f.leafAt(li);
    switch (l.kind) {
        .site, .fresh => try arriveWide(s, q, .{ .kind = .fresh }, out),
        .shared => try arriveWide(s, q, .{ .kind = .shared, .j = l.atom, .slot = l.extra }, out),
        .top => try arriveWide(s, q, .{ .kind = .top }, out),
        .answer => try arriveWide(s, q, .{ .kind = .cb, .j = try labelIndex(s, l.atom), .slot = l.extra }, out),
        .ref => {
            const r = f.roots.items[l.root];
            // The leaf is a subtree of its root read at `q` by structure: its
            // base is the longest common prefix of its slots whose place is
            // `q`'s (a family's element, a position's own slot), and each
            // slot is at the result slot its steps from the base reach. A
            // leaf that is its base's whole subtree says each top slot once,
            // open; any other says each slot. Without such a base it is all
            // at `q` (a cast, §2.13.9).
            // A symbol `↓p` (§2.3.1) is the slot `p` read as a whole subtree.
            const items = f.slots.elems(l.slots);
            var rels = try gpa.alloc(Slots.Rel, items.len);
            defer gpa.free(rels);
            var cp: usize = std.math.maxInt(usize);
            var first: []const u32 = &.{};
            for (items, 0..) |sl, i| {
                rels[i] = try f.slots.relOf(gpa, f.account, f.places, Slots.pathOf(sl));
                const w = f.slots.relWords(rels[i]);
                if (i == 0) {
                    first = w;
                    cp = w.len;
                } else {
                    var n: usize = 0;
                    while (n < cp and n < w.len and w[n] == first[n]) n += 1;
                    cp = n;
                }
            }
            if (items.len == 0) return;
            var base: ?usize = null;
            var base_path: PathId = .none;
            // Never above the leaf's own position: what is above it is not this leaf.
            const floor = f.slots.relWords(try f.slots.relOf(gpa, f.account, f.places, f.pos.items[l.pos].slot)).len;
            var k: usize = cp + 1;
            while (k > floor) {
                k -= 1;
                var ps: std.ArrayList(u32) = .empty;
                defer ps.deinit(gpa);
                try Slots.replay(gpa, f.account, f.places, r.path, first[0..k], &ps);
                if (ps.items.len == 0) continue;
                if (f.places.pathPlace(.from(ps.items[0])) == f.places.pathPlace(q)) {
                    base = k;
                    base_path = .from(ps.items[0]);
                    break;
                }
            }
            const b = base orelse {
                // Read across a cast: a call's part through its arrivals,
                // anything else all of it at every result slot below `q`.
                const qs_all = f.slots.items(try Subtree.belowAll(f.slots, gpa, f.account, f.places, q));
                for (items, 0..) |sl, i| switch (r.kind) {
                    .call, .supply => {
                        const k2 = f.places.kind(f.places.pathPlace(Slots.pathOf(sl)));
                        if (k2 == .@"opaque" or k2 == .@"var") {
                            try describeCallWide(s, l, Slots.pathOf(sl), q, out);
                            continue;
                        }
                        const sub = try f.leaf(.{ .kind = .ref, .root = l.root, .pos = l.pos, .slots = if (Slots.isSub(sl)) try f.slots.internSorted(gpa, f.account, &.{sl}) else try Subtree.below(f.slots, gpa, f.account, f.places, Slots.pathOf(sl)), .tags = l.tags });
                        var xs: std.ArrayList(u32) = .empty;
                        defer xs.deinit(gpa);
                        try e.ev.expand(sub, &xs);
                        for (xs.items) |x| {
                            try describeLeaf(s, x, q, true, out);
                            for (qs_all) |qs| try describeLeaf(s, x, .from(qs), true, out);
                        }
                    },
                    .param => {
                        const pk = f.places.kind(f.places.pathPlace(Slots.pathOf(sl)));
                        const a: Contract.Arrival = .{ .kind = .param, .j = r.a, .slot = rels[i], .deep = Slots.isSub(sl) or pk == .@"var" or pk == .@"opaque" };
                        try arrive(s, q, a, out);
                        for (qs_all) |qs| try arrive(s, .from(qs), a, out);
                    },
                    .cb => {
                        const crel = (try f.slots.relBelow(gpa, f.account, f.places, r.path, Slots.pathOf(sl))) orelse Slots.root;
                        const a: Contract.Arrival = .{ .kind = .cb, .j = try labelIndex(s, r.a), .slot = crel };
                        try arrive(s, q, a, out);
                        for (qs_all) |qs| try arrive(s, .from(qs), a, out);
                    },
                };
                return;
            };
            const whole = l.slots == try Subtree.below(f.slots, gpa, f.account, f.places, base_path);
            var have: Ids.FixedDict(1) = .{};
            defer have.deinit(gpa);
            if (whole) for (rels) |rl| try have.put(gpa, .{rl}, 0);
            for (items, 0..) |sl, i| {
                const w = f.slots.relWords(rels[i]);
                // A slot below another of a whole subtree is said by it.
                if (whole) {
                    var below_other = false;
                    var m = w.len;
                    while (m > b) {
                        m -= 1;
                        if (have.get(.{try f.slots.relOfWords(gpa, f.account, f.places, w[0..m])}) != null) {
                            below_other = true;
                            break;
                        }
                    }
                    if (below_other) continue;
                }
                var ps: std.ArrayList(u32) = .empty;
                defer ps.deinit(gpa);
                try Slots.replay(gpa, f.account, f.places, q, w[b..], &ps);
                if (ps.items.len == 0) try ps.append(gpa, q.int());
                for (ps.items) |dest| switch (r.kind) {
                    .param => {
                        // An opaque or a type variable's slot holds anything
                        // below it: where the result's place is not its own,
                        // all of it arrives at each result slot (§2.13.9),
                        // never by steps the slot cannot take.
                        const pk = f.places.kind(f.places.pathPlace(Slots.pathOf(sl)));
                        const wild = pk == .@"var" or pk == .@"opaque";
                        const a: Contract.Arrival = .{ .kind = .param, .j = r.a, .slot = rels[i], .deep = wild };
                        if (wild and f.places.pathPlace(Slots.pathOf(sl)) != f.places.pathPlace(.from(dest))) {
                            for (f.slots.items(try Subtree.belowAll(f.slots, gpa, f.account, f.places, .from(dest)))) |qs| try arrive(s, .from(qs), a, out);
                        } else if (whole or Slots.isSub(sl)) try arriveWide(s, .from(dest), a, out) else try arrive(s, .from(dest), a, out);
                    },
                    .cb => {
                        const crel = (try f.slots.relBelow(gpa, f.account, f.places, r.path, Slots.pathOf(sl))) orelse Slots.root;
                        const a: Contract.Arrival = .{ .kind = .cb, .j = try labelIndex(s, r.a), .slot = crel };
                        if (whole or Slots.isSub(sl)) try arriveWide(s, .from(dest), a, out) else try arrive(s, .from(dest), a, out);
                    },
                    .call, .supply => if (whole or Slots.isSub(sl)) try describeCallWide(s, l, Slots.pathOf(sl), .from(dest), out) else {
                        const one = try f.leaf(.{ .kind = .ref, .root = l.root, .pos = l.pos, .slots = try f.slots.internSorted(gpa, f.account, &.{sl}), .tags = l.tags });
                        try describeLeaf(s, one, .from(dest), true, out);
                    },
                };
            }
        },
    }
}

fn describeOne(s: *Sink, l: Value.Leaf, r: Value.Root, sl: u32, at: PathId, out: ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    switch (r.kind) {
        .param => {
            const deep = f.places.kind(f.places.pathPlace(.from(sl))) == .@"var";
            try arrive(s, at, .{ .kind = .param, .j = r.a, .slot = try f.slots.relOf(gpa, f.account, f.places, .from(sl)), .deep = deep }, out);
        },
        .cb => {
            const rel = (try f.slots.relBelow(gpa, f.account, f.places, r.path, .from(sl))) orelse Slots.root;
            try arrive(s, at, .{ .kind = .cb, .j = try labelIndex(s, r.a), .slot = rel }, out);
        },
        .call, .supply => {
            const one = try f.leaf(.{ .kind = .ref, .root = l.root, .pos = l.pos, .slots = try f.slots.internSorted(gpa, f.account, &.{sl}), .tags = l.tags });
            if ((try s.described.getOrPut(gpa, .{ one, at.int(), out.label, out.k })).found_existing) return;
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(gpa);
            try expandFor(e, one, .{ .kind = .describe, .a = out.label, .b = at.int(), .c = out.k, .tags = l.tags }, &ls);
            for (ls.items) |x| try describeLeaf(s, x, at, true, out);
        },
    }
}

/// The effects of leaf `li` on the frame's parameters: each parameter slot
/// it names (expanded through calls), as `(j, slot)`.
fn paramEffects(s: *Sink, li: u32, deep: bool, out: EffList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    try stack.append(gpa, li);
    while (stack.pop()) |x| {
        if ((try seen.getOrPut(gpa, .{x})).found_existing) continue;
        if ((try s.effected.getOrPut(gpa, .{ x, @intFromBool(deep), @backingInt(out) })).found_existing) continue;
        const l = f.leafAt(x);
        if (l.kind != .ref) continue;
        const r = f.roots.items[l.root];
        switch (r.kind) {
            .param => {
                // A whole subtree (`↓p`, §2.3.1): one deep effect at `p`.
                for (f.slots.elems(l.slots)) |sl| {
                    if (Slots.isNot(sl)) continue;
                    const eff: Contract.Effect = .{ .j = r.a, .slot = try f.slots.relOf(gpa, f.account, f.places, Slots.pathOf(sl)), .deep = deep or Slots.isSub(sl) };
                    if (try Contract.Draft.addEffect(effList(s, out), s.arena, eff)) {
                        if (out != .reads) if (e.solver) |sv| try sv.effFact(sv.ctx, e.x, out == .writes, eff);
                    }
                }
            },
            .call, .supply => {
                var ls: std.ArrayList(u32) = .empty;
                defer ls.deinit(gpa);
                try expandFor(e, x, .{ .kind = .effect, .a = @backingInt(out), .b = @intFromBool(deep), .tags = l.tags }, &ls);
                try stack.appendSlice(gpa, ls.items);
            },
            .cb => {},
        }
    }
}

/// What `Resolve` tells the read-off: the accepted demands' reliance and
/// each direct label's kept slots and condition.
pub const Verdicts = struct {
    req: Cond = .{},
    /// Per frame label: the kept argument slots, as `(k, leaf)` pairs.
    kept: []const [3]u32 = &.{},
    /// Per frame label: the condition its supplies' check relied on.
    supply_cond: []const Cond = &.{},
    /// Per passed-on label (`passes`' index): the kept supply slots, as
    /// `(pass, k, leaf, at)` (`at`: the leaf's slot in the supply), and
    /// the condition its supplies' check relied on.
    pass_kept: []const [4]u32 = &.{},
    pass_cond: []const Cond = &.{},
};

/// A demand's written parameter slots (whatever its verdict).
fn demandFacts(e: *Evaluation, di: usize) Error!void {
    const dm = e.demands.items[di];
    for (e.w.leavesOfRun(dm.targets)) |t| try paramEffects(&e.sink, t, dm.deep, .writes);
}

/// The facts of the code's contract (§2.10 *Read-off*): its result's
/// arrivals, reads, writes, escapes and labels. While a group is solved
/// the read-off stays open: what the calls' keys gain later, and the
/// demands and escapes made later, arrive in the draft as they come.
pub fn factsOff(e: *Evaluation, arena: Allocator, d: *Contract.Draft) Error!void {
    const w = e.w;
    const f = e.fr();
    const gpa = e.gpa();
    const code = w.code;
    d.* = .{ .arity = @intCast(code.params.len + code.captures.len) };
    e.sink = .{ .e = e, .d = d, .arena = arena };
    e.facts_on = true;
    const s = &e.sink;
    const rpath = try f.places.rootPath(gpa, code.result_place);
    const rv = f.val(w.result);
    d.flags.returns = rv.kind != .bot;
    d.flags.cross = !Slots.holdsAny(f.places, rpath);
    if (d.flags.returns and !d.flags.cross) try describe(s, w.result, rpath, .{});
    // Reads: every use of a local whose value is a parameter's, at its path.
    for (w.uses.items) |u| {
        const b = w.bindings[u.local];
        if (b.value == none) continue;
        var ps: std.ArrayList(Relation.Proj) = .empty;
        defer ps.deinit(gpa);
        const lroot = try f.places.rootPath(gpa, try e.ctx.placeOfLocal(e.ctx.ctx, u.local));
        const rel = (try f.slots.relBelow(gpa, f.account, f.places, lroot, u.path)) orelse Slots.root;
        // A call use reads what its callee's footprint reads of the
        // argument (§2.10 *Read-off*, §2.11.2 item 1), not all of it.
        if (u.kind == .call and u.use_node != .none) foot: {
            const ft = w.foots.items[u.use_node.int()];
            const call = f.calls.items[ft[0]];
            if (call.contract == none) break :foot;
            const h = e.contracts.head(call.contract);
            if (h.flags.pessimistic) break :foot;
            for (e.contracts.effectsOf(h.reads)) |x| {
                if (x.j != ft[1]) continue;
                var words: std.ArrayList(u32) = .empty;
                defer words.deinit(gpa);
                try words.appendSlice(gpa, f.slots.relWords(rel));
                try words.appendSlice(gpa, f.slots.relWords(x.slot));
                var qs: std.ArrayList(Relation.Proj) = .empty;
                defer qs.deinit(gpa);
                try e.ev.project(b.value, words.items, x.deep, 0, 0, &qs);
                for (qs.items) |p| try paramEffects(s, p.leaf, x.deep, .reads);
            }
            continue;
        }
        try e.ev.project(b.value, f.slots.relWords(rel), true, 0, 0, &ps);
        for (ps.items) |p| try paramEffects(s, p.leaf, true, .reads);
    }
    // Writes: every demand's parameter targets, whatever its verdict.
    for (0..e.demands.items.len) |di| try demandFacts(e, di);
    // Escapes, deep.
    // By index: an escape made meanwhile is read off when it is made.
    const n_esc = e.escapes.items.len;
    for (0..n_esc) |i| try paramEffects(s, e.escapes.items[i].leaf, true, .escapes);
    // Labels: the direct ones with their arguments, the passed-on ones with
    // their callees' supplies.
    for (f.cbs.items, 0..) |cb, ci| {
        const at = try labelIndex(s, @intCast(ci));
        if (cb.inst != none) {
            const dl = &d.labels.items[at];
            dl.calls = if (cb.calls > 1 or dl.calls == .many) .many else if (dl.calls == .none) .once else .many;
            for (cb.args, 0..) |a, k| {
                _ = try d.labels.items[at].supplyOf(arena, @intCast(k));
                const ap = f.val(a).place;
                const root = if (ap != .none) try f.places.rootPath(gpa, ap) else rpath;
                try describe(s, a, root, .{ .label = at, .k = @intCast(k) });
            }
        }
    }
    for (e.passes.items) |p| {
        const at = try labelIndex(s, p[0]);
        const call = f.calls.items[p[1]];
        const lab = e.contracts.labelsOf(e.contracts.head(call.contract).labels)[p[2]];
        const dl = &d.labels.items[at];
        dl.calls = @fromBackingInt(@intCast(@max(@backingInt(dl.calls), @backingInt(lab.calls))));
        // The supplies at this call's function type: a callee's supply slot
        // of a type variable's place (`apply : (a → b), a → b`) takes the
        // whole argument, whose structure this frame's type names. Each
        // part arrives at its own slot below, as a direct label's argument
        // does: one arrival at the variable's slot would leave a write at
        // `.f0` of an `R` supply with nothing to read (§2.11.3).
        var site: std.ArrayList(PlaceId) = .empty;
        defer site.deinit(gpa);
        const at_site = f.slots.relWords(lab.slot).len == 0 and lab.j < call.arg_insts.len and call.arg_insts[lab.j] != none and
            (try e.ctx.siteSig(e.ctx.ctx, call.arg_insts[lab.j], &site)) != null;
        for (e.contracts.suppliesOf(lab.supplies)) |su| {
            if (at_site and su.k < site.items.len) for (e.contracts.resOf(su.res)) |rs| {
                for (e.contracts.arrivalsOf(rs.arrivals)) |a| {
                    if (a.kind != .param or a.j >= call.args.len) continue;
                    const v = try e.ev.valueAt(call.args[a.j], f.slots.relWords(a.slot));
                    var ps: std.ArrayList(u32) = .empty;
                    defer ps.deinit(gpa);
                    try Slots.replay(gpa, f.account, f.places, try f.places.rootPath(gpa, site.items[su.k]), f.slots.relWords(rs.slot), &ps);
                    for (ps.items) |p2| try describe(s, v, .from(p2), .{ .label = at, .k = su.k });
                }
            };
            _ = try d.labels.items[at].supplyOf(arena, su.k);
            for (e.contracts.resOf(su.res)) |rs| {
                for (e.contracts.arrivalsOf(rs.arrivals)) |a| {
                    var ls: std.ArrayList(u32) = .empty;
                    defer ls.deinit(gpa);
                    {
                        const saved = e.ev.cur_sub;
                        e.ev.cur_sub = if (e.solver != null) .{ .kind = .supply, .a = at, .b = su.k, .c = rs.slot } else null;
                        defer e.ev.cur_sub = saved;
                        try supplyLeaves(e, p[1], a, &ls);
                    }
                    for (ls.items) |l| try supplyArrive(s, l, rs.slot, .{ .label = at, .k = su.k });
                }
            }
            const sup = try d.labels.items[at].supplyOf(arena, su.k);
            for (e.contracts.effectsOf(su.kept)) |kp| _ = try Contract.Draft.addEffect(&sup.kept, arena, kp);
        }
    }
}

/// A leaf delivered to a consumer of the read-off (§2.12 *Deliveries*).
pub fn deliver(e: *Evaluation, sub: Relation.Sub, x: u32, at: u32) Error!void {
    const f = e.fr();
    const y = (try f.withTags(x, sub.tags)) orelse return;
    switch (sub.kind) {
        .describe => try describeLeaf(&e.sink, y, .from(sub.b), true, .{ .label = sub.a, .k = sub.c }),
        .describe_below => try describeItem(&e.sink, y, at, .from(sub.d), .from(sub.b), .{ .label = sub.a, .k = sub.c }),
        .forward_below => unreachable,
        .effect => try paramEffects(&e.sink, y, sub.b != 0, @fromBackingInt(@intCast(sub.a))),
        .supply => try supplyArrive(&e.sink, y, sub.c, .{ .label = sub.a, .k = sub.b }),
        .escape => try addEscape(e, y, sub.a),
        .forward => unreachable,
    }
}

/// The conditions of the code's contract, once its facts are in: its
/// result's separation, what its writes rely on, its labels' supplies'
/// conditions and kept slots, and `once` (§2.10 *Read-off*).
pub fn condsOff(e: *Evaluation, arena: Allocator, v: Verdicts) Error!void {
    const w = e.w;
    const f = e.fr();
    const s = &e.sink;
    const d = s.d;
    const code = w.code;
    if (d.flags.returns and !d.flags.cross) d.res_cond = try Distinct.sepOf(&e.ev, w.result);
    // An arrival is read where the result is consumed.
    for (d.res.items) |rs| for (rs.arrivals.items) |a| if (a.kind == .param) {
        _ = try Contract.Draft.addEffect(&d.reads, arena, .{ .j = a.j, .slot = a.slot, .deep = true });
    };
    d.req = v.req;
    for (f.cbs.items, 0..) |cb, ci| {
        if (cb.inst == none) continue;
        const at = try labelIndex(s, @intCast(ci));
        for (cb.args, 0..) |_, k| {
            const sup = try d.labels.items[at].supplyOf(arena, @intCast(k));
            if (ci < v.supply_cond.len) sup.cond = try Cond.conj(arena, f.account, sup.cond, v.supply_cond[ci]);
        }
        for (v.kept) |kp| if (kp[0] == ci) {
            const sup = try d.labels.items[at].supplyOf(arena, kp[1]);
            try keptAt(s, kp[2], Slots.root, &sup.kept);
        };
    }
    for (e.passes.items, 0..) |p, pi| {
        const at = try labelIndex(s, p[0]);
        const call = f.calls.items[p[1]];
        const lab = e.contracts.labelsOf(e.contracts.head(call.contract).labels)[p[2]];
        for (e.contracts.suppliesOf(lab.supplies)) |su| {
            const sup = try d.labels.items[at].supplyOf(arena, su.k);
            sup.cond = try Cond.conj(arena, f.account, sup.cond, try Distinct.instSel(&e.ev, try e.contracts.cond(arena, su.cond), p[1]));
            if (pi < v.pass_cond.len) sup.cond = try Cond.conj(arena, f.account, sup.cond, v.pass_cond[pi]);
            for (v.pass_kept) |kp| if (kp[0] == pi and kp[1] == su.k) try keptAt(s, kp[2], kp[3], &sup.kept);
        }
    }
    // A code that writes one of its captures is `once` (R-2.8).
    for (d.writes.items) |x| if (x.j >= code.params.len) {
        d.flags.once = true;
    };
}

/// A leaf's arrivals, all at supply slot `rel`: a parameter's slots, an
/// answer's label, what a call or a supply comes from.
fn supplyArrive(s: *Sink, li: u32, rel: Slots.Rel, out: ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    try stack.append(gpa, li);
    while (stack.pop()) |x| {
        if ((try seen.getOrPut(gpa, .{x})).found_existing) continue;
        const l = f.leafAt(x);
        const a: Contract.Arrival = switch (l.kind) {
            .site, .fresh => .{ .kind = .fresh },
            .shared => .{ .kind = .shared, .j = l.atom, .slot = l.extra },
            .top => .{ .kind = .top },
            .answer => .{ .kind = .cb, .j = try labelIndex(s, l.atom), .slot = l.extra },
            .ref => {
                const r = f.roots.items[l.root];
                switch (r.kind) {
                    .param => for (f.slots.elems(l.slots)) |el| {
                        if (Slots.isNot(el)) continue;
                        const sl = Slots.pathOf(el);
                        _ = try Contract.Draft.addArrival(try resList(s, out), s.arena, rel, .{ .kind = .param, .j = r.a, .slot = try f.slots.relOf(gpa, f.account, f.places, sl), .deep = Slots.isSub(el) or f.places.kind(f.places.pathPlace(sl)) == .@"var" });
                    },
                    .cb => for (f.slots.items(try Subtree.writeOut(f.slots, gpa, f.account, f.places, l.slots))) |sl| {
                        const below = (try f.slots.relBelow(gpa, f.account, f.places, r.path, .from(sl))) orelse Slots.root;
                        _ = try Contract.Draft.addArrival(try resList(s, out), s.arena, rel, .{ .kind = .cb, .j = try labelIndex(s, r.a), .slot = below });
                    },
                    .call, .supply => {
                        var ls: std.ArrayList(u32) = .empty;
                        defer ls.deinit(gpa);
                        try expandFor(e, x, .{ .kind = .supply, .a = out.label, .b = out.k, .c = rel, .tags = l.tags }, &ls);
                        try stack.appendSlice(gpa, ls.items);
                    },
                }
                continue;
            },
        };
        _ = try Contract.Draft.addArrival(try resList(s, out), s.arena, rel, a);
    }
}

/// A kept leaf at supply slot `at`: its slots below `at`.
fn keptAt(s: *Sink, li: u32, at: Slots.Rel, out: *std.ArrayList(Contract.Effect)) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    const l = f.leafAt(li);
    if (l.kind != .ref) {
        _ = try Contract.Draft.addEffect(out, s.arena, .{ .j = 0, .slot = at, .deep = true });
        return;
    }
    const pslot = f.pos.items[l.pos].slot;
    for (f.slots.elems(l.slots)) |el| {
        if (Slots.isNot(el)) continue;
        const rel = (try f.slots.relBelow(gpa, f.account, f.places, pslot, Slots.pathOf(el))) orelse Slots.root;
        const ws = try std.mem.concat(s.arena, u32, &.{ f.slots.relWords(at), f.slots.relWords(rel) });
        _ = try Contract.Draft.addEffect(out, s.arena, .{ .j = 0, .slot = try f.slots.relOfWords(gpa, f.account, f.places, ws), .deep = Slots.isSub(el) });
    }
}

// ===========================================================================
// The group an evaluation is in (§2.12 step 2)
// ===========================================================================

/// The group being solved, as its evaluations see it: its members' drafts,
/// and where their new facts go. `Deliver.Solver` implements it.
pub const Group = struct {
    ctx: *anyopaque,
    live: *Relation.Live,
    /// Code `code`'s index and draft when it is a member, else null.
    member: *const fn (ctx: *anyopaque, code: u32) ?Member,
    /// Evaluation `y`'s call `call` of member `x` gets `x`'s later writes and escapes.
    watchEffects: *const fn (ctx: *anyopaque, x: u32, y: u32, call: u32) Error!void,
    /// Member `x` gained arrival `a` at result slot `rel`.
    resFact: *const fn (ctx: *anyopaque, x: u32, rel: Slots.Rel, open: bool, a: Contract.Arrival) Error!void,
    /// Member `x` gained a write (or an escape).
    effFact: *const fn (ctx: *anyopaque, x: u32, write: bool, eff: Contract.Effect) Error!void,

    pub const Member = struct { x: u32, draft: *Contract.Draft };
};
