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
const BelowSize = @import("BelowSize.zig");
const Contract = @import("Contract.zig");
const Forest = @import("Forest.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");
const Distinct = @import("Distinct.zig");
const Cells = @import("Cells.zig");
const Routed = @import("Routed.zig");
const Graft = @import("Graft.zig");
const RowEnv = @import("RowEnv.zig");
const Host = @import("Host.zig");
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
    /// Per frame label: the calls whose callee's label passes on to it, as `(call, callee label)` pairs, for the read-off of its supplies.
    passes: std.ArrayList([3]u32) = .empty,
    /// The group being solved, and this code's index in it (§2.12).
    solver: ?*const Group = null,
    x: u32 = none,
    /// The read-off under way (`factsOff`): later demands and escapes go into it as they are made.
    sink: Sink = undefined,
    facts_on: bool = false,
    hooks: Hooks = undefined,

    pub fn deinit(e: *Evaluation) void {
        const g = e.w.f.gpa;
        e.ev.deinit();
        e.demands.deinit(g);
        e.escapes.deinit(g);
        e.passes.deinit(g);
        if (e.facts_on) {
            inline for (.{ &e.sink.label_at, &e.sink.described, &e.sink.effected, &e.sink.building, &e.sink.nodes, &e.sink.acyclic, &e.sink.host, &e.sink.reads }) |l| l.deinit(g);
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
    e.* = .{ .w = w, .ev = .{ .f = &w.f, .contracts = contracts, .arena = arena, .routed = Routed.paramLeaves }, .contracts = contracts, .ctx = ctx, .solver = solver, .x = x };
    if (solver) |sv| e.ev.live = sv.live;
    e.ev.code_sig = .{ .ctx = ctx.ctx, .of = ctx.codeSig };
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
                    wild = wild or try BelowSize.wildBelow(gpa, f.places, p);
                };
                if (!at_site) wild = wild or try BelowSize.wildBelow(gpa, f.places, sig.result);
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
            if (h.flags.words) if (Cells.supply(e.contracts, f.slots, l)) |cs| try cellAnswer(e, q, l, cs, got.value_ptr.*);
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
            // What the passed-on code answers is stored in the cell, and it is unknown here (§2.13.7).
            if (h.flags.words) if (Cells.supply(e.contracts, f.slots, l)) |cs| try cellTaint(e, q, cs, &.{}, false, none);
            continue;
        }
        // Unknown code: its answer is unknown, and what it is handed escapes.
        for (e.contracts.suppliesOf(l.supplies)) |s| for ((try entriesOf(e, s.res_root)).items.items) |rs| {
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(gpa);
            const saved = e.ev.cur_sub;
            e.ev.cur_sub = .{ .kind = .escape, .a = call.point };
            defer e.ev.cur_sub = saved;
            for (rs.arrivals) |a| try supplyLeaves(e, q, a, &ls);
            e.ev.cur_sub = saved;
            for (ls.items) |lf| try addEscape(e, lf, call.point);
        };
    }
}

/// Every entry of tree `root`, in the canonical order, in the round.s arena.
pub fn entriesOf(e: *Evaluation, root: Contract.Node) Error!*Forest.Entries {
    const es = try e.ev.arena.create(Forest.Entries);
    es.* = .{};
    try es.of(&e.contracts.trees, e.ev.arena, e.fr().places, root, &.{});
    return es;
}

/// What a known cell callback answers is stored back in the cell
/// (§2.13.7). Where it may share what the cell holds with something else
/// (`Cells.shared`: a capture, a top-level value, an unknown answer), that
/// part of the contents escapes at the call (`cellTaint`), so a later edit
/// of it in place is refused `escaped`.
fn cellAnswer(e: *Evaluation, q: u32, l: Contract.Label, cs: Contract.Arrival, vi: u32) Error!void {
    const f = e.fr();
    const vc = f.calls.items[vi];
    const kh = e.contracts.head(vc.contract);
    // A code of the group being solved has no final contract yet.
    const solving = if (e.solver) |sv| vc.code != none and sv.member(sv.ctx, vc.code) != null else false;
    if (kh.flags.pessimistic or solving) return cellTaint(e, q, cs, &.{}, false, vi);
    var sh: std.ArrayList(Cells.Shared) = .empty;
    defer sh.deinit(e.gpa());
    // `Rows.fromWords` gives a `cellmodify` label offset 1: only `.1` is stored.
    try Cells.shared(try entriesOf(e, kh.res_root), l.origin[2] == 1, &sh, e.gpa());
    for (sh.items) |x| try cellTaint(e, q, cs, x.words, x.drop, vi);
}

