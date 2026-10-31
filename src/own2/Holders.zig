//! L8: the holder index (`docs/design/ownership-v2.md` §2.8 *The holder
//! index*, #1214): condition 5 of every demand of a frame, answered offline
//! by one in-order sweep, after the walk has seen every holder, use and
//! demand.
//!
//! **Pairs from each holder's life.** A demand on base cell `c` (its
//! *target*, with the demand's depth) reads the holders of `c`'s candidates:
//! `c` and its trie ancestors up to a `◆` barrier, its canonical cell's,
//! its descendants for a deep demand, and the cells its refinement and
//! cycle-anchor keys name.
//! Each holder walks its value's cells once, looks each one up by cell and
//! by key, and pairs with a target only when one of the target's demands
//! lies in `(start, end]`, where it is registered. A `⊤` holder pairs only
//! through a cell it holds that may be `c` (§2.8's inversion).
//!
//! **Entries.** A pair's group is `(target, candidate)`. A binding's uses
//! cover its holds (`cover`: a use at `q` covers the holds on `q`'s route and
//! below `q`, a `call` use only where its callee reads the rest), each use
//! with its best exact and best covered path in the canonical order. A light
//! pair inserts one entry per use, active on `(start, use point)`; a heavy
//! pair asks its few demands directly. A pending operand is one entry active
//! on `(start, end)`. Each group keeps a segment tree over its entries'
//! `rank₂`, two minima a node (exact, any), each with the best entry of
//! another split; the sweep activates and retires entries in point order and
//! reads a suffix (`rank₂(u) > rank₂(p)`) or, for pending operands, a prefix.
//! Reliance (`under`, `under_κ`, another position of the base's split) is a
//! count of registered holders on `(start, end]`.
//!
//! Under runtime safety a naive scan answers frames of at most 8 holders
//! again and must agree; `-Downership-full-cross-check` checks every frame.
//!
//! Obligations kept here: O12's (a holder's later use is this frame's own
//! use the index recorded) and I-κ's use (an answer that rests on a split
//! names it, for the demand's κ).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Cell = @import("Cell.zig");
const Shape = @import("Shape.zig");
const Cond = @import("Cond.zig");
const Summary = @import("Summary.zig");
const Liveness = @import("Liveness.zig");
const Regions = @import("Regions.zig");
const Exits = @import("Exits.zig");

pub const NodeId = Ids.NodeId;
pub const CellId = Ids.CellId;
pub const SetId = Ids.SetId;
pub const PathId = Ids.PathId;
pub const CondId = Ids.CondId;
pub const UseId = Ids.UseId;
pub const SplitId = Ids.SplitId;
pub const Env = Summary.Env;
pub const Error = Ids.ChargeError;
pub const Step = Shape.Step;
pub const none: u32 = Ids.none_int;

/// A value interpretation (§2.9): its shape root and its own κ snapshot.
pub const Value = struct {
    node: NodeId = .none,
    kappa: Cond.Kappas = .none,
};

/// One demand the walk met (§2.8).
pub const Demand = struct {
    point: u32,
    kind: Facts.DemandKind,
    base: Value,
    /// The instruction the base was read from, for its text.
    base_inst: u32,
    /// The local the base reads, at `base_path`, or `none` for a computed
    /// base: what tells `later-use` from `alias`.
    base_local: u32 = none,
    base_path: PathId = .none,
    /// The main token of the demand's instruction: its position.
    token: u32,
    /// A writer call's callee instruction, for its name; `none` otherwise.
    callee_inst: u32 = none,
    /// A writer call's write path below the base, and its callee's `xreq` (§2.11).
    write_path: PathId = .none,
    relies: CondId = Cond.yes,
    /// The other operands of the operation, a run of `Frame.operands`.
    operands: Ids.Range = .empty,
};

/// `other_paths`: the operand is the rest of the written argument itself, the
/// paths a call's class does not write (`TransferBeside.otherPaths`), not another
/// operand of the operation: what the message says it reaches (#1380).
pub const Operand = struct { value: Value, inst: u32, other_paths: bool = false };

pub const HolderKind = enum(u8) { binding, pending };

/// A holder (§2.8): a binding of a local, live from its binding to its last
/// use, or a computed value evaluated before its consumer, live in between.
pub const Holder = struct {
    kind: HolderKind,
    /// `binding`: the local; `pending`: the instruction.
    who: u32,
    value: Value,
    start: u32,
    end: u32,
    /// `binding`: the local's root path (its place's `ε`), what the use
    /// index keys its uses under.
    root: PathId,
    token: u32,
    /// `binding` of a list pattern's position (§2.13.3): which.
    taken: Taken = .{},
};

/// A pattern variable bound at position `pos` of split `split`, with the
/// explicit cells at the container's `[*]` (a concrete container's
/// elements) that every position holds: two positions of one split hold
/// one of them only if the split's κ fails, as `elem`s of two sides do.
pub const Taken = struct { split: SplitId = .none, pos: u32 = none, explicit: SetId = .none };

pub const Escape = struct { node: NodeId, point: u32 };

pub const Frame = struct {
    demands: []const Demand,
    operands: []const Operand,
    holders: []const Holder,
    escapes: []const Escape,
    index: *const Liveness.Index,
    regions: *const Regions.Tree,
    /// Per local, its binding's index in `holders`, or `none`.
    bindings: []const u32 = &.{},
};

/// The first failing holder of a demand in the canonical order (§2.8
/// *Verdicts*): exact first; then the earliest use (a pending operand by its
/// start), the earlier binding, the hold path, the holder's index, the
/// use's atom.
pub const Win = struct {
    holder: u32,
    point: u32,
    start: u32,
    /// Under the holder's root; `none` for a pending operand.
    path: PathId = .none,
    use: UseId = .none,
    atom: u32 = none,
    exact: bool = false,
    /// Held there only at an unmaterialised summary position: §2.8
    /// condition 5's `element`, when no exact hold wins.
    element: bool = false,
};

/// Condition 5's answer for one demand.
pub const Answer = struct {
    win: ?Win = null,
    /// A reliance on `under_κ`: the answer is `lost`.
    lost: bool = false,
    /// The splits it relies on, sorted: a run of `answer`'s `splits`.
    splits: Ids.Range = .empty,
};

/// Answer condition 5 for every demand `wanted` names (§2.8).
pub fn answer(env: Env, frame: Frame, wanted: []const bool, out: []Answer, splits: *std.ArrayList(SplitId)) Error!void {
    var ix: Index = .{ .gpa = env.gpa, .env = env, .frame = frame };
    defer ix.deinit();
    // All of it is a general task (§4.1): its products are the families
    // §4.1 names, and a product is never a lane's.
    const task = try env.account().enter(env.gpa, null);
    defer env.account().leave(task);
    try ix.buildTargets(wanted);
    try ix.buildPairs();
    try ix.buildTrees();
    try ix.sweep(out, splits);
    if (std.debug.runtime_safety and (frame.holders.len <= cross_check_holders or Cond.full_cross_check)) try ix.crossCheck(wanted, out, splits.items);
}

/// What a holder's value `n` gives at one path for candidate `x` of target
/// `c` (§2.8 step 3, `Index.expand`): the hold bits, and the states with
/// children that reach `x` into `kids`. One frame-free read of the
/// closure, for a caller with no frame (the knot tests of `Calls`).
pub fn closureOf(env: Env, n: NodeId, x: CellId, c: CellId, kids: *std.ArrayList(NodeId)) Error!struct { any: bool, plain: bool, alt: bool } {
    var ix: Index = .{ .gpa = env.gpa, .env = env, .frame = undefined };
    defer ix.deinit();
    const clo = ix.clos.items[try ix.closure(n, x, c)];
    for (ix.pool.items[clo.start..][0..clo.len]) |s| try kids.append(env.gpa, s.node);
    return .{ .any = clo.bits.any, .plain = clo.bits.plain, .alt = clo.bits.alt };
}

const cross_check_holders = 8;
/// A counter slot of an own-split chain (`Sib`), apart from group ids.
const sib_tag: u32 = 1 << 31;
/// A node with more children keeps a cell-to-children index (`kidsOf`).
const wide = 16;

const Key = [4]u32;

const Target = struct { c: CellId, deep: bool, occ: Ids.Range = .empty, groups: Ids.Range = .empty, sibs: Ids.Range = .empty };
/// A split some holder's refinements took at canonical position `key`.
const KSplit = struct {
    key: Key,
    split: u32,

    fn less(_: void, a: KSplit, b: KSplit) bool {
        const o = std.mem.order(u32, &a.key, &b.key);
        return o == .lt or (o == .eq and a.split < b.split);
    }

    fn below(k: Key, e: KSplit) bool {
        return std.mem.order(u32, &e.key, &k) == .lt;
    }
};
/// A target's own-split refinement chain: one reliance on `split` while a
/// registered holder holds a member of key `kid` other than `self`.
const Sib = struct { target: u32, kid: u32, self: CellId, split: SplitId };
/// `maybe`: the base cell is only possibly in the base (its set bit).
const Occ = struct { target: u32, point: u32, demand: u32, forced: bool, maybe: bool };
const Group = struct { target: u32, x: CellId, how: Cell.Alias, ord: u32 = none, pend: u32 = none };
/// One entry (§2.8): a use of a holder (or a pending operand) in a group,
/// keyed by its use point, its holder's start, its two covered paths.
const Entry = struct {
    tree: u32,
    rank2: u32,
    point: u32,
    start: u32,
    holder: u32,
    atom: u32,
    use: UseId,
    exact_path: PathId,
    any_path: PathId,
    exact_ok: bool,
    element: bool,
    split: u32,
    /// Where it retires: its use point, or a pending operand's end.
    until: u32,
};
const Tree = struct { first: u32, n: u32, off: u32, cap: u32 };
const Event = struct { point: u32, phase: u8, kind: Kind, ref: u32 };
const Kind = enum(u8) { retire, demand, enter, inc, dec };
const Block = struct { lo: u32, hi: u32, exact: PathId, any: PathId, element: bool = false };

