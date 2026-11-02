//! L8: one walk of a value along several paths (`docs/design/ownership-v2.md`
//! §2.11.2 item 3, #1714): what `Relation.Eval.project` gives for each path,
//! with an arm or a step two paths share read once. A call's selection
//! projected occurrence by occurrence walked an `else if` chain once an
//! occurrence, and made its arms' tags again each time.
//!
//! Obligations kept here: none of §2.14's directly (each path's
//! projections are `project`'s).

const std = @import("std");
const Place = @import("Place.zig");
const Relation = @import("Relation.zig");
const Contract = @import("Contract.zig");

const Error = Relation.Error;
const Eval = Relation.Eval;
const Proj = Relation.Proj;
const Step = Place.Step;

/// One path of a shared projection: its words, deep or not, its output.
pub const Req = struct { words: []const u32, deep: bool, out: *std.ArrayList(Proj) };

/// `Eval.project` of `v` along every path of `reqs` by one walk: an arm or
/// a step two paths share is read once. A path alone, at its end, or at a
/// value read by its kind is projected on by `project` from there, so each
/// path's projections are `project`'s, in its order.
pub fn project(e: *Eval, v: u32, reqs: []const Req, route: u32) Error!void {
    const g = e.gpa();
    const Item = struct { v: u32, at: u32, tags: u32, route: u32, run: []const u32 };
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(g);
    const all = try e.arena.alloc(u32, reqs.len);
    for (all, 0..) |*x, i| x.* = @intCast(i);
    try stack.append(g, .{ .v = v, .at = 0, .tags = 0, .route = route, .run = all });
    var on: std.ArrayList(u32) = .empty;
    defer on.deinit(g);
    while (stack.pop()) |it| {
        const x = e.f.val(it.v);
        on.clearRetainingCapacity();
        for (it.run) |r| if (reqs[r].words.len > it.at) try on.append(g, r);
        if (on.items.len < 2 or (x.kind != .alt and x.kind != .built)) {
            for (it.run) |r| try e.project(it.v, reqs[r].words[it.at..], reqs[r].deep, it.tags, it.route, reqs[r].out);
            continue;
        }
        try e.charge(.inspection, 1);
        for (it.run) |r| if (reqs[r].words.len == it.at) try e.project(it.v, &.{}, reqs[r].deep, it.tags, it.route, reqs[r].out);
        const ks = e.f.kidsOf(x);
        if (x.kind == .alt) {
            const run = try e.arena.dupe(u32, on.items);
            var i: usize = 0;
            while (i < ks.len) : (i += 2) {
                const t = (try e.f.mergeTags(it.tags, try e.f.internTags(&.{.{ x.head, try e.f.armOf(ks[i]) }}))) orelse continue;
                try stack.append(g, .{ .v = ks[i + 1], .at = it.at, .tags = t, .route = it.route, .run = run });
            }
            continue;
        }
        // The paths by their next step, in their order; a step `project`
        // reads otherwise (a level, an environment, one the literal cannot
        // follow) is its own.
        for (on.items, 0..) |r, n| {
            const w = reqs[r].words[it.at];
            if (for (on.items[0..n]) |q| {
                if (reqs[q].words[it.at] == w) break true;
            } else false) continue;
            const st = Step.fromWord(w);
            const shared = switch (st.kind) {
                .ctor_arg => x.form == .ctor,
                .index => x.form == .tuple,
                .elem => x.form == .list,
                .field => x.form == .record,
                else => false,
            };
            if (!shared) {
                for (on.items[n..]) |q| if (reqs[q].words[it.at] == w) try e.project(it.v, reqs[q].words[it.at..], reqs[q].deep, it.tags, it.route, reqs[q].out);
                continue;
            }
            var grp: std.ArrayList(u32) = .empty;
            for (on.items[n..]) |q| if (reqs[q].words[it.at] == w) try grp.append(e.arena, q);
            const kid: Item = .{ .v = 0, .at = it.at + 1, .tags = it.tags, .route = 0, .run = grp.items };
            switch (st.kind) {
                .ctor_arg => {
                    const ca = e.places().ctorArgOf(st);
                    if (ca[0] == x.head and ca[1] < ks.len) try stack.append(g, withKid(kid, ks[ca[1]], try e.routeStep(it.route, ca[1])));
                },
                .index => if (st.payload < ks.len) try stack.append(g, withKid(kid, ks[st.payload], try e.routeStep(it.route, st.payload))),
                .elem => for (ks, 0..) |k, m| try stack.append(g, withKid(kid, k, try e.routeStep(it.route, @intCast(m)))),
                else => for (e.f.wordsOf(x.extra), 0..) |f, m| if (f == st.payload) try stack.append(g, withKid(kid, ks[m], try e.routeStep(it.route, @intCast(m)))),
            }
        }
    }
}

fn withKid(it: anytype, v: u32, route: u32) @TypeOf(it) {
    var k = it;
    k.v = v;
    k.route = route;
    return k;
}

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
        try project(e, args[j], reqs, 0);
    }
    return out;
}
