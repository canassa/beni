//! The decision tree of `docs/design/backend.md` §7: one tree over ALL the
//! branches of a `case`, so that no branch re-tests what the branches above
//! it already disproved.
//!
//! Compilation is Maranget's, in the shape §7 fixes: a `case` of *m*
//! branches starts as a matrix of *m* rows and one column (the scrutinee);
//! pick a column, ask which constructors occur in it, and for each one
//! **specialise** — keep the rows whose pattern there is that constructor or
//! a wildcard, replacing the constructor's with its argument sub-patterns in
//! place, so the column becomes *arity* columns. A column of wildcards
//! everywhere is dropped; a matrix whose first row is all wildcards is a
//! leaf.
//!
//! **Pattern forms are simplified exactly as `check/Exhaustive.zig`
//! simplifies them**, and the vocabulary is deliberately shared with it
//! (§7's table): `_`, a variable and a record pattern are *anything*; `p as
//! x` is `p`; a tuple and `()` are the sole constructor of a one-constructor
//! union, so they never become a test and only widen the matrix; `[ a, b ]`
//! is a cons of `a` onto a cons of `b` onto the empty list, over the two
//! alternatives of a list cell, and `[ a, ...rest ]` a cons of `a` onto
//! `rest` — while a column holding items AFTER a spread is split by length
//! instead (`lengthSplit`, backend.md §7); and an
//! `Int`, `Char` or `String` literal has infinitely many alternatives, so
//! its node always keeps a default edge.
//!
//! **Nothing here builds a `JsIr` node or knows a representation.** What it
//! produces is a tree of tests over OCCURRENCES — paths of slot indices down
//! from the scrutinee — and `js/Lower.zig` turns each into the member chain
//! and the `===` §4's representation asks for. The one thing an edge carries
//! out of `Bir` is the instruction that *names* its constructor or spells
//! its literal, which is what the emitter reads the representation from.
//!
//! **Determinism** (CLAUDE.md rule 5) is structural throughout: the
//! constructor set at a column is enumerated in the declaring type's
//! declaration order, literals in the order the rows spell them, and the
//! column tie-break is the lowest index. The one hash table (`HeadTable`)
//! only GROUPS rows by their head: every order is still the rows' own, and
//! nothing iterates the table.
//!
//! **Linear in the rows at each node**. A column's rows are
//! grouped by head once, in one pass (`group`), and each specialisation reads
//! only its own group and the wildcard rows — never the whole matrix again.
//! Before, the key set, the column choice's distinct count and the
//! specialisation each compared every row with every other, and a `case` of
//! 20 000 literal branches took 8.6 s to build.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Interface = @import("../resolve/Interface.zig");

const Inst = Bir.Inst;

/// "No such node": an edge whose matrix held no row. It cannot arise from an
/// exhaustive `case` — every edge is created from a row that reached it —
/// and the emitter drops one if it ever does.
pub const no_node: u32 = std.math.maxInt(u32);

/// What the tree has to read out of the module. A `Bir` and the interfaces
/// of everything it imports, which is all a constructor's declaring type
/// takes: `Exhaustive.ctorUnion` reads exactly these two for exactly this,
/// and for the same reason (`fast-compiler.md` §8.1 — a cached dependency's
/// `Bir` may not be in memory and its interface always is).
pub const Context = struct {
    bir: *const Bir,
    interfaces: []const Interface,
};

/// Where a column's value is read from: a path of slot indices down from one
/// of the roots. `root` is the scrutinee, or one element of it when §7's
/// tuple-literal rule made the `case` an n-column matrix.
///
/// The path and not an expression, because §7 emits an occurrence as a
/// member chain REBUILT at each use — every value is immutable and every
/// step is a property read, so re-reading costs nothing and there is no
/// `const $p$k` per edge for the release optimiser to fail to eliminate.
pub const Occ = struct {
    root: u32,
    parent: u32 = no_parent,
    /// The slot index (`a`, `b`, …) this occurrence is of its parent.
    slot: u32 = 0,
    /// The constructor reference the parent was destructured through, when
    /// it was one: the emitter reads the argument's REPRESENTATION off it.
    /// A record alias's constructor builds a record (backend.md §4), so its
    /// argument `slot` is the alias's field `slot` in declaration order and
    /// not the positional `a`, `b`, … every other constructor uses.
    via: Inst.OptionalIndex = .none,
    /// `.slot` is the parent's slot `slot`. `.head` and `.tail` are the
    /// parent list's first element and the list after it — a `::`'s two
    /// columns — which the emitter reads as an index into the list the
    /// chain of tails started from (`backend.md` §7, *List patterns over
    /// arrays*). `.last` is the list made of the parent list's last `slot`
    /// elements — where a pattern's items after its spread are read from
    /// (*List patterns with elements after the spread*).
    kind: enum(u8) { slot, head, tail, last } = .slot,

    pub const no_parent: u32 = std.math.maxInt(u32);
};

/// What a fan-out tests. The emitter turns each into §4's representation:
/// `subj` or `subj.$` against a tag for `.ctor`, `subj.$` against `0`/`1`
/// for `.list`, and `subj` against the literal for the other three.
pub const Kind = enum { ctor, list, int, char, string };

