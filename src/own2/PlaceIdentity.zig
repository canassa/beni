//! L2: the structural identity of a place graph (`docs/design/ownership-v2.md`
//! §2.1, *Identity*, §3.1), split from `Place` (#1714). `encode` writes a
//! sub-graph as `(kind, head, children)` records with ordinals for
//! backreferences, so a cycle is one record, and maps every name and head
//! through the caller's `Names`, so a block holds no interned address;
//! `decode` reads one back into a table of its own; `equals` is the
//! graph-pair walk two tables are compared by, one record reserved per pair
//! before it is read.
//!
//! Obligations kept here: none of §2.14's (an identity).

const std = @import("std");
const RowSets = @import("RowSets.zig");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const stamped = @import("../stamped.zig");

const Table = Place.Table;
const PlaceId = Place.PlaceId;
const Account = Place.Account;
const Charge = Place.Charge;
const Kind = Place.Kind;
const Step = Place.Step;
const Names = Place.Names;
const Remap = Place.Remap;

/// Write the sub-graph under `root` as records in pre-order ordinals:
/// `[count] { kind, head, holds, n, (step, child ordinal)×n }`, with a
/// field step's name and a nominal head written through `names` (the
/// block's string table), so no session id reaches the bytes. A place
/// is written once; a child seen before is its ordinal (a cycle too).
pub fn encode(t: *const Table, gpa: Allocator, root: PlaceId, names: Names, out: *std.ArrayList(u32)) Allocator.Error!void {
    var ordinal: stamped.Column(PlaceId, u32) = .{};
    defer ordinal.deinit(gpa);
    var order: std.ArrayList(PlaceId) = .empty;
    defer order.deinit(gpa);
    var stack: std.ArrayList(PlaceId) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, root);
    while (stack.pop()) |p| {
        if (ordinal.contains(p)) continue;
        try ordinal.put(gpa, p, @intCast(order.items.len));
        try order.append(gpa, p);
        const r = t.stepRange(p);
        // Pushed in reverse so the first child gets the next ordinal.
        var i = r.len;
        while (i > 0) : (i -= 1) try stack.append(gpa, t.step_tab.col.child[r.start + i - 1]);
    }
    try out.append(gpa, @intCast(order.items.len));
    for (order.items) |p| {
        const r = t.stepRange(p);
        const k = t.kind(p);
        const h = if (k == .tuple or k == .record) t.head(p) else names.head(names.ctx, t.head(p));
        try out.appendSlice(gpa, &.{ @backingInt(k), h, t.holds(p).bits(), r.len });
        for (t.step_tab.col.step[r.start..][0..r.len], t.step_tab.col.child[r.start..][0..r.len]) |s, c| {
            // A field's rank and a `C#i`'s intern index are this table's: the
            // word carries the kind alone and the name or pair follows, so
            // two tables write one type identically.
            const w = if (s.kind == .field or s.kind == .ctor_arg or s.kind == .row) (Step{ .kind = s.kind, .payload = 0 }).word() else s.word();
            try out.appendSlice(gpa, &.{ w, ordinal.get(c).? });
            // A field's name follows its step, through the string table.
            if (s.kind == .field) try out.append(gpa, names.field(names.ctx, s.payload));
            // A `C#i` payload is this table's intern index: the pair follows.
            if (s.kind == .ctor_arg) try out.appendSlice(gpa, &t.ctorArgOf(s));
            if (s.kind == .row) try RowSets.write(gpa, out, t.rowNames(s), names.ctx, names.field);
        }
    }
}

/// Read a graph `encode` wrote into a table of its own, mapping heads
/// and field names back through `remap`; the root is place 0. Null when
/// the words are not a graph (R-5.7.4: an undecodable block is no
/// block), including a child order that is not canonical after the
/// remap.
pub fn decode(gpa: Allocator, account: *Account, words: []const u32, remap: Remap) Place.Error!?Table {
    var t: Table = .{};
    decodeInto(&t, gpa, account, words, remap) catch |err| switch (err) {
        error.Malformed => {
            t.deinit(gpa);
            return null;
        },
        else => |e| {
            t.deinit(gpa);
            return e;
        },
    };
    return t;
}

