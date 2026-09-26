//! Derived contexts (checker-v2.md §11.1, §11.2, D4; *As built by R8a*): the
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
//! position is `absent`; a marker that became anything but a distinct plain
//! flex (a specialised instance bound it) is `absent` too. A worklist
//! re-runs exactly the passes that read an entry that grew; entries only
//! move up the lattice `present(∅) ⊂ present(more) ⊂ absent`, so it ends.
//!
//! **Reading the approximation, or running fresh** (§11.2, round 4 R8-1). A
//! query for a type of unit `U` reads the approximation of `U`'s innermost
//! run when no top-level-kind group frame lies above that run's frame (the
//! run's own passes, and anything they ask directly); when one does — the
//! run's resolution nested a group whose body asks again — it runs a FRESH
//! fixpoint for `U`. Dependency units are run first, in order, so a chain of
//! types never recurses natively (I4).
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
//! result that read another unit's partial approximation is never memoised.
//!
//! Everything a run resolves is reported QUIETLY (one report for the module,
//! made once): a payload that cannot answer is an `absent` entry, never a
//! message about code nobody wrote at this use. An `internal` is still said.
//! A group a pass nests is checked with the module's own report.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Scc = @import("../check/Scc.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Types = @import("../check/Types.zig");
const Context = @import("Context.zig");
const Decide = @import("Decide.zig");
const Evidence = @import("Evidence.zig");
const Generalize = @import("Generalize.zig");
const Groups = @import("Groups.zig");
const Report = @import("Report.zig");
const Resolve = @import("Resolve.zig");
const Solve = @import("Solve.zig");
const Walk = @import("Walk.zig");

const Contexts = @This();

const Var = TypeStore.Var;
const Symbol = InternPool.Symbol;
pub const Kind = Dispatch.Derived.Kind;
pub const Error = Allocator.Error;
pub const none = std.math.maxInt(u32);

pub const Status = enum(u8) {
    /// The type derives the method, with the context in `entries`.
    present,
    /// Not derived: the module declares a `pub` value of the method's name,
    /// which the module rule makes every one of its types' method (§11.3).
    own_method,
    /// A `foreign type`: no body to derive over.
    foreign,
    /// A payload cannot answer the method: a function reachable, or else.
    absent_function,
    absent_other,
    /// A payload reaches another module's private method (§11.2, §11.3):
    /// `culprit` is the module, `method` its name.
    absent_private,
    /// §11.2's parametric in-flight case: `culprit` names the method.
    needs_annotation,
};

/// One context entry: `args[param]` must answer `method`, at the well-known
/// type (`slot` none) or at element `slot` of its answer's `template`.
pub const Entry = struct { param: u16, method: Symbol, slot: u32 = none };
pub const Range = struct { start: u32 = 0, len: u32 = 0 };

pub const Answer = struct {
    status: Status,
    /// `present`: a run of `entries`, sorted by `(param, method text)`.
    entries: Range = .{},
    /// `needs_annotation`: the in-flight method's declaration;
    /// `absent_private`: the module of the private method.
    culprit: u32 = none,
    /// `absent_private`: the private method's name.
    method: Symbol = undefined,
    /// `present`: one frozen tuple of the method types of every entry whose
    /// method is not `eq` or `compare`, over the type's template parameters
    /// (`paramsOf`), an entry's `slot` its element. One tuple per answer, so a
    /// use substitutes the arguments once and a row publishes one scheme,
    /// however many entries it has (R8a's review).
    template: Var.Optional = .none,
};

