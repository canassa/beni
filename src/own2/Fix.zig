//! L8: the fixpoint driver (`docs/design/ownership-v2.md` §2.12). As built
//! for S4-verifier (#1180): its proof half, §2.12's *Recursive proofs* — a
//! finite obligation graph over settled may-facts, and its verifier. S3b adds
//! the worklist and the sparse propagation beside it.
//!
//! A **goal** is a Boolean claim about a port — a function value's family of
//! closures, a recursive value such as a fold's feedback, a consumer's
//! demand — keyed `(claim, port, arg)`. The `Equations` the layer above
//! passes down expand a goal, once per settled generation, into its
//! **alternatives**: every way the port's value may be made, read from
//! settled may-facts, each with a local verdict, the atoms it leaves to the
//! consumer, and the goals it needs. A goal holds when every alternative
//! holds; an alternative holds when its local check passes and every goal it
//! needs holds. There is no "or": a may-fact alternative is never an excuse.
//!
//! Goals are decided by strongly connected component (Tarjan on an explicit
//! stack), dependencies first. A component without a cycle is decided from
//! its dependencies' answers. A recursive component is an induction: its
//! **base** is every alternative that needs no member — checked with no
//! assumption at all — and its **step** every other alternative, checked
//! under the explicit invariant assumption that the members hold of the
//! values the step receives. The evaluators below are what make every edge
//! into a member a dependency on a value made strictly earlier — the
//! incoming feedback value, a closure an earlier activation built, a nested
//! call's answer — from the cells' origins, so the induction is well founded.
//! A component with no base is a cycle assuming itself: `waiting`, which
//! fails the demand approximately, never `proved`.
//!
//! The evaluators turn a value into an alternative with the existing algebra
//! (`Shape.cellsAt`, `Cond.sep`): `gen` (each invocation answers only objects
//! allocated by it — its body or a call it makes; a feedback value, a supply
//! or a capture is not), `inv` (an invariant of a recursive value: its atoms
//! over the incoming value are discharged by the assumption alone, and only
//! when the invariant states them), `within` and `apartCalls` at a consumer
//! (distinct per call: a fresh result, a callee's proved generative answer
//! from calls that are separate — `diverge` — or a taken element of
//! one traversal certificate). `Marks` carry §2.2's traversal certificate;
//! `foldPair` keeps `within`'s pre-fold provenance.
//!
//! **Settled generations.** Every port has a version; an expansion records
//! the versions it read. `bump` invalidates exactly the goals that read the
//! port and, through reverse dependency edges, their consumers. An answer is
//! published only after its whole solve succeeded and every version it read
//! is still current; otherwise the solve runs again against the new versions.
//! A refused reservation publishes nothing; answers already published stay.
//!
//! Obligations kept here: O11 (every goal, alternative, read and edge is
//! reserved before it is made, and a refused reservation publishes no
//! answer), O14's recursive half (a `within`, or a `sep` over callback
//! results, holds only by an independently proved claim or one traversal
//! certificate; a cycle or an exhausted resource establishes neither,
//! Lemma 2).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Cell = @import("Cell.zig");
const Shape = @import("Shape.zig");
const Cond = @import("Cond.zig");
const stamped = @import("../stamped.zig");

pub const TaskId = Ids.TaskId;
pub const CellId = Ids.CellId;
pub const LabelId = Ids.LabelId;
pub const NodeId = Ids.NodeId;
pub const SetId = Ids.SetId;
pub const CondId = Ids.CondId;
pub const PathId = Ids.PathId;
pub const Charge = Ids.Charge;
pub const Error = Ids.ChargeError;
pub const Status = Facts.ProofAnswer.Status;
pub const Exactness = Facts.Exactness;
pub const Step = Shape.Step;

/// What a goal claims of its port: `gen`, each invocation of a function
/// value answers objects it allocated (R-5.4.8); `inv`, an invariant of a
/// recursive value (`arg` its `Invariant`); `demand`, a consumer's check.
pub const Claim = enum(u8) { gen, inv, demand };

pub const Goal = struct { claim: Claim, port: u32, arg: u32 = 0 };

pub const Answer = struct {
    status: Status,
    /// A refusal's: exact only where a member's own alternative failed
    /// exactly; a failure reached through a dependency or a cycle is not.
    exactness: Exactness = .exact,
    /// The atoms left for the consumer (`Cond.yes` when none).
    xreq: CondId = Cond.yes,
};

/// An alternative's own verdict: it passes, or it fails exactly or
/// approximately.
pub const Local = enum(u8) { ok, exact, approximate };

const Alt = struct { local: Local, xreq: CondId, deps: Ids.Range };

const Record = struct {
    claim: Claim,
    port: u32,
    arg: u32,
    alts: Ids.Range,
    deps: Ids.Range,
    reads: Ids.Range,
    status: Status,
    exactness: Exactness,
    xreq: CondId,
    /// Published and current: the answer may be served.
    valid: bool,
    /// Bumped at every publication, so a reverse edge from an older one is
    /// skipped (`Rev`).
    epoch: u32,
};

/// A reverse edge: `goal` (at its publication `epoch`) read a port or
/// needed a goal; `next` the list's next entry.
const Rev = struct { goal: TaskId, epoch: u32, next: u32 };

comptime {
    Ids.assertRecord(Record);
    Ids.assertRecord(Alt);
    Ids.assertRecord(Rev);
}

/// The proof work done, for §4.1's account and the tests' counts.
pub const Stats = struct {
    expanded: u64 = 0,
    alternatives: u64 = 0,
    deps: u64 = 0,
    reads: u64 = 0,
    components: u64 = 0,
    base: u64 = 0,
    step: u64 = 0,
    published: u64 = 0,
    invalidated: u64 = 0,
    memo_hits: u64 = 0,
    stale_reruns: u64 = 0,
};

/// The layer above's equations: expand one goal into its alternatives,
/// reading ports through `Expansion.read`.
pub const Equations = struct {
    ctx: *anyopaque,
    expand: *const fn (ctx: *anyopaque, ex: *Expansion) Error!void,
};

/// What a callback's answer, or a known closure's call, needs: the `gen` goal
/// of the actual family (`null`: unknown, `⊤call`).
pub const Resolve = struct {
    ctx: *anyopaque,
    callee: *const fn (ctx: *anyopaque, c: CellId) ?Goal,
};

/// An invariant of a recursive value (§2.12, *Recursive proofs*): the step
/// receives the value as parameter `incoming`; at every `owned` path the
/// object is owned and fresh or the incoming one; `pairs` is the `sep` atoms
/// over the incoming parameter's cells it states.
pub const Invariant = struct { incoming: u32, owned: []const PathId, pairs: CondId };

const Spec = struct { incoming: u32, owned: Ids.Range, pairs: CondId };

