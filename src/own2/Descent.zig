//! L10: the best-hold descent (`docs/design/ownership-v2.md` §2.8 step 3 on
//! slots). A holder whose value is a DAG (a node reached by two paths) has
//! one hold a node, at its least path. A target is judged against it by a
//! descent from the root, kids in order: a kid at whose path every path
//! below has the later uses its own path has (no place below on a cycle,
//! no use at or below it, every use above it reading all of the subtree or
//! none of it) is asked once, and each hold below it is met once, at its
//! least path from there. Elsewhere the descent goes on path by path. The
//! paths at which a hold holds a target (`holdsAt`) are here too, read by
//! the plain holders as well.
//!
//! Obligations kept here: O2's resolution half: every path of the DAG at
//! which a met hold holds a target is judged with liveness, by its own query
//! or by a subtree's that answers for it; none is skipped.

const std = @import("std");
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Slots = @import("Slots.zig");
const Trees = @import("Trees.zig");
const PlaceBelow = @import("PlaceBelow.zig");
const Subtree = @import("Subtree.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");
const Distinct = @import("Distinct.zig");
const Liveness = @import("Liveness.zig");
const Later = @import("Later.zig");
const Sweep = @import("Sweep.zig");

pub const Error = Ids.ChargeError;
const PathId = Ids.PathId;
const Hold = Sweep.Hold;
const none: u32 = Ids.none_int;

/// A path at which a hold holds a target's object, and the relation there.
pub const Held = struct { PathId, Relation.Ov };

/// The paths at which hold `hd` holds an object `target` may be, and
/// the relation there: each `(path, ov)`.
pub fn holdsAt(ev: *Relation.Eval, hd: Hold, target: u32, out: *std.ArrayList(Held)) Error!void {
    const fr = ev.f;
    const g = ev.gpa();
    const o = try Distinct.overlap(ev, hd.leaf, target, true);
    if (o.kind == .no) return;
    if (!hd.refine) return out.append(g, .{ hd.q, o });
    // The path of the hold: below `q` by the steps from the leaf's
    // position to the slots that meet the target's.
    const lf = fr.leafAt(hd.leaf);
    // The target as leaves of the holder's root: itself, or what a
    // call's leaf comes from (its arrivals).
    var tls: std.ArrayList(u32) = .empty;
    defer tls.deinit(g);
    try sameRoot(ev, lf, target, &tls);
    if (lf.kind == .ref and tls.items.len != 0) {
        const pslot = fr.pos.items[lf.pos].slot;
        var any = false;
        for (tls.items) |tli| for (fr.slots.elems(fr.leafAt(tli).slots)) |el| {
            if (Slots.isNot(el)) continue;
            const ts = Slots.pathOf(el).int();
            // A slot, or a whole subtree (`↓ts`, §2.3.1), the holder meets.
            if (!try Subtree.meetIn(fr.slots, g, fr.account, fr.places, lf.slots, try fr.slots.internSorted(g, fr.account, &.{el}))) continue;
            const rel = (try fr.slots.relBelow(g, fr.account, fr.places, pslot, .from(ts))) orelse continue;
            var ps: std.ArrayList(u32) = .empty;
            defer ps.deinit(g);
            try Slots.replay(g, fr.account, fr.places, hd.q, fr.slots.relWords(rel), &ps);
            for (ps.items) |p| {
                try out.append(g, .{ .from(p), o });
                any = true;
            }
        };
        if (any) {
            // The holder's other objects are the target only where its
            // root is not separated: held at the holder's path, under
            // that condition.
            var minus: std.ArrayList(u32) = .empty;
            defer minus.deinit(g);
            for (tls.items) |tli| try minus.append(g, fr.leafAt(tli).slots);
            if (try Subtree.without(fr.slots, g, fr.account, fr.places, lf.slots, minus.items)) |rest| {
                var rl = lf;
                rl.slots = rest;
                const o2 = try Distinct.overlap(ev, try fr.leaf(rl), target, true);
                if (o2.kind != .no) try out.append(g, .{ hd.q, o2 });
            }
            return;
        }
    }
    try out.append(g, .{ hd.q, o });
}

/// The leaves of target `t` at the holder leaf `lf`'s root: `t`
/// itself when it is of that root, else, while it is a call's or a
/// supply's, what it comes from (§2.9.2 step 4), a few levels deep.
fn sameRoot(ev: *Relation.Eval, lf: Value.Leaf, t: u32, out: *std.ArrayList(u32)) Error!void {
    const fr = ev.f;
    const g = ev.gpa();
    if (lf.kind != .ref) return;
    var cur: std.ArrayList(u32) = .empty;
    defer cur.deinit(g);
    try cur.append(g, t);
    var depth: u32 = 0;
    while (cur.items.len != 0 and depth < 4) : (depth += 1) {
        var next: std.ArrayList(u32) = .empty;
        defer next.deinit(g);
        for (cur.items) |x| {
            try fr.charge(.inspection, 1);
            const xl = fr.leafAt(x);
            if (xl.kind != .ref) continue;
            if (xl.root == lf.root) {
                try out.append(g, x);
                continue;
            }
            const k = fr.roots.items[xl.root].kind;
            if (k == .call or k == .supply) try ev.expand(x, &next);
        }
        std.mem.swap(std.ArrayList(u32), &cur, &next);
    }
}

