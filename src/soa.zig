//! `Appender`: appends to a `std.MultiArrayList` through its column
//! addresses, computed once per growth instead of once per element.
//!
//! `MultiArrayList.append` ends in `set`, which recomputes every column's
//! address from the list's base first (`slice`). LLVM folds that away; Zig's
//! own backend, which builds the compiler the test suites run, does not, and
//! for the parser's and the lowerer's one-row-per-node lists it was a large
//! part of reading a wide file. The rows written are the same.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Appender(comptime T: type) type {
    return struct {
        const Self = @This();
        const List = std.MultiArrayList(T);

        /// The columns as of the last growth; stale whenever the list's
        /// storage or capacity no longer matches, and then read again.
        slice: List.Slice = .empty,
        bytes: ?[*]u8 = null,

        pub fn append(a: *Self, list: *List, gpa: Allocator, item: T) Allocator.Error!void {
            if (list.len == list.capacity) try list.ensureUnusedCapacity(gpa, 1);
            if (a.bytes != list.bytes or a.slice.capacity != list.capacity) {
                a.slice = list.slice();
                a.bytes = list.bytes;
            }
            const i = list.len;
            list.len = i + 1;
            a.slice.len = i + 1;
            if (@typeInfo(T) != .@"struct") return a.slice.set(i, item);
            // Each field straight to its column: `Slice.set` asks `items`
            // for every column's slice, one call per field per row.
            inline for (std.meta.fields(T), 0..) |field, f| {
                if (@sizeOf(field.type) != 0) {
                    const column: [*]field.type = @ptrCast(@alignCast(a.slice.ptrs[f]));
                    column[i] = @field(item, field.name);
                }
            }
        }
    };
}

test "an appender writes the rows append would, across growth" {
    const Row = struct { a: u32, b: u8, c: u64 };
    const gpa = std.testing.allocator;
    var list: std.MultiArrayList(Row) = .empty;
    defer list.deinit(gpa);
    var appender: Appender(Row) = .{};
    for (0..1000) |i| try appender.append(&list, gpa, .{ .a = @intCast(i), .b = @truncate(i), .c = i * 3 });
    try std.testing.expectEqual(@as(usize, 1000), list.len);
    for (0..1000) |i| try std.testing.expectEqual(Row{ .a = @intCast(i), .b = @truncate(i), .c = i * 3 }, list.get(i));
}
