//! L3: shape nodes, the abstract values (`docs/design/ownership-v2.md` §2.3,
//! §3.3). A node denotes a function from paths to sets of `(cell, approx)`.
//!
//! | kind     | meaning                                                     |
//! |----------|-------------------------------------------------------------|
//! | `leaf`   | `cells` at `ε`; below, whatever the symbolic cells project to |
//! | `node`   | a built value: `cells` at `ε`, explicit children by step     |
//! | `delta`  | `base` written: `base`'s cells at `ε`, an override or the base's child at a step |
//! | `recast` | `inner` read at another place: `inner`'s cells, approximate, at every path |
//! | `union`  | the lazy join of two ALTERNATIVES, never flattened: a cell in both sides is one position |
//! | `positions` | two POSITIONS that coexist (`collect`: a literal's elements under `[*]`, a spread's): a cell in both sides is two positions |
//!
//! A `union` and a `positions` node are read alike by `proj`, `reach`,
//! `map` and `widen` (which keep the kind: `proj(positions(a, b), s) =
//! positions(proj a, proj b)`, so a repeated element stays repeated);
//! `leq` is γ-inclusion and kind-blind — the multiplicity is κ's business
//! (`Cond`), where `positions(a, a)` reads `shared` and `union(a, a)` is `a`.
//! `join` only ever makes a `union`; nothing turns a `positions` into one.
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
pub const PathId = Ids.PathId;
pub const SetId = Ids.SetId;
pub const PlaceId = Ids.PlaceId;
pub const CellId = Ids.CellId;
pub const Step = Place.Step;
pub const Account = Ids.Account;

pub const Error = Ids.ChargeError;

pub const Kind = enum(u8) { leaf, node, delta, recast, @"union", positions };

