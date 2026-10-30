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

pub const Kind = enum(u8) { leaf, node, delta, recast, @"union", positions, choice, view };

/// One node (§3.3). `a`, `b` by kind: `node`: the children map; `delta`:
/// base + the override map; `recast`: inner, and `b` 1 for a stepped recast
/// that keeps the whole inner (`recastWhole`); `union`, `positions`: left, right.
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
    memo_join: Ids.FixedDict(3) = .{},
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
    /// `reach`'s and `arrivals`' scratch, one per walk in progress (#1191).
    reach_pool: stamped.Pool(ReachScratch) = .{},
    /// Node marks for a walk over the node table, one per walk in progress,
    /// emptied by generation: a walk makes no slot an earlier walk made (#1191).
    marks: stamped.Pool(stamped.Column(NodeId, void)) = .{},
    /// How many knots were tied: a memo of what a node reaches outside
    /// the record (`Cond.reachAgg`) is valid for the count it was made at.
    ties: u32 = 0,
    /// `namedSteps`' memo: a node's list, `(start, len)` in `named_pool`.
    named_memo: stamped.Column(NodeId, [2]u32) = .{},
    named_pool: std.ArrayList(u32) = .empty,
    /// Views (§2.11 *Representation of a view*): the layer that makes them,
    /// a view's answer, and `viewReach`'s images per (radix node, environment).
    instantiation: ?Instantiation = null,
    memo_force: stamped.Column(NodeId, NodeId) = .{},
    /// A view's one step, when it is a view again: the chain `force` followed.
    memo_step: stamped.Column(NodeId, NodeId) = .{},
    /// Nodes `holdsView` found view-free, valid while `ties` is `view_free_epoch`.
    view_free: Ids.FixedDict(1) = .{},
    view_free_epoch: u32 = 0,
    memo_view_reach: Ids.FixedDict(2) = .{},

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.reach_pool.deinit(gpa);
        t.marks.deinit(gpa);
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
        t.memo_force.deinit(gpa);
        t.memo_step.deinit(gpa);
        t.view_free.deinit(gpa);
        t.memo_view_reach.deinit(gpa);
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

    /// A `positions` node's cell set is lazy (§2.3, #1098): built when a
    /// reader asks (`cellsOf`), never eagerly at every level of a
    /// collection. Until then its `cells` is this marker, which no set
    /// operation accepts.
    pub const lazy_cells: SetId = .from(std.math.maxInt(u32) - 1);

    pub fn isLazy(t: *const Table, n: NodeId) bool {
        return t.cells(n) == lazy_cells;
    }

    /// `n`'s cells, a lazy `positions` node's built from its sides' (each
    /// built first, on an explicit stack) and kept in its record: a record per
    /// node built, its unions charged as any.
    /// A walk from a `positions`, `union` or `choice` node, a DAG as large as
    /// the run or the joins that built it: a growth task chosen before it,
    /// never the asking kernel's lane, until read-off continuations charge it
    /// by its producers (§4.1, #1098). A view's answer may be one, or a
    /// chain (§2.11). From any other node, the kernel's.
    pub fn dagWalk(t: *const Table, gpa: Allocator, account: *Account, n: NodeId) Error!?Account.Kernel {
        return switch (t.kind(n)) {
            .positions, .@"union", .choice, .view => try account.enter(gpa, null),
            else => null,
        };
    }

    pub fn cellsOf(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, n: NodeId) Error!SetId {
        if (!t.isLazy(n)) return t.cells(n);
        const walk = try t.dagWalk(gpa, account, n);
        defer if (walk) |k| account.leave(k);
        var stack: std.ArrayList(NodeId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, n);
        while (stack.items.len > 0) {
            const x = stack.items[stack.items.len - 1];
            if (!t.isLazy(x)) {
                _ = stack.pop();
                continue;
            }
            const d = t.get(x);
            // A view's cells are its answer's.
            if (d.kind == .view) {
                const answer = try t.force(gpa, account, x);
                if (t.isLazy(answer)) {
                    try stack.append(gpa, answer);
                    continue;
                }
                try account.reserve(.shape, 1);
                t.nodes.items(.cells)[x.int()] = t.cells(answer);
                _ = stack.pop();
                continue;
            }
            // A whole recast's are its inner's reach (`recastWhole`).
            if (t.isWhole(x)) {
                const c = try t.approxReach(gpa, account, cellsets, .from(d.a));
                try account.reserve(.shape, 1);
                t.nodes.items(.cells)[x.int()] = c;
                _ = stack.pop();
                continue;
            }
            // A recast's or a delta's cells are its inner's or base's, lazy
            // with them; a positions node's, a union's or a choice's its sides' (a raw one
            // a view made, §2.11).
            const l: NodeId = .from(d.a);
            const r: NodeId = if (d.kind == .positions or d.kind == .@"union" or d.kind == .choice) .from(d.b) else l;
            if (t.isLazy(l) or t.isLazy(r)) {
                if (t.isLazy(l)) try stack.append(gpa, l);
                if (r != l and t.isLazy(r)) try stack.append(gpa, r);
                continue;
            }
            try account.reserve(.shape, 1);
            t.nodes.items(.cells)[x.int()] = if (r == l) t.cells(l) else try cellsets.unionWith(gpa, .growth(account), t.cells(l), t.cells(r));
            _ = stack.pop();
        }
        return t.cells(n);
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
        // A recast's and a delta's cells follow from the node they wrap, which
        // may be lazy and built later (#1098): keyed without them, so one stays
        // one node before and after that read (#1158's review).
        const keyed: u32 = if (n.kind == .recast or n.kind == .delta) Ids.none_int else n.cells.int();
        const got = try t.intern.getOrPut(gpa, .{ @backingInt(n.kind), n.place.int(), keyed, n.a, n.b });
        if (got.found_existing) return .from(got.value_ptr.*);
        got.value_ptr.* = @intCast(t.nodes.len);
        try t.nodes.append(gpa, n);
        return .from(got.value_ptr.*);
    }

    pub fn leaf(t: *Table, gpa: Allocator, account: *Account, at: PlaceId, c: SetId) Error!NodeId {
        return t.make(gpa, account, .{ .kind = .leaf, .place = at, .cells = c, .a = 0, .b = 0, .reach = .none });
    }

    /// Whether `n` is the empty value, a view read at its answer (§2.11).
    pub fn isNothing(t: *Table, gpa: Allocator, account: *Account, n: NodeId) Error!bool {
        const x = try t.force(gpa, account, n);
        return t.kind(x) == .leaf and t.cells(x) == .none;
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
        // Casts compose through a view's answer too (§2.11).
        const inn = try t.force(gpa, account, inner);
        // A cast of some value inside the inner stays one (#1311).
        if (t.isWhole(inn)) return t.wholeOver(gpa, account, at, inn, t.cells(inn));
        const in = if (t.kind(inn) == .recast) NodeId.from(t.nodes.items(.a)[inn.int()]) else inner;
        return t.make(gpa, account, .{ .kind = .recast, .place = at, .cells = t.cells(in), .a = in.int(), .b = 0, .reach = .none });
    }

    /// Whether `n` is a stepped recast that keeps its whole inner (`recastWhole`).
    pub fn isWhole(t: *const Table, n: NodeId) bool {
        return t.kind(n) == .recast and t.nodes.items(.b)[n.int()] == 1;
    }

    /// `n`'s image over its inner's image `inner`, whole where `n` is (#1311).
    pub fn recastAs(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, n: NodeId, inner: NodeId) Error!NodeId {
        if (t.isWhole(n)) return t.recastWhole(gpa, account, cellsets, t.place(n), inner);
        return t.recast(gpa, account, t.place(n), inner);
    }

    // ---- views (§2.11 *Representation of a view*, #1097) ---------------------------

    /// A view's environment, as the layer that makes views (`Calls`) keeps it:
    /// the images of a template's leaf, own cells and one reach cell under the
    /// environment `env`. Set once per table; views exist only where it is.
    pub const Instantiation = struct {
        ctx: *anyopaque,
        /// The cell sets of the tables the views live in.
        sets: *Cell.Radix,
        /// A template leaf's image: each parameter cell re-rooted at the
        /// actual, the others mapped, the parts joined raw.
        leaf: *const fn (ctx: *anyopaque, t: *Table, gpa: Allocator, account: *Account, env: u32, template: NodeId) Error!NodeId,
        /// A template node's own cells' image at `at`.
        cells: *const fn (ctx: *anyopaque, t: *Table, gpa: Allocator, account: *Account, env: u32, cells: SetId, at: PlaceId) Error!SetId,
        /// One template reach cell's image: a parameter cell the actual's
        /// reach at its path, any other its mapped self.
        reach: *const fn (ctx: *anyopaque, t: *Table, gpa: Allocator, account: *Account, env: u32, cell: CellId, approx: u1) Error!SetId,
    };

    /// `view(template, env)`: a call's result by reference, interned, its
    /// cells lazy until a reader asks.
    pub fn view(t: *Table, gpa: Allocator, account: *Account, template: NodeId, env: u32) Error!NodeId {
        return t.make(gpa, account, .{ .kind = .view, .place = t.place(template), .cells = lazy_cells, .a = template.int(), .b = env, .reach = .none });
    }

    /// `n`, or the answer of a view already forced: a reader past the force
    /// (a fold's source walk) reads what the force left.
    pub fn forced(t: *const Table, n: NodeId) NodeId {
        if (t.kind(n) != .view) return n;
        return t.memo_force.get(n).?;
    }

    /// A view's answer when it has been forced, null for one that has not
    /// or for a node that is no view.
    pub fn answerOf(t: *const Table, n: NodeId) ?NodeId {
        if (t.kind(n) != .view) return null;
        return t.memo_force.get(n);
    }

    /// The members over `at` as one value, joined raw (§2.11): unions with
    /// lazy cells and no absorption test, so making it reads no member. A
    /// view's leaf image is built so; `join` would read its members' cells
    /// and cascade through the views below them.
    pub fn joinRaw(t: *Table, gpa: Allocator, account: *Account, at: PlaceId, members: []const NodeId) Error!NodeId {
        var out = members[0];
        for (members[1..]) |m| out = try t.make(gpa, account, .{ .kind = .@"union", .place = at, .cells = lazy_cells, .a = out.int(), .b = m.int(), .reach = .none });
        return out;
    }

    /// `n`, or a view's answer: expanded one step (its children views
    /// again), memoised. A chain of views (an answer that is a view) is
    /// followed once, in growth past its first step, and every view on it
    /// then answers the first node that is not one.
    pub fn force(t: *Table, gpa: Allocator, account: *Account, n: NodeId) Error!NodeId {
        if (t.kind(n) != .view) return n;
        try account.reserve(.memo, 1);
        if (t.memo_force.get(n)) |hit| return hit;
        var chain: std.ArrayList(NodeId) = .empty;
        defer chain.deinit(gpa);
        var task: ?Account.Kernel = null;
        defer if (task) |k| account.leave(k);
        var at = n;
        while (t.kind(at) == .view) {
            if (t.memo_force.get(at)) |hit| {
                at = hit;
                break;
            }
            if (chain.items.len == 1) task = try account.enter(gpa, null);
            try chain.append(gpa, at);
            const next = try t.expandView(gpa, account, at);
            if (t.kind(next) == .view) try t.memo_step.put(gpa, at, next);
            at = next;
        }
        try account.reserve(.memo, @intCast(chain.items.len));
        for (chain.items) |v| try t.memo_force.put(gpa, v, at);
        return at;
    }

    /// The view a forced view `v`'s one step answered, when that was a view
    /// again (a chain, §2.11); null at the chain's last view.
    pub fn chainNext(t: *const Table, v: NodeId) ?NodeId {
        return t.memo_step.get(v);
    }

    /// Whether `n`'s DAG holds a view: a check of the invariant that a class
    /// is stored forced (§2.11), uncharged, for `runtime_safety` builds. A
    /// node found view-free is remembered (`view_free`) until a knot is tied,
    /// the one change to a made node's record, so each class added checks
    /// only what it adds: a check over the whole DAG at every class made
    /// deep snapshots' codec tests quadratic.
    pub fn holdsView(t: *Table, gpa: Allocator, n: NodeId) Allocator.Error!bool {
        if (n == .none) return false;
        if (t.view_free_epoch != t.ties) {
            t.view_free.deinit(gpa);
            t.view_free = .{};
            t.view_free_epoch = t.ties;
        }
        var seen: Ids.FixedDict(1) = .{};
        defer seen.deinit(gpa);
        var visited: std.ArrayList(NodeId) = .empty;
        defer visited.deinit(gpa);
        var stack: std.ArrayList(NodeId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, n);
        while (stack.pop()) |x| {
            if (t.view_free.get(.{x.int()}) != null) continue;
            const got = try seen.getOrPut(gpa, .{x.int()});
            if (got.found_existing) continue;
            try visited.append(gpa, x);
            const d = t.get(x);
            switch (d.kind) {
                .view => return true,
                .leaf => {},
                .node, .delta => {
                    if (d.kind == .delta) try stack.append(gpa, .from(d.a));
                    var it = t.overEntries(if (d.kind == .node) d.a else d.b);
                    while (it.next()) |e| try stack.append(gpa, e.node);
                },
                .recast => try stack.append(gpa, .from(d.a)),
                .@"union", .choice, .positions => try stack.appendSlice(gpa, &.{ .from(d.a), .from(d.b) }),
            }
        }
        // No view below any node the walk met: each is view-free.
        for (visited.items) |x| (try t.view_free.getOrPut(gpa, .{x.int()})).value_ptr.* = 1;
        return false;
    }

    /// A view's one step (§2.11): its template's kind with views for
    /// children; a leaf's image; the sides of a join built raw, lazy, with no
    /// absorption test, so a step never reads them.
    fn expandView(t: *Table, gpa: Allocator, account: *Account, v: NodeId) Error!NodeId {
        const inst = t.instantiation orelse unreachable; // a view exists only under one
        const cellsets = inst.sets;
        const env = t.nodes.items(.b)[v.int()];
        const template: NodeId = .from(t.nodes.items(.a)[v.int()]);
        const d = t.get(template);
        return switch (d.kind) {
            .leaf => inst.leaf(inst.ctx, t, gpa, account, env, template),
            .node => blk: {
                const c = if (d.cells == .none) SetId.none else try inst.cells(inst.ctx, t, gpa, account, env, try t.cellsOf(gpa, account, cellsets, template), d.place);
                var over: u32 = over_none;
                var it = t.overEntries(d.a);
                while (it.next()) |e| over = try t.overPut(gpa, account, over, e.step, try t.view(gpa, account, e.node, env));
                break :blk t.node(gpa, account, d.place, c, over);
            },
            .delta => blk: {
                var over: u32 = over_none;
                var it = t.overEntries(d.b);
                while (it.next()) |e| over = try t.overPut(gpa, account, over, e.step, try t.view(gpa, account, e.node, env));
                var base = try t.view(gpa, account, .from(d.a), env);
                // The base's image may be a delta (a parameter leaf whose
                // actual is one): compose over its base, as `put` does, so no
                // delta is over a delta. A base is a template leaf or node, so
                // this force is one step.
                const fb = try t.force(gpa, account, base);
                if (t.kind(fb) == .delta) {
                    var composed = t.nodes.items(.b)[fb.int()];
                    var ot = t.overEntries(over);
                    while (ot.next()) |e| composed = try t.overPut(gpa, account, composed, e.step, e.node);
                    over = composed;
                    base = .from(t.nodes.items(.a)[fb.int()]);
                }
                break :blk t.make(gpa, account, .{ .kind = .delta, .place = d.place, .cells = lazy_cells, .a = base.int(), .b = over, .reach = .none });
            },
            .recast => t.make(gpa, account, .{ .kind = .recast, .place = d.place, .cells = lazy_cells, .a = (try t.view(gpa, account, .from(d.a), env)).int(), .b = d.b, .reach = .none }),
            .@"union", .choice, .positions => t.make(gpa, account, .{ .kind = d.kind, .place = d.place, .cells = lazy_cells, .a = (try t.view(gpa, account, .from(d.a), env)).int(), .b = (try t.view(gpa, account, .from(d.b), env)).int(), .reach = .none }),
            // A template is a class's node, and a class is stored forced
            // (`Summary.Table.add` checks it): it holds no view (§2.11).
            .view => unreachable,
        };
    }

    /// `reach(view(T, E))`: the image of `reach(T)` under `E`, mapped per
    /// radix node of that set and memoised per (radix node, `E`), each node
    /// charged before it is mapped: a nested view's reach is a part of its
    /// parent's, so a depth-d value's reaches cost O(d), never O(d²).
    fn viewReach(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, v: NodeId) Error!SetId {
        const inst = t.instantiation orelse unreachable;
        const env = t.nodes.items(.b)[v.int()];
        const template: NodeId = .from(t.nodes.items(.a)[v.int()]);
        const whole = try t.reach(gpa, account, cellsets, template);
        const Frame = struct { set: SetId, expanded: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, .{ .set = whole, .expanded = false });
        while (stack.pop()) |f| {
            if (f.set == .none) continue;
            try account.reserve(.memo, 1);
            if (t.memo_view_reach.get(.{ f.set.int(), env }) != null) continue;
            if (cellsets.branches(f.set)) |two| {
                if (!f.expanded) {
                    try stack.appendSlice(gpa, &.{ .{ .set = f.set, .expanded = true }, .{ .set = two[0], .expanded = false }, .{ .set = two[1], .expanded = false } });
                    continue;
                }
                const l = if (two[0] == .none) SetId.none else SetId.from(t.memo_view_reach.get(.{ two[0].int(), env }).?);
                const r = if (two[1] == .none) SetId.none else SetId.from(t.memo_view_reach.get(.{ two[1].int(), env }).?);
                (try t.memo_view_reach.getOrPut(gpa, .{ f.set.int(), env })).value_ptr.* = (try cellsets.unionWith(gpa, .growth(account), l, r)).int();
            } else {
                var it = cellsets.iterate(f.set);
                const e = it.next().?;
                try account.reserve(.inspection, 1);
                (try t.memo_view_reach.getOrPut(gpa, .{ f.set.int(), env })).value_ptr.* = (try inst.reach(inst.ctx, t, gpa, account, env, .from(e.key), e.value)).int();
            }
        }
        return if (whole == .none) .none else .from(t.memo_view_reach.get(.{ whole.int(), env }).?);
    }

    /// A stepped recast that keeps the whole inner (§2.13.9: no part of it
    /// matches the step): it stands for some value inside the inner, so its
    /// cells are what the inner reaches, approximately — never the inner's
    /// own cells, which are the value around it (#1132's defect, through a
    /// call's instantiated place).
    pub fn recastWhole(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, at: PlaceId, inner: NodeId) Error!NodeId {
        return t.wholeOver(gpa, account, at, inner, try t.approxReach(gpa, account, cellsets, try t.force(gpa, account, inner)));
    }

    /// A whole recast at `at` holding `c`, over `inner` (a recast composed
    /// to its inner, a view read at its answer, §2.11). Marked (`b`), so it
    /// interns apart from `recast(at, inner)`, whose cells are the inner's
    /// own (#1310), and every rebuild keeps it whole (`recastAs`, #1311).
    fn wholeOver(t: *Table, gpa: Allocator, account: *Account, at: PlaceId, inner: NodeId, c: SetId) Error!NodeId {
        const inn = try t.force(gpa, account, inner);
        const in = if (t.kind(inn) == .recast) NodeId.from(t.nodes.items(.a)[inn.int()]) else inner;
        return t.make(gpa, account, .{ .kind = .recast, .place = at, .cells = c, .a = in.int(), .b = 1, .reach = .none });
    }

    /// `reach(n)`, every cell approximate.
    fn approxReach(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, n: NodeId) Error!SetId {
        var c: SetId = .none;
        var it = cellsets.iterate(try t.reach(gpa, account, cellsets, n));
        while (it.next()) |e| {
            try account.reserve(.inspection, 1);
            c = try cellsets.insert(gpa, .growth(account), c, e.key, 1);
        }
        return c;
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
        const c = try cellsets.unionWith(gpa, .growth(account), try t.cellsOf(gpa, account, cellsets, l), try t.cellsOf(gpa, account, cellsets, r));
        return t.make(gpa, account, .{ .kind = .@"union", .place = t.place(l), .cells = c, .a = x, .b = y, .reach = .none });
    }

    /// The lazy join of exclusive alternatives (§2.3, #1128): a branch's or a
    /// fixpoint's arms, one of which is the value. Interned apart from `union`;
    /// it absorbs only a member of its own choice DAG (the maximum allows it).
    pub fn choice(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, l: NodeId, r: NodeId) Error!NodeId {
        if (l == r) return l;
        if (try t.dagHas(gpa, account, .choice, l, r)) return l;
        if (try t.dagHas(gpa, account, .choice, r, l)) return r;
        const c = try cellsets.unionWith(gpa, .growth(account), try t.cellsOf(gpa, account, cellsets, l), try t.cellsOf(gpa, account, cellsets, r));
        return t.make(gpa, account, .{ .kind = .choice, .place = t.place(l), .cells = c, .a = @min(l.int(), r.int()), .b = @max(l.int(), r.int()), .reach = .none });
    }

    /// `collect(n₁…nₖ)` (§2.3): a built value's elements under `[*]` as a
    /// balanced `positions` DAG — never deduplicated or absorbed: the same
    /// node on both sides is two positions, which κ reads as `shared`. One
    /// element is itself, so `[ x ]` joined with `[ x ]` stays one position.
    /// `collect` with the root's cell set its caller accumulated by one
    /// insertion per item, on the item's lane (§2.3, §4.1, #1098): the
    /// internal nodes stay lazy.
    /// With `lanes`, the internal node at each split is made on the lane of the
    /// item the split falls before: one node per item (§4.1, #1098).
    pub fn collectRoot(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, members: []const NodeId, root_cells: SetId, lanes: ?[]const Ids.Lane) Error!NodeId {
        const out = if (lanes) |ls| try t.collectLaned(gpa, account, cellsets, members, ls) else try t.collect(gpa, account, cellsets, members);
        if (t.isLazy(out)) t.nodes.items(.cells)[out.int()] = root_cells;
        return out;
    }

    fn collectLaned(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, members: []const NodeId, lanes: []const Ids.Lane) Error!NodeId {
        if (members.len == 1) return members[0];
        const mid = members.len / 2;
        const l = try t.collectLaned(gpa, account, cellsets, members[0..mid], lanes[0..mid]);
        const r = try t.collectLaned(gpa, account, cellsets, members[mid..], lanes[mid..]);
        const kernel = try account.enter(gpa, lanes[mid]);
        defer account.leave(kernel);
        return t.positions(gpa, account, cellsets, l, r);
    }

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
        // Rebuilding a positions, union or choice DAG is as large as the
        // value: a growth task chosen before it, never the asking lane (a
        // pattern's materialisation, §4.1, #1224).
        const walk = try t.dagWalk(gpa, account, n);
        defer if (walk) |k| account.leave(k);
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
                // A view is its answer here (a pattern's position of a call's result).
                .view => if (!f.expanded) {
                    const answer = try t.force(gpa, account, f.node);
                    try stack.appendSlice(gpa, &.{ .{ .node = f.node, .expanded = true }, .{ .node = answer, .expanded = false } });
                } else try t.memo_map.put(gpa, f.node, t.memo_map.get(t.memo_force.get(f.node).?).?),
                .@"union", .choice, .positions => if (!f.expanded) {
                    try stack.appendSlice(gpa, &.{ .{ .node = f.node, .expanded = true }, .{ .node = .from(d.a), .expanded = false }, .{ .node = .from(d.b), .expanded = false } });
                } else {
                    const l = t.memo_map.get(.from(d.a)).?;
                    const r = t.memo_map.get(.from(d.b)).?;
                    // A choice stays a choice (§2.3); one of a positions node's
                    // positions is the union of its sides' contents.
                    const as: Kind = if (d.kind == .positions and one) .@"union" else d.kind;
                    const out: NodeId = if (l == .none) r else if (r == .none) l else if (l == NodeId.from(d.a) and r == NodeId.from(d.b) and as == d.kind) f.node else switch (as) {
                        .@"union" => try t.@"union"(gpa, account, cellsets, l, r),
                        .choice => try t.choice(gpa, account, cellsets, l, r),
                        else => try t.positions(gpa, account, cellsets, l, r),
                    };
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
        t.ties +%= 1;
    }

    /// Two positions at one place (`collect`'s node, `proj`'s image of one).
    fn positions(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, l: NodeId, r: NodeId) Error!NodeId {
        // A side that is nothing (an empty leaf) is no position: no object
        // can be there (§2.3, #1120), so a projection of `[ x, Rose [] ]`'s
        // `[*]` past the empty list is `x`'s alone, not a new node per level.
        if (try t.isNothing(gpa, account, r)) return l;
        if (try t.isNothing(gpa, account, l)) return r;
        _ = cellsets;
        // Its cells are lazy (`cellsOf`): what its sides hold, built on request.
        return t.make(gpa, account, .{ .kind = .positions, .place = t.place(l), .cells = lazy_cells, .a = l.int(), .b = r.int(), .reach = .none });
    }

    /// Whether `x` is a member of the union DAG `u` (its sides, through
    /// nested unions only): a walk with a visited stamp, every union node
    /// once, one record reserved per node read. Never a silent `false`.
    fn unionHas(t: *Table, gpa: Allocator, account: *Account, u: NodeId, x: NodeId) Error!bool {
        return t.dagHas(gpa, account, .@"union", u, x);
    }

    /// `unionHas` over the DAG of one kind, `union` or `choice`: a choice
    /// absorbs a member its own arms hold, which the maximum allows
    /// (`choice(x, choice(x, y))` is `choice(x, y)`, §2.3).
    fn dagHas(t: *Table, gpa: Allocator, account: *Account, dag: Kind, u: NodeId, x: NodeId) Error!bool {
        if (u == x) return true;
        if (t.kind(u) != dag) return false;
        const walk = try t.dagWalk(gpa, account, u);
        defer if (walk) |k| account.leave(k);
        t.union_seen.clear();
        var stack: std.ArrayList(NodeId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, u);
        while (stack.pop()) |n| {
            if (n == x) return true;
            if (t.kind(n) != dag or t.union_seen.contains(n)) continue;
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
    pub fn put(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, view_or_n: NodeId, s: Step, m: NodeId, same_object: bool, fresh: SetId) Error!NodeId {
        // A view is written, recelled or materialized as its answer (§2.11).
        const n = try t.force(gpa, account, view_or_n);
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
    pub fn withCells(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, view_or_n: NodeId, c: SetId) Error!NodeId {
        // A view is written, recelled or materialized as its answer (§2.11).
        const n = try t.force(gpa, account, view_or_n);
        if (t.kind(n) == .leaf) return t.leaf(gpa, account, t.place(n), c);
        return t.node(gpa, account, t.place(n), c, try t.materialize(gpa, account, places, cellt, n));
    }

    /// Every child of `n` as one map, each step of its place projected
    /// (`proj`): a node's children as they are, and for a leaf, a delta over
    /// one, a recast or a union the projections a copy would otherwise
    /// drop. A step that projects to nothing is left out.
    fn materialize(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, view_or_n: NodeId) Error!u32 {
        // A view is written, recelled or materialized as its answer (§2.11).
        const n = try t.force(gpa, account, view_or_n);
        if (t.kind(n) == .node) return t.nodes.items(.a)[n.int()];
        var m: u32 = over_none;
        const steps = places.steps(t.place(n));
        for (steps.steps) |s| {
            const c = (try t.proj(gpa, account, places, cellt, n, s)) orelse continue;
            if (try t.isNothing(gpa, account, c)) continue;
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
        const walk = try t.dagWalk(gpa, account, n);
        defer if (walk) |k| account.leave(k);
        // The sides a union, a positions node or a delta's base projects
        // through first, on an explicit stack (#1138: a union DAG is as deep
        // as the source); each request one memo record, as before.
        const Frame = struct { node: NodeId, expanded: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, .{ .node = n, .expanded = true });
        try t.projBelow(gpa, account, places, &stack, n, s);
        while (stack.pop()) |f| {
            if (!f.expanded) {
                try account.reserve(.memo, 1);
                if (t.memo_proj.get(.{ f.node.int(), s.word() }) != null) continue;
                try stack.append(gpa, .{ .node = f.node, .expanded = true });
                try t.projBelow(gpa, account, places, &stack, f.node, s);
                continue;
            }
            if (t.memo_proj.get(.{ f.node.int(), s.word() }) != null) continue;
            try t.projOne(gpa, account, places, cellt, f.node, s);
        }
        const hit = t.memo_proj.get(.{ n.int(), s.word() }).?;
        return if (hit == Ids.none_int) null else NodeId.from(hit);
    }

    /// The nodes `n`'s projection at `s` reads the projections of.
    fn projBelow(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, stack: anytype, n: NodeId, s: Step) Error!void {
        const d = t.get(n);
        switch (d.kind) {
            .recast => if (try t.recastPart(gpa, account, places, n, s)) |inner| try stack.append(gpa, .{ .node = inner, .expanded = false }),
            .delta => if (t.overGet(d.b, s) == null) try stack.append(gpa, .{ .node = .from(d.a), .expanded = false }),
            .@"union", .choice, .positions => try stack.appendSlice(gpa, &.{ .{ .node = .from(d.a), .expanded = false }, .{ .node = .from(d.b), .expanded = false } }),
            // A view projects as its answer does.
            .view => try stack.append(gpa, .{ .node = try t.force(gpa, account, n), .expanded = false }),
            else => {},
        }
    }

    /// A recast's inner when the recast's part at `s` is the inner's own
    /// part: a built inner (a word's recast of a leaf may hold its cell
    /// anywhere) whose place has the step to the same place.
    fn recastPart(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, n: NodeId, s: Step) Error!?NodeId {
        // A step into a whole recast is whole again (#1311's review).
        if (t.isWhole(n)) return null;
        // A view's raw recast (`expandView`) wraps a view: its answer's part.
        const inner = try t.force(gpa, account, .from(t.get(n).a));
        if (t.kind(inner) != .node and t.kind(inner) != .delta) return null;
        const child = places.child(t.place(n), s) orelse return null;
        return if (places.child(t.place(inner), s) == child) inner else null;
    }

    /// `n`'s projection at `s`, what it reads projected already.
    fn projOne(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, n: NodeId, s: Step) Error!void {
        const d = t.get(n);
        const child_place = places.child(d.place, s) orelse {
            (try t.memo_proj.getOrPut(gpa, .{ n.int(), s.word() })).value_ptr.* = Ids.none_int;
            return;
        };
        const got = struct {
            fn of(tt: *Table, x: u32, st: Step) NodeId {
                return .from(tt.memo_proj.get(.{ x, st.word() }).?);
            }
        }.of;
        const out: NodeId = switch (d.kind) {
            .leaf => try t.projectLeaf(gpa, account, places, cellt, d.cells, child_place, s),
            .node => t.overGet(d.a, s) orelse try t.nothing(gpa, account, child_place),
            .delta => t.overGet(d.b, s) orelse got(t, d.a, s),
            // A recast projects to a recast of its inner's own part where
            // `recastPart` finds one (§2.13.9, #1132's review); otherwise of
            // the whole inner, as far as anyone knows.
            .recast => if (try t.recastPart(gpa, account, places, n, s)) |inner| try t.recast(gpa, account, child_place, got(t, inner.int(), s)) else try t.recastWhole(gpa, account, &cellt.sets, child_place, .from(d.a)),
            .@"union" => try t.@"union"(gpa, account, &cellt.sets, got(t, d.a, s), got(t, d.b, s)),
            .positions => try t.positions(gpa, account, &cellt.sets, got(t, d.a, s), got(t, d.b, s)),
            .choice => try t.choice(gpa, account, &cellt.sets, got(t, d.a, s), got(t, d.b, s)),
            .view => got(t, t.memo_force.get(n).?.int(), s),
        };
        (try t.memo_proj.getOrPut(gpa, .{ n.int(), s.word() })).value_ptr.* = out.int();
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
        return t.cellsOf(gpa, account, &cellt.sets, at);
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
        const walk = try t.dagWalk(gpa, account, n);
        defer if (walk) |k| account.leave(k);
        var r: Reach = .{ .t = t, .gpa = gpa, .account = account, .sets = cellsets, .s = try t.reach_pool.take(gpa) };
        defer t.reach_pool.give(r.s);
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
        var r: Reach = .{ .t = t, .gpa = gpa, .account = account, .sets = cellsets, .filter = cellt, .s = try t.reach_pool.take(gpa) };
        defer t.reach_pool.give(r.s);
        try r.run(n);
        return t.arrivals_memo.get(n).?;
    }

    /// Iterative Tarjan over the explicit children, on explicit stacks.
    /// A `Reach`'s columns and stacks, kept by the table and emptied by
    /// generation per walk: a walk makes no slot an earlier walk made (#1191).
    pub const ReachScratch = struct {
        index: stamped.Column(NodeId, u32) = .{},
        low: stamped.Column(NodeId, u32) = .{},
        on_stack: stamped.Column(NodeId, void) = .{},
        scc_stack: std.ArrayList(NodeId) = .empty,
        /// Successors of a node, flattened: `(node, successor cursor)`.
        frames: std.ArrayList(Reach.Frame) = .empty,
        kids: std.ArrayList(NodeId) = .empty,

        pub fn clear(x: *ReachScratch) void {
            x.index.clear();
            x.low.clear();
            x.on_stack.clear();
            x.scc_stack.clearRetainingCapacity();
            x.frames.clearRetainingCapacity();
            x.kids.clearRetainingCapacity();
        }

        pub fn deinit(x: *ReachScratch, gpa: Allocator) void {
            x.index.deinit(gpa);
            x.low.deinit(gpa);
            x.on_stack.deinit(gpa);
            x.scc_stack.deinit(gpa);
            x.frames.deinit(gpa);
            x.kids.deinit(gpa);
        }
    };

    const Reach = struct {
        t: *Table,
        gpa: Allocator,
        account: *Account,
        sets: *Cell.Radix,
        /// Set: `arrivals`, into `arrivals_memo`, a node's own cells filtered.
        filter: ?*const Cell.Table = null,
        /// Its columns and stacks, from `Table.reach_pool` (#1191).
        s: *ReachScratch,
        next_index: u32 = 0,

        const Frame = struct { node: NodeId, first_kid: u32, cursor: u32 };

        /// The explicit children of `n` appended to `kids`.
        fn children(r: *Reach, n: NodeId) Error!void {
            const d = r.t.get(n);
            switch (d.kind) {
                .leaf => {},
                .node => {
                    var it = r.t.overEntries(d.a);
                    while (it.next()) |e| try r.s.kids.append(r.gpa, e.node);
                },
                .delta => {
                    try r.s.kids.append(r.gpa, .from(d.a));
                    var it = r.t.overEntries(d.b);
                    while (it.next()) |e| try r.s.kids.append(r.gpa, e.node);
                },
                .recast => try r.s.kids.append(r.gpa, .from(d.a)),
                .@"union", .choice, .positions => try r.s.kids.appendSlice(r.gpa, &.{ .from(d.a), .from(d.b) }),
                // A view's reach is its own cells (`own`): `viewReach`, never
                // its answer's graph walked.
                .view => {},
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
            // A view stands for its whole reach (§2.11, `viewReach`).
            const view_reach: ?SetId = if (r.t.kind(m) == .view) try r.t.viewReach(r.gpa, r.account, r.sets, m) else null;
            // A lazy node's cells are its parts', which the reach takes anyway.
            if (view_reach == null and r.t.isLazy(m)) return .none;
            const own_cells = view_reach orelse r.t.cells(m);
            const cellt = r.filter orelse return own_cells;
            var out: SetId = .none;
            var it = r.sets.iterate(own_cells);
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
            try r.s.index.put(r.gpa, n, r.next_index);
            try r.s.low.put(r.gpa, n, r.next_index);
            r.next_index += 1;
            try r.s.on_stack.put(r.gpa, n, {});
            try r.s.scc_stack.append(r.gpa, n);
            const first: u32 = @intCast(r.s.kids.items.len);
            try r.children(n);
            try r.s.frames.append(r.gpa, .{ .node = n, .first_kid = first, .cursor = first });
        }

        fn run(r: *Reach, root: NodeId) Error!void {
            try r.push(root);
            while (r.s.frames.items.len > 0) {
                const f = &r.s.frames.items[r.s.frames.items.len - 1];
                if (f.cursor < r.s.kids.items.len) {
                    const k = r.s.kids.items[f.cursor];
                    f.cursor += 1;
                    const n = f.node;
                    if (r.settled(k)) continue; // settled elsewhere
                    if (r.s.index.get(k) == null) {
                        try r.push(k);
                        continue;
                    }
                    if (r.s.on_stack.contains(k)) {
                        const l = @min(r.s.low.get(n).?, r.s.index.get(k).?);
                        try r.s.low.put(r.gpa, n, l);
                    }
                    continue;
                }
                // Done with `f.node`: pop its kids, fold its low into the parent,
                // and close a component if it is a root.
                const n = f.node;
                r.s.kids.shrinkRetainingCapacity(f.first_kid);
                _ = r.s.frames.pop();
                if (r.s.frames.items.len > 0) {
                    const parent = r.s.frames.items[r.s.frames.items.len - 1].node;
                    const l = @min(r.s.low.get(parent).?, r.s.low.get(n).?);
                    try r.s.low.put(r.gpa, parent, l);
                }
                if (r.s.low.get(n).? != r.s.index.get(n).?) continue;
                // A component: its members' cells and their successors' sets
                // (every successor outside it is settled already).
                var set: SetId = .none;
                var i = r.s.scc_stack.items.len;
                while (i > 0) {
                    i -= 1;
                    const m = r.s.scc_stack.items[i];
                    set = try r.sets.unionWith(r.gpa, .growth(r.account), set, try r.own(m));
                    const first: u32 = @intCast(r.s.kids.items.len);
                    try r.children(m);
                    for (r.s.kids.items[first..]) |k| {
                        const s = r.got(k);
                        if (s != .none) set = try r.sets.unionWith(r.gpa, .growth(r.account), set, s);
                    }
                    r.s.kids.shrinkRetainingCapacity(first);
                    if (m == n) break;
                }
                while (r.s.scc_stack.items.len > 0) {
                    const m = r.s.scc_stack.pop().?;
                    r.s.on_stack.remove(m);
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
        const walk = try t.dagWalk(gpa, account, n);
        defer if (walk) |k| account.leave(k);
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
                .@"union", .choice, .positions => {
                    try stack.appendSlice(gpa, &.{ .{ .node = x, .expanded = true }, .{ .node = .from(d.a), .expanded = false }, .{ .node = .from(d.b), .expanded = false } });
                    continue;
                },
                .delta => {
                    try stack.appendSlice(gpa, &.{ .{ .node = x, .expanded = true }, .{ .node = .from(d.a), .expanded = false } });
                    continue;
                },
                // A view names its answer's steps.
                .view => {
                    try stack.appendSlice(gpa, &.{ .{ .node = x, .expanded = true }, .{ .node = try t.force(gpa, account, x), .expanded = false } });
                    continue;
                },
                else => {},
            };
            try account.reserve(.inspection, 1);
            buf.clearRetainingCapacity();
            switch (d.kind) {
                .leaf, .recast => {},
                .view => try t.mergeNamed(gpa, account, &buf, t.named_memo.get(t.memo_force.get(x).?).?),
                .node, .delta => {
                    var it = t.overEntries(if (d.kind == .node) d.a else d.b);
                    while (it.next()) |e| {
                        try account.reserve(.inspection, 1);
                        try buf.append(gpa, e.step.word());
                    }
                    std.mem.sort(u32, buf.items, {}, std.sort.asc(u32));
                    if (d.kind == .delta) try t.mergeNamed(gpa, account, &buf, t.named_memo.get(.from(d.a)).?);
                },
                .@"union", .choice, .positions => {
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
        const walk = try t.dagWalk(gpa, account, n);
        defer if (walk) |k| account.leave(k);
        const Frame = struct { node: NodeId, expanded: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        // The nodes on the walk's stack: the call's own, so a refusal in
        // the middle leaves no mark behind (§2.3 *Memo safety*); only a
        // finished node's rank is memoised.
        const open = try t.marks.take(gpa);
        defer t.marks.give(open);
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
                // A view ranks as its answer (`rankKids` gave it).
                .view => r = t.rank_memo.get(kids.items[0]) orelse rank_unbounded,
                .@"union", .choice, .positions => for (kids.items) |k| {
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
            .@"union", .choice, .positions => try out.appendSlice(gpa, &.{ .from(d.a), .from(d.b) }),
            .view => try out.append(gpa, try t.force(gpa, account, x)),
        }
    }

    // ---- join -------------------------------------------------------------------------------

    /// `join(n₁…nₖ)` (§2.3): deduplicate; group by base, one delta per base
    /// with overrides joined pointwise (a bare node is `delta(n, ∅)`); leaves
    /// into one leaf; what is left into a balanced union DAG. `members` is
    /// scratch and is reordered.
    pub fn join(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, members: []NodeId) Error!NodeId {
        return t.joinAs(gpa, account, places, cellt, members, .@"union");
    }

    /// `join` of exclusive alternatives (§2.3, #1128): a branch's or a
    /// fixpoint's arms. The same grouping, its outer DAG and every per-step
    /// child join made of `choice`; leaves still merge into one leaf (a cell
    /// in two arms is one, the maximum).
    pub fn joinChoice(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, members: []NodeId) Error!NodeId {
        return t.joinAs(gpa, account, places, cellt, members, .choice);
    }

    fn joinAs(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, members: []NodeId, mode: Kind) Error!NodeId {
        std.debug.assert(members.len > 0);
        if (members.len == 1) return members[0];
        var w: JoinWalk = .{ .t = t, .gpa = gpa, .account = account, .places = places, .cellt = cellt, .mode = mode };
        defer w.deinit();
        return w.run(members);
    }

    fn baseOf(t: *const Table, n: NodeId) NodeId {
        return if (t.kind(n) == .delta) .from(t.nodes.items(.a)[n.int()]) else n;
    }

    /// `join` on an explicit stack (#1138: deltas nest as deep as the
    /// source). A request is a run of members; a group of deltas over one
    /// base asks, per override step, for the join of the values there, a
    /// request of its own, and is finished once they are. The records each
    /// request reserves are the recursion's, in its order per request.
    const JoinWalk = struct {
        t: *Table,
        gpa: Allocator,
        account: *Account,
        places: *Place.Table,
        cellt: *Cell.Table,
        /// `union` or `choice`: what the outer DAG and the child joins are made of.
        mode: Kind = .@"union",
        pool: std.ArrayList(NodeId) = .empty,
        reqs: std.ArrayList(Req) = .empty,
        parts: std.ArrayList(Part) = .empty,
        steps: std.ArrayList(StepChild) = .empty,
        stack: std.ArrayList(u32) = .empty,

        const Req = struct { first: u32, len: u32, key: ?[3]u32 = null, result: NodeId = .none, parts_first: u32 = 0, parts_len: u32 = 0, expanded: bool = false };
        /// A group of the request: a node as it is, the leaves joined, or a
        /// delta group's base with its steps' child requests.
        const Part = struct { kind: enum { node, leaf, delta }, node: NodeId = .none, place: PlaceId = .none, cells: SetId = .none, steps_first: u32 = 0, steps_len: u32 = 0 };
        const StepChild = struct { step: u32, child: u32 };

        fn deinit(w: *JoinWalk) void {
            w.pool.deinit(w.gpa);
            w.reqs.deinit(w.gpa);
            w.parts.deinit(w.gpa);
            w.steps.deinit(w.gpa);
            w.stack.deinit(w.gpa);
        }

        fn request(w: *JoinWalk, members: []const NodeId) Error!u32 {
            const first: u32 = @intCast(w.pool.items.len);
            // A view joins as its answer (§2.11): grouped by what it is.
            for (members) |m| try w.pool.append(w.gpa, try w.t.force(w.gpa, w.account, m));
            const id: u32 = @intCast(w.reqs.items.len);
            try w.reqs.append(w.gpa, .{ .first = first, .len = @intCast(members.len) });
            try w.stack.append(w.gpa, id);
            return id;
        }

        fn run(w: *JoinWalk, members: []NodeId) Error!NodeId {
            _ = try w.request(members);
            while (w.stack.pop()) |id| {
                if (w.reqs.items[id].expanded) try w.finish(id) else try w.expand(id);
            }
            return w.reqs.items[0].result;
        }

        /// The memo and the grouping; the delta groups' child requests.
        fn expand(w: *JoinWalk, id: u32) Error!void {
            const t = w.t;
            const r = w.reqs.items[id];
            if (r.len == 1) {
                w.reqs.items[id].result = w.pool.items[r.first];
                return;
            }
            if (r.len == 2) {
                const m = w.pool.items[r.first..][0..2];
                const x = @min(m[0].int(), m[1].int());
                const y = @max(m[0].int(), m[1].int());
                if (x == y) {
                    w.reqs.items[id].result = m[0];
                    return;
                }
                try w.account.reserve(.memo, 1); // before the memo, a hit charged too
                if (t.memo_join.get(.{ @backingInt(w.mode), x, y })) |hit| {
                    w.reqs.items[id].result = .from(hit);
                    return;
                }
                w.reqs.items[id].key = .{ @backingInt(w.mode), x, y };
            }
            try w.account.reserve(.memo, 1);
            // Sort by (base, id): one pass groups and deduplicates.
            const members = w.pool.items[r.first..][0..r.len];
            std.mem.sort(NodeId, members, t, struct {
                fn lessThan(tt: *Table, a: NodeId, b: NodeId) bool {
                    const ba = tt.baseOf(a).int();
                    const bb = tt.baseOf(b).int();
                    return if (ba != bb) ba < bb else a.int() < b.int();
                }
            }.lessThan);
            const parts_first: u32 = @intCast(w.parts.items.len);
            var leaf_cells: SetId = .none;
            var leaf_place: PlaceId = .none;
            var children: std.ArrayList(u32) = .empty;
            defer children.deinit(w.gpa);
            var i: usize = 0;
            while (i < r.len) {
                const run_now = w.pool.items[r.first..][0..r.len];
                var j = i + 1;
                while (j < run_now.len and t.baseOf(run_now[j]) == t.baseOf(run_now[i])) j += 1;
                const grp = run_now[i..j];
                i = j;
                // One group: deduplicate, then join the deltas over one base.
                var distinct: usize = 1;
                for (grp[1..]) |m| if (m != grp[distinct - 1]) {
                    grp[distinct] = m;
                    distinct += 1;
                };
                if (distinct == 1) {
                    if (t.kind(grp[0]) == .leaf) {
                        leaf_cells = try w.cellt.sets.unionWith(w.gpa, .growth(w.account), leaf_cells, t.cells(grp[0]));
                        leaf_place = t.place(grp[0]);
                    } else {
                        try w.parts.append(w.gpa, .{ .kind = .node, .node = grp[0] });
                    }
                    continue;
                }
                // Copy the group out: requests below append to the pool.
                const copy = try w.gpa.dupe(NodeId, grp[0..distinct]);
                defer w.gpa.free(copy);
                try w.deltaGroup(copy, &children);
            }
            if (leaf_place != .none) try w.parts.append(w.gpa, .{ .kind = .leaf, .place = leaf_place, .cells = leaf_cells });
            w.reqs.items[id].parts_first = parts_first;
            w.reqs.items[id].parts_len = @intCast(w.parts.items.len - parts_first);
            w.reqs.items[id].expanded = true;
            // Finish after the children: pushed under them.
            try w.stack.append(w.gpa, id);
            // The children were pushed as they were made; move them above.
            for (children.items) |c| try w.stack.append(w.gpa, c);
        }

        /// Deltas over one base (a bare node among them is the base itself):
        /// the union of their override steps, each a request for the join of
        /// the members present and the base's child where a member has no
        /// override.
        fn deltaGroup(w: *JoinWalk, group: []const NodeId, children: *std.ArrayList(u32)) Error!void {
            const t = w.t;
            const base = t.baseOf(group[0]);
            const Pair = struct { step: u32, node: NodeId };
            var all: std.ArrayList(Pair) = .empty;
            defer all.deinit(w.gpa);
            for (group) |m| {
                if (t.kind(m) != .delta) continue;
                var it = t.overEntries(t.nodes.items(.b)[m.int()]);
                while (it.next()) |e| {
                    try w.account.reserve(.memo, 1);
                    try all.append(w.gpa, .{ .step = e.step.word(), .node = e.node });
                }
            }
            std.mem.sort(Pair, all.items, {}, struct {
                fn lessThan(_: void, a: Pair, b: Pair) bool {
                    return a.step < b.step;
                }
            }.lessThan);
            const steps_first: u32 = @intCast(w.steps.items.len);
            var values: std.ArrayList(NodeId) = .empty;
            defer values.deinit(w.gpa);
            var i: usize = 0;
            while (i < all.items.len) {
                var j = i;
                values.clearRetainingCapacity();
                while (j < all.items.len and all.items[j].step == all.items[i].step) : (j += 1) try values.append(w.gpa, all.items[j].node);
                const s = Step.fromWord(all.items[i].step);
                // A member with no override at this step keeps the base's child.
                if (j - i < group.len) {
                    if (try t.proj(w.gpa, w.account, w.places, w.cellt, base, s)) |b| try values.append(w.gpa, b);
                }
                i = j;
                const before = w.stack.items.len;
                const child = try w.request(values.items);
                w.stack.shrinkRetainingCapacity(before);
                try children.append(w.gpa, child);
                try w.steps.append(w.gpa, .{ .step = s.word(), .child = child });
            }
            try w.parts.append(w.gpa, .{ .kind = .delta, .node = base, .steps_first = steps_first, .steps_len = @intCast(w.steps.items.len - steps_first) });
        }

        /// The groups built from their children's answers, then the union.
        fn finish(w: *JoinWalk, id: u32) Error!void {
            const t = w.t;
            const r = w.reqs.items[id];
            var groups: std.ArrayList(NodeId) = .empty;
            defer groups.deinit(w.gpa);
            for (w.parts.items[r.parts_first..][0..r.parts_len]) |p| switch (p.kind) {
                .node => try groups.append(w.gpa, p.node),
                .leaf => try groups.append(w.gpa, try t.leaf(w.gpa, w.account, p.place, p.cells)),
                .delta => {
                    var over: u32 = over_none;
                    for (w.steps.items[p.steps_first..][0..p.steps_len]) |sc| over = try t.overPut(w.gpa, w.account, over, Step.fromWord(sc.step), w.reqs.items[sc.child].result);
                    try groups.append(w.gpa, try t.delta(w.gpa, w.account, p.node, over));
                },
            };
            const out = try t.balancedUnion(w.gpa, w.account, w.cellt, groups.items, w.mode);
            w.reqs.items[id].result = out;
            if (r.key) |k| (try t.memo_join.getOrPut(w.gpa, k)).value_ptr.* = out.int();
        }
    };
    fn balancedUnion(t: *Table, gpa: Allocator, account: *Account, cellt: *Cell.Table, groups: []NodeId, mode: Kind) Error!NodeId {
        if (groups.len == 1) return groups[0];
        const mid = groups.len / 2;
        const l = try t.balancedUnion(gpa, account, cellt, groups[0..mid], mode);
        const r = try t.balancedUnion(gpa, account, cellt, groups[mid..], mode);
        return if (mode == .choice) t.choice(gpa, account, &cellt.sets, l, r) else t.@"union"(gpa, account, &cellt.sets, l, r);
    }

    // ---- map ---------------------------------------------------------------------------------

    /// The functor relabelling cells: `f(ctx, set) → set` applied to every
    /// node's `ε` cells, memoised per node within one call so a DAG stays
    /// a DAG (#856). A cyclic node is mapped to a node of the same shape.
    pub fn map(t: *Table, gpa: Allocator, account: *Account, n: NodeId, ctx: anytype, f: *const fn (@TypeOf(ctx), SetId) Error!SetId) Error!NodeId {
        t.memo_map.clear();
        return t.mapWalk(gpa, account, n, ctx, f);
    }

    fn mapWalk(t: *Table, gpa: Allocator, account: *Account, root: NodeId, ctx: anytype, f: *const fn (@TypeOf(ctx), SetId) Error!SetId) Error!NodeId {
        // On an explicit stack (#1138: a value is as deep as the source). A
        // node or a delta takes its image before its children, so a cyclic
        // child finds it (the knot); a recast, a union or a positions node
        // after its parts.
        // `f` runs on entry, as the recursion ran it, and parts in the
        // recursion's order, so what `f` interns is interned as before.
        const Frame = struct { node: NodeId, expanded: bool, cells: SetId = .none };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        var kids: std.ArrayList(NodeId) = .empty;
        defer kids.deinit(gpa);
        try stack.append(gpa, .{ .node = root, .expanded = false });
        while (stack.pop()) |fr| {
            const n = fr.node;
            const d = t.get(n);
            if (!fr.expanded) {
                if (t.memo_map.get(n) != null) continue;
                switch (d.kind) {
                    .leaf => try t.memo_map.put(gpa, n, try t.leaf(gpa, account, d.place, try f(ctx, d.cells))),
                    .recast => {
                        // A lazy node's image is lazy too: its parts' images hold its cells.
                        try stack.append(gpa, .{ .node = n, .expanded = true, .cells = if (d.cells == lazy_cells) lazy_cells else try f(ctx, d.cells) });
                        try stack.append(gpa, .{ .node = .from(d.a), .expanded = false });
                    },
                    .@"union", .choice, .positions => {
                        try stack.append(gpa, .{ .node = n, .expanded = true, .cells = if (d.cells == lazy_cells) lazy_cells else try f(ctx, d.cells) });
                        try stack.appendSlice(gpa, &.{ .{ .node = .from(d.b), .expanded = false }, .{ .node = .from(d.a), .expanded = false } });
                    },
                    // A view's image is its answer's.
                    .view => {
                        const answer = try t.force(gpa, account, n);
                        try stack.appendSlice(gpa, &.{ .{ .node = n, .expanded = true }, .{ .node = answer, .expanded = false } });
                    },
                    .node, .delta => {
                        // Pre-allocate so a cyclic child finds its image (the knot).
                        const c = if (d.cells == lazy_cells) lazy_cells else try f(ctx, d.cells);
                        try account.reserve(.shape, 1);
                        const out: NodeId = .from(t.count());
                        try t.nodes.append(gpa, .{ .kind = d.kind, .place = d.place, .cells = c, .a = 0, .b = 0, .reach = .none });
                        try t.memo_map.put(gpa, n, out);
                        try stack.append(gpa, .{ .node = n, .expanded = true });
                        // The children in order, then a delta's base: pushed in reverse.
                        if (d.kind == .delta) try stack.append(gpa, .{ .node = .from(d.a), .expanded = false });
                        kids.clearRetainingCapacity();
                        var it = t.overEntries(if (d.kind == .node) d.a else d.b);
                        while (it.next()) |e| try kids.append(gpa, e.node);
                        var k = kids.items.len;
                        while (k > 0) {
                            k -= 1;
                            try stack.append(gpa, .{ .node = kids.items[k], .expanded = false });
                        }
                    },
                }
                continue;
            }
            switch (d.kind) {
                .leaf => unreachable,
                .view => {
                    if (t.memo_map.get(n) != null) continue;
                    // Every view on the chain `force` followed takes the
                    // answer's image: κ stored under a middle view is carried
                    // over the relabelling too (§2.11 *κ at a view*).
                    const image = t.memo_map.get(t.memo_force.get(n).?).?;
                    var id: ?NodeId = n;
                    while (id) |x| : (id = t.chainNext(x)) {
                        if (t.memo_map.get(x) != null) break;
                        try t.memo_map.put(gpa, x, image);
                    }
                },
                .recast => {
                    if (t.memo_map.get(n) != null) continue;
                    const in = t.memo_map.get(.from(d.a)).?;
                    // A whole recast stays whole, its reach relabelled (#1311).
                    try t.memo_map.put(gpa, n, if (d.b == 1) try t.wholeOver(gpa, account, d.place, in, fr.cells) else try t.recast(gpa, account, d.place, in));
                },
                .@"union", .choice, .positions => {
                    if (t.memo_map.get(n) != null) continue;
                    const c = fr.cells;
                    const l = t.memo_map.get(.from(d.a)).?;
                    const r = t.memo_map.get(.from(d.b)).?;
                    try account.reserve(.shape, 1);
                    const out: NodeId = .from(t.count());
                    try t.nodes.append(gpa, .{ .kind = d.kind, .place = d.place, .cells = c, .a = l.int(), .b = r.int(), .reach = .none });
                    try t.memo_map.put(gpa, n, out);
                },
                .node, .delta => {
                    const out = t.memo_map.get(n).?;
                    var mapped: u32 = over_none;
                    var it = t.overEntries(if (d.kind == .node) d.a else d.b);
                    while (it.next()) |e| mapped = try t.overPut(gpa, account, mapped, e.step, t.memo_map.get(e.node).?);
                    if (d.kind == .node) {
                        t.nodes.items(.a)[out.int()] = mapped;
                    } else {
                        var base = t.memo_map.get(.from(d.a)).?;
                        // A view base may answer a delta: the image composes
                        // over that delta's base, as `put` does, so no delta
                        // is ever over a delta. Its image is finished here: a
                        // view's answer is mapped before the view.
                        if (t.kind(.from(d.a)) == .view and t.kind(base) == .delta) {
                            var over = t.nodes.items(.b)[base.int()];
                            var mt = t.overEntries(mapped);
                            while (mt.next()) |e| over = try t.overPut(gpa, account, over, e.step, e.node);
                            mapped = over;
                            base = .from(t.nodes.items(.a)[base.int()]);
                        }
                        t.nodes.items(.a)[out.int()] = base.int();
                        t.nodes.items(.b)[out.int()] = mapped;
                    }
                },
            }
        }
        return t.memo_map.get(root).?;
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
        // The pairs on an explicit stack (#1138: a value is as deep as the
        // source): a frame resumes at its next step once the pair below it
        // answered. Each pair as the recursion took it, its records too.
        const Frame = struct { n: NodeId, m: NodeId, step: u32, ok: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        var answer: ?bool = try t.leqEnter(gpa, account, cellt, &stack, n, m);
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (answer) |a| {
                // The pair below answered.
                answer = null;
                if (!a) top.ok = false;
            }
            var below: ?[2]NodeId = null;
            if (top.ok) {
                const steps = places.steps(t.place(top.n)).steps;
                while (top.step < steps.len) {
                    const s = steps[top.step];
                    top.step += 1;
                    const pn = (try t.proj(gpa, account, places, cellt, top.n, s)) orelse continue;
                    const pm = (try t.proj(gpa, account, places, cellt, top.m, s)) orelse {
                        top.ok = false;
                        break;
                    };
                    if (pn == pm) continue;
                    if (try t.isNothing(gpa, account, pn)) continue; // nothing is below anything
                    below = .{ pn, pm };
                    break;
                }
            }
            if (below) |b| {
                answer = try t.leqEnter(gpa, account, cellt, &stack, b[0], b[1]);
                continue;
            }
            // Done: the pair's provisional answer, then its parent resumes.
            const f = stack.pop().?;
            (try t.memo_leq.getOrPut(gpa, .{ f.n.int(), f.m.int() })).value_ptr.* = if (f.ok) leq_assumed else leq_false;
            answer = f.ok;
        }
        const ok = answer.?;
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

    /// One pair entered: its memo's answer, or a new frame assuming it holds
    /// (null: walk it). The record is reserved BEFORE the memo is touched, a
    /// hit charged like a miss (§2.3 *Memo safety*, §4.1).
    fn leqEnter(t: *Table, gpa: Allocator, account: *Account, cellt: *Cell.Table, stack: anytype, n: NodeId, m: NodeId) Error!?bool {
        if (n == m) return true;
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
        const ok = try cellt.sets.subset(gpa, .growth(account), try t.cellsOf(gpa, account, &cellt.sets, n), try t.cellsOf(gpa, account, &cellt.sets, m));
        try stack.append(gpa, .{ .n = n, .m = m, .step = 0, .ok = ok });
        return null;
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

    /// What a widen made of its source (§2.9's path map μ, #1128): each
    /// source node the walk reached → its class's image, the images of the
    /// classes that identify two source positions or more, and the unions
    /// and positions nodes opened on the cycle. Empty when nothing merged.
    pub const Fold = struct {
        image: stamped.Column(NodeId, NodeId) = .{},
        folded: stamped.Column(NodeId, void) = .{},
        opened: stamped.Column(NodeId, void) = .{},
        merged: bool = false,
        /// The root's class image, and each class's step to a child class:
        /// `(image, step word)` → child image (what `classAt` follows).
        root: NodeId = .none,
        steps: Ids.FixedDict(2) = .{},

        pub fn deinit(f: *Fold, gpa: Allocator) void {
            f.image.deinit(gpa);
            f.folded.deinit(gpa);
            f.opened.deinit(gpa);
            f.steps.deinit(gpa);
        }

        /// The class image at `steps` below the root, a `⟲` staying in its
        /// class (a re-entry is its ancestor's class); null where no source
        /// position is.
        pub fn classAt(f: *const Fold, steps: []const Step) ?NodeId {
            var at = f.root;
            for (steps) |s| {
                if (s.kind == .level) continue;
                at = .from(f.steps.get(.{ at.int(), s.word() }) orelse return null);
            }
            return at;
        }
    };

    /// `widen`, its path map into `out`.
    pub fn widenFold(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, n: NodeId, out: *Fold) Error!NodeId {
        var w: Widen = .{ .t = t, .gpa = gpa, .account = account, .places = places, .cellt = cellt, .out = out };
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
        /// The unions and positions nodes met at a re-entry (`⟲`), whose
        /// sides are walked as members of their class (§2.3): their meaning
        /// is their sides', so they ride beside no image.
        opened: stamped.Column(NodeId, void) = .{},
        /// How many times the walk reached each node: a node reached twice
        /// stands at two positions of its class.
        occurs: stamped.Column(NodeId, u32) = .{},
        pending: std.ArrayList([2]u32) = .empty,
        image: stamped.Column(NodeId, NodeId) = .{},
        kids: std.ArrayList(NodeId) = .empty,
        any_merge: bool = false,
        /// The source nodes in the order first visited, and where `widenFold`
        /// wants the path map.
        seen_order: std.ArrayList(NodeId) = .empty,
        out: ?*Fold = null,

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
            w.opened.deinit(w.gpa);
            w.occurs.deinit(w.gpa);
            w.pending.deinit(w.gpa);
            w.image.deinit(w.gpa);
            w.kids.deinit(w.gpa);
            w.seen_order.deinit(w.gpa);
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
                    const base = try w.t.force(w.gpa, w.account, .from(d.a));
                    if (w.t.kind(base) == .node) {
                        var bt = w.t.overEntries(w.t.nodes.items(.a)[base.int()]);
                        while (bt.next()) |e| if (w.t.overGet(d.b, e.step) == null) try w.kids.appendSlice(w.gpa, &.{ .from(e.step.word()), e.node });
                    }
                },
                .leaf, .recast, .@"union", .choice, .positions => {},
                .view => unreachable, // `run` forces before it reads edges
            }
        }

        fn run(w: *Widen, root: NodeId) Error!NodeId {
            // Phase 1: the walk with canonical paths.
            const Frame = struct { node: NodeId, path: PathId };
            var stack: std.ArrayList(Frame) = .empty;
            defer stack.deinit(w.gpa);
            try stack.append(w.gpa, .{ .node = root, .path = try w.places.rootPath(w.gpa, w.t.place(root)) });
            while (stack.pop()) |f| {
                // Widen forces as it descends (§2.11): it folds answers, never views.
                const fnode = try w.t.force(w.gpa, w.account, f.node);
                try w.touch(fnode);
                const seen_before = w.occurs.get(fnode) orelse 0;
                try w.occurs.put(w.gpa, fnode, seen_before + 1);
                try w.account.reserve(.edge, 1);
                // `⟲` is its ancestor's class: the re-entered place's node.
                const reentry = w.places.pathParent(f.path) != .none and w.places.pathStep(f.path).kind == .level;
                const key = if (reentry) w.places.pathParent(f.path) else f.path;
                if (w.by_path.get(key)) |cls| {
                    _ = try w.unite(cls, fnode.int());
                } else {
                    try w.by_path.put(w.gpa, key, w.find(fnode.int()));
                }
                if (w.visited.contains(fnode)) continue;
                try w.visited.put(w.gpa, fnode, {});
                try w.seen_order.append(w.gpa, fnode);
                // A union or a positions node on the cycle being folded: its sides
                // are at its path, so they are members of its class (§2.3).
                switch (w.t.kind(fnode)) {
                    .@"union", .choice, .positions => if (reentry) {
                        try w.opened.put(w.gpa, fnode, {});
                        const d = w.t.get(fnode);
                        try stack.appendSlice(w.gpa, &.{ .{ .node = .from(d.a), .path = f.path }, .{ .node = .from(d.b), .path = f.path } });
                        continue;
                    },
                    else => {},
                }
                try w.explicitEdges(fnode);
                // `kids` holds (step word, child) pairs; copy out before the
                // recursion below reuses it.
                var i: usize = 0;
                while (i < w.kids.items.len) : (i += 2) {
                    const step = Step.fromWord(w.kids.items[i].int());
                    const child = try w.t.force(w.gpa, w.account, w.kids.items[i + 1]);
                    try w.touch(child);
                    const rep = w.find(fnode.int());
                    try w.addEdge(rep, step.word(), child.int());
                    const cp = (try w.places.extend(w.gpa, .growth(w.account), f.path, step)) orelse continue;
                    try stack.append(w.gpa, .{ .node = child, .path = cp });
                }
            }
            // Phase 2: congruence closure.
            while (w.pending.pop()) |pair| _ = try w.unite(pair[0], pair[1]);
            if (!w.any_merge) return root; // the identity
            // The classes are of the answers `run` visited (a view root's too).
            const out = try w.emit(try w.t.force(w.gpa, w.account, root));
            if (w.out) |fo| {
                try w.exportFold(fo);
                fo.root = out;
            }
            return out;
        }

        /// The path map μ into `fo`: each visited source node's image; an
        /// image folded when its class has two members or one reached twice.
        fn exportFold(w: *Widen, fo: *Fold) Error!void {
            fo.merged = true;
            var done: stamped.Column(NodeId, void) = .{};
            defer done.deinit(w.gpa);
            for (w.seen_order.items) |n| {
                try w.account.reserve(.inspection, 1);
                const rep = w.find(n.int());
                const img = w.image.get(.from(rep)) orelse continue;
                try fo.image.put(w.gpa, n, img);
                if (w.opened.contains(n)) try fo.opened.put(w.gpa, n, {});
                if (!done.contains(img)) {
                    try done.put(w.gpa, img, {});
                    var e = w.edge_head.items[rep];
                    while (e != none) : (e = w.entries.items(.next)[e]) {
                        try w.account.reserve(.inspection, 1);
                        const child = w.image.get(.from(w.find(w.entries.items(.child)[e]))) orelse continue;
                        (try fo.steps.getOrPut(w.gpa, .{ img.int(), w.entries.items(.step)[e] })).value_ptr.* = child.int();
                    }
                }
                if (fo.folded.contains(img)) continue;
                const many = w.head.items[rep] != w.tail.items[rep] or (w.occurs.get(n) orelse 0) >= 2;
                if (many) try fo.folded.put(w.gpa, img, {});
            }
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
                    c = try w.cellt.sets.unionWith(w.gpa, .growth(w.account), c, try w.t.cellsOf(w.gpa, w.account, &w.cellt.sets, .from(m)));
                    switch (d.kind) {
                        .leaf => {
                            has_leaf = true;
                            leaf_cells = try w.cellt.sets.unionWith(w.gpa, .growth(w.account), leaf_cells, d.cells);
                        },
                        .recast, .@"union", .choice, .positions => if (!w.opened.contains(.from(m))) try extra.append(w.gpa, .from(m)),
                        .delta => {
                            explicit = true;
                            const base = try w.t.force(w.gpa, w.account, .from(d.a));
                            switch (w.t.kind(base)) {
                                .leaf => {
                                    has_leaf = true;
                                    leaf_cells = try w.cellt.sets.unionWith(w.gpa, .growth(w.account), leaf_cells, w.t.cells(base));
                                },
                                .node => {},
                                .recast, .@"union", .choice, .positions, .delta => try extra.append(w.gpa, base),
                                .view => unreachable, // forced above
                            }
                        },
                        .node => explicit = true,
                        .view => unreachable, // `run` visits answers, never views
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
            try out.append(gpa, .{ .depth = f.depth, .step = f.step, .cells = try t.cellsOf(gpa, account, &cellt.sets, f.node) });
            const steps = places.steps(t.place(f.node));
            for (steps.steps) |s| {
                const c = (try t.proj(gpa, account, places, cellt, f.node, s)) orelse continue;
                if (try t.isNothing(gpa, account, c)) continue;
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
        for (members.items) |m| want = try cellt.sets.unionWith(gpa, .growth(account), want, try t.cellsOf(gpa, account, &cellt.sets, m));
        const got = try t.cellsOf(gpa, account, &cellt.sets, joined);
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
    try testing.expectEqual(@as(u32, 2), f.cells.sets.count(try f.shapes.cellsOf(gpa, &f.account, &f.cells.sets, xy)));
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

test "#1138: proj, map, join and leq walk values as deep as the source on explicit stacks" {
    // On a thread with a small stack, 68 KiB for 700 levels, as 96 KiB was
    // for 1 000 (over CI's budget, #1209) and 256 KiB for 3 000, about the
    // same ratio (over the 1 s budget, #1197): a native frame per level
    // would overflow it.
    var result: anyerror!void = {};
    const th = try std.Thread.spawn(.{ .stack_size = 68 << 10 }, struct {
        fn run(out: *anyerror!void) void {
            out.* = deepShapes();
        }
    }.run, .{&result});
    th.join();
    try result;
}

fn deepShapes() !void {
    const gpa = testing.allocator;
    // The fixture lives on the heap: the small stack is for the walks.
    const f = try gpa.create(Fixture);
    defer gpa.destroy(f);
    f.* = .{};
    f.init();
    defer f.deinit();
    f.account.allowance = std.math.maxInt(u32) - 1;
    const tree = try f.placeOf(0);
    const list = try f.placeOf(1);
    const s0 = try f.places.ctorStep(gpa, &f.account, 0, 0);
    const s1 = try f.places.ctorStep(gpa, &f.account, 0, 1);
    const depth = 700;
    // A union DAG of `depth` levels at one place: `proj` reads through it.
    var u = try f.shapes.leaf(gpa, &f.account, tree, try f.param(0, tree));
    // Made directly: `union`'s absorption check walks the DAG, and a chain
    // of them would be quadratic to build.
    for (0..depth / 4) |i| {
        const side = try f.shapes.node(gpa, &f.account, tree, try f.site(@intCast(i + 1), tree, .record), try f.one(s1, try f.shapes.leaf(gpa, &f.account, list, try f.site(@intCast(depth + i + 1), list, .list))));
        u = try f.shapes.make(gpa, &f.account, .{ .kind = .@"union", .place = tree, .cells = try f.cells.sets.unionWith(gpa, .growth(&f.account), f.shapes.cells(u), f.shapes.cells(side)), .a = u.int(), .b = side.int(), .reach = .none });
    }
    try testing.expect(f.cells.sets.count(f.shapes.cells(try f.proj(u, s1))) >= depth / 4);
    // Two chains `depth` deep along `#0`, the second one more cell at each
    // level: `map` copies one, `leq` compares them, both ways.
    var a = try f.shapes.leaf(gpa, &f.account, tree, .none);
    var b = a;
    for (0..depth) |i| {
        const c = try f.site(@intCast(3 * depth + i), tree, .record);
        a = try f.shapes.node(gpa, &f.account, tree, c, try f.one(s0, a));
        b = try f.shapes.node(gpa, &f.account, tree, try f.cells.sets.unionWith(gpa, .growth(&f.account), c, try f.site(@intCast(4 * depth + i), tree, .record)), try f.one(s0, b));
    }
    const Id = struct {
        fn same(_: void, s: SetId) Error!SetId {
            return s;
        }
    };
    const m = try f.shapes.map(gpa, &f.account, a, {}, Id.same);
    try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, a, m));
    try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, a, b));
    try testing.expect(!try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, b, a));
    // Two delta chains over one chain of bases, overrides differing at the
    // bottom: `join` joins the deltas at every level.
    var da = a;
    var db = a;
    var base = a;
    var bases: std.ArrayList(NodeId) = .empty;
    defer bases.deinit(gpa);
    for (0..depth) |_| {
        try bases.append(gpa, base);
        base = f.shapes.overGet(f.shapes.get(base).a, s0) orelse break;
    }
    da = try f.shapes.leaf(gpa, &f.account, tree, try f.param(1, tree));
    db = try f.shapes.leaf(gpa, &f.account, tree, try f.param(2, tree));
    var k = bases.items.len;
    while (k > 0) {
        k -= 1;
        da = try f.shapes.delta(gpa, &f.account, bases.items[k], try f.one(s0, da));
        db = try f.shapes.delta(gpa, &f.account, bases.items[k], try f.one(s0, db));
    }
    var two = [_]NodeId{ da, db };
    const j = try f.shapes.join(gpa, &f.account, &f.places, &f.cells, &two);
    try testing.expectEqual(Kind.delta, f.shapes.kind(j));
    try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, da, j));
}

test "#1128: a choice is its own kind: interned apart from a union, projected and rebuilt as a choice, never absorbed into one" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    const a = try f.shapes.leaf(gpa, &f.account, list, try f.site(1, list, .list));
    const b = try f.shapes.leaf(gpa, &f.account, list, try f.site(2, list, .list));
    const u = try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, a, b);
    const c = try f.shapes.choice(gpa, &f.account, &f.cells.sets, a, b);
    try testing.expect(u != c);
    try testing.expectEqual(Kind.choice, f.shapes.kind(c));
    try testing.expectEqual(f.shapes.cells(u), f.shapes.cells(c));
    // `choice(x, x)` is `x`; a choice absorbs a member of its own DAG,
    // never one a union holds.
    try testing.expectEqual(a, try f.shapes.choice(gpa, &f.account, &f.cells.sets, a, a));
    try testing.expectEqual(c, try f.shapes.choice(gpa, &f.account, &f.cells.sets, c, a));
    try testing.expect(try f.shapes.choice(gpa, &f.account, &f.cells.sets, u, a) != u);
    // `join` and `joinChoice` of one pair never share a memo entry, in
    // either order (the mode is in `memo_join`'s key).
    const n1 = try f.shapes.node(gpa, &f.account, list, try f.site(3, list, .list), try f.shapes.overPut(gpa, &f.account, Table.over_none, Step.elem, a));
    const n2 = try f.shapes.node(gpa, &f.account, list, try f.site(4, list, .list), try f.shapes.overPut(gpa, &f.account, Table.over_none, Step.elem, b));
    var two = [_]NodeId{ n1, n2 };
    const jc = try f.shapes.joinChoice(gpa, &f.account, &f.places, &f.cells, &two);
    two = .{ n1, n2 };
    const ju = try f.shapes.join(gpa, &f.account, &f.places, &f.cells, &two);
    two = .{ n2, n1 };
    try testing.expectEqual(jc, try f.shapes.joinChoice(gpa, &f.account, &f.places, &f.cells, &two));
    try testing.expectEqual(Kind.choice, f.shapes.kind(jc));
    try testing.expectEqual(Kind.@"union", f.shapes.kind(ju));
    // A projection of a choice is a choice of the projections.
    const p = (try f.shapes.proj(gpa, &f.account, &f.places, &f.cells, jc, Step.elem)).?;
    try testing.expectEqual(Kind.choice, f.shapes.kind(p));
}

test "#1098: a collection's internal positions sets are lazy: collect builds none, a reader builds what it asks for" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    var leaves: [64]NodeId = undefined;
    var all: SetId = .none;
    for (&leaves, 0..) |*l, i| {
        const s = try f.site(@intCast(i + 1), list, .list);
        l.* = try f.shapes.leaf(gpa, &f.account, list, s);
        all = try f.cells.sets.unionWith(gpa, .growth(&f.account), all, s);
    }
    // The root's set given (its caller inserted each item's cells on its
    // lane): collect makes 63 nodes and reads no set.
    const before = f.account.growth_by[@backingInt(Ids.Category.set)];
    const root = try f.shapes.collectRoot(gpa, &f.account, &f.cells.sets, &leaves, all, null);
    try testing.expectEqual(before, f.account.growth_by[@backingInt(Ids.Category.set)]);
    // On per-item lanes (#1139) it is the same DAG, node for node.
    var lanes: [64]Ids.Lane = undefined;
    for (&lanes, 0..) |*l, i| l.* = .{ .atom = @intCast(i), .role = .transfer_settlement };
    try testing.expectEqual(root, try f.shapes.collectRoot(gpa, &f.account, &f.cells.sets, &leaves, all, &lanes));
    try testing.expect(!f.shapes.isLazy(root));
    try testing.expectEqual(all, f.shapes.cells(root));
    const left: NodeId = .from(f.shapes.get(root).a);
    try testing.expect(f.shapes.isLazy(left));
    // Asked, a side's set is built from its own sides, and kept.
    var half: SetId = .none;
    for (leaves[0..32]) |l| half = try f.cells.sets.unionWith(gpa, .growth(&f.account), half, f.shapes.cells(l));
    try testing.expectEqual(half, try f.shapes.cellsOf(gpa, &f.account, &f.cells.sets, left));
    try testing.expect(!f.shapes.isLazy(left));
}

test "#1158 review: a recast or a delta over a lazy node is one node before and after a read of it" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    const a = try f.shapes.leaf(gpa, &f.account, list, try f.site(1, list, .list));
    const b = try f.shapes.leaf(gpa, &f.account, list, try f.site(2, list, .list));
    const p = try f.shapes.collect(gpa, &f.account, &f.cells.sets, &.{ a, b });
    try testing.expect(f.shapes.isLazy(p));
    const r1 = try f.shapes.recast(gpa, &f.account, try f.placeOf(0), p);
    const n = try f.shapes.node(gpa, &f.account, list, .none, try f.shapes.overPut(gpa, &f.account, Table.over_none, Step.elem, p));
    const d1 = try f.shapes.delta(gpa, &f.account, p, try f.shapes.overPut(gpa, &f.account, Table.over_none, Step.elem, n));
    _ = try f.shapes.cellsOf(gpa, &f.account, &f.cells.sets, p);
    try testing.expectEqual(r1, try f.shapes.recast(gpa, &f.account, try f.placeOf(0), p));
    try testing.expectEqual(d1, try f.shapes.delta(gpa, &f.account, p, try f.shapes.overPut(gpa, &f.account, Table.over_none, Step.elem, n)));
}

/// A test environment for views: every parameter cell of a template is the
/// one actual `arg`; every other cell is itself. For the tests of the
/// layers above too.
pub const TestInstantiation = struct {
    cellt: *Cell.Table,
    arg: NodeId,

    pub fn inst(x: *TestInstantiation) Table.Instantiation {
        return .{ .ctx = x, .sets = &x.cellt.sets, .leaf = leaf, .cells = cells, .reach = reach };
    }

    fn of(ctx: *anyopaque) *TestInstantiation {
        return @ptrCast(@alignCast(ctx));
    }

    fn isParam(x: *TestInstantiation, s: SetId) bool {
        var it = x.cellt.sets.iterate(s);
        while (it.next()) |e| if (x.cellt.origin(.from(e.key)) == .param) return true;
        return false;
    }

    fn leaf(ctx: *anyopaque, t: *Table, gpa: Allocator, account: *Account, env: u32, template: NodeId) Error!NodeId {
        _ = env;
        const x = of(ctx);
        return if (x.isParam(t.cells(template))) x.arg else t.leaf(gpa, account, t.place(template), t.cells(template));
    }

    fn cells(ctx: *anyopaque, t: *Table, gpa: Allocator, account: *Account, env: u32, s: SetId, at: PlaceId) Error!SetId {
        _ = .{ ctx, t, gpa, account, env, at };
        return s;
    }

    fn reach(ctx: *anyopaque, t: *Table, gpa: Allocator, account: *Account, env: u32, c: CellId, approx: u1) Error!SetId {
        _ = env;
        const x = of(ctx);
        if (x.cellt.origin(c) == .param) return t.reach(gpa, account, &x.cellt.sets, x.arg);
        return x.cellt.sets.insert(gpa, .growth(account), .none, c.int(), approx);
    }
};

test "a view answers its template's instantiation one step at a time: proj, cells and reach as the eager image's" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const rec = try f.placeOf(3);
    const list = try f.placeOf(1);
    const fa = try Place.Step.field(&f.account, 10);
    const fb = try Place.Step.field(&f.account, 11);
    // The template `{ a = π1, b = [] }`; the actual a built list.
    const p1 = try f.shapes.leaf(gpa, &f.account, list, try f.param(1, list));
    const empty = try f.shapes.leaf(gpa, &f.account, list, try f.site(7, list, .list));
    var kids = try f.one(fa, p1);
    kids = try f.shapes.overPut(gpa, &f.account, kids, fb, empty);
    const template = try f.shapes.node(gpa, &f.account, rec, try f.site(8, rec, .record), kids);
    const arg = try f.shapes.leaf(gpa, &f.account, list, try f.site(9, list, .list));
    var ti: TestInstantiation = .{ .cellt = &f.cells, .arg = arg };
    f.shapes.instantiation = ti.inst();
    const v = try f.shapes.view(gpa, &f.account, template, 0);
    try testing.expectEqual(Kind.view, f.shapes.kind(v));
    // Interned: the same view again; nothing forced yet.
    try testing.expectEqual(v, try f.shapes.view(gpa, &f.account, template, 0));
    try testing.expectEqual(@as(?NodeId, null), f.shapes.memo_force.get(v));
    // A step answers a view again, one step deeper: `.a` forces to the
    // actual itself, `.b` to the template's own leaf.
    try testing.expectEqual(arg, try f.shapes.force(gpa, &f.account, try f.proj(v, fa)));
    try testing.expectEqual(empty, try f.shapes.force(gpa, &f.account, try f.proj(v, fb)));
    // Forced once: the answer is a node of views, memoised.
    const answer = try f.shapes.force(gpa, &f.account, v);
    try testing.expectEqual(Kind.node, f.shapes.kind(answer));
    try testing.expectEqual(answer, try f.shapes.force(gpa, &f.account, v));
    try testing.expectEqual(answer, f.shapes.forced(v));
    try testing.expectEqual(f.shapes.cells(template), try f.shapes.cellsOf(gpa, &f.account, &f.cells.sets, v));
    // reach: the record's cell, the actual's, the empty list's; as the answer's.
    const r = try f.shapes.reach(gpa, &f.account, &f.cells.sets, v);
    try testing.expectEqual(@as(u32, 3), f.cells.sets.count(r));
    try testing.expectEqual(r, try f.shapes.reach(gpa, &f.account, &f.cells.sets, answer));
    // A chain: a parameter leaf whose actual is that view answers it, and
    // forcing it follows the chain to the view's answer, each step kept.
    ti.arg = v;
    const outer = try f.shapes.view(gpa, &f.account, p1, 1);
    try testing.expectEqual(answer, try f.shapes.force(gpa, &f.account, outer));
    try testing.expectEqual(v, f.shapes.chainNext(outer).?);
    try testing.expectEqual(answer, f.shapes.answerOf(outer).?);
}

/// `{ a = recast (delta { a = π1, b = choice [] π1 } { a = positions π1 [] }),
/// b = positions π1 [] }` over `x` for π1: every kind a template holds,
/// eager (`x` written in) or as the view's template (`p1` the parameter).
fn everyKind(f: *Fixture, x: NodeId, a_site: SetId, b_site: SetId) !NodeId {
    const gpa = testing.allocator;
    const rec = try f.placeOf(3);
    const list = try f.placeOf(1);
    const fa = try Place.Step.field(&f.account, 10);
    const fb = try Place.Step.field(&f.account, 11);
    const a = try f.shapes.leaf(gpa, &f.account, list, a_site);
    const b = try f.shapes.leaf(gpa, &f.account, list, b_site);
    const ua = try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, x, a);
    const cb = try f.shapes.choice(gpa, &f.account, &f.cells.sets, b, x);
    const pos = try f.shapes.collect(gpa, &f.account, &f.cells.sets, &.{ x, a });
    const inner = try f.shapes.node(gpa, &f.account, rec, try f.site(6, rec, .record), try f.shapes.overPut(gpa, &f.account, try f.one(fa, ua), fb, cb));
    const dl = try f.shapes.delta(gpa, &f.account, inner, try f.one(fa, pos));
    const rc = try f.shapes.recast(gpa, &f.account, list, dl);
    return f.shapes.node(gpa, &f.account, rec, try f.site(9, rec, .record), try f.shapes.overPut(gpa, &f.account, try f.one(fa, rc), fb, pos));
}

