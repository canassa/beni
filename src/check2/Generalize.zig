//! Frames, rank adjustment and quantification (checker-v2.md §8.1, §8.4).
//!
//! Elm's `generalize` with pools per rank, as v1 has it, except that:
//!
//!   - the rank walk is ITERATIVE and has no depth guard (I4): v1's
//!     `adjustRank` recursed and, past its guard, answered with the
//!     variable's own rank, silently;
//!   - it takes its successors from `Walk.owned` (I2), so a
//!     variable's requirements and obligations are adjusted with it;
//!   - a frame is explicit (§7.5, §8.1, S-2): its rank, its young pool, the
//!     binders its occurs check starts from and its open-`?` list (§8.1
//!     step 3). It keeps no `touched` list: §18's
//!     measurement put the walk over it at 4 % of the check phase, so R4b
//!     took §18's fallback, Elm's placement (binders only).
//!
//! It also holds the frame stack's primitives — push, pop, and a merged
//! frame's queue handed down (§9.1, §10.4) — and step 6, the generality
//! check (§8.3), as §19.1 lays out; the boundary's occurs check (step 4)
//! and its order are `Solve.zig`'s (moved here by R7's review, S4).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Walk = @import("Walk.zig");
const builtin = @import("builtin");
const Messages = @import("Messages.zig");
const Obligations = @import("Obligations.zig");
const Solve = @import("Solve.zig");

pub const Var = TypeStore.Var;
pub const Error = Allocator.Error;

/// A merge that lowered a rigid's rank, or bound an outer flex to a younger
/// structure (§7.1, *As built by R4b*): where an escape (§8.3) is reported.
pub const Capture = struct { v: Var, region: Bir.Inst.Index };

/// One binder a boundary occurs-checks (§6.3): a pattern variable, a
/// parameter, or a `let` or top-level header.
pub const Binder = struct {
    v: Var,
    region: Bir.Inst.Index,
    name: InternPool.Symbol.Optional,
    /// The declaration it belongs to: who an `infinite_type` found from it is
    /// attributed to (§15.2, review S10).
    decl: ?u32 = null,
    kind: Kind = .pattern,

    pub const Kind = enum(u8) {
        /// A pattern variable or parameter, checked at the boundary.
        pattern,
        /// A `let` or top-level header, checked at the boundary AFTER the
        /// patterns, so a cycle a parameter carries is named by the
        /// parameter (§8.2).
        header,
        /// A lambda's or `case` branch's, already checked by its `binders_end`.
        ended,
    };
};

/// An annotated binding of a frame, for the generality check (§8.3).
pub const Annotated = struct {
    /// The scheme every use instantiates, poisoned on an escape.
    scheme: Var,
    /// The rigid reading the body was checked against; its variables are
    /// `rigids`, in first-appearance order.
    rigids_start: u32,
    rigids_len: u32,
    /// The annotation, where an escape with no capture is reported.
    annotation: Bir.Inst.Index,
    name: InternPool.Symbol.Optional,
    /// The declaration it is written in (§8.3's message, §15.2).
    decl: u32,
};

/// A boundary (§8.1): a top-level group — checked in SCC order, or nested at
/// demand (§10.2) — or a `let` group.
pub const Frame = struct {
    rank: u32,
    /// The young pool: every variable made at `rank` while this frame was
    /// current, by the generator or the solver.
    pool: std.ArrayList(Var) = .empty,
    /// The open `?` obligations whose target sits at this frame's rank
    /// (§4.5, §8.1 step 3): what its default step reads. A row whose target
    /// escapes moves to the list of the frame it escaped to, once (CK-98).
    tries: std.ArrayList(u32) = .empty,
    /// The module capture list's length when the frame was pushed.
    captures_start: u32 = 0,
    /// How many wanteds and obligation rows the module had when the frame
    /// was pushed: a frame under which none was made has none riding on its
    /// own variables, so its boundary skips the passes that look for them.
    wanteds_start: u32 = 0,
    rows_start: u32 = 0,
    /// The `ready` queue this frame's wanteds and obligations route to
    /// (§9.1): its own for a top-level-kind frame, its enclosing top-level
    /// frame's for a `let` frame.
    queue: u32 = 0,
    kind: Kind = .let,
    /// Top-level kind only: the binding group it checks (`Groups`).
    group: u32 = no_group,
    /// Merged into a frame below it (§10.4): at its end it runs steps 1 and 2
    /// only, and hands its pool, binders, `?` list and members down.
    merged: bool = false,
    /// In a recursive group — a value SCC of two or more members, or a group
    /// that has merged — so D14's canonical pessimism applies (§10.7).
    recursive: bool = false,
    /// What the frames merged into this one handed down, for its boundary;
    /// null until one does (kept out of line: most frames never merge).
    inherited: ?*Inherited = null,

    /// Their binders (copied out of their trees) and their members.
    pub const Inherited = struct {
        binders: std.ArrayList(Binder) = .empty,
        members: std.ArrayList(u32) = .empty,
    };

    pub const Kind = enum(u8) { top, let };
    pub const no_group = std.math.maxInt(u32);

    pub fn deinit(f: *Frame, gpa: Allocator) void {
        f.pool.deinit(gpa);
        f.tries.deinit(gpa);
        if (f.inherited) |i| {
            i.binders.deinit(gpa);
            i.members.deinit(gpa);
            gpa.destroy(i);
        }
    }
};

