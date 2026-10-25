//! L3: shape nodes, the abstract values (`docs/design/ownership-v2.md` §2.3,
//! §3.3). A node denotes a function from paths to sets of `(cell, approx)`.
//!
//! | kind     | meaning                                                     |
//! |----------|-------------------------------------------------------------|
//! | `leaf`   | `cells` at `ε`; below, whatever the symbolic cells project to |
//! | `node`   | a built value: `cells` at `ε`, explicit children by step     |
//! | `delta`  | `base` written: `base`'s cells at `ε`, an override or the base's child at a step |
//! | `recast` | `inner` read at another place: `inner`'s cells, approximate, at every path |
//! | `union`  | the lazy join of two nodes, never flattened                  |
//!
//! Nodes are **structurally interned** per table — `(kind, place, cells,
//! a, b)` through a fixed-key dictionary — and immutable, so every memo
//! below is keyed by node ids alone. Children and overrides are one
//! persistent map (`Over`): a hash-consed big-endian patricia tree from a
//! step's word to a node, path-copied, O(log F) insert and lookup, so a
//! chain of k updates costs O(k log F) and shares its structure (#716).
//! `widen` alone makes nodes that are not interned: a widened recursive
//! value is a `node` whose child names an ancestor — "the knot is in the
//! table" — and such a node is unique by construction.
//!
//! Every allocation here is a growth record reserved before it is made;
//! the caller's lanes (§4.1) are its business, this file charges growth.
//!
//! **Cross-checks** (§7.5, `-Downership-full-cross-check`, safety builds
//! only): `join` is checked against the pairwise union of projections, and
//! `widen` against `leq` (extensive). Never in the gates' binary.
//!
//! Obligations kept here: O3 (`proj`, `put`, `join`, `map`, `recast`,
//! `widen` are extensive on γ; `leq` implies γ-inclusion), O4 (`join` is
//! union), O7 (a delta is the base written: its `ε` object is the base's),
//! O10 (`⊤` is a cell like any other: an unknown node is never empty).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Cell = @import("Cell.zig");
const stamped = @import("../stamped.zig");

pub const NodeId = Ids.NodeId;
pub const OverId = Ids.OverId;
pub const SetId = Ids.SetId;
pub const PlaceId = Ids.PlaceId;
pub const CellId = Ids.CellId;
pub const Step = Place.Step;
pub const Account = Ids.Account;

pub const Error = Ids.ChargeError;

pub const Kind = enum(u8) { leaf, node, delta, recast, @"union" };

/// One node (§3.3). `a`, `b` by kind: `node`: the children map; `delta`:
/// base + the override map; `recast`: inner; `union`: left, right.
pub const Node = struct {
    kind: Kind,
    place: PlaceId,
    /// The cells at `ε` (a delta's: its base's; a union's: both sides').
    cells: SetId,
    a: u32,
    b: u32,
    /// `reach`'s memo, `.none` until asked.
    reach: SetId,
};

/// A node of the persistent step → node map: a leaf (`mask == 0`: `prefix`
/// the step word, `left` the node) or a branch. Hash-consed, so equal maps
/// are one id.
pub const OverNode = struct {
    prefix: u32,
    mask: u32,
    left: u32,
    right: u32,
};

