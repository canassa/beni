//! L7: demands and the check (`docs/design/ownership-v2.md` §2.8). A demand
//! is a write the walk met — a writer call, a construction, a `++` chain, a
//! deep consumption — at a point, on a base value; this file resolves each
//! one against six conditions in R-4.3.6's order:
//!
//! 1. **Known**: no `⊤` among the base's cells (`unknown`).
//! 2. **Unescaped**: no cell, nor a trie ancestor of it (nor, for a deep
//!    demand, a descendant), escaped at a compatible point before; no
//!    `shared` cell (`top-level`).
//! 3. **Not captured**: S4's (closures).
//! 4. **Disjoint**: no other operand reaches a cell of the base.
//! 5. **Dead**: no pending operand holds it (`held-operand`); no live holder
//!    is used after the point, compatibly, at an overlapping path
//!    (`later-use` the base's own variable, `alias` another, `element` when
//!    the holder holds it only at a summary position). The holder index
//!    (`Holders`, §2.8 *The holder index*) answers every demand of the
//!    frame at once, offline.
//! 6. **Exclusive**: what passed only *under* a split rests on the split's
//!    κ: `yes` passes, atoms are the frame's `xreq`, a failure is
//!    `exclusive`.
//!
//! Every record is reserved on the owner's account before its work (§4.1).
//!
//! Obligations kept here: O8's demand half (a write is blocked by an
//! escaped ancestor-or-self, a deep demand also by a descendant), and I-κ's
//! use (an answer that rests on a split relies on its κ).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Cell = @import("Cell.zig");
const Cond = @import("Cond.zig");
const Summary = @import("Summary.zig");
const Holders = @import("Holders.zig");
const stamped = @import("../stamped.zig");

pub const NodeId = Ids.NodeId;
pub const CellId = Ids.CellId;
pub const SetId = Ids.SetId;
pub const PathId = Ids.PathId;
pub const CondId = Ids.CondId;
pub const UseId = Ids.UseId;
pub const Kappas = Cond.Kappas;
pub const Env = Summary.Env;
pub const Error = Ids.ChargeError;
pub const none: u32 = Ids.none_int;

pub const Value = Holders.Value;
pub const Demand = Holders.Demand;
pub const Operand = Holders.Operand;
pub const HolderKind = Holders.HolderKind;
pub const Holder = Holders.Holder;
pub const Taken = Holders.Taken;
pub const Escape = Holders.Escape;
pub const Frame = Holders.Frame;

/// A resolved demand: its verdict and what the message names.
pub const Outcome = struct {
    verdict: Kind,
    accepted: Facts.Verdict.Accepted = .fresh,
    cause: Facts.Cause = .unknown,
    exactness: Facts.Exactness = .exact,
    /// The holder named: a `Holder` index, or `none`.
    holder: u32 = none,
    /// Where the holder holds it, a path under its local's root.
    holder_path: PathId = .none,
    /// The holder's later use.
    use: UseId = .none,
    /// `top_level`: the shared cell; `escaped`: the point it escaped at.
    cell: CellId = .none,
    /// The atoms the acceptance relies on (a set in `Cond.atoms`).
    xreq: SetId = .none,

    pub const Kind = enum(u8) { accepted, refused };
};

/// A step's slot (§4.4 *holder and callee path words*): the demanded value's
/// own path, or the path a holder holds it at.
const StepSlot = enum(u1) { base, holder };

/// The kernel of demand `atom`'s step `path` (§2.8, §4.4's `(written demand,
/// slot, k)` words on direct-demand-query lanes, `k` the step's depth): the
/// prefix work at one step of a path (its escape) is that step's, never the
/// demand's whole lane (#1225). Null at a root path, outside a demand's
/// query, or when the query is already growth (a product): there the step's
/// work is the growth task's, never piled onto one lane per step (#1233's
/// review).
fn stepLane(env: Env, gpa: Allocator, atom: ?u32, slot: StepSlot, path: PathId) Error!?Ids.Account.Kernel {
    const a = atom orelse return null;
    if (path == .none or env.places.pathParent(path) == .none) return null;
    if (env.account().inGrowth()) return null;
    return try env.account().enter(gpa, .{ .atom = a, .role = .direct_demand_query, .step = stepWord(slot, env.places.pathDepth(path)) });
}

/// A step lane's word: its slot and its depth `k` (§4.4).
fn stepWord(slot: StepSlot, depth: u32) u32 {
    return (@as(u32, @backingInt(slot)) << 28) | depth;
}

/// `stepLane` of a cell's canonical path, for a symbolic cell; null for any
/// other, whose work stays the demand's.
fn cellLane(env: Env, gpa: Allocator, atom: ?u32, c: CellId) Error!?Ids.Account.Kernel {
    const x = env.cells.get(c);
    if (!x.origin.isSymbolic() or x.origin == .top) return null;
    return stepLane(env, gpa, atom, .base, .from(x.b));
}