/// One top-level-kind frame's `ready` queue (§9.1, round 3 B-1): what a
/// unification readied for a wanted or obligation created under that frame.
/// A frame drains only its own, so a nested group never decides its
/// demander's items. When a merged frame hands down, its items are re-pointed
/// to its root's queue (§9.1 *Merges*), so a popped queue is free for reuse.
pub const Queue = struct {
    ready: std.ArrayList(u32) = .empty,
    /// Readied `equatable` rows the eager drain set aside for the next
    /// boundary's step 1 (`Decide.drain`).
    deferred: std.ArrayList(u32) = .empty,
    /// Its frame's index while the frame is on the stack.
    frame: u32,
    live: bool = true,

    pub const none = std.math.maxInt(u32);

    pub fn deinit(q: *Queue, gpa: Allocator) void {
        q.ready.deinit(gpa);
        q.deferred.deinit(gpa);
    }

    pub fn isEmpty(q: *const Queue) bool {
        return q.ready.items.len == 0 and q.deferred.items.len == 0;
    }
};

// ---------------------------------------------------------------------------
// The frame stack (§8.1, §9.1, §10): pushed and popped by the solver
// ---------------------------------------------------------------------------

/// Push a frame at `rank`, which is its depth. A top-level-kind frame gets a
/// `ready` queue of its own; a `let` frame routes to its enclosing one's
/// (§9.1). Also P5's frame (`Eager.zig`), which has no tree and no boundary.
pub fn pushFrame(s: *Solve, rank: u32, kind: Frame.Kind) Error!void {
    // `Generalize.quantify` hands an escaped variable to `frames[rank - 1]`:
    // a frame's rank is its depth (review N4).
    std.debug.assert(rank == s.frames.items.len + 1);
    const gpa = s.cx.gpa;
    const queue: u32 = switch (kind) {
        .top => blk: {
            // A popped frame's queue is free in a release build: nothing
            // routes to it again (its variables were generalised, or handed
            // down with its items re-pointed), so the list is as long as the
            // nesting is deep (`popFrame`).
            const q: u32 = if (s.free_queues.pop()) |free| free else blk2: {
                try s.queues.append(gpa, .{ .frame = 0 });
                break :blk2 @intCast(s.queues.items.len - 1);
            };
            s.queues.items[q] = .{ .frame = @intCast(s.frames.items.len), .deferred = s.queues.items[q].deferred };
            parkReady(s);
            // A popped queue's buffer is reused: a module is one top-level
            // frame per group, and most ready only a few items.
            s.ready = s.spare.pop() orelse .empty;
            s.ready_queue = q;
            break :blk q;
        },
        .let => s.frame().queue,
    };
    try s.frames.append(gpa, .{
        .rank = rank,
        .captures_start = @intCast(s.captures.items.len),
        .wanteds_start = @intCast(s.evidence.wanteds.items.len),
        .rows_start = @intCast(s.obligations.rows.items.len),
        .queue = queue,
        .kind = kind,
    });
    s.obligations.current_queue = queue;
}

/// The current (merged) frame's queue goes to `target`, its root's (§9.1
/// *Merges*): what is left in it — nothing after step 1, unless a decision
/// readied an item of a frame below — is appended there, and every wanted
/// and row created under this frame is re-pointed there, so what readies it
/// later lands in the root's queue. A nested group's items among them keep
/// their own queue. The frame is popped after.
pub fn handQueueDown(s: *Solve, target: u32) Error!void {
    const gpa = s.cx.gpa;
    const f = s.frame();
    const q = f.queue;
    std.debug.assert(f.kind == .top and q == s.ready_queue);
    try s.queues.items[target].ready.appendSlice(gpa, s.ready.items);
    try s.queues.items[target].deferred.appendSlice(gpa, s.queues.items[q].deferred.items);
    s.ready.clearRetainingCapacity();
    s.queues.items[q].deferred.clearRetainingCapacity();
    s.evidence.repoint(f.wanteds_start, q, target);
    s.obligations.repoint(f.rows_start, q, target);
}

