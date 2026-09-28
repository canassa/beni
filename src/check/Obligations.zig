//! Obligations ride on their variables (checker-v2.md §4.5).
//!
//! An obligation is a question about a type that cannot be answered until
//! the type is known: which element a `.0` names (`tuple_index`), whether a
//! `${…}` part can be put into a string (`interpolatable`), whether explicit
//! `Basics.eq`/`neq` may compare it (`equatable`, §11.4), and which shape a
//! `?` has (`try`, §8.6). Each is one row of this table, append-only and
//! index-based, like the wanteds of §4.2.
//!
//! **An open obligation rides on its deciding variables**, through the
//! shared `Flags.obls` field (§4.1): a set here. What the
//! store holds is only that opaque set; the rows and the sets are this
//! file's.
//!
//! - **Readied through its variable.** When a flex that carries one is bound
//!   to anything that is not a flex, every open row of its set goes on the
//!   `ready` queue of the frame it was created under (§9.1, its `frame`). `Unify` does that, and only
//!   that: it decides nothing (§7.1).
//! - **Decided when drained** (`Decide.drain`), in ascending `seq`.
//! - **Closed at quantification** (§8.5, `Decide.close`).
//! - **Carried by escape**: a row on an escaped variable is still attached to
//!   it, and decided by whichever boundary quantifies or binds it.
//!
//! **Every row has an owner, and its dependants never outrank it** (§4.5):
//! a `tuple_index`'s result is lowered to its
//! tuple's rank, a `try`'s subject and value to its target's. The reverse
//! never happens: a `?` target keeps its own success type polymorphic.
//! `Walk.owned` yields a row's dependants from its owner only.
//!
//! **A set is a growable list per variable, mutated in place**: attaching
//! appends, and a merge moves the smaller set's open rows into the larger
//! (union by size). So R rows and M merges cost O(R log R + M) (§4.5's cost
//! claim). Neither rows nor sets are journalled: the checker has no
//! speculation yet (§7.5); the diagnostic probe must journal them, or never
//! merge a set.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const TypeStore = @import("TypeStore.zig");

const Obligations = @This();

pub const Var = TypeStore.Var;
pub const Set = TypeStore.ObligationSet;
pub const Error = Allocator.Error;

pub const Id = enum(u32) {
    _,

    pub fn int(id: Id) u32 {
        return @intFromEnum(id);
    }
};

pub const Kind = enum(u8) {
    /// `e.i`: `vars` = the tuple (the owner), the result.
    tuple_index,
    /// `${e}`: `vars` = the part.
    interpolatable,
    /// The `equatable` marker's question about a variable (§11.4): `vars` =
    /// the variable.
    equatable,
    /// `e?`: `vars` = the subject, the target's result (the owner), the
    /// instruction's value.
    @"try",
};

pub const State = enum(u8) {
    open,
    /// On the queue, not decided yet.
    ready,
    /// Decided, reported, folded or closed: nothing more happens to it.
    done,
};

/// Variable slots per row: the widest kind, `try`, has three.
pub const width = 3;

pub const Row = struct {
    kind: Kind,
    state: State,
    /// The instruction the obligation is about: where it reports.
    region: Bir.Inst.Index,
    /// Module-wide creation order, shared with wanteds (§9.1): the order a
    /// queue is drained in, a function of the source, so declaration order
    /// never changes the result.
    seq: u32,
    /// The `ready` queue of the frame current at creation (§9.1): where a
    /// unification readies it, whichever frame unified.
    frame: u32 = 0,
    /// The deciding variables first, then the results; unused slots repeat
    /// `vars[0]`.
    vars: [width]Var,
    /// `tuple_index`: which element.
    index: u32 = 0,
    /// `equatable`: the row whose question this one continues — itself for
    /// a question asked at a comparison, the asking row for a flag the
    /// marker walk propagated. One question is one message (§11.4).
    origin: Id,
    /// `equatable`, on an origin row: its question has been answered "no",
    /// so no row of the same origin reports again.
    reported: bool = false,

    /// How many of `vars` decide the row: binding one readies it.
    pub fn deciding(r: Row) u32 {
        return switch (r.kind) {
            .tuple_index, .interpolatable, .equatable => 1,
            .@"try" => 2,
        };
    }

    /// The slot of the owner (§4.5).
    pub fn owner(r: Row) u32 {
        return switch (r.kind) {
            .tuple_index, .interpolatable, .equatable => 0,
            .@"try" => 1,
        };
    }

    /// The slots lowered to the owner's rank.
    pub fn dependants(r: Row) []const u2 {
        return switch (r.kind) {
            .tuple_index => &.{1},
            .interpolatable, .equatable => &.{},
            .@"try" => &.{ 0, 2 },
        };
    }
};