fn decodeInto(t: *Table, gpa: Allocator, account: *Account, words: []const u32, remap: Remap) (Place.Error || error{Malformed})!void {
    if (words.len == 0) return error.Malformed;
    const n = words[0];
    var at: usize = 1;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (at + 4 > words.len) return error.Malformed;
        const k = words[at];
        if (k > @backingInt(Kind.cross)) return error.Malformed;
        const kd: Kind = @fromBackingInt(@intCast(k));
        const h = if (kd == .tuple or kd == .record) words[at + 1] else remap.head(remap.ctx, words[at + 1]);
        const hb = words[at + 2];
        const len = words[at + 3];
        at += 4;
        if (hb > 0x7f) return error.Malformed;
        try account.limitOver(.type_places, @as(u64, t.count()) + 1, t.limits.type_places);
        if (kd.childLimit()) |l| try account.limitOver(l, len, t.limits.children);
        const start: u32 = @intCast(t.step_tab.len());
        var j: u32 = 0;
        var last: u64 = 0;
        while (j < len) : (j += 1) {
            if (at + 2 > words.len) return error.Malformed;
            var s = Step.fromWord(words[at]);
            const c = words[at + 1];
            at += 2;
            if (c >= n) return error.Malformed;
            if (s.kind == .field) {
                if (at + 1 > words.len) return error.Malformed;
                s = try Step.field(account, remap.field(remap.ctx, words[at]));
                at += 1;
            }
            if (s.kind == .ctor_arg) {
                if (at + 2 > words.len) return error.Malformed;
                s = try t.ctorStep(gpa, account, words[at], words[at + 1]);
                at += 2;
            }
            if (s.kind == .row) {
                if (at + 1 > words.len or words[at] > words.len - at - 1) return error.Malformed;
                const ranks = try RowSets.mapped(gpa, words[at + 1 ..][0..words[at]], remap.ctx, remap.field);
                defer gpa.free(ranks);
                at += words[at] + 1;
                s = try t.rowStep(gpa, account, ranks);
            }
            if (j > 0 and !t.stepLess(Step.fromWord(@intCast(last)), s)) return error.Malformed;
            last = s.word();
            try t.step_tab.append(gpa, .{ .step = s, .child = .from(c) });
        }
        try t.places.append(gpa, .{ .kind = kd, .head = h, .steps = .{ .start = start, .len = len }, .holds = @bitCast(@as(u8, @intCast(hb))), .class = .none, .scc = 0 });
    }
    if (at != words.len) return error.Malformed;
    // Settled as a build is: at 0, any two places would be one cycle.
    try t.settleCycles(gpa, 0);
}

/// Structural equality of `a` in `ta` and `b` in `tb`: a graph-pair
/// walk, every pair visited once, O(pairs) — the charged comparison of
/// §2.1's *Identity*: one record reserved per pair before it is read.
/// A pair in `proven`, which an earlier walk over the same two tables
/// proved, is not walked again; on `true` every pair visited joins it
/// (#1566: nested places compared one by one cost their pairs once).
pub fn equals(ta: *const Table, a: PlaceId, tb: *const Table, b: PlaceId, gpa: Allocator, charge: Charge, proven: ?*Ids.FixedDict(2)) Place.Error!bool {
    var seen: Ids.FixedDict(2) = .{};
    defer seen.deinit(gpa);
    var stack: std.ArrayList([2]PlaceId) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, .{ a, b });
    const same = while (stack.pop()) |pair| {
        try charge.reserve(gpa, .inspection, 1);
        const key: [2]u32 = .{ pair[0].int(), pair[1].int() };
        if (proven) |pv| if (pv.get(key) != null) continue;
        const got = try seen.getOrPut(gpa, key);
        if (got.found_existing) continue;
        got.value_ptr.* = 1;
        const x = pair[0];
        const y = pair[1];
        if (ta.kind(x) != tb.kind(y) or ta.head(x) != tb.head(y)) break false;
        const rx = ta.stepRange(x);
        const ry = tb.stepRange(y);
        if (rx.len != ry.len) break false;
        var i: u32 = 0;
        const steps_same = while (i < rx.len) : (i += 1) {
            const sx = ta.step_tab.col.step[rx.start + i];
            const sy = tb.step_tab.col.step[ry.start + i];
            if (sx.kind != sy.kind) break false;
            if (sx.kind == .ctor_arg) {
                if (!std.mem.eql(u32, &ta.ctorArgOf(sx), &tb.ctorArgOf(sy))) break false;
            } else if (sx.kind == .row) {
                if (!std.mem.eql(u32, ta.rowNames(sx), tb.rowNames(sy))) break false;
            } else if (!sx.eql(sy)) break false;
            try stack.append(gpa, .{ ta.step_tab.col.child[rx.start + i], tb.step_tab.col.child[ry.start + i] });
        } else true;
        if (!steps_same) break false;
    } else true;
    if (same) if (proven) |pv| {
        var k: usize = 0;
        while (k < seen.keys.items.len) : (k += 2) (try pv.getOrPut(gpa, seen.keys.items[k..][0..2].*)).value_ptr.* = 1;
    };
    return same;
}

