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
//!
//! Obligations kept here: O11 (no bound accepts: a reservation is refused
//! before the work it stands for, and a refusal is terminal).

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
    };
}

// Each id is spelled out — never made by a generic — so `rules_test`'s
// lint (`= enum(u32)`) sees every one of them as a dense id.

pub const PlaceId = enum(u32) {
    none = none_int,
    _,
    pub const int = IdType(@This()).int;
    pub const from = IdType(@This()).from;
};
pub const PathId = enum(u32) {
    none = none_int,
    _,
    pub const int = IdType(@This()).int;
    pub const from = IdType(@This()).from;
};
pub const CellId = enum(u32) {
    none = none_int,
    _,
    pub const int = IdType(@This()).int;
    pub const from = IdType(@This()).from;
};
pub const LabelId = enum(u32) {
    none = none_int,
    _,
    pub const int = IdType(@This()).int;
    pub const from = IdType(@This()).from;
};
/// A node of a persistent set; a set is named by its root.
pub const SetId = enum(u32) {
    none = none_int,
    _,
    pub const int = IdType(@This()).int;
    pub const from = IdType(@This()).from;
};
pub const NodeId = enum(u32) {
    none = none_int,
    _,
    pub const int = IdType(@This()).int;
    pub const from = IdType(@This()).from;
};
pub const OverId = enum(u32) {
    none = none_int,
    _,
    pub const int = IdType(@This()).int;
    pub const from = IdType(@This()).from;
};
pub const CondId = enum(u32) {
    none = none_int,
    _,
    pub const int = IdType(@This()).int;
    pub const from = IdType(@This()).from;
};
pub const SplitId = enum(u32) {
    none = none_int,
    _,
    pub const int = IdType(@This()).int;
    pub const from = IdType(@This()).from;
};
pub const ClassId = enum(u32) {
    none = none_int,
    _,
    pub const int = IdType(@This()).int;
    pub const from = IdType(@This()).from;
};
pub const UseId = enum(u32) {
    none = none_int,
    _,
    pub const int = IdType(@This()).int;
    pub const from = IdType(@This()).from;
};
pub const DemandId = enum(u32) {
    none = none_int,
    _,
    pub const int = IdType(@This()).int;
    pub const from = IdType(@This()).from;
};
pub const RegionId = enum(u32) {
    none = none_int,
    _,
    pub const int = IdType(@This()).int;
    pub const from = IdType(@This()).from;
};
/// The root of an immutable κ snapshot: a persistent map `NodeId → CondId`
/// a holder owns (§2.9, §3.4); `.none` is the empty snapshot.
pub const KappaId = enum(u32) {
    none = none_int,
    _,
    pub const int = IdType(@This()).int;
    pub const from = IdType(@This()).from;
};
pub const SummaryAccountId = enum(u32) {
    none = none_int,
    _,
    pub const int = IdType(@This()).int;
    pub const from = IdType(@This()).from;
};
pub const TaskId = enum(u32) {
    none = none_int,
    _,
    pub const int = IdType(@This()).int;
    pub const from = IdType(@This()).from;
};
pub const ChunkId = enum(u32) {
    none = none_int,
    _,
    pub const int = IdType(@This()).int;
    pub const from = IdType(@This()).from;
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
    inspection,
    other,
    pub const count = @typeInfo(Category).@"enum".field_names.len;
};

/// A baseline lane's role (§4.1's two tables). The ceiling is the role's.
pub const Role = enum(u8) {
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

    /// ≤ 32 constant-size records per original atom for `direct_data`, 512 for every index or routine kernel.
    pub fn ceiling(r: Role) u32 {
        return if (r == .direct_data) 32 else 512;
    }
};

/// The two copies of the source lanes: the initial walk and the one final
/// validation (§4.1, *final source validation*).
pub const Phase = enum(u8) { inference, validation };

/// One baseline lane: an original atom, a role, a phase. An atom is a
/// source identity unique in the owning declaration: an instruction, a use's
/// operand occurrence, a region id, or a canonical path node marked with
/// `atom_path_bit` so it never meets an instruction in one role.
/// `step`: within one atom's role, the step of a path it walks, for a kernel
/// §4.4 counts per step (*holder and callee path words*: `(written demand,
/// slot, k)`); 0 for every other kernel (#1225).
pub const Lane = struct { atom: u32, role: Role, phase: Phase = .inference, step: u32 = 0 };

