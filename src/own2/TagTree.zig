//! L2: a run of tag lists read as the tree of their shared tails
//! (`docs/design/ownership-v2.md` §2.8, *Holds read by their tags*,
//! #1714), and the members whose lists may hold together with a list
//! asked. Lists that end alike share their tail (`Routes.zig`), so a
//! list's tails are its ancestors. Two lists hold together unless their
//! paths below their common tail name one choice with no arm in common;
//! when the two pairs just below it do (they **part**), so does every list
//! below either. A list asked meets its own subtree's members and its
//! ancestors' whole, and below an ancestor only the kids that do not part
//! from its own path, each member there tested exactly. A node whose
//! siblings all part from it and whose parent holds no member is passed by
//! one pointer, so an `else if` chain of n arms costs an asked list its own
//! arm, not n.
//!
//! Obligations kept here: O2's resolution half: every member whose tags
//! may hold with the asked list is answered; one is left out only where
//! the two lists part, where `Relation`'s overlap answers *no*.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Routes = @import("Routes.zig");

pub const Error = Ids.ChargeError;
const none: u32 = Ids.none_int;

/// The tree of one run of lists (`build`).
pub const Tree = struct {
    /// Per node: its list (`lists_of`), parent, first kid, next sibling, first member
    /// (members chained by `next`), and the next ancestor `up` an asked
    /// path below it must stop at, with the node `via` of that path just
    /// below it.
    lists_of: std.ArrayList(u32) = .empty,
    parent: std.ArrayList(u32) = .empty,
    kid: std.ArrayList(u32) = .empty,
    sib: std.ArrayList(u32) = .empty,
    first: std.ArrayList(u32) = .empty,
    up: std.ArrayList(u32) = .empty,
    via: std.ArrayList(u32) = .empty,
    next: std.ArrayList(u32) = .empty,
    lists: []const u32 = &.{},
    at: Ids.FixedDict(1) = .{},

    pub fn deinit(tr: *Tree, gpa: Allocator) void {
        inline for (.{ &tr.lists_of, &tr.parent, &tr.kid, &tr.sib, &tr.first, &tr.up, &tr.via, &tr.next }) |l| l.deinit(gpa);
        tr.at.deinit(gpa);
        gpa.free(tr.lists);
    }

    fn node(tr: *Tree, gpa: Allocator, list: u32, parent: u32) Error!u32 {
        const n: u32 = @intCast(tr.lists_of.items.len);
        try tr.lists_of.append(gpa, list);
        try tr.parent.append(gpa, parent);
        try tr.kid.append(gpa, none);
        try tr.sib.append(gpa, if (parent == none) none else tr.kid.items[parent]);
        if (parent != none) tr.kid.items[parent] = n;
        try tr.first.append(gpa, none);
        try tr.at.put(gpa, .{list}, n);
        return n;
    }

    /// The tree of `lists` (member `i`'s list is `lists[i]`): one record a
    /// node made, a sibling compared and a member placed.
    pub fn build(gpa: Allocator, account: *Ids.Account, tags: *const Routes.Table, lists: []const u32) Error!Tree {
        var tr: Tree = .{ .lists = try gpa.dupe(u32, lists) };
        errdefer tr.deinit(gpa);
        _ = try tr.node(gpa, 0, none);
        try tr.next.appendNTimes(gpa, none, lists.len);
        var path: std.ArrayList(u32) = .empty;
        defer path.deinit(gpa);
        for (lists, 0..) |x, i| {
            path.clearRetainingCapacity();
            var n = x;
            const top = while (true) : (n = tags.tailOf(n)) {
                try account.reserve(.inspection, 1);
                if (tr.at.get(.{n})) |k| break k;
                try path.append(gpa, n);
            };
            var at = top;
            var k = path.items.len;
            while (k > 0) {
                k -= 1;
                at = try tr.node(gpa, path.items[k], at);
            }
            tr.next.items[i] = tr.first.items[at];
            tr.first.items[at] = @intCast(i);
        }
        // Parents come before their kids, so each node's `up` is read off
        // its parent's.
        var arms: Ids.FixedDict(1) = .{};
        defer arms.deinit(gpa);
        try tr.up.appendNTimes(gpa, none, tr.lists_of.items.len);
        try tr.via.appendNTimes(gpa, none, tr.lists_of.items.len);
        for (0..tr.lists_of.items.len) |p| {
            // Which kids of `p` have a sibling they do not part from: all of
            // them when the kids name two choices, else those with an arm
            // another kid names too.
            const k0 = tr.kid.items[p];
            if (k0 == none) continue;
            const choice = tags.pairOf(tr.lists_of.items[k0]).choice;
            var one = true;
            arms.clearRetainingCapacity();
            var c = k0;
            while (c != none) : (c = tr.sib.items[c]) {
                try account.reserve(.inspection, 1);
                const pr = tags.pairOf(tr.lists_of.items[c]);
                if (pr.choice != choice) one = false;
                for (pr.arms) |a| {
                    const got = try arms.getOrPut(gpa, .{a});
                    got.value_ptr.* = if (got.found_existing) got.value_ptr.* + 1 else 1;
                }
            }
            c = k0;
            while (c != none) : (c = tr.sib.items[c]) {
                var meets = !one;
                if (one) for (tags.pairOf(tr.lists_of.items[c]).arms) |a| {
                    if (arms.get(.{a}).? > 1) meets = true;
                };
                if (meets or tr.first.items[p] != none) {
                    tr.up.items[c] = @intCast(p);
                    tr.via.items[c] = c;
                } else {
                    tr.up.items[c] = tr.up.items[p];
                    tr.via.items[c] = tr.via.items[p];
                }
            }
        }
        return tr;
    }

    /// The members whose lists may hold together with list `t`, ascending.
    pub fn meeting(tr: *const Tree, gpa: Allocator, account: *Ids.Account, tags: *const Routes.Table, t: u32, out: *std.ArrayList(u32)) Error!void {
        const start = out.items.len;
        var n = t;
        var below: u32 = none;
        const hit = while (true) : (n = tags.tailOf(n)) {
            try account.reserve(.inspection, 1);
            if (tr.at.get(.{n})) |k| break k;
            below = n;
        };
        if (below == none) {
            // Lists with `t` as their tail: all of them.
            try tr.subtree(gpa, account, tags, hit, none, out);
        } else {
            try tr.members(gpa, account, hit, out);
            try tr.kidsApart(gpa, account, tags, hit, below, t, out);
        }
        var m = hit;
        while (tr.up.items[m] != none) {
            const p = tr.up.items[m];
            const v = tr.via.items[m];
            try tr.members(gpa, account, p, out);
            try tr.kidsApart(gpa, account, tags, p, tr.lists_of.items[v], t, out);
            m = p;
        }
        std.mem.sort(u32, out.items[start..], {}, std.sort.asc(u32));
    }

    fn members(tr: *const Tree, gpa: Allocator, account: *Ids.Account, n: u32, out: *std.ArrayList(u32)) Error!void {
        var i = tr.first.items[n];
        while (i != none) : (i = tr.next.items[i]) {
            try account.reserve(.inspection, 1);
            try out.append(gpa, i);
        }
    }

    /// The members below the kids of `p` that do not part from the asked
    /// path's pair `own` (a kid on the path parts from none: its list is
    /// `own`), each tested against `t`.
    fn kidsApart(tr: *const Tree, gpa: Allocator, account: *Ids.Account, tags: *const Routes.Table, p: u32, own: u32, t: u32, out: *std.ArrayList(u32)) Error!void {
        var c = tr.kid.items[p];
        while (c != none) : (c = tr.sib.items[c]) {
            try account.reserve(.inspection, 1);
            if (tr.lists_of.items[c] == own or tags.parts(tr.lists_of.items[c], own)) continue;
            try tr.subtree(gpa, account, tags, c, t, out);
        }
    }

    /// The members at and below node `n`, those whose lists hold with `t`
    /// (every one when `t` is `none`).
    fn subtree(tr: *const Tree, gpa: Allocator, account: *Ids.Account, tags: *const Routes.Table, n: u32, t: u32, out: *std.ArrayList(u32)) Error!void {
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, n);
        while (stack.pop()) |x| {
            try account.reserve(.inspection, 1);
            var i = tr.first.items[x];
            while (i != none) : (i = tr.next.items[i]) {
                if (t == none or try tags.meet(account, tr.lists[i], t)) try out.append(gpa, i);
            }
            var c = tr.kid.items[x];
            while (c != none) : (c = tr.sib.items[c]) try stack.append(gpa, c);
        }
    }
};

