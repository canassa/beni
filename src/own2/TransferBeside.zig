//! L10: a write's other paths and what is beside it
//! (`docs/design/ownership-v2.md` §2.11 item 3, R-5.1.5): `otherPaths`'
//! walk of the callee's use paired with the argument, the written position
//! by canonical path (`routePath`, `frontierAt`, `routesBelow`), the reads
//! beside the write (`reachBeside`, `keepBeside`, `splitBeside`), and the
//! argument at a class's parameter path (`positionsAt`). `Of(Frame)` is
//! this part's methods over the frame `Transfer.zig` declares;
//! `Transfer.zig` binds them by name (§5). It calls only `TransferFrame`.
//!
//! Obligations kept here: none of §2.14's directly; it computes §2.11
//! item 3's other-paths operand of a demand that `Demands` resolves.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const stamped = @import("../stamped.zig");
const Place = @import("Place.zig");
const Cond = @import("Cond.zig");
const Demands = @import("Demands.zig");
const Calls = @import("Calls.zig");
const NodeId = Ids.NodeId;
const CellId = Ids.CellId;
const SetId = Ids.SetId;
const PathId = Ids.PathId;
const CondId = Ids.CondId;
const Value = Demands.Value;
const Beside = Calls.Beside;
const aliasKey = Calls.aliasKey;
const key_top = Calls.key_top;
const key_param = Calls.key_param;
const key_always = Calls.key_always;
const key_param_leaf = Calls.key_param_leaf;
const Step = Place.Step;
const Error = Ids.ChargeError;
const none: u32 = Ids.none_int;

/// Whether a step path names one position: no `[*]` or `⟲` in it.
fn exactPath(steps: []const Step) bool {
    for (steps) |s| if (s.kind == .elem or s.kind == .level) return false;
    return true;
}

