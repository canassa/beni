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

pub const AtomKind = enum(u8) { excl, sep, within, apart, keep, writes };

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
        t.conds.deinit(gpa);
        t.intern.deinit(gpa);
        t.atoms.deinit(gpa);
        t.kmaps.deinit(gpa);
        t.kmap_intern.deinit(gpa);
        t.flat_memo.deinit(gpa);
        t.of_set.deinit(gpa);
        t.memo_deep.deinit(gpa);
        t.memo_sep.deinit(gpa);
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

    /// The canonical condition of an atom set: the left-nested `and` chain
    /// in ascending atom id, one id per set (memoised), so a fixpoint's
    /// `join` is idempotent (§2.12). O(|S| log) once per set.
    pub fn ofSet(t: *Table, gpa: Allocator, charge: Charge, s: SetId) Error!CondId {
        if (s == .none) return yes;
        if (t.of_set.get(.{s.int()})) |hit| return .from(hit);
        var acc: CondId = yes;
        var it = t.atoms.iterate(s);
        while (it.next()) |e| {
            try charge.reserve(gpa, .inspection, 1);
            acc = try t.@"and"(gpa, charge, acc, .from(e.key));
        }
        (try t.of_set.getOrPut(gpa, .{s.int()})).value_ptr.* = acc.int();
        try t.flat_memo.put(gpa, acc, s);
        return acc;
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
    pub fn leq(t: *Table, gpa: Allocator, charge: Charge, a: CondId, b: CondId) Error!bool {
        if (a == b or a == yes or b == shared) return true;
        if (a == shared) return false;
        if (b == lost) return true;
        if (a == lost) return false;
        if (b == yes) return false;
        return t.atoms.subset(gpa, charge, try t.flat(gpa, charge, a), try t.flat(gpa, charge, b));
    }

    // ---- the κ maps -------------------------------------------------------

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

    /// The map's key: the node AND its position class, so a plain-path κ
    /// never answers a summary-path read (`if c then (g 1).a else (g 2).a`
    /// is `yes`; `[ g 1, g 2 ]`'s `[*].a`, the same leaf, is `apart{…}`).
    fn mapKey(n: NodeId, at_summary: bool) u32 {
        std.debug.assert(n.int() < (1 << 31));
        return (n.int() << 1) | @intFromBool(at_summary);
    }

    /// κ(n) at its position class as `ctx` has it set, or null. O(min(32,
    /// depth)) reads.
    pub fn kappaGet(t: *const Table, ctx: Kappas, n: NodeId, at_summary: bool) ?CondId {
        const key = mapKey(n, at_summary);
        var at = ctx.int();
        while (at != Ids.none_int) {
            const m = t.mapNode(at);
            if (m.mask == 0) return if (m.prefix == key) CondId.from(m.left) else null;
            if (!matches(key, m.prefix, m.mask)) return null;
            at = if (key & m.mask == 0) m.left else m.right;
        }
        return null;
    }

    /// `ctx` with `n ↦ v` (replacing), path-copied: ≤ 33 records.
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

    pub const Set = struct { ctx: Kappas, changed: bool };

    /// `ctx` with κ(n) at its position class joined with `k` (monotone,
    /// §2.12): the new root and whether κ(n) changed; the same root when not.
    pub fn kappaSet(t: *Table, gpa: Allocator, charge: Charge, ctx: Kappas, n: NodeId, at_summary: bool, k: CondId) Error!Set {
        const new = if (t.kappaGet(ctx, n, at_summary)) |old| try t.join(gpa, charge, old, k) else k;
        if (t.kappaGet(ctx, n, at_summary)) |old| if (old == new) return .{ .ctx = ctx, .changed = false };
        return .{ .ctx = .from(try t.mapPut(gpa, charge, ctx.int(), mapKey(n, at_summary), new.int())), .changed = true };
    }

    /// Two snapshots combined (§2.9: a construction combines its children's
    /// snapshots and joins them where they bind one key): the union of the
    /// maps, a key both bind joined. Persistent: `a` when `b` adds nothing,
    /// so a merge of a snapshot with itself is the snapshot. Every node pair
    /// inspected is a record; the recursion is the key width, 33 frames.
    pub fn kappaMerge(t: *Table, gpa: Allocator, charge: Charge, a: Kappas, b: Kappas) Error!Kappas {
        return .from(try t.mapUnion(gpa, charge, a.int(), b.int()));
    }

    fn mapUnion(t: *Table, gpa: Allocator, charge: Charge, a: u32, b: u32) Error!u32 {
        if (a == Ids.none_int) return b;
        if (b == Ids.none_int or a == b) return a;
        try charge.reserve(gpa, .inspection, 1);
        const na = t.mapNode(a);
        const nb = t.mapNode(b);
        if (nb.mask == 0) {
            const old: ?CondId = if (t.kappaGetRaw(a, nb.prefix)) |x| x else null;
            const v: CondId = if (old) |o| try t.join(gpa, charge, o, .from(nb.left)) else .from(nb.left);
            if (old != null and old.? == v) return a;
            return t.mapPut(gpa, charge, a, nb.prefix, v.int());
        }
        if (na.mask == 0) {
            const old: ?CondId = if (t.kappaGetRaw(b, na.prefix)) |x| x else null;
            const v: CondId = if (old) |o| try t.join(gpa, charge, o, .from(na.left)) else .from(na.left);
            if (old != null and old.? == v) return b;
            return t.mapPut(gpa, charge, b, na.prefix, v.int());
        }
        if (na.mask == nb.mask and na.prefix == nb.prefix) {
            const l = try t.mapUnion(gpa, charge, na.left, nb.left);
            const r = try t.mapUnion(gpa, charge, na.right, nb.right);
            if (l == na.left and r == na.right) return a;
            if (l == nb.left and r == nb.right) return b;
            return t.makeMap(gpa, charge, .{ .prefix = na.prefix, .mask = na.mask, .left = l, .right = r });
        }
        if (na.mask > nb.mask and matches(nb.prefix, na.prefix, na.mask)) {
            if (nb.prefix & na.mask == 0) {
                const l = try t.mapUnion(gpa, charge, na.left, b);
                return if (l == na.left) a else t.makeMap(gpa, charge, .{ .prefix = na.prefix, .mask = na.mask, .left = l, .right = na.right });
            }
            const r = try t.mapUnion(gpa, charge, na.right, b);
            return if (r == na.right) a else t.makeMap(gpa, charge, .{ .prefix = na.prefix, .mask = na.mask, .left = na.left, .right = r });
        }
        if (nb.mask > na.mask and matches(na.prefix, nb.prefix, nb.mask)) {
            if (na.prefix & nb.mask == 0) {
                const l = try t.mapUnion(gpa, charge, a, nb.left);
                return if (l == nb.left) b else t.makeMap(gpa, charge, .{ .prefix = nb.prefix, .mask = nb.mask, .left = l, .right = nb.right });
            }
            const r = try t.mapUnion(gpa, charge, a, nb.right);
            return if (r == nb.right) b else t.makeMap(gpa, charge, .{ .prefix = nb.prefix, .mask = nb.mask, .left = nb.left, .right = r });
        }
        return t.mapJoin(gpa, charge, na.prefix, a, nb.prefix, b);
    }

    fn kappaGetRaw(t: *const Table, root: u32, key: u32) ?CondId {
        var at = root;
        while (at != Ids.none_int) {
            const m = t.mapNode(at);
            if (m.mask == 0) return if (m.prefix == key) CondId.from(m.left) else null;
            if (!matches(key, m.prefix, m.mask)) return null;
            at = if (key & m.mask == 0) m.left else m.right;
        }
        return null;
    }

    /// The entries of a snapshot, `(node, at_summary, condition)`, in key
    /// order: a leaf walk on a stack of at most 34 entries. Iterating a
    /// whole snapshot is the caller's charged task (§4.1).
    pub const KappaIterator = struct {
        t: *const Table,
        stack: [34]u32 = undefined,
        depth: usize = 0,

        pub const Entry = struct { node: NodeId, at_summary: bool, cond: CondId };

        pub fn next(it: *KappaIterator) ?Entry {
            while (it.depth > 0) {
                it.depth -= 1;
                const m = it.t.mapNode(it.stack[it.depth]);
                if (m.mask == 0) return .{ .node = .from(m.prefix >> 1), .at_summary = m.prefix & 1 == 1, .cond = .from(m.left) };
                it.stack[it.depth] = m.right;
                it.stack[it.depth + 1] = m.left;
                it.depth += 2;
            }
            return null;
        }
    };

    pub fn kappaEntries(t: *const Table, ctx: Kappas) KappaIterator {
        var it: KappaIterator = .{ .t = t };
        if (ctx != .none) {
            it.stack[0] = ctx.int();
            it.depth = 1;
        }
        return it;
    }

    /// κ of a union or a positions node: the join of its sides' and the
    /// stored, every node of the DAG (both kinds) read ONCE per read (a seen
    /// column for this read alone, nothing goes stale; a side in progress
    /// reads `yes`). At a summary position — a positions node makes it one —
    /// the leaf rule over the root's cells besides, every cell both sides of
    /// a positions node hold counted once more (the multiset; a repeat
    /// through a side holding a recast anywhere in its DAG is `lost`). A
    /// record per node and repeated cell: linear.
    fn dagKappa(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, root: NodeId, at_summary: bool) Error!CondId {
        var memo: stamped.Column(NodeId, CondId) = .{};
        defer memo.deinit(gpa);
        var done: stamped.Column(NodeId, void) = .{};
        defer done.deinit(gpa);
        var dups: std.ArrayList(Item) = .empty;
        defer dups.deinit(gpa);
        var approx: stamped.Column(NodeId, void) = .{};
        defer approx.deinit(gpa);
        var summary = at_summary;
        const Frame = struct { node: NodeId, expanded: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, .{ .node = root, .expanded = false });
        while (stack.pop()) |f| {
            const n = f.node;
            if (done.contains(n)) continue;
            try charge.reserve(gpa, .inspection, 1);
            const nk = v.shapes.kind(n);
            const d = v.shapes.get(n);
            if (nk != .@"union" and nk != .positions) {
                try memo.put(gpa, n, try t.kappaOf(gpa, charge, v, ctx, n, at_summary));
                if (nk == .recast) try approx.put(gpa, n, {});
            } else if (!f.expanded) {
                try memo.put(gpa, n, yes);
                try stack.appendSlice(gpa, &.{ .{ .node = n, .expanded = true }, .{ .node = .from(d.a), .expanded = false }, .{ .node = .from(d.b), .expanded = false } });
                continue;
            } else {
                var k = try t.join(gpa, charge, memo.get(.from(d.a)).?, memo.get(.from(d.b)).?);
                if (t.kappaGet(ctx, n, at_summary)) |s| k = try t.join(gpa, charge, s, k);
                try memo.put(gpa, n, k);
                if (approx.contains(.from(d.a)) or approx.contains(.from(d.b))) try approx.put(gpa, n, {});
                if (nk == .positions) {
                    summary = true;
                    var it = v.cells.sets.iterate(try v.cells.sets.intersection(gpa, charge, v.shapes.cells(.from(d.a)), v.shapes.cells(.from(d.b))));
                    while (it.next()) |e| {
                        try charge.reserve(gpa, .inspection, 1);
                        try dups.append(gpa, .{ .cell = .from(e.key), .approx = approx.contains(n) or e.value == 1 });
                    }
                }
            }
            try done.put(gpa, n, {});
        }
        if (!summary) return memo.get(root).?;
        return t.@"and"(gpa, charge, memo.get(root).?, try t.derivedCells(gpa, charge, v, v.shapes.cells(root), true, dups.items));
    }

    /// κ(n) in `ctx` by the header's rules; `at_summary` is whether `n`'s
    /// path crossed a `[*]` or `⟲` (`excl` there for an arrival `isFolded`).
    pub fn kappaOf(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, at_summary: bool) Error!CondId {
        const stored = t.kappaGet(ctx, n, at_summary);
        // THE RULE (header): stored ⊔ derived at the read's position.
        const derived: CondId = switch (v.shapes.kind(n)) {
            .leaf => try t.derivedCells(gpa, charge, v, v.shapes.cells(n), at_summary, &.{}),
            // A built node's κ is the walk's (O13): `lost` until set.
            .node, .delta => return stored orelse lost,
            // A recast and its inner are one position: what is stored at
            // either counts (§2.9, §2.13.9).
            .recast => blk: {
                const d: CondId = if (holdsBelow(v.places, v.shapes.place(n))) lost else yes;
                break :blk if (t.kappaGet(ctx, .from(v.shapes.get(n).a), at_summary)) |s| try t.join(gpa, charge, s, d) else d;
            },
            .@"union", .positions => return t.dagKappa(gpa, charge, v, ctx, n, at_summary),
        };
        return if (stored) |s| t.join(gpa, charge, s, derived) else derived;
    }

    /// κ from the cells at the read's position (header), `extra` arrivals
    /// counted besides them at a summary position; charged per read.
    fn derivedCells(t: *Table, gpa: Allocator, charge: Charge, v: View, cells: SetId, at_summary: bool, extra: []const Item) Error!CondId {
        if (!at_summary) {
            var it = v.cells.sets.iterate(cells);
            while (it.next()) |e| {
                try charge.reserve(gpa, .inspection, 1);
                if (e.value == 1 or v.cells.origin(.from(e.key)) == .top) return lost;
            }
            return yes;
        }
        var items: std.ArrayList(Item) = .empty;
        defer items.deinit(gpa);
        try items.appendSlice(gpa, extra);
        var it = v.cells.sets.iterate(cells);
        while (it.next()) |e| try items.append(gpa, .{ .cell = .from(e.key), .approx = e.value == 1 });
        const k = try t.summaryExcl(gpa, charge, v.cells, v.places, cells);
        return t.@"and"(gpa, charge, k, try t.apart(gpa, charge, v.cells, v.places, items.items, null));
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
    /// structure and `excl c` for every arrival among their cells. A walk
    /// with a visited stamp, a record per node and cell, memoised per
    /// `(map root, node, position)`.
    pub fn deep(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, at_summary: bool) Error!CondId {
        const mkey = [3]u32{ ctx.int(), n.int(), @intFromBool(at_summary) };
        // Reserved before the memo is read, a hit charged like a miss (§2.3).
        try charge.reserve(gpa, .memo, 1);
        if (t.memo_deep.get(mkey)) |hit| return .from(hit);
        var seen: stamped.Column(NodeId, u8) = .{};
        defer seen.deinit(gpa);
        var stack: std.ArrayList(Next) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, .{ .node = n, .summary = at_summary, .step = Ids.none_int });
        var acc: CondId = yes;
        // The observable frontier (§2.9): below a leaf too while the
        // snapshot stores anything.
        const projected = ctx != .none;
        while (stack.pop()) |f| {
            const bit: u8 = if (f.summary) 2 else 1;
            if (seen.get(f.node)) |s| if (s & bit != 0) continue;
            try seen.put(gpa, f.node, (seen.get(f.node) orelse 0) | bit);
            try charge.reserve(gpa, .inspection, 1);
            try t.traced(gpa, f.node, f.summary);
            if (!f.explicit) {
                // A projection the structure does not name: what the arrivals
                // above claim (`excl` is deep) covers its derivation; only
                // what the snapshot stores there is more.
                if (t.kappaGet(ctx, f.node, f.summary)) |s| acc = try t.@"and"(gpa, charge, acc, s);
            } else {
                acc = try t.@"and"(gpa, charge, acc, try t.kappaOf(gpa, charge, v, ctx, f.node, f.summary));
                acc = try t.@"and"(gpa, charge, acc, try t.shallow(gpa, charge, v.cells, v.shapes.cells(f.node)));
            }
            if (acc == shared) break;
            try t.frontier(gpa, charge, v, f.node, f.summary, projected, &stack);
        }
        (try t.memo_deep.getOrPut(gpa, mkey)).value_ptr.* = acc.int();
        return acc;
    }

    /// At a summary position: `excl c` per arrival standing for many positions.
    fn summaryExcl(t: *Table, gpa: Allocator, charge: Charge, cellt: *const Cell.Table, places: *const Cell.Places, cells: SetId) Error!CondId {
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
    fn shallow(t: *Table, gpa: Allocator, charge: Charge, cellt: *const Cell.Table, cells: SetId) Error!CondId {
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
    pub fn lower(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, base_kappa: CondId, base_cells: SetId, stored: NodeId, at_summary: bool, traversal: ?Traversal) Error!CondId {
        if (base_kappa == shared) return shared;
        const split = t.splitGroup(base_kappa);
        var acc = split.rest;
        var new_arrivals: std.ArrayList(CellId) = .empty;
        defer new_arrivals.deinit(gpa);
        var it = v.cells.sets.iterate(v.shapes.cells(stored));
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
    /// is a PATH, so the transitions are the projections along the place's
    /// steps. Other nodes at `n`'s path are read by `kappaOf` of `n`: a
    /// union's or positions node's sides by `dagKappa`, a recast's inner
    /// beside the recast (a recast changes the type, not the path, so the
    /// two are one position, and the inner's own projections are the
    /// position's too: `via` names the inner, found through the sides of a
    /// union or a positions node as well); a delta's base never (a built
    /// node's κ is the walk's, O13). `explicit`: the structure names
    /// something at that step (`explicitAt`); the others and the empty ones
    /// are followed only when `projected` (a snapshot may store there). The
    /// one walk of `propagate`, `kappaLeq` and `deep`; Block writes a superset.
    pub const Next = struct { node: NodeId, summary: bool, step: u32, explicit: bool = true, via: NodeId = .none };

    pub fn frontier(t: *Table, gpa: Allocator, charge: Charge, v: View, n: NodeId, summary: bool, projected: bool, out: *std.ArrayList(Next)) Error!void {
        try t.steps(gpa, charge, v, n, summary, projected, .none, out);
        var inners: std.ArrayList(NodeId) = .empty;
        defer inners.deinit(gpa);
        try innersOf(gpa, charge, v, n, &inners);
        for (inners.items) |i| try t.steps(gpa, charge, v, i, summary, projected, i, out);
    }

    fn steps(t: *Table, gpa: Allocator, charge: Charge, v: View, n: NodeId, summary: bool, projected: bool, via: NodeId, out: *std.ArrayList(Next)) Error!void {
        for (v.places.steps(v.shapes.place(n)).steps) |s| {
            try charge.reserve(gpa, .inspection, 1);
            const c = (try v.shapes.proj(gpa, charge.account, v.places, v.cells, n, s)) orelse continue;
            // Through a recast's inner only what a snapshot stores is more:
            // an unstored inner adds nothing to the recast's derived read.
            const explicit = via == .none and try t.explicitAt(gpa, charge, v, n, s);
            const empty = v.shapes.kind(c) == .leaf and v.shapes.cells(c) == .none;
            if (!projected and (!explicit or empty)) continue;
            try out.append(gpa, .{ .node = c, .summary = summary or below(s), .step = s.word(), .explicit = explicit, .via = via });
        }
    }

    /// The inners of the recasts at `n`'s path: `n`'s own, and those of its
    /// union's or positions node's sides, each once. A record per node.
    fn innersOf(gpa: Allocator, charge: Charge, v: View, n: NodeId, out: *std.ArrayList(NodeId)) Error!void {
        switch (v.shapes.kind(n)) {
            .recast => return out.append(gpa, .from(v.shapes.get(n).a)),
            .@"union", .positions => {},
            else => return,
        }
        var stack: std.ArrayList(NodeId) = .empty;
        defer stack.deinit(gpa);
        var seen: stamped.Column(NodeId, void) = .{};
        defer seen.deinit(gpa);
        try stack.append(gpa, n);
        while (stack.pop()) |x| {
            if (seen.contains(x)) continue;
            try charge.reserve(gpa, .inspection, 1);
            try seen.put(gpa, x, {});
            const d = v.shapes.get(x);
            switch (d.kind) {
                .recast => if (!seen.contains(.from(d.a))) {
                    try seen.put(gpa, .from(d.a), {});
                    try out.append(gpa, .from(d.a));
                },
                .@"union", .positions => try stack.appendSlice(gpa, &.{ .from(d.a), .from(d.b) }),
                else => {},
            }
        }
    }

    /// A member's counterpart for a transition: itself, or for one out of a
    /// recast's inner `via`, the inner of its own recasts at that place
    /// (null: it has none, so nothing it stores is there).
    fn side(gpa: Allocator, charge: Charge, v: View, m: NodeId, via: NodeId) Error!?NodeId {
        if (via == .none) return m;
        var inners: std.ArrayList(NodeId) = .empty;
        defer inners.deinit(gpa);
        try innersOf(gpa, charge, v, m, &inners);
        for (inners.items) |i| if (v.shapes.place(i) == v.shapes.place(via)) return i;
        return null;
    }

    /// Whether `n`'s structure names something at step `s`: an override in
    /// `n`, a delta's base or a side; a leaf or a recast names nothing (its
    /// projections are derived). A record per own-path DAG node visited.
    fn explicitAt(t: *Table, gpa: Allocator, charge: Charge, v: View, n: NodeId, s: Step) Error!bool {
        _ = t;
        switch (v.shapes.kind(n)) {
            .leaf, .recast => return false,
            .node => return v.shapes.overGet(v.shapes.get(n).a, s) != null,
            .delta, .@"union", .positions => {},
        }
        var stack: std.ArrayList(NodeId) = .empty;
        defer stack.deinit(gpa);
        var seen: stamped.Column(NodeId, void) = .{};
        defer seen.deinit(gpa);
        try stack.append(gpa, n);
        while (stack.pop()) |x| {
            if (seen.contains(x)) continue;
            try charge.reserve(gpa, .inspection, 1);
            try seen.put(gpa, x, {});
            const d = v.shapes.get(x);
            switch (d.kind) {
                .leaf, .recast => {},
                .node => if (v.shapes.overGet(d.a, s) != null) return true,
                .delta => {
                    if (v.shapes.overGet(d.b, s) != null) return true;
                    try stack.append(gpa, .from(d.a));
                },
                .@"union", .positions => try stack.appendSlice(gpa, &.{ .from(d.a), .from(d.b) }),
            }
        }
        return false;
    }

    fn below(s: Step) bool {
        return s.kind == .elem or s.kind == .level;
    }

    /// `out` with κ set at every position of `joined` (a `Shape.join` of
    /// `members`, widened or not) from the members read at the same path,
    /// projected in lockstep, each in its own map: `alternatives` is the
    /// lattice join (O15), `together` `apart` across the members' cells
    /// and every member's κ. The positions are §2.9's observable frontier
    /// along place steps: below a leaf, a recast or an empty projection too
    /// while a member's snapshot stores anything (a stored entry may sit
    /// there; with none, every read below is derived from the structure).
    /// A state is `(joined node, position class, the interned run of
    /// members and snapshots)`, compared exactly and recorded before it is
    /// processed, so a cycle ends and two contexts at one node are two
    /// states (#1063, #1064). Members are read by index: the run they were
    /// cut from grows as children are pushed. A record per state, projection, cell.
    pub fn propagate(t: *Table, gpa: Allocator, charge: Charge, v: View, out: Kappas, joined: NodeId, members: []const NodeId, member_ctxs: []const Kappas, mode: Mode, at_summary: bool, traversal: ?Traversal) Error!Kappas {
        return t.propagateFrom(gpa, charge, v, out, joined, members, member_ctxs, mode, at_summary, at_summary, traversal);
    }

    /// `propagate`, the members read at their own class (a literal's `vᵢ`, §2.9).
    pub fn propagateFrom(t: *Table, gpa: Allocator, charge: Charge, v: View, out: Kappas, joined: NodeId, members: []const NodeId, member_ctxs: []const Kappas, mode: Mode, at_summary: bool, member_summary: bool, traversal: ?Traversal) Error!Kappas {
        std.debug.assert(members.len == member_ctxs.len);
        var ctx = out;
        var projected = false;
        for (member_ctxs) |c| projected = projected or c != .none;
        var runs: std.ArrayList(NodeId) = .empty;
        defer runs.deinit(gpa);
        var run_ctxs: std.ArrayList(Kappas) = .empty;
        defer run_ctxs.deinit(gpa);
        const Frame = struct { node: NodeId, first: u32, len: u32, summary: bool, msummary: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        try runs.appendSlice(gpa, members);
        try run_ctxs.appendSlice(gpa, member_ctxs);
        try stack.append(gpa, .{ .node = joined, .first = 0, .len = @intCast(members.len), .summary = at_summary, .msummary = member_summary });
        // Exact states: a run interned as a cons list of `(member, snapshot)`
        // pairs, the state `(node, class, run)`.
        var cons: Ids.FixedDict(3) = .{};
        defer cons.deinit(gpa);
        var visited: Ids.FixedDict(3) = .{};
        defer visited.deinit(gpa);
        var items: std.ArrayList(Item) = .empty;
        defer items.deinit(gpa);
        var next: std.ArrayList(Next) = .empty;
        defer next.deinit(gpa);
        while (stack.pop()) |f| {
            var run: u32 = Ids.none_int;
            var r = f.len;
            while (r > 0) {
                r -= 1;
                try charge.reserve(gpa, .memo, 1);
                const got = try cons.getOrPut(gpa, .{ runs.items[f.first + r].int(), run_ctxs.items[f.first + r].int(), run });
                if (!got.found_existing) got.value_ptr.* = got.index;
                run = got.value_ptr.*;
            }
            try charge.reserve(gpa, .memo, 1);
            const state = try visited.getOrPut(gpa, .{ f.node.int(), @as(u32, @intFromBool(f.summary)) | @as(u32, @intFromBool(f.msummary)) << 1, run });
            if (state.found_existing) continue;
            state.value_ptr.* = 1;
            try t.traced(gpa, f.node, f.summary);
            var k: CondId = yes;
            items.clearRetainingCapacity();
            for (0..f.len) |i| {
                const m = runs.items[f.first + i];
                const c = run_ctxs.items[f.first + i];
                const km = try t.kappaOf(gpa, charge, v, c, m, f.msummary);
                k = if (mode == .alternatives) try t.join(gpa, charge, k, km) else try t.@"and"(gpa, charge, k, km);
                if (mode == .together) {
                    k = try t.@"and"(gpa, charge, k, try t.summaryExcl(gpa, charge, v.cells, v.places, v.shapes.cells(m)));
                    // At the position itself every object a member holds
                    // anywhere below counts (I-κ: one object at two
                    // positions, at whatever paths, is shared — the
                    // `[ (a, b), (b, a) ]` twin); below it, the path's own.
                    const set = if (f.node == joined) try v.shapes.reach(gpa, charge.account, &v.cells.sets, m) else v.shapes.cells(m);
                    var it = v.cells.sets.iterate(set);
                    while (it.next()) |e| {
                        try charge.reserve(gpa, .inspection, 1);
                        try items.append(gpa, .{ .cell = .from(e.key), .approx = e.value == 1 });
                    }
                }
            }
            if (mode == .together) k = try t.@"and"(gpa, charge, k, try t.apart(gpa, charge, v.cells, v.places, items.items, traversal));
            if (mode == .alternatives and f.len == 0) k = lost;
            // A leaf's read is the stored ⊔ the derivation, so a κ no
            // stronger than the derivation stores nothing: what a reader
            // derives there is the same before and after the join.
            const redundant = v.shapes.kind(f.node) == .leaf and try t.leq(gpa, charge, k, try t.kappaOf(gpa, charge, v, .none, f.node, f.summary));
            if (!redundant) ctx = (try t.kappaSet(gpa, charge, ctx, f.node, f.summary, k)).ctx;
            // Children: the joined node's frontier, the members projected
            // along each step of it.
            next.clearRetainingCapacity();
            try t.frontier(gpa, charge, v, f.node, f.summary, projected, &next);
            for (next.items) |e| {
                const s = Step.fromWord(e.step);
                const child = e.node;
                const first: u32 = @intCast(runs.items.len);
                for (0..f.len) |i| {
                    try charge.reserve(gpa, .inspection, 1);
                    const m = runs.items[f.first + i];
                    const c = run_ctxs.items[f.first + i];
                    const sm = (try side(gpa, charge, v, m, e.via)) orelse continue;
                    const pm = (try v.shapes.proj(gpa, charge.account, v.places, v.cells, sm, s)) orelse continue;
                    try runs.append(gpa, pm);
                    try run_ctxs.append(gpa, c);
                }
                try stack.append(gpa, .{ .node = child, .first = first, .len = @intCast(runs.items.len - first), .summary = e.summary, .msummary = f.msummary or below(s) });
            }
        }
        return ctx;
    }

    /// `κ_a(a) ⊑ κ_b(b)` at every position the two structures put at one
    /// path (§2.9's observable frontier): a simulation over PAIRS, each
    /// once, `b` projected in lockstep along every step of `a`'s place —
    /// below a leaf, a recast or an empty projection too while either
    /// snapshot stores anything; with none, every read below is derived
    /// from cells `Shape.leq` compares (#1063).
    pub fn kappaLeq(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx_a: Kappas, a: NodeId, ctx_b: Kappas, b: NodeId, at_summary: bool) Error!bool {
        const projected = ctx_a != .none or ctx_b != .none;
        var seen: Ids.FixedDict(3) = .{};
        defer seen.deinit(gpa);
        const Frame = struct { a: NodeId, b: NodeId, summary: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        var next: std.ArrayList(Next) = .empty;
        defer next.deinit(gpa);
        try stack.append(gpa, .{ .a = a, .b = b, .summary = at_summary });
        while (stack.pop()) |f| {
            try charge.reserve(gpa, .inspection, 1);
            const got = try seen.getOrPut(gpa, .{ f.a.int(), f.b.int(), @intFromBool(f.summary) });
            if (got.found_existing) continue;
            got.value_ptr.* = 1;
            try t.traced(gpa, f.a, f.summary);
            const ka = try t.kappaOf(gpa, charge, v, ctx_a, f.a, f.summary);
            const kb = try t.kappaOf(gpa, charge, v, ctx_b, f.b, f.summary);
            if (!try t.leq(gpa, charge, ka, kb)) return false;
            next.clearRetainingCapacity();
            try t.frontier(gpa, charge, v, f.a, f.summary, projected, &next);
            for (next.items) |e| {
                const sb = (try side(gpa, charge, v, f.b, e.via)) orelse return false;
                const nb = (try v.shapes.proj(gpa, charge.account, v.places, v.cells, sb, Step.fromWord(e.step))) orelse return false;
                try stack.append(gpa, .{ .a = e.node, .b = nb, .summary = e.summary });
            }
        }
        return true;
    }

    // ---- at a call, and relying ----------------------------------------------

    /// κ instantiated at a call (§2.9, *a call*): a failure stays, every
    /// atom is answered by the caller's interpreter and the answers are
    /// conjoined. One record per atom.
    pub fn instantiate(t: *Table, gpa: Allocator, charge: Charge, k: CondId, interp: Interp) Error!CondId {
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
    pub fn rely(t: *Table, gpa: Allocator, charge: Charge, k: CondId) Error!Rely {
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

    fn setKAt(f: *Fixture, ctx: Kappas, n: NodeId, at_summary: bool, k: CondId) !Kappas {
        return (try f.conds.kappaSet(testing.allocator, f.charge(), ctx, n, at_summary, k)).ctx;
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
        try testing.expectEqual(again, f.account.growth);
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
    const same = try t.kappaSet(gpa, f.charge(), m1, built, false, yes);
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
    try testing.expectEqual(yes, try f.kappa(m3, u, false)); // the plain position is another class
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
    var m = try f.setK(.none, x, e);
    m = try f.setK(m, y_good, e);
    const fa = try Place.Step.field(&f.account, 10);
    const fb = try Place.Step.field(&f.account, 11);
    const s1 = try f.cells.result(gpa, &f.account, .result, .none, 1, rec, .record);
    const a = try f.shapes.node(gpa, &f.account, rec, try f.set(&.{s1}), try f.shapes.overPut(gpa, &f.account, try f.shapes.overPut(gpa, &f.account, Ids.none_int, fa, x), fb, x));
    m = try f.setK(m, a, yes);
    // The reviewer's probe: `{ a = X, b = X }` against `{ a = Y_bad, b =
    // Y_good }` in either order is NOT below (κ(X) = excl ⋢ κ(Y_bad) = yes).
    for ([_][2]NodeId{ .{ y_bad, y_good }, .{ y_good, y_bad } }) |pair| {
        const b = try f.shapes.node(gpa, &f.account, rec, try f.set(&.{s1}), try f.shapes.overPut(gpa, &f.account, try f.shapes.overPut(gpa, &f.account, Ids.none_int, fa, pair[0]), fb, pair[1]));
        const mb = try f.setK(m, b, yes);
        try testing.expect(!try t.kappaLeq(gpa, f.charge(), f.view(), m, a, mb, b, false));
    }
    // And a true inclusion holds, in a different map.
    const b_ok = try f.shapes.node(gpa, &f.account, rec, try f.set(&.{s1}), try f.shapes.overPut(gpa, &f.account, try f.shapes.overPut(gpa, &f.account, Ids.none_int, fa, y_good), fb, y_good));
    const mok = try f.setK(m, b_ok, yes);
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
    try testing.expectError(error.OwnershipLimit, f.conds.kappaSet(gpa, .growth(&broke), .none, l1, false, lost));
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
                3 => if (t.kappaSet(gpa, ch, .none, l12, false, lost)) |_| {} else |e| e,
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
    try testing.expectEqual(f.shapes.cells(w), f.shapes.cells(ea));
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
    try testing.expectEqual(@as(?CondId, null), t.kappaGet(m, w, true));
    // `[ g 1, g 2 ]` in the same frame: `[*].a` holds that leaf's cells at
    // TWO positions. The read joins the stored `yes` with the derivation at
    // the read's position: `apart`, and `rely` is `xreq`, never `ok` — for
    // the positions node and, under the branch's own map, for the leaf.
    const elem = try f.collect(&.{ r1, r2 });
    const me = try f.conds.propagate(gpa, f.charge(), f.view(), m, elem, &.{ r1, r2 }, &.{ m, m }, .together, true, null);
    const ea = (try f.shapes.proj(gpa, &f.account, &f.places, &f.cells, elem, fa)).?;
    try testing.expectEqual(f.shapes.cells(w), f.shapes.cells(ea));
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
        const before = f.account.growth;
        try testing.expectEqual(yes, try f.kappa(.none, u, true));
        const cost = f.account.growth - before;
        try testing.expect(cost <= 16 * depth);
        if (last > 0) try testing.expect(cost * 2 < last * 5);
        last = cost;
    }
}

test "the Rose fold: widen keeps a collection as a side of the image, its `[*]` reads lost and never shared, and `F(x) ⊑ x` holds" {
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
    // class. The collection is not expanded: it rides beside the image as
    // a side of a `union`, its kind kept — never `positions(self, self)`.
    const w = try f.shapes.widen(gpa, &f.account, &f.places, &f.cells, root);
    try testing.expect(w != root);
    try testing.expectEqual(Shape.Kind.@"union", f.shapes.kind(w));
    const side = f.shapes.get(w);
    try testing.expectEqual(Shape.Kind.node, f.shapes.kind(.from(side.a)));
    try testing.expectEqual(Shape.Kind.positions, f.shapes.kind(.from(side.b)));
    try testing.expectEqual(w, try f.projOf(try f.projOf(.from(side.a), arg), Place.Step.elem));
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
    const old = try f.setKAt(.none, child, true, shared);
    try testing.expectEqual(shared, try f.kappa(old, child, true));
    const out = try f.propagate(.none, root, &.{root}, &.{old}, .alternatives, false);
    try testing.expectEqual(shared, try f.kappa(out, child, true));
    // An empty projection holding a stored entry: a concrete list's `[*]`
    // is a leaf with no cells, and still a position.
    const site = try f.cells.site(gpa, &f.account, 7, try f.placeOf(3), .list);
    const lit = try f.leaf(3, &.{site});
    const empty = try f.projOf(lit, Place.Step.elem);
    try testing.expectEqual(SetId.none, f.shapes.cells(empty));
    const empty_old = try f.setKAt(.none, empty, true, lost);
    const empty_out = try f.propagate(.none, lit, &.{lit}, &.{empty_old}, .alternatives, false);
    try testing.expectEqual(lost, try f.kappa(empty_out, empty, true));
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
    const old = try f.setKAt(.none, child, true, shared);
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
    const at_empty = try f.setKAt(.none, try f.projOf(lit, Place.Step.elem), true, lost);
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
    const kl = try f.setKAt(.none, elems, true, shared);
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
    const Case = struct { root: NodeId, at: NodeId, summary: bool };
    const cases = [_]Case{
        .{ .root = delta, .at = try f.projOf(delta, fb), .summary = false },
        .{ .root = un, .at = try f.projOf(un, fa), .summary = false },
        .{ .root = rc, .at = try f.projOf(rc, Place.Step.elem), .summary = true },
        .{ .root = rose, .at = try f.projOf(rose, arg), .summary = false },
        .{ .root = lol, .at = try f.projOf(try f.projOf(lol, Place.Step.elem), Place.Step.elem), .summary = true },
        .{ .root = built_delta, .at = try f.projOf(built_delta, fa), .summary = false },
        .{ .root = list, .at = try f.projOf(try f.projOf(try f.projOf(list, Place.Step.elem), fa), Place.Step.elem), .summary = true },
    };
    for (cases) |c| for ([_]bool{ false, true }) |stores| {
        const ctx = if (stores) try f.setKAt(.none, c.at, c.summary, lost) else .none;
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
        try testing.expectEqualSlices(u32, want, traceSet(&lists[1]));
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
    ctxs[n_members - 1] = try f.setK(.none, try f.projOf(members[n_members - 1], fb), lost);
    const la = try f.leaf(1, &.{try f.cells.site(gpa, &f.account, 1, try f.placeOf(1), .list)});
    const lb = try f.leaf(1, &.{try f.cells.site(gpa, &f.account, 2, try f.placeOf(1), .list)});
    const site = try f.cells.site(gpa, &f.account, 3, try f.placeOf(0), .record);
    const joined = try f.shapes.node(gpa, &f.account, try f.placeOf(0), try f.set(&.{site}), try f.shapes.overPut(gpa, &f.account, try f.shapes.overPut(gpa, &f.account, Ids.none_int, fa, la), fb, lb));
    const out = try f.propagate(.none, joined, &members, &ctxs, .alternatives, false);
    try testing.expectEqual(lost, try f.kappa(out, lb, false));
    try testing.expectEqual(yes, try f.kappa(out, la, false));
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
    const ctx = try f.setK(.none, x, lost);
    var trace: std.ArrayList(u32) = .empty;
    defer trace.deinit(gpa);
    f.conds.trace = &trace;
    const out = try f.propagate(.none, joined, &.{member}, &.{ctx}, .alternatives, false);
    f.conds.trace = null;
    try testing.expectEqual(lost, try f.kappa(out, cc, false));
    try testing.expectEqual(@as(usize, 2), traceCount(trace.items, cc, false));
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
    const stored = try f.setKAt(.none, kids, false, shared);
    var trace: std.ArrayList(u32) = .empty;
    defer trace.deinit(gpa);
    f.conds.trace = &trace;
    const out = try f.propagate(.none, joined, &.{ a, b }, &.{ stored, .none }, .alternatives, false);
    f.conds.trace = null;
    try testing.expectEqual(shared, try f.kappa(out, try f.projOf(joined, arg), false));
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
    const ctx = try f.setKAt(.none, elems, true, k);
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
        const km = try f.setKAt(.none, elems, true, k);
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
    try testing.expectEqual(e, t.kappaGet(m, lp, false).?);
    try testing.expectEqual(lost, t.kappaGet(m, lq, false).?);
    try testing.expectEqual(a, try t.kappaMerge(gpa, f.charge(), a, a));
    try testing.expectEqual(a, try t.kappaMerge(gpa, f.charge(), a, .none));
    try testing.expectEqual(b, try t.kappaMerge(gpa, f.charge(), .none, b));
    // One key in both: joined (lost wins over an atom).
    const c = try f.setK(.none, lp, lost);
    try testing.expectEqual(lost, t.kappaGet(try t.kappaMerge(gpa, f.charge(), a, c), lp, false).?);
    // The entries, every one once.
    var it = t.kappaEntries(m);
    var n: u32 = 0;
    while (it.next()) |x| : (n += 1) try testing.expect(!x.at_summary);
    try testing.expectEqual(@as(u32, 2), n);
}
