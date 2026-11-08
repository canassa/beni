//! L11: where the read-off puts what it describes, split from `ReadOff`
//! (`docs/design/ownership-v2.md` §2.10 *Read-off*): the draft's result and
//! supply lists, an arrival at a slot (plain or by structure), and the
//! stack of subtrees described once per place (their memo is `PutMemo`).
//!
//! Obligations kept here: none of §2.14's directly (each arrival is put
//! where the read-off says, and a new fact of a member is delivered).

const std = @import("std");
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const SupplyKey = @import("SupplyKey.zig");
const Contract = @import("Contract.zig");
const Relation = @import("Relation.zig");
const Eval = @import("Eval.zig");
const FnRun = @import("FnRun.zig");
const LevelWide = @import("LevelWide.zig");

const Error = Eval.Error;
const PathId = Ids.PathId;
const Sink = Eval.Sink;
const none = std.math.maxInt(u32);

/// Where the read-off puts arrivals: the result's, or label `label`'s
/// supply `k` (an index into the draft's labels, never a pointer: the
/// lists grow while the facts are delivered).
/// The frame's result (`label` none) or a label's supply `k`, written below `key` (`SupplyKey`).
pub const ResList = struct { label: u32 = none, k: u32 = 0, key: Slots.Rel = SupplyKey.none };
/// Where a parameter effect goes.
pub const EffList = enum(u8) { reads, writes, escapes };

/// A closure of the frame said into a label's supply (which names objects,
/// never a code) is handed to unseen code: it escapes (§2.11.3, #1776).
pub fn handed(s: *Sink, li: u32, out: ResList) Error!void {
    const e, const l = .{ s.e, s.e.fr().leafAt(li) };
    if (out.label == none or l.kind != .site or !FnRun.frameSite(e.contracts, e.ctx, e.w.closures.items, l.atom)) return;
    try e.fn_escapes.append(e.gpa(), .{ .leaf = li, .point = none });
}

/// A failed read of `key`: remembered unless `above`, and no node.
pub fn fail(s: *Sink, key: [6]u32, above: bool) Error!?Contract.Node {
    if (!above) try s.nodes.put(s.e.gpa(), key, none - 1);
    return null;
}

pub fn resList(s: *Sink, l: ResList) Error!*Contract.Draft.Res {
    if (l.label == none) return &s.d.res;
    return &(try s.d.labels.items[l.label].supplyOf(s.arena, l.k)).res;
}

pub fn effList(s: *Sink, l: EffList) *std.ArrayList(Contract.Effect) {
    return switch (l) {
        .reads => &s.d.reads,
        .writes => &s.d.writes,
        .escapes => &s.d.escapes,
    };
}

/// An arrival at `q` and, by structure, at every slot below it.
pub fn arriveWide(s: *Sink, q: PathId, a: Contract.Arrival, out: ResList) Error!void {
    if (s.building.items.len != 0) {
        try s.e.fr().charge(.edge, 1);
        _ = try Contract.Draft.addWide(&s.building.items[s.building.items.len - 1].res, s.arena, try relIn(s, q), a);
        return;
    }
    return wideLevels(s, q, a, out);
}

/// An arrival at `q` by structure and at the levels above it, in list `out` whatever subtree is described.
pub fn wideLevels(s: *Sink, q: PathId, a: Contract.Arrival, out: ResList) Error!void {
    if (!try wideAt(s, q, a, out)) return;
    var said: std.ArrayList(LevelWide.Said) = .empty;
    try LevelWide.of(s.e.fr(), s.e.gpa(), s.arena, q, a, &said);
    for (said.items) |x| _ = try wideAt(s, x.at, x.a, out);
}

fn wideAt(s: *Sink, q: PathId, a: Contract.Arrival, out: ResList) Error!bool {
    const f = s.e.fr();
    const r = try SupplyKey.relAt(s, q, out.key);
    try f.charge(.edge, 1);
    if (!try Contract.Draft.addWide(try resList(s, out), s.arena, r, a)) return false;
    if (out.label == none) if (s.e.solver) |sv| try sv.resFact(sv.ctx, s.e.x, r, true, a, 0);
    return true;
}

