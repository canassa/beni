//! Unification (checker-v2.md §7): v1's `unifyFlat`, `unifyRecord`,
//! `unifyAlias` and kind lattice with the dispatch arms removed.
//!
//! **`unify` merges and queues. It never resolves and never reports**
//! (§7.1). It returns `ok` or `mismatch(problem)` and the caller reports it
//! with its category, which is Elm's split. What it does besides merging:
//!
//!   - a merge that lowers a rigid's rank, or binds an outer flex to a
//!     younger structure, appends a `Capture` to the module's list (§7.1,
//!     *As built by R4b*), which is where §8.3 reports an escape;
//!   - a record merge leaves the surviving root **normalised** (§4.1): one
//!     node, the union of the fields sorted by symbol, and the chain's end.
//!
//! **Which failing field is reported is chosen by name text** (§7.2, I13,
//! CK-07): every shared field is unified, and among those that failed the
//! one whose name is smallest by text supplies the problem. With one
//! failure, the common case, nothing extra is done.
//!
//! **Depth** (§7.3): the recursion guard is v1's (`Parse.max_depth + 104`),
//! but past it `unify` fails with `too_deep`, which the caller reports as
//! `nesting_too_deep`. It never answers "ok" (CK-10 item 3).
//!
//! **Obligations ride on their variables** (§4.5): binding a flex readies
//! every open obligation on it (onto the queue of the frame it was created
//! under, §9.1), merging
//! two flexes joins their sets and lowers every variable of every obligation
//! now on the survivor to its rank (I15), and a flex carrying the `equatable`
//! marker that meets a structure turns the marker's question into an
//! obligation, readied (§11.4). Nothing is decided here.
//!
//! **Wanteds ride on their receivers** (§4.2, §7.1, R6a): binding a flex
//! readies every wanted on it (a flex bound to a rigid included: the
//! resolver then reads the rigid's givens), and two merging flexes join
//! their constraint sets by Rule U1 — one wanted per method name, the younger
//! answered `alias(older)` and the two method types unified once the roots
//! are merged. A join whose method types disagree is `join_failures`'s, for
//! the caller to report: `unify` never resolves and never reports.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Parse = @import("../parse/Parse.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Generalize = @import("Generalize.zig");
const Walk = @import("Walk.zig");
const Obligations = @import("Obligations.zig");
const Evidence = @import("Evidence.zig");

const Unify = @This();

pub const Var = TypeStore.Var;
pub const Symbol = InternPool.Symbol;
pub const Error = Allocator.Error;

/// Why a unification failed, when the reason is more specific than "these
/// two types differ" (v1's `Solve.Problem`, plus `too_deep`).
pub const Problem = union(enum) {
    kinds: struct { left: TypeStore.Kind, right: TypeStore.Kind },
    kind_not_satisfied: struct { kind: TypeStore.Kind },
    not_equatable_rigid: Var,
    missing_field: Fields,
    unknown_field: Fields,
    record_not_closed: struct { actual: Var, expected: Var },
    /// §7.3: the recursion guard stopped the walk.
    too_deep,

    pub const Fields = struct { names: []Symbol, actual: Var, expected: Var };
};

pub const Result = union(enum) {
    ok,
    /// `null` when the two types simply differ.
    mismatch: ?Problem,
};

/// The recursion guard (§7.3): deep enough for anything the parser accepts.
pub const max_depth = Parse.max_depth + 104;

store: *TypeStore,
types: *const Types,
interner: *const InternPool.Global,
gpa: Allocator,
scratch: Allocator,
/// The open frames; the last is current. Fresh variables `unify` makes go
/// in its pool at its rank.
frames: *std.ArrayList(Generalize.Frame),
captures: *std.ArrayList(Generalize.Capture),
/// The module's obligations (§4.5): `unify` readies them when a flex that
/// carries one is bound, joins their sets when two flexes merge, and lowers
/// the dependants of the rows whose owner's rank dropped. It never decides
/// one (§7.1).
obligations: *Obligations,
/// The frames' `ready` queues (§9.1), which `Solve` owns: a readied item
/// goes on the queue of the frame it was created under (its `frame`),
/// whichever frame's unification readied it.
queues: *std.ArrayList(Generalize.Queue),
/// The current queue's `ready` list, which `Solve` holds apart while its
/// frame is current, and that queue's index.
ready: *std.ArrayList(u32),
ready_queue: *const u32,
/// For `lowerTo` (I15).
stacks: *Walk.Stacks,
/// The module's wanteds (§4.2): `unify` readies those riding on a flex it
/// binds, joins two flexes' sets by Rule U1 (the younger of two wanteds of
/// one name is answered `alias(older)`), and marks those meeting `err`
/// failed. It never resolves one (§7.1).
evidence: *Evidence,
/// Rule-U1 joins whose two method types did not unify. `unify` itself
/// succeeded — the variables merged — and the caller reports each one as
/// `method_constraint_mismatch` (v1's `unifyPending`), since `unify` never
/// reports (§7.1).
join_failures: std.ArrayList(JoinFailure) = .empty,
/// The first invariant a unification broke (`invariant`), for the caller to
/// report as `internal` (review S2): never a silent drop.
fault: ?[]const u8 = null,
region: Bir.Inst.Index = @enumFromInt(0),
/// Whether this unification is a call's argument meeting its parameter:
/// where a flag from a comparison's scheme becomes that comparison's
/// question (§11.4 *As built by R5*).
argument: bool = false,
problem: ?Problem = null,
/// The pairs of non-variables being unified, outermost first: the
/// coinduction of §7.3. Each pair is stored in the order `(min, max)` of
/// its roots when pushed.
active: std.ArrayList([2]Var) = .empty,
/// The pairs of `active` from index `hash_from` on, hashed (R8c, CK-93's
/// note): a deep acyclic unification would otherwise scan its whole path
/// per pair, quadratic in depth. An array hash map, popped in stack order:
/// a plain hash map's removals leave tombstones, and a deep unification's
/// pushes and pops made every probe longer (CK-111's scenario).
active_deep: std.AutoArrayHashMapUnmanaged([2]Var, void) = .empty,
/// Scratch: the rows of a merge side whose rank dropped (`lowerOwned`).
lowered: std.ArrayList(Obligations.Id) = .empty,
depth: u32 = 0,
unifications: u64 = 0,

