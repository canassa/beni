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
pub const CondId = Ids.CondId;
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
    // The `inst` atoms queued before this walk are no frame's of it (§2.11).
    env.conds.instFloor();
    var regions = try Regions.build(gpa, env.account(), in.phase, in.bir, in.decl, in.prepass);
    defer regions.deinit(gpa);
    var frame: Transfer.Frame = .{ .gpa = gpa, .env = env, .sums = in.sums, .ctx = in.ctx, .bir = in.bir, .decl = in.decl, .regions = &regions, .param_places = in.param_places };
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
        .bindings = frame.binding,
    }, outcomes);
    const lines = try gpa.alloc(Line, outcomes.len);
    errdefer gpa.free(lines);
    // The frame's `xreq` is tested here: its `inst` atoms resolved first.
    const frame_xreq = try env.conds.resolved(gpa, env.charge, frame.xreq);
    try env.conds.assertResolved(gpa, env.charge, frame_xreq);
    var xreq = try env.conds.flat(gpa, env.charge, if (Cond.Table.fails(frame_xreq)) Cond.yes else frame_xreq);
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
    /// A frame cell → its `fresh k` (k from 1, first-sight order).
    fresh: Ids.FixedDict(1) = .{},
    /// Each `apart` group → its image's aggregate (`Cond.apartImage`).
    apart_images: Ids.FixedDict(1) = .{},

    fn relabel(r: *ReadOff, s: SetId) Error!SetId {
        if (s == .none) return .none;
        const cells = r.env.cells;
        var out: SetId = .none;
        var it = cells.sets.iterate(s);
        while (it.next()) |e| {
            const c: CellId = .from(e.key);
            var src = c;
            var approx = e.value;
            if (cells.origin(c).isRefinement()) {
                // A refinement is its canonical cell's image (§2.2: `elem(π1·ι)`
                // is `π1[*]`); over a concrete base, the base's, approximate.
                if (try cells.unrefined(r.env.gpa, r.env.account(), r.env.places, c)) |u| src = u else {
                    src = cells.base(c);
                    approx = 1;
                }
            }
            const x = cells.get(src);
            const m: CellId = switch (x.origin) {
                .site, .result => blk: {
                    try r.env.charge.reserve(r.env.gpa, .inspection, 1);
                    const got = try r.fresh.getOrPut(r.env.gpa, .{src.int()});
                    if (!got.found_existing) got.value_ptr.* = r.fresh.count();
                    break :blk try cells.result(r.env.gpa, r.env.account(), .result, .none, got.value_ptr.*, x.place, x.kind);
                },
                .esc => try cells.result(r.env.gpa, r.env.account(), .esc, .none, x.b, x.place, x.kind),
                else => src,
            };
            out = try cells.sets.insert(r.env.gpa, r.env.charge, out, m.int(), approx);
        }
        return out;
    }

    /// One cell's image in the class (as `relabel` maps each member).
    fn image(r: *ReadOff, c: CellId) Error!CellId {
        const set = try r.relabel(try r.env.cells.sets.insert(r.env.gpa, r.env.charge, .none, c.int(), 0));
        var it = r.env.cells.sets.iterate(set);
        return .from(it.next().?.key);
    }

    /// A condition of the frame's in the class's cells: the frame's own
    /// cells (a split's refinements, its sites) never reach a class (§2.10),
    /// so every atom is rebuilt over their images and decided again.
    fn atom(ctx: *anyopaque, t: *Cond.Table, gpa: Allocator, charge: Ids.Charge, a: Cond.Cond) Error!CondId {
        const r: *ReadOff = @ptrCast(@alignCast(ctx));
        const cells = r.env.cells;
        switch (a.atom) {
            .excl => return t.excl(gpa, charge, try r.image(.from(a.a))),
            .sep => return t.sep(gpa, charge, cells, r.env.places, try r.image(.from(a.a)), try r.image(.from(a.b)), false, null),
            // Each group from its predecessor's image (§2.9, #1121): a tower's
            // groups share their cells, and so do their images.
            .apart => return t.apartImage(gpa, charge, cells, r.env.places, .from(a.a), &r.apart_images, r, image),
            .within => return t.within(gpa, charge, .from(a.a)),
            .keep => return t.keep(gpa, charge, a.a),
            .writes => return t.writes(gpa, charge, a.a),
        }
    }

    fn cond(r: *ReadOff, k: CondId) Error!CondId {
        return r.env.conds.instantiate(r.env.gpa, r.env.charge, k, .{ .ctx = r, .atom = atom });
    }
};

