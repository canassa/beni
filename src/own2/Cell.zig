//! L2: cells, the provenance labels of objects (`docs/design/ownership-v2.md`
//! §2.2, §3.2), and the persistent sets of them every shape, condition and
//! holder index is built over.
//!
//! **This file lands in two pieces.** This one is the set representation
//! §4.1 prescribes; the cell table itself — origins, kinds, labels, the
//! trie, interning, splits and `alias` — follows in the next pull request of
//! the same slice.
//!
//! **The persistent set** (`Radix`) is Okasaki–Gill's big-endian patricia
//! tree over `u32` keys (a `CellId`'s rank) with one value bit per key, the
//! `approx` of a `(cell, approx)` pair (§2.3): canonical — equal contents
//! have one structure — and hash-consed, so they have one id too, which is
//! what lets a shape node be interned by its set. An insert of a present key
//! and a union adding nothing return the ORIGINAL root (§4.1's idempotence,
//! what keeps a fixpoint from seeing a change where none is). A path copy
//! touches at most 33 nodes. The recursion in `unionWith` and `subset` is
//! bounded by the key width, 33 frames, a constant and not a function of
//! the input (R-7.12).
//!
//! **Values.** A pair's bit is 0 for exact, 1 for approximate. The join is
//! `and`: an exact pair wins over an approximate one (R-6.3: an exact
//! failure wins), so in the order `subset` tests, approximate ⊑ exact — a
//! set is below another when every key is there with a bit no larger.
//!
//! **Charging.** Every node made and every node a union, an insert or a
//! subset test INSPECTS is one record reserved in the caller's `Charge`
//! before the node is touched (§4.1: a union pays for the entries it visits,
//! not only the cells it adds; §4.4: reserve before set inspection). A set
//! that adds nothing still costs its inspections. The charge is the
//! caller's choice of lane or growth, made before the operation.
//!
//! Obligations kept here: O4 (a union is a union: `unionWith` adds every
//! key of both operands and drops none).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");

pub const SetId = Ids.SetId;
pub const Account = Ids.Account;
pub const Charge = Ids.Charge;
pub const Error = Ids.ChargeError;

// ---------------------------------------------------------------------------
// The persistent set: a big-endian patricia tree over u32 keys (§4.1)
// ---------------------------------------------------------------------------

/// A node: a leaf (`mask == 0`: `prefix` is the key, `left` the value bit)
/// or a branch (`mask` the branching bit, `prefix` the bits above it, the
/// keys with the bit clear in `left`, set in `right`).
pub const RadixNode = struct {
    prefix: u32,
    mask: u32,
    left: SetId,
    right: SetId,
};

