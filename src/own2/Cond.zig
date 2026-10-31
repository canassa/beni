//! L6: conditions, the exclusivity κ of a value's contents
//! (`docs/design/ownership-v2.md` §2.9, §3.4). Each shape node of a value
//! carries a condition saying whether the objects at the node's path are
//! exclusive: `yes`, a conjunction of atoms over arrivals, `shared` (fails
//! exactly: one cell at two positions) or `lost` (fails approximately).
//!
//! **κ is owned by its holder, never by the node** (nodes are interned: one
//! node stands in two values with two conditions): a persistent map
//! `(NodeId, position class) → CondId` (`Kappas`) a frame or a class owns
//! and threads (`kappaSet` returns the new root). **A read is the join of
//! the stored κ with the κ DERIVED at the read's position from the node's
//! cells**: a stored κ adds constraints and never weakens the derivation
//! (the key's position class is precision, not soundness). Derivation is
//! charged per read, never stored: at a plain path a leaf is `yes`; at a
//! summary position (`[*]`/`⟲` on the way) its arrivals must be `apart`
//! and each standing for many positions `excl`; `⊤`/approximate is `lost`;
//! a `union` (alternatives) is the join of its sides, once per node per
//! read, plus the leaf rule over its united cells at a summary position; a
//! `positions` node (`Shape.collect`: elements that coexist) the same over
//! the MULTISET of its sides' cells wherever it sits — a cell in both sides
//! is two positions, `shared` (`lost` if approximate): `[ x, x ]`; a recast
//! is `lost` where its place holds objects below; a node or delta `lost`
//! until the walk sets it (O13). **Atoms are per path** (§2.9, R-4.6.4):
//! `sep`/`apart` speak of their own path, a write relies on that path's κ
//! only, a caller discharges `sep` by comparing the arrivals' cells there
//! (`Interp`); `excl c` alone is deep. `and` is the O(1) binary node a
//! store forms; `join` the lattice join `yes ⊑ and{A} ⊑ and{A ∪ B} ⊑ lost
//! ⊑ shared` in canonical form (`ofSet`: one id per atom set, so a fixpoint
//! sees `and(A, A) = A`); `flat` the charged flattening. `apart` decides a
//! construction's multiset in one sort; `lower` is §2.9's rule made
//! incremental (W fresh stores O(W log W)); `propagate` sets κ on a joined
//! node from its members (alternatives: the join; together: a position
//! holding every member, compared over their `reach`); `kappaLeq` simulates
//! over node pairs. Two `taken` elements of one container are apart only
//! under §2.2's one-traversal rule, the caller's `Traversal` (S4). Every
//! record is reserved on the caller's `Charge` before its work (§4.1, §4.4).
//!
//! The table is four files (§5): `CondAlgebra.zig` the condition algebra
//! and the lazy `inst` atoms, `Kappa.zig` κ storage, `KappaRead.zig` κ
//! reads (the machine, views, the crossing, `deep`, `sep`, `apart`,
//! `lower`, the frontier), and this file the table's columns, `propagate`
//! and `widenValue`. Each of the three is `Of(Table)`, methods over this
//! file's `Table`, which binds them by name: a caller sees one `Cond.Table`.
//!
//! Obligations kept here: O13 (a construction's κ is `yes` only when the
//! stored cells are pairwise apart at that path; a stored refinement of the
//! base's own `[*]` is `shared`), O15 (κ(join) is below every member's; a
//! union's κ is its sides' join, derived and never stale); `KappaRead.zig`
//! holds the reads that keep O13 and O15's second half.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Cell = @import("Cell.zig");
const Shape = @import("Shape.zig");
const Stable = @import("Stable.zig");
const stamped = @import("../stamped.zig");
pub const full_cross_check = @import("ownership_options").full_cross_check;
const CondAlgebra = @import("CondAlgebra.zig");
const Kappa = @import("Kappa.zig");
const KappaRead = @import("KappaRead.zig");

pub const CondId = Ids.CondId;
pub const CellId = Ids.CellId;
pub const SetId = Ids.SetId;
pub const NodeId = Ids.NodeId;
pub const LabelId = Ids.LabelId;
pub const Charge = Ids.Charge;
pub const Error = Ids.ChargeError;
pub const Exactness = Facts.Exactness;
pub const Step = Shape.Step;

pub const Kind = CondAlgebra.Kind;
pub const AtomKind = CondAlgebra.AtomKind;
pub const Cond = CondAlgebra.Cond;
pub const yes = CondAlgebra.yes;
pub const shared = CondAlgebra.shared;
pub const lost = CondAlgebra.lost;
pub const Printer = CondAlgebra.Printer;
pub const Rely = CondAlgebra.Rely;
pub const sortText = CondAlgebra.sortText;
pub const Kappas = Kappa.Kappas;
pub const MapNode = Kappa.MapNode;
pub const Traversal = KappaRead.Traversal;
pub const View = KappaRead.View;
pub const Item = KappaRead.Item;
pub const Interp = algebra.Interp;

/// How `propagate` reads a joined node's members: a branch (the lattice
/// join, O15) or a summary position holding every member (`apart` across
/// their cells at every path, and every member's κ).
pub const Mode = enum(u8) { alternatives, together };

const algebra = CondAlgebra.Of(Table);
const storage = Kappa.Of(Table);
const reads = KappaRead.Of(Table);

