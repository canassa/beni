//! L2: result trees (`docs/design/ownership-v2.md` §2.10, *a contract is a
//! tree of shared subtrees*; §3.5): a contract's `res` and a supply's `res`
//! as nodes over the result's relative steps, hash-consed by content in the
//! module's contract table, so equal subtrees are one node.
//!
//! A node is its plain arrivals (at its own slot), its open arrivals (at its
//! slot and, by structure, every slot below it) and its kids, `(step word,
//! node)` pairs sorted by the step word (a module-local order: equal content
//! has equal words; a reader that writes words out sorts the kids by their
//! canonical keys, §2.10 *Determinism*). An arrival names a parameter's slot
//! from the parameter's root, which does not depend on where the node sits,
//! so sharing is exact. Node 0 is the empty node. Each node keeps the number
//! of entries (a slot's plain or open run) at and below it, which a reader
//! that used to scan the entries is charged.
//!
//! Obligations kept here: none of §2.14's directly (tables only).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Runs = @import("Runs.zig").Runs;

pub const Range = Ids.Range;

pub const ArrivalKind = enum(u8) { param, fresh, shared, cb, top };

/// One arrival (§2.10 `res`): `π_j·slot`, `fresh`, `shared (module, decl)`
/// (`j`, `slot`), `cb label` (`j`: the label's index in its contract), `⊤`.
pub const Arrival = struct {
    kind: ArrivalKind,
    /// `param`: the parameter's slot is a type variable's, so the arrival is
    /// every object at and below it at the caller.
    deep: bool = false,
    j: u32 = 0,
    slot: u32 = 0,
    /// `param`: the module's path `slot` names from the parameter's root, when
    /// the read-off knew it (never in a block): a caller handing that
    /// parameter whole reads the path, not the steps (§2.11.2, #1714).
    path: u32 = Ids.none_int,

    pub fn eql(a: Arrival, b: Arrival) bool {
        return a.kind == b.kind and a.deep == b.deep and a.j == b.j and a.slot == b.slot and a.path == b.path;
    }
};

/// A node of `Table.nodes`; 0 is the empty node.
pub const Node = u32;

/// One entry a slot reader meets (`Forest.atSlot`): `depth` steps from the
/// root, open or plain.
pub const Hit = struct { depth: u32, open: bool, arrivals: []const Arrival };

pub const Table = struct {
    /// A node's words: its plain arrivals' run and its open arrivals' run
    /// (ids of `arr_runs`), then its kids as `(step word, node)` pairs.
    nodes: Runs = .{},
    /// Per node: its entries at and below it (saturating).
    counts: std.ArrayList(u32) = .empty,
    /// Arrival runs by content (four words an arrival), each with its
    /// range of `arrivals`; run 0 is the empty run.
    arr_runs: Runs = .{},
    arr_range: std.ArrayList(Range) = .empty,
    arrivals: std.ArrayList(Arrival) = .empty,

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.nodes.deinit(gpa);
        t.counts.deinit(gpa);
        t.arr_runs.deinit(gpa);
        t.arr_range.deinit(gpa);
        t.arrivals.deinit(gpa);
    }

    /// The node of these arrivals and kids (sorted here), by content.
    pub fn node(t: *Table, gpa: Allocator, plain: []const Arrival, wide: []const Arrival, ks: [][2]u32) Ids.IndexError!Node {
        const h = try t.arrRun(gpa, plain);
        const o = try t.arrRun(gpa, wide);
        if (h == 0 and o == 0 and ks.len == 0) return 0;
        std.mem.sort([2]u32, ks, {}, struct {
            fn lt(_: void, a: [2]u32, b: [2]u32) bool {
                return a[0] < b[0];
            }
        }.lt);
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(gpa);
        try words.appendSlice(gpa, &.{ h, o });
        for (ks) |k| try words.appendSlice(gpa, &k);
        const id = try t.nodes.intern(gpa, words.items);
        if (t.counts.items.len == 0) try t.counts.append(gpa, 0);
        if (id == t.counts.items.len) {
            var n: u64 = @intFromBool(h != 0) + @as(u64, @intFromBool(o != 0));
            for (ks) |k| n += t.counts.items[k[1]];
            try t.counts.append(gpa, @intCast(@min(n, std.math.maxInt(u32))));
        }
        return id;
    }

    fn arrRun(t: *Table, gpa: Allocator, run: []const Arrival) Ids.IndexError!u32 {
        if (t.arr_range.items.len == 0) {
            try t.arr_runs.ensureEmpty(gpa);
            try t.arr_range.append(gpa, .{});
        }
        if (run.len == 0) return 0;
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(gpa);
        for (run) |a| try words.appendSlice(gpa, &.{ @as(u32, @backingInt(a.kind)) | @as(u32, @intFromBool(a.deep)) << 8, a.j, a.slot, a.path });
        const id = try t.arr_runs.intern(gpa, words.items);
        if (id < t.arr_range.items.len) return id;
        const start: u32 = @intCast(t.arrivals.items.len);
        try t.arrivals.appendSlice(gpa, run);
        try t.arr_range.append(gpa, .{ .start = start, .len = @intCast(run.len) });
        return id;
    }

    /// A node's plain arrivals (at its own slot).
    pub fn here(t: *const Table, n: Node) []const Arrival {
        if (n == 0) return &.{};
        const r = t.arr_range.items[t.nodes.get(n)[0]];
        return t.arrivals.items[r.start..][0..r.len];
    }
    /// A node's open arrivals: at its slot and, by structure, every slot
    /// below it.
    pub fn open(t: *const Table, n: Node) []const Arrival {
        if (n == 0) return &.{};
        const r = t.arr_range.items[t.nodes.get(n)[1]];
        return t.arrivals.items[r.start..][0..r.len];
    }
    /// A node's kids, `(step word, node)` sorted by the step word.
    pub fn kids(t: *const Table, n: Node) []const [2]u32 {
        if (n == 0) return &.{};
        const w = t.nodes.get(n)[2..];
        return @as([*]const [2]u32, @ptrCast(w.ptr))[0 .. w.len / 2];
    }
    /// The entries at and below `n`.
    pub fn count(t: *const Table, n: Node) u32 {
        return if (n == 0) 0 else t.counts.items[n];
    }

    /// The kid of `n` at step `st`, or null.
    pub fn kidAt(t: *const Table, n: Node, st: u32) ?Node {
        const ks = t.kids(n);
        var lo: usize = 0;
        var hi: usize = ks.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (ks[mid][0] < st) lo = mid + 1 else hi = mid;
        }
        return if (lo < ks.len and ks[lo][0] == st) ks[lo][1] else null;
    }
};

const testing = std.testing;

test "equal subtrees are one node, and a node counts its entries" {
    const gpa = testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);
    const p: Arrival = .{ .kind = .param, .j = 0, .slot = 7, .deep = true };
    const leaf = try t.node(gpa, &.{}, &.{p}, &.{});
    var k1 = [_][2]u32{ .{ 2, leaf }, .{ 1, leaf } };
    const pair = try t.node(gpa, &.{}, &.{}, &k1);
    var k3 = [_][2]u32{ .{ 1, leaf }, .{ 2, leaf } };
    try testing.expectEqual(pair, try t.node(gpa, &.{}, &.{}, &k3));
    try testing.expectEqual(@as(u32, 2), t.count(pair));
    try testing.expectEqual(leaf, t.kidAt(pair, 2).?);
    try testing.expectEqual(@as(u32, 0), try t.node(gpa, &.{}, &.{}, &.{}));
}
