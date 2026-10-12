//! The ownership checker in report mode (`docs/design/ownership-checker.md`,
//! normative; the argument is the thesis `docs/thesis/ownership/`).
//!
//! For every *demand* — a `core/List` writer, a list construction with a
//! spread, a `++` chain on lists (§3), and from slice 2 a call whose callee's
//! summary writes a parameter (§16.4) — it decides whether the list the
//! demand would write in place is *unique at the site*: no holder of it is
//! read afterwards (thesis §3.3). It changes nothing a program does: it runs
//! only under `beni dump --stage=ownership`, after the checker, and prints
//! one line per demand (§9, §16.11).
//!
//! **The walk** (§2.1) is BIR's expression tree in evaluation order —
//! callee, arguments left to right, then the call — with a point per
//! consuming instruction. Abstract values map paths to abstract cells (§4);
//! a variable is used at the instruction that consumes it (§7.1); a `case`
//! arm is a branch context, and a lambda's body is a frame of its own (§7.2,
//! §7.3).
//!
//! **Summaries** (§16): every top-level value with parameters has one, read
//! off its body after the walk, and every lambda a *class* read off its
//! frame. A call through a summary uses only the paths the callee touches,
//! demands at the call what the callee writes, escapes what it keeps, checks
//! the callbacks it is handed against what it supplies them, and returns
//! its result instantiated. A recursive group is solved by an optimistic
//! fixpoint with a join, then validated (§16.6). Summaries are computed on
//! demand (§16.9). `core/List`'s primitives carry asserted rows (§16.8).
//! Calls with no summary are conservative, exactly as §6.1 says.
//!
//! **Determinism** (§10): modules in the order the caller gives (path
//! order), declarations in source order, every id assigned in the walk;
//! nothing printed is an id, and every fact is printed in text order.

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
const Scc = @import("../check/Scc.zig");
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
/// §16.7: the most entries a summary's component may hold.
pub const width_cap: usize = 64;
/// §16.6: the backstop on a recursive group's rounds.
pub const round_cap: u32 = 32;
/// §16.7: the most `returns owned` atoms a summary's `owned` bits use.
pub const atom_cap: u32 = 8;
/// How deep a callback's result is instantiated through another's.
const inst_depth: u32 = 4;

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

/// §8.3, in its order, then §16.11's.
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
    supply,
    need,
    limit,

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
            .supply => "supply",
            .need => "need",
            .limit => "limit",
        };
    }

    /// The default derivation of a cause (thesis §8.4); `supply` is
    /// decided per rejection (§16.11).
    pub fn approximate(c: Cause) bool {
        return switch (c) {
            .unknown, .escaped, .captured_edit, .element, .call, .limit => true,
            else => false,
        };
    }
};

pub const Verdict = union(enum) {
    accepted: Accept,
    /// An obligation slice 2 does not discharge (§16.5).
    pending,
    rejected: Cause,
};

/// One line of the report (§9.1, §16.11).
pub const Demand = struct {
    position: Position,
    /// `construction`, `++`, `List.<writer>`, `call M.f`, or `value`.
    op: []const u8,
    base: []const u8,
    verdict: Verdict,
    /// For a rejection or a pending line, the reason after the cause.
    detail: []const u8,
    /// The summary that decided it, printed in parentheses.
    note: []const u8 = "",
    /// An acceptance that rests on a callee with no summary (§15 decision 2).
    assumed: bool = false,
    /// A rejection's derivation.
    approx: bool = false,
};

/// One summary line (§16.11).
pub const SummaryLine = struct { text: []const u8 };

pub const ModuleReport = struct {
    module: u32,
    checked: bool,
    demands: []const Demand,
    summaries: []const SummaryLine = &.{},
};

// ---------------------------------------------------------------------------
// Summaries (§16.2)
// ---------------------------------------------------------------------------

pub const bit_r: u8 = 1;
pub const bit_a: u8 = 2;
pub const bit_e: u8 = 4;
pub const bit_w: u8 = 8;
/// With `bit_w`: some demand writes the path through exact steps only; a
/// W without it was derived through an approximate one (thesis §8.4).
pub const bit_x: u8 = 16;

pub const UseEntry = struct { param: u32, path: u32, bits: u8 };

pub const ProvKind = enum(u8) { param, fresh, esc, shared, top, cb, env };

/// A provenance (thesis §3.7's `Prov`). `param`: `a` the parameter's index
/// from 0, `path` its path. `fresh`/`esc`: `a` the number, from 1 (0 in a
/// supply, where it is not compared). `shared`: `a` the module, `b` the
/// declaration, `path` the path in it. `cb`: `a` the function parameter's
/// index. `env` (a lambda's class only): `a` the captured local, `path`.
pub const Prov = struct {
    kind: ProvKind,
    a: u32 = 0,
    b: u32 = 0,
    path: u32 = 0,

    fn eql(x: Prov, y: Prov) bool {
        return x.kind == y.kind and x.a == y.a and x.b == y.b and x.path == y.path;
    }

    fn less(x: Prov, y: Prov) bool {
        if (x.kind != y.kind) return @backingInt(x.kind) < @backingInt(y.kind);
        if (x.a != y.a) return x.a < y.a;
        if (x.b != y.b) return x.b < y.b;
        return x.path < y.path;
    }
};

pub const ResEntry = struct { path: u32, prov: Prov, approx: bool = false };

pub const SupplyEntry = struct { fun: u32, k: u32, path: u32, prov: Prov, owned: bool };

pub const Calls = enum(u8) { zero, once, many };

pub const FunFacts = struct {
    param: u32,
    calls: Calls = .zero,
    need: bool = false,
    seen: bool = true,
};

pub const Limit = enum(u8) { none, width, rounds };

pub const Summary = struct {
    params: u32,
    uses: []const UseEntry = &.{},
    res: []const ResEntry = &.{},
    supply: []const SupplyEntry = &.{},
    /// One per function-typed parameter, by parameter index.
    funs: []const FunFacts = &.{},
    limit: Limit = .none,
    asserted: bool = false,
    /// Too wide for the cap, it was coarsened (§16.7): some parameters are
    /// tracked whole and some result paths cut, each such fact approximate.
    coarse: bool = false,

    fn funOf(s: *const Summary, j: u32) ?FunFacts {
        for (s.funs) |f| if (f.param == j) return f;
        return null;
    }

    fn writesAny(s: *const Summary) bool {
        for (s.uses) |u| if (u.bits & bit_w != 0) return true;
        return false;
    }
};

const Slot = struct {
    state: enum { none, computing, done } = .none,
    sum: Summary = .{ .params = 0 },
};

const Groups = struct {
    /// Per declaration: its group.
    of: []u32,
    order: []u32,
    starts: []u32,
    recursive: []bool,
};

in: Input,
/// Owns everything a report holds.
out: std.heap.ArenaAllocator,
/// Owns every summary.
keep: std.heap.ArenaAllocator,
paths: Paths,
/// Per `TypeId`, a column: null until computed.
nominal: []?NominalFacts = &.{},
ctor_ids: std.AutoHashMapUnmanaged(u64, u32) = .empty,
/// Per module: the summary of each declaration, allocated on first use.
slots: []?[]Slot = &.{},
groups: []?Groups = &.{},
builder_id: ?TypeId = null,
/// Per constructor id: its type's `(module, declaration)`, or none.
ctor_type: std.ArrayList(u64) = .empty,
/// Per constructor id: its `(module, index)`, for printing.
ctor_key: std.ArrayList(u64) = .empty,

pub fn init(in: Input) Ownership {
    return .{ .in = in, .out = .init(in.gpa), .keep = .init(in.gpa), .paths = .{} };
}

pub fn deinit(o: *Ownership) void {
    o.out.deinit();
    o.keep.deinit();
    o.paths.deinit(o.in.gpa);
    o.in.gpa.free(o.nominal);
    o.ctor_ids.deinit(o.in.gpa);
    o.ctor_type.deinit(o.in.gpa);
    o.ctor_key.deinit(o.in.gpa);
    o.in.gpa.free(o.slots);
    o.in.gpa.free(o.groups);
}

/// The report for `targets`, in their order.
pub fn run(o: *Ownership, targets: []const u32) Allocator.Error![]const ModuleReport {
    try o.seedPaths();
    const arena = o.out.allocator();
    const reports = try arena.alloc(ModuleReport, targets.len);
    for (targets, reports) |m, *r| {
        r.* = .{ .module = m, .checked = false, .demands = &.{} };
        if (!o.isChecked(m)) continue;
        r.checked = true;
        const bir = o.in.birs[m];
        // Every summary first (§16.9): a report walk reads them all.
        for (bir.decls, 0..) |_, di| _ = try o.ensureSummary(m, @intCast(di));
        var demands: std.ArrayList(Demand) = .empty;
        for (bir.decls, 0..) |d, di| {
            if (d.kind != .value) continue;
            const body = d.body.unwrap() orelse continue;
            var scratch: std.heap.ArenaAllocator = .init(o.in.gpa);
            defer scratch.deinit();
            var w = o.walker(m, @intCast(di), scratch.allocator(), .report);
            try w.walkDecl(body);
            try w.resolve(&demands);
        }
        // Source order: by position, which is a function of the text.
        std.mem.sort(Demand, demands.items, {}, struct {
            fn less(_: void, x: Demand, y: Demand) bool {
                if (x.position.line != y.position.line) return x.position.line < y.position.line;
                if (x.position.col != y.position.col) return x.position.col < y.position.col;
                if (!std.mem.eql(u8, x.op, y.op)) return std.mem.lessThan(u8, x.op, y.op);
                return std.mem.lessThan(u8, x.base, y.base);
            }
        }.less);
        r.demands = try dedupe(demands.items);
        var lines: std.ArrayList(SummaryLine) = .empty;
        for (bir.decls, 0..) |d, di| {
            if (d.params == 0) continue;
            if (d.kind != .value and d.kind != .foreign_value) continue;
            const s = (try o.ensureSummary(m, @intCast(di))) orelse continue;
            try lines.append(arena, .{ .text = try o.summaryText(m, @intCast(di), s) });
        }
        r.summaries = try lines.toOwnedSlice(arena);
    }
    return reports;
}

/// Two lines the walk produced twice — a demand reached through two
/// classes — are one line.
fn dedupe(items: []Demand) Allocator.Error![]const Demand {
    var n: usize = 0;
    for (items) |d| {
        if (n > 0) {
            const p = items[n - 1];
            if (p.position.line == d.position.line and p.position.col == d.position.col and
                std.mem.eql(u8, p.op, d.op) and std.mem.eql(u8, p.base, d.base) and
                std.meta.eql(p.verdict, d.verdict) and std.mem.eql(u8, p.detail, d.detail)) continue;
        }
        items[n] = d;
        n += 1;
    }
    return items[0..n];
}

fn isChecked(o: *const Ownership, m: u32) bool {
    if (m >= o.in.modules.len) return false;
    const km = &o.in.modules[m];
    const bir = o.in.birs[m];
    return km.inst_type.len == bir.insts.len and km.local_type.len == bir.locals.len;
}

fn walker(o: *Ownership, m: u32, di: u32, a: Allocator, mode: Mode) Walker {
    const km = &o.in.modules[m];
    const bir = o.in.birs[m];
    const d = bir.decls[di];
    return .{
        .o = o,
        .m = m,
        .bir = bir,
        .decl = d,
        .decl_index = di,
        .store = &km.store,
        .inst_type = km.inst_type,
        .local_type = km.local_type[d.locals_start..d.locals_end],
        .a = a,
        .mode = mode,
    };
}

// ---------------------------------------------------------------------------
// Computing summaries (§16.6, §16.9)
// ---------------------------------------------------------------------------

/// The summary of declaration `d` of module `m`, computing its group first
/// when it has none yet; while its group is being solved, the group's
/// current assumption. Null for a declaration with no summary: not a
/// function, in a module the run did not check, or a `foreign` with no
/// asserted row.
fn ensureSummary(o: *Ownership, m: u32, d: u32) Allocator.Error!?*const Summary {
    if (!o.isChecked(m)) return null;
    const bir = o.in.birs[m];
    if (d >= bir.decls.len) return null;
    const decl = bir.decls[d];
    if (decl.params == 0) return null;
    if (decl.kind != .value and decl.kind != .foreign_value) return null;
    const slots = try o.slotsOf(m);
    const slot = &slots[d];
    switch (slot.state) {
        .done, .computing => return &slot.sum,
        .none => {},
    }
    if (try o.assertedRow(m, d)) |row| {
        slot.sum = row;
        slot.state = .done;
        return &slot.sum;
    }
    if (decl.kind != .value or decl.body == .none) return null;
    try o.computeGroup(m, d);
    return &slot.sum;
}

/// Whether `d`'s group is being solved: a call of it is a recursive call.
fn isComputing(o: *const Ownership, m: u32, d: u32) bool {
    if (m >= o.slots.len) return false;
    const slots = o.slots[m] orelse return false;
    return d < slots.len and slots[d].state == .computing;
}

fn slotsOf(o: *Ownership, m: u32) Allocator.Error![]Slot {
    if (o.slots.len == 0) {
        o.slots = try o.in.gpa.alloc(?[]Slot, o.in.birs.len);
        @memset(o.slots, null);
        o.groups = try o.in.gpa.alloc(?Groups, o.in.birs.len);
        @memset(o.groups, null);
    }
    if (o.slots[m]) |s| return s;
    const s = try o.keep.allocator().alloc(Slot, o.in.birs[m].decls.len);
    @memset(s, .{});
    o.slots[m] = s;
    return s;
}

/// The module's top-level declarations as strongly connected groups by
/// their references to each other, dependencies first (§16.6).
fn groupsOf(o: *Ownership, m: u32) Allocator.Error!Groups {
    _ = try o.slotsOf(m);
    if (o.groups[m]) |g| return g;
    const keep = o.keep.allocator();
    const bir = o.in.birs[m];
    const n = bir.decls.len;
    var edges: std.ArrayList(u32) = .empty;
    const starts = try keep.alloc(u32, n + 1);
    const self_edge = try keep.alloc(bool, n);
    @memset(self_edge, false);
    const tags = bir.insts.items(.tag);
    const datas = bir.insts.items(.data);
    for (bir.decls, 0..) |d, di| {
        starts[di] = @intCast(edges.items.len);
        if (d.kind != .value) continue;
        var i = d.inst_start.int();
        while (i < d.inst_end.int()) : (i += 1) {
            const target: u32 = switch (tags[i]) {
                .top => datas[i].lhs,
                .method_call => blk: {
                    if (m >= o.in.dispatch.len) break :blk none;
                    const dt = &o.in.dispatch[m];
                    const site = dt.siteOf(@fromBackingInt(i)) orelse break :blk none;
                    const ci = site.callee.unwrap() orelse break :blk none;
                    break :blk switch (dt.term(ci)) {
                        .top => |t| t.decl.int(),
                        else => none,
                    };
                },
                else => none,
            };
            if (target == none or target >= n) continue;
            if (target == di) self_edge[di] = true;
            try edges.append(keep, target);
        }
    }
    starts[n] = @intCast(edges.items.len);
    const g = try Scc.sccGroups(keep, n, edges.items, starts);
    const count = g.starts.len - 1;
    const of = try keep.alloc(u32, n);
    const recursive = try keep.alloc(bool, count);
    for (0..count) |gi| {
        const members = g.order[g.starts[gi]..g.starts[gi + 1]];
        recursive[gi] = members.len > 1 or self_edge[members[0]];
        for (members) |x| of[x] = @intCast(gi);
    }
    const out: Groups = .{ .of = of, .order = g.order, .starts = g.starts, .recursive = recursive };
    o.groups[m] = out;
    return out;
}

