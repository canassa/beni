//! L7: a call of a class (`docs/design/ownership-v2.md` §2.11). S3a applies
//! the classes the rows give (`Rows.fromWords`, built at the call's own
//! instantiation, so the class's places are the caller's); S3b adds the
//! summaries of declarations, S4 callbacks.
//!
//! `apply` answers what the call does, item by item:
//!
//! 1. **Uses** are the caller's (`Transfer` records each argument at the
//!    call, kind `call`, the class's use shape for that parameter).
//! 2. **W**: every path of a parameter's use shape marked `W` (deep with
//!    `S`) is a write the caller turns into a demand on the argument there.
//! 3. **E**: every path marked `E` lets the argument there escape, deeply.
//! 4. **Result**: `res` grafted: `πᵢ·q ↦ proj(aᵢ, q)`, the class's `fresh k`
//!    a `result ι·k`, its `esc k` an `esc ι·k` that escapes, `⊤` and `shared`
//!    kept; a node's `ε` cells by the arguments' cells there, its children
//!    grafted, a recast kept, a union joined, a positional collection
//!    collected again — every template node once per call (a DAG stays one).
//! 5. **Conditions**: the arguments' snapshots combined, then every κ the
//!    class's snapshot sets instantiated onto the grafted node (§2.9: `excl
//!    πᵢ·q` is the argument's deep condition at `q`, `sep`/`apart` compare
//!    the arguments' cells at those paths); `xreq` instantiated the same way.
//!
//! What a class names that S3a does not interpret — a callback's result, a
//! taken element, a loan, `within`, `keep`, `writes` — instantiates to `⊤`
//! or `lost`: sound, and never a write the caller is not told of (O1, O10).
//!
//! Obligations kept here: O1 (the result over-approximates what the call
//! returns), O5's instantiation half (extensive), O14 (κ(res) instantiated
//! is `yes` only when every atom holds of the actual arrivals).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Cell = @import("Cell.zig");
const Shape = @import("Shape.zig");
const Cond = @import("Cond.zig");
const Summary = @import("Summary.zig");
const Demands = @import("Demands.zig");
const stamped = @import("../stamped.zig");

pub const NodeId = Ids.NodeId;
pub const CellId = Ids.CellId;
pub const SetId = Ids.SetId;
pub const PathId = Ids.PathId;
pub const PlaceId = Ids.PlaceId;
pub const CondId = Ids.CondId;
pub const ClassId = Ids.ClassId;
pub const LabelId = Ids.LabelId;
pub const Value = Demands.Value;
pub const Env = Summary.Env;
pub const Step = Shape.Step;
pub const Error = Ids.ChargeError;

/// A parameter path the class writes (`W`), deeply when `deep` (`S`).
pub const Write = struct { param: u32, steps: Ids.Range, deep: bool };
/// A parameter path the class lets escape (`E`).
pub const Escape = struct { param: u32, steps: Ids.Range };

pub const Applied = struct {
    result: Value,
    /// The instantiated `xreq`: `yes` when the class relies on nothing.
    xreq: CondId,
    writes: []const Write,
    escapes: []const Escape,
    /// The values the result lets escape (an `esc k`), deeply.
    escaped: []const NodeId,
    /// The steps the `Write`s and `Escape`s name, root first.
    steps: []const Step,
};

/// One call's scratch, reused across calls of one walk.
pub const Scratch = struct {
    memo: stamped.Column(NodeId, NodeId) = .{},
    writes: std.ArrayList(Write) = .empty,
    escapes: std.ArrayList(Escape) = .empty,
    escaped: std.ArrayList(NodeId) = .empty,
    steps: std.ArrayList(Step) = .empty,
    members: std.ArrayList(NodeId) = .empty,

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        s.memo.deinit(gpa);
        s.writes.deinit(gpa);
        s.escapes.deinit(gpa);
        s.escaped.deinit(gpa);
        s.steps.deinit(gpa);
        s.members.deinit(gpa);
    }
};

