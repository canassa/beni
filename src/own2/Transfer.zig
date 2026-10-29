//! L8: the transfer rules (`docs/design/ownership-v2.md` §2.6), one case per
//! BIR tag, over one declaration's instructions in evaluation order. A
//! value is a shape root with its own κ snapshot (§2.9); the frame records,
//! for `Walk` and `Demands`, the uses (at the consumer, R-4.1.1), the
//! demands, the holders (bindings and pending computed operands), the
//! escapes and what the calls rely on.
//!
//! **What S3a builds**: locals, field and tuple projections, literals,
//! lists, tuples, records and constructor applications as containers, the
//! spread chains `Lower` recorded (§2.13.2: a construction past the first
//! spread, a prepend before it), `++` chains (one demand on the leftmost
//! operand, R-2.2), `let`s, `case`s and their patterns (a list pattern
//! splits its container, §2.13.3), top-level values (`shared`, §2.13.11),
//! and calls of the classes the rows give (`Calls`). A call whose every
//! argument and result cross does nothing. **Anything else** — a lambda, a
//! local function, a record update, a call of a summarised declaration or
//! a function value, markup, `?`, a schema — is not built yet: the frame
//! says so (`unbuilt`) and the declaration gets the pessimistic class,
//! never a refusal (§8, S3a).
//!
//! **Points.** A use is at its consumer; a value bound by a `let` is bound
//! where its value is complete, a pattern where its root is matched, a
//! parameter at its pattern. A computed operand is pending from its own
//! point to its consumer's.
//!
//! Obligations kept here: O1 (a construct's node over-approximates what it
//! produces; an unknown is `⊤`), O2 (uses at consumers, at the path read,
//! with their kind), O6's pattern half (a list pattern's element and rest
//! are the two sides of one split), O7 (a construction's result is its
//! base's object written), O13 (a literal's and a construction's κ by
//! §2.9's rules).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const stamped = @import("../stamped.zig");
const Facts = @import("Facts.zig");
const Place = @import("Place.zig");
const Cell = @import("Cell.zig");
const Shape = @import("Shape.zig");
const Cond = @import("Cond.zig");
const Summary = @import("Summary.zig");
const Regions = @import("Regions.zig");
const Demands = @import("Demands.zig");
const Calls = @import("Calls.zig");
const Bir = @import("../bir/Bir.zig");

pub const NodeId = Ids.NodeId;
pub const CellId = Ids.CellId;
pub const SetId = Ids.SetId;
pub const PathId = Ids.PathId;
pub const PlaceId = Ids.PlaceId;
pub const CondId = Ids.CondId;
pub const ClassId = Ids.ClassId;
pub const Value = Demands.Value;
pub const Env = Summary.Env;
pub const Step = Place.Step;
pub const Error = Ids.ChargeError;
pub const none: u32 = Ids.none_int;
const Inst = Bir.Inst;

/// What a call runs, as the module adapter resolves it (L10).
pub const Callee = union(enum) {
    /// A class to apply, at this call's instantiation.
    class: ClassId,
    /// A constructor: its ordinal in its type.
    ctor: u32,
    /// Every argument and the result cross: nothing happens.
    harmless,
    /// Not built in this slice.
    unbuilt,
};

/// What the walk asks of the module (§5: upward needs go through an
/// interface passed down). Every answer is source input.
pub const Context = struct {
    ctx: *anyopaque,
    /// The place of an instruction's solved type.
    placeOfInst: *const fn (ctx: *anyopaque, inst: u32) Error!PlaceId,
    /// The place of a local's solved type (declaration-relative index).
    placeOfLocal: *const fn (ctx: *anyopaque, local: u32) Error!PlaceId,
    /// The text rank of a field name (a BIR symbol).
    fieldRank: *const fn (ctx: *anyopaque, symbol: Bir.SymbolIndex) u32,
    /// What a `call` or `method_call` runs.
    callee: *const fn (ctx: *anyopaque, inst: u32) Error!Callee,
    /// A constructor reference's ordinal in its type, and its arity.
    ctorOf: *const fn (ctx: *anyopaque, ref: u32) ?[2]u32,
    /// A reference to a parameterless top-level value: its `shared` index;
    /// null for a function.
    sharedIndex: *const fn (ctx: *anyopaque, ref: u32) ?u32,
    /// A `++` the checker resolved to `List.append` (`Dispatch`).
    isListAppend: *const fn (ctx: *anyopaque, inst: u32) bool,
};

/// One instruction's value, and the local and path it reads when it is a
/// read of one (a field chain included): what its consumer records a use of.
const Val = struct {
    value: Value = .{},
    local: u32 = none,
    path: PathId = .none,
};

