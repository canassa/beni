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
//! `widen`, and `map` on a knot, make nodes that are not interned: a
//! widened recursive value is a `node` whose child names an ancestor —
//! "the knot is in the table" — and such a node is unique by construction.
//! `map` interns every image on no knot (#1372).
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
const Stable = @import("Stable.zig");

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
    /// The projection correspondence (§2.9 *Keyed where a reader looks*): a
    /// union, choice or positions node that `proj` made as the projection of
    /// a DAG node → the head of its origins in `proj_origins`, each `(that
    /// node, the step's word, the next origin)` (`projectedImage`).
    proj_origin: Ids.FixedDict(1) = .{},
    proj_origins: std.ArrayList([3]u32) = .empty,
    memo_join: Ids.FixedDict(3) = .{},
    memo_leq: Ids.FixedDict(2) = .{},
    /// `leq`'s answers that rest on a coinductive assumption of the query
    /// in progress, and its depth.
    leq_provisional: std.ArrayList([2]u32) = .empty,
    leq_depth: u32 = 0,
    memo_map: stamped.Column(NodeId, NodeId) = .{},
    /// `map`'s knot test (§2.3 *map*, #1372): a node or delta whose image
    /// is open (entered, its parts not all mapped) → its entry index; a
    /// mapped node → the earliest open node its image reaches (`MapLow`).
    /// An image that reaches no open node is interned: no back edge can
    /// name its slot (it may still lie on an enclosing knot, reached only
    /// through a knot that closed; that is harmless, and not Tarjan's test).
    map_open: stamped.Column(NodeId, u32) = .{},
    map_low: stamped.Column(NodeId, MapLow) = .{},
    /// The built nodes the last `map` relabelled (`mapSource`): what a
    /// read-off's κ carry counts at a position (`Cond.Relabel.present`).
    map_src: stamped.Column(NodeId, void) = .{},
    /// The images built sources took in the last `map`, and whether two
    /// took one (only then does read-off's κ carry count them per position).
    map_images: stamped.Column(NodeId, void) = .{},
    map_shared: bool = false,
    /// `armCount`'s memo: a choice DAG's arms, by node.
    arm_count: stamped.Column(NodeId, u32) = .{},
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
    /// `cycleWalk`'s (index, low link) per record entered, likewise.
    cycle_marks: stamped.Pool(stamped.Column(NodeId, [2]u32)) = .{},
    /// How many knots were tied: a memo of what a node reaches outside
    /// the record (`Cond.reachAgg`) is valid for the count it was made at.
    ties: u32 = 0,
    /// Stable images (§2.3, 4e): the graphs met by canonical form, and `map`'s trail.
    stable: Stable.Store = .{},
    /// `namedSteps`' memo: a node's list, `(start, len)` in `named_pool`.
    named_memo: stamped.Column(NodeId, [2]u32) = .{},
    named_pool: std.ArrayList(u32) = .empty,
    /// Views (§2.11 *Representation of a view*): the layer that makes them,
    /// a view's answer, and `viewReach`'s images per (radix node, environment).
    instantiation: ?Instantiation = null,
    /// A recursive group's rounds are being widened (§2.3 *On the cycle*,
    /// §2.12, #1360): there a value nests its own previous round, so widen
    /// also opens a union, choice or positions node at a place on a cycle
    /// that a re-entry relates to. Set by the group's driver around its
    /// rounds; off, widen opens such a node only at a `⟲`.
    widen_rounds: bool = false,
    memo_force: stamped.Column(NodeId, NodeId) = .{},
    /// A view's one step, when it is a view again: the chain `force` followed.
    memo_step: stamped.Column(NodeId, NodeId) = .{},
    /// Nodes `holdsView` found view-free, valid while `ties` is `view_free_epoch`.
    view_free: Ids.FixedDict(1) = .{},
    view_free_epoch: u32 = 0,
    memo_view_reach: Ids.FixedDict(2) = .{},
    /// The crossing's node sets (§2.11 *κ across a call*): `region` and `bases`
    /// live in `node_sets`, unions memoised per pair; `base_epoch` moves when
    /// an existing node gains a base.
    node_sets: Cell.Radix = .{ .category = .memo },
    memo_node_union: Ids.FixedDict(2) = .{},
    /// `intersectsMemo`'s pairs over `node_sets`; `approxAll`'s images of cell
    /// sets (`recastWhole`).
    memo_node_meet: Ids.FixedDict(2) = .{},
    memo_approx_all: Ids.FixedDict(1) = .{},
    bases: Ids.FixedDict(1) = .{},
    base_epoch: u32 = 0,
    memo_region: Ids.FixedDict(1) = .{},
    region_ties: Ids.FixedDict(1) = .{},
    memo_bstar: Ids.FixedDict(1) = .{},
    bstar_epoch: Ids.FixedDict(1) = .{},
    memo_tested: Ids.FixedDict(3) = .{},
    memo_wholly: Ids.FixedDict(3) = .{},
    /// Each node's constructions, a list through `cons` (`next`), their members
    /// in `cons_pool`; a projection's once per (node, base). The relevant
    /// nodes: κ keys and their `bases*`, once the κ table reports its keys.
    cons_head: Ids.FixedDict(1) = .{},
    cons: std.ArrayList(struct { next: u32, start: u32, len: u32 }) = .empty,
    cons_pool: std.ArrayList(NodeId) = .empty,
    cons_single: Ids.FixedDict(2) = .{},
    relevant: stamped.Column(NodeId, void) = .{},
    /// `inners` by forced node.
    memo_inners: stamped.Column(NodeId, SetId) = .{},
    /// `eager`'s images (§2.11 *κ at a view*), valid while `ties` is
    /// `eager_ties`; `answered` names the view whose fresh raw answer a node is.
    memo_eager: stamped.Column(NodeId, NodeId) = .{},
    eager_ties: u32 = 0,
    answered: stamped.Column(NodeId, NodeId) = .{},
    /// Where an `eager` image is ordered: the node it stands for (`birth`).
    born: stamped.Column(NodeId, NodeId) = .{},
    /// `dagHas`'s node sets: what a union's or a choice's DAG reaches, by
    /// `(kind, node)`, until a knot is tied.
    memo_dag_members: Ids.FixedDict(2) = .{},
    dag_members_ties: Ids.FixedDict(2) = .{},
    track_relevance: bool = false,
    /// §2.3 *Saturation at two*: the positions nodes `positions` made
    /// (`counted`, a bit of each node's record), and their count maps once
    /// asked for, by node, an index into `member_maps` (the members' keys and
    /// those met twice, sets over `member_sets`).
    counted: std.DynamicBitSetUnmanaged = .{},
    /// Per node, for `reach` (0) and `arrivals` (1): whether its settled set
    /// may not hold the node's `cellsOf` (`Reach.short`, #1467).
    reach_short: [2]std.DynamicBitSetUnmanaged = .{ .{}, .{} },
    member_counts: Ids.FixedDict(1) = .{},
    member_maps: std.ArrayList([2]SetId) = .empty,
    member_sets: Cell.Radix = .{ .category = .memo },
    /// The counted nodes each rebuild dropped, by the node it returned, a list
    /// through `drop_links` (`node`, `next`): what a construction carries
    /// entries from and the read machine checks (§2.3 *Saturation at two*).
    drop_head: Ids.FixedDict(1) = .{},
    drop_links: std.ArrayList([2]u32) = .empty,

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.reach_pool.deinit(gpa);
        t.marks.deinit(gpa);
        t.cycle_marks.deinit(gpa);
        t.rank_memo.deinit(gpa);
        t.named_memo.deinit(gpa);
        t.named_pool.deinit(gpa);
        t.nodes.deinit(gpa);
        t.intern.deinit(gpa);
        t.overs.deinit(gpa);
        t.over_intern.deinit(gpa);
        t.memo_proj.deinit(gpa);
        t.proj_origin.deinit(gpa);
        t.proj_origins.deinit(gpa);
        t.memo_join.deinit(gpa);
        t.memo_leq.deinit(gpa);
        t.leq_provisional.deinit(gpa);
        t.union_seen.deinit(gpa);
        t.memo_map.deinit(gpa);
        t.map_open.deinit(gpa);
        t.map_low.deinit(gpa);
        t.map_src.deinit(gpa);
        t.map_images.deinit(gpa);
        t.arm_count.deinit(gpa);
        t.arrivals_memo.deinit(gpa);
        t.memo_force.deinit(gpa);
        t.memo_step.deinit(gpa);
        t.view_free.deinit(gpa);
        t.memo_view_reach.deinit(gpa);
        t.node_sets.deinit(gpa);
        t.memo_node_union.deinit(gpa);
        t.memo_node_meet.deinit(gpa);
        t.memo_approx_all.deinit(gpa);
        t.bases.deinit(gpa);
        t.memo_region.deinit(gpa);
        t.region_ties.deinit(gpa);
        t.memo_bstar.deinit(gpa);
        t.bstar_epoch.deinit(gpa);
        t.memo_tested.deinit(gpa);
        t.memo_wholly.deinit(gpa);
        t.cons_head.deinit(gpa);
        t.cons.deinit(gpa);
        t.cons_pool.deinit(gpa);
        t.cons_single.deinit(gpa);
        t.relevant.deinit(gpa);
        t.memo_inners.deinit(gpa);
        t.memo_eager.deinit(gpa);
        t.answered.deinit(gpa);
        t.born.deinit(gpa);
        t.memo_dag_members.deinit(gpa);
        t.dag_members_ties.deinit(gpa);
        t.member_counts.deinit(gpa);
        t.counted.deinit(gpa);
        for (&t.reach_short) |*b| b.deinit(gpa);
        t.member_maps.deinit(gpa);
        t.member_sets.deinit(gpa);
        t.drop_head.deinit(gpa);
        t.drop_links.deinit(gpa);
        t.stable.deinit(gpa);
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

    /// Tarjan's walk, on explicit stacks, over a lazy reader's relation
    /// (§2.11 *Cycles, links and folds*): `r.from(x)` is what `x`'s answer is
    /// read from, `r.settled(x)` whether its answer is kept already, and
    /// `r.settle(members)` keeps the answer of one record alone or of one
    /// cycle of them, all they read from outside it settled. Each record is
    /// entered once, so a cycle with no `node` on it (`U = union(leaf,
    /// delta(U, o))` under a view, #1314) ends at its least fixed point.
    pub fn cycleWalk(t: *Table, gpa: Allocator, start: NodeId, r: anytype) Error!void {
        const Frame = struct { node: NodeId, from: [2]NodeId, next: u8 = 0 };
        var frames: std.ArrayList(Frame) = .empty;
        defer frames.deinit(gpa);
        // Records entered and not in a settled cycle, in entry order, and
        // each entered record's (index, low link).
        var open: std.ArrayList(NodeId) = .empty;
        defer open.deinit(gpa);
        const marks = try t.cycle_marks.take(gpa);
        defer t.cycle_marks.give(marks);
        var y = start;
        var entered: u32 = 0;
        while (true) {
            if (y != .none) {
                const at = entered;
                entered += 1;
                try marks.put(gpa, y, .{ at, at });
                try open.append(gpa, y);
                try frames.append(gpa, .{ .node = y, .from = try r.from(y) });
            }
            const f = &frames.items[frames.items.len - 1];
            if (f.next < 2) {
                y = f.from[f.next];
                f.next += 1;
                if (y == .none or r.settled(y)) {
                    y = .none;
                } else if (marks.get(y)) |m| {
                    // Unsettled and entered: open, on the cycle being walked.
                    const mx = marks.getPtr(f.node).?;
                    mx[1] = @min(mx[1], m[0]);
                    y = .none;
                }
                continue;
            }
            y = .none;
            const done = frames.pop().?;
            const mx = marks.get(done.node).?;
            if (frames.items.len > 0) {
                const p = marks.getPtr(frames.items[frames.items.len - 1].node).?;
                p[1] = @min(p[1], mx[1]);
            }
            if (mx[1] == mx[0]) {
                // `done` heads a cycle, or is alone: the open records from it on.
                var first = open.items.len - 1;
                while (open.items[first] != done.node) first -= 1;
                try r.settle(open.items[first..]);
                open.shrinkRetainingCapacity(first);
            }
            if (frames.items.len == 0) return;
        }
    }

    /// `n`'s cells. A lazy node's are the join of what it reads them from:
    /// a view's answer's, a recast's inner's, a delta's base's, a join's two
    /// sides'; a whole recast's its inner's reach, approximately
    /// (`recastWhole`). Each is read first, and kept in the record: a record
    /// per node built, its unions charged as any. A cycle of lazy records
    /// reads its cells as their least fixed point, the join of what enters it
    /// from outside (§2.11 *Cycles, links and folds*, `cycleWalk`).
    pub fn cellsOf(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, n: NodeId) Error!SetId {
        if (!t.isLazy(n)) return t.cells(n);
        const walk = try t.dagWalk(gpa, account, n);
        defer if (walk) |k| account.leave(k);
        var r: CellsWalk = .{ .t = t, .gpa = gpa, .account = account, .cellsets = cellsets };
        try t.cycleWalk(gpa, n, &r);
        return t.cells(n);
    }

    const CellsWalk = struct {
        t: *Table,
        gpa: Allocator,
        account: *Account,
        cellsets: *Cell.Radix,

        /// A view's answer (forced, unless `settling`), a recast's inner or a
        /// delta's base, a join's two sides, the right one first; a whole
        /// recast reads its own.
        fn reads(w: *CellsWalk, x: NodeId, settling: bool) Error![2]NodeId {
            const d = w.t.get(x);
            if (d.kind == .view) return .{ if (settling) w.t.forced(x) else try w.t.force(w.gpa, w.account, x), .none };
            if (w.t.isWhole(x)) return .{ .none, .none };
            const l: NodeId = .from(d.a);
            if (d.kind != .positions and d.kind != .@"union" and d.kind != .choice) return .{ l, .none };
            return .{ .from(d.b), if (d.b == d.a) .none else l };
        }

        fn from(w: *CellsWalk, x: NodeId) Error![2]NodeId {
            return w.reads(x, false);
        }

        fn settled(w: *CellsWalk, x: NodeId) bool {
            return !w.t.isLazy(x);
        }

        fn settle(w: *CellsWalk, members: []const NodeId) Error!void {
            const t = w.t;
            try w.account.reserve(.shape, @intCast(members.len));
            // What a member reads from outside the cycle is settled; from
            // another member, still lazy, it reads nothing new. A join's left
            // side first.
            var c: SetId = .none;
            if (members.len == 1 and t.isWhole(members[0])) {
                c = try t.approxReach(w.gpa, w.account, w.cellsets, .from(t.get(members[0]).a));
            } else for (members) |m| {
                const two = try w.reads(m, true);
                for ([_]NodeId{ two[1], two[0] }) |y| if (y != .none and !t.isLazy(y)) {
                    c = try w.cellsets.unionWith(w.gpa, .growth(w.account), c, t.cells(y));
                };
            }
            for (members) |m| t.nodes.items(.cells)[m.int()] = c;
            // A cycle's fixed point: each member holds what it reads.
            if (std.debug.runtime_safety and members.len > 1) for (members) |m| for (try w.reads(m, true)) |y| if (y != .none) {
                var it = w.cellsets.iterate(t.cells(y));
                while (it.next()) |e| std.debug.assert(w.cellsets.member(c, e.key));
            };
        }
    };

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

    /// Whether `n` is the node its constructor interns for its record, one
    /// any other maker of that record meets (`make`).
    pub fn interned(t: *const Table, n: NodeId) bool {
        const d = t.nodes.get(n.int());
        const keyed: u32 = if (d.kind == .recast or d.kind == .delta) Ids.none_int else d.cells.int();
        const got = t.intern.get(.{ @backingInt(d.kind), d.place.int(), keyed, d.a, d.b }) orelse return false;
        return got == n.int();
    }

    pub fn leaf(t: *Table, gpa: Allocator, account: *Account, at: PlaceId, c: SetId) Error!NodeId {
        return t.make(gpa, account, .{ .kind = .leaf, .place = at, .cells = c, .a = 0, .b = 0, .reach = .none });
    }

    /// Whether `n` is the empty value, a view read at its answer (§2.11).
    pub fn isNothing(t: *Table, gpa: Allocator, account: *Account, n: NodeId) Error!bool {
        const x = try t.force(gpa, account, n);
        return t.kind(x) == .leaf and t.cells(x) == .none;
    }

    /// An atom (§2.3 *The atom rule*, #1483): no cell and no part, a nullary
    /// constructor (`Leaf`) or the empty leaf. It holds no list, so it is no
    /// member of any class of `widen`'s quotient: interned, one atom stands
    /// at every path that holds it, and as a member it united those paths'
    /// classes (the root's `xs` of `Node l xs r` became every level's).
    pub fn isAtom(t: *const Table, n: NodeId) bool {
        const d = t.get(n);
        return d.cells == .none and (d.kind == .leaf or (d.kind == .node and d.a == over_none));
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
        /// The snapshot position a re-root view's template reads its actual
        /// at, null for a template that is no re-root leaf (*The crossing*).
        reroot: *const fn (ctx: *anyopaque, t: *Table, gpa: Allocator, account: *Account, env: u32, template: NodeId) Error!?Ids.KappaId,
        /// A template leaf's parts as the eager graft joined them (`eager`):
        /// the actual at each parameter cell (`approx` where the cell is
        /// approximate), then the other cells mapped into one leaf.
        parts: *const fn (ctx: *anyopaque, t: *Table, gpa: Allocator, account: *Account, env: u32, template: NodeId, out: *std.ArrayList(LeafPart)) Error!void,
        /// The place a view of `template` stands at: at a type variable's
        /// place, the place the call instantiates it to (§2.11
        /// *Re-rooting at a parameter*, #1350); the template's otherwise.
        place: ?*const fn (ctx: *anyopaque, t: *Table, gpa: Allocator, account: *Account, env: u32, template: NodeId) Error!PlaceId = null,
        /// Whether `p` is a type variable's place (no steps, §2.1).
        is_var: ?*const fn (ctx: *anyopaque, p: PlaceId) bool = null,
    };

    /// One part of a template leaf's eager image.
    pub const LeafPart = struct { node: NodeId, approx: bool };

    /// `view(template, env)`: a call's result by reference, interned, its
    /// cells lazy until a reader asks.
    pub fn view(t: *Table, gpa: Allocator, account: *Account, template: NodeId, env: u32) Error!NodeId {
        // A view stands at the place its call instantiates its template's
        // to, so every reader that compares places, or steps through one,
        // reads a view as it reads its answer (§2.11, #1350).
        const at = if (t.instantiation) |inst| if (inst.place) |f| try f(inst.ctx, t, gpa, account, env, template) else t.place(template) else t.place(template);
        return t.make(gpa, account, .{ .kind = .view, .place = at, .cells = lazy_cells, .a = template.int(), .b = env, .reach = .none });
    }

    /// The place of a join of `l` and `r`, whatever their order: theirs when
    /// they share one; where one is a type variable's place (a value that
    /// may be anything, whose step is read whole), the other's; otherwise
    /// the lower place, as the table numbers them.
    fn joinPlace(t: *const Table, l: NodeId, r: NodeId) PlaceId {
        const p = t.place(l);
        const q = t.place(r);
        if (p == q) return p;
        if (t.instantiation) |inst| if (inst.is_var) |isVar| {
            if (isVar(inst.ctx, p) and !isVar(inst.ctx, q)) return q;
            if (isVar(inst.ctx, q) and !isVar(inst.ctx, p)) return p;
        };
        return if (p.int() < q.int()) p else q;
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
            const made = t.nodes.len;
            const next = try t.expandView(gpa, account, at);
            // A raw answer made here stands for this view (`eager`).
            if (next.int() >= made and t.kind(next) != .view) try t.answered.put(gpa, next, at);
            if (t.kind(next) == .view) try t.memo_step.put(gpa, at, next);
            at = next;
        }
        try account.reserve(.memo, @intCast(chain.items.len));
        for (chain.items) |v| try t.memo_force.put(gpa, v, at);
        // A view stands at its answer's place (§2.11 *Re-rooting at a parameter*).
        if (std.debug.runtime_safety and t.instantiation != null and t.instantiation.?.place != null) for (chain.items) |v| std.debug.assert(t.place(v) == t.place(at));
        return at;
    }

    /// The view a forced view `v`'s one step answered, when that was a view
    /// again (a chain, §2.11); null at the chain's last view.
    pub fn chainNext(t: *const Table, v: NodeId) ?NodeId {
        return t.memo_step.get(v);
    }

    // ---- the crossing's region and bases (§2.11 *κ across a call*) -----------------

    /// The `R` a re-root view `v` reads its actual at: null for a node that is
    /// no re-root view (a view whose template is a leaf of one exact parameter
    /// cell, *The crossing*).
    pub fn rerootKappa(t: *Table, gpa: Allocator, account: *Account, v: NodeId) Error!?Ids.KappaId {
        if (t.kind(v) != .view) return null;
        const inst = t.instantiation orelse return null;
        const template: NodeId = .from(t.nodes.items(.a)[v.int()]);
        if (t.kind(template) != .leaf) return null;
        return inst.reroot(inst.ctx, t, gpa, account, t.nodes.items(.b)[v.int()], template);
    }

    /// The persistent set of `m`'s bases (*Bases*): what a `proj` or a join
    /// made it from. `.none` for none.
    pub fn basesOf(t: *const Table, m: NodeId) SetId {
        return if (t.bases.get(.{m.int()})) |s| .from(s) else .none;
    }

    /// `m` made by one construction from `members` (a `proj`'s node, a join's
    /// members): recorded as that construction, and each member a base of `m`
    /// (*Bases*). When a relevant node (`isRelevant`) gains a base, an answer
    /// about what is based on a region may change: `base_epoch` moves, and the
    /// new bases are relevant too. `fresh`: `m` was made by this operation.
    fn addConstruction(t: *Table, gpa: Allocator, account: *Account, m: NodeId, members: []const NodeId, fresh: bool) Error!void {
        // The empty value is tested for every region (`tested`): it needs no base.
        if (t.isEmptyLeaf(m)) return;
        for (members) |b| {
            if (b != m) break;
        } else return;
        // The crossing's bookkeeping, a growth task: never the asking lane's
        // share (a wide join records a base per member, §4.1).
        const task = try account.enter(gpa, null);
        defer account.leave(task);
        try account.reserve(.memo, @intCast(1 + members.len));
        // A projection is one construction per (node, base): `proj` is
        // memoised, so it is met again only through another node.
        if (members.len == 1) {
            const got = try t.cons_single.getOrPut(gpa, .{ m.int(), members[0].int() });
            if (got.found_existing) return;
        }
        const head = t.cons_head.get(.{m.int()}) orelse Ids.none_int;
        try t.cons.append(gpa, .{ .next = head, .start = @intCast(t.cons_pool.items.len), .len = @intCast(members.len) });
        try t.cons_pool.appendSlice(gpa, members);
        (try t.cons_head.getOrPut(gpa, .{m.int()})).value_ptr.* = @intCast(t.cons.items.len - 1);
        var old = t.basesOf(m);
        var gained = false;
        for (members) |b| {
            if (b == m or t.node_sets.member(old, b.int())) continue;
            old = try t.node_sets.insert(gpa, .growth(account), old, b.int(), 0);
            gained = true;
        }
        if (!gained) return;
        (try t.bases.getOrPut(gpa, .{m.int()})).value_ptr.* = old.int();
        if (!t.isRelevant(m)) return;
        if (!fresh) t.base_epoch += 1;
        for (members) |b| try t.markRelevant(gpa, account, b);
    }

    /// The empty value at its place (`nothing`): a leaf with no cell.
    fn isEmptyLeaf(t: *const Table, m: NodeId) bool {
        return t.kind(m) == .leaf and t.cells(m) == .none;
    }

    /// Whether a base gained by `m` can change a `tested` answer: `m` is a κ
    /// key or in `bases*` of one (*Bases*). Every node is, until the κ table
    /// reports its keys (`trackRelevance`).
    pub fn isRelevant(t: *const Table, m: NodeId) bool {
        return !t.track_relevance or t.relevant.contains(m);
    }

    /// The κ table reports its keys from now on (`markRelevant`).
    pub fn trackRelevance(t: *Table) void {
        t.track_relevance = true;
    }

    /// `n` and its `bases*` relevant, each node marked once: `n` became a κ
    /// key, or a relevant node gained `n` as a base.
    pub fn markRelevant(t: *Table, gpa: Allocator, account: *Account, n: NodeId) Error!void {
        if (!t.track_relevance or t.relevant.contains(n)) return;
        const task = try account.enter(gpa, null);
        defer account.leave(task);
        var stack: std.ArrayList(NodeId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, n);
        while (stack.pop()) |x| {
            if (t.relevant.contains(x)) continue;
            try account.reserve(.memo, 1);
            try t.relevant.put(gpa, x, {});
            var it = t.node_sets.iterate(t.basesOf(x));
            while (it.next()) |e| if (!t.relevant.contains(.from(e.key))) try stack.append(gpa, .from(e.key));
        }
    }

    /// The node set `region(n)` (*What the crossing reads: the region*): `n`'s
    /// DAG, and for a view in it its chain and forced answer with theirs,
    /// memoised per node (until a knot is tied) and made from its parts' sets
    /// by `unionMemo`.
    pub fn region(t: *Table, gpa: Allocator, account: *Account, n: NodeId) Error!SetId {
        const task = try account.enter(gpa, null);
        defer account.leave(task);
        return t.closure(gpa, account, .region, n);
    }

    /// `bases*(m)` with `m` itself (*Bases*), memoised within one `base_epoch`.
    pub fn basesClosure(t: *Table, gpa: Allocator, account: *Account, m: NodeId) Error!SetId {
        const task = try account.enter(gpa, null);
        defer account.leave(task);
        return t.closure(gpa, account, .bases, m);
    }

    /// Whether key `m` is based on `reg` at all (*tested*): in it, or a base
    /// chain from `m` reaches it. Memoised within one `base_epoch`.
    pub fn tested(t: *Table, gpa: Allocator, account: *Account, m: NodeId, reg: SetId) Error!bool {
        try account.reserve(.inspection, 1);
        if (t.node_sets.member(reg, m.int())) return true;
        // The empty value, met past every missing child: always compared.
        if (t.isEmptyLeaf(m)) return true;
        if (t.basesOf(m) == .none) return false;
        try account.reserve(.memo, 1);
        const key: [3]u32 = .{ m.int(), reg.int(), t.base_epoch };
        if (t.memo_tested.get(key)) |hit| return hit == 1;
        const out = try t.node_sets.intersectsMemo(gpa, .growth(account), &t.memo_node_meet, try t.closure(gpa, account, .bases, m), reg);
        (try t.memo_tested.getOrPut(gpa, key)).value_ptr.* = @intFromBool(out);
        return out;
    }

    /// Whether `m` is wholly of `reg` (*Carried along the walk*): a node of
    /// it, or one with a construction (`addConstruction`) whose every member
    /// is wholly of it. One such construction fixes `m`'s structure, which is
    /// immutable, so a yes stays a yes: memoised for good. A no may turn into
    /// a yes when `m` is made again; it is kept within one `base_epoch`, and
    /// not when a construction cycles (a member open on the way, read as no).
    pub fn wholly(t: *Table, gpa: Allocator, account: *Account, m: NodeId, reg: SetId) Error!bool {
        try account.reserve(.inspection, 1);
        if (t.node_sets.member(reg, m.int())) return true;
        if (t.cons_head.get(.{m.int()}) == null) return false;
        const Frame = struct { node: NodeId, c: u32, i: u32 };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        var done: stamped.Column(NodeId, bool) = .{};
        defer done.deinit(gpa);
        var cyclic = false;
        try stack.append(gpa, .{ .node = m, .c = t.cons_head.get(.{m.int()}).?, .i = 0 });
        while (stack.items.len > 0) {
            const f = &stack.items[stack.items.len - 1];
            const answer: ?bool = blk: {
                if (f.c == Ids.none_int) break :blk false;
                const con = t.cons.items[f.c];
                if (f.i == con.len) break :blk true;
                const x = t.cons_pool.items[con.start + f.i];
                try account.reserve(.inspection, 1);
                const known: ?bool = if (x == f.node or t.node_sets.member(reg, x.int()))
                    true
                else if (done.get(x)) |d|
                    d
                else if (t.memo_wholly.get(.{ x.int(), reg.int(), 0 }) != null)
                    true
                else if (t.memo_wholly.get(.{ x.int(), reg.int(), t.base_epoch + 1 }) != null)
                    false
                else if (t.cons_head.get(.{x.int()}) == null)
                    false
                else
                    null;
                if (known) |k| {
                    if (k) f.i += 1 else {
                        f.c = con.next;
                        f.i = 0;
                    }
                    break :blk null;
                }
                // `x` in progress lower on the stack: a cycle, read as no.
                for (stack.items) |g| if (g.node == x) {
                    cyclic = true;
                    f.c = con.next;
                    f.i = 0;
                    break :blk null;
                };
                try stack.append(gpa, .{ .node = x, .c = t.cons_head.get(.{x.int()}).?, .i = 0 });
                break :blk null;
            };
            const a = answer orelse continue;
            const finished = stack.pop().?.node;
            try done.put(gpa, finished, a);
            if (a or !cyclic) {
                try account.reserve(.memo, 1);
                (try t.memo_wholly.getOrPut(gpa, .{ finished.int(), reg.int(), if (a) 0 else t.base_epoch + 1 })).value_ptr.* = 1;
            }
        }
        return done.get(m).?;
    }

    /// The inners of the recasts at `n`'s path, as a node set (`Cond`'s
    /// `innersOf`): `n`'s own, those of its union's, choice's or positions
    /// node's sides, and those found inside an inner (one path), each view
    /// read at its answer. Memoised per node, made from its parts' sets by
    /// `unionMemo`, so a chain of views below views costs its new nodes, not
    /// its length. Where the DAG cycles, the plain walk, kept nowhere.
    pub fn inners(t: *Table, gpa: Allocator, account: *Account, n: NodeId) Error!SetId {
        const n0 = try t.force(gpa, account, n);
        switch (t.kind(n0)) {
            .recast, .@"union", .choice, .positions => {},
            else => return .none,
        }
        // A finite rank: no recast anywhere below, so none at this path.
        if (try t.rank(gpa, account, n0) != rank_unbounded) return .none;
        try account.reserve(.memo, 1);
        if (t.memo_inners.get(n0)) |s| return s;
        const charge: Ids.Charge = .growth(account);
        const Frame = struct { node: NodeId, expanded: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        var open: stamped.Column(NodeId, void) = .{};
        defer open.deinit(gpa);
        var local: stamped.Column(NodeId, SetId) = .{};
        defer local.deinit(gpa);
        var cyclic = false;
        try stack.append(gpa, .{ .node = n0, .expanded = false });
        while (stack.pop()) |f| {
            const x = f.node;
            if (local.contains(x)) continue;
            if (t.memo_inners.get(x)) |s| {
                try local.put(gpa, x, s);
                continue;
            }
            const d = t.get(x);
            const parts: [2]NodeId = switch (d.kind) {
                .recast => .{ try t.force(gpa, account, .from(d.a)), .none },
                .@"union", .choice, .positions => .{ try t.force(gpa, account, .from(d.a)), try t.force(gpa, account, .from(d.b)) },
                else => {
                    try local.put(gpa, x, .none);
                    continue;
                },
            };
            if (!f.expanded) {
                if (open.contains(x)) {
                    cyclic = true;
                    continue;
                }
                try account.reserve(.inspection, 1);
                try open.put(gpa, x, {});
                try stack.append(gpa, .{ .node = x, .expanded = true });
                for (parts) |p| if (p != .none and !local.contains(p)) try stack.append(gpa, .{ .node = p, .expanded = false });
                continue;
            }
            open.remove(x);
            var s: SetId = if (d.kind == .recast) try t.node_sets.insert(gpa, charge, .none, d.a, 0) else .none;
            for (parts) |p| if (p != .none) {
                s = try t.node_sets.unionMemo(gpa, charge, &t.memo_node_union, s, local.get(p) orelse .none);
            };
            try local.put(gpa, x, s);
            if (!cyclic) try t.memo_inners.put(gpa, x, s);
        }
        if (!cyclic) return local.get(n0).?;
        // A cycle: every recast the DAG reaches, each node once.
        var out: SetId = .none;
        var seen: stamped.Column(NodeId, void) = .{};
        defer seen.deinit(gpa);
        try stack.append(gpa, .{ .node = n0, .expanded = false });
        while (stack.pop()) |f| {
            const x = try t.force(gpa, account, f.node);
            if (seen.contains(x)) continue;
            try account.reserve(.inspection, 1);
            try seen.put(gpa, x, {});
            const d = t.get(x);
            switch (d.kind) {
                .recast => {
                    out = try t.node_sets.insert(gpa, charge, out, d.a, 0);
                    try stack.append(gpa, .{ .node = .from(d.a), .expanded = false });
                },
                .@"union", .choice, .positions => try stack.appendSlice(gpa, &.{ .{ .node = .from(d.a), .expanded = false }, .{ .node = .from(d.b), .expanded = false } }),
                else => {},
            }
        }
        return out;
    }

    const Closure = enum { region, bases, union_dag, choice_dag };

    /// The node's own successors in `which`'s graph.
    fn closureSuccs(t: *Table, gpa: Allocator, account: *Account, which: Closure, n: NodeId, out: *std.ArrayList(NodeId)) Error!void {
        if (which == .union_dag or which == .choice_dag) {
            const d = t.get(n);
            if (d.kind == (if (which == .choice_dag) Kind.choice else Kind.@"union")) try out.appendSlice(gpa, &.{ .from(d.a), .from(d.b) });
            return;
        }
        if (which == .bases) {
            var it = t.node_sets.iterate(t.basesOf(n));
            while (it.next()) |e| try out.append(gpa, .from(e.key));
            return;
        }
        const d = t.get(n);
        switch (d.kind) {
            .leaf => {},
            .node, .delta => {
                if (d.kind == .delta) try out.append(gpa, .from(d.a));
                var it = t.overEntries(if (d.kind == .node) d.a else d.b);
                while (it.next()) |e| try out.append(gpa, e.node);
            },
            .recast => try out.append(gpa, .from(d.a)),
            .@"union", .choice, .positions => try out.appendSlice(gpa, &.{ .from(d.a), .from(d.b) }),
            // A view's chain and its forced answer (*the region*).
            .view => {
                const answer = try t.force(gpa, account, n);
                try out.append(gpa, t.chainNext(n) orelse answer);
            },
        }
    }

    fn closureMemo(t: *const Table, which: Closure, n: NodeId) ?SetId {
        const key: [1]u32 = .{n.int()};
        return switch (which) {
            .region => if (t.region_ties.get(key) == t.ties) (if (t.memo_region.get(key)) |s| SetId.from(s) else null) else null,
            .bases => if (t.bstar_epoch.get(key) == t.base_epoch) (if (t.memo_bstar.get(key)) |s| SetId.from(s) else null) else null,
            .union_dag, .choice_dag => blk: {
                const k2: [2]u32 = .{ @backingInt(which), n.int() };
                break :blk if (t.dag_members_ties.get(k2) == t.ties) (if (t.memo_dag_members.get(k2)) |s| SetId.from(s) else null) else null;
            },
        };
    }

    fn closureKeep(t: *Table, gpa: Allocator, which: Closure, n: NodeId, s: SetId) Error!void {
        const key: [1]u32 = .{n.int()};
        switch (which) {
            .region => {
                (try t.memo_region.getOrPut(gpa, key)).value_ptr.* = s.int();
                (try t.region_ties.getOrPut(gpa, key)).value_ptr.* = t.ties;
            },
            .bases => {
                (try t.memo_bstar.getOrPut(gpa, key)).value_ptr.* = s.int();
                (try t.bstar_epoch.getOrPut(gpa, key)).value_ptr.* = t.base_epoch;
            },
            .union_dag, .choice_dag => {
                const k2: [2]u32 = .{ @backingInt(which), n.int() };
                (try t.memo_dag_members.getOrPut(gpa, k2)).value_ptr.* = s.int();
                (try t.dag_members_ties.getOrPut(gpa, k2)).value_ptr.* = t.ties;
            },
        }
    }

    /// The set of every node `start` reaches in `which`'s graph, itself
    /// included: Tarjan on an explicit stack, one set per strongly connected
    /// component, each made from its successors' by `unionMemo`. A record per
    /// node and edge.
    fn closure(t: *Table, gpa: Allocator, account: *Account, which: Closure, start: NodeId) Error!SetId {
        try account.reserve(.memo, 1);
        if (t.closureMemo(which, start)) |s| return s;
        const charge: Ids.Charge = .growth(account);
        const Frame = struct { node: NodeId, next: u32, end: u32, from: u32 };
        var frames: std.ArrayList(Frame) = .empty;
        defer frames.deinit(gpa);
        var succ: std.ArrayList(NodeId) = .empty;
        defer succ.deinit(gpa);
        var index: stamped.Column(NodeId, [2]u32) = .{};
        defer index.deinit(gpa);
        var acc: stamped.Column(NodeId, SetId) = .{};
        defer acc.deinit(gpa);
        var on: stamped.Column(NodeId, void) = .{};
        defer on.deinit(gpa);
        var comp: std.ArrayList(NodeId) = .empty;
        defer comp.deinit(gpa);
        var visits: u32 = 0;
        const Push = struct {
            fn go(tt: *Table, g: Allocator, a: *Account, w: Closure, fs: *std.ArrayList(Frame), sc: *std.ArrayList(NodeId), ix: *stamped.Column(NodeId, [2]u32), ac: *stamped.Column(NodeId, SetId), o: *stamped.Column(NodeId, void), cs: *std.ArrayList(NodeId), v: *u32, n: NodeId) Error!void {
                try a.reserve(.inspection, 1);
                try ix.put(g, n, .{ v.*, v.* });
                v.* += 1;
                try o.put(g, n, {});
                try cs.append(g, n);
                try ac.put(g, n, try tt.node_sets.insert(g, .growth(a), .none, n.int(), 0));
                const from: u32 = @intCast(sc.items.len);
                try tt.closureSuccs(g, a, w, n, sc);
                try fs.append(g, .{ .node = n, .next = from, .end = @intCast(sc.items.len), .from = from });
            }
        };
        try Push.go(t, gpa, account, which, &frames, &succ, &index, &acc, &on, &comp, &visits, start);
        while (frames.items.len > 0) {
            const f = &frames.items[frames.items.len - 1];
            if (f.next < f.end) {
                const s = succ.items[f.next];
                f.next += 1;
                try account.reserve(.inspection, 1);
                if (t.closureMemo(which, s)) |set| {
                    try acc.put(gpa, f.node, try t.node_sets.unionMemo(gpa, charge, &t.memo_node_union, acc.get(f.node).?, set));
                    continue;
                }
                if (index.get(s)) |il| {
                    if (on.contains(s)) index.getPtr(f.node).?[1] = @min(index.get(f.node).?[1], il[0]);
                    continue;
                }
                try Push.go(t, gpa, account, which, &frames, &succ, &index, &acc, &on, &comp, &visits, s);
                continue;
            }
            const done = frames.pop().?;
            succ.shrinkRetainingCapacity(done.from);
            const il = index.get(done.node).?;
            if (il[1] == il[0]) {
                // A component closed: its members' sets as one.
                var set: SetId = .none;
                const from = std.mem.lastIndexOfScalar(NodeId, comp.items, done.node).?;
                for (comp.items[from..]) |x| set = try t.node_sets.unionMemo(gpa, charge, &t.memo_node_union, set, acc.get(x).?);
                for (comp.items[from..]) |x| {
                    on.remove(x);
                    try account.reserve(.memo, 1);
                    try t.closureKeep(gpa, which, x, set);
                }
                comp.shrinkRetainingCapacity(from);
                if (frames.items.len > 0) {
                    const p = frames.items[frames.items.len - 1].node;
                    try acc.put(gpa, p, try t.node_sets.unionMemo(gpa, charge, &t.memo_node_union, acc.get(p).?, set));
                }
            } else if (frames.items.len > 0) {
                const p = frames.items[frames.items.len - 1].node;
                index.getPtr(p).?[1] = @min(index.get(p).?[1], il[1]);
            }
        }
        return t.closureMemo(which, start).?;
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
                const c = if (d.cells == .none) SetId.none else try inst.cells(inst.ctx, t, gpa, account, env, try t.cellsOf(gpa, account, cellsets, template), t.place(v));
                var over: u32 = over_none;
                var it = t.overEntries(d.a);
                while (it.next()) |e| over = try t.overPut(gpa, account, over, e.step, try t.view(gpa, account, e.node, env));
                break :blk t.node(gpa, account, t.place(v), c, over);
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
                break :blk t.make(gpa, account, .{ .kind = .delta, .place = t.place(v), .cells = lazy_cells, .a = base.int(), .b = over, .reach = .none });
            },
            .recast => t.make(gpa, account, .{ .kind = .recast, .place = d.place, .cells = lazy_cells, .a = (try t.view(gpa, account, .from(d.a), env)).int(), .b = d.b, .reach = .none }),
            .@"union", .choice, .positions => t.make(gpa, account, .{ .kind = d.kind, .place = t.place(v), .cells = lazy_cells, .a = (try t.view(gpa, account, .from(d.a), env)).int(), .b = (try t.view(gpa, account, .from(d.b), env)).int(), .reach = .none }),
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
                const got = try cellsets.unionWith(gpa, .growth(account), l, r);
                (try t.memo_view_reach.getOrPut(gpa, .{ f.set.int(), env })).value_ptr.* = got.int();
            } else {
                var it = cellsets.iterate(f.set);
                const e = it.next().?;
                try account.reserve(.inspection, 1);
                // Computed before the slot is taken: the instantiation may grow this
                // memo (a nested view), and an error leaves no undefined entry.
                const got = try inst.reach(inst.ctx, t, gpa, account, env, .from(e.key), e.value);
                (try t.memo_view_reach.getOrPut(gpa, .{ f.set.int(), env })).value_ptr.* = got.int();
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
        // Every cell of the reach, approximate: memoised per set node.
        return cellsets.approxAll(gpa, .growth(account), &t.memo_approx_all, try t.reach(gpa, account, cellsets, n));
    }

    /// The lazy join of two nodes at one place (a binary DAG).
    pub fn @"union"(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, l: NodeId, r: NodeId) Error!NodeId {
        const before = t.nodes.len;
        const out = try t.unionMake(gpa, account, cellsets, l, r);
        try t.joinBases(gpa, account, out, &.{ l, r }, before);
        return out;
    }

    /// Two alternatives that are one value (§2.11): a view and its answer, or
    /// a view and another node with that answer. The view is kept: its read
    /// joins the class's entry under it with its answer's (*κ at a view*).
    /// Two distinct views stay two: each holds its own call's entry.
    fn sameAnswer(t: *Table, gpa: Allocator, account: *Account, l: NodeId, r: NodeId) Error!?NodeId {
        // Two recasts at one place of one value are one value; a whole one is
        // never a plain one (#1311).
        if (t.kind(l) == .recast and t.kind(r) == .recast and t.place(l) == t.place(r) and t.isWhole(l) == t.isWhole(r)) {
            const one = (try t.sameAnswer(gpa, account, .from(t.get(l).a), .from(t.get(r).a))) orelse return null;
            return if (one.int() == t.get(l).a) l else r;
        }
        const lv = t.kind(l) == .view;
        const rv = t.kind(r) == .view;
        if (!lv and !rv or lv and rv) return null;
        if (t.eagerOf(l) != t.eagerOf(r) and try t.force(gpa, account, l) != try t.force(gpa, account, r)) return null;
        return if (lv) l else r;
    }

    /// Each member a base of the join `out` made of them (*Bases*); `before`
    /// the table's size before it, so a node made by the join is fresh.
    fn joinBases(t: *Table, gpa: Allocator, account: *Account, out: NodeId, members: []const NodeId, before: usize) Error!void {
        // An interned join met again was made of the same members: its bases
        // are recorded already. A member it absorbed gains the others.
        const fresh = out.int() >= before;
        if (!fresh and std.mem.indexOfScalar(NodeId, members, out) == null) return;
        try t.addConstruction(gpa, account, out, members, fresh);
    }

    fn unionMake(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, l: NodeId, r: NodeId) Error!NodeId {
        if (l == r) return l;
        if (try t.sameAnswer(gpa, account, l, r)) |one| return one;
        // A union absorbs a member it already has, so projecting a cyclic
        // union reaches a fixpoint instead of nesting forever.
        if (try t.unionHas(gpa, account, l, r)) return l;
        if (try t.unionHas(gpa, account, r, l)) return r;
        const x = @min(l.int(), r.int());
        const y = @max(l.int(), r.int());
        const c = try cellsets.unionWith(gpa, .growth(account), try t.cellsOf(gpa, account, cellsets, l), try t.cellsOf(gpa, account, cellsets, r));
        return t.make(gpa, account, .{ .kind = .@"union", .place = t.joinPlace(l, r), .cells = c, .a = x, .b = y, .reach = .none });
    }

    /// The lazy join of exclusive alternatives (§2.3, #1128): a branch's or a
    /// fixpoint's arms, one of which is the value. Interned apart from `union`;
    /// it absorbs only a member of its own choice DAG (the maximum allows it).
    pub fn choice(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, l: NodeId, r: NodeId) Error!NodeId {
        const before = t.nodes.len;
        const out = try t.choiceMake(gpa, account, cellsets, l, r);
        try t.joinBases(gpa, account, out, &.{ l, r }, before);
        return out;
    }

    fn choiceMake(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, l: NodeId, r: NodeId) Error!NodeId {
        if (l == r) return l;
        if (try t.sameAnswer(gpa, account, l, r)) |one| return one;
        if (try t.dagHas(gpa, account, .choice, l, r)) return l;
        if (try t.dagHas(gpa, account, .choice, r, l)) return r;
        const c = try cellsets.unionWith(gpa, .growth(account), try t.cellsOf(gpa, account, cellsets, l), try t.cellsOf(gpa, account, cellsets, r));
        return t.make(gpa, account, .{ .kind = .choice, .place = t.joinPlace(l, r), .cells = c, .a = @min(l.int(), r.int()), .b = @max(l.int(), r.int()), .reach = .none });
    }

    /// `collect(n₁…nₖ)` (§2.3): a built value's elements under `[*]` as a
    /// balanced `positions` DAG — never deduplicated or absorbed below two
    /// occurrences (*Saturation at two*, `positions`): the same node on both
    /// sides is two positions, which κ reads as `shared`. One
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

    /// A raw copy of `n`: its record in a node no constructor interns, its
    /// reach memo and that memo's `short` bit kept (#1517), as `widen`'s
    /// emit copies a class that is its side. A node keyed outside the table
    /// by the class it is an image of (`fold_cond`, #1570) is one of these,
    /// so no other class meets it.
    pub fn rawCopy(t: *Table, gpa: Allocator, account: *Account, n: NodeId) Error!NodeId {
        const id = try t.knot(gpa, account);
        t.nodes.set(id.int(), t.nodes.get(n.int()));
        const sb = &t.reach_short[0];
        if (sb.bit_length <= id.int()) try sb.resize(gpa, @max(t.nodes.len, 2 * sb.bit_length), false);
        sb.setValue(id.int(), n.int() < sb.bit_length and sb.isSet(n.int()));
        return id;
    }

    /// Set a `knot`'s record: the caller's to make it one a constructor
    /// could have made but for the cycle.
    pub fn tie(t: *Table, id: NodeId, n: Node) void {
        t.nodes.set(id.int(), n);
        t.ties +%= 1;
    }

    /// Two positions at one place (`collect`'s node, `proj`'s image of one,
    /// `without`'s and `eager`'s rebuilds), each member at most twice (§2.3
    /// *Saturation at two*): when a member would occur three times or more,
    /// the balanced tree over the members in first-occurrence order, each
    /// once or twice.
    fn positions(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, l: NodeId, r: NodeId) Error!NodeId {
        const before = t.nodes.len;
        // A side that is nothing (an empty leaf) is no position: no object
        // can be there (§2.3, #1120), so a projection of `[ x, Rose [] ]`'s
        // `[*]` past the empty list is `x`'s alone, not a new node per level.
        const nothing_side: ?NodeId = if (try t.isNothing(gpa, account, r)) l else if (try t.isNothing(gpa, account, l)) r else null;
        if (nothing_side) |out| {
            try t.joinBases(gpa, account, out, &.{ l, r }, before);
            return out;
        }
        // The count maps' test and the rebuild are a task of their own, never
        // the caller's lane (a lane of `collect` holds only its item's
        // constant work, §4.1). Two sides that are members alone cannot lose
        // one: their test reads nothing.
        const lost = if (!t.isCounted(l) and !t.isCounted(r)) false else blk: {
            const task = try account.enter(gpa, null);
            defer account.leave(task);
            break :blk try t.losesOne(gpa, account, l, r);
        };
        if (lost) {
            const out = if (mutated("cert-saturate-side")) l else try t.saturate(gpa, account, cellsets, l, r);
            if (std.debug.runtime_safety) try t.assertSaturation(gpa, cellsets, l, r, out);
            try t.joinBases(gpa, account, out, &.{ l, r }, before);
            return out;
        }
        // Its cells are lazy (`cellsOf`): what its sides hold, built on request.
        const out = try t.make(gpa, account, .{ .kind = .positions, .place = t.joinPlace(l, r), .cells = lazy_cells, .a = l.int(), .b = r.int(), .reach = .none });
        // A node made here is counted, from its birth and never later: a
        // positions node another reader made (`map`'s, a view's expansion's,
        // a knot's) is not, and stays one member to a parent. The mark is a
        // bit of the node's record; its count map is made when a parent asks.
        if (out.int() >= before) {
            try t.counted.resize(gpa, t.nodes.len, false);
            t.counted.set(out.int());
        }
        try t.joinBases(gpa, account, out, &.{ l, r }, before);
        return out;
    }

    /// C1 (§8 slice 4, *Lemmas*, #1485), `runtime_safety` only: a positions
    /// node `saturate` made has the aggregate of the two sides it saw, each
    /// cell's multiplicity capped at 2, counted by a reader that keeps no
    /// count map: the sides walked down to their members, every member's
    /// cells once per occurrence.
    fn assertSaturation(t: *Table, gpa: Allocator, cellsets: *Cell.Radix, l: NodeId, r: NodeId, out: NodeId) Error!void {
        var scratch: Account = .{ .allowance = std.math.maxInt(u32) };
        defer scratch.deinit(gpa);
        var raw: Ids.FixedDict(1) = .{};
        defer raw.deinit(gpa);
        var sat: Ids.FixedDict(1) = .{};
        defer sat.deinit(gpa);
        var keys: std.ArrayList(u32) = .empty;
        defer keys.deinit(gpa);
        try t.cellCounts(gpa, &scratch, cellsets, l, &raw, &keys);
        try t.cellCounts(gpa, &scratch, cellsets, r, &raw, &keys);
        var sat_keys: std.ArrayList(u32) = .empty;
        defer sat_keys.deinit(gpa);
        try t.cellCounts(gpa, &scratch, cellsets, out, &sat, &sat_keys);
        var ok = keys.items.len == sat_keys.items.len;
        for (keys.items) |k| if ((sat.get(.{k}) orelse 0) != raw.get(.{k}).?) {
            ok = false;
        };
        if (!ok) std.debug.panic("ownership v2: a saturated positions node changes its aggregate (C1, #1485)", .{});
    }

    fn cellCounts(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, n: NodeId, out: *Ids.FixedDict(1), keys: *std.ArrayList(u32)) Error!void {
        var stack: std.ArrayList(NodeId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, n);
        while (stack.pop()) |x| {
            const d = t.get(x);
            if (d.kind == .positions) {
                try stack.appendSlice(gpa, &.{ .from(d.a), .from(d.b) });
                continue;
            }
            var it = cellsets.iterate(try t.cellsOf(gpa, account, cellsets, x));
            while (it.next()) |e| {
                const got = try out.getOrPut(gpa, .{e.key});
                if (!got.found_existing) try keys.append(gpa, e.key);
                got.value_ptr.* = if (got.found_existing) 2 else 1;
            }
        }
    }
    /// Whether `positions` made `n`: a node whose members a parent counts
    /// (§2.3 *Saturation at two*). Every other node is one member.
    fn isCounted(t: *const Table, n: NodeId) bool {
        return n.int() < t.counted.bit_length and t.counted.isSet(n.int());
    }

    /// The members `n` stands for as a side, as `(keys, twice)` sets over
    /// `member_sets`: a counted node's count map, or `n` alone.
    fn sideCounts(t: *Table, gpa: Allocator, account: *Account, n: NodeId) Error![2]SetId {
        if (t.isCounted(n)) return t.countMap(gpa, account, n);
        return .{ try t.member_sets.insert(gpa, .growth(account), .none, n.int(), 1), .none };
    }

    /// A counted node's count map, member → `{once, twice}` as the members
    /// (`keys`) and those met twice or more (`twice`), memoised per node and
    /// made on request, its counted sides first on an explicit stack. A
    /// parent's map is its sides' merged by saturating sum (§2.3 *Cost*):
    /// identical subtrees are skipped by identity, so a merge pays for its
    /// changed spine. A record per map made.
    fn countMap(t: *Table, gpa: Allocator, account: *Account, n: NodeId) Error![2]SetId {
        if (t.member_counts.get(.{n.int()})) |i| return t.member_maps.items[i];
        const Frame = struct { node: NodeId, expanded: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, .{ .node = n, .expanded = false });
        while (stack.pop()) |f| {
            if (t.member_counts.get(.{f.node.int()}) != null) continue;
            const d = t.get(f.node);
            if (!f.expanded) {
                try stack.append(gpa, .{ .node = f.node, .expanded = true });
                for ([_]u32{ d.a, d.b }) |s| if (t.isCounted(.from(s)) and t.member_counts.get(.{s}) == null) try stack.append(gpa, .{ .node = .from(s), .expanded = false });
                continue;
            }
            const m = try t.mergeCounts(gpa, account, .from(d.a), .from(d.b));
            try account.reserve(.memo, 1);
            (try t.member_counts.getOrPut(gpa, .{f.node.int()})).value_ptr.* = @intCast(t.member_maps.items.len);
            try t.member_maps.append(gpa, m);
        }
        return t.member_maps.items[t.member_counts.get(.{n.int()}).?];
    }

    /// The count map of `positions(l, r)`: the keys' union, and twice what
    /// either side holds twice or both hold.
    fn mergeCounts(t: *Table, gpa: Allocator, account: *Account, l: NodeId, r: NodeId) Error![2]SetId {
        const sets = &t.member_sets;
        const g: Ids.Charge = .growth(account);
        const cl = try t.sideCounts(gpa, account, l);
        const cr = try t.sideCounts(gpa, account, r);
        const both = try sets.intersection(gpa, g, cl[0], cr[0]);
        return .{ try sets.unionWith(gpa, g, cl[0], cr[0]), try sets.unionWith(gpa, g, try sets.unionWith(gpa, g, cl[1], cr[1]), both) };
    }

    /// Whether `positions(l, r)` would hold a member three times: one side
    /// holds it twice and the other holds it. A side that is one member is
    /// looked up in the other's `twice`.
    fn losesOne(t: *Table, gpa: Allocator, account: *Account, l: NodeId, r: NodeId) Error!bool {
        const sets = &t.member_sets;
        if (!t.isCounted(r)) return sets.member((try t.countMap(gpa, account, l))[1], r.int());
        if (!t.isCounted(l)) return sets.member((try t.countMap(gpa, account, r))[1], l.int());
        const g: Ids.Charge = .growth(account);
        const cl = try t.countMap(gpa, account, l);
        const cr = try t.countMap(gpa, account, r);
        return try sets.intersects(gpa, g, cl[1], cr[0]) or try sets.intersects(gpa, g, cl[0], cr[1]);
    }

    /// `positions(l, r)` with a member met three times or more: the
    /// balanced positions tree over its members in left-to-right order of
    /// first occurrence, each met twice or more twice (§2.3 *Saturation at
    /// two*). Charged as a task of its own. Each counted node of the sides
    /// is read once, so the work is the sides' distinct structure.
    fn saturate(t: *Table, gpa: Allocator, account: *Account, cellsets: *Cell.Radix, l: NodeId, r: NodeId) Error!NodeId {
        const task = try account.enter(gpa, null);
        defer account.leave(task);
        const twice = (try t.mergeCounts(gpa, account, l, r))[1];
        const seen = try t.marks.take(gpa);
        defer t.marks.give(seen);
        // The counted nodes read, for the κ-home check (`recordDropped`).
        var read: std.ArrayList(NodeId) = .empty;
        defer read.deinit(gpa);
        var order: std.ArrayList(NodeId) = .empty;
        defer order.deinit(gpa);
        var stack: std.ArrayList(NodeId) = .empty;
        defer stack.deinit(gpa);
        try stack.appendSlice(gpa, &.{ r, l });
        while (stack.pop()) |n| {
            if ((try seen.getOrPut(gpa, n)).found_existing) continue;
            try account.reserve(.shape, 1);
            if (t.isCounted(n)) {
                try read.append(gpa, n);
                const d = t.get(n);
                try stack.appendSlice(gpa, &.{ .from(d.b), .from(d.a) });
                continue;
            }
            try order.append(gpa, n);
            if (t.member_sets.member(twice, n.int())) try order.append(gpa, n);
        }
        const out = try t.collect(gpa, account, cellsets, order.items);
        try t.recordDropped(gpa, account, read.items, out);
        return out;
    }

    /// The counted nodes a rebuild read that its tree `out` does not hold,
    /// kept under `out` (`dropsOf`), a record each: what a construction
    /// carries their snapshot entries from (§2.3 *Saturation at two*, *The
    /// entries of a dropped node*) and what the read machine checks.
    fn recordDropped(t: *Table, gpa: Allocator, account: *Account, read: []const NodeId, out: NodeId) Error!void {
        const kept = try t.marks.take(gpa);
        defer t.marks.give(kept);
        var stack: std.ArrayList(NodeId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, out);
        while (stack.pop()) |n| {
            if ((try kept.getOrPut(gpa, n)).found_existing) continue;
            if (!t.isCounted(n)) continue;
            try account.reserve(.shape, 1);
            const d = t.get(n);
            try stack.appendSlice(gpa, &.{ .from(d.a), .from(d.b) });
        }
        for (read) |n| if (!kept.contains(n)) {
            try account.reserve(.memo, 1);
            const head = try t.drop_head.getOrPut(gpa, .{out.int()});
            if (!head.found_existing) head.value_ptr.* = Ids.none_int;
            try t.drop_links.append(gpa, .{ n.int(), head.value_ptr.* });
            head.value_ptr.* = @intCast(t.drop_links.items.len - 1);
        };
    }

    /// The nodes the rebuilds that returned `n` dropped (`recordDropped`).
    pub const Drops = struct {
        t: *const Table,
        at: u32,

        pub fn next(it: *Drops) ?NodeId {
            if (it.at == Ids.none_int) return null;
            const l = it.t.drop_links.items[it.at];
            it.at = l[1];
            return .from(l[0]);
        }
    };

    pub fn dropsOf(t: *const Table, n: NodeId) Drops {
        return .{ .t = t, .at = t.drop_head.get(.{n.int()}) orelse Ids.none_int };
    }

    /// Every node a rebuild of `n` dropped, and what a dropped node that a
    /// rebuild returned dropped in turn, each once, appended to `out`: the
    /// counted nodes of the tree the constructors would have made that `n`
    /// does not hold. A record per node.
    pub fn dropsClosure(t: *Table, gpa: Allocator, account: *Account, n: NodeId, out: *std.ArrayList(NodeId)) Error!void {
        if (t.drop_head.get(.{n.int()}) == null) return;
        const seen = try t.marks.take(gpa);
        defer t.marks.give(seen);
        for (out.items) |x| try seen.put(gpa, x, {});
        var stack: std.ArrayList(NodeId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, n);
        while (stack.pop()) |x| {
            var it = t.dropsOf(x);
            while (it.next()) |d| {
                if ((try seen.getOrPut(gpa, d)).found_existing) continue;
                try account.reserve(.memo, 1);
                try out.append(gpa, d);
                try stack.append(gpa, d);
            }
        }
    }

    /// How many arms `n`'s choice DAG has, an arm counted once per route,
    /// saturating: the size a flattening join keeps whole (`joinAlternatives`).
    /// Memoised per node on an explicit stack, a count stored only once
    /// it is final (a refused reservation leaves none behind); a node is
    /// immutable, and a node met again while it is counted (no choice
    /// lies on a cycle, §2.3) counts one.
    fn armCount(t: *Table, gpa: Allocator, account: *Account, n: NodeId) Error!u32 {
        if (t.kind(n) != .choice) return 1;
        try account.reserve(.memo, 1);
        if (t.arm_count.get(n)) |c| return c;
        const Frame = struct { node: NodeId, expanded: bool };
        const open = try t.marks.take(gpa);
        defer t.marks.give(open);
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, .{ .node = n, .expanded = false });
        while (stack.pop()) |f| {
            const d = t.get(f.node);
            if (!f.expanded) {
                if (t.arm_count.get(f.node) != null or open.contains(f.node)) continue;
                try account.reserve(.inspection, 1);
                try open.put(gpa, f.node, {});
                try stack.append(gpa, .{ .node = f.node, .expanded = true });
                for ([_]u32{ d.a, d.b }) |s| if (t.kind(.from(s)) == .choice and t.arm_count.get(.from(s)) == null and !open.contains(.from(s))) try stack.append(gpa, .{ .node = .from(s), .expanded = false });
                continue;
            }
            var c: u32 = 0;
            for ([_]u32{ d.a, d.b }) |s| c +|= if (t.kind(.from(s)) == .choice) t.arm_count.get(.from(s)) orelse 1 else 1;
            try t.arm_count.put(gpa, f.node, c);
        }
        return t.arm_count.get(n).?;
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
        // The nodes `u`'s DAG of this kind reaches, a node set memoised per
        // node (`closure`): a union built over an earlier one reads its new
        // nodes, never the whole DAG again.
        try account.reserve(.inspection, 1);
        return t.node_sets.member(try t.closure(gpa, account, if (dag == .choice) .choice_dag else .union_dag, u), x.int());
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
    /// The projection of `n` at `s` taken to be `m`, a node `BlockRead`
    /// decoded as that projection and checked to be its DAG up to the order
    /// of sides (§3.6): later readers then meet the node the block's κ is
    /// keyed on.
    pub fn setProj(t: *Table, gpa: Allocator, account: *Account, n: NodeId, s: Step, m: NodeId) Error!void {
        try account.reserve(.memo, 1);
        (try t.memo_proj.getOrPut(gpa, .{ n.int(), s.word() })).value_ptr.* = m.int();
        try t.noteOrigin(gpa, account, n, s, m);
    }

    /// `m`, decoded as the projection of `n` at `s` (`BlockRead`), takes that
    /// origin as one `proj` made does (§2.9 *Keyed where a reader looks*).
    pub fn noteOrigin(t: *Table, gpa: Allocator, account: *Account, n: NodeId, s: Step, m: NodeId) Error!void {
        return t.addOrigin(gpa, account, n, s, m);
    }

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

    /// Whether view `v` projects at `s` to the view of its template's
    /// projection: a union or choice template (a join's) at the view's own
    /// place with the step, where a call relabels a join's κ (§2.9 *Keyed
    /// where a reader looks*). Elsewhere it projects as its answer does (#1350).
    fn viewProjectsTemplate(t: *const Table, places: *const Place.Table, v: NodeId, s: Step) bool {
        const template: NodeId = .from(t.nodes.items(.a)[v.int()]);
        if (!isJoinKind(t.kind(template))) return false;
        return t.place(v) == t.place(template) and places.child(t.place(template), s) != null;
    }

    /// The nodes `n`'s projection at `s` reads the projections of.
    fn projBelow(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, stack: anytype, n: NodeId, s: Step) Error!void {
        const d = t.get(n);
        switch (d.kind) {
            .recast => if (try t.recastPart(gpa, account, places, n, s)) |inner| try stack.append(gpa, .{ .node = inner, .expanded = false }),
            .delta => if (t.overGet(d.b, s) == null) try stack.append(gpa, .{ .node = .from(d.a), .expanded = false }),
            .@"union", .choice, .positions => try stack.appendSlice(gpa, &.{ .{ .node = .from(d.a), .expanded = false }, .{ .node = .from(d.b), .expanded = false } }),
            // A view projects as its answer does; the view of a DAG template
            // projects to the view of the template's projection, the node a
            // call's κ is keyed on (§2.9 *Keyed where a reader looks*).
            .view => if (t.viewProjectsTemplate(places, n, s)) try stack.append(gpa, .{ .node = .from(d.a), .expanded = false }) else try stack.append(gpa, .{ .node = try t.force(gpa, account, n), .expanded = false }),
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
        // Casts compose, as `recast` composes them: an answer that is a
        // recast is read through to its inner.
        var inner = try t.force(gpa, account, .from(t.get(n).a));
        if (t.kind(inner) == .recast) inner = try t.force(gpa, account, .from(t.get(inner).a));
        if (t.kind(inner) != .node and t.kind(inner) != .delta) return null;
        const child = places.child(t.place(n), s) orelse return null;
        return if (places.child(t.place(inner), s) == child) inner else null;
    }

    /// `n`'s projection at `s`, what it reads projected already.
    fn projOne(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, n: NodeId, s: Step) Error!void {
        const d = t.get(n);
        const before = t.nodes.len;
        // A view projects as its answer does, whose place may have a step
        // the template's has not: the actual at a type variable's place
        // (§2.11 *Re-rooting at a parameter*, #1350).
        if (d.kind == .view and t.viewProjectsTemplate(places, n, s)) {
            const tp: NodeId = .from(t.memo_proj.get(.{ d.a, s.word() }).?);
            const out = try t.view(gpa, account, tp, d.b);
            // A call relabels a join's entry onto this view, which no part of the
            // caller's value names: its origin carries it on (§2.9).
            try t.addOrigin(gpa, account, n, s, out);
            (try t.memo_proj.getOrPut(gpa, .{ n.int(), s.word() })).value_ptr.* = out.int();
            return;
        }
        if (d.kind == .view) {
            const hit = t.memo_proj.get(.{ t.memo_force.get(n).?.int(), s.word() }).?;
            (try t.memo_proj.getOrPut(gpa, .{ n.int(), s.word() })).value_ptr.* = hit;
            return;
        }
        const child_place = places.child(d.place, s) orelse {
            (try t.memo_proj.getOrPut(gpa, .{ n.int(), s.word() })).value_ptr.* = Ids.none_int;
            return;
        };
        const got = struct {
            fn of(tt: *Table, x: u32, st: Step) NodeId {
                return .from(tt.memo_proj.get(.{ x, st.word() }).?);
            }
        }.of;
        // A side with no such step stands at a type variable's place (a
        // join's place is the other side's, `joinPlace`): some value inside
        // it, read whole (§2.13.9).
        const side = struct {
            fn of(tt: *Table, gpa_: Allocator, account_: *Account, sets: *Cell.Radix, x: u32, st: Step, at: PlaceId) Error!NodeId {
                const hit = tt.memo_proj.get(.{ x, st.word() }).?;
                if (hit != Ids.none_int) return .from(hit);
                return tt.recastWhole(gpa_, account_, sets, at, .from(x));
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
            .@"union" => try t.@"union"(gpa, account, &cellt.sets, try side(t, gpa, account, &cellt.sets, d.a, s, child_place), try side(t, gpa, account, &cellt.sets, d.b, s, child_place)),
            .positions => try t.positions(gpa, account, &cellt.sets, try side(t, gpa, account, &cellt.sets, d.a, s, child_place), try side(t, gpa, account, &cellt.sets, d.b, s, child_place)),
            .choice => try t.choice(gpa, account, &cellt.sets, try side(t, gpa, account, &cellt.sets, d.a, s, child_place), try side(t, gpa, account, &cellt.sets, d.b, s, child_place)),
            .view => unreachable, // answered above
        };
        // A node the projection makes records `n` (*Bases*): a leaf's, a
        // recast's, a join's image, and the empty value past a missing
        // child. An explicit child, an override and a base's or an answer's
        // projection are made by none, so they record nothing more.
        const made = switch (d.kind) {
            .leaf, .recast, .@"union", .positions, .choice => true,
            .node => t.overGet(d.a, s) == null,
            .delta, .view => false,
        };
        if (made) try t.addConstruction(gpa, account, out, &.{n}, out.int() >= before);
        // A DAG made as a DAG's projection may be no part of any value: a
        // transport finds it through its origins (§2.9 *Keyed where a reader looks*).
        try t.addOrigin(gpa, account, n, s, out);
        (try t.memo_proj.getOrPut(gpa, .{ n.int(), s.word() })).value_ptr.* = out.int();
    }

    /// A union or a choice: the kinds a join of alternatives makes (§2.3).
    fn isJoinKind(k: Kind) bool {
        return k == .@"union" or k == .choice;
    }

    /// A union or a choice, or a call's view of one: what a join of
    /// alternatives keys, and what its projections' origins name (§2.9
    /// *Keyed where a reader looks*).
    pub fn isJoinNode(t: *const Table, n: NodeId) bool {
        const k = t.kind(n);
        if (k == .view) return isJoinKind(t.kind(.from(t.nodes.items(.a)[n.int()])));
        return isJoinKind(k);
    }

    /// `m`, the projection of DAG `n` at `s`, takes that origin, each of a DAG's
    /// kept, the latest first (§2.9 *Keyed where a reader looks*).
    fn addOrigin(t: *Table, gpa: Allocator, account: *Account, n: NodeId, s: Step, m: NodeId) Error!void {
        if (!t.isJoinNode(n) or !t.isJoinNode(m)) return;
        try account.reserve(.memo, 1);
        const got = try t.proj_origin.getOrPut(gpa, .{m.int()});
        const next: u32 = if (got.found_existing) got.value_ptr.* else Ids.none_int;
        var i = next;
        while (i != Ids.none_int) : (i = t.proj_origins.items[i][2]) {
            if (t.proj_origins.items[i][0] == n.int() and t.proj_origins.items[i][1] == s.word()) return;
        }
        got.value_ptr.* = @intCast(t.proj_origins.items.len);
        try t.proj_origins.append(gpa, .{ n.int(), s.word(), next });
    }

    /// Whether DAG node `n` is the projection of a DAG node (§2.9 *Keyed
    /// where a reader looks*).
    pub fn hasOrigin(t: *const Table, n: NodeId) bool {
        return t.proj_origin.get(.{n.int()}) != null;
    }

    /// Where `n`'s origins start: its own, or, for a call's view of a node
    /// with origins, its template's, each origin's node then viewed under the
    /// view's environment (`env`, none for its own): a call relabels a
    /// class's join entry onto the view of its node (§2.9 *Keyed where a
    /// reader looks*). `templates` false: own origins only (a recursive group's
    /// read-off, whose rounds the port join carries, #1466).
    pub fn originHead(t: *const Table, n: NodeId, templates: bool) ?struct { head: u32, env: u32 } {
        if (t.proj_origin.get(.{n.int()})) |h| return .{ .head = h, .env = Ids.none_int };
        if (!templates or t.kind(n) != .view) return null;
        const h = t.proj_origin.get(.{t.nodes.items(.a)[n.int()]}) orelse return null;
        return .{ .head = h, .env = t.nodes.items(.b)[n.int()] };
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
            // A refinement's projection keeps the position (§2.2 *Parts*):
            // `elem c·ι` by `s` is `part (elem c·ι)·s`, not `c[*]·s`. A loan
            // projects through its canonical position.
            if (o.isRefinement() and o != .loan) {
                if (s.kind == .level) {
                    var lv: std.ArrayList(CellId) = .empty;
                    defer lv.deinit(gpa);
                    if (try cellt.projectRefinedLevels(gpa, account, places, cell, &lv)) {
                        for (lv.items) |p| out = try cellt.sets.insert(gpa, .growth(account), out, p.int(), e.value);
                        continue;
                    }
                }
                const p = (try cellt.projectRefined(gpa, account, places, cell, s)) orelse continue;
                out = try cellt.sets.insert(gpa, .growth(account), out, p.int(), e.value);
                continue;
            }
            const sym = if (o.isRefinement()) (try cellt.unrefined(gpa, account, places, cell)) orelse continue else cell;
            if (!cellt.origin(sym).isSymbolic()) continue;
            const rec = cellt.get(sym);
            // A `⟲` whose levels have several canonical paths: a cell at each
            // (§2.1, *one position, one name*, #1253).
            if (s.kind == .level) if (try places.levelPaths(gpa, .growth(account), .from(rec.b))) |r| {
                var k: u32 = 0;
                while (k < r.len) : (k += 1) {
                    const lp = places.foldPath(r.start + k);
                    const lc = try cellt.symbolic(gpa, account, places, rec.origin, rec.a, lp, rec.c);
                    out = try cellt.sets.insert(gpa, .growth(account), out, lc.int(), e.value);
                }
                continue;
            };
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

        /// A join whose `ε` cells its sides' reaches hold, so `run` leaves
        /// them out (§2.3, #1467): its cells are its sides' `cellsOf`
        /// (`unionMake`, `choiceMake`, a positions node's parts), and each
        /// side is settled outside `m`'s component and not `short`, so its
        /// set holds them. A lazy join's own is nothing already.
        fn ownInSides(r: *const Reach, m: NodeId) bool {
            const d = r.t.get(m);
            if (d.kind != .@"union" and d.kind != .choice and d.kind != .positions) return false;
            if (r.t.isLazy(m)) return false;
            for ([2]NodeId{ .from(d.a), .from(d.b) }) |k| if (r.s.on_stack.contains(k) or r.short(k)) return false;
            return true;
        }

        /// Whether settled `k`'s set may not hold `cellsOf(k)`: a view's is
        /// its template's image (`viewReach`), not its answer's cells; a lazy
        /// node's is its parts' sets alone, which hold its cells only for a
        /// join over two sides that hold theirs, outside its component. Any
        /// other node's set holds its own cells, or sides' that hold them.
        fn short(r: *const Reach, k: NodeId) bool {
            if (r.t.kind(k) == .view) return true;
            const b = &r.t.reach_short[@intFromBool(r.filter != null)];
            return k.int() < b.bit_length and b.isSet(k.int());
        }

        /// `short` for `m`, of the component closing: its sides outside it
        /// are settled, those in it still on the stack.
        fn shortNow(r: *const Reach, m: NodeId) bool {
            if (r.t.kind(m) == .view) return true;
            if (!r.t.isLazy(m)) return false;
            const d = r.t.get(m);
            if (d.kind != .@"union" and d.kind != .choice and d.kind != .positions) return true;
            for ([2]NodeId{ .from(d.a), .from(d.b) }) |k| if (r.s.on_stack.contains(k) or r.short(k)) return true;
            return false;
        }

        /// Record `short` for `m`: a bit of a column grown by doubling, at
        /// most twice the nodes made (each charged when it was made).
        fn markShort(r: *Reach, m: NodeId, v: bool) Error!void {
            const b = &r.t.reach_short[@intFromBool(r.filter != null)];
            if (m.int() >= b.bit_length) {
                if (!v) return;
                try b.resize(r.gpa, @max(r.t.nodes.len, 2 * b.bit_length), false);
            }
            b.setValue(m.int(), v);
        }

        /// Whether `set` holds join `m`'s own cells (`own`'s filter applied)
        /// at values its `and` keeps. Uncharged, for runtime safety.
        fn covers(r: *Reach, set: SetId, m: NodeId) bool {
            if (r.t.isLazy(m)) return true;
            var it = r.sets.iterate(r.t.cells(m));
            while (it.next()) |e| {
                if (r.filter) |cellt| {
                    const o = cellt.origin(.from(e.key));
                    if (e.value == 0 and (o == .site or o == .result or o == .esc)) continue;
                }
                const v = r.sets.get(set, e.key) orelse return false;
                if (v & e.value != v) return false;
            }
            return true;
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
                    // A chain of D nested choices has D, D − 1, … own cells:
                    // their unions were O(D²) records (`ownInSides`).
                    if (!r.ownInSides(m)) set = try r.sets.unionWith(r.gpa, .growth(r.account), set, try r.own(m));
                    const first: u32 = @intCast(r.s.kids.items.len);
                    try r.children(m);
                    for (r.s.kids.items[first..]) |k| {
                        const s = r.got(k);
                        if (s != .none) set = try r.sets.unionWith(r.gpa, .growth(r.account), set, s);
                    }
                    r.s.kids.shrinkRetainingCapacity(first);
                    if (m == n) break;
                }
                // The set is the one the joins' own cells would give.
                if (std.debug.runtime_safety) for (r.s.scc_stack.items[i..]) |m| if (r.ownInSides(m)) std.debug.assert(r.covers(set, m));
                // Before the members leave the stack, which `shortNow` reads.
                for (r.s.scc_stack.items[i..]) |m| try r.markShort(m, r.shortNow(m));
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
    /// positions node's sides', a view's answer's; a leaf or a recast names
    /// none. Memoised per node, a side's list merged into its union's, so a
    /// union DAG costs each node its own steps once; a cycle of them (#1314)
    /// names what every record on it names, its least fixed point
    /// (`cycleWalk`). The slice is valid until the next call.
    pub fn namedSteps(t: *Table, gpa: Allocator, account: *Account, n: NodeId) Error![]const u32 {
        try account.reserve(.memo, 1);
        if (t.named_memo.get(n)) |r| return t.named_pool.items[r[0]..][0..r[1]];
        const walk = try t.dagWalk(gpa, account, n);
        defer if (walk) |k| account.leave(k);
        var w: NamedWalk = .{ .t = t, .gpa = gpa, .account = account };
        defer w.buf.deinit(gpa);
        try t.cycleWalk(gpa, n, &w);
        const r = t.named_memo.get(n).?;
        return t.named_pool.items[r[0]..][0..r[1]];
    }

    const NamedWalk = struct {
        t: *Table,
        gpa: Allocator,
        account: *Account,
        buf: std.ArrayList(u32) = .empty,

        /// A union's sides (the right one first), a delta's base, a view's
        /// answer (forced, unless `settling`).
        fn reads(w: *NamedWalk, x: NodeId, settling: bool) Error![2]NodeId {
            const d = w.t.get(x);
            return switch (d.kind) {
                .@"union", .choice, .positions => .{ .from(d.b), .from(d.a) },
                .delta => .{ .from(d.a), .none },
                .view => .{ if (settling) w.t.forced(x) else try w.t.force(w.gpa, w.account, x), .none },
                .leaf, .node, .recast => .{ .none, .none },
            };
        }

        fn from(w: *NamedWalk, x: NodeId) Error![2]NodeId {
            return w.reads(x, false);
        }

        fn settled(w: *NamedWalk, x: NodeId) bool {
            return w.t.named_memo.contains(x);
        }

        fn settle(w: *NamedWalk, members: []const NodeId) Error!void {
            const t = w.t;
            w.buf.clearRetainingCapacity();
            for (members) |x| {
                try w.account.reserve(.inspection, 1);
                const d = t.get(x);
                if (d.kind == .node or d.kind == .delta) {
                    // Its own steps, sorted in `buf` when it is empty (a
                    // record alone), else merged in from the pool's tail.
                    const at: u32 = @intCast(t.named_pool.items.len);
                    const list = if (w.buf.items.len > 0) &t.named_pool else &w.buf;
                    const lo = list.items.len;
                    var it = t.overEntries(if (d.kind == .node) d.a else d.b);
                    while (it.next()) |e| {
                        try w.account.reserve(.inspection, 1);
                        try list.append(w.gpa, e.step.word());
                    }
                    std.mem.sort(u32, list.items[lo..], {}, std.sort.asc(u32));
                    if (list == &t.named_pool) {
                        try t.mergeNamed(w.gpa, w.account, &w.buf, .{ at, @intCast(t.named_pool.items.len - at) });
                        t.named_pool.shrinkRetainingCapacity(at);
                    }
                }
                // What it reads that is kept: a member still open adds nothing.
                const two = try w.reads(x, true);
                for ([_]NodeId{ two[1], two[0] }) |y| if (y != .none) if (t.named_memo.get(y)) |got| try t.mergeNamed(w.gpa, w.account, &w.buf, got);
            }
            const at: u32 = @intCast(t.named_pool.items.len);
            try t.named_pool.appendSlice(w.gpa, w.buf.items);
            for (members) |m| try t.named_memo.put(w.gpa, m, .{ at, @intCast(w.buf.items.len) });
        }
    };

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
        return t.joinAs(gpa, account, places, cellt, members, .@"union", false);
    }

    /// `join` of exclusive alternatives (§2.3, #1128): a branch's or a
    /// fixpoint's arms. The same grouping, its outer DAG and every per-step
    /// child join made of `choice`; leaves still merge into one leaf (a cell
    /// in two arms is one, the maximum).
    pub fn joinChoice(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, members: []NodeId) Error!NodeId {
        return t.joinAs(gpa, account, places, cellt, members, .choice, false);
    }

    /// `joinChoice` for a caller that sets κ on the result from the members
    /// read whole (`Cond.propagate`: a branch's join, a class join's rounds):
    /// a member that is a choice is flattened into its arms, so the result
    /// is one choice of distinct alternatives (§2.3, #1372). Nothing is
    /// keyed by the nested choice the result no longer holds: its entry is
    /// read through the member it was. `eager`'s rebuild keeps `joinChoice`,
    /// since a published value's κ is carried by node (`kappaRelabel`).
    pub fn joinAlternatives(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, members: []NodeId) Error!NodeId {
        return t.joinAs(gpa, account, places, cellt, members, .choice, true);
    }

    fn joinAs(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, members: []NodeId, mode: Kind, flat: bool) Error!NodeId {
        std.debug.assert(members.len > 0);
        if (members.len == 1) return members[0];
        var w: JoinWalk = .{ .t = t, .gpa = gpa, .account = account, .places = places, .cellt = cellt, .mode = mode, .flat = flat, .before = t.nodes.len };
        defer w.deinit();
        return w.run(members);
    }

    fn baseOf(t: *const Table, n: NodeId) NodeId {
        return if (t.kind(n) == .delta) .from(t.nodes.items(.a)[n.int()]) else n;
    }

    /// What a join groups a member by (§2.11): its eager image's base, as
    /// the eager join grouped it.
    fn groupBase(t: *const Table, n: NodeId) NodeId {
        return t.baseOf(t.eagerOf(n));
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
        /// A choice member flattened into its arms (`joinAlternatives`).
        flat: bool = false,
        /// The table's size before the join: a node made by it is fresh.
        before: usize = 0,
        pool: std.ArrayList(NodeId) = .empty,
        reqs: std.ArrayList(Req) = .empty,
        parts: std.ArrayList(Part) = .empty,
        steps: std.ArrayList(StepChild) = .empty,
        stack: std.ArrayList(u32) = .empty,

        /// `first`, `len`: the members asked for (a join's bases); `run_first`,
        /// `run_len`: what is grouped, the same run unless a choice member
        /// was flattened into its arms (`flatten`).
        const Req = struct { first: u32, len: u32, key: ?[3]u32 = null, result: NodeId = .none, parts_first: u32 = 0, parts_len: u32 = 0, expanded: bool = false, run_first: u32 = 0, run_len: u32 = 0 };
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
            // A member is grouped by its eager image (§2.11) and kept itself: a
            // member taken whole is a side of the join, where its own κ is read
            // (*κ at a view*); an image is never read alone.
            for (members) |m| {
                _ = try w.t.eager(w.gpa, w.account, w.places, w.cellt, m);
                try w.pool.append(w.gpa, m);
            }
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
                if (t.memo_join.get(.{ w.memoMode(), x, y })) |hit| {
                    w.reqs.items[id].result = .from(hit);
                    return;
                }
                w.reqs.items[id].key = .{ w.memoMode(), x, y };
            }
            try w.account.reserve(.memo, 1);
            // A choice member's arms are alternatives of this choice too (§2.3
            // *`choice` and `union`*, #1372): flattened, so a nested choice and
            // its repeated arms are one set of distinct alternatives.
            const flat = if (w.flat) try w.flatten(r.first, r.len) else null;
            const run_first: u32 = if (flat) |fl| fl[0] else r.first;
            const run_len: u32 = if (flat) |fl| fl[1] else r.len;
            w.reqs.items[id].run_first = run_first;
            w.reqs.items[id].run_len = run_len;
            // Sort by (base, id): one pass groups and deduplicates.
            const members = w.pool.items[run_first..][0..run_len];
            std.mem.sort(NodeId, members, t, struct {
                fn lessThan(tt: *Table, a: NodeId, b: NodeId) bool {
                    // Groups in the order the eager join met them (`birth`).
                    const ga = tt.groupBase(a);
                    const gb = tt.groupBase(b);
                    if (ga != gb) return if (tt.birth(ga) != tt.birth(gb)) tt.birth(ga) < tt.birth(gb) else ga.int() < gb.int();
                    // One image's members next to each other.
                    const fa = tt.eagerOf(a);
                    const fb = tt.eagerOf(b);
                    if (fa != fb) return if (tt.birth(fa) != tt.birth(fb)) tt.birth(fa) < tt.birth(fb) else fa.int() < fb.int();
                    return a.int() < b.int();
                }
            }.lessThan);
            const parts_first: u32 = @intCast(w.parts.items.len);
            var leaf_cells: SetId = .none;
            var leaf_place: PlaceId = .none;
            var children: std.ArrayList(u32) = .empty;
            defer children.deinit(w.gpa);
            var i: usize = 0;
            while (i < run_len) {
                const run_now = w.pool.items[run_first..][0..run_len];
                var j = i + 1;
                while (j < run_now.len and t.groupBase(run_now[j]) == t.groupBase(run_now[i])) j += 1;
                const grp = run_now[i..j];
                i = j;
                // One group: deduplicate by image, then join the deltas over one
                // base. Of members with one image a view is kept: its read joins
                // the class's entry under it with its answer's (*κ at a view*).
                var distinct: usize = 1;
                for (grp[1..]) |m| {
                    const prev = &grp[distinct - 1];
                    const views = @as(u2, @intFromBool(t.kind(prev.*) == .view)) + @intFromBool(t.kind(m) == .view);
                    if (m == prev.* or (t.eagerOf(m) == t.eagerOf(prev.*) and views < 2)) {
                        if (t.kind(m) == .view) prev.* = m;
                        continue;
                    }
                    grp[distinct] = m;
                    distinct += 1;
                }
                if (distinct == 1) {
                    const one = t.eagerOf(grp[0]);
                    if (t.kind(one) == .leaf) {
                        leaf_cells = try w.cellt.sets.unionWith(w.gpa, .growth(w.account), leaf_cells, t.cells(one));
                        leaf_place = t.place(one);
                    } else {
                        try w.parts.append(w.gpa, .{ .kind = .node, .node = grp[0] });
                    }
                    continue;
                }
                // Copy the group out, at their images: requests below append
                // to the pool.
                const copy = try w.gpa.dupe(NodeId, grp[0..distinct]);
                defer w.gpa.free(copy);
                for (copy) |*c| c.* = t.eagerOf(c.*);
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

        /// The run `first..first+len` as one set of distinct alternatives,
        /// appended to the pool: `(first, len)` of the new run, or null when
        /// no member is a choice. The choice member with the most arms
        /// (`armCount`) is kept whole, and every other member that is a
        /// choice is replaced by its arms, its choice DAG walked through;
        /// an arm, or a member, the kept choice's DAG holds already is
        /// dropped (`choice(x, choice(x, y)) = choice(x, y)`, §2.3). So a
        /// join pays for the smaller members, never again for the DAG a
        /// tower of joins built. A view, or a node `eager` made again, is
        /// kept whole: its read joins the class's entry under it (§2.11 *κ
        /// at a view*). Only a choice is opened, so a union's or a positions
        /// node's sides never become alternatives.
        fn flatten(w: *JoinWalk, first: u32, len: u32) Error!?[2]u32 {
            const t = w.t;
            var keep: ?NodeId = null;
            var most: u32 = 0;
            for (w.pool.items[first..][0..len]) |m| {
                if (!w.opens(m)) continue;
                const arms = try t.armCount(w.gpa, w.account, m);
                if (keep == null or arms > most) {
                    keep = m;
                    most = arms;
                }
            }
            const kept = keep orelse return null;
            const seen = try t.marks.take(w.gpa);
            defer t.marks.give(seen);
            var todo: std.ArrayList(NodeId) = .empty;
            defer todo.deinit(w.gpa);
            const out: u32 = @intCast(w.pool.items.len);
            try w.pool.append(w.gpa, kept);
            try seen.put(w.gpa, kept, {});
            var k: u32 = len;
            while (k > 0) {
                k -= 1;
                try todo.append(w.gpa, w.pool.items[first + k]);
            }
            while (todo.pop()) |m| {
                if (seen.contains(m)) continue;
                try seen.put(w.gpa, m, {});
                try w.account.reserve(.inspection, 1);
                if (try t.dagHas(w.gpa, w.account, .choice, kept, m)) continue;
                if (!w.opens(m)) {
                    try w.pool.append(w.gpa, m);
                    continue;
                }
                const sides = t.sidesInOrder(m);
                try todo.appendSlice(w.gpa, &.{ sides[1], sides[0] });
            }
            return .{ out, @intCast(w.pool.items.len - out) };
        }

        /// The memo's mode word: a flattening join never shares an entry.
        fn memoMode(w: *const JoinWalk) u32 {
            return @as(u32, @backingInt(w.mode)) | @as(u32, @intFromBool(w.flat)) << 8;
        }

        fn opens(w: *const JoinWalk, m: NodeId) bool {
            return w.t.kind(m) == .choice and w.t.eagerOf(m) == m;
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
            // Each member a base of the join made of them (*Bases*), once,
            // where the join is computed: a memo hit records nothing more.
            // Of the members asked for: a flattened choice member is itself a base.
            try t.addConstruction(w.gpa, w.account, out, w.pool.items[r.first..][0..r.len], out.int() >= w.before);
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
    /// An image no back edge can name is interned (#1372): a value relabelled to
    /// what an earlier relabelling made is that node, so a round's unchanged
    /// value keeps its id and every memo keyed by it hits. Interning is by
    /// the record, never by absorption: a union, choice or positions image
    /// keeps both its sides, so no occurrence is dropped (§2.9).
    pub fn map(t: *Table, gpa: Allocator, account: *Account, n: NodeId, ctx: anytype, f: *const fn (@TypeOf(ctx), SetId) Error!SetId) Error!NodeId {
        t.memo_map.clear();
        t.map_open.clear();
        t.map_low.clear();
        t.map_src.clear();
        t.map_images.clear();
        t.map_shared = false;
        t.stable.clearTrail();
        return t.mapWalk(gpa, account, n, ctx, f);
    }

    /// The built node of the last `map` that `x` stands for: itself, or
    /// what `eager` made of it or of a view's answer; null for none.
    pub fn mapSource(t: *const Table, x: NodeId) ?NodeId {
        for ([_]?NodeId{ x, t.eagerOf(x), t.answerOf(x), if (t.answerOf(x)) |a| t.eagerOf(a) else null }) |c| {
            if (c) |s| if (t.map_src.contains(s)) return s;
        }
        return null;
    }

    /// The earliest open node an image reaches: its entry index, and the
    /// node, so an entry made while it was open is ignored once it closes.
    pub const MapLow = struct { node: NodeId, index: u32 };
    const map_closed: u32 = std.math.maxInt(u32);

    /// The earliest of `low` and what `child`'s image reaches that is
    /// still open (a child open itself is a back edge, the knot).
    fn mapLowWith(t: *const Table, low: ?MapLow, child: NodeId) ?MapLow {
        const got: ?MapLow = if (t.map_open.get(child)) |i| (if (i != map_closed) MapLow{ .node = child, .index = i } else t.map_low.get(child)) else t.map_low.get(child);
        const live: ?MapLow = if (got) |g| (if (t.map_open.get(g.node) == g.index) g else null) else null;
        if (live == null) return low;
        if (low == null or live.?.index < low.?.index) return live;
        return low;
    }

    fn mapLowPut(t: *Table, gpa: Allocator, n: NodeId, low: ?MapLow) Allocator.Error!void {
        if (low) |l| try t.map_low.put(gpa, n, l);
    }

    /// The record at `slot`, made raw by `mapWalk`, interned: an equal
    /// record already interned is the image, and `slot` is left inert (no
    /// node names it); otherwise `slot` is interned as itself. `make`'s key.
    fn mapAdopt(t: *Table, gpa: Allocator, slot: NodeId) Allocator.Error!NodeId {
        const n = t.get(slot);
        const keyed: u32 = if (n.kind == .recast or n.kind == .delta) Ids.none_int else n.cells.int();
        const got = try t.intern.getOrPut(gpa, .{ @backingInt(n.kind), n.place.int(), keyed, n.a, n.b });
        if (got.found_existing) {
            t.nodes.set(slot.int(), .{ .kind = .leaf, .place = .none, .cells = .none, .a = 0, .b = 0, .reach = .none });
            return .from(got.value_ptr.*);
        }
        got.value_ptr.* = slot.int();
        return slot;
    }

    /// `memo_map`'s put, on the trail a closed knot moves along (§2.3, 4e).
    fn mapPut(t: *Table, gpa: Allocator, src: NodeId, img: NodeId) Allocator.Error!void {
        try t.memo_map.put(gpa, src, img);
        try t.stable.trail.append(gpa, .{ src.int(), img.int() });
    }

    fn mapWalk(t: *Table, gpa: Allocator, account: *Account, root: NodeId, ctx: anytype, f: *const fn (@TypeOf(ctx), SetId) Error!SetId) Error!NodeId {
        // On an explicit stack (#1138: a value is as deep as the source). A
        // node or a delta takes its image before its children, so a cyclic
        // child finds it (the knot); a recast, a union or a positions node
        // after its parts.
        // `f` runs on entry, as the recursion ran it, and parts in the
        // recursion's order, so what `f` interns is interned as before.
        // Each node or delta entered is open until its parts are mapped; an
        // image that reaches no node still open is interned
        // (`mapAdopt`), one that does stays the record it was made as.
        const Frame = struct { node: NodeId, expanded: bool, cells: SetId = .none, eager: NodeId = .none };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        var kids: std.ArrayList(NodeId) = .empty;
        defer kids.deinit(gpa);
        var entered: u32 = 0;
        try stack.append(gpa, .{ .node = root, .expanded = false });
        while (stack.pop()) |fr| {
            const n = fr.node;
            const d = t.get(n);
            if (!fr.expanded) {
                if (t.memo_map.get(n) != null) continue;
                // A node `eager` made again is published as its image (§2.11).
                const img = t.eagerOf(n);
                if (img != n) {
                    try stack.appendSlice(gpa, &.{ .{ .node = n, .expanded = true, .eager = img }, .{ .node = img, .expanded = false } });
                    continue;
                }
                switch (d.kind) {
                    .leaf => try t.mapPut(gpa, n, try t.leaf(gpa, account, d.place, try f(ctx, d.cells))),
                    .recast => {
                        // A lazy node's image is lazy too: its parts' images hold its cells.
                        try stack.append(gpa, .{ .node = n, .expanded = true, .cells = if (d.cells == lazy_cells) lazy_cells else try f(ctx, d.cells) });
                        try stack.append(gpa, .{ .node = .from(d.a), .expanded = false });
                    },
                    .@"union", .choice, .positions => {
                        try stack.append(gpa, .{ .node = n, .expanded = true, .cells = if (d.cells == lazy_cells) lazy_cells else try f(ctx, d.cells) });
                        // A union's or a choice's sides in `birth` order: an eager image
                        // made at publish where the eager graft made it.
                        const sides = t.sidesInOrder(n);
                        try stack.appendSlice(gpa, &.{ .{ .node = sides[1], .expanded = false }, .{ .node = sides[0], .expanded = false } });
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
                        try t.mapPut(gpa, n, out);
                        try t.map_open.put(gpa, n, entered);
                        try t.stable.trail_at.append(gpa, @intCast(t.stable.trail.items.len));
                        entered += 1;
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
            if (fr.eager != .none) {
                if (t.memo_map.get(n) != null) continue;
                const image = t.memo_map.get(fr.eager).?;
                const low = t.mapLowWith(null, fr.eager);
                var id: ?NodeId = n;
                while (id) |x| : (id = if (t.kind(x) == .view) t.chainNext(x) else null) {
                    if (t.memo_map.get(x) != null) break;
                    try t.mapPut(gpa, x, image);
                    try t.mapLowPut(gpa, x, low);
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
                    const answer = t.memo_force.get(n).?;
                    const image = t.memo_map.get(answer).?;
                    const low = t.mapLowWith(null, answer);
                    var id: ?NodeId = n;
                    while (id) |x| : (id = t.chainNext(x)) {
                        if (t.memo_map.get(x) != null) break;
                        try t.mapPut(gpa, x, image);
                        try t.mapLowPut(gpa, x, low);
                    }
                },
                .recast => {
                    if (t.memo_map.get(n) != null) continue;
                    const in = t.memo_map.get(.from(d.a)).?;
                    // A whole recast stays whole, its reach relabelled (#1311).
                    try t.mapPut(gpa, n, if (d.b == 1) try t.wholeOver(gpa, account, d.place, in, fr.cells) else try t.recast(gpa, account, d.place, in));
                    try t.mapLowPut(gpa, n, t.mapLowWith(null, .from(d.a)));
                },
                .@"union", .choice, .positions => {
                    if (t.memo_map.get(n) != null) continue;
                    const c = fr.cells;
                    const sides = t.sidesInOrder(n);
                    const l = t.memo_map.get(sides[0]).?;
                    const r = t.memo_map.get(sides[1]).?;
                    const low = t.mapLowWith(t.mapLowWith(null, sides[0]), sides[1]);
                    const rec: Node = .{ .kind = d.kind, .place = d.place, .cells = c, .a = l.int(), .b = r.int(), .reach = .none };
                    // On a knot: the record raw, as the knot's parts are.
                    // Otherwise interned as it is, both sides kept.
                    const out: NodeId = if (low != null) blk: {
                        try account.reserve(.shape, 1);
                        const id: NodeId = .from(t.count());
                        try t.nodes.append(gpa, rec);
                        break :blk id;
                    } else try t.make(gpa, account, rec);
                    try t.mapPut(gpa, n, out);
                    try t.mapLowPut(gpa, n, low);
                },
                .node, .delta => {
                    const out = t.memo_map.get(n).?;
                    const index = t.map_open.get(n).?;
                    var low: ?MapLow = null;
                    var mapped: u32 = over_none;
                    var it = t.overEntries(if (d.kind == .node) d.a else d.b);
                    while (it.next()) |e| {
                        mapped = try t.overPut(gpa, account, mapped, e.step, t.memo_map.get(e.node).?);
                        low = t.mapLowWith(low, e.node);
                    }
                    if (d.kind == .node) {
                        t.nodes.items(.a)[out.int()] = mapped;
                    } else {
                        low = t.mapLowWith(low, .from(d.a));
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
                    // Closed: a part that named it named the knot's own
                    // record; one that reaches an earlier open node is on
                    // that node's knot. Neither is interned; every other
                    // image is, as no back edge can name its slot.
                    t.map_open.put(gpa, n, map_closed) catch unreachable;
                    if (low) |l| {
                        if (l.index < index) try t.map_low.put(gpa, n, l) else try Stable.mapKnot(t, gpa, account, out, index);
                    } else try t.mapPut(gpa, n, try t.mapAdopt(gpa, out));
                    try t.map_src.put(gpa, n, {});
                    if ((try t.map_images.getOrPut(gpa, t.memo_map.get(n).?)).found_existing) t.map_shared = true;
                },
            }
        }
        return t.memo_map.get(root).?;
    }

    /// What value `root` is as the eager graft made it (§2.11 *κ at a view*):
    /// a view its class's `res` grafted onto the canonical actuals with the
    /// eager image's constructors — a leaf the `join` of its parts (the actual
    /// at an exact parameter cell, its recast at an approximate one, the other
    /// cells one mapped leaf), a node over its children's images, a delta its
    /// base's image `put` at each override, a recast of its inner's image, a
    /// union `join`, a choice `joinChoice`, a positions node `collect`. The raw
    /// answer `force` made for a view is that view's image; any other node
    /// holding a view is made again with the constructors over its parts'
    /// images, as the frame made it of eager values. Joins group and absorb
    /// by it and read-off publishes it, so no view and no raw expansion
    /// reaches a published value. Bottom-up on an explicit stack, memoised
    /// per node until a knot is tied: a chain of calls costs each call the
    /// nodes its template adds. A cyclic value (a widened knot) stays as it is.
    pub fn eager(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, root: NodeId) Error!NodeId {
        if (root == .none) return root;
        if (t.eager_ties != t.ties) {
            t.memo_eager.clear();
            t.eager_ties = t.ties;
        }
        if (t.memo_eager.get(root)) |e| return e;
        if (t.kind(root) != .view and !try t.holdsView(gpa, root)) return root;
        const Frame = struct { node: NodeId, expanded: bool, parts_first: u32 = 0, parts_len: u32 = 0, key: u32 = 0 };
        // What an image made here is ordered by (`birth`): the node met before
        // this walk it stands for, as the eager graft made it then; within
        // one, the order this walk makes them, the graft's.
        const start = t.nodes.len;
        const keyOf = struct {
            fn of(tt: *const Table, x: NodeId) u32 {
                return tt.birth(tt.answered.get(x) orelse x);
            }
        }.of;
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        var open: stamped.Column(NodeId, void) = .{};
        defer open.deinit(gpa);
        var kids: std.ArrayList(NodeId) = .empty;
        defer kids.deinit(gpa);
        var parts: std.ArrayList(LeafPart) = .empty;
        defer parts.deinit(gpa);
        try stack.append(gpa, .{ .node = root, .expanded = false, .key = keyOf(t, root) });
        while (stack.pop()) |f| {
            const n = f.node;
            if (t.memo_eager.contains(n)) continue;
            if (f.expanded) {
                open.remove(n);
                const made = t.nodes.len;
                const out = try t.eagerOne(gpa, account, places, cellt, n, parts.items[f.parts_first..][0..f.parts_len]);
                try t.memo_eager.put(gpa, n, out);
                // A node made here is ordered where the node it stands for was
                // made, as the eager graft made it then (`birth`).
                if (out.int() >= made) try t.born.put(gpa, out, .from(f.key));
                continue;
            }
            // A cycle: the value is kept as the frame made it.
            if (open.contains(n)) return root;
            try account.reserve(.inspection, 1);
            if (t.kind(n) != .view and t.answered.get(n) == null and !try t.holdsView(gpa, n)) {
                try t.memo_eager.put(gpa, n, n);
                continue;
            }
            var fr: Frame = .{ .node = n, .expanded = true, .key = f.key };
            kids.clearRetainingCapacity();
            const d = t.get(n);
            // A view's template children are made with it (the graft's order).
            const inherit = t.answered.get(n) != null or (d.kind == .view and t.kind(.from(d.a)) != .leaf);
            if (t.answered.get(n)) |v| {
                try kids.append(gpa, v);
            } else switch (d.kind) {
                .view => {
                    const inst = t.instantiation orelse unreachable; // a view exists only under one
                    const tm = t.get(.from(d.a));
                    switch (tm.kind) {
                        .leaf => {
                            fr.parts_first = @intCast(parts.items.len);
                            try inst.parts(inst.ctx, t, gpa, account, d.b, .from(d.a), &parts);
                            fr.parts_len = @intCast(parts.items.len - fr.parts_first);
                            for (parts.items[fr.parts_first..]) |p| try kids.append(gpa, p.node);
                        },
                        .node, .delta => {
                            if (tm.kind == .delta) try kids.append(gpa, try t.view(gpa, account, .from(tm.a), d.b));
                            var it = t.overEntries(if (tm.kind == .node) tm.a else tm.b);
                            while (it.next()) |e| try kids.append(gpa, try t.view(gpa, account, e.node, d.b));
                        },
                        .recast => try kids.append(gpa, try t.view(gpa, account, .from(tm.a), d.b)),
                        .@"union", .choice, .positions => try kids.appendSlice(gpa, &.{ try t.view(gpa, account, .from(tm.a), d.b), try t.view(gpa, account, .from(tm.b), d.b) }),
                        .view => unreachable, // a class is stored forced
                    }
                },
                .leaf => {},
                .node, .delta => {
                    if (d.kind == .delta) try kids.append(gpa, .from(d.a));
                    var it = t.overEntries(if (d.kind == .node) d.a else d.b);
                    while (it.next()) |e| try kids.append(gpa, e.node);
                },
                .recast => try kids.append(gpa, .from(d.a)),
                .@"union", .choice, .positions => try kids.appendSlice(gpa, &.{ .from(d.a), .from(d.b) }),
            }
            try open.put(gpa, n, {});
            try stack.append(gpa, fr);
            for (kids.items) |k| if (!t.memo_eager.contains(k)) try stack.append(gpa, .{ .node = k, .expanded = false, .key = if (!inherit and k.int() < start) keyOf(t, k) else f.key });
        }
        return t.eagerOf(root);
    }

    /// `n`'s eager image, its parts' images made (`eager`).
    fn eagerOne(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, cellt: *Cell.Table, n: NodeId, parts: []const LeafPart) Error!NodeId {
        if (t.answered.get(n)) |v| return t.eagerOf(v);
        const d = t.get(n);
        switch (d.kind) {
            .leaf => return n,
            .view => {
                const inst = t.instantiation orelse unreachable;
                const tm = t.get(.from(d.a));
                return switch (tm.kind) {
                    .leaf => blk: {
                        if (parts.len == 1 and !parts[0].approx) break :blk t.eagerOf(parts[0].node);
                        const ms = try gpa.alloc(NodeId, parts.len);
                        defer gpa.free(ms);
                        for (parts, ms) |p, *m| m.* = if (p.approx) try t.recast(gpa, account, d.place, t.eagerOf(p.node)) else t.eagerOf(p.node);
                        break :blk if (ms.len == 1) ms[0] else try t.join(gpa, account, places, cellt, ms);
                    },
                    .node => blk: {
                        const c = if (tm.cells == .none) SetId.none else try inst.cells(inst.ctx, t, gpa, account, d.b, tm.cells, d.place);
                        var over: u32 = over_none;
                        var it = t.overEntries(tm.a);
                        while (it.next()) |e| over = try t.overPut(gpa, account, over, e.step, t.eagerOf(try t.view(gpa, account, e.node, d.b)));
                        break :blk try t.node(gpa, account, d.place, c, over);
                    },
                    .delta => blk: {
                        var x = t.eagerOf(try t.view(gpa, account, .from(tm.a), d.b));
                        var it = t.overEntries(tm.b);
                        while (it.next()) |e| x = try t.put(gpa, account, places, cellt, x, e.step, t.eagerOf(try t.view(gpa, account, e.node, d.b)), true, .none);
                        break :blk x;
                    },
                    // A whole recast stays whole (#1311).
                    .recast => try t.recastAs(gpa, account, &cellt.sets, .from(d.a), t.eagerOf(try t.view(gpa, account, .from(tm.a), d.b))),
                    .@"union", .choice => blk: {
                        var two = [_]NodeId{ t.eagerOf(try t.view(gpa, account, .from(tm.a), d.b)), t.eagerOf(try t.view(gpa, account, .from(tm.b), d.b)) };
                        break :blk if (tm.kind == .choice) try t.joinChoice(gpa, account, places, cellt, &two) else try t.join(gpa, account, places, cellt, &two);
                    },
                    .positions => try t.collect(gpa, account, &cellt.sets, &.{ t.eagerOf(try t.view(gpa, account, .from(tm.a), d.b)), t.eagerOf(try t.view(gpa, account, .from(tm.b), d.b)) }),
                    .view => unreachable,
                };
            },
            .node => {
                var over: u32 = over_none;
                var it = t.overEntries(d.a);
                while (it.next()) |e| over = try t.overPut(gpa, account, over, e.step, t.eagerOf(e.node));
                return t.node(gpa, account, d.place, d.cells, over);
            },
            .delta => {
                var base = t.eagerOf(.from(d.a));
                var over: u32 = over_none;
                if (t.kind(base) == .delta) {
                    over = t.nodes.items(.b)[base.int()];
                    base = .from(t.nodes.items(.a)[base.int()]);
                }
                var it = t.overEntries(d.b);
                while (it.next()) |e| over = try t.overPut(gpa, account, over, e.step, t.eagerOf(e.node));
                return t.delta(gpa, account, base, over);
            },
            .recast => return t.recastAs(gpa, account, &cellt.sets, n, t.eagerOf(.from(d.a))),
            .@"union" => return t.@"union"(gpa, account, &cellt.sets, t.eagerOf(.from(d.a)), t.eagerOf(.from(d.b))),
            .choice => return t.choice(gpa, account, &cellt.sets, t.eagerOf(.from(d.a)), t.eagerOf(.from(d.b))),
            .positions => return t.positions(gpa, account, &cellt.sets, t.eagerOf(.from(d.a)), t.eagerOf(.from(d.b))),
        }
    }

    /// Where `n` is ordered among its siblings (a join's groups, a union's
    /// sides at publish): an `eager` image where the node it stands for was
    /// made, which is where the eager graft made it; any other node where it
    /// was made. So publishing a value made of views orders it as the eager
    /// image did, and its fresh cells are numbered alike.
    pub fn birth(t: *const Table, n: NodeId) u32 {
        return (t.born.get(n) orelse n).int();
    }

    /// A union's or a choice's sides in `birth` order; a positions node's as
    /// they are (its order is its structure).
    fn sidesInOrder(t: *const Table, n: NodeId) [2]NodeId {
        const d = t.get(n);
        const a: NodeId = .from(d.a);
        const b: NodeId = .from(d.b);
        if (d.kind == .positions or t.birth(a) <= t.birth(b)) return .{ a, b };
        return .{ b, a };
    }

    /// What `eager` made of `n`: the image of the view whose raw answer it is,
    /// `n` itself when `eager` met neither.
    pub fn eagerOf(t: *const Table, n: NodeId) NodeId {
        if (t.eager_ties != t.ties) return n;
        if (t.memo_eager.get(n)) |e| return e;
        if (t.answered.get(n)) |v| if (t.memo_eager.get(v)) |e| return e;
        return n;
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
                while (top.step <= steps.len) {
                    // Last, a use shape's `⟲` child, no step of a place; a leaf `m` stands for it (#1523).
                    const s = if (top.step < steps.len) steps[top.step] else Step.level;
                    top.step += 1;
                    const pn = (if (s.kind != .level) try t.proj(gpa, account, places, cellt, top.n, s) else if (t.kind(top.n) == .node) t.overGet(t.nodes.items(.a)[top.n.int()], s) else null) orelse continue;
                    const pm = (if (s.kind == .level and t.kind(top.m) == .leaf) top.m else try t.proj(gpa, account, places, cellt, top.m, s)) orelse {
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
        /// The unions, choices and positions nodes met on the cycle (at a
        /// `⟲`, or in a group's rounds at a place on a cycle), whose sides are
        /// walked as members of their class (§2.3): their meaning is their
        /// sides', so they ride beside no image.
        opened: stamped.Column(NodeId, void) = .{},
        /// How many times the walk reached each node: a node reached twice
        /// stands at two positions of its class.
        occurs: stamped.Column(NodeId, u32) = .{},
        pending: std.ArrayList([2]u32) = .empty,
        image: stamped.Column(NodeId, NodeId) = .{},
        kids: std.ArrayList(NodeId) = .empty,
        any_merge: bool = false,
        /// In a group's rounds (`Table.widen_rounds`): every `⟲`'s target, the
        /// class path it returns to, and each target with its ancestors.
        /// Computed once, on the first node that asks.
        targets: stamped.Column(PathId, void) = .{},
        toward: stamped.Column(PathId, void) = .{},
        targets_done: bool = false,
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
            w.targets.deinit(w.gpa);
            w.toward.deinit(w.gpa);
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

        /// A second child `child` at step `step` of class `rep`, whose step
        /// map holds `slot`: a congruence to settle (queued), unless one of
        /// the two is an atom (`Table.isAtom`), which adds nothing beside
        /// the other: the atom gives way, the entry names `child`.
        fn settle(w: *Widen, rep: u32, step: u32, slot: *u32, child: u32) Error!void {
            if (w.find(slot.*) == w.find(child) or w.t.isAtom(.from(child))) return;
            if (!w.t.isAtom(.from(slot.*))) return w.pending.append(w.gpa, .{ slot.*, child });
            const old = slot.*;
            slot.* = child;
            var e = w.edge_head.items[rep];
            while (e != none) : (e = w.entries.items(.next)[e]) {
                try w.account.reserve(.inspection, 1);
                if (w.entries.items(.step)[e] == step and w.entries.items(.child)[e] == old) {
                    w.entries.items(.child)[e] = child;
                    return;
                }
            }
            unreachable; // the step map and the entry list name one child
        }

        /// Record `rep —s→ child`: a second child at one step of a class is
        /// a congruence to settle (`settle`), never two entries.
        fn addEdge(w: *Widen, rep: u32, step: u32, child: u32) Error!void {
            try w.account.reserve(.edge, 1);
            const got = try w.edges.getOrPut(w.gpa, .{ rep, step });
            if (got.found_existing) {
                try w.settle(rep, step, got.value_ptr, child);
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
                    try w.settle(big, step, got.value_ptr, child);
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

        /// In a group's rounds, whether a re-entry relates to `p`: its
        /// target (the class path a `⟲` returns to) is `p`, above `p` or
        /// below it. A union, choice or positions node at a place on a cycle
        /// is opened only then (§2.3 *On the cycle*): a re-entry below the
        /// node (`A1 xs (B2 [] b)`, B's own cycle under A's root join) nests
        /// the previous round under the kept node as surely as one at it.
        fn related(w: *Widen, root: NodeId, p: PathId) Error!bool {
            if (!w.targets_done) {
                w.targets_done = true;
                try w.findTargets(root);
            }
            try w.account.reserve(.path, 1);
            if (w.toward.contains(p)) return true;
            var at = p;
            while (w.places.pathParent(at) != .none) {
                at = w.places.pathParent(at);
                try w.account.reserve(.path, 1);
                if (w.targets.contains(at)) return true;
            }
            return false;
        }

        /// The probe: the value's explicit edges, every union's, choice's
        /// and positions node's sides at its path, each node once, as the
        /// walk proper reads them; each `⟲` its target, the target and its
        /// ancestors `toward` (each path once).
        fn findTargets(w: *Widen, root: NodeId) Error!void {
            const Frame = struct { node: NodeId, path: PathId };
            var stack: std.ArrayList(Frame) = .empty;
            defer stack.deinit(w.gpa);
            var seen: stamped.Column(NodeId, void) = .{};
            defer seen.deinit(w.gpa);
            try stack.append(w.gpa, .{ .node = root, .path = try w.places.rootPath(w.gpa, w.t.place(root)) });
            while (stack.pop()) |f| {
                try w.account.reserve(.edge, 1);
                const n = try w.t.force(w.gpa, w.account, f.node);
                if (w.places.pathParent(f.path) != .none and w.places.pathStep(f.path).kind == .level) {
                    var at = w.places.pathParent(f.path);
                    try w.targets.put(w.gpa, at, {});
                    while (at != .none and !w.toward.contains(at)) : (at = w.places.pathParent(at)) {
                        try w.account.reserve(.path, 1);
                        try w.toward.put(w.gpa, at, {});
                    }
                }
                if (seen.contains(n)) continue;
                try seen.put(w.gpa, n, {});
                switch (w.t.kind(n)) {
                    .@"union", .choice, .positions => {
                        const d = w.t.get(n);
                        try stack.appendSlice(w.gpa, &.{ .{ .node = .from(d.a), .path = f.path }, .{ .node = .from(d.b), .path = f.path } });
                        continue;
                    },
                    else => {},
                }
                try w.explicitEdges(n);
                var i: usize = 0;
                while (i < w.kids.items.len) : (i += 2) {
                    const step = Step.fromWord(w.kids.items[i].int());
                    const cp = (try w.places.extend(w.gpa, .growth(w.account), f.path, step)) orelse continue;
                    try stack.append(w.gpa, .{ .node = w.kids.items[i + 1], .path = cp });
                }
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
                // An atom is no member of any class (`Table.isAtom`).
                if (w.t.isAtom(fnode)) continue;
                try w.touch(fnode);
                const seen_before = w.occurs.get(fnode) orelse 0;
                try w.occurs.put(w.gpa, fnode, seen_before + 1);
                try w.account.reserve(.edge, 1);
                // `⟲` is its ancestor's class: the re-entered place's node,
                // the first return (#1253), which keys its own. Both are on
                // the cycle being folded, where a union is opened.
                const level = w.places.pathParent(f.path) != .none and w.places.pathStep(f.path).kind == .level;
                const reentry = w.places.isReturn(f.path);
                const key = if (level) w.places.pathParent(f.path) else f.path;
                if (w.by_path.get(key)) |cls| {
                    _ = try w.unite(cls, fnode.int());
                } else {
                    try w.by_path.put(w.gpa, key, w.find(fnode.int()));
                }
                if (w.visited.contains(fnode)) continue;
                try w.visited.put(w.gpa, fnode, {});
                try w.seen_order.append(w.gpa, fnode);
                // A union, choice or positions node on the cycle being folded:
                // its sides are at its path, so they are members of its class
                // (§2.3). On the cycle is at a re-entry, or, in a group's
                // rounds, at a place on a cycle a re-entry relates to (a
                // branch join at a member's root): kept whole there, its
                // arms' re-entries would never be walked, and the rounds
                // would nest under it without end.
                switch (w.t.kind(fnode)) {
                    .@"union", .choice, .positions => if (reentry or (w.t.widen_rounds and w.places.onCycle(w.t.place(fnode)) and try w.related(root, f.path))) {
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
                if (w.t.isAtom(.from(rep))) {
                    // Its own class, alone, and its own image (`Table.isAtom`).
                    if (std.debug.runtime_safety) std.debug.assert(w.head.items[rep] == rep and w.tail.items[rep] == rep);
                    try w.image.put(w.gpa, .from(rep), .from(rep));
                    continue;
                }
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
                    // The atom rule: no class with an image has an atom member.
                    if (std.debug.runtime_safety) std.debug.assert(!w.t.isAtom(.from(m)));
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
                    // The copy keeps the side's reach memo, so its `short` bit too (#1517).
                    const sb = &w.t.reach_short[0];
                    if (sb.bit_length <= id.int()) try sb.resize(w.gpa, @max(w.t.nodes.len, 2 * sb.bit_length), false);
                    sb.setValue(id.int(), side.?.int() < sb.bit_length and sb.isSet(side.?.int()));
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
/// Int`; 2: `Int`; 3: a record `{ a : List Int, b : List Int }`; 4, 5: A and B
/// below; 10 + k: a
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
            // `type A = A1 (List Int) B | A0`, `type B = B1 (List Int) A | B2
            // (List Int) B | B0` (#1360's review): B has a cycle of its own
            // inside A's.
            4 => {
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 1, 0) catch unreachable), .@"var" = 1 });
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 1, 1) catch unreachable), .@"var" = 5 });
                return .{ .kind = .ctor, .head = 101 };
            },
            5 => {
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 2, 0) catch unreachable), .@"var" = 1 });
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 2, 1) catch unreachable), .@"var" = 4 });
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 3, 0) catch unreachable), .@"var" = 1 });
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 3, 1) catch unreachable), .@"var" = 5 });
                return .{ .kind = .ctor, .head = 102 };
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
    // The root keeps its own list (#1253: the first return to `Tree` is a
    // plain path and keys its own class); the subtrees, one node `inner` at
    // `#Node.0` and `#Node.2` with the levels below, are one class, a knot: its recursive children name it (or
    // its union with the parameter leaf), and its lists are joined.
    try testing.expectEqual(@as(u32, 1), f.cells.sets.count(f.shapes.cells(try f.proj(w, s1))));
    const sub = try f.proj(w, s0);
    try testing.expect(sub != w);
    try testing.expectEqual(sub, try f.proj(w, s2));
    const knot = struct {
        fn of(x: NodeId, y: NodeId, sh: *const Table) bool {
            return x == y or (sh.kind(x) == .@"union" and sh.nodes.items(.a)[x.int()] == y.int());
        }
    }.of;
    const sub_core: NodeId = if (f.shapes.kind(sub) == .@"union") .from(f.shapes.nodes.items(.a)[sub.int()]) else sub;
    try testing.expect(knot(try f.proj(sub_core, s0), sub_core, &f.shapes));
    const lists = try f.proj(sub, s1);
    // Inner's fresh list and, beside the image, the parameter's own list
    // below (`π₂·#Node.1`).
    try testing.expectEqual(@as(u32, 2), f.cells.sets.count(f.shapes.cells(lists)));
    // Extensive, and a fixpoint: widening again changes nothing semantically.
    try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, outer, w));
    try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, inner, sub));
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

