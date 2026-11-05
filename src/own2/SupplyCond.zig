//! L11: what a write below a label's supply relies on
//! (`docs/design/ownership-v2.md` §2.11.3, *a taken supply*). `below` is a
//! claim the callee makes about what it hands, so it is derived from the
//! supplied value: `no` for `[ v, v ]`, a selection where it depends on the
//! parameters, `yes` only when shown. A write of the supply's root reaches
//! one object, which holds no copy of itself, and asks nothing of it.
//!
//! Obligations kept here: O14's label half: `below` holds at each call that
//! applies the label, outward; relaxed under a `taken` row, each written
//! slot is still asked plain (`RowEnv.takenOccs`).

const std = @import("std");
const Ids = @import("Ids.zig");
const Contract = @import("Contract.zig");
const Value = @import("Value.zig");
const LabelChain = @import("LabelChain.zig");
const Distinct = @import("Distinct.zig");
const Eval = @import("Eval.zig");

const Allocator = std.mem.Allocator;
const Cond = Contract.Cond;
const Error = Eval.Error;
const none: u32 = Ids.none_int;

/// The width of a table by label and argument: the most arguments of a
/// direct call, or the highest of `jobs`' `k`.
pub fn width(f: *const Value.Frame, jobs: anytype) usize {
    var w: usize = 1;
    for (jobs) |j| w = @max(w, j.k + 1);
    for (f.cbs.items) |cb| w = @max(w, cb.args.len);
    return w;
}

/// Each label's `below`: at a direct call, the separation of what it is
/// handed; at a pass, the callee's on the call's arguments and, inside a
/// known code, each outer label's its supply comes through.
pub fn publish(e: *Eval.Evaluation, s: anytype, arena: Allocator, labelIndex: anytype) Error!void {
    const f = e.fr();
    // A pass that closes an entry relies on `below` staying `no`
    // (`SupplyAnswers.closesAtSite`): no answer is read here.
    e.ev.read_mode = .strict;
    defer e.ev.read_mode = .ask;
    for (f.cbs.items[e.w.last.cbs..], e.w.last.cbs..) |cb, ci| if (cb.inst != none) {
        const at = try labelIndex(s, @intCast(ci));
        for (cb.args, 0..) |a, k| {
            const sup = try s.d.labels.items[at].supplyOf(arena, @intCast(k));
            sup.below = try Cond.conj(arena, f.account, sup.below, try Distinct.sepOf(&e.ev, a));
        }
    };
    for (e.passes.items) |p| {
        const at = try labelIndex(s, p[0]);
        const call = f.calls.items[p[1]];
        const lab = e.contracts.labelsOf(e.contracts.head(call.contract).labels)[p[2]];
        for (e.contracts.suppliesOf(lab.supplies)) |su| {
            const sup = try s.d.labels.items[at].supplyOf(arena, su.k);
            const c = try underTaken(e.chain(), arena, f.account, p[1], try e.contracts.cond(arena, su.below));
            const fd: Distinct.Fed.Feed = .{ .j = f.cbs.items[p[0]].j, .slot = f.cbs.items[p[0]].slot, .label = p[2], .covered = Distinct.Fed.covering(&e.ev, c, call) };
            sup.below = try Cond.conj(arena, f.account, sup.below, try Distinct.instSelFeed(&e.ev, c, p[1], fd));
            if (!call.virtual) continue;
            const own = call.args.len - f.kidsOf(f.val(call.callee_val)).len;
            const es = try Eval.entriesOf(e, su.res_root);
            for (es.items.items) |rs| for (rs.arrivals) |a| {
                if (a.kind != .param or a.j >= own) continue;
                var lvs: std.ArrayList(LabelChain.Level) = .empty;
                defer lvs.deinit(e.gpa());
                try LabelChain.supplyLevels(e.chain(), p[1], a.j, f.slots.relWords(a.slot), &lvs);
                for (lvs.items) |lv| for (e.contracts.suppliesOf(lv.lab.supplies)) |ou| if (ou.k == lv.k) {
                    sup.below = try Cond.conj(arena, f.account, sup.below, try Distinct.instSel(&e.ev, try e.contracts.cond(arena, ou.below), lv.call));
                };
            };
        }
    }
}

/// `c` of a label passed on at call `q`. Inside a `taken` row's label one
/// element is supplied and each write asks its slot plain, so what `c` says
/// of that element need only hold apart: said of the row's family, it would
/// ask rows to share no key the callback does not write.
fn underTaken(chain: LabelChain.Chain, arena: Allocator, account: *Ids.Account, q: u32, c: Cond) Error!Cond {
    if (c.no or !LabelChain.takenOutward(chain, q)) return c;
    const out = try arena.dupe(u64, c.sel);
    for (out) |*o| if (!Contract.isFed(o.*)) {
        o.* = Contract.occApart(Contract.occParam(o.*), Contract.occRel(o.*)) | (o.* & Contract.deep_bit);
    };
    return Cond.of(account, out);
}
