//! L10: patterns and splits (`docs/design/ownership-v2.md` §2.13.3, §2.2):
//! a pattern bound to a value, the projections below it (`project`,
//! `projectAt`, a step a place does not have), and a list pattern's split
//! of its container into an element and a rest (`bindList`). `Of(Frame)`
//! is this part's methods over the frame `Transfer.zig` declares;
//! `Transfer.zig` binds them by name (§5). It calls only `TransferFrame`.
//!
//! Obligations kept here: O6's pattern half (a list pattern's element and
//! rest are the two sides of one split), as `Transfer.zig`'s header states
//! it.

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Cell = @import("Cell.zig");
const Demands = @import("Demands.zig");
const Bir = @import("../bir/Bir.zig");
const NodeId = Ids.NodeId;
const CellId = Ids.CellId;
const SetId = Ids.SetId;
const PlaceId = Ids.PlaceId;
const Value = Demands.Value;
const Step = Place.Step;
const Error = Ids.ChargeError;
const none: u32 = Ids.none_int;
const Inst = Bir.Inst;

/// The part of `Transfer.Frame` this file holds, over the frame `Transfer.zig` declares.
pub fn Of(comptime Frame: type) type {
    return struct {
        // ---- patterns ------------------------------------------------------------

        /// Bind pattern `p` to `v`, matched at `point` (§2.13.3).
        const BindItem = struct { pat: u32, value: Value };

        /// Whether a cell set has two members or more.
        fn several(cellt: *const Cell.Table, s: SetId) bool {
            var it = cellt.sets.iterate(s);
            return it.next() != null and it.next() != null;
        }

        pub fn bind(f: *Frame, p: u32, v: Value, point: u32) Error!void {
            // One explicit stack for the whole pattern, a list pattern's nested
            // items included (#1138: a pattern nests as deep as the source).
            var stack: std.ArrayList(BindItem) = .empty;
            defer stack.deinit(f.gpa);
            try stack.append(f.gpa, .{ .pat = p, .value = v });
            while (stack.pop()) |it| {
                // §4.1: each written pattern's binding is its own atom's kernel.
                const kernel = try f.lane(it.pat);
                defer f.account().leave(kernel);
                const d = f.data(it.pat);
                switch (f.tag(it.pat)) {
                    .pat_var => try f.bindLocal(d.lhs, it.value, point),
                    .pat_as => {
                        try f.bindLocal(d.rhs, it.value, point);
                        try stack.append(f.gpa, .{ .pat = d.lhs, .value = it.value });
                    },
                    .pat_wild, .pat_int, .pat_char, .pat_string, .pat_unit => {},
                    // Each part of a wide pattern is its own atom's (§4.1: wide runs
                    // supply their own written atoms): a component's pattern, a field's
                    // local, an argument's pattern.
                    .pat_tuple => for (f.bir.extraSlice(Bir.inlineRange(d), Inst.Index), 0..) |e, k| {
                        const part = try f.lane(e.int());
                        defer f.account().leave(part);
                        try stack.append(f.gpa, .{ .pat = e.int(), .value = try f.project(it.value, try Step.index(f.account(), @intCast(k)), e.int()) });
                    },
                    .pat_record => for (f.bir.extraSlice(Bir.inlineRange(d), u32)) |local| {
                        const part = try f.account().enter(f.gpa, .{ .atom = Ids.atom_local_bit | local, .role = .transfer_settlement });
                        defer f.account().leave(part);
                        const name = f.bir.locals[f.decl.locals_start + local].name;
                        const step = try Step.field(f.account(), f.ctx.fieldRank(f.ctx.ctx, name));
                        const at = try f.ctx.placeOfLocal(f.ctx.ctx, local);
                        try f.bindLocal(local, try f.projectAt(it.value, step, at), point);
                    },
                    .pat_ctor => {
                        const ref = d.lhs;
                        const ord = f.ctx.ctorOf(f.ctx.ctx, ref) orelse {
                            f.markUnbuilt(it.pat);
                            continue;
                        };
                        const arg_pats = f.bir.extraSlice(f.bir.subRange(@fromBackingInt(d.rhs)), Inst.Index);
                        for (arg_pats, 0..) |a, k| {
                            const part = try f.lane(a.int());
                            defer f.account().leave(part);
                            const step = try f.env.places.ctorStep(f.gpa, f.account(), ord[0], @intCast(k));
                            const value = try f.project(it.value, step, a.int());
                            try stack.append(f.gpa, .{ .pat = a.int(), .value = try f.below(it.pat, it.value, step, value) });
                        }
                    },
                    .pat_list => try f.bindList(it.pat, it.value, point, &stack),
                    .pat_spread => {},
                    else => f.markUnbuilt(it.pat),
                }
            }
        }

        /// A constructor pattern's argument at `s` (§2.13.3) on a recursive
        /// place: one `below(c·s·ι)` per symbolic cell `c` of the matched value
        /// (the cells a projection of `c` puts there replaced) — the levels
        /// under a recursive child, or a non-recursive argument of this one
        /// node — so two matched positions' arguments are apart under their
        /// split's κ and below the matched cells. Otherwise the projection.
        pub fn below(f: *Frame, p: u32, v: Value, s: Step, projected: Value) Error!Value {
            const shapes = f.env.shapes;
            const cells = f.env.cells;
            const places = f.env.places;
            if (v.node == .none or projected.node == .none) return projected;
            // Over several alternative cells: a product, growth (see `bindList`).
            const task: ?Ids.Account.Kernel = if (several(cells, (try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, v.node)))) try f.account().enter(f.gpa, null) else null;
            defer if (task) |t| f.account().leave(t);
            const at = shapes.place(v.node);
            const child = places.child(at, s) orelse return projected;
            if (shapes.place(projected.node) != child) return projected;
            // On a recursive place every argument is materialised (`level`'s
            // non-recursive ones too, by their step); a non-recursive
            // constructor's arguments are plain projections.
            const recursive = for (places.steps(at).children) |k| {
                if (places.sameCycle(at, k)) break true;
            } else false;
            if (!recursive) return projected;
            const label = try cells.label(f.gpa, f.account(), p, .none, false);
            const kind = Cell.Kind.ofPlace(places.kind(child));
            const split_kappa = try f.env.conds.kappaOf(f.gpa, f.env.charge, f.env.view(), projected.kappa, projected.node, true);
            var refined: SetId = .none;
            var canon: SetId = .none;
            var it = cells.sets.iterate((try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, v.node)));
            while (it.next()) |e| {
                const c: CellId = .from(e.key);
                const o = cells.origin(c);
                if (o == .site or o == .result or o == .esc or o == .top) continue;
                _ = try cells.split(f.gpa, f.account(), c, p, label, split_kappa);
                const b = try cells.refine(f.gpa, f.account(), .below, c, label, s.word(), child, kind);
                refined = try cells.sets.insert(f.gpa, f.env.charge, refined, b.int(), e.value);
                const u = (try cells.unrefined(f.gpa, f.account(), places, b)) orelse continue;
                canon = try cells.sets.insert(f.gpa, f.env.charge, canon, u.int(), 0);
            }
            if (refined == .none) return projected;
            var drop: SetId = .none;
            var ct = cells.sets.iterate((try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, projected.node)));
            while (ct.next()) |e| {
                try f.env.charge.reserve(f.gpa, .inspection, 1);
                const u = (try cells.unrefined(f.gpa, f.account(), places, .from(e.key))) orelse continue;
                if (cells.sets.member(canon, u.int())) drop = try cells.sets.insert(f.gpa, f.env.charge, drop, e.key, 0);
            }
            var node = try shapes.leaf(f.gpa, f.account(), child, refined);
            const explicit = try shapes.without(f.gpa, f.account(), &cells.sets, projected.node, drop, false);
            if (explicit != .none) {
                var two = [_]NodeId{ node, explicit };
                node = try shapes.join(f.gpa, f.account(), places, cells, &two);
            }
            return .{ .node = node, .kappa = projected.kappa };
        }

        /// `proj(v, s)`, at the pattern's or expression's own place when the
        /// place has no such step (a recast, approximate).
        pub fn project(f: *Frame, v: Value, s: Step, at_inst: u32) Error!Value {
            return f.projectAt(v, s, try f.placeOf(at_inst));
        }

        pub fn projectAt(f: *Frame, v: Value, s: Step, at: PlaceId) Error!Value {
            const shapes = f.env.shapes;
            if (v.node == .none) return f.topValue(at);
            // No such step (a value at a type variable's place, or a folded
            // place): a leaf is itself there, its cells exact; a built value is
            // some value inside it, its reach approximately (§2.13.9), never its
            // own cells, which its parts' are not among (#1350).
            const n = (try shapes.proj(f.gpa, f.account(), f.env.places, f.env.cells, v.node, s)) orelse {
                var inner = try shapes.force(f.gpa, f.account(), v.node);
                while (shapes.kind(inner) == .recast and !shapes.isWhole(inner)) inner = try shapes.force(f.gpa, f.account(), .from(shapes.get(inner).a));
                if (shapes.kind(inner) == .leaf) return .{ .node = try shapes.recast(f.gpa, f.account(), at, v.node), .kappa = v.kappa };
                return .{ .node = try shapes.recastWhole(f.gpa, f.account(), &f.env.cells.sets, at, v.node), .kappa = v.kappa };
            };
            return .{ .node = n, .kappa = f.env.conds.kappaChild(v.kappa, s) };
        }

        /// The cells a list pattern on `n` splits (§2.13.3), into `out`: each
        /// symbolic container cell of `n`, or, where `n` is a rest of a split of
        /// it — its `[*]` (`contents`) holds `others` of that cell's positions —
        /// those `others`, so the match splits the rest's own positions. A
        /// container is split too when the contents hold anything else at its
        /// `[*]`'s canonical position: its plain projection, or a position a
        /// push, literal or join stored beside the rest (`[ a, …rest ]`'s `a`),
        /// which no split of the rest's positions stands for.
        pub fn splitTargets(f: *Frame, n: NodeId, contents: NodeId, out: *std.ArrayList(Cell.Radix.Iterator.Entry)) Error!void {
            const cells = f.env.cells;
            const places = f.env.places;
            const at = try f.env.shapes.cellsOf(f.gpa, f.account(), &cells.sets, contents);
            var it = cells.sets.iterate(try f.env.shapes.cellsOf(f.gpa, f.account(), &cells.sets, n));
            while (it.next()) |e| {
                const c: CellId = .from(e.key);
                const o = cells.origin(c);
                if (o == .site or o == .result or o == .esc or o == .top) continue;
                // `c[*]`'s canonical cell, null over a concrete base.
                const canon: ?CellId = blk: {
                    const cu = (try cells.unrefined(f.gpa, f.account(), places, c)) orelse break :blk null;
                    const x = cells.get(cu);
                    const path = (try places.extend(f.gpa, f.env.charge, .from(x.b), Step.elem)) orelse break :blk null;
                    break :blk try cells.symbolic(f.gpa, f.account(), places, x.origin, x.a, path, x.c);
                };
                const first = out.items.len;
                var plain = false;
                var ct = cells.sets.iterate(at);
                while (ct.next()) |x| {
                    try f.env.charge.reserve(f.gpa, .inspection, 1);
                    const xc: CellId = .from(x.key);
                    if (cells.origin(xc) == .others and cells.positionsOf(xc) == c) {
                        try out.append(f.gpa, .{ .key = x.key, .value = e.value | x.value });
                    } else if (canon) |cn| {
                        if ((try cells.unrefined(f.gpa, f.account(), places, xc)) == cn) plain = true;
                    } else if (cells.parent(xc) == c) plain = true;
                }
                if (out.items.len == first or plain) try out.append(f.gpa, e);
            }
        }

        /// `[ a, b, …rest ]` (§2.13.3): per container cell, the positions taken
        /// at this split are `elem` refinements, the rest `others`; a concrete
        /// container's contents are its explicit elements, on both sides.
        pub fn bindList(f: *Frame, p: u32, v: Value, point: u32, deferred: *std.ArrayList(BindItem)) Error!void {
            const items = f.bir.extraSlice(Bir.inlineRange(f.data(p)), Inst.Index);
            // The match tests the list's length (`[]`, `[ x, …_ ]`, `[ a, b ]`),
            // so it reads the list itself, at whatever depth the pattern is
            // (§2.13.3, *A list pattern reads its list*): a parameter's part
            // is `R` there. `[ …rest ]` alone tests nothing.
            if (!(items.len == 1 and f.tag(items[0].int()) == .pat_spread)) try f.readsOf(v, .none, false);
            if (items.len == 0) return;
            // Several container cells are inferred alternatives: their per-cell
            // work is a product with the items, growth chosen before the work
            // (§4.1), never an item's baseline.
            const product = several(f.env.cells, (try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, v.node)));
            const task: ?Ids.Account.Kernel = if (product) try f.account().enter(f.gpa, null) else null;
            defer if (task) |t| f.account().leave(t);
            const shapes = f.env.shapes;
            const cells = f.env.cells;
            const list_place = shapes.place(v.node);
            const elem_place = f.env.places.child(list_place, Step.elem) orelse {
                f.markUnbuilt(p);
                return;
            };
            const elem_kind = Cell.Kind.ofPlace(f.env.places.kind(elem_place));
            const label = try cells.label(f.gpa, f.account(), p, .none, false);
            const contents = (try shapes.proj(f.gpa, f.account(), f.env.places, cells, v.node, Step.elem)).?;
            const contents_kappa = f.env.conds.kappaChild(v.kappa, Step.elem);
            const split_kappa = try f.env.conds.kappaOf(f.gpa, f.env.charge, f.env.view(), contents_kappa, contents, true);
            // §2.13.3: a position is `elem(c·ι)` per symbolic container cell `c`
            // (its `[*]` projection, `c[*]`, is what it refines), and the rest's
            // `[*]` `others(c·ι)`. The other cells at `[*]` — a concrete
            // container's explicit elements, a value a push stored — stay as
            // they are, in every position: `explicit`, `contents` without the
            // containers' projections.
            var containers: std.ArrayList(Cell.Radix.Iterator.Entry) = .empty;
            defer containers.deinit(f.gpa);
            try f.splitTargets(v.node, contents, &containers);
            // A rest's positions split as positions (`Cell.positions_bit`).
            var bits: std.ArrayList(u32) = .empty;
            defer bits.deinit(f.gpa);
            const own = try f.env.shapes.cellsOf(f.gpa, f.account(), &cells.sets, v.node);
            for (containers.items) |e| try bits.append(f.gpa, if (cells.origin(.from(e.key)) == .others and cells.sets.member(own, cells.positionsOf(.from(e.key)).int())) Cell.Table.positions_bit else 0);
            var projections: SetId = .none;
            for (containers.items, bits.items) |e, bit| {
                const c: CellId = .from(e.key);
                _ = try cells.split(f.gpa, f.account(), c, p, label, split_kappa);
                const u = (try cells.unrefined(f.gpa, f.account(), f.env.places, try cells.refine(f.gpa, f.account(), .elem, c, label, bit, elem_place, elem_kind))) orelse continue;
                projections = try cells.sets.insert(f.gpa, f.env.charge, projections, u.int(), 0);
            }
            var drop: SetId = .none;
            if (projections != .none) {
                var ct = cells.sets.iterate((try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, contents)));
                while (ct.next()) |e| {
                    try f.env.charge.reserve(f.gpa, .inspection, 1);
                    const u = (try cells.unrefined(f.gpa, f.account(), f.env.places, .from(e.key))) orelse continue;
                    if (cells.sets.member(projections, u.int())) drop = try cells.sets.insert(f.gpa, f.env.charge, drop, e.key, 0);
                }
            }
            const explicit_one = try shapes.without(f.gpa, f.account(), &cells.sets, contents, drop, true);
            // A concrete container's positions share its explicit elements: each
            // position bound to a variable records which it is, under one split
            // of the container whose κ is the contents' (`Demands.Taken`).
            var taken_split: Ids.SplitId = .none;
            var it = cells.sets.iterate((try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, v.node)));
            while (it.next()) |e| {
                const o = cells.origin(.from(e.key));
                if (o != .site and o != .result and o != .esc) continue;
                taken_split = try cells.split(f.gpa, f.account(), .from(e.key), p, label, split_kappa);
                break;
            }
            const explicit_cells = if (explicit_one == .none) SetId.none else (try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, explicit_one));
            const explicit_rest = try shapes.without(f.gpa, f.account(), &cells.sets, contents, drop, false);
            var position: u32 = 0;
            for (items) |item| {
                // An item's work over several containers is a product (items ×
                // inferred alternatives): the growth task entered above.
                const kernel = if (product) try f.account().enter(f.gpa, null) else try f.lane(item.int());
                defer f.account().leave(kernel);
                const spread = f.tag(item.int()) == .pat_spread;
                var refined: SetId = .none;
                for (containers.items, bits.items) |e, bit| {
                    const c: CellId = .from(e.key);
                    const r = if (spread) try cells.refine(f.gpa, f.account(), .others, c, label, bit, elem_place, elem_kind) else try cells.refine(f.gpa, f.account(), .elem, c, label, position | bit, elem_place, elem_kind);
                    refined = try cells.sets.insert(f.gpa, f.env.charge, refined, r.int(), e.value);
                }
                var node = try shapes.leaf(f.gpa, f.account(), elem_place, refined);
                const explicit = if (spread) explicit_rest else explicit_one;
                if (explicit != .none) {
                    var two = [_]NodeId{ node, explicit };
                    node = if (refined == .none) explicit else try shapes.join(f.gpa, f.account(), f.env.places, cells, &two);
                }
                if (spread) {
                    // The rest: the same storage (a view), its contents the others.
                    const kids = try shapes.overPut(f.gpa, f.account(), Ids.none_int, Step.elem, node);
                    const rest = try shapes.node(f.gpa, f.account(), list_place, (try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, v.node)), kids);
                    var k = try f.kappaSet(v.kappa, rest, try f.env.conds.kappaOf(f.gpa, f.env.charge, f.env.view(), v.kappa, try shapes.leaf(f.gpa, f.account(), list_place, (try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, v.node))), false));
                    k = try f.kappaSetElem(k, node, split_kappa);
                    const rest_pat = f.data(item.int()).lhs;
                    // A variable binds here (its holder is marked below); a nested
                    // pattern goes on `bind`'s stack.
                    if (rest_pat != none and f.tag(rest_pat) == .pat_var) try f.bind(rest_pat, .{ .node = rest, .kappa = k }, point) else try deferred.append(f.gpa, .{ .pat = rest_pat, .value = .{ .node = rest, .kappa = k } });
                    // The rest holds every position but the taken ones.
                    if (taken_split != .none and rest_pat != none and f.tag(rest_pat) == .pat_var) {
                        const h = f.binding[f.data(rest_pat).lhs];
                        if (h != none) f.holders.items[h].taken = .{ .split = taken_split, .pos = none - 1, .explicit = if (explicit_rest == .none) SetId.none else (try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, explicit_rest)) };
                    }
                    continue;
                }
                if (f.tag(item.int()) == .pat_var) try f.bind(item.int(), .{ .node = node, .kappa = contents_kappa }, point) else try deferred.append(f.gpa, .{ .pat = item.int(), .value = .{ .node = node, .kappa = contents_kappa } });
                if (taken_split != .none and f.tag(item.int()) == .pat_var) {
                    const h = f.binding[f.data(item.int()).lhs];
                    if (h != none) f.holders.items[h].taken = .{ .split = taken_split, .pos = position, .explicit = explicit_cells };
                }
                position += 1;
            }
        }
    };
}
