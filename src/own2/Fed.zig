//! L8: a label's answer handed back to it (`docs/design/ownership-v2.md`
//! §2.11.3, *a label's answer handed back to it*): at a call that passes
//! the frame's label on, the answer of the frame's own call of that
//! function, handed back as the label's argument `k` (a fold's
//! accumulator), is read as what that call was handed as `k`, under a
//! `fed` occurrence. `FedCall` reads that occurrence at a caller.
//! The label's answer held by a builder handed on is read here too: covered
//! by the elements it was taken from (§2.11.3, *a taken supply*).
//!
//! Obligations kept here: none of §2.14's directly (`Distinct.instSelFeed`
//! asks the distinct check of the entries; `Resolve` judges the part).

const std = @import("std");
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const Contract = @import("Contract.zig");
const Relation = @import("Relation.zig");
const Place = @import("Place.zig");
const Value = @import("Value.zig");
const Taken = @import("Taken.zig");

const Error = Relation.Error;
const Eval = Relation.Eval;
const Proj = Relation.Proj;
const none: u32 = Ids.none_int;

/// A call that passes the frame's label at function slot `π_j·slot` on as
/// the callee's label `label`; `covered`: what `covering` found.
pub const Feed = struct { j: u32, slot: Slots.Rel, label: u32, covered: u32 = none };

/// The argument of call `cl` whose elements condition `c` selects plain
/// and deep (`π{[*]*}`), else `none`: an answer of the label to an element
/// taken out of it holds that element (among them) or what the function
/// holds (`replace` asks it apart), §2.11.3 *a taken supply*.
pub fn covering(e: *Eval, c: Contract.Cond, cl: Value.Call) u32 {
    for (c.sel) |o| {
        if (Contract.isApart(o) or !Contract.isDeep(o) or Contract.isFed(o) or Contract.occParam(o) >= cl.args.len) continue;
        const ws = e.f.slots.relWords(Contract.occRel(o));
        if (ws.len == 1 and ws[0] == Place.Step.elem.word()) return cl.args[Contract.occParam(o)];
    }
    return none;
}

/// The direct label call (`cbs`) whose answer leaf `li` is, when its
/// function is the frame's slot `fd`.
pub fn answerOf(e: *Eval, li: u32, fd: Feed) ?u32 {
    const l = e.f.leafAt(li);
    if (l.kind != .ref) return null;
    const r = e.f.roots.items[l.root];
    if (r.kind != .cb) return null;
    const cb = e.f.cbs.items[r.a];
    if (cb.inst == none or cb.j != fd.j or cb.slot != fd.slot) return null;
    return r.a;
}

/// Projected entry `p` of occurrence `o` read through `feed`: when it is
/// the answer of the frame's call of that function, handed back as
/// argument `k`, what that call was handed as `k`, deep (appended to `ps`),
/// and the `fed` occurrence it asks (appended to `fed`). False: `p` itself.
pub fn replace(e: *Eval, p: Proj, o: u64, k: ?u32, feed: Feed, ps: *std.ArrayList(Proj), fed: *std.ArrayList(u64)) Error!bool {
    const ci = answerOf(e, p.leaf, feed) orelse return try through(e, p, o, feed, ps, fed);
    // Held anywhere else (a builder's element): covered, or itself.
    const kk = k orelse return try coveredAsks(e, ci, feed, fed);
    if (kk >= e.f.cbs.items[ci].args.len) return false;
    var sub: std.ArrayList(Proj) = .empty;
    defer sub.deinit(e.gpa());
    try e.project(e.f.cbs.items[ci].args[kk], &.{}, true, 0, p.route, &sub);
    for (sub.items) |q| try ps.append(e.gpa(), .{ .leaf = q.leaf, .route = q.route, .occ = o, .routes = p.routes });
    try fed.append(e.arena, Contract.occFed(feed.j, feed.slot, kk));
    return true;
}

/// Whether the answer of direct label call `ci` is covered (`covering`):
/// the one argument of the call that holds objects is an element taken out
/// of `feed.covered`. It is read as a part of those elements, and what the
/// function holds as apart from every plain object (`π_j·slot*~`, in `fed`).
fn coveredAsks(e: *Eval, ci: u32, feed: Feed, fed: *std.ArrayList(u64)) Error!bool {
    if (!covered(e, ci, feed)) return false;
    try fed.append(e.arena, Contract.occDeep(Contract.occApart(feed.j, feed.slot)));
    return true;
}

fn covered(e: *Eval, ci: u32, feed: Feed) bool {
    if (feed.covered == none) return false;
    if (@import("Mutate.zig").on(.fed_covered_true)) return true;
    var got: ?u32 = null;
    for (e.f.cbs.items[ci].args) |a| if (e.f.val(a).kind != .scalar) {
        if (got != null) return false;
        got = a;
    };
    return Taken.containerOf(e.f, e.contracts, got orelse return false) == feed.covered;
}

/// A call's answer that holds a covered answer (`put b i (f x)`, a builder
/// handed on): read as what the call answers, one level, the covered
/// answer dropped and every other part itself. False: it holds none.
fn through(e: *Eval, p: Proj, o: u64, feed: Feed, ps: *std.ArrayList(Proj), fed: *std.ArrayList(u64)) Error!bool {
    if (feed.covered == none) return false;
    const l = e.f.leafAt(p.leaf);
    if (l.kind != .ref or e.f.roots.items[l.root].kind != .call) return false;
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(e.gpa());
    try e.expand(p.leaf, &ls);
    for (ls.items) |x| {
        if (if (answerOf(e, x, feed)) |ci| covered(e, ci, feed) else false) break;
    } else return false;
    for (ls.items) |x| {
        if (answerOf(e, x, feed)) |ci| if (try coveredAsks(e, ci, feed, fed)) continue;
        try ps.append(e.gpa(), .{ .leaf = x, .route = p.route, .occ = o, .routes = p.routes });
    }
    return true;
}

/// The leaves a pass judges for part `li` of the label's argument `k` (in
/// `e.arena`): the label's own answer handed back is judged as what its
/// call was handed as `k`, deep, so one held after the call keeps the slot
/// as the answer would; any other part is itself.
pub fn judgedOf(e: *Eval, li: u32, fd: Feed, k: u32) Error![]const u32 {
    var ss: std.ArrayList(Proj) = .empty;
    defer ss.deinit(e.gpa());
    if (answerOf(e, li, fd)) |ci| if (k < e.f.cbs.items[ci].args.len) try e.project(e.f.cbs.items[ci].args[k], &.{}, true, 0, 0, &ss);
    if (ss.items.len == 0) try ss.append(e.gpa(), .{ .leaf = li });
    const out = try e.arena.alloc(u32, ss.items.len);
    for (ss.items, out) |q, *x| x.* = q.leaf;
    return out;
}
