//! L9: what a pending argument holds for its consumer
//! (`docs/design/ownership-v2.md` §2.8, *A pending argument*; R-4.8.5). An
//! operand waits on the stack until its consumer runs, and a write between
//! the two must not reach what it holds. Where the consumer is a call of a
//! code whose contract is settled, the consumer reads of its argument only
//! what the contract's footprint says: its reads, its writes and its
//! escapes. So the argument holds no more, and `changed model (List.map
//! model.todos …)` may edit the todos in place when `changed` reads none of
//! them. The record pass only: no list verdict reads it (R-8.6).
//!
//! Obligations kept here: O2's pending half for an argument (every object
//! that the consumer reads, writes or keeps of it is held).

const std = @import("std");
const Ids = @import("Ids.zig");
const Contract = @import("Contract.zig");
const Forest = @import("Forest.zig");
const Relation = @import("Relation.zig");

const Error = Relation.Error;
const none: u32 = Ids.none_int;

/// The leaves of value `v`, pending as an argument of walked call `q` (its instruction `inst` there), that
/// the callee's footprint reaches, into `out`. False, and nothing in `out`: the argument is held whole (a
/// consumer whose contract is not settled or is pessimistic, a virtual call, an operand that is no argument).
pub fn leaves(ev: *Relation.Eval, q: u32, inst: u32, v: u32, out: *std.ArrayList(u32)) Error!bool {
    if (@import("Mutate.zig").on(.pending_arg_whole)) return false;
    const f = ev.f;
    const g = ev.gpa();
    const cl = f.calls.items[q];
    const j: u32 = @intCast(std.mem.indexOfScalar(u32, cl.arg_insts, inst) orelse return false);
    const c = ev.contractOf(q) orelse return false;
    const h = ev.contracts.head(c);
    if (cl.virtual or h.flags.pessimistic) return false;
    // A member of the group being solved: its footprint still grows.
    if (cl.code != none) if (ev.live) |lv| if (lv.draftRes(lv.ctx, cl.code) != null) return false;
    var ps: std.ArrayList(Relation.Proj) = .empty;
    defer ps.deinit(g);
    var es: Forest.Entries = .{};
    defer es.deinit(g);
    for ([_][]const [2]u32{ ev.contracts.readsOf(h.reads), ev.contracts.writesOf(h.writes) }) |roots| for (roots) |r| {
        if (r[0] != j) continue;
        try es.of(&ev.contracts.trees, g, ev.places(), r[1], &.{});
        for (es.items.items) |e| try at(ev, v, es.wordsOf(e), e.open, &ps, out);
    };
    for (ev.contracts.effectsOf(h.escapes)) |x| if (x.j == j) try at(ev, v, f.slots.relWords(x.slot), true, &ps, out);
    for (ps.items) |p| try out.append(g, p.leaf);
    return true;
}

/// What an effect at `words` of the argument reaches: its own storage, or everything at and below it.
fn at(ev: *Relation.Eval, v: u32, words: []const u32, deep: bool, ps: *std.ArrayList(Relation.Proj), out: *std.ArrayList(u32)) Error!void {
    try ev.f.charge(.inspection, 1);
    if (words.len == 0 and !deep) return ev.storageOf(v, 0, out);
    try ev.project(v, words, deep, 0, 0, ps);
}
