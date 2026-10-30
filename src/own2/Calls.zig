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
const Place = @import("Place.zig");
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
/// A parameter path the class marks, and whether it holds what is there
/// (answers or lets it escape: `A`, `E`).
pub const Touch = struct { param: u32, steps: Ids.Range, held: bool };

pub const Applied = struct {
    result: Value,
    /// The instantiated `xreq`: `yes` when the class relies on nothing.
    xreq: CondId,
    writes: []const Write,
    escapes: []const Escape,
    /// Every parameter path the class marks (R, A, W or E): what a write's
    /// Disjoint checks against, beside the other arguments (§2.11 item 3).
    touched: []const Touch = &.{},
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
    touched: std.ArrayList(Touch) = .empty,
    steps: std.ArrayList(Step) = .empty,
    members: std.ArrayList(NodeId) = .empty,

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        s.memo.deinit(gpa);
        s.writes.deinit(gpa);
        s.escapes.deinit(gpa);
        s.escaped.deinit(gpa);
        s.touched.deinit(gpa);
        s.steps.deinit(gpa);
        s.members.deinit(gpa);
    }
};

/// §2.9's path-multiset primitive over a folded template path's full
/// preimage (#1159). The source is the argument `x` at the re-entered
/// place's path `prefix`; each source position is keyed by its canonical
/// path, so every depth a template path through `⟲` stands for meets at one
/// key, and its occurrences there are a multiset. A node's parts and a
/// `positions` node's sides coexist (they add); a `choice`'s arms take the
/// maximum, whole arm by whole arm; a `union` holds its cells at its own
/// position as a set, its sides' structure below coexisting (§2.3, *One
/// reading of `union`*). Below a leaf's symbolic cells and refinements,
/// a `⊤` cell or a recast, every canonical path reads `⊤` (`lost`, as master;
/// the precise projections are #1199). A source on a cycle reaches each key below it at
/// unboundedly many coexisting positions, so the components of the walk
/// (Tarjan, explicit stack) settle once each, a cycle's occurrences all
/// repeated — a backedge is an equation, never a count per visit. Kept by
/// `(x, prefix)` in the table across reads and calls; nothing it reads
/// changes.
fn preimage(env: Env, x: NodeId, prefix: PathId) Error!Cond.Table.ClassAggs {
    if (try env.conds.classesMemo(env.gpa, env.charge, x, prefix.int())) |hit| return hit;
    var w: Pre = .{ .env = env };
    defer w.deinit();
    const out = try w.run(x, prefix);
    try env.conds.classesRemember(env.gpa, env.charge, x, prefix.int(), out);
    return out;
}

const Pre = struct {
    env: Env,
    /// `(node, path, below)` → state; `below` leaves out the node's own
    /// cells at its path (a `union` side's, which the union holds as a set).
    index: Ids.FixedDict(3) = .{},
    states: std.ArrayList(State) = .empty,
    parts: std.ArrayList(u32) = .empty,
    todo: std.ArrayList(u32) = .empty,
    /// One expansion's own contributions, key → its cells.
    own: std.ArrayList(Own) = .empty,
    own_at: Ids.FixedDict(1) = .{},

    const State = struct { node: NodeId, path: PathId, below: bool, max: bool = false, parts: Ids.Range = .empty, own: Cond.Table.ClassAggs = .{} };
    const Own = struct { key: u32, cells: SetId };

    fn deinit(w: *Pre) void {
        const gpa = w.env.gpa;
        w.index.deinit(gpa);
        w.states.deinit(gpa);
        w.parts.deinit(gpa);
        w.todo.deinit(gpa);
        w.own.deinit(gpa);
        w.own_at.deinit(gpa);
    }

    fn state(w: *Pre, n: NodeId, path: PathId, below: bool) Error!u32 {
        const gpa = w.env.gpa;
        try w.env.charge.reserve(gpa, .task, 1);
        const got = try w.index.getOrPut(gpa, .{ n.int(), path.int(), @intFromBool(below) });
        if (got.found_existing) return got.value_ptr.*;
        got.value_ptr.* = @intCast(w.states.items.len);
        try w.states.append(gpa, .{ .node = n, .path = path, .below = below });
        try w.todo.append(gpa, got.value_ptr.*);
        return got.value_ptr.*;
    }

    fn part(w: *Pre, n: NodeId, path: PathId, below: bool) Error!void {
        const s = try w.state(n, path, below);
        try w.parts.append(w.env.gpa, s);
    }

    /// `c` at `key`, approximate when `approx` (kept approximate if either).
    fn add(w: *Pre, key: PathId, c: CellId, approx: bool) Error!void {
        const gpa = w.env.gpa;
        const sets = &w.env.cells.sets;
        const got = try w.own_at.getOrPut(gpa, .{key.int()});
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(w.own.items.len);
            try w.own.append(gpa, .{ .key = key.int(), .cells = .none });
        }
        const o = &w.own.items[got.value_ptr.*];
        const v: u1 = @intFromBool(approx or (sets.get(o.cells, c.int()) orelse 0) == 1);
        o.cells = try sets.insert(gpa, w.env.charge, o.cells, c.int(), v);
    }

    fn addAll(w: *Pre, key: PathId, s: SetId, approx: bool) Error!void {
        var it = w.env.cells.sets.iterate(s);
        while (it.next()) |e| {
            try w.env.charge.reserve(w.env.gpa, .inspection, 1);
            try w.add(key, .from(e.key), approx or e.value == 1);
        }
    }

    /// What `c`, held at `path`, stands for below it: its projection at
    /// every canonical path below (a pair walk over the argument's paths and
    /// the cell's own, each pair once); `⊤` for a `⊤` cell or one whose own
    /// place differs from the position's; nothing for a concrete cell.
    fn project(w: *Pre, c: CellId, approx: bool, path: PathId) Error!void {
        const gpa = w.env.gpa;
        const charge = w.env.charge;
        const cells = w.env.cells;
        const places = w.env.places;
        const account = w.env.account();
        var sym: ?CellId = null;
        switch (cells.origin(c)) {
            .site, .result, .esc, .mark => return,
            .top => {},
            .elem, .others, .level, .below, .loan => sym = (try cells.unrefined(gpa, account, places, c)) orelse return,
            .param, .env, .shared, .cb, .msg => sym = c,
        }
        if (sym) |s| if (!cells.origin(s).isSymbolic() or cells.origin(s) == .top or places.pathPlace(.from(cells.get(s).b)) != places.pathPlace(path)) {
            sym = null;
        };
        const top = if (sym == null) try cells.top(gpa, account) else CellId.none;
        var seen: Ids.FixedDict(2) = .{};
        defer seen.deinit(gpa);
        var stack: std.ArrayList([2]PathId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, .{ path, if (sym) |s| PathId.from(cells.get(s).b) else .none });
        while (stack.pop()) |at| {
            for (places.steps(places.pathPlace(at[0])).steps) |s| {
                try charge.reserve(gpa, .inspection, 1);
                const ap = (try places.extend(gpa, charge, at[0], s)) orelse continue;
                const cp: PathId = if (sym != null) (try places.extend(gpa, charge, at[1], s)) orelse continue else .none;
                const got = try seen.getOrPut(gpa, .{ ap.int(), cp.int() });
                if (got.found_existing) continue;
                got.value_ptr.* = 0;
                if (sym) |x| {
                    const d = cells.get(x);
                    try w.add(ap, try cells.symbolic(gpa, account, places, d.origin, d.a, cp, d.c), approx);
                } else try w.add(ap, top, true);
                try stack.append(gpa, .{ ap, cp });
            }
        }
    }

    /// One state's own contributions and parts.
    fn expand(w: *Pre, id: u32) Error!void {
        const gpa = w.env.gpa;
        const charge = w.env.charge;
        const shapes = w.env.shapes;
        const st = w.states.items[id];
        const d = shapes.get(st.node);
        w.own.clearRetainingCapacity();
        w.own_at.deinit(gpa);
        w.own_at = .{};
        const first: u32 = @intCast(w.parts.items.len);
        var max = false;
        switch (d.kind) {
            .node, .delta => {
                if (!st.below) try w.addAll(st.path, try shapes.cellsOf(gpa, w.env.account(), &w.env.cells.sets, st.node), false);
                const over = if (d.kind == .node) d.a else d.b;
                var it = shapes.overEntries(over);
                while (it.next()) |e| try w.child(st.path, e.step, e.node);
                if (d.kind == .delta) {
                    const base = try shapes.force(gpa, w.env.account(), .from(d.a));
                    if (shapes.kind(base) == .node) {
                        var bt = shapes.overEntries(shapes.get(base).a);
                        while (bt.next()) |e| if (shapes.overGet(d.b, e.step) == null) try w.child(st.path, e.step, e.node);
                    } else try w.part(base, st.path, true); // its projections, overridden steps too: more, never fewer
                }
            },
            .leaf, .recast => {
                var it = w.env.cells.sets.iterate(d.cells);
                while (it.next()) |e| {
                    try charge.reserve(gpa, .inspection, 1);
                    const approx = e.value == 1 or d.kind == .recast;
                    if (!st.below) try w.add(st.path, .from(e.key), approx);
                    if (d.kind == .leaf) try w.project(.from(e.key), approx, st.path);
                }
                // Below a recast, its inner read at another type: `⊤`.
                if (d.kind == .recast) try w.project(try w.env.cells.top(gpa, w.env.account()), true, st.path);
            },
            .@"union" => {
                if (!st.below) try w.addAll(st.path, try shapes.cellsOf(gpa, w.env.account(), &w.env.cells.sets, st.node), false);
                try w.unionSides(st.node, st.path);
            },
            // A view is its answer at the same path: one part (§2.11).
            .view => try w.part(try shapes.force(gpa, w.env.account(), st.node), st.path, st.below),
            .choice, .positions => {
                max = d.kind == .choice;
                try w.part(.from(d.a), st.path, st.below);
                try w.part(.from(d.b), st.path, st.below);
            },
        }
        var own: Cond.Table.ClassAggs = .{};
        for (w.own.items) |o| own = try w.env.conds.classesMerge(gpa, charge, w.env.view(), own, try w.env.conds.classesOf(gpa, charge, w.env.cells, w.env.places, o.key, o.cells), true);
        const s = &w.states.items[id];
        s.own = own;
        s.max = max;
        s.parts = .{ .start = first, .len = @as(u32, @intCast(w.parts.items.len)) - first };
    }

    fn child(w: *Pre, path: PathId, s: Step, n: NodeId) Error!void {
        const cp = (try w.env.places.extend(w.env.gpa, w.env.charge, path, s)) orelse return;
        try w.part(n, cp, false);
    }

    /// A union's sides as parts at its path, through nested unions (a union
    /// DAG, each member once): a built side's structure below (its own cells
    /// are the union's set); a `choice` or `positions` side whole, its cells
    /// counted again (more, never fewer).
    fn unionSides(w: *Pre, u: NodeId, path: PathId) Error!void {
        const gpa = w.env.gpa;
        const shapes = w.env.shapes;
        var seen: stamped.Column(NodeId, void) = .{};
        defer seen.deinit(gpa);
        var stack: std.ArrayList(NodeId) = .empty;
        defer stack.deinit(gpa);
        try stack.appendSlice(gpa, &.{ .from(shapes.get(u).a), .from(shapes.get(u).b) });
        while (stack.pop()) |m| {
            if (seen.contains(m)) continue;
            try seen.put(gpa, m, {});
            try w.env.charge.reserve(gpa, .inspection, 1);
            switch (shapes.kind(m)) {
                .@"union" => try stack.appendSlice(gpa, &.{ .from(shapes.get(m).a), .from(shapes.get(m).b) }),
                .choice, .positions => try w.part(m, path, false),
                .node, .delta, .leaf, .recast => try w.part(m, path, true),
                // A side that is a view stands for its answer (§2.11).
                .view => try stack.append(gpa, try shapes.force(gpa, w.env.account(), m)),
            }
        }
    }

    fn run(w: *Pre, x: NodeId, prefix: PathId) Error!Cond.Table.ClassAggs {
        const gpa = w.env.gpa;
        const charge = w.env.charge;
        const root = try w.state(x, prefix, false);
        while (w.todo.pop()) |id| try w.expand(id);
        // Tarjan over the states, each component settled once.
        const n = w.states.items.len;
        const none = Ids.none_int;
        var index = try gpa.alloc(u32, n);
        defer gpa.free(index);
        var low = try gpa.alloc(u32, n);
        defer gpa.free(low);
        var comp = try gpa.alloc(u32, n);
        defer gpa.free(comp);
        const acc = try gpa.alloc(Cond.Table.ClassAggs, n);
        defer gpa.free(acc);
        @memset(index, none);
        @memset(comp, none);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(gpa);
        const Frame = struct { id: u32, cursor: u32 };
        var frames: std.ArrayList(Frame) = .empty;
        defer frames.deinit(gpa);
        var counter: u32 = 0;
        var comps: u32 = 0;
        index[root] = 0;
        low[root] = 0;
        counter = 1;
        try stack.append(gpa, root);
        try frames.append(gpa, .{ .id = root, .cursor = 0 });
        while (frames.items.len > 0) {
            const top = &frames.items[frames.items.len - 1];
            const ps = w.states.items[top.id].parts;
            if (top.cursor < ps.len) {
                const p = w.parts.items[ps.start + top.cursor];
                top.cursor += 1;
                try charge.reserve(gpa, .inspection, 1);
                if (index[p] == none) {
                    index[p] = counter;
                    low[p] = counter;
                    counter += 1;
                    try stack.append(gpa, p);
                    try frames.append(gpa, .{ .id = p, .cursor = 0 });
                } else if (comp[p] == none) low[top.id] = @min(low[top.id], index[p]);
                continue;
            }
            const id = top.id;
            _ = frames.pop();
            if (frames.items.len > 0) {
                const parent = frames.items[frames.items.len - 1].id;
                low[parent] = @min(low[parent], low[id]);
            }
            if (low[id] != index[id]) continue;
            var at = stack.items.len;
            while (true) {
                at -= 1;
                comp[stack.items[at]] = comps;
                if (stack.items[at] == id) break;
            }
            const members = stack.items[at..];
            try w.settle(members, comps, comp, acc);
            comps += 1;
            stack.shrinkRetainingCapacity(at);
        }
        return acc[root];
    }

    /// A component's occurrences: one state, its own cells and its parts'
    /// (a choice by the maximum); a cycle, everything its members and their
    /// parts hold, all repeated.
    fn settle(w: *Pre, members: []const u32, c: u32, comp: []const u32, acc: []Cond.Table.ClassAggs) Error!void {
        const gpa = w.env.gpa;
        const charge = w.env.charge;
        const conds = w.env.conds;
        const v = w.env.view();
        var cyclic = members.len > 1;
        if (!cyclic) {
            const s = w.states.items[members[0]];
            for (w.parts.items[s.parts.start..][0..s.parts.len]) |p| cyclic = cyclic or p == members[0];
        }
        if (!cyclic) {
            const s = w.states.items[members[0]];
            var parts: Cond.Table.ClassAggs = .{};
            for (w.parts.items[s.parts.start..][0..s.parts.len], 0..) |p, i| {
                try charge.reserve(gpa, .memo, 1);
                parts = if (i == 0) acc[p] else try conds.classesMerge(gpa, charge, v, parts, acc[p], !s.max);
            }
            acc[members[0]] = try conds.classesMerge(gpa, charge, v, s.own, parts, true);
            return;
        }
        var all: Cond.Table.ClassAggs = .{};
        for (members) |m| {
            const s = w.states.items[m];
            all = try conds.classesMerge(gpa, charge, v, all, s.own, true);
            for (w.parts.items[s.parts.start..][0..s.parts.len]) |p| {
                try charge.reserve(gpa, .memo, 1);
                if (comp[p] != c) all = try conds.classesMerge(gpa, charge, v, all, acc[p], true);
            }
        }
        const repeated = try conds.classesRepeated(gpa, charge, all);
        for (members) |m| acc[m] = repeated;
    }
};

