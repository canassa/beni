//! L0 of the ownership checker v2 (`docs/design/ownership-v2.md` §3, §4.1,
//! §4.4, §5): every id newtype the layers above share, and the constant-record
//! primitives §4.1's accounting proof is written over.
//!
//! **Ids.** Every table is indexed by an `enum(u32)` with `.none = maxInt`
//! (`fast-compiler.md` §5 rules 1 and 5); none of them is ever a hash key
//! (`src/rules_test.zig`).
//!
//! **The account** (§4.1, §4.4). Every retained record of an owning
//! declaration is classified BEFORE it is allocated: it either consumes a
//! baseline lane — a slot attached to one original source or import atom and
//! one fixed role, with a fixed ceiling (32 direct records, 512 for an index
//! or routine kernel) — or it reserves growth against the owner's allowance,
//! `ownership_summary_size`, 65 536 by default. Growth that cannot be
//! reserved is the terminal `ownership_limit`; a lane that overflows is the
//! compiler defect `ownership_accounting_invariant`. Neither is ever repaired
//! by spilling into the other, refunding, or dropping work (O11). The
//! account lives from the first allocation through validation and encoding
//! (§3.9) and counts B_f, G_f, S_f and N_f = B_f + G_f per category.
//!
//! **Records** are fixed-size, at most 16 words (`max_record_words`);
//! `assertRecord` is the one check and every table in `own2/` makes it.
//! Variable-length runs are chains of `Chunks`, each chunk reserved before it
//! is filled.
//!
//! **The persistent set** of §4.1 is `Cell.Radix` (L2), the one table that
//! holds cells; it is built on the same account.
//!
//! **The fixed-key dictionary** (`FixedDict`) is a mutable patricia tree over
//! `[k]u32` keys: deterministic, O(32·k) comparisons per lookup, no hashing,
//! the "owner-local comparison tree" every intern table and memo of §3 is.
//!
//! **The queue** (`Tasks`) is one-shot: a task is enqueued at most once and
//! executes at most once (§4.1), its links in its own record.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const none_int: u32 = std.math.maxInt(u32);

/// The largest record any `own2/` table holds, in `u32` words (§4.1).
pub const max_record_words: u32 = 16;

/// Every `MultiArrayList` element type in `own2/` is asserted with this,
/// so a record that grows past §4.1's bound is a compile error.
pub fn assertRecord(comptime T: type) void {
    if (@sizeOf(T) > max_record_words * 4) @compileError("an own2 record exceeds 16 words: " ++ @typeName(T));
}

fn IdType(comptime Self: type) type {
    return struct {
        pub inline fn int(i: Self) u32 {
            return @backingInt(i);
        }
        pub inline fn from(i: u32) Self {
            return @fromBackingInt(i);
        }
        pub inline fn unwrap(i: Self) ?Self {
            return if (i == .none) null else i;
        }
    };
}

// Each id is spelled out — never made by a generic — so `rules_test`'s
// lint (`= enum(u32)`) sees every one of them as a dense id.

