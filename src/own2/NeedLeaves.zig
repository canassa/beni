//! L11: where a closure with a need goes (`docs/design/ownership-v2.md` §2.11.3,
//! *A closure that leaves*), split from `Needs`. A need is discharged only by
//! a caller that reads the label: a closure that escapes, is returned, or is
//! handed to a call under no label of its contract is refused `need`.
//!
//! Obligations kept here: O14's need half (no closure with a need reaches code
//! that cannot read it).

const std = @import("std");
const Ids = @import("Ids.zig");
const Value = @import("Value.zig");
const Eval = @import("Eval.zig");
const W = @import("Walk.zig");

const Error = Eval.Error;
const Evaluation = Eval.Evaluation;
const none: u32 = Ids.none_int;

/// A closure with a need where it escapes: no caller reads its contract.
pub fn escaped(e: *Evaluation) Error!void {
    const f = e.fr();
    const gpa = e.gpa();
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);
    var read = false;
    for (e.w.closures.items) |cl| {
        if (!wants(e, cl.code)) continue;
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

/// A closure with a need handed to a call that runs it under no label of its
/// contract: stored, kept or run as unknown code, so no caller reads the need.
pub fn stored(e: *Evaluation) Error!void {
    const f = e.fr();
    const gpa = e.gpa();
    var todo: std.ArrayList(u32) = .empty;
    defer todo.deinit(gpa);
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    for (f.calls.items) |call| {
        // A choice's arms share their values: each value once per call, never once per route.
        seen.clearRetainingCapacity();
        try todo.appendSlice(gpa, call.args);
        while (todo.pop()) |v| {
            if ((try seen.getOrPut(gpa, .{v})).found_existing) continue;
            const x = f.val(v);
            if (x.kind == .alt) {
                var n: usize = 1;
                while (n < x.kids.len) : (n += 2) try todo.append(gpa, x.kids[n]);
            }
            if (x.kind != .built) continue;
            if (x.form != .closure) {
                try todo.appendSlice(gpa, f.kidsOf(x));
                continue;
            }
            if (!wants(e, x.head) or try labelled(e, call, v)) continue;
            const cl = for (e.w.closures.items) |c| {
                if (c.value == v) break c;
            } else continue;
            try e.demands.append(gpa, .{ .point = cl.point, .kind = .callsite, .token = Eval.tokenOf(e, cl.inst), .base_inst = cl.inst, .callback = true, .need = true });
        }
    }
}

fn wants(e: *Evaluation, head: u32) bool {
    const c = if (head & W.fixed_bit != 0) head & ~W.fixed_bit else e.ctx.contractOf(e.ctx.ctx, head) orelse return false;
    for (e.contracts.labelsOf(e.contracts.head(c).labels)) |l| if (l.need.len != 0) return true;
    return false;
}

/// Whether `call`'s contract has a label that runs value `v`, whose need it then reads.
fn labelled(e: *Evaluation, call: Value.Call, v: u32) Error!bool {
    if (call.contract == none) return false;
    for (e.contracts.labelsOf(e.contracts.head(call.contract).labels)) |l| {
        if (l.j < call.args.len and try e.ev.valueAt(call.args[l.j], e.fr().slots.relWords(l.slot)) == v) return true;
    }
    return false;
}