const Index = struct {
    gpa: Allocator,
    env: Env,
    frame: Frame,
    targets: std.ArrayList(Target) = .empty,
    target_of: Ids.FixedDict(2) = .{},
    occ: std.ArrayList(Occ) = .empty,
    /// Per demand: its occurrences (`docc`'s run) and whether it has several cells.
    dem_occ: []Ids.Range = &.{},
    docc: std.ArrayList(u32) = .empty,
    /// Every key a target reads → its id; per id, its targets.
    keys: Ids.FixedDict(4) = .{},
    key_targets: std.ArrayList(Ids.Range) = .empty,
    kt: std.ArrayList(u32) = .empty,
    /// A holder cell's key ids, memoised per cell.
    cell_keys: Ids.FixedDict(1) = .{},
    ck: std.ArrayList(u32) = .empty,
    ck_runs: std.ArrayList(Ids.Range) = .empty,
    groups: std.ArrayList(Group) = .empty,
    group_of: Ids.FixedDict(2) = .{},
    tg: std.ArrayList(u32) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    tree_of: Ids.FixedDict(4) = .{},
    trees: std.ArrayList(Tree) = .empty,
    nodes: std.ArrayList([4]u32) = .empty,
    /// Live entry per leaf slot: `none` when retired.
    slots: Ids.FixedDict(3) = .{},
    counts: std.ArrayList(i32) = .empty,
    events: std.ArrayList(Event) = .empty,
    /// Heavy pairs' answers per occurrence: exact, any.
    acc: std.ArrayList([2]?Win) = .empty,
    /// Every demand point, sorted: a holder's life is tested against it.
    points: std.ArrayList(u32) = .empty,
    ksplits: std.ArrayList(KSplit) = .empty,
    /// By target; `sib_keys` the same by key id.
    sibs: std.ArrayList(Sib) = .empty,
    sib_keys: std.ArrayList(Sib) = .empty,
    steps: std.ArrayList(Step) = .empty,
    inv: Ids.FixedDict(1) = .{},
    inv_items: std.ArrayList([3]u32) = .empty,
    inv_runs: std.ArrayList(Ids.Range) = .empty,
    /// `expand`'s memo: per `(state, x, c)` its closure at one path.
    /// A memo, never iterated: a hash map keeps a lookup O(1) when a deep
    /// holder makes many closures (§4.1: constant work a record).
    clo_of: std.AutoHashMapUnmanaged(Key, u32) = .empty,
    clos: std.ArrayList(Clo) = .empty,
    pool: std.ArrayList(St) = .empty,
    desc: Descent = .{},
    exits: Exits.Memo = .{},
    kid_cache: std.ArrayList([2]u32) = .empty,

    fn deinit(ix: *Index) void {
        const info = @typeInfo(Index).@"struct";
        inline for (info.field_names, info.field_types) |name, T| switch (@typeInfo(T)) {
            .@"struct" => if (@hasDecl(T, "deinit")) @field(ix, name).deinit(ix.gpa),
            .pointer => ix.gpa.free(@field(ix, name)),
            else => {},
        };
    }

    fn rec(ix: *Index, n: u32) Error!void {
        try ix.env.charge.reserve(ix.gpa, .inspection, n);
    }

    fn reach(ix: *Index, n: NodeId) Error!SetId {
        return ix.env.shapes.reach(ix.gpa, ix.env.account(), &ix.env.cells.sets, n);
    }

    fn rank2(ix: *const Index, p: u32) u32 {
        return ix.frame.regions.rank2(p);
    }

    // ---- candidates and keys (§2.8) ---------------------------------------

    /// Whether `d` may be the object `c` (or contain it, for a deep demand),
    /// and how (§2.2 `alias`; §2.8: a shallow storage write never counts
    /// against the elements a holder holds).
    fn conflict(ix: *Index, d: CellId, c: CellId, deep: bool) Cell.Alias {
        if (!deep and ix.env.cells.below(ix.env.places, d, c)) return .no;
        return ix.env.cells.alias(ix.env.places, d, c);
    }

    /// The group-list key of symbolic cell `sym`'s origin at `path`: what
    /// the refinements at that canonical position share.
    fn pathKey(ix: *Index, sym: CellId, path: PathId) Key {
        const x = ix.env.cells.get(sym);
        std.debug.assert(x.c < 1 << 16);
        return .{ (@as(u32, @backingInt(x.origin)) << 8) | 3 | (x.c << 16), x.a, path.int(), 0 };
    }

    /// The anchor keys of a cell's canonical path (§2.8 *Holders across a
    /// cycle*): every prefix on a cyclic SCC whose next step stays on it,
    /// `(origin, index, prefix, class · ⟲?)`.
    fn anchorsOf(ix: *Index, c: CellId, out: *std.ArrayList(Key)) Error!void {
        const env = ix.env;
        const sym = (try env.cells.unrefined(ix.gpa, env.account(), env.places, c)) orelse return;
        const x = env.cells.get(sym);
        if (!x.origin.isSymbolic() or x.origin == .top) return;
        const places = env.places;
        var at: PathId = places.anchorUp(.from(x.b));
        while (at != .none and places.pathParent(at) != .none) : (at = places.anchorUp(places.pathParent(at))) {
            try ix.rec(1);
            const class: u32 = @intFromBool(places.pathStep(at).kind == .level);
            try out.append(ix.gpa, .{ (@as(u32, @backingInt(x.origin)) << 8) | 1, x.a, places.pathParent(at).int(), (x.c << 1) | class });
        }
    }

    fn cellKey(c: CellId) Key {
        return .{ 0, c.int(), 0, 0 };
    }

    /// The refinements of one split at one canonical position (§2.8's
    /// refinement chain): `pathKey`, split by split.
    fn membersKey(k: Key, split: u32) Key {
        return .{ (k[0] & ~@as(u32, 0xff)) | 2, k[1], k[2], split };
    }

    /// The split refinement `c` took, or `none` for another cell.
    fn ownSplit(ix: *Index, c: CellId) u32 {
        const cells = ix.env.cells;
        if (!cells.origin(c).isRefinement()) return none;
        return cells.findSplit(cells.parent(c), .from(cells.get(c).b)).int();
    }

    /// A refinement's canonical position key, or null for another cell.
    fn refKey(ix: *Index, x: CellId) Error!?Key {
        const cells = ix.env.cells;
        if (!cells.origin(x).isRefinement()) return null;
        const sym = (try cells.unrefined(ix.gpa, ix.env.account(), ix.env.places, x)) orelse return null;
        return ix.pathKey(sym, .from(cells.get(sym).b));
    }

    /// A refinement chain a target reads: the refinements at canonical
    /// position `key`, `self`'s own split's only as one reliance (they all
    /// answer `under` it), never member by member (§2.8).
    const Look = struct { key: Key, self: CellId };

    /// `c`'s trie parent as a candidate, none across a `◆` barrier (§2.13.7:
    /// a holder of a `Ref` holds none of its contents; their only outside
    /// holders are loans, below the contents cell, never above it; #1366).
    fn upCell(ix: *Index, c: CellId) CellId {
        const cells = ix.env.cells;
        const p = cells.parent(c);
        if (p == .none or cells.origin(c).isRefinement()) return p;
        return if (ix.env.places.kind(cells.place(p)) == .ref) .none else p;
    }

    /// `path`'s parent as a candidate's position, as `upCell`.
    fn upPath(ix: *Index, path: PathId) PathId {
        return if (ix.env.places.pathStep(path).kind == .contents) .none else ix.env.places.pathParent(path);
    }

    /// Every key a target `(c, deep)` reads: its static candidates by cell
    /// and its anchors' other class in `out`, its refinement chains by
    /// canonical position in `looks` (§2.8).
    fn targetKeys(ix: *Index, c: CellId, deep: bool, out: *std.ArrayList(Key), looks: *std.ArrayList(Look)) Error!void {
        const cells = ix.env.cells;
        const gpa = ix.gpa;
        var at = c;
        while (at != .none) : (at = ix.upCell(at)) try out.append(gpa, cellKey(at));
        const unrefined = try cells.unrefined(gpa, ix.env.account(), ix.env.places, c);
        if (unrefined) |u| {
            if (u != c) {
                at = u;
                while (at != .none) : (at = ix.upCell(at)) try out.append(gpa, cellKey(at));
            }
            var path: PathId = .from(cells.get(u).b);
            while (path != .none) : (path = ix.upPath(path)) try looks.append(gpa, .{ .key = ix.pathKey(u, path), .self = c });
        }
        at = ix.upCell(c);
        while (at != .none and cells.origin(at).isRefinement()) : (at = ix.upCell(at)) {
            const ua = (try cells.unrefined(gpa, ix.env.account(), ix.env.places, at)) orelse continue;
            try looks.append(gpa, .{ .key = ix.pathKey(ua, .from(cells.get(ua).b)), .self = at });
        }
        if (deep) {
            var stack: std.ArrayList(CellId) = .empty;
            defer stack.deinit(gpa);
            try stack.append(gpa, c);
            if (unrefined) |u| if (u != c) try stack.append(gpa, u);
            while (stack.pop()) |x| {
                var it = cells.children(x);
                while (it.next()) |k| {
                    try ix.rec(1);
                    try out.append(gpa, cellKey(k));
                    try stack.append(gpa, k);
                }
            }
        }
        var anchors: std.ArrayList(Key) = .empty;
        defer anchors.deinit(gpa);
        try ix.anchorsOf(c, &anchors);
        for (anchors.items) |key| {
            const class = key[3] & 1;
            if (class == 0 and !deep) continue;
            var other = key;
            other[3] = (key[3] & ~@as(u32, 1)) | (1 - class);
            try out.append(gpa, other);
        }
        try ix.rec(@intCast(out.items.len));
    }

    /// The keys a holder's cell `x` is found under: itself, a refinement's
    /// canonical position, its anchors (§2.8).
    fn holderKeys(ix: *Index, x: CellId, out: *std.ArrayList(Key)) Error!void {
        try out.append(ix.gpa, cellKey(x));
        if (try ix.refKey(x)) |k| try out.append(ix.gpa, membersKey(k, ix.ownSplit(x)));
        try ix.anchorsOf(x, out);
    }

    /// The key ids (of keys some target reads) of holder cell `x`, memoised.
    fn keysOf(ix: *Index, x: CellId) Error![]const u32 {
        try ix.rec(1);
        const got = try ix.cell_keys.getOrPut(ix.gpa, .{x.int()});
        if (!got.found_existing) {
            const start: u32 = @intCast(ix.ck.items.len);
            var ks: std.ArrayList(Key) = .empty;
            defer ks.deinit(ix.gpa);
            try ix.holderKeys(x, &ks);
            for (ks.items) |k| if (ix.keys.get(k)) |id| try ix.ck.append(ix.gpa, id);
            ix.cell_keys.values.items[got.index] = @intCast(ix.ck_runs.items.len);
            try ix.ck_runs.append(ix.gpa, .{ .start = start, .len = @as(u32, @intCast(ix.ck.items.len)) - start });
        }
        const r = ix.ck_runs.items[ix.cell_keys.values.items[got.index]];
        return ix.ck.items[r.start..][0..r.len];
    }

    /// The demands' targets, their occurrences in point order, and the key
    /// index (§2.8 *The build*).
    fn buildTargets(ix: *Index, wanted: []const bool) Error!void {
        const gpa = ix.gpa;
        const frame = ix.frame;
        const cellt = ix.env.cells;
        const order = try gpa.alloc(u32, frame.demands.len);
        defer gpa.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        std.mem.sort(u32, order, frame.demands, struct {
            fn less(ds: []const Demand, a: u32, b: u32) bool {
                return ds[a].point < ds[b].point or (ds[a].point == ds[b].point and a < b);
            }
        }.less);
        var pairs: std.ArrayList([2]u32) = .empty;
        defer pairs.deinit(gpa);
        var ks: std.ArrayList(Key) = .empty;
        defer ks.deinit(gpa);
        var looks: std.ArrayList(Look) = .empty;
        defer looks.deinit(gpa);
        for (order) |d| if (wanted[d]) try ix.points.append(gpa, frame.demands[d].point);
        // The splits whose refinements a holder holds, per canonical position:
        // what a target's refinement chain reads split by split.
        for (frame.holders) |h| {
            if (!ix.inLife(h)) continue;
            var it = cellt.sets.iterate(try ix.reach(h.value.node));
            while (it.next()) |e| {
                try ix.rec(1);
                if (try ix.refKey(.from(e.key))) |k| try ix.ksplits.append(gpa, .{ .key = k, .split = ix.ownSplit(.from(e.key)) });
            }
        }
        std.mem.sort(KSplit, ix.ksplits.items, {}, KSplit.less);
        var kept: usize = 0;
        for (ix.ksplits.items, 0..) |k, i| {
            if (i > 0 and std.meta.eql(k, ix.ksplits.items[kept - 1])) continue;
            ix.ksplits.items[kept] = k;
            kept += 1;
        }
        ix.ksplits.shrinkRetainingCapacity(kept);
        for (order) |d| {
            if (!wanted[d]) continue;
            const dm = frame.demands[d];
            const deep = dm.kind.isDeep();
            const base = if (deep) try ix.reach(dm.base.node) else try ix.env.shapes.cellsOf(gpa, ix.env.account(), &cellt.sets, dm.base.node);
            var it = cellt.sets.iterate(base);
            var n: u32 = 0;
            while (it.next()) |_| n += 1;
            const alternatives = !deep and n > 1;
            it = cellt.sets.iterate(base);
            while (it.next()) |e| {
                try ix.rec(1);
                const c: CellId = .from(e.key);
                const got = try ix.target_of.getOrPut(gpa, .{ c.int(), @intFromBool(deep) });
                if (!got.found_existing) {
                    got.value_ptr.* = @intCast(ix.targets.items.len);
                    try ix.targets.append(gpa, .{ .c = c, .deep = deep });
                    ks.clearRetainingCapacity();
                    looks.clearRetainingCapacity();
                    try ix.targetKeys(c, deep, &ks, &looks);
                    // A chain's other splits' members are candidates; its own
                    // split's are one reliance, `self` left out.
                    for (looks.items) |l| {
                        const own = ix.ownSplit(l.self);
                        const lo = std.sort.partitionPoint(KSplit, ix.ksplits.items, l.key, KSplit.below);
                        var i = lo;
                        while (i < ix.ksplits.items.len and std.mem.eql(u32, &ix.ksplits.items[i].key, &l.key)) : (i += 1) {
                            try ix.rec(1);
                            const s = ix.ksplits.items[i].split;
                            const mk = membersKey(l.key, s);
                            if (s == own and own != none) {
                                const kid = try ix.keys.getOrPut(gpa, mk);
                                kid.value_ptr.* = kid.index;
                                try ix.sibs.append(gpa, .{ .target = got.value_ptr.*, .kid = kid.index, .self = l.self, .split = .from(own) });
                            } else try ks.append(gpa, mk);
                        }
                    }
                    for (ks.items) |k| {
                        const kid = try ix.keys.getOrPut(gpa, k);
                        kid.value_ptr.* = kid.index;
                        try pairs.append(gpa, .{ kid.index, got.value_ptr.* });
                    }
                }
                try ix.occ.append(gpa, .{ .target = got.value_ptr.*, .point = dm.point, .demand = d, .forced = alternatives or e.value == 1, .maybe = e.value == 1 });
            }
        }
        // Occurrences by target, each target's in point order (stable).
        std.mem.sort(Occ, ix.occ.items, {}, struct {
            fn less(_: void, a: Occ, b: Occ) bool {
                return a.target < b.target or (a.target == b.target and (a.point < b.point or (a.point == b.point and a.demand < b.demand)));
            }
        }.less);
        try ix.rec(@intCast(ix.occ.items.len));
        for (ix.occ.items, 0..) |o, j| {
            const t = &ix.targets.items[o.target];
            if (t.occ.len == 0) t.occ.start = @intCast(j);
            t.occ.len += 1;
        }
        try ix.acc.appendNTimes(gpa, .{ null, null }, ix.occ.items.len);
        // Per demand its occurrences.
        ix.dem_occ = try gpa.alloc(Ids.Range, frame.demands.len);
        @memset(ix.dem_occ, .empty);
        for (ix.occ.items) |o| ix.dem_occ[o.demand].len += 1;
        var at: u32 = 0;
        for (ix.dem_occ) |*r| {
            r.start = at;
            at += r.len;
            r.len = 0;
        }
        try ix.docc.resize(gpa, ix.occ.items.len);
        for (ix.occ.items, 0..) |o, j| {
            const r = &ix.dem_occ[o.demand];
            ix.docc.items[r.start + r.len] = @intCast(j);
            r.len += 1;
        }
        // Own-split chains by target and by key.
        std.mem.sort(Sib, ix.sibs.items, {}, struct {
            fn less(_: void, a: Sib, b: Sib) bool {
                return a.target < b.target or (a.target == b.target and a.kid < b.kid);
            }
        }.less);
        for (ix.sibs.items, 0..) |s, j| {
            const t = &ix.targets.items[s.target];
            if (t.sibs.len == 0) t.sibs.start = @intCast(j);
            t.sibs.len += 1;
        }
        try ix.sib_keys.appendSlice(gpa, ix.sibs.items);
        std.mem.sort(Sib, ix.sib_keys.items, {}, struct {
            fn less(_: void, a: Sib, b: Sib) bool {
                return a.kid < b.kid or (a.kid == b.kid and a.target < b.target);
            }
        }.less);
        // Keys → targets, deduplicated.
        std.mem.sort([2]u32, pairs.items, {}, struct {
            fn less(_: void, a: [2]u32, b: [2]u32) bool {
                return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
            }
        }.less);
        try ix.key_targets.appendNTimes(gpa, .empty, ix.keys.count());
        for (pairs.items, 0..) |p, i| {
            if (i > 0 and std.mem.eql(u32, &p, &pairs.items[i - 1])) continue;
            const r = &ix.key_targets.items[p[0]];
            if (r.len == 0) r.start = @intCast(ix.kt.items.len);
            r.len += 1;
            try ix.kt.append(gpa, p[1]);
        }
    }

    /// Target `t`'s occurrences inside `(lo, hi]`.
    fn lifeRange(ix: *const Index, t: u32, lo: u32, hi: u32) Ids.Range {
        const r = ix.targets.items[t].occ;
        const occ = ix.occ.items[r.start..][0..r.len];
        const a = std.sort.partitionPoint(Occ, occ, lo, struct {
            fn f(p: u32, o: Occ) bool {
                return o.point <= p;
            }
        }.f);
        const b = std.sort.partitionPoint(Occ, occ, hi, struct {
            fn f(p: u32, o: Occ) bool {
                return o.point <= p;
            }
        }.f);
        return .{ .start = r.start + @as(u32, @intCast(a)), .len = @intCast(b - a) };
    }

    fn groupOf(ix: *Index, t: u32, x: CellId) Error!u32 {
        const got = try ix.group_of.getOrPut(ix.gpa, .{ t, x.int() });
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(ix.groups.items.len);
            const tg = ix.targets.items[t];
            try ix.groups.append(ix.gpa, .{ .target = t, .x = x, .how = ix.conflict(x, tg.c, tg.deep) });
        }
        return got.value_ptr.*;
    }

    fn slot(ix: *Index, g: u32, s: u32, pos: u32) Error!u32 {
        const got = try ix.slots.getOrPut(ix.gpa, .{ g, s, pos });
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(ix.counts.items.len);
            try ix.counts.append(ix.gpa, 0);
        }
        return got.value_ptr.*;
    }

    fn count(ix: *const Index, g: u32, s: u32, pos: u32) i32 {
        return if (ix.slots.get(.{ g, s, pos })) |i| ix.counts.items[i] else 0;
    }

    fn registered(ix: *Index, h: Holder, slot_id: u32) Error!void {
        try ix.events.append(ix.gpa, .{ .point = h.start, .phase = 2, .kind = .inc, .ref = slot_id });
        try ix.events.append(ix.gpa, .{ .point = h.end, .phase = 3, .kind = .dec, .ref = slot_id });
    }

    /// Every holder's pairs, its entries or heavy answers, its reliance
    /// (§2.8 *The build*, steps 1–2).
    fn buildPairs(ix: *Index) Error!void {
        const gpa = ix.gpa;
        const cellt = ix.env.cells;
        const top_cell = try cellt.top(gpa, ix.env.account());
        var found: std.ArrayList([4]u32) = .empty;
        defer found.deinit(gpa);
        var blocks: std.ArrayList(Block) = .empty;
        defer blocks.deinit(gpa);
        for (ix.frame.holders, 0..) |h, hi_| {
            const hi: u32 = @intCast(hi_);
            if (!ix.inLife(h)) continue;
            try ix.rec(1);
            const r = try ix.reach(h.value.node);
            found.clearRetainingCapacity();
            const top = cellt.sets.member(r, top_cell.int());
            var it = cellt.sets.iterate(r);
            while (it.next()) |e| {
                const x: CellId = .from(e.key);
                if (x == top_cell) continue;
                for (try ix.keysOf(x)) |kid| {
                    // An own-split chain's member is counted, never paired;
                    // a `⊤` holder still pairs for its inversion.
                    var j = std.sort.partitionPoint(Sib, ix.sib_keys.items, kid, struct {
                        fn f(k: u32, s: Sib) bool {
                            return s.kid < k;
                        }
                    }.f);
                    if (j < ix.sib_keys.items.len and ix.sib_keys.items[j].kid == kid) {
                        try ix.registered(h, try ix.slot(sib_tag | kid, none, none));
                        try ix.registered(h, try ix.slot(sib_tag | kid, x.int(), none));
                        while (top and j < ix.sib_keys.items.len and ix.sib_keys.items[j].kid == kid) : (j += 1) {
                            const s = ix.sib_keys.items[j];
                            const life = ix.lifeRange(s.target, h.start, h.end);
                            if (life.len > 0 and x != s.self) try found.append(gpa, .{ s.target, top_cell.int(), life.start, life.len });
                        }
                    }
                    const run = ix.key_targets.items[kid];
                    for (ix.kt.items[run.start..][0..run.len]) |t| {
                        try ix.rec(1);
                        const life = ix.lifeRange(t, h.start, h.end);
                        if (life.len > 0) try found.append(gpa, .{ t, x.int(), life.start, life.len });
                    }
                }
            }
            std.mem.sort([4]u32, found.items, {}, struct {
                fn less(_: void, a: [4]u32, b: [4]u32) bool {
                    return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
                }
            }.less);
            // A `⊤` holder holds what it may have reached (§2.8's inversion):
            // a target it pairs with through another cell, once.
            var last_t: u32 = none;
            for (found.items, 0..) |f, i| {
                if (i > 0 and f[0] == found.items[i - 1][0] and f[1] == found.items[i - 1][1]) continue;
                const g = try ix.groupOf(f[0], .from(f[1]));
                if (f[1] != top_cell.int()) {
                    if (ix.groups.items[g].how == .no) continue;
                    try ix.pair(hi, g, .{ .start = f[2], .len = f[3] }, &blocks);
                    if (!top) continue;
                }
                if (f[0] == last_t) continue;
                last_t = f[0];
                const tg = try ix.groupOf(f[0], top_cell);
                if (ix.groups.items[tg].how != .no) try ix.pair(hi, tg, .{ .start = f[2], .len = f[3] }, &blocks);
            }
        }
    }

    /// Whether some wanted demand lies in holder `h`'s life `(start, end]`.
    fn inLife(ix: *const Index, h: Holder) bool {
        if (h.value.node == .none) return false;
        const first = std.sort.partitionPoint(u32, ix.points.items, h.start, struct {
            fn f(p: u32, x: u32) bool {
                return x <= p;
            }
        }.f);
        return first < ix.points.items.len and ix.points.items[first] <= h.end;
    }

    fn excluded(ix: *const Index, dm: Demand, h: Holder, x: CellId) ?SplitId {
        if (h.kind != .binding or h.taken.split == .none) return null;
        const t = ix.baseTaken(dm) orelse return null;
        if (t.split != h.taken.split or t.pos == h.taken.pos) return null;
        if (!ix.env.cells.sets.member(t.explicit, x.int())) return null;
        return t.split;
    }

    /// The position the demand's base local was bound at (`Taken`), if any.
    fn baseTaken(ix: *const Index, dm: Demand) ?Taken {
        if (dm.base_local == none or dm.base_local >= ix.frame.bindings.len) return null;
        const b = ix.frame.bindings[dm.base_local];
        if (b == none) return null;
        const t = ix.frame.holders[b].taken;
        return if (t.split == .none) null else t;
    }

    fn treeOf(ix: *Index, g: u32, kind: u32, s: u32, pos: u32) Error!u32 {
        const got = try ix.tree_of.getOrPut(ix.gpa, .{ g, kind, s, pos });
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(ix.trees.items.len);
            try ix.trees.append(ix.gpa, .{ .first = 0, .n = 0, .off = 0, .cap = 0 });
        }
        return got.value_ptr.*;
    }

    /// One pair (holder `hi`, group `g`), its demands `life`.
    fn pair(ix: *Index, hi: u32, g: u32, life: Ids.Range, blocks: *std.ArrayList(Block)) Error!void {
        const h = ix.frame.holders[hi];
        const grp = ix.groups.items[g];
        switch (grp.how) {
            .no => return,
            .under, .under_kappa => return ix.registered(h, try ix.slot(g, none, none)),
            .yes => {},
        }
        const split: u32 = if (h.kind == .binding) h.taken.split.int() else none;
        if (h.kind == .binding and h.taken.split != .none) {
            try ix.registered(h, try ix.slot(g, split, none));
            try ix.registered(h, try ix.slot(g, split, h.taken.pos));
        }
        const top = ix.env.cells.origin(grp.x) == .top;
        if (h.kind == .pending) {
            const t = try ix.treeOf(g, 1, none, none);
            ix.groups.items[g].pend = t;
            try ix.entries.append(ix.gpa, .{ .tree = t, .rank2 = ix.rank2(h.start), .point = h.start, .start = h.start, .holder = hi, .atom = none, .use = .none, .exact_path = .none, .any_path = .none, .exact_ok = !top, .element = false, .split = none, .until = h.end });
            return;
        }
        blocks.clearRetainingCapacity();
        try ix.cover(h, grp.x, ix.targets.items[grp.target].c, blocks);
        if (blocks.items.len == 0) return;
        // `element` (§2.8 condition 5): the first hold this use covers is
        // approximate in itself, whatever the base's cells.
        for (blocks.items) |*b| b.element = b.exact != b.any;
        const index = ix.frame.index;
        var u_count: u64 = 0;
        for (blocks.items) |b| u_count += b.hi - b.lo;
        const p0 = ix.occ.items[life.start].point;
        // Light or heavy (§2.8 step 2): the cheaper of an entry per use and a
        // query per demand and block.
        if (@as(u64, life.len) * blocks.items.len * 4 < u_count) {
            var j = life.start;
            while (j < life.start + life.len) : (j += 1) {
                const o = ix.occ.items[j];
                if (ix.excluded(ix.frame.demands[o.demand], h, grp.x) != null) continue;
                for (blocks.items) |b| {
                    try ix.rec(1);
                    const u = (try ix.earliestIn(b, o.point)) orelse continue;
                    const use = index.get(u);
                    const w: Win = .{ .holder = hi, .point = use.point, .start = h.start, .use = u, .atom = use.atom };
                    if (b.exact != .none) ix.fold(&ix.acc.items[j][0], with(w, b.exact));
                    var a = with(w, b.any);
                    a.element = b.element;
                    ix.fold(&ix.acc.items[j][1], a);
                }
            }
            return;
        }
        const t = try ix.treeOf(g, 0, none, none);
        ix.groups.items[g].ord = t;
        const same: ?u32 = if (split != none) try ix.treeOf(g, 2, split, h.taken.pos) else null;
        for (blocks.items) |b| {
            var i = b.lo;
            while (i < b.hi) : (i += 1) {
                try ix.rec(1);
                const use = index.get(.from(i));
                if (use.point <= p0) continue;
                const e: Entry = .{ .tree = t, .rank2 = ix.rank2(use.point), .point = use.point, .start = h.start, .holder = hi, .atom = use.atom, .use = .from(i), .exact_path = b.exact, .any_path = b.any, .exact_ok = b.exact != .none, .element = b.element, .split = split, .until = use.point };
                try ix.entries.append(ix.gpa, e);
                if (same) |s| {
                    var copy = e;
                    copy.tree = s;
                    try ix.entries.append(ix.gpa, copy);
                }
            }
        }
    }

    /// The earliest use of block `b` after `p` and compatible with it, ties
    /// to the least atom (the canonical order, never the index's).
    fn earliestIn(ix: *Index, b: Block, p: u32) Error!?UseId {
        const index = ix.frame.index;
        const t = ix.rank2(p);
        var r: Ids.Range = .{ .start = b.lo, .len = b.hi - b.lo };
        var best: ?UseId = null;
        while (try index.firstAfter(ix.gpa, ix.env.charge, r, if (best) |x| index.get(x).point - 1 else p, t)) |u| {
            try ix.rec(1);
            if (best) |x| {
                if (index.get(u).point != index.get(x).point) break;
                if (index.get(u).atom < index.get(x).atom) best = u;
            } else best = u;
            // The next at that point: past `u` in the block.
            r = .{ .start = u.int() + 1, .len = b.hi - (u.int() + 1) };
            if (r.len == 0) break;
        }
        return best;
    }

    fn with(w: Win, path: PathId) Win {
        var x = w;
        x.path = path;
        return x;
    }

    // ---- the best hold and the cover (§2.8 step 3) -------------------------

    /// A state at one path; `kids`, a run of `kid_cache`: its children that
    /// reach the candidate, found once by `closure`.
    const St = struct { node: NodeId, alt: bool = false, cast: bool = false, blur: bool = false, kids: Ids.Range = .empty };
    const Clo = struct { start: u32, len: u32, bits: Bits };
    const Chain = struct { f: PathId, exact: bool, k: u32 };
    const Cursor = union(enum) { free, dead, node: NodeId };
    const Open = struct { lo: u32, hi: u32, exact: PathId = .none, any: PathId, need_exact: bool, need_any: bool, cur: Cursor };
    const Kid = struct {
        step: Step,
        states: std.ArrayList(St) = .empty,
        chains: std.ArrayList(Chain) = .empty,
        bits: Bits = .{},

        fn deinit(k: *Kid, gpa: Allocator) void {
            k.states.deinit(gpa);
            k.chains.deinit(gpa);
        }
    };
    const Fallback = error{Fallback};

    /// Whether `x` is held at state `s` (a symbolic cell stands for what is
    /// below it only in a leaf), and how.
    fn holdAt(ix: *Index, s: St, x: CellId, c: CellId) Error!?struct { approx: bool, several: bool } {
        const shapes = ix.env.shapes;
        const cells = try shapes.cellsOf(ix.gpa, ix.env.account(), &ix.env.cells.sets, s.node);
        const kind = shapes.kind(s.node);
        if ((kind == .node or kind == .delta) and x != c) return null;
        const v = ix.env.cells.sets.get(cells, x.int()) orelse return null;
        return .{ .approx = v == 1 or s.blur, .several = s.alt or several(ix.env.cells, cells) };
    }

    /// Whether a hold at final path `f` is exact (§2.8 *Dead*): not at a
    /// summary position or by a cell that stands for several, not `⊤`, not
    /// one of several alternatives.
    fn holdExact(ix: *Index, f: PathId, approx: bool, alt: bool, x: CellId, c: CellId) bool {
        const cellt = ix.env.cells;
        const places = ix.env.places;
        const summary = (places.isSummary(f) or stands(cellt, places, x)) and !isMaterialised(cellt, c);
        return !(approx or summary or cellt.origin(x) == .top or (alt and !places.isSummary(f)));
    }

    /// The steps from a hold of `x` down to `c` (§2.8): a `⟲` first when `x`
    /// is a level, then `stepsTo`; empty when `x` is `c` or not above it.
    /// True when the first step is that `⟲`, which a place without it skips.
    fn extSteps(ix: *Index, x: CellId, c: CellId, out: *std.ArrayList(Step)) Error!bool {
        out.clearRetainingCapacity();
        if (x == c) return false;
        const cellt = ix.env.cells;
        var tail: std.ArrayList(Step) = .empty;
        defer tail.deinit(ix.gpa);
        if (!try cellt.stepsTo(ix.env.places, x, c, ix.gpa, &tail)) return false;
        const dx = cellt.get(x);
        const level = dx.origin.isSymbolic() and dx.origin != .top and ix.env.places.pathParent(.from(dx.b)) != .none and ix.env.places.pathStep(.from(dx.b)).kind == .level;
        if (level) try out.append(ix.gpa, Step.level);
        try out.appendSlice(ix.gpa, tail.items);
        return level;
    }

    /// `path · step` when it is a plain child, `Fallback` when the place
    /// graph folds it (a `⟲`) or lacks it: the cover's order is the paths'
    /// only for plain children.
    fn child(ix: *Index, path: PathId, step: Step) (Error || Fallback)!PathId {
        const ext = (try ix.env.places.extend(ix.gpa, ix.env.charge, path, step)) orelse return error.Fallback;
        if (ix.env.places.pathParent(ext) != path or ix.env.places.pathStep(ext).word() != step.word()) return error.Fallback;
        return ext;
    }

    /// What a path's states hold of `x` (§2.8 *Dead*): some hold; one neither
    /// approximate nor one of several; one of several only.
    const Bits = packed struct(u8) { any: bool = false, plain: bool = false, alt: bool = false, _: u5 = 0 };

    fn bitsOr(a: Bits, b: Bits) Bits {
        return @bitCast(@as(u8, @bitCast(a)) | @as(u8, @bitCast(b)));
    }

    /// Whether a hold with `bits` at final path `f` is exact.
    fn bitsExact(ix: *Index, f: PathId, bits: Bits, x: CellId, c: CellId) bool {
        return bits.plain and ix.holdExact(f, false, false, x, c) or bits.alt and ix.holdExact(f, false, true, x, c);
    }

    /// `s` under the route flags of `f`: a flag set on the way stays set.
    fn under(f: St, s: St) St {
        return .{ .node = s.node, .alt = f.alt or s.alt, .cast = f.cast or s.cast, .blur = f.blur or s.blur, .kids = s.kids };
    }

    /// Hold bits under the route flags of `f`: a blurred hold is approximate,
    /// one below a join one of several.
    fn bitsUnder(f: St, b: Bits) Bits {
        if (!b.any) return b;
        if (f.blur) return .{ .any = true };
        if (f.alt) return .{ .any = true, .alt = b.plain or b.alt };
        return b;
    }

    /// The states at one path from `s` (a union's and a choice's sides, one
    /// of several; a view's answer; a recast's inner; a delta's base), those
    /// whose reach holds `x`: the hold bits they give there and the ones with
    /// children. Memoised per node with no route flags, which are applied on
    /// reading, so a chain of joins is walked once for every holder of the
    /// frame (§2.8 step 3, `scenario/CK-1214`).
    fn expand(ix: *Index, s: St, x: CellId, c: CellId, out: *std.ArrayList(St), bits: *Bits) Error!void {
        const clo = ix.clos.items[try ix.closure(s.node, x, c)];
        bits.* = bitsOr(bits.*, bitsUnder(s, clo.bits));
        for (ix.pool.items[clo.start..][0..clo.len]) |p| {
            const st = under(s, p);
            for (out.items) |o| {
                if (std.meta.eql(o, st)) break;
            } else try out.append(ix.gpa, st);
        }
    }

    /// `closure(n0, x, c)`: one Tarjan walk (`Shape.Table.cycleWalk`) over
    /// what each state's closure is read from, its sides, so a cycle with
    /// no `node` on it (#1314's knot, #1335) ends at its least fixed point.
    fn closure(ix: *Index, n0: NodeId, x: CellId, c: CellId) Error!u32 {
        const key: Key = .{ n0.int(), x.int(), c.int(), 0 };
        if (ix.clo_of.get(key)) |hit| return hit;
        var w: CloWalk = .{ .ix = ix, .x = x, .c = c };
        defer w.deinit();
        try ix.env.shapes.cycleWalk(ix.gpa, n0, &w);
        return ix.clo_of.get(key).?;
    }

    /// The states at one path from `n`, its sides with their route flags
    /// (`expand`), and how many; a view's answer forced unless `settling`.
    fn sidesOf(ix: *Index, n: NodeId, settling: bool) Error!struct { [2]St, usize } {
        const shapes = ix.env.shapes;
        const k = shapes.get(n);
        return switch (k.kind) {
            .leaf, .node => .{ undefined, 0 },
            .delta => .{ .{ .{ .node = .from(k.a) }, undefined }, 1 },
            .recast => .{ .{ .{ .node = .from(k.a), .cast = true }, undefined }, 1 },
            .view => .{ .{ .{ .node = if (settling) shapes.forced(n) else try shapes.force(ix.gpa, ix.env.account(), n) }, undefined }, 1 },
            .@"union", .choice, .positions => blk: {
                const alt = k.kind == .@"union" or k.kind == .choice;
                break :blk .{ .{ .{ .node = .from(k.a), .alt = alt }, .{ .node = .from(k.b), .alt = alt } }, 2 };
            },
        };
    }

    /// `closure`'s relation for `cycleWalk`. A state whose reach lacks `x`
    /// is settled on entry, empty, and reads nothing. A record alone takes
    /// its own hold and children, then its sides' closures under their
    /// flags, deduplicated in that order; a cycle starts each member so and
    /// adds its sides' (a member's as it stands) until nothing changes:
    /// `under` only sets flags, so the states and bits only grow, within the
    /// cycle's reach (§2.11 *A cycle with no node on it*).
    const CloWalk = struct {
        ix: *Index,
        x: CellId,
        c: CellId,
        /// A cycle's members' states and bits while it is settled.
        lists: std.ArrayList(std.ArrayList(St)) = .empty,
        bits: std.ArrayList(Bits) = .empty,

        fn deinit(w: *CloWalk) void {
            const gpa = w.ix.gpa;
            for (w.lists.items) |*l| l.deinit(gpa);
            w.lists.deinit(gpa);
            w.bits.deinit(gpa);
        }

        fn key(w: *const CloWalk, n: NodeId) Key {
            return .{ n.int(), w.x.int(), w.c.int(), 0 };
        }

        pub fn from(w: *CloWalk, n: NodeId) Error![2]NodeId {
            const ix = w.ix;
            try ix.rec(1);
            const two = try ix.sidesOf(n, false);
            if (!ix.env.cells.sets.member(try ix.reach(n), w.x.int())) {
                try ix.clo_of.put(ix.gpa, w.key(n), @intCast(ix.clos.items.len));
                try ix.clos.append(ix.gpa, .{ .start = 0, .len = 0, .bits = .{} });
                return .{ .none, .none };
            }
            var out: [2]NodeId = .{ .none, .none };
            for (two[0][0..two[1]], 0..) |s, i| out[i] = s.node;
            return out;
        }

        pub fn settled(w: *const CloWalk, n: NodeId) bool {
            return w.ix.clo_of.get(w.key(n)) != null;
        }

        /// Member `n`'s own hold bits and, for a node or a delta with a
        /// child that reaches `x`, itself as the state with children.
        fn own(w: *CloWalk, n: NodeId, list: *std.ArrayList(St)) Error!Bits {
            const ix = w.ix;
            var bits: Bits = .{};
            if (try ix.holdAt(.{ .node = n }, w.x, w.c)) |hd| {
                bits.any = true;
                bits.plain = !hd.approx and !hd.several;
                bits.alt = !hd.approx and hd.several;
            }
            const kind = ix.env.shapes.kind(n);
            if (kind == .node or kind == .delta) {
                const lo: u32 = @intCast(ix.kid_cache.items.len);
                try ix.kidsOf(n, w.x, &ix.kid_cache);
                const len = @as(u32, @intCast(ix.kid_cache.items.len)) - lo;
                if (len > 0) try list.append(ix.gpa, .{ .node = n, .kids = .{ .start = lo, .len = len } });
            }
            return bits;
        }

        /// `src`'s states under `side`'s flags into `list`, each once;
        /// whether one was new.
        fn add(w: *CloWalk, side: St, src: []const St, list: *std.ArrayList(St)) Error!bool {
            var grew = false;
            for (src) |p| {
                const st = under(side, p);
                for (list.items) |o| {
                    if (std.meta.eql(o, st)) break;
                } else {
                    try list.append(w.ix.gpa, st);
                    grew = true;
                }
            }
            return grew;
        }

        pub fn settle(w: *CloWalk, members: []const NodeId) Error!void {
            const ix = w.ix;
            const gpa = ix.gpa;
            // Settled on entry: its reach lacks `x`.
            if (members.len == 1 and w.settled(members[0])) return;
            try ix.rec(@intCast(members.len));
            // A member's index by node, for a cycle of several.
            var member: Ids.FixedDict(1) = .{};
            defer member.deinit(gpa);
            if (members.len > 1) for (members, 0..) |m, i| {
                (try member.getOrPut(gpa, .{m.int()})).value_ptr.* = @intCast(i);
            };
            while (w.lists.items.len < members.len) try w.lists.append(gpa, .empty);
            try w.bits.resize(gpa, members.len);
            // A cycle: several members, or one that reads itself.
            var cyclic = members.len > 1;
            if (!cyclic) {
                const two = try ix.sidesOf(members[0], true);
                for (two[0][0..two[1]]) |side| cyclic = cyclic or side.node == members[0];
            }
            const lists = w.lists.items[0..members.len];
            for (members, lists, w.bits.items) |m, *l, *b| {
                l.clearRetainingCapacity();
                b.* = try w.own(m, l);
            }
            // One pass for a record alone; a cycle's until it is still.
            var again = true;
            while (again) {
                again = false;
                for (members, lists, w.bits.items) |m, *l, *b| {
                    const two = try ix.sidesOf(m, false);
                    for (two[0][0..two[1]]) |side| {
                        const before = b.*;
                        const src: []const St, const sb: Bits = if (if (members.len == 1) (if (side.node == members[0]) @as(?u32, 0) else null) else member.get(.{side.node.int()})) |j|
                            .{ lists[j].items, w.bits.items[j] }
                        else blk: {
                            const sub = ix.clos.items[ix.clo_of.get(w.key(side.node)).?];
                            break :blk .{ ix.pool.items[sub.start..][0..sub.len], sub.bits };
                        };
                        // A cycle's passes are charged per state they read.
                        if (cyclic) try ix.rec(@intCast(src.len));
                        b.* = bitsOr(b.*, bitsUnder(side, sb));
                        const grew = try w.add(side, src, l);
                        if (cyclic) again = again or grew or @as(u8, @bitCast(before)) != @as(u8, @bitCast(b.*));
                    }
                }
            }
            for (members, lists, w.bits.items) |m, l, b| {
                const start: u32 = @intCast(ix.pool.items.len);
                try ix.pool.appendSlice(gpa, l.items);
                try ix.clo_of.put(gpa, w.key(m), @intCast(ix.clos.items.len));
                try ix.clos.append(gpa, .{ .start = start, .len = @intCast(l.items.len), .bits = b });
            }
            // A cycle's fixed point: each member holds what it reads.
            if (std.debug.runtime_safety and cyclic) for (members) |m| {
                const mine = ix.clos.items[ix.clo_of.get(w.key(m)).?];
                const two = try ix.sidesOf(m, true);
                for (two[0][0..two[1]]) |side| {
                    const sub = ix.clos.items[ix.clo_of.get(w.key(side.node)).?];
                    const sb: u8 = @bitCast(bitsUnder(side, sub.bits));
                    std.debug.assert(sb & @as(u8, @bitCast(mine.bits)) == sb);
                    for (ix.pool.items[sub.start..][0..sub.len]) |p| {
                        const st = under(side, p);
                        for (ix.pool.items[mine.start..][0..mine.len]) |o| {
                            if (std.meta.eql(o, st)) break;
                        } else unreachable;
                    }
                }
            };
        }
    };

    /// The children of node `n` whose reach holds `x`, as `(step, child)`:
    /// a wide node's from a cell-to-children index built once (§2.8 step 3).
    fn kidsOf(ix: *Index, n: NodeId, x: CellId, out: *std.ArrayList([2]u32)) Error!void {
        const shapes = ix.env.shapes;
        const k = shapes.get(n);
        const root = if (k.kind == .node) k.a else k.b;
        var w: u32 = 0;
        var it = shapes.overEntries(root);
        while (it.next()) |_| : (w += 1) if (w > wide) break;
        if (w <= wide) {
            it = shapes.overEntries(root);
            while (it.next()) |e| {
                try ix.rec(1);
                if (ix.env.cells.sets.member(try ix.reach(e.node), x.int())) try out.append(ix.gpa, .{ e.step.word(), e.node.int() });
            }
            return;
        }
        const got = try ix.inv.getOrPut(ix.gpa, .{n.int()});
        if (!got.found_existing) {
            const start: u32 = @intCast(ix.inv_items.items.len);
            it = shapes.overEntries(root);
            while (it.next()) |e| {
                var cs = ix.env.cells.sets.iterate(try ix.reach(e.node));
                while (cs.next()) |c| {
                    try ix.rec(1);
                    try ix.inv_items.append(ix.gpa, .{ c.key, e.step.word(), e.node.int() });
                }
            }
            std.mem.sort([3]u32, ix.inv_items.items[start..], {}, struct {
                fn less(_: void, a: [3]u32, b: [3]u32) bool {
                    return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
                }
            }.less);
            got.value_ptr.* = @intCast(ix.inv_runs.items.len);
            try ix.inv_runs.append(ix.gpa, .{ .start = start, .len = @as(u32, @intCast(ix.inv_items.items.len)) - start });
        }
        const r = ix.inv_runs.items[ix.inv.values.items[got.index]];
        const run = ix.inv_items.items[r.start..][0..r.len];
        try ix.rec(std.math.log2_int_ceil(usize, run.len + 1) + 1);
        var i = std.sort.partitionPoint([3]u32, run, x.int(), struct {
            fn f(key: u32, e: [3]u32) bool {
                return e[0] < key;
            }
        }.f);
        while (i < run.len and run[i][0] == x.int()) : (i += 1) try out.append(ix.gpa, .{ run[i][1], run[i][2] });
    }

    /// The cover of holder `h`'s uses for candidate `x` of `c` (§2.8): each
    /// use, by blocks of the use index, with its best exact and best covered
    /// hold path. One descent of the holder's value with its uses' paths,
    /// in step order (DFS preorder reaches each node first along its least
    /// path); a path the place graph folds or lacks falls back to listing
    /// the holds.
    fn cover(ix: *Index, h: Holder, x: CellId, c: CellId, out: *std.ArrayList(Block)) Error!void {
        const mark = out.items.len;
        const d = &ix.desc;
        d.ix = ix;
        d.h = h;
        d.x = x;
        d.c = c;
        d.out = out;
        d.bits = .{};
        inline for (.{ &d.ext, &d.steps, &d.open, &d.saved, &d.frames, &d.states, &d.chains, &d.pending }) |l| l.clearRetainingCapacity();
        d.nk = 0;
        d.run() catch |e| switch (e) {
            error.Fallback => {
                ix.env.account().hold_listings += 1;
                out.shrinkRetainingCapacity(mark);
                return ix.coverNaive(h, x, c, out);
            },
            else => |other| return other,
        };
    }

    /// One node of the descent: a path `q` with its uses `[lo, hi)`, the
    /// route's best holds, its open groups and its children.
    const Fr = struct {
        q: PathId,
        depth: u32,
        route_exact: PathId,
        route_any: PathId,
        lo: u32,
        hi: u32,
        /// The entered child's subtree range.
        kid_range: Ids.Range = .empty,
        /// Uses before it are a group's or a child's; the rest, the route's.
        until: u32,
        open_mark: u32,
        kids: u32,
        nkids: u32,
        next: u32 = 0,
        /// While a child is entered: where its cursor snapshot starts.
        cur_mark: u32 = none,
    };

    /// One cover's walk; the index keeps one, its buffers and its children's
    /// lists reused from pair to pair and node to node (§4.1: the work of a
    /// node is its records', not an allocation's).
    const Descent = struct {
        ix: *Index = undefined,
        h: Holder = undefined,
        x: CellId = .none,
        c: CellId = .none,
        out: *std.ArrayList(Block) = undefined,
        /// The live kid slots: `kids` keeps every slot made, its lists' memory
        /// reused.
        nk: u32 = 0,
        ext: std.ArrayList(Step) = .empty,
        steps: std.ArrayList(Step) = .empty,
        open: std.ArrayList(Open) = .empty,
        saved: std.ArrayList(Cursor) = .empty,
        frames: std.ArrayList(Fr) = .empty,
        kids: std.ArrayList(Kid) = .empty,
        bits: Bits = .{},
        states: std.ArrayList(St) = .empty,
        chains: std.ArrayList(Chain) = .empty,
        pending: std.ArrayList(Chain) = .empty,

        pub fn deinit(d: *Descent, gpa: Allocator) void {
            d.ext.deinit(gpa);
            d.steps.deinit(gpa);
            d.open.deinit(gpa);
            d.saved.deinit(gpa);
            d.frames.deinit(gpa);
            for (d.kids.items) |*k| k.deinit(gpa);
            d.kids.deinit(gpa);
            d.states.deinit(gpa);
            d.chains.deinit(gpa);
            d.pending.deinit(gpa);
        }

        fn run(d: *Descent) (Error || Fallback)!void {
            const ix = d.ix;
            const gpa = ix.gpa;
            _ = try ix.extSteps(d.x, d.c, &d.ext);
            try ix.expand(.{ .node = d.h.value.node }, d.x, d.c, &d.states, &d.bits);
            try d.enter(d.h.root, .none, .none, ix.frame.index.rangeOf(ix.env.places, d.h.who, &.{}, true));
            while (d.frames.items.len > 0) {
                const top = &d.frames.items[d.frames.items.len - 1];
                if (top.cur_mark != none) {
                    d.restore(top.cur_mark);
                    top.cur_mark = none;
                }
                d.steps.shrinkRetainingCapacity(top.depth);
                const next = try d.nextKid(top);
                if (next) |k| {
                    const q = try ix.child(top.q, k.step);
                    d.states.clearRetainingCapacity();
                    try d.states.appendSlice(gpa, k.states.items);
                    d.bits = k.bits;
                    d.chains.clearRetainingCapacity();
                    try d.chains.appendSlice(gpa, k.chains.items);
                    try d.enter(q, top.route_exact, top.route_any, top.kid_range);
                    continue;
                }
                // Done: its trailing uses, its open groups, its children.
                if (top.route_any != .none and top.hi > top.until) try d.out.append(gpa, .{ .lo = top.until, .hi = top.hi, .exact = .none, .any = top.route_any });
                for (d.open.items[top.open_mark..]) |g| if (g.any != .none) try d.out.append(gpa, .{ .lo = g.lo, .hi = g.hi, .exact = g.exact, .any = g.any });
                d.open.shrinkRetainingCapacity(top.open_mark);
                d.nk = top.kids;
                _ = d.frames.pop();
            }
        }

        /// Undo the cursor steps of the child entered from the top frame.
        fn restore(d: *Descent, mark: u32) void {
            std.debug.assert(d.saved.items.len - mark == d.open.items.len);
            for (d.open.items, d.saved.items[mark..]) |*g, cur| g.cur = cur;
            d.saved.shrinkRetainingCapacity(mark);
        }

        /// The top frame's next child worth entering: one with uses below
        /// it, or one an open group still needs a hold from.
        fn nextKid(d: *Descent, top: *Fr) Error!?*Kid {
            const ix = d.ix;
            const gpa = ix.gpa;
            const index = ix.frame.index;
            while (top.next < top.nkids) {
                const k = &d.kids.items[top.kids + top.next];
                top.next += 1;
                try d.steps.append(gpa, k.step);
                try ix.rec(1);
                const r = index.childRange(ix.env.places, .{ .start = top.lo, .len = top.hi - top.lo }, top.depth, k.step);
                const mark: u32 = @intCast(d.saved.items.len);
                var need = false;
                for (d.open.items) |*g| {
                    try d.saved.append(gpa, g.cur);
                    g.cur = try ix.stepCursor(g.cur, k.step);
                    if ((g.need_any or g.need_exact) and g.cur != .dead) need = true;
                }
                if (r.len == 0 and !need) {
                    d.restore(mark);
                    d.steps.shrinkRetainingCapacity(top.depth);
                    continue;
                }
                // Uses between the last child and this one hold nothing
                // below: the route's approximate hold covers them, if any.
                if (r.len > 0) {
                    if (top.route_any != .none and r.start > top.until) try d.out.append(gpa, .{ .lo = top.until, .hi = r.start, .exact = .none, .any = top.route_any });
                    top.until = @max(top.until, r.start + r.len);
                }
                top.cur_mark = mark;
                top.kid_range = r;
                return k;
            }
            return null;
        }

        /// Enter path `q` with `states` and `chains`: its holds, then its
        /// uses, then (unless an exact hold on the route covers all below)
        /// its children as a new frame.
        fn enter(d: *Descent, q: PathId, route_exact_in: PathId, route_any_in: PathId, all: Ids.Range) (Error || Fallback)!void {
            const ix = d.ix;
            const gpa = ix.gpa;
            const index = ix.frame.index;
            const places = ix.env.places;
            try ix.rec(1);
            var route_exact = route_exact_in;
            var route_any = route_any_in;
            const at_q: Ids.Range = .{ .start = all.start, .len = index.exactEnd(all, @intCast(d.steps.items.len)) - all.start };
            d.pending.clearRetainingCapacity();
            var hold_any = false;
            var hold_exact = false;
            for (d.chains.items) |ch| if (ch.k == d.ext.items.len) {
                hold_any = true;
                hold_exact = hold_exact or ch.exact;
            } else try d.pending.append(gpa, ch);
            if (d.bits.any) {
                var f = q;
                for (d.ext.items) |st| f = try ix.child(f, st);
                const exact = ix.bitsExact(f, d.bits, d.x, d.c);
                if (d.ext.items.len == 0) {
                    hold_any = true;
                    hold_exact = hold_exact or exact;
                } else try d.pending.append(gpa, .{ .f = f, .exact = exact, .k = 0 });
            }
            if (hold_any) {
                if (route_any == .none) route_any = q;
                if (hold_exact and route_exact == .none) route_exact = q;
                // The first hold below each open group, in canonical order.
                for (d.open.items) |*g| {
                    if (!(g.need_any or (hold_exact and g.need_exact)) or !try ix.accepts(g.cur)) continue;
                    if (g.need_any) g.any = q;
                    g.need_any = false;
                    if (hold_exact and g.need_exact) {
                        g.exact = q;
                        g.need_exact = false;
                    }
                }
            }
            if (route_exact != .none) {
                if (all.len > 0) try d.out.append(gpa, .{ .lo = all.start, .hi = all.start + all.len, .exact = route_exact, .any = route_any });
                return;
            }
            const open_mark: u32 = @intCast(d.open.items.len);
            var j = at_q.start;
            const a = at_q.start + at_q.len;
            while (j < a) {
                const e = index.groupEnd(j, a);
                const u = index.get(.from(j));
                // Exits are outside this walk's order (§2.7): list the holds.
                if ((try ix.exits.exits(ix.tables(), q, if (u.kind == .call) u.use_node else .none)).len > 0) return error.Fallback;
                const cur: Cursor = if (!index.filtered(j)) .free else .{ .node = u.use_node };
                try d.open.append(gpa, .{ .lo = j, .hi = e, .any = route_any, .need_exact = true, .need_any = route_any == .none, .cur = cur });
                j = e;
            }
            const first_kid: u32 = d.nk;
            for (d.states.items) |s| {
                // By index: `expand` may grow `kid_cache` under the loop.
                var ki: u32 = 0;
                while (ki < s.kids.len) : (ki += 1) {
                    const en = ix.kid_cache.items[s.kids.start + ki];
                    const st = Step.fromWord(en[0]);
                    // A step read is a real child of its node: a stale read
                    // would fall back silently to listing holds.
                    if (std.debug.runtime_safety) {
                        const nk = ix.env.shapes.get(s.node);
                        std.debug.assert(ix.env.shapes.overGet(if (nk.kind == .node) nk.a else nk.b, st) == NodeId.from(en[1]));
                    }
                    _ = try ix.child(q, st);
                    const k = try kidFor(d, first_kid, st);
                    try ix.expand(.{ .node = .from(en[1]), .alt = s.alt, .cast = s.cast, .blur = s.blur }, d.x, d.c, &k.states, &k.bits);
                }
            }
            for (d.pending.items) |ch| {
                const k = try kidFor(d, first_kid, d.ext.items[ch.k]);
                try k.chains.append(gpa, .{ .f = ch.f, .exact = ch.exact, .k = ch.k + 1 });
            }
            std.mem.sort(Kid, d.kids.items[first_kid..d.nk], @as(*const Cell.Places, places), struct {
                fn less(p: *const Cell.Places, x: Kid, y: Kid) bool {
                    return p.stepLess(x.step, y.step);
                }
            }.less);
            try d.frames.append(gpa, .{ .q = q, .depth = @intCast(d.steps.items.len), .route_exact = route_exact, .route_any = route_any, .lo = all.start, .hi = all.start + all.len, .until = a, .open_mark = open_mark, .kids = first_kid, .nkids = d.nk - first_kid });
        }
    };

    fn kidFor(d: *Descent, from: u32, st: Step) Allocator.Error!*Kid {
        for (d.kids.items[from..d.nk]) |*k| if (k.step.word() == st.word()) return k;
        // A slot made before keeps its lists' memory.
        if (d.nk < d.kids.items.len) {
            d.nk += 1;
            const k = &d.kids.items[d.nk - 1];
            k.step = st;
            k.bits = .{};
            k.states.clearRetainingCapacity();
            k.chains.clearRetainingCapacity();
            return k;
        }
        try d.kids.append(d.ix.gpa, .{ .step = st });
        d.nk += 1;
        return &d.kids.items[d.nk - 1];
    }

    /// A callee's use shape one step down (§2.7's `call` filter): decided
    /// at a leaf, read on where the place graph cannot follow.
    fn stepCursor(ix: *Index, cur: Cursor, st: Step) Error!Cursor {
        const n = switch (cur) {
            .free, .dead => return cur,
            .node => |n| n,
        };
        try ix.rec(1);
        const shapes = ix.env.shapes;
        if (shapes.kind(n) == .leaf) return if (shapes.cells(n) != .none) .free else .dead;
        // A node marked `D` reads every path below it, as a leaf does
        // (§2.10, *A deep read across a call*), and so, for this frame's
        // liveness, does a node marked `A`: the call's result holds the
        // object there, and its later reads are not uses of the argument's
        // local (§2.7, *A part a callee answers*).
        if (ix.env.cells.readsBelow(try shapes.cellsOf(ix.gpa, ix.env.account(), &ix.env.cells.sets, n))) return .free;
        const p = (try shapes.proj(ix.gpa, ix.env.account(), ix.env.places, ix.env.cells, n, st)) orelse return .free;
        return .{ .node = p };
    }

    fn accepts(ix: *Index, cur: Cursor) Error!bool {
        return switch (cur) {
            .free => true,
            .dead => false,
            .node => |n| ix.env.shapes.cells(n) != .none,
        };
    }

    /// The holds of `x` in `h`'s value, every path listed (today's walk):
    /// the fallback and the naive scan's.
    fn holdsAll(ix: *Index, h: Holder, x: CellId, c: CellId, out: *std.ArrayList(struct { PathId, bool })) Error!void {
        const F = struct { node: NodeId, path: PathId, alt: bool = false, cast: bool = false, blur: bool = false };
        const gpa = ix.gpa;
        var stack: std.ArrayList(F) = .empty;
        defer stack.deinit(gpa);
        var seen: Ids.FixedDict(3) = .{};
        defer seen.deinit(gpa);
        var ext: std.ArrayList(Step) = .empty;
        defer ext.deinit(gpa);
        const lead = try ix.extSteps(x, c, &ext);
        const shapes = ix.env.shapes;
        const places = ix.env.places;
        try stack.append(gpa, .{ .node = h.value.node, .path = h.root });
        while (stack.pop()) |f| {
            try ix.rec(1);
            if (!ix.env.cells.sets.member(try ix.reach(f.node), x.int())) continue;
            if (try ix.holdAt(.{ .node = f.node, .alt = f.alt, .blur = f.blur }, x, c)) |hd| {
                var at = f.path;
                for (ext.items, 0..) |st, i| {
                    const e = try places.extend(gpa, ix.env.charge, at, st);
                    at = e orelse if (i == 0 and lead) at else break;
                }
                try out.append(gpa, .{ at, ix.holdExact(at, hd.approx, hd.several, x, c) });
            }
            const k = shapes.get(f.node);
            const flags: u32 = @as(u32, @intFromBool(f.alt)) | @as(u32, @intFromBool(f.cast)) << 1 | @as(u32, @intFromBool(f.blur)) << 2;
            if ((try seen.getOrPut(gpa, .{ f.node.int(), f.path.int(), flags })).found_existing) continue;
            switch (k.kind) {
                .leaf => {},
                .node, .delta => {
                    if (k.kind == .delta) try stack.append(gpa, .{ .node = .from(k.a), .path = f.path, .cast = f.cast, .blur = f.blur, .alt = f.alt });
                    var it = shapes.overEntries(if (k.kind == .node) k.a else k.b);
                    while (it.next()) |e| {
                        const ex = try places.extend(gpa, ix.env.charge, f.path, e.step);
                        const p = ex orelse if (f.cast) f.path else continue;
                        try stack.append(gpa, .{ .node = e.node, .path = p, .cast = f.cast, .blur = f.blur or ex == null, .alt = f.alt });
                    }
                },
                .recast => try stack.append(gpa, .{ .node = .from(k.a), .path = f.path, .cast = true, .blur = f.blur, .alt = f.alt }),
                .view => {
                    var g = f;
                    g.node = try shapes.force(gpa, ix.env.account(), f.node);
                    try stack.append(gpa, g);
                },
                .@"union", .choice, .positions => {
                    const alt = f.alt or k.kind == .@"union" or k.kind == .choice;
                    try stack.appendSlice(gpa, &.{ .{ .node = .from(k.a), .path = f.path, .alt = alt, .cast = f.cast, .blur = f.blur }, .{ .node = .from(k.b), .path = f.path, .alt = alt, .cast = f.cast, .blur = f.blur } });
                },
            }
        }
    }

    /// Whether a use covers a hold at `f` (§2.7): above it always, under it
    /// where its callee reads the rest, and at its exits on a cycle.
    fn covers(ix: *Index, use: Facts.Use, f: PathId) Error!bool {
        return ix.exits.covers(ix.tables(), use, f);
    }

    fn tables(ix: *Index) Exits.Tables {
        return .{ .gpa = ix.gpa, .charge = ix.env.charge, .places = ix.env.places, .shapes = ix.env.shapes, .cells = ix.env.cells };
    }

    /// The cover from every hold listed, against every group of the
    /// local's uses: holds × groups.
    fn coverNaive(ix: *Index, h: Holder, x: CellId, c: CellId, out: *std.ArrayList(Block)) Error!void {
        var holds: std.ArrayList(struct { PathId, bool }) = .empty;
        defer holds.deinit(ix.gpa);
        try ix.holdsAll(h, x, c, &holds);
        if (holds.items.len == 0) return;
        const index = ix.frame.index;
        const all = index.rangeOf(ix.env.places, h.who, &.{}, true);
        var j = all.start;
        while (j < all.start + all.len) {
            const e = index.groupEnd(j, all.start + all.len);
            const use = index.get(.from(j));
            var best_e: PathId = .none;
            var best_a: PathId = .none;
            for (holds.items) |hd| {
                try ix.rec(1);
                if (!try ix.covers(use, hd[0])) continue;
                if (best_a == .none or ix.pathOrder(hd[0], best_a) == .lt) best_a = hd[0];
                if (hd[1] and (best_e == .none or ix.pathOrder(hd[0], best_e) == .lt)) best_e = hd[0];
            }
            if (best_a != .none) try out.append(ix.gpa, .{ .lo = j, .hi = e, .exact = best_e, .any = best_a });
            j = e;
        }
    }

    // ---- the canonical order (§2.8 *Verdicts*) ------------------------------

    /// Two paths step by step from the root, a prefix first; `none` first.
    fn pathOrder(ix: *const Index, a: PathId, b: PathId) std.math.Order {
        if (a == b) return .eq;
        if (a == .none) return .lt;
        if (b == .none) return .gt;
        const places = ix.env.places;
        var x = a;
        var y = b;
        var dx = places.pathDepth(a);
        var dy = places.pathDepth(b);
        const tie = std.math.order(dx, dy);
        while (dx > dy) : (dx -= 1) x = places.pathParent(x);
        while (dy > dx) : (dy -= 1) y = places.pathParent(y);
        if (x == y) return tie;
        var sx: Step = undefined;
        var sy: Step = undefined;
        while (x != y) {
            sx = places.pathStep(x);
            sy = places.pathStep(y);
            x = places.pathParent(x);
            y = places.pathParent(y);
        }
        if (sx.word() == sy.word()) return .eq;
        return if (places.stepLess(sx, sy)) .lt else .gt;
    }

    fn winOrder(ix: *const Index, a: Win, b: Win) std.math.Order {
        if (a.point != b.point) return std.math.order(a.point, b.point);
        if (a.start != b.start) return std.math.order(a.start, b.start);
        const p = ix.pathOrder(a.path, b.path);
        if (p != .eq) return p;
        if (a.holder != b.holder) return std.math.order(a.holder, b.holder);
        return std.math.order(a.atom, b.atom);
    }

    /// Keep the least of `best` and `w`; on a tie (one hold, several notes)
    /// it is `element` only if every note is (§2.8 condition 5).
    fn fold(ix: *const Index, best: *?Win, w: Win) void {
        const b = best.* orelse {
            best.* = w;
            return;
        };
        if (b.exact != w.exact) {
            if (w.exact) best.* = w;
            return;
        }
        switch (ix.winOrder(w, b)) {
            .lt => best.* = w,
            .eq => best.*.?.element = b.element and w.element,
            .gt => {},
        }
    }

    fn winOf(ix: *const Index, e: u32, class: u1) Win {
        const x = ix.entries.items[e];
        return .{ .holder = x.holder, .point = x.point, .start = x.start, .path = if (class == 0) x.exact_path else x.any_path, .use = x.use, .atom = x.atom, .element = class == 1 and x.element };
    }

    fn entryLess(ix: *const Index, a: u32, b: u32, class: u1) bool {
        if (a == none) return false;
        if (b == none) return true;
        return ix.winOrder(ix.winOf(a, class), ix.winOf(b, class)) == .lt;
    }

    // ---- the trees and the sweep (§2.8 *The sweep*) --------------------------

    fn buildTrees(ix: *Index) Error!void {
        const gpa = ix.gpa;
        try ix.rec(@intCast(ix.entries.items.len));
        std.mem.sort(Entry, ix.entries.items, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return a.tree < b.tree or (a.tree == b.tree and (a.rank2 < b.rank2 or (a.rank2 == b.rank2 and a.atom < b.atom)));
            }
        }.less);
        for (ix.entries.items, 0..) |e, i| {
            const t = &ix.trees.items[e.tree];
            if (t.n == 0) t.first = @intCast(i);
            t.n += 1;
        }
        for (ix.trees.items) |*t| {
            t.cap = 1;
            while (t.cap < t.n) t.cap *= 2;
            t.off = @intCast(ix.nodes.items.len);
            try ix.nodes.appendNTimes(gpa, .{ none, none, none, none }, 2 * t.cap);
        }
        for (ix.entries.items, 0..) |e, i| {
            try ix.events.append(gpa, .{ .point = e.start, .phase = 2, .kind = .enter, .ref = @intCast(i) });
            try ix.events.append(gpa, .{ .point = e.until, .phase = 0, .kind = .retire, .ref = @intCast(i) });
        }
        for (ix.frame.demands, 0..) |dm, d| if (ix.dem_occ[d].len > 0) try ix.events.append(gpa, .{ .point = dm.point, .phase = 1, .kind = .demand, .ref = @intCast(d) });
        std.mem.sort(Event, ix.events.items, {}, struct {
            fn less(_: void, a: Event, b: Event) bool {
                if (a.point != b.point) return a.point < b.point;
                if (a.phase != b.phase) return a.phase < b.phase;
                return a.ref < b.ref;
            }
        }.less);
        // Per target its groups.
        const gs = try gpa.alloc(u32, ix.groups.items.len);
        defer gpa.free(gs);
        for (gs, 0..) |*g, i| g.* = @intCast(i);
        std.mem.sort(u32, gs, ix.groups.items, struct {
            fn less(groups: []const Group, a: u32, b: u32) bool {
                return groups[a].target < groups[b].target or (groups[a].target == groups[b].target and a < b);
            }
        }.less);
        for (gs) |g| {
            const t = &ix.targets.items[ix.groups.items[g].target];
            if (t.groups.len == 0) t.groups.start = @intCast(ix.tg.items.len);
            t.groups.len += 1;
            try ix.tg.append(gpa, g);
        }
    }

    fn merge(ix: *const Index, a: [4]u32, b: [4]u32) [4]u32 {
        var out: [4]u32 = undefined;
        for ([_]u1{ 0, 1 }) |class| {
            const o: usize = @as(usize, class) * 2;
            const cands = [4]u32{ a[o], a[o + 1], b[o], b[o + 1] };
            var best: u32 = none;
            for (cands) |c| if (ix.entryLess(c, best, class)) {
                best = c;
            };
            var second: u32 = none;
            if (best != none) for (cands) |c| if (c != none and ix.entries.items[c].split != ix.entries.items[best].split and ix.entryLess(c, second, class)) {
                second = c;
            };
            out[o] = best;
            out[o + 1] = second;
        }
        return out;
    }

    fn setLeaf(ix: *Index, e: u32, on: bool) Error!void {
        try ix.rec(1);
        const x = ix.entries.items[e];
        const t = ix.trees.items[x.tree];
        var i = t.cap + (e - t.first);
        const v: [4]u32 = if (!on) .{ none, none, none, none } else .{ if (x.exact_ok) e else none, none, e, none };
        const nodes = ix.nodes.items[t.off..][0 .. 2 * t.cap];
        nodes[i] = v;
        while (i > 1) {
            i /= 2;
            nodes[i] = ix.merge(nodes[2 * i], nodes[2 * i + 1]);
        }
    }

    /// The tree's best entries over leaves `[lo, hi)`.
    fn query(ix: *Index, tree: u32, lo: u32, hi: u32) Error![4]u32 {
        try ix.rec(1);
        const t = ix.trees.items[tree];
        const nodes = ix.nodes.items[t.off..][0 .. 2 * t.cap];
        var acc: [4]u32 = .{ none, none, none, none };
        var l = lo + t.cap;
        var r = hi + t.cap;
        while (l < r) : ({
            l /= 2;
            r /= 2;
        }) {
            if (l & 1 == 1) {
                acc = ix.merge(acc, nodes[l]);
                l += 1;
            }
            if (r & 1 == 1) {
                r -= 1;
                acc = ix.merge(acc, nodes[r]);
            }
        }
        return acc;
    }

    /// The first leaf of `tree` with `rank₂` above `t`.
    fn above(ix: *const Index, tree: u32, t: u32) u32 {
        const tr = ix.trees.items[tree];
        return @intCast(std.sort.partitionPoint(Entry, ix.entries.items[tr.first..][0..tr.n], t, struct {
            fn f(bound: u32, e: Entry) bool {
                return e.rank2 <= bound;
            }
        }.f));
    }

    fn below_(ix: *const Index, tree: u32, t: u32) u32 {
        const tr = ix.trees.items[tree];
        return @intCast(std.sort.partitionPoint(Entry, ix.entries.items[tr.first..][0..tr.n], t, struct {
            fn f(bound: u32, e: Entry) bool {
                return e.rank2 < bound;
            }
        }.f));
    }

    fn take(ix: *const Index, v: [4]u32, exclude: ?SplitId, best: *[2]?Win) void {
        for ([_]u1{ 0, 1 }) |class| {
            const o: usize = @as(usize, class) * 2;
            var e = v[o];
            if (exclude) |s| if (e != none and ix.entries.items[e].split == s.int()) {
                e = v[o + 1];
            };
            if (e != none) ix.fold(&best[class], ix.winOf(e, class));
        }
    }

    fn sweep(ix: *Index, out: []Answer, splits: *std.ArrayList(SplitId)) Error!void {
        var relied: std.ArrayList(SplitId) = .empty;
        defer relied.deinit(ix.gpa);
        for (ix.events.items) |ev| switch (ev.kind) {
            .retire => try ix.setLeaf(ev.ref, false),
            .enter => try ix.setLeaf(ev.ref, true),
            .inc => ix.counts.items[ev.ref] += 1,
            .dec => ix.counts.items[ev.ref] -= 1,
            .demand => {
                relied.clearRetainingCapacity();
                out[ev.ref] = try ix.resolve(ev.ref, &relied);
                std.mem.sort(SplitId, relied.items, {}, struct {
                    fn less(_: void, a: SplitId, b: SplitId) bool {
                        return a.int() < b.int();
                    }
                }.less);
                const start: u32 = @intCast(splits.items.len);
                for (relied.items, 0..) |s, i| if (i == 0 or s != relied.items[i - 1]) try splits.append(ix.gpa, s);
                out[ev.ref].splits = .{ .start = start, .len = @as(u32, @intCast(splits.items.len)) - start };
            },
        };
    }

    /// One demand's answer at its point, from its targets' groups (§2.8).
    fn resolve(ix: *Index, d: u32, relied: *std.ArrayList(SplitId)) Error!Answer {
        const dm = ix.frame.demands[d];
        const t2 = ix.rank2(dm.point);
        const bt = ix.baseTaken(dm);
        var a: Answer = .{};
        var best: ?Win = null;
        const run = ix.dem_occ[d];
        for (ix.docc.items[run.start..][0..run.len]) |j| {
            const o = ix.occ.items[j];
            const tgt = ix.targets.items[o.target];
            var cand = ix.acc.items[j];
            for (ix.sibs.items[tgt.sibs.start..][0..tgt.sibs.len]) |s| {
                try ix.rec(1);
                if (ix.count(sib_tag | s.kid, none, none) > ix.count(sib_tag | s.kid, s.self.int(), none)) try relied.append(ix.gpa, s.split);
            }
            for (ix.tg.items[tgt.groups.start..][0..tgt.groups.len]) |g| {
                try ix.rec(1);
                const grp = ix.groups.items[g];
                switch (grp.how) {
                    .no => {},
                    .under => |s| if (ix.count(g, none, none) > 0) try relied.append(ix.gpa, s),
                    .under_kappa => if (ix.count(g, none, none) > 0) {
                        a.lost = true;
                    },
                    .yes => {
                        var ex: ?SplitId = null;
                        if (bt) |b| if (ix.env.cells.sets.member(b.explicit, grp.x.int())) {
                            ex = b.split;
                            if (ix.count(g, b.split.int(), none) > ix.count(g, b.split.int(), b.pos)) try relied.append(ix.gpa, b.split);
                        };
                        if (grp.ord != none) {
                            ix.take(try ix.query(grp.ord, ix.above(grp.ord, t2), ix.trees.items[grp.ord].n), ex, &cand);
                            if (ex) |s| if (ix.tree_of.get(.{ g, 2, s.int(), bt.?.pos })) |st| ix.take(try ix.query(st, ix.above(st, t2), ix.trees.items[st].n), null, &cand);
                        }
                        if (grp.pend != none) ix.take(try ix.query(grp.pend, 0, ix.below_(grp.pend, t2)), null, &cand);
                    },
                }
            }
            var w: ?Win = null;
            if (!o.forced and cand[0] != null) {
                w = cand[0];
                w.?.exact = true;
            } else if (cand[1]) |x| {
                w = x;
                w.?.exact = false;
                // A base cell only possibly in the base: every hold of it is.
                if (o.maybe) w.?.element = true;
            }
            if (w) |x| ix.fold(&best, x);
        }
        a.win = best;
        return a;
    }

    // ---- the naive scan (the safety net, not the argument) -----------------

    fn crossCheck(ix: *Index, wanted: []const bool, out: []const Answer, splits: []const SplitId) Error!void {
        // Its own account: the check never changes what the walk charges.
        var scratch: Ids.Account = .{ .allowance = std.math.maxInt(u32) };
        defer scratch.deinit(ix.gpa);
        const real = ix.env;
        ix.env.charge = .growth(&scratch);
        defer ix.env = real;
        var relied: std.ArrayList(SplitId) = .empty;
        defer relied.deinit(ix.gpa);
        for (ix.frame.demands, 0..) |dm, d| {
            if (!wanted[d]) continue;
            relied.clearRetainingCapacity();
            var lost = false;
            const w = try ix.naive(dm, &relied, &lost);
            std.mem.sort(SplitId, relied.items, {}, struct {
                fn less(_: void, a: SplitId, b: SplitId) bool {
                    return a.int() < b.int();
                }
            }.less);
            var n: usize = 0;
            for (relied.items, 0..) |s, i| if (i == 0 or s != relied.items[i - 1]) {
                relied.items[n] = s;
                n += 1;
            };
            const got = out[d];
            const same_splits = std.mem.eql(SplitId, relied.items[0..n], splits[got.splits.start..][0..got.splits.len]);
            const same_win = if (w) |x| (got.win != null and std.meta.eql(x, got.win.?)) else got.win == null;
            if (!same_splits or lost != got.lost or !same_win) std.debug.panic("ownership v2: the holder index differs from the naive scan at demand {d} (point {d}): index {any} / naive {any}", .{ d, dm.point, got.win, w });
        }
    }

    fn naive(ix: *Index, dm: Demand, relied: *std.ArrayList(SplitId), lost: *bool) Error!?Win {
        const gpa = ix.gpa;
        const cellt = ix.env.cells;
        const deep = dm.kind.isDeep();
        const base = if (deep) try ix.reach(dm.base.node) else try ix.env.shapes.cellsOf(gpa, ix.env.account(), &cellt.sets, dm.base.node);
        const alternatives = !deep and several(cellt, base);
        const p = dm.point;
        var best: ?Win = null;
        var ks: std.ArrayList(Key) = .empty;
        defer ks.deinit(gpa);
        var cands: std.ArrayList(CellId) = .empty;
        defer cands.deinit(gpa);
        var hks: std.ArrayList(Key) = .empty;
        defer hks.deinit(gpa);
        var looks: std.ArrayList(Look) = .empty;
        defer looks.deinit(gpa);
        var holds: std.ArrayList(struct { PathId, bool }) = .empty;
        defer holds.deinit(gpa);
        const index = ix.frame.index;
        var it = cellt.sets.iterate(base);
        while (it.next()) |e| {
            const c: CellId = .from(e.key);
            const forced = alternatives or e.value == 1;
            ks.clearRetainingCapacity();
            looks.clearRetainingCapacity();
            try ix.targetKeys(c, deep, &ks, &looks);
            // Candidates: the static ones, and every live holder's cell a
            // key names: an anchor, or a refinement chain (any member, its
            // own conflict decides).
            cands.clearRetainingCapacity();
            try cands.append(gpa, try cellt.top(gpa, ix.env.account()));
            for (ks.items) |k| if (k[0] == 0) try cands.append(gpa, .from(k[1]));
            for (ix.frame.holders) |h| {
                if (h.value.node == .none or !(h.start < p and p <= h.end)) continue;
                var hit = cellt.sets.iterate(try ix.reach(h.value.node));
                while (hit.next()) |hx| {
                    const y: CellId = .from(hx.key);
                    hks.clearRetainingCapacity();
                    try ix.anchorsOf(y, &hks);
                    for (hks.items) |hk| for (ks.items) |k| if (std.mem.eql(u32, &hk, &k)) try cands.append(gpa, y);
                    if (try ix.refKey(y)) |rk| for (looks.items) |l| if (std.mem.eql(u32, &rk, &l.key) and y != l.self) try cands.append(gpa, y);
                }
            }
            std.mem.sort(CellId, cands.items, {}, struct {
                fn less(_: void, a: CellId, b: CellId) bool {
                    return a.int() < b.int();
                }
            }.less);
            for (cands.items, 0..) |x, ci| {
                if (ci > 0 and x == cands.items[ci - 1]) continue;
                const how = ix.conflict(x, c, deep);
                if (how == .no) continue;
                for (ix.frame.holders, 0..) |h, hi| {
                    if (h.value.node == .none or !(h.start < p and p <= h.end)) continue;
                    const r = try ix.reach(h.value.node);
                    if (!cellt.sets.member(r, x.int())) continue;
                    if (cellt.origin(x) == .top) {
                        var reached = false;
                        for (cands.items) |y| {
                            if (cellt.origin(y) != .top and cellt.sets.member(r, y.int()) and ix.conflict(y, c, deep) != .no) reached = true;
                        }
                        if (!reached) continue;
                    }
                    switch (how) {
                        .no => unreachable,
                        .under => |s| {
                            try relied.append(gpa, s);
                            continue;
                        },
                        .under_kappa => {
                            lost.* = true;
                            continue;
                        },
                        .yes => if (ix.excluded(dm, h, x)) |s| {
                            try relied.append(gpa, s);
                            continue;
                        },
                    }
                    var w: ?Win = null;
                    if (h.kind == .pending) {
                        if (h.start < p and p < h.end and ix.frame.regions.compatible(h.start, p)) w = .{ .holder = @intCast(hi), .point = h.start, .start = h.start, .exact = !forced and cellt.origin(x) != .top };
                        if (w) |x_| ix.fold(&best, x_);
                        continue;
                    }
                    holds.clearRetainingCapacity();
                    try ix.holdsAll(h, x, c, &holds);
                    const all = index.rangeOf(ix.env.places, h.who, &.{}, true);
                    var i = all.start;
                    while (i < all.start + all.len) : (i += 1) {
                        const use = index.get(.from(i));
                        if (use.point <= p or ix.rank2(use.point) <= ix.rank2(p)) continue;
                        for (holds.items) |hd| {
                            if (!try ix.covers(use, hd[0])) continue;
                            const exact = hd[1] and !forced;
                            ix.fold(&best, .{ .holder = @intCast(hi), .point = use.point, .start = h.start, .path = hd[0], .use = .from(i), .atom = use.atom, .exact = exact, .element = !hd[1] or e.value == 1 });
                        }
                    }
                }
            }
        }
        return best;
    }
};

/// Whether a cell set has two members or more: alternatives, of which a
/// conflict on one is only possible (an approximate refusal, R-6.3).
pub fn several(cellt: *const Cell.Table, s: SetId) bool {
    var it = cellt.sets.iterate(s);
    return it.next() != null and it.next() != null;
}

/// A refinement a split took: one position, not the summary.
fn isMaterialised(cellt: *const Cell.Table, c: CellId) bool {
    var at = c;
    // A recursive child of a taken position is that position's own.
    while (cellt.origin(at) == .below) at = cellt.parent(at);
    const o = cellt.origin(at);
    return o == .elem or o == .level;
}

/// A symbolic cell at or below a summary position (`[*]`, `⟲`).
fn stands(cellt: *const Cell.Table, places: *const Cell.Places, c: CellId) bool {
    const x = cellt.get(c);
    return x.origin.isSymbolic() and x.origin != .top and places.isSummary(.from(x.b));
}

comptime {
    Ids.assertRecord(Demand);
    Ids.assertRecord(Holder);
}
