//! L6: the relation solved (`docs/design/ownership-v2.md` §2.9.2, *The fixed
//! point of the pairs*). The relation of two leaves is the least fixed point
//! of an equation per pair: a pair's value is made from the values of the
//! pairs it reaches, and those can reach it back (a fold's supply and its
//! answer). This is the solver of that system, a depth-first walk that finds
//! its strongly connected components as it goes (Tarjan's: rows are numbered
//! in the order they are entered, and each tracks the lowest number it read).
//! A pair read while it is open gives the value it has so far; a row that read
//! no number below its own is its component's head, and the head walks the
//! component again until no value moves. Numbers, not depths: a closed
//! member's low is a depth a later sibling can stand at, and by depth that
//! sibling would pass for a head with a value made under a cut.
//!
//! `solved` is a retained table of the answers so far, kept for an evaluation
//! and dropped at the next outer query after a key grows: the owner's decision, an exception for this
//! table only (§2.9.2, *What is kept*). A row enters it when its head has
//! solved its component. A walk's own rows hold everything else and go with
//! the query. Equations that are not joins (`AnswerKeep.kept`) are not monotone
//! and have no least fixed point: there the walk accumulates, and order can
//! pick another post-fixed point (#2160).
//!
//! Obligations kept here: none of §2.14's directly (the relation's half of
//! O3 is `Distinct`'s; this is what makes its answer the least fixed point
//! and not the order the pairs were met in).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Conds = @import("Conds.zig");

const Cond = Conds.Cond;
const unread_low = std.math.maxInt(u32);

/// The relation of two leaves (§2.9.2).
pub const Ov = struct {
    kind: enum(u8) { no, under, may } = .no,
    cond: Cond = .{},

    pub const no: Ov = .{};
    pub const may: Ov = .{ .kind = .may };

    pub fn join(arena: Allocator, account: *Ids.Account, a: Ov, b: Ov) Ids.ChargeError!Ov {
        if (a.kind == .may or b.kind == .may) return may;
        if (a.kind == .no) return b;
        if (b.kind == .no or @import("Mutate.zig").on(.ov_join_left)) return a;
        const c = try Cond.conj(arena, account, a.cond, b.cond);
        return if (c.no) may else .{ .kind = .under, .cond = c };
    }

    fn eql(a: Ov, b: Ov) bool {
        return a.kind == b.kind and a.cond.eql(b.cond);
    }
};

const State = enum(u8) {
    /// Not walked, or to be walked again; `value` is what it had.
    unread,
    /// On the walk's stack; `at` is its number.
    open,
    /// Walked, in a component whose head is open; `at` is its low.
    member,
};

const Row = struct { value: Ov = .{}, state: State = .unread, at: u32 = 0 };

const Walk = struct {
    keys: Ids.FixedDict(3) = .{},
    rows: std.ArrayList(Row) = .empty,
    /// The rows of components whose heads are still open, oldest first.
    members: std.ArrayList(u32) = .empty,
    /// The next row's number.
    next: u32 = 0,
    /// The lowest number read since the current frame began.
    low: u32 = unread_low,
    /// A member's value moved since the current component's pass began.
    moved: bool = false,
};

/// A pair being walked. Its equation runs under it until `leave` says done.
pub const Frame = struct { row: u32, number: u32, low: u32, moved: bool, members: u32 };

pub const Entered = union(enum) { value: Ov, frame: Frame };

