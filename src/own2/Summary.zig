//! L7: classes and summaries (`docs/design/ownership-v2.md` §2.10, §3.5). A
//! class describes a function type's behaviour over `π₁…πₙ`, `ρ`; a summary
//! is a declaration's class. A class names no declaration (#587's room).
//!
//! `use(i)` is a shape over πᵢ's places whose cells are `mark`s (`R A E W
//! S D`, `W{f}`): a `node` of marks labels its own path (with `D`, a read,
//! every path below too), a LEAF every path below it (a deep read or
//! write), so §2.7's "`U` non-empty at the remainder" is one `cellsAt` or
//! a `D` on the way. `res` is a shape over ρ's places; `kappas`
//! is THE CLASS'S OWN κ snapshot over it (nodes are interned, so κ is the
//! holder's, never the node's, §3.4); `xreq` the flat atom set relied on;
//! `fun(j)` has `calls`, `need`, `seen`, supplies keyed by LABEL and `k`
//! (two labels never merge, §2.2), each with the handed value's snapshot,
//! keep edges and write-backs (`Back`, §2.13.6), the runs sorted; `j ≥ params` names a function slot.
//!
//! **Lattice** (§2.10): pointwise and FUNCTIONAL — `join` builds a new class
//! with a new snapshot (`Cond.propagate`, O15) and never writes a member's;
//! `leq` is `Cond.kappaLeq`'s simulation over node pairs. **Normal form**
//! (§3.5): words by one canonical DFS with backreferences, every sorted run
//! (sets, atoms, supplies, keeps) spelled for the sort in a context of its
//! own so storage order never reaches the words. The words hold this
//! module's place ids and a union's sides in node-id order: deterministic
//! within one build, fit for the fixpoint and the tests, NEVER hashed or
//! published before `Block` (S6) — the gate keeps `normalize` out of every
//! other file. `print` is v1's `summary` grammar (oc §16.11). Every record
//! is reserved on the caller's `Charge` before it exists (§4.1).
//!
//! Obligations kept here: O5's lattice half (a join covers both classes),
//! O15 (κ of a joined `res` is the join of the members' at every path).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Place = @import("Place.zig");
const Cell = @import("Cell.zig");
const Shape = @import("Shape.zig");
const Cond = @import("Cond.zig");
const stamped = @import("../stamped.zig");

pub const ClassId = Ids.ClassId;
pub const NodeId = Ids.NodeId;
pub const CellId = Ids.CellId;
pub const SetId = Ids.SetId;
pub const CondId = Ids.CondId;
pub const PathId = Ids.PathId;
pub const PlaceId = Ids.PlaceId;
pub const LabelId = Ids.LabelId;
pub const Step = Place.Step;
pub const Charge = Ids.Charge;
pub const Error = Ids.ChargeError;
pub const Supply = Facts.Supply;
pub const Keep = Facts.Keep;
pub const Kappas = Cond.Kappas;

pub const Calls = enum(u2) {
    zero,
    once,
    many,

    pub fn join(a: Calls, b: Calls) Calls {
        return @fromBackingInt(@max(@backingInt(a), @backingInt(b)));
    }
};

/// Where a class came from (oc §16.11's `(words)`/`(asserted)`).
pub const Origin = enum(u8) { inferred, words, asserted, unknown };

/// `fun(j)` (§2.10): how often function parameter `j` is called, whether
/// its result is written (`need`), whether every call of it is in sight
/// (`seen`), what it is handed and what it keeps. Both runs are sorted.
pub const Fun = struct {
    j: u32,
    calls: Calls,
    need: bool,
    seen: bool,
    supplies: Ids.Range,
    keeps: Ids.Range,
    /// Its write-backs (`Back`), a sorted run of `backs`.
    backs: Ids.Range,
};

/// A selected callback-result write-back (§2.13.6, *Write-back is a summary
/// effect*): when fun `j` is called, the path `selected` of its answer is
/// put back at `dest` of parameter `dest_param` — a sequence's or a dict's
/// element position `[*]` (`element`) or a cell's `◆` (`cell`). `removes`:
/// the answer is a Maybe-like carrier whose nullary alternative stores
/// nothing and removes the taken position. A flat record, not a `need`
/// on the whole answer, which could not say which part is stored.
pub const Back = struct {
    selected: PathId,
    dest: PathId,
    dest_param: u32,
    mode: BackMode,
    removes: bool = false,
};

pub const BackMode = enum(u8) { element, cell };

/// A function slot (oc §24.9): a function at `path` of parameter `param`,
/// named as `fun(params + k)`.
pub const Slot = struct { param: u32, path: PathId };

pub const Class = struct {
    /// Per parameter its use shape: a run of `uses`.
    params: Ids.Range,
    res: NodeId,
    kappas: Kappas,
    xreq: SetId,
    funs: Ids.Range,
    slots: Ids.Range,
    classes: Ids.Range,
    /// The function-typed result places the class makes once closures at
    /// (§2.10): a run of `onces`, sorted.
    once: Ids.Range,
    refs: SetId,
    /// `⊤call`'s `refs` is top: every slot may be touched (§2.11).
    refs_top: bool,
    writes: bool,
    entry: bool,
    origin: Origin,
    account: Ids.SummaryAccountId,
};

/// The use marks at one path, as read back from a use shape.
pub const Marks = packed struct(u8) {
    r: bool = false,
    a: bool = false,
    e: bool = false,
    w: bool = false,
    deep: bool = false,
    deep_read: bool = false, // `D` (§2.10): read below too; `w` stays shallow
    _pad: u2 = 0,

    pub fn isEmpty(m: Marks) bool {
        return @as(u8, @bitCast(m)) == 0;
    }
};

/// The tables a class is built over, passed down and never stored (§5).
pub const Env = struct {
    gpa: Allocator,
    charge: Charge,
    places: *Place.Table,
    cells: *Cell.Table,
    shapes: *Shape.Table,
    conds: *Cond.Table,

    pub fn account(e: Env) *Ids.Account {
        return e.charge.account;
    }

    pub fn view(e: Env) Cond.View {
        return .{ .shapes = e.shapes, .cells = e.cells, .places = e.places };
    }

    /// κ of a `res` node under a class's map, at a plain path.
    pub fn kappa(e: Env, ctx: Kappas, n: NodeId) Error!CondId {
        return e.conds.kappaOf(e.gpa, e.charge, e.view(), ctx, n, false);
    }
};

/// How names print (§3.8: never an id): a field by its text rank, a
/// constructor by `(constructor, argument)`, a top-level value by
/// `(module, declaration)`.
pub const Names = struct {
    ctx: *anyopaque,
    field: *const fn (ctx: *anyopaque, rank: u32) []const u8,
    ctor: *const fn (ctx: *anyopaque, head: u32, ordinal: u32) []const u8, // type `head`'s `ordinal`th
    decl: *const fn (ctx: *anyopaque, module: u32, decl: u32) []const u8,
};

/// What `add` takes: a class in pieces.
pub const Draft = struct {
    params: []const NodeId,
    res: NodeId,
    kappas: Kappas = .none,
    xreq: SetId = .none,
    funs: []const DraftFun = &.{},
    slots: []const Slot = &.{},
    classes: []const ClassId = &.{},
    once: []const PathId = &.{},
    refs: SetId = .none,
    refs_top: bool = false,
    writes: bool = false,
    entry: bool = false,
    origin: Origin = .inferred,
    account: Ids.SummaryAccountId = .none,
};

pub const DraftFun = struct {
    j: u32,
    calls: Calls,
    need: bool = false,
    seen: bool = true,
    supplies: []const Supply = &.{},
    keeps: []const Keep = &.{},
    backs: []const Back = &.{},
};

/// The order of a fun's supplies: by label, argument, node, `taken`.
fn supplyLess(_: void, a: Supply, b: Supply) bool {
    if (a.label != b.label) return a.label.int() < b.label.int();
    if (a.k != b.k) return a.k < b.k;
    if (a.node != b.node) return a.node.int() < b.node.int();
    return @intFromBool(a.taken) < @intFromBool(b.taken);
}

fn supplySame(a: Supply, b: Supply) bool {
    return a.label == b.label and a.k == b.k and a.node == b.node and a.taken == b.taken;
}

fn keepLess(_: void, a: Keep, b: Keep) bool {
    if (a.j != b.j) return a.j < b.j;
    if (a.k != b.k) return a.k < b.k;
    if (a.kept_path != b.kept_path) return a.kept_path.int() < b.kept_path.int();
    if (a.written_path != b.written_path) return a.written_path.int() < b.written_path.int();
    return a.writer < b.writer;
}

fn keepSame(a: Keep, b: Keep) bool {
    return a.j == b.j and a.k == b.k and a.kept_path == b.kept_path and a.written_path == b.written_path and a.writer == b.writer;
}

/// The order of a fun's write-backs: by destination, mode, removal, then
/// the selected path.
fn backLess(_: void, a: Back, b: Back) bool {
    if (a.dest_param != b.dest_param) return a.dest_param < b.dest_param;
    if (a.dest != b.dest) return a.dest.int() < b.dest.int();
    if (a.mode != b.mode) return @backingInt(a.mode) < @backingInt(b.mode);
    if (a.removes != b.removes) return !a.removes;
    return a.selected.int() < b.selected.int();
}

fn backSame(a: Back, b: Back) bool {
    return a.dest_param == b.dest_param and a.dest == b.dest and a.mode == b.mode and a.removes == b.removes and a.selected == b.selected;
}

fn pathLess(_: void, a: PathId, b: PathId) bool {
    return a.int() < b.int();
}

fn pathOrder(a: PathId, b: PathId) std.math.Order {
    return std.math.order(a.int(), b.int());
}

