//! L2: cells, the provenance labels of objects (`docs/design/ownership-v2.md`
//! §2.2, §3.2): the cell table and its trie, call labels, interning,
//! splits, the may-alias relation, and the persistent sets of
//! `(cell, approx)` every shape, condition and holder index is built over.
//! The live inverted index holders are found through (§2.8's `set_head`
//! chains and live counts) is `Demands`' (§5: `holders`), built over these
//! sets when that layer lands.
//!
//! **One rule** (§2.2): a cell labels one object per occurrence; "many" is a
//! property of a position (`[*]`, `⟲`, a folded label), never of a label.
//! Nothing here derives distinctness from a label.
//!
//! **The trie.** A symbolic cell's parent is its path minus one step, a
//! refinement's the cell it refines, so the descendants of a cell the
//! program ever named are enumerable (§2.8's deep demands). Children are an
//! intrusive list in first-sight order.
//!
//! **`alias`** is the one relation every holder test, `sep` atom and
//! Disjoint reads (§2.2, *May-alias*); it costs O(path length) column reads
//! and returns a `SplitId` when the answer rests on a split's condition.
//! Only this file compares two cells (§5's fence).
//!
//! **The persistent set** (`Radix`) is Okasaki–Gill's big-endian patricia
//! tree over `u32` keys (a `CellId`) with one value bit per key, the
//! `approx` of a pair (§2.3): canonical — equal contents have one structure
//! — so an insert of a present key and a union adding nothing return the
//! ORIGINAL root (§4.1's idempotence, what keeps a fixpoint from seeing a
//! change where none is). A path copy touches at most 33 nodes, and every
//! node made is one growth record reserved before it is made. The
//! recursion in `unionWith` and `subset` is bounded by the key width, 33
//! frames, a constant and not a function of the input (R-7.12). A pair's
//! value joins by `and`: an exact pair wins over an approximate one.
//!
//! Obligations kept here: O4 (a union is a union), O6 (a split's
//! refinements are told apart only under its κ: `alias` answers `under`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");

pub const CellId = Ids.CellId;
pub const LabelId = Ids.LabelId;
pub const SetId = Ids.SetId;
pub const SplitId = Ids.SplitId;
pub const PathId = Ids.PathId;
pub const PlaceId = Ids.PlaceId;
pub const CondId = Ids.CondId;
pub const Account = Ids.Account;
/// The place table `alias` reads, for a layer above that may not import
/// `Place` itself (§5: only `Place` reads type children; the table is data).
pub const Places = Place.Table;

pub const Charge = Ids.Charge;
pub const Error = Ids.ChargeError;

pub const Origin = enum(u8) {
    site,
    param,
    env,
    shared,
    result,
    esc,
    cb,
    msg,
    top,
    elem,
    others,
    level,
    below,
    loan,
    /// A use mark (§2.10's `use(i)`): not an object but a label `R`, `A`,
    /// `E`, `W`, `S` or a written field, carried as a cell so a class's use
    /// shape is an ordinary shape node and `join`/`leq`/`proj` serve it.
    /// Concrete for `alias` (never one object with anything); projected as
    /// `⊤` is — a LEAF of marks stands for every path below it (a deep read
    /// or write), a `node` of marks for its own path alone.
    mark,

    /// Symbolic origins stand for everything under them: projecting appends
    /// a step (§2.2).
    pub fn isSymbolic(o: Origin) bool {
        return switch (o) {
            .param, .env, .shared, .cb, .msg, .top => true,
            else => false,
        };
    }

    /// A refinement has a parent cell and a split (§2.2).
    pub fn isRefinement(o: Origin) bool {
        return switch (o) {
            .elem, .others, .level, .below, .loan => true,
            else => false,
        };
    }
};

/// The kind of object a cell labels: the place it is made at (§2.2).
pub const Kind = enum(u8) {
    list,
    dict,
    record,
    ref,
    closure,
    @"opaque",
    /// A cell at a `var` place, or `⊤`: anything.
    any,
    /// A trie node at a place that holds no object of its own (a tuple, a
    /// constructor, a crossing leaf): the ancestor of its children.
    none,

    pub fn ofPlace(k: Place.Kind) Kind {
        return switch (k) {
            .list => .list,
            .dict => .dict,
            .record => .record,
            .ref => .ref,
            .closure => .closure,
            .@"opaque" => .@"opaque",
            .@"var" => .any,
            .tuple, .ctor, .cross => .none,
        };
    }
};

/// What a `mark` cell says of a parameter path (§2.10's `use(i)` labels):
/// read, kept in the result, escaped, written, written deeply (`S`), or one
/// written field (`W{F}`), whose rank is the cell's `b`.
pub const Mark = enum(u8) { r, a, e, w, deep, field };

/// One cell. `a`, `b`, `c` by origin (§3.2): `site`: the instruction;
/// `result`/`esc`: label + k; `param`/`env`/`shared`/`msg`: index + path;
/// `cb`: label + path, `c` the function parameter; refinements: parent +
/// the split's label, `below`'s `c` its step; `loan`: contents cell + label.
pub const Cell = struct {
    origin: Origin,
    kind: Kind,
    a: u32,
    b: u32,
    c: u32,
    place: PlaceId,
    /// The trie parent: the path minus one step, or the refined cell.
    parent: CellId,
    first_child: CellId,
    last_child: CellId,
    next_sibling: CellId,
};

/// A call label (§2.2): an interned `(call instruction, callee label)`
/// pair; `folded` for `ι⋆` and for a composite whose callee label is
/// folded. `supplies` is filled by the walk (§2.11).
pub const Label = struct {
    inst: u32,
    callee_label: LabelId,
    folded: bool,
    supplies: Ids.Range,
};

/// A split in force (§2.2): a container, the instruction that took from
/// it, the label its refinements carry, and κ of the container at ι.
pub const Split = struct {
    container: CellId,
    inst: u32,
    label: LabelId,
    cond: CondId,
};

/// `alias`'s answer (§2.2).
pub const Alias = union(enum) {
    no,
    yes,
    /// Not aliases if the split's condition held at its instruction.
    under: SplitId,
    /// Two `taken` elements of one container from distinct splits: not
    /// aliases under the container's κ at `[*]`.
    under_kappa: CellId,
};