/// The relation solved, and the walks of the queries in progress, innermost
/// last: a query asked while another runs (a call's separation, a delivery)
/// reads the other's open rows never, and its solved ones as anyone does.
pub const Queries = struct {
    /// `(leaf, leaf, flags)` → `values`: a pair whose component is solved.
    solved: Ids.FixedDict(3) = .{},
    values: std.ArrayList(Ov) = .empty,
    /// What keys had gained when `solved` was begun (`Eval.grown`).
    grown: u32 = 0,
    walks: std.ArrayList(Walk) = .empty,
    open: u32 = 0,

    pub fn deinit(q: *Queries, gpa: Allocator) void {
        q.solved.deinit(gpa);
        q.values.deinit(gpa);
        for (q.walks.items) |*w| {
            w.keys.deinit(gpa);
            w.rows.deinit(gpa);
            w.members.deinit(gpa);
        }
        q.walks.deinit(gpa);
    }

    /// A query. `grown`: what keys have gained now. A key that grew changed
    /// what a leaf expands to, so nothing solved before it is the relation.
    pub fn begin(q: *Queries, gpa: Allocator, grown: u32) Allocator.Error!void {
        if (q.open == 0 and q.grown != grown) {
            q.grown = grown;
            q.solved.clear();
            q.values.clearRetainingCapacity();
        }
        if (q.open == q.walks.items.len) try q.walks.append(gpa, .{});
        const w = &q.walks.items[q.open];
        w.keys.clear();
        w.rows.clearRetainingCapacity();
        w.members.clearRetainingCapacity();
        w.next = 0;
        w.low = unread_low;
        w.moved = false;
        q.open += 1;
    }

    pub fn end(q: *Queries) void {
        q.open -= 1;
    }

    fn solve(q: *Queries, gpa: Allocator, w: *Walk, row: u32) Ids.IndexError!void {
        const r = &w.rows.items[row];
        r.state = .unread;
        try q.solved.put(gpa, w.keys.keyAt(row), @intCast(q.values.items.len));
        try q.values.append(gpa, r.value);
    }

    fn top(q: *Queries) *Walk {
        return &q.walks.items[q.open - 1];
    }

    /// Pair `key` read: its value, or a frame to walk it under.
    pub fn enter(q: *Queries, gpa: Allocator, key: [3]u32) Ids.IndexError!Entered {
        if (q.solved.get(key)) |i| return .{ .value = q.values.items[i] };
        const w = q.top();
        const got = try w.keys.getOrPut(gpa, key);
        if (!got.found_existing) try w.rows.append(gpa, .{});
        const r = &w.rows.items[got.index];
        switch (r.state) {
            .open, .member => {
                w.low = @min(w.low, r.at);
                return .{ .value = if (@import("Mutate.zig").on(.overlap_cycle_may)) Ov.may else r.value };
            },
            .unread => {},
        }
        const fr: Frame = .{ .row = got.index, .number = w.next, .low = w.low, .moved = w.moved, .members = @intCast(w.members.items.len) };
        r.state = .open;
        r.at = w.next;
        w.next += 1;
        w.low = unread_low;
        w.moved = false;
        return .{ .frame = fr };
    }

    /// A pass of `fr` made `got`. Its value, or null to walk the pair again.
    pub fn leave(q: *Queries, gpa: Allocator, arena: Allocator, account: *Ids.Account, fr: Frame, got: Ov) Ids.ChargeError!?Ov {
        const w = q.top();
        const before = w.rows.items[fr.row].value;
        const value = try Ov.join(arena, account, before, got);
        const moved = !value.eql(before);
        w.rows.items[fr.row].value = value;
        if (w.low < fr.number) {
            // Its component's head is further down: not final yet.
            w.rows.items[fr.row].state = .member;
            w.rows.items[fr.row].at = w.low;
            try w.members.append(gpa, fr.row);
            w.moved = w.moved or moved or fr.moved;
            w.low = @min(w.low, fr.low);
            return value;
        }
        const head = w.low == fr.number;
        if (head and value.kind != .may and (moved or w.moved) and !@import("Mutate.zig").on(.pairs_one_pass)) {
            // Again, from the values this pass reached.
            for (w.members.items[fr.members..]) |m| w.rows.items[m].state = .unread;
            w.members.items.len = fr.members;
            w.low = unread_low;
            w.moved = false;
            return null;
        }
        // `may` is the top: no further pass can move this row, but its
        // members saw less than it, so they are walked afresh if read again.
        const forget = value.kind == .may and (moved or w.moved);
        for (w.members.items[fr.members..]) |m| {
            if (forget) w.rows.items[m] = .{} else try q.solve(gpa, w, m);
        }
        w.members.items.len = fr.members;
        try q.solve(gpa, w, fr.row);
        w.low = fr.low;
        w.moved = fr.moved;
        return value;
    }
};

const testing = std.testing;

const random_systems = 700;

/// An equation system over `Queries`: `edges[p]` are the pairs `p` reads,
/// `base[p]` its own value, `lift[p]` a pair whose reads are `may` → `under`.
const System = struct {
    q: *Queries,
    arena: Allocator,
    account: *Ids.Account,
    edges: []const []const u32,
    base: []const Ov,

    fn read(s: System, p: u32) !Ov {
        const fr = switch (try s.q.enter(testing.allocator, .{ p, 0, 0 })) {
            .value => |v| return v,
            .frame => |fr| fr,
        };
        while (true) {
            var acc = s.base[p];
            for (s.edges[p]) |n| acc = try Ov.join(s.arena, s.account, acc, try s.read(n));
            if (try s.q.leave(testing.allocator, s.arena, s.account, fr, acc)) |v| return v;
        }
    }

    fn ask(s: System, p: u32) !Ov {
        try s.q.begin(testing.allocator, 0);
        defer s.q.end();
        return s.read(p);
    }
};