/// One alternative of a fan-out.
pub const Edge = struct {
    /// The constructor reference (`ctor` / `ext_ctor`) for `.ctor` and the
    /// literal PATTERN instruction for a literal kind: what the emitter
    /// reads the representation and the spelling from. `.none` for `.list`,
    /// whose two constructors are the emitter's own `{$:0}` / `{$:1}`.
    ref: Inst.OptionalIndex = .none,
    /// Declaration order within the type for `.ctor`, `0`/`1` for `.list`,
    /// and the order the rows first spell it for a literal. It is what the
    /// edges are sorted by, and what makes the fan input-derived.
    order: u32,
    child: u32,
};

pub const Fan = struct {
    occ: u32,
    kind: Kind,
    edges_start: u32,
    edges_end: u32,
    /// The edge every row that was a wildcard here takes, or `no_node` when
    /// no row was — in which case the LAST edge is the exhaustive
    /// alternative and is spelled `default:` (§7: no impossible arm, no
    /// `throw`).
    default: u32 = no_node,

    pub fn edgeCount(f: Fan) u32 {
        return f.edges_end - f.edges_start;
    }

    /// How many `case` labels the fan would print: §7's threshold is three.
    pub fn labels(f: Fan) u32 {
        return f.edgeCount() + @intFromBool(f.default != no_node);
    }
};

pub const TNode = union(enum) {
    /// A branch of the `case`, by index.
    leaf: u32,
    /// Index into `fans`.
    fan: u32,
};

pub const Tree = struct {
    nodes: []const TNode,
    fans: []const Fan,
    edges: []const Edge,
    occs: []const Occ,
    root: u32,
    /// How many leaves reach each branch. §7's counted rule: one path
    /// inline, two or more shared through a labelled block.
    uses: []const u32,

    pub fn node(t: Tree, index: u32) TNode {
        return t.nodes[index];
    }

    /// Whether any fan-out prints as a `switch` rather than an `if`.
    pub fn hasSwitch(t: Tree) bool {
        for (t.fans) |f| if (f.labels() >= 3) return true;
        return false;
    }

    pub fn hasShared(t: Tree) bool {
        for (t.uses) |u| if (u >= 2) return true;
        return false;
    }

    /// How many times the tree TESTS something read from root `r`. The
    /// other half of §7's "`bindSubject` binds only when the tree reads the
    /// root more than once" is the leaf bindings, which the emitter counts
    /// from the patterns themselves.
    ///
    /// A fan counts once per discriminant the emitter prints for it (§7,
    /// dated note 2026-09-29). One with a single label — the sole
    /// constructor of a one-constructor type — prints no test and reads
    /// nothing; counting it once left `case Debug.log m "m" of Inc ->` with
    /// its scrutinee unbound and never read, so the call was never made.
    /// One wider than `max_labels` is split into consecutive `switch`es,
    /// each reading its discriminant; counting it once let an unbound
    /// scrutinee be evaluated once per `switch`.
    pub fn fanReads(t: Tree, r: u32, max_labels: u32) u32 {
        var count: u32 = 0;
        for (t.fans) |f| {
            if (t.occs[f.occ].root != r) continue;
            const labels = f.labels();
            if (labels >= 2) count += std.math.divCeil(u32, labels, max_labels) catch unreachable;
        }
        return count;
    }
};

/// One row of the initial matrix: a branch and the pattern each root is
/// matched against. `.none` is a wildcard — the `_` row of §7's
/// tuple-literal rule, which matches whatever the elements are.
pub const Row = struct {
    branch: u32,
    pats: []const Inst.OptionalIndex,
};

/// Compile `rows` over `roots` occurrences into one tree.
pub fn build(arena: Allocator, cx: Context, roots: u32, rows: []const Row, branches: u32) Allocator.Error!Tree {
    var b: Builder = .{ .arena = arena, .cx = cx, .uses = try arena.alloc(u32, branches) };
    @memset(b.uses, 0);

    const cols = try arena.alloc(u32, roots);
    for (cols, 0..) |*col, i| col.* = try b.rootOcc(@intCast(i));

    const start_rows = try arena.alloc(MRow, rows.len);
    for (rows, start_rows) |row, *out| {
        const cells = try arena.alloc(Cell, roots);
        for (cells, 0..) |*cell, i| cell.* = .{ .pat = if (i < row.pats.len) row.pats[i] else .none };
        out.* = .{ .branch = row.branch, .cells = cells };
    }

    const root = try b.compile(.{ .cols = cols, .rows = start_rows });
    for (b.nodes.items) |n| switch (n) {
        .leaf => |branch| if (branch < b.uses.len) {
            b.uses[branch] += 1;
        },
        .fan => {},
    };
    return .{
        .nodes = b.nodes.items,
        .fans = b.fans.items,
        .edges = b.edges.items,
        .occs = b.occs.items,
        .root = root,
        .uses = b.uses,
    };
}

/// One cell of the matrix. A `pat_list` is `[ a, b, c ]` NORMALISED to
/// `a :: b :: c :: []` (§7's table) without rewriting `Bir`: `from` is how
/// many of its elements the tree has already consumed, so the same
/// instruction is the head of a cons at `from < len` and the empty list at
/// `from == len`.
const Cell = struct {
    /// `.none` is a wildcard, either written or made by specialising a row
    /// that was one.
    pat: Inst.OptionalIndex = .none,
    from: u32 = 0,
};