pub const Table = struct {
    cells: std.MultiArrayList(Cell) = .empty,
    /// Keyed by `(origin·kind, a, b, c, place)`: a cell is one object at one
    /// place, so a `result`, `site` or refinement made at another place is
    /// another cell, whatever order made them.
    intern: Ids.FixedDict(5) = .{},
    labels: std.MultiArrayList(Label) = .empty,
    label_intern: Ids.FixedDict(3) = .{},
    splits: std.MultiArrayList(Split) = .empty,
    /// `(container, label)` → split.
    split_intern: Ids.FixedDict(2) = .{},
    sets: Radix = .{},

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.cells.deinit(gpa);
        t.intern.deinit(gpa);
        t.labels.deinit(gpa);
        t.label_intern.deinit(gpa);
        t.splits.deinit(gpa);
        t.split_intern.deinit(gpa);
        t.sets.deinit(gpa);
    }

    pub fn count(t: *const Table) u32 {
        return @intCast(t.cells.len);
    }

    pub fn get(t: *const Table, c: CellId) Cell {
        return t.cells.get(c.int());
    }

    pub fn origin(t: *const Table, c: CellId) Origin {
        return t.cells.items(.origin)[c.int()];
    }

    pub fn kind(t: *const Table, c: CellId) Kind {
        return t.cells.items(.kind)[c.int()];
    }

    pub fn parent(t: *const Table, c: CellId) CellId {
        return t.cells.items(.parent)[c.int()];
    }

    pub fn place(t: *const Table, c: CellId) PlaceId {
        return t.cells.items(.place)[c.int()];
    }

    /// The trie children of `c`, in first-sight order.
    pub const Children = struct {
        t: *const Table,
        at: CellId,

        pub fn next(it: *Children) ?CellId {
            if (it.at == .none) return null;
            const c = it.at;
            it.at = it.t.cells.items(.next_sibling)[c.int()];
            return c;
        }
    };

    pub fn children(t: *const Table, c: CellId) Children {
        return .{ .t = t, .at = t.cells.items(.first_child)[c.int()] };
    }

    /// The first non-refinement above `c` (§2.2).
    pub fn base(t: *const Table, c: CellId) CellId {
        var at = c;
        while (t.origin(at).isRefinement()) at = t.parent(at);
        return at;
    }

    // ---- labels -----------------------------------------------------------

    /// The label `(inst, callee_label, folded)`, interned (§2.2). A new
    /// label is one growth record: its context is reserved before creation
    /// against the owning declaration (§4.4).
    pub fn label(t: *Table, gpa: Allocator, account: *Account, inst: u32, callee_label: LabelId, folded: bool) Error!LabelId {
        try account.reserve(.label, 1);
        const got = try t.label_intern.getOrPut(gpa, .{ inst, callee_label.int(), @intFromBool(folded) });
        if (got.found_existing) return .from(got.value_ptr.*);
        got.value_ptr.* = @intCast(t.labels.len);
        try t.labels.append(gpa, .{ .inst = inst, .callee_label = callee_label, .folded = folded, .supplies = .empty });
        return .from(got.value_ptr.*);
    }

    pub fn labelOf(t: *const Table, l: LabelId) Label {
        return t.labels.get(l.int());
    }

    /// The first instruction of a label's chain.
    pub fn labelInst(t: *const Table, l: LabelId) u32 {
        return t.labels.items(.inst)[l.int()];
    }

    // ---- interning ----------------------------------------------------------

    /// The cell `(origin, kind, a, b, c)` at `place`, interned, with its
    /// trie parent. One growth record when new.
    fn internCell(t: *Table, gpa: Allocator, account: *Account, o: Origin, k: Kind, a: u32, b: u32, c: u32, at: PlaceId, trie_parent: CellId) Error!CellId {
        try account.reserve(.cell, 1);
        const got = try t.intern.getOrPut(gpa, .{ (@as(u32, @backingInt(o)) << 8) | @backingInt(k), a, b, c, at.int() });
        if (got.found_existing) return .from(got.value_ptr.*);
        const id: CellId = .from(t.count());
        got.value_ptr.* = id.int();
        try t.cells.append(gpa, .{ .origin = o, .kind = k, .a = a, .b = b, .c = c, .place = at, .parent = trie_parent, .first_child = .none, .last_child = .none, .next_sibling = .none });
        if (trie_parent != .none) {
            const p = trie_parent.int();
            const last = t.cells.items(.last_child)[p];
            if (last == .none) t.cells.items(.first_child)[p] = id else t.cells.items(.next_sibling)[last.int()] = id;
            t.cells.items(.last_child)[p] = id;
        }
        return id;
    }

    /// `site ι` of kind `k` at `place`: the object a literal, construction,
    /// copy or lambda at ι makes.
    pub fn site(t: *Table, gpa: Allocator, account: *Account, inst: u32, at: PlaceId, k: Kind) Error!CellId {
        return t.internCell(gpa, account, .site, k, inst, 0, 0, at, .none);
    }

    /// `⊤`: an object the analysis cannot name (O10).
    pub fn top(t: *Table, gpa: Allocator, account: *Account) Error!CellId {
        return t.internCell(gpa, account, .top, .any, 0, 0, 0, .none, .none);
    }

    /// A use mark (`Mark`), with the field's rank for `field`; one cell per
    /// distinct mark, at no place.
    pub fn mark(t: *Table, gpa: Allocator, account: *Account, m: Mark, rank: u32) Error!CellId {
        return t.internCell(gpa, account, .mark, .none, @backingInt(m), if (m == .field) rank else 0, 0, .none, .none);
    }

    /// The mark a `mark` cell carries.
    pub fn markOf(t: *const Table, c: CellId) Mark {
        std.debug.assert(t.origin(c) == .mark);
        return @fromBackingInt(@intCast(t.cells.items(.a)[c.int()]));
    }

    /// `result λ·k` or `esc λ·k`.
    pub fn result(t: *Table, gpa: Allocator, account: *Account, o: Origin, l: LabelId, k: u32, at: PlaceId, kind_at: Kind) Error!CellId {
        std.debug.assert(o == .result or o == .esc);
        return t.internCell(gpa, account, o, kind_at, l.int(), k, 0, at, .none);
    }

    /// A symbolic cell `origin index·path` (`param πᵢ·q`, `env x·q`,
    /// `shared M.v·q`, `msg·q`, `cb j@λ·q`): its trie parent is the cell at
    /// the path's parent, interned on the way. The kind is the path's
    /// place's. Costs O(depth of the path not yet interned).
    pub fn symbolic(t: *Table, gpa: Allocator, account: *Account, places: *const Place.Table, o: Origin, index: u32, path: PathId, j: u32) Error!CellId {
        std.debug.assert(o.isSymbolic() and o != .top);
        // Find the deepest interned ancestor, then build down.
        var missing: [max_symbolic_depth]PathId = undefined;
        var n: usize = 0;
        var at = path;
        var found: CellId = .none;
        while (true) {
            const key = [5]u32{ (@as(u32, @backingInt(o)) << 8) | @backingInt(Kind.ofPlace(places.kind(places.pathPlace(at)))), index, at.int(), j, places.pathPlace(at).int() };
            if (t.intern.get(key)) |hit| {
                found = .from(hit);
                break;
            }
            if (n == missing.len) return error.OwnershipLimit;
            missing[n] = at;
            n += 1;
            at = places.pathParent(at);
            if (at == .none) break;
        }
        var p = found;
        while (n > 0) {
            n -= 1;
            const q = missing[n];
            p = try t.internCell(gpa, account, o, Kind.ofPlace(places.kind(places.pathPlace(q))), index, q.int(), j, places.pathPlace(q), p);
        }
        return p;
    }

    /// A deep symbolic chain is bounded by `max_path_steps` of §4.4; one
    /// call interns at most this many new ancestors before it is charged
    /// again, so the stack stays constant-size.
    const max_symbolic_depth = 256;

    /// `elem c·ι`/`others c·ι` or `level c·ι`/`below c·s·ι`/`loan c·ι`:
    /// a refinement of `c` by the split labelled `l`, with `step` for
    /// `below`. Records the split (one record) on first sight.
    pub fn refine(t: *Table, gpa: Allocator, account: *Account, o: Origin, c: CellId, l: LabelId, step: u32, at: PlaceId, k: Kind) Error!CellId {
        std.debug.assert(o.isRefinement());
        return t.internCell(gpa, account, o, k, c.int(), l.int(), step, at, c);
    }

    /// The split of `container` at the chain `l` (§2.2's `taken` set), made
    /// with `cond` on first sight.
    pub fn split(t: *Table, gpa: Allocator, account: *Account, container: CellId, inst: u32, l: LabelId, cond: CondId) Error!SplitId {
        try account.reserve(.other, 1);
        const got = try t.split_intern.getOrPut(gpa, .{ container.int(), l.int() });
        if (got.found_existing) return .from(got.value_ptr.*);
        got.value_ptr.* = @intCast(t.splits.len);
        try t.splits.append(gpa, .{ .container = container, .inst = inst, .label = l, .cond = cond });
        return .from(got.value_ptr.*);
    }

    pub fn splitOf(t: *const Table, s: SplitId) Split {
        return t.splits.get(s.int());
    }

    pub fn findSplit(t: *const Table, container: CellId, l: LabelId) SplitId {
        return if (t.split_intern.get(.{ container.int(), l.int() })) |s| .from(s) else .none;
    }

    // ---- may-alias --------------------------------------------------------------

    /// Whether two symbolic cells of one origin and index may be one
    /// object: one canonical path a prefix of the other, `⟲` matching any
    /// continuation, except two paths diverging at a `ctor` place on
    /// different constructors (§2.2). O(path length).
    fn pathsMayAlias(places: *const Place.Table, p: PathId, q: PathId) bool {
        if (p == q) return true;
        var a = p;
        var b = q;
        var below_a: PathId = .none;
        var below_b: PathId = .none;
        while (places.pathDepth(a) > places.pathDepth(b)) {
            below_a = a;
            a = places.pathParent(a);
        }
        while (places.pathDepth(b) > places.pathDepth(a)) {
            below_b = b;
            b = places.pathParent(b);
        }
        while (a != b) {
            below_a = a;
            below_b = b;
            a = places.pathParent(a);
            b = places.pathParent(b);
        }
        // `a` is the deepest common ancestor; one path IS it → a prefix.
        if (below_a == .none or below_b == .none) return true;
        // `⟲` re-entering place P matches the other side's step when that
        // step leads onto P's cycle — the levels below P include whatever it
        // reaches (`Rose (List Rose)`: the children list and the subtrees).
        // A step off the cycle (`Node Tree (List Int) Tree`'s own list
        // against its subtrees), another field, another index or another
        // constructor (alternatives of one value, R-4.8.15) is another path.
        const sa = places.pathStep(below_a);
        const sb = places.pathStep(below_b);
        if (sa.kind == .level and sb.kind == .level) return true;
        if (sa.kind == .level) return places.sameCycle(places.pathPlace(below_a), places.pathPlace(below_b));
        if (sb.kind == .level) return places.sameCycle(places.pathPlace(below_b), places.pathPlace(below_a));
        return false;
    }

    /// Whether the bases `x` and `y` (no refinement) may be one object.
    fn basesMayAlias(t: *const Table, places: *const Place.Table, x: CellId, y: CellId) bool {
        if (x == y) return true;
        const ox = t.origin(x);
        const oy = t.origin(y);
        if (ox == .top or oy == .top) return true;
        if (ox != oy) return false;
        if (!ox.isSymbolic()) return false; // concrete: equal or not
        const cx = t.get(x);
        const cy = t.get(y);
        if (cx.a != cy.a or cx.c != cy.c) return false;
        return pathsMayAlias(places, .from(cx.b), .from(cy.b));
    }

    /// May `a` and `b` be one object (§2.2)? `yes`; `no`; `under ι` when
    /// they descend from one split on different sides; `under_kappa` for
    /// two `taken` elements of one container from distinct splits.
    pub fn alias(t: *const Table, places: *const Place.Table, a: CellId, b: CellId) Alias {
        if (a == b) return .yes;
        const base_a = t.base(a);
        const base_b = t.base(b);
        if (!t.basesMayAlias(places, base_a, base_b)) return .no;
        if (base_a != base_b) return .yes;
        // One base: walk both refinement chains from the base out.
        var ca = t.chainFrom(base_a, a);
        var cb = t.chainFrom(base_b, b);
        while (true) {
            const ra = ca.next() orelse return .yes;
            const rb = cb.next() orelse return .yes;
            if (ra == rb) continue;
            const xa = t.get(ra);
            const xb = t.get(rb);
            if (xa.b == xb.b) {
                // One split, two sides.
                // Two positions one list pattern takes (`[ a, b, …rest ]`)
                // are two sides as well: `c` is the position.
                const sides = (xa.origin == .elem and xb.origin == .others) or (xa.origin == .others and xb.origin == .elem) or
                    (xa.origin == .level and xb.origin == .below) or (xa.origin == .below and xb.origin == .level) or
                    (xa.origin == .below and xb.origin == .below and xa.c != xb.c) or
                    (xa.origin == .elem and xb.origin == .elem and xa.c != xb.c);
                if (!sides) return .yes;
                const s = t.findSplit(xa.parent, .from(xa.b));
                return if (s == .none) .yes else .{ .under = s };
            }
            // Two splits of one container.
            if (xa.origin == .elem and xb.origin == .elem) return .{ .under_kappa = xa.parent };
            return .yes;
        }
    }

    /// The refinements between `base` (exclusive) and `c` (inclusive), from
    /// the base outwards. Depth is a few splits; a fixed stack of 64.
    const Chain = struct {
        items: [64]CellId,
        len: usize,
        i: usize = 0,

        fn next(ch: *Chain) ?CellId {
            if (ch.i == ch.len) return null;
            ch.i += 1;
            return ch.items[ch.len - ch.i];
        }
    };

    fn chainFrom(t: *const Table, base_cell: CellId, c: CellId) Chain {
        var ch: Chain = .{ .items = undefined, .len = 0 };
        var at = c;
        while (at != base_cell and ch.len < ch.items.len) : (at = t.parent(at)) {
            ch.items[ch.len] = at;
            ch.len += 1;
        }
        return ch;
    }

    /// Whether `d` stands only for objects strictly BELOW `c` (§2.8): a trie
    /// descendant of it (a path below, a refinement of it), or, over one
    /// symbolic origin, levels under it — `d` re-enters a place with `⟲`
    /// where `c` steps onto that place's cycle (`Rose`'s subtrees under its
    /// children list). A list storage write of `c` never counts against
    /// such a `d`: it is an element. O(path length).
    pub fn below(t: *const Table, places: *const Place.Table, d: CellId, c: CellId) bool {
        if (d == c) return false;
        var at = t.parent(d);
        while (at != .none) : (at = t.parent(at)) if (at == c) return true;
        const x = t.get(d);
        const y = t.get(c);
        if (x.origin != y.origin or !x.origin.isSymbolic() or x.origin == .top or x.a != y.a or x.c != y.c) return false;
        var p: PathId = .from(x.b);
        var q: PathId = .from(y.b);
        var below_p: PathId = .none;
        var below_q: PathId = .none;
        while (places.pathDepth(p) > places.pathDepth(q)) {
            below_p = p;
            p = places.pathParent(p);
        }
        while (places.pathDepth(q) > places.pathDepth(p)) {
            below_q = q;
            q = places.pathParent(q);
        }
        while (p != q) {
            below_p = p;
            below_q = q;
            p = places.pathParent(p);
            q = places.pathParent(q);
        }
        if (below_q == .none) return below_p != .none; // `c`'s path is a prefix of `d`'s
        if (below_p == .none) return false;
        const sp = places.pathStep(below_p);
        const sq = places.pathStep(below_q);
        return sp.kind == .level and sq.kind != .level and places.sameCycle(places.pathPlace(below_p), places.pathPlace(below_q));
    }

    /// The steps from `d` down to its trie descendant `c` (a symbolic step
    /// per path node, `[*]` per `elem`/`others`, nothing for a `level` or a
    /// `loan`), appended root first; false when `c`'s chain does not reach
    /// `d`. O(depth).
    pub fn stepsTo(t: *const Table, places: *const Place.Table, d: CellId, c: CellId, gpa: Allocator, out: *std.ArrayList(Place.Step)) Allocator.Error!bool {
        const first = out.items.len;
        var at = c;
        while (at != d) : (at = t.parent(at)) {
            if (at == .none) {
                out.shrinkRetainingCapacity(first);
                return false;
            }
            const x = t.get(at);
            switch (x.origin) {
                .elem, .others => try out.append(gpa, Place.Step.elem),
                .level, .loan => {},
                .below => try out.append(gpa, Place.Step.fromWord(x.c)),
                else => if (x.origin.isSymbolic()) try out.append(gpa, places.pathStep(.from(x.b))),
            }
        }
        std.mem.reverse(Place.Step, out.items[first..]);
        return true;
    }

    /// The symbolic cell at a refinement's canonical position, the split
    /// forgotten (`elem c·ι` is `c[*]`, `level c·ι` is `c`, `below c·s·ι`
    /// is `c·s`, folded): what a refinement projects through (§2.2: a refinement's
    /// projection is its parent's, refined). Null when the base is
    /// concrete, whose contents are explicit children.
    pub fn unrefined(t: *Table, gpa: Allocator, account: *Account, places: *Place.Table, c: CellId) Error!?CellId {
        const x = t.get(c);
        if (!x.origin.isRefinement()) return if (x.origin.isSymbolic() and x.origin != .top) c else null;
        const inner = (try t.unrefined(gpa, account, places, x.parent)) orelse return null;
        const y = t.get(inner);
        const step: ?Place.Step = switch (x.origin) {
            .elem, .others => Place.Step.elem,
            .below => Place.Step.fromWord(x.c),
            .level => null,
            .loan => return inner,
            else => unreachable,
        };
        const s = step orelse return inner;
        const path = (try places.extend(gpa, .growth(account), .from(y.b), s)) orelse return null;
        return try t.symbolic(gpa, account, places, y.origin, y.a, path, y.c);
    }
};