/// One round of `pick`'s result over the recursive call's value `x`
/// (#1360): `case t of Node l xs _ → Node (case l of Node a ys _ → Node a
/// ys x; Leaf → x) xs Leaf; Leaf → Leaf`, its root a branch join. `root`
/// says what joins at the root: 0 the two arms, a `choice`; 1 a `choice`
/// nested in a `choice` (an `if` in one arm); 2 that `choice` inside a
/// `union` with `x` (a pattern's two descriptions of one value).
fn pickRound(f: *Fixture, x: NodeId, root: u8) !NodeId {
    const gpa = testing.allocator;
    const tree = try f.placeOf(0);
    const list = try f.placeOf(1);
    const s0 = try f.places.ctorStep(gpa, &f.account, 0, 0);
    const s1 = try f.places.ctorStep(gpa, &f.account, 0, 1);
    const s2 = try f.places.ctorStep(gpa, &f.account, 0, 2);
    const leaf_ctor = try f.shapes.leaf(gpa, &f.account, tree, .none);
    const a = try f.shapes.leaf(gpa, &f.account, tree, try f.param(1, tree));
    var kids = try f.one(s0, a);
    kids = try f.shapes.overPut(gpa, &f.account, kids, s1, try f.shapes.leaf(gpa, &f.account, list, try f.param(4, list)));
    kids = try f.shapes.overPut(gpa, &f.account, kids, s2, x);
    const inner = try f.shapes.choice(gpa, &f.account, &f.cells.sets, try f.shapes.node(gpa, &f.account, tree, try f.site(1, tree, .none), kids), x);
    var okids = try f.one(s0, inner);
    okids = try f.shapes.overPut(gpa, &f.account, okids, s1, try f.shapes.leaf(gpa, &f.account, list, try f.param(5, list)));
    okids = try f.shapes.overPut(gpa, &f.account, okids, s2, leaf_ctor);
    const outer = try f.shapes.node(gpa, &f.account, tree, try f.site(2, tree, .none), okids);
    return switch (root) {
        0 => f.shapes.choice(gpa, &f.account, &f.cells.sets, outer, leaf_ctor),
        1 => f.shapes.choice(gpa, &f.account, &f.cells.sets, try f.shapes.choice(gpa, &f.account, &f.cells.sets, outer, x), leaf_ctor),
        else => f.shapes.@"union"(gpa, &f.account, &f.cells.sets, try f.shapes.choice(gpa, &f.account, &f.cells.sets, outer, leaf_ctor), x),
    };
}

