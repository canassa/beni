//! The ownership checker's first slice: report mode, one declaration at a
//! time (`docs/design/ownership-checker.md`, normative; the argument is the
//! thesis `docs/thesis/ownership/`).
//!
//! For every *demand* — a `core/List` writer, a list construction with a
//! spread, a `++` chain on lists (§3) — it decides whether the list the
//! demand would write in place is *unique at the site*: no holder of it is
//! read afterwards (thesis §3.3). It changes nothing a program does: it runs
//! only under `beni dump --stage=ownership`, after the checker, and prints
//! one line per demand (§9).
//!
//! **The walk** (§2.1) is BIR's expression tree in evaluation order —
//! callee, arguments left to right, then the call — with a point per
//! consuming instruction. Abstract values map paths to abstract cells (§4);
//! a variable is used at the instruction that consumes it (§7.1); a `case`
//! arm is a branch context, and a lambda's body is a frame of its own (§7.2,
//! §7.3). Calls with no row are conservative, exactly as §6.1 says.
//!
//! **Determinism** (§10): modules in the order the caller gives (path
//! order), declarations in source order, every id assigned in the walk;
//! nothing printed is an id.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Check = @import("../check/Check.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Types = @import("../check/Types.zig");
const SourceStore = @import("../SourceStore.zig");
const Token = @import("../lex/Token.zig");

const Inst = Bir.Inst;
const Symbol = InternPool.Symbol;
const Var = TypeStore.Var;
const TypeId = TypeStore.TypeId;

const Ownership = @This();

pub const none: u32 = std.math.maxInt(u32);

/// k: the path cut (§4.1, thesis §3.1).
pub const k_limit: u32 = 8;
/// Depth of a walk over a type before it answers conservatively.
const type_depth: u32 = 16;

pub const Position = struct { line: u32, col: u32 };

pub const Positions = struct {
    ctx: *const anyopaque,
    get: *const fn (ctx: *const anyopaque, module: u32, token: u32) Position,
};

pub const Input = struct {
    gpa: Allocator,
    graph: *const Graph,
    /// Per module index.
    birs: []const *const Bir,
    provenance: []const Interface.Provenance,
    /// Per module index; shorter when a module was not checked.
    dispatch: []const Dispatch,
    /// Per module index: the kept check tables; shorter, or with an empty
    /// `inst_type`, when a module was not checked.
    modules: []Check.Module,
    types: *const Types,
    interner: *const InternPool.Global,
    /// Per module index.
    module_names: []const []const u8,
    packages: []const SourceStore.Package,
    /// Per module index: the file's token tags.
    spans: []const Token.Spans,
    positions: Positions,
};

/// §8.2.
pub const Accept = enum { fresh, call, param, callback_param };

/// §8.3, in its order.
pub const Cause = enum {
    unknown,
    escaped,
    top_level,
    captured_edit,
    disjoint,
    held_operand,
    later_use,
    alias,
    captured,
    element,
    call,

    pub fn text(c: Cause) []const u8 {
        return switch (c) {
            .unknown => "unknown",
            .escaped => "escaped",
            .top_level => "top-level",
            .captured_edit => "captured-edit",
            .disjoint => "disjoint",
            .held_operand => "held-operand",
            .later_use => "later-use",
            .alias => "alias",
            .captured => "captured",
            .element => "element",
            .call => "call",
        };
    }

    pub fn approximate(c: Cause) bool {
        return switch (c) {
            .unknown, .escaped, .captured_edit, .element, .call => true,
            else => false,
        };
    }
};

pub const Verdict = union(enum) {
    accepted: Accept,
    rejected: Cause,
};

/// One line of the report (§9.1).
pub const Demand = struct {
    position: Position,
    /// `construction`, `++`, or `List.<writer>`.
    op: []const u8,
    base: []const u8,
    verdict: Verdict,
    /// For an acceptance by `param`, the parameter; for a rejection, the
    /// reason after the cause.
    detail: []const u8,
};

pub const ModuleReport = struct {
    module: u32,
    checked: bool,
    demands: []const Demand,
};

in: Input,
/// Owns everything a report holds.
out: std.heap.ArenaAllocator,
paths: Paths,
/// Per `TypeId`, a column: null until computed.
nominal: []?NominalFacts = &.{},
ctor_ids: std.AutoHashMapUnmanaged(u64, u32) = .empty,

pub fn init(in: Input) Ownership {
    return .{ .in = in, .out = .init(in.gpa), .paths = .{} };
}

pub fn deinit(o: *Ownership) void {
    o.out.deinit();
    o.paths.deinit(o.in.gpa);
    o.in.gpa.free(o.nominal);
    o.ctor_ids.deinit(o.in.gpa);
}

/// The report for `targets`, in their order.
pub fn run(o: *Ownership, targets: []const u32) Allocator.Error![]const ModuleReport {
    const arena = o.out.allocator();
    const reports = try arena.alloc(ModuleReport, targets.len);
    var scratch: std.heap.ArenaAllocator = .init(o.in.gpa);
    defer scratch.deinit();
    for (targets, reports) |m, *r| {
        r.* = .{ .module = m, .checked = false, .demands = &.{} };
        if (m >= o.in.modules.len) continue;
        const km = &o.in.modules[m];
        const bir = o.in.birs[m];
        if (km.inst_type.len != bir.insts.len or km.local_type.len != bir.locals.len) continue;
        r.checked = true;
        var demands: std.ArrayList(Demand) = .empty;
        for (bir.decls, 0..) |d, di| {
            if (d.kind != .value) continue;
            const body = d.body.unwrap() orelse continue;
            _ = scratch.reset(.retain_capacity);
            var w: Walker = .{
                .o = o,
                .m = m,
                .bir = bir,
                .decl = d,
                .decl_index = @intCast(di),
                .store = &km.store,
                .inst_type = km.inst_type,
                .local_type = km.local_type[d.locals_start..d.locals_end],
                .a = scratch.allocator(),
            };
            try w.walkDecl(body);
            try w.resolve(&demands);
        }
        // Source order: by position, which is a function of the text.
        std.mem.sort(Demand, demands.items, {}, struct {
            fn less(_: void, x: Demand, y: Demand) bool {
                if (x.position.line != y.position.line) return x.position.line < y.position.line;
                if (x.position.col != y.position.col) return x.position.col < y.position.col;
                return std.mem.lessThan(u8, x.op, y.op);
            }
        }.less);
        r.demands = try demands.toOwnedSlice(arena);
    }
    return reports;
}

// ---------------------------------------------------------------------------
// Paths (§4.1)
// ---------------------------------------------------------------------------

const StepKind = enum(u8) { field, tuple, ctor, elem, env, any };

const Paths = struct {
    parent: std.ArrayList(u32) = .empty,
    kind: std.ArrayList(StepKind) = .empty,
    arg: std.ArrayList(u32) = .empty,
    depth: std.ArrayList(u8) = .empty,
    map: std.AutoHashMapUnmanaged([3]u32, u32) = .empty,

    fn deinit(p: *Paths, gpa: Allocator) void {
        p.parent.deinit(gpa);
        p.kind.deinit(gpa);
        p.arg.deinit(gpa);
        p.depth.deinit(gpa);
        p.map.deinit(gpa);
    }
};

/// ε, the empty path. Its id is 0 once `Paths` has been seeded.
const eps: u32 = 0;

fn seedPaths(o: *Ownership) Allocator.Error!void {
    if (o.paths.parent.items.len != 0) return;
    const gpa = o.in.gpa;
    try o.paths.parent.append(gpa, none);
    try o.paths.kind.append(gpa, .any);
    try o.paths.arg.append(gpa, 0);
    try o.paths.depth.append(gpa, 0);
}

fn child(o: *Ownership, parent: u32, kind: StepKind, arg: u32) Allocator.Error!u32 {
    try o.seedPaths();
    // The cut: a path never grows past k steps; a `⋆` absorbs what is below it.
    if (o.paths.depth.items[parent] >= k_limit) return parent;
    if (parent != eps and o.paths.kind.items[parent] == .any) return parent;
    const key: [3]u32 = .{ parent, @backingInt(kind), arg };
    const gop = try o.paths.map.getOrPut(o.in.gpa, key);
    if (gop.found_existing) return gop.value_ptr.*;
    const id: u32 = @intCast(o.paths.parent.items.len);
    gop.value_ptr.* = id;
    try o.paths.parent.append(o.in.gpa, parent);
    try o.paths.kind.append(o.in.gpa, kind);
    try o.paths.arg.append(o.in.gpa, arg);
    try o.paths.depth.append(o.in.gpa, o.paths.depth.items[parent] + 1);
    return id;
}

const Step = struct { kind: StepKind, arg: u32 };

/// The steps of `p`, root first.
fn steps(o: *const Ownership, p: u32, buf: *[k_limit + 1]Step) []const Step {
    const n: usize = o.paths.depth.items[p];
    var at = p;
    var i = n;
    while (i > 0) {
        i -= 1;
        buf[i] = .{ .kind = o.paths.kind.items[at], .arg = o.paths.arg.items[at] };
        at = o.paths.parent.items[at];
    }
    return buf[0..n];
}

/// `s` followed by `p`'s steps.
fn prepend(o: *Ownership, s: Step, p: u32) Allocator.Error!u32 {
    var buf: [k_limit + 1]Step = undefined;
    const rest = o.steps(p, &buf);
    var at = try o.child(eps, s.kind, s.arg);
    for (rest) |r| at = try o.child(at, r.kind, r.arg);
    return at;
}

/// `p`'s steps followed by `q`'s.
fn concat(o: *Ownership, p: u32, q: u32) Allocator.Error!u32 {
    var buf: [k_limit + 1]Step = undefined;
    var at = p;
    for (o.steps(q, &buf)) |r| at = try o.child(at, r.kind, r.arg);
    return at;
}

/// Whether one path is a prefix of the other, step by step, with `⋆`
/// overlapping anything (§4.1).
fn overlap(o: *const Ownership, p: u32, q: u32) bool {
    var bp: [k_limit + 1]Step = undefined;
    var bq: [k_limit + 1]Step = undefined;
    const sp = o.steps(p, &bp);
    const sq = o.steps(q, &bq);
    const n = @min(sp.len, sq.len);
    for (0..n) |i| {
        if (sp[i].kind == .any or sq[i].kind == .any) return true;
        if (sp[i].kind != sq[i].kind or sp[i].arg != sq[i].arg) return false;
    }
    return true;
}

fn hasStep(o: *const Ownership, p: u32, kind: StepKind) bool {
    var at = p;
    while (at != eps and at != none) : (at = o.paths.parent.items[at]) {
        if (o.paths.kind.items[at] == kind) return true;
    }
    return false;
}