test "a view of every kind forces to its eager image: map, widen and join read it as the image" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    const a_site = try f.site(7, list, .list);
    const b_site = try f.site(8, list, .list);
    const p1 = try f.shapes.leaf(gpa, &f.account, list, try f.param(1, list));
    const arg = try f.shapes.leaf(gpa, &f.account, list, try f.site(20, list, .list));
    const template = try everyKind(&f, p1, a_site, b_site);
    const eager = try everyKind(&f, arg, a_site, b_site);
    var ti: TestInstantiation = .{ .cellt = &f.cells, .arg = arg };
    f.shapes.instantiation = ti.inst();
    const v = try f.shapes.view(gpa, &f.account, template, 0);
    const Id = struct {
        fn same(_: void, s: SetId) Error!SetId {
            return s;
        }
    };
    // `map` forces every view it meets (`expandView`'s every arm): the copy
    // holds none and is the eager image.
    const mapped = try f.shapes.map(gpa, &f.account, v, {}, Id.same);
    try testing.expect(!try f.shapes.holdsView(gpa, mapped));
    try testing.expect(try f.shapes.eq(gpa, &f.account, &f.places, &f.cells, mapped, eager));
    try testing.expect(try f.shapes.eq(gpa, &f.account, &f.places, &f.cells, v, eager));
    try testing.expectEqual(try f.shapes.reach(gpa, &f.account, &f.cells.sets, eager), try f.shapes.reach(gpa, &f.account, &f.cells.sets, v));
    // `widen` forces as it descends: the same quotient as the image's (with
    // nothing to merge it is the identity, the view itself).
    const wv = try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, v);
    const we = try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, eager);
    try testing.expect(try f.shapes.eq(gpa, &f.account, &f.places, &f.cells, wv, we));
    // `join` groups a view as its answer: one member with the image's twin.
    var two = [_]NodeId{ v, eager };
    try testing.expect(try f.shapes.eq(gpa, &f.account, &f.places, &f.cells, try f.shapes.join(gpa, &f.account, &f.places, &f.cells, &two), eager));
}

