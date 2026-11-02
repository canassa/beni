//! L6: the entries of the distinct check (`docs/design/ownership-v2.md`
//! §2.9.3) and the state its rounds keep: the entries, made once each, with
//! the expansion they came from (their order is the inline order the check
//! reads); their groups by root and by atom, kept across rounds, each with
//! the index of the pairs within it; and the roots a round may expand, by
//! two heaps. A round re-checks only the groups its expansion changed, and
//! each group only for its new entries' pairs: one call root expanded a
//! round regrouped every entry, n rounds of n entries for a literal of n
//! calls. This is the fixpoint's own working state, not a table of answers.
//!
//! Obligations kept here: the distinct check's half of O3: every pair of
//! entries of one group that may name one object is compared, once its
//! later entry is in the group.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const Subtree = @import("Subtree.zig");
const Contract = @import("Contract.zig");
const Value = @import("Value.zig");

pub const Error = Ids.ChargeError;
const Frame = Value.Frame;
const none: u32 = Ids.none_int;

pub const Ent = struct { leaf: u32, route: u32, occ: u64, block: u32 };

/// The occurrences a check gathers, each once.
pub const Occs = struct {
    run: std.ArrayList(u64) = .empty,
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,
    pub fn deinit(o: *Occs, g: Allocator) void {
        o.run.deinit(g);
        o.seen.deinit(g);
    }
    pub fn add(o: *Occs, g: Allocator, x: u64) Allocator.Error!void {
        if ((try o.seen.getOrPut(g, x)).found_existing) return;
        try o.run.append(g, x);
    }
};

/// Whether a group's one entry names more than one object: two slots, a
/// subtree held whole (`↓p`, §2.3.1), or one that no step below can name.
pub fn manyObjects(f: *Frame, ents: []const Ent, idx: []const u32) bool {
    if (idx.len != 1) return false;
    return f.slots.elems(f.leafAt(ents[idx[0]].leaf).slots).len >= 2 or wildEntry(f, ents[idx[0]]);
}

/// Whether an entry has a slot of a type variable's or an opaque place. A
/// subtree held whole is read as one: its slots are not listed.
pub fn wildEntry(f: *Frame, en: Ent) bool {
    for (f.slots.elems(f.leafAt(en.leaf).slots)) |x| {
        if (Slots.isNot(x)) continue;
        if (Slots.isSub(x)) return true;
        switch (f.places.kind(f.places.pathPlace(Slots.pathOf(x)))) {
            .@"var", .@"opaque" => return true,
            else => {},
        }
    }
    return false;
}

pub fn anyApart(ents: []const Ent, idx: []const u32) bool {
    for (idx) |i| if (Contract.isApart(ents[i].occ)) return true;
    return false;
}

pub fn allApart(ents: []const Ent, idx: []const u32) bool {
    for (idx) |i| if (!Contract.isApart(ents[i].occ)) return false;
    return true;
}

/// Whether two entries `idx` of one atom may hold together (`Routes.Table.anyPair`).
pub fn atomTwice(f: *Frame, ents: []const Ent, idx: []const u32) Error!bool {
    var es: std.ArrayList(@TypeOf(f.sets.tags).Entry) = .empty;
    defer es.deinit(f.gpa);
    for (idx) |i| try es.append(f.gpa, .{ .tags = f.leafAt(ents[i].leaf).tags, .block = ents[i].block, .apart = Contract.isApart(ents[i].occ) });
    return f.sets.tags.anyPair(f.gpa, f.account, es.items);
}

pub fn pairMay(f: *Frame, a: Ent, b: Ent, routed: bool) Error!bool {
    try f.charge(.cond, 1);
    if (a.block != none and a.block == b.block) return false;
    if (a.leaf == b.leaf and a.route == b.route and a.occ == b.occ) return false;
    // Apart occurrences need only be apart from the plain ones.
    if (Contract.isApart(a.occ) and Contract.isApart(b.occ)) return false;
    const la = f.leafAt(a.leaf);
    const lb = f.leafAt(b.leaf);
    if (!try f.sets.tags.meet(f.account, la.tags, lb.tags)) return false;
    // Two distinct occurrences of a callee at one value by one route are
    // two distinct positions of it (§2.9.3's routed rule).
    if (routed and a.route == b.route and a.occ != b.occ and la.pos == lb.pos) return false;
    if (la.at_pos and lb.at_pos and la.pos != lb.pos) return false;
    const r = try f.related(la.pos, lb.pos);
    return r.rel == .related and try Subtree.meetIn(f.slots, f.gpa, f.account, f.places, la.slots, lb.slots);
}

