//! A use's exits (`docs/design/ownership-v2.md` §2.7, *A read that leaves its
//! path on a cycle*, #1345): the paths outside a use's subtree at which
//! `extend` puts what the use reads, and the cover of a hold by a use with
//! them, which the holder index (`Holders`) asks.
//!
//! The cover is by prefix: a use at `q` counts for a hold at or below `q`. On
//! a cycle of the place graph that is not enough, because `extend` folds a
//! re-entry into the `⟲` of the deepest place on the path it re-enters, which
//! may be above `q`: every tree below `r` is reached through `r.kids[*]`, and
//! its path is `r⟲`. A read of every path below `p` exits at `Place.foldsUp`;
//! a `call` use's node is replayed from `q` as `Walk.Graft` replays it, a
//! folded step and a callee `⟲` (`Place.levelsOf`) each an exit with the node
//! it leads to. Exits are made once per `(path, use node)`, by one walk of the
//! use node's nodes on a cycle of the place graph.
//!
//! Obligations kept here: none of its own; it answers the cover that
//! `Holders` keeps O12 with.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Cell = @import("Cell.zig");
const Shape = @import("Shape.zig");
const Facts = @import("Facts.zig");

const NodeId = Ids.NodeId;
const PathId = Ids.PathId;
const Error = Ids.ChargeError;

/// A path outside the use's subtree and the callee node read on below it;
/// `none` reads every path below (a deep read).
pub const Exit = struct { path: PathId, node: NodeId };

/// The tables a cover reads.
pub const Tables = struct {
    gpa: Allocator,
    charge: Ids.Charge,
    places: *Place.Table,
    shapes: *Shape.Table,
    cells: *Cell.Table,
};

