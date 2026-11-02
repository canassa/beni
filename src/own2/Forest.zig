//! L3: readers of result trees (`docs/design/ownership-v2.md` §2.10, *a
//! contract is a tree of shared subtrees*; §3.5): one slot's arrivals, a
//! tree's entries in the canonical order, and each node once.
//!
//! A reader that asks one slot walks its steps from the root. A reader that
//! needs every entry walks the tree in the canonical order of §2.10: a
//! slot's plain run, then its open one, then its kids by their steps'
//! canonical keys (a constructor step by `(ordinal, argument)`, which is
//! the same in every module), which is the order of the slots' keys.
//!
//! Obligations kept here: none of §2.14's directly (readers only).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Trees = @import("Trees.zig");

pub const Node = Trees.Node;
pub const Hit = Trees.Hit;
pub const Arrival = Trees.Arrival;

/// What arrives at the slot `words` of tree `root`, as a reader that asks
/// one slot walks it from the root: each open node on the way (at its
/// depth), then the slot's own node's plain and open arrivals, in the
/// canonical entries' order (an ancestor first, a plain run before an open
/// one). Returns the nodes visited.
pub fn atSlot(t: *const Trees.Table, gpa: Allocator, root: Node, words: []const u32, out: *std.ArrayList(Hit)) Allocator.Error!u32 {
    var n = root;
    var d: usize = 0;
    while (true) : (d += 1) {
        if (d == words.len) {
            if (t.here(n).len != 0) try out.append(gpa, .{ .depth = @intCast(d), .open = false, .arrivals = t.here(n) });
            if (t.open(n).len != 0) try out.append(gpa, .{ .depth = @intCast(d), .open = true, .arrivals = t.open(n) });
            return @intCast(d + 1);
        }
        if (t.open(n).len != 0) try out.append(gpa, .{ .depth = @intCast(d), .open = true, .arrivals = t.open(n) });
        n = t.kidAt(n, words[d]) orelse return @intCast(d + 1);
    }
}

/// The node at slot `words` of tree `root`; null when nothing is at or
/// below it.
pub fn at(t: *const Trees.Table, root: Node, words: []const u32) ?Node {
    var n = root;
    for (words) |w| n = t.kidAt(n, w) orelse return null;
    return if (n == 0) null else n;
}

/// A step word's canonical key (`Slots`' key of a one-step run).
pub fn stepKey(places: *const Place.Table, word: u32) [3]u32 {
    const s = Place.Step.fromWord(word);
    if (s.kind == .ctor_arg) {
        const ca = places.ctorArgOf(s);
        return .{ @backingInt(s.kind), ca[0], ca[1] };
    }
    return .{ @backingInt(s.kind), s.payload, 0 };
}

/// `n`'s kids in the canonical order, into `out`.
pub fn sortedKids(t: *const Trees.Table, gpa: Allocator, places: *const Place.Table, n: Node, out: *std.ArrayList([2]u32)) Allocator.Error!void {
    out.clearRetainingCapacity();
    try out.appendSlice(gpa, t.kids(n));
    std.mem.sort([2]u32, out.items, places, struct {
        fn lt(p: *const Place.Table, a: [2]u32, b: [2]u32) bool {
            return std.mem.order(u32, &stepKey(p, a[0]), &stepKey(p, b[0])) == .lt;
        }
    }.lt);
}

/// One entry of a tree: its slot's words (in `Entries.words`), plain or
/// open, and its arrivals.
pub const Entry = struct { start: u32, len: u32, open: bool, arrivals: []const Arrival };