/// Whether a callback's answer among `ents` may be another entry's object
/// (§2.9.3, #1711), for the pairs with an entry from `fresh` on: the
/// earlier pairs were asked in an earlier round. Unknown code may answer
/// any object its caller reaches, so an answer is apart from no other
/// entry but an alternative to it or one its own block vouches for.
pub fn answerMeets(f: *Frame, ents: []const Ent, alive: []const bool, fresh: usize) Error!bool {
    for (ents, 0..) |en, i| {
        if (!alive[i] or !isAnswer(f, f.leafAt(en.leaf))) continue;
        for (ents[if (i >= fresh) 0 else fresh..], if (i >= fresh) 0 else fresh..) |o, k| {
            if (k == i or !alive[k]) continue;
            if (o.block != none and o.block == en.block) continue;
            if (try f.sets.tags.meet(f.account, f.leafAt(en.leaf).tags, f.leafAt(o.leaf).tags)) return true;
        }
    }
    return false;
}

fn isAnswer(f: *const Frame, l: Value.Leaf) bool {
    return l.kind == .answer or (l.kind == .ref and f.roots.items[l.root].kind == .cb);
}

/// The pairs within one group (§2.9.3): its first `seen` members were
/// compared already; a new one is compared with every earlier one up to
/// eight, then by index `(position, 4, slot)`, `(ancestor, list step kind,
/// slot)` and `(ancestor, 5, slot)` for what lies below a position.
pub const Within = struct {
    seen: u32 = 0,
    indexed: bool = false,
    at: Ids.FixedDict(3) = .{},
    lists: std.ArrayList(std.ArrayList(u32)) = .empty,
    /// The members that hold a whole subtree (`↓p`, §2.3.1): they meet
    /// slots by prefix, not by name, so each is compared with every other.
    sym: std.ArrayList(u32) = .empty,

    pub fn deinit(x: *Within, g: Allocator) void {
        x.at.deinit(g);
        for (x.lists.items) |*l| l.deinit(g);
        x.lists.deinit(g);
        x.sym.deinit(g);
    }

    /// Whether a new member of `members` may name an earlier member's object.
    pub fn add(x: *Within, f: *Frame, ents: []const Ent, members: []const u32, routed: bool) Error!bool {
        defer x.seen = @intCast(members.len);
        if (members.len <= 8) {
            for (members[x.seen..], x.seen..) |i, k| for (members[0..k]) |j| {
                if (try pairMay(f, ents[i], ents[j], routed)) return true;
            };
            return false;
        }
        if (!x.indexed) {
            x.indexed = true;
            for (members[0..x.seen]) |j| try x.register(f, ents, j);
        }
        for (members[x.seen..], x.seen..) |i, k| {
            if (try x.lookup(f, ents, members[0..k], i, routed)) return true;
            try x.register(f, ents, i);
        }
        return false;
    }

    fn put(x: *Within, f: *Frame, key: [3]u32, i: u32) Error!void {
        try f.charge(.inspection, 1);
        const got = try x.at.getOrPut(f.gpa, key);
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(x.lists.items.len);
            try x.lists.append(f.gpa, .empty);
        }
        try x.lists.items[got.value_ptr.*].append(f.gpa, i);
    }

    fn register(x: *Within, f: *Frame, ents: []const Ent, i: u32) Error!void {
        const l = f.leafAt(ents[i].leaf);
        if (Subtree.symbolic(f.slots, l.slots)) try x.sym.append(f.gpa, i);
        const pos = f.pos.items;
        for (Subtree.explicit(f.slots, l.slots)) |s| {
            try x.put(f, .{ l.pos, 4, s }, i);
            var a = l.pos;
            while (pos[a].parent != none) : (a = pos[a].parent) try x.put(f, .{ pos[a].parent, 5, s }, i);
            var c = l.pos;
            while (true) {
                while (pos[c].parent != none and pos[c].kind == .plain) c = pos[c].parent;
                if (pos[c].parent == none) break;
                try x.put(f, .{ pos[c].parent, @backingInt(pos[c].kind), s }, i);
                c = pos[c].parent;
            }
        }
    }

    fn lookup(x: *Within, f: *Frame, ents: []const Ent, earlier: []const u32, i: u32, routed: bool) Error!bool {
        const l = f.leafAt(ents[i].leaf);
        const sym = Subtree.symbolic(f.slots, l.slots);
        for (if (sym) earlier else x.sym.items) |j| if (try pairMay(f, ents[i], ents[j], routed)) return true;
        const pos = f.pos.items;
        for (Subtree.explicit(f.slots, l.slots)) |s| {
            try f.charge(.inspection, 1);
            if (x.at.get(.{ l.pos, 5, s })) |here| for (x.lists.items[here].items) |j| {
                if (try pairMay(f, ents[i], ents[j], routed)) return true;
            };
            var p = l.pos;
            while (p != none) : (p = pos[p].parent) {
                try f.charge(.inspection, 1);
                if (x.at.get(.{ p, 4, s })) |here| for (x.lists.items[here].items) |j| {
                    if (try pairMay(f, ents[i], ents[j], routed)) return true;
                };
                if (pos[p].parent == none) continue;
                const kinds: []const u32 = switch (pos[p].kind) {
                    .plain => &.{},
                    .front => &.{ 2, 3 },
                    .back => &.{ 1, 3 },
                    .slice => &.{ 1, 2, 3 },
                };
                for (kinds) |k| {
                    try f.charge(.inspection, 1);
                    const here = x.at.get(.{ pos[p].parent, k, s }) orelse continue;
                    for (x.lists.items[here].items) |j| if (try pairMay(f, ents[i], ents[j], routed)) return true;
                }
            }
        }
        return false;
    }
};