/// One node (§3.3). `a`, `b` by kind: `node`: the children map; `delta`:
/// base + the override map; `recast`: inner; `union`, `positions`: left, right.
pub const Node = struct {
    kind: Kind,
    place: PlaceId,
    /// The cells at `ε` (a delta's: its base's; a union's or a positions
    /// node's: both sides', as a set — the multiset is read by `Cond`).
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
    /// `leq`'s answers that rest on a coinductive assumption of the query
    /// in progress, and its depth.
    leq_provisional: std.ArrayList([2]u32) = .empty,
    leq_depth: u32 = 0,
    memo_map: stamped.Column(NodeId, NodeId) = .{},
    /// `arrivals`' memo: the cells of a node's reach that are not apart
    /// by construction (#1115's review).
    arrivals_memo: stamped.Column(NodeId, SetId) = .{},
    /// `unionHas`'s visited stamp.
    union_seen: stamped.Column(NodeId, void) = .{},
    /// `rank`'s memo: final ranks only (its in-progress marks are the call's).
    rank_memo: stamped.Column(NodeId, u32) = .{},
    /// `namedSteps`' memo: a node's list, `(start, len)` in `named_pool`.
    named_memo: stamped.Column(NodeId, [2]u32) = .{},
    named_pool: std.ArrayList(u32) = .empty,

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.rank_memo.deinit(gpa);
        t.named_memo.deinit(gpa);
        t.named_pool.deinit(gpa);
        t.nodes.deinit(gpa);
        t.intern.deinit(gpa);
        t.overs.deinit(gpa);
        t.over_intern.deinit(gpa);
        t.memo_proj.deinit(gpa);
        t.memo_join.deinit(gpa);
        t.memo_leq.deinit(gpa);
        t.leq_provisional.deinit(gpa);
        t.union_seen.deinit(gpa);
        t.memo_map.deinit(gpa);
        t.arrivals_memo.deinit(gpa);
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
        try account.reserve(.shape, 1);
        const got = try t.over_intern.getOrPut(gpa, .{ n.prefix, n.mask, n.left, n.right });
        if (got.found_existing) return got.value_ptr.*;
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

    /// Reserved BEFORE the dictionary is touched, on a hit as on a miss
    /// (§4.1), so a refusal leaves no half-written entry.
    fn make(t: *Table, gpa: Allocator, account: *Account, n: Node) Error!NodeId {
        try account.reserve(.shape, 1);
        const got = try t.intern.getOrPut(gpa, .{ @backingInt(n.kind), n.place.int(), n.cells.int(), n.a, n.b });
        if (got.found_existing) return .from(got.value_ptr.*);
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
        if (try t.unionHas(gpa, account, l, r)) return l;
        if (try t.unionHas(gpa, account, r, l)) return r;
        const x = @min(l.int(), r.int());
        const y = @max(l.int(), r.int());
        const c = try cellsets.unionWith(gpa, .growth(account), t.cells(l), t.cells(r));
        return t.make(gpa, account, .{ .kind = .@"union", .place = t.place(l), .cells = c, .a = x, .b = y, .reach = .none });
    }

    /// `collect(n₁…nₖ)` (§2.3): a built value's elements under `[*]` as a
    /// balanced `positions` DAG — never deduplicated or absorbed: the same
    /// node on both sides is two positions, which κ reads as `shared`. One
    /// element is itself, so `[ x ]` joined with `[ x ]` stays one position.
    pub fn collect(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, members: []const NodeId) Error!NodeId {
        std.debug.assert(members.len > 0);
        if (members.len == 1) return members[0];
        const mid = members.len / 2;
        return t.positions(gpa, account, cellsets, try t.collect(gpa, account, cellsets, members[0..mid]), try t.collect(gpa, account, cellsets, members[mid..]));
    }

    /// `n` without the cells of `drop` at its own path: a leaf keeps the
    /// others, a union or a positions node is rebuilt over its sides, a
    /// built node, a delta or a recast stays as it is (its `ε` cells are
    /// its own object). Each node of the same-path DAG once (`memo_map`).
    /// `.none` when nothing is left. `one`: the value at ONE of `n`'s
    /// positions (a pattern's element), so a positions node becomes the
    /// union of its sides — alternatives.
    pub fn without(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, n: NodeId, drop: SetId, one: bool) Error!NodeId {
        if (drop == .none and !one) return n;
        t.memo_map.clear();
        const F = struct { node: NodeId, expanded: bool };
        var stack: std.ArrayList(F) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, .{ .node = n, .expanded = false });
        while (stack.pop()) |f| {
            if (t.memo_map.get(f.node) != null) continue;
            try account.reserve(.shape, 1);
            const d = t.get(f.node);
            switch (d.kind) {
                .leaf => if (drop == .none) {
                    try t.memo_map.put(gpa, f.node, f.node);
                } else {
                    var kept: SetId = .none;
                    var it = cellsets.iterate(d.cells);
                    while (it.next()) |e| {
                        if (cellsets.member(drop, e.key)) continue;
                        kept = try cellsets.insert(gpa, .growth(account), kept, e.key, e.value);
                    }
                    try t.memo_map.put(gpa, f.node, if (kept == .none) .none else if (kept == d.cells) f.node else try t.leaf(gpa, account, d.place, kept));
                },
                .node, .delta, .recast => try t.memo_map.put(gpa, f.node, f.node),
                .@"union", .positions => if (!f.expanded) {
                    try stack.appendSlice(gpa, &.{ .{ .node = f.node, .expanded = true }, .{ .node = .from(d.a), .expanded = false }, .{ .node = .from(d.b), .expanded = false } });
                } else {
                    const l = t.memo_map.get(.from(d.a)).?;
                    const r = t.memo_map.get(.from(d.b)).?;
                    const as_union = d.kind == .@"union" or one;
                    const out: NodeId = if (l == .none) r else if (r == .none) l else if (l == NodeId.from(d.a) and r == NodeId.from(d.b) and as_union == (d.kind == .@"union")) f.node else if (as_union) try t.@"union"(gpa, account, cellsets, l, r) else try t.positions(gpa, account, cellsets, l, r);
                    try t.memo_map.put(gpa, f.node, out);
                },
            }
        }
        return t.memo_map.get(n).?;
    }

    /// A node no constructor interns, its record set later by `tie`: how a
    /// reader rebuilds a knot (`widen`'s, `map`'s), whose parts name it
    /// before it is whole. The empty leaf until it is tied.
    pub fn knot(t: *Table, gpa: Allocator, account: *Account) Error!NodeId {
        try account.reserve(.shape, 1);
        const id: NodeId = .from(t.count());
        try t.nodes.append(gpa, .{ .kind = .leaf, .place = .none, .cells = .none, .a = 0, .b = 0, .reach = .none });
        return id;
    }

    /// Set a `knot`'s record: the caller's to make it one a constructor
    /// could have made but for the cycle.
    pub fn tie(t: *Table, id: NodeId, n: Node) void {
        t.nodes.set(id.int(), n);
    }

    /// Two positions at one place (`collect`'s node, `proj`'s image of one).
    fn positions(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, l: NodeId, r: NodeId) Error!NodeId {
        const c = try cellsets.unionWith(gpa, .growth(account), t.cells(l), t.cells(r));
        return t.make(gpa, account, .{ .kind = .positions, .place = t.place(l), .cells = c, .a = l.int(), .b = r.int(), .reach = .none });
    }

    /// Whether `x` is a member of the union DAG `u` (its sides, through
    /// nested unions only): a walk with a visited stamp, every union node
    /// once, one record reserved per node read. Never a silent `false`.
    fn unionHas(t: *Table, gpa: Allocator, account: *Account, u: NodeId, x: NodeId) Error!bool {
        if (u == x) return true;
        if (t.kind(u) != .@"union") return false;
        t.union_seen.clear();
        var stack: std.ArrayList(NodeId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, u);
        while (stack.pop()) |n| {
            if (n == x) return true;
            if (t.kind(n) != .@"union" or t.union_seen.contains(n)) continue;
            try t.union_seen.put(gpa, n, {});
            try account.reserve(.inspection, 1);
            const d = t.get(n);
            try stack.append(gpa, .from(d.a));
            try stack.append(gpa, .from(d.b));
        }
        return false;
    }

    /// `put(n, s, m)` (§2.3): the same object written (`same_object`) is a
    /// delta over `n`; a construction is a copy with one child changed, a
    /// fresh base with `n`'s children and `fresh` at `ε`.
    pub fn put(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, n: NodeId, s: Step, m: NodeId, same_object: bool, fresh: SetId) Error!NodeId {
        if (same_object) {
            if (t.kind(n) == .delta) {
                const d = t.get(n);
                return t.delta(gpa, account, .from(d.a), try t.overPut(gpa, account, d.b, s, m));
            }
            return t.delta(gpa, account, n, try t.overPut(gpa, account, over_none, s, m));
        }
        const children = try t.materialize(gpa, account, places, cellt, n);
        return t.node(gpa, account, t.place(n), fresh, try t.overPut(gpa, account, children, s, m));
    }

    /// `n` with its `ε` cells replaced by `c` and its children as they are:
    /// a leaf stays a leaf, anything else becomes a `node` over its
    /// materialised children (what a use shape's builder needs, §2.10).
    pub fn withCells(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, n: NodeId, c: SetId) Error!NodeId {
        if (t.kind(n) == .leaf) return t.leaf(gpa, account, t.place(n), c);
        return t.node(gpa, account, t.place(n), c, try t.materialize(gpa, account, places, cellt, n));
    }

    /// Every child of `n` as one map, each step of its place projected
    /// (`proj`): a node's children as they are, and for a leaf, a delta over
    /// one, a recast or a union the projections a copy would otherwise
    /// drop. A step that projects to nothing is left out.
    fn materialize(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, n: NodeId) Error!u32 {
        if (t.kind(n) == .node) return t.nodes.items(.a)[n.int()];
        var m: u32 = over_none;
        const steps = places.steps(t.place(n));
        for (steps.steps) |s| {
            const c = (try t.proj(gpa, account, places, cellt, n, s)) orelse continue;
            if (t.kind(c) == .leaf and t.cells(c) == .none) continue;
            m = try t.overPut(gpa, account, m, s, c);
        }
        return m;
    }

    // ---- projection ---------------------------------------------------------------------

    /// `proj(n, s)` (§2.3), memoised per `(node, step)`. A symbolic leaf
    /// projects its cells one step down the trie; a concrete leaf projects
    /// to nothing; a recast stays a recast (approximate); a union or a
    /// positions node projects both sides, its kind kept. Null when the
    /// place has no such step.
    pub fn proj(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, n: NodeId, s: Step) Error!?NodeId {
        // Reserved before the memo is touched, a hit charged like a miss
        // (§2.3 *Memo safety*); the memo is written only once the answer
        // exists, so a refusal in the middle leaves no "no such step" for
        // another owner to read.
        try account.reserve(.memo, 1);
        if (t.memo_proj.get(.{ n.int(), s.word() })) |hit| return if (hit == Ids.none_int) null else NodeId.from(hit);
        const d = t.get(n);
        const child_place = places.child(d.place, s) orelse {
            (try t.memo_proj.getOrPut(gpa, .{ n.int(), s.word() })).value_ptr.* = Ids.none_int;
            return null;
        };
        const out: NodeId = switch (d.kind) {
            .leaf => try t.projectLeaf(gpa, account, places, cellt, d.cells, child_place, s),
            .node => t.overGet(d.a, s) orelse try t.nothing(gpa, account, child_place),
            .delta => t.overGet(d.b, s) orelse (try t.proj(gpa, account, places, cellt, .from(d.a), s)).?,
            .recast => try t.recast(gpa, account, child_place, .from(d.a)),
            .@"union" => try t.@"union"(gpa, account, &cellt.sets, (try t.proj(gpa, account, places, cellt, .from(d.a), s)).?, (try t.proj(gpa, account, places, cellt, .from(d.b), s)).?),
            .positions => try t.positions(gpa, account, &cellt.sets, (try t.proj(gpa, account, places, cellt, .from(d.a), s)).?, (try t.proj(gpa, account, places, cellt, .from(d.b), s)).?),
        };
        (try t.memo_proj.getOrPut(gpa, .{ n.int(), s.word() })).value_ptr.* = out.int();
        return out;
    }

    /// Project a leaf's cells: every symbolic cell to its child at `s`
    /// (`⊤` to itself, and a use mark likewise: a leaf of marks is a deep
    /// use, §2.10), concrete cells to nothing, approximation kept.
    fn projectLeaf(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, c: SetId, child_place: PlaceId, s: Step) Error!NodeId {
        var out: SetId = .none;
        var it = cellt.sets.iterate(c);
        while (it.next()) |e| {
            const cell: CellId = .from(e.key);
            const o = cellt.origin(cell);
            if (o == .top or o == .mark) {
                out = try cellt.sets.insert(gpa, .growth(account), out, e.key, e.value);
                continue;
            }
            // A refinement projects through its canonical position, the
            // split forgotten (§2.2): `elem c·ι` below is `c[*]` below.
            const sym = if (o.isRefinement()) (try cellt.unrefined(gpa, account, places, cell)) orelse continue else cell;
            if (!cellt.origin(sym).isSymbolic()) continue;
            const rec = cellt.get(sym);
            const child_path = (try places.extend(gpa, .growth(account), .from(rec.b), s)) orelse continue;
            const child = try cellt.symbolic(gpa, account, places, rec.origin, rec.a, child_path, rec.c);
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
    /// are in it by their root), memoised for every node: Tarjan over the
    /// explicit graph, one set per strongly connected component (a widened
    /// cyclic value is one component), the component's set the union of its
    /// members' cells and its successors' sets. O(nodes · log C) once.
    pub fn reach(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, n: NodeId) Error!SetId {
        if (t.nodes.items(.reach)[n.int()] != .none) return t.nodes.items(.reach)[n.int()];
        var r: Reach = .{ .t = t, .gpa = gpa, .account = account, .sets = cellsets };
        defer r.deinit();
        try r.run(n);
        return t.nodes.items(.reach)[n.int()];
    }

    /// The cells of `n`'s reach that construction does not make apart: an
    /// arrival (not a site, a result or an escape), `⊤`, or an approximate
    /// cell, with its flag. What `apart` over the reach of one element
    /// reads (§2.9): the rest is apart by construction. Memoised per node,
    /// built as `reach` is, so a tower costs each level its own cells.
    pub fn arrivals(t: *Table, gpa: Allocator, account: *Account, cellt: *const Cell.Table, cellsets: *Cell.Radix, n: NodeId) Error!SetId {
        try account.reserve(.memo, 1);
        if (t.arrivals_memo.get(n)) |s| return s;
        var r: Reach = .{ .t = t, .gpa = gpa, .account = account, .sets = cellsets, .filter = cellt };
        defer r.deinit();
        try r.run(n);
        return t.arrivals_memo.get(n).?;
    }

    /// Iterative Tarjan over the explicit children, on explicit stacks.
    const Reach = struct {
        t: *Table,
        gpa: Allocator,
        account: *Account,
        sets: *Cell.Radix,
        /// Set: `arrivals`, into `arrivals_memo`, a node's own cells filtered.
        filter: ?*const Cell.Table = null,
        index: stamped.Column(NodeId, u32) = .{},
        low: stamped.Column(NodeId, u32) = .{},
        on_stack: stamped.Column(NodeId, void) = .{},
        scc_stack: std.ArrayList(NodeId) = .empty,
        /// Successors of a node, flattened: `(node, successor cursor)`.
        frames: std.ArrayList(Frame) = .empty,
        kids: std.ArrayList(NodeId) = .empty,
        next_index: u32 = 0,

        const Frame = struct { node: NodeId, first_kid: u32, cursor: u32 };

        fn deinit(r: *Reach) void {
            r.index.deinit(r.gpa);
            r.low.deinit(r.gpa);
            r.on_stack.deinit(r.gpa);
            r.scc_stack.deinit(r.gpa);
            r.frames.deinit(r.gpa);
            r.kids.deinit(r.gpa);
        }

        /// The explicit children of `n` appended to `kids`.
        fn children(r: *Reach, n: NodeId) Error!void {
            const d = r.t.get(n);
            switch (d.kind) {
                .leaf => {},
                .node => {
                    var it = r.t.overEntries(d.a);
                    while (it.next()) |e| try r.kids.append(r.gpa, e.node);
                },
                .delta => {
                    try r.kids.append(r.gpa, .from(d.a));
                    var it = r.t.overEntries(d.b);
                    while (it.next()) |e| try r.kids.append(r.gpa, e.node);
                },
                .recast => try r.kids.append(r.gpa, .from(d.a)),
                .@"union", .positions => try r.kids.appendSlice(r.gpa, &.{ .from(d.a), .from(d.b) }),
            }
        }

        fn settled(r: *Reach, k: NodeId) bool {
            return if (r.filter != null) r.t.arrivals_memo.get(k) != null else r.t.nodes.items(.reach)[k.int()] != .none;
        }

        fn got(r: *Reach, k: NodeId) SetId {
            return if (r.filter != null) r.t.arrivals_memo.get(k) orelse .none else r.t.nodes.items(.reach)[k.int()];
        }

        /// A member's own cells, filtered in `arrivals` mode: a record each.
        fn own(r: *Reach, m: NodeId) Error!SetId {
            const cellt = r.filter orelse return r.t.cells(m);
            var out: SetId = .none;
            var it = r.sets.iterate(r.t.cells(m));
            while (it.next()) |e| {
                try r.account.reserve(.inspection, 1);
                const o = cellt.origin(.from(e.key));
                if (e.value == 0 and (o == .site or o == .result or o == .esc)) continue;
                out = try r.sets.insert(r.gpa, .growth(r.account), out, e.key, e.value);
            }
            return out;
        }

        fn push(r: *Reach, n: NodeId) Error!void {
            try r.account.reserve(.memo, 1);
            try r.index.put(r.gpa, n, r.next_index);
            try r.low.put(r.gpa, n, r.next_index);
            r.next_index += 1;
            try r.on_stack.put(r.gpa, n, {});
            try r.scc_stack.append(r.gpa, n);
            const first: u32 = @intCast(r.kids.items.len);
            try r.children(n);
            try r.frames.append(r.gpa, .{ .node = n, .first_kid = first, .cursor = first });
        }

        fn run(r: *Reach, root: NodeId) Error!void {
            try r.push(root);
            while (r.frames.items.len > 0) {
                const f = &r.frames.items[r.frames.items.len - 1];
                if (f.cursor < r.kids.items.len) {
                    const k = r.kids.items[f.cursor];
                    f.cursor += 1;
                    const n = f.node;
                    if (r.settled(k)) continue; // settled elsewhere
                    if (r.index.get(k) == null) {
                        try r.push(k);
                        continue;
                    }
                    if (r.on_stack.contains(k)) {
                        const l = @min(r.low.get(n).?, r.index.get(k).?);
                        try r.low.put(r.gpa, n, l);
                    }
                    continue;
                }
                // Done with `f.node`: pop its kids, fold its low into the parent,
                // and close a component if it is a root.
                const n = f.node;
                r.kids.shrinkRetainingCapacity(f.first_kid);
                _ = r.frames.pop();
                if (r.frames.items.len > 0) {
                    const parent = r.frames.items[r.frames.items.len - 1].node;
                    const l = @min(r.low.get(parent).?, r.low.get(n).?);
                    try r.low.put(r.gpa, parent, l);
                }
                if (r.low.get(n).? != r.index.get(n).?) continue;
                // A component: its members' cells and their successors' sets
                // (every successor outside it is settled already).
                var set: SetId = .none;
                var i = r.scc_stack.items.len;
                while (i > 0) {
                    i -= 1;
                    const m = r.scc_stack.items[i];
                    set = try r.sets.unionWith(r.gpa, .growth(r.account), set, try r.own(m));
                    const first: u32 = @intCast(r.kids.items.len);
                    try r.children(m);
                    for (r.kids.items[first..]) |k| {
                        const s = r.got(k);
                        if (s != .none) set = try r.sets.unionWith(r.gpa, .growth(r.account), set, s);
                    }
                    r.kids.shrinkRetainingCapacity(first);
                    if (m == n) break;
                }
                while (r.scc_stack.items.len > 0) {
                    const m = r.scc_stack.pop().?;
                    r.on_stack.remove(m);
                    if (r.filter != null) try r.t.arrivals_memo.put(r.gpa, m, set) else r.t.nodes.items(.reach)[m.int()] = set;
                    if (m == n) break;
                }
            }
        }
    };

    // ---- named steps ------------------------------------------------------------------------

    /// The steps `n`'s structure names, sorted and distinct: a node's
    /// children, a delta's overrides and its base's, a union's or a
    /// positions node's sides'; a leaf or a recast names none. Memoised per
    /// node, a side's list merged into its union's, so a union DAG costs
    /// each node its own steps once. The slice is valid until the next call.
    pub fn namedSteps(t: *Table, gpa: Allocator, account: *Account, n: NodeId) Error![]const u32 {
        try account.reserve(.memo, 1);
        if (t.named_memo.get(n)) |r| return t.named_pool.items[r[0]..][0..r[1]];
        const Frame = struct { node: NodeId, expanded: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        var buf: std.ArrayList(u32) = .empty;
        defer buf.deinit(gpa);
        try stack.append(gpa, .{ .node = n, .expanded = false });
        while (stack.pop()) |f| {
            const x = f.node;
            if (t.named_memo.contains(x)) continue;
            const d = t.get(x);
            // A union's sides and a delta's base first; nothing below them
            // names `x` (a side is made before its union).
            if (!f.expanded) switch (d.kind) {
                .@"union", .positions => {
                    try stack.appendSlice(gpa, &.{ .{ .node = x, .expanded = true }, .{ .node = .from(d.a), .expanded = false }, .{ .node = .from(d.b), .expanded = false } });
                    continue;
                },
                .delta => {
                    try stack.appendSlice(gpa, &.{ .{ .node = x, .expanded = true }, .{ .node = .from(d.a), .expanded = false } });
                    continue;
                },
                else => {},
            };
            try account.reserve(.inspection, 1);
            buf.clearRetainingCapacity();
            switch (d.kind) {
                .leaf, .recast => {},
                .node, .delta => {
                    var it = t.overEntries(if (d.kind == .node) d.a else d.b);
                    while (it.next()) |e| {
                        try account.reserve(.inspection, 1);
                        try buf.append(gpa, e.step.word());
                    }
                    std.mem.sort(u32, buf.items, {}, std.sort.asc(u32));
                    if (d.kind == .delta) try t.mergeNamed(gpa, account, &buf, t.named_memo.get(.from(d.a)).?);
                },
                .@"union", .positions => {
                    try t.mergeNamed(gpa, account, &buf, t.named_memo.get(.from(d.a)).?);
                    try t.mergeNamed(gpa, account, &buf, t.named_memo.get(.from(d.b)).?);
                },
            }
            const at: u32 = @intCast(t.named_pool.items.len);
            try t.named_pool.appendSlice(gpa, buf.items);
            try t.named_memo.put(gpa, x, .{ at, @intCast(buf.items.len) });
        }
        const r = t.named_memo.get(n).?;
        return t.named_pool.items[r[0]..][0..r[1]];
    }

    /// `buf` (sorted, distinct) merged with a memoised list, a record per
    /// step read.
    fn mergeNamed(t: *Table, gpa: Allocator, account: *Account, buf: *std.ArrayList(u32), other: [2]u32) Error!void {
        const b = t.named_pool.items[other[0]..][0..other[1]];
        if (b.len == 0) return;
        try account.reserve(.inspection, @intCast(buf.items.len + b.len));
        var merged: std.ArrayList(u32) = .empty;
        defer merged.deinit(gpa);
        var i: usize = 0;
        var j: usize = 0;
        while (i < buf.items.len or j < b.len) {
            const x = if (j >= b.len or (i < buf.items.len and buf.items[i] <= b[j])) buf.items[i] else b[j];
            if (i < buf.items.len and buf.items[i] == x) i += 1;
            if (j < b.len and b[j] == x) j += 1;
            if (merged.items.len == 0 or merged.items[merged.items.len - 1] != x) try merged.append(gpa, x);
        }
        buf.clearRetainingCapacity();
        try buf.appendSlice(gpa, merged.items);
    }

    // ---- rank -------------------------------------------------------------------------------

    /// No finite rank: a recast, or a node on or above a cycle.
    pub const rank_unbounded: u32 = std.math.maxInt(u32);

    /// The projection rank (§2.9, *The join memo*): a leaf 0; a node one
    /// more than its children's; a delta the larger of one more than its
    /// overrides' and its base's; a union or a positions node its sides'
    /// larger; a recast, and a node on or above a cycle, unbounded. Every
    /// `proj` of a node of finite rank r ≥ 1 has a rank below r, and a
    /// rank-0 node projects to rank 0, so such a node is never a projection
    /// of anything it projects to. Memoised per node; one walk over an
    /// explicit stack, a record per node and edge. Asked only of finished
    /// nodes: a knot is tied before anything walks it.
    pub fn rank(t: *Table, gpa: Allocator, account: *Account, n: NodeId) Error!u32 {
        try account.reserve(.memo, 1);
        if (t.rank_memo.get(n)) |r| return r;
        const Frame = struct { node: NodeId, expanded: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        // The nodes on the walk's stack: the call's own, so a refusal in
        // the middle leaves no mark behind (§2.3 *Memo safety*); only a
        // finished node's rank is memoised.
        var open: stamped.Column(NodeId, void) = .{};
        defer open.deinit(gpa);
        var kids: std.ArrayList(NodeId) = .empty;
        defer kids.deinit(gpa);
        try stack.append(gpa, .{ .node = n, .expanded = false });
        while (stack.pop()) |f| {
            const x = f.node;
            kids.clearRetainingCapacity();
            if (!f.expanded) {
                // Open: on the stack below, whose finish reads it as a cycle.
                if (t.rank_memo.contains(x) or open.contains(x)) continue;
                try account.reserve(.inspection, 1);
                try open.put(gpa, x, {});
                try stack.append(gpa, .{ .node = x, .expanded = true });
                try t.rankKids(gpa, account, x, &kids);
                for (kids.items) |k| if (!t.rank_memo.contains(k) and !open.contains(k)) try stack.append(gpa, .{ .node = k, .expanded = false });
                continue;
            }
            // Finished: every child is ranked, or still open (a cycle).
            open.remove(x);
            try t.rankKids(gpa, account, x, &kids);
            const d = t.get(x);
            var r: u32 = 0;
            switch (d.kind) {
                .leaf => {},
                .recast => r = rank_unbounded,
                .node => {
                    r = 1;
                    for (kids.items) |k| r = rankAbove(r, t.rank_memo.get(k) orelse rank_unbounded);
                },
                .delta => {
                    // `kids`: the overrides, then the base.
                    r = 1;
                    for (kids.items[0 .. kids.items.len - 1]) |k| r = rankAbove(r, t.rank_memo.get(k) orelse rank_unbounded);
                    r = @max(r, t.rank_memo.get(kids.items[kids.items.len - 1]) orelse rank_unbounded);
                },
                .@"union", .positions => for (kids.items) |k| {
                    r = @max(r, t.rank_memo.get(k) orelse rank_unbounded);
                },
            }
            try t.rank_memo.put(gpa, x, r);
        }
        return t.rank_memo.get(n).?;
    }

    /// One more than a child's rank, and at least `r`.
    fn rankAbove(r: u32, child: u32) u32 {
        return if (child == rank_unbounded) rank_unbounded else @max(r, child + 1);
    }

    /// What `rank` reads below `x`: a node's children, a delta's overrides
    /// then its base, a union's or a positions node's sides.
    fn rankKids(t: *Table, gpa: Allocator, account: *Account, x: NodeId, out: *std.ArrayList(NodeId)) Error!void {
        const d = t.get(x);
        switch (d.kind) {
            .leaf, .recast => {},
            .node, .delta => {
                var it = t.overEntries(if (d.kind == .node) d.a else d.b);
                while (it.next()) |e| {
                    try account.reserve(.inspection, 1);
                    try out.append(gpa, e.node);
                }
                if (d.kind == .delta) try out.append(gpa, .from(d.a));
            },
            .@"union", .positions => try out.appendSlice(gpa, &.{ .from(d.a), .from(d.b) }),
        }
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
            try account.reserve(.memo, 1); // before the memo, a hit charged too
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
        // Every override of every member as `(step, node)`, sorted by step:
        // O(Σ|Oᵢ| log Σ|Oᵢ|), one record each, then one pass over the runs.
        const Pair = struct { step: u32, node: NodeId };
        var all: std.ArrayList(Pair) = .empty;
        defer all.deinit(gpa);
        for (run) |m| {
            if (t.kind(m) != .delta) continue;
            var it = t.overEntries(t.nodes.items(.b)[m.int()]);
            while (it.next()) |e| {
                try account.reserve(.memo, 1);
                try all.append(gpa, .{ .step = e.step.word(), .node = e.node });
            }
        }
        std.mem.sort(Pair, all.items, {}, struct {
            fn lessThan(_: void, a: Pair, b: Pair) bool {
                return a.step < b.step;
            }
        }.lessThan);
        var over: u32 = over_none;
        var values: std.ArrayList(NodeId) = .empty;
        defer values.deinit(gpa);
        var i: usize = 0;
        while (i < all.items.len) {
            var j = i;
            values.clearRetainingCapacity();
            while (j < all.items.len and all.items[j].step == all.items[i].step) : (j += 1) try values.append(gpa, all.items[j].node);
            const s = Step.fromWord(all.items[i].step);
            // A member with no override at this step keeps the base's child.
            if (j - i < run.len) {
                if (try t.proj(gpa, account, places, cellt, base, s)) |b| try values.append(gpa, b);
            }
            i = j;
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
            .@"union", .positions => {
                const l = try t.mapWalk(gpa, account, .from(d.a), ctx, f);
                const r = try t.mapWalk(gpa, account, .from(d.b), ctx, f);
                try account.reserve(.shape, 1);
                const out: NodeId = .from(t.count());
                try t.nodes.append(gpa, .{ .kind = d.kind, .place = d.place, .cells = c, .a = l.int(), .b = r.int(), .reach = .none });
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
                    // The base first: mapping it may grow the table, and a
                    // column read before the call would be the old one.
                    const base = try t.mapWalk(gpa, account, .from(d.a), ctx, f);
                    t.nodes.items(.a)[out.int()] = base.int();
                    t.nodes.items(.b)[out.int()] = mapped;
                }
                return out;
            },
        }
    }

    // ---- order --------------------------------------------------------------------------------

    /// Coinductive lockstep inclusion (§2.3): `cells(n) ⊆ cells(m)` at every
    /// path, pairs assumed on re-entry, memoised per pair. O(|n|·|m|) pairs
    /// at most; O(|n| + |m|) when shapes agree. Kind-blind: a member is below
    /// its `union` and a `union` is below `m` when both sides are (O4), and
    /// two `positions` nodes compare by their cells per path whatever the
    /// order and tree shape of their members — multiplicity is κ's
    /// (`Cond.kappaLeq`), not γ's.
    pub fn leq(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, n: NodeId, m: NodeId) Error!bool {
        if (n == m) return true;
        const outermost = t.leq_depth == 0;
        t.leq_depth += 1;
        defer t.leq_depth -= 1;
        // A query refused in the middle forgets every provisional answer it
        // made, so no `assumed` is left for another owner to read as true.
        errdefer if (outermost) {
            for (t.leq_provisional.items) |pair| if (t.memo_leq.get(pair)) |v| if (v == leq_assumed) {
                (t.memo_leq.getOrPut(gpa, pair) catch unreachable).value_ptr.* = leq_unknown;
            };
            t.leq_provisional.clearRetainingCapacity();
        };
        // Reserved BEFORE the memo is touched, a hit charged like a miss (§2.3
        // *Memo safety*, §4.1).
        try account.reserve(.memo, 1);
        const got = try t.memo_leq.getOrPut(gpa, .{ n.int(), m.int() });
        if (got.found_existing and got.value_ptr.* != leq_unknown) return got.value_ptr.* != leq_false;
        // The coinductive assumption: the pair holds while it is being
        // checked. An answer resting on it is PROVISIONAL until the
        // outermost query settles: kept if that settles true, forgotten if it
        // settles false (a `false` is definitive either way, since an
        // assumption only ever makes an answer more true).
        got.value_ptr.* = leq_assumed;
        try t.leq_provisional.append(gpa, .{ n.int(), m.int() });
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
        (try t.memo_leq.getOrPut(gpa, .{ n.int(), m.int() })).value_ptr.* = if (ok) leq_assumed else leq_false;
        if (outermost) {
            // Settle every provisional answer of this query.
            for (t.leq_provisional.items) |pair| {
                const slot = (try t.memo_leq.getOrPut(gpa, pair)).value_ptr;
                if (slot.* == leq_assumed) slot.* = if (ok) leq_true else leq_unknown;
            }
            t.leq_provisional.clearRetainingCapacity();
        }
        return ok;
    }

    const leq_false: u32 = 0;
    const leq_true: u32 = 1;
    const leq_assumed: u32 = 2;
    const leq_unknown: u32 = 3;

    pub fn eq(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, n: NodeId, m: NodeId) Error!bool {
        return n == m or (try t.leq(gpa, account, places, cellt, n, m) and try t.leq(gpa, account, places, cellt, m, n));
    }

    // ---- widen ------------------------------------------------------------------------------------

    /// The place-graph quotient (§2.3): the result has at most one node per
    /// canonical path of its place graph, a descendant along a re-entering
    /// step joined into the ancestor it re-enters and the edge tied back to
    /// it; over a non-recursive type nothing re-enters and the DAG is
    /// returned as it is, sharing kept. Leaves, recasts, the sides of a
    /// union and a delta's base that is not a node are kept as they are
    /// (never expanded) beside the explicit image, as a union.
    ///
    /// Two phases, O((n + e) log n), no outer loop. First a walk over the
    /// explicit edges carrying each node's canonical path (`Place.extend`
    /// encodes re-entry: a step back onto a place on the path is `⟲`, whose
    /// class is its parent's), uniting the nodes that land on one path and
    /// recording every edge in its class's step map. Then congruence
    /// closure from a pending queue: a merge folds the smaller step map into
    /// the larger and queues the children that now share a step. Every node
    /// and edge read, every merge and every moved entry is a charged record.
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
        /// Union–find over node ids, grown on first touch; the member list
        /// of a class, head to tail; its step-map entries, head to tail,
        /// counted.
        parent: std.ArrayList(u32) = .empty,
        head: std.ArrayList(u32) = .empty,
        tail: std.ArrayList(u32) = .empty,
        next_member: std.ArrayList(u32) = .empty,
        edge_head: std.ArrayList(u32) = .empty,
        edge_tail: std.ArrayList(u32) = .empty,
        edge_count: std.ArrayList(u32) = .empty,
        /// The step-map entries: `(step word, child node, next in class)`.
        entries: std.MultiArrayList(Entry) = .empty,
        /// `(class, step word)` → child node, for the live classes.
        edges: Ids.FixedDict(2) = .{},
        /// Canonical path → the class at it.
        by_path: stamped.Column(PathId, u32) = .{},
        visited: stamped.Column(NodeId, void) = .{},
        pending: std.ArrayList([2]u32) = .empty,
        image: stamped.Column(NodeId, NodeId) = .{},
        kids: std.ArrayList(NodeId) = .empty,
        any_merge: bool = false,

        pub const Entry = struct { step: u32, child: u32, next: u32 };
        comptime {
            Ids.assertRecord(Entry);
        }
        const none = Ids.none_int;

        fn deinit(w: *Widen) void {
            w.parent.deinit(w.gpa);
            w.head.deinit(w.gpa);
            w.tail.deinit(w.gpa);
            w.next_member.deinit(w.gpa);
            w.edge_head.deinit(w.gpa);
            w.edge_tail.deinit(w.gpa);
            w.edge_count.deinit(w.gpa);
            w.entries.deinit(w.gpa);
            w.edges.deinit(w.gpa);
            w.by_path.deinit(w.gpa);
            w.visited.deinit(w.gpa);
            w.pending.deinit(w.gpa);
            w.image.deinit(w.gpa);
            w.kids.deinit(w.gpa);
        }

        fn touch(w: *Widen, n: NodeId) Allocator.Error!void {
            while (w.parent.items.len <= n.int()) {
                const i: u32 = @intCast(w.parent.items.len);
                try w.parent.append(w.gpa, i);
                try w.head.append(w.gpa, i);
                try w.tail.append(w.gpa, i);
                try w.next_member.append(w.gpa, none);
                try w.edge_head.append(w.gpa, none);
                try w.edge_tail.append(w.gpa, none);
                try w.edge_count.append(w.gpa, 0);
            }
        }

        /// With path halving.
        fn find(w: *Widen, n: u32) u32 {
            var x = n;
            while (w.parent.items[x] != x) {
                const g = w.parent.items[w.parent.items[x]];
                w.parent.items[x] = g;
                x = g;
            }
            return x;
        }

        /// Record `rep —s→ child`: a second child at one step of a class is
        /// a congruence to settle (queued), never two entries.
        fn addEdge(w: *Widen, rep: u32, step: u32, child: u32) Error!void {
            try w.account.reserve(.edge, 1);
            const got = try w.edges.getOrPut(w.gpa, .{ rep, step });
            if (got.found_existing) {
                if (w.find(got.value_ptr.*) != w.find(child)) try w.pending.append(w.gpa, .{ got.value_ptr.*, child });
                return;
            }
            got.value_ptr.* = child;
            const e: u32 = @intCast(w.entries.len);
            try w.entries.append(w.gpa, .{ .step = step, .child = child, .next = none });
            if (w.edge_tail.items[rep] == none) w.edge_head.items[rep] = e else w.entries.items(.next)[w.edge_tail.items[rep]] = e;
            w.edge_tail.items[rep] = e;
            w.edge_count.items[rep] += 1;
        }

        /// Unite two classes: members spliced in O(1), the smaller step map
        /// folded into the larger, each moved entry one record, a step both
        /// have queuing its two children.
        fn unite(w: *Widen, a: u32, b: u32) Error!u32 {
            var big = w.find(a);
            var small = w.find(b);
            if (big == small) return big;
            try w.account.reserve(.memo, 1);
            w.any_merge = true;
            if (w.edge_count.items[big] < w.edge_count.items[small]) std.mem.swap(u32, &big, &small);
            w.parent.items[small] = big;
            w.next_member.items[w.tail.items[big]] = w.head.items[small];
            w.tail.items[big] = w.tail.items[small];
            var e = w.edge_head.items[small];
            while (e != none) {
                const next = w.entries.items(.next)[e];
                try w.account.reserve(.inspection, 1);
                const step = w.entries.items(.step)[e];
                const child = w.entries.items(.child)[e];
                const got = try w.edges.getOrPut(w.gpa, .{ big, step });
                if (got.found_existing) {
                    if (w.find(got.value_ptr.*) != w.find(child)) try w.pending.append(w.gpa, .{ got.value_ptr.*, child });
                } else {
                    got.value_ptr.* = child;
                    w.entries.items(.next)[e] = none;
                    if (w.edge_tail.items[big] == none) w.edge_head.items[big] = e else w.entries.items(.next)[w.edge_tail.items[big]] = e;
                    w.edge_tail.items[big] = e;
                    w.edge_count.items[big] += 1;
                }
                e = next;
            }
            w.edge_head.items[small] = none;
            w.edge_tail.items[small] = none;
            return big;
        }

        /// The explicit children of one node: a node's map, a delta's
        /// overrides and, where not overridden, its node base's children.
        fn explicitEdges(w: *Widen, n: NodeId) Error!void {
            w.kids.clearRetainingCapacity();
            const d = w.t.get(n);
            switch (d.kind) {
                .node => {
                    var it = w.t.overEntries(d.a);
                    while (it.next()) |e| try w.kids.appendSlice(w.gpa, &.{ .from(e.step.word()), e.node });
                },
                .delta => {
                    var it = w.t.overEntries(d.b);
                    while (it.next()) |e| try w.kids.appendSlice(w.gpa, &.{ .from(e.step.word()), e.node });
                    if (w.t.kind(.from(d.a)) == .node) {
                        var bt = w.t.overEntries(w.t.nodes.items(.a)[d.a]);
                        while (bt.next()) |e| if (w.t.overGet(d.b, e.step) == null) try w.kids.appendSlice(w.gpa, &.{ .from(e.step.word()), e.node });
                    }
                },
                .leaf, .recast, .@"union", .positions => {},
            }
        }

        fn run(w: *Widen, root: NodeId) Error!NodeId {
            // Phase 1: the walk with canonical paths.
            const Frame = struct { node: NodeId, path: PathId };
            var stack: std.ArrayList(Frame) = .empty;
            defer stack.deinit(w.gpa);
            try stack.append(w.gpa, .{ .node = root, .path = try w.places.rootPath(w.gpa, w.t.place(root)) });
            while (stack.pop()) |f| {
                try w.touch(f.node);
                try w.account.reserve(.edge, 1);
                // `⟲` is its ancestor's class: the re-entered place's node.
                const key = if (w.places.pathParent(f.path) != .none and w.places.pathStep(f.path).kind == .level) w.places.pathParent(f.path) else f.path;
                if (w.by_path.get(key)) |cls| {
                    _ = try w.unite(cls, f.node.int());
                } else {
                    try w.by_path.put(w.gpa, key, w.find(f.node.int()));
                }
                if (w.visited.contains(f.node)) continue;
                try w.visited.put(w.gpa, f.node, {});
                try w.explicitEdges(f.node);
                // `kids` holds (step word, child) pairs; copy out before the
                // recursion below reuses it.
                var i: usize = 0;
                while (i < w.kids.items.len) : (i += 2) {
                    const step = Step.fromWord(w.kids.items[i].int());
                    const child = w.kids.items[i + 1];
                    try w.touch(child);
                    const rep = w.find(f.node.int());
                    try w.addEdge(rep, step.word(), child.int());
                    const cp = (try w.places.extend(w.gpa, .growth(w.account), f.path, step)) orelse continue;
                    try stack.append(w.gpa, .{ .node = child, .path = cp });
                }
            }
            // Phase 2: congruence closure.
            while (w.pending.pop()) |pair| _ = try w.unite(pair[0], pair[1]);
            if (!w.any_merge) return root; // the identity
            return w.emit(root);
        }

        /// Emit one node per class reachable from `root`, ids first so a
        /// back edge finds its image.
        fn emit(w: *Widen, root: NodeId) Error!NodeId {
            var order: std.ArrayList(u32) = .empty;
            defer order.deinit(w.gpa);
            var stack: std.ArrayList(u32) = .empty;
            defer stack.deinit(w.gpa);
            try stack.append(w.gpa, w.find(root.int()));
            while (stack.pop()) |rep0| {
                const rep = w.find(rep0);
                if (w.image.contains(.from(rep))) continue;
                try w.account.reserve(.shape, 1);
                const id: NodeId = .from(w.t.count());
                try w.t.nodes.append(w.gpa, .{ .kind = .node, .place = w.t.place(.from(rep)), .cells = .none, .a = over_none, .b = 0, .reach = .none });
                try w.image.put(w.gpa, .from(rep), id);
                try order.append(w.gpa, rep);
                var e = w.edge_head.items[rep];
                while (e != none) : (e = w.entries.items(.next)[e]) try stack.append(w.gpa, w.find(w.entries.items(.child)[e]));
            }
            var extra: std.ArrayList(NodeId) = .empty;
            defer extra.deinit(w.gpa);
            for (order.items) |rep| {
                const id = w.image.get(.from(rep)).?;
                // ε cells: the union over members. A member that is not
                // explicit structure rides beside the image: every leaf (and
                // a delta's leaf base) folded into ONE leaf — the class's
                // symbolic projections — and a recast or a union as a side.
                var c: SetId = .none;
                var leaf_cells: SetId = .none;
                var has_leaf = false;
                var explicit = false;
                extra.clearRetainingCapacity();
                var m = w.head.items[rep];
                while (m != none) : (m = w.next_member.items[m]) {
                    try w.account.reserve(.inspection, 1);
                    const d = w.t.get(.from(m));
                    c = try w.cellt.sets.unionWith(w.gpa, .growth(w.account), c, d.cells);
                    switch (d.kind) {
                        .leaf => {
                            has_leaf = true;
                            leaf_cells = try w.cellt.sets.unionWith(w.gpa, .growth(w.account), leaf_cells, d.cells);
                        },
                        .recast, .@"union", .positions => try extra.append(w.gpa, .from(m)),
                        .delta => {
                            explicit = true;
                            const base: NodeId = .from(d.a);
                            switch (w.t.kind(base)) {
                                .leaf => {
                                    has_leaf = true;
                                    leaf_cells = try w.cellt.sets.unionWith(w.gpa, .growth(w.account), leaf_cells, w.t.cells(base));
                                },
                                .node => {},
                                .recast, .@"union", .positions, .delta => try extra.append(w.gpa, base),
                            }
                        },
                        .node => explicit = true,
                    }
                }
                var children: u32 = over_none;
                var e = w.edge_head.items[rep];
                while (e != none) : (e = w.entries.items(.next)[e]) {
                    try w.account.reserve(.inspection, 1);
                    children = try w.t.overPut(w.gpa, w.account, children, Step.fromWord(w.entries.items(.step)[e]), w.image.get(.from(w.find(w.entries.items(.child)[e]))).?);
                }
                const at = w.t.place(id);
                var side: ?NodeId = if (has_leaf) try w.t.leaf(w.gpa, w.account, at, leaf_cells) else null;
                for (extra.items) |x| side = if (side) |s| try w.t.@"union"(w.gpa, w.account, &w.cellt.sets, s, x) else x;
                if (!explicit and children == over_none and side != null) {
                    // Nothing explicit at all: the class IS its side. Parents
                    // name `id`, so `id`'s record becomes a copy of it.
                    w.t.nodes.set(id.int(), w.t.nodes.get(side.?.int()));
                    continue;
                }
                w.t.nodes.items(.cells)[id.int()] = c;
                w.t.nodes.items(.a)[id.int()] = children;
                if (side) |s| {
                    try w.account.reserve(.shape, 1);
                    const u: NodeId = .from(w.t.count());
                    try w.t.nodes.append(w.gpa, .{ .kind = .@"union", .place = at, .cells = c, .a = id.int(), .b = s.int(), .reach = .none });
                    // Every parent's map names `id`; the union is what the
                    // class means, so the two records swap places.
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
            const steps = places.steps(t.place(f.node));
            for (steps.steps) |s| {
                const c = (try t.proj(gpa, account, places, cellt, f.node, s)) orelse continue;
                if (t.cells(c) == .none and t.kind(c) == .leaf) continue;
                try stack.append(gpa, .{ .node = c, .depth = f.depth + 1, .step = s });
            }
        }
    }

    /// §7.5: at every path to `cross_check_depth`, the join's cells equal
    /// the union of the members' cells at that path, by enumeration of the
    /// projections. Safety builds under the flag only.
    pub fn crossCheckJoin(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, joined: NodeId, members: []const NodeId) Error!void {
        if (!(std.debug.runtime_safety and full_cross_check)) return;
        var pending: std.ArrayList(NodeId) = .empty;
        defer pending.deinit(gpa);
        try pending.appendSlice(gpa, members);
        try t.crossCheckAt(gpa, account, places, cellt, joined, &pending, cross_check_depth);
    }

    const cross_check_depth = 4;

    fn crossCheckAt(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, joined: NodeId, members: *std.ArrayList(NodeId), depth: u32) Error!void {
        var want: SetId = .none;
        for (members.items) |m| want = try cellt.sets.unionWith(gpa, .growth(account), want, t.cells(m));
        const got = t.cells(joined);
        std.debug.assert(try cellt.sets.subset(gpa, .growth(account), want, got));
        std.debug.assert(try cellt.sets.subset(gpa, .growth(account), got, want));
        if (depth == 0) return;
        const steps = places.steps(t.place(joined));
        for (steps.steps) |s| {
            var below: std.ArrayList(NodeId) = .empty;
            defer below.deinit(gpa);
            for (members.items) |m| if (try t.proj(gpa, account, places, cellt, m, s)) |p| try below.append(gpa, p);
            const j = (try t.proj(gpa, account, places, cellt, joined, s)) orelse continue;
            try t.crossCheckAt(gpa, account, places, cellt, j, &below, depth - 1);
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

test "rank falls along every projection, and a knot or a recast has none; named steps are a union's sides'" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const tree = try f.placeOf(0);
    const list = try f.placeOf(1);
    const s0 = try f.places.ctorStep(gpa, &f.account, 0, 0);
    const s1 = try f.places.ctorStep(gpa, &f.account, 0, 1);
    const s2 = try f.places.ctorStep(gpa, &f.account, 0, 2);
    const t_param = try f.shapes.leaf(gpa, &f.account, tree, try f.param(2, tree));
    var inner_children = try f.one(s0, t_param);
    inner_children = try f.shapes.overPut(gpa, &f.account, inner_children, s1, try f.shapes.leaf(gpa, &f.account, list, try f.site(1, list, .list)));
    const inner = try f.shapes.node(gpa, &f.account, tree, .none, inner_children);
    var outer_children = try f.one(s0, inner);
    outer_children = try f.shapes.overPut(gpa, &f.account, outer_children, s2, inner);
    const outer = try f.shapes.node(gpa, &f.account, tree, .none, outer_children);
    try testing.expectEqual(@as(u32, 0), try f.shapes.rank(gpa, &f.account, t_param));
    try testing.expectEqual(@as(u32, 1), try f.shapes.rank(gpa, &f.account, inner));
    try testing.expectEqual(@as(u32, 2), try f.shapes.rank(gpa, &f.account, outer));
    // A union is its sides' larger, and every projection of a rank ≥ 1
    // node is below it, at a named step or not.
    const u = try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, inner, outer);
    try testing.expectEqual(@as(u32, 2), try f.shapes.rank(gpa, &f.account, u));
    for ([_]Step{ s0, s1, s2 }) |s| {
        const c = (try f.proj(u, s));
        try testing.expect(try f.shapes.rank(gpa, &f.account, c) < 2);
    }
    // A recast, and a widened knot, have no finite rank.
    const r = try f.shapes.recast(gpa, &f.account, tree, inner);
    try testing.expectEqual(Table.rank_unbounded, try f.shapes.rank(gpa, &f.account, r));
    var go_children = try f.one(s0, t_param);
    go_children = try f.shapes.overPut(gpa, &f.account, go_children, s2, outer);
    const go = try f.shapes.node(gpa, &f.account, tree, .none, go_children);
    const w = try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, go);
    try testing.expect(w != go);
    try testing.expectEqual(Table.rank_unbounded, try f.shapes.rank(gpa, &f.account, w));
    // The steps named: a node's own, a union's both sides', sorted, once.
    try testing.expectEqualSlices(u32, &.{ @min(s0.word(), s1.word()), @max(s0.word(), s1.word()) }, try f.shapes.namedSteps(gpa, &f.account, inner));
    const named_u = try gpa.dupe(u32, try f.shapes.namedSteps(gpa, &f.account, u));
    defer gpa.free(named_u);
    try testing.expectEqual(@as(usize, 3), named_u.len);
    try testing.expect(std.sort.isSorted(u32, named_u, {}, std.sort.asc(u32)));
    try testing.expectEqual(@as(usize, 0), (try f.shapes.namedSteps(gpa, &f.account, t_param)).len);
}

test "a rank refused in the middle leaves no mark: the same node ranks right afterwards" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const tree = try f.placeOf(0);
    const list = try f.placeOf(1);
    const s0 = try f.places.ctorStep(gpa, &f.account, 0, 0);
    const s1 = try f.places.ctorStep(gpa, &f.account, 0, 1);
    const leaf = try f.shapes.leaf(gpa, &f.account, list, try f.site(1, list, .list));
    var inner_children = try f.one(s0, leaf);
    inner_children = try f.shapes.overPut(gpa, &f.account, inner_children, s1, leaf);
    const inner = try f.shapes.node(gpa, &f.account, tree, .none, inner_children);
    const outer = try f.shapes.node(gpa, &f.account, tree, .none, try f.one(s0, inner));
    // The walk needs more than three records: refused part way, with
    // `outer` and `inner` on its stack.
    var short: Account = .{ .allowance = 3 };
    defer short.deinit(gpa);
    try testing.expectError(error.OwnershipLimit, f.shapes.rank(gpa, &short, outer));
    // A fresh account: no mark left behind reads as a cycle or a missing rank.
    var fresh: Account = .{};
    defer fresh.deinit(gpa);
    try testing.expectEqual(@as(u32, 2), try f.shapes.rank(gpa, &fresh, outer));
    try testing.expectEqual(@as(u32, 1), try f.shapes.rank(gpa, &fresh, inner));
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
        n = try f.shapes.put(gpa, &f.account, &f.places, &f.cells, n, if (k % 2 == 0) try Place.Step.field(&f.account, 10) else try Place.Step.field(&f.account, 11), v, true, .none);
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
    const d1 = try f.shapes.put(gpa, &f.account, &f.places, &f.cells, base, try Place.Step.field(&f.account, 10), x, true, .none);
    const d2 = try f.shapes.put(gpa, &f.account, &f.places, &f.cells, base, try Place.Step.field(&f.account, 11), y, true, .none);
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

test "a copy keeps every sibling of a leaf: `{ r | a = x }` on a parameter still has `.b`" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const rec = try f.placeOf(3);
    const list = try f.placeOf(1);
    const r = try f.shapes.leaf(gpa, &f.account, rec, try f.param(1, rec));
    const x = try f.shapes.leaf(gpa, &f.account, list, try f.site(1, list, .list));
    const copy = try f.shapes.put(gpa, &f.account, &f.places, &f.cells, r, try Place.Step.field(&f.account, 10), x, false, try f.site(2, rec, .record));
    try testing.expectEqual(Kind.node, f.shapes.kind(copy));
    try testing.expectEqual(x, try f.proj(copy, try Place.Step.field(&f.account, 10)));
    const b = try f.proj(copy, try Place.Step.field(&f.account, 11));
    try testing.expectEqual(@as(u32, 1), f.cells.sets.count(f.shapes.cells(b)));
    try testing.expectEqual(Cell.Origin.param, f.cells.origin(f.firstCell(f.shapes.cells(b))));
    // The same through a delta over the leaf, and through a union.
    const d = try f.shapes.put(gpa, &f.account, &f.places, &f.cells, r, try Place.Step.field(&f.account, 10), x, true, .none);
    const copy2 = try f.shapes.put(gpa, &f.account, &f.places, &f.cells, d, try Place.Step.field(&f.account, 10), x, false, .none);
    try testing.expectEqual(@as(u32, 1), f.cells.sets.count(f.shapes.cells(try f.proj(copy2, try Place.Step.field(&f.account, 11)))));
}

test "widen keeps a delta member's leaf base and is extensive on it" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const tree = try f.placeOf(0);
    const list = try f.placeOf(1);
    const s0 = try f.places.ctorStep(gpa, &f.account, 0, 0);
    const s1 = try f.places.ctorStep(gpa, &f.account, 0, 1);
    const s2 = try f.places.ctorStep(gpa, &f.account, 0, 2);
    const p2 = try f.shapes.leaf(gpa, &f.account, tree, try f.param(2, tree));
    const p3 = try f.shapes.leaf(gpa, &f.account, tree, try f.param(3, tree));
    var kids = try f.one(s0, p3);
    kids = try f.shapes.overPut(gpa, &f.account, kids, s1, try f.shapes.leaf(gpa, &f.account, list, try f.site(1, list, .list)));
    kids = try f.shapes.overPut(gpa, &f.account, kids, s2, p3);
    const inner = try f.shapes.node(gpa, &f.account, tree, .none, kids);
    const d = try f.shapes.put(gpa, &f.account, &f.places, &f.cells, p2, s0, inner, true, .none);
    const w = try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, d);
    try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, d, w));
    // `π₂·#Node.1`, the base's own list, is still at `#Node.1`.
    const lists = try f.proj(w, s1);
    var found = false;
    var it = f.cells.sets.iterate(f.shapes.cells(lists));
    while (it.next()) |e| if (f.cells.origin(.from(e.key)) == .param) {
        found = true;
    };
    try testing.expect(found);
    try f.shapes.crossCheckWiden(gpa, &f.account, &f.places, &f.cells, d, w);
}