pub const Frame = struct {
    gpa: Allocator,
    env: Env,
    sums: *const Summary.Table,
    ctx: Context,
    bir: *const Bir,
    decl: Bir.Decl,
    regions: *const Regions.Tree,
    /// The declaration's parameter places (its signature's), when known: a
    /// pattern parameter has no type of its own.
    param_places: []const PlaceId = &.{},
    vals: []Val = &.{},
    locals: []Value = &.{},
    bound: []bool = &.{},
    /// Per instruction: who consumes its value, and at which point.
    consumer: []u32 = &.{},
    point_of: []u32 = &.{},
    /// Per instruction: lowered internals of a spread or `++` chain.
    absorbed: []bool = &.{},
    /// Per instruction: the `Bir.Spread` it roots, or `none`.
    chain: []u32 = &.{},
    /// Per instruction: a pattern root and the instruction whose value it
    /// matches (a case's scrutinee), or a `let` pattern's value and the
    /// pattern it binds.
    matches: []u32 = &.{},
    binds: []u32 = &.{},
    uses: std.ArrayList(Facts.Use) = .empty,
    /// Per use: its consumer's main token, the position a message prints.
    use_tokens: std.ArrayList(u32) = .empty,
    demands: std.ArrayList(Demands.Demand) = .empty,
    operands: std.ArrayList(Demands.Operand) = .empty,
    holders: std.ArrayList(Demands.Holder) = .empty,
    escapes: std.ArrayList(Demands.Escape) = .empty,
    /// Per local: its binding holder, or `none`.
    binding: []u32 = &.{},
    /// What the calls of this frame rely on (their `xreq`, instantiated).
    xreq: CondId = Cond.yes,
    /// The first instruction not built yet, or `none`.
    unbuilt: u32 = none,
    calls: Calls.Scratch = .{},
    scratch: std.ArrayList(Inst.Index) = .empty,

    pub fn deinit(f: *Frame) void {
        const gpa = f.gpa;
        gpa.free(f.vals);
        gpa.free(f.locals);
        gpa.free(f.bound);
        gpa.free(f.consumer);
        gpa.free(f.point_of);
        gpa.free(f.absorbed);
        gpa.free(f.chain);
        gpa.free(f.matches);
        gpa.free(f.binds);
        gpa.free(f.binding);
        f.uses.deinit(gpa);
        f.use_tokens.deinit(gpa);
        f.demands.deinit(gpa);
        f.operands.deinit(gpa);
        f.holders.deinit(gpa);
        f.escapes.deinit(gpa);
        f.calls.deinit(gpa);
        f.scratch.deinit(gpa);
    }

    fn rel(f: *const Frame, i: u32) u32 {
        return i - f.decl.inst_start.int();
    }

    fn account(f: *Frame) *Ids.Account {
        return f.env.account();
    }

    fn tag(f: *const Frame, i: u32) Inst.Tag {
        return f.bir.instTag(@fromBackingInt(i));
    }

    fn data(f: *const Frame, i: u32) Inst.Data {
        return f.bir.instData(@fromBackingInt(i));
    }

    fn token(f: *const Frame, i: u32) u32 {
        return f.bir.insts.items(.main_token)[i];
    }

    fn val(f: *const Frame, i: u32) Val {
        return f.vals[f.rel(i)];
    }

    /// Whether a cell set has two members or more.
    fn several(cellt: *const Cell.Table, s: SetId) bool {
        var it = cellt.sets.iterate(s);
        return it.next() != null and it.next() != null;
    }

    /// Enter instruction `i`'s settlement kernel (§4.1), to `leave` after.
    fn lane(f: *Frame, i: u32) Error!Ids.Account.Kernel {
        return f.account().enter(f.gpa, .{ .atom = i, .role = .transfer_settlement });
    }

    /// An item's work that is as large as its value (its fit, its κ merge
    /// and reads, its projection, its cells): a growth task chosen before
    /// it, never the item's lane, whose ceiling a large value would pass
    /// (§4.1, #1139's review). Read-off continuations charge it by its
    /// producers (#1098).
    fn sized(f: *Frame) Error!Ids.Account.Kernel {
        return f.account().enter(f.gpa, null);
    }

    fn markUnbuilt(f: *Frame, i: u32) void {
        if (f.unbuilt == none) f.unbuilt = i;
    }

    fn args(f: *const Frame, c: u32) []const Inst.Index {
        return f.bir.extraSlice(f.bir.subRange(@fromBackingInt(f.data(c).rhs)), Inst.Index);
    }

    fn placeOf(f: *Frame, i: u32) Error!PlaceId {
        return f.ctx.placeOfInst(f.ctx.ctx, i);
    }

    fn set1(f: *Frame, c: CellId) Error!SetId {
        return f.env.cells.sets.insert(f.gpa, f.env.charge, .none, c.int(), 0);
    }

    fn nothing(f: *Frame, at: PlaceId) Error!Value {
        return .{ .node = try f.env.shapes.nothing(f.gpa, f.account(), at) };
    }

    fn topValue(f: *Frame, at: PlaceId) Error!Value {
        const top = try f.env.cells.top(f.gpa, f.account());
        return .{ .node = try f.env.shapes.leaf(f.gpa, f.account(), at, try f.set1(top)) };
    }

    /// A value built at a place the checker gave no structure (a type
    /// variable: `Js.array`'s literal): one leaf of `⊤` and everything its
    /// parts reach, so what flowed into it is in its reach and held at its
    /// own path (#1102, #1136). Each part's union is that part's work, on
    /// its own lane when it has one (§4.1), and a part's reach is memoised,
    /// so a level adds its own cells and never rebuilds the one below.
    fn opaqueOf(f: *Frame, at: PlaceId, parts: []const Value, insts: ?[]const u32) Error!Value {
        const sets = &f.env.cells.sets;
        var cells = try f.set1(try f.env.cells.top(f.gpa, f.account()));
        for (parts, 0..) |p, i| {
            if (p.node == .none) continue;
            const kernel = if (insts) |is| try f.lane(is[i]) else null;
            defer if (kernel) |k| f.account().leave(k);
            cells = try sets.unionWith(f.gpa, f.env.charge, cells, try f.env.shapes.reach(f.gpa, f.account(), sets, p.node));
        }
        return .{ .node = try f.env.shapes.leaf(f.gpa, f.account(), at, cells) };
    }

    /// `k` with κ(n) joined with `c` at the position `k` is.
    fn kappaSet(f: *Frame, k: Cond.Kappas, n: NodeId, c: CondId) Error!Cond.Kappas {
        return (try f.env.conds.kappaSet(f.gpa, f.env.charge, k, n, c)).ctx;
    }

    /// `k` with κ(n) joined with `c` at its `[*]`.
    fn kappaSetElem(f: *Frame, k: Cond.Kappas, n: NodeId, c: CondId) Error!Cond.Kappas {
        return f.env.conds.kappaSetAt(f.gpa, f.env.charge, k, &.{Step.elem}, n, c);
    }

    // ---- the preliminary passes ------------------------------------------------

    /// Consumers, chains and pattern roots: one pass over the instructions.
    fn prepare(f: *Frame) Error!void {
        const gpa = f.gpa;
        const n = f.decl.inst_end.int() - f.decl.inst_start.int();
        f.vals = try gpa.alloc(Val, n);
        @memset(f.vals, .{});
        f.consumer = try gpa.alloc(u32, n);
        @memset(f.consumer, none);
        f.point_of = try gpa.alloc(u32, n);
        f.absorbed = try gpa.alloc(bool, n);
        @memset(f.absorbed, false);
        f.chain = try gpa.alloc(u32, n);
        @memset(f.chain, none);
        f.matches = try gpa.alloc(u32, n);
        @memset(f.matches, none);
        f.binds = try gpa.alloc(u32, n);
        @memset(f.binds, none);
        const nl = f.decl.locals_end - f.decl.locals_start;
        f.locals = try gpa.alloc(Value, nl);
        @memset(f.locals, .{});
        f.bound = try gpa.alloc(bool, nl);
        @memset(f.bound, false);
        f.binding = try gpa.alloc(u32, nl);
        @memset(f.binding, none);
        var i = f.decl.inst_start.int();
        while (i < f.decl.inst_end.int()) : (i += 1) {
            f.scratch.clearRetainingCapacity();
            try f.bir.operands(gpa, @fromBackingInt(i), &f.scratch);
            for (f.scratch.items) |o| {
                if (o.int() < f.decl.inst_start.int() or o.int() >= f.decl.inst_end.int()) continue;
                f.consumer[f.rel(o.int())] = i;
            }
            switch (f.tag(i)) {
                .branch => {
                    // The arm's pattern matches the case's scrutinee: the
                    // case is the branch's consumer, found below.
                },
                .let_pattern => f.binds[f.rel(f.data(i).rhs)] = f.data(i).lhs,
                else => {},
            }
        }
        // A branch's pattern matches its case's scrutinee.
        i = f.decl.inst_start.int();
        while (i < f.decl.inst_end.int()) : (i += 1) {
            if (f.tag(i) != .case) continue;
            const scrutinee = f.data(i).lhs;
            for (f.bir.extraSlice(f.bir.subRange(@fromBackingInt(f.data(i).rhs)), Inst.Index)) |b| {
                f.matches[f.rel(f.data(b.int()).lhs)] = scrutinee;
            }
        }
        // Points: a value bound by a `let`, a scrutinee: its own point.
        for (f.point_of, 0..) |*p, r| {
            const c = f.consumer[r];
            const self: u32 = @intCast(r + f.decl.inst_start.int());
            p.* = if (c == none) self else switch (f.tag(c)) {
                .let_def, .let_pattern => self,
                .case => if (f.data(c).lhs == self) self else c,
                else => c,
            };
        }
        // Spread chains: their roots, and the lowered calls inside them.
        for (f.bir.spreads(f.decl), 0..) |s, si| {
            if (s.root < f.decl.inst_start.int() or s.root >= f.decl.inst_end.int()) continue;
            f.chain[f.rel(s.root)] = @intCast(si);
            var items: std.ArrayList(u32) = .empty;
            defer items.deinit(gpa);
            for (f.bir.spreadItems(s)) |it| try items.append(gpa, it[0]);
            try f.absorb(s.root, items.items);
        }
        // `++` chains: an inner `++` on lists is its outer one's.
        i = f.decl.inst_start.int();
        while (i < f.decl.inst_end.int()) : (i += 1) {
            if (f.tag(i) != .call or !f.ctx.isListAppend(f.ctx.ctx, i)) continue;
            const a = f.args(i);
            if (a.len != 2) continue;
            const inner = a[1].int();
            if (f.tag(inner) == .call and f.ctx.isListAppend(f.ctx.ctx, inner) and f.args(inner).len == 2) {
                f.absorbed[f.rel(inner)] = true;
                f.absorbed[f.rel(f.data(inner).lhs)] = true;
            }
        }
    }

    /// The lowered calls (and a trailing literal) between a chain's root
    /// and its items.
    fn absorb(f: *Frame, root: u32, items: []const u32) Error!void {
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(f.gpa);
        try stack.append(f.gpa, root);
        while (stack.pop()) |c| {
            if (std.mem.indexOfScalar(u32, items, c) != null) continue;
            if (c != root) f.absorbed[f.rel(c)] = true;
            switch (f.tag(c)) {
                .call => {
                    f.absorbed[f.rel(f.data(c).lhs)] = true;
                    for (f.args(c)) |a| try stack.append(f.gpa, a.int());
                },
                .list => for (f.bir.extraSlice(Bir.inlineRange(f.data(c)), Inst.Index)) |e| try stack.append(f.gpa, e.int()),
                else => {},
            }
        }
    }

    // ---- uses ----------------------------------------------------------------

    /// Operand `o` consumed by `by`: a use of the local it reads, if any.
    fn consume(f: *Frame, o: u32, by: u32, kind: Facts.UseKind, use_node: NodeId) Error!void {
        const v = f.val(o);
        if (v.local == none) return;
        const point = f.point_of[f.rel(o)];
        const k: Facts.UseKind = if (kind == .whole and f.env.places.pathDepth(v.path) > 0) .field else kind;
        try f.uses.append(f.gpa, .{
            .local = v.local,
            .path = v.path,
            .point = point,
            .kind = k,
            .region = f.regions.regionOf(point),
            .use_node = use_node,
            .atom = @intCast(f.uses.items.len),
        });
        try f.use_tokens.append(f.gpa, f.token(by));
    }

    /// A computed operand evaluated before its consumer: pending between.
    fn pending(f: *Frame, i: u32) Error!void {
        const v = f.val(i);
        if (v.local != none or v.value.node == .none) return;
        const end = f.point_of[f.rel(i)];
        if (end <= i) return;
        try f.holders.append(f.gpa, .{ .kind = .pending, .who = i, .value = v.value, .start = i, .end = end, .root = .none, .token = f.token(i) });
    }

    fn bindLocal(f: *Frame, local: u32, v: Value, point: u32) Error!void {
        f.locals[local] = v;
        f.bound[local] = true;
        const at = try f.ctx.placeOfLocal(f.ctx.ctx, local);
        f.binding[local] = @intCast(f.holders.items.len);
        try f.holders.append(f.gpa, .{ .kind = .binding, .who = local, .value = v, .start = point, .end = point, .root = try f.env.places.rootPath(f.gpa, at), .token = f.token(point) });
    }

    // ---- patterns ------------------------------------------------------------

    /// Bind pattern `p` to `v`, matched at `point` (§2.13.3).
    const BindItem = struct { pat: u32, value: Value };

    fn bind(f: *Frame, p: u32, v: Value, point: u32) Error!void {
        // One explicit stack for the whole pattern, a list pattern's nested
        // items included (#1138: a pattern nests as deep as the source).
        var stack: std.ArrayList(BindItem) = .empty;
        defer stack.deinit(f.gpa);
        try stack.append(f.gpa, .{ .pat = p, .value = v });
        while (stack.pop()) |it| {
            // §4.1: each written pattern's binding is its own atom's kernel.
            const kernel = try f.lane(it.pat);
            defer f.account().leave(kernel);
            const d = f.data(it.pat);
            switch (f.tag(it.pat)) {
                .pat_var => try f.bindLocal(d.lhs, it.value, point),
                .pat_as => {
                    try f.bindLocal(d.rhs, it.value, point);
                    try stack.append(f.gpa, .{ .pat = d.lhs, .value = it.value });
                },
                .pat_wild, .pat_int, .pat_char, .pat_string, .pat_unit => {},
                // Each part of a wide pattern is its own atom's (§4.1: wide runs
                // supply their own written atoms): a component's pattern, a field's
                // local, an argument's pattern.
                .pat_tuple => for (f.bir.extraSlice(Bir.inlineRange(d), Inst.Index), 0..) |e, k| {
                    const part = try f.lane(e.int());
                    defer f.account().leave(part);
                    try stack.append(f.gpa, .{ .pat = e.int(), .value = try f.project(it.value, try Step.index(f.account(), @intCast(k)), e.int()) });
                },
                .pat_record => for (f.bir.extraSlice(Bir.inlineRange(d), u32)) |local| {
                    const part = try f.account().enter(f.gpa, .{ .atom = Ids.atom_local_bit | local, .role = .transfer_settlement });
                    defer f.account().leave(part);
                    const name = f.bir.locals[f.decl.locals_start + local].name;
                    const step = try Step.field(f.account(), f.ctx.fieldRank(f.ctx.ctx, name));
                    const at = try f.ctx.placeOfLocal(f.ctx.ctx, local);
                    try f.bindLocal(local, try f.projectAt(it.value, step, at), point);
                },
                .pat_ctor => {
                    const ref = d.lhs;
                    const ord = f.ctx.ctorOf(f.ctx.ctx, ref) orelse {
                        f.markUnbuilt(it.pat);
                        continue;
                    };
                    const arg_pats = f.bir.extraSlice(f.bir.subRange(@fromBackingInt(d.rhs)), Inst.Index);
                    for (arg_pats, 0..) |a, k| {
                        const part = try f.lane(a.int());
                        defer f.account().leave(part);
                        const step = try f.env.places.ctorStep(f.gpa, f.account(), ord[0], @intCast(k));
                        const value = try f.project(it.value, step, a.int());
                        try stack.append(f.gpa, .{ .pat = a.int(), .value = try f.below(it.pat, it.value, step, value) });
                    }
                },
                .pat_list => try f.bindList(it.pat, it.value, point, &stack),
                .pat_spread => {},
                else => f.markUnbuilt(it.pat),
            }
        }
    }

    /// A constructor pattern's argument at `s` (§2.13.3) on a recursive
    /// place: one `below(c·s·ι)` per symbolic cell `c` of the matched value
    /// (the cells a projection of `c` puts there replaced) — the levels
    /// under a recursive child, or a non-recursive argument of this one
    /// node — so two matched positions' arguments are apart under their
    /// split's κ and below the matched cells. Otherwise the projection.
    fn below(f: *Frame, p: u32, v: Value, s: Step, projected: Value) Error!Value {
        const shapes = f.env.shapes;
        const cells = f.env.cells;
        const places = f.env.places;
        if (v.node == .none or projected.node == .none) return projected;
        // Over several alternative cells: a product, growth (see `bindList`).
        const task: ?Ids.Account.Kernel = if (several(cells, (try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, v.node)))) try f.account().enter(f.gpa, null) else null;
        defer if (task) |t| f.account().leave(t);
        const at = shapes.place(v.node);
        const child = places.child(at, s) orelse return projected;
        if (shapes.place(projected.node) != child) return projected;
        // On a recursive place every argument is materialised (`level`'s
        // non-recursive ones too, by their step); a non-recursive
        // constructor's arguments are plain projections.
        const recursive = for (places.steps(at).children) |k| {
            if (places.sameCycle(at, k)) break true;
        } else false;
        if (!recursive) return projected;
        const label = try cells.label(f.gpa, f.account(), p, .none, false);
        const kind = Cell.Kind.ofPlace(places.kind(child));
        const split_kappa = try f.env.conds.kappaOf(f.gpa, f.env.charge, f.env.view(), projected.kappa, projected.node, true);
        var refined: SetId = .none;
        var canon: SetId = .none;
        var it = cells.sets.iterate((try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, v.node)));
        while (it.next()) |e| {
            const c: CellId = .from(e.key);
            const o = cells.origin(c);
            if (o == .site or o == .result or o == .esc or o == .top) continue;
            _ = try cells.split(f.gpa, f.account(), c, p, label, split_kappa);
            const b = try cells.refine(f.gpa, f.account(), .below, c, label, s.word(), child, kind);
            refined = try cells.sets.insert(f.gpa, f.env.charge, refined, b.int(), e.value);
            const u = (try cells.unrefined(f.gpa, f.account(), places, b)) orelse continue;
            canon = try cells.sets.insert(f.gpa, f.env.charge, canon, u.int(), 0);
        }
        if (refined == .none) return projected;
        var drop: SetId = .none;
        var ct = cells.sets.iterate((try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, projected.node)));
        while (ct.next()) |e| {
            try f.env.charge.reserve(f.gpa, .inspection, 1);
            const u = (try cells.unrefined(f.gpa, f.account(), places, .from(e.key))) orelse continue;
            if (cells.sets.member(canon, u.int())) drop = try cells.sets.insert(f.gpa, f.env.charge, drop, e.key, 0);
        }
        var node = try shapes.leaf(f.gpa, f.account(), child, refined);
        const explicit = try shapes.without(f.gpa, f.account(), &cells.sets, projected.node, drop, false);
        if (explicit != .none) {
            var two = [_]NodeId{ node, explicit };
            node = try shapes.join(f.gpa, f.account(), places, cells, &two);
        }
        return .{ .node = node, .kappa = projected.kappa };
    }

    /// `proj(v, s)`, at the pattern's or expression's own place when the
    /// place has no such step (a recast, approximate).
    fn project(f: *Frame, v: Value, s: Step, at_inst: u32) Error!Value {
        return f.projectAt(v, s, try f.placeOf(at_inst));
    }

    fn projectAt(f: *Frame, v: Value, s: Step, at: PlaceId) Error!Value {
        const shapes = f.env.shapes;
        if (v.node == .none) return f.topValue(at);
        const n = (try shapes.proj(f.gpa, f.account(), f.env.places, f.env.cells, v.node, s)) orelse
            return .{ .node = try shapes.recast(f.gpa, f.account(), at, v.node), .kappa = v.kappa };
        return .{ .node = n, .kappa = f.env.conds.kappaChild(v.kappa, s) };
    }

    /// `[ a, b, …rest ]` (§2.13.3): per container cell, the positions taken
    /// at this split are `elem` refinements, the rest `others`; a concrete
    /// container's contents are its explicit elements, on both sides.
    fn bindList(f: *Frame, p: u32, v: Value, point: u32, deferred: *std.ArrayList(BindItem)) Error!void {
        const items = f.bir.extraSlice(Bir.inlineRange(f.data(p)), Inst.Index);
        if (items.len == 0) return;
        // Several container cells are inferred alternatives: their per-cell
        // work is a product with the items, growth chosen before the work
        // (§4.1), never an item's baseline.
        const product = several(f.env.cells, (try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, v.node)));
        const task: ?Ids.Account.Kernel = if (product) try f.account().enter(f.gpa, null) else null;
        defer if (task) |t| f.account().leave(t);
        const shapes = f.env.shapes;
        const cells = f.env.cells;
        const list_place = shapes.place(v.node);
        const elem_place = f.env.places.child(list_place, Step.elem) orelse {
            f.markUnbuilt(p);
            return;
        };
        const elem_kind = Cell.Kind.ofPlace(f.env.places.kind(elem_place));
        const label = try cells.label(f.gpa, f.account(), p, .none, false);
        const contents = (try shapes.proj(f.gpa, f.account(), f.env.places, cells, v.node, Step.elem)).?;
        const contents_kappa = f.env.conds.kappaChild(v.kappa, Step.elem);
        const split_kappa = try f.env.conds.kappaOf(f.gpa, f.env.charge, f.env.view(), contents_kappa, contents, true);
        // §2.13.3: a position is `elem(c·ι)` per symbolic container cell `c`
        // (its `[*]` projection, `c[*]`, is what it refines), and the rest's
        // `[*]` `others(c·ι)`. The other cells at `[*]` — a concrete
        // container's explicit elements, a value a push stored — stay as
        // they are, in every position: `explicit`, `contents` without the
        // containers' projections.
        var containers: std.ArrayList(Cell.Radix.Iterator.Entry) = .empty;
        defer containers.deinit(f.gpa);
        var projections: SetId = .none;
        var it = cells.sets.iterate((try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, v.node)));
        while (it.next()) |e| {
            const c: CellId = .from(e.key);
            const o = cells.origin(c);
            if (o == .site or o == .result or o == .esc or o == .top) continue;
            try containers.append(f.gpa, e);
            _ = try cells.split(f.gpa, f.account(), c, p, label, split_kappa);
            const u = (try cells.unrefined(f.gpa, f.account(), f.env.places, try cells.refine(f.gpa, f.account(), .elem, c, label, 0, elem_place, elem_kind))) orelse continue;
            projections = try cells.sets.insert(f.gpa, f.env.charge, projections, u.int(), 0);
        }
        var drop: SetId = .none;
        if (projections != .none) {
            var ct = cells.sets.iterate((try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, contents)));
            while (ct.next()) |e| {
                try f.env.charge.reserve(f.gpa, .inspection, 1);
                const u = (try cells.unrefined(f.gpa, f.account(), f.env.places, .from(e.key))) orelse continue;
                if (cells.sets.member(projections, u.int())) drop = try cells.sets.insert(f.gpa, f.env.charge, drop, e.key, 0);
            }
        }
        const explicit_one = try shapes.without(f.gpa, f.account(), &cells.sets, contents, drop, true);
        // A concrete container's positions share its explicit elements: each
        // position bound to a variable records which it is, under one split
        // of the container whose κ is the contents' (`Demands.Taken`).
        var taken_split: Ids.SplitId = .none;
        it = cells.sets.iterate((try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, v.node)));
        while (it.next()) |e| {
            const o = cells.origin(.from(e.key));
            if (o != .site and o != .result and o != .esc) continue;
            taken_split = try cells.split(f.gpa, f.account(), .from(e.key), p, label, split_kappa);
            break;
        }
        const explicit_cells = if (explicit_one == .none) SetId.none else (try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, explicit_one));
        const explicit_rest = try shapes.without(f.gpa, f.account(), &cells.sets, contents, drop, false);
        var position: u32 = 0;
        for (items) |item| {
            // An item's work over several containers is a product (items ×
            // inferred alternatives): the growth task entered above.
            const kernel = if (product) try f.account().enter(f.gpa, null) else try f.lane(item.int());
            defer f.account().leave(kernel);
            const spread = f.tag(item.int()) == .pat_spread;
            var refined: SetId = .none;
            for (containers.items) |e| {
                const c: CellId = .from(e.key);
                const r = if (spread) try cells.refine(f.gpa, f.account(), .others, c, label, 0, elem_place, elem_kind) else try cells.refine(f.gpa, f.account(), .elem, c, label, position, elem_place, elem_kind);
                refined = try cells.sets.insert(f.gpa, f.env.charge, refined, r.int(), e.value);
            }
            var node = try shapes.leaf(f.gpa, f.account(), elem_place, refined);
            const explicit = if (spread) explicit_rest else explicit_one;
            if (explicit != .none) {
                var two = [_]NodeId{ node, explicit };
                node = if (refined == .none) explicit else try shapes.join(f.gpa, f.account(), f.env.places, cells, &two);
            }
            if (spread) {
                // The rest: the same storage (a view), its contents the others.
                const kids = try shapes.overPut(f.gpa, f.account(), Ids.none_int, Step.elem, node);
                const rest = try shapes.node(f.gpa, f.account(), list_place, (try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, v.node)), kids);
                var k = try f.kappaSet(v.kappa, rest, try f.env.conds.kappaOf(f.gpa, f.env.charge, f.env.view(), v.kappa, try shapes.leaf(f.gpa, f.account(), list_place, (try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, v.node))), false));
                k = try f.kappaSetElem(k, node, split_kappa);
                const rest_pat = f.data(item.int()).lhs;
                // A variable binds here (its holder is marked below); a nested
                // pattern goes on `bind`'s stack.
                if (rest_pat != none and f.tag(rest_pat) == .pat_var) try f.bind(rest_pat, .{ .node = rest, .kappa = k }, point) else try deferred.append(f.gpa, .{ .pat = rest_pat, .value = .{ .node = rest, .kappa = k } });
                // The rest holds every position but the taken ones.
                if (taken_split != .none and rest_pat != none and f.tag(rest_pat) == .pat_var) {
                    const h = f.binding[f.data(rest_pat).lhs];
                    if (h != none) f.holders.items[h].taken = .{ .split = taken_split, .pos = none - 1, .explicit = if (explicit_rest == .none) SetId.none else (try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, explicit_rest)) };
                }
                continue;
            }
            if (f.tag(item.int()) == .pat_var) try f.bind(item.int(), .{ .node = node, .kappa = contents_kappa }, point) else try deferred.append(f.gpa, .{ .pat = item.int(), .value = .{ .node = node, .kappa = contents_kappa } });
            if (taken_split != .none and f.tag(item.int()) == .pat_var) {
                const h = f.binding[f.data(item.int()).lhs];
                if (h != none) f.holders.items[h].taken = .{ .split = taken_split, .pos = position, .explicit = explicit_cells };
            }
            position += 1;
        }
    }

    // ---- constructions ----------------------------------------------------------

    /// A literal's `[*]`: its items collected as positions (§2.3), κ by the
    /// positional rule over them (§2.9).
    fn literal(f: *Frame, i: u32, items: []const u32) Error!Value {
        const at = try f.placeOf(i);
        const shapes = f.env.shapes;
        const cells = f.env.cells;
        const elem_place = f.env.places.child(at, Step.elem) orelse {
            var parts: std.ArrayList(Value) = .empty;
            defer parts.deinit(f.gpa);
            for (items) |item| try parts.append(f.gpa, f.val(item).value);
            return f.opaqueOf(at, parts.items, items);
        };
        const site = try cells.site(f.gpa, f.account(), i, at, .list);
        var kappa: Cond.Kappas = .none;
        // The literal's `[*]`: one position, its items' snapshots merged (§2.9).
        var elem_k: Cond.Kappas = .none;
        var kids: u32 = Ids.none_int;
        if (items.len > 0) {
            var members: std.ArrayList(NodeId) = .empty;
            defer members.deinit(f.gpa);
            var ctxs: std.ArrayList(Cond.Kappas) = .empty;
            defer ctxs.deinit(f.gpa);
            // Each item's fit, κ merge and cells, inserted into the root's set
            // (§2.3, #1098), are as large as the item: growth (`sized`).
            var root_cells: SetId = .none;
            for (items) |item| {
                const kernel = try f.sized();
                defer f.account().leave(kernel);
                const v = try f.fit(f.val(item).value, elem_place);
                try members.append(f.gpa, v.node);
                root_cells = try cells.sets.unionWith(f.gpa, f.env.charge, root_cells, try shapes.cellsOf(f.gpa, f.account(), &cells.sets, v.node));
                try ctxs.append(f.gpa, v.kappa);
                elem_k = try f.env.conds.kappaMerge(f.gpa, f.env.charge, elem_k, v.kappa);
            }
            // The positions DAG, one node per item, and each member's share of
            // the run's condition on its item's lane (§4.1, #1098); what the
            // run does once is a general task.
            const lanes = try f.gpa.alloc(Ids.Lane, items.len);
            defer f.gpa.free(lanes);
            for (items, lanes) |item, *l| l.* = .{ .atom = item, .role = .transfer_settlement };
            const task = try f.account().enter(f.gpa, null);
            defer f.account().leave(task);
            const elems = try shapes.collectRoot(f.gpa, f.account(), &cells.sets, members.items, root_cells, lanes);
            elem_k = try f.env.conds.propagateFrom(f.gpa, f.env.charge, f.env.view(), elem_k, elems, members.items, ctxs.items, .together, true, false, null);
            // Each element at the literal's `[*]`: its own κ there (§2.9: the
            // conditions of `vᵢ` at `p`, relative to `vᵢ`), what a read of a
            // side of the positions node finds.
            for (members.items, ctxs.items) |m, c| {
                const kernel = try f.sized();
                defer f.account().leave(kernel);
                elem_k = try f.kappaSet(elem_k, m, try f.env.conds.kappaOf(f.gpa, f.env.charge, f.env.view(), c, m, false));
            }
            kids = try shapes.overPut(f.gpa, f.account(), kids, Step.elem, elems);
            kappa = try f.env.conds.kappaLink(f.gpa, f.env.charge, kappa, Step.elem, elem_k);
        }
        const node = try shapes.node(f.gpa, f.account(), at, try f.set1(site), kids);
        return .{ .node = node, .kappa = try f.kappaSet(kappa, node, Cond.yes) };
    }

    /// `v` read at place `at`: itself, or a recast when its place differs.
    fn fit(f: *Frame, v: Value, at: PlaceId) Error!Value {
        if (v.node == .none) return f.topValue(at);
        if (f.env.shapes.place(v.node) == at) return v;
        return .{ .node = try f.env.shapes.recast(f.gpa, f.account(), at, v.node), .kappa = v.kappa };
    }

    /// A tuple, a record or a constructor application: a node over its
    /// parts (§2.6), a record's object a fresh `site`.
    fn container(f: *Frame, i: u32, parts: []const u32, steps: []const Step, record: bool) Error!Value {
        const at = try f.placeOf(i);
        const shapes = f.env.shapes;
        if (f.env.places.kind(at) == .cross) return f.nothing(at);
        if (f.env.places.kind(at) == .@"var") {
            var vs: std.ArrayList(Value) = .empty;
            defer vs.deinit(f.gpa);
            for (parts) |p| try vs.append(f.gpa, f.val(p).value);
            return f.opaqueOf(at, vs.items, parts);
        }
        var kids: u32 = Ids.none_int;
        var kappa: Cond.Kappas = .none;
        for (parts, steps) |p, s| {
            // §4.1: each part is in its own atom's lane.
            const kernel = try f.lane(p);
            defer f.account().leave(kernel);
            const child_place = f.env.places.child(at, s) orelse continue;
            const v = try f.fit(f.val(p).value, child_place);
            kids = try shapes.overPut(f.gpa, f.account(), kids, s, v.node);
            // §2.9: each part's snapshot linked under its step, never re-keyed.
            kappa = try f.env.conds.kappaLink(f.gpa, f.env.charge, kappa, s, v.kappa);
        }
        const cells: SetId = if (record) try f.set1(try f.env.cells.site(f.gpa, f.account(), i, at, .record)) else .none;
        const node = try shapes.node(f.gpa, f.account(), at, cells, kids);
        return .{ .node = node, .kappa = try f.kappaSet(kappa, node, Cond.yes) };
    }

    /// The stores of a construction into `base` (§2.9's construction rule):
    /// the base's `[*]` and the stored elements as positions, κ lowered by
    /// each stored value in turn; the result is the base's object.
    /// `atoms[i]` the instruction `stored[i]` comes from, `base_atom` the
    /// base's: each stored item's share on its own lane (§4.1, #1139).
    fn construct(f: *Frame, base: Value, stored: []const Value, base_atom: u32, atoms: []const u32) Error!Value {
        // The base's projection, κ, cells and the put are as large as the
        // base, and the stored items' as large as they: growth (§4.1, #1181).
        // Only the positions nodes are on the items' lanes (`collectRoot`).
        const run = try f.sized();
        defer f.account().leave(run);
        const shapes = f.env.shapes;
        const cells = f.env.cells;
        const at = shapes.place(base.node);
        const elem_place = f.env.places.child(at, Step.elem) orelse {
            var parts: std.ArrayList(Value) = .empty;
            defer parts.deinit(f.gpa);
            try parts.append(f.gpa, base);
            try parts.appendSlice(f.gpa, stored);
            return f.opaqueOf(at, parts.items, null);
        };
        const old = (try shapes.proj(f.gpa, f.account(), f.env.places, cells, base.node, Step.elem)).?;
        var members: std.ArrayList(NodeId) = .empty;
        defer members.deinit(f.gpa);
        try members.append(f.gpa, old);
        // The base's `[*]`, with each stored value's snapshot merged in:
        // they are one position (§2.9).
        var elem_k = f.env.conds.kappaChild(base.kappa, Step.elem);
        var k = try f.env.conds.kappaOf(f.gpa, f.env.charge, f.env.view(), elem_k, old, true);
        var held = (try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, old));
        for (stored) |s| {
            const v = try f.fit(s, elem_place);
            elem_k = try f.env.conds.kappaMerge(f.gpa, f.env.charge, elem_k, v.kappa);
            k = try f.env.conds.lower(f.gpa, f.env.charge, f.env.view(), v.kappa, k, held, v.node, true, null);
            held = try cells.sets.unionWith(f.gpa, f.env.charge, held, (try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, v.node)));
            try members.append(f.gpa, v.node);
        }
        const lanes = try f.gpa.alloc(Ids.Lane, members.items.len);
        defer f.gpa.free(lanes);
        lanes[0] = .{ .atom = base_atom, .role = .transfer_settlement };
        for (atoms, lanes[1..]) |atom, *l| l.* = .{ .atom = atom, .role = .transfer_settlement };
        const elems = try shapes.collectRoot(f.gpa, f.account(), &cells.sets, members.items, Shape.Table.lazy_cells, lanes);
        const node = try shapes.put(f.gpa, f.account(), f.env.places, cells, base.node, Step.elem, elems, true, .none);
        elem_k = try f.kappaSet(elem_k, elems, k);
        var kappa = try f.env.conds.kappaLink(f.gpa, f.env.charge, base.kappa, Step.elem, elem_k);
        kappa = try f.kappaSet(kappa, node, try f.env.conds.kappaOf(f.gpa, f.env.charge, f.env.view(), base.kappa, base.node, false));
        return .{ .node = node, .kappa = kappa };
    }

    fn demand(f: *Frame, point: u32, kind: Facts.DemandKind, base_inst: u32, base: Value, others: []const u32, callee: u32) Error!void {
        const start: u32 = @intCast(f.operands.items.len);
        for (others) |o| try f.operands.append(f.gpa, .{ .value = f.val(o).value, .inst = o });
        const bv = f.val(base_inst);
        try f.demands.append(f.gpa, .{
            .point = point,
            .kind = kind,
            .base = base,
            .base_inst = base_inst,
            .base_local = bv.local,
            .base_path = bv.path,
            .token = f.token(point),
            .callee_inst = callee,
            .operands = .{ .start = start, .len = @intCast(f.operands.items.len - start) },
        });
    }

    /// A spread chain at its root (§2.13.2).
    fn spreadChain(f: *Frame, root: u32, s: Bir.Spread) Error!Value {
        const items = f.bir.spreadItems(s);
        var insts: std.ArrayList(u32) = .empty;
        defer insts.deinit(f.gpa);
        for (items) |it| try insts.append(f.gpa, it[0]);
        for (insts.items) |o| try f.consume(o, root, .whole, .none);
        var first: usize = items.len;
        for (items, 0..) |it, k| if (it[1] == 1) {
            first = k;
            break;
        };
        const at = try f.placeOf(root);
        if (first == items.len) return f.literal(root, insts.items);
        var stored: std.ArrayList(Value) = .empty;
        defer stored.deinit(f.gpa);
        var built = blk: {
            const kernel = try f.sized();
            defer f.account().leave(kernel);
            break :blk try f.fit(f.val(items[first][0]).value, at);
        };
        if (first + 1 < items.len) {
            var atoms: std.ArrayList(u32) = .empty;
            defer atoms.deinit(f.gpa);
            for (items[first + 1 ..]) |it| {
                // Each item's projection is as large as it (§4.1, #1139).
                const kernel = try f.sized();
                defer f.account().leave(kernel);
                try atoms.append(f.gpa, it[0]);
                const v = f.val(it[0]).value;
                if (it[1] == 1) {
                    // A spread's elements are stored.
                    try stored.append(f.gpa, try f.projectAt(v, Step.elem, f.env.places.child(at, Step.elem) orelse at));
                } else try stored.append(f.gpa, v);
            }
            var others: std.ArrayList(u32) = .empty;
            defer others.deinit(f.gpa);
            for (insts.items, 0..) |o, k| if (k != first) try others.append(f.gpa, o);
            try f.demand(root, .construction, items[first][0], built, others.items, none);
            built = try f.construct(built, stored.items, items[first][0], atoms.items);
        }
        if (first == 0) return built;
        return f.prepend(root, at, items[0..first], built, items[first][0]);
    }

    /// `[ x₁…xₖ, …xs ]` (§2.13.2): a fresh list unless it may answer the
    /// base (a re-cons), elements the fronts' and the base's, κ lost —
    /// except when every front is a fresh object by construction.
    fn prepend(f: *Frame, root: u32, at: PlaceId, fronts: []const [2]u32, base: Value, base_atom: u32) Error!Value {
        // The fronts' and the base's work (the base's reach and cells, each
        // put in the root's set when a front is not fresh) is as large as
        // they are: growth (§4.1, #1181). Only the positions nodes are on
        // the items' lanes (`collectRoot`).
        const run = try f.sized();
        defer f.account().leave(run);
        const shapes = f.env.shapes;
        const cells = f.env.cells;
        const elem_place = f.env.places.child(at, Step.elem) orelse {
            var parts: std.ArrayList(Value) = .empty;
            defer parts.deinit(f.gpa);
            try parts.append(f.gpa, base);
            for (fronts) |fr| try parts.append(f.gpa, f.val(fr[0]).value);
            return f.opaqueOf(at, parts.items, null);
        };
        var fresh = true;
        var members: std.ArrayList(NodeId) = .empty;
        defer members.deinit(f.gpa);
        var elem_k = f.env.conds.kappaChild(base.kappa, Step.elem);
        const base_reach = try shapes.reach(f.gpa, f.account(), &cells.sets, base.node);
        for (fronts) |it| {
            const v = try f.fit(f.val(it[0]).value, elem_place);
            try members.append(f.gpa, v.node);
            elem_k = try f.env.conds.kappaMerge(f.gpa, f.env.charge, elem_k, v.kappa);
            const t = f.tag(it[0]);
            if (t == .record or t == .tuple) continue;
            if (t == .call) if (f.ctx.ctorOf(f.ctx.ctx, f.data(it[0]).lhs) != null) continue;
            if (f.env.places.kind(elem_place) != .list) {
                fresh = false;
                continue;
            }
            var ct = cells.sets.iterate((try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, v.node)));
            var any = false;
            while (ct.next()) |e| {
                const o = cells.origin(.from(e.key));
                any = true;
                if (!(o == .site or o == .result) or e.value == 1 or cells.sets.member(base_reach, e.key)) fresh = false;
            }
            if (!any) fresh = false;
        }
        try members.append(f.gpa, (try shapes.proj(f.gpa, f.account(), f.env.places, cells, base.node, Step.elem)).?);
        // One positions node per item, on its lane (§4.1, #1139).
        const lanes = try f.gpa.alloc(Ids.Lane, members.items.len);
        defer f.gpa.free(lanes);
        for (fronts, lanes[0..fronts.len]) |it, *l| l.* = .{ .atom = it[0], .role = .transfer_settlement };
        lanes[fronts.len] = .{ .atom = base_atom, .role = .transfer_settlement };
        const elems = try shapes.collectRoot(f.gpa, f.account(), &cells.sets, members.items, Shape.Table.lazy_cells, lanes);
        var c = try f.set1(try cells.site(f.gpa, f.account(), root, at, .list));
        if (!fresh) {
            var bt = cells.sets.iterate((try f.env.shapes.cellsOf(f.gpa, f.account(), &f.env.cells.sets, base.node)));
            while (bt.next()) |e| c = try cells.sets.insert(f.gpa, f.env.charge, c, e.key, 1);
        }
        const node = try shapes.node(f.gpa, f.account(), at, c, try shapes.overPut(f.gpa, f.account(), Ids.none_int, Step.elem, elems));
        elem_k = try f.kappaSet(elem_k, elems, Cond.lost);
        var kappa = try f.env.conds.kappaLink(f.gpa, f.env.charge, .none, Step.elem, elem_k);
        kappa = try f.kappaSet(kappa, node, if (fresh) Cond.yes else Cond.lost);
        return .{ .node = node, .kappa = kappa };
    }

    /// A `++` chain on lists at its outermost call (R-2.2): one demand on
    /// the leftmost operand, every other operand's elements stored.
    fn appendChain(f: *Frame, root: u32) Error!Value {
        var ops: std.ArrayList(u32) = .empty;
        defer ops.deinit(f.gpa);
        var cur = root;
        while (true) {
            const a = f.args(cur);
            try ops.append(f.gpa, a[0].int());
            const next = a[1].int();
            if (f.tag(next) == .call and f.absorbed[f.rel(next)]) {
                cur = next;
                continue;
            }
            try ops.append(f.gpa, next);
            break;
        }
        for (ops.items) |o| try f.consume(o, root, .whole, .none);
        const at = try f.placeOf(root);
        const base = blk: {
            const kernel = try f.sized();
            defer f.account().leave(kernel);
            break :blk try f.fit(f.val(ops.items[0]).value, at);
        };
        var stored: std.ArrayList(Value) = .empty;
        defer stored.deinit(f.gpa);
        for (ops.items[1..]) |o| {
            const kernel = try f.sized();
            defer f.account().leave(kernel);
            try stored.append(f.gpa, try f.projectAt(f.val(o).value, Step.elem, f.env.places.child(at, Step.elem) orelse at));
        }
        try f.demand(root, .append, ops.items[0], base, ops.items[1..], none);
        return f.construct(base, stored.items, ops.items[0], ops.items[1..]);
    }

    // ---- calls -------------------------------------------------------------------

    fn call(f: *Frame, i: u32, callee_inst: u32, arg_insts: []const Inst.Index) Error!Value {
        // §4.1's call view: the callee's class at this call and its graft.
        const kernel = try f.account().enter(f.gpa, .{ .atom = i, .role = .call_view });
        defer f.account().leave(kernel);
        const at = try f.placeOf(i);
        switch (try f.ctx.callee(f.ctx.ctx, i)) {
            .unbuilt => {
                f.markUnbuilt(i);
                return f.topValue(at);
            },
            .harmless => {
                for (arg_insts) |a| try f.consume(a.int(), i, .whole, .none);
                return f.nothing(at);
            },
            .ctor => |ord| {
                var parts: std.ArrayList(u32) = .empty;
                defer parts.deinit(f.gpa);
                var steps: std.ArrayList(Step) = .empty;
                defer steps.deinit(f.gpa);
                for (arg_insts, 0..) |a, k| {
                    try f.consume(a.int(), i, .whole, .none);
                    try parts.append(f.gpa, a.int());
                    try steps.append(f.gpa, try f.env.places.ctorStep(f.gpa, f.account(), ord, @intCast(k)));
                }
                return f.container(i, parts.items, steps.items, false);
            },
            .class => |class| {
                const uses = f.sums.paramUses(class);
                var argv: std.ArrayList(Value) = .empty;
                defer argv.deinit(f.gpa);
                for (arg_insts, 0..) |a, k| {
                    try f.consume(a.int(), i, .call, if (k < uses.len) uses[k] else .none);
                    try argv.append(f.gpa, f.val(a.int()).value);
                }
                // The graft copies the callee's class over the arguments' structure:
                // named growth until §4.1's call view by reference (#1097, S3b).
                const graft = try f.account().enter(f.gpa, null);
                const applied = Calls.apply(f.env, f.sums, class, argv.items, i, &f.calls) catch |e| {
                    f.account().leave(graft);
                    return e;
                };
                f.account().leave(graft);
                // The callee's `xreq` is discharged on the call's first write, and
                // reported there (§2.11 step 7); a call that writes nothing owes
                // it as the frame's.
                const first_demand = f.demands.items.len;
                for (applied.escapes) |e| {
                    if (e.param >= arg_insts.len) continue;
                    const pos = (try f.positionsAt(argv.items[e.param], applied.steps[e.steps.start..][0..e.steps.len])) orelse continue;
                    try f.escapes.append(f.gpa, .{ .node = pos.node, .point = i });
                }
                for (applied.escaped) |n| try f.escapes.append(f.gpa, .{ .node = n, .point = i });
                const answer = applied.result;
                // Copy out the writes: `apply`'s scratch is reused.
                const writes = try f.gpa.dupe(Calls.Write, applied.writes);
                defer f.gpa.free(writes);
                const steps = try f.gpa.dupe(Step, applied.steps);
                const touched = try f.gpa.dupe(Calls.Touch, applied.touched);
                defer f.gpa.free(touched);
                defer f.gpa.free(steps);
                for (writes) |w| {
                    if (w.param >= arg_insts.len) continue;
                    const base = (try f.positionsAt(argv.items[w.param], steps[w.steps.start..][0..w.steps.len])) orelse continue;
                    var others: std.ArrayList(u32) = .empty;
                    defer others.deinit(f.gpa);
                    for (arg_insts, 0..) |a, k| if (k != w.param) try others.append(f.gpa, a.int());
                    try f.demand(i, if (w.deep) .consumed else .writer, arg_insts[w.param].int(), base, others.items, callee_inst);
                    // Disjoint against every other path of the argument the
                    // callee touches (§2.11 item 3, R-5.1.5): a write at `.x`
                    // while `.y` is read or answered is one object written
                    // twice if the actual's `.x` and `.y` are one.
                    {
                        const dm = &f.demands.items[f.demands.items.len - 1];
                        const wsteps = steps[w.steps.start..][0..w.steps.len];
                        for (touched) |t| {
                            if (t.param != w.param) continue;
                            const tsteps = steps[t.steps.start..][0..t.steps.len];
                            // The written path itself (its positions' distinctness
                            // is the callee's `xreq`), above the write and only
                            // reached, or below an exact
                            // write (inside the written object): not held beside
                            // it. Above it and answered or escaped: it holds the
                            // written object. Below a `[*]` or `⟲` write: another
                            // position the summary path stands for, beside it.
                            if (prefixRelated(wsteps, tsteps)) {
                                if (tsteps.len < wsteps.len and !t.held) continue;
                                if (tsteps.len == wsteps.len) continue;
                                if (tsteps.len > wsteps.len and exactPath(wsteps)) continue;
                            }
                            const pos = (try f.besides((try f.positionsAt(argv.items[w.param], tsteps)) orelse continue, base, &f.demands.items[f.demands.items.len - 1])) orelse continue;
                            try f.operands.append(f.gpa, .{ .value = pos, .inst = arg_insts[w.param].int() });
                            dm.operands.len += 1;
                        }
                    }
                    // The write's path below the argument: the demand's text,
                    // and the part of the argument's local it writes, which
                    // a later read must reach to conflict (§2.8).
                    const wsteps = steps[w.steps.start..][0..w.steps.len];
                    if (wsteps.len != 0) {
                        const dm = &f.demands.items[f.demands.items.len - 1];
                        dm.write_path = try f.extendPath(try f.env.places.rootPath(f.gpa, try f.placeOf(arg_insts[w.param].int())), wsteps);
                        if (dm.base_path != .none) dm.base_path = try f.extendPath(dm.base_path, wsteps);
                    }
                }
                if (f.demands.items.len > first_demand) {
                    const dm = &f.demands.items[first_demand];
                    dm.relies = try f.env.conds.@"and"(f.gpa, f.env.charge, dm.relies, applied.xreq);
                } else f.xreq = try f.env.conds.@"and"(f.gpa, f.env.charge, f.xreq, applied.xreq);
                return answer;
            },
        }
    }

    /// `at` extended by `steps`, as far as the place graph has them.
    fn extendPath(f: *Frame, at: PathId, steps: []const Step) Error!PathId {
        var p = at;
        for (steps) |s| p = (try f.env.places.extend(f.gpa, f.env.charge, p, s)) orelse break;
        return p;
    }

    /// The argument `v` at a class's parameter path `steps`: every position
    /// the path stands for, joined (alternatives at one path). A `⟲` step
    /// stands for every re-entry of the recursive place below the value so
    /// far, at any depth (§2.2's canonical paths): each node reached by one
    /// step or more whose place is that one. A walk of the value, growth
    /// chosen before it (§4.1). Null when no position is left.
    fn positionsAt(f: *Frame, v: Value, steps: []const Step) Error!?Value {
        var has_level = false;
        for (steps) |s| has_level = has_level or s.kind == .level;
        if (!has_level) return try f.along(v, steps);
        const task = try f.account().enter(f.gpa, null);
        defer f.account().leave(task);
        const shapes = f.env.shapes;
        const places = f.env.places;
        var frontier: std.ArrayList(NodeId) = .empty;
        defer frontier.deinit(f.gpa);
        var next: std.ArrayList(NodeId) = .empty;
        defer next.deinit(f.gpa);
        try frontier.append(f.gpa, v.node);
        var seen: stamped.Column(NodeId, void) = .{};
        defer seen.deinit(f.gpa);
        var stack: std.ArrayList(NodeId) = .empty;
        defer stack.deinit(f.gpa);
        for (steps) |s| {
            next.clearRetainingCapacity();
            for (frontier.items) |x| {
                if (s.kind != .level) {
                    if (try shapes.proj(f.gpa, f.account(), places, f.env.cells, x, s)) |n| try next.append(f.gpa, n);
                    continue;
                }
                const p = shapes.place(x);
                seen.deinit(f.gpa);
                seen = .{};
                stack.clearRetainingCapacity();
                try stack.append(f.gpa, x);
                while (stack.pop()) |y| {
                    for (places.steps(shapes.place(y)).steps) |c| {
                        try f.env.charge.reserve(f.gpa, .inspection, 1);
                        if (c.kind == .level) continue;
                        const n = (try shapes.proj(f.gpa, f.account(), places, f.env.cells, y, c)) orelse continue;
                        if (seen.contains(n)) continue;
                        try seen.put(f.gpa, n, {});
                        if (shapes.place(n) == p) try next.append(f.gpa, n);
                        try stack.append(f.gpa, n);
                    }
                }
            }
            std.mem.swap(std.ArrayList(NodeId), &frontier, &next);
        }
        if (frontier.items.len == 0) return null;
        if (frontier.items.len == 1) return .{ .node = frontier.items[0] };
        return .{ .node = try shapes.join(f.gpa, f.account(), places, f.env.cells, frontier.items) };
    }

    /// What `v` reaches beside the write `dm`'s base: the operand a write's
    /// other path is (§2.11 item 3). Two paths of one parameter of this
    /// frame are distinct objects here, as its own walk takes them: its class
    /// marks both and its callers check them, so a cell of another of its
    /// paths is dropped. The base's own cell at a path through `[*]` or `⟲`
    /// stands for several positions, which the class's two paths folded into
    /// one: the write relies on them being distinct, `excl c`, owed upward as
    /// the fold's reliance (§8 S3b). Null when nothing is left.
    fn besides(f: *Frame, v: Value, base: Value, dm: *Demands.Demand) Error!?Value {
        const shapes = f.env.shapes;
        const cells = f.env.cells;
        const own = try shapes.reach(f.gpa, f.account(), &cells.sets, base.node);
        var kept: SetId = .none;
        var it = cells.sets.iterate(try shapes.reach(f.gpa, f.account(), &cells.sets, v.node));
        while (it.next()) |e| {
            try f.env.charge.reserve(f.gpa, .inspection, 1);
            const c: CellId = .from(e.key);
            if (cells.origin(cells.base(c)) == .param) {
                if (!cells.sets.member(own, e.key)) continue;
                if (cells.origin(c) == .param and try f.summaryPath(.from(cells.get(c).b))) {
                    dm.relies = try f.env.conds.@"and"(f.gpa, f.env.charge, dm.relies, try f.env.conds.excl(f.gpa, f.env.charge, c));
                    continue;
                }
            }
            kept = try cells.sets.insert(f.gpa, f.env.charge, kept, e.key, e.value);
        }
        if (kept == .none) return null;
        return .{ .node = try shapes.leaf(f.gpa, f.account(), shapes.place(v.node), kept) };
    }

    /// Whether a path goes through `[*]` or `⟲`: it names several positions.
    fn summaryPath(f: *Frame, p: PathId) Error!bool {
        const places = f.env.places;
        var at = p;
        while (at != .none and places.pathParent(at) != .none) : (at = places.pathParent(at)) {
            try f.env.charge.reserve(f.gpa, .inspection, 1);
            const k = places.pathStep(at).kind;
            if (k == .elem or k == .level) return true;
        }
        return false;
    }
    fn along(f: *Frame, v: Value, steps: []const Step) Error!Value {
        var at = v;
        for (steps) |s| {
            const n = (try f.env.shapes.proj(f.gpa, f.account(), f.env.places, f.env.cells, at.node, s)) orelse return at;
            at = .{ .node = n, .kappa = f.env.conds.kappaChild(at.kappa, s) };
        }
        return at;
    }

    // ---- the walk ----------------------------------------------------------------

    /// One instruction's value (§2.6's table).
    fn eval(f: *Frame, i: u32) Error!Val {
        const d = f.data(i);
        const t = f.tag(i);
        if (f.absorbed[f.rel(i)]) return .{};
        if (t.isType() or t.isPattern()) return .{};
        if (f.chain[f.rel(i)] != none) {
            const s = f.bir.spreads(f.decl)[f.chain[f.rel(i)]];
            return .{ .value = try f.spreadChain(i, s) };
        }
        switch (t) {
            .local => {
                if (!f.bound[d.lhs]) {
                    f.markUnbuilt(i);
                    return .{ .value = try f.topValue(try f.placeOf(i)) };
                }
                const at = try f.ctx.placeOfLocal(f.ctx.ctx, d.lhs);
                return .{ .value = f.locals[d.lhs], .local = d.lhs, .path = try f.env.places.rootPath(f.gpa, at) };
            },
            .field_access, .tuple_index => {
                const target = f.val(d.lhs);
                const step = if (t == .field_access) try Step.field(f.account(), f.ctx.fieldRank(f.ctx.ctx, @fromBackingInt(d.rhs))) else try Step.index(f.account(), d.rhs);
                const v = try f.project(target.value, step, i);
                if (target.local != none) {
                    if (try f.env.places.extend(f.gpa, f.env.charge, target.path, step)) |p| return .{ .value = v, .local = target.local, .path = p };
                    try f.consume(d.lhs, i, .whole, .none);
                }
                return .{ .value = v };
            },
            .top, .ext_value => {
                if (f.isCallee(i)) return .{};
                const idx = f.ctx.sharedIndex(f.ctx.ctx, i) orelse {
                    f.markUnbuilt(i);
                    return .{ .value = try f.topValue(try f.placeOf(i)) };
                };
                const at = try f.placeOf(i);
                const root = try f.env.places.rootPath(f.gpa, at);
                const c = try f.env.cells.symbolic(f.gpa, f.account(), f.env.places, .shared, idx, root, 0);
                return .{ .value = .{ .node = try f.env.shapes.leaf(f.gpa, f.account(), at, try f.set1(c)) } };
            },
            .ctor, .ext_ctor => {
                if (f.isCallee(i)) return .{};
                const ord = f.ctx.ctorOf(f.ctx.ctx, i) orelse {
                    f.markUnbuilt(i);
                    return .{};
                };
                if (ord[1] != 0) {
                    f.markUnbuilt(i);
                    return .{};
                }
                return .{ .value = try f.container(i, &.{}, &.{}, false) };
            },
            .int, .float, .char, .string, .chunk, .unit => return .{ .value = try f.nothing(try f.placeOf(i)) },
            .interp => {
                for (f.bir.extraSlice(Bir.inlineRange(d), Inst.Index)) |p| try f.consume(p.int(), i, .whole, .none);
                return .{ .value = try f.nothing(try f.placeOf(i)) };
            },
            .@"error" => return .{ .value = try f.topValue(try f.placeOf(i)) },
            .list => {
                var items: std.ArrayList(u32) = .empty;
                defer items.deinit(f.gpa);
                for (f.bir.extraSlice(Bir.inlineRange(d), Inst.Index)) |e| {
                    try f.consume(e.int(), i, .whole, .none);
                    try items.append(f.gpa, e.int());
                }
                return .{ .value = try f.literal(i, items.items) };
            },
            .tuple => {
                var parts: std.ArrayList(u32) = .empty;
                defer parts.deinit(f.gpa);
                var steps: std.ArrayList(Step) = .empty;
                defer steps.deinit(f.gpa);
                for (f.bir.extraSlice(Bir.inlineRange(d), Inst.Index), 0..) |e, k| {
                    try f.consume(e.int(), i, .whole, .none);
                    try parts.append(f.gpa, e.int());
                    try steps.append(f.gpa, try Step.index(f.account(), @intCast(k)));
                }
                return .{ .value = try f.container(i, parts.items, steps.items, false) };
            },
            .record => {
                var parts: std.ArrayList(u32) = .empty;
                defer parts.deinit(f.gpa);
                var steps: std.ArrayList(Step) = .empty;
                defer steps.deinit(f.gpa);
                for (f.bir.extraSlice(Bir.inlineRange(d), Bir.Field)) |fld| {
                    try f.consume(fld.value.int(), i, .whole, .none);
                    try parts.append(f.gpa, fld.value.int());
                    try steps.append(f.gpa, try Step.field(f.account(), f.ctx.fieldRank(f.ctx.ctx, fld.name)));
                }
                return .{ .value = try f.container(i, parts.items, steps.items, true) };
            },
            .call => {
                if (f.ctx.isListAppend(f.ctx.ctx, i) and f.args(i).len == 2) return .{ .value = try f.appendChain(i) };
                return .{ .value = try f.call(i, d.lhs, f.args(i)) };
            },
            .method_call => {
                const m = f.bir.extraData(@fromBackingInt(d.rhs), Bir.MethodCall);
                var all: std.ArrayList(Inst.Index) = .empty;
                defer all.deinit(f.gpa);
                try all.append(f.gpa, @fromBackingInt(d.lhs));
                try all.appendSlice(f.gpa, f.bir.extraSlice(.{ .start = m.args_start, .end = m.args_end }, Inst.Index));
                return .{ .value = try f.call(i, i, all.items) };
            },
            .let => return f.val(d.rhs),
            .let_def => {
                const def = f.bir.extraData(@fromBackingInt(d.lhs), Bir.LetDef);
                if (def.params_end != def.params_start) f.markUnbuilt(i);
                return .{};
            },
            .let_pattern => return .{},
            .let_stmt => {
                try f.consume(d.rhs, i, .whole, .none);
                return .{};
            },
            // A branch's value is read where the arm ends (§2.7: the join's
            // uses): the value it evaluates to is used there, in its arm.
            .branch => {
                try f.consume(d.rhs, i, .whole, .none);
                return f.val(d.rhs);
            },
            .case => {
                const branches = f.bir.extraSlice(f.bir.subRange(@fromBackingInt(d.rhs)), Inst.Index);
                var members: std.ArrayList(NodeId) = .empty;
                defer members.deinit(f.gpa);
                var ctxs: std.ArrayList(Cond.Kappas) = .empty;
                defer ctxs.deinit(f.gpa);
                const at = try f.placeOf(i);
                for (branches) |b| {
                    const v = try f.fit(f.val(b.int()).value, at);
                    try members.append(f.gpa, v.node);
                    try ctxs.append(f.gpa, v.kappa);
                }
                if (members.items.len == 0) return .{ .value = try f.nothing(at) };
                // The join walks the arms' values whole: a general task, named
                // growth until it is charged by position (#1098).
                const task = try f.account().enter(f.gpa, null);
                defer f.account().leave(task);
                const copy = try f.gpa.dupe(NodeId, members.items);
                defer f.gpa.free(copy);
                // One arm runs: its arms are exclusive alternatives (§2.3).
                const joined = try f.env.shapes.joinChoice(f.gpa, f.account(), f.env.places, f.env.cells, copy);
                var kappa: Cond.Kappas = .none;
                for (ctxs.items) |k| kappa = try f.env.conds.kappaMerge(f.gpa, f.env.charge, kappa, k);
                kappa = try f.env.conds.propagate(f.gpa, f.env.charge, f.env.view(), kappa, joined, members.items, ctxs.items, .alternatives, false, null);
                return .{ .value = .{ .node = joined, .kappa = kappa } };
            },
            else => {
                // lambda, record_update, try, markup, type_dispatch, schemas.
                f.markUnbuilt(i);
                return .{ .value = try f.topValue(try f.placeOf(i)) };
            },
        }
    }

    fn isCallee(f: *const Frame, i: u32) bool {
        const c = f.consumer[f.rel(i)];
        return c != none and (f.tag(c) == .call or f.tag(c) == .pat_ctor) and f.data(c).lhs == i;
    }

    /// Walk every instruction in order: bind the parameters, evaluate, bind
    /// `let` values and match patterns where they complete, mark computed
    /// operands pending, record the body's value as a whole use (a return).
    pub fn walk(f: *Frame) Error!void {
        try f.prepare();
        const params = f.bir.extraSlice(.{ .start = f.decl.params_start, .end = f.decl.params_end }, Inst.Index);
        for (params, 0..) |p, k| {
            const kernel = try f.account().enter(f.gpa, .{ .atom = p.int(), .role = .direct_data });
            defer f.account().leave(kernel);
            // A pattern has no type of its own; a variable has its local's.
            const at = if (k < f.param_places.len) f.param_places[k] else if (f.tag(p.int()) == .pat_var) try f.ctx.placeOfLocal(f.ctx.ctx, f.data(p.int()).lhs) else try f.placeOf(p.int());
            const root = try f.env.places.rootPath(f.gpa, at);
            const c = try f.env.cells.symbolic(f.gpa, f.account(), f.env.places, .param, @intCast(k), root, 0);
            const kids = f.env.places.kind(at);
            const v: Value = if (kids == .cross) try f.nothing(at) else .{ .node = try f.env.shapes.leaf(f.gpa, f.account(), at, try f.set1(c)) };
            try f.bind(p.int(), v, p.int());
        }
        var i = f.decl.inst_start.int();
        while (i < f.decl.inst_end.int()) : (i += 1) {
            if (f.unbuilt != none) return;
            // §4.1: an instruction's transfer is its own settlement kernel.
            const kernel = try f.account().enter(f.gpa, .{ .atom = i, .role = .transfer_settlement });
            defer f.account().leave(kernel);
            const r = f.rel(i);
            const t = f.tag(i);
            if (f.matches[r] != none) {
                // A case arm's pattern root: match the scrutinee here.
                try f.bind(i, f.val(f.matches[r]).value, i);
                continue;
            }
            f.vals[r] = try f.eval(i);
            if (t.isType() or t.isPattern()) continue;
            // A `let` value completes its binding; a `let` pattern its match.
            const c = f.consumer[r];
            if (c != none and f.tag(c) == .let_def and f.data(c).rhs == i) {
                const def = f.bir.extraData(@fromBackingInt(f.data(c).lhs), Bir.LetDef);
                try f.consume(i, c, .whole, .none);
                try f.bindLocal(def.local, f.vals[r].value, i);
                continue;
            }
            if (f.binds[r] != none) {
                try f.consume(i, c, .whole, .none);
                try f.bind(f.binds[r], f.vals[r].value, i);
                continue;
            }
            if (c != none and f.tag(c) == .case and f.data(c).lhs == i) {
                try f.consume(i, c, .whole, .none);
                continue;
            }
            try f.pending(i);
        }
        if (f.decl.body.unwrap()) |body| try f.consume(body.int(), body.int(), .whole, .none);
    }

    /// The value of the body: what the declaration returns.
    pub fn result(f: *const Frame) Value {
        const body = f.decl.body.unwrap() orelse return .{};
        return f.val(body.int()).value;
    }
};

/// Whether one step path is a prefix of the other: the same object, or one
/// inside the other.
fn prefixRelated(a: []const Step, b: []const Step) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| if (!std.meta.eql(x, y)) return false;
    return true;
}

/// Whether a step path names one position: no `[*]` or `⟲` in it.
fn exactPath(steps: []const Step) bool {
    for (steps) |s| if (s.kind == .elem or s.kind == .level) return false;
    return true;
}
