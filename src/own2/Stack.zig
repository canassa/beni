//! L8: the pending operands of a frame for resolution
//! (`docs/design/ownership-v2.md` §2.8 step 5, *Pending operands*). The walk
//! records each operand on its stack once, with the clock of its push and
//! its removal, and a call records only the clock; an operand is pending at
//! a call when its push is at or before the call's clock and its removal
//! after it. Its leaves are listed once, by their base keys, in lists sorted
//! by push, each with a tree of the latest removal over each range, so a
//! demand reads the pending leaves of a list in push order without a scan
//! of the operands that are not pending.
//!
//! For a parameter's untagged target only the leaves that reach unknown
//! objects and those of its own root at related positions are judged one by
//! one; every other pending leaf with a parameter's key answers `no` or
//! `under` its own selection and the target's: the target's joins through
//! one of them, and each one's own joins `req` once, at an accepted demand
//! it was pending at (as the operand index does, §2.8 *Operands*).
//!
//! Obligations kept here: O2's half for pending operands: every pending
//! leaf that can answer `may` is judged, in push order (the witness the
//! earliest).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Value = @import("Value.zig");
const Steps = @import("Steps.zig");
const Relation = @import("Relation.zig");
const Distinct = @import("Distinct.zig");
const PendingArg = @import("PendingArg.zig");
const Walk = @import("Walk.zig");
const Regions = @import("Regions.zig");

pub const Error = Ids.ChargeError;
const none: u32 = Ids.none_int;

/// A pending leaf: its leaf, its operand (`Walk.entries`), and whether it
/// is aggregated for a parameter's target (no unknown key).
pub const Item = struct { leaf: u32, entry: u32, agg: bool };

/// The lists: every leaf, the unknown ones, the aggregated ones with a
/// parameter's key; then one per parameter key `(position)`.
const all = 0;
const plain = 1;
const agg = 2;

const List = struct { start: u32, len: u32, cap: u32 = 0, tree: u32 = 0 };