/// What the descent hands its caller: hold `k` (its index in the holder's
/// holds) holds the target at `q` with `ov`, and the holder's first use
/// after the point that reads it there (null: none; such a path is handed
/// over only when `dead`).
pub const Visit = struct {
    ctx: *anyopaque,
    each: *const fn (ctx: *anyopaque, k: u32, q: PathId, ov: Relation.Ov, use: ?Liveness.UseId) Error!void,
    dead: bool = false,
};

/// The descent over keyed holder `hi`'s DAG for target `t` at `point`: the
/// holds `met` (ascending) are judged at every path that reaches them, in
/// the order of their paths (a node before its kids, kids in order), so the
/// first hold handed over at a use is at the least path that use reads.
pub fn descend(uses: *Later.Uses, live: *const Sweep.Live, hi: u32, met: []const u32, t: u32, point: u32, visit: Visit) Error!void {
    const ev = uses.ev;
    const fr = ev.f;
    const g = fr.gpa;
    const h = live.holders.items[hi];
    const holds = live.holds.items[h.h_start..][0..h.h_len];
    const n0 = h.d_root;
    const nodes = live.dnodes.items;
    const edges = live.dedges.items;
    var is_met = try g.alloc(bool, holds.len);
    defer g.free(is_met);
    @memset(is_met, false);
    for (met) |k| is_met[k] = true;
    // Per node: whether a met hold is at it or below it (0 unknown, 1 no,
    // 2 yes), by a post-order on an explicit stack.
    const has = try g.alloc(u8, nodes.len - n0);
    defer g.free(has);
    @memset(has, 0);
    {
        var st: std.ArrayList([2]u32) = .empty;
        defer st.deinit(g);
        try st.append(g, .{ n0, 0 });
        while (st.pop()) |top| {
            const n = top[0];
            const nd = nodes[n];
            if (top[1] == 0) {
                if (has[n - n0] != 0) continue;
                try fr.charge(.inspection, 1);
                try st.append(g, .{ n, 1 });
                for (edges[nd.edges.start..][0..nd.edges.len]) |e| if (has[e.node - n0] == 0) try st.append(g, .{ e.node, 0 });
                continue;
            }
            var yes = false;
            for (holds[nd.holds.start..][0..nd.holds.len], nd.holds.start..) |_, k| yes = yes or is_met[k];
            for (edges[nd.edges.start..][0..nd.edges.len]) |e| yes = yes or has[e.node - n0] == 2;
            has[n - n0] = if (yes) 2 else 1;
        }
    }
    if (has[0] != 2) return;
    // Per `(node, use, below a family)`: met already, at a path no greater,
    // by a subtree that answers for its paths (each of its holds is then
    // met once; an exact path is still met after one below a `[*]`).
    var done: Ids.FixedDict(3) = .{};
    defer done.deinit(g);
    const Item = struct { n: u32, q: PathId, flat: bool = false, use: u32 = none };
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(g);
    var hs: std.ArrayList(Held) = .empty;
    defer hs.deinit(g);
    try stack.append(g, .{ .n = n0, .q = nodes[n0].q });
    while (stack.pop()) |it| {
        try fr.charge(.inspection, 1);
        if (it.flat and (try done.getOrPut(g, .{ it.n, it.use, @intFromBool(fr.places.isSummary(it.q)) })).found_existing) continue;
        const nd = nodes[it.n];
        const use: ?Liveness.UseId = if (it.use == none) null else .from(it.use);
        for (holds[nd.holds.start..][0..nd.holds.len], nd.holds.start..) |hd0, k| {
            if (!is_met[k]) continue;
            var hd = hd0;
            hd.q = it.q;
            hs.clearRetainingCapacity();
            try holdsAt(ev, hd, t, &hs);
            for (hs.items) |x| {
                const u = if (it.flat) use else try uses.liveOnce(h.local, x[0], point);
                if (u != null or visit.dead) try visit.each(visit.ctx, @intCast(k), x[0], x[1], u);
            }
        }
        // The kids, pushed last first so that the first is met first.
        const ks = edges[nd.edges.start..][0..nd.edges.len];
        var i = ks.len;
        while (i > 0) {
            i -= 1;
            const e = ks[i];
            if (has[e.node - n0] != 2) continue;
            const c = if (e.step) |s| (try fr.places.extend(g, fr.gc(), it.q, s)) orelse it.q else it.q;
            if (it.flat or c == it.q) {
                try stack.append(g, .{ .n = e.node, .q = c, .flat = it.flat, .use = it.use });
                continue;
            }
            if (try flatAt(uses, h.local, c, point)) {
                const u = try uses.liveOnce(h.local, c, point);
                if (u == null and !visit.dead) continue;
                try stack.append(g, .{ .n = e.node, .q = c, .flat = true, .use = if (u) |x| x.int() else none });
            } else try stack.append(g, .{ .n = e.node, .q = c });
        }
    }
}

