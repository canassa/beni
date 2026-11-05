//! L13: a contract's called contracts in a block (`docs/design/ownership-v2.md`
//! §2.11.3, *a function value in a result*; §3.6, version 23): after a
//! contract, its function slots in the canonical order, each with its called
//! contract. `w` and `r` are `Block`'s writer and reader.
//!
//! Obligations kept here: O10 (read back by `Block`'s re-encoding).

const std = @import("std");
const Contract = @import("Contract.zig");
const Slots = @import("Slots.zig");

fn lessRel(slots: *const Slots.Table, a: [2]u32, b: [2]u32) bool {
    return slots.relOrder(a[0], b[0]) == .lt;
}

pub fn write(w: anytype, c: Contract.Id) std.mem.Allocator.Error!void {
    const run = try w.gpa.dupe([2]u32, w.t.calledRun(c));
    defer w.gpa.free(run);
    std.mem.sort([2]u32, run, w.slots, lessRel);
    try w.word(@intCast(run.len));
    for (run) |x| {
        try w.rel(x[0]);
        try w.contract(x[1]);
    }
}

pub fn read(r: anytype, t: *Contract.Table, c: Contract.Id) !Contract.Id {
    for (0..try r.count()) |_| {
        const rel = try r.rel();
        try t.putCalled(r.gpa, c, rel, try r.contract(t));
    }
    return c;
}
