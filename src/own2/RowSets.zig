//! L0: a record's row steps' sets of excluded names (`docs/design/ownership-v2.md`
//! §2.1, *The row of a record*): each set of field ranks, sorted and interned
//! by content, and how a place's graph and a block write and read one.
//!
//! Obligations kept here: none of §2.14's (a table only).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const RowSets = struct {
    /// A run is its own allocation, so one read stays valid while others are interned.
    sets: std.ArrayList([]const u32) = .empty,
    of: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn deinit(r: *RowSets, gpa: Allocator) void {
        for (r.sets.items) |s| gpa.free(s);
        r.sets.deinit(gpa);
        r.of.deinit(gpa);
    }

    /// The index of the sorted set `ranks`, interned.
    pub fn intern(r: *RowSets, gpa: Allocator, ranks: []const u32) Allocator.Error!u32 {
        if (r.of.get(std.mem.sliceAsBytes(ranks))) |i| return i;
        const own = try gpa.dupe(u32, ranks);
        errdefer gpa.free(own);
        try r.sets.append(gpa, own);
        try r.of.put(gpa, std.mem.sliceAsBytes(own), @intCast(r.sets.items.len - 1));
        return @intCast(r.sets.items.len - 1);
    }

    pub fn names(r: *const RowSets, i: u32) []const u32 {
        return r.sets.items[i];
    }
};

/// A row step's names into a block's or a graph's words: a count, then each through `field`.
pub fn write(gpa: Allocator, out: *std.ArrayList(u32), ns: []const u32, ctx: anytype, field: anytype) Allocator.Error!void {
    try out.append(gpa, @intCast(ns.len));
    for (ns) |x| try out.append(gpa, field(ctx, x));
}

/// Written names read back through `field`, as a sorted set the caller frees.
pub fn mapped(gpa: Allocator, ns: []const u32, ctx: anytype, field: anytype) Allocator.Error![]u32 {
    const out = try gpa.dupe(u32, ns);
    for (out) |*x| x.* = field(ctx, x.*);
    std.mem.sort(u32, out, {}, std.sort.asc(u32));
    return out;
}