fn firstStep(o: *const Ownership, p: u32) ?Step {
    if (p == eps) return null;
    var at = p;
    while (o.paths.parent.items[at] != eps) at = o.paths.parent.items[at];
    return .{ .kind = o.paths.kind.items[at], .arg = o.paths.arg.items[at] };
}

/// `p` without its first step.
fn dropFirst(o: *Ownership, p: u32) Allocator.Error!u32 {
    var buf: [k_limit + 1]Step = undefined;
    const s = o.steps(p, &buf);
    var at: u32 = eps;
    for (s[1..]) |r| at = try o.child(at, r.kind, r.arg);
    return at;
}

fn writePath(o: *const Ownership, w: *std.Io.Writer, p: u32) std.Io.Writer.Error!void {
    var buf: [k_limit + 1]Step = undefined;
    for (o.steps(p, &buf)) |s| switch (s.kind) {
        .field => try w.print(".{s}", .{o.in.interner.slice(@fromBackingInt(@intCast(s.arg)))}),
        .tuple => try w.print(".{d}", .{s.arg}),
        .ctor => try w.writeAll("#"),
        .elem => try w.writeAll("[*]"),
        .env => try w.writeAll("◇"),
        .any => try w.writeAll("⋆"),
    };
}

fn ctorId(o: *Ownership, module: u32, index: u32) Allocator.Error!u32 {
    const key = (@as(u64, module) << 32) | index;
    const gop = try o.ctor_ids.getOrPut(o.in.gpa, key);
    if (!gop.found_existing) gop.value_ptr.* = @intCast(o.ctor_ids.count() - 1);
    return gop.value_ptr.*;
}

// ---------------------------------------------------------------------------
// Crossing and sharing over types (§4.4, §6.1)
// ---------------------------------------------------------------------------

const NominalFacts = struct {
    /// A `List`, a function or a non-primitive `foreign type` is reachable
    /// in the body without going through a type parameter.
    own: bool = false,
    /// A type parameter is reachable in the body.
    params: bool = false,
    /// One constructor of one field: the release representation may make a
    /// value of it its field (thesis §3.1, A10).
    unboxed: bool = false,
};

fn isPrimitive(o: *const Ownership, id: TypeId) bool {
    const wk = o.in.types.well_known;
    return id == wk.int or id == wk.float or id == wk.char or id == wk.string;
}

fn nominalFacts(o: *Ownership, id: TypeId) Allocator.Error!NominalFacts {
    if (id == .none or id.int() >= o.in.types.entries.len) return .{ .own = true };
    if (o.nominal.len == 0) {
        o.nominal = try o.in.gpa.alloc(?NominalFacts, o.in.types.entries.len);
        @memset(o.nominal, null);
    }
    if (o.nominal[id.int()]) |f| return f;
    // Optimistic while in progress: a type's own recursion adds nothing
    // its other edges do not (the least fixpoint of "holds a cell").
    o.nominal[id.int()] = .{};
    const e = o.in.types.entries[id.int()];
    var facts: NominalFacts = .{};
    if (e.schema_endpoint) {
        facts.own = true;
    } else switch (e.kind) {
        .foreign => facts.own = id == o.in.types.well_known.list or !o.isPrimitive(id),
        .alias, .adt => {
            const m = e.module.int();
            const bir = o.in.birs[m];
            const d = bir.decl(e.decl);
            if (e.kind == .alias) {
                if (d.annotation.unwrap()) |body| facts = try o.birTypeFacts(m, bir, body, 0);
            } else {
                const ctors = bir.declCtors(d);
                for (ctors) |c| {
                    const args = bir.extraSlice(.{ .start = c.args_start, .end = c.args_end }, Inst.Index);
                    for (args) |arg| {
                        const f = try o.birTypeFacts(m, bir, arg, 0);
                        facts.own = facts.own or f.own;
                        facts.params = facts.params or f.params;
                    }
                }
                if (ctors.len == 1) {
                    facts.unboxed = bir.extraSlice(.{ .start = ctors[0].args_start, .end = ctors[0].args_end }, Inst.Index).len == 1;
                }
            }
        },
    }
    o.nominal[id.int()] = facts;
    return facts;
}

fn birTypeFacts(o: *Ownership, m: u32, bir: *const Bir, inst: Inst.Index, depth: u32) Allocator.Error!NominalFacts {
    if (depth > type_depth) return .{ .own = true };
    const tag = bir.instTag(inst);
    const data = bir.instData(inst);
    const graph_m: Graph.Index = @fromBackingInt(@intCast(m));
    switch (tag) {
        .type_fn => return .{ .own = true },
        .type_var => return .{ .params = true },
        .type_unit => return .{},
        .type_tuple => {
            var f: NominalFacts = .{};
            for (bir.extraSlice(Bir.inlineRange(data), Inst.Index)) |el| f = join(f, try o.birTypeFacts(m, bir, el, depth + 1));
            return f;
        },
        .type_record => {
            var f: NominalFacts = .{};
            for (bir.extraSlice(Bir.inlineRange(data), Bir.Field)) |fl| f = join(f, try o.birTypeFacts(m, bir, fl.value, depth + 1));
            return f;
        },
        .type_record_ext => {
            var f: NominalFacts = .{ .params = true };
            for (bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(data.rhs))), Bir.Field)) |fl| f = join(f, try o.birTypeFacts(m, bir, fl.value, depth + 1));
            return f;
        },
        .type_top, .ext_type, .schema_type_top, .ext_schema_type => {
            const nf = try o.nominalFacts(o.in.types.headId(graph_m, tag, data));
            return .{ .own = nf.own };
        },
        .type_app => {
            const head: Inst.Index = @fromBackingInt(@intCast(data.lhs));
            const nf = try o.nominalFacts(o.in.types.headId(graph_m, bir.instTag(head), bir.instData(head)));
            var f: NominalFacts = .{ .own = nf.own };
            if (nf.params) for (bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(data.rhs))), Inst.Index)) |arg| {
                f = join(f, try o.birTypeFacts(m, bir, arg, depth + 1));
            };
            return f;
        },
        else => return .{ .own = true },
    }
}

fn join(a: NominalFacts, b: NominalFacts) NominalFacts {
    return .{ .own = a.own or b.own, .params = a.params or b.params };
}

/// Whether a value of this type may hold a cell (§4.4: it does not cross).
fn tracked(o: *Ownership, store: *TypeStore, v: Var, depth: u32) Allocator.Error!bool {
    if (depth > type_depth) return true;
    switch (store.resolvedContent(v)) {
        .flex, .rigid, .err => return true,
        .alias => return true,
        .structure => |s| switch (s) {
            .unit, .empty_record => return false,
            .func => return true,
            .tuple => |r| {
                for (store.vars(r)) |el| if (try o.tracked(store, el, depth + 1)) return true;
                return false;
            },
            .record => |r| {
                for (store.fields(r.fields)) |f| if (try o.tracked(store, f.value, depth + 1)) return true;
                return o.tracked(store, r.ext, depth + 1);
            },
            .app => |a| {
                if (a.type == o.in.types.well_known.list) return true;
                const nf = try o.nominalFacts(a.type);
                if (nf.own) return true;
                if (nf.params) for (store.vars(a.args)) |arg| if (try o.tracked(store, arg, depth + 1)) return true;
                return false;
            },
        },
    }
}

fn unboxed(o: *Ownership, id: TypeId) Allocator.Error!bool {
    return (try o.nominalFacts(id)).unboxed;
}

/// Whether the type variable `v` occurs inside `t`, below its root: a value
/// of type `v` can then be neither a `t` nor hold one, since no value is
/// cyclic (§6.1) — an element of a `List a` is never the list.
fn occursBelow(store: *TypeStore, v: Var, t: Var, depth: u32) bool {
    if (depth > type_depth) return false;
    const root, const c = store.resolved(t);
    if (depth > 0 and root == v) return true;
    return switch (c) {
        .structure => |s| switch (s) {
            .unit, .empty_record => false,
            .func => |f| blk: {
                for (store.vars(f.params)) |p| if (occursBelow(store, v, p, depth + 1)) break :blk true;
                break :blk occursBelow(store, v, f.result, depth + 1);
            },
            .tuple => |r| blk: {
                for (store.vars(r)) |el| if (occursBelow(store, v, el, depth + 1)) break :blk true;
                break :blk false;
            },
            .record => |r| blk: {
                for (store.fields(r.fields)) |f| if (occursBelow(store, v, f.value, depth + 1)) break :blk true;
                break :blk occursBelow(store, v, r.ext, depth + 1);
            },
            .app => |a| blk: {
                for (store.vars(a.args)) |arg| if (occursBelow(store, v, arg, depth + 1)) break :blk true;
                break :blk false;
            },
        },
        else => false,
    };
}

fn isVar(store: *TypeStore, v: Var) ?Var {
    const root, const c = store.resolved(v);
    return switch (c) {
        .flex, .rigid => root,
        else => null,
    };
}

/// Whether a value of type `a` may be the same run-time object as one of
/// type `b` (§6.1).
fn mayShare(o: *Ownership, store: *TypeStore, a: Var, b: Var, depth: u32) Allocator.Error!bool {
    if (depth > type_depth) return true;
    if (isVar(store, a)) |va| if (occursBelow(store, va, b, 0)) return false;
    if (isVar(store, b)) |vb| if (occursBelow(store, vb, a, 0)) return false;
    const ca = store.resolvedContent(a);
    const cb = store.resolvedContent(b);
    const sa = switch (ca) {
        .structure => |s| s,
        else => return true,
    };
    const sb = switch (cb) {
        .structure => |s| s,
        else => return true,
    };
    switch (sa) {
        .app => |x| {
            if (try o.unboxed(x.type)) return true;
            switch (sb) {
                .app => |y| {
                    if (try o.unboxed(y.type)) return true;
                    if (x.type != y.type) return false;
                    const xs = store.vars(x.args);
                    const ys = store.vars(y.args);
                    if (xs.len != ys.len) return true;
                    for (xs, ys) |p, q| if (!try o.mayShare(store, p, q, depth + 1)) return false;
                    return true;
                },
                else => return false,
            }
        },
        .func => return sb == .func or (sb == .app and try o.unboxed(sb.app.type)),
        .record => return sb == .record or (sb == .app and try o.unboxed(sb.app.type)),
        .tuple => return sb == .tuple or (sb == .app and try o.unboxed(sb.app.type)),
        .unit, .empty_record => return false,
    }
}