const MRow = struct {
    branch: u32,
    cells: []const Cell,
};

const Matrix = struct {
    cols: []const u32,
    rows: []const MRow,
};

const Ctor = struct {
    ref: Inst.Index,
    /// Index within the declaring type, which is the fan's order.
    order: u32,
    /// How many constructors the type has, which is what says whether the
    /// alternatives present at a node are all of them.
    count: u32,
    arity: u32,
};

/// A cell's head constructor, in `Exhaustive.zig`'s three shapes plus the
/// structural ones it invents unions for.
const Head = union(enum) {
    wild,
    ctor: Ctor,
    /// A tuple, of this arity: the sole constructor of a one-constructor
    /// union, so it never becomes a test and only widens the matrix.
    tuple: u32,
    unit,
    /// `true` is `::`, `false` is `[]`.
    list: bool,
    literal: struct { pat: Inst.Index, kind: Kind },
};

/// A column's rows grouped by head (`Builder.group`): the distinct heads in
/// the order the rows first spell them, each head's rows as a range of
/// `rows` in row order, and the wildcard rows in row order.
const Grouping = struct {
    keys: []const Head,
    /// `rows[starts[k]..starts[k + 1]]` are key `k`'s rows.
    starts: []const u32,
    rows: []const u32,
    wild: []const u32,

    fn of(g: Grouping, k: usize) []const u32 {
        return g.rows[g.starts[k]..g.starts[k + 1]];
    }
};

/// Heads by `sameHead`, for grouping a column. Keyed by what a head IS — a
/// constructor's order, a literal's spelling — never by a dense id.
const HeadTable = std.HashMapUnmanaged(Head, u32, HeadContext, std.hash_map.default_max_load_percentage);

const HeadContext = struct {
    bir: *const Bir,

    pub fn hash(ctx: HeadContext, h: Head) u64 {
        var hasher = std.hash.Wyhash.init(0);
        // `tuple` and `unit` are one head (`sameHead`), so they hash alike.
        const tag: std.meta.Tag(Head) = if (h == .unit) .tuple else std.meta.activeTag(h);
        hasher.update(&.{@intFromEnum(tag)});
        switch (h) {
            .wild, .tuple, .unit => {},
            .ctor => |c| hasher.update(std.mem.asBytes(&c.order)),
            .list => |cons| hasher.update(&.{@intFromBool(cons)}),
            .literal => |lit| {
                hasher.update(&.{@intFromEnum(lit.kind)});
                switch (ctx.bir.instTag(lit.pat)) {
                    .pat_char => hasher.update(std.mem.asBytes(&ctx.bir.instData(lit.pat).lhs)),
                    .pat_int, .pat_string => hasher.update(ctx.bir.bytes(lit.pat)),
                    else => {},
                }
            },
        }
        return hasher.final();
    }

    pub fn eql(ctx: HeadContext, x: Head, y: Head) bool {
        return sameHead(ctx.bir, x, y);
    }
};