const Grafter = struct {
    env: Env,
    sums: *const Summary.Table,
    args: []const Value,
    label: LabelId,
    s: *Scratch,
    /// `foldedArg` by `(argument, template path)`, however many atoms read
    /// it; the deep read at the prefix by `(argument, prefix)`.
    folded: Ids.FixedDict(2) = .{},
    deeps: Ids.FixedDict(2) = .{},
    /// The environment of the call's view, and at an identity class its
    /// root and the actual it answers (`relabelNode`).
    view_env: u32 = Ids.none_int,
    root: NodeId = .none,
    answer: NodeId = .none,

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

    /// `excl` of argument `i` at a template path `p` that crosses `⟲`, null
    /// for one that does not: the argument at the re-entered place (the
    /// path before its first `⟲`) read deeply there, and the occurrences at
    /// `p` of its full preimage compared as a multiset across depths
    /// (`preimage`). Both are kept per prefix, so many template paths under
    /// one prefix walk the argument once (#1159).
    fn foldedArg(g: *Grafter, i: u32, p: PathId) Error!?CondId {
        const places = g.env.places;
        var lv: PathId = .none;
        var at = p;
        while (places.pathParent(at) != .none) : (at = places.pathParent(at)) {
            if (places.pathStep(at).kind == .level) lv = at;
        }
        if (lv == .none) return null;
        try g.env.charge.reserve(g.gpa(), .memo, 1);
        if (g.folded.get(.{ i, p.int() })) |hit| return CondId.from(hit);
        const k = try g.foldedArgOnce(i, p, places.pathParent(lv));
        (try g.folded.getOrPut(g.gpa(), .{ i, p.int() })).value_ptr.* = k.int();
        return k;
    }

    fn foldedArgOnce(g: *Grafter, i: u32, p: PathId, prefix: PathId) Error!CondId {
        const places = g.env.places;
        const n = try g.argAt(i, prefix, places.pathPlace(prefix));
        try g.env.charge.reserve(g.gpa(), .memo, 1);
        const k: CondId = if (g.deeps.get(.{ i, prefix.int() })) |hit| .from(hit) else blk: {
            const d = try g.env.conds.deep(g.gpa(), g.env.charge, g.env.view(), try g.argKappa(i, prefix), n, true);
            (try g.deeps.getOrPut(g.gpa(), .{ i, prefix.int() })).value_ptr.* = d.int();
            break :blk d;
        };
        if (i >= g.args.len or g.args[i].node == .none) return k;
        const pre = try preimage(g.env, n, prefix);
        return try g.env.conds.@"and"(g.gpa(), g.env.charge, k, try g.env.conds.classesRead(g.gpa(), g.env.charge, g.env.cells, g.env.places, pre, p.int()));
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

    /// A class position's image at this call: the view of it under the
    /// call's environment, the actual itself at an identity root.
    fn relabelNode(ctx: *anyopaque, n: NodeId) Error!?NodeId {
        const g: *Grafter = @ptrCast(@alignCast(ctx));
        if (n == g.root) return g.answer;
        return try g.env.shapes.view(g.gpa(), g.account(), n, g.view_env);
    }

    /// The actual a class whose `res` is one exact parameter cell at its
    /// root answers (`id x = x`, §2.11 *Identity towers*), null otherwise.
    fn identity(g: *Grafter, res: NodeId) Error!?NodeId {
        const shapes = g.env.shapes;
        if (shapes.kind(res) != .leaf) return null;
        var it = g.env.cells.sets.iterate(shapes.cells(res));
        const e = it.next() orelse return null;
        if (it.next() != null or e.value != 0) return null;
        const x = g.env.cells.get(.from(e.key));
        if (x.origin != .param or g.env.places.pathParent(.from(x.b)) != .none) return null;
        return try g.argAt(x.a, .from(x.b), shapes.place(res));
    }

    fn instantiated(ctx: *anyopaque, t: *Cond.Table, gpa_: Allocator, charge: Ids.Charge, k: CondId) Error!CondId {
        return t.instantiate(gpa_, charge, k, .{ .ctx = ctx, .atom = Grafter.atom });
    }

    /// `kappa` with each argument's snapshot merged in at every position of
    /// the class's `res` whose cells name the argument (`π i·q`: the
    /// argument's position at `q`): the paths of `res`'s explicit
    /// structure, each `(node, path)` once. A route that meets a node it
    /// has passed (a widened class's knot) folds there (§2.9).
    /// At a knot's own cursor (§2.11, #1146): each position on the route
    /// has a builder, its snapshot as it stands, rooted there; a merge and
    /// a fold act on the builder at ε, and a finished builder is relinked
    /// into its parent's once, on the way back. No route scan, no path
    /// replayed from the root.
    fn linkArgs(g: *Grafter, kappa: Cond.Kappas, res: NodeId) Error!Cond.Kappas {
        var w: LinkWalk = .{};
        defer w.deinit(g.gpa());
        try w.builders.append(g.gpa(), .{ .at = kappa });
        w.acyclic = try g.knotFree(res);
        try g.linkAt(&w, res, 0);
        return g.finishBuilder(w.builders.items[0]);
    }

    /// Whether `res`'s graph has no cycle (no knot): a coloured depth-first
    /// walk, each node once.
    fn knotFree(g: *Grafter, res: NodeId) Error!bool {
        const shapes = g.env.shapes;
        var colour: stamped.Column(NodeId, bool) = .{};
        defer colour.deinit(g.gpa());
        const Frame = struct { node: NodeId, exit: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(g.gpa());
        try stack.append(g.gpa(), .{ .node = res, .exit = false });
        while (stack.pop()) |f| {
            if (f.exit) {
                try colour.put(g.gpa(), f.node, true);
                continue;
            }
            if (colour.get(f.node)) |done| {
                if (!done) return false;
                continue;
            }
            try g.env.charge.reserve(g.gpa(), .inspection, 1);
            try colour.put(g.gpa(), f.node, false);
            try stack.append(g.gpa(), .{ .node = f.node, .exit = true });
            const d = shapes.get(f.node);
            switch (d.kind) {
                .leaf => {},
                .node, .delta => {
                    if (d.kind == .delta) try stack.append(g.gpa(), .{ .node = .from(d.a), .exit = false });
                    var kt = shapes.overEntries(if (d.kind == .node) d.a else d.b);
                    while (kt.next()) |e| try stack.append(g.gpa(), .{ .node = e.node, .exit = false });
                },
                .recast => try stack.append(g.gpa(), .{ .node = .from(d.a), .exit = false }),
                .@"union", .choice, .positions => try stack.appendSlice(g.gpa(), &.{ .{ .node = .from(d.a), .exit = false }, .{ .node = .from(d.b), .exit = false } }),
                .view => unreachable, // a callee's template: summaries are published forced (§2.11)
            }
        }
        return true;
    }

    const LinkWalk = struct {
        /// One per position of the route, its path length its index.
        builders: std.ArrayList(Builder) = .empty,
        /// The nodes on the route: each its builder's index (a backedge's
        /// fold is there), set on entry, cleared on exit.
        active: stamped.Column(NodeId, u32) = .{},
        /// Paths interned as `(parent, step)`, 0 the root; `(node, path)` visited.
        paths: Ids.FixedDict(2) = .{},
        visited: Ids.FixedDict(2) = .{},
        next_path: u32 = 1,
        /// `argKappa` per `(argument, path)`, from its parent path's.
        arg_at: Ids.FixedDict(2) = .{},
        /// The `(argument, path)`s a level step or a missing position stopped.
        arg_stopped: Ids.FixedDict(2) = .{},
        /// When `res` has no knot: each finished position by `(node, snapshot it
        /// starts from)`, so a node shared by many paths is linked once (#1252).
        acyclic: bool = false,
        shared: Ids.FixedDict(2) = .{},

        fn deinit(w: *LinkWalk, gpa_: Allocator) void {
            w.builders.deinit(gpa_);
            w.active.deinit(gpa_);
            w.paths.deinit(gpa_);
            w.visited.deinit(gpa_);
            w.arg_at.deinit(gpa_);
            w.arg_stopped.deinit(gpa_);
            w.shared.deinit(gpa_);
        }
    };

    /// A position's snapshot being built, and whether a backedge folds it.
    const Builder = struct { at: Cond.Kappas, fold: bool = false, node: NodeId = .none, start: Cond.Kappas = .none };

    fn finishBuilder(g: *Grafter, b: Builder) Error!Cond.Kappas {
        if (!b.fold or g.env.conds.isFold(b.at)) return b.at;
        return g.env.conds.kappaFold(g.gpa(), g.env.charge, b.at);
    }

    /// `argKappa(i, p)` from the parent path's, each `(i, path)` once: the
    /// argument's cursor one step further, or the parent's past a level
    /// step or a missing position (`argKappa` stops there).
    fn argKappaAt(g: *Grafter, w: *LinkWalk, i: u32, p: PathId) Error!Cond.Kappas {
        if (i >= g.args.len) return .none;
        const places = g.env.places;
        // The paths up to one known, then down from it.
        var up: std.ArrayList(PathId) = .empty;
        defer up.deinit(g.gpa());
        var at = p;
        var cur: Cond.Kappas = g.args[i].kappa;
        var stopped = false;
        while (places.pathParent(at) != .none) : (at = places.pathParent(at)) {
            try g.env.charge.reserve(g.gpa(), .memo, 1);
            if (w.arg_at.get(.{ i, at.int() })) |v| {
                cur = .from(v);
                stopped = w.arg_stopped.get(.{ i, at.int() }) != null;
                break;
            }
            try up.append(g.gpa(), at);
        }
        while (up.pop()) |q| {
            const s = places.pathStep(q);
            if (!stopped and (s.kind == .level or cur == .none)) stopped = true;
            if (!stopped) cur = g.env.conds.kappaChild(cur, s);
            try g.env.charge.reserve(g.gpa(), .memo, 1);
            (try w.arg_at.getOrPut(g.gpa(), .{ i, q.int() })).value_ptr.* = cur.int();
            if (stopped) (try w.arg_stopped.getOrPut(g.gpa(), .{ i, q.int() })).value_ptr.* = 0;
        }
        return cur;
    }

    /// A finished child position's snapshot linked into its parent's builder
    /// at `s` (merged when the parent folds).
    fn linkChild(g: *Grafter, w: *LinkWalk, s: Step, child: Cond.Kappas) Error!void {
        const conds = g.env.conds;
        const top = &w.builders.items[w.builders.items.len - 1];
        top.at = if (conds.isFold(top.at)) try conds.kappaMerge(g.gpa(), g.env.charge, top.at, child) else try conds.withLink(g.gpa(), g.env.charge, top.at, s, child);
    }
    fn linkAt(g: *Grafter, w: *LinkWalk, root: NodeId, root_pid: u32) Error!void {
        const shapes = g.env.shapes;
        const conds = g.env.conds;
        // A depth-first walk on an explicit stack (#1130: `res`'s depth is the
        // source's, never native-stack depth). An `enter` frame may carry the
        // step it is reached by, and opens that position's builder; its
        // `exit` frame takes the node off the route and relinks the builder.
        const Frame = struct { node: NodeId, pid: u32, step: ?Step, exit: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(g.gpa());
        var kids: std.ArrayList(Frame) = .empty;
        defer kids.deinit(g.gpa());
        try stack.append(g.gpa(), .{ .node = root, .pid = root_pid, .step = null, .exit = false });
        while (stack.pop()) |f| {
            if (f.exit) {
                w.active.remove(f.node);
                if (f.step) |s| {
                    const b = w.builders.pop().?;
                    const child = try g.finishBuilder(b);
                    if (w.acyclic) {
                        try g.env.charge.reserve(g.gpa(), .memo, 1);
                        (try w.shared.getOrPut(g.gpa(), .{ b.node.int(), b.start.int() })).value_ptr.* = child.int();
                    }
                    try g.linkChild(w, s, child);
                }
                continue;
            }
            const t = f.node;
            // A position whose node and starting snapshot were linked
            // already, on another path: its finished snapshot as it was.
            if (w.acyclic) if (f.step) |s| {
                const start = conds.kappaChild(w.builders.items[w.builders.items.len - 1].at, s);
                try g.env.charge.reserve(g.gpa(), .memo, 1);
                if (w.shared.get(.{ t.int(), start.int() })) |done| {
                    try g.linkChild(w, s, .from(done));
                    continue;
                }
            };
            try g.env.charge.reserve(g.gpa(), .memo, 1);
            const seen = try w.visited.getOrPut(g.gpa(), .{ t.int(), f.pid });
            if (seen.found_existing) continue;
            seen.value_ptr.* = 1;
            try g.env.charge.reserve(g.gpa(), .inspection, 1);
            if (w.active.get(t)) |bi| {
                // A knot: everything below its first entry is that
                // position, folded when its builder is finished.
                w.builders.items[bi].fold = true;
                continue;
            }
            if (f.step) |s| {
                const parent = w.builders.items[w.builders.items.len - 1].at;
                const start = conds.kappaChild(parent, s);
                try w.builders.append(g.gpa(), .{ .at = start, .node = t, .start = start });
            }
            const here: u32 = @intCast(w.builders.items.len - 1);
            try w.active.put(g.gpa(), t, here);
            try stack.append(g.gpa(), .{ .node = t, .pid = f.pid, .step = f.step, .exit = true });
            var it = g.env.cells.sets.iterate((try shapes.cellsOf(g.gpa(), g.account(), &g.env.cells.sets, t)));
            while (it.next()) |e| {
                const cell: CellId = .from(e.key);
                if (g.env.cells.origin(cell) != .param) continue;
                try g.env.charge.reserve(g.gpa(), .inspection, 1);
                const x = g.env.cells.get(cell);
                const b = &w.builders.items[here];
                b.at = try conds.kappaMerge(g.gpa(), g.env.charge, b.at, try g.argKappaAt(w, x.a, .from(x.b)));
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
                .@"union", .choice, .positions => try kids.appendSlice(g.gpa(), &.{ .{ .node = .from(d.a), .pid = f.pid, .step = null, .exit = false }, .{ .node = .from(d.b), .pid = f.pid, .step = null, .exit = false } }),
                .view => unreachable, // a callee's template: summaries are published forced (§2.11)
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
        // A knot is PENDING until it is tied, and a pending knot is never
        // read (#1143): `join`, `put` and `collect` read their members'
        // records as deep as they go, so a part on a cycle of `res` (its
        // strongly connected component, Tarjan's lowlinks on the same walk)
        // is built as `map` builds a cyclic image: a record that names its
        // parts' images and reads only those already built (`graftRaw`).
        // Off a cycle nothing pending is reachable, and the image is built
        // as before.
        const shapes = g.env.shapes;
        const Frame = struct { node: NodeId, parent: NodeId, expanded: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(g.gpa());
        var open: stamped.Column(NodeId, void) = .{};
        defer open.deinit(g.gpa());
        var knots: stamped.Column(NodeId, NodeId) = .{};
        defer knots.deinit(g.gpa());
        var pending: stamped.Column(NodeId, void) = .{};
        defer pending.deinit(g.gpa());
        // Tarjan: each part's visit number and lowlink, and the parts of
        // components not yet closed.
        var index: stamped.Column(NodeId, [2]u32) = .{};
        defer index.deinit(g.gpa());
        var component: std.ArrayList(NodeId) = .empty;
        defer component.deinit(g.gpa());
        var visits: u32 = 0;
        try stack.append(g.gpa(), .{ .node = root, .parent = .none, .expanded = false });
        while (stack.pop()) |f| {
            if (f.expanded) {
                open.remove(f.node);
                const il = index.get(f.node).?;
                if (g.s.memo.get(f.node) == null or knots.get(f.node) != null) {
                    if (il[1] < il[0] or knots.get(f.node) != null)
                        try g.graftRaw(f.node, &knots, &pending)
                    else
                        try g.graftTied(f.node, &knots, &pending);
                }
                if (f.parent != .none) lower(&index, f.parent, il[1]);
                if (il[1] == il[0]) while (component.pop()) |x| {
                    index.getPtr(x).?[0] = closed;
                    if (x == f.node) break;
                };
                continue;
            }
            if (open.contains(f.node)) {
                // A back edge: the part's knot, once.
                if (knots.get(f.node) == null) {
                    const k = try shapes.knot(g.gpa(), g.account());
                    try knots.put(g.gpa(), f.node, k);
                    try pending.put(g.gpa(), k, {});
                    try g.s.memo.put(g.gpa(), f.node, k);
                }
                lower(&index, f.parent, index.get(f.node).?[0]);
                continue;
            }
            if (g.s.memo.get(f.node) != null) {
                // Built: in a component not yet closed, the same cycle.
                if (index.get(f.node)) |il| if (il[0] != closed) lower(&index, f.parent, il[0]);
                continue;
            }
            try index.put(g.gpa(), f.node, .{ visits, visits });
            visits += 1;
            try component.append(g.gpa(), f.node);
            try open.put(g.gpa(), f.node, {});
            try stack.append(g.gpa(), .{ .node = f.node, .parent = f.parent, .expanded = true });
            const d = shapes.get(f.node);
            const me = f.node;
            switch (d.kind) {
                .leaf => {},
                .node, .delta => {
                    if (d.kind == .delta) try stack.append(g.gpa(), .{ .node = .from(d.a), .parent = me, .expanded = false });
                    var kt = shapes.overEntries(if (d.kind == .node) d.a else d.b);
                    while (kt.next()) |e| try stack.append(g.gpa(), .{ .node = e.node, .parent = me, .expanded = false });
                },
                .recast => try stack.append(g.gpa(), .{ .node = .from(d.a), .parent = me, .expanded = false }),
                .@"union", .choice, .positions => try stack.appendSlice(g.gpa(), &.{ .{ .node = .from(d.a), .parent = me, .expanded = false }, .{ .node = .from(d.b), .parent = me, .expanded = false } }),
                .view => unreachable, // a callee's template: summaries are published forced (§2.11)
            }
        }
        return g.s.memo.get(root).?;
    }

    /// A closed component's visit number: no lowlink reads it.
    const closed = std.math.maxInt(u32);

    fn lower(index: *stamped.Column(NodeId, [2]u32), n: NodeId, to: u32) void {
        const il = index.getPtr(n).?;
        il[1] = @min(il[1], to);
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

    /// `t`, a part on a cycle of `res`, grafted as a record over its parts'
    /// images, read only where none is pending: a node as any (it names its
    /// parts), a delta over its base's image with the overrides' images (a
    /// built delta base's map composed, so no delta is over a delta), a
    /// recast of its inner's image (composed likewise), a union or a
    /// positions node over its sides' images. A pending image's kind is
    /// its part's (it is a record of this kind or a node), so the
    /// composition never needs one. Its `ε` cells are the image of `t`'s
    /// (`imageCells`), what the constructors would compute from the parts.
    /// No join, `put` or `collect`: they would read a pending knot below.
    fn graftRaw(g: *Grafter, t: NodeId, knots: *stamped.Column(NodeId, NodeId), pending: *stamped.Column(NodeId, void)) Error!void {
        const shapes = g.env.shapes;
        const d = shapes.get(t);
        if (d.kind == .node or d.kind == .leaf) return g.graftTied(t, knots, pending);
        const built = struct {
            fn of(p: *const stamped.Column(NodeId, void), n: NodeId) bool {
                return !p.contains(n);
            }
        }.of;
        var rec: Shape.Node = .{ .kind = d.kind, .place = d.place, .cells = .none, .a = 0, .b = 0, .reach = .none };
        switch (d.kind) {
            .delta => {
                var base = g.s.memo.get(.from(d.a)).?;
                var over: u32 = Ids.none_int;
                if (built(pending, base) and shapes.kind(base) == .delta) {
                    over = shapes.get(base).b;
                    base = .from(shapes.get(base).a);
                }
                var kt = shapes.overEntries(d.b);
                while (kt.next()) |e| over = try shapes.overPut(g.gpa(), g.account(), over, e.step, g.s.memo.get(e.node).?);
                rec.a = base.int();
                rec.b = over;
                rec.cells = if (d.cells == Shape.Table.lazy_cells) d.cells else try g.imageCells(d.cells, d.place);
            },
            .recast => {
                const image = g.s.memo.get(.from(d.a)).?;
                // A cast of an image that is a whole recast stays whole,
                // its cells that image's, as `Shape.recast` makes it (#1311).
                const whole_image = built(pending, image) and shapes.isWhole(image);
                var in = image;
                if (built(pending, in) and shapes.kind(in) == .recast) in = .from(shapes.get(in).a);
                rec.a = in.int();
                rec.b = if (whole_image) 1 else d.b;
                // A whole recast's cells are a reach: a parameter cell there
                // stands for what the argument reaches (#1311).
                rec.cells = if (d.cells == Shape.Table.lazy_cells) d.cells else if (whole_image and d.b == 0) shapes.cells(image) else if (d.b == 1) try g.imageReach(d.cells, shapes.place(.from(d.a))) else try g.imageCells(d.cells, shapes.place(.from(d.a)));
            },
            .@"union", .choice, .positions => {
                rec.a = g.s.memo.get(.from(d.a)).?.int();
                rec.b = g.s.memo.get(.from(d.b)).?.int();
                rec.cells = if (d.cells == Shape.Table.lazy_cells) d.cells else try g.imageCells(d.cells, d.place);
            },
            .leaf, .node, .view => unreachable,
        }
        const k = knots.get(t) orelse try shapes.knot(g.gpa(), g.account());
        shapes.tie(k, rec);
        try g.s.memo.put(g.gpa(), t, k);
        pending.remove(k);
    }

    /// The image of `res` cells at `at`: a parameter cell the argument's
    /// cells there, any other its mapped self (`graftOne`'s node arm, with
    /// no escape recorded: the parts that hold the cells record theirs).
    fn imageCells(g: *Grafter, cells: SetId, at: PlaceId) Error!SetId {
        var c: SetId = .none;
        var it = g.env.cells.sets.iterate(cells);
        while (it.next()) |e| {
            const cell: CellId = .from(e.key);
            if (g.env.cells.origin(cell) == .param) {
                const x = g.env.cells.get(cell);
                c = try g.env.cells.sets.unionWith(g.gpa(), g.env.charge, c, try g.env.shapes.cellsOf(g.gpa(), g.account(), &g.env.cells.sets, try g.argAt(x.a, .from(x.b), at)));
                continue;
            }
            c = try g.env.cells.sets.insert(g.gpa(), g.env.charge, c, (try g.mapCell(cell, at)).int(), e.value);
        }
        return c;
    }

    /// The image of a whole recast's cells, a reach (`Shape.recastWhole`):
    /// a parameter cell the argument's reach there, any other its mapped
    /// self, every one approximate.
    fn imageReach(g: *Grafter, cells: SetId, at: PlaceId) Error!SetId {
        var c: SetId = .none;
        var it = g.env.cells.sets.iterate(cells);
        while (it.next()) |e| {
            const cell: CellId = .from(e.key);
            const one: SetId = if (g.env.cells.origin(cell) == .param) blk: {
                const x = g.env.cells.get(cell);
                break :blk try g.env.shapes.reach(g.gpa(), g.account(), &g.env.cells.sets, try g.argAt(x.a, .from(x.b), at));
            } else try g.env.cells.sets.insert(g.gpa(), g.env.charge, .none, (try g.mapCell(cell, at)).int(), 1);
            var ot = g.env.cells.sets.iterate(one);
            while (ot.next()) |o| {
                try g.env.charge.reserve(g.gpa(), .inspection, 1);
                c = try g.env.cells.sets.insert(g.gpa(), g.env.charge, c, o.key, 1);
            }
        }
        return c;
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
                        c = try g.env.cells.sets.unionWith(g.gpa(), g.env.charge, c, (try shapes.cellsOf(g.gpa(), g.account(), &g.env.cells.sets, arg)));
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
            // A whole recast is some value inside its inner: the image's
            // reach, never its root's cells (#1311).
            .recast => try shapes.recastAs(g.gpa(), g.account(), &g.env.cells.sets, t, g.s.memo.get(.from(d.a)).?),
            .@"union" => blk: {
                var two = [_]NodeId{ g.s.memo.get(.from(d.a)).?, g.s.memo.get(.from(d.b)).? };
                break :blk try shapes.join(g.gpa(), g.account(), g.env.places, g.env.cells, &two);
            },
            .positions => try shapes.collect(g.gpa(), g.account(), &g.env.cells.sets, &.{ g.s.memo.get(.from(d.a)).?, g.s.memo.get(.from(d.b)).? }),
            // A choice's arms stay exclusive at the call (§2.3).
            .choice => blk: {
                var two = [_]NodeId{ g.s.memo.get(.from(d.a)).?, g.s.memo.get(.from(d.b)).? };
                break :blk try shapes.joinChoice(g.gpa(), g.account(), g.env.places, g.env.cells, &two);
            },
            .view => unreachable, // a callee's template: summaries are published forced (§2.11)
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

    /// A view's leaf image (§2.11): a re-root template (one exact parameter
    /// cell) answers the actual there (`argAt`); otherwise each parameter
    /// part is a re-root view over an interned one-cell leaf (a recast when
    /// approximate), so that every re-rooted actual is reached through one
    /// (*κ across a call*), the other cells mapped into one leaf, the parts
    /// joined raw. Escapes are `apply`'s, made once per call from the class.
    fn viewLeaf(g: *Grafter, members: *std.ArrayList(NodeId), at: PlaceId, cells: SetId) Error!NodeId {
        if (rerootCell(g.env.cells, cells)) |cell| {
            const x = g.env.cells.get(cell);
            return g.argAt(x.a, .from(x.b), at);
        }
        const first = members.items.len;
        defer members.shrinkRetainingCapacity(first);
        var rest: SetId = .none;
        var it = g.env.cells.sets.iterate(cells);
        while (it.next()) |e| {
            try g.env.charge.reserve(g.gpa(), .inspection, 1);
            const cell: CellId = .from(e.key);
            if (g.env.cells.origin(cell) == .param) {
                const one = try g.env.shapes.leaf(g.gpa(), g.account(), at, try g.env.cells.sets.insert(g.gpa(), g.env.charge, .none, cell.int(), 0));
                var n = try g.env.shapes.view(g.gpa(), g.account(), one, g.view_env);
                if (e.value == 1) n = try g.env.shapes.recast(g.gpa(), g.account(), at, n);
                try members.append(g.gpa(), n);
                continue;
            }
            rest = try g.env.cells.sets.insert(g.gpa(), g.env.charge, rest, (try g.mapCell(cell, at)).int(), e.value);
        }
        if (rest != .none or members.items.len == first) try members.append(g.gpa(), try g.env.shapes.leaf(g.gpa(), g.account(), at, rest));
        return g.env.shapes.joinRaw(g.gpa(), g.account(), at, members.items[first..]);
    }

    /// The cells a class cell stands for at this call: a parameter's, the
    /// argument's at that path; anything else its mapped self.
    fn cellsOf(g: *Grafter, c: CellId, at: PlaceId) Error!SetId {
        const x = g.env.cells.get(c);
        if (x.origin == .param) {
            // Through `⟲` the path stands for every position of the argument
            // the fold maps to it: their cells, from the full preimage, never
            // a recast's own shallow cells (#1199).
            if (try g.foldedCells(x.a, .from(x.b))) |s| return s;
            return g.env.shapes.cellsOf(g.gpa(), g.account(), &g.env.cells.sets, try g.argAt(x.a, .from(x.b), at));
        }
        if (x.origin.isSymbolic() and x.origin != .top) return g.env.cells.sets.insert(g.gpa(), g.env.charge, .none, (try g.env.cells.top(g.gpa(), g.account())).int(), 1);
        return g.env.cells.sets.insert(g.gpa(), g.env.charge, .none, (try g.mapCell(c, at)).int(), 0);
    }

    /// The cells at every position of argument `i` that a template path `p`
    /// through `⟲` stands for (the preimage's occurrences at `p`), null for a
    /// path that does not cross `⟲`.
    fn foldedCells(g: *Grafter, i: u32, p: PathId) Error!?SetId {
        const places = g.env.places;
        var lv: PathId = .none;
        var at = p;
        while (places.pathParent(at) != .none) : (at = places.pathParent(at)) {
            if (places.pathStep(at).kind == .level) lv = at;
        }
        if (lv == .none) return null;
        const prefix = places.pathParent(lv);
        if (i >= g.args.len or g.args[i].node == .none) return try g.env.cells.sets.insert(g.gpa(), g.env.charge, .none, (try g.env.cells.top(g.gpa(), g.account())).int(), 1);
        const n = try g.argAt(i, prefix, places.pathPlace(prefix));
        return g.env.conds.classesCells(try preimage(g.env, n, prefix), p.int());
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
                // Through `⟲`, the template path stands for every position of the
                // argument the fold maps to it (§2.9, #1128): each read where it
                // stands (`deep` over the argument below the re-entered place, a
                // superset of those positions), and their arrivals as a multiset
                // across depths, never each path's read alone.
                if (try g.foldedArg(x.a, .from(x.b))) |k| return k;
                const at = g.placeOfCell(c);
                const n = try g.argAt(x.a, .from(x.b), at);
                const kappa = try g.argKappa(x.a, .from(x.b));
                return t.deep(gpa_, g.env.charge, g.env.view(), kappa, n, g.env.places.isSummary(.from(x.b)));
            },
            .sep, .apart => {
                // `apart [A] [B]` over the sides' cells as a multiset: each side's
                // set aggregate, memoised per radix node, merged into the larger
                // (*The derivation*), never a sorted list of them all.
                var sides: std.ArrayList(SetId) = .empty;
                defer sides.deinit(gpa_);
                if (a.atom == .sep) {
                    for ([_]u32{ a.a, a.b }) |side| {
                        const c: CellId = .from(side);
                        try sides.append(gpa_, try g.cellsOf(c, g.placeOfCell(c)));
                    }
                } else {
                    var it = g.env.cells.sets.iterate(.from(a.a));
                    while (it.next()) |e| {
                        const c: CellId = .from(e.key);
                        try sides.append(gpa_, try g.cellsOf(c, g.placeOfCell(c)));
                    }
                }
                var acc: Cond.Table.Agg = .{};
                for (sides.items) |s| acc = try t.aggMergeMulti(gpa_, g.env.charge, g.env.cells, g.env.places, acc, try t.setAgg(gpa_, g.env.charge, g.env.cells, g.env.places, s));
                const k = try t.aggCond(gpa_, g.env.charge, g.env.cells, g.env.places, acc);
                if (std.debug.runtime_safety and Cond.full_cross_check) {
                    var items: std.ArrayList(Cond.Item) = .empty;
                    defer items.deinit(gpa_);
                    for (sides.items) |s| try g.addItems(s, &items);
                    try t.expectSame(gpa_, g.env.charge, k, try t.apart(gpa_, g.env.charge, g.env.cells, g.env.places, items.items, null));
                }
                return k;
            },
            .within, .keep, .writes => return Cond.lost,
        }
    }
};

/// A cell set's one exact parameter cell, null when it is anything else:
/// the template of a re-root view (§2.11 *κ across a call*).
fn rerootCell(cellt: *const Cell.Table, cells: SetId) ?CellId {
    if (cells == .none or cells == Shape.Table.lazy_cells) return null;
    var it = cellt.sets.iterate(cells);
    const e = it.next() orelse return null;
    if (it.next() != null or e.value != 0) return null;
    const c: CellId = .from(e.key);
    return if (cellt.origin(c) == .param) c else null;
}

/// The environments of the views calls answer (§2.11 *Representation of a
/// view*): per call its class, its actuals and its invocation label, kept
/// as long as the module's tables, which hold the views. The table's
/// `Shape.Table.Instantiation` reads them.
pub const Views = struct {
    envs: std.ArrayList(ViewEnv) = .empty,
    args: std.ArrayList(Value) = .empty,
    /// A leaf image's parts, a stack: a nested force appends above.
    members: std.ArrayList(NodeId) = .empty,
    places: *Place.Table,
    cells: *Cell.Table,
    shapes: *Shape.Table,
    conds: *Cond.Table,
    sums: *const Summary.Table,

    const ViewEnv = struct { class: ClassId, args: Ids.Range, label: LabelId };

    pub fn deinit(v: *Views, gpa: Allocator) void {
        v.envs.deinit(gpa);
        v.args.deinit(gpa);
        v.members.deinit(gpa);
    }

    /// Set on `v.shapes` once, before the first call.
    pub fn instantiation(v: *Views) Shape.Table.Instantiation {
        return .{ .ctx = v, .sets = &v.cells.sets, .leaf = leafImage, .cells = cellsImage, .reach = reachImage, .reroot = rerootImage };
    }

    /// One call's environment.
    fn add(v: *Views, env: Env, class: ClassId, args: []const Value, label: LabelId) Error!u32 {
        try env.charge.reserve(env.gpa, .memo, @intCast(1 + args.len));
        const r: Ids.Range = .{ .start = @intCast(v.args.items.len), .len = @intCast(args.len) };
        try v.args.appendSlice(env.gpa, args);
        try v.envs.append(env.gpa, .{ .class = class, .args = r, .label = label });
        return @intCast(v.envs.items.len - 1);
    }

    fn of(ctx: *anyopaque) *Views {
        return @ptrCast(@alignCast(ctx));
    }

    /// A grafter over environment `e`, charging the reader's kernel.
    fn grafter(v: *Views, gpa_: Allocator, account_: *Ids.Account, e: u32, s: *Scratch) Grafter {
        const x = v.envs.items[e];
        const env: Env = .{ .gpa = gpa_, .charge = .growth(account_), .places = v.places, .cells = v.cells, .shapes = v.shapes, .conds = v.conds };
        return .{ .env = env, .sums = v.sums, .args = v.args.items[x.args.start..][0..x.args.len], .label = x.label, .s = s, .view_env = e };
    }

    fn leafImage(ctx: *anyopaque, t: *Shape.Table, gpa_: Allocator, account_: *Ids.Account, e: u32, template: NodeId) Error!NodeId {
        const v = of(ctx);
        var none: Scratch = .{};
        var g = v.grafter(gpa_, account_, e, &none);
        return g.viewLeaf(&v.members, t.place(template), t.cells(template));
    }

    fn cellsImage(ctx: *anyopaque, _: *Shape.Table, gpa_: Allocator, account_: *Ids.Account, e: u32, s: SetId, at: PlaceId) Error!SetId {
        const v = of(ctx);
        var none: Scratch = .{};
        var g = v.grafter(gpa_, account_, e, &none);
        return g.imageCells(s, at);
    }

    /// The snapshot position a re-root view reads its actual at (§2.11 *κ
    /// across a call*, `R = argKappa(E, i, q)`), null for a view that is no
    /// re-root view: its template a leaf of one exact parameter cell.
    fn rerootImage(ctx: *anyopaque, t: *Shape.Table, gpa_: Allocator, account_: *Ids.Account, e: u32, template: NodeId) Error!?Ids.KappaId {
        const v = of(ctx);
        if (t.kind(template) != .leaf) return null;
        const cell = rerootCell(v.cells, t.cells(template)) orelse return null;
        var none: Scratch = .{};
        var g = v.grafter(gpa_, account_, e, &none);
        const x = v.cells.get(cell);
        return try g.argKappa(x.a, .from(x.b));
    }

    fn reachImage(ctx: *anyopaque, t: *Shape.Table, gpa_: Allocator, account_: *Ids.Account, e: u32, c: CellId, approx: u1) Error!SetId {
        const v = of(ctx);
        var none: Scratch = .{};
        var g = v.grafter(gpa_, account_, e, &none);
        const x = v.cells.get(c);
        if (x.origin == .param) return t.reach(gpa_, account_, &v.cells.sets, try g.argAt(x.a, .from(x.b), g.placeOfCell(c)));
        // What the call does not interpret is `⊤`, approximately, as a
        // grafted atom reads it (`Grafter.cellsOf`).
        if (x.origin.isSymbolic() and x.origin != .top) return v.cells.sets.insert(gpa_, .growth(account_), .none, (try v.cells.top(gpa_, account_)).int(), 1);
        return v.cells.sets.insert(gpa_, .growth(account_), .none, (try g.mapCell(c, g.placeOfCell(c))).int(), approx);
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
        var any = false;
        var held = false;
        var answered = false;
        var w = false;
        var e = false;
        var deep = false;
        var it = env.cells.sets.iterate((try env.shapes.cellsOf(env.gpa, env.account(), &env.cells.sets, f.node)));
        while (it.next()) |x| {
            const c: CellId = .from(x.key);
            if (env.cells.origin(c) != .mark) continue;
            any = true;
            switch (env.cells.markOf(c)) {
                .w => w = true,
                .e => {
                    e = true;
                    held = true;
                },
                .a => answered = true,
                .deep => deep = true,
                else => {},
            }
        }
        if (any) {
            const start: u32 = @intCast(s.steps.items.len);
            var at = f.entry;
            while (at != Ids.none_int) : (at = entries.items[at].parent) try s.steps.append(env.gpa, entries.items[at].step);
            std.mem.reverse(Step, s.steps.items[start..]);
            const r: Ids.Range = .{ .start = start, .len = @intCast(s.steps.items.len - start) };
            if (w) try s.writes.append(env.gpa, .{ .param = param, .steps = r, .deep = deep });
            if (e) try s.escapes.append(env.gpa, .{ .param = param, .steps = r });
            // Answered or escaped, exactly or not: the result, or whoever it
            // escaped to, may hold this very object.
            if (answered) held = true;
            try s.touched.append(env.gpa, .{ .param = param, .steps = r, .held = held });
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
    s.touched.clearRetainingCapacity();
    s.steps.clearRetainingCapacity();
    const cls = sums.get(class);
    const label = try env.cells.label(gpa, env.account(), inst, .none, false);
    var g: Grafter = .{ .env = env, .sums = sums, .args = args, .label = label, .s = s };
    defer g.folded.deinit(gpa);
    defer g.deeps.deinit(gpa);
    // 2, 3: the writes and escapes the use shapes mark.
    for (sums.paramUses(class), 0..) |u, i| try marked(env, u, @intCast(i), s);
    // 4: the result, by reference (§2.11 *Representation of a view*): the
    // view of `res` under this call's environment, or at an identity class
    // the actual itself. Nothing of the arguments is read or copied.
    const views = Views.of((env.shapes.instantiation orelse unreachable).ctx); // every table that applies a class has one
    g.view_env = try views.add(env, class, args, label);
    const res = if (try g.identity(cls.res)) |actual| blk: {
        g.root = cls.res;
        g.answer = actual;
        break :blk actual;
    } else try env.shapes.view(gpa, env.account(), cls.res, g.view_env);
    // The values the result lets escape: its `esc k`, each an `esc ι·k`.
    var rt = env.cells.sets.iterate(try env.shapes.reach(gpa, env.account(), &env.cells.sets, cls.res));
    while (rt.next()) |e| {
        try env.charge.reserve(gpa, .inspection, 1);
        const c: CellId = .from(e.key);
        if (env.cells.origin(c) != .esc) continue;
        const at = g.placeOfCell(c);
        try s.escaped.append(gpa, try env.shapes.leaf(gpa, env.account(), at, try env.cells.sets.insert(gpa, env.charge, .none, (try g.mapCell(c, at)).int(), 0)));
    }
    // 5: the class's κ relabelled onto the result's views, each entry's
    // path unchanged and its condition instantiated, then each argument's
    // snapshot linked where the argument stands in the result (§2.9). Eager,
    // the callee's κ size per call (#1265).
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
        .touched = s.touched.items,
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
            // #1159's probes: `B = B (List B) (List B)` (8, 9); a wide `W = W
            // (List W) f₁ … f₆₄` with `fₖ : List Int` (10–13).
            8 => {
                for (0..2) |i| try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 4, @intCast(i)) catch unreachable), .@"var" = 9 });
                return .{ .kind = .ctor, .head = 308 };
            },
            9 => {
                try out.append(g.gpa, .{ .step = Place.Step.elem, .@"var" = 8 });
                return .{ .kind = .list, .head = 200 };
            },
            10 => {
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 5, 0) catch unreachable), .@"var" = 11 });
                for (1..65) |i| try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 5, @intCast(i)) catch unreachable), .@"var" = 12 });
                return .{ .kind = .ctor, .head = 310 };
            },
            11 => {
                try out.append(g.gpa, .{ .step = Place.Step.elem, .@"var" = 10 });
                return .{ .kind = .list, .head = 200 };
            },
            12 => {
                try out.append(g.gpa, .{ .step = Place.Step.elem, .@"var" = 13 });
                return .{ .kind = .list, .head = 200 };
            },
            13 => return .{ .kind = .cross },
            // #1157's probes: `A = A (List C)`, `C = C (List A)` (2–5), and
            // `R2 = R2 (List T)` (6–7).
            2, 4, 6 => {
                const ctor: u32 = switch (v) {
                    2 => 1,
                    4 => 2,
                    else => 3,
                };
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, ctor, 0) catch unreachable), .@"var" = v + 1 });
                return .{ .kind = .ctor, .head = 300 + v };
            },
            3, 5, 7 => {
                try out.append(g.gpa, .{ .step = Place.Step.elem, .@"var" = switch (v) {
                    3 => 4,
                    5 => 2,
                    else => 0,
                } });
                return .{ .kind = .list, .head = 200 };
            },
            else => unreachable,
        }
    }
};