pub const Radix = struct {
    nodes: std.MultiArrayList(RadixNode) = .empty,
    /// Hash-consing: equal contents have one canonical structure, and with
    /// every node interned by `(prefix, mask, left, right)` they have one
    /// id too.
    intern: Ids.FixedDict(4) = .{},

    pub fn deinit(r: *Radix, gpa: Allocator) void {
        r.nodes.deinit(gpa);
        r.intern.deinit(gpa);
    }

    inline fn node(r: *const Radix, id: SetId) RadixNode {
        return r.nodes.get(id.int());
    }

    /// One node, interned. The record is reserved BEFORE the dictionary is
    /// touched, so a refused reservation leaves no half-written entry; and
    /// it is reserved on a hit as well as a miss (§4.1: a request reserves
    /// its logical entry even when the physical node exists already, so
    /// what a request costs never depends on which owner built the node).
    fn make(r: *Radix, gpa: Allocator, charge: Charge, n: RadixNode) Error!SetId {
        try charge.reserve(gpa, .set, 1);
        const got = try r.intern.getOrPut(gpa, .{ n.prefix, n.mask, n.left.int(), n.right.int() });
        if (got.found_existing) return .from(got.value_ptr.*);
        const id: SetId = .from(@intCast(r.nodes.len));
        got.value_ptr.* = id.int();
        try r.nodes.append(gpa, n);
        return id;
    }

    /// Reserve one inspection record before reading a node (§4.4).
    inline fn inspect(gpa: Allocator, charge: Charge) Error!void {
        return charge.reserve(gpa, .inspection, 1);
    }

    inline fn matches(key: u32, prefix: u32, mask: u32) bool {
        return (key & ~((mask << 1) -% 1)) == prefix;
    }

    inline fn zeroBit(key: u32, mask: u32) bool {
        return key & mask == 0;
    }

    fn join(r: *Radix, gpa: Allocator, charge: Charge, p0: u32, t0: SetId, p1: u32, t1: SetId) Error!SetId {
        const diff = p0 ^ p1;
        // The highest differing bit.
        const mask = @as(u32, 1) << @intCast(31 - @clz(diff));
        const prefix = p0 & ~((mask << 1) -% 1);
        return if (zeroBit(p0, mask))
            r.make(gpa, charge, .{ .prefix = prefix, .mask = mask, .left = t0, .right = t1 })
        else
            r.make(gpa, charge, .{ .prefix = prefix, .mask = mask, .left = t1, .right = t0 });
    }

    /// The value bit of `key` in `root`, or null when absent. O(min(32,
    /// depth)) reads: a lookup is a fixed-key dictionary navigation, which
    /// §4.1 lets a task do without a record per comparison.
    pub fn get(r: *const Radix, root: SetId, key: u32) ?u1 {
        var at = root;
        while (at != .none) {
            const n = r.node(at);
            if (n.mask == 0) return if (n.prefix == key) @intCast(n.left.int()) else null;
            if (!matches(key, n.prefix, n.mask)) return null;
            at = if (zeroBit(key, n.mask)) n.left else n.right;
        }
        return null;
    }

    pub fn member(r: *const Radix, root: SetId, key: u32) bool {
        return r.get(root, key) != null;
    }

    /// `root` with `(key, value)`; the same root when it holds a pair at
    /// least as strong already. A present key's value is joined by `and`.
    /// Every node on the descent is one inspection; every node copied one
    /// record, ≤ 33 of each.
    pub fn insert(r: *Radix, gpa: Allocator, charge: Charge, root: SetId, key: u32, value: u1) Error!SetId {
        if (root == .none) return r.make(gpa, charge, .{ .prefix = key, .mask = 0, .left = .from(value), .right = .none });
        // Descend, remembering the path, then copy it back up.
        var path: [33]SetId = undefined;
        var depth: usize = 0;
        var at = root;
        var leaf_or_split: SetId = undefined;
        while (true) {
            try inspect(gpa, charge);
            const n = r.node(at);
            if (n.mask == 0) {
                if (n.prefix == key) {
                    const joined: u1 = @intCast(n.left.int() & value);
                    if (joined == @as(u1, @intCast(n.left.int()))) return root;
                    leaf_or_split = try r.make(gpa, charge, .{ .prefix = key, .mask = 0, .left = .from(joined), .right = .none });
                    break;
                }
                const new_leaf = try r.make(gpa, charge, .{ .prefix = key, .mask = 0, .left = .from(value), .right = .none });
                leaf_or_split = try r.join(gpa, charge, key, new_leaf, n.prefix, at);
                break;
            }
            if (!matches(key, n.prefix, n.mask)) {
                const new_leaf = try r.make(gpa, charge, .{ .prefix = key, .mask = 0, .left = .from(value), .right = .none });
                leaf_or_split = try r.join(gpa, charge, key, new_leaf, n.prefix, at);
                break;
            }
            path[depth] = at;
            depth += 1;
            at = if (zeroBit(key, n.mask)) n.left else n.right;
        }
        var child = leaf_or_split;
        while (depth > 0) {
            depth -= 1;
            const n = r.node(path[depth]);
            child = if (zeroBit(key, n.mask))
                try r.make(gpa, charge, .{ .prefix = n.prefix, .mask = n.mask, .left = child, .right = n.right })
            else
                try r.make(gpa, charge, .{ .prefix = n.prefix, .mask = n.mask, .left = n.left, .right = child });
        }
        return child;
    }

    /// `a ∪ b`, values joined by `and`. Returns `a` itself when `b` adds
    /// nothing (and `b` when `a` adds nothing to it), so a fixpoint sees no
    /// change where there is none. Every pair of nodes the merge inspects
    /// is one record reserved before it is read, whether or not anything is
    /// added (§4.1's zero-growth unions).
    pub fn unionWith(r: *Radix, gpa: Allocator, charge: Charge, a: SetId, b: SetId) Error!SetId {
        if (a == .none) return b;
        if (b == .none) return a;
        if (a == b) return a;
        try inspect(gpa, charge);
        const na = r.node(a);
        const nb = r.node(b);
        if (na.mask == 0) {
            if (nb.mask == 0 and na.prefix == nb.prefix) {
                const joined: u1 = @intCast(na.left.int() & nb.left.int());
                if (joined == @as(u1, @intCast(nb.left.int()))) return b;
                if (joined == @as(u1, @intCast(na.left.int()))) return a;
                return r.make(gpa, charge, .{ .prefix = na.prefix, .mask = 0, .left = .from(joined), .right = .none });
            }
            // A leaf into a set is an insert: `b` is the destination.
            return r.insert(gpa, charge, b, na.prefix, @intCast(na.left.int()));
        }
        if (nb.mask == 0) return r.insert(gpa, charge, a, nb.prefix, @intCast(nb.left.int()));
        if (na.mask == nb.mask and na.prefix == nb.prefix) {
            const l = try r.unionWith(gpa, charge, na.left, nb.left);
            const rt = try r.unionWith(gpa, charge, na.right, nb.right);
            if (l == na.left and rt == na.right) return a;
            if (l == nb.left and rt == nb.right) return b;
            return r.make(gpa, charge, .{ .prefix = na.prefix, .mask = na.mask, .left = l, .right = rt });
        }
        if (na.mask > nb.mask and matches(nb.prefix, na.prefix, na.mask)) {
            // `b` fits under one side of `a`.
            if (zeroBit(nb.prefix, na.mask)) {
                const l = try r.unionWith(gpa, charge, na.left, b);
                if (l == na.left) return a;
                return r.make(gpa, charge, .{ .prefix = na.prefix, .mask = na.mask, .left = l, .right = na.right });
            }
            const rt = try r.unionWith(gpa, charge, na.right, b);
            if (rt == na.right) return a;
            return r.make(gpa, charge, .{ .prefix = na.prefix, .mask = na.mask, .left = na.left, .right = rt });
        }
        if (nb.mask > na.mask and matches(na.prefix, nb.prefix, nb.mask)) {
            if (zeroBit(na.prefix, nb.mask)) {
                const l = try r.unionWith(gpa, charge, a, nb.left);
                if (l == nb.left) return b;
                return r.make(gpa, charge, .{ .prefix = nb.prefix, .mask = nb.mask, .left = l, .right = nb.right });
            }
            const rt = try r.unionWith(gpa, charge, a, nb.right);
            if (rt == nb.right) return b;
            return r.make(gpa, charge, .{ .prefix = nb.prefix, .mask = nb.mask, .left = nb.left, .right = rt });
        }
        return r.join(gpa, charge, na.prefix, a, nb.prefix, b);
    }

    /// `a ⊑ b`: every key of `a` is in `b` with a bit no larger (exact is
    /// above approximate, as the join says). Every node inspected is one
    /// record reserved first.
    pub fn subset(r: *const Radix, gpa: Allocator, charge: Charge, a: SetId, b: SetId) Error!bool {
        if (a == .none) return true;
        if (b == .none) return false;
        if (a == b) return true;
        try inspect(gpa, charge);
        const na = r.node(a);
        const nb = r.node(b);
        if (na.mask == 0) {
            const v = r.get(b, na.prefix) orelse return false;
            return v <= @as(u1, @intCast(na.left.int()));
        }
        if (nb.mask == 0) return false;
        if (na.mask == nb.mask and na.prefix == nb.prefix) return try r.subset(gpa, charge, na.left, nb.left) and try r.subset(gpa, charge, na.right, nb.right);
        if (nb.mask > na.mask and matches(na.prefix, nb.prefix, nb.mask)) {
            return r.subset(gpa, charge, a, if (zeroBit(na.prefix, nb.mask)) nb.left else nb.right);
        }
        return false;
    }

    /// The keys of `root` in ascending order, one per `next` — a leaf
    /// walk on an explicit stack of at most 33 entries. Iterating a whole
    /// set is the caller's charged task (§4.1).
    pub const Iterator = struct {
        radix: *const Radix,
        stack: [34]SetId = undefined,
        depth: usize = 0,

        pub const Entry = struct { key: u32, value: u1 };

        pub fn next(it: *Iterator) ?Entry {
            while (it.depth > 0) {
                it.depth -= 1;
                const id = it.stack[it.depth];
                const n = it.radix.node(id);
                if (n.mask == 0) return .{ .key = n.prefix, .value = @intCast(n.left.int()) };
                it.stack[it.depth] = n.right;
                it.stack[it.depth + 1] = n.left;
                it.depth += 2;
            }
            return null;
        }
    };

    pub fn iterate(r: *const Radix, root: SetId) Iterator {
        var it: Iterator = .{ .radix = r };
        if (root != .none) {
            it.stack[0] = root;
            it.depth = 1;
        }
        return it;
    }

    /// Every key of `root`, counted by walking it: a test instrument, not
    /// an operation an analysis may call (it is Θ(n)).
    pub fn count(r: *const Radix, root: SetId) u32 {
        var it = r.iterate(root);
        var n: u32 = 0;
        while (it.next() != null) n += 1;
        return n;
    }
};