const Grafter = struct {
    env: Env,
    sums: *const Summary.Table,
    args: []const Value,
    label: LabelId,
    s: *Scratch,

    fn gpa(g: *Grafter) Allocator {
        return g.env.gpa;
    }

    fn account(g: *Grafter) *Ids.Account {
        return g.env.account();
    }

    /// The steps of a canonical path, root first, into `out`.
    fn stepsOf(g: *Grafter, p: PathId, out: *std.ArrayList(Step)) Error!void {
        const first = out.items.len;
        var at = p;
        while (g.env.places.pathParent(at) != .none) : (at = g.env.places.pathParent(at)) {
            try g.env.charge.reserve(g.gpa(), .path, 1);
            try out.append(g.gpa(), g.env.places.pathStep(at));
        }
        std.mem.reverse(Step, out.items[first..]);
    }

    /// Argument `i` at path `p` (a parameter cell's own path): its node
    /// projected along the path. Through `⟲` the levels below are inside
    /// the value as it stands: the node itself, read approximately.
    fn argAt(g: *Grafter, i: u32, p: PathId, at: PlaceId) Error!NodeId {
        if (i >= g.args.len or g.args[i].node == .none) return g.topLeaf(at);
        var steps: std.ArrayList(Step) = .empty;
        defer steps.deinit(g.gpa());
        try g.stepsOf(p, &steps);
        var n = g.args[i].node;
        for (steps.items) |s| {
            if (s.kind == .level) return g.env.shapes.recast(g.gpa(), g.account(), at, n);
            n = (try g.env.shapes.proj(g.gpa(), g.account(), g.env.places, g.env.cells, n, s)) orelse return g.topLeaf(at);
        }
        if (g.env.shapes.place(n) != at) return g.env.shapes.recast(g.gpa(), g.account(), at, n);
        return n;
    }

    fn topLeaf(g: *Grafter, at: PlaceId) Error!NodeId {
        const top = try g.env.cells.top(g.gpa(), g.account());
        return g.env.shapes.leaf(g.gpa(), g.account(), at, try g.env.cells.sets.insert(g.gpa(), g.env.charge, .none, top.int(), 0));
    }

    /// A class cell that is not a parameter's, as the caller sees it: the
    /// class's own fresh cell made at this call, an escaping one too, `⊤`
    /// and `shared` as they are; what S3a does not interpret is `⊤`.
    fn mapCell(g: *Grafter, c: CellId, at: PlaceId) Error!CellId {
        const x = g.env.cells.get(c);
        return switch (x.origin) {
            .result, .esc => g.env.cells.result(g.gpa(), g.account(), x.origin, g.label, x.b, at, Cell.Kind.ofPlace(g.env.places.kind(at))),
            .top, .shared, .site, .mark => c,
            else => g.env.cells.top(g.gpa(), g.account()),
        };
    }

    /// The snapshot position of argument `i` at path `p` (`argAt`'s node's):
    /// the argument's snapshot walked along the path, stopping at `⟲` as
    /// `argAt` stops (the levels below are the value as it stands).
    fn argKappa(g: *Grafter, i: u32, p: PathId) Error!Cond.Kappas {
        if (i >= g.args.len) return .none;
        var steps: std.ArrayList(Step) = .empty;
        defer steps.deinit(g.gpa());
        try g.stepsOf(p, &steps);
        var at = g.args[i].kappa;
        for (steps.items) |s| {
            if (s.kind == .level or at == .none) break;
            at = g.env.conds.kappaChild(at, s);
        }
        return at;
    }

    fn relabelNode(ctx: *anyopaque, n: NodeId) ?NodeId {
        const g: *Grafter = @ptrCast(@alignCast(ctx));
        return g.s.memo.get(n);
    }

    fn instantiated(ctx: *anyopaque, t: *Cond.Table, gpa_: Allocator, charge: Ids.Charge, k: CondId) Error!CondId {
        return t.instantiate(gpa_, charge, k, .{ .ctx = ctx, .atom = Grafter.atom });
    }

    /// `kappa` with each argument's snapshot merged in at every position of
    /// the class's `res` whose cells name the argument (`π i·q`: the
    /// argument's position at `q`): the paths of `res`'s explicit
    /// structure, each `(node, path)` once. A route that meets a node it
    /// has passed (a widened class's knot) folds there (§2.9).
    fn linkArgs(g: *Grafter, kappa: Cond.Kappas, res: NodeId) Error!Cond.Kappas {
        var w: LinkWalk = .{ .out = kappa };
        defer w.deinit(g.gpa());
        try g.linkAt(&w, res, 0);
        return w.out;
    }

    const LinkWalk = struct {
        out: Cond.Kappas,
        path: std.ArrayList(Step) = .empty,
        /// The nodes on the way here, each with the path length it was at.
        route: std.ArrayList([2]u32) = .empty,
        /// Paths interned as `(parent, step)`, 0 the root; `(node, path)` visited.
        paths: Ids.FixedDict(2) = .{},
        visited: Ids.FixedDict(2) = .{},
        next_path: u32 = 1,

        fn deinit(w: *LinkWalk, gpa_: Allocator) void {
            w.path.deinit(gpa_);
            w.route.deinit(gpa_);
            w.paths.deinit(gpa_);
            w.visited.deinit(gpa_);
        }
    };

    fn linkAt(g: *Grafter, w: *LinkWalk, root: NodeId, root_pid: u32) Error!void {
        const shapes = g.env.shapes;
        const conds = g.env.conds;
        // A depth-first walk on an explicit stack (#1130: `res`'s depth is the
        // source's, never native-stack depth). An `enter` frame may carry the
        // step it is reached by; its `exit` frame takes the node off the
        // route and the step off the path.
        const Frame = struct { node: NodeId, pid: u32, step: ?Step, exit: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(g.gpa());
        var kids: std.ArrayList(Frame) = .empty;
        defer kids.deinit(g.gpa());
        try stack.append(g.gpa(), .{ .node = root, .pid = root_pid, .step = null, .exit = false });
        while (stack.pop()) |f| {
            if (f.exit) {
                _ = w.route.pop();
                if (f.step != null) _ = w.path.pop();
                continue;
            }
            const t = f.node;
            if (f.step) |s| try w.path.append(g.gpa(), s);
            try g.env.charge.reserve(g.gpa(), .memo, 1);
            const seen = try w.visited.getOrPut(g.gpa(), .{ t.int(), f.pid });
            if (seen.found_existing) {
                if (f.step != null) _ = w.path.pop();
                continue;
            }
            seen.value_ptr.* = 1;
            try g.env.charge.reserve(g.gpa(), .inspection, @intCast(w.route.items.len));
            const knot = for (w.route.items) |r| {
                if (r[0] == t.int()) break r[1];
            } else null;
            if (knot) |len| {
                // A knot: everything below is that position, folded.
                w.out = try conds.kappaAt(g.gpa(), g.env.charge, w.out, w.path.items[0..len], .fold);
                if (f.step != null) _ = w.path.pop();
                continue;
            }
            try w.route.append(g.gpa(), .{ t.int(), @intCast(w.path.items.len) });
            try stack.append(g.gpa(), .{ .node = t, .pid = f.pid, .step = f.step, .exit = true });
            var it = g.env.cells.sets.iterate(shapes.cells(t));
            while (it.next()) |e| {
                const cell: CellId = .from(e.key);
                if (g.env.cells.origin(cell) != .param) continue;
                try g.env.charge.reserve(g.gpa(), .inspection, 1);
                const x = g.env.cells.get(cell);
                w.out = try conds.kappaAt(g.gpa(), g.env.charge, w.out, w.path.items, .{ .merge = try g.argKappa(x.a, .from(x.b)) });
            }
            // The children, in the order the recursion took them: pushed in
            // reverse so the first is walked first.
            kids.clearRetainingCapacity();
            const d = shapes.get(t);
            switch (d.kind) {
                .leaf => {},
                .node, .delta => {
                    if (d.kind == .delta) try kids.append(g.gpa(), .{ .node = .from(d.a), .pid = f.pid, .step = null, .exit = false });
                    var kt = shapes.overEntries(if (d.kind == .node) d.a else d.b);
                    while (kt.next()) |e| {
                        try g.env.charge.reserve(g.gpa(), .memo, 1);
                        const got = try w.paths.getOrPut(g.gpa(), .{ f.pid, e.step.word() });
                        if (!got.found_existing) {
                            got.value_ptr.* = w.next_path;
                            w.next_path += 1;
                        }
                        try kids.append(g.gpa(), .{ .node = e.node, .pid = got.value_ptr.*, .step = e.step, .exit = false });
                    }
                },
                .recast => try kids.append(g.gpa(), .{ .node = .from(d.a), .pid = f.pid, .step = null, .exit = false }),
                .@"union", .positions => try kids.appendSlice(g.gpa(), &.{ .{ .node = .from(d.a), .pid = f.pid, .step = null, .exit = false }, .{ .node = .from(d.b), .pid = f.pid, .step = null, .exit = false } }),
            }
            var k = kids.items.len;
            while (k > 0) {
                k -= 1;
                try stack.append(g.gpa(), kids.items[k]);
            }
        }
    }
    /// Node `t` of the class's `res`, grafted onto the arguments.
    fn graft(g: *Grafter, root: NodeId) Error!NodeId {
        if (g.s.memo.get(root)) |m| return m;
        // Post-order on an explicit stack (#1130): `res`'s depth is the
        // source's, never native-stack depth. A node's parts are grafted
        // before it, each once (`memo`).
        // A cyclic `res` (a widened class's knot, #1138): a part met again
        // while it is being grafted gets a knot as its image, which the part
        // ties when it is done, so the walk ends and the image is cyclic too.
        // A knot is PENDING until it is tied: it has no place and no cells
        // yet. A node only names its parts, so it may be built over one; a
        // union, a positions node, a recast and a delta read their parts'
        // records, so one over a pending part is deferred, a knot of its own,
        // built once the parts it reads are tied (#1143).
        const shapes = g.env.shapes;
        const Frame = struct { node: NodeId, expanded: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(g.gpa());
        var open: stamped.Column(NodeId, void) = .{};
        defer open.deinit(g.gpa());
        var knots: stamped.Column(NodeId, NodeId) = .{};
        defer knots.deinit(g.gpa());
        var pending: stamped.Column(NodeId, void) = .{};
        defer pending.deinit(g.gpa());
        var deferred: std.ArrayList(NodeId) = .empty;
        defer deferred.deinit(g.gpa());
        try stack.append(g.gpa(), .{ .node = root, .expanded = false });
        while (stack.pop()) |f| {
            if (f.expanded) {
                open.remove(f.node);
                if (g.s.memo.get(f.node) != null and knots.get(f.node) == null) continue;
                if (g.readsPending(f.node, &pending)) {
                    const k = knots.get(f.node) orelse blk: {
                        const k = try shapes.knot(g.gpa(), g.account());
                        try knots.put(g.gpa(), f.node, k);
                        try pending.put(g.gpa(), k, {});
                        try g.s.memo.put(g.gpa(), f.node, k);
                        break :blk k;
                    };
                    _ = k;
                    try deferred.append(g.gpa(), f.node);
                    continue;
                }
                try g.graftTied(f.node, &knots, &pending);
                continue;
            }
            if (g.s.memo.get(f.node) != null) continue;
            if (open.contains(f.node)) {
                const k = try shapes.knot(g.gpa(), g.account());
                try knots.put(g.gpa(), f.node, k);
                try pending.put(g.gpa(), k, {});
                try g.s.memo.put(g.gpa(), f.node, k);
                continue;
            }
            try open.put(g.gpa(), f.node, {});
            try stack.append(g.gpa(), .{ .node = f.node, .expanded = true });
            const d = shapes.get(f.node);
            switch (d.kind) {
                .leaf => {},
                .node, .delta => {
                    if (d.kind == .delta) try stack.append(g.gpa(), .{ .node = .from(d.a), .expanded = false });
                    var kt = shapes.overEntries(if (d.kind == .node) d.a else d.b);
                    while (kt.next()) |e| try stack.append(g.gpa(), .{ .node = e.node, .expanded = false });
                },
                .recast => try stack.append(g.gpa(), .{ .node = .from(d.a), .expanded = false }),
                .@"union", .positions => try stack.appendSlice(g.gpa(), &.{ .{ .node = .from(d.a), .expanded = false }, .{ .node = .from(d.b), .expanded = false } }),
            }
        }
        // The deferred parts, each once what it reads is tied. A pass that
        // ties none is a cycle of reading parts with no node between them,
        // which no value has: the walk's own defect, never a program's.
        while (deferred.items.len > 0) {
            var kept: usize = 0;
            for (deferred.items) |x| {
                if (g.readsPending(x, &pending)) {
                    deferred.items[kept] = x;
                    kept += 1;
                    continue;
                }
                try g.graftTied(x, &knots, &pending);
            }
            if (kept == deferred.items.len) {
                const a = g.account();
                if (a.failed == null) a.failed = .{ .invariant = a.lane };
                return error.AccountingInvariant;
            }
            deferred.shrinkRetainingCapacity(kept);
        }
        return g.s.memo.get(root).?;
    }

    /// Whether `t`'s image would read the record of a pending knot: a
    /// union's or a positions node's sides, a recast's inner, a delta's base.
    fn readsPending(g: *Grafter, t: NodeId, pending: *const stamped.Column(NodeId, void)) bool {
        const d = g.env.shapes.get(t);
        const reads: [2]u32 = switch (d.kind) {
            .@"union", .positions => .{ d.a, d.b },
            .recast, .delta => .{ d.a, Ids.none_int },
            .leaf, .node => return false,
        };
        for (reads) |x| {
            if (x == Ids.none_int) continue;
            const img = g.s.memo.get(.from(x)) orelse continue;
            if (pending.contains(img)) return true;
        }
        return false;
    }

    /// `t` grafted, and tied when a knot stands for it.
    fn graftTied(g: *Grafter, t: NodeId, knots: *stamped.Column(NodeId, NodeId), pending: *stamped.Column(NodeId, void)) Error!void {
        const shapes = g.env.shapes;
        try g.graftOne(t);
        if (knots.get(t)) |k| {
            // The knot's record is the part's image, built as any.
            const built = g.s.memo.get(t).?;
            shapes.tie(k, shapes.nodes.get(built.int()));
            try g.s.memo.put(g.gpa(), t, k);
            pending.remove(k);
        }
    }

    /// Node `t` grafted, its parts' images in `memo` already.
    fn graftOne(g: *Grafter, t: NodeId) Error!void {
        const shapes = g.env.shapes;
        const d = shapes.get(t);
        const out: NodeId = switch (d.kind) {
            .leaf => try g.graftLeaf(d.place, d.cells),
            .node => blk: {
                var c: SetId = .none;
                var it = g.env.cells.sets.iterate(d.cells);
                while (it.next()) |e| {
                    const cell: CellId = .from(e.key);
                    if (g.env.cells.origin(cell) == .param) {
                        const x = g.env.cells.get(cell);
                        const arg = try g.argAt(x.a, .from(x.b), d.place);
                        c = try g.env.cells.sets.unionWith(g.gpa(), g.env.charge, c, shapes.cells(arg));
                        continue;
                    }
                    const m = try g.mapCell(cell, d.place);
                    if (g.env.cells.origin(m) == .esc) try g.s.escaped.append(g.gpa(), try shapes.leaf(g.gpa(), g.account(), d.place, try g.env.cells.sets.insert(g.gpa(), g.env.charge, .none, m.int(), 0)));
                    c = try g.env.cells.sets.insert(g.gpa(), g.env.charge, c, m.int(), e.value);
                }
                var kids: u32 = Ids.none_int;
                var kt = shapes.overEntries(d.a);
                while (kt.next()) |e| kids = try shapes.overPut(g.gpa(), g.account(), kids, e.step, g.s.memo.get(e.node).?);
                break :blk try shapes.node(g.gpa(), g.account(), d.place, c, kids);
            },
            .delta => blk: {
                var n = g.s.memo.get(.from(d.a)).?;
                var kt = shapes.overEntries(d.b);
                while (kt.next()) |e| n = try shapes.put(g.gpa(), g.account(), g.env.places, g.env.cells, n, e.step, g.s.memo.get(e.node).?, true, .none);
                break :blk n;
            },
            .recast => try shapes.recast(g.gpa(), g.account(), d.place, g.s.memo.get(.from(d.a)).?),
            .@"union" => blk: {
                var two = [_]NodeId{ g.s.memo.get(.from(d.a)).?, g.s.memo.get(.from(d.b)).? };
                break :blk try shapes.join(g.gpa(), g.account(), g.env.places, g.env.cells, &two);
            },
            .positions => try shapes.collect(g.gpa(), g.account(), &g.env.cells.sets, &.{ g.s.memo.get(.from(d.a)).?, g.s.memo.get(.from(d.b)).? }),
        };
        try g.s.memo.put(g.gpa(), t, out);
    }

    /// A leaf: each parameter cell the argument there, the rest one leaf of
    /// mapped cells, all of it joined (they are alternatives at one path).
    fn graftLeaf(g: *Grafter, at: PlaceId, cells: SetId) Error!NodeId {
        const first = g.s.members.items.len;
        defer g.s.members.shrinkRetainingCapacity(first);
        var rest: SetId = .none;
        var it = g.env.cells.sets.iterate(cells);
        while (it.next()) |e| {
            const cell: CellId = .from(e.key);
            if (g.env.cells.origin(cell) == .param) {
                const x = g.env.cells.get(cell);
                var n = try g.argAt(x.a, .from(x.b), at);
                if (e.value == 1) n = try g.env.shapes.recast(g.gpa(), g.account(), at, n);
                try g.s.members.append(g.gpa(), n);
                continue;
            }
            const m = try g.mapCell(cell, at);
            rest = try g.env.cells.sets.insert(g.gpa(), g.env.charge, rest, m.int(), e.value);
            if (g.env.cells.origin(m) == .esc) try g.s.escaped.append(g.gpa(), try g.env.shapes.leaf(g.gpa(), g.account(), at, try g.env.cells.sets.insert(g.gpa(), g.env.charge, .none, m.int(), 0)));
        }
        if (rest != .none or g.s.members.items.len == first) try g.s.members.append(g.gpa(), try g.env.shapes.leaf(g.gpa(), g.account(), at, rest));
        const ms = g.s.members.items[first..];
        if (ms.len == 1) return ms[0];
        const copy = try g.gpa().dupe(NodeId, ms);
        defer g.gpa().free(copy);
        return g.env.shapes.join(g.gpa(), g.account(), g.env.places, g.env.cells, copy);
    }

    /// The cells a class cell stands for at this call: a parameter's, the
    /// argument's at that path; anything else its mapped self.
    fn cellsOf(g: *Grafter, c: CellId, at: PlaceId) Error!SetId {
        const x = g.env.cells.get(c);
        if (x.origin == .param) return g.env.shapes.cells(try g.argAt(x.a, .from(x.b), at));
        if (x.origin.isSymbolic() and x.origin != .top) return g.env.cells.sets.insert(g.gpa(), g.env.charge, .none, (try g.env.cells.top(g.gpa(), g.account())).int(), 1);
        return g.env.cells.sets.insert(g.gpa(), g.env.charge, .none, (try g.mapCell(c, at)).int(), 0);
    }

    fn placeOfCell(g: *Grafter, c: CellId) PlaceId {
        const x = g.env.cells.get(c);
        return if (x.origin.isSymbolic() and x.origin != .top) g.env.places.pathPlace(.from(x.b)) else x.place;
    }

    fn addItems(g: *Grafter, s: SetId, items: *std.ArrayList(Cond.Item)) Error!void {
        var it = g.env.cells.sets.iterate(s);
        while (it.next()) |e| {
            try g.env.charge.reserve(g.gpa(), .inspection, 1);
            if (g.env.cells.origin(.from(e.key)) == .mark) continue;
            try items.append(g.gpa(), .{ .cell = .from(e.key), .approx = e.value == 1 });
        }
    }

    /// §2.9's interpretation of one atom at this call.
    fn atom(ctx: *anyopaque, t: *Cond.Table, gpa_: Allocator, charge: Ids.Charge, a: Cond.Cond) Error!CondId {
        const g: *Grafter = @ptrCast(@alignCast(ctx));
        _ = charge;
        switch (a.atom) {
            .excl => {
                const c: CellId = .from(a.a);
                const x = g.env.cells.get(c);
                if (x.origin != .param) return if (x.origin == .result or x.origin == .esc) Cond.yes else Cond.lost;
                const at = g.placeOfCell(c);
                const n = try g.argAt(x.a, .from(x.b), at);
                const kappa = try g.argKappa(x.a, .from(x.b));
                return t.deep(gpa_, g.env.charge, g.env.view(), kappa, n, g.env.places.isSummary(.from(x.b)));
            },
            .sep, .apart => {
                var items: std.ArrayList(Cond.Item) = .empty;
                defer items.deinit(gpa_);
                if (a.atom == .sep) {
                    for ([_]u32{ a.a, a.b }) |side| {
                        const c: CellId = .from(side);
                        try g.addItems(try g.cellsOf(c, g.placeOfCell(c)), &items);
                    }
                } else {
                    var it = g.env.cells.sets.iterate(.from(a.a));
                    while (it.next()) |e| {
                        const c: CellId = .from(e.key);
                        try g.addItems(try g.cellsOf(c, g.placeOfCell(c)), &items);
                    }
                }
                return t.apart(gpa_, g.env.charge, g.env.cells, g.env.places, items.items, null);
            },
            .within, .keep, .writes => return Cond.lost,
        }
    }
};

/// The writes and escapes a use shape marks, with their paths: a walk of
/// its explicit structure (a leaf's marks hold below it, so a leaf ends a
/// path). Every node visited is a record.
fn marked(env: Env, use: NodeId, param: u32, s: *Scratch) Error!void {
    if (use == .none) return;
    // Paths as parent chains: a node's path is its entry's.
    const Entry = struct { step: Step, parent: u32 };
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(env.gpa);
    const Frame = struct { node: NodeId, entry: u32 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(env.gpa);
    try stack.append(env.gpa, .{ .node = use, .entry = Ids.none_int });
    while (stack.pop()) |f| {
        try env.charge.reserve(env.gpa, .inspection, 1);
        var w = false;
        var e = false;
        var deep = false;
        var it = env.cells.sets.iterate(env.shapes.cells(f.node));
        while (it.next()) |x| {
            const c: CellId = .from(x.key);
            if (env.cells.origin(c) != .mark) continue;
            switch (env.cells.markOf(c)) {
                .w => w = true,
                .e => e = true,
                .deep => deep = true,
                else => {},
            }
        }
        if (w or e) {
            const start: u32 = @intCast(s.steps.items.len);
            var at = f.entry;
            while (at != Ids.none_int) : (at = entries.items[at].parent) try s.steps.append(env.gpa, entries.items[at].step);
            std.mem.reverse(Step, s.steps.items[start..]);
            const r: Ids.Range = .{ .start = start, .len = @intCast(s.steps.items.len - start) };
            if (w) try s.writes.append(env.gpa, .{ .param = param, .steps = r, .deep = deep });
            if (e) try s.escapes.append(env.gpa, .{ .param = param, .steps = r });
        }
        if (env.shapes.kind(f.node) != .node) continue;
        var kt = env.shapes.overEntries(env.shapes.get(f.node).a);
        while (kt.next()) |k| {
            const id: u32 = @intCast(entries.items.len);
            try entries.append(env.gpa, .{ .step = k.step, .parent = f.entry });
            try stack.append(env.gpa, .{ .node = k.node, .entry = id });
        }
    }
}

/// Apply class `class` at call instruction `inst` to `args` (§2.11). The
/// answer's slices live in `s` until its next call.
pub fn apply(env: Env, sums: *const Summary.Table, class: ClassId, args: []const Value, inst: u32, s: *Scratch) Error!Applied {
    const gpa = env.gpa;
    s.memo.clear();
    s.writes.clearRetainingCapacity();
    s.escapes.clearRetainingCapacity();
    s.escaped.clearRetainingCapacity();
    s.steps.clearRetainingCapacity();
    const cls = sums.get(class);
    const label = try env.cells.label(gpa, env.account(), inst, .none, false);
    var g: Grafter = .{ .env = env, .sums = sums, .args = args, .label = label, .s = s };
    // 2, 3: the writes and escapes the use shapes mark.
    for (sums.paramUses(class), 0..) |u, i| try marked(env, u, @intCast(i), s);
    // 4: the result.
    const res = try g.graft(cls.res);
    // 5: the class's κ relabelled onto the result, each entry's path
    // unchanged and its condition instantiated, then each argument's
    // snapshot linked where the argument stands in the result (§2.9).
    var kappa = try env.conds.kappaRelabel(gpa, env.charge, cls.kappas, .{ .ctx = &g, .node = Grafter.relabelNode, .cond = Grafter.instantiated });
    kappa = try g.linkArgs(kappa, cls.res);
    var xreq: CondId = Cond.yes;
    if (cls.xreq != .none) {
        var at = env.conds.atoms.iterate(cls.xreq);
        while (at.next()) |e| {
            try env.charge.reserve(gpa, .inspection, 1);
            xreq = try env.conds.@"and"(gpa, env.charge, xreq, try Grafter.atom(&g, env.conds, gpa, env.charge, env.conds.get(.from(e.key))));
        }
    }
    return .{
        .result = .{ .node = res, .kappa = kappa },
        .xreq = xreq,
        .writes = s.writes.items,
        .escapes = s.escapes.items,
        .escaped = s.escaped.items,
        .steps = s.steps.items,
    };
}

comptime {
    Ids.assertRecord(Write);
    Ids.assertRecord(Escape);
    _ = Facts;
}

// ---- tests ---------------------------------------------------------------------------------------

const testing = std.testing;
const Place = @import("Place.zig");

/// `type T = T (List T)`: 0 the constructor, 1 its list.
const TestGraph = struct {
    table: *Place.Table,
    account: *Ids.Account,
    gpa: Allocator,

    fn describe(ctx: *anyopaque, v: u32, out: *std.ArrayList(Place.Child)) Allocator.Error!Place.Description {
        const g: *TestGraph = @ptrCast(@alignCast(ctx));
        switch (v) {
            0 => {
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 0, 0) catch unreachable), .@"var" = 1 });
                return .{ .kind = .ctor, .head = 300 };
            },
            1 => {
                try out.append(g.gpa, .{ .step = Place.Step.elem, .@"var" = 0 });
                return .{ .kind = .list, .head = 200 };
            },
            else => unreachable,
        }
    }
};