test "#1130: a call grafts and links a result as deep as the source, on explicit stacks" {
    // On a thread with a small stack, 128 KiB for 3 000 levels: about 43
    // bytes a level, far below a native frame per level in any build, so a
    // recursive walk would overflow it. (It was 30 000 levels on 1 MiB, about
    // the same ratio, over the 1 s budget, #1197; 6 000 on 256 KiB, CI's, #1209.)
    var result: anyerror!void = {};
    const th = try std.Thread.spawn(.{ .stack_size = 128 << 10 }, struct {
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
    var views: Views = .{ .places = &places, .cells = &cells, .shapes = &shapes, .conds = &conds, .sums = &sums };
    defer views.deinit(gpa);
    shapes.instantiation = views.instantiation();
    var graph: TestGraph = .{ .table = &places, .account = &account, .gpa = gpa };
    const src: Place.Source = .{ .ctx = &graph, .describe = TestGraph.describe };
    const t_place = try places.of(gpa, &account, src, 0);
    const list = try places.of(gpa, &account, src, 1);
    const arg = try places.ctorStep(gpa, &account, 0, 0);
    const env: Env = .{ .gpa = gpa, .charge = .growth(&account), .places = &places, .cells = &cells, .shapes = &shapes, .conds = &conds };
    // `res`: 6 000 levels of `T [ … ]` over the parameter at the bottom (12 000
    // path steps, inside `path_steps`), deeper than a native frame per level allows.
    const p = try cells.symbolic(gpa, &account, &places, .param, 0, try places.rootPath(gpa, t_place), 0);
    var n = try shapes.leaf(gpa, &account, t_place, try cells.sets.insert(gpa, env.charge, .none, p.int(), 0));
    const depth = 3_000;
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
    var views: Views = .{ .places = &places, .cells = &cells, .shapes = &shapes, .conds = &conds, .sums = &sums };
    defer views.deinit(gpa);
    shapes.instantiation = views.instantiation();
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
    var views: Views = .{ .places = &places, .cells = &cells, .shapes = &shapes, .conds = &conds, .sums = &sums };
    defer views.deinit(gpa);
    shapes.instantiation = views.instantiation();
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

/// Tables for a hand-built cyclic `res` over `TestGraph`'s `T`/list.
const KnotFixture = struct {
    places: Place.Table = .{},
    cells: Cell.Table = .{},
    shapes: Shape.Table = .{},
    account: Ids.Account = .{},
    conds: Cond.Table = undefined,
    sums: Summary.Table = .{},
    graph: TestGraph = undefined,
    views: Views = undefined,
    t_place: PlaceId = .none,
    list: PlaceId = .none,
    arg: Step = undefined,

    fn init(x: *KnotFixture) !void {
        const gpa = testing.allocator;
        x.conds = try Cond.Table.init(gpa, .growth(&x.account));
        x.graph = .{ .table = &x.places, .account = &x.account, .gpa = gpa };
        x.views = .{ .places = &x.places, .cells = &x.cells, .shapes = &x.shapes, .conds = &x.conds, .sums = &x.sums };
        x.shapes.instantiation = x.views.instantiation();
        const src: Place.Source = .{ .ctx = &x.graph, .describe = TestGraph.describe };
        x.t_place = try x.places.of(gpa, &x.account, src, 0);
        x.list = try x.places.of(gpa, &x.account, src, 1);
        x.arg = try x.places.ctorStep(gpa, &x.account, 0, 0);
    }

    fn deinit(x: *KnotFixture) void {
        const gpa = testing.allocator;
        x.sums.deinit(gpa);
        x.views.deinit(gpa);
        x.conds.deinit(gpa);
        x.account.deinit(gpa);
        x.shapes.deinit(gpa);
        x.cells.deinit(gpa);
        x.places.deinit(gpa);
    }

    fn env(x: *KnotFixture) Env {
        return .{ .gpa = testing.allocator, .charge = .growth(&x.account), .places = &x.places, .cells = &x.cells, .shapes = &x.shapes, .conds = &x.conds };
    }

    fn site(x: *KnotFixture, i: u32, at: PlaceId) !NodeId {
        const gpa = testing.allocator;
        const c = try x.cells.site(gpa, &x.account, i, at, if (at == x.list) .list else .record);
        return x.shapes.leaf(gpa, &x.account, at, try x.cells.sets.insert(gpa, x.env().charge, .none, c.int(), 0));
    }

    fn param(x: *KnotFixture, i: u32) !NodeId {
        const gpa = testing.allocator;
        const p = try x.cells.symbolic(gpa, &x.account, &x.places, .param, i, try x.places.rootPath(gpa, x.t_place), 0);
        return x.shapes.leaf(gpa, &x.account, x.t_place, try x.cells.sets.insert(gpa, x.env().charge, .none, p.int(), 0));
    }

    fn one(x: *KnotFixture, s: Step, n: NodeId) !u32 {
        return x.shapes.overPut(testing.allocator, &x.account, Ids.none_int, s, n);
    }

    fn tieUnion(x: *KnotFixture, k: NodeId, l: NodeId, r: NodeId) !void {
        x.shapes.tie(k, .{ .kind = .@"union", .place = x.shapes.place(l), .cells = try x.cells.sets.unionWith(testing.allocator, x.env().charge, x.shapes.cells(l), x.shapes.cells(r)), .a = l.int(), .b = r.int(), .reach = .none });
    }
};

test "#1143: a back edge under a delta's override inside a union's side is never read pending" {
    const gpa = testing.allocator;
    var x: KnotFixture = .{};
    try x.init();
    defer x.deinit();
    // T{arg: L}, L{[*]: U}, U = union(D1, D2), D1 = delta(param 0, {arg: L})
    // (the back edge is an override), D2 = delta(param 1, {arg: M}). One
    // argument for both parameters: D1's and D2's images share a base, so
    // a join of them would read L's knot while it is pending.
    const b1 = try x.param(0);
    const b2 = try x.param(1);
    const m = try x.site(5, x.list);
    const t = try x.shapes.knot(gpa, &x.account);
    const l = try x.shapes.knot(gpa, &x.account);
    const u = try x.shapes.knot(gpa, &x.account);
    const d1 = try x.shapes.knot(gpa, &x.account);
    const d2 = try x.shapes.knot(gpa, &x.account);
    x.shapes.tie(d1, .{ .kind = .delta, .place = x.t_place, .cells = x.shapes.cells(b1), .a = b1.int(), .b = try x.one(x.arg, l), .reach = .none });
    x.shapes.tie(d2, .{ .kind = .delta, .place = x.t_place, .cells = x.shapes.cells(b2), .a = b2.int(), .b = try x.one(x.arg, m), .reach = .none });
    try x.tieUnion(u, d2, d1);
    const lsite = try x.site(1, x.list);
    x.shapes.tie(l, .{ .kind = .node, .place = x.list, .cells = x.shapes.cells(lsite), .a = try x.one(Place.Step.elem, u), .b = 0, .reach = .none });
    x.shapes.tie(t, .{ .kind = .node, .place = x.t_place, .cells = .none, .a = try x.one(x.arg, l), .b = 0, .reach = .none });
    const c = try x.sums.add(x.env(), .{ .params = &.{ .none, .none }, .res = t, .kappas = .none });
    const a = try x.site(2, x.t_place);
    var s: Scratch = .{};
    defer s.deinit(gpa);
    const applied = try apply(x.env(), &x.sums, c, &.{ .{ .node = a, .kappa = .none }, .{ .node = a, .kappa = .none } }, 0, &s);
    // The image's `arg.[*].arg` holds both alternatives: the list again
    // (the cycle) and M.
    const r = applied.result.node;
    const lr = (try x.shapes.proj(gpa, &x.account, &x.places, &x.cells, r, x.arg)).?;
    const ur = (try x.shapes.proj(gpa, &x.account, &x.places, &x.cells, lr, Place.Step.elem)).?;
    const at = (try x.shapes.proj(gpa, &x.account, &x.places, &x.cells, ur, x.arg)).?;
    try testing.expectEqual(Shape.Kind.@"union", x.shapes.kind(at));
    const sides = x.shapes.get(at);
    try testing.expect(sides.a == lr.int() or sides.b == lr.int());
    try testing.expect(x.cells.sets.member(x.shapes.cells(at), (try x.cells.site(gpa, &x.account, 5, x.list, .list)).int()));
}

/// `X_k = union(N_k, X_{k+1})`, `X_n = union(N_n, leaf)`, `N_k{arg: L_k}`,
/// `L_k{[*]: X_{k-1}}`: each union's side a back edge to the one around
/// it. What grafting `X_n` costs, in records (the graft alone: linking
/// the arguments' snapshots is #1146's).
fn unionChainCost(n: usize) !u64 {
    const gpa = testing.allocator;
    var x: KnotFixture = .{};
    try x.init();
    defer x.deinit();
    const xs = try gpa.alloc(NodeId, n + 1);
    defer gpa.free(xs);
    for (xs) |*k| k.* = try x.shapes.knot(gpa, &x.account);
    const lf = try x.site(7, x.t_place);
    for (1..n + 1) |k| {
        const lsite = try x.site(@intCast(100_000 + k), x.list);
        const lk = if (k == 1) lsite else try x.shapes.node(gpa, &x.account, x.list, x.shapes.cells(lsite), try x.one(Place.Step.elem, xs[k - 1]));
        const nk = try x.shapes.node(gpa, &x.account, x.t_place, x.shapes.cells(try x.site(@intCast(10 + k), x.t_place)), try x.one(x.arg, lk));
        try x.tieUnion(xs[k], nk, if (k == n) lf else xs[k + 1]);
    }
    var s: Scratch = .{};
    defer s.deinit(gpa);
    x.account.allowance = std.math.maxInt(u32) - 1;
    const label = try x.cells.label(gpa, &x.account, 0, .none, false);
    var g: Grafter = .{ .env = x.env(), .sums = &x.sums, .args = &.{.{ .node = lf, .kappa = .none }}, .label = label, .s = &s };
    const before = x.account.total();
    const img = try g.graft(xs[n]);
    try testing.expectEqual(Shape.Kind.@"union", x.shapes.kind(img));
    return x.account.total() - before;
}

test "#1143: grafting a chain of unions on a cycle costs each union its own records" {
    var cost: [5]u64 = undefined;
    for ([_]usize{ 4, 16, 64, 256, 1_024 }, 0..) |n, i| cost[i] = try unionChainCost(n);
    // Four times the unions, about four times the records, never sixteen.
    for (1..5) |i| try testing.expect(cost[i] <= 6 * cost[i - 1]);
}

test "#1143: a cycle with no node on it, a delta over the union it sits in, is grafted" {
    const gpa = testing.allocator;
    var x: KnotFixture = .{};
    try x.init();
    defer x.deinit();
    // K = union(site, D), D = delta(K, {arg: site′}): every part reads
    // another's record, and no node names the cycle. The walk used to
    // refuse it as an invariant.
    const k = try x.shapes.knot(gpa, &x.account);
    const d = try x.shapes.knot(gpa, &x.account);
    const s1 = try x.site(1, x.t_place);
    x.shapes.tie(d, .{ .kind = .delta, .place = x.t_place, .cells = .none, .a = k.int(), .b = try x.one(x.arg, try x.site(2, x.list)), .reach = .none });
    try x.tieUnion(k, s1, d);
    const c = try x.sums.add(x.env(), .{ .params = &.{.none}, .res = k, .kappas = .none });
    var s: Scratch = .{};
    defer s.deinit(gpa);
    const applied = try apply(x.env(), &x.sums, c, &.{.{ .node = try x.site(3, x.t_place), .kappa = .none }}, 0, &s);
    // The image is the same cycle: a union whose delta side's base is it.
    const r = applied.result.node;
    try testing.expectEqual(Shape.Kind.@"union", x.shapes.kind(r));
    const dr: NodeId = .from(x.shapes.get(r).b);
    try testing.expectEqual(Shape.Kind.delta, x.shapes.kind(dr));
    try testing.expectEqual(r.int(), x.shapes.get(dr).a);
}

/// #1146's chain (`unionChainCost`'s), each `N_k` also holding `π0` at its
/// own path when `params`; its root, and `lf` its seed and argument.
fn linkChain(x: *KnotFixture, n: usize, params: bool, lf: NodeId) !NodeId {
    const gpa = testing.allocator;
    const xs = try gpa.alloc(NodeId, n + 1);
    defer gpa.free(xs);
    for (xs) |*k| k.* = try x.shapes.knot(gpa, &x.account);
    // N_k's path: (arg, [*]) repeated n − k times below the root.
    const paths = try gpa.alloc(PathId, n);
    defer gpa.free(paths);
    paths[0] = try x.places.rootPath(gpa, x.t_place);
    for (1..n) |j| {
        const via = (try x.places.extend(gpa, .growth(&x.account), paths[j - 1], x.arg)).?;
        paths[j] = (try x.places.extend(gpa, .growth(&x.account), via, Place.Step.elem)).?;
    }
    for (1..n + 1) |k| {
        const lsite = try x.site(@intCast(100_000 + k), x.list);
        const lk = if (k == 1) lsite else try x.shapes.node(gpa, &x.account, x.list, x.shapes.cells(lsite), try x.one(Place.Step.elem, xs[k - 1]));
        var cells = x.shapes.cells(try x.site(@intCast(10 + k), x.t_place));
        if (params) {
            const p = try x.cells.symbolic(gpa, &x.account, &x.places, .param, 0, paths[n - k], 0);
            cells = try x.cells.sets.insert(gpa, x.env().charge, cells, p.int(), 0);
        }
        const nk = try x.shapes.node(gpa, &x.account, x.t_place, cells, try x.one(x.arg, lk));
        try x.tieUnion(xs[k], nk, if (k == n) lf else xs[k + 1]);
    }
    return xs[n];
}

/// An argument's snapshot: one entry at its root, linked one level down
/// its own `arg`, so each parameter merges a position of its own.
fn linkArgKappa(x: *KnotFixture, lf: NodeId) !Cond.Kappas {
    const ak = (try x.conds.kappaSet(testing.allocator, x.env().charge, .none, lf, Cond.yes)).ctx;
    return x.conds.kappaLink(testing.allocator, x.env().charge, ak, x.arg, ak);
}

/// What linking the chain's arguments costs, in records: the link step
/// alone (the graft is counted above).
fn linkChainCost(n: usize, params: bool) !u64 {
    const gpa = testing.allocator;
    // The tables on the heap: the small-stack test pins `linkArgs`' depth,
    // not the fixture's size.
    const x = try gpa.create(KnotFixture);
    defer gpa.destroy(x);
    x.* = .{};
    try x.init();
    defer x.deinit();
    x.account.allowance = std.math.maxInt(u32) - 1;
    const lf = try x.site(7, x.t_place);
    const root = try linkChain(x, n, params, lf);
    var s: Scratch = .{};
    defer s.deinit(gpa);
    const label = try x.cells.label(gpa, &x.account, 0, .none, false);
    var g: Grafter = .{ .env = x.env(), .sums = &x.sums, .args = &.{.{ .node = lf, .kappa = try linkArgKappa(x, lf) }}, .label = label, .s = &s };
    const before = x.account.total();
    try testing.expect(try g.linkArgs(.none, root) != .none);
    return x.account.total() - before;
}

test "#1146: linking a chain of knots as deep as the source costs each knot its own records" {
    for ([_]bool{ false, true }) |params| {
        var cost: [5]u64 = undefined;
        for ([_]usize{ 4, 16, 64, 256, 1_024 }, 0..) |n, i| cost[i] = try linkChainCost(n, params);
        // Four times the knots, about four times the records (n log n at
        // most), never sixteen: no route scan, no path from the root.
        for (1..5) |i| try testing.expect(cost[i] <= 6 * cost[i - 1]);
    }
}

/// The link step as it was before #1146, for a differential test: each
/// operation replayed from the result's root along its path, the route
/// scanned for a knot.
fn linkByRootPaths(g: *Grafter, kappa: Cond.Kappas, root: NodeId) !Cond.Kappas {
    const gpa = testing.allocator;
    const shapes = g.env.shapes;
    const conds = g.env.conds;
    var out = kappa;
    var path: std.ArrayList(Step) = .empty;
    defer path.deinit(gpa);
    var route: std.ArrayList([2]u32) = .empty;
    defer route.deinit(gpa);
    var paths: Ids.FixedDict(2) = .{};
    defer paths.deinit(gpa);
    var visited: Ids.FixedDict(2) = .{};
    defer visited.deinit(gpa);
    var next_path: u32 = 1;
    const Frame = struct { node: NodeId, pid: u32, step: ?Step, exit: bool };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, .{ .node = root, .pid = 0, .step = null, .exit = false });
    while (stack.pop()) |f| {
        if (f.exit) {
            _ = route.pop();
            if (f.step != null) _ = path.pop();
            continue;
        }
        if ((try visited.getOrPut(gpa, .{ f.node.int(), f.pid })).found_existing) continue;
        if (f.step) |s| try path.append(gpa, s);
        const knot = for (route.items) |r| {
            if (r[0] == f.node.int()) break r[1];
        } else null;
        if (knot) |len| {
            out = try conds.kappaAt(gpa, g.env.charge, out, path.items[0..len], .fold);
            if (f.step != null) _ = path.pop();
            continue;
        }
        try route.append(gpa, .{ f.node.int(), @intCast(path.items.len) });
        try stack.append(gpa, .{ .node = f.node, .pid = f.pid, .step = f.step, .exit = true });
        var it = g.env.cells.sets.iterate(shapes.cells(f.node));
        while (it.next()) |e| if (g.env.cells.origin(.from(e.key)) == .param) {
            const x = g.env.cells.get(.from(e.key));
            out = try conds.kappaAt(gpa, g.env.charge, out, path.items, .{ .merge = try g.argKappa(x.a, .from(x.b)) });
        };
        var kids: std.ArrayList(Frame) = .empty;
        defer kids.deinit(gpa);
        const d = shapes.get(f.node);
        switch (d.kind) {
            .view => unreachable, // the fixtures make no views
            .leaf => {},
            .node, .delta => {
                if (d.kind == .delta) try kids.append(gpa, .{ .node = .from(d.a), .pid = f.pid, .step = null, .exit = false });
                var kt = shapes.overEntries(if (d.kind == .node) d.a else d.b);
                while (kt.next()) |e| {
                    const got = try paths.getOrPut(gpa, .{ f.pid, e.step.word() });
                    if (!got.found_existing) {
                        got.value_ptr.* = next_path;
                        next_path += 1;
                    }
                    try kids.append(gpa, .{ .node = e.node, .pid = got.value_ptr.*, .step = e.step, .exit = false });
                }
            },
            .recast => try kids.append(gpa, .{ .node = .from(d.a), .pid = f.pid, .step = null, .exit = false }),
            .@"union", .choice, .positions => try kids.appendSlice(gpa, &.{ .{ .node = .from(d.a), .pid = f.pid, .step = null, .exit = false }, .{ .node = .from(d.b), .pid = f.pid, .step = null, .exit = false } }),
        }
        var k = kids.items.len;
        while (k > 0) {
            k -= 1;
            try stack.append(gpa, kids.items[k]);
        }
    }
    return out;
}

test "#1146: linking at each knot's own cursor builds the snapshot replaying root paths builds" {
    const gpa = testing.allocator;
    // The chain with and without parameters, a tree with no knot, and one
    // argument passed for two parameters (an aliased control).
    for (0..4) |case| {
        var x: KnotFixture = .{};
        try x.init();
        defer x.deinit();
        x.account.allowance = std.math.maxInt(u32) - 1;
        const lf = try x.site(7, x.t_place);
        const ak = try linkArgKappa(&x, lf);
        const root: NodeId = switch (case) {
            0 => try linkChain(&x, 8, false, lf),
            1 => try linkChain(&x, 8, true, lf),
            else => blk: {
                // T{arg: L{[*]: union(P0, P1)}}, P_i the parameter's leaf at
                // the element's path, and π0 at T's root.
                const rp = try x.places.rootPath(gpa, x.t_place);
                const ep = (try x.places.extend(gpa, .growth(&x.account), (try x.places.extend(gpa, .growth(&x.account), rp, x.arg)).?, Place.Step.elem)).?;
                const leafAt = struct {
                    fn of(f: *KnotFixture, i: u32, p: PathId) !NodeId {
                        const c = try f.cells.symbolic(testing.allocator, &f.account, &f.places, .param, i, p, 0);
                        return f.shapes.leaf(testing.allocator, &f.account, f.t_place, try f.cells.sets.insert(testing.allocator, f.env().charge, .none, c.int(), 0));
                    }
                }.of;
                const u = try x.shapes.@"union"(gpa, &x.account, &x.cells.sets, try leafAt(&x, 0, ep), try leafAt(&x, @intCast(case - 2), ep));
                const l = try x.shapes.node(gpa, &x.account, x.list, .none, try x.one(Place.Step.elem, u));
                break :blk try x.shapes.node(gpa, &x.account, x.t_place, x.shapes.cells(try leafAt(&x, 0, rp)), try x.one(x.arg, l));
            },
        };
        var s: Scratch = .{};
        defer s.deinit(gpa);
        const label = try x.cells.label(gpa, &x.account, 0, .none, false);
        const args = [_]Value{ .{ .node = lf, .kappa = ak }, .{ .node = lf, .kappa = ak } };
        var g: Grafter = .{ .env = x.env(), .sums = &x.sums, .args = &args, .label = label, .s = &s };
        const seed = (try x.conds.kappaSet(gpa, x.env().charge, .none, lf, Cond.yes)).ctx;
        try testing.expectEqual(try linkByRootPaths(&g, seed, root), try g.linkArgs(seed, root));
    }
}

test "#1146: a chain of knots as deep as the source is linked on a small stack" {
    var result: anyerror!u64 = 0;
    const th = try std.Thread.spawn(.{ .stack_size = 64 << 10 }, struct {
        fn run(out: *anyerror!u64) void {
            out.* = linkChainCost(1_024, true);
        }
    }.run, .{&result});
    th.join();
    _ = try result;
}

// ---- the review's random differential (#1149) ---------------------------------------

/// How a new snapshot `b` differs from the root-path replay's `a`: 0 the
/// same, 1 only a collapsed fold that saw more steps (the replay drops a
/// step first taken after the backedge; the cursor walk keeps every step
/// linked below), 2 anything else.
fn linkDiff(c: *Cond.Table, a: Cond.Kappas, b: Cond.Kappas, depth: u32) u8 {
    if (a == b) return 0;
    if (depth > 40) return 2;
    const pa = c.position(a);
    const pb = c.position(b);
    if (pa.here != pb.here or pa.fold != pb.fold) return 2;
    if (pa.fold != 0) {
        var na: u32 = 0;
        var nb: u32 = 0;
        var it = c.kappaLinks(a);
        while (it.next()) |_| na += 1;
        var it2 = c.kappaLinks(b);
        while (it2.next()) |_| nb += 1;
        return if (nb > na) 1 else 2;
    }
    var worst: u8 = 0;
    var cnt_a: u32 = 0;
    var la = c.kappaLinks(a);
    while (la.next()) |e| {
        cnt_a += 1;
        worst = @max(worst, linkDiff(c, e.child, c.kappaChild(b, e.step), depth + 1));
    }
    var cnt_b: u32 = 0;
    var lb = c.kappaLinks(b);
    while (lb.next()) |_| cnt_b += 1;
    return if (cnt_a != cnt_b) 2 else worst;
}

const RevRand = struct {
    x: *KnotFixture,
    r: std.Random,
    knots: []NodeId,
    cells: []CellId,
    paths: []PathId,
    flags: u32,

    fn on(rv: *const RevRand, b: u5) bool {
        return rv.flags & (@as(u32, 1) << b) != 0;
    }

    fn step(rv: *RevRand) Step {
        return if (rv.r.boolean()) rv.x.arg else Place.Step.elem;
    }

    fn cond(rv: *RevRand) !CondId {
        const gpa = testing.allocator;
        return switch (rv.r.uintLessThan(u8, 4)) {
            0 => Cond.yes,
            1 => rv.x.conds.excl(gpa, rv.x.env().charge, rv.cells[rv.r.uintLessThan(usize, rv.cells.len)]),
            2 => rv.x.conds.@"and"(gpa, rv.x.env().charge, try rv.x.conds.excl(gpa, rv.x.env().charge, rv.cells[0]), try rv.x.conds.excl(gpa, rv.x.env().charge, rv.cells[rv.r.uintLessThan(usize, rv.cells.len)])),
            else => rv.x.conds.excl(gpa, rv.x.env().charge, rv.cells[1]),
        };
    }

    fn kappa(rv: *RevRand, depth: u32) !Cond.Kappas {
        const gpa = testing.allocator;
        const ch = rv.x.env().charge;
        const c = &rv.x.conds;
        var k: Cond.Kappas = .none;
        const roll = rv.r.uintLessThan(u8, 10);
        if (roll == 0 and rv.on(0)) k = try c.kappaEmptyFold(gpa, ch, Cond.Table.fold_exact);
        for (0..rv.r.uintLessThan(usize, 3)) |_| {
            k = (try c.kappaSet(gpa, ch, k, rv.knots[rv.r.uintLessThan(usize, rv.knots.len)], try rv.cond())).ctx;
        }
        if (depth > 0) for (0..rv.r.uintLessThan(usize, 3)) |_| {
            const s = rv.step();
            const sub = try rv.kappa(depth - 1);
            k = if (c.isFold(k)) (if (sub == .none) k else try c.kappaMerge(gpa, ch, k, sub)) else try c.kappaLink(gpa, ch, k, s, sub);
            if (c.isFold(k)) k = try c.kappaFoldStep(gpa, ch, k, s);
        };
        if (roll == 1 and rv.on(1)) k = try c.kappaFold(gpa, ch, k);
        return k;
    }
};

fn linkRandom(seed_: u64, flags: u32) !u8 {
    const gpa = testing.allocator;
    var x: KnotFixture = .{};
    try x.init();
    defer x.deinit();
    x.account.allowance = std.math.maxInt(u32) - 1;
    var prng = std.Random.DefaultPrng.init(seed_);
    const r = prng.random();
    const n = 2 + r.uintLessThan(usize, 8);
    var knots: [10]NodeId = undefined;
    for (knots[0..n]) |*k| k.* = try x.shapes.knot(gpa, &x.account);
    var cells: [4]CellId = undefined;
    for (&cells, 0..) |*c, i| c.* = try x.cells.site(gpa, &x.account, @intCast(500 + i), x.t_place, .record);
    var paths: [6]PathId = undefined;
    paths[0] = try x.places.rootPath(gpa, x.t_place);
    for (1..6) |j| paths[j] = (try x.places.extend(gpa, .growth(&x.account), paths[j - 1], if (j % 2 == 1) x.arg else Place.Step.elem)).?;
    var rv: RevRand = .{ .x = &x, .r = r, .knots = knots[0..n], .cells = &cells, .paths = &paths, .flags = flags };
    const leaves = 3;
    var lf: [leaves]NodeId = undefined;
    for (&lf, 0..) |*l, i| {
        var cs: SetId = .none;
        for (0..r.uintLessThan(usize, 3)) |_| {
            const p = try x.cells.symbolic(gpa, &x.account, &x.places, .param, r.uintLessThan(u32, 3), paths[r.uintLessThan(usize, 6)], 0);
            cs = try x.cells.sets.insert(gpa, x.env().charge, cs, p.int(), 0);
        }
        l.* = try x.shapes.leaf(gpa, &x.account, x.t_place, try x.cells.sets.insert(gpa, x.env().charge, cs, cells[i].int(), 0));
    }
    const pick = struct {
        fn of(rr: std.Random, ks: []NodeId, ls: []NodeId) NodeId {
            return if (rr.uintLessThan(u8, 4) == 0) ls[rr.uintLessThan(usize, ls.len)] else ks[rr.uintLessThan(usize, ks.len)];
        }
    }.of;
    for (knots[0..n]) |k| {
        var cs: SetId = .none;
        for (0..r.uintLessThan(usize, 3)) |_| {
            const p = try x.cells.symbolic(gpa, &x.account, &x.places, .param, r.uintLessThan(u32, 3), paths[r.uintLessThan(usize, 6)], 0);
            cs = try x.cells.sets.insert(gpa, x.env().charge, cs, p.int(), 0);
        }
        var kind = r.uintLessThan(u8, 6);
        if (kind == 2 and !rv.on(2)) kind = 0;
        if (kind == 3 and !rv.on(3)) kind = 0;
        if (kind == 5 and !rv.on(4)) kind = 4;
        switch (kind) {
            0, 1 => {
                var over: u32 = Ids.none_int;
                for (0..1 + r.uintLessThan(usize, 2)) |_| over = try x.shapes.overPut(gpa, &x.account, over, rv.step(), pick(r, knots[0..n], &lf));
                x.shapes.tie(k, .{ .kind = .node, .place = x.t_place, .cells = cs, .a = over, .b = 0, .reach = .none });
            },
            2 => {
                const over = try x.shapes.overPut(gpa, &x.account, Ids.none_int, rv.step(), pick(r, knots[0..n], &lf));
                const base = lf[r.uintLessThan(usize, leaves)];
                x.shapes.tie(k, .{ .kind = .delta, .place = x.t_place, .cells = x.shapes.cells(base), .a = base.int(), .b = over, .reach = .none });
            },
            3 => x.shapes.tie(k, .{ .kind = .recast, .place = x.t_place, .cells = cs, .a = pick(r, knots[0..n], &lf).int(), .b = 0, .reach = .none }),
            else => x.shapes.tie(k, .{ .kind = if (kind == 4) .@"union" else .positions, .place = x.t_place, .cells = cs, .a = pick(r, knots[0..n], &lf).int(), .b = pick(r, knots[0..n], &lf).int(), .reach = .none }),
        }
    }
    const args = [_]Value{
        .{ .node = lf[0], .kappa = try rv.kappa(3) },
        .{ .node = lf[1], .kappa = try rv.kappa(3) },
        .{ .node = lf[2], .kappa = try rv.kappa(3) },
    };
    const seed = try rv.kappa(3);
    var s: Scratch = .{};
    defer s.deinit(gpa);
    const label = try x.cells.label(gpa, &x.account, 0, .none, false);
    var g: Grafter = .{ .env = x.env(), .sums = &x.sums, .args = &args, .label = label, .s = &s };
    const want = try linkByRootPaths(&g, seed, knots[0]);
    const got = try g.linkArgs(seed, knots[0]);
    return linkDiff(&x.conds, want, got, 0);
}

// Random graphs of up to 9 knots: nodes, deltas, recasts, unions and
// positions, back edges anywhere, parameters at six paths, seeds and
// arguments with exact and collapsed folds. Every snapshot is the replay's,
// or differs only in a collapsed fold's steps, which the cursor walk keeps
// for every step linked below it. 600 graphs as before, 150 a test (one
// test of all was over the 1 s budget, #1197), the heavier kinds 100 a test
// (#1209); each allows its share of the 60 step-only differences the whole
// allowed (1 and 3 measured).
test "#1149 review: random cyclic results link to the root-path replay's snapshot, a collapsed fold seeing more steps at most: every kind, seeds 0–99" {
    try testing.expect(try linkRandomSweep(0xff, 0, 100) < 10);
}

test "#1149 review: random cyclic results link to the root-path replay's snapshot, a collapsed fold seeing more steps at most: every kind, seeds 100–199" {
    try testing.expect(try linkRandomSweep(0xff, 100, 200) < 10);
}

test "#1149 review: random cyclic results link to the root-path replay's snapshot, a collapsed fold seeing more steps at most: every kind, seeds 200–299" {
    try testing.expect(try linkRandomSweep(0xff, 200, 300) < 10);
}

test "#1149 review: random cyclic results link to the root-path replay's snapshot, a collapsed fold seeing more steps at most: plain graphs, seeds 0–149" {
    try testing.expect(try linkRandomSweep(0xe0, 0, 150) < 15);
}

test "#1149 review: random cyclic results link to the root-path replay's snapshot, a collapsed fold seeing more steps at most: plain graphs, seeds 150–299" {
    try testing.expect(try linkRandomSweep(0xe0, 150, 300) < 15);
}

/// How many random graphs of the kind mix `flags`, seeds `from` to `to`,
/// differ from the replay only in a collapsed fold's steps; any other
/// difference fails.
fn linkRandomSweep(flags: u32, from: u64, to: u64) !u32 {
    var steps_only: u32 = 0;
    var q: u64 = from;
    while (q < to) : (q += 1) switch (try linkRandom(q, flags)) {
        0 => {},
        1 => steps_only += 1,
        else => return error.TestUnexpectedResult,
    };
    return steps_only;
}

test "#1149 review: a merge after a backedge's fold is a step the collapsed fold saw" {
    const gpa = testing.allocator;
    var x: KnotFixture = .{};
    try x.init();
    defer x.deinit();
    x.account.allowance = std.math.maxInt(u32) - 1;
    // N0 = T{ arg: N0, [*]: N1 }, π1 at ε (arg walked first: the backedge);
    // N1 = union(leaf, leaf), π2 at ε.
    const root = try x.places.rootPath(gpa, x.t_place);
    const p1 = try x.cells.symbolic(gpa, &x.account, &x.places, .param, 0, root, 0);
    const p2 = try x.cells.symbolic(gpa, &x.account, &x.places, .param, 1, root, 0);
    const n0 = try x.shapes.knot(gpa, &x.account);
    const l1 = try x.site(1, x.t_place);
    const l2 = try x.site(2, x.t_place);
    const set2 = try x.cells.sets.insert(gpa, x.env().charge, try x.cells.sets.unionWith(gpa, x.env().charge, x.shapes.cells(l1), x.shapes.cells(l2)), p2.int(), 0);
    const n1 = try x.shapes.knot(gpa, &x.account);
    x.shapes.tie(n1, .{ .kind = .@"union", .place = x.t_place, .cells = set2, .a = l1.int(), .b = l2.int(), .reach = .none });
    var over = try x.one(x.arg, n0);
    over = try x.shapes.overPut(gpa, &x.account, over, Place.Step.elem, n1);
    x.shapes.tie(n0, .{ .kind = .node, .place = x.t_place, .cells = try x.cells.sets.insert(gpa, x.env().charge, .none, p1.int(), 0), .a = over, .b = 0, .reach = .none });
    const ak = (try x.conds.kappaSet(gpa, x.env().charge, .none, l1, try x.conds.excl(gpa, x.env().charge, p1))).ctx;
    const args = [_]Value{ .{ .node = l1, .kappa = ak }, .{ .node = l2, .kappa = ak } };
    var s: Scratch = .{};
    defer s.deinit(gpa);
    const label = try x.cells.label(gpa, &x.account, 0, .none, false);
    var g: Grafter = .{ .env = x.env(), .sums = &x.sums, .args = &args, .label = label, .s = &s };
    const want = try linkByRootPaths(&g, .none, n0);
    const got = try g.linkArgs(.none, n0);
    // The same conditions and fold kind; the cursor walk's fold also saw `[*]`.
    try testing.expect(want != got);
    try testing.expectEqual(@as(u8, 1), linkDiff(&x.conds, want, got, 0));
    try testing.expect(x.conds.isCollapsed(got));
}

test "#1128: a template path through ⟲ compares the argument's arrivals across the depths it folds" {
    const gpa = testing.allocator;
    for ([_]bool{ true, false }) |repeat| {
        var x: KnotFixture = .{};
        try x.init();
        defer x.deinit();
        x.account.allowance = std.math.maxInt(u32) - 1;
        // The class relies on `excl π1·⟲.arg`: every kids list below the root
        // exclusive. The actual: `T{arg: L0}`, `L0[*] = [ T{arg: K}, T{arg:
        // L2} ]`, `L2[*] = T{arg: K or K′}` — one kids list at two depths, or
        // two distinct ones. No single path of the actual holds K twice.
        const root = try x.places.rootPath(gpa, x.t_place);
        const down = (try x.places.extend(gpa, .growth(&x.account), (try x.places.extend(gpa, .growth(&x.account), root, x.arg)).?, Place.Step.elem)).?;
        try testing.expectEqual(Place.StepKind.level, x.places.pathStep(down).kind);
        const kids = (try x.places.extend(gpa, .growth(&x.account), down, x.arg)).?;
        const p = try x.cells.symbolic(gpa, &x.account, &x.places, .param, 0, kids, 0);
        const xreq = try x.conds.flat(gpa, x.env().charge, try x.conds.excl(gpa, x.env().charge, p));
        const c = try x.sums.add(x.env(), .{ .params = &.{.none}, .res = try x.site(90, x.t_place), .kappas = .none, .xreq = xreq });
        const k = try x.site(1, x.list);
        const k2 = if (repeat) k else try x.site(2, x.list);
        const tOf = struct {
            fn of(f: *KnotFixture, kidsl: NodeId) !NodeId {
                return f.shapes.node(testing.allocator, &f.account, f.t_place, .none, try f.one(f.arg, kidsl));
            }
        }.of;
        const listOf = struct {
            fn of(f: *KnotFixture, i: u32, elems: NodeId) !NodeId {
                return f.shapes.node(testing.allocator, &f.account, f.list, f.shapes.cells(try f.site(i, f.list)), try f.one(Place.Step.elem, elems));
            }
        }.of;
        const t3 = try tOf(&x, k2);
        const l2 = try listOf(&x, 3, t3);
        const t1 = try tOf(&x, k);
        const t2 = try tOf(&x, l2);
        const l0 = try listOf(&x, 4, try x.shapes.collect(gpa, &x.account, &x.cells.sets, &.{ t1, t2 }));
        const arg = try tOf(&x, l0);
        // The actual's own snapshot: every built node `yes` where it stands.
        const e = Place.Step.elem;
        const at = [_]struct { n: NodeId, p: []const Step }{
            .{ .n = arg, .p = &.{} },                    .{ .n = l0, .p = &.{x.arg} },
            .{ .n = t1, .p = &.{ x.arg, e } },           .{ .n = t2, .p = &.{ x.arg, e } },
            .{ .n = k, .p = &.{ x.arg, e, x.arg } },     .{ .n = l2, .p = &.{ x.arg, e, x.arg } },
            .{ .n = t3, .p = &.{ x.arg, e, x.arg, e } }, .{ .n = k2, .p = &.{ x.arg, e, x.arg, e, x.arg } },
        };
        var ak: Cond.Kappas = .none;
        for (at) |q| ak = try x.conds.kappaSetAt(gpa, x.env().charge, ak, q.p, q.n, Cond.yes);
        var s: Scratch = .{};
        defer s.deinit(gpa);
        const applied = try apply(x.env(), &x.sums, c, &.{.{ .node = arg, .kappa = ak }}, 0, &s);
        try testing.expectEqual(repeat, Cond.Table.fails(applied.xreq));
    }
}

/// #1157's probes: a class relying on `excl π1·q`, q the path `steps` takes
/// from `root` (re-entries canonical, so through `⟲`), applied to `arg`
/// whose snapshot stores `yes` for every built node where it stands; the
/// reliance as the call instantiates it.
fn foldProbe(x: *KnotFixture, root: PlaceId, steps: []const Step, arg: NodeId) !CondId {
    const gpa = testing.allocator;
    var p = try x.places.rootPath(gpa, root);
    for (steps) |s| p = (try x.places.extend(gpa, .growth(&x.account), p, s)).?;
    const cell = try x.cells.symbolic(gpa, &x.account, &x.places, .param, 0, p, 0);
    const xreq = try x.conds.flat(gpa, x.env().charge, try x.conds.excl(gpa, x.env().charge, cell));
    const c = try x.sums.add(x.env(), .{ .params = &.{.none}, .res = try x.site(90, x.t_place), .kappas = .none, .xreq = xreq });
    var ak: Cond.Kappas = .none;
    var path: std.ArrayList(Step) = .empty;
    defer path.deinit(gpa);
    try snapshotYes(x, arg, &path, &ak);
    var s: Scratch = .{};
    defer s.deinit(gpa);
    return (try apply(x.env(), &x.sums, c, &.{.{ .node = arg, .kappa = ak }}, 0, &s)).xreq;
}

fn snapshotYes(x: *KnotFixture, n: NodeId, path: *std.ArrayList(Step), ak: *Cond.Kappas) !void {
    const gpa = testing.allocator;
    const d = x.shapes.get(n);
    switch (d.kind) {
        .view => try snapshotYes(x, try x.shapes.force(gpa, &x.account, n), path, ak),
        .node, .delta => {
            // A cyclic source (a knot) is snapshotted to a bounded depth.
            if (path.items.len > 16) return;
            ak.* = try x.conds.kappaSetAt(gpa, x.env().charge, ak.*, path.items, n, Cond.yes);
            var it = x.shapes.overEntries(if (d.kind == .node) d.a else d.b);
            while (it.next()) |e| {
                try path.append(gpa, e.step);
                try snapshotYes(x, e.node, path, ak);
                _ = path.pop();
            }
        },
        .@"union", .choice, .positions => {
            try snapshotYes(x, .from(d.a), path, ak);
            try snapshotYes(x, .from(d.b), path, ak);
        },
        .leaf, .recast => {},
    }
}

/// `C{ step: kids }` at `place`, and a list of `elems` with its own site.
fn ctorOf(x: *KnotFixture, place: PlaceId, step: Step, kids: NodeId) !NodeId {
    return x.shapes.node(testing.allocator, &x.account, place, .none, try x.one(step, kids));
}

fn listAt(x: *KnotFixture, place: PlaceId, i: u32, elems: ?NodeId) !NodeId {
    const site = x.shapes.cells(try x.site(i, place));
    return if (elems) |e| x.shapes.node(testing.allocator, &x.account, place, site, try x.one(Place.Step.elem, e)) else x.shapes.leaf(testing.allocator, &x.account, place, site);
}

test "#1157 review, #1159: a template path through ⟲ reads its full preimage: hidden repeats refuse, distinct positions accept" {
    const gpa = testing.allocator;
    const e = Place.Step.elem;
    for (0..6) |probe| {
        var x: KnotFixture = .{};
        try x.init();
        defer x.deinit();
        x.account.allowance = std.math.maxInt(u32) - 1;
        const src: Place.Source = .{ .ctx = &x.graph, .describe = TestGraph.describe };
        const T = x.t_place;
        const L = x.list;
        const k = try listAt(&x, L, 1, null);
        const got: CondId = switch (probe) {
            // A choice (0) or a union (1) in a field, `k` inside one arm and
            // beside it: `T [ T (if c then [T k] else []), T k ]`.
            0, 1 => blk: {
                const arm = try listAt(&x, L, 2, try ctorOf(&x, T, x.arg, k));
                const none_arm = try listAt(&x, L, 3, null);
                const field = if (probe == 0) try x.shapes.choice(gpa, &x.account, &x.cells.sets, arm, none_arm) else try x.shapes.@"union"(gpa, &x.account, &x.cells.sets, arm, none_arm);
                const l0 = try listAt(&x, L, 4, try x.shapes.collect(gpa, &x.account, &x.cells.sets, &.{ try ctorOf(&x, T, x.arg, field), try ctorOf(&x, T, x.arg, k) }));
                break :blk try foldProbe(&x, T, &.{ x.arg, e, x.arg }, try ctorOf(&x, T, x.arg, l0));
            },
            // Mutual `A = A (List C)`, `C = C (List A)`: `A [C [A k], C [A [C [A k]]]]`.
            2 => blk: {
                const A = try x.places.of(gpa, &x.account, src, 2);
                const LC = try x.places.of(gpa, &x.account, src, 3);
                const C = try x.places.of(gpa, &x.account, src, 4);
                const LA = try x.places.of(gpa, &x.account, src, 5);
                const a0 = try x.places.ctorStep(gpa, &x.account, 1, 0);
                const c0 = try x.places.ctorStep(gpa, &x.account, 2, 0);
                const km = try listAt(&x, LC, 1, null);
                const c1 = try ctorOf(&x, C, c0, try listAt(&x, LA, 2, try ctorOf(&x, A, a0, km)));
                const deep = try ctorOf(&x, C, c0, try listAt(&x, LA, 3, try ctorOf(&x, A, a0, try listAt(&x, LC, 4, try ctorOf(&x, C, c0, try listAt(&x, LA, 5, try ctorOf(&x, A, a0, km)))))));
                const root = try ctorOf(&x, A, a0, try listAt(&x, LC, 6, try x.shapes.collect(gpa, &x.account, &x.cells.sets, &.{ c1, deep })));
                break :blk try foldProbe(&x, A, &.{ a0, e, c0, e, a0 }, root);
            },
            // A prefix through `[*]`: `R2 [ T k, T [T k] ]`, q = `0·[*]·⟲·arg`.
            3 => blk: {
                const R2 = try x.places.of(gpa, &x.account, src, 6);
                const LT = try x.places.of(gpa, &x.account, src, 7);
                const r0 = try x.places.ctorStep(gpa, &x.account, 3, 0);
                const t2 = try ctorOf(&x, T, x.arg, try listAt(&x, L, 2, try ctorOf(&x, T, x.arg, k)));
                const root = try ctorOf(&x, R2, r0, try listAt(&x, LT, 3, try x.shapes.collect(gpa, &x.account, &x.cells.sets, &.{ try ctorOf(&x, T, x.arg, k), t2 })));
                break :blk try foldProbe(&x, R2, &.{ r0, e, x.arg, e, x.arg }, root);
            },
            // A symbolic leaf: the caller's own parameter as a kids list, its
            // projections below it out of the walk's sight.
            4 => blk: {
                const q = try x.cells.symbolic(gpa, &x.account, &x.places, .param, 7, try x.places.rootPath(gpa, L), 0);
                const ql = try x.shapes.leaf(gpa, &x.account, L, try x.cells.sets.insert(gpa, x.env().charge, .none, q.int(), 0));
                const l0 = try listAt(&x, L, 2, try x.shapes.collect(gpa, &x.account, &x.cells.sets, &.{ try ctorOf(&x, T, x.arg, ql), try ctorOf(&x, T, x.arg, k) }));
                break :blk try foldProbe(&x, T, &.{ x.arg, e, x.arg }, try ctorOf(&x, T, x.arg, l0));
            },
            // Control: an opened choice at the re-entry, `k` in one arm alone.
            else => blk: {
                const l0 = try listAt(&x, L, 2, try x.shapes.choice(gpa, &x.account, &x.cells.sets, try ctorOf(&x, T, x.arg, k), try ctorOf(&x, T, x.arg, try listAt(&x, L, 3, null))));
                break :blk try foldProbe(&x, T, &.{ x.arg, e, x.arg }, try ctorOf(&x, T, x.arg, l0));
            },
        };
        switch (probe) {
            // A repeat across depths inside a choice's arm, a union's side, or
            // through mutual types: the full preimage sees it (#1159).
            0, 1, 2 => try testing.expectEqual(Cond.lost, got),
            // `R2 [ T k, T [T k] ]` under `0·[*]·⟲·arg`: the first `k` is at
            // `0·[*]·arg`, another canonical path, outside the template path's
            // preimage; the second is its only occurrence there. A callee
            // writing both paths is caught by the caller's Disjoint across its
            // W paths (§2.11 item 3), not by this read.
            3 => try testing.expectEqual(Cond.yes, got),
            // The symbolic leaf: its projections below it are occurrences too.
            // They owe their `summaryExcl` and an `apart` with the leaf's own
            // cell, which the caller instantiates through `⟲` (#1199).
            4 => {
                try testing.expect(!Cond.Table.fails(got));
                var it = x.conds.atoms.iterate(try x.conds.flat(gpa, x.env().charge, got));
                var apart = false;
                var summary_excl = false;
                while (it.next()) |a| {
                    const atom_ = x.conds.get(.from(a.key));
                    apart = apart or atom_.atom == .apart;
                    summary_excl = summary_excl or (atom_.atom == .excl and x.places.isSummary(.from(x.cells.get(.from(atom_.a)).b)));
                }
                try testing.expect(apart and summary_excl);
            },
            else => try testing.expectEqual(Cond.yes, got),
        }
    }
}

test "#1157 review: one fold of an argument per template path at a call, however many atoms read it" {
    const gpa = testing.allocator;
    var grew: [2]u32 = undefined;
    for ([_]u32{ 1, 8 }, 0..) |atoms, run| {
        var x: KnotFixture = .{};
        try x.init();
        defer x.deinit();
        x.account.allowance = std.math.maxInt(u32) - 1;
        const e = Place.Step.elem;
        var p = try x.places.rootPath(gpa, x.t_place);
        for ([_]Step{ x.arg, e, x.arg }) |s| p = (try x.places.extend(gpa, .growth(&x.account), p, s)).?;
        const cell = try x.cells.symbolic(gpa, &x.account, &x.places, .param, 0, p, 0);
        // `atoms` conditions each relying on `excl π1·⟲.arg` (with a site of
        // its own beside it), stored at distinct result nodes.
        const ex = try x.conds.excl(gpa, x.env().charge, cell);
        var km: Cond.Kappas = .none;
        var leaves: [8]NodeId = undefined;
        for (0..atoms) |i| {
            const leaf = try x.site(@intCast(200 + i), x.t_place);
            const sep = try x.conds.excl(gpa, x.env().charge, try x.cells.site(gpa, &x.account, @intCast(300 + i), x.t_place, .record));
            km = try x.conds.kappaSetAt(gpa, x.env().charge, km, &.{e}, leaf, try x.conds.@"and"(gpa, x.env().charge, ex, sep));
            leaves[i] = leaf;
        }
        const res = try listAt(&x, x.list, 9, try x.shapes.collect(gpa, &x.account, &x.cells.sets, leaves[0..atoms]));
        const c = try x.sums.add(x.env(), .{ .params = &.{.none}, .res = res, .kappas = km, .xreq = try x.conds.flat(gpa, x.env().charge, ex) });
        const k = try listAt(&x, x.list, 1, null);
        const l0 = try listAt(&x, x.list, 2, try x.shapes.collect(gpa, &x.account, &x.cells.sets, &.{ try ctorOf(&x, x.t_place, x.arg, k), try ctorOf(&x, x.t_place, x.arg, try listAt(&x, x.list, 3, try ctorOf(&x, x.t_place, x.arg, k))) }));
        const arg = try ctorOf(&x, x.t_place, x.arg, l0);
        var s: Scratch = .{};
        defer s.deinit(gpa);
        const before = x.shapes.count();
        _ = try apply(x.env(), &x.sums, c, &.{.{ .node = arg, .kappa = .none }}, 0, &s);
        grew[run] = x.shapes.count() - before;
    }
    // The argument is folded once: eight atoms add no image of their own.
    try testing.expectEqual(grew[0], grew[1]);
}

/// `B l r` at place 8, and a `List B` of `elems` (none: a leaf of its site).
fn bOf(x: *KnotFixture, l: NodeId, r: NodeId) !NodeId {
    const gpa = testing.allocator;
    const src: Place.Source = .{ .ctx = &x.graph, .describe = TestGraph.describe };
    const B = try x.places.of(gpa, &x.account, src, 8);
    const over = try x.shapes.overPut(gpa, &x.account, try x.one(try x.places.ctorStep(gpa, &x.account, 4, 0), l), try x.places.ctorStep(gpa, &x.account, 4, 1), r);
    return x.shapes.node(gpa, &x.account, B, .none, over);
}

fn bList(x: *KnotFixture, i: u32, elems: []const NodeId) !NodeId {
    const gpa = testing.allocator;
    const src: Place.Source = .{ .ctx = &x.graph, .describe = TestGraph.describe };
    const LB = try x.places.of(gpa, &x.account, src, 9);
    if (elems.len == 0) return listAt(x, LB, i, null);
    return listAt(x, LB, i, if (elems.len == 1) elems[0] else try x.shapes.collect(gpa, &x.account, &x.cells.sets, elems));
}

test "#1159: the full preimage over nested, shared, chosen and cyclic records of lists" {
    const gpa = testing.allocator;
    const e = Place.Step.elem;
    const Want = enum { lost, yes };
    for (0..8) |probe| {
        var x: KnotFixture = .{};
        try x.init();
        defer x.deinit();
        x.account.allowance = std.math.maxInt(u32) - 1;
        const src: Place.Source = .{ .ctx = &x.graph, .describe = TestGraph.describe };
        const B = try x.places.of(gpa, &x.account, src, 8);
        const b0 = try x.places.ctorStep(gpa, &x.account, 4, 0);
        const k = try bList(&x, 1, &.{});
        const k2 = try bList(&x, 2, &.{});
        var ids: u32 = 40;
        // Template `π0·⟲·.0` (B's `.0` lists at depth ≥ 1), from `.0[*]·.0`.
        const steps = [_]Step{ b0, e, b0 };
        const arg: NodeId, const want: Want = switch (probe) {
            // FoldedBCall's actual: `B [B k []] [B k []]`, k at `.0[*].0` and
            // `.1[*].0`; the distinct twin.
            0 => .{ try bOf(&x, try bList(&x, 4, &.{try bOf(&x, k, try bList(&x, nextId(&ids), &.{}))}), try bList(&x, 5, &.{try bOf(&x, k, try bList(&x, nextId(&ids), &.{}))})), .lost },
            1 => .{ try bOf(&x, try bList(&x, 4, &.{try bOf(&x, k, try bList(&x, nextId(&ids), &.{}))}), try bList(&x, 5, &.{try bOf(&x, k2, try bList(&x, nextId(&ids), &.{}))})), .yes },
            // k at `.0[*].0` and at `.1[*].1`: only one in the preimage.
            2 => .{ try bOf(&x, try bList(&x, 4, &.{try bOf(&x, k, try bList(&x, nextId(&ids), &.{}))}), try bList(&x, 5, &.{try bOf(&x, try bList(&x, nextId(&ids), &.{}), k)})), .yes },
            // An earlier-built value shared at two coexisting positions: one
            // node, two routes, its `.0` twice.
            3 => blk: {
                const shared_b = try bOf(&x, k, try bList(&x, nextId(&ids), &.{}));
                break :blk .{ try bOf(&x, try bList(&x, 4, &.{shared_b}), try bList(&x, 5, &.{shared_b})), .lost };
            },
            // The same value in both arms of a choice: one execution, once.
            4 => blk: {
                const one_b = try bOf(&x, k, try bList(&x, nextId(&ids), &.{}));
                const arms = try x.shapes.choice(gpa, &x.account, &x.cells.sets, try bList(&x, 4, &.{one_b}), try bList(&x, 6, &.{ one_b, try bOf(&x, k2, try bList(&x, nextId(&ids), &.{})) }));
                break :blk .{ try bOf(&x, arms, try bList(&x, nextId(&ids), &.{})), .yes };
            },
            // A choice of depths for k, beside k elsewhere: either arm repeats.
            5 => blk: {
                const arms = try x.shapes.choice(gpa, &x.account, &x.cells.sets, try bList(&x, 4, &.{try bOf(&x, k, try bList(&x, nextId(&ids), &.{}))}), try bList(&x, 6, &.{try bOf(&x, try bList(&x, 7, &.{try bOf(&x, k, try bList(&x, nextId(&ids), &.{}))}), try bList(&x, nextId(&ids), &.{}))}));
                break :blk .{ try bOf(&x, arms, try bList(&x, 5, &.{try bOf(&x, k, try bList(&x, nextId(&ids), &.{}))})), .lost };
            },
            // A list of lists three deep, every `.0` distinct.
            6 => blk: {
                const deep3 = try bOf(&x, try bList(&x, 8, &.{try bOf(&x, k2, try bList(&x, nextId(&ids), &.{}))}), try bList(&x, nextId(&ids), &.{}));
                const deep2 = try bOf(&x, try bList(&x, 9, &.{deep3}), try bList(&x, nextId(&ids), &.{}));
                break :blk .{ try bOf(&x, try bList(&x, 4, &.{ deep2, try bOf(&x, k, try bList(&x, nextId(&ids), &.{})) }), try bList(&x, nextId(&ids), &.{})), .yes };
            },
            // A cyclic source (a widened knot, as a fixpoint round feeds): its
            // depths are unboundedly many coexisting positions, all repeated.
            // A cyclic source (a knot, as a fixpoint round feeds one): a B
            // whose `.0` list holds itself. Its depths are unboundedly many
            // coexisting positions, so the equations settle with every
            // occurrence below the cycle repeated: `lost`, sound. Whether a
            // widened image's own fold certificate may stand for that
            // multiset instead is an open question (see the PR), not taken
            // here.
            7 => blk: {
                const knot = try x.shapes.knot(gpa, &x.account);
                const kids = try bList(&x, 10, &.{knot});
                x.shapes.tie(knot, x.shapes.get(try bOf(&x, kids, try bList(&x, nextId(&ids), &.{}))));
                break :blk .{ try bOf(&x, try bList(&x, 4, &.{knot}), try bList(&x, nextId(&ids), &.{})), .lost };
            },
            else => unreachable,
        };
        const got = try foldProbe(&x, B, &steps, arg);
        switch (want) {
            .lost => try testing.expectEqual(Cond.lost, got),
            .yes => try testing.expectEqual(Cond.yes, got),
        }
    }
}

test "#1159: many template paths under one prefix walk the argument once, kept across reads" {
    const gpa = testing.allocator;
    var grew: [2]u64 = undefined;
    for ([_]u32{ 8, 64 }, 0..) |paths, run| {
        var x: KnotFixture = .{};
        try x.init();
        defer x.deinit();
        x.account.allowance = std.math.maxInt(u32) - 1;
        const src: Place.Source = .{ .ctx = &x.graph, .describe = TestGraph.describe };
        const W = try x.places.of(gpa, &x.account, src, 10);
        const LW = try x.places.of(gpa, &x.account, src, 11);
        const LI = try x.places.of(gpa, &x.account, src, 12);
        const e = Place.Step.elem;
        const w0 = try x.places.ctorStep(gpa, &x.account, 5, 0);
        // The argument: `W [W f₁…f₆₄] f₁…f₆₄`, every field list its own site.
        var inner_over: u32 = Ids.none_int;
        var outer_over: u32 = Ids.none_int;
        for (1..65) |i| {
            const f = try x.places.ctorStep(gpa, &x.account, 5, @intCast(i));
            inner_over = try x.shapes.overPut(gpa, &x.account, inner_over, f, try listAt(&x, LI, @intCast(100 + i), null));
            outer_over = try x.shapes.overPut(gpa, &x.account, outer_over, f, try listAt(&x, LI, @intCast(200 + i), null));
        }
        const inner = try x.shapes.node(gpa, &x.account, W, .none, inner_over);
        outer_over = try x.shapes.overPut(gpa, &x.account, outer_over, w0, try listAt(&x, LW, 300, inner));
        const arg = try x.shapes.node(gpa, &x.account, W, .none, outer_over);
        // A class relying on `excl π1·⟲·fₖ` for `paths` fields under one prefix.
        var xreq: CondId = Cond.yes;
        for (1..paths + 1) |i| {
            var p = try x.places.rootPath(gpa, W);
            for ([_]Step{ w0, e, try x.places.ctorStep(gpa, &x.account, 5, @intCast(i)) }) |s| p = (try x.places.extend(gpa, .growth(&x.account), p, s)).?;
            xreq = try x.conds.@"and"(gpa, x.env().charge, xreq, try x.conds.excl(gpa, x.env().charge, try x.cells.symbolic(gpa, &x.account, &x.places, .param, 0, p, 0)));
        }
        const c = try x.sums.add(x.env(), .{ .params = &.{.none}, .res = try x.site(90, x.t_place), .kappas = .none, .xreq = try x.conds.flat(gpa, x.env().charge, xreq) });
        var s: Scratch = .{};
        defer s.deinit(gpa);
        const walks = x.conds.classes_done.items.len;
        const before = x.account.growth;
        var snap_path: std.ArrayList(Step) = .empty;
        defer snap_path.deinit(gpa);
        var ak: Cond.Kappas = .none;
        try snapshotYes(&x, arg, &snap_path, &ak);
        const applied = try apply(x.env(), &x.sums, c, &.{.{ .node = arg, .kappa = ak }}, 0, &s);
        try testing.expect(!Cond.Table.fails(applied.xreq));
        // One walk of the argument for every path under the prefix.
        try testing.expectEqual(walks + 1, x.conds.classes_done.items.len);
        grew[run] = x.account.growth - before;
        // A second call reads the kept walk: no walk again.
        var s2: Scratch = .{};
        defer s2.deinit(gpa);
        _ = try apply(x.env(), &x.sums, c, &.{.{ .node = arg, .kappa = ak }}, 0, &s2);
        try testing.expectEqual(walks + 1, x.conds.classes_done.items.len);
    }
    // Eight times the paths: the walk once, each further path a read.
    // Measured 5,349 and 5,652 records: the walk (the 64-field record) once,
    // about five records for each further path (memo, inspection, cond),
    // never another walk, which would cost thousands. Before #1236 the path
    // re-entry walk charged the narrower run more and hid part of that.
    try testing.expect(grew[1] - grew[0] <= 6 * (64 - 8));
}

fn nextId(ids: *u32) u32 {
    ids.* += 1;
    return ids.*;
}

test "#1159: a cyclic source settles once, every occurrence below the cycle repeated; above it, once" {
    // `w = B [w] []` tied as a knot, inside `B [w] [B k []]`: the knot's `.0`
    // lists recur at every depth, so the key `⟲·.0` reads them repeated
    // (`lost`); `k`, at `.1[*]·.0` beside the cycle, occurs once.
    const gpa = testing.allocator;
    var x: KnotFixture = .{};
    try x.init();
    defer x.deinit();
    x.account.allowance = std.math.maxInt(u32) - 1;
    var ids: u32 = 40;
    const src: Place.Source = .{ .ctx = &x.graph, .describe = TestGraph.describe };
    const B = try x.places.of(gpa, &x.account, src, 8);
    const b0 = try x.places.ctorStep(gpa, &x.account, 4, 0);
    const b1 = try x.places.ctorStep(gpa, &x.account, 4, 1);
    const e = Place.Step.elem;
    const knot = try x.shapes.knot(gpa, &x.account);
    x.shapes.tie(knot, x.shapes.get(try bOf(&x, try bList(&x, 10, &.{knot}), try bList(&x, nextId(&ids), &.{}))));
    const k = try bList(&x, 1, &.{});
    const arg = try bOf(&x, try bList(&x, 4, &.{knot}), try bList(&x, 5, &.{try bOf(&x, k, try bList(&x, nextId(&ids), &.{}))}));
    const root = try x.places.rootPath(gpa, B);
    var q = root;
    for ([_]Step{ b0, e, b0 }) |s| q = (try x.places.extend(gpa, .growth(&x.account), q, s)).?;
    var r = root;
    for ([_]Step{ b1, e, b0 }) |s| r = (try x.places.extend(gpa, .growth(&x.account), r, s)).?;
    try testing.expect(q == r); // both depth-1 `.0` lists: one key, `⟲·.0`
    const pre = try preimage(x.env(), arg, root);
    try testing.expectEqual(Cond.lost, try x.conds.classesRead(gpa, x.env().charge, &x.cells, &x.places, pre, q.int()));
    // Above the cycle: the root's own `.1` list once.
    var top = root;
    top = (try x.places.extend(gpa, .growth(&x.account), top, b1)).?;
    try testing.expectEqual(Cond.yes, try x.conds.classesRead(gpa, x.env().charge, &x.cells, &x.places, pre, top.int()));
}

test "#1196 review, #1199: a symbolic leaf below the prefix — Repro A and Repro B refuse at the caller, distinct actuals accept" {
    // A callee relying on `excl π0·⟲·arg`. The middle frame passes it
    // `T [ p, T k ]` (Repro A) or `T [ p, q ]` (Repro B), `p` and `q` its own
    // parameters (a `T` each). The middle's reliance is its `xreq`: the
    // projections' `summaryExcl` and `apart` (#1199). A caller instantiates
    // it through `⟲` by the preimage: Repro A's `p ↦ T [ T k′, T [ T k′ ] ]`
    // holds `k′` at two depths; Repro B's `p` and `q` share one kids list.
    // Distinct lists accept.
    const gpa = testing.allocator;
    const e = Place.Step.elem;
    for (0..2) |repro| for ([_]bool{ true, false }) |shared_list| {
        var x: KnotFixture = .{};
        try x.init();
        defer x.deinit();
        x.account.allowance = std.math.maxInt(u32) - 1;
        const T = x.t_place;
        const p = try x.param(3);
        const second = if (repro == 0) try ctorOf(&x, T, x.arg, try listAt(&x, x.list, 1, null)) else try x.param(4);
        const middle_arg = try ctorOf(&x, T, x.arg, try listAt(&x, x.list, 2, try x.shapes.collect(gpa, &x.account, &x.cells.sets, &.{ p, second })));
        const middle = try foldProbe(&x, T, &.{ x.arg, e, x.arg }, middle_arg);
        try testing.expect(!Cond.Table.fails(middle));
        // The caller: a class owing the middle's reliance, applied to actuals.
        const c = try x.sums.add(x.env(), .{ .params = &.{ .none, .none, .none, .none, .none }, .res = try x.site(90, x.t_place), .kappas = .none, .xreq = try x.conds.flat(gpa, x.env().charge, middle) });
        const k = try listAt(&x, x.list, 20, null);
        const k2 = if (shared_list) k else try listAt(&x, x.list, 21, null);
        const actual_p, const actual_q = if (repro == 0) .{
            try ctorOf(&x, T, x.arg, try listAt(&x, x.list, 22, try x.shapes.collect(gpa, &x.account, &x.cells.sets, &.{ try ctorOf(&x, T, x.arg, k), try ctorOf(&x, T, x.arg, try listAt(&x, x.list, 23, try ctorOf(&x, T, x.arg, k2))) }))),
            try x.site(91, T),
        } else .{
            try ctorOf(&x, T, x.arg, try listAt(&x, x.list, 22, try ctorOf(&x, T, x.arg, k))),
            try ctorOf(&x, T, x.arg, try listAt(&x, x.list, 23, try ctorOf(&x, T, x.arg, k2))),
        };
        var args: [5]Value = undefined;
        for (&args, 0..) |*a, i| {
            const node = if (i == 3) actual_p else if (i == 4) actual_q else try x.site(@intCast(95 + i), T);
            var path: std.ArrayList(Step) = .empty;
            defer path.deinit(gpa);
            var ak: Cond.Kappas = .none;
            try snapshotYes(&x, node, &path, &ak);
            a.* = .{ .node = node, .kappa = ak };
        }
        var s: Scratch = .{};
        defer s.deinit(gpa);
        const applied = try apply(x.env(), &x.sums, c, &args, 0, &s);
        try testing.expectEqual(shared_list, Cond.Table.fails(applied.xreq));
    };
}

test "#1196 decision 1, #1199: a callee writing at `0·[*]·⟲·arg` while it answers `0·[*]·arg` rests on its sep, which the actual's preimage refutes" {
    // Probe 3 accepted `excl π0·0·[*]·⟲·arg` over `R2 [ T k, T [ T k ] ]`: the
    // first `k` is at `0·[*]·arg`, outside that path's preimage. A callee that
    // writes the deeper lists and reads, escapes or returns the shallow ones
    // relies on `sep(π0·0·[*]·⟲·arg, π0·0·[*]·arg)`. Instantiated, the deep
    // side's cells come from the preimage (never a recast's), so the shared `k`
    // refuses; distinct lists accept.
    const gpa = testing.allocator;
    const e = Place.Step.elem;
    for ([_]bool{ true, false }) |shared_list| {
        var x: KnotFixture = .{};
        try x.init();
        defer x.deinit();
        x.account.allowance = std.math.maxInt(u32) - 1;
        const src: Place.Source = .{ .ctx = &x.graph, .describe = TestGraph.describe };
        const T = x.t_place;
        const R2 = try x.places.of(gpa, &x.account, src, 6);
        const LT = try x.places.of(gpa, &x.account, src, 7);
        const r0 = try x.places.ctorStep(gpa, &x.account, 3, 0);
        var deep = try x.places.rootPath(gpa, R2);
        for ([_]Step{ r0, e, x.arg, e, x.arg }) |s| deep = (try x.places.extend(gpa, .growth(&x.account), deep, s)).?;
        var shallow = try x.places.rootPath(gpa, R2);
        for ([_]Step{ r0, e, x.arg }) |s| shallow = (try x.places.extend(gpa, .growth(&x.account), shallow, s)).?;
        try testing.expect(deep != shallow);
        const sep = try x.conds.sepAtom(gpa, x.env().charge, try x.cells.symbolic(gpa, &x.account, &x.places, .param, 0, deep, 0), try x.cells.symbolic(gpa, &x.account, &x.places, .param, 0, shallow, 0));
        const c = try x.sums.add(x.env(), .{ .params = &.{.none}, .res = try x.site(90, T), .kappas = .none, .xreq = try x.conds.flat(gpa, x.env().charge, sep) });
        const k = try listAt(&x, x.list, 1, null);
        const k2 = if (shared_list) k else try listAt(&x, x.list, 4, null);
        const t2 = try ctorOf(&x, T, x.arg, try listAt(&x, x.list, 2, try ctorOf(&x, T, x.arg, k2)));
        const arg = try ctorOf(&x, R2, r0, try listAt(&x, LT, 3, try x.shapes.collect(gpa, &x.account, &x.cells.sets, &.{ try ctorOf(&x, T, x.arg, k), t2 })));
        var path: std.ArrayList(Step) = .empty;
        defer path.deinit(gpa);
        var ak: Cond.Kappas = .none;
        try snapshotYes(&x, arg, &path, &ak);
        var s: Scratch = .{};
        defer s.deinit(gpa);
        const applied = try apply(x.env(), &x.sums, c, &.{.{ .node = arg, .kappa = ak }}, 0, &s);
        try testing.expectEqual(shared_list, Cond.Table.fails(applied.xreq));
    }
}

test "a call's argument that is a view folds its preimage as its eager image does" {
    // `Pre` and `unionSides` read a view as its answer at its path (§2.11):
    // `B xs xs` (k at `.0[*].0` and `.1[*].0`) refuses, `B xs []` accepts,
    // as their eager twins do.
    const gpa = testing.allocator;
    const e = Place.Step.elem;
    for (0..2) |probe| {
        var x: KnotFixture = .{};
        try x.init();
        defer x.deinit();
        x.account.allowance = std.math.maxInt(u32) - 1;
        const src: Place.Source = .{ .ctx = &x.graph, .describe = TestGraph.describe };
        const B = try x.places.of(gpa, &x.account, src, 8);
        const LB = try x.places.of(gpa, &x.account, src, 9);
        const b0 = try x.places.ctorStep(gpa, &x.account, 4, 0);
        const k = try bList(&x, 1, &.{});
        const xs = try bList(&x, 4, &.{try bOf(&x, k, try bList(&x, 5, &.{}))});
        const empty = try bList(&x, 6, &.{});
        const p = try x.shapes.leaf(gpa, &x.account, LB, try x.cells.sets.insert(gpa, .growth(&x.account), .none, (try x.cells.symbolic(gpa, &x.account, &x.places, .param, 3, try x.places.rootPath(gpa, LB), 0)).int(), 0));
        // The view's environment: parameter 3 is `xs`.
        const label = try x.cells.label(gpa, &x.account, 0, .none, false);
        const env_id = try x.views.add(x.env(), .from(0), &.{ .{}, .{}, .{}, .{ .node = xs } }, label);
        const template = try bOf(&x, p, if (probe == 0) p else empty);
        const eager = try bOf(&x, xs, if (probe == 0) xs else empty);
        const v = try x.shapes.view(gpa, &x.account, template, env_id);
        const steps = [_]Step{ b0, e, b0 };
        const want = try foldProbe(&x, B, &steps, eager);
        try testing.expectEqual(if (probe == 0) Cond.lost else Cond.yes, want);
        try testing.expectEqual(want, try foldProbe(&x, B, &steps, v));
    }
}
