//! L4: conditions, the exclusivity κ of a value's contents
//! (`docs/design/ownership-v2.md` §2.9, §3.4). Each shape node carries a
//! condition — the `kappa` column, owned here and not by `Shape` (D1) —
//! saying whether the objects at the node's path are exclusive: `yes`, a
//! conjunction of atoms over arrivals, `shared` (fails exactly: one cell at
//! two positions) or `lost` (fails approximately).
//!
//! **Atoms name arrivals only** (parameters, captures, callback results and
//! their refinements): `excl c` (everything under `c` exclusive), `sep c d`
//! (deep separation: no object of `c` is one of `d`, at any path — which is
//! what lets a symbolic leaf's projections inherit `yes`), `apart{S}` (every
//! `sep` over a set, stated once, #693), `within λ⋆` (§2.10's self-atom),
//! `keep cb_j`, `writes cb_j`.
//!
//! **Two conjunctions.** `and` is the O(1) interned binary node a store
//! forms (a chain of W stores is W outer nodes); `join` is the lattice join
//! `yes ⊑ and{A} ⊑ and{A ∪ B} ⊑ lost ⊑ shared`, which returns the CANONICAL
//! form of an atom set (`ofSet`: one id per set, built over the persistent
//! set of atom ids), so a fixpoint sees `and(A, A) = A` and no new nesting
//! round to round (§2.12). `flat` is the charged flattening between them,
//! memoised per node. `shared` sits above `lost`: an exact failure wins as a
//! cause (R-6.3).
//!
//! **Where κ is computed.** `sep` decides one pair of cells by §2.9's table
//! over `Cell.alias`; `apart` decides a construction's stored multiset in
//! one sort (duplicates are `shared` or `lost`, the arrivals one `apart`
//! group, pairs of one base individually); `deep` conjoins everything under
//! a node; `lower` is §2.9's construction rule; `propagate` sets κ on a
//! `Shape.join` result from its members, as alternatives (a branch: the
//! lattice join, O15) or together (a literal's elements: `apart` across the
//! members at every path); `instantiate` maps a class's κ through the
//! caller's interpreter at a call; `rely` is what a write that needs κ
//! reads (`yes` passes, atoms become `xreq`, a failure is `exclusive`).
//!
//! **Defaults.** A node whose κ was never set reads `yes` for a leaf of
//! arrivals (their `excl`/`sep` atoms are deep and cover every projection),
//! `lost` for a leaf holding `⊤` or an approximate pair, the join of its
//! sides for a union, `lost` for a recast, and `lost` for a built node or a
//! delta — the walk sets those (O13), never a default.
//!
//! **Callback labels.** Two different `cb j` labels compared here are an
//! atom; two `taken` elements of one container from two splits are apart
//! only under the container's κ and §2.2's one-traversal rule, which the
//! caller answers through `Traversal` (S4's `Calls`); without it the pair
//! is `lost`. `Cond` never calls up (§5).
//!
//! Every record — a condition, an atom set node, a memo, each inspection
//! of a node or cell — is reserved on the caller's `Charge` before the work
//! it stands for (§4.1, §4.4).
//!
//! Obligations kept here: O13 (a construction's κ is `yes` only when the
//! stored cells are pairwise apart and each stored value's deep condition
//! holds; a stored refinement of the base's own `[*]` is `shared`), O15
//! (κ(join) is below every member's; a union's κ is the join of its sides').

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

/// S4's answer for two `taken` elements of one container from distinct
/// splits (§2.2, *Traversals*): apart under the container's κ when both are
/// `single` and of one entry prefix, else null (`lost`).
pub const Traversal = struct {
    ctx: *anyopaque,
    apart: *const fn (ctx: *anyopaque, container: CellId, a: CellId, b: CellId) ?CondId,
};

/// A caller's interpretation of one atom at a call (§2.9, *a call*):
/// `excl c` becomes the argument's deep condition at `c`'s path, `sep`
/// the two arrivals' separation, `keep`/`writes` the actual's facts,
/// `within`/a label `sep` the instantiation of §2.11 item 5.
pub const Interp = struct {
    ctx: *anyopaque,
    atom: *const fn (ctx: *anyopaque, t: *Table, gpa: Allocator, charge: Charge, atom: Cond) Error!CondId,
};

/// How a cell and a label print, the layer above's (`Summary`).
pub const Printer = struct {
    ctx: *anyopaque,
    cell: *const fn (ctx: *anyopaque, w: *std.Io.Writer, c: CellId) std.Io.Writer.Error!void,
    label: *const fn (ctx: *anyopaque, w: *std.Io.Writer, l: LabelId) std.Io.Writer.Error!void,
};

/// `rely`'s answer (§2.9, *Where κ is relied on*).
pub const Rely = union(enum) {
    ok,
    /// The atoms the frame relied on: its class's `xreq`.
    xreq: SetId,
    refused: Exactness,
};

