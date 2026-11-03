//! L8: the holder index and its sweep (`docs/design/ownership-v2.md` §2.8,
//! *The holder index and its sweep*, *Holder entries judged by base
//! leaves*). A holder is live while the sweep's point is past its binding
//! and before its last use. The first demand that meets live holders keys
//! them: each holder's holds (its value's leaves with the path at which it
//! holds each) are listed once, and the holder is entered under the base
//! keys of its holds, a parameter's key per position. Each key's bucket is
//! a heap of its live holders by their next use, so a demand visits its
//! buckets' holders in use order and stops once no later one can be its
//! witness. A parameter's buckets are registered at their positions, so a
//! parameter's target finds the buckets at related positions only; every
//! other holder of a parameter's object can only add an apart selection,
//! and is judged once (`pending`, then `done`), not once a demand.
//!
//! Obligations kept here: O2's resolution half: every live holder that may
//! hold a target is visited in use order up to the witness, or judged as an
//! aggregated holder; none is skipped.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");

pub const Error = Ids.ChargeError;
const PathId = Ids.PathId;
const none: u32 = Ids.none_int;
const top_key: u32 = std.math.maxInt(u32);

/// A base key (`Holders.Key`): kind 0 a parameter (`a` its index, the third
/// word its base leaf's position), 1 a site, 2 a call's fresh atom, 3 a
/// shared value, 4 unknown.
pub const Key = [3]u32;
const unknown_key: Key = .{ 4, 0, 0 };

/// One hold: a leaf of the holder's value and the path at which the holder
/// holds it. `refine`: a leaf of a `ref` value of no family, whose path is
/// refined by the target's slots (§2.8 step 5). `agg`: its base keys are
/// parameters' and none unknown, so for a parameter's target it answers no
/// or `under` (§2.8, *the factorisation*); `done`: its selection is in the
/// frame's `req` already.
/// `node`: its node in the holder's DAG, when the holder has one.
pub const Hold = struct { leaf: u32, q: PathId, refine: bool, agg: bool = false, done: bool = false, node: u32 = none };

/// A holder's value as a DAG (§2.8 step 3 on slots), when a node of it is
/// reached by two paths: each `(value, tags)` once, at its least path, with
/// its holds and its kids in order, each by the step that reaches it (none:
/// the same path).
pub const DNode = struct { holds: Ids.Range = .{}, edges: Ids.Range = .{}, q: PathId };
pub const DEdge = struct { node: u32 = none, step: ?Place.Step = null };
pub const Dag = struct {
    nodes: std.ArrayList(DNode) = .empty,
    edges: std.ArrayList(DEdge) = .empty,
    pub fn deinit(d: *Dag, g: Allocator) void {
        d.nodes.deinit(g);
        d.edges.deinit(g);
    }
};

/// The holds of a value held at `root` (§2.8 step 5): the storage of every
/// built node at its path, and every leaf of a `ref`, `⊤` or shared value at
/// the path that reaches it. One walk of the value; a node met again at the
/// same path and tags is not walked again. When one is met at a second
/// path, the value is walked again as `dag` (true returned): each node
/// once, kids in order, so a node's first visit is at its least path.
pub fn holdsOfValue(ev: *Relation.Eval, value: u32, root: PathId, out: *std.ArrayList(Hold), dag: *Dag) Error!bool {
    const start = out.items.len;
    if (try walkHolds(ev, value, root, out, null)) return false;
    out.shrinkRetainingCapacity(start);
    _ = try walkHolds(ev, value, root, out, dag);
    return true;
}