/// A group: a root's entries (`root`) or an atom's (`none`).
pub const Group = struct {
    root: u32,
    members: std.ArrayList(u32) = .empty,
    within: Within = .{},
    dirty: bool = false,
    /// A parameter group's members whose occurrences are gathered.
    occ_done: u32 = 0,
    /// The group asks to be expanded first: 1 unvouched, 2 vouched.
    must: u8 = 0,
};

/// The rounds' state of one check (§2.9.3).
pub const Rounds = struct {
    ents: std.ArrayList(Ent) = .empty,
    alive: std.ArrayList(bool) = .empty,
    /// Per entry, the expanded entry it came from (`none`: given), its
    /// place in that expansion, and its depth: the inline order.
    par: std.ArrayList([3]u32) = .empty,
    groups: std.ArrayList(Group) = .empty,
    of_root: std.ArrayList(u32) = .empty,
    atoms: Ids.FixedDict(3) = .{},
    nonempty: u32 = 0,
    params: u32 = 0,
    /// The groups changed since the last round's checks.
    dirty: std.ArrayList(u32) = .empty,
    /// The roots that may be expanded and the groups that ask to be, by
    /// root (max-heaps, stale entries skipped when read).
    expandable: std.ArrayList(u32) = .empty,
    musts: std.ArrayList(u32) = .empty,

    pub fn deinit(r: *Rounds, g: Allocator) void {
        for (r.groups.items) |*gr| {
            gr.members.deinit(g);
            gr.within.deinit(g);
        }
        inline for (.{ &r.ents, &r.alive, &r.par, &r.groups, &r.of_root, &r.expandable, &r.musts, &r.dirty }) |l| l.deinit(g);
        r.atoms.deinit(g);
    }

    pub fn add(r: *Rounds, g: Allocator, en: Ent, par: [3]u32) Error!void {
        try r.ents.append(g, en);
        try r.alive.append(g, true);
        try r.par.append(g, par);
    }

    /// Put entry `i` in its group (a root's, an atom's, or none), which is
    /// then dirty.
    pub fn place(r: *Rounds, f: *Frame, i: u32) Error!void {
        const g = f.gpa;
        const l = f.leafAt(r.ents.items[i].leaf);
        const gi: u32 = switch (l.kind) {
            .ref => blk: {
                if (l.root >= r.of_root.items.len) try r.of_root.appendNTimes(g, none, l.root + 1 - r.of_root.items.len);
                if (r.of_root.items[l.root] == none) {
                    r.of_root.items[l.root] = @intCast(r.groups.items.len);
                    try r.groups.append(g, .{ .root = l.root });
                    if (f.roots.items[l.root].kind == .param) r.params += 1;
                }
                break :blk r.of_root.items[l.root];
            },
            .site, .fresh => blk: {
                const got = try r.atoms.getOrPut(g, .{ @backingInt(l.kind), l.atom, 0 });
                if (!got.found_existing) {
                    got.value_ptr.* = @intCast(r.groups.items.len);
                    try r.groups.append(g, .{ .root = none });
                }
                break :blk got.value_ptr.*;
            },
            else => return,
        };
        const gr = &r.groups.items[gi];
        if (gr.members.items.len == 0) {
            r.nonempty += 1;
            if (gr.root != none) switch (f.roots.items[gr.root].kind) {
                .call, .supply => try push(g, &r.expandable, gr.root),
                else => {},
            };
        }
        try gr.members.append(g, i);
        try r.mark(g, gi);
    }

    pub fn mark(r: *Rounds, g: Allocator, gi: u32) Error!void {
        if (r.groups.items[gi].dirty) return;
        r.groups.items[gi].dirty = true;
        try r.dirty.append(g, gi);
    }

    /// The greatest root of `heap` whose group `ok` says is still one.
    pub fn top(r: *Rounds, heap: *std.ArrayList(u32), comptime ok: fn (*const Group) bool) ?u32 {
        while (heap.items.len != 0) {
            const root = heap.items[0];
            if (ok(&r.groups.items[r.of_root.items[root]])) return root;
            pop(heap);
        }
        return null;
    }

    pub fn push(g: Allocator, heap: *std.ArrayList(u32), root: u32) Error!void {
        try heap.append(g, root);
        var c = heap.items.len - 1;
        while (c > 0 and heap.items[(c - 1) / 2] < heap.items[c]) : (c = (c - 1) / 2) std.mem.swap(u32, &heap.items[c], &heap.items[(c - 1) / 2]);
    }

    fn pop(heap: *std.ArrayList(u32)) void {
        const h = heap.items;
        h[0] = h[h.len - 1];
        heap.items.len -= 1;
        var c: usize = 0;
        while (true) {
            var m = c;
            for ([_]usize{ 2 * c + 1, 2 * c + 2 }) |k| if (k < heap.items.len and heap.items[k] > heap.items[m]) {
                m = k;
            };
            if (m == c) return;
            std.mem.swap(u32, &heap.items[c], &heap.items[m]);
            c = m;
        }
    }

    /// Empty the group of `root` into `out`: its members are expanded.
    pub fn take(r: *Rounds, g: Allocator, root: u32, out: *std.ArrayList(u32)) Error!void {
        const gr = &r.groups.items[r.of_root.items[root]];
        for (gr.members.items) |i| r.alive.items[i] = false;
        try out.appendSlice(g, gr.members.items);
        gr.members.clearRetainingCapacity();
        gr.within.deinit(g);
        gr.within = .{};
        gr.occ_done = 0;
        gr.must = 0;
        r.nonempty -= 1;
    }

    /// Whether entry `a` comes before `b` in the inline order: by the
    /// expansions they came from, a record a step.
    pub fn before(r: *const Rounds, f: *Frame, a: u32, b: u32) Error!bool {
        var x = a;
        var y = b;
        const p = r.par.items;
        while (p[x][2] > p[y][2]) : (x = p[x][0]) try f.charge(.cond, 1);
        while (p[y][2] > p[x][2]) : (y = p[y][0]) try f.charge(.cond, 1);
        while (p[x][0] != p[y][0]) : ({
            x = p[x][0];
            y = p[y][0];
        }) try f.charge(.cond, 1);
        return p[x][1] < p[y][1];
    }
};