const testing = std.testing;
const StepKind = Place.StepKind;
const Child = Place.Child;
const Description = Place.Description;
const Source = Place.Source;
const PathId = Place.PathId;

/// A test type graph: node `v` is `nodes[v]`.
const TestGraph = struct {
    nodes: []const TestNode,
    table: *Table,
    account: *Account,
    gpa: Allocator,

    const TestNode = struct { kind: Kind, head: u32 = 0, children: []const TestChild = &.{} };
    const TestChild = struct { kind: StepKind, payload: u32 = 0, @"var": u32, arg: u32 = 0 };

    fn describe(ctx: *anyopaque, v: u32, out: *std.ArrayList(Child)) Allocator.Error!Description {
        const g: *TestGraph = @ptrCast(@alignCast(ctx));
        const n = g.nodes[v];
        for (n.children) |c| {
            const step: Step = switch (c.kind) {
                .field => Step.field(g.account, c.payload) catch unreachable,
                .index => Step.index(g.account, c.payload) catch unreachable,
                .ctor_arg => g.table.ctorStep(g.gpa, g.account, c.payload, c.arg) catch unreachable,
                .elem => Step.elem,
                .contents => Step.contents,
                .env => Step.env,
                .slot => Step.slot(g.account, c.payload) catch unreachable,
                .level, .row => unreachable,
            };
            try out.append(g.gpa, .{ .step = step, .@"var" = c.@"var" });
        }
        return .{ .kind = n.kind, .head = n.head };
    }

    fn source(g: *TestGraph) Source {
        return .{ .ctx = g, .describe = describe };
    }
};

const Fixture = struct {
    table: Table = .{},
    account: Account = .{},
    graph: TestGraph = undefined,

    fn init(f: *Fixture, nodes: []const TestGraph.TestNode) void {
        f.graph = .{ .nodes = nodes, .table = &f.table, .account = &f.account, .gpa = testing.allocator };
    }

    fn deinit(f: *Fixture) void {
        f.table.deinit(testing.allocator);
        f.account.deinit(testing.allocator);
    }

    fn of(f: *Fixture, v: u32) !PlaceId {
        return f.table.of(testing.allocator, &f.account, f.graph.source(), v);
    }

    fn ctor(f: *Fixture, c: u32, i: u32) !Step {
        return f.table.ctorStep(testing.allocator, &f.account, c, i);
    }
};

// `Maybe (Maybe (List Int))` and `Int × Int`: 0 outer Maybe, 1 inner Maybe,
// 2 List Int, 3 Int, 4 the tuple, 5 `type T = A T | B`.
const inst_nodes = [_]TestGraph.TestNode{
    .{ .kind = .ctor, .head = 300, .children = &.{.{ .kind = .ctor_arg, .payload = 1, .arg = 0, .@"var" = 1 }} },
    .{ .kind = .ctor, .head = 300, .children = &.{.{ .kind = .ctor_arg, .payload = 1, .arg = 0, .@"var" = 2 }} },
    .{ .kind = .list, .head = 200, .children = &.{.{ .kind = .elem, .@"var" = 3 }} },
    .{ .kind = .cross },
    .{ .kind = .tuple, .head = 2, .children = &.{ .{ .kind = .index, .payload = 0, .@"var" = 3 }, .{ .kind = .index, .payload = 1, .@"var" = 3 } } },
    .{ .kind = .ctor, .head = 400, .children = &.{.{ .kind = .ctor_arg, .payload = 2, .arg = 0, .@"var" = 5 }} },
};