/// A closed in-flight method a run met: replayed for every asker (§11.2).
/// `template` is the frozen tuple `( receiver, method type )`.
const Replay = struct { slot: u32, decl: u32, method: Symbol, template: Var };

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
    /// The pass met another module's private method: `(module, method)`.
    private: ?struct { module: u32, method: Symbol } = null,
    /// It read another run's approximation: never memoised.
    partial: bool = false,
    /// It read a generational result: memoised under the generation only.
    generational: bool = false,
    /// Per slot: its last pass's positions, committed to `bodies` with the
    /// answers when the run is memoised permanently (R8a's review, S4: a
    /// nested fresh run of the same unit must not leave its bodies beside
    /// the outer run's answers).
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
units: Scc.IndexGroups = .{ .order = &.{}, .starts = &.{} },
/// Per unit, the units its members' payloads mention (dependencies).
dep_starts: []u32 = &.{},
deps: []u32 = &.{},
memo: []Memo = &.{},
memo_gen: []u32 = &.{},
replay_of: []Range = &.{},
/// Per local type × method, the last computed answer.
answers: []Answer = &.{},
entries: std.ArrayList(Entry) = .empty,
replays: std.ArrayList(Replay) = .empty,
/// Per local type, its template parameters (a run of `param_vars`), made
/// when first needed.
params: []Range = &.{},
param_vars: std.ArrayList(Var) = .empty,
runs: std.ArrayList(Run) = .empty,
/// Bumped whenever a group completes (§11.2, *Memo generations*).
generation: u32 = 0,
/// The module declares a `pub` value named `eq` / `compare`.
module_has: [2]bool = .{ false, false },
/// The one quiet report every run resolves under, made on first use.
quiet: ?*Report = null,
quiet_items: std.ArrayList(Report.Item) = .empty,
/// A stamp per unit for `ensure`'s walk.
seen: []u32 = &.{},
walks: u32 = 0,
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
    // A `pub` value of the method's name: the module rule answers every type
    // of the module with it, and none derives. A private one answers the
    // module's own uses, but the row is still derived and published, as v1
    // does (`dispatch/PrivateEqStillDerives`): what D1 changes about it is
    // R8b's (§11.3).
    for (bir.decls) |d| {
        if (!d.kind.isValue() or !d.is_pub) continue;
        const name = bir.symbol(d.name);
        if (name == InternPool.WellKnown.eq.symbol()) c.module_has[0] = true;
        if (name == InternPool.WellKnown.compare.symbol()) c.module_has[1] = true;
    }
    const m = cx.module.int();
    if (m + 1 >= types.entry_offsets.len) return c;
    c.start = types.entry_offsets[m];
    c.count = types.entry_offsets[m + 1] - c.start;
    const n = c.count;
    c.unit_of = try scratch.alloc(u32, n);
    @memset(c.unit_of, none);
    c.member_of = try scratch.alloc(u32, n);
    c.answers = try scratch.alloc(Answer, n * 2);
    @memset(c.answers, .{ .status = .absent_other });
    c.params = try scratch.alloc(Range, n);
    @memset(c.params, .{});
    c.bodies = try scratch.alloc(Body, n * 2);
    @memset(c.bodies, .{});

    // The mentions graph over the module's own `type`s.
    var edges: std.ArrayList(u32) = .empty;
    const edge_start = try scratch.alloc(u32, n + 1);
    // Per declaration, the last type whose payloads expanded it as an alias.
    const expanded = try scratch.alloc(u32, bir.decls.len);
    @memset(expanded, none);
    // Per local type, the last type whose edges named it: a stamp, so a
    // payload that mentions many types costs its mentions, not their square.
    const named = try scratch.alloc(u32, n);
    @memset(named, none);
    for (0..n) |t| {
        edge_start[t] = @intCast(edges.items.len);
        if (!c.derives(@intCast(t))) continue;
        const d = bir.decls[types.entry(c.id(@intCast(t))).decl.int()];
        try c.mentions(d, &edges, @intCast(t), named, expanded);
    }
    edge_start[n] = @intCast(edges.items.len);
    c.units = try Scc.sccGroups(scratch, n, edges.items, edge_start);
    const unit_count = c.units.starts.len - 1;
    for (0..unit_count) |u| {
        for (c.units.order[c.units.starts[u]..c.units.starts[u + 1]], 0..) |t, i| {
            if (!c.derives(t)) continue;
            c.unit_of[t] = @intCast(u);
            c.member_of[t] = @intCast(i);
        }
    }
    // Unit dependencies, for `ensure`.
    c.dep_starts = try scratch.alloc(u32, unit_count + 1);
    var deps: std.ArrayList(u32) = .empty;
    const listed = try scratch.alloc(u32, unit_count);
    @memset(listed, none);
    for (0..unit_count) |u| {
        c.dep_starts[u] = @intCast(deps.items.len);
        for (c.units.order[c.units.starts[u]..c.units.starts[u + 1]]) |t| {
            for (edges.items[edge_start[t]..edge_start[t + 1]]) |to| {
                const v = c.unit_of[to];
                if (v == none or v == u or listed[v] == u) continue;
                listed[v] = @intCast(u);
                try deps.append(scratch, v);
            }
        }
    }
    c.dep_starts[unit_count] = @intCast(deps.items.len);
    c.deps = deps.items;
    c.memo = try scratch.alloc(Memo, unit_count);
    @memset(c.memo, .none);
    c.memo_gen = try scratch.alloc(u32, unit_count);
    c.replay_of = try scratch.alloc(Range, unit_count);
    @memset(c.replay_of, .{});
    c.seen = try scratch.alloc(u32, unit_count);
    @memset(c.seen, 0);
    return c;
}