pub fn unify(u: *Unify, a: Var, b: Var, region: Bir.Inst.Index) Error!Result {
    return u.unifyAt(a, b, region, false);
}

/// `unify`, saying whether it is a call's argument against its parameter.
pub fn unifyAt(u: *Unify, a: Var, b: Var, region: Bir.Inst.Index, argument: bool) Error!Result {
    u.problem = null;
    u.region = region;
    u.depth = 0;
    u.argument = argument;
    if (try u.go(a, b)) return .ok;
    const problem = u.problem;
    u.problem = null;
    return .{ .mismatch = problem };
}

/// Record the first specific reason: the deepest call that knows is the
/// most specific, and a later sibling failure is its consequence.
fn fail(u: *Unify, problem: Problem) bool {
    if (u.problem == null) u.problem = problem;
    return false;
}

fn frame(u: *Unify) *Generalize.Frame {
    return &u.frames.items[u.frames.items.len - 1];
}

/// A fresh variable at the current frame's rank, in its pool.
fn fresh(u: *Unify, content: TypeStore.Content) Error!Var {
    const f = u.frame();
    const v = try u.store.fresh(content, f.rank);
    try f.pool.append(u.gpa, v);
    return v;
}

/// Every merge `unify` makes (review S3): the store's union, then the
/// resolver's per-root class flags (`Evidence.rejected`, CK-37) OR-merged
/// onto the survivor, so a flag set on either side is on the one root that
/// remains — never keyed by a variable that stopped being a root.
fn merge(u: *Unify, a: Var, b: Var, content: TypeStore.Content) Error!Var {
    if (std.debug.runtime_safety) u.assertContained(a, b);
    // The store keeps the acyclicity proofs through the merge, or voids them
    // all when it adds an edge (`TypeStore.merge`, CK-93).
    const keep = u.store.merge(a, b, content);
    try u.evidence.mergeRejected(u.gpa, if (keep == a) b else a, keep);
    return keep;
}

/// §11.2's frame assert, in its linear form (CK-117, R8b): while a
/// fixpoint frame is the current frame — a derived-context pass, or P5's
/// rows — no unification may change a VARIABLE of an older frame. A pass
/// may bind its own variables to older structure (a done method's shared
/// ground `T`), but an older flex joined with anything of the pass would
/// carry the pass's wanteds or bindings out of a frame whose variables are
/// discarded. A group checked nested above the frame is its own current
/// frame, and legitimately merges down (§10.4). O(1) per merge, Debug only.
fn assertContained(u: *Unify, a: Var, b: Var) void {
    const f = u.frame();
    if (f.kind != .fixpoint) return;
    for ([_]Var{ a, b }) |x| {
        const rank = u.store.rank(x);
        if (rank == TypeStore.generalized or rank >= f.rank) continue;
        switch (u.store.content(x)) {
            .flex => std.debug.panic("a fixpoint frame's unification changed a variable of an older frame (checker-v2.md §11.2, CK-117)", .{}),
            else => {},
        }
    }
}

/// An invariant `unify` relies on (review S2, S8). `unify` never reports
/// (§7.1): a debug build stops here, and a release build keeps the first
/// broken one in `fault` for the caller to report as `internal`, then takes
/// the safe path (the caller's `continue` or `return`).
fn invariant(u: *Unify, cond: bool, what: []const u8) bool {
    if (cond) return true;
    if (builtin.mode == .Debug) std.debug.panic("checker v2 invariant: {s}", .{what});
    if (u.fault == null) u.fault = what;
    return false;
}

/// Bind the flex root `bound`, whose flags are `flags`, to `other`'s content:
/// the one place a flex stops being a variable. Every open obligation riding
/// on it is readied (§4.5, §7.1): queued, never decided here.
fn bind(u: *Unify, bound: Var, flags: TypeStore.Flags, other: Var, content: TypeStore.Content) Error!void {
    try u.release(flags);
    const low = u.store.rank(bound);
    if (low < u.store.rank(other)) {
        try u.captures.append(u.gpa, .{ .v = other, .region = u.region });
    }
    _ = try u.merge(bound, other, content);
}

/// Ready the open obligations and wanteds of a flex that is about to stop
/// being one. Against `err` too: the resolver then answers a wanted
/// `failed`, in silence (§7.1), and an obligation poisons its results.
inline fn release(u: *Unify, flags: TypeStore.Flags) Error!void {
    // Inline, with the rest out of line: most flexes carry nothing (R14b).
    if (flags.obls == .none and flags.constraints == .none) return;
    return u.releaseSlow(flags);
}

