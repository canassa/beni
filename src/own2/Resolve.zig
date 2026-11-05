//! L9: demands judged offline (`docs/design/ownership-v2.md` §2.8,
//! *Resolution on slots*): after a walk and its evaluation, when every use,
//! holder and pending operand of the frame is known. A demand's targets are
//! leaves; each condition is the one relation (§2.9.2) against what could
//! still observe them: unknown provenance, escapes, top-level values, the
//! other operands, the pending operands, the live locals (found through the
//! holder index: a target's root names the locals that may hold it), and
//! what the overlaps relied on.
//!
//! The same check, at a callback call, gives a label's kept slots and the
//! condition its supplies' distinctness relies on (§2.11.3).
//!
//! Obligations kept here: O2's resolution half (a later compatible use of a
//! holder at an overlapping path refuses), O4 (a write relies only on a
//! selection of the frame's parameters, which callers instantiate).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Subtree = @import("Subtree.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");
const Distinct = @import("Distinct.zig");
const SupplyCond = @import("SupplyCond.zig");
const Routed = @import("Routed.zig");
const Cells = @import("Cells.zig");
const Fed = @import("Fed.zig");
const Contract = @import("Contract.zig");
const Forest = @import("Forest.zig");
const Eval = @import("Eval.zig");
const Walk = @import("Walk.zig");
const Liveness = @import("Liveness.zig");
const Ancestry = @import("Ancestry.zig");
const Regions = @import("Regions.zig");
const Holders = @import("Holders.zig");
const Sweep = @import("Sweep.zig");
const Stack = @import("Stack.zig");
const TagTree = @import("TagTree.zig");
const Later = @import("Later.zig");
const Descent = @import("Descent.zig");
const HoldAt = @import("HoldAt.zig");
const Kept = @import("Kept.zig");
const Parts = @import("Parts.zig");
const Twins = @import("Twins.zig");

pub const Error = Ids.ChargeError;
const Cond = Contract.Cond;
const PathId = Ids.PathId;
const none: u32 = Ids.none_int;
const debug = false;

pub const HolderKind = Kept.HolderKind;
pub const Holder = Kept.Holder;
pub const Outcome = Kept.Outcome;
pub const Line = Kept.Line;

pub const Result = struct {
    lines: []Line,
    verdicts: Kept.Verdicts,
};

/// A holder's holds as `TagTree.Forest` reads them: each hold's tags.
const HoldTags = struct {
    f: *Value.Frame,
    hs: []const Sweep.Hold,
    pub fn listOf(x: HoldTags, i: usize) u32 {
        return x.f.leafAt(x.hs[i].leaf).tags;
    }
};

/// A refusal's witness so far: the holder, its use and the path.
const Witness = struct { h: u32, use: Liveness.UseId, q: PathId };