pub const PlaceId = enum(u32) {
    none = none_int,
    _,
    const Mixin = IdType(PlaceId);
    pub const int = Mixin.int;
    pub const from = Mixin.from;
    pub const unwrap = Mixin.unwrap;
};
pub const PathId = enum(u32) {
    none = none_int,
    _,
    const Mixin = IdType(PathId);
    pub const int = Mixin.int;
    pub const from = Mixin.from;
    pub const unwrap = Mixin.unwrap;
};
pub const CellId = enum(u32) {
    none = none_int,
    _,
    const Mixin = IdType(CellId);
    pub const int = Mixin.int;
    pub const from = Mixin.from;
    pub const unwrap = Mixin.unwrap;
};
pub const LabelId = enum(u32) {
    none = none_int,
    _,
    const Mixin = IdType(LabelId);
    pub const int = Mixin.int;
    pub const from = Mixin.from;
    pub const unwrap = Mixin.unwrap;
};
/// A node of a persistent set; a set is named by its root.
pub const SetId = enum(u32) {
    none = none_int,
    _,
    const Mixin = IdType(SetId);
    pub const int = Mixin.int;
    pub const from = Mixin.from;
    pub const unwrap = Mixin.unwrap;
};
pub const NodeId = enum(u32) {
    none = none_int,
    _,
    const Mixin = IdType(NodeId);
    pub const int = Mixin.int;
    pub const from = Mixin.from;
    pub const unwrap = Mixin.unwrap;
};
pub const OverId = enum(u32) {
    none = none_int,
    _,
    const Mixin = IdType(OverId);
    pub const int = Mixin.int;
    pub const from = Mixin.from;
    pub const unwrap = Mixin.unwrap;
};
pub const CondId = enum(u32) {
    none = none_int,
    _,
    const Mixin = IdType(CondId);
    pub const int = Mixin.int;
    pub const from = Mixin.from;
    pub const unwrap = Mixin.unwrap;
};
pub const SplitId = enum(u32) {
    none = none_int,
    _,
    const Mixin = IdType(SplitId);
    pub const int = Mixin.int;
    pub const from = Mixin.from;
    pub const unwrap = Mixin.unwrap;
};
pub const ClassId = enum(u32) {
    none = none_int,
    _,
    const Mixin = IdType(ClassId);
    pub const int = Mixin.int;
    pub const from = Mixin.from;
    pub const unwrap = Mixin.unwrap;
};
pub const UseId = enum(u32) {
    none = none_int,
    _,
    const Mixin = IdType(UseId);
    pub const int = Mixin.int;
    pub const from = Mixin.from;
    pub const unwrap = Mixin.unwrap;
};
pub const DemandId = enum(u32) {
    none = none_int,
    _,
    const Mixin = IdType(DemandId);
    pub const int = Mixin.int;
    pub const from = Mixin.from;
    pub const unwrap = Mixin.unwrap;
};
pub const RegionId = enum(u32) {
    none = none_int,
    _,
    const Mixin = IdType(RegionId);
    pub const int = Mixin.int;
    pub const from = Mixin.from;
    pub const unwrap = Mixin.unwrap;
};
pub const SummaryAccountId = enum(u32) {
    none = none_int,
    _,
    const Mixin = IdType(SummaryAccountId);
    pub const int = Mixin.int;
    pub const from = Mixin.from;
    pub const unwrap = Mixin.unwrap;
};
pub const TaskId = enum(u32) {
    none = none_int,
    _,
    const Mixin = IdType(TaskId);
    pub const int = Mixin.int;
    pub const from = Mixin.from;
    pub const unwrap = Mixin.unwrap;
};
pub const ChunkId = enum(u32) {
    none = none_int,
    _,
    const Mixin = IdType(ChunkId);
    pub const int = Mixin.int;
    pub const from = Mixin.from;
    pub const unwrap = Mixin.unwrap;
};

/// A half-open run of a sidecar table.
pub const Range = struct {
    start: u32 = 0,
    len: u32 = 0,

    pub const empty: Range = .{};
};

// ---------------------------------------------------------------------------
// The account (§4.1, §4.4)
// ---------------------------------------------------------------------------

/// What a reservation is for: instrumentation only (§4.4's category
/// counts); never a reason to charge differently.
pub const Category = enum(u8) {
    cell,
    label,
    set,
    shape,
    cond,
    use,
    demand,
    class,
    context,
    memo,
    task,
    edge,
    path,
    region,
    chunk,
    other,

    pub const count = @typeInfo(Category).@"enum".field_names.len;
};

/// A baseline lane's role (§4.1's two tables). The ceiling is the role's.
pub const Role = enum(u8) {
    /// ≤ 32 constant-size records per original atom.
    direct_data,
    cell_index,
    shape_index,
    cond_index,
    reach_index,
    liveness_index,
    holder_index,
    escape_index,
    codec_index,
    direct_demand_query,
    call_view,
    transfer_settlement,
    entry_delta,

    pub fn ceiling(r: Role) u32 {
        return if (r == .direct_data) 32 else 512;
    }
};

/// The two copies of the source lanes: the initial walk and the one final
/// validation (§4.1, *final source validation*).
pub const Phase = enum(u8) { inference, validation };

/// One baseline lane: an original atom, a role, a phase.
pub const Lane = struct { atom: u32, role: Role, phase: Phase = .inference };

/// A reservation refused, with what refused it (§6's two messages).
pub const Failure = union(enum) {
    /// `ownership_limit`: the growth record that would have been
    /// `allowance + 1`, by category.
    exhausted: Category,
    /// `ownership_accounting_invariant`: a lane past its ceiling.
    invariant: Lane,
};

pub const AccountError = error{ OwnershipLimit, AccountingInvariant };

