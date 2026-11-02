//! A walk's working sets: sparse sets over dense ids, kept by a table in
//! slots indexed by the walk's depth, so a walk neither allocates nor clears
//! in proportion to the id space (#1646).
//!
//! - `Set(K)` and `Map(K, V)` are Briggs–Torczon sparse sets: the entries in
//!   a dense array in the order they were added, and a sparse index by id
//!   that names an entry's position. An id is present when its index names a
//!   position below the count whose entry holds that id, so `clear` sets the
//!   count to zero and the index is never emptied. The index grows to the
//!   highest id the structure has seen, once in its life, not per walk.
//! - `Dict(k, lead)` is the same over keys of `k` words: the sparse index
//!   is by the word `lead`, a dense id, and the entries of one lead word
//!   form a chain. Its entries are numbered in the order they were added,
//!   as `Ids.FixedDict`'s are.
//! - `Depths(T)` holds one `T` per walk in progress: `take` gives the slot
//!   of the next depth, emptied, and `give` returns it. A nested walk is one
//!   depth deeper, so it never shares a slot with the walk around it, and a
//!   slot is emptied before each use, so it never shows a previous walk's
//!   entries. Slots never move: they live in blocks of 1, 2, 4, … slots, a
//!   block allocated once, so a `*T` stays valid while deeper slots are made.
//!
//! A value pointer (`getPtr`, `getOrPut`) is valid until the next entry is
//! added or removed: entries live in growing arrays.
//!
//! Obligations kept here: none.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Counters = @import("Counters.zig");

const none: u32 = std.math.maxInt(u32);

/// Where id `k` is in a sparse index: one past it, so `none` (an id's
/// absent value, which some walks key by) is slot 0.
inline fn index(comptime K: type, k: K) u32 {
    return slot(switch (@typeInfo(K)) {
        .@"enum" => @backingInt(k),
        else => k,
    });
}

inline fn slot(w: u32) u32 {
    return w +% 1;
}

/// `sparse[i]` for an id never seen: no entry (`present` checks the entry
/// anyway, so its value only has to be defined).
fn grow(gpa: Allocator, sparse: *std.ArrayList(u32), i: u32) Allocator.Error!void {
    if (i < sparse.items.len) return;
    const n = @max(i + 1, sparse.items.len * 2);
    try sparse.appendNTimes(gpa, none, n - sparse.items.len);
}

/// A set of dense ids `K`.
pub fn Set(comptime K: type) type {
    return Map(K, void);
}

/// A map from dense ids `K` to `V`.
pub fn Map(comptime K: type, comptime V: type) type {
    return struct {
        sparse: std.ArrayList(u32) = .empty,
        keys: std.ArrayList(K) = .empty,
        values: std.ArrayList(V) = .empty,
        stats: Counters.Sparse = Counters.zero(Counters.Sparse),

        const Self = @This();
        pub const Key = K;
        pub const counter_kind = Counters.Kind.sparse;

        pub const GetOrPut = struct { found_existing: bool, value_ptr: *V, index: u32 };

        pub fn deinit(m: *Self, gpa: Allocator) void {
            m.sparse.deinit(gpa);
            m.keys.deinit(gpa);
            m.values.deinit(gpa);
        }

        pub fn clear(m: *Self) void {
            Counters.sparseClear(&m.stats);
            m.keys.items.len = 0;
            m.values.items.len = 0;
        }

        pub fn count(m: *const Self) u32 {
            return @intCast(m.keys.items.len);
        }

        /// The entry of `k`, or null.
        fn find(m: *const Self, k: K) ?u32 {
            const i = index(K, k);
            if (i >= m.sparse.items.len) return null;
            const at = m.sparse.items[i];
            return if (at < m.keys.items.len and m.keys.items[at] == k) at else null;
        }

        pub fn contains(m: *const Self, k: K) bool {
            const hit = m.find(k) != null;
            Counters.sparseGet(&m.stats, hit, 0);
            return hit;
        }

        pub fn get(m: *const Self, k: K) ?V {
            const at = m.find(k);
            Counters.sparseGet(&m.stats, at != null, 0);
            return if (at) |i| m.values.items[i] else null;
        }

        pub fn getPtr(m: *Self, k: K) ?*V {
            const at = m.find(k);
            Counters.sparseGet(&m.stats, at != null, 0);
            return if (at) |i| &m.values.items[i] else null;
        }

        pub fn getOrPut(m: *Self, gpa: Allocator, k: K) Allocator.Error!GetOrPut {
            if (m.find(k)) |i| {
                Counters.sparsePut(&m.stats, true, 0);
                return .{ .found_existing = true, .value_ptr = &m.values.items[i], .index = i };
            }
            Counters.sparsePut(&m.stats, false, 0);
            try grow(gpa, &m.sparse, index(K, k));
            try m.keys.ensureUnusedCapacity(gpa, 1);
            try m.values.ensureUnusedCapacity(gpa, 1);
            const i: u32 = @intCast(m.keys.items.len);
            m.sparse.items[index(K, k)] = i;
            m.keys.appendAssumeCapacity(k);
            m.values.appendAssumeCapacity(undefined);
            return .{ .found_existing = false, .value_ptr = &m.values.items[i], .index = i };
        }

        pub fn put(m: *Self, gpa: Allocator, k: K, v: V) Allocator.Error!void {
            (try m.getOrPut(gpa, k)).value_ptr.* = v;
        }

        /// `k` gone; the last entry takes its position.
        pub fn remove(m: *Self, k: K) void {
            const i = m.find(k) orelse return;
            const last = m.keys.items.len - 1;
            const moved = m.keys.items[last];
            m.keys.items[i] = moved;
            m.values.items[i] = m.values.items[last];
            m.sparse.items[index(K, moved)] = i;
            m.keys.items.len = last;
            m.values.items.len = last;
        }
    };
}