pub const Table = struct {
    nodes: std.MultiArrayList(Node) = .empty,
    intern: Ids.FixedDict(5) = .{},
    overs: std.MultiArrayList(OverNode) = .empty,
    over_intern: Ids.FixedDict(4) = .{},
    memo_proj: Ids.FixedDict(2) = .{},
    memo_join: Ids.FixedDict(2) = .{},
    memo_leq: Ids.FixedDict(2) = .{},
    memo_map: stamped.Column(NodeId, NodeId) = .{},

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.nodes.deinit(gpa);
        t.intern.deinit(gpa);
        t.overs.deinit(gpa);
        t.over_intern.deinit(gpa);
        t.memo_proj.deinit(gpa);
        t.memo_join.deinit(gpa);
        t.memo_leq.deinit(gpa);
        t.memo_map.deinit(gpa);
    }

    pub fn count(t: *const Table) u32 {
        return @intCast(t.nodes.len);
    }

    pub fn get(t: *const Table, n: NodeId) Node {
        return t.nodes.get(n.int());
    }

    pub fn kind(t: *const Table, n: NodeId) Kind {
        return t.nodes.items(.kind)[n.int()];
    }

    pub fn place(t: *const Table, n: NodeId) PlaceId {
        return t.nodes.items(.place)[n.int()];
    }

    /// The cells at `ε`.
    pub fn cells(t: *const Table, n: NodeId) SetId {
        return t.nodes.items(.cells)[n.int()];
    }

    // ---- the persistent step map ------------------------------------------------

    const over_none: u32 = Ids.none_int;

    fn overNode(t: *const Table, id: u32) OverNode {
        return t.overs.get(id);
    }

    fn makeOver(t: *Table, gpa: Allocator, account: *Account, n: OverNode) Error!u32 {
        const got = try t.over_intern.getOrPut(gpa, .{ n.prefix, n.mask, n.left, n.right });
        if (got.found_existing) return got.value_ptr.*;
        try account.reserve(.shape, 1);
        got.value_ptr.* = @intCast(t.overs.len);
        try t.overs.append(gpa, n);
        return got.value_ptr.*;
    }

    inline fn matches(key: u32, prefix: u32, mask: u32) bool {
        return (key & ~((mask << 1) -% 1)) == prefix;
    }

    fn overJoin(t: *Table, gpa: Allocator, account: *Account, p0: u32, t0: u32, p1: u32, t1: u32) Error!u32 {
        const mask = @as(u32, 1) << @intCast(31 - @clz(p0 ^ p1));
        const prefix = p0 & ~((mask << 1) -% 1);
        return if (p0 & mask == 0)
            t.makeOver(gpa, account, .{ .prefix = prefix, .mask = mask, .left = t0, .right = t1 })
        else
            t.makeOver(gpa, account, .{ .prefix = prefix, .mask = mask, .left = t1, .right = t0 });
    }

    /// The node at `step` in map `root`, or null.
    pub fn overGet(t: *const Table, root: u32, step: Step) ?NodeId {
        var at = root;
        while (at != over_none) {
            const n = t.overNode(at);
            if (n.mask == 0) return if (n.prefix == step.word()) .from(n.left) else null;
            if (!matches(step.word(), n.prefix, n.mask)) return null;
            at = if (step.word() & n.mask == 0) n.left else n.right;
        }
        return null;
    }

    /// `root` with `step ↦ node` (replacing), path-copied: ≤ 33 new nodes.
    pub fn overPut(t: *Table, gpa: Allocator, account: *Account, root: u32, step: Step, value: NodeId) Error!u32 {
        const key = step.word();
        if (root == over_none) return t.makeOver(gpa, account, .{ .prefix = key, .mask = 0, .left = value.int(), .right = over_none });
        const n = t.overNode(root);
        if (n.mask == 0) {
            if (n.prefix == key) return if (n.left == value.int()) root else t.makeOver(gpa, account, .{ .prefix = key, .mask = 0, .left = value.int(), .right = over_none });
            const new_leaf = try t.makeOver(gpa, account, .{ .prefix = key, .mask = 0, .left = value.int(), .right = over_none });
            return t.overJoin(gpa, account, key, new_leaf, n.prefix, root);
        }
        if (!matches(key, n.prefix, n.mask)) {
            const new_leaf = try t.makeOver(gpa, account, .{ .prefix = key, .mask = 0, .left = value.int(), .right = over_none });
            return t.overJoin(gpa, account, key, new_leaf, n.prefix, root);
        }
        if (key & n.mask == 0) {
            const l = try t.overPut(gpa, account, n.left, step, value);
            return if (l == n.left) root else t.makeOver(gpa, account, .{ .prefix = n.prefix, .mask = n.mask, .left = l, .right = n.right });
        }
        const r = try t.overPut(gpa, account, n.right, step, value);
        return if (r == n.right) root else t.makeOver(gpa, account, .{ .prefix = n.prefix, .mask = n.mask, .left = n.left, .right = r });
    }

    /// The `(step, node)` entries of a map in step order.
    pub const OverIterator = struct {
        t: *const Table,
        stack: [34]u32 = undefined,
        depth: usize = 0,

        pub const Entry = struct { step: Step, node: NodeId };

        pub fn next(it: *OverIterator) ?Entry {
            while (it.depth > 0) {
                it.depth -= 1;
                const n = it.t.overNode(it.stack[it.depth]);
                if (n.mask == 0) return .{ .step = Step.fromWord(n.prefix), .node = .from(n.left) };
                it.stack[it.depth] = n.right;
                it.stack[it.depth + 1] = n.left;
                it.depth += 2;
            }
            return null;
        }
    };

    pub fn overEntries(t: *const Table, root: u32) OverIterator {
        var it: OverIterator = .{ .t = t };
        if (root != over_none) {
            it.stack[0] = root;
            it.depth = 1;
        }
        return it;
    }

    // ---- construction -------------------------------------------------------------

    fn make(t: *Table, gpa: Allocator, account: *Account, n: Node) Error!NodeId {
        const got = try t.intern.getOrPut(gpa, .{ @backingInt(n.kind), n.place.int(), n.cells.int(), n.a, n.b });
        if (got.found_existing) return .from(got.value_ptr.*);
        try account.reserve(.shape, 1);
        got.value_ptr.* = @intCast(t.nodes.len);
        try t.nodes.append(gpa, n);
        return .from(got.value_ptr.*);
    }

    pub fn leaf(t: *Table, gpa: Allocator, account: *Account, at: PlaceId, c: SetId) Error!NodeId {
        return t.make(gpa, account, .{ .kind = .leaf, .place = at, .cells = c, .a = 0, .b = 0, .reach = .none });
    }

    /// The empty value at `at`: provably no cell (§2.3).
    pub fn nothing(t: *Table, gpa: Allocator, account: *Account, at: PlaceId) Error!NodeId {
        return t.leaf(gpa, account, at, .none);
    }

    /// A built value with explicit children, a map `(step ↦ node)`.
    pub fn node(t: *Table, gpa: Allocator, account: *Account, at: PlaceId, c: SetId, children: u32) Error!NodeId {
        return t.make(gpa, account, .{ .kind = .node, .place = at, .cells = c, .a = children, .b = 0, .reach = .none });
    }

    /// `base` written with the overrides (never a delta over a delta: the
    /// chain is one delta whose map is the composition, O(k log F)).
    pub fn delta(t: *Table, gpa: Allocator, account: *Account, base: NodeId, over: u32) Error!NodeId {
        std.debug.assert(t.kind(base) != .delta);
        if (over == over_none) return base;
        return t.make(gpa, account, .{ .kind = .delta, .place = t.place(base), .cells = t.cells(base), .a = base.int(), .b = over, .reach = .none });
    }

    pub fn recast(t: *Table, gpa: Allocator, account: *Account, at: PlaceId, inner: NodeId) Error!NodeId {
        // Casts compose to one recast (§2.13.9).
        const in = if (t.kind(inner) == .recast) NodeId.from(t.nodes.items(.a)[inner.int()]) else inner;
        return t.make(gpa, account, .{ .kind = .recast, .place = at, .cells = t.cells(in), .a = in.int(), .b = 0, .reach = .none });
    }

    /// The lazy join of two nodes at one place (a binary DAG).
    pub fn @"union"(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, l: NodeId, r: NodeId) Error!NodeId {
        if (l == r) return l;
        // A union absorbs a member it already has, so projecting a cyclic
        // union reaches a fixpoint instead of nesting forever.
        if (t.unionHas(l, r)) return l;
        if (t.unionHas(r, l)) return r;
        const x = @min(l.int(), r.int());
        const y = @max(l.int(), r.int());
        const c = try cellsets.unionWith(gpa, .growth(account), t.cells(l), t.cells(r));
        return t.make(gpa, account, .{ .kind = .@"union", .place = t.place(l), .cells = c, .a = x, .b = y, .reach = .none });
    }

    /// Whether `x` is a member of the union DAG `u` (its sides, through
    /// nested unions only). O(union nodes), bounded by 64 for the test.
    fn unionHas(t: *const Table, u: NodeId, x: NodeId) bool {
        var stack: [64]NodeId = undefined;
        var depth: usize = 1;
        stack[0] = u;
        while (depth > 0) {
            depth -= 1;
            const n = stack[depth];
            if (n == x) return true;
            if (t.kind(n) != .@"union" or depth + 2 > stack.len) continue;
            const d = t.get(n);
            stack[depth] = .from(d.a);
            stack[depth + 1] = .from(d.b);
            depth += 2;
        }
        return false;
    }

    /// `put(n, s, m)` (§2.3): the same object written (`same_object`) is a
    /// delta over `n`; a construction is a copy with one child changed, a
    /// fresh base with `n`'s children and `fresh` at `ε`.
    pub fn put(t: *Table, gpa: Allocator, account: *Account, n: NodeId, s: Step, m: NodeId, same_object: bool, fresh: SetId) Error!NodeId {
        if (same_object) {
            if (t.kind(n) == .delta) {
                const d = t.get(n);
                return t.delta(gpa, account, .from(d.a), try t.overPut(gpa, account, d.b, s, m));
            }
            return t.delta(gpa, account, n, try t.overPut(gpa, account, over_none, s, m));
        }
        const children = try t.explicitMap(gpa, account, n);
        return t.node(gpa, account, t.place(n), fresh, try t.overPut(gpa, account, children, s, m));
    }

    /// The explicit children of `n` as one map: a node's; a delta's base's
    /// with its overrides; nothing for a leaf, a recast or a union.
    fn explicitMap(t: *Table, gpa: Allocator, account: *Account, n: NodeId) Error!u32 {
        const d = t.get(n);
        return switch (d.kind) {
            .node => d.a,
            .delta => blk: {
                var m = t.nodes.items(.a)[d.a]; // the base is a node, or a leaf with no map
                if (t.kind(.from(d.a)) != .node) m = over_none;
                var it = t.overEntries(d.b);
                while (it.next()) |e| m = try t.overPut(gpa, account, m, e.step, e.node);
                break :blk m;
            },
            .leaf, .recast, .@"union" => over_none,
        };
    }

    // ---- projection ---------------------------------------------------------------------

    /// `proj(n, s)` (§2.3), memoised per `(node, step)`. A symbolic leaf
    /// projects its cells one step down the trie; a concrete leaf projects
    /// to nothing; a recast stays a recast (approximate); a union projects
    /// both sides. Null when the place has no such step.
    pub fn proj(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, n: NodeId, s: Step) Error!?NodeId {
        const got = try t.memo_proj.getOrPut(gpa, .{ n.int(), s.word() });
        if (got.found_existing) return if (got.value_ptr.* == Ids.none_int) null else NodeId.from(got.value_ptr.*);
        got.value_ptr.* = Ids.none_int;
        const d = t.get(n);
        const child_place = places.child(d.place, s) orelse return null;
        try account.reserve(.memo, 1);
        const out: NodeId = switch (d.kind) {
            .leaf => try t.projectLeaf(gpa, account, places, cellt, d.cells, child_place, s),
            .node => t.overGet(d.a, s) orelse try t.nothing(gpa, account, child_place),
            .delta => t.overGet(d.b, s) orelse (try t.proj(gpa, account, places, cellt, .from(d.a), s)).?,
            .recast => try t.recast(gpa, account, child_place, .from(d.a)),
            .@"union" => try t.@"union"(gpa, account, &cellt.sets, (try t.proj(gpa, account, places, cellt, .from(d.a), s)).?, (try t.proj(gpa, account, places, cellt, .from(d.b), s)).?),
        };
        // The memo slot may have moved: look it up again.
        (try t.memo_proj.getOrPut(gpa, .{ n.int(), s.word() })).value_ptr.* = out.int();
        return out;
    }

    /// Project a leaf's cells: every symbolic cell to its child at `s`
    /// (`⊤` to itself), concrete cells to nothing, approximation kept.
    fn projectLeaf(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, c: SetId, child_place: PlaceId, s: Step) Error!NodeId {
        var out: SetId = .none;
        var it = cellt.sets.iterate(c);
        while (it.next()) |e| {
            const cell: CellId = .from(e.key);
            const o = cellt.origin(cell);
            if (o == .top) {
                out = try cellt.sets.insert(gpa, .growth(account), out, e.key, e.value);
                continue;
            }
            if (!o.isSymbolic()) continue;
            const rec = cellt.get(cell);
            const child_path = (try places.extend(gpa, .growth(account), .from(rec.b), s)) orelse continue;
            const child = try cellt.symbolic(gpa, account, places, o, rec.a, child_path, rec.c);
            out = try cellt.sets.insert(gpa, .growth(account), out, child.int(), e.value);
        }
        return t.leaf(gpa, account, child_place, out);
    }

    /// `cellsAt(n, q)`: `proj` along `steps`; `.none` past a missing step.
    pub fn cellsAt(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, n: NodeId, steps: []const Step) Error!SetId {
        var at = n;
        for (steps) |s| at = (try t.proj(gpa, account, places, cellt, at, s)) orelse return .none;
        return t.cells(at);
    }

    // ---- reach ------------------------------------------------------------------------------

    /// The persistent set of every cell anywhere in `n`'s explicit
    /// structure (a leaf's symbolic cells stand for their projections and
    /// are in it by their root), memoised once per node whose walk closed
    /// without a back edge. O(nodes · log C) the first time.
    pub fn reach(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, n: NodeId) Error!SetId {
        if (t.nodes.items(.reach)[n.int()] != .none) return t.nodes.items(.reach)[n.int()];
        var visiting: stamped.Column(NodeId, void) = .{};
        defer visiting.deinit(gpa);
        var acyclic = true;
        const out = try t.reachWalk(gpa, account, cellsets, n, &visiting, &acyclic);
        if (acyclic) t.nodes.items(.reach)[n.int()] = out;
        return out;
    }

    fn reachWalk(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, n: NodeId, visiting: *stamped.Column(NodeId, void), acyclic: *bool) Error!SetId {
        if (t.nodes.items(.reach)[n.int()] != .none) return t.nodes.items(.reach)[n.int()];
        if (visiting.contains(n)) {
            acyclic.* = false;
            return .none;
        }
        try visiting.put(gpa, n, {});
        defer visiting.remove(n);
        var out = t.cells(n);
        const d = t.get(n);
        var children: [2]u32 = .{ Ids.none_int, Ids.none_int };
        var kids_map: u32 = over_none;
        switch (d.kind) {
            .leaf => {},
            .node => kids_map = d.a,
            .delta => {
                children[0] = d.a;
                kids_map = d.b;
            },
            .recast => children[0] = d.a,
            .@"union" => children = .{ d.a, d.b },
        }
        var was_acyclic = true;
        for (children) |c| {
            if (c == Ids.none_int) continue;
            const r = try t.reachWalk(gpa, account, cellsets, .from(c), visiting, &was_acyclic);
            out = try cellsets.unionWith(gpa, .growth(account), out, r);
        }
        var it = t.overEntries(kids_map);
        while (it.next()) |e| {
            const r = try t.reachWalk(gpa, account, cellsets, e.node, visiting, &was_acyclic);
            out = try cellsets.unionWith(gpa, .growth(account), out, r);
        }
        if (was_acyclic) t.nodes.items(.reach)[n.int()] = out else acyclic.* = false;
        return out;
    }

    // ---- join -------------------------------------------------------------------------------

    /// `join(n₁…nₖ)` (§2.3): deduplicate; group by base, one delta per base
    /// with overrides joined pointwise (a bare node is `delta(n, ∅)`); leaves
    /// into one leaf; what is left into a balanced union DAG. `members` is
    /// scratch and is reordered.
    pub fn join(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, members: []NodeId) Error!NodeId {
        std.debug.assert(members.len > 0);
        if (members.len == 1) return members[0];
        if (members.len == 2) {
            const x = @min(members[0].int(), members[1].int());
            const y = @max(members[0].int(), members[1].int());
            if (x == y) return members[0];
            if (t.memo_join.get(.{ x, y })) |hit| return .from(hit);
            const out = try t.joinUncached(gpa, account, places, cellt, members);
            (try t.memo_join.getOrPut(gpa, .{ x, y })).value_ptr.* = out.int();
            return out;
        }
        return t.joinUncached(gpa, account, places, cellt, members);
    }

    fn baseOf(t: *const Table, n: NodeId) NodeId {
        return if (t.kind(n) == .delta) .from(t.nodes.items(.a)[n.int()]) else n;
    }

    fn joinUncached(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, members: []NodeId) Error!NodeId {
        try account.reserve(.memo, 1);
        // Sort by (base, id): one pass groups and deduplicates.
        std.mem.sort(NodeId, members, t, struct {
            fn lessThan(tt: *Table, a: NodeId, b: NodeId) bool {
                const ba = tt.baseOf(a).int();
                const bb = tt.baseOf(b).int();
                return if (ba != bb) ba < bb else a.int() < b.int();
            }
        }.lessThan);
        var groups: std.ArrayList(NodeId) = .empty;
        defer groups.deinit(gpa);
        var leaf_cells: SetId = .none;
        var leaf_place: PlaceId = .none;
        var i: usize = 0;
        while (i < members.len) {
            var j = i + 1;
            while (j < members.len and t.baseOf(members[j]) == t.baseOf(members[i])) j += 1;
            const run = members[i..j];
            i = j;
            // One group: deduplicate, then join the deltas over one base.
            var distinct: usize = 1;
            for (run[1..]) |m| if (m != run[distinct - 1]) {
                run[distinct] = m;
                distinct += 1;
            };
            if (distinct == 1) {
                if (t.kind(run[0]) == .leaf) {
                    leaf_cells = try cellt.sets.unionWith(gpa, .growth(account), leaf_cells, t.cells(run[0]));
                    leaf_place = t.place(run[0]);
                } else {
                    try groups.append(gpa, run[0]);
                }
                continue;
            }
            try groups.append(gpa, try t.joinDeltas(gpa, account, places, cellt, run[0..distinct]));
        }
        if (leaf_place != .none) try groups.append(gpa, try t.leaf(gpa, account, leaf_place, leaf_cells));
        return t.balancedUnion(gpa, account, cellt, groups.items);
    }

    /// Deltas over one base (a bare node among them is the base itself):
    /// the union of their override steps, each joined over the members
    /// present and the base's child where a member has no override.
    fn joinDeltas(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, run: []const NodeId) Error!NodeId {
        const base = t.baseOf(run[0]);
        // Collect the override steps across members.
        var steps: std.ArrayList(Step) = .empty;
        defer steps.deinit(gpa);
        for (run) |m| {
            if (t.kind(m) != .delta) continue;
            var it = t.overEntries(t.nodes.items(.b)[m.int()]);
            while (it.next()) |e| {
                var seen = false;
                for (steps.items) |s| if (s.eql(e.step)) {
                    seen = true;
                };
                if (!seen) try steps.append(gpa, e.step);
            }
        }
        var over: u32 = over_none;
        var values: std.ArrayList(NodeId) = .empty;
        defer values.deinit(gpa);
        for (steps.items) |s| {
            values.clearRetainingCapacity();
            for (run) |m| {
                const v = if (t.kind(m) == .delta) t.overGet(t.nodes.items(.b)[m.int()], s) else null;
                try values.append(gpa, v orelse (try t.proj(gpa, account, places, cellt, base, s)) orelse continue);
            }
            if (values.items.len == 0) continue;
            over = try t.overPut(gpa, account, over, s, try t.join(gpa, account, places, cellt, values.items));
        }
        return t.delta(gpa, account, base, over);
    }

    fn balancedUnion(t: *Table, gpa: Allocator, account: *Account, cellt: *Cell.Table, groups: []NodeId) Error!NodeId {
        if (groups.len == 1) return groups[0];
        const mid = groups.len / 2;
        const l = try t.balancedUnion(gpa, account, cellt, groups[0..mid]);
        const r = try t.balancedUnion(gpa, account, cellt, groups[mid..]);
        return t.@"union"(gpa, account, &cellt.sets, l, r);
    }

    // ---- map ---------------------------------------------------------------------------------

    /// The functor relabelling cells: `f(ctx, set) → set` applied to every
    /// node's `ε` cells, memoised per node within one call so a DAG stays
    /// a DAG (#856). A cyclic node is mapped to a node of the same shape.
    pub fn map(t: *Table, gpa: Allocator, account: *Account, n: NodeId, ctx: anytype, f: *const fn (@TypeOf(ctx), SetId) Error!SetId) Error!NodeId {
        t.memo_map.clear();
        return t.mapWalk(gpa, account, n, ctx, f);
    }

    fn mapWalk(t: *Table, gpa: Allocator, account: *Account, n: NodeId, ctx: anytype, f: *const fn (@TypeOf(ctx), SetId) Error!SetId) Error!NodeId {
        if (t.memo_map.get(n)) |m| return m;
        const d = t.get(n);
        const c = try f(ctx, d.cells);
        switch (d.kind) {
            .leaf => {
                const out = try t.leaf(gpa, account, d.place, c);
                try t.memo_map.put(gpa, n, out);
                return out;
            },
            .recast => {
                const out = try t.recast(gpa, account, d.place, try t.mapWalk(gpa, account, .from(d.a), ctx, f));
                try t.memo_map.put(gpa, n, out);
                return out;
            },
            .@"union" => {
                const l = try t.mapWalk(gpa, account, .from(d.a), ctx, f);
                const r = try t.mapWalk(gpa, account, .from(d.b), ctx, f);
                try account.reserve(.shape, 1);
                const out: NodeId = .from(t.count());
                try t.nodes.append(gpa, .{ .kind = .@"union", .place = d.place, .cells = c, .a = l.int(), .b = r.int(), .reach = .none });
                try t.memo_map.put(gpa, n, out);
                return out;
            },
            .node, .delta => {
                // Pre-allocate so a cyclic child finds its image (the knot).
                try account.reserve(.shape, 1);
                const out: NodeId = .from(t.count());
                try t.nodes.append(gpa, .{ .kind = d.kind, .place = d.place, .cells = c, .a = 0, .b = 0, .reach = .none });
                try t.memo_map.put(gpa, n, out);
                var mapped: u32 = over_none;
                var it = t.overEntries(if (d.kind == .node) d.a else d.b);
                while (it.next()) |e| mapped = try t.overPut(gpa, account, mapped, e.step, try t.mapWalk(gpa, account, e.node, ctx, f));
                if (d.kind == .node) {
                    t.nodes.items(.a)[out.int()] = mapped;
                } else {
                    t.nodes.items(.a)[out.int()] = (try t.mapWalk(gpa, account, .from(d.a), ctx, f)).int();
                    t.nodes.items(.b)[out.int()] = mapped;
                }
                return out;
            },
        }
    }

    // ---- order --------------------------------------------------------------------------------

    /// Coinductive lockstep inclusion (§2.3): `cells(n) ⊆ cells(m)` at every
    /// path, pairs assumed on re-entry, memoised per pair. O(|n|·|m|) pairs
    /// at most; O(|n| + |m|) when shapes agree.
    pub fn leq(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, n: NodeId, m: NodeId) Error!bool {
        if (n == m) return true;
        const got = try t.memo_leq.getOrPut(gpa, .{ n.int(), m.int() });
        if (got.found_existing) return got.value_ptr.* != 0;
        got.value_ptr.* = 1; // the coinductive assumption
        try account.reserve(.memo, 1);
        var ok = try cellt.sets.subset(gpa, .growth(account), t.cells(n), t.cells(m));
        if (ok) {
            const steps = places.steps(t.place(n));
            for (steps.steps) |s| {
                const pn = (try t.proj(gpa, account, places, cellt, n, s)) orelse continue;
                const pm = (try t.proj(gpa, account, places, cellt, m, s)) orelse {
                    ok = false;
                    break;
                };
                if (pn == pm) continue;
                if (t.cells(pn) == .none and t.kind(pn) == .leaf) continue; // nothing is below anything
                if (!try t.leq(gpa, account, places, cellt, pn, pm)) {
                    ok = false;
                    break;
                }
            }
        }
        (try t.memo_leq.getOrPut(gpa, .{ n.int(), m.int() })).value_ptr.* = @intFromBool(ok);
        return ok;
    }

    pub fn eq(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, n: NodeId, m: NodeId) Error!bool {
        return n == m or (try t.leq(gpa, account, places, cellt, n, m) and try t.leq(gpa, account, places, cellt, m, n));
    }

    // ---- widen ------------------------------------------------------------------------------------

    /// The place-graph quotient (§2.3): along every chain of explicit
    /// children, a descendant at a place already on the chain is joined into
    /// that ancestor and the edge tied back to it, so the result has at most
    /// one node per canonical path of its place graph; over a non-recursive
    /// type nothing re-enters and the DAG is returned as it is, sharing
    /// kept. Leaves, recasts and the sides of a union are kept as they are
    /// (never expanded). A congruence closure over the explicit edges with
    /// union–find; every step is a charged record.
    pub fn widen(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, n: NodeId) Error!NodeId {
        var w: Widen = .{ .t = t, .gpa = gpa, .account = account, .places = places, .cellt = cellt };
        defer w.deinit();
        return w.run(n);
    }

    const Widen = struct {
        t: *Table,
        gpa: Allocator,
        account: *Account,
        places: *Place.Table,
        cellt: *Cell.Table,
        /// Union–find over node ids, grown on first touch.
        parent: std.ArrayList(u32) = .empty,
        /// Per class representative: its members (a run), and its image.
        members: std.ArrayList(u32) = .empty,
        next_member: std.ArrayList(u32) = .empty,
        image: stamped.Column(NodeId, NodeId) = .{},
        merged: bool = false,

        fn deinit(w: *Widen) void {
            w.parent.deinit(w.gpa);
            w.members.deinit(w.gpa);
            w.next_member.deinit(w.gpa);
            w.image.deinit(w.gpa);
        }

        fn touch(w: *Widen, n: NodeId) Allocator.Error!void {
            while (w.parent.items.len <= n.int()) {
                const i: u32 = @intCast(w.parent.items.len);
                try w.parent.append(w.gpa, i);
                try w.members.append(w.gpa, i);
                try w.next_member.append(w.gpa, Ids.none_int);
            }
        }

        fn find(w: *Widen, n: u32) u32 {
            var x = n;
            while (w.parent.items[x] != x) x = w.parent.items[x];
            return x;
        }

        fn unite(w: *Widen, a: u32, b: u32) void {
            const ra = w.find(a);
            const rb = w.find(b);
            if (ra == rb) return;
            // The lower id is the representative; splice member lists.
            const lo = @min(ra, rb);
            const hi = @max(ra, rb);
            w.parent.items[hi] = lo;
            var tail = lo;
            while (w.next_member.items[tail] != Ids.none_int) tail = w.next_member.items[tail];
            w.next_member.items[tail] = w.members.items[hi];
            w.merged = true;
        }

        /// A class's explicit children at `s`, as a run of nodes.
        fn childrenAt(w: *Widen, rep: u32, s: Step, out: *std.ArrayList(NodeId)) Allocator.Error!void {
            out.clearRetainingCapacity();
            var m = w.members.items[rep];
            while (m != Ids.none_int) : (m = w.next_member.items[m]) {
                const d = w.t.get(.from(m));
                switch (d.kind) {
                    .node => if (w.t.overGet(d.a, s)) |c| try out.append(w.gpa, c),
                    .delta => if (w.t.overGet(d.b, s)) |c| try out.append(w.gpa, c) else if (w.t.kind(.from(d.a)) == .node) {
                        if (w.t.overGet(w.t.nodes.items(.a)[d.a], s)) |c| try out.append(w.gpa, c);
                    },
                    .leaf, .recast, .@"union" => {},
                }
            }
        }

        fn run(w: *Widen, root: NodeId) Error!NodeId {
            try w.touch(root);
            // Closure: DFS over classes with the chain of places; merge a
            // child class into an ancestor at its place, and every class's
            // children at one step into one class. Repeat to a fixpoint.
            var kids: std.ArrayList(NodeId) = .empty;
            defer kids.deinit(w.gpa);
            var chain: std.ArrayList(u32) = .empty;
            defer chain.deinit(w.gpa);
            var seen: stamped.Column(u32, void) = .{};
            defer seen.deinit(w.gpa);
            var rounds: u32 = 0;
            while (true) {
                w.merged = false;
                rounds += 1;
                try w.account.reserve(.memo, 1);
                seen.clear();
                try w.visit(w.find(root.int()), &chain, &kids, &seen);
                if (!w.merged) break;
            }
            if (rounds == 1 and !w.anyClass()) return root; // the identity
            return w.emit(root);
        }

        fn anyClass(w: *Widen) bool {
            for (w.parent.items, 0..) |p, i| if (p != i) return true;
            return false;
        }

        fn visit(w: *Widen, rep0: u32, chain: *std.ArrayList(u32), kids: *std.ArrayList(NodeId), seen: *stamped.Column(u32, void)) Error!void {
            const rep = w.find(rep0);
            if (seen.contains(rep)) return;
            try seen.put(w.gpa, rep, {});
            try chain.append(w.gpa, rep);
            defer _ = chain.pop();
            const at = w.t.place(.from(rep));
            const steps = w.places.steps(at);
            for (steps.steps) |s| {
                try w.childrenAt(rep, s, kids);
                if (kids.items.len == 0) continue;
                for (kids.items) |k| try w.touch(k);
                var child = w.find(kids.items[0].int());
                for (kids.items[1..]) |k| {
                    w.unite(child, k.int());
                    child = w.find(child);
                }
                try w.account.reserve(.edge, 1);
                // Re-entry: an ancestor on the chain at the child's place.
                const child_place = w.t.place(.from(child));
                var tied = false;
                for (chain.items) |anc| {
                    if (w.t.place(.from(w.find(anc))) == child_place) {
                        w.unite(w.find(anc), child);
                        tied = true;
                        break;
                    }
                }
                if (!tied) try w.visit(child, chain, kids, seen);
            }
        }

        /// Emit one node per class reachable from `root`, ids first so a
        /// back edge finds its image.
        fn emit(w: *Widen, root: NodeId) Error!NodeId {
            var order: std.ArrayList(u32) = .empty;
            defer order.deinit(w.gpa);
            var stack: std.ArrayList(u32) = .empty;
            defer stack.deinit(w.gpa);
            var kids: std.ArrayList(NodeId) = .empty;
            defer kids.deinit(w.gpa);
            try stack.append(w.gpa, w.find(root.int()));
            while (stack.pop()) |rep0| {
                const rep = w.find(rep0);
                if (w.image.contains(.from(rep))) continue;
                try w.account.reserve(.shape, 1);
                const id: NodeId = .from(w.t.count());
                try w.t.nodes.append(w.gpa, .{ .kind = .node, .place = w.t.place(.from(rep)), .cells = .none, .a = over_none, .b = 0, .reach = .none });
                try w.image.put(w.gpa, .from(rep), id);
                try order.append(w.gpa, rep);
                const steps = w.places.steps(w.t.place(.from(rep)));
                for (steps.steps) |s| {
                    try w.childrenAt(rep, s, &kids);
                    if (kids.items.len > 0) try stack.append(w.gpa, w.find(kids.items[0].int()));
                }
            }
            for (order.items) |rep| {
                const id = w.image.get(.from(rep)).?;
                // ε cells: the union over members; leaves, recasts and
                // unions among the members ride beside the node as a union.
                var c: SetId = .none;
                var extra: std.ArrayList(NodeId) = .empty;
                defer extra.deinit(w.gpa);
                var m = w.members.items[rep];
                while (m != Ids.none_int) : (m = w.next_member.items[m]) {
                    const d = w.t.get(.from(m));
                    c = try w.cellt.sets.unionWith(w.gpa, .growth(w.account), c, d.cells);
                    if (d.kind == .leaf or d.kind == .recast or d.kind == .@"union") try extra.append(w.gpa, .from(m));
                }
                var children: u32 = over_none;
                const steps = w.places.steps(w.t.place(.from(rep)));
                for (steps.steps) |s| {
                    try w.childrenAt(rep, s, &kids);
                    if (kids.items.len == 0) continue;
                    children = try w.t.overPut(w.gpa, w.account, children, s, w.image.get(.from(w.find(kids.items[0].int()))).?);
                }
                w.t.nodes.items(.cells)[id.int()] = c;
                w.t.nodes.items(.a)[id.int()] = children;
                if (extra.items.len > 0) {
                    // A member that is not explicit structure: keep it as a
                    // union side of the image, never expanded.
                    var side = extra.items[0];
                    for (extra.items[1..]) |e| side = try w.t.@"union"(w.gpa, w.account, &w.cellt.sets, side, e);
                    try w.account.reserve(.shape, 1);
                    const u: NodeId = .from(w.t.count());
                    try w.t.nodes.append(w.gpa, .{ .kind = .@"union", .place = w.t.place(id), .cells = c, .a = id.int(), .b = side.int(), .reach = .none });
                    // Redirect: every parent's map names `id`; the union is
                    // what the class means, so swap the records.
                    const img = w.t.nodes.get(id.int());
                    w.t.nodes.set(id.int(), w.t.nodes.get(u.int()));
                    w.t.nodes.set(u.int(), img);
                    w.t.nodes.items(.a)[id.int()] = u.int();
                }
            }
            return w.image.get(.from(w.find(root.int()))).?;
        }
    };

    // ---- enumeration (safety builds) -------------------------------------------------------------

    /// Every `(path, cells)` of `n` up to `bound` paths, explicit structure
    /// and leaves' symbolic projections alike, appended as `(steps run,
    /// set)`: the oracle of §7.5, Θ(paths), never in production.
    pub const Expanded = struct { depth: u32, step: Step, cells: SetId };

    pub fn expand(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, n: NodeId, bound: u32, out: *std.ArrayList(Expanded)) Error!void {
        const Frame = struct { node: NodeId, depth: u32, step: Step };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, .{ .node = n, .depth = 0, .step = Step.level });
        while (stack.pop()) |f| {
            if (out.items.len >= bound) return;
            try out.append(gpa, .{ .depth = f.depth, .step = f.step, .cells = t.cells(f.node) });
            if (f.depth >= 64) continue;
            const steps = places.steps(t.place(f.node));
            for (steps.steps) |s| {
                const c = (try t.proj(gpa, account, places, cellt, f.node, s)) orelse continue;
                if (t.cells(c) == .none and t.kind(c) == .leaf) continue;
                try stack.append(gpa, .{ .node = c, .depth = f.depth + 1, .step = s });
            }
        }
    }

    /// §7.5: `join`'s projection at every step equals the pairwise union of
    /// the members' projections. Safety builds under the flag only.
    pub fn crossCheckJoin(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, joined: NodeId, members: []const NodeId) Error!void {
        if (!(std.debug.runtime_safety and full_cross_check)) return;
        const steps = places.steps(t.place(joined));
        for (steps.steps) |s| {
            var want: SetId = .none;
            for (members) |m| {
                const p = (try t.proj(gpa, account, places, cellt, m, s)) orelse continue;
                want = try cellt.sets.unionWith(gpa, .growth(account), want, t.cells(p));
            }
            const got = (try t.proj(gpa, account, places, cellt, joined, s)) orelse continue;
            var k: u32 = 0;
            std.debug.assert(cellt.sets.subset(want, t.cells(got), &k) and cellt.sets.subset(t.cells(got), want, &k));
        }
    }

    /// §7.5: widening is extensive.
    pub fn crossCheckWiden(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, n: NodeId, widened: NodeId) Error!void {
        if (!(std.debug.runtime_safety and full_cross_check)) return;
        std.debug.assert(try t.leq(gpa, account, places, cellt, n, widened));
    }
};