/// The account of one owning declaration (§4.4): its nested lambdas, local
/// functions and entry work share it, and so does its final validation.
pub const Account = struct {
    /// R_f: the growth allowance, by default `default_allowance`, raised by
    /// the attribute (§4.4).
    allowance: u32 = default_allowance,
    /// G_f.
    growth: u32 = 0,
    /// B_f: every baseline record ever reserved.
    baseline: u32 = 0,
    /// S_f: the written and imported atoms, recorded by the owner's walk.
    source: u32 = 0,
    growth_by: [Category.count]u32 = @splat(0),
    baseline_by: [Category.count]u32 = @splat(0),
    /// Set by the first refusal and never cleared: the exhaustion marker of
    /// §4.4, which makes every later reservation fail at once.
    failed: ?Failure = null,
    lanes: FixedDict(3) = .{},

    pub const default_allowance: u32 = 65_536;

    pub fn deinit(a: *Account, gpa: Allocator) void {
        a.lanes.deinit(gpa);
    }

    /// N_f.
    pub fn total(a: *const Account) u64 {
        return @as(u64, a.baseline) + a.growth;
    }

    /// Reserve `n` growth records before doing the work they stand for.
    pub fn reserve(a: *Account, category: Category, n: u32) error{OwnershipLimit}!void {
        if (a.failed != null) return error.OwnershipLimit;
        const next = @as(u64, a.growth) + n;
        if (next > a.allowance) {
            a.failed = .{ .exhausted = category };
            return error.OwnershipLimit;
        }
        a.growth = @intCast(next);
        a.growth_by[@backingInt(category)] += n;
    }

    /// Reserve `n` baseline records in `lane`. The ceiling is the role's;
    /// the 513th (or 33rd) record is the implementation defect
    /// `ownership_accounting_invariant`, never growth (§4.1).
    pub fn reserveLane(a: *Account, gpa: Allocator, lane: Lane, category: Category, n: u32) (Allocator.Error || AccountError)!void {
        if (a.failed) |f| return switch (f) {
            .exhausted => error.OwnershipLimit,
            .invariant => error.AccountingInvariant,
        };
        const slot = try a.lanes.getOrPut(gpa, .{ lane.atom, @backingInt(lane.role), @backingInt(lane.phase) });
        if (!slot.found_existing) slot.value_ptr.* = 0;
        const next = @as(u64, slot.value_ptr.*) + n;
        if (next > lane.role.ceiling()) {
            a.failed = .{ .invariant = lane };
            return error.AccountingInvariant;
        }
        slot.value_ptr.* = @intCast(next);
        a.baseline += n;
        a.baseline_by[@backingInt(category)] += n;
    }

    /// How many records `lane` has used.
    pub fn laneUsed(a: *const Account, lane: Lane) u32 {
        return a.lanes.get(.{ lane.atom, @backingInt(lane.role), @backingInt(lane.phase) }) orelse 0;
    }
};

// ---------------------------------------------------------------------------
// Chunks: variable-length runs as fixed-size records (§4.1)
// ---------------------------------------------------------------------------

/// One chunk of a run: `words_per_chunk` words and a link. Exactly 16 words.
pub const Chunk = struct {
    next: ChunkId,
    len: u32,
    words: [words_per_chunk]u32,
};
pub const words_per_chunk = 14;

/// Runs of `u32` as chains of chunks. A run is `(first chunk, count)`;
/// appending reserves the chunk it opens, in `category`, before writing.
pub const Chunks = struct {
    table: std.MultiArrayList(Chunk) = .empty,

    pub const Run = struct {
        first: ChunkId = .none,
        last: ChunkId = .none,
        count: u32 = 0,
    };

    pub fn deinit(c: *Chunks, gpa: Allocator) void {
        c.table.deinit(gpa);
    }

    /// Append one word to `run`, opening a chunk (one growth record) when
    /// the last is full.
    pub fn append(c: *Chunks, gpa: Allocator, account: *Account, category: Category, run: *Run, word: u32) (Allocator.Error || error{OwnershipLimit})!void {
        if (run.last == .none or c.table.items(.len)[run.last.int()] == words_per_chunk) {
            try account.reserve(category, 1);
            const id: ChunkId = .from(@intCast(c.table.len));
            try c.table.append(gpa, .{ .next = .none, .len = 0, .words = undefined });
            if (run.last == .none) run.first = id else c.table.items(.next)[run.last.int()] = id;
            run.last = id;
        }
        const i = run.last.int();
        const len = &c.table.items(.len)[i];
        c.table.items(.words)[i][len.*] = word;
        len.* += 1;
        run.count += 1;
    }

    pub const Iterator = struct {
        chunks: *const Chunks,
        at: ChunkId,
        i: u32 = 0,

        pub fn next(it: *Iterator) ?u32 {
            while (it.at != .none) {
                const k = it.at.int();
                if (it.i < it.chunks.table.items(.len)[k]) {
                    const w = it.chunks.table.items(.words)[k][it.i];
                    it.i += 1;
                    return w;
                }
                it.at = it.chunks.table.items(.next)[k];
                it.i = 0;
            }
            return null;
        }
    };

    pub fn iterate(c: *const Chunks, run: Run) Iterator {
        return .{ .chunks = c, .at = run.first };
    }
};

