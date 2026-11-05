//! L8: a callee's `fed` occurrence at a call (`docs/design/ownership-v2.md`
//! §2.11.3, *a label's answer handed back to it*): read at a caller, the
//! occurrence is renamed onto the caller's function slot where the label
//! passes on, or decided by the known code applied there, from what its
//! answer holds (`Fed` reads the frame's own label's answer handed back).
//!
//! Obligations kept here: none of §2.14's directly (`Distinct.instSelFeed`
//! asks it; `Resolve` judges the part).

const std = @import("std");
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const Forest = @import("Forest.zig");
const Contract = @import("Contract.zig");
const Relation = @import("Relation.zig");

const Error = Relation.Error;
const Eval = Relation.Eval;

/// The argument `k` of the callee's label `label` at `call` that the
/// callee's parameter `j` arrives at whole (a fold's accumulator), if any.
pub fn supplyOf(e: *Eval, call: u32, label: u32, j: u32) Error!?u32 {
    const c = e.contractOf(call) orelse return null;
    const labs = e.contracts.labelsOf(e.contracts.head(c).labels);
    if (label >= labs.len) return null;
    var es: Forest.Entries = .{};
    defer es.deinit(e.gpa());
    for (e.contracts.suppliesOf(labs[label].supplies)) |su| {
        try es.of(&e.contracts.trees, e.gpa(), e.places(), su.res_root, &.{});
        for (es.items.items) |rs| {
            if (es.wordsOf(rs).len != 0) continue;
            for (rs.arrivals) |a| if (a.kind == .param and a.j == j and e.f.slots.relWords(a.slot).len == 0) return su.k;
        }
    }
    return null;
}

pub const Got = union(enum) { yes, no, occ: u64 };

/// A callee's `fed` occurrence `o` at call `call`: the caller's own when
/// the callee's function slot is one of the caller's parameters (the
/// label passes on), `yes` when it is a known code whose answer holds only
/// its argument `k` and fresh objects, else `no`.
pub fn at(e: *Eval, call: u32, o: u64) Error!Got {
    const c = e.contractOf(call) orelse return .no;
    const j = Contract.fedParam(o);
    const k = Contract.fedArg(o);
    for (e.contracts.labelsOf(e.contracts.head(c).labels), 0..) |lab, li| {
        if (lab.j != j or lab.slot != Contract.occRel(o)) continue;
        if (e.label_map.get(.{ call, @intCast(li) })) |fc| {
            const cb = e.f.cbs.items[fc];
            return .{ .occ = Contract.occFed(cb.j, cb.slot, k) };
        }
        const vi = e.known.get(.{ call, @intCast(li) }) orelse return .no;
        const kh = e.contracts.head(e.contractOf(vi) orelse return .no);
        if (kh.flags.pessimistic) return .no;
        // Its answer at a slot that holds no object (a scalar) carries none.
        const root = e.f.roots.items[e.f.calls.items[vi].root].path;
        var es: Forest.Entries = .{};
        defer es.deinit(e.gpa());
        try es.of(&e.contracts.trees, e.gpa(), e.places(), kh.res_root, &.{});
        // An answer that is the answer of a label `K` passes on to the
        // frame's, handed `k` whole (`λx acc → step x acc`): fed where that
        // label is, at the argument it is handed `k` as (#1721).
        var through: ?u64 = null;
        for (es.items.items) |rs| {
            if (!try holdsAt(e, root, es.wordsOf(rs))) continue;
            for (rs.arrivals) |a| switch (a.kind) {
                .param => if (a.j != k) {
                    const x = if (a.j < e.f.calls.items[vi].args.len) e.f.val(e.f.calls.items[vi].args[a.j]) else return .no;
                    if (x.kind != .ref or try holdsAt(e, e.f.pos.items[x.pos].slot, e.f.slots.relWords(a.slot))) return .no;
                },
                .fresh => {},
                .cb => {
                    if (es.wordsOf(rs).len != 0) return .no;
                    const fc = e.label_map.get(.{ vi, a.j }) orelse return .no;
                    const k2 = if (k == Contract.fresh_arg) k else (try supplyOf(e, vi, a.j, k)) orelse return .no;
                    const cb = e.f.cbs.items[fc];
                    const occ = Contract.occFed(cb.j, cb.slot, k2);
                    if (through) |t| if (t != occ) return .no;
                    through = occ;
                },
                else => return .no,
            };
        }
        if (through) |t| return .{ .occ = t };
        return .yes;
    }
    return .no;
}

/// Whether the place `words` below `root` may hold an object.
pub fn holdsAt(e: *Eval, root: Ids.PathId, words: []const u32) Error!bool {
    var ps: std.ArrayList(u32) = .empty;
    defer ps.deinit(e.gpa());
    try Slots.replay(e.gpa(), e.account(), e.places(), root, words, &ps);
    if (ps.items.len == 0) return true;
    for (ps.items) |p| if (Slots.holdsAny(e.places(), .from(p))) return true;
    return false;
}
