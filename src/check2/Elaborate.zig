//! P6, elaboration (checker-v2.md §12.2, §12.3, §13): THE one place v2
//! builds evidence trees.
//!
//! Everything it reads was recorded when it was decided, and nothing here
//! recounts it (v1's root cause #1):
//!
//!   - a `method_call`/`type_dispatch`'s callee wanted (`inst_callee`);
//!   - an instantiation's wanteds, in the callee's canonical order, as
//!     `Solve.instantiated` recorded them (`inst_evidence`, I5);
//!   - each wanted's answer, followed through `alias` chains;
//!   - each declaration's requirement list and its quantifier roots
//!     (`Resolve.close`, or an annotation's givens);
//!   - P5's rows (`Eager.zig`, which also writes their bodies through the
//!     unit builder here).
//!
//! A `promoted` answer is `(root, method)`: its index is the SITE's
//! declaration's, found in that declaration's own list (§12.3), and a
//! reference to an unannotated member of the group being checked — which
//! instantiated nothing, so it has no `inst_evidence` — is a group call,
//! whose arguments come from the callee's final list by §12.3's cases 1
//! and 3 (case 2 is R14's). Case 3 is taken only when the requirement's
//! variable is unreachable from the site's declaration's type, and a
//! `promoted` answer only inside the group that promoted it: either other
//! case is the compiler's (`internal`, §12.3).
//!
//! **What never becomes a term.** An `open` or `ready` wanted is `internal`
//! (I6), never a structural answer (v1's root cause #6) — except OPEN on a
//! P5 marker for the row's own method, which is exactly the row's context
//! entry. A `failed` wanted (or an alias chain that ends in one: R6a's
//! round-2 nit) means an error was reported: the site keeps its callee, for
//! `Cycles`, and no evidence. In a module that reported nothing that is the
//! compiler's own failure: it is returned in `Output.internals`, which the
//! module reports after the last pass that can report an error (§13.1's
//! rule for the I7 assert).
//!
//! **The table's shape.** Each site and each derived row's body is one unit
//! (`Unit.zig`): a DAG of distinct answers, written owners first. An
//! `undetermined` answer is the `undetermined` leaf only where `Lower` can
//! tell its method — below a derived ancestor whose kind IS the wanted's
//! method — and everywhere else the structural function for the wanted's
//! own method (`Basics.eq`, or `num_compare` for `compare`): v1's table,
//! except where v1 put an `eq` leaf in a `compare` slot (CK-103). `derived`
//! rows are sorted by emitted name text last, and every index is remapped
//! once.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Dispatch = @import("../check/Dispatch.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Types = @import("../check/Types.zig");
const Context = @import("Context.zig");
const Eager = @import("Eager.zig");
const Evidence = @import("Evidence.zig");
const Report = @import("Report.zig");
const Unit = @import("Unit.zig");
const Walk = @import("Walk.zig");

const Elaborate = @This();

const Var = TypeStore.Var;
const Symbol = InternPool.Symbol;
const WantedId = Evidence.WantedId;
const TermIndex = Dispatch.TermIndex;
const Ctx = Unit.Ctx;
pub const Error = Allocator.Error;

pub const Input = struct {
    cx: *const Context,
    evidence: *const Evidence,
    eager: *const Eager,
    /// The table's own `decls` and `requirements`, already written.
    decls: []const Dispatch.DeclInfo,
    requirements: []const Dispatch.Requirement,
    /// Per requirement row, its quantifier's root.
    roots: []const Var,
    /// Per declaration, its published scheme (case 3's reachability test).
    decl_scheme: []const Var.Optional,
    /// Per declaration, its top-level binding group.
    group_of: []const u32,
    report: *Report,
    /// No error was reported before P6: a refusal here is said now.
    clean: bool,
};

/// The compiler's own failure at `region`, reported by the caller once the
/// module is known to have no error (`Module.assertEvidence`).
pub const Internal = struct { region: Bir.Inst.Index, what: []const u8 };

/// What P6 writes: the table less `decls`, `requirements` and `tries`.
pub const Output = struct {
    terms: []const Dispatch.Term,
    args: []const TermIndex,
    sites: []const Dispatch.Site,
    derived: []const Dispatch.Derived,
    contexts: []const Dispatch.ContextEntry,
    symbols: []const Symbol,
    /// Owned by the scratch arena.
    internals: []const Internal,
};

/// Whose `param` a term is: the site's declaration, or a P5 row (by its
/// index before the sort).
pub const Binder = union(enum) { none, decl: u32, row: u32 };

