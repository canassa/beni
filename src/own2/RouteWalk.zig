//! L8: one walk of a value along several paths by route sets, `⟲` one of
//! its shared steps
//! (`docs/design/ownership-v2.md` §2.11.2 *A projection carries a route
//! set*, #1714). `Paths.project` walks each arm of an `alt` on its own, so a
//! value two arms reach is read once per arm, and a chain of n such choices
//! is 2ⁿ walks of its first value. Here the values are read in decreasing
//! id: a value's kids are made before it, so every arrival at a value is in
//! before the value is read, and two arrivals with the same paths left and
//! the same literal route are one item, under the union of their routes.
//! Each output carries that route set (`Relation.Proj.routes`), relative to
//! its leaf's own tags. Split from `Routed` (#1714): `Routed` keeps the
//! write targets and the reader that writes a set out.
//!
//! Obligations kept here: none of §2.14's directly (each output stands for
//! the outputs `Paths.project` gives under each of its routes, and no
//! other).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Relation = @import("Relation.zig");
const Coexist = @import("Coexist.zig");

const Error = Relation.Error;
const Eval = Relation.Eval;
const Proj = Relation.Proj;
const Step = Place.Step;
const none: u32 = Ids.none_int;

/// One path: its words, deep or not, its output.
pub const Req = struct { words: []const u32, deep: bool, out: *std.ArrayList(Proj) };

/// A value to read: its paths from `at`, its literal route, and what it is
/// reached under: tag list `tags` alone while one arrival reaches it, or
/// the route set `routes` (each route merged with `tags`) once two have.
/// A **descent** item (`lvl` the index of a `⟲` in its paths) is a value
/// one or more levels below the `⟲`'s value, at `place` on the cycle of
/// `origin` (`below`: under it, not the value itself), as
/// `Eval.projectLevels` walks it: `⟲` is a step the walk shares.
const Item = struct { v: u32, at: u32, route: u32, run: u32, tags: u32 = 0, routes: u32 = 0, read: bool = false, more: u32 = none, lvl: u32 = none, place: u32 = 0, origin: u32 = 0, below: bool = false };