pub const Table = struct {
    conds: std.MultiArrayList(Cond) = .empty,
    intern: Ids.FixedDict(3) = .{},
    /// The persistent sets of atom ids (`flat`; `apart`'s groups are cell
    /// sets and live in `Cell.Table.sets`).
    atoms: Cell.Radix = .{},
    /// The κ maps' nodes, hash-consed.
    kmaps: std.MultiArrayList(MapNode) = .empty,
    kmap_intern: Ids.FixedDict(4) = .{},
    /// The snapshots' positions, hash-consed (`Kappas` indexes them).
    kpos: std.MultiArrayList(Position) = .empty,
    kpos_intern: Ids.FixedDict(3) = .{},
    /// `flat`'s memo: the atom set of a condition (`.none` for `yes`).
    flat_memo: stamped.Column(CondId, SetId) = .{},
    /// `ofSet`'s memo: the canonical condition of an atom set.
    of_set: Ids.FixedDict(1) = .{},
    /// `deep`'s memo, keyed by the immutable map root, the node and the
    /// position: never stale.
    memo_deep: Ids.FixedDict(3) = .{},
    /// `sep`'s memo for an exact pair with no traversal context; a split's
    /// κ is fixed at its creation (S1), so the answer is too.
    memo_sep: Ids.FixedDict(2) = .{},
    /// `propagate`'s runs, interned across calls: `(member, its position,
    /// the rest)` → a run id. Keys only, never published.
    prop_runs: Ids.FixedDict(3) = .{},
    /// Per run id, `(call, slice)`: the slice a `propagate` call made for
    /// it, read only by that call (each call its own number, #1372).
    prop_slice: std.ArrayList([2]u32) = .empty,
    prop_calls: u32 = 0,
    /// `withoutImpliedJoins`' answers by `(key, condition, position)`: all
    /// three immutable, so never stale.
    memo_implied: Ids.FixedDict(3) = .{},
    /// `propagate`'s join memo (§2.9, *The join memo*): a state `(joined
    /// node, class and mode bits, run)` whose walk is the same wherever it is
    /// met → the snapshot its walk puts at its position. Written only once
    /// a call has finished.
    memo_prop: Ids.FixedDict(3) = .{},
    /// The apart aggregates (#1121): reach memo (with tie epoch), group provenance, `anyLost`.
    aggs: std.ArrayList(Agg) = .empty,
    reach_agg: Ids.FixedDict(1) = .{},
    reach_epoch: Ids.FixedDict(1) = .{},
    group_prov: Ids.FixedDict(1) = .{},
    group_steps: std.ArrayList([2]u32) = .empty,
    lost_memo: Ids.FixedDict(1) = .{},
    /// A folded class's obligation from the path-multiset primitive, by
    /// its image node (`widenValue`, §2.9, #1128).
    fold_cond: stamped.Column(NodeId, CondId) = .{},
    fold_cond_n: u32 = 0,
    /// `foldCondOf` by node.
    fold_of: stamped.Column(NodeId, CondId) = .{},
    /// A client walk's results by `(node, key)` (`classesMemo`).
    classes_memo: Ids.FixedDict(2) = .{},
    classes_done: std.ArrayList(ClassAggs) = .empty,
    /// `dagKappa`'s memo: `(position, node, class)` → its read; the
    /// position and the node are immutable, so it is never stale.
    memo_dag: Ids.FixedDict(3) = .{},
    /// A view's chain join by `(ctx, view)` (`chainStored`), `none` for nothing.
    memo_chain: Ids.FixedDict(2) = .{},
    /// The last position each view's chain join was stored at (`chainStored`),
    /// and the last a `(dag or inner, node, class)` read was stored at
    /// (`memoAt`): where a read at another position may take that entry
    /// (§2.11 *Part 2*, *A read at another position*).
    home_chain: Ids.FixedDict(1) = .{},
    home_read: Ids.FixedDict(3) = .{},
    /// Positions `kappaHoldsView` found view-free, valid while the shape table's
    /// `ties` is `kview_free_epoch`.
    kview_free: Ids.FixedDict(1) = .{},
    kview_free_epoch: u32 = 0,
    /// Node marks for a walk over the node table, one per walk in progress,
    /// emptied by generation: a walk makes no slot an earlier walk made (#1191).
    marks: stamped.Pool(stamped.Column(NodeId, void)) = .{},
    /// `kappaMerge`'s memo: an unordered pair of positions → their merge.
    memo_merge: Ids.FixedDict(2) = .{},
    /// The reads across a call (§2.11 *κ across a call*): a DAG node's sides'
    /// join by `(position, node, class)` (`memo_inner`), its `DagFacts` by node,
    /// the entries a crossed read keeps pending until it is known not to have
    /// seen `base_epoch` move, `eqOn` by `(C, R, region, epoch)` and per pair of
    /// map nodes, `foldBelow` by position, and `mapUnion` by its pair and
    /// `Combine`.
    memo_inner: Ids.FixedDict(3) = .{},
    dag_facts: stamped.Column(NodeId, u32) = .{},
    facts: std.ArrayList(DagFacts) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    /// The memo entries a crossed read made, by key: their value then.
    memo_crossed: Ids.FixedDict(4) = .{},
    memo_eq: Ids.FixedDict(4) = .{},
    memo_fold_below: Ids.FixedDict(1) = .{},
    memo_map_union: Ids.FixedDict(3) = .{},
    memo_diff: Ids.FixedDict(2) = .{},
    memo_map_keys: Ids.FixedDict(1) = .{},
    memo_nodes_part: Ids.FixedDict(3) = .{},
    memo_per_cell: Ids.FixedDict(2) = .{},
    memo_set_agg: Ids.FixedDict(1) = .{},
    memo_cell_part: Ids.FixedDict(2) = .{},
    memo_agg_pair: Ids.FixedDict(2) = .{},
    /// A read made with no crossing (a redo, the cross-check) and with no
    /// memo (the cross-check); and how many reads crossed, and were redone.
    /// The shape table whose nodes key this table's entries, told of each new
    /// key (`keyed`); null: it tracks no relevance, and every node is relevant.
    shapes_hook: ?*Shape.Table = null,
    /// Lazy conditions: the resolver, the `inst` atoms in creation order and
    /// how far they are resolved, and the resolutions by condition.
    resolver: ?Resolver = null,
    inst_queue: std.ArrayList(CondId) = .empty,
    inst_next: u32 = 0,
    memo_resolved: Ids.FixedDict(1) = .{},
    memo_resolved_root: Ids.FixedDict(1) = .{},
    memo_inst_latest: Ids.FixedDict(1) = .{},
    no_cross: bool = false,
    no_memo: bool = false,
    /// Off while a construction tests whether a dropped node's entry needs
    /// carrying (`TransferConstruct.carryDropped`): its reads are the test.
    drop_check_off: bool = false,
    crossed_reads: u32 = 0,
    crossed_redos: u32 = 0,
    /// For tests: every position a reader (`deep`, `propagate`,
    /// `kappaLeq`) reads, as `node << 1 | class`, so a test can compare
    /// the frontiers they walk.
    trace: ?*std.ArrayList(u32) = null,

    comptime {
        Ids.assertRecord(Position);
    }

    /// A table with its three constants, three records in `charge`.
    pub fn init(gpa: Allocator, charge: Charge) Error!Table {
        var t: Table = .{};
        errdefer t.deinit(gpa);
        try charge.reserve(gpa, .cond, 3);
        inline for (.{ Kind.yes, Kind.shared, Kind.lost }) |k| {
            const got = try t.intern.getOrPut(gpa, .{ @backingInt(k), 0, 0 });
            got.value_ptr.* = @intCast(t.conds.len);
            try t.conds.append(gpa, .{ .kind = k, .atom = .excl, .a = 0, .b = 0 });
        }
        return t;
    }

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.marks.deinit(gpa);
        t.conds.deinit(gpa);
        t.intern.deinit(gpa);
        t.atoms.deinit(gpa);
        t.kmaps.deinit(gpa);
        t.kmap_intern.deinit(gpa);
        t.kpos.deinit(gpa);
        t.kpos_intern.deinit(gpa);
        t.flat_memo.deinit(gpa);
        t.of_set.deinit(gpa);
        t.memo_deep.deinit(gpa);
        t.memo_sep.deinit(gpa);
        t.prop_runs.deinit(gpa);
        t.prop_slice.deinit(gpa);
        t.memo_prop.deinit(gpa);
        t.memo_implied.deinit(gpa);
        t.aggs.deinit(gpa);
        t.reach_agg.deinit(gpa);
        t.reach_epoch.deinit(gpa);
        t.group_prov.deinit(gpa);
        t.group_steps.deinit(gpa);
        t.lost_memo.deinit(gpa);
        t.fold_cond.deinit(gpa);
        t.classes_memo.deinit(gpa);
        t.classes_done.deinit(gpa);
        t.fold_of.deinit(gpa);
        t.memo_dag.deinit(gpa);
        t.memo_chain.deinit(gpa);
        t.home_chain.deinit(gpa);
        t.home_read.deinit(gpa);
        t.kview_free.deinit(gpa);
        t.memo_merge.deinit(gpa);
        t.memo_inner.deinit(gpa);
        t.dag_facts.deinit(gpa);
        t.facts.deinit(gpa);
        t.pending.deinit(gpa);
        t.memo_crossed.deinit(gpa);
        t.memo_eq.deinit(gpa);
        t.memo_fold_below.deinit(gpa);
        t.memo_map_union.deinit(gpa);
        t.memo_diff.deinit(gpa);
        t.memo_map_keys.deinit(gpa);
        t.memo_nodes_part.deinit(gpa);
        t.memo_per_cell.deinit(gpa);
        t.memo_set_agg.deinit(gpa);
        t.inst_queue.deinit(gpa);
        t.memo_resolved.deinit(gpa);
        t.memo_resolved_root.deinit(gpa);
        t.memo_inst_latest.deinit(gpa);
        t.memo_cell_part.deinit(gpa);
        t.memo_agg_pair.deinit(gpa);
    }

    pub const count = algebra.count;
    pub const get = algebra.get;
    pub const kind = algebra.kind;
    pub const fails = algebra.fails;
    pub const make = algebra.make;
    pub const find = algebra.find;
    pub const @"and" = algebra.@"and";
    pub const excl = algebra.excl;
    pub const sepAtom = algebra.sepAtom;
    pub const within = algebra.within;
    pub const apartAtom = algebra.apartAtom;
    pub const keep = algebra.keep;
    pub const writes = algebra.writes;
    pub const flat = algebra.flat;
    pub const ofSet = algebra.ofSet;
    pub const join = algebra.join;
    pub const leq = algebra.leq;
    pub const expectSame = algebra.expectSame;
    pub const canonical = algebra.canonical;
    pub const Resolver = algebra.Resolver;
    pub const instAtom = algebra.instAtom;
    pub const instSet = algebra.instSet;
    pub const inst_set_bit = algebra.inst_set_bit;
    pub const instFloor = algebra.instFloor;
    pub const resolved = algebra.resolved;
    pub const instLatest = algebra.instLatest;
    pub const resolveTree = algebra.resolveTree;
    pub const drainTo = algebra.drainTo;
    pub const resolveAtom = algebra.resolveAtom;
    pub const assertResolved = algebra.assertResolved;
    pub const instantiate = algebra.instantiate;
    pub const rely = algebra.rely;
    pub const print = algebra.print;
    pub const printAtom = algebra.printAtom;

    pub const mapNode = storage.mapNode;
    pub const makeMap = storage.makeMap;
    pub const matches = storage.matches;
    pub const mapJoin = storage.mapJoin;
    pub const mapGet = storage.mapGet;
    pub const mapPut = storage.mapPut;
    pub const combine = storage.combine;
    pub const mapUnion = storage.mapUnion;
    pub const mapUnionUncached = storage.mapUnionUncached;
    pub const MapIterator = storage.MapIterator;
    pub const mapEntries = storage.mapEntries;
    pub const Position = storage.Position;
    pub const position = storage.position;
    pub const makePos = storage.makePos;
    pub const kappaGet = storage.kappaGet;
    pub const kappaChild = storage.kappaChild;
    pub const kappaAlong = storage.kappaAlong;
    pub const isFold = storage.isFold;
    pub const isCollapsed = storage.isCollapsed;
    pub const fold_exact = storage.fold_exact;
    pub const fold_collapsed = storage.fold_collapsed;
    pub const Set = storage.Set;
    pub const keyed = storage.keyed;
    pub const kappaSet = storage.kappaSet;
    pub const PathOp = storage.PathOp;
    pub const kappaAt = storage.kappaAt;
    pub const kappaSetAt = storage.kappaSetAt;
    pub const withLink = storage.withLink;
    pub const kappaLink = storage.kappaLink;
    pub const kappaMerge = storage.kappaMerge;
    pub const kappaMergeUncached = storage.kappaMergeUncached;
    pub const kappaFold = storage.kappaFold;
    pub const kappaEmptyFold = storage.kappaEmptyFold;
    pub const kappaFoldStep = storage.kappaFoldStep;
    pub const HereIterator = storage.HereIterator;
    pub const kappaHere = storage.kappaHere;
    pub const LinkIterator = storage.LinkIterator;
    pub const kappaLinks = storage.kappaLinks;
    pub const Relabel = storage.Relabel;
    pub const kappaHoldsInst = storage.kappaHoldsInst;
    pub const kappaHoldsView = storage.kappaHoldsView;
    pub const kappaRelabel = storage.kappaRelabel;
    pub const relabelMap = storage.relabelMap;
    pub const relabelOne = storage.relabelOne;

    pub const Pair = reads.Pair;
    pub const DagFacts = reads.DagFacts;
    const isDag = reads.isDag;
    const Pending = reads.Pending;
    pub const memoPut = reads.memoPut;
    pub const memoAt = reads.memoAt;
    pub const readsAlike = reads.readsAlike;
    pub const memoGet = reads.memoGet;
    pub const settle = reads.settle;
    pub const dagFacts = reads.dagFacts;
    pub const dagRoot = reads.dagRoot;
    pub const chainStored = reads.chainStored;
    pub const storedAt = reads.storedAt;
    pub const kappaOf = reads.kappaOf;
    pub const readAt = reads.readAt;
    pub const readAtRaw = reads.readAtRaw;
    pub const crossCheckRead = reads.crossCheckRead;
    pub const crossAt = reads.crossAt;
    pub const carried = reads.carried;
    pub const machine = reads.machine;
    const kappaRead = reads.kappaRead;
    pub const kappaReadOne = reads.kappaReadOne;
    pub const foldBelow = reads.foldBelow;
    pub const eqOn = reads.eqOn;
    pub const eqOnWalk = reads.eqOnWalk;
    pub const mapsEqOn = reads.mapsEqOn;
    pub const diffKeys = reads.diffKeys;
    pub const mapKeys = reads.mapKeys;
    pub const nodesPart = reads.nodesPart;
    pub const sameCond = reads.sameCond;
    pub const linksEq = reads.linksEq;
    pub const derivedCells = reads.derivedCells;
    pub const derivedCellsFlat = reads.derivedCellsFlat;
    pub const cellPart = reads.cellPart;
    pub const setAgg = reads.setAgg;
    pub const aggJoin = reads.aggJoin;
    pub const sep = reads.sep;
    pub const Agg = reads.Agg;
    pub const agg = reads.agg;
    pub const aggAdd = reads.aggAdd;
    pub const aggAll = reads.aggAll;
    pub const aggMerge = reads.aggMerge;
    pub const aggMergeSets = reads.aggMergeSets;
    pub const aggMergeSetsAt = reads.aggMergeSetsAt;
    pub const aggMergeMulti = reads.aggMergeMulti;
    pub const aggCond = reads.aggCond;
    pub const anyLost = reads.anyLost;
    pub const reachAgg = reads.reachAgg;
    pub const reachMemo = reads.reachMemo;
    pub const apartImage = reads.apartImage;
    pub const repeatingSplit = reads.repeatingSplit;
    pub const exclOf = reads.exclOf;
    pub const ClassAggs = reads.ClassAggs;
    pub const classesOf = reads.classesOf;
    pub const classesMerge = reads.classesMerge;
    pub const classesRepeated = reads.classesRepeated;
    pub const classesRead = reads.classesRead;
    pub const classesCells = reads.classesCells;
    pub const classesMemo = reads.classesMemo;
    pub const classesRemember = reads.classesRemember;
    const foldCondOf = reads.foldCondOf;
    pub const foldCondWalk = reads.foldCondWalk;
    pub const foldCond = reads.foldCond;
    const arrivalAggs = reads.arrivalAggs;
    pub const ownAgg = reads.ownAgg;
    pub const aggChoice = reads.aggChoice;
    pub const classMerge = reads.classMerge;
    pub const apart = reads.apart;
    pub const sameBasePairs = reads.sameBasePairs;
    pub const deep = reads.deep;
    pub const deepRaw = reads.deepRaw;
    pub const crossCheckDeep = reads.crossCheckDeep;
    pub const deepWalk = reads.deepWalk;
    pub const crossingsAt = reads.crossingsAt;
    pub const perCell = reads.perCell;
    pub const summaryExcl = reads.summaryExcl;
    pub const shallow = reads.shallow;
    pub const summaryExclFlat = reads.summaryExclFlat;
    pub const shallowFlat = reads.shallowFlat;
    pub const splitGroup = reads.splitGroup;
    pub const lower = reads.lower;
    pub const groupSize2 = reads.groupSize2;
    pub const traced = reads.traced;
    pub const Next = reads.Next;
    pub const frontier = reads.frontier;
    pub const frontierWith = reads.frontierWith;
    pub const CursorSteps = reads.CursorSteps;
    pub const cursorSteps = reads.cursorSteps;
    pub const steps = reads.steps;
    pub const side = reads.side;
    pub const sortCost = reads.sortCost;
    pub const below = reads.below;
    pub const kappaLeq = reads.kappaLeq;
    pub const impliedBy = reads.impliedBy;
    pub const atomsOf = reads.atomsOf;

    /// Whether the entry `k` on union or choice `n` at `cur` adds nothing to
    /// its read: what `n`'s sides read there, joined, is no stronger than `k`
    /// in either class (§2.9 *Keyed where a reader looks*: a join keys its DAG
    /// node, its members' snapshots merged first, so its sides usually imply
    /// it). A fold's obligation is never implied.
    pub fn joinImplied(t: *Table, gpa: Allocator, charge: Charge, v: View, n: NodeId, cur: Kappas, k: CondId) Error!bool {
        // A call's view of a join reads its stored entry joined with its
        // answer's read: implied where the answer's read is no stronger.
        if (v.shapes.kind(n) == .view) {
            const answer = try v.shapes.force(gpa, charge.account, n);
            const ak = v.shapes.kind(answer);
            if (ak != .@"union" and ak != .choice) return false;
            for ([_]bool{ false, true }) |summary| {
                if (!try t.leq(gpa, charge, k, try t.kappaOf(gpa, charge, v, cur, answer, summary))) return false;
            }
            return true;
        }
        const nk = v.shapes.kind(n);
        if (nk != .@"union" and nk != .choice) return false;
        if (t.fold_cond.get(n) != null) return false;
        const d = v.shapes.get(n);
        for ([_]bool{ false, true }) |summary| {
            const a = try t.kappaOf(gpa, charge, v, cur, .from(d.a), summary);
            const b = try t.kappaOf(gpa, charge, v, cur, .from(d.b), summary);
            if (!try t.leq(gpa, charge, k, try t.join(gpa, charge, a, b))) return false;
        }
        return true;
    }

    /// `ctx` without the join entries that read-off would carry onto a new
    /// projection (`imageless`: a union or choice the map did not meet) and
    /// that the reads at their positions show implied (`joinImplied`): every
    /// read the same, and no node made for them (§2.9 *Keyed where a reader
    /// looks*). For a recursive group's read-off, where each round's class
    /// would carry them into the next (#1466). Positions at or below a fold
    /// are kept as they are. Post-order on an explicit stack.
    pub fn withoutImpliedJoins(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, pred: anytype, imageless: *const fn (@TypeOf(pred), NodeId) Error!bool) Error!Kappas {
        if (ctx == .none) return .none;
        var memo: Ids.FixedDict(1) = .{};
        defer memo.deinit(gpa);
        const Frame = struct { at: Kappas, expanded: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        var drop: std.ArrayList(u32) = .empty;
        defer drop.deinit(gpa);
        var spread: std.ArrayList([2]u32) = .empty;
        defer spread.deinit(gpa);
        try stack.append(gpa, .{ .at = ctx, .expanded = false });
        while (stack.pop()) |f| {
            if (memo.get(.{f.at.int()}) != null) continue;
            const p = t.position(f.at);
            if (!f.expanded) {
                try charge.reserve(gpa, .memo, 1);
                try stack.append(gpa, .{ .at = f.at, .expanded = true });
                if (p.fold == 0) {
                    var lt = t.mapEntries(p.links);
                    while (lt.next()) |e| try stack.append(gpa, .{ .at = .from(e.value), .expanded = false });
                }
                continue;
            }
            if (p.fold != 0) {
                (try memo.getOrPut(gpa, .{f.at.int()})).value_ptr.* = f.at.int();
                continue;
            }
            drop.clearRetainingCapacity();
            spread.clearRetainingCapacity();
            var it = t.mapEntries(p.here);
            while (it.next()) |e| {
                const nk = v.shapes.kind(.from(e.key));
                if (nk != .@"union" and nk != .choice and nk != .view) continue;
                if (!try imageless(pred, .from(e.key))) continue;
                try charge.reserve(gpa, .inspection, 1);
                try charge.reserve(gpa, .memo, 1);
                const mk: [3]u32 = .{ e.key, e.value, f.at.int() };
                const implied = if (t.memo_implied.get(mk)) |hit| hit == 1 else blk: {
                    const got = try t.joinImplied(gpa, charge, v, .from(e.key), f.at, .from(e.value));
                    (try t.memo_implied.getOrPut(gpa, mk)).value_ptr.* = @intFromBool(got);
                    break :blk got;
                };
                if (implied) {
                    try drop.append(gpa, e.key);
                    continue;
                }
                // Not implied: the entry joins each side the map met, so its
                // reads keep it with no projection made (a side read alone is
                // read nowhere, §2.9). A side the map did not meet keeps the
                // entry where it is, carried by projection.
                const first = spread.items.len;
                var all = true;
                var sides: std.ArrayList(NodeId) = .empty;
                defer sides.deinit(gpa);
                try sides.append(gpa, if (nk == .view) try v.shapes.force(gpa, charge.account, .from(e.key)) else .from(e.key));
                var seen: u32 = 0;
                while (sides.pop()) |x| {
                    seen += 1;
                    try charge.reserve(gpa, .inspection, 1);
                    const xk = v.shapes.kind(x);
                    if (xk == .@"union" or xk == .choice or xk == .positions) {
                        const d = v.shapes.get(x);
                        try sides.appendSlice(gpa, &.{ .from(d.a), .from(d.b) });
                        continue;
                    }
                    if (seen > 256 or try imageless(pred, x)) {
                        all = false;
                        break;
                    }
                    try spread.append(gpa, .{ x.int(), e.value });
                }
                if (!all) {
                    spread.shrinkRetainingCapacity(first);
                    continue;
                }
                try drop.append(gpa, e.key);
            }
            var here = p.here;
            if (drop.items.len > 0) {
                here = Ids.none_int;
                var kt = t.mapEntries(p.here);
                while (kt.next()) |e| {
                    if (std.mem.indexOfScalar(u32, drop.items, e.key) != null) continue;
                    here = try t.mapPut(gpa, charge, here, e.key, e.value);
                }
            }
            for (spread.items) |x| {
                const old = t.mapGet(here, x[0]);
                try t.keyed(gpa, charge, .from(x[0]));
                here = try t.mapPut(gpa, charge, here, x[0], if (old) |o| (try t.join(gpa, charge, .from(o), .from(x[1]))).int() else x[1]);
            }
            // A fold's links are the steps it saw, kept as they are.
            var links: u32 = if (p.fold != 0) p.links else Ids.none_int;
            var changed = here != p.here;
            if (p.fold == 0) {
                var lt = t.mapEntries(p.links);
                while (lt.next()) |e| {
                    const child: Kappas = .from(memo.get(.{e.value}).?);
                    if (child.int() != e.value) changed = true;
                    if (child != .none) links = try t.mapPut(gpa, charge, links, e.key, child.int());
                }
            }
            const out: Kappas = if (!changed) f.at else try t.makePos(gpa, charge, .{ .here = here, .links = links, .fold = p.fold });
            (try memo.getOrPut(gpa, .{f.at.int()})).value_ptr.* = out.int();
        }
        return .from(memo.get(.{ctx.int()}).?);
    }

    /// `x` widened (§2.3) with its κ carried onto the image (O15) and each
    /// folded class's obligation from §2.9's one path-multiset primitive:
    /// the source occurrences μ maps into the class as a multiset — choice
    /// (a `choice` node's arms, whole) takes the maximum, coexistence (a node's
    /// parts, a union's or positions node's sides, the depths a fold identifies) the
    /// sum — so a cell at two coexisting positions is a repeat (`lost`
    /// through the fold) and distinct arrivals owe `apart`, while one value
    /// in either arm of a choice stays one (`propagate` conjoins them at
    /// the class, `fold_cond`). The widened node and its κ.
    pub fn widenValue(t: *Table, gpa: Allocator, charge: Charge, v: View, x: NodeId, kx: Kappas) Error!struct { node: NodeId, kappas: Kappas } {
        var fold: Shape.Table.Fold = .{};
        defer fold.deinit(gpa);
        const lo = v.shapes.count();
        const raw = try v.shapes.widenFold(gpa, charge.account, v.places, v.cells, x, &fold);
        if (raw == x) return .{ .node = x, .kappas = kx };
        const per = try t.arrivalAggs(gpa, charge, v, x, &fold);
        var it = t.mapEntries(per.map);
        while (it.next()) |e| {
            if (!fold.folded.contains(.from(e.key)) and !per.saturated) continue;
            try charge.reserve(gpa, .inspection, 1);
            try t.fold_cond.put(gpa, .from(e.key), try t.foldCond(gpa, charge, v.cells, v.places, t.aggs.items[e.value]));
            t.fold_cond_n += 1;
        }
        // The image interned by its canonical form, `fold_cond` in the key
        // (§2.3, 4e): a target has the moved node's obligation already.
        var avoid: Avoid = .{ .t = t, .fold = &fold };
        var redir = try Stable.widened(v.shapes, gpa, charge.account, raw, lo, .{ .ctx = &avoid, .word = Avoid.word, .avoid = Avoid.source });
        defer redir.deinit(gpa);
        const w: NodeId = if (redir.get(raw.int())) |to| .from(to) else raw;
        // One member: `propagate` keeps its entries at each position it walks
        // outside a fold (§2.9 *Keyed where a reader looks*).
        const kappas = try t.propagate(gpa, charge, v, .none, w, &.{x}, &.{kx}, .alternatives, false, null);
        if (std.debug.runtime_safety and full_cross_check and redir.count() > 0) try t.crossCheckStable(gpa, v, x, kx, w, kappas);
        return .{ .node = w, .kappas = kappas };
    }

    /// A widening's side word (`fold_cond`) and its source nodes.
    const Avoid = struct {
        t: *Table,
        fold: *const Shape.Table.Fold,
        fn word(ctx: *anyopaque, n: NodeId) u32 {
            const a: *@This() = @ptrCast(@alignCast(ctx));
            return if (a.t.fold_cond.get(n)) |c| c.int() else Ids.none_int;
        }
        fn source(ctx: *anyopaque, n: NodeId) bool {
            const a: *@This() = @ptrCast(@alignCast(ctx));
            return a.fold.image.get(n) != null;
        }
    };

    /// The widening made again with nothing moved, on an account of its
    /// own: its κ at every position equals the moved one's (§2.3, 4e).
    fn crossCheckStable(t: *Table, gpa: Allocator, v: View, x: NodeId, kx: Kappas, w: NodeId, kw: Kappas) Error!void {
        var scratch: Ids.Account = .{ .allowance = std.math.maxInt(u32) };
        defer scratch.deinit(gpa);
        const was = v.shapes.stable.off;
        v.shapes.stable.off = true;
        defer v.shapes.stable.off = was;
        const raw = try t.widenValue(gpa, .growth(&scratch), v, x, kx);
        if (!try t.kappaLeq(gpa, .growth(&scratch), v, raw.kappas, raw.node, kw, w, false) or !try t.kappaLeq(gpa, .growth(&scratch), v, kw, w, raw.kappas, raw.node, false))
            std.debug.panic("ownership v2: a stable image reads other than its raw widening (§2.3, 4e)", .{});
    }

    /// `out` merged with a snapshot that sets κ at every position of
    /// `joined` (a `Shape.join` of `members`, widened or not) from the
    /// members read at the same path, projected in lockstep, each at its own
    /// position of its own snapshot: `alternatives` is the lattice join
    /// (O15), `together` `apart` across the members' cells and every
    /// member's κ. The positions are §2.9's sparse frontier. A state is
    /// `(joined node, position class, the interned run of members and their
    /// positions, the output position)`, compared exactly and recorded
    /// before it is processed (#1063, #1064). **Where `joined` cycles** (a
    /// route meets a node it has passed: a knot `widen` tied) the output
    /// position of that node becomes a FOLD (§2.9): every position below it
    /// is it, so the walk ends. The output is built once at the end, bottom
    /// up, a record per position and entry. Members are read by index: the
    /// run they were cut from grows as children are pushed.
    pub fn propagate(t: *Table, gpa: Allocator, charge: Charge, v: View, out: Kappas, joined: NodeId, members: []const NodeId, member_ctxs: []const Kappas, mode: Mode, at_summary: bool, traversal: ?Traversal) Error!Kappas {
        return t.propagateFrom(gpa, charge, v, out, joined, members, member_ctxs, mode, at_summary, at_summary, traversal);
    }

    /// `propagate`, the members read at their own class (a literal's `vᵢ`, §2.9).
    pub fn propagateFrom(t: *Table, gpa: Allocator, charge: Charge, v: View, out: Kappas, joined: NodeId, members: []const NodeId, member_ctxs: []const Kappas, mode: Mode, at_summary: bool, member_summary: bool, traversal: ?Traversal) Error!Kappas {
        const r = try t.propagateWalk(gpa, charge, v, out, joined, members, member_ctxs, mode, at_summary, member_summary, traversal);
        if (!(std.debug.runtime_safety and full_cross_check and !t.no_memo)) return r;
        // Walked again with no memo (*Cross-check*), on an account of its own
        // so that the check moves no limit: the same snapshot.
        var scratch: Ids.Account = .{ .allowance = std.math.maxInt(u32) };
        defer scratch.deinit(gpa);
        t.no_memo = true;
        defer t.no_memo = false;
        if (r != try t.propagateWalk(gpa, .growth(&scratch), v, out, joined, members, member_ctxs, mode, at_summary, member_summary, traversal)) std.debug.panic("ownership v2: a memoised propagation differs from its walk", .{});
        return r;
    }

    fn propagateWalk(t: *Table, gpa: Allocator, charge: Charge, v: View, out: Kappas, joined: NodeId, members: []const NodeId, member_ctxs: []const Kappas, mode: Mode, at_summary: bool, member_summary: bool, traversal: ?Traversal) Error!Kappas {
        std.debug.assert(members.len == member_ctxs.len);
        const memo = !t.no_memo;
        const call = t.prop_calls;
        t.prop_calls += 1;
        var runs: std.ArrayList(NodeId) = .empty;
        defer runs.deinit(gpa);
        var run_ctxs: std.ArrayList(Kappas) = .empty;
        defer run_ctxs.deinit(gpa);
        // `route`: the joined nodes on the way to this frame, each with its
        // output position (a persistent map node → path).
        // `clean`: every joined node on the way, this one included, has a
        // finite rank of at least 1, so nothing below can fold back onto
        // the way: the walk from here is a function of the state alone.
        const Frame = struct { node: NodeId, first: u32, len: u32, summary: bool, msummary: bool, path: u32, folded: bool, route: u32, clean: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        try runs.appendSlice(gpa, members);
        try run_ctxs.appendSlice(gpa, member_ctxs);
        // The output positions: path 0 the root, path k `(parent, step)`.
        const PathRec = struct { parent: u32, step: u32 };
        var paths: std.ArrayList(PathRec) = .empty;
        defer paths.deinit(gpa);
        var path_index: Ids.FixedDict(2) = .{};
        defer path_index.deinit(gpa);
        try paths.append(gpa, .{ .parent = Ids.none_int, .step = Ids.none_int });
        var fold_at: std.ArrayList(bool) = .empty;
        defer fold_at.deinit(gpa);
        var fold_steps: std.ArrayList([2]u32) = .empty;
        defer fold_steps.deinit(gpa);
        // The states met at each output position.
        var path_states: std.ArrayList(u32) = .empty;
        defer path_states.deinit(gpa);
        try path_states.append(gpa, 0);
        // The memo states walked here, written once the call has finished.
        const Candidate = struct { key: [3]u32, path: u32 };
        var candidates: std.ArrayList(Candidate) = .empty;
        defer candidates.deinit(gpa);
        try fold_at.append(gpa, false);
        const Write = struct { path: u32, node: NodeId, k: CondId };
        var outs: std.ArrayList(Write) = .empty;
        defer outs.deinit(gpa);
        // The positions that are a member's own snapshot, linked as they are.
        const Linked = struct { path: u32, at: Kappas };
        // A lone member's positions the walk passes outside a fold: its own
        // entries kept there, so each side of a DAG it holds keeps its
        // certificate (§2.9 *Keyed where a reader looks*).
        var kept: std.ArrayList(Linked) = .empty;
        defer kept.deinit(gpa);
        var linked: std.ArrayList(Linked) = .empty;
        defer linked.deinit(gpa);
        const root_route = try t.mapPut(gpa, charge, Ids.none_int, joined.int(), 0);
        try stack.append(gpa, .{ .node = joined, .first = 0, .len = @intCast(members.len), .summary = at_summary, .msummary = member_summary, .path = 0, .folded = false, .route = root_route, .clean = traversal == null and try memoRank(gpa, charge, v, joined) });
        // Exact states: a run interned as a cons list of `(member, position)`
        // pairs (`prop_runs`, across calls), the state `(node, class, run,
        // output position)`.
        var visited: Ids.FixedDict(4) = .{};
        defer visited.deinit(gpa);
        var items: std.ArrayList(Item) = .empty;
        defer items.deinit(gpa);
        var next: std.ArrayList(Next) = .empty;
        defer next.deinit(gpa);
        // What a frame reads of its run alone, once per run (#1273): the
        // run's interned id, its one member (the link test's), κ from the
        // members, the cursors' steps, and the run one step below along each
        // (step, inner place, class). A member's `side` for a transition out
        // of a recast's inner reads the inner's place, never the inner, so
        // the n frames one step below n inners at one place share one run.
        // The frames themselves, their order and each node's state are
        // the walk's as before.
        const Slice = struct { run: u32, m0: NodeId, c0: Kappas, one: bool, k: [4]u32, words: u32, words_len: u32, fold: bool, front: [3]u32 = .{ Ids.none_int, 0, 0 } };
        var slices: std.ArrayList(Slice) = .empty;
        defer slices.deinit(gpa);
        var slice_at: Ids.FixedDict(1) = .{};
        defer slice_at.deinit(gpa);
        var words: std.ArrayList(u64) = .empty;
        defer words.deinit(gpa);
        var below_at: Ids.FixedDict(4) = .{};
        defer below_at.deinit(gpa);
        var belows: std.ArrayList([2]u32) = .empty;
        defer belows.deinit(gpa);
        // Per call, by content (#1372): a run met again through another
        // parent reads the slice made for it, and a frontier is made once
        // per (node, class, slice): exact memos of pure functions, read by
        // this call alone, so a failed call leaves nothing another reads.
        var front_at: Ids.FixedDict(3) = .{};
        defer front_at.deinit(gpa);
        var fronts: std.ArrayList(Next) = .empty;
        defer fronts.deinit(gpa);
        while (stack.pop()) |f| {
            try charge.reserve(gpa, .memo, 1);
            var fresh: ?u32 = null;
            const sg = try slice_at.getOrPut(gpa, .{f.first});
            if (!sg.found_existing) {
                var run: u32 = Ids.none_int;
                var r = f.len;
                while (r > 0) {
                    r -= 1;
                    try charge.reserve(gpa, .memo, 1);
                    const got = try t.prop_runs.getOrPut(gpa, .{ runs.items[f.first + r].int(), run_ctxs.items[f.first + r].int(), run });
                    if (!got.found_existing) got.value_ptr.* = got.index;
                    run = got.value_ptr.*;
                }
                fresh = run;
                if (memo and run != Ids.none_int) {
                    if (t.prop_slice.items.len <= run) try t.prop_slice.appendNTimes(gpa, .{ Ids.none_int, 0 }, run + 1 - t.prop_slice.items.len);
                    const e = &t.prop_slice.items[run];
                    if (e[0] == call) fresh = null else e.* = .{ call, @intCast(slices.items.len) };
                    sg.value_ptr.* = e[1];
                } else sg.value_ptr.* = @intCast(slices.items.len);
            }
            if (fresh) |run| {
                var m0: NodeId = .none;
                var c0: Kappas = .none;
                var one = true;
                for (0..f.len) |i| {
                    const m = runs.items[f.first + i];
                    const c = run_ctxs.items[f.first + i];
                    if (c == .none and try nothingAt(gpa, charge, v, m)) continue;
                    if (m0 == .none) {
                        m0 = m;
                        c0 = c;
                    } else one = one and mode == .alternatives and m == m0 and c == c0;
                }
                try slices.append(gpa, .{ .run = run, .m0 = m0, .c0 = c0, .one = one, .k = @splat(Ids.none_int), .words = 0, .words_len = Ids.none_int, .fold = false });
            }
            const si = sg.value_ptr.*;
            const run = slices.items[si].run;
            try charge.reserve(gpa, .memo, 1);
            const state = try visited.getOrPut(gpa, .{ f.node.int(), @as(u32, @intFromBool(f.summary)) | @as(u32, @intFromBool(f.msummary)) << 1, run, f.path });
            if (state.found_existing) continue;
            state.value_ptr.* = 1;
            path_states.items[f.path] += 1;
            try t.traced(gpa, f.node, f.summary);
            // One alternative, or alternatives all one member at its own
            // node: the position IS that member's, a link (§2.9, #1112) —
            // nothing below is walked, nothing is written.
            // An alternative that is nothing (an empty leaf with nothing
            // stored) adds nothing to a join, so it does not count.
            // Together, an empty member is no object either, but two equal
            // members are two positions, never one.
            if (f.len > 0) {
                const m0 = slices.items[si].m0;
                const c0 = slices.items[si].c0;
                const one = slices.items[si].one and m0 != .none and (f.node == m0 or try joinOfOne(gpa, charge, v, f.node, m0, if (mode == .alternatives) .@"union" else .positions));
                if (one) {
                    try charge.reserve(gpa, .inspection, 1);
                    try linked.append(gpa, .{ .path = f.path, .at = c0 });
                    // A literal's one element at its `[*]` itself: the objects it
                    // holds at any path below are compared there (§2.9), over
                    // those construction does not make apart (`arrivals`).
                    if (mode == .together and f.node == joined) {
                        var k1 = try t.kappaOf(gpa, charge, v, c0, m0, f.msummary);
                        k1 = try t.@"and"(gpa, charge, k1, try t.summaryExcl(gpa, charge, v.cells, v.places, (try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, m0))));
                        if (traversal == null) {
                            // Its reach's aggregate, extended from its parts' (#1121).
                            k1 = try t.@"and"(gpa, charge, k1, try t.aggCond(gpa, charge, v.cells, v.places, try t.reachAgg(gpa, charge, v, m0)));
                        } else {
                            items.clearRetainingCapacity();
                            var it = v.cells.sets.iterate(try v.shapes.arrivals(gpa, charge.account, v.cells, &v.cells.sets, m0));
                            while (it.next()) |e| {
                                try charge.reserve(gpa, .inspection, 1);
                                try items.append(gpa, .{ .cell = .from(e.key), .approx = e.value == 1 });
                            }
                            k1 = try t.@"and"(gpa, charge, k1, try t.apart(gpa, charge, v.cells, v.places, items.items, traversal));
                        }
                        try outs.append(gpa, .{ .path = f.path, .node = f.node, .k = k1 });
                    }
                    continue;
                }
            }
            if (mode == .alternatives and f.len == 1 and !f.folded and members.len == 1) {
                try charge.reserve(gpa, .inspection, 1);
                try kept.append(gpa, .{ .path = f.path, .at = run_ctxs.items[f.first] });
            }
            // A clean state met before, in this call or another: its walk
            // is the same, so its position is the snapshot that walk made,
            // linked as it is (§2.9, *The join memo*).
            if (f.clean) {
                const key: [3]u32 = .{ f.node.int(), stateBits(f.summary, f.msummary, mode, f.node == joined), run };
                try charge.reserve(gpa, .memo, 1);
                if (if (t.no_memo) null else t.memo_prop.get(key)) |hit| {
                    try linked.append(gpa, .{ .path = f.path, .at = .from(hit) });
                    continue;
                }
                try candidates.append(gpa, .{ .key = key, .path = f.path });
            }
            const k_slot = @as(usize, @intFromBool(f.node == joined)) * 2 + @intFromBool(f.msummary);
            var k: CondId = yes;
            if (slices.items[si].k[k_slot] != Ids.none_int) k = .from(slices.items[si].k[k_slot]) else {
                items.clearRetainingCapacity();
                // At the joined node, the members' reaches as one multiset of
                // aggregates, each extended from its parts' (#1121).
                const by_agg = mode == .together and f.node == joined and traversal == null;
                var together: Agg = .{};
                for (0..f.len) |i| {
                    const m = runs.items[f.first + i];
                    const c = run_ctxs.items[f.first + i];
                    const km = try t.kappaOf(gpa, charge, v, c, m, f.msummary);
                    k = if (mode == .alternatives) try t.join(gpa, charge, k, km) else try t.@"and"(gpa, charge, k, km);
                    if (mode == .together) {
                        k = try t.@"and"(gpa, charge, k, try t.summaryExcl(gpa, charge, v.cells, v.places, (try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, m))));
                        // At the position itself every object a member holds
                        // anywhere below counts (I-κ: one object at two
                        // positions, at whatever paths, is shared — the
                        // `[ (a, b), (b, a) ]` twin); below it, the path's own.
                        if (by_agg) {
                            together = try t.aggMerge(gpa, charge, v.cells, v.places, together, try t.reachAgg(gpa, charge, v, m), true);
                            continue;
                        }
                        const set = if (f.node == joined) try v.shapes.reach(gpa, charge.account, &v.cells.sets, m) else (try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, m));
                        var it = v.cells.sets.iterate(set);
                        while (it.next()) |e| {
                            try charge.reserve(gpa, .inspection, 1);
                            try items.append(gpa, .{ .cell = .from(e.key), .approx = e.value == 1 });
                        }
                    }
                }
                if (by_agg) {
                    k = try t.@"and"(gpa, charge, k, try t.aggCond(gpa, charge, v.cells, v.places, together));
                } else if (mode == .together) k = try t.@"and"(gpa, charge, k, try t.apart(gpa, charge, v.cells, v.places, items.items, traversal));
                if (mode == .alternatives and f.len == 0) k = lost;
                slices.items[si].k[k_slot] = k.int();
            }
            // The repeats of a class `widen` opened a collection into are stored,
            // so the block carries them (§2.3, #1120).
            // A folded class's obligation, stored so the block carries it: the
            // class image's own, or its sides' where it rides in a union.
            k = try t.@"and"(gpa, charge, k, try t.foldCondOf(gpa, charge, v, f.node));
            // A leaf's read is the stored ⊔ the derivation, so a κ no
            // stronger than the derivation stores nothing: what a reader
            // derives there is the same before and after the join.
            // (Against the read without its fold obligation, so the snapshot
            // stores the obligation itself, #1128.)
            const plain = try v.shapes.force(gpa, charge.account, f.node);
            const redundant = v.shapes.kind(plain) == .leaf and try t.leq(gpa, charge, k, try t.kappaRead(gpa, charge, v, .none, plain, f.summary, null));
            if (!redundant) {
                try charge.reserve(gpa, .inspection, 1);
                try outs.append(gpa, .{ .path = f.path, .node = f.node, .k = k });
            }
            // Children: the joined node's frontier, the members projected
            // along each step of it, each at its position one step below.
            if (slices.items[si].words_len == Ids.none_int) {
                const at: u32 = @intCast(words.items.len);
                const fold = try t.cursorSteps(gpa, charge, run_ctxs.items[f.first..][0..f.len], &words);
                slices.items[si].words = at;
                slices.items[si].words_len = @intCast(words.items.len - at);
                slices.items[si].fold = fold;
            }
            const sl = slices.items[si];
            // The slice's first frontier is kept on it; another of its
            // frontiers is in `front_at`, looked up only when one may be.
            const fkey: [2]u32 = .{ f.node.int(), @intFromBool(f.summary) };
            var at: ?u32 = if (memo and sl.front[0] == fkey[0] and sl.front[1] == fkey[1]) sl.front[2] else null;
            if (at == null and memo and sl.front[0] != Ids.none_int) {
                try charge.reserve(gpa, .memo, 1);
                const fg = try front_at.getOrPut(gpa, .{ fkey[0], fkey[1], si });
                if (fg.found_existing) at = fg.value_ptr.* else fg.value_ptr.* = @intCast(fronts.items.len);
            }
            if (at == null) {
                next.clearRetainingCapacity();
                try t.frontierWith(gpa, charge, v, f.node, f.summary, .{ .words = words.items[sl.words..][0..sl.words_len], .fold = sl.fold }, &next);
                at = @intCast(fronts.items.len);
                if (sl.front[0] == Ids.none_int) slices.items[si].front = .{ fkey[0], fkey[1], at.? };
                try fronts.appendSlice(gpa, next.items);
                try fronts.append(gpa, .{ .node = .none, .summary = false, .step = Ids.none_int });
            }
            for (fronts.items[at.?..]) |e| {
                if (e.node == .none) break;
                const s = Step.fromWord(e.step);
                const child = e.node;
                // The run one step below, made once per (run, step, inner
                // place, class).
                try charge.reserve(gpa, .memo, 1);
                const place: u32 = if (e.via == .none) Ids.none_int else v.shapes.place(e.via).int();
                const bg = try below_at.getOrPut(gpa, .{ if (memo) run else f.first, e.step, place, @intFromBool(e.summary) });
                if (!bg.found_existing) {
                    bg.value_ptr.* = @intCast(belows.items.len);
                    const first: u32 = @intCast(runs.items.len);
                    for (0..f.len) |i| {
                        try charge.reserve(gpa, .inspection, 1);
                        const m = runs.items[f.first + i];
                        const c = run_ctxs.items[f.first + i];
                        const sm = (try side(gpa, charge, v, m, e.via)) orelse continue;
                        const pm = (try v.shapes.proj(gpa, charge.account, v.places, v.cells, sm, s)) orelse continue;
                        try runs.append(gpa, pm);
                        try run_ctxs.append(gpa, t.kappaChild(c, s));
                    }
                    try belows.append(gpa, .{ first, @intCast(runs.items.len - first) });
                }
                const first = belows.items[bg.value_ptr.*][0];
                const len = belows.items[bg.value_ptr.*][1];
                // The child's output position: a fold stays itself; a node
                // the route has passed folds there (its knot); else one step.
                var path = f.path;
                var folded = f.folded;
                var route = f.route;
                if (!folded) {
                    if (t.mapGet(f.route, child.int())) |back| {
                        path = back;
                        folded = true;
                        fold_at.items[back] = true;
                    } else {
                        try charge.reserve(gpa, .memo, 1);
                        const got = try path_index.getOrPut(gpa, .{ f.path, e.step });
                        if (!got.found_existing) {
                            got.value_ptr.* = @intCast(paths.items.len);
                            try paths.append(gpa, .{ .parent = f.path, .step = e.step });
                            try fold_at.append(gpa, false);
                            try path_states.append(gpa, 0);
                        }
                        path = got.value_ptr.*;
                        route = try t.mapPut(gpa, charge, f.route, child.int(), path);
                    }
                }
                // A step taken at a fold is one of the steps it saw.
                if (folded) {
                    try charge.reserve(gpa, .inspection, 1);
                    try fold_steps.append(gpa, .{ path, e.step });
                }
                try stack.append(gpa, .{ .node = child, .first = first, .len = len, .summary = e.summary, .msummary = f.msummary or below(s), .path = path, .folded = folded, .route = route, .clean = f.clean and !folded and try memoRank(gpa, charge, v, child) });
            }
        }
        // Each output position below a fold is the fold (the highest one on
        // its way); parents precede their children in `paths`.
        const owner = try gpa.alloc(u32, paths.items.len);
        defer gpa.free(owner);
        for (paths.items, 0..) |p, i| {
            owner[i] = @intCast(i);
            if (p.parent == Ids.none_int) continue;
            const up = owner[p.parent];
            if (up != p.parent) owner[i] = up else if (fold_at.items[p.parent]) owner[i] = p.parent;
        }
        const here = try gpa.alloc(u32, paths.items.len);
        defer gpa.free(here);
        @memset(here, Ids.none_int);
        // Each fold's steps: those taken at it, and those of the paths made
        // below it before it folded.
        const fold_links = try gpa.alloc(u32, paths.items.len);
        defer gpa.free(fold_links);
        @memset(fold_links, Ids.none_int);
        for (fold_steps.items) |x| {
            const at = owner[x[0]];
            fold_links[at] = try t.mapPut(gpa, charge, fold_links[at], x[1], 0);
        }
        for (paths.items, 0..) |p, pi| if (p.parent != Ids.none_int and owner[pi] != pi) {
            try charge.reserve(gpa, .inspection, 1);
            fold_links[owner[pi]] = try t.mapPut(gpa, charge, fold_links[owner[pi]], p.step, 0);
        };
        for (kept.items) |x| {
            if (owner[x.path] != x.path or fold_at.items[x.path] or x.at == .none) continue;
            try charge.reserve(gpa, .inspection, 1);
            here[x.path] = try t.mapUnion(gpa, charge, .cond, here[x.path], t.position(x.at).here);
        }
        for (outs.items) |w| {
            try charge.reserve(gpa, .inspection, 1);
            const at = owner[w.path];
            const old = t.mapGet(here[at], w.node.int());
            const val = if (old) |o| try t.join(gpa, charge, .from(o), w.k) else w.k;
            try t.keyed(gpa, charge, w.node);
            here[at] = try t.mapPut(gpa, charge, here[at], w.node.int(), val.int());
        }
        // The linked positions by the output position they are at.
        const link_head = try gpa.alloc(u32, paths.items.len);
        defer gpa.free(link_head);
        @memset(link_head, Ids.none_int);
        const link_next = try gpa.alloc(u32, linked.items.len);
        defer gpa.free(link_next);
        for (linked.items, 0..) |l, li| {
            const at = owner[l.path];
            link_next[li] = link_head[at];
            link_head[at] = @intCast(li);
        }
        // Bottom up: a child after its parent in `paths`, so in reverse.
        const pos = try gpa.alloc(Kappas, paths.items.len);
        defer gpa.free(pos);
        @memset(pos, .none);
        const links = try gpa.alloc(u32, paths.items.len);
        defer gpa.free(links);
        @memset(links, Ids.none_int);
        var i = paths.items.len;
        while (i > 0) {
            i -= 1;
            if (owner[i] != i) continue;
            pos[i] = try t.makePos(gpa, charge, .{ .here = here[i], .links = if (fold_at.items[i]) fold_links[i] else links[i], .fold = if (fold_at.items[i]) fold_exact else 0 });
            var li = link_head[i];
            while (li != Ids.none_int) : (li = link_next[li]) pos[i] = try t.kappaMerge(gpa, charge, pos[i], linked.items[li].at);
            const p = paths.items[i];
            if (p.parent != Ids.none_int and pos[i] != .none) links[p.parent] = try t.mapPut(gpa, charge, links[p.parent], p.step, pos[i].int());
        }
        // The call has finished: each clean state walked here, alone at its
        // position, is that position's snapshot wherever it is met again.
        for (candidates.items) |c| {
            if (path_states.items[c.path] != 1) continue;
            try charge.reserve(gpa, .memo, 1);
            (try t.memo_prop.getOrPut(gpa, c.key)).value_ptr.* = pos[c.path].int();
        }
        const result = try t.kappaMerge(gpa, charge, out, pos[0]);
        return result;
    }

    /// A memo state's bits: its class, the mode, and whether it is the
    /// call's root (a literal's root reads everything its members hold).
    fn stateBits(summary: bool, msummary: bool, mode: Mode, root: bool) u32 {
        return @as(u32, @intFromBool(summary)) | @as(u32, @intFromBool(msummary)) << 1 | @as(u32, @backingInt(mode)) << 2 | @as(u32, @intFromBool(root)) << 3;
    }

    /// Whether `n` may key the join memo: a finite rank of at least 1, so
    /// no walk below it meets it, or anything above it, again.
    fn memoRank(gpa: Allocator, charge: Charge, v: View, n: NodeId) Error!bool {
        const r = try v.shapes.rank(gpa, charge.account, n);
        return r >= 1 and r != Shape.Table.rank_unbounded;
    }
    /// An empty leaf: no object can be there.
    fn nothingAt(gpa: Allocator, charge: Charge, v: View, n: NodeId) Error!bool {
        return v.shapes.isNothing(gpa, charge.account, n);
    }

    /// Whether `joined` is `m` with nothing but empty leaves: a `via` DAG
    /// (`union` for alternatives, `positions` for elements) whose every
    /// other side is an empty leaf. As elements `m` must stand once: twice
    /// is two positions. A record per node.
    fn joinOfOne(gpa: Allocator, charge: Charge, v: View, joined: NodeId, m: NodeId, via: Shape.Kind) Error!bool {
        var stack: std.ArrayList(NodeId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, joined);
        var found: u32 = 0;
        while (stack.pop()) |x| {
            try charge.reserve(gpa, .inspection, 1);
            if (x == m) {
                found += 1;
                continue;
            }
            if (try nothingAt(gpa, charge, v, x)) continue;
            const xk = v.shapes.kind(x);
            // Alternatives are joined as a `choice` or a `union` (§2.3).
            if (xk != via and !(via == .@"union" and xk == .choice)) return false;
            const d = v.shapes.get(x);
            try stack.appendSlice(gpa, &.{ .from(d.a), .from(d.b) });
        }
        return found == 1 or (found > 1 and via == .@"union");
    }
};

/// The node a reader of a transported value meets for DAG node `n`, the
/// projection of a DAG that no part of the value names (§2.9 *Keyed where
/// a reader looks*): the projection of an origin's, at the origin's step.
/// A call's view of such a node has its template's origins, viewed under
/// its environment (`Shape.originHead`). A node's own image is `image`'s
/// (null for a node the transport does not carry); one with none is found
/// through its origins, each tried in turn. Null where `n` has an image of
/// its own (the transport keys that one), or no origin leads to one.
/// Memoised per transport in `memo`, so each node is resolved once; on an
/// explicit stack.
pub fn projectedImage(t: *Shape.Table, gpa: Allocator, account: *Ids.Account, places: *@import("Place.zig").Table, cellt: *Cell.Table, n: NodeId, memo: *Ids.FixedDict(1), ctx: anytype, image: *const fn (@TypeOf(ctx), NodeId) Error!?NodeId, templates: bool) Error!?NodeId {
    // A join of alternatives keys a union or a choice, or a call's view of
    // one; a positions node is a literal's, which no transport carries.
    if (!t.isJoinNode(n)) return null;
    const start = t.originHead(n, templates) orelse return null;
    if ((try image(ctx, n)) != null) return null;
    const open: u32 = Ids.none_int - 1;
    const Frame = struct { node: NodeId, origin: u32, env: u32 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(gpa);
    var result: ?NodeId = null;
    try stack.append(gpa, .{ .node = n, .origin = start.head, .env = start.env });
    (try memo.getOrPut(gpa, .{n.int()})).value_ptr.* = open;
    // `result` carries a finished child's answer to its parent frame.
    var returned = false;
    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        try account.reserve(.memo, 1);
        if (returned) {
            returned = false;
            const o = t.proj_origins.items[top.origin];
            if (result) |b| if (try t.proj(gpa, account, places, cellt, b, Step.fromWord(o[1]))) |got| {
                (try memo.getOrPut(gpa, .{top.node.int()})).value_ptr.* = got.int();
                result = got;
                returned = true;
                _ = stack.pop();
                continue;
            };
            top.origin = o[2];
        }
        if (top.origin == Ids.none_int) {
            (try memo.getOrPut(gpa, .{top.node.int()})).value_ptr.* = Ids.none_int;
            result = null;
            returned = true;
            _ = stack.pop();
            continue;
        }
        const raw: NodeId = .from(t.proj_origins.items[top.origin][0]);
        const parent = if (top.env == Ids.none_int) raw else try t.view(gpa, account, raw, top.env);
        if (memo.get(.{parent.int()})) |hit| {
            if (hit == open) {
                top.origin = t.proj_origins.items[top.origin][2];
                continue;
            }
            result = if (hit == Ids.none_int) null else NodeId.from(hit);
            returned = true;
            continue;
        }
        if (try image(ctx, parent)) |img| {
            (try memo.getOrPut(gpa, .{parent.int()})).value_ptr.* = img.int();
            result = img;
            returned = true;
            continue;
        }
        const head = t.originHead(parent, templates) orelse {
            (try memo.getOrPut(gpa, .{parent.int()})).value_ptr.* = Ids.none_int;
            top.origin = t.proj_origins.items[top.origin][2];
            continue;
        };
        (try memo.getOrPut(gpa, .{parent.int()})).value_ptr.* = open;
        try stack.append(gpa, .{ .node = parent, .origin = head.head, .env = head.env });
    }
    return result;
}

