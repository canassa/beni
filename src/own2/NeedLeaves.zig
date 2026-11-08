//! L11: where a value that carries a need goes (`docs/design/ownership-v2.md`
//! §2.11.3, *A value that carries a need*), split from `Needs`. A need is
//! discharged only by a caller that reads the label: a value that carries one
//! (`NeedCarry`) and escapes, is returned, or is handed to a call under no
//! label of its contract is refused `need`, at the closure that has the need.
//!
//! Obligations kept here: O14's need half (no value that carries a need
//! reaches code that cannot read it).

const std = @import("std");
const Ids = @import("Ids.zig");
const Value = @import("Value.zig");
const Eval = @import("Eval.zig");
const NeedCarry = @import("NeedCarry.zig");

const Error = Eval.Error;
const Evaluation = Eval.Evaluation;
const none: u32 = Ids.none_int;

/// What escapes or is returned, run by code no caller reads the contract of.
pub fn escaped(e: *Evaluation) Error!void {
    if (!NeedCarry.any(e.contracts, e.ctx, e.w.closures.items)) return;
    const gpa = e.gpa();
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(gpa);
    for ([_][]const Eval.Escape{ e.escapes.items, e.fn_escapes.items }) |list| for (list) |es| try ls.append(gpa, es.leaf);
    if (e.w.result != none) try e.ev.leavesOf(e.w.result, 0, &ls);
    try refuse(e, ls.items);
}

/// What a call is handed under no label of its contract: stored, kept or
/// run as unknown code, so no caller reads the need. A function a label runs
/// is the label's: its own needs pass on there, and what it captures is
/// handed to the label's virtual call, which this reads as any call.
pub fn stored(e: *Evaluation) Error!void {
    if (!NeedCarry.any(e.contracts, e.ctx, e.w.closures.items)) return;
    const f = e.fr();
    const gpa = e.gpa();
    var todo: std.ArrayList(u32) = .empty;
    defer todo.deinit(gpa);
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(gpa);
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    for (f.calls.items) |call| {
        // A choice's arms share their values: each value once per call, never once per route.
        seen.clearRetainingCapacity();
        ls.clearRetainingCapacity();
        try todo.appendSlice(gpa, call.args);
        while (todo.pop()) |v| {
            if ((try seen.getOrPut(gpa, .{v})).found_existing) continue;
            const x = f.val(v);
            switch (x.kind) {
                .scalar, .bot => {},
                .alt => {
                    var n: usize = 1;
                    while (n < x.kids.len) : (n += 2) try todo.append(gpa, x.kids[n]);
                },
                .built => if (x.form != .closure) try todo.appendSlice(gpa, f.kidsOf(x)) else if (!try labelled(e, call, v)) try e.ev.leavesOf(v, 0, &ls),
                else => if (!try labelled(e, call, v)) try e.ev.leavesOf(v, 0, &ls),
            }
        }
        try refuse(e, ls.items);
    }
}

/// A refused demand at each closure with a need that leaves `ls` reach, once an evaluation.
fn refuse(e: *Evaluation, ls: []const u32) Error!void {
    var hit: std.ArrayList(u32) = .empty;
    defer hit.deinit(e.gpa());
    try NeedCarry.reached(&e.ev, e.ctx, e.w.closures.items, ls, &hit);
    next: for (hit.items) |i| {
        const cl = e.w.closures.items[i];
        for (e.demands.items) |d| if (d.need and d.kind == .callsite and d.base_inst == cl.inst and d.point == cl.point) continue :next;
        try e.demands.append(e.gpa(), .{ .point = cl.point, .kind = .callsite, .token = Eval.tokenOf(e, cl.inst), .base_inst = cl.inst, .callback = true, .need = true });
    }
}

/// Whether `call`'s contract has a label that runs value `v`, whose need it then reads.
fn labelled(e: *Evaluation, call: Value.Call, v: u32) Error!bool {
    if (call.contract == none) return false;
    for (e.contracts.labelsOf(e.contracts.head(call.contract).labels)) |l| {
        if (l.j < call.args.len and try e.ev.valueAt(call.args[l.j], e.fr().slots.relWords(l.slot)) == v) return true;
    }
    return false;
}