pub const Why = enum { failed, r8a, internal };

/// A derived row being built.
pub const Row = struct {
    kind: Dispatch.Derived.Kind,
    shape: Dispatch.Shape,
    context: u32,
    body: Dispatch.Range = .empty,
    alive: bool = true,
    /// Its P5 row, for a nominal one.
    eager: u32 = no_row,
};

pub const no_row = std.math.maxInt(u32);

const OwnKey = struct { type_id: Types.TypeId, kind: Dispatch.Derived.Kind };

pub const Dep = struct { from: u32, to: u32 };

in: Input,
gpa: Allocator,
scratch: Allocator,
terms: std.ArrayList(Dispatch.Term) = .empty,
args: std.ArrayList(TermIndex) = .empty,
sites: std.ArrayList(Dispatch.Site) = .empty,
rows: std.ArrayList(Row) = .empty,
symbols: std.ArrayList(Symbol) = .empty,
own: std.AutoHashMapUnmanaged(OwnKey, u32) = .empty,
/// Structural rows by shape hash, for their deduplication.
shapes: std.AutoHashMapUnmanaged(u64, u32) = .empty,
unit: Unit = .{},
/// P5's first pass: which own rows each row's body names.
deps: std.ArrayList(Dep) = .empty,
collecting: bool = false,
internals: std.ArrayList(Internal) = .empty,
stacks: Walk.Stacks = .{},
/// Why the last unit failed.
why: Why = .failed,
what: []const u8 = "",

/// Build the table's trees. The caller owns the output's slices.
pub fn run(in: Input) Error!Output {
    var e: Elaborate = .{ .in = in, .gpa = in.cx.gpa, .scratch = in.cx.scratch };
    defer e.deinit();
    try Eager.elaborate(&e);
    try e.siteRows();
    return e.finish();
}

fn deinit(e: *Elaborate) void {
    e.terms.deinit(e.gpa);
    e.args.deinit(e.gpa);
    e.sites.deinit(e.gpa);
    e.rows.deinit(e.gpa);
    e.symbols.deinit(e.gpa);
    e.own.deinit(e.scratch);
    e.shapes.deinit(e.scratch);
    e.unit.deinit(e.scratch);
    e.deps.deinit(e.scratch);
    e.stacks.deinit(e.gpa);
}

pub fn fail(e: *Elaborate, why: Why, what: []const u8) void {
    e.why = why;
    e.what = what;
}

/// A nominal row of this module, for P5 (`Eager.elaborate`).
pub fn addOwnRow(e: *Elaborate, row: Row, type_id: Types.TypeId) Error!void {
    const index: u32 = @intCast(e.rows.items.len);
    try e.rows.append(e.gpa, row);
    try e.own.put(e.scratch, .{ .type_id = type_id, .kind = row.kind }, index);
}

pub fn addArgs(e: *Elaborate, ts: []const TermIndex) Error!Dispatch.Range {
    const start: u32 = @intCast(e.args.items.len);
    try e.args.appendSlice(e.gpa, ts);
    return .{ .start = start, .len = @intCast(ts.len) };
}

/// Defer an `internal` to after the module's last error-reporting pass.
pub fn internal(e: *Elaborate, region: Bir.Inst.Index, what: []const u8) Error!void {
    try e.internals.append(e.scratch, .{ .region = region, .what = what });
}

// ---------------------------------------------------------------------------
// Sites
// ---------------------------------------------------------------------------

const Event = struct {
    inst: Bir.Inst.Index,
    what: union(enum) { callee: WantedId, evidence: Evidence.Range, group: u32 },
    /// The declaration the instruction is in.
    binder: Binder = .none,
};

fn eventLessThan(_: void, a: Event, b: Event) bool {
    return a.inst.int() < b.inst.int();
}

fn instLessThan(_: void, a: Evidence.InstEvidence, b: Evidence.InstEvidence) bool {
    return a.inst.int() < b.inst.int();
}

fn instOrder(key: Bir.Inst.Index, item: Evidence.InstEvidence) std.math.Order {
    return std.math.order(key.int(), item.inst.int());
}