/// Two use shapes of one place merged path by path: the marks of both at every
/// path, a leaf standing for everything below it. `Shape.join` makes a `union`
/// of two nodes, and a read-off of a use (`Calls.marked`) does not go into a
/// union, so the writes below it would not be found.
pub const UseMerge = struct {
    env: Env,
    memo: Ids.FixedDict(2) = .{},

    pub fn deinit(m: *UseMerge) void {
        m.memo.deinit(m.env.gpa);
    }

    pub fn merge(m: *UseMerge, a: NodeId, b: NodeId) Error!NodeId {
        const env = m.env;
        const gpa = env.gpa;
        if (a == b or b == .none) return a;
        if (a == .none) return b;
        try env.charge.reserve(gpa, .shape, 1);
        if (m.memo.get(.{ a.int(), b.int() })) |hit| return .from(hit);
        const shapes = env.shapes;
        const at = shapes.place(a);
        const ca = try shapes.cellsOf(gpa, env.account(), &env.cells.sets, a);
        const cb = try shapes.cellsOf(gpa, env.account(), &env.cells.sets, b);
        const cells = try env.cells.sets.unionWith(gpa, env.charge, ca, cb);
        const ka = shapes.kind(a);
        const kb = shapes.kind(b);
        const out: NodeId = out: {
            if (ka == .node and kb == .node and shapes.place(b) == at) {
                var children: u32 = Ids.none_int;
                var it = shapes.overEntries(shapes.get(a).a);
                while (it.next()) |e| {
                    const other = if (shapes.overGet(shapes.get(b).a, e.step)) |o| o else NodeId.none;
                    children = try shapes.overPut(gpa, env.account(), children, e.step, try m.merge(e.node, other));
                }
                var jt = shapes.overEntries(shapes.get(b).a);
                while (jt.next()) |e| if (shapes.overGet(shapes.get(a).a, e.step) == null) {
                    children = try shapes.overPut(gpa, env.account(), children, e.step, e.node);
                };
                break :out try shapes.node(gpa, env.account(), at, cells, children);
            }
            // A leaf stands for everything below it, and so does the merge of
            // anything else: what both reach, deeply.
            const ra = try shapes.reach(gpa, env.account(), &env.cells.sets, a);
            const rb = try shapes.reach(gpa, env.account(), &env.cells.sets, b);
            const deep = try Table.marksSet(env, .{ .deep = true }, &.{});
            break :out try shapes.leaf(gpa, env.account(), at, try env.cells.sets.unionWith(gpa, env.charge, try env.cells.sets.unionWith(gpa, env.charge, ra, rb), deep));
        };
        (try m.memo.getOrPut(gpa, .{ a.int(), b.int() })).value_ptr.* = out.int();
        return out;
    }
};
pub const Table = struct {
    classes: std.MultiArrayList(Class) = .empty,
    uses: std.ArrayList(NodeId) = .empty,
    funs: std.MultiArrayList(Fun) = .empty,
    supplies: std.MultiArrayList(Supply) = .empty,
    keeps: std.MultiArrayList(Keep) = .empty,
    slots: std.MultiArrayList(Slot) = .empty,
    nested: std.ArrayList(ClassId) = .empty,
    onces: std.ArrayList(PathId) = .empty,
    backs: std.MultiArrayList(Back) = .empty,
    /// The classes whose fold certificates the induction proved (§8 slice
    /// 4, *The fold certificate, specified*, #1485): a settled recursive
    /// group's classes, each folded class of its `res` certified at its key
    /// with its cells there as the arrival keys and its κ there as the
    /// condition. A view of one is a hypothesis node for every reader.
    certs: std.ArrayList(bool) = .empty,

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.certs.deinit(gpa);
        t.classes.deinit(gpa);
        t.uses.deinit(gpa);
        t.funs.deinit(gpa);
        t.supplies.deinit(gpa);
        t.keeps.deinit(gpa);
        t.slots.deinit(gpa);
        t.nested.deinit(gpa);
        t.onces.deinit(gpa);
        t.backs.deinit(gpa);
    }

    pub fn certified(t: *const Table, c: ClassId) bool {
        return c != .none and c.int() < t.certs.items.len and t.certs.items[c.int()];
    }

    pub fn certify(t: *Table, gpa: Allocator, c: ClassId) Allocator.Error!void {
        if (t.certs.items.len <= c.int()) try t.certs.appendNTimes(gpa, false, c.int() + 1 - t.certs.items.len);
        t.certs.items[c.int()] = true;
    }

    pub fn count(t: *const Table) u32 {
        return @intCast(t.classes.len);
    }

    pub fn get(t: *const Table, c: ClassId) Class {
        return t.classes.get(c.int());
    }

    pub fn paramUses(t: *const Table, c: ClassId) []const NodeId {
        const r = t.classes.items(.params)[c.int()];
        return t.uses.items[r.start..][0..r.len];
    }

    /// The `k`th fun of class `c`.
    pub fn fun(t: *const Table, c: ClassId, k: u32) Fun {
        const r = t.classes.items(.funs)[c.int()];
        std.debug.assert(k < r.len);
        return t.funs.get(r.start + k);
    }

    pub fn funCount(t: *const Table, c: ClassId) u32 {
        return t.classes.items(.funs)[c.int()].len;
    }

    pub fn supply(t: *const Table, f: Fun, k: u32) Supply {
        std.debug.assert(k < f.supplies.len);
        return t.supplies.get(f.supplies.start + k);
    }

    pub fn keepOf(t: *const Table, f: Fun, k: u32) Keep {
        std.debug.assert(k < f.keeps.len);
        return t.keeps.get(f.keeps.start + k);
    }

    pub fn backOf(t: *const Table, f: Fun, k: u32) Back {
        std.debug.assert(k < f.backs.len);
        return t.backs.get(f.backs.start + k);
    }

    pub fn slot(t: *const Table, c: ClassId, k: u32) Slot {
        const r = t.classes.items(.slots)[c.int()];
        std.debug.assert(k < r.len);
        return t.slots.get(r.start + k);
    }

    pub fn nestedOf(t: *const Table, c: ClassId) []const ClassId {
        const r = t.classes.items(.classes)[c.int()];
        return t.nested.items[r.start..][0..r.len];
    }

    pub fn oncesOf(t: *const Table, c: ClassId) []const PathId {
        const r = t.classes.items(.once)[c.int()];
        return t.onces.items[r.start..][0..r.len];
    }

    // ---- building -------------------------------------------------------------

    /// A class from its pieces: one record each for the class, every use
    /// node, fun, supply, keep, slot, nested class and once path, reserved
    /// before anything is appended. Funs are stored sorted by `j`, their
    /// supplies and keeps sorted by their keys, the once paths by id.
    pub fn add(t: *Table, env: Env, d: Draft) Error!ClassId {
        // A class is stored forced: no view in its `res`, its use shapes or
        // the nodes its κ is stored under, so a template, a block and a
        // printer never meet one (§2.11).
        if (std.debug.runtime_safety) {
            std.debug.assert(!try env.shapes.holdsView(env.gpa, d.res));
            for (d.params) |u| std.debug.assert(!try env.shapes.holdsView(env.gpa, u));
            std.debug.assert(!try env.conds.kappaHoldsView(env.gpa, env.shapes, d.kappas));
            // And resolved: a published κ holds no `inst` atom (§2.11, part 3).
            std.debug.assert(!try env.conds.kappaHoldsInst(env.gpa, d.kappas));
        }
        var n: u32 = 1 + @as(u32, @intCast(d.params.len + d.funs.len + d.slots.len + d.classes.len + d.once.len));
        for (d.funs) |f| n += @intCast(f.supplies.len + f.keeps.len + f.backs.len);
        try env.charge.reserve(env.gpa, .class, n);
        const gpa = env.gpa;
        const params: Ids.Range = .{ .start = @intCast(t.uses.items.len), .len = @intCast(d.params.len) };
        try t.uses.appendSlice(gpa, d.params);
        var order: std.ArrayList(u32) = .empty;
        defer order.deinit(gpa);
        for (0..d.funs.len) |i| try order.append(gpa, @intCast(i));
        std.mem.sort(u32, order.items, d.funs, struct {
            fn lessThan(fs: []const DraftFun, x: u32, y: u32) bool {
                return fs[x].j < fs[y].j;
            }
        }.lessThan);
        const funs: Ids.Range = .{ .start = @intCast(t.funs.len), .len = @intCast(d.funs.len) };
        for (order.items) |i| {
            const f = d.funs[i];
            const sr: Ids.Range = .{ .start = @intCast(t.supplies.len), .len = @intCast(f.supplies.len) };
            for (f.supplies) |s| try t.supplies.append(gpa, s);
            try sortRun(Supply, gpa, &t.supplies, sr, supplyLess);
            const kr: Ids.Range = .{ .start = @intCast(t.keeps.len), .len = @intCast(f.keeps.len) };
            for (f.keeps) |k| try t.keeps.append(gpa, k);
            try sortRun(Keep, gpa, &t.keeps, kr, keepLess);
            const br: Ids.Range = .{ .start = @intCast(t.backs.len), .len = @intCast(f.backs.len) };
            for (f.backs) |b| try t.backs.append(gpa, b);
            try sortRun(Back, gpa, &t.backs, br, backLess);
            try t.funs.append(gpa, .{ .j = f.j, .calls = f.calls, .need = f.need, .seen = f.seen, .supplies = sr, .keeps = kr, .backs = br });
        }
        const slots: Ids.Range = .{ .start = @intCast(t.slots.len), .len = @intCast(d.slots.len) };
        for (d.slots) |s| try t.slots.append(gpa, s);
        const classes: Ids.Range = .{ .start = @intCast(t.nested.items.len), .len = @intCast(d.classes.len) };
        try t.nested.appendSlice(gpa, d.classes);
        const once: Ids.Range = .{ .start = @intCast(t.onces.items.len), .len = @intCast(d.once.len) };
        try t.onces.appendSlice(gpa, d.once);
        std.mem.sort(PathId, t.onces.items[once.start..], {}, pathLess);
        const id: ClassId = .from(t.count());
        try t.classes.append(gpa, .{
            .params = params,
            .res = d.res,
            .kappas = d.kappas,
            .xreq = d.xreq,
            .funs = funs,
            .slots = slots,
            .classes = classes,
            .once = once,
            .refs = d.refs,
            .refs_top = d.refs_top,
            .writes = d.writes,
            .entry = d.entry,
            .origin = d.origin,
            .account = d.account,
        });
        return id;
    }

    /// Sort a run of a table in place, through a scratch copy of the run.
    fn sortRun(comptime T: type, gpa: Allocator, list: anytype, r: Ids.Range, comptime lessFn: anytype) Allocator.Error!void {
        if (r.len < 2) return;
        const buf = try gpa.alloc(T, r.len);
        defer gpa.free(buf);
        for (buf, 0..) |*b, i| b.* = list.get(r.start + i);
        std.mem.sort(T, buf, {}, lessFn);
        for (buf, 0..) |b, i| list.set(r.start + i, b);
    }

    /// `⊤call` (§2.11, R-5.5.4): every parameter `RAEW` deep, the result
    /// `⊤` with κ `lost`, every function parameter in `fun_params` called
    /// many times, unseen, its result needed and put back anywhere; `refs`
    /// top; writes. It is the top of `leq`.
    pub fn unknown(t: *Table, env: Env, param_places: []const PlaceId, fun_params: []const u32, res_place: PlaceId) Error!ClassId {
        const gpa = env.gpa;
        var params: std.ArrayList(NodeId) = .empty;
        defer params.deinit(gpa);
        const all = try marksSet(env, .{ .r = true, .a = true, .e = true, .w = true, .deep = true }, &.{});
        for (param_places) |p| try params.append(gpa, try env.shapes.leaf(gpa, env.account(), p, all));
        const top = try env.cells.top(gpa, env.account());
        const res = try env.shapes.leaf(gpa, env.account(), res_place, try env.cells.sets.insert(gpa, env.charge, .none, top.int(), 0));
        const kappas = (try env.conds.kappaSet(gpa, env.charge, .none, res, Cond.lost)).ctx;
        var funs: std.ArrayList(DraftFun) = .empty;
        defer funs.deinit(gpa);
        for (fun_params) |j| try funs.append(gpa, .{ .j = j, .calls = .many, .need = true, .seen = false });
        return t.add(env, .{ .params = params.items, .res = res, .kappas = kappas, .funs = funs.items, .refs_top = true, .writes = true, .origin = .unknown });
    }

    // ---- use shapes ---------------------------------------------------------------

    /// The set of mark cells for `m` and the written fields' ranks.
    pub fn marksSet(env: Env, m: Marks, fields: []const u32) Error!SetId {
        var s: SetId = .none;
        inline for (.{ .{ m.r, Cell.Mark.r }, .{ m.a, Cell.Mark.a }, .{ m.e, Cell.Mark.e }, .{ m.w, Cell.Mark.w }, .{ m.deep, Cell.Mark.deep }, .{ m.deep_read, Cell.Mark.deep_read } }) |pair| {
            if (pair[0]) s = try env.cells.sets.insert(env.gpa, env.charge, s, (try env.cells.mark(env.gpa, env.account(), pair[1], 0)).int(), 0);
        }
        for (fields) |rank| s = try env.cells.sets.insert(env.gpa, env.charge, s, (try env.cells.mark(env.gpa, env.account(), .field, rank)).int(), 0);
        return s;
    }

    /// `use` (a use shape at `place`, or `.none` for no use yet) with the
    /// marks `m` and written fields added at the path `steps`: a path copy
    /// of the node chain, O(depth · log F). A deep mark makes the path's
    /// node a leaf, which stands for everything below it; marks added
    /// under a deep leaf join that leaf (a stronger claim, never a weaker
    /// one). Returns the new use shape.
    pub fn markUse(env: Env, use: NodeId, place: PlaceId, steps: []const Step, m: Marks, fields: []const u32) Error!NodeId {
        const marks = try marksSet(env, m, fields);
        return markAt(env, use, place, steps, marks, m.deep);
    }

    fn markAt(env: Env, root: NodeId, root_place: PlaceId, steps: []const Step, marks: SetId, deep: bool) Error!NodeId {
        const gpa = env.gpa;
        // Down the path, then back up rebuilding each level, on explicit
        // lists (#1138: a path is as long as the source is deep). The
        // records as the recursion reserved them, one shape per level.
        const Level = struct { n: NodeId, place: PlaceId, here: SetId };
        var way: std.ArrayList(Level) = .empty;
        defer way.deinit(gpa);
        var n = root;
        var place = root_place;
        var i: usize = 0;
        var out: NodeId = while (true) : (i += 1) {
            try env.charge.reserve(gpa, .shape, 1);
            const here: SetId = if (n == .none) .none else try env.shapes.cellsOf(env.gpa, env.account(), &env.cells.sets, n);
            if (n != .none and env.shapes.kind(n) == .leaf and here != .none) {
                break try env.shapes.leaf(gpa, env.account(), place, try env.cells.sets.unionWith(gpa, env.charge, here, marks));
            }
            if (i == steps.len) {
                const c = try env.cells.sets.unionWith(gpa, env.charge, here, marks);
                if (deep) break try env.shapes.leaf(gpa, env.account(), place, c);
                if (n == .none or env.shapes.kind(n) == .leaf) break try env.shapes.node(gpa, env.account(), place, c, Ids.none_int);
                break try env.shapes.withCells(gpa, env.account(), env.places, env.cells, n, c);
            }
            try way.append(gpa, .{ .n = n, .place = place, .here = here });
            const s = steps[i];
            const child_place = env.places.child(place, s) orelse unreachable;
            var child: NodeId = .none;
            if (n != .none and env.shapes.kind(n) == .node) {
                if (env.shapes.overGet(env.shapes.get(n).a, s)) |c| child = c;
            }
            n = child;
            place = child_place;
        };
        while (way.pop()) |lv| {
            i -= 1;
            const children: u32 = if (lv.n != .none and env.shapes.kind(lv.n) == .node) env.shapes.get(lv.n).a else Ids.none_int;
            out = try env.shapes.node(gpa, env.account(), lv.place, lv.here, try env.shapes.overPut(gpa, env.account(), children, steps[i], out));
        }
        return out;
    }

    /// The marks at `steps` of a use shape (a leaf's hold below it), and `R D`
    /// past a `D` on the way (§2.10); empty when unused. A record per step.
    pub fn marksAt(env: Env, use: NodeId, steps: []const Step) Error!Marks {
        var at = use;
        var m: Marks = .{};
        if (at == .none) return m;
        for (steps) |s| {
            try env.charge.reserve(env.gpa, .inspection, 1);
            if (try deepRead(env, at)) m = .{ .r = true, .deep_read = true };
            at = (try env.shapes.proj(env.gpa, env.account(), env.places, env.cells, at, s)) orelse return m;
        }
        var it = env.cells.sets.iterate(try env.shapes.cellsOf(env.gpa, env.account(), &env.cells.sets, at));
        while (it.next()) |e| {
            const c: CellId = .from(e.key);
            if (env.cells.origin(c) != .mark) continue;
            switch (env.cells.markOf(c)) {
                .r => m.r = true,
                .a => m.a = true,
                .e => m.e = true,
                .w => m.w = true,
                .deep => m.deep = true,
                .deep_read => m.deep_read = true,
                .field => {},
            }
        }
        return m;
    }

    /// Whether a callee's use shape names anything at or below `steps`
    /// (§2.7's lazy `call` use): `cellsAt` non-empty, or a `D` on the way.
    pub fn usedAt(env: Env, use: NodeId, steps: []const Step) Error!bool {
        if (use == .none) return false;
        if (env.cells.mark_d != .none and (try marksAt(env, use, steps)).deep_read) return true;
        return (try env.shapes.cellsAt(env.gpa, env.account(), env.places, env.cells, use, steps)) != .none;
    }

    /// Whether a use shape's node is marked `D` (§2.10).
    pub fn deepRead(env: Env, n: NodeId) Error!bool {
        if (env.cells.mark_d == .none) return false;
        return env.cells.hasDeepRead(try env.shapes.cellsOf(env.gpa, env.account(), &env.cells.sets, n));
    }

    // ---- the lattice -------------------------------------------------------------

    /// The pointwise join of two classes over one signature (§2.10): use
    /// and `res` shapes by `Shape.join` then `widen`, κ by `Cond.propagate`
    /// into the NEW class's map (the members' maps are read, never written),
    /// xreq by union, funs by `j` (calls max, need or, seen and; supplies
    /// merged by `(label, k, node, taken)` with `owned` and-ed and κ joined,
    /// keeps and once paths merged), nested classes pointwise, bits or-ed.
    /// Sorted runs merge in one pass; every record visited is charged.
    /// `mode` (§2.3): `choice` for one value's alternatives, `union` for coexisting invocations.
    pub fn join(t: *Table, env: Env, a: ClassId, b: ClassId, mode: Shape.Kind) Error!ClassId {
        if (a == b) return a;
        const gpa = env.gpa;
        const ca = t.get(a);
        const cb = t.get(b);
        std.debug.assert(ca.params.len == cb.params.len and ca.slots.len == cb.slots.len);
        try env.charge.reserve(gpa, .class, 1);
        var params: std.ArrayList(NodeId) = .empty;
        defer params.deinit(gpa);
        for (t.paramUses(a), t.paramUses(b)) |ua, ub| try params.append(gpa, try joinUse(env, ua, ub));
        const joined = try joinClassRes(env, ca.res, ca.kappas, cb.res, cb.kappas, mode);
        const xreq = try env.conds.atoms.unionWith(gpa, env.charge, ca.xreq, cb.xreq);
        var funs: std.ArrayList(DraftFun) = .empty;
        defer funs.deinit(gpa);
        var sup_store: std.ArrayList(Supply) = .empty;
        defer sup_store.deinit(gpa);
        var keep_store: std.ArrayList(Keep) = .empty;
        defer keep_store.deinit(gpa);
        var back_store: std.ArrayList(Back) = .empty;
        defer back_store.deinit(gpa);
        const Merged = struct { f: DraftFun, sup: Ids.Range, keep: Ids.Range, back: Ids.Range };
        var merged: std.ArrayList(Merged) = .empty;
        defer merged.deinit(gpa);
        var i: u32 = 0;
        var j: u32 = 0;
        while (i < ca.funs.len or j < cb.funs.len) {
            try env.charge.reserve(gpa, .class, 1);
            const fa: ?Fun = if (i < ca.funs.len) t.fun(a, i) else null;
            const fb: ?Fun = if (j < cb.funs.len) t.fun(b, j) else null;
            const sup_start: u32 = @intCast(sup_store.items.len);
            const keep_start: u32 = @intCast(keep_store.items.len);
            const back_start: u32 = @intCast(back_store.items.len);
            var f: DraftFun = undefined;
            if (fb == null or (fa != null and fa.?.j < fb.?.j)) {
                f = .{ .j = fa.?.j, .calls = fa.?.calls, .need = fa.?.need, .seen = fa.?.seen };
                try t.mergeFun(env, fa.?, null, &sup_store, &keep_store, &back_store);
                i += 1;
            } else if (fa == null or fb.?.j < fa.?.j) {
                f = .{ .j = fb.?.j, .calls = fb.?.calls, .need = fb.?.need, .seen = fb.?.seen };
                try t.mergeFun(env, fb.?, null, &sup_store, &keep_store, &back_store);
                j += 1;
            } else {
                f = .{ .j = fa.?.j, .calls = fa.?.calls.join(fb.?.calls), .need = fa.?.need or fb.?.need, .seen = fa.?.seen and fb.?.seen };
                try t.mergeFun(env, fa.?, fb.?, &sup_store, &keep_store, &back_store);
                i += 1;
                j += 1;
            }
            try merged.append(gpa, .{ .f = f, .sup = .{ .start = sup_start, .len = @intCast(sup_store.items.len - sup_start) }, .keep = .{ .start = keep_start, .len = @intCast(keep_store.items.len - keep_start) }, .back = .{ .start = back_start, .len = @intCast(back_store.items.len - back_start) } });
        }
        for (merged.items) |m| {
            var f = m.f;
            f.supplies = sup_store.items[m.sup.start..][0..m.sup.len];
            f.keeps = keep_store.items[m.keep.start..][0..m.keep.len];
            f.backs = back_store.items[m.back.start..][0..m.back.len];
            try funs.append(gpa, f);
        }
        var nested: std.ArrayList(ClassId) = .empty;
        defer nested.deinit(gpa);
        const na = t.nestedOf(a);
        const nb = t.nestedOf(b);
        std.debug.assert(na.len == nb.len);
        for (na, nb) |x, y| try nested.append(gpa, try t.join(env, x, y, mode));
        // Once paths: both sorted runs, re-sorted and deduplicated by `add`'s
        // sort (O((|a| + |b|) log) records).
        var once: std.ArrayList(PathId) = .empty;
        defer once.deinit(gpa);
        try env.charge.reserve(gpa, .class, @intCast(ca.once.len + cb.once.len));
        try once.appendSlice(gpa, t.oncesOf(a));
        for (t.oncesOf(b)) |p| if (std.sort.binarySearch(PathId, t.oncesOf(a), p, pathOrder) == null) try once.append(gpa, p);
        var slots: std.ArrayList(Slot) = .empty;
        defer slots.deinit(gpa);
        for (0..ca.slots.len) |k| try slots.append(gpa, t.slot(a, @intCast(k)));
        return t.add(env, .{
            .params = params.items,
            .res = joined.node,
            .kappas = joined.kappas,
            .xreq = xreq,
            .funs = funs.items,
            .slots = slots.items,
            .classes = nested.items,
            .once = once.items,
            .refs = try env.cells.sets.unionWith(gpa, env.charge, ca.refs, cb.refs),
            .refs_top = ca.refs_top or cb.refs_top,
            .writes = ca.writes or cb.writes,
            .entry = ca.entry or cb.entry,
            .origin = if (ca.origin == cb.origin) ca.origin else .inferred,
            .account = ca.account,
        });
    }

    /// `fa`'s supplies and keeps, merged with `fb`'s when given, appended
    /// to the stores: one pass over two sorted runs, one record per entry
    /// read. A supply of one `(label, k, node, taken)` in both joins
    /// (`owned` and-ed, κ joined); two labels never merge.
    fn mergeFun(t: *const Table, env: Env, fa: Fun, fb: ?Fun, sup: *std.ArrayList(Supply), keeps: *std.ArrayList(Keep), backs: *std.ArrayList(Back)) Error!void {
        const gpa = env.gpa;
        var i: u32 = 0;
        var j: u32 = 0;
        const nb: u32 = if (fb) |f| f.supplies.len else 0;
        while (i < fa.supplies.len or j < nb) {
            try env.charge.reserve(gpa, .class, 1);
            const sa: ?Supply = if (i < fa.supplies.len) t.supply(fa, i) else null;
            const sb: ?Supply = if (j < nb) t.supply(fb.?, j) else null;
            if (sb == null or (sa != null and supplyLess({}, sa.?, sb.?))) {
                try sup.append(gpa, sa.?);
                i += 1;
            } else if (sa == null or supplyLess({}, sb.?, sa.?)) {
                try sup.append(gpa, sb.?);
                j += 1;
            } else {
                var s = sa.?;
                s.owned = s.owned and sb.?.owned;
                // The two snapshots of one handed value joined into a new one.
                const merged = try env.conds.kappaMerge(gpa, env.charge, sa.?.kappa, sb.?.kappa);
                const joined = env.conds.propagate(gpa, env.charge, env.view(), merged, s.node, &.{ s.node, s.node }, &.{ sa.?.kappa, sb.?.kappa }, .alternatives, false, null);
                s.kappa = try joined;
                try sup.append(gpa, s);
                i += 1;
                j += 1;
            }
        }
        i = 0;
        j = 0;
        const kb: u32 = if (fb) |f| f.keeps.len else 0;
        while (i < fa.keeps.len or j < kb) {
            try env.charge.reserve(gpa, .class, 1);
            const ka: ?Keep = if (i < fa.keeps.len) t.keepOf(fa, i) else null;
            const kk: ?Keep = if (j < kb) t.keepOf(fb.?, j) else null;
            if (kk == null or (ka != null and keepLess({}, ka.?, kk.?))) {
                try keeps.append(gpa, ka.?);
                i += 1;
            } else if (ka == null or keepLess({}, kk.?, ka.?)) {
                try keeps.append(gpa, kk.?);
                j += 1;
            } else {
                try keeps.append(gpa, ka.?);
                i += 1;
                j += 1;
            }
        }
        // Write-backs: the union of both runs.
        i = 0;
        j = 0;
        const bb: u32 = if (fb) |f| f.backs.len else 0;
        while (i < fa.backs.len or j < bb) {
            try env.charge.reserve(gpa, .class, 1);
            const xa: ?Back = if (i < fa.backs.len) t.backOf(fa, i) else null;
            const xb: ?Back = if (j < bb) t.backOf(fb.?, j) else null;
            if (xb == null or (xa != null and backLess({}, xa.?, xb.?))) {
                try backs.append(gpa, xa.?);
                i += 1;
            } else if (xa == null or backLess({}, xb.?, xa.?)) {
                try backs.append(gpa, xb.?);
                j += 1;
            } else {
                try backs.append(gpa, xa.?);
                i += 1;
                j += 1;
            }
        }
    }

    /// Two use shapes joined path by path (`UseMerge`), never into a
    /// `union`, which `Calls.marked` does not read: `.none` is the empty use.
    pub fn joinUse(env: Env, a: NodeId, b: NodeId) Error!NodeId {
        if (a == b or b == .none) return a;
        if (a == .none) return b;
        var mg: UseMerge = .{ .env = env };
        defer mg.deinit();
        return mg.merge(a, b);
    }

    pub const Joined = struct { node: NodeId, kappas: Kappas };

    /// Two `res` shapes with their maps joined, widened, κ propagated into a
    /// NEW map (O15), the widened node's from the join's. `mode` is the
    /// caller's (§2.3): `choice` for exclusive alternatives (a fixpoint's
    /// rounds of one result, a branch's arms), `union` for a join of several
    /// invocations' results, which coexist.
    pub fn joinRes(env: Env, a: NodeId, ka: Kappas, b: NodeId, kb: Kappas, mode: Shape.Kind) Error!Joined {
        if (a == b and ka == kb) return .{ .node = a, .kappas = ka };
        var members = [_]NodeId{ a, b };
        const j = if (mode == .choice) try env.shapes.joinAlternatives(env.gpa, env.account(), env.places, env.cells, &members) else try env.shapes.join(env.gpa, env.account(), env.places, env.cells, &members);
        // The members' snapshots first, as a branch join merges its arms': each
        // side of the joined DAG keeps its own entries (§2.9 *Keyed where a
        // reader looks*, #1093).
        const both = try env.conds.kappaMerge(env.gpa, env.charge, ka, kb);
        const mj = env.conds.propagate(env.gpa, env.charge, env.view(), both, j, &.{ a, b }, &.{ ka, kb }, .alternatives, false, null);
        const mj_ok = try mj;
        // Each side is a class's `res`, a widened knot whose folded classes
        // owe their own fold conditions: read by their cells, once per class,
        // never as a cycle of the join's source (§8 slice 4, #1485).
        env.conds.hyp_knots.clear();
        defer env.conds.hyp_knots.clear();
        for ([_]NodeId{ a, b }) |m| try env.conds.hyp_knots.put(env.gpa, m, {});
        const w = try env.conds.widenValueOf(env.gpa, env.charge, env.view(), j, mj_ok, &.{ a, b }, &.{ ka, kb });
        return .{ .node = w.node, .kappas = w.kappas };
    }

    /// A class join's `res` and κ (§2.3 *A port keeps no round that its
    /// last round covers*). `b`'s under `a`'s: `a`'s, as they are, since a
    /// group's later rounds often move only `xreq` (#1423). In `choice`
    /// mode also the other way, `b`'s widened; otherwise each arm of a
    /// side's top choice that the other side covers is dropped, `a`'s
    /// first, then `b`'s against what is left of `a`, so one value never
    /// leaves both. Only the class join does this: a shape constructor has
    /// no κ. Every test is a charged `Shape.leq` and `kappaLeq`.
    fn joinClassRes(env: Env, a: NodeId, ka: Kappas, b: NodeId, kb: Kappas, mode: Shape.Kind) Error!Joined {
        if (try resLeq(env, b, kb, a, ka)) return .{ .node = a, .kappas = ka };
        if (mode != .choice) return joinRes(env, a, ka, b, kb, mode);
        if (try resLeq(env, a, ka, b, kb)) return widened(env, b, kb);
        const sa = try dropCovered(env, a, ka, b, kb);
        if (sa.node == .none) return widened(env, b, kb);
        const sb = try dropCovered(env, b, kb, sa.node, sa.kappas);
        if (sb.node == .none) return if (sa.node == a) sa else widened(env, sa.node, sa.kappas);
        return joinRes(env, sa.node, sa.kappas, sb.node, sb.kappas, mode);
    }

    fn resLeq(env: Env, x: NodeId, kx: Kappas, y: NodeId, ky: Kappas) Error!bool {
        return try env.shapes.leq(env.gpa, env.account(), env.places, env.cells, x, y) and
            try env.conds.kappaLeq(env.gpa, env.charge, env.view(), kx, x, ky, y, false);
    }

    fn widened(env: Env, x: NodeId, kx: Kappas) Error!Joined {
        const w = try env.conds.widenValue(env.gpa, env.charge, env.view(), x, kx);
        return .{ .node = w.node, .kappas = w.kappas };
    }

    /// `s` without the arms of its top choice DAG (the nodes its choice
    /// edges reach that open no choice) that `o` covers: `s` itself when
    /// none is, `.none` when all are. The kept arms are a balanced choice
    /// in the order the walk met them. κ home: the entry `ks` stores at a
    /// choice node of the DAG is joined into the entry of each arm below
    /// it, so a read of the kept arms is what it was. A side that is no
    /// choice, or one of whose choice nodes owes a fold condition, is kept whole.
    fn dropCovered(env: Env, s: NodeId, ks: Kappas, o: NodeId, ko: Kappas) Error!Joined {
        const gpa = env.gpa;
        const shapes = env.shapes;
        const whole: Joined = .{ .node = s, .kappas = ks };
        if (!opensChoice(shapes, s) or env.conds.fold_cond.get(s) != null) return whole;
        // The DAG's choice nodes in post-order and its arms in the order met.
        var post: std.ArrayList(NodeId) = .empty;
        defer post.deinit(gpa);
        var arms: std.ArrayList(NodeId) = .empty;
        defer arms.deinit(gpa);
        var seen: Ids.FixedDict(1) = .{};
        defer seen.deinit(gpa);
        const Frame = struct { node: NodeId, expanded: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, .{ .node = s, .expanded = false });
        while (stack.pop()) |f| {
            if (f.expanded) {
                try post.append(gpa, f.node);
                continue;
            }
            if ((try seen.getOrPut(gpa, .{f.node.int()})).found_existing) continue;
            try env.charge.reserve(gpa, .inspection, 1);
            if (!opensChoice(shapes, f.node)) {
                try arms.append(gpa, f.node);
                continue;
            }
            // A choice node's fold condition rides on every read through it
            // (`foldCondOf`); no entry stores it, so a side holding one is
            // kept whole.
            if (env.conds.fold_cond.get(f.node) != null) return whole;
            const d = shapes.get(f.node);
            try stack.appendSlice(gpa, &.{ .{ .node = f.node, .expanded = true }, .{ .node = .from(d.b), .expanded = false }, .{ .node = .from(d.a), .expanded = false } });
        }
        // Each choice node's entry, with what is carried to it, carried to
        // its sides: parents first, in reverse post-order.
        var acc: Ids.FixedDict(1) = .{};
        defer acc.deinit(gpa);
        var i = post.items.len;
        while (i > 0) {
            i -= 1;
            const u = post.items[i];
            try env.charge.reserve(gpa, .inspection, 1);
            const here = env.conds.kappaGet(ks, u);
            const above: ?CondId = if (acc.get(.{u.int()})) |x| .from(x) else null;
            const give = if (here) |h| (if (above) |x| try env.conds.join(gpa, env.charge, x, h) else h) else above orelse continue;
            const d = shapes.get(u);
            for ([_]NodeId{ .from(d.a), .from(d.b) }) |side| {
                const got = try acc.getOrPut(gpa, .{side.int()});
                got.value_ptr.* = (if (got.found_existing) try env.conds.join(gpa, env.charge, .from(got.value_ptr.*), give) else give).int();
            }
        }
        // Each arm's cover test reads the arm as its readers will once the
        // others are dropped: its own κ with the choice's entries carried
        // to it, at the root and below (`DropCarry`). Read under the merged
        // snapshot alone it would skip the join's entry and borrow another
        // arm's certificate (#1459's review).
        var kept: std.ArrayList(NodeId) = .empty;
        defer kept.deinit(gpa);
        for (arms.items) |x| {
            try env.charge.reserve(gpa, .inspection, 1);
            var kx = ks;
            if (acc.get(.{x.int()})) |c| kx = (try env.conds.kappaSet(gpa, env.charge, kx, x, .from(c))).ctx;
            kx = try carryTo(env, kx, post.items, x);
            if (!mutated("cert-drop-any") and !try resLeq(env, x, kx, o, ko)) {
                try kept.append(gpa, x);
            } else if (std.debug.runtime_safety) try assertDropKeeps(env, x, kx, o, ko);
        }
        if (kept.items.len == arms.items.len) return whole;
        if (kept.items.len == 0) return .{ .node = .none, .kappas = .none };
        var k = ks;
        for (kept.items) |x| if (acc.get(.{x.int()})) |c| {
            k = (try env.conds.kappaSet(gpa, env.charge, k, x, .from(c))).ctx;
        };
        const root = try balancedChoice(env, kept.items);
        k = try carryTo(env, k, post.items, root);
        return .{ .node = root, .kappas = k };
    }


    /// C3 (§8 slice 4, *Lemmas*, #1485), `runtime_safety` only: an arm
    /// `x` dropped under `o` keeps every fold certificate below it, read by
    /// a reader the cover test does not share: every exact cell `x` reaches
    /// is one `o` reaches, and `x`'s frontier read (`deep`) is no weaker
    /// than `o`'s. A key's multiplicity is in that read (`lost`), so an arm
    /// `[ x, x ]` is never dropped under `[ x ]`.
    fn assertDropKeeps(env: Env, x: NodeId, kx: Kappas, o: NodeId, ko: Kappas) Error!void {
        const gpa = env.gpa;
        var scratch: Ids.Account = .{ .allowance = std.math.maxInt(u32) };
        defer scratch.deinit(gpa);
        const ch: Ids.Charge = .growth(&scratch);
        const sets = &env.cells.sets;
        const rx = try env.shapes.reach(gpa, &scratch, sets, x);
        const ro = try env.shapes.reach(gpa, &scratch, sets, o);
        var it = sets.iterate(rx);
        while (it.next()) |e| if (e.value == 0 and sets.get(ro, e.key) == null and env.cells.origin(.from(e.key)) != .top)
            std.debug.panic("ownership v2: a dropped arm reaches a cell its cover does not (C3, #1485)", .{});
        const dx = try env.conds.deep(gpa, ch, env.view(), kx, x, false);
        const d_o = try env.conds.deep(gpa, ch, env.view(), ko, o, false);
        if (!try env.conds.leq(gpa, ch, dx, d_o))
            std.debug.panic("ownership v2: a dropped arm reads weaker than its cover (C3, #1485)", .{});
    }
    /// `dropCovered`'s transport: every entry kept where it is, and a joined
    /// DAG's entry also on the kept root's projection.
    const DropCarry = struct {
        env: Env,
        root: NodeId,
        choices: Ids.FixedDict(1) = .{},
        memo: Ids.FixedDict(1) = .{},

        fn deinit(c: *DropCarry) void {
            c.choices.deinit(c.env.gpa);
            c.memo.deinit(c.env.gpa);
        }
        fn node(_: *anyopaque, x: NodeId) Error!?NodeId {
            return x;
        }
        fn cond(_: *anyopaque, _: *Cond.Table, _: Allocator, _: Ids.Charge, k: CondId) Error!CondId {
            return k;
        }
        fn image(ctx: *anyopaque, x: NodeId) Error!?NodeId {
            const c: *DropCarry = @ptrCast(@alignCast(ctx));
            return if (c.choices.get(.{x.int()}) != null) c.root else null;
        }
        fn projected(ctx: *anyopaque, x: NodeId) Error!?NodeId {
            const c: *DropCarry = @ptrCast(@alignCast(ctx));
            const e = c.env;
            return Cond.projectedImage(e.shapes, e.gpa, e.account(), e.places, e.cells, x, &c.memo, ctx, image, true);
        }
    };

    /// `ks` transported through the projection correspondence with every
    /// choice node in `choices` mapped to `root`: each entry kept where it
    /// is, and each joined DAG's entry also on `proj(root, q)`. Below the
    /// root, the join's entry is keyed on `proj(choice, q)`, which `root`'s
    /// readers never meet; so they read it there, as the choice's did, never
    /// a certificate merged in from another arm alone (§2.9 *A covered arm's
    /// drop keeps the join below the root*, #1459's review).
    fn carryTo(env: Env, ks: Kappas, choices: []const NodeId, root: NodeId) Error!Kappas {
        var carry: DropCarry = .{ .env = env, .root = root };
        defer carry.deinit();
        for (choices) |u| (try carry.choices.getOrPut(env.gpa, .{u.int()})).value_ptr.* = 1;
        return env.conds.kappaRelabel(env.gpa, env.charge, ks, .{ .ctx = &carry, .node = DropCarry.node, .cond = DropCarry.cond, .projected = DropCarry.projected });
    }

    fn opensChoice(shapes: *Shape.Table, n: NodeId) bool {
        return shapes.kind(n) == .choice and shapes.eagerOf(n) == n;
    }

    fn balancedChoice(env: Env, arms: []const NodeId) Error!NodeId {
        if (arms.len == 1) return arms[0];
        const mid = arms.len / 2;
        const l = try balancedChoice(env, arms[0..mid]);
        const r = try balancedChoice(env, arms[mid..]);
        return env.shapes.choice(env.gpa, env.account(), &env.cells.sets, l, r);
    }

    /// `a ⊑ b` pointwise (§2.10): a stronger class below a weaker one.
    pub fn leq(t: *Table, env: Env, a: ClassId, b: ClassId) Error!bool {
        if (a == b) return true;
        const gpa = env.gpa;
        const ca = t.get(a);
        const cb = t.get(b);
        if (ca.params.len != cb.params.len) return false;
        try env.charge.reserve(gpa, .inspection, 1);
        // `⊤call` is the top of the order: whatever another class supplies,
        // keeps or puts back (its write-backs included), `⊤call` may do.
        if (cb.origin == .unknown) return true;
        // A certified class reads its knots by their certificates, where an
        // uncertified one saturates: it is the stronger (§8 slice 4, #1485).
        if (t.certified(b) and !t.certified(a)) return false;
        for (t.paramUses(a), t.paramUses(b)) |ua, ub| if (!try leqUse(env, ua, ub)) return false;
        if (!try env.shapes.leq(gpa, env.account(), env.places, env.cells, ca.res, cb.res)) return false;
        if (!try env.conds.kappaLeq(gpa, env.charge, env.view(), ca.kappas, ca.res, cb.kappas, cb.res, false)) return false;
        if (!try env.conds.atoms.subset(gpa, env.charge, ca.xreq, cb.xreq)) return false;
        // Every fun of `a` under one of `b`; runs sorted, so two pointers.
        var j: u32 = 0;
        for (0..ca.funs.len) |i| {
            const fa = t.fun(a, @intCast(i));
            while (j < cb.funs.len and t.fun(b, j).j < fa.j) j += 1;
            if (j >= cb.funs.len or t.fun(b, j).j != fa.j) return false;
            const fb = t.fun(b, j);
            if (@backingInt(fa.calls) > @backingInt(fb.calls)) return false;
            if (fa.need and !fb.need) return false;
            if (fb.seen and !fa.seen) return false;
            var m: u32 = 0;
            for (0..fa.supplies.len) |k| {
                try env.charge.reserve(gpa, .inspection, 1);
                const s = t.supply(fa, @intCast(k));
                while (m < fb.supplies.len and supplyLess({}, t.supply(fb, m), s)) m += 1;
                if (m >= fb.supplies.len or !supplySame(t.supply(fb, m), s)) return false;
                const o = t.supply(fb, m);
                if (o.owned and !s.owned) return false;
                if (!try env.conds.kappaLeq(gpa, env.charge, env.view(), s.kappa, s.node, o.kappa, o.node, false)) return false;
            }
            m = 0;
            for (0..fa.keeps.len) |k| {
                try env.charge.reserve(gpa, .inspection, 1);
                const x = t.keepOf(fa, @intCast(k));
                while (m < fb.keeps.len and keepLess({}, t.keepOf(fb, m), x)) m += 1;
                if (m >= fb.keeps.len or !keepSame(t.keepOf(fb, m), x)) return false;
            }
            m = 0;
            for (0..fa.backs.len) |k| {
                try env.charge.reserve(gpa, .inspection, 1);
                const x = t.backOf(fa, @intCast(k));
                while (m < fb.backs.len and backLess({}, t.backOf(fb, m), x)) m += 1;
                if (m >= fb.backs.len or !backSame(t.backOf(fb, m), x)) return false;
            }
        }
        const na = t.nestedOf(a);
        const nb = t.nestedOf(b);
        if (na.len != nb.len) return false;
        for (na, nb) |x, y| if (!try t.leq(env, x, y)) return false;
        var m: usize = 0;
        const ob = t.oncesOf(b);
        for (t.oncesOf(a)) |p| {
            while (m < ob.len and ob[m].int() < p.int()) m += 1;
            if (m >= ob.len or ob[m] != p) return false;
        }
        if (ca.refs_top and !cb.refs_top) return false;
        if (!cb.refs_top and !try env.cells.sets.subset(gpa, env.charge, ca.refs, cb.refs)) return false;
        if (ca.writes and !cb.writes) return false;
        return true;
    }

    fn leqUse(env: Env, a: NodeId, b: NodeId) Error!bool {
        if (a == b or a == .none) return true;
        if (b == .none) return false;
        return env.shapes.leq(env.gpa, env.account(), env.places, env.cells, a, b);
    }

    // ---- normal form --------------------------------------------------------

    /// The class as words (header): one canonical DFS over `res` and the
    /// use shapes, nodes by first-visit ordinal with backreferences, cells
    /// spelled by origin and canonical path, sets and atoms sorted by their
    /// spelling. Appended to `out`; every node and cell visited is a record.
    /// Build-local words (header): never hashed or published.
    pub fn normalize(t: *Table, env: Env, c: ClassId, out: *std.ArrayList(u32)) Error!void {
        var n: Normalizer = .{ .t = t, .env = env, .out = out, .ctx = t.get(c).kappas };
        defer n.deinit();
        try n.class(c);
    }

    /// Equality as `leq` both ways (§2.10, #1094): what every reader observes
    /// of the two classes is the same. A walk over parts (the normal form)
    /// would miss a κ stored past the parts, which `leq` compares along the
    /// observable frontier (§2.9).
    pub fn eq(t: *Table, env: Env, a: ClassId, b: ClassId) Error!bool {
        if (a == b) return true;
        return try t.leq(env, a, b) and try t.leq(env, b, a);
    }

    const Normalizer = struct {
        t: *Table,
        env: Env,
        out: *std.ArrayList(u32),
        ctx: Kappas,
        /// `(node, cursor)` → ordinal: a node's two positions are two (§2.9).
        ordinal: Ids.FixedDict(2) = .{},
        next: u32 = 0,

        const Tag = enum(u32) { class, node_new, node_ref, cell, set, cond, atom, fun, supply, keep, slot, path, label, none, back };

        fn deinit(n: *Normalizer) void {
            n.ordinal.deinit(n.env.gpa);
        }

        fn put(n: *Normalizer, w: u32) Error!void {
            try n.out.append(n.env.gpa, w);
        }

        fn tag(n: *Normalizer, x: Tag) Error!void {
            try n.put(@backingInt(x));
        }

        fn class(n: *Normalizer, c: ClassId) Error!void {
            try n.env.charge.reserve(n.env.gpa, .inspection, 1);
            const k = n.t.get(c);
            const saved_ctx = n.ctx;
            n.ctx = k.kappas;
            defer n.ctx = saved_ctx;
            try n.tag(.class);
            try n.put(k.params.len);
            try n.put(@as(u32, @intFromBool(k.writes)) | (@as(u32, @intFromBool(k.entry)) << 1) | (@as(u32, @intFromBool(k.refs_top)) << 2));
            try n.put(@backingInt(k.origin));
            try n.node(k.res, false, n.ctx);
            // Use shapes carry marks, not value κ (§2.9).
            for (n.t.paramUses(c)) |u| if (u == .none) try n.tag(.none) else try n.node(u, false, .none);
            try n.condSet(k.xreq);
            try n.put(k.funs.len);
            for (0..k.funs.len) |i| {
                const f = n.t.fun(c, @intCast(i));
                try n.tag(.fun);
                try n.put(f.j);
                try n.put(@backingInt(f.calls));
                try n.put(@as(u32, @intFromBool(f.need)) | (@as(u32, @intFromBool(f.seen)) << 1));
                try n.sortedItems(.supply, f, f.supplies.len, supplyWords);
                try n.sortedItems(.keep, f, f.keeps.len, keepWords);
                try n.sortedItems(.back, f, f.backs.len, backWords);
            }
            try n.put(k.slots.len);
            for (0..k.slots.len) |i| {
                const s = n.t.slot(c, @intCast(i));
                try n.tag(.slot);
                try n.put(s.param);
                try n.path(s.path);
            }
            try n.put(k.classes.len);
            for (n.t.nestedOf(c)) |x| try n.class(x);
            try n.put(k.once.len);
            for (n.t.oncesOf(c)) |p| try n.path(p); // sorted by id: the store's order is canonical within a build
            try n.cellSet(k.refs);
        }

        fn supplyWords(n: *Normalizer, f: Fun, i: u32) Error!void {
            const s = n.t.supply(f, i);
            try n.put(s.k);
            try n.put(@as(u32, @intFromBool(s.owned)) | (@as(u32, @intFromBool(s.taken)) << 1));
            try n.label(s.label);
            // The handed value under its own snapshot.
            const saved = n.ctx;
            n.ctx = s.kappa;
            defer n.ctx = saved;
            try n.node(s.node, false, s.kappa);
        }

        fn backWords(n: *Normalizer, f: Fun, i: u32) Error!void {
            const b = n.t.backOf(f, i);
            try n.put(b.dest_param);
            try n.put(@as(u32, @backingInt(b.mode)) | (@as(u32, @intFromBool(b.removes)) << 8));
            try n.path(b.selected);
            try n.path(b.dest);
        }

        fn keepWords(n: *Normalizer, f: Fun, i: u32) Error!void {
            const k = n.t.keepOf(f, i);
            try n.put(k.j);
            try n.put(k.k);
            try n.path(k.kept_path);
            try n.path(k.written_path);
            try n.put(k.writer);
        }

        /// `len` items of `f`: each spelled for the SORT in a context of its
        /// own (fresh ordinals, so the storage order cannot reach the key),
        /// then spelled in key order in this context.
        fn sortedItems(n: *Normalizer, t: Tag, f: Fun, len: u32, spell: *const fn (*Normalizer, Fun, u32) Error!void) Error!void {
            const gpa = n.env.gpa;
            const Keyed = struct { key: []u32, i: u32 };
            var keyed: std.ArrayList(Keyed) = .empty;
            defer {
                for (keyed.items) |k| gpa.free(k.key);
                keyed.deinit(gpa);
            }
            for (0..len) |i| {
                try n.env.charge.reserve(gpa, .inspection, 1);
                var buf: std.ArrayList(u32) = .empty;
                errdefer buf.deinit(gpa);
                var fresh: Normalizer = .{ .t = n.t, .env = n.env, .out = &buf, .ctx = n.ctx };
                defer fresh.deinit();
                try spell(&fresh, f, @intCast(i));
                try keyed.append(gpa, .{ .key = try buf.toOwnedSlice(gpa), .i = @intCast(i) });
            }
            std.mem.sort(Keyed, keyed.items, {}, struct {
                fn lessThan(_: void, x: Keyed, y: Keyed) bool {
                    return lessRun(x.key, y.key);
                }
            }.lessThan);
            try n.tag(t);
            try n.put(len);
            for (keyed.items) |k| try spell(n, f, k.i);
        }

        fn node(n: *Normalizer, root: NodeId, root_summary: bool, root_cur: Kappas) Error!void {
            // Spelled in the recursion's order on an explicit stack (#1138: a
            // value is as deep as the source): a node's words, then its parts;
            // an `Over` its count, then each step and the node below it.
            const Act = struct { kind: enum { node, overs, step }, id: u32, at_summary: bool, cur: Kappas };
            var stack: std.ArrayList(Act) = .empty;
            defer stack.deinit(n.env.gpa);
            var entries: std.ArrayList(Shape.Table.OverIterator.Entry) = .empty;
            defer entries.deinit(n.env.gpa);
            try stack.append(n.env.gpa, .{ .kind = .node, .id = root.int(), .at_summary = root_summary, .cur = root_cur });
            while (stack.pop()) |a| switch (a.kind) {
                .step => try n.step(Step.fromWord(a.id)),
                .overs => {
                    entries.clearRetainingCapacity();
                    var it = n.env.shapes.overEntries(a.id);
                    while (it.next()) |e| try entries.append(n.env.gpa, e);
                    try n.put(@intCast(entries.items.len));
                    var k = entries.items.len;
                    while (k > 0) {
                        k -= 1;
                        const e = entries.items[k];
                        try stack.append(n.env.gpa, .{ .kind = .node, .id = e.node.int(), .at_summary = a.at_summary or e.step.kind == .elem or e.step.kind == .level, .cur = n.env.conds.kappaChild(a.cur, e.step) });
                        try stack.append(n.env.gpa, .{ .kind = .step, .id = e.step.word(), .at_summary = false, .cur = .none });
                    }
                },
                .node => {
                    // A view normalizes as its answer (§2.11); a stored class holds none.
                    const id = try n.env.shapes.force(n.env.gpa, n.env.account(), .from(a.id));
                    const at_summary = a.at_summary;
                    const cur = a.cur;
                    try n.env.charge.reserve(n.env.gpa, .inspection, 1);
                    if (n.ordinal.get(.{ id.int(), cur.int() })) |o| {
                        try n.tag(.node_ref);
                        try n.put(o);
                        continue;
                    }
                    (try n.ordinal.getOrPut(n.env.gpa, .{ id.int(), cur.int() })).value_ptr.* = n.next;
                    n.next += 1;
                    const d = n.env.shapes.get(id);
                    try n.tag(.node_new);
                    try n.put(@backingInt(d.kind));
                    try n.put(d.place.int());
                    try n.cellSet(try n.env.shapes.cellsOf(n.env.gpa, n.env.account(), &n.env.cells.sets, id));
                    try n.cond(try n.env.conds.kappaOf(n.env.gpa, n.env.charge, n.env.view(), cur, id, at_summary));
                    // The parts, pushed in reverse.
                    switch (d.kind) {
                        .view => unreachable, // forced above
                        .leaf => {},
                        .node => try stack.append(n.env.gpa, .{ .kind = .overs, .id = d.a, .at_summary = at_summary, .cur = cur }),
                        .delta => {
                            try stack.append(n.env.gpa, .{ .kind = .overs, .id = d.b, .at_summary = at_summary, .cur = cur });
                            try stack.append(n.env.gpa, .{ .kind = .node, .id = d.a, .at_summary = at_summary, .cur = cur });
                        },
                        .recast => try stack.append(n.env.gpa, .{ .kind = .node, .id = d.a, .at_summary = at_summary, .cur = cur }),
                        .@"union", .choice, .positions => {
                            try stack.append(n.env.gpa, .{ .kind = .node, .id = d.b, .at_summary = at_summary, .cur = cur });
                            try stack.append(n.env.gpa, .{ .kind = .node, .id = d.a, .at_summary = at_summary, .cur = cur });
                        },
                    }
                },
            };
        }

        fn step(n: *Normalizer, s: Step) Error!void {
            try n.put(@backingInt(s.kind));
            if (s.kind == .ctor_arg) {
                const pair = n.env.places.ctorArgOf(s);
                try n.put(pair[0]);
                try n.put(pair[1]);
            } else {
                try n.put(s.payload);
            }
        }

        fn path(n: *Normalizer, p: PathId) Error!void {
            try n.tag(.path);
            if (p == .none) {
                try n.put(Ids.none_int);
                return;
            }
            const depth = n.env.places.pathDepth(p);
            try n.put(depth);
            var stepsbuf: std.ArrayList(Step) = .empty;
            defer stepsbuf.deinit(n.env.gpa);
            var at = p;
            while (n.env.places.pathParent(at) != .none) : (at = n.env.places.pathParent(at)) try stepsbuf.append(n.env.gpa, n.env.places.pathStep(at));
            try n.put(n.env.places.pathPlace(at).int());
            var i = stepsbuf.items.len;
            while (i > 0) : (i -= 1) try n.step(stepsbuf.items[i - 1]);
        }

        fn label(n: *Normalizer, l: LabelId) Error!void {
            try n.tag(.label);
            if (l == .none) {
                try n.put(Ids.none_int);
                return;
            }
            const d = n.env.cells.labelOf(l);
            try n.put(d.inst);
            try n.put(@intFromBool(d.folded));
            try n.label(d.callee_label);
        }

        fn cell(n: *Normalizer, c: CellId) Error!void {
            try n.env.charge.reserve(n.env.gpa, .inspection, 1);
            const d = n.env.cells.get(c);
            try n.tag(.cell);
            try n.put(@backingInt(d.origin));
            try n.put(@backingInt(d.kind));
            switch (d.origin) {
                .site => try n.put(d.a),
                .result, .esc => {
                    try n.label(.from(d.a));
                    try n.put(d.b);
                },
                .param, .env, .msg, .shared => {
                    try n.put(d.a);
                    try n.path(.from(d.b));
                },
                .cb => {
                    try n.label(.from(d.a));
                    try n.path(.from(d.b));
                    try n.put(d.c);
                },
                .top => {},
                .part => {
                    try n.cell(.from(d.a));
                    try n.path(.from(d.c));
                },
                .elem, .others, .level, .below, .loan => {
                    try n.cell(.from(d.a));
                    try n.label(.from(d.b));
                    try n.put(d.c);
                },
                .mark => {
                    try n.put(d.a);
                    try n.put(d.b);
                },
            }
        }

        /// A run of spellings, each into its own buffer, sorted and appended
        /// with a tag and count.
        fn sortedRuns(n: *Normalizer, runs: *std.ArrayList([]u32)) Error!void {
            sortRuns(runs.items);
            try n.tag(.set);
            try n.put(@intCast(runs.items.len));
            for (runs.items) |r| try n.out.appendSlice(n.env.gpa, r);
        }

        fn spellInto(n: *Normalizer, runs: *std.ArrayList([]u32), comptime spell: anytype, arg: anytype) Error!void {
            const gpa = n.env.gpa;
            try n.env.charge.reserve(gpa, .inspection, 1);
            var buf: std.ArrayList(u32) = .empty;
            errdefer buf.deinit(gpa);
            const saved = n.out;
            n.out = &buf;
            const r = spell(n, arg);
            n.out = saved;
            try r;
            try runs.append(gpa, try buf.toOwnedSlice(gpa));
        }

        fn cellWithBit(n: *Normalizer, e: Cell.Radix.Iterator.Entry) Error!void {
            try n.cell(.from(e.key));
            try n.put(e.value);
        }

        /// A cell set: its pairs spelled and sorted.
        fn cellSet(n: *Normalizer, s: SetId) Error!void {
            const gpa = n.env.gpa;
            var runs: std.ArrayList([]u32) = .empty;
            defer {
                for (runs.items) |r| gpa.free(r);
                runs.deinit(gpa);
            }
            var it = n.env.cells.sets.iterate(s);
            while (it.next()) |e| try n.spellInto(&runs, cellWithBit, e);
            try n.sortedRuns(&runs);
        }

        fn cond(n: *Normalizer, k: CondId) Error!void {
            try n.tag(.cond);
            try n.put(@backingInt(n.env.conds.kind(k)));
            if (k == Cond.yes or Cond.Table.fails(k)) return;
            try n.condSet(try n.env.conds.flat(n.env.gpa, n.env.charge, k));
        }

        fn atomOf(n: *Normalizer, id: u32) Error!void {
            return n.atom(n.env.conds.get(.from(id)));
        }

        /// An atom set spelled and sorted.
        fn condSet(n: *Normalizer, s: SetId) Error!void {
            const gpa = n.env.gpa;
            var runs: std.ArrayList([]u32) = .empty;
            defer {
                for (runs.items) |r| gpa.free(r);
                runs.deinit(gpa);
            }
            var it = n.env.conds.atoms.iterate(s);
            while (it.next()) |e| try n.spellInto(&runs, atomOf, e.key);
            try n.sortedRuns(&runs);
        }

        fn atom(n: *Normalizer, a: Cond.Cond) Error!void {
            try n.tag(.atom);
            try n.put(@backingInt(a.atom));
            switch (a.atom) {
                .excl => try n.cell(.from(a.a)),
                .sep => {
                    const gpa = n.env.gpa;
                    var runs: std.ArrayList([]u32) = .empty;
                    defer {
                        for (runs.items) |r| gpa.free(r);
                        runs.deinit(gpa);
                    }
                    try n.spellInto(&runs, cell, CellId.from(a.a));
                    try n.spellInto(&runs, cell, CellId.from(a.b));
                    sortRuns(runs.items);
                    for (runs.items) |r| try n.out.appendSlice(gpa, r);
                },
                .within => try n.label(.from(a.a)),
                .apart => try n.cellSet(.from(a.a)),
                .keep, .writes => try n.put(a.a),
                .inst => unreachable, // a summary is resolved
            }
        }
    };

    fn lessRun(x: []const u32, y: []const u32) bool {
        return std.mem.order(u32, x, y) == .lt;
    }

    fn sortRuns(runs: [][]u32) void {
        std.mem.sort([]u32, runs, {}, struct {
            fn lessThan(_: void, x: []u32, y: []u32) bool {
                return lessRun(x, y);
            }
        }.lessThan);
    }

    // ---- text --------------------------------------------------------------

    /// `summary <name>: <facts> (words|asserted)` in v1's grammar (oc
    /// §16.11): parameter paths and bits, `res` by path, function
    /// parameters, `xreq`; `unused` when nothing is left. `arena` holds the
    /// texts while they are sorted.
    pub fn print(t: *Table, env: Env, arena: Allocator, w: *std.Io.Writer, c: ClassId, name: []const u8, names: Names) (Error || std.Io.Writer.Error)!void {
        var p: Printer = .{ .t = t, .env = env, .arena = arena, .names = names, .class_id = c, .ctx = t.get(c).kappas };
        defer p.deinit();
        try p.summary(w, name);
    }

    const Printer = struct {
        t: *Table,
        env: Env,
        arena: Allocator,
        names: Names,
        class_id: ClassId,
        ctx: Kappas,
        slots: []const Slot = &.{},
        params: u32 = 0,
        seen: Ids.FixedDict(3) = .{},
        /// The path each `seen` entry was first printed at (#1122).
        firsts: std.ArrayList([]const u8) = .empty,
        /// The (node, cursor, summary, prefix) whose structure was expanded:
        /// a union's or positions node's sides that share a node expand it
        /// once at one prefix, never once per route through the DAG (#1182).
        /// The prefix by identity: both sides carry the one slice.
        expanded: Ids.FixedDict(4) = .{},

        const WErr = std.Io.Writer.Error;

        fn deinit(p: *Printer) void {
            p.seen.deinit(p.env.gpa);
            p.expanded.deinit(p.env.gpa);
        }

        fn summary(p: *Printer, w: *std.Io.Writer, name: []const u8) (Error || WErr)!void {
            const arena = p.arena;
            const k = p.t.get(p.class_id);
            p.params = k.params.len;
            var slots: std.ArrayList(Slot) = .empty;
            for (0..k.slots.len) |i| try slots.append(arena, p.t.slot(p.class_id, @intCast(i)));
            p.slots = slots.items;
            var parts: std.ArrayList([]const u8) = .empty;
            var uses: std.ArrayList([]const u8) = .empty;
            for (p.t.paramUses(p.class_id), 0..) |u, i| if (u != .none) try p.useLines(u, @intCast(i), "", &uses);
            Cond.sortText(uses.items);
            if (uses.items.len > 0) try parts.append(arena, try std.mem.join(arena, ", ", uses.items));
            var groups: std.ArrayList([]const u8) = .empty;
            p.seen.deinit(p.env.gpa);
            p.seen = .{};
            p.firsts = .empty;
            try p.resLines(k.res, "", false, p.ctx, &groups);
            Cond.sortText(groups.items);
            // One line per (route, text): a route a union's two sides reach
            // with one leaf prints it once, however the leaf was first met.
            var kept: usize = 0;
            for (groups.items) |g| {
                if (kept > 0 and std.mem.eql(u8, groups.items[kept - 1], g)) continue;
                groups.items[kept] = g;
                kept += 1;
            }
            groups.shrinkRetainingCapacity(kept);
            if (groups.items.len > 0) try parts.append(arena, try std.fmt.allocPrint(arena, "res {s}", .{try std.mem.join(arena, ", ", groups.items)}));
            // The fold certificate (§8 slice 4, *Publication*, #1485): each
            // `res` line of a certified class is its entry `K {keys} κ`.
            if (p.t.certified(p.class_id)) try parts.append(arena, "cert");
            for (0..k.funs.len) |i| {
                const f = p.t.fun(p.class_id, @intCast(i));
                var buf: std.Io.Writer.Allocating = .init(arena);
                const wr = &buf.writer;
                try p.funName(wr, f.j);
                try wr.print(" calls {s}", .{switch (f.calls) {
                    .zero => "0",
                    .once => "≤1",
                    .many => "many",
                }});
                if (f.need) try wr.writeAll(", need owned");
                if (!f.seen) try wr.writeAll(", unseen");
                var sup: std.ArrayList([]const u8) = .empty;
                for (0..f.supplies.len) |s| {
                    const e = p.t.supply(f, @intCast(s));
                    var sb: std.Io.Writer.Allocating = .init(arena);
                    try sb.writer.print("supply {d} ", .{e.k + 1});
                    try p.cellsText(&sb.writer, try p.env.shapes.cellsOf(p.env.gpa, p.env.account(), &p.env.cells.sets, e.node));
                    try sb.writer.print(" {s}{s}", .{ if (e.owned) "owned" else "borrowed", if (e.taken) " taken" else "" });
                    try p.cond(&sb.writer, try p.env.conds.kappaOf(p.env.gpa, p.env.charge, p.env.view(), e.kappa, e.node, false));
                    if (e.label != .none) {
                        try sb.writer.writeAll(" @");
                        try p.label(&sb.writer, e.label);
                    }
                    try sup.append(arena, sb.toOwnedSlice() catch return error.OutOfMemory);
                }
                Cond.sortText(sup.items);
                for (sup.items) |s| try wr.print(", {s}", .{s});
                // The write-backs, in the run's order.
                for (0..f.backs.len) |s| {
                    const b = p.t.backOf(f, @intCast(s));
                    try wr.writeAll(", stores answer");
                    try p.path(wr, b.selected);
                    try wr.print(" at π{d}", .{b.dest_param + 1});
                    try p.path(wr, b.dest);
                    if (b.removes) try wr.writeAll(" or removes");
                }
                try parts.append(arena, buf.toOwnedSlice() catch return error.OutOfMemory);
            }
            if (k.xreq != .none) {
                var buf: std.Io.Writer.Allocating = .init(arena);
                try buf.writer.writeAll("xreq ");
                try p.atoms(&buf.writer, k.xreq);
                try parts.append(arena, buf.toOwnedSlice() catch return error.OutOfMemory);
            }
            const facts = if (parts.items.len == 0) "unused" else try std.mem.join(arena, "; ", parts.items);
            try w.print("summary {s}: {s}{s}", .{ name, facts, switch (k.origin) {
                .words => " (words)",
                .asserted => " (asserted)",
                .inferred, .unknown => "",
            } });
        }

        fn funName(p: *Printer, w: *std.Io.Writer, j: u32) WErr!void {
            if (j >= p.params and j - p.params < p.slots.len) {
                const s = p.slots[j - p.params];
                try w.print("π{d}", .{s.param + 1});
                try p.path(w, s.path);
            } else try w.print("π{d}", .{j + 1});
        }

        /// `π{i}{path} {bits}` for every used path of a use shape.
        fn useLines(p: *Printer, root: NodeId, i: u32, root_prefix: []const u8, out: *std.ArrayList([]const u8)) (Error || WErr)!void {
            const env = p.env;
            // Depth-first on an explicit stack, children in order (#1138: a
            // use shape is as deep as the source).
            const Item = struct { u: NodeId, prefix: []const u8 };
            var stack: std.ArrayList(Item) = .empty;
            defer stack.deinit(env.gpa);
            var below: std.ArrayList(Item) = .empty;
            defer below.deinit(env.gpa);
            try stack.append(env.gpa, .{ .u = root, .prefix = root_prefix });
            while (stack.pop()) |item| try p.useLine(item.u, i, item.prefix, out, &below, &stack);
        }

        fn useLine(p: *Printer, u: NodeId, i: u32, prefix: []const u8, out: *std.ArrayList([]const u8), below: anytype, stack: anytype) (Error || WErr)!void {
            const env = p.env;
            const d = env.shapes.get(u);
            var buf: std.Io.Writer.Allocating = .init(p.arena);
            const w = &buf.writer;
            try w.print("π{d}{s} ", .{ i + 1, prefix });
            var m: Marks = .{};
            var fields: std.ArrayList([]const u8) = .empty;
            var it = env.cells.sets.iterate(d.cells);
            while (it.next()) |e| {
                const c: CellId = .from(e.key);
                if (env.cells.origin(c) != .mark) continue;
                switch (env.cells.markOf(c)) {
                    .r, .deep_read => m.r = true,
                    .a => m.a = true,
                    .e => m.e = true,
                    .w => m.w = true,
                    .deep => m.deep = true,
                    .field => try fields.append(p.arena, p.names.field(p.names.ctx, env.cells.get(c).b)),
                }
            }
            if (!m.isEmpty() or fields.items.len > 0) {
                if (m.r) try w.writeAll("R");
                if (m.a) try w.writeAll("A");
                if (m.e) try w.writeAll("E");
                if (m.w) try w.writeAll(if (m.deep) "S" else "W");
                if (fields.items.len > 0) {
                    Cond.sortText(fields.items);
                    try w.print("W{{{s}}}", .{try std.mem.join(p.arena, ", ", fields.items)});
                }
                try out.append(p.arena, buf.toOwnedSlice() catch return error.OutOfMemory);
            }
            if (d.kind != .node) return;
            below.clearRetainingCapacity();
            var kids = env.shapes.overEntries(d.a);
            while (kids.next()) |e| {
                var sb: std.Io.Writer.Allocating = .init(p.arena);
                try sb.writer.writeAll(prefix);
                try p.step(&sb.writer, d.place, e.step);
                try below.append(env.gpa, .{ .u = e.node, .prefix = sb.toOwnedSlice() catch return error.OutOfMemory });
            }
            var k = below.items.len;
            while (k > 0) {
                k -= 1;
                try stack.append(env.gpa, below.items[k]);
            }
        }

        /// `res`'s groups: one text per path of the explicit structure,
        /// `<path> <provenances> {κ}`, a node once; a union's sides gathered
        /// into one group, a recast's cells approximate.
        fn resLines(p: *Printer, root: NodeId, root_prefix: []const u8, root_summary: bool, root_cur: Kappas, out: *std.ArrayList([]const u8)) (Error || WErr)!void {
            const env = p.env;
            // In the recursion's order on an explicit stack (#1138: a value is
            // as deep as the source): a node's line, then the lines below it,
            // a union's sides in turn, a node's steps in order.
            // `dag`: the outermost union, choice or positions node on the way,
            // projected along the steps since (§2.9 *Keyed where a reader
            // looks*): what a join keyed at this path, read with each node.
            const Act = struct { line: bool, n: NodeId, prefix: []const u8, at_summary: bool, cur: Kappas, dag: NodeId = .none };
            var stack: std.ArrayList(Act) = .empty;
            defer stack.deinit(env.gpa);
            var below: std.ArrayList(Act) = .empty;
            defer below.deinit(env.gpa);
            try stack.append(env.gpa, .{ .line = true, .n = root, .prefix = root_prefix, .at_summary = root_summary, .cur = root_cur });
            while (stack.pop()) |a| {
                const n = a.n;
                if (a.line) {
                    const got = try p.seen.getOrPut(env.gpa, .{ n.int(), a.cur.int(), @intFromBool(a.at_summary) });
                    if (got.found_existing) {
                        // The same node at the same cursor by another route (#1122):
                        // printed there too, never omitted. A leaf's line again;
                        // a built node's a reference to its first route, so a
                        // DAG is never flattened. Below its first route, a cycle.
                        const first = p.firsts.items[got.value_ptr.*];
                        if (routeBelow(a.prefix, first)) continue;
                        if (env.shapes.kind(n) != .leaf) {
                            try out.append(p.arena, try std.fmt.allocPrint(p.arena, "{s} = {s}", .{ a.prefix, first }));
                            continue;
                        }
                    } else {
                        got.value_ptr.* = @intCast(p.firsts.items.len);
                        try p.firsts.append(p.arena, a.prefix);
                    }
                    var texts: std.ArrayList([]const u8) = .empty;
                    try p.gather(n, &texts);
                    Cond.sortText(texts.items);
                    var buf: std.Io.Writer.Allocating = .init(p.arena);
                    const w = &buf.writer;
                    if (a.prefix.len > 0) try w.print("{s} ", .{a.prefix});
                    try w.writeAll(try std.mem.join(p.arena, " ", texts.items));
                    var k = try env.conds.kappaOf(env.gpa, env.charge, env.view(), a.cur, n, a.at_summary);
                    // A reader at this path reads the outermost join on the way,
                    // which joins every side and every join nested in it (§2.9).
                    if (a.dag != .none and a.dag != n) k = try env.conds.join(env.gpa, env.charge, k, try env.conds.kappaOf(env.gpa, env.charge, env.view(), a.cur, a.dag, a.at_summary));
                    try p.cond(w, k);
                    if (texts.items.len > 0 or k != Cond.yes) try out.append(p.arena, buf.toOwnedSlice() catch return error.OutOfMemory);
                    try stack.append(env.gpa, .{ .line = false, .n = n, .prefix = a.prefix, .at_summary = a.at_summary, .cur = a.cur, .dag = a.dag });
                    continue;
                }
                // The children of the explicit structure under `n`: a node's
                // or a delta's projections (so a delta's unchanged fields
                // print), a union's sides' in turn; a leaf's or a recast's
                // are implied by its cells and never enumerated. Once per
                // (node, cursor, summary, prefix): a second expansion's lines
                // are all at a printed route already (#1182).
                const pp: u64 = @intFromPtr(a.prefix.ptr);
                if ((try p.expanded.getOrPut(env.gpa, .{ n.int(), a.cur.int(), @as(u32, @intFromBool(a.at_summary)) | @as(u32, @truncate(pp >> 32)) << 1, @truncate(pp) })).found_existing) continue;
                const d = env.shapes.get(n);
                switch (d.kind) {
                    .leaf, .recast => {},
                    .view => {
                        var b = a;
                        b.n = try env.shapes.force(env.gpa, env.account(), n);
                        try stack.append(env.gpa, b);
                    },
                    .@"union", .choice, .positions => {
                        const dag = if (a.dag != .none or d.kind == .positions) a.dag else n;
                        try stack.append(env.gpa, .{ .line = false, .n = .from(d.b), .prefix = a.prefix, .at_summary = a.at_summary, .cur = a.cur, .dag = dag });
                        try stack.append(env.gpa, .{ .line = false, .n = .from(d.a), .prefix = a.prefix, .at_summary = a.at_summary, .cur = a.cur, .dag = dag });
                    },
                    .node, .delta => {
                        below.clearRetainingCapacity();
                        const steps = env.places.steps(d.place);
                        for (steps.steps) |s| {
                            const c = (try env.shapes.proj(env.gpa, env.account(), env.places, env.cells, n, s)) orelse continue;
                            if (env.shapes.kind(c) == .leaf and env.shapes.cells(c) == .none) continue;
                            var sb: std.Io.Writer.Allocating = .init(p.arena);
                            try sb.writer.writeAll(a.prefix);
                            try p.step(&sb.writer, d.place, s);
                            const dag = if (a.dag == .none) NodeId.none else (try env.shapes.proj(env.gpa, env.account(), env.places, env.cells, a.dag, s)) orelse NodeId.none;
                            try below.append(env.gpa, .{ .line = true, .n = c, .prefix = sb.toOwnedSlice() catch return error.OutOfMemory, .at_summary = a.at_summary or s.kind == .elem or s.kind == .level, .cur = env.conds.kappaChild(a.cur, s), .dag = dag });
                        }
                        var i = below.items.len;
                        while (i > 0) {
                            i -= 1;
                            try stack.append(env.gpa, below.items[i]);
                        }
                    },
                }
            }
        }

        /// The provenance texts of `n`'s cells at its own path: through a
        /// union's sides, `~` before an approximate pair or under a recast.
        fn gather(p: *Printer, root: NodeId, texts: *std.ArrayList([]const u8)) (Error || WErr)!void {
            var stack: std.ArrayList(NodeId) = .empty;
            defer stack.deinit(p.env.gpa);
            try stack.append(p.env.gpa, root);
            // Each node once per gather (#1182).
            var gathered: Ids.FixedDict(1) = .{};
            defer gathered.deinit(p.env.gpa);
            while (stack.pop()) |n| {
                // A node the DAG reaches twice gives its cells once (#1182).
                if ((try gathered.getOrPut(p.env.gpa, .{n.int()})).found_existing) continue;
                const d = p.env.shapes.get(n);
                if (d.kind == .@"union" or d.kind == .choice or d.kind == .positions) {
                    try stack.appendSlice(p.env.gpa, &.{ .from(d.b), .from(d.a) });
                    continue;
                }
                try p.gatherCells(try p.env.shapes.cellsOf(p.env.gpa, p.env.account(), &p.env.cells.sets, n), d.kind == .recast, texts);
            }
        }

        fn gatherCells(p: *Printer, s: SetId, all_approx: bool, texts: *std.ArrayList([]const u8)) (Error || WErr)!void {
            var it = p.env.cells.sets.iterate(s);
            while (it.next()) |e| {
                var buf: std.Io.Writer.Allocating = .init(p.arena);
                if (e.value == 1 or all_approx) try buf.writer.writeAll("~");
                try p.cell(&buf.writer, .from(e.key));
                try texts.append(p.arena, buf.toOwnedSlice() catch return error.OutOfMemory);
            }
        }

        /// A set's cells in text order, `~` before an approximate pair.
        fn cellsText(p: *Printer, w: *std.Io.Writer, s: SetId) (Error || WErr)!void {
            var texts: std.ArrayList([]const u8) = .empty;
            try p.gatherCells(s, false, &texts);
            Cond.sortText(texts.items);
            try w.writeAll(try std.mem.join(p.arena, " ", texts.items));
        }

        fn cond(p: *Printer, w: *std.Io.Writer, k: CondId) (Error || WErr)!void {
            try p.env.conds.print(p.env.gpa, p.env.charge, p.arena, w, k, p.env.cells, .{ .ctx = p, .cell = printCell, .label = printLabel });
        }

        fn atoms(p: *Printer, w: *std.Io.Writer, s: SetId) (Error || WErr)!void {
            var texts: std.ArrayList([]const u8) = .empty;
            var it = p.env.conds.atoms.iterate(s);
            while (it.next()) |e| {
                var buf: std.Io.Writer.Allocating = .init(p.arena);
                try p.env.conds.printAtom(&buf.writer, p.env.conds.get(.from(e.key)), p.env.gpa, p.arena, p.env.cells, .{ .ctx = p, .cell = printCell, .label = printLabel });
                try texts.append(p.arena, buf.toOwnedSlice() catch return error.OutOfMemory);
            }
            Cond.sortText(texts.items);
            try w.writeAll(try std.mem.join(p.arena, ", ", texts.items));
        }

        fn printCell(ctx: *anyopaque, w: *std.Io.Writer, c: CellId) WErr!void {
            const p: *Printer = @ptrCast(@alignCast(ctx));
            return p.cell(w, c);
        }

        fn printLabel(ctx: *anyopaque, w: *std.Io.Writer, l: LabelId) WErr!void {
            const p: *Printer = @ptrCast(@alignCast(ctx));
            return p.label(w, l);
        }

        /// A provenance (oc §16.11, §24.7): `π1.a`, `fresh2`, `esc1`,
        /// `shared(M.v).q`, `cb3[*]` (`cb(π1.f)` for a slot), `msg#Got.0`,
        /// `⊤`, `elem(π1·ι)`, `others(…)`, `level(…)`, `below(…#i·ι)`,
        /// `loan(…)`, `site7`; a label other than the class's own after `@`.
        fn cell(p: *Printer, w: *std.Io.Writer, top: CellId) WErr!void {
            // A refinement chain (`elem(elem(c·ι)·κ)`): the openings down to
            // its base, the base, then the closings back up, on an explicit
            // list (#1143: splits nest as deep as the source's patterns).
            const env = p.env;
            var chain: std.ArrayList(CellId) = .empty;
            var at = top;
            while (true) {
                const o = env.cells.get(at).origin;
                if (o != .elem and o != .others and o != .level and o != .below and o != .loan and o != .part) break;
                chain.append(p.arena, at) catch return error.WriteFailed;
                try w.writeAll(switch (o) {
                    .elem => "elem(",
                    .others => "others(",
                    .level => "level(",
                    .below => "below(",
                    .part => "part(",
                    else => "loan(",
                });
                at = .from(env.cells.get(at).a);
            }
            try p.cellBase(w, at);
            var i = chain.items.len;
            while (i > 0) {
                i -= 1;
                const d = env.cells.get(chain.items[i]);
                if (d.origin == .part) {
                    try p.path(w, .from(d.c));
                    try w.writeAll(")");
                    continue;
                }
                if (d.origin == .below) try w.print("#{d}", .{d.c});
                try w.writeAll("·");
                try p.label(w, .from(d.b));
                try w.writeAll(")");
            }
        }

        fn cellBase(p: *Printer, w: *std.Io.Writer, c: CellId) WErr!void {
            const env = p.env;
            const d = env.cells.get(c);
            switch (d.origin) {
                .site => try w.print("site{d}", .{d.a}),
                .result, .esc => {
                    try w.writeAll(if (d.origin == .result) "fresh" else "esc");
                    if (d.b != 0) try w.print("{d}", .{d.b});
                    if (LabelId.from(d.a) != .none) {
                        try w.writeAll("@");
                        try p.label(w, .from(d.a));
                    }
                },
                .param => {
                    try w.print("π{d}", .{d.a + 1});
                    try p.path(w, .from(d.b));
                },
                .env => {
                    try w.print("◇{d}", .{d.a});
                    try p.path(w, .from(d.b));
                },
                .msg => {
                    try w.writeAll("msg");
                    try p.path(w, .from(d.b));
                },
                .shared => {
                    try w.print("shared({s})", .{p.names.decl(p.names.ctx, d.a, d.c)});
                    try p.path(w, .from(d.b));
                },
                .cb => {
                    if (d.c >= p.params and d.c - p.params < p.slots.len) {
                        const s = p.slots[d.c - p.params];
                        try w.print("cb(π{d}", .{s.param + 1});
                        try p.path(w, s.path);
                        try w.writeAll(")");
                    } else try w.print("cb{d}", .{d.c + 1});
                    if (LabelId.from(d.a) != .none) {
                        try w.writeAll("@");
                        try p.label(w, .from(d.a));
                    }
                    try p.path(w, .from(d.b));
                },
                .top => try w.writeAll("⊤"),
                .elem, .others, .level, .below, .loan, .part => unreachable,
                .mark => try w.writeAll(switch (env.cells.markOf(c)) {
                    .r, .deep_read => "R",
                    .a => "A",
                    .e => "E",
                    .w => "W",
                    .deep => "S",
                    .field => "W{}",
                }),
            }
        }

        /// A label: `ι<inst>`, `⋆` when folded, `·` then the callee's.
        fn label(p: *Printer, w: *std.Io.Writer, first: LabelId) WErr!void {
            if (first == .none) return w.writeAll("λ");
            // The callee chain as a loop (#1143: calls nest as deep as the source).
            var l = first;
            while (true) {
                const d = p.env.cells.labelOf(l);
                try w.print("ι{d}", .{d.inst});
                if (d.folded) try w.writeAll("⋆");
                if (d.callee_label == .none) break;
                try w.writeAll("·");
                l = d.callee_label;
            }
        }

        fn path(p: *Printer, w: *std.Io.Writer, q: PathId) WErr!void {
            if (q == .none) return;
            var steps: std.ArrayList(PathId) = .empty;
            var at = q;
            while (p.env.places.pathParent(at) != .none) : (at = p.env.places.pathParent(at)) {
                steps.append(p.arena, at) catch return error.WriteFailed;
            }
            var n = steps.items.len;
            while (n > 0) : (n -= 1) try p.step(w, p.env.places.pathPlace(p.env.places.pathParent(steps.items[n - 1])), p.env.places.pathStep(steps.items[n - 1]));
        }

        /// Step `s` out of place `from` (a constructor is named by its type).
        /// Whether printed path `route` is `first` or a path below it: `first`
        /// then a step (`.`, `#`, `[`, or a sign like `⟲`).
        fn routeBelow(route: []const u8, first: []const u8) bool {
            if (!std.mem.startsWith(u8, route, first)) return false;
            if (route.len == first.len) return true;
            const c = route[first.len];
            return c == '.' or c == '#' or c == '[' or c >= 0x80;
        }

        fn step(p: *Printer, w: *std.Io.Writer, from: PlaceId, s: Step) WErr!void {
            switch (s.kind) {
                .field => try w.print(".{s}", .{p.names.field(p.names.ctx, s.payload)}),
                .index => try w.print(".{d}", .{s.payload}),
                .ctor_arg => {
                    const pair = p.env.places.ctorArgOf(s);
                    try w.print("#{s}.{d}", .{ p.names.ctor(p.names.ctx, p.env.places.head(from), pair[0]), pair[1] });
                },
                .elem => try w.writeAll("[*]"),
                .contents => try w.writeAll("◆"),
                .env => try w.writeAll("◇"),
                .slot => try w.print("⟨{d}⟩", .{s.payload}),
                .level => try w.writeAll("⟲"),
            }
        }
    };
};