/// Local type `t`'s own `type`s mentioned in declaration `d`'s payloads,
/// through aliases, as edges `t → mentioned`.
fn mentions(c: *const Contexts, d: Bir.Decl, edges: *std.ArrayList(u32), from: u32, named: []u32, expanded: []u32) Error!void {
    const bir = c.cx.bir;
    const scratch = c.cx.scratch;
    var pending: std.ArrayList(Bir.Decl) = .empty;
    defer pending.deinit(scratch);
    try pending.append(scratch, d);
    while (pending.pop()) |next| {
        for (bir.declRefs(next)) |ref| {
            if (ref.kind != .top_type or ref.a >= bir.decls.len) continue;
            const target = bir.decls[ref.a];
            switch (target.kind) {
                .type => {
                    const to = c.local(c.cx.types.ofDecl(c.cx.module, @enumFromInt(ref.a))) orelse continue;
                    if (named[to] == from) continue;
                    named[to] = from;
                    try edges.append(scratch, to);
                },
                .type_alias => {
                    if (expanded[ref.a] == from) continue;
                    expanded[ref.a] = from;
                    try pending.append(scratch, target);
                },
                else => {},
            }
        }
    }
}

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
    return @enumFromInt(c.start + t);
}

/// The module-local index of type `type_id`, if it is this module's.
pub fn local(c: *const Contexts, type_id: Types.TypeId) ?u32 {
    if (type_id == .none) return null;
    const i = type_id.int();
    if (i < c.start or i - c.start >= c.count) return null;
    return i - c.start;
}

/// Whether a fixpoint answers local type `t`: a `type` of this module that
/// is not a schema endpoint (R8b's).
fn derives(c: *const Contexts, t: u32) bool {
    const e = c.cx.types.entry(c.id(t));
    return e.module == c.cx.module and e.kind == .adt and !e.schema_endpoint;
}