test "#1130: a call grafts and links a result as deep as the source, on explicit stacks" {
    // On a thread with a small stack (a wasm build's is 1 MiB): a native
    // frame per level of the source would overflow it.
    var result: anyerror!void = {};
    const th = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, struct {
        fn run(out: *anyerror!void) void {
            out.* = deepCall();
        }
    }.run, .{&result});
    th.join();
    try result;
}

fn deepCall() !void {
    const gpa = testing.allocator;
    var places: Place.Table = .{};
    defer places.deinit(gpa);
    var cells: Cell.Table = .{};
    defer cells.deinit(gpa);
    var shapes: Shape.Table = .{};
    defer shapes.deinit(gpa);
    var account: Ids.Account = .{ .allowance = std.math.maxInt(u32) - 1 };
    defer account.deinit(gpa);
    var conds = try Cond.Table.init(gpa, .growth(&account));
    defer conds.deinit(gpa);
    var sums: Summary.Table = .{};
    defer sums.deinit(gpa);
    var graph: TestGraph = .{ .table = &places, .account = &account, .gpa = gpa };
    const src: Place.Source = .{ .ctx = &graph, .describe = TestGraph.describe };
    const t_place = try places.of(gpa, &account, src, 0);
    const list = try places.of(gpa, &account, src, 1);
    const arg = try places.ctorStep(gpa, &account, 0, 0);
    const env: Env = .{ .gpa = gpa, .charge = .growth(&account), .places = &places, .cells = &cells, .shapes = &shapes, .conds = &conds };
    // `res`: 30 000 levels of `T [ … ]` over the parameter at the bottom (60 000
    // path steps, inside `path_steps`), deeper than a native frame per level allows.
    const p = try cells.symbolic(gpa, &account, &places, .param, 0, try places.rootPath(gpa, t_place), 0);
    var n = try shapes.leaf(gpa, &account, t_place, try cells.sets.insert(gpa, env.charge, .none, p.int(), 0));
    const depth = 30_000;
    for (0..depth) |i| {
        const l = try shapes.node(gpa, &account, list, try cells.sets.insert(gpa, env.charge, .none, (try cells.site(gpa, &account, @intCast(i + 1), list, .list)).int(), 0), try shapes.overPut(gpa, &account, Ids.none_int, Place.Step.elem, n));
        n = try shapes.node(gpa, &account, t_place, .none, try shapes.overPut(gpa, &account, Ids.none_int, arg, l));
    }
    const c = try sums.add(env, .{ .params = &.{.none}, .res = n, .kappas = .none });
    // The argument: a leaf with a snapshot of its own, merged at the bottom.
    const site = try cells.site(gpa, &account, depth + 1, t_place, .record);
    const a = try shapes.leaf(gpa, &account, t_place, try cells.sets.insert(gpa, env.charge, .none, site.int(), 0));
    const ak = (try conds.kappaSet(gpa, env.charge, .none, a, Cond.yes)).ctx;
    var s: Scratch = .{};
    defer s.deinit(gpa);
    const applied = try apply(env, &sums, c, &.{.{ .node = a, .kappa = ak }}, 0, &s);
    // The bottom of the result is the argument, its κ there.
    var at = applied.result;
    for (0..depth) |_| {
        at.node = (try shapes.proj(gpa, &account, &places, &cells, at.node, arg)).?;
        at.kappa = conds.kappaChild(at.kappa, arg);
        at.node = (try shapes.proj(gpa, &account, &places, &cells, at.node, Place.Step.elem)).?;
        at.kappa = conds.kappaChild(at.kappa, Place.Step.elem);
    }
    try testing.expectEqual(a, at.node);
    try testing.expectEqual(Cond.yes, conds.kappaGet(at.kappa, a).?);
}