comptime {
    Ids.assertRecord(Cond);
    Ids.assertRecord(MapNode);
    std.debug.assert(@sizeOf(Cond) == 12);
    std.debug.assert(@sizeOf(MapNode) == 16);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Place = @import("Place.zig");

/// A test type graph: 0 a record `{ a : List Int, b : List Int }`, 1 `List
/// Int`, 2 `Int`, 3 `List (List Int)`, 4 a record `{ p : Int, q : Int }`
/// (crosses), 5 `List { a : List Int, b : List Int }`.
const TestGraph = struct {
    table: *Place.Table,
    account: *Ids.Account,
    gpa: Allocator,

    fn describe(ctx: *anyopaque, v: u32, out: *std.ArrayList(Place.Child)) Allocator.Error!Place.Description {
        const g: *TestGraph = @ptrCast(@alignCast(ctx));
        switch (v) {
            0 => {
                try out.append(g.gpa, .{ .step = (Place.Step.field(g.account, 10) catch unreachable), .@"var" = 1 });
                try out.append(g.gpa, .{ .step = (Place.Step.field(g.account, 11) catch unreachable), .@"var" = 1 });
                return .{ .kind = .record };
            },
            1 => {
                try out.append(g.gpa, .{ .step = Place.Step.elem, .@"var" = 2 });
                return .{ .kind = .list, .head = 200 };
            },
            2 => return .{ .kind = .cross },
            3 => {
                try out.append(g.gpa, .{ .step = Place.Step.elem, .@"var" = 1 });
                return .{ .kind = .list, .head = 200 };
            },
            4 => {
                try out.append(g.gpa, .{ .step = (Place.Step.field(g.account, 12) catch unreachable), .@"var" = 2 });
                try out.append(g.gpa, .{ .step = (Place.Step.field(g.account, 13) catch unreachable), .@"var" = 2 });
                return .{ .kind = .record };
            },
            5 => {
                try out.append(g.gpa, .{ .step = Place.Step.elem, .@"var" = 0 });
                return .{ .kind = .list, .head = 200 };
            },
            // `type Rose = Rose (List Rose)`: 6 the constructor, 7 its list.
            6 => {
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 6, 0) catch unreachable), .@"var" = 7 });
                return .{ .kind = .ctor, .head = 300 };
            },
            7 => {
                try out.append(g.gpa, .{ .step = Place.Step.elem, .@"var" = 6 });
                return .{ .kind = .list, .head = 200 };
            },
            // 8 a record `{ a, b, c : List Int }`: three routes to one place.
            8 => {
                inline for (.{ 10, 11, 14 }) |name| try out.append(g.gpa, .{ .step = (Place.Step.field(g.account, name) catch unreachable), .@"var" = 1 });
                return .{ .kind = .record };
            },
            // 9 and 10: records of 8 and of 512 `List (List Int)` fields
            // (ranks 100…), for the sparse frontier's width (#1073).
            9, 10 => {
                const w: u32 = if (v == 9) 8 else 512;
                for (0..w) |i| try out.append(g.gpa, .{ .step = (Place.Step.field(g.account, @intCast(100 + i)) catch unreachable), .@"var" = 3 });
                return .{ .kind = .record };
            },
            // 11 a record `{ a, b : List (List Int) }`.
            11 => {
                inline for (.{ 10, 11 }) |name| try out.append(g.gpa, .{ .step = (Place.Step.field(g.account, name) catch unreachable), .@"var" = 3 });
                return .{ .kind = .record };
            },
            // 14 a record `{ p, q }` of two records 0: a repeated substructure.
            14 => {
                inline for (.{ 15, 16 }) |name| try out.append(g.gpa, .{ .step = (Place.Step.field(g.account, name) catch unreachable), .@"var" = 0 });
                return .{ .kind = .record };
            },
            // `type T = T (List Int) (List T)`: 12 the constructor, 13 its list.
            12 => {
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 12, 0) catch unreachable), .@"var" = 1 });
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 12, 1) catch unreachable), .@"var" = 13 });
                return .{ .kind = .ctor, .head = 301 };
            },
            13 => {
                try out.append(g.gpa, .{ .step = Place.Step.elem, .@"var" = 12 });
                return .{ .kind = .list, .head = 200 };
            },
            else => unreachable,
        }
    }
};

const Fixture = struct {
    places: Place.Table = .{},
    cells: Cell.Table = .{},
    shapes: Shape.Table = .{},
    conds: Table = undefined,
    account: Ids.Account = .{},
    graph: TestGraph = undefined,

    fn init(f: *Fixture) !void {
        f.graph = .{ .table = &f.places, .account = &f.account, .gpa = testing.allocator };
        f.conds = try Table.init(testing.allocator, .growth(&f.account));
    }

    fn deinit(f: *Fixture) void {
        f.places.deinit(testing.allocator);
        f.cells.deinit(testing.allocator);
        f.shapes.deinit(testing.allocator);
        f.conds.deinit(testing.allocator);
        f.account.deinit(testing.allocator);
    }

    fn charge(f: *Fixture) Charge {
        return .growth(&f.account);
    }

    fn view(f: *Fixture) View {
        return .{ .shapes = &f.shapes, .cells = &f.cells, .places = &f.places };
    }

    fn placeOf(f: *Fixture, v: u32) !Ids.PlaceId {
        return f.places.of(testing.allocator, &f.account, .{ .ctx = &f.graph, .describe = TestGraph.describe }, v);
    }

    fn param(f: *Fixture, i: u32, root: u32, steps: []const Place.Step) !CellId {
        const p = try f.placeOf(root);
        var at = try f.places.rootPath(testing.allocator, p);
        for (steps) |s| at = (try f.places.extend(testing.allocator, f.charge(), at, s)).?;
        return f.cells.symbolic(testing.allocator, &f.account, &f.places, .param, i, at, 0);
    }

    fn set(f: *Fixture, cells: []const CellId) !SetId {
        var s: SetId = .none;
        for (cells) |c| s = try f.cells.sets.insert(testing.allocator, f.charge(), s, c.int(), 0);
        return s;
    }

    fn leaf(f: *Fixture, root: u32, cells: []const CellId) !NodeId {
        return f.shapes.leaf(testing.allocator, &f.account, try f.placeOf(root), try f.set(cells));
    }

    fn sep(f: *Fixture, a: CellId, b: CellId) !CondId {
        return f.conds.sep(testing.allocator, f.charge(), &f.cells, &f.places, a, b, false, null);
    }

    fn apart(f: *Fixture, cells: []const CellId) !CondId {
        var items: std.ArrayList(Item) = .empty;
        defer items.deinit(testing.allocator);
        for (cells) |c| try items.append(testing.allocator, .{ .cell = c, .approx = false });
        return f.conds.apart(testing.allocator, f.charge(), &f.cells, &f.places, items.items, null);
    }

    fn firstCell(f: *Fixture, s: SetId) CellId {
        var it = f.cells.sets.iterate(s);
        return .from(it.next().?.key);
    }

    fn kappa(f: *Fixture, ctx: Kappas, n: NodeId, at_summary: bool) !CondId {
        return f.conds.kappaOf(testing.allocator, f.charge(), f.view(), ctx, n, at_summary);
    }

    fn setK(f: *Fixture, ctx: Kappas, n: NodeId, k: CondId) !Kappas {
        return f.setKAt(ctx, n, false, k);
    }

    /// κ(n) stored at the position `ctx` is; the class is the reader's now
    /// (a path names it, §2.9), so a test that needs another position
    /// builds the snapshot along the path.
    fn setKAt(f: *Fixture, ctx: Kappas, n: NodeId, at_summary: bool, k: CondId) !Kappas {
        _ = at_summary;
        return (try f.conds.kappaSet(testing.allocator, f.charge(), ctx, n, k)).ctx;
    }

    /// κ(n) stored at the position along `steps` from `ctx`.
    fn setKPath(f: *Fixture, ctx: Kappas, steps: []const Place.Step, n: NodeId, k: CondId) !Kappas {
        return f.conds.kappaSetAt(testing.allocator, f.charge(), ctx, steps, n, k);
    }

    /// κ(n) read at the position along `steps` from `ctx`.
    fn kappaPath(f: *Fixture, ctx: Kappas, steps: []const Place.Step, n: NodeId, at_summary: bool) !CondId {
        return f.kappa(f.conds.kappaAlong(ctx, steps), n, at_summary);
    }

    fn join2(f: *Fixture, a: NodeId, b: NodeId) !NodeId {
        var ms = [_]NodeId{ a, b };
        return f.shapes.join(testing.allocator, &f.account, &f.places, &f.cells, &ms);
    }

    /// A literal's elements under `[*]`.
    fn collect(f: *Fixture, members: []const NodeId) !NodeId {
        return f.shapes.collect(testing.allocator, &f.account, &f.cells.sets, members);
    }

    fn projOf(f: *Fixture, n: NodeId, s: Place.Step) !NodeId {
        return (try f.shapes.proj(testing.allocator, &f.account, &f.places, &f.cells, n, s)).?;
    }

    fn propagate(f: *Fixture, out: Kappas, joined: NodeId, members: []const NodeId, ctxs: []const Kappas, mode: Mode, at_summary: bool) !Kappas {
        return f.conds.propagate(testing.allocator, f.charge(), f.view(), out, joined, members, ctxs, mode, at_summary, null);
    }

    /// A literal's `[*]` snapshot over `members` (no snapshots of their own).
    fn propagateFrom2(f: *Fixture, joined: NodeId, members: []const NodeId) !Kappas {
        const none_ks = try testing.allocator.alloc(Kappas, members.len);
        defer testing.allocator.free(none_ks);
        @memset(none_ks, .none);
        return f.conds.propagateFrom(testing.allocator, f.charge(), f.view(), .none, joined, members, none_ks, .together, true, false, null);
    }
};

test "and is O(1) and absorbing; join is the canonical flat form and idempotent" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var t = &f.conds;
    const p1 = try f.param(1, 1, &.{});
    const p2 = try f.param(2, 1, &.{});
    const p3 = try f.param(3, 1, &.{});
    const e1 = try t.excl(gpa, f.charge(), p1);
    const e2 = try t.excl(gpa, f.charge(), p2);
    const e3 = try t.excl(gpa, f.charge(), p3);
    try testing.expectEqual(e1, try t.excl(gpa, f.charge(), p1));
    try testing.expectEqual(e1, try t.@"and"(gpa, f.charge(), yes, e1));
    try testing.expectEqual(shared, try t.@"and"(gpa, f.charge(), lost, shared));
    try testing.expectEqual(lost, try t.@"and"(gpa, f.charge(), e1, lost));
    try testing.expectEqual(e1, try t.@"and"(gpa, f.charge(), e1, e1));
    const a12 = try t.@"and"(gpa, f.charge(), e1, e2);
    try testing.expectEqual(a12, try t.@"and"(gpa, f.charge(), e2, e1));
    const x = try t.@"and"(gpa, f.charge(), a12, e3);
    const y = try t.@"and"(gpa, f.charge(), e1, try t.@"and"(gpa, f.charge(), e3, e2));
    try testing.expect(x != y);
    try testing.expectEqual(try t.flat(gpa, f.charge(), x), try t.flat(gpa, f.charge(), y));
    try testing.expectEqual(@as(u32, 3), t.atoms.count(try t.flat(gpa, f.charge(), x)));
    const jx = try t.join(gpa, f.charge(), x, yes);
    try testing.expectEqual(jx, try t.join(gpa, f.charge(), y, yes));
    try testing.expectEqual(jx, try t.join(gpa, f.charge(), jx, jx));
    try testing.expectEqual(jx, try t.join(gpa, f.charge(), x, y));
    try testing.expectEqual(jx, try t.join(gpa, f.charge(), a12, e3));
    try testing.expect(try t.leq(gpa, f.charge(), yes, a12));
    try testing.expect(try t.leq(gpa, f.charge(), a12, x));
    try testing.expect(!try t.leq(gpa, f.charge(), x, a12));
    try testing.expect(try t.leq(gpa, f.charge(), x, lost));
    try testing.expect(try t.leq(gpa, f.charge(), lost, shared));
    try testing.expect(!try t.leq(gpa, f.charge(), shared, lost));
    try testing.expect(!try t.leq(gpa, f.charge(), lost, x));
    try testing.expectEqual(shared, try t.join(gpa, f.charge(), lost, shared));
    try testing.expectEqual(lost, try t.join(gpa, f.charge(), x, lost));
    try testing.expectEqual(yes, try t.ofSet(gpa, f.charge(), .none));
    try testing.expect((try t.rely(gpa, f.charge(), yes)) == .ok);
    try testing.expectEqual(Rely{ .refused = .exact }, try t.rely(gpa, f.charge(), shared));
    try testing.expectEqual(Rely{ .refused = .approximate }, try t.rely(gpa, f.charge(), lost));
    try testing.expectEqual(try t.flat(gpa, f.charge(), x), (try t.rely(gpa, f.charge(), x)).xreq);
}

test "a chain of W stores is W outer nodes, flattened once in O(W log W)" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var t = &f.conds;
    var last_cost: u64 = 0;
    for ([_]u32{ 100, 200, 400 }) |w| {
        var acc: CondId = yes;
        var i: u32 = 0;
        const before_form = f.account.growth;
        while (i < w) : (i += 1) acc = try t.@"and"(gpa, f.charge(), acc, try t.excl(gpa, f.charge(), try f.param(i + 1, 1, &.{})));
        try testing.expect(f.account.growth - before_form <= 12 * w);
        const before = f.account.growth;
        const s = try t.flat(gpa, f.charge(), acc);
        try testing.expectEqual(w, t.atoms.count(s));
        const cost = f.account.growth - before;
        try testing.expect(cost <= 40 * w * (std.math.log2_int(u32, w) + 1));
        if (last_cost > 0) try testing.expect(cost * 2 < last_cost * 5);
        last_cost = cost;
        const again = f.account.growth;
        try testing.expectEqual(s, try t.flat(gpa, f.charge(), acc));
        // A hit is one memo record, reserved before the memo is read (#1124).
        try testing.expectEqual(again + 1, f.account.growth);
    }
}

test "sep: concrete cells, one cell twice, folded cells, arrivals, a split's sides" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var t = &f.conds;
    const list = try f.placeOf(1);
    const s7 = try f.cells.site(gpa, &f.account, 7, list, .list);
    const s8 = try f.cells.site(gpa, &f.account, 8, list, .list);
    const p1 = try f.param(1, 0, &.{});
    const p1a = try f.param(1, 0, &.{try Place.Step.field(&f.account, 10)});
    const p1b = try f.param(1, 0, &.{try Place.Step.field(&f.account, 11)});
    const p2 = try f.param(2, 0, &.{});
    const top = try f.cells.top(gpa, &f.account);
    try testing.expectEqual(yes, try f.sep(s7, s8));
    try testing.expectEqual(yes, try f.sep(s7, p1));
    try testing.expectEqual(shared, try f.sep(s7, s7));
    try testing.expectEqual(shared, try f.sep(p1, p1));
    const elems = try f.param(3, 3, &.{Place.Step.elem});
    try testing.expectEqual(lost, try f.sep(elems, elems));
    try testing.expectEqual(lost, try f.sep(top, s7));
    try testing.expectEqual(lost, try f.sep(top, top));
    try testing.expectEqual(lost, try t.sep(gpa, f.charge(), &f.cells, &f.places, p1, p2, true, null));
    const atom = try f.sep(p1, p2);
    try testing.expectEqual(Kind.atom, t.kind(atom));
    try testing.expectEqual(atom, try f.sep(p2, p1));
    try testing.expectEqual(atom, try t.sepAtom(gpa, f.charge(), p2, p1));
    try testing.expectEqual(Kind.atom, t.kind(try f.sep(p1a, p1b)));
    try testing.expectEqual(lost, try f.sep(p1, p1a));
    // Two `cb` labels: an atom; one folded label twice: lost; one unfolded
    // label under `[*]` twice: lost too (a summary position, R-6.3).
    const l1 = try f.cells.label(gpa, &f.account, 40, .none, false);
    const l2 = try f.cells.label(gpa, &f.account, 41, .none, true);
    const root1 = try f.places.rootPath(gpa, list);
    const cb1 = try f.cells.symbolic(gpa, &f.account, &f.places, .cb, l1.int(), root1, 5);
    const cb2 = try f.cells.symbolic(gpa, &f.account, &f.places, .cb, l2.int(), root1, 5);
    try testing.expectEqual(Kind.atom, t.kind(try f.sep(cb1, cb2)));
    try testing.expectEqual(shared, try f.sep(cb1, cb1));
    try testing.expectEqual(lost, try f.sep(cb2, cb2));
    const root3 = try f.places.rootPath(gpa, try f.placeOf(3));
    const under = (try f.places.extend(gpa, f.charge(), root3, Place.Step.elem)).?;
    const cb1e = try f.cells.symbolic(gpa, &f.account, &f.places, .cb, l1.int(), under, 5);
    try testing.expectEqual(lost, try f.sep(cb1e, cb1e));
    // The two sides of a split: the split's κ. Two taken elements of one
    // container: lost without a traversal answer, its answer with one.
    const xs = try f.param(4, 1, &.{});
    const kappa_at_split = try t.excl(gpa, f.charge(), xs);
    _ = try f.cells.split(gpa, &f.account, xs, 40, l1, kappa_at_split);
    const e1 = try f.cells.refine(gpa, &f.account, .elem, xs, l1, 0, .none, .none);
    const o1 = try f.cells.refine(gpa, &f.account, .others, xs, l1, 0, .none, .list);
    try testing.expectEqual(kappa_at_split, try f.sep(e1, o1));
    const e2 = try f.cells.refine(gpa, &f.account, .elem, xs, l2, 0, .none, .none);
    try testing.expectEqual(lost, try f.sep(e1, e2));
    const Answer = struct {
        fn apart(_: *anyopaque, _: CellId, _: CellId, _: CellId) ?CondId {
            return yes;
        }
    };
    var dummy: u8 = 0;
    try testing.expectEqual(yes, try t.sep(gpa, f.charge(), &f.cells, &f.places, e1, e2, false, .{ .ctx = &dummy, .apart = Answer.apart }));
}

test "apart over a construction's cells: ListOfParams is one atom, O(n)" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var t = &f.conds;
    var last: u64 = 0;
    for ([_]u32{ 100, 200, 400 }) |n| {
        var cells: std.ArrayList(CellId) = .empty;
        defer cells.deinit(gpa);
        var i: u32 = 0;
        while (i < n) : (i += 1) try cells.append(gpa, try f.param(i + 1, 1, &.{}));
        const before = f.account.growth;
        const k = try f.apart(cells.items);
        const cost = f.account.growth - before;
        try testing.expectEqual(Kind.atom, t.kind(k));
        try testing.expectEqual(AtomKind.apart, t.get(k).atom);
        try testing.expectEqual(n, f.cells.sets.count(.from(t.get(k).a)));
        try testing.expect(cost <= 80 * n);
        if (last > 0) try testing.expect(cost * 2 < last * 5);
        last = cost;
    }
}

test "apart decides duplicates, ⊤, fresh cells and a split's sides" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var t = &f.conds;
    const list = try f.placeOf(1);
    const s7 = try f.cells.site(gpa, &f.account, 7, list, .list);
    const s8 = try f.cells.site(gpa, &f.account, 8, list, .list);
    const p1 = try f.param(1, 1, &.{});
    const p2 = try f.param(2, 1, &.{});
    try testing.expectEqual(shared, try f.apart(&.{ p1, p1 }));
    try testing.expectEqual(shared, try f.apart(&.{ s7, s7, p1 }));
    try testing.expectEqual(yes, try f.apart(&.{ s7, s8 }));
    try testing.expectEqual(yes, try f.apart(&.{s7}));
    try testing.expectEqual(yes, try f.apart(&.{}));
    try testing.expectEqual(yes, try f.apart(&.{ s7, p1 }));
    const k = try f.apart(&.{ s7, p1, p2 });
    try testing.expectEqual(AtomKind.apart, t.get(k).atom);
    try testing.expectEqual(lost, try f.apart(&.{ try f.cells.top(gpa, &f.account), s7 }));
    var items = [_]Item{ .{ .cell = p1, .approx = true }, .{ .cell = p2, .approx = false } };
    try testing.expectEqual(lost, try t.apart(gpa, f.charge(), &f.cells, &f.places, &items, null));
    var dup = [_]Item{ .{ .cell = p1, .approx = true }, .{ .cell = p2, .approx = false }, .{ .cell = p2, .approx = false } };
    try testing.expectEqual(shared, try t.apart(gpa, f.charge(), &f.cells, &f.places, &dup, null));
    const l1 = try f.cells.label(gpa, &f.account, 40, .none, false);
    _ = try f.cells.split(gpa, &f.account, p1, 40, l1, shared);
    const e1 = try f.cells.refine(gpa, &f.account, .elem, p1, l1, 0, .none, .none);
    const o1 = try f.cells.refine(gpa, &f.account, .others, p1, l1, 0, .none, .list);
    try testing.expectEqual(shared, try f.apart(&.{ e1, o1 }));
    const xs = try f.param(3, 1, &.{});
    const kx = try t.excl(gpa, f.charge(), xs);
    _ = try f.cells.split(gpa, &f.account, xs, 41, l1, kx);
    const ex = try f.cells.refine(gpa, &f.account, .elem, xs, l1, 0, .none, .none);
    const ox = try f.cells.refine(gpa, &f.account, .others, xs, l1, 0, .none, .list);
    const kk = try f.apart(&.{ ex, ox });
    try testing.expect(t.atoms.member(try t.flat(gpa, f.charge(), kk), kx.int()));
}

test "κ maps are functional and monotone; derived defaults; a union's κ is never stale" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var t = &f.conds;
    const list = try f.placeOf(1);
    const lists = try f.placeOf(3);
    const p1 = try f.param(1, 1, &.{});
    const p2 = try f.param(2, 1, &.{});
    const top = try f.cells.top(gpa, &f.account);
    const l1 = try f.leaf(1, &.{p1});
    const l2 = try f.leaf(1, &.{p2});
    const l12 = try f.leaf(1, &.{ p1, p2 });
    const ltop = try f.leaf(1, &.{top});
    const nothing = try f.shapes.nothing(gpa, &f.account, list);
    const e1 = try t.excl(gpa, f.charge(), p1);
    // Derived: one arrival yes; two arrivals yes at a plain path (one
    // position, alternatives) but `apart` at a summary position; ⊤ lost;
    // nothing yes; a built node lost; a recast lost only where objects sit
    // below (`List (List Int)`), yes for `List Int`.
    try testing.expectEqual(yes, try f.kappa(.none, l1, true));
    try testing.expectEqual(yes, try f.kappa(.none, l12, false));
    const k12 = try f.kappa(.none, l12, true);
    try testing.expectEqual(AtomKind.apart, t.get(k12).atom);
    try testing.expectEqual(lost, try f.kappa(.none, ltop, false));
    try testing.expectEqual(yes, try f.kappa(.none, nothing, true));
    const s9 = try f.cells.site(gpa, &f.account, 9, lists, .list);
    const built = try f.shapes.node(gpa, &f.account, lists, try f.set(&.{s9}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, l1));
    try testing.expectEqual(lost, try f.kappa(.none, built, false));
    try testing.expectEqual(lost, try f.kappa(.none, try f.shapes.recast(gpa, &f.account, lists, l1), false));
    try testing.expectEqual(yes, try f.kappa(.none, try f.shapes.recast(gpa, &f.account, list, l1), false));
    // Setting is functional: the old map is untouched, the new one joins.
    const m1 = try f.setK(.none, built, yes);
    try testing.expectEqual(yes, try f.kappa(m1, built, false));
    try testing.expectEqual(lost, try f.kappa(.none, built, false));
    const same = try t.kappaSet(gpa, f.charge(), m1, built, yes);
    try testing.expect(!same.changed and same.ctx == m1);
    const m2 = try f.setK(m1, built, e1);
    try testing.expect(m2 != m1);
    try testing.expectEqual(e1, try f.kappa(m2, built, false));
    try testing.expectEqual(yes, try f.kappa(m1, built, false));
    // The reviewer's probe: a union reads the join of its sides at the time
    // of asking — after `[ x, x ]` set κ(leaf{π1}) shared in the map, the
    // union reads shared (O15), with no memo to go stale.
    const u = try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, l1, l2);
    try testing.expectEqual(yes, try f.kappa(.none, u, false));
    const m3 = try f.propagate(.none, l1, &.{ l1, l1 }, &.{ .none, .none }, .together, true);
    try testing.expectEqual(shared, try f.kappa(m3, l1, true));
    try testing.expectEqual(shared, try f.kappa(m3, u, true));
    try testing.expectEqual(AtomKind.apart, t.get(try f.kappa(.none, u, true)).atom); // two arrivals across the sides
    // Another position (a path below, where the position class is the
    // path's) stores nothing.
    try testing.expectEqual(yes, try f.kappa(f.conds.kappaChild(m3, Place.Step.elem), u, false));
    // deep: the node's κ plus `excl` of every arrival inside, keyed by the
    // map, so a changed map is a new answer.
    const d = try t.deep(gpa, f.charge(), f.view(), m2, built, false);
    const fd = try t.flat(gpa, f.charge(), d);
    try testing.expectEqual(@as(u32, 1), t.atoms.count(fd));
    try testing.expect(t.atoms.member(fd, e1.int()));
    const m4 = try f.setK(m2, built, lost);
    try testing.expectEqual(lost, try t.deep(gpa, f.charge(), f.view(), m4, built, false));
    try testing.expectEqual(d, try t.deep(gpa, f.charge(), f.view(), m2, built, false));
}

test "lower is incremental: a chain of W fresh pushes is O(W log W), a group grows by insertion" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var t = &f.conds;
    const list = try f.placeOf(1);
    const v = f.view();
    // The reviewer's probe: W fresh lists pushed one by one.
    var last: u64 = 0;
    for ([_]u32{ 100, 200, 400 }) |w| {
        var base: SetId = .none;
        var k: CondId = yes;
        const before = f.account.growth;
        var i: u32 = 0;
        while (i < w) : (i += 1) {
            const s = try f.cells.site(gpa, &f.account, 1000 * w + i, list, .list);
            const stored = try f.shapes.leaf(gpa, &f.account, list, try f.set(&.{s}));
            k = try t.lower(gpa, f.charge(), v, .none, k, base, stored, true, null);
            base = try f.cells.sets.insert(gpa, f.charge(), base, s.int(), 0);
        }
        try testing.expectEqual(yes, k);
        const cost = f.account.growth - before;
        try testing.expect(cost <= 60 * w);
        if (last > 0) try testing.expect(cost * 2 < last * 5);
        last = cost;
    }
    // Arrivals: `[ p1 ]` then push p2: the group {p1, p2} appears (the base
    // scanned once); push p3: the group grows by insertion and the old atom
    // is replaced, not kept beside; push p1 again: shared.
    const p1 = try f.param(1, 1, &.{});
    const p2 = try f.param(2, 1, &.{});
    const p3 = try f.param(3, 1, &.{});
    const lp = struct {
        fn leaf(ff: *Fixture, c: CellId) !NodeId {
            return ff.leaf(1, &.{c});
        }
    };
    var base = try f.set(&.{p1});
    var k = try t.lower(gpa, f.charge(), v, .none, yes, base, try lp.leaf(&f, p2), true, null);
    base = try f.cells.sets.insert(gpa, f.charge(), base, p2.int(), 0);
    var fl = try t.flat(gpa, f.charge(), k);
    try testing.expectEqual(@as(u32, 1), t.atoms.count(fl)); // apart{p1,p2}: p2 is one object
    const g12 = t.splitGroup(k);
    try testing.expect(g12.atom != .none);
    try testing.expectEqual(@as(u32, 2), f.cells.sets.count(.from(t.get(g12.atom).a)));
    k = try t.lower(gpa, f.charge(), v, .none, k, base, try lp.leaf(&f, p3), true, null);
    base = try f.cells.sets.insert(gpa, f.charge(), base, p3.int(), 0);
    fl = try t.flat(gpa, f.charge(), k);
    try testing.expectEqual(@as(u32, 1), t.atoms.count(fl)); // apart{p1,p2,p3}, the old group replaced
    const g123 = t.splitGroup(k);
    try testing.expectEqual(@as(u32, 3), f.cells.sets.count(.from(t.get(g123.atom).a)));
    try testing.expectEqual(shared, try t.lower(gpa, f.charge(), v, .none, k, base, try lp.leaf(&f, p1), true, null));
    try testing.expectEqual(shared, try t.lower(gpa, f.charge(), v, .none, shared, .none, try lp.leaf(&f, p2), true, null));
    // A stored value's deep condition rides along: a built node with κ lost
    // in the map makes the store lost.
    const lists = try f.placeOf(3);
    const s9 = try f.cells.site(gpa, &f.account, 9, lists, .list);
    const built = try f.shapes.node(gpa, &f.account, lists, try f.set(&.{s9}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, try lp.leaf(&f, p1)));
    const m = try f.setK(.none, built, lost);
    try testing.expectEqual(lost, try t.lower(gpa, f.charge(), v, m, yes, .none, built, true, null));
    const m_ok = try f.setKAt(.none, built, true, yes);
    const kb = try t.lower(gpa, f.charge(), v, m_ok, yes, .none, built, true, null);
    try testing.expectEqual(yes, kb); // the stored value's paths below are the children's business
}

test "propagate: a branch joins κ; a literal's elements are apart per path, below too" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var t = &f.conds;
    const list = try f.placeOf(1);
    const lists = try f.placeOf(3);
    const s7 = try f.cells.site(gpa, &f.account, 7, lists, .list);
    const s8 = try f.cells.site(gpa, &f.account, 8, lists, .list);
    const xs = try f.shapes.leaf(gpa, &f.account, list, try f.set(&.{try f.param(3, 1, &.{})}));
    const ys = try f.shapes.leaf(gpa, &f.account, list, try f.set(&.{try f.param(4, 1, &.{})}));
    const a = try f.shapes.node(gpa, &f.account, lists, try f.set(&.{s7}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, xs));
    const b = try f.shapes.node(gpa, &f.account, lists, try f.set(&.{s8}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, ys));
    const ma = try f.setK(.none, a, yes);
    const mb = try f.setK(.none, b, lost);
    // A branch: κ is the join, lost; the members' maps are untouched.
    const j = try f.join2(a, b);
    const mj = try f.propagate(.none, j, &.{ a, b }, &.{ ma, mb }, .alternatives, false);
    try testing.expectEqual(lost, try f.kappa(mj, j, false));
    try testing.expectEqual(yes, try f.kappa(ma, a, false));
    // A literal `[ xs, ys ]`: together at `[*]`, apart{p3, p4} ∧ excl both.
    const elem = try f.collect(&.{ xs, ys });
    const me = try f.propagate(.none, elem, &.{ xs, ys }, &.{ .none, .none }, .together, true);
    const fe = try t.flat(gpa, f.charge(), try f.kappa(me, elem, true));
    try testing.expectEqual(@as(u32, 1), t.atoms.count(fe)); // apart{p3, p4}: each is one object
    // `[ xs, xs ]`: shared, exact (I-κ's two positions).
    const dup = try f.collect(&.{ a, a });
    const ma_t = try f.setKAt(ma, a, true, yes);
    const md = try f.propagate(.none, dup, &.{ a, a }, &.{ ma_t, ma_t }, .together, true);
    try testing.expectEqual(shared, try f.kappa(md, dup, true));
    // The reviewer's probe: `[ p, q ]` of records. κ([*]) is apart{p, q};
    // the lazily projected `[*].b` derives apart{p.b, q.b} — a write there
    // relies on that path's own atom (R-4.6.4), never on nothing.
    const p = try f.param(1, 0, &.{});
    const q = try f.param(2, 0, &.{});
    const lp = try f.leaf(0, &.{p});
    const lq = try f.leaf(0, &.{q});
    const recs = try f.collect(&.{ lp, lq });
    const mr = try f.propagate(.none, recs, &.{ lp, lq }, &.{ .none, .none }, .together, true);
    try testing.expectEqual(AtomKind.apart, t.get(try f.kappa(mr, recs, true)).atom);
    const fb = try Place.Step.field(&f.account, 11);
    const child = (try f.shapes.proj(gpa, &f.account, &f.places, &f.cells, recs, fb)).?;
    const kc = try f.kappa(mr, child, true);
    const r = try t.rely(gpa, f.charge(), kc);
    try testing.expect(r == .xreq);
    const pb = try f.param(1, 0, &.{fb});
    const qb = try f.param(2, 0, &.{fb});
    try testing.expect(t.atoms.member(r.xreq, (try t.apartAtom(gpa, f.charge(), try f.set(&.{ pb, qb }))).int()));
    // And the other direction: at a plain (non-summary) path two arrivals
    // of a LEAF are alternatives, κ yes — while a positions node is
    // positions wherever the reader thinks it sits.
    try testing.expectEqual(yes, try f.kappa(mr, try f.projOf(try f.join2(lp, lq), fb), false));
    try testing.expectEqual(AtomKind.apart, t.get(try f.kappa(mr, child, false)).atom);
}

