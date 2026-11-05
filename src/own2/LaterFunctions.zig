//! L11: a function the frame runs after a supply (`docs/design/ownership-v2.md`
//! §2.11.3, *a later function*). A row's footprint says nothing of its
//! callback, so what that function holds is asked here, apart and no more.
//!
//! Obligations kept here: O14's frame half for a later function.

const std = @import("std");
const Ids = @import("Ids.zig");
const Holders = @import("Holders.zig");
const Contract = @import("Contract.zig");
const Eval = @import("Eval.zig");

const Error = Eval.Error;

/// What a supply at `point` is asked apart from: each function the frame's labels run after it holds what a
/// row's footprint does not say, so the frame reads it as nothing (#2050).
pub fn ask(e: *Eval.Evaluation, point: u32, out: *Holders.Gather) Error!void {
    const f = e.fr();
    var seen: Ids.FixedDict(2) = .{};
    defer seen.deinit(e.gpa());
    for (e.passes.items) |p| {
        const cb = f.cbs.items[p[0]];
        if (f.calls.items[p[1]].point <= point) continue;
        if ((try seen.getOrPut(e.gpa(), .{ cb.j, cb.slot })).found_existing) continue;
        const run = try e.ev.arena.alloc(u64, 1);
        run[0] = Contract.occDeep(Contract.occApart(cb.j, cb.slot));
        try out.add(e.ev.arena, f.account, try Contract.Cond.of(f.account, run));
    }
}