/// The part of `Transfer.Frame` this file holds, over the frame `Transfer.zig` declares.
pub fn Of(comptime Frame: type) type {
    return struct {
        /// `at` extended by `steps`, as far as the place graph has them.
        pub fn extendPath(f: *Frame, at: PathId, steps: []const Step) Error!PathId {
            var p = at;
            for (steps) |s| p = (try f.env.places.extend(f.gpa, f.env.charge, p, s)) orelse break;
            return p;
        }
        /// A write's other paths (§2.11 item 3, R-5.1.5), as one operand of the
        /// write's demand, the last one `demand` made: what the argument `arg`
        /// reaches beside the base at every path of `use` (the callee's use of
        /// the written parameter) that holds an object beside the write at
        /// `ws`. The rules are item 3's, per path: above the write only when it
        /// is answered or escapes (`A`, `E`), never the write's own path, below
        /// it only when it goes through `[*]` or `⟲`, every other path; the
        /// argument is read at a path as `positionsAt` reads it, and a parameter
        /// cell of the base two paths fold onto through one leaf
        /// (`keepBeside`'s `folded`) is owed as `excl` instead.
        ///
        /// **By node (#1325).** The use shape is walked as the DAG it is, paired
        /// with the argument's value, each `(use node, value node, state)` once,
        /// and the cells kept beside the base are one set: a use of n read paths
        /// or a doubling DAG costs its distinct nodes, never its paths, and adds
        /// one operand, never one per path (Demands reads an operand's reach
        /// only). A leaf of parameter cells none of whose positions the base
        /// reaches keeps nothing at any path below it (`keepBeside` drops such
        /// cells), so its subtree is not walked. Value-sized: growth chosen
        /// before the work (§4.1, *call view and direct obligation*: a graph is
        /// descended by pre-reserved growth tasks), so a huge use is the loud
        /// `ownership_summary_size`, never a lane past its ceiling.
        ///
        /// **Only what may be the base (#1334).** Two cells whose bases may
        /// not alias (`Cell.alias`) never conflict in Disjoint, so the operand
        /// keeps a cell other than a parameter's only when its alias key
        /// (`aliasKey`) is one of the base's or `⊤`, a parameter's by rule (c).
        /// A node of the write's path finds its children beside the write by
        /// those keys (`Beside`, built once per call and shared by its
        /// writes): `n` writes of `n` fields of one argument cost n, not n².
        pub fn otherPaths(f: *Frame, bs: *Beside, use: NodeId, arg: Value, ws: []const Step, base: Value, inst: u32, deep: bool) Error!void {
            if (use == .none) return;
            const task = try f.account().enter(f.gpa, null);
            defer f.account().leave(task);
            const gpa = f.gpa;
            const shapes = f.env.shapes;
            const cells = f.env.cells;
            const own = try shapes.reach(gpa, f.account(), &cells.sets, base.node);
            // What may be the base: its cells as Demands reads them (a deep
            // demand's reach, whose symbolic cells' descendants share their
            // keys), by alias key; and the parameter cells of `own`, by the
            // paths a parameter leaf beside them may sit at (`unreached`).
            var want: Want = .{};
            defer want.deinit(gpa);
            var bt = cells.sets.iterate(if (deep) own else try shapes.cellsOf(gpa, f.account(), &cells.sets, base.node));
            while (bt.next()) |e| {
                try f.env.charge.reserve(gpa, .inspection, 1);
                const c: CellId = .from(e.key);
                if (cells.origin(cells.base(c)) == .param) continue;
                const k = aliasKey(cells, c);
                if (k[0] == key_top) want.all = true;
                try want.keys.append(gpa, k);
            }
            var ot = cells.sets.iterate(own);
            while (ot.next()) |e| {
                try f.env.charge.reserve(gpa, .inspection, 1);
                const c: CellId = .from(e.key);
                if (cells.origin(cells.base(c)) != .param) continue;
                try want.params.append(gpa, c);
                const at = (try cells.unrefined(gpa, f.account(), f.env.places, c)) orelse {
                    want.any_param_leaf = true;
                    continue;
                };
                const p = cells.get(at);
                var path: PathId = .from(p.b);
                while (true) {
                    try f.env.charge.reserve(gpa, .inspection, 1);
                    try want.keys.append(gpa, .{ key_param, p.a, path.int(), 0 });
                    if (path == .none or f.env.places.pathParent(path) == .none) break;
                    path = f.env.places.pathParent(path);
                }
            }
            try want.keys.append(gpa, .{ key_top, 0, 0, 0 });
            try want.keys.append(gpa, .{ key_always, 0, 0, 0 });
            if (want.any_param_leaf) try want.keys.append(gpa, .{ key_param_leaf, 0, 0, 0 });
            // Two paths fold through one leaf when both meet it through one
            // exact prefix: the write's path meets one at
            // depth `leaf`, and another path does at that depth when it is still
            // the write's path there.
            const leaf = try f.leafDepth(arg, ws);
            const exact = exactPath(ws);
            // The refinements the write's path meets in the argument along its
            // exact prefix: the position of a split the base is, which its
            // projection forgot (§2.2: `elem c·ι` below is `c[*]` below).
            var refs: std.ArrayList(CellId) = .empty;
            defer refs.deinit(gpa);
            try f.spineRefinements(arg.node, ws, &refs);
            var relied: CondId = Cond.yes;
            var stack: std.ArrayList(Item) = .empty;
            defer stack.deinit(gpa);
            var seen: Ids.FixedDict(4) = .{};
            defer seen.deinit(gpa);
            // The written positions, by canonical path (#1253): the base's nodes
            // at the write's own path. A route beside the write that folds back
            // onto that path through the use shape's knot, or a reach that holds
            // them from above, meets the written object itself, not another path
            // of the argument; its other positions there are the `excl` it owes.
            // Never a node alone: use nodes and values are shared, so one node
            // stands at two paths (`{ x = l, z = l }`).
            var written: Written = .{};
            defer written.ends.deinit(gpa);
            defer written.paths.deinit(gpa);
            try f.env.places.expandLevels(gpa, f.env.charge, try f.extendPath(try f.env.places.rootPath(gpa, shapes.place(use)), ws), &written.paths);
            try f.frontierAt(arg.node, ws, &written);
            var read: Ids.FixedDict(3) = .{};
            defer read.deinit(gpa);
            var kept: SetId = .none;
            var excl: SetId = .none;
            try stack.append(gpa, .{ .u = use, .v = arg.node, .mode = .spine, .depth = 0, .folded = false, .stuck = false, .level = false, .held = false, .path = try f.env.places.rootPath(gpa, shapes.place(use)) });
            while (stack.pop()) |it| {
                try f.env.charge.reserve(gpa, .inspection, 1);
                const state: u32 = @as(u32, @backingInt(it.mode)) | @as(u32, @intFromBool(it.folded)) << 2 | @as(u32, @intFromBool(it.stuck)) << 3 | @as(u32, @intFromBool(it.level)) << 4 | @as(u32, @intFromBool(it.held)) << 5 | (if (it.mode == .spine) it.depth << 6 else 0);
                if ((try seen.getOrPut(gpa, .{ it.u.int(), it.v.int(), state, it.path.int() })).found_existing) continue;
                if (it.mode != .spine and written.holds(it.path, it.v)) continue;
                if (try f.unreached(it.v, own)) continue;
                const d = shapes.get(it.u);
                var marks: u8 = 0; // 1 any mark, 2 held (`A` or `E`)
                var ct = cells.sets.iterate(d.cells);
                while (ct.next()) |x| {
                    const c: CellId = .from(x.key);
                    if (cells.origin(c) != .mark) continue;
                    marks |= 1;
                    const m = cells.markOf(c);
                    if (m == .a or m == .e) marks |= 2;
                }
                // Held on the exact write path: what it holds beside the write (#1367).
                var held_below = it.held;
                if (marks & 1 != 0 or it.held) {
                    const beside, const folded = switch (it.mode) {
                        .spine => .{ it.depth < ws.len and (marks & 2 != 0 or it.held), leaf != null and leaf.? < it.depth },
                        .below, .off => .{ true, it.folded },
                    };
                    if (beside and it.mode == .spine and exact) {
                        // A stuck value is from above, where `ws[depth..]` is not its
                        // rest: whole, unless a held item already read it there.
                        if (!it.stuck)
                            try f.keepAnswered(bs, &want, it.v, ws[it.depth..], folded, refs.items, &kept, &excl, &relied)
                        else if (!it.held and !(try read.getOrPut(gpa, .{ it.v.int(), @intFromBool(folded), it.path.int() })).found_existing)
                            try f.keepBeside(bs, &want, it.v, folded, true, null, refs.items, &kept, &excl, &relied, null);
                        held_below = true;
                    } else if (beside and !(try read.getOrPut(gpa, .{ it.v.int(), @intFromBool(folded), it.path.int() })).found_existing)
                        try f.keepBeside(bs, &want, it.v, folded, marks & 2 != 0 or d.kind == .leaf or (cells.mark_d != .none and cells.hasDeepRead(d.cells)), null, refs.items, &kept, &excl, &relied, .{ .path = it.path, .written = &written });
                }
                if (d.kind != .node) continue;
                if (it.mode == .spine and it.depth < ws.len) {
                    // On the write's path: its next step, and the children
                    // beside it that may hold a cell of the base (`Beside`).
                    if (shapes.overGet(d.a, ws[it.depth])) |child| {
                        const next: Item = .{ .u = child, .v = it.v, .mode = .spine, .depth = it.depth + 1, .folded = it.folded, .stuck = it.stuck, .level = it.level, .held = held_below, .path = .none };
                        try f.advance(it, ws[it.depth], next, &stack);
                    }
                    const folded = leaf != null and leaf.? <= it.depth;
                    const sp = try f.spineOf(bs, it);
                    if (want.all) {
                        const r = bs.ranges.items[sp];
                        for (bs.kids.items[r[0]..][0..r[1]]) |k| try f.pushOff(k, ws[it.depth], folded, it.path, &stack);
                        continue;
                    }
                    for (want.keys.items) |k| {
                        var link = bs.head(sp, k);
                        while (link != none) : (link = bs.links.items[link][1]) {
                            try f.env.charge.reserve(gpa, .inspection, 1);
                            try f.pushOff(bs.kids.items[bs.links.items[link][0]], ws[it.depth], folded, it.path, &stack);
                        }
                    }
                    continue;
                }
                if (it.mode == .spine and exact) continue;
                var kt = shapes.overEntries(d.a);
                while (kt.next()) |k| {
                    var next = it;
                    next.u = k.node;
                    if (it.mode == .spine) {
                        // Inside the written object: beside it only when the
                        // write's path stands for several positions.
                        next.mode = .below;
                        next.held = false;
                        next.folded = leaf != null;
                        next.depth = 0;
                    }
                    try f.advance(it, k.step, next, &stack);
                }
            }
            const dm = &f.demands.items[f.demands.items.len - 1];
            dm.relies = try f.env.conds.@"and"(gpa, f.env.charge, dm.relies, relied);
            excl = try cells.sets.unionWith(gpa, f.env.charge, excl, written.owed);
            var xt = cells.sets.iterate(excl);
            while (xt.next()) |x| dm.relies = try f.env.conds.@"and"(gpa, f.env.charge, dm.relies, try f.env.conds.exclOf(gpa, f.env.charge, f.env.cells, .from(x.key)));
            if (kept == .none) return;
            try f.operands.append(gpa, .{ .value = .{ .node = try shapes.leaf(gpa, f.account(), shapes.place(arg.node), kept) }, .inst = inst, .other_paths = true });
            dm.operands.len += 1;
        }

        /// One item of `otherPaths`' walk: a use node, the argument's value
        /// there, and how the path it stands for lies to the write's.
        const Mode = enum(u2) { spine, below, off };
        /// `held`: on the write's exact path below a value the class answers
        /// or lets escape (`keepAnswered`).
        /// `path`: the canonical path the route stands at in the use's place
        /// graph (`routePath`), `none` where no fold can bring it back onto the
        /// write's path.
        const Item = struct { u: NodeId, v: NodeId, mode: Mode, depth: u32, folded: bool, stuck: bool, level: bool, held: bool, path: PathId };

        /// The written positions of one write (`otherPaths`): its canonical
        /// path and the argument's nodes there.
        /// A write path that is a join of several level paths (`Place.levelPaths`)
        /// is written at each.
        const Written = struct {
            paths: std.ArrayList(PathId) = .empty,
            ends: stamped.Column(NodeId, void) = .{},
            /// The canonical cells a symbolic value above the base holds at a
            /// written position of several (`atWritten`): their `excl` is owed.
            owed: SetId = .none,
            fn holds(w: *const Written, path: PathId, v: NodeId) bool {
                return path != .none and std.mem.indexOfScalar(PathId, w.paths.items, path) != null and w.ends.contains(v);
            }
        };
        /// Where a value beside a write stands (`keepBeside`).
        const Where = struct { path: PathId, written: *Written };

        /// `next`, a child of `it` at step `s`, with the argument's value there
        /// as `positionsAt` reads a path: a missing step keeps the value
        /// reached (`along`) unless the path goes through `⟲`, where it is no
        /// position.
        pub fn advance(f: *Frame, it: Item, s: Step, next0: Item, out: *std.ArrayList(Item)) Error!void {
            var next = next0;
            next.path = try f.routePath(it.path, it.mode, s);
            if (it.stuck) {
                if (s.kind == .level) return;
                try out.append(f.gpa, next);
            } else if (s.kind == .level) {
                next.level = true;
                var frontier: std.ArrayList(NodeId) = .empty;
                defer frontier.deinit(f.gpa);
                try f.reentries(it.v, &frontier);
                for (frontier.items) |n| {
                    next.v = n;
                    try out.append(f.gpa, next);
                }
            } else if (try f.env.shapes.proj(f.gpa, f.account(), f.env.places, f.env.cells, it.v, s)) |n| {
                next.v = n;
                try out.append(f.gpa, next);
            } else if (!it.level) {
                next.stuck = true;
                try out.append(f.gpa, next);
            }
        }

        /// The canonical path a route at `from` stands at one step `s` further
        /// (`Item.path`, §2.11 item 3, *the written position*): `none` below a
        /// place on no cycle beside the write's path. `Place.extend` folds only
        /// through the places of one cycle, so no step below such a place comes
        /// back above it, onto the write's path; dropping the path there keeps
        /// the walk's states its nodes' (#1325) over doubling types.
        pub fn routePath(f: *Frame, from: PathId, mode: Mode, s: Step) Error!PathId {
            if (from == .none) return .none;
            const places = f.env.places;
            if (mode != .spine and !places.cyclic(places.pathPlace(from))) return .none;
            return (try places.extend(f.gpa, f.env.charge, from, s)) orelse .none;
        }

        /// The argument's nodes at the end of the write's path `steps` that
        /// stand at **one** position there (§2.11 item 3, *the written
        /// position*), as `otherPaths`' walk reaches them along it (`advance`):
        /// a `⟲` every re-entry below, a missing step the value reached unless
        /// past a `⟲`, and the sides of a join there. Each node counts its
        /// routes from the argument (saturating at two): a node reached by two
        /// routes, or on a knot, stands at two positions of the path, and an
        /// arrival there may be its other position, which only the class's
        /// `excl` would cover, and a callee writing one position of a folded path
        /// owes none (`writeLL`, `FoldedOnePosition`). Every route to a position
        /// at the path goes through the path's positions above it, so counting
        /// along the path counts them all.
        pub fn frontierAt(f: *Frame, v: NodeId, steps: []const Step, w: *Written) Error!void {
            const gpa = f.gpa;
            var frontier: std.ArrayList(Pos) = .empty;
            defer frontier.deinit(gpa);
            var next: std.ArrayList(Pos) = .empty;
            defer next.deinit(gpa);
            var counts: Routes = .{};
            defer counts.deinit(gpa);
            try frontier.append(gpa, .{ .n = v, .routes = 1 });
            for (steps) |s| {
                next.clearRetainingCapacity();
                if (s.kind == .level) {
                    // Every re-entry below the frontier, each node of the value
                    // below it once, its routes summed over all of them.
                    var roots: std.ArrayList(Pos) = .empty;
                    defer roots.deinit(gpa);
                    for (frontier.items) |x| if (!x.stuck) try roots.append(gpa, x);
                    try f.routesBelow(roots.items, .steps, &counts);
                    const p = if (roots.items.len == 0) null else f.env.shapes.place(roots.items[0].n);
                    for (counts.order.items) |i| {
                        const n = counts.keys.items[i];
                        if (p == null or f.env.shapes.place(n) != p.?) continue;
                        if (counts.root.items[i]) continue;
                        try next.append(gpa, .{ .n = n, .level = true, .routes = counts.get(i) });
                    }
                    std.mem.swap(std.ArrayList(Pos), &frontier, &next);
                    continue;
                }
                for (frontier.items) |x| {
                    try f.env.charge.reserve(gpa, .inspection, 1);
                    if (x.stuck) {
                        try next.append(gpa, x);
                    } else if (try f.env.shapes.proj(gpa, f.account(), f.env.places, f.env.cells, x.n, s)) |n| {
                        try next.append(gpa, .{ .n = n, .level = x.level, .routes = x.routes });
                    } else if (!x.level) try next.append(gpa, .{ .n = x.n, .stuck = true, .routes = x.routes });
                }
                std.mem.swap(std.ArrayList(Pos), &frontier, &next);
            }
            // The routes of each node there, a join's sides with their join's.
            try f.routesBelow(frontier.items, .sides, &counts);
            for (counts.order.items) |i| if (counts.get(i) == 1) try w.ends.put(gpa, counts.keys.items[i], {});
        }

        const Pos = struct { n: NodeId, level: bool = false, stuck: bool = false, routes: u8 };

        /// The nodes below some roots, each once, with its routes from them
        /// (`routesBelow`): the roots' routes carried down every edge (one per
        /// `(node, step)` or join side), summed where edges meet, two at most.
        const Routes = struct {
            index: stamped.Column(NodeId, u32) = .{},
            keys: std.ArrayList(NodeId) = .empty,
            order: std.ArrayList(u32) = .empty,
            runs: std.ArrayList([2]u32) = .empty,
            kids: std.ArrayList(u32) = .empty,
            acc: std.ArrayList(u8) = .empty,
            indeg: std.ArrayList(u32) = .empty,
            done: std.ArrayList(bool) = .empty,
            root: std.ArrayList(bool) = .empty,
            fn deinit(r: *Routes, gpa: Allocator) void {
                r.index.deinit(gpa);
                r.keys.deinit(gpa);
                r.order.deinit(gpa);
                r.runs.deinit(gpa);
                r.kids.deinit(gpa);
                r.acc.deinit(gpa);
                r.indeg.deinit(gpa);
                r.done.deinit(gpa);
                r.root.deinit(gpa);
            }
            fn clear(r: *Routes) void {
                r.index.clear();
                r.keys.clearRetainingCapacity();
                r.order.clearRetainingCapacity();
                r.runs.clearRetainingCapacity();
                r.kids.clearRetainingCapacity();
            }
            fn intern(r: *Routes, gpa: Allocator, n: NodeId) Allocator.Error!struct { index: u32, found_existing: bool } {
                const got = try r.index.getOrPut(gpa, n);
                if (!got.found_existing) {
                    got.value_ptr.* = @intCast(r.keys.items.len);
                    try r.keys.append(gpa, n);
                }
                return .{ .index = got.value_ptr.*, .found_existing = got.found_existing };
            }
            /// A node on a knot of the value is never settled: two.
            fn get(r: *const Routes, i: u32) u8 {
                return if (r.done.items[i]) r.acc.items[i] else 2;
            }
        };

        /// `out` the nodes below `roots`, by their place's steps (`.steps`, a
        /// `⟲`'s re-entries) or by a join's sides and a view's answer
        /// (`.sides`), with their routes: one walk of the value, then one pass in
        /// topological order (Kahn's). Value-sized, each node and edge once.
        pub fn routesBelow(f: *Frame, roots: []const Pos, by: enum { steps, sides }, out: *Routes) Error!void {
            const shapes = f.env.shapes;
            const places = f.env.places;
            const gpa = f.gpa;
            out.clear();
            var stack: std.ArrayList(NodeId) = .empty;
            defer stack.deinit(gpa);
            for (roots) |x| if (!(try out.intern(gpa, x.n)).found_existing) try stack.append(gpa, x.n);
            while (stack.pop()) |y| {
                const yi = out.index.get(y).?;
                try out.order.append(gpa, yi);
                const start: u32 = @intCast(out.kids.items.len);
                switch (by) {
                    .steps => for (places.steps(shapes.place(y)).steps) |c| {
                        try f.env.charge.reserve(gpa, .inspection, 1);
                        if (c.kind == .level) continue;
                        const n = (try shapes.proj(gpa, f.account(), places, f.env.cells, y, c)) orelse continue;
                        const got = try out.intern(gpa, n);
                        try out.kids.append(gpa, got.index);
                        if (!got.found_existing) try stack.append(gpa, n);
                    },
                    .sides => {
                        try f.env.charge.reserve(gpa, .inspection, 1);
                        const m = try shapes.force(gpa, f.account(), y);
                        var buf: [3]NodeId = undefined;
                        var k: usize = 0;
                        if (m != y) {
                            buf[k] = m;
                            k += 1;
                        }
                        switch (shapes.kind(m)) {
                            .@"union", .choice, .positions => {
                                buf[k] = .from(shapes.get(m).a);
                                buf[k + 1] = .from(shapes.get(m).b);
                                k += 2;
                            },
                            else => {},
                        }
                        for (buf[0..k]) |n| {
                            const got = try out.intern(gpa, n);
                            try out.kids.append(gpa, got.index);
                            if (!got.found_existing) try stack.append(gpa, n);
                        }
                    },
                }
                while (out.runs.items.len <= yi) try out.runs.append(gpa, .{ 0, 0 });
                out.runs.items[yi] = .{ start, @as(u32, @intCast(out.kids.items.len)) - start };
            }
            const n_nodes = out.keys.items.len;
            while (out.runs.items.len < n_nodes) try out.runs.append(gpa, .{ 0, 0 });
            try out.acc.resize(gpa, n_nodes);
            try out.indeg.resize(gpa, n_nodes);
            try out.done.resize(gpa, n_nodes);
            try out.root.resize(gpa, n_nodes);
            @memset(out.acc.items, 0);
            @memset(out.indeg.items, 0);
            @memset(out.done.items, false);
            @memset(out.root.items, false);
            for (out.kids.items) |k| out.indeg.items[k] += 1;
            for (roots) |x| {
                const i = out.index.get(x.n).?;
                // A root no edge reaches is no re-entry of another.
                out.root.items[i] = out.indeg.items[i] == 0;
                out.acc.items[i] = @min(2, out.acc.items[i] + x.routes);
            }
            var queue: std.ArrayList(u32) = .empty;
            defer queue.deinit(gpa);
            for (0..n_nodes) |i| if (out.indeg.items[i] == 0) try queue.append(gpa, @intCast(i));
            while (queue.pop()) |i| {
                try f.env.charge.reserve(gpa, .inspection, 1);
                out.done.items[i] = true;
                const r = out.runs.items[i];
                for (out.kids.items[r[0]..][0..r[1]]) |k| {
                    out.acc.items[k] = @min(2, out.acc.items[k] + out.acc.items[i]);
                    out.indeg.items[k] -= 1;
                    if (out.indeg.items[k] == 0) try queue.append(gpa, k);
                }
            }
        }

        /// The reach of `v`, a value beside a write at the canonical path
        /// `where.path`, but for the written positions (§2.11 item 3, *the
        /// written position*, #1253): read by position, each `(node, path)`
        /// once, a node at the write's own path that the write's path reaches
        /// skipped with what is below it, which is the written object and its
        /// contents, not another path. Where the path is dropped (`routePath`),
        /// or at a leaf, the node's whole reach. A value above the write by
        /// position though not by path prefix (the level's own list
        /// `#T.0[*]#T.0` above the lists `#T.0[*]⟲#T.0` below it) so keeps what
        /// it holds beside them only.
        pub fn reachBeside(f: *Frame, v: NodeId, where: Where) Error!SetId {
            const shapes = f.env.shapes;
            const places = f.env.places;
            const cells = f.env.cells;
            if (where.path == .none) return shapes.reach(f.gpa, f.account(), &cells.sets, v);
            const task = try f.account().enter(f.gpa, null);
            defer f.account().leave(task);
            const Fr = struct { n: NodeId, path: PathId };
            var stack: std.ArrayList(Fr) = .empty;
            defer stack.deinit(f.gpa);
            var seen: Ids.FixedDict(2) = .{};
            defer seen.deinit(f.gpa);
            var acc: SetId = .none;
            try stack.append(f.gpa, .{ .n = v, .path = where.path });
            while (stack.pop()) |fr| {
                try f.env.charge.reserve(f.gpa, .inspection, 1);
                if ((try seen.getOrPut(f.gpa, .{ fr.n.int(), fr.path.int() })).found_existing) continue;
                if (where.written.holds(fr.path, fr.n)) continue;
                const n = try shapes.force(f.gpa, f.account(), fr.n);
                switch (shapes.kind(n)) {
                    // Coexisting or alternative values at this one position.
                    .@"union", .choice, .positions => if (fr.path != .none) {
                        const d = shapes.get(n);
                        try stack.append(f.gpa, .{ .n = .from(d.a), .path = fr.path });
                        try stack.append(f.gpa, .{ .n = .from(d.b), .path = fr.path });
                        continue;
                    },
                    .node, .delta => {},
                    // A leaf, a recast (its inner read at another type, whose
                    // parts no step of this place names): whole.
                    else => {},
                }
                if (fr.path == .none or (shapes.kind(n) != .node and shapes.kind(n) != .delta)) {
                    acc = try cells.sets.unionWith(f.gpa, f.env.charge, acc, try shapes.reach(f.gpa, f.account(), &cells.sets, n));
                    continue;
                }
                acc = try cells.sets.unionWith(f.gpa, f.env.charge, acc, try shapes.cellsOf(f.gpa, f.account(), &cells.sets, n));
                for (places.steps(shapes.place(n)).steps) |s| {
                    try f.env.charge.reserve(f.gpa, .inspection, 1);
                    if (s.kind == .level) continue;
                    const c = (try shapes.proj(f.gpa, f.account(), places, cells, n, s)) orelse continue;
                    try stack.append(f.gpa, .{ .n = c, .path = try f.routePath(fr.path, .off, s) });
                }
            }
            return acc;
        }

        /// The `Beside` index of the children of `it`, a node on a write's
        /// path: the items the walk would push for them, built at the node's
        /// first visit in the call.
        pub fn spineOf(f: *Frame, bs: *Beside, it: Item) Error!u32 {
            const key: [3]u32 = .{ it.u.int(), it.v.int(), @as(u32, @intFromBool(it.stuck)) | @as(u32, @intFromBool(it.level)) << 1 };
            if (try bs.lookup(f.env, key)) |sp| return sp;
            var items: std.ArrayList(Item) = .empty;
            defer items.deinit(f.gpa);
            var kids: std.ArrayList(Beside.Kid) = .empty;
            defer kids.deinit(f.gpa);
            var kt = f.env.shapes.overEntries(f.env.shapes.get(it.u).a);
            while (kt.next()) |k| {
                items.clearRetainingCapacity();
                var next = it;
                next.u = k.node;
                try f.advance(it, k.step, next, &items);
                for (items.items) |x| try kids.append(f.gpa, .{ .step = k.step, .u = x.u, .v = x.v, .stuck = x.stuck, .level = x.level });
            }
            return bs.add(f.env, key, kids.items);
        }

        /// A child of a node on the write's path, off it unless at its step.
        pub fn pushOff(f: *Frame, k: Beside.Kid, on: Step, folded: bool, from: PathId, out: *std.ArrayList(Item)) Error!void {
            if (k.step.word() == on.word()) return;
            try out.append(f.gpa, .{ .u = k.u, .v = k.v, .mode = .off, .depth = 0, .folded = folded, .stuck = k.stuck, .level = k.level, .held = false, .path = try f.routePath(from, .spine, k.step) });
        }

        /// The cells of `v` beside the base that may be one of its objects,
        /// added to `kept`, its folded parameter cells to `excl`: a parameter's
        /// cell the base does not reach is another path of this frame's
        /// parameter, distinct here; one it reaches at a path through `[*]` or
        /// `⟲`, where two paths fold through one leaf, is owed as `excl`
        /// (§2.11 item 3 (c)). Any other cell is kept when its alias key is one
        /// of the base's (`want`), read from `v`'s reach by key (`Beside.keyed`),
        /// never cell by cell.
        /// The approximation bit of a cell of `reach` that holds the base's
        /// canonical cell `cu`, null for none, each read at its own canonical
        /// cell: a pattern refines what it binds (`x` of `Pair _ x`), and a
        /// refinement is its canonical cell's object (#1385). It is `cu` itself,
        /// or, for a value the class answers, lets escape or reads deeply (a leaf
        /// use, or `D`), a parameter cell that `cu` is strictly below
        /// (`Cell.below`: a trie ancestor, or levels through `⟲`). What a callee
        /// relied on when it found two paths of one parameter apart, discharged
        /// here (§2.11 item 3, rule (c), #1383).
        /// With `rest`, `reach` is a leaf on the write's exact path whose
        /// position is `rest` above the base's (`keepAnswered`): a cell whose
        /// position `rest` below is `cu` holds the written object as the
        /// object itself there, and its other paths are distinct objects of
        /// this frame (rule (c)), so it holds nothing beside the write (#1367).
        pub fn holdsCanonical(f: *Frame, reach: SetId, cu: CellId, held: bool, rest: ?[]const Step, refs: []const CellId, where: ?Where) Error!?u1 {
            const cells = f.env.cells;
            var it = cells.sets.iterate(reach);
            while (it.next()) |e| {
                try f.env.charge.reserve(f.gpa, .inspection, 1);
                const d: CellId = .from(e.key);
                if (cells.origin(cells.base(d)) != .param) continue;
                // Another side of a split the write's path met is apart from
                // the base under the split's κ, which `splitBeside` relies on
                // (#1386), though its canonical cell is the base's.
                if (try f.otherSide(d, refs)) continue;
                const du = (try cells.unrefined(f.gpa, f.account(), f.env.places, d)) orelse continue;
                if (rest) |r| if (try f.pathBelow(du, r, cu)) continue;
                if (du == cu) return @intCast(e.value);
                if (held and cells.below(f.env.places, cu, du) and !(try f.atWritten(where, du, cu))) return @intCast(e.value);
            }
            return null;
        }

        /// Whether the symbolic cell `c` is `d`'s position `steps` below it.
        pub fn pathBelow(f: *Frame, d: CellId, steps: []const Step, c: CellId) Error!bool {
            if (steps.len == 0) return false;
            const cells = f.env.cells;
            const x = cells.get(d);
            const y = cells.get(c);
            if (x.origin != y.origin or !x.origin.isSymbolic() or x.origin == .top or x.a != y.a or x.c != y.c) return false;
            var p: PathId = .from(x.b);
            for (steps) |s| p = (try f.env.places.extend(f.gpa, f.env.charge, p, s)) orelse return false;
            return p == PathId.from(y.b);
        }

        /// What a value on the write's exact path that the class answers or
        /// lets escape, or that is below one, holds beside the written object
        /// (§2.11 item 3, rule (a), #1367). A node: its own cells and its
        /// children off the path (`rest`'s first step), each wholly; the child
        /// on the path is read at the path's next node, and the written object
        /// at its end is the object written, not a second one. A leaf: as
        /// `holdsCanonical` reads it with `rest`. A choice or a union: each
        /// arm, its projections being the arms' (§2.3). Any other value whole.
        pub fn keepAnswered(f: *Frame, bs: *Beside, want: *const Want, v0: NodeId, rest: []const Step, folded: bool, refs: []const CellId, kept: *SetId, excl: *SetId, relied: *CondId) Error!void {
            const shapes = f.env.shapes;
            var stack: std.ArrayList(NodeId) = .empty;
            defer stack.deinit(f.gpa);
            var seen: Ids.FixedDict(1) = .{};
            defer seen.deinit(f.gpa);
            try stack.append(f.gpa, v0);
            while (stack.pop()) |x| {
                try f.env.charge.reserve(f.gpa, .inspection, 1);
                const v = try shapes.force(f.gpa, f.account(), x);
                if ((try seen.getOrPut(f.gpa, .{v.int()})).found_existing) continue;
                const d = shapes.get(v);
                switch (d.kind) {
                    .node => {
                        if (d.cells != .none) try f.keepBeside(bs, want, try shapes.leaf(f.gpa, f.account(), d.place, d.cells), folded, true, null, refs, kept, excl, relied, null);
                        var kt = shapes.overEntries(d.a);
                        while (kt.next()) |k| if (k.step.word() != rest[0].word())
                            try f.keepBeside(bs, want, k.node, folded, true, null, refs, kept, excl, relied, null);
                    },
                    .choice, .@"union" => try stack.appendSlice(f.gpa, &.{ .from(d.a), .from(d.b) }),
                    .leaf => try f.keepBeside(bs, want, v, folded, true, rest, refs, kept, excl, relied, null),
                    else => try f.keepBeside(bs, want, v, folded, true, null, refs, kept, excl, relied, null),
                }
            }
        }

        /// `keepBeside`: a refinement of `v` whose canonical position holds
        /// the base's is another position of a split the write's path met
        /// (`refs`), apart from the base only under that split's κ (§2.2's
        /// `under`, §2.11 item 3 (c)): `[ a, c ]`'s `a` beside a write into `c` is `c[*]` beside
        /// `c[*]`, one summary path, so the write relies on the split's κ —
        /// `excl` of a parameter's elements — into `relied`, and from the
        /// demand into the class's `xreq` (step 7). The same position holds
        /// the base's object: its cell is kept.
        pub fn keepBeside(f: *Frame, bs: *Beside, want: *const Want, v: NodeId, folded: bool, held: bool, rest: ?[]const Step, refs: []const CellId, kept: *SetId, excl: *SetId, relied: *CondId, where: ?Where) Error!void {
            const cells = f.env.cells;
            const reach = if (where) |w| try f.reachBeside(v, w) else try f.env.shapes.reach(f.gpa, f.account(), &cells.sets, v);
            if (refs.len != 0) try f.splitBeside(want, reach, refs, folded, kept, excl, relied, where);
            for (want.params.items) |c| {
                try f.env.charge.reserve(f.gpa, .inspection, 1);
                // The base's cell, or its canonical cell when a pattern refined it
                // (`ys` of `Br _ ys _`); and a held value whose parameter cell is
                // above the base's holds it, a symbolic leaf's reach being its own
                // cell (#1383).
                const cu = (try cells.unrefined(f.gpa, f.account(), f.env.places, c)) orelse c;
                const value = cells.sets.get(reach, c.int()) orelse cells.sets.get(reach, cu.int()) orelse try f.holdsCanonical(reach, cu, held, rest, refs, where) orelse continue;
                // Two paths folding through one leaf at a summary path: the
                // parameter's, or a part's canonical one (§2.2 *Parts*), owed as
                // `excl` of the canonical cell.
                if (folded and cells.origin(cu) == .param and try f.summaryPath(.from(cells.get(cu).b))) {
                    excl.* = try cells.sets.insert(f.gpa, f.env.charge, excl.*, cu.int(), 0);
                    continue;
                }
                kept.* = try cells.sets.insert(f.gpa, f.env.charge, kept.*, c.int(), value);
            }
            if (want.all) {
                var it = cells.sets.iterate(reach);
                while (it.next()) |e| {
                    try f.env.charge.reserve(f.gpa, .inspection, 1);
                    if (cells.origin(cells.base(.from(e.key))) == .param) continue;
                    kept.* = try cells.sets.insert(f.gpa, f.env.charge, kept.*, e.key, e.value);
                }
                return;
            }
            for (want.keys.items) |k| {
                if (k[0] == key_param or k[0] == key_always or k[0] == key_param_leaf) continue;
                try f.env.charge.reserve(f.gpa, .inspection, 1);
                const s = try bs.keyed(f.env, reach, k);
                if (s != .none) kept.* = try cells.sets.unionWith(f.gpa, f.env.charge, kept.*, s);
            }
        }

        /// The refinement cells of the argument `v` at each node of the write's
        /// path `ws` up to its first `[*]` or `⟲` (`otherPaths`): past one, the
        /// path stands for several positions.
        pub fn spineRefinements(f: *Frame, v: NodeId, ws: []const Step, out: *std.ArrayList(CellId)) Error!void {
            const shapes = f.env.shapes;
            const cells = f.env.cells;
            var at = v;
            var i: usize = 0;
            while (true) : (i += 1) {
                try f.env.charge.reserve(f.gpa, .inspection, 1);
                at = try shapes.force(f.gpa, f.account(), at);
                var it = cells.sets.iterate(try shapes.cellsOf(f.gpa, f.account(), &cells.sets, at));
                while (it.next()) |e| {
                    try f.env.charge.reserve(f.gpa, .inspection, 1);
                    if (cells.origin(.from(e.key)).isRefinement()) try out.append(f.gpa, .from(e.key));
                }
                if (i == ws.len or ws[i].kind == .elem or ws[i].kind == .level) return;
                at = (try shapes.proj(f.gpa, f.account(), f.env.places, cells, at, ws[i])) orelse return;
            }
        }

        /// Whether the refinement `d` is on another side of a split one of
        /// `refs` is on, and on no `refs`' own side (`Cell.alias`).
        pub fn otherSide(f: *Frame, d: CellId, refs: []const CellId) Error!bool {
            const cells = f.env.cells;
            if (!cells.origin(d).isRefinement()) return false;
            var other = false;
            for (refs) |r| {
                try f.env.charge.reserve(f.gpa, .inspection, 1);
                if (cells.base(r) != cells.base(d)) continue;
                switch (cells.alias(f.env.places, d, r)) {
                    .yes => return false,
                    .under, .under_kappa => other = true,
                    .no => {},
                }
            }
            return other;
        }

        /// `keepBeside`'s refinements: each refinement `d` of `reach` whose
        /// canonical position is at or above a parameter cell of the base,
        /// against each refinement `r` of one base the write's path met: a
        /// side of `r`'s split relies on its κ, `r` itself keeps the base's
        /// cell (`Cell.alias`).
        /// Whether `cu`, the base's canonical cell below `du`, the canonical cell
        /// of a value beside the write at `where.path`, is that value's object at
        /// the written position itself (§2.11 item 3, *the written position*,
        /// #1253): the steps from `du`'s path down to `cu`'s, taken from the
        /// value's path, land on the write's path. The value holds the written
        /// object there, not at another path: in `T = T (List T)` an element of
        /// the level's list `[*]#T.0[*]` holds the lists `[*]#T.0⟲` below it.
        pub fn atWritten(f: *Frame, where: ?Where, du: CellId, cu: CellId) Error!bool {
            const w = where orelse return false;
            if (w.path == .none) return false;
            const cells = f.env.cells;
            const places = f.env.places;
            const x = cells.get(du);
            const y = cells.get(cu);
            if (x.origin != y.origin or !x.origin.isSymbolic() or x.origin == .top or x.a != y.a or x.c != y.c) return false;
            const top: PathId = .from(x.b);
            const bottom: PathId = .from(y.b);
            if (!places.isPrefix(top, bottom) or top == bottom) return false;
            var steps: std.ArrayList(Step) = .empty;
            defer steps.deinit(f.gpa);
            var at = bottom;
            while (at != top) : (at = places.pathParent(at)) {
                try f.env.charge.reserve(f.gpa, .path, 1);
                try steps.append(f.gpa, places.pathStep(at));
            }
            var p = w.path;
            var i = steps.items.len;
            while (i > 0) {
                i -= 1;
                p = (try places.extend(f.gpa, f.env.charge, p, steps.items[i])) orelse return false;
            }
            if (std.mem.indexOfScalar(PathId, w.written.paths.items, p) == null) return false;
            // At a path of several positions the value's object there is the
            // written one only if they hold distinct objects: owed upward.
            if (places.isSummary(bottom)) w.written.owed = try cells.sets.insert(f.gpa, f.env.charge, w.written.owed, cu.int(), 0);
            return true;
        }
        pub fn splitBeside(f: *Frame, want: *const Want, reach: SetId, refs: []const CellId, folded: bool, kept: *SetId, excl: *SetId, relied: *CondId, where: ?Where) Error!void {
            const cells = f.env.cells;
            const places = f.env.places;
            var it = cells.sets.iterate(reach);
            while (it.next()) |e| {
                try f.env.charge.reserve(f.gpa, .inspection, 1);
                const d: CellId = .from(e.key);
                if (!cells.origin(d).isRefinement()) continue;
                const db = cells.base(d);
                const du = (try cells.unrefined(f.gpa, f.account(), places, d)) orelse continue;
                const dp = cells.get(du);
                for (want.params.items) |c| {
                    try f.env.charge.reserve(f.gpa, .inspection, 1);
                    const cu = (try cells.unrefined(f.gpa, f.account(), places, c)) orelse c;
                    const cp = cells.get(cu);
                    if (cp.a != dp.a or !places.isPrefix(.from(dp.b), .from(cp.b))) continue;
                    if (try f.atWritten(where, du, cu)) continue;
                    for (refs) |r| {
                        try f.env.charge.reserve(f.gpa, .inspection, 1);
                        if (cells.base(r) != db) continue;
                        switch (cells.alias(places, d, r)) {
                            .no => {},
                            // Met again in a fold through one leaf: `excl` (§2.2).
                            .yes => if (folded and cp.origin == .param and try f.summaryPath(.from(cp.b))) {
                                excl.* = try cells.sets.insert(f.gpa, f.env.charge, excl.*, cu.int(), 0);
                            } else {
                                kept.* = try cells.sets.insert(f.gpa, f.env.charge, kept.*, c.int(), e.value);
                            },
                            .under => |s| {
                                const k = cells.splitOf(s).cond;
                                relied.* = try f.env.conds.@"and"(f.gpa, f.env.charge, relied.*, if (k == .none) Cond.lost else k);
                            },
                            .under_kappa => relied.* = Cond.lost,
                        }
                    }
                }
            }
        }

        /// What a write's base may be (`otherPaths`): its alias keys, and its
        /// parameter cells.
        const Want = struct {
            /// The base holds `⊤`: any cell may be it.
            all: bool = false,
            /// A parameter cell of the base with no canonical position: every
            /// parameter leaf beside it is looked at, as `unreached` does.
            any_param_leaf: bool = false,
            keys: std.ArrayList([4]u32) = .empty,
            params: std.ArrayList(CellId) = .empty,

            fn deinit(w: *Want, gpa: Allocator) void {
                w.keys.deinit(gpa);
                w.params.deinit(gpa);
            }
        };

        /// Whether `v` is a leaf of parameter cells none of whose positions the
        /// base reaches (`own`): every cell at or below it is a parameter's
        /// (a symbolic cell projects to a symbolic cell of its origin, §2.2),
        /// and `keepBeside` keeps none of them.
        pub fn unreached(f: *Frame, v: NodeId, own: SetId) Error!bool {
            const shapes = f.env.shapes;
            const cells = f.env.cells;
            const places = f.env.places;
            const n = try shapes.force(f.gpa, f.account(), v);
            if (shapes.kind(n) != .leaf) return false;
            var it = cells.sets.iterate(try shapes.cellsOf(f.gpa, f.account(), &cells.sets, n));
            while (it.next()) |e| {
                try f.env.charge.reserve(f.gpa, .inspection, 1);
                const c: CellId = .from(e.key);
                if (cells.origin(cells.base(c)) != .param) return false;
                const at = (try cells.unrefined(f.gpa, f.account(), places, c)) orelse return false;
                const p = cells.get(at);
                var ot = cells.sets.iterate(own);
                while (ot.next()) |o| {
                    try f.env.charge.reserve(f.gpa, .inspection, 1);
                    const oc: CellId = .from(o.key);
                    if (cells.origin(cells.base(oc)) != .param) continue;
                    const oat = (try cells.unrefined(f.gpa, f.account(), places, oc)) orelse return false;
                    const op = cells.get(oat);
                    if (op.a == p.a and places.isPrefix(.from(p.b), .from(op.b))) return false;
                }
            }
            return true;
        }

        /// How many exact steps of `steps` read `v` before a leaf, when the path meets
        /// one (null when it does not): every position below is then a symbolic
        /// cell's projection, not a cell a built value holds.
        pub fn leafDepth(f: *Frame, v: Value, steps: []const Step) Error!?usize {
            const shapes = f.env.shapes;
            var at = v.node;
            for (steps, 0..) |s, i| {
                try f.env.charge.reserve(f.gpa, .inspection, 1);
                // A view is its answer here (§2.11).
                at = try shapes.force(f.gpa, f.account(), at);
                if (shapes.kind(at) == .leaf) return i;
                // A `[*]` or `⟲` before the leaf stands for many positions: the
                // shared prefix does not prove both paths reach the same one.
                if (s.kind == .level or s.kind == .elem) return null;
                at = (try shapes.proj(f.gpa, f.account(), f.env.places, f.env.cells, at, s)) orelse return null;
            }
            return null;
        }

        /// The argument `v` at a class's parameter path `steps`: every position
        /// the path stands for, joined (alternatives at one path). A `⟲` step
        /// stands for every re-entry of the recursive place below the value so
        /// far, at any depth (§2.2's canonical paths): each node reached by one
        /// step or more whose place is that one. A walk of the value, growth
        /// chosen before it (§4.1). Null when no position is left.
        pub fn positionsAt(f: *Frame, v: Value, steps: []const Step) Error!?Value {
            var has_level = false;
            for (steps) |s| has_level = has_level or s.kind == .level;
            if (!has_level) return try f.along(v, steps);
            const n = (try Calls.positionsAt(f.env, v.node, steps)) orelse return null;
            return .{ .node = n };
        }

        /// Whether a path goes through `[*]` or `⟲`: it names several positions.
        pub fn summaryPath(f: *Frame, p: PathId) Error!bool {
            const places = f.env.places;
            var at = p;
            while (at != .none and places.pathParent(at) != .none) : (at = places.pathParent(at)) {
                try f.env.charge.reserve(f.gpa, .inspection, 1);
                const k = places.pathStep(at).kind;
                if (k == .elem or k == .level) return true;
            }
            return false;
        }
        pub fn along(f: *Frame, v: Value, steps: []const Step) Error!Value {
            var at = v;
            for (steps) |s| {
                const n = (try f.env.shapes.proj(f.gpa, f.account(), f.env.places, f.env.cells, at.node, s)) orelse return at;
                at = .{ .node = n, .kappa = f.env.conds.kappaChild(at.kappa, s) };
            }
            return at;
        }
    };
}