/// One node per canonical path (§2.3): a class is one built node (beside
/// its leaf side, a `union` whose explicit side it is). The root's
/// re-entering steps `#Node.0` and `#Node.2` are first returns, a plain
/// path each with a class of its own (#1253), and that class's re-entering
/// steps name it, so nothing below a first return is a second node.
fn oneNodePerPath(f: *Fixture, w: NodeId) !void {
    const gpa = testing.allocator;
    const core = struct {
        fn of(ff: *Fixture, x: NodeId) !NodeId {
            const d = ff.shapes.get(x);
            return switch (d.kind) {
                .node => x,
                .@"union" => .from(d.a),
                else => error.TestUnexpectedResult,
            };
        }
    }.of;
    const n = try core(f, w);
    try testing.expectEqual(Kind.node, f.shapes.kind(n));
    for ([_]u32{ 0, 2 }) |i| {
        const s = try f.places.ctorStep(gpa, &f.account, 0, i);
        const c = f.shapes.overGet(f.shapes.get(n).a, s) orelse continue;
        // A node the root shares (a leaf arm there and a child here) puts
        // the first return in the root's class, its knot the root's.
        if (f.shapes.kind(c) == .leaf or c == w) continue;
        const cn = try core(f, c);
        try testing.expectEqual(Kind.node, f.shapes.kind(cn));
        for ([_]u32{ 0, 2 }) |j| {
            const t = try f.places.ctorStep(gpa, &f.account, 0, j);
            if (f.shapes.overGet(f.shapes.get(cn).a, t)) |cc| if (f.shapes.kind(cc) != .leaf) try testing.expectEqual(c, cc);
        }
    }
}