/// One site per instruction that dispatches or passes evidence, ascending.
fn siteRows(e: *Elaborate) Error!void {
    const ev = e.in.evidence;
    const bir = e.in.cx.bir;
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(e.scratch);
    for (ev.callees.items) |c| try events.append(e.scratch, .{ .inst = c.inst, .what = .{ .callee = c.wanted } });
    const rows = try e.scratch.dupe(Evidence.InstEvidence, ev.inst_evidence.items);
    defer e.scratch.free(rows);
    std.mem.sort(Evidence.InstEvidence, rows, {}, instLessThan);
    // A reference's evidence rides on the `call` that applies it, when one
    // does (§13.1 as R2a wrote it: `Lower` reads a call's site for its
    // callee's hidden arguments, a bare reference's for its own).
    var call_of: std.AutoHashMapUnmanaged(Bir.Inst.Index, Bir.Inst.Index) = .empty;
    defer call_of.deinit(e.scratch);
    for (bir.decls) |d| {
        if (!d.kind.isValue()) continue;
        var i = d.inst_start.int();
        while (i < d.inst_end.int() and i < bir.insts.len) : (i += 1) {
            const inst: Bir.Inst.Index = @enumFromInt(i);
            switch (bir.instTag(inst)) {
                .call => try call_of.put(e.scratch, @enumFromInt(bir.instData(inst).lhs), inst),
                // A reference to a value with requirements that instantiated
                // nothing: an unannotated member of the group being checked
                // (§12.3).
                .top => {
                    const target = bir.instData(inst).lhs;
                    if (target >= e.in.decls.len or e.in.decls[target].requirements.len == 0) continue;
                    if (std.sort.binarySearch(Evidence.InstEvidence, rows, inst, instOrder) != null) continue;
                    try events.append(e.scratch, .{ .inst = inst, .what = .{ .group = target } });
                },
                else => {},
            }
        }
    }
    for (rows) |r| try events.append(e.scratch, .{ .inst = r.inst, .what = .{ .evidence = r.args } });
    var owner: Owner = try .init(e.scratch, bir);
    defer owner.deinit(e.scratch);
    for (events.items) |*event| {
        event.binder = owner.of(event.inst);
        if (event.what != .callee) event.inst = call_of.get(event.inst) orelse event.inst;
    }
    std.mem.sort(Event, events.items, {}, eventLessThan);
    for (events.items, 0..) |event, i| {
        if (i > 0 and events.items[i - 1].inst == event.inst) {
            try e.internal(event.inst, "two sites on one instruction (checker-v2.md §13.1)");
            continue;
        }
        try e.site(event);
    }
}

/// The value declaration whose instructions hold an instruction.
const Owner = struct {
    order: []u32,
    bir: *const Bir,

    fn init(scratch: Allocator, bir: *const Bir) Error!Owner {
        var list: std.ArrayList(u32) = .empty;
        for (bir.decls, 0..) |d, i| {
            if (d.kind.isValue()) try list.append(scratch, @intCast(i));
        }
        const Sorter = struct {
            fn lessThan(b: *const Bir, x: u32, y: u32) bool {
                return b.decls[x].inst_start.int() < b.decls[y].inst_start.int();
            }
        };
        std.mem.sort(u32, list.items, bir, Sorter.lessThan);
        return .{ .order = list.items, .bir = bir };
    }

    fn deinit(o: *Owner, scratch: Allocator) void {
        scratch.free(o.order);
    }

    fn of(o: *const Owner, inst: Bir.Inst.Index) Binder {
        var lo: usize = 0;
        var hi: usize = o.order.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const d = o.bir.decls[o.order[mid]];
            if (inst.int() < d.inst_start.int()) {
                hi = mid;
            } else if (inst.int() >= d.inst_end.int()) {
                lo = mid + 1;
            } else return .{ .decl = o.order[mid] };
        }
        return .none;
    }
};

/// One site: its callee and roots built as ONE unit, so what they share is
/// written once. A unit that fails leaves nothing behind — no term, and no
/// structural row it made (review N1).
fn site(e: *Elaborate, event: Event) Error!void {
    const rows_len = e.rows.items.len;
    const symbols_len = e.symbols.items.len;
    e.beginUnit();
    var kept: ?Dispatch.Term = null;
    const has_callee = event.what == .callee;
    var ok = switch (event.what) {
        .callee => |id| try e.calleeNodes(id, event.binder, &kept),
        .evidence => |r| try e.wantedRoots(e.in.evidence.argsOf(r)),
        .group => |d| try e.groupNodes(d, event.binder, .none, &e.unit.roots),
    } and try e.fillUnit(event.binder);
    if (ok) {
        var terms: std.ArrayList(TermIndex) = .empty;
        defer terms.deinit(e.scratch);
        ok = try e.emitUnit(&terms);
        if (ok) {
            const first: usize = if (has_callee) 1 else 0;
            try e.sites.append(e.gpa, .{
                .inst = event.inst,
                .callee = if (has_callee) terms.items[0].toOptional() else .none,
                .evidence = try e.addArgs(terms.items[first..]),
            });
            return;
        }
    }
    e.rows.shrinkRetainingCapacity(rows_len);
    e.symbols.shrinkRetainingCapacity(symbols_len);
    switch (e.why) {
        .r8a => if (e.in.clean) try e.in.report.notImplementedR8a(event.inst),
        .failed => try e.internal(event.inst, "a wanted of this site failed, but nothing was reported (checker-v2.md §12.2)"),
        .internal => try e.internal(event.inst, e.what),
    }
    // The callee alone, for `Cycles` (`Edges.declEdges`' third leg).
    if (kept) |t| {
        const at: TermIndex = @enumFromInt(@as(u32, @intCast(e.terms.items.len)));
        try e.terms.append(e.gpa, t);
        try e.sites.append(e.gpa, .{ .inst = event.inst, .callee = at.toOptional() });
    }
}

