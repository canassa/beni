//! L11: a traversal's write of what an `entry` function is handed
//! (`docs/design/ownership-v2.md` §2.11.3, *a taken supply*; S7). v2 makes no
//! demand at an `entry` argument yet, so no caller judges a write of a
//! parameter of `update` or `view`, and a list reached from one stays held:
//! a function value marked `taken_write`, or with a label that has a need,
//! handed to an `entry` parameter is refused at that call, where master
//! refused the write itself. Nothing is accepted early: S7 owes both.
//!
//! Obligations kept here: none of §2.14's directly (`Resolve` refuses).

const std = @import("std");
const Ids = @import("Ids.zig");
const Contract = @import("Contract.zig");
const Eval = @import("Eval.zig");
const Walk = @import("Walk.zig");

const Error = Eval.Error;
const none: u32 = Ids.none_int;

/// A refused demand at each `entry` call handed a marked function; a call
/// handed a parameter's value marks the frame `entry` in its turn.
pub fn demands(e: *Eval.Evaluation) Error!void {
    if (@import("Mutate.zig").on(.entry_held_off)) return;
    const f = e.fr();
    for (f.calls.items, 0..) |call, q| {
        if (call.virtual or call.contract == none or !e.contracts.head(call.contract).flags.entry) continue;
        var todo: std.ArrayList(u32) = .empty;
        defer todo.deinit(e.gpa());
        try todo.appendSlice(e.gpa(), call.args);
        var seen: Ids.FixedDict(1) = .{};
        defer seen.deinit(e.gpa());
        while (todo.pop()) |v| {
            if ((try seen.getOrPut(e.gpa(), .{v})).found_existing) continue;
            const x = f.val(v);
            switch (x.kind) {
                .built => {
                    // A closure runs its code and holds its captures, which it may run.
                    if (x.form == .closure) if (markOf(e, x.head)) |need| try refuse(e, @intCast(q), v, need);
                    try todo.appendSlice(e.gpa(), f.kidsOf(x));
                },
                .alt => {
                    const ks = f.kidsOf(x);
                    var n: usize = 0;
                    while (n < ks.len) : (n += 2) try todo.append(e.gpa(), ks[n + 1]);
                },
                .ref => if (f.roots.items[x.root].kind == .param) {
                    e.marks.entry = !@import("Mutate.zig").on(.entry_mark_off);
                },
                else => {},
            }
        }
    }
}

/// Why a function can't go to an entry: true, a need; false, `taken_write`.
fn markOf(e: *Eval.Evaluation, head: u32) ?bool {
    const c = if (head & Walk.fixed_bit != 0) head & ~Walk.fixed_bit else e.ctx.contractOf(e.ctx.ctx, head) orelse return null;
    for (e.contracts.labelsOf(e.contracts.head(c).labels)) |l| if (l.need.len != 0) return true;
    return if (e.contracts.head(c).flags.taken_write) false else null;
}

fn refuse(e: *Eval.Evaluation, q: u32, v: u32, need: bool) Error!void {
    const f = e.fr();
    const call = f.calls.items[q];
    const start: u32 = @intCast(e.w.leaf_runs.items.len);
    try e.ev.storageOf(v, 0, &e.w.leaf_runs);
    try Eval.addDemand(e, .{ .point = call.point, .kind = .writer, .token = e.w.bir.insts.items(.main_token)[call.inst], .base_inst = if (call.arg_insts.len != 0) call.arg_insts[0] else call.inst, .callee_inst = call.head, .targets = .{ .start = start, .len = @intCast(e.w.leaf_runs.items.len - start) }, .kept = true, .need = need });
}
