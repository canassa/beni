//! L7: the keys a supply's parts are described below (`docs/design/ownership-v2.md` §2.1,
//! *An arrival's level*). A value described by its own place has no path from the supply's
//! root, so a result list carries the key in its `k`, above the supply's index, and a delivery
//! later in the evaluation writes at the same key.
//!
//! Obligations kept here: none of §2.14's directly.

const std = @import("std");
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");

const Allocator = std.mem.Allocator;

pub const Keys = struct {
    keys: std.ArrayList(Slots.Rel) = .empty,
    at: Ids.FixedDict(1) = .{},

    pub fn deinit(ks: *Keys, gpa: Allocator) void {
        ks.keys.deinit(gpa);
        ks.at.deinit(gpa);
    }

    /// Supply `k`'s index, with its slots written below `key`.
    pub fn below(ks: *Keys, gpa: Allocator, k: u32, key: Slots.Rel) Ids.IndexError!u32 {
        const g = try ks.at.getOrPut(gpa, .{key});
        if (!g.found_existing) {
            g.value_ptr.* = @intCast(ks.keys.items.len);
            try ks.keys.append(gpa, key);
        }
        return supply(k) | (g.value_ptr.* + 1) << 16;
    }

    /// The key `k` carries, null when it carries none.
    pub fn of(ks: *const Keys, k: u32) ?Slots.Rel {
        return if (k >> 16 == 0) null else ks.keys.items[(k >> 16) - 1];
    }
};

/// The slot that path `q` writes in a result list of index `k`, for `s` an `Eval.Sink`.
pub fn relAt(s: anytype, q: Ids.PathId, k: u32) Slots.Error!Slots.Rel {
    const f = s.e.fr();
    const r = try f.slots.relOf(s.e.gpa(), f.account, f.places, q);
    const key = s.keys.of(k) orelse return r;
    return f.slots.relOfWords(s.e.gpa(), f.account, f.places, try std.mem.concat(s.arena, u32, &.{ f.slots.relWords(key), f.slots.relWords(r) }));
}

/// The supply's own index.
pub fn supply(k: u32) u32 {
    return k & 0xffff;
}

test "a list's index carries its key and keeps the supply's" {
    const gpa = std.testing.allocator;
    var ks: Keys = .{};
    defer ks.deinit(gpa);
    const a: Slots.Rel = 7;
    const k = try ks.below(gpa, 3, a);
    try std.testing.expectEqual(@as(u32, 3), supply(k));
    try std.testing.expectEqual(a, ks.of(k).?);
    try std.testing.expectEqual(k, try ks.below(gpa, 3, a));
    try std.testing.expectEqual(@as(?Slots.Rel, null), ks.of(3));
}
