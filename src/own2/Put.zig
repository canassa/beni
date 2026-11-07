//! L11: where the read-off puts what it describes, split from `ReadOff`
//! (`docs/design/ownership-v2.md` §2.10 *Read-off*): the draft's result and
//! supply lists, and an arrival at a slot (plain or by structure).
//!
//! Obligations kept here: none of §2.14's directly (each arrival is put
//! where the read-off says, and a new fact of a member is delivered).

const std = @import("std");
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const Contract = @import("Contract.zig");
const Eval = @import("Eval.zig");
const LevelWide = @import("LevelWide.zig");

const Error = Eval.Error;
const PathId = Ids.PathId;
const Sink = Eval.Sink;
const none = std.math.maxInt(u32);

/// Where the read-off puts arrivals: the result's, or label `label`'s
/// supply `k` (an index into the draft's labels, never a pointer: the
/// lists grow while the facts are delivered).
pub const ResList = struct { label: u32 = none, k: u32 = 0 };
/// Where a parameter effect goes.
pub const EffList = enum(u8) { reads, writes, escapes };

pub const labelIndex = Sink.labelIndex;

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
    const f = s.e.fr();
    if (s.building.items.len != 0) {
        try f.charge(.edge, 1);
        _ = try Contract.Draft.addWide(&s.building.items[s.building.items.len - 1].res, s.arena, try relIn(s, q), a);
        return;
    }
    if (!try wideLevels(s, q, a, out)) return;
    if (a.kind == .fresh) return;
    for (try levelNames(s, q)) |p| _ = try wideLevels(s, .from(p), a, out);
}

/// Arrival `a`, wide at `q`, and at the levels above it (`LevelWide.of`); false when `q` had it.
fn wideLevels(s: *Sink, q: PathId, a: Contract.Arrival, out: ResList) Error!bool {
    if (!try wideAt(s, q, a, out)) return false;
    var said: std.ArrayList(LevelWide.Said) = .empty;
    try LevelWide.of(s.e.fr(), s.e.gpa(), s.arena, q, a, &said);
    for (said.items) |x| _ = try wideAt(s, x.at, x.a, out);
    return true;
}

/// The level paths `q` stands for when a `⟲` on it is a join (`Place.expandLevels`, §2.1,
/// *one position, one name*): a slot's replay can reach one, and a reader walks a slot's words
/// to the names a walk gives, so what is said at the join is said at each of them too. Empty
/// otherwise. A caller leaves out a `fresh` arrival: a slot with no entry reads fresh.
pub fn levelNames(s: *Sink, q: PathId) Error![]const u32 {
    const f = s.e.fr();
    return f.slots.joinNames(s.e.gpa(), s.arena, f.account, f.places, q);
}

fn wideAt(s: *Sink, q: PathId, a: Contract.Arrival, out: ResList) Error!bool {
    const f = s.e.fr();
    const r = try f.slots.relOf(s.e.gpa(), f.account, f.places, q);
    try f.charge(.edge, 1);
    if (!try Contract.Draft.addWide(try resList(s, out), s.arena, r, a)) return false;
    if (out.label == none) if (s.e.solver) |sv| try sv.resFact(sv.ctx, s.e.x, r, true, a, 0);
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
    const r = try f.slots.relOf(s.e.gpa(), f.account, f.places, q);
    const list = try resList(s, out);
    if (open) try Contract.Draft.markOpen(list, s.arena, r);
    try f.charge(.edge, 1);
    if (!try Contract.Draft.addArrival(list, s.arena, r, a)) return false;
    // A new fact of a member: delivered to what reads it (§2.12).
    if (out.label == none) if (s.e.solver) |sv| try sv.resFact(sv.ctx, s.e.x, r, open, a, 0);
    return true;
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
    const f = s.e.fr();
    const r = try f.slots.relOf(s.e.gpa(), f.account, f.places, q);
    if (!try Contract.Draft.addNode(try resList(s, out), s.arena, r, n)) return false;
    if (out.label == none) if (s.e.solver) |sv| try sv.resFact(sv.ctx, s.e.x, r, false, .{ .kind = .top }, n);
    return true;
}
