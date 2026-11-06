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
//! `assertRecord` is the one check and every table in `own2/` makes it,
//! through `Columns`, which holds each table with its columns hoisted.
//!
//! **The fixed-key dictionary** is `Index`: open addressing over entry
//! indices with a fixed hash and linear probing, never iterated, an expected
//! O(1) probes per operation at a load factor of at most 1/2, and a probe
//! past `probe_length` is the named `ownership_limit` (§4.1). `FixedDict`
//! keeps its keys in its own dense columns; `Interned` reads them from the
//! records of an intern table, which stores each key once.
//!
//! Obligations kept here: O11 (no bound accepts: a reservation is refused
//! before the work it stands for, and a refusal is terminal).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Counters = @import("Counters.zig");

pub const none_int: u32 = std.math.maxInt(u32);

/// The largest record any `own2/` table holds, in `u32` words (§4.1).
pub const max_record_words: u32 = 16;

/// Every `MultiArrayList` element type in `own2/` is asserted with this,
/// so a record that grows past §4.1's bound is a compile error.
pub fn assertRecord(comptime T: type) void {
    if (@sizeOf(T) > max_record_words * 4) @compileError("an own2 record exceeds 16 words: " ++ @typeName(T));
}

// ---------------------------------------------------------------------------
// Columns: a table's MultiArrayList with its columns hoisted (§4.1)
// ---------------------------------------------------------------------------

/// A table of `T` records, stored as a `std.MultiArrayList(T)`, whose
/// columns are read and written through `col`: one plain slice per field of
/// `T`, over the list's storage. `MultiArrayList.items` and `get` recompute
/// every column's address per call, and where the code generator does not
/// fold that away — Zig's own backend, which builds the compiler the test
/// suites run — it cost about 100 ns a read and a third of the checker's
/// cycles (`check/TypeStore.zig`'s `col` met the same wall).
///
/// `list` is never changed but through this type: the one method that moves
/// the storage (`ensureTotalCapacity`) re-reads `col`, and every one that
/// changes its length cuts or extends `col` to match, so `col` itself is
/// never stale. A slice copied out of it is: a local `const xs = t.col.f`
/// held across a call that may append to the same table can point at freed
/// storage, so read `t.col.f` again after any such call. `rules_test`
/// keeps every other `own2/` file off `MultiArrayList`, `items` and `list`.
pub fn Columns(comptime T: type) type {
    assertRecord(T);
    const names = @typeInfo(T).@"struct".field_names;
    return struct {
        const Self = @This();
        const List = std.MultiArrayList(T);

        /// One slice per field of `T`, named as the field.
        pub const Col = blk: {
            var types: [names.len]type = undefined;
            for (names, &types) |n, *ty| ty.* = []@FieldType(T, n);
            break :blk @Struct(.auto, null, names, &types, &@splat(.{}));
        };

        const no_col: Col = blk: {
            var c: Col = undefined;
            for (names) |n| @field(c, n) = &.{};
            break :blk c;
        };

        /// The storage. Changed only by the methods below, which keep `col`
        /// its columns.
        list: List = .empty,
        col: Col = no_col,

        pub const empty: Self = .{};

        pub fn deinit(s: *Self, gpa: Allocator) void {
            s.list.deinit(gpa);
            s.* = undefined;
        }

        pub inline fn len(s: *const Self) usize {
            return s.list.len;
        }

        /// Re-read `col` after `list` moved.
        fn sync(s: *Self) void {
            const sl = s.list.slice();
            inline for (names) |n| @field(s.col, n) = sl.items(@field(List.Field, n));
        }

        /// The one place the storage moves, and so the one place `col` is
        /// re-read; safety builds check it was in step before.
        pub fn ensureTotalCapacity(s: *Self, gpa: Allocator, n: usize) Allocator.Error!void {
            if (std.debug.runtime_safety) s.assertSynced();
            try s.list.ensureTotalCapacity(gpa, n);
            s.sync();
        }

        pub fn ensureUnusedCapacity(s: *Self, gpa: Allocator, n: usize) Allocator.Error!void {
            return s.ensureTotalCapacity(gpa, s.list.len + n);
        }

        /// Append `elem`: the capacity test inline, the growth and the
        /// re-read of `col` it needs out of line.
        pub inline fn append(s: *Self, gpa: Allocator, elem: T) Allocator.Error!void {
            if (s.list.len == s.list.capacity) try s.ensureUnusedCapacity(gpa, 1);
            s.appendAssumeCapacity(elem);
        }

        /// Written column by column through `col`: the list's own
        /// `appendAssumeCapacity` would recompute every column's address.
        pub inline fn appendAssumeCapacity(s: *Self, elem: T) void {
            std.debug.assert(s.list.len < s.list.capacity);
            const i = s.list.len;
            s.list.len = i + 1;
            inline for (names) |n| {
                const c = &@field(s.col, n);
                c.* = c.ptr[0 .. i + 1];
                c.*[i] = @field(elem, n);
            }
        }

        pub inline fn get(s: *const Self, i: usize) T {
            var r: T = undefined;
            inline for (names) |n| @field(r, n) = @field(s.col, n)[i];
            return r;
        }

        pub inline fn set(s: *Self, i: usize, elem: T) void {
            inline for (names) |n| @field(s.col, n)[i] = @field(elem, n);
        }

        /// The storage stays where it is: `col` is cut, not re-read.
        pub fn shrinkRetainingCapacity(s: *Self, n: usize) void {
            std.debug.assert(n <= s.list.len);
            s.list.len = n;
            inline for (names) |f| {
                const c = &@field(s.col, f);
                c.* = c.ptr[0..n];
            }
        }

        pub fn clearRetainingCapacity(s: *Self) void {
            s.shrinkRetainingCapacity(0);
        }

        /// `col` is exactly the list's columns (the tests' check).
        pub fn assertSynced(s: *const Self) void {
            const sl = s.list.slice();
            inline for (names) |n| {
                const want = sl.items(@field(List.Field, n));
                const got = @field(s.col, n);
                std.debug.assert(got.len == want.len and (want.len == 0 or got.ptr == want.ptr));
            }
        }
    };
}