/// The atom kinds beside an instruction, each its own bit so no two share a
/// role's counter: a canonical path node (a `PathId`), a local (a binding,
/// a pattern variable), a region (its settlement slots).
pub const atom_path_bit: u32 = 1 << 31;
pub const atom_local_bit: u32 = 1 << 30;
pub const atom_region_bit: u32 = 1 << 29;

/// §4.4's input and format limits, each its own named `ownership_limit`.
pub const Limit = enum(u8) {
    /// `step_payload` is a step past 28 bits: nothing written reaches it under the limits above, so it is the format's.
    record_fields,
    tuple_arity,
    constructor_args,
    type_places,
    path_steps,
    declaration_insts,
    block_bytes,
    step_payload,
    ctor_steps,

    pub fn value(l: Limit) u64 {
        return switch (l) {
            .record_fields, .tuple_arity, .constructor_args, .path_steps => 65_536,
            .type_places => 1 << 24,
            .declaration_insts, .block_bytes => 1 << 31,
            .step_payload, .ctor_steps => 1 << 28,
        };
    }
};

/// A reservation refused, with what refused it (§6's two messages).
pub const Failure = union(enum) {
    /// `ownership_limit`: the growth record that would have been
    /// `allowance + 1`, by category.
    exhausted: Category,
    /// `ownership_limit` for an input or format limit (§4.4's table).
    limit: Limit,
    /// `ownership_accounting_invariant`: a lane past its ceiling.
    invariant: Lane,

    /// The error a failed account keeps answering with: an invariant never
    /// reads as a limit a raise would fix.
    pub fn err(f: Failure) AccountError {
        return switch (f) {
            .exhausted, .limit => error.OwnershipLimit,
            .invariant => error.AccountingInvariant,
        };
    }
};

pub const AccountError = error{ OwnershipLimit, AccountingInvariant };
/// What every charged operation can fail with.
pub const ChargeError = Allocator.Error || AccountError;