// ---------------------------------------------------------------------------
// The persistent set: a big-endian patricia tree over u32 keys (§4.1)
// ---------------------------------------------------------------------------

/// A node: a leaf (`mask == 0`: `prefix` is the key, `left` the value bit)
/// or a branch (`mask` the branching bit, `prefix` the bits above it, the
/// keys with the bit clear in `left`, set in `right`).
pub const RadixNode = struct {
    prefix: u32,
    mask: u32,
    left: SetId,
    right: SetId,
};

pub const Radix = struct {
    nodes: std.MultiArrayList(RadixNode) = .empty,
    /// Hash-consing: equal contents have one canonical structure, and with
    /// every node interned by `(prefix, mask, left, right)` they have one
    /// id too.
    intern: Ids.FixedDict(4) = .{},

    pub fn deinit(r: *Radix, gpa: Allocator) void {
        r.nodes.deinit(gpa);
        r.intern.deinit(gpa);
    }

    inline fn node(r: *const Radix, id: SetId) RadixNode {
        return r.nodes.get(id.int());
    }

    /// One node, interned. The record is reserved BEFORE the dictionary is
    /// touched, so a refused reservation leaves no half-written entry; and
    /// it is reserved on a hit as well as a miss (§4.1: a request reserves
    /// its logical entry even when the physical node exists already, so
    /// what a request costs never depends on which owner built the node).
    fn make(r: *Radix, gpa: Allocator, charge: Charge, n: RadixNode) Error!SetId {
        try charge.reserve(gpa, .set, 1);
        const got = try r.intern.getOrPut(gpa, .{ n.prefix, n.mask, n.left.int(), n.right.int() });
        if (got.found_existing) return .from(got.value_ptr.*);
        const id: SetId = .from(@intCast(r.nodes.len));
        got.value_ptr.* = id.int();
        try r.nodes.append(gpa, n);
        return id;
    }

    /// Reserve one inspection record before reading a node (§4.4).
    inline fn inspect(gpa: Allocator, charge: Charge) Error!void {
        return charge.reserve(gpa, .inspection, 1);
    }

    inline fn matches(key: u32, prefix: u32, mask: u32) bool {
        return (key & ~((mask << 1) -% 1)) == prefix;
    }

    inline fn zeroBit(key: u32, mask: u32) bool {
        return key & mask == 0;
    }

    fn join(r: *Radix, gpa: Allocator, charge: Charge, p0: u32, t0: SetId, p1: u32, t1: SetId) Error!SetId {
        const diff = p0 ^ p1;
        // The highest differing bit.
        const mask = @as(u32, 1) << @intCast(31 - @clz(diff));
        const prefix = p0 & ~((mask << 1) -% 1);
        return if (zeroBit(p0, mask))
            r.make(gpa, charge, .{ .prefix = prefix, .mask = mask, .left = t0, .right = t1 })
        else
            r.make(gpa, charge, .{ .prefix = prefix, .mask = mask, .left = t1, .right = t0 });
    }

    /// The value bit of `key` in `root`, or null when absent. O(min(32,
    /// depth)) reads: a lookup is a fixed-key dictionary navigation, which
    /// §4.1 lets a task do without a record per comparison.
    pub fn get(r: *const Radix, root: SetId, key: u32) ?u1 {
        var at = root;
        while (at != .none) {
            const n = r.node(at);
            if (n.mask == 0) return if (n.prefix == key) @intCast(n.left.int()) else null;
            if (!matches(key, n.prefix, n.mask)) return null;
            at = if (zeroBit(key, n.mask)) n.left else n.right;
        }
        return null;
    }

    pub fn member(r: *const Radix, root: SetId, key: u32) bool {
        return r.get(root, key) != null;
    }

    /// The leaf node of `(key, value)` if any set ever held it (hash-consing
    /// makes it one node): what an inverted index keyed by a cell starts
    /// from (§2.8's `set_head`). Allocates nothing.
    pub fn leafOf(r: *const Radix, key: u32, value: u1) ?SetId {
        return if (r.intern.get(.{ key, 0, value, Ids.none_int })) |id| .from(id) else null;
    }

    pub fn nodeCount(r: *const Radix) u32 {
        return @intCast(r.nodes.len);
    }

    /// The two children of a branch, or null for a leaf.
    pub fn branches(r: *const Radix, id: SetId) ?[2]SetId {
        const n = r.node(id);
        return if (n.mask == 0) null else .{ n.left, n.right };
    }

    /// `root` with `(key, value)`; the same root when it holds a pair at
    /// least as strong already. A present key's value is joined by `and`.
    /// Every node on the descent is one inspection; every node copied one
    /// record, ≤ 33 of each.
    pub fn insert(r: *Radix, gpa: Allocator, charge: Charge, root: SetId, key: u32, value: u1) Error!SetId {
        if (root == .none) return r.make(gpa, charge, .{ .prefix = key, .mask = 0, .left = .from(value), .right = .none });
        // Descend, remembering the path, then copy it back up.
        var path: [33]SetId = undefined;
        var depth: usize = 0;
        var at = root;
        var leaf_or_split: SetId = undefined;
        while (true) {
            try inspect(gpa, charge);
            const n = r.node(at);
            if (n.mask == 0) {
                if (n.prefix == key) {
                    const joined: u1 = @intCast(n.left.int() & value);
                    if (joined == @as(u1, @intCast(n.left.int()))) return root;
                    leaf_or_split = try r.make(gpa, charge, .{ .prefix = key, .mask = 0, .left = .from(joined), .right = .none });
                    break;
                }
                const new_leaf = try r.make(gpa, charge, .{ .prefix = key, .mask = 0, .left = .from(value), .right = .none });
                leaf_or_split = try r.join(gpa, charge, key, new_leaf, n.prefix, at);
                break;
            }
            if (!matches(key, n.prefix, n.mask)) {
                const new_leaf = try r.make(gpa, charge, .{ .prefix = key, .mask = 0, .left = .from(value), .right = .none });
                leaf_or_split = try r.join(gpa, charge, key, new_leaf, n.prefix, at);
                break;
            }
            path[depth] = at;
            depth += 1;
            at = if (zeroBit(key, n.mask)) n.left else n.right;
        }
        var child = leaf_or_split;
        while (depth > 0) {
            depth -= 1;
            const n = r.node(path[depth]);
            child = if (zeroBit(key, n.mask))
                try r.make(gpa, charge, .{ .prefix = n.prefix, .mask = n.mask, .left = child, .right = n.right })
            else
                try r.make(gpa, charge, .{ .prefix = n.prefix, .mask = n.mask, .left = n.left, .right = child });
        }
        return child;
    }

    /// `a ∪ b`, values joined by `and`. Returns `a` itself when `b` adds
    /// nothing (and `b` when `a` adds nothing to it), so a fixpoint sees no
    /// change where there is none. Every pair of nodes the merge inspects
    /// is one record reserved before it is read, whether or not anything is
    /// added (§4.1's zero-growth unions).
    pub fn unionWith(r: *Radix, gpa: Allocator, charge: Charge, a: SetId, b: SetId) Error!SetId {
        if (a == .none) return b;
        if (b == .none) return a;
        if (a == b) return a;
        try inspect(gpa, charge);
        const na = r.node(a);
        const nb = r.node(b);
        if (na.mask == 0) {
            if (nb.mask == 0 and na.prefix == nb.prefix) {
                const joined: u1 = @intCast(na.left.int() & nb.left.int());
                if (joined == @as(u1, @intCast(nb.left.int()))) return b;
                if (joined == @as(u1, @intCast(na.left.int()))) return a;
                return r.make(gpa, charge, .{ .prefix = na.prefix, .mask = 0, .left = .from(joined), .right = .none });
            }
            // A leaf into a set is an insert: `b` is the destination.
            return r.insert(gpa, charge, b, na.prefix, @intCast(na.left.int()));
        }
        if (nb.mask == 0) return r.insert(gpa, charge, a, nb.prefix, @intCast(nb.left.int()));
        if (na.mask == nb.mask and na.prefix == nb.prefix) {
            const l = try r.unionWith(gpa, charge, na.left, nb.left);
            const rt = try r.unionWith(gpa, charge, na.right, nb.right);
            if (l == na.left and rt == na.right) return a;
            if (l == nb.left and rt == nb.right) return b;
            return r.make(gpa, charge, .{ .prefix = na.prefix, .mask = na.mask, .left = l, .right = rt });
        }
        if (na.mask > nb.mask and matches(nb.prefix, na.prefix, na.mask)) {
            // `b` fits under one side of `a`.
            if (zeroBit(nb.prefix, na.mask)) {
                const l = try r.unionWith(gpa, charge, na.left, b);
                if (l == na.left) return a;
                return r.make(gpa, charge, .{ .prefix = na.prefix, .mask = na.mask, .left = l, .right = na.right });
            }
            const rt = try r.unionWith(gpa, charge, na.right, b);
            if (rt == na.right) return a;
            return r.make(gpa, charge, .{ .prefix = na.prefix, .mask = na.mask, .left = na.left, .right = rt });
        }
        if (nb.mask > na.mask and matches(na.prefix, nb.prefix, nb.mask)) {
            if (zeroBit(na.prefix, nb.mask)) {
                const l = try r.unionWith(gpa, charge, a, nb.left);
                if (l == nb.left) return b;
                return r.make(gpa, charge, .{ .prefix = nb.prefix, .mask = nb.mask, .left = l, .right = nb.right });
            }
            const rt = try r.unionWith(gpa, charge, a, nb.right);
            if (rt == nb.right) return b;
            return r.make(gpa, charge, .{ .prefix = nb.prefix, .mask = nb.mask, .left = nb.left, .right = rt });
        }
        return r.join(gpa, charge, na.prefix, a, nb.prefix, b);
    }

    /// `a ⊑ b`: every key of `a` is in `b` with a bit no larger (exact is
    /// above approximate, as the join says). Every node inspected is one
    /// record reserved first.
    pub fn subset(r: *const Radix, gpa: Allocator, charge: Charge, a: SetId, b: SetId) Error!bool {
        if (a == .none) return true;
        if (b == .none) return false;
        if (a == b) return true;
        try inspect(gpa, charge);
        const na = r.node(a);
        const nb = r.node(b);
        if (na.mask == 0) {
            const v = r.get(b, na.prefix) orelse return false;
            return v <= @as(u1, @intCast(na.left.int()));
        }
        if (nb.mask == 0) return false;
        if (na.mask == nb.mask and na.prefix == nb.prefix) return try r.subset(gpa, charge, na.left, nb.left) and try r.subset(gpa, charge, na.right, nb.right);
        if (nb.mask > na.mask and matches(na.prefix, nb.prefix, nb.mask)) {
            return r.subset(gpa, charge, a, if (zeroBit(na.prefix, nb.mask)) nb.left else nb.right);
        }
        return false;
    }

    /// The keys of `root` in ascending order, one per `next` — a leaf
    /// walk on an explicit stack of at most 33 entries. Iterating a whole
    /// set is the caller's charged task (§4.1).
    pub const Iterator = struct {
        radix: *const Radix,
        stack: [34]SetId = undefined,
        depth: usize = 0,

        pub const Entry = struct { key: u32, value: u1 };

        pub fn next(it: *Iterator) ?Entry {
            while (it.depth > 0) {
                it.depth -= 1;
                const id = it.stack[it.depth];
                const n = it.radix.node(id);
                if (n.mask == 0) return .{ .key = n.prefix, .value = @intCast(n.left.int()) };
                it.stack[it.depth] = n.right;
                it.stack[it.depth + 1] = n.left;
                it.depth += 2;
            }
            return null;
        }
    };

    pub fn iterate(r: *const Radix, root: SetId) Iterator {
        var it: Iterator = .{ .radix = r };
        if (root != .none) {
            it.stack[0] = root;
            it.depth = 1;
        }
        return it;
    }

    /// `a ∩ b`, a key approximate when it is in either: one descent over the
    /// two trees, a subtree the other has no prefix for skipped whole, every
    /// node pair inspected one record (O(min(|a|, |b|)) nodes).
    pub fn intersection(r: *Radix, gpa: Allocator, charge: Charge, a: SetId, b: SetId) Error!SetId {
        if (a == .none or b == .none) return .none;
        if (a == b) return a;
        try inspect(gpa, charge);
        const na = r.node(a);
        const nb = r.node(b);
        if (na.mask == 0 or nb.mask == 0) {
            const leaf = if (na.mask == 0) na else nb;
            const v = r.get(if (na.mask == 0) b else a, leaf.prefix) orelse return .none;
            return r.make(gpa, charge, .{ .prefix = leaf.prefix, .mask = 0, .left = .from(v | @as(u1, @intCast(leaf.left.int()))), .right = .none });
        }
        if (na.mask == nb.mask and na.prefix == nb.prefix) {
            const l = try r.intersection(gpa, charge, na.left, nb.left);
            const rt = try r.intersection(gpa, charge, na.right, nb.right);
            if (l == .none) return rt;
            if (rt == .none) return l;
            return r.make(gpa, charge, .{ .prefix = na.prefix, .mask = na.mask, .left = l, .right = rt });
        }
        if (na.mask > nb.mask and matches(nb.prefix, na.prefix, na.mask)) return r.intersection(gpa, charge, if (zeroBit(nb.prefix, na.mask)) na.left else na.right, b);
        if (nb.mask > na.mask and matches(na.prefix, nb.prefix, nb.mask)) return r.intersection(gpa, charge, a, if (zeroBit(na.prefix, nb.mask)) nb.left else nb.right);
        return .none;
    }

    /// Every key of `root`, counted by walking it: a test instrument, not
    /// an operation an analysis may call (it is Θ(n)).
    pub fn count(r: *const Radix, root: SetId) u32 {
        var it = r.iterate(root);
        var n: u32 = 0;
        while (it.next() != null) n += 1;
        return n;
    }
};

