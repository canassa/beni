//! The fork of a cold pool (`docs/design/ownership-v2.md` §4.4, *The fork
//! of a cold pool*): a deep copy of a module's tables, and the deep
//! comparison the safety builds check a fork with.
//!
//! The copy is generic over the tables' types, so a field added later is
//! copied with the rest. A value with no pointer in it is copied bit for
//! bit. A list, a struct-of-arrays list, a bit set, a hash map and a pool
//! get their own storage. A pointer or slice is a compile error unless
//! `policy` names its field: memory the tables own (`owned`), memory
//! outside them (`alias`), a pointer into the module itself that the caller
//! wires again (`wired`), or a field that is null between two solves
//! (`idle`). A hash map in the tables is read by key and counted, never
//! iterated, so its copy keeps its entries and not their order.
//!
//! Obligations kept here: none of §2.14's. A fork changes no verdict: it
//! is the tables a rebuild would make (§4.4).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// How `With` copies and compares a field of a struct: `deep` for any field
/// without a pointer, a pointer is named.
pub const Policy = enum { deep, owned, alias, wired, idle };

/// Whether `T` holds no pointer: a bit-for-bit copy is a copy.
fn plain(comptime T: type) bool {
    @setEvalBranchQuota(100_000);
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .@"enum", .void, .enum_literal, .null => true,
        .optional => |o| plain(o.child),
        .array => |a| plain(a.child),
        .vector => true,
        .@"struct" => |s| inline for (s.field_types) |ft| {
            if (!plain(ft)) break false;
        } else true,
        .@"union" => |u| inline for (u.field_types) |ft| {
            if (!plain(ft)) break false;
        } else true,
        .error_set => true,
        else => false,
    };
}

fn named(comptime T: type, comptime prefix: []const u8) bool {
    return std.mem.startsWith(u8, @typeName(T), prefix);
}

/// A `std.HashMapUnmanaged`, whose name is its implementation's.
fn isHashMap(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "KV") and @hasField(T, "metadata") and @hasField(T, "available");
}

fn listElem(comptime T: type) type {
    return @typeInfo(@FieldType(T, "items")).pointer.child;
}

fn multiElem(comptime T: type) type {
    return @typeInfo(@TypeOf(T.get)).@"fn".return_type.?;
}

fn poolElem(comptime T: type) type {
    return @typeInfo(listElem(@FieldType(T, "all"))).pointer.child;
}