const Resolver = struct {
    e: *Eval.Evaluation,
    arena: Allocator,
    regions: *const Regions.Tree,
    /// The holder index and its sweep (§2.8): locals by their values' base
    /// keys, live while the sweep's point is between their binding and last use.
    live: Sweep.Live = .{},
    ancestry: Ancestry.Ancestry = .{},
    /// Each leaf's base keys and the escape index (§2.8).
    keys: Holders.Keys = .{},
    escapes: Holders.Escapes = .{},
    ops: Holders.Operands = .{},
    /// The pending operands by clock and key (§2.8 step 5).
    stack: Stack.Index = .{},
    /// Per keyed holder, its holds by their tags (§2.8).
    tags: TagTree.Forest = .{},
    /// The holders' later uses, a judgement's answers kept (§2.8).
    uses: Later.Uses,
    /// Working lists of a judgement's hold readers.
    met: std.ArrayList(u32) = .empty,
    agg: std.ArrayList(Agg) = .empty,
    agg_any: bool = false,
    hs: std.ArrayList(Descent.Held) = .empty,
    /// Whether a judgement's aggregated holders add to the frame's `req`:
    /// a demand's do, a label's supplied part's are judged one by one.
    aggregate: bool = false,
    /// The code's kept judgements across the group's rounds (§2.12).
    kept: ?*Kept.Table = null,

    fn f(r: *Resolver) *Value.Frame {
        return &r.e.w.f;
    }
    fn ev(r: *Resolver) *Relation.Eval {
        return &r.e.ev;
    }
    fn gpa(r: *Resolver) Allocator {
        return r.e.w.f.gpa;
    }
    fn account(r: *Resolver) *Ids.Account {
        return r.e.w.f.account;
    }

    fn deinit(r: *Resolver) void {
        r.live.deinit(r.gpa());
        r.ancestry.deinit(r.gpa());
        r.keys.deinit(r.gpa());
        r.escapes.deinit(r.gpa());
        r.ops.deinit(r.gpa());
        r.stack.deinit(r.gpa());
        r.tags.deinit(r.gpa());
        r.uses.deinit();
        r.met.deinit(r.gpa());
        r.agg.deinit(r.gpa());
        r.hs.deinit(r.gpa());
    }

    /// The holder index (§2.8): every bound local that is used after its
    /// binding; keyed by its holds' base keys only when a demand first
    /// meets it live (`keyLive`).
    fn index(r: *Resolver) Error!void {
        const w = r.e.w;
        for (w.bindings, 0..) |b, local| {
            if (b.value == none or b.point == none) continue;
            const last = w.index.lastUse(@intCast(local));
            if (last == none or last <= b.point) continue;
            try r.live.add(r.ev(), @intCast(local), b.point, last);
        }
        try r.live.finish(r.ev());
    }

    /// Key every unkeyed live holder (§2.8, *Holder entries judged by base
    /// leaves*): its holds listed once, each hold's base keys, its uses.
    pub fn keyLive(r: *Resolver) Error!void {
        if (!r.live.any()) return;
        const g = r.gpa();
        const w = r.e.w;
        const fr = r.f();
        var keys: std.ArrayList([3]u32) = .empty;
        defer keys.deinit(g);
        var hds: std.ArrayList(Sweep.Hold) = .empty;
        defer hds.deinit(g);
        var dag: Sweep.Dag = .{};
        defer dag.deinit(g);
        var points: std.ArrayList(u32) = .empty;
        defer points.deinit(g);
        while (r.live.takeUnkeyed()) |hi| {
            if (r.kept) |k| try k.event(g, .{ Kept.key_event, hi, 0 });
            const local = r.live.holders.items[hi].local;
            hds.clearRetainingCapacity();
            keys.clearRetainingCapacity();
            points.clearRetainingCapacity();
            dag.nodes.clearRetainingCapacity();
            dag.edges.clearRetainingCapacity();
            const root = try fr.places.rootPath(g, try r.e.ctx.placeOfLocal(r.e.ctx.ctx, local));
            const is_dag = try Sweep.holdsOfValue(r.ev(), w.bindings[local].value, root, &hds, &dag);
            var unknown = false;
            for (hds.items) |*hd| {
                const ks = try r.keys.of(r.ev(), hd.leaf);
                try keys.appendSlice(g, ks.keys);
                unknown = unknown or ks.unknown;
                var param = false;
                for (ks.keys) |k| param = param or k[0] == 0;
                hd.agg = param and !ks.unknown;
            }
            const run = if (local < w.index.by_local.len) w.index.by_local[local] else Ids.Range{};
            var i: u32 = 0;
            while (i < run.len) : (i += 1) try points.append(g, w.index.get(.from(run.start + i)).point);
            try r.live.key(r.ev(), hi, hds.items, if (is_dag) &dag else null, try sortedKeys(&keys), unknown, points.items);
        }
    }

    fn sortedKeys(keys: *std.ArrayList([3]u32)) Error![]const [3]u32 {
        std.mem.sort([3]u32, keys.items, {}, struct {
            fn lt(_: void, a: [3]u32, c: [3]u32) bool {
                return std.mem.order(u32, &a, &c) == .lt;
            }
        }.lt);
        var n: usize = 0;
        for (keys.items) |k| {
            if (n != 0 and std.mem.eql(u32, &keys.items[n - 1], &k)) continue;
            keys.items[n] = k;
            n += 1;
        }
        keys.shrinkRetainingCapacity(n);
        return keys.items;
    }

    /// The buckets of the holders that may hold target `t` (§2.8): the
    /// unknown one; for a parameter's untagged target judged with
    /// aggregation, the buckets at related positions (true: every other
    /// holder is an aggregated one); else its keys' buckets, and every
    /// parameter's for a parameter's key.
    fn bucketsOf(r: *Resolver, t: u32, out: *std.ArrayList(u32)) Error!bool {
        const g = r.gpa();
        const l = r.f().leafAt(t);
        if (r.live.unknownBucket()) |b| try out.append(g, b);
        if (r.aggregate and Holders.paramTarget(r.f(), l)) {
            try r.live.related(r.ev(), l.pos, out);
            return true;
        }
        const ks = try r.keys.of(r.ev(), t);
        var params = false;
        for (ks.keys) |k| {
            if (k[0] == 0) {
                params = true;
                continue;
            }
            if (r.live.bucketFor(k)) |b| try out.append(g, b);
        }
        if (params) try r.live.allParams(r.ev(), out);
        return false;
    }

    /// The aggregated holders of a parameter's target `t` at `point` (§2.8,
    /// *Holder entries judged by base leaves*, step 3): no visited holder,
    /// each hold of which answers no or `under` an apart selection and the
    /// target's. A pending holder's holds are judged against `t`; those used
    /// after the point add their selections, and a holder all of whose
    /// holds have is done (`dones`, once the demand is accepted). When no
    /// pending one is used after the point, the first done holder that is
    /// adds the target's selection with its own (which `req` has already).
    fn aggregated(r: *Resolver, t: u32, point: u32, relied: *Holders.Gather, done_holds: *std.ArrayList([2]u32), dones: *std.ArrayList(u32)) Error!void {
        const g = r.gpa();
        const fr = r.f();
        var found = false;
        var it = r.live.aggFirst(0);
        while (it) |hi| : (it = r.live.aggNext(hi)) {
            try fr.charge(.inspection, 1);
            if (r.live.visited(hi)) continue;
            const h = r.live.holders.items[hi];
            if (!try r.uses.usedAfter(h.local, point)) continue;
            var all = true;
            for (try r.aggHolds(hi, false, t, point, relied), 0..) |got, k| switch (got) {
                .skip => {},
                .some, .empty => all = false,
                .all => try done_holds.append(g, .{ hi, @intCast(k) }),
            };
            found = found or r.agg_any;
            if (all) try dones.append(g, hi);
        }
        if (found) return;
        it = r.live.aggFirst(1);
        while (it) |hi| : (it = r.live.aggNext(hi)) {
            try fr.charge(.inspection, 1);
            if (r.live.visited(hi)) continue;
            const local = r.live.holders.items[hi].local;
            if (!try r.uses.usedAfter(local, point)) continue;
            _ = try r.aggHolds(hi, true, t, point, relied);
            if (r.agg_any) return;
        }
    }

    /// A hold's aggregated answer: not asked, no path, every `under` path
    /// used after the point, or some not.
    const Agg = enum(u8) { skip, empty, all, some };

    /// Holder `hi`'s aggregated holds (every one when `done_too`, else
    /// those not done) against `t`: each `under` path used after `point`
    /// gathered (`agg_any` when one is); per hold, whether some or all of
    /// the paths that answer `under` are.
    fn aggHolds(r: *Resolver, hi: u32, done_too: bool, t: u32, point: u32, relied: *Holders.Gather) Error![]const Agg {
        const g = r.gpa();
        const hds = r.live.holdsOf(hi);
        r.met.clearRetainingCapacity();
        r.agg.clearRetainingCapacity();
        try r.agg.appendNTimes(g, .skip, hds.len);
        r.agg_any = false;
        for (hds, 0..) |hd, k| if (hd.agg and (done_too or !hd.done)) {
            try r.met.append(g, @intCast(k));
            r.agg.items[k] = .empty;
        };
        const Ctx = struct { r: *Resolver, relied: *Holders.Gather };
        var c: Ctx = .{ .r = r, .relied = relied };
        try r.heldAt(hi, r.met.items, t, point, .{ .ctx = &c, .dead = true, .each = struct {
            fn each(ctx: *anyopaque, k: u32, _: PathId, ov: Relation.Ov, u: ?Liveness.UseId) Error!void {
                const x: *Ctx = @ptrCast(@alignCast(ctx));
                const a = &x.r.agg.items[k];
                if (a.* == .empty) a.* = .all;
                if (ov.kind != .under) return;
                if (u == null) {
                    a.* = .some;
                    return;
                }
                try x.relied.add(x.r.gpa(), x.r.account(), ov.cond);
                x.r.agg_any = true;
            }
        }.each });
        return r.agg.items;
    }

    /// Holder `hi`'s holds `met` against target `t`: each path at which one
    /// holds it, with the holder's first use after `point` there; a holder
    /// whose value is a DAG by the best-hold descent (`Descent`).
    fn heldAt(r: *Resolver, hi: u32, met: []const u32, t: u32, point: u32, visit: Descent.Visit) Error!void {
        const h = r.live.holders.items[hi];
        if (h.d_root != none) return Descent.descend(&r.uses, &r.live, hi, met, t, point, visit);
        const hds = r.live.holdsOf(hi);
        for (met) |k| {
            r.hs.clearRetainingCapacity();
            try HoldAt.holdsAt(r.ev(), .{ .leaf = hds[k].leaf, .q = hds[k].q, .refine = hds[k].refine }, t, &r.hs);
            for (r.hs.items) |x| {
                const u = try r.uses.liveOnce(h.local, x[0], point);
                if (u != null or visit.dead) try visit.each(visit.ctx, k, x[0], x[1], u);
            }
        }
    }

    /// Whether an escape before `point` reaches a target (§2.8, *The
    /// escape index*).
    fn escaped(r: *Resolver, t: u32, point: u32, call: u32, relied: *Holders.Gather) Error!bool {
        return r.escapes.escaped(r.ev(), &r.keys, r.regions, r.e.escapes.items, t, point, call, relied);
    }

    fn refuse(o: *Outcome, cause: Facts.Cause) void {
        o.verdict = .refused;
        o.cause = cause;
    }

    /// Judge demand `d`.
    fn judge(r: *Resolver, d: Walk.Demand) Error!Line {
        const w = r.e.w;
        const fr = r.f();
        const g = r.gpa();
        try fr.charge(.demand, 1);
        r.uses.clear();
        var line: Line = .{ .demand = d, .outcome = .{} };
        const o = &line.outcome;
        const targets = w.leavesOfRun(d.targets);
        // Known, and the ground: what the targets come from, by their facts
        // (§2.8, *Base keys*).
        var fx: Holders.Facts = .{};
        for (targets) |t| {
            fx.join(try r.keys.factsOf(r.ev(), t));
        }
        // A host object escaped, or JavaScript made it (§2.10, *host objects*).
        if (fx.unknown or fx.host or targets.len == 0) {
            refuse(o, if (fx.unknown or targets.len == 0) .unknown else .escaped);
            if (targets.len != 0) o.exactness = .approximate;
            return line;
        }
        // The ground is what the targets come from (R-7.15): a parameter's
        // object relies on the callers, anything this activation allocated
        // (here or in a callee) is fresh.
        const ground: Facts.Verdict.Accepted = if (fx.param) .param else .fresh;
        if (fx.shared[0] != none) {
            refuse(o, .top_level);
            o.exactness = .position;
            o.shared = fx.shared;
            return line;
        }
        var relied: Holders.Gather = .{};
        defer relied.deinit(g);
        relied.no = d.relies.no;
        if (debug) std.debug.print("judge point {d} kind {t} relies no={} sel={d}\n", .{ d.point, d.kind, d.relies.no, d.relies.sel.len });
        // Unescaped.
        for (targets) |t| if (try r.escaped(t, d.point, d.call, &relied)) {
            refuse(o, .escaped);
            return line;
        };
        // Disjoint: the callee's own reliance, then the other operands.
        if (relied.no) {
            refuse(o, .disjoint);
            o.other_paths = d.kind == .writer or d.kind == .consumed;
            o.exactness = .approximate;
            return line;
        }
        // A kept supply written by a known code.
        if (d.kept or d.many) {
            refuse(o, if (d.many) .once else .call);
            return line;
        }
        // A call's other arguments by the operand index (§2.8 step 4): the
        // aggregated ones join `req` once, at the end.
        const by_call = r.aggregate and d.call != none and !fr.calls.items[d.call].virtual and d.operands.len + 1 == fr.calls.items[d.call].args.len;
        var writes: std.ArrayList([3]u32) = .empty;
        defer writes.deinit(g);
        var ols: std.ArrayList(u32) = .empty;
        defer ols.deinit(g);
        for (targets) |t| {
            ols.clearRetainingCapacity();
            if (by_call) {
                if (try r.ops.judged(r.ev(), &r.keys, d.call, d.arg, t, &relied, &ols)) try writes.append(g, .{ d.call, d.arg, t });
            } else for (w.valuesOfRun(d.operands)) |v| try r.ev().leavesOf(v, 0, &ols);
            for (ols.items) |l| {
                const ov = try Distinct.overlap(r.ev(), l, t, true);
                switch (ov.kind) {
                    .no => {},
                    .under => try relied.add(g, r.account(), ov.cond),
                    .may => {
                        refuse(o, .disjoint);
                        return line;
                    },
                }
            }
        }
        // Dead: the pending operands, then the live locals.
        try r.stack.build(r.ev(), w, r.regions, &r.keys);
        if (try r.stack.judge(r.ev(), w, r.regions, d.pending, d.point, targets, r.aggregate, Holders.paramTarget, &relied)) |p| {
            refuse(o, .held_operand);
            line.holder = .{ .kind = .pending, .who = p, .token = w.bir.insts.items(.main_token)[p] };
            return line;
        }
        // The live locals (§2.8 step 5), a target's buckets in use order: once
        // a hold is found, no holder used later can be the witness.
        try r.keyLive();
        const base_local: u32 = if (w.bir.instTag(@fromBackingInt(d.base_inst)) == .local) w.bir.instData(@fromBackingInt(d.base_inst)).lhs else none;
        var best: ?Witness = null;
        var done_holds: std.ArrayList([2]u32) = .empty;
        defer done_holds.deinit(g);
        var dones: std.ArrayList(u32) = .empty;
        defer dones.deinit(g);
        var bs: std.ArrayList(u32) = .empty;
        defer bs.deinit(g);
        const Ctx = struct { r: *Resolver, h: u32, best: *?Witness, relied: *Holders.Gather };
        var c: Ctx = .{ .r = r, .h = none, .best = &best, .relied = &relied };
        const visit: Descent.Visit = .{
            .ctx = &c,
            .each = struct {
                fn each(ctx: *anyopaque, _: u32, q: PathId, ov: Relation.Ov, use: ?Liveness.UseId) Error!void {
                    const x: *Ctx = @ptrCast(@alignCast(ctx));
                    // A cell holds its contents behind the barrier (§2.13.7):
                    // only the worded operations reach them, and what they
                    // hand out (a loan, a callback's supply) is a holder of
                    // its own.
                    if (Cells.behindCell(x.r.f().places, q)) return;
                    const u = use.?;
                    const idx = &x.r.e.w.index;
                    switch (ov.kind) {
                        .no => {},
                        .under => try x.relied.add(x.r.gpa(), x.r.account(), ov.cond),
                        .may => if (x.best.*) |bh| {
                            const up = idx.get(u).point;
                            const bp = idx.get(bh.use).point;
                            // At one use of one holder, an exact hold before one at
                            // or below a `[*]` or a `⟲` (*Verdicts*), else the first.
                            const pl = x.r.f().places;
                            const exact = up == bp and x.h == bh.h and pl.isSummary(bh.q) and !pl.isSummary(q);
                            if (up < bp or (up == bp and x.h < bh.h) or exact) x.best.* = .{ .h = x.h, .use = u, .q = q };
                        } else {
                            x.best.* = .{ .h = x.h, .use = u, .q = q };
                        },
                    }
                }
            }.each,
        };
        // The live holders by their tags: a target's routes one by one.
        var outs: std.ArrayList(u32) = .empty;
        defer outs.deinit(g);
        if (r.live.any()) for (targets) |t0| try Routed.writtenOut(r.ev(), t0, &outs);
        if (r.live.any()) for (outs.items) |t| {
            bs.clearRetainingCapacity();
            const aggregating = try r.bucketsOf(t, &bs);
            try r.live.begin(r.ev(), bs.items);
            while (try r.live.next(r.ev(), if (best) |bh| w.index.get(bh.use).point else std.math.maxInt(u32))) |hi| {
                c.h = r.live.holders.items[hi].local;
                const hds = r.live.holdsOf(hi);
                try r.heldAt(hi, try r.tags.meeting(g, r.account(), &fr.sets.tags, hi, hds.len, HoldTags{ .f = fr, .hs = hds }, fr.leafAt(t).tags), t, d.point, visit);
            }
            if (aggregating and best == null) try r.aggregated(t, d.point, &relied, &done_holds, &dones);
        };
        if (best) |bh| {
            const clos = fr.val(w.bindings[bh.h].value);
            refuse(o, if (bh.h == base_local) .later_use else if (clos.kind == .built and clos.form == .closure) .captured else .alias);
            o.holder_path = bh.q;
            line.holder = .{ .kind = .binding, .who = bh.h, .token = w.bindings[bh.h].token };
            line.use_token = w.bir.insts.items(.main_token)[w.index.get(bh.use).point];
            if (outs.items.len > 1) o.exactness = .approximate;
            return line;
        }
        // Exclusive: what the write relied on is the frame's to ask of its
        // callers; a condition that cannot hold refuses.
        if (relied.no) {
            refuse(o, .exclusive);
            o.exactness = .approximate;
            return line;
        }
        o.accepted = if (d.callback) .callback_param else ground;
        // What the aggregated holders added is in `req` from now on.
        for (done_holds.items) |x| try Kept.done(r, Kept.hold_event, x[0], x[1]);
        for (dones.items) |hi| try Kept.done(r, Kept.holder_event, hi, 0);
        try r.ops.writes.appendSlice(g, writes.items);
        if (r.aggregate) try r.stack.accept(r.ev(), d.pending, d.point, targets, Holders.paramTarget);
        line.extra = try relied.cond(r.ev().arena, r.account());
        r.e.ev.f.account.in_demands = false;
        return line;
    }

    /// Demand `d` judged, or its judgement of the round before taken again
    /// (§2.12, *judgements kept across rounds*); under the cross-check,
    /// judged and compared.
    fn judgeKept(r: *Resolver, d: Walk.Demand) Error!Line {
        const k = r.kept orelse return r.judge(d);
        const found = try k.find(r.e.w, d, r.e.contracts);
        const at = k.mark(r.ops.writes.items.len, r.stack.writes.items.len);
        if (found) |ri| if (!Kept.cross) return k.replay(r, d, ri, at);
        return k.judged(r, d, try r.judge(d), found, at);
    }

    /// A supplied leaf `t` judged as a write the callback may make, the
    /// call's other arguments its operands (§2.11.3) but `skip`: a passed-on
    /// label's own function value, which is no more an operand of its supply
    /// than a direct label's callee is of its arguments (its captures are
    /// asked apart by the label's condition).
    /// A supplied part `t` judged at a label's call. A part that comes
    /// partly from unknown code (a callback's answer: a fold's accumulator)
    /// is `unknown` whole, yet its known objects are still kept where they
    /// are held after the call: each is judged on its own (§2.11.3).
    fn judgeSupplied(r: *Resolver, t: u32, point: u32, inst: u32, args: []const u32, k: usize, skip: usize, pending: u32) Error!Line {
        const l = try r.judgeSuppliedLeaf(t, point, inst, args, k, skip, pending);
        if (l.outcome.verdict != .refused or l.outcome.cause != .unknown) return l;
        const fr = r.f();
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(r.gpa());
        var seen: Ids.FixedDict(1) = .{};
        defer seen.deinit(r.gpa());
        try stack.append(r.gpa(), t);
        while (stack.pop()) |x| {
            if ((try seen.getOrPut(r.gpa(), .{x})).found_existing) continue;
            const xl = fr.leafAt(x);
            switch (xl.kind) {
                .answer, .top, .host => continue,
                .ref => switch (fr.roots.items[xl.root].kind) {
                    .cb => continue,
                    .call, .supply => {
                        try r.ev().expand(x, &stack);
                        continue;
                    },
                    .param => {},
                },
                else => {},
            }
            const lb = try r.judgeSuppliedLeaf(x, point, inst, args, k, skip, pending);
            if (lb.outcome.verdict == .refused and lb.outcome.cause != .unknown) return lb;
        }
        return l;
    }

    fn judgeSuppliedLeaf(r: *Resolver, t: u32, point: u32, inst: u32, args: []const u32, k: usize, skip: usize, pending: u32) Error!Line {
        const w = r.e.w;
        const start: u32 = @intCast(w.leaf_runs.items.len);
        try w.leaf_runs.append(w.f.gpa, t);
        const o_start: u32 = @intCast(w.value_runs.items.len);
        for (args, 0..) |b, m| if (m != k and m != skip) try w.value_runs.append(w.f.gpa, b);
        return r.judge(.{ .point = point, .kind = .callsite, .token = 0, .base_inst = inst, .targets = .{ .start = start, .len = 1 }, .operands = .{ .start = o_start, .len = @intCast(w.value_runs.items.len - o_start) }, .pending = pending });
    }
};