/// A map from keys of `k` words to `u32`, whose word `lead` is a dense id.
pub fn Dict(comptime k: usize, comptime lead: usize) type {
    comptime std.debug.assert(lead < k);
    return struct {
        /// By lead word: the position in `heads` of its chain.
        sparse: std.ArrayList(u32) = .empty,
        /// Per lead word present: the word, and its chain's newest entry.
        heads: std.ArrayList([2]u32) = .empty,
        keys: std.ArrayList(u32) = .empty,
        values: std.ArrayList(u32) = .empty,
        /// The next older entry of the same lead word.
        next: std.ArrayList(u32) = .empty,
        stats: Counters.Sparse = Counters.zero(Counters.Sparse),

        const Self = @This();
        pub const Key = [k]u32;
        pub const counter_kind = Counters.Kind.sparse;

        pub const GetOrPut = struct { found_existing: bool, value_ptr: *u32, index: u32 };

        pub fn deinit(d: *Self, gpa: Allocator) void {
            d.sparse.deinit(gpa);
            d.heads.deinit(gpa);
            d.keys.deinit(gpa);
            d.values.deinit(gpa);
            d.next.deinit(gpa);
        }

        pub fn clear(d: *Self) void {
            Counters.sparseClear(&d.stats);
            d.heads.items.len = 0;
            d.keys.items.len = 0;
            d.values.items.len = 0;
            d.next.items.len = 0;
        }

        pub fn count(d: *const Self) u32 {
            return @intCast(d.values.items.len);
        }

        pub fn keyAt(d: *const Self, i: u32) Key {
            return d.keys.items[i * k ..][0..k].*;
        }

        /// The position in `heads` of `w`'s chain, or null.
        fn headOf(d: *const Self, w: u32) ?u32 {
            if (slot(w) >= d.sparse.items.len) return null;
            const at = d.sparse.items[slot(w)];
            return if (at < d.heads.items.len and d.heads.items[at][0] == w) at else null;
        }

        /// Whether entry `at` holds `key`: its words compared in line.
        inline fn matches(d: *const Self, at: u32, key: Key) bool {
            const ks = d.keys.items[at * k ..][0..k];
            inline for (0..k) |j| {
                if (j != lead and ks[j] != key[j]) return false;
            }
            return true;
        }

        /// The entry of `key`, or null; `steps` counts the entries compared.
        fn find(d: *const Self, key: Key, steps: *u32) ?u32 {
            const h = d.headOf(key[lead]) orelse return null;
            var at = d.heads.items[h][1];
            while (at != none) : (at = d.next.items[at]) {
                steps.* += 1;
                if (d.matches(at, key)) return at;
            }
            return null;
        }

        pub fn get(d: *const Self, key: Key) ?u32 {
            var steps: u32 = 0;
            const at = d.find(key, &steps);
            Counters.sparseGet(&d.stats, at != null, steps);
            return if (at) |i| d.values.items[i] else null;
        }

        pub fn getOrPut(d: *Self, gpa: Allocator, key: Key) Allocator.Error!GetOrPut {
            var steps: u32 = 0;
            if (d.find(key, &steps)) |i| {
                Counters.sparsePut(&d.stats, true, steps);
                return .{ .found_existing = true, .value_ptr = &d.values.items[i], .index = i };
            }
            Counters.sparsePut(&d.stats, false, steps);
            const w = key[lead];
            try grow(gpa, &d.sparse, slot(w));
            try d.heads.ensureUnusedCapacity(gpa, 1);
            try d.keys.ensureUnusedCapacity(gpa, k);
            try d.values.ensureUnusedCapacity(gpa, 1);
            try d.next.ensureUnusedCapacity(gpa, 1);
            const i: u32 = @intCast(d.values.items.len);
            if (d.headOf(w)) |h| {
                d.next.appendAssumeCapacity(d.heads.items[h][1]);
                d.heads.items[h][1] = i;
            } else {
                d.sparse.items[slot(w)] = @intCast(d.heads.items.len);
                d.heads.appendAssumeCapacity(.{ w, i });
                d.next.appendAssumeCapacity(none);
            }
            d.keys.appendSliceAssumeCapacity(&key);
            d.values.appendAssumeCapacity(undefined);
            return .{ .found_existing = false, .value_ptr = &d.values.items[i], .index = i };
        }

        pub fn put(d: *Self, gpa: Allocator, key: Key, v: u32) Allocator.Error!void {
            (try d.getOrPut(gpa, key)).value_ptr.* = v;
        }
    };
}