fn releaseSlow(u: *Unify, flags: TypeStore.Flags) Error!void {
    if (flags.obls != .none) {
        // `Obligations.ready`, routed: each row to its own frame's queue.
        for (u.obligations.members(flags.obls)) |id| {
            const r = u.obligations.rowPtr(id);
            if (r.state != .open) continue;
            r.state = .ready;
            try u.enqueue(r.frame, id.int());
        }
    }
    const set = flags.constraints;
    const n = u.store.constraintCount(set);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const id = u.evidence.slotAt(Evidence.position(u.store, set, i)).asWanted() orelse {
            _ = u.invariant(false, "a method requirement on a flex is paired with no wanted (checker-v2.md §4.2 *As built by R6a*)");
            continue;
        };
        try u.readyWanted(id);
    }
}

/// Put an open wanted on the queue (§9.1). Queued, never resolved here.
fn readyWanted(u: *Unify, id: Evidence.WantedId) Error!void {
    // I14: a probe writes nothing the journal cannot undo (§7.5).
    if (!u.invariant(u.store.depth == 0, "a wanted was readied inside a speculation (checker-v2.md §7.5, I14)")) return;
    const w = u.evidence.ptr(id);
    if (w.state != .open) return;
    w.state = .ready;
    try u.enqueue(w.frame, id.int() | Evidence.queued_wanted);
}

/// Put a readied item on the `ready` queue of the frame it was created
/// under (§9.1, round 4 R4-1) — or of the root it was re-pointed to when its
/// frame handed down (`Groups.handDown`). A popped frame left nothing that can
/// be readied: its variables were generalised, or handed down with its items.
pub fn enqueue(u: *Unify, q: u32, raw: u32) Error!void {
    if (q == u.ready_queue.*) return u.ready.append(u.gpa, raw);
    if (!u.invariant(u.queues.items[q].live, "an item was readied for a frame that is gone (checker-v2.md §9.1)")) return;
    try u.queues.items[q].ready.append(u.gpa, raw);
}

/// A Rule-U1 join whose method types did not unify, for the caller to report.
pub const JoinFailure = struct { younger: Evidence.WantedId, older: Evidence.WantedId };

/// One pair of wanteds of one name met on a merge: after the roots are
/// merged, their method types are unified and the younger aliases the older.
const Join = struct { older: Evidence.WantedId, younger: Evidence.WantedId };

/// **Rule U1** (static-dispatch-spike.md §6.2, checker-v2.md §7.1): the
/// constraint set of two merging flexes. A name on one side only is carried
/// over; a name on both is one wanted — the older by `seq` — and the pair is
/// appended to `joins` for the caller to unify once the roots are merged
/// (merging first stops the re-entry, as in v1). On a `number` survivor an
/// `eq` or `compare` wanted is readied instead, for the `number` bridge
/// (§9.2): a `number` never promotes one. A set neither input changes is
/// returned as it is; otherwise a fresh one, every position paired with its
/// wanted (`Evidence.slots`).
fn unionWants(u: *Unify, fa: TypeStore.Flags, fb: TypeStore.Flags, kind: TypeStore.Kind, joins: *std.ArrayList(Join)) Error!TypeStore.ConstraintSet.Optional {
    const st = u.store;
    const sa = fa.constraints;
    const sb = fb.constraints;
    const bridged = kind == .number and (fa.kind != .number or fb.kind != .number);
    if (!bridged) {
        if (sa == .none) return sb;
        if (sb == .none) return sa;
    }
    var entries: std.ArrayList(TypeStore.MethodConstraint) = .empty;
    defer entries.deinit(u.scratch);
    var ids: std.ArrayList(Evidence.WantedId) = .empty;
    defer ids.deinit(u.scratch);
    var changed = false;
    for ([_]TypeStore.ConstraintSet.Optional{ sa, sb }, 0..) |set, side| {
        const n = st.constraintCount(set);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const c = st.constraintAt(set, i);
            const id = u.evidence.slotAt(Evidence.position(st, set, i)).asWanted() orelse {
                _ = u.invariant(false, "a method requirement on a flex is paired with no wanted (checker-v2.md §4.2 *As built by R6a*)");
                continue;
            };
            if (bridged and isWellKnownName(c.name)) {
                try u.readyWanted(id);
                changed = true;
                continue;
            }
            if (side == 1) {
                changed = true;
                const at = for (entries.items, 0..) |e, j| {
                    if (e.name == c.name) break j;
                } else null;
                if (at) |j| {
                    const other = ids.items[j];
                    // A failed wanted is never an alias target (§4.2: a
                    // flex's set is its open wanteds; round-2 review, S1):
                    // the live one keeps the name, and the failed one leaves
                    // the set with nothing joined to it.
                    const id_failed = u.evidence.get(id).state.rejected();
                    const other_failed = u.evidence.get(other).state.rejected();
                    if (id_failed or other_failed) {
                        if (other_failed and !id_failed) {
                            entries.items[j] = c;
                            ids.items[j] = id;
                        }
                        continue;
                    }
                    if (u.evidence.get(id).seq < u.evidence.get(other).seq) {
                        entries.items[j] = c;
                        ids.items[j] = id;
                        try joins.append(u.scratch, .{ .older = id, .younger = other });
                    } else {
                        try joins.append(u.scratch, .{ .older = other, .younger = id });
                    }
                    continue;
                }
            }
            try entries.append(u.scratch, c);
            try ids.append(u.scratch, id);
        }
    }
    if (!changed) return sa;
    if (entries.items.len == 0) return .none;
    const set = try st.addConstraints(entries.items);
    for (ids.items, 0..) |id, i| {
        try u.evidence.setSlot(u.gpa, Evidence.position(st, set.toOptional(), @intCast(i)), .wanted(id));
    }
    return set.toOptional();
}

