//! L9: a call's writes of one argument projected by one walk, and a leaf
//! once per route of its set (`docs/design/ownership-v2.md` §2.11.2 *A
//! projection carries a route set*, §2.3.5 *a key's leaf*, #1714). The walk
//! itself is `RouteWalk`'s; its entry points are named here too, for the
//! readers above it.
//!
//! Obligations kept here: none of §2.14's directly (each target stands for
//! the targets the walk by arms gives under each of its routes).

const std = @import("std");
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const Subtree = @import("Subtree.zig");
const Place = @import("Place.zig");
const Relation = @import("Relation.zig");
const Contract = @import("Contract.zig");
const RouteWalk = @import("RouteWalk.zig");

const Error = Relation.Error;
const Eval = Relation.Eval;
const Proj = Relation.Proj;
const Step = Place.Step;

pub const Req = RouteWalk.Req;
pub const project = RouteWalk.project;
/// An arrival's leaves at a parameter's slot (`Eval.routed`): the leaf at its path for an argument at the path's
/// root with no `⟲` on its way (§2.11.2, *an arrival keeps its path*); else `RouteWalk.paramLeaves`.
pub fn paramLeaves(e: *Eval, v: u32, words: []const u32, deep: bool, path: u32, out: *std.ArrayList(u32)) Error!void {
    const x, const at = .{ e.f.val(v), if (path != Ids.none_int) e.places().ancestorAt(.from(path), 0) else .{ Ids.PathId.none, 0 } };
    if (path != Ids.none_int and x.kind == .ref and x.family == Slots.empty and !e.places().paths.col.info[path].levels and e.f.pos.items[x.pos].slot == at[0]) {
        try e.charge(.path, at[1] + 1);
        const set = if (deep) try Subtree.below(e.f.slots, e.gpa(), e.account(), e.places(), .from(path)) else try e.f.slots.canon(e.gpa(), e.account(), e.places(), .from(path));
        if (set != Slots.empty) try out.append(e.gpa(), try e.f.leaf(.{ .kind = .ref, .root = x.root, .pos = x.pos, .slots = set }));
        return;
    }
    return RouteWalk.paramLeaves(e, v, words, deep, out);
}
pub const leavesOf = RouteWalk.leavesOf;

/// The targets of each write of `ws` that are its argument projected (deep,
/// or by steps that end at no cell's contents), by one walk an argument
/// written twice or more; null for the others (`Eval.callWrite`'s own).
pub fn ofWrites(e: *Eval, args: []const u32, ws: []const Contract.Effect) Error![]?std.ArrayList(Proj) {
    const g = e.gpa();
    const out = try e.arena.alloc(?std.ArrayList(Proj), ws.len);
    @memset(out, null);
    var js: std.ArrayList(u32) = .empty;
    defer js.deinit(g);
    var at: std.ArrayList(u32) = .empty;
    defer at.deinit(g);
    for (ws) |x| if (x.j < args.len and std.mem.indexOfScalar(u32, js.items, x.j) == null) try js.append(g, x.j);
    for (js.items) |j| {
        at.clearRetainingCapacity();
        for (ws, 0..) |y, k| {
            const words = e.f.slots.relWords(y.slot);
            if (y.j == j and (y.deep or (words.len != 0 and Step.fromWord(words[words.len - 1]).kind != .contents))) try at.append(g, @intCast(k));
        }
        if (at.items.len < 2) continue;
        const reqs = try e.arena.alloc(Req, at.items.len);
        for (at.items, reqs) |k, *r| {
            out[k] = .empty;
            r.* = .{ .words = e.f.slots.relWords(ws[k].slot), .deep = ws[k].deep, .out = &out[k].? };
        }
        try project(e, args[j], reqs, 0, 0);
        // A target carries its routes in its leaf (`Value.Leaf.routes`).
        for (reqs) |r| for (r.out.items) |*p| if (p.routes != 0) {
            var l = e.f.leafAt(p.leaf);
            l.routes = p.routes;
            p.* = .{ .leaf = try e.f.leaf(l), .route = p.route, .occ = p.occ };
        };
    }
    return out;
}

/// Leaf `t` once per route of its set, its tags those of the route (what
/// the walk by arms gave), or `t` itself when it has no set.
pub fn writtenOut(e: *Eval, t: u32, out: *std.ArrayList(u32)) Error!void {
    const g = e.gpa();
    const l = e.f.leafAt(t);
    if (l.routes == 0) return out.append(g, t);
    var it = try e.f.sets.tags.routeIter(g, l.routes, l.tags);
    defer it.deinit(g);
    while (try it.next(g, e.account())) |r| {
        try e.charge(.inspection, 1);
        var x = l;
        x.tags = r;
        x.routes = 0;
        try out.append(g, try e.f.leaf(x));
    }
}