const Builder = struct {
    arena: Allocator,
    cx: Context,
    occs: std.ArrayList(Occ) = .empty,
    nodes: std.ArrayList(TNode) = .empty,
    fans: std.ArrayList(Fan) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    uses: []u32,
    /// Reused by every grouping: cleared per column, read only inside
    /// `group` and `chooseColumn`, never across a recursive `compile`.
    table: HeadTable = .empty,

    fn rootOcc(b: *Builder, root: u32) !u32 {
        for (b.occs.items, 0..) |o, i| {
            if (o.parent == Occ.no_parent and o.root == root) return @intCast(i);
        }
        const index: u32 = @intCast(b.occs.items.len);
        try b.occs.append(b.arena, .{ .root = root });
        return index;
    }

    /// The occurrence of slot `slot` of `parent`, interned so that two
    /// columns reaching the same value are one occurrence and the emitter
    /// builds its member chain once.
    ///
    /// `via` is the constructor the parent is destructured through. All the
    /// constructors of one type share a representation, and a record alias
    /// has exactly one, so the first `via` recorded answers for the slot.
    fn subOcc(b: *Builder, parent: u32, slot: u32, via: Inst.OptionalIndex) !u32 {
        return b.internOcc(parent, slot, via, .slot);
    }

    /// The head (`slot` 0) or the tail (`slot` 1) of the list at `parent`,
    /// the two columns a `::` specialises into.
    fn listOcc(b: *Builder, parent: u32, slot: u32) !u32 {
        return b.internOcc(parent, slot, .none, if (slot == 0) .head else .tail);
    }

    fn internOcc(b: *Builder, parent: u32, slot: u32, via: Inst.OptionalIndex, kind: @FieldType(Occ, "kind")) !u32 {
        for (b.occs.items, 0..) |o, i| {
            if (o.parent == parent and o.slot == slot and o.kind == kind) return @intCast(i);
        }
        const index: u32 = @intCast(b.occs.items.len);
        try b.occs.append(b.arena, .{ .root = b.occs.items[parent].root, .parent = parent, .slot = slot, .via = via, .kind = kind });
        return index;
    }

    fn leafNode(b: *Builder, branch: u32) !u32 {
        const index: u32 = @intCast(b.nodes.items.len);
        try b.nodes.append(b.arena, .{ .leaf = branch });
        return index;
    }

    // ---- Heads ------------------------------------------------------------

    fn headOf(b: *Builder, cell: Cell) Head {
        const pat = cell.pat.unwrap() orelse return .wild;
        const bir = b.cx.bir;
        if (pat.int() >= bir.insts.len) return .wild;
        const d = bir.instData(pat);
        return switch (bir.instTag(pat)) {
            // A record pattern binds names and cannot fail: a record type
            // has no alternatives (`Exhaustive.simplify`, §7's table).
            .pat_wild, .pat_var, .pat_record => .wild,
            .pat_as => b.headOf(.{ .pat = @as(Inst.Index, @enumFromInt(d.lhs)).toOptional() }),
            .pat_unit => .unit,
            .pat_tuple => .{ .tuple = Bir.inlineRange(d).len() },
            .pat_int => .{ .literal = .{ .pat = pat, .kind = .int } },
            .pat_char => .{ .literal = .{ .pat = pat, .kind = .char } },
            .pat_string => .{ .literal = .{ .pat = pat, .kind = .string } },
            .pat_list => blk: {
                const len = Bir.inlineRange(d).len();
                // `[ a, b, ...rest ]` is `a :: b :: rest` (§7's table): a
                // cons while items before the spread remain, then the
                // spread's operand, which binds and tests nothing. Items
                // AFTER a spread make the column a length split (`compile`),
                // whatever this answers — only that it is not a wildcard.
                if (spreadIndex(bir, pat)) |s| break :blk if (cell.from < s or s + 1 < len) .{ .list = true } else .wild;
                break :blk .{ .list = cell.from < len };
            },
            .pat_ctor => blk: {
                const arity = bir.subRange(@enumFromInt(d.rhs)).len();
                break :blk if (b.ctorInfo(@enumFromInt(d.lhs), arity)) |c| .{ .ctor = c } else .wild;
            },
            // A pattern the parser or the resolver could not build. A build
            // with any error diagnostic emits nothing, so this is
            // unreachable from a successful one; treating it as a wildcard
            // keeps a bug in that gate from becoming a crash.
            else => .wild,
        };
    }

    /// Where a constructor sits in its declaring type, and how many siblings
    /// it has — `Exhaustive.ctorUnion`'s two answers, without the `TypeId`
    /// it needs for interning and this does not.
    fn ctorInfo(b: *Builder, ref: Inst.Index, arity: u32) ?Ctor {
        const bir = b.cx.bir;
        if (ref.int() >= bir.insts.len) return null;
        const d = bir.instData(ref);
        switch (bir.instTag(ref)) {
            .ctor => {
                if (d.lhs >= bir.ctors.len) return null;
                const owner = bir.decl(bir.ctors[d.lhs].decl);
                if (owner.ctors_end <= owner.ctors_start) return null;
                if (d.lhs < owner.ctors_start or d.lhs >= owner.ctors_end) return null;
                return .{
                    .ref = ref,
                    .order = d.lhs - owner.ctors_start,
                    .count = owner.ctors_end - owner.ctors_start,
                    .arity = arity,
                };
            },
            .ext_ctor => {
                if (d.lhs >= b.cx.interfaces.len) return null;
                const iface = &b.cx.interfaces[d.lhs];
                if (d.rhs >= iface.ctors.len) return null;
                const type_index = iface.ctors[d.rhs].type;
                if (@intFromEnum(type_index) >= iface.types.len) return null;
                const t = iface.types[@intFromEnum(type_index)];
                if (t.ctors_end <= t.ctors_start) return null;
                if (d.rhs < t.ctors_start or d.rhs >= t.ctors_end) return null;
                return .{
                    .ref = ref,
                    .order = d.rhs - t.ctors_start,
                    .count = t.ctors_end - t.ctors_start,
                    .arity = arity,
                };
            },
            else => return null,
        }
    }

    // ---- The algorithm ----------------------------------------------------

    fn compile(b: *Builder, m: Matrix) Allocator.Error!u32 {
        // Only reachable from a `case` the checker could not prove
        // exhaustive (§7's documented hole) or from one with no branches at
        // all. Neither may crash the compiler and neither gets a `throw`.
        if (m.rows.len == 0) return no_node;
        if (b.allWild(m.rows[0])) return b.leafNode(m.rows[0].branch);

        const col = try b.chooseColumn(m);
        if (try b.needsLengthSplit(m, col)) return b.lengthSplit(m, col);

        const g = try b.group(m, col);
        const has_default = g.wild.len != 0;
        // Unreachable: the row above is not all wildcards, so the column
        // chosen for it holds something. A leaf rather than an index out of
        // bounds, because a poisoned `Bir` must not panic the compiler.
        if (g.keys.len == 0) return b.leafNode(m.rows[0].branch);

        // A tuple and `()` always match: the column becomes its elements and
        // no test is emitted, which is what keeps a tuple scrutinee from
        // costing a comparison it cannot fail (§7's table).
        switch (g.keys[0]) {
            .tuple, .unit => return b.expand(m, col, g.keys[0]),
            else => {},
        }

        const order = try b.arena.alloc(u32, g.keys.len);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        sortKeys(g.keys, order);

        const fan_index: u32 = @intCast(b.fans.items.len);
        const node_index: u32 = @intCast(b.nodes.items.len);
        try b.nodes.append(b.arena, .{ .fan = fan_index });
        try b.fans.append(b.arena, .{
            .occ = m.cols[col],
            .kind = kindOf(g.keys[0]),
            .edges_start = 0,
            .edges_end = 0,
            .default = no_node,
        });

        var built: std.ArrayList(Edge) = .empty;
        for (order) |k| {
            const key = g.keys[k];
            const child = try b.compile(try b.specialiseGroup(m, col, key, g.of(k), g.wild));
            if (child == no_node) continue;
            try built.append(b.arena, .{
                .ref = switch (key) {
                    .ctor => |c| c.ref.toOptional(),
                    .literal => |lit| lit.pat.toOptional(),
                    else => .none,
                },
                .order = orderOf(key),
                .child = child,
            });
        }
        // A default edge only when the alternatives present are NOT all of
        // them: a wildcard row is copied into every specialisation already,
        // so once the set is complete the default arm is the impossible one
        // §7 refuses to emit. A literal column is never complete, which is
        // why a literal node always keeps its default.
        const complete = switch (g.keys[0]) {
            .ctor => |c| built.items.len >= c.count,
            .list => built.items.len >= 2,
            else => false,
        };
        const default = if (has_default and !complete)
            try b.compile(try b.defaultMatrix(m, col, g.wild))
        else
            no_node;

        const start: u32 = @intCast(b.edges.items.len);
        try b.edges.appendSlice(b.arena, built.items);
        b.fans.items[fan_index].edges_start = start;
        b.fans.items[fan_index].edges_end = @intCast(b.edges.items.len);
        b.fans.items[fan_index].default = default;
        return node_index;
    }

    // ---- A list column split by length (backend.md §7, *List patterns
    // with elements after the spread*) ------------------------------------

    /// A list pattern as the length split reads it: its items before the
    /// spread, then its items after it, as cells, and whether it has one.
    const Shape = struct {
        items: []const Cell,
        prefix: u32,
        suffix: u32,
        spread: bool,
    };

    /// `cell` as a `Shape`, or null when it is no list pattern — a wildcard,
    /// or a pattern this tree cannot read. The items start at `cell.from`,
    /// the leading items a cons column has already consumed.
    fn listShape(b: *Builder, cell: Cell) Allocator.Error!?Shape {
        const bir = b.cx.bir;
        const pat = unwrapAs(bir, cell.pat.unwrap() orelse return null);
        if (pat.int() >= bir.insts.len or bir.instTag(pat) != .pat_list) return null;
        var items: std.ArrayList(Cell) = .empty;
        var prefix: u32 = 0;
        var suffix: u32 = 0;
        var spread = false;
        const elements = bir.extraSlice(Bir.inlineRange(bir.instData(pat)), Inst.Index);
        for (elements[@min(cell.from, elements.len)..]) |el| {
            if (bir.instTag(el) == .pat_spread) {
                spread = true;
                continue;
            }
            try items.append(b.arena, .{ .pat = el.toOptional() });
            if (spread) suffix += 1 else prefix += 1;
        }
        return .{ .items = items.items, .prefix = prefix, .suffix = suffix, .spread = spread };
    }

    /// Whether a row of column `col` names elements after a spread: only
    /// then is the column split by length rather than into `[]`/`::`, so a
    /// column without one compiles exactly as it always did.
    fn needsLengthSplit(b: *Builder, m: Matrix, col: u32) Allocator.Error!bool {
        for (m.rows) |row| {
            const shape = (try b.listShape(row.cells[col])) orelse continue;
            if (shape.suffix != 0) return true;
        }
        return false;
    }

    /// `checker.md` §6.6's split of a list column: `exact ℓ` for ℓ below
    /// `len`, and `at least len`, whose cells are the first `prefix` and
    /// the last `suffix` elements.
    const Lens = struct { prefix: u32, suffix: u32, len: u32 };

    fn lengthSplit(b: *Builder, m: Matrix, col: u32) Allocator.Error!u32 {
        const shapes = try b.arena.alloc(?Shape, m.rows.len);
        var fixed: ?u32 = null;
        var lens: Lens = .{ .prefix = 0, .suffix = 0, .len = 0 };
        for (m.rows, shapes) |row, *shape| {
            shape.* = try b.listShape(row.cells[col]);
            const s = shape.* orelse continue;
            if (s.spread) {
                lens.prefix = @max(lens.prefix, s.prefix);
                lens.suffix = @max(lens.suffix, s.suffix);
            } else fixed = @max(fixed orelse 0, s.prefix);
        }
        lens.len = lens.prefix + lens.suffix;
        if (fixed) |f| if (f + 1 > lens.len) {
            lens.prefix = f + 1 - lens.suffix;
            lens.len = f + 1;
        };
        return b.lengthNode(m, col, shapes, lens, 0, m.cols[col]);
    }

    /// The spine of the split: at depth ℓ, a list node on the ℓ-th tail —
    /// its `[]` edge is `exact ℓ`, its `::` edge the next depth — and at
    /// depth `len`, `at least len` itself. Each node is the two-way test a
    /// cons column writes, so the emitter needs nothing new for it.
    fn lengthNode(b: *Builder, m: Matrix, col: u32, shapes: []const ?Shape, lens: Lens, depth: u32, spine: u32) Allocator.Error!u32 {
        if (depth == lens.len) return b.compile(try b.lengthMatrix(m, col, shapes, lens, depth));
        const fan_index: u32 = @intCast(b.fans.items.len);
        const node_index: u32 = @intCast(b.nodes.items.len);
        try b.nodes.append(b.arena, .{ .fan = fan_index });
        try b.fans.append(b.arena, .{ .occ = spine, .kind = .list, .edges_start = 0, .edges_end = 0 });
        const exact = try b.compile(try b.lengthMatrix(m, col, shapes, lens, depth));
        const longer = try b.lengthNode(m, col, shapes, lens, depth + 1, try b.listOcc(spine, 1));
        const start: u32 = @intCast(b.edges.items.len);
        if (exact != no_node) try b.edges.append(b.arena, .{ .order = 0, .child = exact });
        if (longer != no_node) try b.edges.append(b.arena, .{ .order = 1, .child = longer });
        b.fans.items[fan_index].edges_start = start;
        b.fans.items[fan_index].edges_end = @intCast(b.edges.items.len);
        return node_index;
    }

    /// The specialisation by alternative `alt` (`exact alt` below
    /// `lens.len`, `at least` at it): the column becomes one column per
    /// element the alternative names, read down the spine for leading
    /// elements and from the `.last` occurrence for trailing ones.
    fn lengthMatrix(b: *Builder, m: Matrix, col: u32, shapes: []const ?Shape, lens: Lens, alt: u32) Allocator.Error!Matrix {
        const at_least = alt == lens.len;
        const arity = if (at_least) lens.prefix + lens.suffix else alt;
        const lead = if (at_least) lens.prefix else alt;
        const cols = try b.arena.alloc(u32, m.cols.len - 1 + arity);
        @memcpy(cols[0..col], m.cols[0..col]);
        @memcpy(cols[col + arity ..], m.cols[col + 1 ..]);
        var spine = m.cols[col];
        for (0..lead) |i| {
            cols[col + i] = try b.listOcc(spine, 0);
            spine = try b.listOcc(spine, 1);
        }
        if (at_least and lens.suffix != 0) {
            var last = try b.internOcc(m.cols[col], lens.suffix, .none, .last);
            for (0..lens.suffix) |j| {
                cols[col + lead + j] = try b.listOcc(last, 0);
                last = try b.listOcc(last, 1);
            }
        }

        const rows = try b.arena.alloc(MRow, m.rows.len);
        var len: usize = 0;
        for (m.rows, shapes) |row, shape| {
            const cells = try b.arena.alloc(Cell, cols.len);
            @memcpy(cells[0..col], row.cells[0..col]);
            @memcpy(cells[col + arity ..], row.cells[col + 1 ..]);
            const out = cells[col..][0..arity];
            @memset(out, .{});
            if (shape) |s| {
                if (!s.spread and (at_least or s.prefix != alt)) continue;
                if (s.spread and !at_least and s.prefix + s.suffix > alt) continue;
                @memcpy(out[0..s.prefix], s.items[0..s.prefix]);
                @memcpy(out[arity - s.suffix ..], s.items[s.prefix..]);
            }
            rows[len] = .{ .branch = row.branch, .cells = cells };
            len += 1;
        }
        return .{ .cols = cols, .rows = rows[0..len] };
    }

    fn allWild(b: *Builder, row: MRow) bool {
        for (row.cells) |cell| {
            if (b.headOf(cell) != .wild) return false;
        }
        return true;
    }

    /// §7's three rules, in order, stopping at the first that leaves one
    /// column: **d** (fewest wildcard rows), **b** (fewest distinct
    /// constructors) and **leftmost**. The third is not a formality — it is
    /// what makes the choice input-derived (CLAUDE.md rule 5) — and it falls
    /// out of scanning left to right and improving only on a strict win.
    ///
    /// The distinct count is the size of the column's head table:
    /// one hashed insert per row, where comparing each row with every row
    /// above it was quadratic.
    fn chooseColumn(b: *Builder, m: Matrix) Allocator.Error!u32 {
        var best: u32 = 0;
        var best_wild: usize = 0;
        var best_distinct: usize = 0;
        var found = false;
        const ctx: HeadContext = .{ .bir = b.cx.bir };
        for (0..m.cols.len) |i| {
            var wild: usize = 0;
            var relevant = false;
            b.table.clearRetainingCapacity();
            for (m.rows) |row| {
                const h = b.headOf(row.cells[i]);
                if (h == .wild) {
                    wild += 1;
                    continue;
                }
                relevant = true;
                _ = try b.table.getOrPutContext(b.arena, h, ctx);
            }
            const distinct: usize = b.table.count();
            if (!relevant) continue;
            if (found and wild > best_wild) continue;
            if (found and wild == best_wild and distinct >= best_distinct) continue;
            best = @intCast(i);
            best_wild = wild;
            best_distinct = distinct;
            found = true;
        }
        return best;
    }

    /// The column becomes the sole constructor's arity columns and every row
    /// is widened. Specialising by a one-constructor union drops no row —
    /// every row matches it — so this is the ordinary specialisation with no
    /// fan-out wrapped around it, which is exactly what "always matches, so
    /// it never becomes a test" means.
    fn expand(b: *Builder, m: Matrix, col: u32, key: Head) Allocator.Error!u32 {
        const all = try b.arena.alloc(u32, m.rows.len);
        for (all, 0..) |*r, i| r.* = @intCast(i);
        return b.compile(try b.specialiseGroup(m, col, key, all, &.{}));
    }

    /// Column `col`'s rows grouped by head, in one pass: each row's head is
    /// looked up once in the head table, and the groups are laid out by a
    /// counting sort that keeps every group in row order.
    fn group(b: *Builder, m: Matrix, col: u32) Allocator.Error!Grouping {
        const ctx: HeadContext = .{ .bir = b.cx.bir };
        b.table.clearRetainingCapacity();
        const wild_mark = std.math.maxInt(u32);
        const key_of = try b.arena.alloc(u32, m.rows.len);
        var keys: std.ArrayList(Head) = .empty;
        var wild_count: usize = 0;
        for (m.rows, key_of) |row, *k| {
            const h = b.headOf(row.cells[col]);
            if (h == .wild) {
                k.* = wild_mark;
                wild_count += 1;
                continue;
            }
            const gop = try b.table.getOrPutContext(b.arena, h, ctx);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(keys.items.len);
                try keys.append(b.arena, h);
            }
            k.* = gop.value_ptr.*;
        }
        const starts = try b.arena.alloc(u32, keys.items.len + 1);
        @memset(starts, 0);
        for (key_of) |k| if (k != wild_mark) {
            starts[k + 1] += 1;
        };
        for (1..starts.len) |i| starts[i] += starts[i - 1];
        const cursor = try b.arena.dupe(u32, starts[0..keys.items.len]);
        const rows = try b.arena.alloc(u32, m.rows.len - wild_count);
        const wild = try b.arena.alloc(u32, wild_count);
        var w: usize = 0;
        for (key_of, 0..) |k, r| {
            if (k == wild_mark) {
                wild[w] = @intCast(r);
                w += 1;
            } else {
                rows[cursor[k]] = @intCast(r);
                cursor[k] += 1;
            }
        }
        return .{ .keys = keys.items, .starts = starts, .rows = rows, .wild = wild };
    }

    /// The specialisation of `m` by `key` at `col`: `group`'s rows for the
    /// key and the wildcard rows, merged back into row order. No other row
    /// can match `key`, so none is read.
    fn specialiseGroup(b: *Builder, m: Matrix, col: u32, key: Head, keyed: []const u32, wild: []const u32) Allocator.Error!Matrix {
        const arity = arityOf(key);
        const cols = try b.arena.alloc(u32, m.cols.len - 1 + arity);
        @memcpy(cols[0..col], m.cols[0..col]);
        const via: Inst.OptionalIndex = switch (key) {
            .ctor => |c| c.ref.toOptional(),
            else => .none,
        };
        for (0..arity) |i| cols[col + i] = switch (key) {
            .list => try b.listOcc(m.cols[col], @intCast(i)),
            else => try b.subOcc(m.cols[col], @intCast(i), via),
        };
        @memcpy(cols[col + arity ..], m.cols[col + 1 ..]);

        const rows = try b.arena.alloc(MRow, keyed.len + wild.len);
        var len: usize = 0;
        var i: usize = 0;
        var j: usize = 0;
        while (i < keyed.len or j < wild.len) {
            const take_keyed = j == wild.len or (i < keyed.len and keyed[i] < wild[j]);
            const r = if (take_keyed) keyed[i] else wild[j];
            if (take_keyed) i += 1 else j += 1;
            const row = m.rows[r];
            const cells = try b.arena.alloc(Cell, cols.len);
            @memcpy(cells[0..col], row.cells[0..col]);
            @memcpy(cells[col + arity ..], row.cells[col + 1 ..]);
            if (!b.subCells(row.cells[col], key, cells[col..][0..arity])) continue;
            rows[len] = .{ .branch = row.branch, .cells = cells };
            len += 1;
        }
        return .{ .cols = cols, .rows = rows[0..len] };
    }

    /// Maranget's `D(P)`: the rows that were a wildcard at `col`, with the
    /// column dropped. A row that tested something there cannot reach the
    /// default edge.
    fn defaultMatrix(b: *Builder, m: Matrix, col: u32, wild: []const u32) Allocator.Error!Matrix {
        const cols = try b.arena.alloc(u32, m.cols.len - 1);
        @memcpy(cols[0..col], m.cols[0..col]);
        @memcpy(cols[col..], m.cols[col + 1 ..]);

        const rows = try b.arena.alloc(MRow, wild.len);
        for (wild, rows) |r, *out| {
            const row = m.rows[r];
            const cells = try b.arena.alloc(Cell, cols.len);
            @memcpy(cells[0..col], row.cells[0..col]);
            @memcpy(cells[col..], row.cells[col + 1 ..]);
            out.* = .{ .branch = row.branch, .cells = cells };
        }
        return .{ .cols = cols, .rows = rows };
    }

    /// The sub-patterns `cell` contributes when the row is kept under `key`,
    /// or `false` when the row tests something else and is dropped.
    fn subCells(b: *Builder, cell: Cell, key: Head, out: []Cell) bool {
        const head = b.headOf(cell);
        if (head == .wild) {
            @memset(out, .{});
            return true;
        }
        if (!sameHead(b.cx.bir, head, key)) return false;
        @memset(out, .{});
        const pat = unwrapAs(b.cx.bir, cell.pat.unwrap().?);
        const bir = b.cx.bir;
        const d = bir.instData(pat);
        switch (bir.instTag(pat)) {
            .pat_ctor => {
                const args = bir.extraSlice(bir.subRange(@enumFromInt(d.rhs)), Inst.Index);
                for (args, 0..) |arg, i| {
                    if (i < out.len) out[i] = .{ .pat = arg.toOptional() };
                }
            },
            .pat_tuple => {
                for (bir.extraSlice(Bir.inlineRange(d), Inst.Index), 0..) |element, i| {
                    if (i < out.len) out[i] = .{ .pat = element.toOptional() };
                }
            },
            .pat_list => {
                // `[ a, b, c ]` from element `from` on is `a :: <the rest>`,
                // and the rest is this same instruction one element along.
                const elements = bir.extraSlice(Bir.inlineRange(d), Inst.Index);
                if (out.len == 2 and cell.from < elements.len) {
                    out[0] = .{ .pat = elements[cell.from].toOptional() };
                    out[1] = .{ .pat = pat.toOptional(), .from = cell.from + 1 };
                }
            },
            // `()` and a literal have no arguments.
            else => {},
        }
        return true;
    }
};