const Walk = struct {
    e: *Eval,
    reqs: []const Req,
    items: std.ArrayList(Item) = .empty,
    /// `(value, at, route, run, place, origin)` → its item.
    index: Ids.FixedDict(6) = .{},
    /// The items not read yet, the greatest value first.
    heap: std.ArrayList(u32) = .empty,
    runs: std.ArrayList([]const u32) = .empty,
    run_index: Ids.FixedDict(2) = .{},
    /// The later arrivals at an item, `(set, next)`: united once, when the
    /// item is read.
    more: std.ArrayList([2]u32) = .empty,

    fn deinit(w: *Walk) void {
        const g = w.e.gpa();
        w.more.deinit(g);
        w.items.deinit(g);
        w.index.deinit(g);
        w.heap.deinit(g);
        w.runs.deinit(g);
        w.run_index.deinit(g);
    }

    /// The run of paths `xs`, one id per content.
    fn run(w: *Walk, xs: []const u32) Error!u32 {
        const g = w.e.gpa();
        const h = std.hash.Wyhash.hash(3, std.mem.sliceAsBytes(xs));
        var key: [2]u32 = .{ @truncate(h), @truncate(h >> 32) };
        while (w.run_index.get(key)) |id| {
            if (std.mem.eql(u32, w.runs.items[id], xs)) return id;
            key[1] +%= 1;
        }
        const id: u32 = @intCast(w.runs.items.len);
        try w.runs.append(g, try w.e.arena.dupe(u32, xs));
        try w.run_index.put(g, key, id);
        return id;
    }

    fn less(w: *const Walk, a: u32, b: u32) bool {
        const x = w.items.items[a];
        const y = w.items.items[b];
        return x.v < y.v or (x.v == y.v and a > b);
    }

    /// What an item is reached under, as one route set.
    fn setOf(w: *Walk, it: Item) Error!u32 {
        const tbl = &w.e.f.sets.tags;
        if (it.routes == 0) {
            var one = [1]u32{it.tags};
            return tbl.internRoutes(w.e.gpa(), w.e.account(), &one, 0, 0);
        }
        return tbl.wrapRoutes(w.e.gpa(), w.e.account(), it.routes, it.tags);
    }

    /// An arrival: a new item, or one more set of routes for the item that
    /// has its value, paths and route. Every arrival is at a kid of a value
    /// read, a smaller id, so that item is not read yet; one read already
    /// would be read again on its own.
    fn arrive(w: *Walk, it: Item) Error!void {
        if (it.routes == none) return;
        const g = w.e.gpa();
        const at = if (it.lvl == none) it.at else it.lvl | 1 << 31 | @as(u32, @intFromBool(it.below)) << 30;
        const got = try w.index.getOrPut(g, .{ it.v, at, it.route, it.run, it.place, it.origin });
        if (got.found_existing and !w.items.items[got.value_ptr.*].read) {
            // A merge is charged here; an item, when it is read (`project`'s
            // own, where it is emitted).
            try w.e.charge(.inspection, 1);
            const x = &w.items.items[got.value_ptr.*];
            try w.more.append(g, .{ try w.setOf(it), x.more });
            x.more = @intCast(w.more.items.len - 1);
            return;
        }
        const id: u32 = @intCast(w.items.items.len);
        got.value_ptr.* = id;
        try w.items.append(g, it);
        try w.heap.append(g, id);
        var i = w.heap.items.len - 1;
        while (i > 0) {
            const p = (i - 1) / 2;
            if (!w.less(w.heap.items[p], w.heap.items[i])) break;
            std.mem.swap(u32, &w.heap.items[p], &w.heap.items[i]);
            i = p;
        }
    }

    fn pop(w: *Walk) Error!?Item {
        const hs = w.heap.items;
        if (hs.len == 0) return null;
        const top = hs[0];
        hs[0] = hs[hs.len - 1];
        w.heap.items.len -= 1;
        var i: usize = 0;
        while (true) {
            const l = 2 * i + 1;
            if (l >= w.heap.items.len) break;
            const c = if (l + 1 < w.heap.items.len and w.less(w.heap.items[l], w.heap.items[l + 1])) l + 1 else l;
            if (!w.less(w.heap.items[i], w.heap.items[c])) break;
            std.mem.swap(u32, &w.heap.items[i], &w.heap.items[c]);
            i = c;
        }
        const x = &w.items.items[top];
        x.read = true;
        if (x.more != none) {
            // Every arrival's routes, united once.
            var sets: std.ArrayList(u32) = .empty;
            defer sets.deinit(w.e.gpa());
            try sets.append(w.e.gpa(), try w.setOf(x.*));
            var at = x.more;
            while (at != none) : (at = w.more.items[at][1]) try sets.append(w.e.gpa(), w.more.items[at][0]);
            x.routes = try w.e.f.sets.tags.uniteAll(w.e.gpa(), w.e.account(), sets.items);
            x.tags = 0;
        }
        return x.*;
    }

    /// `project` of item `it`'s value by path `r`'s words from its `at`,
    /// each output under the item's routes (an output none of whose routes
    /// holds with its tags is no output).
    fn emit(w: *Walk, r: u32, it: Item) Error!void {
        const e = w.e;
        const g = e.gpa();
        var tmp: std.ArrayList(Proj) = .empty;
        defer tmp.deinit(g);
        const q = w.reqs[r];
        const x = e.f.val(it.v);
        if (it.routes == 0 and q.words.len == it.at and q.deep and !e.parts and (x.kind == .alt or x.kind == .built)) {
            // A value read deep whole: its leaf set, each element once under
            // its routes.
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(g);
            try leavesOf(e, it.v, &ls);
            for (ls.items, 0..) |id, k| {
                // A leaf two coexisting routes reach is read twice; its second
                // copy is at a route of its own (§2.9.3, #1748), as in `Eval.project`.
                const route = if (k != 0 and ls.items[k - 1] == id) try e.routeStep(it.route, Ids.none_int - 1) else it.route;
                var l = e.f.leafAt(id);
                const rs = l.routes;
                if (rs == 0 and it.tags == 0) {
                    try q.out.append(g, .{ .leaf = id, .route = route });
                    continue;
                }
                l.routes = 0;
                l.tags = (try e.f.mergeTags(l.tags, it.tags)) orelse continue;
                if (rs != 0 and !try Coexist.setsMeet(&e.f.sets.tags, g, e.account(), l.tags, rs, 0, 0)) continue;
                try q.out.append(g, .{ .leaf = try e.f.leaf(l), .route = route, .routes = rs });
            }
            return;
        }
        try e.project(it.v, q.words[it.at..], q.deep, it.tags, it.route, &tmp);
        for (tmp.items) |p| {
            if (it.routes != 0 and !try Coexist.setsMeet(&e.f.sets.tags, g, e.account(), e.f.leafAt(p.leaf).tags, it.routes, 0, 0)) continue;
            try q.out.append(g, .{ .leaf = p.leaf, .route = p.route, .occ = p.occ, .routes = it.routes });
        }
    }
};

