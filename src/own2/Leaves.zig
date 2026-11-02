//! L4: a value's leaf set and the choice tags it carries
//! (`docs/design/ownership-v2.md` §2.3.4, §2.3.5, #1714). A value's leaves
//! are part of the value: each value's set is made once, with the value,
//! from its kids' sets, and stored by the value's id (`Value.Frame.deep`).
//!
//! **The set** is Okasaki–Gill's big-endian Patricia tree over `u32` keys
//! (a leaf's id with no tags), hash-consed: equal contents are one node, a
//! set built over another shares its nodes, and adding a key copies at most
//! one path (33 nodes). A leaf node's `left` is the element's **routes**,
//! the tag sets under which it is reached (a route set of `Routes.zig`),
//! its `right` its `many` bit (two coexisting routes reach it). A wrap
//! node tags a whole set; a wrap inside a wrap is two nodes when the
//! inner's choices all come first. Every node made
//! is one `set` record and every pair of nodes a join meets one
//! `inspection`, reserved before the work. The recursion is the key width,
//! 33 frames, a constant (R-7.12).
//!
//! **Tags** and routes are `Routes.zig`'s.
//!
//! Obligations kept here: none of §2.14's directly; §2.3.5's soundness
//! argument (an element's tags are a subset of every route's) is `meet`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Routes = @import("Routes.zig");

pub const Error = Ids.ChargeError;
pub const none: u32 = Ids.none_int;
/// The empty set.
pub const empty: u32 = none;

/// A leaf (`mask == 0`: `prefix` is the key, `left` its routes, `right`
/// its `many` bit), a **wrap** (`mask == wrap`: every element of set
/// `right` with tags `left` merged in, opened one level where a join looks
/// inside, so tagging a set is one node) or a branch (`mask` the branching bit, `prefix` the bits
/// above it, the keys with the bit clear in `left`, set in `right`).
pub const Node = struct { prefix: u32, mask: u32, left: u32, right: u32 };

/// One element of a set: its key, its route set (`Routes.Table.routeIter`), the tags of
/// the wraps above it, and whether coexisting routes reach it twice.
pub const Elem = struct { key: u32, routes: u32, tags: u32, many: bool };

const wrap: u32 = std.math.maxInt(u32);

/// A node's bits: a key below it is one a pass must read (`refs`), every
/// element below it is `many`.
const refs_bit: u8 = 1;
const many_bit: u8 = 2;

