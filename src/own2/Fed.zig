//! L8: a label's answer handed back to it (`docs/design/ownership-v2.md`
//! §2.11.3, *a label's answer handed back to it*): at a call that passes
//! the frame's label on, the answer of the frame's own call of that
//! function, handed back as the label's argument `k` (a fold's
//! accumulator), is read as what that call was handed as `k`, under a
//! `fed` occurrence; and that occurrence at a caller is renamed onto the
//! caller's function slot or decided by the known code applied there.
//!
//! Obligations kept here: none of §2.14's directly (`Distinct.instSelFeed`
//! asks the distinct check of the entries; `Resolve` judges the part).

const std = @import("std");
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const Forest = @import("Forest.zig");
const Contract = @import("Contract.zig");
const Relation = @import("Relation.zig");

const Error = Relation.Error;
const Eval = Relation.Eval;
const Proj = Relation.Proj;
const none: u32 = Ids.none_int;

/// A call that passes the frame's label at function slot `π_j·slot` on as
/// the callee's label `label`.
pub const Feed = struct { j: u32, slot: Slots.Rel, label: u32 };

/// The argument `k` of the callee's label `label` at `call` that the
/// callee's parameter `j` arrives at whole (a fold's accumulator), if any.
pub fn supplyOf(e: *Eval, call: u32, label: u32, j: u32) Error!?u32 {
    const c = e.contractOf(call) orelse return null;
    const labs = e.contracts.labelsOf(e.contracts.head(c).labels);
    if (label >= labs.len) return null;
    var es: Forest.Entries = .{};
    defer es.deinit(e.gpa());
    for (e.contracts.suppliesOf(labs[label].supplies)) |su| {
        try es.of(&e.contracts.trees, e.gpa(), e.places(), su.res_root, &.{});
        for (es.items.items) |rs| {
            if (es.wordsOf(rs).len != 0) continue;
            for (rs.arrivals) |a| if (a.kind == .param and a.j == j and e.f.slots.relWords(a.slot).len == 0) return su.k;
        }
    }
    return null;
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
    const kk = k orelse return false;
    const ci = answerOf(e, p.leaf, feed) orelse return false;
    if (kk >= e.f.cbs.items[ci].args.len) return false;
    var sub: std.ArrayList(Proj) = .empty;
    defer sub.deinit(e.gpa());
    try e.project(e.f.cbs.items[ci].args[kk], &.{}, true, 0, p.route, &sub);
    for (sub.items) |q| try ps.append(e.gpa(), .{ .leaf = q.leaf, .route = q.route, .occ = o, .routes = p.routes });
    try fed.append(e.arena, Contract.occFed(feed.j, feed.slot, kk));
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

pub const Got = union(enum) { yes, no, occ: u64 };

/// A callee's `fed` occurrence `o` at call `call`: the caller's own when
/// the callee's function slot is one of the caller's parameters (the
/// label passes on), `yes` when it is a known code whose answer holds only
/// its argument `k` and fresh objects, else `no`.
pub fn at(e: *Eval, call: u32, o: u64) Error!Got {
    const c = e.contractOf(call) orelse return .no;
    const j = Contract.fedParam(o);
    const k = Contract.fedArg(o);
    for (e.contracts.labelsOf(e.contracts.head(c).labels), 0..) |lab, li| {
        if (lab.j != j or lab.slot != Contract.occRel(o)) continue;
        if (e.label_map.get(.{ call, @intCast(li) })) |fc| {
            const cb = e.f.cbs.items[fc];
            return .{ .occ = Contract.occFed(cb.j, cb.slot, k) };
        }
        const vi = e.known.get(.{ call, @intCast(li) }) orelse return .no;
        const kh = e.contracts.head(e.contractOf(vi) orelse return .no);
        if (kh.flags.pessimistic) return .no;
        // Its answer at a slot that holds no object (a scalar) carries none.
        const root = e.f.roots.items[e.f.calls.items[vi].root].path;
        var es: Forest.Entries = .{};
        defer es.deinit(e.gpa());
        try es.of(&e.contracts.trees, e.gpa(), e.places(), kh.res_root, &.{});
        for (es.items.items) |rs| {
            if (!try holdsAt(e, root, es.wordsOf(rs))) continue;
            for (rs.arrivals) |a| switch (a.kind) {
                .param => if (a.j != k) {
                    const x = if (a.j < e.f.calls.items[vi].args.len) e.f.val(e.f.calls.items[vi].args[a.j]) else return .no;
                    if (x.kind != .ref or try holdsAt(e, e.f.roots.items[x.root].path, e.f.slots.relWords(a.slot))) return .no;
                },
                .fresh => {},
                else => return .no,
            };
        }
        return .yes;
    }
    return .no;
}

/// Whether the place `words` below `root` may hold an object.
fn holdsAt(e: *Eval, root: Ids.PathId, words: []const u32) Error!bool {
    var ps: std.ArrayList(u32) = .empty;
    defer ps.deinit(e.gpa());
    try Slots.replay(e.gpa(), e.account(), e.places(), root, words, &ps);
    if (ps.items.len == 0) return true;
    for (ps.items) |p| if (Slots.holdsAny(e.places(), .from(p))) return true;
    return false;
}