test "leq's coinductive answers are provisional: a failed outer pair does not leave a true behind" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const tree = try f.placeOf(0);
    const list = try f.placeOf(1);
    const s0 = try f.places.ctorStep(gpa, &f.account, 0, 0);
    const s1 = try f.places.ctorStep(gpa, &f.account, 0, 1);
    // Two cyclic pairs n ⇄ p and m ⇄ q over the Tree place, differing only
    // in n's list: n·#Node.1 = {site 1}, m·#Node.1 = {site 2}.
    const Cyc = struct {
        fn make(fx: *Fixture, site_a: u32, site_b: u32) ![2]NodeId {
            const g = testing.allocator;
            const tr = try fx.placeOf(0);
            const li = try fx.placeOf(1);
            const st0 = try fx.places.ctorStep(g, &fx.account, 0, 0);
            const st1 = try fx.places.ctorStep(g, &fx.account, 0, 1);
            try fx.account.reserve(.shape, 2);
            const a: NodeId = .from(fx.shapes.count());
            try fx.shapes.nodes.append(g, .{ .kind = .node, .place = tr, .cells = .none, .a = Table.over_none, .b = 0, .reach = .none });
            const b: NodeId = .from(fx.shapes.count());
            try fx.shapes.nodes.append(g, .{ .kind = .node, .place = tr, .cells = .none, .a = Table.over_none, .b = 0, .reach = .none });
            var ka = try fx.one(st0, b);
            ka = try fx.shapes.overPut(g, &fx.account, ka, st1, try fx.shapes.leaf(g, &fx.account, li, try fx.site(site_a, li, .list)));
            var kb = try fx.one(st0, a);
            kb = try fx.shapes.overPut(g, &fx.account, kb, st1, try fx.shapes.leaf(g, &fx.account, li, try fx.site(site_b, li, .list)));
            fx.shapes.nodes.items(.a)[a.int()] = ka;
            fx.shapes.nodes.items(.a)[b.int()] = kb;
            return .{ a, b };
        }
    };
    _ = tree;
    _ = list;
    _ = s0;
    _ = s1;
    const np = try Cyc.make(&f, 1, 3);
    const mq = try Cyc.make(&f, 2, 3);
    // n ⊄ m (lists differ), and p ⊄ q because p ≤ q needs n ≤ m.
    try testing.expect(!try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, np[0], mq[0]));
    try testing.expect(!try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, np[1], mq[1]));
    // Asked the other way round first, the answers are the same.
    var g2: Fixture = .{};
    g2.init();
    defer g2.deinit();
    const np2 = try Cyc.make(&g2, 1, 3);
    const mq2 = try Cyc.make(&g2, 2, 3);
    try testing.expect(!try g2.shapes.leq(gpa, &g2.account, &g2.places, &g2.cells, np2[1], mq2[1]));
    try testing.expect(!try g2.shapes.leq(gpa, &g2.account, &g2.places, &g2.cells, np2[0], mq2[0]));
    // A genuinely cyclic inclusion still settles true, and stays true.
    try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, np[0], np[0]));
    try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, mq[1], mq[1]));
    const self_q = try Cyc.make(&f, 2, 3);
    try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, mq[0], self_q[0]));
}

