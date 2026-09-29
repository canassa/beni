//! `Column(K, V)`: a map from a dense id to a value, as an array indexed by
//! the id (fast-compiler.md §5 rule 5).
//!
//! A slot holds its value while its stamp is the column's generation, so
//! emptying the column is one increment — which is what lets a short-lived
//! table over a large id space (a boundary's variables over a module's
//! store, one statement list's shared evidence terms) be a column rather than a
//! hash map: clearing and lookup cost nothing in proportion to the space.
//! Writing an id past the end makes every slot up to it, stamped empty, so
//! a column holds memory in proportion to the highest id it has seen, not to
//! its entries (why lowering's name tables stay maps, `src/rules_test.zig`);
//! a read past the end is a miss.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Column(comptime K: type, comptime V: type) type {
    return struct {
        slots: std.ArrayList(Slot) = .empty,
        /// A slot stamped with anything else is empty. Never 0, the stamp
        /// of a slot never written.
        gen: u32 = 1,

        const Self = @This();
        const Slot = struct { stamp: u32 = 0, value: V = undefined };

        pub const GetOrPut = struct { found_existing: bool, value_ptr: *V };

        pub fn deinit(c: *Self, gpa: Allocator) void {
            c.slots.deinit(gpa);
        }

        /// Every slot empty: one increment, and a pass over the slots once
        /// in four billion.
        pub fn clear(c: *Self) void {
            c.gen +%= 1;
            if (c.gen != 0) return;
            for (c.slots.items) |*s| s.stamp = 0;
            c.gen = 1;
        }

        pub fn get(c: *const Self, k: K) ?V {
            const i = index(k);
            if (i >= c.slots.items.len) return null;
            const slot = &c.slots.items[i];
            return if (slot.stamp == c.gen) slot.value else null;
        }

        pub fn getPtr(c: *Self, k: K) ?*V {
            const i = index(k);
            if (i >= c.slots.items.len) return null;
            const slot = &c.slots.items[i];
            return if (slot.stamp == c.gen) &slot.value else null;
        }

        pub fn contains(c: *const Self, k: K) bool {
            const i = index(k);
            return i < c.slots.items.len and c.slots.items[i].stamp == c.gen;
        }

        pub fn put(c: *Self, gpa: Allocator, k: K, value: V) Allocator.Error!void {
            const slot = try c.slotOf(gpa, k);
            slot.* = .{ .stamp = c.gen, .value = value };
        }

        pub fn getOrPut(c: *Self, gpa: Allocator, k: K) Allocator.Error!GetOrPut {
            const slot = try c.slotOf(gpa, k);
            const found = slot.stamp == c.gen;
            slot.stamp = c.gen;
            return .{ .found_existing = found, .value_ptr = &slot.value };
        }

        pub fn remove(c: *Self, k: K) void {
            const i = index(k);
            if (i < c.slots.items.len) c.slots.items[i].stamp = 0;
        }

        fn slotOf(c: *Self, gpa: Allocator, k: K) Allocator.Error!*Slot {
            const i = index(k);
            if (i >= c.slots.items.len) try c.slots.appendNTimes(gpa, .{}, i + 1 - c.slots.items.len);
            return &c.slots.items[i];
        }

        fn index(k: K) usize {
            return switch (@typeInfo(K)) {
                .@"enum" => @intFromEnum(k),
                else => k,
            };
        }
    };
}

const testing = std.testing;

test "a column forgets everything at clear, and nothing before it" {
    const Id = enum(u32) { _ };
    var c: Column(Id, u32) = .{};
    defer c.deinit(testing.allocator);
    const a: Id = @enumFromInt(3);
    const b: Id = @enumFromInt(40);
    try c.put(testing.allocator, a, 7);
    try testing.expectEqual(@as(?u32, 7), c.get(a));
    try testing.expectEqual(@as(?u32, null), c.get(b));
    const got = try c.getOrPut(testing.allocator, b);
    try testing.expect(!got.found_existing);
    got.value_ptr.* = 9;
    try testing.expect((try c.getOrPut(testing.allocator, b)).found_existing);
    c.remove(a);
    try testing.expect(!c.contains(a));
    try testing.expectEqual(@as(?u32, 9), c.get(b));
    c.clear();
    try testing.expect(!c.contains(b));
    try testing.expectEqual(@as(?u32, null), c.get(@enumFromInt(1000)));
}

test "a generation that wraps empties every slot first" {
    var c: Column(u32, void) = .{ .gen = std.math.maxInt(u32) };
    defer c.deinit(testing.allocator);
    try c.put(testing.allocator, 2, {});
    c.clear();
    try testing.expectEqual(@as(u32, 1), c.gen);
    try testing.expect(!c.contains(2));
}