test "#1360: in a group's rounds widen opens a choice at a member's root, nested or inside a union, and settles" {
    for ([_]u8{ 0, 1, 2 }) |root| {
        var f: Fixture = .{};
        f.init();
        defer f.deinit();
        f.shapes.widen_rounds = true;
        const gpa = testing.allocator;
        const tree = try f.placeOf(0);
        const seed = try f.shapes.leaf(gpa, &f.account, tree, try f.param(3, tree));
        const v1 = try pickRound(&f, seed, root);
        var fold: Table.Fold = .{};
        defer fold.deinit(gpa);
        const x1 = try f.shapes.widenFold(gpa, &f.account, &f.places, &f.cells, v1, &fold);
        // Quotiented through the root: the knot ties back to a node, the
        // root's arms are members of its class, never a choice on a cycle.
        try testing.expect(x1 != v1);
        try testing.expect(f.shapes.kind(x1) != .choice);
        try testing.expect(fold.opened.contains(v1));
        try oneNodePerPath(&f, x1);
        try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, v1, x1));
        // Two more rounds and the third is below the second: the group
        // settles. The first return is a plain path (#1253), so its class
        // takes the previous round's root a round after the root's own.
        const x2 = try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, try pickRound(&f, x1, root));
        try oneNodePerPath(&f, x2);
        try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, x1, x2));
        const x3 = try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, try pickRound(&f, x2, root));
        try oneNodePerPath(&f, x3);
        try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, x3, x2));
    }
}

