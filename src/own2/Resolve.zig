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
const Contract = @import("Contract.zig");
const Forest = @import("Forest.zig");
const Eval = @import("Eval.zig");
const Walk = @import("Walk.zig");
const Liveness = @import("Liveness.zig");
const Regions = @import("Regions.zig");
const Holders = @import("Holders.zig");

pub const Error = Ids.ChargeError;
const Cond = Contract.Cond;
const PathId = Ids.PathId;
const none: u32 = Ids.none_int;
const debug = false;

pub const HolderKind = enum(u8) { binding, pending };

/// The holder a refusal names: a local (`who`) or a pending operand (its
/// instruction's token).
pub const Holder = struct { kind: HolderKind, who: u32, token: u32 };

/// A demand's verdict (R-0.3) with what `Message` says of it.
pub const Outcome = struct {
    verdict: enum(u8) { accepted, refused } = .accepted,
    accepted: Facts.Verdict.Accepted = .fresh,
    cause: Facts.Cause = .unknown,
    exactness: Facts.Exactness = .exact,
    holder_path: PathId = .none,
    other_paths: bool = false,
    /// `top_level`: the value's `(module, declaration)`.
    shared: [2]u32 = .{ none, none },
};

/// One verdict line: the demand, its outcome, the holder and the use.
pub const Line = struct {
    demand: Walk.Demand,
    outcome: Outcome,
    holder: ?Holder = null,
    use_token: u32 = none,
};

pub const Result = struct {
    lines: []Line,
    verdicts: Eval.Verdicts,
};