/// A method call's callee: a value's evidence is the site's roots; any
/// other callee carries its own (§13.1).
fn calleeNodes(e: *Elaborate, callee_id: WantedId, binder: Binder, kept: *?Dispatch.Term) Error!bool {
    const ev = e.in.evidence;
    const id = e.follow(callee_id) orelse return false;
    const a = ev.answer(id);
    const value: ?Dispatch.Term = switch (a) {
        .top => |t| .{ .top = .{ .decl = @enumFromInt(t.decl) } },
        .group_call => |d| .{ .top = .{ .decl = @enumFromInt(d) } },
        .ext => |x| .{ .ext = .{ .module = x.module, .value = x.value } },
        else => null,
    };
    kept.* = value;
    if (ev.get(id).state == .failed) {
        e.fail(.failed, "");
        return false;
    }
    if (value) |t| {
        try e.unit.roots.append(e.scratch, try e.unit.leaf(e.scratch, t));
        return switch (a) {
            .top => |x| try e.wantedRoots(ev.argsOf(x.args)),
            .ext => |x| try e.wantedRoots(ev.argsOf(x.args)),
            .group_call => |d| try e.groupNodes(d, binder, .none, &e.unit.roots),
            else => unreachable,
        };
    }
    try e.unit.roots.append(e.scratch, (try e.wantedNode(id, .none)) orelse return false);
    return true;
}

fn wantedRoots(e: *Elaborate, ids: []const WantedId) Error!bool {
    for (ids) |id| try e.unit.roots.append(e.scratch, (try e.wantedNode(id, .none)) orelse return false);
    return true;
}

/// A group call's arguments (§12.3): one per requirement of the callee's
/// final list — the caller's own parameter for it (case 1), or, when the
/// caller's list does not hold it, the proven-undetermined answer (case 3).
/// Leaf nodes, appended to `out`.
fn groupNodes(e: *Elaborate, callee: u32, binder: Binder, ctx: Ctx, out: *std.ArrayList(u32)) Error!bool {
    const r = e.in.decls[callee].requirements;
    for (e.in.requirements[r.start..][0..r.len], e.in.roots[r.start..][0..r.len]) |req, q| {
        const t: Dispatch.Term = if (e.paramFor(binder, q, req.method)) |k|
            .{ .param = .{ .binder = .decl, .k = k } }
        else
            (try e.caseThree(binder, q, req.method, ctx)) orelse return false;
        try out.append(e.scratch, try e.unit.leaf(e.scratch, t));
    }
    return true;
}

/// `(q, method)`'s index in the site's declaration's list, if it has one.
fn paramFor(e: *Elaborate, binder: Binder, q: Var, method: Symbol) ?u16 {
    const d = switch (binder) {
        .decl => |d| d,
        else => return null,
    };
    const st = e.in.cx.store;
    const root = st.find(q);
    const r = e.in.decls[d].requirements;
    for (e.in.requirements[r.start..][0..r.len], e.in.roots[r.start..][0..r.len], 0..) |req, x, k| {
        if (req.method == method and st.find(x) == root) return @intCast(k);
    }
    return null;
}