/// One frame's exits, by `(path, use node)`, and per use node whether a
/// node of its subtree is on a cycle of the place graph.
pub const Memo = struct {
    of: Ids.FixedDict(2) = .{},
    runs: std.ArrayList(Ids.Range) = .empty,
    items: std.ArrayList(Exit) = .empty,
    cyclic: Ids.FixedDict(1) = .{},
    stack: std.ArrayList(Exit) = .empty,
    steps: std.ArrayList(Place.Step) = .empty,

    pub fn deinit(m: *Memo, gpa: Allocator) void {
        m.of.deinit(gpa);
        m.runs.deinit(gpa);
        m.items.deinit(gpa);
        m.cyclic.deinit(gpa);
        m.stack.deinit(gpa);
        m.steps.deinit(gpa);
    }

    /// Whether `use` covers a hold at `f` (§2.7): `f` on the way to its path
    /// or to an exit, or below one of them where the callee reads on.
    pub fn covers(m: *Memo, t: Tables, use: Facts.Use, f: PathId) Error!bool {
        const places = t.places;
        const node: NodeId = if (use.kind == .call) use.use_node else .none;
        if (places.isPrefix(f, use.path)) return true;
        if (places.isPrefix(use.path, f) and try m.reads(t, node, use.path, f)) return true;
        const r = try m.exits(t, use.path, node);
        var i: u32 = 0;
        while (i < r.len) : (i += 1) {
            try t.charge.reserve(t.gpa, .inspection, 1);
            const e = m.items.items[r.start + i];
            if (places.isPrefix(f, e.path)) return true;
            if (places.isPrefix(e.path, f) and try m.reads(t, e.node, e.path, f)) return true;
        }
        return false;
    }

    /// Whether the callee node `n` at `at` reads `f` below it: the cursor
    /// of §2.7, free below a non-empty leaf or a node marked `D`.
    fn reads(m: *Memo, t: Tables, n0: NodeId, at: PathId, f: PathId) Error!bool {
        if (n0 == .none) return true;
        const places = t.places;
        m.steps.clearRetainingCapacity();
        var x = f;
        while (x != at) : (x = places.pathParent(x)) try m.steps.append(t.gpa, places.pathStep(x));
        var n = n0;
        var k = m.steps.items.len;
        while (k > 0) {
            k -= 1;
            try t.charge.reserve(t.gpa, .inspection, 1);
            if (try deep(t, n)) return true;
            if (t.shapes.kind(n) == .leaf) return false;
            n = (try t.shapes.proj(t.gpa, t.charge.account, places, t.cells, n, m.steps.items[k])) orelse return true;
        }
        return t.shapes.cells(n) != .none;
    }

    /// The exits of a read at `q` by callee node `u` (`none`: every path
    /// below `q`), memoised; a run of `items`.
    pub fn exits(m: *Memo, t: Tables, q: PathId, u: NodeId) Error!Ids.Range {
        const gpa = t.gpa;
        const places = t.places;
        try t.charge.reserve(gpa, .memo, 1);
        if (m.of.get(.{ q.int(), u.int() })) |i| return m.runs.items[i];
        const start: u32 = @intCast(m.items.items.len);
        // Exits kept, and pairs walked: a use shape that is a DAG is walked
        // as a DAG.
        var seen: Ids.FixedDict(2) = .{};
        defer seen.deinit(gpa);
        var walked: Ids.FixedDict(2) = .{};
        defer walked.deinit(gpa);
        m.stack.clearRetainingCapacity();
        try m.stack.append(gpa, .{ .path = q, .node = u });
        while (m.stack.pop()) |top| {
            try t.charge.reserve(gpa, .inspection, 1);
            const p = top.path;
            if ((try walked.getOrPut(gpa, .{ p.int(), top.node.int() })).found_existing) continue;
            const n = if (top.node != .none and t.shapes.kind(top.node) == .view) try t.shapes.force(gpa, t.charge.account, top.node) else top.node;
            if (n != .none and !places.cyclic(places.pathPlace(p)) and !try m.onCycle(t, n)) continue;
            // A read of every path below `p`, and a kind this walk does not
            // follow, exit where `p`'s levels fold above it.
            if (n == .none or try deep(t, n) or t.shapes.kind(n) != .node) {
                if (n != .none and t.shapes.kind(n) == .leaf and t.shapes.cells(n) == .none) continue;
                const r = try places.foldsUp(gpa, t.charge, p);
                var i: u32 = 0;
                while (i < r.len) : (i += 1) try m.add(t, &seen, .{ .path = places.foldPath(r.start + i), .node = .none }, false);
                continue;
            }
            var it = t.shapes.overEntries(t.shapes.get(n).a);
            while (it.next()) |e| {
                try t.charge.reserve(gpa, .inspection, 1);
                if (e.step.kind == .level) {
                    const r = try places.levelsOf(gpa, t.charge, p);
                    var i: u32 = 0;
                    while (i < r.len) : (i += 1) try m.add(t, &seen, .{ .path = places.foldPath(r.start + i), .node = e.node }, true);
                    continue;
                }
                const y = (try places.extend(gpa, t.charge, p, e.step)) orelse continue;
                const plain = places.pathParent(y) == p and places.pathStep(y).word() == e.step.word();
                if (plain) try m.stack.append(gpa, .{ .path = y, .node = e.node }) else try m.add(t, &seen, .{ .path = y, .node = e.node }, true);
            }
        }
        const run: Ids.Range = .{ .start = start, .len = @as(u32, @intCast(m.items.items.len)) - start };
        (try m.of.getOrPut(gpa, .{ q.int(), u.int() })).value_ptr.* = @intCast(m.runs.items.len);
        try m.runs.append(gpa, run);
        return run;
    }

    /// An exit, once, and a callee node read on from it (`walk`) walked on.
    /// It is kept below `q` too: the callee's canonical paths there need not
    /// be the caller's. A same-module callee on a mutual cycle keeps the
    /// route (`π1⟲#P.0` of a `P`/`Q` cycle) that the caller folds into
    /// `t⟲`, so the cursor from `q` would not reach it (#1345).
    fn add(m: *Memo, t: Tables, seen: *Ids.FixedDict(2), e: Exit, walk: bool) Error!void {
        if ((try seen.getOrPut(t.gpa, .{ e.path.int(), e.node.int() })).found_existing) return;
        if (walk) try m.stack.append(t.gpa, e);
        try m.items.append(t.gpa, e);
    }

    /// Whether a node of `n`'s subtree is on a cycle of the place graph:
    /// one that is not makes no exit. Memoised per node, on an explicit
    /// stack (#1138).
    fn onCycle(m: *Memo, t: Tables, n0: NodeId) Error!bool {
        const gpa = t.gpa;
        if (m.cyclic.get(.{n0.int()})) |b| return b == 1;
        const Item = struct { n: NodeId, expanded: bool };
        var stack: std.ArrayList(Item) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, .{ .n = n0, .expanded = false });
        while (stack.pop()) |f| {
            if (m.cyclic.get(.{f.n.int()}) != null) continue;
            const d = t.shapes.get(f.n);
            if (!f.expanded and d.kind == .node) {
                try t.charge.reserve(gpa, .inspection, 1);
                try stack.append(gpa, .{ .n = f.n, .expanded = true });
                var it = t.shapes.overEntries(d.a);
                while (it.next()) |k| if (m.cyclic.get(.{k.node.int()}) == null) try stack.append(gpa, .{ .n = k.node, .expanded = false });
                continue;
            }
            // A kind other than a node is read as a whole: on a cycle when
            // its place is.
            var on = t.places.cyclic(d.place);
            if (d.kind == .node) {
                var it = t.shapes.overEntries(d.a);
                while (it.next()) |k| on = on or k.step.kind == .level or m.cyclic.get(.{k.node.int()}).? == 1;
            }
            (try m.cyclic.getOrPut(gpa, .{f.n.int()})).value_ptr.* = @intFromBool(on);
        }
        return m.cyclic.get(.{n0.int()}).? == 1;
    }
};

/// A callee node that reads every path below it: a non-empty leaf (a leaf
/// of marks, §2.13.6), or a node marked `D` (§2.10).
fn deep(t: Tables, n: NodeId) Error!bool {
    if (t.shapes.kind(n) == .leaf) return t.shapes.cells(n) != .none;
    if (t.cells.mark_d == .none) return false;
    return t.cells.hasDeepRead(try t.shapes.cellsOf(t.gpa, t.charge.account, &t.cells.sets, n));
}