/// A remap for the encode/decode test: heads and field names shifted by a
/// constant on the way out and back, as a string table would renumber them.
const Shift = struct {
    fn out(_: *anyopaque, x: u32) u32 {
        return x + 1000;
    }
    fn back(_: *anyopaque, x: u32) u32 {
        return x - 1000;
    }
    const names: Names = .{ .ctx = undefined, .head = out, .field = out };
    const remap: Remap = .{ .ctx = undefined, .head = back, .field = back };
};

// A record `{ a : List Int, b : Tree }` by field ranks 10 and 11: 0 record,
// 1 list, 2 Int, 3 Tree.
const record_nodes = [_]TestGraph.TestNode{
    .{ .kind = .record, .children = &.{ .{ .kind = .field, .payload = 10, .@"var" = 1 }, .{ .kind = .field, .payload = 11, .@"var" = 3 } } },
    .{ .kind = .list, .head = 200, .children = &.{.{ .kind = .elem, .@"var" = 2 }} },
    .{ .kind = .cross },
    .{ .kind = .ctor, .head = 100, .children = &.{
        .{ .kind = .ctor_arg, .payload = 0, .arg = 0, .@"var" = 3 },
        .{ .kind = .ctor_arg, .payload = 0, .arg = 1, .@"var" = 1 },
        .{ .kind = .ctor_arg, .payload = 0, .arg = 2, .@"var" = 3 },
    } },
};

test "encode writes a cycle once through the names table, and decode reads an equal graph" {
    var f: Fixture = .{};
    f.init(&record_nodes);
    defer f.deinit();
    const gpa = testing.allocator;
    const rec = try f.of(0);
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(gpa);
    try encode(&f.table, gpa, rec, Shift.names, &words);
    // 4 places; a field step carries its name; heads are shifted.
    try testing.expectEqual(@as(u32, 4), words.items[0]);
    try testing.expectEqual(@as(usize, 1 + (4 + 2 * 3) + (4 + 2) + 4 + (4 + 3 * 4)), words.items.len);
    try testing.expectEqual(@as(u32, 1010), words.items[1 + 4 + 2]);
    // The nominal head of `Tree` went through the table; the record's did not.
    try testing.expectEqual(@as(u32, 0), words.items[2]);
    var decoded = (try decode(gpa, &f.account, words.items, Shift.remap)).?;
    defer decoded.deinit(gpa);
    try testing.expectEqual(@as(u32, 100), decoded.head(.from(3)));
    // Its cycles are settled: the record is on none, `Tree` on its own.
    try testing.expect(!decoded.cyclic(.from(0)));
    var on: u32 = 0;
    for (0..decoded.count()) |i| on += @intFromBool(decoded.cyclic(.from(@intCast(i))));
    var on_built: u32 = 0;
    for (0..f.table.count()) |i| on_built += @intFromBool(f.table.cyclic(.from(@intCast(i))));
    try testing.expectEqual(on_built, on);
    try testing.expect(try equals(&f.table, rec, &decoded, .from(0), gpa, .growth(&f.account), null));
    // A different graph at the same place count is not equal, and the
    // comparison was charged per pair.
    var g: Fixture = .{};
    g.init(&inst_nodes);
    defer g.deinit();
    const outer = try g.of(0);
    const before = f.account.growth;
    try testing.expect(!try equals(&f.table, rec, &g.table, outer, gpa, .growth(&f.account), null));
    try testing.expect(f.account.growth > before);
    // Truncated or malformed words are no graph; neither is one whose
    // children come out of order after the remap.
    try testing.expect((try decode(gpa, &f.account, words.items[0 .. words.items.len - 1], Shift.remap)) == null);
    try testing.expect((try decode(gpa, &f.account, &.{}, Shift.remap)) == null);
    const Swap = struct {
        fn back(_: *anyopaque, x: u32) u32 {
            return if (x == 1010) 11 else if (x == 1011) 10 else x - 1000;
        }
        const remap: Remap = .{ .ctx = undefined, .head = Shift.back, .field = back };
    };
    try testing.expect((try decode(gpa, &f.account, words.items, Swap.remap)) == null);
}

