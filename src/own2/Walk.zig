//! L9: one frame (`docs/design/ownership-v2.md` §2.4–§2.8, §2.10's read-off):
//! a declaration's body walked once by `Transfer`, its uses indexed
//! (`Liveness`), its demands resolved in evaluation order (`Demands`), and
//! its class read off. S3a walks declarations one at a time, without groups
//! (S3b), and a declaration with a construct not built yet gets the
//! pessimistic class (`Summary.unknown`) and reports no demand (§8).
//!
//! **The read-off** (§2.10): `use(i)` marks `R` at every path the body
//! reads a parameter at, `W` (and `S` for a deep demand) where a demand's
//! base is a parameter's, `E` where an escape reaches one, `A` where the
//! result holds one; `res` is the body's value with this activation's
//! objects renumbered `fresh k` in the order they are met, widened, its κ
//! carried over the relabelling; `xreq` what the demands and calls relied
//! on.
//!
//! Obligations kept here: O5's read-off half (`res`, `W`, `E`, `A` and `R`
//! cover the body), O11 (a refusal of the account stops the walk; nothing
//! partial is published).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Place = @import("Place.zig");
const Cell = @import("Cell.zig");
const Shape = @import("Shape.zig");
const Cond = @import("Cond.zig");
const Summary = @import("Summary.zig");
const Regions = @import("Regions.zig");
const Liveness = @import("Liveness.zig");
const Demands = @import("Demands.zig");
const Transfer = @import("Transfer.zig");
const Bir = @import("../bir/Bir.zig");

pub const ClassId = Ids.ClassId;
pub const NodeId = Ids.NodeId;
pub const CellId = Ids.CellId;
pub const SetId = Ids.SetId;
pub const PathId = Ids.PathId;
pub const PlaceId = Ids.PlaceId;
pub const Env = Summary.Env;
pub const Error = Ids.ChargeError;
pub const none: u32 = Ids.none_int;

pub const Input = struct {
    env: Env,
    sums: *Summary.Table,
    ctx: Transfer.Context,
    bir: *const Bir,
    decl: Bir.Decl,
    prepass: ?*const Facts.Prepass = null,
    phase: Ids.Phase = .inference,
    /// The places of the parameters and the result, for a pessimistic class.
    param_places: []const PlaceId,
    result_place: PlaceId,
};

/// One reported demand: what a line names (§6, R-7.15).
pub const Line = struct {
    demand: Demands.Demand,
    outcome: Demands.Outcome,
    /// The holder's local and kind (or the pending instruction).
    holder: ?Demands.Holder = null,
    /// The token of the holder's later use, `none` when there is none.
    use_token: u32 = none,
};

pub const Result = struct {
    class: ClassId,
    /// The first instruction not built, or `none` when the walk built all.
    unbuilt: u32,
    lines: []Line,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        gpa.free(r.lines);
    }
};