/// How `propagate` reads the members of a joined node.
pub const Mode = enum(u8) {
    /// A branch: one member or another. κ is the lattice join (O15).
    alternatives,
    /// A summary position holding every member (a literal's elements, a
    /// `[*]` after a store): `apart` across the members at every path, and
    /// every member's condition.
    together,
};

pub const Table = struct {
    conds: std.MultiArrayList(Cond) = .empty,
    intern: Ids.FixedDict(3) = .{},
    /// The persistent sets of atom ids (`flat`, `apart`'s groups are cell
    /// sets and live in `Cell.Table.sets`).
    atoms: Cell.Radix = .{},
    /// κ per node, dense per walk (§3.4).
    kappa: stamped.Column(NodeId, CondId) = .{},
    /// Bumped by every κ change: what `memo_deep` is versioned by.
    kappa_version: u32 = 1,
    kappa_visiting: stamped.Column(NodeId, void) = .{},
    /// `flat`'s memo: the atom set of a condition (`.none` for `yes`).
    flat_memo: stamped.Column(CondId, SetId) = .{},
    /// `ofSet`'s memo: the canonical condition of an atom set.
    of_set: Ids.FixedDict(1) = .{},
    memo_deep: stamped.Column(NodeId, Deep) = .{},
    /// `sep`'s memo for an exact pair with no traversal context.
    memo_sep: Ids.FixedDict(2) = .{},
    /// `propagate`'s visited set and the member runs it saw.
    visited: stamped.Column(NodeId, u32) = .{},

    const Deep = struct { cond: CondId, version: u32 };

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
        t.kappa.deinit(gpa);
        t.kappa_visiting.deinit(gpa);
        t.flat_memo.deinit(gpa);
        t.of_set.deinit(gpa);
        t.memo_deep.deinit(gpa);
        t.memo_sep.deinit(gpa);
        t.visited.deinit(gpa);
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
        const got = try t.intern.getOrPut(gpa, .{ (@as(u32, @backingInt(c.kind)) << 8) | @backingInt(c.atom), c.a, c.b });
        if (got.found_existing) return .from(got.value_ptr.*);
        got.value_ptr.* = @intCast(t.conds.len);
        try t.conds.append(gpa, c);
        return .from(got.value_ptr.*);
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

    /// The atom `sep a b` (deep separation of two arrivals), unordered.
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

    /// The atom set of `c`, which must not be a failure: `.none` for `yes`,
    /// else the persistent set of its atoms' ids. An `and` tree is walked
    /// once on an explicit stack, every node read one inspection, every
    /// inner node memoised, so a chain of W stores flattens in O(W log W)
    /// once and its prefixes are shared.
    pub fn flat(t: *Table, gpa: Allocator, charge: Charge, c: CondId) Error!SetId {
        std.debug.assert(!fails(c));
        if (c == yes) return .none;
        if (t.flat_memo.get(c)) |s| return s;
        if (t.kind(c) == .atom) {
            const s = try t.atoms.insert(gpa, charge, .none, c.int(), 0);
            try t.flat_memo.put(gpa, c, s);
            return s;
        }
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

    /// The canonical condition of an atom set: `yes` for the empty set, the
    /// atom alone for one, else the left-nested `and` chain in ascending
    /// atom id — one id per set (memoised), which is what makes a fixpoint's
    /// `join` idempotent (§2.12). O(|S| log) once per set.
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

    // ---- the κ column ----------------------------------------------------

    /// κ(n) (§2.9): the column, or the default of the header.
    pub fn kappaOf(t: *Table, gpa: Allocator, charge: Charge, shapes: *Shape.Table, cellt: *const Cell.Table, n: NodeId) Error!CondId {
        if (t.kappa.get(n)) |k| return k;
        switch (shapes.kind(n)) {
            .leaf => {
                var it = cellt.sets.iterate(shapes.cells(n));
                while (it.next()) |e| {
                    try charge.reserve(gpa, .inspection, 1);
                    if (e.value == 1 or cellt.origin(.from(e.key)) == .top) return lost;
                }
                return yes;
            },
            .recast, .node, .delta => return lost,
            .@"union" => {
                // A cycle through unions contributes nothing new (the least
                // solution): the side being computed reads `yes`.
                if (t.kappa_visiting.contains(n)) return yes;
                try t.kappa_visiting.put(gpa, n, {});
                defer t.kappa_visiting.remove(n);
                const d = shapes.get(n);
                const l = try t.kappaOf(gpa, charge, shapes, cellt, .from(d.a));
                const r = try t.kappaOf(gpa, charge, shapes, cellt, .from(d.b));
                const k = try t.join(gpa, charge, l, r);
                try charge.reserve(gpa, .cond, 1);
                try t.kappa.put(gpa, n, k);
                return k;
            },
        }
    }

    /// Set κ(n), joined with what is there (monotone round to round,
    /// §2.12); whether it changed. One record.
    pub fn setKappa(t: *Table, gpa: Allocator, charge: Charge, n: NodeId, k: CondId) Error!bool {
        try charge.reserve(gpa, .cond, 1);
        const new = if (t.kappa.get(n)) |old| try t.join(gpa, charge, old, k) else k;
        if (t.kappa.get(n)) |old| if (old == new) return false;
        try t.kappa.put(gpa, n, new);
        t.kappa_version += 1;
        return true;
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
            .result, .esc, .cb => cellt.labelOf(.from(d.a)).folded,
            .param, .env, .shared, .msg => places.isSummary(.from(d.b)),
            .elem, .others, .level, .below, .loan => cellt.labelOf(.from(d.b)).folded,
        };
    }

    /// `sep(a, b)` (§2.9): are the objects of `a` and `b` apart? Two concrete
    /// cells distinct → `yes`; one unfolded cell twice → `shared`, a folded
    /// one twice → `lost`; `⊤` or an approximate pair → `lost`; two arrivals
    /// that `alias` tells apart (`no`) → the atom `sep a b`, that it says may
    /// be one (`yes`) → `lost`; the two sides of one split → the split's κ;
    /// two `taken` elements of one container → the traversal rule, or `lost`.
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

    /// One stored cell of a construction, with its pair's approximation.
    pub const Item = struct { cell: CellId, approx: bool };

    /// §2.9's construction rule over the cells stored at one path, a
    /// multiset: sorted once (every item one record), a duplicate decides
    /// at once (`shared`, or `lost` for a folded cell), `⊤` and an
    /// approximate pair are `lost`, the arrivals form one `apart` group, and
    /// the pairs of arrivals over one base (a prefix, a split's sides, two
    /// `taken` elements) are decided one by one, each charged. Concrete
    /// cells are fresh and apart from everything else by construction.
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
                acc = try t.@"and"(gpa, charge, acc, try t.sep(gpa, charge, cellt, places, c, c, false, traversal));
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
            acc = try t.@"and"(gpa, charge, acc, try t.apartAtom(gpa, charge, group));
            // Pairs over one base: sorted by base, each run's pairs decided.
            const Ctx = struct { cellt: *const Cell.Table };
            std.mem.sort(CellId, arrivals.items, Ctx{ .cellt = cellt }, struct {
                fn lessThan(ctx: Ctx, x: CellId, y: CellId) bool {
                    const bx = ctx.cellt.base(x).int();
                    const by = ctx.cellt.base(y).int();
                    return if (bx != by) bx < by else x.int() < y.int();
                }
            }.lessThan);
            var k: usize = 0;
            while (k < arrivals.items.len) {
                var m = k + 1;
                while (m < arrivals.items.len and cellt.base(arrivals.items[m]) == cellt.base(arrivals.items[k])) m += 1;
                var x = k;
                while (x < m) : (x += 1) {
                    var y = x + 1;
                    while (y < m) : (y += 1) {
                        if (cellt.alias(places, arrivals.items[x], arrivals.items[y]) == .no) continue; // in the group
                        acc = try t.@"and"(gpa, charge, acc, try t.sep(gpa, charge, cellt, places, arrivals.items[x], arrivals.items[y], false, traversal));
                        if (acc == shared) return shared;
                    }
                }
                k = m;
            }
        }
        return acc;
    }

    /// The deep condition of a node: κ of every node of its explicit
    /// structure conjoined with `excl c` for every arrival among their
    /// cells (`lost` for `⊤`, an approximate pair or a recast). A walk with
    /// a visited stamp, every node and cell one record, memoised per node
    /// until κ changes anywhere.
    pub fn deep(t: *Table, gpa: Allocator, charge: Charge, shapes: *Shape.Table, cellt: *const Cell.Table, n: NodeId) Error!CondId {
        if (t.memo_deep.get(n)) |d| if (d.version == t.kappa_version) return d.cond;
        var seen: stamped.Column(NodeId, void) = .{};
        defer seen.deinit(gpa);
        var stack: std.ArrayList(NodeId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, n);
        var acc: CondId = yes;
        while (stack.pop()) |m| {
            if (seen.contains(m)) continue;
            try seen.put(gpa, m, {});
            try charge.reserve(gpa, .inspection, 1);
            acc = try t.@"and"(gpa, charge, acc, try t.kappaOf(gpa, charge, shapes, cellt, m));
            acc = try t.@"and"(gpa, charge, acc, try t.shallow(gpa, charge, cellt, shapes.cells(m)));
            if (acc == shared) break;
            const d = shapes.get(m);
            switch (d.kind) {
                .leaf => {},
                .recast => acc = try t.@"and"(gpa, charge, acc, lost),
                .node => {
                    var it = shapes.overEntries(d.a);
                    while (it.next()) |e| try stack.append(gpa, e.node);
                },
                .delta => {
                    try stack.append(gpa, .from(d.a));
                    var it = shapes.overEntries(d.b);
                    while (it.next()) |e| try stack.append(gpa, e.node);
                },
                .@"union" => try stack.appendSlice(gpa, &.{ .from(d.a), .from(d.b) }),
            }
        }
        try charge.reserve(gpa, .memo, 1);
        try t.memo_deep.put(gpa, n, .{ .cond = acc, .version = t.kappa_version });
        return acc;
    }

    /// `excl c` for every arrival in a cell set, `lost` for `⊤` or an
    /// approximate pair: a node's own contribution to a deep condition.
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

    /// §2.9's construction rule: the base's κ at the written path lowered by
    /// a stored value — `apart` over the stored value's cells beside what the
    /// base holds there (a cell the base already holds is `shared`), and
    /// the stored value's deep condition.
    pub fn lower(t: *Table, gpa: Allocator, charge: Charge, shapes: *Shape.Table, cellt: *Cell.Table, places: *const Cell.Places, base_kappa: CondId, base_cells: SetId, stored: NodeId, traversal: ?Traversal) Error!CondId {
        if (base_kappa == shared) return shared;
        var items: std.ArrayList(Item) = .empty;
        defer items.deinit(gpa);
        inline for (.{ shapes.cells(stored), base_cells }) |s| {
            var it = cellt.sets.iterate(s);
            while (it.next()) |e| try items.append(gpa, .{ .cell = .from(e.key), .approx = e.value == 1 });
        }
        const across = try t.apart(gpa, charge, cellt, places, items.items, traversal);
        if (across == shared) return shared;
        const k = try t.@"and"(gpa, charge, base_kappa, across);
        return t.@"and"(gpa, charge, k, try t.deep(gpa, charge, shapes, cellt, stored));
    }

    // ---- joins -------------------------------------------------------------

    /// Set κ on every node of `joined`'s explicit structure (a `Shape.join`
    /// of `members`, widened or not) from the members' nodes at the same
    /// path, projected in lockstep: as `alternatives`, the lattice join
    /// (O15); as `together`, `apart` across the members' cells at the path
    /// and every member's κ there. Leaves are set and not descended (their
    /// deep atoms cover their projections); a node met again with another
    /// member run is joined again. Every node, projection and cell is a
    /// record. `members` is read, not reordered.
    pub fn propagate(t: *Table, gpa: Allocator, charge: Charge, shapes: *Shape.Table, cellt: *Cell.Table, places: *Cell.Places, joined: NodeId, members: []const NodeId, mode: Mode, traversal: ?Traversal) Error!void {
        var runs: std.ArrayList(NodeId) = .empty;
        defer runs.deinit(gpa);
        const Frame = struct { node: NodeId, first: u32, len: u32 };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        try runs.appendSlice(gpa, members);
        try stack.append(gpa, .{ .node = joined, .first = 0, .len = @intCast(members.len) });
        t.visited.clear();
        var items: std.ArrayList(Item) = .empty;
        defer items.deinit(gpa);
        while (stack.pop()) |f| {
            const ms = runs.items[f.first..][0..f.len];
            // The run's signature: a visit with the same members is done.
            var sig: u32 = 0x811C9DC5;
            for (ms) |m| sig = (sig ^ m.int()) *% 0x01000193;
            if (t.visited.get(f.node)) |s| if (s == sig) continue;
            try t.visited.put(gpa, f.node, sig);
            try charge.reserve(gpa, .inspection, 1);
            var k: CondId = yes;
            items.clearRetainingCapacity();
            for (ms) |m| {
                const km = try t.kappaOf(gpa, charge, shapes, cellt, m);
                k = if (mode == .alternatives) try t.join(gpa, charge, k, km) else try t.@"and"(gpa, charge, k, km);
                if (mode == .together) {
                    k = try t.@"and"(gpa, charge, k, try t.shallow(gpa, charge, cellt, shapes.cells(m)));
                    var it = cellt.sets.iterate(shapes.cells(m));
                    while (it.next()) |e| try items.append(gpa, .{ .cell = .from(e.key), .approx = e.value == 1 });
                }
            }
            if (mode == .together) k = try t.@"and"(gpa, charge, k, try t.apart(gpa, charge, cellt, places, items.items, traversal));
            if (mode == .alternatives and ms.len == 0) k = lost;
            _ = try t.setKappa(gpa, charge, f.node, k);
            if (shapes.kind(f.node) == .leaf or shapes.kind(f.node) == .recast) continue;
            // Children: every step of the place the joined node has
            // something at, the members projected along it.
            const steps = places.steps(shapes.place(f.node));
            for (steps.steps) |s| {
                const child = (try shapes.proj(gpa, charge.account, places, cellt, f.node, s)) orelse continue;
                if (shapes.kind(child) == .leaf and shapes.cells(child) == .none) continue;
                const first: u32 = @intCast(runs.items.len);
                for (ms) |m| {
                    try charge.reserve(gpa, .inspection, 1);
                    const pm = (try shapes.proj(gpa, charge.account, places, cellt, m, s)) orelse continue;
                    try runs.append(gpa, pm);
                }
                try stack.append(gpa, .{ .node = child, .first = first, .len = @intCast(runs.items.len - first) });
            }
        }
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

    /// A condition as a summary line prints it (v1's grammar): nothing when
    /// it holds, `{lost}`, `{shared}`, or `{atom, atom}` with the atoms in
    /// text order. `arena` holds the atom texts while they are sorted.
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
    std.debug.assert(@sizeOf(Cond) == 12);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Place = @import("Place.zig");

/// A test type graph: 0 a record `{ a : List Int, b : List Int }`, 1 `List
/// Int`, 2 `Int`, 3 `List (List Int)`.
const TestGraph = struct {
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
        f.graph = .{ .account = &f.account, .gpa = testing.allocator };
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
        var items: std.ArrayList(Table.Item) = .empty;
        defer items.deinit(testing.allocator);
        for (cells) |c| try items.append(testing.allocator, .{ .cell = c, .approx = false });
        return f.conds.apart(testing.allocator, f.charge(), &f.cells, &f.places, items.items, null);
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
    // The unit and the absorbers.
    try testing.expectEqual(e1, try t.@"and"(gpa, f.charge(), yes, e1));
    try testing.expectEqual(shared, try t.@"and"(gpa, f.charge(), lost, shared));
    try testing.expectEqual(lost, try t.@"and"(gpa, f.charge(), e1, lost));
    try testing.expectEqual(e1, try t.@"and"(gpa, f.charge(), e1, e1));
    // Commutative by interning.
    const a12 = try t.@"and"(gpa, f.charge(), e1, e2);
    try testing.expectEqual(a12, try t.@"and"(gpa, f.charge(), e2, e1));
    // Two different nestings of one atom set flatten to one set and join
    // to one canonical condition.
    const x = try t.@"and"(gpa, f.charge(), a12, e3);
    const y = try t.@"and"(gpa, f.charge(), e1, try t.@"and"(gpa, f.charge(), e3, e2));
    try testing.expect(x != y);
    try testing.expectEqual(try t.flat(gpa, f.charge(), x), try t.flat(gpa, f.charge(), y));
    try testing.expectEqual(@as(u32, 3), t.atoms.count(try t.flat(gpa, f.charge(), x)));
    const jx = try t.join(gpa, f.charge(), x, yes);
    const jy = try t.join(gpa, f.charge(), y, yes);
    try testing.expectEqual(jx, jy);
    try testing.expectEqual(jx, try t.join(gpa, f.charge(), jx, jx));
    try testing.expectEqual(jx, try t.join(gpa, f.charge(), x, y));
    try testing.expectEqual(jx, try t.join(gpa, f.charge(), a12, e3));
    // The order: yes ⊑ and{A} ⊑ and{A ∪ B} ⊑ lost ⊑ shared.
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
    // rely: nothing, atoms, a refusal.
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
        // Forming: a constant number of records per store (the param cell,
        // its path, the atom, the and node).
        try testing.expect(f.account.growth - before_form <= 12 * w);
        const before = f.account.growth;
        const s = try t.flat(gpa, f.charge(), acc);
        try testing.expectEqual(w, t.atoms.count(s));
        const cost = f.account.growth - before;
        // Flattening: O(W log W) records; less than 2.5× per doubling.
        try testing.expect(cost <= 40 * w * (std.math.log2_int(u32, w) + 1));
        if (last_cost > 0) try testing.expect(cost * 2 < last_cost * 5);
        last_cost = cost;
        // A second flattening of the same chain is a memo hit.
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
    // Two fresh objects: apart. A fresh object and an arrival: apart.
    try testing.expectEqual(yes, try f.sep(s7, s8));
    try testing.expectEqual(yes, try f.sep(s7, p1));
    // One cell twice: shared; under a summary position, lost.
    try testing.expectEqual(shared, try f.sep(s7, s7));
    try testing.expectEqual(shared, try f.sep(p1, p1));
    const elems = try f.param(3, 3, &.{Place.Step.elem});
    try testing.expectEqual(lost, try f.sep(elems, elems));
    // ⊤ and an approximate pair: lost.
    try testing.expectEqual(lost, try f.sep(top, s7));
    try testing.expectEqual(lost, try f.sep(top, top));
    try testing.expectEqual(lost, try t.sep(gpa, f.charge(), &f.cells, &f.places, p1, p2, true, null));
    // Two arrivals that may not be one object: the atom; a prefix: lost.
    const atom = try f.sep(p1, p2);
    try testing.expectEqual(Kind.atom, t.kind(atom));
    try testing.expectEqual(atom, try f.sep(p2, p1));
    try testing.expectEqual(atom, try t.sepAtom(gpa, f.charge(), p2, p1));
    try testing.expectEqual(Kind.atom, t.kind(try f.sep(p1a, p1b)));
    try testing.expectEqual(lost, try f.sep(p1, p1a));
    // Two `cb` labels: an atom; one folded label twice: lost.
    const l1 = try f.cells.label(gpa, &f.account, 40, .none, false);
    const l2 = try f.cells.label(gpa, &f.account, 41, .none, true);
    const root1 = try f.places.rootPath(gpa, list);
    const cb1 = try f.cells.symbolic(gpa, &f.account, &f.places, .cb, l1.int(), root1, 5);
    const cb2 = try f.cells.symbolic(gpa, &f.account, &f.places, .cb, l2.int(), root1, 5);
    try testing.expectEqual(Kind.atom, t.kind(try f.sep(cb1, cb2)));
    try testing.expectEqual(shared, try f.sep(cb1, cb1));
    try testing.expectEqual(lost, try f.sep(cb2, cb2));
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
        // One `apart` atom over the n cells and nothing else.
        try testing.expectEqual(Kind.atom, t.kind(k));
        try testing.expectEqual(AtomKind.apart, t.get(k).atom);
        try testing.expectEqual(n, f.cells.sets.count(.from(t.get(k).a)));
        // Linear: less than 2.5× per doubling (the set's path copies are the
        // log factor).
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
    // `[ r, r ]`: shared, exact. `[ a, b ]` of fresh lists: yes.
    try testing.expectEqual(shared, try f.apart(&.{ p1, p1 }));
    try testing.expectEqual(shared, try f.apart(&.{ s7, s7, p1 }));
    try testing.expectEqual(yes, try f.apart(&.{ s7, s8 }));
    try testing.expectEqual(yes, try f.apart(&.{s7}));
    try testing.expectEqual(yes, try f.apart(&.{}));
    // One arrival among fresh cells needs no atom; two arrivals one.
    try testing.expectEqual(yes, try f.apart(&.{ s7, p1 }));
    const k = try f.apart(&.{ s7, p1, p2 });
    try testing.expectEqual(AtomKind.apart, t.get(k).atom);
    // ⊤ is lost; an approximate pair is lost; a duplicate still wins.
    try testing.expectEqual(lost, try f.apart(&.{ try f.cells.top(gpa, &f.account), s7 }));
    var items = [_]Table.Item{ .{ .cell = p1, .approx = true }, .{ .cell = p2, .approx = false } };
    try testing.expectEqual(lost, try t.apart(gpa, f.charge(), &f.cells, &f.places, &items, null));
    var dup = [_]Table.Item{ .{ .cell = p1, .approx = true }, .{ .cell = p2, .approx = false }, .{ .cell = p2, .approx = false } };
    try testing.expectEqual(shared, try t.apart(gpa, f.charge(), &f.cells, &f.places, &dup, null));
    // The taken element stored back beside the others of its split: the
    // split's κ decides; with κ `shared` at the split, `shared`
    // (R-4.6.9, `[ p, …_ ] → [ …l, p ]`).
    const l1 = try f.cells.label(gpa, &f.account, 40, .none, false);
    _ = try f.cells.split(gpa, &f.account, p1, 40, l1, shared);
    const e1 = try f.cells.refine(gpa, &f.account, .elem, p1, l1, 0, .none, .none);
    const o1 = try f.cells.refine(gpa, &f.account, .others, p1, l1, 0, .none, .list);
    try testing.expectEqual(shared, try f.apart(&.{ e1, o1 }));
    // With κ an atom at the split: that atom beside the apart group.
    const xs = try f.param(3, 1, &.{});
    const kx = try t.excl(gpa, f.charge(), xs);
    _ = try f.cells.split(gpa, &f.account, xs, 41, l1, kx);
    const ex = try f.cells.refine(gpa, &f.account, .elem, xs, l1, 0, .none, .none);
    const ox = try f.cells.refine(gpa, &f.account, .others, xs, l1, 0, .none, .list);
    const kk = try f.apart(&.{ ex, ox });
    try testing.expect(t.atoms.member(try t.flat(gpa, f.charge(), kk), kx.int()));
}

test "κ: defaults, monotone setting, deep conditions and the construction rule" {
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
    const ltop = try f.leaf(1, &.{top});
    const nothing = try f.shapes.nothing(gpa, &f.account, list);
    // Defaults: a leaf of arrivals yes, ⊤ lost, nothing yes, a built node
    // lost until set, a recast lost.
    try testing.expectEqual(yes, try t.kappaOf(gpa, f.charge(), &f.shapes, &f.cells, l1));
    try testing.expectEqual(lost, try t.kappaOf(gpa, f.charge(), &f.shapes, &f.cells, ltop));
    try testing.expectEqual(yes, try t.kappaOf(gpa, f.charge(), &f.shapes, &f.cells, nothing));
    const s9 = try f.cells.site(gpa, &f.account, 9, lists, .list);
    const children = try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, l1);
    const built = try f.shapes.node(gpa, &f.account, lists, try f.set(&.{s9}), children);
    try testing.expectEqual(lost, try t.kappaOf(gpa, f.charge(), &f.shapes, &f.cells, built));
    try testing.expectEqual(lost, try t.kappaOf(gpa, f.charge(), &f.shapes, &f.cells, try f.shapes.recast(gpa, &f.account, lists, l1)));
    // Setting joins: yes then an atom then lost; a union reads its sides'.
    const e1 = try t.excl(gpa, f.charge(), p1);
    try testing.expect(try t.setKappa(gpa, f.charge(), built, yes));
    try testing.expect(!try t.setKappa(gpa, f.charge(), built, yes));
    try testing.expect(try t.setKappa(gpa, f.charge(), built, e1));
    try testing.expectEqual(e1, try t.kappaOf(gpa, f.charge(), &f.shapes, &f.cells, built));
    const l2 = try f.leaf(1, &.{p2});
    const u = try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, l2, ltop);
    try testing.expectEqual(lost, try t.kappaOf(gpa, f.charge(), &f.shapes, &f.cells, u));
    // deep: the node's κ, plus `excl` of every arrival inside.
    const d = try t.deep(gpa, f.charge(), &f.shapes, &f.cells, built);
    const fd = try t.flat(gpa, f.charge(), d);
    try testing.expectEqual(@as(u32, 1), t.atoms.count(fd));
    try testing.expect(t.atoms.member(fd, e1.int()));
    // The version: κ changed elsewhere invalidates the memo.
    try testing.expect(try t.setKappa(gpa, f.charge(), built, lost));
    try testing.expectEqual(lost, try t.deep(gpa, f.charge(), &f.shapes, &f.cells, built));
    // lower: `List.push ys p2` where `ys` is `[ p1 ]` exclusive: the base's
    // κ ∧ apart{p2, p1} ∧ excl p2 — and storing `p1` again is shared.
    const base_k = try t.excl(gpa, f.charge(), p1);
    const stored2 = try f.leaf(1, &.{p2});
    const k = try t.lower(gpa, f.charge(), &f.shapes, &f.cells, &f.places, base_k, try f.set(&.{p1}), stored2, null);
    const fk = try t.flat(gpa, f.charge(), k);
    try testing.expectEqual(@as(u32, 3), t.atoms.count(fk));
    try testing.expect(t.atoms.member(fk, base_k.int()));
    try testing.expect(t.atoms.member(fk, (try t.excl(gpa, f.charge(), p2)).int()));
    try testing.expectEqual(shared, try t.lower(gpa, f.charge(), &f.shapes, &f.cells, &f.places, base_k, try f.set(&.{p1}), l1, null));
    try testing.expectEqual(shared, try t.lower(gpa, f.charge(), &f.shapes, &f.cells, &f.places, shared, .none, stored2, null));
}