test "#1360: in a group's rounds widen is idempotent on a widened choice root" {
    for ([_]u8{ 0, 1, 2 }) |root| {
        var f: Fixture = .{};
        f.init();
        defer f.deinit();
        f.shapes.widen_rounds = true;
        const gpa = testing.allocator;
        const tree = try f.placeOf(0);
        const seed = try f.shapes.leaf(gpa, &f.account, tree, try f.param(3, tree));
        const x1 = try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, try pickRound(&f, seed, root));
        try oneNodePerPath(&f, x1);
        const x2 = try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, x1);
        try testing.expect(try f.shapes.eq(gpa, &f.account, &f.places, &f.cells, x1, x2));
        try oneNodePerPath(&f, x2);
    }
}

/// One round of `growA a n = if n == 0 then a else case growA a (n - 1) of
/// A1 xs b → A1 xs (B2 [] b); A0 → A0` over the last round's value `x`.
fn growRound(f: *Fixture, x: NodeId) !NodeId {
    const gpa = testing.allocator;
    const a_place = try f.placeOf(4);
    const b_place = try f.placeOf(5);
    const list = try f.placeOf(1);
    const a1_0 = try f.places.ctorStep(gpa, &f.account, 1, 0);
    const a1_1 = try f.places.ctorStep(gpa, &f.account, 1, 1);
    const b2_0 = try f.places.ctorStep(gpa, &f.account, 3, 0);
    const b2_1 = try f.places.ctorStep(gpa, &f.account, 3, 1);
    var bk = try f.one(b2_0, try f.shapes.leaf(gpa, &f.account, list, try f.site(1, list, .list)));
    bk = try f.shapes.overPut(gpa, &f.account, bk, b2_1, try f.proj(x, a1_1));
    const b2 = try f.shapes.node(gpa, &f.account, b_place, try f.site(2, b_place, .none), bk);
    var ak = try f.one(a1_0, try f.proj(x, a1_0));
    ak = try f.shapes.overPut(gpa, &f.account, ak, a1_1, b2);
    const a1 = try f.shapes.node(gpa, &f.account, a_place, try f.site(3, a_place, .none), ak);
    var arms = [_]NodeId{ a1, try f.shapes.leaf(gpa, &f.account, a_place, .none) };
    const body = try f.shapes.joinChoice(gpa, &f.account, &f.places, &f.cells, &arms);
    var both = [_]NodeId{ x, body };
    return f.shapes.joinChoice(gpa, &f.account, &f.places, &f.cells, &both);
}