test "kappaLeq is a simulation over the node correspondence" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var t = &f.conds;
    const rec = try f.placeOf(0);
    const p3 = try f.param(3, 1, &.{});
    const p4 = try f.param(4, 1, &.{});
    const p5 = try f.param(5, 1, &.{});
    const x = try f.leaf(1, &.{p3});
    const y_good = try f.leaf(1, &.{ p3, p4 });
    const y_bad = try f.leaf(1, &.{ p3, p5 });
    const e = try t.excl(gpa, f.charge(), p4);
    const fa = try Place.Step.field(&f.account, 10);
    const fb = try Place.Step.field(&f.account, 11);
    // `excl p4` stored for `x` and `y_good` wherever they stand.
    var m = try f.setKPath(.none, &.{fa}, x, e);
    m = try f.setKPath(m, &.{fb}, x, e);
    const s1 = try f.cells.result(gpa, &f.account, .result, .none, 1, rec, .record);
    const a = try f.shapes.node(gpa, &f.account, rec, try f.set(&.{s1}), try f.shapes.overPut(gpa, &f.account, try f.shapes.overPut(gpa, &f.account, Ids.none_int, fa, x), fb, x));
    m = try f.setK(m, a, yes);
    // The reviewer's probe: `{ a = X, b = X }` against `{ a = Y_bad, b =
    // Y_good }` in either order is NOT below (κ(X) = excl ⋢ κ(Y_bad) = yes).
    for ([_][2]NodeId{ .{ y_bad, y_good }, .{ y_good, y_bad } }) |pair| {
        const b = try f.shapes.node(gpa, &f.account, rec, try f.set(&.{s1}), try f.shapes.overPut(gpa, &f.account, try f.shapes.overPut(gpa, &f.account, Ids.none_int, fa, pair[0]), fb, pair[1]));
        var mb = try f.setK(.none, b, yes);
        for ([_]Place.Step{ fa, fb }, pair) |s, n| if (n == y_good) {
            mb = try f.setKPath(mb, &.{s}, n, e);
        };
        try testing.expect(!try t.kappaLeq(gpa, f.charge(), f.view(), m, a, mb, b, false));
    }
    // And a true inclusion holds, in a different map.
    const b_ok = try f.shapes.node(gpa, &f.account, rec, try f.set(&.{s1}), try f.shapes.overPut(gpa, &f.account, try f.shapes.overPut(gpa, &f.account, Ids.none_int, fa, y_good), fb, y_good));
    var mok = try f.setK(.none, b_ok, yes);
    mok = try f.setKPath(mok, &.{fa}, y_good, e);
    mok = try f.setKPath(mok, &.{fb}, y_good, e);
    try testing.expect(try t.kappaLeq(gpa, f.charge(), f.view(), m, a, mok, b_ok, false));
    try testing.expect(try t.kappaLeq(gpa, f.charge(), f.view(), m, a, m, a, false));
}

test "instantiate maps every atom through the interpreter; print is v1's grammar" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var t = &f.conds;
    const p1 = try f.param(1, 1, &.{});
    const p2 = try f.param(2, 1, &.{});
    const p3 = try f.param(3, 1, &.{});
    const e1 = try t.excl(gpa, f.charge(), p1);
    const s12 = try t.sepAtom(gpa, f.charge(), p2, p1);
    const grp = try t.apartAtom(gpa, f.charge(), try f.set(&.{ p1, p2, p3 }));
    const l = try f.cells.label(gpa, &f.account, 40, .none, true);
    const w = try t.within(gpa, f.charge(), l);
    const k = try t.@"and"(gpa, f.charge(), try t.@"and"(gpa, f.charge(), e1, s12), try t.@"and"(gpa, f.charge(), grp, w));
    const I = struct {
        fn atom(_: *anyopaque, tt: *Table, g: Allocator, ch: Charge, a: Cond) Error!CondId {
            return switch (a.atom) {
                .excl => yes,
                .within => lost,
                else => tt.make(g, ch, a),
            };
        }
    };
    var dummy: u8 = 0;
    try testing.expectEqual(lost, try t.instantiate(gpa, f.charge(), k, .{ .ctx = &dummy, .atom = I.atom }));
    const k2 = try t.@"and"(gpa, f.charge(), e1, try t.@"and"(gpa, f.charge(), s12, grp));
    const out2 = try t.instantiate(gpa, f.charge(), k2, .{ .ctx = &dummy, .atom = I.atom });
    const fo = try t.flat(gpa, f.charge(), out2);
    try testing.expectEqual(@as(u32, 2), t.atoms.count(fo));
    try testing.expect(t.atoms.member(fo, s12.int()) and t.atoms.member(fo, grp.int()));
    try testing.expectEqual(shared, try t.instantiate(gpa, f.charge(), shared, .{ .ctx = &dummy, .atom = I.atom }));
    const P = struct {
        fn cell(ctx: *anyopaque, wr: *std.Io.Writer, c: CellId) std.Io.Writer.Error!void {
            const ct: *const Cell.Table = @ptrCast(@alignCast(ctx));
            try wr.print("π{d}", .{ct.get(c).a});
        }
        fn label(_: *anyopaque, wr: *std.Io.Writer, _: LabelId) std.Io.Writer.Error!void {
            try wr.writeAll("ι⋆");
        }
    };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try t.print(gpa, f.charge(), arena.allocator(), &buf.writer, k, &f.cells, .{ .ctx = &f.cells, .cell = P.cell, .label = P.label });
    try testing.expectEqualStrings("{apart [π1] [π2] [π3], excl π1, sep π1 π2, within ι⋆}", buf.written());
    buf.clearRetainingCapacity();
    try t.print(gpa, f.charge(), arena.allocator(), &buf.writer, lost, &f.cells, .{ .ctx = &f.cells, .cell = P.cell, .label = P.label });
    try testing.expectEqualStrings("{lost}", buf.written());
    buf.clearRetainingCapacity();
    try t.print(gpa, f.charge(), arena.allocator(), &buf.writer, yes, &f.cells, .{ .ctx = &f.cells, .cell = P.cell, .label = P.label });
    try testing.expectEqualStrings("", buf.written());
}

test "a refused reservation leaves the condition table and the maps whole" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const p1 = try f.param(1, 1, &.{});
    const l1 = try f.leaf(1, &.{p1});
    var broke: Ids.Account = .{ .allowance = 0 };
    defer broke.deinit(gpa);
    const n = f.conds.count();
    try testing.expectError(error.OwnershipLimit, f.conds.excl(gpa, .growth(&broke), p1));
    try testing.expectError(error.OwnershipLimit, f.conds.kappaSet(gpa, .growth(&broke), .none, l1, lost));
    try testing.expectEqual(n, f.conds.count());
    try testing.expectEqual(@as(usize, 0), f.conds.kmaps.len);
    const e = try f.conds.excl(gpa, f.charge(), p1);
    try testing.expectEqual(n, e.int());
    const before = f.account.growth;
    try testing.expectEqual(e, try f.conds.excl(gpa, f.charge(), p1));
    try testing.expectEqual(before + 1, f.account.growth);
    var lane_account: Ids.Account = .{ .allowance = 0 };
    defer lane_account.deinit(gpa);
    var t2 = try Table.init(gpa, .in(&lane_account, .{ .atom = 1, .role = .cond_index }));
    defer t2.deinit(gpa);
    _ = try t2.excl(gpa, .in(&lane_account, .{ .atom = 1, .role = .cond_index }), p1);
    try testing.expectEqual(@as(u32, 0), lane_account.growth);
    try testing.expectEqual(@as(u64, 4), lane_account.baseline);
}

test "a projected leaf: one object yes, a summary arrival excl, several arrivals apart, below too" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var t = &f.conds;
    const p1 = try f.param(1, 3, &.{});
    const p2 = try f.param(2, 3, &.{});
    const p1e = try f.param(1, 3, &.{Place.Step.elem});
    const p2e = try f.param(2, 3, &.{Place.Step.elem});
    // `xs : List (List Int)` projected: `xs[*]` is one arrival that stands
    // for many positions → `excl xs[*]` at the summary position, `yes` at a
    // plain one; two such arrivals (`List.append xs ys`'s `[*]`) → both
    // `excl` and `apart`; two single objects at `[*]` → `apart` alone.
    const one = try f.leaf(1, &.{p1e});
    try testing.expectEqual(try t.excl(gpa, f.charge(), p1e), try f.kappa(.none, one, true));
    try testing.expectEqual(yes, try f.kappa(.none, one, false));
    const two = try f.leaf(1, &.{ p1e, p2e });
    const k2 = try t.flat(gpa, f.charge(), try f.kappa(.none, two, true));
    try testing.expectEqual(@as(u32, 3), t.atoms.count(k2));
    try testing.expect(t.atoms.member(k2, (try t.excl(gpa, f.charge(), p1e)).int()));
    try testing.expect(t.atoms.member(k2, (try t.apartAtom(gpa, f.charge(), try f.set(&.{ p1e, p2e }))).int()));
    const plain = try f.leaf(3, &.{ p1, p2 });
    const kp = try f.kappa(.none, plain, true);
    try testing.expectEqual(AtomKind.apart, t.get(kp).atom);
    // The projection of that leaf below `[*]` (lazily, through `proj`) is
    // a leaf of two summary arrivals and derives its own atoms: the write
    // at `[*][*]` relies on them (R-4.6.4), never on `yes`.
    const below = (try f.shapes.proj(gpa, &f.account, &f.places, &f.cells, plain, Place.Step.elem)).?;
    const kb = try t.flat(gpa, f.charge(), try f.kappa(.none, below, true));
    try testing.expectEqual(@as(u32, 3), t.atoms.count(kb));
    try testing.expect(t.atoms.member(kb, (try t.excl(gpa, f.charge(), p1e)).int()));
}

test "the cross-path holder twin `[ (a, b), (b, a) ]`: the position is shared, each component apart" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var t = &f.conds;
    // A pair of lists as a record `{ a, b }` (the fixture's tuple), two
    // positions holding `(x, y)` and `(y, x)`.
    const rec = try f.placeOf(0);
    const fa = try Place.Step.field(&f.account, 10);
    const fb = try Place.Step.field(&f.account, 11);
    const x = try f.param(1, 1, &.{});
    const y = try f.param(2, 1, &.{});
    const lx = try f.leaf(1, &.{x});
    const ly = try f.leaf(1, &.{y});
    const s1 = try f.cells.result(gpa, &f.account, .result, .none, 1, rec, .record);
    const s2 = try f.cells.result(gpa, &f.account, .result, .none, 2, rec, .record);
    const xy = try f.shapes.node(gpa, &f.account, rec, try f.set(&.{s1}), try f.shapes.overPut(gpa, &f.account, try f.shapes.overPut(gpa, &f.account, Ids.none_int, fa, lx), fb, ly));
    const yx = try f.shapes.node(gpa, &f.account, rec, try f.set(&.{s2}), try f.shapes.overPut(gpa, &f.account, try f.shapes.overPut(gpa, &f.account, Ids.none_int, fa, ly), fb, lx));
    var m = try f.setKAt(.none, xy, true, yes);
    m = try f.setKAt(m, yx, true, yes);
    const elem = try f.collect(&.{ xy, yx });
    const me = try f.conds.propagate(gpa, f.charge(), f.view(), m, elem, &.{ xy, yx }, &.{ m, m }, .together, true, null);
    // Per component, the positions are apart: `.a` holds x and y, `.b` holds
    // y and x — each an `apart{x, y}` atom (R-4.6.4: a write at `.b` relies
    // on `.b`'s). The position itself holds x twice across its paths: shared
    // — the alias in the sibling component is visible at `[*]`, and the
    // holder check (Dead, §2.8) must find it; per-component κ never hides it.
    const ca = (try f.shapes.proj(gpa, &f.account, &f.places, &f.cells, elem, fa)).?;
    const cb = (try f.shapes.proj(gpa, &f.account, &f.places, &f.cells, elem, fb)).?;
    try testing.expectEqual(AtomKind.apart, t.get(try f.kappa(me, ca, true)).atom);
    try testing.expectEqual(AtomKind.apart, t.get(try f.kappa(me, cb, true)).atom);
    try testing.expectEqual(shared, try f.kappa(me, elem, true));
    // `[ (x, y), (z, w) ]` with four lists: nothing shared anywhere.
    const z = try f.param(3, 1, &.{});
    const w = try f.param(4, 1, &.{});
    const s3 = try f.cells.result(gpa, &f.account, .result, .none, 3, rec, .record);
    const zw = try f.shapes.node(gpa, &f.account, rec, try f.set(&.{s3}), try f.shapes.overPut(gpa, &f.account, try f.shapes.overPut(gpa, &f.account, Ids.none_int, fa, try f.leaf(1, &.{z})), fb, try f.leaf(1, &.{w})));
    const m2 = try f.setKAt(m, zw, true, yes);
    const elem2 = try f.collect(&.{ xy, zw });
    const me2 = try f.conds.propagate(gpa, f.charge(), f.view(), m2, elem2, &.{ xy, zw }, &.{ m2, m2 }, .together, true, null);
    try testing.expectEqual(AtomKind.apart, t.get(try f.kappa(me2, elem2, true)).atom);
}

test "fault injection: a refusal before any dictionary, memo or path operation leaves every table whole" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var t = &f.conds;
    const list = try f.placeOf(1);
    const p1 = try f.param(1, 1, &.{});
    const p2 = try f.param(2, 1, &.{});
    const l1 = try f.leaf(1, &.{p1});
    const l12 = try f.leaf(1, &.{ p1, p2 });
    const built = try f.shapes.node(gpa, &f.account, try f.placeOf(3), try f.set(&.{try f.cells.site(gpa, &f.account, 9, list, .list)}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, l1));
    const e1 = try t.excl(gpa, f.charge(), p1);
    const a12 = try t.@"and"(gpa, f.charge(), e1, try t.excl(gpa, f.charge(), p2));
    // Every allowance from 0 upward until the operation succeeds: whatever
    // step is refused, the tables have exactly what they had.
    const Snapshot = struct { conds: usize, kmaps: usize, atoms: usize, sets: usize, shapes: u32, cells: u32 };
    const snap = struct {
        fn take(ff: *Fixture) Snapshot {
            return .{ .conds = ff.conds.conds.len, .kmaps = ff.conds.kmaps.len, .atoms = ff.conds.atoms.nodes.len, .sets = ff.cells.sets.nodes.len, .shapes = ff.shapes.count(), .cells = ff.cells.count() };
        }
    };
    var allowance: u32 = 0;
    var op: u32 = 0;
    while (op < 7) : (op += 1) {
        allowance = 0;
        while (allowance < 4000) : (allowance += 1) {
            var broke: Ids.Account = .{ .allowance = allowance };
            defer broke.deinit(gpa);
            const ch: Charge = .growth(&broke);
            const before = snap.take(&f);
            var items = [_]Item{ .{ .cell = p1, .approx = false }, .{ .cell = p2, .approx = false } };
            const r: Error!void = switch (op) {
                0 => if (t.excl(gpa, ch, p2)) |_| {} else |e| e,
                1 => if (t.flat(gpa, ch, a12)) |_| {} else |e| e,
                2 => if (t.apart(gpa, ch, &f.cells, &f.places, &items, null)) |_| {} else |e| e,
                3 => if (t.kappaSet(gpa, ch, .none, l12, lost)) |_| {} else |e| e,
                4 => if (t.deep(gpa, ch, f.view(), .none, built, false)) |_| {} else |e| e,
                5 => if (t.lower(gpa, ch, f.view(), .none, yes, try f.set(&.{p1}), l12, true, null)) |_| {} else |e| e,
                else => if (t.propagate(gpa, ch, f.view(), .none, l12, &.{ l1, l12 }, &.{ .none, .none }, .together, true, null)) |_| {} else |e| e,
            };
            if (r) |_| {
                break; // enough allowance: the operation ran
            } else |err| {
                try testing.expectEqual(error.OwnershipLimit, err);
                // What a refused step had already reserved and built stays
                // (an interned record is never half-written: a later owner
                // reads a whole table), and nothing was built past the refusal.
                const after = snap.take(&f);
                try testing.expect(after.conds >= before.conds and after.kmaps >= before.kmaps and after.atoms >= before.atoms);
                // Every interned condition and map node is readable.
                var i: usize = before.conds;
                while (i < after.conds) : (i += 1) _ = t.get(.from(@intCast(i)));
            }
        }
        try testing.expect(allowance < 4000);
    }
    // After every refusal, a whole owner still gets whole answers.
    const k = try t.lower(gpa, f.charge(), f.view(), .none, yes, try f.set(&.{p1}), l12, true, null);
    try testing.expectEqual(shared, k);
    try testing.expectEqual(e1, try t.excl(gpa, f.charge(), p1));
}

test "red twin CallbackFieldPositions: a plain-path κ never answers a summary-path read" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var t = &f.conds;
    // `g : Int → { a : List Int, b : List Int }` called twice: `cb@ι₁`, `cb@ι₂`.
    const rec = try f.placeOf(0);
    const fa = try Place.Step.field(&f.account, 10);
    const l1 = try f.cells.label(gpa, &f.account, 40, .none, false);
    const l2 = try f.cells.label(gpa, &f.account, 41, .none, false);
    const root = try f.places.rootPath(gpa, rec);
    const g1 = try f.cells.symbolic(gpa, &f.account, &f.places, .cb, l1.int(), root, 0);
    const g2 = try f.cells.symbolic(gpa, &f.account, &f.places, .cb, l2.int(), root, 0);
    const r1 = try f.leaf(0, &.{g1});
    const r2 = try f.leaf(0, &.{g2});
    // `w = if c then (g 1).a else (g 2).a`: a branch at a plain path stores
    // `yes` for the interned leaf `{cb@ι₁·.a, cb@ι₂·.a}`.
    const a1 = (try f.shapes.proj(gpa, &f.account, &f.places, &f.cells, r1, fa)).?;
    const a2 = (try f.shapes.proj(gpa, &f.account, &f.places, &f.cells, r2, fa)).?;
    const w = try f.join2(a1, a2);
    const m = try f.propagate(.none, w, &.{ a1, a2 }, &.{ .none, .none }, .alternatives, false);
    try testing.expectEqual(yes, try f.kappa(m, w, false));
    // `[ g 1, g 2 ]` in the same frame: `[*].a` projects to the two
    // positions over that leaf's cells.
    const elem = try f.collect(&.{ r1, r2 });
    const me = try f.conds.propagate(gpa, f.charge(), f.view(), m, elem, &.{ r1, r2 }, &.{ m, m }, .together, true, null);
    const ea = (try f.shapes.proj(gpa, &f.account, &f.places, &f.cells, elem, fa)).?;
    try testing.expectEqual(Shape.Kind.positions, f.shapes.kind(ea));
    try testing.expectEqual(try f.shapes.cellsOf(gpa, &f.account, &f.cells.sets, w), try f.shapes.cellsOf(gpa, &f.account, &f.cells.sets, ea));
    // Read at the summary position it is `apart{cb@ι₁·.a, cb@ι₂·.a}`, never
    // the plain path's `yes`: a write at `[*].a` relies on the atom. So is
    // the leaf itself, under the branch's map that stored `yes` for it.
    const ka = try f.kappa(me, ea, true);
    try testing.expectEqual(AtomKind.apart, t.get(ka).atom);
    try testing.expectEqual(ka, try f.kappa(m, w, true));
    try testing.expect((try t.rely(gpa, f.charge(), ka)) == .xreq);
    try testing.expectEqual(yes, try f.kappa(me, w, false));
}

test "a union's κ is read once per node of a shared union DAG: depth 64, 128, 256" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    f.account.allowance = 1 << 24;
    var last: u64 = 0;
    for ([_]u32{ 64, 128, 256 }) |depth| {
        // `u_k = if c then (if d then u_{k−1} else a_k) else (if e then u_{k−1} else b_k)`.
        var u = try f.leaf(1, &.{try f.param(1, 1, &.{})});
        var k: u32 = 0;
        while (k < depth) : (k += 1) {
            const a = try f.shapes.leaf(gpa, &f.account, list, try f.set(&.{try f.cells.site(gpa, &f.account, 100_000 * depth + 2 * k, list, .list)}));
            const b = try f.shapes.leaf(gpa, &f.account, list, try f.set(&.{try f.cells.site(gpa, &f.account, 100_000 * depth + 2 * k + 1, list, .list)}));
            const l = try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, u, a);
            const r = try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, u, b);
            u = try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, l, r);
        }
        const before = f.account.growth;
        try testing.expectEqual(yes, try f.kappa(.none, u, false));
        const cost = f.account.growth - before;
        try testing.expect(cost <= 12 * depth);
        if (last > 0) try testing.expect(cost * 2 < last * 5);
        last = cost;
    }
}

test "red twin CallbackFieldPositionsBranch: a stored summary κ never weakens the read's derivation" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var t = &f.conds;
    const rec = try f.placeOf(0);
    const fa = try Place.Step.field(&f.account, 10);
    const l1 = try f.cells.label(gpa, &f.account, 40, .none, false);
    const l2 = try f.cells.label(gpa, &f.account, 41, .none, false);
    const root = try f.places.rootPath(gpa, rec);
    const g1 = try f.cells.symbolic(gpa, &f.account, &f.places, .cb, l1.int(), root, 0);
    const g2 = try f.cells.symbolic(gpa, &f.account, &f.places, .cb, l2.int(), root, 0);
    const r1 = try f.leaf(0, &.{g1});
    const r2 = try f.leaf(0, &.{g2});
    const a1 = (try f.shapes.proj(gpa, &f.account, &f.places, &f.cells, r1, fa)).?;
    const a2 = (try f.shapes.proj(gpa, &f.account, &f.places, &f.cells, r2, fa)).?;
    // `if c then [ (g 1).a ] else [ (g 2).a ]`: two one-element lists; the
    // joined `[*]` is the leaf `{cb@ι₁·.a, cb@ι₂·.a}` with ONE position per
    // branch, so the branch's κ there is `yes` — no stronger than the
    // leaf's derivation, so it stores nothing.
    const w = try f.join2(a1, a2);
    const m = try f.propagate(.none, w, &.{ a1, a2 }, &.{ .none, .none }, .alternatives, true);
    try testing.expectEqual(@as(?CondId, null), t.kappaGet(m, w));
    // `[ g 1, g 2 ]` in the same frame: `[*].a` holds that leaf's cells at
    // TWO positions. The read joins the stored `yes` with the derivation at
    // the read's position: `apart`, and `rely` is `xreq`, never `ok` — for
    // the positions node and, under the branch's own map, for the leaf.
    const elem = try f.collect(&.{ r1, r2 });
    const me = try f.conds.propagate(gpa, f.charge(), f.view(), m, elem, &.{ r1, r2 }, &.{ m, m }, .together, true, null);
    const ea = (try f.shapes.proj(gpa, &f.account, &f.places, &f.cells, elem, fa)).?;
    try testing.expectEqual(try f.shapes.cellsOf(gpa, &f.account, &f.cells.sets, w), try f.shapes.cellsOf(gpa, &f.account, &f.cells.sets, ea));
    const ka = try f.kappa(me, ea, true);
    try testing.expectEqual(AtomKind.apart, t.get(ka).atom);
    try testing.expectEqual(ka, try f.kappa(m, w, true));
    try testing.expect((try t.rely(gpa, f.charge(), ka)) == .xreq);
    // And under the branch's own map the same leaf reads `apart` too: a
    // stored `yes` is never a weaker answer than the position derives.
    try testing.expectEqual(AtomKind.apart, t.get(try f.kappa(m, w, true)).atom);
    // A stored constraint is kept: `shared` stored at the position stays.
    const ms = try f.setKAt(.none, w, true, shared);
    try testing.expectEqual(shared, try f.kappa(ms, w, true));
}

test "red twin CallbackFieldPositionsUnion: an unstored union at a summary position compares cells across sides" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var t = &f.conds;
    // `if c then { a = (g 1).a } else { a = (g 2).a }` as an element: `[*].a`
    // is the union of the one-cell leaves `{cb@ι₁·.a}` and `{cb@ι₂·.a}` — a
    // union the walk never stored (as `Shape.map` makes at an instantiation).
    const rec = try f.placeOf(0);
    const fa = try Place.Step.field(&f.account, 10);
    const l1 = try f.cells.label(gpa, &f.account, 40, .none, false);
    const l2 = try f.cells.label(gpa, &f.account, 41, .none, false);
    const root = try f.places.rootPath(gpa, rec);
    const g1 = try f.cells.symbolic(gpa, &f.account, &f.places, .cb, l1.int(), root, 0);
    const g2 = try f.cells.symbolic(gpa, &f.account, &f.places, .cb, l2.int(), root, 0);
    const a1 = (try f.shapes.proj(gpa, &f.account, &f.places, &f.cells, try f.leaf(0, &.{g1}), fa)).?;
    const a2 = (try f.shapes.proj(gpa, &f.account, &f.places, &f.cells, try f.leaf(0, &.{g2}), fa)).?;
    const s1 = try f.cells.result(gpa, &f.account, .result, .none, 1, rec, .record);
    const s2 = try f.cells.result(gpa, &f.account, .result, .none, 2, rec, .record);
    const r1 = try f.shapes.node(gpa, &f.account, rec, try f.set(&.{s1}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, fa, a1));
    const r2 = try f.shapes.node(gpa, &f.account, rec, try f.set(&.{s2}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, fa, a2));
    const elem = try f.join2(r1, r2);
    try testing.expectEqual(Shape.Kind.@"union", f.shapes.kind(elem));
    const ea = (try f.shapes.proj(gpa, &f.account, &f.places, &f.cells, elem, fa)).?;
    try testing.expectEqual(Shape.Kind.@"union", f.shapes.kind(ea));
    // Read from an empty map at the summary position: `apart` over the two
    // sides' cells, as the one leaf `{cb@ι₁·.a, cb@ι₂·.a}` derives; at a
    // plain path `yes`.
    const ka = try f.kappa(.none, ea, true);
    try testing.expectEqual(AtomKind.apart, t.get(ka).atom);
    try testing.expectEqual(ka, try f.kappa(.none, try f.leaf(1, &.{ f.firstCell(f.shapes.cells(a1)), f.firstCell(f.shapes.cells(a2)) }), true));
    try testing.expectEqual(yes, try f.kappa(.none, ea, false));
    try testing.expect((try t.rely(gpa, f.charge(), ka)) == .xreq);
}

test "red twin PositionsRepeatArg: `[ { a = a }, { a = b } ]` at `f x x` is shared; BranchSameElement stays yes; a collection is a multiset whatever its tree" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var t = &f.conds;
    const fa = try Place.Step.field(&f.account, 10);
    // The callee: two parameter records as the literal's elements. `[*].a`
    // projects to `positions(leaf{π₁·.a}, leaf{π₂·.a})`, the kind kept.
    const l1 = try f.leaf(0, &.{try f.param(1, 0, &.{})});
    const l2 = try f.leaf(0, &.{try f.param(2, 0, &.{})});
    const elem = try f.collect(&.{ l1, l2 });
    try testing.expectEqual(Shape.Kind.positions, f.shapes.kind(elem));
    const ea = try f.projOf(elem, fa);
    try testing.expectEqual(Shape.Kind.positions, f.shapes.kind(ea));
    try testing.expectEqual(AtomKind.apart, t.get(try f.kappa(.none, ea, true)).atom);
    // `f x x`: every parameter cell becomes `x`'s at the same path. Both
    // sides are now ONE leaf, and the multiset `{x·.a, x·.a}` is shared —
    // read from an empty map, as an instantiation's fresh nodes are.
    const Subst = struct {
        fn relabel(fx: *Fixture, s: SetId) Error!SetId {
            var out: SetId = .none;
            var it = fx.cells.sets.iterate(s);
            while (it.next()) |e| {
                const rec = fx.cells.get(.from(e.key));
                const c = try fx.cells.symbolic(testing.allocator, &fx.account, &fx.places, .param, 5, .from(rec.b), rec.c);
                out = try fx.cells.sets.insert(testing.allocator, fx.charge(), out, c.int(), e.value);
            }
            return out;
        }
    };
    const xa = try f.shapes.map(gpa, &f.account, ea, &f, Subst.relabel);
    try testing.expectEqual(Shape.Kind.positions, f.shapes.kind(xa));
    try testing.expectEqual(f.shapes.nodes.items(.a)[xa.int()], f.shapes.nodes.items(.b)[xa.int()]);
    try testing.expectEqual(shared, try f.kappa(.none, xa, true));
    try testing.expect((try t.rely(gpa, f.charge(), shared)) == .refused);
    // BranchSameElement: `if c then [ x ] else [ x ]` joins ALTERNATIVES. The
    // same substitution leaves one position, `yes`: through `join` (one
    // merged leaf) and through a raw union of two sides that became equal.
    const j = try f.shapes.map(gpa, &f.account, try f.join2(l1, l2), &f, Subst.relabel);
    try testing.expectEqual(yes, try f.kappa(.none, try f.projOf(j, fa), true));
    const u = try f.shapes.map(gpa, &f.account, try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, l1, l2), &f, Subst.relabel);
    try testing.expectEqual(Shape.Kind.@"union", f.shapes.kind(u));
    try testing.expectEqual(yes, try f.kappa(.none, try f.projOf(u, fa), true));
    // The multiset is read whatever the tree: `[ a, b, c ]` in any order and
    // nesting is one `apart`; `[ a, b, a ]` and `[ a, a, b ]` are shared.
    const l3 = try f.leaf(0, &.{try f.param(3, 0, &.{})});
    const abc = try f.kappa(.none, try f.collect(&.{ l1, l2, l3 }), true);
    try testing.expectEqual(AtomKind.apart, t.get(abc).atom);
    try testing.expectEqual(abc, try f.kappa(.none, try f.collect(&.{ l3, l1, l2 }), true));
    try testing.expectEqual(abc, try f.kappa(.none, try f.collect(&.{ l2, try f.collect(&.{ l3, l1 }) }), true));
    try testing.expectEqual(shared, try f.kappa(.none, try f.collect(&.{ l1, l2, l1 }), true));
    try testing.expectEqual(shared, try f.kappa(.none, try f.collect(&.{ l1, l1, l2 }), true));
    // A cell on one side of an alternative and at another position may be
    // held twice: `[ if c then a else b, a ]` is shared.
    try testing.expectEqual(shared, try f.kappa(.none, try f.collect(&.{ try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, l1, l2), l1 }), true));
    // A repeat through an approximate side is `lost`, never exact — the
    // recast an immediate side, or reached through a union in the side
    // (`positions(union(cast a, c), a)`); a side with no recast anywhere
    // keeps its repeat exact.
    const cast = try f.shapes.recast(gpa, &f.account, try f.placeOf(0), l1);
    try testing.expectEqual(lost, try f.kappa(.none, try f.collect(&.{ cast, l1 }), true));
    try testing.expectEqual(lost, try f.kappa(.none, try f.collect(&.{ try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, cast, l3), l1 }), true));
    try testing.expectEqual(shared, try f.kappa(.none, try f.collect(&.{ try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, l1, l3), try f.collect(&.{ l1, l2 }) }), true));
}