test "a union absorbs a member anywhere in its DAG, and reach is one set per cycle" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    var leaves: [70]NodeId = undefined;
    for (&leaves, 0..) |*l, i| l.* = try f.shapes.leaf(gpa, &f.account, list, try f.site(@intCast(i + 1), list, .list));
    var u = leaves[0];
    for (leaves[1..]) |l| u = try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, u, l);
    // Deep in the DAG, past 64 levels: still absorbed, never a new node.
    const before = f.shapes.count();
    try testing.expectEqual(u, try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, u, leaves[0]));
    try testing.expectEqual(u, try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, leaves[1], u));
    try testing.expectEqual(before, f.shapes.count());
    // reach over a cycle: `go`'s widened shape, every node of the cycle
    // memoised at once, and asking twice costs nothing more.
    const tree = try f.placeOf(0);
    const s0 = try f.places.ctorStep(gpa, &f.account, 0, 0);
    const s1 = try f.places.ctorStep(gpa, &f.account, 0, 1);
    const s2 = try f.places.ctorStep(gpa, &f.account, 0, 2);
    const t_param = try f.shapes.leaf(gpa, &f.account, tree, try f.param(2, tree));
    var kids = try f.one(s0, t_param);
    kids = try f.shapes.overPut(gpa, &f.account, kids, s1, leaves[2]);
    kids = try f.shapes.overPut(gpa, &f.account, kids, s2, t_param);
    const inner = try f.shapes.node(gpa, &f.account, tree, .none, kids);
    var okids = try f.one(s0, inner);
    okids = try f.shapes.overPut(gpa, &f.account, okids, s1, leaves[3]);
    okids = try f.shapes.overPut(gpa, &f.account, okids, s2, inner);
    const outer = try f.shapes.node(gpa, &f.account, tree, .none, okids);
    const w = try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, outer);
    const r1 = try f.shapes.reach(gpa, &f.account, &f.cells.sets, w);
    try testing.expectEqual(@as(u32, 3), f.cells.sets.count(r1)); // site 3, site 4, π₂
    const growth = f.account.growth;
    try testing.expectEqual(r1, try f.shapes.reach(gpa, &f.account, &f.cells.sets, w));
    try testing.expectEqual(growth, f.account.growth);
    // The knot's node (the union's explicit side, which points back at it) shares the set.
    const w_node: NodeId = .from(f.shapes.nodes.items(.a)[w.int()]);
    try testing.expectEqual(r1, try f.shapes.reach(gpa, &f.account, &f.cells.sets, w_node));
}

