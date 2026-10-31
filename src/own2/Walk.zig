//! L11: one frame (`docs/design/ownership-v2.md` §2.4–§2.8, §2.10's read-off):
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
    /// A recursive group member's stable labels (§8 S3b slice 4), or null.
    labels: ?Labels = null,
    /// A type's `eq` or `compare` (§2.13.13 item 13, R-5.13.1): a demand
    /// on what it was handed is `comparison`, never accepted.
    comparison: bool = false,
};

/// The stable labels of a recursive group member's read-off (§8 S3b slice
/// 4, *Stable labels*): its own fresh objects numbered by key, not by the
/// order a walk meets them, in a dictionary kept across its walks, so its
/// label inventory is bounded by the group's instructions however many
/// rounds run. A cell a group call ι answers fresh (`result ι·k`, any k) is
/// one folded label `ι⋆` per place and kind; any other is its own cell.
pub const Labels = struct {
    fresh: *Ids.FixedDict(3),
    ctx: *anyopaque,
    /// Whether instruction `inst` is a call of the walk's own group.
    group_call: *const fn (ctx: *anyopaque, inst: u32) bool,

    fn key(l: Labels, cells: *const Cell.Table, c: CellId) [3]u32 {
        const x = cells.get(c);
        if (x.origin == .result and x.a != none and l.group_call(l.ctx, cells.labelInst(.from(x.a))))
            return .{ 1 | (@as(u32, @backingInt(x.kind)) << 1), cells.labelInst(.from(x.a)), x.place.int() };
        return .{ 0, c.int(), 0 };
    }
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
    // R-5.13.1: a comparison may only read its arguments. A demand the
    // conditions accept on an arrival (`param`: a cell neither the frame
    // nor a call made) is the language's refusal, a position rule; one they
    // refuse keeps its own cause.
    if (in.comparison) for (outcomes) |*o| if (o.verdict == .accepted and o.accepted == .param) {
        o.* = .{ .verdict = .refused, .cause = .comparison, .exactness = .position };
    };
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
    /// A group member's stable labels instead, when given.
    labels: ?Labels = null,
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
                    if (r.labels) |l| {
                        const got = try l.fresh.getOrPut(r.env.gpa, l.key(cells, src));
                        if (!got.found_existing) got.value_ptr.* = l.fresh.count();
                        break :blk try cells.result(r.env.gpa, r.env.account(), .result, .none, got.value_ptr.*, x.place, x.kind);
                    }
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
            // `instantiate` resolves its condition first: no `inst` reaches here.
            .inst => unreachable,
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

/// A `call` use's reads in the caller's use shapes (§2.7, §2.10's
/// read-off, #1325): the callee reads its argument at every path its
/// `use` marks, so the class marks `R` at each, the callee's steps after
/// the argument's. Built by one descent of the pair (callee use node,
/// caller's node at the path) per installed path, the result one node put
/// at the path by one path copy, so a call costs its use shape's width,
/// never a rebuild from the root per marked path. A jump-free graft is
/// memoised by `(callee node, caller node, place)`, so a use shape that is
/// a DAG is grafted as a DAG.
///
/// **Cycles.** A callee's step can close a cycle of the caller's place
/// graph above the argument: `viaT t = case t of T r → readKid r` where
/// `readKid` reads `π1⟲.v`. The callee's `⟲` is replayed through `extend`,
/// step by step around the place's cycles in the caller's graph, so the
/// path is the one the inline walk makes (`π1⟲#T.0.v`, never
/// `π1#T.0⟲.v`, which no demand queries). Such a path, and a plain step
/// that `extend` folds into a `⟲` above, is not below the path being
/// built: it is a jump, installed after the graft from the root.
///
/// A callee's deep read (a leaf of marks: every path below, §2.13.6; or a
/// node marked `D`) is `R` and `D` at its path, in a node (§2.10, *A deep
/// read across a call*, #1328): never a leaf, which would make a shallow
/// `W` of the caller's at the same path deep (`S`), as v1 never does. A
/// step the caller's place does not take is `R` where it stopped.
const Graft = struct {
    env: Env,
    us: []NodeId,
    places: []const PlaceId,
    /// The set `{R}`.
    r: SetId,
    /// The set `{R, D}`: a callee's deep read (§2.10), made at its first
    /// use, so a frame with none interns no `D` (#1328).
    rd: SetId = .none,
    /// `(callee node, caller node, place)` → the grafted node, jump-free
    /// grafts only.
    memo: Ids.FixedDict(3) = .{},
    /// Per callee node: 1 when its subtree is plain `node`s marked `R` at
    /// most, with no `⟲` step and no place on a cycle (`pure`).
    pure_memo: Ids.FixedDict(1) = .{},
    /// `(parameter, callee node, path)` installed: two parameters of one
    /// place share their paths.
    done: Ids.FixedDict(3) = .{},
    jumps: std.ArrayList(Jump) = .empty,
    /// A place's re-entries (`levels`), memoised by the path they start at.
    level_memo: Ids.FixedDict(1) = .{},
    level_runs: std.ArrayList([2]u32) = .empty,
    level_paths: std.ArrayList(PathId) = .empty,
    steps: std.ArrayList(Place.Step) = .empty,
    way: std.ArrayList(Way) = .empty,
    stack: std.ArrayList(Frame) = .empty,

    const Jump = struct { u: NodeId, path: PathId };
    const Way = struct { n: NodeId, place: PlaceId, here: SetId };
    const Frame = struct {
        u: NodeId,
        path: PathId,
        c: NodeId,
        cells: SetId,
        children: u32,
        jump_free: bool,
        it: Shape.Table.OverIterator,
        /// The step this frame's node is put at in its parent.
        step: Place.Step,
    };

    fn deinit(g: *Graft) void {
        const gpa = g.env.gpa;
        g.memo.deinit(gpa);
        g.pure_memo.deinit(gpa);
        g.done.deinit(gpa);
        g.jumps.deinit(gpa);
        g.level_memo.deinit(gpa);
        g.level_runs.deinit(gpa);
        g.level_paths.deinit(gpa);
        g.steps.deinit(gpa);
        g.way.deinit(gpa);
        g.stack.deinit(gpa);
    }

    /// `u`, a callee's use shape, read at `base`, the argument's path of
    /// parameter `k`.
    fn compose(g: *Graft, k: u32, base: PathId, u: NodeId) Error!void {
        if (k >= g.us.len or g.env.places.kind(g.places[k]) == .cross) return;
        try g.jumps.append(g.env.gpa, .{ .u = u, .path = base });
        while (g.jumps.pop()) |j| {
            try g.env.charge.reserve(g.env.gpa, .inspection, 1);
            const got = try g.done.getOrPut(g.env.gpa, .{ k, j.u.int(), j.path.int() });
            if (got.found_existing) continue;
            try g.install(k, j.path, j.u);
        }
    }

    /// The graft of `u` at `path`, put into parameter `k`'s use shape.
    fn install(g: *Graft, k: u32, path: PathId, u: NodeId) Error!void {
        const e = g.env;
        const gpa = e.gpa;
        // A path in another place graph than the parameter's (a recast on
        // the way) marks the parameter whole, as `Mark.at` does.
        var root = path;
        while (e.places.pathParent(root) != .none) root = e.places.pathParent(root);
        if (e.places.pathPlace(root) != g.places[k]) {
            g.us[k] = try Summary.Table.markUse(e, g.us[k], g.places[k], &.{}, .{ .r = true }, &.{});
            return;
        }
        try stepsOf(e.places, path, gpa, &g.steps);
        // Down to the path's node; a leaf on the way holds its marks below,
        // and `markUse` joins `R` into it.
        g.way.clearRetainingCapacity();
        var n = g.us[k];
        var place = g.places[k];
        for (g.steps.items) |s| {
            try e.charge.reserve(gpa, .shape, 1);
            const here: SetId = if (n == .none) .none else try e.shapes.cellsOf(gpa, e.account(), &e.cells.sets, n);
            if (n != .none and e.shapes.kind(n) == .leaf and here != .none) {
                g.us[k] = try Summary.Table.markUse(e, g.us[k], g.places[k], g.steps.items, .{ .r = true }, &.{});
                return;
            }
            try g.way.append(gpa, .{ .n = n, .place = place, .here = here });
            var child: NodeId = .none;
            if (n != .none and e.shapes.kind(n) == .node) {
                if (e.shapes.overGet(e.shapes.get(n).a, s)) |c| child = c;
            }
            n = child;
            place = e.places.child(place, s) orelse unreachable;
        }
        var out = try g.graft(u, path, n);
        var i = g.steps.items.len;
        while (g.way.pop()) |lv| {
            i -= 1;
            const children: u32 = if (lv.n != .none and e.shapes.kind(lv.n) == .node) e.shapes.get(lv.n).a else Ids.none_int;
            out = try e.shapes.node(gpa, e.account(), lv.place, lv.here, try e.shapes.overPut(gpa, e.account(), children, g.steps.items[i], out));
        }
        g.us[k] = out;
    }

    /// The caller's node `c` at `path` with `R` at every path `u` marks,
    /// on an explicit stack (#1138); jumps are queued.
    fn graft(g: *Graft, u: NodeId, path: PathId, c: NodeId) Error!NodeId {
        const e = g.env;
        const gpa = e.gpa;
        g.stack.clearRetainingCapacity();
        var result: NodeId = .none;
        if (try g.enter(u, path, c, Place.Step.level)) |hit| return hit;
        while (g.stack.items.len > 0) {
            const top = &g.stack.items[g.stack.items.len - 1];
            if (top.it.next()) |ch| {
                try e.charge.reserve(gpa, .inspection, 1);
                if (ch.step.kind == .level) {
                    const run = try g.levels(top.path);
                    if (run[1] == 0) top.cells = try e.cells.sets.unionWith(gpa, e.charge, top.cells, g.r);
                    for (g.level_paths.items[run[0]..][0..run[1]]) |t| try g.jumps.append(gpa, .{ .u = ch.node, .path = t });
                    if (run[1] != 0) top.jump_free = false;
                    continue;
                }
                const below = (try e.places.extend(gpa, e.charge, top.path, ch.step)) orelse {
                    top.cells = try e.cells.sets.unionWith(gpa, e.charge, top.cells, g.r);
                    continue;
                };
                if (e.places.pathParent(below) != top.path or e.places.pathStep(below).word() != ch.step.word()) {
                    // Folded into a `⟲` above: not below this path.
                    try g.jumps.append(gpa, .{ .u = ch.node, .path = below });
                    top.jump_free = false;
                    continue;
                }
                var cc: NodeId = .none;
                if (top.c != .none and e.shapes.kind(top.c) == .node) {
                    if (e.shapes.overGet(e.shapes.get(top.c).a, ch.step)) |x| cc = x;
                }
                if (try g.enter(ch.node, below, cc, ch.step)) |hit| {
                    const t = &g.stack.items[g.stack.items.len - 1];
                    t.children = try e.shapes.overPut(gpa, e.account(), t.children, ch.step, hit);
                }
                continue;
            }
            const done = g.stack.pop().?;
            const place = e.places.pathPlace(done.path);
            const node = try e.shapes.node(gpa, e.account(), place, done.cells, done.children);
            if (done.jump_free) (try g.memo.getOrPut(gpa, .{ done.u.int(), done.c.int(), place.int() })).value_ptr.* = node.int();
            if (g.stack.items.len == 0) {
                result = node;
                break;
            }
            const parent = &g.stack.items[g.stack.items.len - 1];
            parent.children = try e.shapes.overPut(gpa, e.account(), parent.children, done.step, node);
            parent.jump_free = parent.jump_free and done.jump_free;
        }
        return result;
    }

    /// Starts the graft of `u` at `path` over `c`: its answer when it needs
    /// no descent (a memo hit, a caller leaf, a callee node that is not a
    /// plain `node`), else a frame pushed and null.
    fn enter(g: *Graft, u: NodeId, path: PathId, c: NodeId, step: Place.Step) Error!?NodeId {
        const e = g.env;
        const gpa = e.gpa;
        const place = e.places.pathPlace(path);
        try e.charge.reserve(gpa, .memo, 1);
        if (g.memo.get(.{ u.int(), c.int(), place.int() })) |hit| return NodeId.from(hit);
        const here: SetId = if (c == .none) .none else try e.shapes.cellsOf(gpa, e.account(), &e.cells.sets, c);
        if (c != .none and e.shapes.kind(c) == .leaf and here != .none)
            return try e.shapes.leaf(gpa, e.account(), place, try e.cells.sets.unionWith(gpa, e.charge, here, g.r));
        // A read-only callee use at the same place, on no cycle, over a
        // caller node with no children: the graft is the caller's cells over
        // the callee's own children (a wrapper copies none of its callee's use).
        if (e.shapes.place(u) == place and try g.pure(u)) {
            const bare = c == .none or (e.shapes.kind(c) == .node and e.shapes.get(c).a == Ids.none_int);
            if (bare) return try e.shapes.node(gpa, e.account(), place, try e.cells.sets.unionWith(gpa, e.charge, here, e.shapes.get(u).cells), e.shapes.get(u).a);
        }
        const d = e.shapes.get(u);
        // A leaf of marks, or a node marked `D`, reads every path below.
        const deep = (d.kind == .leaf and try marked(e, d.cells)) or try Summary.Table.deepRead(e, u);
        if (deep and g.rd == .none) g.rd = try Summary.Table.marksSet(e, .{ .r = true, .deep_read = true }, &.{});
        const cells = if (deep) try e.cells.sets.unionWith(gpa, e.charge, here, g.rd) else if (try marked(e, d.cells)) try e.cells.sets.unionWith(gpa, e.charge, here, g.r) else here;
        const children: u32 = if (c != .none and e.shapes.kind(c) == .node) e.shapes.get(c).a else Ids.none_int;
        if (d.kind != .node) return try e.shapes.node(gpa, e.account(), place, cells, children);
        try g.stack.append(gpa, .{ .u = u, .path = path, .c = c, .cells = cells, .children = children, .jump_free = true, .it = e.shapes.overEntries(d.a), .step = step });
        return null;
    }

    /// The paths at the place of `path` one or more steps around its cycles
    /// of the caller's place graph, each as `extend` makes it (so as the
    /// inline walk names it): `(start, len)` into `level_paths`. Empty when
    /// the place is on no cycle. A walk of the canonical paths of the
    /// place's strongly connected component, each once.
    fn levels(g: *Graft, path: PathId) Error![2]u32 {
        const e = g.env;
        try e.charge.reserve(e.gpa, .memo, 1);
        if (g.level_memo.get(.{path.int()})) |i| return g.level_runs.items[i];
        // `Place.levelsOf` is the one walk of a path's levels (sealed first
        // returns taken whole, #1253).
        const r = try e.places.levelsOf(e.gpa, e.charge, path);
        const start: u32 = @intCast(g.level_paths.items.len);
        var i: u32 = 0;
        while (i < r.len) : (i += 1) try g.level_paths.append(e.gpa, e.places.foldPath(r.start + i));
        const run: [2]u32 = .{ start, r.len };
        (try g.level_memo.getOrPut(e.gpa, .{path.int()})).value_ptr.* = @intCast(g.level_runs.items.len);
        try g.level_runs.append(e.gpa, run);
        return run;
    }

    /// Whether `u`'s subtree is plain `node`s whose cells are `R` and `D`
    /// marks at most, with no `⟲` step and no place on a cycle: its graft
    /// at its own place over nothing is itself. Memoised per node, on an
    /// explicit stack (#1138); a child not settled (a cycle) is not pure.
    fn pure(g: *Graft, u: NodeId) Error!bool {
        const e = g.env;
        const gpa = e.gpa;
        if (g.pure_memo.get(.{u.int()})) |b| return b == 1;
        const Item = struct { n: NodeId, expanded: bool };
        var stack: std.ArrayList(Item) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, .{ .n = u, .expanded = false });
        while (stack.pop()) |f| {
            if (g.pure_memo.get(.{f.n.int()}) != null) continue;
            const d = e.shapes.get(f.n);
            if (!f.expanded and d.kind == .node) {
                try e.charge.reserve(gpa, .inspection, 1);
                try stack.append(gpa, .{ .n = f.n, .expanded = true });
                var it = e.shapes.overEntries(d.a);
                while (it.next()) |k| if (g.pure_memo.get(.{k.node.int()}) == null) try stack.append(gpa, .{ .n = k.node, .expanded = false });
                continue;
            }
            var ok = d.kind == .node and !try g.cyclic(d.place);
            if (ok) {
                var ct = e.cells.sets.iterate(d.cells);
                while (ct.next()) |x| {
                    const c: CellId = .from(x.key);
                    if (e.cells.origin(c) != .mark or (e.cells.markOf(c) != .r and e.cells.markOf(c) != .deep_read)) ok = false;
                }
                var it = e.shapes.overEntries(d.a);
                while (it.next()) |k| {
                    if (k.step.kind == .level or (g.pure_memo.get(.{k.node.int()}) orelse 0) != 1) ok = false;
                }
            }
            (try g.pure_memo.getOrPut(gpa, .{f.n.int()})).value_ptr.* = @intFromBool(ok);
        }
        return g.pure_memo.get(.{u.int()}).? == 1;
    }

    /// Whether `p` is on a cycle of the place graph.
    fn cyclic(g: *Graft, p: PlaceId) Error!bool {
        const e = g.env;
        const st = e.places.steps(p);
        try e.charge.reserve(e.gpa, .inspection, 1);
        for (st.children) |child| if (child == p or e.places.sameCycle(p, child)) return true;
        return false;
    }

    fn marked(e: Env, cells: SetId) Error!bool {
        var it = e.cells.sets.iterate(cells);
        while (it.next()) |x| if (e.cells.origin(.from(x.key)) == .mark) return true;
        return false;
    }
};