pub const Table = struct {
    nodes: std.ArrayList(Node) = .empty,
    bits: std.ArrayList(u8) = .empty,
    /// The pass that last visited each node (`enter`).
    stamp: std.ArrayList(u32) = .empty,
    intern: Ids.FixedDict(4) = .{},
    pass: u32 = 0,
    /// The tags and routes its elements carry.
    tags: Routes.Table = .{},

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.nodes.deinit(gpa);
        t.bits.deinit(gpa);
        t.stamp.deinit(gpa);
        t.intern.deinit(gpa);
        t.tags.deinit(gpa);
    }

    // ---- sets ---------------------------------------------------------------

    pub fn node(t: *const Table, id: u32) Node {
        return t.nodes.items[id];
    }

    /// Whether some key of set `s` is one a pass must read.
    pub fn hasRefs(t: *const Table, s: u32) bool {
        return s != none and t.bits.items[s] & refs_bit != 0;
    }

    fn make(t: *Table, gpa: Allocator, account: *Ids.Account, n: Node, bits: u8) Error!u32 {
        try account.reserve(.set, 1);
        const got = try t.intern.getOrPut(gpa, .{ n.prefix, n.mask, n.left, n.right });
        if (got.found_existing) return got.value_ptr.*;
        const id: u32 = @intCast(t.nodes.items.len);
        try t.nodes.append(gpa, n);
        try t.bits.append(gpa, bits);
        try t.stamp.append(gpa, 0);
        got.value_ptr.* = id;
        return id;
    }

    fn leafNode(t: *Table, gpa: Allocator, account: *Ids.Account, key: u32, routes: u32, many: bool, refs: bool) Error!u32 {
        if (routes == none) return none;
        const bits: u8 = (if (refs) refs_bit else 0) | (if (many) many_bit else 0);
        return t.make(gpa, account, .{ .prefix = key, .mask = 0, .left = routes, .right = @intFromBool(many) }, bits);
    }

    fn isRefs(t: *const Table, s: u32) bool {
        return t.bits.items[s] & refs_bit != 0;
    }

    /// A branch over two sets, either of which may be empty.
    fn branch(t: *Table, gpa: Allocator, account: *Ids.Account, prefix: u32, mask: u32, l: u32, r: u32) Error!u32 {
        if (l == none) return r;
        if (r == none) return l;
        const bl = t.bits.items[l];
        const br = t.bits.items[r];
        return t.make(gpa, account, .{ .prefix = prefix, .mask = mask, .left = l, .right = r }, ((bl | br) & refs_bit) | (bl & br & many_bit));
    }

    inline fn matches(key: u32, prefix: u32, mask: u32) bool {
        return (key & ~((mask << 1) -% 1)) == prefix;
    }

    inline fn zeroBit(key: u32, mask: u32) bool {
        return key & mask == 0;
    }

    /// Two sets whose prefixes `p0` and `p1` differ: one branch over them.
    fn join(t: *Table, gpa: Allocator, account: *Ids.Account, p0: u32, s0: u32, p1: u32, s1: u32) Error!u32 {
        if (s0 == none) return s1;
        if (s1 == none) return s0;
        const mask = @as(u32, 1) << @intCast(31 - @clz(p0 ^ p1));
        const prefix = p0 & ~((mask << 1) -% 1);
        return if (zeroBit(p0, mask)) t.branch(gpa, account, prefix, mask, s0, s1) else t.branch(gpa, account, prefix, mask, s1, s0);
    }

    /// The one-element set.
    pub fn one(t: *Table, gpa: Allocator, account: *Ids.Account, key: u32, tags: u32, refs: bool) Error!u32 {
        var r = [1]u32{tags};
        return t.leafNode(gpa, account, key, try t.tags.internRoutes(gpa, account, &r, 0, 0), false, refs);
    }

    /// Set `s` with tags `x` merged into every element; an element they
    /// conflict with is dropped.
    pub fn withTags(t: *Table, gpa: Allocator, account: *Ids.Account, s: u32, x: u32) Error!u32 {
        if (x == 0 or s == none) return s;
        const n = t.node(s);
        var tags = x;
        var child = s;
        // A wrap whose choices all come before `x`'s gains an outer wrap,
        // one node; else the two lists are merged.
        if (n.mask == wrap and !t.tags.before(n.left, x)) {
            tags = (try t.tags.merge(gpa, account, n.left, x)) orelse return none;
            child = n.right;
        }
        return t.make(gpa, account, .{ .prefix = t.node(child).prefix, .mask = wrap, .left = tags, .right = child }, t.bits.items[child]);
    }

    /// Set `s` with no wrap at its top: the wraps at its top (one inside
    /// another, the outer after the inner), innermost first, pushed one
    /// level down.
    fn open(t: *Table, gpa: Allocator, account: *Ids.Account, s0: u32) Error!u32 {
        if (s0 == none or t.node(s0).mask != wrap) return s0;
        var nest: std.ArrayList(u32) = .empty;
        defer nest.deinit(gpa);
        var s = s0;
        while (t.node(s).mask == wrap) : (s = t.node(s).right) {
            try account.reserve(.inspection, 1);
            try nest.append(gpa, t.node(s).left);
        }
        var i = nest.items.len;
        while (i > 0 and s != none) {
            i -= 1;
            const c = t.node(s);
            s = if (c.mask == 0)
                try t.leafNode(gpa, account, c.prefix, try t.tags.wrapRoutes(gpa, account, c.left, nest.items[i]), c.right != 0, t.isRefs(s))
            else
                try t.branch(gpa, account, c.prefix, c.mask, try t.withTags(gpa, account, c.left, nest.items[i]), try t.withTags(gpa, account, c.right, nest.items[i]));
        }
        return s;
    }

    /// Set `s` with every element `many`.
    fn allMany(t: *Table, gpa: Allocator, account: *Ids.Account, s0: u32) Error!u32 {
        if (s0 == none or t.bits.items[s0] & many_bit != 0) return s0;
        const s = try t.open(gpa, account, s0);
        if (s == none) return none;
        try account.reserve(.inspection, 1);
        const n = t.node(s);
        if (n.mask == 0) return t.leafNode(gpa, account, n.prefix, n.left, true, t.isRefs(s));
        return t.branch(gpa, account, n.prefix, n.mask, try t.allMany(gpa, account, n.left), try t.allMany(gpa, account, n.right));
    }

    /// Two coexisting sets joined (§2.3.4): a key in both keeps both sides'
    /// tag sets, and is `many` unless no two of them coexist.
    pub fn coexist(t: *Table, gpa: Allocator, account: *Ids.Account, a: u32, b: u32) Error!u32 {
        return t.join2(gpa, account, a, 0, b, 0, true);
    }

    /// An `alt`'s set from its arms' (§2.3.5): what every arm has the same
    /// stays as it is; the rest of each arm gains that arm's tag, `tags[i]`.
    /// What the arms share is found by node identity, so it costs the path
    /// to it.
    pub fn arms(t: *Table, gpa: Allocator, account: *Ids.Account, sets: []const u32, tags: []const u32, universe: [2]u32) Error!u32 {
        if (sets.len == 0) return none;
        t.tags.universe = universe;
        defer t.tags.universe = .{ none, none };
        var all = sets[0];
        for (sets[1..]) |x| all = try t.alike(gpa, account, all, x);
        var rest: u32 = none;
        for (sets, tags) |x, tg| rest = try t.join2(gpa, account, rest, 0, try t.minus(gpa, account, x, all), tg, false);
        return t.join2(gpa, account, all, 0, rest, 0, false);
    }

    /// A `built` value's sets (§2.3.4): deep, its own storage `own`, the
    /// storage of the value it is built over (`base`) and its kids' deep
    /// sets (`kids` into `deep`), coexisting; its storage, `own` with
    /// the base's, or the deferred `recons` element instead of it.
    pub fn built(t: *Table, gpa: Allocator, account: *Ids.Account, own: u32, base: u32, recons: u32, deep: []const u32, kids: []const u32) Error![2]u32 {
        var d = try t.coexist(gpa, account, own, base);
        for (kids) |k| d = try t.coexist(gpa, account, d, deep[k]);
        return .{ d, try t.coexist(gpa, account, own, if (recons != none) recons else base) };
    }

    /// An `alt`'s sets (§2.3.5): `kids` its `(arm, value)` pairs, the
    /// values' sets in `deep` and `shallow`.
    pub fn alt(t: *Table, gpa: Allocator, account: *Ids.Account, deep: []const u32, shallow: []const u32, choice: u32, kids: []const u32) Error![2]u32 {
        var col: [2]std.ArrayList(u32) = .{ .empty, .empty };
        defer for (&col) |*c| c.deinit(gpa);
        var tags: std.ArrayList(u32) = .empty;
        defer tags.deinit(gpa);
        var all: std.ArrayList(u32) = .empty;
        defer all.deinit(gpa);
        var i: usize = 0;
        while (i < kids.len) : (i += 2) {
            try all.append(gpa, kids[i]);
            try tags.append(gpa, try t.tags.internTags(gpa, account, &.{.{ choice, try t.tags.armOf(gpa, account, kids[i]) }}));
            try col[0].append(gpa, deep[kids[i + 1]]);
            try col[1].append(gpa, shallow[kids[i + 1]]);
        }
        const u: [2]u32 = .{ choice, try t.tags.armSet(gpa, account, all.items) };
        return .{ try t.arms(gpa, account, col[0].items, tags.items, u), try t.arms(gpa, account, col[1].items, tags.items, u) };
    }

    /// The node for `key` in `s`, or none.
    fn find(t: *const Table, s: u32, key: u32) u32 {
        var at = s;
        while (at != none) {
            const n = t.node(at);
            if (n.mask == wrap) return none;
            if (n.mask == 0) return if (n.prefix == key) at else none;
            if (!matches(key, n.prefix, n.mask)) return none;
            at = if (zeroBit(key, n.mask)) n.left else n.right;
        }
        return none;
    }

    /// The elements both sets have exactly alike.
    fn alike(t: *Table, gpa: Allocator, account: *Ids.Account, a0: u32, b0: u32) Error!u32 {
        if (a0 == b0 or a0 == none or b0 == none) return if (a0 == b0) a0 else none;
        const a = try t.open(gpa, account, a0);
        const b = try t.open(gpa, account, b0);
        if (a == none or b == none) return none;
        try account.reserve(.inspection, 1);
        const na = t.node(a);
        const nb = t.node(b);
        if (na.mask == 0) return if (t.find(b, na.prefix) == a) a else none;
        if (nb.mask == 0) return if (t.find(a, nb.prefix) == b) b else none;
        if (na.mask == nb.mask and na.prefix == nb.prefix) return t.branch(gpa, account, na.prefix, na.mask, try t.alike(gpa, account, na.left, nb.left), try t.alike(gpa, account, na.right, nb.right));
        if (na.mask > nb.mask and matches(nb.prefix, na.prefix, na.mask)) return t.alike(gpa, account, if (zeroBit(nb.prefix, na.mask)) na.left else na.right, b);
        if (nb.mask > na.mask and matches(na.prefix, nb.prefix, nb.mask)) return t.alike(gpa, account, a, if (zeroBit(na.prefix, nb.mask)) nb.left else nb.right);
        return none;
    }

    /// `a` without the elements `c` has exactly alike.
    fn minus(t: *Table, gpa: Allocator, account: *Ids.Account, a0: u32, c0: u32) Error!u32 {
        if (a0 == c0 or a0 == none) return none;
        if (c0 == none) return a0;
        const a = try t.open(gpa, account, a0);
        const c = try t.open(gpa, account, c0);
        if (a == none or c == none) return a;
        try account.reserve(.inspection, 1);
        const na = t.node(a);
        const nc = t.node(c);
        if (na.mask == 0) return if (t.find(c, na.prefix) == a) none else a;
        if (na.mask == nc.mask and na.prefix == nc.prefix) return t.branch(gpa, account, na.prefix, na.mask, try t.minus(gpa, account, na.left, nc.left), try t.minus(gpa, account, na.right, nc.right));
        if (na.mask > nc.mask and matches(nc.prefix, na.prefix, na.mask)) {
            if (zeroBit(nc.prefix, na.mask)) return t.branch(gpa, account, na.prefix, na.mask, try t.minus(gpa, account, na.left, c), na.right);
            return t.branch(gpa, account, na.prefix, na.mask, na.left, try t.minus(gpa, account, na.right, c));
        }
        if (nc.mask > na.mask and matches(na.prefix, nc.prefix, nc.mask)) return t.minus(gpa, account, a, if (zeroBit(na.prefix, nc.mask)) nc.left else nc.right);
        return a;
    }

    fn join2(t: *Table, gpa: Allocator, account: *Ids.Account, a0: u32, ta: u32, b0: u32, tb: u32, co: bool) Error!u32 {
        if (a0 == none) return t.withTags(gpa, account, b0, tb);
        if (b0 == none) return t.withTags(gpa, account, a0, ta);
        if (a0 == b0 and co) return t.allMany(gpa, account, a0);
        if (a0 == b0 and ta == 0 and tb == 0) return a0;
        const a = try t.open(gpa, account, a0);
        const b = try t.open(gpa, account, b0);
        if (a == none or b == none) return t.join2(gpa, account, a, ta, b, tb, co);
        try account.reserve(.inspection, 1);
        const na = t.node(a);
        const nb = t.node(b);
        if (na.mask == 0 and nb.mask == 0 and na.prefix == nb.prefix) {
            const many = (na.right | nb.right) != 0 or (co and try t.tags.routesMeet(gpa, account, na.left, nb.left));
            const routes = if (co) try t.tags.coexistRoutes(gpa, account, na.left, nb.left) else try t.tags.unite(gpa, account, try t.tags.wrapRoutes(gpa, account, na.left, ta), try t.tags.wrapRoutes(gpa, account, nb.left, tb));
            return t.leafNode(gpa, account, na.prefix, routes, many, t.isRefs(a));
        }
        if (na.mask != 0 and na.mask == nb.mask and na.prefix == nb.prefix) {
            const l = try t.join2(gpa, account, na.left, ta, nb.left, tb, co);
            const r = try t.join2(gpa, account, na.right, ta, nb.right, tb, co);
            return t.branch(gpa, account, na.prefix, na.mask, l, r);
        }
        if (na.mask > nb.mask and matches(nb.prefix, na.prefix, na.mask)) {
            // `b` fits under one side of `a`.
            if (zeroBit(nb.prefix, na.mask)) return t.branch(gpa, account, na.prefix, na.mask, try t.join2(gpa, account, na.left, ta, b, tb, co), try t.withTags(gpa, account, na.right, ta));
            return t.branch(gpa, account, na.prefix, na.mask, try t.withTags(gpa, account, na.left, ta), try t.join2(gpa, account, na.right, ta, b, tb, co));
        }
        if (nb.mask > na.mask and matches(na.prefix, nb.prefix, nb.mask)) {
            if (zeroBit(na.prefix, nb.mask)) return t.branch(gpa, account, nb.prefix, nb.mask, try t.join2(gpa, account, a, ta, nb.left, tb, co), try t.withTags(gpa, account, nb.right, tb));
            return t.branch(gpa, account, nb.prefix, nb.mask, try t.withTags(gpa, account, nb.left, tb), try t.join2(gpa, account, a, ta, nb.right, tb, co));
        }
        return t.join(gpa, account, na.prefix, try t.withTags(gpa, account, a, ta), nb.prefix, try t.withTags(gpa, account, b, tb));
    }

    /// A new pass (§2.3.4 *Reading*): `enter` says once per node whether it
    /// is met for the first time in it.
    pub fn newPass(t: *Table) u32 {
        t.pass += 1;
        return t.pass;
    }

    fn enter(t: *Table, s: u32, pass: u32) bool {
        if (t.stamp.items[s] == pass) return false;
        t.stamp.items[s] = pass;
        return true;
    }

    /// The elements of set `s` in key order, one per `next`, on an
    /// explicit stack of at most 34 nodes. With a `pass`, a node met before
    /// in the pass and a node with no key a pass reads are skipped.
    pub const Iterator = struct {
        t: *Table,
        pass: u32 = 0,
        /// `(node, tags of the wraps above it)`.
        stack: [70][2]u32 = undefined,
        depth: usize = 0,

        pub fn next(it: *Iterator, gpa: Allocator, account: *Ids.Account) Error!?Elem {
            while (it.depth > 0) {
                it.depth -= 1;
                const id, const tags = it.stack[it.depth];
                // A node is met once a pass only where no wrap tags it.
                if (it.pass != 0 and (!it.t.hasRefs(id) or (tags == 0 and !it.t.enter(id, it.pass)))) continue;
                const n = it.t.node(id);
                if (n.mask == wrap) {
                    it.stack[it.depth] = .{ n.right, (try it.t.tags.merge(gpa, account, tags, n.left)) orelse continue };
                    it.depth += 1;
                    continue;
                }
                if (n.mask == 0) return .{ .key = n.prefix, .routes = n.left, .tags = tags, .many = n.right != 0 };
                it.stack[it.depth] = .{ n.right, tags };
                it.stack[it.depth + 1] = .{ n.left, tags };
                it.depth += 2;
            }
            return null;
        }
    };

    pub fn iterate(t: *Table, s: u32, pass: u32) Iterator {
        var it: Iterator = .{ .t = t, .pass = pass };
        if (s != none) {
            it.stack[0] = .{ s, 0 };
            it.depth = 1;
        }
        return it;
    }
};

