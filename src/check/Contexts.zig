//! Derived contexts (checker-v2.md §11.1, §11.2): the
//! ONE answer to "what does `T args` need to derive `eq` or `compare`", for
//! every own nominal type of the module. The derivability verdict
//! (`Instances.derivability`), derivation at a use (`Instances`), P5's rows
//! (`Eager`) and publication (`Publish`) all read it; nothing else decides it.
//!
//! **A context** is a set of entries `(i, m', τ)`: to answer the method on
//! `T args`, `args[i]` must answer `m'` at type `τ`. `τ` is the well-known
//! `a, a -> Bool | Order` for `eq` and `compare`, and otherwise a TEMPLATE —
//! the method type over the type's own template parameters
//! (`Instantiate.freeze`), which a use instantiates with its arguments.
//!
//! **One fixpoint per unit.** A unit is a strongly connected component of
//! the module's "payload mentions" graph over its own `type`s (read off the
//! declarations' `top_type` references, through aliases). A run computes
//! every `(X, m)` of its unit together, for both methods, in a frame of its
//! own (`.fixpoint`, rank `top + 1`): every entry starts at `present(∅)`, and
//! a PASS for `(X, m)` reads `X`'s constructor payloads with each parameter
//! bound to a fresh flex MARKER, resolves one `(payload, m)` wanted per
//! position with the ordinary resolver (§9.3 in full), drains, and reads the
//! answer off what is left: every wanted still OPEN on marker `i` is the
//! entry `(i, its method, its type)` (Rule U1 keeps one per name); a failed
//! position is `absent`; a marker a specialised instance bound to a ground
//! type is a PIN (the type derives only at that argument), and one
//! that became anything else but a distinct plain flex is `absent`. A worklist
//! re-runs exactly the passes that read an entry that grew; entries only
//! move up the lattice `present(∅) ⊂ present(more) ⊂ absent`, so it ends.
//!
//! **Reading the approximation, or running fresh** (§11.2). A
//! query for a type of unit `U` reads the approximation of `U`'s innermost
//! run when no top-level-kind group frame lies above that run's frame (the
//! run's own passes, and anything they ask directly); when one does — the
//! run's resolution nested a group whose body asks again — it runs a FRESH
//! fixpoint for `U`. Dependency units are run first, in order, so a chain of
//! types never recurses natively (no walk stops at a fixed depth).
//!
//! **In flight** (§11.2's closed and parametric branches). A pass that meets
//! an own unannotated method whose group is `checking` does not link it
//! (`inFlight`): a receiver that reaches no marker is CLOSED, contributes no
//! entry and is recorded for REPLAY; one that reaches a marker makes the
//! entry `needs_annotation`, naming the method. A unit's result is memoised
//! permanently when it read nothing in flight; otherwise under the current
//! GENERATION (bumped whenever a group completes), with its replay list: every
//! asker that reads it — the first, and every later one in the generation —
//! gets one ordinary `(receiver, method)` wanted per replay item, in its own
//! frame, which the ordinary resolver links (§10.3) and merges (§10.4). A
//! unit graph is exact before a run (`complete`), so no run reads another's.
//!
//! Everything a run resolves is reported QUIETLY (one report for the module,
//! made once): a payload that cannot answer is an `absent` entry, never a
//! message about code nobody wrote at this use. An `internal` is still said.
//! A group a pass nests is checked with the module's own report.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Dispatch = @import("Dispatch.zig");
const Scc = @import("Scc.zig");
const Schema = @import("Schema.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Context = @import("Context.zig");
const Decide = @import("Decide.zig");
const Evidence = @import("Evidence.zig");
const Generalize = @import("Generalize.zig");
const Groups = @import("Groups.zig");
const Report = @import("Report.zig");
const Resolve = @import("Resolve.zig");
const Solve = @import("Solve.zig");
const Walk = @import("Walk.zig");
const ContextUnits = @import("ContextUnits.zig");

const Contexts = @This();

const Var = TypeStore.Var;
const Symbol = InternPool.Symbol;
pub const Kind = Dispatch.Derived.Kind;
pub const Error = Allocator.Error;
pub const none = std.math.maxInt(u32);

pub const Status = enum(u8) {
    /// The type derives the method, with the context in `entries`.
    present,
    /// Not derived: the module declares a value of the method's name, `pub`
    /// or not, which the module rule makes every one of its types' method
    /// (§11.3): `module_pub` says which.
    own_method,
    /// A `foreign type`: no body to derive over.
    foreign,
    /// A payload cannot answer the method: a function reachable, or else.
    absent_function,
    absent_other,
    /// A payload reaches another module's private method (§11.2, §11.3):
    /// `culprit` is the type whose module declares it (a `TypeId`, so an
    /// importer can be told which, §14.2), `method` its name.
    absent_private,
    /// §11.2's parametric in-flight case: `culprit` names the method.
    needs_annotation,
    /// A pass ran out of the resolver's step budget: no
    /// answer, and the use says `nesting_too_deep` — never an absent that
    /// reads as "does not support".
    absent_budget,
    /// A payload's method exists and has the wrong type for a requirement
    /// the pass made of it (static-dispatch-spike.md §10.13):
    /// `culprit` is the `TypeId` whose method it is, `method` its name.
    absent_requirement,
    /// A payload position met `err` and nothing else failed (checker-v2.md
    /// §12.2): that `err` has its message,
    /// said where it was made, so the type's method is no answer and the
    /// use is `poisoned`, in silence — never "does not support `==`".
    poisoned,
};

/// One context entry: `args[param]` must answer `method`, at the well-known
/// type (`slot` none) or at element `slot` of its answer's `template`.
pub const Entry = struct { param: u16, method: Symbol, slot: u32 = none };
pub const Range = struct { start: u32 = 0, len: u32 = 0 };

/// A PIN (§11.2): a payload's specialised
/// method (`H.eq : Holder Int, Holder Int -> Bool`) bound marker `param` to
/// the ground type at element `slot` of the answer's `template`. The type
/// derives only where `args[param]` is that type: a use unifies the two, and
/// no evidence rides on a pin, so it is no entry and no row parameter: a
/// derived function takes one evidence parameter per context entry.
pub const Pin = struct { param: u16, slot: u32 };

pub const Answer = struct {
    status: Status,
    /// `present`: a run of `entries`, sorted by `(param, method text)`.
    entries: Range = .{},
    /// `present`: a run of `pins`, by param.
    pins: Range = .{},
    /// `needs_annotation`: the in-flight method's declaration;
    /// `absent_private`: the `TypeId` whose module holds the private method;
    /// `absent_requirement`: the `TypeId` whose method failed; `present`
    /// with pins: the `TypeId` whose specialised method made the first pin,
    /// when the pass could tell (else `none`).
    culprit: u32 = none,
    /// `absent_private`, `absent_requirement`, a pin's culprit: the method's
    /// name.
    method: Symbol = undefined,
    /// `absent_requirement`: the first payload whose position failed, by
    /// its index in `readPayloads`' order (constructors in declaration
    /// order, arguments left to right), for the message.
    payload: u32 = none,
    /// `present`: one frozen tuple of the method types of every entry whose
    /// method is not `eq` or `compare`, over the type's template parameters
    /// (`paramsOf`), an entry's `slot` its element. One tuple per answer, so a
    /// use substitutes the arguments once and a row publishes one scheme,
    /// however many entries it has.
    template: Var.Optional = .none,
};

/// A closed in-flight method a run met: replayed for every asker (§11.2).
/// `template` is the frozen tuple `( receiver, method type )`. Or, `post`, a
/// closed type whose payloads a pass could not read because a schema they
/// go through is in flight (§11.5): replayed
/// as a DEFERRED check of `type_id`'s `method`, made once P4 is over.
const Replay = struct { slot: u32, decl: u32, method: Symbol, template: Var = undefined, post: bool = false, type_id: Types.TypeId = .none };

/// A comparison answered while a schema its type's payloads go through was
/// in flight: checked in P5, when every group is done (`checkDeferred`).
pub const DeferredGate = struct { type_id: Types.TypeId, v: Var, region: Bir.Inst.Index, origin: @import("Obligations.zig").Id, decl: ?u32 };

pub const Deferred = struct { type_id: Types.TypeId, method: Symbol, origin: Bir.Inst.Index, wanted: Evidence.WantedId.Optional, decl: ?u32 };

const Memo = enum(u8) { none, permanent, generational };

/// One fixpoint in progress (§11.2's frame `F`), by index: runs nest, and
/// the list may move while a nested one is pushed.
const Run = struct {
    unit: u32,
    /// Its frame's index on the solver's stack.
    frame: u32,
    /// Per member × method (`slot = member * 2 + kind`): the approximation.
    approx: []Answer,
    queued: []bool,
    worklist: std.ArrayList(u32) = .empty,
    /// `(reader, read)` slot pairs: when `read` grows, `reader` runs again.
    deps: std.ArrayList([2]u32) = .empty,
    in_flight: std.ArrayList(Replay) = .empty,
    /// The pass in progress, its markers, and what it met.
    current: u32 = none,
    markers: []const Var = &.{},
    culprit: u32 = none,
    saw_function: bool = false,
    /// The pass met another module's private method: the type whose module
    /// declares it, and its name.
    private: ?struct { type_id: Types.TypeId, method: Symbol } = null,
    /// The pass met a payload's method of the wrong type for a requirement
    /// the type whose method it is, and its name.
    requirement: ?struct { type_id: Types.TypeId, method: Symbol } = null,
    /// It read another run's approximation, which an exact unit graph
    /// rules out (`noteApprox`): not memoised, and `internal`.
    stray: bool = false,
    /// It read a generational result: memoised under the generation only.
    generational: bool = false,
    /// Per slot: its last pass's positions, committed to `bodies` with the
    /// answers when the run is memoised permanently (a nested fresh run of
    /// the same unit must not leave its bodies beside the outer run's
    /// answers).
    bodies: []Body = &.{},
};

cx: *const Context,
/// The module's type range in the session table.
start: u32 = 0,
count: u32 = 0,
/// Per local type: its unit (`none` for a type no fixpoint answers — an
/// alias, a `foreign type`, a schema endpoint) and its index in the unit.
unit_of: []u32 = &.{},
member_of: []u32 = &.{},
/// The units: per unit a run of `unit_members` (ascending; a retired
/// unit's is empty). Unit ids are never reused or renumbered.
unit_start: std.ArrayList(u32) = .empty,
unit_len: std.ArrayList(u32) = .empty,
unit_members: std.ArrayList(u32) = .empty,
/// Per unit (views of the lists below, which `pushUnit` grows).
memo: []Memo = &.{},
memo_gen: []u32 = &.{},
replay_of: []Range = &.{},
memo_list: std.ArrayList(Memo) = .empty,
memo_gen_list: std.ArrayList(u32) = .empty,
replay_list: std.ArrayList(Range) = .empty,
seen_list: std.ArrayList(u32) = .empty,
/// Per local type × method, the last computed answer.
answers: []Answer = &.{},
entries: std.ArrayList(Entry) = .empty,
pins: std.ArrayList(Pin) = .empty,
replays: std.ArrayList(Replay) = .empty,
/// Per local type, its template parameters (a run of `param_vars`), made
/// when first needed.
params: []Range = &.{},
param_vars: std.ArrayList(Var) = .empty,
runs: std.ArrayList(Run) = .empty,
/// How many unit fixpoints this module ran (`run`), for the
/// `derived_context_runs` counter: the witness that whether `T` answers `m`
/// has one answer per module (checker-v2.md §14.3). A cache hit runs none,
/// because nothing of the check runs.
runs_total: u64 = 0,
/// Bumped whenever a group completes (§11.2, *Memo generations*).
generation: u32 = 0,
/// The module declares a value named `eq` / `compare`, `pub` or not: the
/// module rule answers every type of the module with it, so none derives
/// (§11.3, as amended 2026-09-24).
module_has: [2]bool = .{ false, false },
/// ... and that value is `pub`: an importer may call it (`own_method` in
/// the record), where a private one is `private_method` there (§14.2).
module_pub: [2]bool = .{ false, false },
/// The one quiet report every run resolves under, made on first use.
quiet: ?*Report = null,
quiet_items: std.ArrayList(Report.Item) = .empty,
/// A stamp per unit for `ensure`'s walk.
seen: []u32 = &.{},
walks: u32 = 0,
/// The module declares a schema.
has_schemas: bool = false,
/// §11.4's gate per local type (`Marker.functionFree`): known for
/// `gate_gen` (the generation, or 0 for good in a module without schemas),
/// `gate_seen` a stamp per walk.
gate_gen: []u32 = &.{},
gate_ok: []bool = &.{},
gate_seen: []u32 = &.{},
gate_walk: u32 = 0,
/// §11.4 gates the marker walk found unknown (a schema in flight), asked
/// again in P5 (`checkDeferred`).
deferred_gates: std.ArrayList(DeferredGate) = .empty,
/// Comparisons of closed types answered while a schema their payloads go
/// through was in flight, checked in P5 (`checkDeferred`).
deferred: std.ArrayList(Deferred) = .empty,
/// The mentions graph: `edges` from the declarations (a CSR by
/// `edge_start`), and `extra_adj`, per local type, the mentions its `via`
/// targets add once their groups are done (`complete`). `rebuilds` counts
/// the unit merges, which `ensure` watches. `completed`: a type whose
/// reach is exact (every schema it reaches done and added); `reached` and
/// `local_index` are `complete`'s, `edge_seen` `viaEdges`'s scratch.
edges: []const u32 = &.{},
edge_start: []u32 = &.{},
extra_adj: []std.ArrayList(u32) = &.{},
rebuilds: u32 = 0,
completed: []bool = &.{},
reached: []u32 = &.{},
reach_walk: u32 = 0,
local_index: []u32 = &.{},
edge_seen: []u32 = &.{},
edge_walk: u32 = 0,
/// Per declaration: a schema with a `via`, and whether its targets'
/// mentions are edges yet. `via_refs` are the `(type, schema)` pairs of a
/// type that reads such a schema's payloads (its own endpoint's, a record
/// schema it names), indexed by type (`refs_by_type`) and by schema
/// (`refs_by_decl` over `referrers`) on first use.
has_via: []bool = &.{},
via_added: []bool = &.{},
via_refs: std.ArrayList([2]u32) = .empty,
refs_by_type: []u32 = &.{},
refs_by_decl: []u32 = &.{},
referrers: std.ArrayList(u32) = .empty,
/// Per local type × method: the last pass's positions of a run memoised
/// permanently, which P5 (`Eager`) takes as the row's body, so no payload
/// is read twice.
bodies: []Body = &.{},

/// One pass's markers and position wanteds (`Eager.Row`'s body).
pub const Body = struct { markers: []const Var = &.{}, ids: []const Evidence.WantedId = &.{}, set: bool = false };

pub fn methodName(kind: Kind) Symbol {
    return switch (kind) {
        .eq => InternPool.WellKnown.eq.symbol(),
        .compare => InternPool.WellKnown.compare.symbol(),
    };
}

pub fn kindOf(name: Symbol) Kind {
    return if (name == InternPool.WellKnown.eq.symbol()) .eq else .compare;
}

/// The units and their dependencies, from the module's declarations (P1).
pub fn init(cx: *const Context) Error!Contexts {
    const scratch = cx.scratch;
    const types = cx.types;
    const bir = cx.bir;
    var c: Contexts = .{ .cx = cx };
    // A value of the method's name, `pub` or not: the module rule answers
    // every type of the module with it, and none derives (§11.3). A
    // private one answers only this module's uses; from any other module,
    // reaching it — directly or through anything derived — is
    // `private_method`, and no row is derived or published for it
    // (`dispatch/PrivateEqStillDerives`).
    for (bir.decls) |d| {
        if (d.kind == .schema) c.has_schemas = true;
        if (!d.kind.isValue()) continue;
        const name = bir.symbol(d.name);
        inline for (.{ InternPool.WellKnown.eq, InternPool.WellKnown.compare }, 0..) |wk, k| {
            if (name == wk.symbol()) {
                c.module_has[k] = true;
                if (d.is_pub) c.module_pub[k] = true;
            }
        }
    }
    const m = cx.module.int();
    if (m + 1 >= types.entry_offsets.len) return c;
    c.start = types.entry_offsets[m];
    c.count = types.entry_offsets[m + 1] - c.start;
    const n = c.count;
    c.unit_of = try scratch.alloc(u32, n);
    @memset(c.unit_of, none);
    c.member_of = try scratch.alloc(u32, n);
    c.extra_adj = try scratch.alloc(std.ArrayList(u32), n);
    c.gate_gen = try scratch.alloc(u32, n);
    @memset(c.gate_gen, none);
    c.gate_ok = try scratch.alloc(bool, n);
    c.gate_seen = try scratch.alloc(u32, n);
    @memset(c.gate_seen, 0);
    @memset(c.extra_adj, .empty);
    c.answers = try scratch.alloc(Answer, n * 2);
    @memset(c.answers, .{ .status = .absent_other });
    c.params = try scratch.alloc(Range, n);
    @memset(c.params, .{});
    c.bodies = try scratch.alloc(Body, n * 2);
    @memset(c.bodies, .{});

    // The mentions graph over the module's own `type`s.
    var edges: std.ArrayList(u32) = .empty;
    c.edge_start = try scratch.alloc(u32, n + 1);
    // Per declaration, the last type whose payloads expanded it as an alias.
    const expanded = try scratch.alloc(u32, bir.decls.len);
    @memset(expanded, none);
    // Per local type, the last type whose edges named it: a stamp, so a
    // payload that mentions many types costs its mentions, not their square.
    const named = try scratch.alloc(u32, n);
    @memset(named, none);
    if (c.has_schemas) {
        c.has_via = try scratch.alloc(bool, bir.decls.len);
        @memset(c.has_via, false);
        for (cx.schemas.vias.items) |via| c.has_via[via.owner.int()] = true;
        c.via_added = try scratch.alloc(bool, bir.decls.len);
        @memset(c.via_added, false);
    }
    for (0..n) |t| {
        c.edge_start[t] = @intCast(edges.items.len);
        if (!c.derives(@intCast(t))) continue;
        const entry = types.entry(c.id(@intCast(t)));
        const d = bir.decls[entry.decl.int()];
        // An endpoint's own `via` targets are mentions too (below).
        if (entry.schema_endpoint and !c.isEncoded(@intCast(t))) try c.noteVia(@intCast(t), entry.decl.int());
        try c.mentions(d, &edges, @intCast(t), named, expanded);
    }
    c.edge_start[n] = @intCast(edges.items.len);
    c.edges = edges.items;
    c.completed = try scratch.alloc(bool, n);
    @memset(c.completed, false);
    c.reached = try scratch.alloc(u32, n);
    @memset(c.reached, 0);
    c.local_index = try scratch.alloc(u32, n);
    c.edge_seen = try scratch.alloc(u32, n);
    @memset(c.edge_seen, 0);
    try c.initUnits();
    return c;
}

// The unit graph lives in `ContextUnits.zig` (checker-v2.md §19.1).
pub const initUnits = ContextUnits.initUnits;
pub const pushUnit = ContextUnits.pushUnit;
pub const membersOf = ContextUnits.membersOf;
pub const unitCount = ContextUnits.unitCount;
pub const noteVia = ContextUnits.noteVia;
pub const complete = ContextUnits.complete;
pub const reach = ContextUnits.reach;
pub const merge = ContextUnits.merge;
pub const indexVias = ContextUnits.indexVias;
pub const viaEdges = ContextUnits.viaEdges;
pub const mentions = ContextUnits.mentions;

pub fn deinit(c: *Contexts) void {
    const gpa = c.cx.gpa;
    if (c.quiet) |q| {
        q.deinit();
        gpa.destroy(q);
    }
    for (c.quiet_items.items) |item| gpa.free(item.message);
    c.quiet_items.deinit(gpa);
}

fn id(c: *const Contexts, t: u32) Types.TypeId {
    return @fromBackingInt(@intCast(c.start + t));
}

/// Whether the module rule answers `kind` for this module's type `type_id`:
/// the module has a value of the name (§11.3), and §3.2's table has no row
/// for it — the table is consulted before the module rule
/// (`Instances.onApp`). `core/Basics.beni` declares `Order` and `Never`
/// beside `pub compare : number, number -> Order` and `pub foreign eq`, and
/// the table derives `Order`'s `compare` and both of `Never`'s
/// (static-dispatch-spike.md §3.2). Their rows must say so, or an importer
/// finds no `compare` for `Order` (which `core` itself relies on).
pub fn moduleRuleAnswers(c: *const Contexts, type_id: Types.TypeId, kind: Kind) bool {
    if (!c.module_has[@backingInt(kind)]) return false;
    return tableRow(c.cx.types, type_id, kind) == null;
}

/// Whether `kind` on this module's `type_id` is answered by no derived
/// context of its own: the module rule's method, or §3.2's `primitive` row
/// (`Bool` and `Order`'s `eq` in `core/Basics.beni`, whatever values the
/// module declares). Read as `own_method`: nothing is
/// derived, and nothing is emitted for it (P5).
pub fn notDerived(c: *const Contexts, type_id: Types.TypeId, kind: Kind) bool {
    return tableRow(c.cx.types, type_id, kind) == .primitive or c.moduleRuleAnswers(type_id, kind);
}

/// A row of §3.2's table (static-dispatch-spike.md §3.2).
pub const TableRow = enum { primitive, derived };

/// THE statement of §3.2's table: `eq` and `compare`
/// on `Int`, `Float`, `Bool`, `Char` and `String`, and `Order`'s `eq`,
/// are `primitive`; `Order`'s `compare` (not alphabetic) and both of
/// `Never`'s are `derived`; any other type has no row. The resolver
/// (`Instances.wellKnownAnswer`), the verdict walk, the contexts and the
/// published rows (`Publish`) all read it.
pub fn tableRow(types: *const Types, type_id: Types.TypeId, kind: Kind) ?TableRow {
    const wk = types.well_known;
    if (type_id == .none) return null;
    if (type_id == wk.int or type_id == wk.float or type_id == wk.bool or type_id == wk.char or type_id == wk.string) return .primitive;
    if (type_id == wk.order) return if (kind == .eq) .primitive else .derived;
    if (type_id == wk.never) return .derived;
    return null;
}

/// The module-local index of type `type_id`, if it is this module's.
pub fn local(c: *const Contexts, type_id: Types.TypeId) ?u32 {
    if (type_id == .none) return null;
    const i = type_id.int();
    if (i < c.start or i - c.start >= c.count) return null;
    return i - c.start;
}

/// Whether a fixpoint answers local type `t`: a nominal `type` of this
/// module, a tagged schema's two endpoints among them (§11.5). A record
/// schema's endpoints are aliases, whose expansion answers.
pub fn derives(c: *const Contexts, t: u32) bool {
    const e = c.cx.types.entry(c.id(t));
    return e.module == c.cx.module and e.kind == .adt;
}

pub fn entriesOf(c: *const Contexts, a: Answer) []const Entry {
    return c.entries.items[a.entries.start..][0..a.entries.len];
}

pub fn pinsOf(c: *const Contexts, a: Answer) []const Pin {
    return c.pins.items[a.pins.start..][0..a.pins.len];
}

/// Local type `t`'s template parameters, made once: generalised flexes, one
/// per type parameter, with the parameter's name.
pub fn paramsOf(c: *Contexts, t: u32) Error![]const Var {
    const cx = c.cx;
    if (c.params[t].len == 0) {
        const d = cx.bir.decls[cx.types.entry(c.id(t)).decl.int()];
        const names = cx.bir.declTypeParams(d);
        if (names.len == 0) return &.{};
        const first: u32 = @intCast(c.param_vars.items.len);
        for (names) |p| {
            try c.param_vars.append(cx.scratch, try cx.store.fresh(.{ .flex = .{ .name = p.toOptional() } }, TypeStore.generalized));
        }
        c.params[t] = .{ .start = first, .len = @intCast(names.len) };
    }
    return c.param_vars.items[c.params[t].start..][0..c.params[t].len];
}

/// The final answer for local type `t` (P5, P8): valid once `settleAll` ran.
pub fn final(c: *const Contexts, t: u32, kind: Kind) Answer {
    return c.answers[t * 2 + @backingInt(kind)];
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

/// Whether any top-level-kind frame lies above frame `frame`.
fn groupAbove(s: *const Solve, frame: u32) bool {
    for (s.frames.items[frame + 1 ..]) |f| {
        if (f.kind == .top) return true;
    }
    return false;
}

/// The innermost run, when the resolution now running is its own — no
/// top-level-kind group frame above it: a pass, or a query a pass made
/// directly.
pub fn active(c: *const Contexts, s: *const Solve) ?u32 {
    if (c.runs.items.len == 0) return null;
    const ri: u32 = @intCast(c.runs.items.len - 1);
    if (groupAbove(s, c.runs.items[ri].frame)) return null;
    return ri;
}

/// The run of unit `u` whose approximation a query reads (§11.2): the
/// innermost run of `u`, when no group frame is above it.
fn readable(c: *const Contexts, s: *const Solve, u: u32) ?u32 {
    var i = c.runs.items.len;
    while (i > 0) {
        i -= 1;
        if (c.runs.items[i].unit != u) continue;
        return if (groupAbove(s, c.runs.items[i].frame)) null else @intCast(i);
    }
    return null;
}

fn valid(c: *const Contexts, u: u32) bool {
    return switch (c.memo[u]) {
        .none => false,
        .permanent => true,
        .generational => c.memo_gen[u] == c.generation,
    };
}

/// What the resolution now running learnt by reading answer `slot` of run
/// `ri`: a pass of the same run depends on it.
fn noteApprox(c: *Contexts, s: *const Solve, ri: u32, slot: u32) Error!void {
    const reader = c.active(s) orelse return;
    const r = &c.runs.items[reader];
    if (reader != ri) {
        // Never, once the unit graph is exact (`complete`):
        // a run started inside `ri`'s pass that reads `ri`'s unit would make
        // the two one strongly connected component, so one unit. Were it to
        // happen, the reader is not memoised and the compiler says so
        // (`run`), rather than answer from an approximation.
        if (std.debug.runtime_safety) std.debug.panic("a derived-context run read another unit's approximation (checker-v2.md §11.2, §11.5)", .{});
        r.stray = true;
        return;
    }
    if (r.current == none) return;
    try r.deps.append(c.cx.scratch, .{ r.current, slot });
}

/// A run reading a memoised result inherits its generation.
fn noteMemo(c: *Contexts, s: *const Solve, u: u32) void {
    const reader = c.active(s) orelse return;
    if (c.memo[u] == .generational) c.runs.items[reader].generational = true;
}

/// The answer for `(type_id, kind)` when it can be had without running a
/// fixpoint — the verdict walk's read (`Instances.derivability`), which
/// replays nothing — or null, when `query` must run one.
pub fn peek(c: *Contexts, s: *const Solve, type_id: Types.TypeId, kind: Kind) Error!?Answer {
    const t = c.local(type_id) orelse return .{ .status = .absent_other };
    const u = c.unit_of[t];
    if (u == none) return .{ .status = .absent_other };
    if (c.notDerived(type_id, kind)) return .{ .status = .own_method };
    if (c.readable(s, u)) |ri| {
        const slot = c.member_of[t] * 2 + @backingInt(kind);
        try c.noteApprox(s, ri, slot);
        return c.runs.items[ri].approx[slot];
    }
    if (!c.valid(u)) return null;
    c.noteMemo(s, u);
    return c.answers[t * 2 + @backingInt(kind)];
}

/// The answer for `(type_id, kind)` for a wanted at `origin` that derives
/// it: the current approximation, the memo, or a fixpoint run now. A result
/// read from the memo (or just computed) is REPLAYED for this asker
/// (§11.2): one ordinary wanted per closed in-flight method it reached.
pub fn query(s: *Solve, type_id: Types.TypeId, kind: Kind, origin: Bir.Inst.Index, asker: Evidence.WantedId) Error!Answer {
    const c = &s.contexts;
    if (try c.peek(s, type_id, kind)) |a| {
        const t = c.local(type_id).?;
        const u = c.unit_of[t];
        // Only a valid memo's replay list is this generation's: a `peek`
        // that answered without one (`own_method`) replays nothing.
        if (u != none and c.valid(u) and c.readable(s, u) == null) try replay(s, u, kind, origin, asker);
        return a;
    }
    const t = c.local(type_id).?;
    const u = c.unit_of[t];
    try ensure(s, u);
    c.noteMemo(s, u);
    try replay(s, u, kind, origin, asker);
    return c.answers[t * 2 + @backingInt(kind)];
}

/// Unit `u`'s result, computed if it is not valid: its dependencies first,
/// in order, so no chain of types recurses natively.
pub fn ensure(s: *Solve, unit: u32) Error!void {
    const c = &s.contexts;
    // A unit is named by a member across a merge (`complete`).
    const rep = c.membersOf(unit)[0];
    while (true) {
        const u = c.unit_of[rep];
        if (c.valid(u)) return;
        _ = try complete(s, &.{rep});
        if (try c.walk(s, c.unit_of[rep])) return;
    }
}

/// `ensure`'s walk: `u`'s dependencies first — the units its members'
/// edges reach — then `u`. False when a run merged units (a nested query
/// completed another part of the graph), so the walk starts again: every
/// unit it ran is memoised, and no memoised unit merges.
fn walk(c: *Contexts, s: *Solve, u: u32) Error!bool {
    const rebuilds = c.rebuilds;
    c.walks += 1;
    const stamp = c.walks;
    // A unit on the stack, its next member, and that member's next edge
    // (its declared edges, then its `via` ones).
    const Item = struct { unit: u32, member: u32 = 0, edge: u32 = 0 };
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(c.cx.scratch);
    try stack.append(c.cx.scratch, .{ .unit = u });
    c.seen[u] = stamp;
    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        const members = c.membersOf(top.unit);
        if (top.member < members.len) {
            const t = members[top.member];
            const declared = c.edge_start[t + 1] - c.edge_start[t];
            const total = declared + @as(u32, @intCast(c.extra_adj[t].items.len));
            if (top.edge >= total) {
                top.member += 1;
                top.edge = 0;
                continue;
            }
            const to = if (top.edge < declared) c.edges[c.edge_start[t] + top.edge] else c.extra_adj[t].items[top.edge - declared];
            top.edge += 1;
            const v = c.unit_of[to];
            if (v == none or c.seen[v] == stamp or c.valid(v) or c.readable(s, v) != null) continue;
            c.seen[v] = stamp;
            try stack.append(c.cx.scratch, .{ .unit = v });
            continue;
        }
        const done = stack.pop().?.unit;
        if (done == u or (!c.valid(done) and c.readable(s, done) == null)) {
            try run(s, done);
            if (c.rebuilds != rebuilds) return false;
        }
    }
    return true;
}

/// P5, first: the comparisons deferred while a schema was in flight
/// (§11.5), each checked against the one verdict now
/// that every group is done; a refusal is said at its use, which is
/// rejected, so P6 elaborates no answer that has no row.
pub fn checkDeferred(s: *Solve) Error!void {
    const c = &s.contexts;
    const scratch = c.cx.scratch;
    const items = try scratch.dupe(Deferred, c.deferred.items);
    defer scratch.free(items);
    c.deferred.clearRetainingCapacity();
    const Derivable = @import("Derivable.zig");
    const Marker = @import("Marker.zig");
    // One report per use, type and method (a use can replay an item twice).
    var said: std.AutoHashMapUnmanaged(struct { Types.TypeId, Symbol, Bir.Inst.Index }, void) = .empty;
    defer said.deinit(scratch);
    for (items) |d| {
        if ((try said.getOrPut(scratch, .{ d.type_id, d.method, d.origin })).found_existing) continue;
        const v = try c.cx.store.fresh(.{ .structure = .{ .app = .{ .type = d.type_id, .args = .empty } } }, TypeStore.generalized);
        const verdict = try Derivable.settledVerdict(s, v, kindOf(d.method));
        if (verdict == .ok) continue;
        const saved = s.report.current;
        defer s.report.at(saved);
        s.report.at(d.decl);
        const kind: Evidence.Kind = if (d.wanted.unwrap()) |wanted| s.evidence.get(wanted).kind else .well_known;
        try Derivable.report(s, d.origin, v, d.method, verdict, kind);
        if (d.wanted.unwrap()) |w| try Resolve.reject(s, w, false);
    }
    // The §11.4 gates a marker walk could not read: the obligation's
    // question, asked again of the type now that every
    // group is done; one message per question, as the walk says it.
    const gates = try scratch.dupe(DeferredGate, c.deferred_gates.items);
    defer scratch.free(gates);
    c.deferred_gates.clearRetainingCapacity();
    for (gates) |g| {
        if (s.obligations.row(g.origin).reported) continue;
        if ((try Marker.functionFree(c.cx, c, null, g.type_id)) orelse true) continue;
        s.obligations.rowPtr(g.origin).reported = true;
        const saved = s.report.current;
        defer s.report.at(saved);
        s.report.at(g.decl);
        try s.report.notEquatable(g.region, g.v, .opaque_type, .{ .marker = s.obligations.row(g.origin).call });
    }
}

/// P5: every unit's final result, from `done` inputs (P4 is over), in
/// dependency order — the graph completed over every type first, so no
/// `via` mention is missing.
pub fn settleAll(s: *Solve) Error!void {
    const c = &s.contexts;
    s.resolver.steps = 0;
    if (c.via_refs.items.len != 0) {
        const all = try c.cx.scratch.alloc(u32, c.count);
        defer c.cx.scratch.free(all);
        for (all, 0..) |*t, i| t.* = @intCast(i);
        _ = try complete(s, all);
    }
    // Every result not memoised permanently is computed again, from `done`
    // inputs, dependencies first (`ensure`'s walk).
    for (0..c.unitCount()) |u| {
        if (c.unit_len.items[u] != 0 and c.memo[u] != .permanent) c.memo[u] = .none;
    }
    for (0..c.unitCount()) |u| {
        if (c.unit_len.items[u] == 0 or c.valid(@intCast(u))) continue;
        try ensure(s, @intCast(u));
    }
}

/// One replay item per closed in-flight method unit `u`'s result reached:
/// an ordinary wanted in the asker's frame (§11.2).
fn replay(s: *Solve, u: u32, kind: Kind, origin: Bir.Inst.Index, asker: Evidence.WantedId) Error!void {
    const c = &s.contexts;
    const r = c.replay_of[u];
    if (r.len == 0) return;
    const items = try c.cx.scratch.dupe(Replay, c.replays.items[r.start..][0..r.len]);
    defer c.cx.scratch.free(items);
    for (items) |item| {
        if (item.post) {
            // Only the method asked: a deferred `compare` is no part of `==`.
            if (item.method != methodName(kind)) continue;
            // Inside another run's pass it is that run's own item; for any
            // other asker, a check deferred to P5.
            if (c.active(s)) |ri| {
                const run_ = &c.runs.items[ri];
                var own = item;
                own.slot = run_.current;
                try run_.in_flight.append(c.cx.scratch, own);
            } else {
                try c.deferred.append(c.cx.scratch, .{ .type_id = item.type_id, .method = item.method, .origin = origin, .wanted = asker.toOptional(), .decl = s.report.current });
            }
            continue;
        }
        const tuple = try s.instantiate.copy(item.template);
        const both = Walk.positions(s.store(), tuple);
        if (both.len != 2) continue;
        const receiver = both[0];
        const method_type = both[1];
        const w = try Resolve.create(s, item.method, receiver, method_type, origin, .where_clause, .none);
        try Resolve.step(s, w, false);
    }
}

// ---------------------------------------------------------------------------
// The fixpoint
// ---------------------------------------------------------------------------

/// The report every run resolves under: quiet, one per module.
pub fn quietReport(s: *Solve) Error!*Report {
    const c = &s.contexts;
    if (c.quiet) |q| return q;
    const gpa = c.cx.gpa;
    const q = try gpa.create(Report);
    errdefer gpa.destroy(q);
    try q.init(c.cx, &c.quiet_items, true, s.report.env.decl_scheme, s.report.local_type);
    c.quiet = q;
    return q;
}

/// Run unit `u`'s fixpoint to the end and memoise it (§11.2).
fn run(s: *Solve, u: u32) Error!void {
    const c = &s.contexts;
    const cx = c.cx;
    const scratch = cx.scratch;
    // A copy: a nested query can add units, which moves the list.
    const members = try scratch.dupe(u32, c.membersOf(u));
    const slots: u32 = @intCast(members.len * 2);

    // A run has a step budget of its own: what a type derives is the type's,
    // not whoever asked first.
    const asker_steps = s.resolver.steps;
    s.resolver.steps = 0;
    defer s.resolver.steps = asker_steps;
    try Generalize.pushFrame(s, @intCast(s.frames.items.len + 1), .fixpoint);
    const real = s.report;
    s.report = try quietReport(s);
    s.nest_units += Groups.nest_cost;
    c.runs_total += 1;
    const ri: u32 = @intCast(c.runs.items.len);
    try c.runs.append(scratch, .{
        .unit = u,
        .frame = @intCast(s.frames.items.len - 1),
        .approx = try scratch.alloc(Answer, slots),
        .queued = try scratch.alloc(bool, slots),
        .bodies = try scratch.alloc(Body, slots),
    });
    {
        const r = &c.runs.items[ri];
        @memset(r.queued, false);
        @memset(r.bodies, .{});
        var slot = slots;
        while (slot > 0) {
            slot -= 1;
            const kind: Kind = @fromBackingInt(@intCast(slot % 2));
            if (c.notDerived(c.id(members[slot / 2]), kind)) {
                r.approx[slot] = .{ .status = .own_method };
                continue;
            }
            r.approx[slot] = .{ .status = .present };
            r.queued[slot] = true;
            try r.worklist.append(scratch, slot);
        }
    }
    var passes: u32 = 0;
    while (c.runs.items[ri].worklist.pop()) |slot| {
        c.runs.items[ri].queued[slot] = false;
        // Entries only climb a finite lattice, so the worklist ends; a pass
        // that did not climb would loop, and says so instead.
        passes += 1;
        if (passes > max_passes) {
            try s.report.internal(cx.bir.decls[cx.types.entry(c.id(members[slot / 2])).decl.int()].inst_start, "a derived-context fixpoint did not converge (checker-v2.md §11.2)");
            c.runs.items[ri].worklist.clearRetainingCapacity();
            break;
        }
        // Its replay items are the last pass's.
        {
            const r = &c.runs.items[ri];
            var i: usize = 0;
            while (i < r.in_flight.items.len) {
                if (r.in_flight.items[i].slot == slot) _ = r.in_flight.orderedRemove(i) else i += 1;
            }
        }
        const got = try pass(s, ri, members[slot / 2], @fromBackingInt(@intCast(slot % 2)), slot);
        const r = &c.runs.items[ri];
        if (c.same(r.approx[slot], got)) {
            // Keep the newest templates. `same` does not compare them, and
            // need not: a template's leaves are the type's parameters or
            // ground, and a marker that is bound is `absent`, so a template
            // changes only with the set (§11.2).
            if (std.debug.runtime_safety) try assertSameTemplate(s, r.approx[slot], got);
            r.approx[slot] = got;
            continue;
        }
        if (std.debug.runtime_safety) std.debug.assert(c.climbs(r.approx[slot], got));
        r.approx[slot] = got;
        for (r.deps.items) |dep| {
            if (dep[1] != slot or r.queued[dep[0]]) continue;
            r.queued[dep[0]] = true;
            try r.worklist.append(scratch, dep[0]);
        }
    }
    var r = c.runs.pop().?;
    // Its unit's id now: a nested query may have rebuilt the units
    // (`complete`), which keeps this one's members but not its id.
    const unit = r.unit;
    for (members, 0..) |t, i| {
        c.answers[t * 2] = r.approx[i * 2];
        c.answers[t * 2 + 1] = r.approx[i * 2 + 1];
    }
    const start: u32 = @intCast(c.replays.items.len);
    try c.replays.appendSlice(scratch, r.in_flight.items);
    c.replay_of[unit] = .{ .start = start, .len = @intCast(r.in_flight.items.len) };
    var needs = false;
    var budget = false;
    for (r.approx) |a| {
        needs = needs or a.status == .needs_annotation;
        budget = budget or a.status == .absent_budget;
    }
    if (r.stray) try s.report.internal(cx.bir.decls[cx.types.entry(c.id(members[0])).decl.int()].inst_start, "a derived-context fixpoint read another unit's approximation (checker-v2.md §11.2, §11.5)");
    // A budget run out is never an answer to keep: P5 computes it again.
    c.memo[unit] = if (r.stray or budget) .none else if (r.generational or needs or r.in_flight.items.len != 0) .generational else .permanent;
    // Only a permanent result's last passes are row bodies, committed with
    // its answers: one that read something in flight is computed again in P5.
    for (members, 0..) |t, i| {
        const keep = c.memo[unit] == .permanent;
        c.bodies[t * 2] = if (keep) r.bodies[i * 2] else .{};
        c.bodies[t * 2 + 1] = if (keep) r.bodies[i * 2 + 1] else .{};
    }
    c.memo_gen[unit] = c.generation;
    r.worklist.deinit(scratch);
    r.deps.deinit(scratch);
    r.in_flight.deinit(scratch);

    s.nest_units -= Groups.nest_cost;
    s.report = real;
    try Decide.drain(s, s.frame().queue, true);
    Generalize.popFrame(s);
    try sayInternals(s, real);
}

/// What the quiet report gathered is dropped, except the compiler's own
/// failures, which `real` says.
pub fn sayInternals(s: *Solve, real: *Report) Error!void {
    const c = &s.contexts;
    // A run nested inside another run's pass: `real` is the same quiet
    // report, and the outermost run says what gathered (appending to the
    // list being read would lose them, and leak).
    if (c.quiet == real) return;
    const gpa = c.cx.gpa;
    for (c.quiet_items.items) |item| {
        if (item.code == .internal) {
            var said = item;
            said.message = try gpa.dupe(u8, item.message);
            try real.emit(said);
        }
        gpa.free(item.message);
    }
    c.quiet_items.clearRetainingCapacity();
}

/// Whether two answers are the same lattice point: status, culprit and the
/// `(param, method)` set (the templates of equal entries may be new copies).
fn assertSameTemplate(s: *Solve, a: Answer, b: Answer) Error!void {
    const x = a.template.unwrap() orelse return;
    const y = b.template.unwrap() orelse return;
    std.debug.assert(try Walk.sameShape(s.store(), s.cx.scratch, x, y, 1 << 20));
}

/// A pass may only move its entry up the lattice: `present(∅) ⊂ present(more)
/// ⊂ absent` (§11.2). A present set must contain the one before it; any
/// absent may follow any present, and any absent any absent (which culprit
/// a pass met first can change between them); `own_method` and `foreign`
/// never move. So an oscillation between two absents (culprits a pass meets
/// in a different order) is not caught here; the worklist's cap, `internal`
/// past 2²² passes, bounds it.
fn climbs(c: *const Contexts, old: Answer, new: Answer) bool {
    switch (old.status) {
        .own_method, .foreign => return new.status == old.status,
        .present => {},
        else => return new.status != .present and new.status != .own_method and new.status != .foreign,
    }
    if (new.status != .present) return new.status != .own_method and new.status != .foreign;
    // Both sorted by `(param, method text)`: one merge walk.
    // A pin is a constraint on its parameter at least as strong as any
    // entry on it: an old entry may give way to a new pin, and an
    // old pin stays.
    const new_pins = c.pinsOf(new);
    for (c.pinsOf(old)) |p| {
        if (!hasPin(new_pins, p.param)) return false;
    }
    const had = c.entriesOf(old);
    const has = c.entriesOf(new);
    var j: usize = 0;
    for (had) |e| {
        if (hasPin(new_pins, e.param)) continue;
        while (j < has.len and entryLessThan(c.cx.interner, has[j], e)) j += 1;
        if (j == has.len or has[j].param != e.param or has[j].method != e.method) return false;
        j += 1;
    }
    return true;
}

fn hasPin(pins: []const Pin, param: u16) bool {
    for (pins) |p| {
        if (p.param == param) return true;
    }
    return false;
}

/// Passes one run may make before it is `internal`: a
/// hang guard, far above what a lattice of any real width climbs through.
const max_passes: u32 = 1 << 22;

fn same(c: *const Contexts, a: Answer, b: Answer) bool {
    if (a.status != b.status or a.culprit != b.culprit) return false;
    const x = c.entriesOf(a);
    const y = c.entriesOf(b);
    if (x.len != y.len) return false;
    for (x, y) |p, q| {
        if (p.param != q.param or p.method != q.method) return false;
    }
    const u = c.pinsOf(a);
    const v = c.pinsOf(b);
    if (u.len != v.len) return false;
    for (u, v) |p, q| {
        if (p.param != q.param) return false;
    }
    return true;
}

/// Local type `t`'s constructor payloads, read in the current frame with its
/// parameters bound to fresh flex MARKERS: every argument, constructors in
/// declaration order and arguments left to right (§9's parts contract).
/// Null when a payload is too deep to read (its `nesting_too_deep` is
/// P4's). Shared with P5 (`Eager`), whose body positions these are.
pub const Payloads = struct { markers: []const Var, args: []const Var, origin: Bir.Inst.Index };

pub fn readPayloads(s: *Solve, t: u32) Error!?Payloads {
    const c = &s.contexts;
    const cx = c.cx;
    const scratch = cx.scratch;
    const bir = cx.bir;
    const entry = cx.types.entry(c.id(t));
    const d = bir.decls[entry.decl.int()];
    const params = bir.declTypeParams(d);
    const markers = try scratch.alloc(Var, params.len);
    if (entry.schema_endpoint) {
        for (params, markers) |p, *v| v.* = try s.fresh(.{ .flex = .{ .name = p.toOptional() } });
        return .{ .markers = markers, .args = try endpointPayloads(s, t, markers), .origin = d.inst_start };
    }
    var b = cx.builder(.flex, s.frame().rank);
    defer b.deinit();
    // Every endpoint a payload names, a fresh copy
    // (`Schema.State.lookupFresh`): no two passes share a root the resolver
    // keys an answer by.
    b.schema_lookup = Schema.State.lookupFresh;
    for (params, markers) |p, *v| {
        v.* = try s.fresh(.{ .flex = .{ .name = p.toOptional() } });
        try b.bind(p, v.*);
    }
    const mark = cx.store.count();
    var args: std.ArrayList(Var) = .empty;
    for (bir.declCtors(d)) |ctor| {
        for (bir.extraSlice(.{ .start = ctor.args_start, .end = ctor.args_end }, Bir.Inst.Index)) |arg| {
            try args.append(scratch, try b.read(arg));
        }
    }
    try s.instantiate.adoptSince(mark);
    if (b.too_deep) return null;
    return .{ .markers = markers, .args = args.items, .origin = d.inst_start };
}

/// A tagged schema endpoint's payloads (§11.5): what
/// `Schema.State` elaborated for its variants, over the schema's own
/// generalised parameters, instantiated in the current frame with the
/// markers for those parameters — the same read a `type`'s constructors
/// get, from the plan instead of the declaration. A `via` payload is its
/// conversion's target type, which the schema's group (done by now:
/// `complete`) inferred.
fn endpointPayloads(s: *Solve, t: u32, markers: []const Var) Error![]const Var {
    const c = &s.contexts;
    const cx = c.cx;
    const scratch = cx.scratch;
    const entry = cx.types.entry(c.id(t));
    const ep = endpointOf(cx, c.id(t));
    const decl = entry.decl.int();
    const params = try scratch.alloc(Var, markers.len);
    defer scratch.free(params);
    for (params, 0..) |*p, j| p.* = cx.schemas.param(decl, @intCast(j), ep);
    var raw: std.ArrayList(Var) = .empty;
    defer raw.deinit(scratch);
    try cx.schemas.payloads(decl, ep, &raw, scratch);
    const args = try scratch.alloc(Var, raw.items.len);
    for (raw.items, args) |payload, *arg| arg.* = try s.instantiate.substitute(payload, params, markers);
    return args;
}

/// Which endpoint of its schema `type_id` is.
fn endpointOf(cx: *const Context, type_id: Types.TypeId) @import("../resolve/Interface.zig").SchemaCtor.Endpoint {
    const entry = cx.types.entry(type_id);
    return if (cx.types.ofSchemaDecl(cx.module, entry.decl, .type) == type_id) .type else .encoded;
}

/// A schema with a `via` whose payloads local type `t` reads (its own, as a
/// program endpoint, or a record schema it names) and whose group is still
/// in flight: its `via` targets are not inferred yet, so the pass cannot
/// read them (§11.5). The schema's declaration, or none.
fn endpointInFlight(s: *Solve, t: u32) u32 {
    const c = &s.contexts;
    if (c.refs_by_type.len == 0) return none;
    for (c.via_refs.items[c.refs_by_type[t]..c.refs_by_type[t + 1]]) |r| {
        if (s.groups.statusOf(r[1]) != .done) return r[1];
    }
    return none;
}

/// The top-level value schema `decl`'s first `via` names, if it is one: what
/// `method_needs_annotation`'s hint says to annotate (§11.5).
pub fn schemaConversion(cx: *const Context, decl: u32) ?Symbol {
    if (cx.bir.decls[decl].kind != .schema) return null;
    for (cx.schemas.vias.items) |via| {
        if (via.owner.int() != decl) continue;
        if (cx.bir.instTag(via.expr) != .top) continue;
        const target = cx.bir.instData(via.expr).lhs;
        if (target >= cx.bir.decls.len) continue;
        return cx.bir.symbol(cx.bir.decls[target].name);
    }
    return null;
}

/// Whether local type `t` is a schema's encoded endpoint, whose payloads
/// hold no `via` target (schema.md §4).
pub fn isEncoded(c: *const Contexts, t: u32) bool {
    const entry = c.cx.types.entry(c.id(t));
    return entry.schema_endpoint and c.cx.types.ofSchemaDecl(c.cx.module, entry.decl, .encoded) == c.id(t);
}

/// One wanted of `kind` per payload position, each resolved now (a flex
/// position rides on it, open).
pub fn resolvePayloads(s: *Solve, p: Payloads, kind: Kind) Error![]const Evidence.WantedId {
    const name = methodName(kind);
    const ids = try s.cx.scratch.alloc(Evidence.WantedId, p.args.len);
    for (p.args, ids) |arg, *wid| {
        const method_type = try Resolve.wellKnownType(s, name, arg);
        wid.* = try Resolve.create(s, name, arg, method_type, p.origin, .well_known, .none);
        try Resolve.step(s, wid.*, false);
    }
    return ids;
}

/// One pass of `(t, kind)` in run `ri` (§11.2): resolve the payloads, drain,
/// and read the answer off what is left.
fn pass(s: *Solve, ri: u32, t: u32, kind: Kind, slot: u32) Error!Answer {
    const c = &s.contexts;
    const cx = c.cx;
    {
        const r = &c.runs.items[ri];
        r.current = slot;
        r.culprit = none;
        r.saw_function = false;
        r.private = null;
        r.requirement = null;
    }
    defer {
        const r = &c.runs.items[ri];
        r.current = none;
        r.markers = &.{};
    }
    const wanted_start: u32 = @intCast(s.evidence.wanteds.items.len);
    const too_deep_start = s.report.too_deep;
    // An endpoint whose schema is in flight: its `via` targets are not
    // inferred yet (§11.5).
    const schema = endpointInFlight(s, t);
    if (schema != none) {
        // A CLOSED type (no parameters): its answer is deferred, as a closed
        // in-flight method's is (§11.2) — no entry now, and every asker
        // checks it once the schema's group is done. A parametric one's entries
        // would depend on what is being inferred: `needs_annotation`.
        if (cx.bir.declTypeParams(cx.bir.decls[cx.types.entry(c.id(t)).decl.int()]).len != 0) return .{ .status = .needs_annotation, .culprit = schema };
        const r = &c.runs.items[ri];
        try r.in_flight.append(cx.scratch, .{ .slot = slot, .decl = schema, .method = methodName(kind), .post = true, .type_id = c.id(t) });
        return .{ .status = .present };
    }
    const p = (try readPayloads(s, t)) orelse return .{ .status = .absent_other };
    c.runs.items[ri].markers = p.markers;
    const ids = try resolvePayloads(s, p, kind);
    try Decide.drain(s, s.frame().queue, true);
    // The last pass of a slot read every entry at its final value (the
    // worklist re-runs a pass whose read grew), so once the run is memoised
    // permanently it IS the row's body, and P5 reads no payload again.
    c.runs.items[ri].bodies[slot] = .{ .markers = p.markers, .ids = ids, .set = true };
    // A budget that ran out inside the pass — the resolver's steps, or a
    // nested check refused at demand — said so to the quiet report, which
    // drops the message and counts it: the entry is no answer, and the use
    // says it.
    if (s.report.too_deep != too_deep_start) return .{ .status = .absent_budget };
    return c.collect(s, ri, t, p.markers, ids, wanted_start);
}

/// What a pass's positions say (§11.2): `needs_annotation` when a parametric
/// in-flight method was met; `absent` when a position failed, a marker
/// stopped being a distinct plain flex or a pin (bound to a ground type:
/// `pins`), or a wanted of the pass is left open
/// on anything but a marker; else `present`, one entry per wanted open on a
/// marker, sorted by `(param, method text)`, each of another method than
/// `eq` or `compare` with its type frozen over the template parameters.
fn collect(c: *Contexts, s: *Solve, ri: u32, t: u32, markers: []const Var, ids: []const Evidence.WantedId, wanted_start: u32) Error!Answer {
    const cx = c.cx;
    const st = cx.store;
    const scratch = cx.scratch;
    const r = c.runs.items[ri];
    if (r.culprit != none) return .{ .status = .needs_annotation, .culprit = r.culprit };
    if (s.resolver.steps >= Resolve.step_budget) return .{ .status = .absent_budget };
    const failed: Answer = if (r.private) |p|
        .{ .status = .absent_private, .culprit = @backingInt(p.type_id), .method = p.method }
    else if (r.requirement) |q|
        .{ .status = .absent_requirement, .culprit = @backingInt(q.type_id), .method = q.method }
    else
        .{ .status = if (r.saw_function) .absent_function else .absent_other };
    // A failed position is the answer; a POISONED one only when nothing
    // else failed (`Status.poisoned`), and never over a reason the
    // run recorded.
    var poisoned = false;
    for (ids, 0..) |wid, k| switch (s.evidence.get(wid).state) {
        .failed => {
            var at = failed;
            if (at.status == .absent_requirement) at.payload = @intCast(k);
            return at;
        },
        .poisoned => poisoned = true,
        else => {},
    };
    if (poisoned) return if (failed.status == .absent_other) .{ .status = .poisoned } else failed;
    // Every marker a distinct plain flex or a PIN — bound to a ground type,
    // by a payload's specialised method — found in linear time: each
    // flex root is stamped `seen` (a type may have tens of
    // thousands of parameters). The ground walks come first, as they stamp
    // with marks of their own.
    var pinned = try std.DynamicBitSetUnmanaged.initEmpty(scratch, markers.len);
    defer pinned.deinit(scratch);
    for (markers, 0..) |m, i| {
        const root = st.find(m);
        switch (st.content(root)) {
            .flex => |flags| if (flags.kind != .any) return failed,
            .structure => {
                if (!try c.ground(s, root)) return failed;
                pinned.set(i);
            },
            else => return failed,
        }
    }
    const seen = st.nextMark();
    for (markers, 0..) |m, i| {
        if (pinned.isSet(i)) continue;
        const root = st.find(m);
        if (st.mark(root) == seen) return failed;
        st.setMark(root, seen);
    }
    // A wanted of this pass left open on anything but a marker has no
    // context entry to be.
    const end: u32 = @intCast(s.evidence.wanteds.items.len);
    var mine = try std.DynamicBitSetUnmanaged.initEmpty(scratch, end - wanted_start);
    defer mine.deinit(scratch);
    for (ids) |wid| if (wid.int() >= wanted_start) mine.set(wid.int() - wanted_start);
    for (s.evidence.wanteds.items[wanted_start..], wanted_start..) |w, i| {
        if (w.state != .open and w.state != .ready) continue;
        const lineage = Resolve.lineageRoot(s, @fromBackingInt(@intCast(@as(u32, @intCast(i)))));
        if (lineage.int() < wanted_start or !mine.isSet(lineage.int() - wanted_start)) continue;
        if (w.state == .ready or st.mark(st.find(w.receiver)) != seen) return failed;
    }
    const first: u32 = @intCast(c.entries.items.len);
    var method_types: std.ArrayList(Var) = .empty;
    defer method_types.deinit(scratch);
    for (markers, 0..) |m, i| {
        if (pinned.isSet(i)) continue;
        const flags = st.flagsOf(st.find(m));
        const set = Walk.constraints(flags);
        const n = set.count(st);
        var asks_eq = false;
        var j: u32 = 0;
        while (j < n) : (j += 1) {
            const wid = s.evidence.slotAt(Evidence.position(st, set.set, j)).asWanted() orelse continue;
            const w = s.evidence.get(wid);
            if (w.state != .open) continue;
            if (w.method == InternPool.WellKnown.eq.symbol()) asks_eq = true;
            var slot: u32 = none;
            if (!Resolve.isWellKnownName(w.method)) {
                slot = @intCast(method_types.items.len);
                try method_types.append(scratch, w.method_type);
            }
            try c.entries.append(scratch, .{ .param = @intCast(i), .method = w.method, .slot = slot });
        }
        // The `equatable` flag a payload's method put on the parameter — a
        // quantifier of its scheme that `Basics.eq` compares — or an open
        // `equatable` row riding on it: not an evidence
        // wanted, but a requirement of the argument all the same. It is the
        // entry `(i, eq)`, as a boundary's flag is (`Derivable.boundaryStep`)
        // so an argument that holds a
        // function is refused at the use.
        if (!asks_eq and (flags.equatable or s.obligations.openEquatable(flags.obls) != null)) {
            try c.entries.append(scratch, .{ .param = @intCast(i), .method = InternPool.WellKnown.eq.symbol() });
        }
    }
    // A pin's type rides in the template beside the method types, and its
    // culprit is the specialised method the pass matched (for the use's
    // message): the first pin's, by param.
    const pins_first: u32 = @intCast(c.pins.items.len);
    var culprit: u32 = none;
    var culprit_method: Symbol = undefined;
    for (markers, 0..) |m, i| {
        if (!pinned.isSet(i)) continue;
        try c.pins.append(scratch, .{ .param = @intCast(i), .slot = @intCast(method_types.items.len) });
        try method_types.append(scratch, m);
        if (culprit == none) {
            if (pinCulprit(s, st.find(m), wanted_start)) |p| {
                culprit = @backingInt(p.type_id);
                culprit_method = p.method;
            }
        }
    }
    const pins_len: u32 = @intCast(c.pins.items.len - pins_first);
    // One frozen tuple for every method type the entries need and every
    // pin's type, over the template parameters, frozen once (not once per
    // entry). A pinned marker's root is its ground type, never a parameter:
    // only the others are replaced.
    var template: Var.Optional = .none;
    if (method_types.items.len != 0) {
        const range = try st.addVars(method_types.items);
        const tuple = try s.fresh(.{ .structure = .{ .tuple = range } });
        const params = try c.paramsOf(t);
        if (pins_len == 0) {
            template = (try s.instantiate.freeze(tuple, markers, params)).toOptional();
        } else {
            var from: std.ArrayList(Var) = .empty;
            defer from.deinit(scratch);
            var to: std.ArrayList(Var) = .empty;
            defer to.deinit(scratch);
            for (markers, params, 0..) |m, p, i| {
                if (pinned.isSet(i)) continue;
                try from.append(scratch, m);
                try to.append(scratch, p);
            }
            template = (try s.instantiate.freeze(tuple, from.items, to.items)).toOptional();
        }
    }
    const got = c.entries.items[first..];
    std.mem.sort(Entry, got, cx.interner, entryLessThan);
    return .{
        .status = .present,
        .entries = .{ .start = first, .len = @intCast(got.len) },
        .pins = .{ .start = pins_first, .len = pins_len },
        .template = template,
        .culprit = culprit,
        .method = if (culprit != none) culprit_method else undefined,
    };
}

/// Whether `root` is a ground type: no variable anywhere below it.
fn ground(c: *Contexts, s: *Solve, root: Var) Error!bool {
    var vars: std.ArrayList(Var) = .empty;
    defer vars.deinit(c.cx.scratch);
    try Walk.variables(s.store(), &s.stacks, s.cx.gpa, c.cx.scratch, root, &vars);
    return vars.items.len == 0;
}

/// The specialised method that pinned a marker whose root is now `root`:
/// a wanted of the pass answered by a module-rule method (`top`/`ext`)
/// whose receiver's argument is that root. Null when none is found (a pin
/// inherited through another pinned type's derived answer).
fn pinCulprit(s: *Solve, root: Var, wanted_start: u32) ?struct { type_id: Types.TypeId, method: Symbol } {
    const st = s.store();
    const c = &s.contexts;
    for (s.evidence.wanteds.items[wanted_start..], wanted_start..) |w, i| {
        const answer = s.evidence.answer(@fromBackingInt(@intCast(@as(u32, @intCast(i)))));
        switch (answer) {
            .top, .ext, .derived => {},
            else => continue,
        }
        const a = switch (st.resolvedContent(w.receiver)) {
            .structure => |flat| switch (flat) {
                .app => |a| a,
                else => continue,
            },
            else => continue,
        };
        const mine = for (Walk.positions(st, st.find(w.receiver))) |arg| {
            if (st.find(arg) == root) break true;
        } else false;
        if (!mine) continue;
        switch (answer) {
            .derived => {
                // A pin inherited from a pinned type of this module: its
                // culprit, when its own answer knows it.
                const u = c.local(a.type) orelse continue;
                if (!Resolve.isWellKnownName(w.method)) continue;
                const known = c.answers[u * 2 + @backingInt(kindOf(w.method))];
                if (known.status == .present and known.culprit != none) return .{ .type_id = @fromBackingInt(@intCast(known.culprit)), .method = known.method };
            },
            else => return .{ .type_id = a.type, .method = w.method },
        }
    }
    return null;
}

fn entryLessThan(interner: *const InternPool.Global, a: Entry, b: Entry) bool {
    if (a.param != b.param) return a.param < b.param;
    return std.mem.lessThan(u8, interner.slice(a.method), interner.slice(b.method));
}

/// §11.2's in-flight branch: a pass of run `ri` resolved wanted `wid` to own
/// method `decl`, whose group is `checking`. A receiver that reaches one of
/// the pass's markers is the parametric case: the entry becomes
/// `needs_annotation`, naming `decl`, and the wanted fails in silence. Any
/// other is closed: no entry, the wanted answered as a group call (its body
/// term is P5's, when `decl` is done), and `( receiver, method type )`
/// recorded for replay — the method-type check is the asker's ordinary
/// wanted, in the asker's frame, never this frame's.
pub fn inFlight(s: *Solve, ri: u32, wid: Evidence.WantedId, decl: u32) Error!void {
    const c = &s.contexts;
    const w = s.evidence.get(wid);
    for (c.runs.items[ri].markers) |m| {
        if (!try Walk.reaches(s.store(), &s.stacks, c.cx.gpa, w.receiver, m)) continue;
        if (c.runs.items[ri].culprit == none) c.runs.items[ri].culprit = decl;
        return Resolve.reject(s, wid, false);
    }
    const pair = try s.store().addVars(&.{ w.receiver, w.method_type });
    const tuple = try s.fresh(.{ .structure = .{ .tuple = pair } });
    const template = try s.instantiate.freeze(tuple, &.{}, &.{});
    const r = &c.runs.items[ri];
    try r.in_flight.append(c.cx.scratch, .{ .slot = r.current, .decl = decl, .method = w.method, .template = template });
    Resolve.answer(s, wid, .{ .group_call = decl });
}

/// A run's pass met a function: an `absent` entry is `absent_function`.
pub fn noteFunction(c: *Contexts, s: *const Solve) void {
    const ri = c.active(s) orelse return;
    c.runs.items[ri].saw_function = true;
}

/// A run's pass met a `needs_annotation` answer: its own entry is one too.
pub fn noteCulprit(c: *Contexts, s: *const Solve, decl: u32) void {
    const ri = c.active(s) orelse return;
    if (c.runs.items[ri].culprit == none) c.runs.items[ri].culprit = decl;
}

/// Local type `t`'s id in the session table.
pub fn typeId(c: *const Contexts, t: u32) Types.TypeId {
    return c.id(t);
}

/// The generation the gate memo is keyed by: none moves a gate in a module
/// without schemas, whose payloads are all declared.
fn gateGeneration(c: *const Contexts) u32 {
    return if (c.has_schemas) c.generation else 0;
}

/// Local type `t`'s §11.4 gate, if known this generation.
pub fn gateKnown(c: *const Contexts, t: u32) ?bool {
    if (c.gate_gen[t] != c.gateGeneration()) return null;
    return c.gate_ok[t];
}

pub fn setGate(c: *Contexts, t: u32, ok: bool) void {
    c.gate_gen[t] = c.gateGeneration();
    c.gate_ok[t] = ok;
}

/// A group completed (§11.2, *Memo generations*).
pub fn groupDone(c: *Contexts) void {
    c.generation +%= 1;
}

/// A run's pass met another module's private method, declared by the
/// module of `type_id`: an `absent` entry is `private_method` at the use
/// (§11.2, §11.3).
/// A run's pass met a payload's method of the wrong type: its
/// entry is `absent_requirement`, naming it, unless a private method was
/// met first.
pub fn noteRequirement(c: *Contexts, s: *const Solve, type_id: Types.TypeId, method: Symbol) void {
    const ri = c.active(s) orelse return;
    if (c.runs.items[ri].requirement == null) c.runs.items[ri].requirement = .{ .type_id = type_id, .method = method };
}

pub fn notePrivate(c: *Contexts, s: *const Solve, type_id: Types.TypeId, method: Symbol) void {
    const ri = c.active(s) orelse return;
    if (c.runs.items[ri].private == null) c.runs.items[ri].private = .{ .type_id = type_id, .method = method };
}

/// Whether `type_id`'s answers are memoised permanently: a verdict built on
/// them may be kept past its walk (`Derivable`).
pub fn settled(c: *const Contexts, type_id: Types.TypeId) bool {
    const t = c.local(type_id) orelse return true;
    const u = c.unit_of[t];
    return u == none or c.memo[u] == .permanent;
}

// ---------------------------------------------------------------------------
// Tests: a supplement (CLAUDE.md rule 3). The behaviour is the
// `DerivedContext*` corpus fixtures, several in both declaration orders; what
// is here is the memo's generation rule alone.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a result memoised under a generation is not read past it; a permanent one always is" {
    var memo = [_]Memo{ .generational, .permanent, .none };
    var memo_gen = [_]u32{ 0, 0, 0 };
    var c: Contexts = .{ .cx = undefined, .memo = &memo, .memo_gen = &memo_gen };
    try testing.expect(c.valid(0));
    try testing.expect(c.valid(1));
    try testing.expect(!c.valid(2));
    // A group completes: the in-flight method the first result read is done.
    c.groupDone();
    try testing.expect(!c.valid(0));
    try testing.expect(c.valid(1));
    // Recomputed in the new generation, it is read again — until the next.
    memo_gen[0] = c.generation;
    try testing.expect(c.valid(0));
    c.groupDone();
    try testing.expect(!c.valid(0));
}