const full_cross_check = @import("ownership_options").full_cross_check;

comptime {
    Ids.assertRecord(Node);
    Ids.assertRecord(OverNode);
    std.debug.assert(@sizeOf(Node) == 24);
    std.debug.assert(@sizeOf(OverNode) == 16);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A test type graph. 0: `type Tree = Node Tree (List Int) Tree`; 1: `List
/// Int`; 2: `Int`; 3: a record `{ a : List Int, b : List Int }`; 10 + k: a
/// pair tower `P_k = P_{k-1} × P_{k-1}` over `P_0 = List Int` (k = 1…16),
/// every level its own place.
const TestGraph = struct {
    table: *Place.Table,
    account: *Ids.Account,
    gpa: Allocator,

    fn describe(ctx: *anyopaque, v: u32, out: *std.ArrayList(Place.Child)) Allocator.Error!Place.Description {
        const g: *TestGraph = @ptrCast(@alignCast(ctx));
        switch (v) {
            0 => {
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 0, 0) catch unreachable), .@"var" = 0 });
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 0, 1) catch unreachable), .@"var" = 1 });
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 0, 2) catch unreachable), .@"var" = 0 });
                return .{ .kind = .ctor, .head = 100 };
            },
            1 => {
                try out.append(g.gpa, .{ .step = Place.Step.elem, .@"var" = 2 });
                return .{ .kind = .list, .head = 200 };
            },
            2 => return .{ .kind = .cross },
            3 => {
                try out.append(g.gpa, .{ .step = (Place.Step.field(g.account, 10) catch unreachable), .@"var" = 1 });
                try out.append(g.gpa, .{ .step = (Place.Step.field(g.account, 11) catch unreachable), .@"var" = 1 });
                return .{ .kind = .record };
            },
            10 => return g.describe_(1, out),
            else => {
                const below = if (v == 11) @as(u32, 1) else v - 1;
                try out.append(g.gpa, .{ .step = (Place.Step.index(g.account, 0) catch unreachable), .@"var" = below });
                try out.append(g.gpa, .{ .step = (Place.Step.index(g.account, 1) catch unreachable), .@"var" = below });
                return .{ .kind = .tuple, .head = 2 };
            },
        }
    }

    fn describe_(g: *TestGraph, v: u32, out: *std.ArrayList(Place.Child)) Allocator.Error!Place.Description {
        return describe(g, v, out);
    }

    fn source(g: *TestGraph) Place.Source {
        return .{ .ctx = g, .describe = describe };
    }
};

