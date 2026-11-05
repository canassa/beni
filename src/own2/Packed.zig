//! Versioned ownership-v2 rows in the embedded core/platform pack
//! (`fast-compiler.md` §8, *Ownership v2 beside v1*). Ordinary entries
//! retain their v1 block; this envelope is the only packed input to v2.
//!
//! Obligations kept here: none (pack envelope validation).
const std = @import("std");
const Block = @import("Block.zig");

pub const magic = "BENIOW2\x00";
pub const version: u32 = 1;
const header_len = 20;

pub fn write(gpa: std.mem.Allocator, block: []const u8) std.mem.Allocator.Error![]u8 {
    const bytes = try gpa.alloc(u8, header_len + block.len);
    @memcpy(bytes[0..8], magic);
    std.mem.writeInt(u32, bytes[8..12], version, .little);
    std.mem.writeInt(u32, bytes[12..16], Block.version, .little);
    std.mem.writeInt(u32, bytes[16..20], @intCast(block.len), .little);
    @memcpy(bytes[header_len..], block);
    return bytes;
}

/// Empty is a current row that publishes no classes. Null means a row
/// that cannot be used, before any block decoder or remapping runs.
pub fn read(bytes: []const u8) ?[]const u8 {
    if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..8], magic)) return null;
    if (std.mem.readInt(u32, bytes[8..12], .little) != version) return null;
    if (std.mem.readInt(u32, bytes[12..16], .little) != Block.version) return null;
    const len = std.mem.readInt(u32, bytes[16..20], .little);
    if (len != bytes.len - header_len or len % 4 != 0) return null;
    return bytes[header_len..];
}

test "packed v2 ownership rejects v1, stale versions and incomplete rows" {
    const gpa = std.testing.allocator;
    const row = try write(gpa, &.{ 1, 2, 3, 4 });
    defer gpa.free(row);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, read(row).?);
    try std.testing.expect(read("v1 ownership") == null);
    try std.testing.expect(read(row[0 .. row.len - 1]) == null);
    std.mem.writeInt(u32, row[8..12], version - 1, .little);
    try std.testing.expect(read(row) == null);
    std.mem.writeInt(u32, row[8..12], version, .little);
    std.mem.writeInt(u32, row[12..16], Block.version - 1, .little);
    try std.testing.expect(read(row) == null);
    const empty = try write(gpa, &.{});
    defer gpa.free(empty);
    try std.testing.expectEqual(@as(usize, 0), read(empty).?.len);
}

test "fuzz packed v2 ownership envelope" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var bytes: [4096]u8 = undefined;
            const len = smith.sliceWithHash(&bytes, 0xbed1823);
            _ = read(bytes[0..len]);
        }
    }.one, .{});
}
