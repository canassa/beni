//! L11: where the read-off puts what it describes, split from `ReadOff`
//! (`docs/design/ownership-v2.md` §2.10 *Read-off*): the draft's result and
//! supply lists, and an arrival at a slot (plain or by structure); the stack
//! of subtrees described once per place is `Building`, their memo `PutMemo`.
//!
//! Obligations kept here: none of §2.14's directly (each arrival is put
//! where the read-off says, and a new fact of a member is delivered).

const std = @import("std");
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const SupplyKey = @import("SupplyKey.zig");
const Contract = @import("Contract.zig");
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

/// An arrival at `q` by structure, the levels above it and its `levelNames`, whatever is described.
pub fn wideLevels(s: *Sink, q: PathId, a: Contract.Arrival, out: ResList) Error!void {
    if (!try wideOne(s, q, a, out)) return;
    if (a.kind == .fresh) return;
    for (try levelNames(s, q)) |p| _ = try wideOne(s, .from(p), try LevelWide.renamed(s.e.fr(), s.e.gpa(), a, q, .from(p)), out);
}

/// Arrival `a`, wide at `q`, and at the levels above it (`LevelWide.of`); false when `q` had it.
fn wideOne(s: *Sink, q: PathId, a: Contract.Arrival, out: ResList) Error!bool {
    if (!try addAt(s, try SupplyKey.relAt(s, q, out.key), a, true, true, out)) return false;
    var said: std.ArrayList(LevelWide.Said) = .empty;
    try LevelWide.of(s.e.fr(), s.e.gpa(), s.arena, q, a, &said);
    for (said.items) |x| _ = try addAt(s, try SupplyKey.relAt(s, x.at, out.key), x.a, true, true, out);
    return true;
}

/// The level paths `q` stands for when a `⟲` on it is a join (§2.1, *one position, one name*):
/// what is said at the join is said at each. A caller leaves out `fresh`: no entry reads fresh.
pub fn levelNames(s: *Sink, q: PathId) Error![]const u32 {
    const f = s.e.fr();
    return f.slots.joinNames(s.e.gpa(), s.arena, f.account, f.places, q);
}

/// Arrival `a` at slot `r` of `out` (by structure when `wide`): when new, a fact of a member
/// delivered to what reads it (§2.12), `open` when the slot is.
fn addAt(s: *Sink, r: Slots.Rel, a: Contract.Arrival, wide: bool, open: bool, out: ResList) Error!bool {
    const list = try resList(s, out);
    try s.e.fr().charge(.edge, 1);
    if (!(if (wide) try Contract.Draft.addWide(list, s.arena, r, a) else try Contract.Draft.addArrival(list, s.arena, r, a))) return false;
    if (out.label == none) if (s.e.solver) |sv| try sv.resFact(sv.ctx, s.e.x, r, open, a, 0);
    return true;
}

pub fn arrive(s: *Sink, q: PathId, a: Contract.Arrival, out: ResList) Error!void {
    const f = s.e.fr();
    if (s.building.items.len != 0) {
        const res = &s.building.items[s.building.items.len - 1].res;
        const r = try relIn(s, q);
        if (f.places.kind(f.places.pathPlace(q)) == .@"var") try Contract.Draft.markOpen(res, s.arena, r);
        try f.charge(.edge, 1);
        _ = try Contract.Draft.addArrival(res, s.arena, r, a);
        return;
    }
    if (!try plainAt(s, q, a, out)) return;
    if (a.kind == .fresh) return;
    for (try levelNames(s, q)) |p| _ = try plainAt(s, .from(p), a, out);
}

fn plainAt(s: *Sink, q: PathId, a: Contract.Arrival, out: ResList) Error!bool {
    const f = s.e.fr();
    const open = f.places.kind(f.places.pathPlace(q)) == .@"var";
    const r = try SupplyKey.relAt(s, q, out.key);
    if (open) try Contract.Draft.markOpen(try resList(s, out), s.arena, r);
    return addAt(s, r, a, false, open, out);
}

/// A late `host` at told slot `q` (the root by structure when `built`), and at its `levelNames`.
pub fn host(s: *Sink, q: PathId, built: bool, out: ResList) Error!void {
    if (built) _ = try addAt(s, Slots.root, .{ .kind = .host }, true, true, out);
    if (built) return;
    _ = try addAt(s, try SupplyKey.relAt(s, q, out.key), .{ .kind = .host }, false, false, out);
    for (try levelNames(s, q)) |p| _ = try addAt(s, try SupplyKey.relAt(s, .from(p), out.key), .{ .kind = .host }, false, false, out);
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
    if (!try nodeAt(s, q, n, out)) return;
    for (try levelNames(s, q)) |p| _ = try nodeAt(s, .from(p), n, out);
}

fn nodeAt(s: *Sink, q: PathId, n: Contract.Node, out: ResList) Error!bool {
    const r = try SupplyKey.relAt(s, q, out.key);
    if (!try Contract.Draft.addNode(try resList(s, out), s.arena, r, n)) return false;
    if (out.label == none) if (s.e.solver) |sv| try sv.resFact(sv.ctx, s.e.x, r, false, .{ .kind = .top }, n);
    return true;
}