test "a pair read after the query that cut it has its fixed point, whichever was asked first" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var account: Ids.Account = .{};
    defer account.deinit(testing.allocator);
    // `a → [ b, t ]`, `b → [ a ]`: `b` reaches `t` through `a`. Asked at `a`, the
    // walk reaches `b` and cuts at `a`, so `b` has `no` until `a` is done.
    const under: Ov = .{ .kind = .under, .cond = .{ .sel = &.{7} } };
    const edges: []const []const u32 = &.{ &.{ 1, 2 }, &.{0}, &.{} };
    const base: []const Ov = &.{ .no, .no, under };
    for ([_][2]u32{ .{ 0, 1 }, .{ 1, 0 } }) |order| {
        var q: Queries = .{};
        defer q.deinit(testing.allocator);
        const s: System = .{ .q = &q, .arena = arena_state.allocator(), .account = &account, .edges = edges, .base = base };
        for (order) |p| try testing.expect((try s.ask(p)).eql(under));
    }
}

test "a cross edge to a closed member is no head" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var account: Ids.Account = .{};
    defer account.deinit(testing.allocator);
    // `H → [ A, C, t ]`, `A → [ H, B ]`, `B → [ A ]`, `C → [ B ]`. `A` is closed
    // when `C` reads `B`, whose low is `A`'s depth, and `C` stands at that
    // depth: by depth, `C` looks like a head, and is solved with `no`.
    const under: Ov = .{ .kind = .under, .cond = .{ .sel = &.{7} } };
    const edges: []const []const u32 = &.{ &.{ 1, 3, 4 }, &.{ 0, 2 }, &.{1}, &.{2}, &.{} };
    const base: []const Ov = &.{ .no, .no, .no, .no, under };
    for ([_][2]u32{ .{ 0, 3 }, .{ 3, 0 } }) |order| {
        var q: Queries = .{};
        defer q.deinit(testing.allocator);
        const s: System = .{ .q = &q, .arena = arena_state.allocator(), .account = &account, .edges = edges, .base = base };
        for (order) |p| try testing.expect((try s.ask(p)).eql(under));
        try testing.expect((try s.ask(2)).eql(under));
    }
}

test "random systems of joins have one answer, their least fixed point, in any order" {
    var prng = std.Random.DefaultPrng.init(2146);
    const r = prng.random();
    const us: [3]Ov = .{ .{ .kind = .under, .cond = .{ .sel = &.{1} } }, .{ .kind = .under, .cond = .{ .sel = &.{2} } }, .{ .kind = .under, .cond = .{ .sel = &.{3} } } };
    for (0..random_systems) |_| {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var account: Ids.Account = .{};
        defer account.deinit(testing.allocator);
        const n = r.intRangeAtMost(u32, 2, 8);
        const edges = try arena.alloc([]u32, n);
        const base = try arena.alloc(Ov, n);
        for (edges, base) |*e, *b| {
            e.* = try arena.alloc(u32, r.uintLessThan(u32, 4));
            for (e.*) |*x| x.* = r.uintLessThan(u32, n);
            b.* = switch (r.uintLessThan(u32, 6)) {
                0 => us[r.uintLessThan(u32, 3)],
                1 => .may,
                else => .{},
            };
        }
        // The truth: Kleene's iteration from the bottom.
        const truth = try arena.alloc(Ov, n);
        @memset(truth, .{});
        var moved = true;
        while (moved) {
            moved = false;
            for (truth, edges, base) |*v, e, b| {
                var acc = b;
                for (e) |x| acc = try Ov.join(arena, &account, acc, truth[x]);
                if (!acc.eql(v.*)) {
                    v.* = acc;
                    moved = true;
                }
            }
        }
        const perm = try arena.alloc(u32, n);
        for (perm, 0..) |*x, i| x.* = @intCast(i);
        for (0..4) |_| {
            r.shuffle(u32, perm);
            var q: Queries = .{};
            defer q.deinit(testing.allocator);
            const s: System = .{ .q = &q, .arena = arena, .account = &account, .edges = @ptrCast(edges), .base = base };
            for (perm) |p| try testing.expect((try s.ask(p)).eql(truth[p]));
        }
    }
}

test "a member forgotten under a head's may is walked again, and is its own value" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var account: Ids.Account = .{};
    defer account.deinit(testing.allocator);
    var q: Queries = .{};
    defer q.deinit(testing.allocator);
    const edges: []const []const u32 = &.{ &.{ 1, 2 }, &.{0}, &.{} };
    const s: System = .{ .q = &q, .arena = arena_state.allocator(), .account = &account, .edges = edges, .base = &.{ .no, .no, .may } };
    try testing.expectEqual(.may, (try s.ask(0)).kind);
    try testing.expectEqual(.may, (try s.ask(1)).kind);
}

test "a key that grew drops what was solved" {
    var q: Queries = .{};
    defer q.deinit(testing.allocator);
    try q.begin(testing.allocator, 0);
    try q.solved.put(testing.allocator, .{ 1, 2, 0 }, 0);
    try q.values.append(testing.allocator, .may);
    q.end();
    try q.begin(testing.allocator, 1);
    q.end();
    try testing.expectEqual(@as(?u32, null), q.solved.get(.{ 1, 2, 0 }));
}