test "a positions DAG reads in linear time: depth 250, 500, 1000" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    f.account.allowance = 1 << 24;
    var last: u64 = 0;
    for ([_]u32{ 250, 500, 1000 }) |depth| {
        // `[ …u_{k−1}, a_k ]`: a spread chain, every element its own site.
        var u = try f.leaf(1, &.{try f.param(1, 1, &.{})});
        var k: u32 = 0;
        while (k < depth) : (k += 1) {
            const a = try f.shapes.leaf(gpa, &f.account, list, try f.set(&.{try f.cells.site(gpa, &f.account, 100_000 * depth + k, list, .list)}));
            u = try f.collect(&.{ u, a });
        }
        // The chain's lazy sets (#1098) built first: the read is what is counted.
        _ = try f.shapes.cellsOf(gpa, &f.account, &f.cells.sets, u);
        const before = f.account.growth;
        try testing.expectEqual(yes, try f.kappa(.none, u, true));
        const cost = f.account.growth - before;
        // A cold read builds the derivation's memos per radix node of the
        // root's set (#1121): about 21 records an element, where one sorted
        // list was 16. The doubling below is what pins linear time.
        try testing.expect(cost <= 24 * depth);
        if (last > 0) try testing.expect(cost * 2 < last * 5);
        last = cost;
    }
}

test "the Rose fold: widen folds a collection on the cycle into its class, its `[*]` reads lost and never shared, and `F(x) ⊑ x` holds" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const rose = try f.placeOf(6);
    const kids = try f.placeOf(7);
    const arg = try f.places.ctorStep(gpa, &f.account, 6, 0);
    const rk = Cell.Kind.ofPlace(f.places.kind(rose));
    const lk = Cell.Kind.ofPlace(f.places.kind(kids));
    // `Rose [ Rose [], Rose [] ]`: four sites, the children a collection.
    const empty = try f.shapes.nothing(gpa, &f.account, kids);
    const ra = try f.shapes.node(gpa, &f.account, rose, try f.set(&.{try f.cells.site(gpa, &f.account, 2, rose, rk)}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, arg, empty));
    const rb = try f.shapes.node(gpa, &f.account, rose, try f.set(&.{try f.cells.site(gpa, &f.account, 3, rose, rk)}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, arg, empty));
    const s_list = try f.cells.site(gpa, &f.account, 4, kids, lk);
    const lit = try f.shapes.node(gpa, &f.account, kids, try f.set(&.{s_list}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, try f.collect(&.{ ra, rb })));
    const s_root = try f.cells.site(gpa, &f.account, 1, rose, rk);
    const root = try f.shapes.node(gpa, &f.account, rose, try f.set(&.{s_root}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, arg, lit));
    // The children re-enter `Rose`: widening ties `[*]` back to the root's
    // class. The collection is on the cycle, so its two children are
    // members of that class too (§2.3, #1120): one knot, no side kept
    // beside it, and its repeat is κ's business (`many`, below). Since
    // #1253 the first return to `Rose` is a plain path, so the value is
    // that return below a root `Rose [ root ]`, and `w` is its class.
    const outer_lit = try f.shapes.node(gpa, &f.account, kids, try f.set(&.{try f.cells.site(gpa, &f.account, 6, kids, lk)}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, root));
    const outer = try f.shapes.node(gpa, &f.account, rose, try f.set(&.{try f.cells.site(gpa, &f.account, 5, rose, rk)}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, arg, outer_lit));
    const ww = try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, outer);
    try testing.expect(ww != outer);
    const w = try f.projOf(try f.projOf(ww, arg), Place.Step.elem);
    try testing.expectEqual(Shape.Kind.node, f.shapes.kind(w));
    // `[*]` leads back to the knot (joined with the empty list's nothing).
    const back = try f.projOf(try f.projOf(w, arg), Place.Step.elem);
    try testing.expect(back == w or (f.shapes.kind(back) == .@"union" and (f.shapes.get(back).a == w.int() or f.shapes.get(back).b == w.int())));
    try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, root, w));
    // `[*]` of the widened children reads through the image, a built node
    // the fold gave no κ: `lost`, approximate — never exact `shared` for
    // the two distinct children the fold put in one class.
    const at_elem = try f.projOf(try f.projOf(w, arg), Place.Step.elem);
    try testing.expectEqual(lost, try f.kappa(.none, at_elem, true));
    try testing.expectEqual(lost, try f.kappa(.none, w, true));
    // `F(x) ⊑ x`: another `Rose [ x, x ]` over the widened value, the same
    // sites, is below it — γ-inclusion settles the fixpoint in one step
    // whatever the kinds inside (O4; the repeat `[ x, x ]` is κ's).
    const fx_lit = try f.shapes.node(gpa, &f.account, kids, try f.set(&.{s_list}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, try f.collect(&.{ w, w })));
    const fx = try f.shapes.node(gpa, &f.account, rose, try f.set(&.{s_root}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, arg, fx_lit));
    try testing.expect(try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, fx, w));
    try testing.expect(!try f.shapes.leq(gpa, &f.account, &f.places, &f.cells, w, fx));
    try testing.expectEqual(shared, try f.kappa(.none, try f.projOf(fx_lit, Place.Step.elem), true));
}

test "#1063: a κ stored below a leaf's projection survives propagation, and at an empty projection" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    // `p : List (List Int)`, the leaf `{p}`; its `[*]` is a projected leaf.
    const p = try f.param(0, 3, &.{});
    const root = try f.leaf(3, &.{p});
    const child = try f.projOf(root, Place.Step.elem);
    const old = try f.setKPath(.none, &.{Place.Step.elem}, child, shared);
    try testing.expectEqual(shared, try f.kappaPath(old, &.{Place.Step.elem}, child, true));
    const out = try f.propagate(.none, root, &.{root}, &.{old}, .alternatives, false);
    try testing.expectEqual(shared, try f.kappaPath(out, &.{Place.Step.elem}, child, true));
    // An empty projection holding a stored entry: a concrete list's `[*]`
    // is a leaf with no cells, and still a position.
    const site = try f.cells.site(gpa, &f.account, 7, try f.placeOf(3), .list);
    const lit = try f.leaf(3, &.{site});
    const empty = try f.projOf(lit, Place.Step.elem);
    try testing.expectEqual(SetId.none, f.shapes.cells(empty));
    const empty_old = try f.setKPath(.none, &.{Place.Step.elem}, empty, lost);
    const empty_out = try f.propagate(.none, lit, &.{lit}, &.{empty_old}, .alternatives, false);
    try testing.expectEqual(lost, try f.kappaPath(empty_out, &.{Place.Step.elem}, empty, true));
    // `deep` reads both.
    try testing.expectEqual(lost, try f.conds.deep(gpa, f.charge(), f.view(), empty_old, lit, false));
    try testing.expectEqual(shared, try f.conds.deep(gpa, f.charge(), f.view(), old, root, false));
}

test "#1063: kappaLeq compares below a leaf in both directions, and two roots of one snapshot" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const p = try f.param(0, 3, &.{});
    const root = try f.leaf(3, &.{p});
    const child = try f.projOf(root, Place.Step.elem);
    const old = try f.setKPath(.none, &.{Place.Step.elem}, child, shared);
    const v = f.view();
    // Shared below `[*]` is not below the empty snapshot's derived read…
    try testing.expect(!try f.conds.kappaLeq(gpa, f.charge(), v, old, root, .none, root, false));
    // …and the empty snapshot is below it.
    try testing.expect(try f.conds.kappaLeq(gpa, f.charge(), v, .none, root, old, root, false));
    // One snapshot over two roots: a second leaf over another parameter,
    // its own `[*]` untouched, compares by its own derived read.
    const q = try f.param(1, 3, &.{});
    const other = try f.leaf(3, &.{q});
    try testing.expect(try f.conds.kappaLeq(gpa, f.charge(), v, old, other, old, other, false));
    try testing.expect(!try f.conds.kappaLeq(gpa, f.charge(), v, old, root, old, other, false));
    // An empty projection's stored entry counts.
    const site = try f.cells.site(gpa, &f.account, 7, try f.placeOf(3), .list);
    const lit = try f.leaf(3, &.{site});
    const at_empty = try f.setKPath(.none, &.{Place.Step.elem}, try f.projOf(lit, Place.Step.elem), lost);
    try testing.expect(!try f.conds.kappaLeq(gpa, f.charge(), v, at_empty, lit, .none, lit, false));
    try testing.expect(try f.conds.kappaLeq(gpa, f.charge(), v, .none, lit, at_empty, lit, false));
}

/// The positions a reader read, sorted and without repeats.
fn traceSet(list: *std.ArrayList(u32)) []const u32 {
    std.mem.sort(u32, list.items, {}, std.sort.asc(u32));
    var n: usize = 0;
    for (list.items) |x| {
        if (n > 0 and list.items[n - 1] == x) continue;
        list.items[n] = x;
        n += 1;
    }
    list.shrinkRetainingCapacity(n);
    return list.items;
}

/// How many times the reader read `(node, class)`.
fn traceCount(list: []const u32, n: NodeId, summary: bool) usize {
    var c: usize = 0;
    for (list) |x| c += @intFromBool(x == (n.int() << 1 | @intFromBool(summary)));
    return c;
}

test "#1063: a delta's base is no position, a recast's inner is the recast's: every reader agrees" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const v = f.view();
    // A delta over a leaf `{p}`, `a` overridden; the snapshot stores
    // `shared` for the base. The base is not at a path of its own: the
    // delta's κ is the walk's, so no reader reads it, and a join keeps
    // what every reader reads (the review's probe (a)).
    const p = try f.param(0, 0, &.{});
    const q = try f.param(1, 1, &.{});
    const base = try f.leaf(0, &.{p});
    const fa = try Place.Step.field(&f.account, 10);
    const m = try f.shapes.delta(gpa, &f.account, base, try f.shapes.overPut(gpa, &f.account, Ids.none_int, fa, try f.leaf(1, &.{q})));
    var ctx = try f.setK(.none, m, yes);
    ctx = try f.setK(ctx, base, shared);
    const out = try f.propagate(.none, m, &.{m}, &.{ctx}, .alternatives, false);
    const d0 = try f.conds.deep(gpa, f.charge(), v, ctx, m, false);
    try testing.expect(d0 != shared);
    try testing.expectEqual(d0, try f.conds.deep(gpa, f.charge(), v, out, m, false));
    try testing.expect(try f.conds.kappaLeq(gpa, f.charge(), v, ctx, m, out, m, false));
    try testing.expect(try f.conds.kappaLeq(gpa, f.charge(), v, out, m, ctx, m, false));
    // A recast to `Int` of a built node (the review's probe (b)): its κ is
    // derived — nothing below an `Int` holds an object — so `deep` reads
    // `yes`, never the inner node's unset `lost`.
    const s = try f.cells.site(gpa, &f.account, 7, try f.placeOf(0), .record);
    const x = try f.param(2, 1, &.{});
    const inner = try f.shapes.node(gpa, &f.account, try f.placeOf(0), try f.set(&.{s}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, fa, try f.leaf(1, &.{x})));
    const r = try f.shapes.recast(gpa, &f.account, try f.placeOf(2), inner);
    try testing.expectEqual(yes, try f.kappa(.none, r, false));
    try testing.expectEqual(yes, try f.conds.deep(gpa, f.charge(), v, .none, r, false));
    // `Rows.storedInto`: a list node whose `[*]` carries a stored κ, recast
    // to the signature's `Int` result: the entry is the recast position's.
    const ls = try f.cells.site(gpa, &f.account, 8, try f.placeOf(1), .list);
    const elems = try f.leaf(2, &.{});
    const list = try f.shapes.node(gpa, &f.account, try f.placeOf(1), try f.set(&.{ls}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, elems));
    const rl = try f.shapes.recast(gpa, &f.account, try f.placeOf(2), list);
    const kl = try f.setKPath(.none, &.{Place.Step.elem}, elems, shared);
    try testing.expectEqual(shared, try f.conds.deep(gpa, f.charge(), v, kl, rl, false));
    try testing.expectEqual(yes, try f.conds.deep(gpa, f.charge(), v, .none, rl, false));
}

test "#1063: propagate, kappaLeq and deep read exactly one frontier" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const fa = try Place.Step.field(&f.account, 10);
    const fb = try Place.Step.field(&f.account, 11);
    const arg = try f.places.ctorStep(gpa, &f.account, 6, 0);
    // A delta over a leaf, a union of two nodes, a recast of a node, a
    // Rose leaf (cyclic), a list of lists (a leaf): each with no snapshot
    // and with one storing `lost` (never `shared`, so `deep` reads all).
    const p = try f.param(0, 0, &.{});
    const base = try f.leaf(0, &.{p});
    const delta = try f.shapes.delta(gpa, &f.account, base, try f.shapes.overPut(gpa, &f.account, Ids.none_int, fa, try f.leaf(1, &.{try f.param(1, 1, &.{})})));
    const n1 = try f.shapes.node(gpa, &f.account, try f.placeOf(0), try f.set(&.{try f.cells.site(gpa, &f.account, 1, try f.placeOf(0), .record)}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, fa, try f.leaf(1, &.{try f.param(2, 1, &.{})})));
    const n2 = try f.shapes.node(gpa, &f.account, try f.placeOf(0), try f.set(&.{try f.cells.site(gpa, &f.account, 2, try f.placeOf(0), .record)}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, fb, try f.leaf(1, &.{try f.param(3, 1, &.{})})));
    const un = try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, n1, n2);
    const rc = try f.shapes.recast(gpa, &f.account, try f.placeOf(3), n1);
    const rose = try f.leaf(6, &.{try f.param(4, 6, &.{})});
    const lol = try f.leaf(3, &.{try f.param(5, 3, &.{})});
    // A delta over a built base (`explicitAt` recurses into it), and a
    // built list of two element records collected as positions.
    const built_delta = try f.shapes.delta(gpa, &f.account, n1, try f.shapes.overPut(gpa, &f.account, Ids.none_int, fb, try f.leaf(1, &.{try f.param(6, 1, &.{})})));
    const lsite = try f.cells.site(gpa, &f.account, 9, try f.placeOf(5), .list);
    const pos = try f.collect(&.{ n1, n2 });
    const list = try f.shapes.node(gpa, &f.account, try f.placeOf(5), try f.set(&.{lsite}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, pos));
    const Case = struct { root: NodeId, at: NodeId, summary: bool, steps: []const Place.Step };
    const e = Place.Step.elem;
    const cases = [_]Case{
        .{ .root = delta, .at = try f.projOf(delta, fb), .summary = false, .steps = &.{fb} },
        .{ .root = un, .at = try f.projOf(un, fa), .summary = false, .steps = &.{fa} },
        .{ .root = rc, .at = try f.projOf(rc, e), .summary = true, .steps = &.{e} },
        .{ .root = rose, .at = try f.projOf(rose, arg), .summary = false, .steps = &.{arg} },
        .{ .root = lol, .at = try f.projOf(try f.projOf(lol, e), e), .summary = true, .steps = &.{ e, e } },
        .{ .root = built_delta, .at = try f.projOf(built_delta, fa), .summary = false, .steps = &.{fa} },
        .{ .root = list, .at = try f.projOf(try f.projOf(try f.projOf(list, e), fa), e), .summary = true, .steps = &.{ e, fa, e } },
    };
    for (cases) |c| for ([_]bool{ false, true }) |stores| {
        const ctx = if (stores) try f.setKPath(.none, c.steps, c.at, lost) else .none;
        var lists: [3]std.ArrayList(u32) = @splat(.empty);
        defer for (&lists) |*l| l.deinit(gpa);
        f.conds.trace = &lists[0];
        const d_ctx = try f.conds.deep(gpa, f.charge(), f.view(), ctx, c.root, false);
        f.conds.trace = &lists[1];
        const out = try f.propagate(.none, c.root, &.{c.root}, &.{ctx}, .alternatives, false);
        f.conds.trace = &lists[2];
        try testing.expect(try f.conds.kappaLeq(gpa, f.charge(), f.view(), ctx, c.root, ctx, c.root, false));
        f.conds.trace = null;
        const want = traceSet(&lists[0]);
        // One alternative is its own snapshot, linked: `propagate` reads its
        // root alone (#1112).
        try testing.expectEqualSlices(u32, &.{c.root.int() << 1}, traceSet(&lists[1]));
        try testing.expectEqualSlices(u32, want, traceSet(&lists[2]));
        // A stored entry is at a position every reader reaches.
        if (stores) try testing.expect(traceCount(want, c.at, c.summary) == 1);
        // And each reader applies it alike: what `propagate` keeps reads
        // the same through `deep` and both ways through `kappaLeq`.
        try testing.expectEqual(d_ctx, try f.conds.deep(gpa, f.charge(), f.view(), out, c.root, false));
        try testing.expect(try f.conds.kappaLeq(gpa, f.charge(), f.view(), ctx, c.root, out, c.root, false));
        try testing.expect(try f.conds.kappaLeq(gpa, f.charge(), f.view(), out, c.root, ctx, c.root, false));
    };
}

test "#1064: propagate reads its members by index across reallocation" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    // A built record `{ a, b }` joined over 128 members: the first child
    // step appends a run as long as the members, which moves the run list
    // while the second step still has to read them.
    const n_members = 128;
    var members: [n_members]NodeId = undefined;
    var ctxs: [n_members]Kappas = undefined;
    for (&members, &ctxs, 0..) |*m, *c, i| {
        m.* = try f.leaf(0, &.{try f.param(@intCast(i), 0, &.{})});
        c.* = .none;
    }
    const fa = try Place.Step.field(&f.account, 10);
    const fb = try Place.Step.field(&f.account, 11);
    ctxs[n_members - 1] = try f.setKPath(.none, &.{fb}, try f.projOf(members[n_members - 1], fb), lost);
    const la = try f.leaf(1, &.{try f.cells.site(gpa, &f.account, 1, try f.placeOf(1), .list)});
    const lb = try f.leaf(1, &.{try f.cells.site(gpa, &f.account, 2, try f.placeOf(1), .list)});
    const site = try f.cells.site(gpa, &f.account, 3, try f.placeOf(0), .record);
    const joined = try f.shapes.node(gpa, &f.account, try f.placeOf(0), try f.set(&.{site}), try f.shapes.overPut(gpa, &f.account, try f.shapes.overPut(gpa, &f.account, Ids.none_int, fa, la), fb, lb));
    const out = try f.propagate(.none, joined, &members, &ctxs, .alternatives, false);
    try testing.expectEqual(lost, try f.kappaPath(out, &.{fb}, lb, false));
    try testing.expectEqual(yes, try f.kappaPath(out, &.{fa}, la, false));
}

test "#1064: two contexts at one node in one propagation are two states, each once" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    // A record `{ a, b, c }` whose three fields are ONE built list `C`;
    // the member's are `X`, `Y`, `X`, `X`'s snapshot `lost`. `C` is met
    // with the runs `X`, `Y`, `X` in one call: two states, each read once,
    // and `C` joins both.
    const r = try f.placeOf(8);
    const l = try f.placeOf(1);
    var steps: [3]Place.Step = undefined;
    for (&steps, [_]u32{ 10, 11, 14 }) |*s, name| s.* = try Place.Step.field(&f.account, name);
    const cc = try f.shapes.node(gpa, &f.account, l, try f.set(&.{try f.cells.site(gpa, &f.account, 1, l, .list)}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, try f.leaf(2, &.{})));
    const x = try f.leaf(1, &.{try f.param(0, 1, &.{})});
    const y = try f.leaf(1, &.{try f.param(1, 1, &.{})});
    var jo: u32 = Ids.none_int;
    var mo: u32 = Ids.none_int;
    for (steps, [_]NodeId{ x, y, x }) |s, kid| {
        jo = try f.shapes.overPut(gpa, &f.account, jo, s, cc);
        mo = try f.shapes.overPut(gpa, &f.account, mo, s, kid);
    }
    const joined = try f.shapes.node(gpa, &f.account, r, try f.set(&.{try f.cells.site(gpa, &f.account, 2, r, .record)}), jo);
    const member = try f.shapes.node(gpa, &f.account, r, try f.set(&.{try f.cells.site(gpa, &f.account, 3, r, .record)}), mo);
    // `X`'s snapshot `lost` wherever `X` stands: `a` and `c`.
    var ctx = try f.setKPath(.none, &.{steps[0]}, x, lost);
    ctx = try f.setKPath(ctx, &.{steps[2]}, x, lost);
    var trace: std.ArrayList(u32) = .empty;
    defer trace.deinit(gpa);
    f.conds.trace = &trace;
    const out = try f.propagate(.none, joined, &.{member}, &.{ctx}, .alternatives, false);
    f.conds.trace = null;
    try testing.expectEqual(lost, try f.kappaPath(out, &.{steps[0]}, cc, false));
    try testing.expectEqual(lost, try f.kappaPath(out, &.{steps[2]}, cc, false));
    // Three positions of `C` (the paths `.a`, `.b`, `.c`), each read once.
    try testing.expectEqual(@as(usize, 3), traceCount(trace.items, cc, false));
}

/// `{ p = { a = C, b = C }, q = … }` joined over one member of the same
/// shape, `X`'s snapshot `lost` at `.p.a` only: three frames below `.p.b`,
/// `.q.a` and `.q.b` read one run through three parents (#1372).
const RepeatedRuns = struct {
    joined: NodeId,
    member: NodeId,
    ctx: Kappas,
    c: NodeId,
    steps: [4]Place.Step,

    fn build(f: *Fixture) !RepeatedRuns {
        const gpa = testing.allocator;
        var r: RepeatedRuns = undefined;
        for (&r.steps, [_]u32{ 15, 16, 10, 11 }) |*s, name| s.* = try Place.Step.field(&f.account, name);
        const l = try f.placeOf(1);
        r.c = try f.shapes.node(gpa, &f.account, l, try f.set(&.{try f.cells.site(gpa, &f.account, 1, l, .list)}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, try f.leaf(2, &.{})));
        const x = try f.leaf(1, &.{try f.param(0, 1, &.{})});
        var outer: [2]NodeId = undefined;
        for (&outer, [_]NodeId{ r.c, x }, 0..) |*o, kid, i| {
            const inner_p = try f.placeOf(0);
            const inner = try f.shapes.node(gpa, &f.account, inner_p, try f.set(&.{try f.cells.site(gpa, &f.account, @intCast(2 + i), inner_p, .record)}), try f.shapes.overPut(gpa, &f.account, try f.shapes.overPut(gpa, &f.account, Ids.none_int, r.steps[2], kid), r.steps[3], kid));
            const p = try f.placeOf(14);
            o.* = try f.shapes.node(gpa, &f.account, p, try f.set(&.{try f.cells.site(gpa, &f.account, @intCast(4 + i), p, .record)}), try f.shapes.overPut(gpa, &f.account, try f.shapes.overPut(gpa, &f.account, Ids.none_int, r.steps[0], inner), r.steps[1], inner));
        }
        r.joined = outer[0];
        r.member = outer[1];
        r.ctx = try f.setKPath(.none, &.{ r.steps[0], r.steps[2] }, x, lost);
        return r;
    }

    /// The walk's snapshot, its records and the states it read.
    fn run(memo: bool) !struct { out: [4]CondId, records: u32, states: usize } {
        var f: Fixture = .{};
        try f.init();
        defer f.deinit();
        const r = try build(&f);
        var trace: std.ArrayList(u32) = .empty;
        defer trace.deinit(testing.allocator);
        f.conds.trace = &trace;
        f.conds.no_memo = !memo;
        const before = f.account.growth;
        const out = try f.propagate(.none, r.joined, &.{r.member}, &.{r.ctx}, .alternatives, false);
        const records = f.account.growth - before;
        f.conds.no_memo = false;
        var ks: [4]CondId = undefined;
        for (&ks, [_][2]u32{ .{ 0, 2 }, .{ 0, 3 }, .{ 1, 2 }, .{ 1, 3 } }) |*k, at| k.* = try f.kappaPath(out, &.{ r.steps[at[0]], r.steps[at[1]] }, r.c, false);
        return .{ .out = ks, .records = records, .states = traceCount(trace.items, r.c, false) };
    }
};

test "#1372: propagate's per-call memos are exact, and a run met through three parents is read once" {
    const memo = try RepeatedRuns.run(true);
    const walk = try RepeatedRuns.run(false);
    // The same snapshot: `lost` at `.p.a` alone, and the same four states of `C`.
    try testing.expectEqualSlices(CondId, &.{ lost, yes, yes, yes }, &walk.out);
    try testing.expectEqualSlices(CondId, &walk.out, &memo.out);
    try testing.expectEqual(@as(usize, 4), walk.states);
    try testing.expectEqual(walk.states, memo.states);
    // Two of the three frames of `(X, none)` reuse its slice and `C`'s frontier.
    try testing.expect(memo.records < walk.records);
}

test "#1064: a cyclic place with two contexts ends at the revisited exact states" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    // `Rose`: projections cycle through `⟲`, and a stored entry makes the
    // walk follow them. Two members, one storing at its children: every
    // state of the cycle is read once, and the walk ends there.
    const arg = try f.places.ctorStep(gpa, &f.account, 6, 0);
    const a = try f.leaf(6, &.{try f.param(0, 6, &.{})});
    const b = try f.leaf(6, &.{try f.param(1, 6, &.{})});
    const joined = try f.join2(a, b);
    const kids = try f.projOf(a, arg);
    const stored = try f.setKPath(.none, &.{arg}, kids, shared);
    var trace: std.ArrayList(u32) = .empty;
    defer trace.deinit(gpa);
    f.conds.trace = &trace;
    const out = try f.propagate(.none, joined, &.{ a, b }, &.{ stored, .none }, .alternatives, false);
    f.conds.trace = null;
    try testing.expectEqual(shared, try f.kappaPath(out, &.{arg}, try f.projOf(joined, arg), false));
    const n = trace.items.len;
    try testing.expectEqual(n, traceSet(&trace).len);
}

test "#1063: a recast and its inner are one position: an entry stored below the inner survives a join" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const v = f.view();
    // `Rows.storedInto`: a list node whose `[*]` stores `excl x`, recast to
    // the signature's result. The recast changes the type, not the path:
    // the inner's entries are the position's, and a join keeps them.
    const x = try f.param(0, 1, &.{});
    const site = try f.cells.site(gpa, &f.account, 3, try f.placeOf(1), .list);
    const elems = try f.leaf(2, &.{});
    const inner = try f.shapes.node(gpa, &f.account, try f.placeOf(1), try f.set(&.{site}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, elems));
    const r = try f.shapes.recast(gpa, &f.account, try f.placeOf(2), inner);
    const k = try f.conds.excl(gpa, f.charge(), x);
    const ctx = try f.setKPath(.none, &.{Place.Step.elem}, elems, k);
    try testing.expectEqual(k, try f.conds.deep(gpa, f.charge(), v, ctx, r, false));
    const out = try f.propagate(.none, r, &.{r}, &.{ctx}, .alternatives, false);
    try testing.expectEqual(k, try f.conds.deep(gpa, f.charge(), v, out, r, false));
    try testing.expect(try f.conds.kappaLeq(gpa, f.charge(), v, ctx, r, out, r, false));
    try testing.expect(!try f.conds.kappaLeq(gpa, f.charge(), v, out, r, .none, r, false));
    // What is stored at the inner itself is read at the recast; with
    // nothing stored, the recast reads its derivation: `yes`.
    try testing.expectEqual(yes, try f.kappa(.none, r, false));
    try testing.expectEqual(k, try f.kappa(try f.setK(.none, inner, k), r, false));
}

test "#1063: a join keeps what is stored below a recast's inner, through a union's side" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const v = f.view();
    // `Rows.storedInto`'s shape, `excl x` at the inner's `[*]`, joined with
    // another alternative at the recast's place: the literal `0`, then a
    // recast of a fresh list. The join is a union; its frontier reaches the
    // inners of the recasts among its sides, each member through its own.
    const x = try f.param(0, 1, &.{});
    const k = try f.conds.excl(gpa, f.charge(), x);
    for ([_]bool{ false, true }) |two_recasts| {
        const s1 = try f.cells.site(gpa, &f.account, 3, try f.placeOf(1), .list);
        const elems = try f.leaf(2, &.{});
        const in1 = try f.shapes.node(gpa, &f.account, try f.placeOf(1), try f.set(&.{s1}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, elems));
        const r = try f.shapes.recast(gpa, &f.account, try f.placeOf(2), in1);
        const km = try f.setKPath(.none, &.{Place.Step.elem}, elems, k);
        const other = if (!two_recasts) try f.leaf(2, &.{}) else blk: {
            const s2 = try f.cells.site(gpa, &f.account, 4, try f.placeOf(1), .list);
            const in2 = try f.shapes.node(gpa, &f.account, try f.placeOf(1), try f.set(&.{s2}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, try f.leaf(2, &.{})));
            break :blk try f.shapes.recast(gpa, &f.account, try f.placeOf(2), in2);
        };
        const j = try f.join2(r, other);
        const out = try f.propagate(.none, j, &.{ r, other }, &.{ km, .none }, .alternatives, false);
        try testing.expectEqual(k, try f.conds.deep(gpa, f.charge(), v, km, r, false));
        try testing.expectEqual(k, try f.conds.deep(gpa, f.charge(), v, out, j, false));
        try testing.expect(try f.conds.kappaLeq(gpa, f.charge(), v, km, r, out, j, false));
        try testing.expect(try f.conds.kappaLeq(gpa, f.charge(), v, .none, other, out, j, false));
        try testing.expect(!try f.conds.kappaLeq(gpa, f.charge(), v, out, j, .none, j, false));
    }
}

test "#1372 review: two built arms a map interns to one image read lost where one has no entry" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    // `if c then b else c'`, two built nodes at one position whose cells a
    // read-off relabels alike, so `map` interns them to one image, with a
    // third, `a`, relabelled alike and standing elsewhere. `b` stores
    // `shared`, `c'` nothing: alone `c'` reads `lost` (§2.9), so the image,
    // which stands for both here, reads `lost` too.
    const at = try f.placeOf(0);
    const a = try f.shapes.node(gpa, &f.account, at, try f.set(&.{try f.param(1, 0, &.{})}), Ids.none_int);
    const b = try f.shapes.node(gpa, &f.account, at, try f.set(&.{try f.param(2, 0, &.{})}), Ids.none_int);
    const cc = try f.shapes.node(gpa, &f.account, at, try f.set(&.{try f.param(4, 0, &.{})}), Ids.none_int);
    const v = try f.shapes.collect(gpa, &f.account, &f.cells.sets, &.{ a, try f.shapes.choice(gpa, &f.account, &f.cells.sets, b, cc) });
    const k = try f.setK(.none, b, shared);
    try testing.expectEqual(lost, try f.kappa(k, cc, false));
    const Alike = struct {
        fn relabel(fx: *Fixture, s: SetId) Error!SetId {
            if (s == .none) return .none;
            return fx.set(&.{try fx.param(3, 0, &.{})});
        }
    };
    _ = try f.shapes.map(gpa, &f.account, v, &f, Alike.relabel);
    const m = f.shapes.memo_map.get(b).?;
    try testing.expectEqual(m, f.shapes.memo_map.get(cc).?);
    try testing.expectEqual(m, f.shapes.memo_map.get(a).?);
    // Which sources stand at which position: what read-off's walk finds.
    const Carry = struct {
        shapes: *Shape.Table,
        root: Kappas,
        here: []const NodeId,
        fn node(ctx: *anyopaque, n: NodeId) Error!?NodeId {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            return s.shapes.memo_map.get(n);
        }
        fn cond(_: *anyopaque, _: *Table, _: Allocator, _: Charge, x: CondId) Error!CondId {
            return x;
        }
        fn source(ctx: *anyopaque, pos: Kappas, n: NodeId) ?NodeId {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            const src = s.shapes.mapSource(n) orelse return null;
            return if (pos == s.root and std.mem.indexOfScalar(NodeId, s.here, src) != null) src else null;
        }
        fn present(ctx: *anyopaque, pos: Kappas, _: NodeId) u32 {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            return if (pos == s.root) @intCast(s.here.len) else 0;
        }
    };
    const relabel = struct {
        fn of(fx: *Fixture, kk: Kappas, carry: *Carry) !Kappas {
            carry.root = kk;
            return fx.conds.kappaRelabel(testing.allocator, fx.charge(), kk, .{ .ctx = carry, .node = Carry.node, .cond = Carry.cond, .source = Carry.source, .present = Carry.present });
        }
    }.of;
    var two: Carry = .{ .shapes = &f.shapes, .root = k, .here = &.{ b, cc } };
    try testing.expectEqual(lost, try f.kappa(try relabel(&f, k, &two), m, false));
    // Both with an entry: their join, never `lost` for want of one.
    const kc = try f.setK(k, cc, shared);
    try testing.expectEqual(shared, try f.kappa(try relabel(&f, kc, &two), m, false));
    // `c'` at another position: `b`'s entry is the image's here.
    var one: Carry = .{ .shapes = &f.shapes, .root = k, .here = &.{b} };
    try testing.expectEqual(shared, try f.kappa(try relabel(&f, k, &one), m, false));
    // A stale entry beside the missing one: `a` stands elsewhere, and a
    // branch join kept its `shared` at this position. It is no source here,
    // so it cannot stand in for `c'`: the image still reads `lost`.
    const ka = try f.setK(k, a, shared);
    try testing.expectEqual(lost, try f.kappa(try relabel(&f, ka, &two), m, false));
}