fn computeGroup(o: *Ownership, m: u32, d: u32) Allocator.Error!void {
    const groups = try o.groupsOf(m);
    const gi = groups.of[d];
    const all = groups.order[groups.starts[gi]..groups.starts[gi + 1]];
    const bir = o.in.birs[m];
    const slots = o.slots[m].?;
    var members: std.ArrayList(u32) = .empty;
    defer members.deinit(o.in.gpa);
    for (all) |x| {
        const dx = bir.decls[x];
        if (dx.kind != .value or dx.params == 0 or dx.body == .none) continue;
        if (slots[x].state != .none) continue;
        if (try o.assertedRow(m, x)) |row| {
            slots[x] = .{ .state = .done, .sum = row };
            continue;
        }
        try members.append(o.in.gpa, x);
    }
    std.mem.sort(u32, members.items, {}, std.sort.asc(u32));
    for (members.items) |x| slots[x] = .{ .state = .computing, .sum = .{ .params = bir.decls[x].params } };
    if (!groups.recursive[gi]) {
        for (members.items) |x| {
            slots[x].sum = try o.walkSummary(m, x, false);
            slots[x].state = .done;
        }
        return;
    }
    // Optimistic, joined (§16.6): each round walks every member against
    // the current assumptions and joins what it reads off into them.
    var round: u32 = 0;
    while (round < round_cap) : (round += 1) {
        var changed = false;
        for (members.items) |x| {
            const next = try o.walkSummary(m, x, true);
            const joined = try o.join(slots[x].sum, next);
            if (!summaryEql(joined, slots[x].sum)) changed = true;
            slots[x].sum = joined;
        }
        if (!changed) break;
    }
    if (round == round_cap) {
        for (members.items) |x| slots[x].sum = try o.pessimistic(slots[x].sum, .rounds);
    }
    for (members.items) |x| slots[x].state = .done;
}

/// One walk of `d` and the summary read off it.
fn walkSummary(o: *Ownership, m: u32, d: u32, recursive: bool) Allocator.Error!Summary {
    var scratch: std.heap.ArenaAllocator = .init(o.in.gpa);
    defer scratch.deinit();
    var w = o.walker(m, d, scratch.allocator(), .summary);
    w.recursive = recursive;
    try w.walkDecl(w.decl.body.unwrap().?);
    var ignored: std.ArrayList(Demand) = .empty;
    try w.resolve(&ignored);
    return w.readOff();
}

// ---------------------------------------------------------------------------
// The lattice (§16.2)
// ---------------------------------------------------------------------------

fn summaryEql(x: Summary, y: Summary) bool {
    if (x.limit != y.limit or x.params != y.params or x.coarse != y.coarse) return false;
    if (x.uses.len != y.uses.len or x.res.len != y.res.len or x.supply.len != y.supply.len or x.funs.len != y.funs.len) return false;
    for (x.uses, y.uses) |a, b| if (!std.meta.eql(a, b)) return false;
    for (x.res, y.res) |a, b| if (a.path != b.path or !a.prov.eql(b.prov) or a.approx != b.approx) return false;
    for (x.supply, y.supply) |a, b| if (a.fun != b.fun or a.k != b.k or a.path != b.path or !a.prov.eql(b.prov) or a.owned != b.owned) return false;
    for (x.funs, y.funs) |a, b| if (!std.meta.eql(a, b)) return false;
    return true;
}

fn join(o: *Ownership, x: Summary, y: Summary) Allocator.Error!Summary {
    if (x.limit != .none) return x;
    if (y.limit != .none) return o.pessimistic(x, y.limit);
    const keep = o.keep.allocator();
    var uses: std.ArrayList(UseEntry) = .empty;
    try uses.appendSlice(keep, x.uses);
    try uses.appendSlice(keep, y.uses);
    var res: std.ArrayList(ResEntry) = .empty;
    try res.appendSlice(keep, x.res);
    try res.appendSlice(keep, y.res);
    var supply: std.ArrayList(SupplyEntry) = .empty;
    try supply.appendSlice(keep, x.supply);
    try supply.appendSlice(keep, y.supply);
    var funs: std.ArrayList(FunFacts) = .empty;
    try funs.appendSlice(keep, x.funs);
    try funs.appendSlice(keep, y.funs);
    return o.normalize(.{
        .params = @max(x.params, y.params),
        .uses = uses.items,
        .res = res.items,
        .supply = supply.items,
        .funs = funs.items,
    });
}

/// Sorted, merged, and capped (§16.7).
fn normalize(o: *Ownership, s: Summary) Allocator.Error!Summary {
    const out = try o.normalizeRaw(s);
    if (out.limit != .none or out.coarse or o.widthOf(out) <= width_cap) return out;
    // Too wide (§16.7): track the widest parameters whole and cut the
    // result's and the supplies' paths, each step approximate; only a
    // summary still too wide is the pessimistic one.
    const coarse = try o.coarsen(out);
    if (o.widthOf(coarse) <= width_cap) return coarse;
    return o.pessimistic(out, .width);
}

/// Sorted and merged.
fn normalizeRaw(o: *Ownership, s: Summary) Allocator.Error!Summary {
    const keep = o.keep.allocator();
    const uses = try keep.dupe(UseEntry, s.uses);
    std.mem.sort(UseEntry, uses, {}, struct {
        fn less(_: void, x: UseEntry, y: UseEntry) bool {
            if (x.param != y.param) return x.param < y.param;
            return x.path < y.path;
        }
    }.less);
    var nu: usize = 0;
    for (uses) |u| {
        if (u.bits == 0) continue;
        if (nu > 0 and uses[nu - 1].param == u.param and uses[nu - 1].path == u.path) {
            uses[nu - 1].bits |= u.bits;
            continue;
        }
        uses[nu] = u;
        nu += 1;
    }
    const res = try keep.dupe(ResEntry, s.res);
    std.mem.sort(ResEntry, res, {}, struct {
        fn less(_: void, x: ResEntry, y: ResEntry) bool {
            if (x.path != y.path) return x.path < y.path;
            return x.prov.less(y.prov);
        }
    }.less);
    var nr: usize = 0;
    for (res) |r| {
        if (nr > 0 and res[nr - 1].path == r.path and res[nr - 1].prov.eql(r.prov)) {
            res[nr - 1].approx = res[nr - 1].approx or r.approx;
            continue;
        }
        res[nr] = r;
        nr += 1;
    }
    const supply = try keep.dupe(SupplyEntry, s.supply);
    std.mem.sort(SupplyEntry, supply, {}, struct {
        fn less(_: void, x: SupplyEntry, y: SupplyEntry) bool {
            if (x.fun != y.fun) return x.fun < y.fun;
            if (x.k != y.k) return x.k < y.k;
            if (x.path != y.path) return x.path < y.path;
            return x.prov.less(y.prov);
        }
    }.less);
    var ns: usize = 0;
    for (supply) |e| {
        if (ns > 0) {
            const p = &supply[ns - 1];
            if (p.fun == e.fun and p.k == e.k and p.path == e.path and p.prov.eql(e.prov)) {
                p.owned = p.owned and e.owned;
                continue;
            }
        }
        supply[ns] = e;
        ns += 1;
    }
    const funs = try keep.dupe(FunFacts, s.funs);
    std.mem.sort(FunFacts, funs, {}, struct {
        fn less(_: void, x: FunFacts, y: FunFacts) bool {
            return x.param < y.param;
        }
    }.less);
    var nf: usize = 0;
    for (funs) |f| {
        if (nf > 0 and funs[nf - 1].param == f.param) {
            const p = &funs[nf - 1];
            p.calls = @fromBackingInt(@max(@backingInt(p.calls), @backingInt(f.calls)));
            p.need = p.need or f.need;
            p.seen = p.seen and f.seen;
            continue;
        }
        funs[nf] = f;
        nf += 1;
    }
    const out: Summary = .{
        .params = s.params,
        .uses = uses[0..nu],
        .res = res[0..nr],
        .supply = supply[0..ns],
        .funs = funs[0..nf],
        .limit = s.limit,
        .asserted = s.asserted,
        .coarse = s.coarse,
    };
    return out;
}

/// The number of distinct paths in a summary's widest component.
fn widthOf(o: *const Ownership, s: Summary) usize {
    _ = o;
    var res_paths: usize = 0;
    for (s.res, 0..) |r, i| {
        if (i == 0 or s.res[i - 1].path != r.path) res_paths += 1;
    }
    var supply_paths: usize = 0;
    for (s.supply, 0..) |e, i| {
        if (i == 0) {
            supply_paths += 1;
            continue;
        }
        const p = s.supply[i - 1];
        if (p.fun != e.fun or p.k != e.k or p.path != e.path) supply_paths += 1;
    }
    return @max(s.uses.len, @max(res_paths, supply_paths));
}

/// `p` cut to its first `d` steps, then `⋆`.
fn truncate(o: *Ownership, p: u32, d: usize) Allocator.Error!u32 {
    var buf: [k_limit + 1]Step = undefined;
    const s = o.steps(p, &buf);
    if (s.len <= d) return p;
    var at: u32 = eps;
    for (s[0..d]) |st| at = try o.child(at, st.kind, st.arg);
    return o.child(at, .any, 0);
}

fn coarsen(o: *Ownership, s: Summary) Allocator.Error!Summary {
    const keep = o.keep.allocator();
    // Parameters tracked whole, the widest first, until the uses fit.
    var uses: std.ArrayList(UseEntry) = .empty;
    try uses.appendSlice(keep, s.uses);
    while (uses.items.len > width_cap) {
        var widest: u32 = 0;
        var most: usize = 0;
        var p: u32 = 0;
        while (p < s.params) : (p += 1) {
            var n: usize = 0;
            for (uses.items) |u| if (u.param == p) {
                n += 1;
            };
            if (n > most) {
                most = n;
                widest = p;
            }
        }
        if (most <= 1) break;
        var bits: u8 = 0;
        var kept: std.ArrayList(UseEntry) = .empty;
        for (uses.items) |u| {
            if (u.param == widest) bits |= u.bits else try kept.append(keep, u);
        }
        try kept.append(keep, .{ .param = widest, .path = eps, .bits = bits & ~bit_x });
        uses = kept;
    }
    // The result's and the supplies' paths, cut shallower until they fit.
    const res = try keep.dupe(ResEntry, s.res);
    const supply = try keep.dupe(SupplyEntry, s.supply);
    var depth: usize = k_limit;
    while (depth > 0) {
        const trial = try o.normalizeRaw(.{ .params = s.params, .uses = uses.items, .res = res, .supply = supply, .funs = s.funs });
        if (o.widthOf(trial) <= width_cap) break;
        depth -= 1;
        for (res) |*r| {
            const t = try o.truncate(r.path, depth);
            if (t != r.path) {
                r.path = t;
                r.approx = true;
            }
        }
        for (supply) |*e| e.path = try o.truncate(e.path, depth);
    }
    var out = try o.normalizeRaw(.{ .params = s.params, .uses = uses.items, .res = res, .supply = supply, .funs = s.funs, .asserted = s.asserted });
    out.coarse = true;
    return out;
}

/// The pessimistic summary of §16.2: every parameter written, kept and
/// returned whole, the result unknown, every callback out of sight.
fn pessimistic(o: *Ownership, s: Summary, why: Limit) Allocator.Error!Summary {
    const keep = o.keep.allocator();
    const uses = try keep.alloc(UseEntry, s.params);
    for (uses, 0..) |*u, i| u.* = .{ .param = @intCast(i), .path = eps, .bits = bit_r | bit_a | bit_e | bit_w };
    const res = try keep.dupe(ResEntry, &.{.{ .path = eps, .prov = .{ .kind = .top }, .approx = true }});
    const funs = try keep.alloc(FunFacts, s.funs.len);
    for (funs, s.funs) |*f, g| f.* = .{ .param = g.param, .calls = .many, .need = true, .seen = false };
    return .{ .params = s.params, .uses = uses, .res = res, .funs = funs, .limit = why, .asserted = s.asserted };
}

// ---------------------------------------------------------------------------
// The asserted rows (§16.8)
// ---------------------------------------------------------------------------

fn assertedRow(o: *Ownership, m: u32, d: u32) Allocator.Error!?Summary {
    if (o.in.packages[m] != .core or !std.mem.eql(u8, o.in.module_names[m], "List")) return null;
    const bir = o.in.birs[m];
    const name = o.in.interner.slice(bir.symbol(bir.decls[d].name));
    const R = bit_r;
    const A = bit_a;
    const W = bit_w | bit_x;
    const elem = try o.child(eps, .elem, 0);
    const p = struct {
        fn at(i: u32, path: u32) Prov {
            return .{ .kind = .param, .a = i, .path = path };
        }
    }.at;
    const fresh: Prov = .{ .kind = .fresh, .a = 1 };
    const Row = struct { uses: []const UseEntry, res: []const ResEntry };
    // A writer whose base is parameter `b` and which stores parameter `v`
    // (or none) at its elements.
    const row: ?Row = if (eqlAny(name, &.{ "set", "insertAt" }))
        .{ .uses = &.{ .{ .param = 0, .path = eps, .bits = R | A | W }, .{ .param = 2, .path = eps, .bits = A } }, .res = &.{ .{ .path = eps, .prov = p(0, eps) }, .{ .path = elem, .prov = p(0, elem) }, .{ .path = elem, .prov = p(2, eps) } } }
    else if (eqlAny(name, &.{ "push", "put" }))
        if (std.mem.eql(u8, name, "push"))
            .{ .uses = &.{ .{ .param = 0, .path = eps, .bits = R | A | W }, .{ .param = 1, .path = eps, .bits = A } }, .res = &.{ .{ .path = eps, .prov = p(0, eps) }, .{ .path = elem, .prov = p(0, elem) }, .{ .path = elem, .prov = p(1, eps) } } }
        else
            .{ .uses = &.{ .{ .param = 0, .path = eps, .bits = R | A | W }, .{ .param = 2, .path = eps, .bits = A } }, .res = &.{ .{ .path = eps, .prov = p(0, eps) }, .{ .path = elem, .prov = p(0, elem) }, .{ .path = elem, .prov = p(2, eps) } } }
    else if (eqlAny(name, &.{ "pop", "removeAt", "done" }))
        .{ .uses = &.{.{ .param = 0, .path = eps, .bits = R | A | W }}, .res = &.{ .{ .path = eps, .prov = p(0, eps) }, .{ .path = elem, .prov = p(0, elem) } } }
    else if (std.mem.eql(u8, name, "cons"))
        .{ .uses = &.{ .{ .param = 0, .path = eps, .bits = A }, .{ .param = 1, .path = eps, .bits = R | A | W } }, .res = &.{ .{ .path = eps, .prov = p(1, eps) }, .{ .path = elem, .prov = p(1, elem) }, .{ .path = elem, .prov = p(0, eps) } } }
    else if (std.mem.eql(u8, name, "append"))
        .{ .uses = &.{ .{ .param = 0, .path = eps, .bits = R | A | W }, .{ .param = 1, .path = eps, .bits = R }, .{ .param = 1, .path = elem, .bits = A } }, .res = &.{ .{ .path = eps, .prov = p(0, eps) }, .{ .path = elem, .prov = p(0, elem) }, .{ .path = elem, .prov = p(1, elem) } } }
    else if (eqlAny(name, &.{ "copy", "sliceOf" }))
        .{ .uses = &.{ .{ .param = 0, .path = eps, .bits = R }, .{ .param = 0, .path = elem, .bits = A } }, .res = &.{ .{ .path = eps, .prov = fresh }, .{ .path = elem, .prov = p(0, elem) } } }
    else if (eqlAny(name, &.{ "length", "offset" }))
        .{ .uses = &.{.{ .param = 0, .path = eps, .bits = R }}, .res = &.{} }
    else if (eqlAny(name, &.{ "at", "unsafeGet" }))
        .{ .uses = &.{ .{ .param = 0, .path = eps, .bits = R }, .{ .param = 0, .path = elem, .bits = A } }, .res = &.{.{ .path = eps, .prov = p(0, elem) }} }
    else if (std.mem.eql(u8, name, "view"))
        .{ .uses = &.{.{ .param = 0, .path = eps, .bits = R | A }}, .res = &.{ .{ .path = eps, .prov = p(0, eps) }, .{ .path = eps, .prov = fresh }, .{ .path = elem, .prov = p(0, elem) } } }
    else if (std.mem.eql(u8, name, "base"))
        .{ .uses = &.{.{ .param = 0, .path = eps, .bits = R | A }}, .res = &.{ .{ .path = eps, .prov = p(0, eps) }, .{ .path = elem, .prov = p(0, elem) } } }
    else if (std.mem.eql(u8, name, "builder"))
        .{ .uses = &.{}, .res = &.{.{ .path = eps, .prov = fresh }} }
    else if (std.mem.eql(u8, name, "identical"))
        .{ .uses = &.{}, .res = &.{} }
    else if (std.mem.eql(u8, name, "kept"))
        .{ .uses = &.{ .{ .param = 1, .path = eps, .bits = A }, .{ .param = 2, .path = eps, .bits = A } }, .res = &.{ .{ .path = eps, .prov = p(1, eps) }, .{ .path = eps, .prov = p(2, eps) }, .{ .path = elem, .prov = p(1, elem) }, .{ .path = elem, .prov = p(2, elem) } } }
    else
        null;
    const r = row orelse return null;
    const keep = o.keep.allocator();
    return try o.normalize(.{
        .params = o.in.birs[m].decls[d].params,
        .uses = try keep.dupe(UseEntry, r.uses),
        .res = try keep.dupe(ResEntry, r.res),
        .asserted = true,
    });
}

