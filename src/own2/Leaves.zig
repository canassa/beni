//! L4: a value's leaf set and the choice tags it carries
//! (`docs/design/ownership-v2.md` §2.3.4, §2.3.5, #1714). A value's leaves
//! are part of the value: each value's set is made once, with the value,
//! from its kids' sets, and stored by the value's id (`Value.Frame.deep`).
//!
//! **The set** is Okasaki–Gill's big-endian Patricia tree over `u32` keys
//! (a leaf's id with no tags), hash-consed: equal contents are one node, a
//! set built over another shares its nodes, and adding a key copies at most
//! one path (33 nodes). A leaf node's `left` is the element's **routes**,
//! the tag sets under which it is reached (an interned run, none weaker
//! than another), its `right` its `many` bit (two coexisting routes reach
//! it). Every node made
//! is one `set` record and every pair of nodes a join meets one
//! `inspection`, reserved before the work. The recursion is the key width,
//! 33 frames, a constant (R-7.12).
//!
//! **Tags** are interned runs of `(choice, arms)` pairs, `arms` an interned
//! set of the choice's arms: the leaf is there only when one of them ran.
//! Two pairs of one choice conflict when their arms share none; set 0 is
//! empty. A tag naming every arm of its `alt` says nothing and is dropped.
//!
//! Obligations kept here: none of §2.14's directly; §2.3.5's soundness
//! argument (an element's tags are a subset of every route's) is `meet`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");

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

