//! L2: whether entries reached under choice tags may hold together
//! (`docs/design/ownership-v2.md` §2.3.5, §2.9.3, §2.11.2, #1714): two
//! route sets' meet, and the atom pairs a parting rules out. Split from
//! `Routes`, whose tag lists and route sets these read.
//!
//! Obligations kept here: none of §2.14's directly; §2.3.5's soundness
//! argument (a route answers *no* only where the routes it stands for all
//! do) is `setsMeet`: it answers *no* only when no route of one set and no
//! route of the other merge.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Routes = @import("Routes.zig");

const Error = Ids.ChargeError;
const Table = Routes.Table;
const none: u32 = Ids.none_int;

/// Whether a route of set `ra` under tags `ta` and a route of `rb` under
/// `tb` hold together (§2.11.2): some route of each, merged with the
/// tags, merge. Set 0 is the tags alone; `none` is no route. The sets are
/// read together from their earliest choices, each node's tags merged into
/// a running list that drops every choice before both remaining sets'
/// earliest one (no later node can name it), so a state `(a, b, list)`
/// is met once. One inspection a state.
pub fn setsMeet(t: *Table, gpa: Allocator, account: *Ids.Account, ta: u32, ra: u32, tb: u32, rb: u32) Error!bool {
    if (@import("Mutate.zig").on(.sets_meet_never)) return false;
    if (ra == none or rb == none) return false;
    const p0 = (try t.merge(gpa, account, ta, tb)) orelse return false;
    if (ra == 0 and rb == 0) return true;
    // A set's routes are consistent lists (a wrap or a prefix joins lists of
    // disjoint choices), so one set alone holds with tags that name none of
    // its choices.
    if (ra == 0 or rb == 0) {
        const r = if (ra == 0) rb else ra;
        if (p0 == 0 or t.tag(p0).last < t.firstOf(r) or t.lastOf(r) < t.tag(p0).choice) return true;
    }
    // Sets of lists written out (a join of arms' lists): two groups of
    // lists, compared by the tree of their tails as one atom's entries are.
    if (shallow(t, ra) and shallow(t, rb)) {
        var es: std.ArrayList(Entry) = .empty;
        defer es.deinit(gpa);
        try listsInto(t, gpa, account, ra, ta, 0, false, none, &es);
        try listsInto(t, gpa, account, rb, tb, 1, false, none, &es);
        return anyPair(t, gpa, account, es.items);
    }
    var seen: Ids.FixedDict(3) = .{};
    defer seen.deinit(gpa);
    var stack: std.ArrayList([3]u32) = .empty;
    defer stack.deinit(gpa);
    try push(t, gpa, account, &seen, &stack, ra, rb, p0);
    while (stack.pop()) |st| {
        const a, const b, const p = st;
        if (a == 0 and b == 0) return true;
        // The side whose earliest choice comes first is read first.
        const take_a = b == 0 or (a != 0 and t.firstOf(a) <= t.firstOf(b));
        const x = if (take_a) a else b;
        const other = if (take_a) b else a;
        const n = t.rset(x);
        switch (n.kind) {
            .join => for (t.runs.get(n.a)) |m| try push(t, gpa, account, &seen, &stack, if (take_a) m else other, if (take_a) other else m, p),
            .wrap, .pre => if (try t.merge(gpa, account, p, n.a)) |q| try push(t, gpa, account, &seen, &stack, if (take_a) n.b else other, if (take_a) other else n.b, q),
            .flat => for (t.runs.get(n.a)) |r| if (try t.merge(gpa, account, p, r)) |q| try push(t, gpa, account, &seen, &stack, if (take_a) 0 else other, if (take_a) other else 0, q),
        }
    }
    return false;
}

fn push(t: *const Table, gpa: Allocator, account: *Ids.Account, seen: *Ids.FixedDict(3), stack: *std.ArrayList([3]u32), a: u32, b: u32, p0: u32) Error!void {
    if (a == none or b == none) return;
    try account.reserve(.inspection, 1);
    // A choice before every one the sets still name is never met again.
    const f = earliest(t.firstOf(a), t.firstOf(b));
    const p = if (f == none) 0 else try t.seek(p0, f, account);
    if ((try seen.getOrPut(gpa, .{ a, b, p })).found_existing) return;
    try stack.append(gpa, .{ a, b, p });
}