comptime {
    Ids.assertRecord(Class);
    Ids.assertRecord(Fun);
    Ids.assertRecord(Slot);
    Ids.assertRecord(Supply);
    Ids.assertRecord(Keep);
    Ids.assertRecord(Back);
    std.debug.assert(@sizeOf(Class) <= 64);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A test type graph: 0 a record `{ a : List Int, b : List Int }`, 1 `List
/// Int`, 2 `Int`, 3 `List (List Int)`, 4 `Int → Int` (a function leaf).
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
            4 => return .{ .kind = .closure, .head = 400 },
            // 5 a list of itself: a recursive place, for depth (#1138).
            5 => {
                try out.append(g.gpa, .{ .step = Place.Step.elem, .@"var" = 5 });
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
    conds: Cond.Table = undefined,
    sums: Table = .{},
    account: Ids.Account = .{},
    graph: TestGraph = undefined,
    arena: std.heap.ArenaAllocator = undefined,

    fn init(f: *Fixture) !void {
        f.graph = .{ .account = &f.account, .gpa = testing.allocator };
        f.conds = try Cond.Table.init(testing.allocator, .growth(&f.account));
        f.arena = std.heap.ArenaAllocator.init(testing.allocator);
    }

    fn deinit(f: *Fixture) void {
        f.places.deinit(testing.allocator);
        f.cells.deinit(testing.allocator);
        f.shapes.deinit(testing.allocator);
        f.conds.deinit(testing.allocator);
        f.sums.deinit(testing.allocator);
        f.account.deinit(testing.allocator);
        f.arena.deinit();
    }

    fn env(f: *Fixture) Env {
        return .{ .gpa = testing.allocator, .charge = .growth(&f.account), .places = &f.places, .cells = &f.cells, .shapes = &f.shapes, .conds = &f.conds };
    }

    fn placeOf(f: *Fixture, v: u32) !PlaceId {
        return f.places.of(testing.allocator, &f.account, .{ .ctx = &f.graph, .describe = TestGraph.describe }, v);
    }

    fn param(f: *Fixture, i: u32, root: u32, steps: []const Step) !CellId {
        const p = try f.placeOf(root);
        var at = try f.places.rootPath(testing.allocator, p);
        for (steps) |s| at = (try f.places.extend(testing.allocator, .growth(&f.account), at, s)).?;
        return f.cells.symbolic(testing.allocator, &f.account, &f.places, .param, i, at, 0);
    }

    fn set(f: *Fixture, cells: []const CellId) !SetId {
        var s: SetId = .none;
        for (cells) |c| s = try f.cells.sets.insert(testing.allocator, .growth(&f.account), s, c.int(), 0);
        return s;
    }

    fn leaf(f: *Fixture, root: u32, cells: []const CellId) !NodeId {
        return f.shapes.leaf(testing.allocator, &f.account, try f.placeOf(root), try f.set(cells));
    }

    fn fresh(f: *Fixture, k: u32, root: u32) !CellId {
        return f.cells.result(testing.allocator, &f.account, .result, .none, k, try f.placeOf(root), .list);
    }

    fn setK(f: *Fixture, ctx: Kappas, n: NodeId, k: CondId) !Kappas {
        return f.setKAt(ctx, n, false, k);
    }

    fn setKAt(f: *Fixture, ctx: Kappas, n: NodeId, at_summary: bool, k: CondId) !Kappas {
        _ = at_summary;
        return (try f.conds.kappaSet(testing.allocator, .growth(&f.account), ctx, n, k)).ctx;
    }

    fn setKPath(f: *Fixture, ctx: Kappas, steps: []const Place.Step, n: NodeId, k: CondId) !Kappas {
        return f.conds.kappaSetAt(testing.allocator, .growth(&f.account), ctx, steps, n, k);
    }

    fn label(f: *Fixture, inst: u32) !LabelId {
        return f.cells.label(testing.allocator, &f.account, inst, .none, false);
    }

    fn text(f: *Fixture, c: ClassId, name: []const u8) ![]const u8 {
        var buf: std.Io.Writer.Allocating = .init(f.arena.allocator());
        try f.sums.print(f.env(), f.arena.allocator(), &buf.writer, c, name, test_names);
        return buf.toOwnedSlice();
    }
};

const TestNames = struct {
    fn field(_: *anyopaque, rank: u32) []const u8 {
        return if (rank == 10) "a" else if (rank == 11) "b" else "?";
    }
    fn ctor(_: *anyopaque, _: u32, _: u32) []const u8 {
        return "C";
    }
    fn decl(_: *anyopaque, _: u32, _: u32) []const u8 {
        return "M.v";
    }
};
var test_names_ctx: u8 = 0;
const test_names: Names = .{ .ctx = &test_names_ctx, .field = TestNames.field, .ctor = TestNames.ctor, .decl = TestNames.decl };

test "use shapes: marks by path, deep leaves, the lazy call-use query, join and leq" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const env = f.env();
    const rec = try f.placeOf(0);
    const fa = try Place.Step.field(&f.account, 10);
    const fb = try Place.Step.field(&f.account, 11);
    var u = try Table.markUse(env, .none, rec, &.{}, .{ .w = true }, &.{10});
    u = try Table.markUse(env, u, rec, &.{fb}, .{ .a = true }, &.{});
    try testing.expectEqual(Marks{ .w = true }, try Table.marksAt(env, u, &.{}));
    try testing.expectEqual(Marks{ .a = true }, try Table.marksAt(env, u, &.{fb}));
    try testing.expectEqual(Marks{}, try Table.marksAt(env, u, &.{fa}));
    try testing.expect(try Table.usedAt(env, u, &.{}));
    try testing.expect(try Table.usedAt(env, u, &.{fb}));
    try testing.expect(!try Table.usedAt(env, u, &.{fa}));
    try testing.expect(!try Table.usedAt(env, u, &.{ fa, Place.Step.elem }));
    const deep = try Table.markUse(env, u, rec, &.{fa}, .{ .r = true, .deep = true }, &.{});
    try testing.expect(try Table.usedAt(env, deep, &.{ fa, Place.Step.elem }));
    try testing.expectEqual(Marks{ .r = true, .deep = true }, try Table.marksAt(env, deep, &.{fa}));
    try testing.expectEqual(Shape.Kind.leaf, f.shapes.kind((try f.shapes.proj(testing.allocator, &f.account, &f.places, &f.cells, deep, fa)).?));
    const under = try Table.markUse(env, deep, rec, &.{ fa, Place.Step.elem }, .{ .w = true }, &.{});
    try testing.expectEqual(Marks{ .r = true, .w = true, .deep = true }, try Table.marksAt(env, under, &.{fa}));
    const only_b = try Table.markUse(env, .none, rec, &.{fb}, .{ .r = true }, &.{});
    const j = try Table.joinUse(env, u, only_b);
    try testing.expectEqual(Marks{ .r = true, .a = true }, try Table.marksAt(env, j, &.{fb}));
    try testing.expectEqual(Marks{ .w = true }, try Table.marksAt(env, j, &.{}));
    try testing.expect(try Table.leqUse(env, u, j));
    try testing.expect(try Table.leqUse(env, only_b, j));
    try testing.expect(!try Table.leqUse(env, j, u));
    try testing.expect(try Table.leqUse(env, .none, u));
    try testing.expectEqual(u, try Table.joinUse(env, u, .none));
}

