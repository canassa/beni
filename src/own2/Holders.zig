//! L8: what resolution reads of a frame's leaves, built once per
//! resolution (`docs/design/ownership-v2.md` §2.8): each leaf's base keys
//! (*Base keys*), the escape index (*The escape index*) and the operand
//! index (*Operands*). The holder
//! index is `Sweep`'s.
//!
//! Obligations kept here: O2's resolution half reads the escapes through
//! the index, every escape a target can meet visited (none skipped).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Relation = @import("Relation.zig");
const Distinct = @import("Distinct.zig");
const Routed = @import("Routed.zig");
const Contract = @import("Contract.zig");
const Walk = @import("Walk.zig");
const Regions = @import("Regions.zig");
const Value = @import("Value.zig");
const Place = @import("Place.zig");
const KeySets = @import("KeySets.zig");

pub const Error = Ids.ChargeError;
const Cond = Contract.Cond;
const none: u32 = Ids.none_int;

/// A base key: `(kind, root or atom, extra)`; kind 0 a parameter (`extra`
/// its base leaf's position, §2.8 *Holder entries*), 1 a site, 2 a
/// call's fresh atom, 3 a shared value. Unknown is a flag.
pub const Key = [3]u32;

/// What a leaf comes from, in a word: whether it reaches unknown objects
/// or a parameter's, and the least shared value it reaches (`none`).
/// `host`: a host object (§2.10, *host objects*): it has no base key, so it
/// holds no target, and a target that may be one is refused `escaped`.
pub const Facts = struct {
    unknown: bool = false,
    param: bool = false,
    host: bool = false,
    shared: [2]u32 = .{ none, none },

    pub fn join(a: *Facts, b: Facts) void {
        a.* = .{ .unknown = a.unknown or b.unknown, .param = a.param or b.param, .host = a.host or b.host, .shared = leastShared(a.shared, b.shared) };
    }
};

/// Conditions gathered (§2.9.4): each met condition's occurrences appended,
/// made one selection at the end by one sort, never merged one by one.
pub const Gather = struct {
    no: bool = false,
    occ: std.ArrayList(u64) = .empty,
    /// The shared runs added already (`addBoth`), by their address.
    shared: std.AutoHashMapUnmanaged([2]usize, void) = .empty,

    pub fn deinit(x: *Gather, gpa: Allocator) void {
        inline for (.{ &x.occ, &x.shared }) |l| l.deinit(gpa);
    }

    /// Add `shared` (one run several judgements hold) once, then `own`.
    pub fn addBoth(x: *Gather, gpa: Allocator, account: *Ids.Account, shared: Cond, own: Cond) Error!void {
        try account.reserve(.cond, 1);
        if (shared.no or shared.sel.len == 0 or !(try x.shared.getOrPut(gpa, .{ @intFromPtr(shared.sel.ptr), shared.sel.len })).found_existing) try x.add(gpa, account, shared);
        try x.add(gpa, account, own);
    }

    pub fn add(x: *Gather, gpa: Allocator, account: *Ids.Account, c: Cond) Error!void {
        if (c.no) x.no = true;
        if (x.no or c.sel.len == 0) return;
        try account.reserve(.cond, @intCast(c.sel.len));
        try x.occ.appendSlice(gpa, c.sel);
    }

    /// The selection gathered, in `arena`.
    pub fn cond(x: *const Gather, arena: Allocator, account: *Ids.Account) Error!Cond {
        if (x.no) return Cond.unprovable;
        if (x.occ.items.len == 0) return Cond.yes;
        return Cond.of(account, try arena.dupe(u64, x.occ.items));
    }
};