/// A map from keys of `k` words to `u32` whose words are not one dense id
/// a chain can hang from: open addressing over the entries' indices, the
/// slots stamped with a generation, so `clear` is one increment and the
/// slots are kept for the next walk. The hash is fixed: the probes never
/// depend on anything but the keys. Entries are numbered in the order they
/// were added.
pub fn Hash(comptime k: usize) type {
    return struct {
        /// `(generation, entry)`; a slot of another generation is empty.
        slots: std.ArrayList([2]u32) = .empty,
        gen: u32 = 1,
        keys: std.ArrayList(u32) = .empty,
        values: std.ArrayList(u32) = .empty,
        stats: Counters.Sparse = Counters.zero(Counters.Sparse),

        const Self = @This();
        pub const Key = [k]u32;
        pub const counter_kind = Counters.Kind.sparse;

        pub const GetOrPut = struct { found_existing: bool, value_ptr: *u32, index: u32 };

        pub fn deinit(d: *Self, gpa: Allocator) void {
            d.slots.deinit(gpa);
            d.keys.deinit(gpa);
            d.values.deinit(gpa);
        }

        pub fn clear(d: *Self) void {
            Counters.sparseClear(&d.stats);
            d.keys.items.len = 0;
            d.values.items.len = 0;
            d.gen +%= 1;
            if (d.gen != 0) return;
            for (d.slots.items) |*x| x[0] = 0;
            d.gen = 1;
        }

        pub fn count(d: *const Self) u32 {
            return @intCast(d.values.items.len);
        }

        pub fn keyAt(d: *const Self, i: u32) Key {
            return d.keys.items[i * k ..][0..k].*;
        }

        inline fn hash(key: Key) u64 {
            var h: u64 = 0x243f6a8885a308d3;
            inline for (0..k) |j| {
                h = (h ^ key[j]) *% 0x9e3779b97f4a7c15;
                h ^= h >> 29;
            }
            return h ^ (h >> 32);
        }

        /// The slot of `key`, or the empty slot where it would go.
        fn probe(d: *const Self, key: Key, steps: *u32) u32 {
            const mask: u32 = @intCast(d.slots.items.len - 1);
            var at: u32 = @as(u32, @truncate(hash(key))) & mask;
            while (true) : (at = (at + 1) & mask) {
                steps.* += 1;
                const x = d.slots.items[at];
                if (x[0] != d.gen) return at;
                const ks = d.keys.items[x[1] * k ..][0..k];
                var same = true;
                inline for (0..k) |j| same = same and ks[j] == key[j];
                if (same) return at;
            }
        }

        pub fn get(d: *const Self, key: Key) ?u32 {
            var steps: u32 = 0;
            const hit: ?u32 = if (d.slots.items.len == 0) null else blk: {
                const x = d.slots.items[d.probe(key, &steps)];
                break :blk if (x[0] == d.gen) x[1] else null;
            };
            Counters.sparseGet(&d.stats, hit != null, steps);
            return if (hit) |i| d.values.items[i] else null;
        }

        pub fn getOrPut(d: *Self, gpa: Allocator, key: Key) Allocator.Error!GetOrPut {
            var steps: u32 = 0;
            if (2 * (d.values.items.len + 1) > d.slots.items.len) try d.grow(gpa);
            const at = d.probe(key, &steps);
            const x = d.slots.items[at];
            Counters.sparsePut(&d.stats, x[0] == d.gen, steps);
            if (x[0] == d.gen) return .{ .found_existing = true, .value_ptr = &d.values.items[x[1]], .index = x[1] };
            try d.keys.ensureUnusedCapacity(gpa, k);
            try d.values.ensureUnusedCapacity(gpa, 1);
            const i: u32 = @intCast(d.values.items.len);
            d.slots.items[at] = .{ d.gen, i };
            d.keys.appendSliceAssumeCapacity(&key);
            d.values.appendAssumeCapacity(undefined);
            return .{ .found_existing = false, .value_ptr = &d.values.items[i], .index = i };
        }

        pub fn put(d: *Self, gpa: Allocator, key: Key, v: u32) Allocator.Error!void {
            (try d.getOrPut(gpa, key)).value_ptr.* = v;
        }

        /// Twice the slots, the entries placed again.
        fn grow(d: *Self, gpa: Allocator) Allocator.Error!void {
            const n = @max(16, 2 * d.slots.items.len);
            try d.slots.resize(gpa, n);
            @memset(d.slots.items, .{ 0, 0 });
            d.gen = 1;
            const mask: u32 = @intCast(n - 1);
            for (0..d.values.items.len) |i| {
                var at: u32 = @as(u32, @truncate(hash(d.keyAt(@intCast(i))))) & mask;
                while (d.slots.items[at][0] == d.gen) at = (at + 1) & mask;
                d.slots.items[at] = .{ d.gen, @intCast(i) };
            }
        }
    };
}