/// One place of every kind, each nominal one with a distinctive head:
/// 0 record { a : 1, b : 2 }, 1 list, 2 dict, 3 ref, 4 closure, 5 opaque,
/// 6 var, 7 tuple (var, Int), 8 `type T = A T | B` (crosses), 9 Int.
const every_kind = [_]TestGraph.TestNode{
    .{ .kind = .record, .children = &.{ .{ .kind = .field, .payload = 10, .@"var" = 1 }, .{ .kind = .field, .payload = 11, .@"var" = 2 } } },
    .{ .kind = .list, .head = 777, .children = &.{.{ .kind = .elem, .@"var" = 3 }} },
    .{ .kind = .dict, .head = 778, .children = &.{.{ .kind = .elem, .@"var" = 4 }} },
    .{ .kind = .ref, .head = 779, .children = &.{.{ .kind = .contents, .@"var" = 5 }} },
    .{ .kind = .closure, .head = 780, .children = &.{.{ .kind = .env, .@"var" = 6 }} },
    .{ .kind = .@"opaque", .head = 781, .children = &.{.{ .kind = .slot, .payload = 0, .@"var" = 7 }} },
    .{ .kind = .@"var" },
    .{ .kind = .tuple, .head = 2, .children = &.{ .{ .kind = .index, .payload = 0, .@"var" = 6 }, .{ .kind = .index, .payload = 1, .@"var" = 8 } } },
    .{ .kind = .ctor, .head = 782, .children = &.{ .{ .kind = .ctor_arg, .payload = 0, .arg = 0, .@"var" = 8 }, .{ .kind = .ctor_arg, .payload = 1, .arg = 0, .@"var" = 9 } } },
    .{ .kind = .cross },
};

test "no session id reaches the bytes for any place kind, a reclassified leaf included" {
    var f: Fixture = .{};
    f.init(&every_kind);
    defer f.deinit();
    const gpa = testing.allocator;
    const rec = try f.of(0);
    // `type T = A T | B` holds nothing: a leaf, and no longer a `T`.
    const t = try f.of(8);
    try testing.expectEqual(Kind.cross, f.table.kind(t));
    try testing.expectEqual(@as(u32, 0), f.table.head(t));
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(gpa);
    try encode(&f.table, gpa, rec, Shift.names, &words);
    for (words.items) |w| {
        for ([_]u32{ 777, 778, 779, 780, 781, 782 }) |head| try testing.expect(w != head);
    }
    var decoded = (try decode(gpa, &f.account, words.items, Shift.remap)).?;
    defer decoded.deinit(gpa);
    try testing.expect(try equals(&f.table, rec, &decoded, .from(0), gpa, .growth(&f.account), null));
    // Every head came back as it was, the leaf's as 0.
    var i: u32 = 0;
    var seen_heads: u32 = 0;
    while (i < decoded.count()) : (i += 1) {
        const h = decoded.head(.from(i));
        if (h >= 777 and h <= 782) seen_heads += 1;
    }
    try testing.expectEqual(@as(u32, 5), seen_heads);
}

test "two tables that intern one type in different orders write identical bytes" {
    const gpa = testing.allocator;
    var f: Fixture = .{};
    f.init(&record_nodes);
    defer f.deinit();
    var g: Fixture = .{};
    g.init(&record_nodes);
    defer g.deinit();
    // `g` interns the Tree's constructor steps in another order first.
    _ = try g.ctor(0, 2);
    _ = try g.ctor(0, 1);
    _ = try g.ctor(0, 0);
    const rf = try f.of(0);
    const rg = try g.of(0);
    var wf: std.ArrayList(u32) = .empty;
    defer wf.deinit(gpa);
    var wg: std.ArrayList(u32) = .empty;
    defer wg.deinit(gpa);
    try encode(&f.table, gpa, rf, Names.identity, &wf);
    try encode(&g.table, gpa, rg, Names.identity, &wg);
    try testing.expectEqualSlices(u32, wf.items, wg.items);
    // And both decode to a graph equal to either.
    var decoded = (try decode(gpa, &f.account, wg.items, Names.identity)).?;
    defer decoded.deinit(gpa);
    try testing.expect(try equals(&f.table, rf, &decoded, .from(0), gpa, .growth(&f.account), null));
    try testing.expect(try equals(&g.table, rg, &decoded, .from(0), gpa, .growth(&g.account), null));
}
