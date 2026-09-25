//! Frames, rank adjustment and quantification (checker-v2.md §8.1, §8.4).
//!
//! Elm's `generalize` with pools per rank, as v1 has it, except that:
//!
//!   - the rank walk is ITERATIVE and has no depth guard (I4): v1's
//!     `adjustRank` recursed and, past its guard, answered with the
//!     variable's own rank, silently;
//!   - it takes its successors from `Walk.child(…, .owned)` (I2), so a
//!     variable's requirements are adjusted with it once R5/R6a attach any;
//!   - a frame is explicit (§7.5, §8.1, S-2): its rank, its young pool, the
//!     binders its occurs check starts from and its `ready` queue, which is
//!     empty until R6a resolves anything. It keeps no `touched` list: §18's
//!     measurement put the walk over it at 4 % of the check phase, so R4b
//!     took §18's fallback, Elm's placement (binders only).
//!
//! The boundary's other steps — occurs (4) and the generality check (6) —
//! report, so they are `Solve.zig`'s; this file is the part that only moves
//! ranks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Walk = @import("Walk.zig");

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

/// A boundary (§8.1): a top-level group or a `let` group.
pub const Frame = struct {
    rank: u32,
    /// The young pool: every variable made at `rank` while this frame was
    /// current, by the generator or the solver.
    pool: std.ArrayList(Var) = .empty,
    /// Wanteds and obligations readied onto this frame (§9.1). Nothing is
    /// ever queued in R4b: the queue is drained, empty, at step 1.
    ready: std.ArrayList(u32) = .empty,
    /// The module capture list's length when the frame was pushed.
    captures_start: u32 = 0,

    pub fn deinit(f: *Frame, gpa: Allocator) void {
        f.pool.deinit(gpa);
        f.ready.deinit(gpa);
    }
};

/// Where a variable of one young root sits while ranks are adjusted.
const Entry = struct { v: Var, bucket: u32 };

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
    // A counting sort by bucket rather than one list per rank: a `let`
    // 200 deep would otherwise allocate 200 lists at every boundary.
    const entries = try scratch.alloc(Entry, pool.len);
    defer scratch.free(entries);
    const counts = try scratch.alloc(u32, young + 2);
    defer scratch.free(counts);
    @memset(counts, 0);
    for (pool, entries) |v, *e| {
        const root = store.find(v);
        store.setMark(root, young_mark);
        e.* = .{ .v = root, .bucket = @min(store.rank(root), young) };
        counts[e.bucket + 1] += 1;
    }
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
        if (Walk.child(store, top.v, top.cursor, .owned)) |c| {
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
/// were quantified, for the counters.
pub fn quantify(store: *TypeStore, gpa: Allocator, frames: []Frame, young: u32) Error!u64 {
    const frame = &frames[frames.len - 1];
    var quantified: u64 = 0;
    for (frame.pool.items) |v| {
        if (store.find(v) != v) continue; // merged away: its root is in the pool too
        const rank = store.rank(v);
        if (rank >= young) {
            store.setRank(v, TypeStore.generalized);
            quantified += 1;
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
    try testing.expectEqual(@as(u64, 1), try quantify(&store, testing.allocator, &frames, 2));
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