/// One tree per key (a holder), made when its key is first asked with
/// more than eight members; fewer are all answered, each tested by its
/// reader as before.
pub const Forest = struct {
    trees: std.ArrayList(?Tree) = .empty,
    out: std.ArrayList(u32) = .empty,

    pub fn deinit(fo: *Forest, gpa: Allocator) void {
        for (fo.trees.items) |*t| if (t.*) |*x| x.deinit(gpa);
        fo.trees.deinit(gpa);
        fo.out.deinit(gpa);
    }

    /// The members of `key` whose lists may hold with `t`, ascending,
    /// valid until the next call; `n` members, `src.listOf(i)` the list of
    /// member `i`.
    pub fn meeting(fo: *Forest, gpa: Allocator, account: *Ids.Account, tags: *const Routes.Table, key: u32, n: usize, src: anytype, t: u32) Error![]const u32 {
        fo.out.clearRetainingCapacity();
        if (n <= 8) {
            for (0..n) |k| try fo.out.append(gpa, @intCast(k));
            return fo.out.items;
        }
        if (key >= fo.trees.items.len) try fo.trees.appendNTimes(gpa, null, key + 1 - fo.trees.items.len);
        if (fo.trees.items[key] == null) {
            const ls = try gpa.alloc(u32, n);
            defer gpa.free(ls);
            for (ls, 0..) |*l, i| l.* = src.listOf(i);
            fo.trees.items[key] = try Tree.build(gpa, account, tags, ls);
        }
        try fo.trees.items[key].?.meeting(gpa, account, tags, t, &fo.out);
        return fo.out.items;
    }
};