/// `project` of item `it`'s value by `words` for path `r`, each output
/// under the item's routes (a descent's reference read on, `projectLevels`).
fn emitWords(w: *Walk, r: u32, it: Item, words: []const u32) Error!void {
    const e = w.e;
    var tmp: std.ArrayList(Proj) = .empty;
    defer tmp.deinit(e.gpa());
    try e.project(it.v, words, w.reqs[r].deep, it.tags, it.route, &tmp);
    for (tmp.items) |p| {
        if (it.routes != 0 and !try Coexist.setsMeet(&e.f.sets.tags, e.gpa(), e.account(), e.f.leafAt(p.leaf).tags, it.routes, 0, 0)) continue;
        try w.reqs[r].out.append(e.gpa(), .{ .leaf = p.leaf, .route = p.route, .occ = p.occ, .routes = it.routes });
    }
}

/// A descent item (`Eval.projectLevels`, one step of its walk): a value at
/// the `⟲`'s place below it goes on by the paths' rest, a built value's
/// kids on the cycle and an `alt`'s arms (no tag: the levels walk adds
/// none) are descent items, a reference reads its own levels below.
fn descend(w: *Walk, it: Item) Error!void {
    const e = w.e;
    const g = e.gpa();
    const pl = e.places();
    const x = e.f.val(it.v);
    const place: Place.PlaceId = @fromBackingInt(@intCast(it.place));
    const origin: Place.PlaceId = @fromBackingInt(@intCast(it.origin));
    var on = withKid(it, it.v, it.route);
    on.lvl = none;
    on.at = it.lvl + 1;
    on.place = 0;
    on.origin = 0;
    on.below = false;
    switch (x.kind) {
        .built => {
            if (it.below and place == origin) try w.arrive(on);
            for (e.f.kidsOf(x), 0..) |k, n| {
                const kst: Step = switch (x.form) {
                    .list => Step.elem,
                    .record => try Step.field(e.account(), e.f.wordsOf(x.extra)[n]),
                    .tuple => try Step.index(e.account(), @intCast(n)),
                    .ctor => try pl.ctorStep(g, e.account(), x.head, @intCast(n)),
                    .closure, .opaque_ => continue,
                };
                const kp = pl.child(place, kst) orelse continue;
                if (kp != origin and !pl.sameCycle(kp, origin)) continue;
                var kid = withKid(it, k, try kidRoute(e, it.route, @intCast(n)));
                kid.place = kp.int();
                kid.below = true;
                try w.arrive(kid);
            }
        },
        .scalar, .bot => {},
        .ref => if (it.below) {
            if (place == origin) try w.arrive(on);
            // A part on the cycle at another place: its next level is the
            // steps to the cycle's place; its own levels below by its slots.
            var to: std.ArrayList(u32) = .empty;
            defer to.deinit(g);
            if (place != origin and x.family == Slots.empty) try e.stepsTo(e.f.pos.items[x.pos].slot, origin, &to);
            var lv: std.ArrayList(u32) = .empty;
            defer lv.deinit(g);
            for (w.runs.items[it.run]) |r| {
                const rest = w.reqs[r].words[it.lvl + 1 ..];
                if (to.items.len != 0) {
                    lv.clearRetainingCapacity();
                    try lv.appendSlice(g, to.items);
                    try lv.appendSlice(g, rest);
                    try emitWords(w, r, it, lv.items);
                }
                lv.clearRetainingCapacity();
                try lv.appendSlice(g, to.items);
                try lv.append(g, Step.level.word());
                try lv.appendSlice(g, rest);
                try emitWords(w, r, it, lv.items);
            }
        },
        .alt => {
            const ks = e.f.kidsOf(x);
            var i: usize = 0;
            while (i < ks.len) : (i += 2) try w.arrive(withKid(it, ks[i + 1], it.route));
        },
        else => if (it.below) try w.arrive(on),
    }
}