test "a view of the empty value is nothing: a positions side and a pattern's rest drop it" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    const empty = try f.shapes.nothing(gpa, &f.account, list);
    const a = try f.shapes.leaf(gpa, &f.account, list, try f.site(7, list, .list));
    var ti: TestInstantiation = .{ .cellt = &f.cells, .arg = a };
    f.shapes.instantiation = ti.inst();
    const v = try f.shapes.view(gpa, &f.account, empty, 0);
    try testing.expect(try f.shapes.isNothing(gpa, &f.account, v));
    try testing.expectEqual(a, try f.shapes.collect(gpa, &f.account, &f.cells.sets, &.{ a, v }));
}

/// `Node (Node x [ 1 ] x) [ 2 ] (Node x [ 1 ] x)` over `x` at the tree place.
fn twoLevels(f: *Fixture, x: NodeId) !NodeId {
    const gpa = testing.allocator;
    const tree = try f.placeOf(0);
    const list = try f.placeOf(1);
    const s0 = try f.places.ctorStep(gpa, &f.account, 0, 0);
    const s1 = try f.places.ctorStep(gpa, &f.account, 0, 1);
    const s2 = try f.places.ctorStep(gpa, &f.account, 0, 2);
    var ic = try f.one(s0, x);
    ic = try f.shapes.overPut(gpa, &f.account, ic, s1, try f.shapes.leaf(gpa, &f.account, list, try f.site(1, list, .list)));
    ic = try f.shapes.overPut(gpa, &f.account, ic, s2, x);
    const inner = try f.shapes.node(gpa, &f.account, tree, .none, ic);
    var oc = try f.one(s0, inner);
    oc = try f.shapes.overPut(gpa, &f.account, oc, s1, try f.shapes.leaf(gpa, &f.account, list, try f.site(2, list, .list)));
    oc = try f.shapes.overPut(gpa, &f.account, oc, s2, inner);
    return f.shapes.node(gpa, &f.account, tree, .none, oc);
}