pub const Index = struct {
    made: bool = false,
    items: std.ArrayList(Item) = .empty,
    /// Per item, its parameter keys' positions (a run of `poss`).
    pos_of: std.ArrayList([2]u32) = .empty,
    poss: std.ArrayList(u32) = .empty,
    lists: std.ArrayList(List) = .empty,
    order: std.ArrayList(u32) = .empty,
    /// Per position of `order`, its operand's push clock.
    pushes: std.ArrayList(u32) = .empty,
    /// Per list, two trees over its items: the latest removal and the
    /// least `rank₂` of the operands' points over each range (§2.5).
    tree: std.ArrayList(u32) = .empty,
    rank: std.ArrayList(u32) = .empty,
    /// A position's list; the lists by position (`Steps.PosLists`), as
    /// `Sweep`'s buckets.
    at_pos: std.ArrayList(u32) = .empty,
    reg: Steps.PosLists = .{},
    mark: std.ArrayList(u32) = .empty,
    query: u32 = 0,
    /// The accepted demands' parameter targets: `(clock, point, target)`.
    writes: std.ArrayList([3]u32) = .empty,

    pub fn deinit(x: *Index, g: Allocator) void {
        inline for (.{ &x.items, &x.pos_of, &x.poss, &x.lists, &x.order, &x.pushes, &x.tree, &x.rank, &x.mark, &x.writes }) |l| l.deinit(g);
        x.reg.deinit(g);
        x.at_pos.deinit(g);
    }

    /// List every pending leaf once (`keys.of(ev, leaf)`: its base keys).
    pub fn build(x: *Index, ev: *Relation.Eval, w: *const Walk.Walk, regions: *const Regions.Tree, keys: anytype) Error!void {
        if (x.made) return;
        x.made = true;
        const g = ev.gpa();
        var ls: std.ArrayList(u32) = .empty;
        defer ls.deinit(g);
        var per: std.ArrayList(std.ArrayList(u32)) = .empty;
        defer {
            for (per.items) |*l| l.deinit(g);
            per.deinit(g);
        }
        try per.appendNTimes(g, .empty, 3);
        // The record pass: an argument that waits for a walked call holds what that call's callee reads of it (`PendingArg`).
        var call_of: Ids.FixedDict(1) = .{};
        defer call_of.deinit(g);
        if (ev.f.records) for (ev.f.calls.items[0..w.walk_calls], 0..) |cl, q| try call_of.put(g, .{cl.inst}, @intCast(q));
        for (w.entries.items, 0..) |en, ei| for (w.pendingOfRun(en.vals)) |v| {
            ls.clearRetainingCapacity();
            const narrowed = if (call_of.get(.{en.call})) |q| try PendingArg.leaves(ev, q, en.inst, v, &ls) else false;
            if (!narrowed) try ev.leavesOf(v, 0, &ls);
            for (ls.items) |l| {
                try ev.f.charge(.inspection, 1);
                const ks = try keys.of(ev, l);
                const i: u32 = @intCast(x.items.items.len);
                const p0: u32 = @intCast(x.poss.items.len);
                if (!ks.unknown) for (ks.keys) |k| if (k[0] == 0) try x.poss.append(g, k[2]);
                try x.items.append(g, .{ .leaf = l, .entry = @intCast(ei), .agg = !ks.unknown });
                try x.pos_of.append(g, .{ p0, @as(u32, @intCast(x.poss.items.len)) - p0 });
                try x.mark.append(g, 0);
                try per.items[all].append(g, i);
                if (ks.unknown) try per.items[plain].append(g, i);
                if (x.poss.items.len > p0) try per.items[agg].append(g, i);
                for (x.poss.items[p0..]) |p| {
                    try ev.f.charge(.edge, 1);
                    if (p >= x.at_pos.items.len) try x.at_pos.appendNTimes(g, none, p + 1 - x.at_pos.items.len);
                    if (x.at_pos.items[p] == none) {
                        x.at_pos.items[p] = @intCast(per.items.len);
                        try per.append(g, .empty);
                        try x.register(ev, p, x.at_pos.items[p]);
                    }
                    const l2 = &per.items[x.at_pos.items[p]];
                    if (l2.items.len == 0 or l2.items[l2.items.len - 1] != i) try l2.append(g, i);
                }
            }
        };
        for (per.items) |l| try x.addList(ev, w, regions, l.items);
    }

    fn register(x: *Index, ev: *Relation.Eval, p: u32, list: u32) Error!void {
        try x.reg.file(ev.gpa(), ev.f.account, ev.f.pos.items, p, list);
    }

    /// A list of items (in push order) and its trees.
    fn addList(x: *Index, ev: *Relation.Eval, w: *const Walk.Walk, regions: *const Regions.Tree, items: []const u32) Error!void {
        const g = ev.gpa();
        var cap: u32 = 1;
        while (cap < items.len) cap *= 2;
        try ev.f.charge(.inspection, @intCast(1 + items.len));
        const l: List = .{ .start = @intCast(x.order.items.len), .len = @intCast(items.len), .cap = cap, .tree = @intCast(x.tree.items.len) };
        try x.order.appendSlice(g, items);
        for (items) |i| try x.pushes.append(g, w.entries.items[x.items.items[i].entry].push);
        try x.tree.appendNTimes(g, 0, 2 * cap);
        try x.rank.appendNTimes(g, std.math.maxInt(u32), 2 * cap);
        const t = x.tree.items[l.tree..][0 .. 2 * cap];
        const r = x.rank.items[l.tree..][0 .. 2 * cap];
        for (items, 0..) |i, k| {
            const en = w.entries.items[x.items.items[i].entry];
            t[cap + k] = en.gone;
            r[cap + k] = regions.rank2(en.inst);
        }
        var n = cap - 1;
        while (n >= 1) : (n -= 1) {
            t[n] = @max(t[2 * n], t[2 * n + 1]);
            r[n] = @min(r[2 * n], r[2 * n + 1]);
        }
        try x.lists.append(g, l);
    }

    /// The positions from `lo` of list `li` pending at clock `at` (pushed at
    /// or before it, removed after it; `none`: never) and compatible with a point of
    /// `rank₂` `r2` (an operand comes before the point: compatible exactly
    /// when its `rank₂` is below, §2.5), handed to `v.visit` in order until it
    /// stops: a descent into the subtrees whose latest removal is after `at`
    /// and least `rank₂` below `r2` whose first push is at or before `at`
    /// (the pushes are in order), a record a node, reserved before it is read.
    fn live(x: *const Index, ev: *Relation.Eval, li: u32, lo: u32, at: u32, r2: u32, v: anytype) Error!void {
        const l = x.lists.items[li];
        const q: Q = .{ .t = x.tree.items[l.tree..][0 .. 2 * l.cap], .r = x.rank.items[l.tree..][0 .. 2 * l.cap], .push = x.pushes.items[l.start..][0..l.len], .lo = lo, .hi = l.len, .at = at, .r2 = r2 };
        if (lo < l.len) _ = try descend(ev, q, 1, 0, l.cap, v);
    }

    const Q = struct { t: []const u32, r: []const u32, push: []const u32, lo: u32, hi: u32, at: u32, r2: u32 };

    fn descend(ev: *Relation.Eval, q: Q, node: u32, nl: u32, nr: u32, v: anytype) Error!bool {
        if (nr <= q.lo or nl >= q.hi or q.push[@max(nl, q.lo)] > q.at) return false;
        try ev.f.charge(.inspection, 1);
        if (q.t[node] <= q.at or q.r[node] >= q.r2) return false;
        if (nr - nl == 1) return v.visit(nl);
        const mid = nl + (nr - nl) / 2;
        if (try descend(ev, q, 2 * node, nl, mid, v)) return true;
        return descend(ev, q, 2 * node + 1, mid, nr, v);
    }

    /// Step 5's pending operands of a demand at clock `at` and `point`
    /// (§2.8): the earliest operand one of whose leaves may meet a target
    /// (its instruction), else null with every `under` gathered into
    /// `relied`. A parameter's target (`param_target`) judged with
    /// aggregation reads the unknown leaves and its related positions'
    /// lists; the target's selection joins through one other leaf.
    pub fn judge(x: *Index, ev: *Relation.Eval, w: *const Walk.Walk, regions: *const Regions.Tree, at: u32, point: u32, targets: []const u32, aggregate: bool, param_target: *const fn (*const Value.Frame, Value.Leaf) bool, relied: anytype) Error!?u32 {
        if (@import("Mutate.zig").on(.stack_judge_off)) return null;
        if (at == none or x.items.items.len == 0) return null;
        const g = ev.gpa();
        var lists: std.ArrayList(u32) = .empty;
        defer lists.deinit(g);
        // A list is read in push order: past the earliest witness so far,
        // nothing can be the witness.
        const V = struct {
            x: *Index,
            ev: *Relation.Eval,
            w: *const Walk.Walk,
            regions: *const Regions.Tree,
            point: u32,
            li: u32 = all,
            t: u32 = none,
            /// Aggregated: the first that answers `under` is enough.
            once: bool = false,
            best: u32 = none,
            relied: @TypeOf(relied),
            fn visit(v: *@This(), p: u32) Error!bool {
                const i = v.x.order.items[v.x.lists.items[v.li].start + p];
                const it = v.x.items.items[i];
                if (it.entry >= v.best) return true;
                if (v.x.mark.items[i] == v.x.query) return false;
                if (!v.once) v.x.mark.items[i] = v.x.query;
                if (!v.regions.compatible(v.w.entries.items[it.entry].inst, v.point)) return false;
                const ov = try Distinct.overlap(v.ev, it.leaf, v.t, true);
                switch (ov.kind) {
                    .no => return false,
                    .under => try v.relied.add(v.ev.gpa(), v.ev.account(), ov.cond),
                    .may => {
                        v.best = it.entry;
                        return true;
                    },
                }
                return v.once;
            }
        };
        var v: V = .{ .x = x, .ev = ev, .w = w, .regions = regions, .point = point, .relied = relied };
        const r2 = regions.rank2(point);
        for (targets) |t| {
            x.query += 1;
            lists.clearRetainingCapacity();
            const tl = ev.f.leafAt(t);
            const by_key = aggregate and param_target(ev.f, tl);
            if (by_key) {
                try lists.append(g, plain);
                try x.related(ev, tl.pos, &lists);
            } else try lists.append(g, all);
            v.t = t;
            v.once = false;
            for (lists.items) |li| {
                v.li = li;
                try x.live(ev, li, 0, at, r2, &v);
            }
            if (!by_key or v.best != none) continue;
            // The target's selection: the first other pending leaf with a
            // parameter's key that answers `under`.
            if (@import("Mutate.zig").on(.stack_agg_off)) continue;
            v.li = agg;
            v.once = true;
            try x.live(ev, agg, 0, at, r2, &v);
        }
        return if (v.best == none) null else w.entries.items[v.best].inst;
    }

    /// The lists at positions related to `p` (§2.3.2), as `Sweep.Live.related`.
    fn related(x: *const Index, ev: *Relation.Eval, p: u32, out: *std.ArrayList(u32)) Error!void {
        try x.reg.ask(ev.gpa(), ev.f.account, ev.f.pos.items, p, out);
    }

    /// An accepted demand judged with aggregation: its parameter targets.
    pub fn accept(x: *Index, ev: *Relation.Eval, at: u32, point: u32, targets: []const u32, param_target: *const fn (*const Value.Frame, Value.Leaf) bool) Error!void {
        if (at == none or x.items.items.len == 0) return;
        for (targets) |t| if (param_target(ev.f, ev.f.leafAt(t))) try x.writes.append(ev.gpa(), .{ at, point, t });
    }

    /// Each aggregated pending leaf's own selection, into `req`: through an
    /// accepted demand it was pending at, compatible with, not judged one
    /// by one for (no key at a position related to the target's), and
    /// answers `under` for.
    pub fn finish(x: *Index, ev: *Relation.Eval, w: *const Walk.Walk, regions: *const Regions.Tree, req: anytype, arena: Allocator) Error!void {
        if (x.writes.items.len == 0) return;
        const f = ev.f;
        try f.charge(.inspection, @intCast(1 + 2 * x.writes.items.len));
        std.mem.sort([3]u32, x.writes.items, {}, struct {
            fn lt(_: void, a: [3]u32, b: [3]u32) bool {
                return std.mem.order(u32, &a, &b) == .lt;
            }
        }.lt);
        // The writes' points by a tree of the greatest `rank₂` over each
        // range: an operand's compatible writes are found, not scanned.
        const n: u32 = @intCast(x.writes.items.len);
        var cap: u32 = 1;
        while (cap < n) cap *= 2;
        const g = ev.gpa();
        const t = try g.alloc(u32, 2 * cap);
        defer g.free(t);
        const zero = try g.alloc(u32, 2 * cap);
        defer g.free(zero);
        @memset(t, 0);
        @memset(zero, 0);
        for (x.writes.items, 0..) |wr, k| t[cap + k] = regions.rank2(wr[1]) + 1;
        var m = cap - 1;
        while (m >= 1) : (m -= 1) t[m] = @max(t[2 * m], t[2 * m + 1]);
        // The items in push order, each entry's together: the writes from
        // its push on by one pointer, its first compatible write once.
        const l = x.lists.items[agg];
        var start: u32 = 0;
        var entry: u32 = none;
        var first: u32 = none;
        for (x.order.items[l.start..][0..l.len]) |i| {
            const it = x.items.items[i];
            const en = w.entries.items[it.entry];
            while (start < n and x.writes.items[start][0] < en.push) : (start += 1) try f.charge(.inspection, 1);
            const q: Q = .{ .t = t, .r = zero, .push = zero, .lo = start, .hi = n, .at = regions.rank2(en.inst) + 1, .r2 = 1 };
            if (it.entry != entry) {
                entry = it.entry;
                first = try nextWrite(ev, q, cap, start);
            }
            var k = first;
            while (k != none and x.writes.items[k][0] < en.gone) : (k = try nextWrite(ev, q, cap, k + 1)) {
                const wr = x.writes.items[k];
                const tl = f.leafAt(wr[2]);
                const pr = x.pos_of.items[i];
                const near = for (x.poss.items[pr[0]..][0..pr[1]]) |p| {
                    if ((try f.related(p, tl.pos)).rel == .related) break true;
                } else false;
                if (near) continue;
                const o = try Distinct.overlap(ev, it.leaf, wr[2], true);
                if (o.kind != .under) continue;
                try req.add(arena, ev.account(), o.cond);
                break;
            }
        }
    }

    /// The first write at or after `lo` compatible with `q`'s operand.
    fn nextWrite(ev: *Relation.Eval, q: Q, cap: u32, lo: u32) Error!u32 {
        if (lo >= q.hi) return none;
        var qk = q;
        qk.lo = lo;
        var first: struct {
            p: u32 = none,
            fn visit(v: *@This(), p: u32) Error!bool {
                v.p = p;
                return true;
            }
        } = .{};
        _ = try descend(ev, qk, 1, 0, cap, &first);
        return first.p;
    }
};