/// Each leaf's base keys (§2.8, *Base keys*), two columns by leaf id: its
/// `Facts`, made for every leaf a demand targets, and its keys, made only
/// for a target or a holder that a demand meets live. Each made by one
/// post-order walk over the expansions, strongly connected leaves sharing
/// one entry, so each leaf is expanded once a column. A leaf's keys are a
/// run of `items` (sorted, once each) while they are at most `flat_max`
/// and come from runs only; past that they are a set of `sets`, which
/// shares its kids' sets and is listed only when asked for, so a chain of
/// k leaves each over the one before costs k sets, not Σk items.
pub const Keys = struct {
    facts: std.ArrayList(?Facts) = .empty,
    /// Per leaf: `items` run start and length, or `(shared, set)`; `none`
    /// while not made.
    run: std.ArrayList([2]u32) = .empty,
    items: std.ArrayList(Key) = .empty,
    sets: KeySets.Table = .{},

    pub const Mode = enum { facts, runs };
    /// A run's first word when its keys are a set of `sets`.
    const shared: u32 = none - 1;
    /// The most keys a run copies from its kids' (§2.8, *Base keys*).
    pub const flat_max: u32 = 32;

    pub fn deinit(k: *Keys, gpa: Allocator) void {
        k.facts.deinit(gpa);
        k.run.deinit(gpa);
        k.items.deinit(gpa);
        k.sets.deinit(gpa);
    }

    fn made(k: *const Keys, li: u32, mode: Mode) bool {
        return switch (mode) {
            .facts => li < k.facts.items.len and k.facts.items[li] != null,
            .runs => li < k.run.items.len and k.run.items[li][0] != none,
        };
    }

    /// Leaf `li`'s facts, made first if they are not.
    pub fn factsOf(k: *Keys, ev: *Relation.Eval, li: u32) Error!Facts {
        if (!k.made(li, .facts)) try k.make(ev, li, .facts);
        return k.facts.items[li].?;
    }

    /// Leaf `li`'s keys, made first if they are not.
    pub fn of(k: *Keys, ev: *Relation.Eval, li: u32) Error!struct { keys: []const Key, unknown: bool } {
        if (!k.made(li, .runs)) try k.make(ev, li, .runs);
        const r = k.run.items[li];
        const unknown = k.facts.items[li].?.unknown;
        if (r[0] == shared) return .{ .keys = try k.sets.keys(ev.gpa(), ev.account(), r[1]), .unknown = unknown };
        return .{ .keys = k.items.items[r[0]..][0..r[1]], .unknown = unknown };
    }

    fn grow(k: *Keys, gpa: Allocator, n: usize) Allocator.Error!void {
        if (n > k.run.items.len) try k.run.appendNTimes(gpa, .{ none, 0 }, n - k.run.items.len);
        if (n > k.facts.items.len) try k.facts.appendNTimes(gpa, null, n - k.facts.items.len);
    }

    /// Tarjan's walk from `li0` over the expansions, on explicit stacks:
    /// each leaf expanded once, a component's members given one entry.
    fn make(k: *Keys, ev: *Relation.Eval, li0: u32, mode: Mode) Error!void {
        const g = ev.gpa();
        var w: Walker = .{};
        defer w.deinit(g);
        try w.open(k, ev, li0);
        while (w.frames.items.len != 0) {
            const top = &w.frames.items[w.frames.items.len - 1];
            const span = w.span.items[top.at];
            if (top.next < span[1]) {
                const c = w.kids.items[top.next];
                top.next += 1;
                if (k.made(c, mode)) continue;
                if (w.slot(c)) |ci| {
                    // Met in this walk and not closed: on the stack.
                    w.low.items[top.at] = @min(w.low.items[top.at], ci);
                    continue;
                }
                try w.open(k, ev, c);
                continue;
            }
            const me = w.frames.pop().?.at;
            if (w.frames.items.len != 0) {
                const up = w.frames.items[w.frames.items.len - 1].at;
                w.low.items[up] = @min(w.low.items[up], w.low.items[me]);
            }
            if (w.low.items[me] != me) continue;
            // `me` roots a component: the walk's entries from it on that
            // are not closed yet.
            try k.close(ev, &w, me, mode);
        }
    }

    /// Give every member of the component rooted at walk entry `root` one
    /// run: the members' own keys and the runs of their kids outside it.
    fn close(k: *Keys, ev: *Relation.Eval, w: *Walker, root: u32, mode: Mode) Error!void {
        const g = ev.gpa();
        const f = ev.f;
        var acc: std.ArrayList(Key) = .empty;
        defer acc.deinit(g);
        // The kids' keys that are sets, united as sets.
        var big: std.ArrayList(u32) = .empty;
        defer big.deinit(g);
        var fx: Facts = .{};
        var members: std.ArrayList(u32) = .empty;
        defer members.deinit(g);
        while (w.stack.items.len != 0) {
            const at = w.stack.items[w.stack.items.len - 1];
            if (at < root) break;
            _ = w.stack.pop();
            try members.append(g, at);
        }
        for (members.items) |at| {
            const m = w.leaf.items[at];
            const l = f.leafAt(m);
            switch (l.kind) {
                .ref => switch (f.roots.items[l.root].kind) {
                    .param => {
                        fx.param = true;
                        if (mode == .runs) try acc.append(g, .{ 0, f.roots.items[l.root].a, l.pos });
                    },
                    .cb => fx.unknown = true,
                    .call, .supply => {},
                },
                .site => if (mode == .runs) try acc.append(g, .{ 1, l.atom, 0 }),
                .fresh => if (mode == .runs) try acc.append(g, .{ 2, l.atom, 0 }),
                .shared => {
                    fx.shared = leastShared(fx.shared, .{ l.atom, l.extra });
                    if (mode == .runs) try acc.append(g, .{ 3, l.atom, l.extra });
                },
                .answer, .top, .loan => fx.unknown = true,
                .host => fx.host = true,
                .recons => unreachable,
            }
            const span = w.span.items[at];
            for (w.kids.items[span[0]..span[1]]) |c| {
                if (k.made(c, .facts)) {
                    fx.join(k.facts.items[c].?);
                }
                if (mode == .runs and k.made(c, .runs)) {
                    const r = k.run.items[c];
                    if (r[0] == shared) try big.append(g, r[1]) else try acc.appendSlice(g, k.items.items[r[0]..][0..r[1]]);
                }
            }
        }
        try k.grow(g, f.leaves.items.len);
        if (mode == .facts) {
            try f.charge(.inspection, @intCast(members.items.len));
            for (members.items) |at| {
                k.facts.items[w.leaf.items[at]] = fx;
                w.closed.items[at] = true;
            }
            return;
        }
        std.mem.sort(Key, acc.items, {}, struct {
            fn lt(_: void, a: Key, b: Key) bool {
                return std.mem.order(u32, &a, &b) == .lt;
            }
        }.lt);
        var n: usize = 0;
        for (acc.items) |x| {
            if (n != 0 and std.mem.eql(u32, &acc.items[n - 1], &x)) continue;
            acc.items[n] = x;
            n += 1;
        }
        acc.shrinkRetainingCapacity(n);
        try f.charge(.edge, @max(1, @as(u32, @intCast(n))));
        var run: [2]u32 = .{ @intCast(k.items.items.len), @intCast(n) };
        if (big.items.len == 0 and n <= flat_max) {
            try k.items.appendSlice(g, acc.items);
        } else {
            const a = ev.account();
            var s: u32 = KeySets.empty;
            for (acc.items) |x| s = try k.sets.unite(g, a, s, try k.sets.one(g, a, x));
            for (big.items) |b| s = try k.sets.unite(g, a, s, b);
            run = .{ shared, s };
        }
        for (members.items) |at| {
            const m = w.leaf.items[at];
            k.run.items[m] = run;
            k.facts.items[m] = fx;
            w.closed.items[at] = true;
        }
    }
};

