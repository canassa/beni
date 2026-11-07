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
const Place = @import("Place.zig");
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Slots = @import("Slots.zig");
const Trees = @import("Trees.zig");
const PlaceBelow = @import("PlaceBelow.zig");
const Subtree = @import("Subtree.zig");
const MeetRun = @import("MeetRun.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");
const Distinct = @import("Distinct.zig");
const Liveness = @import("Liveness.zig");
const Later = @import("Later.zig");
const Sweep = @import("Sweep.zig");
const DagRoutes = @import("DagRoutes.zig");
const HoldAt = @import("HoldAt.zig");

pub const Error = Ids.ChargeError;
const PathId = Ids.PathId;
const Hold = Sweep.Hold;
const none: u32 = Ids.none_int;

pub const Held = HoldAt.Held;

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
    if (@import("Mutate.zig").on(.descent_off)) return;
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
    // The items, in the order the descent meets them (a node before its
    // kids, kids in order): `(node, path)`, or, in a subtree that answers
    // for its paths, `(node, use, below a family)` at the path it is met at
    // first. Each is read once, under the routes `DagRoutes` unites for it.
    var dr: DagRoutes.Table = .{};
    defer dr.deinit(g);
    var index: Ids.FixedDict(4) = .{};
    defer index.deinit(g);
    const Item = struct { n: u32, q: PathId, flat: bool = false, use: u32 = none };
    var items: std.ArrayList(Item) = .empty;
    defer items.deinit(g);
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(g);
    var stack: std.ArrayList(struct { u32, PathId }) = .empty;
    defer stack.deinit(g);
    const root = try dr.add(g, nodes[n0].v);
    try items.append(g, .{ .n = n0, .q = nodes[n0].q });
    try stack.append(g, .{ root, nodes[n0].q });
    while (stack.pop()) |top| {
        try fr.charge(.inspection, 1);
        const id = top[0];
        if (dr.items.items[id].edges.start != none) continue;
        items.items[id].q = top[1];
        try order.append(g, id);
        const it = items.items[id];
        dr.begin(id);
        // The kids, pushed last first so that the first is met first.
        const ks = edges[nodes[it.n].edges.start..][0..nodes[it.n].edges.len];
        const s0 = stack.items.len;
        for (ks) |e| {
            if (has[e.node - n0] != 2) continue;
            const c = if (e.step) |st| (try fr.places.extend(g, fr.gc(), it.q, st)) orelse it.q else it.q;
            var kid: Item = .{ .n = e.node, .q = c };
            if (it.flat or c == it.q) {
                kid = .{ .n = e.node, .q = c, .flat = it.flat, .use = it.use };
            } else if (try flatAt(uses, h.local, c, point)) {
                const u = try uses.liveOnce(h.local, c, point);
                if (u == null and !visit.dead) continue;
                kid = .{ .n = e.node, .q = c, .flat = true, .use = if (u) |x| x.int() else none };
            }
            const key: [4]u32 = if (kid.flat) .{ kid.n, kid.use, @intFromBool(fr.places.isSummary(c)), 1 } else .{ kid.n, c.int(), 0, 0 };
            const got = try index.getOrPut(g, key);
            if (!got.found_existing) {
                got.value_ptr.* = try dr.add(g, nodes[kid.n].v);
                try items.append(g, kid);
            }
            try dr.edge(g, id, got.value_ptr.*, e.arm);
            try stack.append(g, .{ got.value_ptr.*, c });
        }
        std.mem.reverse(struct { u32, PathId }, stack.items[s0..]);
    }
    try dr.settle(ev, root);
    var hs: std.ArrayList(Held) = .empty;
    defer hs.deinit(g);
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(g);
    for (order.items) |id| {
        const ri = dr.items.items[id];
        if (!ri.reached) continue;
        const it = items.items[id];
        const nd = nodes[it.n];
        const use: ?Liveness.UseId = if (it.use == none) null else .from(it.use);
        for (holds[nd.holds.start..][0..nd.holds.len], nd.holds.start..) |hd0, k| {
            if (!is_met[k]) continue;
            ls.clearRetainingCapacity();
            try DagRoutes.under(ev, hd0.leaf, ri, &ls);
            for (ls.items) |l| {
                hs.clearRetainingCapacity();
                try HoldAt.holdsAt(ev, .{ .leaf = l, .q = it.q, .refine = hd0.refine }, t, &hs);
                for (hs.items) |x| {
                    const u = if (it.flat) use else try uses.liveOnce(h.local, x[0], point);
                    if (u != null or visit.dead) try visit.each(visit.ctx, @intCast(k), x[0], x[1], u);
                }
            }
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
    if (uses.feet) |l| try l.append(fr.gpa, foot);
    if (call.contract == none) return .all;
    const hd = uses.contracts.head(call.contract);
    const rem = (try fr.slots.relBelow(fr.gpa, fr.account, fr.places, u.path, c)) orelse return .some;
    const rw = fr.slots.relWords(rem);
    try fr.charge(.inspection, @intCast(rw.len + 1));
    var got: Cover = .none;
    for (uses.contracts.readsOf(hd.reads)) |r| if (r[0] == foot[1]) switch (readCover(&uses.contracts.trees, fr.places, r[1], rw)) {
        .all => return .all,
        .some => got = .some,
        .none => {},
    };
    // A write at `c` or above it is all of it; one only below it, some.
    for (uses.contracts.writesOf(hd.writes)) |r| if (r[0] == foot[1]) {
        if (writtenAbove(&uses.contracts.trees, fr.places, r[1], rw)) return .all;
        if (Later.writeMeets(&uses.contracts.trees, fr.places, r[1], rw)) return .some;
    };
    return got;
}

/// Whether write tree `n0` writes the slot `words` below its root or a
/// prefix of it: the walk down its steps, charged by the caller.
fn writtenAbove(t: *const Trees.Table, places: *const Place.Table, n0: Trees.Node, words: []const u32) bool {
    var n = n0;
    for (words) |w| {
        if (t.here(n).len != 0 or t.open(n).len != 0) return true;
        n = t.kidAt(n, w) orelse return t.rowReaches(places, n, w);
    }
    return t.here(n).len != 0 or t.open(n).len != 0;
}

/// An effect tree's reach of the subtree at `words` below its root: an
/// open (deep) node at or above it all of it, none below it none.
fn readCover(t: *const Trees.Table, places: *const Place.Table, n0: Trees.Node, words: []const u32) Cover {
    var n = n0;
    for (words) |w| {
        if (t.open(n).len != 0) return .all;
        n = t.kidAt(n, w) orelse return if (t.rowReaches(places, n, w)) .all else .none;
    }
    if (t.open(n).len != 0) return .all;
    return if (t.count(n) == 0) .none else .some;
}