test "kappaMerge: the union of two snapshots, a shared key joined, a snapshot with itself the same" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const t = &f.conds;
    const p = try f.param(0, 1, &.{});
    const q = try f.param(1, 1, &.{});
    const lp = try f.leaf(1, &.{p});
    const lq = try f.leaf(1, &.{q});
    const e = try t.excl(gpa, f.charge(), p);
    const a = try f.setK(.none, lp, e);
    const b = try f.setK(.none, lq, lost);
    const m = try t.kappaMerge(gpa, f.charge(), a, b);
    try testing.expectEqual(e, t.kappaGet(m, lp).?);
    try testing.expectEqual(lost, t.kappaGet(m, lq).?);
    try testing.expectEqual(a, try t.kappaMerge(gpa, f.charge(), a, a));
    try testing.expectEqual(a, try t.kappaMerge(gpa, f.charge(), a, .none));
    try testing.expectEqual(b, try t.kappaMerge(gpa, f.charge(), .none, b));
    // One key in both: joined (lost wins over an atom).
    const c = try f.setK(.none, lp, lost);
    try testing.expectEqual(lost, t.kappaGet(try t.kappaMerge(gpa, f.charge(), a, c), lp).?);
    // The entries, every one once.
    var it = t.kappaHere(m);
    var n: u32 = 0;
    while (it.next()) |_| : (n += 1) {}
    try testing.expectEqual(@as(u32, 2), n);
}

// ---- #1073: the κ trie ---------------------------------------------------------

/// `[ n ]`'s or a list node's snapshot as a construction makes it: the
/// child's linked under `[*]`, the node's own `yes`.
fn listOver(f: *Fixture, place: u32, site: u32, child: NodeId, child_k: Kappas) !struct { node: NodeId, k: Kappas } {
    const gpa = testing.allocator;
    const p = try f.placeOf(place);
    const n = try f.shapes.node(gpa, &f.account, p, try f.set(&.{try f.cells.site(gpa, &f.account, site, p, .list)}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, child));
    var k = try f.conds.kappaLink(gpa, f.charge(), .none, Place.Step.elem, child_k);
    k = (try f.conds.kappaSet(gpa, f.charge(), k, n, yes)).ctx;
    return .{ .node = n, .k = k };
}

/// `Rose xs`'s: `xs`'s snapshot linked under the constructor's argument.
fn roseOver(f: *Fixture, site: u32, xs: NodeId, xs_k: Kappas) !struct { node: NodeId, k: Kappas } {
    const gpa = testing.allocator;
    const arg = try f.places.ctorStep(gpa, &f.account, 6, 0);
    const p = try f.placeOf(6);
    const n = try f.shapes.node(gpa, &f.account, p, try f.set(&.{try f.cells.site(gpa, &f.account, site, p, .record)}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, arg, xs));
    var k = try f.conds.kappaLink(gpa, f.charge(), .none, arg, xs_k);
    k = (try f.conds.kappaSet(gpa, f.charge(), k, n, yes)).ctx;
    return .{ .node = n, .k = k };
}

/// `minimal` (#1125's review), or its control: `k` the kids of a depth-2
/// and a depth-1 node (`alias`), or two lists alike. The root and its
/// snapshot, the kids lists and the paths to them.
fn crossDepth(f: *Fixture, alias: bool) !struct { root: NodeId, k: Kappas, kids: [2]NodeId } {
    const gpa = testing.allocator;
    const arg = try f.places.ctorStep(gpa, &f.account, 6, 0);
    const nothing = try f.shapes.nothing(gpa, &f.account, try f.placeOf(6));
    const k1 = try listOver(f, 7, 1, nothing, .none);
    const k2 = if (alias) k1 else try listOver(f, 7, 2, nothing, .none);
    const rk1 = try roseOver(f, 3, k1.node, k1.k);
    const rk2 = try roseOver(f, 4, k2.node, k2.k);
    const empty = try listOver(f, 7, 5, nothing, .none);
    const e = try roseOver(f, 6, empty.node, empty.k);
    // `b = Rose [ Rose k, Rose [] ]`, then `Rose [ b, Rose k ]`: each
    // literal's `[*]` the merge of its items' snapshots, as Transfer builds.
    const inner = try f.shapes.node(gpa, &f.account, try f.placeOf(7), try f.set(&.{try f.cells.site(gpa, &f.account, 7, try f.placeOf(7), .list)}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, try f.collect(&.{ rk1.node, e.node })));
    var ik = try f.conds.kappaLink(gpa, f.charge(), .none, Place.Step.elem, try f.conds.kappaMerge(gpa, f.charge(), rk1.k, e.k));
    ik = (try f.conds.kappaSet(gpa, f.charge(), ik, inner, yes)).ctx;
    const b = try roseOver(f, 8, inner, ik);
    const outer = try f.shapes.node(gpa, &f.account, try f.placeOf(7), try f.set(&.{try f.cells.site(gpa, &f.account, 9, try f.placeOf(7), .list)}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, try f.collect(&.{ b.node, rk2.node })));
    var ok = try f.conds.kappaLink(gpa, f.charge(), .none, Place.Step.elem, try f.conds.kappaMerge(gpa, f.charge(), b.k, rk2.k));
    ok = (try f.conds.kappaSet(gpa, f.charge(), ok, outer, yes)).ctx;
    const root = try roseOver(f, 10, outer, ok);
    _ = arg;
    // As the first return below a root `Rose [ … ]`, a plain path since #1253.
    const wl = try listOver(f, 7, 11, root.node, root.k);
    const top = try roseOver(f, 12, wl.node, wl.k);
    return .{ .root = top.node, .k = top.k, .kids = .{ k1.node, k2.node } };
}

test "#1125 review: widen opening two depths into one class reads a cell both hold as `lost`, never stronger than a member" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const arg = try f.places.ctorStep(gpa, &f.account, 6, 0);
    const e = Place.Step.elem;
    for ([_]bool{ false, true }) |alias| {
        const v = try crossDepth(&f, alias);
        // Unwidened, each kids list reads `yes` at its own path: no single
        // path holds `k` twice.
        const depth2 = [_]Place.Step{ arg, e, arg, e, arg, e, arg };
        const depth1 = [_]Place.Step{ arg, e, arg, e, arg };
        const r2 = try f.kappaPath(v.k, &depth2, v.kids[0], true);
        const r1 = try f.kappaPath(v.k, &depth1, v.kids[1], true);
        try testing.expectEqual(yes, r2);
        try testing.expectEqual(yes, r1);
        // Widened: the kids of every depth are one class, its snapshot
        // propagated from the unwidened one, as a read-off does.
        const widened = try f.conds.widenValue(gpa, f.charge(), f.view(), v.root, v.k);
        const w = widened.node;
        try testing.expect(w != v.root);
        const wk = widened.kappas;
        // The value's class is the root's first return, `[arg, [*]]` (#1253).
        const kids = try f.projOf(try f.projOf(try f.projOf(w, arg), e), arg);
        const read = try f.kappa(f.conds.kappaAlong(wk, &.{ arg, e, arg }), kids, false);
        // Never stronger than a member it covers.
        try testing.expect(try f.conds.leq(gpa, f.charge(), try f.conds.join(gpa, f.charge(), r1, r2), read));
        // `k` at two depths is two positions of the class: a repeat, `lost`
        // (the path-multiset primitive, #1128). Two lists alike are no repeat.
        // Two distinct lists owe nothing of the primitive (their read may be
        // lost for other reasons, as before the primitive).
        if (alias) try testing.expectEqual(lost, read) else if (f.conds.fold_cond.get(kids)) |fc| try testing.expect(!Table.fails(fc));
    }
}

test "#1360: in a group's rounds widen opens a choice at the root and keeps its arms exclusive: a kids list in each arm is one, beside each other two" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.shapes.widen_rounds = true;
    const gpa = testing.allocator;
    const arg = try f.places.ctorStep(gpa, &f.account, 6, 0);
    const nothing = try f.shapes.nothing(gpa, &f.account, try f.placeOf(6));
    for ([_]bool{ true, false }) |exclusive| {
        // `if c then Rose k else Rose [ Rose k ]`: `k` at `#Rose.0` in one
        // arm and at `#Rose.0·[*]·#Rose.0`, the same class, in the other.
        const k = try listOver(&f, 7, 1, nothing, .none);
        const shallow = try roseOver(&f, 3, k.node, k.k);
        const kids = try listOver(&f, 7, 2, shallow.node, shallow.k);
        const deep = try roseOver(&f, 4, kids.node, kids.k);
        const root = if (exclusive) try f.shapes.choice(gpa, &f.account, &f.cells.sets, shallow.node, deep.node) else try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, shallow.node, deep.node);
        const rk = try f.conds.kappaMerge(gpa, f.charge(), shallow.k, deep.k);
        const widened = try f.conds.widenValue(gpa, f.charge(), f.view(), root, rk);
        // Opened: the arms are members of the root's class, the knot ties
        // back to a node, never to a choice.
        try testing.expect(widened.node != root);
        try testing.expect(f.shapes.kind(widened.node) != .choice);
        const at = try f.projOf(widened.node, arg);
        // The class's obligation from the path-multiset primitive (§2.9):
        // one execution has one arm, so `k` once; coexisting sides, twice.
        // (The read through the built image may be `lost` for other
        // reasons, as #1125's distinct lists are.)
        try testing.expect(f.conds.fold_cond_n > 0);
        const fc = try f.conds.foldCondOf(gpa, f.charge(), f.view(), at);
        if (exclusive) try testing.expect(!Table.fails(fc)) else try testing.expectEqual(lost, fc);
        if (!exclusive) try testing.expectEqual(lost, try f.kappa(f.conds.kappaChild(widened.kappas, arg), at, false));
    }
}

test "#1125 verification: a leaf-only folded class stores its repeat, so the snapshot alone reads it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const t0 = try f.places.ctorStep(gpa, &f.account, 12, 0);
    const t1 = try f.places.ctorStep(gpa, &f.account, 12, 1);
    const tp = try f.placeOf(12);
    const kids = try f.placeOf(13);
    // `T xs [ T xs [ T xs [] ] ]`: `xs` (a leaf) at three depths of `#T.0`,
    // one per path, so no unwidened read sees it twice; the folded class is
    // all leaves.
    const xs = try f.leaf(1, &.{try f.param(0, 1, &.{})});
    var node: NodeId = try f.shapes.node(gpa, &f.account, kids, try f.set(&.{try f.cells.site(gpa, &f.account, 1, kids, .list)}), Ids.none_int);
    var k = (try f.conds.kappaSet(gpa, f.charge(), .none, node, yes)).ctx;
    var root: NodeId = undefined;
    var rk: Kappas = undefined;
    for (0..3) |i| {
        root = try f.shapes.node(gpa, &f.account, tp, .none, try f.shapes.overPut(gpa, &f.account, try f.shapes.overPut(gpa, &f.account, Ids.none_int, t0, xs), t1, node));
        rk = try f.conds.kappaLink(gpa, f.charge(), .none, t1, k);
        rk = (try f.conds.kappaSet(gpa, f.charge(), rk, root, yes)).ctx;
        if (i == 2) break;
        node = try f.shapes.node(gpa, &f.account, kids, try f.set(&.{try f.cells.site(gpa, &f.account, @intCast(i + 2), kids, .list)}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, root));
        k = try f.conds.kappaLink(gpa, f.charge(), .none, Place.Step.elem, rk);
        k = (try f.conds.kappaSet(gpa, f.charge(), k, node, yes)).ctx;
    }
    // Widened and propagated, as a read-off does.
    const widened = try f.conds.widenValue(gpa, f.charge(), f.view(), root, rk);
    const w = widened.node;
    try testing.expect(w != root);
    const wk = widened.kappas;
    const at = try f.projOf(w, t0);
    try testing.expectEqual(Shape.Kind.leaf, f.shapes.kind(at));
    // The read, and the stored κ alone (what a block writes and its reader
    // reads, with no `widen` evidence beside it): the same refusal.
    const read = try f.kappa(f.conds.kappaChild(wk, t0), at, false);
    try testing.expect(Table.fails(read));
    const stored = f.conds.kappaGet(f.conds.kappaChild(wk, t0), at) orelse return error.TestUnexpectedResult;
    try testing.expect(Table.fails(stored));
    try testing.expectEqual(read, try f.conds.kappaOf(gpa, f.charge(), f.view(), f.conds.kappaChild(wk, t0), at, false));
}
test "#1073: a child's snapshot linked under a recursive parent reads at its paths as it does alone" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const v = f.view();
    // `type Rose = Rose (List Rose)`, `t = Rose xs`. In `xs`'s own canonical
    // paths its element is `[*]` (a `Rose`); under `t` the same position is
    // `⟲` (§2.1's fold re-enters `t`'s root place), so the trie keys by the
    // steps a read takes from the snapshot's root, never by canonical paths.
    const arg = try f.places.ctorStep(gpa, &f.account, 6, 0);
    const e = try f.leaf(6, &.{try f.param(0, 6, &.{})});
    const xs = try listOver(&f, 7, 1, e, try f.setK(.none, e, shared));
    const xs_k = xs.k;
    const t = try roseOver(&f, 2, xs.node, xs_k);
    try testing.expectEqual(shared, try f.kappaPath(xs_k, &.{Place.Step.elem}, e, true));
    try testing.expectEqual(try f.kappaPath(xs_k, &.{Place.Step.elem}, e, true), try f.kappaPath(t.k, &.{ arg, Place.Step.elem }, e, true));
    try testing.expectEqual(try f.kappaPath(xs_k, &.{}, xs.node, false), try f.kappaPath(t.k, &.{arg}, xs.node, false));
    // The deep reads agree too, and the link is the child's snapshot itself.
    try testing.expectEqual(try f.conds.deep(gpa, f.charge(), v, xs_k, xs.node, false), try f.conds.deep(gpa, f.charge(), v, f.conds.kappaChild(t.k, arg), xs.node, false));
    try testing.expectEqual(shared, try f.conds.deep(gpa, f.charge(), v, t.k, t.node, false));
    try testing.expectEqual(xs_k, f.conds.kappaChild(t.k, arg));
}

test "#1073: an n-level recursive construction costs O(n) links, never a re-key" {
    var cost: [2]u64 = undefined;
    for ([_]u32{ 100, 200 }, 0..) |n, run| {
        var f: Fixture = .{};
        try f.init();
        defer f.deinit();
        const gpa = testing.allocator;
        const arg = try f.places.ctorStep(gpa, &f.account, 6, 0);
        // A store at the innermost level, then n levels of `Rose [ … ]`.
        const e = try f.leaf(6, &.{try f.param(0, 6, &.{})});
        var node = e;
        var k = try f.setK(.none, e, shared);
        const before = f.account.total();
        for (0..n) |i| {
            const l = try listOver(&f, 7, @intCast(2 * i + 1), node, k);
            const r = try roseOver(&f, @intCast(2 * i + 2), l.node, l.k);
            node = r.node;
            k = r.k;
        }
        cost[run] = f.account.total() - before;
        // The innermost store is where the read reaches it, n levels down.
        const steps = try gpa.alloc(Place.Step, 2 * n);
        defer gpa.free(steps);
        for (0..n) |i| {
            steps[2 * i] = arg;
            steps[2 * i + 1] = Place.Step.elem;
        }
        try testing.expectEqual(shared, f.conds.kappaGet(f.conds.kappaAlong(k, steps), e).?);
    }
    // Linear: the snapshots' share of a level is a constant.
    try testing.expect(cost[1] <= 2 * cost[0] + 64);
}

test "#1073: two positions of one value that reach one interned node keep their own conditions" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    // OnePairTwoPositions: `r = [ 1 ]; p = { a = [ r ], b = [ r, r ] }`.
    // `shared` stored for `r` at `.b[*]` never answers `.a[*]`.
    const fa = try Place.Step.field(&f.account, 10);
    const fb = try Place.Step.field(&f.account, 11);
    const r = try f.leaf(1, &.{try f.cells.site(gpa, &f.account, 1, try f.placeOf(1), .list)});
    const a = try listOver(&f, 3, 2, r, .none);
    const two = try f.collect(&.{ r, r });
    var two_k = try f.propagateFrom2(two, &.{ r, r });
    two_k = (try f.conds.kappaSet(gpa, f.charge(), two_k, r, shared)).ctx;
    const b = try listOver(&f, 3, 3, two, two_k);
    const p = try f.shapes.node(gpa, &f.account, try f.placeOf(11), try f.set(&.{try f.cells.site(gpa, &f.account, 4, try f.placeOf(11), .record)}), try f.shapes.overPut(gpa, &f.account, try f.shapes.overPut(gpa, &f.account, Ids.none_int, fa, a.node), fb, b.node));
    var pk = try f.conds.kappaLink(gpa, f.charge(), .none, fa, a.k);
    pk = try f.conds.kappaLink(gpa, f.charge(), pk, fb, b.k);
    try testing.expectEqual(shared, try f.kappaPath(pk, &.{ fb, Place.Step.elem }, r, true));
    try testing.expectEqual(shared, try f.kappaPath(pk, &.{ fb, Place.Step.elem }, two, true));
    try testing.expectEqual(yes, try f.kappaPath(pk, &.{ fa, Place.Step.elem }, r, true));
    _ = p;
}

test "#1073: the frontier is sparse: κ stored below one field of a wide record costs nothing for the width" {
    var traced: [2]usize = undefined;
    for ([_]u32{ 9, 10 }, 0..) |place, run| {
        var f: Fixture = .{};
        try f.init();
        defer f.deinit();
        const gpa = testing.allocator;
        const v = f.view();
        // A record parameter (a leaf: no field is built) with `shared`
        // stored at `.f0[*]`.
        const f0 = try Place.Step.field(&f.account, 100);
        const root = try f.leaf(place, &.{try f.param(0, place, &.{})});
        const at = try f.projOf(try f.projOf(root, f0), Place.Step.elem);
        const k = try f.setKPath(.none, &.{ f0, Place.Step.elem }, at, shared);
        // The three readers' records: what they read and what they reserve.
        const before = f.account.total();
        try testing.expectEqual(shared, try f.conds.deep(gpa, f.charge(), v, k, root, false));
        const out = try f.propagate(.none, root, &.{root}, &.{k}, .alternatives, false);
        try testing.expect(try f.conds.kappaLeq(gpa, f.charge(), v, k, root, out, root, false));
        traced[run] = f.account.total() - before;
        try testing.expectEqual(shared, try f.kappaPath(out, &.{ f0, Place.Step.elem }, at, true));
    }
    // Eight fields or 512: the same records.
    try testing.expectEqual(traced[0], traced[1]);
}

test "#1073: widen's fold: the snapshot of a widened tower folds, the walk ends, each level is below it, and a second round adds nothing" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const v = f.view();
    const arg = try f.places.ctorStep(gpa, &f.account, 6, 0);
    // `Rose [ Rose [ … e ] ]`, five levels, `excl` of a parameter stored at
    // `e`, one site per construction (a folded `fresh ι⋆`): what a
    // recursive function's read-off widens.
    const e = try f.leaf(6, &.{try f.param(0, 6, &.{})});
    const ek = try f.setK(.none, e, try f.conds.excl(gpa, f.charge(), try f.param(1, 6, &.{})));
    var node = e;
    var k = ek;
    for (0..5) |_| {
        const l = try listOver(&f, 7, 2, node, k);
        const r = try roseOver(&f, 3, l.node, l.k);
        node = r.node;
        k = r.k;
    }
    const w = try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, node);
    try testing.expect(w != node);
    // The walk over the cyclic shape ends at its fold.
    const out = try f.propagate(.none, w, &.{node}, &.{k}, .alternatives, false);
    // The tower is below its fold: folding only weakens a read.
    try testing.expect(try f.conds.kappaLeq(gpa, f.charge(), v, k, node, out, w, false));
    // A second round over the folded snapshot adds nothing: the fixpoint
    // settles (both ways).
    const again = try f.propagate(.none, w, &.{w}, &.{out}, .alternatives, false);
    try testing.expect(try f.conds.kappaLeq(gpa, f.charge(), v, again, w, out, w, false));
    try testing.expect(try f.conds.kappaLeq(gpa, f.charge(), v, out, w, again, w, false));
    // The snapshot folds where the shape cycles: a read below the fold is
    // the fold's, at every level.
    var at = out;
    var steps: usize = 0;
    while (!f.conds.isFold(at) and steps < 12) : (steps += 1) at = f.conds.kappaChild(at, if (steps % 2 == 0) arg else Place.Step.elem);
    try testing.expect(f.conds.isFold(at));
    try testing.expectEqual(at, f.conds.kappaChild(at, arg));
    try testing.expectEqual(at, f.conds.kappaChild(f.conds.kappaChild(at, arg), Place.Step.elem));
}

test "#1073 review: a fold made by collapsing reads a built node lost wherever one covered position lacked its certificate" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    // `{ a = X, b = X }` with X's certificate linked at `.a` only: at `.b`, X
    // reads `lost`. Collapsing the record's snapshot, or merging it into a
    // fold, must not make X read `yes` there.
    const fa = try Place.Step.field(&f.account, 10);
    const fb = try Place.Step.field(&f.account, 11);
    const l = try f.placeOf(1);
    const x = try f.shapes.node(gpa, &f.account, l, try f.set(&.{try f.cells.site(gpa, &f.account, 1, l, .list)}), Ids.none_int);
    const s = try f.setKPath(.none, &.{fa}, x, yes);
    try testing.expectEqual(yes, try f.kappaPath(s, &.{fa}, x, false));
    try testing.expectEqual(lost, try f.kappaPath(s, &.{fb}, x, false));
    const folded = try f.conds.kappaFold(gpa, f.charge(), s);
    try testing.expect(f.conds.isCollapsed(folded));
    try testing.expectEqual(lost, try f.kappa(folded, x, false));
    const other = try f.conds.kappaEmptyFold(gpa, f.charge(), Table.fold_exact);
    const merged = try f.conds.kappaMerge(gpa, f.charge(), other, s);
    try testing.expectEqual(lost, try f.kappa(merged, x, false));
    // A leaf's entries only add constraints: collapsing keeps them.
    const lf = try f.leaf(1, &.{try f.param(0, 1, &.{})});
    const sl = try f.setKPath(.none, &.{fa}, lf, shared);
    try testing.expectEqual(shared, try f.kappa(try f.conds.kappaFold(gpa, f.charge(), sl), lf, false));
}

test "#1073 review: below a fold the frontier is sparse too: a wide record's width costs nothing" {
    var cost: [2]u64 = undefined;
    for ([_]u32{ 9, 10 }, 0..) |place, run| {
        var f: Fixture = .{};
        try f.init();
        defer f.deinit();
        const gpa = testing.allocator;
        const v = f.view();
        const f0 = try Place.Step.field(&f.account, 100);
        const root = try f.leaf(place, &.{try f.param(0, place, &.{})});
        const at = try f.projOf(try f.projOf(root, f0), Place.Step.elem);
        // The snapshot collapsed into a fold at the root: its links are the
        // steps it saw, `.f0` and `[*]`.
        const k = try f.conds.kappaFold(gpa, f.charge(), try f.setKPath(.none, &.{ f0, Place.Step.elem }, at, shared));
        try testing.expect(f.conds.isFold(k));
        const before = f.account.total();
        try testing.expectEqual(shared, try f.conds.deep(gpa, f.charge(), v, k, root, false));
        try testing.expect(try f.conds.kappaLeq(gpa, f.charge(), v, k, root, k, root, false));
        const out = try f.propagate(.none, root, &.{ root, root }, &.{ k, .none }, .alternatives, false);
        try testing.expectEqual(shared, try f.kappaPath(out, &.{ f0, Place.Step.elem }, at, true));
        cost[run] = f.account.total() - before;
    }
    try testing.expectEqual(cost[0], cost[1]);
}

test "#1129: relabelling a fold keeps the steps it saw, so deep, kappaLeq and the frontier still reach below it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const v = f.view();
    const f0 = try Place.Step.field(&f.account, 100);
    const root = try f.leaf(9, &.{try f.param(0, 9, &.{})});
    const at = try f.projOf(try f.projOf(root, f0), Place.Step.elem);
    const Identity = struct {
        fn node(_: *anyopaque, n: NodeId) Error!?NodeId {
            return n;
        }
        fn cond(_: *anyopaque, _: *Table, _: Allocator, _: Charge, k: CondId) Error!CondId {
            return k;
        }
    };
    var dummy: u8 = 0;
    const id: Table.Relabel = .{ .ctx = &dummy, .node = Identity.node, .cond = Identity.cond };
    // A collapsed fold, and an exact one with the same entry and steps.
    const collapsed = try f.conds.kappaFold(gpa, f.charge(), try f.setKPath(.none, &.{ f0, Place.Step.elem }, at, shared));
    var exact = try f.conds.kappaEmptyFold(gpa, f.charge(), Table.fold_exact);
    exact = try f.conds.kappaFoldStep(gpa, f.charge(), exact, f0);
    exact = try f.conds.kappaFoldStep(gpa, f.charge(), exact, Place.Step.elem);
    exact = (try f.conds.kappaSet(gpa, f.charge(), exact, at, shared)).ctx;
    for ([_]Kappas{ collapsed, exact }) |k| {
        try testing.expect(f.conds.isFold(k));
        try testing.expectEqual(shared, try f.conds.deep(gpa, f.charge(), v, k, root, false));
        const r = try f.conds.kappaRelabel(gpa, f.charge(), k, id);
        // The identity is the identity: the same hash-consed position, its
        // step set, and every read through it.
        try testing.expectEqual(k, r);
        var steps: u32 = 0;
        var it = f.conds.kappaLinks(r);
        while (it.next()) |e| {
            try testing.expectEqual(r, e.child);
            steps += 1;
        }
        try testing.expectEqual(@as(u32, 2), steps);
        try testing.expectEqual(shared, try f.conds.deep(gpa, f.charge(), v, r, root, false));
        try testing.expect(try f.conds.kappaLeq(gpa, f.charge(), v, k, root, r, root, false));
        try testing.expect(try f.conds.kappaLeq(gpa, f.charge(), v, r, root, k, root, false));
    }
}

test "#1130: a snapshot as deep as the source is set, relabelled and merged on explicit stacks" {
    // On a thread with a small stack, 512 KiB for 15 000 steps, as 1 MiB was
    // for 30 000 (over the budget under load, #1197): a native frame per
    // level of the snapshot would overflow it.
    var result: anyerror!void = {};
    const th = try std.Thread.spawn(.{ .stack_size = 512 << 10 }, struct {
        fn run(out: *anyerror!void) void {
            out.* = deepSnapshot();
        }
    }.run, .{&result});
    th.join();
    try result;
}

fn deepSnapshot() !void {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.account.allowance = std.math.maxInt(u32) - 1;
    const gpa = testing.allocator;
    const steps = try gpa.alloc(Place.Step, 15_000);
    defer gpa.free(steps);
    @memset(steps, Place.Step.elem);
    const a = try f.leaf(1, &.{try f.param(0, 1, &.{})});
    const b = try f.leaf(1, &.{try f.param(1, 1, &.{})});
    // Path copying down 15 000 steps, twice, to two tries.
    const ka = try f.conds.kappaSetAt(gpa, f.charge(), .none, steps, a, shared);
    const kb = try f.conds.kappaSetAt(gpa, f.charge(), .none, steps, b, lost);
    try testing.expectEqual(shared, f.conds.kappaGet(f.conds.kappaAlong(ka, steps), a).?);
    // Relabelled by the identity: the same position.
    const Identity = struct {
        fn node(_: *anyopaque, n: NodeId) Error!?NodeId {
            return n;
        }
        fn cond(_: *anyopaque, _: *Table, _: Allocator, _: Charge, k: CondId) Error!CondId {
            return k;
        }
    };
    var dummy: u8 = 0;
    try testing.expectEqual(ka, try f.conds.kappaRelabel(gpa, f.charge(), ka, .{ .ctx = &dummy, .node = Identity.node, .cond = Identity.cond }));
    // Refused part way, loudly: what it completed is memoised, nothing
    // else, so the same merge then succeeds with room.
    f.account.allowance = f.account.growth + 1000;
    try testing.expectError(error.OwnershipLimit, f.conds.kappaMerge(gpa, f.charge(), ka, kb));
    f.account.failed = null;
    f.account.allowance = std.math.maxInt(u32) - 1;
    // Merged: both entries at the bottom, each pair of positions once.
    const m = try f.conds.kappaMerge(gpa, f.charge(), ka, kb);
    const bottom = f.conds.kappaAlong(m, steps);
    try testing.expectEqual(shared, f.conds.kappaGet(bottom, a).?);
    try testing.expectEqual(lost, f.conds.kappaGet(bottom, b).?);
}
test "#1101: a recast whose inner is a union of recasts keeps what is stored below them, through a join" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const v = f.view();
    // `excl x` stored at the `[*]` of a list node `in1`, recast; a union of
    // that recast and another, recast again: every inner at the outer
    // recast's path is the position's, and its links are its transitions.
    const x = try f.param(0, 1, &.{});
    const k = try f.conds.excl(gpa, f.charge(), x);
    const s1 = try f.cells.site(gpa, &f.account, 3, try f.placeOf(1), .list);
    const s2 = try f.cells.site(gpa, &f.account, 4, try f.placeOf(1), .list);
    const elems = try f.leaf(2, &.{});
    const in1 = try f.shapes.node(gpa, &f.account, try f.placeOf(1), try f.set(&.{s1}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, elems));
    const in2 = try f.shapes.node(gpa, &f.account, try f.placeOf(1), try f.set(&.{s2}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, try f.leaf(2, &.{try f.cells.site(gpa, &f.account, 9, try f.placeOf(2), .list)})));
    const ra = try f.shapes.recast(gpa, &f.account, try f.placeOf(2), in1);
    const rb = try f.shapes.recast(gpa, &f.account, try f.placeOf(2), in2);
    const u = try f.join2(ra, rb);
    const r = try f.shapes.recast(gpa, &f.account, try f.placeOf(1), u);
    try testing.expectEqual(Shape.Kind.recast, f.shapes.kind(r));
    try testing.expectEqual(u, NodeId.from(f.shapes.get(r).a));
    const km = try f.setKPath(.none, &.{Place.Step.elem}, elems, k);
    // Read through the outer recast, before any join.
    try testing.expectEqual(k, try f.conds.deep(gpa, f.charge(), v, km, r, false));
    // Joined with another alternative at the outer place, kept.
    const other = try f.leaf(1, &.{});
    const j = try f.join2(r, other);
    const out = try f.propagate(.none, j, &.{ r, other }, &.{ km, .none }, .alternatives, false);
    try testing.expectEqual(k, try f.conds.deep(gpa, f.charge(), v, out, j, false));
    try testing.expect(try f.conds.kappaLeq(gpa, f.charge(), v, km, r, out, j, false));
    try testing.expect(!try f.conds.kappaLeq(gpa, f.charge(), v, out, j, .none, j, false));
    // What is stored at a nested inner itself is read at the outer recast.
    try testing.expectEqual(k, try f.kappa(try f.setK(.none, in1, k), r, false));
}

