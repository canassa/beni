//! L11: a traversal's supply (`docs/design/ownership-v2.md` §2.11.3, *a
//! traversal's supply*): which supplies of a frame's labels hand one element
//! of one family per run, each position at most once. It is derived from the
//! walk, never from a name: a direct call handed a taken element or a
//! pattern's front, a pass of a callee's traversal over the same family, and
//! never two sources that can name one position.
//!
//! Obligations kept here: O14's label half for `each`: it holds of every
//! run of the label, at each call that applies it, outward.

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Forest = @import("Forest.zig");
const Contract = @import("Contract.zig");
const Value = @import("Value.zig");
const Taken = @import("Taken.zig");
const LabelChain = @import("LabelChain.zig");
const Each = @import("Each.zig");
const Eval = @import("Eval.zig");

const Allocator = std.mem.Allocator;
const Error = Eval.Error;
const none: u32 = Ids.none_int;

/// The value a source hands elements of, and how.
const Source = struct {
    /// A value of the frame: the container of a taken element, the list a
    /// pass walks; the `front` position's parent for a pattern's front.
    root: u32,
    pos: u32,
    /// `front`: the pattern's index; `slice`: the first index a pass walks.
    /// `taken` compares containers only (the index obligation, §2.13.6).
    kind: enum { taken, front, whole, slice },
    at: u32 = 0,
    /// The element comes out of a `taken` row, all the way down.
    walk: bool = false,
};

/// What a direct call's argument `a` hands, if an element of a family.
fn directSource(e: *Eval.Evaluation, a: u32) ?Source {
    const f = e.fr();
    const c = Taken.containerOf(f, e.contracts, a);
    if (c != none) {
        const v = f.val(c);
        return if (v.kind == .ref and v.family == Slots.empty) .{ .root = v.root, .pos = v.pos, .kind = .taken, .walk = true } else null;
    }
    const v = f.val(a);
    if (v.kind != .ref or v.family != Slots.empty) return null;
    const p = f.pos.items[v.pos];
    if (p.kind != .front or p.parent == none) return null;
    return .{ .root = v.root, .pos = p.parent, .kind = .front, .at = p.a };
}

/// What value `v` walks when a callee's traversal is passed it: its own
/// elements from an index on. A call's result is no walk of what it was
/// handed, but for a call that answers its parameter whole (`base`).
fn walkSource(e: *Eval.Evaluation, v0: u32, walk: bool) Error!?Source {
    const f = e.fr();
    var w = v0;
    while (true) {
        const x = f.val(w);
        if (x.kind != .ref or x.family != Slots.empty) return null;
        const r = f.roots.items[x.root];
        if (r.kind == .param) break;
        if (r.kind != .call or x.pos != r.pos) return null;
        const cl = f.calls.items[r.a];
        if (cl.contract == none) return null;
        const j = (try Each.answersWhole(e.chain(), cl.contract)) orelse return null;
        if (j >= cl.args.len) return null;
        w = cl.args[j];
    }
    const v = f.val(w);
    const p = f.pos.items[v.pos];
    if (p.kind == .slice and p.parent != none and p.b == 0) return .{ .root = v.root, .pos = p.parent, .kind = .slice, .at = p.a };
    return .{ .root = v.root, .pos = v.pos, .kind = .whole, .walk = walk };
}

/// Whether a direct source and a pass name no position in common: a taken
/// element and a walk of its container are one traversal, by the index
/// obligation; a pattern's front and a slice after it are apart.
fn apartSources(d: Source, p: Source) bool {
    if (d.root != p.root or d.pos != p.pos) return false;
    return switch (d.kind) {
        .taken => p.kind == .whole,
        .front => p.kind == .slice and d.at < p.at,
        else => false,
    };
}

/// The supply `k` of a label.
fn supplyOf(c: LabelChain.Chain, lab: Contract.Label, k: u32) ?Contract.Supply {
    for (c.contracts.suppliesOf(lab.supplies)) |su| if (su.k == k) return su;
    return null;
}

/// Whether virtual call `q`'s own argument `j` is handed once per position
/// of a family, or once: outward, by each label its code is run by.
fn runsEach(c: LabelChain.Chain, q: u32, j: u32) Error!bool {
    const f = c.f;
    var cur = q;
    var k = j;
    while (f.calls.items[cur].virtual) {
        const o = LabelChain.virtualOuter(c, cur) orelse return false;
        const lab = LabelChain.labelAt(c, o);
        const su = supplyOf(c, lab, k) orelse return false;
        if (c.contracts.effectsOf(su.kept).len != 0) return false;
        if (!su.each and lab.calls != .once) return false;
        const oc = f.calls.items[o[0]];
        if (!oc.virtual) return true;
        const fam = (try Each.familyOf(c, su)) orelse return false;
        if (fam.j + f.kidsOf(f.val(oc.callee_val)).len >= oc.args.len) return false;
        k = fam.j;
        cur = o[0];
    }
    return true;
}