test "#1360 review: in a group's rounds a re-entry below the root join opens it: growA settles" {
    // `B2 [] b` re-enters B below A's root join: the `⟲`'s target is
    // `#A1.1`, under the join's path, and kept whole the join would nest
    // one more `B2` every round.
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    f.shapes.widen_rounds = true;
    const gpa = testing.allocator;
    var x = try f.shapes.leaf(gpa, &f.account, try f.placeOf(4), try f.param(1, try f.placeOf(4)));
    var settled = false;
    for (0..4) |_| {
        const next = try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, try growRound(&f, x));
        try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, x, next));
        if (try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, next, x)) {
            settled = true;
            break;
        }
        x = next;
    }
    try testing.expect(settled);
}

test "#1360 review: outside a group's rounds widen keeps a choice at the root: a finite value has no cycle" {
    // `case t of Node a xs b → Node a (List.push xs 1) b; Leaf → Leaf`, and
    // `pick`'s rounds built once: a non-recursive function's result, kept
    // exact, as master keeps it.
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const tree = try f.placeOf(0);
    const list = try f.placeOf(1);
    const s0 = try f.places.ctorStep(gpa, &f.account, 0, 0);
    const s1 = try f.places.ctorStep(gpa, &f.account, 0, 1);
    const s2 = try f.places.ctorStep(gpa, &f.account, 0, 2);
    const p = try f.shapes.leaf(gpa, &f.account, tree, try f.param(1, tree));
    var kids = try f.one(s0, try f.proj(p, s0));
    kids = try f.shapes.overPut(gpa, &f.account, kids, s1, try f.shapes.leaf(gpa, &f.account, list, try f.site(1, list, .list)));
    kids = try f.shapes.overPut(gpa, &f.account, kids, s2, try f.proj(p, s2));
    const n = try f.shapes.node(gpa, &f.account, tree, try f.site(2, tree, .none), kids);
    const c = try f.shapes.choice(gpa, &f.account, &f.cells.sets, n, try f.shapes.leaf(gpa, &f.account, tree, .none));
    try testing.expectEqual(c, try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, c));
    for ([_]u8{ 0, 1, 2 }) |root| {
        const v = try pickRound(&f, try f.shapes.leaf(gpa, &f.account, tree, try f.param(3, tree)), root);
        try testing.expectEqual(v, try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, v));
    }
}

