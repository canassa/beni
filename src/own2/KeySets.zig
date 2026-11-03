//! L1: sets of base keys (`docs/design/ownership-v2.md` §2.8, *Base
//! keys*), shared between a leaf and the leaves it expands to (#1714).
//!
//! A base key `(kind, root or atom, extra)` is given a dense id the first
//! time it is met. A set of ids is Okasaki–Gill's big-endian Patricia tree,
//! hash-consed: equal contents are one node, and a set made over another
//! shares its nodes, so a leaf's set is the union of its own keys and its
//! kids' sets with no kid's set copied. A chain `x_k` over `x_(k-1)` plus
//! one key costs a path a level, not a copy of the k keys below. Only a
//! set a reader asks for is listed (`run`), once a set, as its keys sorted.
//! Every node made is one `set` record, every pair of nodes a union meets
//! one `inspection`, and every key listed one `edge`, each reserved before
//! the work. The recursion is the key width, 33 frames, a constant
//! (R-7.12).
//!
//! Obligations kept here: none of §2.14's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");

pub const Error = Ids.ChargeError;
const none: u32 = Ids.none_int;

/// The empty set.
pub const empty: u32 = none;

/// A base key, as `Holders.Key`.
pub const Key = [3]u32;

/// A leaf (`mask == 0`, `prefix` its key's id) or a branch (`mask` the
/// branching bit, `prefix` the bits above it, the ids with the bit clear in
/// `left`, set in `right`).
const Node = struct { prefix: u32, mask: u32, left: u32, right: u32 };

