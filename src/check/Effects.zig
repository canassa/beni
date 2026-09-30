//! Effect inference: the two bits of transparent-effects-proposal.md §2,
//! carried as one point of the ladder `pure ⊏ impure ⊏ suspends` per class
//! (§14 there is the contract; checker-v2.md §26 says where it sits).
//!
//! **A class is a union-find class of the store.** Every function type is
//! one, and so is every application of a nominal type whose body holds a
//! function (§14.5); two that unify are one class, so nothing here touches
//! `unify` or the store's layout. The bits ride BESIDE unification: the
//! generator, the solver and instantiation only RECORD —
//!
//!   - `edges`: `callee ⊑ ambient` for each call (§14.3 rule 1), and the
//!     dependencies an imported summary gives a use;
//!   - `seeds`: a rung a class has for certain (a `foreign`'s, an imported
//!     summary's);
//!   - `joins` and `zips`: two classes that are one although unification
//!     never met them, variable by variable or position by position
//!     (rules 2, 4, 5 and §14.5);
//!   - `records`: which scheme variable each copied function type came from,
//!     for a reference to an own top-level declaration (rule 3), whose
//!     summary is not known until its body has been checked —
//!
//! and `run`, after P5, joins, orders the declarations by those references,
//! and solves each one's summary (§14.4) with the least fixpoint on the
//! ladder. A summary is what a use instantiates and what the interface
//! publishes (§14.6, `writeBlock`); `View` is what the dumps print (§14.7).
//!
//! Nothing here reports, and no emitted byte depends on it: the `sync` step
//! is the first reader.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Interface = @import("../resolve/Interface.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Walk = @import("Walk.zig");
const Scc = @import("Scc.zig");

const Effects = @This();

pub const Var = TypeStore.Var;
pub const Rung = Bir.Rung;
pub const Symbol = InternPool.Symbol;
pub const Error = Allocator.Error;

pub const Pair = struct { a: Var, b: Var };
pub const Seed = struct { v: Var, rung: Rung };

/// A copy of an own top-level declaration's scheme (§14.3 rule 3), or of a
/// generalised local `let` (rule 4): `pairs[start..][0..len]` are its
/// `(scheme variable, copy)` pairs, and `owner` the declaration whose body
/// the reference is in, or `no_owner` for a derived context's own frame.
pub const Record = struct { owner: u32, scheme: Var, start: u32, len: u32 };
pub const no_owner = std.math.maxInt(u32);

gpa: Allocator,
store: *TypeStore,
types: *const Types,
interner: *const InternPool.Global,
edges: std.ArrayList(Pair) = .empty,
seeds: std.ArrayList(Seed) = .empty,
joins: std.ArrayList(Pair) = .empty,
zips: std.ArrayList(Pair) = .empty,
records: std.ArrayList(Record) = .empty,
pairs: std.ArrayList(Pair) = .empty,
/// Per declaration: the evaluation class of a top-level value with no
/// parameters (§14.3 rule 1), made when its body is generated.
eval: []Var.Optional = &.{},
/// Per declaration: the store variables its annotation's two readings made,
/// the scheme's (read in P2) and the one the body is checked against. One
/// annotation read twice by one reader makes the same variables in the same
/// order, so the two are one class position by position (§14.3 rule 5)
/// without a walk of either, and the scheme's classes are the carrying
/// variables of its range.
readings: []Readings = &.{},
/// What `run` solved; empty before it.
solved: Solved = .{},

pub const Readings = struct {
    scheme_start: u32 = none,
    scheme_end: u32 = none,
    check_start: u32 = none,
    check_end: u32 = none,
};

pub fn init(gpa: Allocator, store: *TypeStore, types: *const Types, interner: *const InternPool.Global, decls: usize) Error!Effects {
    const eval = try gpa.alloc(Var.Optional, decls);
    errdefer gpa.free(eval);
    @memset(eval, .none);
    const readings = try gpa.alloc(Readings, decls);
    @memset(readings, .{});
    return .{ .gpa = gpa, .store = store, .types = types, .interner = interner, .eval = eval, .readings = readings };
}

/// The variables `[start, end)` P2 made reading `decl`'s annotation and its
/// `where` clause into the scheme.
pub fn schemeReading(e: *Effects, decl: u32, start: u32, end: u32) void {
    if (decl >= e.readings.len) return;
    e.readings[decl].scheme_start = start;
    e.readings[decl].scheme_end = end;
}

/// The variables `[start, end)` of the reading `decl`'s body is checked
/// against, made the same way, whose root is `check`, beside the scheme
/// `scheme`. Two readings of one length are paired by position; any other
/// pair (never seen: it would be a reader that read one text two ways) is
/// zipped by structure.
pub fn checkReading(e: *Effects, decl: u32, start: u32, end: u32, scheme: Var, check: Var) Error!void {
    if (decl < e.readings.len) {
        const rd = &e.readings[decl];
        if (rd.scheme_start != none and rd.scheme_end - rd.scheme_start == end - start) {
            rd.check_start = start;
            rd.check_end = end;
            return;
        }
    }
    try e.zip(scheme, check);
}

pub fn deinit(e: *Effects) void {
    const gpa = e.gpa;
    e.edges.deinit(gpa);
    e.seeds.deinit(gpa);
    e.joins.deinit(gpa);
    e.zips.deinit(gpa);
    e.records.deinit(gpa);
    e.pairs.deinit(gpa);
    gpa.free(e.eval);
    gpa.free(e.readings);
    e.solved.deinit(gpa);
    e.* = undefined;
}

// ---------------------------------------------------------------------------
// Recording (generation, solving, instantiation)
// ---------------------------------------------------------------------------

/// §14.3 rule 1: a call of `callee` from a body whose class is `ambient`.
pub fn call(e: *Effects, callee: Var, ambient: Var) Error!void {
    try e.edges.append(e.gpa, .{ .a = callee, .b = ambient });
}

pub fn join(e: *Effects, a: Var, b: Var) Error!void {
    try e.joins.append(e.gpa, .{ .a = a, .b = b });
}

/// Two readings of one type, whose classes are one position by position
/// (§14.3 rules 2 and 5).
pub fn zip(e: *Effects, a: Var, b: Var) Error!void {
    try e.zips.append(e.gpa, .{ .a = a, .b = b });
}

pub fn seed(e: *Effects, v: Var, rung: Rung) Error!void {
    if (rung == .pure) return;
    try e.seeds.append(e.gpa, .{ .v = v, .rung = rung });
}

/// The evaluation class of top-level value `decl`: a variable nothing
/// unifies, at rank `generalized` and in no pool, so no boundary sees it.
pub fn evalNode(e: *Effects, decl: u32) Error!Var {
    const v = try e.store.fresh(.{ .flex = .{} }, TypeStore.generalized);
    if (decl < e.eval.len) e.eval[decl] = v.toOptional();
    return v;
}

/// Whether root `r` carries a class: a function type, or an application of
/// a nominal type whose body holds a function (§14.5). Any other
/// application's class is one nothing can ever join, so it is not recorded.
pub fn carries(e: *const Effects, r: Var) bool {
    return switch (e.store.content(r)) {
        .structure => |s| switch (s) {
            .func => true,
            .app => |a| a.type != .none and e.types.entry(a.type).has_function,
            else => false,
        },
        else => false,
    };
}