fn isWellKnownName(name: Symbol) bool {
    return name == InternPool.WellKnown.eq.symbol() or name == InternPool.WellKnown.compare.symbol();
}

/// After a merge into `root`: the joined pairs' method types are unified,
/// the younger of each pair answered `alias(older)`, and every wanted now on
/// the survivor has its method type lowered to the survivor's rank (I15).
fn finishJoins(u: *Unify, root: Var, joins: []const Join, lowered: []const Var) Error!void {
    if (joins.len != 0 and !u.invariant(u.store.depth == 0, "a Rule-U1 join ran inside a speculation (checker-v2.md §7.5, I14)")) return;
    const rank = u.store.rank(root);
    for (lowered) |v| try Walk.lowerTo(u.store, u.stacks, u.gpa, v, rank);
    for (joins) |j| {
        const younger = u.evidence.ptr(j.younger);
        younger.state = .answered;
        u.evidence.setAnswer(j.younger, .{ .alias = j.older });
        u.evidence.joinField(j.older, j.younger);
        const saved = u.problem;
        defer u.problem = saved;
        u.problem = null;
        if (!try u.go(u.evidence.get(j.older).method_type, u.evidence.get(j.younger).method_type)) {
            try u.join_failures.append(u.gpa, .{ .younger = j.younger, .older = j.older });
        }
    }
}

/// A flex carrying the `equatable` marker is bound to a structure or an
/// alias `other`: the marker's question about it becomes an obligation,
/// readied now and decided by the marker walk when drained (§11.4). A flex
/// that already carries its question's row (the comparison's argument, or a
/// flag the walk propagated) has `bind` ready that row instead, which
/// remembers where the question was asked.
fn equatableMeets(u: *Unify, flags: TypeStore.Flags, other: Var) Error!void {
    if (!flags.equatable or u.obligations.openEquatable(flags.obls) != null) return;
    const id = try u.obligations.create(u.gpa, .equatable, u.region, &.{other}, 0, null);
    u.obligations.rowPtr(id).state = .ready;
    try u.enqueue(u.obligations.rowPtr(id).frame, id.int());
}

/// Whether a flex carrying `flags` may meet a rigid that is not marked
/// `equatable`: only when it carries its question's row, which then reports
/// where the question was asked (§11.4).
fn equatableRigidDeferred(u: *Unify, flags: TypeStore.Flags) bool {
    return u.obligations.openEquatable(flags.obls) != null;
}

/// After a merge into `root` lowered the rank of a side that carried the
/// rows `ids`, lower the dependants of those it owns to `root`'s rank (I15,
/// §4.5); the other side's rows already hold it. Ranks only fall, so a row
/// is lowered at most once per level (§4.5's cost claim, CK-97).
fn lowerOwned(u: *Unify, root: Var, ids: []const Obligations.Id) Error!void {
    const rank = u.store.rank(root);
    for (ids) |id| {
        const row = u.obligations.row(id);
        if (row.state != .open) continue;
        if (u.store.find(row.vars[row.owner()]) != root) continue;
        for (row.dependants()) |slot| try Walk.lowerTo(u.store, u.stacks, u.gpa, row.vars[slot], rank);
    }
}

fn isChildless(c: TypeStore.Content) bool {
    return switch (c) {
        .structure => |s| switch (s) {
            .unit, .empty_record => true,
            .app => |a| a.args.len == 0,
            else => false,
        },
        else => false,
    };
}

fn go(u: *Unify, a: Var, b: Var) Error!bool {
    u.depth += 1;
    defer u.depth -= 1;
    if (u.depth > max_depth) return u.fail(.too_deep);

    const st = u.store;
    const ra = st.find(a);
    const rb = st.find(b);
    if (ra == rb) return true;
    u.unifications += 1;

    const ca = st.content(ra);
    const cb = st.content(rb);
    if (ca == .alias or cb == .alias) return u.throughAlias(ra, ca, rb, cb);
    // **Coinduction** (§7.3, *As built by R4b's review*). Only two
    // non-variables recurse, and only they can meet again on a cycle: a pair
    // already being unified further up is assumed equal, so a cyclic graph —
    // or two isomorphic ones — terminates, and a finite type is unchanged
    // (in a finite graph no pair is its own descendant). Children are still
    // unified before the merge, so a message still prints two types.
    if (!isVariable(ca) and !isVariable(cb)) {
        // Two structures with no children (`Int`, `()`, `{}`) recurse into
        // nothing, so they cannot meet a pair again: no pair is pushed (R8c).
        if (isChildless(ca) and isChildless(cb)) return u.flat(ra, ca.structure, rb, cb.structure);
        if (u.isActive(ra, rb)) return true;
        try u.pushActive(ra, rb);
        defer u.popActive();
        return u.structure(ra, ca.structure, rb, cb);
    }
    return switch (ca) {
        .err => {
            // A flex poisoned by meeting `err` readies what rides on it, which
            // then decides nothing and poisons its results silently (§7.1).
            if (cb == .flex) try u.release(cb.flex);
            _ = try u.merge(ra, rb, .err);
            return true;
        },
        .flex => |fa| u.flex(ra, fa, rb, cb),
        .rigid => |fa| u.rigid(ra, fa, rb, cb),
        .alias => unreachable, // `throughAlias`
        .structure => |sa| u.structure(ra, sa, rb, cb),
    };
}

/// Below this many active pairs nothing is scanned: a cycle is then met
/// again at most `scan_from` levels further down, where the scan finds it.
const scan_from = 8;
/// From this many active pairs on, the deeper ones are also hashed.
const hash_from = 64;