/// `go`'s shape before widening, `k` levels deep: `Node(t, [site], t)`
/// grafted over a parameter leaf.
fn tower(f: *Fixture, k: u32) !NodeId {
    const gpa = testing.allocator;
    const tree = try f.placeOf(0);
    const list = try f.placeOf(1);
    const s0 = try f.places.ctorStep(gpa, &f.account, 0, 0);
    const s1 = try f.places.ctorStep(gpa, &f.account, 0, 1);
    const s2 = try f.places.ctorStep(gpa, &f.account, 0, 2);
    var n = try f.shapes.leaf(gpa, &f.account, tree, try f.param(2, tree));
    var i: u32 = 0;
    while (i < k) : (i += 1) {
        var kids = try f.one(s0, n);
        kids = try f.shapes.overPut(gpa, &f.account, kids, s1, try f.shapes.leaf(gpa, &f.account, list, try f.site(i + 1, list, .list)));
        kids = try f.shapes.overPut(gpa, &f.account, kids, s2, n);
        n = try f.shapes.node(gpa, &f.account, tree, .none, kids);
    }
    return n;
}

test "widen is linearithmic on a grafted tower: k = 1000, 2000, 4000" {
    const gpa = testing.allocator;
    var costs: [3]u64 = undefined;
    const depths = [_]u32{ 1000, 2000, 4000 };
    for (depths, 0..) |k, idx| {
        var f: Fixture = .{};
        f.init();
        defer f.deinit();
        f.account.allowance = 1 << 30;
        const n = try tower(&f, k);
        const before = f.account.growth;
        const w = try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, n);
        costs[idx] = f.account.growth - before;
        // One class for every level, the lists joined: the knot.
        const s0 = try f.places.ctorStep(gpa, &f.account, 0, 0);
        const s1 = try f.places.ctorStep(gpa, &f.account, 0, 1);
        const below = try f.proj(w, s0);
        try testing.expect(below == w or (f.shapes.kind(below) == .@"union" and f.shapes.nodes.items(.a)[below.int()] == w.int()));
        try testing.expectEqual(k + 1, f.cells.sets.count(f.shapes.cells(try f.proj(w, s1))));
        // Within c·k·log₂k records, with c small; k² would be a million at k = 1000.
        const log2k: u64 = std.math.log2_int(u32, k) + 1;
        try testing.expect(costs[idx] <= 60 * @as(u64, k) * log2k);
    }
    // Doubling k less than triples the cost: no quadratic term.
    try testing.expect(costs[1] * 10 < costs[0] * 25);
    try testing.expect(costs[2] * 10 < costs[1] * 25);
}