comptime {
    Ids.assertRecord(Cell);
    Ids.assertRecord(Label);
    Ids.assertRecord(Split);
    Ids.assertRecord(RadixNode);
    std.debug.assert(@sizeOf(Cell) == 36);
    std.debug.assert(@sizeOf(RadixNode) == 16);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the radix set is canonical, hash-consed, idempotent and ordered" {
    var r: Radix = .{};
    defer r.deinit(testing.allocator);
    var a: Account = .{};
    defer a.deinit(testing.allocator);
    const gpa = testing.allocator;
    const g: Charge = .growth(&a);
    var s: SetId = .none;
    const keys = [_]u32{ 5, 1_000_000, 3, 0, 0xFFFF_FFFF, 5, 17 };
    for (keys) |key| s = try r.insert(gpa, g, s, key, 0);
    try testing.expectEqual(@as(u32, 6), r.count(s));
    // Inserting a present key with an equal or weaker value is the same root.
    try testing.expectEqual(s, try r.insert(gpa, g, s, 3, 0));
    try testing.expectEqual(s, try r.insert(gpa, g, s, 3, 1));
    // An exact pair strengthens an approximate one, and that is a new root.
    var t: SetId = .none;
    t = try r.insert(gpa, g, t, 9, 1);
    try testing.expectEqual(@as(?u1, 1), r.get(t, 9));
    const t2 = try r.insert(gpa, g, t, 9, 0);
    try testing.expect(t2 != t);
    try testing.expectEqual(@as(?u1, 0), r.get(t2, 9));
    // Hash-consed: the same keys in another order are the same root.
    var u: SetId = .none;
    for ([_]u32{ 17, 0, 0xFFFF_FFFF, 3, 1_000_000, 5 }) |key| u = try r.insert(gpa, g, u, key, 0);
    try testing.expectEqual(s, u);
    try testing.expect(!try r.subset(gpa, g, t, s));
    // Ordered iteration.
    var it = r.iterate(s);
    var last: u64 = 0;
    var seen: u32 = 0;
    while (it.next()) |e| {
        if (seen > 0) try testing.expect(e.key > last);
        last = e.key;
        seen += 1;
    }
    try testing.expectEqual(@as(u32, 6), seen);
    try testing.expect(!r.member(s, 4) and r.member(s, 0) and r.member(s, 0xFFFF_FFFF));
}