fn walkHolds(ev: *Relation.Eval, value: u32, root: PathId, out: *std.ArrayList(Hold), dag: ?*Dag) Error!bool {
    const fr = ev.f;
    const g = ev.gpa();
    const base = out.items.len;
    // `edge`: the parent's edge slot this item fills (a DAG's).
    const Item = struct { v: u32, q: PathId, tags: u32, edge: u32 = none };
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(g);
    var seen: Ids.FixedDict(3) = .{};
    defer seen.deinit(g);
    // Per `(value, tags)`: its first path, or its DAG node.
    var first: Ids.FixedDict(2) = .{};
    defer first.deinit(g);
    try stack.append(g, .{ .v = value, .q = root, .tags = 0 });
    while (stack.pop()) |it| {
        const at = try first.getOrPut(g, .{ it.v, it.tags });
        if (dag) |d| {
            if (at.found_existing) {
                d.edges.items[it.edge].node = at.value_ptr.*;
                continue;
            }
            at.value_ptr.* = @intCast(d.nodes.items.len);
            if (it.edge != none) d.edges.items[it.edge].node = at.value_ptr.*;
            try d.nodes.append(g, .{ .q = it.q, .holds = .{ .start = @intCast(out.items.len - base) } });
        } else if (at.found_existing) {
            if (at.value_ptr.* != it.q.int()) return false;
        } else at.value_ptr.* = it.q.int();
        if ((try seen.getOrPut(g, .{ it.v, it.q.int(), it.tags })).found_existing) continue;
        try fr.charge(.inspection, 1);
        const x = fr.val(it.v);
        const ni: u32 = if (dag) |d| @intCast(d.nodes.items.len - 1) else none;
        defer if (dag) |d| {
            d.nodes.items[ni].holds.len = @intCast(out.items.len - base - d.nodes.items[ni].holds.start);
        };
        // A DAG's kids: their edge slots in order, pushed last first.
        const e0: u32 = if (dag) |d| @intCast(d.edges.items.len) else none;
        const s0 = stack.items.len;
        defer if (dag) |d| {
            const n: u32 = @intCast(stack.items.len - s0);
            d.nodes.items[ni].edges = .{ .start = e0, .len = n };
            for (stack.items[s0..], 0..) |*k, i| k.edge = e0 + @as(u32, @intCast(i));
            std.mem.reverse(Item, stack.items[s0..]);
        };
        switch (x.kind) {
            .scalar, .bot => {},
            .alt => {
                const ks = fr.kidsOf(x);
                var i: usize = 0;
                while (i < ks.len) : (i += 2) {
                    const t = (try fr.mergeTags(it.tags, try fr.internTags(&.{.{ x.head, try fr.armOf(ks[i]) }}))) orelse continue;
                    if (dag) |d| try d.edges.append(g, .{});
                    try stack.append(g, .{ .v = ks[i + 1], .q = it.q, .tags = t });
                }
            },
            .built => {
                var own: std.ArrayList(u32) = .empty;
                defer own.deinit(g);
                try ev.storageOf(it.v, it.tags, &own);
                for (own.items) |l| try out.append(g, .{ .leaf = l, .q = it.q, .refine = false, .node = ni });
                for (fr.kidsOf(x), 0..) |kv, n| {
                    const st: ?Place.Step = switch (x.form) {
                        .tuple => try Place.Step.index(fr.account, @intCast(n)),
                        .ctor => try fr.places.ctorStep(g, fr.account, x.head, @intCast(n)),
                        .list => Place.Step.elem,
                        .record => try Place.Step.field(fr.account, fr.wordsOf(x.extra)[n]),
                        .closure, .opaque_ => null,
                    };
                    const nq = if (st) |s| (try fr.places.extend(g, fr.gc(), it.q, s)) orelse it.q else it.q;
                    if (dag) |d| try d.edges.append(g, .{ .step = st });
                    try stack.append(g, .{ .v = kv, .q = nq, .tags = it.tags });
                }
            },
            .ref, .top, .shared, .host => {
                var ls: std.ArrayList(u32) = .empty;
                defer ls.deinit(g);
                try ev.leavesOf(it.v, it.tags, &ls);
                for (ls.items) |l| try out.append(g, .{ .leaf = l, .q = it.q, .refine = x.family == Slots.empty, .node = ni });
            },
        }
    }
    return true;
}

