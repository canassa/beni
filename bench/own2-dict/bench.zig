//! Replays the real operation traces of the ownership checker v2's dictionaries
//! against three layouts, and prints ns per operation (best of 5): the crit-bit
//! `Ids.FixedDict` as it is, an open-addressing index of entry indices over
//! dense key arrays, and a per-key-0 chain. Record the traces with
//! `-Downership-v2-counters -Downership-v2-trace=<dir>` (see README.md).
//!
//!     zig build-exe -OReleaseFast bench.zig -femit-bin=/path/own2-dict
//!     zig build-exe -OReleaseFast -fno-llvm bench.zig ...   # the self-hosted backend
//!     own2-dict <dir>/shapes.memo_proj.k2 <dir>/cells.sets.intern.k4 ...
//!
//! A trace file is `u32` records: a tag (0 a get, anything else a put) and the
//! key's `k` words, `k` read from the `.k<k>` at the end of the file name. A
//! layout that does not fit a key is not an answer (key 0 is a kind or flag
//! for `shapes.intern`, so the by-key0 chains are as long as the table). Not a
//! gate: nothing runs it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const none_int: u32 = std.math.maxInt(u32);

// Ids.FixedDict as on master (81d3b8bfd), stats stripped.
pub fn FixedDict(comptime k: usize) type {
    return struct {
        nodes: std.ArrayList(Node) = .empty,
        keys: std.ArrayList(u32) = .empty,
        values: std.ArrayList(u32) = .empty,
        root: u32 = none_int,
        const Self = @This();
        pub const Key = [k]u32;
        const Node = struct { crit: u32, left: u32, right: u32 };
        const leaf_crit: u32 = none_int;
        inline fn bitOf(key: Key, crit: u32) u1 {
            return @intCast((key[crit / 32] >> @intCast(31 - crit % 32)) & 1);
        }
        fn keyAt(d: *const Self, leaf: u32) Key {
            return d.keys.items[leaf * k ..][0..k].*;
        }
        fn descend(d: *const Self, key: Key) u32 {
            var at = d.root;
            if (at == none_int) return none_int;
            const ns = d.nodes.items;
            while (ns[at].crit != leaf_crit) at = if (bitOf(key, ns[at].crit) == 0) ns[at].left else ns[at].right;
            return ns[at].left;
        }
        pub fn get(d: *const Self, key: Key) ?u32 {
            const leaf = d.descend(key);
            if (leaf == none_int or !std.mem.eql(u32, &d.keyAt(leaf), &key)) return null;
            return d.values.items[leaf];
        }
        pub fn getOrPut(d: *Self, gpa: Allocator, key: Key) Allocator.Error!*u32 {
            const leaf = d.descend(key);
            if (leaf != none_int and std.mem.eql(u32, &d.keyAt(leaf), &key)) return &d.values.items[leaf];
            const new_leaf: u32 = @intCast(d.values.items.len);
            try d.keys.appendSlice(gpa, &key);
            try d.values.append(gpa, undefined);
            try d.nodes.ensureUnusedCapacity(gpa, 2);
            const leaf_node: u32 = @intCast(d.nodes.items.len);
            d.nodes.appendAssumeCapacity(.{ .crit = leaf_crit, .left = new_leaf, .right = none_int });
            if (leaf == none_int) {
                d.root = leaf_node;
                return &d.values.items[new_leaf];
            }
            const other = d.keyAt(leaf);
            var crit: u32 = 0;
            while (crit / 32 < k and bitOf(other, crit) == bitOf(key, crit)) crit += 1;
            var parent: u32 = none_int;
            var at = d.root;
            while (d.nodes.items[at].crit != leaf_crit and d.nodes.items[at].crit < crit) {
                parent = at;
                const n = d.nodes.items[at];
                at = if (bitOf(key, n.crit) == 0) n.left else n.right;
            }
            const branch: u32 = @intCast(d.nodes.items.len);
            const new_bit = bitOf(key, crit);
            d.nodes.appendAssumeCapacity(.{ .crit = crit, .left = if (new_bit == 0) leaf_node else at, .right = if (new_bit == 0) at else leaf_node });
            if (parent == none_int) {
                d.root = branch;
            } else if (d.nodes.items[parent].left == at) {
                d.nodes.items[parent].left = branch;
            } else {
                d.nodes.items[parent].right = branch;
            }
            return &d.values.items[new_leaf];
        }
    };
}