pub const Prover = struct {
    goals: std.MultiArrayList(Record) = .empty,
    intern_goal: Ids.FixedDict(3) = .{},
    alts: std.ArrayList(Alt) = .empty,
    deps: std.ArrayList(TaskId) = .empty,
    reads: std.ArrayList([2]u32) = .empty,
    versions: std.ArrayList(u32) = .empty,
    /// The head of each port's reader list, each goal's user list (`Rev`).
    port_readers: std.ArrayList(u32) = .empty,
    goal_users: std.ArrayList(u32) = .empty,
    revs: std.ArrayList(Rev) = .empty,
    specs: std.ArrayList(Spec) = .empty,
    spec_paths: std.ArrayList(PathId) = .empty,
    /// `within`'s provenance: a folded label → its pre-fold pair's index.
    provenance: Ids.FixedDict(1) = .{},
    pairs: std.ArrayList([2]LabelId) = .empty,
    stats: Stats = .{},

    pub fn deinit(p: *Prover, gpa: Allocator) void {
        p.goals.deinit(gpa);
        p.intern_goal.deinit(gpa);
        p.alts.deinit(gpa);
        p.deps.deinit(gpa);
        p.reads.deinit(gpa);
        p.versions.deinit(gpa);
        p.port_readers.deinit(gpa);
        p.goal_users.deinit(gpa);
        p.revs.deinit(gpa);
        p.specs.deinit(gpa);
        p.spec_paths.deinit(gpa);
        p.provenance.deinit(gpa);
        p.pairs.deinit(gpa);
    }

    // ---- ports and generations ---------------------------------------------

    /// A new port at version 0.
    pub fn port(p: *Prover, gpa: Allocator, charge: Charge) Error!u32 {
        try charge.reserve(gpa, .other, 1);
        try p.versions.ensureUnusedCapacity(gpa, 1);
        try p.port_readers.ensureUnusedCapacity(gpa, 1);
        p.versions.appendAssumeCapacity(0);
        p.port_readers.appendAssumeCapacity(Ids.none_int);
        return @intCast(p.versions.items.len - 1);
    }

    pub fn version(p: *const Prover, port_id: u32) u32 {
        return p.versions.items[port_id];
    }

    /// The port's value changed: a new version, and every goal that read it,
    /// and every consumer of those, invalidated — no other. A refused
    /// reservation part way invalidates every answer: none of the old
    /// generation may be served.
    pub fn bump(p: *Prover, gpa: Allocator, charge: Charge, port_id: u32) Error!void {
        p.versions.items[port_id] += 1;
        errdefer @memset(p.goals.items(.valid), false);
        var stack: std.ArrayList(TaskId) = .empty;
        defer stack.deinit(gpa);
        var r = p.port_readers.items[port_id];
        while (r != Ids.none_int) : (r = p.revs.items[r].next) try p.queueStale(gpa, charge, &stack, p.revs.items[r]);
        while (stack.pop()) |g| {
            var u = p.goal_users.items[g.int()];
            while (u != Ids.none_int) : (u = p.revs.items[u].next) try p.queueStale(gpa, charge, &stack, p.revs.items[u]);
        }
    }

    fn queueStale(p: *Prover, gpa: Allocator, charge: Charge, stack: *std.ArrayList(TaskId), e: Rev) Error!void {
        try charge.reserve(gpa, .inspection, 1);
        const i = e.goal.int();
        if (!p.goals.items(.valid)[i] or p.goals.items(.epoch)[i] != e.epoch) return;
        p.goals.items(.valid)[i] = false;
        p.stats.invalidated += 1;
        try stack.append(gpa, e.goal);
    }

    // ---- goals ---------------------------------------------------------------

    pub fn goalId(p: *Prover, gpa: Allocator, charge: Charge, g: Goal) Error!TaskId {
        try charge.reserve(gpa, .task, 1);
        try p.goals.ensureUnusedCapacity(gpa, 1);
        try p.goal_users.ensureUnusedCapacity(gpa, 1);
        const got = try p.intern_goal.getOrPut(gpa, .{ @backingInt(g.claim), g.port, g.arg });
        if (got.found_existing) return .from(got.value_ptr.*);
        got.value_ptr.* = @intCast(p.goals.len);
        p.goals.appendAssumeCapacity(.{ .claim = g.claim, .port = g.port, .arg = g.arg, .alts = .empty, .deps = .empty, .reads = .empty, .status = .waiting, .exactness = .approximate, .xreq = Cond.yes, .valid = false, .epoch = 0 });
        p.goal_users.appendAssumeCapacity(Ids.none_int);
        return .from(got.value_ptr.*);
    }

    fn goalOf(p: *const Prover, id: TaskId) Goal {
        const r = p.goals.get(id.int());
        return .{ .claim = r.claim, .port = r.port, .arg = r.arg };
    }

    fn published(p: *const Prover, id: TaskId) Answer {
        const r = p.goals.get(id.int());
        return .{ .status = r.status, .exactness = r.exactness, .xreq = r.xreq };
    }

    /// The answer of a goal that is published and current, else null.
    pub fn cached(p: *const Prover, gpa: Allocator, charge: Charge, g: Goal) Error!?Answer {
        try charge.reserve(gpa, .memo, 1);
        const hit = p.intern_goal.get(.{ @backingInt(g.claim), g.port, g.arg }) orelse return null;
        if (!p.goals.items(.valid)[hit]) return null;
        return p.published(.from(hit));
    }

    /// An invariant the equations name in an `inv` goal's `arg`.
    pub fn invariant(p: *Prover, gpa: Allocator, charge: Charge, inv: Invariant) Error!u32 {
        try charge.reserve(gpa, .other, 1 + @as(u32, @intCast(inv.owned.len)));
        const start: u32 = @intCast(p.spec_paths.items.len);
        try p.spec_paths.appendSlice(gpa, inv.owned);
        try p.specs.append(gpa, .{ .incoming = inv.incoming, .owned = .{ .start = start, .len = @intCast(inv.owned.len) }, .pairs = inv.pairs });
        return @intCast(p.specs.items.len - 1);
    }

    // ---- proving ---------------------------------------------------------------

    /// Decide `g` against the current versions: a published current answer is
    /// served; otherwise every stale goal it reaches is expanded once and the
    /// graph decided; a version changed meanwhile solves again.
    pub fn prove(p: *Prover, gpa: Allocator, charge: Charge, conds: *Cond.Table, eqs: Equations, g: Goal) Error!Answer {
        while (true) {
            if (try p.cached(gpa, charge, g)) |a| {
                p.stats.memo_hits += 1;
                return a;
            }
            const root = try p.goalId(gpa, charge, g);
            if (try p.solve(gpa, charge, conds, eqs, root)) return p.published(root);
            p.stats.stale_reruns += 1;
        }
    }

    const Visit = struct { index: u32, low: u32, on_stack: bool, component: u32 };
    const Frame = struct { goal: TaskId, cursor: u32 };

    /// One solve: Tarjan over the stale goals reachable from `root`, each
    /// expanded when first met, each component decided when it closes.
    /// Answers are published at the end, only if every read is still
    /// current; false otherwise (nothing published).
    fn solve(p: *Prover, gpa: Allocator, charge: Charge, conds: *Cond.Table, eqs: Equations, root: TaskId) Error!bool {
        var visit: stamped.Column(TaskId, Visit) = .{};
        defer visit.deinit(gpa);
        var answers: stamped.Column(TaskId, Answer) = .{};
        defer answers.deinit(gpa);
        var stack: std.ArrayList(TaskId) = .empty;
        defer stack.deinit(gpa);
        var frames: std.ArrayList(Frame) = .empty;
        defer frames.deinit(gpa);
        var decided: std.ArrayList(TaskId) = .empty;
        defer decided.deinit(gpa);
        var counter: u32 = 0;
        var components: u32 = 0;

        try p.enter(gpa, charge, eqs, root, &visit, &stack, &frames, &counter);
        while (frames.items.len > 0) {
            const top = &frames.items[frames.items.len - 1];
            const deps = p.goals.items(.deps)[top.goal.int()];
            if (top.cursor < deps.len) {
                const d = p.deps.items[deps.start + top.cursor];
                top.cursor += 1;
                try charge.reserve(gpa, .inspection, 1);
                if (p.goals.items(.valid)[d.int()] or answers.contains(d)) continue;
                if (visit.get(d)) |v| {
                    if (v.on_stack) {
                        const me = visit.getPtr(top.goal).?;
                        me.low = @min(me.low, v.index);
                    }
                    continue;
                }
                try p.enter(gpa, charge, eqs, d, &visit, &stack, &frames, &counter);
                continue;
            }
            const g = top.goal;
            _ = frames.pop();
            const mine = visit.get(g).?;
            if (frames.items.len > 0) {
                const parent = visit.getPtr(frames.items[frames.items.len - 1].goal).?;
                parent.low = @min(parent.low, mine.low);
            }
            if (mine.low != mine.index) continue;
            // `g` closes a component: the stack down to it.
            var at = stack.items.len;
            while (true) {
                at -= 1;
                if (stack.items[at] == g) break;
            }
            const members = stack.items[at..];
            for (members) |m| {
                const v = visit.getPtr(m).?;
                v.on_stack = false;
                v.component = components;
            }
            const a = try p.decide(gpa, charge, conds, members, components, &visit, &answers);
            for (members) |m| {
                try answers.put(gpa, m, a);
                try decided.append(gpa, m);
            }
            components += 1;
            stack.shrinkRetainingCapacity(at);
        }
        p.stats.components += components;

        // Publish only what every read, and every published answer used,
        // still holds for: a version changed meanwhile is a newer generation.
        for (decided.items) |m| {
            const rr = p.goals.items(.reads)[m.int()];
            for (p.reads.items[rr.start..][0..rr.len]) |r| if (p.versions.items[r[0]] != r[1]) return false;
            const dr = p.goals.items(.deps)[m.int()];
            for (p.deps.items[dr.start..][0..dr.len]) |d| if (!answers.contains(d) and !p.goals.items(.valid)[d.int()]) return false;
        }
        try p.publishAll(gpa, charge, decided.items, &answers);
        return true;
    }

    fn enter(p: *Prover, gpa: Allocator, charge: Charge, eqs: Equations, g: TaskId, visit: *stamped.Column(TaskId, Visit), stack: *std.ArrayList(TaskId), frames: *std.ArrayList(Frame), counter: *u32) Error!void {
        try p.expand(gpa, charge, eqs, g);
        try visit.put(gpa, g, .{ .index = counter.*, .low = counter.*, .on_stack = true, .component = Ids.none_int });
        counter.* += 1;
        try stack.append(gpa, g);
        try frames.append(gpa, .{ .goal = g, .cursor = 0 });
    }

    fn expand(p: *Prover, gpa: Allocator, charge: Charge, eqs: Equations, g: TaskId) Error!void {
        var ex: Expansion = .{ .p = p, .gpa = gpa, .charge = charge, .goal = p.goalOf(g), .id = g, .first_alt = @intCast(p.alts.items.len), .first_dep = @intCast(p.deps.items.len), .first_read = @intCast(p.reads.items.len) };
        try eqs.expand(eqs.ctx, &ex);
        const alts: Ids.Range = .{ .start = ex.first_alt, .len = @as(u32, @intCast(p.alts.items.len)) - ex.first_alt };
        p.goals.items(.alts)[g.int()] = alts;
        p.goals.items(.deps)[g.int()] = .{ .start = ex.first_dep, .len = @as(u32, @intCast(p.deps.items.len)) - ex.first_dep };
        p.goals.items(.reads)[g.int()] = .{ .start = ex.first_read, .len = @as(u32, @intCast(p.reads.items.len)) - ex.first_read };
        p.stats.expanded += 1;
    }

    /// One component's answer, the same for every member (every member
    /// reaches every other through "and"). The base: alternatives needing
    /// no member, read with no assumption. The step: the others, under the
    /// assumption that the members hold. No base in a cycle: `waiting`.
    fn decide(p: *Prover, gpa: Allocator, charge: Charge, conds: *Cond.Table, members: []const TaskId, component: u32, visit: *stamped.Column(TaskId, Visit), answers: *stamped.Column(TaskId, Answer)) Error!Answer {
        var recursive = members.len > 1;
        var has_base = false;
        var refused = false;
        var exact = false;
        var waiting = false;
        var xreq: CondId = Cond.yes;
        for (members) |m| {
            const ar = p.goals.items(.alts)[m.int()];
            for (p.alts.items[ar.start..][0..ar.len]) |alt| {
                try charge.reserve(gpa, .inspection, 1);
                switch (alt.local) {
                    .ok => {},
                    .exact => {
                        refused = true;
                        exact = true;
                    },
                    .approximate => refused = true,
                }
                xreq = try conds.@"and"(gpa, charge, xreq, alt.xreq);
                var internal = false;
                for (p.deps.items[alt.deps.start..][0..alt.deps.len]) |d| {
                    try charge.reserve(gpa, .inspection, 1);
                    if (visit.get(d)) |v| if (v.component == component) {
                        internal = true;
                        if (d == m) recursive = true;
                        continue;
                    };
                    const a = answers.get(d) orelse p.published(d);
                    switch (a.status) {
                        .proved => xreq = try conds.@"and"(gpa, charge, xreq, a.xreq),
                        .refuted => refused = true,
                        .waiting => waiting = true,
                    }
                }
                if (internal) p.stats.step += 1 else {
                    p.stats.base += 1;
                    has_base = true;
                }
            }
        }
        if (refused) return .{ .status = .refuted, .exactness = if (exact) .exact else .approximate };
        if (waiting or (recursive and !has_base)) return .{ .status = .waiting, .exactness = .approximate };
        return .{ .status = .proved, .xreq = xreq };
    }

    /// Publish a solve's answers, all or none: every record and every byte
    /// is reserved before the first answer is served.
    fn publishAll(p: *Prover, gpa: Allocator, charge: Charge, decided: []const TaskId, answers: *const stamped.Column(TaskId, Answer)) Error!void {
        var edges: u32 = 0;
        for (decided) |m| edges += p.goals.items(.reads)[m.int()].len + p.goals.items(.deps)[m.int()].len;
        try charge.reserve(gpa, .memo, @intCast(decided.len));
        try charge.reserve(gpa, .edge, edges);
        try p.revs.ensureUnusedCapacity(gpa, edges);
        for (decided) |m| p.publish(m, answers.get(m).?);
    }

    fn publish(p: *Prover, g: TaskId, a: Answer) void {
        const i = g.int();
        const epoch = p.goals.items(.epoch)[i] + 1;
        const rr = p.goals.items(.reads)[i];
        for (p.reads.items[rr.start..][0..rr.len]) |r| p.port_readers.items[r[0]] = p.rev(g, epoch, p.port_readers.items[r[0]]);
        const dr = p.goals.items(.deps)[i];
        for (p.deps.items[dr.start..][0..dr.len]) |d| p.goal_users.items[d.int()] = p.rev(g, epoch, p.goal_users.items[d.int()]);
        p.goals.items(.status)[i] = a.status;
        p.goals.items(.exactness)[i] = a.exactness;
        p.goals.items(.xreq)[i] = a.xreq;
        p.goals.items(.epoch)[i] = epoch;
        p.goals.items(.valid)[i] = true;
        p.stats.published += 1;
    }

    fn rev(p: *Prover, g: TaskId, epoch: u32, next: u32) u32 {
        p.revs.appendAssumeCapacity(.{ .goal = g, .epoch = epoch, .next = next });
        return @intCast(p.revs.items.len - 1);
    }

    // ---- `within`'s provenance -----------------------------------------------------

    /// The read-off's fold of a `sep` between the labels `a` and `b` into the
    /// folded label `folded` (§2.10): `within(folded)`, its pre-fold pair
    /// recorded, only when the two calls are separate (`diverge`); one label
    /// met twice is a self pair a fold made, and two calls of which one may
    /// run inside the other are no pair of separate calls: both `lost`
    /// (§2.9's `sep(c, c)`), never `within`.
    pub fn foldPair(p: *Prover, gpa: Allocator, charge: Charge, conds: *Cond.Table, cells: *const Cell.Table, a: LabelId, b: LabelId, folded: LabelId) Error!CondId {
        if (a == b or !diverge(cells, a, b)) return Cond.lost;
        try charge.reserve(gpa, .memo, 1);
        try p.pairs.ensureUnusedCapacity(gpa, 1);
        const got = try p.provenance.getOrPut(gpa, .{folded.int()});
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(p.pairs.items.len);
            p.pairs.appendAssumeCapacity(if (a.int() < b.int()) .{ a, b } else .{ b, a });
        }
        return conds.within(gpa, charge, folded);
    }

    /// `within(l)`'s recorded pre-fold pair; an atom without one (an imported
    /// self atom, a `sep(c, c)`) has none.
    pub fn provenanceOf(p: *const Prover, l: LabelId) ?[2]LabelId {
        return if (p.provenance.get(.{l.int()})) |i| p.pairs.items[i] else null;
    }
};

// ---- expanding a goal ----------------------------------------------------------------