/// Judge every demand of evaluation `e`; the lines in `arena` (null when
/// only the verdicts are wanted, during a fixed point).
pub fn resolve(e: *Eval.Evaluation, regions: *const Regions.Tree, arena: Allocator, kt: ?*Kept.Table) Error!Result {
    if (kt) |k| try k.begin(e.w.f.gpa, e.escapes.items);
    var r: Resolver = .{ .e = e, .arena = arena, .regions = regions, .kept = kt, .uses = .{ .w = e.w, .ev = &e.ev, .contracts = e.contracts, .regions = regions, .feet = if (kt) |k| &k.feet else null } };
    defer r.deinit();
    const f = &e.w.f;
    // Every judgement, in the walk's order: the demands, the direct labels'
    // supplied parts, the passed-on labels' parts (§2.11.3).
    const Job = struct { kind: enum { demand, cb, pass }, point: u32, i: u32, k: u32 = 0, t: u32 = none, at: u32 = 0, aj: u32 = 0, skip: usize = std.math.maxInt(usize), pending: u32 = none, judged: u32 = none };
    var jobs: std.ArrayList(Job) = .empty;
    const twins = try Twins.of(f.gpa, f.account, arena, e.w, e.demands.items);
    for (e.demands.items, twins, 0..) |d, tw, i| if (tw == none) try jobs.append(arena, .{ .kind = .demand, .point = d.point, .i = @intCast(i) });
    for (f.cbs.items, 0..) |cb, ci| {
        if (cb.inst == none) continue;
        for (cb.args, 0..) |a, k| {
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(f.gpa);
            try e.ev.leavesOf(a, 0, &ls);
            for (ls.items) |t| try jobs.append(arena, .{ .kind = .cb, .point = cb.point, .i = @intCast(ci), .k = @intCast(k), .t = t, .pending = cb.pending });
        }
    }
    // The passed-on labels: the part of a call's argument each callee
    // supply takes is what the callback may write, judged as a direct
    // label's argument is (§2.11.3): `apply f { f0 = a, f1 = a }` hands the
    // callback two names of one list.
    for (e.passes.items, 0..) |p, pi| {
        const call = f.calls.items[p[1]];
        const lab = e.contracts.labelsOf(e.contracts.head(call.contract).labels)[p[2]];
        for (e.contracts.suppliesOf(lab.supplies)) |su| {
            var es: Forest.Entries = .{};
            defer es.deinit(f.gpa);
            try es.of(&e.contracts.trees, f.gpa, f.places, su.res_root, &.{});
            for (es.items.items) |rs| for (rs.arrivals) |a| {
                if (a.kind != .param or a.j >= call.args.len) continue;
                const v = try e.ev.valueAt(call.args[a.j], f.slots.relWords(a.slot));
                var ls: std.ArrayList(Relation.Part) = .empty;
                defer ls.deinit(f.gpa);
                try Parts.of(&e.ev, v, es.wordsOf(rs), &ls);
                const pending = if (p[1] < e.w.sites.items.len) e.w.sites.items[p[1]].pending else none;
                const fd: Fed.Feed = .{ .j = f.cbs.items[p[0]].j, .slot = f.cbs.items[p[0]].slot, .label = p[2] };
                for (ls.items) |part| for (try Fed.judgedOf(r.ev(), part.leaf, fd, su.k)) |q| try jobs.append(arena, .{ .kind = .pass, .point = call.point, .i = @intCast(pi), .k = su.k, .t = part.leaf, .at = part.at, .aj = a.j, .skip = lab.j, .pending = pending, .judged = q });
            };
        }
    }
    // The indices are built only when something is judged (§2.8): a
    // declaration with no demand and no label pays for neither.
    if (jobs.items.len != 0) {
        try r.index();
        try r.escapes.build(r.ev(), &r.keys, regions, e.escapes.items);
    }
    // Judged in point order (the sweep, §2.8), kept in the walk's order.
    const order = try arena.alloc(u32, jobs.items.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u32, order, jobs.items, struct {
        fn lt(js: []const Job, a: u32, b: u32) bool {
            return js[a].point < js[b].point or (js[a].point == js[b].point and a < b);
        }
    }.lt);
    const got = try arena.alloc(Line, jobs.items.len);
    for (order) |ji| {
        const j = jobs.items[ji];
        try r.live.advance(r.ev(), j.point);
        got[ji] = switch (j.kind) {
            .demand => blk: {
                e.w.f.account.in_demands = true;
                r.aggregate = true;
                defer e.w.f.account.in_demands = false;
                defer r.aggregate = false;
                break :blk try r.judgeKept(e.demands.items[j.i]);
            },
            .cb => blk: {
                const cb = f.cbs.items[j.i];
                break :blk try r.judgeSupplied(j.t, cb.point, cb.inst, cb.args, j.k, j.skip, j.pending);
            },
            .pass => blk: {
                const call = f.calls.items[e.passes.items[j.i][1]];
                break :blk try r.judgeSupplied(j.judged, call.point, call.inst, call.args, j.aj, j.skip, j.pending);
            },
        };
    }
    const lines = try arena.alloc(Line, e.demands.items.len);
    // Each condition gathered over its judgements and made once (§2.9.4).
    var req: Holders.Gather = .{};
    // `req` lives in `arena`, as every later `add` to it does.
    try r.ops.finish(&e.ev, &r.keys, &req, arena);
    try r.stack.finish(&e.ev, e.w, regions, &req, arena);
    var kept: std.ArrayList([3]u32) = .empty;
    const width = SupplyCond.width(f, jobs.items);
    const conds = try arena.alloc(Holders.Gather, f.cbs.items.len * width);
    @memset(conds, .{});
    var pkept: std.ArrayList([4]u32) = .empty;
    const pconds = try arena.alloc(Holders.Gather, e.passes.items.len * width);
    @memset(pconds, .{});
    for (jobs.items, got) |j, l| switch (j.kind) {
        .demand => {
            lines[j.i] = l;
            if (l.outcome.verdict == .accepted) try req.addBoth(arena, f.account, l.demand.relies, l.extra);
        },
        .cb => switch (l.outcome.verdict) {
            .refused => if (l.outcome.cause != .unknown) try kept.append(arena, .{ j.i, j.k, j.t }),
            .accepted => try conds[j.i * width + j.k].addBoth(arena, f.account, l.demand.relies, l.extra),
        },
        .pass => switch (l.outcome.verdict) {
            .refused => if (l.outcome.cause != .unknown) try pkept.append(arena, .{ j.i, j.k, j.t, j.at }),
            .accepted => try pconds[j.i * width + j.k].addBoth(arena, f.account, l.demand.relies, l.extra),
        },
    };
    // A twin takes its first's verdict (§2.8, *Twin demands*).
    Twins.copy(lines, twins, e.demands.items);
    const cs = try arena.alloc(Cond, conds.len);
    for (conds, cs) |*x, *c| c.* = try x.cond(e.ev.arena, f.account);
    const ps = try arena.alloc(Cond, pconds.len);
    for (pconds, ps) |*x, *c| c.* = try x.cond(e.ev.arena, f.account);
    return .{ .lines = lines, .verdicts = .{ .req = try req.cond(e.ev.arena, f.account), .kept = kept.items, .supply_cond = cs, .width = @intCast(width), .pass_kept = pkept.items, .pass_cond = ps } };
}