/// Open addressing, linear probing, power-of-two table of u32 slot indices
/// into dense key/value arrays (Zig InternPool style: the map stores only
/// indices; keys live in the dense table). Deterministic: fixed hash.
pub fn Flat(comptime k: usize) type {
    return struct {
        slots: []u32 = &.{},
        keys: std.ArrayList(u32) = .empty,
        values: std.ArrayList(u32) = .empty,
        const Self = @This();
        const Key = [k]u32;
        fn hash(key: Key) u32 {
            var h: u64 = 0x9E3779B97F4A7C15;
            inline for (key) |w| h = (h ^ w) *% 0xff51afd7ed558ccd;
            return @truncate(h ^ (h >> 32));
        }
        fn grow(d: *Self, gpa: Allocator) !void {
            const n = if (d.slots.len == 0) 64 else d.slots.len * 2;
            gpa.free(d.slots);
            d.slots = try gpa.alloc(u32, n);
            @memset(d.slots, none_int);
            const mask: u32 = @intCast(n - 1);
            for (0..d.values.items.len) |i| {
                var s = hash(d.keys.items[i * k ..][0..k].*) & mask;
                while (d.slots[s] != none_int) s = (s + 1) & mask;
                d.slots[s] = @intCast(i);
            }
        }
        pub fn get(d: *const Self, key: Key) ?u32 {
            if (d.slots.len == 0) return null;
            const mask: u32 = @intCast(d.slots.len - 1);
            var s = hash(key) & mask;
            while (true) : (s = (s + 1) & mask) {
                const i = d.slots[s];
                if (i == none_int) return null;
                if (std.mem.eql(u32, d.keys.items[i * k ..][0..k], &key)) return d.values.items[i];
            }
        }
        pub fn getOrPut(d: *Self, gpa: Allocator, key: Key) !*u32 {
            if ((d.values.items.len + 1) * 4 > d.slots.len * 3) try d.grow(gpa);
            const mask: u32 = @intCast(d.slots.len - 1);
            var s = hash(key) & mask;
            while (true) : (s = (s + 1) & mask) {
                const i = d.slots[s];
                if (i == none_int) break;
                if (std.mem.eql(u32, d.keys.items[i * k ..][0..k], &key)) return &d.values.items[i];
            }
            const i: u32 = @intCast(d.values.items.len);
            try d.keys.appendSlice(gpa, &key);
            try d.values.append(gpa, 0);
            d.slots[s] = i;
            return &d.values.items[i];
        }
    };
}

fn now() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn run(comptime D: type, comptime k: usize, gpa: Allocator, ops: []const u32) !struct { ns: u64, sink: u64 } {
    var d: D = .{};
    var sink: u64 = 0;
    const t0 = now();
    var i: usize = 0;
    while (i < ops.len) : (i += k + 1) {
        const key: [k]u32 = ops[i + 1 ..][0..k].*;
        if (ops[i] == 0) {
            if (d.get(key)) |v| sink +%= v;
        } else {
            const p = try d.getOrPut(gpa, key);
            p.* = @truncate(i);
        }
    }
    return .{ .ns = now() - t0, .sink = sink };
}

/// The dense alternative where key[0] is a dense id: a column indexed by
/// key[0] holding the head of a short chain of entries with that key[0].
fn Chained(comptime k: usize) type {
    return struct {
        head: std.ArrayList(u32) = .empty,
        next: std.ArrayList(u32) = .empty,
        keys: std.ArrayList(u32) = .empty,
        values: std.ArrayList(u32) = .empty,
        const Self = @This();
        pub fn get(d: *const Self, key: [k]u32) ?u32 {
            if (key[0] >= d.head.items.len) return null;
            var e = d.head.items[key[0]];
            while (e != none_int) : (e = d.next.items[e]) {
                if (std.mem.eql(u32, d.keys.items[e * k ..][0..k], &key)) return d.values.items[e];
            }
            return null;
        }
        pub fn getOrPut(d: *Self, gpa: Allocator, key: [k]u32) !*u32 {
            if (key[0] >= d.head.items.len) try d.head.appendNTimes(gpa, none_int, key[0] + 1 - d.head.items.len);
            var e = d.head.items[key[0]];
            while (e != none_int) : (e = d.next.items[e]) {
                if (std.mem.eql(u32, d.keys.items[e * k ..][0..k], &key)) return &d.values.items[e];
            }
            const i: u32 = @intCast(d.values.items.len);
            try d.keys.appendSlice(gpa, &key);
            try d.values.append(gpa, 0);
            try d.next.append(gpa, d.head.items[key[0]]);
            d.head.items[key[0]] = i;
            return &d.values.items[i];
        }
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |path| {
        const kpos = std.mem.lastIndexOf(u8, path, ".k").?;
        const kc = path[kpos + 2];
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .unlimited);
        const ops = std.mem.bytesAsSlice(u32, @as([]align(4) u8, @alignCast(bytes)));
        switch (kc) {
            inline '1', '2', '3', '4', '5' => |c| {
                const k = c - '0';
                const n = ops.len / (k + 1);
                // key[0] spread: max value and the longest chain
                var maxk0: u32 = 0;
                var i: usize = 0;
                while (i < ops.len) : (i += k + 1) maxk0 = @max(maxk0, ops[i + 1]);
                var best = [3]u64{ std.math.maxInt(u64), std.math.maxInt(u64), std.math.maxInt(u64) };
                for (0..5) |_| {
                    best[0] = @min(best[0], (try run(FixedDict(k), k, gpa, ops)).ns);
                    best[1] = @min(best[1], (try run(Flat(k), k, gpa, ops)).ns);
                    best[2] = @min(best[2], (try run(Chained(k), k, gpa, ops)).ns);
                }
                std.debug.print("{s}\tops={d}\tmax_key0={d}\tcritbit={d:.1}ns/op\topen-addr={d:.1}ns/op\tby-key0={d:.1}ns/op\n", .{ std.fs.path.basename(path), n, maxk0, @as(f64, @floatFromInt(best[0])) / @as(f64, @floatFromInt(n)), @as(f64, @floatFromInt(best[1])) / @as(f64, @floatFromInt(n)), @as(f64, @floatFromInt(best[2])) / @as(f64, @floatFromInt(n)) });
            },
            else => unreachable,
        }
        gpa.free(bytes);
    }
}