// ---------------------------------------------------------------------------
// The fixed-key dictionary: a mutable patricia tree over [k]u32 keys (§4.1)
// ---------------------------------------------------------------------------

/// Deterministic, hash-free, O(32k) per lookup: a crit-bit tree whose
/// inner node names the first bit two keys differ at. Keys are the words
/// `keys[k·i ..]`; `values[i]` is leaf `i`'s value.
pub fn FixedDict(comptime k: usize) type {
    return struct {
        /// `crit`: the critical bit's position (0 is the most significant
        /// bit of word 0), or `leaf_crit` for a leaf whose `left` is the
        /// key/value index.
        nodes: std.MultiArrayList(Node) = .empty,
        keys: std.ArrayList(u32) = .empty,
        values: std.ArrayList(u32) = .empty,
        root: u32 = none_int,

        const Self = @This();
        pub const Key = [k]u32;
        const Node = struct { crit: u32, left: u32, right: u32 };
        const leaf_crit: u32 = none_int;

        comptime {
            assertRecord(Node);
        }

        pub const GetOrPut = struct { found_existing: bool, value_ptr: *u32, index: u32 };

        pub fn deinit(d: *Self, gpa: Allocator) void {
            d.nodes.deinit(gpa);
            d.keys.deinit(gpa);
            d.values.deinit(gpa);
        }

        pub fn count(d: *const Self) u32 {
            return @intCast(d.values.items.len);
        }

        inline fn bitOf(key: Key, crit: u32) u1 {
            return @intCast((key[crit / 32] >> @intCast(31 - crit % 32)) & 1);
        }

        fn keyAt(d: *const Self, leaf: u32) Key {
            return d.keys.items[leaf * k ..][0..k].*;
        }

        /// The leaf a lookup of `key` lands on, or none for an empty tree.
        fn descend(d: *const Self, key: Key) u32 {
            var at = d.root;
            if (at == none_int) return none_int;
            const crits = d.nodes.items(.crit);
            const lefts = d.nodes.items(.left);
            const rights = d.nodes.items(.right);
            while (crits[at] != leaf_crit) at = if (bitOf(key, crits[at]) == 0) lefts[at] else rights[at];
            return lefts[at];
        }

        pub fn get(d: *const Self, key: Key) ?u32 {
            const leaf = d.descend(key);
            if (leaf == none_int or !std.mem.eql(u32, &d.keyAt(leaf), &key)) return null;
            return d.values.items[leaf];
        }

        pub fn getOrPut(d: *Self, gpa: Allocator, key: Key) Allocator.Error!GetOrPut {
            const leaf = d.descend(key);
            if (leaf != none_int and std.mem.eql(u32, &d.keyAt(leaf), &key)) {
                return .{ .found_existing = true, .value_ptr = &d.values.items[leaf], .index = leaf };
            }
            const new_leaf: u32 = @intCast(d.values.items.len);
            try d.keys.appendSlice(gpa, &key);
            try d.values.append(gpa, undefined);
            try d.nodes.ensureUnusedCapacity(gpa, 2);
            const leaf_node: u32 = @intCast(d.nodes.len);
            d.nodes.appendAssumeCapacity(.{ .crit = leaf_crit, .left = new_leaf, .right = none_int });
            if (leaf == none_int) {
                d.root = leaf_node;
                return .{ .found_existing = false, .value_ptr = &d.values.items[new_leaf], .index = new_leaf };
            }
            // The first differing bit against the leaf found decides where
            // the new branch goes: above the first inner node whose
            // critical bit is deeper than it.
            const other = d.keyAt(leaf);
            var crit: u32 = 0;
            while (crit / 32 < k and bitOf(other, crit) == bitOf(key, crit)) crit += 1;
            const crits = d.nodes.items(.crit);
            const lefts = d.nodes.items(.left);
            const rights = d.nodes.items(.right);
            var parent: u32 = none_int;
            var at = d.root;
            while (crits[at] != leaf_crit and crits[at] < crit) {
                parent = at;
                at = if (bitOf(key, crits[at]) == 0) lefts[at] else rights[at];
            }
            const branch: u32 = @intCast(d.nodes.len);
            const new_bit = bitOf(key, crit);
            d.nodes.appendAssumeCapacity(.{
                .crit = crit,
                .left = if (new_bit == 0) leaf_node else at,
                .right = if (new_bit == 0) at else leaf_node,
            });
            if (parent == none_int) {
                d.root = branch;
            } else if (d.nodes.items(.left)[parent] == at) {
                d.nodes.items(.left)[parent] = branch;
            } else {
                d.nodes.items(.right)[parent] = branch;
            }
            return .{ .found_existing = false, .value_ptr = &d.values.items[new_leaf], .index = new_leaf };
        }
    };
}

