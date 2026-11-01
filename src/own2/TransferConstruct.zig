//! L10: constructions (`docs/design/ownership-v2.md` §2.3, §2.9, §2.13.2):
//! literals, containers, a construction over its base, the demands they
//! make, spread chains, prepends and `++` chains. `Of(Frame)` is this
//! part's methods over the frame `Transfer.zig` declares; `Transfer.zig`
//! binds them by name (§5). It calls `TransferFrame` and
//! `TransferPattern` (`projectAt`).
//!
//! Obligations kept here: O7 (a construction's result is its base's object
//! written) and O13 (a literal's and a construction's κ by §2.9's rules),
//! as `Transfer.zig`'s header states them.

const std = @import("std");
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Place = @import("Place.zig");
const Shape = @import("Shape.zig");
const Cond = @import("Cond.zig");
const Demands = @import("Demands.zig");
const Bir = @import("../bir/Bir.zig");
const NodeId = Ids.NodeId;
const CondId = Ids.CondId;
const SetId = Ids.SetId;
const PlaceId = Ids.PlaceId;
const Value = Demands.Value;
const Step = Place.Step;
const Error = Ids.ChargeError;
const none: u32 = Ids.none_int;

/// The part of `Transfer.Frame` this file holds, over the frame `Transfer.zig` declares.
pub fn Of(comptime Frame: type) type {
    return struct {
        // ---- constructions ----------------------------------------------------------

        /// A literal's `[*]`: its items collected as positions (§2.3), κ by the
        /// positional rule over them (§2.9).
        pub fn literal(f: *Frame, i: u32, items: []const u32) Error!Value {
            const at = try f.placeOf(i);
            const shapes = f.env.shapes;
            const cells = f.env.cells;
            const elem_place = f.env.places.child(at, Step.elem) orelse {
                var parts: std.ArrayList(Value) = .empty;
                defer parts.deinit(f.gpa);
                for (items) |item| try parts.append(f.gpa, f.val(item).value);
                return f.opaqueOf(at, parts.items, items);
            };
            const site = try cells.site(f.gpa, f.account(), i, at, .list);
            var kappa: Cond.Kappas = .none;
            // The literal's `[*]`: one position, its items' snapshots merged (§2.9).
            var elem_k: Cond.Kappas = .none;
            var kids: u32 = Ids.none_int;
            if (items.len > 0) {
                var members: std.ArrayList(NodeId) = .empty;
                defer members.deinit(f.gpa);
                var ctxs: std.ArrayList(Cond.Kappas) = .empty;
                defer ctxs.deinit(f.gpa);
                // Each item's fit, κ merge and cells, inserted into the root's set
                // (§2.3, #1098), are as large as the item: growth (`sized`).
                var root_cells: SetId = .none;
                for (items) |item| {
                    const kernel = try f.sized();
                    defer f.account().leave(kernel);
                    const v = try f.fit(f.val(item).value, elem_place);
                    try members.append(f.gpa, v.node);
                    root_cells = try cells.sets.unionWith(f.gpa, f.env.charge, root_cells, try shapes.cellsOf(f.gpa, f.account(), &cells.sets, v.node));
                    try ctxs.append(f.gpa, v.kappa);
                    elem_k = try f.env.conds.kappaMerge(f.gpa, f.env.charge, elem_k, v.kappa);
                }
                // The positions DAG, one node per item, and each member's share of
                // the run's condition on its item's lane (§4.1, #1098); what the
                // run does once is a general task.
                const lanes = try f.gpa.alloc(Ids.Lane, items.len);
                defer f.gpa.free(lanes);
                for (items, lanes) |item, *l| l.* = .{ .atom = item, .role = .transfer_settlement };
                const task = try f.account().enter(f.gpa, null);
                defer f.account().leave(task);
                const start = shapes.count();
                const elems = try shapes.collectRoot(f.gpa, f.account(), &cells.sets, members.items, root_cells, lanes);
                elem_k = try f.env.conds.propagateFrom(f.gpa, f.env.charge, f.env.view(), elem_k, elems, members.items, ctxs.items, .together, true, false, null);
                // Each element at the literal's `[*]`: its own κ there (§2.9: the
                // conditions of `vᵢ` at `p`, relative to `vᵢ`), what a read of a
                // side of the positions node finds.
                for (members.items, ctxs.items) |m, c| {
                    const kernel = try f.sized();
                    defer f.account().leave(kernel);
                    elem_k = try f.kappaSet(elem_k, m, try f.env.conds.kappaOf(f.gpa, f.env.charge, f.env.view(), c, m, false));
                }
                elem_k = try carryDropped(f, elem_k, elems, start);
                kids = try shapes.overPut(f.gpa, f.account(), kids, Step.elem, elems);
                kappa = try f.env.conds.kappaLink(f.gpa, f.env.charge, kappa, Step.elem, elem_k);
            }
            const node = try shapes.node(f.gpa, f.account(), at, try f.set1(site), kids);
            return .{ .node = node, .kappa = try f.kappaSet(kappa, node, Cond.yes) };
        }

        /// §2.3 *Saturation at two*, *The entries of a dropped node*: the
        /// snapshot `root` of a value at position `elems` with the entries it
        /// stores for the nodes rebuilds dropped (`Shape.dropsClosure`, at each
        /// position below too, their projections with them) joined onto the
        /// node the value has there, where a read of that node does not imply
        /// them already. The tree the constructors would have made held the
        /// dropped nodes, so those entries were part of its reads; the rebuilt
        /// node holds every member they hold, so each stays true of it. Only the
        /// snapshot's own positions are walked, each `(position, node)` once,
        /// and only to a fold. A growth task.
        fn carryDropped(f: *Frame, root: Cond.Kappas, elems: NodeId, start: u32) Error!Cond.Kappas {
            if (root == .none) return root;
            const shapes = f.env.shapes;
            const conds = f.env.conds;
            const gpa = f.gpa;
            const task = try f.account().enter(gpa, null);
            defer f.account().leave(task);
            const PathRec = struct { parent: u32, step: Step };
            var paths: std.ArrayList(PathRec) = .empty;
            defer paths.deinit(gpa);
            var cands: std.ArrayList(NodeId) = .empty;
            defer cands.deinit(gpa);
            const Fr = struct { pos: Cond.Kappas, node: NodeId, path: u32, from: u32, len: u32 };
            var frames: std.ArrayList(Fr) = .empty;
            defer frames.deinit(gpa);
            var visited: Ids.FixedDict(2) = .{};
            defer visited.deinit(gpa);
            const Carry = struct { path: u32, node: NodeId, k: CondId };
            var carries: std.ArrayList(Carry) = .empty;
            defer carries.deinit(gpa);
            var here: std.ArrayList(NodeId) = .empty;
            defer here.deinit(gpa);
            try frames.append(gpa, .{ .pos = root, .node = elems, .path = none, .from = 0, .len = 0 });
            while (frames.pop()) |fr| {
                try f.account().reserve(.shape, 1);
                if ((try visited.getOrPut(gpa, .{ fr.pos.int(), fr.node.int() })).found_existing) continue;
                // The dropped nodes at this position: the parent's, projected,
                // and what the rebuilds of this position's node dropped.
                here.clearRetainingCapacity();
                try here.appendSlice(gpa, cands.items[fr.from..][0..fr.len]);
                try shapes.dropsClosure(gpa, f.account(), fr.node, &here);
                var carry: ?CondId = null;
                if (here.items.len > 0) {
                    const own = conds.kappaGet(fr.pos, fr.node);
                    var reads: ?[2]CondId = null;
                    for (here.items) |x| {
                        const e = conds.kappaGet(fr.pos, x) orelse continue;
                        if (e == Cond.yes) continue;
                        if (own) |o| if (try conds.impliedBy(gpa, f.env.view(), e, o)) continue;
                        // The node's reads, at a plain position and at a summary
                        // one, before anything is carried: the test, unchecked.
                        if (reads == null) {
                            // No memo either: a later read is then made, and checked.
                            const saved = .{ conds.drop_check_off, conds.no_memo };
                            conds.drop_check_off = true;
                            conds.no_memo = true;
                            defer {
                                conds.drop_check_off = saved[0];
                                conds.no_memo = saved[1];
                            }
                            reads = .{ try conds.kappaOf(gpa, f.env.charge, f.env.view(), fr.pos, fr.node, false), try conds.kappaOf(gpa, f.env.charge, f.env.view(), fr.pos, fr.node, true) };
                        }
                        if (try conds.impliedBy(gpa, f.env.view(), e, reads.?[0]) and try conds.impliedBy(gpa, f.env.view(), e, reads.?[1])) continue;
                        carry = if (carry) |c| try conds.join(gpa, f.env.charge, c, e) else e;
                    }
                }
                if (carry) |k| try carries.append(gpa, .{ .path = fr.path, .node = fr.node, .k = k });
                if (conds.isFold(fr.pos)) continue;
                var it = conds.kappaLinks(fr.pos);
                while (it.next()) |l| {
                    const child = (try shapes.proj(gpa, f.account(), f.env.places, f.env.cells, fr.node, l.step)) orelse continue;
                    const from: u32 = @intCast(cands.items.len);
                    for (here.items) |x| if (try shapes.proj(gpa, f.account(), f.env.places, f.env.cells, x, l.step)) |px| try cands.append(gpa, px);
                    // Below a node older than the construction and with nothing
                    // dropped above it, every position is an operand's own: its
                    // construction carried what it dropped there.
                    if (child.int() < start and cands.items.len == from and shapes.dropsOf(child).at == none) continue;
                    try paths.append(gpa, .{ .parent = fr.path, .step = l.step });
                    try frames.append(gpa, .{ .pos = l.child, .node = child, .path = @intCast(paths.items.len - 1), .from = from, .len = @as(u32, @intCast(cands.items.len)) - from });
                }
            }
            var out = root;
            var along: std.ArrayList(Step) = .empty;
            defer along.deinit(gpa);
            for (carries.items) |c| {
                along.clearRetainingCapacity();
                var p = c.path;
                while (p != none) : (p = paths.items[p].parent) try along.append(gpa, paths.items[p].step);
                std.mem.reverse(Step, along.items);
                out = try conds.kappaSetAt(gpa, f.env.charge, out, along.items, c.node, c.k);
            }
            return out;
        }

        /// `v` read at place `at`: itself, or a recast when its place differs.
        pub fn fit(f: *Frame, v: Value, at: PlaceId) Error!Value {
            if (v.node == .none) return f.topValue(at);
            if (f.env.shapes.place(v.node) == at) return v;
            return .{ .node = try f.env.shapes.recast(f.gpa, f.account(), at, v.node), .kappa = v.kappa };
        }

        /// A tuple, a record or a constructor application: a node over its
        /// parts (§2.6), a record's object a fresh `site`.
        pub fn container(f: *Frame, i: u32, parts: []const u32, steps: []const Step, record: bool) Error!Value {
            const at = try f.placeOf(i);
            const shapes = f.env.shapes;
            if (f.env.places.kind(at) == .cross) return f.nothing(at);
            if (f.env.places.kind(at) == .@"var") {
                var vs: std.ArrayList(Value) = .empty;
                defer vs.deinit(f.gpa);
                for (parts) |p| try vs.append(f.gpa, f.val(p).value);
                return f.opaqueOf(at, vs.items, parts);
            }
            var kids: u32 = Ids.none_int;
            var kappa: Cond.Kappas = .none;
            for (parts, steps) |p, s| {
                // §4.1: each part is in its own atom's lane.
                const kernel = try f.lane(p);
                defer f.account().leave(kernel);
                const child_place = f.env.places.child(at, s) orelse continue;
                const v = try f.fit(f.val(p).value, child_place);
                kids = try shapes.overPut(f.gpa, f.account(), kids, s, v.node);
                // §2.9: each part's snapshot linked under its step, never re-keyed.
                kappa = try f.env.conds.kappaLink(f.gpa, f.env.charge, kappa, s, v.kappa);
            }
            const cells: SetId = if (record) try f.set1(try f.env.cells.site(f.gpa, f.account(), i, at, .record)) else .none;
            const node = try shapes.node(f.gpa, f.account(), at, cells, kids);
            return .{ .node = node, .kappa = try f.kappaSet(kappa, node, Cond.yes) };
        }

        /// The stores of a construction into `base` (§2.9's construction rule):
        /// the base's `[*]` and the stored elements as positions, κ lowered by
        /// each stored value in turn; the result is the base's object.
        /// `atoms[i]` the instruction `stored[i]` comes from, `base_atom` the
        /// base's: each stored item's share on its own lane (§4.1, #1139).
        pub fn construct(f: *Frame, base: Value, stored: []const Value, base_atom: u32, atoms: []const u32) Error!Value {
            // The base's projection, κ, cells and the put are as large as the
            // base, and the stored items' as large as they: growth (§4.1, #1181).
            // Only the positions nodes are on the items' lanes (`collectRoot`).
            const run = try f.sized();
            defer f.account().leave(run);
            const shapes = f.env.shapes;
            const cells = f.env.cells;
            const at = shapes.place(base.node);
            const elem_place = f.env.places.child(at, Step.elem) orelse {
                var parts: std.ArrayList(Value) = .empty;
                defer parts.deinit(f.gpa);
                try parts.append(f.gpa, base);
                try parts.appendSlice(f.gpa, stored);
                return f.opaqueOf(at, parts.items, null);
            };
            const old = (try shapes.proj(f.gpa, f.account(), f.env.places, cells, base.node, Step.elem)).?;
            var members: std.ArrayList(NodeId) = .empty;
            defer members.deinit(f.gpa);
            try members.append(f.gpa, old);
            // The base's `[*]`, with each stored value's snapshot merged in:
            // they are one position (§2.9).
            var elem_k = f.env.conds.kappaChild(base.kappa, Step.elem);
            var k = try f.env.conds.kappaOf(f.gpa, f.env.charge, f.env.view(), elem_k, old, true);
            var held = (try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, old));
            for (stored) |s| {
                const v = try f.fit(s, elem_place);
                elem_k = try f.env.conds.kappaMerge(f.gpa, f.env.charge, elem_k, v.kappa);
                k = try f.env.conds.lower(f.gpa, f.env.charge, f.env.view(), v.kappa, k, held, v.node, true, null);
                held = try cells.sets.unionWith(f.gpa, f.env.charge, held, (try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, v.node)));
                try members.append(f.gpa, v.node);
            }
            const lanes = try f.gpa.alloc(Ids.Lane, members.items.len);
            defer f.gpa.free(lanes);
            lanes[0] = .{ .atom = base_atom, .role = .transfer_settlement };
            for (atoms, lanes[1..]) |atom, *l| l.* = .{ .atom = atom, .role = .transfer_settlement };
            const start = shapes.count();
            const elems = try shapes.collectRoot(f.gpa, f.account(), &cells.sets, members.items, Shape.Table.lazy_cells, lanes);
            const node = try shapes.put(f.gpa, f.account(), f.env.places, cells, base.node, Step.elem, elems, true, .none);
            elem_k = try f.kappaSet(elem_k, elems, k);
            elem_k = try carryDropped(f, elem_k, elems, start);
            var kappa = try f.env.conds.kappaLink(f.gpa, f.env.charge, base.kappa, Step.elem, elem_k);
            kappa = try f.kappaSet(kappa, node, try f.env.conds.kappaOf(f.gpa, f.env.charge, f.env.view(), base.kappa, base.node, false));
            return .{ .node = node, .kappa = kappa };
        }

        pub fn demand(f: *Frame, point: u32, kind: Facts.DemandKind, base_inst: u32, base: Value, others: []const u32, callee: u32) Error!void {
            const start: u32 = @intCast(f.operands.items.len);
            for (others) |o| try f.operands.append(f.gpa, .{ .value = f.val(o).value, .inst = o });
            const bv = f.val(base_inst);
            try f.demands.append(f.gpa, .{
                .point = point,
                .kind = kind,
                .base = base,
                .base_inst = base_inst,
                .base_local = bv.local,
                .base_path = bv.path,
                .token = f.token(point),
                .callee_inst = callee,
                .operands = .{ .start = start, .len = @intCast(f.operands.items.len - start) },
            });
        }

        /// A spread chain at its root (§2.13.2).
        pub fn spreadChain(f: *Frame, root: u32, s: Bir.Spread) Error!Value {
            const items = f.bir.spreadItems(s);
            var insts: std.ArrayList(u32) = .empty;
            defer insts.deinit(f.gpa);
            for (items) |it| try insts.append(f.gpa, it[0]);
            for (insts.items) |o| try f.consume(o, root, .whole, .none);
            var first: usize = items.len;
            for (items, 0..) |it, k| if (it[1] == 1) {
                first = k;
                break;
            };
            const at = try f.placeOf(root);
            if (first == items.len) return f.literal(root, insts.items);
            var stored: std.ArrayList(Value) = .empty;
            defer stored.deinit(f.gpa);
            var built = blk: {
                const kernel = try f.sized();
                defer f.account().leave(kernel);
                break :blk try f.fit(f.val(items[first][0]).value, at);
            };
            if (first + 1 < items.len) {
                var atoms: std.ArrayList(u32) = .empty;
                defer atoms.deinit(f.gpa);
                for (items[first + 1 ..]) |it| {
                    // Each item's projection is as large as it (§4.1, #1139).
                    const kernel = try f.sized();
                    defer f.account().leave(kernel);
                    try atoms.append(f.gpa, it[0]);
                    const v = f.val(it[0]).value;
                    if (it[1] == 1) {
                        // A spread's elements are stored.
                        try stored.append(f.gpa, try f.projectAt(v, Step.elem, f.env.places.child(at, Step.elem) orelse at));
                    } else try stored.append(f.gpa, v);
                }
                var others: std.ArrayList(u32) = .empty;
                defer others.deinit(f.gpa);
                for (insts.items, 0..) |o, k| if (k != first) try others.append(f.gpa, o);
                try f.demand(root, .construction, items[first][0], built, others.items, none);
                built = try f.construct(built, stored.items, items[first][0], atoms.items);
            }
            if (first == 0) return built;
            return f.prepend(root, at, items[0..first], built, items[first][0]);
        }

        /// `[ x₁…xₖ, …xs ]` (§2.13.2): a fresh list unless it may answer the
        /// base (a re-cons), elements the fronts' and the base's, their κ the
        /// positional collection's (the construction rule, #1386); the
        /// storage's κ lost except when every front is a fresh object by
        /// construction.
        pub fn prepend(f: *Frame, root: u32, at: PlaceId, fronts: []const [2]u32, base: Value, base_atom: u32) Error!Value {
            // The fronts' and the base's work (the base's reach and cells, each
            // put in the root's set when a front is not fresh) is as large as
            // they are: growth (§4.1, #1181). Only the positions nodes are on
            // the items' lanes (`collectRoot`).
            const run = try f.sized();
            defer f.account().leave(run);
            const shapes = f.env.shapes;
            const cells = f.env.cells;
            const elem_place = f.env.places.child(at, Step.elem) orelse {
                var parts: std.ArrayList(Value) = .empty;
                defer parts.deinit(f.gpa);
                try parts.append(f.gpa, base);
                for (fronts) |fr| try parts.append(f.gpa, f.val(fr[0]).value);
                return f.opaqueOf(at, parts.items, null);
            };
            var fresh = true;
            var members: std.ArrayList(NodeId) = .empty;
            defer members.deinit(f.gpa);
            var elem_k = f.env.conds.kappaChild(base.kappa, Step.elem);
            const base_reach = try shapes.reach(f.gpa, f.account(), &cells.sets, base.node);
            for (fronts) |it| {
                const v = try f.fit(f.val(it[0]).value, elem_place);
                try members.append(f.gpa, v.node);
                elem_k = try f.env.conds.kappaMerge(f.gpa, f.env.charge, elem_k, v.kappa);
                const t = f.tag(it[0]);
                if (t == .record or t == .tuple) continue;
                if (t == .call) if (f.ctx.ctorOf(f.ctx.ctx, f.data(it[0]).lhs) != null) continue;
                if (f.env.places.kind(elem_place) != .list) {
                    fresh = false;
                    continue;
                }
                var ct = cells.sets.iterate((try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, v.node)));
                var any = false;
                while (ct.next()) |e| {
                    const o = cells.origin(.from(e.key));
                    any = true;
                    if (!(o == .site or o == .result) or e.value == 1 or cells.sets.member(base_reach, e.key)) fresh = false;
                }
                if (!any) fresh = false;
            }
            try members.append(f.gpa, (try shapes.proj(f.gpa, f.account(), f.env.places, cells, base.node, Step.elem)).?);
            // One positions node per item, on its lane (§4.1, #1139).
            const lanes = try f.gpa.alloc(Ids.Lane, members.items.len);
            defer f.gpa.free(lanes);
            for (fronts, lanes[0..fronts.len]) |it, *l| l.* = .{ .atom = it[0], .role = .transfer_settlement };
            lanes[fronts.len] = .{ .atom = base_atom, .role = .transfer_settlement };
            const start = shapes.count();
            const elems = try shapes.collectRoot(f.gpa, f.account(), &cells.sets, members.items, Shape.Table.lazy_cells, lanes);
            var c = try f.set1(try cells.site(f.gpa, f.account(), root, at, .list));
            if (!fresh) {
                var bt = cells.sets.iterate((try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, base.node)));
                while (bt.next()) |e| c = try cells.sets.insert(f.gpa, f.env.charge, c, e.key, 1);
            }
            const node = try shapes.node(f.gpa, f.account(), at, c, try shapes.overPut(f.gpa, f.account(), Ids.none_int, Step.elem, elems));
            elem_k = try carryDropped(f, elem_k, elems, start);
            var kappa = try f.env.conds.kappaLink(f.gpa, f.env.charge, .none, Step.elem, elem_k);
            kappa = try f.kappaSet(kappa, node, if (fresh) Cond.yes else Cond.lost);
            return .{ .node = node, .kappa = kappa };
        }

        /// A `++` chain on lists at its outermost call (R-2.2): one demand on
        /// the leftmost operand, every other operand's elements stored.
        pub fn appendChain(f: *Frame, root: u32) Error!Value {
            var ops: std.ArrayList(u32) = .empty;
            defer ops.deinit(f.gpa);
            var cur = root;
            while (true) {
                const a = f.args(cur);
                try ops.append(f.gpa, a[0].int());
                const next = a[1].int();
                if (f.tag(next) == .call and f.absorbed[f.rel(next)]) {
                    cur = next;
                    continue;
                }
                try ops.append(f.gpa, next);
                break;
            }
            for (ops.items) |o| try f.consume(o, root, .whole, .none);
            const at = try f.placeOf(root);
            const base = blk: {
                const kernel = try f.sized();
                defer f.account().leave(kernel);
                break :blk try f.fit(f.val(ops.items[0]).value, at);
            };
            var stored: std.ArrayList(Value) = .empty;
            defer stored.deinit(f.gpa);
            for (ops.items[1..]) |o| {
                const kernel = try f.sized();
                defer f.account().leave(kernel);
                try stored.append(f.gpa, try f.projectAt(f.val(o).value, Step.elem, f.env.places.child(at, Step.elem) orelse at));
            }
            try f.demand(root, .append, ops.items[0], base, ops.items[1..], none);
            return f.construct(base, stored.items, ops.items[0], ops.items[1..]);
        }
    };
}