const Resolver = struct {
    e: *Eval.Evaluation,
    arena: Allocator,
    regions: *const Regions.Tree,
    /// The holder index and its sweep (§2.8): locals by their values' base
    /// keys, live while the sweep's point is between their binding and last use.
    live: Holders.Live = .{},
    ancestry: Liveness.Ancestry = .{},
    /// Each leaf's base keys and the escape index (§2.8).
    keys: Holders.Keys = .{},
    escapes: Holders.Escapes = .{},

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
    }

    /// The base keys of `targets` (§2.8, *Base keys*): their runs, joined.
    fn keysOf(r: *Resolver, targets: []const u32, out: *std.ArrayList([3]u32), unknown: *bool) Error!void {
        for (targets) |t| {
            const ks = try r.keys.of(r.ev(), t);
            try out.appendSlice(r.gpa(), ks.keys);
            unknown.* = unknown.* or ks.unknown;
        }
    }

    /// The holder index (§2.8): every bound local that is used after its
    /// binding; keyed by its value's base keys only when a demand first
    /// meets it live (`candidates`).
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

    /// The live locals that may hold an object of `targets` (§2.8, *The
    /// holder index and its sweep*): the live holders not keyed yet keyed
    /// first, by their values' leaves' base keys.
    fn candidates(r: *Resolver, targets: []const u32, out: *std.ArrayList(u32)) Error!void {
        if (!r.live.any()) return;
        const g = r.gpa();
        var keys: std.ArrayList([3]u32) = .empty;
        defer keys.deinit(g);
        while (r.live.takeUnkeyed()) |hi| {
            const b = r.e.w.bindings[r.live.holders.items[hi].local];
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(g);
            try r.ev().leavesOf(b.value, 0, &ls);
            keys.clearRetainingCapacity();
            var unknown = false;
            try r.keysOf(ls.items, &keys, &unknown);
            try r.live.key(r.ev(), hi, try sortedKeys(&keys), unknown);
        }
        keys.clearRetainingCapacity();
        var unknown = false;
        try r.keysOf(targets, &keys, &unknown);
        try r.live.candidates(r.ev(), try sortedKeys(&keys), out);
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

    /// The paths at which local `h`'s value holds an object `target` may
    /// be, and the relation there: each `(path, ov)`.
    fn holds(r: *Resolver, h: u32, target: u32, out: *std.ArrayList(struct { PathId, Relation.Ov })) Error!void {
        const fr = r.f();
        const g = r.gpa();
        const b = r.e.w.bindings[h];
        const root = try fr.places.rootPath(g, try r.e.ctx.placeOfLocal(r.e.ctx.ctx, h));
        const Item = struct { v: u32, q: PathId, tags: u32 };
        var stack: std.ArrayList(Item) = .empty;
        defer stack.deinit(g);
        try stack.append(g, .{ .v = b.value, .q = root, .tags = 0 });
        while (stack.pop()) |it| {
            try fr.charge(.inspection, 1);
            const x = fr.val(it.v);
            switch (x.kind) {
                .scalar, .bot => {},
                .alt => {
                    const ks = fr.kidsOf(x);
                    var i: usize = 0;
                    while (i < ks.len) : (i += 2) {
                        const t = (try fr.mergeTags(it.tags, try fr.internTags(&.{.{ x.head, try fr.armOf(ks[i]) }}))) orelse continue;
                        try stack.append(g, .{ .v = ks[i + 1], .q = it.q, .tags = t });
                    }
                },
                .built => {
                    var own: std.ArrayList(u32) = .empty;
                    defer own.deinit(g);
                    try r.ev().storageOf(it.v, it.tags, &own);
                    for (own.items) |l| {
                        const o = try Distinct.overlap(r.ev(), l, target, true);
                        if (o.kind != .no) try out.append(g, .{ it.q, o });
                    }
                    for (fr.kidsOf(x), 0..) |kv, n| {
                        const st: ?Place.Step = switch (x.form) {
                            .tuple => try Place.Step.index(fr.account, @intCast(n)),
                            .ctor => try fr.places.ctorStep(g, fr.account, x.head, @intCast(n)),
                            .list => Place.Step.elem,
                            .record => try Place.Step.field(fr.account, fr.wordsOf(x.extra)[n]),
                            .closure, .opaque_ => null,
                        };
                        const nq = if (st) |s| (try fr.places.extend(g, fr.gc(), it.q, s)) orelse it.q else it.q;
                        try stack.append(g, .{ .v = kv, .q = nq, .tags = it.tags });
                    }
                },
                .ref, .top, .shared => {
                    var ls: std.ArrayList(u32) = .empty;
                    defer ls.deinit(g);
                    try r.ev().leavesOf(it.v, it.tags, &ls);
                    for (ls.items) |l| {
                        const o = try Distinct.overlap(r.ev(), l, target, true);
                        if (o.kind == .no) continue;
                        // The path of the hold: below `q` by the steps from the
                        // leaf's position to the slots that meet the target's.
                        const lf = fr.leafAt(l);
                        // The target as leaves of the holder's root: itself,
                        // or what a call's leaf comes from (its arrivals).
                        var tls: std.ArrayList(u32) = .empty;
                        defer tls.deinit(g);
                        try r.sameRoot(lf, target, &tls);
                        if (lf.kind == .ref and tls.items.len != 0 and x.family == Slots.empty) {
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
                                try Slots.replay(g, fr.account, fr.places, it.q, fr.slots.relWords(rel), &ps);
                                for (ps.items) |p| {
                                    try out.append(g, .{ .from(p), o });
                                    any = true;
                                }
                            };
                            if (any) {
                                // The holder's other objects are the target
                                // only where its root is not separated: held
                                // at the holder's path, under that condition.
                                var minus: std.ArrayList(u32) = .empty;
                                defer minus.deinit(g);
                                for (tls.items) |tli| try minus.append(g, fr.leafAt(tli).slots);
                                if (try Subtree.without(fr.slots, g, fr.account, fr.places, lf.slots, minus.items)) |rest| {
                                    var rl = lf;
                                    rl.slots = rest;
                                    const o2 = try Distinct.overlap(r.ev(), try fr.leaf(rl), target, true);
                                    if (o2.kind != .no) try out.append(g, .{ it.q, o2 });
                                }
                                continue;
                            }
                        }
                        try out.append(g, .{ it.q, o });
                    }
                },
            }
        }
    }

    /// The leaves of target `t` at the holder leaf `lf`'s root: `t`
    /// itself when it is of that root, else, while it is a call's or a
    /// supply's, what it comes from (§2.9.2 step 4), a few levels deep.
    fn sameRoot(r: *Resolver, lf: Value.Leaf, t: u32, out: *std.ArrayList(u32)) Error!void {
        const fr = r.f();
        const g = r.gpa();
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
                if (k == .call or k == .supply) try r.ev().expand(x, &next);
            }
            std.mem.swap(std.ArrayList(u32), &cur, &next);
        }
    }

    /// The first use of local `h` after `point`, compatible with it, that
    /// reads the hold at `q` (at an ancestor, at `q`, or below it), through
    /// call uses' footprints.
    fn liveAt(r: *Resolver, h: u32, q: PathId, point: u32) Error!?Liveness.UseId {
        const w = r.e.w;
        const fr = r.f();
        const g = r.gpa();
        if (w.index.lastUse(h) == none or w.index.lastUse(h) <= point) return null;
        const Ctx = struct { r: *Resolver, q: PathId };
        var c: Ctx = .{ .r = r, .q = q };
        const filter: Liveness.Filter = .{ .ctx = &c, .accept = struct {
            fn accept(ctx: *anyopaque, u: Facts.Use, _: Liveness.UseId) Error!bool {
                const k: *Ctx = @ptrCast(@alignCast(ctx));
                return k.r.footprintReads(u, k.q);
            }
        }.accept };
        const charge: Ids.Charge = .growth(fr.account);
        var best: ?Liveness.UseId = try w.index.useAfter(g, charge, fr.places, r.regions, h, q, point, filter);
        if (try w.index.useUnder(g, charge, fr.places, r.regions, h, q, point, filter)) |u| {
            if (best == null or w.index.get(u).point < w.index.get(best.?).point) best = u;
        }
        // A deep read whose levels fold above it (§2.7, a read on a cycle).
        if (fr.places.onCycle(fr.places.pathPlace(q)) or fr.places.pathParent(q) != .none) {
            const run = if (h < w.index.by_local.len) w.index.by_local[h] else Ids.Range{};
            var i: u32 = 0;
            while (i < run.len) : (i += 1) {
                const id = run.start + i;
                const u = w.index.get(.from(id));
                if (u.point <= point or !r.regions.compatible(point, u.point)) continue;
                if (u.kind == .call and u.use_node != .none) continue;
                const ups = try fr.places.foldsUp(g, charge, u.path);
                var k: u32 = 0;
                while (k < ups.len) : (k += 1) {
                    const up = fr.places.foldPath(ups.start + k);
                    if (fr.places.isPrefix(up, q)) {
                        if (best == null or u.point < w.index.get(best.?).point) best = .from(id);
                        break;
                    }
                }
            }
        }
        return best;
    }

    /// Whether a use reads the hold at `q` (§2.7): a whole or field use does;
    /// a call use does where its callee's footprint reaches `q`.
    fn footprintReads(r: *Resolver, u: Facts.Use, q: PathId) Error!bool {
        if (u.kind != .call or u.use_node == .none) return true;
        const fr = r.f();
        const g = r.gpa();
        const foot = r.e.w.foots.items[u.use_node.int()];
        const call = fr.calls.items[foot[0]];
        if (call.contract == none) return true;
        const h = r.e.contracts.head(call.contract);
        const rem = (try fr.slots.relBelow(g, fr.account, fr.places, u.path, q)) orelse return true;
        // The reads by the callee's tree a parameter, the writes by binary
        // search over its sorted effects (§2.7), each charged.
        const rw = fr.slots.relWords(rem);
        try fr.charge(.inspection, @intCast(rw.len + 1));
        for (r.e.contracts.readsOf(h.reads)) |x| if (x[0] == foot[1] and Forest.effectReaches(&r.e.contracts.trees, x[1], rw)) return true;
        return Holders.effectMeets(r.ev(), r.e.contracts, h.writes, foot[1], fr.slots.relKey(rem), false);
    }

    /// Whether an escape before `point` reaches a target.
    /// Whether an escape before `point` reaches a target (§2.8, *The
    /// escape index*).
    fn escaped(r: *Resolver, t: u32, point: u32, call: u32, relied: *Cond) Error!bool {
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
        var line: Line = .{ .demand = d, .outcome = .{} };
        const o = &line.outcome;
        const targets = w.leavesOfRun(d.targets);
        // Known, and the ground: what the targets come from, by their facts
        // (§2.8, *Base keys*).
        var fx: Holders.Facts = .{};
        for (targets) |t| {
            const tf = try r.keys.factsOf(r.ev(), t);
            fx.unknown = fx.unknown or tf.unknown;
            fx.param = fx.param or tf.param;
            if (std.mem.order(u32, &tf.shared, &fx.shared) == .lt) fx.shared = tf.shared;
        }
        if (fx.unknown or targets.len == 0) {
            refuse(o, .unknown);
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
        var relied: Cond = d.relies;
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
        for (w.valuesOfRun(d.operands)) |v| {
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(g);
            try r.ev().leavesOf(v, 0, &ls);
            for (ls.items) |l| for (targets) |t| {
                const ov = try Distinct.overlap(r.ev(), l, t, true);
                switch (ov.kind) {
                    .no => {},
                    .under => relied = try Cond.conj(r.ev().arena, r.account(), relied, ov.cond),
                    .may => {
                        refuse(o, .disjoint);
                        return line;
                    },
                }
            };
        }
        // A kept supply written by a known code.
        if (d.kept or d.many) {
            refuse(o, if (d.many) .once else .call);
            return line;
        }
        // Dead: the pending operands, then the live locals.
        for (w.pendingOfRun(d.pending)) |p| {
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(g);
            try r.ev().leavesOf(p.value, 0, &ls);
            for (ls.items) |l| for (targets) |t| {
                const ov = try Distinct.overlap(r.ev(), l, t, true);
                switch (ov.kind) {
                    .no => {},
                    .under => {
                        if (debug) std.debug.print("  pending {d} under {any}\n", .{ p.inst, ov.cond.sel });
                        relied = try Cond.conj(r.ev().arena, r.account(), relied, ov.cond);
                    },
                    .may => {
                        refuse(o, .held_operand);
                        line.holder = .{ .kind = .pending, .who = p.inst, .token = w.bir.insts.items(.main_token)[p.inst] };
                        return line;
                    },
                }
            };
        }
        var cands: std.ArrayList(u32) = .empty;
        defer cands.deinit(g);
        try r.candidates(targets, &cands);
        const base_local: u32 = if (w.bir.instTag(@fromBackingInt(d.base_inst)) == .local) w.bir.instData(@fromBackingInt(d.base_inst)).lhs else none;
        var best: ?struct { h: u32, use: Liveness.UseId, q: PathId, exact: bool } = null;
        for (cands.items) |h| {
            const b = w.bindings[h];
            if (b.point == none or b.point >= d.point) continue;
            if (w.index.lastUse(h) == none or w.index.lastUse(h) <= d.point) continue;
            for (targets) |t| {
                var hs: std.ArrayList(struct { PathId, Relation.Ov }) = .empty;
                defer hs.deinit(g);
                try r.holds(h, t, &hs);
                for (hs.items) |x| {
                    const u = (try r.liveAt(h, x[0], d.point)) orelse continue;
                    switch (x[1].kind) {
                        .no => {},
                        .under => relied = try Cond.conj(r.ev().arena, r.account(), relied, x[1].cond),
                        .may => {
                            const up = w.index.get(u).point;
                            if (best == null or up < w.index.get(best.?.use).point or (up == w.index.get(best.?.use).point and h < best.?.h)) best = .{ .h = h, .use = u, .q = x[0], .exact = true };
                        },
                    }
                }
            }
        }
        if (best) |bh| {
            const clos = fr.val(w.bindings[bh.h].value);
            refuse(o, if (bh.h == base_local) .later_use else if (clos.kind == .built and clos.form == .closure) .captured else .alias);
            o.holder_path = bh.q;
            line.holder = .{ .kind = .binding, .who = bh.h, .token = w.bindings[bh.h].token };
            line.use_token = w.bir.insts.items(.main_token)[w.index.get(bh.use).point];
            if (targets.len > 1) o.exactness = .approximate;
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
        r.e.ev.f.account.in_demands = false;
        line.demand.relies = relied;
        return line;
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
    fn judgeSupplied(r: *Resolver, t: u32, point: u32, inst: u32, args: []const u32, k: usize, skip: usize, pending: Ids.Range) Error!Line {
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
                .answer, .top => continue,
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

    fn judgeSuppliedLeaf(r: *Resolver, t: u32, point: u32, inst: u32, args: []const u32, k: usize, skip: usize, pending: Ids.Range) Error!Line {
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
pub fn resolve(e: *Eval.Evaluation, regions: *const Regions.Tree, arena: Allocator) Error!Result {
    var r: Resolver = .{ .e = e, .arena = arena, .regions = regions };
    defer r.deinit();
    try r.index();
    try r.escapes.build(r.ev(), &r.keys, regions, e.escapes.items);
    const f = &e.w.f;
    // Every judgement, in the walk's order: the demands, the direct labels'
    // supplied parts, the passed-on labels' parts (§2.11.3).
    const Job = struct { kind: enum { demand, cb, pass }, point: u32, i: u32, k: u32 = 0, t: u32 = none, at: u32 = 0, aj: u32 = 0, skip: usize = std.math.maxInt(usize), pending: Ids.Range = .{} };
    var jobs: std.ArrayList(Job) = .empty;
    for (e.demands.items, 0..) |d, i| try jobs.append(arena, .{ .kind = .demand, .point = d.point, .i = @intCast(i) });
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
                try e.ev.partsOf(v, es.wordsOf(rs), &ls);
                const pending = if (p[1] < e.w.sites.items.len) e.w.sites.items[p[1]].pending else Ids.Range{};
                for (ls.items) |part| try jobs.append(arena, .{ .kind = .pass, .point = call.point, .i = @intCast(pi), .k = su.k, .t = part.leaf, .at = part.at, .aj = a.j, .skip = lab.j, .pending = pending });
            };
        }
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
                defer e.w.f.account.in_demands = false;
                break :blk try r.judge(e.demands.items[j.i]);
            },
            .cb => blk: {
                const cb = f.cbs.items[j.i];
                break :blk try r.judgeSupplied(j.t, cb.point, cb.inst, cb.args, j.k, j.skip, j.pending);
            },
            .pass => blk: {
                const call = f.calls.items[e.passes.items[j.i][1]];
                break :blk try r.judgeSupplied(j.t, call.point, call.inst, call.args, j.aj, j.skip, j.pending);
            },
        };
    }
    const lines = try arena.alloc(Line, e.demands.items.len);
    var req: Cond = .{};
    var kept: std.ArrayList([3]u32) = .empty;
    const conds = try arena.alloc(Cond, f.cbs.items.len);
    @memset(conds, .{});
    var pkept: std.ArrayList([4]u32) = .empty;
    const pconds = try arena.alloc(Cond, e.passes.items.len);
    @memset(pconds, .{});
    for (jobs.items, got) |j, l| switch (j.kind) {
        .demand => {
            lines[j.i] = l;
            if (l.outcome.verdict == .accepted) req = try Cond.conj(e.ev.arena, f.account, req, l.demand.relies);
        },
        .cb => switch (l.outcome.verdict) {
            .refused => if (l.outcome.cause != .unknown) try kept.append(arena, .{ j.i, j.k, j.t }),
            .accepted => conds[j.i] = try Cond.conj(e.ev.arena, f.account, conds[j.i], l.demand.relies),
        },
        .pass => switch (l.outcome.verdict) {
            .refused => if (l.outcome.cause != .unknown) try pkept.append(arena, .{ j.i, j.k, j.t, j.at }),
            .accepted => pconds[j.i] = try Cond.conj(e.ev.arena, f.account, pconds[j.i], l.demand.relies),
        },
    };
    return .{ .lines = lines, .verdicts = .{ .req = req, .kept = kept.items, .supply_cond = conds, .pass_kept = pkept.items, .pass_cond = pconds } };
}
