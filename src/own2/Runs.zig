//! L1: two tables the slot tables are made of (`docs/design/ownership-v2.md`
//! §3.2): runs of words interned by content, and a column of `u32` by a
//! dense path id.
//!
//! Obligations kept here: none of §2.14's (tables only).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");

const PathId = Ids.PathId;
const none: u32 = Ids.none_int;

/// Runs of words interned by content: a 64-bit hash names a chain, each
/// run once. Run 0 is the empty run. Each run is its own allocation in the
/// table's arena, so a run read stays valid while others are interned.
pub const Runs = struct {
    store: std.heap.ArenaAllocator.State = .{},
    runs: std.ArrayList([]const u32) = .empty,
    heads: Ids.FixedDict(2) = .{},
    next: std.ArrayList(u32) = .empty,

    pub fn deinit(r: *Runs, gpa: Allocator) void {
        r.store.promote(gpa).deinit();
        r.runs.deinit(gpa);
        r.heads.deinit(gpa);
        r.next.deinit(gpa);
    }

    pub fn ensureEmpty(r: *Runs, gpa: Allocator) Allocator.Error!void {
        if (r.runs.items.len != 0) return;
        try r.runs.append(gpa, &.{});
        try r.next.append(gpa, none);
    }

    pub fn get(r: *const Runs, id: u32) []const u32 {
        return r.runs.items[id];
    }

    pub fn intern(r: *Runs, gpa: Allocator, items: []const u32) Ids.IndexError!u32 {
        try r.ensureEmpty(gpa);
        if (items.len == 0) return 0;
        const h = std.hash.Wyhash.hash(0x51075, std.mem.sliceAsBytes(items));
        const key: [2]u32 = .{ @truncate(h), @truncate(h >> 32) };
        const got = try r.heads.getOrPut(gpa, key);
        if (got.found_existing) {
            var at = got.value_ptr.*;
            while (at != none) : (at = r.next.items[at]) if (std.mem.eql(u32, r.get(at), items)) return at;
        }
        const id: u32 = @intCast(r.runs.items.len);
        var arena = r.store.promote(gpa);
        const own = arena.allocator().dupe(u32, items);
        r.store = arena.state;
        try r.runs.append(gpa, try own);
        try r.next.append(gpa, if (got.found_existing) got.value_ptr.* else none);
        got.value_ptr.* = id;
        return id;
    }
};

/// A column of `u32` by a dense id, `none` where not filled.
pub const ByPath = struct {
    items: std.ArrayList(u32) = .empty,

    pub fn deinit(c: *ByPath, gpa: Allocator) void {
        c.items.deinit(gpa);
    }
    pub fn get(c: *const ByPath, p: PathId) ?u32 {
        const i = p.int();
        if (i >= c.items.items.len or c.items.items[i] == none) return null;
        return c.items.items[i];
    }
    pub fn put(c: *ByPath, gpa: Allocator, p: PathId, v: u32) Allocator.Error!void {
        const i = p.int();
        if (i >= c.items.items.len) try c.items.appendNTimes(gpa, none, i + 1 - c.items.items.len);
        c.items.items[i] = v;
    }
};