test "#1328: a deep read is `D` in a node: read below it, and a shallow `W` beside it stays shallow" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const env = f.env();
    const rec = try f.placeOf(0);
    const fa = try Place.Step.field(&f.account, 10);
    const fb = try Place.Step.field(&f.account, 11);
    const d = try Table.markUse(env, .none, rec, &.{fa}, .{ .r = true, .deep_read = true }, &.{});
    try testing.expectEqual(Shape.Kind.node, f.shapes.kind((try f.shapes.proj(testing.allocator, &f.account, &f.places, &f.cells, d, fa)).?));
    // Below the `D`, where the use has no node of its own: read.
    try testing.expect(try Table.usedAt(env, d, &.{ fa, Place.Step.elem }));
    try testing.expectEqual(Marks{ .r = true, .deep_read = true }, try Table.marksAt(env, d, &.{ fa, Place.Step.elem }));
    try testing.expect(!try Table.usedAt(env, d, &.{fb}));
    // A shallow write at the `D`'s path and one below it: neither is `S`.
    const w = try Table.markUse(env, d, rec, &.{fa}, .{ .w = true }, &.{});
    try testing.expectEqual(Marks{ .r = true, .w = true, .deep_read = true }, try Table.marksAt(env, w, &.{fa}));
    const wb = try Table.markUse(env, w, rec, &.{ fa, Place.Step.elem }, .{ .w = true }, &.{});
    try testing.expectEqual(Marks{ .r = true, .w = true, .deep_read = true }, try Table.marksAt(env, wb, &.{ fa, Place.Step.elem }));
    try testing.expectEqual(Shape.Kind.node, f.shapes.kind((try f.shapes.proj(testing.allocator, &f.account, &f.places, &f.cells, wb, fa)).?));
    try testing.expect(try Table.leqUse(env, d, wb));
}

