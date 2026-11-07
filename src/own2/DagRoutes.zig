//! L8: the route sets of a DAG's items (`docs/design/ownership-v2.md` §2.8
//! step 3 on slots, *A hold under its route set*, #1714). The best-hold
//! descent meets a holder's DAG as items, each a node at a path (or, in a
//! subtree that answers for its paths, a node at a use), and one node is an
//! `alt`'s arm below as many items as there are tag lists above it. Here
//! each item is reached under one route set: its arrivals' routes, an
//! arm's tag put in front, united once before the item's own arrivals are
//! sent on. A kid's value is made before its parent's, so in decreasing
//! value id every arrival at an item is in before it is read, as in
//! `Routed.project`. While one route reaches an item it is a tag list
//! (`tags`, `routes` 0); once two have, a set (`routes`, relative to no
//! tags), as `Value.Leaf.routes` is.
//!
//! Obligations kept here: none of §2.14's directly (an item's set holds
//! each route of every path from the root to it, and no other).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Coexist = @import("Coexist.zig");
const Relation = @import("Relation.zig");

const Error = Relation.Error;
const Eval = Relation.Eval;
const none: u32 = Ids.none_int;

pub const Item = struct { v: u32, tags: u32 = 0, routes: u32 = 0, reached: bool = false, more: u32 = none, edges: Ids.Range = .{ .start = none, .len = 0 } };

pub const Table = struct {
    items: std.ArrayList(Item) = .empty,
    /// Per edge: `(kid item, arm tag)`, each item's edges one run.
    edges: std.ArrayList([2]u32) = .empty,
    /// The later arrivals at an item, `(set, next)`.
    more: std.ArrayList([2]u32) = .empty,

    pub fn deinit(t: *Table, g: Allocator) void {
        t.items.deinit(g);
        t.edges.deinit(g);
        t.more.deinit(g);
    }

    /// A new item of value `v`, not reached yet.
    pub fn add(t: *Table, g: Allocator, v: u32) Error!u32 {
        try t.items.append(g, .{ .v = v });
        return @intCast(t.items.items.len - 1);
    }

    /// Item `from`'s edges begin: the next `edge`s are its.
    pub fn begin(t: *Table, from: u32) void {
        t.items.items[from].edges = .{ .start = @intCast(t.edges.items.len) };
    }

    pub fn edge(t: *Table, g: Allocator, from: u32, to: u32, arm: u32) Error!void {
        try t.edges.append(g, .{ to, arm });
        t.items.items[from].edges.len += 1;
    }

    fn setOf(e: *Eval, it: Item) Error!u32 {
        const tbl = &e.f.sets.tags;
        if (it.routes == 0) {
            var one = [1]u32{it.tags};
            return tbl.internRoutes(e.gpa(), e.account(), &one, 0, 0);
        }
        return tbl.wrapRoutes(e.gpa(), e.account(), it.routes, it.tags);
    }

    fn arrive(t: *Table, e: *Eval, to: u32, tags: u32, routes: u32) Error!void {
        if (routes == none) return;
        try e.charge(.inspection, 1);
        const x = &t.items.items[to];
        if (!x.reached) {
            x.* = .{ .v = x.v, .tags = tags, .routes = routes, .reached = true, .edges = x.edges };
            return;
        }
        try t.more.append(e.gpa(), .{ try setOf(e, .{ .v = 0, .tags = tags, .routes = routes }), x.more });
        x.more = @intCast(t.more.items.len - 1);
    }

    /// Every item's routes from item `root`, reached under no tags: items
    /// read in decreasing value id, each one's arrivals united, then sent
    /// along its edges (an arm's tag in front; a route it conflicts with
    /// dropped). An item no route reaches stays unreached.
    pub fn settle(t: *Table, e: *Eval, root: u32) Error!void {
        const g = e.gpa();
        const n = t.items.items.len;
        const order = try g.alloc(u32, n);
        defer g.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        try e.charge(.inspection, @intCast(n));
        std.mem.sort(u32, order, t.items.items, struct {
            fn gt(its: []const Item, a: u32, b: u32) bool {
                return its[a].v > its[b].v or (its[a].v == its[b].v and a < b);
            }
        }.gt);
        t.items.items[root].reached = true;
        var sets: std.ArrayList(u32) = .empty;
        defer sets.deinit(g);
        for (order) |id| {
            const x = &t.items.items[id];
            if (!x.reached) continue;
            if (x.more != none) {
                sets.clearRetainingCapacity();
                try sets.append(g, try setOf(e, x.*));
                var at = x.more;
                while (at != none) : (at = t.more.items[at][1]) try sets.append(g, t.more.items[at][0]);
                x.routes = try e.f.sets.tags.uniteAll(g, e.account(), sets.items);
                x.tags = 0;
                x.more = none;
            }
            const it = x.*;
            for (t.edges.items[it.edges.start..][0..it.edges.len]) |ed| {
                if (ed[1] == 0) {
                    try t.arrive(e, ed[0], it.tags, it.routes);
                } else if (it.routes == 0) {
                    if (try e.f.mergeTags(it.tags, ed[1])) |tg| try t.arrive(e, ed[0], tg, 0);
                } else try t.arrive(e, ed[0], 0, try e.f.sets.tags.prefixRoutes(g, e.account(), it.routes, ed[1]));
            }
        }
    }
};

/// Leaf `li` under item `it`'s routes, into `out` (none where no route
/// holds with its tags): its tags with the item's list merged in, or the
/// item's set as its routes; a leaf with a set of its own takes the item's
/// routes written out over its tags, its own set kept.
pub fn under(e: *Eval, li: u32, it: Item, out: *std.ArrayList(u32)) Error!void {
    const f = e.f;
    const g = e.gpa();
    var l = f.leafAt(li);
    if (it.routes == 0) {
        l.tags = (try f.mergeTags(l.tags, it.tags)) orelse return;
        return out.append(g, try f.leaf(l));
    }
    if (l.routes == 0) {
        if (!try Coexist.setsMeet(&f.sets.tags, g, e.account(), l.tags, it.routes, 0, 0)) return;
        l.routes = it.routes;
        return out.append(g, try f.leaf(l));
    }
    var rs = try f.sets.tags.routeIter(g, it.routes, l.tags);
    defer rs.deinit(g);
    while (try rs.next(g, e.account())) |t| {
        try e.charge(.inspection, 1);
        if (!try Coexist.setsMeet(&f.sets.tags, g, e.account(), t, l.routes, 0, 0)) continue;
        var m = l;
        m.tags = t;
        try out.append(g, try f.leaf(m));
    }
}