test "#1138: a call grafts a cyclic result (a widened knot) into a cyclic image, and ends" {
    const gpa = testing.allocator;
    var places: Place.Table = .{};
    defer places.deinit(gpa);
    var cells: Cell.Table = .{};
    defer cells.deinit(gpa);
    var shapes: Shape.Table = .{};
    defer shapes.deinit(gpa);
    var account: Ids.Account = .{};
    defer account.deinit(gpa);
    var conds = try Cond.Table.init(gpa, .growth(&account));
    defer conds.deinit(gpa);
    var sums: Summary.Table = .{};
    defer sums.deinit(gpa);
    var graph: TestGraph = .{ .table = &places, .account = &account, .gpa = gpa };
    const src: Place.Source = .{ .ctx = &graph, .describe = TestGraph.describe };
    const t_place = try places.of(gpa, &account, src, 0);
    const list = try places.of(gpa, &account, src, 1);
    const arg = try places.ctorStep(gpa, &account, 0, 0);
    const env: Env = .{ .gpa = gpa, .charge = .growth(&account), .places = &places, .cells = &cells, .shapes = &shapes, .conds = &conds };
    // `res` is a knot: `T` whose list's `[*]` is the `T` itself, the list a
    // union with the parameter's leaf.
    const p = try cells.symbolic(gpa, &account, &places, .param, 0, try places.rootPath(gpa, list), 0);
    const pl = try shapes.leaf(gpa, &account, list, try cells.sets.insert(gpa, env.charge, .none, p.int(), 0));
    const t = try shapes.knot(gpa, &account);
    const l = try shapes.knot(gpa, &account);
    const site = try cells.site(gpa, &account, 1, list, .list);
    shapes.tie(l, .{ .kind = .node, .place = list, .cells = try cells.sets.insert(gpa, env.charge, .none, site.int(), 0), .a = try shapes.overPut(gpa, &account, Ids.none_int, Place.Step.elem, t), .b = 0, .reach = .none });
    const u = try shapes.@"union"(gpa, &account, &cells.sets, l, pl);
    shapes.tie(t, .{ .kind = .node, .place = t_place, .cells = .none, .a = try shapes.overPut(gpa, &account, Ids.none_int, arg, u), .b = 0, .reach = .none });
    const c = try sums.add(env, .{ .params = &.{.none}, .res = t, .kappas = .none });
    // The argument: a list of its own.
    const arg_site = try cells.site(gpa, &account, 2, list, .list);
    const a = try shapes.leaf(gpa, &account, list, try cells.sets.insert(gpa, env.charge, .none, arg_site.int(), 0));
    var s: Scratch = .{};
    defer s.deinit(gpa);
    const applied = try apply(env, &sums, c, &.{.{ .node = a, .kappa = .none }}, 0, &s);
    // The image is cyclic: down `#T.0` and `[*]` is the image again.
    const r = applied.result.node;
    try testing.expectEqual(Shape.Kind.node, shapes.kind(r));
    const ul = (try shapes.proj(gpa, &account, &places, &cells, r, arg)).?;
    const back = (try shapes.proj(gpa, &account, &places, &cells, ul, Place.Step.elem)).?;
    try testing.expect(back == r or (shapes.kind(back) == .@"union" and (shapes.get(back).a == r.int() or shapes.get(back).b == r.int())));
}