/// Whether every path at or below `c` has the later uses of local `h`
/// after `point` that `c` has: no place below `c` is on a cycle (else the
/// descent lists its paths: `hold listings`), no use is at `c` or below
/// it, and each one at a proper prefix of `c` reads all of `c`'s subtree
/// or none of it.
fn flatAt(uses: *Later.Uses, h: u32, c: PathId, point: u32) Error!bool {
    const w = uses.w;
    const fr = &w.f;
    const g = fr.gpa;
    if (w.index.lastUse(h) == none or w.index.lastUse(h) <= point) return true;
    var memo: Ids.FixedDict(1) = .{};
    defer memo.deinit(g);
    if (try PlaceBelow.slotsBelow(g, fr.account, fr.places, fr.places.pathPlace(c), 1, &memo) == std.math.maxInt(u32)) {
        fr.account.hold_listings += 1;
        return false;
    }
    const charge: Ids.Charge = .growth(fr.account);
    if ((try w.index.useUnder(g, charge, fr.places, uses.regions, h, c, point, .all)) != null) return false;
    const parent = fr.places.pathParent(c);
    if (parent == .none) return true;
    const Ctx = struct { u: *Later.Uses, c: PathId };
    var x: Ctx = .{ .u = uses, .c = c };
    const mixed: Liveness.Filter = .{ .ctx = &x, .accept = struct {
        fn accept(ctx: *anyopaque, u: Facts.Use, _: Liveness.UseId) Error!bool {
            const k: *Ctx = @ptrCast(@alignCast(ctx));
            return (try cover(k.u, u, k.c)) == .some;
        }
    }.accept };
    return (try w.index.useAfter(g, charge, fr.places, uses.regions, h, parent, point, mixed)) == null;
}

const Cover = enum { none, all, some };

/// How much of the subtree at `c` use `u` (at a prefix of it) reads: a
/// whole or field use all of it; a call use by its callee's footprint
/// there (§2.7): a deep read or a write at `c` or above it is all, an
/// effect below it some, no effect none.
fn cover(uses: *Later.Uses, u: Facts.Use, c: PathId) Error!Cover {
    if (u.kind != .call or u.use_node == .none) return .all;
    const fr = &uses.w.f;
    const foot = uses.w.foots.items[u.use_node.int()];
    const call = fr.calls.items[foot[0]];
    if (call.contract == none) return .all;
    const hd = uses.contracts.head(call.contract);
    const rem = (try fr.slots.relBelow(fr.gpa, fr.account, fr.places, u.path, c)) orelse return .some;
    const rw = fr.slots.relWords(rem);
    try fr.charge(.inspection, @intCast(rw.len + 1));
    var got: Cover = .none;
    for (uses.contracts.readsOf(hd.reads)) |r| if (r[0] == foot[1]) switch (readCover(&uses.contracts.trees, r[1], rw)) {
        .all => return .all,
        .some => got = .some,
        .none => {},
    };
    // A write at `c` or above it is all of it; one only below it, some.
    const key = fr.slots.relKey(rem);
    if (try writtenAbove(uses, hd.writes, foot[1], key)) return .all;
    if (try Later.effectMeets(uses.ev, uses.contracts, hd.writes, foot[1], key, false)) return .some;
    return got;
}

/// Whether effect run `r` (sorted, §2.10) has an effect of parameter `j`
/// at `key` or at a prefix of it: a binary search a prefix, charged.
fn writtenAbove(uses: *Later.Uses, r: Ids.Range, j: u32, key: []const u32) Error!bool {
    const fr = &uses.w.f;
    const effs = uses.contracts.effectsOf(r);
    if (effs.len == 0) return false;
    const step = std.math.log2_int_ceil(u32, @intCast(effs.len + 1)) + 1;
    const Ctx = struct { slots: *const Slots.Table, j: u32, key: []const u32 };
    const before = struct {
        fn f(x: Ctx, e: @TypeOf(effs[0])) bool {
            if (e.j != x.j) return e.j < x.j;
            return std.mem.order(u32, x.slots.relKey(e.slot), x.key) == .lt;
        }
    }.f;
    var len: usize = 0;
    while (len <= key.len) : (len += 3) {
        try fr.charge(.inspection, step);
        const p = key[0..len];
        const i = std.sort.partitionPoint(@TypeOf(effs[0]), effs, Ctx{ .slots = fr.slots, .j = j, .key = p }, before);
        if (i < effs.len and effs[i].j == j and std.mem.eql(u32, fr.slots.relKey(effs[i].slot), p)) return true;
    }
    return false;
}

/// An effect tree's reach of the subtree at `words` below its root: an
/// open (deep) node at or above it all of it, none below it none.
fn readCover(t: *const Trees.Table, n0: Trees.Node, words: []const u32) Cover {
    var n = n0;
    for (words) |w| {
        if (t.open(n).len != 0) return .all;
        n = t.kidAt(n, w) orelse return .none;
    }
    if (t.open(n).len != 0) return .all;
    return if (t.count(n) == 0) .none else .some;
}