test "propagate: a branch joins κ, a literal's elements are apart at every path" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var t = &f.conds;
    const list = try f.placeOf(1);
    const lists = try f.placeOf(3);
    const p1 = try f.param(1, 3, &.{});
    const p2 = try f.param(2, 3, &.{});
    const s7 = try f.cells.site(gpa, &f.account, 7, lists, .list);
    const s8 = try f.cells.site(gpa, &f.account, 8, lists, .list);
    const l1 = try f.leaf(3, &.{p1});
    const l2 = try f.leaf(3, &.{p2});
    // Two built lists of lists: `a = [ xs ]` (xs = p1's elements) and
    // `b = [ ys ]`, κ yes each.
    const xs = try f.shapes.leaf(gpa, &f.account, list, try f.set(&.{try f.param(3, 1, &.{})}));
    const ys = try f.shapes.leaf(gpa, &f.account, list, try f.set(&.{try f.param(4, 1, &.{})}));
    const a = try f.shapes.node(gpa, &f.account, lists, try f.set(&.{s7}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, xs));
    const b = try f.shapes.node(gpa, &f.account, lists, try f.set(&.{s8}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, ys));
    _ = try t.setKappa(gpa, f.charge(), a, yes);
    _ = try t.setKappa(gpa, f.charge(), b, lost);
    // A branch: `if c then a else b` — κ is the join, lost.
    var members = [_]NodeId{ a, b };
    const j = try f.shapes.join(gpa, &f.account, &f.places, &f.cells, &members);
    try t.propagate(gpa, f.charge(), &f.shapes, &f.cells, &f.places, j, &.{ a, b }, .alternatives, null);
    try testing.expectEqual(lost, try t.kappaOf(gpa, f.charge(), &f.shapes, &f.cells, j));
    // A branch over two leaves of arrivals: yes stays yes; with one side's
    // κ an atom, the atom.
    var ms2 = [_]NodeId{ l1, l2 };
    const j2 = try f.shapes.join(gpa, &f.account, &f.places, &f.cells, &ms2);
    try t.propagate(gpa, f.charge(), &f.shapes, &f.cells, &f.places, j2, &.{ l1, l2 }, .alternatives, null);
    try testing.expectEqual(yes, try t.kappaOf(gpa, f.charge(), &f.shapes, &f.cells, j2));
    // A literal `[ xs, ys ]` holding two parameters at `[*]`: together, the
    // element path's κ is apart{p3, p4} ∧ excl p3 ∧ excl p4.
    var ms3 = [_]NodeId{ xs, ys };
    const elem = try f.shapes.join(gpa, &f.account, &f.places, &f.cells, &ms3);
    try t.propagate(gpa, f.charge(), &f.shapes, &f.cells, &f.places, elem, &.{ xs, ys }, .together, null);
    const ke = try t.kappaOf(gpa, f.charge(), &f.shapes, &f.cells, elem);
    const fe = try t.flat(gpa, f.charge(), ke);
    try testing.expectEqual(@as(u32, 3), t.atoms.count(fe));
    // `[ xs, xs ]`: shared, exact (I-κ's two positions).
    var ms4 = [_]NodeId{ xs, xs };
    const elem2 = try f.shapes.join(gpa, &f.account, &f.places, &f.cells, &ms4);
    try testing.expectEqual(xs, elem2);
    // The join deduplicates the node; the members still say two positions.
    var lists_members = [_]NodeId{ a, a };
    const dup = try f.shapes.join(gpa, &f.account, &f.places, &f.cells, &lists_members);
    try t.propagate(gpa, f.charge(), &f.shapes, &f.cells, &f.places, dup, &.{ a, a }, .together, null);
    try testing.expectEqual(shared, try t.kappaOf(gpa, f.charge(), &f.shapes, &f.cells, dup));
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
    // An interpreter answering `yes` to `excl`, `lost` to `within`, and the
    // atom itself otherwise.
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
    const out = try t.instantiate(gpa, f.charge(), k, .{ .ctx = &dummy, .atom = I.atom });
    try testing.expectEqual(lost, out);
    const k2 = try t.@"and"(gpa, f.charge(), e1, try t.@"and"(gpa, f.charge(), s12, grp));
    const out2 = try t.instantiate(gpa, f.charge(), k2, .{ .ctx = &dummy, .atom = I.atom });
    const fo = try t.flat(gpa, f.charge(), out2);
    try testing.expectEqual(@as(u32, 2), t.atoms.count(fo));
    try testing.expect(t.atoms.member(fo, s12.int()) and t.atoms.member(fo, grp.int()));
    try testing.expectEqual(shared, try t.instantiate(gpa, f.charge(), shared, .{ .ctx = &dummy, .atom = I.atom }));
    // Print.
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