/// The lesser of two shared values by `(module, declaration)`, `none` the
/// greatest: the one a refusal names, whatever the order it was met in.
fn leastShared(a: [2]u32, b: [2]u32) [2]u32 {
    return if (std.mem.order(u32, &b, &a) == .lt) b else a;
}

/// One walk of `Keys.make`: entries numbered in opening order, each with
/// its leaf, its low link, its kids' span of `kids` and whether its
/// component is closed; Tarjan's stack of entries; the frames.
const Walker = struct {
    leaf: std.ArrayList(u32) = .empty,
    low: std.ArrayList(u32) = .empty,
    span: std.ArrayList([2]u32) = .empty,
    closed: std.ArrayList(bool) = .empty,
    kids: std.ArrayList(u32) = .empty,
    stack: std.ArrayList(u32) = .empty,
    frames: std.ArrayList(struct { at: u32, next: u32 }) = .empty,
    /// Per leaf met: its entry (`none` when not met), by leaf id.
    entry: std.ArrayList(u32) = .empty,

    fn deinit(w: *Walker, g: Allocator) void {
        inline for (.{ &w.leaf, &w.low, &w.kids, &w.stack, &w.entry }) |l| l.deinit(g);
        w.span.deinit(g);
        w.closed.deinit(g);
        w.frames.deinit(g);
    }

    /// Leaf `c`'s entry when it was met and is not closed.
    fn slot(w: *const Walker, c: u32) ?u32 {
        if (c >= w.entry.items.len) return null;
        const at = w.entry.items[c];
        if (at == none or w.closed.items[at]) return null;
        return at;
    }

    fn open(w: *Walker, k: *Keys, e: *Relation.Eval, li: u32) Error!void {
        const g = e.gpa();
        try e.f.charge(.inspection, 1);
        const at: u32 = @intCast(w.leaf.items.len);
        if (li >= w.entry.items.len) try w.entry.appendNTimes(g, none, li + 1 - w.entry.items.len);
        w.entry.items[li] = at;
        try w.leaf.append(g, li);
        try w.low.append(g, at);
        try w.closed.append(g, false);
        try w.stack.append(g, at);
        const start: u32 = @intCast(w.kids.items.len);
        const l = e.f.leafAt(li);
        // Each kid once under its route set (§2.3.5, *a key's leaf*): a key is not a route.
        if (l.kind == .ref and e.expandable(l)) try e.expandRouted(li, &w.kids);
        try w.span.append(g, .{ start, @intCast(w.kids.items.len) });
        try k.grow(g, e.f.leaves.items.len);
        try w.frames.append(g, .{ .at = at, .next = start });
    }
};