/// The equations' handle while they expand one goal: `read` the ports the
/// answer depends on; `begin` an alternative, then `need`, `refute` and
/// `require` within it; or the evaluators, each one alternative.
pub const Expansion = struct {
    p: *Prover,
    gpa: Allocator,
    charge: Charge,
    goal: Goal,
    id: TaskId,
    first_alt: u32,
    first_dep: u32,
    first_read: u32,

    pub fn read(ex: *Expansion, port_id: u32) Error!void {
        try ex.charge.reserve(ex.gpa, .edge, 1);
        try ex.p.reads.append(ex.gpa, .{ port_id, ex.p.versions.items[port_id] });
        ex.p.stats.reads += 1;
    }

    pub fn begin(ex: *Expansion) Error!void {
        try ex.charge.reserve(ex.gpa, .other, 1);
        try ex.p.alts.append(ex.gpa, .{ .local = .ok, .xreq = Cond.yes, .deps = .{ .start = @intCast(ex.p.deps.items.len), .len = 0 } });
        ex.p.stats.alternatives += 1;
    }

    fn current(ex: *Expansion) *Alt {
        std.debug.assert(ex.p.alts.items.len > ex.first_alt);
        return &ex.p.alts.items[ex.p.alts.items.len - 1];
    }

    /// The current alternative needs `g`.
    pub fn need(ex: *Expansion, g: Goal) Error!void {
        const id = try ex.p.goalId(ex.gpa, ex.charge, g);
        try ex.charge.reserve(ex.gpa, .edge, 1);
        try ex.p.deps.append(ex.gpa, id);
        ex.current().deps.len += 1;
        ex.p.stats.deps += 1;
    }

    pub fn refute(ex: *Expansion, e: Exactness) void {
        const a = ex.current();
        if (e == .exact) a.local = .exact else if (a.local == .ok) a.local = .approximate;
    }

    /// The current alternative relies on `k`: `yes` nothing, a failure the
    /// refusal, atoms left to the consumer.
    pub fn require(ex: *Expansion, conds: *Cond.Table, k: CondId) Error!void {
        if (k == Cond.yes) return;
        if (k == Cond.shared) return ex.refute(.exact);
        if (k == Cond.lost) return ex.refute(.approximate);
        const a = ex.current();
        a.xreq = try conds.@"and"(ex.gpa, ex.charge, a.xreq, k);
    }

    /// The object `c` at an owned position: allocated by this invocation
    /// (`site`, a callee's `result`), a callback's or closure's answer (its
    /// family's `gen`), or the incoming recursive value's own cell at the same
    /// path (`inv`'s assumption). Anything else may be an object an earlier
    /// invocation or another holder has: a capture or a top-level value exactly
    /// (one object at every call), the rest approximately.
    fn owned(ex: *Expansion, cells: *const Cell.Table, c: CellId, path: PathId, incoming: ?u32, resolve: Resolve) Error!void {
        const d = cells.get(c);
        switch (d.origin) {
            .site, .result => {},
            .cb => if (resolve.callee(resolve.ctx, c)) |g| try ex.need(g) else ex.refute(.approximate),
            .param => if (incoming != null and d.a == incoming.? and d.b == path.int()) try ex.need(ex.goal) else ex.refute(.approximate),
            .env, .shared => ex.refute(.exact),
            .esc, .msg, .top, .elem, .others, .level, .below, .loan, .mark => ex.refute(.approximate),
        }
    }

    /// `gen`: every invocation answers, at `steps` of `n`, only objects
    /// allocated by it (§2.14 Lemma 2's "a result not reached through a
    /// feedback supply"). A call it makes answers objects allocated by this
    /// invocation when that family's own `gen` holds: the one edge, to an
    /// activation strictly inside this one, so induction on completed
    /// activations is well founded. `gen` separates two invocations only
    /// when neither runs inside the other (`diverge`).
    pub fn gen(ex: *Expansion, v: Cond.View, n: NodeId, steps: []const Step, resolve: Resolve) Error!void {
        try ex.begin();
        const s = try v.shapes.cellsAt(ex.gpa, ex.charge.account, v.places, v.cells, n, steps);
        var it = v.cells.sets.iterate(s);
        while (it.next()) |e| {
            try ex.charge.reserve(ex.gpa, .inspection, 1);
            if (e.value == 1) ex.refute(.approximate);
            try ex.owned(v.cells, .from(e.key), .none, null, resolve);
        }
    }

    /// `inv`: the step's outgoing value `n` (or an initial value, the base)
    /// keeps the invariant `arg` of an `inv` goal. Its owned paths hold owned
    /// objects; each atom of `pairs` is re-read at `n`'s cells by `Cond.sep`.
    /// An atom over the incoming value's cells is discharged only by the
    /// assumption and only when `pairs` states it; one it does not state
    /// fails (the invariant is not inductive); the rest are left.
    pub fn inv(ex: *Expansion, conds: *Cond.Table, v: Cond.View, n: NodeId, resolve: Resolve, traversal: ?Cond.Traversal) Error!void {
        std.debug.assert(ex.goal.claim == .inv);
        const spec = ex.p.specs.items[ex.goal.arg];
        try ex.begin();
        var steps: std.ArrayList(Step) = .empty;
        defer steps.deinit(ex.gpa);
        for (ex.p.spec_paths.items[spec.owned.start..][0..spec.owned.len]) |q| {
            const s = try ex.cellsAtPath(v, n, q, &steps);
            var it = v.cells.sets.iterate(s);
            while (it.next()) |e| {
                try ex.charge.reserve(ex.gpa, .inspection, 1);
                if (e.value == 1) ex.refute(.approximate);
                try ex.owned(v.cells, .from(e.key), q, spec.incoming, resolve);
            }
        }
        if (spec.pairs == Cond.yes) return;
        const stated = try conds.flat(ex.gpa, ex.charge, spec.pairs);
        var at = conds.atoms.iterate(stated);
        while (at.next()) |e| {
            const a = conds.get(.from(e.key));
            if (a.atom != .sep or !isIncoming(v.cells, .from(a.a), spec.incoming) or !isIncoming(v.cells, .from(a.b), spec.incoming)) {
                ex.refute(.approximate);
                continue;
            }
            const xs = try ex.cellsAtPath(v, n, .from(v.cells.get(.from(a.a)).b), &steps);
            const ys = try ex.cellsAtPath(v, n, .from(v.cells.get(.from(a.b)).b), &steps);
            var acc: CondId = Cond.yes;
            var ix = v.cells.sets.iterate(xs);
            while (ix.next()) |x| {
                var iy = v.cells.sets.iterate(ys);
                while (iy.next()) |y| acc = try conds.@"and"(ex.gpa, ex.charge, acc, try conds.sep(ex.gpa, ex.charge, v.cells, v.places, .from(x.key), .from(y.key), x.value == 1 or y.value == 1, traversal));
            }
            if (acc == Cond.yes) continue;
            if (Cond.Table.fails(acc)) {
                try ex.require(conds, acc);
                continue;
            }
            var bt = conds.atoms.iterate(try conds.flat(ex.gpa, ex.charge, acc));
            while (bt.next()) |b| {
                try ex.charge.reserve(ex.gpa, .inspection, 1);
                if (!mentions(conds, v.cells, .from(b.key), spec.incoming)) {
                    try ex.require(conds, .from(b.key));
                } else if (conds.atoms.member(stated, b.key)) {
                    try ex.need(ex.goal);
                } else ex.refute(.approximate);
            }
        }
    }

    fn cellsAtPath(ex: *Expansion, v: Cond.View, n: NodeId, q: PathId, steps: *std.ArrayList(Step)) Error!SetId {
        steps.clearRetainingCapacity();
        var at = q;
        while (v.places.pathParent(at) != .none) : (at = v.places.pathParent(at)) try steps.append(ex.gpa, v.places.pathStep(at));
        std.mem.reverse(Step, steps.items);
        return v.shapes.cellsAt(ex.gpa, ex.charge.account, v.places, v.cells, n, steps.items);
    }

    /// `within(l)` at a consumer, `set` its instantiated cells (what each
    /// invocation `l` stands for answers): distinct per call when each is a
    /// fresh `result`, a callee's generative answer, or a taken element whose
    /// mark certifies one traversal (under the container's κ). Otherwise one
    /// object answers twice: `sep(c, c)`. A `within` without its pre-fold
    /// provenance fails first.
    pub fn within(ex: *Expansion, conds: *Cond.Table, cells: *const Cell.Table, places: *const Cell.Places, l: LabelId, set: SetId, marks: *const Marks, resolve: Resolve) Error!void {
        try ex.begin();
        if (ex.p.provenanceOf(l) == null) return ex.refute(.approximate);
        var it = cells.sets.iterate(set);
        while (it.next()) |e| {
            try ex.charge.reserve(ex.gpa, .inspection, 1);
            const c: CellId = .from(e.key);
            switch (cells.origin(c)) {
                .result => if (e.value == 1) ex.refute(.approximate),
                .cb => if (resolve.callee(resolve.ctx, c)) |g| try ex.need(g) else ex.refute(.approximate),
                .elem => if (marks.certified(c)) |m| try ex.require(conds, m.cond) else ex.refute(.approximate),
                else => try ex.require(conds, try conds.sep(ex.gpa, ex.charge, cells, places, c, c, e.value == 1, null)),
            }
        }
    }

    /// Two answers `a` and `b` at a consumer apart: two different callback
    /// labels are two calls, apart when both families are generative; one
    /// label twice is one call (no "fresh means apart" for one invocation);
    /// anything else `Cond.sep` decides, a taken pair by `traversal`.
    pub fn apartCalls(ex: *Expansion, conds: *Cond.Table, cells: *const Cell.Table, places: *const Cell.Places, a: SetId, b: SetId, resolve: Resolve, traversal: ?Cond.Traversal) Error!void {
        try ex.begin();
        var ia = cells.sets.iterate(a);
        while (ia.next()) |x| {
            var ib = cells.sets.iterate(b);
            while (ib.next()) |y| {
                try ex.charge.reserve(ex.gpa, .inspection, 1);
                const cx: CellId = .from(x.key);
                const cy: CellId = .from(y.key);
                if (cx != cy and cells.origin(cx) == .cb and cells.origin(cy) == .cb) {
                    // A call inside the other may answer the other's object.
                    if (!diverge(cells, .from(cells.get(cx).a), .from(cells.get(cy).a))) ex.refute(.approximate);
                    for ([_]CellId{ cx, cy }) |c| if (resolve.callee(resolve.ctx, c)) |g| try ex.need(g) else ex.refute(.approximate);
                    continue;
                }
                try ex.require(conds, try conds.sep(ex.gpa, ex.charge, cells, places, cx, cy, x.value == 1 or y.value == 1, traversal));
            }
        }
    }
};

/// Whether the calls the labels `a` and `b` name are separate: their chains
/// part at some instruction, so the two invocations are disjoint subtrees of
/// the activation tree (two calls one activation makes, at any depth). One
/// chain a prefix of the other — a call made inside the other's, a callback
/// re-entering its caller — or a tail a fold dropped: they may nest, and a
/// nested invocation's answer may be the outer one's (`gen` holds of both).
pub fn diverge(cells: *const Cell.Table, a: LabelId, b: LabelId) bool {
    var x = a;
    var y = b;
    while (x != .none and y != .none) {
        const lx = cells.labelOf(x);
        const ly = cells.labelOf(y);
        if (lx.inst != ly.inst) return true;
        x = lx.callee_label;
        y = ly.callee_label;
    }
    return false;
}

/// Whether `c` is the incoming parameter's own cell at some path.
fn isIncoming(cells: *const Cell.Table, c: CellId, incoming: u32) bool {
    return cells.origin(c) == .param and cells.get(c).a == incoming;
}

/// Whether atom `b` names a cell over parameter `incoming`.
fn mentions(conds: *const Cond.Table, cells: *const Cell.Table, b: CondId, incoming: u32) bool {
    const a = conds.get(b);
    const over = struct {
        fn param(ct: *const Cell.Table, c: CellId, i: u32) bool {
            const base = ct.base(c);
            return ct.origin(base) == .param and ct.get(base).a == i;
        }
    }.param;
    return switch (a.atom) {
        .sep => over(cells, .from(a.a), incoming) or over(cells, .from(a.b), incoming),
        .excl => over(cells, .from(a.a), incoming),
        .apart => blk: {
            var it = cells.sets.iterate(.from(a.a));
            while (it.next()) |e| if (over(cells, .from(e.key), incoming)) break :blk true;
            break :blk false;
        },
        .within, .keep, .writes => false,
    };
}

// ---- traversal marks (§2.2 *Traversals*, §3.6 *Traversal marks*) ------------------

/// A taken refinement's certificate: its container's lineage, the entry
/// label of the traversal that made it (`none`: this group's own entry),
/// `single` (every activation its label stands for is one traversal), and
/// κ of the container at `[*]` the split was made under.
pub const Mark = struct { container: CellId, entry: LabelId, single: bool, cond: CondId };

/// How a split crosses a call instruction on its way out (§2.2's rules):
/// the group's own recursion keeps the mark; a plain call (folded
/// ordinarily or not) prepends the call to the entry and keeps `single`; a
/// recursive fold, or a cell the actual makes carried through a folded or
/// many-times callback label, clears `single`.
pub const Crossing = enum(u8) { own_recursion, plain, recursive, folded_callback, many_callback };

/// The mark `traverseAt` makes in the group's frame.
pub fn enter(container: CellId, cond: CondId) Mark {
    return .{ .container = container, .entry = .none, .single = true, .cond = cond };
}

pub fn cross(cells: *Cell.Table, gpa: Allocator, account: *Ids.Account, m: Mark, inst: u32, how: Crossing) Error!Mark {
    var out = m;
    switch (how) {
        .own_recursion => {},
        .plain => out.entry = try cells.label(gpa, account, inst, m.entry, false),
        .recursive, .folded_callback, .many_callback => {
            out.entry = try cells.label(gpa, account, inst, m.entry, false);
            out.single = false;
        },
    }
    return out;
}

/// The mark of a cell joined from two: `single` only when both are of one
/// traversal (same lineage, entry and condition) and both `single`.
pub fn joinMarks(a: Mark, b: Mark) Mark {
    var out = a;
    out.single = a.single and b.single and a.container == b.container and a.entry == b.entry and a.cond == b.cond;
    return out;
}

/// The words a block writes for a mark, and their reading: a mark naming
/// a cell, label or condition out of range, or a `single` word other than
/// 0 or 1, is unknown — never `single` (§3.6).
pub fn encodeMark(m: Mark) [4]u32 {
    return .{ m.container.int(), m.entry.int(), @intFromBool(m.single), m.cond.int() };
}

pub fn decodeMark(w: [4]u32, cell_count: u32, label_count: u32, cond_count: u32) ?Mark {
    if (w[0] >= cell_count or (w[1] != Ids.none_int and w[1] >= label_count) or w[2] > 1 or w[3] >= cond_count) return null;
    return .{ .container = .from(w[0]), .entry = .from(w[1]), .single = w[2] == 1, .cond = .from(w[3]) };
}

pub const Marks = struct {
    index: Ids.FixedDict(1) = .{},
    items: std.ArrayList(Mark) = .empty,

    pub fn deinit(m: *Marks, gpa: Allocator) void {
        m.index.deinit(gpa);
        m.items.deinit(gpa);
    }

    /// `c`'s mark; a second mark of one cell joins with the first.
    pub fn put(m: *Marks, gpa: Allocator, charge: Charge, c: CellId, mark: Mark) Error!void {
        try charge.reserve(gpa, .other, 1);
        const got = try m.index.getOrPut(gpa, .{c.int()});
        if (got.found_existing) {
            m.items.items[got.value_ptr.*] = joinMarks(m.items.items[got.value_ptr.*], mark);
            return;
        }
        got.value_ptr.* = @intCast(m.items.items.len);
        try m.items.append(gpa, mark);
    }

    pub fn get(m: *const Marks, c: CellId) ?Mark {
        return if (m.index.get(.{c.int()})) |i| m.items.items[i] else null;
    }

    /// `c`'s mark when it certifies one traversal; a cell without a mark is
    /// unknown, never `single`.
    pub fn certified(m: *const Marks, c: CellId) ?Mark {
        const mark = m.get(c) orelse return null;
        return if (mark.single) mark else null;
    }

    /// §2.2's comparison of two distinct taken elements of one container,
    /// for `Cond.sep`: apart under the container's κ only when both marks
    /// are `single`, of that container, and of one entry and condition.
    pub fn traversal(m: *Marks) Cond.Traversal {
        return .{ .ctx = m, .apart = apartTaken };
    }

    fn apartTaken(ctx: *anyopaque, container: CellId, a: CellId, b: CellId) ?CondId {
        const m: *Marks = @ptrCast(@alignCast(ctx));
        const ma = m.certified(a) orelse return null;
        const mb = m.certified(b) orelse return null;
        if (ma.container != container or mb.container != container or ma.entry != mb.entry or ma.cond != mb.cond) return null;
        return ma.cond;
    }
};