pub fn popFrame(s: *Solve) void {
    const gpa = s.cx.gpa;
    var f = s.frames.pop().?;
    if (f.recursive) s.recursive_frames -= 1;
    if (f.kind == .top) {
        // A top-level-kind frame leaves nothing readied behind it: every row
        // is decided by its last drain, or settled by `poison` (review S7);
        // a merged one handed its queue down first (`Groups.handDown`).
        const q = &s.queues.items[f.queue];
        std.debug.assert(f.queue == s.ready_queue and s.ready.items.len == 0 and q.isEmpty());
        q.live = false;
        q.deferred.clearRetainingCapacity();
        if (s.ready.capacity != 0) s.spare.append(gpa, s.ready) catch s.ready.deinit(gpa);
        s.ready = .empty;
        s.ready_queue = Queue.none;
        // Reused in a release build; never in Debug, where the `live`
        // check of `Unify.enqueue` then catches a stale id at full strength
        // (R7's review, S2).
        if (builtin.mode != .Debug) s.free_queues.append(gpa, f.queue) catch {};
        if (s.frames.items.len != 0) takeReady(s, s.frame().queue);
    }
    f.deinit(gpa);
    s.obligations.current_queue = if (s.frames.items.len != 0) s.frame().queue else Obligations.no_queue;
}

/// The current queue's `ready` list goes back into its `Queue`, for a frame
/// pushed above it.
fn parkReady(s: *Solve) void {
    if (s.ready_queue == Queue.none) return;
    s.queues.items[s.ready_queue].ready = s.ready;
    s.ready = .empty;
}

/// Queue `q`'s `ready` list becomes the current one.
fn takeReady(s: *Solve, q: u32) void {
    s.ready = s.queues.items[q].ready;
    s.queues.items[q].ready = .empty;
    s.ready_queue = q;
}

// ---------------------------------------------------------------------------
// Step 6: the generality check (§8.3)
// ---------------------------------------------------------------------------

/// §8.3 (I1): every rigid of an annotated binding's checked reading must
/// still be a rigid root, and generalised. One message per binding.
pub fn generality(s: *Solve, a: Annotated, top: bool) Error!void {
    const st = s.store();
    s.report.at(a.decl);
    const rigids = s.tree.vars(a.rigids_start, a.rigids_len);
    for (rigids, 0..) |r, i| {
        const root = st.find(r);
        switch (st.content(root)) {
            // Already reported where it was poisoned.
            .err => continue,
            .rigid => {},
            else => return s.report.internal(a.annotation, "an annotation's type variable stopped being rigid (checker-v2.md §8.3, invariant I1)"),
        }
        for (rigids[0..i]) |other| {
            if (st.find(other) == root) return s.report.internal(a.annotation, "two type variables of one annotation became one (checker-v2.md §8.3, invariant I1)");
        }
        if (st.rank(root) == TypeStore.generalized) continue;
        // A top-level rigid has nothing to escape into (§8.3): a failure is
        // the compiler's.
        if (top) return s.report.internal(a.annotation, "a top-level annotation's type variable was not generalised (checker-v2.md §8.3, invariant I1)");
        const region = try captureOf(s, root) orelse a.annotation;
        const enclosing = s.cx.bir.symbol(s.cx.bir.decls[a.decl].name);
        try Messages.escape(s.report, region, a.name, enclosing, a.scheme, root);
        // The scheme, so callers are not held to the false promise, and the
        // rigid itself, so what the body tied it to (a lambda parameter, say)
        // adds no second message about `a` outside `g` (F5).
        try s.poison(a.scheme);
        try s.poison(root);
        return;
    }
}