/// The escape index (§2.8, *The escape index*): the escapes by their
/// leaves' base keys, a bucket each (`unknown_bucket` for those that reach
/// unknown objects), each bucket a run of `items` sorted by point with a
/// tree of the least rank₂ over it in `tree`.
pub const Escapes = struct {
    bucket: Ids.FixedDict(3) = .{},
    unknown_bucket: u32 = none,
    runs: std.ArrayList(Run) = .empty,
    /// The parameters' buckets, which a parameter's target meets.
    params: std.ArrayList(u32) = .empty,
    items: std.ArrayList(u32) = .empty,
    tree: std.ArrayList(u32) = .empty,
    /// Per escape, the query that last judged it: an escape in several
    /// buckets is judged once a query.
    mark: std.ArrayList(u32) = .empty,
    query: u32 = 0,

    const Run = struct { start: u32, len: u32, tree: u32, cap: u32 };

    pub fn deinit(x: *Escapes, g: Allocator) void {
        x.bucket.deinit(g);
        x.runs.deinit(g);
        x.params.deinit(g);
        x.items.deinit(g);
        x.tree.deinit(g);
        x.mark.deinit(g);
    }

    /// Index `escs`: each escape under its leaf's base keys.
    pub fn build(x: *Escapes, ev: *Relation.Eval, keys: *Keys, regions: *const Regions.Tree, escs: []const Walk.Escape) Error!void {
        const g = ev.gpa();
        if (escs.len == 0) return;
        var members: std.ArrayList(std.ArrayList(u32)) = .empty;
        defer {
            for (members.items) |*m| m.deinit(g);
            members.deinit(g);
        }
        for (escs, 0..) |e, i| {
            const ks = try keys.of(ev, e.leaf);
            const unknown_key: [1]Key = .{.{ 4, 0, 0 }};
            for ([_][]const Key{ ks.keys, if (ks.unknown) &unknown_key else &.{} }) |part| for (part) |k0| {
                // A parameter's bucket is the parameter's, whatever the position.
                const k: Key = if (k0[0] == 0) .{ 0, k0[1], 0 } else k0;
                try ev.f.charge(.edge, 1);
                const got = try x.bucket.getOrPut(g, k);
                if (!got.found_existing) {
                    got.value_ptr.* = @intCast(members.items.len);
                    try members.append(g, .empty);
                    if (k[0] == 0) try x.params.append(g, got.value_ptr.*);
                    if (k[0] == 4) x.unknown_bucket = got.value_ptr.*;
                }
                const m = &members.items[got.value_ptr.*];
                if (m.items.len == 0 or m.items[m.items.len - 1] != i) try m.append(g, @intCast(i));
            };
        }
        try x.mark.appendNTimes(g, 0, escs.len);
        for (members.items) |m| {
            // By point: a call's own escapes are recorded after its operands'.
            std.mem.sort(u32, m.items, escs, struct {
                fn lt(es: []const Walk.Escape, a: u32, b: u32) bool {
                    return es[a].point < es[b].point or (es[a].point == es[b].point and a < b);
                }
            }.lt);
            const n: u32 = @intCast(m.items.len);
            try ev.f.charge(.inspection, n * (std.math.log2_int_ceil(u32, n + 1) + 1));
            const cap = std.math.ceilPowerOfTwo(u32, n) catch unreachable;
            const at: u32 = @intCast(x.tree.items.len);
            try x.tree.appendNTimes(g, std.math.maxInt(u32), 2 * cap);
            const t = x.tree.items[at..][0 .. 2 * cap];
            for (m.items, 0..) |ei, k| t[cap + k] = regions.rank2(escs[ei].point);
            var k = cap - 1;
            while (k > 0) : (k -= 1) t[k] = @min(t[2 * k], t[2 * k + 1]);
            try x.runs.append(g, .{ .start = @intCast(x.items.items.len), .len = n, .tree = at, .cap = cap });
            try x.items.appendSlice(g, m.items);
        }
    }

    /// Whether an escape at `point` or before it, compatibly, reaches
    /// target `t` (`may`); an `under` adds to `relied`. The buckets the
    /// target's keys meet only (§2.8, *The escape index*).
    pub fn escaped(x: *Escapes, ev: *Relation.Eval, keys: *Keys, regions: *const Regions.Tree, escs: []const Walk.Escape, t: u32, point: u32, call: u32, relied: *Gather) Error!bool {
        if (x.runs.items.len == 0) return false;
        const ks = try keys.of(ev, t);
        x.query += 1;
        const q: Query = .{ .x = x, .ev = ev, .regions = regions, .escs = escs, .t = t, .point = point, .call = call, .relied = relied };
        if (x.unknown_bucket != none) if (try q.in(x.unknown_bucket)) return true;
        if (ks.unknown) {
            for (0..x.runs.items.len) |b| if (try q.in(@intCast(b))) return true;
            return false;
        }
        var params = false;
        for (ks.keys) |k| {
            if (k[0] == 0) {
                params = true;
                continue;
            }
            if (x.bucket.get(k)) |b| if (try q.in(b)) return true;
        }
        if (params) for (x.params.items) |b| if (try q.in(b)) return true;
        return false;
    }

    const Query = struct {
        x: *Escapes,
        ev: *Relation.Eval,
        regions: *const Regions.Tree,
        escs: []const Walk.Escape,
        t: u32,
        point: u32,
        call: u32,
        relied: *Gather,

        /// Bucket `b`'s escapes at the point, and those before it whose
        /// rank₂ is below its own (§2.5), by descending the tree only into
        /// subtrees whose least rank₂ is. Each step charged before it.
        fn in(q: Query, b: u32) Error!bool {
            const g = q.ev.gpa();
            const run = q.x.runs.items[b];
            const items = q.x.items.items[run.start..][0..run.len];
            try q.ev.f.charge(.inspection, std.math.log2_int_ceil(u32, run.len + 1) + 1);
            const Ctx = struct { escs: []const Walk.Escape, p: u32 };
            const c: Ctx = .{ .escs = q.escs, .p = q.point };
            const end = std.sort.partitionPoint(u32, items, c, struct {
                fn f(k: Ctx, ei: u32) bool {
                    return k.escs[ei].point <= k.p;
                }
            }.f);
            const before = std.sort.partitionPoint(u32, items[0..end], c, struct {
                fn f(k: Ctx, ei: u32) bool {
                    return k.escs[ei].point < k.p;
                }
            }.f);
            for (items[before..end]) |ei| if (try q.judge(ei)) return true;
            if (before == 0) return false;
            const rank = q.regions.rank2(q.point);
            const tree = q.x.tree.items[run.tree..][0 .. 2 * run.cap];
            var stack: std.ArrayList([3]u32) = .empty;
            defer stack.deinit(g);
            try stack.append(g, .{ 1, 0, run.cap });
            while (stack.pop()) |nd| {
                const k, const lo, const hi = nd;
                if (lo >= before) continue;
                try q.ev.f.charge(.inspection, 1);
                if (tree[k] >= rank) continue;
                if (k >= run.cap) {
                    if (try q.judge(items[k - run.cap])) return true;
                    continue;
                }
                const mid = lo + (hi - lo) / 2;
                try stack.append(g, .{ 2 * k + 1, mid, hi });
                try stack.append(g, .{ 2 * k, lo, mid });
            }
            return false;
        }

        fn judge(q: Query, ei: u32) Error!bool {
            if (q.x.mark.items[ei] == q.x.query) return false;
            q.x.mark.items[ei] = q.x.query;
            const e = q.escs[ei];
            // What a callee keeps of the value its own write takes (`Ref.set`
            // storing what it consumes) is that write's own business.
            if (q.call != none and e.call == q.call) return false;
            const o = try Distinct.overlap(q.ev, e.leaf, q.t, false);
            switch (o.kind) {
                .no => {},
                .under => try q.relied.add(q.ev.gpa(), q.ev.account(), o.cond),
                .may => return true,
            }
            return false;
        }
    };
};