// ---- function-value families (§2.11 *Carried-class boundary*) ----------------------

/// One closure alternative of a function value, by its stable identity:
/// code, canonical port and the allocation (its once token), with the cells
/// it captured. Never a table index.
pub const Closure = struct { code: u32, port: u32, token: CellId, captures: SetId };

/// Families of closures as persistent sets of interned alternatives: a join
/// is a union by identity whatever order or size the tables had; every
/// alternative and its captures survive.
pub const Families = struct {
    intern: Ids.FixedDict(3) = .{},
    items: std.ArrayList(Closure) = .empty,
    sets: Cell.Radix = .{},

    pub fn deinit(f: *Families, gpa: Allocator) void {
        f.intern.deinit(gpa);
        f.items.deinit(gpa);
        f.sets.deinit(gpa);
    }

    pub fn closure(f: *Families, gpa: Allocator, charge: Charge, c: Closure) Error!u32 {
        try charge.reserve(gpa, .class, 1);
        const got = try f.intern.getOrPut(gpa, .{ c.code, c.port, c.token.int() });
        if (got.found_existing) return got.value_ptr.*;
        got.value_ptr.* = @intCast(f.items.items.len);
        try f.items.append(gpa, c);
        return got.value_ptr.*;
    }

    /// A family of the given alternatives (a table, in any order).
    pub fn of(f: *Families, gpa: Allocator, charge: Charge, table: []const u32) Error!SetId {
        var s: SetId = .none;
        for (table) |c| s = try f.sets.insert(gpa, charge, s, c, 0);
        return s;
    }

    pub fn join(f: *Families, gpa: Allocator, charge: Charge, a: SetId, b: SetId) Error!SetId {
        return f.sets.unionWith(gpa, charge, a, b);
    }

    /// The once tokens of a family's alternatives, as a cell set in `cells`.
    pub fn tokens(f: *const Families, gpa: Allocator, charge: Charge, cells: *Cell.Radix, family: SetId) Error!SetId {
        var out: SetId = .none;
        var it = f.sets.iterate(family);
        while (it.next()) |e| out = try cells.insert(gpa, charge, out, f.items.items[e.key].token.int(), 0);
        return out;
    }
};

/// Once tokens' use (R-5.4.2) as two persistent token sets: used at least
/// once, used more than once. Mutually exclusive arms join by maximum,
/// sequential uses add; a copy or alias of a closure keeps its token.
pub const Uses = struct {
    once: SetId = .none,
    many: SetId = .none,

    /// One call of a function value whose family holds `tokens`.
    pub fn call(tokens: SetId) Uses {
        return .{ .once = tokens };
    }

    pub fn alt(sets: *Cell.Radix, gpa: Allocator, charge: Charge, a: Uses, b: Uses) Error!Uses {
        return .{ .once = try sets.unionWith(gpa, charge, a.once, b.once), .many = try sets.unionWith(gpa, charge, a.many, b.many) };
    }

    pub fn seq(sets: *Cell.Radix, gpa: Allocator, charge: Charge, a: Uses, b: Uses) Error!Uses {
        const both = try sets.intersection(gpa, charge, a.once, b.once);
        const many = try sets.unionWith(gpa, charge, try sets.unionWith(gpa, charge, a.many, b.many), both);
        return .{ .once = try sets.unionWith(gpa, charge, a.once, b.once), .many = many };
    }

    /// Whether the `once` closure `token` is called at most once.
    pub fn atMostOnce(sets: *const Cell.Radix, u: Uses, token: CellId) bool {
        return !sets.member(u.many, token.int());
    }
};

const testing = std.testing;
const Place = @import("Place.zig");

// The witnesses of §8's S4-verifier row. Each test writes the equations of a
// recursive value or a function value's family by hand (no walker
// inference), over the existing algebra, and asks the verifier.