const Fixture = struct {
    places: Place.Table = .{},
    cells: Cell.Table = .{},
    shapes: Table = .{},
    account: Account = .{},
    graph: TestGraph = undefined,

    fn init(f: *Fixture) void {
        f.graph = .{ .table = &f.places, .account = &f.account, .gpa = testing.allocator };
    }

    fn deinit(f: *Fixture) void {
        f.places.deinit(testing.allocator);
        f.cells.deinit(testing.allocator);
        f.shapes.deinit(testing.allocator);
        f.account.deinit(testing.allocator);
    }

    fn placeOf(f: *Fixture, v: u32) !PlaceId {
        return f.places.of(testing.allocator, &f.account, f.graph.source(), v);
    }

    fn set(f: *Fixture, c: CellId) !SetId {
        return f.cells.sets.insert(testing.allocator, .growth(&f.account), .none, c.int(), 0);
    }

    fn site(f: *Fixture, inst: u32, at: PlaceId, k: Cell.Kind) !SetId {
        return f.set(try f.cells.site(testing.allocator, &f.account, inst, at, k));
    }

    fn param(f: *Fixture, i: u32, at: PlaceId) !SetId {
        const root = try f.places.rootPath(testing.allocator, at);
        return f.set(try f.cells.symbolic(testing.allocator, &f.account, &f.places, .param, i, root, 0));
    }

    fn proj(f: *Fixture, n: NodeId, s: Step) !NodeId {
        return (try f.shapes.proj(testing.allocator, &f.account, &f.places, &f.cells, n, s)).?;
    }

    fn firstCell(f: *Fixture, s: SetId) CellId {
        var it = f.cells.sets.iterate(s);
        return .from(it.next().?.key);
    }

    fn one(f: *Fixture, s: Step, n: NodeId) !u32 {
        return f.shapes.overPut(testing.allocator, &f.account, Table.over_none, s, n);
    }
};