test "a class prints in v1's grammar: bits by path, res by path with κ, funs, xreq" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const env = f.env();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    const lists = try f.placeOf(3);
    const p1 = try f.param(0, 3, &.{});
    const p1e = try f.param(0, 3, &.{Place.Step.elem});
    const p3 = try f.param(2, 1, &.{});
    var use1 = try Table.markUse(env, .none, lists, &.{}, .{ .r = true, .a = true, .w = true }, &.{});
    use1 = try Table.markUse(env, use1, lists, &.{Place.Step.elem}, .{ .a = true }, &.{});
    const use3 = try Table.markUse(env, .none, list, &.{}, .{ .a = true }, &.{});
    const elem = try f.leaf(1, &.{ p1e, p3 });
    const res = try f.shapes.node(gpa, &f.account, lists, try f.set(&.{p1}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Place.Step.elem, elem));
    const e1 = try f.conds.excl(gpa, env.charge, p1);
    const e3 = try f.conds.excl(gpa, env.charge, p3);
    const ap = try f.conds.apartAtom(gpa, env.charge, try f.set(&.{ p1e, p3 }));
    var m = try f.setK(.none, res, e1);
    m = try f.setKPath(m, &.{Place.Step.elem}, elem, try f.conds.@"and"(gpa, env.charge, ap, e3));
    const supply_node = try f.leaf(3, &.{p1});
    const kappa_e1 = try f.setK(.none, supply_node, e1);
    const c = try f.sums.add(env, .{
        .params = &.{ use1, .none, use3 },
        .res = res,
        .kappas = m,
        .xreq = try f.conds.flat(gpa, env.charge, e1),
        .funs = &.{.{ .j = 1, .calls = .once, .supplies = &.{.{ .j = 1, .k = 0, .node = supply_node, .label = .none, .owned = true, .taken = false, .kappa = kappa_e1 }} }},
        .writes = true,
        .origin = .words,
    });
    try testing.expectEqualStrings(
        "summary push: π1 RAW, π1[*] A, π3 A; res [*] π1[*] π3{apart [π1[*]] [π3], excl π1[*], excl π3}, π1{excl π1}; π2 calls ≤1, supply 1 π1 owned{excl π1}; xreq excl π1 (words)",
        try f.text(c, "push"),
    );
    const nothing = try f.sums.add(env, .{ .params = &.{.none}, .res = try f.shapes.nothing(gpa, &f.account, list) });
    try testing.expectEqualStrings("summary g: unused", try f.text(nothing, "g"));
    const fresh1 = try f.fresh(1, 1);
    const r2 = try f.leaf(1, &.{fresh1});
    const fr = try f.sums.add(env, .{ .params = &.{}, .res = r2, .origin = .asserted });
    try testing.expectEqualStrings("summary h: res fresh1 (asserted)", try f.text(fr, "h"));
    const unk = try f.sums.unknown(env, &.{ lists, list }, &.{1}, list);
    try testing.expectEqualStrings("summary k: π1 RAES, π2 RAES; res ⊤{lost}; π2 calls many, need owned, unseen", try f.text(unk, "k"));
    try testing.expect(f.sums.get(unk).refs_top and f.sums.get(unk).writes);
}

