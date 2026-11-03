//! L8: a selection's apart and plain occurrences of one parameter read
//! part by part (`docs/design/ownership-v2.md` §2.9.1, §2.11.2): which
//! parameters are asked both ways, the plain objects taken from the apart
//! ones at their routes, and a projection's route sets written out where
//! the two are compared route by route. Split from `Distinct` (#1714).
//!
//! Obligations kept here: §2.9.1's deep apart occurrence asks apart only
//! the objects its condition's plain occurrences do not ask plain.

const std = @import("std");
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const Subtree = @import("Subtree.zig");
const Contract = @import("Contract.zig");
const Relation = @import("Relation.zig");

const Error = Relation.Error;
const Eval = Relation.Eval;
const Proj = Relation.Proj;

/// Whether two of the projections name one leaf's place by one route
/// under two route sets.
pub fn routesDiffer(e: *Eval, aps: []const Proj, plains: []const Proj) Error!bool {
    var at: Ids.FixedDict(4) = .{};
    defer at.deinit(e.gpa());
    for ([2][]const Proj{ aps, plains }) |ps| for (ps) |p| {
        try e.charge(.cond, 1);
        const l = e.f.leafAt(p.leaf);
        const got = try at.getOrPut(e.gpa(), .{ l.root, l.pos, l.tags, p.route });
        if (got.found_existing and got.value_ptr.* != p.routes) return true;
        got.value_ptr.* = p.routes;
    };
    return false;
}

/// Each projection of `ps` once per route of its set, its tags those of
/// the route (§2.11.2: what the walk by arms gives).
pub fn writeOut(e: *Eval, ps: *std.ArrayList(Proj)) Error!void {
    const g = e.gpa();
    const f = e.f;
    var out: std.ArrayList(Proj) = .empty;
    for (ps.items) |p| {
        if (p.routes == 0) {
            try out.append(g, p);
            continue;
        }
        var it = try f.sets.tags.routeIter(g, p.routes, f.leafAt(p.leaf).tags);
        defer it.deinit(g);
        while (try it.next(g, e.account())) |t| {
            try e.charge(.cond, 1);
            var l = f.leafAt(p.leaf);
            l.tags = t;
            try out.append(g, .{ .leaf = try f.leaf(l), .route = p.route, .occ = p.occ });
        }
    }
    ps.deinit(g);
    ps.* = out;
}

/// Whether occurrences `occs` ask parameter `j` deep apart somewhere and
/// plain somewhere.
pub fn mixed(occs: []const u64, j: u32) bool {
    var deep_apart = false;
    var plain = false;
    for (occs) |o| if (Contract.occParam(o) == j) {
        if (!Contract.isApart(o)) plain = true else if (Contract.isDeep(o)) deep_apart = true;
    };
    return deep_apart and plain;
}

/// §2.9.1: a deep apart occurrence asks apart only the objects the plain
/// occurrences of its condition do not ask plain. Both are read part by
/// part, so a route names one place in the argument: an object a plain
/// occurrence reaches at a route is taken once from the apart ones at that
/// route (as many times as the plain ones reach it, never by leaf alone:
/// one object at two places is two entries); a reference's slots lose the
/// plain ones' at its route (`Subtree.without`).
pub fn withoutPlain(e: *Eval, aps: []const Proj, plains: []const Proj, out: *std.ArrayList(Proj)) Error!void {
    if (aps.len == 0) return;
    const g = e.gpa();
    const f = e.f;
    var taken: Ids.FixedDict(3) = .{};
    defer taken.deinit(g);
    var refs: Ids.FixedDict(5) = .{};
    defer refs.deinit(g);
    var minus: std.ArrayList(std.ArrayList(Slots.SetId)) = .empty;
    defer {
        for (minus.items) |*m| m.deinit(g);
        minus.deinit(g);
    }
    for (plains) |p| {
        try e.charge(.cond, 1);
        const l = f.leafAt(p.leaf);
        if (l.kind == .ref) {
            const got = try refs.getOrPut(g, .{ l.root, l.pos, l.tags, p.route, p.routes });
            if (!got.found_existing) {
                got.value_ptr.* = @intCast(minus.items.len);
                try minus.append(g, .empty);
            }
            try minus.items[got.value_ptr.*].append(g, l.slots);
            continue;
        }
        const got = try taken.getOrPut(g, .{ p.leaf, p.route, p.routes });
        got.value_ptr.* = if (got.found_existing) got.value_ptr.* + 1 else 1;
    }
    for (aps) |p| {
        try e.charge(.cond, 1);
        var l = f.leafAt(p.leaf);
        if (l.kind == .ref) {
            if (refs.get(.{ l.root, l.pos, l.tags, p.route, p.routes })) |mi| {
                l.slots = (try Subtree.without(f.slots, g, e.account(), e.places(), l.slots, minus.items[mi].items)) orelse continue;
                try out.append(g, .{ .leaf = try f.leaf(l), .route = p.route, .occ = p.occ, .routes = p.routes });
                continue;
            }
        } else if (taken.get(.{ p.leaf, p.route, p.routes })) |n| if (n != 0) {
            (try taken.getOrPut(g, .{ p.leaf, p.route, p.routes })).value_ptr.* = n - 1;
            continue;
        };
        try out.append(g, p);
    }
}
