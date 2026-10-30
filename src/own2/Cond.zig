//! L4: conditions, the exclusivity κ of a value's contents
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
//! Obligations kept here: O13 (a construction's κ is `yes` only when the
//! stored cells are pairwise apart at that path; a stored refinement of the
//! base's own `[*]` is `shared`), O15 (κ(join) is below every member's; a
//! union's κ is its sides' join, derived and never stale).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Cell = @import("Cell.zig");
const Shape = @import("Shape.zig");
const stamped = @import("../stamped.zig");
pub const full_cross_check = @import("ownership_options").full_cross_check;

pub const CondId = Ids.CondId;
pub const CellId = Ids.CellId;
pub const SetId = Ids.SetId;
pub const NodeId = Ids.NodeId;
pub const LabelId = Ids.LabelId;
pub const Charge = Ids.Charge;
pub const Error = Ids.ChargeError;
pub const Exactness = Facts.Exactness;
pub const Step = Shape.Step;

pub const Kind = enum(u8) { yes, @"and", atom, shared, lost };

pub const AtomKind = enum(u8) { excl, sep, within, apart, keep, writes, inst };

/// One condition (§3.4). `a`, `b` by kind: `and`: two conditions; `atom`:
/// `excl`: a cell; `sep`: two cells (the smaller id first); `within`: a
/// label; `apart`: a persistent set of cells; `keep`/`writes`: a function
/// parameter index.
pub const Cond = struct {
    kind: Kind,
    atom: AtomKind,
    a: u32,
    b: u32,
};

/// The three constants, in every table at these ids (`init`).
pub const yes: CondId = .from(0);
pub const shared: CondId = .from(1);
pub const lost: CondId = .from(2);

/// A holder's κ snapshot: the root of a persistent map, `.none` when empty.
pub const Kappas = Ids.KappaId;

/// A κ map node: a leaf (`mask == 0`: `prefix` the key, `left` the
/// condition) or a branch; hash-consed, so equal maps are one root.
pub const MapNode = struct { prefix: u32, mask: u32, left: u32, right: u32 };

/// S4's answer for two `taken` elements of one container from distinct
/// splits (§2.2, *Traversals*): apart under the container's κ when both are
/// `single` and of one entry prefix, else null (`lost`).
pub const Traversal = struct { ctx: *anyopaque, apart: *const fn (ctx: *anyopaque, container: CellId, a: CellId, b: CellId) ?CondId };

/// A caller's interpretation of one atom at a call (§2.9): `excl c` the
/// argument's deep condition at `c`'s path, `sep`/`apart` the arrivals'
/// cells compared AT THAT PATH, `keep`/`writes` the actual's facts,
/// `within` and a label `sep` §2.11 item 5's instantiation.
pub const Interp = struct { ctx: *anyopaque, atom: *const fn (ctx: *anyopaque, t: *Table, gpa: Allocator, charge: Charge, atom: Cond) Error!CondId };

/// How a cell and a label print, the layer above's (`Summary`).
pub const Printer = struct {
    ctx: *anyopaque,
    cell: *const fn (ctx: *anyopaque, w: *std.Io.Writer, c: CellId) std.Io.Writer.Error!void,
    label: *const fn (ctx: *anyopaque, w: *std.Io.Writer, l: LabelId) std.Io.Writer.Error!void,
};

/// `rely`'s answer (§2.9): nothing, the atoms (the class's `xreq`), a refusal.
pub const Rely = union(enum) { ok, xreq: SetId, refused: Exactness };

/// How `propagate` reads a joined node's members: a branch (the lattice
/// join, O15) or a summary position holding every member (`apart` across
/// their cells at every path, and every member's κ).
pub const Mode = enum(u8) { alternatives, together };

/// The tables `kappaOf` and its callers read; passed down, never stored.
pub const View = struct { shapes: *Shape.Table, cells: *Cell.Table, places: *Cell.Places };

