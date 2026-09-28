//! A hash map context for keys that are one small integer — an `enum(u32)`
//! id or a `u32` — hashed by one multiplication.
//!
//! `std`'s `AutoContext` runs Wyhash over the key's bytes, and in the
//! checker's per-field and per-entry tables that hash was most of the
//! lookup. For a small integer the product's low bits (the slot) are a
//! permutation of the key's, and its high bits (`std`'s fingerprint) mix
//! all of them. A map's iteration order follows its hash, so a table read
//! in iteration order for anything observable keeps `std`'s context.

const std = @import("std");

pub fn Context(comptime K: type) type {
    return struct {
        pub fn hash(_: @This(), key: K) u64 {
            return @as(u64, toInt(key)) *% 0x9E37_79B9_7F4A_7C15;
        }

        pub fn eql(_: @This(), a: K, b: K) bool {
            return a == b;
        }

        fn toInt(key: K) u32 {
            return switch (@typeInfo(K)) {
                .@"enum" => @intFromEnum(key),
                else => key,
            };
        }
    };
}

/// A hash map keyed by `K` under `Context(K)`.
pub fn Map(comptime K: type, comptime V: type) type {
    return std.HashMapUnmanaged(K, V, Context(K), std.hash_map.default_max_load_percentage);
}

test "an id and a u32 hash apart and compare by value" {
    const Id = enum(u32) { _ };
    var map: Map(Id, u32) = .empty;
    defer map.deinit(std.testing.allocator);
    for (0..1000) |i| try map.put(std.testing.allocator, @enumFromInt(i), @intCast(i * 2));
    for (0..1000) |i| try std.testing.expectEqual(@as(u32, @intCast(i * 2)), map.get(@enumFromInt(i)).?);
    try std.testing.expectEqual(null, map.get(@enumFromInt(1000)));
}