/// A tree's entries in the canonical order, each slot's words below `prefix`.
pub const Entries = struct {
    words: std.ArrayList(u32) = .empty,
    items: std.ArrayList(Entry) = .empty,
    /// The arrivals, copied: the table may grow while the entries are read.
    arrs: std.ArrayList(Arrival) = .empty,

    pub fn deinit(es: *Entries, gpa: Allocator) void {
        es.words.deinit(gpa);
        es.items.deinit(gpa);
        es.arrs.deinit(gpa);
    }

    pub fn wordsOf(es: *const Entries, e: Entry) []const u32 {
        return es.words.items[e.start..][0..e.len];
    }

    /// Every entry of `root`, its words `prefix` and the steps below it.
    pub fn of(es: *Entries, t: *const Trees.Table, gpa: Allocator, places: *const Place.Table, root: Node, prefix: []const u32) Allocator.Error!void {
        es.words.clearRetainingCapacity();
        es.items.clearRetainingCapacity();
        es.arrs.clearRetainingCapacity();
        var path: std.ArrayList(u32) = .empty;
        defer path.deinit(gpa);
        try path.appendSlice(gpa, prefix);
        try es.walk(t, gpa, places, root, &path);
        var at_: usize = 0;
        for (es.items.items) |*x| {
            x.arrivals = es.arrs.items[at_..][0..x.arrivals.len];
            at_ += x.arrivals.len;
        }
    }

    fn walk(es: *Entries, t: *const Trees.Table, gpa: Allocator, places: *const Place.Table, n: Node, path: *std.ArrayList(u32)) Allocator.Error!void {
        if (n == 0) return;
        for ([_]bool{ false, true }) |o| {
            const run = if (o) t.open(n) else t.here(n);
            if (run.len == 0) continue;
            const start: u32 = @intCast(es.words.items.len);
            try es.words.appendSlice(gpa, path.items);
            try es.arrs.appendSlice(gpa, run);
            try es.items.append(gpa, .{ .start = start, .len = @intCast(path.items.len), .open = o, .arrivals = run });
        }
        var ks: std.ArrayList([2]u32) = .empty;
        defer ks.deinit(gpa);
        try sortedKids(t, gpa, places, n, &ks);
        for (ks.items) |k| {
            try path.append(gpa, k[0]);
            try es.walk(t, gpa, places, k[1], path);
            _ = path.pop();
        }
    }
};

/// Every node of `root` once, in the canonical order of first meeting.
pub fn nodes(t: *const Trees.Table, gpa: Allocator, places: *const Place.Table, root: Node, out: *std.ArrayList(Node)) Ids.IndexError!void {
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    var stack: std.ArrayList(Node) = .empty;
    defer stack.deinit(gpa);
    var ks: std.ArrayList([2]u32) = .empty;
    defer ks.deinit(gpa);
    if (root != 0) try stack.append(gpa, root);
    while (stack.pop()) |n| {
        if ((try seen.getOrPut(gpa, .{n})).found_existing) continue;
        try out.append(gpa, n);
        try sortedKids(t, gpa, places, n, &ks);
        var i = ks.items.len;
        while (i > 0) {
            i -= 1;
            try stack.append(gpa, ks.items[i][1]);
        }
    }
}

/// The arrivals of every node of `root`, each node once.
pub fn arrivalsOf(t: *const Trees.Table, gpa: Allocator, places: *const Place.Table, root: Node, out: *std.ArrayList(Arrival)) Ids.IndexError!void {
    var ns: std.ArrayList(Node) = .empty;
    defer ns.deinit(gpa);
    try nodes(t, gpa, places, root, &ns);
    for (ns.items) |n| {
        try out.appendSlice(gpa, t.here(n));
        try out.appendSlice(gpa, t.open(n));
    }
}

/// The canonical order of arrivals (§2.10 *Determinism*), the caller's.
pub const Less = struct {
    ctx: *const anyopaque,
    lt: *const fn (ctx: *const anyopaque, a: Arrival, b: Arrival) bool,
};

/// `plain`: a node's runs are each side's, merged. `join`: a contract
/// joined into another keeps the other's entries' shape (§2.10 *Lattice*):
/// where it brings open arrivals, every arrival at the slot is open; its
/// plain ones go to the plain run there, else to an open one.
pub const Mode = enum(u8) { plain, join };

/// `n` below the steps `words`.
pub fn graft(t: *Trees.Table, gpa: Allocator, words: []const u32, n: Node) Ids.IndexError!Node {
    var m = n;
    var i = words.len;
    while (i > 0 and m != 0) {
        i -= 1;
        var k = [_][2]u32{.{ words[i], m }};
        m = try t.node(gpa, &.{}, &.{}, &k);
    }
    return m;
}

