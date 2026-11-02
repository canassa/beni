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
const Eval = @import("Eval.zig");
const Walk = @import("Walk.zig");
const Liveness = @import("Liveness.zig");
const Regions = @import("Regions.zig");

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
    /// Locals by the roots and atoms of their values' leaves (the holder
    /// index): `(kind, root or atom, extra)` → a run of `cands`.
    by_key: Ids.FixedDict(3) = .{},
    cands: std.ArrayList(std.ArrayList(u32)) = .empty,
    /// Locals whose values reach an unknown object: candidates of every demand.
    anywhere: std.ArrayList(u32) = .empty,
    ancestry: Liveness.Ancestry = .{},

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
        r.by_key.deinit(r.gpa());
        for (r.cands.items) |*c| c.deinit(r.gpa());
        r.cands.deinit(r.gpa());
        r.anywhere.deinit(r.gpa());
        r.ancestry.deinit(r.gpa());
    }

    /// A leaf's base keys: the parameters, atoms and labels it comes from,
    /// through calls and supplies.
    fn baseKeys(r: *Resolver, li: u32, out: *std.ArrayList([3]u32), unknown: *bool) Error!void {
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(r.gpa());
        var seen: Ids.FixedDict(1) = .{};
        defer seen.deinit(r.gpa());
        try stack.append(r.gpa(), li);
        while (stack.pop()) |x| {
            if ((try seen.getOrPut(r.gpa(), .{x})).found_existing) continue;
            try r.f().charge(.inspection, 1);
            const l = r.f().leafAt(x);
            switch (l.kind) {
                .ref => {
                    const root = r.f().roots.items[l.root];
                    switch (root.kind) {
                        .param => try out.append(r.gpa(), .{ 0, root.a, 0 }),
                        .cb => unknown.* = true,
                        .call, .supply => {
                            var ls: std.ArrayList(u32) = .empty;
                            defer ls.deinit(r.gpa());
                            try r.ev().expand(x, &ls);
                            try stack.appendSlice(r.gpa(), ls.items);
                        },
                    }
                },
                .site => try out.append(r.gpa(), .{ 1, l.atom, 0 }),
                .fresh => try out.append(r.gpa(), .{ 2, l.atom, 0 }),
                .shared => try out.append(r.gpa(), .{ 3, l.atom, l.extra }),
                .answer, .top => unknown.* = true,
                .recons => unreachable,
            }
        }
    }

    /// The holder index (§2.8): every bound local, by its value's base keys.
    fn index(r: *Resolver) Error!void {
        const w = r.e.w;
        for (w.bindings, 0..) |b, local| {
            if (b.value == none) continue;
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(r.gpa());
            try r.ev().leavesOf(b.value, 0, &ls);
            var keys: std.ArrayList([3]u32) = .empty;
            defer keys.deinit(r.gpa());
            var unknown = false;
            for (ls.items) |l| try r.baseKeys(l, &keys, &unknown);
            if (unknown) {
                try r.anywhere.append(r.gpa(), @intCast(local));
                continue;
            }
            for (keys.items) |k| {
                try r.f().charge(.edge, 1);
                const got = try r.by_key.getOrPut(r.gpa(), k);
                if (!got.found_existing) {
                    got.value_ptr.* = @intCast(r.cands.items.len);
                    try r.cands.append(r.gpa(), .empty);
                }
                const list = &r.cands.items[got.value_ptr.*];
                if (list.items.len == 0 or list.items[list.items.len - 1] != local) try list.append(r.gpa(), @intCast(local));
            }
        }
    }

    /// The locals that may hold one of `targets`, sorted and once each.
    fn candidates(r: *Resolver, targets: []const u32, out: *std.ArrayList(u32)) Error!void {
        var keys: std.ArrayList([3]u32) = .empty;
        defer keys.deinit(r.gpa());
        var unknown = false;
        for (targets) |t| try r.baseKeys(t, &keys, &unknown);
        try out.appendSlice(r.gpa(), r.anywhere.items);
        if (unknown) {
            for (r.e.w.bindings, 0..) |b, l| if (b.value != none) try out.append(r.gpa(), @intCast(l));
        } else for (keys.items) |k| {
            if (r.by_key.get(k)) |c| try out.appendSlice(r.gpa(), r.cands.items[c].items);
            // A parameter's object may be held through another parameter.
            if (k[0] == 0) {
                var it: usize = 0;
                while (it < r.by_key.count()) : (it += 1) {
                    const key = r.by_key.keyAt(@intCast(it));
                    if (key[0] == 0 and key[1] != k[1]) try out.appendSlice(r.gpa(), r.cands.items[r.by_key.values.items[it]].items);
                }
            }
        }
        std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
        var n: usize = 0;
        for (out.items) |x| {
            if (n != 0 and out.items[n - 1] == x) continue;
            out.items[n] = x;
            n += 1;
        }
        out.shrinkRetainingCapacity(n);
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
        const rw = fr.slots.relWords(rem);
        for (r.e.contracts.effectsOf(h.reads)) |x| {
            if (x.j != foot[1]) continue;
            const sw = fr.slots.relWords(x.slot);
            if (sw.len <= rw.len and std.mem.eql(u32, sw, rw[0..sw.len]) and (x.deep or sw.len == rw.len)) return true;
            if (rw.len < sw.len and std.mem.eql(u32, rw, sw[0..rw.len])) return true;
        }
        for (r.e.contracts.effectsOf(h.writes)) |x| if (x.j == foot[1]) {
            const sw = fr.slots.relWords(x.slot);
            const n = @min(sw.len, rw.len);
            if (std.mem.eql(u32, sw[0..n], rw[0..n])) return true;
        };
        return false;
    }

    /// Whether an escape before `point` reaches a target.
    fn escaped(r: *Resolver, t: u32, point: u32, call: u32, relied: *Cond) Error!bool {
        for (r.e.escapes.items) |x| {
            if (x.point > point) continue;
            // What a callee keeps of the value its own write takes (`Ref.set`
            // storing what it consumes) is that write's own business.
            if (call != none and x.call == call) continue;
            if (x.point != point and !r.regions.compatible(x.point, point)) continue;
            const o = try Distinct.overlap(r.ev(), x.leaf, t, false);
            switch (o.kind) {
                .no => {},
                .under => relied.* = try Cond.conj(r.ev().arena, r.account(), relied.*, o.cond),
                .may => return true,
            }
        }
        return false;
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
        // Known, and the ground: what the targets come from.
        var base: std.ArrayList([3]u32) = .empty;
        defer base.deinit(g);
        var unknown = false;
        for (targets) |t| try r.baseKeys(t, &base, &unknown);
        if (unknown or targets.len == 0) {
            refuse(o, .unknown);
            if (targets.len != 0) o.exactness = .approximate;
            return line;
        }
        // The ground is what the targets come from (R-7.15): a parameter's
        // object relies on the callers, anything this activation allocated
        // (here or in a callee) is fresh.
        var ground: Facts.Verdict.Accepted = .fresh;
        for (base.items) |k| switch (k[0]) {
            0 => ground = .param,
            3 => {
                refuse(o, .top_level);
                o.exactness = .position;
                o.shared = .{ k[1], k[2] };
                return line;
            },
            else => {},
        };
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
    const lines = try arena.alloc(Line, e.demands.items.len);
    var req: Cond = .{};
    for (e.demands.items, lines) |d, *l| {
        e.w.f.account.in_demands = true;
        defer e.w.f.account.in_demands = false;
        l.* = try r.judge(d);
        if (l.outcome.verdict == .accepted) req = try Cond.conj(e.ev.arena, e.w.f.account, req, l.demand.relies);
    }
    // The direct labels' kept slots and their supplies' condition.
    const f = &e.w.f;
    var kept: std.ArrayList([3]u32) = .empty;
    const conds = try arena.alloc(Cond, f.cbs.items.len);
    @memset(conds, .{});
    for (f.cbs.items, 0..) |cb, ci| {
        if (cb.inst == none) continue;
        for (cb.args, 0..) |a, k| {
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(f.gpa);
            try e.ev.leavesOf(a, 0, &ls);
            for (ls.items) |t| {
                const l = try r.judgeSupplied(t, cb.point, cb.inst, cb.args, k, std.math.maxInt(usize), cb.pending);
                switch (l.outcome.verdict) {
                    .refused => if (l.outcome.cause != .unknown) try kept.append(arena, .{ @intCast(ci), @intCast(k), t }),
                    .accepted => conds[ci] = try Cond.conj(e.ev.arena, f.account, conds[ci], l.demand.relies),
                }
            }
        }
    }
    // The passed-on labels: the part of a call's argument each callee
    // supply takes is what the callback may write, judged as a direct
    // label's argument is (§2.11.3): `apply f { f0 = a, f1 = a }` hands the
    // callback two names of one list.
    var pkept: std.ArrayList([4]u32) = .empty;
    const pconds = try arena.alloc(Cond, e.passes.items.len);
    @memset(pconds, .{});
    for (e.passes.items, 0..) |p, pi| {
        const call = f.calls.items[p[1]];
        const lab = e.contracts.labelsOf(e.contracts.head(call.contract).labels)[p[2]];
        for (e.contracts.suppliesOf(lab.supplies)) |su| for (e.contracts.resOf(su.res)) |rs| for (e.contracts.arrivalsOf(rs.arrivals)) |a| {
            if (a.kind != .param or a.j >= call.args.len) continue;
            const v = try e.ev.valueAt(call.args[a.j], f.slots.relWords(a.slot));
            var ls: std.ArrayList(Relation.Part) = .empty;
            defer ls.deinit(f.gpa);
            try e.ev.partsOf(v, f.slots.relWords(rs.slot), &ls);
            for (ls.items) |part| {
                const pending = if (p[1] < e.w.sites.items.len) e.w.sites.items[p[1]].pending else Ids.Range{};
                const l = try r.judgeSupplied(part.leaf, call.point, call.inst, call.args, a.j, lab.j, pending);
                switch (l.outcome.verdict) {
                    .refused => if (l.outcome.cause != .unknown) try pkept.append(arena, .{ @intCast(pi), su.k, part.leaf, part.at }),
                    .accepted => pconds[pi] = try Cond.conj(e.ev.arena, f.account, pconds[pi], l.demand.relies),
                }
            }
        };
    }
    return .{ .lines = lines, .verdicts = .{ .req = req, .kept = kept.items, .supply_cond = conds, .pass_kept = pkept.items, .pass_cond = pconds } };
}