/// Whether the pair `(ra, rb)` is being unified further up (§7.3). The
/// shallow pairs are compared by their current roots; a hashed deep pair
/// by its roots when pushed, so a pair whose root a merge below it has
/// since changed is missed, and unrolled once more: merges only reduce the
/// roots, so that happens a bounded number of times.
fn isActive(u: *Unify, ra: Var, rb: Var) bool {
    const n = u.active.items.len;
    if (n < scan_from) return false;
    const st = u.store;
    for (u.active.items[0..@min(n, hash_from)]) |pair| {
        const x = st.find(pair[0]);
        const y = st.find(pair[1]);
        if ((x == ra and y == rb) or (x == rb and y == ra)) return true;
    }
    return n > hash_from and u.active_deep.contains(orderedPair(ra, rb));
}

fn orderedPair(a: Var, b: Var) [2]Var {
    return if (a.int() <= b.int()) .{ a, b } else .{ b, a };
}

fn pushActive(u: *Unify, ra: Var, rb: Var) Error!void {
    const pair = orderedPair(ra, rb);
    if (u.active.items.len >= hash_from) try u.active_deep.put(u.gpa, pair, {});
    try u.active.append(u.gpa, pair);
}

fn popActive(u: *Unify) void {
    const pair = u.active.pop().?;
    if (u.active.items.len >= hash_from) {
        const keys = u.active_deep.keys();
        if (keys.len != 0 and std.mem.eql(Var, &keys[keys.len - 1], &pair)) _ = u.active_deep.pop();
    }
}

fn flex(u: *Unify, ra: Var, fa: TypeStore.Flags, rb: Var, cb: TypeStore.Content) Error!bool {
    const st = u.store;
    switch (cb) {
        .err => {
            try u.release(fa);
            _ = try u.merge(ra, rb, .err);
            return true;
        },
        .flex => |fb| {
            const kind = TypeStore.Kind.meet(fa.kind, fb.kind) orelse
                return u.fail(.{ .kinds = .{ .left = fa.kind, .right = fb.kind } });
            // Nothing rides on either side and neither is marked: the join
            // below reduces to this (R8c's profile: the common case).
            if (fa.obls == .none and fb.obls == .none and fa.constraints == .none and fb.constraints == .none and !fa.equatable and !fb.equatable) {
                var plain = fb;
                plain.name = if (fb.name != .none) fb.name else fa.name;
                plain.kind = kind;
                _ = try u.merge(ra, rb, .{ .flex = plain });
                return true;
            }
            // One `Flags`, copied and changed field by field, never rebuilt
            // from parts: a rebuilt one drops what it does not name (CK-18).
            var joined = fb;
            joined.name = if (fb.name != .none) fb.name else fa.name;
            joined.kind = kind;
            joined.equatable = fa.equatable or fb.equatable;
            // The rows of a side whose rank is about to drop, taken before
            // the sets are joined in place (§4.5, I15).
            const low = @min(st.rank(ra), st.rank(rb));
            const dropped = u.lowered.items.len;
            if (st.rank(ra) > low) try u.lowered.appendSlice(u.gpa, u.obligations.owned(fa.obls));
            if (st.rank(rb) > low) try u.lowered.appendSlice(u.gpa, u.obligations.owned(fb.obls));
            joined.obls = try u.obligations.merged(u.gpa, fa.obls, fb.obls);
            // A comparison's flag meeting its argument: the question is
            // asked HERE, at the argument, and the row remembers it (§11.4
            // *As built by R5*: `Basics.eq r r`'s answer is reported at the
            // comparison, not where `r` later becomes a record).
            if (joined.equatable and u.argument and u.depth == 1 and u.obligations.openEquatable(joined.obls) == null) {
                const id = try u.obligations.create(u.gpa, .equatable, u.region, &.{ra}, 0, null);
                joined.obls = try u.obligations.with(u.gpa, joined.obls, id, true);
            }
            // Neither side carries a wanted: the common case, and nothing
            // of Rule U1 to do.
            if (fa.constraints == .none and fb.constraints == .none) {
                const root = try u.merge(ra, rb, .{ .flex = joined });
                defer u.lowered.shrinkRetainingCapacity(dropped);
                try u.lowerOwned(root, u.lowered.items[dropped..]);
                return true;
            }
            // Rule U1: the wanteds of both, one per name (§7.1).
            var joins: std.ArrayList(Join) = .empty;
            defer joins.deinit(u.scratch);
            joined.constraints = try u.unionWants(fa, fb, kind, &joins);
            // The method types of a side whose rank is about to drop (I15).
            var sink: std.ArrayList(Var) = .empty;
            defer sink.deinit(u.scratch);
            if (st.rank(ra) > low) try methodTypes(st, fa, &sink, u.scratch);
            if (st.rank(rb) > low) try methodTypes(st, fb, &sink, u.scratch);
            const root = try u.merge(ra, rb, .{ .flex = joined });
            defer u.lowered.shrinkRetainingCapacity(dropped);
            try u.lowerOwned(root, u.lowered.items[dropped..]);
            try u.finishJoins(root, joins.items, sink.items);
            return true;
        },
        .rigid => |fb| {
            // A rigid is a promise about ALL types: a `number` flex meeting a
            // rigid `a` wants more than the annotation said.
            if (fa.kind != .any and fa.kind != fb.kind) return false;
            if (fa.equatable and !fb.equatable and !u.equatableRigidDeferred(fa)) return u.fail(.{ .not_equatable_rigid = rb });
            try u.bind(ra, fa, rb, cb);
            return true;
        },
        .alias => unreachable, // `throughAlias`
        .structure => {
            if (fa.kind != .any and !u.kindAccepts(fa.kind, rb)) {
                return u.fail(.{ .kind_not_satisfied = .{ .kind = fa.kind } });
            }
            try u.equatableMeets(fa, rb);
            try u.bind(ra, fa, rb, cb);
            return true;
        },
    }
}