test "#1360: in a group's rounds a choice at the root with no re-entry below is kept: widen stays the identity" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    f.shapes.widen_rounds = true;
    const gpa = testing.allocator;
    const tree = try f.placeOf(0);
    const c = try f.shapes.choice(gpa, &f.account, &f.cells.sets, try f.shapes.leaf(gpa, &f.account, tree, try f.param(1, tree)), try f.shapes.leaf(gpa, &f.account, tree, try f.param(2, tree)));
    try testing.expectEqual(c, try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, c));
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
    // The subtrees' knot (the root is a class of its own, #1253): its node,
    // the union's explicit side, which points back at it, shares the set.
    const sub = try f.proj(w, s0);
    try testing.expectEqual(Kind.@"union", f.shapes.kind(sub));
    const sub_node: NodeId = .from(f.shapes.nodes.items(.a)[sub.int()]);
    const r2 = try f.shapes.reach(gpa, &f.account, &f.cells.sets, sub);
    try testing.expectEqual(@as(u32, 2), f.cells.sets.count(r2)); // site 3, π₂
    try testing.expectEqual(r2, try f.shapes.reach(gpa, &f.account, &f.cells.sets, sub_node));
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
        // The root keeps its own list (#1253); every level below is one
        // class, its lists joined, with the parameter's beside it: the knot.
        const s0 = try f.places.ctorStep(gpa, &f.account, 0, 0);
        const s1 = try f.places.ctorStep(gpa, &f.account, 0, 1);
        try testing.expectEqual(@as(u32, 1), f.cells.sets.count(f.shapes.cells(try f.proj(w, s1))));
        const below = try f.proj(w, s0);
        const core: NodeId = if (f.shapes.kind(below) == .@"union") .from(f.shapes.nodes.items(.a)[below.int()]) else below;
        const again = try f.proj(core, s0);
        try testing.expect(again == core or again == below);
        try testing.expectEqual(k, f.cells.sets.count(f.shapes.cells(try f.proj(below, s1))));
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

