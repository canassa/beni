//! L10: the runs of a write's other-paths walk (`docs/design/ownership-v2.md`
//! §2.11 item 3, *a choice's arms*, #1439): a choice on the write's exact
//! prefix is one arm per run (§2.9), and what an item keeps beside the write
//! is another path only of a base met in one of its runs (`Arms`); the
//! whole argument's nodes on the write's path, whose children's keys an
//! arm's node reads (`Synthetic`); the written positions counted per run
//! (`frontierMax`, `routesMax`); and the walk's reads and re-entries one
//! node at a time, so that what arms share is met once (`readStep`,
//! `expandOne`). `Of(Frame)` is this part's methods over the frame
//! `Transfer.zig` declares; `Transfer.zig` binds them by name (§5). It
//! calls `TransferFrame` and `TransferBeside`.
//!
//! Obligations kept here: none of §2.14's directly; it narrows §2.11 item
//! 3's other-paths operand to the runs that may hold it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const stamped = @import("../stamped.zig");
const Place = @import("Place.zig");
const Calls = @import("Calls.zig");
const NodeId = Ids.NodeId;
const CellId = Ids.CellId;
const SetId = Ids.SetId;
const PathId = Ids.PathId;
const Beside = Calls.Beside;
const aliasKey = Calls.aliasKey;
const key_top = Calls.key_top;
const Step = Place.Step;
const Error = Ids.ChargeError;
const none: u32 = Ids.none_int;