// ---------------------------------------------------------------------------
// One-shot tasks (§4.1)
// ---------------------------------------------------------------------------

pub const TaskState = enum(u8) { fresh, queued, done };

/// A task record: its kind and four payload words are the caller's; the
/// state and queue link are the queue's. Reserved before creation.
pub const Task = struct {
    kind: u8,
    state: TaskState,
    next: TaskId,
    a: u32,
    b: u32,
    c: u32,
    d: u32,
};

pub const Tasks = struct {
    table: std.MultiArrayList(Task) = .empty,
    head: TaskId = .none,
    tail: TaskId = .none,
    /// Instrumentation (§7.6): tasks executed, i.e. dequeued.
    executed: u32 = 0,

    pub fn deinit(t: *Tasks, gpa: Allocator) void {
        t.table.deinit(gpa);
    }

    /// A new task, one growth record, not yet queued.
    pub fn add(t: *Tasks, gpa: Allocator, account: *Account, kind: u8, payload: [4]u32) (Allocator.Error || error{OwnershipLimit})!TaskId {
        try account.reserve(.task, 1);
        const id: TaskId = .from(@intCast(t.table.len));
        try t.table.append(gpa, .{ .kind = kind, .state = .fresh, .next = .none, .a = payload[0], .b = payload[1], .c = payload[2], .d = payload[3] });
        return id;
    }

    /// Queue `id` unless it was queued or has run: at most once per task.
    pub fn enqueueOnce(t: *Tasks, id: TaskId) void {
        const states = t.table.items(.state);
        if (states[id.int()] != .fresh) return;
        states[id.int()] = .queued;
        if (t.tail == .none) t.head = id else t.table.items(.next)[t.tail.int()] = id;
        t.tail = id;
    }

    /// The next task to run, marked done as it leaves the queue.
    pub fn dequeue(t: *Tasks) ?TaskId {
        const id = t.head.unwrap() orelse return null;
        t.head = t.table.items(.next)[id.int()];
        if (t.head == .none) t.tail = .none;
        t.table.items(.state)[id.int()] = .done;
        t.executed += 1;
        return id;
    }

    pub fn get(t: *const Tasks, id: TaskId) Task {
        return t.table.get(id.int());
    }
};