test "subset orders values as the join does: approximate below exact" {
    var r: Radix = .{};
    defer r.deinit(testing.allocator);
    var a: Account = .{};
    defer a.deinit(testing.allocator);
    const gpa = testing.allocator;
    const g: Charge = .growth(&a);
    const approx = try r.insert(gpa, g, .none, 9, 1);
    const exact = try r.insert(gpa, g, .none, 9, 0);
    // The join picks exact.
    try testing.expectEqual(exact, try r.unionWith(gpa, g, approx, exact));
    try testing.expectEqual(exact, try r.unionWith(gpa, g, exact, approx));
    // So approximate ⊑ exact, and not the other way: `leq` agrees with `join`.
    try testing.expect(try r.subset(gpa, g, approx, exact));
    try testing.expect(!try r.subset(gpa, g, exact, approx));
    try testing.expect(try r.subset(gpa, g, approx, approx));
    // Over several keys the same.
    var big: SetId = .none;
    for ([_]u32{ 1, 9, 20 }) |k| big = try r.insert(gpa, g, big, k, 0);
    try testing.expect(try r.subset(gpa, g, approx, big));
    const big_approx = try r.insert(gpa, g, big, 9, 1); // weaker: unchanged
    try testing.expectEqual(big, big_approx);
}

test "a union adding nothing returns the destination root, and shares the larger operand" {
    var r: Radix = .{};
    defer r.deinit(testing.allocator);
    var a: Account = .{};
    defer a.deinit(testing.allocator);
    const gpa = testing.allocator;
    const g: Charge = .growth(&a);
    var big: SetId = .none;
    var i: u32 = 0;
    while (i < 64) : (i += 1) big = try r.insert(gpa, g, big, i * 3, 0);
    var small: SetId = .none;
    small = try r.insert(gpa, g, small, 9, 0);
    small = try r.insert(gpa, g, small, 30, 0);
    try testing.expectEqual(big, try r.unionWith(gpa, g, big, small));
    try testing.expectEqual(big, try r.unionWith(gpa, g, small, big));
    const before = r.nodes.len;
    var other: SetId = .none;
    other = try r.insert(gpa, g, other, 1, 0);
    const joined = try r.unionWith(gpa, g, big, other);
    try testing.expectEqual(@as(u32, 65), r.count(joined));
    // One path copied: at most 33 new nodes, plus the leaf.
    try testing.expect(r.nodes.len - before <= 34);
    // Every node was reserved (a hit as well, so at least one record per
    // node), and so was every inspection.
    try testing.expect(a.growth_by[@backingInt(Ids.Category.set)] >= @as(u32, @intCast(r.nodes.len)));
    try testing.expect(a.growth_by[@backingInt(Ids.Category.inspection)] > 0);
}

