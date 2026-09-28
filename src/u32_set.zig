//! `U32Set`: a set of `u32` keys — term indices, symbols — by open
//! addressing with linear probing over a power-of-two table, the slot taken
//! from the high bits of one multiplication.
//!
//! `std`'s hash map hashes a `u32` with Wyhash and runs generic code that
//! Zig's own backend, which builds the compiler the test suites run,
//! compiles poorly; as the walked-term set of the evidence edge walk and the
//! seen-field set of a record's lowering it was a sixth of building a wide
//! type. The set is never iterated, so its layout is never observable.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const U32Set = struct {
    slots: []u32 = &.{},
    count: usize = 0,

    /// The one key the set cannot hold.
    pub const empty = std.math.maxInt(u32);

    pub fn deinit(s: *U32Set, gpa: Allocator) void {
        gpa.free(s.slots);
        s.* = .{};
    }

    /// Add `key`, which is never `empty`; true when it was there already.
    pub fn insert(s: *U32Set, gpa: Allocator, key: u32) Allocator.Error!bool {
        std.debug.assert(key != empty);
        if ((s.count + 1) * 4 > s.slots.len * 3) try s.grow(gpa);
        const mask = s.slots.len - 1;
        var i = slot(key, s.slots.len);
        while (true) : (i = (i + 1) & mask) {
            if (s.slots[i] == key) return true;
            if (s.slots[i] == empty) {
                s.slots[i] = key;
                s.count += 1;
                return false;
            }
        }
    }

    fn grow(s: *U32Set, gpa: Allocator) Allocator.Error!void {
        const len = @max(16, s.slots.len * 2);
        const slots = try gpa.alloc(u32, len);
        @memset(slots, empty);
        const mask = len - 1;
        for (s.slots) |key| {
            if (key == empty) continue;
            var i = slot(key, len);
            while (slots[i] != empty) i = (i + 1) & mask;
            slots[i] = key;
        }
        gpa.free(s.slots);
        s.slots = slots;
    }

    fn slot(key: u32, len: usize) usize {
        const bits: u6 = @intCast(std.math.log2_int(usize, len));
        return @intCast((@as(u64, key) *% 0x9E37_79B9_7F4A_7C15) >> (63 - bits) >> 1);
    }
};

test "a key is new once and seen after, across growth" {
    const gpa = std.testing.allocator;
    var set: U32Set = .{};
    defer set.deinit(gpa);
    for (0..5000) |i| try std.testing.expect(!try set.insert(gpa, @intCast(i * 7)));
    for (0..5000) |i| try std.testing.expect(try set.insert(gpa, @intCast(i * 7)));
    try std.testing.expect(!try set.insert(gpa, 1));
    try std.testing.expectEqual(@as(usize, 5001), set.count);
}
