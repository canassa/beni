//! `push`: `std.ArrayList.append` for the compiler's hottest lists — a
//! variable pool, a walk's stack — written so the common case costs no call.
//!
//! `append` is three calls deep (`addOne`, `ensureTotalCapacity`,
//! `addOneAssumeCapacity`), and Zig's own backend, which builds the compiler
//! the test suites run, inlines none of them: on a record of 65 537 fields
//! the appends to the pools and stacks were a tenth of solving it. Growth
//! still goes through `append`, so what the list holds is the same.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub inline fn push(comptime T: type, list: *std.ArrayList(T), gpa: Allocator, item: T) Allocator.Error!void {
    if (list.items.len < list.capacity) {
        list.items.len += 1;
        list.items[list.items.len - 1] = item;
    } else try list.append(gpa, item);
}

test "push appends in order, growing as append does" {
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(std.testing.allocator);
    for (0..100) |i| try push(u32, &list, std.testing.allocator, @intCast(i));
    for (list.items, 0..) |item, i| try std.testing.expectEqual(@as(u32, @intCast(i)), item);
}

/// `push` with the element type read off the list: `list` is a pointer to
/// an `std.ArrayList`.
pub inline fn add(list: anytype, gpa: Allocator, item: @TypeOf(list.items[0])) Allocator.Error!void {
    if (list.items.len < list.capacity) {
        list.items.len += 1;
        list.items[list.items.len - 1] = item;
    } else try list.append(gpa, item);
}

test "add appends in order, growing as append does" {
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(std.testing.allocator);
    for (0..100) |i| try add(&list, std.testing.allocator, @intCast(i));
    for (list.items, 0..) |item, i| try std.testing.expectEqual(@as(u32, @intCast(i)), item);
}

/// `list.pop()` without a call: the last item, removed, or null.
pub inline fn pop(list: anytype) ?@TypeOf(list.items[0]) {
    if (list.items.len == 0) return null;
    list.items.len -= 1;
    return list.items.ptr[list.items.len];
}

/// `list.appendSlice`, with the common case, room already there, copied
/// without a call.
pub inline fn addSlice(list: anytype, gpa: Allocator, items: []const @TypeOf(list.items[0])) Allocator.Error!void {
    if (list.capacity - list.items.len >= items.len) {
        const at = list.items.len;
        list.items.len += items.len;
        @memcpy(list.items[at..], items);
    } else try list.appendSlice(gpa, items);
}

test "pop and addSlice agree with the list's own" {
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(std.testing.allocator);
    for (0..40) |i| try addSlice(&list, std.testing.allocator, &.{ @intCast(i), @intCast(i + 1) });
    try std.testing.expectEqual(@as(usize, 80), list.items.len);
    try std.testing.expectEqual(@as(?u32, 40), pop(&list));
    try std.testing.expectEqual(@as(usize, 79), list.items.len);
    list.clearRetainingCapacity();
    try std.testing.expectEqual(@as(?u32, null), pop(&list));
}