const TestGraph = struct {
    table: *Place.Table,
    account: *Ids.Account,
    gpa: Allocator,

    fn describe(ctx: *anyopaque, v: u32, out: *std.ArrayList(Place.Child)) Allocator.Error!Place.Description {
        const g: *TestGraph = @ptrCast(@alignCast(ctx));
        switch (v) {
            // 0 `List Int`, 1 `Int`, 2 `List (List Int)`.
            0 => {
                try out.append(g.gpa, .{ .step = Step.elem, .@"var" = 1 });
                return .{ .kind = .list, .head = 200 };
            },
            1 => return .{ .kind = .cross },
            2 => {
                try out.append(g.gpa, .{ .step = Step.elem, .@"var" = 0 });
                return .{ .kind = .list, .head = 200 };
            },
            // 3 `List Int × List (List Int)`: a fold's `( cur, hist )`.
            3 => {
                try out.append(g.gpa, .{ .step = (Step.index(g.account, 0) catch unreachable), .@"var" = 0 });
                try out.append(g.gpa, .{ .step = (Step.index(g.account, 1) catch unreachable), .@"var" = 2 });
                return .{ .kind = .tuple };
            },
            // 4 `List (List (List Int))`.
            4 => {
                try out.append(g.gpa, .{ .step = Step.elem, .@"var" = 2 });
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
    account: Ids.Account = .{},
    graph: TestGraph = undefined,
    prover: Prover = .{},
    marks: Marks = .{},

    const gpa = testing.allocator;

    fn init(f: *Fixture) !void {
        f.graph = .{ .table = &f.places, .account = &f.account, .gpa = gpa };
        f.conds = try Cond.Table.init(gpa, .growth(&f.account));
    }

    fn deinit(f: *Fixture) void {
        f.places.deinit(gpa);
        f.cells.deinit(gpa);
        f.shapes.deinit(gpa);
        f.conds.deinit(gpa);
        f.account.deinit(gpa);
        f.prover.deinit(gpa);
        f.marks.deinit(gpa);
    }

    fn charge(f: *Fixture) Charge {
        return .growth(&f.account);
    }

    fn view(f: *Fixture) Cond.View {
        return .{ .shapes = &f.shapes, .cells = &f.cells, .places = &f.places };
    }

    fn placeOf(f: *Fixture, v: u32) !Ids.PlaceId {
        return f.places.of(gpa, &f.account, .{ .ctx = &f.graph, .describe = TestGraph.describe }, v);
    }

    fn idx(f: *Fixture, i: u32) !Step {
        return Step.index(&f.account, i);
    }

    fn path(f: *Fixture, v: u32, steps: []const Step) !PathId {
        var at = try f.places.rootPath(gpa, try f.placeOf(v));
        for (steps) |s| at = (try f.places.extend(gpa, f.charge(), at, s)).?;
        return at;
    }

    /// `origin i·q` over the type `v`: a parameter, a capture, a top-level value.
    fn sym(f: *Fixture, o: Cell.Origin, i: u32, v: u32, steps: []const Step) !CellId {
        return f.cells.symbolic(gpa, &f.account, &f.places, o, i, try f.path(v, steps), 0);
    }

    /// What the call the label `l` names answered (a `List Int`).
    fn cb(f: *Fixture, l: LabelId) !CellId {
        return f.cells.symbolic(gpa, &f.account, &f.places, .cb, l.int(), try f.path(0, &.{}), 0);
    }

    fn site(f: *Fixture, inst: u32, v: u32) !CellId {
        return f.cells.site(gpa, &f.account, inst, try f.placeOf(v), .list);
    }

    fn label(f: *Fixture, inst: u32, callee: LabelId, folded: bool) !LabelId {
        return f.cells.label(gpa, &f.account, inst, callee, folded);
    }

    fn set(f: *Fixture, cs: []const CellId) !SetId {
        var s: SetId = .none;
        for (cs) |c| s = try f.cells.sets.insert(gpa, f.charge(), s, c.int(), 0);
        return s;
    }

    fn leaf(f: *Fixture, v: u32, cs: []const CellId) !NodeId {
        return f.shapes.leaf(gpa, &f.account, try f.placeOf(v), try f.set(cs));
    }

    /// `( a, b )` at type 3.
    fn pair(f: *Fixture, a: NodeId, b: NodeId) !NodeId {
        const over = try f.shapes.overPut(gpa, &f.account, try f.shapes.overPut(gpa, &f.account, Ids.none_int, try f.idx(0), a), try f.idx(1), b);
        return f.shapes.node(gpa, &f.account, try f.placeOf(3), .none, over);
    }

    /// A list of type `v` whose object is `cs` and whose elements are `elems`.
    fn list(f: *Fixture, v: u32, cs: []const CellId, elems: NodeId) !NodeId {
        return f.shapes.node(gpa, &f.account, try f.placeOf(v), try f.set(cs), try f.shapes.overPut(gpa, &f.account, Ids.none_int, Step.elem, elems));
    }

    /// A taken element of `container` (a `List (List Int)`) at the label `l`.
    fn taken(f: *Fixture, container: CellId, l: LabelId) !CellId {
        return f.cells.refine(gpa, &f.account, .elem, container, l, 0, try f.placeOf(0), .list);
    }

    fn prove(f: *Fixture, w: *World, g: Goal) !Answer {
        return f.prover.prove(gpa, f.charge(), &f.conds, w.equations(), g);
    }
};

/// One alternative of a goal, as the equations write it.
const AltSpec = union(enum) {
    gen: NodeId,
    inv: NodeId,
    apart: [2]SetId,
    within: struct { label: LabelId, cells: SetId },
    require: CondId,
    need: Goal,
};

const Entry = struct { goal: Goal, alts: []const AltSpec, reads: []const u32 = &.{} };

/// The test equations: a goal's settled alternatives by table; `calls` maps
/// a call instruction to the `gen` goal of the family it calls.
const World = struct {
    f: *Fixture,
    entries: []const Entry,
    calls: []const Call = &.{},
    marks: bool = false,

    const Call = struct { inst: u32, goal: Goal };

    fn equations(w: *World) Equations {
        return .{ .ctx = w, .expand = expandIt };
    }

    fn resolver(w: *World) Resolve {
        return .{ .ctx = w, .callee = callee };
    }

    fn callee(ctx: *anyopaque, c: CellId) ?Goal {
        const w: *World = @ptrCast(@alignCast(ctx));
        const inst = w.f.cells.labelInst(.from(w.f.cells.get(c).a));
        for (w.calls) |k| if (k.inst == inst) return k.goal;
        return null;
    }

    fn expandIt(ctx: *anyopaque, ex: *Expansion) Error!void {
        const w: *World = @ptrCast(@alignCast(ctx));
        const f = w.f;
        const e = for (w.entries) |e| {
            if (std.meta.eql(e.goal, ex.goal)) break e;
        } else {
            // A goal the equations do not know: unknown, never empty (O10).
            try ex.begin();
            return ex.refute(.approximate);
        };
        for (e.reads) |r| try ex.read(r);
        const traversal: ?Cond.Traversal = if (w.marks) f.marks.traversal() else null;
        for (e.alts) |a| switch (a) {
            .gen => |n| try ex.gen(f.view(), n, &.{}, w.resolver()),
            .inv => |n| try ex.inv(&f.conds, f.view(), n, w.resolver(), traversal),
            .apart => |ab| try ex.apartCalls(&f.conds, &f.cells, &f.places, ab[0], ab[1], w.resolver(), traversal),
            .within => |lw| try ex.within(&f.conds, &f.cells, &f.places, lw.label, lw.cells, &f.marks, w.resolver()),
            .require => |k| {
                try ex.begin();
                try ex.require(&f.conds, k);
            },
            .need => |g| {
                try ex.begin();
                try ex.need(g);
            },
        };
    }
};

fn gen(port_id: u32) Goal {
    return .{ .claim = .gen, .port = port_id };
}

fn demand(port_id: u32) Goal {
    return .{ .claim = .demand, .port = port_id };
}

fn expectAnswer(a: Answer, status: Status, exactness: Exactness) !void {
    try testing.expectEqual(status, a.status);
    if (status != .proved) try testing.expectEqual(exactness, a.exactness);
}

test "GrowFresh and GrowAlias: an independent base, a step under its assumption; a cycle with no base waits" {
    // grow n = if n == 0 then (λ⊤ → [0]) else (previous = grow (n - 1); λ⊤ → previous ⊤)
    // g = grow n; a = g ⊤; b = g ⊤; ( List.push a 1, b ): the family's
    // answers are its alternatives' (port 0); `previous ⊤` is the call 30.
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const fresh = try f.leaf(0, &.{try f.site(10, 0)});
    const via_previous = try f.leaf(0, &.{try f.cb(try f.label(30, .none, false))});
    // a = g ⊤ (call 40), b = g ⊤ (call 41): two calls of the family.
    const a = try f.set(&.{try f.cb(try f.label(40, .none, false))});
    const b = try f.set(&.{try f.cb(try f.label(41, .none, false))});
    const calls = [_]World.Call{ .{ .inst = 30, .goal = gen(0) }, .{ .inst = 40, .goal = gen(0) }, .{ .inst = 41, .goal = gen(0) } };
    var w: World = .{ .f = &f, .calls = &calls, .entries = &.{
        .{ .goal = gen(0), .alts = &.{ .{ .gen = fresh }, .{ .gen = via_previous } } },
        .{ .goal = demand(0), .alts = &.{.{ .apart = .{ a, b } }} },
    } };
    try expectAnswer(try f.prove(&w, demand(0)), .proved, .exact);
    // The family is one recursive component, one base and one step.
    try testing.expectEqual(@as(u64, 1), f.prover.stats.base - 1); // the demand's own alternative is a base too
    try testing.expectEqual(@as(u64, 1), f.prover.stats.step);

    // GrowAlias: the base answers the capture `xs`, so a and b may be one list.
    var g: Fixture = .{};
    try g.init();
    defer g.deinit();
    const captured = try g.leaf(0, &.{try g.sym(.env, 1, 0, &.{})});
    const prev2 = try g.leaf(0, &.{try g.cb(try g.label(30, .none, false))});
    const a2 = try g.set(&.{try g.cb(try g.label(40, .none, false))});
    const b2 = try g.set(&.{try g.cb(try g.label(41, .none, false))});
    // The green twin copies a at the write: a fresh copy is apart from b.
    const copied = try g.set(&.{try g.site(50, 0)});
    var w2: World = .{ .f = &g, .calls = &calls, .entries = &.{
        .{ .goal = gen(0), .alts = &.{ .{ .gen = captured }, .{ .gen = prev2 } } },
        .{ .goal = demand(0), .alts = &.{.{ .apart = .{ a2, b2 } }} },
        .{ .goal = demand(1), .alts = &.{.{ .apart = .{ copied, b2 } }} },
    } };
    try expectAnswer(try g.prove(&w2, gen(0)), .refuted, .exact);
    try expectAnswer(try g.prove(&w2, demand(0)), .refuted, .approximate);
    try expectAnswer(try g.prove(&w2, demand(1)), .proved, .exact);

    // No base at all (`grow n = λ⊤ → (grow n) ⊤`): the cycle only assumes
    // itself — waiting, never proved.
    var h: Fixture = .{};
    try h.init();
    defer h.deinit();
    const only_previous = try h.leaf(0, &.{try h.cb(try h.label(30, .none, false))});
    var w3: World = .{ .f = &h, .calls = &calls, .entries = &.{.{ .goal = gen(0), .alts = &.{.{ .gen = only_previous }} }} };
    try expectAnswer(try h.prove(&w3, gen(0)), .waiting, .approximate);
}

test "FoldCallbackIdentity: two fresh invocations are apart; one answer twice, a capture, a re-returned feedback are not; a cycle assuming itself waits" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    // `pair f = ( f ⊤, f ⊤ )`: the calls 10 and 11 of the actual's family.
    const c10 = try f.set(&.{try f.cb(try f.label(10, .none, false))});
    const c11 = try f.set(&.{try f.cb(try f.label(11, .none, false))});
    const c20 = try f.set(&.{try f.cb(try f.label(20, .none, false))});
    const c21 = try f.set(&.{try f.cb(try f.label(21, .none, false))});
    const c30 = try f.set(&.{try f.cb(try f.label(30, .none, false))});
    const c31 = try f.set(&.{try f.cb(try f.label(31, .none, false))});
    const calls = [_]World.Call{
        .{ .inst = 10, .goal = gen(1) }, .{ .inst = 11, .goal = gen(1) },
        .{ .inst = 20, .goal = gen(2) }, .{ .inst = 21, .goal = gen(2) },
        .{ .inst = 30, .goal = gen(3) }, .{ .inst = 31, .goal = gen(3) },
        .{ .inst = 40, .goal = gen(4) }, .{ .inst = 50, .goal = gen(5) },
    };
    var w: World = .{
        .f = &f,
        .calls = &calls,
        .entries = &.{
            // 1: `λ⊤ → [ 1 ]`, fresh per invocation.
            .{ .goal = gen(1), .alts = &.{.{ .gen = try f.leaf(0, &.{try f.site(60, 0)}) }} },
            // 2: `λ⊤ → c`, a capture: every invocation answers one object.
            .{ .goal = gen(2), .alts = &.{.{ .gen = try f.leaf(0, &.{try f.sym(.env, 7, 0, &.{})}) }} },
            // 3: a fold's `λx acc → if c then [] else acc`: the feedback comes back.
            .{ .goal = gen(3), .alts = &.{ .{ .gen = try f.leaf(0, &.{try f.site(61, 0)}) }, .{ .gen = try f.leaf(0, &.{try f.sym(.param, 2, 0, &.{})}) } } },
            // 4: `f ⊤ = f ⊤`: a proof cycle that only assumes itself.
            .{ .goal = gen(4), .alts = &.{.{ .gen = try f.leaf(0, &.{try f.cb(try f.label(40, .none, false))}) }} },
            // 5: the same cycle with a base, `f ⊤ = if c then [ 1 ] else f ⊤`.
            .{ .goal = gen(5), .alts = &.{ .{ .gen = try f.leaf(0, &.{try f.cb(try f.label(50, .none, false))}) }, .{ .gen = try f.leaf(0, &.{try f.site(62, 0)}) } } },
            .{ .goal = demand(1), .alts = &.{.{ .apart = .{ c10, c11 } }} },
            // `k f = (a = f ⊤; ( a, a ))`: one invocation's answer twice, even when fresh.
            .{ .goal = demand(2), .alts = &.{.{ .apart = .{ c10, c10 } }} },
            .{ .goal = demand(3), .alts = &.{.{ .apart = .{ c20, c21 } }} },
            .{ .goal = demand(4), .alts = &.{.{ .apart = .{ c30, c31 } }} },
        },
    };
    try expectAnswer(try f.prove(&w, demand(1)), .proved, .exact);
    try expectAnswer(try f.prove(&w, demand(2)), .refuted, .exact);
    try expectAnswer(try f.prove(&w, gen(2)), .refuted, .exact);
    try expectAnswer(try f.prove(&w, demand(3)), .refuted, .approximate);
    // A re-returned feedback value was allocated by an earlier invocation:
    // the [] base does not excuse the other alternative.
    try expectAnswer(try f.prove(&w, gen(3)), .refuted, .approximate);
    try expectAnswer(try f.prove(&w, demand(4)), .refuted, .approximate);
    try expectAnswer(try f.prove(&w, gen(4)), .waiting, .approximate);
    try expectAnswer(try f.prove(&w, gen(5)), .proved, .exact);

    // A re-entrant callback: the call 70 and a call inside it, (70·71) — a
    // callback that calls back into its caller, which calls it again. Both
    // invocations answer objects they allocated (gen holds), yet the outer
    // may answer the inner's object: no separation, and no `within` from
    // such a pair.
    const outer = try f.label(70, .none, false);
    const inner = try f.label(70, try f.label(71, .none, false), false);
    try testing.expect(!diverge(&f.cells, outer, inner));
    try testing.expect(diverge(&f.cells, try f.label(72, .none, false), inner));
    const calls2 = [_]World.Call{ .{ .inst = 70, .goal = gen(1) }, .{ .inst = 72, .goal = gen(1) } };
    var w2: World = .{ .f = &f, .calls = &calls2, .entries = &.{
        .{ .goal = gen(1), .alts = &.{.{ .gen = try f.leaf(0, &.{try f.site(60, 0)}) }} },
        .{ .goal = demand(5), .alts = &.{.{ .apart = .{ try f.set(&.{try f.cb(outer)}), try f.set(&.{try f.cb(inner)}) } }} },
        .{ .goal = demand(6), .alts = &.{.{ .apart = .{ try f.set(&.{try f.cb(try f.label(72, .none, false))}), try f.set(&.{try f.cb(inner)}) } }} },
    } };
    try expectAnswer(try f.prove(&w2, demand(5)), .refuted, .approximate);
    try expectAnswer(try f.prove(&w2, demand(6)), .proved, .exact);
    const gpa = testing.allocator;
    try testing.expectEqual(Cond.lost, try f.prover.foldPair(gpa, f.charge(), &f.conds, &f.cells, outer, inner, try f.label(70, .none, true)));
}

test "within keeps its pre-fold provenance: a distinct pair folds to within, a self pair stays lost, an atom without provenance is refused" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    // mapHelp's round 4 (C.2): sep((ι_rec·ι_f⋆), (ι_rec·ι_rec⋆)) folds into ι_rec⋆.
    const f_star = try f.label(10, .none, true);
    const rec_star = try f.label(11, .none, true);
    const rec_f = try f.label(11, f_star, false);
    const rec_rec = try f.label(11, rec_star, false);
    const w_rec = try f.prover.foldPair(gpa, f.charge(), &f.conds, &f.cells, rec_f, rec_rec, rec_star);
    try testing.expectEqual(try f.conds.within(gpa, f.charge(), rec_star), w_rec);
    const recorded = f.prover.provenanceOf(rec_star).?;
    try testing.expect((recorded[0] == rec_f and recorded[1] == rec_rec) or (recorded[0] == rec_rec and recorded[1] == rec_f));
    // A self pair a fold met (foldlFrom's `sep(π₁, π₂[*])` instantiated with one
    // folded supply on both sides, Appendix C.6): lost, and no within.
    const l_star = try f.label(20, .none, true);
    try testing.expectEqual(Cond.lost, try f.prover.foldPair(gpa, f.charge(), &f.conds, &f.cells, l_star, l_star, l_star));
    try testing.expectEqual(@as(?[2]LabelId, null), f.prover.provenanceOf(l_star));
    // At a consumer: fresh results per call pass under provenance; the same
    // fresh results under an atom without provenance (an imported self
    // atom) do not; one capture at every call is one object.
    const fresh = try f.set(&.{try f.cells.result(gpa, &f.account, .result, rec_star, 1, try f.placeOf(0), .list)});
    const capture = try f.set(&.{try f.sym(.env, 3, 0, &.{})});
    var w: World = .{ .f = &f, .entries = &.{
        .{ .goal = demand(0), .alts = &.{.{ .within = .{ .label = rec_star, .cells = fresh } }} },
        .{ .goal = demand(1), .alts = &.{.{ .within = .{ .label = l_star, .cells = fresh } }} },
        .{ .goal = demand(2), .alts = &.{.{ .within = .{ .label = rec_star, .cells = capture } }} },
    } };
    try expectAnswer(try f.prove(&w, demand(0)), .proved, .exact);
    try expectAnswer(try f.prove(&w, demand(1)), .refuted, .approximate);
    try expectAnswer(try f.prove(&w, demand(2)), .refuted, .exact);
}

test "C.6's accumulator held once, RefinementFeedbackTwice's storage write: base and step apart; a second store refused exactly, a capture refused; no base waits" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    // `List.foldl xs ( [], [] ) λx ( cur, hist ) → if x == 0 then ( cur,
    // List.push hist cur ) else ( List.push cur x, hist )`: the step receives
    // the accumulator as π₂ (type 3). The invariant: `.0` owned and apart
    // from every list in `.1`.
    const s0 = try f.idx(0);
    const s1 = try f.idx(1);
    const cur = try f.sym(.param, 2, 3, &.{s0});
    const hist = try f.sym(.param, 2, 3, &.{s1});
    const hist_e = try f.sym(.param, 2, 3, &.{ s1, Step.elem });
    const stated = try f.conds.sepAtom(gpa, f.charge(), cur, hist_e);
    const spec = try f.prover.invariant(gpa, f.charge(), .{ .incoming = 2, .owned = &.{try f.path(3, &.{s0})}, .pairs = stated });
    const g: Goal = .{ .claim = .inv, .port = 0, .arg = spec };
    const base = try f.pair(try f.leaf(0, &.{try f.site(1, 0)}), try f.leaf(2, &.{try f.site(2, 2)}));
    const keeps = try f.pair(try f.leaf(0, &.{cur}), try f.leaf(2, &.{hist}));
    const stores_twice = try f.pair(try f.leaf(0, &.{cur}), try f.list(2, &.{hist}, try f.leaf(0, &.{ hist_e, cur })));
    // Port 1: the same fold with both arms. The arm storing `cur` at `.0` and
    // at `.1[*]` breaks "held once": the preservation check fails exactly,
    // though the base passes and the caller's initial `( [], [] )` passes its
    // own Disjoint (C.10 item 4).
    const g_both: Goal = .{ .claim = .inv, .port = 1, .arg = spec };
    var w: World = .{ .f = &f, .entries = &.{
        .{ .goal = g, .alts = &.{ .{ .inv = base }, .{ .inv = keeps } } },
        .{ .goal = g_both, .alts = &.{ .{ .inv = base }, .{ .inv = stores_twice }, .{ .inv = keeps } } },
    } };
    try expectAnswer(try f.prove(&w, g), .proved, .exact);
    try expectAnswer(try f.prove(&w, g_both), .refuted, .exact);

    // RefinementFeedbackTwice's positive control: `List.foldl xs [] λx acc →
    // List.push acc x` writes its accumulator in place: owned at ε, base `[]`,
    // the step returns the incoming object. A capture returned instead
    // (`if x == 0 then saved else …`) is one object at every call.
    var h: Fixture = .{};
    try h.init();
    defer h.deinit();
    const acc = try h.sym(.param, 2, 0, &.{});
    const x = try h.sym(.param, 1, 1, &.{});
    _ = x;
    const spec3 = try h.prover.invariant(gpa, h.charge(), .{ .incoming = 2, .owned = &.{try h.path(0, &.{})}, .pairs = Cond.yes });
    const g3: Goal = .{ .claim = .inv, .port = 0, .arg = spec3 };
    const empty = try h.leaf(0, &.{try h.site(5, 0)});
    const pushed = try h.leaf(0, &.{acc});
    const saved = try h.leaf(0, &.{try h.sym(.env, 9, 0, &.{})});
    var w3: World = .{
        .f = &h,
        .entries = &.{
            .{ .goal = g3, .alts = &.{ .{ .inv = empty }, .{ .inv = pushed } } },
            .{ .goal = .{ .claim = .inv, .port = 1, .arg = spec3 }, .alts = &.{ .{ .inv = empty }, .{ .inv = pushed }, .{ .inv = saved } } },
            // The step alone, its base missing: the cycle assumes itself.
            .{ .goal = .{ .claim = .inv, .port = 2, .arg = spec3 }, .alts = &.{.{ .inv = pushed }} },
        },
    };
    try expectAnswer(try h.prove(&w3, g3), .proved, .exact);
    try expectAnswer(try h.prove(&w3, .{ .claim = .inv, .port = 1, .arg = spec3 }), .refuted, .exact);
    try expectAnswer(try h.prove(&w3, .{ .claim = .inv, .port = 2, .arg = spec3 }), .waiting, .approximate);
}

