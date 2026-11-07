//! L8: a holder's later uses (`docs/design/ownership-v2.md` §2.7, §2.8):
//! the first use of a local after a point, compatible with it, that reads
//! a hold at a path, through call uses' footprints. Split from `Resolve` so
//! that the best-hold descent, which asks it at the path of a subtree,
//! sits on the layer above it with the holder index.
//!
//! Obligations kept here: O2's resolution half reads every later use of a
//! holder that may read the hold (an ancestor, the path, below it, a deep
//! read whose levels fold above it), none skipped.

const std = @import("std");
const Place = @import("Place.zig");
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Slots = @import("Slots.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");
const Contract = @import("Contract.zig");
const Forest = @import("Forest.zig");
const Trees = @import("Trees.zig");
const Walk = @import("Walk.zig");
const Liveness = @import("Liveness.zig");
const Regions = @import("Regions.zig");

pub const Error = Ids.ChargeError;
const PathId = Ids.PathId;
const none: u32 = Ids.none_int;

/// A resolution's questions about later uses, with a judgement's answers.
pub const Uses = struct {
    w: *Walk.Walk,
    ev: *Relation.Eval,
    contracts: *const Contract.Table,
    regions: *const Regions.Tree,
    /// A judgement's `liveAt` answers (+1, 0 none), each asked once a target.
    asked: Ids.FixedDict(3) = .{},
    /// The `(call, parameter)` footprints read, for a kept judgement (§2.12).
    feet: ?*std.ArrayList([2]u32) = null,

    fn f(u: *Uses) *Value.Frame {
        return &u.w.f;
    }

    pub fn deinit(u: *Uses) void {
        u.asked.deinit(u.f().gpa);
    }

    /// Forget a judgement's answers (each judgement asks its own).
    pub fn clear(u: *Uses) void {
        u.asked.clearRetainingCapacity();
    }

    /// `liveAt`, each `(holder, path, point)` asked once a judgement.
    pub fn liveOnce(u: *Uses, h: u32, q: PathId, point: u32) Error!?Liveness.UseId {
        try u.f().charge(.inspection, 1);
        if (u.asked.get(.{ h, q.int(), point })) |x| return if (x == 0) null else .from(x - 1);
        const got = try u.liveAt(h, q, point);
        try u.asked.put(u.f().gpa, .{ h, q.int(), point }, if (got) |x| x.int() + 1 else 0);
        return got;
    }

    /// The first use of local `h` after `point`, compatible with it, that
    /// reads the hold at `q` (at an ancestor, at `q`, or below it), through
    /// call uses' footprints.
    pub fn liveAt(u: *Uses, h: u32, q: PathId, point: u32) Error!?Liveness.UseId {
        const w = u.w;
        const fr = u.f();
        const g = fr.gpa;
        if (w.index.lastUse(h) == none or w.index.lastUse(h) <= point) return null;
        const Ctx = struct { u: *Uses, q: PathId };
        var c: Ctx = .{ .u = u, .q = q };
        const filter: Liveness.Filter = .{ .ctx = &c, .accept = struct {
            fn accept(ctx: *anyopaque, x: Facts.Use, _: Liveness.UseId) Error!bool {
                const k: *Ctx = @ptrCast(@alignCast(ctx));
                return k.u.footprintReads(x, k.q);
            }
        }.accept, .below_all = !fr.places.onCycle(fr.places.pathPlace(q)) };
        const charge: Ids.Charge = .growth(fr.account);
        var best: ?Liveness.UseId = try w.index.useAfter(g, charge, fr.places, u.regions, h, q, point, filter);
        if (try w.index.useUnder(g, charge, fr.places, u.regions, h, q, point, filter)) |x| {
            if (best == null or w.index.get(x).point < w.index.get(best.?).point) best = x;
        }
        // A deep read whose levels fold above it (§2.7, a read on a cycle).
        if (fr.places.onCycle(fr.places.pathPlace(q)) or fr.places.pathParent(q) != .none) {
            const run = if (h < w.index.by_local.len) w.index.by_local[h] else Ids.Range{};
            var i: u32 = 0;
            while (i < run.len) : (i += 1) {
                const id = run.start + i;
                const x = w.index.get(.from(id));
                if (x.point <= point or !u.regions.compatible(point, x.point)) continue;
                if (x.kind == .call and x.use_node != .none) continue;
                const ups = try fr.places.foldsUp(g, charge, x.path);
                var k: u32 = 0;
                while (k < ups.len) : (k += 1) {
                    const up = fr.places.foldPath(ups.start + k);
                    if (fr.places.isPrefix(up, q)) {
                        if (best == null or x.point < w.index.get(best.?).point) best = .from(id);
                        break;
                    }
                }
            }
        }
        return best;
    }

    /// Whether local `h` has a use after `point` compatible with it, at
    /// any path: one range query, before a query per hold.
    pub fn usedAfter(u: *Uses, h: u32, point: u32) Error!bool {
        const w = u.w;
        if (h >= w.index.by_local.len) return false;
        try u.f().charge(.region, 1);
        return (try w.index.firstAfter(u.f().gpa, .growth(u.f().account), w.index.by_local[h], point, u.regions.rank2(point))) != null;
    }

    /// Whether a use reads the hold at `q` (§2.7): a whole or field use does;
    /// a call use does where its callee's footprint reaches `q`.
    fn footprintReads(u: *Uses, x: Facts.Use, q: PathId) Error!bool {
        if (@import("Mutate.zig").on(.later_footprint_none)) return false;
        if (x.kind != .call or x.use_node == .none) return true;
        const fr = u.f();
        const foot = u.w.foots.items[x.use_node.int()];
        const call = fr.calls.items[foot[0]];
        if (u.feet) |l| try l.append(fr.gpa, foot);
        if (call.contract == none) return true;
        const h = u.contracts.head(call.contract);
        const rem = (try fr.slots.relBelow(fr.gpa, fr.account, fr.places, x.path, q)) orelse return true;
        // The callee's read and write trees a parameter (§2.7), charged.
        const rw = fr.slots.relWords(rem);
        try fr.charge(.inspection, @intCast(rw.len + 1));
        for (u.contracts.readsOf(h.reads)) |r| if (r[0] == foot[1] and Forest.effectReaches(&u.contracts.trees, fr.places, r[1], rw)) return true;
        for (u.contracts.writesOf(h.writes)) |r| if (r[0] == foot[1] and writeMeets(&u.contracts.trees, fr.places, r[1], rw)) return true;
        return false;
    }
};

/// Whether write tree `n0` meets the slot `words` below its root (§2.7, a
/// footprint entry read at a path): a write at it or below it, or at a
/// proper prefix of it. The walk down its steps, charged by the caller.
pub fn writeMeets(t: *const Trees.Table, places: *const Place.Table, n0: Trees.Node, words: []const u32) bool {
    var n = n0;
    for (words) |w| {
        if (t.here(n).len != 0 or t.open(n).len != 0) return true;
        n = t.kidAt(n, w) orelse return t.rowReaches(places, n, w);
    }
    return t.count(n) != 0;
}