/// `a ∪ b` by `mode`, each pair of nodes once (`memo`, the caller's).
pub fn unite(t: *Trees.Table, gpa: Allocator, memo: *Ids.FixedDict(2), a: Node, b: Node, less: Less, mode: Mode) Ids.IndexError!Node {
    if (b == 0 or (a == b and mode == .plain)) return a;
    if (a == 0 and mode == .plain) return b;
    if (memo.get(.{ a, b })) |n| return n;
    var hr: std.ArrayList(Arrival) = .empty;
    defer hr.deinit(gpa);
    var op: std.ArrayList(Arrival) = .empty;
    defer op.deinit(gpa);
    if (mode == .plain or t.open(b).len != 0) {
        try merge(gpa, &hr, t.here(a), t.here(b), less);
        try merge(gpa, &op, t.open(a), t.open(b), less);
        if (mode == .join) {
            const all = try gpa.dupe(Arrival, op.items);
            defer gpa.free(all);
            op.clearRetainingCapacity();
            try merge(gpa, &op, all, hr.items, less);
            hr.clearRetainingCapacity();
        }
    } else if (t.here(a).len != 0 or t.open(a).len == 0) {
        try merge(gpa, &hr, t.here(a), t.here(b), less);
        try op.appendSlice(gpa, t.open(a));
    } else try merge(gpa, &op, t.open(a), t.here(b), less);
    var ks: std.ArrayList([2]u32) = .empty;
    defer ks.deinit(gpa);
    const ka = t.kids(a);
    const kb = t.kids(b);
    var i: usize = 0;
    var j: usize = 0;
    while (i < ka.len or j < kb.len) {
        if (j >= kb.len or (i < ka.len and ka[i][0] < kb[j][0])) {
            try ks.append(gpa, ka[i]);
            i += 1;
        } else {
            const x = if (i < ka.len and ka[i][0] == kb[j][0]) ka[i][1] else 0;
            if (x != 0) i += 1;
            try ks.append(gpa, .{ kb[j][0], try unite(t, gpa, memo, x, kb[j][1], less, mode) });
            j += 1;
        }
    }
    const n = try t.node(gpa, hr.items, op.items, ks.items);
    try memo.put(gpa, .{ a, b }, n);
    return n;
}

/// `n` with each `cb` arrival's label renumbered by `map`, re-sorted.
pub fn mapLabels(t: *Trees.Table, gpa: Allocator, memo: *Ids.FixedDict(2), n: Node, map: []const u32, less: Less) Ids.IndexError!Node {
    if (n == 0) return 0;
    if (memo.get(.{ n, 0 })) |m| return m;
    var runs: [2]std.ArrayList(Arrival) = .{ .empty, .empty };
    defer for (&runs) |*r| r.deinit(gpa);
    for (&runs, [_][]const Arrival{ t.here(n), t.open(n) }) |*r, src| {
        for (src) |a0| {
            var a = a0;
            if (a.kind == .cb) a.j = map[a.j];
            try r.append(gpa, a);
        }
        std.mem.sort(Arrival, r.items, less, struct {
            fn lt(l: Less, x: Arrival, y: Arrival) bool {
                return l.lt(l.ctx, x, y);
            }
        }.lt);
    }
    var ks: std.ArrayList([2]u32) = .empty;
    defer ks.deinit(gpa);
    for (t.kids(n)) |k| try ks.append(gpa, .{ k[0], try mapLabels(t, gpa, memo, k[1], map, less) });
    const m = try t.node(gpa, runs[0].items, runs[1].items, ks.items);
    try memo.put(gpa, .{ n, 0 }, m);
    return m;
}

/// `xs ∪ ys` (each sorted by `less`) into `out`, each arrival once.
fn merge(gpa: Allocator, out: *std.ArrayList(Arrival), xs: []const Arrival, ys: []const Arrival, less: Less) Allocator.Error!void {
    var i: usize = 0;
    var j: usize = 0;
    while (i < xs.len or j < ys.len) {
        if (j >= ys.len or (i < xs.len and less.lt(less.ctx, xs[i], ys[j]))) {
            try out.append(gpa, xs[i]);
            i += 1;
        } else if (i >= xs.len or less.lt(less.ctx, ys[j], xs[i])) {
            try out.append(gpa, ys[j]);
            j += 1;
        } else {
            try out.append(gpa, xs[i]);
            if (!xs[i].eql(ys[j])) try out.append(gpa, ys[j]);
            i += 1;
            j += 1;
        }
    }
}