pub fn entriesOf(c: *const Contexts, a: Answer) []const Entry {
    return c.entries.items[a.entries.start..][0..a.entries.len];
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
    return c.answers[t * 2 + @intFromEnum(kind)];
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
/// `ri`: a pass of the same run depends on it; any other run is partial.
fn noteApprox(c: *Contexts, s: *const Solve, ri: u32, slot: u32) Error!void {
    const reader = c.active(s) orelse return;
    const r = &c.runs.items[reader];
    if (reader != ri) {
        r.partial = true;
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
    if (c.module_has[@intFromEnum(kind)]) return .{ .status = .own_method };
    if (c.readable(s, u)) |ri| {
        const slot = c.member_of[t] * 2 + @intFromEnum(kind);
        try c.noteApprox(s, ri, slot);
        return c.runs.items[ri].approx[slot];
    }
    if (!c.valid(u)) return null;
    c.noteMemo(s, u);
    return c.answers[t * 2 + @intFromEnum(kind)];
}

/// The answer for `(type_id, kind)` for a wanted at `origin` that derives
/// it: the current approximation, the memo, or a fixpoint run now. A result
/// read from the memo (or just computed) is REPLAYED for this asker
/// (§11.2): one ordinary wanted per closed in-flight method it reached.
pub fn query(s: *Solve, type_id: Types.TypeId, kind: Kind, origin: Bir.Inst.Index) Error!Answer {
    const c = &s.contexts;
    if (try c.peek(s, type_id, kind)) |a| {
        const t = c.local(type_id).?;
        const u = c.unit_of[t];
        // Only a valid memo's replay list is this generation's: a `peek`
        // that answered without one (`own_method`) replays nothing (R8a's
        // review, nit).
        if (u != none and c.valid(u) and c.readable(s, u) == null) try replay(s, u, origin);
        return a;
    }
    const t = c.local(type_id).?;
    const u = c.unit_of[t];
    try ensure(s, u);
    c.noteMemo(s, u);
    try replay(s, u, origin);
    return c.answers[t * 2 + @intFromEnum(kind)];
}

/// Unit `u`'s result, computed if it is not valid: its dependencies first,
/// in order, so no chain of types recurses natively (I4).
pub fn ensure(s: *Solve, u: u32) Error!void {
    const c = &s.contexts;
    if (c.valid(u)) return;
    c.walks += 1;
    const stamp = c.walks;
    const Item = struct { unit: u32, next: u32 };
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(c.cx.scratch);
    try stack.append(c.cx.scratch, .{ .unit = u, .next = c.dep_starts[u] });
    c.seen[u] = stamp;
    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        if (top.next < c.dep_starts[top.unit + 1]) {
            const v = c.deps[top.next];
            top.next += 1;
            if (c.seen[v] == stamp or c.valid(v) or c.readable(s, v) != null) continue;
            c.seen[v] = stamp;
            try stack.append(c.cx.scratch, .{ .unit = v, .next = c.dep_starts[v] });
            continue;
        }
        const done = stack.pop().?.unit;
        if (done == u or (!c.valid(done) and c.readable(s, done) == null)) try run(s, done);
    }
}

/// P5: every unit's final result, from `done` inputs (P4 is over), in
/// dependency order.
pub fn settleAll(s: *Solve) Error!void {
    const c = &s.contexts;
    s.resolver.steps = 0;
    const unit_count = c.units.starts.len -| 1;
    for (0..unit_count) |u| {
        const members = c.units.order[c.units.starts[u]..c.units.starts[u + 1]];
        if (members.len == 0 or c.unit_of[members[0]] == none) continue;
        if (c.memo[u] == .permanent) continue;
        try run(s, @intCast(u));
    }
}

/// One replay item per closed in-flight method unit `u`'s result reached:
/// an ordinary wanted in the asker's frame (§11.2, R8-3).
fn replay(s: *Solve, u: u32, origin: Bir.Inst.Index) Error!void {
    const c = &s.contexts;
    const r = c.replay_of[u];
    if (r.len == 0) return;
    const items = try c.cx.scratch.dupe(Replay, c.replays.items[r.start..][0..r.len]);
    defer c.cx.scratch.free(items);
    for (items) |item| {
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
    const members = c.units.order[c.units.starts[u]..c.units.starts[u + 1]];
    const slots: u32 = @intCast(members.len * 2);

    try Generalize.pushFrame(s, @intCast(s.frames.items.len + 1), .fixpoint);
    const real = s.report;
    s.report = try quietReport(s);
    s.nest_units += Groups.nest_cost;
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
            const kind: Kind = @enumFromInt(slot % 2);
            if (c.module_has[@intFromEnum(kind)]) {
                r.approx[slot] = .{ .status = .own_method };
                continue;
            }
            r.approx[slot] = .{ .status = .present };
            r.queued[slot] = true;
            try r.worklist.append(scratch, slot);
        }
    }
    while (c.runs.items[ri].worklist.pop()) |slot| {
        c.runs.items[ri].queued[slot] = false;
        // Its replay items are the last pass's.
        {
            const r = &c.runs.items[ri];
            var i: usize = 0;
            while (i < r.in_flight.items.len) {
                if (r.in_flight.items[i].slot == slot) _ = r.in_flight.orderedRemove(i) else i += 1;
            }
        }
        const got = try pass(s, ri, members[slot / 2], @enumFromInt(slot % 2), slot);
        const r = &c.runs.items[ri];
        if (c.same(r.approx[slot], got)) {
            // Keep the newest templates. `same` does not compare them, and
            // need not: a template's leaves are the type's parameters or
            // ground, and a marker that is bound is `absent`, so a template
            // changes only with the set (§11.2 *as built by R8a*, S5).
            if (std.debug.runtime_safety) try assertSameTemplate(s, r.approx[slot], got);
            r.approx[slot] = got;
            continue;
        }
        r.approx[slot] = got;
        for (r.deps.items) |dep| {
            if (dep[1] != slot or r.queued[dep[0]]) continue;
            r.queued[dep[0]] = true;
            try r.worklist.append(scratch, dep[0]);
        }
    }
    var r = c.runs.pop().?;
    for (members, 0..) |t, i| {
        c.answers[t * 2] = r.approx[i * 2];
        c.answers[t * 2 + 1] = r.approx[i * 2 + 1];
    }
    const start: u32 = @intCast(c.replays.items.len);
    try c.replays.appendSlice(scratch, r.in_flight.items);
    c.replay_of[u] = .{ .start = start, .len = @intCast(r.in_flight.items.len) };
    var needs = false;
    for (r.approx) |a| needs = needs or a.status == .needs_annotation;
    c.memo[u] = if (r.partial) .none else if (r.generational or needs or r.in_flight.items.len != 0) .generational else .permanent;
    // Only a permanent result's last passes are row bodies, committed with
    // its answers: one that read something in flight is computed again in P5.
    for (members, 0..) |t, i| {
        const keep = c.memo[u] == .permanent;
        c.bodies[t * 2] = if (keep) r.bodies[i * 2] else .{};
        c.bodies[t * 2 + 1] = if (keep) r.bodies[i * 2 + 1] else .{};
    }
    c.memo_gen[u] = c.generation;
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

fn same(c: *const Contexts, a: Answer, b: Answer) bool {
    if (a.status != b.status or a.culprit != b.culprit) return false;
    const x = c.entriesOf(a);
    const y = c.entriesOf(b);
    if (x.len != y.len) return false;
    for (x, y) |p, q| {
        if (p.param != q.param or p.method != q.method) return false;
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
    const d = bir.decls[cx.types.entry(c.id(t)).decl.int()];
    const params = bir.declTypeParams(d);
    var b = cx.builder(.flex, s.frame().rank);
    defer b.deinit();
    const markers = try scratch.alloc(Var, params.len);
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
    {
        const r = &c.runs.items[ri];
        r.current = slot;
        r.culprit = none;
        r.saw_function = false;
        r.private = null;
    }
    defer {
        const r = &c.runs.items[ri];
        r.current = none;
        r.markers = &.{};
    }
    const wanted_start: u32 = @intCast(s.evidence.wanteds.items.len);
    const p = (try readPayloads(s, t)) orelse return .{ .status = .absent_other };
    c.runs.items[ri].markers = p.markers;
    const ids = try resolvePayloads(s, p, kind);
    try Decide.drain(s, s.frame().queue, true);
    // The last pass of a slot read every entry at its final value (the
    // worklist re-runs a pass whose read grew), so once the run is memoised
    // permanently it IS the row's body, and P5 reads no payload again.
    c.runs.items[ri].bodies[slot] = .{ .markers = p.markers, .ids = ids, .set = true };
    return c.collect(s, ri, t, p.markers, ids, wanted_start);
}

/// What a pass's positions say (§11.2): `needs_annotation` when a parametric
/// in-flight method was met; `absent` when a position failed, a marker
/// stopped being a distinct plain flex, or a wanted of the pass is left open
/// on anything but a marker; else `present`, one entry per wanted open on a
/// marker, sorted by `(param, method text)`, each of another method than
/// `eq` or `compare` with its type frozen over the template parameters.
fn collect(c: *Contexts, s: *Solve, ri: u32, t: u32, markers: []const Var, ids: []const Evidence.WantedId, wanted_start: u32) Error!Answer {
    const cx = c.cx;
    const st = cx.store;
    const scratch = cx.scratch;
    const r = c.runs.items[ri];
    if (r.culprit != none) return .{ .status = .needs_annotation, .culprit = r.culprit };
    const failed: Answer = if (r.private) |p|
        .{ .status = .absent_private, .culprit = p.module, .method = p.method }
    else
        .{ .status = if (r.saw_function) .absent_function else .absent_other };
    for (ids) |wid| {
        if (s.evidence.get(wid).state == .failed) return failed;
    }
    // Every marker a distinct plain flex, found in linear time: each root is
    // stamped `seen` (R8a's reviews: a type of tens of thousands of
    // parameters).
    const seen = st.nextMark();
    for (markers) |m| {
        const root = st.find(m);
        switch (st.content(root)) {
            .flex => |flags| if (flags.kind != .any) return failed,
            else => return failed,
        }
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
        const lineage = Resolve.lineageRoot(s, @enumFromInt(@as(u32, @intCast(i))));
        if (lineage.int() < wanted_start or !mine.isSet(lineage.int() - wanted_start)) continue;
        if (w.state == .ready or st.mark(st.find(w.receiver)) != seen) return failed;
    }
    const first: u32 = @intCast(c.entries.items.len);
    var method_types: std.ArrayList(Var) = .empty;
    defer method_types.deinit(scratch);
    for (markers, 0..) |m, i| {
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
        // `equatable` row riding on it (R8a's review, B1): not an evidence
        // wanted, but a requirement of the argument all the same. It is the
        // entry `(i, eq)`, as a boundary's flag is (`Derivable.boundaryStep`)
        // and as v1's requirement bits said, so an argument that holds a
        // function is refused at the use.
        if (!asks_eq and (flags.equatable or s.obligations.openEquatable(flags.obls) != null)) {
            try c.entries.append(scratch, .{ .param = @intCast(i), .method = InternPool.WellKnown.eq.symbol() });
        }
    }
    // One frozen tuple for every method type the entries need, over the
    // template parameters, frozen once (not once per entry).
    var template: Var.Optional = .none;
    if (method_types.items.len != 0) {
        const range = try st.addVars(method_types.items);
        const tuple = try s.fresh(.{ .structure = .{ .tuple = range } });
        template = (try s.instantiate.freeze(tuple, markers, try c.paramsOf(t))).toOptional();
    }
    const got = c.entries.items[first..];
    std.mem.sort(Entry, got, cx.interner, entryLessThan);
    return .{ .status = .present, .entries = .{ .start = first, .len = @intCast(got.len) }, .template = template };
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
/// wanted, in the asker's frame, never this frame's (round 4, R8-3).
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

/// A group completed (§11.2, *Memo generations*).
pub fn groupDone(c: *Contexts) void {
    c.generation +%= 1;
}

/// A run's pass met another module's private method: an `absent` entry is
/// `private_method` at the use (§11.2, §11.3).
pub fn notePrivate(c: *Contexts, s: *const Solve, module: u32, method: Symbol) void {
    const ri = c.active(s) orelse return;
    if (c.runs.items[ri].private == null) c.runs.items[ri].private = .{ .module = module, .method = method };
}

/// Whether `type_id`'s answers are memoised permanently: a verdict built on
/// them may be kept past its walk (`Derivable`).
pub fn settled(c: *const Contexts, type_id: Types.TypeId) bool {
    const t = c.local(type_id) orelse return true;
    const u = c.unit_of[t];
    return u == none or c.memo[u] == .permanent;
}

// ---------------------------------------------------------------------------
// Tests: a supplement (CLAUDE.md rule 3). The behaviour is `scenario/PERM`'s
// derived-context programs and the `check/bad/DerivedContext*` fixtures in both
// declaration orders; what is here is the memo's generation rule alone.
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
