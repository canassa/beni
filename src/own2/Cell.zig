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
//! have one structure — so an insert of a present key and a union adding
//! nothing return the ORIGINAL root (§4.1's idempotence, what keeps a
//! fixpoint from seeing a change where none is). A path copy touches at most
//! 33 nodes, and every node made is one growth record reserved before it is
//! made. The recursion in `unionWith` and `subset` is bounded by the key
//! width, 33 frames, a constant and not a function of the input (R-7.12).
//! A pair's value joins by `and`: an exact pair wins over an approximate one
//! (R-6.3: an exact failure wins).
//!
//! Obligations kept here: O4 (a union is a union: `unionWith` adds every
//! key of both operands and drops none).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");

pub const SetId = Ids.SetId;
pub const Account = Ids.Account;

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

    pub const Error = Allocator.Error || error{OwnershipLimit};

    pub fn deinit(r: *Radix, gpa: Allocator) void {
        r.nodes.deinit(gpa);
    }

    inline fn node(r: *const Radix, id: SetId) RadixNode {
        return r.nodes.get(id.int());
    }

    fn make(r: *Radix, gpa: Allocator, account: *Account, n: RadixNode) Error!SetId {
        try account.reserve(.set, 1);
        const id: SetId = .from(@intCast(r.nodes.len));
        try r.nodes.append(gpa, n);
        return id;
    }

    inline fn matches(key: u32, prefix: u32, mask: u32) bool {
        return (key & ~((mask << 1) -% 1)) == prefix;
    }

    inline fn zeroBit(key: u32, mask: u32) bool {
        return key & mask == 0;
    }

    fn join(r: *Radix, gpa: Allocator, account: *Account, p0: u32, t0: SetId, p1: u32, t1: SetId) Error!SetId {
        const diff = p0 ^ p1;
        // The highest differing bit.
        const mask = @as(u32, 1) << @intCast(31 - @clz(diff));
        const prefix = p0 & ~((mask << 1) -% 1);
        return if (zeroBit(p0, mask))
            r.make(gpa, account, .{ .prefix = prefix, .mask = mask, .left = t0, .right = t1 })
        else
            r.make(gpa, account, .{ .prefix = prefix, .mask = mask, .left = t1, .right = t0 });
    }

    /// The value bit of `key` in `root`, or null when absent. O(min(32, depth)).
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

    /// `root` with `(key, value)`; the same root when it holds the pair
    /// already. A present key's value is joined by `join_value`: the result
    /// is `value` where it differs, so an exact pair wins over an
    /// approximate one when `join_value` is `and`.
    pub fn insert(r: *Radix, gpa: Allocator, account: *Account, root: SetId, key: u32, value: u1) Error!SetId {
        if (root == .none) return r.make(gpa, account, .{ .prefix = key, .mask = 0, .left = .from(value), .right = .none });
        // Descend, remembering the path, then copy it back up.
        var path: [33]SetId = undefined;
        var depth: usize = 0;
        var at = root;
        var leaf_or_split: SetId = undefined;
        while (true) {
            const n = r.node(at);
            if (n.mask == 0) {
                if (n.prefix == key) {
                    const joined: u1 = @intCast(n.left.int() & value);
                    if (joined == @as(u1, @intCast(n.left.int()))) return root;
                    leaf_or_split = try r.make(gpa, account, .{ .prefix = key, .mask = 0, .left = .from(joined), .right = .none });
                    break;
                }
                const new_leaf = try r.make(gpa, account, .{ .prefix = key, .mask = 0, .left = .from(value), .right = .none });
                leaf_or_split = try r.join(gpa, account, key, new_leaf, n.prefix, at);
                break;
            }
            if (!matches(key, n.prefix, n.mask)) {
                const new_leaf = try r.make(gpa, account, .{ .prefix = key, .mask = 0, .left = .from(value), .right = .none });
                leaf_or_split = try r.join(gpa, account, key, new_leaf, n.prefix, at);
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
                try r.make(gpa, account, .{ .prefix = n.prefix, .mask = n.mask, .left = child, .right = n.right })
            else
                try r.make(gpa, account, .{ .prefix = n.prefix, .mask = n.mask, .left = n.left, .right = child });
        }
        return child;
    }

    /// `a ∪ b`, values joined by `and`. Returns `a` itself when `b` adds
    /// nothing (and `b` when `a` adds nothing to it), so a fixpoint sees no
    /// change where there is none. Every node of both operands that the
    /// merge inspects is work §4.1 charges: `inspected` counts them.
    pub fn unionWith(r: *Radix, gpa: Allocator, account: *Account, a: SetId, b: SetId, inspected: *u32) Error!SetId {
        if (a == .none) return b;
        if (b == .none) return a;
        if (a == b) return a;
        inspected.* += 1;
        const na = r.node(a);
        const nb = r.node(b);
        if (na.mask == 0) {
            if (nb.mask == 0 and na.prefix == nb.prefix) {
                const joined: u1 = @intCast(na.left.int() & nb.left.int());
                if (joined == @as(u1, @intCast(nb.left.int()))) return b;
                if (joined == @as(u1, @intCast(na.left.int()))) return a;
                return r.make(gpa, account, .{ .prefix = na.prefix, .mask = 0, .left = .from(joined), .right = .none });
            }
            // A leaf into a set is an insert: `b` is the destination.
            const out = try r.insert(gpa, account, b, na.prefix, @intCast(na.left.int()));
            return out;
        }
        if (nb.mask == 0) return r.insert(gpa, account, a, nb.prefix, @intCast(nb.left.int()));
        if (na.mask == nb.mask and na.prefix == nb.prefix) {
            const l = try r.unionWith(gpa, account, na.left, nb.left, inspected);
            const rt = try r.unionWith(gpa, account, na.right, nb.right, inspected);
            if (l == na.left and rt == na.right) return a;
            if (l == nb.left and rt == nb.right) return b;
            return r.make(gpa, account, .{ .prefix = na.prefix, .mask = na.mask, .left = l, .right = rt });
        }
        if (na.mask > nb.mask and matches(nb.prefix, na.prefix, na.mask)) {
            // `b` fits under one side of `a`.
            if (zeroBit(nb.prefix, na.mask)) {
                const l = try r.unionWith(gpa, account, na.left, b, inspected);
                if (l == na.left) return a;
                return r.make(gpa, account, .{ .prefix = na.prefix, .mask = na.mask, .left = l, .right = na.right });
            }
            const rt = try r.unionWith(gpa, account, na.right, b, inspected);
            if (rt == na.right) return a;
            return r.make(gpa, account, .{ .prefix = na.prefix, .mask = na.mask, .left = na.left, .right = rt });
        }
        if (nb.mask > na.mask and matches(na.prefix, nb.prefix, nb.mask)) {
            if (zeroBit(na.prefix, nb.mask)) {
                const l = try r.unionWith(gpa, account, a, nb.left, inspected);
                if (l == nb.left) return b;
                return r.make(gpa, account, .{ .prefix = nb.prefix, .mask = nb.mask, .left = l, .right = nb.right });
            }
            const rt = try r.unionWith(gpa, account, a, nb.right, inspected);
            if (rt == nb.right) return b;
            return r.make(gpa, account, .{ .prefix = nb.prefix, .mask = nb.mask, .left = nb.left, .right = rt });
        }
        return r.join(gpa, account, na.prefix, a, nb.prefix, b);
    }

    /// Whether every key of `a` is in `b` with a value at least as strong
    /// (exact ⊑ approximate: `b`'s bit ≥ `a`'s). Charged per node inspected.
    pub fn subset(r: *const Radix, a: SetId, b: SetId, inspected: *u32) bool {
        if (a == .none) return true;
        if (b == .none) return false;
        if (a == b) return true;
        inspected.* += 1;
        const na = r.node(a);
        const nb = r.node(b);
        if (na.mask == 0) {
            const v = r.get(b, na.prefix) orelse return false;
            return v >= @as(u1, @intCast(na.left.int()));
        }
        if (nb.mask == 0) return false;
        if (na.mask == nb.mask and na.prefix == nb.prefix) return r.subset(na.left, nb.left, inspected) and r.subset(na.right, nb.right, inspected);
        if (nb.mask > na.mask and matches(na.prefix, nb.prefix, nb.mask)) {
            return r.subset(a, if (zeroBit(na.prefix, nb.mask)) nb.left else nb.right, inspected);
        }
        return false;
    }

    /// The keys of `root` in ascending order, one per `next` — a leaf
    /// walk on an explicit stack of at most 33 entries.
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

test "the radix set is canonical, idempotent and ordered" {
    var r: Radix = .{};
    defer r.deinit(testing.allocator);
    var a: Account = .{};
    defer a.deinit(testing.allocator);
    const gpa = testing.allocator;
    var s: SetId = .none;
    const keys = [_]u32{ 5, 1_000_000, 3, 0, 0xFFFF_FFFF, 5, 17 };
    for (keys) |key| s = try r.insert(gpa, &a, s, key, 0);
    try testing.expectEqual(@as(u32, 6), r.count(s));
    // Inserting a present key with an equal or weaker value is the same root.
    try testing.expectEqual(s, try r.insert(gpa, &a, s, 3, 0));
    try testing.expectEqual(s, try r.insert(gpa, &a, s, 3, 1));
    // An exact pair strengthens an approximate one, and that is a new root.
    var t: SetId = .none;
    t = try r.insert(gpa, &a, t, 9, 1);
    try testing.expectEqual(@as(?u1, 1), r.get(t, 9));
    const t2 = try r.insert(gpa, &a, t, 9, 0);
    try testing.expect(t2 != t);
    try testing.expectEqual(@as(?u1, 0), r.get(t2, 9));
    // Canonical: the same keys in another order give an equal set that `subset` accepts both ways.
    var u: SetId = .none;
    for ([_]u32{ 17, 0, 0xFFFF_FFFF, 3, 1_000_000, 5 }) |key| u = try r.insert(gpa, &a, u, key, 0);
    var inspected: u32 = 0;
    try testing.expect(r.subset(s, u, &inspected) and r.subset(u, s, &inspected));
    try testing.expect(!r.subset(t, s, &inspected));
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

test "a union adding nothing returns the destination root, and shares the larger operand" {
    var r: Radix = .{};
    defer r.deinit(testing.allocator);
    var a: Account = .{};
    defer a.deinit(testing.allocator);
    const gpa = testing.allocator;
    var big: SetId = .none;
    var i: u32 = 0;
    while (i < 64) : (i += 1) big = try r.insert(gpa, &a, big, i * 3, 0);
    var small: SetId = .none;
    small = try r.insert(gpa, &a, small, 9, 0);
    small = try r.insert(gpa, &a, small, 30, 0);
    var inspected: u32 = 0;
    try testing.expectEqual(big, try r.unionWith(gpa, &a, big, small, &inspected));
    try testing.expectEqual(big, try r.unionWith(gpa, &a, small, big, &inspected));
    const before = r.nodes.len;
    var other: SetId = .none;
    other = try r.insert(gpa, &a, other, 1, 0);
    const joined = try r.unionWith(gpa, &a, big, other, &inspected);
    try testing.expectEqual(@as(u32, 65), r.count(joined));
    // One path copied: at most 33 new nodes, plus the leaf.
    try testing.expect(r.nodes.len - before <= 34);
    try testing.expect(inspected > 0);
    // Growth was reserved for every node.
    try testing.expectEqual(@as(u32, @intCast(r.nodes.len)), a.growth);
    // Exhaustion stops before allocation.
    var tight: Account = .{ .allowance = 1 };
    defer tight.deinit(testing.allocator);
    var r2: Radix = .{};
    defer r2.deinit(testing.allocator);
    var s2: SetId = .none;
    s2 = try r2.insert(gpa, &tight, s2, 1, 0);
    try testing.expectError(error.OwnershipLimit, r2.insert(gpa, &tight, s2, 2, 0));
    try testing.expectEqual(@as(usize, 1), r2.nodes.len);
}