/// A tree's text (§2.10 *Text*): `entry` for each entry in the canonical
/// order, a kid equal to an earlier sibling as `.1 = .0`, each
/// with its slot's words.
pub fn text(t: *const Trees.Table, places: *const Place.Table, root: Node, ctx: *anyopaque, entry: EntryText) std.Io.Writer.Error!void {
    var path: std.ArrayList(u32) = .empty;
    defer path.deinit(std.heap.smp_allocator);
    textAt(t, places, root, ctx, entry, &path) catch return error.WriteFailed;
}

/// An entry's text: its slot's words, open or not, and its arrivals; or
/// the words of the earlier sibling it equals (`as`).
pub const EntryText = *const fn (ctx: *anyopaque, path: []const u32, open: bool, run: []const Arrival, as: ?[]const u32) std.Io.Writer.Error!void;

fn textAt(t: *const Trees.Table, places: *const Place.Table, n: Node, ctx: *anyopaque, entry: EntryText, path: *std.ArrayList(u32)) (std.Io.Writer.Error || Allocator.Error)!void {
    const gpa = std.heap.smp_allocator;
    if (t.here(n).len != 0) try entry(ctx, path.items, false, t.here(n), null);
    if (t.open(n).len != 0) try entry(ctx, path.items, true, t.open(n), null);
    var ks: std.ArrayList([2]u32) = .empty;
    defer ks.deinit(gpa);
    try sortedKids(t, gpa, places, n, &ks);
    for (ks.items, 0..) |k, i| {
        const top = path.items.len;
        defer path.shrinkRetainingCapacity(top);
        const twin: ?u32 = for (ks.items[0..i]) |o| {
            if (o[1] == k[1]) break o[0];
        } else null;
        if (twin) |o| {
            // `path` then holds the earlier sibling's words, then this kid's.
            try path.ensureUnusedCapacity(gpa, top + 2);
            path.appendAssumeCapacity(o);
            path.appendSliceAssumeCapacity(path.items[0..top]);
            path.appendAssumeCapacity(k[0]);
            try entry(ctx, path.items[top + 1 ..], false, &.{}, path.items[0 .. top + 1]);
        } else {
            try path.append(gpa, k[0]);
            try textAt(t, places, k[1], ctx, entry, path);
        }
    }
}

// ---- effects as trees (§2.10, *Effects as trees*) ------------------------

/// The mark of an effect tree: a plain run is a shallow effect at its slot,
/// an open run a deep one at its slot and every slot below it.
pub const mark: Arrival = .{ .kind = .top };

/// `n` with each deep effect covering what is below it: its kids and its
/// shallow effect dropped (a fold names the same slots).
pub fn foldDeep(t: *Trees.Table, gpa: Allocator, memo: *Ids.FixedDict(2), n: Node) Ids.IndexError!Node {
    if (n == 0) return 0;
    if (t.open(n).len != 0) return t.node(gpa, &.{}, &.{mark}, &.{});
    if (memo.get(.{ n, 1 })) |m| return m;
    var ks: std.ArrayList([2]u32) = .empty;
    defer ks.deinit(gpa);
    for (t.kids(n)) |k| try ks.append(gpa, .{ k[0], try foldDeep(t, gpa, memo, k[1]) });
    const m = try t.node(gpa, t.here(n), &.{}, ks.items);
    try memo.put(gpa, .{ n, 1 }, m);
    return m;
}