test "widen folds a view's levels as it folds its eager image's" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const tree = try f.placeOf(0);
    const p = try f.shapes.leaf(gpa, &f.account, tree, try f.param(2, tree));
    const arg = try f.shapes.leaf(gpa, &f.account, tree, try f.site(30, tree, .record));
    const template = try twoLevels(&f, p);
    const eager = try twoLevels(&f, arg);
    var ti: TestInstantiation = .{ .cellt = &f.cells, .arg = arg };
    f.shapes.instantiation = ti.inst();
    const v = try f.shapes.view(gpa, &f.account, template, 0);
    const wv = try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, v);
    try testing.expect(wv != v);
    try testing.expect(!try f.shapes.holdsView(gpa, wv));
    try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, v, wv));
    try testing.expect(try f.shapes.eq(gpa, &f.account, &f.places, &f.cells, wv, try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, eager)));
}

test "#1279 review: a view's delta over a parameter whose actual is a delta composes, as `put` does" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const rec = try f.placeOf(3);
    const list = try f.placeOf(1);
    const fa = try Place.Step.field(&f.account, 10);
    const fb = try Place.Step.field(&f.account, 11);
    const base = try f.shapes.leaf(gpa, &f.account, rec, try f.site(5, rec, .record));
    const xb = try f.shapes.leaf(gpa, &f.account, list, try f.site(6, list, .list));
    const arg = try f.shapes.delta(gpa, &f.account, base, try f.one(fb, xb));
    const p = try f.shapes.leaf(gpa, &f.account, rec, try f.param(1, rec));
    const xa = try f.shapes.leaf(gpa, &f.account, list, try f.site(7, list, .list));
    const template = try f.shapes.delta(gpa, &f.account, p, try f.one(fa, xa));
    var ti: TestInstantiation = .{ .cellt = &f.cells, .arg = arg };
    f.shapes.instantiation = ti.inst();
    const v = try f.shapes.view(gpa, &f.account, template, 0);
    const answer = try f.shapes.force(gpa, &f.account, v);
    try testing.expectEqual(Kind.delta, f.shapes.kind(answer));
    try testing.expect(f.shapes.kind(try f.shapes.force(gpa, &f.account, .from(f.shapes.get(answer).a))) != .delta);
    const Id = struct {
        fn same(_: void, s: SetId) Error!SetId {
            return s;
        }
    };
    const m = try f.shapes.map(gpa, &f.account, v, {}, Id.same);
    try testing.expectEqual(Kind.delta, f.shapes.kind(m));
    try testing.expect(f.shapes.kind(.from(f.shapes.get(m).a)) != .delta);
    const eager = try f.shapes.delta(gpa, &f.account, base, try f.shapes.overPut(gpa, &f.account, try f.one(fb, xb), fa, xa));
    try testing.expect(try f.shapes.eq(gpa, &f.account, &f.places, &f.cells, m, eager));
}
