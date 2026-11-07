//! L7: the key a supply's part is described below (`docs/design/ownership-v2.md` §2.1,
//! *An arrival's level*). A value described by its own place has no path from the supply's
//! root, so a result list carries the key in a field of its own (`Put.ResList.key`), and so does
//! a subscription (`Relation.Sub.key`), so a delivery later in the evaluation writes at the same
//! key. The key is never packed into another number: no count of supplies or keys can make two
//! lists one.
//!
//! Obligations kept here: none of §2.14's directly.

const std = @import("std");
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");

/// No key: the list's slots are the path's own.
pub const none: Slots.Rel = std.math.maxInt(u32);

/// The slot that path `q` writes in a list whose key is `key`, for `s` an `Eval.Sink`.
pub fn relAt(s: anytype, q: Ids.PathId, key: Slots.Rel) Slots.Error!Slots.Rel {
    const f = s.e.fr();
    const r = try f.slots.relOf(s.e.gpa(), f.account, f.places, q);
    if (key == none) return r;
    return f.slots.relOfWords(s.e.gpa(), f.account, f.places, try std.mem.concat(s.arena, u32, &.{ f.slots.relWords(key), f.slots.relWords(r) }));
}

/// A list's identity, as the read-off's memos key it: its label, supply and key, each whole.
pub fn ofList(label: u32, k: u32, key: Slots.Rel) [3]u32 {
    return .{ label, k, key };
}

test "lists past the old 16-bit boundary stay apart" {
    const gpa = std.testing.allocator;
    var seen: Ids.FixedDict(3) = .{};
    defer seen.deinit(gpa);
    // Packed as `k | (key + 1) << 16`, the first two pairs were one number, and the last two
    // lost the key's high bits.
    const lists = [_][2]u32{ .{ 1, none }, .{ 65_537, none }, .{ 0, 65_535 }, .{ 0, 131_071 }, .{ 65_536, 0 }, .{ 0, 0 } };
    for (lists) |l| try std.testing.expect(!(try seen.getOrPut(gpa, ofList(3, l[0], l[1]))).found_existing);
    try std.testing.expectEqual(@as(usize, lists.len), seen.count());
}