test "a union that adds nothing still pays its inspections, before it reads" {
    var r: Radix = .{};
    defer r.deinit(testing.allocator);
    var a: Account = .{};
    defer a.deinit(testing.allocator);
    const gpa = testing.allocator;
    var x: SetId = .none;
    var y: SetId = .none;
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        x = try r.insert(gpa, .growth(&a), x, i, 0);
        if (i % 2 == 0) y = try r.insert(gpa, .growth(&a), y, i, 0);
    }
    const before = a.growth;
    try testing.expectEqual(x, try r.unionWith(gpa, .growth(&a), x, y));
    try testing.expect(a.growth > before);
    // Exhaustion stops before any node is allocated or read.
    var tight: Account = .{ .allowance = 0 };
    defer tight.deinit(testing.allocator);
    const nodes = r.nodes.len;
    try testing.expectError(error.OwnershipLimit, r.unionWith(gpa, .growth(&tight), x, y));
    try testing.expectError(error.OwnershipLimit, r.insert(gpa, .growth(&tight), x, 100, 0));
    try testing.expectError(error.OwnershipLimit, r.subset(gpa, .growth(&tight), y, x));
    try testing.expectEqual(nodes, r.nodes.len);
    // In a lane, the inspections are baseline, not growth.
    var lane_account: Account = .{ .allowance = 0 };
    defer lane_account.deinit(testing.allocator);
    const lane: Ids.Lane = .{ .atom = 1, .role = .reach_index };
    try testing.expectEqual(x, try r.unionWith(gpa, .in(&lane_account, lane), x, y));
    try testing.expectEqual(@as(u32, 0), lane_account.growth);
    try testing.expect(lane_account.laneUsed(lane) > 0);
}

test "a refused reservation leaves the set table whole, and a hit is charged like a miss" {
    var r: Radix = .{};
    defer r.deinit(testing.allocator);
    const gpa = testing.allocator;
    var broke: Account = .{ .allowance = 0 };
    defer broke.deinit(gpa);
    try testing.expectError(error.OwnershipLimit, r.insert(gpa, .growth(&broke), .none, 42, 0));
    try testing.expectEqual(@as(usize, 0), r.nodes.len);
    // Another owner making the same node gets a real one, not the refused
    // owner's half-written entry.
    var a: Account = .{};
    defer a.deinit(gpa);
    const s = try r.insert(gpa, .growth(&a), .none, 42, 0);
    try testing.expectEqual(@as(usize, 1), r.nodes.len);
    try testing.expectEqual(@as(u32, 0), s.int());
    try testing.expect(r.member(s, 42));
    // The same node again is a hit, and the request is charged all the same
    // (§4.1: what a request costs never depends on who built the node).
    const before = a.growth;
    try testing.expectEqual(s, try r.insert(gpa, .growth(&a), .none, 42, 0));
    try testing.expectEqual(before + 1, a.growth);
}

/// A test place graph: `r` a record `{ a : List Int, b : List Int }`, with
/// the list's element a crossing `Int`; `t` the `Tree` of `Place.zig`'s
/// tests. Built by hand through `Place.Source`.
const TestGraph = struct {
    table: *Place.Table,
    account: *Ids.Account,
    gpa: Allocator,

    fn describe(ctx: *anyopaque, v: u32, out: *std.ArrayList(Place.Child)) Allocator.Error!Place.Description {
        const g: *TestGraph = @ptrCast(@alignCast(ctx));
        switch (v) {
            // record { a : List Int, b : List Int }
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
            // type Tree = Node Tree (List Int) Tree
            3 => {
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 0, 0) catch unreachable), .@"var" = 3 });
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 0, 1) catch unreachable), .@"var" = 1 });
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 0, 2) catch unreachable), .@"var" = 3 });
                return .{ .kind = .ctor, .head = 100 };
            },
            // type Status = Editing (List Int) | Saving (List Int)
            4 => {
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 1, 0) catch unreachable), .@"var" = 1 });
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 2, 0) catch unreachable), .@"var" = 1 });
                return .{ .kind = .ctor, .head = 300 };
            },
            else => unreachable,
        }
    }

    fn source(g: *TestGraph) Place.Source {
        return .{ .ctx = g, .describe = describe };
    }
};

const Fixture = struct {
    places: Place.Table = .{},
    cells: Table = .{},
    account: Account = .{},
    graph: TestGraph = undefined,

    fn init(f: *Fixture) void {
        f.graph = .{ .table = &f.places, .account = &f.account, .gpa = testing.allocator };
    }

    fn deinit(f: *Fixture) void {
        f.places.deinit(testing.allocator);
        f.cells.deinit(testing.allocator);
        f.account.deinit(testing.allocator);
    }

    fn path(f: *Fixture, root: u32, steps: []const Place.Step) !PathId {
        const p = try f.places.of(testing.allocator, &f.account, f.graph.source(), root);
        var at = try f.places.rootPath(testing.allocator, p);
        for (steps) |s| at = (try f.places.extend(testing.allocator, .growth(&f.account), at, s)).?;
        return at;
    }

    fn param(f: *Fixture, i: u32, root: u32, steps: []const Place.Step) !CellId {
        return f.cells.symbolic(testing.allocator, &f.account, &f.places, .param, i, try f.path(root, steps), 0);
    }
};

test "a symbolic cell interns its trie ancestors, and children are in first-sight order" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const a_elems = try f.param(1, 0, &.{ try Place.Step.field(&f.account, 10), Place.Step.elem });
    // `param π₁·ε`, `·.a` and `·.a[*]` exist; `.b` does not yet.
    try testing.expectEqual(@as(u32, 3), f.cells.count());
    const a = f.cells.parent(a_elems);
    const root = f.cells.parent(a);
    try testing.expectEqual(CellId.none, f.cells.parent(root));
    try testing.expectEqual(Kind.record, f.cells.kind(root));
    try testing.expectEqual(Kind.list, f.cells.kind(a));
    try testing.expectEqual(Kind.none, f.cells.kind(a_elems));
    const b = try f.param(1, 0, &.{try Place.Step.field(&f.account, 11)});
    try testing.expectEqual(@as(u32, 4), f.cells.count());
    try testing.expectEqual(a, try f.param(1, 0, &.{try Place.Step.field(&f.account, 10)}));
    var it = f.cells.children(root);
    try testing.expectEqual(a, it.next().?);
    try testing.expectEqual(b, it.next().?);
    try testing.expectEqual(@as(?CellId, null), it.next());
    try testing.expectEqual(@as(u32, 4), f.account.growth_by[@backingInt(Ids.Category.cell)]);
    try testing.expectEqual(a_elems, f.cells.base(a_elems));
}