/// Walk declaration `in.decl` (§8 S3a).
pub fn walk(in: Input) Error!Result {
    const env = in.env;
    const gpa = env.gpa;
    var regions = try Regions.build(gpa, env.account(), in.phase, in.bir, in.decl, in.prepass);
    defer regions.deinit(gpa);
    var frame: Transfer.Frame = .{ .gpa = gpa, .env = env, .sums = in.sums, .ctx = in.ctx, .bir = in.bir, .decl = in.decl, .regions = &regions };
    defer frame.deinit();
    try frame.walk();
    if (frame.unbuilt != none) {
        const class = try pessimistic(in);
        return .{ .class = class, .unbuilt = frame.unbuilt, .lines = &.{} };
    }
    var index = try Liveness.Index.build(gpa, env.account(), in.phase, env.places, &regions, frame.uses.items);
    defer index.deinit(gpa);
    // A binding lives to its local's last use.
    for (frame.holders.items) |*h| if (h.kind == .binding) {
        const last = index.lastUse(h.who);
        h.end = if (last == none or last < h.start) h.start else last;
    };
    const outcomes = try gpa.alloc(Demands.Outcome, frame.demands.items.len);
    defer gpa.free(outcomes);
    try Demands.resolve(env, .{
        .demands = frame.demands.items,
        .operands = frame.operands.items,
        .holders = frame.holders.items,
        .escapes = frame.escapes.items,
        .index = &index,
        .regions = &regions,
    }, outcomes);
    const lines = try gpa.alloc(Line, outcomes.len);
    errdefer gpa.free(lines);
    var xreq = try env.conds.flat(gpa, env.charge, if (Cond.Table.fails(frame.xreq)) Cond.yes else frame.xreq);
    for (frame.demands.items, outcomes, lines) |d, o, *l| {
        l.* = .{ .demand = d, .outcome = o };
        if (o.holder != none) l.holder = frame.holders.items[o.holder];
        if (o.use != .none) l.use_token = frame.use_tokens.items[index.get(o.use).atom];
        if (o.verdict == .accepted and o.xreq != .none) xreq = try env.conds.atoms.unionWith(gpa, env.charge, xreq, o.xreq);
    }
    const class = try readOff(in, &frame, xreq);
    return .{ .class = class, .unbuilt = none, .lines = lines };
}

/// `⊤call` over the declaration's places: every parameter read, kept,
/// escaped and written deeply, the result `⊤` (O10).
fn pessimistic(in: Input) Error!ClassId {
    return in.sums.unknown(in.env, in.param_places, &.{}, in.result_place);
}

const ReadOff = struct {
    env: Env,
    fresh: std.ArrayList(CellId) = .empty,

    fn relabel(r: *ReadOff, s: SetId) Error!SetId {
        if (s == .none) return .none;
        const cells = r.env.cells;
        var out: SetId = .none;
        var it = cells.sets.iterate(s);
        while (it.next()) |e| {
            const c: CellId = .from(e.key);
            const x = cells.get(c);
            const m: CellId = switch (x.origin) {
                .site, .result => blk: {
                    const k: u32 = for (r.fresh.items, 0..) |f, i| {
                        if (f == c) break @intCast(i + 1);
                    } else k: {
                        try r.fresh.append(r.env.gpa, c);
                        break :k @intCast(r.fresh.items.len);
                    };
                    break :blk try cells.result(r.env.gpa, r.env.account(), .result, .none, k, x.place, x.kind);
                },
                .esc => try cells.result(r.env.gpa, r.env.account(), .esc, .none, x.b, x.place, x.kind),
                // A refinement is its base's image, approximate (§2.10).
                .elem, .others, .level, .below, .loan => cells.base(c),
                else => c,
            };
            const approx: u1 = if (x.origin.isRefinement()) 1 else e.value;
            out = try cells.sets.insert(r.env.gpa, r.env.charge, out, m.int(), approx);
        }
        return out;
    }
};

/// The parameter a cell (or the base it refines) names, and its path.
fn paramOf(cells: *const Cell.Table, c: CellId) ?struct { u32, PathId } {
    const b = cells.base(c);
    const x = cells.get(b);
    if (x.origin != .param) return null;
    return .{ x.a, .from(x.b) };
}

fn stepsOf(places: *const Place.Table, p: PathId, gpa: Allocator, out: *std.ArrayList(Place.Step)) Allocator.Error!void {
    out.clearRetainingCapacity();
    var at = p;
    while (places.pathParent(at) != .none) : (at = places.pathParent(at)) try out.append(gpa, places.pathStep(at));
    std.mem.reverse(Place.Step, out.items);
}