/// v1's flat membership test for `number` and `appendable`.
fn kindAccepts(u: *Unify, kind: TypeStore.Kind, v: Var) bool {
    const wk = u.types.well_known;
    const app = switch (u.store.resolvedContent(v)) {
        .structure => |s| switch (s) {
            .app => |a| a,
            else => return false,
        },
        .err => return true,
        else => return false,
    };
    return switch (kind) {
        .any => true,
        .number => app.args.len == 0 and (app.type == wk.int or app.type == wk.float),
        .appendable => (app.args.len == 0 and app.type == wk.string) or
            (app.args.len == 1 and app.type == wk.list),
    };
}

fn rigid(u: *Unify, ra: Var, fa: TypeStore.Flags, rb: Var, cb: TypeStore.Content) Error!bool {
    switch (cb) {
        .err => {
            _ = try u.merge(ra, rb, .err);
            return true;
        },
        .flex => |fb| {
            if (fb.kind != .any and fb.kind != fa.kind) return false;
            if (fb.equatable and !fa.equatable and !u.equatableRigidDeferred(fb)) return u.fail(.{ .not_equatable_rigid = ra });
            try u.bind(rb, fb, ra, .{ .rigid = fa });
            return true;
        },
        // Two rigids, or a rigid against a real type: the annotation
        // promised more than the code delivers.
        .rigid, .structure => return false,
        .alias => unreachable, // `throughAlias`
    }
}

/// Unify two types at least one of which is an alias (checker-v2.md §7.1
/// *amended by R15-fix-C*). An alias is a NAME for its expansion, so:
///
///   - **two types whose expansions end at one variable are one type**, and
///     nothing is written. Merging them anyway closed a cycle through an
///     alias's `actual`: `x` against `Id x` bound `x` to an alias whose
///     expansion is `x` (a false INFINITE TYPE, CK-172), and two same-named
///     aliases, one the other's argument, merged into a node that expands
///     to itself — the cycle `TypeStore.resolved` once stopped at 1 024
///     links with a silent `err` (CK-169). With this row no write makes an
///     alias reach itself through `actual`, which is what lets `resolved`
///     walk with no bound;
///   - a **variable** meets the alias's expansion when that expansion is a
///     variable too: a `number` flex against `Id number` is two flexes
///     (CK-174), a rigid against `Id a` is `a` against `a` (CK-173). Only a
///     flex against an alias of a STRUCTURE absorbs it by name, so a message
///     still prints `Id Int` where the program wrote it;
///   - two aliases of the same name unify their arguments and keep the
///     name; otherwise the expansions meet, directly — not one link per
///     recursion, which spent `max_depth` on a long chain.
fn throughAlias(u: *Unify, ra: Var, ca: TypeStore.Content, rb: Var, cb: TypeStore.Content) Error!bool {
    const st = u.store;
    const xa, const xca = if (ca == .alias) st.resolved(ra) else .{ ra, ca };
    const xb, const xcb = if (cb == .alias) st.resolved(rb) else .{ rb, cb };
    if (xa == xb) return true;
    if (ca == .alias and cb == .alias) {
        const aa = ca.alias;
        const ab = cb.alias;
        if (aa.type != ab.type or aa.args.len != ab.args.len) return u.go(xa, xb);
        if (u.isActive(ra, rb)) return true;
        try u.pushActive(ra, rb);
        defer u.popActive();
        if (!try u.pairs(aa.args, ab.args)) return false;
        // The arguments' unification may have joined the two, or their
        // expansions: then there is nothing to merge, and merging would
        // make the survivor's `actual` reach itself.
        const na = st.find(ra);
        const nb = st.find(rb);
        if (na == nb) return true;
        const ya, _ = st.resolved(na);
        const yb, _ = st.resolved(nb);
        if (ya == yb) return true;
        _ = try u.merge(na, nb, st.content(nb));
        return true;
    }
    // One side is an alias; `r`, `c` the other.
    const alias_left = ca == .alias;
    const r = if (alias_left) rb else ra;
    const c = if (alias_left) cb else ca;
    const x = if (alias_left) xa else xb;
    const xc = if (alias_left) xca else xcb;
    switch (c) {
        .err => {
            _ = try u.merge(ra, rb, .err);
            return true;
        },
        .flex => |f| switch (xc) {
            .flex, .rigid => return if (alias_left) u.go(x, r) else u.go(r, x),
            // The flex absorbs the alias, name and all.
            else => {
                const named = if (alias_left) ra else rb;
                if (f.kind != .any and !u.kindAccepts(f.kind, named)) {
                    return u.fail(.{ .kind_not_satisfied = .{ .kind = f.kind } });
                }
                try u.equatableMeets(f, named);
                try u.bind(r, f, named, st.content(named));
                return true;
            },
        },
        .rigid, .structure => return if (alias_left) u.go(x, r) else u.go(r, x),
        .alias => unreachable,
    }
}

