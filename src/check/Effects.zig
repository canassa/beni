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
//! Nothing here reports, and no emitted byte depends on it. The `sync` step
//! (§15 there) is the first reader: demands ride beside the rungs — a
//! `sync` position records one on a class, a summary carries it to every
//! use (`Class.sync`) — and `Sync.zig` reports the ones that reached
//! `suspends`.

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
pub const Record = struct { owner: u32, scheme: Var, start: u32, len: u32, site: u32 = none };
pub const no_owner = std.math.maxInt(u32);

/// Where a call edge came from, for the `sync` chain (§15.4): the call's
/// instruction, and the lambda or `let` definition whose body the call is
/// in (`none` for the declaration's own body). `none` throughout for an edge
/// no call wrote.
pub const Site = struct { call: u32 = none, ambient: u32 = none };

/// Which boundary put a demand on its class (§15.2).
/// `.value` is a top-level value other than `main` (§15.2 item 7).
pub const DemandKind = enum(u8) { argument, handler, row, key, main, value, method, signature };

/// "This class must not suspend" (§15.1), recorded before the run: `v`
/// carries the class, `site` is the instruction it is attributed to.
/// `.argument`: where the class sits in the callee's arrow — its parameter
/// `param` and, inside that, the record field `field` (a `Symbol`), or the
/// `where` method `method` (a `Symbol`) — as far as a site of the summary
/// says, and `holder` when the class is a nominal application's rather
/// than a function type's. `.main`, `.value` and `.method`: the declaration, and for
/// a method the name of the type it is written for, in `field`. `.signature`: a
/// function type an ordinary declaration's signature marks `sync` (§15.2 item
/// 1, amended 2026-10-02), `site` its `type_fn` instruction, `decl` the
/// declaration.
pub const Demand = struct {
    v: Var,
    kind: DemandKind,
    site: u32,
    decl: u32 = none,
    param: u32 = none,
    field: u32 = none,
    method: u32 = none,
    holder: bool = false,
};

/// A demand on a node of the solved graph. One `applyRecord` makes names
/// the summary class it came from, `target`'s `class`, instead of a path.
pub const Source = struct { node: u32, demand: Demand, target: u32 = none, class: u32 = none };

/// An imported value a use read whose own class suspends: where the chain
/// of §15.4 ends.
pub const Terminal = struct { v: Var, site: u32 };

pub const ForeignSync = struct { decl: u32, v: Var };

/// A lambda's or a `let` definition's own arrow, by its instruction: what
/// the lowering asks "is this function suspendable?" of (§16.2).
pub const Fn = struct { inst: u32, v: Var };

/// An imported value's or method's type as a use read it, by the use's
/// instruction: what the lowering asks "which body?" of (§16.2).
pub const Use = struct { site: u32, v: Var };

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
/// Per edge of `edges`, the call it came from (§15.4).
sites: std.ArrayList(Site) = .empty,
/// The demands generation, instantiation and P2 recorded (§15.2).
demands: std.ArrayList(Demand) = .empty,
/// The function types this module's `foreign`s mark `sync`.
foreign_syncs: std.ArrayList(ForeignSync) = .empty,
/// The imported values a use read whose own class suspends.
terminals: std.ArrayList(Terminal) = .empty,
/// Every lambda's and `let` definition's own arrow (§16.2).
fns: std.ArrayList(Fn) = .empty,
/// Every imported value's and method's type at its use (§16.2).
uses: std.ArrayList(Use) = .empty,
/// Every own declaration by its scheme's root, `(root, declaration)`
/// ascending, as the run found them.
scheme_decl: []const [2]u32 = &.{},
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
    e.sites.deinit(gpa);
    e.demands.deinit(gpa);
    e.foreign_syncs.deinit(gpa);
    e.terminals.deinit(gpa);
    e.fns.deinit(gpa);
    e.uses.deinit(gpa);
    gpa.free(e.scheme_decl);
    gpa.free(e.eval);
    gpa.free(e.readings);
    e.solved.deinit(gpa);
    e.* = undefined;
}

// ---------------------------------------------------------------------------
// Recording (generation, solving, instantiation)
// ---------------------------------------------------------------------------

