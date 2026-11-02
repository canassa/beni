//! L1: the choice tags a leaf carries and the routes it is reached by
//! (`docs/design/ownership-v2.md` §2.3.5, #1714).
//!
//! **Tags** are lists of `(choice, arms)` pairs sorted by choice, earliest
//! first, `arms` an interned set of the choice's arms: the leaf is there
//! only when one of them ran. A list is one node per `(pair, tail)`, by
//! dense id, hash-consed, so lists that end alike share their tail, and a
//! walk over two lists stops where they meet. An enclosing `case` comes
//! after its arms, so its tag goes at a list's end and a reader going down
//! a set, outer wraps first, puts each inner tag in front. Two pairs of one
//! choice conflict when their arms share none; list 0 is empty. A tag
//! naming every arm of its `alt` says nothing and is dropped.
//!
//! **Routes**, the tag lists under which one element is reached, are a set
//! by dense id (`Set`): written out and normalised (`flat`), every route
//! of a set under an enclosing `case`'s tag (`wrap`, one node), or the
//! arms' sets of an `alt` (`join`), so a leaf that every `then` arm of an
//! `else if` chain reaches costs one node an arm, never a route an arm.
//!
//! Obligations kept here: none of §2.14's directly; §2.3.5's soundness
//! argument (a route answers *no* only where the routes it stands for all
//! do) is `merge`, `combine` and `within`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");

pub const Error = Ids.ChargeError;
pub const none: u32 = Ids.none_int;

/// A tag list's first pair, `(choice, arms)`, and the list after it
/// (`tail`), of `len` pairs whose latest choice is `last`: a tag set
/// sorted by choice, earliest first (§2.3.5). `jump`: a list further down
/// the tail (Myers' skew-binary jump pointers), so a walk can pass a run of
/// earlier choices in steps logarithmic in its length.
pub const Tag = struct { choice: u32, arms: u32, tail: u32, len: u32, last: u32, jump: u32 = 0 };

/// A set of routes (§2.3.5): `flat`, the routes of run `a`, normalised;
/// `wrap`, every route of set `b` with tag list `a` merged in, every
/// choice of `a` after the set's; `join`, the routes of the sets in run
/// `a` (arms' sets, `unite`). `last`: the latest choice a route names,
/// `none` for none. Set 0 is the one unconditional route; `none`, none.
pub const Set = struct {
    kind: Kind,
    a: u32,
    b: u32,
    last: u32,
    pub const Kind = enum(u8) { flat, wrap, join };
};