/// One element of a set: its key, its routes (`routesOf`), the tags of
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
    tags: RunTable([2]u32) = .{},
    arm_sets: RunTable(u32) = .{},
    routes: RunTable(u32) = .{},
    scratch: std.ArrayList([2]u32) = .empty,
    /// While an `alt`'s set is made: its choice and the set of its arms.
    universe: [2]u32 = .{ none, none },

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.nodes.deinit(gpa);
        t.bits.deinit(gpa);
        t.stamp.deinit(gpa);
        t.intern.deinit(gpa);
        t.tags.deinit(gpa);
        t.arm_sets.deinit(gpa);
        t.routes.deinit(gpa);
        t.scratch.deinit(gpa);
    }

    // ---- tags ---------------------------------------------------------------

    pub fn tagsOf(t: *const Table, id: u32) []const [2]u32 {
        return if (id == 0) &.{} else t.tags.get(id);
    }

    fn pairLess(_: void, x: [2]u32, y: [2]u32) bool {
        return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]);
    }

    /// The set of `arms` (any order, in place).
    pub fn armSet(t: *Table, gpa: Allocator, account: *Ids.Account, arms_: []u32) Error!u32 {
        std.mem.sort(u32, arms_, {}, std.sort.asc(u32));
        return t.arm_sets.intern(gpa, account, arms_);
    }

    /// The set of one arm.
    pub fn armOf(t: *Table, gpa: Allocator, account: *Ids.Account, arm: u32) Error!u32 {
        return t.arm_sets.intern(gpa, account, &.{arm});
    }

    /// The tag set of `words`, `(choice, arm set)` pairs in any order,
    /// one pair per choice, interned.
    pub fn internTags(t: *Table, gpa: Allocator, account: *Ids.Account, words: []const [2]u32) Error!u32 {
        if (words.len == 0) return 0;
        t.scratch.clearRetainingCapacity();
        try t.scratch.appendSlice(gpa, words);
        std.mem.sort([2]u32, t.scratch.items, {}, pairLess);
        return t.tags.intern(gpa, account, t.scratch.items);
    }

    fn armsOf(t: *const Table, a: u32) []const u32 {
        return t.arm_sets.get(a);
    }

    fn armsMeet(t: *const Table, a: u32, b: u32) bool {
        if (a == b) return true;
        for (t.armsOf(a)) |x| for (t.armsOf(b)) |y| if (x == y) return true;
        return false;
    }

    fn armsWithin(t: *const Table, a: u32, b: u32) bool {
        if (a == b) return true;
        for (t.armsOf(a)) |x| if (std.mem.indexOfScalar(u32, t.armsOf(b), x) == null) return false;
        return true;
    }

    /// The arms both sets name, or of either (`both` false), interned.
    fn armsJoin(t: *Table, gpa: Allocator, account: *Ids.Account, a: u32, b: u32, both: bool) Error!u32 {
        if (a == b) return a;
        var out: std.ArrayList(u32) = .empty;
        defer out.deinit(gpa);
        for (t.armsOf(a)) |x| if ((std.mem.indexOfScalar(u32, t.armsOf(b), x) != null) == both or !both) try out.append(gpa, x);
        if (!both) for (t.armsOf(b)) |y| if (std.mem.indexOfScalar(u32, t.armsOf(a), y) == null) try out.append(gpa, y);
        std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
        return t.arm_sets.intern(gpa, account, out.items);
    }

    /// Whether two tag sets never hold together: one choice, no arm in common.
    pub fn conflict(t: *const Table, x: u32, y: u32) bool {
        if (x == 0 or y == 0 or x == y) return false;
        for (t.tagsOf(x)) |p| for (t.tagsOf(y)) |q| if (p[0] == q[0] and !t.armsMeet(p[1], q[1])) return true;
        return false;
    }

    /// Both tag sets at once (a choice's arms met), or null when they conflict.
    pub fn merge(t: *Table, gpa: Allocator, account: *Ids.Account, x: u32, y: u32) Error!?u32 {
        if (x == 0) return y;
        if (y == 0 or x == y) return x;
        const xs = t.tagsOf(x);
        const ys = t.tagsOf(y);
        try account.reserve(.inspection, @intCast(xs.len + ys.len));
        if (t.conflict(x, y)) return null;
        var all: std.ArrayList([2]u32) = .empty;
        defer all.deinit(gpa);
        for (xs) |p| {
            var q = p;
            for (ys) |o| if (o[0] == p[0]) {
                q[1] = try t.armsJoin(gpa, account, p[1], o[1], true);
            };
            try all.append(gpa, q);
        }
        for (ys) |o| if (for (xs) |p| {
            if (p[0] == o[0]) break false;
        } else true) try all.append(gpa, o);
        return try t.internTags(gpa, account, all.items);
    }

    /// Whether `y` implies `x`: each pair of `x` has one in `y` of the
    /// same choice and fewer arms (`x` answers *no* to less, §2.3.5).
    fn within(t: *const Table, x: u32, y: u32) bool {
        if (x == 0 or x == y) return true;
        for (t.tagsOf(x)) |p| {
            const has = for (t.tagsOf(y)) |q| {
                if (p[0] == q[0] and t.armsWithin(q[1], p[1])) break true;
            } else false;
            if (!has) return false;
        }
        return true;
    }

    /// Two routes that differ only in one choice's arms, as one with their
    /// arms joined (a pair naming every arm of the `alt` made now
    /// dropped); null when they differ otherwise.
    fn combine(t: *Table, gpa: Allocator, account: *Ids.Account, x: u32, y: u32) Error!?u32 {
        const xs = t.tagsOf(x);
        const ys = t.tagsOf(y);
        if (xs.len != ys.len) return null;
        var at: ?usize = null;
        for (xs, ys, 0..) |p, q, i| {
            if (p[0] != q[0]) return null;
            if (p[1] == q[1]) continue;
            if (at != null) return null;
            at = i;
        }
        const i = at orelse return x;
        var all: std.ArrayList([2]u32) = .empty;
        defer all.deinit(gpa);
        try all.appendSlice(gpa, xs);
        all.items[i][1] = try t.armsJoin(gpa, account, xs[i][1], ys[i][1], false);
        if (all.items[i][0] == t.universe[0] and all.items[i][1] == t.universe[1]) _ = all.orderedRemove(i);
        return try t.internTags(gpa, account, all.items);
    }

    pub fn routesOf(t: *const Table, id: u32) []const u32 {
        return if (id == 0) &.{0} else t.routes.get(id);
    }

    /// The routes `xs` (any order) interned: two that differ only in one
    /// choice's arms are one, and none that another implies is kept;
    /// none when `xs` is empty.
    fn internRoutes(t: *Table, gpa: Allocator, account: *Ids.Account, xs0: []u32, settled: usize) Error!u32 {
        if (xs0.len == 0) return none;
        var xs: std.ArrayList(u32) = .empty;
        defer xs.deinit(gpa);
        try xs.appendSlice(gpa, xs0);
        // The first `settled` are normalised already: only a pair with a later
        // route can join or cover. A joined route goes to the end, new.
        var done = @min(settled, xs.items.len);
        scan: while (done < xs.items.len) {
            const y = xs.items[done];
            for (xs.items[0..done], 0..) |x, i| {
                try account.reserve(.inspection, 1);
                const w = (try t.combine(gpa, account, x, y)) orelse if (t.within(x, y)) x else if (t.within(y, x)) y else continue;
                _ = xs.orderedRemove(done);
                _ = xs.orderedRemove(i);
                done -= 1;
                try xs.append(gpa, w);
                continue :scan;
            }
            done += 1;
        }
        std.mem.sort(u32, xs.items, {}, std.sort.asc(u32));
        if (xs.items.len == 1 and xs.items[0] == 0) return 0;
        return t.routes.intern(gpa, account, xs.items);
    }

    // ---- sets ---    // ---- sets ---------------------------------------------------------------

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
        return t.leafNode(gpa, account, key, try t.internRoutes(gpa, account, &r, 0), false, refs);
    }

    /// Set `s` with tags `x` merged into every element; an element they
    /// conflict with is dropped.
    pub fn withTags(t: *Table, gpa: Allocator, account: *Ids.Account, s: u32, x: u32) Error!u32 {
        if (x == 0 or s == none) return s;
        const n = t.node(s);
        var tags = x;
        var child = s;
        if (n.mask == wrap) {
            tags = (try t.merge(gpa, account, n.left, x)) orelse return none;
            child = n.right;
        }
        return t.make(gpa, account, .{ .prefix = t.node(child).prefix, .mask = wrap, .left = tags, .right = child }, t.bits.items[child]);
    }

    /// Set `s` with no wrap at its top: a wrap's tags pushed one level down.
    fn open(t: *Table, gpa: Allocator, account: *Ids.Account, s0: u32) Error!u32 {
        var s = s0;
        while (s != none and t.node(s).mask == wrap) {
            try account.reserve(.inspection, 1);
            const n = t.node(s);
            const c = t.node(n.right);
            if (c.mask == 0) {
                var got: std.ArrayList(u32) = .empty;
                defer got.deinit(gpa);
                for (t.routesOf(c.left)) |v| if (try t.merge(gpa, account, v, n.left)) |m| try got.append(gpa, m);
                return t.leafNode(gpa, account, c.prefix, try t.internRoutes(gpa, account, got.items, 0), c.right != 0, t.isRefs(n.right));
            }
            s = try t.branch(gpa, account, c.prefix, c.mask, try t.withTags(gpa, account, c.left, n.left), try t.withTags(gpa, account, c.right, n.left));
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
        t.universe = universe;
        defer t.universe = .{ none, none };
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
            try tags.append(gpa, try t.internTags(gpa, account, &.{.{ choice, try t.armOf(gpa, account, kids[i]) }}));
            try col[0].append(gpa, deep[kids[i + 1]]);
            try col[1].append(gpa, shallow[kids[i + 1]]);
        }
        const u: [2]u32 = .{ choice, try t.armSet(gpa, account, all.items) };
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
            var many = (na.right | nb.right) != 0;
            var all: std.ArrayList(u32) = .empty;
            defer all.deinit(gpa);
            const settled = if (co or ta == 0) t.routesOf(na.left).len else 0;
            for (t.routesOf(na.left)) |x| {
                if (co) for (t.routesOf(nb.left)) |y| {
                    if (!t.conflict(x, y)) many = true;
                };
                if (if (co) x else try t.merge(gpa, account, x, ta)) |m| try all.append(gpa, m);
            }
            for (t.routesOf(nb.left)) |y| if (if (co) y else try t.merge(gpa, account, y, tb)) |m| try all.append(gpa, m);
            return t.leafNode(gpa, account, na.prefix, try t.internRoutes(gpa, account, all.items, if (all.items.len >= settled) settled else 0), many, t.isRefs(a));
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
                    it.stack[it.depth] = .{ n.right, (try it.t.merge(gpa, account, tags, n.left)) orelse continue };
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

/// Runs of `T` interned by content; run 0 is the empty run.
fn RunTable(comptime T: type) type {
    return struct {
        runs: std.ArrayList([2]u32) = .empty,
        words: std.ArrayList(T) = .empty,
        index: Ids.FixedDict(2) = .{},
        next: std.ArrayList(u32) = .empty,
        const Self = @This();

        fn deinit(r: *Self, gpa: Allocator) void {
            r.runs.deinit(gpa);
            r.words.deinit(gpa);
            r.index.deinit(gpa);
            r.next.deinit(gpa);
        }

        fn get(r: *const Self, id: u32) []const T {
            const x = r.runs.items[id];
            return r.words.items[x[0]..][0..x[1]];
        }

        fn intern(r: *Self, gpa: Allocator, account: *Ids.Account, ws: []const T) Error!u32 {
            if (r.runs.items.len == 0) {
                try r.runs.append(gpa, .{ 0, 0 });
                try r.next.append(gpa, none);
            }
            if (ws.len == 0) return 0;
            try account.reserve(.set, @intCast(ws.len));
            const h = std.hash.Wyhash.hash(7, std.mem.sliceAsBytes(ws));
            const got = try r.index.getOrPut(gpa, .{ @truncate(h), @truncate(h >> 32) });
            if (got.found_existing) {
                var at = got.value_ptr.*;
                while (at != none) : (at = r.next.items[at]) if (std.mem.eql(u8, std.mem.sliceAsBytes(r.get(at)), std.mem.sliceAsBytes(ws))) return at;
            }
            const id: u32 = @intCast(r.runs.items.len);
            const start: u32 = @intCast(r.words.items.len);
            try r.words.appendSlice(gpa, ws);
            try r.runs.append(gpa, .{ start, @intCast(ws.len) });
            try r.next.append(gpa, if (got.found_existing) got.value_ptr.* else none);
            got.value_ptr.* = id;
            return id;
        }
    };
}

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
    const a0 = try t.armOf(g, &account, 0);
    const a1 = try t.armOf(g, &account, 1);
    const t0 = try t.internTags(g, &account, &.{.{ 9, a0 }});
    const t1 = try t.internTags(g, &account, &.{.{ 9, a1 }});
    const alt = try t.arms(g, &account, &.{ own, shared }, &.{ t0, t1 }, .{ 9, try t.armsJoin(g, &account, a0, a1, false) });
    var it = t.iterate(alt, 0);
    const e1 = (try it.next(g, &account)).?;
    try testing.expectEqual(@as(u32, 1), e1.key);
    try testing.expectEqual(@as(u32, 0), e1.routes);
    const e2 = (try it.next(g, &account)).?;
    try testing.expectEqual(@as(u32, 2), e2.key);
    try testing.expectEqualSlices(u32, &.{t0}, t.routesOf(e2.routes));
    try testing.expect(!e2.many);
    // One choice's two arms coexisting: once, not twice.
    const x0 = try t.one(g, &account, 5, t0, false);
    const x1 = try t.one(g, &account, 5, t1, false);
    var c = t.iterate(try t.coexist(g, &account, x0, x1), 0);
    try testing.expect(!(try c.next(g, &account)).?.many);
}