fn sameHead(bir: *const Bir, x: Head, y: Head) bool {
    return switch (x) {
        .wild => false,
        .ctor => |a| y == .ctor and y.ctor.order == a.order,
        // One constructor, so two heads of one column are always it.
        .tuple, .unit => y == .tuple or y == .unit,
        .list => |cons| y == .list and y.list == cons,
        .literal => |a| y == .literal and a.kind == y.literal.kind and
            sameLiteral(bir, a.pat, y.literal.pat),
    };
}

/// Two literal patterns spell the same value. By the SPELLING for an
/// `Int`, where `Exhaustive.zig` compares by value: two spellings of one
/// number are then two edges of the fan, the first of which wins at run
/// time — which is the row the source put first, so the answer is the
/// same and the cost is one dead `case` label on input nobody writes.
fn sameLiteral(bir: *const Bir, x: Inst.Index, y: Inst.Index) bool {
    return switch (bir.instTag(x)) {
        .pat_char => bir.instData(x).lhs == bir.instData(y).lhs,
        .pat_int, .pat_string => std.mem.eql(u8, bir.bytes(x), bir.bytes(y)),
        else => false,
    };
}

/// The index of a `pat_list`'s spread item, or null when it has none.
fn spreadIndex(bir: *const Bir, pat: Inst.Index) ?u32 {
    for (bir.extraSlice(Bir.inlineRange(bir.instData(pat)), Inst.Index), 0..) |el, i| {
        if (bir.instTag(el) == .pat_spread) return @intCast(i);
    }
    return null;
}

