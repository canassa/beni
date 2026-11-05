//! L12: the conditions of a code's contract, once its facts are in
//! (`docs/design/ownership-v2.md` §2.10 *Read-off*, §2.11), split from
//! `ReadOff`.
//!
//! Obligations kept here: none of §2.14's directly (`Resolve`'s verdicts
//! are read off here).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const Forest = @import("Forest.zig");
const Contract = @import("Contract.zig");
const Graft = @import("Graft.zig");
const Distinct = @import("Distinct.zig");
const Eval = @import("Eval.zig");
const Outward = @import("Outward.zig");
const SupplyCond = @import("SupplyCond.zig");
const SupplyAnswers = @import("SupplyAnswers.zig");
const Canon = @import("Canon.zig");
const Put = @import("Put.zig");

const Error = Eval.Error;
const none: u32 = Ids.none_int;
const PathId = Ids.PathId;
const Cond = Contract.Cond;
const Evaluation = Eval.Evaluation;
const Sink = Eval.Sink;
const Verdicts = @import("Kept.zig").Verdicts;

/// The conditions of the code's contract, once its facts are in: its
/// result's separation, what its writes rely on, its labels' supplies'
/// conditions and kept slots, and `once` (§2.10 *Read-off*).
pub fn condsOff(e: *Evaluation, arena: Allocator, v: Verdicts) Error!void {
    const w = e.w;
    const f = e.fr();
    const s = &e.sink;
    const d = s.d;
    if (d.flags.returns and !d.flags.cross) d.res_cond = try Distinct.sepOf(&e.ev, w.result);
    var arrs: std.ArrayList(Contract.Arrival) = .empty;
    for (d.res.items.items) |rs| {
        arrs.clearRetainingCapacity();
        if (rs.node == 0) try arrs.append(arena, rs.a) else try Forest.arrivalsOf(&e.contracts.trees, arena, f.places, rs.node, &arrs);
        for (arrs.items) |a| if (a.kind == .param) {
            _ = try Contract.Draft.addEffect(&d.reads, arena, .{ .j = a.j, .slot = a.slot, .deep = true });
        };
    }
    // A label's function is run, so what it holds is read (#2048).
    for (d.labels.items) |l| _ = try Contract.Draft.addEffect(&d.reads, arena, .{ .j = l.j, .slot = l.slot, .deep = true });
    d.req = try Graft.fold(&e.ev, v.req);
    for (f.cbs.items[w.last.cbs..], w.last.cbs..) |cb, ci| {
        if (cb.inst == none) continue;
        const at = try Put.labelIndex(s, @intCast(ci));
        for (cb.args, 0..) |_, k| {
            const sup = try d.labels.items[at].supplyOf(arena, @intCast(k));
            if (ci * v.width + k < v.supply_cond.len) sup.cond = try Cond.conj(arena, f.account, sup.cond, v.supply_cond[ci * v.width + k]);
        }
        for (v.kept) |kp| if (kp[0] == ci) {
            const sup = try d.labels.items[at].supplyOf(arena, kp[1]);
            try keptAt(s, kp[2], Slots.root, &sup.kept);
        };
    }
    for (e.passes.items, 0..) |p, pi| {
        const at = try Put.labelIndex(s, p[0]);
        const call = f.calls.items[p[1]];
        const lab = e.contracts.labelsOf(e.contracts.head(call.contract).labels)[p[2]];
        for (e.contracts.suppliesOf(lab.supplies)) |su| {
            const sup = try d.labels.items[at].supplyOf(arena, su.k);
            sup.cond = try Cond.conj(arena, f.account, sup.cond, try Distinct.instSelFeed(&e.ev, try e.contracts.cond(arena, su.cond), p[1], .{ .j = f.cbs.items[p[0]].j, .slot = f.cbs.items[p[0]].slot, .label = p[2], .covered = Distinct.Fed.covering(&e.ev, try e.contracts.cond(arena, su.cond), call) }));
            if (pi * v.width + su.k < v.pass_cond.len) sup.cond = try Cond.conj(arena, f.account, sup.cond, v.pass_cond[pi * v.width + su.k]);
            // Passed on inside a known code, the outer labels' too (#1721).
            try Outward.passSupply(e, arena, p[1], su, sup);
            for (v.pass_kept) |kp| if (kp[0] == pi and kp[1] == su.k) try keptAt(s, kp[2], kp[3], &sup.kept);
        }
    }
    try SupplyCond.publish(e, s, arena, Put.labelIndex);
    try SupplyAnswers.repeated(e, s.d, arena);
    var flat: std.ArrayList(Contract.Effect) = .empty;
    defer flat.deinit(e.gpa());
    for (d.writes.items) |x| if (x.j >= w.code.params.len) try e.contracts.effectFlat(e.gpa(), e.gpa(), f.account, f.slots, f.places, x, &flat);
    for (flat.items) |x| if (!Eval.cellWrite(f.slots, x)) {
        d.flags.once = true;
    };
    d.flags.taken_write, d.flags.entry = .{ d.flags.taken_write or e.marks.taken_write, d.flags.entry or e.marks.entry };
    // Each condition in its one spelling (§2.9.1, *One spelling of a subtree*).
    var nj: usize = 0;
    for (f.roots.items) |r| if (r.kind == .param) {
        nj = @max(nj, r.a + 1);
    };
    const roots = try arena.alloc(PathId, nj);
    @memset(roots, .none);
    for (f.roots.items) |r| if (r.kind == .param and r.a < roots.len) {
        roots[r.a] = r.path;
    };
    const cx: Canon.Ctx = .{ .gpa = e.gpa(), .arena = arena, .account = f.account, .slots = f.slots, .places = f.places, .roots = roots };
    d.res_cond = try Canon.canonical(cx, d.res_cond);
    d.req = try Canon.canonical(cx, d.req);
    for (d.labels.items) |*l| for (l.supplies.items) |*sup| {
        sup.cond = try Canon.canonical(cx, sup.cond);
    };
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