/// §12.3's case 3: `q` is in no list the site's declaration has, which is
/// sound only when its type cannot reach `q` — else the lists disagree with
/// the types, and that is `internal` ("in the member's type, but not in its
/// list", review S1).
fn caseThree(e: *Elaborate, binder: Binder, q: Var, method: Symbol, ctx: Ctx) Error!?Dispatch.Term {
    if (binder == .decl) {
        const d = binder.decl;
        if (d < e.in.decl_scheme.len) if (e.in.decl_scheme[d].unwrap()) |scheme| {
            if (try Walk.reaches(e.in.cx.store, &e.stacks, e.gpa, scheme, q)) {
                e.fail(.internal, "a requirement the site's declaration's type reaches is not in its list (checker-v2.md §12.3)");
                return null;
            }
        };
    }
    return e.undetermined(method, ctx);
}

/// The proven-undetermined answer for `method`: the `undetermined` leaf
/// where `Lower` will read the right method off the nearest derived
/// ancestor (`ctx` is that method), the structural function itself
/// everywhere else (B1, CK-103); a method that is not well known has none.
fn undetermined(e: *Elaborate, method: Symbol, ctx: Ctx) ?Dispatch.Term {
    const is_eq = method == InternPool.WellKnown.eq.symbol();
    if (!is_eq and method != InternPool.WellKnown.compare.symbol()) {
        e.fail(.internal, "a requirement no scheme reaches is not `eq` or `compare`, so nothing answers it (checker-v2.md §12.3, case 3)");
        return null;
    }
    if (ctx == (if (is_eq) Ctx.eq else Ctx.compare)) return .undetermined;
    if (!is_eq) return .{ .primitive = .num_compare };
    const cx = e.in.cx;
    const basics = cx.graph.lookup(.core, InternPool.WellKnown.Basics.symbol()) orelse {
        e.fail(.internal, "`Basics` is not in the graph, so nothing answers a structural `eq`");
        return null;
    };
    const value = cx.iface(basics).findValue(cx.interner, InternPool.WellKnown.eq.symbol()) orelse {
        e.fail(.internal, "`Basics` exports no `eq`, so nothing answers a structural `eq`");
        return null;
    };
    return .{ .ext = .{ .module = basics, .value = value } };
}

// ---------------------------------------------------------------------------
// One unit (`Unit.zig`): its answers
// ---------------------------------------------------------------------------

pub fn beginUnit(e: *Elaborate) void {
    e.unit.begin();
    e.fail(.failed, "");
}

/// `id` through its `alias` chain; a chain longer than the wanteds is a
/// cycle, which the resolver never makes (`internal`).
fn follow(e: *Elaborate, start: WantedId) ?WantedId {
    const ev = e.in.evidence;
    var id = start;
    var n: usize = 0;
    while (ev.answer(id) == .alias) : (n += 1) {
        if (n > ev.wanteds.items.len) {
            e.fail(.internal, "an `alias` chain of wanteds is a cycle (checker-v2.md §12.2)");
            return null;
        }
        id = ev.answer(id).alias;
    }
    return id;
}

/// The node for wanted `start` (through its aliases) in context `ctx`.
pub fn wantedNode(e: *Elaborate, start: WantedId, ctx: Ctx) Error!?u32 {
    const id = e.follow(start) orelse return null;
    return try e.unit.wanted(e.scratch, .{ .wanted = id, .ctx = ctx });
}

/// Answer every queued node.
pub fn fillUnit(e: *Elaborate, binder: Binder) Error!bool {
    while (e.unit.pending.pop()) |p| {
        const t = (try e.termOf(p.key.wanted, binder, p.key.ctx, p.node)) orelse return false;
        e.unit.nodes.items[p.node].term = t;
    }
    return true;
}

pub fn emitUnit(e: *Elaborate, out: *std.ArrayList(TermIndex)) Error!bool {
    if (try e.unit.emit(e.gpa, e.scratch, &e.terms, &e.args, out)) return true;
    e.fail(.internal, "the evidence of this site refers back to itself (checker-v2.md §13.1)");
    return false;
}

/// The nodes of `ids` in context `ctx`, as a run of the unit's arguments.
fn children(e: *Elaborate, ids: []const WantedId, ctx: Ctx) Error!?Dispatch.Range {
    const nodes = try e.scratch.alloc(u32, ids.len);
    defer e.scratch.free(nodes);
    for (ids, nodes) |id, *n| n.* = (try e.wantedNode(id, ctx)) orelse return null;
    return try e.unit.addArgs(e.scratch, nodes);
}