test "#1114 review: a join keeps what is stored below every inner of a recast of a union of recasts" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const v = f.view();
    // Two inners with DIFFERENT `[*]` nodes under one recast of a union of
    // recasts; a join with another list projects every inner of the member
    // at the inners' place, never the first one alone.
    const ky = try f.conds.excl(gpa, f.charge(), try f.param(0, 1, &.{}));
    const kx = try f.conds.excl(gpa, f.charge(), try f.param(1, 1, &.{}));
    const elems1 = try f.leaf(2, &.{});
    const elems2 = try f.leaf(2, &.{try f.cells.site(gpa, &f.account, 9, try f.placeOf(2), .list)});
    try testing.expect(elems1 != elems2);
    const s1 = try f.cells.site(gpa, &f.account, 3, try f.placeOf(1), .list);
    const s2 = try f.cells.site(gpa, &f.account, 4, try f.placeOf(1), .list);
    const in1 = try f.shapes.node(gpa, &f.account, try f.placeOf(1), try f.set(&.{s1}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, elems1));
    const in2 = try f.shapes.node(gpa, &f.account, try f.placeOf(1), try f.set(&.{s2}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, elems2));
    const u = try f.join2(try f.shapes.recast(gpa, &f.account, try f.placeOf(2), in1), try f.shapes.recast(gpa, &f.account, try f.placeOf(2), in2));
    const r = try f.shapes.recast(gpa, &f.account, try f.placeOf(1), u);
    const other = try f.leaf(1, &.{try f.cells.site(gpa, &f.account, 7, try f.placeOf(1), .list)});
    const j = try f.join2(r, other);
    // Stored at `in1[*]` only, then at both.
    const one = try f.setKPath(.none, &.{Place.Step.elem}, elems1, ky);
    const both = try f.setKPath(one, &.{Place.Step.elem}, elems2, kx);
    for ([_]Kappas{ one, both }, [_]CondId{ ky, try f.conds.@"and"(gpa, f.charge(), kx, ky) }) |km, want| {
        try testing.expectEqual(try f.conds.flat(gpa, f.charge(), want), try f.conds.flat(gpa, f.charge(), try f.conds.deep(gpa, f.charge(), v, km, r, false)));
        const out = try f.propagate(.none, j, &.{ r, other }, &.{ km, .none }, .alternatives, false);
        try testing.expectEqual(try f.conds.flat(gpa, f.charge(), want), try f.conds.flat(gpa, f.charge(), try f.conds.deep(gpa, f.charge(), v, out, j, false)));
        try testing.expect(try f.conds.kappaLeq(gpa, f.charge(), v, km, r, out, j, false));
    }
}

test "#1112: a built node read at a summary position owes excl for a storage arrival standing for many" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    // A node whose storage is `π1[*]` (one of a parameter's elements, a
    // folded arrival), its certificate `yes`: at a plain position `yes`, at a
    // summary position `excl π1[*]` — wherever it is linked from.
    const pe = try f.param(0, 3, &.{Place.Step.elem});
    const n = try f.shapes.node(gpa, &f.account, try f.placeOf(1), try f.set(&.{pe}), Ids.none_int);
    const k = try f.setK(.none, n, yes);
    try testing.expectEqual(yes, try f.kappa(k, n, false));
    const at_summary = try f.kappa(k, n, true);
    try testing.expectEqual(Kind.atom, f.conds.kind(at_summary));
    try testing.expectEqual(AtomKind.excl, f.conds.get(at_summary).atom);
    // `shared` stays `shared`; no certificate stays `lost`.
    try testing.expectEqual(shared, try f.kappa(try f.setK(.none, n, shared), n, true));
    try testing.expectEqual(lost, try f.kappa(.none, n, true));
}

test "#1112: a one-element literal and a join with an empty alternative are links: nothing below is walked" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    // A deep member: a tower of `Rose [ … ]` levels.
    const e = try f.leaf(6, &.{try f.param(0, 6, &.{})});
    var node = e;
    var k = try f.setK(.none, e, shared);
    for (0..20) |i| {
        const l = try listOver(&f, 7, @intCast(2 * i + 1), node, k);
        const r = try roseOver(&f, @intCast(2 * i + 2), l.node, l.k);
        node = r.node;
        k = r.k;
    }
    var trace: std.ArrayList(u32) = .empty;
    defer trace.deinit(gpa);
    f.conds.trace = &trace;
    // `[ tower ]`: the literal's `[*]` is the tower's snapshot itself.
    const one = try f.conds.propagateFrom(gpa, f.charge(), f.view(), .none, node, &.{node}, &.{k}, .together, true, false, null);
    try testing.expectEqual(@as(usize, 1), trace.items.len);
    try testing.expectEqual(k, one);
    // `if c then tower else <nothing>` at the root's place: the join is the
    // tower's snapshot too.
    trace.clearRetainingCapacity();
    const nothing = try f.shapes.nothing(gpa, &f.account, try f.placeOf(6));
    const j = try f.join2(node, nothing);
    const alt = try f.propagate(.none, j, &.{ node, nothing }, &.{ k, .none }, .alternatives, false);
    f.conds.trace = null;
    try testing.expectEqual(@as(usize, 1), trace.items.len);
    try testing.expectEqual(k, alt);
}

test "#1120: a literal's element that is nothing is no position: `[ x, ∅ ]` is a link to x, `[ x, x ]` is not" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const e = try f.leaf(6, &.{try f.param(0, 6, &.{})});
    var node = e;
    var k = try f.setK(.none, e, shared);
    for (0..20) |i| {
        const l = try listOver(&f, 7, @intCast(2 * i + 1), node, k);
        const r = try roseOver(&f, @intCast(2 * i + 2), l.node, l.k);
        node = r.node;
        k = r.k;
    }
    const nothing = try f.shapes.nothing(gpa, &f.account, try f.placeOf(6));
    // An empty side is no position: the collection is the element itself.
    const with_nothing = try f.collect(&.{ node, nothing });
    try testing.expectEqual(node, with_nothing);
    var trace: std.ArrayList(u32) = .empty;
    defer trace.deinit(gpa);
    f.conds.trace = &trace;
    const one = try f.conds.propagateFrom(gpa, f.charge(), f.view(), .none, node, &.{node}, &.{k}, .together, true, false, null);
    trace.clearRetainingCapacity();
    const linked = try f.conds.propagateFrom(gpa, f.charge(), f.view(), .none, with_nothing, &.{ node, nothing }, &.{ k, .none }, .together, true, false, null);
    try testing.expectEqual(@as(usize, 1), trace.items.len);
    try testing.expectEqual(one, linked);
    // Two equal elements are two positions: walked, and the repeat is read.
    trace.clearRetainingCapacity();
    const twice = try f.collect(&.{ node, node });
    _ = try f.conds.propagateFrom(gpa, f.charge(), f.view(), .none, twice, &.{ node, node }, &.{ k, k }, .together, true, false, null);
    f.conds.trace = null;
    try testing.expect(trace.items.len > 1);
}

test "#1115 review: a one-element literal's [*] still compares everything its element holds below, and a recast owes its excl" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const fa = try Place.Step.field(&f.account, 10);
    const fb = try Place.Step.field(&f.account, 11);
    const rec = try f.placeOf(0);
    const site = try f.cells.site(gpa, &f.account, 1, rec, .record);
    // `[ { a = a, b = b } ]` over two parameters: at `[*]`, `apart{π1, π2}`.
    const p1 = try f.param(0, 1, &.{});
    const p2 = try f.param(1, 1, &.{});
    const pair = try f.shapes.node(gpa, &f.account, rec, try f.set(&.{site}), try f.shapes.overPut(gpa, &f.account, try f.shapes.overPut(gpa, &f.account, Ids.none_int, fa, try f.leaf(1, &.{p1})), fb, try f.leaf(1, &.{p2})));
    const pk = try f.setK(.none, pair, yes);
    const out = try f.conds.propagateFrom(gpa, f.charge(), f.view(), .none, pair, &.{pair}, &.{pk}, .together, true, false, null);
    const k = try f.kappa(out, pair, true);
    try testing.expectEqual(Kind.atom, f.conds.kind(k));
    try testing.expectEqual(AtomKind.apart, f.conds.get(k).atom);
    try testing.expectEqual(@as(u32, 2), f.cells.sets.count(.from(f.conds.get(k).a)));
    // (`[ ( xs, x ) ]` with `x` one of `xs`'s elements: `build_test`.)
    const pe = try f.param(0, 3, &.{Place.Step.elem});
    // A recast member standing for many (`π1[*]`) owes `excl` at `[*]`.
    const r = try f.shapes.recast(gpa, &f.account, try f.placeOf(1), try f.leaf(3, &.{pe}));
    const out3 = try f.conds.propagateFrom(gpa, f.charge(), f.view(), .none, r, &.{r}, &.{.none}, .together, true, false, null);
    const k3 = try f.kappa(out3, r, true);
    try testing.expectEqual(Kind.atom, f.conds.kind(k3));
    try testing.expectEqual(AtomKind.excl, f.conds.get(k3).atom);
}

/// The two conditions are one: equal, or the same atom set.
fn expectSameCond(t: *Table, gpa: Allocator, charge: Charge, a: CondId, b: CondId) !void {
    if (a == b) return;
    try testing.expect(!Table.fails(a) and !Table.fails(b));
    try testing.expectEqual(try t.flat(gpa, charge, a), try t.flat(gpa, charge, b));
}

test "#1121: an incremental apart aggregate decides what apart over the same multiset decides" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var t = &f.conds;
    const list = try f.placeOf(1);
    const s7 = try f.cells.site(gpa, &f.account, 7, list, .list);
    const s8 = try f.cells.site(gpa, &f.account, 8, list, .list);
    const p1 = try f.param(1, 1, &.{});
    const p2 = try f.param(2, 1, &.{});
    const p3 = try f.param(3, 1, &.{});
    const top = try f.cells.top(gpa, &f.account);
    const l1 = try f.cells.label(gpa, &f.account, 40, .none, false);
    _ = try f.cells.split(gpa, &f.account, p1, 40, l1, shared);
    const e1 = try f.cells.refine(gpa, &f.account, .elem, p1, l1, 0, .none, .none);
    const o1 = try f.cells.refine(gpa, &f.account, .others, p1, l1, 0, .none, .list);
    const xs = try f.param(4, 1, &.{});
    _ = try f.cells.split(gpa, &f.account, xs, 41, l1, try t.excl(gpa, f.charge(), xs));
    const ex = try f.cells.refine(gpa, &f.account, .elem, xs, l1, 0, .none, .none);
    const ox = try f.cells.refine(gpa, &f.account, .others, xs, l1, 0, .none, .list);
    const I = Item;
    const cases = [_][]const I{
        &.{ .{ .cell = p1, .approx = false }, .{ .cell = p1, .approx = false } },
        &.{ .{ .cell = s7, .approx = false }, .{ .cell = s7, .approx = false }, .{ .cell = p1, .approx = false } },
        &.{ .{ .cell = s7, .approx = false }, .{ .cell = s8, .approx = false } },
        &.{ .{ .cell = s7, .approx = false }, .{ .cell = p1, .approx = false }, .{ .cell = p2, .approx = false } },
        &.{ .{ .cell = p1, .approx = false }, .{ .cell = p2, .approx = false }, .{ .cell = p3, .approx = false } },
        &.{ .{ .cell = top, .approx = false }, .{ .cell = s7, .approx = false } },
        &.{ .{ .cell = p1, .approx = true }, .{ .cell = p2, .approx = false } },
        &.{ .{ .cell = p1, .approx = true }, .{ .cell = p2, .approx = false }, .{ .cell = p2, .approx = false } },
        &.{ .{ .cell = p2, .approx = false }, .{ .cell = p2, .approx = false }, .{ .cell = p2, .approx = true } },
        &.{ .{ .cell = e1, .approx = false }, .{ .cell = o1, .approx = false } },
        &.{ .{ .cell = ex, .approx = false }, .{ .cell = ox, .approx = false }, .{ .cell = p2, .approx = false } },
        &.{ .{ .cell = ex, .approx = false }, .{ .cell = ox, .approx = false }, .{ .cell = e1, .approx = false }, .{ .cell = o1, .approx = false } },
    };
    for (cases) |items| {
        const scratch = try gpa.dupe(I, items);
        defer gpa.free(scratch);
        const want = try t.apart(gpa, f.charge(), &f.cells, &f.places, scratch, null);
        // One occurrence at a time, and as two members merged (each split
        // point), in both orders.
        var one: Table.Agg = .{};
        for (items) |x| one = try t.aggAdd(gpa, f.charge(), &f.cells, &f.places, one, x.cell, x.approx, true);
        try expectSameCond(t, gpa, f.charge(), want, try t.aggCond(gpa, f.charge(), &f.cells, &f.places, one));
        for (1..items.len) |cut| {
            var left: Table.Agg = .{};
            var right: Table.Agg = .{};
            for (items[0..cut]) |x| left = try t.aggAdd(gpa, f.charge(), &f.cells, &f.places, left, x.cell, x.approx, true);
            for (items[cut..]) |x| right = try t.aggAdd(gpa, f.charge(), &f.cells, &f.places, right, x.cell, x.approx, true);
            try expectSameCond(t, gpa, f.charge(), want, try t.aggCond(gpa, f.charge(), &f.cells, &f.places, try t.aggMerge(gpa, f.charge(), &f.cells, &f.places, left, right, true)));
            try expectSameCond(t, gpa, f.charge(), want, try t.aggCond(gpa, f.charge(), &f.cells, &f.places, try t.aggMerge(gpa, f.charge(), &f.cells, &f.places, right, left, true)));
        }
    }
    // A group's image, extended from its predecessors' images, is apart's
    // over the images: here two cells meeting at one image are a repeat.
    var g: Table.Agg = .{};
    for ([_]CellId{ p1, p2, p3 }) |c| g = try t.aggAdd(gpa, f.charge(), &f.cells, &f.places, g, c, false, false);
    const Img = struct {
        to: CellId,
        from: CellId,
        fn of(s: *const @This(), c: CellId) Error!CellId {
            return if (c == s.from) s.to else c;
        }
    };
    var memo: Ids.FixedDict(1) = .{};
    defer memo.deinit(gpa);
    const img: Img = .{ .from = p3, .to = p1 };
    try testing.expectEqual(shared, try t.apartImage(gpa, f.charge(), &f.cells, &f.places, g.group, &memo, &img, Img.of));
    var memo2: Ids.FixedDict(1) = .{};
    defer memo2.deinit(gpa);
    const ident: Img = .{ .from = p3, .to = p3 };
    try expectSameCond(t, gpa, f.charge(), try f.apart(&.{ p1, p2, p3 }), try t.apartImage(gpa, f.charge(), &f.cells, &f.places, g.group, &memo2, &ident, Img.of));
}

fn aggSame(t: *Table, gpa: Allocator, charge: Charge, a: CondId, b: CondId) !u8 {
    if (a == b) return 0;
    if (Table.fails(a) or Table.fails(b)) return 1;
    if (try t.flat(gpa, charge, a) == try t.flat(gpa, charge, b)) return 0;
    return 2;
}

// The review's differential, in two tests (one was near the 1 s budget, #1197):
// random aggregates against `apart`, and random cyclic shapes' reach aggregates in
// two halves of 750 shapes on two seeds (1 500 on one seed before).
test "#1150 review: random aggregates decide what apart over the same multiset decides: members, orders and images" {
    try randomAggregates(0);
}

test "#1150 review: random aggregates decide what apart over the same multiset decides: cyclic shapes' reach, 750 of one seed" {
    try randomAggregates(1);
}

test "#1150 review: random aggregates decide what apart over the same multiset decides: cyclic shapes' reach, 750 of another" {
    try randomAggregates(2);
}

fn randomAggregates(part: u32) !void {
    const members = part == 0;
    // The review's differential: random members built of random parts
    // (sites, parameters at folded paths, ⊤, two splits' refinements, a
    // taken element and its container, approximate occurrences), merged in
    // both orders and one occurrence at a time; random groups' images; and
    // random cyclic shapes' reach aggregates.

    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var t = &f.conds;
    const list = try f.placeOf(1);
    var pool: std.ArrayList(CellId) = .empty;
    defer pool.deinit(gpa);
    try pool.append(gpa, try f.cells.site(gpa, &f.account, 7, list, .list));
    try pool.append(gpa, try f.cells.site(gpa, &f.account, 8, list, .list));
    const p1 = try f.param(1, 1, &.{});
    try pool.append(gpa, p1);
    try pool.append(gpa, try f.param(2, 1, &.{}));
    try pool.append(gpa, try f.param(3, 1, &.{}));
    try pool.append(gpa, try f.cells.top(gpa, &f.account));
    const l1 = try f.cells.label(gpa, &f.account, 40, .none, false);
    _ = try f.cells.split(gpa, &f.account, p1, 40, l1, shared);
    try pool.append(gpa, try f.cells.refine(gpa, &f.account, .elem, p1, l1, 0, .none, .none));
    try pool.append(gpa, try f.cells.refine(gpa, &f.account, .elem, p1, l1, 1, .none, .none));
    try pool.append(gpa, try f.cells.refine(gpa, &f.account, .others, p1, l1, 0, .none, .list));
    const xs = try f.param(4, 1, &.{});
    _ = try f.cells.split(gpa, &f.account, xs, 41, l1, try t.excl(gpa, f.charge(), xs));
    try pool.append(gpa, try f.cells.refine(gpa, &f.account, .elem, xs, l1, 0, .none, .none));
    try pool.append(gpa, try f.cells.refine(gpa, &f.account, .others, xs, l1, 0, .none, .list));
    // A taken element and its container's [*].
    const r0 = try f.param(5, 3, &.{});
    const l2 = try f.cells.label(gpa, &f.account, 42, .none, false);
    _ = try f.cells.split(gpa, &f.account, r0, 42, l2, try t.excl(gpa, f.charge(), r0));
    try pool.append(gpa, try f.cells.refine(gpa, &f.account, .elem, r0, l2, 0, .none, .none));
    try pool.append(gpa, try f.param(5, 3, &.{Place.Step.elem}));
    try pool.append(gpa, try f.param(0, 3, &.{Place.Step.elem}));
    const lf = try f.cells.label(gpa, &f.account, 43, .none, true);
    _ = try f.cells.split(gpa, &f.account, p1, 43, lf, try t.excl(gpa, f.charge(), p1));
    try pool.append(gpa, try f.cells.refine(gpa, &f.account, .elem, p1, lf, 0, .none, .none));
    try pool.append(gpa, try f.cells.refine(gpa, &f.account, .others, p1, lf, 0, .none, .list));
    try pool.append(gpa, try f.param(1, 3, &.{Place.Step.elem}));
    try pool.append(gpa, try f.param(1, 3, &.{}));
    try pool.append(gpa, try f.param(2, 3, &.{ Place.Step.elem, Place.Step.elem }));
    try pool.append(gpa, try f.param(2, 3, &.{}));
    try pool.append(gpa, try f.cells.site(gpa, &f.account, 9, list, .list));
    const n_pool = pool.items.len;
    f.account.allowance = std.math.maxInt(u32) - 1;

    var prng = std.Random.DefaultPrng.init(777 + part);
    const r = prng.random();
    var bad: u32 = 0;
    var iter: u32 = 0;
    while (members and iter < 400) : (iter += 1) {
        // Members, each a set made of parts.
        const n_members = 1 + r.uintLessThan(usize, 4);
        var items: std.ArrayList(Item) = .empty;
        defer items.deinit(gpa);
        var together: Table.Agg = .{};
        var together2: Table.Agg = .{};
        var member_aggs: [4]Table.Agg = undefined;
        for (0..n_members) |mi| {
            const n_parts = 1 + r.uintLessThan(usize, 3);
            var mset: SetId = .none;
            var magg: ?Table.Agg = null;
            for (0..n_parts) |_| {
                var ps: SetId = .none;
                for (0..r.uintLessThan(usize, 4)) |_| {
                    ps = try f.cells.sets.insert(gpa, f.charge(), ps, pool.items[r.uintLessThan(usize, n_pool)].int(), @intFromBool(r.uintLessThan(u8, 4) == 0));
                }
                mset = try f.cells.sets.unionWith(gpa, f.charge(), mset, ps);
                const pa = try t.aggAll(gpa, f.charge(), &f.cells, &f.places, .{}, ps, false);
                magg = if (magg) |m| (if (r.boolean()) try t.aggMerge(gpa, f.charge(), &f.cells, &f.places, m, pa, false) else try t.aggMerge(gpa, f.charge(), &f.cells, &f.places, pa, m, false)) else pa;
            }
            var it = f.cells.sets.iterate(mset);
            while (it.next()) |e| try items.append(gpa, .{ .cell = .from(e.key), .approx = e.value == 1 });
            member_aggs[mi] = magg.?;
            together = try t.aggMerge(gpa, f.charge(), &f.cells, &f.places, together, magg.?, true);
        }
        // Reverse order too.
        var mi2 = n_members;
        while (mi2 > 0) {
            mi2 -= 1;
            together2 = try t.aggMerge(gpa, f.charge(), &f.cells, &f.places, together2, member_aggs[mi2], true);
        }
        // One by one.
        var one: Table.Agg = .{};
        for (items.items) |x| one = try t.aggAdd(gpa, f.charge(), &f.cells, &f.places, one, x.cell, x.approx, true);
        const scratch = try gpa.dupe(Item, items.items);
        defer gpa.free(scratch);
        const want = try t.apart(gpa, f.charge(), &f.cells, &f.places, scratch, null);
        for ([_]Table.Agg{ together, together2, one }, 0..) |a, which| {
            const got = try t.aggCond(gpa, f.charge(), &f.cells, &f.places, a);
            const s = try aggSame(t, gpa, f.charge(), want, got);
            if (s != 0) {
                bad += 1;
                _ = which;
            }
        }
        // Images.
        var g: Table.Agg = .{};
        var gcells: std.ArrayList(CellId) = .empty;
        defer gcells.deinit(gpa);
        for (0..r.uintLessThan(usize, 6)) |_| {
            const c = pool.items[r.uintLessThan(usize, n_pool)];
            g = try t.aggAdd(gpa, f.charge(), &f.cells, &f.places, g, c, false, r.boolean());
        }
        if (g.group != .none) {
            var map: [32]CellId = undefined;
            for (pool.items, 0..) |c, j| map[j] = if (r.uintLessThan(u8, 3) == 0) pool.items[r.uintLessThan(usize, n_pool)] else c;
            const Img = struct {
                pool: []const CellId,
                map: []const CellId,
                fn of(s: *const @This(), c: CellId) Error!CellId {
                    for (s.pool, 0..) |p, j| if (p == c) return s.map[j];
                    return c;
                }
            };
            const img: Img = .{ .pool = pool.items, .map = map[0..n_pool] };
            var memo: Ids.FixedDict(1) = .{};
            defer memo.deinit(gpa);
            var it = f.cells.sets.iterate(g.group);
            var im: std.ArrayList(Item) = .empty;
            defer im.deinit(gpa);
            while (it.next()) |e| try im.append(gpa, .{ .cell = try img.of(.from(e.key)), .approx = false });
            const want_i = try t.apart(gpa, f.charge(), &f.cells, &f.places, im.items, null);
            const got_i = try t.apartImage(gpa, f.charge(), &f.cells, &f.places, g.group, &memo, &img, Img.of);
            // Twice, memo hit.
            const got_i2 = try t.apartImage(gpa, f.charge(), &f.cells, &f.places, g.group, &memo, &img, Img.of);
            if (try aggSame(t, gpa, f.charge(), want_i, got_i) != 0 or try aggSame(t, gpa, f.charge(), want_i, got_i2) != 0) {
                bad += 1;
            }
        }
    }
    // Shapes: reachAgg against reach.
    const fa = try Place.Step.field(&f.account, 10);
    const rec = try f.placeOf(0);
    var sbad: u32 = 0;
    var siter: u32 = 0;
    while (!members and siter < 750) : (siter += 1) {
        const nk = 2 + r.uintLessThan(usize, 7);
        var ks: [9]NodeId = undefined;
        for (ks[0..nk]) |*k| k.* = try f.shapes.knot(gpa, &f.account);
        var lvs: [3]NodeId = undefined;
        for (&lvs) |*l| {
            var cs: SetId = .none;
            for (0..r.uintLessThan(usize, 3)) |_| cs = try f.cells.sets.insert(gpa, f.charge(), cs, pool.items[r.uintLessThan(usize, n_pool)].int(), @intFromBool(r.uintLessThan(u8, 4) == 0));
            l.* = try f.shapes.leaf(gpa, &f.account, rec, cs);
        }
        for (ks[0..nk], 0..) |k, ki| {
            var cs: SetId = .none;
            for (0..r.uintLessThan(usize, 3)) |_| cs = try f.cells.sets.insert(gpa, f.charge(), cs, pool.items[r.uintLessThan(usize, n_pool)].int(), @intFromBool(r.uintLessThan(u8, 4) == 0));
            // Mostly forward edges, some back edges.
            const pickk = struct {
                fn of(rr: std.Random, kss: []NodeId, ls: []NodeId, i: usize) NodeId {
                    if (rr.uintLessThan(u8, 3) == 0) return ls[rr.uintLessThan(usize, ls.len)];
                    if (rr.uintLessThan(u8, 5) == 0 or i + 1 >= kss.len) return kss[rr.uintLessThan(usize, kss.len)];
                    return kss[i + 1 + rr.uintLessThan(usize, kss.len - i - 1)];
                }
            }.of;
            switch (r.uintLessThan(u8, 5)) {
                0, 1 => {
                    var over: u32 = Ids.none_int;
                    over = try f.shapes.overPut(gpa, &f.account, over, fa, pickk(r, ks[0..nk], &lvs, ki));
                    if (r.boolean()) over = try f.shapes.overPut(gpa, &f.account, over, Place.Step.elem, pickk(r, ks[0..nk], &lvs, ki));
                    f.shapes.tie(k, .{ .kind = .node, .place = rec, .cells = cs, .a = over, .b = 0, .reach = .none });
                },
                2 => {
                    const inner = pickk(r, ks[0..nk], &lvs, ki);
                    f.shapes.tie(k, .{ .kind = .recast, .place = rec, .cells = f.shapes.cells(inner), .a = inner.int(), .b = 0, .reach = .none });
                },
                else => {
                    const a = pickk(r, ks[0..nk], &lvs, ki);
                    const b = pickk(r, ks[0..nk], &lvs, ki);
                    f.shapes.tie(k, .{ .kind = if (r.boolean()) .@"union" else .positions, .place = rec, .cells = try f.cells.sets.unionWith(gpa, f.charge(), f.shapes.cells(a), f.shapes.cells(b)), .a = a.int(), .b = b.int(), .reach = .none });
                },
            }
        }
        // Read members in random order (memo order varies).
        const nm = 1 + r.uintLessThan(usize, 3);
        var items: std.ArrayList(Item) = .empty;
        defer items.deinit(gpa);
        var tog: Table.Agg = .{};
        for (0..nm) |_| {
            const m = ks[r.uintLessThan(usize, nk)];
            const ag = try t.reachAgg(gpa, f.charge(), f.view(), m);
            tog = try t.aggMerge(gpa, f.charge(), &f.cells, &f.places, tog, ag, true);
            var it = f.cells.sets.iterate(try f.shapes.reach(gpa, &f.account, &f.cells.sets, m));
            while (it.next()) |e| try items.append(gpa, .{ .cell = .from(e.key), .approx = e.value == 1 });
        }
        const want = try t.apart(gpa, f.charge(), &f.cells, &f.places, items.items, null);
        const got = try t.aggCond(gpa, f.charge(), &f.cells, &f.places, tog);
        if (try aggSame(t, gpa, f.charge(), want, got) != 0) {
            sbad += 1;
        }
    }
    try testing.expectEqual(@as(u32, 0), bad);
    try testing.expectEqual(@as(u32, 0), sbad);
}

test "#1150 review: a group's image numbers its cells in set order, whatever order built it; a tie renews a reach aggregate" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var t = &f.conds;
    const p1 = try f.param(1, 1, &.{});
    const p2 = try f.param(2, 1, &.{});
    // The group {p1, p2}, first built p2 then p1: its provenance says so.
    var g: Table.Agg = .{};
    g = try t.aggAdd(gpa, f.charge(), &f.cells, &f.places, g, p2, false, false);
    g = try t.aggAdd(gpa, f.charge(), &f.cells, &f.places, g, p1, false, false);
    const Seen = struct {
        order: [4]CellId = undefined,
        n: usize = 0,
        fn of(s: *@This(), c: CellId) Error!CellId {
            for (s.order[0..s.n]) |x| if (x == c) return c;
            s.order[s.n] = c;
            s.n += 1;
            return c;
        }
    };
    var seen: Seen = .{};
    var memo: Ids.FixedDict(1) = .{};
    defer memo.deinit(gpa);
    _ = try t.apartImage(gpa, f.charge(), &f.cells, &f.places, g.group, &memo, &seen, Seen.of);
    try testing.expectEqual(@as(usize, 2), seen.n);
    try testing.expect(seen.order[0].int() < seen.order[1].int());
    // A node over a knot, aggregated while the knot is pending, then tied:
    // the aggregate reads the tied record's cells.
    const k = try f.shapes.knot(gpa, &f.account);
    const rec = try f.placeOf(0);
    const n = try f.shapes.node(gpa, &f.account, rec, .none, try f.shapes.overPut(gpa, &f.account, Ids.none_int, try Place.Step.field(&f.account, 10), k));
    try testing.expectEqual(@as(u32, 0), (try t.reachAgg(gpa, f.charge(), f.view(), n)).all_len);
    f.shapes.tie(k, .{ .kind = .leaf, .place = rec, .cells = try f.set(&.{p1}), .a = 0, .b = 0, .reach = .none });
    try testing.expectEqual(@as(u32, 1), (try t.reachAgg(gpa, f.charge(), f.view(), n)).all_len);
}

test "#1157 review: a fold obligation read through a chain of unions costs each union its own node" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    f.account.allowance = std.math.maxInt(u32) - 1;
    const list = try f.placeOf(1);
    var cost: [3]u64 = undefined;
    for ([_]u32{ 100, 200, 400 }, 0..) |n, run| {
        // A left-deep chain of unions over leaves each carrying an obligation,
        // read at every link, as `propagate` reads each state.
        var u = try f.shapes.leaf(gpa, &f.account, list, try f.set(&.{try f.cells.site(gpa, &f.account, 100_000 * n, list, .list)}));
        var read: u64 = 0;
        for (0..n) |i| {
            const l = try f.shapes.leaf(gpa, &f.account, list, try f.set(&.{try f.cells.site(gpa, &f.account, @intCast(100_000 * n + i + 1), list, .list)}));
            try f.conds.fold_cond.put(gpa, l, lost);
            f.conds.fold_cond_n += 1;
            u = try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, u, l);
            const before = f.account.total();
            try testing.expectEqual(lost, try f.conds.foldCondOf(gpa, f.charge(), f.view(), u));
            read += f.account.total() - before;
        }
        cost[run] = read;
    }
    // Twice the links, about twice the work, never four times.
    try testing.expect(cost[1] <= 3 * cost[0]);
    try testing.expect(cost[2] <= 3 * cost[1]);
}