/// Unify two argument lists elementwise, re-slicing the range each time:
/// unifying appends to `extra` and would dangle a view taken once.
fn pairs(u: *Unify, left: TypeStore.Range, right: TypeStore.Range) Error!bool {
    const n = @min(left.len, right.len);
    for (0..n) |i| {
        if (!try u.go(u.store.vars(left)[i], u.store.vars(right)[i])) return false;
    }
    return true;
}

fn structure(u: *Unify, ra: Var, sa: TypeStore.Structure, rb: Var, cb: TypeStore.Content) Error!bool {
    switch (cb) {
        .err => {
            _ = try u.merge(ra, rb, .err);
            return true;
        },
        .flex => |fb| {
            if (fb.kind != .any and !u.kindAccepts(fb.kind, ra)) {
                return u.fail(.{ .kind_not_satisfied = .{ .kind = fb.kind } });
            }
            try u.equatableMeets(fb, ra);
            try u.bind(rb, fb, ra, .{ .structure = sa });
            return true;
        },
        .rigid => return false,
        .alias => unreachable, // `throughAlias`
        .structure => |sb| return u.flat(ra, sa, rb, sb),
    }
}

fn flat(u: *Unify, ra: Var, sa: TypeStore.Structure, rb: Var, sb: TypeStore.Structure) Error!bool {
    const st = u.store;
    switch (sa) {
        .unit => {
            if (sb != .unit) return false;
            _ = try u.merge(ra, rb, .{ .structure = .unit });
            return true;
        },
        .empty_record => {
            if (sb != .empty_record) return false;
            _ = try u.merge(ra, rb, .{ .structure = .empty_record });
            return true;
        },
        // Children FIRST, merge only on success (Elm's order): merging up
        // front would print the same type twice in the message.
        .func => |fa| {
            const fb = switch (sb) {
                .func => |f| f,
                else => return false,
            };
            if (fa.params.len != fb.params.len) return false;
            if (!try u.pairs(fa.params, fb.params)) return false;
            if (!try u.go(fa.result, fb.result)) return false;
            _ = try u.merge(st.find(ra), st.find(rb), .{ .structure = .{ .func = fa } });
            return true;
        },
        .app => |aa| {
            const ab = switch (sb) {
                .app => |a| a,
                else => return false,
            };
            if (aa.type != ab.type or aa.args.len != ab.args.len) return false;
            if (!try u.pairs(aa.args, ab.args)) return false;
            _ = try u.merge(st.find(ra), st.find(rb), .{ .structure = .{ .app = aa } });
            return true;
        },
        .tuple => |ta| {
            const tb = switch (sb) {
                .tuple => |t| t,
                else => return false,
            };
            if (ta.len != tb.len) return false;
            if (!try u.pairs(ta, tb)) return false;
            _ = try u.merge(st.find(ra), st.find(rb), .{ .structure = .{ .tuple = ta } });
            return true;
        },
        .record => |rec_a| {
            const rec_b = switch (sb) {
                .record => |r| r,
                else => return false,
            };
            return u.record(ra, rec_a, rb, rec_b);
        },
    }
}

// ---------------------------------------------------------------------------
// Records: Elm's four-way field partition as one merge-join
// ---------------------------------------------------------------------------

const Gathered = struct {
    fields: std.ArrayList(TypeStore.Field),
    end: Walk.RowEnd,
    concatenated: bool,
};

fn gather(u: *Unify, rec: TypeStore.Structure.Record) Error!Gathered {
    var out: Gathered = .{ .fields = .empty, .end = undefined, .concatenated = false };
    out.end = try Walk.recordRow(u.store, rec, &out.fields, u.scratch, &out.concatenated);
    // A chain is two sorted runs concatenated; the merge-join needs one.
    if (out.concatenated) std.mem.sort(TypeStore.Field, out.fields.items, {}, symbolLessThan);
    return out;
}

fn symbolLessThan(_: void, a: TypeStore.Field, b: TypeStore.Field) bool {
    return @intFromEnum(a.name) < @intFromEnum(b.name);
}

fn endVar(end: Walk.RowEnd) Var {
    return switch (end) {
        .closed, .open => |v| v,
    };
}

/// One failed shared field, for the text-order choice of §7.2.
const Failure = struct { name: Symbol, problem: ?Problem };