fn leaveLane(env: Env, k: ?Ids.Account.Kernel) void {
    if (k) |kk| env.account().leave(kk);
}

const Resolver = struct {
    gpa: Allocator,
    env: Env,
    frame: Frame,
    /// Escapes: per cell, a run of points (`esc_points`).
    esc: stamped.Column(CellId, Ids.Range) = .{},
    esc_points: std.ArrayList(u32) = .empty,
    /// Per point of a run, the run prefix's point of least rank₂.
    esc_low: std.ArrayList(u32) = .empty,
    /// The demand being resolved's atom (its base's instruction), whose step
    /// lanes its path work goes on (`stepLane`, #1225).
    atom: ?u32 = null,

    fn deinit(r: *Resolver) void {
        r.esc.deinit(r.gpa);
        r.esc_points.deinit(r.gpa);
        r.esc_low.deinit(r.gpa);
    }

    fn reach(r: *Resolver, n: NodeId) Error!SetId {
        return r.env.shapes.reach(r.gpa, r.env.account(), &r.env.cells.sets, n);
    }

    /// Every cell of every escaped value, with the point it escaped at:
    /// escape is deep, so `reach` (§2.4).
    fn buildEscapes(r: *Resolver) Error!void {
        // Every (cell, point) as one word, sorted: each cell's points are one
        // run in point order, beside each the run prefix's point of least
        // rank₂ (`esc_low`), so `escapedAt` is one binary search (#1226).
        var pairs: std.ArrayList(u64) = .empty;
        defer pairs.deinit(r.gpa);
        for (r.frame.escapes) |e| {
            var it = r.env.cells.sets.iterate(try r.reach(e.node));
            while (it.next()) |x| {
                try r.env.charge.reserve(r.gpa, .inspection, 1);
                try pairs.append(r.gpa, @as(u64, x.key) << 32 | e.point);
            }
        }
        try r.env.charge.reserve(r.gpa, .inspection, @intCast(pairs.items.len * (std.math.log2_int_ceil(usize, pairs.items.len + 1) + 1)));
        std.mem.sort(u64, pairs.items, {}, std.sort.asc(u64));
        try r.esc_points.resize(r.gpa, pairs.items.len);
        try r.esc_low.resize(r.gpa, pairs.items.len);
        for (pairs.items, 0..) |q, i| {
            const pt: u32 = @truncate(q);
            const got = try r.esc.getOrPut(r.gpa, .from(@intCast(q >> 32)));
            if (!got.found_existing) got.value_ptr.* = .{ .start = @intCast(i), .len = 0 };
            got.value_ptr.len += 1;
            r.esc_points.items[i] = pt;
            const low = if (got.value_ptr.len == 1) pt else r.esc_low.items[i - 1];
            r.esc_low.items[i] = if (r.frame.regions.rank2(pt) < r.frame.regions.rank2(low)) pt else low;
        }
    }

    /// The point `c` escaped at before `p`, compatibly, or null. For e < p,
    /// compatible ⇔ rank₂(e) < rank₂(p) (§2.5): the least rank₂ before `p`
    /// decides, by a binary search charged as growth (#1226), never a scan.
    fn escapedAt(r: *Resolver, c: CellId, p: u32) Error!?u32 {
        const run = r.esc.get(c) orelse return null;
        // One point is one test, which the caller's step already paid for;
        // a longer run's search is as large as the run, so growth chosen
        // before it, never the demand's fixed lane (§4.1).
        const task: ?Ids.Account.Kernel = if (run.len > 1) try r.env.account().enter(r.gpa, null) else null;
        defer if (task) |k| r.env.account().leave(k);
        if (task != null) try r.env.charge.reserve(r.gpa, .inspection, std.math.log2_int_ceil(u32, run.len + 1) + 1);
        const prior = std.sort.partitionPoint(u32, r.esc_points.items[run.start..][0..run.len], p, struct {
            fn below(bound: u32, e: u32) bool {
                return e < bound;
            }
        }.below);
        if (prior == 0) return null;
        const e = r.esc_low.items[run.start + prior - 1];
        return if (r.frame.regions.rank2(e) < r.frame.regions.rank2(p)) e else null;
    }

    /// Escaped itself or through a trie ancestor; for a deep demand, a
    /// named descendant too (§2.4, O8).
    fn escaped(r: *Resolver, c: CellId, p: u32, deep: bool) Error!?u32 {
        var at = c;
        while (at != .none) : (at = r.env.cells.parent(at)) {
            const lane = try cellLane(r.env, r.gpa, r.atom, at);
            defer leaveLane(r.env, lane);
            try r.env.charge.reserve(r.gpa, .inspection, 1);
            if (try r.escapedAt(at, p)) |e| return e;
        }
        if (!deep) return null;
        return r.escapedBelow(c, p);
    }

    fn escapedBelow(r: *Resolver, c: CellId, p: u32) Error!?u32 {
        // Every cell below the base: as many as the value has, a walk in
        // growth, never the demand's lane (#1201).
        const walk = try r.env.account().enter(r.gpa, null);
        defer r.env.account().leave(walk);
        var stack: std.ArrayList(CellId) = .empty;
        defer stack.deinit(r.gpa);
        try stack.append(r.gpa, c);
        while (stack.pop()) |x| {
            var it = r.env.cells.children(x);
            while (it.next()) |k| {
                try r.env.charge.reserve(r.gpa, .inspection, 1);
                if (try r.escapedAt(k, p)) |e| return e;
                try stack.append(r.gpa, k);
            }
        }
        return null;
    }

    /// Whether `d` may be the object `c` (or contain it, for a deep demand),
    /// and how (§2.2 `alias`; §2.8: a shallow storage write never counts
    /// against the elements a holder holds).
    fn conflict(r: *Resolver, d: CellId, c: CellId, deep: bool) Cell.Alias {
        if (!deep and r.env.cells.below(r.env.places, d, c)) return .no;
        return r.env.cells.alias(r.env.places, d, c);
    }

    fn isFresh(o: Cell.Origin) bool {
        return o == .site or o == .result;
    }

    /// Conditions 1–4 (§2.8): an outcome, or null when condition 5 decides,
    /// with what passed so far relying on `relied`.
    fn before(r: *Resolver, dm: Demand, accepted: *Facts.Verdict.Accepted, relied: *CondId) Error!?Outcome {
        r.atom = dm.base_inst;
        defer r.atom = null;
        const deep = dm.kind.isDeep();
        const cellt = r.env.cells;
        const base_cells = if (deep) try r.reach(dm.base.node) else try r.env.shapes.cellsOf(r.gpa, r.env.account(), &r.env.cells.sets, dm.base.node);
        accepted.* = .fresh;
        // Several cells (alternatives, or a deep demand's reach) make every
        // query below a product of the demand with them: growth, chosen
        // here before the work, the list of them too (§4.1, *direct demand
        // query*; #1225: decided from the set before reading it).
        const product: ?Ids.Account.Kernel = if (Holders.several(cellt, base_cells)) try r.env.account().enter(r.gpa, null) else null;
        defer if (product) |k| r.env.account().leave(k);
        // The base's cells, in the order the conditions read them.
        var cells: std.ArrayList(Cell.Radix.Iterator.Entry) = .empty;
        defer cells.deinit(r.gpa);
        var it = cellt.sets.iterate(base_cells);
        while (it.next()) |e| {
            try r.env.charge.reserve(r.gpa, .inspection, 1);
            try cells.append(r.gpa, e);
            const o = cellt.origin(.from(e.key));
            if (!isFresh(o) and o != .mark) accepted.* = .param;
        }
        // A base with no cell holds no object: nothing to write.
        // 1. Known.
        for (cells.items) |e| if (cellt.origin(.from(e.key)) == .top) {
            return .{ .verdict = .refused, .cause = .unknown, .exactness = .approximate };
        };
        // 2. Unescaped; not shared (R-6.3's order: an escape first).
        for (cells.items) |e| {
            const c: CellId = .from(e.key);
            if (try r.escaped(c, dm.point, deep)) |_| return .{ .verdict = .refused, .cause = .escaped, .exactness = .approximate, .cell = c };
        }
        for (cells.items) |e| {
            const c: CellId = .from(e.key);
            if (cellt.origin(cellt.base(c)) == .shared) return .{ .verdict = .refused, .cause = .top_level, .exactness = .position, .cell = cellt.base(c) };
        }
        // 4. Disjoint: no other operand reaches a cell of the base.
        relied.* = dm.relies;
        // Every operand's reach against the base's cells: as large as the
        // operands, a product, so growth chosen before it, never the
        // demand's lane (§4.1, #1139).
        const sweep: ?Ids.Account.Kernel = if (product == null) try r.env.account().enter(r.gpa, null) else null;
        defer if (sweep) |k| r.env.account().leave(k);
        for (r.frame.operands[dm.operands.start..][0..dm.operands.len]) |op| {
            const rs = try r.reach(op.value.node);
            var ot = cellt.sets.iterate(rs);
            while (ot.next()) |x| {
                for (cells.items) |e| {
                    try r.env.charge.reserve(r.gpa, .inspection, 1);
                    switch (r.conflict(.from(x.key), .from(e.key), deep)) {
                        .no => {},
                        .yes => return .{ .verdict = .refused, .cause = .disjoint, .exactness = if (x.value == 1 or e.value == 1) .approximate else .exact },
                        .under => |s| relied.* = try r.env.conds.@"and"(r.gpa, r.env.charge, relied.*, r.splitCond(s)),
                        .under_kappa => relied.* = Cond.lost,
                    }
                }
            }
        }
        return null;
    }

    /// Conditions 5 (the holder index's answer) and 6.
    fn after(r: *Resolver, dm: Demand, accepted: Facts.Verdict.Accepted, relied0: CondId, a: Holders.Answer, splits: []const Ids.SplitId) Error!Outcome {
        if (a.win) |w| {
            // The cause is the winner's alone (§2.8 condition 5): a pending
            // operand's `held-operand`; `element` for a hold only at an
            // unmaterialised summary position; else from this demand's base
            // local and path. Exactness is apart: `(approx)`.
            const h = r.frame.holders[w.holder];
            const own = h.kind == .binding and h.who == dm.base_local and (dm.base_path == .none or overlaps(r.env.places, w.path, dm.base_path));
            const cause: Facts.Cause = if (h.kind == .pending) .held_operand else if (w.element) .element else if (own) .later_use else .alias;
            return .{ .verdict = .refused, .cause = cause, .exactness = if (w.exact) .exact else .approximate, .holder = w.holder, .holder_path = w.path, .use = w.use };
        }
        // 6. Exclusive, over the relied splits in their order.
        var relied = relied0;
        for (splits[a.splits.start..][0..a.splits.len]) |s| relied = try r.env.conds.@"and"(r.gpa, r.env.charge, relied, r.splitCond(s));
        if (a.lost) relied = Cond.lost;
        var out: Outcome = .{ .verdict = .accepted, .accepted = accepted };
        switch (try r.env.conds.rely(r.gpa, r.env.charge, relied)) {
            .ok => {},
            .xreq => |atoms| out.xreq = atoms,
            .refused => |x| return .{ .verdict = .refused, .cause = .exclusive, .exactness = x },
        }
        return out;
    }

    fn splitCond(r: *Resolver, s: Ids.SplitId) CondId {
        const k = r.env.cells.splitOf(s).cond;
        return if (k == .none) Cond.lost else k;
    }

    /// One path a prefix of the other.
    fn overlaps(places: *const Cell.Places, a: PathId, b: PathId) bool {
        return places.isPrefix(a, b) or places.isPrefix(b, a);
    }
};