/// The holder index: buckets by base key, each a heap of `(bucket,
/// holder)` entries by the holder's next use; a parameter's buckets
/// registered at their positions; the unkeyed live holders; the aggregated
/// holders, pending and done.
pub const Live = struct {
    bucket: Ids.FixedDict(3) = .{},
    /// Per bucket: its heap of entries, and its key's position (a
    /// parameter's), else `none`.
    heap: std.ArrayList(std.ArrayList(u32)) = .empty,
    b_pos: std.ArrayList(u32) = .empty,
    /// The parameters' buckets, which a parameter's target meets.
    params: std.ArrayList(u32) = .empty,
    /// The bucket of holders whose values reach unknown objects.
    unknown_bucket: u32 = none,
    /// Per entry: its bucket, its holder, its stored key (a lower bound of
    /// the holder's next use, exact once past the sweep's point) and its
    /// index in its bucket's heap.
    e_bucket: std.ArrayList(u32) = .empty,
    e_holder: std.ArrayList(u32) = .empty,
    e_key: std.ArrayList(u32) = .empty,
    e_at: std.ArrayList(u32) = .empty,
    holders: std.ArrayList(Holder) = .empty,
    holds: std.ArrayList(Hold) = .empty,
    /// The keyed holders' DAGs (`Dag`), node and edge indices rebased.
    dnodes: std.ArrayList(DNode) = .empty,
    dedges: std.ArrayList(DEdge) = .empty,
    /// Per keyed holder, its uses' points, sorted.
    uses: std.ArrayList(u32) = .empty,
    /// The unkeyed live holders: a list by holder index.
    unkeyed: u32 = none,
    u_next: std.ArrayList(u32) = .empty,
    u_prev: std.ArrayList(u32) = .empty,
    /// The aggregated holders' lists (§2.8 step 3): 0 pending, 1 done.
    agg_head: [2]u32 = .{ none, none },
    a_next: std.ArrayList(u32) = .empty,
    a_prev: std.ArrayList(u32) = .empty,
    /// Holder indices by binding point and by last use; the sweep's cursors.
    by_bind: std.ArrayList(u32) = .empty,
    by_last: std.ArrayList(u32) = .empty,
    at_bind: usize = 0,
    at_last: usize = 0,
    /// The holders live now, keyed or not; the sweep's point.
    live: u32 = 0,
    now: u32 = 0,
    /// Per position, five lists of parameter buckets: those at the
    /// position, then those below it by a plain, front, back and slice
    /// step of its own.
    reg: std.ArrayList(std.ArrayList(u32)) = .empty,
    /// Per holder and per bucket: the query that last met it.
    mark: std.ArrayList(u32) = .empty,
    b_mark: std.ArrayList(u32) = .empty,
    query: u32 = 0,
    /// A query's frontier of heap slots.
    frontier: std.ArrayList(Slot) = .empty,

    pub const Holder = struct {
        local: u32,
        point: u32,
        last: u32,
        /// Entries, holds and uses: runs of `e_*`, `holds`, `uses`.
        start: u32 = 0,
        len: u32 = 0,
        h_start: u32 = 0,
        h_len: u32 = 0,
        u_start: u32 = 0,
        u_len: u32 = 0,
        cur: u32 = 0,
        state: enum(u8) { idle, unkeyed, keyed, gone } = .idle,
        /// The aggregated list it is on: 0 pending, 1 done, `none` none.
        agg: u32 = none,
        /// Its DAG's root node in `dnodes`, when it has one.
        d_root: u32 = none,
    };

    pub fn deinit(x: *Live, g: Allocator) void {
        x.bucket.deinit(g);
        for (x.heap.items) |*h| h.deinit(g);
        for (x.reg.items) |*l| l.deinit(g);
        inline for (.{ &x.heap, &x.reg }) |l| l.deinit(g);
        inline for (.{ &x.b_pos, &x.params, &x.e_bucket, &x.e_holder, &x.e_key, &x.e_at, &x.uses, &x.u_next, &x.u_prev, &x.a_next, &x.a_prev, &x.by_bind, &x.by_last, &x.mark, &x.b_mark }) |l| l.deinit(g);
        x.frontier.deinit(g);
        x.holders.deinit(g);
        x.holds.deinit(g);
        x.dnodes.deinit(g);
        x.dedges.deinit(g);
    }

    /// Index local `l`, bound at `point` and last used at `last`.
    pub fn add(x: *Live, ev: *Relation.Eval, l: u32, point: u32, last: u32) Error!void {
        const g = ev.gpa();
        try ev.f.charge(.inspection, 1);
        try x.holders.append(g, .{ .local = l, .point = point, .last = last });
        inline for (.{ &x.u_next, &x.u_prev, &x.a_next, &x.a_prev }) |c| try c.append(g, none);
        try x.mark.append(g, 0);
    }

    /// Order the holders for the sweep: by binding point and by last use,
    /// each a counting sort over the frame's points (source-sized, linear).
    pub fn finish(x: *Live, ev: *Relation.Eval) Error!void {
        const g = ev.gpa();
        const hs = x.holders.items;
        if (hs.len == 0) return;
        // Points are the module's instruction numbers: the sort spans the
        // holders' own points only, so its cost is the declaration's.
        var lo: u32 = std.math.maxInt(u32);
        var top: u32 = 0;
        for (hs) |h| {
            lo = @min(lo, h.point);
            top = @max(top, @max(h.point, h.last));
        }
        try ev.f.charge(.inspection, @intCast(2 * hs.len + (top - lo) / 16 + 1));
        try countingSort(g, hs, &x.by_bind, lo, top, struct {
            fn key(h: Holder) u32 {
                return h.point;
            }
        }.key);
        try countingSort(g, hs, &x.by_last, lo, top, struct {
            fn key(h: Holder) u32 {
                return h.last;
            }
        }.key);
    }

    fn countingSort(g: Allocator, hs: []const Holder, out: *std.ArrayList(u32), lo: u32, top: u32, comptime keyOf: fn (Holder) u32) Allocator.Error!void {
        const starts = try g.alloc(u32, top - lo + 2);
        defer g.free(starts);
        @memset(starts, 0);
        for (hs) |h| starts[keyOf(h) - lo + 1] += 1;
        for (1..starts.len) |i| starts[i] += starts[i - 1];
        try out.resize(g, hs.len);
        for (hs, 0..) |h, i| {
            out.items[starts[keyOf(h) - lo]] = @intCast(i);
            starts[keyOf(h) - lo] += 1;
        }
    }

    /// Move the sweep to point `p` (never back): every holder bound before
    /// it joins the unkeyed list, every holder last used at or before it
    /// leaves its heaps and lists.
    pub fn advance(x: *Live, ev: *Relation.Eval, p: u32) Error!void {
        x.now = p;
        const hs = x.holders.items;
        while (x.at_bind < x.by_bind.items.len and hs[x.by_bind.items[x.at_bind]].point < p) : (x.at_bind += 1) {
            const hi = x.by_bind.items[x.at_bind];
            if (hs[hi].state != .idle or hs[hi].last <= p) continue;
            try ev.f.charge(.inspection, 1);
            hs[hi].state = .unkeyed;
            x.live += 1;
            x.u_prev.items[hi] = none;
            x.u_next.items[hi] = x.unkeyed;
            if (x.unkeyed != none) x.u_prev.items[x.unkeyed] = hi;
            x.unkeyed = hi;
        }
        while (x.at_last < x.by_last.items.len and hs[x.by_last.items[x.at_last]].last <= p) : (x.at_last += 1) {
            const hi = x.by_last.items[x.at_last];
            const h = &hs[hi];
            defer h.state = .gone;
            if (h.state == .unkeyed or h.state == .keyed) x.live -= 1;
            switch (h.state) {
                .idle, .gone => {},
                .unkeyed => {
                    try ev.f.charge(.inspection, 1);
                    x.unlinkUnkeyed(hi);
                },
                .keyed => {
                    for (h.start..h.start + h.len) |e| try x.heapRemove(ev, @intCast(e));
                    if (h.agg != none) x.aggUnlink(hi);
                },
            }
        }
    }

    fn unlinkUnkeyed(x: *Live, hi: u32) void {
        const nx = x.u_next.items[hi];
        const pv = x.u_prev.items[hi];
        if (pv != none) x.u_next.items[pv] = nx else x.unkeyed = nx;
        if (nx != none) x.u_prev.items[nx] = pv;
    }

    /// Whether any holder is live.
    pub fn any(x: *const Live) bool {
        return x.live != 0;
    }

    /// An unkeyed live holder taken off its list for `key`: its index, or null.
    pub fn takeUnkeyed(x: *Live) ?u32 {
        const hi = x.unkeyed;
        if (hi == none) return null;
        x.unlinkUnkeyed(hi);
        return hi;
    }

    fn bucketOf(x: *Live, ev: *Relation.Eval, k: Key) Error!u32 {
        const g = ev.gpa();
        const got = try x.bucket.getOrPut(g, k);
        if (got.found_existing) return got.value_ptr.*;
        const b: u32 = @intCast(x.heap.items.len);
        got.value_ptr.* = b;
        try x.heap.append(g, .empty);
        try x.b_mark.append(g, 0);
        try x.b_pos.append(g, if (k[0] == 0) k[2] else none);
        if (k[0] == 4) x.unknown_bucket = b;
        if (k[0] == 0) {
            try x.params.append(g, b);
            // Registered at its position and below each ancestor by the
            // step that leads to it: a record a step.
            const pos = ev.f.pos.items;
            try x.regAdd(ev, k[2], 0, b);
            var c = k[2];
            while (pos[c].parent != none) : (c = pos[c].parent) try x.regAdd(ev, pos[c].parent, 1 + @as(u32, @backingInt(pos[c].kind)), b);
        }
        return b;
    }

    fn regAdd(x: *Live, ev: *Relation.Eval, p: u32, which: u32, b: u32) Error!void {
        const g = ev.gpa();
        try ev.f.charge(.edge, 1);
        const at = 5 * p + which;
        if (at >= x.reg.items.len) try x.reg.appendNTimes(g, .empty, at + 1 - x.reg.items.len);
        try x.reg.items[at].append(g, b);
    }

    fn regList(x: *const Live, p: u32, which: u32) []const u32 {
        const at = 5 * p + which;
        return if (at < x.reg.items.len) x.reg.items[at].items else &.{};
    }

    /// Key holder `hi`, which `takeUnkeyed` gave: its `holds` (each `agg`
    /// set), its base keys (sorted, once each; the unknown key alone when
    /// `unknown`) and its uses' points.
    pub fn key(x: *Live, ev: *Relation.Eval, hi: u32, holds: []const Hold, dag: ?*const Dag, keys: []const Key, unknown: bool, points: []const u32) Error!void {
        const g = ev.gpa();
        if (dag) |d| {
            const nb: u32 = @intCast(x.dnodes.items.len);
            const eb: u32 = @intCast(x.dedges.items.len);
            try ev.f.charge(.inspection, @intCast(d.nodes.items.len + d.edges.items.len));
            x.holders.items[hi].d_root = nb;
            for (d.nodes.items) |n| try x.dnodes.append(g, .{ .q = n.q, .holds = n.holds, .edges = .{ .start = n.edges.start + eb, .len = n.edges.len } });
            for (d.edges.items) |e| try x.dedges.append(g, .{ .node = e.node + nb, .step = e.step });
        }
        const h = &x.holders.items[hi];
        h.h_start = @intCast(x.holds.items.len);
        h.h_len = @intCast(holds.len);
        try x.holds.appendSlice(g, holds);
        h.u_start = @intCast(x.uses.items.len);
        h.u_len = @intCast(points.len);
        try x.uses.appendSlice(g, points);
        std.mem.sort(u32, x.uses.items[h.u_start..][0..h.u_len], {}, std.sort.asc(u32));
        try ev.f.charge(.inspection, @intCast(1 + points.len));
        h.start = @intCast(x.e_bucket.items.len);
        const ks: []const Key = if (unknown) &.{unknown_key} else keys;
        for (ks) |k| {
            try ev.f.charge(.edge, 1);
            const b = try x.bucketOf(ev, k);
            const e: u32 = @intCast(x.e_bucket.items.len);
            try x.e_bucket.append(g, b);
            try x.e_holder.append(g, hi);
            try x.e_key.append(g, try x.nextUse(ev, hi));
            try x.e_at.append(g, none);
            try x.heapPush(ev, e);
        }
        const hh = &x.holders.items[hi];
        hh.len = @intCast(x.e_bucket.items.len - hh.start);
        hh.state = .keyed;
        if (unknown) return;
        for (holds) |hd| if (hd.agg) {
            x.aggLink(hi, 0);
            break;
        };
    }

    /// The holds of keyed holder `hi`.
    pub fn holdsOf(x: *Live, hi: u32) []Hold {
        const h = x.holders.items[hi];
        return x.holds.items[h.h_start..][0..h.h_len];
    }

    /// Holder `hi`'s first use after the sweep's point (`top_key` if none).
    fn nextUse(x: *Live, ev: *Relation.Eval, hi: u32) Error!u32 {
        const h = &x.holders.items[hi];
        const us = x.uses.items[h.u_start..][0..h.u_len];
        while (h.cur < us.len and us[h.cur] <= x.now) : (h.cur += 1) try ev.f.charge(.inspection, 1);
        return if (h.cur < us.len) us[h.cur] else top_key;
    }

    // ---- the buckets' heaps --------------------------------------------------
    // A sift is charged a record and one a swap: its work.

    fn less(x: *const Live, a: u32, b: u32) bool {
        const ka = x.e_key.items[a];
        const kb = x.e_key.items[b];
        return ka < kb or (ka == kb and a < b);
    }

    fn heapPush(x: *Live, ev: *Relation.Eval, e: u32) Error!void {
        const h = &x.heap.items[x.e_bucket.items[e]];
        try h.append(ev.gpa(), e);
        x.e_at.items[e] = @intCast(h.items.len - 1);
        try ev.f.charge(.inspection, 1 + x.siftUp(h.items, @intCast(h.items.len - 1)));
    }

    fn heapRemove(x: *Live, ev: *Relation.Eval, e: u32) Error!void {
        const at = x.e_at.items[e];
        if (at == none) return;
        const h = &x.heap.items[x.e_bucket.items[e]];
        x.e_at.items[e] = none;
        const last = h.pop().?;
        if (last == e) return try ev.f.charge(.inspection, 1);
        h.items[at] = last;
        x.e_at.items[last] = at;
        const up = x.siftUp(h.items, at);
        try ev.f.charge(.inspection, 1 + up + x.siftDown(h.items, x.e_at.items[last]));
    }

    fn siftUp(x: *Live, h: []u32, at0: u32) u32 {
        var at = at0;
        var n: u32 = 0;
        while (at > 0) : (n += 1) {
            const up = (at - 1) / 2;
            if (!x.less(h[at], h[up])) break;
            std.mem.swap(u32, &h[at], &h[up]);
            x.e_at.items[h[at]] = at;
            x.e_at.items[h[up]] = up;
            at = up;
        }
        return n;
    }

    fn siftDown(x: *Live, h: []u32, at0: u32) u32 {
        var at = at0;
        var n: u32 = 0;
        while (true) : (n += 1) {
            var m = at;
            for ([_]u32{ 2 * at + 1, 2 * at + 2 }) |c| if (c < h.len and x.less(h[c], h[m])) {
                m = c;
            };
            if (m == at) break;
            std.mem.swap(u32, &h[at], &h[m]);
            x.e_at.items[h[at]] = at;
            x.e_at.items[h[m]] = m;
            at = m;
        }
        return n;
    }

    /// Bring bucket `b`'s least entry's key past the sweep's point (its
    /// holder's next use): whether the heap has one.
    fn refresh(x: *Live, ev: *Relation.Eval, b: u32) Error!bool {
        const h = &x.heap.items[b];
        while (h.items.len != 0) {
            const e = h.items[0];
            if (x.e_key.items[e] > x.now) return true;
            x.e_key.items[e] = try x.nextUse(ev, x.e_holder.items[e]);
            try ev.f.charge(.inspection, 1 + x.siftDown(h.items, 0));
        }
        return false;
    }

    // ---- a query: buckets' holders in use order ------------------------------
    // The buckets' heaps are read, never changed: a frontier of heap slots
    // by key, a slot's children entering when it leaves. A slot's stored key
    // bounds its subtree's from below; a stale one (at or before the sweep's
    // point) enters again at its holder's next use, its children with it.

    const Slot = struct { key: u32, b: u32, at: u32, open: bool };

    fn slotLess(a: Slot, b: Slot) bool {
        if (a.key != b.key) return a.key < b.key;
        if (a.b != b.b) return a.b < b.b;
        return a.at < b.at;
    }

    fn frontierPush(x: *Live, ev: *Relation.Eval, s: Slot) Error!void {
        const f = &x.frontier;
        try f.append(ev.gpa(), s);
        var at = f.items.len - 1;
        var n: u32 = 0;
        while (at > 0 and slotLess(f.items[at], f.items[(at - 1) / 2])) : (n += 1) {
            std.mem.swap(Slot, &f.items[at], &f.items[(at - 1) / 2]);
            at = (at - 1) / 2;
        }
        try ev.f.charge(.inspection, 1 + n);
    }

    fn frontierPop(x: *Live, ev: *Relation.Eval) Error!Slot {
        const f = &x.frontier;
        const top = f.items[0];
        const last = f.pop().?;
        var n: u32 = 0;
        if (f.items.len != 0) {
            f.items[0] = last;
            var at: usize = 0;
            while (true) : (n += 1) {
                var m = at;
                for ([_]usize{ 2 * at + 1, 2 * at + 2 }) |c| if (c < f.items.len and slotLess(f.items[c], f.items[m])) {
                    m = c;
                };
                if (m == at) break;
                std.mem.swap(Slot, &f.items[at], &f.items[m]);
                at = m;
            }
        }
        try ev.f.charge(.inspection, 1 + n);
        return top;
    }

    fn openChildren(x: *Live, ev: *Relation.Eval, b: u32, at: u32) Error!void {
        const h = x.heap.items[b].items;
        for ([_]u32{ 2 * at + 1, 2 * at + 2 }) |c| if (c < h.len) try x.frontierPush(ev, .{ .key = x.e_key.items[h[c]], .b = b, .at = c, .open = false });
    }

    /// Start a query over buckets `bs` (a bucket named twice counts once).
    pub fn begin(x: *Live, ev: *Relation.Eval, bs: []const u32) Error!void {
        x.query += 1;
        x.frontier.clearRetainingCapacity();
        for (bs) |b| {
            try ev.f.charge(.inspection, 1);
            if (x.b_mark.items[b] == x.query) continue;
            x.b_mark.items[b] = x.query;
            if (!try x.refresh(ev, b)) continue;
            try x.frontierPush(ev, .{ .key = x.e_key.items[x.heap.items[b].items[0]], .b = b, .at = 0, .open = false });
        }
    }

    /// The next holder of the query's buckets in order of next use, each
    /// once, while its next use is at most `bound`: no later holder can be
    /// used first (§2.8, *Verdicts*).
    pub fn next(x: *Live, ev: *Relation.Eval, bound: u32) Error!?u32 {
        while (x.frontier.items.len != 0) {
            if (x.frontier.items[0].key > bound) return null;
            const s = try x.frontierPop(ev);
            const e = x.heap.items[s.b].items[s.at];
            if (!s.open) {
                try x.openChildren(ev, s.b, s.at);
                if (x.e_key.items[e] <= x.now) {
                    try x.frontierPush(ev, .{ .key = try x.nextUse(ev, x.e_holder.items[e]), .b = s.b, .at = s.at, .open = true });
                    continue;
                }
            }
            const hi = x.e_holder.items[e];
            if (x.mark.items[hi] == x.query) continue;
            x.mark.items[hi] = x.query;
            return hi;
        }
        return null;
    }

    /// Whether the current query visited holder `hi`.
    pub fn visited(x: *const Live, hi: u32) bool {
        return x.mark.items[hi] == x.query;
    }

    /// Every bucket into `out`: the unknown one, and the parameters'.
    pub fn allParams(x: *const Live, ev: *Relation.Eval, out: *std.ArrayList(u32)) Error!void {
        try ev.f.charge(.inspection, 1);
        try out.appendSlice(ev.gpa(), x.params.items);
    }

    /// The bucket of key `k`, if any holder was keyed under it.
    pub fn bucketFor(x: *const Live, k: Key) ?u32 {
        return x.bucket.get(k);
    }

    pub fn unknownBucket(x: *const Live) ?u32 {
        return if (x.unknown_bucket == none) null else x.unknown_bucket;
    }

    /// The parameters' buckets at positions related to `p` (§2.3.2): at `p`
    /// or below it, at an ancestor, or below a list step of an ancestor
    /// that may name what `p`'s does. Every other parameter bucket's
    /// positions are apart from `p`'s.
    pub fn related(x: *const Live, ev: *Relation.Eval, p: u32, out: *std.ArrayList(u32)) Error!void {
        const g = ev.gpa();
        const pos = ev.f.pos.items;
        for (0..5) |w| {
            try ev.f.charge(.inspection, 1);
            try out.appendSlice(g, x.regList(p, @intCast(w)));
        }
        var c = p;
        while (pos[c].parent != none) : (c = pos[c].parent) {
            const a = pos[c].parent;
            try ev.f.charge(.inspection, 1);
            try out.appendSlice(g, x.regList(a, 0));
            const kinds: []const Value.PKind = switch (pos[c].kind) {
                .plain => &.{},
                .front => &.{ .back, .slice },
                .back => &.{ .front, .slice },
                .slice => &.{ .front, .back, .slice },
            };
            for (kinds) |k| {
                try ev.f.charge(.inspection, 1);
                try out.appendSlice(g, x.regList(a, 1 + @as(u32, @backingInt(k))));
            }
        }
        try ev.f.charge(.inspection, @intCast(out.items.len));
    }

    // ---- the aggregated holders ----------------------------------------------

    fn aggLink(x: *Live, hi: u32, list: u32) void {
        const h = &x.holders.items[hi];
        h.agg = list;
        x.a_prev.items[hi] = none;
        x.a_next.items[hi] = x.agg_head[list];
        if (x.agg_head[list] != none) x.a_prev.items[x.agg_head[list]] = hi;
        x.agg_head[list] = hi;
    }

    fn aggUnlink(x: *Live, hi: u32) void {
        const list = x.holders.items[hi].agg;
        const nx = x.a_next.items[hi];
        const pv = x.a_prev.items[hi];
        if (pv != none) x.a_next.items[pv] = nx else x.agg_head[list] = nx;
        if (nx != none) x.a_prev.items[nx] = pv;
        x.holders.items[hi].agg = none;
    }

    /// The first holder of aggregated list `list` (0 pending, 1 done).
    pub fn aggFirst(x: *const Live, list: u32) ?u32 {
        const h = x.agg_head[list];
        return if (h == none) null else h;
    }

    pub fn aggNext(x: *const Live, hi: u32) ?u32 {
        const h = x.a_next.items[hi];
        return if (h == none) null else h;
    }

    /// Move pending holder `hi` to the done list: every hold of it that can
    /// only add an apart selection has added it.
    pub fn aggDone(x: *Live, hi: u32) void {
        if (x.holders.items[hi].agg != 0) return;
        x.aggUnlink(hi);
        x.aggLink(hi, 1);
    }
};
