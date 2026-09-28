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