/// Which source nodes of a read-off stand at each κ position (#1372's
/// review): `(source position, image)` → how many distinct built sources
/// at that position `Shape.map` made that image of. Two built nodes at one
/// position that intern to one image must not let one's entry answer for
/// the other's absence (`Cond.Relabel.present`). One walk of the value
/// paired with its snapshot, each `(node, position)` once, a record each;
/// a delta's base is walked at its delta's position and is no position of
/// its own, so its children may be counted where an override hides them,
/// which can only add `lost`.
const Presence = struct {
    count: Ids.FixedDict(2) = .{},
    counted: Ids.FixedDict(2) = .{},
    seen: Ids.FixedDict(3) = .{},

    fn deinit(p: *Presence, gpa: Allocator) void {
        p.count.deinit(gpa);
        p.counted.deinit(gpa);
        p.seen.deinit(gpa);
    }

    fn run(p: *Presence, env: anytype, root: NodeId, k: Cond.Kappas) Error!void {
        const gpa = env.gpa;
        const shapes = env.shapes;
        const Item = struct { node: NodeId, at: Cond.Kappas, position: bool };
        var stack: std.ArrayList(Item) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, .{ .node = root, .at = k, .position = true });
        while (stack.pop()) |it| {
            if (it.at == .none or it.node == .none) continue;
            const got = try p.seen.getOrPut(gpa, .{ it.node.int(), it.at.int(), @intFromBool(it.position) });
            if (got.found_existing) continue;
            try env.charge.reserve(gpa, .inspection, 1);
            var x = it.node;
            if (shapes.kind(x) == .view) x = shapes.answerOf(x) orelse continue;
            x = shapes.eagerOf(x);
            const d = shapes.get(x);
            switch (d.kind) {
                .leaf, .view => {},
                .recast => try stack.append(gpa, .{ .node = .from(d.a), .at = it.at, .position = true }),
                .@"union", .choice, .positions => try stack.appendSlice(gpa, &.{ .{ .node = .from(d.a), .at = it.at, .position = true }, .{ .node = .from(d.b), .at = it.at, .position = true } }),
                .node, .delta => {
                    if (it.position) if (shapes.mapSource(x)) |s| if (shapes.memo_map.get(s)) |m| {
                        const c = try p.counted.getOrPut(gpa, .{ it.at.int(), s.int() });
                        if (!c.found_existing) {
                            c.value_ptr.* = 1;
                            const n = try p.count.getOrPut(gpa, .{ it.at.int(), m.int() });
                            n.value_ptr.* = if (n.found_existing) n.value_ptr.* + 1 else 1;
                        }
                    };
                    var e = shapes.overEntries(if (d.kind == .node) d.a else d.b);
                    while (e.next()) |c| try stack.append(gpa, .{ .node = c.node, .at = env.conds.kappaChild(it.at, c.step), .position = true });
                    if (d.kind == .delta) try stack.append(gpa, .{ .node = .from(d.a), .at = it.at, .position = false });
                },
            }
        }
    }
};

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
    var graft: Graft = .{ .env = env, .us = uses, .places = in.param_places, .r = try Summary.Table.marksSet(env, .{ .r = true }, &.{}) };
    defer graft.deinit();
    for (frame.uses.items) |u| {
        if (u.local >= frame.locals.len or !frame.bound[u.local]) continue;
        const v = frame.locals[u.local];
        if (v.node == .none) continue;
        try stepsOf(env.places, u.path, gpa, &use_steps);
        var it = env.cells.sets.iterate(try env.shapes.cellsOf(env.gpa, env.account(), &env.cells.sets, v.node));
        while (it.next()) |e| if (try paramOf(env, .from(e.key))) |pq| {
            try env.charge.reserve(gpa, .inspection, 1);
            var at = pq[1];
            var whole = true;
            for (use_steps.items) |s| at = (try env.places.extend(gpa, env.charge, at, s)) orelse {
                whole = false;
                break;
            };
            try Mark.at(env, uses, in.param_places, pq[0], at, .{ .r = true }, &steps);
            // A `call` use reads the argument at every path its callee's
            // `use` names (§2.7), so the class marks `R` there too, the
            // callee's paths below the argument's (#1325: `rxb2 g = rb g.x`
            // with `rb r = List.length r.b` reads `π1.x.b`, not only `π1.x`).
            if (u.kind == .call and u.use_node != .none and whole) try graft.compose(pq[0], at, u.use_node);
        };
    }
    // R: the parameter parts a consumed value holds, a temporary's too
    // (#1330: `rbc { b = g.x }`, `rbx (pick g.x)`), at their own paths and
    // the callee's use below them (`Transfer.Frame.readsOf`).
    for (frame.param_reads.items) |rd| if (try paramOf(env, rd.cell)) |pq| {
        try env.charge.reserve(gpa, .inspection, 1);
        if (rd.use_node == .none) {
            try Mark.at(env, uses, in.param_places, pq[0], pq[1], .{ .r = true }, &steps);
        } else try graft.compose(pq[0], pq[1], rd.use_node);
    };
    // W: a demand's base cells that are a parameter's.
    for (frame.demands.items) |d| {
        // A deep demand writes everything its base reaches (§2.8): a fresh value holding a parameter writes it.
        const written = if (d.kind.isDeep()) try env.shapes.reach(gpa, env.account(), &env.cells.sets, d.base.node) else try env.shapes.cellsOf(env.gpa, env.account(), &env.cells.sets, d.base.node);
        var it = env.cells.sets.iterate(written);
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
    var ro: ReadOff = .{ .env = env, .labels = in.labels };
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
        // Published as the eager graft made it (§2.11 *κ at a view*): each
        // view, and each node holding one, as its eager image.
        _ = try env.shapes.eager(gpa, env.account(), env.places, env.cells, result.node);
        const mapped = try env.shapes.map(gpa, env.account(), result.node, &ro, ReadOff.relabel);
        // The value's κ, carried over the relabelling: each entry's node
        // relabelled, its path unchanged (§2.9).
        var presence: Presence = .{};
        defer presence.deinit(gpa);
        if (env.shapes.map_shared) try presence.run(env, result.node, result.kappa);
        var carry: Carry = .{ .ro = &ro, .presence = &presence };
        // A map that interned no two sources into one image needs no presence
        // count: the relabel then maps each shared submap once (§2.9).
        kappa = try env.conds.kappaRelabel(gpa, env.charge, result.kappa, .{ .ctx = &carry, .node = Carry.node, .cond = Carry.cond, .source = if (env.shapes.map_shared) Carry.source else null, .present = if (env.shapes.map_shared) Carry.present else null });
        // Widened, its κ carried onto the image with each folded class's
        // path-multiset obligation (§2.9, #1128).
        const widened = try env.conds.widenValue(gpa, env.charge, env.view(), mapped, kappa);
        res = widened.node;
        kappa = widened.kappas;
    }
    return in.sums.add(env, .{ .params = uses, .res = res, .kappas = kappa, .xreq = class_xreq, .origin = .inferred });
}