comptime {
    Ids.assertRecord(RadixNode);
    std.debug.assert(@sizeOf(RadixNode) == 16);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the radix set is canonical, hash-consed, idempotent and ordered" {
    var r: Radix = .{};
    defer r.deinit(testing.allocator);
    var a: Account = .{};
    defer a.deinit(testing.allocator);
    const gpa = testing.allocator;
    const g: Charge = .growth(&a);
    var s: SetId = .none;
    const keys = [_]u32{ 5, 1_000_000, 3, 0, 0xFFFF_FFFF, 5, 17 };
    for (keys) |key| s = try r.insert(gpa, g, s, key, 0);
    try testing.expectEqual(@as(u32, 6), r.count(s));
    // Inserting a present key with an equal or weaker value is the same root.
    try testing.expectEqual(s, try r.insert(gpa, g, s, 3, 0));
    try testing.expectEqual(s, try r.insert(gpa, g, s, 3, 1));
    // An exact pair strengthens an approximate one, and that is a new root.
    var t: SetId = .none;
    t = try r.insert(gpa, g, t, 9, 1);
    try testing.expectEqual(@as(?u1, 1), r.get(t, 9));
    const t2 = try r.insert(gpa, g, t, 9, 0);
    try testing.expect(t2 != t);
    try testing.expectEqual(@as(?u1, 0), r.get(t2, 9));
    // Hash-consed: the same keys in another order are the same root.
    var u: SetId = .none;
    for ([_]u32{ 17, 0, 0xFFFF_FFFF, 3, 1_000_000, 5 }) |key| u = try r.insert(gpa, g, u, key, 0);
    try testing.expectEqual(s, u);
    try testing.expect(!try r.subset(gpa, g, t, s));
    // Ordered iteration.
    var it = r.iterate(s);
    var last: u64 = 0;
    var seen: u32 = 0;
    while (it.next()) |e| {
        if (seen > 0) try testing.expect(e.key > last);
        last = e.key;
        seen += 1;
    }
    try testing.expectEqual(@as(u32, 6), seen);
    try testing.expect(!r.member(s, 4) and r.member(s, 0) and r.member(s, 0xFFFF_FFFF));
}