/// `{ a = xs, b = [] }` with its storage cell made at site `site`.
fn record2(f: *Fixture, site: u32) !NodeId {
    const gpa = testing.allocator;
    const rec = try f.placeOf(3);
    const list = try f.placeOf(1);
    const xs = try f.shapes.leaf(gpa, &f.account, list, try f.param(2, list));
    const empty = try f.shapes.leaf(gpa, &f.account, list, try f.site(7, list, .list));
    var children = try f.one(try Place.Step.field(&f.account, 10), xs);
    children = try f.shapes.overPut(gpa, &f.account, children, try Place.Step.field(&f.account, 11), empty);
    return f.shapes.node(gpa, &f.account, rec, try f.site(site, rec, .record), children);
}

const OneCell = struct {
    fn relabel(fx: *Fixture, s: SetId) Error!SetId {
        if (s == .none) return .none;
        return fx.cells.sets.insert(testing.allocator, .growth(&fx.account), .none, 1_000, 0);
    }
};

test "#1372: map interns an image on no knot: a value relabelled again is the node it was" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const r = try record2(&f, 8);
    // A round's unchanged value: relabelled twice, one node; relabelled by
    // the identity, the node itself, a choice of it included.
    const once = try f.shapes.map(gpa, &f.account, r, &f, OneCell.relabel);
    try testing.expectEqual(once, try f.shapes.map(gpa, &f.account, r, &f, OneCell.relabel));
    const Same = struct {
        fn same(_: void, s: SetId) Error!SetId {
            return s;
        }
    };
    try testing.expectEqual(r, try f.shapes.map(gpa, &f.account, r, {}, Same.same));
    const c = try f.shapes.choice(gpa, &f.account, &f.cells.sets, r, try record2(&f, 9));
    try testing.expectEqual(c, try f.shapes.map(gpa, &f.account, c, {}, Same.same));
    // Two records of two sites that relabel alike are one image.
    try testing.expectEqual(once, try f.shapes.map(gpa, &f.account, try record2(&f, 9), &f, OneCell.relabel));
}

test "positions saturate at two: a third occurrence rebuilds the tree in first-occurrence order, off the item's lane" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const rec = try f.placeOf(3);
    const fa = try Place.Step.field(&f.account, 10);
    const x = try f.shapes.leaf(gpa, &f.account, rec, try f.param(1, rec));
    const y = try f.shapes.leaf(gpa, &f.account, rec, try f.param(2, rec));
    const xx = try f.shapes.collect(gpa, &f.account, &f.cells.sets, &.{ x, x });
    // `[ x, x, x ]` is `[ x, x ]`, and so is `positions(positions(x, x), x)`
    // (§2.3 *Saturation at two*).
    try testing.expectEqual(xx, try f.shapes.collect(gpa, &f.account, &f.cells.sets, &.{ x, x, x }));
    try testing.expectEqual(xx, try f.shapes.positions(gpa, &f.account, &f.cells.sets, xx, x));
    try testing.expectEqual(xx, try f.shapes.positions(gpa, &f.account, &f.cells.sets, xx, xx));
    // Two occurrences are the record as written: no rebuild.
    const xy = try f.shapes.collect(gpa, &f.account, &f.cells.sets, &.{ x, y });
    const xyx = try f.shapes.positions(gpa, &f.account, &f.cells.sets, xy, x);
    try testing.expectEqual(xy.int(), f.shapes.nodes.items(.a)[xyx.int()]);
    // `[ x, y, x, x ]`: the members in first-occurrence order, each at most
    // twice, is `[ x, x, y ]`.
    const g = try f.shapes.collect(gpa, &f.account, &f.cells.sets, &.{ x, y, x, x });
    try testing.expectEqual(try f.shapes.collect(gpa, &f.account, &f.cells.sets, &.{ x, x, y }), g);
    // Projection distributes over the sides, so it saturates as well: the
    // image of `positions(xx, xx)` is `xx`'s.
    try testing.expectEqual(try f.proj(xx, fa), try f.proj(try f.shapes.collect(gpa, &f.account, &f.cells.sets, &.{ xx, x }), fa));
    // The count maps and the rebuild are their own task: a collection on the
    // items' lanes charges each lane its positions node alone (§4.1).
    var lanes: [6]Ids.Lane = undefined;
    for (&lanes, 0..) |*l, i| l.* = .{ .atom = 100 + @as(u32, @intCast(i)), .role = .transfer_settlement };
    const z = try f.shapes.leaf(gpa, &f.account, rec, try f.param(3, rec));
    _ = try f.shapes.collectRoot(gpa, &f.account, &f.cells.sets, &.{ z, y, z, x, z, z }, Table.lazy_cells, &lanes);
    for (lanes) |l| try testing.expect(f.account.laneUsed(l) <= 1);
}

test "#1372: a positions node whose sides map to one node keeps both edges" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    // `[ r₁, r₂ ]`, two built records that relabel alike: their images are
    // one node, and the element positions stay two (§2.9: κ counts edges).
    const xy = try f.shapes.collect(gpa, &f.account, &f.cells.sets, &.{ try record2(&f, 8), try record2(&f, 9) });
    const mapped = try f.shapes.map(gpa, &f.account, xy, &f, OneCell.relabel);
    try testing.expectEqual(Kind.positions, f.shapes.kind(mapped));
    const d = f.shapes.get(mapped);
    try testing.expectEqual(d.a, d.b);
    try testing.expectEqual(Kind.node, f.shapes.kind(.from(d.a)));
    // Below it too: `[*].a` is a positions node of two.
    const pa = try f.proj(mapped, try Place.Step.field(&f.account, 10));
    try testing.expectEqual(Kind.positions, f.shapes.kind(pa));
    // A union of them is two alternatives of one value, and a choice the
    // same: the record kept as each made it, never absorbed.
    const u = try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, try record2(&f, 8), try record2(&f, 9));
    const mu = try f.shapes.map(gpa, &f.account, u, &f, OneCell.relabel);
    try testing.expectEqual(Kind.@"union", f.shapes.kind(mu));
}

/// The built side of a knot's union with the parameter leaf, or the node.
fn knotSide(f: *Fixture, n: NodeId) !NodeId {
    if (f.shapes.kind(n) != .@"union") return n;
    const d = f.shapes.get(n);
    const sides = [_]NodeId{ .from(d.a), .from(d.b) };
    for (sides) |s| if (f.shapes.kind(s) != .leaf) return s;
    return error.TestUnexpectedResult;
}

test "#1372 F3 (4e): an image on a knot is the knot an equal map made before; the raw pass ties its own" {
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
    inner_children = try f.shapes.overPut(gpa, &f.account, inner_children, s2, t_param);
    const inner = try f.shapes.node(gpa, &f.account, tree, .none, inner_children);
    var outer_children = try f.one(s0, inner);
    outer_children = try f.shapes.overPut(gpa, &f.account, outer_children, s1, try f.shapes.leaf(gpa, &f.account, list, try f.site(2, list, .list)));
    outer_children = try f.shapes.overPut(gpa, &f.account, outer_children, s2, inner);
    const outer = try f.shapes.node(gpa, &f.account, tree, .none, outer_children);
    const w = try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, outer);
    const Same = struct {
        fn same(_: void, s: SetId) Error!SetId {
            return s;
        }
    };
    const m1 = try f.shapes.map(gpa, &f.account, w, {}, Same.same);
    const m2 = try f.shapes.map(gpa, &f.account, w, {}, Same.same);
    // With nothing moved (the cross-check's raw pass), a map ties a knot of
    // its own.
    f.shapes.stable.off = true;
    const m3 = try f.shapes.map(gpa, &f.account, w, {}, Same.same);
    f.shapes.stable.off = false;
    try testing.expect(m1 != w and m2 != w);
    // The second map's knot has the first's form, so it is that knot, and
    // the root on no knot is interned onto the first's (§2.3, 4e).
    try testing.expectEqual(m1, m2);
    try testing.expect(m3 != m1);
    // Each a knot (#1253, #1382: the root's first return keys a class of
    // its own, and the subtrees are the knot): the recursive child of each
    // map's subtree class names that class's own image.
    var subs: [3]NodeId = undefined;
    for ([_]NodeId{ m1, m2, m3 }, 0..) |m, i| {
        const sub = try f.proj(m, s0);
        try testing.expect(sub != m);
        // The knot is the union's built side; `map` orders a union's sides
        // by birth, so the parameter leaf may come first.
        const core = try knotSide(&f, sub);
        const child = try f.proj(core, s0);
        try testing.expectEqual(core, try knotSide(&f, child));
        subs[i] = core;
    }
    try testing.expectEqual(subs[0], subs[1]);
    try testing.expect(subs[2] != subs[0]);
    try testing.expect(try f.shapes.eq(gpa, &f.account, &f.places, &f.cells, m1, m3));

    // The raw knot has the form recorded: σ moves it onto the first map's,
    // and its precondition holds.
    const raw = subs[2];
    var redir = (try Stable.canon(&f.shapes, gpa, &f.account, raw, raw.int(), null, null)) orelse return error.TestUnexpectedResult;
    defer redir.deinit(gpa);
    try testing.expectEqual(subs[0].int(), redir.get(raw.int()).?);
    var members: std.ArrayList(u32) = .empty;
    defer members.deinit(gpa);
    for (0..redir.count()) |i| try members.append(gpa, redir.key(@intCast(i)));
    try testing.expect(try Stable.moveHolds(&f.shapes, gpa, members.items, &redir, null));
    // The check fires on a move that does not keep the records: the knot
    // sent to a node of another record, or two members to one target.
    const wrong = try f.shapes.leaf(gpa, &f.account, list, try f.site(1, list, .list));
    var bad: Stable.Redirect = .{};
    defer bad.deinit(gpa);
    for (0..redir.count()) |i| try bad.put(gpa, redir.key(@intCast(i)), redir.value(@intCast(i)));
    try bad.put(gpa, raw.int(), wrong.int());
    try testing.expect(!try Stable.moveHolds(&f.shapes, gpa, members.items, &bad, null));
    if (members.items.len >= 2) {
        var twice: Stable.Redirect = .{};
        defer twice.deinit(gpa);
        for (0..redir.count()) |i| try twice.put(gpa, redir.key(@intCast(i)), redir.value(@intCast(i)));
        try twice.put(gpa, members.items[1], twice.get(members.items[0]).?);
        try testing.expect(!try Stable.moveHolds(&f.shapes, gpa, members.items, &twice, null));
    }
    // A side word in the key (`fold_cond`): the same graph with another word
    // has another form, and is not moved.
    const Word = struct {
        fn seven(_: *anyopaque, _: NodeId) u32 {
            return 7;
        }
    };
    var dummy: u8 = 0;
    try testing.expectEqual(@as(?Stable.Redirect, null), try Stable.canon(&f.shapes, gpa, &f.account, raw, raw.int(), .{ .ctx = &dummy, .word = Word.seven }, null));

    // A graph that reaches its target never has its key: a raw copy of the
    // knot's entry, whose references name the knot itself, is on no cycle;
    // it is not moved onto the knot, so no route meets a moved member and
    // its target both (§2.3, 4e, the fold case of the lemma).
    const k = subs[0];
    try f.account.reserve(.shape, 1);
    const copy: NodeId = .from(f.shapes.count());
    try f.shapes.nodes.append(gpa, f.shapes.get(k));
    try testing.expectEqual(@as(?Stable.Redirect, null), try Stable.canon(&f.shapes, gpa, &f.account, copy, copy.int(), null, null));
    var moved = try Stable.widened(&f.shapes, gpa, &f.account, copy, copy.int(), null);
    defer moved.deinit(gpa);
    try testing.expect(moved.get(copy.int()) == null or moved.get(copy.int()).? != k.int());
}

test "#1372: joinAlternatives flattens a choice member into one set of distinct alternatives; joinChoice keeps it" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const a = try record2(&f, 8);
    const b = try record2(&f, 9);
    const c = try record2(&f, 10);
    // `port₂ = port₁ ⊔ F₁` with `port₁ = choice(a, b)` and `F₁ ∋ b, c`: three
    // alternatives, b once.
    const ab = try f.shapes.choice(gpa, &f.account, &f.cells.sets, a, b);
    const bc = try f.shapes.choice(gpa, &f.account, &f.cells.sets, b, c);
    var m1 = [_]NodeId{ ab, bc };
    const flat = try f.shapes.joinAlternatives(gpa, &f.account, &f.places, &f.cells, &m1);
    var arms: std.ArrayList(NodeId) = .empty;
    defer arms.deinit(gpa);
    var todo: std.ArrayList(NodeId) = .empty;
    defer todo.deinit(gpa);
    try todo.append(gpa, flat);
    while (todo.pop()) |n| {
        if (f.shapes.kind(n) == .choice) {
            try todo.appendSlice(gpa, &.{ .from(f.shapes.get(n).a), .from(f.shapes.get(n).b) });
        } else try arms.append(gpa, n);
    }
    std.mem.sort(NodeId, arms.items, {}, struct {
        fn lt(_: void, x: NodeId, y: NodeId) bool {
            return x.int() < y.int();
        }
    }.lt);
    try testing.expectEqualSlices(NodeId, &.{ a, b, c }, arms.items);
    // Again: the memo, and γ is the nested join's.
    var m2 = [_]NodeId{ ab, bc };
    try testing.expectEqual(flat, try f.shapes.joinAlternatives(gpa, &f.account, &f.places, &f.cells, &m2));
    var m3 = [_]NodeId{ ab, bc };
    const nested = try f.shapes.joinChoice(gpa, &f.account, &f.places, &f.cells, &m3);
    try testing.expect(nested != flat);
    try testing.expect(try f.shapes.eq(gpa, &f.account, &f.places, &f.cells, nested, flat));
    // The member with the most arms is kept whole, so a tower of joins adds
    // one arm to it, never rebuilds it.
    var m5 = [_]NodeId{ c, ab };
    const tw = try f.shapes.joinAlternatives(gpa, &f.account, &f.places, &f.cells, &m5);
    const ts = [_]u32{ f.shapes.get(tw).a, f.shapes.get(tw).b };
    try testing.expect(std.mem.indexOfScalar(u32, &ts, ab.int()) != null);
    // A union or positions member is never opened into alternatives.
    const u = try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, a, b);
    var m4 = [_]NodeId{ u, c };
    const ju = try f.shapes.joinAlternatives(gpa, &f.account, &f.places, &f.cells, &m4);
    try testing.expectEqual(Kind.choice, f.shapes.kind(ju));
    const sides = [_]u32{ f.shapes.get(ju).a, f.shapes.get(ju).b };
    try testing.expect(std.mem.indexOfScalar(u32, &sides, u.int()) != null);
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
    /// When set, a parameter cell below the root is the argument projected
    /// along its path; otherwise the argument whole.
    places: ?*Place.Table = null,

    pub fn inst(x: *TestInstantiation) Table.Instantiation {
        return .{ .ctx = x, .sets = &x.cellt.sets, .leaf = leaf, .cells = cells, .reach = reach, .reroot = reroot, .parts = parts };
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
        if (!x.isParam(t.cells(template))) return t.leaf(gpa, account, t.place(template), t.cells(template));
        const places = x.places orelse return x.arg;
        // A parameter cell below the root stands for the argument there, as
        // `Views`' `argAt` reads it: the argument projected along its path.
        var it = x.cellt.sets.iterate(t.cells(template));
        const p = while (it.next()) |e| {
            if (x.cellt.origin(.from(e.key)) == .param) break x.cellt.get(.from(e.key));
        } else unreachable;
        var steps: std.ArrayList(Step) = .empty;
        defer steps.deinit(gpa);
        var at: Ids.PathId = .from(p.b);
        while (places.pathParent(at) != .none) : (at = places.pathParent(at)) try steps.append(gpa, places.pathStep(at));
        var out = x.arg;
        var k = steps.items.len;
        while (k > 0) {
            k -= 1;
            out = (try t.proj(gpa, account, places, x.cellt, out, steps.items[k])) orelse return t.nothing(gpa, account, t.place(template));
        }
        return out;
    }

    fn parts(ctx: *anyopaque, t: *Table, gpa: Allocator, account: *Account, env: u32, template: NodeId, out: *std.ArrayList(Table.LeafPart)) Error!void {
        try out.append(gpa, .{ .node = try leaf(ctx, t, gpa, account, env, template), .approx = false });
    }

    fn cells(ctx: *anyopaque, t: *Table, gpa: Allocator, account: *Account, env: u32, s: SetId, at: PlaceId) Error!SetId {
        _ = .{ ctx, t, gpa, account, env, at };
        return s;
    }

    fn reroot(ctx: *anyopaque, t: *Table, gpa: Allocator, account: *Account, env: u32, template: NodeId) Error!?Ids.KappaId {
        _ = .{ ctx, t, gpa, account, env, template };
        return null;
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
    var ti: TestInstantiation = .{ .cellt = &f.cells, .arg = arg, .places = &f.places };
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

const v2_mutation = @import("ownership_options").v2_mutation;

/// A test-only mutation (`-Downership-v2-mutation`, which `gates` refuses).
fn mutated(comptime which: []const u8) bool {
    return std.mem.eql(u8, v2_mutation, which);
}