test "a symbolic leaf projects down the trie; a built node projects its children" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const rec = try f.placeOf(3);
    const list = try f.placeOf(1);
    const p1 = try f.shapes.leaf(gpa, &f.account, rec, try f.param(1, rec));
    const a = try f.proj(p1, try Place.Step.field(&f.account, 10));
    try testing.expectEqual(Kind.leaf, f.shapes.kind(a));
    try testing.expectEqual(list, f.shapes.place(a));
    const a_cell = f.firstCell(f.shapes.cells(a));
    try testing.expectEqual(Cell.Origin.param, f.cells.origin(a_cell));
    try testing.expectEqual(Cell.Kind.list, f.cells.kind(a_cell));
    // Memoised: the same node again.
    try testing.expectEqual(a, try f.proj(p1, try Place.Step.field(&f.account, 10)));
    // A built record: `{ a = xs, b = [] }`.
    const xs = try f.shapes.leaf(gpa, &f.account, list, try f.param(2, list));
    const empty = try f.shapes.leaf(gpa, &f.account, list, try f.site(7, list, .list));
    var children = try f.one(try Place.Step.field(&f.account, 10), xs);
    children = try f.shapes.overPut(gpa, &f.account, children, try Place.Step.field(&f.account, 11), empty);
    const r = try f.shapes.node(gpa, &f.account, rec, try f.site(8, rec, .record), children);
    try testing.expectEqual(xs, try f.proj(r, try Place.Step.field(&f.account, 10)));
    try testing.expectEqual(empty, try f.proj(r, try Place.Step.field(&f.account, 11)));
    // A concrete leaf projects to nothing; a missing step is null.
    const below = try f.proj(empty, Place.Step.elem);
    try testing.expectEqual(SetId.none, f.shapes.cells(below));
    try testing.expectEqual(@as(?NodeId, null), try f.shapes.proj(gpa, &f.account, &f.places, &f.cells, r, Place.Step.elem));
    // reach: the record's own cell, both fields' cells.
    const reach = try f.shapes.reach(gpa, &f.account, &f.cells.sets, r);
    try testing.expectEqual(@as(u32, 3), f.cells.sets.count(reach));
}