const List = std.ArrayList(Id);

/// What rides on one variable: every row it decides (`all`, what binding it
/// readies), and the part of them it owns (`owned`, what `Walk.owned` yields
/// dependants from). Kept apart so a variable that decides many rows it does
/// not own — the subject of many `?` — is not walked through them.
const SetData = struct {
    all: List = .empty,
    owned: List = .empty,

    fn deinit(d: *SetData, gpa: Allocator) void {
        d.all.deinit(gpa);
        d.owned.deinit(gpa);
    }
};

rows: std.ArrayList(Row) = .empty,
sets: std.ArrayList(SetData) = .empty,
seq: u32 = 0,
/// The queue of the current frame (`Generalize.Frame.queue`): what a row and
/// a wanted created now route to (§9.1). `Solve` keeps it with its frames.
current_queue: u32 = no_queue,

/// `current_queue` when no frame is open: nothing may be created then.
pub const no_queue = std.math.maxInt(u32);

pub fn deinit(o: *Obligations, gpa: Allocator) void {
    o.rows.deinit(gpa);
    for (o.sets.items) |*s| s.deinit(gpa);
    o.sets.deinit(gpa);
}

pub fn row(o: *const Obligations, id: Id) Row {
    return o.rows.items[id.int()];
}

pub fn rowPtr(o: *Obligations, id: Id) *Row {
    return &o.rows.items[id.int()];
}

/// A new open row. `vars` holds the deciding variables first; missing slots
/// are filled with the first. `origin` is the row's own id when null.
pub fn create(o: *Obligations, gpa: Allocator, kind: Kind, region: Bir.Inst.Index, vars: []const Var, index: u32, origin: ?Id) Error!Id {
    std.debug.assert(o.current_queue != no_queue);
    std.debug.assert(vars.len >= 1 and vars.len <= width);
    var slots: [width]Var = .{ vars[0], vars[0], vars[0] };
    for (vars, 0..) |v, i| slots[i] = v;
    const id: Id = @enumFromInt(o.rows.items.len);
    try o.rows.append(gpa, .{
        .kind = kind,
        .state = .open,
        .region = region,
        .seq = o.seq,
        .frame = o.current_queue,
        .vars = slots,
        .index = index,
        .origin = origin orelse id,
    });
    o.seq += 1;
    return id;
}

/// A merged frame's hand-down (§9.1 *Merges*): every row made since `start`
/// that routes to queue `from` routes to `to`.
pub fn repoint(o: *Obligations, start: u32, from: u32, to: u32) void {
    for (o.rows.items[start..]) |*r| {
        if (r.frame == from) r.frame = to;
    }
}

/// The rows a set holds, open or not.
pub fn members(o: *const Obligations, set: Set) []const Id {
    if (set == .none) return &.{};
    return o.sets.items[@intFromEnum(set)].all.items;
}

/// The rows of a set whose owner is the variable that carries it.
pub fn owned(o: *const Obligations, set: Set) []const Id {
    if (set == .none) return &.{};
    return o.sets.items[@intFromEnum(set)].owned.items;
}

/// The first open `equatable` row of `set`, if it has one.
pub fn openEquatable(o: *const Obligations, set: Set) ?Id {
    for (o.owned(set)) |id| {
        const r = o.row(id);
        if (r.kind == .equatable and r.state == .open) return id;
    }
    return null;
}