pub const Table = struct {
    nodes: std.ArrayList(Node) = .empty,
    /// Per node: its listed run in `items` (start, length), `none` before.
    run: std.ArrayList([2]u32) = .empty,
    intern: Ids.FixedDict(4) = .{},
    /// The base keys, numbered in the order they were met.
    ids: Ids.FixedDict(3) = .{},
    items: std.ArrayList(Key) = .empty,

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.nodes.deinit(gpa);
        t.run.deinit(gpa);
        t.intern.deinit(gpa);
        t.ids.deinit(gpa);
        t.items.deinit(gpa);
    }

    fn make(t: *Table, gpa: Allocator, account: *Ids.Account, n: Node) Error!u32 {
        try account.reserve(.set, 1);
        const got = try t.intern.getOrPut(gpa, .{ n.prefix, n.mask, n.left, n.right });
        if (got.found_existing) return got.value_ptr.*;
        const id: u32 = @intCast(t.nodes.items.len);
        try t.nodes.append(gpa, n);
        try t.run.append(gpa, .{ none, 0 });
        got.value_ptr.* = id;
        return id;
    }

    /// The one-key set.
    pub fn one(t: *Table, gpa: Allocator, account: *Ids.Account, k: Key) Error!u32 {
        const got = try t.ids.getOrPut(gpa, k);
        if (!got.found_existing) got.value_ptr.* = got.index;
        return t.make(gpa, account, .{ .prefix = got.index, .mask = 0, .left = none, .right = none });
    }

    inline fn matches(key: u32, prefix: u32, mask: u32) bool {
        return (key & ~((mask << 1) -% 1)) == prefix;
    }

    fn branch(t: *Table, gpa: Allocator, account: *Ids.Account, prefix: u32, mask: u32, l: u32, r: u32) Error!u32 {
        if (l == none) return r;
        if (r == none) return l;
        return t.make(gpa, account, .{ .prefix = prefix, .mask = mask, .left = l, .right = r });
    }

    /// Two sets whose prefixes `p0` and `p1` differ: one branch over them.
    fn join(t: *Table, gpa: Allocator, account: *Ids.Account, p0: u32, s0: u32, p1: u32, s1: u32) Error!u32 {
        const mask = @as(u32, 1) << @intCast(31 - @clz(p0 ^ p1));
        const prefix = p0 & ~((mask << 1) -% 1);
        return if (p0 & mask == 0) t.branch(gpa, account, prefix, mask, s0, s1) else t.branch(gpa, account, prefix, mask, s1, s0);
    }

    /// The union of `a` and `b`; a node both share is met once, not opened.
    pub fn unite(t: *Table, gpa: Allocator, account: *Ids.Account, a: u32, b: u32) Error!u32 {
        if (a == b or b == none) return a;
        if (a == none) return b;
        try account.reserve(.inspection, 1);
        const na = t.nodes.items[a];
        const nb = t.nodes.items[b];
        if (na.mask != 0 and na.mask == nb.mask and na.prefix == nb.prefix) {
            const l = try t.unite(gpa, account, na.left, nb.left);
            const r = try t.unite(gpa, account, na.right, nb.right);
            return t.branch(gpa, account, na.prefix, na.mask, l, r);
        }
        if (na.mask > nb.mask and matches(nb.prefix, na.prefix, na.mask)) {
            if (nb.prefix & na.mask == 0) return t.branch(gpa, account, na.prefix, na.mask, try t.unite(gpa, account, na.left, b), na.right);
            return t.branch(gpa, account, na.prefix, na.mask, na.left, try t.unite(gpa, account, na.right, b));
        }
        if (nb.mask > na.mask and matches(na.prefix, nb.prefix, nb.mask)) {
            if (na.prefix & nb.mask == 0) return t.branch(gpa, account, nb.prefix, nb.mask, try t.unite(gpa, account, a, nb.left), nb.right);
            return t.branch(gpa, account, nb.prefix, nb.mask, nb.left, try t.unite(gpa, account, a, nb.right));
        }
        return t.join(gpa, account, na.prefix, a, nb.prefix, b);
    }

    /// Set `s`'s keys, sorted, listed the first time it is asked for.
    pub fn keys(t: *Table, gpa: Allocator, account: *Ids.Account, s: u32) Error![]const Key {
        if (s == none) return &.{};
        if (t.run.items[s][0] == none) {
            const start: u32 = @intCast(t.items.items.len);
            var stack: [34]u32 = undefined;
            stack[0] = s;
            var depth: usize = 1;
            while (depth > 0) {
                depth -= 1;
                const n = t.nodes.items[stack[depth]];
                if (n.mask == 0) {
                    try account.reserve(.edge, 1);
                    try t.items.append(gpa, t.ids.keyAt(n.prefix));
                    continue;
                }
                stack[depth] = n.right;
                stack[depth + 1] = n.left;
                depth += 2;
            }
            const got = t.items.items[start..];
            std.mem.sort(Key, got, {}, struct {
                fn lt(_: void, x: Key, y: Key) bool {
                    return std.mem.order(u32, &x, &y) == .lt;
                }
            }.lt);
            t.run.items[s] = .{ start, @intCast(got.len) };
        }
        const r = t.run.items[s];
        return t.items.items[r[0]..][0..r[1]];
    }
};

const testing = std.testing;

test "a chain of sets each over the one before with one key more makes a path a level" {
    var account: Ids.Account = .{};
    defer account.deinit(testing.allocator);
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    const g = testing.allocator;
    var s: u32 = empty;
    var most: usize = 0;
    for (0..512) |k| {
        const before = t.nodes.items.len;
        s = try t.unite(g, &account, try t.one(g, &account, .{ 2, @intCast(511 - k), 0 }), s);
        most = @max(most, t.nodes.items.len - before);
    }
    try testing.expect(most <= 11);
    // Listed sorted, each key once, whatever the order it was met in.
    const ks = try t.keys(g, &account, try t.unite(g, &account, s, s));
    try testing.expectEqual(@as(usize, 512), ks.len);
    for (ks, 0..) |k, i| try testing.expectEqual(@as(u32, @intCast(i)), k[1]);
    // A set and a subset of it: the set itself, no node made.
    const made = t.nodes.items.len;
    try testing.expectEqual(s, try t.unite(g, &account, s, try t.one(g, &account, .{ 2, 7, 0 })));
    try testing.expectEqual(made, t.nodes.items.len);
}
