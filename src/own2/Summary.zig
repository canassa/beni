//! L5: classes and summaries (`docs/design/ownership-v2.md` §2.10, §3.5). A
//! class describes a function type's behaviour over `π₁…πₙ`, `ρ`; a summary
//! is a declaration's class. A class names no declaration (#587's room).
//!
//! | field     | content |
//! |-----------|---------|
//! | `use(i)`  | a shape over πᵢ's places whose cells are `mark`s: `R`, `A`, `E`, `W`, `S` (deep) and `W{f}` per written field. A `node` of marks labels its own path, a LEAF of marks every path below it (a deep read or write): `Shape.proj` carries marks down a leaf as it carries `⊤`, so "`U` non-empty at the remainder of `q`" (§2.7) is one `cellsAt` |
//! | `res`     | a shape over ρ's places whose cells are provenances; κ per node in `Cond`'s column |
//! | `xreq`    | the flat atom set the body relied on |
//! | `fun(j)`  | `calls`, `need`, `seen`, the supplies (`Facts.Supply`, with κ) and keep edges; `j ≥ params` names a function SLOT, a function at a path of a parameter (`slots`) |
//! | `classes` | the summary-local class table (closures carried in `res`/supplies: S4) |
//! | `refs`, `slots` (handles) | S8 |
//! | `writes`, `once`, `entry`, `origin` | one bit each; where the class came from (`inferred`, `words`, `asserted`, `unknown`) |
//!
//! **Lattice** (§2.10): pointwise. Use and `res` shapes by `Shape.leq`/`join`
//! after widening; κ per `res` node by `Cond.propagate` where the shapes
//! join (O15: `Shape.join` knows no κ); `owned ⊑ borrowed`; `calls 0 ⊑ ≤1 ⊑
//! many`; `seen` yes ⊑ no; xreq by inclusion; κ of a supply by `Cond.join`.
//!
//! **Normal form** (§3.5): `normalize` writes a class as words with every
//! node numbered by one canonical DFS (children in step order) and a node
//! met again a backreference, cells spelled out by origin and canonical
//! path, sets and atoms sorted by their own spelling. Two classes are `eq`
//! when their words are. Places are this module's ids and a union's sides
//! are in id order — deterministic within a build (§3.8), structural across
//! modules only through `Block` (S6), which maps places structurally and
//! sorts sides by spelling. Fresh numbering by result path is the
//! read-off's (S3a); `normalize` encodes what it is given.
//!
//! **Text**: `print` reproduces v1's `summary` grammar (oc §16.11): the
//! parameters' bits by path, `res` grouped by path with `~` for an
//! approximate pair and the path's κ in braces, each function parameter's
//! `calls`/`need`/`unseen`/supplies, `xreq`, `(words)`/`(asserted)`.
//!
//! Every record (a class, a fun, a supply, a keep, a slot, a use node) is
//! reserved on the caller's `Charge` before it exists, and so is every
//! node a join, an inclusion test or a normalisation visits (§4.1).
//!
//! Obligations kept here: O5's lattice half (a join covers both classes:
//! every field joined pointwise, κ by `Cond.propagate`), O15 (κ of a joined
//! `res` is the join of the members' at every path).

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
/// (`seen`), what it is handed and what it keeps.
pub const Fun = struct {
    j: u32,
    calls: Calls,
    need: bool,
    seen: bool,
    supplies: Ids.Range,
    keeps: Ids.Range,
};

/// A function slot (oc §24.9): a function at `path` of parameter `param`,
/// named as `fun(params + k)`.
pub const Slot = struct { param: u32, path: PathId };

pub const Class = struct {
    /// Per parameter its use shape: a run of `uses`.
    params: Ids.Range,
    res: NodeId,
    xreq: SetId,
    funs: Ids.Range,
    slots: Ids.Range,
    classes: Ids.Range,
    /// The function-typed result places the class makes once closures at
    /// (§2.10): a run of `onces`.
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
    _pad: u3 = 0,

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
};

/// How names print (§3.8: never an id): a field by its text rank, a
/// constructor by `(constructor, argument)`, a top-level value by
/// `(module, declaration)`.
pub const Names = struct {
    ctx: *anyopaque,
    field: *const fn (ctx: *anyopaque, rank: u32) []const u8,
    ctor: *const fn (ctx: *anyopaque, c: u32, i: u32) []const u8,
    decl: *const fn (ctx: *anyopaque, module: u32, decl: u32) []const u8,
};