/// The term one wanted's answer is, its arguments nodes of the unit (their
/// indices are written by `Unit.emit`). `node` is the wanted's own node and
/// `ctx` its context.
fn termOf(e: *Elaborate, id: WantedId, binder: Binder, ctx: Ctx, node: u32) Error!?Dispatch.Term {
    const ev = e.in.evidence;
    const w = ev.get(id);
    switch (w.state) {
        .failed => return e.failTerm(.failed, ""),
        .open, .ready => return Eager.marker(e, id, binder),
        .answered, .promoted, .defaulted => {},
    }
    return switch (ev.answer(id)) {
        .none, .alias => e.failTerm(.internal, "a wanted was answered with nothing (checker-v2.md §12.2, I6)"),
        .param => |p| switch (binder) {
            .decl => |d| if (d == p.decl)
                .{ .param = .{ .binder = .decl, .k = @intCast(p.k) } }
            else
                e.failTerm(.internal, "a `where` clause's evidence is used outside its declaration (checker-v2.md §12.2)"),
            else => e.failTerm(.internal, "a `where` clause's evidence is used outside its declaration (checker-v2.md §12.2)"),
        },
        .promoted => |p| try e.promotedTerm(w, p.root, p.method, binder, ctx),
        .top => |t| try e.withArgs(node, .{ .top = .{ .decl = @enumFromInt(t.decl) } }, ev.argsOf(t.args), ctx),
        .ext => |x| try e.withArgs(node, .{ .ext = .{ .module = x.module, .value = x.value } }, ev.argsOf(x.args), ctx),
        .derived => |dv| try e.derivedTerm(id, dv, binder, node),
        .primitive => |p| .{ .primitive = p },
        .undetermined => e.undetermined(w.method, ctx),
        .field => .field,
        .group_call => |d| blk: {
            var leaves: std.ArrayList(u32) = .empty;
            defer leaves.deinit(e.scratch);
            if (!try e.groupNodes(d, binder, ctx, &leaves)) break :blk null;
            const range = try e.unit.addArgs(e.scratch, leaves.items);
            e.unit.nodes.items[node].args = range;
            break :blk .{ .top = .{ .decl = @enumFromInt(d) } };
        },
    };
}

/// A promoted requirement at this site: the site's declaration's own
/// parameter, which exists only inside the group that promoted it; else
/// §12.3's case 3.
fn promotedTerm(e: *Elaborate, w: Evidence.Wanted, root: Var, method: Symbol, binder: Binder, ctx: Ctx) Error!?Dispatch.Term {
    if (binder == .decl and w.decl != Evidence.Wanted.no_decl) {
        const g = e.in.group_of;
        if (binder.decl < g.len and w.decl < g.len and g[binder.decl] != g[w.decl]) {
            return e.failTerm(.internal, "a promoted requirement is used outside the group that promoted it (checker-v2.md §12.3)");
        }
    }
    if (e.paramFor(binder, root, method)) |k| return .{ .param = .{ .binder = .decl, .k = k } };
    return e.caseThree(binder, root, method, ctx);
}

/// `t` with the nodes of `ids` as its arguments, in context `ctx`.
fn withArgs(e: *Elaborate, node: u32, t: Dispatch.Term, ids: []const WantedId, ctx: Ctx) Error!?Dispatch.Term {
    // Made before the store: `children` grows `nodes`.
    const range = (try e.children(ids, ctx)) orelse return null;
    e.unit.nodes.items[node].args = range;
    return t;
}

pub fn failTerm(e: *Elaborate, why: Why, what: []const u8) ?Dispatch.Term {
    e.fail(why, what);
    return null;
}

/// A derived answer: this module's row (P5's for a nominal type, one
/// shared by shape for a structural one) or another module's. Its
/// arguments are inside it: their context is its kind.
fn derivedTerm(e: *Elaborate, id: WantedId, dv: @FieldType(Evidence.Answer, "derived"), binder: Binder, node: u32) Error!?Dispatch.Term {
    const ev = e.in.evidence;
    const cx = e.in.cx;
    const w = ev.get(id);
    const kind: Dispatch.Derived.Kind = if (w.method == InternPool.WellKnown.eq.symbol()) .eq else .compare;
    const inner = Ctx.of(kind);
    const subs = ev.argsOf(dv.args);
    if (dv.type_id != .none) {
        const entry = cx.types.entry(dv.type_id);
        if (entry.module != cx.module) {
            return e.withArgs(node, .{ .ext_derived = .{ .module = entry.module, .type = dv.type_id, .kind = kind } }, subs, inner);
        }
        const index = e.own.get(.{ .type_id = dv.type_id, .kind = kind }) orelse return e.failTerm(.r8a, "");
        if (e.collecting) {
            // P5's first pass: which rows a body names, alive or not yet.
            if (binder == .row) try e.deps.append(e.scratch, .{ .from = binder.row, .to = index });
        } else if (!e.rows.items[index].alive) return e.failTerm(.r8a, "");
        if (e.rows.items[index].context != subs.len) return e.failTerm(.internal, "a derived answer's arguments are not its row's context (checker-v2.md §13.1, I7)");
        return e.withArgs(node, .{ .derived = .{ .index = index } }, subs, inner);
    }
    const shape = (try e.shapeOf(w.receiver, subs.len)) orelse return null;
    const index = try e.structural(kind, shape, @intCast(subs.len));
    return e.withArgs(node, .{ .derived = .{ .index = index } }, subs, inner);
}