test "join is functional: the result owns its κ, the members keep theirs, and leq sees the change" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const env = f.env();
    const p1 = try f.param(0, 1, &.{});
    const p2 = try f.param(1, 1, &.{});
    const ra = try f.leaf(1, &.{p1});
    const rb = try f.leaf(1, &.{ p1, p2 });
    const ma = try f.setK(.none, ra, Cond.lost);
    const mb = try f.setK(.none, rb, Cond.yes);
    const a = try f.sums.add(env, .{ .params = &.{ .none, .none }, .res = ra, .kappas = ma });
    const b = try f.sums.add(env, .{ .params = &.{ .none, .none }, .res = rb, .kappas = mb });
    // The reviewer's probe: the join's res IS b's node (b ⊒ a in shape);
    // its κ is lost in the JOIN's map, b's map still says yes, and b is
    // strictly below the join.
    const j = try f.sums.join(env, a, b, .choice);
    try testing.expectEqual(rb, f.sums.get(j).res);
    try testing.expectEqual(Cond.lost, try env.kappa(f.sums.get(j).kappas, rb));
    try testing.expectEqual(Cond.yes, try env.kappa(f.sums.get(b).kappas, rb));
    try testing.expect(try f.sums.leq(env, b, j));
    try testing.expect(!try f.sums.leq(env, j, b));
    try testing.expect(try f.sums.leq(env, a, j));
    try testing.expect(!try f.sums.leq(env, a, b));
    try testing.expectEqual(j, try f.sums.join(env, j, j, .choice));
    try testing.expect(try f.sums.eq(env, j, try f.sums.join(env, b, a, .choice)));
}

