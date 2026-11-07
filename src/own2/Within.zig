//! L5: `within` (`docs/design/ownership-v2.md` §2.10): a contract says no
//! more than another. Split from `Contract` (#1991).
//!
//! Obligations kept here: none of §2.14's directly; it is §2.12's validation
//! test.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const Forest = @import("Forest.zig");
const Contract = @import("Contract.zig");

const Table = Contract.Table;
const Id = Contract.Id;
const Head = Contract.Head;
const Label = Contract.Label;
const Range = Contract.Range;
const Node = Contract.Node;
const Arrival = Contract.Arrival;

fn readsWithin(t: *const Table, arena: Allocator, a: Range, b: Range) Ids.IndexError!bool {
    var memo: Ids.FixedDict(2) = .{};
    for (t.readsOf(a)) |x| {
        const y = for (t.readsOf(b)) |y| {
            if (y[0] == x[0]) break y[1];
        } else 0;
        if (!try Forest.effectsWithin(&t.trees, arena, &memo, x[1], y)) return false;
    }
    return true;
}

/// `within(got, claim)` (§2.10): `got` says no more than `claim`.
pub fn within(t: *const Table, arena: Allocator, slots: *const Slots.Table, got: Id, claim: Id) Ids.IndexError!bool {
    const g = t.heads.items[got];
    const c = t.heads.items[claim];
    if (g.flags.returns and !c.flags.returns) return false;
    if (g.flags.once and !c.flags.once) return false;
    if ((g.flags.taken_write and !c.flags.taken_write) or (g.flags.entry and !c.flags.entry)) return false;
    for ([_]bool{ false, true }) |read| if (g.flags.returns) {
        const cr = try t.resCond(arena, claim, read);
        if (!cr.no and !(try t.resCond(arena, got, read)).weakerIn(slots, cr)) return false;
    };
    if (!(try t.cond(arena, g.req)).weakerIn(slots, try t.cond(arena, c.req))) return false;
    if (!try readsWithin(t, arena, g.reads, c.reads) or !try readsWithin(t, arena, g.writes, c.writes) or !effectsWithin(t, slots, g.escapes, c.escapes)) return false;
    // A condition asked more is an escape more often.
    for (t.storesOf(g.stores)) |s| {
        const y = for (t.storesOf(c.stores)) |y| {
            if (y.j == s.j and y.slot == s.slot) break y;
        } else return false;
        if (!(try t.cond(arena, s.cond)).weakerIn(slots, try t.cond(arena, y.cond))) return false;
    }
    const ids: [2]Id = .{ got, claim };
    // Labels by identity; `cb` arrivals compared through them.
    for (t.labelsOf(g.labels)) |l| {
        const m = findLabel(t, c, l) orelse return false;
        if (@backingInt(l.calls) > @backingInt(m.calls) or (l.answer_left and !m.answer_left)) return false;
        for (t.suppliesOf(l.supplies)) |s| {
            const u = for (t.suppliesOf(m.supplies)) |u| {
                if (u.k == s.k) break u;
            } else return false;
            if ((u.each and !s.each) or (u.walk and !s.walk)) return false;
            if (!try treeWithin(t, arena, slots, ids, s.res_root, u.res_root)) return false;
            if (!effectsWithin(t, slots, s.kept, u.kept)) return false;
            if (!u.below.no and !(try t.cond(arena, s.below)).weakerIn(slots, try t.cond(arena, u.below))) return false;
            if (!u.cond.no and !(try t.cond(arena, s.cond)).weakerIn(slots, try t.cond(arena, u.cond))) return false;
        }
    }
    return treeWithin(t, arena, slots, ids, g.res_root, c.res_root);
}

fn findLabel(t: *const Table, h: Head, l: Label) ?Label {
    for (t.labelsOf(h.labels)) |m| if (m.j == l.j and m.slot == l.slot and std.mem.eql(u32, &m.origin, &l.origin)) return m;
    return null;
}

/// Every effect of `a` is one of `b`'s, or below a deep one of `b`'s.
fn effectsWithin(t: *const Table, slots: *const Slots.Table, a: Range, b: Range) bool {
    for (t.effectsOf(a)) |x| {
        const found = for (t.effectsOf(b)) |y| {
            if (x.j != y.j) continue;
            if (x.slot == y.slot and (!x.deep or y.deep)) break true;
            if (y.deep and Table.continues(slots, y.slot, &.{}, x.slot, true)) break true;
        } else false;
        if (!found) return false;
    }
    return true;
}