/// A structural receiver's shape key (§9.2): the fields by name text, the
/// arity, or `()`. Its positions must be the answer's.
fn shapeOf(e: *Elaborate, receiver: Var, n: usize) Error!?Dispatch.Shape {
    const cx = e.in.cx;
    const st = cx.store;
    _, const content = st.resolved(receiver);
    const flat = switch (content) {
        .structure => |f| f,
        else => return e.failShape(),
    };
    switch (flat) {
        .unit => return if (n == 0) .unit else e.failShape(),
        .tuple => {
            const arity = Walk.positions(st, receiver).len;
            return if (arity == n and arity <= std.math.maxInt(u8)) .{ .tuple = @intCast(arity) } else e.failShape();
        },
        .record, .empty_record => {
            var row: std.ArrayList(TypeStore.Field) = .empty;
            defer row.deinit(e.scratch);
            var concatenated = false;
            if (flat == .record) _ = try Walk.recordRow(st, flat.record, &row, e.scratch, &concatenated);
            if (row.items.len != n) return e.failShape();
            std.mem.sort(TypeStore.Field, row.items, cx.interner, fieldTextLess);
            const start: u32 = @intCast(e.symbols.items.len);
            for (row.items) |f| try e.symbols.append(e.gpa, f.name);
            return .{ .record = .{ .start = start, .len = @intCast(n) } };
        },
        else => return e.failShape(),
    }
}

fn failShape(e: *Elaborate) ?Dispatch.Shape {
    e.fail(.internal, "a structural derived answer's receiver is not the shape it was answered for (checker-v2.md §13.1)");
    return null;
}

fn fieldTextLess(interner: *const InternPool.Global, a: TypeStore.Field, b: TypeStore.Field) bool {
    return std.mem.lessThan(u8, interner.slice(a.name), interner.slice(b.name));
}

/// The row for `(kind, shape)`, made when it is new: deduplicated on the
/// shape alone (A.11, A.46), by a hash of the shape and a comparison. A
/// record shape's names were just appended; a row that already has them
/// gives them back. A hash entry left by a row a failed unit took back is
/// stale, and replaced.
fn structural(e: *Elaborate, kind: Dispatch.Derived.Kind, shape: Dispatch.Shape, n: u32) Error!u32 {
    const h = e.shapeHash(kind, shape);
    const entry = try e.shapes.getOrPut(e.scratch, h);
    if (entry.found_existing and entry.value_ptr.* < e.rows.items.len) {
        const i = entry.value_ptr.*;
        const r = e.rows.items[i];
        if (r.eager == no_row and r.kind == kind and e.sameShape(r.shape, shape)) {
            if (shape == .record) e.symbols.shrinkRetainingCapacity(shape.record.start);
            return i;
        }
        // A collision: the rows are few, so a scan settles it.
        for (e.rows.items, 0..) |other, j| {
            if (other.eager != no_row or other.kind != kind or !e.sameShape(other.shape, shape)) continue;
            if (shape == .record) e.symbols.shrinkRetainingCapacity(shape.record.start);
            return @intCast(j);
        }
    }
    const index: u32 = @intCast(e.rows.items.len);
    try e.rows.append(e.gpa, .{ .kind = kind, .shape = shape, .context = n });
    if (!entry.found_existing or entry.value_ptr.* >= index) entry.value_ptr.* = index;
    return index;
}

fn shapeHash(e: *const Elaborate, kind: Dispatch.Derived.Kind, shape: Dispatch.Shape) u64 {
    var h: std.hash.Wyhash = .init(@intFromEnum(kind));
    h.update(&.{@intFromEnum(std.meta.activeTag(shape))});
    switch (shape) {
        .nominal => |t| h.update(std.mem.asBytes(&t)),
        .tuple => |n| h.update(&.{n}),
        .unit => {},
        .record => |r| h.update(std.mem.sliceAsBytes(e.symbols.items[r.start..][0..r.len])),
    }
    return h.final();
}