/// Whether the pass `p` of a frame's label hands supply `k` a traversal's
/// element: its source, when one of the frame's values is walked.
fn passSource(e: *Eval.Evaluation, p: [3]u32, su: Contract.Supply) Error!?Source {
    const f = e.fr();
    const c = e.chain();
    const call = f.calls.items[p[1]];
    if (c.contracts.effectsOf(su.kept).len != 0) return null;
    if (!su.each) return null;
    const fam = (try Each.familyOf(c, su)) orelse return null;
    if (fam.j >= call.args.len) return null;
    const v = try e.ev.valueAt(call.args[fam.j], fam.words[0 .. fam.words.len - 1]);
    if (call.virtual) {
        const own = call.args.len - f.kidsOf(f.val(call.callee_val)).len;
        if (if (fam.j >= own) LabelChain.outwardMany(c, p[1]) else !try runsEach(c, p[1], fam.j)) return null;
    }
    return walkSource(e, v, su.walk and !call.virtual);
}

/// Whether the pass `p` is a known code handing its own element whole,
/// once a run, the code run by a traversal's label.
fn handsOn(e: *Eval.Evaluation, p: [3]u32, lab: Contract.Label, su: Contract.Supply) Error!bool {
    const f = e.fr();
    const c = e.chain();
    const call = f.calls.items[p[1]];
    if (!call.virtual or lab.calls != .once or c.contracts.effectsOf(su.kept).len != 0) return false;
    const own = call.args.len - f.kidsOf(f.val(call.callee_val)).len;
    const es = try LabelChain.entriesOf(c, su.res_root);
    var hit: ?u32 = null;
    for (es.items.items) |rs| for (rs.arrivals) |a| {
        if (a.kind != .param or a.j >= own) return false;
        if (hit) |h| {
            if (h != a.j) return false;
        } else hit = a.j;
        if (es.wordsOf(rs).len == 0 and f.slots.relWords(a.slot).len != 0) return false;
    };
    const j = hit orelse return false;
    if (!try runsEach(c, p[1], j)) return false;
    const o = LabelChain.virtualOuter(c, p[1]) orelse return false;
    const ou = supplyOf(c, LabelChain.labelAt(c, o), j) orelse return false;
    return ou.each;
}

/// Mark each supply of the draft's labels that is a traversal's.
pub fn publish(e: *Eval.Evaluation, s: anytype, arena: Allocator, labelIndex: anytype) Error!void {
    const f = e.fr();
    const d = s.d;
    const c = e.chain();
    for (d.labels.items, 0..) |*g, gi| for (g.supplies.items) |*sup| {
        sup.each = false;
        sup.walk = false;
        if (sup.kept.items.len != 0) continue;
        if (!try oneFamily(e, arena, sup)) continue;
        var direct: ?Source = null;
        var pass: ?Source = null;
        var directs: u32 = 0;
        var any = false;
        var ok = true;
        var walk = true;
        for (f.cbs.items[e.w.last.cbs..], e.w.last.cbs..) |cb, ci| {
            if (cb.inst == none or try labelIndex(s, @intCast(ci)) != gi) continue;
            directs += 1;
            if (sup.k >= cb.args.len) continue;
            direct = directSource(e, cb.args[sup.k]);
            if (direct == null) ok = false else walk = walk and direct.?.walk;
        }
        for (e.passes.items) |p| {
            if (try labelIndex(s, p[0]) != gi) continue;
            const call = f.calls.items[p[1]];
            const lab = c.contracts.labelsOf(c.contracts.head(call.contract).labels)[p[2]];
            const su = supplyOf(c, lab, sup.k) orelse continue;
            any = true;
            if (try handsOn(e, p, lab, su)) {
                walk = false;
                continue;
            }
            // Two passes over one value are alternatives: the first would
            // be kept by the second's argument.
            const src = try passSource(e, p, su);
            if (src == null or (pass != null and !std.meta.eql(src.?, pass.?))) ok = false;
            pass = src;
            if (src) |x| walk = walk and x.walk;
        }
        if (!ok or directs > 1 or (directs == 0 and !any)) continue;
        if (direct != null and pass != null and !apartSources(direct.?, pass.?)) continue;
        sup.each = true;
        sup.walk = walk;
    };
}

/// Whether nothing but one parameter's family arrives at the draft's supply.
fn oneFamily(e: *Eval.Evaluation, arena: Allocator, sup: *Contract.Draft.DraftSupply) Error!bool {
    const f = e.fr();
    var arrs: std.ArrayList(Contract.Arrival) = .empty;
    for (sup.res.items.items) |rs| {
        if (rs.node == 0) try arrs.append(arena, rs.a) else try Forest.arrivalsOf(&e.contracts.trees, arena, f.places, rs.node, &arrs);
    }
    if (arrs.items.len == 0) return false;
    const elem = Place.Step.elem.word();
    for (arrs.items) |a| {
        if (a.kind != .param or a.j != arrs.items[0].j) return false;
        if (std.mem.indexOfScalar(u32, f.slots.relWords(a.slot), elem) == null) return false;
    }
    return true;
}
