//! L9: what a cell callback's write-back makes escape
//! (`docs/design/ownership-v2.md` §2.13.7, *what the callback answers is
//! stored back*; #1729, #1955). Where the answer may share what the cell
//! holds with something else (`Cells.shared`: a capture, a top-level value,
//! an unknown answer), two things escape at the call: that part of the
//! contents, which the cell's later loans and edits name, and the answer's
//! objects there, which the caller still names (a capture stored is the
//! cell's now, as `Ref.set`'s payload is). `Eval` adds the escapes.
//!
//! Obligations kept here: none of §2.14's directly (`Eval` records the
//! escapes; `Resolve` refuses an edit of an escaped object).

const std = @import("std");
const Place = @import("Place.zig");
const Contract = @import("Contract.zig");
const Relation = @import("Relation.zig");
const Cells = @import("Cells.zig");
const LabelChain = @import("LabelChain.zig");

const Error = Relation.Error;

/// The leaves that escape at call `q`, whose cell callback label supplied
/// `cs` is applied by virtual call `vi`, appended to `out`. `modify`: only `.1` is stored.
/// `unknown`: the code's contract is not final (pessimistic, or a member
/// of the group being solved), so every slot of its answer may share.
pub fn leaves(c: LabelChain.Chain, ev: *Relation.Eval, q: u32, modify: bool, cs: Contract.Arrival, vi: u32, unknown: bool, out: *std.ArrayList(u32)) Error!void {
    if (@import("Mutate.zig").on(.stored_off)) return;
    const f = c.f;
    const vc = f.calls.items[vi];
    const answer = try f.refRoot(vc.root);
    if (unknown) {
        try project(ev, answer, if (modify) &.{(try Place.Step.index(f.account, 1)).word()} else &.{}, out);
        return taint(ev, q, cs, &.{}, false, out);
    }
    var sh: std.ArrayList(Cells.Shared) = .empty;
    defer sh.deinit(f.gpa);
    try Cells.shared(try LabelChain.entriesOf(c, c.contracts.head(vc.contract).res_root), modify, &sh, f.gpa);
    for (sh.items) |x| {
        try project(ev, answer, x.words, out);
        try taint(ev, q, cs, x.words, x.drop, out);
    }
}

/// What call `q`'s cell holds at `bw` under its `◆` (less its first step
/// when `drop`): it may be held elsewhere now.
pub fn taint(ev: *Relation.Eval, q: u32, cs: Contract.Arrival, bw: []const u32, drop: bool, out: *std.ArrayList(u32)) Error!void {
    const f = ev.f;
    const call = f.calls.items[q];
    if (cs.j >= call.args.len) return;
    const words = try std.mem.concat(ev.arena, u32, &.{ f.slots.relWords(cs.slot), bw[@min(@intFromBool(drop), bw.len)..] });
    try project(ev, call.args[cs.j], words, out);
}

fn project(ev: *Relation.Eval, v: u32, words: []const u32, out: *std.ArrayList(u32)) Error!void {
    var ps: std.ArrayList(Relation.Proj) = .empty;
    defer ps.deinit(ev.f.gpa);
    try ev.project(v, words, true, 0, 0, &ps);
    for (ps.items) |p| try out.append(ev.f.gpa, p.leaf);
}