/// The first capture since the current frame was pushed whose node is the
/// escaped rigid or reaches it (§7.1, *As built by R4b*).
fn captureOf(s: *Solve, rigid: Var) Error!?Bir.Inst.Index {
    const start = s.frame().captures_start;
    for (s.captures.items[start..]) |c| {
        if (try Walk.reaches(s.store(), &s.stacks, s.cx.gpa, c.v, rigid)) return c.region;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Rank adjustment and quantification
// ---------------------------------------------------------------------------

/// Where a variable of one young root sits while ranks are adjusted.
const Entry = struct { v: Var, bucket: u32 };

fn bucketLessThan(_: void, a: Entry, b: Entry) bool {
    return a.bucket < b.bucket;
}

/// Step 2 of §8.1: Elm's `poolToRankTable` + `adjustRank` over `pool`, whose
/// young rank is `young`, lowest ranks first so every rank is computed in
/// one pass. Afterwards a variable's rank says whether it escapes.
pub fn adjustRanks(
    store: *TypeStore,
    stacks: *Walk.Stacks,
    gpa: Allocator,
    scratch: Allocator,
    pool: []const Var,
    young: u32,
) Error!void {
    const young_mark = store.nextMark();
    const visit_mark = store.nextMark();
    const entries = try scratch.alloc(Entry, pool.len);
    defer scratch.free(entries);
    for (pool, entries) |v, *e| {
        const root = store.find(v);
        store.setMark(root, young_mark);
        e.* = .{ .v = root, .bucket = @min(store.rank(root), young) };
    }
    // Lowest ranks first. A counting sort by bucket rather than one list per
    // rank: a `let` 200 deep would otherwise allocate 200 lists at every
    // boundary. But a frame nested at demand sits `young` ranks up with a
    // small pool (§10.2), and a count per rank would make a chain of n
    // nested groups cost O(n²): a small pool is sorted instead (stable, as
    // the counting sort is).
    if (young + 2 > 4 * pool.len + 64) {
        std.mem.sort(Entry, entries, {}, bucketLessThan);
        for (entries) |e| _ = try adjustRank(store, stacks, gpa, young_mark, visit_mark, e.bucket, e.v);
        return;
    }
    const counts = try scratch.alloc(u32, young + 2);
    defer scratch.free(counts);
    @memset(counts, 0);
    for (entries) |e| counts[e.bucket + 1] += 1;
    for (1..counts.len) |i| counts[i] += counts[i - 1];
    const sorted = try scratch.alloc(Var, pool.len);
    defer scratch.free(sorted);
    const bucket_of = try scratch.alloc(u32, pool.len);
    defer scratch.free(bucket_of);
    for (entries) |e| {
        sorted[counts[e.bucket]] = e.v;
        bucket_of[counts[e.bucket]] = e.bucket;
        counts[e.bucket] += 1;
    }
    for (sorted, bucket_of) |v, bucket| {
        _ = try adjustRank(store, stacks, gpa, young_mark, visit_mark, bucket, v);
    }
}

/// How a node's rank folds its successors' (Elm's `adjustRankContent`, in
/// v1's exact form): a variable is its group's rank whatever it carries; a
/// function, an alias and a record are the maximum of their successors; an
/// application, a tuple, a unit and `{}` are at least `outermost`.
const Fold = struct { maxes: bool, floor: u32 };

fn foldOf(store: *const TypeStore, root: Var, group_rank: u32) Fold {
    return switch (store.content(root)) {
        .err, .flex, .rigid => .{ .maxes = false, .floor = group_rank },
        .alias => .{ .maxes = true, .floor = 0 },
        .structure => |flat| switch (flat) {
            .unit, .empty_record => .{ .maxes = false, .floor = TypeStore.outermost },
            .func, .record => .{ .maxes = true, .floor = 0 },
            .app, .tuple => .{ .maxes = true, .floor = TypeStore.outermost },
        },
    };
}

const RankFrame = Walk.RankFrame;

/// Elm's `adjustRank` without recursion. A young node is marked `visit`
/// BEFORE its successors are walked, because the graph may be cyclic (a
/// cycle's rank is read mid-walk, as Elm's recursion reads it).
fn adjustRank(
    store: *TypeStore,
    stacks: *Walk.Stacks,
    gpa: Allocator,
    young_mark: u32,
    visit_mark: u32,
    group_rank: u32,
    start: Var,
) Error!u32 {
    const frames = &stacks.ranks;
    frames.clearRetainingCapacity();
    var result: u32 = undefined;
    // `enter` returns the rank at once for a node it does not descend into.
    if (try enter(store, frames, gpa, young_mark, visit_mark, group_rank, start)) |r| return r;
    while (frames.items.len > 0) {
        const top = &frames.items[frames.items.len - 1];
        if (Walk.owned(store, stacks.obligations, top.v, top.cursor)) |c| {
            top.cursor += 1;
            if (try enter(store, frames, gpa, young_mark, visit_mark, group_rank, c)) |r| {
                const parent = &frames.items[frames.items.len - 1];
                if (parent.maxes) parent.max = @max(parent.max, r);
            }
            continue;
        }
        const done = frames.pop().?;
        store.setRank(done.v, done.max);
        result = done.max;
        if (frames.items.len > 0) {
            const parent = &frames.items[frames.items.len - 1];
            if (parent.maxes) parent.max = @max(parent.max, result);
        }
    }
    return result;
}

fn enter(
    store: *TypeStore,
    frames: *std.ArrayList(RankFrame),
    gpa: Allocator,
    young_mark: u32,
    visit_mark: u32,
    group_rank: u32,
    v: Var,
) Error!?u32 {
    const root = store.find(v);
    const rank = store.rank(root);
    const mark = store.mark(root);
    if (mark == young_mark) {
        store.setMark(root, visit_mark);
        const fold = foldOf(store, root, group_rank);
        try frames.append(gpa, .{ .v = root, .cursor = 0, .max = fold.floor, .maxes = fold.maxes });
        return null;
    }
    if (mark == visit_mark) return rank;
    const min_rank = @min(group_rank, rank);
    store.setMark(root, visit_mark);
    store.setRank(root, min_rank);
    return min_rank;
}

/// Step 5 of §8.1: every pool member still at the young rank is quantified;
/// everything below it escaped and joins the pool of the frame at its rank
/// (`frames[rank - 1]`, a frame's rank being its depth). Returns how many
/// were quantified, for the counters. Every quantified variable that still
/// carries obligations is appended to `carriers`, and every quantified flex
/// that carries wanteds to `wanters`, for §8.1 step 7.
pub fn quantify(store: *TypeStore, gpa: Allocator, frames: []Frame, young: u32, carriers: *std.ArrayList(Var), wanters: *std.ArrayList(Var)) Error!u64 {
    const frame = &frames[frames.len - 1];
    var quantified: u64 = 0;
    for (frame.pool.items) |v| {
        if (store.find(v) != v) continue; // merged away: its root is in the pool too
        const rank = store.rank(v);
        if (rank >= young) {
            store.setRank(v, TypeStore.generalized);
            quantified += 1;
            const content = store.content(v);
            switch (content) {
                .flex, .rigid => |flags| {
                    if (flags.obls != .none) try carriers.append(gpa, v);
                    if (content == .flex and !Walk.constraints(flags).isEmpty()) try wanters.append(gpa, v);
                },
                else => {},
            }
            continue;
        }
        // Already quantified (a scheme reached through a merge): nothing to
        // hand down, and no frame of rank 0 exists.
        if (rank == TypeStore.generalized) continue;
        try frames[rank - 1].pool.append(gpa, v);
    }
    frame.pool.clearRetainingCapacity();
    return quantified;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "an inner frame's variable bound to an outer one escapes; its own is quantified" {
    var store: TypeStore = .init(testing.allocator);
    defer store.deinit();
    var stacks: Walk.Stacks = .{};
    defer stacks.deinit(testing.allocator);
    var frames = [_]Frame{ .{ .rank = 1 }, .{ .rank = 2 } };
    defer for (&frames) |*f| f.deinit(testing.allocator);

    const outer = try store.freshFlex(1);
    try frames[0].pool.append(testing.allocator, outer);
    // inner = List outer, own = a fresh variable of the inner frame.
    const args = try store.addVars(&.{outer});
    const inner = try store.fresh(.{ .structure = .{ .app = .{ .type = @enumFromInt(0), .args = args } } }, 2);
    const own = try store.freshFlex(2);
    try frames[1].pool.appendSlice(testing.allocator, &.{ inner, own });

    try adjustRanks(&store, &stacks, testing.allocator, testing.allocator, frames[1].pool.items, 2);
    try testing.expectEqual(@as(u32, 1), store.rank(inner));
    var carriers: std.ArrayList(Var) = .empty;
    defer carriers.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 1), try quantify(&store, testing.allocator, &frames, 2, &carriers, &carriers));
    try testing.expectEqual(TypeStore.generalized, store.rank(own));
    // The escaped structure went down to the outer frame's pool.
    try testing.expectEqual(@as(usize, 2), frames[0].pool.items.len);
}

test "rank adjustment walks a 100 000-deep type without recursion" {
    var store: TypeStore = .init(testing.allocator);
    defer store.deinit();
    var stacks: Walk.Stacks = .{};
    defer stacks.deinit(testing.allocator);
    var pool: std.ArrayList(Var) = .empty;
    defer pool.deinit(testing.allocator);
    const outer = try store.freshFlex(1);
    var v = outer;
    for (0..100_000) |_| {
        const args = try store.addVars(&.{v});
        v = try store.fresh(.{ .structure = .{ .app = .{ .type = @enumFromInt(0), .args = args } } }, 3);
        try pool.append(testing.allocator, v);
    }
    try adjustRanks(&store, &stacks, testing.allocator, testing.allocator, pool.items, 3);
    // Every level holds the outer variable, so none of them is young any more.
    try testing.expectEqual(@as(u32, 1), store.rank(v));
}