/// `set` with `id` appended, in place (to `owned` too when the variable
/// owns the row); a new set when `set` is `.none`.
pub fn with(o: *Obligations, gpa: Allocator, set: Set, id: Id, owner: bool) Error!Set {
    const at: Set = if (set != .none) set else blk: {
        const fresh: Set = @enumFromInt(o.sets.items.len);
        try o.sets.append(gpa, .{});
        break :blk fresh;
    };
    const d = &o.sets.items[@intFromEnum(at)];
    try d.all.append(gpa, id);
    if (owner) try d.owned.append(gpa, id);
    return at;
}

/// The union of two sets, for a merge of the two variables that carry them:
/// the smaller set's open rows are moved into the larger, in place, and the
/// larger is returned (union by size); the smaller is emptied.
pub fn merged(o: *Obligations, gpa: Allocator, a: Set, b: Set) Error!Set {
    if (b == .none or a == b) return a;
    if (a == .none) return b;
    const da = &o.sets.items[@intFromEnum(a)];
    const db = &o.sets.items[@intFromEnum(b)];
    const big, const small, const kept = if (da.all.items.len >= db.all.items.len) .{ da, db, a } else .{ db, da, b };
    for (small.all.items) |id| {
        if (o.row(id).state == .open) try big.all.append(gpa, id);
    }
    for (small.owned.items) |id| {
        if (o.row(id).state == .open) try big.owned.append(gpa, id);
    }
    small.all.clearRetainingCapacity();
    small.owned.clearRetainingCapacity();
    return kept;
}

/// Move every open row of `set` to `queue` (§4.5: readied through its
/// variable). A row already on a queue, or done, stays where it is.
pub fn ready(o: *Obligations, gpa: Allocator, set: Set, queue: *std.ArrayList(u32)) Error!void {
    for (o.members(set)) |id| {
        const r = o.rowPtr(id);
        if (r.state != .open) continue;
        r.state = .ready;
        try queue.append(gpa, id.int());
    }
}

/// The `n`th `owned` successor a set contributes to the variable `self`
/// (§4.5): a row's dependants, from its owner only. `width` slots per row,
/// so the lookup is O(1); a slot with no dependant, a row that is not open,
/// or a row `self` does not own, yields `self` — a node every `owned` walk
/// has already visited. Null past the end.
pub fn successor(o: *const Obligations, store: *TypeStore, set: Set, self: Var, n: u32) ?Var {
    const ids = o.owned(set);
    const i = n / width;
    if (i >= ids.len) return null;
    const r = o.row(ids[i]);
    if (r.state != .open) return self;
    // A row the variable owned may have moved to a merge's survivor, whose
    // own set now holds it: this one is stale.
    if (store.find(r.vars[r.owner()]) != self) return self;
    const deps = r.dependants();
    const slot = n % width;
    return if (slot < deps.len) r.vars[deps[slot]] else self;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a merge moves the smaller set's open rows into the larger, in place" {
    var o: Obligations = .{ .current_queue = 0 };
    defer o.deinit(testing.allocator);
    const x: Var = @enumFromInt(1);
    const y: Var = @enumFromInt(2);
    const r: Var = @enumFromInt(3);
    const a = try o.create(testing.allocator, .tuple_index, @enumFromInt(0), &.{ x, r }, 0, null);
    const b = try o.create(testing.allocator, .interpolatable, @enumFromInt(0), &.{y}, 0, null);
    const c = try o.create(testing.allocator, .interpolatable, @enumFromInt(0), &.{y}, 0, null);
    const sa = try o.with(testing.allocator, .none, a, true);
    var sb = try o.with(testing.allocator, .none, b, true);
    sb = try o.with(testing.allocator, sb, c, true);
    const both = try o.merged(testing.allocator, sa, sb);
    try testing.expectEqual(sb, both);
    try testing.expectEqual(@as(usize, 3), o.members(both).len);
    try testing.expectEqual(@as(usize, 0), o.members(sa).len);

    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(testing.allocator);
    try o.ready(testing.allocator, both, &queue);
    try testing.expectEqual(@as(usize, 3), queue.items.len);
    try testing.expectEqual(Obligations.State.ready, o.row(a).state);
}