/// Copy and comparison under `policy`, which names every pointer field of
/// the tables' structs.
pub fn With(comptime policy: fn (comptime type, comptime []const u8) Policy) type {
    return struct {
        /// A deep copy of `src`.
        pub fn copy(comptime T: type, gpa: Allocator, src: *const T) Allocator.Error!T {
            @setEvalBranchQuota(100_000);
            if (comptime plain(T)) return src.*;
            if (T == Allocator) return src.*;
            if (comptime named(T, "array_list.Aligned(")) {
                const E = listElem(T);
                if (comptime plain(E)) return src.clone(gpa);
                var out = try T.initCapacity(gpa, src.capacity);
                for (src.items) |*x| out.appendAssumeCapacity(try copy(E, gpa, x));
                return out;
            }
            if (comptime isMulti(T)) {
                comptime std.debug.assert(plain(multiElem(T)));
                return src.clone(gpa);
            }
            if (T == std.DynamicBitSetUnmanaged) return src.clone(gpa);
            if (comptime isHashMap(T)) {
                var out = try src.clone(gpa);
                const K = @FieldType(T.KV, "key");
                if (K == []const u8) {
                    // `Stable.Store.keys` owns its key bytes.
                    var it = out.keyIterator();
                    while (it.next()) |k| k.* = try gpa.dupe(u8, k.*);
                } else comptime std.debug.assert(plain(K) and plain(@FieldType(T.KV, "value")));
                return out;
            }
            if (comptime named(T, "stamped.Pool(")) {
                const E = poolElem(T);
                var out: T = .{};
                try out.all.ensureTotalCapacity(gpa, src.all.capacity);
                try out.free.ensureTotalCapacity(gpa, src.free.capacity);
                for (src.all.items) |p| {
                    const n = try gpa.create(E);
                    n.* = try copy(E, gpa, p);
                    out.all.appendAssumeCapacity(n);
                }
                for (src.free.items) |p| {
                    const at = std.mem.indexOfScalar(*E, src.all.items, p).?;
                    out.free.appendAssumeCapacity(out.all.items[at]);
                }
                return out;
            }
            switch (@typeInfo(T)) {
                .@"struct" => |s| {
                    var out: T = undefined;
                    inline for (s.field_names, s.field_types, s.field_attrs) |n, ft, a| {
                        if (a.@"comptime") continue;
                        const from = &@field(src, n);
                        @field(out, n) = switch (comptime policy(T, n)) {
                            .deep => try copy(ft, gpa, from),
                            .owned => try ownedSlice(ft, gpa, from.*),
                            .alias, .wired => from.*,
                            .idle => idle: {
                                std.debug.assert(from.* == null);
                                break :idle null;
                            },
                        };
                    }
                    return out;
                },
                .optional => |o| return if (src.*) |*x| try copy(o.child, gpa, x) else null,
                .array => |a| {
                    var out: T = undefined;
                    for (&out, src) |*o, *x| o.* = try copy(a.child, gpa, x);
                    return out;
                },
                .@"union" => |u| {
                    if (u.tag_type == null) @compileError("own2.Fork: an untagged union with a pointer, " ++ @typeName(T));
                    switch (src.*) {
                        inline else => |*x, tag| return @unionInit(T, @tagName(tag), try copy(@TypeOf(x.*), gpa, x)),
                    }
                },
                else => @compileError("own2.Fork: a pointer no policy names, " ++ @typeName(T)),
            }
        }

        fn ownedSlice(comptime S: type, gpa: Allocator, src: S) Allocator.Error!S {
            const E = @typeInfo(S).pointer.child;
            const out = try gpa.alloc(E, src.len);
            for (out, src) |*o, *x| o.* = try copy(E, gpa, x);
            return out;
        }

        /// Whether `a` and `b` are the same tables: every entry a read can see
        /// (a stamped slot only while its stamp is live), every `alias` pointer
        /// the same, every `idle` field null. `wired` fields are not compared:
        /// `Groups` wires them the same way in every module.
        pub fn same(comptime T: type, a: *const T, b: *const T) bool {
            @setEvalBranchQuota(100_000);
            if (T == Allocator) return true;
            if (comptime named(T, "stamped.Column(")) {
                if (a.gen != b.gen or a.slots.items.len != b.slots.items.len) return false;
                for (a.slots.items, b.slots.items) |*x, *y| {
                    if (x.stamp != y.stamp) return false;
                    if (x.stamp == a.gen and !same(@TypeOf(x.value), &x.value, &y.value)) return false;
                }
                return true;
            }
            if (comptime named(T, "array_list.Aligned(")) {
                if (a.items.len != b.items.len) return false;
                for (a.items, b.items) |*x, *y| if (!same(listElem(T), x, y)) return false;
                return true;
            }
            if (comptime isMulti(T)) {
                if (a.len != b.len) return false;
                const E = multiElem(T);
                for (0..a.len) |i| {
                    const x = a.get(i);
                    const y = b.get(i);
                    if (!same(E, &x, &y)) return false;
                }
                return true;
            }
            if (T == std.DynamicBitSetUnmanaged) return a.eql(b.*);
            if (comptime isHashMap(T)) {
                if (a.count() != b.count()) return false;
                var it = a.iterator();
                while (it.next()) |e| {
                    const v = b.get(e.key_ptr.*) orelse return false;
                    if (!same(@TypeOf(v), e.value_ptr, &v)) return false;
                }
                return true;
            }
            if (comptime named(T, "stamped.Pool(")) {
                // Every pooled value is emptied when it is taken: only how many
                // there are is the pool's.
                return a.all.items.len == b.all.items.len and a.free.items.len == b.free.items.len;
            }
            switch (@typeInfo(T)) {
                .@"struct" => |s| {
                    if (s.layout == .@"packed") return @as(s.backing_integer.?, @bitCast(a.*)) == @as(s.backing_integer.?, @bitCast(b.*));
                    inline for (s.field_names, s.field_types, s.field_attrs) |n, ft, at| {
                        if (at.@"comptime") continue;
                        const x = &@field(a, n);
                        const y = &@field(b, n);
                        const ok = switch (comptime policy(T, n)) {
                            .deep => same(ft, x, y),
                            .owned => x.len == y.len and for (x.*, y.*) |*p, *q| {
                                if (!same(@TypeOf(p.*), p, q)) break false;
                            } else true,
                            .alias => x.* == y.*,
                            .wired => true,
                            .idle => x.* == null and y.* == null,
                        };
                        if (!ok) return false;
                    }
                    return true;
                },
                .optional => |o| {
                    if (a.* == null or b.* == null) return a.* == null and b.* == null;
                    return same(o.child, &a.*.?, &b.*.?);
                },
                .array => |r| {
                    for (a, b) |*x, *y| if (!same(r.child, x, y)) return false;
                    return true;
                },
                .@"union" => |u| {
                    if (u.tag_type == null) return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
                    if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
                    switch (a.*) {
                        inline else => |*x, tag| return same(@TypeOf(x.*), x, &@field(b.*, @tagName(tag))),
                    }
                },
                .pointer => |p| {
                    // A string key or other borrowed bytes: compared by content.
                    if (p.size == .slice and comptime plain(p.child)) return std.mem.eql(p.child, a.*, b.*);
                    @compileError("own2.Fork: a pointer no policy names, " ++ @typeName(T));
                },
                .int, .bool, .@"enum", .void, .error_set, .enum_literal => return a.* == b.*,
                .float => return @as(std.meta.Int(.unsigned, @bitSizeOf(T)), @bitCast(a.*)) == @as(std.meta.Int(.unsigned, @bitSizeOf(T)), @bitCast(b.*)),
                .vector => return @reduce(.And, a.* == b.*),
                else => @compileError("own2.Fork: cannot compare " ++ @typeName(T)),
            }
        }
    };
}

/// A `std.MultiArrayList`.
fn isMulti(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "bytes") and @hasField(T, "len") and @hasDecl(T, "Slice") and @hasDecl(T, "Field");
}