/// `Eval.project` of `v` along every path of `reqs`, a step two paths share
/// read once and a value several arms reach once under the union of their
/// routes (§2.11.2). `pass`: the pass a deep read of a value reads under.
pub fn project(e: *Eval, v: u32, reqs: []const Req, route: u32, pass: u32) Error!void {
    const g = e.gpa();
    const saved = e.pass;
    e.pass = pass;
    defer e.pass = saved;
    var w: Walk = .{ .e = e, .reqs = reqs };
    defer w.deinit();
    const all = try e.arena.alloc(u32, reqs.len);
    for (all, 0..) |*x, i| x.* = @intCast(i);
    try w.arrive(.{ .v = v, .at = 0, .route = route, .run = try w.run(all) });
    var on: std.ArrayList(u32) = .empty;
    defer on.deinit(g);
    var grp: std.ArrayList(u32) = .empty;
    defer grp.deinit(g);
    while (try w.pop()) |it| {
        if (it.lvl != none) {
            try e.charge(.inspection, 1);
            try descend(&w, it);
            continue;
        }
        const x = e.f.val(it.v);
        const rs = w.runs.items[it.run];
        on.clearRetainingCapacity();
        for (rs) |r| if (reqs[r].words.len > it.at) try on.append(g, r);
        // A path alone below a built value is `project`'s, as in the walk by
        // arms; an arm is this walk's, so a value two arms reach is read once.
        // A walk whose literal routes nobody reads (`Eval.no_routes`) takes
        // every step it shares itself, so arrivals merge below a built value too.
        if (x.kind != .alt and (x.kind != .built or (on.items.len < 2 and !e.no_routes))) {
            for (rs) |r| try w.emit(r, it);
            continue;
        }
        try e.charge(.inspection, 1);
        for (rs) |r| if (reqs[r].words.len == it.at) try w.emit(r, it);
        if (on.items.len == 0) continue;
        const ks = e.f.kidsOf(x);
        const on_run = try w.run(on.items);
        if (x.kind == .alt) {
            var i: usize = 0;
            while (i < ks.len) : (i += 2) {
                const t = try e.f.internTags(&.{.{ x.head, try e.f.armOf(ks[i]) }});
                var arm: Item = .{ .v = ks[i + 1], .at = it.at, .route = it.route, .run = on_run, .tags = it.tags, .routes = it.routes };
                // One arrival keeps a list, as the walk by arms does; a set
                // takes the arm's tag in front of every route.
                if (it.routes == 0) {
                    arm.tags = (try e.f.mergeTags(it.tags, t)) orelse continue;
                } else arm.routes = try e.f.sets.tags.prefixRoutes(g, e.account(), it.routes, t);
                try w.arrive(arm);
            }
            continue;
        }
        // The paths by their next step, in their order; a step `project`
        // reads otherwise is its own.
        for (on.items, 0..) |r, n| {
            const wd = reqs[r].words[it.at];
            if (for (on.items[0..n]) |q| {
                if (reqs[q].words[it.at] == wd) break true;
            } else false) continue;
            const st = Step.fromWord(wd);
            const shared = switch (st.kind) {
                .ctor_arg => x.form == .ctor,
                .index => x.form == .tuple,
                .elem => x.form == .list,
                .field => x.form == .record,
                .level => x.place != .none,
                else => false,
            };
            if (!shared) {
                for (on.items[n..]) |q| if (reqs[q].words[it.at] == wd) try w.emit(q, it);
                continue;
            }
            grp.clearRetainingCapacity();
            for (on.items[n..]) |q| if (reqs[q].words[it.at] == wd) try grp.append(g, q);
            const kid_run = try w.run(grp.items);
            const kid: Item = .{ .v = 0, .at = it.at + 1, .route = 0, .run = kid_run, .tags = it.tags, .routes = it.routes };
            switch (st.kind) {
                .level => try w.arrive(.{ .v = it.v, .at = it.at, .route = it.route, .run = kid_run, .tags = it.tags, .routes = it.routes, .lvl = it.at, .place = x.place.int(), .origin = x.place.int() }),
                .ctor_arg => {
                    const ca = e.places().ctorArgOf(st);
                    if (ca[0] == x.head and ca[1] < ks.len) try w.arrive(withKid(kid, ks[ca[1]], try kidRoute(e, it.route, ca[1])));
                },
                .index => if (st.payload < ks.len) try w.arrive(withKid(kid, ks[st.payload], try kidRoute(e, it.route, st.payload))),
                .elem => for (ks, 0..) |k, m| try w.arrive(withKid(kid, k, try kidRoute(e, it.route, @intCast(m)))),
                else => for (e.f.wordsOf(x.extra), 0..) |f, m| if (f == st.payload) try w.arrive(withKid(kid, ks[m], try kidRoute(e, it.route, @intCast(m)))),
            }
        }
    }
}