/// One `T` per walk in progress, by depth (see the file's header). `T` has
/// a default value, `clear()` and `deinit(gpa)`.
pub fn Depths(comptime T: type) type {
    return struct {
        /// Block `b` holds the slots `2^b - 1 ..< 2^(b+1) - 1`.
        blocks: [block_count]?[*]T = @splat(null),
        /// Slots made (each `T` initialised once), and in use.
        made: u32 = 0,
        depth: u32 = 0,
        stats: Counters.PoolS = Counters.zero(Counters.PoolS),

        const Self = @This();
        const block_count = 32;
        pub const counter_kind = Counters.Kind.pool;

        fn at(p: *const Self, d: u32) *T {
            const b = std.math.log2_int(u32, d + 1);
            return &p.blocks[b].?[d + 1 - (@as(u32, 1) << b)];
        }

        pub fn deinit(p: *Self, gpa: Allocator) void {
            std.debug.assert(p.depth == 0);
            for (0..p.made) |d| p.at(@intCast(d)).deinit(gpa);
            for (&p.blocks, 0..) |*b, i| if (b.*) |ptr| {
                gpa.free(ptr[0 .. @as(usize, 1) << @intCast(i)]);
                b.* = null;
            };
            p.made = 0;
        }

        /// The slot of the next depth, emptied.
        pub fn take(p: *Self, gpa: Allocator) Allocator.Error!*T {
            const d = p.depth;
            Counters.poolTake(&p.stats, d == p.made);
            if (d == p.made) {
                const b = std.math.log2_int(u32, d + 1);
                if (p.blocks[b] == null) p.blocks[b] = (try gpa.alloc(T, @as(usize, 1) << @intCast(b))).ptr;
                p.at(d).* = .{};
                p.made += 1;
            }
            p.depth = d + 1;
            const t = p.at(d);
            t.clear();
            return t;
        }

        /// `t`, the deepest slot taken, given back.
        pub fn give(p: *Self, t: *T) void {
            std.debug.assert(p.depth > 0 and p.at(p.depth - 1) == t);
            p.depth -= 1;
        }
    };
}