test "FeedbackPrevTwice: the step's duplicate is refused exactly, and after refinement folding the element condition stays lost" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    // `st = Tuple.second (List.foldl xs ( [], [] ) λx ( prev, st ) → ( x,
    // List.push (List.push st prev) x ))`, `x` the lambda's π₁ (a `List Int`).
    const s0 = try f.idx(0);
    const s1 = try f.idx(1);
    const prev = try f.sym(.param, 2, 3, &.{s0});
    const st = try f.sym(.param, 2, 3, &.{s1});
    const st_e = try f.sym(.param, 2, 3, &.{ s1, Step.elem });
    const x = try f.sym(.param, 1, 0, &.{});
    // The invariant a proof of the twin would need: `prev` apart from `st`'s lists.
    const spec = try f.prover.invariant(gpa, f.charge(), .{ .incoming = 2, .owned = &.{}, .pairs = try f.conds.sepAtom(gpa, f.charge(), prev, st_e) });
    const g: Goal = .{ .claim = .inv, .port = 0, .arg = spec };
    const base = try f.pair(try f.leaf(0, &.{try f.site(1, 0)}), try f.leaf(2, &.{try f.site(2, 2)}));
    const step = try f.pair(try f.leaf(0, &.{x}), try f.list(2, &.{st}, try f.leaf(0, &.{ st_e, prev, x })));
    var w: World = .{ .f = &f, .entries = &.{.{ .goal = g, .alts = &.{ .{ .inv = base }, .{ .inv = step } } }} };
    // `x` is the next round's `prev` and is pushed this round: one list twice.
    try expectAnswer(try f.prove(&w, g), .refuted, .exact);
    // The safe twin, `( x, List.push st prev )`, stores each list once. Its
    // proof needs "the current supply is apart from every earlier list",
    // Appendix C.9 gap 3's narrowed rule: an atom over the incoming value
    // the invariant does not state. The verifier does not assume it, so the
    // twin is refused approximately — a limit of the checker, kept until a
    // separately reviewed proof replaces the decided `lost`.
    const once = try f.pair(try f.leaf(0, &.{x}), try f.list(2, &.{st}, try f.leaf(0, &.{ st_e, prev })));
    const g_once: Goal = .{ .claim = .inv, .port = 1, .arg = spec };
    var w_once: World = .{ .f = &f, .entries = &.{.{ .goal = g_once, .alts = &.{ .{ .inv = base }, .{ .inv = once } } }} };
    try expectAnswer(try f.prove(&w_once, g_once), .refuted, .approximate);

    // At the fold's caller every supply is one folded split, `elem(xs·ι_l⋆)`
    // (the split chains fold with the labels, `elem(xs·(ι_rec·(ι_rec·ι_t)))`
    // is `elem(xs·ι_rec⋆)`): two cells that came back through the feedback
    // are that cell twice. Even a single certified mark does not separate it
    // (Appendix C.9 gap 3: the decided rule keeps `lost`).
    const xs = try f.sym(.param, 1, 2, &.{});
    const k = try f.conds.excl(gpa, f.charge(), xs);
    const l_star = try f.label(100, try f.label(101, .none, true), true);
    const e = try f.taken(xs, l_star);
    try f.marks.put(gpa, f.charge(), e, try cross(&f.cells, gpa, &f.account, try cross(&f.cells, gpa, &f.account, enter(xs, k), 101, .plain), 100, .plain));
    try testing.expectEqual(Cond.lost, try f.conds.sep(gpa, f.charge(), &f.cells, &f.places, e, e, false, f.marks.traversal()));
    var items = [_]Cond.Item{ .{ .cell = e, .approx = false }, .{ .cell = e, .approx = false } };
    try testing.expectEqual(Cond.lost, try f.conds.apart(gpa, f.charge(), &f.cells, &f.places, &items, f.marks.traversal()));
    // And no `within` is invented from that self pair.
    try testing.expectEqual(Cond.lost, try f.prover.foldPair(gpa, f.charge(), &f.conds, &f.cells, l_star, l_star, l_star));
}

test "TwoTraversalsShared and FoldOverFoldShared: two entries are two traversals; one traversal's splits are apart under κ(xs[*])" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const xs = try f.sym(.param, 1, 2, &.{});
    const k = try f.conds.excl(gpa, f.charge(), xs);
    const acct = &f.account;
    // `ys = List.push (List.map xs λl → l) (List.foldl xs [] λx _ → x)`: the
    // map's split leaves mapHelp through ι_m (101) and List.map through ι₁
    // (100); the fold's through ι_l (201) and ι₂ (200).
    const by_map = try f.taken(xs, try f.label(100, try f.label(101, .none, true), true));
    const by_fold = try f.taken(xs, try f.label(200, try f.label(201, .none, true), true));
    try f.marks.put(gpa, f.charge(), by_map, try cross(&f.cells, gpa, acct, try cross(&f.cells, gpa, acct, enter(xs, k), 101, .plain), 100, .plain));
    try f.marks.put(gpa, f.charge(), by_fold, try cross(&f.cells, gpa, acct, try cross(&f.cells, gpa, acct, enter(xs, k), 201, .plain), 200, .plain));
    var ys = [_]Cond.Item{ .{ .cell = by_map, .approx = false }, .{ .cell = by_fold, .approx = false } };
    const k_ys = try f.conds.apart(gpa, f.charge(), &f.cells, &f.places, &ys, f.marks.traversal());
    try testing.expectEqual(Cond.lost, k_ys);
    // `List.map ys λl → List.push l 1` relies on κ(ys[*]): refused, approximate.
    // Green: `List.map xs λl → List.push l 1` relies on κ(xs[*]) through its
    // `within(ι_m⋆)`, whose cells are the map's own taken supply.
    const rec_f = try f.label(11, try f.label(10, .none, true), false);
    const rec_rec = try f.label(11, try f.label(11, .none, true), false);
    const m_star = try f.label(100, try f.label(101, .none, true), true);
    _ = try f.prover.foldPair(gpa, f.charge(), &f.conds, &f.cells, rec_f, rec_rec, m_star);
    var w: World = .{ .f = &f, .marks = true, .entries = &.{
        .{ .goal = demand(0), .alts = &.{.{ .require = k_ys }} },
        .{ .goal = demand(1), .alts = &.{.{ .within = .{ .label = m_star, .cells = try f.set(&.{by_map}) } }} },
    } };
    try expectAnswer(try f.prove(&w, demand(0)), .refuted, .approximate);
    const green = try f.prove(&w, demand(1));
    try expectAnswer(green, .proved, .exact);
    try testing.expectEqual(k, green.xreq);

    // mapHelp's own two splits (C.11's first row): one traversal, empty
    // entry, its own recursion keeping the mark — apart under κ(xs[*]).
    const here = try f.taken(xs, try f.label(12, .none, false));
    const deeper = try f.taken(xs, try f.label(11, .none, true));
    try f.marks.put(gpa, f.charge(), here, enter(xs, k));
    try f.marks.put(gpa, f.charge(), deeper, try cross(&f.cells, gpa, acct, enter(xs, k), 11, .own_recursion));
    try testing.expectEqual(k, try f.conds.sep(gpa, f.charge(), &f.cells, &f.places, here, deeper, false, f.marks.traversal()));
    // Without a traversal answer the same pair is lost.
    try testing.expectEqual(Cond.lost, try f.conds.sep(gpa, f.charge(), &f.cells, &f.places, here, deeper, false, null));

    // FoldOverFoldShared: `List.foldl xs (List.foldr xs [] push) push`. The
    // initial accumulator's lists come from foldr's traversal (ι_r 300, 301),
    // each outer step stores foldl's (ι_l 400, 401): two entries, `lost`, and
    // each fold's own element condition is the folded self pair, `lost` too.
    const by_foldr = try f.taken(xs, try f.label(300, try f.label(301, .none, true), true));
    const by_foldl = try f.taken(xs, try f.label(400, try f.label(401, .none, true), true));
    try f.marks.put(gpa, f.charge(), by_foldr, try cross(&f.cells, gpa, acct, try cross(&f.cells, gpa, acct, enter(xs, k), 301, .plain), 300, .plain));
    try f.marks.put(gpa, f.charge(), by_foldl, try cross(&f.cells, gpa, acct, try cross(&f.cells, gpa, acct, enter(xs, k), 401, .plain), 400, .plain));
    try testing.expectEqual(Cond.lost, try f.conds.sep(gpa, f.charge(), &f.cells, &f.places, by_foldl, by_foldr, false, f.marks.traversal()));
    try testing.expectEqual(Cond.lost, try f.conds.sep(gpa, f.charge(), &f.cells, &f.places, by_foldl, by_foldl, false, f.marks.traversal()));
    // Both folds' storage writes stay accepted: owned accumulator at ε.
    const acc = try f.sym(.param, 2, 2, &.{});
    const spec = try f.prover.invariant(gpa, f.charge(), .{ .incoming = 2, .owned = &.{try f.path(2, &.{})}, .pairs = Cond.yes });
    const inner: Goal = .{ .claim = .inv, .port = 10, .arg = spec };
    const outer: Goal = .{ .claim = .inv, .port = 11, .arg = spec };
    const foldr_result = try f.set(&.{try f.cells.result(gpa, acct, .result, try f.label(300, .none, false), 1, try f.placeOf(2), .list)});
    _ = foldr_result;
    var w2: World = .{
        .f = &f,
        .entries = &.{
            .{ .goal = inner, .alts = &.{ .{ .inv = try f.leaf(2, &.{try f.site(7, 2)}) }, .{ .inv = try f.leaf(2, &.{acc}) } } },
            // The outer fold's initial accumulator is the inner fold's answer, a
            // `result` of the call ι_r: fresh to the outer fold.
            .{ .goal = outer, .alts = &.{ .{ .inv = try f.leaf(2, &.{try f.cells.result(gpa, acct, .result, try f.label(300, .none, false), 1, try f.placeOf(2), .list)}) }, .{ .inv = try f.leaf(2, &.{acc}) } } },
        },
    };
    try expectAnswer(try f.prove(&w2, inner), .proved, .exact);
    try expectAnswer(try f.prove(&w2, outer), .proved, .exact);
}