/// A copy just made by `Instantiate.copy`: `copied` are the generalised
/// roots it copied, each with its copy in the store's `copy` memo.
pub fn recordCopy(e: *Effects, owner: u32, scheme: Var, copied: []const Var) Error!void {
    const start: u32 = @intCast(e.pairs.items.len);
    for (copied) |r| {
        if (!e.carries(r)) continue;
        const c = e.store.copy(r).unwrap() orelse continue;
        try e.pairs.append(e.gpa, .{ .a = r, .b = c });
    }
    const len: u32 = @intCast(e.pairs.items.len - start);
    if (len == 0) return;
    try e.records.append(e.gpa, .{ .owner = owner, .scheme = e.store.find(scheme), .start = start, .len = len });
}

/// §14.5: a constructor's type just built for a use, `result` the type it
/// constructs and `args` its fields. Every function type and every nominal
/// application written in the fields is joined with `result`'s class. The
/// fields' type parameters are still fresh variables here, so the walk
/// stops at the declaration's own text.
pub fn constructor(e: *Effects, result: Var, args: []const Var) Error!void {
    const store = e.store;
    const r = store.find(result);
    switch (store.content(r)) {
        .structure => |s| switch (s) {
            .app => if (!e.carries(r)) return,
            else => return,
        },
        else => return,
    }
    // An epoch colour of its own (`TypeStore.nextMark`): it runs where
    // `Instantiate.reference` builds a type, inside no other walk.
    var stack: std.ArrayList(Var) = .empty;
    defer stack.deinit(e.gpa);
    const mark = store.nextMark();
    store.setMark(r, mark);
    try stack.appendSlice(e.gpa, args);
    while (stack.pop()) |next| {
        const n = store.find(next);
        if (store.mark(n) == mark) continue;
        store.setMark(n, mark);
        if (e.carries(n)) try e.join(r, n);
        var k: u32 = 0;
        while (Walk.stepped(store, n, k)) |c| : (k += 1) try stack.append(e.gpa, c.v);
    }
}

/// An imported value's scheme just read at a use (`Instantiate.imported`):
/// its effect block applied to the variables the read made — `body` and
/// the `quantified` variables whose constraints carry its `where` types —
/// so the use gets the declaration's summary (§14.3 rule 3, §14.6).
pub fn applyImported(e: *Effects, iface: *const Interface, scheme: Interface.Scheme, body: Var, quantified: []const Var) Error!void {
    const block = iface.effectBlock(scheme) orelse return;
    const count = block.classCount();
    if (count == 0) return;
    // A handful of classes, the common case, on the stack.
    var small: [8]Var.Optional = undefined;
    const reps = if (count <= small.len) small[0..count] else try e.gpa.alloc(Var.Optional, count);
    defer if (count > small.len) e.gpa.free(reps);
    @memset(reps, .none);
    var sites = block.sites();
    while (sites.next()) |site| {
        const v = e.follow(iface, site, body, quantified) orelse continue;
        if (reps[site.class].unwrap()) |rep| {
            try e.join(rep, v);
        } else reps[site.class] = v.toOptional();
    }
    for (0..count) |c| {
        const rep = reps[c].unwrap() orelse continue;
        const class = block.class(@intCast(c));
        try e.seed(rep, @enumFromInt(@min(class.rung, 2)));
        for (class.deps) |d| {
            const from = reps[d].unwrap() orelse continue;
            try e.edges.append(e.gpa, .{ .a = from, .b = rep });
        }
    }
}

/// The variable a site's path reaches from the read's roots, or null for a
/// path this type does not have (a record from disk that lies).
fn follow(e: *Effects, iface: *const Interface, site: Interface.EffectBlock.Site, body: Var, quantified: []const Var) ?Var {
    const store = e.store;
    var at: Var = if (site.root == 0) body else whereType(store, quantified, site.root - 1) orelse return null;
    for (site.steps) |word| {
        const kind = std.enums.fromInt(Walk.StepKind, Interface.EffectBlock.stepKind(word)) orelse return null;
        var index = Interface.EffectBlock.stepIndex(word);
        if (kind == .field) {
            if (index >= iface.symbols.len) return null;
            index = @intFromEnum(iface.symbol(@enumFromInt(index)));
        }
        at = Walk.follow(store, store.find(at), kind, index) orelse return null;
    }
    return at;
}

/// The `k`th `where` type of a scheme whose quantifiers are `quantified`:
/// quantifiers in order, each one's constraints in the order the record
/// wrote them (§14.6).
fn whereType(store: *TypeStore, quantified: []const Var, k: u32) ?Var {
    var left = k;
    for (quantified) |q| {
        const set = Walk.constraints(store.flagsOf(store.find(q)));
        const n = set.count(store);
        if (left < n) return set.at(store, left).fn_var;
        left -= n;
    }
    return null;
}

/// An imported method answered on the plain-method fast path
/// (`Instances.plainImported`), which reads no scheme: its summary applied
/// by position. `method_type` is the wanted's own; `subs[q]` is quantifier
/// `q`'s sub-wanted's method type, or none.
pub fn applyPlain(e: *Effects, iface: *const Interface, scheme: Interface.Scheme, method_type: Var, subs: []const Var.Optional) Error!void {
    const block = iface.effectBlock(scheme) orelse return;
    // The method's own arrow is the site at the body's root with no step.
    var own: ?u32 = null;
    var sites = block.sites();
    while (sites.next()) |site| {
        if (site.root == 0 and site.steps.len == 0) own = site.class;
    }
    const c = own orelse return;
    const class = block.class(c);
    try e.seed(method_type, @enumFromInt(@min(class.rung, 2)));
    for (class.deps) |d| {
        var it = block.sites();
        while (it.next()) |site| {
            if (site.class != d or site.root == 0 or site.steps.len != 0) continue;
            // A `where` type's own arrow: which quantifier's?
            const q = whereQuantifier(iface, scheme, site.root - 1) orelse continue;
            if (q >= subs.len) continue;
            const sub = subs[q].unwrap() orelse continue;
            try e.edges.append(e.gpa, .{ .a = sub, .b = method_type });
        }
    }
}