/// Whether a value of type `r`, or a part of it, may be the same object
/// as a value of type `t` (§6.1).
fn mayHold(o: *Ownership, store: *TypeStore, r: Var, t: Var, depth: u32) Allocator.Error!bool {
    if (depth > type_depth) return true;
    if (isVar(store, r)) |vr| if (occursBelow(store, vr, t, 0)) return false;
    if (try o.mayShare(store, r, t, depth)) return true;
    switch (store.resolvedContent(r)) {
        .flex, .rigid, .err, .alias => return true,
        .structure => |s| switch (s) {
            .unit, .empty_record => return false,
            .func => return true,
            .tuple => |rg| {
                for (store.vars(rg)) |el| if (try o.mayHold(store, el, t, depth + 1)) return true;
                return false;
            },
            .record => |rc| {
                for (store.fields(rc.fields)) |f| if (try o.mayHold(store, f.value, t, depth + 1)) return true;
                return o.tracked(store, rc.ext, depth + 1);
            },
            .app => |a| {
                if (a.type == o.in.types.well_known.list) {
                    for (store.vars(a.args)) |arg| if (try o.mayHold(store, arg, t, depth + 1)) return true;
                    return false;
                }
                const nf = try o.nominalFacts(a.type);
                // A body we do not instantiate: it may hold anything it holds.
                if (nf.own) return true;
                if (nf.params) for (store.vars(a.args)) |arg| if (try o.mayHold(store, arg, t, depth + 1)) return true;
                return false;
            },
        },
    }
}

// ---------------------------------------------------------------------------
// One declaration
// ---------------------------------------------------------------------------

const CellKind = enum(u8) { site, param, result, env, shared, top, closure };

const Cell = struct {
    kind: CellKind,
    /// site/result: the instruction; param: the parameter pattern
    /// instruction; env: the captured local; shared: the module; closure:
    /// its index.
    a: u32,
    /// shared: the declaration; param: 1 for a lambda's or local
    /// function's parameter, 0 for the declaration's own.
    b: u32 = 0,
    path: u32 = eps,
    ty: Var.Optional = .none,
};

const Entry = struct {
    path: u32,
    cell: u32,
    /// 0 when exact; else 1 + the instruction of the conservative call
    /// whose aliasing put the entry here (§8.4).
    approx: u32 = 0,
};

const AV = []const Entry;

const Capture = struct { local: u32, path: u32 };

const Closure = struct { captures: []const Capture };

const Use = struct {
    local: u32,
    path: u32,
    /// A record update's base is used at every path but these fields.
    except: []const u32 = &.{},
    point: u32,
    frame: u32,
    ctx: u32,
    token: u32,
};

const Holder = struct {
    local: u32,
    path: u32,
    approx: u32,
};

const DemandRec = struct {
    token: u32,
    op: []const u8,
    base: []const u8,
    /// The root local of the base when it is a variable path.
    base_local: u32,
    base_path: u32,
    point: u32,
    frame: u32,
    ctx: u32,
    element: bool,
    accept: Accept,
    prelim: ?struct { cause: Cause, detail: []const u8 },
    holders: []const Holder,
};

const Pending = struct { av: AV, frame: u32, token: u32, is_ref: bool, by_call: bool };

const CtxNode = struct { parent: u32, case_id: u32, arm: u32, depth: u32 };

const Frame = struct {
    /// The enclosing frame, or `none` for the declaration's.
    parent: u32,
    captures: std.ArrayList(Capture) = .empty,
    pending_base: usize,
};

const PatSite = struct { list: Inst.Index, index: u32, spread: bool };