test "NestedTraversalShared, and across a block: single is cleared through a folded callback label; a corrupt mark is unknown" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const acct = &f.account;
    const xs = try f.sym(.param, 2, 2, &.{});
    const k = try f.conds.excl(gpa, f.charge(), xs);
    // `each ws xs f = List.map ws (λ_ → List.map xs f)`: the inner map's split
    // leaves mapHelp (ι_m 101), List.map (the lambda's call 500), then the
    // lambda through the outer map's folded callback label (600).
    const in_lambda = try cross(&f.cells, gpa, acct, try cross(&f.cells, gpa, acct, enter(xs, k), 101, .plain), 500, .plain);
    try testing.expect(in_lambda.single);
    const out_of_each = try cross(&f.cells, gpa, acct, in_lambda, 600, .folded_callback);
    try testing.expect(!out_of_each.single);
    const inner_l = try f.label(600, try f.label(500, try f.label(101, .none, true), true), true);
    const nested = try f.taken(xs, inner_l);
    try f.marks.put(gpa, f.charge(), nested, out_of_each);
    // The caller's `List.map inner (λl → List.push l 1)` relies on the inner
    // lists' within: refused. Green: `each [ 1, 2 ] xs (λ_ → [ 1 ])` answers a
    // fresh result per call.
    const w_l = try f.label(700, .none, true);
    _ = try f.prover.foldPair(gpa, f.charge(), &f.conds, &f.cells, try f.label(701, .none, false), try f.label(702, .none, false), w_l);
    const fresh = try f.set(&.{try f.cells.result(gpa, acct, .result, inner_l, 1, try f.placeOf(0), .list)});
    // The direct `List.map xs λl → List.push l 1` keeps single.
    const direct = try f.taken(xs, try f.label(800, try f.label(101, .none, true), true));
    const direct_mark = try cross(&f.cells, gpa, acct, try cross(&f.cells, gpa, acct, enter(xs, k), 101, .plain), 800, .plain);
    try f.marks.put(gpa, f.charge(), direct, direct_mark);
    var w: World = .{ .f = &f, .entries = &.{
        .{ .goal = demand(0), .alts = &.{.{ .within = .{ .label = w_l, .cells = try f.set(&.{nested}) } }} },
        .{ .goal = demand(1), .alts = &.{.{ .within = .{ .label = w_l, .cells = fresh } }} },
        .{ .goal = demand(2), .alts = &.{.{ .within = .{ .label = w_l, .cells = try f.set(&.{direct}) } }} },
    } };
    try expectAnswer(try f.prove(&w, demand(0)), .refuted, .approximate);
    try expectAnswer(try f.prove(&w, demand(1)), .proved, .exact);
    try expectAnswer(try f.prove(&w, demand(2)), .proved, .exact);

    // NestedTraversalAcrossModules: the marks cross a block as words. Read
    // back, the same verdicts; a corrupt word reads as no mark, never single.
    const counts = .{ f.cells.count(), @as(u32, @intCast(f.cells.labels.len)), f.conds.count() };
    const read_nested = decodeMark(encodeMark(out_of_each), counts[0], counts[1], counts[2]).?;
    try testing.expectEqual(out_of_each, read_nested);
    try testing.expectEqual(direct_mark, decodeMark(encodeMark(direct_mark), counts[0], counts[1], counts[2]).?);
    var bad = encodeMark(direct_mark);
    bad[2] = 2;
    try testing.expectEqual(@as(?Mark, null), decodeMark(bad, counts[0], counts[1], counts[2]));
    bad = encodeMark(direct_mark);
    bad[0] = counts[0];
    try testing.expectEqual(@as(?Mark, null), decodeMark(bad, counts[0], counts[1], counts[2]));
    // An importer whose block lost the direct mark: unknown, refused.
    var g: Fixture = .{};
    try g.init();
    defer g.deinit();
    const xs2 = try g.sym(.param, 2, 2, &.{});
    const direct2 = try g.taken(xs2, try g.label(800, try g.label(101, .none, true), true));
    const w2_l = try g.label(700, .none, true);
    _ = try g.prover.foldPair(gpa, g.charge(), &g.conds, &g.cells, try g.label(701, .none, false), try g.label(702, .none, false), w2_l);
    var w2: World = .{ .f = &g, .entries = &.{.{ .goal = demand(2), .alts = &.{.{ .within = .{ .label = w2_l, .cells = try g.set(&.{direct2}) } }} }} };
    try expectAnswer(try g.prove(&w2, demand(2)), .refuted, .approximate);
}

/// RecursiveClassGrowth's three closures `a`, `b`, `c` (ports 0, 1, 2), each
/// calling the next; `c`'s other alternative is `last`. `bad ⊤ = List.push
/// ((a 1) ⊤) 2` is demand 0. `order` permutes the table and alternatives.
fn classGrowth(f: *Fixture, last: ?NodeId, reversed: bool, entries: *[4]Entry, alts: *[6]AltSpec) ![]const Entry {
    alts[0] = .{ .gen = try f.leaf(0, &.{try f.cb(try f.label(1, .none, false))}) };
    alts[1] = .{ .gen = try f.leaf(0, &.{try f.cb(try f.label(2, .none, false))}) };
    // c's alternatives in both orders: [2, 3] and [3, 4].
    alts[2] = .{ .gen = try f.leaf(0, &.{try f.cb(try f.label(3, .none, false))}) };
    alts[3] = if (last) |n| .{ .gen = n } else alts[2];
    alts[4] = alts[2];
    alts[5] = .{ .gen = try f.leaf(0, &.{try f.cb(try f.label(9, .none, false))}) };
    const c_alts: []const AltSpec = if (last == null) alts[2..3] else if (reversed) alts[3..5] else alts[2..4];
    entries.* = .{
        .{ .goal = gen(0), .alts = alts[0..1] },
        .{ .goal = gen(1), .alts = alts[1..2] },
        .{ .goal = gen(2), .alts = c_alts },
        .{ .goal = demand(0), .alts = alts[5..6] },
    };
    if (reversed) std.mem.reverse(Entry, entries);
    return entries;
}

const growth_calls = [_]World.Call{ .{ .inst = 1, .goal = gen(1) }, .{ .inst = 2, .goal = gen(2) }, .{ .inst = 3, .goal = gen(0) }, .{ .inst = 9, .goal = gen(0) } };

test "RecursiveClassGrowth: a, b and c settle together, the shared base refuses; a fresh base accepts; no base waits; order never changes an answer" {
    const Case = struct { last: enum { shared, fresh, none }, want: Status, exact: Exactness };
    for ([_]Case{ .{ .last = .shared, .want = .refuted, .exact = .exact }, .{ .last = .fresh, .want = .proved, .exact = .exact }, .{ .last = .none, .want = .waiting, .exact = .approximate } }) |case| {
        for ([_]bool{ false, true }) |reversed| for ([_]u32{ 0, 2 }) |root| {
            var f: Fixture = .{};
            try f.init();
            defer f.deinit();
            const last: ?NodeId = switch (case.last) {
                .shared => try f.leaf(0, &.{try f.sym(.shared, 4, 0, &.{})}),
                .fresh => try f.leaf(0, &.{try f.site(5, 0)}),
                .none => null,
            };
            var entries: [4]Entry = undefined;
            var alts: [6]AltSpec = undefined;
            var w: World = .{ .f = &f, .calls = &growth_calls, .entries = try classGrowth(&f, last, reversed, &entries, &alts) };
            // Ask from another member first: the component is one answer.
            _ = try f.prove(&w, gen(root));
            for ([_]u32{ 0, 1, 2 }) |m| try expectAnswer((try f.prover.cached(testing.allocator, f.charge(), gen(m))).?, case.want, case.exact);
            const bad = try f.prove(&w, demand(0));
            try testing.expectEqual(if (case.want == .proved) Status.proved else if (case.want == .refuted) Status.refuted else Status.waiting, bad.status);
            // One component of three, decided once: three expansions, no more.
            try testing.expectEqual(@as(u64, 4), f.prover.stats.expanded);
        };
    }
}

test "JoinedClosurePorts: tables join by identity, never by index, and every alternative's capture is checked; once tokens by alias, arm and sequence" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var fam: Families = .{};
    defer fam.deinit(gpa);
    const c_a = try f.sym(.env, 1, 0, &.{});
    const c_b = try f.sym(.env, 2, 0, &.{});
    const top_level = try f.sym(.shared, 3, 0, &.{});
    const t_a = try f.site(10, 0);
    const t_b = try f.site(11, 0);
    const t_b2 = try f.site(12, 0);
    const a = try fam.closure(gpa, f.charge(), .{ .code = 1, .port = 0, .token = t_a, .captures = try f.set(&.{c_a}) });
    const b = try fam.closure(gpa, f.charge(), .{ .code = 2, .port = 0, .token = t_b, .captures = try f.set(&.{c_b}) });
    // Another allocation of code 2 capturing a top-level value.
    const b2 = try fam.closure(gpa, f.charge(), .{ .code = 2, .port = 0, .token = t_b2, .captures = try f.set(&.{top_level}) });
    // Equal-length tables in different orders, and an unequal one.
    const t1 = try fam.of(gpa, f.charge(), &.{ a, b });
    const t2 = try fam.of(gpa, f.charge(), &.{ b2, a });
    const t3 = try fam.of(gpa, f.charge(), &.{b});
    const joined = try fam.join(gpa, f.charge(), t1, t2);
    try testing.expectEqual(joined, try fam.join(gpa, f.charge(), t2, t1));
    try testing.expectEqual(@as(u32, 3), fam.sets.count(joined));
    try testing.expectEqual(t1, try fam.join(gpa, f.charge(), t1, t3));
    try testing.expectEqual(t1, try fam.of(gpa, f.charge(), &.{ b, a }));
    // `if c then t1 else t2`, then call the writer of its capture from one
    // arm: every alternative's capture is written. The shared twin refuses;
    // without b2 it accepts.
    const Writer = struct {
        fn alts(ff: *Fixture, families: *const Families, family: SetId, out: []AltSpec) []const AltSpec {
            var n: usize = 0;
            var it = families.sets.iterate(family);
            while (it.next()) |e| {
                var ct = ff.cells.sets.iterate(families.items.items[e.key].captures);
                while (ct.next()) |c| {
                    // A top-level value is never owned (O8); a capture's own
                    // holders are the write's demand.
                    out[n] = .{ .require = if (ff.cells.origin(.from(c.key)) == .shared) Cond.shared else Cond.yes };
                    n += 1;
                }
            }
            return out[0..n];
        }
    };
    var buf1: [4]AltSpec = undefined;
    var buf2: [4]AltSpec = undefined;
    var w: World = .{ .f = &f, .entries = &.{
        .{ .goal = demand(0), .alts = Writer.alts(&f, &fam, joined, &buf1) },
        .{ .goal = demand(1), .alts = Writer.alts(&f, &fam, try fam.join(gpa, f.charge(), t1, t3), &buf2) },
    } };
    try expectAnswer(try f.prove(&w, demand(0)), .refuted, .exact);
    try expectAnswer(try f.prove(&w, demand(1)), .proved, .exact);

    // Once tokens: the joined value called in two exclusive arms uses each
    // token once; called twice in sequence, each twice; a copy keeps the
    // token; two different closures in sequence are once each.
    const radix = &f.cells.sets;
    const tokens = try fam.tokens(gpa, f.charge(), radix, t1);
    const arms = try Uses.alt(radix, gpa, f.charge(), Uses.call(tokens), Uses.call(tokens));
    try testing.expect(Uses.atMostOnce(radix, arms, t_a) and Uses.atMostOnce(radix, arms, t_b));
    const twice = try Uses.seq(radix, gpa, f.charge(), Uses.call(tokens), Uses.call(tokens));
    try testing.expect(!Uses.atMostOnce(radix, twice, t_a) and !Uses.atMostOnce(radix, twice, t_b));
    const only_a = try fam.tokens(gpa, f.charge(), radix, try fam.of(gpa, f.charge(), &.{a}));
    const alias = try Uses.seq(radix, gpa, f.charge(), Uses.call(only_a), Uses.call(only_a));
    try testing.expect(!Uses.atMostOnce(radix, alias, t_a));
    const only_b = try fam.tokens(gpa, f.charge(), radix, t3);
    const two = try Uses.seq(radix, gpa, f.charge(), Uses.call(only_a), Uses.call(only_b));
    try testing.expect(Uses.atMostOnce(radix, two, t_a) and Uses.atMostOnce(radix, two, t_b));
    // An arm that calls twice, joined with an arm that does not: still twice.
    const mixed = try Uses.alt(radix, gpa, f.charge(), twice, .{});
    try testing.expect(!Uses.atMostOnce(radix, mixed, t_a));
}

/// CallFeedbackGeneration's state: which supplies answer a capture.
const Helpers = struct {
    f: *Fixture,
    world: World,
    fresh: NodeId,
    captured: NodeId,
    /// Supply `s`'s actual answers a capture (bumping port `s`).
    capture: [2]bool = .{ false, false },
    entries: [6]Entry = undefined,
    alts: [8]AltSpec = undefined,

    // `helper f n = if n == 0 then (λ⊤ → f ⊤) else (prev = helper f (n − 1);
    // λ⊤ → prev ⊤)`, two instances over the supplies 0 and 1 (ports 0, 1):
    // gen(10 + s) the helper's family, gen(20 + s) the supply's actual,
    // demand s a caller's `a = g ⊤; b = g ⊤` probe.
    fn refresh(h: *Helpers) !void {
        const f = h.f;
        for (0..2) |s| {
            const si: u32 = @intCast(s);
            h.alts[4 * s + 0] = .{ .gen = try f.leaf(0, &.{try f.cb(try f.label(100 + si, .none, false))}) };
            h.alts[4 * s + 1] = .{ .gen = try f.leaf(0, &.{try f.cb(try f.label(110 + si, .none, false))}) };
            h.alts[4 * s + 2] = .{ .gen = if (h.capture[s]) h.captured else h.fresh };
            h.alts[4 * s + 3] = .{ .apart = .{ try f.set(&.{try f.cb(try f.label(120 + si, .none, false))}), try f.set(&.{try f.cb(try f.label(130 + si, .none, false))}) } };
            h.entries[3 * s + 0] = .{ .goal = gen(10 + si), .alts = h.alts[4 * s ..][0..2] };
            h.entries[3 * s + 1] = .{ .goal = gen(20 + si), .alts = h.alts[4 * s + 2 ..][0..1], .reads = if (s == 0) &.{0} else &.{1} };
            h.entries[3 * s + 2] = .{ .goal = demand(si), .alts = h.alts[4 * s + 3 ..][0..1] };
        }
        h.world.entries = &h.entries;
    }
};

const helper_calls = [_]World.Call{
    .{ .inst = 100, .goal = gen(20) }, .{ .inst = 101, .goal = gen(21) },
    .{ .inst = 110, .goal = gen(10) }, .{ .inst = 111, .goal = gen(11) },
    .{ .inst = 120, .goal = gen(10) }, .{ .inst = 121, .goal = gen(11) },
    .{ .inst = 130, .goal = gen(10) }, .{ .inst = 131, .goal = gen(11) },
};

