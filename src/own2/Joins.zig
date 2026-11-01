//! The join index (`docs/design/ownership-v2.md` §2.8 step 3, *The join
//! index*, #1510): a node's joins at its own path flattened once, so the
//! holder index reads the states and hold bits of `closure(n0, x, c)` for
//! each candidate `x` without walking a chain of joins down to `x`.
//!
//! **Members.** Every record a closure may read at `n0`'s path, from `n0`
//! by the sides `sides` names (a union's, a choice's and a positions
//! node's two, a delta's base, a recast's inner), with each combination of
//! route flags (`alt`, `cast`) a path of joins reaches it under: a fixed
//! point over four combinations, so a cycle of joins ends. Each is an
//! explicit side, so a member's reach holds its sides' (`Shape.reach`). A
//! node whose joins meet a view has no index (`get` is null): the walk
//! forces each view it enters, in its own order, and a view's reach need
//! not hold its answer's cells.
//!
//! **What a read takes apart.** A node or a delta (its children and its own
//! hold) and a lazy record (its own cells, read when asked): each a leaf of
//! a tree of reach unions, so the members whose reach holds `x` are found
//! in O(hits · log members). Every other member (an eager join, recast or
//! leaf, whose reach holds its cells) is folded: its cells into `plain` or
//! `alt` by the hold it gives, so one lookup each gives their hold bits.
//!
//! Obligations kept here: none (a representation of `Holders`' closure,
//! which keeps them).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Cell = @import("Cell.zig");
const Shape = @import("Shape.zig");

pub const NodeId = Ids.NodeId;
pub const CellId = Ids.CellId;
pub const SetId = Ids.SetId;
pub const Error = Ids.ChargeError;

pub const Ctx = struct {
    gpa: Allocator,
    charge: Ids.Charge,
    shapes: *Shape.Table,
    cells: *Cell.Table,

    fn rec(c: Ctx, n: u32) Error!void {
        try c.charge.reserve(c.gpa, .inspection, n);
    }

    fn reach(c: Ctx, n: NodeId) Error!SetId {
        return c.shapes.reach(c.gpa, c.charge.account, &c.cells.sets, n);
    }
};

/// A side at one path and the route flags it adds.
pub const Side = struct { node: NodeId, alt: bool = false, cast: bool = false };

/// `combos`: bit `k` when a path of joins reaches the member with flags
/// `k` (bit 0 `alt`, bit 1 `cast`). `frontier`: a node or a delta, whose
/// children that reach `x` are states; otherwise a lazy record.
pub const Member = struct { node: NodeId, combos: u4, frontier: bool };

/// One node's joins: `members`, a run of `Index.members`, under the reach
/// tree at `tree` (heap order, root at 1); the folded members' cells by
/// the hold they give, `plain` (one cell, a combination with no `alt`) and
/// `alt` (several cells, or a combination with `alt`).
pub const Joins = struct { members: Ids.Range, tree: u32, plain: SetId = .none, alt: SetId = .none };

/// The folded members' hold bits for one cell: some hold; one neither
/// approximate nor one of several; one of several only.
pub const Bits = struct { any: bool, plain: bool, alt: bool };

/// The sides at one path of `n` with the flags they add; a view's answer
/// is no explicit side (`get` stops at a view).
pub fn sides(shapes: *const Shape.Table, n: NodeId) struct { [2]Side, usize } {
    const k = shapes.get(n);
    return switch (k.kind) {
        .leaf, .node, .view => .{ undefined, 0 },
        .delta => .{ .{ .{ .node = .from(k.a) }, undefined }, 1 },
        .recast => .{ .{ .{ .node = .from(k.a), .cast = true }, undefined }, 1 },
        .@"union", .choice, .positions => blk: {
            const alt = k.kind == .@"union" or k.kind == .choice;
            break :blk .{ .{ .{ .node = .from(k.a), .alt = alt }, .{ .node = .from(k.b), .alt = alt } }, 2 };
        },
    };
}

fn comboOf(s: Side) u2 {
    return @as(u2, @intFromBool(s.alt)) | @as(u2, @intFromBool(s.cast)) << 1;
}

fn several(cellt: *const Cell.Table, s: SetId) bool {
    var it = cellt.sets.iterate(s);
    return it.next() != null and it.next() != null;
}