/// Every arrival of tree `a` is one of `b`'s at its slot: of `b`'s run
/// of the same kind there, or of an open node of `b` above it,
/// continued by the steps between (an atom is the same at every slot
/// below). A node of `a` is checked once per node of `b` its slot
/// reaches with the same open nodes above it.
fn treeWithin(t: *const Table, arena: Allocator, slots: *const Slots.Table, ids: [2]Id, a: Node, b: Node) Allocator.Error!bool {
    var path: std.ArrayList(u32) = .empty;
    var above: std.ArrayList([2]u32) = .empty;
    return nodeWithin(t, arena, slots, ids, a, b, &path, &above);
}

fn nodeWithin(t: *const Table, arena: Allocator, slots: *const Slots.Table, ids: [2]Id, a: Node, b: Node, path: *std.ArrayList(u32), above: *std.ArrayList([2]u32)) Allocator.Error!bool {
    if (a == 0) return true;
    const tr = &t.trees;
    for ([_]bool{ false, true }) |open| for (if (open) tr.open(a) else tr.here(a)) |p| {
        const found = blk: {
            // `b`'s runs at this slot: its plain one only for a plain arrival.
            if (!open) for (tr.here(b)) |q| if (arrivalHas(t, slots, ids, q, p, &.{})) break :blk true;
            for (tr.open(b)) |q| if (arrivalHas(t, slots, ids, q, p, &.{})) break :blk true;
            for (above.items) |ab| for (tr.open(ab[0])) |q| if (arrivalHas(t, slots, ids, q, p, path.items[ab[1]..])) break :blk true;
            break :blk false;
        };
        if (!found) return false;
    };
    const pushed = tr.open(b).len != 0;
    if (pushed) try above.append(arena, .{ b, @intCast(path.items.len) });
    defer if (pushed) {
        _ = above.pop();
    };
    for (tr.kids(a)) |k| {
        try path.append(arena, k[0]);
        defer _ = path.pop();
        if (!try nodeWithin(t, arena, slots, ids, k[1], tr.kidAt(b, k[0]) orelse 0, path, above)) return false;
    }
    return true;
}

/// Whether claim's arrival `q` holds `got`'s `p` once continued by `suffix`.
fn arrivalHas(t: *const Table, slots: *const Slots.Table, ids: [2]Id, q: Arrival, p: Arrival, suffix: []const u32) bool {
    if (p.kind != q.kind) return false;
    switch (p.kind) {
        .fresh, .top, .host => return true,
        .shared => return p.j == q.j and p.slot == q.slot,
        .cb => {
            const lp = t.labelAt(ids[0], p.j);
            const lq = t.labelAt(ids[1], q.j);
            return lp.j == lq.j and lp.slot == lq.slot and std.mem.eql(u32, &lp.origin, &lq.origin) and Table.continues(slots, q.slot, suffix, p.slot, false);
        },
        .param, .lent => return p.j == q.j and (!p.deep or q.deep) and Table.continues(slots, q.slot, suffix, p.slot, q.deep),
    }
}

const testing = std.testing;
const Place = @import("Place.zig");
const Draft = Contract.Draft;

test "a join keeps every result slot of both sides" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var account: Ids.Account = .{};
    defer account.deinit(gpa);
    var slots: Slots.Table = .{};
    defer slots.deinit(gpa);
    var places: Place.Table = .{};
    defer places.deinit(gpa);
    var t: Table = .{};
    defer t.deinit(gpa);
    const r1 = try slots.relOfWords(gpa, &account, &places, &.{1});
    const r2 = try slots.relOfWords(gpa, &account, &places, &.{2});
    var da: Draft = .{ .arity = 1, .flags = .{ .returns = true } };
    _ = try Draft.addArrival(&da.res, arena, r1, .{ .kind = .param, .j = 0, .slot = r1 });
    var db: Draft = .{ .arity = 1, .flags = .{ .returns = true } };
    _ = try Draft.addArrival(&db.res, arena, r2, .{ .kind = .fresh });
    const a = try t.commit(gpa, &account, &slots, &da);
    const b = try t.commit(gpa, &account, &slots, &db);
    const j = try t.join(gpa, arena, &account, &slots, a, b);
    try testing.expectEqual(@as(u32, 2), t.trees.count(t.head(j).res_root));
    try testing.expect(try within(&t, arena, &slots, a, j) and try within(&t, arena, &slots, b, j) and !try within(&t, arena, &slots, j, a));
}