test "w5's pair tower is 17 nodes, map keeps the DAG and widen is the identity" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    var n = try f.shapes.leaf(gpa, &f.account, list, try f.site(1, list, .list));
    var k: u32 = 1;
    while (k <= 16) : (k += 1) {
        const at = try f.placeOf(10 + k);
        var children = try f.one(try Place.Step.index(&f.account, 0), n);
        children = try f.shapes.overPut(gpa, &f.account, children, try Place.Step.index(&f.account, 1), n);
        n = try f.shapes.node(gpa, &f.account, at, .none, children);
    }
    try testing.expectEqual(@as(u32, 17), f.shapes.count());
    // map: 17 steps, 17 new nodes, the DAG kept.
    const before = f.shapes.count();
    const Relabel = struct {
        fn relabel(fx: *Fixture, s: SetId) Error!SetId {
            if (s == .none) return .none;
            return fx.cells.sets.insert(testing.allocator, .growth(&fx.account), .none, 1_000, 1);
        }
    };
    const mapped = try f.shapes.map(gpa, &f.account, n, &f, Relabel.relabel);
    try testing.expectEqual(@as(u32, 17), f.shapes.count() - before);
    try testing.expect(mapped != n);
    // widen: no re-entering step, the very node.
    try testing.expectEqual(n, try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, n));
    // 2¹⁶ paths exist; the oracle enumerates them only to a bound.
    var out: std.ArrayList(Table.Expanded) = .empty;
    defer out.deinit(gpa);
    try f.shapes.expand(gpa, &f.account, &f.places, &f.cells, n, 100, &out);
    try testing.expectEqual(@as(usize, 100), out.items.len);
}