fn whereQuantifier(iface: *const Interface, scheme: Interface.Scheme, k: u32) ?u32 {
    var left = k;
    for (0..scheme.quantified_count) |q| {
        const n = iface.quantified(scheme, @intCast(q)).constraints_len;
        if (left < n) return @intCast(q);
        left -= n;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Solving (§14.4)
// ---------------------------------------------------------------------------

/// A declaration's summary: `classes[start..][0..len]`.
pub const Summary = struct { start: u32 = 0, len: u32 = 0 };

/// One class of a summary: its node, its rung and the classes of the same
/// summary it depends on, `deps[deps_start..][0..deps_len]` (indices into
/// the summary, ascending).
pub const Class = struct { node: u32, rung: Rung, deps_start: u32 = 0, deps_len: u32 = 0 };

/// What `run` leaves: the graph, every node's rung, and the summaries.
///
/// **A node is a type root the effect graph met**, numbered in the order
/// `run` met it: most of a store's variables are never a callee, a scheme's
/// function type or a copy of one, so the graph's columns are as long as
/// the classes it has, and only `slot` is as long as the store.
pub const Solved = struct {
    /// Store variables at the time of the run; a later one has no class.
    n: u32 = 0,
    /// Per store variable: its node + 1, or 0 for one the graph never met.
    slot: []u32 = &.{},
    uf: std.ArrayList(u32) = .empty,
    level: std.ArrayList(Rung) = .empty,
    head: std.ArrayList(u32) = .empty,
    next: std.ArrayList(u32) = .empty,
    to: std.ArrayList(u32) = .empty,
    summaries: []Summary = &.{},
    classes: std.ArrayList(Class) = .empty,
    deps: std.ArrayList(u32) = .empty,
    /// `dependencies`' bits per node, live while `stamp` is `epoch`.
    mask: std.ArrayList(u64) = .empty,
    stamp: std.ArrayList(u32) = .empty,
    epoch: u32 = 0,
    /// `schemeNodes`' stack, kept across declarations.
    walk: std.ArrayList(Var) = .empty,
    /// `summarise`'s list of one scheme's nodes, kept across declarations.
    scheme_nodes: std.ArrayList(u32) = .empty,

    fn deinit(s: *Solved, gpa: Allocator) void {
        s.walk.deinit(gpa);
        s.scheme_nodes.deinit(gpa);
        gpa.free(s.slot);
        s.uf.deinit(gpa);
        s.level.deinit(gpa);
        s.head.deinit(gpa);
        s.mask.deinit(gpa);
        s.stamp.deinit(gpa);
        s.next.deinit(gpa);
        s.to.deinit(gpa);
        gpa.free(s.summaries);
        s.classes.deinit(gpa);
        s.deps.deinit(gpa);
    }

    /// How many nodes the graph has.
    pub fn nodes(s: *const Solved) u32 {
        return @intCast(s.uf.items.len);
    }

    /// Root `r`'s node, made the first time the graph meets it.
    fn nodeAt(s: *Solved, gpa: Allocator, r: Var) Error!u32 {
        const at = &s.slot[r.int()];
        if (at.* != 0) return at.* - 1;
        const id: u32 = @intCast(s.uf.items.len);
        try s.uf.append(gpa, id);
        try s.level.append(gpa, .pure);
        try s.head.append(gpa, none);
        try s.mask.append(gpa, 0);
        try s.stamp.append(gpa, 0);
        at.* = id + 1;
        return id;
    }

    /// Root `r`'s node, or null when the graph never met it.
    pub fn nodeIfAny(s: *const Solved, r: Var) ?u32 {
        if (r.int() >= s.n or s.slot[r.int()] == 0) return null;
        return s.slot[r.int()] - 1;
    }

    fn maskOf(s: *const Solved, x: u32) u64 {
        return if (s.stamp.items[x] == s.epoch) s.mask.items[x] else 0;
    }

    fn orMask(s: *Solved, x: u32, bits: u64) void {
        if (s.stamp.items[x] != s.epoch) {
            s.stamp.items[x] = s.epoch;
            s.mask.items[x] = 0;
        }
        s.mask.items[x] |= bits;
    }

    pub fn find(s: *const Solved, x: u32) u32 {
        var at = x;
        while (s.uf.items[at] != at) at = s.uf.items[at];
        return at;
    }

    fn findCompress(s: *Solved, x: u32) u32 {
        const uf = s.uf.items;
        var at = x;
        while (uf[at] != at) {
            uf[at] = uf[uf[at]];
            at = uf[at];
        }
        return at;
    }

    pub fn classesOf(s: *const Solved, decl: u32) []const Class {
        if (decl >= s.summaries.len) return &.{};
        const sum = s.summaries[decl];
        return s.classes.items[sum.start..][0..sum.len];
    }

    pub fn depsOf(s: *const Solved, c: Class) []const u32 {
        return s.deps.items[c.deps_start..][0..c.deps_len];
    }

    /// The summary class of `decl` whose node is `node`.
    pub fn classIndex(s: *const Solved, decl: u32, node: u32) ?u32 {
        for (s.classesOf(decl), 0..) |c, i| if (c.node == node) return @intCast(i);
        return null;
    }
};

/// The node a variable's class is, or null for a variable made after the
/// run: its union-find root, looked through aliases to what they stand for,
/// and through the effect joins.
pub fn nodeOf(e: *Effects, v: Var) ?u32 {
    const r, _ = e.store.resolved(v);
    const id = e.solved.nodeIfAny(r) orelse return null;
    return e.solved.find(id);
}

/// The rung node `node` reached.
pub fn levelOf(e: *const Effects, node: u32) Rung {
    return e.solved.level.items[node];
}

/// What `run` reads of the module's check.
pub const Input = struct {
    scratch: Allocator,
    bir: *const Bir,
    decl_scheme: []const Var.Optional,
    /// Per declaration, its binding group's root (`Groups.root`), so the
    /// members of one group, which share variables until it is generalised,
    /// are solved together.
    unit: []const u32,
    /// Derived answers and joined wanteds, as `(from, to)` method types
    /// (§14.3 rule 7): read off the evidence tables by the caller.
    wanted_edges: []const Pair,
    wanted_joins: []const Pair,
};

pub fn run(e: *Effects, in: Input) Error!void {
    const gpa = e.gpa;
    const store = e.store;
    const scratch = in.scratch;
    const n = store.count();
    var s = &e.solved;
    s.n = n;
    s.slot = try gpa.alloc(u32, n);
    @memset(s.slot, 0);
    s.summaries = try gpa.alloc(Summary, in.bir.decls.len);
    @memset(s.summaries, .{});

    // 1. Classes: every join, every zip position by position, every copy of
    // a generalised local (§14.3 rule 4).
    const scheme_decl = try e.schemeDecls(in, scratch);
    for (e.joins.items) |p| try e.unite(p.a, p.b);
    for (in.wanted_joins) |p| try e.unite(p.a, p.b);
    for (e.readings) |rd| {
        if (rd.check_start == none) continue;
        for (0..rd.scheme_end - rd.scheme_start) |i| {
            const s_var: Var = @enumFromInt(rd.scheme_start + i);
            if (!e.carries(e.store.find(s_var))) continue;
            try e.unite(s_var, @enumFromInt(rd.check_start + i));
        }
    }
    for (e.zips.items) |p| try e.zipped(p.a, p.b, scratch);
    for (e.records.items) |r| {
        if (scheme_decl.get(r.scheme) != null) continue;
        for (e.pairs.items[r.start..][0..r.len]) |p| try e.unite(p.a, p.b);
    }
    // Every class is final now: flattened, so each later `find` is one read.
    // A root is always the smaller node (`unite`), so ascending order meets
    // a node's parent flattened already. A node met from here on is a class
    // of its own.
    for (s.uf.items) |*u| u.* = s.uf.items[u.*];

    // 2. The edges, and the rungs seeded so far.
    for (e.edges.items) |p| try e.addEdge(p.a, p.b);
    for (in.wanted_edges) |p| try e.addEdge(p.a, p.b);
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(scratch);
    for (e.seeds.items) |sd| try e.raise(try e.nodeFor(sd.v), sd.rung, &work, scratch);
    try e.propagate(&work, scratch);

    // 3. The `foreign` declarations' summaries: rule 6, off the signature.
    for (in.bir.decls, 0..) |d, i| {
        if (d.kind != .foreign_value) continue;
        const v = in.decl_scheme[i].unwrap() orelse continue;
        try e.foreignSummary(@intCast(i), v, d.rung, scratch);
    }

    // 4. Every other declaration, dependencies first.
    const order = try e.dependencyOrder(in, scheme_decl, scratch);
    const by_owner = try e.recordsByOwner(in, scratch);
    var at: usize = 0;
    while (at + 1 < order.starts.len) : (at += 1) {
        const members = order.order[order.starts[at]..order.starts[at + 1]];
        try e.solveComponent(in, members, scheme_decl, by_owner, &work);
    }
    // A derived context's own frames: nothing depends on them.
    for (e.records.items) |r| {
        if (r.owner != no_owner) continue;
        if (scheme_decl.get(r.scheme)) |target| try e.applyRecord(r, target, &work, scratch);
    }
    try e.propagate(&work, scratch);
    // The rungs as the whole module left them: monotone, so at least what
    // each summary read when it was solved.
    for (s.classes.items) |*c| c.rung = s.level.items[c.node];
}

const none = std.math.maxInt(u32);

/// `v`'s node, through aliases and the effect joins, made the first time.
fn nodeFor(e: *Effects, v: Var) Error!u32 {
    // Most variables are no alias: the root without `resolved`'s walk.
    var r = e.store.find(v);
    if (e.store.content(r) == .alias) r, _ = e.store.resolved(r);
    return e.solved.findCompress(try e.solved.nodeAt(e.gpa, r));
}

fn unite(e: *Effects, a: Var, b: Var) Error!void {
    const x = try e.nodeFor(a);
    const y = try e.nodeFor(b);
    if (x == y) return;
    // The smaller node is the root: an order that depends on the module
    // alone (nodes are numbered in the order the graph meets them).
    if (x < y) e.solved.uf.items[y] = x else e.solved.uf.items[x] = y;
}

/// Two readings of one type, position by position, as far as both have the
/// same shape (§14.3 rules 2 and 5).
fn zipped(e: *Effects, a: Var, b: Var, scratch: Allocator) Error!void {
    const store = e.store;
    var stack: std.ArrayList(Pair) = .empty;
    defer stack.deinit(scratch);
    try stack.append(scratch, .{ .a = a, .b = b });
    // An epoch colour on both sides: a pair is walked again only when one
    // of its nodes is new, which a reading sharing a node the other does not
    // share needs, and which bounds the walk by the two graphs' sizes.
    const mark = store.nextMark();
    while (stack.pop()) |p| {
        const x, _ = store.resolved(p.a);
        const y, _ = store.resolved(p.b);
        if (x == y) continue;
        if (store.mark(x) == mark and store.mark(y) == mark) continue;
        store.setMark(x, mark);
        store.setMark(y, mark);
        if (e.carries(x) and e.carries(y)) try e.unite(x, y);
        // Two readings of one `where` clause carry its constraints in the
        // clause's order: their method types are one class too.
        const wx = Walk.constraints(store.flagsOf(x));
        const wy = Walk.constraints(store.flagsOf(y));
        if (wx.count(store) == wy.count(store)) {
            for (0..wx.count(store)) |i| {
                try stack.append(scratch, .{ .a = wx.at(store, @intCast(i)).fn_var, .b = wy.at(store, @intCast(i)).fn_var });
            }
        }
        var k: u32 = 0;
        while (true) : (k += 1) {
            const cx = Walk.stepped(store, x, k) orelse break;
            const cy = Walk.stepped(store, y, k) orelse break;
            if (cx.kind != cy.kind) break;
            try stack.append(scratch, .{ .a = cx.v, .b = cy.v });
        }
    }
}

fn addEdge(e: *Effects, a: Var, b: Var) Error!void {
    const x = try e.nodeFor(a);
    const y = try e.nodeFor(b);
    if (x == y) return;
    try e.edgeNodes(x, y);
}

fn edgeNodes(e: *Effects, x: u32, y: u32) Error!void {
    const s = &e.solved;
    try s.to.append(e.gpa, y);
    try s.next.append(e.gpa, s.head.items[x]);
    s.head.items[x] = @intCast(s.to.items.len - 1);
}

fn raise(e: *Effects, x: u32, rung: Rung, work: *std.ArrayList(u32), scratch: Allocator) Error!void {
    const s = &e.solved;
    if (@intFromEnum(rung) <= @intFromEnum(s.level.items[x])) return;
    s.level.items[x] = rung;
    try work.append(scratch, x);
}

/// The least rungs: each node at least every node with an edge into it.
fn propagate(e: *Effects, work: *std.ArrayList(u32), scratch: Allocator) Error!void {
    const s = &e.solved;
    while (work.pop()) |x| {
        var at = s.head.items[x];
        while (at != none) : (at = s.next.items[at]) {
            const y = s.find(s.to.items[at]);
            try e.raise(y, s.level.items[x], work, scratch);
        }
    }
}

/// Every own declaration by its scheme's root, so a record names the
/// declaration it copied: the pairs sorted by root, searched.
const SchemeDecls = struct {
    pairs: []const [2]u32,

    fn get(s: SchemeDecls, v: Var) ?u32 {
        var lo: usize = 0;
        var hi: usize = s.pairs.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const at = s.pairs[mid][0];
            if (at < v.int()) lo = mid + 1 else if (at > v.int()) hi = mid else return s.pairs[mid][1];
        }
        return null;
    }
};

fn schemeDecls(e: *Effects, in: Input, scratch: Allocator) Error!SchemeDecls {
    var pairs: std.ArrayList([2]u32) = .empty;
    for (in.decl_scheme, 0..) |v, i| {
        const scheme = v.unwrap() orelse continue;
        if (!in.bir.decls[i].kind.isValue()) continue;
        try pairs.append(scratch, .{ e.store.find(scheme).int(), @intCast(i) });
    }
    const Less = struct {
        fn lessThan(_: void, a: [2]u32, b: [2]u32) bool {
            return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
        }
    };
    std.mem.sort([2]u32, pairs.items, {}, Less.lessThan);
    return .{ .pairs = pairs.items };
}

/// Declaration-level strongly connected components over the references
/// records make, dependencies first; the members of one binding group are
/// one component.
fn dependencyOrder(e: *Effects, in: Input, scheme_decl: SchemeDecls, scratch: Allocator) Error!Scc.IndexGroups {
    const decls = in.bir.decls.len;
    // (from, to) pairs, then counted into CSR form.
    var arcs: std.ArrayList([2]u32) = .empty;
    defer arcs.deinit(scratch);
    for (e.records.items) |r| {
        if (r.owner == no_owner or r.owner >= decls) continue;
        const target = scheme_decl.get(r.scheme) orelse continue;
        if (target != r.owner) try arcs.append(scratch, .{ r.owner, target });
    }
    // A group's members, each tied to the first member met of its group.
    const first = try scratch.alloc(u32, decls);
    @memset(first, none);
    for (0..decls) |d| {
        const u = if (d < in.unit.len) in.unit[d] else none;
        if (u == none or u >= decls) continue;
        if (first[u] == none) {
            first[u] = @intCast(d);
        } else {
            try arcs.append(scratch, .{ @intCast(d), first[u] });
            try arcs.append(scratch, .{ first[u], @intCast(d) });
        }
    }
    // No arc, the common case: every declaration a component of its own,
    // in index order, with no search.
    if (arcs.items.len == 0) {
        const order = try scratch.alloc(u32, decls);
        const starts = try scratch.alloc(u32, decls + 1);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        for (starts, 0..) |*s, i| s.* = @intCast(i);
        return .{ .order = order, .starts = starts };
    }
    const start = try scratch.alloc(u32, decls + 1);
    @memset(start, 0);
    for (arcs.items) |a| start[a[0] + 1] += 1;
    for (1..decls + 1) |i| start[i] += start[i - 1];
    const targets = try scratch.alloc(u32, arcs.items.len);
    const fill = try scratch.dupe(u32, start[0..decls]);
    for (arcs.items) |a| {
        targets[fill[a[0]]] = a[1];
        fill[a[0]] += 1;
    }
    return Scc.sccGroups(scratch, decls, targets, start);
}

/// Record indices by owning declaration, in record order.
const ByOwner = struct { start: []u32, items: []u32 };

fn recordsByOwner(e: *Effects, in: Input, scratch: Allocator) Error!ByOwner {
    const decls = in.bir.decls.len;
    const start = try scratch.alloc(u32, decls + 1);
    @memset(start, 0);
    for (e.records.items) |r| {
        if (r.owner < decls) start[r.owner + 1] += 1;
    }
    for (1..decls + 1) |i| start[i] += start[i - 1];
    const items = try scratch.alloc(u32, start[decls]);
    const fill = try scratch.dupe(u32, start[0..decls]);
    for (e.records.items, 0..) |r, i| {
        if (r.owner >= decls) continue;
        items[fill[r.owner]] = @intCast(i);
        fill[r.owner] += 1;
    }
    return .{ .start = start, .items = items };
}

/// One component: its records applied, its rungs propagated, its summaries
/// read off the graph — again while a record of the component into the
/// component meets a summary that changed.
fn solveComponent(e: *Effects, in: Input, members: []const u32, scheme_decl: SchemeDecls, by_owner: ByOwner, work: *std.ArrayList(u32)) Error!void {
    const scratch = in.scratch;
    var inward = false;
    var rounds: u32 = 0;
    while (true) : (rounds += 1) {
        for (members) |d| {
            for (by_owner.items[by_owner.start[d]..by_owner.start[d + 1]]) |ri| {
                const r = e.records.items[ri];
                const target = scheme_decl.get(r.scheme) orelse continue;
                // A record into the component reads a summary this loop
                // is still solving.
                if (members.len == 1) {
                    if (target == members[0]) inward = true;
                } else if (std.mem.indexOfScalar(u32, members, target) != null) inward = true;
                try e.applyRecord(r, target, work, scratch);
            }
        }
        try e.propagate(work, scratch);
        const changed = try e.summarise(in, members);
        // The ladder has three points and a scheme finitely many classes, so
        // the summaries stop changing; the bound only guards a bug.
        if (!inward or !changed or rounds > 64) break;
    }
}

/// A copy of `target`'s scheme gets `target`'s summary (§14.3 rule 3): its
/// copies of one class are one class, each gets the class's rung, and the
/// copy of each class it depends on flows into it.
fn applyRecord(e: *Effects, r: Record, target: u32, work: *std.ArrayList(u32), scratch: Allocator) Error!void {
    const s = &e.solved;
    const classes = s.classesOf(target);
    if (classes.len == 0) return;
    const reps = try scratch.alloc(u32, classes.len);
    defer scratch.free(reps);
    @memset(reps, none);
    for (e.pairs.items[r.start..][0..r.len]) |p| {
        const sn = try e.nodeFor(p.a);
        const c = s.classIndex(target, sn) orelse continue;
        const i = try e.nodeFor(p.b);
        if (reps[c] == none) {
            reps[c] = i;
        } else if (reps[c] != i) {
            try e.edgeNodes(reps[c], i);
            try e.edgeNodes(i, reps[c]);
            const lr = s.level.items[reps[c]];
            const li = s.level.items[i];
            if (@intFromEnum(lr) > @intFromEnum(li)) try e.raise(i, lr, work, scratch);
            if (@intFromEnum(li) > @intFromEnum(lr)) try e.raise(reps[c], li, work, scratch);
        }
    }
    for (classes, 0..) |c, ci| {
        const rep = reps[ci];
        if (rep == none) continue;
        try e.raise(rep, c.rung, work, scratch);
        for (s.depsOf(c)) |d| {
            const from = reps[d];
            if (from == none) continue;
            try e.edgeNodes(from, rep);
            try e.raise(rep, s.level.items[from], work, scratch);
        }
    }
}

/// Read each member's summary off the graph: its scheme's classes, each
/// one's rung, and — 64 classes at a time, one bit each, pushed forward
/// along the edges — which of the declaration's other classes reach it.
/// True when a summary changed.
fn summarise(e: *Effects, in: Input, members: []const u32) Error!bool {
    const s = &e.solved;
    const scratch = in.scratch;
    var changed = false;
    for (members) |d| {
        if (!in.bir.decls[d].kind.isValue() or in.bir.decls[d].kind == .foreign_value) continue;
        const scheme = in.decl_scheme[d].unwrap() orelse continue;
        const nodes = &s.scheme_nodes;
        nodes.clearRetainingCapacity();
        const rd = e.readings[d];
        if (rd.scheme_start != none and e.store.content(e.store.find(scheme)) != .err) {
            // An annotated scheme's variables are its reading's range: no
            // walk (see `readings`).
            for (rd.scheme_start..rd.scheme_end) |i| {
                const r = e.store.find(@enumFromInt(i));
                if (!e.carries(r)) continue;
                const nd = try e.nodeFor(r);
                if (std.mem.indexOfScalar(u32, nodes.items, nd) == null) try nodes.append(e.gpa, nd);
            }
        } else try e.schemeNodes(scheme, nodes);
        // One class, the common case, depends on no other: no bits to push.
        if (nodes.items.len <= 1) {
            const old = s.classesOf(d);
            if (nodes.items.len == 0) {
                if (old.len == 0) continue;
                s.summaries[d] = .{};
                changed = true;
                continue;
            }
            const nd = nodes.items[0];
            if (old.len == 1 and old[0].node == nd and old[0].rung == s.level.items[nd]) continue;
            changed = true;
            s.summaries[d] = .{ .start = @intCast(s.classes.items.len), .len = 1 };
            try s.classes.append(e.gpa, .{ .node = nd, .rung = s.level.items[nd] });
            continue;
        }
        const deps = try e.dependencies(nodes.items, scratch);
        defer {
            for (deps) |list| scratch.free(list);
            scratch.free(deps);
        }
        // Compare with the summary in place, then replace it.
        const old = s.classesOf(d);
        var same = old.len == nodes.items.len;
        if (same) {
            for (old, nodes.items, deps) |c, nd, ds| {
                if (c.node != nd or c.rung != s.level.items[nd] or !std.mem.eql(u32, s.depsOf(c), ds)) same = false;
            }
        }
        if (same) continue;
        changed = true;
        const start: u32 = @intCast(s.classes.items.len);
        for (nodes.items, deps) |nd, ds| {
            const deps_start: u32 = @intCast(s.deps.items.len);
            try s.deps.appendSlice(e.gpa, ds);
            try s.classes.append(e.gpa, .{ .node = nd, .rung = s.level.items[nd], .deps_start = deps_start, .deps_len = @intCast(ds.len) });
        }
        s.summaries[d] = .{ .start = start, .len = @intCast(nodes.items.len) };
    }
    return changed;
}

/// For each of `nodes`, the indices of the others that reach it, ascending.
pub fn dependencies(e: *Effects, nodes: []const u32, scratch: Allocator) Error![][]u32 {
    const s = &e.solved;
    const out = try scratch.alloc([]u32, nodes.len);
    for (out) |*o| o.* = &.{};
    // One class depends on no other: most functions have only their own.
    if (nodes.len < 2) return out;
    var lists = try scratch.alloc(std.ArrayList(u32), nodes.len);
    defer scratch.free(lists);
    for (lists) |*l| l.* = .empty;
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(scratch);
    var chunk: usize = 0;
    while (chunk < nodes.len) : (chunk += 64) {
        const end = @min(nodes.len, chunk + 64);
        // The bits live in a column over the nodes, valid under this pass's
        // epoch: no clearing, and no map keyed by a dense id.
        s.epoch +%= 1;
        if (s.epoch == 0) {
            @memset(s.stamp.items, 0);
            s.epoch = 1;
        }
        for (nodes[chunk..end], 0..) |nd, b| {
            s.orMask(nd, @as(u64, 1) << @intCast(b));
            try work.append(scratch, nd);
        }
        while (work.pop()) |x| {
            const bits = s.maskOf(x);
            var at = s.head.items[x];
            while (at != none) : (at = s.next.items[at]) {
                const y = s.find(s.to.items[at]);
                if (s.maskOf(y) | bits == s.maskOf(y)) continue;
                s.orMask(y, bits);
                try work.append(scratch, y);
            }
        }
        for (nodes, 0..) |nd, i| {
            const bits = s.maskOf(nd);
            if (bits == 0) continue;
            for (chunk..end) |j| {
                if (j == i) continue;
                if (bits & (@as(u64, 1) << @intCast(j - chunk)) != 0) try lists[i].append(scratch, @intCast(j));
            }
        }
    }
    for (lists, out) |*l, *o| o.* = try l.toOwnedSlice(scratch);
    return out;
}

/// The distinct nodes of `scheme`'s function types and function-holding
/// applications, its `where` types included, in a depth-first order.
/// The order is the walk's, deterministic and otherwise immaterial: a
/// summary's classes are numbered again by site when published, and named
/// by first print when dumped.
fn schemeNodes(e: *Effects, scheme: Var, out: *std.ArrayList(u32)) Error!void {
    const store = e.store;
    const stack = &e.solved.walk;
    stack.clearRetainingCapacity();
    const mark = store.nextMark();
    try stack.append(e.gpa, scheme);
    while (stack.pop()) |next| {
        const r = store.find(next);
        if (store.mark(r) == mark) continue;
        store.setMark(r, mark);
        switch (store.content(r)) {
            .flex, .rigid => |flags| {
                const set = Walk.constraints(flags);
                for (0..set.count(store)) |i| try stack.append(e.gpa, set.at(store, @intCast(i)).fn_var);
                continue;
            },
            else => {},
        }
        if (e.carries(r)) {
            const nd = try e.nodeFor(r);
            if (std.mem.indexOfScalar(u32, out.items, nd) == null) try out.append(e.gpa, nd);
        }
        var k: u32 = 0;
        while (Walk.stepped(store, r, k)) |c| : (k += 1) try stack.append(e.gpa, c.v);
    }
}

/// §14.3 rule 6: a `foreign`'s own arrow has its rung, and so does every
/// function type in a positive position of its signature; its `where` types
/// flow into its own arrow; everything else is independent.
fn foreignSummary(e: *Effects, decl: u32, scheme: Var, rung: Rung, scratch: Allocator) Error!void {
    const s = &e.solved;
    const store = e.store;
    const own_var, _ = store.resolved(scheme);
    const is_function = switch (store.content(own_var)) {
        .structure => |st| st == .func,
        else => false,
    };
    var nodes: std.ArrayList(u32) = .empty;
    defer nodes.deinit(scratch);
    var positive: std.ArrayList(bool) = .empty;
    defer positive.deinit(scratch);
    var evidence: std.ArrayList(bool) = .empty;
    defer evidence.deinit(scratch);
    const Item = struct { v: Var, positive: bool, evidence: bool };
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(scratch);
    try stack.append(scratch, .{ .v = scheme, .positive = true, .evidence = false });
    const mark = store.nextMark();
    while (stack.pop()) |item| {
        const r = store.find(item.v);
        if (store.mark(r) == mark) continue;
        store.setMark(r, mark);
        switch (store.content(r)) {
            .flex, .rigid => |flags| {
                const set = Walk.constraints(flags);
                for (0..set.count(store)) |i| try stack.append(scratch, .{ .v = set.at(store, @intCast(i)).fn_var, .positive = false, .evidence = true });
                continue;
            },
            else => {},
        }
        if (e.carries(r)) {
            const nd = try e.nodeFor(r);
            if (std.mem.indexOfScalar(u32, nodes.items, nd) == null) {
                try nodes.append(scratch, nd);
                try positive.append(scratch, item.positive);
                try evidence.append(scratch, item.evidence);
            }
        }
        var k: u32 = 0;
        while (Walk.stepped(store, r, k)) |c| : (k += 1) {
            // A parameter flips the position; everything else keeps it.
            const flips = c.kind == .param;
            try stack.append(scratch, .{ .v = c.v, .positive = if (flips) !item.positive else item.positive, .evidence = item.evidence });
        }
    }
    const own = if (is_function) try e.nodeFor(own_var) else none;
    const start: u32 = @intCast(s.classes.items.len);
    for (nodes.items, positive.items, evidence.items) |nd, pos, _| {
        const deps_start: u32 = @intCast(s.deps.items.len);
        if (nd == own) {
            for (nodes.items, evidence.items, 0..) |other, ev, j| {
                if (ev and other != own) try s.deps.append(e.gpa, @intCast(j));
            }
        }
        const class_rung: Rung = if (pos and !isEvidence(nodes.items, evidence.items, nd)) rung else .pure;
        try s.classes.append(e.gpa, .{
            .node = nd,
            .rung = class_rung,
            .deps_start = deps_start,
            .deps_len = @intCast(s.deps.items.len - deps_start),
        });
        var work: std.ArrayList(u32) = .empty;
        defer work.deinit(scratch);
        try e.raise(nd, class_rung, &work, scratch);
        try e.propagate(&work, scratch);
    }
    s.summaries[decl] = .{ .start = start, .len = @intCast(nodes.items.len) };
}

fn isEvidence(nodes: []const u32, evidence: []const bool, nd: u32) bool {
    for (nodes, evidence) |x, ev| if (x == nd) return ev;
    return false;
}

// ---------------------------------------------------------------------------
// Publication (§14.6)
// ---------------------------------------------------------------------------

/// What the writer needs of one declaration to write its block.
pub const Publication = struct {
    effects: *Effects,
    decl: u32,
};

/// Whether `decl`'s summary says anything a block would carry: some class
/// with a rung or a dependency (a dependant needs one to depend on it).
/// Most schemes do not, and their block is `no_terms` at no cost.
pub fn publishes(e: *const Effects, decl: u32) bool {
    for (e.solved.classesOf(decl)) |c| {
        if (c.rung != .pure or c.deps_len != 0) return true;
    }
    return false;
}

/// One site of a scheme on its way into a block.
const Site = struct { v: Var, node: u32, root: u32, steps_start: u32, steps_len: u32 };

/// The block of `decl`'s scheme `v`, appended to `extra`, or `no_terms`
/// when no class of it carries anything. `where_types` are the scheme's
/// `where` types in the record's order; `symbol_index` turns a field's
/// `Symbol` into the record's `SymbolIndex`; `extra` grows with `extra_gpa`.
pub fn writeBlock(
    e: *Effects,
    decl: u32,
    v: Var,
    where_types: []const Var,
    extra_gpa: Allocator,
    extra: *std.ArrayList(u32),
    context: anytype,
    comptime symbol_index: fn (@TypeOf(context), Symbol) Error!u32,
) Error!u32 {
    const s = &e.solved;
    const classes = s.classesOf(decl);
    if (!e.publishes(decl)) return Interface.no_terms;
    const gpa = e.gpa;
    // Which classes are worth a site: a rung, a dependency, or a dependant.
    const worth = try gpa.alloc(bool, classes.len);
    defer gpa.free(worth);
    @memset(worth, false);
    for (classes, 0..) |c, i| {
        if (c.rung != .pure or c.deps_len != 0) worth[i] = true;
        for (s.depsOf(c)) |d| worth[d] = true;
    }
    if (std.mem.indexOfScalar(bool, worth, true) == null) return Interface.no_terms;

    var sites: std.ArrayList(Site) = .empty;
    defer sites.deinit(gpa);
    var steps: std.ArrayList(u32) = .empty;
    defer steps.deinit(gpa);
    const roots = try gpa.alloc(Var, where_types.len + 1);
    defer gpa.free(roots);
    roots[0] = v;
    @memcpy(roots[1..], where_types);
    try e.walkSites(roots, &sites, &steps, context, symbol_index);

    // Classes numbered by first site.
    const number = try gpa.alloc(u32, classes.len);
    defer gpa.free(number);
    @memset(number, none);
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(gpa);
    var kept: std.ArrayList(Site) = .empty;
    defer kept.deinit(gpa);
    for (sites.items) |site| {
        const c = s.classIndex(decl, site.node) orelse continue;
        if (!worth[c]) continue;
        if (number[c] == none) {
            number[c] = @intCast(order.items.len);
            try order.append(gpa, @intCast(c));
        }
        try kept.append(gpa, site);
    }
    if (order.items.len == 0) return Interface.no_terms;
    const at: u32 = @intCast(extra.items.len);
    try extra.append(extra_gpa, @intCast(order.items.len));
    var deps: std.ArrayList(u32) = .empty;
    defer deps.deinit(gpa);
    for (order.items) |c| {
        const class = classes[c];
        deps.clearRetainingCapacity();
        for (s.depsOf(class)) |d| {
            if (number[d] != none) try deps.append(gpa, number[d]);
        }
        std.mem.sort(u32, deps.items, {}, std.sort.asc(u32));
        try extra.append(extra_gpa, @intFromEnum(class.rung));
        try extra.append(extra_gpa, @intCast(deps.items.len));
        try extra.appendSlice(extra_gpa, deps.items);
    }
    try extra.append(extra_gpa, @intCast(kept.items.len));
    for (kept.items) |site| {
        const c = s.classIndex(decl, site.node).?;
        try extra.append(extra_gpa, number[c]);
        try extra.append(extra_gpa, site.root);
        try extra.append(extra_gpa, site.steps_len);
        try extra.appendSlice(extra_gpa, steps.items[site.steps_start..][0..site.steps_len]);
    }
    return at;
}

/// §14.6's walk: from each root in turn, depth first, parameters before
/// the result, arguments and elements in order, a record's fields by name
/// text then its extension, an alias's expansion; each variable once. Every
/// function type and function-holding application is a site, with the path
/// that reached it first.
fn walkSites(
    e: *Effects,
    roots: []const Var,
    sites: *std.ArrayList(Site),
    steps: *std.ArrayList(u32),
    context: anytype,
    comptime symbol_index: fn (@TypeOf(context), Symbol) Error!u32,
) Error!void {
    const gpa = e.gpa;
    const store = e.store;
    const Frame = struct { v: Var, path_start: u32, path_len: u32 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(gpa);
    // Paths live in one list; a frame's path is a run of it.
    var paths: std.ArrayList(u32) = .empty;
    defer paths.deinit(gpa);
    var kids: std.ArrayList(Walk.Stepped) = .empty;
    defer kids.deinit(gpa);
    const mark = store.nextMark();
    for (roots, 0..) |root, ri| {
        try stack.append(gpa, .{ .v = root, .path_start = 0, .path_len = 0 });
        while (stack.pop()) |f| {
            const r = store.find(f.v);
            if (store.mark(r) == mark) continue;
            store.setMark(r, mark);
            if (e.carries(r)) {
                // A variable the graph never met is in no class a summary has.
                if (e.solved.nodeIfAny(r)) |id| {
                    const steps_start: u32 = @intCast(steps.items.len);
                    try steps.appendSlice(gpa, paths.items[f.path_start..][0..f.path_len]);
                    try sites.append(gpa, .{ .v = r, .node = e.solved.find(id), .root = @intCast(ri), .steps_start = steps_start, .steps_len = f.path_len });
                }
            }
            kids.clearRetainingCapacity();
            var k: u32 = 0;
            while (Walk.stepped(store, r, k)) |c| : (k += 1) try kids.append(gpa, c);
            // A record's fields by name text (the extension stays last).
            const Sorter = struct {
                interner: *const InternPool.Global,
                fn lessThan(ctx: @This(), a: Walk.Stepped, b: Walk.Stepped) bool {
                    if (a.kind != .field or b.kind != .field) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
                    return std.mem.lessThan(u8, ctx.interner.slice(@enumFromInt(a.index)), ctx.interner.slice(@enumFromInt(b.index)));
                }
            };
            std.mem.sort(Walk.Stepped, kids.items, Sorter{ .interner = e.interner }, Sorter.lessThan);
            // Pushed in reverse, so the first child is walked first.
            var i = kids.items.len;
            while (i > 0) {
                i -= 1;
                const c = kids.items[i];
                const index: u32 = if (c.kind == .field) try symbol_index(context, @enumFromInt(c.index)) else c.index;
                const path_start: u32 = @intCast(paths.items.len);
                // Grown first: the parent's path is a run of this same list.
                try paths.ensureUnusedCapacity(gpa, f.path_len + 1);
                paths.appendSliceAssumeCapacity(paths.items[f.path_start..][0..f.path_len]);
                paths.appendAssumeCapacity((@as(u32, @intFromEnum(c.kind)) << 28) | index);
                try stack.append(gpa, .{ .v = c.v, .path_start = path_start, .path_len = f.path_len + 1 });
            }
        }
    }
}

// ---------------------------------------------------------------------------
// What the dumps print (§14.7)
// ---------------------------------------------------------------------------

/// The classes one printed type may show, and their names: a
/// declaration's summary with its locals read against it (`forDecl`), or an
/// interface scheme's block (`forBlock`). Every lookup is a column over the
/// store's variables, never a map keyed by one.
pub const View = struct {
    gpa: Allocator,
    /// `forBlock`: per store variable, its class + 1, or 0.
    by_var: []u32 = &.{},
    /// `forDecl`: the solved graph, and the declaration read against it.
    effects: ?*Effects = null,
    decl: u32 = 0,
    /// `forDecl`: per node, which of the declaration's classes reach it,
    /// `chunks` words of 64 bits each.
    reach: []u64 = &.{},
    chunks: u32 = 0,
    classes: std.ArrayList(ViewClass) = .empty,
    deps: std.ArrayList(u32) = .empty,
    /// Per class, its printed name once it has one, or `none`.
    names: std.ArrayList(u32) = .empty,
    named: u32 = 0,
    /// A local's dependencies, rebuilt per lookup.
    scratch_deps: std.ArrayList(u32) = .empty,

    pub const ViewClass = struct { rung: Rung, deps_start: u32, deps_len: u32, dependant: bool };

    pub fn deinit(view: *View) void {
        view.gpa.free(view.by_var);
        view.gpa.free(view.reach);
        view.classes.deinit(view.gpa);
        view.deps.deinit(view.gpa);
        view.names.deinit(view.gpa);
        view.scratch_deps.deinit(view.gpa);
    }

    fn addClass(view: *View, rung: Rung, deps: []const u32) Error!void {
        try view.classes.append(view.gpa, .{ .rung = rung, .deps_start = @intCast(view.deps.items.len), .deps_len = @intCast(deps.len), .dependant = false });
        try view.deps.appendSlice(view.gpa, deps);
        try view.names.append(view.gpa, none);
    }

    fn markDependants(view: *View) void {
        for (view.deps.items) |d| {
            if (d < view.classes.items.len) view.classes.items[d].dependant = true;
        }
    }

    /// A declaration's summary, and its locals read against it.
    pub fn forDecl(gpa: Allocator, e: *Effects, decl: u32) Error!View {
        var view: View = .{ .gpa = gpa, .effects = e, .decl = decl };
        errdefer view.deinit();
        const s = &e.solved;
        const classes = s.classesOf(decl);
        for (classes) |c| try view.addClass(c.rung, s.depsOf(c));
        view.markDependants();
        // What reaches each node the declaration's classes reach: one
        // forward walk per class, its bit set on every node it meets.
        view.chunks = @intCast((classes.len + 63) / 64);
        view.reach = try gpa.alloc(u64, @as(usize, s.nodes()) * view.chunks);
        @memset(view.reach, 0);
        var work: std.ArrayList(u32) = .empty;
        defer work.deinit(gpa);
        for (classes, 0..) |c, ci| {
            const word = ci / 64;
            const bit = @as(u64, 1) << @intCast(ci % 64);
            try work.append(gpa, c.node);
            view.reach[@as(usize, c.node) * view.chunks + word] |= bit;
            while (work.pop()) |x| {
                var at = s.head.items[x];
                while (at != none) : (at = s.next.items[at]) {
                    const y = s.find(s.to.items[at]);
                    const slot = &view.reach[@as(usize, y) * view.chunks + word];
                    if (slot.* & bit != 0) continue;
                    slot.* |= bit;
                    try work.append(gpa, y);
                }
            }
        }
        return view;
    }

    /// An interface scheme's block, over the variables `Schemes.instantiate`
    /// read it into.
    pub fn forBlock(gpa: Allocator, store: *TypeStore, iface: *const Interface, scheme: Interface.Scheme, body: Var, quantified: []const Var) Error!View {
        var view: View = .{ .gpa = gpa };
        errdefer view.deinit();
        const block = iface.effectBlock(scheme) orelse return view;
        for (0..block.classCount()) |c| {
            const class = block.class(@intCast(c));
            try view.addClass(@enumFromInt(@min(class.rung, 2)), class.deps);
        }
        view.markDependants();
        view.by_var = try gpa.alloc(u32, store.count());
        @memset(view.by_var, 0);
        var reader: Effects = .{ .gpa = gpa, .store = store, .types = undefined, .interner = undefined };
        var sites = block.sites();
        while (sites.next()) |site| {
            const v = reader.follow(iface, site, body, quantified) orelse continue;
            const r, _ = store.resolved(v);
            if (r.int() < view.by_var.len) view.by_var[r.int()] = site.class + 1;
        }
        return view;
    }

    const Printed = union(enum) { class: u32, local: struct { rung: Rung, deps: []const u32 } };

    /// What `v` prints: one of the view's classes, or a local's rung and the
    /// declaration's classes that reach it.
    fn classOf(view: *View, store: *TypeStore, v: Var) Error!?Printed {
        const r, _ = store.resolved(v);
        if (r.int() < view.by_var.len and view.by_var[r.int()] != 0) return .{ .class = view.by_var[r.int()] - 1 };
        const e = view.effects orelse return null;
        if (!e.carries(r)) return null;
        const nd = e.nodeOf(r) orelse return null;
        if (e.solved.classIndex(view.decl, nd)) |c| return .{ .class = c };
        view.scratch_deps.clearRetainingCapacity();
        for (0..view.classes.items.len) |ci| {
            if (view.reach[@as(usize, nd) * view.chunks + ci / 64] & (@as(u64, 1) << @intCast(ci % 64)) != 0) {
                try view.scratch_deps.append(view.gpa, @intCast(ci));
            }
        }
        const rung = e.levelOf(nd);
        if (rung == .pure and view.scratch_deps.items.len == 0) return null;
        return .{ .local = .{ .rung = rung, .deps = view.scratch_deps.items } };
    }

    /// ` !x` for `v`'s class, or nothing when it prints nothing (§14.7).
    pub fn suffix(view: *View, store: *TypeStore, v: Var, out: *std.ArrayList(u8)) Error!void {
        out.clearRetainingCapacity();
        const what = (try view.classOf(store, v)) orelse return;
        var rung: Rung = .pure;
        var own: ?u32 = null;
        var deps: []const u32 = &.{};
        switch (what) {
            .class => |c| {
                const vc = view.classes.items[c];
                rung = vc.rung;
                if (vc.dependant) own = c;
                deps = view.deps.items[vc.deps_start..][0..vc.deps_len];
            },
            .local => |l| {
                rung = l.rung;
                deps = l.deps;
            },
        }
        if (rung == .suspends) return out.appendSlice(view.gpa, " !suspends");
        var parts: u32 = 0;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(view.gpa);
        if (rung == .impure) {
            try text.appendSlice(view.gpa, "impure");
            parts += 1;
        }
        if (own) |c| {
            if (parts != 0) try text.appendSlice(view.gpa, " | ");
            try view.nameOf(c, &text);
            parts += 1;
        }
        for (deps) |d| {
            if (d >= view.names.items.len or own == d) continue;
            if (parts != 0) try text.appendSlice(view.gpa, " | ");
            try view.nameOf(d, &text);
            parts += 1;
        }
        if (parts == 0) return;
        try out.appendSlice(view.gpa, " !");
        if (parts > 1) try out.append(view.gpa, '(');
        try out.appendSlice(view.gpa, text.items);
        if (parts > 1) try out.append(view.gpa, ')');
    }

    fn nameOf(view: *View, c: u32, text: *std.ArrayList(u8)) Error!void {
        if (view.names.items[c] == none) {
            view.named += 1;
            view.names.items[c] = view.named;
        }
        var buf: [16]u8 = undefined;
        try text.appendSlice(view.gpa, std.fmt.bufPrint(&buf, "e{d}", .{view.names.items[c]}) catch unreachable);
    }
};