fn record(u: *Unify, ra: Var, rec_a: TypeStore.Structure.Record, rb: Var, rec_b: TypeStore.Structure.Record) Error!bool {
    const st = u.store;
    var a = try u.gather(rec_a);
    defer a.fields.deinit(u.scratch);
    var b = try u.gather(rec_b);
    defer b.fields.deinit(u.scratch);
    const a_ext = endVar(a.end);
    const b_ext = endVar(b.end);
    const a_closed = a.end == .closed;
    const b_closed = b.end == .closed;

    var only_a: std.ArrayList(TypeStore.Field) = .empty;
    defer only_a.deinit(u.scratch);
    var only_b: std.ArrayList(TypeStore.Field) = .empty;
    defer only_b.deinit(u.scratch);
    var shared: std.ArrayList(Shared) = .empty;
    defer shared.deinit(u.scratch);

    var i: usize = 0;
    var j: usize = 0;
    while (i < a.fields.items.len and j < b.fields.items.len) {
        const fa = a.fields.items[i];
        const fb = b.fields.items[j];
        const na = @intFromEnum(fa.name);
        const nb = @intFromEnum(fb.name);
        if (na < nb) {
            try only_a.append(u.scratch, fa);
            i += 1;
        } else if (na > nb) {
            try only_b.append(u.scratch, fb);
            j += 1;
        } else {
            try shared.append(u.scratch, .{ .name = fa.name, .a = fa.value, .b = fb.value });
            i += 1;
            j += 1;
        }
    }
    try only_a.appendSlice(u.scratch, a.fields.items[i..]);
    try only_b.appendSlice(u.scratch, b.fields.items[j..]);

    // A field one side requires and the other cannot grow.
    if (only_a.items.len != 0 and !isOpenVar(st, b_ext)) {
        return u.fail(.{ .missing_field = .{ .names = try u.fieldNames(only_a.items), .actual = rb, .expected = ra } });
    }
    if (only_b.items.len != 0 and !isOpenVar(st, a_ext)) {
        return u.fail(.{ .unknown_field = .{ .names = try u.fieldNames(only_b.items), .actual = rb, .expected = ra } });
    }
    // Both can grow, but one promised to stay open: an annotation's
    // `{ r | … }` cannot become a specific record.
    if (isRigidVar(st, a_ext) != isRigidVar(st, b_ext) and (a_closed or b_closed)) {
        return u.fail(.{ .record_not_closed = .{ .actual = rb, .expected = ra } });
    }

    var ok = true;
    // Where the merged record's chain ends, for the normalised merge.
    var end: Var = a_ext;
    if (only_a.items.len == 0 and only_b.items.len == 0) {
        ok = try u.go(a_ext, b_ext) and ok;
    } else if (only_a.items.len == 0) {
        const sub = try u.freshRecord(only_b.items, b_ext);
        ok = try u.go(a_ext, sub) and ok;
        end = b_ext;
    } else if (only_b.items.len == 0) {
        const sub = try u.freshRecord(only_a.items, a_ext);
        ok = try u.go(sub, b_ext) and ok;
    } else {
        const ext = try u.fresh(.{ .flex = .{} });
        const sub_a = try u.freshRecord(only_a.items, ext);
        const sub_b = try u.freshRecord(only_b.items, ext);
        ok = try u.go(a_ext, sub_b) and ok;
        ok = try u.go(sub_a, b_ext) and ok;
        end = ext;
    }
    // A problem the extensions produced is v1's first and stays first.
    const kept = u.problem;
    var failures: std.ArrayList(Failure) = .empty;
    defer failures.deinit(u.scratch);
    // Past the depth guard no further field is tried: each would walk to the
    // guard again (review B1).
    const stopped = if (kept) |k| k == .too_deep else false;
    if (!stopped) for (shared.items) |pair| {
        u.problem = null;
        if (!try u.go(pair.a, pair.b)) {
            ok = false;
            if (u.problem) |p| if (p == .too_deep) return false;
            try failures.append(u.scratch, .{ .name = pair.name, .problem = u.problem });
        }
    };
    u.problem = kept;
    if (kept == null and failures.items.len != 0) {
        var best = failures.items[0];
        for (failures.items[1..]) |f| {
            if (std.mem.lessThan(u8, u.interner.slice(f.name), u.interner.slice(best.name))) best = f;
        }
        u.problem = best.problem;
    }
    if (!ok) return false;

    // Normalised on merge (§4.1): the survivor is ONE record, every field
    // and the chain's end. When `a` was already that — no chain, nothing
    // added — its own content is reused and nothing is allocated.
    const merged: TypeStore.Structure.Record = if (!a.concatenated and only_b.items.len == 0)
        rec_a
    else blk: {
        const all = try u.scratch.alloc(TypeStore.Field, a.fields.items.len + only_b.items.len);
        defer u.scratch.free(all);
        @memcpy(all[0..a.fields.items.len], a.fields.items);
        @memcpy(all[a.fields.items.len..], only_b.items);
        break :blk .{ .fields = try st.addFields(all), .ext = end };
    };
    _ = try u.merge(st.find(ra), st.find(rb), .{ .structure = .{ .record = merged } });
    return true;
}

const Shared = struct { name: Symbol, a: Var, b: Var };

fn freshRecord(u: *Unify, fields: []const TypeStore.Field, ext: Var) Error!Var {
    const copied = try u.scratch.dupe(TypeStore.Field, fields);
    defer u.scratch.free(copied);
    const range = try u.store.addFields(copied);
    return u.fresh(.{ .structure = .{ .record = .{ .fields = range, .ext = ext } } });
}

fn fieldNames(u: *Unify, fields: []const TypeStore.Field) Error![]Symbol {
    const out = try u.scratch.alloc(Symbol, fields.len);
    for (fields, out) |f, *n| n.* = f.name;
    return out;
}

fn isRigidVar(st: *TypeStore, v: Var) bool {
    return st.content(st.find(v)) == .rigid;
}

fn isOpenVar(st: *TypeStore, v: Var) bool {
    return switch (st.content(st.find(v))) {
        .flex, .rigid, .err => true,
        else => false,
    };
}

fn isVariable(c: TypeStore.Content) bool {
    return switch (c) {
        .flex, .rigid, .err => true,
        .alias, .structure => false,
    };
}

pub fn deinit(u: *Unify) void {
    u.active.deinit(u.gpa);
    u.active_deep.deinit(u.gpa);
    u.lowered.deinit(u.gpa);
    u.join_failures.deinit(u.gpa);
}

/// The method types of the wanteds riding on a flex with `flags`.
fn methodTypes(st: *TypeStore, flags: TypeStore.Flags, out: *std.ArrayList(Var), scratch: Allocator) Error!void {
    const set = Walk.constraints(flags);
    const n = set.count(st);
    var i: u32 = 0;
    while (i < n) : (i += 1) try out.append(scratch, set.at(st, i).fn_var);
}