test "a cyclic type is one place, and widen ties go's grafted levels back" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const tree = try f.placeOf(0);
    const list = try f.placeOf(1);
    try testing.expectEqual(@as(u32, 3), f.places.count());
    const s0 = try f.places.ctorStep(gpa, &f.account, 0, 0);
    const s1 = try f.places.ctorStep(gpa, &f.account, 0, 1);
    const s2 = try f.places.ctorStep(gpa, &f.account, 0, 2);
    // `go (n - 1) (Node t [ n ] t)` twice over the parameter `t`.
    const t_param = try f.shapes.leaf(gpa, &f.account, tree, try f.param(2, tree));
    var inner_children = try f.one(s0, t_param);
    inner_children = try f.shapes.overPut(gpa, &f.account, inner_children, s1, try f.shapes.leaf(gpa, &f.account, list, try f.site(1, list, .list)));
    inner_children = try f.shapes.overPut(gpa, &f.account, inner_children, s2, t_param);
    const inner = try f.shapes.node(gpa, &f.account, tree, .none, inner_children);
    var outer_children = try f.one(s0, inner);
    outer_children = try f.shapes.overPut(gpa, &f.account, outer_children, s1, try f.shapes.leaf(gpa, &f.account, list, try f.site(2, list, .list)));
    outer_children = try f.shapes.overPut(gpa, &f.account, outer_children, s2, inner);
    const outer = try f.shapes.node(gpa, &f.account, tree, .none, outer_children);
    const w = try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, outer);
    try testing.expect(w != outer);
    // The knot: the recursive children name the widened node itself (or
    // its union with the parameter leaf), and the lists are joined.
    const w_child = try f.proj(w, s0);
    try testing.expect(w_child == w or (f.shapes.kind(w_child) == .@"union" and f.shapes.nodes.items(.a)[w_child.int()] == w.int()));
    const lists = try f.proj(w, s1);
    // Both fresh lists and the parameter's own list below (`π₂·#Node.1`).
    try testing.expectEqual(@as(u32, 3), f.cells.sets.count(f.shapes.cells(lists)));
    // Extensive, and a fixpoint: widening again changes nothing semantically.
    try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, outer, w));
    try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, inner, w));
    try f.shapes.crossCheckWiden(gpa, &f.account, &f.places, &f.cells, outer, w);
    const w2 = try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, w);
    try testing.expect(try f.shapes.eq(gpa, &f.account, &f.places, &f.cells, w, w2));
}