/// What call `q`'s cell holds at `below` under its `◆` (less its first
/// step when `drop`) escapes at the call (§2.13.7): it may be held elsewhere
/// now. `vi`: the callback's virtual call, whose own writes of what it was
/// supplied this does not refuse.
fn cellTaint(e: *Evaluation, q: u32, cs: Contract.Arrival, bw: []const u32, drop: bool, vi: u32) Error!void {
    const f = e.fr();
    const gpa = e.gpa();
    const call = f.calls.items[q];
    if (cs.j >= call.args.len) return;
    const words = try std.mem.concat(e.ev.arena, u32, &.{ f.slots.relWords(cs.slot), bw[@min(@intFromBool(drop), bw.len)..] });
    var ps: std.ArrayList(Relation.Proj) = .empty;
    defer ps.deinit(gpa);
    try e.ev.project(call.args[cs.j], words, true, 0, 0, &ps);
    for (ps.items) |p| try addEscapeAt(e, p.leaf, call.point, vi);
}

/// An arrival of call `q`'s supply, as leaves (`Relation.arrivalLeaves`' rule, read from outside).
pub fn supplyLeaves(e: *Evaluation, q: u32, a: Contract.Arrival, out: *std.ArrayList(u32)) Error!void {
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
    // The writes a stop leaves, of one argument by one walk of it (`Routed`).
    var flat: std.ArrayList(Contract.Effect) = .empty;
    for (e.contracts.writesOf(h.writes)) |x| try callTree(e, q, .{ .j = x[0], .slot = Slots.root, .node = x[1] }, &flat);
    const pre = try Routed.ofWrites(&e.ev, call.args, flat.items);
    defer for (pre) |*p| if (p.*) |*l| l.deinit(e.gpa());
    for (flat.items, pre) |x, p| try callWriteFrom(e, q, x, if (p) |l| l.items else null, .{}, &.{});
}