test "alias: prefixes, fields, constructors' alternatives, concrete cells and ⊤" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const r = try f.param(1, 0, &.{});
    const ra = try f.param(1, 0, &.{try Place.Step.field(&f.account, 10)});
    const rb = try f.param(1, 0, &.{try Place.Step.field(&f.account, 11)});
    const ra_elem = try f.param(1, 0, &.{ try Place.Step.field(&f.account, 10), Place.Step.elem });
    try testing.expectEqual(Alias.yes, f.cells.alias(&f.places, r, ra));
    try testing.expectEqual(Alias.yes, f.cells.alias(&f.places, ra_elem, r));
    try testing.expectEqual(Alias.no, f.cells.alias(&f.places, ra, rb));
    try testing.expectEqual(Alias.no, f.cells.alias(&f.places, ra_elem, rb));
    // Another parameter of the same type: never.
    const other = try f.param(2, 0, &.{try Place.Step.field(&f.account, 10)});
    try testing.expectEqual(Alias.no, f.cells.alias(&f.places, ra, other));
    // Two constructors of one value are alternatives (R-4.8.15).
    const editing = try f.param(3, 4, &.{try f.places.ctorStep(testing.allocator, &f.account, 1, 0)});
    const saving = try f.param(3, 4, &.{try f.places.ctorStep(testing.allocator, &f.account, 2, 0)});
    try testing.expectEqual(Alias.no, f.cells.alias(&f.places, editing, saving));
    // `⟲` matches any continuation: the root's list and a list below.
    const s1 = try f.places.ctorStep(testing.allocator, &f.account, 0, 1);
    const s0 = try f.places.ctorStep(testing.allocator, &f.account, 0, 0);
    const top_list = try f.param(4, 3, &.{s1});
    const deep_list = try f.param(4, 3, &.{ s0, s1 });
    const below = try f.param(4, 3, &.{s0});
    try testing.expectEqual(Alias.no, f.cells.alias(&f.places, top_list, deep_list));
    try testing.expectEqual(Alias.yes, f.cells.alias(&f.places, below, deep_list));
    try testing.expectEqual(Alias.no, f.cells.alias(&f.places, below, top_list));
    // Concrete cells alias only themselves; ⊤ aliases everything.
    const list_place = try f.places.of(testing.allocator, &f.account, f.graph.source(), 1);
    const s7 = try f.cells.site(testing.allocator, &f.account, 7, list_place, .list);
    const s8 = try f.cells.site(testing.allocator, &f.account, 8, list_place, .list);
    try testing.expectEqual(s7, try f.cells.site(testing.allocator, &f.account, 7, list_place, .list));
    try testing.expectEqual(Alias.no, f.cells.alias(&f.places, s7, s8));
    try testing.expectEqual(Alias.no, f.cells.alias(&f.places, s7, ra));
    const t = try f.cells.top(testing.allocator, &f.account);
    try testing.expectEqual(Alias.yes, f.cells.alias(&f.places, t, s8));
    try testing.expectEqual(Alias.yes, f.cells.alias(&f.places, ra, t));
}

test "alias on refinements answers the split, and two taken elements the container's κ" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const xs = try f.param(1, 1, &.{});
    const elem_place = try f.places.of(gpa, &f.account, f.graph.source(), 2);
    const l1 = try f.cells.label(gpa, &f.account, 40, .none, false);
    const l2 = try f.cells.label(gpa, &f.account, 41, .none, false);
    try testing.expectEqual(l1, try f.cells.label(gpa, &f.account, 40, .none, false));
    try testing.expect(l1 != l2);
    const split1 = try f.cells.split(gpa, &f.account, xs, 40, l1, .none);
    _ = try f.cells.split(gpa, &f.account, xs, 41, l2, .none);
    const e1 = try f.cells.refine(gpa, &f.account, .elem, xs, l1, 0, elem_place, .none);
    const o1 = try f.cells.refine(gpa, &f.account, .others, xs, l1, 0, .none, .list);
    const e2 = try f.cells.refine(gpa, &f.account, .elem, xs, l2, 0, elem_place, .none);
    try testing.expectEqual(xs, f.cells.base(e1));
    try testing.expectEqual(Alias{ .under = split1 }, f.cells.alias(&f.places, e1, o1));
    try testing.expectEqual(Alias{ .under_kappa = xs }, f.cells.alias(&f.places, e1, e2));
    // The container whole and its element may alias; a different list's
    // element never.
    try testing.expectEqual(Alias.yes, f.cells.alias(&f.places, xs, e1));
    const ys = try f.param(2, 1, &.{});
    const ey = try f.cells.refine(gpa, &f.account, .elem, ys, l1, 0, elem_place, .none);
    try testing.expectEqual(Alias.no, f.cells.alias(&f.places, e1, ey));
    // Two `below`s of distinct steps are two sides; of one step, one cell.
    const tree = try f.param(3, 3, &.{});
    const b0 = try f.cells.refine(gpa, &f.account, .below, tree, l1, 0, .none, .none);
    const b2 = try f.cells.refine(gpa, &f.account, .below, tree, l1, 2, .none, .none);
    const lv = try f.cells.refine(gpa, &f.account, .level, tree, l1, 0, .none, .none);
    const split_t = f.cells.findSplit(tree, l1);
    try testing.expectEqual(SplitId.none, split_t);
    try testing.expectEqual(Alias.yes, f.cells.alias(&f.places, b0, b2)); // no split recorded: conservative
    const st = try f.cells.split(gpa, &f.account, tree, 40, l1, .none);
    try testing.expectEqual(Alias{ .under = st }, f.cells.alias(&f.places, b0, b2));
    try testing.expectEqual(Alias{ .under = st }, f.cells.alias(&f.places, lv, b2));
    try testing.expectEqual(b0, try f.cells.refine(gpa, &f.account, .below, tree, l1, 0, .none, .none));
}

/// Recursive types whose cycle passes through another place: 0 `type Rose =
/// Rose (List Rose)` (1 its `List Rose`); 2 `type T = T (Maybe T) (List
/// Int)` (3 `Maybe T`, 4 `List Int`); 5 `type A = A B | Leaf Int`, 6 `type B
/// = B (List A)` (7 `List A`); 8 `Int`.
const CycleGraph = struct {
    table: *Place.Table,
    account: *Ids.Account,
    gpa: Allocator,

    fn describe(ctx: *anyopaque, v: u32, out: *std.ArrayList(Place.Child)) Allocator.Error!Place.Description {
        const g: *CycleGraph = @ptrCast(@alignCast(ctx));
        const step = struct {
            fn ctor(gg: *CycleGraph, c: u32, i: u32) Place.Step {
                return gg.table.ctorStep(gg.gpa, gg.account, c, i) catch unreachable;
            }
        };
        switch (v) {
            0 => {
                try out.append(g.gpa, .{ .step = step.ctor(g, 0, 0), .@"var" = 1 });
                return .{ .kind = .ctor, .head = 500 };
            },
            1 => {
                try out.append(g.gpa, .{ .step = Place.Step.elem, .@"var" = 0 });
                return .{ .kind = .list, .head = 200 };
            },
            2 => {
                try out.append(g.gpa, .{ .step = step.ctor(g, 0, 0), .@"var" = 3 });
                try out.append(g.gpa, .{ .step = step.ctor(g, 0, 1), .@"var" = 4 });
                return .{ .kind = .ctor, .head = 600 };
            },
            3 => {
                try out.append(g.gpa, .{ .step = step.ctor(g, 1, 0), .@"var" = 2 });
                return .{ .kind = .ctor, .head = 300 };
            },
            4 => {
                try out.append(g.gpa, .{ .step = Place.Step.elem, .@"var" = 8 });
                return .{ .kind = .list, .head = 200 };
            },
            5 => {
                try out.append(g.gpa, .{ .step = step.ctor(g, 0, 0), .@"var" = 6 });
                try out.append(g.gpa, .{ .step = step.ctor(g, 1, 0), .@"var" = 8 });
                return .{ .kind = .ctor, .head = 700 };
            },
            6 => {
                try out.append(g.gpa, .{ .step = step.ctor(g, 0, 0), .@"var" = 7 });
                return .{ .kind = .ctor, .head = 800 };
            },
            7 => {
                try out.append(g.gpa, .{ .step = Place.Step.elem, .@"var" = 5 });
                return .{ .kind = .list, .head = 200 };
            },
            8 => return .{ .kind = .cross },
            else => unreachable,
        }
    }
};