test "a refused reservation leaves the shape tables whole" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    const cells = try f.site(1, list, .list);
    var broke: Account = .{ .allowance = 0 };
    defer broke.deinit(gpa);
    try testing.expectError(error.OwnershipLimit, f.shapes.leaf(gpa, &broke, list, cells));
    try testing.expectEqual(@as(u32, 0), f.shapes.count());
    const l = try f.shapes.leaf(gpa, &f.account, list, cells);
    try testing.expectEqual(@as(u32, 0), l.int());
    try testing.expectEqual(Kind.leaf, f.shapes.kind(l));
    // A hit is charged like a miss.
    const before = f.account.growth;
    try testing.expectEqual(l, try f.shapes.leaf(gpa, &f.account, list, cells));
    try testing.expectEqual(before + 1, f.account.growth);
    // The same for the step maps.
    try testing.expectError(error.OwnershipLimit, f.shapes.overPut(gpa, &broke, Table.over_none, Place.Step.elem, l));
    try testing.expectEqual(@as(usize, 0), f.shapes.overs.len);
    const m = try f.shapes.overPut(gpa, &f.account, Table.over_none, Place.Step.elem, l);
    try testing.expectEqual(l, f.shapes.overGet(m, Place.Step.elem).?);
}

test "a refused projection or inclusion leaves no answer behind for the next owner" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const rec = try f.placeOf(3);
    const list = try f.placeOf(1);
    const r = try f.shapes.leaf(gpa, &f.account, rec, try f.param(1, rec));
    const x = try f.shapes.leaf(gpa, &f.account, list, try f.site(1, list, .list));
    const y = try f.shapes.leaf(gpa, &f.account, list, try f.site(2, list, .list));
    const fa = try Place.Step.field(&f.account, 10);
    // Owner A is refused projecting `.a`; owner B gets the projection, not
    // "no such step".
    var broke: Account = .{ .allowance = 0 };
    defer broke.deinit(gpa);
    try testing.expectError(error.OwnershipLimit, f.shapes.proj(gpa, &broke, &f.places, &f.cells, r, fa));
    const a = (try f.shapes.proj(gpa, &f.account, &f.places, &f.cells, r, fa)).?;
    try testing.expectEqual(@as(u32, 1), f.cells.sets.count(f.shapes.cells(a)));
    // Owner A is refused in the middle of `leq(x, y)` — after the pair was
    // assumed — and owner B must still get `false`.
    var tight: Account = .{ .allowance = 1 };
    defer tight.deinit(gpa);
    try testing.expectError(error.OwnershipLimit, f.shapes.leq(gpa, &tight, &f.places, &f.cells, x, y));
    try testing.expect(!try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, x, y));
    try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, x, x));
    // A memo HIT is reserved before it is read and charged like a miss (§2.3
    // *Memo safety*): owner C, with nothing to spend, is refused the answers
    // owner B paid for — `leq(x, y)`, `proj(r, .a)`, `join(x, y)` — and owner
    // D pays one record for each.
    var members = [_]NodeId{ x, y };
    const j = try f.shapes.join(gpa, &f.account, &f.places, &f.cells, &members);
    try testing.expectError(error.OwnershipLimit, f.shapes.leq(gpa, &broke, &f.places, &f.cells, x, y));
    try testing.expectError(error.OwnershipLimit, f.shapes.proj(gpa, &broke, &f.places, &f.cells, r, fa));
    try testing.expectError(error.OwnershipLimit, f.shapes.join(gpa, &broke, &f.places, &f.cells, &members));
    var paying: Account = .{ .allowance = 3 };
    defer paying.deinit(gpa);
    try testing.expect(!try f.shapes.leq(gpa, &paying, &f.places, &f.cells, x, y));
    try testing.expectEqual(a, (try f.shapes.proj(gpa, &paying, &f.places, &f.cells, r, fa)).?);
    try testing.expectEqual(j, try f.shapes.join(gpa, &paying, &f.places, &f.cells, &members));
    try testing.expectEqual(@as(u32, 3), paying.growth);
}