/// Call `q`'s write tree `x`: grafted demands where it stops at a
/// parameter of the frame (`Graft`, §2.11.2), else written out (arena).
fn callTree(e: *Evaluation, q: u32, x: Contract.Effect, flat: *std.ArrayList(Contract.Effect)) Error!void {
    var gs: std.ArrayList(Graft.Group) = .empty;
    defer gs.deinit(e.gpa());
    const call = e.fr().calls.items[q];
    const g = (try Graft.stop(&e.ev, call, x, &gs)) orelse if (try Graft.literal(&e.ev, call, x, &gs)) Graft.Graft{} else return e.contracts.effectFlat(e.gpa(), e.ev.arena, e.fr().account, e.fr().slots, e.fr().places, x, flat);
    for (gs.items) |*gr| {
        defer gr.targets.deinit(e.gpa());
        defer gr.also.deinit(e.gpa());
        try callWriteFrom(e, q, gr.x, gr.targets.items, g, gr.also.items);
    }
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

/// Whether write `x` is a cell operation (`Cells.cellWrite`, §2.13.7).
pub const cellWrite = Cells.cellWrite;

/// A write of call `q`'s callee: a demand at the call. What it relies on
/// is instantiated once the group's facts are in (`finishDemands`).
pub fn callWrite(e: *Evaluation, q: u32, x: Contract.Effect) Error!void {
    var flat: std.ArrayList(Contract.Effect) = .empty;
    try callTree(e, q, x, &flat);
    for (flat.items) |y| try callWriteFrom(e, q, y, null, .{}, &.{});
}

fn callWriteFrom(e: *Evaluation, q: u32, x: Contract.Effect, pre: ?[]const Relation.Proj, graft: Graft.Graft, also_at: []const Slots.Rel) Error!void {
    const f = e.fr();
    const gpa = e.gpa();
    const call = f.calls.items[q];
    const site: ?CallSite = if (q < e.w.walk_calls) e.w.sites.items[q] else null;
    if (x.j >= call.args.len) return;
    const arg = call.args[x.j];
    const words = f.slots.relWords(x.slot);
    const t_start: u32 = @intCast(e.w.leaf_runs.items.len);
    if (pre) |ps| {
        for (ps) |p| try e.w.leaf_runs.append(gpa, p.leaf);
    } else if (x.deep) {
        var ps: std.ArrayList(Relation.Proj) = .empty;
        defer ps.deinit(gpa);
        try e.ev.project(arg, words, true, 0, 0, &ps);
        for (ps.items) |p| try e.w.leaf_runs.append(gpa, p.leaf);
    } else if (cellWrite(f.slots, x)) {
        try Cells.targets(&e.ev, arg, words, &e.w.leaf_runs);
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
    const base = Graft.argInst(call, x.j);
    // The path below the base, and the other routes a grouped demand covers,
    // by their steps: replayed only when the line is printed (§2.10).
    const named = base != call.inst and q < e.w.walk_calls and words.len != 0;
    const write_path: PathId = if (named) try f.places.rootPath(gpa, try e.ctx.placeOfInst(e.ctx.ctx, base)) else .none;
    const also = if (named) try f.arena.dupe(u32, also_at) else &.{};
    // A capture a known code writes is named by its local.
    const caps: []const u32 = if (!call.virtual and call.code != none and x.j >= call.arg_insts.len) e.ctx.capturesOf(e.ctx.ctx, call.code) else &.{};
    var d: Demand = .{
        .point = call.point,
        .base_local = if (caps.len != 0 and x.j - call.arg_insts.len < caps.len) caps[x.j - call.arg_insts.len] else none,
        .kind = if (x.deep) .consumed else .writer,
        .token = e.w.code.decl.inst_start.int(),
        .base_inst = base,
        .write_path = write_path,
        .write_rel = x.slot,
        .callee_inst = if (call.virtual) none else call.head,
        .targets = .{ .start = t_start, .len = @intCast(e.w.leaf_runs.items.len - t_start) },
        .deep = x.deep,
        .pending = if (site) |st| st.pending else none,
        .call = q,
        .arg = x.j,
        .cell = cellWrite(f.slots, x),
        .graft = .{ graft.j, graft.slot, graft.node },
        .also = also,
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
            // The outer call may be virtual too (a label of a known code's own label): the operands pending are the walked call's.
            var wq = o[0];
            while (wq >= e.w.walk_calls) wq = (virtualOuter(e, wq) orelse break)[0];
            d.pending = if (wq < e.w.walk_calls) e.w.sites.items[wq].pending else none;
            const oc = f.calls.items[o[0]];
            const lab = e.contracts.labelsOf(e.contracts.head(oc.contract).labels)[o[1]];
            // A cell callback's write of the contents is deep at the cell's
            // `◆`: an edit of what the cell holds, never a cell operation
            // (`cellWrite`), for every caller (§2.13.7).
            for (e.contracts.suppliesOf(lab.supplies)) |su| if (su.k == x.j) for ((try entriesOf(e, su.res_root)).items.items) |rs| for (rs.arrivals) |a| {
                if (a.kind == .param and Cells.throughContents(f.slots, a.slot)) d.deep = true;
            };
            for (e.contracts.suppliesOf(lab.supplies)) |su| if (su.k == x.j) {
                for (e.contracts.effectsOf(su.kept)) |kp| if (std.mem.startsWith(u32, words, f.slots.relWords(kp.slot)) or std.mem.startsWith(u32, f.slots.relWords(kp.slot), words)) {
                    d.kept = true;
                };
                if (lab.origin[2] & RowEnv.taken_origin != 0) d.taken_occs = try RowEnv.takenOccs(e.contracts, f.places, f.slots, f.account, gpa, e.ev.arena, su, words, x.deep);
            };
            // A virtual call's head is a code, never an instruction: the walked call names the demand.
            d.callee_inst = if (wq < e.w.walk_calls) f.calls.items[wq].head else none;
            const sa = (try supplyingArg(e, o[0], lab, x.j, words)) orelse Named{ .inst = oc.inst, .path = .none };
            d.base_inst = sa.inst;
            d.write_path, d.write_rel = .{ sa.path, 0 };
        }
    }
    try addDemand(e, d);
}

/// What each callee write relies on (§2.11.2 item 4), instantiated on its
/// call's arguments: after the group's facts are delivered, since the
/// distinct check reads every expansion whole.
pub fn finishDemands(e: *Evaluation) Error!void {
    const f = e.fr();
    // A call's instantiated `req`, made once a call (§2.11.2 item 4).
    const req_of = try e.ev.arena.alloc(?Cond, f.calls.items.len);
    @memset(req_of, null);
    for (e.demands.items) |*d| {
        if (d.call == none) continue;
        const call = f.calls.items[d.call];
        const c = if (req_of[d.call] == null) try e.contracts.cond(e.ev.arena, e.contracts.head(call.contract).req) else Cond.yes;
        if (req_of[d.call] == null) req_of[d.call] = (try Graft.movedReq(&e.ev, call, c)) orelse try Distinct.instSel(&e.ev, c, d.call);
        d.relies = req_of[d.call].?;
        if (!call.virtual) continue;
        const outer = virtualOuter(e, d.call) orelse continue;
        const lab = e.contracts.labelsOf(e.contracts.head(f.calls.items[outer[0]].contract).labels)[outer[1]];
        for (e.contracts.suppliesOf(lab.supplies)) |su| if (su.k == d.arg) {
            d.relies = try Cond.conj(e.ev.arena, f.account, d.relies, try Distinct.instSel(&e.ev, try e.contracts.cond(e.ev.arena, su.cond), outer[0]));
        };
        if (d.taken_occs) |os| {
            var run = os;
            d.relies = try Cond.conj(e.ev.arena, f.account, d.relies, try Distinct.instSel(&e.ev, try Cond.of(f.account, &run), outer[0]));
        }
    }
}

fn addDemand(e: *Evaluation, d: Demand) Error!void {
    try e.demands.append(e.gpa(), d);
    if (e.facts_on) try e.hooks.demand(e, e.demands.items.len - 1);
}

pub fn addEscape(e: *Evaluation, leaf: u32, point: u32) Error!void {
    return addEscapeAt(e, leaf, point, none);
}

fn addEscapeAt(e: *Evaluation, leaf: u32, point: u32, call: u32) Error!void {
    try e.escapes.append(e.gpa(), .{ .leaf = leaf, .point = point, .call = call });
    if (e.facts_on) try e.hooks.escape(e, leaf);
}

/// A virtual call's base as v1 names it: `List.foldl acc`.
const Named = struct { inst: u32, path: PathId };
/// Call `q`'s argument supplying `lab`'s parameter `k` written at `words`.
fn supplyingArg(e: *Evaluation, q: u32, lab: Contract.Label, k: u32, words: []const u32) Error!?Named {
    const f = e.fr();
    const call = f.calls.items[q];
    for (e.contracts.suppliesOf(lab.supplies)) |su| {
        if (su.k != k) continue;
        // The entries at the prefixes of `words`, shortest first.
        var n = su.res_root;
        for (0..words.len + 1) |d| {
            for ([_][]const Contract.Arrival{ e.contracts.trees.here(n), e.contracts.trees.open(n) }) |run| for (run) |a| {
                if (a.kind != .param or a.j >= call.arg_insts.len or call.arg_insts[a.j] == none) continue;
                const inst = call.arg_insts[a.j];
                const ws = try std.mem.concat(e.ev.arena, u32, &.{ f.slots.relWords(a.slot), words[d..] });
                return .{ .inst = inst, .path = if (q < e.w.walk_calls) try pathAt(e, try e.ctx.placeOfInst(e.ctx.ctx, inst), ws) else .none };
            };
            if (d == words.len) break;
            n = e.contracts.trees.kidAt(n, words[d]) orelse break;
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
/// demand at its creation on each written capture. A cell operation on a
/// captured `Ref` is a `writer` demand on the cell's `◆` there instead,
/// never `once`: the code's frame keeps the write (§2.13.7).
fn onceDemands(e: *Evaluation) Error!void {
    const f = e.fr();
    const gpa = e.gpa();
    for (e.w.closures.items) |cl| {
        const c = (e.ctx.contractOf(e.ctx.ctx, cl.code)) orelse continue;
        const h = e.contracts.head(c);
        const sig = try e.ctx.codeSig(e.ctx.ctx, cl.code);
        const x = f.val(cl.value);
        const caps = f.kidsOf(x);
        var flat: std.ArrayList(Contract.Effect) = .empty;
        try e.contracts.writesFlat(gpa, e.ev.arena, f.account, f.slots, f.places, h.writes, &flat);
        for (flat.items) |wr| {
            if (wr.j < sig.own or wr.j - sig.own >= caps.len) continue;
            const cell = cellWrite(f.slots, wr);
            if (!cell and !h.flags.once) continue;
            const t_start: u32 = @intCast(e.w.leaf_runs.items.len);
            if (cell) try Cells.targets(&e.ev, caps[wr.j - sig.own], f.slots.relWords(wr.slot), &e.w.leaf_runs) else {
                var ps: std.ArrayList(Relation.Proj) = .empty;
                defer ps.deinit(gpa);
                try e.ev.project(caps[wr.j - sig.own], f.slots.relWords(wr.slot), wr.deep, 0, 0, &ps);
                for (ps.items) |p| try e.w.leaf_runs.append(gpa, p.leaf);
            }
            const cap_local = e.ctx.capturesOf(e.ctx.ctx, cl.code)[wr.j - sig.own];
            const write_path: PathId = if (cap_local != none) try pathAt(e, try e.ctx.placeOfLocal(e.ctx.ctx, cap_local), f.slots.relWords(wr.slot)) else .none;
            try e.demands.append(gpa, .{
                .point = cl.point,
                .kind = if (cell) .writer else .once,
                .cell = cell,
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

/// The read-off.s entry points (`ReadOff.zig`): a demand or an escape made while it is under way, and a leaf delivered to it.
pub const Hooks = struct {
    demand: *const fn (e: *Evaluation, di: usize) Error!void,
    escape: *const fn (e: *Evaluation, leaf: u32) Error!void,
    deliver: *const fn (e: *Evaluation, sub: Relation.Sub, x: u32, at: u32) Error!void,
};

/// The read-off's sink: a draft and the frame's labels' indices in it.
pub const Sink = struct {
    e: *Evaluation,
    d: *Contract.Draft,
    arena: Allocator,
    /// Per frame label (`cbs`): its index in the draft's labels.
    label_at: std.ArrayList(u32) = .empty,
    /// `(leaf, slot, list label, list k)`: a call's leaf already described
    /// there. Describing it again adds nothing, and a fold's answer that
    /// feeds itself would describe it without end.
    described: Ids.FixedDict(4) = .{},
    /// `(leaf, deep, list)`: a leaf whose parameter effects are said already (effects only grow).
    effected: Ids.FixedDict(3) = .{},
    /// The subtrees described once per place (§2.10): arrivals go to the innermost, relative to it.
    building: std.ArrayList(Builder) = .empty,
    /// `(kind, a, b, c, place, d)` → a subtree described already; `none` while it is, `none - 1` where it cannot be.
    nodes: Ids.FixedDict(6) = .{},
    /// Per place: 1 when no place below it is on a cycle, else 2.
    acyclic: Ids.FixedDict(1) = .{},
    /// Per read `(from, q)`: its result slots (`ReadOff.destsOf`).
    reads: Relation.Dests.Reads(2) = .{},
    /// 0 not known; 1 nothing the frame reads grows; 2 something does.
    frozen: u8 = 0,
    /// The subtrees begun so far.
    serial: u32 = 0,
    /// The shallowest subtree in progress a description met again: nothing below it is kept.
    cut: usize = std.math.maxInt(usize),
    /// The sources the frame's escapes reach (§2.10, *host objects*).
    host: Host.State = .{},
};

/// A subtree being described at path `q` (`depth` steps from its root). `depth`: its serial number in the evaluation.
pub const Builder = struct { q: PathId, depth: u32, res: Contract.Draft.Res = .{} };

/// What `Resolve` tells the read-off: the accepted demands' reliance and each direct label's kept slots and condition.
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
    /// Member `x` gained arrival `a` at result slot `rel` (or subtree `n` below it).
    resFact: *const fn (ctx: *anyopaque, x: u32, rel: Slots.Rel, open: bool, a: Contract.Arrival, n: Contract.Node) Error!void,
    /// Member `x` gained a write (or an escape).
    effFact: *const fn (ctx: *anyopaque, x: u32, write: bool, eff: Contract.Effect) Error!void,

    pub const Member = struct { x: u32, draft: *Contract.Draft };
};