/// Resolve every demand of `frame` (§2.8): conditions 1–4 per demand in
/// evaluation order, condition 5 for those that pass by one sweep of the
/// holder index, then condition 6. One outcome per demand, in its order.
pub fn resolve(env: Env, frame: Frame, out: []Outcome) Error!void {
    std.debug.assert(out.len == frame.demands.len);
    // Counted apart (`Account.demands`).
    const was = env.account().in_demands;
    env.account().in_demands = true;
    defer env.account().in_demands = was;
    const gpa = env.gpa;
    var r: Resolver = .{ .gpa = gpa, .env = env, .frame = frame };
    defer r.deinit();
    try r.buildEscapes();
    const n = frame.demands.len;
    const want = try gpa.alloc(bool, n);
    defer gpa.free(want);
    const relied = try gpa.alloc(CondId, n);
    defer gpa.free(relied);
    const accepted = try gpa.alloc(Facts.Verdict.Accepted, n);
    defer gpa.free(accepted);
    for (frame.demands, 0..) |dm, d| {
        // §4.1: a written demand's query is its own kernel, keyed by the
        // demand's base: two demands at one call are two lanes.
        const kernel = try env.account().enter(gpa, .{ .atom = dm.base_inst, .role = .direct_demand_query });
        defer env.account().leave(kernel);
        const got = try r.before(dm, &accepted[d], &relied[d]);
        want[d] = got == null;
        if (got) |o| out[d] = o;
    }
    const answers = try gpa.alloc(Holders.Answer, n);
    defer gpa.free(answers);
    @memset(answers, .{});
    var splits: std.ArrayList(Ids.SplitId) = .empty;
    defer splits.deinit(gpa);
    try Holders.answer(env, frame, want, answers, &splits);
    for (frame.demands, 0..) |dm, d| {
        if (!want[d]) continue;
        const kernel = try env.account().enter(gpa, .{ .atom = dm.base_inst, .role = .direct_demand_query });
        defer env.account().leave(kernel);
        out[d] = try r.after(dm, accepted[d], relied[d], answers[d], splits.items);
    }
}

comptime {
    Ids.assertRecord(Outcome);
}