/// Whether `l` is a parameter's untagged target, not a cell's `◆` (§2.8,
/// *Holder entries judged by base leaves*, step 2).
pub fn paramTarget(f: *const Value.Frame, l: Value.Leaf) bool {
    if (l.kind != .ref or l.tags != 0 or l.routes != 0 or f.roots.items[l.root].kind != .param) return false;
    if (l.at_pos) {
        const tp = f.pos.items[l.pos];
        if (tp.kind == .plain and Place.Step.fromWord(tp.a).kind == .contents) return false;
    }
    return true;
}

/// A call's operands by their base keys (§2.8 step 4, #1714): its
/// arguments' leaves, made once a resolution. A leaf whose keys are
/// parameters' only is *aggregated*: against a parameter's untagged target
/// at a position its keys are not related to, it answers no or `under` an
/// apart selection of its own and the target's (*the factorisation*). So a
/// write of argument `j` judges only the other arguments' other leaves and
/// those of its target's parameter at related positions; the target's
/// selection joins when an aggregated leaf answers `under`, and each
/// aggregated leaf's own once a resolution (`finish`), at a write of
/// another argument that was accepted.
pub const Operands = struct {
    /// Per call: its run of `calls`, `none` while not made.
    at: std.ArrayList(u32) = .empty,
    calls: std.ArrayList(Run) = .empty,
    items: std.ArrayList(Item) = .empty,
    /// Per call, `(parameter, position, item)` of its aggregated items'
    /// parameter keys, sorted; and its other items.
    keyed: std.ArrayList([3]u32) = .empty,
    plain: std.ArrayList(u32) = .empty,
    /// The accepted writes judged with aggregation: `(call, argument, target)`.
    writes: std.ArrayList([3]u32) = .empty,
    mark: std.ArrayList(u32) = .empty,
    query: u32 = 0,

    const Run = struct { items: [2]u32, keyed: [2]u32, plain: [2]u32 };
    pub const Item = struct { leaf: u32, arg: u32, agg: bool };

    pub fn deinit(x: *Operands, g: Allocator) void {
        inline for (.{ &x.at, &x.plain, &x.mark }) |l| l.deinit(g);
        x.calls.deinit(g);
        x.items.deinit(g);
        x.keyed.deinit(g);
        x.writes.deinit(g);
    }

    fn make(x: *Operands, ev: *Relation.Eval, keys: *Keys, call: u32) Error!Run {
        const g = ev.gpa();
        if (call >= x.at.items.len) try x.at.appendNTimes(g, none, call + 1 - x.at.items.len);
        if (x.at.items[call] != none) return x.calls.items[x.at.items[call]];
        var run: Run = .{ .items = .{ @intCast(x.items.items.len), 0 }, .keyed = .{ @intCast(x.keyed.items.len), 0 }, .plain = .{ @intCast(x.plain.items.len), 0 } };
        var ls: std.ArrayList(u32) = .empty;
        defer ls.deinit(g);
        for (ev.f.calls.items[call].args, 0..) |a, k| {
            ls.clearRetainingCapacity();
            try Routed.leavesOf(ev, a, &ls);
            for (ls.items) |l| {
                try ev.f.charge(.inspection, 1);
                const ks = try keys.of(ev, l);
                const i: u32 = @intCast(x.items.items.len);
                try x.items.append(g, .{ .leaf = l, .arg = @intCast(k), .agg = !ks.unknown });
                try x.mark.append(g, 0);
                if (ks.unknown) try x.plain.append(g, i) else for (ks.keys) |kk| if (kk[0] == 0) try x.keyed.append(g, .{ kk[1], kk[2], i });
            }
        }
        run.items[1] = @as(u32, @intCast(x.items.items.len)) - run.items[0];
        run.keyed[1] = @as(u32, @intCast(x.keyed.items.len)) - run.keyed[0];
        run.plain[1] = @as(u32, @intCast(x.plain.items.len)) - run.plain[0];
        const kd = x.keyed.items[run.keyed[0]..][0..run.keyed[1]];
        try ev.f.charge(.inspection, @intCast(1 + kd.len));
        std.mem.sort([3]u32, kd, {}, struct {
            fn lt(_: void, a: [3]u32, b: [3]u32) bool {
                return std.mem.order(u32, &a, &b) == .lt;
            }
        }.lt);
        x.at.items[call] = @intCast(x.calls.items.len);
        try x.calls.append(g, run);
        return run;
    }

    /// Call `call`'s operand leaves a write of argument `j` judges against
    /// target `t` one by one (`out`, leaf ids); true when `t` is a
    /// parameter's untagged target and the others are aggregated (`T(t)`
    /// then joins `relied` through one that answers `under`).
    pub fn judged(x: *Operands, ev: *Relation.Eval, keys: *Keys, call: u32, j: u32, t: u32, relied: *Gather, out: *std.ArrayList(u32)) Error!bool {
        const g = ev.gpa();
        const f = ev.f;
        const run = try x.make(ev, keys, call);
        const items = x.items.items[run.items[0]..][0..run.items[1]];
        const tl = f.leafAt(t);
        if (!paramTarget(f, tl)) {
            for (items) |it| if (it.arg != j) try out.append(g, it.leaf);
            return false;
        }
        x.query += 1;
        for (x.plain.items[run.plain[0]..][0..run.plain[1]]) |i| if (x.items.items[i].arg != j) {
            x.mark.items[i] = x.query;
            try out.append(g, x.items.items[i].leaf);
        };
        const a = f.roots.items[tl.root].a;
        const kd = x.keyed.items[run.keyed[0]..][0..run.keyed[1]];
        try ev.f.charge(.inspection, std.math.log2_int_ceil(u32, @intCast(kd.len + 1)) + 1);
        var at = std.sort.partitionPoint([3]u32, kd, a, struct {
            fn below(p: u32, e: [3]u32) bool {
                return e[0] < p;
            }
        }.below);
        while (at < kd.len and kd[at][0] == a) : (at += 1) {
            const i = kd[at][2];
            if (x.mark.items[i] == x.query or x.items.items[i].arg == j) continue;
            if ((try f.related(kd[at][1], tl.pos)).rel != .related) continue;
            x.mark.items[i] = x.query;
            try out.append(g, x.items.items[i].leaf);
        }
        // `T(t)`: the first aggregated leaf that answers `under`.
        for (run.items[0]..run.items[0] + run.items[1]) |i| {
            const it = x.items.items[i];
            if (it.arg == j or x.mark.items[i] == x.query) continue;
            try ev.f.charge(.inspection, 1);
            const o = try Distinct.overlap(ev, it.leaf, t, true);
            if (o.kind == .under) {
                try relied.add(g, ev.account(), o.cond);
                break;
            }
        }
        return true;
    }

    /// Each aggregated leaf's own selection, into `req`: through a write of
    /// another argument of its call that was accepted with aggregation and
    /// for whose target it was aggregated and answers `under`.
    pub fn finish(x: *Operands, ev: *Relation.Eval, keys: *Keys, req: *Gather, arena: Allocator) Error!void {
        const f = ev.f;
        std.mem.sort([3]u32, x.writes.items, {}, struct {
            fn lt(_: void, a: [3]u32, b: [3]u32) bool {
                return std.mem.order(u32, &a, &b) == .lt;
            }
        }.lt);
        var w: usize = 0;
        while (w < x.writes.items.len) {
            const call = x.writes.items[w][0];
            var end = w;
            while (end < x.writes.items.len and x.writes.items[end][0] == call) end += 1;
            const run = try x.make(ev, keys, call);
            for (x.items.items[run.items[0]..][0..run.items[1]]) |it| for (x.writes.items[w..end]) |wr| {
                try f.charge(.inspection, 1);
                if (it.arg == wr[1] or !it.agg) continue;
                const tl = f.leafAt(wr[2]);
                const ks = try keys.of(ev, it.leaf);
                const near = for (ks.keys) |kk| {
                    if (kk[0] == 0 and kk[1] == f.roots.items[tl.root].a and (try f.related(kk[2], tl.pos)).rel == .related) break true;
                } else false;
                if (near) continue;
                const o = try Distinct.overlap(ev, it.leaf, wr[2], true);
                if (o.kind != .under) continue;
                try req.add(arena, ev.account(), o.cond);
                break;
            };
            w = end;
        }
    }
};