fn eqlAny(name: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Printing a summary (§16.11)
// ---------------------------------------------------------------------------

fn summaryText(o: *Ownership, m: u32, d: u32, s: *const Summary) Allocator.Error![]const u8 {
    const arena = o.out.allocator();
    const bir = o.in.birs[m];
    var parts: std.ArrayList([]const u8) = .empty;
    // Parameters' bits, in text order.
    var uses: std.ArrayList([]const u8) = .empty;
    for (s.uses) |u| {
        var buf: std.Io.Writer.Allocating = .init(arena);
        const wr = &buf.writer;
        wr.print("π{d}", .{u.param + 1}) catch return error.OutOfMemory;
        o.writePath(wr, u.path) catch return error.OutOfMemory;
        wr.writeByte(' ') catch return error.OutOfMemory;
        inline for (.{ .{ bit_r, "R" }, .{ bit_a, "A" }, .{ bit_e, "E" } }) |b| {
            if (u.bits & b[0] != 0) wr.writeAll(b[1]) catch return error.OutOfMemory;
        }
        // `w`: written only through an approximate step.
        if (u.bits & bit_w != 0) wr.writeAll(if (u.bits & bit_x != 0) "W" else "w") catch return error.OutOfMemory;
        try uses.append(arena, try buf.toOwnedSlice());
    }
    sortText(uses.items);
    if (uses.items.len > 0) try parts.append(arena, try std.mem.join(arena, ", ", uses.items));
    // The result, grouped by path in text order.
    var groups: std.ArrayList(struct { path: []const u8, provs: std.ArrayList([]const u8) }) = .empty;
    for (s.res) |r| {
        const pt = try o.pathText(r.path);
        var found: ?usize = null;
        for (groups.items, 0..) |g, i| if (std.mem.eql(u8, g.path, pt)) {
            found = i;
        };
        const i = found orelse blk: {
            try groups.append(arena, .{ .path = pt, .provs = .empty });
            break :blk groups.items.len - 1;
        };
        const t = try o.provText(r.prov);
        try groups.items[i].provs.append(arena, if (r.approx) try std.fmt.allocPrint(arena, "~{s}", .{t}) else t);
    }
    if (groups.items.len > 0) {
        var gtexts: std.ArrayList([]const u8) = .empty;
        for (groups.items) |*g| {
            sortText(g.provs.items);
            const provs = try std.mem.join(arena, " ", g.provs.items);
            try gtexts.append(arena, if (g.path.len == 0) provs else try std.fmt.allocPrint(arena, "{s} {s}", .{ g.path, provs }));
        }
        sortText(gtexts.items);
        try parts.append(arena, try std.fmt.allocPrint(arena, "res {s}", .{try std.mem.join(arena, ", ", gtexts.items)}));
    }
    // Function parameters.
    for (s.funs) |f| {
        var buf: std.Io.Writer.Allocating = .init(arena);
        const wr = &buf.writer;
        wr.print("π{d} calls {s}", .{ f.param + 1, switch (f.calls) {
            .zero => "0",
            .once => "≤1",
            .many => "many",
        } }) catch return error.OutOfMemory;
        if (f.need) wr.writeAll(", need owned") catch return error.OutOfMemory;
        if (!f.seen) wr.writeAll(", unseen") catch return error.OutOfMemory;
        var sup: std.ArrayList([]const u8) = .empty;
        for (s.supply) |e| {
            if (e.fun != f.param) continue;
            const pt = try o.pathText(e.path);
            try sup.append(arena, try std.fmt.allocPrint(arena, "supply {d}{s} {s} {s}", .{ e.k + 1, pt, try o.provText(e.prov), if (e.owned) "owned" else "borrowed" }));
        }
        sortText(sup.items);
        for (sup.items) |t| wr.print(", {s}", .{t}) catch return error.OutOfMemory;
        try parts.append(arena, try buf.toOwnedSlice());
    }
    if (s.limit != .none) try parts.append(arena, if (s.limit == .width) "limit width" else "limit rounds");
    if (s.coarse) try parts.append(arena, "coarse");
    const facts = if (parts.items.len == 0) "unused" else try std.mem.join(arena, "; ", parts.items);
    const name = o.in.interner.slice(bir.symbol(bir.decls[d].name));
    return std.fmt.allocPrint(arena, "summary {s}: {s}{s}", .{ name, facts, if (s.asserted) " (asserted)" else "" });
}

fn sortText(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
}

fn pathText(o: *Ownership, p: u32) Allocator.Error![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(o.out.allocator());
    o.writePath(&buf.writer, p) catch return error.OutOfMemory;
    return buf.toOwnedSlice();
}

fn provText(o: *Ownership, p: Prov) Allocator.Error![]const u8 {
    const arena = o.out.allocator();
    const pt = try o.pathText(p.path);
    return switch (p.kind) {
        .param => std.fmt.allocPrint(arena, "π{d}{s}", .{ p.a + 1, pt }),
        .fresh => if (p.a == 0) "fresh" else std.fmt.allocPrint(arena, "fresh{d}", .{p.a}),
        .esc => if (p.a == 0) "esc" else std.fmt.allocPrint(arena, "esc{d}", .{p.a}),
        .shared => blk: {
            const b = o.in.birs[p.a];
            break :blk std.fmt.allocPrint(arena, "shared({s}.{s}){s}", .{ o.in.module_names[p.a], o.in.interner.slice(b.symbol(b.decls[p.b].name)), pt });
        },
        .top => if (p.a == 1) "⊤limit" else "⊤",
        .cb => std.fmt.allocPrint(arena, "cb{d}{s}", .{ p.a + 1, pt }),
        .env => std.fmt.allocPrint(arena, "◇{d}{s}", .{ p.a, pt }),
    };
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
    // A recursive type is folded (thesis §3.1): a constructor step into a
    // value of a type the path is already inside goes on from where the
    // path first entered that type, so `t#.3#.3` is `t#.3`'s twin and a
    // summary over a tree stays a few paths wide (§16.7).
    if (kind == .ctor) if (o.foldAt(parent, arg)) |at| return o.rawChild(at, kind, arg);
    return o.rawChild(parent, kind, arg);
}

fn foldAt(o: *Ownership, parent: u32, arg: u32) ?u32 {
    const ty = o.ctorType(arg / 64) orelse return null;
    var chain: [k_limit + 1]u32 = undefined;
    var n: usize = 0;
    var at = parent;
    while (at != eps and at != none) : (at = o.paths.parent.items[at]) {
        chain[n] = at;
        n += 1;
    }
    // Root first: `chain[n - 1]` is the first step.
    var i = n;
    while (i > 0) {
        i -= 1;
        const node = chain[i];
        if (o.paths.kind.items[node] != .ctor) continue;
        const t = o.ctorType(o.paths.arg.items[node] / 64) orelse continue;
        if (t == ty) return o.paths.parent.items[node];
    }
    return null;
}

fn ctorType(o: *const Ownership, c: u32) ?u64 {
    if (c >= o.ctor_type.items.len) return null;
    const t = o.ctor_type.items[c];
    return if (t == std.math.maxInt(u64)) null else t;
}

fn rawChild(o: *Ownership, parent: u32, kind: StepKind, arg: u32) Allocator.Error!u32 {
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

/// When `p` is a prefix of `q`, the rest of `q`; else null.
fn suffix(o: *Ownership, p: u32, q: u32) Allocator.Error!?u32 {
    var bp: [k_limit + 1]Step = undefined;
    var bq: [k_limit + 1]Step = undefined;
    const sp = o.steps(p, &bp);
    const sq = o.steps(q, &bq);
    if (sp.len > sq.len) return null;
    for (sp, sq[0..sp.len]) |x, y| if (x.kind != y.kind or x.arg != y.arg) return null;
    var at: u32 = eps;
    for (sq[sp.len..]) |s| at = try o.child(at, s.kind, s.arg);
    return at;
}

/// Whether `p` is a prefix of `q`, `⋆` matching anything.
fn isPrefix(o: *const Ownership, p: u32, q: u32) bool {
    return o.paths.depth.items[p] <= o.paths.depth.items[q] and o.overlap(p, q);
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
        .ctor => {
            // `#Name.i`: the constructor and the argument.
            const c = s.arg / 64;
            const name: []const u8 = blk: {
                if (c >= o.ctor_key.items.len) break :blk "";
                const key = o.ctor_key.items[c];
                const m: u32 = @intCast(key >> 32);
                const i: u32 = @truncate(key);
                if (m >= o.in.birs.len or i == none) break :blk "";
                const bir = o.in.birs[m];
                if (i >= bir.ctors.len) break :blk "";
                break :blk o.in.interner.slice(bir.symbol(bir.ctors[i].name));
            };
            try w.print("#{s}.{d}", .{ name, s.arg % 64 });
        },
        .elem => try w.writeAll("[*]"),
        .env => try w.writeAll("◇"),
        .any => try w.writeAll("⋆"),
    };
}

fn ctorId(o: *Ownership, module: u32, index: u32) Allocator.Error!u32 {
    const key = (@as(u64, module) << 32) | index;
    const gop = try o.ctor_ids.getOrPut(o.in.gpa, key);
    if (!gop.found_existing) {
        gop.value_ptr.* = @intCast(o.ctor_ids.count() - 1);
        // The type that declares it, for folding (§16.7).
        var ty: u64 = std.math.maxInt(u64);
        if (module < o.in.birs.len and index != none) {
            const bir = o.in.birs[module];
            if (index < bir.ctors.len) ty = (@as(u64, module) << 32) | bir.ctors[index].decl.int();
        }
        try o.ctor_type.append(o.in.gpa, ty);
        try o.ctor_key.append(o.in.gpa, key);
    }
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
            for (bir.extraSlice(Bir.inlineRange(data), Inst.Index)) |el| f = joinFacts(f, try o.birTypeFacts(m, bir, el, depth + 1));
            return f;
        },
        .type_record => {
            var f: NominalFacts = .{};
            for (bir.extraSlice(Bir.inlineRange(data), Bir.Field)) |fl| f = joinFacts(f, try o.birTypeFacts(m, bir, fl.value, depth + 1));
            return f;
        },
        .type_record_ext => {
            var f: NominalFacts = .{ .params = true };
            for (bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(data.rhs))), Bir.Field)) |fl| f = joinFacts(f, try o.birTypeFacts(m, bir, fl.value, depth + 1));
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
                f = joinFacts(f, try o.birTypeFacts(m, bir, arg, depth + 1));
            };
            return f;
        },
        else => return .{ .own = true },
    }
}

