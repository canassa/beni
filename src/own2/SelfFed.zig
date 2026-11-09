//! L8: a known code's run handed its own answer back (`docs/design/ownership-v2.md`
//! §2.11.3, *a label's answer handed back to it*, at the caller): a
//! virtual call whose label hands the label's own answer back whole as its
//! argument `k` (a fold's accumulator) is asked its conditions on a twin
//! of that argument, which reads every arrival but that answer. An
//! invocation is handed the first value or an earlier invocation's answer,
//! one of them, never both: so the twin's objects stand for the first,
//! and the answer's own separation is the call's (`instCond`), by
//! induction on the invocations. `F` is `FedCall`, of this layer.
//!
//! Obligations kept here: none of §2.14's directly (`Distinct.instCond`
//! and `Distinct.reqOn` ask it; G12's cut stays for every other cycle).

const std = @import("std");
const Ids = @import("Ids.zig");
const Forest = @import("Forest.zig");
const Contract = @import("Contract.zig");
const Relation = @import("Relation.zig");
const Place = @import("Place.zig");
const SlotWords = @import("SlotWords.zig");

const Error = Relation.Error;
const Eval = Relation.Eval;
const Cond = Contract.Cond;
const none: u32 = Ids.none_int;

/// Virtual call `v`'s arguments, its fed argument `k` read through its twin.
pub const Twin = struct { k: u32, args: []const u32 };

/// The twin of virtual call `v`, or null: `v`'s label hands its own answer
/// back as argument `k`, at `k`'s root only; the known code answers `k` at
/// each slot it held it at, or fresh objects (`F.at`'s `fed`), and keeps
/// nothing (`keepsNothing`); no other argument of the label holds it.
pub fn of(e: *Eval, v: u32, comptime F: type) Error!?Twin {
    if (v >= e.applied.items.len or e.applied.items[v][0] == none) return null;
    const q, const li = e.applied.items[v];
    const kc = e.contractOf(v) orelse return null;
    const labs = e.contracts.labelsOf(e.contracts.head(e.contractOf(q) orelse return null).labels);
    if (li >= labs.len or e.contracts.head(kc).flags.pessimistic) return null;
    var es: Forest.Entries = .{};
    defer es.deinit(e.gpa());
    var got: ?u32 = null;
    for (e.contracts.suppliesOf(labs[li].supplies)) |su| {
        try es.of(&e.contracts.trees, e.gpa(), e.places(), su.res_root, &.{});
        for (es.items.items) |rs| for (rs.arrivals) |a| if (a.kind == .cb and a.j == li) {
            if (es.wordsOf(rs).len != 0 or (got != null and got.? != su.k)) return null;
            got = su.k;
        };
    }
    const k = got orelse return null;
    if (!try keepsNothing(e, kc, k)) return null;
    const vc = e.f.calls.items[v];
    if (k >= vc.args.len) return null;
    try es.of(&e.contracts.trees, e.gpa(), e.places(), e.contracts.head(kc).res_root, &.{});
    for (es.items.items) |rs| for (rs.arrivals) |a| if (a.kind == .param and a.j == k and !@import("Mutate.zig").on(.self_fed_slot_off) and e.f.slots.rels.find(es.wordsOf(rs)) != a.slot) return null;
    if (try F.at(e, q, Contract.occFed(labs[li].j, labs[li].slot, k), null) != .yes) return null;
    const args = try e.arena.dupe(u32, vc.args);
    args[k] = try twinOf(e, e.f.val(vc.args[k]).root, li);
    return .{ .k = k, .args = args };
}

/// Whether known code `kc` keeps nothing a later run writes (§2.11.3): no
/// store, cell write or label handed anything or letting its answer go; no
/// escape but of argument `k`, none at or above a slot of `k` it writes, or
/// below one it writes open. Else a cell or a capture may hold an object of
/// a run's answer that a later run edits in place through the accumulator.
fn keepsNothing(e: *Eval, kc: Contract.Id, k: u32) Error!bool {
    if (@import("Mutate.zig").on(.self_fed_keeps_ok)) return true;
    const h = e.contracts.head(kc);
    if (h.stores.len != 0) return false;
    for (e.contracts.labelsOf(h.labels)) |l| if (l.answer_left or l.supplies.len != 0) return false;
    var ws: std.ArrayList(Contract.Effect) = .empty;
    defer ws.deinit(e.gpa());
    try e.contracts.writesFlat(e.gpa(), e.gpa(), e.account(), e.f.slots, e.places(), h.writes, &ws);
    for (ws.items) |x| for (e.f.slots.relWords(x.slot)) |w| if (Place.Step.fromWord(w).kind == .contents) return false;
    for (e.contracts.effectsOf(h.escapes)) |x| {
        if (x.j != k) return false;
        const at = e.f.slots.relWords(x.slot);
        for (ws.items) |w| if (w.j == k) {
            const ww = e.f.slots.relWords(w.slot);
            if (SlotWords.under(e.places(), at, ww) != null or w.deep and SlotWords.under(e.places(), ww, at) != null) return false;
        };
    }
    return true;
}

/// The twin of supply root `r`, made once: a root of its own that reads
/// every arrival but label `li`'s answer (`Value.Frame.selfAnswer`).
fn twinOf(e: *Eval, r: u32, li: u32) Error!u32 {
    const si = e.f.roots.items[r].a;
    if (e.f.supplies.items[si].twin != none) return e.f.supplies.items[si].twin;
    var su = e.f.supplies.items[si];
    const ti: u32 = @intCast(e.f.supplies.items.len);
    su.root = try e.f.addRoot(.supply, ti, e.f.roots.items[r].place);
    su.no_self = li;
    try e.f.supplies.append(e.f.gpa, su);
    const t = try e.f.refRoot(su.root);
    e.f.supplies.items[si].twin = t;
    return t;
}