fn readOff(in: Input, frame: *Transfer.Frame, xreq: SetId) Error!ClassId {
    const env = in.env;
    const gpa = env.gpa;
    const n = in.param_places.len;
    const uses = try gpa.alloc(NodeId, n);
    defer gpa.free(uses);
    @memset(uses, .none);
    var steps: std.ArrayList(Place.Step) = .empty;
    defer steps.deinit(gpa);
    const Mark = struct {
        fn at(e: Env, us: []NodeId, places: []const PlaceId, k: u32, path: PathId, m: Summary.Marks, st: *std.ArrayList(Place.Step)) Error!void {
            if (k >= us.len or e.places.kind(places[k]) == .cross) return;
            // A path read in another place graph than the parameter's (a
            // recast on the way) marks the parameter whole.
            var root = path;
            while (e.places.pathParent(root) != .none) root = e.places.pathParent(root);
            if (e.places.pathPlace(root) != places[k]) {
                us[k] = try Summary.Table.markUse(e, us[k], places[k], &.{}, m, &.{});
                return;
            }
            try stepsOf(e.places, path, e.gpa, st);
            // A path through `⟲` marks where it re-enters: the place above.
            var len = st.items.len;
            for (st.items, 0..) |s, i| if (s.kind == .level) {
                len = i;
                break;
            };
            us[k] = try Summary.Table.markUse(e, us[k], places[k], st.items[0..len], m, &.{});
        }
    };
    // R: the body's reads of a parameter's local.
    const params = in.bir.extraSlice(.{ .start = in.decl.params_start, .end = in.decl.params_end }, Bir.Inst.Index);
    for (frame.uses.items) |u| {
        for (params, 0..) |p, k| {
            if (in.bir.instTag(p) != .pat_var or in.bir.instData(p).lhs != u.local) continue;
            try Mark.at(env, uses, in.param_places, @intCast(k), u.path, .{ .r = true }, &steps);
        }
    }
    // W: a demand's base cells that are a parameter's.
    for (frame.demands.items) |d| {
        var it = env.cells.sets.iterate(env.shapes.cells(d.base.node));
        while (it.next()) |e| if (paramOf(env.cells, .from(e.key))) |pq| {
            try Mark.at(env, uses, in.param_places, pq[0], pq[1], .{ .r = true, .w = true, .deep = d.kind.isDeep() }, &steps);
        };
    }
    // E: escaped parameter cells; A: the result's.
    for (frame.escapes.items) |esc| {
        var it = env.cells.sets.iterate(try env.shapes.reach(gpa, env.account(), &env.cells.sets, esc.node));
        while (it.next()) |e| if (paramOf(env.cells, .from(e.key))) |pq| {
            try Mark.at(env, uses, in.param_places, pq[0], pq[1], .{ .e = true }, &steps);
        };
    }
    const result = frame.result();
    var res: NodeId = undefined;
    var kappa: Cond.Kappas = .none;
    if (result.node == .none) {
        res = try env.shapes.nothing(gpa, env.account(), in.result_place);
    } else {
        var it = env.cells.sets.iterate(try env.shapes.reach(gpa, env.account(), &env.cells.sets, result.node));
        while (it.next()) |e| if (paramOf(env.cells, .from(e.key))) |pq| {
            try Mark.at(env, uses, in.param_places, pq[0], pq[1], .{ .a = true }, &steps);
        };
        var ro: ReadOff = .{ .env = env };
        defer ro.fresh.deinit(gpa);
        const mapped = try env.shapes.map(gpa, env.account(), result.node, &ro, ReadOff.relabel);
        // The value's κ, carried over the relabelling.
        var kt = env.conds.kappaEntries(result.kappa);
        while (kt.next()) |e| {
            try env.charge.reserve(gpa, .inspection, 1);
            const m = env.shapes.memo_map.get(e.node) orelse continue;
            kappa = (try env.conds.kappaSet(gpa, env.charge, kappa, m, e.at_summary, e.cond)).ctx;
        }
        res = try env.shapes.widen(gpa, env.account(), env.places, env.cells, mapped);
        if (res != mapped) kappa = try env.conds.propagate(gpa, env.charge, env.view(), .none, res, &.{mapped}, &.{kappa}, .alternatives, false, null);
    }
    return in.sums.add(env, .{ .params = uses, .res = res, .kappas = kappa, .xreq = xreq, .origin = .inferred });
}