/// A κ carried over a relabelling (`ReadOff`): each entry's node the map's
/// image, its path unchanged (§2.9). A view's entries, and its raw
/// answer's, join its image's.
const Carry = struct {
    ro: *ReadOff,
    presence: *Presence,
    fn node(ctx: *anyopaque, x: NodeId) Error!?NodeId {
        const c: *@This() = @ptrCast(@alignCast(ctx));
        const shapes = c.ro.env.shapes;
        if (shapes.memo_map.get(x) orelse shapes.memo_map.get(shapes.eagerOf(x))) |m| return m;
        // A view the map did not meet, on a chain it forced: its entries
        // join the answer's (§2.11 *κ at a view*).
        const answer = shapes.answerOf(x) orelse return null;
        return shapes.memo_map.get(answer) orelse shapes.memo_map.get(shapes.eagerOf(answer));
    }
    /// The source `x` stands for at `pos`: one the walk found there. A
    /// stale entry, kept for a node a join left elsewhere, counts for none,
    /// so it cannot make up for a source with no entry.
    fn source(ctx: *anyopaque, pos: Cond.Kappas, x: NodeId) ?NodeId {
        const c: *@This() = @ptrCast(@alignCast(ctx));
        const s = c.ro.env.shapes.mapSource(x) orelse return null;
        return if (c.presence.counted.get(.{ pos.int(), s.int() }) != null) s else null;
    }
    fn present(ctx: *anyopaque, pos: Cond.Kappas, m: NodeId) u32 {
        const c: *@This() = @ptrCast(@alignCast(ctx));
        return c.presence.count.get(.{ pos.int(), m.int() }) orelse 0;
    }
    fn cond(ctx: *anyopaque, _: *Cond.Table, _: std.mem.Allocator, _: Ids.Charge, k: Cond.CondId) Error!Cond.CondId {
        const c: *@This() = @ptrCast(@alignCast(ctx));
        return c.ro.cond(k);
    }
};