test "subset orders values as the join does: approximate below exact" {
    var r: Radix = .{};
    defer r.deinit(testing.allocator);
    var a: Account = .{};
    defer a.deinit(testing.allocator);
    const gpa = testing.allocator;
    const g: Charge = .growth(&a);
    const approx = try r.insert(gpa, g, .none, 9, 1);
    const exact = try r.insert(gpa, g, .none, 9, 0);
    // The join picks exact.
    try testing.expectEqual(exact, try r.unionWith(gpa, g, approx, exact));
    try testing.expectEqual(exact, try r.unionWith(gpa, g, exact, approx));
    // So approximate ⊑ exact, and not the other way: `leq` agrees with `join`.
    try testing.expect(try r.subset(gpa, g, approx, exact));
    try testing.expect(!try r.subset(gpa, g, exact, approx));
    try testing.expect(try r.subset(gpa, g, approx, approx));
    // Over several keys the same.
    var big: SetId = .none;
    for ([_]u32{ 1, 9, 20 }) |k| big = try r.insert(gpa, g, big, k, 0);
    try testing.expect(try r.subset(gpa, g, approx, big));
    const big_approx = try r.insert(gpa, g, big, 9, 1); // weaker: unchanged
    try testing.expectEqual(big, big_approx);
}

test "a union adding nothing returns the destination root, and shares the larger operand" {
    var r: Radix = .{};
    defer r.deinit(testing.allocator);
    var a: Account = .{};
    defer a.deinit(testing.allocator);
    const gpa = testing.allocator;
    const g: Charge = .growth(&a);
    var big: SetId = .none;
    var i: u32 = 0;
    while (i < 64) : (i += 1) big = try r.insert(gpa, g, big, i * 3, 0);
    var small: SetId = .none;
    small = try r.insert(gpa, g, small, 9, 0);
    small = try r.insert(gpa, g, small, 30, 0);
    try testing.expectEqual(big, try r.unionWith(gpa, g, big, small));
    try testing.expectEqual(big, try r.unionWith(gpa, g, small, big));
    const before = r.nodes.len;
    var other: SetId = .none;
    other = try r.insert(gpa, g, other, 1, 0);
    const joined = try r.unionWith(gpa, g, big, other);
    try testing.expectEqual(@as(u32, 65), r.count(joined));
    // One path copied: at most 33 new nodes, plus the leaf.
    try testing.expect(r.nodes.len - before <= 34);
    // Every node was reserved (a hit as well, so at least one record per
    // node), and so was every inspection.
    try testing.expect(a.growth_by[@backingInt(Ids.Category.set)] >= @as(u32, @intCast(r.nodes.len)));
    try testing.expect(a.growth_by[@backingInt(Ids.Category.inspection)] > 0);
}