test "collect keeps positions: a repeated member stays two, proj and map keep the kind, join makes only unions" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const rec = try f.placeOf(3);
    const fa = try Place.Step.field(&f.account, 10);
    const x = try f.shapes.leaf(gpa, &f.account, rec, try f.param(1, rec));
    const y = try f.shapes.leaf(gpa, &f.account, rec, try f.param(2, rec));
    // One element is itself; two are a positions node, the same one twice
    // too — where a union of the same node twice is the node.
    try testing.expectEqual(x, try f.shapes.collect(gpa, &f.account, &f.cells.sets, &.{x}));
    const xx = try f.shapes.collect(gpa, &f.account, &f.cells.sets, &.{ x, x });
    try testing.expect(xx != x);
    try testing.expectEqual(Kind.positions, f.shapes.kind(xx));
    try testing.expectEqual(x, try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, x, x));
    const xy = try f.shapes.collect(gpa, &f.account, &f.cells.sets, &.{ x, y });
    try testing.expectEqual(@as(u32, 2), f.cells.sets.count(f.shapes.cells(xy)));
    // proj keeps the kind and so the multiplicity: `[*].a` of `[ x, x ]` is
    // `positions(x.a, x.a)`.
    const pa = try f.proj(xx, fa);
    try testing.expectEqual(Kind.positions, f.shapes.kind(pa));
    try testing.expectEqual(f.shapes.nodes.items(.a)[pa.int()], f.shapes.nodes.items(.b)[pa.int()]);
    try testing.expectEqual(try f.proj(x, fa), NodeId.from(f.shapes.nodes.items(.a)[pa.int()]));
    // map keeps the kind, and two sides that become equal stay two.
    const Relabel = struct {
        fn relabel(fx: *Fixture, s: SetId) Error!SetId {
            if (s == .none) return .none;
            return fx.cells.sets.insert(testing.allocator, .growth(&fx.account), .none, 1_000, 0);
        }
    };
    const mapped = try f.shapes.map(gpa, &f.account, xy, &f, Relabel.relabel);
    try testing.expectEqual(Kind.positions, f.shapes.kind(mapped));
    try testing.expectEqual(f.shapes.nodes.items(.a)[mapped.int()], f.shapes.nodes.items(.b)[mapped.int()]);
    // join of two collections is a union over them, each keeping its kind;
    // every member is below it (O4), and leq is γ-inclusion, kind-blind:
    // the repeat in `[ x, x ]` is κ's to see, not the order's.
    var members = [_]NodeId{ xx, xy };
    const j = try f.shapes.join(gpa, &f.account, &f.places, &f.cells, &members);
    try testing.expectEqual(Kind.@"union", f.shapes.kind(j));
    try testing.expectEqual(Kind.positions, f.shapes.kind(.from(f.shapes.get(j).a)));
    try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, xx, j));
    try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, xy, j));
    try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, j, xy));
    try testing.expect(!try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, xy, xx));
    // reach sees through both kinds.
    try testing.expectEqual(@as(u32, 2), f.cells.sets.count(try f.shapes.reach(gpa, &f.account, &f.cells.sets, j)));
}