test "join and leq: uses, funs by label, supplies merged in one pass, bits" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const env = f.env();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    const p1 = try f.param(0, 1, &.{});
    const fresh1 = try f.fresh(1, 1);
    const ua = try Table.markUse(env, .none, list, &.{}, .{ .r = true }, &.{});
    const ub = try Table.markUse(env, .none, list, &.{}, .{ .r = true, .a = true, .w = true }, &.{});
    const ra = try f.leaf(1, &.{fresh1});
    const rb = try f.leaf(1, &.{p1});
    const e1 = try f.conds.excl(gpa, env.charge, p1);
    const l3 = try f.label(3);
    const l7 = try f.label(7);
    const sup_a: Supply = .{ .j = 1, .k = 0, .node = rb, .label = l3, .owned = true, .taken = false, .kappa = .none };
    const sup_b: Supply = .{ .j = 1, .k = 0, .node = rb, .label = l3, .owned = false, .taken = false, .kappa = try f.setK(.none, rb, e1) };
    const sup_other: Supply = .{ .j = 1, .k = 0, .node = rb, .label = l7, .owned = true, .taken = false, .kappa = .none };
    const a = try f.sums.add(env, .{ .params = &.{ua}, .res = ra, .funs = &.{.{ .j = 1, .calls = .once, .supplies = &.{sup_a} }} });
    const b = try f.sums.add(env, .{ .params = &.{ub}, .res = rb, .xreq = try f.conds.flat(gpa, env.charge, e1), .funs = &.{ .{ .j = 1, .calls = .many, .need = true, .seen = false }, .{ .j = 2, .calls = .zero } }, .writes = true });
    const j = try f.sums.join(env, a, b, .choice);
    const jc = f.sums.get(j);
    try testing.expectEqual(Marks{ .r = true, .a = true, .w = true }, try Table.marksAt(env, f.sums.paramUses(j)[0], &.{}));
    try testing.expectEqual(@as(u32, 2), f.cells.sets.count(f.shapes.cells(jc.res)));
    try testing.expect(jc.writes);
    try testing.expectEqual(jc.xreq, f.sums.get(b).xreq);
    try testing.expectEqual(@as(u32, 2), f.sums.funCount(j));
    const f1 = f.sums.fun(j, 0);
    try testing.expectEqual(@as(u32, 1), f1.j);
    try testing.expectEqual(Calls.many, f1.calls);
    try testing.expect(f1.need and !f1.seen);
    try testing.expectEqual(@as(u32, 1), f1.supplies.len);
    try testing.expectEqual(@as(u32, 2), f.sums.fun(j, 1).j);
    try testing.expect(try f.sums.leq(env, a, j));
    try testing.expect(try f.sums.leq(env, b, j));
    try testing.expect(!try f.sums.leq(env, j, a));
    // One label's supply in both: owned and-ed, κ joined. Another label:
    // kept beside, never merged (§2.2).
    const c = try f.sums.add(env, .{ .params = &.{ua}, .res = ra, .funs = &.{.{ .j = 1, .calls = .once, .supplies = &.{ sup_other, sup_b } }} });
    const ac = try f.sums.join(env, a, c, .choice);
    const fac = f.sums.fun(ac, 0);
    try testing.expectEqual(@as(u32, 2), fac.supplies.len);
    const s0 = f.sums.supply(fac, 0);
    try testing.expectEqual(l3, s0.label);
    try testing.expect(!s0.owned);
    try testing.expectEqual(e1, try env.kappa(s0.kappa, s0.node));
    try testing.expectEqual(l7, f.sums.supply(fac, 1).label);
    try testing.expect(try f.sums.leq(env, a, ac));
    try testing.expect(!try f.sums.leq(env, ac, a));
}

test "normal form: equal classes built in another order are byte-equal, storage order never shows; a flipped bit is not" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const env = f.env();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    const p1 = try f.param(0, 1, &.{});
    const p2 = try f.param(1, 1, &.{});
    const u = try Table.markUse(env, .none, list, &.{}, .{ .r = true }, &.{});
    const r = try f.leaf(1, &.{ p1, p2 });
    const n1 = try f.leaf(1, &.{p1});
    const n2 = try f.leaf(1, &.{p2});
    const s1: Supply = .{ .j = 2, .k = 0, .node = n1, .label = .none, .owned = true, .taken = false, .kappa = .none };
    const s2: Supply = .{ .j = 2, .k = 1, .node = n2, .label = .none, .owned = true, .taken = true, .kappa = .none };
    const a = try f.sums.add(env, .{ .params = &.{ u, u, .none }, .res = r, .funs = &.{ .{ .j = 2, .calls = .many, .supplies = &.{ s1, s2 } }, .{ .j = 3, .calls = .zero } } });
    const b = try f.sums.add(env, .{ .params = &.{ u, u, .none }, .res = r, .funs = &.{ .{ .j = 3, .calls = .zero }, .{ .j = 2, .calls = .many, .supplies = &.{ s2, s1 } } } });
    try testing.expect(a != b);
    try testing.expect(try f.sums.eq(env, a, b));
    // The reviewer's probe: two supplies sharing one node, given in either
    // order, spell the same.
    const x = try f.leaf(1, &.{try f.fresh(7, 1)});
    const t0: Supply = .{ .j = 1, .k = 0, .node = x, .label = .none, .owned = true, .taken = false, .kappa = .none };
    const t1: Supply = .{ .j = 1, .k = 1, .node = x, .label = .none, .owned = true, .taken = false, .kappa = .none };
    const nothing = try f.shapes.nothing(gpa, &f.account, list);
    const sa = try f.sums.add(env, .{ .params = &.{ .none, .none }, .res = nothing, .funs = &.{.{ .j = 1, .calls = .many, .supplies = &.{ t0, t1 } }} });
    const sb = try f.sums.add(env, .{ .params = &.{ .none, .none }, .res = nothing, .funs = &.{.{ .j = 1, .calls = .many, .supplies = &.{ t1, t0 } }} });
    try testing.expect(try f.sums.eq(env, sa, sb));
    var s1b = s1;
    s1b.owned = false;
    const c = try f.sums.add(env, .{ .params = &.{ u, u, .none }, .res = r, .funs = &.{ .{ .j = 2, .calls = .many, .supplies = &.{ s1b, s2 } }, .{ .j = 3, .calls = .zero } } });
    try testing.expect(!try f.sums.eq(env, a, c));
    // κ is part of the form, read from each class's own map.
    const m = try f.setK(.none, r, Cond.lost);
    const d = try f.sums.add(env, .{ .params = &.{ u, u, .none }, .res = r, .kappas = m, .funs = &.{ .{ .j = 2, .calls = .many, .supplies = &.{ s1, s2 } }, .{ .j = 3, .calls = .zero } } });
    try testing.expect(!try f.sums.eq(env, a, d));
}