/// The part of `Transfer.Frame` this file holds, over the frame `Transfer.zig` declares.
pub fn Of(comptime Frame: type) type {
    return struct {
        const Item = Frame.BesideItem;
        const Push = Frame.BesidePush;
        const Written = Frame.BesideWritten;
        const Want = Frame.BesideWant;

        /// The runs of a write's walk (`otherPaths`, #1439). A choice on the
        /// write's exact prefix is one arm per run (§2.9). The walk is a graph
        /// of its items and reads (each once, whatever arm meets it), and each
        /// node runs in the arms whose routes reach it: arm 0, the whole
        /// argument's, above every split. What a node keeps beside the write
        /// is another path only of a base met in a run it is in too: an arm,
        /// one of its parents, or one of its own arms.
        pub const Arms = struct {
            kept: std.ArrayList(SetId) = .empty,
            sets: std.ArrayList(SetId) = .empty,
            edges: std.ArrayList([3]u32) = .empty,
            ids: Ids.FixedDict(2) = .{},
            parents: std.ArrayList(SetId) = .empty,
            /// The ends of the write's path met: `(node, value)`.
            ends: std.ArrayList([2]u32) = .empty,
            /// Every node's cells are kept whatever runs it is in.
            whole: bool = false,
            pub fn deinit(a: *Arms, gpa: Allocator) void {
                a.kept.deinit(gpa);
                a.sets.deinit(gpa);
                a.edges.deinit(gpa);
                a.ids.deinit(gpa);
                a.parents.deinit(gpa);
                a.ends.deinit(gpa);
            }
            pub fn node(a: *Arms, gpa: Allocator) Allocator.Error!u32 {
                try a.kept.append(gpa, .none);
                try a.sets.append(gpa, .none);
                return @intCast(a.kept.items.len - 1);
            }
            pub fn edge(a: *Arms, gpa: Allocator, from: u32, to: u32, arm: u32) Allocator.Error!void {
                if (from != none) try a.edges.append(gpa, .{ from, to, arm });
            }
            /// The arm of `side`, a side of a choice met at `depth`.
            pub fn armOf(a: *Arms, gpa: Allocator, side: NodeId, depth: u32) Allocator.Error!u32 {
                const got = try a.ids.getOrPut(gpa, .{ side.int(), depth });
                if (!got.found_existing) {
                    try a.parents.append(gpa, .none);
                    got.value_ptr.* = @intCast(a.parents.items.len);
                }
                return got.value_ptr.*;
            }
            /// The node of a read of key `key` by node `by`: new (to read now)
            /// or null, and an edge from `by` either way.
            pub fn read(a: *Arms, gpa: Allocator, dict: *Ids.FixedDict(5), key: [5]u32, by: u32) Allocator.Error!?u32 {
                const got = try dict.getOrPut(gpa, key);
                if (got.found_existing) {
                    try a.edge(gpa, by, got.value_ptr.*, none);
                    return null;
                }
                const n = try a.node(gpa);
                got.value_ptr.* = n;
                try a.edge(gpa, by, n, none);
                return n;
            }

            /// Each node's arms: the union over its incoming edges of the
            /// arm an edge starts, or its source's arms, per strongly
            /// connected component in topological order (Tarjan's, one pass).
            fn propagate(a: *Arms, f: *Frame) Error!void {
                const gpa = f.gpa;
                const sets = &f.env.cells.sets;
                const n: u32 = @intCast(a.kept.items.len);
                // Out-edges and in-edges, by node.
                var out_start = try gpa.alloc(u32, n + 1);
                defer gpa.free(out_start);
                var in_start = try gpa.alloc(u32, n + 1);
                defer gpa.free(in_start);
                @memset(out_start, 0);
                @memset(in_start, 0);
                for (a.edges.items) |e| {
                    out_start[e[0] + 1] += 1;
                    in_start[e[1] + 1] += 1;
                }
                for (1..n + 1) |i| {
                    out_start[i] += out_start[i - 1];
                    in_start[i] += in_start[i - 1];
                }
                const outs = try gpa.alloc(u32, a.edges.items.len);
                defer gpa.free(outs);
                const ins = try gpa.alloc(u32, a.edges.items.len);
                defer gpa.free(ins);
                {
                    const op = try gpa.dupe(u32, out_start[0..n]);
                    defer gpa.free(op);
                    const ip = try gpa.dupe(u32, in_start[0..n]);
                    defer gpa.free(ip);
                    for (a.edges.items, 0..) |e, i| {
                        outs[op[e[0]]] = e[1];
                        op[e[0]] += 1;
                        ins[ip[e[1]]] = @intCast(i);
                        ip[e[1]] += 1;
                    }
                }
                // Tarjan's components, iteratively.
                const index = try gpa.alloc(u32, n);
                defer gpa.free(index);
                const low = try gpa.alloc(u32, n);
                defer gpa.free(low);
                const on = try gpa.alloc(bool, n);
                defer gpa.free(on);
                const comp = try gpa.alloc(u32, n);
                defer gpa.free(comp);
                @memset(index, none);
                @memset(on, false);
                var tstack: std.ArrayList(u32) = .empty;
                defer tstack.deinit(gpa);
                var call: std.ArrayList([2]u32) = .empty;
                defer call.deinit(gpa);
                var order: std.ArrayList(u32) = .empty; // components' nodes, in emission order
                defer order.deinit(gpa);
                var bounds: std.ArrayList(u32) = .empty;
                defer bounds.deinit(gpa);
                var counter: u32 = 0;
                for (0..n) |s0| {
                    if (index[s0] != none) continue;
                    try call.append(gpa, .{ @intCast(s0), out_start[s0] });
                    index[s0] = counter;
                    low[s0] = counter;
                    counter += 1;
                    try tstack.append(gpa, @intCast(s0));
                    on[s0] = true;
                    while (call.items.len != 0) {
                        try f.env.charge.reserve(gpa, .inspection, 1);
                        const top = &call.items[call.items.len - 1];
                        const v = top[0];
                        if (top[1] < out_start[v + 1]) {
                            const w = outs[top[1]];
                            top[1] += 1;
                            if (index[w] == none) {
                                index[w] = counter;
                                low[w] = counter;
                                counter += 1;
                                try tstack.append(gpa, w);
                                on[w] = true;
                                try call.append(gpa, .{ w, out_start[w] });
                            } else if (on[w]) low[v] = @min(low[v], index[w]);
                            continue;
                        }
                        _ = call.pop();
                        if (call.items.len != 0) {
                            const u = call.items[call.items.len - 1][0];
                            low[u] = @min(low[u], low[v]);
                        }
                        if (low[v] == index[v]) {
                            try bounds.append(gpa, @intCast(order.items.len));
                            const id: u32 = @intCast(bounds.items.len - 1);
                            while (true) {
                                const w = tstack.pop().?;
                                on[w] = false;
                                comp[w] = id;
                                try order.append(gpa, w);
                                if (w == v) break;
                            }
                        }
                    }
                }
                try bounds.append(gpa, @intCast(order.items.len));
                // Emission order is reverse topological: walk it backwards.
                var ci = bounds.items.len - 1;
                while (ci > 0) {
                    ci -= 1;
                    const members = order.items[bounds.items[ci]..bounds.items[ci + 1]];
                    var s: SetId = .none;
                    for (members) |m| {
                        if (m == 0) s = try sets.insert(gpa, f.env.charge, s, 0, 0);
                        for (ins[in_start[m]..in_start[m + 1]]) |ei| {
                            try f.env.charge.reserve(gpa, .inspection, 1);
                            const e = a.edges.items[ei];
                            if (e[2] != none) {
                                s = try sets.insert(gpa, f.env.charge, s, e[2], 0);
                            } else if (comp[e[0]] != ci) s = try sets.unionWith(gpa, f.env.charge, s, a.sets.items[e[0]]);
                        }
                    }
                    for (members) |m| a.sets.items[m] = s;
                }
                // An arm's parents: the arms of the choices it is a side of.
                for (a.edges.items) |e| if (e[2] != none) {
                    a.parents.items[e[2] - 1] = try sets.unionWith(gpa, f.env.charge, a.parents.items[e[2] - 1], a.sets.items[e[0]]);
                };
            }

            /// The runs of the ends of the write's path whose reach holds the
            /// parameter cell `c` (`keptAll`), once per cell.
            fn paramRuns(a: *const Arms, f: *Frame, c: CellId, memo: *Ids.FixedDict(1)) Error!SetId {
                if (memo.get(.{c.int()})) |v| return .from(v);
                const sets = &f.env.cells.sets;
                var r: SetId = .none;
                for (a.ends.items) |e| {
                    try f.env.charge.reserve(f.gpa, .inspection, 1);
                    if (!sets.member(try f.env.shapes.reach(f.gpa, f.account(), sets, .from(e[1])), c.int())) continue;
                    r = try sets.unionWith(f.gpa, f.env.charge, r, a.sets.items[e[0]]);
                }
                (try memo.getOrPut(f.gpa, .{c.int()})).value_ptr.* = r.int();
                return r;
            }

            /// `s` with every arm's parents, and arm 0.
            fn closure(a: *const Arms, f: *Frame, s0: SetId) Error!SetId {
                const sets = &f.env.cells.sets;
                var s = try sets.insert(f.gpa, f.env.charge, s0, 0, 0);
                var work: std.ArrayList(u32) = .empty;
                defer work.deinit(f.gpa);
                var it = sets.iterate(s0);
                while (it.next()) |e| try work.append(f.gpa, e.key);
                while (work.pop()) |x| {
                    if (x == 0) continue;
                    var pt = sets.iterate(a.parents.items[x - 1]);
                    while (pt.next()) |e| {
                        try f.env.charge.reserve(f.gpa, .inspection, 1);
                        if (sets.member(s, e.key)) continue;
                        s = try sets.insert(f.gpa, f.env.charge, s, e.key, 0);
                        try work.append(f.gpa, e.key);
                    }
                }
                return s;
            }

            /// What every node keeps: a cell of another path only where its
            /// key is a base's in a run the node is in too (one set of arms
            /// the other's closure meets); a parameter's or a `⊤` cell always.
            pub fn keptAll(a: *Arms, f: *Frame) Error!SetId {
                const gpa = f.gpa;
                const cells = f.env.cells;
                const sets = &cells.sets;
                var kept: SetId = .none;
                if (a.whole) {
                    for (a.kept.items) |k| kept = try sets.unionWith(gpa, f.env.charge, kept, k);
                    return kept;
                }
                try a.propagate(f);
                // The runs of each base key.
                var based: Ids.FixedDict(4) = .{};
                defer based.deinit(gpa);
                for (a.ends.items) |e| {
                    var it = sets.iterate(try f.env.shapes.cellsOf(gpa, f.account(), &cells.sets, .from(e[1])));
                    while (it.next()) |x| {
                        try f.env.charge.reserve(gpa, .inspection, 1);
                        const c: CellId = .from(x.key);
                        if (cells.origin(cells.base(c)) == .param) continue;
                        const k = aliasKey(cells, c);
                        if (k[0] == key_top) {
                            a.whole = true;
                            for (a.kept.items) |kk| kept = try sets.unionWith(gpa, f.env.charge, kept, kk);
                            return kept;
                        }
                        const got = try based.getOrPut(gpa, k);
                        const prev: SetId = if (got.found_existing) .from(got.value_ptr.*) else .none;
                        got.value_ptr.* = (try sets.unionWith(gpa, f.env.charge, prev, a.sets.items[e[0]])).int();
                    }
                }
                // The nodes' cells, by their set of arms.
                var groups: Ids.FixedDict(1) = .{};
                defer groups.deinit(gpa);
                var gk: std.ArrayList([2]SetId) = .empty;
                defer gk.deinit(gpa);
                for (a.kept.items, a.sets.items) |k, s| {
                    if (k == .none) continue;
                    const got = try groups.getOrPut(gpa, .{s.int()});
                    if (!got.found_existing) {
                        got.value_ptr.* = @intCast(gk.items.len);
                        try gk.append(gpa, .{ s, .none });
                    }
                    const g = &gk.items[got.value_ptr.*];
                    g[1] = try sets.unionWith(gpa, f.env.charge, g[1], k);
                }
                var closed: Ids.FixedDict(1) = .{};
                defer closed.deinit(gpa);
                var by_param: Ids.FixedDict(1) = .{};
                defer by_param.deinit(gpa);
                for (gk.items) |g| {
                    const cs = try a.closure(f, g[0]);
                    var it = sets.iterate(g[1]);
                    while (it.next()) |x| {
                        try f.env.charge.reserve(gpa, .inspection, 1);
                        const c: CellId = .from(x.key);
                        const k = aliasKey(cells, c);
                        if (k[0] != key_top) {
                            // A parameter's cell is the base's where an end
                            // reaches it; any other cell, by its key.
                            const r: SetId = if (cells.origin(cells.base(c)) == .param) try a.paramRuns(f, c, &by_param) else .from(based.get(k) orelse continue);
                            if (r == .none) continue;
                            const cr = blk: {
                                if (closed.get(.{r.int()})) |v| break :blk SetId.from(v);
                                const v = try a.closure(f, r);
                                (try closed.getOrPut(gpa, .{r.int()})).value_ptr.* = v.int();
                                break :blk v;
                            };
                            if (!(try sets.intersects(gpa, f.env.charge, g[0], cr)) and !(try sets.intersects(gpa, f.env.charge, r, cs))) continue;
                        }
                        kept = try sets.insert(gpa, f.env.charge, kept, x.key, x.value);
                    }
                }
                return kept;
            }
        };

        /// The whole argument's nodes on the write's path above its first `⟲`
        /// (`otherPaths`): one per depth, as the walk reaches them with no
        /// choice split, and per depth the steps of its children that hold a
        /// cell of the base (`steps`), from its `Beside` index.
        pub const Synthetic = struct {
            nodes: std.ArrayList(Item) = .empty,
            list: std.ArrayList(Step) = .empty,
            ranges: std.ArrayList(?[2]u32) = .empty,
            pub fn deinit(s: *Synthetic, gpa: Allocator) void {
                s.nodes.deinit(gpa);
                s.list.deinit(gpa);
                s.ranges.deinit(gpa);
            }
            /// The steps to read `it`'s children at, for a node of the
            /// write's path above its first `⟲` that is not the whole
            /// argument's own (an arm's, or a part of one): those where the
            /// whole argument's children hold a cell of the base. An arm's
            /// value there is a part of the whole argument's, so its other
            /// children hold none. Null for the whole argument's own node, or
            /// a stuck one: read by its own index.
            pub fn steps(s: *Synthetic, f: *Frame, bs: *Beside, want: *const Want, it: Item) Error!?[]const Step {
                if (it.depth >= s.nodes.items.len or it.stuck or it.level) return null;
                const n = s.nodes.items[it.depth];
                if (n.u == it.u and n.v == it.v and n.stuck == it.stuck) return null;
                if (n.u != it.u) return null;
                if (s.ranges.items[it.depth] == null) {
                    const start: u32 = @intCast(s.list.items.len);
                    const sp = try f.spineOf(bs, n);
                    const r = bs.ranges.items[sp];
                    if (want.all) {
                        for (bs.kids.items[r[0]..][0..r[1]]) |k| try s.add(f.gpa, start, k.step);
                    } else for (want.keys.items) |k| {
                        var link = bs.head(sp, k);
                        while (link != none) : (link = bs.links.items[link][1]) {
                            try f.env.charge.reserve(f.gpa, .inspection, 1);
                            try s.add(f.gpa, start, bs.kids.items[bs.links.items[link][0]].step);
                        }
                    }
                    s.ranges.items[it.depth] = .{ start, @as(u32, @intCast(s.list.items.len)) - start };
                }
                const r = s.ranges.items[it.depth].?;
                return s.list.items[r[0]..][0..r[1]];
            }
            /// Whether the write's exact prefix meets a choice.
            pub fn split(s: *const Synthetic, f: *Frame, exact_to: usize) Error!bool {
                for (s.nodes.items, 0..) |n, d| {
                    if (d > exact_to or n.stuck) break;
                    if (f.env.shapes.kind(try f.env.shapes.force(f.gpa, f.account(), n.v)) == .choice) return true;
                }
                return false;
            }
            fn add(s: *Synthetic, gpa: Allocator, start: u32, step: Step) Allocator.Error!void {
                for (s.list.items[start..]) |x| if (x.word() == step.word()) return;
                try s.list.append(gpa, step);
            }
        };

        /// `syn` the whole argument `v`'s nodes along `ws` above its first
        /// `⟲`, from the use `use`, as `advance` reaches them.
        pub fn synthetic(f: *Frame, use: NodeId, v: NodeId, ws: []const Step, syn: *Synthetic) Error!void {
            const shapes = f.env.shapes;
            var u = use;
            var at = v;
            var stuck = false;
            for (ws, 0..) |s, d| {
                try syn.nodes.append(f.gpa, .{ .u = u, .v = at, .mode = .spine, .depth = @intCast(d), .folded = false, .stuck = stuck, .level = false, .held = false, .path = .none, .ctx = 0 });
                try syn.ranges.append(f.gpa, null);
                if (s.kind == .level) return;
                const g = shapes.get(u);
                if (g.kind != .node) return;
                u = shapes.overGet(g.a, s) orelse return;
                if (!stuck) {
                    if (try shapes.proj(f.gpa, f.account(), f.env.places, f.env.cells, at, s)) |n| at = n else stuck = true;
                }
            }
        }

        /// One step of an arm's lazy `⟲` (`advance`): `it` stands for the
        /// re-entries of place `it.expand` below `it.v`, as `reentries` finds
        /// them, met one node at a time so that a part two arms share is
        /// expanded once (`visit`). A join's sides are expanded each.
        pub fn expandOne(f: *Frame, it: Item, out: *std.ArrayList(Push)) Error!void {
            const shapes = f.env.shapes;
            const places = f.env.places;
            const y = try shapes.force(f.gpa, f.account(), it.v);
            switch (shapes.kind(y)) {
                .@"union", .positions, .choice => {
                    for ([_]NodeId{ .from(shapes.get(y).a), .from(shapes.get(y).b) }) |side| {
                        var x = it;
                        x.v = side;
                        try out.append(f.gpa, .{ .it = x });
                    }
                    return;
                },
                else => {},
            }
            for (places.steps(shapes.place(y)).steps) |c| {
                try f.env.charge.reserve(f.gpa, .inspection, 1);
                if (c.kind == .level) continue;
                const n = (try shapes.proj(f.gpa, f.account(), places, f.env.cells, y, c)) orelse continue;
                if (shapes.place(n).int() == it.expand) {
                    var x = it;
                    x.v = n;
                    x.expand = none;
                    try out.append(f.gpa, .{ .it = x });
                }
                var e = it;
                e.v = n;
                try out.append(f.gpa, .{ .it = e });
            }
        }

        /// Routes to a node in the runs of a choice's arms (`frontierMax`):
        /// the leaf arms a route comes from (`all`), and those two or more
        /// come from (`two`). One run takes one leaf arm, so the routes of a
        /// run are its arm's; arm 0 is the argument with no choice split.
        pub const Sum = struct { all: SetId = .none, two: SetId = .none };
        fn addSum(f: *Frame, a: Sum, b: Sum) Error!Sum {
            const sets = &f.env.cells.sets;
            var two = try sets.unionWith(f.gpa, f.env.charge, a.two, b.two);
            two = try sets.unionWith(f.gpa, f.env.charge, two, try sets.intersection(f.gpa, f.env.charge, a.all, b.all));
            return .{ .all = try sets.unionWith(f.gpa, f.env.charge, a.all, b.all), .two = two };
        }
        pub const MPos = struct { n: NodeId, sum: Sum, level: bool = false, stuck: bool = false };

        /// `frontierAt` where the write's exact prefix meets a `choice` (#1439):
        /// the written positions are those of one position in every run. A
        /// node's routes are counted per leaf arm of the choices split on the
        /// exact prefix, and a node stands at one position when no arm has two
        /// routes to it: in `chosen` a list two arms share is written in each.
        /// A join's sides and a view's answer are walked as nodes of their
        /// own, so a part arms share is met once (`routesMax`).
        pub fn frontierMax(f: *Frame, v: NodeId, steps: []const Step, exact_to: usize, w: *Written) Error!void {
            const gpa = f.gpa;
            const shapes = f.env.shapes;
            const sets = &f.env.cells.sets;
            var frontier: std.ArrayList(MPos) = .empty;
            defer frontier.deinit(gpa);
            var next: std.ArrayList(MPos) = .empty;
            defer next.deinit(gpa);
            var arms: Ids.FixedDict(3) = .{};
            defer arms.deinit(gpa);
            var out: MRoutes = .{};
            defer out.deinit(gpa);
            try frontier.append(gpa, .{ .n = v, .sum = .{ .all = try sets.insert(gpa, f.env.charge, .none, 0, 0) } });
            for (steps, 0..) |s, d| {
                // A choice on the exact prefix: one leaf arm per side.
                if (d <= exact_to) {
                    var i: usize = 0;
                    while (i < frontier.items.len) {
                        try f.env.charge.reserve(gpa, .inspection, 1);
                        const x = frontier.items[i];
                        const m = if (x.stuck or x.level) x.n else try shapes.force(gpa, f.account(), x.n);
                        if (x.stuck or x.level or shapes.kind(m) != .choice) {
                            i += 1;
                            continue;
                        }
                        _ = frontier.swapRemove(i);
                        for ([_]NodeId{ .from(shapes.get(m).a), .from(shapes.get(m).b) }) |side| {
                            var sum: Sum = .{};
                            var at = sets.iterate(x.sum.all);
                            while (at.next()) |e| {
                                const got = try arms.getOrPut(gpa, .{ side.int(), @intCast(d), e.key });
                                if (!got.found_existing) got.value_ptr.* = arms.count();
                                sum.all = try sets.insert(gpa, f.env.charge, sum.all, got.value_ptr.*, 0);
                                if (sets.member(x.sum.two, e.key)) sum.two = try sets.insert(gpa, f.env.charge, sum.two, got.value_ptr.*, 0);
                            }
                            try frontier.append(gpa, .{ .n = side, .sum = sum });
                        }
                    }
                }
                next.clearRetainingCapacity();
                if (s.kind == .level) {
                    var roots: std.ArrayList(MPos) = .empty;
                    defer roots.deinit(gpa);
                    for (frontier.items) |x| if (!x.stuck) try roots.append(gpa, x);
                    try f.routesMax(roots.items, .steps, &out);
                    const p = if (roots.items.len == 0) null else shapes.place(roots.items[0].n);
                    for (out.order.items) |i| {
                        const n = out.keys.items[i];
                        if (p == null or shapes.place(n) != p.?) continue;
                        // A join or a view stands for its sides or its answer,
                        // which are re-entries of their own: never both.
                        if (out.root.items[i] or out.join.items[i]) continue;
                        try next.append(gpa, .{ .n = n, .level = true, .sum = out.get(i) });
                    }
                    std.mem.swap(std.ArrayList(MPos), &frontier, &next);
                    continue;
                }
                for (frontier.items) |x| {
                    try f.env.charge.reserve(gpa, .inspection, 1);
                    if (x.stuck) {
                        try next.append(gpa, x);
                    } else if (try shapes.proj(gpa, f.account(), f.env.places, f.env.cells, x.n, s)) |n| {
                        try next.append(gpa, .{ .n = n, .level = x.level, .sum = x.sum });
                    } else if (!x.level) try next.append(gpa, .{ .n = x.n, .stuck = true, .sum = x.sum });
                }
                std.mem.swap(std.ArrayList(MPos), &frontier, &next);
            }
            try f.routesMax(frontier.items, .sides, &out);
            for (out.order.items) |i| {
                const sum = out.get(i);
                if (sum.all != .none and sum.two == .none) try w.ends.put(gpa, out.keys.items[i], {});
            }
        }

        /// `Routes` with a `Sum` per node (`routesMax`).
        pub const MRoutes = struct {
            index: stamped.Column(NodeId, u32) = .{},
            keys: std.ArrayList(NodeId) = .empty,
            order: std.ArrayList(u32) = .empty,
            runs: std.ArrayList([2]u32) = .empty,
            kids: std.ArrayList(u32) = .empty,
            acc: std.ArrayList(Sum) = .empty,
            indeg: std.ArrayList(u32) = .empty,
            done: std.ArrayList(bool) = .empty,
            root: std.ArrayList(bool) = .empty,
            /// A join or a view, walked as its sides or its answer.
            join: std.ArrayList(bool) = .empty,
            fn deinit(r: *MRoutes, gpa: Allocator) void {
                r.index.deinit(gpa);
                r.keys.deinit(gpa);
                r.order.deinit(gpa);
                r.runs.deinit(gpa);
                r.kids.deinit(gpa);
                r.acc.deinit(gpa);
                r.indeg.deinit(gpa);
                r.done.deinit(gpa);
                r.root.deinit(gpa);
                r.join.deinit(gpa);
            }
            fn intern(r: *MRoutes, gpa: Allocator, n: NodeId) Allocator.Error!struct { index: u32, found_existing: bool } {
                const got = try r.index.getOrPut(gpa, n);
                if (!got.found_existing) {
                    got.value_ptr.* = @intCast(r.keys.items.len);
                    try r.keys.append(gpa, n);
                }
                return .{ .index = got.value_ptr.*, .found_existing = got.found_existing };
            }
            /// A node on a knot of the value is never settled: two routes in
            /// every arm that reaches it.
            fn get(r: *const MRoutes, i: u32) Sum {
                const s = r.acc.items[i];
                return if (r.done.items[i]) s else .{ .all = s.all, .two = s.all };
            }
        };

        /// `routesBelow` with a `Sum` per node, and a join's sides and a
        /// view's answer walked as edges in `.steps` too (`frontierMax`).
        pub fn routesMax(f: *Frame, roots: []const MPos, by: enum { steps, sides }, out: *MRoutes) Error!void {
            const shapes = f.env.shapes;
            const places = f.env.places;
            const gpa = f.gpa;
            out.index.clear();
            out.keys.clearRetainingCapacity();
            out.order.clearRetainingCapacity();
            out.runs.clearRetainingCapacity();
            out.kids.clearRetainingCapacity();
            out.join.clearRetainingCapacity();
            var stack: std.ArrayList(NodeId) = .empty;
            defer stack.deinit(gpa);
            for (roots) |x| if (!(try out.intern(gpa, x.n)).found_existing) try stack.append(gpa, x.n);
            while (stack.pop()) |y| {
                const yi = out.index.get(y).?;
                try out.order.append(gpa, yi);
                const start: u32 = @intCast(out.kids.items.len);
                try f.env.charge.reserve(gpa, .inspection, 1);
                const m = try shapes.force(gpa, f.account(), y);
                var buf: [3]NodeId = undefined;
                var k: usize = 0;
                if (m != y) {
                    buf[k] = m;
                    k += 1;
                } else switch (shapes.kind(m)) {
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
                if (by == .steps and k == 0) for (places.steps(shapes.place(y)).steps) |c| {
                    try f.env.charge.reserve(gpa, .inspection, 1);
                    if (c.kind == .level) continue;
                    const n = (try shapes.proj(gpa, f.account(), places, f.env.cells, y, c)) orelse continue;
                    const got = try out.intern(gpa, n);
                    try out.kids.append(gpa, got.index);
                    if (!got.found_existing) try stack.append(gpa, n);
                };
                while (out.runs.items.len <= yi) try out.runs.append(gpa, .{ 0, 0 });
                while (out.join.items.len <= yi) try out.join.append(gpa, false);
                out.join.items[yi] = k != 0;
                out.runs.items[yi] = .{ start, @as(u32, @intCast(out.kids.items.len)) - start };
            }
            const n_nodes = out.keys.items.len;
            while (out.runs.items.len < n_nodes) try out.runs.append(gpa, .{ 0, 0 });
            while (out.join.items.len < n_nodes) try out.join.append(gpa, false);
            try out.acc.resize(gpa, n_nodes);
            try out.indeg.resize(gpa, n_nodes);
            try out.done.resize(gpa, n_nodes);
            try out.root.resize(gpa, n_nodes);
            @memset(out.acc.items, .{});
            @memset(out.indeg.items, 0);
            @memset(out.done.items, false);
            @memset(out.root.items, false);
            for (out.kids.items) |k| out.indeg.items[k] += 1;
            for (roots) |x| {
                const i = out.index.get(x.n).?;
                out.root.items[i] = out.indeg.items[i] == 0;
                out.acc.items[i] = try addSum(f, out.acc.items[i], x.sum);
            }
            var queue: std.ArrayList(u32) = .empty;
            defer queue.deinit(gpa);
            for (0..n_nodes) |i| if (out.indeg.items[i] == 0) try queue.append(gpa, @intCast(i));
            while (queue.pop()) |i| {
                try f.env.charge.reserve(gpa, .inspection, 1);
                out.done.items[i] = true;
                const r = out.runs.items[i];
                for (out.kids.items[r[0]..][0..r[1]]) |k| {
                    out.acc.items[k] = try addSum(f, out.acc.items[k], out.acc.items[i]);
                    out.indeg.items[k] -= 1;
                    if (out.indeg.items[k] == 0) try queue.append(gpa, k);
                }
            }
        }

        /// One state of `reachBeside`'s read, `it` a `.read` item: its own
        /// cells (or its whole reach where the read takes it whole), its
        /// sides or children pushed as states of their own (`otherPaths`,
        /// #1439).
        pub fn readStep(f: *Frame, it: Item, written: *const Written, paths: []const PathId, out: *std.ArrayList(Push)) Error!SetId {
            const shapes = f.env.shapes;
            const places = f.env.places;
            const cells = f.env.cells;
            if (written.holds(paths, it.path, it.v)) return .none;
            const n = try shapes.force(f.gpa, f.account(), it.v);
            switch (shapes.kind(n)) {
                .@"union", .choice, .positions => if (it.path != .none) {
                    const d = shapes.get(n);
                    for ([_]NodeId{ .from(d.a), .from(d.b) }) |side| {
                        var x = it;
                        x.v = side;
                        try out.append(f.gpa, .{ .it = x });
                    }
                    return .none;
                },
                else => {},
            }
            if (it.path == .none or (shapes.kind(n) != .node and shapes.kind(n) != .delta)) return shapes.reach(f.gpa, f.account(), &cells.sets, n);
            for (places.steps(shapes.place(n)).steps) |s| {
                try f.env.charge.reserve(f.gpa, .inspection, 1);
                if (s.kind == .level) continue;
                const c = (try shapes.proj(f.gpa, f.account(), places, cells, n, s)) orelse continue;
                var x = it;
                x.v = c;
                x.path = try f.routePath(it.path, .off, s);
                try out.append(f.gpa, .{ .it = x });
            }
            return shapes.cellsOf(f.gpa, f.account(), &cells.sets, n);
        }
    };
}