/// Every effect of tree `g` is one of `c`'s at its slot (a shallow one by
/// either, a deep one by a deep one) or below a deep one of `c`'s.
pub fn effectsWithin(t: *const Trees.Table, gpa: Allocator, memo: *Ids.FixedDict(2), g: Node, c: Node) Ids.IndexError!bool {
    if (g == 0 or t.open(c).len != 0) return true;
    if (memo.get(.{ g, c })) |x| return x == 1;
    var ok = (t.here(g).len == 0 or t.here(c).len != 0) and t.open(g).len == 0;
    if (ok) for (t.kids(g)) |k| {
        if (!try effectsWithin(t, gpa, memo, k[1], t.kidAt(c, k[0]) orelse 0)) {
            ok = false;
            break;
        }
    };
    try memo.put(gpa, .{ g, c }, @intFromBool(ok));
    return ok;
}

/// Whether effect tree `n` reaches the slot `words` below its root: an
/// effect at it or below it, or a deep one above it.
pub fn effectReaches(t: *const Trees.Table, n0: Node, words: []const u32) bool {
    var n = n0;
    for (words) |w| {
        if (t.open(n).len != 0) return true;
        n = t.kidAt(n, w) orelse return false;
    }
    return t.count(n) != 0;
}

const testing = std.testing;

test "a slot reader walks only its steps, and the entries come in order" {
    const gpa = testing.allocator;
    var t: Trees.Table = .{};
    defer t.deinit(gpa);
    var places: Place.Table = .{};
    defer places.deinit(gpa);
    const p: Arrival = .{ .kind = .param, .j = 0, .slot = 7, .deep = true };
    const leaf = try t.node(gpa, &.{}, &.{p}, &.{});
    const w1 = (Place.Step{ .kind = .index, .payload = 0 }).word();
    const w2 = (Place.Step{ .kind = .index, .payload = 1 }).word();
    var k1 = [_][2]u32{ .{ w2, leaf }, .{ w1, leaf } };
    const pair = try t.node(gpa, &.{}, &.{}, &k1);
    var k2 = [_][2]u32{ .{ w1, pair }, .{ w2, pair } };
    const top = try t.node(gpa, &.{.{ .kind = .fresh }}, &.{}, &k2);
    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(gpa);
    try testing.expectEqual(@as(u32, 3), try atSlot(&t, gpa, top, &.{ w2, w1 }, &hits));
    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expect(hits.items[0].open and hits.items[0].depth == 2 and hits.items[0].arrivals[0].eql(p));
    try testing.expect(at(&t, top, &.{ w1, 99 }) == null);
    var es: Entries = .{};
    defer es.deinit(gpa);
    try es.of(&t, gpa, &places, top, &.{});
    try testing.expectEqual(@as(usize, 5), es.items.items.len);
    try testing.expectEqualSlices(u32, &.{ w1, w2 }, es.wordsOf(es.items.items[2]));
    var ns: std.ArrayList(Node) = .empty;
    defer ns.deinit(gpa);
    try nodes(&t, gpa, &places, top, &ns);
    try testing.expectEqual(@as(usize, 3), ns.items.len);
}

test "a union is pointwise and keeps every slot of both sides" {
    const gpa = testing.allocator;
    var t: Trees.Table = .{};
    defer t.deinit(gpa);
    const p: Arrival = .{ .kind = .param, .j = 0, .slot = 7, .deep = true };
    const leaf = try t.node(gpa, &.{}, &.{p}, &.{});
    var k1 = [_][2]u32{ .{ 1, leaf }, .{ 2, leaf } };
    const pair = try t.node(gpa, &.{}, &.{}, &k1);
    const fresh = try t.node(gpa, &.{.{ .kind = .fresh }}, &.{}, &.{});
    var memo: Ids.FixedDict(2) = .{};
    defer memo.deinit(gpa);
    const less: Less = .{ .ctx = &t, .lt = struct {
        fn lt(_: *const anyopaque, a: Arrival, b: Arrival) bool {
            return @backingInt(a.kind) < @backingInt(b.kind);
        }
    }.lt };
    const u = try unite(&t, gpa, &memo, try graft(&t, gpa, &.{ 1, 2 }, fresh), pair, less, .plain);
    try testing.expectEqual(@as(u32, 3), t.count(u));
    try testing.expectEqual(leaf, t.kidAt(u, 2).?);
    try testing.expectEqual(@as(usize, 1), t.here(t.kidAt(t.kidAt(u, 1).?, 2).?).len);
}
