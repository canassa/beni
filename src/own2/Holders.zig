//! L8: what resolution reads of a frame's leaves, built once per
//! resolution (`docs/design/ownership-v2.md` §2.8): each leaf's base keys
//! (*Base keys*), and the escape index (*The escape index*). The holder
//! index is `Sweep`'s.
//!
//! Obligations kept here: O2's resolution half reads the escapes through
//! the index, every escape a target can meet visited (none skipped).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Relation = @import("Relation.zig");
const Distinct = @import("Distinct.zig");
const Contract = @import("Contract.zig");
const Slots = @import("Slots.zig");
const Walk = @import("Walk.zig");
const Regions = @import("Regions.zig");

pub const Error = Ids.ChargeError;
const Cond = Contract.Cond;
const none: u32 = Ids.none_int;

/// A base key: `(kind, root or atom, extra)`; kind 0 a parameter (`extra`
/// its base leaf's position, §2.8 *Holder entries*), 1 a site, 2 a
/// call's fresh atom, 3 a shared value. Unknown is a flag.
pub const Key = [3]u32;

/// What a leaf comes from, in a word: whether it reaches unknown objects
/// or a parameter's, and the least shared value it reaches (`none`).
pub const Facts = struct { unknown: bool = false, param: bool = false, shared: [2]u32 = .{ none, none } };

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
/// `Facts`, made for every leaf a demand targets, and its run of `items`
/// (sorted, once each), made only for a target or a holder that a demand
/// meets live. Each made by one post-order walk over the expansions,
/// strongly connected leaves sharing one entry, so each leaf is expanded
/// once a column.
pub const Keys = struct {
    facts: std.ArrayList(?Facts) = .empty,
    /// Per leaf: `items` run start and length, `none` while not made.
    run: std.ArrayList([2]u32) = .empty,
    items: std.ArrayList(Key) = .empty,

    pub const Mode = enum { facts, runs };

    pub fn deinit(k: *Keys, gpa: Allocator) void {
        k.facts.deinit(gpa);
        k.run.deinit(gpa);
        k.items.deinit(gpa);
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
        return .{ .keys = k.items.items[r[0]..][0..r[1]], .unknown = k.facts.items[li].?.unknown };
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
                .answer, .top => fx.unknown = true,
                .recons => unreachable,
            }
            const span = w.span.items[at];
            for (w.kids.items[span[0]..span[1]]) |c| {
                if (k.made(c, .facts)) {
                    const cf = k.facts.items[c].?;
                    fx.unknown = fx.unknown or cf.unknown;
                    fx.param = fx.param or cf.param;
                    fx.shared = leastShared(fx.shared, cf.shared);
                }
                if (mode == .runs and k.made(c, .runs)) {
                    const r = k.run.items[c];
                    try acc.appendSlice(g, k.items.items[r[0]..][0..r[1]]);
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
        const start: u32 = @intCast(k.items.items.len);
        for (acc.items) |x| {
            const n = k.items.items.len;
            if (n > start and std.mem.eql(u32, &k.items.items[n - 1], &x)) continue;
            try k.items.append(g, x);
        }
        const len: u32 = @intCast(k.items.items.len - start);
        try f.charge(.edge, @max(1, len));
        for (members.items) |at| {
            const m = w.leaf.items[at];
            k.run.items[m] = .{ start, len };
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
        if (l.kind == .ref and e.expandable(l)) try e.expand(li, &w.kids);
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

/// Whether effect run `r` (sorted by parameter, then canonical key, §2.10)
/// has an effect of parameter `j` that meets the slot of canonical key
/// `key` (§2.7, a footprint entry read at a path): one at `key` or below
/// it, or one at a proper prefix of it that is deep (any, when not
/// `deep_only`). Binary searches by prefix, one a prefix of `key` and one
/// below it, each charged before its work: never a scan of the run.
pub fn effectMeets(ev: *Relation.Eval, contracts: *const Contract.Table, r: Ids.Range, j: u32, key: []const u32, deep_only: bool) Error!bool {
    const slots = ev.f.slots;
    const effs = contracts.effectsOf(r);
    const n: u32 = @intCast(effs.len);
    if (n == 0) return false;
    const step = std.math.log2_int_ceil(u32, n + 1) + 1;
    const Ctx = struct { slots: *const Slots.Table, j: u32, key: []const u32 };
    const before = struct {
        fn f(c: Ctx, x: Contract.Effect) bool {
            if (x.j != c.j) return x.j < c.j;
            return std.mem.order(u32, c.slots.relKey(x.slot), c.key) == .lt;
        }
    }.f;
    // At or below `key`: the first effect not before it has `key` as prefix.
    try ev.f.charge(.inspection, step);
    const at = std.sort.partitionPoint(Contract.Effect, effs, Ctx{ .slots = slots, .j = j, .key = key }, before);
    if (at < n and effs[at].j == j and std.mem.startsWith(u32, slots.relKey(effs[at].slot), key)) return true;
    // At a proper prefix: three words a step (`Slots.relKey`).
    var len: usize = 0;
    while (len + 3 <= key.len) : (len += 3) {
        if (len == key.len) break;
        try ev.f.charge(.inspection, step);
        const p = key[0..len];
        const i = std.sort.partitionPoint(Contract.Effect, effs, Ctx{ .slots = slots, .j = j, .key = p }, before);
        if (i < n and effs[i].j == j and std.mem.eql(u32, slots.relKey(effs[i].slot), p) and (effs[i].deep or !deep_only)) return true;
    }
    return false;
}