comptime {
    assertRecord(Chunk);

    assertRecord(Task);
    std.debug.assert(@sizeOf(Chunk) == 64);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "growth is reserved before work and the allowance is terminal" {
    var a: Account = .{ .allowance = 3 };
    defer a.deinit(testing.allocator);
    try a.reserve(.cell, 2);
    try testing.expectError(error.OwnershipLimit, a.reserve(.set, 2));
    try testing.expectEqual(@as(u32, 2), a.growth);
    try testing.expect(a.failed != null and a.failed.? == .exhausted and a.failed.?.exhausted == .set);
    // Terminal: a reservation that would have fit no longer does.
    try testing.expectError(error.OwnershipLimit, a.reserve(.cell, 1));
    try testing.expectEqual(@as(u64, 2), a.total());
}

test "a baseline lane is per atom and role, and overflow is the invariant, never growth" {
    var a: Account = .{ .allowance = 0 };
    defer a.deinit(testing.allocator);
    const direct: Lane = .{ .atom = 7, .role = .direct_data };
    try a.reserveLane(testing.allocator, direct, .cell, 32);
    try testing.expectEqual(@as(u32, 32), a.laneUsed(direct));
    // Another atom and another role have their own ceilings.
    try a.reserveLane(testing.allocator, .{ .atom = 8, .role = .direct_data }, .cell, 1);
    try a.reserveLane(testing.allocator, .{ .atom = 7, .role = .cell_index }, .set, 512);
    try a.reserveLane(testing.allocator, .{ .atom = 7, .role = .cell_index, .phase = .validation }, .set, 1);
    try testing.expectError(error.AccountingInvariant, a.reserveLane(testing.allocator, direct, .cell, 1));
    try testing.expectEqual(@as(u32, 0), a.growth);
    try testing.expectEqual(@as(u32, 546), a.baseline);
    try testing.expect(a.failed.? == .invariant);
    try testing.expectError(error.AccountingInvariant, a.reserveLane(testing.allocator, .{ .atom = 9, .role = .direct_data }, .cell, 1));
}

test "the fixed-key dictionary finds composite keys without hashing" {
    var d: FixedDict(3) = .{};
    defer d.deinit(testing.allocator);
    const gpa = testing.allocator;
    const keys = [_][3]u32{ .{ 1, 2, 3 }, .{ 1, 2, 4 }, .{ 0, 0, 0 }, .{ 0xFFFF_FFFF, 0, 0 }, .{ 1, 3, 3 }, .{ 1, 2, 3 } };
    for (keys, 0..) |key, i| {
        const got = try d.getOrPut(gpa, key);
        if (i == 5) {
            try testing.expect(got.found_existing);
            try testing.expectEqual(@as(u32, 100), got.value_ptr.*);
        } else {
            try testing.expect(!got.found_existing);
            got.value_ptr.* = @intCast(100 + i);
        }
    }
    try testing.expectEqual(@as(u32, 5), d.count());
    try testing.expectEqual(@as(?u32, 101), d.get(.{ 1, 2, 4 }));
    try testing.expectEqual(@as(?u32, 102), d.get(.{ 0, 0, 0 }));
    try testing.expectEqual(@as(?u32, 103), d.get(.{ 0xFFFF_FFFF, 0, 0 }));
    try testing.expectEqual(@as(?u32, 104), d.get(.{ 1, 3, 3 }));
    try testing.expectEqual(@as(?u32, null), d.get(.{ 1, 2, 5 }));
    try testing.expectEqual(@as(?u32, null), d.get(.{ 2, 2, 3 }));
    // Many keys, every one found again.
    var k: u32 = 0;
    while (k < 2000) : (k += 1) {
        const got = try d.getOrPut(gpa, .{ k *% 2654435761, k + 10, k >> 3 });
        try testing.expect(!got.found_existing);
        got.value_ptr.* = k;
    }
    k = 0;
    while (k < 2000) : (k += 1) try testing.expectEqual(@as(?u32, k), d.get(.{ k *% 2654435761, k + 10, k >> 3 }));
}

test "chunks reserve each chunk before filling it and read back in order" {
    var c: Chunks = .{};
    defer c.deinit(testing.allocator);
    var a: Account = .{ .allowance = 2 };
    defer a.deinit(testing.allocator);
    var run: Chunks.Run = .{};
    var i: u32 = 0;
    while (i < 2 * words_per_chunk) : (i += 1) try c.append(testing.allocator, &a, .chunk, &run, i * 7);
    try testing.expectError(error.OwnershipLimit, c.append(testing.allocator, &a, .chunk, &run, 1));
    try testing.expectEqual(@as(u32, 2 * words_per_chunk), run.count);
    var it = c.iterate(run);
    i = 0;
    while (it.next()) |w| : (i += 1) try testing.expectEqual(i * 7, w);
    try testing.expectEqual(@as(u32, 2 * words_per_chunk), i);
}

test "a task is queued once and runs once" {
    var t: Tasks = .{};
    defer t.deinit(testing.allocator);
    var a: Account = .{};
    defer a.deinit(testing.allocator);
    const x = try t.add(testing.allocator, &a, 1, .{ 1, 2, 3, 4 });
    const y = try t.add(testing.allocator, &a, 2, .{ 0, 0, 0, 0 });
    t.enqueueOnce(x);
    t.enqueueOnce(y);
    t.enqueueOnce(x);
    try testing.expectEqual(x, t.dequeue().?);
    t.enqueueOnce(x);
    try testing.expectEqual(y, t.dequeue().?);
    try testing.expectEqual(@as(?TaskId, null), t.dequeue());
    try testing.expectEqual(@as(u32, 2), t.executed);
    try testing.expectEqual(TaskState.done, t.get(x).state);
    try testing.expectEqual(@as(u32, 2), a.growth);
}