fn unwrapAs(bir: *const Bir, pat: Inst.Index) Inst.Index {
    var at = pat;
    while (at.int() < bir.insts.len and bir.instTag(at) == .pat_as) {
        at = @enumFromInt(bir.instData(at).lhs);
    }
    return at;
}

fn arityOf(key: Head) u32 {
    return switch (key) {
        .wild, .unit => 0,
        .ctor => |c| c.arity,
        .tuple => |arity| arity,
        .list => |cons| if (cons) 2 else 0,
        .literal => 0,
    };
}

fn orderOf(key: Head) u32 {
    return switch (key) {
        .ctor => |c| c.order,
        .list => |cons| @intFromBool(cons),
        else => 0,
    };
}

fn kindOf(key: Head) Kind {
    return switch (key) {
        .ctor => .ctor,
        .list => .list,
        .literal => |lit| lit.kind,
        // Neither reaches a fan: both are expanded away above.
        .wild, .tuple, .unit => .ctor,
    };
}

/// Constructors in the declaring type's declaration order, `[]` before `::`:
/// `order` is a permutation of `keys`' indices, sorted by it. A literal
/// keeps the order the rows spell it in, which is the only input-derived
/// order there is — a literal column has no declaration.
///
/// A stable sort (`std.mem.sort` is block sort) keeps equal keys in row
/// order; a fan has as many alternatives as the type has constructors, and
/// the insertion sort this was before is quadratic in them.
fn sortKeys(keys: []const Head, order: []u32) void {
    if (keys.len == 0 or keys[0] == .literal) return;
    std.mem.sort(u32, order, keys, struct {
        fn lessThan(k: []const Head, a: u32, b: u32) bool {
            return orderOf(k[a]) < orderOf(k[b]);
        }
    }.lessThan);
}