fn sameShape(e: *const Elaborate, a: Dispatch.Shape, b: Dispatch.Shape) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .nominal => |t| t == b.nominal,
        .tuple => |n| n == b.tuple,
        .unit => true,
        .record => |r| std.mem.eql(Symbol, e.symbols.items[r.start..][0..r.len], e.symbols.items[b.record.start..][0..b.record.len]),
    };
}

// ---------------------------------------------------------------------------
// The sort (§8.5 of the spike, A.29)
// ---------------------------------------------------------------------------

fn finish(e: *Elaborate) Error!Output {
    const gpa = e.gpa;
    // The live rows, by emitted name text.
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(e.scratch);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(e.scratch);
    for (e.rows.items, 0..) |r, i| {
        try names.append(e.scratch, if (r.alive) try e.nameOf(r) else "");
        if (r.alive) try order.append(e.scratch, @intCast(i));
    }
    const Sorter = struct {
        names: []const []const u8,
        fn lessThan(self: @This(), x: u32, y: u32) bool {
            return switch (std.mem.order(u8, self.names[x], self.names[y])) {
                .lt => true,
                .gt => false,
                .eq => x < y,
            };
        }
    };
    std.mem.sort(u32, order.items, Sorter{ .names = names.items }, Sorter.lessThan);
    const remap = try e.scratch.alloc(u32, e.rows.items.len);
    defer e.scratch.free(remap);
    @memset(remap, no_row);
    for (order.items, 0..) |old, new| remap[old] = @intCast(new);
    for (e.terms.items) |*t| switch (t.*) {
        .derived => |*d| d.index = remap[d.index],
        .param => |*p| switch (p.binder) {
            .derived => |*i| i.* = remap[i.*],
            else => {},
        },
        else => {},
    };

    var contexts: std.ArrayList(Dispatch.ContextEntry) = .empty;
    errdefer contexts.deinit(gpa);
    const derived = try gpa.alloc(Dispatch.Derived, order.items.len);
    errdefer gpa.free(derived);
    for (order.items, derived) |old, *out| {
        const r = e.rows.items[old];
        const start: u32 = @intCast(contexts.items.len);
        const method: Symbol = if (r.kind == .eq) InternPool.WellKnown.eq.symbol() else InternPool.WellKnown.compare.symbol();
        for (0..r.context) |k| try contexts.append(gpa, .{ .param = @intCast(k), .method = method });
        out.* = .{ .kind = r.kind, .shape = r.shape, .context = .{ .start = start, .len = r.context }, .body = r.body };
    }
    const terms = try e.terms.toOwnedSlice(gpa);
    errdefer gpa.free(terms);
    const args = try e.args.toOwnedSlice(gpa);
    errdefer gpa.free(args);
    const sites = try e.sites.toOwnedSlice(gpa);
    errdefer gpa.free(sites);
    const symbols = try e.symbols.toOwnedSlice(gpa);
    errdefer gpa.free(symbols);
    return .{
        .terms = terms,
        .args = args,
        .sites = sites,
        .derived = derived,
        .contexts = try contexts.toOwnedSlice(gpa),
        .symbols = symbols,
        .internals = e.internals.items,
    };
}

/// `<Module>$<Type>$<kind>` for a nominal row — the declaring module, this
/// one — and `<Module>$<kind>$<shape>` for a structural one (v1's
/// `DerivedNamer`).
fn nameOf(e: *Elaborate, r: Row) Error![]const u8 {
    const cx = e.in.cx;
    const interner = cx.interner;
    const kind = if (r.kind == .eq) "eq" else "compare";
    const module = interner.slice(cx.graph.moduleName(cx.module));
    return switch (r.shape) {
        .nominal => |id| std.fmt.allocPrint(e.scratch, "{s}${s}${s}", .{ interner.slice(cx.graph.moduleName(cx.types.entry(id).module)), interner.slice(cx.types.entry(id).name), kind }),
        .tuple => |n| std.fmt.allocPrint(e.scratch, "{s}${s}$t{d}", .{ module, kind, n }),
        .unit => std.fmt.allocPrint(e.scratch, "{s}${s}$unit", .{ module, kind }),
        .record => |range| blk: {
            var out: std.ArrayList(u8) = .empty;
            try out.print(e.scratch, "{s}${s}$r", .{ module, kind });
            for (e.symbols.items[range.start..][0..range.len]) |name| try out.print(e.scratch, "${s}", .{interner.slice(name)});
            break :blk out.items;
        },
    };
}