/// The lists of a `shallow` set `rs`, `tags` merged in (one they conflict
/// with dropped), as entries of block `blk` (and `one`, `Entry`'s).
fn listsInto(t: *Table, gpa: Allocator, account: *Ids.Account, rs: u32, tags: u32, blk: u32, apart: bool, one_of: u32, out: *std.ArrayList(Entry)) Error!void {
    const one = [1]u32{rs};
    const ms: []const u32 = if (rs == 0 or t.rset(rs).kind == .flat) &one else t.runs.get(t.rset(rs).a);
    for (ms) |m| for (if (m == 0) &[1]u32{0} else t.runs.get(t.rset(m).a)) |r| {
        try account.reserve(.inspection, 1);
        const x = (try t.merge(gpa, account, r, tags)) orelse continue;
        try out.append(gpa, .{ .tags = x, .block = blk, .apart = apart, .one = one_of });
    };
}

/// Whether set `rs` is lists written out: one route, a `flat` run, or a
/// `join` of them.
fn shallow(t: *const Table, rs: u32) bool {
    if (rs == 0 or t.rset(rs).kind == .flat) return true;
    if (t.rset(rs).kind != .join) return false;
    for (t.runs.get(t.rset(rs).a)) |m| if (m != 0 and t.rset(m).kind != .flat) return false;
    return true;
}

fn earliest(a: u32, b: u32) u32 {
    return if (a == none) b else if (b == none) a else @min(a, b);
}

/// One entry of `anyPair`: its tags, its block (`none` for none),
/// whether it is an apart occurrence, its route set (§2.11.2; 0 for
/// its tags alone), and `one` (`Entries.Ent`'s).
pub const Entry = struct { tags: u32, block: u32, apart: bool, routes: u32 = 0, one: u32 = none };

/// Whether two of the entries `es` may be one object twice: two that
/// share no block, are not both apart and whose tags hold together.
/// Lists that end alike share their tail, so the entries' lists form a
/// tree by tail. Two lists whose paths to their common tail start at
/// two pairs of one choice with no arm in common (they **part** there)
/// conflict, as do all the lists below those two pairs, so they are
/// never merged: an `else if` chain's D arms reach one atom by D lists
/// that part at each arm, and no pair of them is merged. One inspection
/// a list node, a pair of kids and a pair of entries.
pub fn anyPair(t: *Table, gpa: Allocator, account: *Ids.Account, es0: []const Entry) Error!bool {
    if (es0.len < 2) return false;
    // An entry with a route set is compared with every other by `setsMeet`;
    // the others by the tree of their tags.
    var plain: std.ArrayList(Entry) = .empty;
    defer plain.deinit(gpa);
    for (es0, 0..) |a, i| {
        if (a.routes == 0) {
            try plain.append(gpa, a);
            continue;
        }
        // Lists written out join the tree, one block an entry: an entry's
        // own routes never hold together (§2.11.2).
        if (shallow(t, a.routes)) {
            const blk = if (a.block != none) a.block else 0x8000_0000 | @as(u32, @intCast(i));
            try listsInto(t, gpa, account, a.routes, a.tags, blk, a.apart, a.one, &plain);
            continue;
        }
        for (es0, 0..) |b, k| if (k != i and (b.routes == 0 or k < i)) {
            try account.reserve(.inspection, 1);
            if (try mayPair(t, gpa, account, a, b)) return true;
        };
    }
    const es = plain.items;
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
            if (try mayPair(t, gpa, account, es[a], es[b])) return true;
        };
        // A node's entries and those below it: a list and a longer one.
        if (n.ents.items.len > 0) for (n.kids.items) |c| {
            left.clearRetainingCapacity();
            try below(gpa, account, nodes.items, c, &left);
            for (n.ents.items) |a| for (left.items) |b| {
                try account.reserve(.inspection, 1);
                if (try mayPair(t, gpa, account, es[a], es[b])) return true;
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
                if (try mayPair(t, gpa, account, es[a], es[b])) return true;
            };
        };
    }
    return false;
}

fn mayPair(t: *Table, gpa: Allocator, account: *Ids.Account, a: Entry, b: Entry) Error!bool {
    if ((a.block != none and a.block == b.block) or (a.apart and b.apart) or (a.one != none and a.one == b.one)) return false;
    return setsMeet(t, gpa, account, a.tags, a.routes, b.tags, b.routes);
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