const testing = std.testing;

test "a sparse map forgets everything at clear, and a removal moves the last entry" {
    const Id = enum(u32) { _ };
    const gpa = testing.allocator;
    var m: Map(Id, u32) = .{};
    defer m.deinit(gpa);
    const a: Id = @fromBackingInt(3);
    const b: Id = @fromBackingInt(40);
    const c: Id = @fromBackingInt(7);
    try m.put(gpa, a, 7);
    try testing.expectEqual(@as(?u32, 7), m.get(a));
    try testing.expectEqual(@as(?u32, null), m.get(b));
    const got = try m.getOrPut(gpa, b);
    try testing.expect(!got.found_existing);
    got.value_ptr.* = 9;
    try testing.expect((try m.getOrPut(gpa, b)).found_existing);
    try m.put(gpa, c, 5);
    m.remove(a);
    try testing.expect(!m.contains(a));
    try testing.expectEqual(@as(?u32, 9), m.get(b));
    try testing.expectEqual(@as(?u32, 5), m.get(c));
    try testing.expectEqual(@as(u32, 2), m.count());
    m.clear();
    try testing.expect(!m.contains(b) and !m.contains(c));
    try testing.expectEqual(@as(?u32, null), m.get(@fromBackingInt(1000)));
    // A stale index entry names a position a later entry took.
    try m.put(gpa, c, 1);
    try testing.expect(!m.contains(b));
    try testing.expectEqual(@as(?u32, 1), m.get(c));
}

test "a sparse dictionary numbers its entries in order and chains one lead word" {
    const gpa = testing.allocator;
    var d: Dict(3, 1) = .{};
    defer d.deinit(gpa);
    for (0..20) |i| {
        const got = try d.getOrPut(gpa, .{ @intCast(i), @intCast(i % 3), 5 });
        try testing.expect(!got.found_existing);
        try testing.expectEqual(@as(u32, @intCast(i)), got.index);
        got.value_ptr.* = @intCast(100 + i);
    }
    for (0..20) |i| try testing.expectEqual(@as(?u32, @intCast(100 + i)), d.get(.{ @intCast(i), @intCast(i % 3), 5 }));
    try testing.expectEqual(@as(?u32, null), d.get(.{ 1, 2, 5 }));
    try testing.expectEqual([3]u32{ 4, 1, 5 }, d.keyAt(4));
    d.clear();
    try testing.expectEqual(@as(?u32, null), d.get(.{ 0, 0, 5 }));
    try testing.expect(!(try d.getOrPut(gpa, .{ 2, 2, 5 })).found_existing);
    try testing.expectEqual(@as(u32, 1), d.count());
}

test "a nested walk takes its own slot, emptied, and slots never move" {
    const gpa = testing.allocator;
    var p: Depths(Set(u32)) = .{};
    defer p.deinit(gpa);
    const outer = try p.take(gpa);
    try outer.put(gpa, 5, {});
    var taken: [40]*Set(u32) = undefined;
    for (&taken, 0..) |*t, i| {
        t.* = try p.take(gpa);
        try testing.expect(t.* != outer and !t.*.contains(5));
        try t.*.put(gpa, @intCast(i), {});
    }
    try testing.expect(outer.contains(5));
    var i: usize = taken.len;
    while (i > 0) {
        i -= 1;
        try testing.expect(taken[i].contains(@intCast(i)));
        p.give(taken[i]);
    }
    p.give(outer);
    const again = try p.take(gpa);
    try testing.expect(again == outer and !again.contains(5));
    p.give(again);
}