const testing = std.testing;

test "a set built over another shares its nodes, and a key reached twice is many" {
    var account: Ids.Account = .{};
    defer account.deinit(testing.allocator);
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    const g = testing.allocator;
    var s: u32 = empty;
    for (0..64) |k| s = try t.coexist(g, &account, s, try t.one(g, &account, @intCast(k), 0, k % 2 == 0));
    const made = t.nodes.items.len;
    const s2 = try t.coexist(g, &account, s, try t.one(g, &account, 64, 0, false));
    try testing.expect(t.nodes.items.len - made <= 34);
    // Coexisting with itself: every element twice.
    const twice = try t.coexist(g, &account, s2, s2);
    var it = t.iterate(twice, 0);
    var n: u32 = 0;
    while (try it.next(g, &account)) |e| : (n += 1) try testing.expect(e.many);
    try testing.expectEqual(@as(u32, 65), n);
    // A pass reads each node once, and only nodes with a key it reads.
    const p = t.newPass();
    var a = t.iterate(s2, p);
    var refs: u32 = 0;
    while (try a.next(g, &account)) |_| refs += 1;
    try testing.expectEqual(@as(u32, 32), refs);
    var b = t.iterate(s2, p);
    try testing.expect((try b.next(g, &account)) == null);
}

test "two arms keep the tags common to them, and an arm's own key gains its arm" {
    var account: Ids.Account = .{};
    defer account.deinit(testing.allocator);
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    const g = testing.allocator;
    const shared = try t.one(g, &account, 1, 0, true);
    const own = try t.coexist(g, &account, shared, try t.one(g, &account, 2, 0, false));
    const a0 = try t.tags.armOf(g, &account, 0);
    const a1 = try t.tags.armOf(g, &account, 1);
    const t0 = try t.tags.internTags(g, &account, &.{.{ 9, a0 }});
    const t1 = try t.tags.internTags(g, &account, &.{.{ 9, a1 }});
    const alt = try t.arms(g, &account, &.{ own, shared }, &.{ t0, t1 }, .{ 9, try t.tags.armsJoin(g, &account, a0, a1, false) });
    var it = t.iterate(alt, 0);
    const e1 = (try it.next(g, &account)).?;
    try testing.expectEqual(@as(u32, 1), e1.key);
    try testing.expectEqual(@as(u32, 0), e1.routes);
    const e2 = (try it.next(g, &account)).?;
    try testing.expectEqual(@as(u32, 2), e2.key);
    var rs = try t.tags.routeIter(g, e2.routes, 0);
    defer rs.deinit(g);
    try testing.expectEqual(@as(?u32, t0), try rs.next(g, &account));
    try testing.expectEqual(@as(?u32, null), try rs.next(g, &account));
    try testing.expect(!e2.many);
    // One choice's two arms coexisting: once, not twice.
    const x0 = try t.one(g, &account, 5, t0, false);
    const x1 = try t.one(g, &account, 5, t1, false);
    var c = t.iterate(try t.coexist(g, &account, x0, x1), 0);
    try testing.expect(!(try c.next(g, &account)).?.many);
}