/// One stored cell of a construction, with its pair's approximation.
pub const Item = struct { cell: CellId, approx: bool };

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
    crossed_reads: u32 = 0,
    crossed_redos: u32 = 0,
    /// For tests: every position a reader (`deep`, `propagate`,
    /// `kappaLeq`) reads, as `node << 1 | class`, so a test can compare
    /// the frontiers they walk.
    trace: ?*std.ArrayList(u32) = null,

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
        t.memo_prop.deinit(gpa);
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

    pub fn count(t: *const Table) u32 {
        return @intCast(t.conds.len);
    }

    pub fn get(t: *const Table, c: CondId) Cond {
        return t.conds.get(c.int());
    }

    pub fn kind(t: *const Table, c: CondId) Kind {
        return t.conds.items(.kind)[c.int()];
    }

    /// Whether `c` fails (`shared` or `lost`).
    pub fn fails(c: CondId) bool {
        return c == shared or c == lost;
    }

    /// Reserved before the dictionary is touched, hit or miss (§4.1).
    fn make(t: *Table, gpa: Allocator, charge: Charge, c: Cond) Error!CondId {
        try charge.reserve(gpa, .cond, 1);
        const got = try t.intern.getOrPut(gpa, .{ key0(c), c.a, c.b });
        if (got.found_existing) return .from(got.value_ptr.*);
        got.value_ptr.* = @intCast(t.conds.len);
        try t.conds.append(gpa, c);
        return .from(got.value_ptr.*);
    }

    fn key0(c: Cond) u32 {
        return (@as(u32, @backingInt(c.kind)) << 8) | @backingInt(c.atom);
    }

    /// The id of `c` if it exists, without making it. One inspection.
    fn find(t: *Table, gpa: Allocator, charge: Charge, c: Cond) Error!?CondId {
        try charge.reserve(gpa, .inspection, 1);
        return if (t.intern.get(.{ key0(c), c.a, c.b })) |hit| .from(hit) else null;
    }

    // ---- forming -----------------------------------------------------------

    /// `a ∧ b`, O(1): a failure absorbs (`shared` over `lost`), `yes` is the
    /// unit, the pair is interned in id order so `and(a, b) = and(b, a)`.
    pub fn @"and"(t: *Table, gpa: Allocator, charge: Charge, a: CondId, b: CondId) Error!CondId {
        if (a == b) return a;
        if (a == shared or b == shared) return shared;
        if (a == lost or b == lost) return lost;
        if (a == yes) return b;
        if (b == yes) return a;
        return t.make(gpa, charge, .{ .kind = .@"and", .atom = .excl, .a = @min(a.int(), b.int()), .b = @max(a.int(), b.int()) });
    }

    pub fn excl(t: *Table, gpa: Allocator, charge: Charge, c: CellId) Error!CondId {
        return t.make(gpa, charge, .{ .kind = .atom, .atom = .excl, .a = c.int(), .b = 0 });
    }

    /// The atom `sep a b` (two arrivals apart at this path), unordered.
    pub fn sepAtom(t: *Table, gpa: Allocator, charge: Charge, a: CellId, b: CellId) Error!CondId {
        std.debug.assert(a != b);
        return t.make(gpa, charge, .{ .kind = .atom, .atom = .sep, .a = @min(a.int(), b.int()), .b = @max(a.int(), b.int()) });
    }

    pub fn within(t: *Table, gpa: Allocator, charge: Charge, l: LabelId) Error!CondId {
        return t.make(gpa, charge, .{ .kind = .atom, .atom = .within, .a = l.int(), .b = 0 });
    }

    /// `apart{S}` over a persistent set of cells (in `Cell.Table.sets`).
    pub fn apartAtom(t: *Table, gpa: Allocator, charge: Charge, group: SetId) Error!CondId {
        return t.make(gpa, charge, .{ .kind = .atom, .atom = .apart, .a = group.int(), .b = 0 });
    }

    pub fn keep(t: *Table, gpa: Allocator, charge: Charge, j: u32) Error!CondId {
        return t.make(gpa, charge, .{ .kind = .atom, .atom = .keep, .a = j, .b = 0 });
    }

    pub fn writes(t: *Table, gpa: Allocator, charge: Charge, j: u32) Error!CondId {
        return t.make(gpa, charge, .{ .kind = .atom, .atom = .writes, .a = j, .b = 0 });
    }

    // ---- flattening and the lattice ------------------------------------------

    /// The atom set of `c` (not a failure): `.none` for `yes`, else the
    /// persistent set of its atoms. An `and` tree is walked once on an
    /// explicit stack, every inner node memoised: W stores flatten in
    /// O(W log W) once, their prefixes shared.
    pub fn flat(t: *Table, gpa: Allocator, charge: Charge, c: CondId) Error!SetId {
        std.debug.assert(!fails(c));
        if (c == yes) return .none;
        // Reserved before the memo is read, a hit too (§2.3 *Memo safety*, #1124).
        try charge.reserve(gpa, .memo, 1);
        if (t.flat_memo.get(c)) |s| return s;
        var stack: std.ArrayList(CondId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, c);
        while (stack.items.len > 0) {
            const x = stack.items[stack.items.len - 1];
            if (t.flat_memo.contains(x)) {
                _ = stack.pop();
                continue;
            }
            try charge.reserve(gpa, .inspection, 1);
            if (x == yes) {
                try t.flat_memo.put(gpa, x, .none);
                _ = stack.pop();
                continue;
            }
            const d = t.get(x);
            if (d.kind == .atom) {
                try t.flat_memo.put(gpa, x, try t.atoms.insert(gpa, charge, .none, x.int(), 0));
                _ = stack.pop();
                continue;
            }
            std.debug.assert(d.kind == .@"and");
            const l: CondId = .from(d.a);
            const r: CondId = .from(d.b);
            const fl = t.flat_memo.get(l);
            const fr = t.flat_memo.get(r);
            if (fl != null and fr != null) {
                try t.flat_memo.put(gpa, x, try t.atoms.unionWith(gpa, charge, fl.?, fr.?));
                _ = stack.pop();
                continue;
            }
            if (fl == null) try stack.append(gpa, l);
            if (fr == null) try stack.append(gpa, r);
        }
        return t.flat_memo.get(c).?;
    }

    /// The canonical condition of an atom set: the `and` tree of its
    /// persistent set's own trie (a branch the `and` of its two sides'),
    /// one id per set (memoised per trie node), so a fixpoint's `join` is
    /// idempotent (§2.12) and a set one insertion larger builds only its
    /// new spine (§2.9, #1121): O(log |S|), never a chain of all its atoms.
    pub fn ofSet(t: *Table, gpa: Allocator, charge: Charge, s: SetId) Error!CondId {
        if (s == .none) return yes;
        if (t.of_set.get(.{s.int()})) |hit| return .from(hit);
        var stack: std.ArrayList(SetId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, s);
        while (stack.items.len > 0) {
            const x = stack.items[stack.items.len - 1];
            if (t.of_set.get(.{x.int()}) != null) {
                _ = stack.pop();
                continue;
            }
            try charge.reserve(gpa, .inspection, 1);
            const acc: CondId = if (t.atoms.branches(x)) |kids| blk: {
                const l = t.of_set.get(.{kids[0].int()});
                const r = t.of_set.get(.{kids[1].int()});
                if (l == null or r == null) {
                    if (l == null) try stack.append(gpa, kids[0]);
                    if (r == null) try stack.append(gpa, kids[1]);
                    continue;
                }
                break :blk try t.@"and"(gpa, charge, .from(l.?), .from(r.?));
            } else blk: {
                var it = t.atoms.iterate(x);
                break :blk .from(it.next().?.key);
            };
            (try t.of_set.getOrPut(gpa, .{x.int()})).value_ptr.* = acc.int();
            if (!t.flat_memo.contains(acc)) try t.flat_memo.put(gpa, acc, x);
            _ = stack.pop();
        }
        return .from(t.of_set.get(.{s.int()}).?);
    }

    /// The lattice join (§2.10): `shared` wins, then `lost`, else the
    /// canonical form of the union of the atom sets. `join(a, a) = a`.
    pub fn join(t: *Table, gpa: Allocator, charge: Charge, a: CondId, b: CondId) Error!CondId {
        if (a == b) return a;
        if (a == shared or b == shared) return shared;
        if (a == lost or b == lost) return lost;
        if (a == yes) return t.ofSet(gpa, charge, try t.flat(gpa, charge, b));
        if (b == yes) return t.ofSet(gpa, charge, try t.flat(gpa, charge, a));
        const fa = try t.flat(gpa, charge, a);
        const fb = try t.flat(gpa, charge, b);
        return t.ofSet(gpa, charge, try t.atoms.unionWith(gpa, charge, fa, fb));
    }

    /// `a ⊑ b` in the lattice `yes ⊑ and{A} ⊑ and{A ∪ B} ⊑ lost ⊑ shared`.
    pub fn leq(t: *Table, gpa: Allocator, charge: Charge, a0: CondId, b0: CondId) Error!bool {
        // A fixpoint compares resolved conditions: an `inst` atom made at one
        // round need not repeat at the next.
        const a = try t.resolved(gpa, charge, a0);
        const b = try t.resolved(gpa, charge, b0);
        if (a == b or a == yes or b == shared) return true;
        if (a == shared) return false;
        if (b == lost) return true;
        if (a == lost) return false;
        if (b == yes) return false;
        return t.atoms.subset(gpa, charge, try t.flat(gpa, charge, a), try t.flat(gpa, charge, b));
    }

    // ---- the κ snapshots ----------------------------------------------------
    //
    // A snapshot (§2.9, §3.4) is a trie of POSITIONS: a position stores
    // conditions by node (`here`, a radix map NodeId → CondId) and links
    // one step below (`links`, a radix map step word → Kappas). Paths are
    // the steps a read takes from the root of the snapshot that stores
    // them; a construction links its children's snapshots, never re-keyed.
    // A FOLD (`widen`'s, §2.9) is a position whose links lead back to
    // itself, its conditions keyed by node alone for every level below.

    fn mapNode(t: *const Table, id: u32) MapNode {
        return t.kmaps.get(id);
    }

    /// One map node, interned; reserved before the dictionary is touched.
    fn makeMap(t: *Table, gpa: Allocator, charge: Charge, n: MapNode) Error!u32 {
        try charge.reserve(gpa, .cond, 1);
        const got = try t.kmap_intern.getOrPut(gpa, .{ n.prefix, n.mask, n.left, n.right });
        if (got.found_existing) return got.value_ptr.*;
        got.value_ptr.* = @intCast(t.kmaps.len);
        try t.kmaps.append(gpa, n);
        return got.value_ptr.*;
    }

    inline fn matches(key: u32, prefix: u32, mask: u32) bool {
        return (key & ~((mask << 1) -% 1)) == prefix;
    }

    fn mapJoin(t: *Table, gpa: Allocator, charge: Charge, p0: u32, t0: u32, p1: u32, t1: u32) Error!u32 {
        const mask = @as(u32, 1) << @intCast(31 - @clz(p0 ^ p1));
        const prefix = p0 & ~((mask << 1) -% 1);
        return if (p0 & mask == 0)
            t.makeMap(gpa, charge, .{ .prefix = prefix, .mask = mask, .left = t0, .right = t1 })
        else
            t.makeMap(gpa, charge, .{ .prefix = prefix, .mask = mask, .left = t1, .right = t0 });
    }

    /// The value at `key`, or null. O(min(32, depth)) reads.
    fn mapGet(t: *const Table, root: u32, key: u32) ?u32 {
        var at = root;
        while (at != Ids.none_int) {
            const m = t.mapNode(at);
            if (m.mask == 0) return if (m.prefix == key) m.left else null;
            if (!matches(key, m.prefix, m.mask)) return null;
            at = if (key & m.mask == 0) m.left else m.right;
        }
        return null;
    }

    /// `root` with `key ↦ v` (replacing), path-copied: ≤ 33 records.
    fn mapPut(t: *Table, gpa: Allocator, charge: Charge, root: u32, key: u32, v: u32) Error!u32 {
        if (root == Ids.none_int) return t.makeMap(gpa, charge, .{ .prefix = key, .mask = 0, .left = v, .right = Ids.none_int });
        const m = t.mapNode(root);
        if (m.mask == 0) {
            if (m.prefix == key) return if (m.left == v) root else t.makeMap(gpa, charge, .{ .prefix = key, .mask = 0, .left = v, .right = Ids.none_int });
            const leaf = try t.makeMap(gpa, charge, .{ .prefix = key, .mask = 0, .left = v, .right = Ids.none_int });
            return t.mapJoin(gpa, charge, key, leaf, m.prefix, root);
        }
        if (!matches(key, m.prefix, m.mask)) {
            const leaf = try t.makeMap(gpa, charge, .{ .prefix = key, .mask = 0, .left = v, .right = Ids.none_int });
            return t.mapJoin(gpa, charge, key, leaf, m.prefix, root);
        }
        if (key & m.mask == 0) {
            const l = try t.mapPut(gpa, charge, m.left, key, v);
            return if (l == m.left) root else t.makeMap(gpa, charge, .{ .prefix = m.prefix, .mask = m.mask, .left = l, .right = m.right });
        }
        const r = try t.mapPut(gpa, charge, m.right, key, v);
        return if (r == m.right) root else t.makeMap(gpa, charge, .{ .prefix = m.prefix, .mask = m.mask, .left = m.left, .right = r });
    }

    /// How two values bound to one key combine in a union: conditions by
    /// the lattice join, links by merging the two positions below.
    const Combine = enum { cond, link };

    fn combine(t: *Table, gpa: Allocator, charge: Charge, how: Combine, x: u32, y: u32) Error!u32 {
        if (x == y) return x;
        return switch (how) {
            .cond => (try t.join(gpa, charge, .from(x), .from(y))).int(),
            .link => (try t.kappaMerge(gpa, charge, .from(x), .from(y))).int(),
        };
    }

    /// The union of two maps, a key both bind combined (`how`). Persistent:
    /// `a` when `b` adds nothing. Every node pair inspected is a record; the
    /// recursion is the key width, 33 frames.
    fn mapUnion(t: *Table, gpa: Allocator, charge: Charge, how: Combine, a: u32, b: u32) Error!u32 {
        if (a == Ids.none_int) return b;
        if (b == Ids.none_int or a == b) return a;
        // Memoised per pair of map nodes and `Combine` (*Argument 2*): the union
        // of two maps that both grew meets, below their changed spines, the
        // pairs an earlier union met.
        const key: [3]u32 = .{ @backingInt(how), a, b };
        try charge.reserve(gpa, .memo, 1);
        if (t.memo_map_union.get(key)) |hit| return hit;
        const out = try t.mapUnionUncached(gpa, charge, how, a, b);
        (try t.memo_map_union.getOrPut(gpa, key)).value_ptr.* = out;
        return out;
    }

    fn mapUnionUncached(t: *Table, gpa: Allocator, charge: Charge, how: Combine, a: u32, b: u32) Error!u32 {
        try charge.reserve(gpa, .inspection, 1);
        const na = t.mapNode(a);
        const nb = t.mapNode(b);
        if (nb.mask == 0) {
            const old = t.mapGet(a, nb.prefix);
            const v = if (old) |o| try t.combine(gpa, charge, how, o, nb.left) else nb.left;
            if (old != null and old.? == v) return a;
            return t.mapPut(gpa, charge, a, nb.prefix, v);
        }
        if (na.mask == 0) {
            const old = t.mapGet(b, na.prefix);
            const v = if (old) |o| try t.combine(gpa, charge, how, na.left, o) else na.left;
            if (old != null and old.? == v) return b;
            return t.mapPut(gpa, charge, b, na.prefix, v);
        }
        if (na.mask == nb.mask and na.prefix == nb.prefix) {
            const l = try t.mapUnion(gpa, charge, how, na.left, nb.left);
            const r = try t.mapUnion(gpa, charge, how, na.right, nb.right);
            if (l == na.left and r == na.right) return a;
            if (l == nb.left and r == nb.right) return b;
            return t.makeMap(gpa, charge, .{ .prefix = na.prefix, .mask = na.mask, .left = l, .right = r });
        }
        if (na.mask > nb.mask and matches(nb.prefix, na.prefix, na.mask)) {
            if (nb.prefix & na.mask == 0) {
                const l = try t.mapUnion(gpa, charge, how, na.left, b);
                return if (l == na.left) a else t.makeMap(gpa, charge, .{ .prefix = na.prefix, .mask = na.mask, .left = l, .right = na.right });
            }
            const r = try t.mapUnion(gpa, charge, how, na.right, b);
            return if (r == na.right) a else t.makeMap(gpa, charge, .{ .prefix = na.prefix, .mask = na.mask, .left = na.left, .right = r });
        }
        if (nb.mask > na.mask and matches(na.prefix, nb.prefix, nb.mask)) {
            if (na.prefix & nb.mask == 0) {
                const l = try t.mapUnion(gpa, charge, how, a, nb.left);
                return if (l == nb.left) b else t.makeMap(gpa, charge, .{ .prefix = nb.prefix, .mask = nb.mask, .left = l, .right = nb.right });
            }
            const r = try t.mapUnion(gpa, charge, how, a, nb.right);
            return if (r == nb.right) b else t.makeMap(gpa, charge, .{ .prefix = nb.prefix, .mask = nb.mask, .left = nb.left, .right = r });
        }
        return t.mapJoin(gpa, charge, na.prefix, a, nb.prefix, b);
    }

    /// The `(key, value)` entries of a map in key order: a leaf walk on a
    /// stack of at most 34 entries. Iterating a whole map is the caller's
    /// charged task (§4.1).
    pub const MapIterator = struct {
        t: *const Table,
        stack: [34]u32 = undefined,
        depth: usize = 0,

        pub const Entry = struct { key: u32, value: u32 };

        pub fn next(it: *MapIterator) ?Entry {
            while (it.depth > 0) {
                it.depth -= 1;
                const m = it.t.mapNode(it.stack[it.depth]);
                if (m.mask == 0) return .{ .key = m.prefix, .value = m.left };
                it.stack[it.depth] = m.right;
                it.stack[it.depth + 1] = m.left;
                it.depth += 2;
            }
            return null;
        }
    };

    fn mapEntries(t: *const Table, root: u32) MapIterator {
        var it: MapIterator = .{ .t = t };
        if (root != Ids.none_int) {
            it.stack[0] = root;
            it.depth = 1;
        }
        return it;
    }

    /// One position of a snapshot, hash-consed: equal snapshots are one root.
    pub const Position = struct { here: u32, links: u32, fold: u32 };

    comptime {
        Ids.assertRecord(Position);
    }

    pub fn position(t: *const Table, ctx: Kappas) Position {
        if (ctx == .none) return .{ .here = Ids.none_int, .links = Ids.none_int, .fold = 0 };
        return t.kpos.get(ctx.int());
    }

    /// A position, interned (`.none` when it stores and links nothing and is
    /// no fold); reserved before the dictionary is touched.
    fn makePos(t: *Table, gpa: Allocator, charge: Charge, p: Position) Error!Kappas {
        if (p.here == Ids.none_int and p.links == Ids.none_int and p.fold == 0) return .none;
        try charge.reserve(gpa, .cond, 1);
        const got = try t.kpos_intern.getOrPut(gpa, .{ p.here, p.links, p.fold });
        if (got.found_existing) return .from(got.value_ptr.*);
        got.value_ptr.* = @intCast(t.kpos.len);
        try t.kpos.append(gpa, p);
        return .from(got.value_ptr.*);
    }

    /// κ stored for `n` at the position `ctx`, or null.
    pub fn kappaGet(t: *const Table, ctx: Kappas, n: NodeId) ?CondId {
        if (ctx == .none) return null;
        return if (t.mapGet(t.position(ctx).here, n.int())) |v| CondId.from(v) else null;
    }

    /// The position one step `s` below `ctx`: its link, `.none` without one;
    /// a fold is its own position at every step below (§2.9).
    pub fn kappaChild(t: *const Table, ctx: Kappas, s: Step) Kappas {
        if (ctx == .none) return .none;
        const p = t.position(ctx);
        if (p.fold != 0) return ctx;
        return if (t.mapGet(p.links, s.word())) |v| Kappas.from(v) else .none;
    }

    /// The position along `along` from `ctx`.
    pub fn kappaAlong(t: *const Table, ctx: Kappas, along: []const Step) Kappas {
        var at = ctx;
        for (along) |s| {
            if (at == .none) return .none;
            at = t.kappaChild(at, s);
        }
        return at;
    }

    pub fn isFold(t: *const Table, ctx: Kappas) bool {
        return ctx != .none and t.position(ctx).fold != 0;
    }

    /// A fold made by collapsing a snapshot (`kappaFold`), not by
    /// `propagate`'s walk: a built node or a delta absent at one of the
    /// positions it covered read `lost` there, and the collapse cannot tell
    /// which, so it reads `lost` (§2.9).
    pub fn isCollapsed(t: *const Table, ctx: Kappas) bool {
        return ctx != .none and t.position(ctx).fold == fold_collapsed;
    }

    /// `Position.fold`: an exact fold (`propagate` stores every built node
    /// it walks) or a collapsed one.
    pub const fold_exact: u32 = 1;
    pub const fold_collapsed: u32 = 2;

    pub const Set = struct { ctx: Kappas, changed: bool };

    /// `ctx` with κ(n) at this position joined with `k` (monotone, §2.12):
    /// the new root and whether κ(n) changed; the same root when not.
    /// `n` became a κ key: relevant to the crossing's `base_epoch` (*Bases*).
    fn keyed(t: *Table, gpa: Allocator, charge: Charge, n: NodeId) Error!void {
        if (t.shapes_hook) |s| try s.markRelevant(gpa, charge.account, n);
    }

    pub fn kappaSet(t: *Table, gpa: Allocator, charge: Charge, ctx: Kappas, n: NodeId, k: CondId) Error!Set {
        const old = t.kappaGet(ctx, n);
        const new = if (old) |o| try t.join(gpa, charge, o, k) else k;
        if (old) |o| if (o == new) return .{ .ctx = ctx, .changed = false };
        const p = t.position(ctx);
        try t.keyed(gpa, charge, n);
        return .{ .ctx = try t.makePos(gpa, charge, .{ .here = try t.mapPut(gpa, charge, p.here, n.int(), new.int()), .links = p.links, .fold = p.fold }), .changed = true };
    }

    /// What `kappaAt` does at the position its path reaches.
    pub const PathOp = union(enum) { set: struct { node: NodeId, k: CondId }, merge: Kappas, fold };

    /// `root` with `op` done at the position along `along`, path-copied: a
    /// record per step; a fold on the way is the rest of the path itself.
    pub fn kappaAt(t: *Table, gpa: Allocator, charge: Charge, root: Kappas, along: []const Step, op: PathOp) Error!Kappas {
        // Down the path on an explicit stack (#1130: a path's length is the
        // source's depth, never native-stack depth), to its end or a fold.
        var way: std.ArrayList(Kappas) = .empty;
        defer way.deinit(gpa);
        var at = root;
        var i: usize = 0;
        while (i < along.len and !t.isFold(at)) : (i += 1) {
            try charge.reserve(gpa, .inspection, 1);
            try way.append(gpa, at);
            at = t.kappaChild(at, along[i]);
        }
        var out = switch (op) {
            .set => |s| (try t.kappaSet(gpa, charge, at, s.node, s.k)).ctx,
            .merge => |sub| try t.kappaMerge(gpa, charge, at, sub),
            .fold => if (t.isFold(at)) at else try t.kappaFold(gpa, charge, at),
        };
        // Back up, each position with its link replaced.
        while (way.pop()) |up| {
            i -= 1;
            out = try t.withLink(gpa, charge, up, along[i], out);
        }
        return out;
    }

    /// `kappaAt` setting κ(n) to `k` joined.
    pub fn kappaSetAt(t: *Table, gpa: Allocator, charge: Charge, root: Kappas, along: []const Step, n: NodeId, k: CondId) Error!Kappas {
        return t.kappaAt(gpa, charge, root, along, .{ .set = .{ .node = n, .k = k } });
    }

    /// `ctx` with its link at `s` replaced by `child`.
    pub fn withLink(t: *Table, gpa: Allocator, charge: Charge, ctx: Kappas, s: Step, child: Kappas) Error!Kappas {
        const p = t.position(ctx);
        std.debug.assert(p.fold == 0);
        if (t.kappaChild(ctx, s) == child) return ctx;
        const links = if (child == .none) p.links else try t.mapPut(gpa, charge, p.links, s.word(), child.int());
        return t.makePos(gpa, charge, .{ .here = p.here, .links = links, .fold = 0 });
    }

    /// `ctx` with `child` linked one step `s` below (§2.9: a construction
    /// links each child's snapshot under its step, never re-keyed); a link
    /// there already is merged with it. One record when the step is new.
    pub fn kappaLink(t: *Table, gpa: Allocator, charge: Charge, ctx: Kappas, s: Step, child: Kappas) Error!Kappas {
        if (child == .none) return ctx;
        if (t.isFold(ctx)) return t.kappaMerge(gpa, charge, ctx, child);
        const old = t.kappaChild(ctx, s);
        return t.withLink(gpa, charge, ctx, s, if (old == .none) child else try t.kappaMerge(gpa, charge, old, child));
    }

    /// Two snapshots combined (§2.9: a construction combines its children's
    /// snapshots and joins them where they bind one key): at each position
    /// the union of what both store, a node both bind joined, the links
    /// merged below. A fold takes the other side folded into it; two exact
    /// folds stay exact (each stores every built node of its own), anything
    /// collapsed into one is collapsed. `a` when `b` adds nothing.
    /// Memoised per unordered pair (§2.9): positions are immutable and
    /// interned by content, so a pair always merges to one position.
    pub fn kappaMerge(t: *Table, gpa: Allocator, charge: Charge, a: Kappas, b: Kappas) Error!Kappas {
        if (a == .none) return b;
        if (b == .none or a == b) return a;
        const mkey: [2]u32 = .{ @min(a.int(), b.int()), @max(a.int(), b.int()) };
        try charge.reserve(gpa, .memo, 1);
        if (t.memo_merge.get(mkey)) |hit| return .from(hit);
        // The pairs below that both sides link merge first, on an explicit
        // stack (#1130: a snapshot's depth is the source's, never native-
        // stack depth); each pair is memoised once complete, so a position's
        // links then find their children merged.
        const Frame = struct { a: Kappas, b: Kappas, expanded: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, .{ .a = a, .b = b, .expanded = false });
        while (stack.pop()) |f| {
            const key: [2]u32 = .{ @min(f.a.int(), f.b.int()), @max(f.a.int(), f.b.int()) };
            if (!f.expanded) {
                try charge.reserve(gpa, .memo, 1);
                if (t.memo_merge.get(key) != null) continue;
                try stack.append(gpa, .{ .a = f.a, .b = f.b, .expanded = true });
                const pa = t.position(f.a);
                const pb = t.position(f.b);
                if (pa.fold != 0 or pb.fold != 0) continue;
                var lt = t.mapEntries(pa.links);
                while (lt.next()) |e| {
                    try charge.reserve(gpa, .inspection, 1);
                    const y: Kappas = .from(t.mapGet(pb.links, e.key) orelse continue);
                    const x: Kappas = .from(e.value);
                    if (x != y) try stack.append(gpa, .{ .a = x, .b = y, .expanded = false });
                }
                continue;
            }
            if (t.memo_merge.get(key) != null) continue;
            const out = try t.kappaMergeUncached(gpa, charge, f.a, f.b);
            try charge.reserve(gpa, .memo, 1);
            (try t.memo_merge.getOrPut(gpa, key)).value_ptr.* = out.int();
        }
        return .from(t.memo_merge.get(mkey).?);
    }

    fn kappaMergeUncached(t: *Table, gpa: Allocator, charge: Charge, a: Kappas, b: Kappas) Error!Kappas {
        try charge.reserve(gpa, .inspection, 1);
        const pa = t.position(a);
        const pb = t.position(b);
        if (pa.fold != 0 or pb.fold != 0) {
            const fa = t.position(try t.kappaFold(gpa, charge, a));
            const fb = t.position(try t.kappaFold(gpa, charge, b));
            const here = try t.mapUnion(gpa, charge, .cond, fa.here, fb.here);
            const steps_union = try t.mapUnion(gpa, charge, .cond, fa.links, fb.links);
            return t.makePos(gpa, charge, .{ .here = here, .links = steps_union, .fold = @max(fa.fold, fb.fold) });
        }
        const here = try t.mapUnion(gpa, charge, .cond, pa.here, pb.here);
        const links = try t.mapUnion(gpa, charge, .link, pa.links, pb.links);
        if (here == pa.here and links == pa.links) return a;
        if (here == pb.here and links == pb.links) return b;
        return t.makePos(gpa, charge, .{ .here = here, .links = links, .fold = 0 });
    }

    /// `ctx` collapsed into one COLLAPSED fold (§2.9): by node, the join of
    /// everything stored at it and below it; its links, which lead back to
    /// itself, the steps it saw (so a reader below it stays sparse). A
    /// record per position, step and entry folded in, each shared position
    /// once. An exact fold stays as it is.
    pub fn kappaFold(t: *Table, gpa: Allocator, charge: Charge, ctx: Kappas) Error!Kappas {
        if (ctx != .none and t.isFold(ctx)) return ctx;
        var seen: Ids.FixedDict(1) = .{};
        defer seen.deinit(gpa);
        var stack: std.ArrayList(Kappas) = .empty;
        defer stack.deinit(gpa);
        var here: u32 = Ids.none_int;
        var steps_seen: u32 = Ids.none_int;
        if (ctx != .none) try stack.append(gpa, ctx);
        while (stack.pop()) |at| {
            try charge.reserve(gpa, .memo, 1);
            const got = try seen.getOrPut(gpa, .{at.int()});
            if (got.found_existing) continue;
            got.value_ptr.* = 1;
            const p = t.position(at);
            here = try t.mapUnion(gpa, charge, .cond, here, p.here);
            var it = t.mapEntries(p.links);
            while (it.next()) |e| {
                try charge.reserve(gpa, .inspection, 1);
                steps_seen = try t.mapPut(gpa, charge, steps_seen, e.key, 0);
                if (p.fold == 0) try stack.append(gpa, .from(e.value));
            }
        }
        return t.makePos(gpa, charge, .{ .here = here, .links = steps_seen, .fold = fold_collapsed });
    }

    /// An empty fold of `kind` (`fold_exact` or `fold_collapsed`).
    pub fn kappaEmptyFold(t: *Table, gpa: Allocator, charge: Charge, fold_kind: u32) Error!Kappas {
        return t.makePos(gpa, charge, .{ .here = Ids.none_int, .links = Ids.none_int, .fold = fold_kind });
    }

    /// The fold `ctx` with step `s` among the steps it saw.
    pub fn kappaFoldStep(t: *Table, gpa: Allocator, charge: Charge, ctx: Kappas, s: Step) Error!Kappas {
        const p = t.position(ctx);
        std.debug.assert(p.fold != 0);
        return t.makePos(gpa, charge, .{ .here = p.here, .links = try t.mapPut(gpa, charge, p.links, s.word(), 0), .fold = p.fold });
    }

    /// The `(node, condition)` entries stored at the position `ctx`.
    pub const HereIterator = struct {
        it: MapIterator,

        pub const Entry = struct { node: NodeId, cond: CondId };

        pub fn next(h: *HereIterator) ?Entry {
            const e = h.it.next() orelse return null;
            return .{ .node = .from(e.key), .cond = .from(e.value) };
        }
    };

    pub fn kappaHere(t: *const Table, ctx: Kappas) HereIterator {
        return .{ .it = t.mapEntries(t.position(ctx).here) };
    }

    /// The `(step, position)` links of `ctx`; a fold's are the steps it
    /// saw, each leading back to it.
    pub const LinkIterator = struct {
        it: MapIterator,
        fold: Kappas,

        pub const Entry = struct { step: Step, child: Kappas };

        pub fn next(l: *LinkIterator) ?Entry {
            const e = l.it.next() orelse return null;
            return .{ .step = Step.fromWord(e.key), .child = if (l.fold != .none) l.fold else .from(e.value) };
        }
    };

    pub fn kappaLinks(t: *const Table, ctx: Kappas) LinkIterator {
        const p = t.position(ctx);
        return .{ .it = t.mapEntries(p.links), .fold = if (p.fold != 0) ctx else .none };
    }

    /// How `kappaRelabel` maps an entry: its node (null: dropped) and its
    /// condition.
    pub const Relabel = struct {
        ctx: *anyopaque,
        node: *const fn (ctx: *anyopaque, n: NodeId) Error!?NodeId,
        cond: *const fn (ctx: *anyopaque, t: *Table, gpa: Allocator, charge: Charge, k: CondId) Error!CondId,
    };

    /// Whether a snapshot stores an unresolved condition (an `inst` atom in an
    /// entry): a check that a published κ is resolved (§2.11), uncharged, for
    /// `runtime_safety` builds.
    pub fn kappaHoldsInst(t: *const Table, gpa: Allocator, ctx: Kappas) Allocator.Error!bool {
        if (ctx == .none) return false;
        var seen: Ids.FixedDict(1) = .{};
        defer seen.deinit(gpa);
        var stack: std.ArrayList(Kappas) = .empty;
        defer stack.deinit(gpa);
        var conds: std.ArrayList(CondId) = .empty;
        defer conds.deinit(gpa);
        try stack.append(gpa, ctx);
        while (stack.pop()) |at| {
            if (at == .none or (try seen.getOrPut(gpa, .{at.int()})).found_existing) continue;
            const p = t.position(at);
            var it = t.mapEntries(p.here);
            while (it.next()) |e| try conds.append(gpa, .from(e.value));
            while (conds.pop()) |k| {
                if (k == yes or fails(k)) continue;
                const c = t.get(k);
                if (c.kind == .@"and") {
                    try conds.appendSlice(gpa, &.{ .from(c.a), .from(c.b) });
                } else if (c.atom == .inst) return true;
            }
            if (p.fold != 0) continue;
            var lt = t.mapEntries(p.links);
            while (lt.next()) |e| try stack.append(gpa, .from(e.value));
        }
        return false;
    }

    /// Whether a snapshot stores an entry under a view or a node whose DAG
    /// holds one: a check of the invariant that a class is stored forced
    /// (§2.11), uncharged, for `runtime_safety` builds. A position found
    /// view-free is remembered while no knot is tied, as `holdsView`
    /// remembers nodes, so a class added checks only the positions it adds.
    pub fn kappaHoldsView(t: *Table, gpa: Allocator, shapes: *Shape.Table, ctx: Kappas) Allocator.Error!bool {
        if (ctx == .none) return false;
        if (t.kview_free_epoch != shapes.ties) {
            t.kview_free.deinit(gpa);
            t.kview_free = .{};
            t.kview_free_epoch = shapes.ties;
        }
        var seen: Ids.FixedDict(1) = .{};
        defer seen.deinit(gpa);
        var visited: std.ArrayList(Kappas) = .empty;
        defer visited.deinit(gpa);
        var stack: std.ArrayList(Kappas) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, ctx);
        while (stack.pop()) |at| {
            if (at == .none or t.kview_free.get(.{at.int()}) != null) continue;
            if ((try seen.getOrPut(gpa, .{at.int()})).found_existing) continue;
            try visited.append(gpa, at);
            const p = t.position(at);
            var it = t.mapEntries(p.here);
            while (it.next()) |e| if (try shapes.holdsView(gpa, .from(e.key))) return true;
            if (p.fold != 0) continue;
            var lt = t.mapEntries(p.links);
            while (lt.next()) |e| try stack.append(gpa, .from(e.value));
        }
        for (visited.items) |at| (try t.kview_free.getOrPut(gpa, .{at.int()})).value_ptr.* = 1;
        return false;
    }

    /// `ctx` with every stored entry's node and condition mapped, the
    /// positions' paths and folds unchanged (§2.9: `Shape.map` relabels
    /// each binding's node, its paths relative to the value's root). A
    /// record per position and entry, each shared position once.
    pub fn kappaRelabel(t: *Table, gpa: Allocator, charge: Charge, ctx: Kappas, r: Relabel) Error!Kappas {
        if (ctx == .none) return .none;
        var memo: Ids.FixedDict(1) = .{};
        defer memo.deinit(gpa);
        // Post-order on an explicit stack (#1130): a snapshot's depth is the
        // source's, never native-stack depth. A position's children are
        // relabelled before it; a shared one once (the memo).
        const Frame = struct { at: Kappas, expanded: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, .{ .at = ctx, .expanded = false });
        while (stack.pop()) |f| {
            if (!f.expanded) {
                try charge.reserve(gpa, .memo, 1);
                if (memo.get(.{f.at.int()}) != null) continue;
                try stack.append(gpa, .{ .at = f.at, .expanded = true });
                const p = t.position(f.at);
                if (p.fold == 0) {
                    var lt = t.mapEntries(p.links);
                    while (lt.next()) |e| try stack.append(gpa, .{ .at = .from(e.value), .expanded = false });
                }
                continue;
            }
            if (memo.get(.{f.at.int()}) != null) continue;
            try t.relabelOne(gpa, charge, f.at, r, &memo);
        }
        return .from(memo.get(.{ctx.int()}).?);
    }

    /// One position relabelled, its children's images in `memo` already.
    fn relabelOne(t: *Table, gpa: Allocator, charge: Charge, ctx: Kappas, r: Relabel, memo: *Ids.FixedDict(1)) Error!void {
        const p = t.position(ctx);
        var here: u32 = Ids.none_int;
        var it = t.mapEntries(p.here);
        while (it.next()) |e| {
            try charge.reserve(gpa, .inspection, 1);
            const m = (try r.node(r.ctx, .from(e.key))) orelse continue;
            const k = try r.cond(r.ctx, t, gpa, charge, .from(e.value));
            const old = t.mapGet(here, m.int());
            const v = if (old) |o| try t.join(gpa, charge, .from(o), k) else k;
            try t.keyed(gpa, charge, m);
            here = try t.mapPut(gpa, charge, here, m.int(), v.int());
        }
        // A fold's links are the steps it saw, its sparse frontier (§2.9),
        // each leading back to itself: kept as they are, never followed (#1129).
        var links: u32 = if (p.fold != 0) p.links else Ids.none_int;
        if (p.fold == 0) {
            var lt = t.mapEntries(p.links);
            while (lt.next()) |e| {
                const child: Kappas = .from(memo.get(.{e.value}).?);
                if (child != .none) links = try t.mapPut(gpa, charge, links, e.key, child.int());
            }
        }
        const out = try t.makePos(gpa, charge, .{ .here = here, .links = links, .fold = p.fold });
        (try memo.getOrPut(gpa, .{ctx.int()})).value_ptr.* = out.int();
    }

    // ---- κ reads, and the crossing (§2.11 *κ across a call*) -------------------------

    /// A crossing carried down a walk (*Carried along the walk*): the
    /// re-rooted actual's region and the position `R_Q` the walk reads it at.
    /// `epoch`: the `base_epoch` its `eqOn` held at; once that moves, the pair
    /// carries nothing (*A read in flight*).
    pub const Pair = struct { region: SetId, r: Kappas, epoch: u32 };

    /// What a union, choice or positions DAG holds besides its κ, a function
    /// of the node alone (*`dagKappa`*): whether a recast is below it (a view
    /// of a recast included), whether a positions node is, and the cells the
    /// positions nodes below it repeat (`dups`, `dups_approx` those one of
    /// whose occurrences is approximate), as sets.
    pub const DagFacts = struct { approx: bool = false, positions: bool = false, dups: SetId = .none, dups_approx: SetId = .none };

    fn isDag(k: Shape.Kind) bool {
        return k == .@"union" or k == .choice or k == .positions;
    }

    /// A memo entry a crossed read made, written once the read is known not
    /// to have seen `base_epoch` move (*A read in flight*).
    const Pending = struct { which: enum(u8) { dag, inner, deep }, key: [3]u32, value: u32 };

    fn memoPut(t: *Table, gpa: Allocator, which: @FieldType(Pending, "which"), key: [3]u32, value: u32, crossed: bool) Error!void {
        if (t.no_memo) return;
        if (crossed) return t.pending.append(gpa, .{ .which = which, .key = key, .value = value });
        const m = switch (which) {
            .dag => &t.memo_dag,
            .inner => &t.memo_inner,
            .deep => &t.memo_deep,
        };
        (try m.getOrPut(gpa, key)).value_ptr.* = value;
    }

    fn memoGet(t: *const Table, which: @FieldType(Pending, "which"), key: [3]u32) ?u32 {
        if (t.no_memo) return null;
        const v = switch (which) {
            .dag => t.memo_dag.get(key),
            .inner => t.memo_inner.get(key),
            .deep => t.memo_deep.get(key),
        } orelse return null;
        // A read with no crossing (a redo, the cross-check) takes no entry a
        // crossing made (*A read in flight*).
        if (t.no_cross) if (t.memo_crossed.get(.{ @backingInt(which), key[0], key[1], key[2] })) |c| if (c == v) return null;
        return v;
    }

    /// The pending entries from `from` on: kept, or dropped with the read.
    fn settle(t: *Table, gpa: Allocator, from: usize, kept: bool) Error!void {
        if (kept) for (t.pending.items[from..]) |p| {
            const m = switch (p.which) {
                .dag => &t.memo_dag,
                .inner => &t.memo_inner,
                .deep => &t.memo_deep,
            };
            (try m.getOrPut(gpa, p.key)).value_ptr.* = p.value;
            (try t.memo_crossed.getOrPut(gpa, .{ @backingInt(p.which), p.key[0], p.key[1], p.key[2] })).value_ptr.* = p.value;
        };
        t.pending.shrinkRetainingCapacity(from);
    }

    /// The facts of a DAG node (`DagFacts`), memoised per node: post-order on
    /// an explicit stack over its union, choice and positions sides (a view
    /// side is read at its answer as one position, not walked), a node met
    /// again while open adding nothing and keeping no memo. A record per node
    /// and repeated cell.
    fn dagFacts(t: *Table, gpa: Allocator, charge: Charge, v: View, root: NodeId) Error!DagFacts {
        try charge.reserve(gpa, .memo, 1);
        if (t.dag_facts.get(root)) |i| return t.facts.items[i];
        const Frame = struct { node: NodeId, expanded: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        var local: stamped.Column(NodeId, DagFacts) = .{};
        defer local.deinit(gpa);
        var open: stamped.Column(NodeId, void) = .{};
        defer open.deinit(gpa);
        var cyclic = false;
        try stack.append(gpa, .{ .node = root, .expanded = false });
        while (stack.pop()) |f| {
            const n = f.node;
            if (local.contains(n)) continue;
            if (!isDag(v.shapes.kind(n))) {
                // A recast, or a view of one, is approximate (§2.11).
                const nk = v.shapes.kind(n);
                const approx = nk == .recast or (nk == .view and v.shapes.kind(try v.shapes.force(gpa, charge.account, n)) == .recast);
                try local.put(gpa, n, .{ .approx = approx });
                continue;
            }
            if (t.dag_facts.get(n)) |i| {
                try local.put(gpa, n, t.facts.items[i]);
                continue;
            }
            const d = v.shapes.get(n);
            if (!f.expanded) {
                if (open.contains(n)) {
                    cyclic = true;
                    continue;
                }
                try open.put(gpa, n, {});
                try stack.appendSlice(gpa, &.{ .{ .node = n, .expanded = true }, .{ .node = .from(d.a), .expanded = false }, .{ .node = .from(d.b), .expanded = false } });
                continue;
            }
            open.remove(n);
            const fa = local.get(.from(d.a)) orelse DagFacts{};
            const fb = local.get(.from(d.b)) orelse DagFacts{};
            var out: DagFacts = .{
                .approx = fa.approx or fb.approx,
                .positions = fa.positions or fb.positions or d.kind == .positions,
                .dups = try v.cells.sets.unionWith(gpa, charge, fa.dups, fb.dups),
                .dups_approx = try v.cells.sets.unionWith(gpa, charge, fa.dups_approx, fb.dups_approx),
            };
            if (d.kind == .positions) {
                // The cells both sides hold, as sets: one approximate where the
                // node is (a recast below) or either occurrence is.
                const both = try v.cells.sets.intersection(gpa, charge, try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, .from(d.a)), try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, .from(d.b)));
                out.dups = try v.cells.sets.unionWith(gpa, charge, out.dups, both);
                out.dups_approx = try v.cells.sets.unionWith(gpa, charge, out.dups_approx, if (out.approx) both else try t.cellPart(gpa, charge, v.cells, v.places, .approx, both));
            }
            try local.put(gpa, n, out);
            if (!cyclic) {
                try charge.reserve(gpa, .memo, 1);
                try t.dag_facts.put(gpa, n, @intCast(t.facts.items.len));
                try t.facts.append(gpa, out);
            }
        }
        return local.get(root).?;
    }

    /// A DAG node's read once its sides' join `inner` is known: at a summary
    /// position, a positions node below making it one, the leaf rule over its
    /// cells and the repeats its positions nodes found (*`dagKappa`*).
    fn dagRoot(t: *Table, gpa: Allocator, charge: Charge, v: View, root: NodeId, at_summary: bool, inner: CondId) Error!CondId {
        const facts = try t.dagFacts(gpa, charge, v, root);
        if (!at_summary and !facts.positions) return inner;
        return t.@"and"(gpa, charge, inner, try t.derivedCells(gpa, charge, v, try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, root), true, facts.dups, facts.dups_approx));
    }

    /// What is stored for view `n` along its chain (§2.11 *κ at a view*):
    /// the entries under the view and every view its chain passes through,
    /// joined as stored values, the answer's left to the reader. Memoised
    /// per `(ctx, view)`, each view on a chain once: a chain of L views costs
    /// L, never L². Null when no id on the chain stores anything.
    fn chainStored(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId) Error!?CondId {
        // Down the chain to its end or to a view already joined.
        var views: std.ArrayList(NodeId) = .empty;
        defer views.deinit(gpa);
        var joined: ?CondId = null;
        var id: ?NodeId = n;
        while (id) |x| : (id = v.shapes.chainNext(x)) {
            try charge.reserve(gpa, .memo, 1);
            if (t.memo_chain.get(.{ ctx.int(), x.int() })) |hit| {
                joined = if (hit == Ids.none_int) null else CondId.from(hit);
                break;
            }
            try views.append(gpa, x);
        }
        // Back up it, each view's entry joined onto what lies joined it.
        var k = views.items.len;
        while (k > 0) {
            k -= 1;
            const x = views.items[k];
            if (t.kappaGet(ctx, x)) |s| joined = if (joined) |b| try t.join(gpa, charge, s, b) else s;
            try charge.reserve(gpa, .memo, 1);
            (try t.memo_chain.getOrPut(gpa, .{ ctx.int(), x.int() })).value_ptr.* = if (joined) |b| b.int() else Ids.none_int;
        }
        return joined;
    }

    /// What is stored at `n` itself, a view's chain and answer joined in:
    /// what a reader of one position (a recast's inner, `innersOf`) takes.
    fn storedAt(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId) Error!?CondId {
        if (v.shapes.kind(n) != .view) return t.kappaGet(ctx, n);
        const answer = try v.shapes.force(gpa, charge.account, n);
        const chain = try t.chainStored(gpa, charge, v, ctx, n);
        const own = t.kappaGet(ctx, answer);
        if (chain) |c| return if (own) |o| try t.join(gpa, charge, c, o) else c;
        return own;
    }

    /// κ(n) in `ctx` by the header's rules; `at_summary` is whether `n`'s
    /// path crossed a `[*]` or `⟲` (`excl` there for an arrival `isFolded`).
    pub fn kappaOf(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, at_summary: bool) Error!CondId {
        return t.readAt(gpa, charge, v, ctx, n, at_summary, &.{});
    }

    /// `kappaOf` with the crossings a walk carries (`deep`'s frontier): the
    /// read at `ctx`, its value the same with or without them (*Argument 1*).
    /// A crossed read notes `base_epoch`; if it moved, the read is made again
    /// at `ctx`, exact, its memo entries dropped (*A read in flight*).
    fn readAt(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, at_summary: bool, pairs: []const Pair) Error!CondId {
        return t.resolved(gpa, charge, try t.readAtRaw(gpa, charge, v, ctx, n, at_summary, pairs));
    }

    fn readAtRaw(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, at_summary: bool, pairs: []const Pair) Error!CondId {
        // A node that walks nothing below it (no view, no DAG): read at once,
        // as the machine would, with no task of its own.
        if (v.shapes.kind(n) != .view and !isDag(v.shapes.kind(n))) {
            const k = try t.kappaReadOne(gpa, charge, v, ctx, n, at_summary, null);
            const fc = t.fold_cond.get(n) orelse return k;
            return t.@"and"(gpa, charge, k, fc);
        }
        // A union's, a positions node's or a view's read is a DAG walk (§4.1, #1098).
        const walk = try v.shapes.dagWalk(gpa, charge.account, n);
        defer if (walk) |k| charge.account.leave(k);
        const epoch = v.shapes.base_epoch;
        const from = t.pending.items.len;
        const r = try t.machine(gpa, charge, v, ctx, n, at_summary, pairs);
        // Every read outside a check is checked: memo hits walked whole.
        if (std.debug.runtime_safety and full_cross_check and !r.crossed and !t.no_memo) try t.crossCheckRead(gpa, charge, v, ctx, n, at_summary, r.k);
        if (!r.crossed) return r.k;
        t.crossed_reads += 1;
        if (v.shapes.base_epoch != epoch) {
            t.crossed_redos += 1;
            try t.settle(gpa, from, false);
            const saved = t.no_cross;
            t.no_cross = true;
            defer t.no_cross = saved;
            return (try t.machine(gpa, charge, v, ctx, n, at_summary, &.{})).k;
        }
        try t.settle(gpa, from, true);
        if (std.debug.runtime_safety and full_cross_check and !t.no_memo) try t.crossCheckRead(gpa, charge, v, ctx, n, at_summary, r.k);
        return r.k;
    }

    /// `-Downership-full-cross-check` (*Cross-check*): a crossed read made
    /// again at `C`, with no crossing and no memo, gives the same kind and
    /// atom set.
    fn crossCheckRead(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, at_summary: bool, k: CondId) Error!void {
        const saved = .{ t.no_cross, t.no_memo };
        t.no_cross = true;
        t.no_memo = true;
        defer {
            t.no_cross = saved[0];
            t.no_memo = saved[1];
        }
        const exact = (try t.machine(gpa, charge, v, ctx, n, at_summary, &.{})).k;
        try t.expectSame(gpa, charge, k, exact);
    }

    /// Two conditions of one kind and one atom set, or a defect.
    pub fn expectSame(t: *Table, gpa: Allocator, charge: Charge, a: CondId, b: CondId) Error!void {
        const same = blk: {
            if (fails(a) or fails(b) or a == yes or b == yes) break :blk a == b;
            break :blk try t.flat(gpa, charge, a) == try t.flat(gpa, charge, b);
        };
        if (!same) std.debug.panic("ownership v2 cross-check: a crossed read {d} differs from its read at C {d}", .{ a.int(), b.int() });
    }

    /// The crossing at re-root view `n` read at `ctx` (*The crossing*):
    /// `R`, the actual and its region, when `eqOn(ctx, R)` holds on the
    /// region; null where the read stays at `ctx`.
    fn crossAt(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId) Error!?struct { r: Kappas, region: SetId } {
        if (t.no_cross) return null;
        const r = (try v.shapes.rerootKappa(gpa, charge.account, n)) orelse return null;
        const answer = try v.shapes.force(gpa, charge.account, n);
        const actual = v.shapes.chainNext(n) orelse answer;
        const region = try v.shapes.region(gpa, charge.account, actual);
        if (!try t.eqOn(gpa, charge, v, ctx, r, region)) return null;
        return .{ .r = r, .region = region };
    }

    /// The position a node met at `ctx` with `pairs` carried is read at: a
    /// carried pair's `R_Q` when the node is wholly of its region, else `ctx`
    /// (*Carried along the walk*). `true` when it crossed.
    fn carried(t: *Table, gpa: Allocator, charge: Charge, v: View, n: NodeId, pairs: []const Pair) Error!?Kappas {
        if (t.no_cross) return null;
        for (pairs) |p| if (p.epoch == v.shapes.base_epoch and try v.shapes.wholly(gpa, charge.account, n, p.region)) return p.r;
        return null;
    }

    const Read = struct { k: CondId, crossed: bool };

    /// The read machine: `kappaOf` and the DAG walk below it on one explicit
    /// stack (#1130: a chain of views below views is as long as the calls
    /// that made it, never native-stack depth). A `read` task is `kappaOf`
    /// at its position; an `inner` task a DAG node's join of its sides' reads
    /// with its own entry. At a re-root view the read may cross into the
    /// actual's own position (`crossAt`), and below a crossing a node wholly
    /// of the actual's region is read at the carried `R_Q`. Both tasks are
    /// memoised by `(position, node, class)`: positions and nodes are
    /// immutable, so a read is a function of its key, crossed or not. Within
    /// one run each task is made once; a task met again while it is open (a
    /// cycle) reads `yes`, and the run then keeps no memo entry.
    fn machine(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx0: Kappas, n0: NodeId, s0: bool, pairs: []const Pair) Error!Read {
        const Op = enum(u8) { read, inner };
        const Frame = struct {
            op: Op,
            ctx: Kappas,
            node: NodeId,
            summary: bool,
            /// Whether the carried pairs hold below this task.
            carry: bool,
            stage: u8 = 0,
            /// A read: the position and node its kind's rule reads (a view's
            /// answer, perhaps across) and what the chain stored.
            at: Kappas = .none,
            answer: NodeId = .none,
            extra: CondId = .none,
            /// Read at a position a crossing chose.
            crossed: bool = false,

            fn key(f: @This()) [4]u32 {
                return .{ @backingInt(f.op), f.ctx.int(), f.node.int(), @intFromBool(f.summary) };
            }
        };
        const open_mark = std.math.maxInt(u32);
        var frames: std.ArrayList(Frame) = .empty;
        defer frames.deinit(gpa);
        var vals: std.ArrayList(Read) = .empty;
        defer vals.deinit(gpa);
        var state: Ids.FixedDict(4) = .{};
        defer state.deinit(gpa);
        var done: std.ArrayList(Read) = .empty;
        defer done.deinit(gpa);
        var cyclic = false;
        try frames.append(gpa, .{ .op = .read, .ctx = ctx0, .node = n0, .summary = s0, .carry = pairs.len > 0 });
        while (frames.items.len > 0) {
            const fi = frames.items.len - 1;
            var f = frames.items[fi];
            if (f.stage == 0) {
                try charge.reserve(gpa, .memo, 1);
                const got = try state.getOrPut(gpa, f.key());
                if (got.found_existing) {
                    _ = frames.pop();
                    if (got.value_ptr.* == open_mark) {
                        cyclic = true;
                        try vals.append(gpa, .{ .k = yes, .crossed = false });
                    } else try vals.append(gpa, done.items[got.value_ptr.*]);
                    continue;
                }
                got.value_ptr.* = open_mark;
            }
            var result: ?Read = null;
            switch (f.op) {
                .read => if (f.stage == 0) {
                    f.at = f.ctx;
                    f.answer = f.node;
                    var extra: ?CondId = null;
                    if (v.shapes.kind(f.node) == .view) {
                        f.answer = try v.shapes.force(gpa, charge.account, f.node);
                        if (try t.crossAt(gpa, charge, v, f.ctx, f.node)) |x| {
                            // The view's own entry, the class's binding, at `C`;
                            // the chain past it and the answer at `R`.
                            f.at = x.r;
                            f.crossed = true;
                            extra = t.kappaGet(f.ctx, f.node);
                            if (v.shapes.chainNext(f.node)) |next| if (try t.chainStored(gpa, charge, v, x.r, next)) |c| {
                                extra = if (extra) |e| try t.join(gpa, charge, e, c) else c;
                            };
                        } else extra = try t.chainStored(gpa, charge, v, f.ctx, f.node);
                    }
                    f.extra = extra orelse .none;
                    if (!isDag(v.shapes.kind(f.answer))) {
                        result = .{ .k = try t.kappaReadOne(gpa, charge, v, f.at, f.answer, f.summary, extra), .crossed = f.crossed };
                    } else {
                        if (t.memoGet(.dag, .{ f.at.int(), f.answer.int(), @intFromBool(f.summary) })) |hit| {
                            result = .{ .k = if (extra) |e| try t.join(gpa, charge, e, .from(hit)) else .from(hit), .crossed = f.crossed };
                        } else {
                            // The answer's DAG, its sides' join first. Below a
                            // crossing every node of it is of the region, read at
                            // `R`: the carried pairs are not needed there.
                            f.stage = 1;
                            frames.items[fi] = f;
                            try frames.append(gpa, .{ .op = .inner, .ctx = f.at, .node = f.answer, .summary = f.summary, .carry = f.carry and !f.crossed });
                            continue;
                        }
                    }
                } else {
                    const inner = vals.pop().?;
                    const root = try t.dagRoot(gpa, charge, v, f.answer, f.summary, inner.k);
                    const crossed = f.crossed or inner.crossed;
                    if (!cyclic) try t.memoPut(gpa, .dag, .{ f.at.int(), f.answer.int(), @intFromBool(f.summary) }, root.int(), crossed);
                    result = .{ .k = if (f.extra != .none) try t.join(gpa, charge, f.extra, root) else root, .crossed = crossed };
                },
                .inner => if (f.stage == 0) {
                    // The task's one record (above) covers its memo lookups.
                    if (t.memoGet(.inner, .{ f.ctx.int(), f.node.int(), @intFromBool(f.summary) })) |hit| {
                        result = .{ .k = .from(hit), .crossed = false };
                    } else {
                        f.stage = 1;
                        frames.items[fi] = f;
                        const d = v.shapes.get(f.node);
                        for ([_]NodeId{ .from(d.b), .from(d.a) }) |sd| {
                            var at = f.ctx;
                            var carry = f.carry;
                            if (f.carry) if (try t.carried(gpa, charge, v, sd, pairs)) |r| {
                                at = r;
                                carry = false;
                            };
                            try frames.append(gpa, .{ .op = if (isDag(v.shapes.kind(sd))) .inner else .read, .ctx = at, .node = sd, .summary = f.summary, .carry = carry, .crossed = at != f.ctx });
                        }
                        continue;
                    }
                } else {
                    const a = vals.pop().?;
                    const b = vals.pop().?;
                    var k = try t.join(gpa, charge, a.k, b.k);
                    if (t.kappaGet(f.ctx, f.node)) |st| k = try t.join(gpa, charge, st, k);
                    const crossed = a.crossed or b.crossed or f.crossed;
                    if (!cyclic) try t.memoPut(gpa, .inner, .{ f.ctx.int(), f.node.int(), @intFromBool(f.summary) }, k.int(), crossed);
                    result = .{ .k = k, .crossed = crossed };
                },
            }
            var r = result.?;
            // A widened class image owes its path-multiset obligation wherever
            // it is read, a union's side included (§2.9, #1128). `fold_cond`
            // never keys a view: widen folds answers.
            if (f.op == .read) if (t.fold_cond.get(f.answer)) |fc| {
                r.k = try t.@"and"(gpa, charge, r.k, fc);
            };
            _ = frames.pop();
            (try state.getOrPut(gpa, f.key())).value_ptr.* = @intCast(done.items.len);
            try done.append(gpa, r);
            try vals.append(gpa, r);
        }
        return vals.pop().?;
    }

    /// `kappaRead` of a node that is no view: a DAG node's read through the
    /// machine, any other kind's at once.
    fn kappaRead(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, at_summary: bool, extra: ?CondId) Error!CondId {
        if (!isDag(v.shapes.kind(n))) return t.resolved(gpa, charge, try t.kappaReadOne(gpa, charge, v, ctx, n, at_summary, extra));
        const k = try t.readAt(gpa, charge, v, ctx, n, at_summary, &.{});
        return t.resolved(gpa, charge, if (extra) |e| try t.join(gpa, charge, e, k) else k);
    }

    /// The read of a node of a kind that walks nothing below it (no view, no
    /// DAG): its stored entry, `extra` joined, and the derived read.
    fn kappaReadOne(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, at_summary: bool, extra: ?CondId) Error!CondId {
        const own = t.kappaGet(ctx, n);
        const stored: ?CondId = if (extra) |e| (if (own) |s| try t.join(gpa, charge, s, e) else e) else own;
        // THE RULE (header): stored ⊔ derived at the read's position.
        const derived: CondId = switch (v.shapes.kind(n)) {
            .leaf => try t.derivedCells(gpa, charge, v, (try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, n)), at_summary, .none, .none),
            // A built node's κ is the walk's (O13): `lost` until set; in a
            // collapsed fold `lost` (§2.9). At a summary position its storage
            // arrivals that stand for many positions owe `excl` as a leaf's do
            // (§2.9, #1112), so a read never rests on where it was linked from.
            .node, .delta => {
                if (t.isCollapsed(ctx)) return lost;
                const s = stored orelse return lost;
                if (!at_summary or s == shared) return s;
                return t.@"and"(gpa, charge, s, try t.derivedCells(gpa, charge, v, (try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, n)), true, .none, .none));
            },
            // A recast and its inner are one position: what is stored at
            // either counts (§2.9, §2.13.9).
            .recast => blk: {
                var d: CondId = if (holdsBelow(v.places, v.shapes.place(n))) lost else yes;
                // Every inner at this position, a union's recasts' inside an
                // inner too (#1101).
                var inners: std.ArrayList(NodeId) = .empty;
                defer inners.deinit(gpa);
                try innersOf(gpa, charge, v, n, &inners);
                for (inners.items) |i| if (try t.storedAt(gpa, charge, v, ctx, i)) |s| {
                    d = try t.join(gpa, charge, s, d);
                };
                // At a summary position its cells owe what a leaf's do (#1115).
                if (at_summary) d = try t.@"and"(gpa, charge, d, try t.derivedCells(gpa, charge, v, (try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, n)), true, .none, .none));
                break :blk d;
            },
            .@"union", .choice, .positions, .view => unreachable, // the machine's
        };
        return if (stored) |s| t.join(gpa, charge, s, derived) else derived;
    }

    // ---- the equality a crossing rests on (*The equality*) -----------------------------

    /// Whether any position at or below `ctx` is a fold, exact or collapsed
    /// (*No crossing at a fold*): memoised per position, post-order on an
    /// explicit stack.
    fn foldBelow(t: *Table, gpa: Allocator, charge: Charge, ctx: Kappas) Error!bool {
        if (ctx == .none) return false;
        try charge.reserve(gpa, .memo, 1);
        if (t.memo_fold_below.get(.{ctx.int()})) |hit| return hit == 1;
        const Frame = struct { at: Kappas, expanded: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, .{ .at = ctx, .expanded = false });
        while (stack.pop()) |f| {
            if (t.memo_fold_below.get(.{f.at.int()}) != null) continue;
            const p = t.position(f.at);
            if (p.fold != 0) {
                (try t.memo_fold_below.getOrPut(gpa, .{f.at.int()})).value_ptr.* = 1;
                continue;
            }
            if (!f.expanded) {
                try charge.reserve(gpa, .inspection, 1);
                try stack.append(gpa, .{ .at = f.at, .expanded = true });
                var it = t.mapEntries(p.links);
                while (it.next()) |e| if (t.memo_fold_below.get(.{e.value}) == null) try stack.append(gpa, .{ .at = .from(e.value), .expanded = false });
                continue;
            }
            var any = false;
            var it = t.mapEntries(p.links);
            while (it.next()) |e| {
                try charge.reserve(gpa, .inspection, 1);
                if (t.memo_fold_below.get(.{e.value}).? == 1) any = true;
            }
            try charge.reserve(gpa, .memo, 1);
            (try t.memo_fold_below.getOrPut(gpa, .{f.at.int()})).value_ptr.* = @intFromBool(any);
        }
        return t.memo_fold_below.get(.{ctx.int()}).? == 1;
    }

    /// `eqOn(C, R)` on `region` (*The equality*): at every pair of positions
    /// the walk can reach, neither is a fold, every key based on the region
    /// has in both no entry or entries of one kind and atom set, and `C`
    /// links a step exactly when `R` does. Memoised per `(C, R, region)`
    /// within one `base_epoch`; a pair of equal positions is equal at once,
    /// and the entry maps are compared per pair of map nodes (`mapsEqOn`).
    pub fn eqOn(t: *Table, gpa: Allocator, asking: Charge, v: View, c: Kappas, r: Kappas, region: SetId) Error!bool {
        // The crossing's comparison, a growth task (§4.1).
        const task = try asking.account.enter(gpa, null);
        defer asking.account.leave(task);
        const charge: Charge = .growth(asking.account);
        if (try t.foldBelow(gpa, charge, c) or try t.foldBelow(gpa, charge, r)) return false;
        if (c == r) return true;
        const key: [4]u32 = .{ c.int(), r.int(), region.int(), v.shapes.base_epoch };
        try charge.reserve(gpa, .memo, 1);
        if (t.memo_eq.get(key)) |hit| return hit == 1;
        const out = try t.eqOnWalk(gpa, charge, v, c, r, region);
        (try t.memo_eq.getOrPut(gpa, key)).value_ptr.* = @intFromBool(out);
        return out;
    }

    fn eqOnWalk(t: *Table, gpa: Allocator, charge: Charge, v: View, c0: Kappas, r0: Kappas, region: SetId) Error!bool {
        var stack: std.ArrayList([2]Kappas) = .empty;
        defer stack.deinit(gpa);
        var seen: Ids.FixedDict(2) = .{};
        defer seen.deinit(gpa);
        try stack.append(gpa, .{ c0, r0 });
        while (stack.pop()) |pr| {
            const c, const r = pr;
            if (c == r) continue;
            try charge.reserve(gpa, .memo, 1);
            if ((try seen.getOrPut(gpa, .{ c.int(), r.int() })).found_existing) continue;
            if (t.memo_eq.get(.{ c.int(), r.int(), region.int(), v.shapes.base_epoch })) |hit| {
                if (hit == 0) return false;
                continue;
            }
            const pc = t.position(c);
            const pr_ = t.position(r);
            if (pc.fold != 0 or pr_.fold != 0) return false;
            if (!try t.mapsEqOn(gpa, charge, v, pc.here, pr_.here, region)) return false;
            if (!try t.linksEq(gpa, charge, pc.links, pr_.links, &stack)) return false;
        }
        return true;
    }

    /// Two entry maps equal on the keys based on `region` (*The comparison
    /// and its cost*): the keys the two bind differently (`diffKeys`, with no
    /// region in it, so a pair of subtrees an earlier call compared is met
    /// again whatever the region) must hold no tested key: not the empty
    /// value, which is tested for every region, and none whose `bases*`
    /// meets the region (`diffReach`, memoised per radix node).
    fn mapsEqOn(t: *Table, gpa: Allocator, charge: Charge, v: View, a: u32, b: u32, region: SetId) Error!bool {
        if (a == b) return true;
        const d = try t.diffKeys(gpa, charge, v, a, b);
        if (d == .none) return true;
        if (try t.nodesPart(gpa, charge, v, .empty, d) != .none) return false;
        return !try v.shapes.node_sets.intersectsMemo(gpa, charge, &v.shapes.memo_node_meet, try t.nodesPart(gpa, charge, v, .reach, d), region);
    }

    /// The keys two entry maps bind differently, as a node set: bound by one
    /// side only, or by both with another kind or atom set (`sameCond`).
    /// Memoised per unordered pair of map nodes, for good (maps and their
    /// entries never change); the recursion is the key width.
    fn diffKeys(t: *Table, gpa: Allocator, charge: Charge, v: View, a: u32, b: u32) Error!SetId {
        if (a == b) return .none;
        if (a == Ids.none_int) return t.mapKeys(gpa, charge, v, b);
        if (b == Ids.none_int) return t.mapKeys(gpa, charge, v, a);
        const key: [2]u32 = .{ @min(a, b), @max(a, b) };
        try charge.reserve(gpa, .memo, 1);
        if (t.memo_diff.get(key)) |hit| return .from(hit);
        const sets = &v.shapes.node_sets;
        const memo = &v.shapes.memo_node_union;
        const na = t.mapNode(a);
        const nb = t.mapNode(b);
        const out: SetId = blk: {
            if (na.mask == 0 and nb.mask == 0) {
                if (na.prefix == nb.prefix) {
                    if (na.left == nb.left or try t.sameCond(gpa, charge, .from(na.left), .from(nb.left))) break :blk .none;
                    break :blk try sets.insert(gpa, charge, .none, na.prefix, 0);
                }
                break :blk try sets.unionMemo(gpa, charge, memo, try t.mapKeys(gpa, charge, v, a), try t.mapKeys(gpa, charge, v, b));
            }
            if (na.mask == 0 or nb.mask == 0) {
                const leaf_a = na.mask == 0;
                const leaf_id = if (leaf_a) a else b;
                const leaf = if (leaf_a) na else nb;
                const br = if (leaf_a) nb else na;
                if (!matches(leaf.prefix, br.prefix, br.mask)) break :blk try sets.unionMemo(gpa, charge, memo, try t.mapKeys(gpa, charge, v, a), try t.mapKeys(gpa, charge, v, b));
                const zero = leaf.prefix & br.mask == 0;
                break :blk try sets.unionMemo(gpa, charge, memo, try t.diffKeys(gpa, charge, v, leaf_id, if (zero) br.left else br.right), try t.mapKeys(gpa, charge, v, if (zero) br.right else br.left));
            }
            if (na.mask == nb.mask and na.prefix == nb.prefix) break :blk try sets.unionMemo(gpa, charge, memo, try t.diffKeys(gpa, charge, v, na.left, nb.left), try t.diffKeys(gpa, charge, v, na.right, nb.right));
            if (na.mask > nb.mask and matches(nb.prefix, na.prefix, na.mask)) {
                const zero = nb.prefix & na.mask == 0;
                break :blk try sets.unionMemo(gpa, charge, memo, try t.diffKeys(gpa, charge, v, if (zero) na.left else na.right, b), try t.mapKeys(gpa, charge, v, if (zero) na.right else na.left));
            }
            if (nb.mask > na.mask and matches(na.prefix, nb.prefix, nb.mask)) {
                const zero = na.prefix & nb.mask == 0;
                break :blk try sets.unionMemo(gpa, charge, memo, try t.diffKeys(gpa, charge, v, a, if (zero) nb.left else nb.right), try t.mapKeys(gpa, charge, v, if (zero) nb.right else nb.left));
            }
            break :blk try sets.unionMemo(gpa, charge, memo, try t.mapKeys(gpa, charge, v, a), try t.mapKeys(gpa, charge, v, b));
        };
        (try t.memo_diff.getOrPut(gpa, key)).value_ptr.* = out.int();
        return out;
    }

    /// The keys of an entry map, as a node set: memoised per map node, for
    /// good, made from its two halves' sets; the recursion is the key width.
    fn mapKeys(t: *Table, gpa: Allocator, charge: Charge, v: View, m: u32) Error!SetId {
        if (m == Ids.none_int) return .none;
        const n = t.mapNode(m);
        if (n.mask == 0) return v.shapes.node_sets.insert(gpa, charge, .none, n.prefix, 0);
        try charge.reserve(gpa, .memo, 1);
        if (t.memo_map_keys.get(.{m})) |hit| return .from(hit);
        const out = try v.shapes.node_sets.unionMemo(gpa, charge, &v.shapes.memo_node_union, try t.mapKeys(gpa, charge, v, n.left), try t.mapKeys(gpa, charge, v, n.right));
        (try t.memo_map_keys.getOrPut(gpa, .{m})).value_ptr.* = out.int();
        return out;
    }

    /// What a node set of keys tells the comparison (`mapsEqOn`): `empty`,
    /// the empty values among them (memoised for good); `reach`, their
    /// `bases*` with themselves (memoised within one `base_epoch`). Per radix
    /// node, a node's the union of its halves'; the recursion is the key width.
    const NodesPart = enum(u8) { empty, reach };

    fn nodesPart(t: *Table, gpa: Allocator, charge: Charge, v: View, which: NodesPart, s: SetId) Error!SetId {
        if (s == .none) return .none;
        const sets = &v.shapes.node_sets;
        const epoch: u32 = if (which == .reach) v.shapes.base_epoch else 0;
        const key: [3]u32 = .{ @backingInt(which), s.int(), epoch };
        try charge.reserve(gpa, .memo, 1);
        if (t.memo_nodes_part.get(key)) |hit| return .from(hit);
        const out: SetId = if (sets.branches(s)) |kids|
            try sets.unionMemo(gpa, charge, &v.shapes.memo_node_union, try t.nodesPart(gpa, charge, v, which, kids[0]), try t.nodesPart(gpa, charge, v, which, kids[1]))
        else blk: {
            var it = sets.iterate(s);
            const n: NodeId = .from(it.next().?.key);
            break :blk switch (which) {
                .empty => if (v.shapes.kind(n) == .leaf and v.shapes.cells(n) == .none) s else .none,
                .reach => try v.shapes.basesClosure(gpa, charge.account, n),
            };
        };
        (try t.memo_nodes_part.getOrPut(gpa, key)).value_ptr.* = out.int();
        return out;
    }

    /// One kind and one atom set (`flat`): what a block and a verdict see.
    fn sameCond(t: *Table, gpa: Allocator, charge: Charge, a: CondId, b: CondId) Error!bool {
        if (a == b) return true;
        if (fails(a) or fails(b) or a == yes or b == yes) return false;
        return try t.flat(gpa, charge, a) == try t.flat(gpa, charge, b);
    }

    /// Two link maps with the same steps, each pair of differing children
    /// queued for `eqOn`: an extra link is no equality (*The equality*).
    fn linksEq(t: *Table, gpa: Allocator, charge: Charge, a: u32, b: u32, out: *std.ArrayList([2]Kappas)) Error!bool {
        if (a == b) return true;
        var ia = t.mapEntries(a);
        var ib = t.mapEntries(b);
        while (true) {
            try charge.reserve(gpa, .inspection, 1);
            const x = ia.next();
            const y = ib.next();
            if (x == null and y == null) return true;
            if (x == null or y == null) return false;
            if (x.?.key != y.?.key) return false;
            if (x.?.value != y.?.value) try out.append(gpa, .{ .from(x.?.value), .from(y.?.value) });
        }
    }

    /// κ from the cells at the read's position (header), `extra` arrivals
    /// counted besides them at a summary position; charged per read.
    fn derivedCells(t: *Table, gpa: Allocator, charge: Charge, v: View, cells: SetId, at_summary: bool, dups: SetId, dups_approx: SetId) Error!CondId {
        // At a plain path: `lost` for an approximate cell or `⊤`, the first one
        // found; a set read once costs its cells up to it.
        if (!at_summary) {
            var it = v.cells.sets.iterate(cells);
            while (it.next()) |e| {
                try charge.reserve(gpa, .inspection, 1);
                if (e.value == 1 or v.cells.origin(.from(e.key)) == .top) return lost;
            }
            return yes;
        }
        // `summaryExcl(cells) ∧ apart(cells ⊎ dups)` (*The derivation*): the
        // set's aggregate, memoised per radix node, with the repeats added as
        // second occurrences. Every repeat is a cell of `cells`, one exact
        // where both its occurrences are, and then `cells` holds it exact: so
        // `all` is unchanged, and the repeats join `dups` as sets, approximate
        // where either occurrence is (`dups_approx`, or `cells` holds it so).
        var a = try t.setAgg(gpa, charge, v.cells, v.places, cells);
        if (dups != .none) {
            a.dups = try v.cells.sets.unionWith(gpa, charge, a.dups, dups);
            const old = try v.cells.sets.intersection(gpa, charge, dups, try t.cellPart(gpa, charge, v.cells, v.places, .approx, a.all));
            a.dups_approx = try v.cells.sets.unionWith(gpa, charge, a.dups_approx, try v.cells.sets.unionWith(gpa, charge, dups_approx, old));
        }
        const k = try t.@"and"(gpa, charge, try t.summaryExcl(gpa, charge, v.cells, v.places, cells), try t.aggCond(gpa, charge, v.cells, v.places, a));
        if (std.debug.runtime_safety and full_cross_check) try t.expectSame(gpa, charge, k, try t.derivedCellsFlat(gpa, charge, v, cells, dups, dups_approx));
        return k;
    }

    /// `derivedCells` the old way, a list sorted once (the cross-check's).
    fn derivedCellsFlat(t: *Table, gpa: Allocator, charge: Charge, v: View, cells: SetId, dups: SetId, dups_approx: SetId) Error!CondId {
        var items: std.ArrayList(Item) = .empty;
        defer items.deinit(gpa);
        var dt = v.cells.sets.iterate(dups);
        while (dt.next()) |e| try items.append(gpa, .{ .cell = .from(e.key), .approx = v.cells.sets.member(dups_approx, e.key) });
        var it = v.cells.sets.iterate(cells);
        while (it.next()) |e| try items.append(gpa, .{ .cell = .from(e.key), .approx = e.value == 1 });
        const k = try t.summaryExclFlat(gpa, charge, v.cells, v.places, cells);
        return t.@"and"(gpa, charge, k, try t.apart(gpa, charge, v.cells, v.places, items.items, null));
    }

    /// The part of a cell set a property picks (*The derivation*): `approx`,
    /// the cells held approximately; `unfolded`, the cells a repeat of makes
    /// `shared` (not `⊤`, not standing for many positions). Memoised per radix
    /// node, a node's the union of its halves'. Post-order on an explicit stack.
    const Part = enum(u8) { approx, unfolded };

    fn cellPart(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *const Cell.Places, which: Part, cells: SetId) Error!SetId {
        if (cells == .none) return .none;
        if (cellt.sets.branches(cells) == null) {
            try charge.reserve(gpa, .inspection, 1);
            var it = cellt.sets.iterate(cells);
            const e = it.next().?;
            const kept = switch (which) {
                .approx => e.value == 1,
                .unfolded => cellt.origin(.from(e.key)) != .top and !isFolded(cellt, places, .from(e.key)),
            };
            return if (kept) cells else .none;
        }
        try charge.reserve(gpa, .memo, 1);
        if (t.memo_cell_part.get(.{ @backingInt(which), cells.int() })) |hit| return .from(hit);
        var stack: std.ArrayList(SetId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, cells);
        while (stack.items.len > 0) {
            const x = stack.items[stack.items.len - 1];
            if (t.memo_cell_part.get(.{ @backingInt(which), x.int() }) != null) {
                _ = stack.pop();
                continue;
            }
            const kids = cellt.sets.branches(x).?;
            var halves: [2]SetId = .{ .none, .none };
            var missing = false;
            for (kids, 0..) |kid, i| {
                if (kid == .none) continue;
                if (cellt.sets.branches(kid) == null) {
                    halves[i] = try t.cellPart(gpa, charge, cellt, places, which, kid);
                } else if (t.memo_cell_part.get(.{ @backingInt(which), kid.int() })) |h| {
                    halves[i] = .from(h);
                } else {
                    missing = true;
                    try stack.append(gpa, kid);
                }
            }
            if (missing) continue;
            try charge.reserve(gpa, .memo, 1);
            const got = try cellt.sets.unionWith(gpa, charge, halves[0], halves[1]);
            (try t.memo_cell_part.getOrPut(gpa, .{ @backingInt(which), x.int() })).value_ptr.* = got.int();
            _ = stack.pop();
        }
        return .from(t.memo_cell_part.get(.{ @backingInt(which), cells.int() }).?);
    }

    /// The aggregate of a cell set (`Agg`), a use mark left out: memoised per
    /// radix node, a node's the disjoint join of its two halves' (`aggJoin`).
    /// Post-order on an explicit stack.
    pub fn setAgg(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *const Cell.Places, cells: SetId) Error!Agg {
        if (cells == .none) return .{};
        if (cellt.sets.branches(cells) == null) {
            var it = cellt.sets.iterate(cells);
            const e = it.next().?;
            if (cellt.origin(.from(e.key)) == .mark) return .{};
            return t.aggAdd(gpa, charge, cellt, places, .{}, .from(e.key), e.value == 1, false);
        }
        try charge.reserve(gpa, .memo, 1);
        if (t.memo_set_agg.get(.{cells.int()})) |hit| return t.aggs.items[hit];
        var stack: std.ArrayList(SetId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, cells);
        while (stack.items.len > 0) {
            const x = stack.items[stack.items.len - 1];
            if (t.memo_set_agg.get(.{x.int()}) != null) {
                _ = stack.pop();
                continue;
            }
            try charge.reserve(gpa, .memo, 1);
            const a: Agg = if (cellt.sets.branches(x)) |kids| blk: {
                var halves: [2]Agg = .{ .{}, .{} };
                var missing = false;
                for (kids, 0..) |kid, i| {
                    if (kid == .none) continue;
                    if (t.memo_set_agg.get(.{kid.int()})) |h| halves[i] = t.aggs.items[h] else {
                        missing = true;
                        try stack.append(gpa, kid);
                    }
                }
                if (missing) continue;
                break :blk try t.aggJoin(gpa, charge, cellt, places, halves[0], halves[1]);
            } else blk: {
                var it = cellt.sets.iterate(x);
                const e = it.next().?;
                if (cellt.origin(.from(e.key)) == .mark) break :blk .{};
                break :blk try t.aggAdd(gpa, charge, cellt, places, .{}, .from(e.key), e.value == 1, false);
            };
            const got = try t.agg(gpa, a);
            (try t.memo_set_agg.getOrPut(gpa, .{x.int()})).value_ptr.* = got;
            _ = stack.pop();
        }
        return t.aggs.items[t.memo_set_agg.get(.{cells.int()}).?];
    }

    /// Two aggregates of disjoint cell sets as one, a set's two halves (*The
    /// derivation*): the sets united as they are, the taken-element rule met
    /// across them, and the pairs over a base both bind added as `aggAdd`
    /// adds them, the smaller side's cells of that base one by one. No repeat
    /// arises: the keys are disjoint.
    fn aggJoin(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *const Cell.Places, x: Agg, y: Agg) Error!Agg {
        if (x.all == .none) return y;
        if (y.all == .none) return x;
        try charge.reserve(gpa, .inspection, 1);
        const sets = &cellt.sets;
        var a: Agg = .{
            .all = try sets.unionWith(gpa, charge, x.all, y.all),
            .all_len = x.all_len + y.all_len,
            .dups = try sets.unionWith(gpa, charge, x.dups, y.dups),
            .dups_approx = try sets.unionWith(gpa, charge, x.dups_approx, y.dups_approx),
            .lost_extra = x.lost_extra or y.lost_extra,
            .group = try sets.unionWith(gpa, charge, x.group, y.group),
            .group_len = x.group_len + y.group_len,
            .whole = try sets.unionWith(gpa, charge, x.whole, y.whole),
            .elems = try sets.unionWith(gpa, charge, x.elems, y.elems),
            .pairs = try t.@"and"(gpa, charge, x.pairs, y.pairs),
            .hit = x.hit or y.hit or try sets.intersects(gpa, charge, x.whole, y.elems) or try sets.intersects(gpa, charge, x.elems, y.whole),
        };
        // The bases: the larger side's map, the smaller's bases added to it.
        const big, const small = if (x.group_len >= y.group_len) .{ x, y } else .{ y, x };
        a.bases = big.bases;
        var bt = t.mapEntries(small.bases);
        while (bt.next()) |be| {
            try charge.reserve(gpa, .inspection, 1);
            var same: SetId = if (t.mapGet(a.bases, be.key)) |s| .from(s) else .none;
            if (same == .none) {
                a.bases = try t.mapPut(gpa, charge, a.bases, be.key, be.value);
                continue;
            }
            var ct = sets.iterate(.from(be.value));
            while (ct.next()) |ce| {
                const c: CellId = .from(ce.key);
                const split = splitKey(cellt, c);
                var run: ?CellId = null;
                var run_len: u32 = 0;
                var it = sets.iterate(same);
                while (it.next()) |e| {
                    try charge.reserve(gpa, .inspection, 1);
                    const w: CellId = .from(e.key);
                    if (split[0] != Ids.none_int and std.mem.eql(u32, &split, &splitKey(cellt, w))) {
                        run_len += 1;
                        run = w;
                        continue;
                    }
                    if (cellt.alias(places, c, w) == .no) continue;
                    a.pairs = try t.@"and"(gpa, charge, a.pairs, try t.sep(gpa, charge, cellt, places, c, w, false, null));
                }
                if (run_len == 1) if (run) |w| if (cellt.alias(places, c, w) != .no) {
                    a.pairs = try t.@"and"(gpa, charge, a.pairs, try t.sep(gpa, charge, cellt, places, c, w, false, null));
                };
                same = try sets.insert(gpa, charge, same, c.int(), 0);
            }
            a.bases = try t.mapPut(gpa, charge, a.bases, be.key, same.int());
        }
        return a;
    }

    /// Whether anything below `p` may hold an object.
    fn holdsBelow(places: *const Cell.Places, p: Ids.PlaceId) bool {
        for (places.steps(p).children) |c| if (!places.holds(c).isEmpty()) return true;
        return false;
    }

    // ---- sep, apart, deep, lower ------------------------------------------

    fn isConcrete(o: Cell.Origin) bool {
        return o == .site or o == .result or o == .esc;
    }

    /// Whether `c` stands for possibly several objects: its label is folded
    /// (`⋆`) or its path is at or below a summary position (`[*]`, `⟲`).
    fn isFolded(cellt: *const Cell.Table, places: *const Cell.Places, c: CellId) bool {
        const d = cellt.get(c);
        return switch (d.origin) {
            .site, .top, .mark => false,
            // No label (an asserted row's `taken` element): folded, which claims less.
            .result, .esc => d.a == Ids.none_int or cellt.labelOf(.from(d.a)).folded,
            .cb => d.a == Ids.none_int or cellt.labelOf(.from(d.a)).folded or places.isSummary(.from(d.b)),
            .param, .env, .shared, .msg => places.isSummary(.from(d.b)),
            .elem, .others, .level, .below, .loan => d.b == Ids.none_int or cellt.labelOf(.from(d.b)).folded,
        };
    }

    /// `sep(a, b)` (§2.9) at this path: two distinct concrete cells `yes`;
    /// one unfolded cell twice `shared`, a folded one `lost`; `⊤`/approximate
    /// `lost`; arrivals `alias` tells apart the atom, that may be one `lost`;
    /// a split's two sides its κ; two `taken` elements the traversal rule.
    pub fn sep(t: *Table, gpa: Allocator, charge: Charge, cellt: *const Cell.Table, places: *const Cell.Places, a: CellId, b: CellId, approx: bool, traversal: ?Traversal) Error!CondId {
        try charge.reserve(gpa, .inspection, 1);
        if (approx or cellt.origin(a) == .top or cellt.origin(b) == .top) return lost;
        if (a == b) return if (isFolded(cellt, places, a)) lost else shared;
        const memo = traversal == null;
        const key = [2]u32{ @min(a.int(), b.int()), @max(a.int(), b.int()) };
        if (memo) if (t.memo_sep.get(key)) |hit| return .from(hit);
        const out: CondId = switch (cellt.alias(places, a, b)) {
            .no => if (isConcrete(cellt.origin(a)) or isConcrete(cellt.origin(b))) yes else try t.sepAtom(gpa, charge, a, b),
            .yes => lost,
            .under => |s| blk: {
                const k = cellt.splitOf(s).cond;
                break :blk if (k == .none) lost else k;
            },
            .under_kappa => |container| if (traversal) |tr| (tr.apart(tr.ctx, container, a, b) orelse lost) else lost,
        };
        if (memo) {
            try charge.reserve(gpa, .memo, 1);
            (try t.memo_sep.getOrPut(gpa, key)).value_ptr.* = out.int();
        }
        return out;
    }

    // ---- incremental apart reads (§2.9, #1121) ------------------------------------

    /// `apart` over a cell multiset as a persistent aggregate: a one-cell
    /// extension is one insertion into its predecessor, never a sort of the
    /// old cells again. `all` every distinct cell met (values joined as a
    /// set joins them); `dups` the cells met twice, `dups_approx` those one
    /// of whose occurrences was approximate; `lost_extra` a member's own
    /// approximation (an occurrence `all`'s join forgets); `group` the
    /// arrivals; `whole`/`elems` the parents §2.9's taken-element rule
    /// compares; `bases` base → the group's cells over it; `pairs` the
    /// same-base pairs' conditions; `hit` the taken-element rule met.
    pub const Agg = struct {
        all: SetId = .none,
        all_len: u32 = 0,
        dups: SetId = .none,
        dups_approx: SetId = .none,
        lost_extra: bool = false,
        group: SetId = .none,
        group_len: u32 = 0,
        whole: SetId = .none,
        elems: SetId = .none,
        bases: u32 = Ids.none_int,
        pairs: CondId = yes,
        hit: bool = false,
    };

    fn agg(t: *Table, gpa: Allocator, a: Agg) Error!u32 {
        try t.aggs.append(gpa, a);
        return @intCast(t.aggs.items.len - 1);
    }

    /// `a` with one occurrence of `c` more. `multiset`: a cell met again is
    /// a repeat (two members holding it); otherwise the occurrences join as
    /// a set's do (`a` is one member's reach).
    fn aggAdd(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *const Cell.Places, a0: Agg, c: CellId, approx: bool, multiset: bool) Error!Agg {
        var a = a0;
        try charge.reserve(gpa, .inspection, 1);
        const sets = &cellt.sets;
        if (sets.get(a.all, c.int())) |old| {
            if (multiset) {
                a.dups = try sets.insert(gpa, charge, a.dups, c.int(), 0);
                if (approx or old == 1) a.dups_approx = try sets.insert(gpa, charge, a.dups_approx, c.int(), 0);
            }
            a.all = try sets.insert(gpa, charge, a.all, c.int(), @intFromBool(approx));
            return a;
        }
        a.all = try sets.insert(gpa, charge, a.all, c.int(), @intFromBool(approx));
        a.all_len += 1;
        const o = cellt.origin(c);
        std.debug.assert(o != .mark);
        if (isConcrete(o) or o == .top) return a;
        const before = a.group;
        a.group = try sets.insert(gpa, charge, a.group, c.int(), 0);
        a.group_len += 1;
        try charge.reserve(gpa, .memo, 1);
        const prov = try t.group_prov.getOrPut(gpa, .{a.group.int()});
        if (!prov.found_existing) {
            prov.value_ptr.* = @intCast(t.group_steps.items.len);
            try t.group_steps.append(gpa, .{ before.int(), c.int() });
        }
        // The taken-element rule: a taken element stored beside its
        // container's `c[*]` (`apart`'s `whole`).
        const p = cellt.parent(c);
        const d = cellt.get(c);
        if (o.isSymbolic() and places.pathParent(.from(d.b)) != .none and places.pathStep(.from(d.b)).kind == .elem) {
            a.whole = try sets.insert(gpa, charge, a.whole, p.int(), 0);
            if (sets.member(a.elems, p.int())) a.hit = true;
        }
        if (o == .elem) {
            a.elems = try sets.insert(gpa, charge, a.elems, p.int(), 0);
            if (sets.member(a.whole, p.int())) a.hit = true;
        }
        // The pairs over one base `alias` does not tell apart (`sameBasePairs`):
        // one pair per split's run, every pair across runs.
        const b = cellt.base(c);
        const same: SetId = if (t.mapGet(a.bases, b.int())) |s| .from(s) else .none;
        const split = splitKey(cellt, c);
        var run: ?CellId = null;
        var run_len: u32 = 0;
        var it = sets.iterate(same);
        while (it.next()) |e| {
            try charge.reserve(gpa, .inspection, 1);
            const y: CellId = .from(e.key);
            if (split[0] != Ids.none_int and std.mem.eql(u32, &split, &splitKey(cellt, y))) {
                run_len += 1;
                run = y;
                continue;
            }
            if (cellt.alias(places, c, y) == .no) continue;
            a.pairs = try t.@"and"(gpa, charge, a.pairs, try t.sep(gpa, charge, cellt, places, c, y, false, null));
        }
        if (run_len == 1) if (run) |y| if (cellt.alias(places, c, y) != .no) {
            a.pairs = try t.@"and"(gpa, charge, a.pairs, try t.sep(gpa, charge, cellt, places, c, y, false, null));
        };
        a.bases = try t.mapPut(gpa, charge, a.bases, b.int(), (try sets.insert(gpa, charge, same, c.int(), 0)).int());
        return a;
    }

    fn splitKey(cellt: *const Cell.Table, x: CellId) [2]u32 {
        const o = cellt.origin(x);
        if (o != .elem and o != .others) return .{ Ids.none_int, x.int() };
        const d = cellt.get(x);
        return .{ d.parent.int(), d.b };
    }

    /// Every cell of `from` added to `a` (`multiset` as `aggAdd`).
    fn aggAll(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *const Cell.Places, a0: Agg, from: SetId, multiset: bool) Error!Agg {
        var a = a0;
        var it = cellt.sets.iterate(from);
        while (it.next()) |e| a = try t.aggAdd(gpa, charge, cellt, places, a, .from(e.key), e.value == 1, multiset);
        return a;
    }

    /// Two aggregates as one: the smaller's cells added to the larger's.
    fn aggMerge(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *const Cell.Places, x: Agg, y: Agg, multiset: bool) Error!Agg {
        const big, const small = if (x.all_len >= y.all_len) .{ x, y } else .{ y, x };
        // What the smaller side adds, its subtrees the larger shares
        // skipped whole (a DAG's two sides share most of their reach).
        var added: std.ArrayList(Cell.Radix.Iterator.Entry) = .empty;
        defer added.deinit(gpa);
        try cellt.sets.news(gpa, charge, big.all, small.all, &added);
        var a = big;
        for (added.items) |e| a = try t.aggAdd(gpa, charge, cellt, places, a, .from(e.key), e.value == 1, false);
        if (multiset) {
            // Both sides' cells are repeats, one approximate where either
            // occurrence is; a member's own approximation, which `all`'s join
            // forgets; the smaller side's own repeats.
            const both = try cellt.sets.intersection(gpa, charge, big.all, small.all);
            var it = cellt.sets.iterate(both);
            while (it.next()) |e| {
                try charge.reserve(gpa, .inspection, 1);
                a.dups = try cellt.sets.insert(gpa, charge, a.dups, e.key, 0);
                if (e.value == 1) a.dups_approx = try cellt.sets.insert(gpa, charge, a.dups_approx, e.key, 0);
            }
            a.lost_extra = a.lost_extra or small.lost_extra or try t.anyLost(gpa, charge, cellt, small.all) or try t.anyLost(gpa, charge, cellt, big.all);
            a.dups = try cellt.sets.unionWith(gpa, charge, a.dups, small.dups);
            a.dups_approx = try cellt.sets.unionWith(gpa, charge, a.dups_approx, small.dups_approx);
        }
        return a;
    }

    /// The aggregate of two cell sets as one multiset (an atom's two sides,
    /// `apart [A] [B]`): `aggMerge` of their set aggregates, made along the
    /// two radix tries and memoised per pair of set nodes. Disjoint halves
    /// join structurally (`aggJoin`); a node both sides share is all repeats;
    /// a leaf against a set is one `aggAdd`. So two sets that both grew pay
    /// their changed spines, never the smaller side's size. The recursion is
    /// the key width.
    pub fn aggMergeSets(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *const Cell.Places, a: SetId, b: SetId) Error!Agg {
        var out = try t.aggMergeSetsAt(gpa, charge, cellt, places, a, b);
        // A member's own approximation, which `all`'s join forgets.
        out.lost_extra = out.lost_extra or try t.anyLost(gpa, charge, cellt, a) or try t.anyLost(gpa, charge, cellt, b);
        return out;
    }

    fn aggMergeSetsAt(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *const Cell.Places, a: SetId, b: SetId) Error!Agg {
        if (a == .none) return t.setAgg(gpa, charge, cellt, places, b);
        if (b == .none) return t.setAgg(gpa, charge, cellt, places, a);
        const sets = &cellt.sets;
        if (a == b) {
            // Every cell twice: all repeats, approximate where either is.
            var x = try t.setAgg(gpa, charge, cellt, places, a);
            x.dups = try sets.unionWith(gpa, charge, x.dups, a);
            x.dups_approx = try sets.unionWith(gpa, charge, x.dups_approx, try t.cellPart(gpa, charge, cellt, places, .approx, a));
            return x;
        }
        const key: [2]u32 = .{ @min(a.int(), b.int()), @max(a.int(), b.int()) };
        try charge.reserve(gpa, .memo, 1);
        if (t.memo_agg_pair.get(key)) |hit| return t.aggs.items[hit];
        const na = sets.branches(a);
        const nb = sets.branches(b);
        const out: Agg = blk: {
            if (na == null or nb == null) {
                // A leaf: its one cell added to the other side, a repeat when
                // that side holds it.
                const leaf = if (na == null) a else b;
                const other = if (na == null) b else a;
                var it = sets.iterate(leaf);
                const e = it.next().?;
                const base = try t.setAgg(gpa, charge, cellt, places, other);
                if (cellt.origin(.from(e.key)) == .mark) break :blk base;
                break :blk try t.aggAdd(gpa, charge, cellt, places, base, .from(e.key), e.value == 1, true);
            }
            const ra = sets.radixNode(a);
            const rb = sets.radixNode(b);
            if (ra.mask == rb.mask and ra.prefix == rb.prefix) break :blk try t.aggJoin(gpa, charge, cellt, places, try t.aggMergeSetsAt(gpa, charge, cellt, places, na.?[0], nb.?[0]), try t.aggMergeSetsAt(gpa, charge, cellt, places, na.?[1], nb.?[1]));
            if (ra.mask > rb.mask and sets.under(rb.prefix, ra.prefix, ra.mask)) {
                const zero = sets.zeroAt(rb.prefix, ra.mask);
                break :blk try t.aggJoin(gpa, charge, cellt, places, try t.aggMergeSetsAt(gpa, charge, cellt, places, if (zero) na.?[0] else na.?[1], b), try t.setAgg(gpa, charge, cellt, places, if (zero) na.?[1] else na.?[0]));
            }
            if (rb.mask > ra.mask and sets.under(ra.prefix, rb.prefix, rb.mask)) {
                const zero = sets.zeroAt(ra.prefix, rb.mask);
                break :blk try t.aggJoin(gpa, charge, cellt, places, try t.aggMergeSetsAt(gpa, charge, cellt, places, a, if (zero) nb.?[0] else nb.?[1]), try t.setAgg(gpa, charge, cellt, places, if (zero) nb.?[1] else nb.?[0]));
            }
            // Disjoint prefixes: no repeat.
            break :blk try t.aggJoin(gpa, charge, cellt, places, try t.setAgg(gpa, charge, cellt, places, a), try t.setAgg(gpa, charge, cellt, places, b));
        };
        const got = try t.agg(gpa, out);
        (try t.memo_agg_pair.getOrPut(gpa, key)).value_ptr.* = got;
        return out;
    }

    /// `aggMerge` of two multisets (an atom's sides): an empty side is the
    /// other, as it is.
    pub fn aggMergeMulti(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *const Cell.Places, x: Agg, y: Agg) Error!Agg {
        if (x.all == .none) return y;
        if (y.all == .none) return x;
        return t.aggMerge(gpa, charge, cellt, places, x, y, true);
    }

    /// §2.9's apart condition of an aggregate: `apart`'s over its cells.
    pub fn aggCond(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *const Cell.Places, a: Agg) Error!CondId {
        // A cell met twice: `sep(c, c)` (§2.9), `shared` for one exact, not `⊤`
        // and standing for one position, `lost` otherwise. Decided over the
        // repeats' set: memoised per radix node, never cell by cell.
        var acc: CondId = yes;
        if (a.dups != .none) {
            if (!try cellt.sets.keysWithin(gpa, charge, try t.cellPart(gpa, charge, cellt, places, .unfolded, a.dups), a.dups_approx)) return shared;
            acc = lost;
        }
        if (a.lost_extra or try t.anyLost(gpa, charge, cellt, a.all)) acc = try t.@"and"(gpa, charge, acc, lost);
        if (a.group_len >= 2) {
            if (a.hit) return shared;
            acc = try t.@"and"(gpa, charge, acc, try t.apartAtom(gpa, charge, a.group));
            acc = try t.@"and"(gpa, charge, acc, a.pairs);
        }
        return acc;
    }

    /// Whether a cell set holds an approximate pair or `⊤`, memoised per
    /// node of the persistent set, so a new root reads its changed spine.
    fn anyLost(t: *Table, gpa: Allocator, charge: Charge, cellt: *const Cell.Table, s: SetId) Error!bool {
        if (s == .none) return false;
        // One cell: read at once, never memoised.
        if (cellt.sets.branches(s) == null) {
            try charge.reserve(gpa, .inspection, 1);
            var it = cellt.sets.iterate(s);
            const e = it.next().?;
            return e.value == 1 or cellt.origin(.from(e.key)) == .top;
        }
        try charge.reserve(gpa, .memo, 1);
        if (t.lost_memo.get(.{s.int()})) |v| return v == 1;
        var stack: std.ArrayList(SetId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, s);
        while (stack.items.len > 0) {
            const x = stack.items[stack.items.len - 1];
            if (t.lost_memo.get(.{x.int()}) != null) {
                _ = stack.pop();
                continue;
            }
            try charge.reserve(gpa, .inspection, 1);
            const v: bool = if (cellt.sets.branches(x)) |kids| blk: {
                const l = t.lost_memo.get(.{kids[0].int()});
                const r = t.lost_memo.get(.{kids[1].int()});
                if (l == null or r == null) {
                    if (l == null) try stack.append(gpa, kids[0]);
                    if (r == null) try stack.append(gpa, kids[1]);
                    continue;
                }
                break :blk l.? == 1 or r.? == 1;
            } else blk: {
                var it = cellt.sets.iterate(x);
                const e = it.next().?;
                break :blk e.value == 1 or cellt.origin(.from(e.key)) == .top;
            };
            (try t.lost_memo.getOrPut(gpa, .{x.int()})).value_ptr.* = @intFromBool(v);
            _ = stack.pop();
        }
        return t.lost_memo.get(.{s.int()}).? == 1;
    }

    /// The aggregate of `n`'s reach (every cell of its explicit structure,
    /// as a set), memoised per node: a node of finite rank merges its
    /// parts' aggregates, the larger extended by the smaller's cells and its
    /// own (so a tower's level adds its own cells, O(log) each); a node on
    /// or above a cycle, from its reach set.
    pub fn reachAgg(t: *Table, gpa: Allocator, charge: Charge, v: View, n: NodeId) Error!Agg {
        try charge.reserve(gpa, .memo, 1);
        if (t.reachMemo(v, n)) |hit| return t.aggs.items[hit];
        const walk = try v.shapes.dagWalk(gpa, charge.account, n);
        defer if (walk) |k| charge.account.leave(k);
        // Post-order over the parts on an explicit stack (a value is as
        // deep as the source). A part met again while it is open is on a
        // cycle: a node whose part has no aggregate yet takes its own from
        // its reach set (`Shape.reach` closes the cycle), so only a cycle,
        // never a recast or a deep DAG, reads a whole reach.
        const Frame = struct { node: NodeId, expanded: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        const open = try t.marks.take(gpa);
        defer t.marks.give(open);
        var parts: std.ArrayList(NodeId) = .empty;
        defer parts.deinit(gpa);
        try stack.append(gpa, .{ .node = n, .expanded = false });
        while (stack.pop()) |f| {
            if (t.reachMemo(v, f.node) != null) continue;
            parts.clearRetainingCapacity();
            try partsOf(gpa, charge, v, f.node, &parts);
            if (!f.expanded) {
                if (open.contains(f.node)) continue;
                try open.put(gpa, f.node, {});
                try stack.append(gpa, .{ .node = f.node, .expanded = true });
                for (parts.items) |p| if (t.reachMemo(v, p) == null) try stack.append(gpa, .{ .node = p, .expanded = false });
                continue;
            }
            open.remove(f.node);
            // The largest part's aggregate, the others' and the node's own
            // cells added to it.
            var best: ?Agg = null;
            const whole = for (parts.items) |p| {
                try charge.reserve(gpa, .memo, 1);
                const pi = t.reachMemo(v, p) orelse break true;
                const pa = t.aggs.items[pi];
                best = if (best) |b| try t.aggMerge(gpa, charge, v.cells, v.places, b, pa, false) else pa;
            } else false;
            const a = if (whole)
                try t.aggAll(gpa, charge, v.cells, v.places, .{}, try v.shapes.reach(gpa, charge.account, &v.cells.sets, f.node), false)
            else
                try t.aggAll(gpa, charge, v.cells, v.places, best orelse .{}, if (v.shapes.isLazy(f.node)) SetId.none else v.shapes.cells(f.node), false);
            const got = try t.agg(gpa, a);
            (try t.reach_agg.getOrPut(gpa, .{f.node.int()})).value_ptr.* = got;
            (try t.reach_epoch.getOrPut(gpa, .{f.node.int()})).value_ptr.* = v.shapes.ties;
        }
        return t.aggs.items[t.reachMemo(v, n).?];
    }

    /// `n`'s reach aggregate, if made since the last knot was tied.
    fn reachMemo(t: *const Table, v: View, n: NodeId) ?u32 {
        const at = t.reach_agg.get(.{n.int()}) orelse return null;
        return if (t.reach_epoch.get(.{n.int()}) == v.shapes.ties) at else null;
    }

    /// The parts of `n` whose cells its reach holds.
    fn partsOf(gpa: Allocator, charge: Charge, v: View, n: NodeId, out: *std.ArrayList(NodeId)) Error!void {
        const d = v.shapes.get(n);
        switch (d.kind) {
            .leaf => {},
            .node, .delta => {
                if (d.kind == .delta) try out.append(gpa, .from(d.a));
                var it = v.shapes.overEntries(if (d.kind == .node) d.a else d.b);
                while (it.next()) |e| try out.append(gpa, e.node);
            },
            .recast => try out.append(gpa, .from(d.a)),
            .@"union", .choice, .positions => try out.appendSlice(gpa, &.{ .from(d.a), .from(d.b) }),
            // A view holds what its answer holds (§2.11).
            .view => try out.append(gpa, try v.shapes.force(gpa, charge.account, n)),
        }
    }

    /// The apart condition of `group`'s cells' images (`image` maps one), a
    /// multiset: each group is extended from its predecessor's image
    /// (`group_prov`), `memo` holding the images built under this `image`.
    pub fn apartImage(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *const Cell.Places, group: SetId, memo: *Ids.FixedDict(1), ctx: anytype, image: *const fn (@TypeOf(ctx), CellId) Error!CellId) Error!CondId {
        var chain: std.ArrayList([2]u32) = .empty;
        defer chain.deinit(gpa);
        var at = group;
        var start: Agg = .{};
        var base: SetId = .none;
        while (at != .none) {
            try charge.reserve(gpa, .memo, 1);
            if (memo.get(.{at.int()})) |hit| {
                start = t.aggs.items[hit];
                break;
            }
            // A set no aggregate built: its cells from nothing.
            const step = t.group_prov.get(.{at.int()}) orelse {
                base = at;
                break;
            };
            const s = t.group_steps.items[step];
            try chain.append(gpa, .{ at.int(), s[1] });
            at = .from(s[0]);
        }
        // New cells imaged in set order: `image` numbers by content (#1150).
        var fresh: std.ArrayList(u32) = .empty;
        defer fresh.deinit(gpa);
        var bt = cellt.sets.iterate(base);
        while (bt.next()) |e| try fresh.append(gpa, e.key);
        for (chain.items) |x| try fresh.append(gpa, x[1]);
        std.mem.sort(u32, fresh.items, {}, std.sort.asc(u32));
        for (fresh.items) |c| {
            try charge.reserve(gpa, .inspection, 1);
            _ = try image(ctx, .from(c));
        }
        if (base != .none) {
            var it = cellt.sets.iterate(base);
            while (it.next()) |e| start = try t.aggAdd(gpa, charge, cellt, places, start, try image(ctx, .from(e.key)), false, true);
            const got = try t.agg(gpa, start);
            (try memo.getOrPut(gpa, .{base.int()})).value_ptr.* = got;
        }
        var a = start;
        while (chain.pop()) |x| {
            a = try t.aggAdd(gpa, charge, cellt, places, a, try image(ctx, .from(x[1])), false, true);
            const got = try t.agg(gpa, a);
            (try memo.getOrPut(gpa, .{x[0]})).value_ptr.* = got;
        }
        return t.aggCond(gpa, charge, cellt, places, a);
    }

    // ---- the path-multiset primitive (§2.9, #1128) --------------------------------

    /// Per destination class (a widened image node), the aggregate of the
    /// source occurrences μ maps into it: a persistent map image → `aggs`
    /// index, and how many classes it names (for merging small into large).
    /// `saturated`: a cyclic source, every class it reaches all repeated.
    pub const ClassAggs = struct { map: u32 = Ids.none_int, len: u32 = 0, saturated: bool = false };

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
        const w = try v.shapes.widenFold(gpa, charge.account, v.places, v.cells, x, &fold);
        if (w == x) return .{ .node = x, .kappas = kx };
        const per = try t.arrivalAggs(gpa, charge, v, x, &fold);
        var it = t.mapEntries(per.map);
        while (it.next()) |e| {
            if (!fold.folded.contains(.from(e.key)) and !per.saturated) continue;
            try charge.reserve(gpa, .inspection, 1);
            try t.fold_cond.put(gpa, .from(e.key), try t.foldCond(gpa, charge, v.cells, v.places, t.aggs.items[e.value]));
            t.fold_cond_n += 1;
        }
        return .{ .node = w, .kappas = try t.propagate(gpa, charge, v, .none, w, &.{x}, &.{kx}, .alternatives, false, null) };
    }

    // ---- the path-multiset primitive for a client's walk (#1159) ---------------------

    /// One key holding each of `cells` once: a source node's own contents at
    /// its position (a cell's approximation is its set value).
    pub fn classesOf(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *const Cell.Places, key: u32, cells: SetId) Error!ClassAggs {
        if (cells == .none) return .{};
        const a = try t.aggAll(gpa, charge, cellt, places, .{}, cells, false);
        return .{ .map = try t.mapPut(gpa, charge, Ids.none_int, key, try t.agg(gpa, a)), .len = 1 };
    }

    /// Two contributions as one: coexisting (`together`, a multiset sum) or
    /// a choice's arms (the maximum, whole arm by whole arm).
    pub fn classesMerge(t: *Table, gpa: Allocator, charge: Charge, v: View, x: ClassAggs, y: ClassAggs, together: bool) Error!ClassAggs {
        if (x.len == 0) return y;
        if (y.len == 0) return x;
        return t.classMerge(gpa, charge, v, x, y, together);
    }

    /// Every occurrence repeated: a source on a cycle reaches each key below
    /// it at unboundedly many coexisting positions.
    pub fn classesRepeated(t: *Table, gpa: Allocator, charge: Charge, x: ClassAggs) Error!ClassAggs {
        var out: ClassAggs = .{ .saturated = true };
        var it = t.mapEntries(x.map);
        while (it.next()) |e| {
            try charge.reserve(gpa, .inspection, 1);
            var a = t.aggs.items[e.value];
            a.dups = a.all;
            out.map = try t.mapPut(gpa, charge, out.map, e.key, try t.agg(gpa, a));
            out.len += 1;
        }
        return out;
    }

    /// The obligation of the occurrences at `key` (§2.9's three parts): a
    /// repeat `lost` (through a fold, never `shared`), distinct arrivals
    /// `apart`, and `summaryExcl` — `excl c` — for each symbolic arrival at
    /// a summary path, which stands for many objects whose own separation is
    /// its holder's (#1199); `yes` where no occurrence maps.
    pub fn classesRead(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *const Cell.Places, x: ClassAggs, key: u32) Error!CondId {
        try charge.reserve(gpa, .memo, 1);
        const a = t.mapGet(x.map, key) orelse return yes;
        var k = try t.foldCond(gpa, charge, cellt, places, t.aggs.items[a]);
        var it = cellt.sets.iterate(t.aggs.items[a].all);
        while (it.next()) |e| {
            try charge.reserve(gpa, .inspection, 1);
            const c: CellId = .from(e.key);
            const o = cellt.origin(c);
            if (o.isSymbolic() and o != .top and places.isSummary(.from(cellt.get(c).b))) k = try t.@"and"(gpa, charge, k, try t.excl(gpa, charge, c));
        }
        return k;
    }

    /// The cells occurring at `key`, as a set (their approximation kept).
    pub fn classesCells(t: *const Table, x: ClassAggs, key: u32) SetId {
        const a = t.mapGet(x.map, key) orelse return .none;
        return t.aggs.items[a].all;
    }

    /// A client walk's result by `(node, key)`, kept across reads and calls:
    /// both are immutable, so an answer is never stale. Charged, hit or miss.
    pub fn classesMemo(t: *Table, gpa: Allocator, charge: Charge, n: NodeId, key: u32) Error!?ClassAggs {
        try charge.reserve(gpa, .memo, 1);
        const i = t.classes_memo.get(.{ n.int(), key }) orelse return null;
        return t.classes_done.items[i];
    }

    pub fn classesRemember(t: *Table, gpa: Allocator, charge: Charge, n: NodeId, key: u32, x: ClassAggs) Error!void {
        try charge.reserve(gpa, .memo, 1);
        try t.classes_done.ensureUnusedCapacity(gpa, 1);
        const got = try t.classes_memo.getOrPut(gpa, .{ n.int(), key });
        if (got.found_existing) return;
        got.value_ptr.* = @intCast(t.classes_done.items.len);
        t.classes_done.appendAssumeCapacity(x);
    }

    /// The fold obligations a read of `n` meets at its own position: its
    /// own, and through a union, choice or positions DAG its sides' (a class
    /// image rides there beside the class's other members).
    fn foldCondOf(t: *Table, gpa: Allocator, charge: Charge, v: View, n: NodeId) Error!CondId {
        if (t.fold_cond_n == 0) return yes;
        // Memoised per node: `fold_cond` only gains entries for fresh image
        // ids, which no existing DAG holds, so an answer never goes stale.
        try charge.reserve(gpa, .memo, 1);
        if (t.fold_of.get(n)) |hit| return hit;
        return t.foldCondWalk(gpa, charge, v, n);
    }

    /// `foldCondOf`'s walk: one Tarjan walk (`Shape.Table.cycleWalk`) over
    /// a union's, a choice's or a positions node's sides and a view's
    /// answer, so a cycle of them with no node on it (#1335) ends at its
    /// least fixed point: every member owes what every member owns and what
    /// enters the cycle (§2.11 *A cycle with no node on it*).
    fn foldCondWalk(t: *Table, gpa: Allocator, charge: Charge, v: View, n: NodeId) Error!CondId {
        var w: FoldWalk = .{ .t = t, .gpa = gpa, .charge = charge, .v = v };
        try v.shapes.cycleWalk(gpa, n, &w);
        return t.fold_of.get(n).?;
    }

    /// `foldCondWalk`'s relation. A record whose parts are answered already
    /// is answered on entry, so a chain of unions costs each its own node
    /// once, a record that waited once more, as the post-order on a stack did.
    const FoldWalk = struct {
        t: *Table,
        gpa: Allocator,
        charge: Charge,
        v: View,

        /// The right side first; a view's answer.
        fn parts(w: *FoldWalk, x: NodeId) Error![2]NodeId {
            const shapes = w.v.shapes;
            return switch (shapes.kind(x)) {
                .@"union", .choice, .positions => .{ .from(shapes.get(x).b), .from(shapes.get(x).a) },
                .view => .{ try shapes.force(w.gpa, w.charge.account, x), .none },
                else => .{ .none, .none },
            };
        }

        /// `x`'s own certificate and its parts' answers, the left side's
        /// first, or null while a part has none.
        fn answer(w: *FoldWalk, x: NodeId, two: [2]NodeId) Error!?CondId {
            const t = w.t;
            const acc: CondId = t.fold_cond.get(x) orelse yes;
            if (two[0] == .none) return acc;
            const r = t.fold_of.get(two[0]) orelse return null;
            if (two[1] == .none) return try t.@"and"(w.gpa, w.charge, acc, r);
            const l = t.fold_of.get(two[1]) orelse return null;
            return try t.@"and"(w.gpa, w.charge, acc, try t.@"and"(w.gpa, w.charge, l, r));
        }

        pub fn from(w: *FoldWalk, x: NodeId) Error![2]NodeId {
            try w.charge.reserve(w.gpa, .inspection, 1);
            const two = try w.parts(x);
            if (try w.answer(x, two)) |k| try w.t.fold_of.put(w.gpa, x, k);
            return two;
        }

        pub fn settled(w: *const FoldWalk, x: NodeId) bool {
            return w.t.fold_of.get(x) != null;
        }

        pub fn settle(w: *FoldWalk, members: []const NodeId) Error!void {
            const t = w.t;
            if (members.len == 1 and w.settled(members[0])) return;
            try w.charge.reserve(w.gpa, .inspection, @intCast(members.len));
            if (members.len == 1) {
                const two = try w.parts(members[0]);
                if (try w.answer(members[0], two)) |k| return t.fold_of.put(w.gpa, members[0], k);
            }
            // A cycle: what its members own, and what enters it.
            var acc: CondId = yes;
            for (members) |m| {
                acc = try t.@"and"(w.gpa, w.charge, acc, t.fold_cond.get(m) orelse yes);
                for (try w.parts(m)) |y| if (y != .none) if (t.fold_of.get(y)) |k| {
                    acc = try t.@"and"(w.gpa, w.charge, acc, k);
                };
            }
            // A fixed point by construction: each member owes every
            // conjunct of every member.
            for (members) |m| try t.fold_of.put(w.gpa, m, acc);
        }
    };

    /// A folded class's obligation from its aggregate: a repeat is
    /// identified through the fold (`lost`, never `shared`: the levels it
    /// merged were never compared), distinct arrivals `apart`.
    fn foldCond(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *const Cell.Places, a: Agg) Error!CondId {
        var plain = a;
        plain.dups = .none;
        plain.dups_approx = .none;
        const k = try t.aggCond(gpa, charge, cellt, places, plain);
        return if (a.dups != .none) t.@"and"(gpa, charge, k, lost) else k;
    }

    /// The aggregates of `x`'s source occurrences by destination class: a
    /// post-order over the source on an explicit stack (a value is as deep
    /// as the source), each node's own cells at its image with its parts'
    /// aggregates, every node once (shared parts are re-read by reference,
    /// so two routes count twice where they coexist and once where they are
    /// a choice). A source on a cycle has no finite multiset by this walk:
    /// every class it reaches reads all its cells repeated (sound, `lost`).
    fn arrivalAggs(t: *Table, gpa: Allocator, charge: Charge, v: View, x: NodeId, fold: *const Shape.Table.Fold) Error!ClassAggs {
        var memo: stamped.Column(NodeId, ClassAggs) = .{};
        defer memo.deinit(gpa);
        var open: stamped.Column(NodeId, void) = .{};
        defer open.deinit(gpa);
        const Frame = struct { node: NodeId, expanded: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        var parts: std.ArrayList(NodeId) = .empty;
        defer parts.deinit(gpa);
        var cyclic = false;
        // The widen walked answers: a view root is read at its answer.
        try stack.append(gpa, .{ .node = try v.shapes.force(gpa, charge.account, x), .expanded = false });
        while (stack.pop()) |f| {
            if (memo.get(f.node) != null) continue;
            parts.clearRetainingCapacity();
            try sourceParts(gpa, charge, v, fold, f.node, &parts);
            // An opened choice's arms: the maximum, arm by arm (§2.3).
            const arms = v.shapes.kind(f.node) == .choice and fold.opened.contains(f.node);
            if (!f.expanded) {
                if (open.contains(f.node)) {
                    cyclic = true;
                    continue;
                }
                try open.put(gpa, f.node, {});
                try stack.append(gpa, .{ .node = f.node, .expanded = true });
                for (parts.items) |p| if (memo.get(p) == null) try stack.append(gpa, .{ .node = p, .expanded = false });
                continue;
            }
            open.remove(f.node);
            if (cyclic) break;
            var acc: ClassAggs = .{};
            for (parts.items, 0..) |p, i| {
                try charge.reserve(gpa, .memo, 1);
                const pa = memo.get(p) orelse {
                    cyclic = true;
                    break;
                };
                acc = if (i == 0) pa else try t.classMerge(gpa, charge, v, acc, pa, !arms);
            }
            if (cyclic) break;
            if (fold.image.get(f.node)) |img| {
                const own = try t.ownAgg(gpa, charge, v, fold, f.node);
                if (own.all_len > 0) acc = try t.classMerge(gpa, charge, v, acc, .{ .map = try t.mapPut(gpa, charge, Ids.none_int, img.int(), try t.agg(gpa, own)), .len = 1 }, true);
            }
            try memo.put(gpa, f.node, acc);
        }
        if (!cyclic) return memo.get(v.shapes.forced(x)).?;
        // On a cycle: every source node's cells at its class, all repeated.
        var all: stamped.Column(NodeId, SetId) = .{};
        defer all.deinit(gpa);
        var images: std.ArrayList(NodeId) = .empty;
        defer images.deinit(gpa);
        var seen: stamped.Column(NodeId, void) = .{};
        defer seen.deinit(gpa);
        var walk: std.ArrayList(NodeId) = .empty;
        defer walk.deinit(gpa);
        try walk.append(gpa, try v.shapes.force(gpa, charge.account, x));
        while (walk.pop()) |n| {
            if (seen.contains(n)) continue;
            try seen.put(gpa, n, {});
            try charge.reserve(gpa, .inspection, 1);
            if (fold.image.get(n)) |img| {
                const old = all.get(img) orelse blk: {
                    try images.append(gpa, img);
                    break :blk SetId.none;
                };
                try all.put(gpa, img, try v.cells.sets.unionWith(gpa, charge, old, if (v.shapes.isLazy(n)) SetId.none else v.shapes.cells(n)));
            }
            parts.clearRetainingCapacity();
            try sourceParts(gpa, charge, v, fold, n, &parts);
            try walk.appendSlice(gpa, parts.items);
        }
        var out: ClassAggs = .{ .saturated = true };
        for (images.items) |img| {
            const cells = all.get(img).?;
            var a = try t.aggAll(gpa, charge, v.cells, v.places, .{}, cells, false);
            a.dups = cells;
            out.map = try t.mapPut(gpa, charge, out.map, img.int(), try t.agg(gpa, a));
            out.len += 1;
        }
        return out;
    }

    /// The parts of source node `n` the widen walked: its explicit
    /// children, an opened union's, choice's or positions node's sides. They
    /// coexist, except an opened choice's arms, which the caller takes by the
    /// maximum (§2.3: two source occurrences add, one execution has one arm).
    fn sourceParts(gpa: Allocator, charge: Charge, v: View, fold: *const Shape.Table.Fold, n: NodeId, out: *std.ArrayList(NodeId)) Error!void {
        const from = out.items.len;
        defer for (out.items[from..]) |*p| {
            // The widen forced each child as it descended: its source nodes are answers.
            p.* = v.shapes.forced(p.*);
        };
        const d = v.shapes.get(n);
        switch (d.kind) {
            .@"union", .choice, .positions => if (fold.opened.contains(n)) try out.appendSlice(gpa, &.{ .from(d.a), .from(d.b) }),
            .node => {
                var it = v.shapes.overEntries(d.a);
                while (it.next()) |e| try out.append(gpa, e.node);
            },
            .delta => {
                var it = v.shapes.overEntries(d.b);
                while (it.next()) |e| try out.append(gpa, e.node);
                const base = try v.shapes.force(gpa, charge.account, .from(d.a));
                if (v.shapes.kind(base) == .node) {
                    var bt = v.shapes.overEntries(v.shapes.get(base).a);
                    while (bt.next()) |e| if (v.shapes.overGet(d.b, e.step) == null) try out.append(gpa, e.node);
                }
            },
            .leaf, .recast => {},
            .view => unreachable, // the widen walked answers, never views
        }
    }

    /// The cells source node `n` itself holds at its class, as a set: a
    /// leaf's, a node's, a delta's, a union's, choice's or positions node's kept
    /// whole (its sides' set; what it repeats inside is `dagKappa`'s), a
    /// recast's approximate. An opened one holds nothing of its own.
    fn ownAgg(t: *Table, gpa: Allocator, charge: Charge, v: View, fold: *const Shape.Table.Fold, n: NodeId) Error!Agg {
        const d = v.shapes.get(n);
        if ((d.kind == .@"union" or d.kind == .choice or d.kind == .positions) and fold.opened.contains(n)) return .{};
        const own = try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, n);
        if (d.kind != .recast) return t.aggAll(gpa, charge, v.cells, v.places, .{}, own, false);
        var a: Agg = .{};
        var it = v.cells.sets.iterate(own);
        while (it.next()) |e| a = try t.aggAdd(gpa, charge, v.cells, v.places, a, .from(e.key), true, false);
        return a;
    }

    /// Two arms of a choice: a cell in both is still one (the maximum), a
    /// repeat in either stays a repeat.
    fn aggChoice(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *const Cell.Places, x: Agg, y: Agg) Error!Agg {
        const big, const small = if (x.all_len >= y.all_len) .{ x, y } else .{ y, x };
        var a = try t.aggMerge(gpa, charge, cellt, places, big, small, false);
        a.dups = try cellt.sets.unionWith(gpa, charge, a.dups, small.dups);
        a.dups_approx = try cellt.sets.unionWith(gpa, charge, a.dups_approx, small.dups_approx);
        a.lost_extra = a.lost_extra or small.lost_extra;
        return a;
    }

    /// Two class maps as one, coexisting: each class the smaller names
    /// merged into the larger's as a multiset.
    fn classMerge(t: *Table, gpa: Allocator, charge: Charge, v: View, x: ClassAggs, y: ClassAggs, together: bool) Error!ClassAggs {
        const big, const small = if (x.len >= y.len) .{ x, y } else .{ y, x };
        var out = big;
        var it = t.mapEntries(small.map);
        while (it.next()) |e| {
            try charge.reserve(gpa, .inspection, 1);
            const b = t.aggs.items[e.value];
            const merged: Agg = if (t.mapGet(out.map, e.key)) |o| (if (together) try t.aggMerge(gpa, charge, v.cells, v.places, t.aggs.items[o], b, true) else try t.aggChoice(gpa, charge, v.cells, v.places, t.aggs.items[o], b)) else blk: {
                out.len += 1;
                break :blk b;
            };
            out.map = try t.mapPut(gpa, charge, out.map, e.key, try t.agg(gpa, merged));
        }
        return out;
    }

    /// §2.9's rule over the cells stored at one path, a multiset sorted once
    /// (an item a record): a duplicate decides at once, `⊤`/approximate is
    /// `lost`, the arrivals form ONE `apart` group, pairs over one base are
    /// decided one by one; concrete cells are apart by construction.
    /// `items` is scratch and is reordered.
    pub fn apart(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *const Cell.Places, items: []Item, traversal: ?Traversal) Error!CondId {
        try charge.reserve(gpa, .inspection, @intCast(items.len));
        std.mem.sort(Item, items, {}, struct {
            fn lessThan(_: void, x: Item, y: Item) bool {
                return x.cell.int() < y.cell.int();
            }
        }.lessThan);
        var acc: CondId = yes;
        var arrivals: std.ArrayList(CellId) = .empty;
        defer arrivals.deinit(gpa);
        var i: usize = 0;
        while (i < items.len) {
            var j = i + 1;
            var any_approx = items[i].approx;
            while (j < items.len and items[j].cell == items[i].cell) : (j += 1) any_approx = any_approx or items[j].approx;
            const c = items[i].cell;
            if (j - i >= 2) {
                acc = try t.@"and"(gpa, charge, acc, try t.sep(gpa, charge, cellt, places, c, c, any_approx, traversal));
                if (acc == shared) return shared;
            }
            const o = cellt.origin(c);
            if (any_approx or o == .top) acc = try t.@"and"(gpa, charge, acc, lost);
            std.debug.assert(o != .mark);
            if (!isConcrete(o) and o != .top) try arrivals.append(gpa, c);
            i = j;
        }
        if (arrivals.items.len >= 2) {
            var group: SetId = .none;
            for (arrivals.items) |c| group = try cellt.sets.insert(gpa, charge, group, c.int(), 0);
            // A taken element stored back beside its container's `c[*]` (not
            // `others`): one object at two positions (§2.9's `shared`, P5).
            var whole: SetId = .none;
            for (arrivals.items) |c| {
                const o = cellt.origin(c);
                if (!o.isSymbolic() or o == .top) continue;
                if (places.pathParent(.from(cellt.get(c).b)) == .none or places.pathStep(.from(cellt.get(c).b)).kind != .elem) continue;
                whole = try cellt.sets.insert(gpa, charge, whole, cellt.parent(c).int(), 0);
            }
            if (whole != .none) for (arrivals.items) |c| if (cellt.origin(c) == .elem) {
                try charge.reserve(gpa, .inspection, 1);
                if (cellt.sets.member(whole, cellt.parent(c).int())) return shared;
            };
            acc = try t.@"and"(gpa, charge, acc, try t.apartAtom(gpa, charge, group));
            acc = try t.@"and"(gpa, charge, acc, try t.sameBasePairs(gpa, charge, cellt, places, arrivals.items, traversal));
        }
        return acc;
    }

    /// The pairs of `arrivals` over one base that `alias` does not tell apart.
    fn sameBasePairs(t: *Table, gpa: Allocator, charge: Charge, cellt: *const Cell.Table, places: *const Cell.Places, arrivals: []CellId, traversal: ?Traversal) Error!CondId {
        var acc: CondId = yes;
        // By base, then by split: one split's members answer `sep` alike
        // (`under` it), so its run is one pair; runs pair across (linear).
        const Ctx = struct {
            cellt: *const Cell.Table,
            fn split(ctx: @This(), x: CellId) [2]u32 {
                const o = ctx.cellt.origin(x);
                if (o != .elem and o != .others) return .{ Ids.none_int, x.int() };
                const d = ctx.cellt.get(x);
                return .{ d.parent.int(), d.b };
            }
        };
        const ctx: Ctx = .{ .cellt = cellt };
        std.mem.sort(CellId, arrivals, ctx, struct {
            fn lessThan(c: Ctx, x: CellId, y: CellId) bool {
                const bx = c.cellt.base(x).int();
                const by = c.cellt.base(y).int();
                if (bx != by) return bx < by;
                const sx = c.split(x);
                const sy = c.split(y);
                if (sx[0] != sy[0]) return sx[0] < sy[0];
                if (sx[1] != sy[1]) return sx[1] < sy[1];
                return x.int() < y.int();
            }
        }.lessThan);
        var k: usize = 0;
        while (k < arrivals.len) {
            var m = k + 1;
            while (m < arrivals.len and cellt.base(arrivals[m]) == cellt.base(arrivals[k])) m += 1;
            // The runs of one split in [k, m).
            var x = k;
            while (x < m) {
                var e = x + 1;
                while (e < m and std.mem.eql(u32, &ctx.split(arrivals[e]), &ctx.split(arrivals[x])) and ctx.split(arrivals[x])[0] != Ids.none_int) e += 1;
                if (e - x >= 2) {
                    try charge.reserve(gpa, .inspection, @intCast(e - x));
                    if (cellt.alias(places, arrivals[x], arrivals[x + 1]) != .no) {
                        acc = try t.@"and"(gpa, charge, acc, try t.sep(gpa, charge, cellt, places, arrivals[x], arrivals[x + 1], false, traversal));
                        if (acc == shared) return shared;
                    }
                }
                // Against every later run.
                for (arrivals[x..e]) |a| for (arrivals[e..m]) |b| {
                    try charge.reserve(gpa, .inspection, 1);
                    if (cellt.alias(places, a, b) == .no) continue; // in the group
                    acc = try t.@"and"(gpa, charge, acc, try t.sep(gpa, charge, cellt, places, a, b, false, traversal));
                    if (acc == shared) return shared;
                };
                x = e;
            }
            k = m;
        }
        return acc;
    }

    /// The deep condition of a node: κ of every node of its explicit
    /// structure and `excl c` for every arrival among their cells, each
    /// read at its own position of the snapshot (`ctx` is `n`'s) (*`deep`*).
    /// A walk over states `(position, node, class, explicit)`, post-order on
    /// an explicit stack: a state's answer is the `and` of its own part and
    /// its frontier's answers. An explicit state's answer is a function of
    /// its key, kept canonical in `memo_deep` and taken from there when met
    /// again, in this read or a later one. A state met again while it is open
    /// (a fold, a knot) adds nothing more, and the read then keeps no inner
    /// entry. Below a re-root view the walk carries the crossing's pairs
    /// (*Carried along the walk*): a node wholly of the actual's region is
    /// read at `R_Q`, where earlier reads met it.
    pub fn deep(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, at_summary: bool) Error!CondId {
        return t.resolved(gpa, charge, try t.deepRaw(gpa, charge, v, ctx, n, at_summary));
    }

    fn deepRaw(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, at_summary: bool) Error!CondId {
        const epoch = v.shapes.base_epoch;
        const from = t.pending.items.len;
        const r = try t.deepWalk(gpa, charge, v, ctx, n, at_summary);
        if (!r.crossed and !(std.debug.runtime_safety and full_cross_check and !t.no_memo)) return r.k;
        if (!r.crossed) {
            try t.crossCheckDeep(gpa, charge, v, ctx, n, at_summary, r.k);
            return r.k;
        }
        if (v.shapes.base_epoch != epoch) {
            t.crossed_redos += 1;
            try t.settle(gpa, from, false);
            const saved = t.no_cross;
            t.no_cross = true;
            defer t.no_cross = saved;
            return (try t.deepWalk(gpa, charge, v, ctx, n, at_summary)).k;
        }
        try t.settle(gpa, from, true);
        if (std.debug.runtime_safety and full_cross_check and !t.no_memo) try t.crossCheckDeep(gpa, charge, v, ctx, n, at_summary, r.k);
        return r.k;
    }

    /// `-Downership-full-cross-check`: a `deep` read walked again whole, with
    /// no memo and no crossing, gives the same kind and atom set.
    fn crossCheckDeep(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, at_summary: bool, k: CondId) Error!void {
        const saved = .{ t.no_cross, t.no_memo };
        t.no_cross = true;
        t.no_memo = true;
        defer {
            t.no_cross = saved[0];
            t.no_memo = saved[1];
        }
        try t.expectSame(gpa, charge, try t.resolved(gpa, charge, k), try t.resolved(gpa, charge, (try t.deepWalk(gpa, charge, v, ctx, n, at_summary)).k));
    }

    fn deepWalk(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, at_summary: bool) Error!Read {
        const Frame = struct {
            at: Kappas,
            node: NodeId,
            summary: bool,
            explicit: bool,
            /// The carried pairs: a range of `pairs`.
            pairs: [2]u32,
            expanded: bool = false,
            /// This state's part, and where its children's answers start.
            own: CondId = yes,
            kids: u32 = 0,
            crossed: bool = false,

            fn key(f: @This()) [4]u32 {
                return .{ f.at.int(), f.node.int(), @intFromBool(f.summary), @intFromBool(f.explicit) };
            }
        };
        const open_mark = std.math.maxInt(u32);
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        var vals: std.ArrayList(Read) = .empty;
        defer vals.deinit(gpa);
        var pairs: std.ArrayList(Pair) = .empty;
        defer pairs.deinit(gpa);
        var state: Ids.FixedDict(4) = .{};
        defer state.deinit(gpa);
        var done: std.ArrayList(Read) = .empty;
        defer done.deinit(gpa);
        var next: std.ArrayList(Next) = .empty;
        defer next.deinit(gpa);
        var cyclic = false;
        var stop = false;
        try stack.append(gpa, .{ .at = ctx, .node = n, .summary = at_summary, .explicit = true, .pairs = .{ 0, 0 } });
        while (stack.items.len > 0) {
            const fi = stack.items.len - 1;
            var f = stack.items[fi];
            if (!f.expanded) {
                // Below a crossing, a node wholly of a carried region is read
                // at that pair's `R_Q`, where earlier reads met it.
                if (f.pairs[1] > 0 and !t.no_cross) {
                    for (pairs.items[f.pairs[0]..][0..f.pairs[1]]) |p| if (p.epoch == v.shapes.base_epoch and try v.shapes.wholly(gpa, charge.account, f.node, p.region)) {
                        f.at = p.r;
                        f.pairs = .{ 0, 0 };
                        f.crossed = true;
                        break;
                    };
                }
                try charge.reserve(gpa, .memo, 1);
                const got = try state.getOrPut(gpa, f.key());
                if (got.found_existing) {
                    _ = stack.pop();
                    if (got.value_ptr.* == open_mark) {
                        cyclic = true;
                        try vals.append(gpa, .{ .k = yes, .crossed = false });
                    } else try vals.append(gpa, done.items[got.value_ptr.*]);
                    continue;
                }
                // A traced read (a test's) walks every state: no answer from the memo.
                if (f.explicit and t.trace == null) if (t.memoGet(.deep, .{ f.at.int(), f.node.int(), @as(u32, @intFromBool(f.summary)) })) |hit| {
                    got.value_ptr.* = @intCast(done.items.len);
                    const r: Read = .{ .k = .from(hit), .crossed = f.crossed };
                    try done.append(gpa, r);
                    _ = stack.pop();
                    try vals.append(gpa, r);
                    continue;
                };
                got.value_ptr.* = open_mark;
                try charge.reserve(gpa, .inspection, 1);
                try t.traced(gpa, f.node, f.summary);
                const fpairs = pairs.items[f.pairs[0]..][0..f.pairs[1]];
                if (!f.explicit) {
                    // A projection the structure does not name: what the arrivals
                    // above claim (`excl` is deep) covers its derivation; only
                    // what the snapshot stores there is more.
                    if (t.kappaGet(f.at, f.node)) |s| f.own = s;
                } else {
                    const k = try t.readAt(gpa, charge, v, f.at, f.node, f.summary, fpairs);
                    f.own = try t.@"and"(gpa, charge, k, try t.shallow(gpa, charge, v.cells, v.places, (try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, f.node))));
                }
                f.expanded = true;
                f.kids = @intCast(vals.items.len);
                if (f.own == shared) {
                    stop = true;
                    stack.items[fi] = f;
                    continue;
                }
                // The pairs below: those carried, a step down, and the crossings
                // at this node's re-root views.
                const sub_from: u32 = @intCast(pairs.items.len);
                if (!t.no_cross) try t.crossingsAt(gpa, charge, v, f.at, f.node, &pairs);
                const own_pairs = pairs.items.len - sub_from;
                next.clearRetainingCapacity();
                try t.frontier(gpa, charge, v, f.node, f.summary, &.{f.at}, &next);
                stack.items[fi] = f;
                for (next.items) |e| {
                    const s = Step.fromWord(e.step);
                    const pf: u32 = @intCast(pairs.items.len);
                    for (0..f.pairs[1]) |i| {
                        const p = pairs.items[f.pairs[0] + i];
                        try pairs.append(gpa, .{ .region = p.region, .r = t.kappaChild(p.r, s), .epoch = p.epoch });
                    }
                    for (0..own_pairs) |i| {
                        const p = pairs.items[sub_from + i];
                        try pairs.append(gpa, .{ .region = p.region, .r = t.kappaChild(p.r, s), .epoch = p.epoch });
                    }
                    try stack.append(gpa, .{ .at = t.kappaChild(f.at, s), .node = e.node, .summary = e.summary, .explicit = e.explicit, .pairs = .{ pf, @intCast(pairs.items.len - pf) } });
                }
                continue;
            }
            // Its frontier's answers are in: this state's own.
            var k = f.own;
            var crossed = f.crossed;
            for (vals.items[f.kids..]) |r| {
                k = try t.@"and"(gpa, charge, k, r.k);
                crossed = crossed or r.crossed;
            }
            vals.shrinkRetainingCapacity(f.kids);
            if (f.pairs[1] > 0) crossed = true;
            k = try t.canonical(gpa, charge, k);
            _ = stack.pop();
            if (f.explicit and !cyclic and !stop) try t.memoPut(gpa, .deep, .{ f.at.int(), f.node.int(), @intFromBool(f.summary) }, k.int(), crossed);
            (try state.getOrPut(gpa, f.key())).value_ptr.* = @intCast(done.items.len);
            try done.append(gpa, .{ .k = k, .crossed = crossed });
            try vals.append(gpa, .{ .k = k, .crossed = crossed });
            if (stop) {
                // `shared` absorbs: the root's answer is `shared`.
                while (stack.items.len > 0) _ = stack.pop();
                return .{ .k = shared, .crossed = crossed };
            }
        }
        const r = vals.pop().?;
        if (cyclic) try t.memoPut(gpa, .deep, .{ ctx.int(), n.int(), @intFromBool(at_summary) }, r.k.int(), r.crossed);
        return r;
    }

    /// The crossings at `n`'s re-root views read at `ctx` (*Carried along
    /// the walk*): the views a union, choice or positions DAG at `n`'s path
    /// has for sides (a view that is no re-root view read at its answer),
    /// each where `eqOn` holds, appended to `out` once per region.
    fn crossingsAt(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, out: *std.ArrayList(Pair)) Error!void {
        var stack: std.ArrayList(NodeId) = .empty;
        defer stack.deinit(gpa);
        var seen: stamped.Column(NodeId, void) = .{};
        defer seen.deinit(gpa);
        try stack.append(gpa, n);
        while (stack.pop()) |x| {
            if (seen.contains(x)) continue;
            try seen.put(gpa, x, {});
            try charge.reserve(gpa, .inspection, 1);
            if (v.shapes.kind(x) == .view) {
                if (try t.crossAt(gpa, charge, v, ctx, x)) |c| {
                    for (out.items) |p| {
                        if (p.region == c.region and p.r == c.r) break;
                    } else try out.append(gpa, .{ .region = c.region, .r = c.r, .epoch = v.shapes.base_epoch });
                    continue;
                }
                const answer = try v.shapes.force(gpa, charge.account, x);
                if (isDag(v.shapes.kind(answer))) try stack.append(gpa, answer);
                continue;
            }
            if (!isDag(v.shapes.kind(x))) continue;
            const d = v.shapes.get(x);
            try stack.appendSlice(gpa, &.{ .from(d.a), .from(d.b) });
        }
    }

    /// What a cell set owes per cell (*The derivation*): `summary`, at a
    /// summary position, `excl c` per arrival standing for many positions
    /// (`summaryExclFlat`); `shallow`, `excl c` for every arrival, a deep
    /// condition's part (`shallowFlat`). A term depends only on the cell's
    /// origin, approximation and folding, all immutable, so the answer is
    /// memoised per radix node of the persistent set: a node's is its two
    /// halves' `and`, canonical (*Canonical partials*). A set one insertion
    /// larger reads its new spine. Post-order on an explicit stack.
    const PerCell = enum(u8) { summary, shallow };

    fn perCell(t: *Table, gpa: Allocator, charge: Charge, cellt: *const Cell.Table, places: *const Cell.Places, which: PerCell, cells: SetId) Error!CondId {
        if (cells == .none) return yes;
        // One cell: its term at once, never memoised.
        if (cellt.sets.branches(cells) == null) return switch (which) {
            .summary => t.summaryExclFlat(gpa, charge, cellt, places, cells),
            .shallow => t.shallowFlat(gpa, charge, cellt, places, cells),
        };
        try charge.reserve(gpa, .memo, 1);
        if (t.memo_per_cell.get(.{ @backingInt(which), cells.int() })) |hit| return .from(hit);
        var stack: std.ArrayList(SetId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, cells);
        while (stack.items.len > 0) {
            const x = stack.items[stack.items.len - 1];
            if (t.memo_per_cell.get(.{ @backingInt(which), x.int() }) != null) {
                _ = stack.pop();
                continue;
            }
            const k: CondId = if (cellt.sets.branches(x)) |kids| blk: {
                var halves: [2]CondId = undefined;
                var missing = false;
                for (kids, 0..) |kid, i| {
                    if (kid == .none) {
                        halves[i] = yes;
                    } else if (t.memo_per_cell.get(.{ @backingInt(which), kid.int() })) |h| {
                        halves[i] = .from(h);
                    } else {
                        missing = true;
                        try stack.append(gpa, kid);
                    }
                }
                if (missing) continue;
                break :blk try t.canonical(gpa, charge, try t.@"and"(gpa, charge, halves[0], halves[1]));
            } else switch (which) {
                .summary => try t.summaryExclFlat(gpa, charge, cellt, places, x),
                .shallow => try t.shallowFlat(gpa, charge, cellt, places, x),
            };
            (try t.memo_per_cell.getOrPut(gpa, .{ @backingInt(which), x.int() })).value_ptr.* = k.int();
            _ = stack.pop();
        }
        return .from(t.memo_per_cell.get(.{ @backingInt(which), cells.int() }).?);
    }

    fn summaryExcl(t: *Table, gpa: Allocator, charge: Charge, cellt: *const Cell.Table, places: *const Cell.Places, cells: SetId) Error!CondId {
        return t.perCell(gpa, charge, cellt, places, .summary, cells);
    }

    fn shallow(t: *Table, gpa: Allocator, charge: Charge, cellt: *const Cell.Table, places: *const Cell.Places, cells: SetId) Error!CondId {
        return t.perCell(gpa, charge, cellt, places, .shallow, cells);
    }

    /// `k` as the condition of its atom set (*Canonical partials*): one id per
    /// kind and atom set, whatever `and` tree made it.
    fn canonical(t: *Table, gpa: Allocator, charge: Charge, k: CondId) Error!CondId {
        if (k == yes or fails(k)) return k;
        return t.ofSet(gpa, charge, try t.flat(gpa, charge, k));
    }

    /// At a summary position: `excl c` per arrival standing for many positions.
    fn summaryExclFlat(t: *Table, gpa: Allocator, charge: Charge, cellt: *const Cell.Table, places: *const Cell.Places, cells: SetId) Error!CondId {
        var acc: CondId = yes;
        var it = cellt.sets.iterate(cells);
        while (it.next()) |e| {
            try charge.reserve(gpa, .inspection, 1);
            const c: CellId = .from(e.key);
            const o = cellt.origin(c);
            if (e.value == 1 or o == .top) return lost;
            if (isConcrete(o) or o == .mark or !isFolded(cellt, places, c)) continue;
            acc = try t.@"and"(gpa, charge, acc, try t.excl(gpa, charge, c));
        }
        return acc;
    }

    /// `excl c` for every arrival in a cell set (a DEEP condition's part).
    fn shallowFlat(t: *Table, gpa: Allocator, charge: Charge, cellt: *const Cell.Table, places: *const Cell.Places, cells: SetId) Error!CondId {
        _ = places;
        var acc: CondId = yes;
        var it = cellt.sets.iterate(cells);
        while (it.next()) |e| {
            try charge.reserve(gpa, .inspection, 1);
            const c: CellId = .from(e.key);
            const o = cellt.origin(c);
            if (e.value == 1 or o == .top) return lost;
            if (isConcrete(o) or o == .mark) continue;
            acc = try t.@"and"(gpa, charge, acc, try t.excl(gpa, charge, c));
        }
        return acc;
    }

    /// The `apart` group atom at the top of a container's κ, and the rest.
    fn splitGroup(t: *Table, k: CondId) struct { atom: CondId, rest: CondId } {
        if (k == yes or fails(k)) return .{ .atom = .none, .rest = k };
        const d = t.get(k);
        if (d.kind == .atom) return if (d.atom == .apart) .{ .atom = k, .rest = yes } else .{ .atom = .none, .rest = k };
        const a: CondId = .from(d.a);
        const b: CondId = .from(d.b);
        if (t.kind(a) == .atom and t.get(a).atom == .apart) return .{ .atom = a, .rest = b };
        if (t.kind(b) == .atom and t.get(b).atom == .apart) return .{ .atom = b, .rest = a };
        return .{ .atom = .none, .rest = k };
    }

    /// §2.9's construction rule, incremental: a stored cell the base holds is
    /// `shared` (one set lookup); the arrivals group (the `apart` atom at the
    /// top of κ) grows by insertion, the base scanned only while it has no
    /// group; plus the stored value's κ as a position. W fresh stores O(W log W).
    pub fn lower(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, base_kappa0: CondId, base_cells: SetId, stored: NodeId, at_summary: bool, traversal: ?Traversal) Error!CondId {
        // `splitGroup` tests the base's condition's shape: resolved first.
        const base_kappa = try t.resolved(gpa, charge, base_kappa0);
        if (base_kappa == shared) return shared;
        const split = t.splitGroup(base_kappa);
        var acc = split.rest;
        var new_arrivals: std.ArrayList(CellId) = .empty;
        defer new_arrivals.deinit(gpa);
        var it = v.cells.sets.iterate((try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, stored)));
        while (it.next()) |e| {
            try charge.reserve(gpa, .inspection, 1);
            const c: CellId = .from(e.key);
            if (e.value == 1 or v.cells.origin(c) == .top) acc = try t.@"and"(gpa, charge, acc, lost);
            if (v.cells.sets.member(base_cells, c.int())) {
                acc = try t.@"and"(gpa, charge, acc, try t.sep(gpa, charge, v.cells, v.places, c, c, false, traversal));
                if (acc == shared) return shared;
            } else if (!isConcrete(v.cells.origin(c)) and v.cells.origin(c) != .top) {
                try new_arrivals.append(gpa, c);
            }
        }
        var group: SetId = if (split.atom != .none) .from(t.get(split.atom).a) else .none;
        if (new_arrivals.items.len > 0) {
            if (split.atom == .none) {
                // No group yet: the base holds at most one arrival, found by
                // one scan, charged per cell.
                var bt = v.cells.sets.iterate(base_cells);
                while (bt.next()) |e| {
                    try charge.reserve(gpa, .inspection, 1);
                    const o = v.cells.origin(.from(e.key));
                    if (!isConcrete(o) and o != .top and o != .mark) group = try v.cells.sets.insert(gpa, charge, group, e.key, 0);
                }
            }
            // The new arrivals against the group's cells of the same base.
            var same: std.ArrayList(CellId) = .empty;
            defer same.deinit(gpa);
            for (new_arrivals.items) |c| {
                var gt = v.cells.sets.iterate(group);
                while (gt.next()) |e| {
                    try charge.reserve(gpa, .inspection, 1);
                    const g: CellId = .from(e.key);
                    if (v.cells.base(g) != v.cells.base(c)) continue;
                    if (v.cells.alias(v.places, g, c) == .no) continue;
                    acc = try t.@"and"(gpa, charge, acc, try t.sep(gpa, charge, v.cells, v.places, g, c, false, traversal));
                    if (acc == shared) return shared;
                }
                group = try v.cells.sets.insert(gpa, charge, group, c.int(), 0);
            }
            try same.appendSlice(gpa, new_arrivals.items);
            if (new_arrivals.items.len >= 2) acc = try t.@"and"(gpa, charge, acc, try t.sameBasePairs(gpa, charge, v.cells, v.places, same.items, traversal));
        }
        // The stored value's own condition at the written position (its κ
        // as a position, `excl` for its arrivals that stand for many): the
        // conditions of the paths below are set where the walker joins the
        // children (`propagate` together), never a deep condition here.
        acc = try t.@"and"(gpa, charge, acc, try t.kappaOf(gpa, charge, v, ctx, stored, at_summary));
        if (acc == shared) return shared;
        if (group != .none and try t.groupSize2(gpa, charge, v.cells, group)) return t.@"and"(gpa, charge, acc, try t.apartAtom(gpa, charge, group));
        if (split.atom != .none) return t.@"and"(gpa, charge, acc, split.atom);
        return acc;
    }

    /// Whether a set has at least two members: two steps of its iterator.
    fn groupSize2(t: *Table, gpa: Allocator, charge: Charge, cellt: *const Cell.Table, s: SetId) Error!bool {
        _ = t;
        try charge.reserve(gpa, .inspection, 1);
        var it = cellt.sets.iterate(s);
        return it.next() != null and it.next() != null;
    }

    // ---- joins -------------------------------------------------------------

    /// Record a position a reader reads (`trace`, for tests).
    fn traced(t: *Table, gpa: Allocator, n: NodeId, summary: bool) Error!void {
        if (t.trace) |l| try l.append(gpa, n.int() << 1 | @intFromBool(summary));
    }

    /// The positions a κ read reaches from `(n, summary)` (§2.9): a position
    /// is a path, so the transitions are steps, and the frontier is SPARSE:
    /// the steps `n`'s structure names (`explicitSteps`) and the steps the
    /// snapshots read there (`cursors`) link; every other projection's read
    /// is derived from structure the reader reads already, with nothing
    /// stored, so it is omitted and a type's width costs nothing. Below a
    /// fold (a widened recursive position, whose entries are keyed by node
    /// for every level) every step of the place is a transition. Other nodes
    /// at `n`'s path are read by `kappaOf` of `n`: a union's or positions
    /// node's sides by `dagKappa`, a recast's inner beside the recast (a
    /// recast changes the type, not the path, so the two are one position,
    /// and the inner's own steps are the position's too: `via` names the
    /// inner, found through the sides of a union or a positions node as
    /// well); a delta's base never (a built node's κ is the walk's, O13).
    /// `explicit`: the structure names something at that step. The one walk
    /// of `propagate`, `kappaLeq` and `deep`; Block writes the same.
    pub const Next = struct { node: NodeId, summary: bool, step: u32, explicit: bool = true, via: NodeId = .none };

    pub fn frontier(t: *Table, gpa: Allocator, charge: Charge, v: View, n: NodeId, summary: bool, cursors: []const Kappas, out: *std.ArrayList(Next)) Error!void {
        var words: std.ArrayList(u64) = .empty;
        defer words.deinit(gpa);
        const fold = try t.cursorSteps(gpa, charge, cursors, &words);
        try t.frontierWith(gpa, charge, v, n, summary, .{ .words = words.items, .fold = fold }, out);
    }

    /// `frontier` against cursors read already: the frames reading one
    /// run read its cursors once (#1273).
    fn frontierWith(t: *Table, gpa: Allocator, charge: Charge, v: View, n: NodeId, summary: bool, cs: CursorSteps, out: *std.ArrayList(Next)) Error!void {
        try t.steps(gpa, charge, v, n, summary, cs, .none, out);
        var inners: std.ArrayList(NodeId) = .empty;
        defer inners.deinit(gpa);
        try innersOf(gpa, charge, v, n, &inners);
        for (inners.items) |i| try t.steps(gpa, charge, v, i, summary, cs, i, out);
    }

    /// What a frontier reads of its cursors, the same for every node read
    /// against them: the steps their links name, distinct and sorted (a
    /// fold's links are the steps it saw, sparse below it too; a wide
    /// run's cursors name the same few steps, #1139), those a cursor has a
    /// position at, and whether one is a fold (a position at every step).
    pub const CursorSteps = struct {
        /// `step word << 1 | linked`, sorted.
        words: []const u64,
        fold: bool,
    };

    /// The cursors' steps appended to `out`, sorted; whether one is a fold.
    fn cursorSteps(t: *Table, gpa: Allocator, charge: Charge, cursors: []const Kappas, out: *std.ArrayList(u64)) Error!bool {
        const from = out.items.len;
        var fold = false;
        var seen: Ids.FixedDict(1) = .{};
        defer seen.deinit(gpa);
        for (cursors) |c| {
            if (c != .none and t.position(c).fold != 0) fold = true;
            var it = t.kappaLinks(c);
            while (it.next()) |e| {
                try charge.reserve(gpa, .inspection, 1);
                const got = try seen.getOrPut(gpa, .{e.step.word()});
                if (!got.found_existing) {
                    got.value_ptr.* = @intCast(out.items.len);
                    try out.append(gpa, @as(u64, e.step.word()) << 1);
                }
                if (t.kappaChild(c, e.step) != .none) out.items[got.value_ptr.*] |= 1;
            }
        }
        try charge.reserve(gpa, .inspection, sortCost(out.items.len - from));
        std.mem.sort(u64, out.items[from..], {}, std.sort.asc(u64));
        return fold;
    }

    fn steps(_: *Table, gpa: Allocator, charge: Charge, v: View, n: NodeId, summary: bool, cs: CursorSteps, via: NodeId, out: *std.ArrayList(Next)) Error!void {
        var named: std.ArrayList(u32) = .empty;
        defer named.deinit(gpa);
        try explicitSteps(gpa, charge, v, n, &named);
        try charge.reserve(gpa, .inspection, sortCost(named.items.len));
        std.mem.sort(u32, named.items, {}, std.sort.asc(u32));
        // The named steps and the cursors' merged, each once, in order;
        // each is charged below as it is read.
        var a: usize = 0;
        var b: usize = 0;
        var last: ?u32 = null;
        while (a < named.items.len or b < cs.words.len) {
            const wb: ?u32 = if (b < cs.words.len) @intCast(cs.words[b] >> 1) else null;
            const take_named = a < named.items.len and (wb == null or named.items[a] <= wb.?);
            const w = if (take_named) named.items[a] else wb.?;
            const explicit_here = take_named;
            var linked = cs.fold;
            if (take_named) a += 1;
            if (wb != null and wb.? == w) {
                linked = linked or cs.words[b] & 1 == 1;
                b += 1;
            }
            if (last != null and last.? == w) continue;
            last = w;
            try charge.reserve(gpa, .inspection, 1);
            const s = Step.fromWord(w);
            const c = (try v.shapes.proj(gpa, charge.account, v.places, v.cells, n, s)) orelse continue;
            // Through a recast's inner only what a snapshot stores is more:
            // an unstored inner adds nothing to the recast's derived read.
            const explicit = via == .none and explicit_here;
            const empty = try v.shapes.isNothing(gpa, charge.account, c);
            if (!linked and (!explicit or empty)) continue;
            try out.append(gpa, .{ .node = c, .summary = summary or below(s), .step = w, .explicit = explicit, .via = via });
        }
    }

    /// The steps `n`'s structure names: a node's overrides, a delta's and
    /// its base's, a union's or a positions node's sides'; a leaf or a
    /// recast names none (its projections are derived). Sorted and
    /// distinct, `Shape.namedSteps`' memo: a record per step read.
    fn explicitSteps(gpa: Allocator, charge: Charge, v: View, n: NodeId, out: *std.ArrayList(u32)) Error!void {
        const named = try v.shapes.namedSteps(gpa, charge.account, n);
        try charge.reserve(gpa, .inspection, @intCast(named.len));
        try out.appendSlice(gpa, named);
    }

    /// The inners of the recasts at `n`'s path: `n`'s own, those of its
    /// union's or positions node's sides, and, an inner being at the same
    /// path, those found inside an inner (a recast of a union of recasts,
    /// #1101), each once. A record per node.
    fn innersOf(gpa: Allocator, charge: Charge, v: View, n: NodeId, out: *std.ArrayList(NodeId)) Error!void {
        // A view is read at its answer; a recast's inner is listed as stored
        // (a view's κ is its chain's, `storedAt`) and walked at its answer:
        // `Shape.inners`, memoised per node, in node order.
        var it = v.shapes.node_sets.iterate(try v.shapes.inners(gpa, charge.account, n));
        while (it.next()) |e| {
            try charge.reserve(gpa, .inspection, 1);
            try out.append(gpa, .from(e.key));
        }
    }

    /// A member's counterpart for a transition: itself, or for one out of a
    /// recast's inner `via`, the join of the inners of its own recasts at
    /// that place (null: it has none, so nothing it stores is there).
    fn side(gpa: Allocator, charge: Charge, v: View, m: NodeId, via: NodeId) Error!?NodeId {
        if (via == .none) return m;
        var inners: std.ArrayList(NodeId) = .empty;
        defer inners.deinit(gpa);
        try innersOf(gpa, charge, v, m, &inners);
        // Every inner at that place, joined: a union's recasts' inners are
        // alternatives at one position, each read (#1114's review).
        var at: std.ArrayList(NodeId) = .empty;
        defer at.deinit(gpa);
        for (inners.items) |i| if (v.shapes.place(i) == v.shapes.place(via)) try at.append(gpa, i);
        if (at.items.len == 0) return null;
        if (at.items.len == 1) return at.items[0];
        return try v.shapes.join(gpa, charge.account, v.places, v.cells, at.items);
    }

    /// A sort of `n` items: n·⌈log₂(n + 1)⌉ comparisons, each a record.
    fn sortCost(n: usize) u32 {
        const lg: usize = std.math.log2_int_ceil(usize, n + 1);
        return @intCast(@min(n * lg, std.math.maxInt(u32)));
    }

    fn below(s: Step) bool {
        return s.kind == .elem or s.kind == .level;
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
        std.debug.assert(members.len == member_ctxs.len);
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
        const Slice = struct { run: u32, m0: NodeId, c0: Kappas, one: bool, k: [4]u32, words: u32, words_len: u32, fold: bool };
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
        while (stack.pop()) |f| {
            try charge.reserve(gpa, .memo, 1);
            const sg = try slice_at.getOrPut(gpa, .{f.first});
            if (!sg.found_existing) {
                sg.value_ptr.* = @intCast(slices.items.len);
                var run: u32 = Ids.none_int;
                var r = f.len;
                while (r > 0) {
                    r -= 1;
                    try charge.reserve(gpa, .memo, 1);
                    const got = try t.prop_runs.getOrPut(gpa, .{ runs.items[f.first + r].int(), run_ctxs.items[f.first + r].int(), run });
                    if (!got.found_existing) got.value_ptr.* = got.index;
                    run = got.value_ptr.*;
                }
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
            // A clean state met before, in this call or another: its walk
            // is the same, so its position is the snapshot that walk made,
            // linked as it is (§2.9, *The join memo*).
            if (f.clean) {
                const key: [3]u32 = .{ f.node.int(), stateBits(f.summary, f.msummary, mode, f.node == joined), run };
                try charge.reserve(gpa, .memo, 1);
                if (t.memo_prop.get(key)) |hit| {
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
            next.clearRetainingCapacity();
            if (slices.items[si].words_len == Ids.none_int) {
                const at: u32 = @intCast(words.items.len);
                const fold = try t.cursorSteps(gpa, charge, run_ctxs.items[f.first..][0..f.len], &words);
                slices.items[si].words = at;
                slices.items[si].words_len = @intCast(words.items.len - at);
                slices.items[si].fold = fold;
            }
            const sl = slices.items[si];
            try t.frontierWith(gpa, charge, v, f.node, f.summary, .{ .words = words.items[sl.words..][0..sl.words_len], .fold = sl.fold }, &next);
            for (next.items) |e| {
                const s = Step.fromWord(e.step);
                const child = e.node;
                // The run one step below, made once per (run, step, inner
                // place, class).
                try charge.reserve(gpa, .memo, 1);
                const place: u32 = if (e.via == .none) Ids.none_int else v.shapes.place(e.via).int();
                const bg = try below_at.getOrPut(gpa, .{ f.first, e.step, place, @intFromBool(e.summary) });
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
        return t.kappaMerge(gpa, charge, out, pos[0]);
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

    /// `κ_a(a) ⊑ κ_b(b)` at every position the two structures put at one
    /// path (§2.9's sparse frontier): a simulation over PAIRS, each once
    /// per pair of positions, `b` projected in lockstep along every step
    /// of `a`'s frontier, both snapshots' links included (#1063).
    pub fn kappaLeq(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx_a: Kappas, a: NodeId, ctx_b: Kappas, b: NodeId, at_summary: bool) Error!bool {
        var seen: Ids.FixedDict(5) = .{};
        defer seen.deinit(gpa);
        const Frame = struct { a: NodeId, b: NodeId, summary: bool, ca: Kappas, cb: Kappas };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        var next: std.ArrayList(Next) = .empty;
        defer next.deinit(gpa);
        try stack.append(gpa, .{ .a = a, .b = b, .summary = at_summary, .ca = ctx_a, .cb = ctx_b });
        while (stack.pop()) |f| {
            try charge.reserve(gpa, .inspection, 1);
            const got = try seen.getOrPut(gpa, .{ f.a.int(), f.b.int(), @intFromBool(f.summary), f.ca.int(), f.cb.int() });
            if (got.found_existing) continue;
            got.value_ptr.* = 1;
            try t.traced(gpa, f.a, f.summary);
            const ka = try t.kappaOf(gpa, charge, v, f.ca, f.a, f.summary);
            const kb = try t.kappaOf(gpa, charge, v, f.cb, f.b, f.summary);
            if (!try t.leq(gpa, charge, ka, kb)) return false;
            next.clearRetainingCapacity();
            try t.frontier(gpa, charge, v, f.a, f.summary, &.{ f.ca, f.cb }, &next);
            for (next.items) |e| {
                const s = Step.fromWord(e.step);
                const sb = (try side(gpa, charge, v, f.b, e.via)) orelse return false;
                const nb = (try v.shapes.proj(gpa, charge.account, v.places, v.cells, sb, s)) orelse return false;
                try stack.append(gpa, .{ .a = e.node, .b = nb, .summary = e.summary, .ca = t.kappaChild(f.ca, s), .cb = t.kappaChild(f.cb, s) });
            }
        }
        return true;
    }

    // ---- lazy conditions (§2.11 *κ across a call*, part 3) -------------------------

    /// What resolves an `inst` atom: condition `k` of a class under a call's
    /// environment `env`, instantiated there (`Calls.Views`).
    pub const Resolver = struct {
        ctx: *anyopaque,
        /// `k` a condition id, or with `set` an atom set (`instSet`).
        resolve: *const fn (ctx: *anyopaque, t: *Table, gpa: Allocator, charge: Charge, k: u32, env: u32, set: bool) Error!CondId,
    };

    /// The atom `inst(k, env)`: a class's condition `k` under a call's
    /// environment, instantiated only when a reader tests it (`resolved`).
    /// `join`, `and`, `flat` and `kind` treat it as an opaque atom: resolving
    /// distributes over `and`. A new atom is queued in creation order.
    pub fn instAtom(t: *Table, gpa: Allocator, charge: Charge, k: CondId, env: u32) Error!CondId {
        if (k == yes or fails(k)) return k;
        const before = t.conds.len;
        const a = try t.make(gpa, charge, .{ .kind = .atom, .atom = .inst, .a = k.int(), .b = env });
        if (a.int() >= before) try t.inst_queue.append(gpa, a);
        return a;
    }

    /// `inst` of an atom set (a class's `xreq`): the set itself, flagged in
    /// the environment word (`inst_set_bit`), resolved atom by atom.
    pub fn instSet(t: *Table, gpa: Allocator, charge: Charge, s: SetId, env: u32) Error!CondId {
        if (s == .none) return yes;
        std.debug.assert(env & inst_set_bit == 0);
        const before = t.conds.len;
        const a = try t.make(gpa, charge, .{ .kind = .atom, .atom = .inst, .a = s.int(), .b = env | inst_set_bit });
        if (a.int() >= before) try t.inst_queue.append(gpa, a);
        return a;
    }

    pub const inst_set_bit: u32 = 1 << 31;

    /// The atoms queued before now are not this walk's to resolve: a frame
    /// holds only atoms made in its own walk (a class is published resolved).
    pub fn instFloor(t: *Table) void {
        t.inst_next = @intCast(t.inst_queue.items.len);
    }

    /// `k` with every `inst` atom resolved (`Cond.resolved`, the one entry):
    /// memoised per condition, canonical (*Canonical partials*). Before it
    /// resolves anything it resolves, in creation order, every queued atom up
    /// to the latest environment `k` names: an atom's resolution reads only
    /// its environment's actuals, made before it, so the atoms that read
    /// meets are resolved already and no resolution waits on another on the
    /// native stack (#1130).
    pub fn resolved(t: *Table, gpa: Allocator, charge: Charge, k: CondId) Error!CondId {
        if (k == yes or fails(k) or t.inst_queue.items.len == 0) return k;
        // A call's condition resolved inside Demands' resolve is the call's.
        const was = charge.account.in_demands;
        charge.account.in_demands = false;
        defer charge.account.in_demands = was;
        // Resolving is the reader's growth: never a lane's share (§4.1).
        const task = try charge.account.enter(gpa, null);
        defer charge.account.leave(task);
        const g: Charge = .growth(charge.account);
        const latest = try t.instLatest(gpa, g, k) orelse return k;
        try g.reserve(gpa, .memo, 1);
        if (t.memo_resolved_root.get(.{k.int()})) |hit| return .from(hit);
        try t.drainTo(gpa, g, latest);
        const out = try t.canonical(gpa, g, try t.resolveTree(gpa, g, k));
        (try t.memo_resolved_root.getOrPut(gpa, .{k.int()})).value_ptr.* = out.int();
        return out;
    }

    /// The latest environment an `inst` atom of `k` names, null for none:
    /// memoised per node of `k`'s `and` tree, so a condition built over
    /// earlier ones reads its new nodes. Post-order on an explicit stack.
    fn instLatest(t: *Table, gpa: Allocator, charge: Charge, k: CondId) Error!?u32 {
        const none: u32 = 0;
        const of = struct {
            fn leaf(tt: *const Table, x: CondId) ?u32 {
                if (x == yes or fails(x)) return none;
                const c = tt.get(x);
                if (c.kind != .atom) return null;
                return if (c.atom == .inst) (c.b & ~inst_set_bit) + 1 else none;
            }
        };
        if (of.leaf(t, k)) |v| return if (v == none) null else v - 1;
        var stack: std.ArrayList(CondId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, k);
        while (stack.items.len > 0) {
            const x = stack.items[stack.items.len - 1];
            if (t.memo_inst_latest.get(.{x.int()}) != null) {
                _ = stack.pop();
                continue;
            }
            try charge.reserve(gpa, .memo, 1);
            const c = t.get(x);
            var vals: [2]u32 = undefined;
            var missing = false;
            for ([_]CondId{ .from(c.a), .from(c.b) }, 0..) |sd, i| {
                if (of.leaf(t, sd)) |v| {
                    vals[i] = v;
                } else if (t.memo_inst_latest.get(.{sd.int()})) |v| {
                    vals[i] = v;
                } else {
                    missing = true;
                    try stack.append(gpa, sd);
                }
            }
            if (missing) continue;
            (try t.memo_inst_latest.getOrPut(gpa, .{x.int()})).value_ptr.* = @max(vals[0], vals[1]);
            _ = stack.pop();
        }
        const v = t.memo_inst_latest.get(.{k.int()}).?;
        return if (v == none) null else v - 1;
    }

    /// `k` with each `inst` atom replaced by its resolution: memoised per node
    /// of its `and` tree, a node's the `and` of its two sides'. Post-order on
    /// an explicit stack; the caller makes the answer canonical.
    fn resolveTree(t: *Table, gpa: Allocator, charge: Charge, k: CondId) Error!CondId {
        const leafOf = struct {
            fn get(tt: *Table, g: Allocator, ch: Charge, x: CondId) Error!?CondId {
                if (x == yes or fails(x)) return x;
                const c = tt.get(x);
                if (c.kind != .atom) return null;
                return if (c.atom == .inst) try tt.resolveAtom(g, ch, x) else x;
            }
        }.get;
        if (try leafOf(t, gpa, charge, k)) |r| return r;
        var stack: std.ArrayList(CondId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, k);
        while (stack.items.len > 0) {
            const x = stack.items[stack.items.len - 1];
            if (t.memo_resolved.get(.{x.int()}) != null) {
                _ = stack.pop();
                continue;
            }
            try charge.reserve(gpa, .memo, 1);
            const c = t.get(x);
            var sides: [2]CondId = undefined;
            var missing = false;
            for ([_]CondId{ .from(c.a), .from(c.b) }, 0..) |sd, i| {
                if (try leafOf(t, gpa, charge, sd)) |r| {
                    sides[i] = r;
                } else if (t.memo_resolved.get(.{sd.int()})) |r| {
                    sides[i] = .from(r);
                } else {
                    missing = true;
                    try stack.append(gpa, sd);
                }
            }
            if (missing) continue;
            const got = try t.@"and"(gpa, charge, sides[0], sides[1]);
            (try t.memo_resolved.getOrPut(gpa, .{x.int()})).value_ptr.* = got.int();
            _ = stack.pop();
        }
        return .from(t.memo_resolved.get(.{k.int()}).?);
    }

    /// The queued atoms up to environment `env`, resolved in creation order.
    fn drainTo(t: *Table, gpa: Allocator, charge: Charge, env: u32) Error!void {
        while (t.inst_next < t.inst_queue.items.len) {
            const a = t.inst_queue.items[t.inst_next];
            if (t.get(a).b & ~inst_set_bit > env) break;
            t.inst_next += 1;
            _ = try t.resolveAtom(gpa, charge, a);
        }
    }

    /// One `inst` atom resolved, memoised: `instantiate` of its condition
    /// under its environment, canonical. A resolved condition holds no
    /// `inst` atom.
    fn resolveAtom(t: *Table, gpa: Allocator, charge: Charge, a: CondId) Error!CondId {
        try charge.reserve(gpa, .memo, 1);
        if (t.memo_resolved.get(.{a.int()})) |hit| return .from(hit);
        const d = t.get(a);
        const rs = t.resolver orelse unreachable; // an `inst` atom is made only under one
        const r = try t.canonical(gpa, charge, try rs.resolve(rs.ctx, t, gpa, charge, d.a, d.b & ~inst_set_bit, d.b & inst_set_bit != 0));
        if (std.debug.runtime_safety) try t.assertResolved(gpa, charge, r);
        if (std.debug.runtime_safety and full_cross_check and !t.no_memo) {
            // Resolved again, with no memo and no crossing (*Cross-check*).
            const saved = .{ t.no_cross, t.no_memo };
            t.no_cross = true;
            t.no_memo = true;
            defer {
                t.no_cross = saved[0];
                t.no_memo = saved[1];
            }
            try t.expectSame(gpa, charge, r, try t.canonical(gpa, charge, try rs.resolve(rs.ctx, t, gpa, charge, d.a, d.b & ~inst_set_bit, d.b & inst_set_bit != 0)));
        }
        (try t.memo_resolved.getOrPut(gpa, .{a.int()})).value_ptr.* = r.int();
        return r;
    }

    /// A `runtime_safety` check at a resolving reader: `k` holds no `inst`.
    pub fn assertResolved(t: *Table, gpa: Allocator, charge: Charge, k: CondId) Error!void {
        if (!std.debug.runtime_safety or k == yes or fails(k)) return;
        var it = t.atoms.iterate(try t.flat(gpa, charge, k));
        while (it.next()) |e| if (t.get(.from(e.key)).atom == .inst) std.debug.panic("ownership v2: an unresolved inst atom reached a reader that tests it", .{});
    }

    // ---- at a call, and relying ----------------------------------------------

    /// κ instantiated at a call (§2.9, *a call*): a failure stays, every
    /// atom is answered by the caller's interpreter and the answers are
    /// conjoined. One record per atom.
    pub fn instantiate(t: *Table, gpa: Allocator, charge: Charge, k0: CondId, interp: Interp) Error!CondId {
        // A reader of a condition's atoms: its `inst` atoms resolved first.
        const k = try t.resolved(gpa, charge, k0);
        if (k == yes or fails(k)) return k;
        var acc: CondId = yes;
        var it = t.atoms.iterate(try t.flat(gpa, charge, k));
        while (it.next()) |e| {
            try charge.reserve(gpa, .inspection, 1);
            acc = try t.@"and"(gpa, charge, acc, try interp.atom(interp.ctx, t, gpa, charge, t.get(.from(e.key))));
            if (acc == shared) return shared;
        }
        return acc;
    }

    /// Relying on κ (§2.9): `yes` records nothing, atoms become the frame's
    /// `xreq`, a failure is the refusal `exclusive`, exact for `shared`.
    pub fn rely(t: *Table, gpa: Allocator, charge: Charge, k0: CondId) Error!Rely {
        const k = try t.resolved(gpa, charge, k0);
        try t.assertResolved(gpa, charge, k);
        if (k == yes) return .ok;
        if (k == shared) return .{ .refused = .exact };
        if (k == lost) return .{ .refused = .approximate };
        return .{ .xreq = try t.flat(gpa, charge, k) };
    }

    // ---- text -------------------------------------------------------------------

    /// A condition as a summary line prints it (v1's grammar): nothing,
    /// `{lost}`, `{shared}`, or `{atom, atom}` in text order (`arena` scratch).
    pub fn print(t: *Table, gpa: Allocator, charge: Charge, arena: Allocator, w: *std.Io.Writer, k: CondId, cellt: *const Cell.Table, p: Printer) (Error || std.Io.Writer.Error)!void {
        if (k == yes) return;
        if (k == lost) return w.writeAll("{lost}");
        if (k == shared) return w.writeAll("{shared}");
        var texts: std.ArrayList([]const u8) = .empty;
        defer texts.deinit(gpa);
        var it = t.atoms.iterate(try t.flat(gpa, charge, k));
        while (it.next()) |e| {
            try charge.reserve(gpa, .inspection, 1);
            var buf: std.Io.Writer.Allocating = .init(arena);
            try t.printAtom(&buf.writer, t.get(.from(e.key)), gpa, arena, cellt, p);
            try texts.append(gpa, buf.toOwnedSlice() catch return error.OutOfMemory);
        }
        sortText(texts.items);
        try w.writeByte('{');
        for (texts.items, 0..) |s, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(s);
        }
        try w.writeByte('}');
    }

    /// `excl X`, `sep X Y`, `within L`, `apart [X] [Y] …` (members in text
    /// order, one group each as v1 prints them), `keep cbJ`, `writes cbJ`.
    pub fn printAtom(t: *Table, w: *std.Io.Writer, a: Cond, gpa: Allocator, arena: Allocator, cellt: *const Cell.Table, p: Printer) (Error || std.Io.Writer.Error)!void {
        _ = t;
        std.debug.assert(a.kind == .atom);
        switch (a.atom) {
            .excl => {
                try w.writeAll("excl ");
                try p.cell(p.ctx, w, .from(a.a));
            },
            .sep => {
                // The two sides in text order.
                var x: std.Io.Writer.Allocating = .init(arena);
                try p.cell(p.ctx, &x.writer, .from(a.a));
                var y: std.Io.Writer.Allocating = .init(arena);
                try p.cell(p.ctx, &y.writer, .from(a.b));
                const xs = x.toOwnedSlice() catch return error.OutOfMemory;
                const ys = y.toOwnedSlice() catch return error.OutOfMemory;
                const first = std.mem.lessThan(u8, ys, xs);
                try w.print("sep {s} {s}", .{ if (first) ys else xs, if (first) xs else ys });
            },
            .within => {
                try w.writeAll("within ");
                try p.label(p.ctx, w, .from(a.a));
            },
            .apart => {
                var texts: std.ArrayList([]const u8) = .empty;
                defer texts.deinit(gpa);
                var it = cellt.sets.iterate(.from(a.a));
                while (it.next()) |e| {
                    var buf: std.Io.Writer.Allocating = .init(arena);
                    try p.cell(p.ctx, &buf.writer, .from(e.key));
                    try texts.append(gpa, buf.toOwnedSlice() catch return error.OutOfMemory);
                }
                sortText(texts.items);
                try w.writeAll("apart");
                for (texts.items) |s| try w.print(" [{s}]", .{s});
            },
            .keep => try w.print("keep cb{d}", .{a.a + 1}),
            .writes => try w.print("writes cb{d}", .{a.a + 1}),
            // Unresolved: only a frame's value, never a summary, holds one.
            .inst => try w.print("inst {d}@{d}", .{ a.a, a.b }),
        }
    }
};

pub fn sortText(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
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
    // beside it, and its repeat is κ's business (`many`, below).
    const w = try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, root);
    try testing.expect(w != root);
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
    return .{ .root = root.node, .k = root.k, .kids = .{ k1.node, k2.node } };
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
        const depth2 = [_]Place.Step{ arg, e, arg, e, arg };
        const depth1 = [_]Place.Step{ arg, e, arg };
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
        const kids = try f.projOf(w, arg);
        const read = try f.kappa(f.conds.kappaChild(wk, arg), kids, false);
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