test "#1143: a back edge onto a union's side is grafted once the knot is tied" {
    const gpa = testing.allocator;
    var places: Place.Table = .{};
    defer places.deinit(gpa);
    var cells: Cell.Table = .{};
    defer cells.deinit(gpa);
    var shapes: Shape.Table = .{};
    defer shapes.deinit(gpa);
    var account: Ids.Account = .{};
    defer account.deinit(gpa);
    var conds = try Cond.Table.init(gpa, .growth(&account));
    defer conds.deinit(gpa);
    var sums: Summary.Table = .{};
    defer sums.deinit(gpa);
    var graph: TestGraph = .{ .table = &places, .account = &account, .gpa = gpa };
    const src: Place.Source = .{ .ctx = &graph, .describe = TestGraph.describe };
    const t_place = try places.of(gpa, &account, src, 0);
    const list = try places.of(gpa, &account, src, 1);
    const arg = try places.ctorStep(gpa, &account, 0, 0);
    const env: Env = .{ .gpa = gpa, .charge = .growth(&account), .places = &places, .cells = &cells, .shapes = &shapes, .conds = &conds };
    // `T` whose list's `[*]` is `union(T, the parameter's leaf)`: the back
    // edge lands on the union's side itself.
    const p = try cells.symbolic(gpa, &account, &places, .param, 0, try places.rootPath(gpa, t_place), 0);
    const pl = try shapes.leaf(gpa, &account, t_place, try cells.sets.insert(gpa, env.charge, .none, p.int(), 0));
    const t = try shapes.knot(gpa, &account);
    const l = try shapes.knot(gpa, &account);
    const u = try shapes.knot(gpa, &account);
    shapes.tie(u, .{ .kind = .@"union", .place = t_place, .cells = shapes.cells(pl), .a = t.int(), .b = pl.int(), .reach = .none });
    const site = try cells.site(gpa, &account, 1, list, .list);
    shapes.tie(l, .{ .kind = .node, .place = list, .cells = try cells.sets.insert(gpa, env.charge, .none, site.int(), 0), .a = try shapes.overPut(gpa, &account, Ids.none_int, Place.Step.elem, u), .b = 0, .reach = .none });
    shapes.tie(t, .{ .kind = .node, .place = t_place, .cells = .none, .a = try shapes.overPut(gpa, &account, Ids.none_int, arg, l), .b = 0, .reach = .none });
    const c = try sums.add(env, .{ .params = &.{.none}, .res = t, .kappas = .none });
    const asite = try cells.site(gpa, &account, 2, t_place, .record);
    const a = try shapes.leaf(gpa, &account, t_place, try cells.sets.insert(gpa, env.charge, .none, asite.int(), 0));
    var s: Scratch = .{};
    defer s.deinit(gpa);
    const applied = try apply(env, &sums, c, &.{.{ .node = a, .kappa = .none }}, 0, &s);
    // The image: `T`, its list's `[*]` a union whose one side is the image
    // and the other the argument (the parameter's leaf grafted).
    const r = applied.result.node;
    try testing.expectEqual(Shape.Kind.node, shapes.kind(r));
    const ul = (try shapes.proj(gpa, &account, &places, &cells, r, arg)).?;
    const back = (try shapes.proj(gpa, &account, &places, &cells, ul, Place.Step.elem)).?;
    try testing.expectEqual(Shape.Kind.@"union", shapes.kind(back));
    try testing.expectEqual(t_place, shapes.place(back));
    const d = shapes.get(back);
    try testing.expect(d.a == r.int() or d.b == r.int());
    // Its cells are the argument's: what the tied sides hold.
    try testing.expect(cells.sets.member(shapes.cells(back), asite.int()));
}