/// The account of one owning declaration (§4.4): its nested lambdas, local
/// functions and entry work share it, and so does its final validation.
pub const Account = struct {
    /// R_f: the growth allowance, by default `default_allowance`, raised by
    /// the attribute (§4.4).
    allowance: u32 = default_allowance,
    /// G_f.
    growth: u32 = 0,
    /// B_f: every baseline record ever reserved. 64 bits: §4.4 lets it
    /// reach 11 328·S_f (the lanes' 10 304, and the source continuation's
    /// 1 024 per written instruction).
    baseline: u64 = 0,
    /// I_f (§4.1): the declaration's written instructions only, never its
    /// imports, set before its walk. The source continuation is K times it.
    source: u64 = 0,
    /// The source continuation spent (§4.1, *The source continuation*):
    /// records that would have been growth, taken from the declaration's
    /// `continuation_per_atom`·I_f instead, and counted in B_f.
    continuation: u64 = 0,
    growth_by: [Category.count]u32 = @splat(0),
    baseline_by: [Category.count]u64 = @splat(0),
    /// Set by the first refusal and never cleared: the exhaustion marker of
    /// §4.4, which makes every later reservation fail at once.
    failed: ?Failure = null,
    lanes: FixedDict(4) = .{},
    /// The kernel the walk is in (§4.1), `lanes`' slot of `lane` or growth
    /// (`none_int`): where a reservation naming no lane goes (`enter`).
    lane_slot: u32 = none_int,
    lane: Lane = .{ .atom = 0, .role = .direct_data },

    pub const default_allowance: u32 = 65_536;
    /// K (§4.1, *The source continuation*): the records each source atom
    /// lends its declaration's work beyond the lanes. A huge, named bound,
    /// an order of magnitude past every measurement, never tuned; it adds at
    /// most 1 024·I_f to B_f (§4.4's 11 328·S_f).
    pub const continuation_per_atom: u64 = 1024;

    /// K·I_f, what the source continuation may lend in all.
    pub fn continuationCap(a: *const Account) u64 {
        return continuation_per_atom * a.source;
    }

    pub fn deinit(a: *Account, gpa: Allocator) void {
        a.lanes.deinit(gpa);
    }

    /// N_f.
    pub fn total(a: *const Account) u64 {
        return a.baseline + a.growth;
    }

    /// The kernel `enter` left, to `leave` back to.
    pub const Kernel = struct { slot: u32, lane: Lane };

    /// Run the next reservations in `lane` (null: growth) until `leave`.
    /// The slot is made here, so a reservation never allocates.
    pub fn enter(a: *Account, gpa: Allocator, lane: ?Lane) ChargeError!Kernel {
        const prev: Kernel = .{ .slot = a.lane_slot, .lane = a.lane };
        if (a.failed) |f| return f.err();
        const l = lane orelse {
            a.lane_slot = none_int;
            return prev;
        };
        const got = try a.lanes.getOrPut(gpa, .{ l.atom, @backingInt(l.role), @backingInt(l.phase), l.step });
        if (!got.found_existing) got.value_ptr.* = 0;
        a.lane_slot = got.index;
        a.lane = l;
        return prev;
    }

    /// Whether the kernel the walk is in is growth (no lane).
    pub fn inGrowth(a: *const Account) bool {
        return a.lane_slot == none_int;
    }

    pub fn leave(a: *Account, k: Kernel) void {
        a.lane_slot = k.slot;
        a.lane = k.lane;
    }

    /// Reserve `n` records in the kernel `enter` named, or growth.
    pub fn reserve(a: *Account, category: Category, n: u32) AccountError!void {
        if (a.lane_slot == none_int) return a.reserveGrowth(category, n);
        if (a.failed) |f| return f.err();
        const slot = &a.lanes.values.items[a.lane_slot];
        const next = @as(u64, slot.*) + n;
        if (next > a.lane.role.ceiling()) {
            a.failed = .{ .invariant = a.lane };
            return error.AccountingInvariant;
        }
        slot.* = @intCast(next);
        a.baseline += n;
        a.baseline_by[@backingInt(category)] += n;
    }

    /// Reserve `n` growth records first: a product, a general task.
    pub fn reserveGrowth(a: *Account, category: Category, n: u32) AccountError!void {
        if (a.failed) |f| return f.err();
        // The source continuation first, whole or not at all, decided at
        // this reservation before its work: only what passes K·I_f is growth.
        if (a.continuation + n <= a.continuationCap()) {
            a.continuation += n;
            a.baseline += n;
            a.baseline_by[@backingInt(category)] += n;
            return;
        }
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
    pub fn reserveLane(a: *Account, gpa: Allocator, lane: Lane, category: Category, n: u32) ChargeError!void {
        if (a.failed) |f| return f.err();
        const slot = try a.lanes.getOrPut(gpa, .{ lane.atom, @backingInt(lane.role), @backingInt(lane.phase), lane.step });
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

    /// One call for the caller's classification: a baseline lane when the
    /// record has one (§4.1's tables), growth otherwise.
    pub fn charge(a: *Account, gpa: Allocator, lane: ?Lane, category: Category, n: u32) ChargeError!void {
        if (lane) |l| return a.reserveLane(gpa, l, category, n);
        return a.reserve(category, n);
    }

    /// Check an input against its named limit (§4.4): `count` past it is
    /// the terminal `ownership_limit` naming the limit.
    pub fn limit(a: *Account, which: Limit, count: u64) AccountError!void {
        return a.limitOver(which, count, which.value());
    }

    /// `limit` against `max` instead of the limit's own value: what a table
    /// with configurable limits (a test's) calls.
    pub fn limitOver(a: *Account, which: Limit, count: u64, max: u64) AccountError!void {
        if (a.failed) |f| return f.err();
        if (count > max) {
            a.failed = .{ .limit = which };
            return error.OwnershipLimit;
        }
    }

    /// How many records `lane` has used.
    pub fn laneUsed(a: *const Account, lane: Lane) u32 {
        return a.lanes.get(.{ lane.atom, @backingInt(lane.role), @backingInt(lane.phase), lane.step }) orelse 0;
    }
};

/// Where an operation's records go: an account, and the baseline lane they
/// belong to or growth. Chosen by the caller BEFORE the operation (§4.1,
/// §4.4: "classify every record before allocation"); the primitives below
/// take one and never choose for themselves.
pub const Charge = struct {
    account: *Account,
    lane: ?Lane = null,

    pub fn growth(account: *Account) Charge {
        return .{ .account = account };
    }

    pub fn in(account: *Account, lane: Lane) Charge {
        return .{ .account = account, .lane = lane };
    }

    pub fn reserve(c: Charge, gpa: Allocator, category: Category, n: u32) ChargeError!void {
        return c.account.charge(gpa, c.lane, category, n);
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

    /// Append one word to `run`, opening a chunk (one record in `charge`) when
    /// the last is full.
    pub fn append(c: *Chunks, gpa: Allocator, charge: Charge, category: Category, run: *Run, word: u32) ChargeError!void {
        if (run.last == .none or c.table.items(.len)[run.last.int()] == words_per_chunk) {
            try charge.reserve(gpa, category, 1);
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

        /// Empty, the room kept.
        pub fn clearRetainingCapacity(d: *Self) void {
            d.nodes.clearRetainingCapacity();
            d.keys.clearRetainingCapacity();
            d.values.clearRetainingCapacity();
            d.root = none_int;
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

    /// A new task, one record in `charge`, not yet queued.
    pub fn add(t: *Tasks, gpa: Allocator, charge: Charge, kind: u8, payload: [4]u32) ChargeError!TaskId {
        try charge.reserve(gpa, .task, 1);
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
        if (t.head == .none) return null;
        const id = t.head;
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
    while (i < 2 * words_per_chunk) : (i += 1) try c.append(testing.allocator, .growth(&a), .chunk, &run, i * 7);
    try testing.expectError(error.OwnershipLimit, c.append(testing.allocator, .growth(&a), .chunk, &run, 1));
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
    const x = try t.add(testing.allocator, .growth(&a), 1, .{ 1, 2, 3, 4 });
    const y = try t.add(testing.allocator, .growth(&a), 2, .{ 0, 0, 0, 0 });
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

test "a primitive charges the lane it is given, and growth only when it is given none" {
    var c: Chunks = .{};
    defer c.deinit(testing.allocator);
    var a: Account = .{ .allowance = 0 };
    defer a.deinit(testing.allocator);
    const lane: Lane = .{ .atom = 3, .role = .direct_data };
    var run: Chunks.Run = .{};
    // Source-sized work in its lane spends no growth (§4.4).
    var i: u32 = 0;
    while (i < 3 * words_per_chunk) : (i += 1) try c.append(testing.allocator, .in(&a, lane), .chunk, &run, i);
    try testing.expectEqual(@as(u32, 0), a.growth);
    try testing.expectEqual(@as(u32, 3), a.laneUsed(lane));
    try testing.expectEqual(@as(u64, 3), a.baseline);
    var t: Tasks = .{};
    defer t.deinit(testing.allocator);
    _ = try t.add(testing.allocator, .in(&a, lane), 1, .{ 0, 0, 0, 0 });
    try testing.expectEqual(@as(u32, 4), a.laneUsed(lane));
    // With no lane the same call is growth, and this account has none.
    try testing.expectError(error.OwnershipLimit, t.add(testing.allocator, .growth(&a), 1, .{ 0, 0, 0, 0 }));
}

test "an invariant failure keeps reading as the invariant, and the baseline does not wrap" {
    var a: Account = .{ .baseline = std.math.maxInt(u32) };
    defer a.deinit(testing.allocator);
    const lane: Lane = .{ .atom = 1, .role = .direct_data };
    try a.reserveLane(testing.allocator, lane, .cell, 32);
    try testing.expectEqual(@as(u64, std.math.maxInt(u32)) + 32, a.baseline);
    try testing.expectError(error.AccountingInvariant, a.reserveLane(testing.allocator, lane, .cell, 1));
    // Never a limit a raise would appear to fix.
    try testing.expectError(error.AccountingInvariant, a.reserve(.cell, 1));
    try testing.expectError(error.AccountingInvariant, a.limit(.type_places, 1));
    try testing.expectError(error.AccountingInvariant, a.charge(testing.allocator, null, .cell, 1));
}

test "an input limit is named, terminal and checked before work" {
    var a: Account = .{};
    defer a.deinit(testing.allocator);
    try a.limit(.record_fields, 65_536);
    try testing.expectError(error.OwnershipLimit, a.limit(.record_fields, 65_537));
    try testing.expectEqual(Limit.record_fields, a.failed.?.limit);
    try testing.expectError(error.OwnershipLimit, a.reserve(.cell, 1));
    try testing.expectEqual(@as(u32, 0), a.growth);
}