pub const Table = struct {
    /// Tag lists by dense id, list 0 the empty one (`cons`).
    tags: std.ArrayList(Tag) = .empty,
    tag_index: Ids.FixedDict(3) = .{},
    /// Route sets by dense id, set 0 the unconditional route's (`Set`).
    rsets: std.ArrayList(Set) = .empty,
    rset_index: Ids.FixedDict(3) = .{},
    arm_sets: RunTable(u32) = .{},
    runs: RunTable(u32) = .{},
    scratch: std.ArrayList([2]u32) = .empty,
    /// While an `alt`'s set is made: its choice and the set of its arms.
    universe: [2]u32 = .{ none, none },

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.tags.deinit(gpa);
        t.tag_index.deinit(gpa);
        t.rsets.deinit(gpa);
        t.rset_index.deinit(gpa);
        t.arm_sets.deinit(gpa);
        t.runs.deinit(gpa);
        t.scratch.deinit(gpa);
    }

    /// Tag list `x` after its first pair.
    pub fn tailOf(t: *const Table, x: u32) u32 {
        return t.tag(x).tail;
    }

    /// Tag list `x`'s first pair: its choice and its arms.
    pub fn pairOf(t: *const Table, x: u32) struct { choice: u32, arms: []const u32 } {
        return .{ .choice = t.tag(x).choice, .arms = t.armsOf(t.tag(x).arms) };
    }

    /// Whether two lists' first pairs part: one choice, no arm in common.
    pub fn parts(t: *const Table, x: u32, y: u32) bool {
        const p = t.tag(x);
        const q = t.tag(y);
        return p.choice == q.choice and !t.armsMeet(p.arms, q.arms);
    }

    /// Whether every choice of tag list `x` comes before every one of `y`.
    pub fn before(t: *const Table, x: u32, y: u32) bool {
        return x == 0 or y == 0 or t.tag(x).last < t.tag(y).choice;
    }

    // ---- tags ---------------------------------------------------------------

    fn tag(t: *const Table, id: u32) Tag {
        return t.tags.items[id];
    }

    fn lenOf(t: *const Table, id: u32) u32 {
        return if (id == 0) 0 else t.tag(id).len;
    }

    /// The list `(choice, arms)` before `tail`, whose choices all come
    /// after `choice`: one node per `(pair, tail)`, so lists that end
    /// alike share their tail.
    fn cons(t: *Table, gpa: Allocator, account: *Ids.Account, choice: u32, arms_: u32, tail: u32) Error!u32 {
        try account.reserve(.set, 1);
        if (t.tags.items.len == 0) try t.tags.append(gpa, .{ .choice = none, .arms = none, .tail = 0, .len = 0, .last = none });
        const got = try t.tag_index.getOrPut(gpa, .{ choice, arms_, tail });
        if (got.found_existing) return got.value_ptr.*;
        const id: u32 = @intCast(t.tags.items.len);
        // Myers' rule: jump twice as far as the tail's jump when its two
        // last jumps were of one length, else to the tail.
        const tj = t.tag(tail).jump;
        const jump = if (t.lenOf(tail) - t.lenOf(tj) == t.lenOf(tj) - t.lenOf(t.tag(tj).jump)) t.tag(tj).jump else tail;
        try t.tags.append(gpa, .{ .choice = choice, .arms = arms_, .tail = tail, .len = t.lenOf(tail) + 1, .last = if (tail == 0) choice else t.tag(tail).last, .jump = jump });
        got.value_ptr.* = id;
        return id;
    }

    /// `pairs` (in list order) before `tail`, one `cons` each.
    fn consAll(t: *Table, gpa: Allocator, account: *Ids.Account, pairs: []const [2]u32, tail: u32) Error!u32 {
        var out = tail;
        var i = pairs.len;
        while (i > 0) {
            i -= 1;
            out = try t.cons(gpa, account, pairs[i][0], pairs[i][1], out);
        }
        return out;
    }

    /// The order of a tag list: the earliest choice first. An enclosing
    /// `case`'s choice comes after its arms', so the tags a reader meets
    /// going down a set (outer wraps first) are put in front of the list
    /// made so far, and the leaves below one wrap share its tags as their
    /// tail.
    inline fn first(a: u32, b: u32) bool {
        return a < b;
    }

    fn pairLess(_: void, x: [2]u32, y: [2]u32) bool {
        return first(x[0], y[0]) or (x[0] == y[0] and x[1] < y[1]);
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
    /// one pair per choice, as a list.
    pub fn internTags(t: *Table, gpa: Allocator, account: *Ids.Account, words: []const [2]u32) Error!u32 {
        if (words.len == 0) return 0;
        t.scratch.clearRetainingCapacity();
        try t.scratch.appendSlice(gpa, words);
        std.mem.sort([2]u32, t.scratch.items, {}, pairLess);
        return t.consAll(gpa, account, t.scratch.items, 0);
    }

    fn armsOf(t: *const Table, a: u32) []const u32 {
        return t.arm_sets.get(a);
    }

    pub fn armsMeet(t: *const Table, a: u32, b: u32) bool {
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
    pub fn armsJoin(t: *Table, gpa: Allocator, account: *Ids.Account, a: u32, b: u32, both: bool) Error!u32 {
        if (a == b) return a;
        var out: std.ArrayList(u32) = .empty;
        defer out.deinit(gpa);
        for (t.armsOf(a)) |x| if ((std.mem.indexOfScalar(u32, t.armsOf(b), x) != null) == both or !both) try out.append(gpa, x);
        if (!both) for (t.armsOf(b)) |y| if (std.mem.indexOfScalar(u32, t.armsOf(a), y) == null) try out.append(gpa, y);
        std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
        return t.arm_sets.intern(gpa, account, out.items);
    }

    /// Whether two tag sets never hold together: one choice, no arm in
    /// common. The walk stops where the lists share their tail, and passes
    /// one list's choices the other does not name by its jumps (`seek`).
    pub fn conflict(t: *const Table, x: u32, y: u32) bool {
        return t.conflictCounted(x, y, null) catch unreachable;
    }

    /// `conflict`, one inspection a step charged to `account`.
    pub fn meet(t: *const Table, account: *Ids.Account, x: u32, y: u32) Error!bool {
        return !try t.conflictCounted(x, y, account);
    }

    fn conflictCounted(t: *const Table, x: u32, y: u32, account: ?*Ids.Account) Error!bool {
        var a = x;
        var b = y;
        while (a != b and a != 0 and b != 0) {
            if (account) |ac| try ac.reserve(.inspection, 1);
            const p = t.tag(a);
            const q = t.tag(b);
            if (p.choice == q.choice) {
                if (!t.armsMeet(p.arms, q.arms)) return true;
                a = p.tail;
                b = q.tail;
            } else if (first(p.choice, q.choice)) a = try t.seek(a, q.choice, account) else b = try t.seek(b, p.choice, account);
        }
        return false;
    }

    /// The first list down `a`'s tail whose choice is not before `c` (0
    /// when none is): a list's choices come in order, so every pair a jump
    /// passes is before `c` when the jump's is.
    fn seek(t: *const Table, a0: u32, c: u32, account: ?*Ids.Account) Error!u32 {
        var a = a0;
        while (a != 0 and first(t.tag(a).choice, c)) {
            if (account) |ac| try ac.reserve(.inspection, 1);
            const j = t.tag(a).jump;
            a = if (j != 0 and first(t.tag(j).choice, c)) j else t.tag(a).tail;
        }
        return a;
    }

    /// Both tag sets at once (a choice's arms met), or null when they
    /// conflict: one inspection per pair before the lists' shared tail,
    /// which the result shares.
    pub fn merge(t: *Table, gpa: Allocator, account: *Ids.Account, x: u32, y: u32) Error!?u32 {
        if (x == 0) return y;
        if (y == 0 or x == y) return x;
        var front: std.ArrayList([2]u32) = .empty;
        defer front.deinit(gpa);
        var a = x;
        var b = y;
        while (a != b and a != 0 and b != 0) {
            try account.reserve(.inspection, 1);
            const p = t.tag(a);
            const q = t.tag(b);
            if (p.choice == q.choice) {
                if (!t.armsMeet(p.arms, q.arms)) return null;
                try front.append(gpa, .{ p.choice, try t.armsJoin(gpa, account, p.arms, q.arms, true) });
                a = p.tail;
                b = q.tail;
            } else if (first(p.choice, q.choice)) {
                try front.append(gpa, .{ p.choice, p.arms });
                a = p.tail;
            } else {
                try front.append(gpa, .{ q.choice, q.arms });
                b = q.tail;
            }
        }
        return try t.consAll(gpa, account, front.items, if (a == 0) b else a);
    }

    /// Whether `y` implies `x`: each pair of `x` has one in `y` of the
    /// same choice and fewer arms (`x` answers *no* to less, §2.3.5).
    fn within(t: *const Table, x: u32, y: u32) bool {
        var a = x;
        var b = y;
        while (a != 0 and a != b) {
            if (b == 0) return false;
            const p = t.tag(a);
            const q = t.tag(b);
            if (p.choice == q.choice) {
                if (!t.armsWithin(q.arms, p.arms)) return false;
                a = p.tail;
                b = q.tail;
            } else if (first(q.choice, p.choice)) b = q.tail else return false;
        }
        return true;
    }

    /// Two routes that differ only in one choice's arms, as one with their
    /// arms joined (a pair naming every arm of the `alt` made now
    /// dropped); null when they differ otherwise. The result shares the
    /// routes' common tail.
    fn combine(t: *Table, gpa: Allocator, account: *Ids.Account, x: u32, y: u32) Error!?u32 {
        if (t.lenOf(x) != t.lenOf(y)) return null;
        var front: std.ArrayList([2]u32) = .empty;
        defer front.deinit(gpa);
        var at: ?usize = null;
        var other: u32 = none;
        var a = x;
        var b = y;
        while (a != b) {
            const p = t.tag(a);
            const q = t.tag(b);
            if (p.choice != q.choice) return null;
            if (p.arms != q.arms) {
                if (at != null) return null;
                at = front.items.len;
                other = q.arms;
            }
            try front.append(gpa, .{ p.choice, p.arms });
            a = p.tail;
            b = q.tail;
        }
        const i = at orelse return x;
        front.items[i][1] = try t.armsJoin(gpa, account, front.items[i][1], other, false);
        if (front.items[i][0] == t.universe[0] and front.items[i][1] == t.universe[1]) _ = front.orderedRemove(i);
        return try t.consAll(gpa, account, front.items, a);
    }

    // ---- routes ---------------------------------------------------------------

    fn rset(t: *const Table, id: u32) Set {
        return t.rsets.items[id];
    }

    /// The latest choice a route of set `rs` names, `none` for none.
    fn lastOf(t: *const Table, rs: u32) u32 {
        return if (rs == 0) none else t.rset(rs).last;
    }

    fn latest(a: u32, b: u32) u32 {
        return if (a == none) b else if (b == none) a else @max(a, b);
    }

    fn makeSet(t: *Table, gpa: Allocator, account: *Ids.Account, kind: Set.Kind, a: u32, b: u32, last: u32) Error!u32 {
        try account.reserve(.set, 1);
        if (t.rsets.items.len == 0) try t.rsets.append(gpa, .{ .kind = .flat, .a = 0, .b = 0, .last = none });
        const got = try t.rset_index.getOrPut(gpa, .{ @backingInt(kind), a, b });
        if (got.found_existing) return got.value_ptr.*;
        const id: u32 = @intCast(t.rsets.items.len);
        try t.rsets.append(gpa, .{ .kind = kind, .a = a, .b = b, .last = last });
        got.value_ptr.* = id;
        return id;
    }

    /// The routes `xs0` (any order) as a set: two that differ only in one
    /// choice's arms are one, and none that another implies is kept; none
    /// when `xs0` is empty. The first `ga` are normalised among
    /// themselves, as are the next `gb`, so a route of either group is
    /// compared only with the first group's; a joined route is new and
    /// compared with every route before it.
    pub fn internRoutes(t: *Table, gpa: Allocator, account: *Ids.Account, xs0: []const u32, ga: usize, gb: usize) Error!u32 {
        if (xs0.len == 0) return none;
        var xs: std.ArrayList(u32) = .empty;
        defer xs.deinit(gpa);
        try xs.appendSlice(gpa, xs0);
        var a_end = @min(ga, xs.items.len);
        var b_end = @min(ga + gb, xs.items.len);
        var done: usize = 0;
        scan: while (done < xs.items.len) {
            const y = xs.items[done];
            const lim = if (done < a_end) 0 else if (done < b_end) a_end else done;
            for (xs.items[0..lim], 0..) |x, i| {
                try account.reserve(.inspection, 1);
                const w = (try t.combine(gpa, account, x, y)) orelse if (t.within(x, y)) x else if (t.within(y, x)) y else continue;
                if (done < b_end) b_end -= 1;
                if (i < a_end) a_end -= 1;
                if (i < b_end) b_end -= 1;
                _ = xs.orderedRemove(done);
                _ = xs.orderedRemove(i);
                done -= 1;
                try xs.append(gpa, w);
                continue :scan;
            }
            done += 1;
        }
        std.mem.sort(u32, xs.items, {}, std.sort.asc(u32));
        if (std.mem.indexOfScalar(u32, xs.items, 0) != null) return 0;
        var last: u32 = none;
        for (xs.items) |x| last = latest(last, t.tag(x).last);
        return t.makeSet(gpa, account, .flat, try t.runs.intern(gpa, account, xs.items), 0, last);
    }

    /// Every route of set `rs`, `seed` merged in (a route it conflicts
    /// with is dropped), appended to `out`.
    fn routesInto(t: *Table, gpa: Allocator, account: *Ids.Account, rs: u32, seed: u32, out: *std.ArrayList(u32)) Error!void {
        var it = try t.routeIter(gpa, rs, seed);
        defer it.deinit(gpa);
        while (try it.next(gpa, account)) |r| try out.append(gpa, r);
    }

    /// Whether set `rs` is normalised (`internRoutes`): a `join` of
    /// arms' sets is only where their routes are one node (`unite`).
    fn normal(t: *const Table, rs: u32) bool {
        return rs == 0 or t.rset(rs).kind != .join;
    }

    /// Set `rs` with tags `y` merged into every route. Where every choice
    /// of `y` comes after the set's, that is one `wrap` node, so an
    /// `alt`'s tag costs one node whatever the routes below it; otherwise
    /// the routes are written out and merged.
    pub fn wrapRoutes(t: *Table, gpa: Allocator, account: *Ids.Account, rs: u32, y: u32) Error!u32 {
        if (y == 0 or rs == none) return rs;
        const last = t.lastOf(rs);
        if (last == none or last < t.tag(y).choice) return t.makeSet(gpa, account, .wrap, y, rs, t.tag(y).last);
        var xs: std.ArrayList(u32) = .empty;
        defer xs.deinit(gpa);
        try t.routesInto(gpa, account, rs, y, &xs);
        return t.internRoutes(gpa, account, xs.items, 0, 0);
    }

    fn membersOf(t: *const Table, rs: *const u32) []const u32 {
        return if (rs.* != 0 and t.rset(rs.*).kind == .join) t.runs.get(t.rset(rs.*).a) else rs[0..1];
    }

    /// The routes of two arms' sets, `a` and `b`, each wrapped in its arm's
    /// tags already (§2.3.5): one route under both arms where it is one
    /// node in both (a `wrap` of one set, tags joined by `combine` or one
    /// implying the other), and every other route of each, as a `join`.
    pub fn unite(t: *Table, gpa: Allocator, account: *Ids.Account, a: u32, b: u32) Error!u32 {
        if (a == none or a == b) return b;
        if (b == none) return a;
        // The unconditional route implies every other.
        if (a == 0 or b == 0) return 0;
        var ms: std.ArrayList(u32) = .empty;
        defer ms.deinit(gpa);
        try ms.appendSlice(gpa, t.membersOf(&a));
        next: for (t.membersOf(&b)) |m| {
            for (ms.items) |*o| {
                try account.reserve(.inspection, 1);
                if (o.* == m) continue :next;
                const x = t.rset(o.*);
                const z = t.rset(m);
                if (x.kind != .wrap or z.kind != .wrap or x.b != z.b) continue;
                const w = (try t.combine(gpa, account, x.a, z.a)) orelse if (t.within(x.a, z.a)) x.a else if (t.within(z.a, x.a)) z.a else continue;
                o.* = try t.wrapRoutes(gpa, account, x.b, w);
                continue :next;
            }
            try ms.append(gpa, m);
        }
        std.mem.sort(u32, ms.items, {}, std.sort.asc(u32));
        var n: usize = 0;
        for (ms.items) |m| if (n == 0 or ms.items[n - 1] != m) {
            ms.items[n] = m;
            n += 1;
        };
        if (n == 1) return ms.items[0];
        var last: u32 = none;
        for (ms.items[0..n]) |m| last = latest(last, t.lastOf(m));
        return t.makeSet(gpa, account, .join, try t.runs.intern(gpa, account, ms.items[0..n]), 0, last);
    }

    /// The routes of two coexisting sets: the unconditional route implies
    /// every other; else both written out and normalised.
    pub fn coexistRoutes(t: *Table, gpa: Allocator, account: *Ids.Account, a: u32, b: u32) Error!u32 {
        if (a == none or a == b) return b;
        if (b == none) return a;
        if (a == 0 or b == 0) return 0;
        var xs: std.ArrayList(u32) = .empty;
        defer xs.deinit(gpa);
        try t.routesInto(gpa, account, a, 0, &xs);
        const ga = xs.items.len;
        try t.routesInto(gpa, account, b, 0, &xs);
        return t.internRoutes(gpa, account, xs.items, if (t.normal(a)) ga else 0, if (t.normal(a) and t.normal(b)) xs.items.len - ga else 0);
    }

    /// Whether a route of `a` and a route of `b` can hold together.
    pub fn routesMeet(t: *Table, gpa: Allocator, account: *Ids.Account, a: u32, b: u32) Error!bool {
        if (a == 0 or b == 0) return true;
        var xs: std.ArrayList(u32) = .empty;
        defer xs.deinit(gpa);
        try t.routesInto(gpa, account, b, 0, &xs);
        var it = try t.routeIter(gpa, a, 0);
        defer it.deinit(gpa);
        while (try it.next(gpa, account)) |x| for (xs.items) |y| {
            try account.reserve(.inspection, 1);
            if (!t.conflict(x, y)) return true;
        };
        return false;
    }

    /// One entry of `anyPair`: its tags, its block (`none` for none) and
    /// whether it is an apart occurrence.
    pub const Entry = struct { tags: u32, block: u32, apart: bool };

    /// Whether two of the entries `es` may be one object twice: two that
    /// share no block, are not both apart and whose tags hold together.
    /// Lists that end alike share their tail, so the entries' lists form a
    /// tree by tail. Two lists whose paths to their common tail start at
    /// two pairs of one choice with no arm in common (they **part** there)
    /// conflict, as do all the lists below those two pairs, so they are
    /// never merged: an `else if` chain's D arms reach one atom by D lists
    /// that part at each arm, and no pair of them is merged. One inspection
    /// a list node, a pair of kids and a pair of entries.
    pub fn anyPair(t: *Table, gpa: Allocator, account: *Ids.Account, es: []const Entry) Error!bool {
        if (es.len < 2) return false;
        // The tree: each node met, its parent (by index), its entries.
        var at: Ids.FixedDict(1) = .{};
        defer at.deinit(gpa);
        var nodes: std.ArrayList(struct { id: u32, parent: u32, kids: std.ArrayList(u32) = .empty, ents: std.ArrayList(u32) = .empty }) = .empty;
        defer {
            for (nodes.items) |*n| {
                n.kids.deinit(gpa);
                n.ents.deinit(gpa);
            }
            nodes.deinit(gpa);
        }
        try nodes.append(gpa, .{ .id = 0, .parent = none });
        for (es, 0..) |en, i| {
            const x = en.tags;
            var path: std.ArrayList(u32) = .empty;
            defer path.deinit(gpa);
            var n = x;
            const top = while (n != 0) : (n = t.tag(n).tail) {
                try account.reserve(.inspection, 1);
                if (at.get(.{n})) |k| break k;
                try path.append(gpa, n);
            } else 0;
            var parent = top;
            var k = path.items.len;
            while (k > 0) {
                k -= 1;
                const me: u32 = @intCast(nodes.items.len);
                try at.put(gpa, .{path.items[k]}, me);
                try nodes.append(gpa, .{ .id = path.items[k], .parent = parent });
                try nodes.items[parent].kids.append(gpa, me);
                parent = me;
            }
            try nodes.items[if (path.items.len > 0) parent else top].ents.append(gpa, @intCast(i));
        }
        var left: std.ArrayList(u32) = .empty;
        defer left.deinit(gpa);
        var right: std.ArrayList(u32) = .empty;
        defer right.deinit(gpa);
        for (nodes.items) |n| {
            // Entries at one node: the same list twice.
            for (n.ents.items, 0..) |a, k| for (n.ents.items[k + 1 ..]) |b| {
                try account.reserve(.inspection, 1);
                if (try t.mayPair(gpa, account, es[a], es[b])) return true;
            };
            // A node's entries and those below it: a list and a longer one.
            if (n.ents.items.len > 0) for (n.kids.items) |c| {
                left.clearRetainingCapacity();
                try below(gpa, account, nodes.items, c, &left);
                for (n.ents.items) |a| for (left.items) |b| {
                    try account.reserve(.inspection, 1);
                    if (try t.mayPair(gpa, account, es[a], es[b])) return true;
                };
            };
            // Two kids' entries, unless the kids part.
            for (n.kids.items, 0..) |c, k| for (n.kids.items[k + 1 ..]) |d| {
                try account.reserve(.inspection, 1);
                const p = t.tag(nodes.items[c].id);
                const q = t.tag(nodes.items[d].id);
                if (p.choice == q.choice and !t.armsMeet(p.arms, q.arms)) continue;
                left.clearRetainingCapacity();
                right.clearRetainingCapacity();
                try below(gpa, account, nodes.items, c, &left);
                try below(gpa, account, nodes.items, d, &right);
                for (left.items) |a| for (right.items) |b| {
                    try account.reserve(.inspection, 1);
                    if (try t.mayPair(gpa, account, es[a], es[b])) return true;
                };
            };
        }
        return false;
    }

    fn mayPair(t: *Table, gpa: Allocator, account: *Ids.Account, a: Entry, b: Entry) Error!bool {
        if ((a.block != none and a.block == b.block) or (a.apart and b.apart)) return false;
        return (try t.merge(gpa, account, a.tags, b.tags)) != null;
    }

    /// The entries at node `n` of `anyPair`'s tree and below it.
    fn below(gpa: Allocator, account: *Ids.Account, nodes: anytype, n: u32, out: *std.ArrayList(u32)) Error!void {
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, n);
        while (stack.pop()) |m| {
            try account.reserve(.inspection, 1);
            try out.appendSlice(gpa, nodes[m].ents.items);
            try stack.appendSlice(gpa, nodes[m].kids.items);
        }
    }

    /// The routes of set `rs`, each with `seed` merged in (one that
    /// conflicts with it is dropped), one per `next`: a `wrap`'s tags are
    /// merged in going down, before its routes', so routes below one wrap
    /// share its tags as their tail. One inspection a node.
    pub const RouteIter = struct {
        t: *Table,
        stack: std.ArrayList([2]u32) = .empty,
        run: []const u32 = &.{},
        acc: u32 = 0,

        pub fn deinit(it: *RouteIter, gpa: Allocator) void {
            it.stack.deinit(gpa);
        }

        pub fn next(it: *RouteIter, gpa: Allocator, account: *Ids.Account) Error!?u32 {
            while (true) {
                if (it.run.len > 0) {
                    const r = it.run[0];
                    it.run = it.run[1..];
                    if (try it.t.merge(gpa, account, r, it.acc)) |m| return m;
                    continue;
                }
                const rs, const acc = it.stack.pop() orelse return null;
                // The one unconditional route is its reader's to charge.
                if (rs == 0) return acc;
                try account.reserve(.inspection, 1);
                const n = it.t.rset(rs);
                switch (n.kind) {
                    .flat => {
                        it.run = it.t.runs.get(n.a);
                        it.acc = acc;
                    },
                    .wrap => try it.stack.append(gpa, .{ n.b, (try it.t.merge(gpa, account, n.a, acc)) orelse continue }),
                    .join => {
                        const ms = it.t.runs.get(n.a);
                        var i = ms.len;
                        while (i > 0) {
                            i -= 1;
                            try it.stack.append(gpa, .{ ms[i], acc });
                        }
                    },
                }
            }
        }
    };

    /// The routes of set `rs` with `seed` merged in (`RouteIter`).
    pub fn routeIter(t: *Table, gpa: Allocator, rs: u32, seed: u32) Error!RouteIter {
        var it: RouteIter = .{ .t = t };
        if (rs != none) try it.stack.append(gpa, .{ rs, seed });
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