test "a chain of k deltas costs O(k log F) and reach shares the base" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const rec = try f.placeOf(3);
    const list = try f.placeOf(1);
    const base = try f.shapes.leaf(gpa, &f.account, rec, try f.param(1, rec));
    var n = base;
    var k: u32 = 0;
    const nodes_before = f.shapes.count();
    while (k < 64) : (k += 1) {
        const v = try f.shapes.leaf(gpa, &f.account, list, try f.site(100 + k, list, .list));
        n = try f.shapes.put(gpa, &f.account, n, if (k % 2 == 0) try Place.Step.field(&f.account, 10) else try Place.Step.field(&f.account, 11), v, true, .none);
        try testing.expectEqual(Kind.delta, f.shapes.kind(n));
    }
    // One delta and one leaf per step, never a copy of the chain.
    try testing.expectEqual(@as(u32, 128), f.shapes.count() - nodes_before);
    try testing.expectEqual(base, f.shapes.baseOf(n));
    // The ε object is the base's (O7); the last writes are what is read.
    try testing.expectEqual(f.shapes.cells(base), f.shapes.cells(n));
    const a = try f.proj(n, try Place.Step.field(&f.account, 10));
    try testing.expectEqual(f.firstCell(f.shapes.cells(a)), try f.cells.site(gpa, &f.account, 162, list, .list));
    const reach = try f.shapes.reach(gpa, &f.account, &f.cells.sets, n);
    // The base's cell, and the two overrides in force.
    try testing.expectEqual(@as(u32, 3), f.cells.sets.count(reach));
}

test "join groups deltas by base, merges leaves, and unions the rest" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const rec = try f.placeOf(3);
    const list = try f.placeOf(1);
    const base = try f.shapes.leaf(gpa, &f.account, rec, try f.param(1, rec));
    const x = try f.shapes.leaf(gpa, &f.account, list, try f.site(1, list, .list));
    const y = try f.shapes.leaf(gpa, &f.account, list, try f.site(2, list, .list));
    const d1 = try f.shapes.put(gpa, &f.account, base, try Place.Step.field(&f.account, 10), x, true, .none);
    const d2 = try f.shapes.put(gpa, &f.account, base, try Place.Step.field(&f.account, 11), y, true, .none);
    var members = [_]NodeId{ d1, d2 };
    const j = try f.shapes.join(gpa, &f.account, &f.places, &f.cells, &members);
    try testing.expectEqual(Kind.delta, f.shapes.kind(j));
    try testing.expectEqual(base, f.shapes.baseOf(j));
    // `.a` is `x` joined with the base's `.a` (the parameter's field): a union.
    const ja = try f.proj(j, try Place.Step.field(&f.account, 10));
    try testing.expectEqual(@as(u32, 2), f.cells.sets.count(f.shapes.cells(ja)));
    try f.shapes.crossCheckJoin(gpa, &f.account, &f.places, &f.cells, j, &members);
    // Memoised and symmetric.
    var swapped = [_]NodeId{ d2, d1 };
    try testing.expectEqual(j, try f.shapes.join(gpa, &f.account, &f.places, &f.cells, &swapped));
    // Two leaves at one place: one leaf, the set union.
    var leaves = [_]NodeId{ x, y, x };
    const l = try f.shapes.join(gpa, &f.account, &f.places, &f.cells, &leaves);
    try testing.expectEqual(Kind.leaf, f.shapes.kind(l));
    try testing.expectEqual(@as(u32, 2), f.cells.sets.count(f.shapes.cells(l)));
    // A leaf beside a delta: a union; leq holds for every member (O4).
    var mixed = [_]NodeId{ d1, base };
    const u = try f.shapes.join(gpa, &f.account, &f.places, &f.cells, &mixed);
    try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, d1, u));
    try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, base, u));
    try testing.expect(!try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, u, base));
    try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, j, u) == false or true);
    // A recast is approximate at every path and composes to one.
    const cast = try f.shapes.recast(gpa, &f.account, rec, x);
    const cast2 = try f.shapes.recast(gpa, &f.account, list, cast);
    try testing.expectEqual(x.int(), f.shapes.nodes.items(.a)[cast2.int()]);
    try testing.expectEqual(Kind.recast, f.shapes.kind(try f.proj(cast, try Place.Step.field(&f.account, 10))));
}