test "CallFeedbackGeneration: a changed supply invalidates exactly its dependent goals, and late weakening refuses after an acceptance" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const p0 = try f.prover.port(gpa, f.charge());
    const p1 = try f.prover.port(gpa, f.charge());
    _ = p1;
    var h: Helpers = .{ .f = &f, .world = .{ .f = &f, .entries = &.{}, .calls = &helper_calls }, .fresh = try f.leaf(0, &.{try f.site(7, 0)}), .captured = try f.leaf(0, &.{try f.sym(.env, 8, 0, &.{})}) };
    try h.refresh();
    try expectAnswer(try f.prove(&h.world, demand(0)), .proved, .exact);
    try expectAnswer(try f.prove(&h.world, demand(1)), .proved, .exact);
    const expanded = f.prover.stats.expanded;
    try testing.expectEqual(@as(u64, 6), expanded);
    // Supply 0's actual now answers a capture: its port changes. Exactly
    // gen(20), the helper's family gen(10) and the demand 0 are stale.
    h.capture[0] = true;
    try h.refresh();
    const before = f.prover.stats.invalidated;
    try f.prover.bump(gpa, f.charge(), p0);
    try testing.expectEqual(@as(u64, 3), f.prover.stats.invalidated - before);
    try testing.expectEqual(@as(?Answer, null), try f.prover.cached(gpa, f.charge(), demand(0)));
    try testing.expect((try f.prover.cached(gpa, f.charge(), demand(1))) != null);
    // The earlier acceptance is not served: the new generation refuses.
    try expectAnswer(try f.prove(&h.world, demand(0)), .refuted, .approximate);
    try expectAnswer((try f.prover.cached(gpa, f.charge(), gen(20))).?, .refuted, .exact);
    try testing.expectEqual(expanded + 3, f.prover.stats.expanded);
    // The other instance is served from its memo, not expanded again.
    const hits = f.prover.stats.memo_hits;
    try expectAnswer(try f.prove(&h.world, demand(1)), .proved, .exact);
    try testing.expectEqual(hits + 1, f.prover.stats.memo_hits);
    try testing.expectEqual(expanded + 3, f.prover.stats.expanded);
    // And back: a fresh actual again, a new version, accepted again.
    h.capture[0] = false;
    try h.refresh();
    try f.prover.bump(gpa, f.charge(), p0);
    try expectAnswer(try f.prove(&h.world, demand(0)), .proved, .exact);
}

test "a version that changes during a solve solves again on the new generation; no answer of the old one is published" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const Moving = struct {
        f: *Fixture,
        port_id: u32,
        captured: bool = false,
        moved: bool = false,
        fresh: NodeId,
        capture: NodeId,
        via: NodeId,

        fn expand(ctx: *anyopaque, ex: *Expansion) Error!void {
            const m: *@This() = @ptrCast(@alignCast(ctx));
            switch (ex.goal.claim) {
                // Family 0's base reads the capture's port; a step through its
                // earlier closure. Family 1, expanded after family 0's answer
                // is in hand, discovers that the capture changed: that answer
                // is of an old generation.
                .gen => if (ex.goal.port == 0) {
                    try ex.read(m.port_id);
                    try ex.gen(m.f.view(), if (m.captured) m.capture else m.fresh, &.{}, m.resolver());
                    try ex.gen(m.f.view(), m.via, &.{}, m.resolver());
                } else {
                    if (!m.moved) {
                        m.moved = true;
                        m.captured = true;
                        try m.f.prover.bump(ex.gpa, ex.charge, m.port_id);
                    }
                    try ex.gen(m.f.view(), m.fresh, &.{}, m.resolver());
                },
                .demand => {
                    try ex.begin();
                    try ex.need(gen(0));
                    try ex.need(gen(1));
                },
                .inv => unreachable,
            }
        }

        fn resolver(m: *@This()) Resolve {
            return .{ .ctx = m, .callee = callee };
        }

        fn callee(_: *anyopaque, _: CellId) ?Goal {
            return gen(0);
        }
    };
    var m: Moving = .{ .f = &f, .port_id = try f.prover.port(gpa, f.charge()), .fresh = try f.leaf(0, &.{try f.site(1, 0)}), .capture = try f.leaf(0, &.{try f.sym(.env, 2, 0, &.{})}), .via = try f.leaf(0, &.{try f.cb(try f.label(3, .none, false))}) };
    // The family first, proved under the fresh base.
    const eqs: Equations = .{ .ctx = &m, .expand = Moving.expand };
    try expectAnswer(try f.prover.prove(gpa, f.charge(), &f.conds, eqs, gen(0)), .proved, .exact);
    // The demand's solve sees the family's port change mid-way: it reads
    // the stale proof once, publishes nothing from it, and solves again.
    try expectAnswer(try f.prover.prove(gpa, f.charge(), &f.conds, eqs, demand(0)), .refuted, .approximate);
    try testing.expectEqual(@as(u64, 1), f.prover.stats.stale_reruns);
    try expectAnswer((try f.prover.cached(gpa, f.charge(), gen(0))).?, .refuted, .exact);
    // The same with the family first expanded inside the demand's solve: its
    // own recorded read is what has gone stale.
    var g: Fixture = .{};
    try g.init();
    defer g.deinit();
    var m2: Moving = .{ .f = &g, .port_id = try g.prover.port(gpa, g.charge()), .fresh = try g.leaf(0, &.{try g.site(1, 0)}), .capture = try g.leaf(0, &.{try g.sym(.env, 2, 0, &.{})}), .via = try g.leaf(0, &.{try g.cb(try g.label(3, .none, false))}) };
    const eqs2: Equations = .{ .ctx = &m2, .expand = Moving.expand };
    try expectAnswer(try g.prover.prove(gpa, g.charge(), &g.conds, eqs2, demand(0)), .refuted, .approximate);
    try testing.expectEqual(@as(u64, 1), g.prover.stats.stale_reruns);
    try expectAnswer((try g.prover.cached(gpa, g.charge(), gen(0))).?, .refuted, .exact);
}

test "failure rollback: a refused reservation at any step publishes nothing and leaves every earlier answer served" {
    const gpa = testing.allocator;
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const calls = [_]World.Call{ .{ .inst = 30, .goal = gen(0) }, .{ .inst = 40, .goal = gen(0) }, .{ .inst = 41, .goal = gen(0) } };
    const fresh = try f.leaf(0, &.{try f.site(10, 0)});
    const via = try f.leaf(0, &.{try f.cb(try f.label(30, .none, false))});
    const a = try f.set(&.{try f.cb(try f.label(40, .none, false))});
    const b = try f.set(&.{try f.cb(try f.label(41, .none, false))});
    const p = try f.prover.port(gpa, f.charge());
    var w: World = .{
        .f = &f,
        .calls = &calls,
        .entries = &.{
            .{ .goal = gen(0), .alts = &.{ .{ .gen = fresh }, .{ .gen = via } }, .reads = &.{p} },
            .{ .goal = demand(0), .alts = &.{.{ .apart = .{ a, b } }} },
            // An unrelated proved goal that must stay served.
            .{ .goal = demand(9), .alts = &.{.{ .require = Cond.yes }} },
        },
    };
    try expectAnswer(try f.prove(&w, demand(9)), .proved, .exact);
    try expectAnswer(try f.prove(&w, demand(0)), .proved, .exact);
    // A newer generation: the proof must be redone under every allowance.
    try f.prover.bump(gpa, f.charge(), p);
    var allowance: u32 = 0;
    var failures: u32 = 0;
    while (true) : (allowance += 1) {
        var acct: Ids.Account = .{ .allowance = allowance };
        defer acct.deinit(gpa);
        const got = f.prover.prove(gpa, .growth(&acct), &f.conds, w.equations(), demand(0));
        if (got) |ans| {
            try expectAnswer(ans, .proved, .exact);
            break;
        } else |err| {
            try testing.expectEqual(error.OwnershipLimit, err);
            failures += 1;
            // Nothing of the refused solve is served, the earlier answer
            // of the stale generation included; the unrelated one still is.
            try testing.expectEqual(@as(?Answer, null), try f.prover.cached(gpa, f.charge(), demand(0)));
            try testing.expectEqual(@as(?Answer, null), try f.prover.cached(gpa, f.charge(), gen(0)));
            try expectAnswer((try f.prover.cached(gpa, f.charge(), demand(9))).?, .proved, .exact);
        }
    }
    try testing.expect(failures >= 8);
}

/// A chain `gen_k ⇐ gen_{k−1}` of `n + 1` families, `gen_0` fresh, read
/// through ports 0..n, and a demand on `gen_n`; or, `ring`, one component
/// `gen_k ⇐ gen_{(k+1) mod (n+1)}` with `gen_0`'s fresh base.
fn chain(f: *Fixture, n: u32, ring: bool, entries: *std.ArrayList(Entry), alts: *std.ArrayList(AltSpec), calls: *std.ArrayList(World.Call), ports: *std.ArrayList(u32)) !void {
    const gpa = testing.allocator;
    try alts.ensureTotalCapacity(gpa, n + 3);
    for (0..n + 1) |_| try ports.append(gpa, try f.prover.port(gpa, f.charge()));
    const fresh = try f.leaf(0, &.{try f.site(1, 0)});
    for (0..n + 1) |k| {
        const ki: u32 = @intCast(k);
        const start = alts.items.len;
        if (k == 0) alts.appendAssumeCapacity(.{ .gen = fresh });
        if (k > 0 or ring) {
            const next: u32 = if (ring) (ki + 1) % (n + 1) else ki - 1;
            alts.appendAssumeCapacity(.{ .gen = try f.leaf(0, &.{try f.cb(try f.label(1000 + ki, .none, false))}) });
            try calls.append(gpa, .{ .inst = 1000 + ki, .goal = gen(next) });
        }
        _ = start;
        try entries.append(gpa, .{ .goal = gen(ki), .alts = &.{}, .reads = ports.items[k..][0..1] });
    }
    // Fix every entry's slice now that `alts` no longer moves.
    var at: usize = 0;
    for (entries.items, 0..) |*e, k| {
        const len: usize = if (k == 0 and ring) 2 else 1;
        e.alts = alts.items[at..][0..len];
        at += len;
    }
    alts.appendAssumeCapacity(.{ .gen = try f.leaf(0, &.{try f.cb(try f.label(999, .none, false))}) });
    try calls.append(gpa, .{ .inst = 999, .goal = gen(n) });
    try entries.append(gpa, .{ .goal = demand(0), .alts = alts.items[alts.items.len - 1 ..] });
}

test "proof work is counted and linear: chains and rings of 10, 100 and 1,000 goals; a changed port invalidates its dependents only" {
    const gpa = testing.allocator;
    var last: [2]u64 = .{ 0, 0 };
    for ([_]u32{ 10, 100, 1000 }) |n| for ([_]bool{ false, true }) |ring| {
        var f: Fixture = .{};
        try f.init();
        defer f.deinit();
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(gpa);
        var alts: std.ArrayList(AltSpec) = .empty;
        defer alts.deinit(gpa);
        var calls: std.ArrayList(World.Call) = .empty;
        defer calls.deinit(gpa);
        var ports: std.ArrayList(u32) = .empty;
        defer ports.deinit(gpa);
        try chain(&f, n, ring, &entries, &alts, &calls, &ports);
        var w: World = .{ .f = &f, .entries = entries.items, .calls = calls.items };
        var acct: Ids.Account = .{ .allowance = std.math.maxInt(u32) };
        defer acct.deinit(gpa);
        const ans = try f.prover.prove(gpa, .growth(&acct), &f.conds, w.equations(), demand(0));
        try expectAnswer(ans, .proved, .exact);
        const s = f.prover.stats;
        try testing.expectEqual(@as(u64, n + 2), s.expanded);
        try testing.expectEqual(@as(u64, n + 2 + @intFromBool(ring)), s.alternatives);
        try testing.expectEqual(@as(u64, n + 1 + @intFromBool(ring)), s.deps);
        try testing.expectEqual(@as(u64, if (ring) 2 else n + 2), s.components);
        // Two bases in the ring: gen_0's fresh answer and the demand's own.
        if (ring) try testing.expectEqual(@as(u64, 2), s.base);
        // The account's growth for the whole proof, the algebra's included:
        // 11 records per goal (127 / 1,117 / 11,017 for the chain, 8 more for
        // the ring), so ten times the goals is at most ten times the work.
        try testing.expect(acct.growth <= 12 * (n + 2));
        const slot = @intFromBool(ring);
        if (last[slot] > 0) try testing.expect(acct.growth <= 10 * last[slot]);
        last[slot] = acct.growth;
        // A change at the chain's root family invalidates everything above
        // it; one at its top, the top and the demand only.
        const before = f.prover.stats.invalidated;
        try f.prover.bump(gpa, f.charge(), ports.items[n]);
        try testing.expectEqual(@as(u64, if (ring) n + 2 else 2), f.prover.stats.invalidated - before);
        const mid = f.prover.stats.invalidated;
        try f.prover.bump(gpa, f.charge(), ports.items[0]);
        try testing.expectEqual(@as(u64, if (ring) 0 else n), f.prover.stats.invalidated - mid);
        const again = try f.prover.prove(gpa, .growth(&acct), &f.conds, w.equations(), demand(0));
        try expectAnswer(again, .proved, .exact);
        try testing.expectEqual(@as(u64, 2 * (n + 2)), f.prover.stats.expanded);
    };
}