test "a union that adds nothing still pays its inspections, before it reads" {
    var r: Radix = .{};
    defer r.deinit(testing.allocator);
    var a: Account = .{};
    defer a.deinit(testing.allocator);
    const gpa = testing.allocator;
    var x: SetId = .none;
    var y: SetId = .none;
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        x = try r.insert(gpa, .growth(&a), x, i, 0);
        if (i % 2 == 0) y = try r.insert(gpa, .growth(&a), y, i, 0);
    }
    const before = a.growth;
    try testing.expectEqual(x, try r.unionWith(gpa, .growth(&a), x, y));
    try testing.expect(a.growth > before);
    // Exhaustion stops before any node is allocated or read.
    var tight: Account = .{ .allowance = 0 };
    defer tight.deinit(testing.allocator);
    const nodes = r.nodes.len;
    try testing.expectError(error.OwnershipLimit, r.unionWith(gpa, .growth(&tight), x, y));
    try testing.expectError(error.OwnershipLimit, r.insert(gpa, .growth(&tight), x, 100, 0));
    try testing.expectError(error.OwnershipLimit, r.subset(gpa, .growth(&tight), y, x));
    try testing.expectEqual(nodes, r.nodes.len);
    // In a lane, the inspections are baseline, not growth.
    var lane_account: Account = .{ .allowance = 0 };
    defer lane_account.deinit(testing.allocator);
    const lane: Ids.Lane = .{ .atom = 1, .role = .reach_index };
    try testing.expectEqual(x, try r.unionWith(gpa, .in(&lane_account, lane), x, y));
    try testing.expectEqual(@as(u32, 0), lane_account.growth);
    try testing.expect(lane_account.laneUsed(lane) > 0);
}

test "a refused reservation leaves the set table whole, and a hit is charged like a miss" {
    var r: Radix = .{};
    defer r.deinit(testing.allocator);
    const gpa = testing.allocator;
    var broke: Account = .{ .allowance = 0 };
    defer broke.deinit(gpa);
    try testing.expectError(error.OwnershipLimit, r.insert(gpa, .growth(&broke), .none, 42, 0));
    try testing.expectEqual(@as(usize, 0), r.nodes.len);
    // Another owner making the same node gets a real one, not the refused
    // owner's half-written entry.
    var a: Account = .{};
    defer a.deinit(gpa);
    const s = try r.insert(gpa, .growth(&a), .none, 42, 0);
    try testing.expectEqual(@as(usize, 1), r.nodes.len);
    try testing.expectEqual(@as(u32, 0), s.int());
    try testing.expect(r.member(s, 42));
    // The same node again is a hit, and the request is charged all the same
    // (§4.1: what a request costs never depends on who built the node).
    const before = a.growth;
    try testing.expectEqual(s, try r.insert(gpa, .growth(&a), .none, 42, 0));
    try testing.expectEqual(before + 1, a.growth);
}