/// What `add` takes: a class in pieces.
pub const Draft = struct {
    params: []const NodeId,
    res: NodeId,
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

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.classes.deinit(gpa);
        t.uses.deinit(gpa);
        t.funs.deinit(gpa);
        t.supplies.deinit(gpa);
        t.keeps.deinit(gpa);
        t.slots.deinit(gpa);
        t.nested.deinit(gpa);
        t.onces.deinit(gpa);
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
    /// before anything is appended. Funs are stored sorted by `j`.
    pub fn add(t: *Table, env: Env, d: Draft) Error!ClassId {
        var n: u32 = 1 + @as(u32, @intCast(d.params.len + d.funs.len + d.slots.len + d.classes.len + d.once.len));
        for (d.funs) |f| n += @intCast(f.supplies.len + f.keeps.len);
        try env.charge.reserve(env.gpa, .class, n);
        const gpa = env.gpa;
        const params: Ids.Range = .{ .start = @intCast(t.uses.items.len), .len = @intCast(d.params.len) };
        try t.uses.appendSlice(gpa, d.params);
        // Funs in `j` order: sort a scratch index.
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
            const kr: Ids.Range = .{ .start = @intCast(t.keeps.len), .len = @intCast(f.keeps.len) };
            for (f.keeps) |k| try t.keeps.append(gpa, k);
            try t.funs.append(gpa, .{ .j = f.j, .calls = f.calls, .need = f.need, .seen = f.seen, .supplies = sr, .keeps = kr });
        }
        const slots: Ids.Range = .{ .start = @intCast(t.slots.len), .len = @intCast(d.slots.len) };
        for (d.slots) |s| try t.slots.append(gpa, s);
        const classes: Ids.Range = .{ .start = @intCast(t.nested.items.len), .len = @intCast(d.classes.len) };
        try t.nested.appendSlice(gpa, d.classes);
        const once: Ids.Range = .{ .start = @intCast(t.onces.items.len), .len = @intCast(d.once.len) };
        try t.onces.appendSlice(gpa, d.once);
        const id: ClassId = .from(t.count());
        try t.classes.append(gpa, .{
            .params = params,
            .res = d.res,
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

    /// `⊤call` (§2.11, R-5.5.4): every parameter `RAEW` deep, the result
    /// `⊤` with κ `lost`, every function parameter in `fun_params` called
    /// many times, unseen, its result needed; `refs` top; writes.
    pub fn unknown(t: *Table, env: Env, param_places: []const PlaceId, fun_params: []const u32, res_place: PlaceId) Error!ClassId {
        const gpa = env.gpa;
        var params: std.ArrayList(NodeId) = .empty;
        defer params.deinit(gpa);
        const all = try marksSet(env, .{ .r = true, .a = true, .e = true, .w = true, .deep = true }, &.{});
        for (param_places) |p| try params.append(gpa, try env.shapes.leaf(gpa, env.account(), p, all));
        const top = try env.cells.top(gpa, env.account());
        const res = try env.shapes.leaf(gpa, env.account(), res_place, try env.cells.sets.insert(gpa, env.charge, .none, top.int(), 0));
        _ = try env.conds.setKappa(gpa, env.charge, res, Cond.lost);
        var funs: std.ArrayList(DraftFun) = .empty;
        defer funs.deinit(gpa);
        for (fun_params) |j| try funs.append(gpa, .{ .j = j, .calls = .many, .need = true, .seen = false });
        return t.add(env, .{ .params = params.items, .res = res, .funs = funs.items, .refs_top = true, .writes = true, .origin = .unknown });
    }

    // ---- use shapes ---------------------------------------------------------------

    /// The set of mark cells for `m` and the written fields' ranks.
    pub fn marksSet(env: Env, m: Marks, fields: []const u32) Error!SetId {
        var s: SetId = .none;
        inline for (.{ .{ m.r, Cell.Mark.r }, .{ m.a, Cell.Mark.a }, .{ m.e, Cell.Mark.e }, .{ m.w, Cell.Mark.w }, .{ m.deep, Cell.Mark.deep } }) |pair| {
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

    fn markAt(env: Env, n: NodeId, place: PlaceId, steps: []const Step, marks: SetId, deep: bool) Error!NodeId {
        const gpa = env.gpa;
        try env.charge.reserve(gpa, .shape, 1);
        const here: SetId = if (n == .none) .none else env.shapes.cells(n);
        if (n != .none and env.shapes.kind(n) == .leaf and here != .none) {
            // A deep leaf covers this path and everything below: join.
            return env.shapes.leaf(gpa, env.account(), place, try env.cells.sets.unionWith(gpa, env.charge, here, marks));
        }
        if (steps.len == 0) {
            const c = try env.cells.sets.unionWith(gpa, env.charge, here, marks);
            if (deep) return env.shapes.leaf(gpa, env.account(), place, c);
            if (n == .none or env.shapes.kind(n) == .leaf) return env.shapes.node(gpa, env.account(), place, c, Ids.none_int);
            return env.shapes.withCells(gpa, env.account(), env.places, env.cells, n, c);
        }
        const s = steps[0];
        const child_place = env.places.child(place, s) orelse unreachable;
        var child: NodeId = .none;
        if (n != .none and env.shapes.kind(n) == .node) {
            if (env.shapes.overGet(env.shapes.get(n).a, s)) |c| child = c;
        }
        const new_child = try markAt(env, child, child_place, steps[1..], marks, deep);
        const children: u32 = if (n != .none and env.shapes.kind(n) == .node) env.shapes.get(n).a else Ids.none_int;
        return env.shapes.node(gpa, env.account(), place, here, try env.shapes.overPut(gpa, env.account(), children, s, new_child));
    }

    /// The marks at `steps` of a use shape: the node's own, plus `deep`
    /// from a leaf on the way (whose marks hold below it). Empty when the
    /// path is not used. One record per step.
    pub fn marksAt(env: Env, use: NodeId, steps: []const Step) Error!Marks {
        var at = use;
        var m: Marks = .{};
        if (at == .none) return m;
        for (steps) |s| {
            try env.charge.reserve(env.gpa, .inspection, 1);
            at = (try env.shapes.proj(env.gpa, env.account(), env.places, env.cells, at, s)) orelse return m;
        }
        var it = env.cells.sets.iterate(env.shapes.cells(at));
        while (it.next()) |e| {
            const c: CellId = .from(e.key);
            if (env.cells.origin(c) != .mark) continue;
            switch (env.cells.markOf(c)) {
                .r => m.r = true,
                .a => m.a = true,
                .e => m.e = true,
                .w => m.w = true,
                .deep => m.deep = true,
                .field => {},
            }
        }
        return m;
    }

    /// Whether a callee's use shape names anything at or below `steps`
    /// (§2.7's lazy `call` use): `cellsAt` non-empty.
    pub fn usedAt(env: Env, use: NodeId, steps: []const Step) Error!bool {
        if (use == .none) return false;
        return (try env.shapes.cellsAt(env.gpa, env.account(), env.places, env.cells, use, steps)) != .none;
    }

    // ---- the lattice -------------------------------------------------------------

    /// The pointwise join of two classes over one signature (§2.10): use
    /// and `res` shapes by `Shape.join` then `widen`, κ by `Cond.propagate`
    /// (O15), xreq by union, funs by `j` (calls max, need or, seen and,
    /// supplies united with `owned` and-ed and κ joined, keeps united),
    /// nested classes pointwise, bits or-ed. Every visited record charged.
    pub fn join(t: *Table, env: Env, a: ClassId, b: ClassId) Error!ClassId {
        if (a == b) return a;
        const gpa = env.gpa;
        const ca = t.get(a);
        const cb = t.get(b);
        std.debug.assert(ca.params.len == cb.params.len and ca.slots.len == cb.slots.len);
        try env.charge.reserve(gpa, .class, 1);
        var params: std.ArrayList(NodeId) = .empty;
        defer params.deinit(gpa);
        for (t.paramUses(a), t.paramUses(b)) |ua, ub| try params.append(gpa, try joinUse(env, ua, ub));
        const res = try joinRes(env, ca.res, cb.res);
        const xreq = try env.conds.atoms.unionWith(gpa, env.charge, ca.xreq, cb.xreq);
        // Funs: both runs sorted by `j`, merged.
        var funs: std.ArrayList(DraftFun) = .empty;
        defer funs.deinit(gpa);
        var sup_store: std.ArrayList(Supply) = .empty;
        defer sup_store.deinit(gpa);
        var keep_store: std.ArrayList(Keep) = .empty;
        defer keep_store.deinit(gpa);
        var i: u32 = 0;
        var j: u32 = 0;
        var merged: std.ArrayList(struct { f: DraftFun, sup_start: u32, sup_len: u32, keep_start: u32, keep_len: u32 }) = .empty;
        defer merged.deinit(gpa);
        while (i < ca.funs.len or j < cb.funs.len) {
            try env.charge.reserve(gpa, .class, 1);
            const fa: ?Fun = if (i < ca.funs.len) t.fun(a, i) else null;
            const fb: ?Fun = if (j < cb.funs.len) t.fun(b, j) else null;
            const sup_start: u32 = @intCast(sup_store.items.len);
            const keep_start: u32 = @intCast(keep_store.items.len);
            var f: DraftFun = undefined;
            if (fb == null or (fa != null and fa.?.j < fb.?.j)) {
                f = .{ .j = fa.?.j, .calls = fa.?.calls, .need = fa.?.need, .seen = fa.?.seen };
                try t.copySupplies(env, fa.?, &sup_store, &keep_store);
                i += 1;
            } else if (fa == null or fb.?.j < fa.?.j) {
                f = .{ .j = fb.?.j, .calls = fb.?.calls, .need = fb.?.need, .seen = fb.?.seen };
                try t.copySupplies(env, fb.?, &sup_store, &keep_store);
                j += 1;
            } else {
                f = .{ .j = fa.?.j, .calls = fa.?.calls.join(fb.?.calls), .need = fa.?.need or fb.?.need, .seen = fa.?.seen and fb.?.seen };
                try t.copySupplies(env, fa.?, &sup_store, &keep_store);
                try t.mergeSupplies(env, fb.?, &sup_store, sup_start, &keep_store, keep_start);
                i += 1;
                j += 1;
            }
            try merged.append(gpa, .{ .f = f, .sup_start = sup_start, .sup_len = @intCast(sup_store.items.len - sup_start), .keep_start = keep_start, .keep_len = @intCast(keep_store.items.len - keep_start) });
        }
        for (merged.items) |m| {
            var f = m.f;
            f.supplies = sup_store.items[m.sup_start..][0..m.sup_len];
            f.keeps = keep_store.items[m.keep_start..][0..m.keep_len];
            try funs.append(gpa, f);
        }
        // Nested classes pointwise (S4 fills them; today both are empty or
        // of one length).
        var nested: std.ArrayList(ClassId) = .empty;
        defer nested.deinit(gpa);
        const na = t.nestedOf(a);
        const nb = t.nestedOf(b);
        std.debug.assert(na.len == nb.len);
        for (na, nb) |x, y| try nested.append(gpa, try t.join(env, x, y));
        var once: std.ArrayList(PathId) = .empty;
        defer once.deinit(gpa);
        try once.appendSlice(gpa, t.oncesOf(a));
        for (t.oncesOf(b)) |p| {
            if (std.mem.indexOfScalar(PathId, once.items, p) == null) try once.append(gpa, p);
        }
        var slots: std.ArrayList(Slot) = .empty;
        defer slots.deinit(gpa);
        for (0..ca.slots.len) |k| try slots.append(gpa, t.slot(a, @intCast(k)));
        return t.add(env, .{
            .params = params.items,
            .res = res,
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

    fn copySupplies(t: *const Table, env: Env, f: Fun, sup: *std.ArrayList(Supply), keeps: *std.ArrayList(Keep)) Error!void {
        for (0..f.supplies.len) |k| {
            try env.charge.reserve(env.gpa, .class, 1);
            try sup.append(env.gpa, t.supply(f, @intCast(k)));
        }
        for (0..f.keeps.len) |k| {
            try env.charge.reserve(env.gpa, .class, 1);
            try keeps.append(env.gpa, t.keepOf(f, @intCast(k)));
        }
    }

    /// `f`'s supplies and keeps merged into the runs starting at `sup_start`
    /// and `keep_start`: a supply of the same `(k, node, taken)` as one there
    /// joins it (`owned` and-ed, κ joined, the earlier point kept), else it
    /// is added; a keep already there is not added twice.
    fn mergeSupplies(t: *const Table, env: Env, f: Fun, sup: *std.ArrayList(Supply), sup_start: u32, keeps: *std.ArrayList(Keep), keep_start: u32) Error!void {
        for (0..f.supplies.len) |k| {
            try env.charge.reserve(env.gpa, .class, 1);
            const s = t.supply(f, @intCast(k));
            var found = false;
            for (sup.items[sup_start..]) |*e| {
                if (e.k != s.k or e.node != s.node or e.taken != s.taken) continue;
                e.owned = e.owned and s.owned;
                e.cond = try env.conds.join(env.gpa, env.charge, e.cond, s.cond);
                e.point = @min(e.point, s.point);
                found = true;
                break;
            }
            if (!found) try sup.append(env.gpa, s);
        }
        for (0..f.keeps.len) |k| {
            try env.charge.reserve(env.gpa, .class, 1);
            const x = t.keepOf(f, @intCast(k));
            var found = false;
            for (keeps.items[keep_start..]) |e| {
                if (e.j == x.j and e.k == x.k and e.kept_path == x.kept_path and e.written_path == x.written_path and e.writer == x.writer) {
                    found = true;
                    break;
                }
            }
            if (!found) try keeps.append(env.gpa, x);
        }
    }

    /// Two use shapes joined: `.none` is the empty use.
    pub fn joinUse(env: Env, a: NodeId, b: NodeId) Error!NodeId {
        if (a == b or b == .none) return a;
        if (a == .none) return b;
        var members = [_]NodeId{ a, b };
        return env.shapes.join(env.gpa, env.account(), env.places, env.cells, &members);
    }

    /// Two `res` shapes joined as alternatives, widened, κ propagated
    /// (O15). The join's κ is set from both members at every path; when
    /// widening changed the shape, the widened node's κ is set from the
    /// join's nodes it merged.
    pub fn joinRes(env: Env, a: NodeId, b: NodeId) Error!NodeId {
        if (a == b) return a;
        var members = [_]NodeId{ a, b };
        const j = try env.shapes.join(env.gpa, env.account(), env.places, env.cells, &members);
        try env.conds.propagate(env.gpa, env.charge, env.shapes, env.cells, env.places, j, &.{ a, b }, .alternatives, null);
        const w = try env.shapes.widen(env.gpa, env.account(), env.places, env.cells, j);
        if (w != j) try env.conds.propagate(env.gpa, env.charge, env.shapes, env.cells, env.places, w, &.{j}, .alternatives, null);
        return w;
    }

    /// `a ⊑ b` pointwise (§2.10): a stronger class below a weaker one.
    pub fn leq(t: *Table, env: Env, a: ClassId, b: ClassId) Error!bool {
        if (a == b) return true;
        const ca = t.get(a);
        const cb = t.get(b);
        if (ca.params.len != cb.params.len) return false;
        try env.charge.reserve(env.gpa, .inspection, 1);
        for (t.paramUses(a), t.paramUses(b)) |ua, ub| if (!try leqUse(env, ua, ub)) return false;
        if (!try env.shapes.leq(env.gpa, env.account(), env.places, env.cells, ca.res, cb.res)) return false;
        if (!try kappaLeq(env, ca.res, cb.res)) return false;
        if (!try env.conds.atoms.subset(env.gpa, env.charge, ca.xreq, cb.xreq)) return false;
        // Every fun of `a` under one of `b`.
        var j: u32 = 0;
        for (0..ca.funs.len) |i| {
            const fa = t.fun(a, @intCast(i));
            while (j < cb.funs.len and t.fun(b, j).j < fa.j) j += 1;
            if (j >= cb.funs.len or t.fun(b, j).j != fa.j) return false;
            const fb = t.fun(b, j);
            if (@backingInt(fa.calls) > @backingInt(fb.calls)) return false;
            if (fa.need and !fb.need) return false;
            if (fb.seen and !fa.seen) return false;
            for (0..fa.supplies.len) |k| {
                try env.charge.reserve(env.gpa, .inspection, 1);
                const s = t.supply(fa, @intCast(k));
                var found = false;
                for (0..fb.supplies.len) |m| {
                    const o = t.supply(fb, @intCast(m));
                    if (o.k != s.k or o.node != s.node or o.taken != s.taken) continue;
                    if (o.owned and !s.owned) continue;
                    if (!try env.conds.leq(env.gpa, env.charge, s.cond, o.cond)) continue;
                    found = true;
                    break;
                }
                if (!found) return false;
            }
            for (0..fa.keeps.len) |k| {
                try env.charge.reserve(env.gpa, .inspection, 1);
                const x = t.keepOf(fa, @intCast(k));
                var found = false;
                for (0..fb.keeps.len) |m| {
                    const y = t.keepOf(fb, @intCast(m));
                    if (x.j == y.j and x.k == y.k and x.kept_path == y.kept_path and x.written_path == y.written_path and x.writer == y.writer) {
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            }
        }
        const na = t.nestedOf(a);
        const nb = t.nestedOf(b);
        if (na.len != nb.len) return false;
        for (na, nb) |x, y| if (!try t.leq(env, x, y)) return false;
        for (t.oncesOf(a)) |p| if (std.mem.indexOfScalar(PathId, t.oncesOf(b), p) == null) return false;
        if (ca.refs_top and !cb.refs_top) return false;
        if (!cb.refs_top and !try env.cells.sets.subset(env.gpa, env.charge, ca.refs, cb.refs)) return false;
        if (ca.writes and !cb.writes) return false;
        return true;
    }

    fn leqUse(env: Env, a: NodeId, b: NodeId) Error!bool {
        if (a == b or a == .none) return true;
        if (b == .none) return false;
        return env.shapes.leq(env.gpa, env.account(), env.places, env.cells, a, b);
    }

    /// κ(a) ⊑ κ(b) at every node of `a`'s explicit structure, `b` projected
    /// in lockstep; a node once. One record per node and projection.
    pub fn kappaLeq(env: Env, a: NodeId, b: NodeId) Error!bool {
        const gpa = env.gpa;
        var seen: stamped.Column(NodeId, void) = .{};
        defer seen.deinit(gpa);
        var stack: std.ArrayList([2]NodeId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, .{ a, b });
        while (stack.pop()) |pair| {
            if (seen.contains(pair[0])) continue;
            try seen.put(gpa, pair[0], {});
            try env.charge.reserve(gpa, .inspection, 1);
            const ka = try env.conds.kappaOf(gpa, env.charge, env.shapes, env.cells, pair[0]);
            const kb = try env.conds.kappaOf(gpa, env.charge, env.shapes, env.cells, pair[1]);
            if (!try env.conds.leq(gpa, env.charge, ka, kb)) return false;
            const kind = env.shapes.kind(pair[0]);
            if (kind == .leaf or kind == .recast) continue;
            const steps = env.places.steps(env.shapes.place(pair[0]));
            for (steps.steps) |s| {
                const na = (try env.shapes.proj(gpa, env.account(), env.places, env.cells, pair[0], s)) orelse continue;
                if (env.shapes.kind(na) == .leaf and env.shapes.cells(na) == .none) continue;
                const nb = (try env.shapes.proj(gpa, env.account(), env.places, env.cells, pair[1], s)) orelse return false;
                try stack.append(gpa, .{ na, nb });
            }
        }
        return true;
    }

    // ---- normal form --------------------------------------------------------

    /// The class as words (header): one canonical DFS over `res` and the
    /// use shapes, nodes by first-visit ordinal with backreferences, cells
    /// spelled by origin and canonical path, sets and atoms sorted by their
    /// spelling. Appended to `out`; every node and cell visited is a record.
    pub fn normalize(t: *Table, env: Env, c: ClassId, out: *std.ArrayList(u32)) Error!void {
        var n: Normalizer = .{ .t = t, .env = env, .out = out };
        defer n.deinit();
        try n.class(c);
    }

    /// Byte equality of the normal forms (§3.5).
    pub fn eq(t: *Table, env: Env, a: ClassId, b: ClassId) Error!bool {
        if (a == b) return true;
        var wa: std.ArrayList(u32) = .empty;
        defer wa.deinit(env.gpa);
        var wb: std.ArrayList(u32) = .empty;
        defer wb.deinit(env.gpa);
        try t.normalize(env, a, &wa);
        try t.normalize(env, b, &wb);
        return std.mem.eql(u32, wa.items, wb.items);
    }

    const Normalizer = struct {
        t: *Table,
        env: Env,
        out: *std.ArrayList(u32),
        ordinal: stamped.Column(NodeId, u32) = .{},
        next: u32 = 0,

        const Tag = enum(u32) { class, node_new, node_ref, cell, set, cond, atom, fun, supply, keep, slot, path, label, none };

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
            try n.tag(.class);
            try n.put(k.params.len);
            try n.put(@as(u32, @intFromBool(k.writes)) | (@as(u32, @intFromBool(k.entry)) << 1) | (@as(u32, @intFromBool(k.refs_top)) << 2));
            try n.put(@backingInt(k.origin));
            try n.node(k.res);
            for (n.t.paramUses(c)) |u| if (u == .none) try n.tag(.none) else try n.node(u);
            try n.condSet(k.xreq);
            try n.put(k.funs.len);
            for (0..k.funs.len) |i| {
                const f = n.t.fun(c, @intCast(i));
                try n.tag(.fun);
                try n.put(f.j);
                try n.put(@backingInt(f.calls));
                try n.put(@as(u32, @intFromBool(f.need)) | (@as(u32, @intFromBool(f.seen)) << 1));
                try n.sorted(.supply, f.supplies.len, f, supplyWords);
                try n.sorted(.keep, f.keeps.len, f, keepWords);
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
            try n.sortedPaths(n.t.oncesOf(c));
            try n.cellSet(k.refs);
        }

        fn supplyWords(n: *Normalizer, f: Fun, i: u32, out: *std.ArrayList(u32)) Error!void {
            const s = n.t.supply(f, i);
            const saved = n.out;
            n.out = out;
            defer n.out = saved;
            try n.put(s.k);
            try n.put(@as(u32, @intFromBool(s.owned)) | (@as(u32, @intFromBool(s.taken)) << 1));
            try n.node(s.node);
            try n.cond(s.cond);
        }

        fn keepWords(n: *Normalizer, f: Fun, i: u32, out: *std.ArrayList(u32)) Error!void {
            const k = n.t.keepOf(f, i);
            const saved = n.out;
            n.out = out;
            defer n.out = saved;
            try n.put(k.j);
            try n.put(k.k);
            try n.path(k.kept_path);
            try n.path(k.written_path);
            try n.put(k.writer);
        }

        /// `len` items spelled by `spell`, sorted by their words, appended
        /// with a tag and count. (Node ordinals inside are assigned in the
        /// spelling order, which is itself canonical by induction.)
        fn sorted(n: *Normalizer, t: Tag, len: u32, f: Fun, spell: *const fn (*Normalizer, Fun, u32, *std.ArrayList(u32)) Error!void) Error!void {
            const gpa = n.env.gpa;
            var runs: std.ArrayList([]u32) = .empty;
            defer {
                for (runs.items) |r| gpa.free(r);
                runs.deinit(gpa);
            }
            for (0..len) |i| {
                try n.env.charge.reserve(gpa, .inspection, 1);
                var buf: std.ArrayList(u32) = .empty;
                errdefer buf.deinit(gpa);
                try spell(n, f, @intCast(i), &buf);
                try runs.append(gpa, try buf.toOwnedSlice(gpa));
            }
            sortRuns(runs.items);
            try n.tag(t);
            try n.put(len);
            for (runs.items) |r| try n.out.appendSlice(gpa, r);
        }

        fn sortedPaths(n: *Normalizer, paths: []const PathId) Error!void {
            const gpa = n.env.gpa;
            var runs: std.ArrayList([]u32) = .empty;
            defer {
                for (runs.items) |r| gpa.free(r);
                runs.deinit(gpa);
            }
            for (paths) |p| {
                var buf: std.ArrayList(u32) = .empty;
                errdefer buf.deinit(gpa);
                const saved = n.out;
                n.out = &buf;
                n.path(p) catch |e| {
                    n.out = saved;
                    return e;
                };
                n.out = saved;
                try runs.append(gpa, try buf.toOwnedSlice(gpa));
            }
            sortRuns(runs.items);
            for (runs.items) |r| try n.out.appendSlice(gpa, r);
        }

        fn node(n: *Normalizer, id: NodeId) Error!void {
            try n.env.charge.reserve(n.env.gpa, .inspection, 1);
            if (n.ordinal.get(id)) |o| {
                try n.tag(.node_ref);
                try n.put(o);
                return;
            }
            try n.ordinal.put(n.env.gpa, id, n.next);
            n.next += 1;
            const d = n.env.shapes.get(id);
            try n.tag(.node_new);
            try n.put(@backingInt(d.kind));
            try n.put(d.place.int());
            try n.cellSet(d.cells);
            try n.cond(try n.env.conds.kappaOf(n.env.gpa, n.env.charge, n.env.shapes, n.env.cells, id));
            switch (d.kind) {
                .leaf => {},
                .node => try n.overs(d.a),
                .delta => {
                    try n.node(.from(d.a));
                    try n.overs(d.b);
                },
                .recast => try n.node(.from(d.a)),
                .@"union" => {
                    try n.node(.from(d.a));
                    try n.node(.from(d.b));
                },
            }
        }

        fn overs(n: *Normalizer, root: u32) Error!void {
            // Step order is the map's iteration order (by step word).
            var n_entries: u32 = 0;
            var it = n.env.shapes.overEntries(root);
            while (it.next()) |_| n_entries += 1;
            try n.put(n_entries);
            it = n.env.shapes.overEntries(root);
            while (it.next()) |e| {
                try n.step(e.step);
                try n.node(e.node);
            }
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
            // Root first: collect by climbing.
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

        /// A cell set: its pairs spelled and sorted.
        fn cellSet(n: *Normalizer, s: SetId) Error!void {
            const gpa = n.env.gpa;
            var runs: std.ArrayList([]u32) = .empty;
            defer {
                for (runs.items) |r| gpa.free(r);
                runs.deinit(gpa);
            }
            var it = n.env.cells.sets.iterate(s);
            while (it.next()) |e| {
                var buf: std.ArrayList(u32) = .empty;
                errdefer buf.deinit(gpa);
                const saved = n.out;
                n.out = &buf;
                const r = n.cell(.from(e.key));
                n.out = saved;
                try r;
                try buf.append(gpa, e.value);
                try runs.append(gpa, try buf.toOwnedSlice(gpa));
            }
            sortRuns(runs.items);
            try n.tag(.set);
            try n.put(@intCast(runs.items.len));
            for (runs.items) |r| try n.out.appendSlice(gpa, r);
        }

        fn cond(n: *Normalizer, k: CondId) Error!void {
            try n.tag(.cond);
            try n.put(@backingInt(n.env.conds.kind(k)));
            if (k == Cond.yes or Cond.Table.fails(k)) return;
            try n.condSet(try n.env.conds.flat(n.env.gpa, n.env.charge, k));
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
            while (it.next()) |e| {
                try n.env.charge.reserve(gpa, .inspection, 1);
                var buf: std.ArrayList(u32) = .empty;
                errdefer buf.deinit(gpa);
                const saved = n.out;
                n.out = &buf;
                const r = n.atom(n.env.conds.get(.from(e.key)));
                n.out = saved;
                try r;
                try runs.append(gpa, try buf.toOwnedSlice(gpa));
            }
            sortRuns(runs.items);
            try n.tag(.set);
            try n.put(@intCast(runs.items.len));
            for (runs.items) |r| try n.out.appendSlice(gpa, r);
        }

        fn atom(n: *Normalizer, a: Cond.Cond) Error!void {
            try n.tag(.atom);
            try n.put(@backingInt(a.atom));
            switch (a.atom) {
                .excl => try n.cell(.from(a.a)),
                .sep => {
                    // The two sides in spelling order.
                    const gpa = n.env.gpa;
                    var x: std.ArrayList(u32) = .empty;
                    defer x.deinit(gpa);
                    var y: std.ArrayList(u32) = .empty;
                    defer y.deinit(gpa);
                    const saved = n.out;
                    n.out = &x;
                    const rx = n.cell(.from(a.a));
                    n.out = &y;
                    const ry = n.cell(.from(a.b));
                    n.out = saved;
                    try rx;
                    try ry;
                    const first = lessRun(y.items, x.items);
                    try n.out.appendSlice(gpa, if (first) y.items else x.items);
                    try n.out.appendSlice(gpa, if (first) x.items else y.items);
                },
                .within => try n.label(.from(a.a)),
                .apart => try n.cellSet(.from(a.a)),
                .keep, .writes => try n.put(a.a),
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
        var p: Printer = .{ .t = t, .env = env, .arena = arena, .names = names, .class_id = c };
        defer p.deinit();
        try p.summary(w, name);
    }

    const Printer = struct {
        t: *Table,
        env: Env,
        arena: Allocator,
        names: Names,
        class_id: ClassId,
        slots: []const Slot = &.{},
        params: u32 = 0,
        seen: stamped.Column(NodeId, void) = .{},

        const WErr = std.Io.Writer.Error;

        fn deinit(p: *Printer) void {
            p.seen.deinit(p.env.gpa);
        }

        fn summary(p: *Printer, w: *std.Io.Writer, name: []const u8) (Error || WErr)!void {
            const arena = p.arena;
            const k = p.t.get(p.class_id);
            p.params = k.params.len;
            var slots: std.ArrayList(Slot) = .empty;
            for (0..k.slots.len) |i| try slots.append(arena, p.t.slot(p.class_id, @intCast(i)));
            p.slots = slots.items;
            var parts: std.ArrayList([]const u8) = .empty;
            // Parameters' bits by path, in text order.
            var uses: std.ArrayList([]const u8) = .empty;
            for (p.t.paramUses(p.class_id), 0..) |u, i| if (u != .none) try p.useLines(u, @intCast(i), "", &uses);
            Cond.sortText(uses.items);
            if (uses.items.len > 0) try parts.append(arena, try std.mem.join(arena, ", ", uses.items));
            // The result by path.
            var groups: std.ArrayList([]const u8) = .empty;
            p.seen.clear();
            try p.resLines(k.res, "", &groups);
            Cond.sortText(groups.items);
            if (groups.items.len > 0) try parts.append(arena, try std.fmt.allocPrint(arena, "res {s}", .{try std.mem.join(arena, ", ", groups.items)}));
            // Function parameters.
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
                    try p.cellsText(&sb.writer, p.env.shapes.cells(e.node));
                    try sb.writer.print(" {s}{s}", .{ if (e.owned) "owned" else "borrowed", if (e.taken) " taken" else "" });
                    try p.cond(&sb.writer, e.cond);
                    try sup.append(arena, sb.toOwnedSlice() catch return error.OutOfMemory);
                }
                Cond.sortText(sup.items);
                for (sup.items) |s| try wr.print(", {s}", .{s});
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
        fn useLines(p: *Printer, u: NodeId, i: u32, prefix: []const u8, out: *std.ArrayList([]const u8)) (Error || WErr)!void {
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
                    .r => m.r = true,
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
            var kids = env.shapes.overEntries(d.a);
            while (kids.next()) |e| {
                var sb: std.Io.Writer.Allocating = .init(p.arena);
                try sb.writer.writeAll(prefix);
                try p.step(&sb.writer, e.step);
                try p.useLines(e.node, i, sb.toOwnedSlice() catch return error.OutOfMemory, out);
            }
        }

        /// `res`'s groups: one text per path of the explicit structure,
        /// `<path> <provenances> {κ}`, a node once.
        fn resLines(p: *Printer, n: NodeId, prefix: []const u8, out: *std.ArrayList([]const u8)) (Error || WErr)!void {
            const env = p.env;
            if (p.seen.contains(n)) return;
            try p.seen.put(env.gpa, n, {});
            // One group per path: a union's sides are gathered into it, a
            // recast's cells approximate.
            var texts: std.ArrayList([]const u8) = .empty;
            try p.gather(n, &texts);
            Cond.sortText(texts.items);
            var buf: std.Io.Writer.Allocating = .init(p.arena);
            const w = &buf.writer;
            if (prefix.len > 0) try w.print("{s} ", .{prefix});
            try w.writeAll(try std.mem.join(p.arena, " ", texts.items));
            const k = try env.conds.kappaOf(env.gpa, env.charge, env.shapes, env.cells, n);
            try p.cond(w, k);
            // A path holding nothing with nothing to say is not a group.
            if (texts.items.len > 0 or k != Cond.yes) try out.append(p.arena, buf.toOwnedSlice() catch return error.OutOfMemory);
            try p.descend(n, prefix, out);
        }

        /// The children of the explicit structure under `n`: a node's or a
        /// delta's projections (so a delta's unchanged fields print), a
        /// union's sides' in turn; a leaf's or a recast's are implied by its
        /// cells and never enumerated.
        fn descend(p: *Printer, n: NodeId, prefix: []const u8, out: *std.ArrayList([]const u8)) (Error || WErr)!void {
            const env = p.env;
            const d = env.shapes.get(n);
            switch (d.kind) {
                .leaf, .recast => return,
                .@"union" => {
                    try p.descend(.from(d.a), prefix, out);
                    try p.descend(.from(d.b), prefix, out);
                },
                .node, .delta => {
                    const steps = env.places.steps(d.place);
                    for (steps.steps) |s| {
                        const c = (try env.shapes.proj(env.gpa, env.account(), env.places, env.cells, n, s)) orelse continue;
                        if (env.shapes.kind(c) == .leaf and env.shapes.cells(c) == .none) continue;
                        var sb: std.Io.Writer.Allocating = .init(p.arena);
                        try sb.writer.writeAll(prefix);
                        try p.step(&sb.writer, s);
                        try p.resLines(c, sb.toOwnedSlice() catch return error.OutOfMemory, out);
                    }
                },
            }
        }

        /// The provenance texts of `n`'s cells at its own path: through a
        /// union's sides, `~` before an approximate pair or under a recast.
        fn gather(p: *Printer, n: NodeId, texts: *std.ArrayList([]const u8)) (Error || WErr)!void {
            const d = p.env.shapes.get(n);
            if (d.kind == .@"union") {
                try p.gather(.from(d.a), texts);
                try p.gather(.from(d.b), texts);
                return;
            }
            var it = p.env.cells.sets.iterate(d.cells);
            while (it.next()) |e| {
                var buf: std.Io.Writer.Allocating = .init(p.arena);
                if (e.value == 1 or d.kind == .recast) try buf.writer.writeAll("~");
                try p.cell(&buf.writer, .from(e.key));
                try texts.append(p.arena, buf.toOwnedSlice() catch return error.OutOfMemory);
            }
        }
        /// A set's cells in text order, `~` before an approximate pair.
        fn cellsText(p: *Printer, w: *std.Io.Writer, s: SetId) (Error || WErr)!void {
            var texts: std.ArrayList([]const u8) = .empty;
            var it = p.env.cells.sets.iterate(s);
            while (it.next()) |e| {
                var buf: std.Io.Writer.Allocating = .init(p.arena);
                if (e.value == 1) try buf.writer.writeAll("~");
                try p.cell(&buf.writer, .from(e.key));
                try texts.append(p.arena, buf.toOwnedSlice() catch return error.OutOfMemory);
            }
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
        /// `⊤`, `elem(π1)`, `others(π1)`, `level(…)`, `below(…#C.i)`,
        /// `loan(…)`, `site7`; a label other than the class's own after `@`.
        fn cell(p: *Printer, w: *std.Io.Writer, c: CellId) WErr!void {
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
                .elem, .others, .level, .below, .loan => {
                    try w.writeAll(switch (d.origin) {
                        .elem => "elem(",
                        .others => "others(",
                        .level => "level(",
                        .below => "below(",
                        else => "loan(",
                    });
                    try p.cell(w, .from(d.a));
                    if (d.origin == .below) try w.print("#{d}", .{d.c});
                    try w.writeAll("·");
                    try p.label(w, .from(d.b));
                    try w.writeAll(")");
                },
                .mark => try w.writeAll(switch (env.cells.markOf(c)) {
                    .r => "R",
                    .a => "A",
                    .e => "E",
                    .w => "W",
                    .deep => "S",
                    .field => "W{}",
                }),
            }
        }

        /// A label: `ι<inst>`, `⋆` when folded, `·` then the callee's.
        fn label(p: *Printer, w: *std.Io.Writer, l: LabelId) WErr!void {
            if (l == .none) return w.writeAll("λ");
            const d = p.env.cells.labelOf(l);
            try w.print("ι{d}", .{d.inst});
            if (d.folded) try w.writeAll("⋆");
            if (d.callee_label != .none) {
                try w.writeAll("·");
                try p.label(w, d.callee_label);
            }
        }

        fn path(p: *Printer, w: *std.Io.Writer, q: PathId) WErr!void {
            if (q == .none) return;
            // Root first: the steps collected by climbing, in the arena.
            var steps: std.ArrayList(Step) = .empty;
            var at = q;
            while (p.env.places.pathParent(at) != .none) : (at = p.env.places.pathParent(at)) {
                steps.append(p.arena, p.env.places.pathStep(at)) catch return error.WriteFailed;
            }
            var n = steps.items.len;
            while (n > 0) : (n -= 1) try p.step(w, steps.items[n - 1]);
        }

        fn step(p: *Printer, w: *std.Io.Writer, s: Step) WErr!void {
            switch (s.kind) {
                .field => try w.print(".{s}", .{p.names.field(p.names.ctx, s.payload)}),
                .index => try w.print(".{d}", .{s.payload}),
                .ctor_arg => {
                    const pair = p.env.places.ctorArgOf(s);
                    try w.print("#{s}.{d}", .{ p.names.ctor(p.names.ctx, pair[0], pair[1]), pair[1] });
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
    // `{ r | a = … }`: W{a} at ε, A at .b, nothing at .a (R-4.8.2).
    var u = try Table.markUse(env, .none, rec, &.{}, .{ .w = true }, &.{10});
    u = try Table.markUse(env, u, rec, &.{fb}, .{ .a = true }, &.{});
    try testing.expectEqual(Marks{ .w = true }, try Table.marksAt(env, u, &.{}));
    try testing.expectEqual(Marks{ .a = true }, try Table.marksAt(env, u, &.{fb}));
    try testing.expectEqual(Marks{}, try Table.marksAt(env, u, &.{fa}));
    try testing.expect(try Table.usedAt(env, u, &.{}));
    try testing.expect(try Table.usedAt(env, u, &.{fb}));
    try testing.expect(!try Table.usedAt(env, u, &.{fa}));
    try testing.expect(!try Table.usedAt(env, u, &.{ fa, Place.Step.elem }));
    // A deep read at .a (a callee that compares the field): used below it.
    const deep = try Table.markUse(env, u, rec, &.{fa}, .{ .r = true, .deep = true }, &.{});
    try testing.expect(try Table.usedAt(env, deep, &.{ fa, Place.Step.elem }));
    try testing.expectEqual(Marks{ .r = true, .deep = true }, try Table.marksAt(env, deep, &.{fa}));
    try testing.expectEqual(Shape.Kind.leaf, f.shapes.kind((try f.shapes.proj(testing.allocator, &f.account, &f.places, &f.cells, deep, fa)).?));
    // A mark under a deep leaf joins the leaf.
    const under = try Table.markUse(env, deep, rec, &.{ fa, Place.Step.elem }, .{ .w = true }, &.{});
    try testing.expectEqual(Marks{ .r = true, .w = true, .deep = true }, try Table.marksAt(env, under, &.{fa}));
    // join is pointwise union; leq inclusion; `.none` the empty use.
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

test "a class prints in v1's grammar: bits by path, res by path with κ, funs, xreq" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const env = f.env();
    const gpa = testing.allocator;
    const list = try f.placeOf(1);
    const lists = try f.placeOf(3);
    // `push : written returned List (List Int), borrowed (⊤ → ⊤), stored List Int → …`
    // read off as: π1 RAW at ε, A at [*]; π3 A; res π1 at ε, `[*]` holds
    // π1[*] and π3 under apart; fun π2 calls ≤1 with supply π1 owned; xreq.
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
    _ = try f.conds.setKappa(gpa, env.charge, res, e1);
    _ = try f.conds.setKappa(gpa, env.charge, elem, try f.conds.@"and"(gpa, env.charge, ap, e3));
    const supply_node = try f.leaf(3, &.{p1});
    const c = try f.sums.add(env, .{
        .params = &.{ use1, .none, use3 },
        .res = res,
        .xreq = try f.conds.flat(gpa, env.charge, e1),
        .funs = &.{.{ .j = 1, .calls = .once, .supplies = &.{.{ .j = 1, .k = 0, .node = supply_node, .point = 5, .owned = true, .taken = false, .cond = e1 }} }},
        .writes = true,
        .origin = .words,
    });
    try testing.expectEqualStrings(
        "summary push: π1 RAW, π1[*] A, π3 A; res [*] π1[*] π3{apart [π1[*]] [π3], excl π3}, π1{excl π1}; π2 calls ≤1, supply 1 π1 owned{excl π1}; xreq excl π1 (words)",
        try f.text(c, "push"),
    );
    // A class with nothing: `unused`. A result-only class.
    const nothing = try f.sums.add(env, .{ .params = &.{.none}, .res = try f.shapes.nothing(gpa, &f.account, list) });
    try testing.expectEqualStrings("summary g: unused", try f.text(nothing, "g"));
    const fresh1 = try f.fresh(1, 1);
    const r2 = try f.leaf(1, &.{fresh1});
    const fr = try f.sums.add(env, .{ .params = &.{}, .res = r2, .origin = .asserted });
    try testing.expectEqualStrings("summary h: res fresh1 (asserted)", try f.text(fr, "h"));
    // `⊤call`.
    const unk = try f.sums.unknown(env, &.{ lists, list }, &.{1}, list);
    try testing.expectEqualStrings("summary k: π1 RAES, π2 RAES; res ⊤{lost}; π2 calls many, need owned, unseen", try f.text(unk, "k"));
    try testing.expect(f.sums.get(unk).refs_top and f.sums.get(unk).writes);
}

test "join and leq: pointwise over uses, res with κ, funs, supplies and bits" {
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
    _ = try f.conds.setKappa(gpa, env.charge, ra, Cond.lost);
    const e1 = try f.conds.excl(gpa, env.charge, p1);
    const sup_a: Supply = .{ .j = 1, .k = 0, .node = rb, .point = 3, .owned = true, .taken = false, .cond = Cond.yes };
    const sup_b: Supply = .{ .j = 1, .k = 0, .node = rb, .point = 7, .owned = false, .taken = false, .cond = e1 };
    const a = try f.sums.add(env, .{ .params = &.{ua}, .res = ra, .funs = &.{.{ .j = 1, .calls = .once, .supplies = &.{sup_a} }} });
    const b = try f.sums.add(env, .{ .params = &.{ub}, .res = rb, .xreq = try f.conds.flat(gpa, env.charge, e1), .funs = &.{ .{ .j = 1, .calls = .many, .need = true, .seen = false }, .{ .j = 2, .calls = .zero } }, .writes = true });
    const j = try f.sums.join(env, a, b);
    const jc = f.sums.get(j);
    // Uses: RAW. res: both provenances, κ lost (the join of lost and yes).
    try testing.expectEqual(Marks{ .r = true, .a = true, .w = true }, try Table.marksAt(env, f.sums.paramUses(j)[0], &.{}));
    try testing.expectEqual(@as(u32, 2), f.cells.sets.count(f.shapes.cells(jc.res)));
    try testing.expectEqual(Cond.lost, try f.conds.kappaOf(gpa, env.charge, &f.shapes, &f.cells, jc.res));
    try testing.expect(jc.writes);
    try testing.expectEqual(jc.xreq, f.sums.get(b).xreq);
    // Funs merged by j: calls many, need, unseen; the supply kept; π3 added.
    try testing.expectEqual(@as(u32, 2), f.sums.funCount(j));
    const f1 = f.sums.fun(j, 0);
    try testing.expectEqual(@as(u32, 1), f1.j);
    try testing.expectEqual(Calls.many, f1.calls);
    try testing.expect(f1.need and !f1.seen);
    try testing.expectEqual(@as(u32, 1), f1.supplies.len);
    try testing.expectEqual(@as(u32, 2), f.sums.fun(j, 1).j);
    // The order: a ⊑ j, b ⊑ j, not j ⊑ a; a ⊑ b fails on res.
    try testing.expect(try f.sums.leq(env, a, j));
    try testing.expect(try f.sums.leq(env, b, j));
    try testing.expect(!try f.sums.leq(env, j, a));
    try testing.expect(!try f.sums.leq(env, a, b));
    try testing.expect(try f.sums.leq(env, j, j));
    // Two supplies of one node: owned and-ed, κ joined.
    const c = try f.sums.add(env, .{ .params = &.{ua}, .res = ra, .funs = &.{.{ .j = 1, .calls = .once, .supplies = &.{sup_b} }} });
    const ac = try f.sums.join(env, a, c);
    const s = f.sums.supply(f.sums.fun(ac, 0), 0);
    try testing.expect(!s.owned);
    try testing.expectEqual(@as(u32, 3), s.point);
    try testing.expectEqual(e1, s.cond);
    try testing.expect(try f.sums.leq(env, a, ac));
    try testing.expect(!try f.sums.leq(env, ac, a)); // borrowed is not below owned
    // Idempotent.
    try testing.expectEqual(j, try f.sums.join(env, j, j));
    try testing.expect(try f.sums.eq(env, j, try f.sums.join(env, b, a)));
}

test "normal form: equal classes built in another order are byte-equal; a flipped bit is not" {
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
    const s1: Supply = .{ .j = 2, .k = 0, .node = n1, .point = 1, .owned = true, .taken = false, .cond = Cond.yes };
    const s2: Supply = .{ .j = 2, .k = 1, .node = n2, .point = 2, .owned = true, .taken = true, .cond = Cond.yes };
    const a = try f.sums.add(env, .{ .params = &.{ u, u, .none }, .res = r, .funs = &.{ .{ .j = 2, .calls = .many, .supplies = &.{ s1, s2 } }, .{ .j = 3, .calls = .zero } } });
    const b = try f.sums.add(env, .{ .params = &.{ u, u, .none }, .res = r, .funs = &.{ .{ .j = 3, .calls = .zero }, .{ .j = 2, .calls = .many, .supplies = &.{ s2, s1 } } } });
    try testing.expect(a != b);
    try testing.expect(try f.sums.eq(env, a, b));
    var wa: std.ArrayList(u32) = .empty;
    defer wa.deinit(gpa);
    try f.sums.normalize(env, a, &wa);
    try testing.expect(wa.items.len > 20);
    var s1b = s1;
    s1b.owned = false;
    const c = try f.sums.add(env, .{ .params = &.{ u, u, .none }, .res = r, .funs = &.{ .{ .j = 2, .calls = .many, .supplies = &.{ s1b, s2 } }, .{ .j = 3, .calls = .zero } } });
    try testing.expect(!try f.sums.eq(env, a, c));
    // κ is part of the form.
    const r2 = try f.leaf(1, &.{ p1, p2 });
    try testing.expectEqual(r, r2);
    const d = try f.sums.add(env, .{ .params = &.{ u, u, .none }, .res = r2, .funs = &.{ .{ .j = 2, .calls = .many, .supplies = &.{ s1, s2 } }, .{ .j = 3, .calls = .zero } } });
    try testing.expect(try f.sums.eq(env, a, d));
    _ = try f.conds.setKappa(gpa, env.charge, r, Cond.lost);
    var wa2: std.ArrayList(u32) = .empty;
    defer wa2.deinit(gpa);
    try f.sums.normalize(env, a, &wa2);
    try testing.expect(!std.mem.eql(u32, wa.items, wa2.items));
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