/// The parameter a cell names, and its path: a refinement's at its
/// canonical position (`elem(π1·ι)` is `π1[*]`, §2.2), not its base's.
fn paramOf(env: Env, c: CellId) Error!?struct { u32, PathId } {
    const u = (try env.cells.unrefined(env.gpa, env.account(), env.places, c)) orelse return null;
    const x = env.cells.get(u);
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
            // The canonical path, `⟲` included: a write below a level is at
            // that level (`π1#Rose.0⟨List⟩`), never the outer object's storage.
            us[k] = try Summary.Table.markUse(e, us[k], places[k], st.items, m, &.{});
        }
    };
    // R: the body's reads of a local that names a parameter's object — the
    // parameter itself, or a part a pattern bound (`count ( _, ( b, _ ) )`
    // reads `π1.1.0`): at the cell's path, the use's own path below it.
    var use_steps: std.ArrayList(Place.Step) = .empty;
    defer use_steps.deinit(gpa);
    for (frame.uses.items) |u| {
        if (u.local >= frame.locals.len or !frame.bound[u.local]) continue;
        const v = frame.locals[u.local];
        if (v.node == .none) continue;
        try stepsOf(env.places, u.path, gpa, &use_steps);
        var it = env.cells.sets.iterate(try env.shapes.cellsOf(env.gpa, env.account(), &env.cells.sets, v.node));
        while (it.next()) |e| if (try paramOf(env, .from(e.key))) |pq| {
            try env.charge.reserve(gpa, .inspection, 1);
            var at = pq[1];
            for (use_steps.items) |s| at = (try env.places.extend(gpa, env.charge, at, s)) orelse break;
            try Mark.at(env, uses, in.param_places, pq[0], at, .{ .r = true }, &steps);
        };
    }
    // W: a demand's base cells that are a parameter's.
    for (frame.demands.items) |d| {
        var it = env.cells.sets.iterate(try env.shapes.cellsOf(env.gpa, env.account(), &env.cells.sets, d.base.node));
        while (it.next()) |e| if (try paramOf(env, .from(e.key))) |pq| {
            try Mark.at(env, uses, in.param_places, pq[0], pq[1], .{ .r = true, .w = true, .deep = d.kind.isDeep() }, &steps);
        };
    }
    // E: escaped parameter cells; A: the result's.
    for (frame.escapes.items) |esc| {
        var it = env.cells.sets.iterate(try env.shapes.reach(gpa, env.account(), &env.cells.sets, esc.node));
        while (it.next()) |e| if (try paramOf(env, .from(e.key))) |pq| {
            try Mark.at(env, uses, in.param_places, pq[0], pq[1], .{ .e = true }, &steps);
        };
    }
    var ro: ReadOff = .{ .env = env };
    defer ro.fresh.deinit(gpa);
    defer ro.apart_images.deinit(gpa);
    // The frame's reliance in the class's cells; one that fails there
    // (a split's atom no caller could discharge) is no class at all.
    var class_xreq: SetId = .none;
    if (xreq != .none) {
        const k = try ro.cond(try env.conds.ofSet(gpa, env.charge, xreq));
        if (Cond.Table.fails(k)) return pessimistic(in);
        class_xreq = try env.conds.flat(gpa, env.charge, k);
    }
    const result = frame.result();
    var res: NodeId = undefined;
    var kappa: Cond.Kappas = .none;
    if (result.node == .none) {
        res = try env.shapes.nothing(gpa, env.account(), in.result_place);
    } else {
        var it = env.cells.sets.iterate(try env.shapes.reach(gpa, env.account(), &env.cells.sets, result.node));
        while (it.next()) |e| if (try paramOf(env, .from(e.key))) |pq| {
            try Mark.at(env, uses, in.param_places, pq[0], pq[1], .{ .a = true }, &steps);
        };
        const mapped = try env.shapes.map(gpa, env.account(), result.node, &ro, ReadOff.relabel);
        // The value's κ, carried over the relabelling: each entry's node
        // relabelled, its path unchanged (§2.9).
        const Carry = struct {
            ro: *ReadOff,
            fn node(ctx: *anyopaque, x: NodeId) Error!?NodeId {
                const c: *@This() = @ptrCast(@alignCast(ctx));
                const shapes = c.ro.env.shapes;
                if (shapes.memo_map.get(x)) |m| return m;
                // A view the map did not meet, on a chain it forced: its
                // entries join the answer's (§2.11 *κ at a view*).
                const answer = shapes.answerOf(x) orelse return null;
                return shapes.memo_map.get(answer);
            }
            fn cond(ctx: *anyopaque, _: *Cond.Table, _: std.mem.Allocator, _: Ids.Charge, k: Cond.CondId) Error!Cond.CondId {
                const c: *@This() = @ptrCast(@alignCast(ctx));
                return c.ro.cond(k);
            }
        };
        var carry: Carry = .{ .ro = &ro };
        kappa = try env.conds.kappaRelabel(gpa, env.charge, result.kappa, .{ .ctx = &carry, .node = Carry.node, .cond = Carry.cond });
        // Widened, its κ carried onto the image with each folded class's
        // path-multiset obligation (§2.9, #1128).
        const widened = try env.conds.widenValue(gpa, env.charge, env.view(), mapped, kappa);
        res = widened.node;
        kappa = widened.kappas;
    }
    return in.sums.add(env, .{ .params = uses, .res = res, .kappas = kappa, .xreq = class_xreq, .origin = .inferred });
}