/// §14.3 rule 1: a call of `callee` from a body whose class is `ambient`,
/// written at `site` (§15.4).
pub fn call(e: *Effects, callee: Var, ambient: Var, site: Site) Error!void {
    try e.edges.append(e.gpa, .{ .a = callee, .b = ambient });
    try e.sites.append(e.gpa, site);
}

/// §15.2: a boundary's demand on the class `d.v` carries.
pub fn demand(e: *Effects, d: Demand) Error!void {
    try e.demands.append(e.gpa, d);
}

/// §15.2 item 1: `v`, a function type P2 built for `foreign` `decl`'s
/// annotation, is marked `sync`.
pub fn foreignSync(e: *Effects, decl: u32, v: Var) Error!void {
    try e.foreign_syncs.append(e.gpa, .{ .decl = decl, .v = v });
}

/// A lambda's or `let` definition's own arrow `v`, made by `inst` (§16.2).
pub fn function(e: *Effects, inst: u32, v: Var) Error!void {
    try e.fns.append(e.gpa, .{ .inst = inst, .v = v });
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
/// roots it copied, each with its copy in the store's `copy` memo; `site`
/// the use it is for (§15.3).
pub fn recordCopy(e: *Effects, owner: u32, scheme: Var, copied: []const Var, site: u32) Error!void {
    const start: u32 = @intCast(e.pairs.items.len);
    for (copied) |r| {
        if (!e.carries(r)) continue;
        const c = e.store.copy(r).unwrap() orelse continue;
        try e.pairs.append(e.gpa, .{ .a = r, .b = c });
    }
    const len: u32 = @intCast(e.pairs.items.len - start);
    if (len == 0) return;
    try e.records.append(e.gpa, .{ .owner = owner, .scheme = e.store.find(scheme), .start = start, .len = len, .site = site });
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
pub fn applyImported(e: *Effects, iface: *const Interface, scheme: Interface.Scheme, body: Var, quantified: []const Var, site_inst: u32) Error!void {
    const block = iface.effectBlock(scheme) orelse return;
    // A declaration with a second body: which one this use takes is read off
    // the type it was read at, once everything is solved (§16.2).
    if (block.twin()) {
        try e.uses.append(e.gpa, .{ .site = site_inst, .v = body });
        // And the `where` types, while the quantifiers still carry them: the
        // evidence a use passes is read at the same site (§16.2).
        for (quantified) |q| {
            const set = Walk.constraints(e.store.flagsOf(e.store.find(q)));
            for (0..set.count(e.store)) |i| try e.uses.append(e.gpa, .{ .site = site_inst, .v = set.at(e.store, @intCast(i)).fn_var });
        }
    }
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
        const rung: Rung = @enumFromInt(@min(class.rung, 2));
        try e.seed(rep, rung);
        // Where a `sync` chain ends (§15.4): this use suspends by itself.
        if (rung == .suspends) try e.terminals.append(e.gpa, .{ .v = rep, .site = site_inst });
        for (class.deps) |d| {
            const from = reps[d].unwrap() orelse continue;
            try e.uncalled(from, rep);
        }
        // §15.3: the use's copy of a `sync` class must not suspend.
        if (class.sync) try e.demand(e.importedDemand(iface, scheme, block, @intCast(c), rep, site_inst));
    }
}

/// An edge no call wrote: a summary's dependency, applied at a use.
fn uncalled(e: *Effects, a: Var, b: Var) Error!void {
    try e.edges.append(e.gpa, .{ .a = a, .b = b });
    try e.sites.append(e.gpa, .{});
}

/// The demand a use of an imported value puts on `rep`, its copy of class
/// `c`: where the class sits, read off the class's first site (§15.4 needs
/// the parameter to point at, and the field or `where` method to name).
fn importedDemand(e: *const Effects, iface: *const Interface, scheme: Interface.Scheme, block: Interface.EffectBlock, c: u32, rep: Var, site_inst: u32) Demand {
    var d: Demand = .{ .v = rep, .kind = .argument, .site = site_inst, .holder = e.isHolder(rep) };
    var it = block.sites();
    const first = while (it.next()) |s| {
        if (s.class == c) break s;
    } else return d;
    if (first.root != 0) {
        // A `where` type: which quantifier's, and which of its constraints.
        var left = first.root - 1;
        for (0..scheme.quantified_count) |q| {
            const quantifier = iface.quantified(scheme, @intCast(q));
            if (left < quantifier.constraints_len) {
                d.method = @intFromEnum(iface.symbol(iface.quantifiedConstraint(quantifier, left).name));
                break;
            }
            left -= quantifier.constraints_len;
        }
        return d;
    }
    var seen: u32 = 0;
    for (first.steps) |word| {
        const kind = std.enums.fromInt(Walk.StepKind, Interface.EffectBlock.stepKind(word)) orelse return d;
        const index = Interface.EffectBlock.stepIndex(word);
        if (kind == .expansion) continue;
        if (seen == 0) {
            if (kind != .param) return d;
            d.param = index;
        } else {
            if (kind == .field and index < iface.symbols.len) d.field = @intFromEnum(iface.symbol(@enumFromInt(index)));
            return d;
        }
        seen += 1;
    }
    return d;
}

/// Whether `v`'s class is a nominal application's: a value that holds a
/// function, rather than a function (§15.4's wording).
pub fn isHolder(e: *const Effects, v: Var) bool {
    const r, _ = e.store.resolved(v);
    return switch (e.store.content(r)) {
        .structure => |s| s == .app,
        else => false,
    };
}

/// The variable a site's path reaches from the read's roots, or null for a
/// path this type does not have (a record from disk that lies).
pub fn follow(e: *Effects, iface: *const Interface, site: Interface.EffectBlock.Site, body: Var, quantified: []const Var) ?Var {
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
pub fn applyPlain(e: *Effects, iface: *const Interface, scheme: Interface.Scheme, method_type: Var, subs: []const Var.Optional, site_inst: u32) Error!void {
    const block = iface.effectBlock(scheme) orelse return;
    if (block.twin()) try e.uses.append(e.gpa, .{ .site = site_inst, .v = method_type });
    // The method's own arrow is the site at the body's root with no step.
    var own: ?u32 = null;
    var sites = block.sites();
    while (sites.next()) |site| {
        if (site.root == 0 and site.steps.len == 0) own = site.class;
    }
    // A `where` type's own arrow that must not suspend (§15.3): the sub-wanted
    // that answers it is demanded, whether or not the method depends on it.
    var it = block.sites();
    while (it.next()) |site| {
        if (site.root == 0 or site.steps.len != 0 or !block.class(site.class).sync) continue;
        const q = whereQuantifier(iface, scheme, site.root - 1) orelse continue;
        if (q >= subs.len) continue;
        const sub = subs[q].unwrap() orelse continue;
        var d = e.importedDemand(iface, scheme, block, site.class, sub, site_inst);
        d.v = sub;
        try e.demand(d);
    }
    const c = own orelse return;
    const class = block.class(c);
    const rung: Rung = @enumFromInt(@min(class.rung, 2));
    try e.seed(method_type, rung);
    if (rung == .suspends) try e.terminals.append(e.gpa, .{ .v = method_type, .site = site_inst });
    for (class.deps) |d| {
        var deps = block.sites();
        while (deps.next()) |site| {
            if (site.class != d or site.root == 0 or site.steps.len != 0) continue;
            // A `where` type's own arrow: which quantifier's?
            const q = whereQuantifier(iface, scheme, site.root - 1) orelse continue;
            if (q >= subs.len) continue;
            const sub = subs[q].unwrap() orelse continue;
            try e.uncalled(sub, method_type);
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
/// `sync`: a use must not let its copy suspend (§15.3).
/// `sensitive`: the declaration's body reads the class, so the declaration has
/// a second, suspendable body (§16.2; `EffectPlan`).
pub const Class = struct { node: u32, rung: Rung, deps_start: u32 = 0, deps_len: u32 = 0, sync: bool = false, sensitive: bool = false };

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
    /// Per edge: its index in `Effects.sites`, or `none` for one no call
    /// wrote (§15.4's chain reads the call).
    origin: std.ArrayList(u32) = .empty,
    /// Per node: a demand is on it (§15.2).
    demanded: std.ArrayList(bool) = .empty,
    /// The demands, on nodes, in the order they were met.
    sources: std.ArrayList(Source) = .empty,
    summaries: []Summary = &.{},
    /// The declarations in the order `run` solved them, dependencies first,
    /// and where each component starts: what `EffectPlan` walks in.
    order: []u32 = &.{},
    order_starts: []u32 = &.{},
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
        s.origin.deinit(gpa);
        s.demanded.deinit(gpa);
        s.sources.deinit(gpa);
        gpa.free(s.summaries);
        gpa.free(s.order);
        gpa.free(s.order_starts);
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
        try s.demanded.append(gpa, false);
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

    /// A new epoch: every mask reads 0 until set under it.
    fn nextEpoch(s: *Solved) void {
        s.epoch +%= 1;
        if (s.epoch == 0) {
            @memset(s.stamp.items, 0);
            s.epoch = 1;
        }
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

    e.scheme_decl = try gpa.dupe([2]u32, scheme_decl.pairs);

    // 2. The edges, and the rungs seeded so far.
    for (e.edges.items, 0..) |p, i| try e.addEdge(p.a, p.b, @intCast(i));
    for (in.wanted_edges) |p| try e.addEdge(p.a, p.b, none);
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(scratch);
    for (e.seeds.items) |sd| try e.raise(try e.nodeFor(sd.v), sd.rung, &work, scratch);
    try e.propagate(&work, scratch);
    // The demands recorded so far, on their nodes (§15.2). `main`'s and a
    // top-level value's are on its evaluation class, which is no type; every
    // other one is on a function type or a nominal application, and a
    // handler in its value form, which is neither, demands nothing.
    for (e.demands.items) |d| {
        // A top-level value's evaluation class is module-local and no
        // summary reaches it, so its demand is placed after the summaries
        // (below), where it costs them no walk.
        if (d.kind == .value) continue;
        if (d.kind != .main) {
            const r, _ = e.store.resolved(d.v);
            if (!e.carries(r)) continue;
        }
        try e.addSource(.{ .node = try e.nodeFor(d.v), .demand = d });
    }

    // 3. The `foreign` declarations' summaries: rule 6, off the signature;
    // and a markup primitive's, whose function parameters the page calls
    // (§15.2 item 3).
    for (in.bir.decls, 0..) |d, i| {
        if (d.kind != .foreign_value and d.kind != .vocab_markup) continue;
        const v = in.decl_scheme[i].unwrap() orelse continue;
        try e.foreignSummary(@intCast(i), v, d.rung, d.kind == .vocab_markup, scratch);
    }

    // 4. Every other declaration, dependencies first.
    const order = try e.dependencyOrder(in, scheme_decl, scratch);
    s.order = try gpa.dupe(u32, order.order);
    s.order_starts = try gpa.dupe(u32, order.starts);
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
    // each summary read when it was solved. A class that came to suspend
    // publishes no demand (§15.3).
    for (s.classes.items) |*c| {
        c.rung = s.level.items[c.node];
        if (c.rung == .suspends) c.sync = false;
    }
    // Top-level values' demands (§15.2 item 7), only where one is broken:
    // an evaluation class is on no path a summary reads.
    for (e.demands.items) |d| {
        if (d.kind != .value) continue;
        const node = try e.nodeFor(d.v);
        if (s.level.items[node] != .suspends) continue;
        try e.addSource(.{ .node = node, .demand = d });
    }
}

/// A demand on node `src.node` (§15.2, §15.3).
fn addSource(e: *Effects, src: Source) Error!void {
    const s = &e.solved;
    s.demanded.items[src.node] = true;
    try s.sources.append(e.gpa, src);
}

pub const none = std.math.maxInt(u32);

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

fn addEdge(e: *Effects, a: Var, b: Var, origin: u32) Error!void {
    const x = try e.nodeFor(a);
    const y = try e.nodeFor(b);
    if (x == y) return;
    try e.edgeNodes(x, y, origin);
}

/// `origin` is the edge's index in `sites`, or `none`.
fn edgeNodes(e: *Effects, x: u32, y: u32, origin: u32) Error!void {
    const s = &e.solved;
    try s.origin.append(e.gpa, origin);
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
            try e.edgeNodes(reps[c], i, none);
            try e.edgeNodes(i, reps[c], none);
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
            try e.edgeNodes(from, rep, none);
            try e.raise(rep, s.level.items[from], work, scratch);
        }
        // §15.3: the use's copy of a `sync` class must not suspend. Where
        // the class sits is read off `target`'s scheme when it is reported.
        if (c.sync) try e.addSource(.{
            .node = rep,
            .demand = .{ .v = @enumFromInt(none), .kind = .argument, .site = r.site, .decl = r.owner, .holder = try e.nodeIsHolder(r, ci, target) },
            .target = target,
            .class = @intCast(ci),
        });
    }
}

/// Whether record `r`'s copy of `target`'s class `ci` is a nominal
/// application's (`isHolder`).
fn nodeIsHolder(e: *Effects, r: Record, ci: usize, target: u32) Error!bool {
    for (e.pairs.items[r.start..][0..r.len]) |p| {
        if (e.solved.classIndex(target, try e.nodeFor(p.a)) == @as(u32, @intCast(ci))) return e.isHolder(p.b);
    }
    return false;
}

/// Read each member's summary off the graph: its scheme's classes, each
/// one's rung, and — 64 classes at a time, one bit each, pushed forward
/// along the edges — which of the declaration's other classes reach it.
/// True when a summary changed.
fn summarise(e: *Effects, in: Input, members: []const u32) Error!bool {
    const s = &e.solved;
    const scratch = in.scratch;
    var changed = false;
    const demands = s.sources.items.len != 0;
    for (members) |d| {
        const kind = in.bir.decls[d].kind;
        if (!kind.isValue() or kind == .foreign_value or kind == .vocab_markup) continue;
        const scheme = in.decl_scheme[d].unwrap() orelse continue;
        // The declaration's own root class publishes no demand (§15.3).
        const root: u32 = blk: {
            const r, _ = e.store.resolved(scheme);
            break :blk if (e.carries(r)) try e.nodeFor(r) else none;
        };
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
            const sync = demands and nd != root and s.level.items[nd] != .suspends and try e.reachesDemand(nd, scratch);
            if (old.len == 1 and old[0].node == nd and old[0].rung == s.level.items[nd] and old[0].sync == sync) continue;
            changed = true;
            s.summaries[d] = .{ .start = @intCast(s.classes.items.len), .len = 1 };
            try s.classes.append(e.gpa, .{ .node = nd, .rung = s.level.items[nd], .sync = sync });
            continue;
        }
        const reach = try scratch.alloc(bool, nodes.items.len);
        defer scratch.free(reach);
        @memset(reach, false);
        const deps = try e.dependencies(nodes.items, scratch, if (demands) reach else null);
        defer {
            for (deps) |list| scratch.free(list);
            scratch.free(deps);
        }
        for (nodes.items, reach) |nd, *r| r.* = r.* and nd != root and s.level.items[nd] != .suspends;
        // Compare with the summary in place, then replace it.
        const old = s.classesOf(d);
        var same = old.len == nodes.items.len;
        if (same) {
            for (old, nodes.items, deps, reach) |c, nd, ds, sync| {
                if (c.node != nd or c.rung != s.level.items[nd] or c.sync != sync or !std.mem.eql(u32, s.depsOf(c), ds)) same = false;
            }
        }
        if (same) continue;
        changed = true;
        const start: u32 = @intCast(s.classes.items.len);
        for (nodes.items, deps, reach) |nd, ds, sync| {
            const deps_start: u32 = @intCast(s.deps.items.len);
            try s.deps.appendSlice(e.gpa, ds);
            try s.classes.append(e.gpa, .{ .node = nd, .rung = s.level.items[nd], .deps_start = deps_start, .deps_len = @intCast(ds.len), .sync = sync });
        }
        s.summaries[d] = .{ .start = start, .len = @intCast(nodes.items.len) };
    }
    return changed;
}

/// Whether node `nd` reaches a demand along the edges, itself included
/// (§15.3): one walk under a fresh epoch.
fn reachesDemand(e: *Effects, nd: u32, scratch: Allocator) Error!bool {
    const s = &e.solved;
    s.nextEpoch();
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(scratch);
    s.orMask(nd, 1);
    try work.append(scratch, nd);
    while (work.pop()) |x| {
        if (s.demanded.items[x]) return true;
        var at = s.head.items[x];
        while (at != none) : (at = s.next.items[at]) {
            const y = s.find(s.to.items[at]);
            if (s.maskOf(y) != 0) continue;
            s.orMask(y, 1);
            try work.append(scratch, y);
        }
    }
    return false;
}

/// For each of `nodes`, the indices of the others that reach it, ascending;
/// and, into `reach` when given, whether each reaches a demand (§15.3) —
/// the same pass, since a node's bits are the nodes that reach it.
fn dependencies(e: *Effects, nodes: []const u32, scratch: Allocator, reach: ?[]bool) Error![][]u32 {
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
    // The demanded nodes a chunk's walk met.
    var met: std.ArrayList(u32) = .empty;
    defer met.deinit(scratch);
    var chunk: usize = 0;
    while (chunk < nodes.len) : (chunk += 64) {
        const end = @min(nodes.len, chunk + 64);
        // The bits live in a column over the nodes, valid under this pass's
        // epoch: no clearing, and no map keyed by a dense id.
        s.nextEpoch();
        met.clearRetainingCapacity();
        for (nodes[chunk..end], 0..) |nd, b| {
            s.orMask(nd, @as(u64, 1) << @intCast(b));
            try work.append(scratch, nd);
        }
        while (work.pop()) |x| {
            if (reach != null and s.demanded.items[x]) try met.append(scratch, x);
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
        if (reach) |out_reach| {
            // A demanded node's bits are the nodes of the chunk that reach
            // it; its bits are final once the walk is done.
            var reaching: u64 = 0;
            for (met.items) |x| reaching |= s.maskOf(x);
            for (chunk..end) |j| {
                if (reaching & (@as(u64, 1) << @intCast(j - chunk)) != 0) out_reach[j] = true;
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
fn foreignSummary(e: *Effects, decl: u32, scheme: Var, rung: Rung, markup: bool, scratch: Allocator) Error!void {
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
    var sync: std.ArrayList(bool) = .empty;
    defer sync.deinit(scratch);
    // The function types P2 found marked `sync` in this declaration (§15.2 item 1).
    var marked: std.ArrayList(u32) = .empty;
    defer marked.deinit(scratch);
    for (e.foreign_syncs.items) |f| if (f.decl == decl) try marked.append(scratch, try e.nodeFor(f.v));
    const Item = struct { v: Var, positive: bool, evidence: bool, where_root: bool = false };
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
                for (0..set.count(store)) |i| try stack.append(scratch, .{ .v = set.at(store, @intCast(i)).fn_var, .positive = false, .evidence = true, .where_root = true });
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
                // `sync` (§15.2): a function type the platform marked; the
                // evidence the sibling calls from JavaScript (item 2); a
                // markup primitive's function parameter, which the page
                // calls (item 3).
                const is_func = switch (store.content(r)) {
                    .structure => |st| st == .func,
                    else => false,
                };
                try sync.append(scratch, std.mem.indexOfScalar(u32, marked.items, nd) != null or item.where_root or (markup and is_func and !item.positive and !item.evidence));
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
    for (nodes.items, positive.items, evidence.items, sync.items) |nd, pos, _, is_sync| {
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
            .sync = is_sync and nd != own,
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
/// with a rung, a dependency (a dependant needs one to depend on it) or a
/// demand (§15.5).
/// Most schemes do not, and their block is `no_terms` at no cost.
pub fn publishes(e: *const Effects, decl: u32) bool {
    for (e.solved.classesOf(decl)) |c| {
        if (c.rung != .pure or c.deps_len != 0 or c.sync or c.sensitive) return true;
    }
    return false;
}

/// The block of `decl`'s scheme, appended to the record's `extra`: in
/// `EffectsBlock.zig`.
pub const writeBlock = @import("EffectsBlock.zig").write;

// ---------------------------------------------------------------------------
// What the dumps print (§14.7): `EffectsView.zig`
// ---------------------------------------------------------------------------

pub const View = @import("EffectsView.zig").View;