/// A kid's literal route; none where nobody reads them (`Eval.no_routes`).
fn kidRoute(e: *Eval, route: u32, kid: u32) Error!u32 {
    return if (e.no_routes) 0 else e.routeStep(route, kid);
}

/// Item `it`'s arrival at `v` by `route`: not read, with no later arrivals.
fn withKid(it: Item, v: u32, route: u32) Item {
    var k = it;
    k.v = v;
    k.route = route;
    k.read = false;
    k.more = none;
    return k;
}

/// An arrival's leaves at a parameter's slot (`Eval.routed`): `Eval.project`
/// of `v` by one path, where no literal route is read, so a value several
/// arms or levels reach is one item under the union of their routes, and
/// each leaf carries that set (§2.3.5, *a key's leaf*).
pub fn paramLeaves(e: *Eval, v: u32, words: []const u32, deep: bool, out: *std.ArrayList(u32)) Error!void {
    const g = e.gpa();
    var ps: std.ArrayList(Proj) = .empty;
    defer ps.deinit(g);
    const was = e.no_routes;
    e.no_routes = true;
    defer e.no_routes = was;
    // A value with no arm or part to share is `project`'s alone.
    const k = e.f.val(v).kind;
    const req = [1]Req{.{ .words = words, .deep = deep, .out = &ps }};
    if (k == .alt or k == .built) try project(e, v, &req, 0, 0) else try e.project(v, words, deep, 0, 0, &ps);
    for (ps.items) |p| {
        if (p.routes == 0) {
            try out.append(g, p.leaf);
            continue;
        }
        var l = e.f.leafAt(p.leaf);
        l.routes = p.routes;
        try out.append(g, try e.f.leaf(l));
    }
}

/// `Eval.leavesOf(v, 0)` with each element once under its route set
/// (§2.11.2), not once per route: a value an `else if` chain of n choices
/// reaches by 2ⁿ routes is one leaf. Read under the evaluation's pass, as
/// `leavesOf` reads it. A set that holds a prepend's own storage is read
/// as `leavesOf` reads it.
pub fn leavesOf(e: *Eval, v: u32, out: *std.ArrayList(u32)) Error!void {
    const g = e.gpa();
    const f = e.f;
    const start = out.items.len;
    var it = f.sets.iterate(f.deep.items[v], e.pass);
    while (try it.next(g, e.account())) |el| {
        try e.charge(.inspection, 1);
        var l = f.leafAt(el.key);
        if (l.kind == .recons) {
            out.shrinkRetainingCapacity(start);
            return e.leavesOf(v, 0, out);
        }
        if (l.kind == .ref and l.extra != 0) l = (try f.resolveRef(l)) orelse continue;
        l.tags = el.tags;
        l.routes = el.routes;
        const rs = if (el.routes != 0) f.sets.tags.rset(el.routes) else null;
        if (rs != null and rs.?.kind == .flat and f.sets.tags.runs.get(rs.?.a).len == 1) {
            l.tags = (try f.mergeTags(el.tags, f.sets.tags.runs.get(rs.?.a)[0])) orelse continue;
            l.routes = 0;
        } else if (l.routes != 0 and !try Coexist.setsMeet(&f.sets.tags, g, e.account(), l.tags, l.routes, 0, 0)) continue;
        const id = try f.leaf(l);
        try out.append(g, id);
        if (el.many) try out.append(g, id);
    }
}
