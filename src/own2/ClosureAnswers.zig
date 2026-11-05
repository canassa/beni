//! L11: what a closure answers leaves with it (`docs/design/ownership-v2.md`
//! §2.11.3, *a function value goes where a value goes*). A closure that escapes
//! is run by code nobody sees, which takes its answer: a capture it answers, or
//! one it hands a label that may answer it back, has escaped too (#2059).
//!
//! Obligations kept here: O1's half for a closure's answer.

const std = @import("std");
const Ids = @import("Ids.zig");
const Contract = @import("Contract.zig");
const LabelChain = @import("LabelChain.zig");
const Slots = @import("Slots.zig");
const Value = @import("Value.zig");
const Place = @import("Place.zig");
const Eval = @import("Eval.zig");
const Relation = @import("Relation.zig");

/// One closure's code: its contract and captures, where a run of it stands.
/// `fns`: the answer's type can hold a function.
const Run = struct { e: *Eval.Evaluation, c: Contract.Id, own: u32, caps: []const u32, at: u32, fns: bool };

/// What a closure's code let go has escaped, data too, once it runs unseen.
pub fn gone(e: *Eval.Evaluation, v: u32, slot: u32, deep: bool, at: u32) Eval.Error!void {
    var ps: std.ArrayList(Relation.Proj) = .empty;
    defer ps.deinit(e.gpa());
    try e.ev.project(v, e.fr().slots.relWords(slot), deep, 0, 0, &ps);
    for (ps.items) |p| try Eval.addEscape(e, p.leaf, at);
}

/// What captured function `v` holds, which its answer may hand on. The function
/// itself runs at its label, seen, and leaves only in an answer that can hold it.
fn holdings(r: Run, v: u32, slot: u32) Eval.Error!void {
    var ps: std.ArrayList(Relation.Proj) = .empty;
    defer ps.deinit(r.e.gpa());
    try r.e.ev.project(v, r.e.fr().slots.relWords(slot), true, 0, 0, &ps);
    for (ps.items) |p| if (r.fns or r.e.fr().leafAt(p.leaf).kind != .site) try Eval.addEscape(r.e, p.leaf, r.at);
}

/// The arrivals of tree `root`: a capture lets go of its slot, and a label's
/// answer of the function it runs, deep, and of what it is supplied, each label once.
fn tree(r: Run, root: Contract.Node, seen: []bool) Eval.Error!void {
    const labels = r.e.contracts.labelsOf(r.e.contracts.head(r.c).labels);
    for ((try Eval.entriesOf(r.e, root)).items.items) |rs| for (rs.arrivals) |a| switch (a.kind) {
        .param => if (a.j >= r.own and a.j - r.own < r.caps.len) try gone(r.e, r.caps[a.j - r.own], a.slot, a.deep or rs.open, r.at),
        .cb => if (!seen[a.j]) {
            seen[a.j] = true;
            const lab = labels[a.j];
            if (lab.j >= r.own and lab.j - r.own < r.caps.len) try holdings(r, r.caps[lab.j - r.own], lab.slot);
            for (r.e.contracts.suppliesOf(lab.supplies)) |su| try tree(r, su.res_root, seen);
        },
        else => {},
    };
}

/// Closure `atom` of the frame, run at `point` (`none`: where it stands) by code
/// unseen: its answer goes there.
pub fn of(e: *Eval.Evaluation, atom: u32, point: u32) Eval.Error!void {
    for (e.w.closures.items) |cl| {
        if (cl.inst != atom) continue;
        const c = e.ctx.contractOf(e.ctx.ctx, cl.code) orelse continue;
        const h = e.contracts.head(c);
        const sig = try e.ctx.codeSig(e.ctx.ctx, cl.code);
        const seen = try e.ev.arena.alloc(bool, e.contracts.labelsOf(h.labels).len);
        @memset(seen, false);
        const holds: Place.Holds = if (sig.result == .none) .{ .any = true } else e.fr().places.holds(sig.result);
        const r: Run = .{ .e = e, .c = c, .own = sig.own, .caps = e.fr().kidsOf(e.fr().val(cl.value)), .at = if (point == Ids.none_int) cl.point else point, .fns = holds.closure or holds.any };
        try tree(r, h.res_root, seen);
    }
}

/// What code `c` hands a function it is given leaves too: nobody saw that function.
pub fn supplied(e: *Eval.Evaluation, c: Contract.Id, own: u32, caps: []const u32, at: u32) Eval.Error!void {
    const labels = e.contracts.labelsOf(e.contracts.head(c).labels);
    const seen = try e.ev.arena.alloc(bool, labels.len);
    @memset(seen, false);
    const r: Run = .{ .e = e, .c = c, .own = own, .caps = caps, .at = at, .fns = true };
    for (labels) |lab| if (lab.j < own) for (e.contracts.suppliesOf(lab.supplies)) |su| try tree(r, su.res_root, seen);
}

/// What a known code answers a label that lets its answer go has escaped.
pub fn labelled(e: *Eval.Evaluation) Eval.Error!void {
    const f = e.fr();
    for (f.calls.items, 0..) |c, q| if (c.virtual) if (LabelChain.virtualOuter(e.chain(), @intCast(q))) |o| {
        const outer = f.calls.items[o[0]];
        if (outer.contract == Value.none or !e.contracts.labelsOf(e.contracts.head(outer.contract).labels)[o[1]].answer_left) continue;
        try gone(e, try f.refRoot(c.root), Slots.root, true, c.point);
    };
}

/// Whether code `c`'s answer names a capture, directly or through a label.
pub fn namesCapture(e: *Eval.Evaluation, c: Contract.Id, own: u32) Eval.Error!bool {
    const h = e.contracts.head(c);
    for ((try Eval.entriesOf(e, h.res_root)).items.items) |rs| for (rs.arrivals) |a| switch (a.kind) {
        .param => if (a.j >= own) return true,
        .cb => return true,
        else => {},
    };
    return false;
}
