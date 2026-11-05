//! L11: what the labels outward of a virtual call add
//! (`docs/design/ownership-v2.md` §2.11.2 item 4, §2.11.3). A demand a
//! known code's call makes relies on its callee's `req`, instantiated at
//! the call, and on each label its supply comes through (`LabelChain`):
//! their supplies' conditions and a `taken` row's container occurrences
//! (#1758, #1760). A label the frame passes on inside such a code takes the
//! same of every label outward for its own supplies (#1721).
//!
//! Obligations kept here: O14's label half (a supply's condition, and a
//! `taken` supply's container occurrences, hold at each call that applies
//! the label, outward).

const std = @import("std");
const Ids = @import("Ids.zig");
const Contract = @import("Contract.zig");
const RowEnv = @import("RowEnv.zig");
const LabelChain = @import("LabelChain.zig");
const Graft = @import("Graft.zig");
const Distinct = @import("Distinct.zig");
const Eval = @import("Eval.zig");
const CellEdit = @import("CellEdit.zig");
const FedWrite = @import("FedWrite.zig");

const Allocator = std.mem.Allocator;
const Error = Eval.Error;
const Cond = Contract.Cond;
const Evaluation = Eval.Evaluation;
const none: u32 = Ids.none_int;

/// What each callee write relies on (§2.11.2 item 4), on its call's arguments:
/// after the group's facts are delivered, the distinct check reads them whole.
pub fn finishDemands(e: *Evaluation) Error!void {
    const f = e.fr();
    const req_of = try e.ev.arena.alloc(?Cond, f.calls.items.len);
    @memset(req_of, null);
    for (e.demands.items) |*d| {
        if (d.call == none) continue;
        const call = f.calls.items[d.call];
        const c = if (req_of[d.call] == null) try e.contracts.cond(e.ev.arena, e.contracts.head(call.contract).req) else Cond.yes;
        if (req_of[d.call] == null) req_of[d.call] = (try Graft.movedReq(&e.ev, call, c)) orelse try Distinct.instSel(&e.ev, c, d.call);
        d.relies = req_of[d.call].?;
        const held = e.contracts.head(call.contract).flags.taken_write;
        if (held and try CellEdit.reachesParam(&e.ev, e.w.leavesOfRun(d.targets))) e.marks.taken_write = true;
        if (!call.virtual or d.wslot == none) continue;
        var lvs: std.ArrayList(LabelChain.Level) = .empty;
        defer lvs.deinit(e.gpa());
        try LabelChain.supplyLevels(e.chain(), d.call, d.arg, f.slots.relWords(d.wslot), &lvs);
        for (lvs.items) |lv| for (e.contracts.suppliesOf(lv.lab.supplies)) |su| if (su.k == lv.k) {
            const es = try Eval.entriesOf(e, su.res_root);
            if (lv.lab.calls == .many and CellEdit.ofElement(es, f.slots, lv.words) and try CellEdit.reachesParam(&e.ev, e.w.leavesOfRun(d.targets))) e.marks.taken_write = true;
            for (try FedWrite.relies(&e.ev, e.chain(), lv.lab, su, lv.call, lv.words, d.deep)) |x| d.relies = try Cond.conj(e.ev.arena, f.account, d.relies, x);
            if (su.each) continue;
            if (lv.lab.origin[2] & RowEnv.taken_origin != 0) if (try RowEnv.takenOccs(e.contracts, f.places, f.slots, f.account, e.gpa(), e.ev.arena, su, lv.words, d.deep)) |os| {
                d.relies = try Cond.conj(e.ev.arena, f.account, d.relies, try Distinct.instSel(&e.ev, try Cond.of(f.account, os), lv.call));
            };
        };
    }
}

/// A label the frame passes on at virtual call `q`, its supply `su`
/// (drafted as `sup`): passed on inside a known code an outer label runs,
/// what it is supplied is that label's supply, so the invocations'
/// supplies are apart only under each such label's condition too, and a
/// slot an outer label keeps is kept here, the part arriving from it whole
/// (#1721).
pub fn passSupply(e: *Evaluation, arena: Allocator, q: u32, su: Contract.Supply, sup: *Contract.Draft.DraftSupply) Error!void {
    const f = e.fr();
    const call = f.calls.items[q];
    if (!call.virtual) return;
    const own = call.args.len - f.kidsOf(f.val(call.callee_val)).len;
    const es = try Eval.entriesOf(e, su.res_root);
    for (es.items.items) |rs| for (rs.arrivals) |a| {
        if (a.kind != .param or a.j >= own) continue;
        var lvs: std.ArrayList(LabelChain.Level) = .empty;
        defer lvs.deinit(e.gpa());
        try LabelChain.supplyLevels(e.chain(), q, a.j, f.slots.relWords(a.slot), &lvs);
        for (lvs.items) |lv| for (e.contracts.suppliesOf(lv.lab.supplies)) |ou| if (ou.k == lv.k) {
            sup.cond = try Cond.conj(arena, f.account, sup.cond, try Distinct.instSel(&e.ev, try e.contracts.cond(arena, ou.cond), lv.call));
            for (e.contracts.effectsOf(ou.kept)) |kp| if (LabelChain.overlaps(lv.words, f.slots.relWords(kp.slot))) {
                _ = try Contract.Draft.addEffect(&sup.kept, arena, .{ .j = 0, .slot = try f.slots.relOfWords(e.gpa(), f.account, f.places, es.wordsOf(rs)), .deep = true });
            };
        };
    };
}

/// Whether call `q` is a known code's run by a label that calls it many
/// times, at any level outward (§2.11.3, #1721).
pub fn outwardMany(e: *Evaluation, q: u32) bool {
    return LabelChain.outwardMany(e.chain(), q);
}