fn joinFacts(a: NominalFacts, b: NominalFacts) NominalFacts {
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

fn isFunc(store: *TypeStore, v: Var) bool {
    return switch (store.resolvedContent(v)) {
        .structure => |s| s == .func,
        else => false,
    };
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

/// `core/List`'s `Builder`, which `done` hands over as the list it is: the
/// two types are one run-time object (§16.8's `done` row).
fn builderId(o: *Ownership) TypeId {
    if (o.builder_id) |id| return id;
    var found: TypeId = .none;
    for (o.in.types.entries, 0..) |e, i| {
        if (e.package != .core or e.kind != .foreign) continue;
        if (!std.mem.eql(u8, o.in.interner.slice(e.module_name), "List")) continue;
        if (!std.mem.eql(u8, o.in.interner.slice(e.name), "Builder")) continue;
        found = @fromBackingInt(@intCast(i));
        break;
    }
    o.builder_id = found;
    return found;
}

fn sameRepresentation(o: *Ownership, x: TypeId, y: TypeId) bool {
    if (x == y) return true;
    const list = o.in.types.well_known.list;
    const builder = o.builderId();
    if (builder == .none) return false;
    return (x == list or x == builder) and (y == list or y == builder);
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
                    if (!o.sameRepresentation(x.type, y.type)) return false;
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

const Mode = enum { summary, report };

const CellKind = enum(u8) { site, param, result, env, shared, top, closure, func, cbres };

const Cell = struct {
    kind: CellKind,
    /// site/result: the instruction; param: the parameter pattern
    /// instruction; env: the captured local; shared: the module; closure:
    /// its index; func: the module; cbres: the function parameter's index.
    a: u32,
    /// shared/func: the declaration; param: 1 for a lambda's or local
    /// function's parameter, 0 for the declaration's own; result: 0 for a
    /// call with no summary (§6.1), else the callee's fresh number; cbres:
    /// the call's instruction.
    b: u32 = 0,
    path: u32 = eps,
    ty: Var.Optional = .none,
};

const Entry = struct {
    path: u32,
    cell: u32,
    /// 0 when exact; else 1 + the instruction of the call whose
    /// conservative aliasing or identity promise put the entry here (§8.4).
    approx: u32 = 0,
};

const AV = []const Entry;

const Capture = struct { local: u32, path: u32 };

/// How a lambda was consumed: what decides its demands on its own
/// parameters (§16.5).
const Consumption = struct {
    kind: enum { supply, local, no_summary, pending },
    /// supply: per parameter of the lambda, a borrowed supply's reason, or
    /// null when every supply it writes is owned.
    bad: []const ?[]const u8 = &.{},
    /// supply: whether the reason is a limit (an element).
    bad_approx: []const bool = &.{},
    /// The summary or callee that decided it, for the note.
    name: []const u8 = "",
    /// pending: why.
    why: []const u8 = "",
};

const Closure = struct {
    captures: []const Capture,
    params: []const Inst.Index = &.{},
    frame: u32 = 0,
    class: ?*const Summary = null,
    /// The captured cells the lambda's body escaped (§16.4 item 4).
    env_escapes: []const Capture = &.{},
    consumed: std.ArrayList(Consumption) = .empty,
};

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

const DemandKind = enum { report, callsite, probe, value };

const DemandRec = struct {
    kind: DemandKind = .report,
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
    /// The callee with no summary an acceptance rests on (§15 decision 2).
    assumed: []const u8 = "",
    prelim: ?struct { cause: Cause, detail: []const u8, approx: ?bool = null } = null,
    /// A value line's own verdict (§16.5).
    fixed: ?struct { verdict: Verdict, detail: []const u8, assumed: bool = false } = null,
    holders: []const Holder,
    /// The base's cells: what read-off makes W of (§16.3).
    cells: []const Entry = &.{},
    note: []const u8 = "",
    /// A probe's slot in `probe_ok`.
    probe: u32 = none,
    /// Where a call-site demand's W came from.
    origin: Origin = .exact,
};

/// Where a call-site demand's W came from: a summary's exact write, one
/// derived through an approximate step (a rejection is then the `call`
/// cause), or a pessimistic summary (the `limit` cause, §16.7).
const Origin = enum { exact, approx, limit };

const Pending = struct {
    av: AV,
    frame: u32,
    token: u32,
    is_ref: bool,
    by_call: bool,
    /// The summary of the call this operand waits for, and its index:
    /// it holds a cell only at paths that call touches (§16.4 item 2).
    consumer: ?*const Summary = null,
    arg: u32 = 0,
};

const CtxNode = struct { parent: u32, case_id: u32, arm: u32, depth: u32 };

const Frame = struct {
    /// The enclosing frame, or `none` for the declaration's.
    parent: u32,
    captures: std.ArrayList(Capture) = .empty,
    pending_base: usize,
};

const PatSite = struct { list: Inst.Index, index: u32, spread: bool };

/// What the walk learns about a function-typed parameter (§16.2).
const FnState = struct {
    is_fn: bool = false,
    calls: Calls = .zero,
    need: bool = false,
    seen: bool = true,
};

/// A supply to a function parameter, read off once its probe is resolved.
const SupplyRec = struct {
    fun: u32,
    k: u32,
    path: u32,
    av: AV,
    probe: u32,
    /// The callee's own `owned`, for a supply passed on (§16.4 item 4).
    owned: bool = true,
};

/// A summary or class being applied at a call.
const Callee = struct {
    sum: *const Summary,
    /// For notes: `Main.f`, `List.update`, `<lambda>`.
    name: []const u8,
    /// The operation of a call-site demand line.
    op: []const u8,
    /// A lambda's class: its closure, whose captures `◇` names.
    closure: u32 = none,
    /// A member of the recursive group being solved (§16.6).
    merge_fresh: bool = false,
};

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
    mode: Mode,
    /// The declaration is in a recursive group (§16.6).
    recursive: bool = false,

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
    /// Per instruction of the declaration: a lambda parameter's pattern's
    /// closure and position, `none` elsewhere.
    pat_closure: [][2]u32 = &.{},
    /// The declaration's parameters.
    params: []const Inst.Index = &.{},
    fn_state: []FnState = &.{},
    supplies: std.ArrayList(SupplyRec) = .empty,
    probe_ok: std.ArrayList(bool) = .empty,
    result_av: AV = &.{},
    /// Per local: 1 for a local function of the `let` being created, 2 once
    /// it is named before its class exists (§16.5); 0 otherwise.
    early: []u8 = &.{},
    /// The writing top-level functions already reported out of sight: one
    /// line where each first leaves it (§16.5).
    unseen_funcs: std.AutoHashMapUnmanaged(u64, void) = .empty,

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
        w.early = try w.a.alloc(u8, n);
        @memset(w.early, 0);
        w.pat_closure = try w.a.alloc([2]u32, w.decl.inst_end.int() - w.decl.inst_start.int());
        @memset(w.pat_closure, .{ none, none });
        try w.ctx_nodes.append(w.a, .{ .parent = none, .case_id = none, .arm = 0, .depth = 0 });
        try w.frames.append(w.a, .{ .parent = none, .pending_base = 0 });
        w.params = w.bir.extraSlice(.{ .start = w.decl.params_start, .end = w.decl.params_end }, Inst.Index);
        w.fn_state = try w.a.alloc(FnState, w.params.len);
        @memset(w.fn_state, .{});
        for (w.params, 0..) |p, i| {
            if (w.patternType(p)) |v| w.fn_state[i].is_fn = isFunc(w.store, v);
            try w.bindParam(p, 0);
        }
        const result = try w.eval(body);
        try w.consume(&.{body}, w.bir.insts.items(.main_token)[body.int()]);
        try w.sight(result, .{ .pending = "it is returned" }, w.token(body));
        w.result_av = result;
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

    fn pos(w: *const Walker, tok: u32) Position {
        return w.o.in.positions.get(w.o.in.positions.ctx, w.m, tok);
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

    /// `av` placed under the path `p`.
    fn under(w: *Walker, av: AV, p: u32) Allocator.Error!AV {
        if (p == eps) return av;
        const out = try w.a.alloc(Entry, av.len);
        for (av, out) |e, *x| x.* = .{ .path = try w.o.concat(p, e.path), .cell = e.cell, .approx = e.approx };
        return w.norm(out);
    }

    fn approxAll(w: *Walker, av: AV, inst: Inst.Index) Allocator.Error!AV {
        const out = try w.a.alloc(Entry, av.len);
        for (av, out) |e, *x| x.* = .{ .path = e.path, .cell = e.cell, .approx = if (e.approx != 0) e.approx else inst.int() + 1 };
        return out;
    }

    /// A symbolic cell one step further down (§4.3).
    fn projCell(w: *Walker, c: u32, s: Step, ty: ?Var) Allocator.Error!?u32 {
        const x = w.cells.items[c];
        switch (x.kind) {
            .site, .closure, .func => return null,
            .top => return c,
            .param, .result, .env, .shared, .cbres => {
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
            const at = try w.o.child(path, .env, 0);
            for (w.closures.items[c.a].captures) |cap| {
                const held = w.local_av[cap.local] orelse continue;
                const sub = try w.projPath(held, cap.path, null);
                try w.expandInto(sub, at, ap, out, seen);
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
        if (try w.refPath(op)) |r| try w.useAt(r.local, r.path, tok, except);
    }

    fn useAt(w: *Walker, l: u32, path: u32, tok: u32, except: []const u32) Allocator.Error!void {
        if (l >= w.local_frame.len or w.local_frame[l] != w.frame) return;
        try w.uses.append(w.a, .{ .local = l, .path = path, .except = except, .point = w.point, .frame = w.frame, .ctx = w.ctx, .token = tok });
    }

    /// Record, at the current point, a use of everything a closure value
    /// in `av` captured (§6.1 item 1): a temporary closure consumed by a call.
    fn useCaptures(w: *Walker, av: AV, tok: u32) Allocator.Error!void {
        for (av) |e| {
            const c = w.cells.items[e.cell];
            if (c.kind != .closure) continue;
            for (w.closures.items[c.a].captures) |cap| {
                if (cap.local >= w.local_frame.len or w.local_frame[cap.local] != w.frame) continue;
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

    fn escape(w: *Walker, av: AV, at: u32) Allocator.Error!void {
        for (try w.expand(av)) |e| {
            const k = w.cells.items[e.cell].kind;
            if (k == .closure or k == .func) continue;
            try w.escaped.append(w.a, .{ e.cell, at });
        }
    }

    fn isEscaped(w: *Walker, c: u32) Allocator.Error!bool {
        for (w.escaped.items) |x| if ((try w.covers(x[0], c)) != null) return true;
        return false;
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

    fn termTarget(w: *const Walker, t: Dispatch.Term) ?Target {
        switch (t) {
            .top => |x| return .{ .m = w.m, .d = x.decl.int() },
            .ext => |x| {
                const m2 = x.module.int();
                if (m2 >= w.o.in.provenance.len) return null;
                const d = w.o.in.provenance[m2].valueDecl(@backingInt(x.value)) orelse return null;
                return .{ .m = m2, .d = d.int() };
            },
            else => return null,
        }
    }

    fn methodTarget(w: *const Walker, inst: Inst.Index) ?Target {
        if (w.m >= w.o.in.dispatch.len) return null;
        const dt = &w.o.in.dispatch[w.m];
        const site = dt.siteOf(inst) orelse return null;
        const ci = site.callee.unwrap() orelse return null;
        return w.termTarget(dt.term(ci));
    }

    fn targetName(w: *const Walker, t: Target) []const u8 {
        const b = w.o.in.birs[t.m];
        return w.o.in.interner.slice(b.symbol(b.decls[t.d].name));
    }

    fn qualified(w: *Walker, t: Target) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(w.o.out.allocator(), "{s}.{s}", .{ w.o.in.module_names[t.m], w.targetName(t) });
    }

    fn isCore(w: *const Walker, t: Target, module: []const u8) bool {
        return w.o.in.packages[t.m] == .core and std.mem.eql(u8, w.o.in.module_names[t.m], module);
    }

    /// The named writers of §3.1, whose call-site demands keep their
    /// slice-1 operation, `List.<name>`.
    fn writerName(w: *const Walker, t: Target) ?[]const u8 {
        if (!w.isCore(t, "List")) return null;
        const name = w.targetName(t);
        const writers = [_][]const u8{ "set", "update", "push", "pop", "swap", "insertAt", "removeAt", "cons", "append" };
        for (writers) |x| if (std.mem.eql(u8, x, name)) return x;
        return null;
    }

    /// A `foreign` whose rung is `impure` or `suspends` (§6.1 item 2). A
    /// `foreign pure` promises it changes and keeps nothing, so it is a
    /// conservative call: it can only return what it was given.
    fn escapes(w: *const Walker, t: Target) bool {
        const d = w.o.in.birs[t.m].decls[t.d];
        return d.kind == .foreign_value and d.rung != .pure;
    }

    fn isSpreadCall(w: *const Walker, inst: Inst.Index) bool {
        if (w.bir.instTag(inst) != .call) return false;
        const tags = w.o.in.spans[w.m].tags;
        const tok = w.token(inst);
        if (tok >= tags.len or tags[tok] != .ellipsis) return false;
        const t = w.valueTarget(@fromBackingInt(@intCast(w.bir.instData(inst).lhs))) orelse return false;
        if (!w.isCore(t, "List")) return false;
        const name = w.targetName(t);
        return std.mem.eql(u8, name, "cons") or std.mem.eql(u8, name, "append");
    }

    fn isSpreadAppend(w: *const Walker, inst: Inst.Index) bool {
        const t = w.valueTarget(@fromBackingInt(@intCast(w.bir.instData(inst).lhs))) orelse return false;
        return std.mem.eql(u8, w.targetName(t), "append");
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
                // A function: a value with no cell of its own, which carries
                // its summary to where it is called (§16.5).
                if (decl.params > 0) return w.single(.{ .kind = .func, .a = t.m, .b = t.d });
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
                const out = try w.unionOf(parts);
                try w.sight(out, .{ .pending = "it is stored in a tuple" }, w.token(inst));
                return out;
            },
            .list => {
                const items = b.extraSlice(Bir.inlineRange(data), Inst.Index);
                const avs = try w.evalOperands(items, false);
                w.popPending(avs.len);
                try w.consume(items, w.token(inst));
                var parts = try w.a.alloc(AV, avs.len + 1);
                parts[0] = try w.single(.{ .kind = .site, .a = inst.int(), .ty = w.instTypeOpt(inst) });
                for (avs, 0..) |av, i| parts[i + 1] = try w.shift(av, .{ .kind = .elem, .arg = 0 });
                const out = try w.unionOf(parts);
                try w.sight(out, .{ .pending = "it is stored in a list" }, w.token(inst));
                return out;
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
                const out = try w.unionOf(parts);
                try w.sight(out, .{ .pending = "it is stored in a record" }, w.token(inst));
                return out;
            },
            .record_update => return w.evalRecordUpdate(inst),
            .call => return w.evalCall(inst),
            .method_call => return w.evalMethod(inst),
            .type_dispatch => {
                const md = b.extraData(@fromBackingInt(@intCast(data.rhs)), Bir.TypeDispatch);
                const args = b.extraSlice(.{ .start = md.args_start, .end = md.args_end }, Inst.Index);
                return w.conservative(inst, args, &.{}, null, "");
            },
            .lambda => {
                const params = b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.lhs))), Inst.Index);
                return w.closure(params, @fromBackingInt(@intCast(data.rhs)), null);
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
                return w.conservative(inst, values.items, &.{}, null, "");
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
        if (!bound and w.early[l] == 1) w.early[l] = 2;
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
            const k = w.cells.items[e.cell].kind;
            if (e.path == eps and k != .top and k != .site and k != .closure and k != .func) {
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
            try w.sight(shifted, .{ .pending = "it is stored in a record" }, w.token(inst));
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

    /// A lambda or local function: its body walked as a frame of its own,
    /// and its class read off it (§16.5).
    fn closure(w: *Walker, params: []const Inst.Index, body: Inst.Index, ci_in: ?u32) Allocator.Error!AV {
        const saved_frame = w.frame;
        const saved_ctx = w.ctx;
        const id: u32 = @intCast(w.frames.items.len);
        try w.frames.append(w.a, .{ .parent = saved_frame, .pending_base = w.pending.items.len });
        const ci: u32 = ci_in orelse blk: {
            try w.closures.append(w.a, .{ .captures = &.{} });
            break :blk @intCast(w.closures.items.len - 1);
        };
        w.closures.items[ci].params = params;
        w.closures.items[ci].frame = id;
        for (params, 0..) |p, k| {
            const at = p.int() -% w.decl.inst_start.int();
            if (at < w.pat_closure.len) w.pat_closure[at] = .{ ci, @intCast(k) };
        }
        w.frame = id;
        const escapes_from = w.escaped.items.len;
        for (params) |p| try w.bindParam(p, 1);
        const result = try w.eval(body);
        try w.consume(&.{body}, w.token(body));
        try w.sight(result, .{ .pending = "it is returned by a function value" }, w.token(body));
        // Captures of locals of this frame only: an inner capture of an
        // outer-outer local was recorded in the frames between.
        var caps: std.ArrayList(Capture) = .empty;
        for (w.frames.items[id].captures.items) |cap| {
            if (cap.local < w.local_frame.len and w.local_frame[cap.local] == id and w.local_av[cap.local] != null) continue;
            try caps.append(w.a, cap);
        }
        w.closures.items[ci].captures = try caps.toOwnedSlice(w.a);
        var env_escapes: std.ArrayList(Capture) = .empty;
        for (w.escaped.items[escapes_from..]) |x| {
            const c = w.cells.items[x[0]];
            if (c.kind != .env or c.a >= w.local_frame.len) continue;
            if (w.local_av[c.a] != null and w.local_frame[c.a] == id) continue;
            try env_escapes.append(w.a, .{ .local = c.a, .path = c.path });
        }
        w.closures.items[ci].env_escapes = try env_escapes.toOwnedSlice(w.a);
        const cls = try w.a.create(Summary);
        cls.* = try w.readOffFrame(id, params, result);
        w.closures.items[ci].class = cls;
        w.frame = saved_frame;
        w.ctx = saved_ctx;
        return w.single(.{ .kind = .closure, .a = ci });
    }

    fn evalLet(w: *Walker, inst: Inst.Index) Allocator.Error!AV {
        const b = w.bir;
        const data = b.instData(inst);
        const items = b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.lhs))), Inst.Index);
        // Local functions first: their closures exist from the block's
        // entry (thesis §3.6, *Local functions*), and their captures are
        // looked up when needed, so a later local is found. One named
        // before its class exists — by itself or by a sibling walked first
        // — was called out of the walk's sight (§16.5).
        var group: std.ArrayList([2]u32) = .empty;
        for (items) |item| {
            if (b.instTag(item) != .let_def) continue;
            const ld = b.extraData(@fromBackingInt(@intCast(b.instData(item).lhs)), Bir.LetDef);
            if (ld.params_start == ld.params_end) continue;
            try w.closures.append(w.a, .{ .captures = &.{} });
            const ci: u32 = @intCast(w.closures.items.len - 1);
            try group.append(w.a, .{ ld.local, ci });
            if (ld.local < w.early.len) w.early[ld.local] = 1;
        }
        var gi: usize = 0;
        for (items) |item| {
            if (b.instTag(item) != .let_def) continue;
            const ld = b.extraData(@fromBackingInt(@intCast(b.instData(item).lhs)), Bir.LetDef);
            if (ld.params_start == ld.params_end) continue;
            const params = b.extraSlice(.{ .start = ld.params_start, .end = ld.params_end }, Inst.Index);
            const av = try w.closure(params, @fromBackingInt(@intCast(b.instData(item).rhs)), group.items[gi][1]);
            w.bindLocal(ld.local, av);
            gi += 1;
        }
        for (group.items) |g| {
            const used_early = g[0] < w.early.len and w.early[g[0]] == 2;
            if (g[0] < w.early.len) w.early[g[0]] = 0;
            if (!used_early) continue;
            const c = &w.closures.items[g[1]];
            if (c.class) |cls| if (cls.writesAny()) {
                try c.consumed.append(w.a, .{ .kind = .pending, .why = "a local function named before its summary is known (it calls itself, or a sibling calls it first)" });
            };
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

    // ---- calls (§6, §16.4) -----------------------------------------------

    fn evalCall(w: *Walker, inst: Inst.Index) Allocator.Error!AV {
        const b = w.bir;
        const data = b.instData(inst);
        const callee: Inst.Index = @fromBackingInt(@intCast(data.lhs));
        const args = w.callArgs(inst);
        if (w.isSpreadCall(inst)) return w.construction(inst);
        if (w.isListAppend(inst)) return w.appendChain(inst);
        switch (b.instTag(callee)) {
            .ctor, .ext_ctor => {
                const c = try w.ctorOf(callee);
                const avs = try w.evalOperands(args, false);
                w.popPending(avs.len);
                try w.consume(args, w.token(inst));
                var parts = try w.a.alloc(AV, avs.len);
                for (avs, 0..) |av, i| parts[i] = try w.shift(av, .{ .kind = .ctor, .arg = c *% 64 +% @as(u32, @intCast(i)) });
                const out = try w.unionOf(parts);
                try w.sight(out, .{ .pending = "it is stored in a constructor" }, w.token(inst));
                return out;
            },
            else => {},
        }
        if (w.valueTarget(callee)) |t| {
            try w.evidenceSight(callee);
            try w.evidenceSight(inst);
            return w.callTarget(inst, t, args);
        }
        // A function value: its classes, when the walk knows where it came
        // from (§16.5); else a conservative call that reads its captures.
        const f = try w.eval(callee);
        try w.pushPending(f, callee, true);
        defer w.popPending(1);
        // A call of a function parameter of the declaration (§16.4 item 4).
        if (w.fnParamOf(f)) |j| {
            if (w.frame == 0) return w.callbackCall(inst, j, args, callee);
            w.fn_state[j].seen = false;
        }
        const classes = try w.classesOf(f);
        if (classes.len == 1) {
            switch (classes[0]) {
                .closure => |ci| if (w.closures.items[ci].class) |cls| {
                    try w.closures.items[ci].consumed.append(w.a, .{ .kind = .local });
                    try w.escapeCaptures(ci, w.point);
                    return w.applySummary(inst, .{ .sum = cls, .name = "<lambda>", .op = "call <lambda>", .closure = ci }, args, f, callee);
                },
                .func => |t| if (try w.o.ensureSummary(t.m, t.d)) |s| {
                    return w.applySummary(inst, .{ .sum = s, .name = try w.qualified(t), .op = try w.callOp(t), .merge_fresh = w.o.isComputing(t.m, t.d) }, args, f, callee);
                },
            }
        }
        try w.sight(f, .{ .pending = "it is called where the checker does not know which function runs" }, w.token(inst));
        return w.conservative(inst, args, f, callee, "");
    }

    fn callOp(w: *Walker, t: Target) Allocator.Error![]const u8 {
        if (w.writerName(t)) |n| return std.fmt.allocPrint(w.o.out.allocator(), "List.{s}", .{n});
        return std.fmt.allocPrint(w.o.out.allocator(), "call {s}", .{try w.qualified(t)});
    }

    /// A call of a top-level value (§16.4), or §6.1 when it has no summary.
    fn callTarget(w: *Walker, inst: Inst.Index, t: Target, args: []const Inst.Index) Allocator.Error!AV {
        if (try w.o.ensureSummary(t.m, t.d)) |s| {
            return w.applySummary(inst, .{ .sum = s, .name = try w.qualified(t), .op = try w.callOp(t), .merge_fresh = w.o.isComputing(t.m, t.d) }, args, &.{}, null);
        }
        if (w.escapes(t)) return w.escapeCall(inst, args, try w.qualified(t));
        return w.conservative(inst, args, &.{}, null, try w.qualified(t));
    }

    fn evalMethod(w: *Walker, inst: Inst.Index) Allocator.Error!AV {
        const b = w.bir;
        const data = b.instData(inst);
        const mc = b.extraData(@fromBackingInt(@intCast(data.rhs)), Bir.MethodCall);
        const rest = b.extraSlice(.{ .start = mc.args_start, .end = mc.args_end }, Inst.Index);
        const all = try w.a.alloc(Inst.Index, rest.len + 1);
        all[0] = @fromBackingInt(@intCast(data.lhs));
        @memcpy(all[1..], rest);
        try w.evidenceSight(inst);
        if (w.methodTarget(inst)) |t| return w.callTarget(inst, t, all);
        return w.conservative(inst, all, &.{}, null, "");
    }

    /// Where a function the dispatch table passes as evidence writes a
    /// parameter: its calls are not seen (§16.5).
    fn evidenceSight(w: *Walker, inst: Inst.Index) Allocator.Error!void {
        if (w.m >= w.o.in.dispatch.len) return;
        const dt = &w.o.in.dispatch[w.m];
        const site = dt.siteOf(inst) orelse return;
        for (dt.argsAt(site.evidence)) |ti| try w.evidenceTerm(dt, ti, w.token(inst), 0);
    }

    fn evidenceTerm(w: *Walker, dt: *const Dispatch, ti: Dispatch.TermIndex, tok: u32, depth: u32) Allocator.Error!void {
        if (depth > 8) return;
        const t = dt.term(ti);
        if (w.termTarget(t)) |target| {
            if (try w.o.ensureSummary(target.m, target.d)) |s| if (s.writesAny()) {
                try w.valueLine(tok, try w.qualified(target), .pending, "it is passed as evidence, whose calls the checker does not see", "", false);
            };
        }
        for (dt.argsOfTerm(ti)) |x| try w.evidenceTerm(dt, x, tok, depth + 1);
    }

    /// The function parameter of the declaration an abstract value is,
    /// when it is exactly one.
    fn fnParamOf(w: *Walker, av: AV) ?u32 {
        if (av.len != 1 or av[0].path != eps) return null;
        var c = w.cells.items[av[0].cell];
        if (c.kind == .env) {
            const held = w.local_av[c.a] orelse return null;
            if (held.len != 1 or held[0].path != eps or c.path != eps) return null;
            c = w.cells.items[held[0].cell];
        }
        if (c.kind != .param or c.b != 0 or c.path != eps) return null;
        for (w.params, 0..) |p, i| if (p.int() == c.a and w.fn_state[i].is_fn) return @intCast(i);
        return null;
    }

    const Class = union(enum) { closure: u32, func: Target };

    /// The classes a function value may have: the lambdas, local functions
    /// and top-level functions it may be (§16.5). Empty when any part of it
    /// is something else.
    fn classesOf(w: *Walker, av: AV) Allocator.Error![]const Class {
        var out: std.ArrayList(Class) = .empty;
        for (av) |e| {
            if (e.path != eps) return &.{};
            const c = w.cells.items[e.cell];
            switch (c.kind) {
                .closure => try out.append(w.a, .{ .closure = c.a }),
                .func => try out.append(w.a, .{ .func = .{ .m = c.a, .d = c.b } }),
                .env => {
                    const held = w.local_av[c.a] orelse return &.{};
                    if (c.path != eps) return &.{};
                    for (held) |h| {
                        if (h.path != eps) return &.{};
                        const hc = w.cells.items[h.cell];
                        switch (hc.kind) {
                            .closure => try out.append(w.a, .{ .closure = hc.a }),
                            .func => try out.append(w.a, .{ .func = .{ .m = hc.a, .d = hc.b } }),
                            else => return &.{},
                        }
                    }
                },
                else => return &.{},
            }
        }
        return out.items;
    }

    /// §6.1.
    fn conservative(w: *Walker, inst: Inst.Index, args: []const Inst.Index, callee_av: AV, callee: ?Inst.Index, name: []const u8) Allocator.Error!AV {
        const avs = try w.evalOperands(args, true);
        w.popPending(avs.len);
        w.point += 1;
        const tok = w.token(inst);
        for (args) |x| try w.useOperand(x, tok, &.{});
        if (callee) |c| try w.useOperand(c, tok, &.{});
        try w.useTemporaries(args, avs, tok);
        if (callee) |c| try w.useTemporaries(&.{c}, &.{callee_av}, tok);
        for (avs) |av| try w.sight(av, if (name.len > 0) .{ .no_summary = name } else .{ .pending = "it is passed where the checker cannot see its calls" }, tok);
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
                if (c.kind == .closure or c.kind == .func) continue;
                if (ty) |r| if (c.ty.unwrap()) |ct| if (!try w.o.mayHold(w.store, r, ct, 0)) continue;
                try out.append(w.a, .{ .path = any, .cell = e.cell, .approx = inst.int() + 1 });
            }
        }
        return w.norm(out.items);
    }

    /// A `foreign` or `Js` call: its arguments escape, its result is ⊤
    /// (§6.1 item 2).
    fn escapeCall(w: *Walker, inst: Inst.Index, args: []const Inst.Index, name: []const u8) Allocator.Error!AV {
        const avs = try w.evalOperands(args, false);
        w.popPending(avs.len);
        try w.consume(args, w.token(inst));
        try w.useTemporaries(args, avs, w.token(inst));
        for (avs) |av| {
            try w.sight(av, .{ .no_summary = name }, w.token(inst));
            try w.escape(av, w.point);
        }
        if (!try w.isTracked(inst)) return &.{};
        return w.single(.{ .kind = .top, .a = 0 });
    }

    /// A call of the declaration's own function parameter `j` (§16.4 item
    /// 4): each argument is a supply, owned when it passes the four
    /// conditions at the call, and the result is that parameter's result.
    fn callbackCall(w: *Walker, inst: Inst.Index, j: u32, args: []const Inst.Index, callee: Inst.Index) Allocator.Error!AV {
        const avs = try w.evalOperands(args, true);
        w.popPending(avs.len);
        w.point += 1;
        const tok = w.token(inst);
        for (args) |x| try w.useOperand(x, tok, &.{});
        try w.useOperand(callee, tok, &.{});
        try w.useTemporaries(args, avs, tok);
        for (avs) |av| try w.sight(av, .{ .pending = "it is passed to a function parameter, whose class is not known here" }, tok);
        const st = &w.fn_state[j];
        st.calls = if (w.recursive or st.calls != .zero) .many else .once;
        for (avs, 0..) |av, k| {
            if (av.len == 0) continue;
            var others: std.ArrayList(AV) = .empty;
            for (avs, 0..) |x, i| if (i != k) try others.append(w.a, x);
            const probe = try w.probeDemand(inst, av, others.items);
            try w.supplies.append(w.a, .{ .fun = j, .k = @intCast(k), .path = eps, .av = av, .probe = probe });
        }
        if (!try w.isTracked(inst)) return &.{};
        return w.single(.{ .kind = .cbres, .a = j, .b = inst.int(), .ty = w.instTypeOpt(inst) });
    }

    /// Whether `s` reads, keeps, returns or writes its parameter `i` at a
    /// path overlapping `q`.
    fn touches(w: *const Walker, s: *const Summary, i: u32, q: u32) bool {
        for (s.uses) |u| {
            if (u.param != i or u.bits == 0) continue;
            if (w.o.overlap(u.path, q)) return true;
        }
        return false;
    }

    /// §16.4: a call whose callee has a summary.
    fn applySummary(w: *Walker, inst: Inst.Index, callee: Callee, args: []const Inst.Index, callee_av: AV, callee_inst: ?Inst.Index) Allocator.Error!AV {
        const s = callee.sum;
        const avs = try w.a.alloc(AV, args.len);
        for (args, avs, 0..) |arg, *v, i| {
            v.* = try w.eval(arg);
            const is_ref = (try w.refPath(arg)) != null;
            try w.pending.append(w.a, .{ .av = v.*, .frame = w.frame, .token = w.token(arg), .is_ref = is_ref, .by_call = true, .consumer = s, .arg = @intCast(i) });
        }
        w.popPending(args.len);
        w.point += 1;
        const tok = w.token(inst);
        // 1. Uses, at the paths the callee touches.
        for (args, avs, 0..) |arg, av, i| {
            const pi: u32 = @intCast(i);
            if (try w.refPath(arg)) |r| {
                for (s.uses) |u| {
                    if (u.param != pi or u.bits == 0) continue;
                    try w.useAt(r.local, try w.o.concat(r.path, u.path), tok, &.{});
                }
            } else if (w.touches(s, pi, eps)) {
                try w.useCaptures(av, tok);
            }
        }
        if (callee_inst) |c| {
            try w.useOperand(c, tok, &.{});
            try w.useTemporaries(&.{c}, &.{callee_av}, tok);
        }
        // 2. What the callbacks escape, before the callee writes (§16.4 item 4).
        for (s.funs) |f| {
            if (f.param >= args.len) continue;
            try w.callbackEscapes(inst, s, f.param, avs);
        }
        // 3. W: the caller's side of a written parameter.
        for (s.uses) |u| {
            if (u.bits & bit_w == 0 or u.param >= args.len) continue;
            // A named writer's line keeps its slice-1 form; any other call
            // names the summary that wrote.
            const note = if (s.asserted or std.mem.startsWith(u8, callee.op, "List.")) "" else try std.fmt.allocPrint(w.o.out.allocator(), "{s} writes π{d}{s}", .{ callee.name, u.param + 1, try w.o.pathText(u.path) });
            try w.callSiteDemand(inst, callee.op, args, avs, u.param, u.path, note, if (s.limit != .none) .limit else if (u.bits & bit_x == 0) .approx else .exact);
        }
        // 4. E, and what the summary keeps of a function value.
        for (s.uses) |u| {
            if (u.bits & bit_e == 0 or u.param >= args.len) continue;
            const at = try w.projPath(avs[u.param], u.path, null);
            try w.sight(at, .{ .pending = try std.fmt.allocPrint(w.o.out.allocator(), "{s} keeps it", .{callee.name}) }, tok);
            try w.escape(at, w.point);
        }
        // Callbacks.
        for (s.funs) |f| {
            if (f.param >= args.len) continue;
            try w.checkCallback(inst, callee, args, avs, f.param);
        }
        // 5. The result.
        const ty = w.instType(inst);
        if (ty) |v| if (!try w.o.tracked(w.store, v, 0)) return &.{};
        const arg_types = try w.a.alloc(?Var, args.len);
        for (args, arg_types) |arg, *t| t.* = w.instType(arg);
        const res = try w.instRes(s, .{ .inst = inst, .s = s, .avs = avs, .closure = callee.closure, .depth = 0, .merge_fresh = callee.merge_fresh, .arg_types = arg_types, .result_ty = ty });
        // An identity promise names an argument the result's type cannot
        // be (§6.1's type filter, thesis §3.8): `List.map xs String.fromInt`
        // is never `xs`.
        const rt = ty orelse return res;
        var kept: std.ArrayList(Entry) = .empty;
        for (res) |e| {
            if (e.path == eps and e.approx != 0) {
                if (w.cells.items[e.cell].ty.unwrap()) |ct| if (!try w.o.mayShare(w.store, rt, ct, 0)) continue;
            }
            try kept.append(w.a, e);
        }
        return kept.items;
    }

    /// The cells the callbacks handed to this call escape (§16.4 item 4),
    /// joined to Esc just before the call's point, so that a write the
    /// callee makes after calling them sees the escape.
    fn callbackEscapes(w: *Walker, inst: Inst.Index, s: *const Summary, j: u32, avs: []const AV) Allocator.Error!void {
        const classes = try w.classesOf(avs[j]);
        for (classes) |cls| {
            const c = (try w.classSummary(cls)) orelse continue;
            for (c.uses) |u| {
                if (u.bits & bit_e == 0) continue;
                for (s.supply) |e| {
                    if (e.fun != j or e.k != u.param or !w.o.overlap(e.path, u.path)) continue;
                    const cells = try w.instProv(e.prov, .{ .inst = inst, .s = s, .avs = avs, .depth = 1 });
                    try w.escape(cells, w.point - 1);
                }
            }
            if (cls == .closure) try w.escapeCaptures(cls.closure, w.point - 1);
        }
    }

    /// What a lambda escaped of the cells it captured, joined to Esc where
    /// the lambda runs.
    fn escapeCaptures(w: *Walker, ci: u32, at: u32) Allocator.Error!void {
        for (w.closures.items[ci].env_escapes) |cap| {
            const held = w.local_av[cap.local] orelse continue;
            try w.escape(try w.projPath(held, cap.path, null), at);
        }
    }

    fn classSummary(w: *Walker, cls: Class) Allocator.Error!?*const Summary {
        return switch (cls) {
            .closure => |ci| w.closures.items[ci].class,
            .func => |t| w.o.ensureSummary(t.m, t.d),
        };
    }

    const InstCtx = struct {
        inst: Inst.Index,
        s: *const Summary,
        avs: []const AV,
        /// A lambda's class: its closure, whose captures `◇` names.
        closure: u32 = none,
        depth: u32,
        /// A callback's result being instantiated, and what it stands for
        /// so far: a fold hands its callback its own previous result.
        self_j: u32 = none,
        self_av: AV = &.{},
        /// The callee is in the recursive group being solved: its fresh
        /// cells are one cell per call, so the numbering stays finite.
        merge_fresh: bool = false,
        /// At the call itself: the arguments' types and the result's.
        arg_types: []const ?Var = &.{},
        result_ty: ?Var = null,
    };

    /// `s.res` instantiated at the call (§16.4 item 6).
    fn instRes(w: *Walker, s: *const Summary, ctx: InstCtx) Allocator.Error!AV {
        var out: std.ArrayList(Entry) = .empty;
        for (s.res, 0..) |r, i| {
            var several = false;
            for (s.res, 0..) |x, j| if (j != i and x.path == r.path) {
                several = true;
            };
            // An identity promise names an argument the result's type
            // cannot be (§16.4 item 6): `List.map xs String.fromInt` is
            // never `xs`, whatever `xs`'s cells are.
            if ((several or r.approx) and r.path == eps and r.prov.kind == .param and r.prov.path == eps and r.prov.a < ctx.arg_types.len) {
                if (ctx.result_ty) |rt| if (ctx.arg_types[r.prov.a]) |at| if (!try w.o.mayShare(w.store, rt, at, 0)) continue;
            }
            var av = try w.under(try w.instProv(r.prov, ctx), r.path);
            if (several or r.approx) av = try w.approxAll(av, ctx.inst);
            try out.appendSlice(w.a, av);
        }
        return w.norm(out.items);
    }

    fn instProv(w: *Walker, p: Prov, ctx: InstCtx) Allocator.Error!AV {
        switch (p.kind) {
            .param => {
                if (p.a >= ctx.avs.len) return &.{};
                return w.projPath(ctx.avs[p.a], p.path, null);
            },
            .fresh, .esc => {
                const base_k = if (ctx.merge_fresh) 1 else p.a;
                const k = if (ctx.depth == 0) base_k else base_k + 1000 * ctx.depth;
                const ty: Var.Optional = if (ctx.depth == 0) w.instTypeOpt(ctx.inst) else .none;
                const av = try w.single(.{ .kind = .result, .a = ctx.inst.int(), .b = @max(k, 1), .ty = ty });
                if (p.kind == .esc) try w.escape(av, w.point);
                return av;
            },
            .shared => return w.single(.{ .kind = .shared, .a = p.a, .b = p.b, .path = p.path }),
            .top => return w.single(.{ .kind = .top, .a = if (ctx.s.limit != .none or p.a == 1) 1 else 0 }),
            .env => {
                if (ctx.closure == none) return w.single(.{ .kind = .top, .a = 0 });
                const held = w.local_av[p.a] orelse return &.{};
                return w.projPath(held, p.path, null);
            },
            .cb => {
                if (p.a >= ctx.avs.len) return w.single(.{ .kind = .top, .a = 0 });
                const whole = if (p.a == ctx.self_j) ctx.self_av else if (ctx.depth >= inst_depth) try w.single(.{ .kind = .top, .a = 0 }) else try w.instCb(p.a, ctx);
                return w.projPath(whole, p.path, null);
            },
        }
    }

    /// What the actual for function parameter `j` returns when the callee
    /// calls it (§16.4 item 6). A callee may hand the callback its own
    /// earlier result (a fold's accumulator), so this is a least fixpoint,
    /// iterated from nothing; one that does not settle adds `⊤`.
    fn instCb(w: *Walker, j: u32, ctx: InstCtx) Allocator.Error!AV {
        const actual = ctx.avs[j];
        if (w.fnParamOf(actual)) |jj| {
            if (w.frame == 0) return w.single(.{ .kind = .cbres, .a = jj, .b = ctx.inst.int() });
        }
        const classes = try w.classesOf(actual);
        if (classes.len == 0) return w.unknownCb(j, ctx);
        var x: AV = &.{};
        var rounds: u32 = 0;
        while (rounds < 4) : (rounds += 1) {
            var inner = ctx;
            inner.self_j = j;
            inner.self_av = x;
            const y = try w.instCbOnce(j, classes, inner);
            const next = try w.unionOf(&.{ x, y });
            if (next.len == x.len) return x;
            x = next;
        }
        return w.unionOf(&.{ x, try w.single(.{ .kind = .top, .a = 0 }) });
    }

    fn instCbOnce(w: *Walker, j: u32, classes: []const Class, ctx: InstCtx) Allocator.Error!AV {
        var out: std.ArrayList(Entry) = .empty;
        var deeper = ctx;
        deeper.depth += 1;
        for (classes) |cls| {
            const c = (try w.classSummary(cls)) orelse return w.unknownCb(j, ctx);
            // The callback's parameters are what the callee supplies it.
            const params = try w.a.alloc(AV, c.params);
            for (params, 0..) |*pa, k| {
                var parts: std.ArrayList(AV) = .empty;
                for (ctx.s.supply) |e| {
                    if (e.fun != j or e.k != k) continue;
                    try parts.append(w.a, try w.under(try w.instProv(e.prov, deeper), e.path));
                }
                pa.* = try w.unionOf(parts.items);
            }
            const sub: InstCtx = .{ .inst = ctx.inst, .s = c, .avs = params, .closure = if (cls == .closure) cls.closure else none, .depth = ctx.depth + 1 };
            try out.appendSlice(w.a, try w.instRes(c, sub));
        }
        return w.norm(out.items);
    }

    /// A callback with no class: §6.1's conservative result over what the
    /// callee supplies it and what it holds.
    fn unknownCb(w: *Walker, j: u32, ctx: InstCtx) Allocator.Error!AV {
        var out: std.ArrayList(Entry) = .empty;
        const fresh = try w.cell(.{ .kind = .result, .a = ctx.inst.int(), .b = 0 });
        try out.append(w.a, .{ .path = eps, .cell = fresh });
        const any = try w.o.child(eps, .any, 0);
        var from: std.ArrayList(AV) = .empty;
        for (ctx.s.supply) |e| {
            if (e.fun != j) continue;
            try from.append(w.a, try w.instProv(e.prov, .{ .inst = ctx.inst, .s = ctx.s, .avs = ctx.avs, .closure = ctx.closure, .depth = ctx.depth + 1 }));
        }
        try from.append(w.a, ctx.avs[j]);
        for (from.items) |av| for (try w.expand(av)) |e| {
            const c = w.cells.items[e.cell];
            if (c.kind == .closure or c.kind == .func) continue;
            try out.append(w.a, .{ .path = any, .cell = e.cell, .approx = ctx.inst.int() + 1 });
        };
        return w.norm(out.items);
    }

    /// A call-site demand (§16.4 item 3): argument `i`'s cells at `q`,
    /// Disjoint against every other argument and every other path of `i`.
    fn callSiteDemand(w: *Walker, inst: Inst.Index, op: []const u8, args: []const Inst.Index, avs: []const AV, i: u32, q: u32, note: []const u8, origin: Origin) Allocator.Error!void {
        const base = try w.projPath(avs[i], q, null);
        var others: std.ArrayList(AV) = .empty;
        for (avs, 0..) |av, x| if (x != i) try others.append(w.a, av);
        var rest: std.ArrayList(Entry) = .empty;
        for (avs[i]) |e| if (!w.o.overlap(e.path, q)) try rest.append(w.a, e);
        try others.append(w.a, rest.items);
        const arena = w.o.out.allocator();
        const text = try w.baseText(args[i]);
        const base_text = if (q == eps) text else try std.fmt.allocPrint(arena, "{s}{s}", .{ text, try w.o.pathText(q) });
        const ref = try w.refPath(args[i]);
        try w.demandOn(.{
            .kind = .callsite,
            .token = w.token(inst),
            .op = op,
            .base_text = base_text,
            .base_ref = if (ref) |r| .{ .local = r.local, .path = try w.o.concat(r.path, q) } else null,
            .base_ty = if (q == eps) w.instType(args[i]) else null,
            .base = base,
            .others = others.items,
            .note = note,
            .origin = origin,
        });
    }

    /// A probe (§16.4 item 4): whether `av`'s cells pass the four conditions
    /// at this point; resolved with the demands, printed by none.
    fn probeDemand(w: *Walker, inst: Inst.Index, av: AV, others: []const AV) Allocator.Error!u32 {
        const idx: u32 = @intCast(w.probe_ok.items.len);
        try w.probe_ok.append(w.a, false);
        var base: std.ArrayList(Entry) = .empty;
        for (try w.expand(av)) |e| {
            const k = w.cells.items[e.cell].kind;
            if (k == .closure or k == .func) continue;
            try base.append(w.a, .{ .path = eps, .cell = e.cell, .approx = e.approx });
        }
        try w.demandOn(.{
            .kind = .probe,
            .token = w.token(inst),
            .op = "",
            .base_text = "",
            .base_ref = null,
            .base_ty = null,
            .base = base.items,
            .others = others,
            .probe = idx,
        });
        return idx;
    }

    /// A function value's line (§16.5, §16.11).
    fn valueLine(w: *Walker, tok: u32, name: []const u8, verdict: Verdict, detail: []const u8, note: []const u8, assumed: bool) Allocator.Error!void {
        try w.demands.append(w.a, .{
            .kind = .value,
            .token = tok,
            .op = "value",
            .base = name,
            .base_local = none,
            .base_path = eps,
            .point = w.point,
            .frame = w.frame,
            .ctx = w.ctx,
            .element = false,
            .accept = .callback_param,
            .holders = &.{},
            .fixed = .{ .verdict = verdict, .detail = detail, .assumed = assumed },
            .note = note,
        });
    }

    fn firstUnseen(w: *Walker, t: Target) Allocator.Error!bool {
        const gop = try w.unseen_funcs.getOrPut(w.a, (@as(u64, t.m) << 32) | t.d);
        return !gop.found_existing;
    }

    const Sight = union(enum) {
        /// The value leaves the walk's sight (§16.5).
        pending: []const u8,
        /// It is handed to a callee with no summary (§15 decision 2).
        no_summary: []const u8,
    };

    /// Every writing function value in `av` that goes where the walk cannot
    /// see its calls, and every function parameter that does (§16.5).
    fn sight(w: *Walker, av: AV, why: Sight, tok: u32) Allocator.Error!void {
        try w.sightAt(av, why, tok, 0);
    }

    fn sightAt(w: *Walker, av: AV, why: Sight, tok: u32, depth: u32) Allocator.Error!void {
        if (depth > 2) return;
        for (av) |e| {
            const c = w.cells.items[e.cell];
            switch (c.kind) {
                .closure => {
                    const cl = &w.closures.items[c.a];
                    const cls = cl.class orelse continue;
                    if (!cls.writesAny()) continue;
                    try cl.consumed.append(w.a, switch (why) {
                        .pending => |t| .{ .kind = .pending, .why = t },
                        .no_summary => |n| .{ .kind = .no_summary, .name = n },
                    });
                },
                .func => {
                    const t: Target = .{ .m = c.a, .d = c.b };
                    const s = (try w.o.ensureSummary(t.m, t.d)) orelse continue;
                    if (!s.writesAny()) continue;
                    switch (why) {
                        .pending => |t2| if (try w.firstUnseen(t)) try w.valueLine(tok, try w.qualified(t), .pending, t2, "", false),
                        .no_summary => |n| try w.valueLine(tok, try w.qualified(t), .{ .accepted = .callback_param }, "", try std.fmt.allocPrint(w.o.out.allocator(), "no summary: {s}", .{n}), true),
                    }
                },
                .param => {
                    if (c.b != 0 or c.path != eps) continue;
                    for (w.params, 0..) |p, i| if (p.int() == c.a and w.fn_state[i].is_fn) {
                        w.fn_state[i].seen = false;
                    };
                },
                .env => {
                    const held = w.local_av[c.a] orelse continue;
                    try w.sightAt(try w.projPath(held, c.path, null), why, tok, depth + 1);
                },
                else => {},
            }
        }
    }

    /// The actual for function parameter `j` of a callee with a summary,
    /// checked against what the callee supplies it (§16.4 item 4).
    fn checkCallback(w: *Walker, inst: Inst.Index, callee: Callee, args: []const Inst.Index, avs: []const AV, j: u32) Allocator.Error!void {
        const s = callee.sum;
        const ff = s.funOf(j) orelse return;
        const actual = avs[j];
        const tok = w.token(inst);
        const arena = w.o.out.allocator();
        // The caller's own function parameter, passed on.
        if (w.fnParamOf(actual)) |jj| {
            if (w.frame != 0) {
                w.fn_state[jj].seen = false;
                return;
            }
            const st = &w.fn_state[jj];
            st.calls = @fromBackingInt(@min(2, @as(u8, @backingInt(st.calls)) + @as(u8, @backingInt(ff.calls))));
            if (w.recursive and ff.calls != .zero) st.calls = .many;
            st.need = st.need or ff.need;
            st.seen = st.seen and ff.seen;
            for (s.supply) |e| {
                if (e.fun != j) continue;
                const cells = try w.instProv(e.prov, .{ .inst = inst, .s = s, .avs = avs, .depth = 0 });
                // Disjoint against every argument but the function and the
                // one the supplied cells come from.
                const from: u32 = if (e.prov.kind == .param) e.prov.a else none;
                var others: std.ArrayList(AV) = .empty;
                for (avs, 0..) |x, i| if (i != j and i != from) try others.append(w.a, x);
                const probe = if (e.owned and cells.len > 0) try w.probeDemand(inst, cells, others.items) else none;
                try w.supplies.append(w.a, .{ .fun = jj, .k = e.k, .path = e.path, .av = cells, .probe = probe, .owned = e.owned });
            }
            return;
        }
        const classes = try w.classesOf(actual);
        for (classes) |cls| {
            const c = (try w.classSummary(cls)) orelse continue;
            const name: []const u8 = switch (cls) {
                .closure => "<lambda>",
                .func => |t| try w.qualified(t),
            };
            const writes = c.writesAny();
            if (!ff.seen) {
                if (writes) switch (cls) {
                    .closure => |ci| try w.closures.items[ci].consumed.append(w.a, .{ .kind = .pending, .why = try std.fmt.allocPrint(arena, "{s} loses sight of what calls it", .{callee.name}) }),
                    .func => try w.valueLine(tok, name, .pending, try std.fmt.allocPrint(arena, "{s} loses sight of what calls it", .{callee.name}), "", false),
                };
                continue;
            }
            // The supply edge, per parameter of the callback.
            const bad = try w.a.alloc(?[]const u8, c.params);
            @memset(bad, null);
            const bad_approx = try w.a.alloc(bool, c.params);
            @memset(bad_approx, false);
            for (c.uses) |u| {
                if (u.bits & bit_w == 0 or u.param >= c.params) continue;
                for (s.supply) |e| {
                    if (e.fun != j or e.k != u.param or !w.o.overlap(e.path, u.path)) continue;
                    // The path the callback writes, within what the supply holds.
                    const written = (try w.o.suffix(e.path, u.path)) orelse eps;
                    const owned = e.owned and try w.provOwned(e.prov, s, avs, none, 0, written);
                    if (!owned) {
                        if (bad[u.param] == null) {
                            bad[u.param] = if (e.prov.kind == .cb and e.owned)
                                try std.fmt.allocPrint(arena, "{s} hands its parameter {d} what the callback returned before, which may be a list the callback does not own", .{ callee.name, u.param + 1 })
                            else
                                try std.fmt.allocPrint(arena, "{s} supplies its parameter {d} borrowed ({s})", .{ callee.name, u.param + 1, try w.o.provText(e.prov) });
                            // An element's borrowed supply is the checker's
                            // limit (§16.8); a parameter's or a callback's
                            // result is what the text shows.
                            bad_approx[u.param] = w.o.hasStep(e.prov.path, .elem) or w.o.hasStep(e.prov.path, .any);
                        }
                        continue;
                    }
                    // An owned supply of the callee's own parameter: the
                    // caller's argument is written, at the call.
                    if (e.prov.kind == .param and e.prov.a < args.len) {
                        var path = e.prov.path;
                        if (try w.o.suffix(e.path, u.path)) |rest| path = try w.o.concat(path, rest);
                        const note = try std.fmt.allocPrint(arena, "{s} writes what {s} supplies it", .{ name, callee.name });
                        try w.callSiteDemand(inst, callee.op, args, avs, e.prov.a, path, note, if (s.limit != .none or c.limit != .none) .limit else if (u.bits & bit_x == 0) .approx else .exact);
                    }
                }
            }
            // The callee edits what the callback returns (§16.2's need).
            var need_bad = false;
            if (ff.need and !try w.returnsOwned(c, s, avs, j, 0, none)) need_bad = true;
            switch (cls) {
                .closure => |ci| {
                    try w.closures.items[ci].consumed.append(w.a, .{ .kind = .supply, .bad = bad, .bad_approx = bad_approx, .name = callee.name });
                    if (need_bad) try w.valueLine(tok, name, .{ .rejected = .need }, try std.fmt.allocPrint(arena, "{s} edits what it returns, which may be a list it does not own", .{callee.name}), "", false);
                },
                .func => {
                    if (need_bad) {
                        try w.valueLine(tok, name, .{ .rejected = .need }, try std.fmt.allocPrint(arena, "{s} edits what it returns, which may be a list it does not own", .{callee.name}), "", false);
                    } else if (writes) {
                        var first: ?usize = null;
                        for (bad, 0..) |x, k| if (x != null and first == null) {
                            first = k;
                        };
                        if (first) |k| {
                            try w.demands.append(w.a, .{
                                .kind = .value,
                                .token = tok,
                                .op = "value",
                                .base = name,
                                .base_local = none,
                                .base_path = eps,
                                .point = w.point,
                                .frame = w.frame,
                                .ctx = w.ctx,
                                .element = false,
                                .accept = .callback_param,
                                .holders = &.{},
                                .fixed = .{ .verdict = .{ .rejected = .supply }, .detail = bad[k].? },
                                .prelim = .{ .cause = .supply, .detail = bad[k].?, .approx = bad_approx[k] },
                            });
                        } else {
                            try w.valueLine(tok, name, .{ .accepted = .callback_param }, "", try std.fmt.allocPrint(arena, "{s} supplies it owned", .{callee.name}), false);
                        }
                    }
                },
            }
        }
    }

    /// Whether a supply of provenance `p` is owned once its guard is
    /// decided: a `cb_j′` supply needs the actual for πⱼ′ to return owned,
    /// except while that is the guard being established (`guard`).
    fn provOwned(w: *Walker, p: Prov, s: *const Summary, avs: []const AV, guard: u32, depth: u32, written: u32) Allocator.Error!bool {
        if (p.kind != .cb) return true;
        if (p.a == guard) return true;
        if (depth >= inst_depth or p.a >= avs.len) return false;
        const classes = try w.classesOf(avs[p.a]);
        if (classes.len == 0) return false;
        for (classes) |cls| {
            const c = (try w.classSummary(cls)) orelse return false;
            if (!try w.returnsOwned(c, s, avs, p.a, depth + 1, written)) return false;
        }
        return true;
    }

    /// §16.4 item 5: whether class `c`, called by `s` as its parameter `j`,
    /// returns owned.
    /// Only the result paths `written` is under matter: the cell a write
    /// changes is the array at `written`, not the elements below it (`none`:
    /// every path).
    fn returnsOwned(w: *Walker, c: *const Summary, s: *const Summary, avs: []const AV, j: u32, depth: u32, written: u32) Allocator.Error!bool {
        if (c.limit != .none) return false;
        for (c.res, 0..) |r, i| {
            if (written != none and !w.o.isPrefix(r.path, written)) continue;
            switch (r.prov.kind) {
                .fresh => {},
                .param => {
                    for (c.uses) |u| if (u.param == r.prov.a and u.bits & bit_e != 0 and w.o.overlap(u.path, r.prov.path)) return false;
                    for (s.supply) |e| {
                        if (e.fun != j or e.k != r.prov.a or !w.o.overlap(e.path, r.prov.path)) continue;
                        if (!e.owned) return false;
                        if (!try w.provOwned(e.prov, s, avs, j, depth, none)) return false;
                    }
                },
                else => return false,
            }
            // One provenance at two distinct result paths is not owned.
            for (c.res[i + 1 ..]) |x| {
                if (written != none and !w.o.isPrefix(x.path, written)) continue;
                if (x.path != r.path and x.prov.eql(r.prov)) return false;
            }
        }
        return true;
    }

    const Item = struct { inst: Inst.Index, spread: bool };

    /// A list literal with a spread, read back as one construction (§3.2).
    fn construction(w: *Walker, top: Inst.Index) Allocator.Error!AV {
        var items: std.ArrayList(Item) = .empty;
        var cur = top;
        while (true) {
            const args = w.callArgs(cur);
            try items.append(w.a, .{ .inst = args[0], .spread = w.isSpreadAppend(cur) });
            const next = args[1];
            if (w.isSpreadCall(next) and w.balanced(w.token(cur), w.token(next))) {
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
        for (items, avs) |it, av| {
            if (it.spread) continue;
            try w.sight(av, .{ .pending = "it is stored in a list" }, w.token(top));
        }
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
        const ref = try w.refPath(items[bi].inst);
        try w.demandOn(.{
            .kind = .report,
            .token = w.token(top),
            .op = op,
            .base_text = try w.baseText(items[bi].inst),
            .base_ref = ref,
            .base_ty = w.instType(items[bi].inst),
            .base = avs[bi],
            .others = others,
        });
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

    /// The entries of a list value at its elements, re-rooted.
    fn elementsOf(w: *Walker, av: AV) Allocator.Error!AV {
        return w.proj(av, .{ .kind = .elem, .arg = 0 }, null);
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
            .param, .result, .env, .shared, .cbres => {},
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
                if (found == null or hit.approx < found.?.approx) found = hit;
            }
        }
        return found;
    }

    const DemandSpec = struct {
        kind: DemandKind,
        token: u32,
        op: []const u8,
        base_text: []const u8,
        base_ref: ?Capture,
        base_ty: ?Var,
        base: AV,
        others: []const AV,
        note: []const u8 = "",
        probe: u32 = none,
        origin: Origin = .exact,
    };

    fn demandOn(w: *Walker, spec: DemandSpec) Allocator.Error!void {
        const out = w.o.out.allocator();
        // The base's cells: at ε, and every `⋆` entry that may be the base.
        var cells: std.ArrayList(Entry) = .empty;
        const any = try w.o.child(eps, .any, 0);
        for (spec.base) |e| {
            const k = w.cells.items[e.cell].kind;
            if (k == .closure or k == .func) continue;
            if (e.path == eps) {
                try cells.append(w.a, e);
                continue;
            }
            if (e.path != any) continue;
            const c = w.cells.items[e.cell];
            if (spec.base_ty) |bt| if (c.ty.unwrap()) |ct| if (!try w.o.mayShare(w.store, bt, ct, 0)) continue;
            try cells.append(w.a, e);
        }
        var rec: DemandRec = .{
            .kind = spec.kind,
            .token = spec.token,
            .op = spec.op,
            .base = spec.base_text,
            .base_local = if (spec.base_ref) |r| r.local else none,
            .base_path = if (spec.base_ref) |r| r.path else eps,
            .point = w.point,
            .frame = w.frame,
            .ctx = w.ctx,
            .element = false,
            .accept = .fresh,
            .holders = &.{},
            .cells = cells.items,
            .note = spec.note,
            .probe = spec.probe,
            .origin = spec.origin,
        };
        // A probe on nothing passes: nothing is supplied.
        // Known, Unescaped, Captured, in that order across the cells.
        var worst: ?Cause = null;
        var worst_detail: []const u8 = "";
        for (cells.items) |e| {
            const c = w.cells.items[e.cell];
            if (w.o.hasStep(c.path, .elem)) rec.element = true;
            const rank: Accept = switch (c.kind) {
                .param => if (c.b == 1) .callback_param else .param,
                .result, .cbres => .call,
                else => .fresh,
            };
            if (@backingInt(rank) > @backingInt(rec.accept)) rec.accept = rank;
            if (c.kind == .result and c.b == 0 and rec.assumed.len == 0) rec.assumed = try w.callName(@fromBackingInt(c.a));
            var cause: ?Cause = null;
            var detail: []const u8 = "";
            switch (c.kind) {
                .top => if (c.a == 1) {
                    cause = .limit;
                    detail = "it came from a callee whose summary is past the checker's limits";
                } else {
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
                else => {},
            }
            for (w.escaped.items) |x| {
                if (x[1] >= w.point) continue;
                if ((try w.covers(x[0], e.cell)) == null) continue;
                if (cause == null or @backingInt(Cause.escaped) < @backingInt(cause.?)) {
                    cause = .escaped;
                    detail = "it was given to JavaScript, or kept by a callee";
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
        for (spec.others) |av| {
            const hit = (try w.reaches(av, cells.items)) orelse continue;
            if (hit.approx != 0) {
                if (approx_hit == 0 or hit.approx < approx_hit) approx_hit = hit.approx;
                continue;
            }
            rec.prelim = .{ .cause = .disjoint, .detail = "another operand of the same operation reaches it" };
            try w.demands.append(w.a, rec);
            return;
        }
        if (approx_hit != 0) {
            const cp = w.pos(w.token(@fromBackingInt(@intCast(approx_hit - 1))));
            rec.prelim = .{ .cause = .call, .detail = try std.fmt.allocPrint(out, "another operand may be it, through the call at {d}:{d}", .{ cp.line, cp.col }) };
            try w.demands.append(w.a, rec);
            return;
        }
        // A temporary already evaluated for an enclosing consumer holds it.
        const base_pending = w.frames.items[w.frame].pending_base;
        for (w.pending.items[base_pending..]) |p| {
            if (p.frame != w.frame or p.is_ref) continue;
            const phit = (try w.reaches(p.av, cells.items)) orelse continue;
            // Waiting for a call with a summary, it holds the cell only
            // where that call touches it (§16.4 item 2).
            if (p.consumer) |s| if (!w.touches(s, p.arg, phit.path)) continue;
            const ppos = w.pos(p.token);
            // Held for a call with no summary, the temporary is a holder only
            // because the call is assumed to read it (§6.1): a limit.
            rec.prelim = if (phit.approx != 0 or (p.by_call and p.consumer == null))
                .{ .cause = .call, .detail = try std.fmt.allocPrint(out, "the argument at {d}:{d}, evaluated before it, holds it, and the call it waits for may read it", .{ ppos.line, ppos.col }) }
            else
                .{ .cause = .held_operand, .detail = try std.fmt.allocPrint(out, "the value at {d}:{d}, evaluated before it, holds it until its consumer runs", .{ ppos.line, ppos.col }) };
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

    /// The callee of the call at `inst`, as written.
    fn callName(w: *Walker, inst: Inst.Index) Allocator.Error![]const u8 {
        const tag = w.bir.instTag(inst);
        if (tag == .call) {
            const callee: Inst.Index = @fromBackingInt(@intCast(w.bir.instData(inst).lhs));
            if (w.valueTarget(callee)) |t| return w.qualified(t);
            return "a function value";
        }
        if (tag == .method_call) {
            if (w.methodTarget(inst)) |t| return w.qualified(t);
            return "a method";
        }
        return "an operation";
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
            .lambda => return "<lambda>",
            .record, .record_update => return "<record>",
            .tuple => return "<tuple>",
            .call => {
                if (w.isSpreadCall(inst)) return "<construction>";
                if (w.isListAppend(inst)) return "<++>";
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

    /// The closure and position of a lambda's parameter cell.
    fn lambdaParam(w: *const Walker, c: Cell) ?[2]u32 {
        if (c.kind != .param or c.b != 1) return null;
        const at = c.a -% w.decl.inst_start.int();
        if (at >= w.pat_closure.len or w.pat_closure[at][0] == none) return null;
        return w.pat_closure[at];
    }

    /// Liveness, once every use is known (§7, §8.3); and the lambdas'
    /// demands on their own parameters, once every lambda's consumers are
    /// known (§16.5).
    fn resolve(w: *Walker, out_list: *std.ArrayList(Demand)) Allocator.Error!void {
        const out = w.o.out.allocator();
        for (w.demands.items) |rec| {
            const verdict = try w.resolveOne(rec);
            if (rec.kind == .probe) {
                w.probe_ok.items[rec.probe] = verdict.verdict != .rejected and verdict.verdict != .pending;
                continue;
            }
            if (w.mode != .report) continue;
            try out_list.append(out, verdict);
        }
    }

    fn resolveOne(w: *Walker, rec: DemandRec) Allocator.Error!Demand {
        var d = try w.resolveRaw(rec);
        if (d.verdict == .rejected) switch (rec.origin) {
            .exact => {},
            // A write only a pessimistic summary claims (§16.7).
            .limit => {
                d.detail = try std.fmt.allocPrint(w.o.out.allocator(), "{s}; the callee's summary is past the checker's limits, so it is taken to write and keep its arguments", .{d.detail});
                d.verdict = .{ .rejected = .limit };
                d.approx = true;
            },
            // A write the callee makes only through an approximate step.
            .approx => if (!d.verdict.rejected.approximate()) {
                d.detail = try std.fmt.allocPrint(w.o.out.allocator(), "{s}; the callee writes it only through an approximate step", .{d.detail});
                d.verdict = .{ .rejected = .call };
                d.approx = true;
            },
        };
        return d;
    }

    fn resolveRaw(w: *Walker, rec: DemandRec) Allocator.Error!Demand {
        const out = w.o.out.allocator();
        const position = w.pos(rec.token);
        var d: Demand = .{ .position = position, .op = rec.op, .base = rec.base, .verdict = .{ .accepted = rec.accept }, .detail = "", .note = rec.note };
        if (rec.accept == .call and rec.assumed.len > 0) {
            d.assumed = true;
            d.note = try std.fmt.allocPrint(out, "no summary: {s}", .{rec.assumed});
        }
        if (rec.fixed) |f| {
            d.verdict = f.verdict;
            d.detail = f.detail;
            d.assumed = f.assumed;
            if (f.verdict == .rejected) d.approx = if (rec.prelim) |p| (p.approx orelse f.verdict.rejected.approximate()) else f.verdict.rejected.approximate();
            return d;
        }
        if (rec.prelim) |p| {
            d.verdict = .{ .rejected = p.cause };
            d.detail = p.detail;
            d.approx = p.approx orelse p.cause.approximate();
            d.assumed = false;
            return d;
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
                if (!(better_kind or (same_kind and (u.point < bst.use.point or (u.point == bst.use.point and w.holderBefore(h, bst.holder)))))) continue;
            }
            best = .{ .cause = cause, .holder = h, .use = u };
        }
        if (best) |bst| {
            const up = w.pos(bst.use.token);
            var buf: std.Io.Writer.Allocating = .init(out);
            const wr = &buf.writer;
            wr.writeAll(w.localName(bst.holder.local)) catch return error.OutOfMemory;
            if (bst.cause != .captured) w.o.writePath(wr, bst.holder.path) catch return error.OutOfMemory;
            switch (bst.cause) {
                .later_use => wr.print(" is read again at {d}:{d}", .{ up.line, up.col }) catch return error.OutOfMemory,
                .captured => wr.print(", a closure holding it, is used at {d}:{d}", .{ up.line, up.col }) catch return error.OutOfMemory,
                .call => {
                    const call_inst: Inst.Index = @fromBackingInt(@intCast(bst.holder.approx - 1));
                    const cp = w.pos(w.token(call_inst));
                    wr.print(" may hold it through the call at {d}:{d}, and is read at {d}:{d}", .{ cp.line, cp.col, up.line, up.col }) catch return error.OutOfMemory;
                },
                else => wr.print(" holds it and is read at {d}:{d}", .{ up.line, up.col }) catch return error.OutOfMemory,
            }
            d.verdict = .{ .rejected = bst.cause };
            d.detail = try buf.toOwnedSlice();
            d.approx = bst.cause.approximate();
            d.assumed = false;
            return d;
        }
        // A lambda's demand on its own parameter: what its consumers decide.
        if (rec.accept == .callback_param) try w.decideCallback(rec, &d);
        return d;
    }

    fn decideCallback(w: *Walker, rec: DemandRec, d: *Demand) Allocator.Error!void {
        const out = w.o.out.allocator();
        var lp: ?[2]u32 = null;
        for (rec.cells) |e| {
            if (w.lambdaParam(w.cells.items[e.cell])) |x| {
                lp = x;
                break;
            }
        }
        const x = lp orelse return;
        const cl = &w.closures.items[x[0]];
        // The worst consumer decides: pending, then rejected, then a callee
        // with no summary, then accepted.
        var rank: u8 = 0;
        for (cl.consumed.items) |c| switch (c.kind) {
            .pending => if (rank < 3) {
                rank = 3;
                d.verdict = .pending;
                d.detail = c.why;
                d.note = "";
                d.assumed = false;
            },
            .supply => if (rank < 2 and x[1] < c.bad.len) {
                if (c.bad[x[1]]) |why| {
                    rank = 2;
                    d.verdict = .{ .rejected = .supply };
                    d.detail = why;
                    d.approx = c.bad_approx[x[1]];
                    d.note = "";
                    d.assumed = false;
                } else if (rank == 0) {
                    d.note = try std.fmt.allocPrint(out, "{s} supplies it owned", .{c.name});
                }
            },
            .no_summary => if (rank < 1) {
                rank = 1;
                d.assumed = true;
                d.note = try std.fmt.allocPrint(out, "no summary: {s}", .{c.name});
            },
            .local => if (rank == 0 and d.note.len == 0) {
                d.note = "decided at its calls";
            },
        };
    }

    /// A tie-break between two holders read at one point that depends on the
    /// text alone — the local, then the path as written, then the call —
    /// never on an id, which other declarations' walks move.
    fn holderBefore(w: *const Walker, a: Holder, b: Holder) bool {
        if (a.local != b.local) return a.local < b.local;
        var ba: [256]u8 = undefined;
        var bb: [256]u8 = undefined;
        var wa: std.Io.Writer = .fixed(&ba);
        var wb: std.Io.Writer = .fixed(&bb);
        w.o.writePath(&wa, a.path) catch {};
        w.o.writePath(&wb, b.path) catch {};
        const o = std.mem.order(u8, wa.buffered(), wb.buffered());
        if (o != .eq) return o == .lt;
        return a.approx < b.approx;
    }

    fn useOverlaps(w: *const Walker, u: Use, path: u32) bool {
        if (u.except.len != 0 and u.path == eps) {
            const first = w.o.firstStep(path) orelse return true;
            if (first.kind == .field and std.mem.indexOfScalar(u32, u.except, first.arg) != null) return false;
            return true;
        }
        return w.o.overlap(u.path, path);
    }

    // ---- reading off (§16.3) -----------------------------------------------

    /// The declaration's summary, once the walk is resolved.
    fn readOff(w: *Walker) Allocator.Error!Summary {
        return w.readOffFrame(0, w.params, w.result_av);
    }

    /// The parameter index a cell is of, in frame `frame` whose parameters
    /// are `params`.
    fn paramIndex(_: *const Walker, c: Cell, frame: u32, params: []const Inst.Index) ?u32 {
        if (c.kind != .param) return null;
        if (frame == 0 and c.b != 0) return null;
        if (frame != 0 and c.b != 1) return null;
        for (params, 0..) |p, i| if (p.int() == c.a) return @intCast(i);
        return null;
    }

    fn readOffFrame(w: *Walker, frame: u32, params: []const Inst.Index, result: AV) Allocator.Error!Summary {
        const keep = w.o.keep.allocator();
        var uses: std.ArrayList(UseEntry) = .empty;
        // R: a use of a local whose value holds a parameter cell.
        for (w.uses.items) |u| {
            if (u.frame != frame) continue;
            const held = w.local_av[u.local] orelse continue;
            for (held) |e| {
                const c = w.cells.items[e.cell];
                const pi = w.paramIndex(c, frame, params) orelse continue;
                if (u.except.len != 0 and u.path == eps) {
                    if (w.o.firstStep(e.path)) |first| {
                        if (first.kind == .field and std.mem.indexOfScalar(u32, u.except, first.arg) != null) continue;
                    } else if (w.recordFields(w.localType(u.local))) |fields| {
                        // A record update reads every field but the ones it
                        // replaces (§5's split, §16.4 item 1).
                        for (fields) |fl| {
                            if (std.mem.indexOfScalar(u32, u.except, @backingInt(fl.name)) != null) continue;
                            if (!try w.o.tracked(w.store, fl.value, 0)) continue;
                            try uses.append(keep, .{ .param = pi, .path = try w.o.child(c.path, .field, @backingInt(fl.name)), .bits = bit_r });
                        }
                        continue;
                    }
                } else if (!w.o.overlap(e.path, u.path)) continue;
                var path = c.path;
                if (try w.o.suffix(e.path, u.path)) |rest| path = try w.o.concat(path, rest);
                try uses.append(keep, .{ .param = pi, .path = path, .bits = bit_r });
            }
        }
        // W: a demand's cells, in this frame or, through a capture, inside
        // a lambda of it.
        for (w.demands.items) |rec| {
            if (rec.kind == .probe or rec.kind == .value) continue;
            for (rec.cells) |e| {
                const c = w.cells.items[e.cell];
                if (rec.frame == frame) {
                    if (w.paramIndex(c, frame, params)) |pi| try uses.append(keep, .{ .param = pi, .path = c.path, .bits = bit_w | (if (e.approx == 0 and rec.origin == .exact) bit_x else 0) });
                }
                if (c.kind == .env and rec.frame != frame) {
                    const held = w.local_av[c.a] orelse continue;
                    if (c.a >= w.local_frame.len or w.local_frame[c.a] != frame) continue;
                    for (try w.projPath(held, c.path, null)) |h| {
                        if (h.path != eps) continue;
                        const hc = w.cells.items[h.cell];
                        if (w.paramIndex(hc, frame, params)) |pi| try uses.append(keep, .{ .param = pi, .path = hc.path, .bits = bit_w | (if (e.approx == 0 and h.approx == 0 and rec.origin == .exact) bit_x else 0) });
                    }
                }
            }
        }
        // E: a parameter cell in Esc.
        for (w.escaped.items) |x| {
            const c = w.cells.items[x[0]];
            if (w.paramIndex(c, frame, params)) |pi| try uses.append(keep, .{ .param = pi, .path = c.path, .bits = bit_e });
        }
        // A and the result.
        const expanded = try w.expand(result);
        var fresh_cells: std.ArrayList(u32) = .empty;
        for (expanded) |e| {
            const k = w.cells.items[e.cell].kind;
            if (k == .site or k == .result) {
                if (std.mem.indexOfScalar(u32, fresh_cells.items, e.cell) == null) try fresh_cells.append(w.a, e.cell);
            }
        }
        std.mem.sort(u32, fresh_cells.items, w, struct {
            fn less(ww: *Walker, x: u32, y: u32) bool {
                const cx = ww.cells.items[x];
                const cy = ww.cells.items[y];
                if (cx.a != cy.a) return cx.a < cy.a;
                if (cx.b != cy.b) return cx.b < cy.b;
                return cx.path < cy.path;
            }
        }.less);
        // A fresh number only says which result paths may hold one new
        // cell (thesis §3.7, §4.6: `k ≤ |Q|`), so cells that appear at the
        // same paths share a number; the numbering stays a function of the
        // result's shape, not of how many literals the body has.
        const renum = try w.a.alloc(u32, fresh_cells.items.len);
        var groups: std.ArrayList([]const u32) = .empty;
        for (fresh_cells.items, renum) |fc, *num| {
            var ps: std.ArrayList(u32) = .empty;
            for (expanded) |e| {
                if (e.cell != fc) continue;
                const key = e.path *% 2 +% @intFromBool(e.approx != 0);
                if (std.mem.indexOfScalar(u32, ps.items, key) == null) try ps.append(w.a, key);
            }
            std.mem.sort(u32, ps.items, {}, std.sort.asc(u32));
            const esc_bit: u32 = if (try w.isEscaped(fc)) 1 else 0;
            try ps.append(w.a, esc_bit);
            var found: ?usize = null;
            for (groups.items, 0..) |g, gi| if (std.mem.eql(u32, g, ps.items)) {
                found = gi;
                break;
            };
            const gi = found orelse blk: {
                try groups.append(w.a, ps.items);
                break :blk groups.items.len - 1;
            };
            num.* = @intCast(gi + 1);
        }
        var res: std.ArrayList(ResEntry) = .empty;
        for (expanded) |e| {
            const c = w.cells.items[e.cell];
            if (w.paramIndex(c, frame, params)) |pi| try uses.append(keep, .{ .param = pi, .path = c.path, .bits = bit_a });
            var prov = (try w.provOf(e.cell, frame, params, fresh_cells.items)) orelse continue;
            if ((prov.kind == .fresh or prov.kind == .esc) and prov.a > 0) prov.a = renum[prov.a - 1];
            try res.append(keep, .{ .path = e.path, .prov = prov, .approx = e.approx != 0 });
        }
        // Function parameters.
        var funs: std.ArrayList(FunFacts) = .empty;
        var supply: std.ArrayList(SupplyEntry) = .empty;
        if (frame == 0) {
            for (w.fn_state, 0..) |st, j| {
                if (!st.is_fn) continue;
                var need = st.need;
                for (w.demands.items) |rec| {
                    if (rec.kind == .probe or rec.kind == .value) continue;
                    for (rec.cells) |e| {
                        const c = w.cells.items[e.cell];
                        if (c.kind == .cbres and c.a == j) need = true;
                    }
                }
                try funs.append(keep, .{ .param = @intCast(j), .calls = st.calls, .need = need, .seen = st.seen });
            }
            var atoms: u32 = 0;
            for (w.supplies.items) |sr| {
                const owned_probe = sr.owned and (sr.probe == none or w.probe_ok.items[sr.probe]);
                for (try w.expand(sr.av)) |e| {
                    var prov = (try w.provOf(e.cell, frame, params, &.{})) orelse continue;
                    if (prov.kind == .fresh or prov.kind == .esc) prov.a = 0;
                    var owned = owned_probe and prov.kind != .shared and prov.kind != .top and prov.kind != .esc and prov.kind != .env;
                    if (prov.kind == .cb and owned) {
                        atoms += 1;
                        if (atoms > atom_cap) owned = false;
                    }
                    try supply.append(keep, .{ .fun = sr.fun, .k = sr.k, .path = try w.o.concat(sr.path, e.path), .prov = prov, .owned = owned });
                }
            }
        } else {
            // A lambda's own function parameters: its class does not follow
            // them (§16.5).
            for (params, 0..) |p, k| {
                const v = w.patternType(p) orelse continue;
                if (isFunc(w.store, v)) try funs.append(keep, .{ .param = @intCast(k), .calls = .many, .seen = false });
            }
        }
        return w.o.normalize(.{
            .params = @intCast(params.len),
            .uses = uses.items,
            .res = res.items,
            .supply = supply.items,
            .funs = funs.items,
        });
    }

    /// The provenance a cell is read off as (thesis §4.4).
    fn provOf(w: *Walker, cell_id: u32, frame: u32, params: []const Inst.Index, fresh: []const u32) Allocator.Error!?Prov {
        const c = w.cells.items[cell_id];
        switch (c.kind) {
            .param => {
                if (w.paramIndex(c, frame, params)) |pi| return .{ .kind = .param, .a = pi, .path = c.path };
                return .{ .kind = .top };
            },
            .site, .result => {
                const k: u32 = if (std.mem.indexOfScalar(u32, fresh, cell_id)) |i| @intCast(i + 1) else 0;
                return .{ .kind = if (try w.isEscaped(cell_id)) .esc else .fresh, .a = k };
            },
            .env => {
                if (frame == 0) return .{ .kind = .top };
                return .{ .kind = .env, .a = c.a, .path = c.path };
            },
            .shared => return .{ .kind = .shared, .a = c.a, .b = c.b, .path = c.path },
            // `a` 1: a ⊤ a pessimistic summary made (§16.7).
            .top => return .{ .kind = .top, .a = c.a },
            .cbres => {
                if (frame != 0) return .{ .kind = .top };
                return .{ .kind = .cb, .a = c.a, .path = c.path };
            },
            .closure, .func => return null,
        }
    }
};