// ---------------------------------------------------------------------------
// IdColumn: a memo or attribute keyed by one dense id (§4.1)
// ---------------------------------------------------------------------------

/// A map from one dense id `K` (an id newtype or a `u32` index) to a `u32`,
/// as a column indexed by the id: one load and a compare per lookup, where a
/// `FixedDict(1)` hashes the id and probes. It holds memory in proportion to
/// the highest id it has stored, never iterates, and is never cleared: a
/// slot is absent until written.
///
/// A column is used one of two ways, never both:
/// - plain (`get`, `getOrPut`, `put`): a slot, once written, stays;
/// - by epoch (`getAt`, `getOrPutAt`): a slot holds the epoch it was written
///   at, and reads as absent at any other — a memo valid while a counter
///   (`Shape.Table.ties`, `base_epoch`) stands still, emptied by moving it.
pub fn IdColumn(comptime K: type) type {
    return struct {
        slots: std.ArrayList(Slot) = .empty,
        stats: Counters.Col = Counters.zero(Counters.Col),

        const Self = @This();
        pub const Key = K;
        pub const counter_kind = Counters.Kind.column;
        /// `tag`: `absent`, `present` for a plain column, or the epoch the
        /// value was written at.
        const Slot = struct { tag: u32, value: u32 };
        const absent: u32 = none_int;
        const present: u32 = 0;

        comptime {
            assertRecord(Slot);
        }

        pub const GetOrPut = struct { found_existing: bool, value_ptr: *u32 };

        pub fn deinit(c: *Self, gpa: Allocator) void {
            c.slots.deinit(gpa);
        }

        inline fn index(k: K) usize {
            return switch (@typeInfo(K)) {
                .@"enum" => @backingInt(k),
                else => k,
            };
        }

        pub inline fn get(c: *const Self, k: K) ?u32 {
            return c.getAt(k, present);
        }

        pub inline fn contains(c: *const Self, k: K) bool {
            return c.get(k) != null;
        }

        /// The value written at `epoch`, or null.
        pub inline fn getAt(c: *const Self, k: K, epoch: u32) ?u32 {
            const i = index(k);
            const hit = i < c.slots.items.len and c.slots.items[i].tag == epoch;
            Counters.colRead(&c.stats, hit);
            return if (hit) c.slots.items[i].value else null;
        }

        pub fn getOrPut(c: *Self, gpa: Allocator, k: K) Allocator.Error!GetOrPut {
            return c.getOrPutAt(gpa, k, present);
        }

        pub fn put(c: *Self, gpa: Allocator, k: K, value: u32) Allocator.Error!void {
            (try c.getOrPut(gpa, k)).value_ptr.* = value;
        }

        /// The slot of `k` at `epoch`: found when it was written at `epoch`,
        /// otherwise now taken for it, its value the caller's to write.
        pub fn getOrPutAt(c: *Self, gpa: Allocator, k: K, epoch: u32) Allocator.Error!GetOrPut {
            std.debug.assert(epoch != absent);
            const i = index(k);
            // An id, never `none`: a column grows to the id it is given.
            std.debug.assert(i != none_int);
            if (i >= c.slots.items.len) try c.slots.appendNTimes(gpa, .{ .tag = absent, .value = 0 }, i + 1 - c.slots.items.len);
            const s = &c.slots.items[i];
            const found = s.tag == epoch;
            Counters.colWrite(&c.stats, s.tag == absent);
            s.tag = epoch;
            return .{ .found_existing = found, .value_ptr = &s.value };
        }
    };
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
pub const CondId = enum(u32) {
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
    /// The longest displacement of a key in a dictionary's index (§4.1): what
    /// an adversarial key set meets, loudly.
    probe_length,

    pub fn value(l: Limit) u64 {
        return switch (l) {
            .record_fields, .tuple_arity, .constructor_args, .path_steps => 65_536,
            .type_places => 1 << 24,
            .declaration_insts, .block_bytes => 1 << 31,
            .step_payload, .ctor_steps => 1 << 28,
            .probe_length => 1024,
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

/// The module tables whose entries an account pays on its own first read
/// (§4.1, *A module table's entries*).
pub const ModuleTable = enum(u8) {
    extend,
    folds_up,
    hits,
    rel_of,
    rel_walk,
    below,
    anchors,
    below_all,
    import,
    worded,
    pub const count = @typeInfo(ModuleTable).@"enum".field_names.len;
};

/// A module table's fill costs by its entries' dense ids (§4.1, *A module
/// table's entries*), beside the table's own column.
pub const Costs = struct {
    items: std.ArrayList(u64) = .empty,

    pub fn deinit(c: *Costs, gpa: Allocator) void {
        c.items.deinit(gpa);
    }
    pub fn get(c: *const Costs, id: u32) u64 {
        return if (id < c.items.items.len) c.items.items[id] else 0;
    }
    pub fn put(c: *Costs, gpa: Allocator, id: u32, cost: u64) Allocator.Error!void {
        if (id >= c.items.items.len) try c.items.appendNTimes(gpa, 0, id + 1 - c.items.items.len);
        c.items.items[id] = cost;
    }
};

/// `ProbeLength` is a dictionary's `probe_length`, raised where no account is
/// at hand; the walk that catches it names it (`Account.probeFailed`).
pub const AccountError = error{ OwnershipLimit, AccountingInvariant, ProbeLength };
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
    /// The records reserved while `in_demands`: Demands' resolve, which the
    /// counted tests of §2.11 *κ across a call* leave out of a call's share
    /// (#1214's). A condition resolved inside it is the call's and is not.
    demands: u64 = 0,
    in_demands: bool = false,
    /// Holder covers that fell back to listing their holds (`Holders`, a
    /// folded path): printed, so a fallback is never silent (#1214).
    hold_listings: u32 = 0,
    baseline_by: [Category.count]u64 = @splat(0),
    /// Set by the first refusal and never cleared: the exhaustion marker of
    /// §4.4, which makes every later reservation fail at once.
    failed: ?Failure = null,
    lanes: FixedDict(4) = .{},
    /// The kernel the walk is in (§4.1), `lanes`' slot of `lane` or growth
    /// (`none_int`): where a reservation naming no lane goes (`enter`).
    lane_slot: u32 = none_int,
    lane: Lane = .{ .atom = 0, .role = .direct_data },
    /// Which copy of the source lanes a walk takes (§4.1): a recursive
    /// group member's second walk the validation one, any later walk none,
    /// its lanes growth (§8 S3b slice 4, *Charging*).
    walk: enum(u8) { inference, validation, growth } = .inference,
    /// §4.1, *A module table's entries*: per table, the entries this
    /// account has read outside a fill, one bit per dense id. Each such
    /// first read paid the entry's fill cost.
    firsts: [ModuleTable.count]std.DynamicBitSetUnmanaged = @splat(.{}),
    /// The fills open (nested), the records the innermost one has counted,
    /// and what every open one has counted: a fill counts its records
    /// instead of reserving them, and the reader of the entry pays them.
    fill_depth: u32 = 0,
    fill_count: u64 = 0,
    fill_sum: u64 = 0,
    /// What a `⟲` stands for, as this declaration has read it: `(Walked, path)`
    /// → a run of `walk_runs`, or a set for `.canon`. State of its walk, never
    /// read by another declaration, and never by a fill, whose cost is a fact of its entry.
    walks: FixedDict(2) = .{},
    /// A replay's steps as a trie: `(run or none, from, step)` → a run of `walk_runs`.
    replays: FixedDict(3) = .{},
    walk_runs: std.ArrayList([2]u32) = .empty,
    walked: std.ArrayList(u32) = .empty,

    pub const Walked = enum(u32) { past_fold, levels, level_step, expanded, canon };

    /// The run of `path` under `w`, if this declaration has read it.
    pub fn walkedRun(a: *const Account, w: Walked, path: u32) ?[]const u32 {
        if (a.filling()) return null;
        const i = a.walks.get(.{ @backingInt(w), path }) orelse return null;
        const r = a.walk_runs.items[i];
        return a.walked.items[r[0]..][0..r[1]];
    }

    /// Keep `run` as `path`'s under `w`.
    pub fn keepRun(a: *Account, gpa: Allocator, w: Walked, path: u32, run: []const u32) IndexError!void {
        if (a.filling()) return;
        const start: u32 = @intCast(a.walked.items.len);
        try a.walked.appendSlice(gpa, run);
        try a.walks.put(gpa, .{ @backingInt(w), path }, @intCast(a.walk_runs.items.len));
        try a.walk_runs.append(gpa, .{ start, @intCast(run.len) });
    }

    /// The run of `run`, as `walk_runs` holds it.
    pub fn runAt(a: *const Account, run: u32) []const u32 {
        const r = a.walk_runs.items[run];
        return a.walked.items[r[0]..][0..r[1]];
    }

    /// Keep `cur` as the step `(run, from, word)`'s, and give its run.
    pub fn keepStep(a: *Account, gpa: Allocator, run: u32, from: u32, word: u32, cur: []const u32) IndexError!u32 {
        const start: u32 = @intCast(a.walked.items.len);
        try a.walked.appendSlice(gpa, cur);
        const id: u32 = @intCast(a.walk_runs.items.len);
        try a.walk_runs.append(gpa, .{ start, @intCast(cur.len) });
        try a.replays.put(gpa, .{ run, from, word }, id);
        return id;
    }

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
        a.dropFirsts(gpa);
    }

    /// Forget the first reads (`firsts`): once the declaration is checked,
    /// nothing of it reads a module table again.
    pub fn dropFirsts(a: *Account, gpa: Allocator) void {
        for (&a.firsts) |*b| b.deinit(gpa);
        a.walks.deinit(gpa);
        a.replays.deinit(gpa);
        a.walk_runs.deinit(gpa);
        a.walked.deinit(gpa);
        a.walks = .{};
        a.replays = .{};
        a.walk_runs = .empty;
        a.walked = .empty;
    }

    /// An open fill of a module table's entry (§4.1, *A module table's
    /// entries*): the count of the fill around it.
    pub const Fill = struct { saved: u64 };

    /// Open a fill: until `endFill`, every reservation is counted, not made.
    pub fn beginFill(a: *Account) Fill {
        a.fill_depth += 1;
        const f: Fill = .{ .saved = a.fill_count };
        a.fill_count = 0;
        return f;
    }

    /// Close a fill: its cost, the records it counted. The caller stores
    /// it with the entry and then reads the entry (`readEntry`).
    pub fn endFill(a: *Account, f: Fill) u64 {
        const c = a.fill_count;
        a.fill_count = f.saved;
        a.fill_depth -= 1;
        a.fill_sum -= c;
        return c;
    }

    /// Whether a fill is open: a read now is the fill's.
    pub fn filling(a: *const Account) bool {
        return a.fill_depth != 0;
    }

    /// Count `n` records in the open fill, against what the account has
    /// left: the reader pays them whole, from the continuation or growth,
    /// so a count that fits in neither stops the fill now (§4.4).
    fn countFill(a: *Account, category: Category, n: u64) AccountError!void {
        if (a.failed) |f| return f.err();
        a.fill_count += n;
        a.fill_sum += n;
        const room = @max(a.continuationCap() -| a.continuation, @as(u64, a.allowance) -| a.growth);
        if (a.fill_sum > room) {
            a.failed = .{ .exhausted = category };
            return error.OwnershipLimit;
        }
    }

    /// Read entry `id` of module table `table`, whose fill cost is
    /// `cost`: inside a fill, the fill counts the cost; else the account
    /// pays it on its own first read of the entry and never again.
    pub fn readEntry(a: *Account, gpa: Allocator, table: ModuleTable, id: u32, cost: u64) ChargeError!void {
        if (a.failed) |f| return f.err();
        if (a.fill_depth != 0) return a.countFill(.memo, cost);
        const bits = &a.firsts[@backingInt(table)];
        if (id >= bits.bit_length) try bits.resize(gpa, @max(id + 1, 2 * bits.bit_length), false);
        if (bits.isSet(id)) return;
        bits.set(id);
        if (cost == 0) return;
        if (cost > std.math.maxInt(u32)) {
            a.failed = .{ .exhausted = .memo };
            return error.OwnershipLimit;
        }
        return a.reserve(.memo, @intCast(cost));
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
        var l = lane orelse {
            a.lane_slot = none_int;
            return prev;
        };
        if (a.walk == .growth) {
            a.lane_slot = none_int;
            return prev;
        }
        if (a.walk == .validation) l.phase = .validation;
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
        if (a.fill_depth != 0) return a.countFill(category, n);
        if (a.in_demands) a.demands += n;
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
        if (a.fill_depth != 0) return a.countFill(category, n);
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
    pub fn reserveLane(a: *Account, gpa: Allocator, lane_: Lane, category: Category, n: u32) ChargeError!void {
        if (a.fill_depth != 0) return a.countFill(category, n);
        if (a.in_demands) a.demands += n;
        if (a.walk == .growth) return a.reserveGrowth(category, n);
        var lane = lane_;
        if (a.walk == .validation) lane.phase = .validation;
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

    /// A dictionary refused a probe past `probe_length` (§4.4), which has no
    /// account to mark: this owner's failure names it, unless it has one.
    pub fn probeFailed(a: *Account) ?Failure {
        if (a.failed == null) a.failed = .{ .limit = .probe_length };
        return a.failed;
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
// The fixed-key dictionary: open addressing over entry indices (§4.1)
// ---------------------------------------------------------------------------

/// What an insertion into an `Index` fails with besides memory: a probe
/// longer than `probe_length` (§4.1, §4.4). The index has no account, so the
/// walk that meets it names the limit (`Account.probeFailed`).
pub const IndexError = Allocator.Error || error{ProbeLength};

/// `probe_length` (§4.4): the longest displacement an `Index` takes.
pub const probe_length: u32 = @intCast(Limit.probe_length.value());

/// The fixed hash of a key (§4.1): each word folded in by xor, a multiply by
/// ⌊2⁶⁴/φ⌋ and an xor-shift, from a fixed seed. It reads nothing but the key,
/// so where a key lands never depends on the run (§3.8).
pub inline fn hashKey(comptime k: usize, key: [k]u32) u64 {
    var h: u64 = 0x243f6a8885a308d3;
    inline for (0..k) |j| {
        h = (h ^ key[j]) *% 0x9e3779b97f4a7c15;
        h ^= h >> 29;
    }
    return h ^ (h >> 32);
}

/// An open-addressing index of entry indices, the shape of Zig's
/// `InternPool` maps: a slot holds `(generation, entry)` and nothing else,
/// and the keys stay in the caller's dense columns, read through `ctx`
/// (`ctx.keyAt(entry)`). Its entries are `0 .. len`, numbered in the order
/// they were inserted. Nothing iterates the slots but `grow`.
///
/// - Linear probing from the key's hash; the load factor stays at most 1/2
///   (the slots double, at least 16, before an insertion would pass it).
/// - `reach` is the longest displacement of an entry, so a lookup probes at
///   most `reach + 1` slots. An insertion whose displacement would pass
///   `probe_length` is refused with `error.ProbeLength` before it writes: an
///   adversarial key set is loud, never slow (§4.1). A rehash that passes it
///   completes, so the index stays correct, then refuses.
/// - `clear` is one increment of the generation: a slot of another
///   generation is empty.
pub const Index = struct {
    slots: std.ArrayList([2]u32) = .empty,
    gen: u32 = 1,
    len: u32 = 0,
    reach: u32 = 0,

    pub fn deinit(ix: *Index, gpa: Allocator) void {
        ix.slots.deinit(gpa);
    }

    pub fn clear(ix: *Index) void {
        ix.len = 0;
        ix.reach = 0;
        ix.gen +%= 1;
        if (ix.gen != 0) return;
        for (ix.slots.items) |*x| x[0] = 0;
        ix.gen = 1;
    }

    inline fn home(ix: *const Index, comptime k: usize, key: [k]u32) u32 {
        return @as(u32, @truncate(hashKey(k, key))) & @as(u32, @intCast(ix.slots.items.len - 1));
    }

    /// The entry holding `key`, or null; `steps` counts the slots read.
    pub fn find(ix: *const Index, comptime k: usize, key: [k]u32, ctx: anytype, steps: *Counters.Steps) ?u32 {
        if (ix.len == 0) return null;
        const mask: u32 = @intCast(ix.slots.items.len - 1);
        var at = ix.home(k, key);
        var d: u32 = 0;
        while (d <= ix.reach) : (d += 1) {
            steps.inc();
            const x = ix.slots.items[at];
            if (x[0] != ix.gen) return null;
            const other: [k]u32 = ctx.keyAt(x[1]);
            var same = true;
            inline for (0..k) |j| same = same and other[j] == key[j];
            if (same) return x[1];
            at = (at + 1) & mask;
        }
        return null;
    }

    /// Index entry `len` under `key`, which `find` has just missed. The
    /// caller writes the entry's key into its columns after this succeeds,
    /// so a refusal leaves nothing half-written.
    pub fn insert(ix: *Index, gpa: Allocator, comptime k: usize, key: [k]u32, ctx: anytype) IndexError!void {
        if (2 * (@as(usize, ix.len) + 1) > ix.slots.items.len) try ix.grow(gpa, k, ctx);
        const mask: u32 = @intCast(ix.slots.items.len - 1);
        var at = ix.home(k, key);
        var d: u32 = 0;
        while (ix.slots.items[at][0] == ix.gen) : (d += 1) {
            if (d == probe_length) return error.ProbeLength;
            at = (at + 1) & mask;
        }
        ix.slots.items[at] = .{ ix.gen, ix.len };
        ix.reach = @max(ix.reach, d);
        ix.len += 1;
    }

    /// Twice the slots, every entry placed again from its key.
    fn grow(ix: *Index, gpa: Allocator, comptime k: usize, ctx: anytype) IndexError!void {
        const n = @max(16, 2 * ix.slots.items.len);
        try ix.slots.resize(gpa, n);
        @memset(ix.slots.items, .{ 0, 0 });
        ix.gen = 1;
        ix.reach = 0;
        const mask: u32 = @intCast(n - 1);
        for (0..ix.len) |i| {
            var at = ix.home(k, ctx.keyAt(@intCast(i)));
            var d: u32 = 0;
            while (ix.slots.items[at][0] == ix.gen) : (d += 1) at = (at + 1) & mask;
            ix.slots.items[at] = .{ ix.gen, @intCast(i) };
            ix.reach = @max(ix.reach, d);
        }
        if (ix.reach > probe_length) return error.ProbeLength;
    }
};

/// A map from keys of `k` words to `u32`: an `Index` over its own dense key
/// and value columns, entries numbered in insertion order (§4.1).
pub fn FixedDict(comptime k: usize) type {
    return struct {
        index: Index = .{},
        keys: std.ArrayList(u32) = .empty,
        values: std.ArrayList(u32) = .empty,
        stats: Counters.Dict = Counters.zero(Counters.Dict),

        const Self = @This();
        pub const Key = [k]u32;
        pub const counter_kind = Counters.Kind.dict;

        pub const GetOrPut = struct { found_existing: bool, value_ptr: *u32, index: u32 };

        pub fn deinit(d: *Self, gpa: Allocator) void {
            d.index.deinit(gpa);
            d.keys.deinit(gpa);
            d.values.deinit(gpa);
            if (Counters.enabled) d.stats.trace.deinit(std.heap.smp_allocator);
        }

        pub fn count(d: *const Self) u32 {
            return @intCast(d.values.items.len);
        }

        pub fn clearRetainingCapacity(d: *Self) void {
            d.index.clear();
            d.keys.clearRetainingCapacity();
            d.values.clearRetainingCapacity();
        }

        /// What a walk's slot (`Scratch.Depths`) empties it with.
        pub fn clear(d: *Self) void {
            d.clearRetainingCapacity();
        }

        pub fn keyAt(d: *const Self, i: u32) Key {
            return d.keys.items[i * k ..][0..k].*;
        }

        fn lookup(d: *const Self, key: Key) ?u32 {
            var steps: Counters.Steps = .{};
            defer Counters.dictDescended(&d.stats, steps, d.index.reach);
            return d.index.find(k, key, d, &steps);
        }

        /// The entry number of `key`, or null.
        pub fn indexOf(d: *const Self, key: Key) ?u32 {
            return d.lookup(key);
        }

        pub fn get(d: *const Self, key: Key) ?u32 {
            const at = d.lookup(key);
            Counters.dictGet(k, &d.stats, &key, at != null);
            return if (at) |i| d.values.items[i] else null;
        }

        pub fn getOrPut(d: *Self, gpa: Allocator, key: Key) IndexError!GetOrPut {
            const at = d.lookup(key);
            Counters.dictPut(k, &d.stats, &key, at != null);
            if (at) |i| return .{ .found_existing = true, .value_ptr = &d.values.items[i], .index = i };
            try d.keys.ensureUnusedCapacity(gpa, k);
            try d.values.ensureUnusedCapacity(gpa, 1);
            try d.index.insert(gpa, k, key, d);
            Counters.dictReach(&d.stats, d.index.reach);
            const i: u32 = @intCast(d.values.items.len);
            d.keys.appendSliceAssumeCapacity(&key);
            d.values.appendAssumeCapacity(undefined);
            return .{ .found_existing = false, .value_ptr = &d.values.items[i], .index = i };
        }

        pub fn put(d: *Self, gpa: Allocator, key: Key, v: u32) IndexError!void {
            (try d.getOrPut(gpa, key)).value_ptr.* = v;
        }
    };
}

/// An intern table's index (§4.1): an `Index` whose entry `i` is the
/// table's record `i`, its key rebuilt from that record's columns by
/// `ctx.keyAt(i)`, so the table stores each key once, in its records.
pub fn Interned(comptime k: usize) type {
    return struct {
        index: Index = .{},
        stats: Counters.Dict = Counters.zero(Counters.Dict),

        const Self = @This();
        pub const Key = [k]u32;
        pub const counter_kind = Counters.Kind.dict;

        pub fn deinit(t: *Self, gpa: Allocator) void {
            t.index.deinit(gpa);
            if (Counters.enabled) t.stats.trace.deinit(std.heap.smp_allocator);
        }

        pub fn count(t: *const Self) u32 {
            return t.index.len;
        }

        fn lookup(t: *const Self, key: Key, ctx: anytype) ?u32 {
            var steps: Counters.Steps = .{};
            defer Counters.dictDescended(&t.stats, steps, t.index.reach);
            return t.index.find(k, key, ctx, &steps);
        }

        /// The record holding `key`, or null.
        pub fn get(t: *const Self, key: Key, ctx: anytype) ?u32 {
            const at = t.lookup(key, ctx);
            Counters.dictGet(k, &t.stats, &key, at != null);
            return at;
        }

        /// The record holding `key`, or null once `key` is indexed as the
        /// next record, `records`: the caller appends that record at once,
        /// its capacity ensured before this call.
        pub fn getOrInsert(t: *Self, gpa: Allocator, key: Key, ctx: anytype, records: usize) IndexError!?u32 {
            const at = t.lookup(key, ctx);
            Counters.dictPut(k, &t.stats, &key, at != null);
            if (at != null) return at;
            std.debug.assert(records == t.index.len);
            try t.index.insert(gpa, k, key, ctx);
            Counters.dictReach(&t.stats, t.index.reach);
            return null;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a table's hoisted columns follow its storage across every reallocation" {
    const Rec = struct { a: u32, b: u8, c: NodeId };
    const gpa = testing.allocator;
    var t: Columns(Rec) = .empty;
    defer t.deinit(gpa);
    // Grown one record at a time from nothing, so `append` reallocates
    // several times; after each, every earlier record is read back through
    // `col` and `get`, which a column left on the freed block would fail
    // (and the testing allocator would report as a use after free).
    var moves: u32 = 0;
    for (0..1000) |i| {
        const before = t.col.a.ptr;
        try t.append(gpa, .{ .a = @intCast(i), .b = @truncate(i), .c = .from(@intCast(i * 3)) });
        if (t.col.a.ptr != before) moves += 1;
        t.assertSynced();
        try testing.expectEqual(i + 1, t.col.a.len);
        try testing.expectEqual(t.len(), t.col.c.len);
        for (0..i + 1) |j| {
            try testing.expectEqual(@as(u32, @intCast(j)), t.col.a[j]);
            try testing.expectEqual(@as(u32, @intCast(j * 3)), t.get(j).c.int());
        }
    }
    try testing.expect(moves > 3);
    // A write through `col` is a write to the table.
    t.col.b[7] = 99;
    try testing.expectEqual(@as(u8, 99), t.get(7).b);
    t.set(8, .{ .a = 1, .b = 2, .c = .none });
    try testing.expectEqual(NodeId.none, t.col.c[8]);
    // Shrinking and reserving keep `col` the list's columns too.
    t.shrinkRetainingCapacity(10);
    t.assertSynced();
    try testing.expectEqual(@as(usize, 10), t.col.b.len);
    try t.ensureTotalCapacity(gpa, 5000);
    t.assertSynced();
    try testing.expectEqual(@as(u32, 9), t.col.a[9]);
    t.clearRetainingCapacity();
    t.assertSynced();
    try testing.expectEqual(@as(usize, 0), t.col.a.len);
}

test "an id column reads absent until written, and by epoch only at the epoch written" {
    const gpa = testing.allocator;
    var c: IdColumn(NodeId) = .{};
    defer c.deinit(gpa);
    try testing.expectEqual(@as(?u32, null), c.get(.from(5)));
    try testing.expectEqual(@as(?u32, null), c.get(.none));
    const got = try c.getOrPut(gpa, .from(5));
    try testing.expect(!got.found_existing);
    got.value_ptr.* = none_int;
    // Any value is stored, `none` included; ids below and above stay absent.
    try testing.expectEqual(@as(?u32, none_int), c.get(.from(5)));
    try testing.expectEqual(@as(?u32, null), c.get(.from(4)));
    try testing.expectEqual(@as(?u32, null), c.get(.from(6)));
    try testing.expect((try c.getOrPut(gpa, .from(5))).found_existing);
    try c.put(gpa, .from(0), 7);
    try testing.expectEqual(@as(?u32, 7), c.get(.from(0)));
    var e: IdColumn(u32) = .{};
    defer e.deinit(gpa);
    (try e.getOrPutAt(gpa, 3, 0)).value_ptr.* = 11;
    try testing.expectEqual(@as(?u32, 11), e.getAt(3, 0));
    try testing.expectEqual(@as(?u32, null), e.getAt(3, 1));
    // Written again at a later epoch, it is that epoch's alone.
    const later = try e.getOrPutAt(gpa, 3, 1);
    try testing.expect(!later.found_existing);
    later.value_ptr.* = 12;
    try testing.expectEqual(@as(?u32, 12), e.getAt(3, 1));
    try testing.expectEqual(@as(?u32, null), e.getAt(3, 0));
}

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

test "the fixed-key dictionary finds composite keys" {
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

test "a dictionary grows past many sizes and numbers its entries in insertion order" {
    const gpa = testing.allocator;
    var d: FixedDict(2) = .{};
    defer d.deinit(gpa);
    var k: u32 = 0;
    while (k < 5000) : (k += 1) {
        const got = try d.getOrPut(gpa, .{ k, k ^ 0x5555 });
        try testing.expect(!got.found_existing);
        try testing.expectEqual(k, got.index);
        got.value_ptr.* = k + 1;
    }
    // Every doubling placed each entry again from its key.
    try testing.expect(d.index.slots.items.len >= 2 * 5000);
    k = 0;
    while (k < 5000) : (k += 1) {
        try testing.expectEqual(@as(?u32, k + 1), d.get(.{ k, k ^ 0x5555 }));
        try testing.expectEqual([2]u32{ k, k ^ 0x5555 }, d.keyAt(k));
    }
    try testing.expectEqual(@as(?u32, null), d.get(.{ 5000, 5000 ^ 0x5555 }));
}

test "a cleared dictionary is empty, keeps its slots, and numbers from zero again" {
    const gpa = testing.allocator;
    var d: FixedDict(1) = .{};
    defer d.deinit(gpa);
    for (0..100) |i| try d.put(gpa, .{@intCast(i)}, @intCast(i));
    const slots = d.index.slots.items.len;
    d.clear();
    try testing.expectEqual(@as(u32, 0), d.count());
    for (0..100) |i| try testing.expectEqual(@as(?u32, null), d.get(.{@intCast(i)}));
    const got = try d.getOrPut(gpa, .{7});
    try testing.expect(!got.found_existing);
    try testing.expectEqual(@as(u32, 0), got.index);
    got.value_ptr.* = 70;
    try testing.expectEqual(@as(?u32, 70), d.get(.{7}));
    try testing.expectEqual(slots, d.index.slots.items.len);
}

test "a dictionary's generation wraps: every older slot reads as empty" {
    const gpa = testing.allocator;
    var d: FixedDict(1) = .{};
    defer d.deinit(gpa);
    for (0..10) |i| try d.put(gpa, .{@intCast(i)}, 1);
    // The last generation before the counter wraps.
    d.index.gen = std.math.maxInt(u32);
    for (d.index.slots.items) |*x| {
        if (x[0] != 0) x[0] = d.index.gen;
    }
    try testing.expectEqual(@as(?u32, 1), d.get(.{3}));
    d.clear();
    try testing.expectEqual(@as(u32, 1), d.index.gen);
    for (d.index.slots.items) |x| try testing.expectEqual(@as(u32, 0), x[0]);
    for (0..10) |i| try testing.expectEqual(@as(?u32, null), d.get(.{@intCast(i)}));
    try d.put(gpa, .{3}, 9);
    try testing.expectEqual(@as(?u32, 9), d.get(.{3}));
    try testing.expectEqual(@as(?u32, null), d.get(.{4}));
}

test "an intern table keeps its keys in its records" {
    const gpa = testing.allocator;
    const Records = struct {
        rows: std.ArrayList([3]u32) = .empty,
        pub fn keyAt(r: *const @This(), i: u32) [3]u32 {
            return r.rows.items[i];
        }
    };
    var recs: Records = .{};
    defer recs.rows.deinit(gpa);
    var ix: Interned(3) = .{};
    defer ix.deinit(gpa);
    for (0..300) |i| {
        const key = [3]u32{ @intCast(i % 7), @intCast(i), 1 };
        try recs.rows.ensureUnusedCapacity(gpa, 1);
        try testing.expectEqual(@as(?u32, null), try ix.getOrInsert(gpa, key, &recs, recs.rows.items.len));
        recs.rows.appendAssumeCapacity(key);
    }
    for (0..300) |i| {
        const key = [3]u32{ @intCast(i % 7), @intCast(i), 1 };
        try testing.expectEqual(@as(?u32, @intCast(i)), try ix.getOrInsert(gpa, key, &recs, recs.rows.items.len));
        try testing.expectEqual(@as(?u32, @intCast(i)), ix.get(key, &recs));
    }
    try testing.expectEqual(@as(?u32, null), ix.get(.{ 0, 1, 1 }, &recs));
    try testing.expectEqual(@as(u32, 300), ix.count());
}

test "keys that collide past probe_length are the named ownership_limit, and the dictionary stays whole" {
    const gpa = testing.allocator;
    // Keys whose hashes agree in their low 12 bits share one home in every
    // table up to 4 096 slots, which holds them all at a load of 1/2.
    const want = probe_length + 2;
    var keys: std.ArrayList(u32) = .empty;
    defer keys.deinit(gpa);
    const home = hashKey(1, .{0}) & 0xFFF;
    var x: u32 = 0;
    while (keys.items.len < want) : (x += 1) {
        if (hashKey(1, .{x}) & 0xFFF == home) try keys.append(gpa, x);
    }
    var d: FixedDict(1) = .{};
    defer d.deinit(gpa);
    var a: Account = .{};
    defer a.deinit(gpa);
    const refused: usize = for (keys.items, 0..) |key, i| {
        d.put(gpa, .{key}, @intCast(i)) catch |err| {
            try testing.expectEqual(error.ProbeLength, err);
            break i;
        };
    } else return error.TestExpectedProbeLength;
    // The probe of displacement `probe_length` is the last one taken.
    try testing.expectEqual(@as(usize, probe_length + 1), refused);
    try testing.expectEqual(probe_length, d.index.reach);
    for (keys.items[0..refused], 0..) |key, i| try testing.expectEqual(@as(?u32, @intCast(i)), d.get(.{key}));
    try testing.expectEqual(@as(?u32, null), d.get(.{keys.items[refused]}));
    try testing.expectEqual(@as(u32, @intCast(refused)), d.count());
    // The walk that meets it names the limit, and the owner stops.
    _ = a.probeFailed();
    try testing.expectEqual(Failure{ .limit = .probe_length }, a.failed.?);
    try testing.expectEqualStrings("probe_length", @tagName(a.failed.?.limit));
    try testing.expectError(error.OwnershipLimit, a.reserve(.cell, 1));
}

test "a charge reserves in the lane it is given, and growth only when it is given none" {
    var a: Account = .{ .allowance = 0 };
    defer a.deinit(testing.allocator);
    const lane: Lane = .{ .atom = 3, .role = .direct_data };
    const in_lane: Charge = .in(&a, lane);
    // Source-sized work in its lane spends no growth (§4.4).
    for (0..3) |_| try in_lane.reserve(testing.allocator, .chunk, 1);
    try testing.expectEqual(@as(u32, 0), a.growth);
    try testing.expectEqual(@as(u32, 3), a.laneUsed(lane));
    try testing.expectEqual(@as(u64, 3), a.baseline);
    try in_lane.reserve(testing.allocator, .task, 1);
    try testing.expectEqual(@as(u32, 4), a.laneUsed(lane));
    // With no lane the same call is growth, and this account has none.
    try testing.expectError(error.OwnershipLimit, Charge.growth(&a).reserve(testing.allocator, .task, 1));
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