pub fn arrive(s: *Sink, q: PathId, a: Contract.Arrival, out: ResList) Error!void {
    const f = s.e.fr();
    const open = f.places.kind(f.places.pathPlace(q)) == .@"var";
    if (s.building.items.len != 0) {
        const res = &s.building.items[s.building.items.len - 1].res;
        const r = try relIn(s, q);
        if (open) try Contract.Draft.markOpen(res, s.arena, r);
        try f.charge(.edge, 1);
        _ = try Contract.Draft.addArrival(res, s.arena, r, a);
        return;
    }
    const r = try SupplyKey.relAt(s, q, out.key);
    const list = try resList(s, out);
    if (open) try Contract.Draft.markOpen(list, s.arena, r);
    try f.charge(.edge, 1);
    if (try Contract.Draft.addArrival(list, s.arena, r, a)) {
        // A new fact of a member: delivered to what reads it (§2.12).
        if (out.label == none) if (s.e.solver) |sv| try sv.resFact(sv.ctx, s.e.x, r, open, a, 0);
    }
}

/// `q`'s steps below the innermost subtree's path.
pub fn relIn(s: *Sink, q: PathId) Error!Slots.Rel {
    const f = s.e.fr();
    const b = &s.building.items[s.building.items.len - 1];
    // The steps up from `q` to the subtree's path (one record a step),
    // never from the root: a slot below another is that slot's steps.
    var w: std.ArrayList(u32) = .empty;
    defer w.deinit(s.e.gpa());
    var at = q;
    while (at != b.q) : (at = f.places.pathParent(at)) {
        if (std.debug.runtime_safety) std.debug.assert(at != .none);
        try f.charge(.path, 1);
        try w.append(s.e.gpa(), f.places.pathStep(at).word());
    }
    std.mem.reverse(u32, w.items);
    return f.slots.rels.find(w.items) orelse f.slots.relOfWords(s.e.gpa(), f.account, f.places, w.items);
}

pub fn begin(s: *Sink, q: PathId) Error!void {
    s.serial += 1;
    try s.building.append(s.e.gpa(), .{ .q = q, .depth = s.serial });
}

/// What `described` keys a leaf at slot `q` of list `out` by: inside a
/// subtree being described, that subtree.s own (a subtree kept for its
/// place must hold everything said in it, whatever was said before).
pub fn describedKey(s: *Sink, x: u32, q: PathId, out: ResList) Error![5]u32 {
    if (s.building.items.len == 0) return [2]u32{ x, q.int() } ++ SupplyKey.ofList(out.label, out.k, out.key);
    return .{ x, q.int(), s.building.items[s.building.items.len - 1].depth, Relation.open_bit, SupplyKey.none };
}

/// The innermost subtree, made: its arrivals and subtrees in one node,
/// its labels the draft's.
pub fn end(s: *Sink) Error!Contract.Node {
    var b = s.building.pop().?;
    const same = try s.arena.alloc(u32, s.d.labels.items.len);
    for (same, 0..) |*x, i| x.* = @intCast(i);
    return s.e.contracts.putRes(s.e.gpa(), s.e.fr().slots, &b.res, same);
}

/// Subtree `n` below result slot `q`: into the innermost subtree being
/// described, else into the draft, a fact delivered to what reads it.
pub fn emitPart(s: *Sink, q: PathId, n: Contract.Node, out: ResList) Error!void {
    if (n == 0) return;
    const f = s.e.fr();
    // No draft keeps a node at a row's slot: a reader of a row reads arrivals (§2.1).
    if (s.building.items.len == 0 and f.places.pathParent(q) != .none and f.places.pathStep(q).isRow()) {
        const t = &s.e.contracts.trees;
        for ([_][]const Contract.Arrival{ t.here(n), t.open(n) }) |run| for (try s.e.gpa().dupe(Contract.Arrival, run)) |a| try arrive(s, q, a, out);
        return;
    }
    try f.charge(.edge, 1);
    if (s.building.items.len != 0) {
        _ = try Contract.Draft.addNode(&s.building.items[s.building.items.len - 1].res, s.arena, try relIn(s, q), n);
        return;
    }
    const r = try SupplyKey.relAt(s, q, out.key);
    if (try Contract.Draft.addNode(try resList(s, out), s.arena, r, n)) {
        if (out.label == none) if (s.e.solver) |sv| try sv.resFact(sv.ctx, s.e.x, r, false, .{ .kind = .top }, n);
    }
}