test "⟲ matches a step onto its cycle: Rose, Maybe T and mutual recursion" {
    var places: Place.Table = .{};
    defer places.deinit(testing.allocator);
    var cells: Table = .{};
    defer cells.deinit(testing.allocator);
    var account: Ids.Account = .{};
    defer account.deinit(testing.allocator);
    var g: CycleGraph = .{ .table = &places, .account = &account, .gpa = testing.allocator };
    const source: Place.Source = .{ .ctx = &g, .describe = CycleGraph.describe };
    const gpa = testing.allocator;
    const Ctx = struct {
        places: *Place.Table,
        cells: *Table,
        account: *Ids.Account,
        fn param(c: @This(), i: u32, root: Place.PlaceId, steps: []const Place.Step) !CellId {
            var at = try c.places.rootPath(testing.allocator, root);
            for (steps) |s| at = (try c.places.extend(testing.allocator, .growth(c.account), at, s)).?;
            return c.cells.symbolic(testing.allocator, c.account, c.places, .param, i, at, 0);
        }
    };
    const cx: Ctx = .{ .places = &places, .cells = &cells, .account = &account };
    // Rose: the root's children list is `#Rose.0`; its elements re-enter
    // Rose and are `⟲`. The list aliases the subtrees, and so does a list
    // below.
    const rose = try places.of(gpa, &account, source, 0);
    const r0 = try places.ctorStep(gpa, &account, 0, 0);
    const kids = try cx.param(1, rose, &.{r0});
    const subtrees = try cx.param(1, rose, &.{ r0, Place.Step.elem });
    try testing.expectEqual(Place.StepKind.level, places.pathStep(.from(cells.get(subtrees).b)).kind);
    try testing.expectEqual(Alias.yes, cells.alias(&places, kids, subtrees));
    const deep_kids = try cx.param(1, rose, &.{ r0, Place.Step.elem, r0 });
    try testing.expectEqual(Alias.yes, cells.alias(&places, kids, deep_kids));
    try testing.expect(places.sameCycle(rose, places.child(rose, r0).?));
    // Maybe T: the `Maybe` step is on T's cycle, the `List Int` is not.
    const t = try places.of(gpa, &account, source, 2);
    const t0 = try places.ctorStep(gpa, &account, 0, 0);
    const t1 = try places.ctorStep(gpa, &account, 0, 1);
    const just = try places.ctorStep(gpa, &account, 1, 0);
    const maybe = try cx.param(2, t, &.{t0});
    const below_t = try cx.param(2, t, &.{ t0, just });
    const own_list = try cx.param(2, t, &.{t1});
    try testing.expectEqual(Alias.yes, cells.alias(&places, maybe, below_t));
    try testing.expectEqual(Alias.no, cells.alias(&places, own_list, below_t));
    try testing.expectEqual(Alias.no, cells.alias(&places, own_list, maybe));
    // Mutual recursion: A's B, B's list and the A below are one cycle; A's
    // `Leaf Int` is not.
    const a = try places.of(gpa, &account, source, 5);
    const a0 = try places.ctorStep(gpa, &account, 0, 0);
    const leaf = try places.ctorStep(gpa, &account, 1, 0);
    const b0 = try places.ctorStep(gpa, &account, 0, 0);
    const b = try cx.param(3, a, &.{a0});
    const b_list = try cx.param(3, a, &.{ a0, b0 });
    const below_a = try cx.param(3, a, &.{ a0, b0, Place.Step.elem });
    try testing.expectEqual(Alias.yes, cells.alias(&places, b, below_a));
    try testing.expectEqual(Alias.yes, cells.alias(&places, b_list, below_a));
    const a_leaf = try cx.param(3, a, &.{leaf});
    try testing.expectEqual(Alias.no, cells.alias(&places, a_leaf, below_a));
    try testing.expectEqual(Alias.no, cells.alias(&places, a_leaf, b));
}

test "intersection is the common keys, approximate when either is, and skips what one side has no prefix for" {
    var r: Radix = .{};
    defer r.deinit(testing.allocator);
    var a: Account = .{};
    defer a.deinit(testing.allocator);
    const gpa = testing.allocator;
    const g: Charge = .growth(&a);
    var s: SetId = .none;
    for ([_]u32{ 1, 2, 3, 5, 1_000_000 }) |key| s = try r.insert(gpa, g, s, key, 0);
    var t: SetId = .none;
    for ([_]u32{ 2, 4, 1_000_000 }) |key| t = try r.insert(gpa, g, t, key, 0);
    t = try r.insert(gpa, g, t, 3, 1);
    const both = try r.intersection(gpa, g, s, t);
    try testing.expectEqual(@as(u32, 3), r.count(both));
    try testing.expectEqual(@as(?u1, 0), r.get(both, 2));
    try testing.expectEqual(@as(?u1, 1), r.get(both, 3));
    try testing.expectEqual(@as(?u1, 0), r.get(both, 1_000_000));
    try testing.expect(!r.member(both, 1) and !r.member(both, 4) and !r.member(both, 5));
    try testing.expectEqual(both, try r.intersection(gpa, g, t, s));
    try testing.expectEqual(s, try r.intersection(gpa, g, s, s));
    try testing.expectEqual(SetId.none, try r.intersection(gpa, g, s, .none));
    var far: SetId = .none;
    for ([_]u32{ 7, 8, 9 }) |key| far = try r.insert(gpa, g, far, key, 0);
    // Disjoint sets whose prefixes part high up: a few nodes, no result.
    const before = a.growth;
    try testing.expectEqual(SetId.none, try r.intersection(gpa, g, s, far));
    try testing.expect(a.growth - before <= 4);
}

test "below, stepsTo and unrefined: containment by the trie, by refinement and through ⟲" {
    var places: Place.Table = .{};
    defer places.deinit(testing.allocator);
    var cells: Table = .{};
    defer cells.deinit(testing.allocator);
    var account: Ids.Account = .{};
    defer account.deinit(testing.allocator);
    const gpa = testing.allocator;
    var g: CycleGraph = .{ .table = &places, .account = &account, .gpa = gpa };
    const source: Place.Source = .{ .ctx = &g, .describe = CycleGraph.describe };
    const rose = try places.of(gpa, &account, source, 0);
    const r0 = try places.ctorStep(gpa, &account, 0, 0);
    const Ctx = struct {
        places: *Place.Table,
        cells: *Table,
        account: *Ids.Account,
        fn param(c: @This(), root: Place.PlaceId, steps: []const Place.Step) !CellId {
            var at = try c.places.rootPath(testing.allocator, root);
            for (steps) |s| at = (try c.places.extend(testing.allocator, .growth(c.account), at, s)).?;
            return c.cells.symbolic(testing.allocator, c.account, c.places, .param, 0, at, 0);
        }
    };
    const cx: Ctx = .{ .places = &places, .cells = &cells, .account = &account };
    const root = try cx.param(rose, &.{});
    const kids = try cx.param(rose, &.{r0});
    const subtrees = try cx.param(rose, &.{ r0, Place.Step.elem }); // r⟲
    const deep_kids = try cx.param(rose, &.{ r0, Place.Step.elem, r0 }); // r⟲#Rose.0
    // A trie descendant is below its ancestor, never the other way.
    try testing.expect(cells.below(&places, kids, root));
    try testing.expect(!cells.below(&places, root, kids));
    try testing.expect(!cells.below(&places, kids, kids));
    // Through `⟲`: the subtrees and their lists are below the children list,
    // which is not below them.
    try testing.expect(cells.below(&places, subtrees, kids));
    try testing.expect(cells.below(&places, deep_kids, kids));
    try testing.expect(!cells.below(&places, kids, deep_kids));
    // stepsTo: the trie's steps; none through a `⟲` relation.
    var steps: std.ArrayList(Place.Step) = .empty;
    defer steps.deinit(gpa);
    try testing.expect(try cells.stepsTo(&places, root, deep_kids, gpa, &steps));
    try testing.expectEqual(@as(usize, 2), steps.items.len);
    try testing.expectEqual(Place.StepKind.level, steps.items[0].kind);
    steps.clearRetainingCapacity();
    try testing.expect(!try cells.stepsTo(&places, kids, deep_kids, gpa, &steps));
    // A refinement: an element of the children list is below it, its steps
    // `[*]`, its canonical position the subtrees.
    const l = try cells.label(gpa, &account, 40, .none, false);
    const e = try cells.refine(gpa, &account, .elem, kids, l, 0, places.child(places.child(rose, r0).?, Place.Step.elem).?, .none);
    try testing.expect(cells.below(&places, e, kids));
    steps.clearRetainingCapacity();
    try testing.expect(try cells.stepsTo(&places, kids, e, gpa, &steps));
    try testing.expectEqual(@as(usize, 1), steps.items.len);
    try testing.expectEqual(subtrees, (try cells.unrefined(gpa, &account, &places, e)).?);
    // Two positions one pattern takes are two sides of its split.
    const e2 = try cells.refine(gpa, &account, .elem, kids, l, 1, places.child(places.child(rose, r0).?, Place.Step.elem).?, .none);
    const s = try cells.split(gpa, &account, kids, 40, l, .none);
    try testing.expectEqual(Alias{ .under = s }, cells.alias(&places, e, e2));
}
