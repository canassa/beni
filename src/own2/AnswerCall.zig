//! L8: an answers occurrence at a caller (`docs/design/ownership-v2.md`
//! §2.11.3, *a traversal's supply*): renamed where the label passes on,
//! decided from the known code applied there, over every label of the slot.
//! `F` is `FedCall`, of this layer.
//!
//! Obligations kept here: O14's rule for a `within` over answers (§2.14).

const std = @import("std");
const Forest = @import("Forest.zig");
const Contract = @import("Contract.zig");
const AnsOcc = @import("AnsOcc.zig");
const Relation = @import("Relation.zig");

const Error = Relation.Error;
const Eval = Relation.Eval;
const Cond = Contract.Cond;

/// An answers occurrence `o` of call `call`'s callee, decided there: `plain`
/// gets what the callee's occurrences then ask of what it hands, `own` what
/// the known codes' results ask, `fed` the occurrence where the label passes
/// on. False: `no`.
pub fn at(e: *Eval, call: u32, o: u64, instCond: anytype, comptime F: type, plain: *std.ArrayList(u64), own: *Cond, fed: *std.ArrayList(u64)) Error!bool {
    if (@import("Mutate.zig").on(.answer_call_no)) return false;
    const c = e.contractOf(call) orelse return false;
    const j = Contract.fedParam(o);
    const k = AnsOcc.arg(o);
    var hit = false;
    for (e.contracts.labelsOf(e.contracts.head(c).labels), 0..) |lab, li| {
        if (lab.j != j or lab.slot != Contract.occRel(o)) continue;
        hit = true;
        if (e.label_map.get(.{ call, @intCast(li) })) |fc| {
            const cb = e.f.cbs.items[fc];
            try fed.append(e.arena, AnsOcc.occ(cb.j, cb.slot, k));
            continue;
        }
        const r = e.alts.codes(&e.known, call, @intCast(li)) orelse return false;
        var handed = false;
        for (r[0]..r[0] + r[1]) |vi| if (!try known(e, @intCast(vi), k, instCond, F, own, fed, &handed)) return false; // Each of an `alt`'s too (#2322).
        if (!handed) continue;
        for (e.contracts.suppliesOf(lab.supplies)) |su| if (su.k == k) {
            // Handed a value the callee could not say holds each object once.
            if (su.cond.no or su.below.no) return false;
            var es: Forest.Entries = .{};
            defer es.deinit(e.gpa());
            try es.of(&e.contracts.trees, e.gpa(), e.places(), su.res_root, &.{});
            for (es.items.items) |rs| for (rs.arrivals) |a| switch (a.kind) {
                .fresh => {},
                .param => try plain.append(e.arena, Contract.occDeep(Contract.occ(a.j, a.slot))),
                else => return false,
            };
        };
    }
    return hit;
}

/// Whether known code `vi`, run on its argument `k`, answers what `at` asks
/// (`handed`: it answers a part of `k`).
fn known(e: *Eval, vi: u32, k: u32, instCond: anytype, comptime F: type, own: *Cond, fed: *std.ArrayList(u64), handed: *bool) Error!bool {
    const kh = e.contracts.head(e.contractOf(vi) orelse return false);
    if (kh.flags.pessimistic) return false;
    const kc = try instCond(e, vi);
    if (kc.no) return false;
    own.* = try Cond.conj(e.arena, e.account(), own.*, kc);
    const vc = e.f.calls.items[vi];
    const root = e.f.roots.items[vc.root].path;
    var es: Forest.Entries = .{};
    defer es.deinit(e.gpa());
    try es.of(&e.contracts.trees, e.gpa(), e.places(), kh.res_root, &.{});
    for (es.items.items) |rs| {
        if (!try F.holdsAt(e, root, es.wordsOf(rs))) continue;
        for (rs.arrivals) |a| switch (a.kind) {
            .fresh => {},
            .param => {
                if (a.j == k) {
                    handed.* = true;
                    continue;
                }
                const x = if (a.j < vc.args.len) e.f.val(vc.args[a.j]) else return false;
                if (x.kind != .ref or try F.holdsAt(e, e.f.pos.items[x.pos].slot, e.f.slots.relWords(a.slot))) return false;
            },
            .cb => {
                const k2 = if (k == Contract.fresh_arg) k else (try F.supplyOf(e, vi, a.j, k)) orelse Contract.fresh_arg;
                if (k2 != Contract.fresh_arg) handed.* = true;
                if (e.label_map.get(.{ vi, a.j })) |fc| {
                    const cb = e.f.cbs.items[fc];
                    try fed.append(e.arena, AnsOcc.occ(cb.j, cb.slot, k2));
                } else {
                    const r2 = e.alts.codes(&e.known, vi, a.j) orelse return false;
                    var h2 = false;
                    for (r2[0]..r2[0] + r2[1]) |v2| if (!try known(e, @intCast(v2), k2, instCond, F, own, fed, &h2)) return false;
                }
            },
            else => return false,
        };
    }
    return true;
}