/// `Rose [ Rose x, Rose [] ]` with `x` at the children list: a value whose
/// widen folds its levels.
fn roseTwoLevels(f: *Fixture, x: NodeId) !NodeId {
    const gpa = testing.allocator;
    const rose = try f.placeOf(6);
    const kids = try f.placeOf(7);
    const arg = try f.places.ctorStep(gpa, &f.account, 6, 0);
    const rk = Cell.Kind.ofPlace(f.places.kind(rose));
    const lk = Cell.Kind.ofPlace(f.places.kind(kids));
    const empty = try f.shapes.nothing(gpa, &f.account, kids);
    const ra = try f.shapes.node(gpa, &f.account, rose, try f.set(&.{try f.cells.site(gpa, &f.account, 2, rose, rk)}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, arg, x));
    const rb = try f.shapes.node(gpa, &f.account, rose, try f.set(&.{try f.cells.site(gpa, &f.account, 3, rose, rk)}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, arg, empty));
    const lit = try f.shapes.node(gpa, &f.account, kids, try f.set(&.{try f.cells.site(gpa, &f.account, 4, kids, lk)}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, try f.collect(&.{ ra, rb })));
    return f.shapes.node(gpa, &f.account, rose, try f.set(&.{try f.cells.site(gpa, &f.account, 1, rose, rk)}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, arg, lit));
}

test "κ at a view: its chain's entries join its answer's, a recast's inner view and a union's view of a recast read alike" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    const lk = Cell.Kind.ofPlace(f.places.kind(list));
    const arg = try f.leaf(1, &.{try f.cells.site(gpa, &f.account, 1, list, lk)});
    const p1 = try f.leaf(1, &.{try f.param(1, 1, &.{})});
    var ti: Shape.TestInstantiation = .{ .cellt = &f.cells, .arg = arg };
    f.shapes.instantiation = ti.inst();
    const k1 = try f.sep(try f.param(2, 1, &.{}), try f.param(3, 1, &.{}));
    // A chain: `outer` answers `mid`, which answers `arg`.
    const mid = try f.shapes.view(gpa, &f.account, p1, 0);
    try testing.expectEqual(arg, try f.shapes.force(gpa, &f.account, mid));
    ti.arg = mid;
    const outer = try f.shapes.view(gpa, &f.account, p1, 1);
    try testing.expectEqual(arg, try f.shapes.force(gpa, &f.account, outer));
    // Stored under the middle view, read at the outer one: as stored at `arg`.
    const at_mid = try f.setK(.none, mid, k1);
    const at_arg = try f.setK(.none, arg, k1);
    try testing.expectEqual(try f.kappa(at_arg, arg, false), try f.kappa(at_mid, outer, false));
    try testing.expectEqual(try f.kappa(at_arg, arg, false), try f.kappa(at_mid, outer, false)); // memoised: the same again
    // A recast's inner is a position of the recast: a view there reads its chain.
    const rec_v = try f.shapes.recast(gpa, &f.account, try f.placeOf(3), outer);
    const rec_e = try f.shapes.recast(gpa, &f.account, try f.placeOf(3), arg);
    try testing.expectEqual(try f.kappa(at_arg, rec_e, true), try f.kappa(at_mid, rec_v, true));
    // A union's side that is a view of a recast is approximate as the recast is.
    ti.arg = arg;
    const b = try f.leaf(1, &.{try f.cells.site(gpa, &f.account, 2, list, lk)});
    const rc_t = try f.shapes.recast(gpa, &f.account, list, try f.leaf(3, &.{try f.param(1, 3, &.{})}));
    const vr = try f.shapes.view(gpa, &f.account, rc_t, 2);
    try testing.expectEqual(Shape.Kind.recast, f.shapes.kind(try f.shapes.force(gpa, &f.account, vr)));
    const eager_rc = try f.shapes.recast(gpa, &f.account, list, arg);
    try testing.expectEqual(try f.kappa(.none, try f.join2(eager_rc, b), true), try f.kappa(.none, try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, vr, b), true));
}

test "a view's reach aggregate and its widened fold are its eager image's" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const kids = try f.placeOf(7);
    const lk = Cell.Kind.ofPlace(f.places.kind(kids));
    const arg = try f.shapes.leaf(gpa, &f.account, kids, try f.set(&.{try f.cells.site(gpa, &f.account, 9, kids, lk)}));
    const p = try f.shapes.leaf(gpa, &f.account, kids, try f.set(&.{try f.param(1, 7, &.{})}));
    var ti: Shape.TestInstantiation = .{ .cellt = &f.cells, .arg = arg };
    f.shapes.instantiation = ti.inst();
    const eager = try roseTwoLevels(&f, arg);
    const v = try f.shapes.view(gpa, &f.account, try roseTwoLevels(&f, p), 0);
    // `partsOf` reads a view as its answer.
    try testing.expect(std.meta.eql(try f.conds.reachAgg(gpa, f.charge(), f.view(), eager), try f.conds.reachAgg(gpa, f.charge(), f.view(), v)));
    // The fold's source walk (`sourceParts`) reads the answers widen visited.
    const we = try f.conds.widenValue(gpa, f.charge(), f.view(), eager, .none);
    const wv = try f.conds.widenValue(gpa, f.charge(), f.view(), v, .none);
    try testing.expect(try f.shapes.eq(gpa, &f.account, &f.places, &f.cells, we.node, wv.node));
    try testing.expectEqual(try f.kappa(we.kappas, we.node, false), try f.kappa(wv.kappas, wv.node, false));
    const arg_step = try f.places.ctorStep(gpa, &f.account, 6, 0);
    try testing.expectEqual(try f.kappaPath(we.kappas, &.{ arg_step, Place.Step.elem }, try f.projOf(try f.projOf(we.node, arg_step), Place.Step.elem), true), try f.kappaPath(wv.kappas, &.{ arg_step, Place.Step.elem }, try f.projOf(try f.projOf(wv.node, arg_step), Place.Step.elem), true));
}

test "#1279 review: κ stored under a chain's middle view survives a read-off's relabelling, and a recast's inner view reads its chain" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    const lol = try f.placeOf(3);
    const lk = Cell.Kind.ofPlace(f.places.kind(lol));
    const arg = try f.leaf(3, &.{try f.cells.site(gpa, &f.account, 1, lol, lk)});
    const p1 = try f.leaf(3, &.{try f.param(1, 3, &.{})});
    var ti: Shape.TestInstantiation = .{ .cellt = &f.cells, .arg = arg };
    f.shapes.instantiation = ti.inst();
    const k1 = try f.sep(try f.param(2, 1, &.{}), try f.param(3, 1, &.{}));
    const mid = try f.shapes.view(gpa, &f.account, p1, 0);
    try testing.expectEqual(arg, try f.shapes.force(gpa, &f.account, mid));
    ti.arg = mid;
    const outer = try f.shapes.view(gpa, &f.account, p1, 1);
    try testing.expectEqual(arg, try f.shapes.force(gpa, &f.account, outer));
    const at_mid = try f.setK(.none, mid, k1);
    const want = try f.kappa(at_mid, outer, false);
    try testing.expect(want != try f.kappa(.none, outer, false)); // the entry matters
    // Read-off: `map` the value, then carry its κ over the map's images.
    const Carry = struct {
        shapes: *Shape.Table,
        fn node(ctx: *anyopaque, x: NodeId) Error!?NodeId {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            return c.shapes.memo_map.get(x);
        }
        fn cond(_: *anyopaque, _: *Table, _: Allocator, _: Charge, k: CondId) Error!CondId {
            return k;
        }
        fn same(_: void, s: SetId) Error!SetId {
            return s;
        }
    };
    const mapped = try f.shapes.map(gpa, &f.account, outer, {}, Carry.same);
    var carry: Carry = .{ .shapes = &f.shapes };
    const relabelled = try f.conds.kappaRelabel(gpa, f.charge(), at_mid, .{ .ctx = &carry, .node = Carry.node, .cond = Carry.cond });
    try testing.expectEqual(want, try f.kappa(relabelled, mapped, false));
    // A recast is one position with its inner, and a recast has no finite
    // rank, so `innersOf` lists the inner view: its chain's entry counts.
    const rec_v = try f.shapes.recast(gpa, &f.account, list, outer);
    const rec_e = try f.shapes.recast(gpa, &f.account, list, arg);
    const at_arg = try f.setK(.none, arg, k1);
    const via_arg = try f.kappa(at_arg, rec_e, false);
    try testing.expect(via_arg != try f.kappa(.none, rec_e, false));
    try testing.expectEqual(via_arg, try f.kappa(at_mid, rec_v, false));
}

test "#1279 review: a union's view side owes its answer's fold certificate" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    const lk = Cell.Kind.ofPlace(f.places.kind(list));
    // A widened class image's certificate (`widenValue` stores one; set here).
    const image = try f.leaf(1, &.{try f.cells.site(gpa, &f.account, 9, list, lk)});
    try f.conds.fold_cond.put(gpa, image, lost);
    f.conds.fold_cond_n += 1;
    var ti: Shape.TestInstantiation = .{ .cellt = &f.cells, .arg = image };
    f.shapes.instantiation = ti.inst();
    const v = try f.shapes.view(gpa, &f.account, try f.leaf(1, &.{try f.param(1, 1, &.{})}), 0);
    const other = try f.leaf(1, &.{try f.cells.site(gpa, &f.account, 11, list, lk)});
    const u_v = try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, v, other);
    const u_e = try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, image, other);
    try testing.expectEqual(lost, try f.conds.foldCondOf(gpa, f.charge(), f.view(), u_e));
    try testing.expectEqual(lost, try f.conds.foldCondOf(gpa, f.charge(), f.view(), u_v));
}

test "#1335: a cycle of a union and a view with no node on it owes, at each member, what enters it" {
    // `U = union(image, V)`, `V` a view whose answer is `U`: a cycle of
    // unions and views alone, which `foldCondOf` walks with no node to
    // stop it. Each member owes the image's certificate, the one thing
    // that enters the cycle. Bounded by the allowance, so a walk that does
    // not end fails fast.
    const gpa = testing.allocator;
    for ([_]bool{ false, true }) |swap| {
        var f: Fixture = .{};
        try f.init();
        defer f.deinit();
        const list = try f.placeOf(1);
        const lk = Cell.Kind.ofPlace(f.places.kind(list));
        const image = try f.leaf(1, &.{try f.cells.site(gpa, &f.account, 9, list, lk)});
        try f.conds.fold_cond.put(gpa, image, lost);
        f.conds.fold_cond_n += 1;
        const u = try f.shapes.knot(gpa, &f.account);
        var ti: Shape.TestInstantiation = .{ .cellt = &f.cells, .arg = u };
        f.shapes.instantiation = ti.inst();
        const v = try f.shapes.view(gpa, &f.account, try f.leaf(1, &.{try f.param(1, 1, &.{})}), 0);
        const l, const r = if (swap) .{ v, image } else .{ image, v };
        f.shapes.tie(u, .{ .kind = .@"union", .place = list, .cells = f.shapes.cells(image), .a = l.int(), .b = r.int(), .reach = .none });
        try testing.expectEqual(u, try f.shapes.force(gpa, &f.account, v));
        f.account.allowance = f.account.growth + 100_000;
        try testing.expectEqual(lost, try f.conds.foldCondOf(gpa, f.charge(), f.view(), v));
        try testing.expectEqual(lost, try f.conds.foldCondOf(gpa, f.charge(), f.view(), u));
    }
}
test "#1121: a cell set's derivation over its aggregate and an atom's two sides merged along their tries are apart's" {
    // `ownership-v2.md` §2.11 *The derivation*: `derivedCells` over the set
    // aggregate (memoised per radix node), the repeats added as sets, and
    // `aggMergeSets` over two sets, against one sorted list of the same
    // multiset (`apart`), on sets built one insertion at a time.
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    var pool: [24]CellId = undefined;
    for (&pool, 0..) |*c, i| c.* = if (i % 3 == 0)
        try f.param(@intCast(i), 1, &.{})
    else
        try f.cells.site(gpa, &f.account, @intCast(500 + i), list, .list);
    var prng = std.Random.DefaultPrng.init(1121);
    const r = prng.random();
    var a: SetId = .none;
    var b: SetId = .none;
    for (0..40) |_| {
        const c = pool[r.uintLessThan(usize, pool.len)];
        const approx: u1 = @intFromBool(r.uintLessThan(u8, 8) == 0);
        if (r.boolean()) a = try f.cells.sets.insert(gpa, f.charge(), a, c.int(), approx) else b = try f.cells.sets.insert(gpa, f.charge(), b, c.int(), approx);
        // Two sides as one multiset.
        var items: std.ArrayList(Item) = .empty;
        defer items.deinit(gpa);
        for ([_]SetId{ a, b }) |s| {
            var it = f.cells.sets.iterate(s);
            while (it.next()) |e| try items.append(gpa, .{ .cell = .from(e.key), .approx = e.value == 1 });
        }
        const want = try f.conds.apart(gpa, f.charge(), &f.cells, &f.places, items.items, null);
        const got = try f.conds.aggCond(gpa, f.charge(), &f.cells, &f.places, try f.conds.aggMergeSets(gpa, f.charge(), &f.cells, &f.places, a, b));
        try f.conds.expectSame(gpa, f.charge(), want, got);
        // One set, its common cells with the other as repeats.
        const both = try f.cells.sets.intersection(gpa, f.charge(), a, b);
        const dups_approx = try f.conds.cellPart(gpa, f.charge(), &f.cells, &f.places, .approx, both);
        const u = try f.cells.sets.unionWith(gpa, f.charge(), a, b);
        try f.conds.expectSame(gpa, f.charge(), try f.conds.derivedCellsFlat(gpa, f.charge(), f.view(), u, both, dups_approx), try f.conds.derivedCells(gpa, f.charge(), f.view(), u, true, both, dups_approx));
    }
}

test "eqOn compares only the keys based on the region, the empty value always" {
    // `ownership-v2.md` §2.11 *The equality*: an entry `C` holds and `R` does
    // not is no inequality for a key the region does not test; it is for a
    // node of the region and for the empty value.
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    const inside = try f.shapes.leaf(gpa, &f.account, list, try f.set(&.{try f.cells.site(gpa, &f.account, 1, list, .list)}));
    const outside = try f.shapes.leaf(gpa, &f.account, list, try f.set(&.{try f.cells.site(gpa, &f.account, 2, list, .list)}));
    const empty = try f.shapes.nothing(gpa, &f.account, list);
    const region = try f.shapes.node_sets.insert(gpa, f.charge(), .none, inside.int(), 0);
    const atom = try f.conds.excl(gpa, f.charge(), try f.param(0, 1, &.{}));
    const r = try f.setK(.none, inside, yes);
    try testing.expect(try f.conds.eqOn(gpa, f.charge(), f.view(), try f.setK(r, outside, atom), r, region));
    try testing.expect(!try f.conds.eqOn(gpa, f.charge(), f.view(), try f.setK(r, inside, atom), r, region));
    try testing.expect(!try f.conds.eqOn(gpa, f.charge(), f.view(), try f.setK(r, empty, atom), r, region));
    // A step `C` links and `R` does not is no equality either.
    const linked = try f.conds.kappaLink(gpa, f.charge(), r, Place.Step.elem, try f.setK(.none, outside, atom));
    try testing.expect(!try f.conds.eqOn(gpa, f.charge(), f.view(), linked, r, region));
}

test "a read at another position takes its home's entry only where the two read alike on the node's region" {
    // `ownership-v2.md` §2.11 *A read at another position*: `u = union(a, b)`
    // read at `h`, which stores `a ↦ shared`, is `u`'s home. A position that
    // differs from `h` only outside the region reads what `h` reads; one that
    // binds `a` or `b` otherwise must be read itself, never from the home.
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    const a = try f.shapes.leaf(gpa, &f.account, list, try f.set(&.{try f.cells.site(gpa, &f.account, 1, list, .list)}));
    const b = try f.shapes.leaf(gpa, &f.account, list, try f.set(&.{try f.cells.site(gpa, &f.account, 2, list, .list)}));
    const x = try f.shapes.leaf(gpa, &f.account, list, try f.set(&.{try f.cells.site(gpa, &f.account, 3, list, .list)}));
    const u = try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, a, b);
    const h = try f.setK(.none, a, shared);
    try testing.expectEqual(shared, try f.kappa(h, u, false));
    // Outside the region: the home's entry, which is the read itself.
    const outside = try f.setK(h, x, lost);
    try testing.expectEqual(shared, try f.kappa(outside, u, false));
    // On the region, `a` bound otherwise and `b` bound: read here.
    const inside = try f.setK(try f.setK(.none, a, lost), b, lost);
    try testing.expectEqual(lost, try f.kappa(inside, u, false));
    // And with nothing stored on the region: what the leaves derive.
    const bare = try f.setK(.none, x, shared);
    f.conds.no_memo = true;
    const fresh = try f.kappa(bare, u, false);
    f.conds.no_memo = false;
    try testing.expectEqual(fresh, try f.kappa(bare, u, false));
    try testing.expect(fresh != shared);
}

test "a union tower read at a position one level larger each time costs its new level (the home's witness)" {
    // `u_k = union(l_k, u_{k-1})` read at `c_k`, which binds `l_k` beside
    // what `c_{k-1}` binds: `u_{k-1}` reads at `c_k` what it read at
    // `c_{k-1}` (§2.11 *A read at another position*), so each level costs a
    // constant. Read again at each position, the tower is quadratic.
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    f.account.allowance = 1 << 26;
    var costs: [2]u64 = undefined;
    for ([_]u32{ 64, 256 }, 0..) |depth, run| {
        var u = try f.shapes.leaf(gpa, &f.account, list, try f.set(&.{try f.cells.site(gpa, &f.account, @intCast(1_000_000 * (run + 1)), list, .list)}));
        var c: Kappas = .none;
        const before = f.account.total();
        for (0..depth) |k| {
            const l = try f.shapes.leaf(gpa, &f.account, list, try f.set(&.{try f.cells.site(gpa, &f.account, @intCast(1_000_000 * (run + 1) + k + 1), list, .list)}));
            u = try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, l, u);
            c = try f.setK(c, l, lost);
            try testing.expectEqual(lost, try f.kappa(c, u, false));
        }
        costs[run] = f.account.total() - before;
    }
    // Four times the levels: about four times the records, never sixteen.
    try testing.expect(costs[1] <= 6 * costs[0]);
}

test "read-off maps an entry map many positions share once (relabelMap's witness)" {
    // §2.9: read-off maps κ submaps once under one correspondence. `m`
    // positions, linked one below the other, each store a base map of 128
    // entries and one entry of their own. Each shared map node is mapped
    // once, so four times the positions is far less than four times the
    // records; one walk of every entry of every position is four times.
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    f.account.allowance = 1 << 26;
    const Identity = struct {
        fn node(_: *anyopaque, n: NodeId) Error!?NodeId {
            return n;
        }
        fn cond(_: *anyopaque, _: *Table, _: Allocator, _: Charge, k: CondId) Error!CondId {
            return k;
        }
    };
    var dummy: u8 = 0;
    const id: Table.Relabel = .{ .ctx = &dummy, .node = Identity.node, .cond = Identity.cond };
    var base: u32 = Ids.none_int;
    for (0..128) |k| base = try f.conds.mapPut(gpa, f.charge(), base, @intCast(k), lost.int());
    var costs: [2]u64 = undefined;
    for ([_]u32{ 16, 64 }, 0..) |m, run| {
        var below: Kappas = .none;
        for (0..m) |i| {
            const here = try f.conds.mapPut(gpa, f.charge(), base, @intCast(10_000 * (run + 1) + i), lost.int());
            const links = if (below == .none) Ids.none_int else try f.conds.mapPut(gpa, f.charge(), Ids.none_int, Place.Step.elem.word(), below.int());
            below = try f.conds.makePos(gpa, f.charge(), .{ .here = here, .links = links, .fold = 0 });
        }
        const before = f.account.total();
        try testing.expectEqual(below, try f.conds.kappaRelabel(gpa, f.charge(), below, id));
        costs[run] = f.account.total() - before;
    }
    try testing.expect(costs[1] <= 2 * costs[0]);
}

test "#1121: two growing sets merged along their tries cost their new spines" {
    // `aggMergeSets` is memoised per node pair: a pair of sets one insertion
    // larger each costs about their two changed spines, not their size.
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    f.account.allowance = 1 << 24;
    var a: SetId = .none;
    var b: SetId = .none;
    var costs: [2]u64 = .{ 0, 0 };
    for (0..512) |i| {
        a = try f.cells.sets.insert(gpa, f.charge(), a, (try f.cells.site(gpa, &f.account, @intCast(2 * i), list, .list)).int(), 0);
        b = try f.cells.sets.insert(gpa, f.charge(), b, (try f.cells.site(gpa, &f.account, @intCast(2 * i + 1), list, .list)).int(), 0);
        const before = f.account.growth;
        _ = try f.conds.aggMergeSets(gpa, f.charge(), &f.cells, &f.places, a, b);
        if (i == 63) costs[0] = f.account.growth - before;
        if (i == 511) costs[1] = f.account.growth - before;
    }
    // Eight times the cells: a few more levels, never eight times the work.
    try testing.expect(costs[1] <= 2 * costs[0] + 64);
}

test "a crossing's pair carries nothing once base_epoch moves, and a redo takes no entry a crossing made" {
    // `ownership-v2.md` §2.11 *A read in flight*: a pair `deep` made while
    // `eqOn` held is carried only within that epoch; and a read made again
    // with no crossing never answers from an entry a crossed read kept.
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    const n = try f.shapes.leaf(gpa, &f.account, list, try f.set(&.{try f.cells.site(gpa, &f.account, 1, list, .list)}));
    const region = try f.shapes.node_sets.insert(gpa, f.charge(), .none, n.int(), 0);
    const r = try f.setK(.none, n, yes);
    const pair: Table.Pair = .{ .region = region, .r = r, .epoch = f.shapes.base_epoch };
    try testing.expectEqual(r, (try f.conds.carried(gpa, f.charge(), f.view(), n, &.{pair})).?);
    // A relevant node gains a base: the epoch moves, the pair carries nothing.
    f.shapes.base_epoch += 1;
    try testing.expect(try f.conds.carried(gpa, f.charge(), f.view(), n, &.{pair}) == null);
    // An entry a crossed read kept: a read with no crossing skips it.
    const key: [3]u32 = .{ r.int(), n.int(), 0 };
    try f.conds.memoPut(gpa, .dag, key, yes.int(), true);
    try f.conds.settle(gpa, 0, true);
    try testing.expectEqual(yes.int(), f.conds.memoGet(.dag, key).?);
    f.conds.no_cross = true;
    try testing.expect(f.conds.memoGet(.dag, key) == null);
}

/// `choice(a, b)` of two lists of lists at the fixture's place 3, `a`'s
/// element a parameter's element `held`, `b`'s a fresh list `fresh`, and
/// `d`, the choice's projection at `[*]`: the joined DAG node §2.9 *Keyed
/// where a reader looks* keys, which no part of the value names.
const JoinedDag = struct { a: NodeId, b: NodeId, c: NodeId, d: NodeId, held: NodeId, fresh: NodeId };

fn joinedDag(f: *Fixture) !JoinedDag {
    const gpa = testing.allocator;
    const outer = try f.placeOf(3);
    const inner = try f.placeOf(1);
    const held = try f.leaf(1, &.{try f.param(1, 3, &.{Place.Step.elem})});
    const fresh = try f.leaf(1, &.{try f.cells.site(gpa, &f.account, 7, inner, .list)});
    const sa = try f.set(&.{try f.cells.site(gpa, &f.account, 8, outer, .list)});
    const sb = try f.set(&.{try f.cells.site(gpa, &f.account, 9, outer, .list)});
    const a = try f.shapes.node(gpa, &f.account, outer, sa, try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, held));
    const b = try f.shapes.node(gpa, &f.account, outer, sb, try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, fresh));
    const c = try f.shapes.choice(gpa, &f.account, &f.cells.sets, a, b);
    return .{ .a = a, .b = b, .c = c, .d = try f.projOf(c, Place.Step.elem), .held = held, .fresh = fresh };
}

test "#1406: a side no member holds reads the join's κ joined with its derivation, never stronger" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const j = try joinedDag(&f);
    try testing.expectEqual(Shape.Kind.choice, f.shapes.kind(j.d));
    const elem = &[_]Place.Step{Place.Step.elem};
    // The join's κ at `[*]` (a member stored `shared` there), keyed on `d`
    // alone, as `propagate` keys it.
    const ctx = try f.setKPath(.none, elem, j.d, shared);
    // Alone, `fresh` reads its derivation, `yes`: stronger than the join's.
    try testing.expectEqual(yes, try f.kappaPath(ctx, elem, j.fresh, true));
    // No reader meets it alone. An in-walk reader projects the value and
    // meets `d`, whose read joins its entry with its sides' reads.
    const at = f.conds.kappaAlong(ctx, elem);
    const k = try f.kappa(at, try f.projOf(j.c, Place.Step.elem), true);
    try testing.expect(try f.conds.leq(testing.allocator, f.charge(), shared, k));
    try testing.expectEqual(shared, k);
}

/// A relabelling `Shape.map` made, as read-off carries it (`Walk.Carry`):
/// each entry's node its image, and a DAG a projection made the projection
/// of its origin's image when `with_projection` (§2.9 *Keyed where a reader
/// looks*).
const MapCarry = struct {
    f: *Fixture,
    memo: Ids.FixedDict(1) = .{},
    with_projection: bool,

    fn node(ctx: *anyopaque, x: NodeId) Error!?NodeId {
        const c: *MapCarry = @ptrCast(@alignCast(ctx));
        return c.f.shapes.memo_map.get(x);
    }
    fn projected(ctx: *anyopaque, x: NodeId) Error!?NodeId {
        const c: *MapCarry = @ptrCast(@alignCast(ctx));
        if (!c.with_projection) return null;
        return projectedImage(&c.f.shapes, testing.allocator, &c.f.account, &c.f.places, &c.f.cells, x, &c.memo, ctx, node, true);
    }
    fn cond(_: *anyopaque, _: *Table, _: Allocator, _: Charge, k: CondId) Error!CondId {
        return k;
    }
};

test "a transport carries a built node's, a choice's and a leaf's κ to their images, and a join's to the projection of its origin's image" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const j = try joinedDag(&f);
    const elem = &[_]Place.Step{Place.Step.elem};
    // κ on each kind at its own position, and the join's on `d` at `[*]`:
    // a built node (`a`), a choice (`c`), a leaf (`held`), the joined DAG.
    var ctx = try f.setK(.none, j.c, yes);
    ctx = try f.setK(ctx, j.a, yes);
    ctx = try f.setKPath(ctx, elem, j.held, lost);
    ctx = try f.setKPath(ctx, elem, j.d, shared);
    // `map` renames the parameter, so every image is a new node.
    const Rename = struct {
        fn cells(fx: *Fixture, s: SetId) Error!SetId {
            var out: SetId = .none;
            var it = fx.cells.sets.iterate(s);
            while (it.next()) |e| {
                const c: CellId = .from(e.key);
                const img = if (fx.cells.origin(c) == .param) try fx.param(2, 3, &.{Place.Step.elem}) else c;
                out = try fx.cells.sets.insert(testing.allocator, fx.charge(), out, img.int(), e.value);
            }
            return out;
        }
    };
    const mapped = try f.shapes.map(gpa, &f.account, j.c, &f, Rename.cells);
    try testing.expect(mapped != j.c);
    const md = try f.projOf(mapped, Place.Step.elem);
    for ([_]bool{ false, true }) |with| {
        var carry: MapCarry = .{ .f = &f, .with_projection = with };
        defer carry.memo.deinit(gpa);
        const out = try f.conds.kappaRelabel(gpa, f.charge(), ctx, .{ .ctx = &carry, .node = MapCarry.node, .cond = MapCarry.cond, .projected = MapCarry.projected });
        // The entries of nodes the map met follow their images.
        try testing.expect(f.conds.kappaGet(out, f.shapes.memo_map.get(j.a).?) != null);
        try testing.expectEqual(lost, f.conds.kappaGet(f.conds.kappaAlong(out, elem), f.shapes.memo_map.get(j.held).?).?);
        // The join's, on a node the map never met, only by the correspondence:
        // without it the image of `[*]` reads its sides alone, `lost`.
        const got = f.conds.kappaGet(f.conds.kappaAlong(out, elem), md);
        if (with) try testing.expectEqual(shared, got.?) else try testing.expectEqual(@as(?CondId, null), got);
        try testing.expectEqual(if (with) shared else lost, try f.kappa(f.conds.kappaAlong(out, elem), md, true));
    }
}

test "a view of a joined DAG projects to the view of its template's projection, where a call keys the join's κ" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const j = try joinedDag(&f);
    const arg = try f.leaf(3, &.{try f.cells.site(gpa, &f.account, 1, try f.placeOf(3), .list)});
    var ti: Shape.TestInstantiation = .{ .cellt = &f.cells, .arg = arg, .places = &f.places };
    f.shapes.instantiation = ti.inst();
    const v = try f.shapes.view(gpa, &f.account, j.c, 0);
    // A caller projects the call's view: it meets the view of `d`, the node
    // `Calls.apply` relabels the class's entry on `d` onto.
    const pv = try f.projOf(v, Place.Step.elem);
    try testing.expectEqual(try f.shapes.view(gpa, &f.account, j.d, 0), pv);
    const ctx = try f.setKPath(.none, &.{Place.Step.elem}, pv, shared);
    try testing.expectEqual(shared, try f.kappaPath(ctx, &.{Place.Step.elem}, pv, true));
}

test "#1093: a join of two built records, their snapshots merged first, reads the members' join" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const j = try joinedDag(&f);
    // Each member certifies its own record (κ `yes` at its root).
    const ka = try f.setK(.none, j.a, yes);
    const kb = try f.setK(.none, j.b, yes);
    const members = [_]NodeId{ j.a, j.b };
    // From nothing (`Summary.joinRes` before #1447), the sides keep no
    // certificate, and the join reads `lost` at its root.
    const bare = try f.propagate(.none, j.c, &members, &.{ ka, kb }, .alternatives, false);
    try testing.expectEqual(lost, try f.kappa(bare, j.c, false));
    // Merged first, as every join of alternatives now starts: each side reads
    // its member's certificate, and the join reads the members' join.
    const merged = try f.propagate(try f.conds.kappaMerge(gpa, f.charge(), ka, kb), j.c, &members, &.{ ka, kb }, .alternatives, false);
    try testing.expectEqual(yes, try f.kappa(merged, j.c, false));
    for (members, [_]Kappas{ ka, kb }) |m, km| try testing.expect(try f.conds.kappaLeq(gpa, f.charge(), f.view(), km, m, merged, j.c, false));
}

test "a class join keeps a join entry its sides' merged certificates would make stronger (#1459's review)" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const j = try joinedDag(&f);
    // `x = a`, `u = union(a, b)`, `joined = choice(x, u)`. `ka` certifies
    // `x`; `kb` only `b`, so `u` reads `lost` (its `a` has no certificate
    // there). The members' snapshots merged give `a` `ka`'s certificate, so
    // the sides alone would read `yes`: the shape says nothing of reads.
    const x = j.a;
    const u = try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, j.a, j.b);
    const joined = try f.shapes.choice(gpa, &f.account, &f.cells.sets, x, u);
    const ka = try f.setK(.none, x, yes);
    const kb = try f.setK(.none, j.b, yes);
    try testing.expectEqual(lost, try f.kappa(kb, u, false));
    const merged = try f.conds.kappaMerge(gpa, f.charge(), ka, kb);
    const out = try f.propagate(merged, joined, &.{ x, u }, &.{ ka, kb }, .alternatives, false);
    try testing.expectEqual(lost, try f.kappa(out, joined, false));
}