const Walker = struct {
    o: *Ownership,
    m: u32,
    bir: *const Bir,
    decl: Bir.Decl,
    decl_index: u32,
    store: *TypeStore,
    inst_type: []const Var.Optional,
    local_type: []const Var.Optional,
    a: Allocator,

    point: u32 = 0,
    cells: std.ArrayList(Cell) = .empty,
    cell_map: std.AutoHashMapUnmanaged([4]u32, u32) = .empty,
    local_av: []?AV = &.{},
    local_frame: []u32 = &.{},
    local_ctx: []u32 = &.{},
    pat_site: []?PatSite = &.{},
    frames: std.ArrayList(Frame) = .empty,
    frame: u32 = 0,
    ctx_nodes: std.ArrayList(CtxNode) = .empty,
    ctx: u32 = 0,
    cases: u32 = 0,
    pending: std.ArrayList(Pending) = .empty,
    uses: std.ArrayList(Use) = .empty,
    demands: std.ArrayList(DemandRec) = .empty,
    escaped: std.ArrayList([2]u32) = .empty,
    closures: std.ArrayList(Closure) = .empty,

    // ---- setup -------------------------------------------------------------

    fn walkDecl(w: *Walker, body: Inst.Index) Allocator.Error!void {
        try w.o.seedPaths();
        const n = w.decl.locals_end - w.decl.locals_start;
        w.local_av = try w.a.alloc(?AV, n);
        @memset(w.local_av, null);
        w.local_frame = try w.a.alloc(u32, n);
        @memset(w.local_frame, 0);
        w.local_ctx = try w.a.alloc(u32, n);
        @memset(w.local_ctx, 0);
        w.pat_site = try w.a.alloc(?PatSite, n);
        @memset(w.pat_site, null);
        try w.ctx_nodes.append(w.a, .{ .parent = none, .case_id = none, .arm = 0, .depth = 0 });
        try w.frames.append(w.a, .{ .parent = none, .pending_base = 0 });
        const params = w.bir.extraSlice(.{ .start = w.decl.params_start, .end = w.decl.params_end }, Inst.Index);
        for (params) |p| try w.bindParam(p, 0);
        const result = try w.eval(body);
        _ = result;
        try w.consume(&.{body}, w.bir.insts.items(.main_token)[body.int()]);
    }

    fn bindParam(w: *Walker, pat: Inst.Index, lambda: u32) Allocator.Error!void {
        const ty = w.patternType(pat);
        if (ty) |v| if (!try w.o.tracked(w.store, v, 0)) return w.bindPattern(pat, &.{});
        const c = try w.cell(.{ .kind = .param, .a = pat.int(), .b = lambda, .ty = if (ty) |v| v.toOptional() else .none });
        const av = try w.a.dupe(Entry, &.{.{ .path = eps, .cell = c }});
        try w.bindPattern(pat, av);
    }

    fn patternType(w: *const Walker, pat: Inst.Index) ?Var {
        return switch (w.bir.instTag(pat)) {
            .pat_var => w.localType(w.bir.instData(pat).lhs),
            .pat_as => w.localType(w.bir.instData(pat).rhs),
            else => null,
        };
    }

    fn localType(w: *const Walker, l: u32) ?Var {
        if (l >= w.local_type.len) return null;
        return w.local_type[l].unwrap();
    }

    fn instType(w: *const Walker, inst: Inst.Index) ?Var {
        if (inst.int() >= w.inst_type.len) return null;
        return w.inst_type[inst.int()].unwrap();
    }

    fn cell(w: *Walker, c: Cell) Allocator.Error!u32 {
        const key: [4]u32 = .{ @backingInt(c.kind), c.a, c.b, c.path };
        const gop = try w.cell_map.getOrPut(w.a, key);
        if (gop.found_existing) return gop.value_ptr.*;
        const id: u32 = @intCast(w.cells.items.len);
        gop.value_ptr.* = id;
        try w.cells.append(w.a, c);
        return id;
    }

    fn token(w: *const Walker, inst: Inst.Index) u32 {
        return w.bir.insts.items(.main_token)[inst.int()];
    }

    // ---- abstract values ---------------------------------------------------

    fn norm(w: *Walker, items: []Entry) Allocator.Error!AV {
        std.mem.sort(Entry, items, {}, struct {
            fn less(_: void, x: Entry, y: Entry) bool {
                if (x.path != y.path) return x.path < y.path;
                if (x.cell != y.cell) return x.cell < y.cell;
                return x.approx < y.approx;
            }
        }.less);
        var out: std.ArrayList(Entry) = .empty;
        for (items) |e| {
            if (out.items.len > 0) {
                const last = out.items[out.items.len - 1];
                if (last.path == e.path and last.cell == e.cell) continue;
            }
            try out.append(w.a, e);
        }
        return out.toOwnedSlice(w.a);
    }

    fn unionOf(w: *Walker, parts: []const AV) Allocator.Error!AV {
        var all: std.ArrayList(Entry) = .empty;
        for (parts) |p| try all.appendSlice(w.a, p);
        return w.norm(all.items);
    }

    fn shift(w: *Walker, av: AV, s: Step) Allocator.Error!AV {
        const out = try w.a.alloc(Entry, av.len);
        for (av, out) |e, *x| x.* = .{ .path = try w.o.prepend(s, e.path), .cell = e.cell, .approx = e.approx };
        return w.norm(out);
    }

    /// A symbolic cell one step further down (§4.3).
    fn projCell(w: *Walker, c: u32, s: Step, ty: ?Var) Allocator.Error!?u32 {
        const x = w.cells.items[c];
        switch (x.kind) {
            .site, .closure => return null,
            .top => return c,
            .param, .result, .env, .shared => {
                var y = x;
                y.path = try w.o.child(x.path, s.kind, s.arg);
                y.ty = if (ty) |v| v.toOptional() else .none;
                return try w.cell(y);
            },
        }
    }

    fn proj(w: *Walker, av: AV, s: Step, ty: ?Var) Allocator.Error!AV {
        if (ty) |v| if (!try w.o.tracked(w.store, v, 0)) return &.{};
        var out: std.ArrayList(Entry) = .empty;
        for (av) |e| {
            if (e.path == eps) {
                if (try w.projCell(e.cell, s, ty)) |c| try out.append(w.a, .{ .path = eps, .cell = c, .approx = e.approx });
                continue;
            }
            const first = w.o.firstStep(e.path).?;
            if (first.kind == .any) {
                try out.append(w.a, e);
            } else if (first.kind == s.kind and first.arg == s.arg) {
                try out.append(w.a, .{ .path = try w.o.dropFirst(e.path), .cell = e.cell, .approx = e.approx });
            }
        }
        return w.norm(out.items);
    }

    /// Every entry of `av` with closures expanded into what they capture,
    /// under `◇` (§4.2).
    fn expand(w: *Walker, av: AV) Allocator.Error!AV {
        var out: std.ArrayList(Entry) = .empty;
        var seen: std.ArrayList(u32) = .empty;
        try w.expandInto(av, eps, 0, &out, &seen);
        return w.norm(out.items);
    }

    fn expandInto(w: *Walker, av: AV, prefix: u32, approx: u32, out: *std.ArrayList(Entry), seen: *std.ArrayList(u32)) Allocator.Error!void {
        for (av) |e| {
            const path = try w.o.concat(prefix, e.path);
            const ap = if (approx != 0) approx else e.approx;
            try out.append(w.a, .{ .path = path, .cell = e.cell, .approx = ap });
            const c = w.cells.items[e.cell];
            if (c.kind != .closure) continue;
            if (std.mem.indexOfScalar(u32, seen.items, c.a) != null) continue;
            try seen.append(w.a, c.a);
            const under = try w.o.child(path, .env, 0);
            for (w.closures.items[c.a].captures) |cap| {
                const held = w.local_av[cap.local] orelse continue;
                const at = try w.projPath(held, cap.path, null);
                try w.expandInto(at, under, ap, out, seen);
            }
        }
    }

    /// `av` projected along every step of `p`.
    fn projPath(w: *Walker, av: AV, p: u32, ty: ?Var) Allocator.Error!AV {
        var buf: [k_limit + 1]Step = undefined;
        var at = av;
        const s = w.o.steps(p, &buf);
        for (s, 0..) |st, i| at = try w.proj(at, st, if (i + 1 == s.len) ty else null);
        return at;
    }

    // ---- uses, pending, escape -------------------------------------------

    /// The local and path an expression names, when it is a variable or a
    /// field path of one (§7.1).
    fn refPath(w: *Walker, inst: Inst.Index) Allocator.Error!?Capture {
        const tag = w.bir.instTag(inst);
        const data = w.bir.instData(inst);
        switch (tag) {
            .local => return .{ .local = data.lhs, .path = eps },
            .field_access => {
                const base = (try w.refPath(@fromBackingInt(@intCast(data.lhs)))) orelse return null;
                const sym = w.bir.symbol(@fromBackingInt(@intCast(data.rhs)));
                return .{ .local = base.local, .path = try w.o.child(base.path, .field, @backingInt(sym)) };
            },
            .tuple_index => {
                const base = (try w.refPath(@fromBackingInt(@intCast(data.lhs)))) orelse return null;
                return .{ .local = base.local, .path = try w.o.child(base.path, .tuple, data.rhs) };
            },
            else => return null,
        }
    }

    /// Record the uses a consumer makes of its operands, at a new point.
    fn consume(w: *Walker, operands: []const Inst.Index, tok: u32) Allocator.Error!void {
        w.point += 1;
        for (operands) |op| try w.useOperand(op, tok, &.{});
    }

    fn useOperand(w: *Walker, op: Inst.Index, tok: u32, except: []const u32) Allocator.Error!void {
        if (try w.refPath(op)) |r| {
            if (w.local_frame[r.local] == w.frame) {
                try w.uses.append(w.a, .{ .local = r.local, .path = r.path, .except = except, .point = w.point, .frame = w.frame, .ctx = w.ctx, .token = tok });
            }
        }
    }

    /// Record, at the current point, a use of everything a closure value
    /// in `av` captured (§6.1 item 1): a temporary closure consumed by a call.
    fn useCaptures(w: *Walker, av: AV, tok: u32) Allocator.Error!void {
        for (av) |e| {
            const c = w.cells.items[e.cell];
            if (c.kind != .closure) continue;
            for (w.closures.items[c.a].captures) |cap| {
                if (w.local_frame[cap.local] != w.frame) continue;
                try w.uses.append(w.a, .{ .local = cap.local, .path = cap.path, .point = w.point, .frame = w.frame, .ctx = w.ctx, .token = tok });
            }
        }
    }

    /// `useCaptures` for each operand that is not a variable path: a
    /// variable holding a closure is a holder of its own, used at the call.
    fn useTemporaries(w: *Walker, insts: []const Inst.Index, avs: []const AV, tok: u32) Allocator.Error!void {
        for (insts, avs) |inst, av| {
            if ((try w.refPath(inst)) != null) continue;
            try w.useCaptures(av, tok);
        }
    }

    fn pushPending(w: *Walker, av: AV, inst: Inst.Index, by_call: bool) Allocator.Error!void {
        const is_ref = (try w.refPath(inst)) != null;
        try w.pending.append(w.a, .{ .av = av, .frame = w.frame, .token = w.token(inst), .is_ref = is_ref, .by_call = by_call });
    }

    fn popPending(w: *Walker, n: usize) void {
        w.pending.shrinkRetainingCapacity(w.pending.items.len - n);
    }

    /// Evaluate operands left to right; each is pending until the consumer
    /// runs (§7.4). The caller pops them.
    fn evalOperands(w: *Walker, insts: []const Inst.Index, by_call: bool) Allocator.Error![]AV {
        const out = try w.a.alloc(AV, insts.len);
        for (insts, out) |inst, *v| {
            v.* = try w.eval(inst);
            try w.pushPending(v.*, inst, by_call);
        }
        return out;
    }

    // ---- branch contexts ---------------------------------------------------

    fn compatible(w: *const Walker, x: u32, y: u32) bool {
        var a = x;
        var b = y;
        var prev_a: u32 = none;
        var prev_b: u32 = none;
        while (w.ctx_nodes.items[a].depth > w.ctx_nodes.items[b].depth) {
            prev_a = a;
            a = w.ctx_nodes.items[a].parent;
        }
        while (w.ctx_nodes.items[b].depth > w.ctx_nodes.items[a].depth) {
            prev_b = b;
            b = w.ctx_nodes.items[b].parent;
        }
        while (a != b) {
            prev_a = a;
            prev_b = b;
            a = w.ctx_nodes.items[a].parent;
            b = w.ctx_nodes.items[b].parent;
        }
        if (prev_a == none or prev_b == none) return true;
        const na = w.ctx_nodes.items[prev_a];
        const nb = w.ctx_nodes.items[prev_b];
        return !(na.case_id == nb.case_id and na.arm != nb.arm);
    }

    // ---- binding -------------------------------------------------------------

    fn bindLocal(w: *Walker, l: u32, av: AV) void {
        if (l >= w.local_av.len) return;
        w.local_av[l] = av;
        w.local_frame[l] = w.frame;
        w.local_ctx[l] = w.ctx;
    }

    fn bindPattern(w: *Walker, pat: Inst.Index, av: AV) Allocator.Error!void {
        const b = w.bir;
        const data = b.instData(pat);
        switch (b.instTag(pat)) {
            .pat_var => w.bindLocal(data.lhs, av),
            .pat_as => {
                w.bindLocal(data.rhs, av);
                try w.bindPattern(@fromBackingInt(@intCast(data.lhs)), av);
            },
            .pat_tuple => for (b.extraSlice(Bir.inlineRange(data), Inst.Index), 0..) |el, i| {
                try w.bindPattern(el, try w.proj(av, .{ .kind = .tuple, .arg = @intCast(i) }, w.patternType(el)));
            },
            .pat_record => for (b.extraSlice(Bir.inlineRange(data), u32)) |l| {
                const name = b.locals[w.decl.locals_start + l].name;
                const sym = if (name.unwrap()) |s| @backingInt(b.symbols[s]) else 0;
                w.bindLocal(l, try w.proj(av, .{ .kind = .field, .arg = sym }, w.localType(l)));
            },
            .pat_ctor => {
                const c = try w.ctorOf(@fromBackingInt(@intCast(data.lhs)));
                for (b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.rhs))), Inst.Index), 0..) |arg, i| {
                    try w.bindPattern(arg, try w.proj(av, .{ .kind = .ctor, .arg = c *% 64 +% @as(u32, @intCast(i)) }, w.patternType(arg)));
                }
            },
            .pat_list => {
                const items = b.extraSlice(Bir.inlineRange(data), Inst.Index);
                for (items, 0..) |item, i| {
                    if (b.instTag(item) == .pat_spread) {
                        // A spread binds a view of the scrutinee: the same cells.
                        const inner: Inst.Index = @fromBackingInt(@intCast(b.instData(item).lhs));
                        try w.bindPattern(inner, av);
                        if (b.instTag(inner) == .pat_var) w.notePat(b.instData(inner).lhs, pat, i, true);
                    } else {
                        try w.bindPattern(item, try w.proj(av, .{ .kind = .elem, .arg = 0 }, w.patternType(item)));
                        if (b.instTag(item) == .pat_var) w.notePat(b.instData(item).lhs, pat, i, false);
                    }
                }
            },
            .pat_spread => try w.bindPattern(@fromBackingInt(@intCast(data.lhs)), av),
            else => {},
        }
    }

    fn notePat(w: *Walker, l: u32, list: Inst.Index, index: usize, spread: bool) void {
        if (l < w.pat_site.len) w.pat_site[l] = .{ .list = list, .index = @intCast(index), .spread = spread };
    }

    /// A small id for a constructor reference, for its path step.
    fn ctorOf(w: *Walker, ref: Inst.Index) Allocator.Error!u32 {
        const data = w.bir.instData(ref);
        switch (w.bir.instTag(ref)) {
            .ctor => return w.o.ctorId(w.m, data.lhs),
            .ext_ctor => {
                if (data.lhs >= w.o.in.provenance.len) return w.o.ctorId(data.lhs, none);
                const i = w.o.in.provenance[data.lhs].ctorIndex(data.rhs) orelse none;
                return w.o.ctorId(data.lhs, i);
            },
            else => return w.o.ctorId(none, ref.int()),
        }
    }

    // ---- callees ---------------------------------------------------------

    const Target = struct { m: u32, d: u32 };

    fn valueTarget(w: *const Walker, inst: Inst.Index) ?Target {
        const data = w.bir.instData(inst);
        switch (w.bir.instTag(inst)) {
            .top => return .{ .m = w.m, .d = data.lhs },
            .ext_value => {
                if (data.lhs >= w.o.in.provenance.len) return null;
                const d = w.o.in.provenance[data.lhs].valueDecl(data.rhs) orelse return null;
                return .{ .m = data.lhs, .d = d.int() };
            },
            else => return null,
        }
    }

    fn methodTarget(w: *const Walker, inst: Inst.Index) ?Target {
        if (w.m >= w.o.in.dispatch.len) return null;
        const dt = &w.o.in.dispatch[w.m];
        const site = dt.siteOf(inst) orelse return null;
        const ci = site.callee.unwrap() orelse return null;
        switch (dt.term(ci)) {
            .top => |t| return .{ .m = w.m, .d = t.decl.int() },
            .ext => |t| {
                const m2 = t.module.int();
                if (m2 >= w.o.in.provenance.len) return null;
                const d = w.o.in.provenance[m2].valueDecl(@backingInt(t.value)) orelse return null;
                return .{ .m = m2, .d = d.int() };
            },
            else => return null,
        }
    }

    fn targetName(w: *const Walker, t: Target) []const u8 {
        const b = w.o.in.birs[t.m];
        return w.o.in.interner.slice(b.symbol(b.decls[t.d].name));
    }

    fn isCore(w: *const Walker, t: Target, module: []const u8) bool {
        return w.o.in.packages[t.m] == .core and std.mem.eql(u8, w.o.in.module_names[t.m], module);
    }

    const Row = enum { set, update, push, pop, swap, insert_at, remove_at, cons, append, copy };

    fn listRow(w: *const Walker, t: Target) ?Row {
        if (!w.isCore(t, "List")) return null;
        const name = w.targetName(t);
        const table = [_]struct { []const u8, Row }{
            .{ "set", .set },            .{ "update", .update }, .{ "push", .push },
            .{ "pop", .pop },            .{ "swap", .swap },     .{ "insertAt", .insert_at },
            .{ "removeAt", .remove_at }, .{ "cons", .cons },     .{ "append", .append },
            .{ "copy", .copy },
        };
        for (table) |e| if (std.mem.eql(u8, e[0], name)) return e[1];
        return null;
    }

    /// A `foreign` whose rung is `impure` or `suspends` (§6.1 item 2). A
    /// `foreign pure` promises it changes and keeps nothing, so it is a
    /// conservative call: it can only return what it was given.
    fn escapes(w: *const Walker, t: Target) bool {
        const d = w.o.in.birs[t.m].decls[t.d];
        return d.kind == .foreign_value and d.rung != .pure;
    }

    fn isSpreadCall(w: *const Walker, inst: Inst.Index) ?Row {
        if (w.bir.instTag(inst) != .call) return null;
        const tags = w.o.in.spans[w.m].tags;
        const tok = w.token(inst);
        if (tok >= tags.len or tags[tok] != .ellipsis) return null;
        const t = w.valueTarget(@fromBackingInt(@intCast(w.bir.instData(inst).lhs))) orelse return null;
        const row = w.listRow(t) orelse return null;
        return if (row == .cons or row == .append) row else null;
    }

    fn isListAppend(w: *const Walker, inst: Inst.Index) bool {
        if (w.bir.instTag(inst) != .call) return false;
        if (w.m >= w.o.in.dispatch.len) return false;
        const dt = &w.o.in.dispatch[w.m];
        if (dt.isListAppend(inst) or dt.isListAppend(@fromBackingInt(@intCast(w.bir.instData(inst).lhs)))) {
            return w.callArgs(inst).len == 2;
        }
        return false;
    }

    fn callArgs(w: *const Walker, inst: Inst.Index) []const Inst.Index {
        return w.bir.extraSlice(w.bir.subRange(@fromBackingInt(@intCast(w.bir.instData(inst).rhs))), Inst.Index);
    }

    /// Whether the tokens strictly between `a` and `b` are balanced brackets.
    fn balanced(w: *const Walker, a: u32, b: u32) bool {
        const tags = w.o.in.spans[w.m].tags;
        var depth: i32 = 0;
        var i = a + 1;
        while (i < b and i < tags.len) : (i += 1) {
            switch (tags[i]) {
                .l_bracket, .l_paren, .l_brace => depth += 1,
                .r_bracket, .r_paren, .r_brace => {
                    depth -= 1;
                    if (depth < 0) return false;
                },
                else => {},
            }
        }
        return depth == 0;
    }

    // ---- evaluation (§5) -------------------------------------------------

    fn eval(w: *Walker, inst: Inst.Index) Allocator.Error!AV {
        const b = w.bir;
        const data = b.instData(inst);
        switch (b.instTag(inst)) {
            .local => return w.evalLocal(data.lhs, eps, inst),
            .field_access, .tuple_index => {
                if (try w.refPath(inst)) |r| return w.evalLocal(r.local, r.path, inst);
                const target = try w.eval(@fromBackingInt(@intCast(data.lhs)));
                const s: Step = if (b.instTag(inst) == .field_access)
                    .{ .kind = .field, .arg = @backingInt(b.symbol(@fromBackingInt(@intCast(data.rhs)))) }
                else
                    .{ .kind = .tuple, .arg = data.rhs };
                return w.proj(target, s, w.instType(inst));
            },
            .top, .ext_value => {
                const t = w.valueTarget(inst) orelse return &.{};
                const decl = w.o.in.birs[t.m].decls[t.d];
                if (decl.params > 0) return &.{};
                if (!try w.isTracked(inst)) return &.{};
                if (decl.kind == .foreign_value) return w.single(.{ .kind = .top, .a = 0 });
                return w.single(.{ .kind = .shared, .a = t.m, .b = t.d, .ty = w.instTypeOpt(inst) });
            },
            .int, .float, .char, .string, .chunk, .unit, .ctor, .ext_ctor, .@"error" => return &.{},
            .interp => {
                const parts = b.extraSlice(Bir.inlineRange(data), Inst.Index);
                const avs = try w.evalOperands(parts, false);
                w.popPending(avs.len);
                try w.consume(parts, w.token(inst));
                return &.{};
            },
            .tuple => {
                const items = b.extraSlice(Bir.inlineRange(data), Inst.Index);
                const avs = try w.evalOperands(items, false);
                w.popPending(avs.len);
                try w.consume(items, w.token(inst));
                var parts = try w.a.alloc(AV, avs.len);
                for (avs, 0..) |av, i| parts[i] = try w.shift(av, .{ .kind = .tuple, .arg = @intCast(i) });
                return w.unionOf(parts);
            },
            .list => {
                const items = b.extraSlice(Bir.inlineRange(data), Inst.Index);
                const avs = try w.evalOperands(items, false);
                w.popPending(avs.len);
                try w.consume(items, w.token(inst));
                var parts = try w.a.alloc(AV, avs.len + 1);
                parts[0] = try w.single(.{ .kind = .site, .a = inst.int(), .ty = w.instTypeOpt(inst) });
                for (avs, 0..) |av, i| parts[i + 1] = try w.shift(av, .{ .kind = .elem, .arg = 0 });
                return w.unionOf(parts);
            },
            .record => {
                const fields = b.extraSlice(Bir.inlineRange(data), Bir.Field);
                const insts = try w.a.alloc(Inst.Index, fields.len);
                for (fields, insts) |f, *x| x.* = f.value;
                const avs = try w.evalOperands(insts, false);
                w.popPending(avs.len);
                try w.consume(insts, w.token(inst));
                var parts = try w.a.alloc(AV, avs.len);
                for (fields, avs, 0..) |f, av, i| parts[i] = try w.shift(av, .{ .kind = .field, .arg = @backingInt(b.symbol(f.name)) });
                return w.unionOf(parts);
            },
            .record_update => return w.evalRecordUpdate(inst),
            .call => return w.evalCall(inst),
            .method_call => return w.evalMethod(inst),
            .type_dispatch => {
                const md = b.extraData(@fromBackingInt(@intCast(data.rhs)), Bir.TypeDispatch);
                const args = b.extraSlice(.{ .start = md.args_start, .end = md.args_end }, Inst.Index);
                return w.conservative(inst, args, &.{}, null);
            },
            .lambda => {
                const params = b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.lhs))), Inst.Index);
                return w.closure(params, @fromBackingInt(@intCast(data.rhs)));
            },
            .let => return w.evalLet(inst),
            .case => return w.evalCase(inst),
            .@"try" => {
                const s = try w.eval(@fromBackingInt(@intCast(data.lhs)));
                try w.consume(&.{@fromBackingInt(@intCast(data.lhs))}, w.token(inst));
                if (!try w.isTracked(inst)) return &.{};
                const any = try w.o.child(eps, .any, 0);
                const out = try w.a.alloc(Entry, s.len);
                for (s, out) |e, *x| x.* = .{ .path = any, .cell = e.cell, .approx = e.approx };
                return w.norm(out);
            },
            .markup => {
                var values: std.ArrayList(Inst.Index) = .empty;
                try b.markupValues(w.a, @fromBackingInt(@intCast(data.lhs)), &values);
                return w.conservative(inst, values.items, &.{}, null);
            },
            else => return &.{},
        }
    }

    fn instTypeOpt(w: *const Walker, inst: Inst.Index) Var.Optional {
        return if (w.instType(inst)) |v| v.toOptional() else .none;
    }

    fn isTracked(w: *Walker, inst: Inst.Index) Allocator.Error!bool {
        const v = w.instType(inst) orelse return true;
        return w.o.tracked(w.store, v, 0);
    }

    fn single(w: *Walker, c: Cell) Allocator.Error!AV {
        const id = try w.cell(c);
        return w.a.dupe(Entry, &.{.{ .path = eps, .cell = id }});
    }

    /// A local, or a field path of one; inside a lambda, a local of an
    /// enclosing frame is a capture (§5, §7.3).
    fn evalLocal(w: *Walker, l: u32, path: u32, inst: Inst.Index) Allocator.Error!AV {
        if (l >= w.local_av.len) return &.{};
        const ty = w.instType(inst);
        if (ty) |v| if (!try w.o.tracked(w.store, v, 0)) return &.{};
        const bound = w.local_av[l] != null;
        if (bound and w.local_frame[l] == w.frame) return w.projPath(w.local_av[l].?, path, ty);
        // Not bound yet in the declaration's own frame: nothing is known.
        if (w.frame == 0) return &.{};
        // A capture, recorded in every frame between the local's and this
        // one, so an enclosing lambda holds what its inner lambda reads. A
        // local not bound yet (one a local function names above its line)
        // is this frame's capture, looked up when needed.
        var f = w.frame;
        while (f != none) : (f = w.frames.items[f].parent) {
            if (bound and f == w.local_frame[l]) break;
            try w.frames.items[f].captures.append(w.a, .{ .local = l, .path = path });
            if (!bound) break;
        }
        return w.single(.{ .kind = .env, .a = l, .path = path, .ty = if (ty) |v| v.toOptional() else .none });
    }

    fn evalRecordUpdate(w: *Walker, inst: Inst.Index) Allocator.Error!AV {
        const b = w.bir;
        const data = b.instData(inst);
        const base_inst: Inst.Index = @fromBackingInt(@intCast(data.lhs));
        const fields = b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.rhs))), Bir.Field);
        const base = try w.eval(base_inst);
        try w.pushPending(base, base_inst, false);
        const insts = try w.a.alloc(Inst.Index, fields.len);
        for (fields, insts) |f, *x| x.* = f.value;
        const avs = try w.evalOperands(insts, false);
        w.popPending(avs.len + 1);
        const names = try w.a.alloc(u32, fields.len);
        for (fields, names) |f, *n| n.* = @backingInt(b.symbol(f.name));
        w.point += 1;
        try w.useOperand(base_inst, w.token(inst), names);
        for (insts) |x| try w.useOperand(x, w.token(inst), &.{});
        // The base without the updated fields; a symbolic entry is split
        // into its record type's other fields when the type is closed.
        var out: std.ArrayList(Entry) = .empty;
        const all_fields = w.recordFields(w.instType(base_inst));
        for (base) |e| {
            if (e.path == eps and w.cells.items[e.cell].kind != .top and w.cells.items[e.cell].kind != .site) {
                if (all_fields) |fs| {
                    for (fs) |fl| {
                        if (std.mem.indexOfScalar(u32, names, @backingInt(fl.name)) != null) continue;
                        if (!try w.o.tracked(w.store, fl.value, 0)) continue;
                        const s: Step = .{ .kind = .field, .arg = @backingInt(fl.name) };
                        if (try w.projCell(e.cell, s, fl.value)) |c| {
                            try out.append(w.a, .{ .path = try w.o.child(eps, .field, s.arg), .cell = c, .approx = e.approx });
                        }
                    }
                    continue;
                }
                try out.append(w.a, e);
                continue;
            }
            if (w.o.firstStep(e.path)) |first| {
                if (first.kind == .field and std.mem.indexOfScalar(u32, names, first.arg) != null) continue;
            }
            try out.append(w.a, e);
        }
        for (fields, avs) |f, av| {
            const shifted = try w.shift(av, .{ .kind = .field, .arg = @backingInt(b.symbol(f.name)) });
            try out.appendSlice(w.a, shifted);
        }
        return w.norm(out.items);
    }

    /// The fields of a closed record type, or null.
    fn recordFields(w: *Walker, ty: ?Var) ?[]const TypeStore.Field {
        const v = ty orelse return null;
        switch (w.store.resolvedContent(v)) {
            .structure => |s| switch (s) {
                .record => |r| {
                    switch (w.store.resolvedContent(r.ext)) {
                        .structure => |e| if (e == .empty_record) return w.store.fields(r.fields),
                        else => {},
                    }
                    return null;
                },
                else => return null,
            },
            else => return null,
        }
    }

    fn closure(w: *Walker, params: []const Inst.Index, body: Inst.Index) Allocator.Error!AV {
        const saved_frame = w.frame;
        const saved_ctx = w.ctx;
        const id: u32 = @intCast(w.frames.items.len);
        try w.frames.append(w.a, .{ .parent = saved_frame, .pending_base = w.pending.items.len });
        w.frame = id;
        for (params) |p| try w.bindParam(p, 1);
        _ = try w.eval(body);
        try w.consume(&.{body}, w.token(body));
        w.frame = saved_frame;
        w.ctx = saved_ctx;
        const ci: u32 = @intCast(w.closures.items.len);
        // Captures of locals of this frame only: an inner capture of an
        // outer-outer local was recorded in the frames between.
        var caps: std.ArrayList(Capture) = .empty;
        for (w.frames.items[id].captures.items) |cap| {
            if (cap.local < w.local_frame.len and w.local_frame[cap.local] == id and w.local_av[cap.local] != null) continue;
            try caps.append(w.a, cap);
        }
        try w.closures.append(w.a, .{ .captures = try caps.toOwnedSlice(w.a) });
        return w.single(.{ .kind = .closure, .a = ci });
    }

    fn evalLet(w: *Walker, inst: Inst.Index) Allocator.Error!AV {
        const b = w.bir;
        const data = b.instData(inst);
        const items = b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.lhs))), Inst.Index);
        // Local functions first: their closures exist from the block's
        // entry (thesis §3.6, *Local functions*), and their captures are
        // looked up when needed, so a later local is found.
        for (items) |item| {
            if (b.instTag(item) != .let_def) continue;
            const ld = b.extraData(@fromBackingInt(@intCast(b.instData(item).lhs)), Bir.LetDef);
            if (ld.params_start == ld.params_end) continue;
            const params = b.extraSlice(.{ .start = ld.params_start, .end = ld.params_end }, Inst.Index);
            const av = try w.closure(params, @fromBackingInt(@intCast(b.instData(item).rhs)));
            w.bindLocal(ld.local, av);
        }
        for (items) |item| {
            const idata = b.instData(item);
            switch (b.instTag(item)) {
                .let_def => {
                    const ld = b.extraData(@fromBackingInt(@intCast(idata.lhs)), Bir.LetDef);
                    if (ld.params_start != ld.params_end) continue;
                    const value: Inst.Index = @fromBackingInt(@intCast(idata.rhs));
                    const av = try w.eval(value);
                    try w.consume(&.{value}, w.token(item));
                    w.bindLocal(ld.local, av);
                },
                .let_pattern => {
                    const value: Inst.Index = @fromBackingInt(@intCast(idata.rhs));
                    const av = try w.eval(value);
                    try w.consume(&.{value}, w.token(item));
                    try w.bindPattern(@fromBackingInt(@intCast(idata.lhs)), av);
                },
                .let_stmt => {
                    const value: Inst.Index = @fromBackingInt(@intCast(idata.rhs));
                    _ = try w.eval(value);
                    try w.consume(&.{value}, w.token(item));
                },
                else => {},
            }
        }
        return w.eval(@fromBackingInt(@intCast(data.rhs)));
    }

    fn evalCase(w: *Walker, inst: Inst.Index) Allocator.Error!AV {
        const b = w.bir;
        const data = b.instData(inst);
        const scrutinee: Inst.Index = @fromBackingInt(@intCast(data.lhs));
        const s = try w.eval(scrutinee);
        try w.consume(&.{scrutinee}, w.token(inst));
        const branches = b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.rhs))), Inst.Index);
        const case_id = w.cases;
        w.cases += 1;
        const saved = w.ctx;
        var results: std.ArrayList(AV) = .empty;
        for (branches, 0..) |br, arm| {
            const node: u32 = @intCast(w.ctx_nodes.items.len);
            try w.ctx_nodes.append(w.a, .{ .parent = saved, .case_id = case_id, .arm = @intCast(arm), .depth = w.ctx_nodes.items[saved].depth + 1 });
            w.ctx = node;
            try w.bindPattern(@fromBackingInt(@intCast(b.instData(br).lhs)), s);
            try results.append(w.a, try w.eval(@fromBackingInt(@intCast(b.instData(br).rhs))));
        }
        w.ctx = saved;
        return w.unionOf(results.items);
    }

    // ---- calls (§6) ------------------------------------------------------

    fn evalCall(w: *Walker, inst: Inst.Index) Allocator.Error!AV {
        const b = w.bir;
        const data = b.instData(inst);
        const callee: Inst.Index = @fromBackingInt(@intCast(data.lhs));
        const args = w.callArgs(inst);
        if (w.isSpreadCall(inst) != null) return w.construction(inst);
        if (w.isListAppend(inst)) return w.appendChain(inst);
        switch (b.instTag(callee)) {
            .ctor, .ext_ctor => {
                const c = try w.ctorOf(callee);
                const avs = try w.evalOperands(args, false);
                w.popPending(avs.len);
                try w.consume(args, w.token(inst));
                var parts = try w.a.alloc(AV, avs.len);
                for (avs, 0..) |av, i| parts[i] = try w.shift(av, .{ .kind = .ctor, .arg = c *% 64 +% @as(u32, @intCast(i)) });
                return w.unionOf(parts);
            },
            else => {},
        }
        if (w.valueTarget(callee)) |t| {
            if (w.listRow(t)) |row| return w.writer(inst, row, args);
            if (w.escapes(t)) return w.escapeCall(inst, args);
            return w.conservative(inst, args, &.{}, null);
        }
        // A function value: read its captures, as an argument (§6.1).
        const f = try w.eval(callee);
        try w.pushPending(f, callee, true);
        defer w.popPending(1);
        return w.conservative(inst, args, f, callee);
    }

    fn evalMethod(w: *Walker, inst: Inst.Index) Allocator.Error!AV {
        const b = w.bir;
        const data = b.instData(inst);
        const mc = b.extraData(@fromBackingInt(@intCast(data.rhs)), Bir.MethodCall);
        const rest = b.extraSlice(.{ .start = mc.args_start, .end = mc.args_end }, Inst.Index);
        const all = try w.a.alloc(Inst.Index, rest.len + 1);
        all[0] = @fromBackingInt(@intCast(data.lhs));
        @memcpy(all[1..], rest);
        if (w.methodTarget(inst)) |t| {
            if (w.listRow(t)) |row| return w.writer(inst, row, all);
        }
        return w.conservative(inst, all, &.{}, null);
    }

    /// §6.1.
    fn conservative(w: *Walker, inst: Inst.Index, args: []const Inst.Index, callee_av: AV, callee: ?Inst.Index) Allocator.Error!AV {
        const avs = try w.evalOperands(args, true);
        w.popPending(avs.len);
        w.point += 1;
        const tok = w.token(inst);
        for (args) |x| try w.useOperand(x, tok, &.{});
        if (callee) |c| try w.useOperand(c, tok, &.{});
        try w.useTemporaries(args, avs, tok);
        if (callee) |c| try w.useTemporaries(&.{c}, &.{callee_av}, tok);
        const ty = w.instType(inst);
        if (ty) |v| if (!try w.o.tracked(w.store, v, 0)) return &.{};
        var out: std.ArrayList(Entry) = .empty;
        const fresh = try w.cell(.{ .kind = .result, .a = inst.int(), .ty = w.instTypeOpt(inst) });
        try out.append(w.a, .{ .path = eps, .cell = fresh });
        const any = try w.o.child(eps, .any, 0);
        var from: std.ArrayList(AV) = .empty;
        try from.appendSlice(w.a, avs);
        try from.append(w.a, callee_av);
        for (from.items) |av| {
            for (try w.expand(av)) |e| {
                const c = w.cells.items[e.cell];
                if (c.kind == .closure) continue;
                if (ty) |r| if (c.ty.unwrap()) |ct| if (!try w.o.mayHold(w.store, r, ct, 0)) continue;
                try out.append(w.a, .{ .path = any, .cell = e.cell, .approx = inst.int() + 1 });
            }
        }
        return w.norm(out.items);
    }

    /// A `foreign` or `Js` call: its arguments escape, its result is ⊤
    /// (§6.1 item 2).
    fn escapeCall(w: *Walker, inst: Inst.Index, args: []const Inst.Index) Allocator.Error!AV {
        const avs = try w.evalOperands(args, false);
        w.popPending(avs.len);
        try w.consume(args, w.token(inst));
        try w.useTemporaries(args, avs, w.token(inst));
        for (avs) |av| for (try w.expand(av)) |e| {
            if (w.cells.items[e.cell].kind == .closure) continue;
            try w.escaped.append(w.a, .{ e.cell, w.point });
        };
        if (!try w.isTracked(inst)) return &.{};
        return w.single(.{ .kind = .top, .a = 0 });
    }

    /// A named writer or `List.copy` (§6.2).
    fn writer(w: *Walker, inst: Inst.Index, row: Row, args: []const Inst.Index) Allocator.Error!AV {
        const avs = try w.evalOperands(args, false);
        w.popPending(avs.len);
        try w.consume(args, w.token(inst));
        try w.useTemporaries(args, avs, w.token(inst));
        if (row == .copy) {
            if (avs.len < 1) return &.{};
            const fresh = try w.single(.{ .kind = .site, .a = inst.int(), .ty = w.instTypeOpt(inst) });
            const elems = try w.shift(try w.elementsOf(avs[0]), .{ .kind = .elem, .arg = 0 });
            return w.unionOf(&.{ fresh, elems });
        }
        const base_at: usize = if (row == .cons) 1 else 0;
        if (avs.len <= base_at) return &.{};
        const name = try std.fmt.allocPrint(w.o.out.allocator(), "List.{s}", .{switch (row) {
            .set => "set",
            .update => "update",
            .push => "push",
            .pop => "pop",
            .swap => "swap",
            .insert_at => "insertAt",
            .remove_at => "removeAt",
            .cons => "cons",
            .append => "append",
            .copy => unreachable,
        }});
        const others = try w.a.alloc(AV, avs.len - 1);
        var k: usize = 0;
        for (avs, 0..) |av, i| if (i != base_at) {
            others[k] = av;
            k += 1;
        };
        try w.demand(inst, name, args[base_at], avs[base_at], others);
        // The result is the base's cell, with what the row stores (§6.2).
        var parts: std.ArrayList(AV) = .empty;
        try parts.append(w.a, avs[base_at]);
        for (avs, 0..) |av, i| {
            if (i == base_at) continue;
            const ty = w.instType(args[i]);
            const is_list = if (ty) |v| w.isListType(v) else false;
            if (row == .append and is_list) {
                try parts.append(w.a, try w.shift(try w.elementsOf(av), .{ .kind = .elem, .arg = 0 }));
            } else if (row == .update) {
                // The callback's result: what it may return, conservatively.
                try parts.append(w.a, try w.anyOf(av, inst));
            } else {
                try parts.append(w.a, try w.shift(av, .{ .kind = .elem, .arg = 0 }));
            }
        }
        return w.unionOf(parts.items);
    }

    fn isListType(w: *Walker, v: Var) bool {
        return switch (w.store.resolvedContent(v)) {
            .structure => |s| s == .app and s.app.type == w.o.in.types.well_known.list,
            else => false,
        };
    }

    /// The entries of a list value at its elements, re-rooted.
    fn elementsOf(w: *Walker, av: AV) Allocator.Error!AV {
        return w.proj(av, .{ .kind = .elem, .arg = 0 }, null);
    }

    /// Every cell of `av`, closures expanded, at `⋆`, tagged with `inst`.
    fn anyOf(w: *Walker, av: AV, inst: Inst.Index) Allocator.Error!AV {
        const any = try w.o.child(eps, .any, 0);
        var out: std.ArrayList(Entry) = .empty;
        for (try w.expand(av)) |e| {
            if (w.cells.items[e.cell].kind == .closure) continue;
            try out.append(w.a, .{ .path = any, .cell = e.cell, .approx = inst.int() + 1 });
        }
        return w.norm(out.items);
    }

    const Item = struct { inst: Inst.Index, spread: bool };

    /// A list literal with a spread, read back as one construction (§3.2).
    fn construction(w: *Walker, top: Inst.Index) Allocator.Error!AV {
        var items: std.ArrayList(Item) = .empty;
        var cur = top;
        while (true) {
            const row = w.isSpreadCall(cur).?;
            const args = w.callArgs(cur);
            try items.append(w.a, .{ .inst = args[0], .spread = row == .append });
            const next = args[1];
            if (w.isSpreadCall(next) != null and w.balanced(w.token(cur), w.token(next))) {
                cur = next;
                continue;
            }
            if (w.bir.instTag(next) == .list and w.token(next) < w.token(cur)) {
                for (w.bir.extraSlice(Bir.inlineRange(w.bir.instData(next)), Inst.Index)) |el| {
                    try items.append(w.a, .{ .inst = el, .spread = false });
                }
            } else {
                try items.append(w.a, .{ .inst = next, .spread = true });
            }
            break;
        }
        return w.build(top, "construction", items.items);
    }

    /// A `++` chain on lists: one construction whose base is its leftmost
    /// operand (§3.2).
    fn appendChain(w: *Walker, top: Inst.Index) Allocator.Error!AV {
        var items: std.ArrayList(Item) = .empty;
        var cur = top;
        while (true) {
            const args = w.callArgs(cur);
            try items.append(w.a, .{ .inst = args[0], .spread = true });
            if (w.isListAppend(args[1])) {
                cur = args[1];
                continue;
            }
            try items.append(w.a, .{ .inst = args[1], .spread = true });
            break;
        }
        return w.build(top, "++", items.items);
    }

    fn build(w: *Walker, top: Inst.Index, op: []const u8, items: []const Item) Allocator.Error!AV {
        const insts = try w.a.alloc(Inst.Index, items.len);
        for (items, insts) |it, *x| x.* = it.inst;
        const avs = try w.evalOperands(insts, false);
        w.popPending(avs.len);
        try w.consume(insts, w.token(top));
        try w.useTemporaries(insts, avs, w.token(top));
        var base_at: ?usize = null;
        for (items, 0..) |it, i| if (it.spread) {
            base_at = i;
            break;
        };
        const bi = base_at orelse return w.single(.{ .kind = .site, .a = top.int(), .ty = w.instTypeOpt(top) });
        // A list re-built in the shape a pattern just matched is that list
        // (thesis §3.8): an alias, not a demand.
        if (w.reconsed(items)) return avs[bi];
        const others = try w.a.alloc(AV, avs.len - 1);
        var k: usize = 0;
        for (avs, 0..) |av, i| if (i != bi) {
            others[k] = av;
            k += 1;
        };
        try w.demand(top, op, items[bi].inst, avs[bi], others);
        var parts: std.ArrayList(AV) = .empty;
        try parts.append(w.a, avs[bi]);
        for (items, avs, 0..) |it, av, i| {
            if (i == bi) continue;
            if (it.spread) {
                try parts.append(w.a, try w.shift(try w.elementsOf(av), .{ .kind = .elem, .arg = 0 }));
            } else {
                try parts.append(w.a, try w.shift(av, .{ .kind = .elem, .arg = 0 }));
            }
        }
        return w.unionOf(parts.items);
    }

    fn reconsed(w: *Walker, items: []const Item) bool {
        var list: ?Inst.Index = null;
        for (items, 0..) |it, i| {
            if (w.bir.instTag(it.inst) != .local) return false;
            const l = w.bir.instData(it.inst).lhs;
            if (l >= w.pat_site.len) return false;
            const site = w.pat_site[l] orelse return false;
            if (site.index != i or site.spread != it.spread) return false;
            if (list) |x| {
                if (x != site.list) return false;
            } else list = site.list;
        }
        const pl = list orelse return false;
        return w.bir.extraSlice(Bir.inlineRange(w.bir.instData(pl)), Inst.Index).len == items.len;
    }

    // ---- the check (§8) --------------------------------------------------

    /// When a value holding `outer` also holds `inner`, the path from the
    /// one to the other: a symbolic cell stands for every cell under it
    /// (§4.3), so `param(x, ε)` holds `param(x, .items)` at `.items`.
    fn covers(w: *Walker, outer: u32, inner: u32) Allocator.Error!?u32 {
        if (outer == inner) return eps;
        const o = w.cells.items[outer];
        const i = w.cells.items[inner];
        switch (o.kind) {
            .param, .result, .env, .shared => {},
            else => return null,
        }
        if (o.kind != i.kind or o.a != i.a or o.b != i.b) return null;
        var bo: [k_limit + 1]Step = undefined;
        var bi: [k_limit + 1]Step = undefined;
        const so = w.o.steps(o.path, &bo);
        const si = w.o.steps(i.path, &bi);
        if (so.len >= si.len) return null;
        for (so, si[0..so.len]) |x, y| if (x.kind != y.kind or x.arg != y.arg) return null;
        var at: u32 = eps;
        for (si[so.len..]) |s| at = try w.o.child(at, s.kind, s.arg);
        return at;
    }

    /// Where `av`, closures expanded, holds one of `cells`: the first such
    /// entry, with its path extended to the cell, or null.
    fn reaches(w: *Walker, av: AV, cells: []const Entry) Allocator.Error!?Entry {
        // An exact entry first: an approximate one is reported only when no
        // exact one reaches the cell.
        var found: ?Entry = null;
        for (try w.expand(av)) |e| {
            for (cells) |c| {
                const rest = (try w.covers(e.cell, c.cell)) orelse continue;
                const hit: Entry = .{ .path = try w.o.concat(e.path, rest), .cell = c.cell, .approx = if (e.approx != 0) e.approx else c.approx };
                if (hit.approx == 0) return hit;
                if (found == null) found = hit;
            }
        }
        return found;
    }

    fn demand(w: *Walker, inst: Inst.Index, op: []const u8, base_inst: Inst.Index, base: AV, others: []const AV) Allocator.Error!void {
        const out = w.o.out.allocator();
        const base_ty = w.instType(base_inst);
        // The base's cells: at ε, and every `⋆` entry that may be the base.
        var cells: std.ArrayList(Entry) = .empty;
        const any = try w.o.child(eps, .any, 0);
        for (base) |e| {
            if (e.path == eps) {
                try cells.append(w.a, e);
                continue;
            }
            if (e.path != any) continue;
            const c = w.cells.items[e.cell];
            if (base_ty) |bt| if (c.ty.unwrap()) |ct| if (!try w.o.mayShare(w.store, bt, ct, 0)) continue;
            try cells.append(w.a, e);
        }
        const base_ref = try w.refPath(base_inst);
        var rec: DemandRec = .{
            .token = w.token(inst),
            .op = op,
            .base = try w.baseText(base_inst),
            .base_local = if (base_ref) |r| r.local else none,
            .base_path = if (base_ref) |r| r.path else eps,
            .point = w.point,
            .frame = w.frame,
            .ctx = w.ctx,
            .element = false,
            .accept = .fresh,
            .prelim = null,
            .holders = &.{},
        };
        // Known, Unescaped, Captured, in that order across the cells.
        var worst: ?Cause = null;
        var worst_detail: []const u8 = "";
        for (cells.items) |e| {
            const c = w.cells.items[e.cell];
            if (w.o.hasStep(c.path, .elem)) rec.element = true;
            const rank: Accept = switch (c.kind) {
                .param => if (c.b == 1) .callback_param else .param,
                .result => .call,
                else => .fresh,
            };
            if (@backingInt(rank) > @backingInt(rec.accept)) rec.accept = rank;
            var cause: ?Cause = null;
            var detail: []const u8 = "";
            switch (c.kind) {
                .top => {
                    cause = .unknown;
                    detail = "the list came from JavaScript";
                },
                .shared => {
                    cause = .top_level;
                    const b = w.o.in.birs[c.a];
                    detail = try std.fmt.allocPrint(out, "{s}.{s} is a top-level value", .{ w.o.in.module_names[c.a], w.o.in.interner.slice(b.symbol(b.decls[c.b].name)) });
                },
                .env => {
                    cause = .captured_edit;
                    detail = try std.fmt.allocPrint(out, "{s} is captured, and how often the closure runs is not known", .{w.localName(c.a)});
                },
                .param, .result, .site, .closure => {},
            }
            for (w.escaped.items) |x| {
                if (x[1] >= w.point) continue;
                if ((try w.covers(x[0], e.cell)) == null) continue;
                if (cause == null or @backingInt(Cause.escaped) < @backingInt(cause.?)) {
                    cause = .escaped;
                    detail = "it was given to JavaScript";
                }
            }
            if (cause) |cs| if (worst == null or @backingInt(cs) < @backingInt(worst.?)) {
                worst = cs;
                worst_detail = detail;
            };
        }
        if (worst) |cs| {
            rec.prelim = .{ .cause = cs, .detail = worst_detail };
            try w.demands.append(w.a, rec);
            return;
        }
        // Disjoint: another operand of the demand reaches the cell.
        var approx_hit: u32 = 0;
        for (others) |av| {
            const hit = (try w.reaches(av, cells.items)) orelse continue;
            if (hit.approx != 0) {
                if (approx_hit == 0) approx_hit = hit.approx;
                continue;
            }
            rec.prelim = .{ .cause = .disjoint, .detail = "another operand of the same operation reaches it" };
            try w.demands.append(w.a, rec);
            return;
        }
        if (approx_hit != 0) {
            const cp = w.o.in.positions.get(w.o.in.positions.ctx, w.m, w.token(@fromBackingInt(@intCast(approx_hit - 1))));
            rec.prelim = .{ .cause = .call, .detail = try std.fmt.allocPrint(out, "another operand may be it, through the call at {d}:{d}", .{ cp.line, cp.col }) };
            try w.demands.append(w.a, rec);
            return;
        }
        // A temporary already evaluated for an enclosing consumer holds it.
        const base_pending = w.frames.items[w.frame].pending_base;
        for (w.pending.items[base_pending..]) |p| {
            if (p.frame != w.frame or p.is_ref) continue;
            const phit = (try w.reaches(p.av, cells.items)) orelse continue;
            const pos = w.o.in.positions.get(w.o.in.positions.ctx, w.m, p.token);
            // Held for a call with no summary, the temporary is a holder only
            // because the call is assumed to read it (§6.1): a limit.
            rec.prelim = if (p.by_call or phit.approx != 0)
                .{ .cause = .call, .detail = try std.fmt.allocPrint(out, "the argument at {d}:{d}, evaluated before it, holds it, and the call it waits for may read it", .{ pos.line, pos.col }) }
            else
                .{ .cause = .held_operand, .detail = try std.fmt.allocPrint(out, "the value at {d}:{d}, evaluated before it, holds it until its consumer runs", .{ pos.line, pos.col }) };
            try w.demands.append(w.a, rec);
            return;
        }
        // The holders, resolved against later uses once the walk is done.
        var holders: std.ArrayList(Holder) = .empty;
        for (w.local_av, 0..) |maybe, l| {
            const av = maybe orelse continue;
            if (w.local_frame[l] != w.frame) continue;
            if (!w.compatible(w.local_ctx[l], w.ctx)) continue;
            for (try w.expand(av)) |e| {
                for (cells.items) |c| {
                    const rest = (try w.covers(e.cell, c.cell)) orelse continue;
                    try holders.append(w.a, .{
                        .local = @intCast(l),
                        .path = try w.o.concat(e.path, rest),
                        .approx = if (e.approx != 0) e.approx else c.approx,
                    });
                }
            }
        }
        rec.holders = try holders.toOwnedSlice(w.a);
        try w.demands.append(w.a, rec);
    }

    fn localName(w: *const Walker, l: u32) []const u8 {
        const at = w.decl.locals_start + l;
        if (at >= w.bir.locals.len) return "_";
        const name = w.bir.locals[at].name.unwrap() orelse return "_";
        return w.o.in.interner.slice(w.bir.symbols[name]);
    }

    fn baseText(w: *Walker, inst: Inst.Index) Allocator.Error![]const u8 {
        const out = w.o.out.allocator();
        var buf: std.Io.Writer.Allocating = .init(out);
        if (try w.writeExpr(&buf.writer, inst)) return buf.toOwnedSlice();
        buf.deinit();
        switch (w.bir.instTag(inst)) {
            .list => return "<literal>",
            .call => {
                const callee: Inst.Index = @fromBackingInt(@intCast(w.bir.instData(inst).lhs));
                if (w.valueTarget(callee)) |t| {
                    return std.fmt.allocPrint(out, "<call {s}.{s}>", .{ w.o.in.module_names[t.m], w.targetName(t) });
                }
                return "<call>";
            },
            .method_call => return "<call>",
            else => return "<expression>",
        }
    }

    /// A variable or top-level value with a field path, as written.
    fn writeExpr(w: *Walker, wr: *std.Io.Writer, inst: Inst.Index) Allocator.Error!bool {
        const data = w.bir.instData(inst);
        switch (w.bir.instTag(inst)) {
            .local => wr.writeAll(w.localName(data.lhs)) catch return error.OutOfMemory,
            .top, .ext_value => {
                const t = w.valueTarget(inst) orelse return false;
                wr.print("{s}.{s}", .{ w.o.in.module_names[t.m], w.targetName(t) }) catch return error.OutOfMemory;
            },
            .field_access => {
                if (!try w.writeExpr(wr, @fromBackingInt(@intCast(data.lhs)))) return false;
                wr.print(".{s}", .{w.o.in.interner.slice(w.bir.symbol(@fromBackingInt(@intCast(data.rhs))))}) catch return error.OutOfMemory;
            },
            .tuple_index => {
                if (!try w.writeExpr(wr, @fromBackingInt(@intCast(data.lhs)))) return false;
                wr.print(".{d}", .{data.rhs}) catch return error.OutOfMemory;
            },
            else => return false,
        }
        return true;
    }

    /// Liveness, once every use is known (§7, §8.3).
    fn resolve(w: *Walker, out_list: *std.ArrayList(Demand)) Allocator.Error!void {
        const out = w.o.out.allocator();
        for (w.demands.items) |rec| {
            const pos = w.o.in.positions.get(w.o.in.positions.ctx, w.m, rec.token);
            var d: Demand = .{ .position = pos, .op = rec.op, .base = rec.base, .verdict = .{ .accepted = rec.accept }, .detail = "" };
            if (rec.prelim) |p| {
                d.verdict = .{ .rejected = p.cause };
                d.detail = p.detail;
                try out_list.append(out, d);
                continue;
            }
            // Each holder's first later use in a compatible branch.
            var best: ?struct { cause: Cause, holder: Holder, use: Use } = null;
            for (rec.holders) |h| {
                var first: ?Use = null;
                for (w.uses.items) |u| {
                    if (u.local != h.local or u.frame != rec.frame or u.point <= rec.point) continue;
                    if (!w.compatible(u.ctx, rec.ctx)) continue;
                    if (!w.useOverlaps(u, h.path)) continue;
                    if (first == null or u.point < first.?.point) first = u;
                }
                const u = first orelse continue;
                const cause: Cause = if (h.approx != 0)
                    .call
                else if (rec.element and w.o.hasStep(h.path, .elem))
                    .element
                else if (w.o.hasStep(h.path, .env))
                    .captured
                else if (h.local == rec.base_local and w.o.overlap(h.path, rec.base_path))
                    .later_use
                else
                    .alias;
                if (best) |bst| {
                    const better_kind = cause.approximate() != bst.cause.approximate() and !cause.approximate();
                    const same_kind = cause.approximate() == bst.cause.approximate();
                    if (!(better_kind or (same_kind and u.point < bst.use.point))) continue;
                }
                best = .{ .cause = cause, .holder = h, .use = u };
            }
            if (best) |bst| {
                const up = w.o.in.positions.get(w.o.in.positions.ctx, w.m, bst.use.token);
                var buf: std.Io.Writer.Allocating = .init(out);
                const wr = &buf.writer;
                wr.writeAll(w.localName(bst.holder.local)) catch return error.OutOfMemory;
                if (bst.cause != .captured) w.o.writePath(wr, bst.holder.path) catch return error.OutOfMemory;
                switch (bst.cause) {
                    .later_use => wr.print(" is read again at {d}:{d}", .{ up.line, up.col }) catch return error.OutOfMemory,
                    .captured => wr.print(", a closure holding it, is used at {d}:{d}", .{ up.line, up.col }) catch return error.OutOfMemory,
                    .call => {
                        const call_inst: Inst.Index = @fromBackingInt(@intCast(bst.holder.approx - 1));
                        const cp = w.o.in.positions.get(w.o.in.positions.ctx, w.m, w.token(call_inst));
                        wr.print(" may hold it through the call at {d}:{d}, and is read at {d}:{d}", .{ cp.line, cp.col, up.line, up.col }) catch return error.OutOfMemory;
                    },
                    else => wr.print(" holds it and is read at {d}:{d}", .{ up.line, up.col }) catch return error.OutOfMemory,
                }
                d.verdict = .{ .rejected = bst.cause };
                d.detail = try buf.toOwnedSlice();
            }
            try out_list.append(out, d);
        }
    }

    fn useOverlaps(w: *const Walker, u: Use, path: u32) bool {
        if (u.except.len != 0 and u.path == eps) {
            const first = w.o.firstStep(path) orelse return true;
            if (first.kind == .field and std.mem.indexOfScalar(u32, u.except, first.arg) != null) return false;
            return true;
        }
        return w.o.overlap(u.path, path);
    }
};