test "a refused reservation adds no class" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const list = try f.placeOf(1);
    const r = try f.shapes.nothing(testing.allocator, &f.account, list);
    var broke: Ids.Account = .{ .allowance = 0 };
    defer broke.deinit(testing.allocator);
    var env = f.env();
    env.charge = .growth(&broke);
    try testing.expectError(error.OwnershipLimit, f.sums.add(env, .{ .params = &.{}, .res = r }));
    try testing.expectEqual(@as(u32, 0), f.sums.count());
    try testing.expectEqual(@as(usize, 0), f.sums.uses.items.len);
}

test "repeated-node simulation: one DAG node against two partners, and a join that reuses an operand's shape" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const env = f.env();
    const gpa = testing.allocator;
    const rec = try f.placeOf(0);
    const fa = try Place.Step.field(&f.account, 10);
    const fb = try Place.Step.field(&f.account, 11);
    const p3 = try f.param(2, 1, &.{});
    const p4 = try f.param(3, 1, &.{});
    const p5 = try f.param(4, 1, &.{});
    const x = try f.leaf(1, &.{p3});
    const y_good = try f.leaf(1, &.{ p3, p4 });
    const y_bad = try f.leaf(1, &.{ p3, p5 });
    const e = try f.conds.excl(gpa, env.charge, p4);
    const s1 = try f.cells.result(gpa, &f.account, .result, .none, 1, rec, .record);
    // `a = { a = X, b = X }`: one node X at two paths, κ(X) = excl in a's map.
    const ra = try f.shapes.node(gpa, &f.account, rec, try f.set(&.{s1}), try f.shapes.overPut(gpa, &f.account, try f.shapes.overPut(gpa, &f.account, Ids.none_int, fa, x), fb, x));
    var ma = try f.setKPath(.none, &.{fa}, x, e);
    ma = try f.setKPath(ma, &.{fb}, x, e);
    ma = try f.setK(ma, ra, Cond.yes);
    const a = try f.sums.add(env, .{ .params = &.{}, .res = ra, .kappas = ma });
    // `b = { a = Y_bad, b = Y_good }` in either order: X meets two partners
    // and must be checked against both; κ(Y_bad) defaults to yes, so a ⊑ b
    // is false whichever side holds Y_bad.
    for ([_][2]NodeId{ .{ y_bad, y_good }, .{ y_good, y_bad } }) |pair| {
        const rb = try f.shapes.node(gpa, &f.account, rec, try f.set(&.{s1}), try f.shapes.overPut(gpa, &f.account, try f.shapes.overPut(gpa, &f.account, Ids.none_int, fa, pair[0]), fb, pair[1]));
        var mb = try f.setKPath(.none, &.{if (pair[0] == y_good) fa else fb}, y_good, e);
        mb = try f.setK(mb, rb, Cond.yes);
        const b = try f.sums.add(env, .{ .params = &.{}, .res = rb, .kappas = mb });
        try testing.expect(!try f.sums.leq(env, a, b));
    }
    // A join whose result reuses an operand's shape (b's node IS the join's
    // node): the join owns a new snapshot, b's is untouched, and b ⊑ join
    // strictly.
    const rc = try f.leaf(1, &.{ p3, p4, p5 });
    const c = try f.sums.add(env, .{ .params = &.{}, .res = rc, .kappas = try f.setK(.none, rc, Cond.yes) });
    const d = try f.sums.add(env, .{ .params = &.{}, .res = try f.leaf(1, &.{p3}), .kappas = try f.setK(.none, try f.leaf(1, &.{p3}), Cond.lost) });
    const j = try f.sums.join(env, d, c, .choice);
    try testing.expectEqual(rc, f.sums.get(j).res);
    try testing.expectEqual(Cond.lost, try env.kappa(f.sums.get(j).kappas, rc));
    try testing.expectEqual(Cond.yes, try env.kappa(f.sums.get(c).kappas, rc));
    try testing.expect(try f.sums.leq(env, c, j));
    try testing.expect(!try f.sums.leq(env, j, c));
    // A supply's snapshot is the handed value's own: two classes handing one
    // node under two snapshots join into a third snapshot, the operands'
    // untouched.
    const kx_yes = try f.setK(.none, x, Cond.yes);
    const kx_lost = try f.setK(.none, x, Cond.lost);
    const sa = try f.sums.add(env, .{ .params = &.{}, .res = rc, .funs = &.{.{ .j = 1, .calls = .once, .supplies = &.{.{ .j = 1, .k = 0, .node = x, .label = .none, .owned = true, .taken = false, .kappa = kx_yes }} }} });
    const sb = try f.sums.add(env, .{ .params = &.{}, .res = rc, .funs = &.{.{ .j = 1, .calls = .once, .supplies = &.{.{ .j = 1, .k = 0, .node = x, .label = .none, .owned = true, .taken = false, .kappa = kx_lost }} }} });
    const sj = try f.sums.join(env, sa, sb, .choice);
    const sup = f.sums.supply(f.sums.fun(sj, 0), 0);
    try testing.expectEqual(Cond.lost, try env.kappa(sup.kappa, x));
    try testing.expectEqual(Cond.yes, try env.kappa(kx_yes, x));
    try testing.expect(try f.sums.leq(env, sa, sj));
    try testing.expect(!try f.sums.leq(env, sj, sa));
}

test "fault injection: a join refused at any step leaves the class table whole" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const env = f.env();
    const list = try f.placeOf(1);
    const p1 = try f.param(0, 1, &.{});
    const p2 = try f.param(1, 1, &.{});
    const ua = try Table.markUse(env, .none, list, &.{}, .{ .r = true }, &.{});
    const ub = try Table.markUse(env, .none, list, &.{}, .{ .w = true }, &.{});
    const ra = try f.leaf(1, &.{p1});
    const rb = try f.leaf(1, &.{p2});
    const a = try f.sums.add(env, .{ .params = &.{ua}, .res = ra, .funs = &.{.{ .j = 1, .calls = .once, .supplies = &.{.{ .j = 1, .k = 0, .node = ra, .label = .none, .owned = true, .taken = false, .kappa = .none }} }} });
    const b = try f.sums.add(env, .{ .params = &.{ub}, .res = rb, .funs = &.{.{ .j = 1, .calls = .many, .supplies = &.{.{ .j = 1, .k = 0, .node = rb, .label = .none, .owned = false, .taken = false, .kappa = .none }} }} });
    var allowance: u32 = 0;
    while (allowance < 4000) : (allowance += 1) {
        var broke: Ids.Account = .{ .allowance = allowance };
        defer broke.deinit(gpa);
        var tight = env;
        tight.charge = .growth(&broke);
        const classes = f.sums.count();
        const uses = f.sums.uses.items.len;
        const supplies = f.sums.supplies.len;
        if (f.sums.join(tight, a, b, .choice)) |j| {
            try testing.expectEqual(classes + 1, f.sums.count());
            try testing.expect(try f.sums.leq(env, a, j));
            break;
        } else |err| {
            try testing.expectEqual(error.OwnershipLimit, err);
            try testing.expectEqual(classes, f.sums.count());
            try testing.expectEqual(uses, f.sums.uses.items.len);
            try testing.expectEqual(supplies, f.sums.supplies.len);
        }
    }
    try testing.expect(allowance < 4000);
}

test "#1138: a summary as deep as the source is spelled, printed and marked on explicit stacks" {
    // On a thread with a small stack (256 KiB): a native frame per level
    // would overflow it.
    var result: anyerror!void = {};
    const th = try std.Thread.spawn(.{ .stack_size = 256 << 10 }, struct {
        fn run(out: *anyerror!void) void {
            out.* = deepSummary();
        }
    }.run, .{&result});
    th.join();
    try result;
}

fn deepSummary() !void {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.account.allowance = std.math.maxInt(u32) - 1;
    const gpa = testing.allocator;
    const env = f.env();
    const lst = try f.placeOf(5);
    const depth = 1_000;
    // `res`: lists of lists, `depth` levels, each its own site.
    var n = try f.shapes.leaf(gpa, &f.account, lst, .none);
    for (0..depth) |i| {
        const s = try f.cells.site(gpa, &f.account, @intCast(i + 1), lst, .list);
        n = try f.shapes.node(gpa, &f.account, lst, try f.set(&.{s}), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Step.elem, n));
    }
    // A use `depth` steps down.
    const steps = try gpa.alloc(Step, depth);
    defer gpa.free(steps);
    @memset(steps, Step.elem);
    const use = try Table.markUse(env, .none, lst, steps, .{ .r = true }, &.{});
    const c = try f.sums.add(env, .{ .params = &.{use}, .res = n });
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(gpa);
    try f.sums.normalize(env, c, &words);
    try testing.expect(words.items.len > depth);
    var buf: std.Io.Writer.Allocating = .init(f.arena.allocator());
    try f.sums.print(env, f.arena.allocator(), &buf.writer, c, "deep", test_names);
    try testing.expect(std.mem.count(u8, buf.written(), "[*]") > depth);
}

test "#1094: two classes that differ only in a κ stored below a leaf `res` are not equal" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const env = f.env();
    const gpa = testing.allocator;
    // Q7: `res` a leaf at `List (List Int)`, one class storing `shared` at
    // `res[*]`, the other nothing. Their parts are the same; the stored κ is
    // observable at the projection (§2.9), so `eq` (`leq` both ways) tells
    // them apart.
    const p1 = try f.param(0, 3, &.{});
    const u = try Table.markUse(env, .none, try f.placeOf(3), &.{}, .{ .r = true }, &.{});
    const r = try f.leaf(3, &.{p1});
    const below = (try f.shapes.proj(gpa, env.account(), &f.places, &f.cells, r, Place.Step.elem)).?;
    const k = try f.conds.kappaSetAt(gpa, env.charge, .none, &.{Place.Step.elem}, below, Cond.shared);
    const stored = try f.sums.add(env, .{ .params = &.{u}, .res = r, .kappas = k });
    const plain = try f.sums.add(env, .{ .params = &.{u}, .res = r, .kappas = .none });
    try testing.expect(try f.sums.leq(env, plain, stored));
    try testing.expect(!try f.sums.leq(env, stored, plain));
    try testing.expect(!try f.sums.eq(env, stored, plain));
    try testing.expect(try f.sums.eq(env, stored, stored));
}

test "a port join that drops a covered arm keeps the joined entries below the root (#1459's review)" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const env = f.env();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    const lol = try f.placeOf(3);
    const elem = &[_]Step{Place.Step.elem};
    const built = struct {
        fn of(fx: *Fixture, place: PlaceId, k: u32, child: ?NodeId) !NodeId {
            const over: u32 = if (child) |c| try fx.shapes.overPut(testing.allocator, &fx.account, Ids.none_int, Place.Step.elem, c) else Ids.none_int;
            return fx.shapes.node(testing.allocator, &fx.account, place, try fx.set(&.{try fx.cells.site(testing.allocator, &fx.account, k, place, .list)}), over);
        }
    }.of;
    // Three built lists, and three lists of them: `x = [a]`, `u = [a | b]`
    // (an element either list), `big = [a | c]`.
    const a = try built(&f, list, 1, null);
    const b = try built(&f, list, 2, null);
    const c = try built(&f, list, 3, null);
    const x = try built(&f, lol, 4, a);
    // One allocation site, as a group's rounds have.
    const u = try built(&f, lol, 4, try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, a, b));
    const big = try built(&f, lol, 4, try f.shapes.@"union"(gpa, &f.account, &f.cells.sets, a, c));
    // `x` certifies `a` at `[*]`; `u` only `b`, so its `[*]` reads `lost`;
    // `big` certifies both of its.
    var kx = try f.setK(.none, x, Cond.yes);
    kx = try f.conds.kappaSetAt(gpa, env.charge, kx, elem, a, Cond.yes);
    var ku = try f.setK(.none, u, Cond.yes);
    ku = try f.conds.kappaSetAt(gpa, env.charge, ku, elem, b, Cond.yes);
    var kb = try f.setK(.none, big, Cond.yes);
    kb = try f.conds.kappaSetAt(gpa, env.charge, kb, elem, a, Cond.yes);
    kb = try f.conds.kappaSetAt(gpa, env.charge, kb, elem, c, Cond.yes);
    const p = try Table.joinRes(env, x, kx, u, ku, .choice);
    const q = try Table.joinClassRes(env, p.node, p.kappas, big, kb, .choice);
    // A round that covers one arm drops it; the kept arm's `[*]` still reads
    // as the join did, never the certificate merged in from the dropped arm.
    const at = f.conds.kappaAlong(q.kappas, elem);
    const k = try env.conds.kappaOf(gpa, env.charge, env.view(), at, (try f.shapes.proj(gpa, &f.account, &f.places, &f.cells, q.node, Place.Step.elem)).?, true);
    try testing.expect(Cond.Table.fails(k));
}

test "a port join's cover test reads an arm with the join's entries carried to it (#1459's review)" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const env = f.env();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    const lol = try f.placeOf(3);
    const elem = &[_]Step{Place.Step.elem};
    const built = struct {
        fn of(fx: *Fixture, place: PlaceId, k: u32, child: ?NodeId) !NodeId {
            const over: u32 = if (child) |c| try fx.shapes.overPut(testing.allocator, &fx.account, Ids.none_int, Place.Step.elem, c) else Ids.none_int;
            return fx.shapes.node(testing.allocator, &fx.account, place, try fx.set(&.{try fx.cells.site(testing.allocator, &fx.account, k, place, .list)}), over);
        }
    }.of;
    const un = struct {
        fn of(fx: *Fixture, xs: []const NodeId) !NodeId {
            var out = xs[0];
            for (xs[1..]) |x| out = try fx.shapes.@"union"(testing.allocator, &fx.account, &fx.cells.sets, out, x);
            return out;
        }
    }.of;
    const a = try built(&f, list, 1, null);
    const b = try built(&f, list, 2, null);
    const c = try built(&f, list, 3, null);
    const d = try built(&f, list, 5, null);
    // `x = [a]` certifies `a`; `u = [a | b]` only `b`; `big = [a | c | d]`
    // all; `v = [b]`. One outer allocation site.
    const x = try built(&f, lol, 4, a);
    const u = try built(&f, lol, 4, try un(&f, &.{ a, b }));
    const big = try built(&f, lol, 4, try un(&f, &.{ a, c, d }));
    const v = try built(&f, lol, 4, b);
    const cert = struct {
        fn of(fx: *Fixture, outer: NodeId, inner: []const NodeId) !Kappas {
            var k = try fx.setK(.none, outer, Cond.yes);
            for (inner) |n| k = try fx.conds.kappaSetAt(testing.allocator, fx.env().charge, k, &.{Place.Step.elem}, n, Cond.yes);
            return k;
        }
    }.of;
    const p1 = try Table.joinRes(env, x, try cert(&f, x, &.{a}), u, try cert(&f, u, &.{b}), .choice);
    const bb = try Table.joinRes(env, big, try cert(&f, big, &.{ a, c, d }), v, try cert(&f, v, &.{b}), .choice);
    const q3 = try Table.joinClassRes(env, p1.node, p1.kappas, bb.node, bb.kappas, .choice);
    // `u` read under `p1`'s merged snapshot alone borrows `a`'s certificate
    // from `x` and reads `yes`; the join's `[*]` reads `lost`. So `u` is no
    // arm `bb` covers, and `q3`'s `[*]` keeps that `lost`.
    const at = f.conds.kappaAlong(q3.kappas, elem);
    const k = try env.conds.kappaOf(gpa, env.charge, env.view(), at, (try f.shapes.proj(gpa, &f.account, &f.places, &f.cells, q3.node, Place.Step.elem)).?, true);
    try testing.expect(Cond.Table.fails(k));
}

const v2_mutation = @import("ownership_options").v2_mutation;

/// A test-only mutation (`-Downership-v2-mutation`, which `gates` refuses).
fn mutated(comptime which: []const u8) bool {
    return std.mem.eql(u8, v2_mutation, which);
}
