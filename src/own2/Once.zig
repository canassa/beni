//! L11: what a closure's creation asks of what its code writes
//! (`docs/design/ownership-v2.md` §2.11.4, R-2.8), split from `Eval`.
//!
//! Obligations kept here: none of §2.14's directly (`Resolve` judges these
//! demands).

const std = @import("std");
const Ids = @import("Ids.zig");
const Contract = @import("Contract.zig");
const Relation = @import("Relation.zig");
const Cells = @import("Cells.zig");
const Eval = @import("Eval.zig");

const none: u32 = Ids.none_int;

/// A closure whose code writes a capture (§2.11.4, R-2.8): a `once`
/// demand at its creation on each written capture. A cell operation on a
/// captured `Ref` is a `writer` demand on the cell's `◆` there instead,
/// never `once`: the code's frame keeps the write (§2.13.7).
pub fn demands(e: *Eval.Evaluation) Eval.Error!void {
    if (@import("Mutate.zig").on(.once_off)) return;
    const f = e.fr();
    const gpa = e.gpa();
    if (e.w.code.called != null) return; // The closures of a called code's creation are its body's.
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
            const cell = Eval.cellWrite(f.slots, wr);
            if (!cell and !h.flags.once) continue;
            const t_start: u32 = @intCast(e.w.leaf_runs.items.len);
            if (cell) try Cells.targets(&e.ev, caps[wr.j - sig.own], f.slots.relWords(wr.slot), &e.w.leaf_runs) else {
                var ps: std.ArrayList(Relation.Proj) = .empty;
                defer ps.deinit(gpa);
                try e.ev.project(caps[wr.j - sig.own], f.slots.relWords(wr.slot), wr.deep, 0, 0, &ps);
                for (ps.items) |p| try e.w.leaf_runs.append(gpa, p.leaf);
            }
            const cap_local = e.ctx.capturesOf(e.ctx.ctx, cl.code)[wr.j - sig.own];
            const write_path: Eval.PathId = if (cap_local != none) try Eval.pathAt(e, try e.ctx.placeOfLocal(e.ctx.ctx, cap_local), f.slots.relWords(wr.slot)) else .none;
            try e.demands.append(gpa, .{
                .point = cl.point,
                .kind = if (cell) .writer else .once,
                .cell = cell,
                .token = Eval.tokenOf(e, cl.inst),
                .base_inst = cl.inst,
                .base_local = cap_local,
                .write_path = write_path,
                .targets = .{ .start = t_start, .len = @intCast(e.w.leaf_runs.items.len - t_start) },
                .deep = wr.deep,
                .record = f.records and !cell and !wr.deep and @import("Update.zig").isRecord(f, try e.ev.valueAt(caps[wr.j - sig.own], f.slots.relWords(wr.slot))),
            });
        }
    }
}