test "a refused reservation leaves the condition table whole" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const p1 = try f.param(1, 1, &.{});
    var broke: Ids.Account = .{ .allowance = 0 };
    defer broke.deinit(gpa);
    const n = f.conds.count();
    try testing.expectError(error.OwnershipLimit, f.conds.excl(gpa, .growth(&broke), p1));
    try testing.expectEqual(n, f.conds.count());
    // The next owner gets a real condition, and the same request again is
    // a hit charged like a miss.
    const e = try f.conds.excl(gpa, f.charge(), p1);
    try testing.expectEqual(n, e.int());
    const before = f.account.growth;
    try testing.expectEqual(e, try f.conds.excl(gpa, f.charge(), p1));
    try testing.expectEqual(before + 1, f.account.growth);
    // In a lane, the records are baseline.
    var lane_account: Ids.Account = .{ .allowance = 0 };
    defer lane_account.deinit(gpa);
    var t2 = try Table.init(gpa, .in(&lane_account, .{ .atom = 1, .role = .cond_index }));
    defer t2.deinit(gpa);
    _ = try t2.excl(gpa, .in(&lane_account, .{ .atom = 1, .role = .cond_index }), p1);
    try testing.expectEqual(@as(u32, 0), lane_account.growth);
    try testing.expectEqual(@as(u64, 4), lane_account.baseline);
}