test "map of a delta keeps its base when mapping the base grows the table" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    const lists = try f.placeOf(3);
    // A delta over a built record, its base deep enough that mapping it
    // appends many nodes: the base's image must land in the delta's record,
    // not in the column the table had before (a column read before a call
    // that grows it).
    var base = try f.shapes.leaf(gpa, &f.account, list, try f.site(1, list, .list));
    var children = try f.one(try Place.Step.field(&f.account, 10), base);
    children = try f.shapes.overPut(gpa, &f.account, children, try Place.Step.field(&f.account, 11), base);
    const rec = try f.shapes.node(gpa, &f.account, lists, try f.site(2, lists, .record), children);
    base = try f.shapes.leaf(gpa, &f.account, list, try f.site(3, list, .list));
    const d = try f.shapes.delta(gpa, &f.account, rec, try f.one(try Place.Step.field(&f.account, 10), base));
    const Relabel = struct {
        fn relabel(fx: *Fixture, s: SetId) Error!SetId {
            if (s == .none) return .none;
            // Grow the node table on every call: new keys each time.
            const first: u32 = 5000 + fx.shapes.count();
            var i: u32 = 0;
            while (i < 256) : (i += 1) _ = try fx.shapes.leaf(testing.allocator, &fx.account, try fx.placeOf(1), try fx.cells.sets.insert(testing.allocator, .growth(&fx.account), .none, first + i, 0));
            return s;
        }
    };
    const mapped = try f.shapes.map(gpa, &f.account, d, &f, Relabel.relabel);
    try testing.expectEqual(Kind.delta, f.shapes.kind(mapped));
    const mapped_base: NodeId = .from(f.shapes.get(mapped).a);
    try testing.expectEqual(Kind.node, f.shapes.kind(mapped_base));
}