/// The join indexes of one holder index, by node; `none` for a node whose
/// joins meet a view.
pub const Index = struct {
    of: Ids.FixedDict(1) = .{},
    joins: std.ArrayList(Joins) = .empty,
    members: std.ArrayList(Member) = .empty,
    tree: std.ArrayList(SetId) = .empty,

    pub fn deinit(t: *Index, gpa: Allocator) void {
        t.of.deinit(gpa);
        t.joins.deinit(gpa);
        t.members.deinit(gpa);
        t.tree.deinit(gpa);
    }

    /// `n0`'s joins, flattened on first ask, or null when they meet a view:
    /// a record per member and combination, then one per member, and the
    /// unions the tree and the folded classes charge.
    pub fn get(t: *Index, c: Ctx, n0: NodeId) Error!?Joins {
        if (t.of.get(.{n0.int()})) |j| return if (j == Ids.none_int) null else t.joins.items[j];
        const gpa = c.gpa;
        var at: Ids.FixedDict(1) = .{};
        defer at.deinit(gpa);
        var order: std.ArrayList(NodeId) = .empty;
        defer order.deinit(gpa);
        var masks: std.ArrayList(u4) = .empty;
        defer masks.deinit(gpa);
        var work: std.ArrayList(struct { u32, u2 }) = .empty;
        defer work.deinit(gpa);
        const Flat = struct {
            at: *Ids.FixedDict(1),
            order: *std.ArrayList(NodeId),
            masks: *std.ArrayList(u4),
            work: *std.ArrayList(struct { u32, u2 }),

            fn add(f: @This(), g: Allocator, n: NodeId, k: u2) Allocator.Error!void {
                const got = try f.at.getOrPut(g, .{n.int()});
                if (!got.found_existing) {
                    got.value_ptr.* = @intCast(f.order.items.len);
                    try f.order.append(g, n);
                    try f.masks.append(g, 0);
                }
                const bit = @as(u4, 1) << k;
                if (f.masks.items[got.value_ptr.*] & bit != 0) return;
                f.masks.items[got.value_ptr.*] |= bit;
                try f.work.append(g, .{ got.value_ptr.*, k });
            }
        };
        const flat: Flat = .{ .at = &at, .order = &order, .masks = &masks, .work = &work };
        try flat.add(gpa, n0, 0);
        while (work.pop()) |item| {
            try c.rec(1);
            const m = order.items[item[0]];
            if (c.shapes.kind(m) == .view) {
                (try t.of.getOrPut(gpa, .{n0.int()})).value_ptr.* = Ids.none_int;
                return null;
            }
            const two = sides(c.shapes, m);
            for (two[0][0..two[1]]) |side| try flat.add(gpa, side.node, item[1] | comboOf(side));
        }
        const sets = &c.cells.sets;
        var j: Joins = .{ .members = .{ .start = @intCast(t.members.items.len), .len = 0 }, .tree = @intCast(t.tree.items.len) };
        for (order.items, masks.items) |m, mask| {
            try c.rec(1);
            const kind = c.shapes.kind(m);
            const frontier = kind == .node or kind == .delta;
            if (frontier or c.shapes.isLazy(m)) {
                try t.members.append(gpa, .{ .node = m, .combos = mask, .frontier = frontier });
                continue;
            }
            // Folded: its hold of `x` is plain when its cells are one and a
            // combination has no `alt`, one of several when they are more
            // or a combination has `alt`, approximate by the cell's value;
            // `and` keeps an exact one.
            const cs = c.shapes.cells(m);
            const sev = several(c.cells, cs);
            if (!sev and mask & 0b0101 != 0) j.plain = try sets.unionWith(gpa, c.charge, j.plain, cs);
            if (sev or mask & 0b1010 != 0) j.alt = try sets.unionWith(gpa, c.charge, j.alt, cs);
        }
        j.members.len = @as(u32, @intCast(t.members.items.len)) - j.members.start;
        if (j.members.len > 0) {
            try t.tree.appendNTimes(gpa, .none, 2 * std.math.ceilPowerOfTwoAssert(u32, j.members.len));
            _ = try t.build(c, j, 1, 0, j.members.len);
        }
        (try t.of.getOrPut(gpa, .{n0.int()})).value_ptr.* = @intCast(t.joins.items.len);
        try t.joins.append(gpa, j);
        return j;
    }

    /// The union of members `[lo, hi)`'s reaches at tree node `i`.
    fn build(t: *Index, c: Ctx, j: Joins, i: u32, lo: u32, hi: u32) Error!SetId {
        const s = if (hi - lo == 1)
            try c.reach(t.members.items[j.members.start + lo].node)
        else blk: {
            const mid = lo + (hi - lo + 1) / 2;
            const l = try t.build(c, j, 2 * i, lo, mid);
            const r = try t.build(c, j, 2 * i + 1, mid, hi);
            break :blk try c.cells.sets.unionWith(c.gpa, c.charge, l, r);
        };
        t.tree.items[j.tree + i] = s;
        return s;
    }

    /// The members of `j` whose reach holds `x`, as indexes into
    /// `members`, in member order: a record per tree node read.
    pub fn hits(t: *const Index, c: Ctx, j: Joins, x: CellId, out: *std.ArrayList(u32)) Error!void {
        if (j.members.len > 0) try t.descend(c, j, x, 1, 0, j.members.len, out);
    }

    fn descend(t: *const Index, c: Ctx, j: Joins, x: CellId, i: u32, lo: u32, hi: u32, out: *std.ArrayList(u32)) Error!void {
        try c.rec(1);
        if (!c.cells.sets.member(t.tree.items[j.tree + i], x.int())) return;
        if (hi - lo == 1) return out.append(c.gpa, j.members.start + lo);
        const mid = lo + (hi - lo + 1) / 2;
        try t.descend(c, j, x, 2 * i, lo, mid, out);
        try t.descend(c, j, x, 2 * i + 1, mid, hi, out);
    }
};

/// The folded members' hold bits for `x`, a lookup a class.
pub fn folded(cellt: *const Cell.Table, j: Joins, x: CellId) Bits {
    const vp = cellt.sets.get(j.plain, x.int());
    const va = cellt.sets.get(j.alt, x.int());
    return .{ .any = vp != null or va != null, .plain = vp == 0, .alt = va == 0 };
}
