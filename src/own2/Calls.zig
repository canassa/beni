//! L9: a call of a class (`docs/design/ownership-v2.md` §2.11). S3a applies
//! the classes the rows give (`Rows.fromWords`, built at the call's own
//! instantiation, so the class's places are the caller's); S3b adds the
//! summaries of declarations, S4 callbacks.
//!
//! `apply` answers what the call does, item by item:
//!
//! 1. **Uses** are the caller's (`Transfer` records each argument at the
//!    call, kind `call`, the class's use shape for that parameter).
//! 2. **W**: every path of a parameter's use shape marked `W` (deep with
//!    `S`) is a write the caller turns into a demand on the argument there,
//!    one per path of the use's pair graph with the argument (`Routes`).
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
//! A row's taken result is the element the call materialises out of the
//! actual, under a split the call makes (item 6, *A taken result*, #1393).
//! What a class names that S3a does not interpret — a callback's result, a
//! loan, `within`, `keep`, `writes` — instantiates to `⊤` or `lost`: sound,
//! and never a write the caller is not told of (O1, O10).
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
const Holders = @import("Holders.zig");
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
pub const Value = Holders.Value;
pub const Env = Summary.Env;
pub const Step = Shape.Step;
pub const Error = Ids.ChargeError;

pub const Applied = struct {
    result: Value,
    /// The instantiated `xreq`: `yes` when the class relies on nothing.
    xreq: CondId,
    /// The values the result lets escape (an `esc k`), deeply.
    escaped: []const NodeId,
};

/// One call's scratch, reused across calls of one walk.
pub const Scratch = struct {
    memo: stamped.Column(NodeId, NodeId) = .{},
    escaped: std.ArrayList(NodeId) = .empty,
    members: std.ArrayList(NodeId) = .empty,
    /// Rule 4's walk of a key's steps (`Grafter.groupOf`).
    steps: std.ArrayList(Step) = .empty,
    /// The place the caller reads the call's result at (its instruction's),
    /// or `.none`: a structured result template is instantiated there.
    result_place: PlaceId = .none,

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        s.steps.deinit(gpa);
        s.memo.deinit(gpa);
        s.escaped.deinit(gpa);
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
    /// `runtime_safety` only (§2.9 rule 3's check): every `(key, cell, state)`
    /// an expansion adds, when set.
    trace: ?*std.ArrayList(Arrival) = null,
    cur: u32 = 0,

    const Arrival = struct { key: PathId, cell: CellId, state: u32 };

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
        if (w.trace) |tr| try tr.append(gpa, .{ .key = key, .cell = c, .state = w.cur });
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
            .elem, .others, .level, .below, .loan, .part => sym = (try cells.unrefined(gpa, account, places, c)) orelse return,
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
        w.cur = id;
        const d = shapes.get(st.node);
        w.own.clearRetainingCapacity();
        w.own_at.deinit(gpa);
        w.own_at = .{};
        const first: u32 = @intCast(w.parts.items.len);
        var max = false;
        var cert: Cond.Table.ClassAggs = .{};
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
            // A view is its answer at the same path: one part (§2.11). A view
            // of a certified class is its certificate (reader 2, #1485): each
            // class of its template at each canonical path below, its keys by
            // §2.9 rule 4, never its cycle.
            .view => if (w.env.conds.hypEnv(w.env.view(), st.node)) |e| {
                cert = try w.certView(st, e);
            } else try w.part(try shapes.force(gpa, w.env.account(), st.node), st.path, st.below),
            .choice, .positions => {
                max = d.kind == .choice;
                try w.part(.from(d.a), st.path, st.below);
                try w.part(.from(d.b), st.path, st.below);
            },
        }
        var own: Cond.Table.ClassAggs = cert;
        for (w.own.items) |o| own = try w.env.conds.classesMerge(gpa, charge, w.env.view(), own, try w.env.conds.classesOf(gpa, charge, w.env.cells, w.env.places, o.key, o.cells), true);
        const s = &w.states.items[id];
        s.own = own;
        s.max = max;
        s.parts = .{ .start = first, .len = @as(u32, @intCast(w.parts.items.len)) - first };
    }

    /// An entry of `certView`'s walk: a class of the template, its path, and
    /// its position in the class's snapshot (`Cond.Table.ClassPos`).
    const CertEntry = struct { tn: u32, path: u32, pos: Cond.Table.ClassPos };

    /// Reader 2 (§8 slice 4, #1485): the certificate of a view `st.node` of a
    /// certified class at environment `e`, below `st.path`. Each class of
    /// its template meets each canonical path the walk of its steps reaches
    /// (a pair `(class, path)` once, so a `⟲` folds onto the path it
    /// returns to), and gives there its keys' multiset by rule 4. The
    /// classes that meet at one path are read together, one multiset of
    /// their keys (§2.9 rule 4, *Across the classes of one certificate*,
    /// #1559); distinct paths add, as distinct positions of one result.
    fn certView(w: *Pre, st: State, e: u32) Error!Cond.Table.ClassAggs {
        const gpa = w.env.gpa;
        const charge = w.env.charge;
        const shapes = w.env.shapes;
        const conds = w.env.conds;
        var seen: Ids.FixedDict(2) = .{};
        defer seen.deinit(gpa);
        var stack: std.ArrayList(CertEntry) = .empty;
        defer stack.deinit(gpa);
        var items: std.ArrayList(Cond.Table.CertItem) = .empty;
        defer items.deinit(gpa);
        var keys: std.ArrayList(Cond.Table.HypKey) = .empty;
        defer keys.deinit(gpa);
        try stack.append(gpa, .{ .tn = shapes.get(st.node).a, .path = st.path.int(), .pos = conds.classPos(w.env.view(), e) });
        while (stack.pop()) |x| {
            try charge.reserve(gpa, .inspection, 1);
            if ((try seen.getOrPut(gpa, .{ x.tn, x.path })).found_existing) continue;
            const tn: NodeId = .from(x.tn);
            const path: PathId = .from(x.path);
            if (!st.below or path != st.path) {
                // The certificate's condition at the class, its κ (#1485).
                const cond = if (!mutated("cert-keys-only-reader2")) try conds.classCond(gpa, charge, w.env.view(), x.pos, tn, e) else Cond.yes;
                if (w.trace) |tr| {
                    keys.clearRetainingCapacity();
                    try conds.classKeys(gpa, charge, w.env.view(), e, tn, &keys);
                    for (keys.items) |k| try tr.append(gpa, .{ .key = path, .cell = k.image, .state = w.cur });
                }
                try items.append(gpa, .{ .at = path.int(), .tn = tn, .cond = cond });
            }
            try w.certKids(tn, path, x.pos, &stack);
        }
        return conds.certClassesAggs(gpa, charge, w.env.view(), e, items.items);
    }

    /// `certView`'s children of class `tn` at `path`: a join's sides at the
    /// path, a node's or delta's entries one step below.
    fn certKids(w: *Pre, tn: NodeId, path: PathId, pos: Cond.Table.ClassPos, stack: *std.ArrayList(CertEntry)) Error!void {
        const shapes = w.env.shapes;
        const d = shapes.get(tn);
        switch (d.kind) {
            .@"union", .choice, .positions => {
                try w.certKids(.from(d.a), path, pos, stack);
                try w.certKids(.from(d.b), path, pos, stack);
            },
            .node, .delta => {
                if (d.kind == .delta) try w.certKids(.from(d.a), path, pos, stack);
                var it = shapes.overEntries(if (d.kind == .node) d.a else d.b);
                while (it.next()) |c| {
                    const cp = (try w.env.places.extend(w.env.gpa, w.env.charge, path, c.step)) orelse continue;
                    try stack.append(w.env.gpa, .{ .tn = c.node.int(), .path = cp.int(), .pos = try w.env.conds.classStep(w.env.gpa, w.env.charge, w.env.view(), pos, c.step) });
                }
            },
            else => {},
        }
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
        // From the node table's pool, as every walk over it (#1191, #1560).
        const seen = try shapes.marks.take(gpa);
        defer shapes.marks.give(seen);
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
    /// `foldedArg` by `(argument, template path)`; the deep read at the
    /// prefix, and the argument there, by `(argument, prefix)` (#1159).
    folded: Ids.FixedDict(2) = .{},
    deeps: Ids.FixedDict(2) = .{},
    prefix_args: Ids.FixedDict(2) = .{},
    /// The environment of the call's view, and at an identity class its
    /// root and the actual it answers (`relabelNode`).
    view_env: u32 = Ids.none_int,
    root: NodeId = .none,
    answer: NodeId = .none,

    fn deinit(g: *Grafter) void {
        g.folded.deinit(g.env.gpa);
        g.deeps.deinit(g.env.gpa);
        g.prefix_args.deinit(g.env.gpa);
    }

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
    /// the value as it stands: some value inside the node, a recast that
    /// keeps the whole inner, whose cells are its reach, approximately
    /// (`Shape.recastWhole`, §2.13.9, #1219). A node at another place is the
    /// same value there: a place-only recast, its cells exact.
    fn argAt(g: *Grafter, i: u32, p: PathId, at: PlaceId) Error!NodeId {
        if (i >= g.args.len or g.args[i].node == .none) return g.topLeaf(at);
        var steps: std.ArrayList(Step) = .empty;
        defer steps.deinit(g.gpa());
        try g.stepsOf(p, &steps);
        var n = g.args[i].node;
        for (steps.items) |s| {
            if (s.kind == .level and !try g.symbolicLeaf(n)) return g.env.shapes.recastWhole(g.gpa(), g.account(), &g.env.cells.sets, at, n);
            n = (try g.env.shapes.proj(g.gpa(), g.account(), g.env.places, g.env.cells, n, s)) orelse return g.topLeaf(at);
        }
        // At a type variable's place the call instantiates the variable to
        // the actual's type: the actual stands at its own place (#1350).
        if (g.env.places.kind(at) != .@"var" and g.env.shapes.place(n) != at) return g.env.shapes.recast(g.gpa(), g.account(), at, n);
        return n;
    }

    /// §2.9 rule 4 for one arrival key `c` of a certificate at this call
    /// (#1485): a parameter key whose walk along the actual meets one
    /// position's node (rule 3's (b), at the parameter's place, at an exact
    /// prefix `L`) is in the group `(πᵢ, L, node)`, and its images are the
    /// symbolic projections of the node's member cells along the key's rest,
    /// canonical, a `⟲` included and never expanded. Any other key adds its
    /// images as the graft reads them (`cellsOf`). Group ids are `groups`'
    /// values, one per `(env, i, L, node)` for the call's environment `env`,
    /// whatever class of the certificate the key is in (#1559).
    fn ruleFourKey(g: *Grafter, c: CellId, approx: bool, env: u32, groups: *Ids.FixedDict(4), out: *std.ArrayList(Cond.Table.HypKey)) Error!void {
        const cells = g.env.cells;
        const x = cells.get(c);
        if (x.origin == .param and !approx) {
            const first = out.items.len;
            if (try g.groupOf(x.a, .from(x.b))) |grp| {
                const got = try groups.getOrPut(g.gpa(), .{ env, x.a, grp.prefix.int(), grp.node.int() });
                if (!got.found_existing) got.value_ptr.* = groups.count() - 1;
                if (try g.groupImages(c, grp, got.value_ptr.*, out)) {
                    // The mutation adds a group's images, as by cell (#1485).
                    if (mutated("cert-rule4-sum")) for (out.items[first..]) |*k| {
                        k.group = Ids.none_int;
                    };
                    return;
                }
                out.shrinkRetainingCapacity(first);
            }
        }
        var it = cells.sets.iterate(try g.cellsOf(c, g.placeOfCell(c)));
        while (it.next()) |e| {
            try g.env.charge.reserve(g.gpa(), .inspection, 1);
            try out.append(g.gpa(), .{ .key = c, .image = .from(e.key), .approx = approx or e.value == 1, .group = Ids.none_int });
        }
    }

    const Group = struct { node: NodeId, prefix: PathId, rest: []const Step };

    /// Rule 4 over an atom's sides (#1485): an image that an earlier side of
    /// the same group holds, met again, is one more position of it. It owes
    /// `exclOf` and stays on the first side only. Sides of other groups, and
    /// sides in no group, keep their images, which the multiset then reads.
    fn ruleFourSides(g: *Grafter, t: *Cond.Table, callee: []const CellId, gids: []const u32, sides: []SetId) Error!CondId {
        const cells = g.env.cells;
        // (a′) first, in every build: a group whose keys overlap is no group,
        // and all its sides keep their images, which the multiset then reads
        // as repeats (`Cell.keysOverlap`, memoised by the key set).
        var group_keys: Ids.FixedDict(1) = .{};
        defer group_keys.deinit(g.gpa());
        for (callee, gids) |c, gid| if (gid != Ids.none_int) {
            const got = try group_keys.getOrPut(g.gpa(), .{gid});
            if (!got.found_existing) got.value_ptr.* = SetId.none.int();
            got.value_ptr.* = (try cells.sets.insert(g.gpa(), g.env.charge, .from(got.value_ptr.*), c.int(), 0)).int();
        };
        for (group_keys.values.items) |*s| s.* = @intFromBool(try cells.keysOverlap(g.gpa(), g.env.charge, g.env.places, .from(s.*)));
        var first: Ids.FixedDict(2) = .{};
        defer first.deinit(g.gpa());
        var extra: CondId = Cond.yes;
        for (sides, gids, 0..) |*side, gid, j| {
            if (gid == Ids.none_int or group_keys.get(.{gid}).? == 1) continue;
            var kept: SetId = .none;
            var it = cells.sets.iterate(side.*);
            while (it.next()) |e| {
                try g.env.charge.reserve(g.gpa(), .inspection, 1);
                const got = try first.getOrPut(g.gpa(), .{ gid, e.key });
                if (!got.found_existing) got.value_ptr.* = @intCast(j);
                // Another side of the group at the image: one more position
                // of it, since the group's keys are alias-apart.
                if (got.value_ptr.* != j and callee[got.value_ptr.*] != callee[j]) {
                    extra = try t.@"and"(g.gpa(), g.env.charge, extra, try t.exclOf(g.gpa(), g.env.charge, cells, .from(e.key)));
                    continue;
                }
                kept = try cells.sets.insert(g.gpa(), g.env.charge, kept, e.key, e.value);
            }
            side.* = kept;
        }
        return extra;
    }

    /// Rule 4's group of a key of argument `i` at path `p`: walking the actual
    /// along `p` (views forced, built nodes and deltas projected one step at a
    /// time), the first node that is not built, met before any `[*]` or `⟲`,
    /// standing at the parameter's place there, and one position's possible
    /// contents (`onePosition`). Null for none. `rest` lives in `g.s`.
    fn groupOf(g: *Grafter, i: u32, p: PathId) Error!?Group {
        const shapes = g.env.shapes;
        const places = g.env.places;
        if (i >= g.args.len or g.args[i].node == .none) return null;
        g.s.steps.clearRetainingCapacity();
        try g.stepsOf(p, &g.s.steps);
        const steps = g.s.steps.items;
        var pfx = p;
        while (places.pathParent(pfx) != .none) pfx = places.pathParent(pfx);
        var n = g.args[i].node;
        var k: usize = 0;
        while (true) : (k += 1) {
            try g.env.charge.reserve(g.gpa(), .inspection, 1);
            n = try shapes.force(g.gpa(), g.account(), n);
            switch (shapes.kind(n)) {
                .leaf, .@"union", .choice => {
                    if (shapes.place(n) != places.pathPlace(pfx) or !try g.onePosition(n)) return null;
                    return .{ .node = n, .prefix = pfx, .rest = steps[k..] };
                },
                .node, .delta => {
                    if (k == steps.len) return null;
                    const s = steps[k];
                    if (s.kind == .elem or s.kind == .level) return null;
                    n = (try shapes.proj(g.gpa(), g.account(), places, g.env.cells, n, s)) orelse return null;
                    pfx = (try places.extend(g.gpa(), g.env.charge, pfx, s)) orelse return null;
                },
                else => return null,
            }
        }
    }

    /// The images of key `c` in its group: each member cell of the group's
    /// node, canonical, extended along the rest by `Place.extend`. False
    /// when a member has no canonical cell or a step no path: the key then
    /// adds as before.
    fn groupImages(g: *Grafter, c: CellId, grp: Group, id: u32, out: *std.ArrayList(Cond.Table.HypKey)) Error!bool {
        const shapes = g.env.shapes;
        const cells = g.env.cells;
        const places = g.env.places;
        var stack: std.ArrayList(NodeId) = .empty;
        defer stack.deinit(g.gpa());
        const seen = try shapes.marks.take(g.gpa());
        defer shapes.marks.give(seen);
        try stack.append(g.gpa(), grp.node);
        while (stack.pop()) |m0| {
            const m = try shapes.force(g.gpa(), g.account(), m0);
            if (seen.contains(m)) continue;
            try seen.put(g.gpa(), m, {});
            const d = shapes.get(m);
            switch (d.kind) {
                .@"union", .choice => try stack.appendSlice(g.gpa(), &.{ .from(d.a), .from(d.b) }),
                .leaf => {
                    var it = cells.sets.iterate(d.cells);
                    while (it.next()) |e| {
                        try g.env.charge.reserve(g.gpa(), .inspection, 1);
                        const cell: CellId = .from(e.key);
                        const o = cells.origin(cell);
                        if (o == .top or o == .mark) return false;
                        const sym = if (o.isRefinement()) (try cells.unrefined(g.gpa(), g.account(), places, cell)) orelse return false else cell;
                        const sd = cells.get(sym);
                        if (!sd.origin.isSymbolic() or sd.origin == .top) return false;
                        var path: PathId = .from(sd.b);
                        for (grp.rest) |s| path = (try places.extend(g.gpa(), g.env.charge, path, s)) orelse return false;
                        const img = try cells.symbolic(g.gpa(), g.account(), places, sd.origin, sd.a, path, sd.c);
                        try out.append(g.gpa(), .{ .key = c, .image = img, .approx = false, .group = id });
                    }
                },
                else => return false,
            }
        }
        return true;
    }

    /// A leaf of exact symbolic or refined cells, none `⊤` and none under a
    /// repeating split: it stands for exactly its cells' projections (§2.2),
    /// so `argAt` projects it through `⟲` symbolically, never by its whole
    /// reach (§2.9 rule 4's read, #1485).
    fn symbolicLeaf(g: *Grafter, n0: NodeId) Error!bool {
        const shapes = g.env.shapes;
        const n = try shapes.force(g.gpa(), g.account(), n0);
        if (shapes.kind(n) != .leaf) return false;
        const cells = g.env.cells;
        var it = cells.sets.iterate(shapes.cells(n));
        var any = false;
        while (it.next()) |e| {
            if (e.value == 1) return false;
            const o = cells.origin(.from(e.key));
            if (o == .top or !(o.isSymbolic() or o.isRefinement())) return false;
            if (Cond.Table.repeatingSplit(cells, .from(e.key)) != null) return false;
            any = true;
        }
        return any;
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

    /// `argAt` at a `⟲`'s prefix, once per `(argument, prefix)`.
    fn prefixArg(g: *Grafter, i: u32, prefix: PathId) Error!NodeId {
        try g.env.charge.reserve(g.gpa(), .memo, 1);
        if (g.prefix_args.get(.{ i, prefix.int() })) |hit| return .from(hit);
        const n = try g.argAt(i, prefix, g.env.places.pathPlace(prefix));
        (try g.prefix_args.getOrPut(g.gpa(), .{ i, prefix.int() })).value_ptr.* = n.int();
        return n;
    }

    fn foldedArgOnce(g: *Grafter, i: u32, p: PathId, prefix: PathId) Error!CondId {
        const n = try g.prefixArg(i, prefix);
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

    /// A row's taken result `elem(πᵢ·q·ρ)` (§2.13.6) at this call, null for
    /// any other cell: materialised out of the actual as a list pattern does
    /// (§2.13.3, `TransferPattern.bindList`), `elem(c·ι)` per symbolic container
    /// cell `c` under the split this call makes, κ the contents' at `q[*]`,
    /// joined with the other contents' node there, whole, so what a
    /// literal's element or a stored value holds below it is kept (§2.11
    /// item 6, #1393).
    fn takenImage(g: *Grafter, c: CellId) Error!?NodeId {
        const cells = g.env.cells;
        const shapes = g.env.shapes;
        const x = cells.get(c);
        if (x.origin != .elem or LabelId.from(x.b) != .none or g.label == .none) return null;
        const px = cells.get(.from(x.a));
        if (px.origin != .param) return null;
        const gpa_ = g.gpa();
        const places = g.env.places;
        const list_at = g.placeOfCell(.from(x.a));
        const at = places.child(list_at, Step.elem) orelse return null;
        const path = (try places.extend(gpa_, g.env.charge, .from(px.b), Step.elem)) orelse return null;
        const contents = try g.argAt(px.a, path, at);
        const kappa = try g.env.conds.kappaOf(gpa_, g.env.charge, g.env.view(), try g.argKappa(px.a, path), contents, true);
        var refined: SetId = .none;
        var projections: SetId = .none;
        var it = cells.sets.iterate(try shapes.cellsOf(gpa_, g.account(), &cells.sets, try g.argAt(px.a, .from(px.b), list_at)));
        while (it.next()) |e| {
            try g.env.charge.reserve(gpa_, .inspection, 1);
            const k: CellId = .from(e.key);
            if (!cells.origin(k).isSymbolic() and !cells.origin(k).isRefinement() or cells.origin(k) == .top) continue;
            _ = try cells.split(gpa_, g.account(), k, cells.labelInst(g.label), g.label, kappa);
            const r = try cells.refine(gpa_, g.account(), .elem, k, g.label, 0, at, Cell.Kind.ofPlace(places.kind(at)));
            refined = try cells.sets.insert(gpa_, g.env.charge, refined, r.int(), e.value);
            if (try cells.unrefined(gpa_, g.account(), places, r)) |u| projections = try cells.sets.insert(gpa_, g.env.charge, projections, u.int(), 0);
        }
        // The contents without the containers' own projections, which the
        // refinements stand for: one position's value, node and all.
        var drop: SetId = .none;
        if (projections != .none) {
            var ct = cells.sets.iterate(try shapes.cellsOf(gpa_, g.account(), &cells.sets, contents));
            while (ct.next()) |e| {
                try g.env.charge.reserve(gpa_, .inspection, 1);
                const u = (try cells.unrefined(gpa_, g.account(), places, .from(e.key))) orelse continue;
                if (cells.sets.member(projections, u.int())) drop = try cells.sets.insert(gpa_, g.env.charge, drop, e.key, 0);
            }
        }
        const explicit = try shapes.without(gpa_, g.account(), &cells.sets, contents, drop, true);
        const node = try shapes.leaf(gpa_, g.account(), at, refined);
        if (explicit == .none) return node;
        if (refined == .none) return explicit;
        var two = [_]NodeId{ node, explicit };
        return try shapes.join(gpa_, g.account(), places, cells, &two);
    }

    /// `takenImage`'s cells at `ε` for a reader of a set (a view node's own
    /// cells, an atom's side): a built value below them is `⊤` there,
    /// approximately, since a set cannot hold it (#1393).
    fn takenCells(g: *Grafter, n: NodeId) Error!SetId {
        const sets = &g.env.cells.sets;
        const s = try g.env.shapes.cellsOf(g.gpa(), g.account(), sets, n);
        if (g.env.shapes.kind(n) == .leaf) return s;
        return sets.insert(g.gpa(), g.env.charge, s, (try g.env.cells.top(g.gpa(), g.account())).int(), 1);
    }

    /// `c`, no parameter's, mapped into `into`: a taken element's cells
    /// (`takenCells`), any other cell by `mapCell`.
    fn mapInto(g: *Grafter, into: SetId, c: CellId, approx: u1) Error!SetId {
        if (try g.takenImage(c)) |t| return g.env.cells.sets.unionWith(g.gpa(), g.env.charge, into, try g.takenCells(t));
        return g.env.cells.sets.insert(g.gpa(), g.env.charge, into, (try g.mapCell(c)).int(), approx);
    }

    /// A class cell that is not a parameter's, as the caller sees it: the
    /// class's own fresh cell made at this call, an escaping one too, `⊤`
    /// and `shared` as they are; what S3a does not interpret is `⊤`.
    /// One object, one cell (§2.2): `result ι·k` is made at the class cell's
    /// own place, never at the reader's. So a view's own cells and its reach
    /// (`reachImage`, which has no view in hand) name one cell where the call
    /// stands the view at another place, a generic callee's (#1350, #1516).
    fn mapCell(g: *Grafter, c: CellId) Error!CellId {
        const x = g.env.cells.get(c);
        return switch (x.origin) {
            .result, .esc => g.env.cells.result(g.gpa(), g.account(), x.origin, g.label, x.b, x.place, Cell.Kind.ofPlace(g.env.places.kind(x.place))),
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

    /// A class condition at this call: the atom `inst(k, E)`, resolved only
    /// when a reader tests it (§2.11 *κ across a call*, part 3).
    fn instantiated(ctx: *anyopaque, t: *Cond.Table, gpa_: Allocator, charge: Ids.Charge, k: CondId) Error!CondId {
        const g: *Grafter = @ptrCast(@alignCast(ctx));
        return t.instAtom(gpa_, charge, k, g.view_env);
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

    /// The cells argument `i` holds at a parameter cell's path `p`, read at
    /// `at`: through `⟲` the full preimage's (`foldedCells`, #1199);
    /// otherwise the argument's there. Below a level that is a whole recast
    /// (`argAt`), whose cells are its inner's reach, approximately, and a
    /// delta, union, choice or positions node over one reads them (#1219).
    fn argCells(g: *Grafter, i: u32, p: PathId, at: PlaceId) Error!SetId {
        if (try g.foldedCells(i, p)) |s| return s;
        return g.env.shapes.cellsOf(g.gpa(), g.account(), &g.env.cells.sets, try g.argAt(i, p, at));
    }

    /// The image of `res` cells at `at`: a parameter cell the argument's
    /// cells there, any other its mapped self (a view's node image, with
    /// no escape recorded: the parts that hold the cells record theirs).
    fn imageCells(g: *Grafter, cells: SetId, at: PlaceId) Error!SetId {
        var c: SetId = .none;
        var it = g.env.cells.sets.iterate(cells);
        while (it.next()) |e| {
            const cell: CellId = .from(e.key);
            if (g.env.cells.origin(cell) == .param) {
                const x = g.env.cells.get(cell);
                c = try g.env.cells.sets.unionWith(g.gpa(), g.env.charge, c, try g.argCells(x.a, .from(x.b), at));
                continue;
            }
            c = try g.mapInto(c, cell, e.value);
        }
        return c;
    }

    /// A template leaf's parts as the eager graft joined them (§2.11, the
    /// view's eager image, `Shape.Table.eager`): the actual at each parameter
    /// cell, marked where the cell is approximate (its recast), then the other
    /// cells mapped into one leaf, which is there when nothing else is.
    fn eagerParts(g: *Grafter, at: PlaceId, cells: SetId, out: *std.ArrayList(Shape.Table.LeafPart)) Error!void {
        const first = out.items.len;
        var rest: SetId = .none;
        var it = g.env.cells.sets.iterate(cells);
        while (it.next()) |e| {
            try g.env.charge.reserve(g.gpa(), .inspection, 1);
            const cell: CellId = .from(e.key);
            if (g.env.cells.origin(cell) == .param) {
                const x = g.env.cells.get(cell);
                try out.append(g.gpa(), .{ .node = try g.argAt(x.a, .from(x.b), at), .approx = e.value == 1 });
                continue;
            }
            if (try g.takenImage(cell)) |t| {
                try out.append(g.gpa(), .{ .node = t, .approx = e.value == 1 });
                continue;
            }
            rest = try g.env.cells.sets.insert(g.gpa(), g.env.charge, rest, (try g.mapCell(cell)).int(), e.value);
        }
        if (rest != .none or out.items.len == first) try out.append(g.gpa(), .{ .node = try g.env.shapes.leaf(g.gpa(), g.account(), at, rest), .approx = false });
    }

    /// A view's leaf image (§2.11): a re-root template (one exact parameter
    /// cell) answers the actual there (`argAt`); otherwise each parameter
    /// part is a re-root view over an interned one-cell leaf (a recast when
    /// approximate), so that every re-rooted actual is reached through one
    /// (*κ across a call*), the other cells mapped into one leaf, the parts
    /// joined raw. Escapes are `apply`'s, made once per call from the class.
    fn viewLeaf(g: *Grafter, members: *std.ArrayList(NodeId), template_at: PlaceId, cells: SetId) Error!NodeId {
        if (rerootCell(g.env.cells, cells)) |cell| {
            const x = g.env.cells.get(cell);
            return g.argAt(x.a, .from(x.b), template_at);
        }
        const at = try g.instantiatedPlace(template_at, cells);
        const first = members.items.len;
        defer members.shrinkRetainingCapacity(first);
        var rest: SetId = .none;
        var it = g.env.cells.sets.iterate(cells);
        while (it.next()) |e| {
            try g.env.charge.reserve(g.gpa(), .inspection, 1);
            const cell: CellId = .from(e.key);
            if (g.env.cells.origin(cell) == .param) {
                // An approximate part is the actual's recast, read through its
                // inner, as the eager image was: one value with the recasts of the
                // same actual elsewhere, so a join absorbs it.
                if (e.value == 1) {
                    const x = g.env.cells.get(cell);
                    try members.append(g.gpa(), try g.env.shapes.recast(g.gpa(), g.account(), at, try g.argAt(x.a, .from(x.b), at)));
                    continue;
                }
                const one = try g.env.shapes.leaf(g.gpa(), g.account(), at, try g.env.cells.sets.insert(g.gpa(), g.env.charge, .none, cell.int(), 0));
                try members.append(g.gpa(), try g.env.shapes.view(g.gpa(), g.account(), one, g.view_env));
                continue;
            }
            // A taken element is a value of its own, its node whole.
            if (try g.takenImage(cell)) |t| {
                try members.append(g.gpa(), if (e.value == 1) try g.env.shapes.recast(g.gpa(), g.account(), at, t) else t);
                continue;
            }
            rest = try g.env.cells.sets.insert(g.gpa(), g.env.charge, rest, (try g.mapCell(cell)).int(), e.value);
        }
        if (rest != .none or members.items.len == first) try members.append(g.gpa(), try g.env.shapes.leaf(g.gpa(), g.account(), at, rest));
        return g.env.shapes.joinRaw(g.gpa(), g.account(), at, members.items[first..]);
    }

    /// The place `argAt(i, p, at)` answers at, read off the place graph
    /// alone: no node is made or projected, so a view's place costs its
    /// template's cells and nothing of the actual (`placeImage`).
    fn argPlace(g: *Grafter, i: u32, p: PathId, at: PlaceId) Error!PlaceId {
        if (i >= g.args.len or g.args[i].node == .none) return at;
        var steps: std.ArrayList(Step) = .empty;
        defer steps.deinit(g.gpa());
        try g.stepsOf(p, &steps);
        var q = g.env.shapes.place(g.args[i].node);
        for (steps.items) |s| {
            if (s.kind == .level) return at;
            q = g.env.places.child(q, s) orelse return at;
        }
        return if (g.env.places.kind(at) == .@"var") q else at;
    }

    /// The place a template leaf at `at` stands at under this call. At a
    /// type variable's place whose cells are all parameter cells, the
    /// exact ones' actuals at one place, the call instantiates the
    /// variable to that place (`argAt`, #1350): `choose b l r = if b then l
    /// else r` answers its actuals' record, whose fields are steps. Any
    /// other leaf stays at `at`. Read off the place graph (`argPlace`), so
    /// a view is made at its answer's place before it is forced.
    fn instantiatedPlace(g: *Grafter, at: PlaceId, cells: SetId) Error!PlaceId {
        if (g.env.places.kind(at) != .@"var") return at;
        var got: PlaceId = .none;
        var it = g.env.cells.sets.iterate(cells);
        while (it.next()) |e| {
            try g.env.charge.reserve(g.gpa(), .inspection, 1);
            const cell: CellId = .from(e.key);
            if (g.env.cells.origin(cell) != .param) return at;
            if (e.value == 1) continue;
            const x = g.env.cells.get(cell);
            const p = try g.argPlace(x.a, .from(x.b), at);
            if (got != .none and got != p) return at;
            got = p;
        }
        return if (got == .none) at else got;
    }

    /// The cells a class cell stands for at this call: a parameter's, the
    /// argument's at that path; anything else its mapped self.
    fn cellsOf(g: *Grafter, c: CellId, at: PlaceId) Error!SetId {
        const x = g.env.cells.get(c);
        if (x.origin == .param) {
            // Through `⟲` the full preimage's, a whole recast's approximately
            // (`argCells`, #1199, #1219).
            return g.argCells(x.a, .from(x.b), at);
        }
        if (try g.takenImage(c)) |t| return g.takenCells(t);
        if (x.origin.isSymbolic() and x.origin != .top) return g.env.cells.sets.insert(g.gpa(), g.env.charge, .none, (try g.env.cells.top(g.gpa(), g.account())).int(), 1);
        return g.env.cells.sets.insert(g.gpa(), g.env.charge, .none, (try g.mapCell(c)).int(), 0);
    }

    /// The cells at every position of argument `i` that a template path `p`
    /// through `⟲` stands for (the preimage's occurrences at `p`), null for a
    /// path that does not cross `⟲`.
    /// A `sep` or `apart` side's cells at this call (`cellsOf`). An actual
    /// at a place that holds no object of its own (a constructor, a tuple)
    /// has its objects below it, so the side is its reach: `List.push [ b ] b`
    /// with `b = Box [ 0 ]` stores one box twice, and the repeat is its
    /// list at `#Box.0`, not a cell at `[*]` (#1386).
    fn sideCells(g: *Grafter, c: CellId) Error!SetId {
        const x = g.env.cells.get(c);
        const at = g.placeOfCell(c);
        if (x.origin != .param) return g.cellsOf(c, at);
        // Through `⟲` the side is the fold's preimage (`argCells`).
        var p: PathId = .from(x.b);
        while (p != .none and g.env.places.pathParent(p) != .none) : (p = g.env.places.pathParent(p)) {
            if (g.env.places.pathStep(p).kind == .level) return g.cellsOf(c, at);
        }
        const n = try g.argAt(x.a, .from(x.b), at);
        if (Cell.Kind.ofPlace(g.env.places.kind(g.env.shapes.place(n))) != .none) return g.cellsOf(c, at);
        return g.env.shapes.reach(g.gpa(), g.account(), &g.env.cells.sets, n);
    }

    /// §2.9 *Two positions of one image*, rule 3: a callee's `apart`/`sep`
    /// over cells `πᵢ·P₁ … πᵢ·Pₖ` of one parameter, each through `⟲`, whose
    /// images share cells. A shared cell `X` is several positions of `X`
    /// when (a) the paths end in pairwise different named steps, so no
    /// route is in two of them; (b) the actual is one position at their
    /// common prefix, cut before the first `⟲` (`onePositionAlong`), so its
    /// positions below are its cells', route for route. Each shared `X`
    /// then stays on the first side that holds it and owes what `shareImages`
    /// says, so no pair across sides is lost. Returns what the sides owe beyond their
    /// multiset, `yes` with the sides unchanged when the rule does not
    /// apply. Linear in the sides' cells.
    fn positionsThroughLevels(g: *Grafter, t: *Cond.Table, callee: []const CellId, sides: []SetId) Error!CondId {
        const cells = g.env.cells;
        const places = g.env.places;
        const gpa_ = g.gpa();
        if (callee.len < 2 or callee.len != sides.len) return Cond.yes;
        const i = cells.get(callee[0]).a;
        // (a) Apart by route: named last steps, pairwise different.
        var lasts: Ids.FixedDict(1) = .{};
        defer lasts.deinit(gpa_);
        for (callee) |c| {
            try g.env.charge.reserve(gpa_, .inspection, 1);
            const x = cells.get(c);
            if (x.origin != .param or x.a != i) return Cond.yes;
            const p: PathId = .from(x.b);
            if (firstLevel(places, p) == .none) return Cond.yes;
            const s = places.pathStep(p);
            if (!mutated("rule3-route") and !namedStep(s)) return Cond.yes;
            const got = try lasts.getOrPut(gpa_, .{@as(u32, @bitCast(s))});
            if (got.found_existing and !mutated("rule3-route")) return Cond.yes;
            got.value_ptr.* = 0;
        }
        // (b) One position at the common prefix.
        var common: std.ArrayList(Place.Step) = .empty;
        defer common.deinit(gpa_);
        try g.stepsOf(.from(cells.get(callee[0]).b), &common);
        for (common.items, 0..) |s, k| if (s.kind == .level) {
            common.shrinkRetainingCapacity(k);
            break;
        };
        var other: std.ArrayList(Place.Step) = .empty;
        defer other.deinit(gpa_);
        for (callee[1..]) |c| {
            other.clearRetainingCapacity();
            try g.stepsOf(.from(cells.get(c).b), &other);
            var k: usize = 0;
            while (k < common.items.len and k < other.items.len and @as(u32, @bitCast(common.items[k])) == @as(u32, @bitCast(other.items[k]))) k += 1;
            common.shrinkRetainingCapacity(k);
        }
        if (!mutated("rule3-one-position") and !try g.onePositionAlong(i, common.items)) return Cond.yes;
        const got = try shareImages(t, gpa_, g.env.charge, cells, places, sides);
        if (got.shared == .none) return Cond.yes;
        if (std.debug.runtime_safety) try g.assertOnePosition(i, callee, got.shared);
        return got.extra;
    }

    /// Rule 3's check by a reader that shares none of its walk (Lemma R3):
    /// the call's preimage of the whole actual, traced. Every source state
    /// that brings a shared image to one of the callee's paths stands at one
    /// path with no summary step, the same for all of them: one position of
    /// the actual, whose possible contents they are. Two positions of one
    /// object, or two elements of a list, would show as two paths or as a
    /// summary path, whether they land at one callee path or at two.
    fn assertOnePosition(g: *Grafter, i: u32, callee: []const CellId, shared: SetId) Error!void {
        const gpa_ = g.gpa();
        const places = g.env.places;
        const cells = g.env.cells;
        if (i >= g.args.len or g.args[i].node == .none) return;
        // On an account of its own: the check never changes what the call
        // charges (#1545).
        var scratch: Ids.Account = .{ .allowance = std.math.maxInt(u32) };
        defer scratch.deinit(gpa_);
        const real = g.env.charge;
        g.env.charge = .growth(&scratch);
        defer g.env.charge = real;
        var root: PathId = .from(cells.get(callee[0]).b);
        while (places.pathParent(root) != .none) root = places.pathParent(root);
        var trace: std.ArrayList(Pre.Arrival) = .empty;
        defer trace.deinit(gpa_);
        var w: Pre = .{ .env = g.env, .trace = &trace };
        defer w.deinit();
        _ = try w.run(g.args[i].node, root);
        var keys: Ids.FixedDict(1) = .{};
        defer keys.deinit(gpa_);
        for (callee) |c| (try keys.getOrPut(gpa_, .{cells.get(c).b})).value_ptr.* = 0;
        var at: ?PathId = null;
        for (trace.items) |a| {
            if (keys.get(.{a.key.int()}) == null or !cells.sets.member(shared, a.cell.int())) continue;
            const p = w.states.items[a.state].path;
            if (at == null) at = p;
            if (at.? != p or places.isSummary(p))
                std.debug.panic("ownership v2: §2.9 rule 3 read two positions of one image that two positions of the actual bring", .{});
        }
    }

    /// Rule 3's (b): walking the actual down `steps` (built nodes and deltas
    /// projected one step at a time, views forced), the first node that is
    /// not built is one position's possible contents (`onePosition`), and it
    /// is met before any summary step (`[*]`). Below a summary step a node
    /// stands for coexisting elements, so a leaf or a union there is not one
    /// position. Reaching the end still built is not one position either.
    fn onePositionAlong(g: *Grafter, i: u32, steps: []const Place.Step) Error!bool {
        const shapes = g.env.shapes;
        if (i >= g.args.len or g.args[i].node == .none) return false;
        var n = g.args[i].node;
        var summary = false;
        var k: usize = 0;
        while (true) : (k += 1) {
            try g.env.charge.reserve(g.gpa(), .inspection, 1);
            n = try shapes.force(g.gpa(), g.account(), n);
            switch (shapes.kind(n)) {
                .leaf, .@"union", .choice => return !summary and try g.onePosition(n),
                .node, .delta => {
                    if (k == steps.len) return false;
                    const s = steps[k];
                    if (s.kind == .elem or s.kind == .level) summary = true;
                    n = (try shapes.proj(g.gpa(), g.account(), g.env.places, g.env.cells, n, s)) orelse return false;
                },
                else => return false,
            }
        }
    }

    /// The forced node is one position's possible contents: a leaf, or a
    /// union or choice DAG whose every member is a leaf, each node visited
    /// once. A leaf holding an approximate cell, or a cell under a repeating
    /// split (§2.9 *The repeating split*), is not: two of its parameter
    /// positions may be one object. A node, delta, recast or positions node
    /// is not either: two of its children may hold one object.
    fn onePosition(g: *Grafter, n0: NodeId) Error!bool {
        const shapes = g.env.shapes;
        var stack: std.ArrayList(NodeId) = .empty;
        defer stack.deinit(g.gpa());
        const seen = try shapes.marks.take(g.gpa());
        defer shapes.marks.give(seen);
        try stack.append(g.gpa(), n0);
        while (stack.pop()) |m| {
            if (seen.contains(m)) continue;
            try seen.put(g.gpa(), m, {});
            try g.env.charge.reserve(g.gpa(), .inspection, 1);
            const n = try shapes.force(g.gpa(), g.account(), m);
            switch (shapes.kind(n)) {
                .leaf => {
                    var it = g.env.cells.sets.iterate(shapes.cells(n));
                    while (it.next()) |e| {
                        try g.env.charge.reserve(g.gpa(), .inspection, 1);
                        if (e.value == 1 or Cond.Table.repeatingSplit(g.env.cells, .from(e.key)) != null) return false;
                    }
                },
                .@"union", .choice => try stack.appendSlice(g.gpa(), &.{ .from(shapes.get(n).a), .from(shapes.get(n).b) }),
                else => return false,
            }
        }
        return true;
    }

    /// A field, a tuple index or a constructor argument: a step every route
    /// of a path ending in it ends in.
    fn namedStep(s: Place.Step) bool {
        return s.kind == .field or s.kind == .index or s.kind == .ctor_arg;
    }

    /// The path's first `⟲` node, `none` when it has none.
    fn firstLevel(places: *Place.Table, p0: PathId) PathId {
        var lv: PathId = .none;
        var p = p0;
        while (places.pathParent(p) != .none) : (p = places.pathParent(p)) {
            if (places.pathStep(p).kind == .level) lv = p;
        }
        return lv;
    }

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
        const n = try g.prefixArg(i, prefix);
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
                return try t.deep(gpa_, g.env.charge, g.env.view(), kappa, n, g.env.places.isSummary(.from(x.b)));
            },
            .sep, .apart => {
                // `apart [A] [B]` over the sides' cells as a multiset: each side's
                // set aggregate, memoised per radix node, merged into the larger
                // (*The derivation*), never a sorted list of them all.
                var sides: std.ArrayList(SetId) = .empty;
                defer sides.deinit(gpa_);
                var callee: std.ArrayList(CellId) = .empty;
                defer callee.deinit(gpa_);
                if (a.atom == .sep) {
                    for ([_]u32{ a.a, a.b }) |side| try callee.append(gpa_, .from(side));
                } else {
                    var it = g.env.cells.sets.iterate(.from(a.a));
                    while (it.next()) |e| try callee.append(gpa_, .from(e.key));
                }
                if (switched("cert-params-reversed")) std.mem.reverse(CellId, callee.items);
                // §2.9 rule 4 (#1485): a side in a group stands at its images
                // there; two sides of one group whose images meet at `X` are two
                // disjoint sets of positions of `X`, apart under `exclOf(X)`.
                var extra: CondId = Cond.yes;
                var groups: Ids.FixedDict(3) = .{};
                defer groups.deinit(gpa_);
                var gids: std.ArrayList(u32) = .empty;
                defer gids.deinit(gpa_);
                var keys: std.ArrayList(Cond.Table.HypKey) = .empty;
                defer keys.deinit(gpa_);
                for (callee.items) |c| {
                    keys.clearRetainingCapacity();
                    var gid: u32 = Ids.none_int;
                    var side: SetId = .none;
                    const x = g.env.cells.get(c);
                    if (x.origin == .param and !mutated("cert-rule4-sum")) if (try g.groupOf(x.a, .from(x.b))) |grp| {
                        const got = try groups.getOrPut(gpa_, .{ x.a, grp.prefix.int(), grp.node.int() });
                        if (!got.found_existing) got.value_ptr.* = groups.count() - 1;
                        if (try g.groupImages(c, grp, got.value_ptr.*, &keys)) {
                            gid = got.value_ptr.*;
                            for (keys.items) |k| side = try g.env.cells.sets.insert(gpa_, g.env.charge, side, k.image.int(), 0);
                        }
                    };
                    if (gid == Ids.none_int) side = try g.sideCells(c);
                    try sides.append(gpa_, side);
                    try gids.append(gpa_, gid);
                }
                if (std.mem.indexOfNone(u32, gids.items, &.{Ids.none_int}) != null) extra = try g.ruleFourSides(t, callee.items, gids.items, sides.items);
                // Two sides (a `sep`, or an `apart` of two): merged along their
                // tries, memoised per node pair; more, one into the other.
                // Two positions of one image through `⟲` (§2.9 rule 3).
                if (sides.items.len >= 2) extra = try t.@"and"(gpa_, g.env.charge, extra, try g.positionsThroughLevels(t, callee.items, sides.items));
                var acc: Cond.Table.Agg = .{};
                if (sides.items.len == 2) {
                    acc = try t.aggMergeSets(gpa_, g.env.charge, g.env.cells, g.env.places, sides.items[0], sides.items[1]);
                } else for (sides.items) |s| {
                    acc = try t.aggMergeMulti(gpa_, g.env.charge, g.env.cells, g.env.places, acc, try t.setAgg(gpa_, g.env.charge, g.env.cells, g.env.places, s));
                }
                const k = try t.@"and"(gpa_, g.env.charge, try t.aggCond(gpa_, g.env.charge, g.env.cells, g.env.places, acc), extra);
                if (std.debug.runtime_safety and Cond.full_cross_check) {
                    // On an account and caches of its own (#1545).
                    var scratch: Ids.Account = .{ .allowance = std.math.maxInt(u32) };
                    defer scratch.deinit(gpa_);
                    const ch: Ids.Charge = .growth(&scratch);
                    var caches = t.checkBegin(true);
                    defer t.checkEnd(gpa_, &caches);
                    const real = g.env.charge;
                    g.env.charge = ch;
                    defer g.env.charge = real;
                    var items: std.ArrayList(Cond.Item) = .empty;
                    defer items.deinit(gpa_);
                    for (sides.items) |s| try g.addItems(s, &items);
                    try t.expectSame(gpa_, ch, k, try t.@"and"(gpa_, ch, try t.apart(gpa_, ch, g.env.cells, g.env.places, items.items, null), extra));
                }
                return k;
            },
            .within, .keep, .writes => return Cond.lost,
            // A class is published resolved: its conditions hold no `inst`.
            .inst => unreachable,
        }
    }
};

/// §2.9 rule 3's reading of k sides once (a) and (b) hold: an image that an
/// earlier side holds exactly, met again, is shared. It stays on the first
/// side that holds it and leaves every later one. What the group owes beyond
/// the multiset of what is left: `exclOf(X)` for each shared `X`; `apart`
/// among the shared images when there are two or more; and `apart` between
/// the shared images a side keeps and the rest of that side, so that `X` on
/// a later side against `Z` on the first is still required. One pass over the
/// sides' cells, and one merge per side that keeps a shared image.
fn shareImages(t: *Cond.Table, gpa: Allocator, charge: Ids.Charge, cells: *Cell.Table, places: *Cell.Places, sides: []SetId) Error!struct { extra: CondId, shared: SetId } {
    var first: Ids.FixedDict(1) = .{};
    defer first.deinit(gpa);
    var shared: SetId = .none;
    for (sides, 0..) |*side, j| {
        var rest: SetId = .none;
        var dropped = false;
        var it = cells.sets.iterate(side.*);
        while (it.next()) |e| {
            try charge.reserve(gpa, .inspection, 1);
            if (e.value == 0) if (first.get(.{e.key})) |f| if (f != j and namesPositions(cells, places, .from(e.key))) {
                shared = try cells.sets.insert(gpa, charge, shared, e.key, 0);
                dropped = true;
                continue;
            };
            rest = try cells.sets.insert(gpa, charge, rest, e.key, e.value);
        }
        var st = cells.sets.iterate(side.*);
        while (st.next()) |e| if (e.value == 0) {
            const got = try first.getOrPut(gpa, .{e.key});
            if (!got.found_existing) got.value_ptr.* = @intCast(j);
        };
        if (dropped) side.* = rest;
    }
    if (shared == .none) return .{ .extra = Cond.yes, .shared = .none };
    var extra: CondId = Cond.yes;
    var items: std.ArrayList(Cond.Item) = .empty;
    defer items.deinit(gpa);
    var it = cells.sets.iterate(shared);
    while (it.next()) |e| {
        const c: CellId = .from(e.key);
        extra = try t.@"and"(gpa, charge, extra, try t.exclOf(gpa, charge, cells, c));
        try items.append(gpa, .{ .cell = c, .approx = false });
    }
    if (items.items.len >= 2) extra = try t.@"and"(gpa, charge, extra, try t.apart(gpa, charge, cells, places, items.items, null));
    // Each side's kept shared images against the rest of that side.
    for (sides, 0..) |side, j| {
        var kept: SetId = .none;
        var rest: SetId = .none;
        var st = cells.sets.iterate(side);
        while (st.next()) |e| {
            try charge.reserve(gpa, .inspection, 1);
            if (cells.sets.member(shared, e.key) and first.get(.{e.key}).? == j) {
                kept = try cells.sets.insert(gpa, charge, kept, e.key, 0);
            } else rest = try cells.sets.insert(gpa, charge, rest, e.key, e.value);
        }
        if (kept == .none or rest == .none) continue;
        extra = try t.@"and"(gpa, charge, extra, try t.aggCond(gpa, charge, cells, places, try t.aggMergeSets(gpa, charge, cells, places, kept, rest)));
    }
    return .{ .extra = extra, .shared = shared };
}

/// Rule 3's (c): a shared image is symbolic and at a summary path, so it
/// names positions. Given (b) every shared image is a projection of one
/// exact leaf, so this never fails: a `runtime_safety` assert. A release
/// build keeps the image a repeat if it ever did.
fn namesPositions(cells: *const Cell.Table, places: *const Cell.Places, c: CellId) bool {
    const o = cells.origin(c);
    const ok = o.isSymbolic() and o != .top and places.isSummary(.from(cells.get(c).b));
    if (std.debug.runtime_safety and !ok) std.debug.panic("ownership v2: §2.9 rule 3 shares an image that names no positions", .{});
    return ok;
}

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
    /// The place a structured template stands at under an environment,
    /// `(environment, template)`, where it is not the template's own: a call
    /// instantiates its type variables (`instantiate`, `placeImage`).
    places_of: std.AutoHashMapUnmanaged(u64, PlaceId) = .empty,
    places: *Place.Table,
    cells: *Cell.Table,
    shapes: *Shape.Table,
    conds: *Cond.Table,
    sums: *const Summary.Table,
    /// The group being solved, while one is (`Groups`): which classes are
    /// its members' ports, so a view of one is a hypothesis node (#1485).
    group: ?GroupPorts = null,
    /// Rule 4's groups (§2.9 rule 4, #1485, #1559): one id per
    /// `(environment, i, L, node)`, kept across the classes of one
    /// certificate, so the keys of two classes that land in one class of
    /// the caller meet in one group. Never a count restarted per class.
    rule4_groups: Ids.FixedDict(4) = .{},

    pub const GroupPorts = struct { ctx: *anyopaque, isPort: *const fn (ctx: *anyopaque, class: ClassId) bool };

    const ViewEnv = struct { class: ClassId, args: Ids.Range, label: LabelId };

    pub fn deinit(v: *Views, gpa: Allocator) void {
        v.envs.deinit(gpa);
        v.args.deinit(gpa);
        v.members.deinit(gpa);
        v.places_of.deinit(gpa);
        v.rule4_groups.deinit(gpa);
    }

    /// Set on `v.shapes` once, before the first call.
    pub fn instantiation(v: *Views) Shape.Table.Instantiation {
        return .{ .ctx = v, .sets = &v.cells.sets, .leaf = leafImage, .cells = cellsImage, .reach = reachImage, .reroot = rerootImage, .parts = partsImage, .place = placeImage, .is_var = isVar };
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

    /// The place a view of `template` stands at under environment `e`: a
    /// leaf at a type variable's place stands where its image does (one
    /// exact parameter cell's actual, or `instantiatedPlace`'s shared place);
    /// a structured template where its parent's instantiated place has its
    /// step (`instantiate`); any other at its own (§2.11 *Re-rooting at a
    /// parameter*).
    fn placeImage(ctx: *anyopaque, t: *Shape.Table, gpa_: Allocator, account_: *Ids.Account, e: u32, template: NodeId) Error!PlaceId {
        const v = of(ctx);
        const at = t.place(template);
        const d = t.get(template);
        switch (d.kind) {
            .leaf => {
                if (v.places.kind(at) != .@"var") return at;
                var none: Scratch = .{};
                defer none.deinit(gpa_);
                var g = v.grafter(gpa_, account_, e, &none);
                defer g.deinit();
                return g.instantiatedPlace(at, d.cells);
            },
            .recast => return at,
            else => {
                try account_.reserve(.memo, 1);
                if (v.places_of.get(@as(u64, e) << 32 | template.int())) |p| return p;
                if (v.places.kind(at) != .@"var" or !(d.kind == .@"union" or d.kind == .choice or d.kind == .positions)) return at;
                // A join at a type variable's place stands where its sides
                // do, a side at a `var` place yielding (`Shape.joinPlace`).
                const l = try placeImage(ctx, t, gpa_, account_, e, .from(d.a));
                const r = try placeImage(ctx, t, gpa_, account_, e, .from(d.b));
                if (l == r or v.places.kind(r) == .@"var") return l;
                return if (v.places.kind(l) == .@"var") r else at;
            },
        }
    }

    fn structured(t: *Shape.Table, n: NodeId) bool {
        return switch (t.kind(n)) {
            .node, .delta, .@"union", .choice, .positions => true,
            else => false,
        };
    }

    /// Records that `template` stands at `p` under environment `e`, and so
    /// its structured children at `p`'s child places, a join's sides at
    /// `p`. Nothing when `p` is the template's own place or another kind
    /// of place, nor for a leaf (`instantiatedPlace`) or a recast, whose
    /// inner keeps its own place (§2.13.9).
    fn instantiate(v: *Views, gpa_: Allocator, account_: *Ids.Account, t: *Shape.Table, template: NodeId, e: u32, p: PlaceId) Error!void {
        // The whole template at once, before any of its views is made, so
        // a view made out of order (a κ relabelling) has its place too.
        const Item = struct { n: NodeId, p: PlaceId };
        var stack: std.ArrayList(Item) = .empty;
        defer stack.deinit(gpa_);
        try stack.append(gpa_, .{ .n = template, .p = p });
        while (stack.pop()) |x| {
            if (x.p == .none or !structured(t, x.n) or x.p == t.place(x.n) or v.places.kind(x.p) != v.places.kind(t.place(x.n))) continue;
            try account_.reserve(.memo, 1);
            const got = try v.places_of.getOrPut(gpa_, @as(u64, e) << 32 | x.n.int());
            if (got.found_existing) continue;
            got.value_ptr.* = x.p;
            const d = t.get(x.n);
            switch (d.kind) {
                .node, .delta => {
                    if (d.kind == .delta) try stack.append(gpa_, .{ .n = .from(d.a), .p = x.p });
                    var it = t.overEntries(if (d.kind == .node) d.a else d.b);
                    while (it.next()) |c| if (v.places.child(x.p, c.step)) |q| try stack.append(gpa_, .{ .n = c.node, .p = q });
                },
                else => for ([_]u32{ d.a, d.b }) |s| try stack.append(gpa_, .{ .n = .from(s), .p = x.p }),
            }
        }
    }

    fn isVar(ctx: *anyopaque, p: PlaceId) bool {
        return of(ctx).places.kind(p) == .@"var";
    }

    fn leafImage(ctx: *anyopaque, t: *Shape.Table, gpa_: Allocator, account_: *Ids.Account, e: u32, template: NodeId) Error!NodeId {
        const v = of(ctx);
        var none: Scratch = .{};
        defer none.deinit(gpa_);
        var g = v.grafter(gpa_, account_, e, &none);
        defer g.deinit();
        return g.viewLeaf(&v.members, t.place(template), t.cells(template));
    }

    fn partsImage(ctx: *anyopaque, t: *Shape.Table, gpa_: Allocator, account_: *Ids.Account, e: u32, template: NodeId, out: *std.ArrayList(Shape.Table.LeafPart)) Error!void {
        const v = of(ctx);
        var none: Scratch = .{};
        defer none.deinit(gpa_);
        var g = v.grafter(gpa_, account_, e, &none);
        defer g.deinit();
        return g.eagerParts(t.place(template), t.cells(template), out);
    }

    fn cellsImage(ctx: *anyopaque, _: *Shape.Table, gpa_: Allocator, account_: *Ids.Account, e: u32, s: SetId, at: PlaceId) Error!SetId {
        const v = of(ctx);
        var none: Scratch = .{};
        defer none.deinit(gpa_);
        var g = v.grafter(gpa_, account_, e, &none);
        defer g.deinit();
        return g.imageCells(s, at);
    }

    /// The fold certificate's readers (§8 slice 4, #1485), set on `conds`
    /// once, as `resolver` is.
    pub fn hyp(v: *Views) Cond.Table.Hyp {
        return .{ .ctx = v, .envOf = hypEnvOf, .keys = hypKeys, .class = hypClass };
    }

    /// A view's environment when its class is a hypothesis: a port of the
    /// group being solved (`group`), or a settled class whose certificate
    /// the induction proved (`Summary.Table.certified`).
    fn hypEnvOf(ctx: *anyopaque, shapes: *Shape.Table, n: NodeId) ?u32 {
        const v = of(ctx);
        const e = shapes.nodes.col.b[n.int()];
        if (e >= v.envs.items.len) return null;
        const class = v.envs.items[e].class;
        if (v.sums.certified(class)) return e;
        const g = v.group orelse return null;
        return if (g.isPort(g.ctx, class)) e else null;
    }

    /// The `res` and snapshot of the class at environment `e`.
    fn hypClass(ctx: *anyopaque, e: u32) Cond.Table.HypClass {
        const v = of(ctx);
        const c = v.sums.get(v.envs.items[e].class);
        return .{ .res = c.res, .kappas = c.kappas };
    }

    /// The certificate's keys `cells` at environment `e`, each with its
    /// images by §2.9 rule 4 (`Grafter.ruleFourKey`).
    fn hypKeys(ctx: *anyopaque, gpa_: Allocator, charge: Ids.Charge, e: u32, cells: SetId, out: *std.ArrayList(Cond.Table.HypKey)) Error!void {
        const v = of(ctx);
        var none: Scratch = .{};
        defer none.deinit(gpa_);
        var g = v.grafter(gpa_, charge.account, e, &none);
        defer g.deinit();
        var keys: std.ArrayList([2]u32) = .empty;
        defer keys.deinit(gpa_);
        var it = v.cells.sets.iterate(cells);
        while (it.next()) |x| {
            try charge.reserve(gpa_, .inspection, 1);
            if (v.cells.origin(.from(x.key)) == .mark) continue;
            try keys.append(gpa_, .{ x.key, x.value });
        }
        // The test-only switch instantiates the keys, and so the parameters'
        // groups, in the other order: rule 4's verdict is the same (§2.9 (a′),
        // near-miss row 19).
        if (switched("cert-params-reversed")) std.mem.reverse([2]u32, keys.items);
        for (keys.items) |x| try g.ruleFourKey(.from(x[0]), x[1] == 1, e, &v.rule4_groups, out);
    }

    /// The resolver of the `inst` atoms calls make (§2.11 *κ across a call*,
    /// part 3), set on `conds` once, as `instantiation` is.
    pub fn resolver(v: *Views) Cond.Table.Resolver {
        return .{ .ctx = v, .resolve = resolveImage };
    }

    /// Class condition `k` instantiated at the call of environment `e`.
    fn resolveImage(ctx: *anyopaque, t: *Cond.Table, gpa_: Allocator, charge: Ids.Charge, k: u32, e: u32, set: bool) Error!CondId {
        const v = of(ctx);
        var none: Scratch = .{};
        defer none.deinit(gpa_);
        var g = v.grafter(gpa_, charge.account, e, &none);
        defer g.deinit();
        if (!set) return t.instantiate(gpa_, charge, .from(k), .{ .ctx = &g, .atom = Grafter.atom });
        // An atom set (a class's `xreq`): each atom answered here, conjoined.
        var acc: CondId = Cond.yes;
        var at = t.atoms.iterate(.from(k));
        while (at.next()) |a| {
            try charge.reserve(gpa_, .inspection, 1);
            acc = try t.@"and"(gpa_, charge, acc, try Grafter.atom(&g, t, gpa_, charge, t.get(.from(a.key))));
        }
        return acc;
    }

    /// The snapshot position a re-root view reads its actual at (§2.11 *κ
    /// across a call*, `R = argKappa(E, i, q)`), null for a view that is no
    /// re-root view: its template a leaf of one exact parameter cell.
    fn rerootImage(ctx: *anyopaque, t: *Shape.Table, gpa_: Allocator, account_: *Ids.Account, e: u32, template: NodeId) Error!?Ids.KappaId {
        const v = of(ctx);
        if (t.kind(template) != .leaf) return null;
        const cell = rerootCell(v.cells, t.cells(template)) orelse return null;
        var none: Scratch = .{};
        defer none.deinit(gpa_);
        var g = v.grafter(gpa_, account_, e, &none);
        defer g.deinit();
        const x = v.cells.get(cell);
        return try g.argKappa(x.a, .from(x.b));
    }

    fn reachImage(ctx: *anyopaque, t: *Shape.Table, gpa_: Allocator, account_: *Ids.Account, e: u32, c: CellId, approx: u1) Error!SetId {
        const v = of(ctx);
        var none: Scratch = .{};
        defer none.deinit(gpa_);
        var g = v.grafter(gpa_, account_, e, &none);
        defer g.deinit();
        const x = v.cells.get(c);
        if (x.origin == .param) return t.reach(gpa_, account_, &v.cells.sets, try g.argAt(x.a, .from(x.b), g.placeOfCell(c)));
        // A taken element, the call's materialisation (`takenImage`).
        if (try g.takenImage(c)) |n| return t.reach(gpa_, account_, &v.cells.sets, n);
        // What the call does not interpret is `⊤`, approximately, as a
        // grafted atom reads it (`Grafter.cellsOf`).
        if (x.origin.isSymbolic() and x.origin != .top) return v.cells.sets.insert(gpa_, .growth(account_), .none, (try v.cells.top(gpa_, account_)).int(), 1);
        return v.cells.sets.insert(gpa_, .growth(account_), .none, (try g.mapCell(c)).int(), approx);
    }
};

/// Per node of a use shape, what is at or below it: 1 a `W`, 2 an `E`.
/// Memoised per node, on an explicit stack (#1138), so a use shape that is
/// a DAG costs its nodes.
pub fn marksBelow(env: Env, use: NodeId, memo: *Ids.FixedDict(1)) Error!u32 {
    const Frame = struct { node: NodeId, expanded: bool };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(env.gpa);
    try stack.append(env.gpa, .{ .node = use, .expanded = false });
    while (stack.pop()) |f| {
        if (memo.get(.{f.node.int()}) != null) continue;
        const kids = env.shapes.kind(f.node) == .node;
        if (!f.expanded) {
            try env.charge.reserve(env.gpa, .inspection, 1);
            try stack.append(env.gpa, .{ .node = f.node, .expanded = true });
            if (kids) {
                var kt = env.shapes.overEntries(env.shapes.get(f.node).a);
                while (kt.next()) |k| if (memo.get(.{k.node.int()}) == null) try stack.append(env.gpa, .{ .node = k.node, .expanded = false });
            }
            continue;
        }
        var bits: u32 = 0;
        var it = env.cells.sets.iterate((try env.shapes.cellsOf(env.gpa, env.account(), &env.cells.sets, f.node)));
        while (it.next()) |x| {
            const c: CellId = .from(x.key);
            if (env.cells.origin(c) != .mark) continue;
            switch (env.cells.markOf(c)) {
                .w => bits |= 1,
                .e => bits |= 2,
                else => {},
            }
        }
        if (kids) {
            var kt = env.shapes.overEntries(env.shapes.get(f.node).a);
            // A child not settled is on a cycle: everything, to be safe.
            while (kt.next()) |k| bits |= memo.get(.{k.node.int()}) orelse 3;
        }
        (try memo.getOrPut(env.gpa, .{f.node.int()})).value_ptr.* = bits;
    }
    return memo.get(.{use.int()}).?;
}

/// The positions one `⟲` step stands for below `x`: each node reached by
/// one step or more whose place is `x`'s (`positionsAt`).
pub fn reentries(env: Env, x: NodeId, out: *std.ArrayList(NodeId)) Error!void {
    const gpa = env.gpa;
    const shapes = env.shapes;
    const places = env.places;
    const p = shapes.place(x);
    const seen = try shapes.marks.take(gpa);
    defer shapes.marks.give(seen);
    var stack: std.ArrayList(NodeId) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, x);
    while (stack.pop()) |y| {
        for (places.steps(shapes.place(y)).steps) |c| {
            try env.charge.reserve(gpa, .inspection, 1);
            if (c.kind == .level) continue;
            const n = (try shapes.proj(gpa, env.account(), places, env.cells, y, c)) orelse continue;
            if (seen.contains(n)) continue;
            try seen.put(gpa, n, {});
            if (shapes.place(n) == p) try out.append(gpa, n);
            try stack.append(gpa, n);
        }
    }
}

/// The value `n` at a class's parameter path `steps`, as `Transfer`'s
/// `positionsAt` reads an argument there: every position the path stands
/// for, joined; a `⟲` step every re-entry of the place below the value so
/// far (`reentries`). Without one, a missing step keeps the value reached.
/// Null when no position is left.
pub fn positionsAt(env: Env, n: NodeId, steps: []const Step) Error!?NodeId {
    const gpa = env.gpa;
    const shapes = env.shapes;
    const places = env.places;
    var has_level = false;
    for (steps) |s| has_level = has_level or s.kind == .level;
    if (!has_level) {
        var at = n;
        for (steps) |s| at = (try shapes.proj(gpa, env.account(), places, env.cells, at, s)) orelse return at;
        return at;
    }
    const task = try env.account().enter(gpa, null);
    defer env.account().leave(task);
    var frontier: std.ArrayList(NodeId) = .empty;
    defer frontier.deinit(gpa);
    var next: std.ArrayList(NodeId) = .empty;
    defer next.deinit(gpa);
    try frontier.append(gpa, n);
    for (steps) |s| {
        next.clearRetainingCapacity();
        for (frontier.items) |x| {
            if (s.kind != .level) {
                if (try shapes.proj(gpa, env.account(), places, env.cells, x, s)) |m| try next.append(gpa, m);
                continue;
            }
            try reentries(env, x, &next);
        }
        std.mem.swap(std.ArrayList(NodeId), &frontier, &next);
    }
    if (frontier.items.len == 0) return null;
    if (frontier.items.len == 1) return frontier.items[0];
    return try shapes.join(gpa, env.account(), places, env.cells, frontier.items);
}

/// A parameter's routes to what its use shape writes (`W`, deep with `S`)
/// or lets escape (`E`), one at a time, each with its steps from the root
/// (§2.11 items 3 and 4): a walk of the shape's explicit structure (a leaf's
/// marks hold below it, so a leaf ends a route) through the subtrees that
/// hold what is wanted only (`marksBelow`), paired with the argument's value
/// as `TransferBeside.positionsAt` reads it. A missing step keeps the value
/// reached; below a `⟲` a route is no single value and pairs with none.
///
/// **One route per path of the pair graph (#1356).** Sibling routes that
/// meet one `(use node, value node)` pair are one route from there: they
/// have one base, one set of other paths and one set of marks below it,
/// and the route met first names them. So a use that is a DAG over a value
/// that shares its parts costs its distinct pairs, never its paths; over
/// distinct values (a tree, a parameter's positions) every route is its own.
/// A value is projected when its route is popped, in the order a caller
/// that reads the routes one by one and projects each made it. Each pair
/// popped is a record. A write's other paths are `Transfer`'s (#1325).
///
/// **A stop at a parameter's leaf (#1412).** With `stops`, a write route
/// whose value becomes an exact, unrefined leaf of the caller's own
/// parameter through an exact prefix (no `[*]` or `⟲`) is not walked on:
/// it is returned once as a `stop`, with its use node and the leaf, and
/// the caller expands what is below it after its walk, paired with what
/// its frame names below that leaf (`Transfer.Frame.expandGroups`).
pub const Routes = struct {
    env: Env,
    below: Ids.FixedDict(1) = .{},
    seen: Ids.FixedDict(4) = .{},
    entries: std.ArrayList(Entry) = .empty,
    stack: std.ArrayList(Item) = .empty,
    steps: std.ArrayList(Step) = .empty,
    want: u32 = 0,
    stops: bool = false,

    const Entry = struct { step: Step, parent: u32 };
    /// A use node, its route's entry, and the argument's value: the
    /// parent's until the item is popped, then its own. `stuck` once a step
    /// is missing; `free`, no value, below a `⟲` or with no argument;
    /// `exact` while no step is a `[*]` or a `⟲`.
    const Item = struct { node: NodeId, entry: u32, value: NodeId, stuck: bool, free: bool, exact: bool = true };
    /// `stop`: the route stopped at a parameter's leaf (`stops`).
    pub const Route = struct { steps: []const Step, deep: bool, stop: ?Stop = null };
    pub const Stop = struct { node: NodeId, leaf: CellId, value: NodeId };
    pub const Want = enum(u2) { writes = 1, escapes = 2 };

    pub fn deinit(r: *Routes) void {
        r.below.deinit(r.env.gpa);
        r.seen.deinit(r.env.gpa);
        r.entries.deinit(r.env.gpa);
        r.stack.deinit(r.env.gpa);
        r.steps.deinit(r.env.gpa);
    }

    /// Walk `use`'s routes of `want` over the argument's value `arg`
    /// (`.none`: no argument).
    /// `below` is a node's own and stays: one memo for every walk of the call.
    pub fn start(r: *Routes, use: NodeId, arg: NodeId, want: Want) Error!void {
        return r.startStops(use, arg, want, false);
    }

    /// `start`, stopping at a parameter's leaf when `stops` (writes only).
    pub fn startStops(r: *Routes, use: NodeId, arg: NodeId, want: Want, stops: bool) Error!void {
        const below = r.below;
        r.below = .{};
        r.deinit();
        r.* = .{ .env = r.env, .below = below, .want = @backingInt(want), .stops = stops and want == .writes };
        // The use's size: growth chosen before the walk, never the call's
        // lane (§4.1; #1369's review: a use of 600 nodes passed it).
        const walk = try r.env.account().enter(r.env.gpa, null);
        defer r.env.account().leave(walk);
        if (use == .none or try marksBelow(r.env, use, &r.below) & r.want == 0) return;
        try r.stack.append(r.env.gpa, .{ .node = use, .entry = Ids.none_int, .value = arg, .stuck = false, .free = arg == .none });
    }

    /// The next route, or null; its steps live until the next call.
    pub fn next(r: *Routes) Error!?Route {
        const env = r.env;
        while (r.stack.pop()) |it0| {
            try env.charge.reserve(env.gpa, .inspection, 1);
            var it = it0;
            if (it.entry != Ids.none_int and !it.free) {
                const e = r.entries.items[it.entry];
                if (e.step.kind == .level) {
                    it.free = true;
                } else if (!it.stuck) {
                    if (try env.shapes.proj(env.gpa, env.account(), env.places, env.cells, it.value, e.step)) |n| it.value = n else it.stuck = true;
                }
                if (!it.free and (try r.seen.getOrPut(env.gpa, .{ e.parent, it.node.int(), it.value.int(), @intFromBool(it.stuck) })).found_existing) continue;
                if (e.step.kind == .level or e.step.kind == .elem) it.exact = false;
            }
            if (r.stops and !it.free and !it.stuck and it.exact) if (try stopLeaf(env, it.value)) |c| {
                r.steps.clearRetainingCapacity();
                var at = it.entry;
                while (at != Ids.none_int) : (at = r.entries.items[at].parent) try r.steps.append(env.gpa, r.entries.items[at].step);
                std.mem.reverse(Step, r.steps.items);
                return .{ .steps = r.steps.items, .deep = false, .stop = .{ .node = it.node, .leaf = c, .value = it.value } };
            };
            var w = false;
            var e = false;
            var deep = false;
            var ct = env.cells.sets.iterate(try env.shapes.cellsOf(env.gpa, env.account(), &env.cells.sets, it.node));
            while (ct.next()) |x| {
                const c: CellId = .from(x.key);
                if (env.cells.origin(c) != .mark) continue;
                switch (env.cells.markOf(c)) {
                    .w => w = true,
                    .e => e = true,
                    .deep => deep = true,
                    else => {},
                }
            }
            if (env.shapes.kind(it.node) == .node) {
                var kt = env.shapes.overEntries(env.shapes.get(it.node).a);
                while (kt.next()) |k| {
                    if ((r.below.get(.{k.node.int()}) orelse 3) & r.want == 0) continue;
                    const id: u32 = @intCast(r.entries.items.len);
                    try r.entries.append(env.gpa, .{ .step = k.step, .parent = it.entry });
                    try r.stack.append(env.gpa, .{ .node = k.node, .entry = id, .value = it.value, .stuck = it.stuck, .free = it.free, .exact = it.exact });
                }
            }
            if (!(if (r.want == 1) w else e)) continue;
            r.steps.clearRetainingCapacity();
            var at = it.entry;
            while (at != Ids.none_int) : (at = r.entries.items[at].parent) try r.steps.append(env.gpa, r.entries.items[at].step);
            std.mem.reverse(Step, r.steps.items);
            return .{ .steps = r.steps.items, .deep = deep };
        }
        return null;
    }
};

/// The cell of `n` when it is a leaf of exactly one exact, unrefined
/// parameter cell: where a write route stops (`Routes.stops`, #1412).
pub fn stopLeaf(env: Env, n: NodeId) Error!?CellId {
    if (n == .none or env.shapes.kind(n) != .leaf) return null;
    var it = env.cells.sets.iterate(try env.shapes.cellsOf(env.gpa, env.account(), &env.cells.sets, n));
    const e = it.next() orelse return null;
    if (it.next() != null or e.value != 0) return null;
    const c: CellId = .from(e.key);
    return if (env.cells.origin(c) == .param) c else null;
}

/// Apply class `class` at call instruction `inst` to `args` (§2.11). The
/// answer's slices live in `s` until its next call.
pub fn apply(env: Env, sums: *const Summary.Table, class: ClassId, args: []const Value, inst: u32, s: *Scratch) Error!Applied {
    const gpa = env.gpa;
    s.memo.clear();
    s.escaped.clearRetainingCapacity();
    const cls = sums.get(class);
    const label = try env.cells.label(gpa, env.account(), inst, .none, false);
    var g: Grafter = .{ .env = env, .sums = sums, .args = args, .label = label, .s = s };
    defer g.deinit();
    // 4: the result, by reference (§2.11 *Representation of a view*): the
    // view of `res` under this call's environment, or at an identity class
    // the actual itself. Nothing of the arguments is read or copied.
    const views = Views.of((env.shapes.instantiation orelse unreachable).ctx); // every table that applies a class has one
    g.view_env = try views.add(env, class, args, label);
    const res = if (try g.identity(cls.res)) |actual| blk: {
        g.root = cls.res;
        g.answer = actual;
        break :blk actual;
    } else blk: {
        try views.instantiate(env.gpa, env.account(), env.shapes, cls.res, g.view_env, s.result_place);
        break :blk try env.shapes.view(gpa, env.account(), cls.res, g.view_env);
    };
    // The values the result lets escape: its `esc k`, each an `esc ι·k`.
    var rt = env.cells.sets.iterate(try env.shapes.reach(gpa, env.account(), &env.cells.sets, cls.res));
    while (rt.next()) |e| {
        try env.charge.reserve(gpa, .inspection, 1);
        const c: CellId = .from(e.key);
        if (env.cells.origin(c) != .esc) continue;
        const at = g.placeOfCell(c);
        try s.escaped.append(gpa, try env.shapes.leaf(gpa, env.account(), at, try env.cells.sets.insert(gpa, env.charge, .none, (try g.mapCell(c)).int(), 0)));
    }
    // 5: the class's κ relabelled onto the result's views, each entry's
    // path unchanged and its condition instantiated, then each argument's
    // snapshot linked where the argument stands in the result (§2.9). Eager,
    // the callee's κ size per call (#1265).
    var kappa = try env.conds.kappaRelabel(gpa, env.charge, cls.kappas, .{ .ctx = &g, .node = Grafter.relabelNode, .cond = Grafter.instantiated });
    kappa = try g.linkArgs(kappa, cls.res);
    // The callee's `xreq` the same way: one `inst` atom of its atom set.
    const xreq: CondId = if (cls.xreq == .none) Cond.yes else try env.conds.instSet(gpa, env.charge, cls.xreq, g.view_env);
    return .{
        .result = .{ .node = res, .kappa = kappa },
        .xreq = xreq,
        .escaped = s.escaped.items,
    };
}

// ---- a write's other paths, by alias key (§2.11 item 3, #1334) -------------------------

/// The alias key tags (`aliasKey`, `Beside`).
pub const key_concrete: u32 = 0;
pub const key_symbolic: u32 = 1;
pub const key_top: u32 = 2;
/// A parameter leaf's cell, by `(parameter, canonical path)`.
pub const key_param: u32 = 3;
/// A child whose reach holds a parameter's cell and is no parameter leaf:
/// beside every write.
pub const key_always: u32 = 4;
/// Every parameter leaf.
pub const key_param_leaf: u32 = 5;

/// The key two cells share whenever they may be one object (§2.2,
/// `Cell.alias`: only cells whose bases may alias do): a concrete base
/// itself; a symbolic base's origin, index and `j`, whose paths
/// `pathsMayAlias` tells apart; `⊤`, which may be anything.
pub fn aliasKey(cells: *const Cell.Table, c: CellId) [4]u32 {
    const b = cells.base(c);
    const o = cells.origin(b);
    if (o == .top) return .{ key_top, 0, 0, 0 };
    if (!o.isSymbolic()) return .{ key_concrete, b.int(), 0, 0 };
    const x = cells.get(b);
    return .{ key_symbolic, @backingInt(o), x.a, x.c };
}

/// A call's index of the children beside a write's path (`Transfer`'s
/// `otherPaths`, #1334): per node of a write's path, the items its walk
/// would push for the node's children, each listed under the alias keys of
/// the cells its value reaches (a parameter leaf under its cells' canonical
/// positions, as `unreached` reads them; a child holding any other
/// parameter cell under `key_always`). Built once per `(use node, value
/// node, state)` and shared by every write of the call through that node,
/// in growth chosen before it. A child listed under none of a write's keys
/// holds no cell that may be its base at any path below it: a concrete
/// cell projects to nothing, a symbolic one to cells of its own origin and
/// key (`Shape.projectLeaf`).
pub const Beside = struct {
    /// `(use node, value node, state)` → spine index.
    memo: Ids.FixedDict(3) = .{},
    /// Per spine index: its children's run in `kids`.
    ranges: std.ArrayList([2]u32) = .empty,
    kids: std.ArrayList(Kid) = .empty,
    /// `(spine, key)` → the first link of its children.
    heads: Ids.FixedDict(5) = .{},
    /// `(kid, next link)`.
    links: std.ArrayList([2]u32) = .empty,
    /// `(reach, key)` → that reach's cells of that key (`keyed`).
    sets: Ids.FixedDict(5) = .{},
    keyed_done: Ids.FixedDict(1) = .{},
    /// Per spine index: the keys its children are listed under, a run of
    /// `key_list`.
    key_ranges: std.ArrayList([2]u32) = .empty,
    key_list: std.ArrayList([4]u32) = .empty,

    pub const Kid = struct { step: Place.Step, u: NodeId, v: NodeId, stuck: bool, level: bool };

    pub fn deinit(b: *Beside, gpa: Allocator) void {
        b.memo.deinit(gpa);
        b.ranges.deinit(gpa);
        b.kids.deinit(gpa);
        b.heads.deinit(gpa);
        b.links.deinit(gpa);
        b.sets.deinit(gpa);
        b.keyed_done.deinit(gpa);
        b.key_ranges.deinit(gpa);
        b.key_list.deinit(gpa);
    }

    /// The spine index of a node built already, or null.
    pub fn lookup(b: *Beside, env: Env, key: [3]u32) Error!?u32 {
        try env.charge.reserve(env.gpa, .memo, 1);
        return b.memo.get(key);
    }

    /// The keys `sp`'s children are listed under.
    pub fn keysOf(b: *const Beside, sp: u32) []const [4]u32 {
        const r = b.key_ranges.items[sp];
        return b.key_list.items[r[0]..][0..r[1]];
    }

    /// The first link of `key`'s children at spine `sp`, or `none`.
    pub fn head(b: *const Beside, sp: u32, key: [4]u32) u32 {
        return b.heads.get(.{ sp, key[0], key[1], key[2], key[3] }) orelse Ids.none_int;
    }

    /// The children of a node of a write's path, `kids` (each an item its
    /// walk would push), indexed by key: their spine index.
    pub fn add(b: *Beside, env: Env, key: [3]u32, kids: []const Kid) Error!u32 {
        const gpa = env.gpa;
        const shapes = env.shapes;
        const cells = env.cells;
        const sp: u32 = @intCast(b.ranges.items.len);
        (try b.memo.getOrPut(gpa, key)).value_ptr.* = sp;
        const start: u32 = @intCast(b.kids.items.len);
        try b.kids.appendSlice(gpa, kids);
        try b.ranges.append(gpa, .{ start, @intCast(kids.len) });
        const keys_at: u32 = @intCast(b.key_list.items.len);
        for (kids, start..) |k, ki| {
            const kid: u32 = @intCast(ki);
            const n = try shapes.force(gpa, env.account(), k.v);
            if (try paramLeaf(env, n)) {
                try b.link(gpa, sp, .{ key_param_leaf, 0, 0, 0 }, kid);
                var ct = cells.sets.iterate(try shapes.cellsOf(gpa, env.account(), &cells.sets, n));
                while (ct.next()) |e| {
                    try env.charge.reserve(gpa, .inspection, 1);
                    const p = cells.get((try cells.unrefined(gpa, env.account(), env.places, .from(e.key))).?);
                    try b.link(gpa, sp, .{ key_param, p.a, p.b, 0 }, kid);
                }
                continue;
            }
            var rt = cells.sets.iterate(try shapes.reach(gpa, env.account(), &cells.sets, k.v));
            while (rt.next()) |e| {
                try env.charge.reserve(gpa, .inspection, 1);
                const c: CellId = .from(e.key);
                if (cells.origin(cells.base(c)) == .param) {
                    try b.link(gpa, sp, .{ key_always, 0, 0, 0 }, kid);
                    break;
                }
                try b.link(gpa, sp, aliasKey(cells, c), kid);
            }
        }
        try b.key_ranges.append(gpa, .{ keys_at, @as(u32, @intCast(b.key_list.items.len)) - keys_at });
        return sp;
    }

    fn link(b: *Beside, gpa: Allocator, sp: u32, key: [4]u32, kid: u32) Error!void {
        const got = try b.heads.getOrPut(gpa, .{ sp, key[0], key[1], key[2], key[3] });
        if (got.found_existing and b.links.items[got.value_ptr.*][0] == kid) return;
        if (!got.found_existing) try b.key_list.append(gpa, key);
        const prev = if (got.found_existing) got.value_ptr.* else Ids.none_int;
        got.value_ptr.* = @intCast(b.links.items.len);
        try b.links.append(gpa, .{ kid, prev });
    }

    /// Whether `n` is a leaf of parameter cells, each with a canonical
    /// position: what `unreached` can tell apart from a write's base.
    fn paramLeaf(env: Env, n: NodeId) Error!bool {
        const cells = env.cells;
        if (env.shapes.kind(n) != .leaf) return false;
        var ct = cells.sets.iterate(try env.shapes.cellsOf(env.gpa, env.account(), &cells.sets, n));
        var any = false;
        while (ct.next()) |e| {
            try env.charge.reserve(env.gpa, .inspection, 1);
            const c: CellId = .from(e.key);
            if (cells.origin(cells.base(c)) != .param) return false;
            if ((try cells.unrefined(env.gpa, env.account(), env.places, c)) == null) return false;
            any = true;
        }
        return any;
    }

    /// The cells of `reach` of alias key `key`, none if it has none; split by
    /// key once per reach, since a value is read at its path (`TransferBeside.reachBeside`).
    pub fn keyed(b: *Beside, env: Env, reach: SetId, key: [4]u32) Error!SetId {
        const gpa = env.gpa;
        const cells = env.cells;
        try env.charge.reserve(gpa, .memo, 1);
        if (!(try b.keyed_done.getOrPut(gpa, .{reach.int()})).found_existing) {
            var it = cells.sets.iterate(reach);
            while (it.next()) |e| {
                try env.charge.reserve(gpa, .inspection, 1);
                const c: CellId = .from(e.key);
                if (cells.origin(cells.base(c)) == .param) continue;
                const k = aliasKey(cells, c);
                const prev: SetId = if (b.sets.get(.{ reach.int(), k[0], k[1], k[2], k[3] })) |s| .from(s) else .none;
                const next = try cells.sets.insert(gpa, env.charge, prev, e.key, e.value);
                (try b.sets.getOrPut(gpa, .{ reach.int(), k[0], k[1], k[2], k[3] })).value_ptr.* = next.int();
            }
        }
        return if (b.sets.get(.{ reach.int(), key[0], key[1], key[2], key[3] })) |s| .from(s) else .none;
    }
};

comptime {
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
            // #1485's rule 4: `Tree = Node Tree (List Int) Tree | Leaf` (14, 15).
            14 => {
                for (0..3) |i| try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 6, @intCast(i)) catch unreachable), .@"var" = if (i == 1) 15 else 14 });
                return .{ .kind = .ctor, .head = 314 };
            },
            15 => {
                try out.append(g.gpa, .{ .step = Place.Step.elem, .@"var" = 13 });
                return .{ .kind = .list, .head = 200 };
            },
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
    conds.resolver = views.resolver();
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
    // A view of the template's bottom, re-rooted at the argument (§2.11).
    try testing.expectEqual(a, try shapes.force(gpa, &account, at.node));
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
    conds.resolver = views.resolver();
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
    // The result is a view (§2.11): its answer is the image's record.
    try testing.expectEqual(Shape.Kind.node, shapes.kind(try shapes.force(gpa, &account, r)));
    const ul = (try shapes.proj(gpa, &account, &places, &cells, r, arg)).?;
    const back = (try shapes.proj(gpa, &account, &places, &cells, ul, Place.Step.elem)).?;
    // A view of a DAG template projects to the view of its projection (§2.9
    // *Keyed where a reader looks*): its answer holds the image again.
    const bf = try shapes.force(gpa, &account, back);
    try testing.expect(bf == r or (shapes.kind(bf) == .@"union" and (shapes.get(bf).a == r.int() or shapes.get(bf).b == r.int())));
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
    conds.resolver = views.resolver();
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
    // The result is a view (§2.11): its answer is the image's record.
    try testing.expectEqual(Shape.Kind.node, shapes.kind(try shapes.force(gpa, &account, r)));
    const ul = (try shapes.proj(gpa, &account, &places, &cells, r, arg)).?;
    // The `[*]` child is the view of the template's union: its answer a
    // union whose one side is the image (the interned view) again.
    const back = try shapes.force(gpa, &account, (try shapes.proj(gpa, &account, &places, &cells, ul, Place.Step.elem)).?);
    try testing.expectEqual(Shape.Kind.@"union", shapes.kind(back));
    try testing.expectEqual(t_place, shapes.place(back));
    const d = shapes.get(back);
    try testing.expect(d.a == r.int() or d.b == r.int());
    // Its cells are the argument's: what the tied sides hold.
    try testing.expect(cells.sets.member(try shapes.cellsOf(gpa, &account, &cells.sets, back), asite.int()));
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
        x.conds.resolver = x.views.resolver();
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
    // A view of a DAG template projects to the view of its projection (§2.9
    // *Keyed where a reader looks*): its answer is the union.
    const at = try x.shapes.force(gpa, &x.account, (try x.shapes.proj(gpa, &x.account, &x.places, &x.cells, ur, x.arg)).?);
    try testing.expectEqual(Shape.Kind.@"union", x.shapes.kind(at));
    const sides = x.shapes.get(at);
    try testing.expect(sides.a == lr.int() or sides.b == lr.int());
    try testing.expect(x.cells.sets.member(try x.shapes.cellsOf(gpa, &x.account, &x.cells.sets, at), (try x.cells.site(gpa, &x.account, 5, x.list, .list)).int()));
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
    // The result is a view (§2.11): each record read at its answer, the
    // cycle closing through the interned view.
    const fr = try x.shapes.force(gpa, &x.account, r);
    try testing.expectEqual(Shape.Kind.@"union", x.shapes.kind(fr));
    const dr = try x.shapes.force(gpa, &x.account, .from(x.shapes.get(fr).b));
    try testing.expectEqual(Shape.Kind.delta, x.shapes.kind(dr));
    try testing.expectEqual(r.int(), x.shapes.get(dr).a);
}

test "#1314: every lazy reader of a view of a cycle with no node on it ends, its cells the cycle's least fixed point" {
    // `U = union(leaf{π0}, D)`, `D = delta(U, {[*]: site})` (and its sides
    // swapped), applied to a list `a`: a view's union answer, whose delta
    // side's base is the same interned view. Each reader is bounded by the
    // allowance, so a read that does not end fails. The cells are the
    // cycle's least fixed point, what enters it from outside: `a`'s own, as
    // the eager image of the cycle's one exit, the leaf, is.
    const gpa = testing.allocator;
    for ([_]bool{ false, true }) |swap| {
        var x: KnotFixture = .{};
        try x.init();
        defer x.deinit();
        x.account.allowance = std.math.maxInt(u32) - 1;
        const L = x.list;
        const p0 = try x.cells.symbolic(gpa, &x.account, &x.places, .param, 0, try x.places.rootPath(gpa, L), 0);
        const p0_set = try x.cells.sets.insert(gpa, x.env().charge, .none, p0.int(), 0);
        const pleaf = try x.shapes.leaf(gpa, &x.account, L, p0_set);
        const uu = try x.shapes.knot(gpa, &x.account);
        const ud = try x.shapes.knot(gpa, &x.account);
        x.shapes.tie(ud, .{ .kind = .delta, .place = L, .cells = p0_set, .a = uu.int(), .b = try x.one(Place.Step.elem, try x.site(26, x.t_place)), .reach = .none });
        if (swap) try x.tieUnion(uu, ud, pleaf) else try x.tieUnion(uu, pleaf, ud);
        const u = try x.sums.add(x.env(), .{ .params = &.{.none}, .res = uu, .kappas = .none });
        const a = try listAt(&x, L, 20, try x.site(21, x.t_place));
        const ak = (try x.conds.kappaSet(gpa, x.env().charge, .none, a, Cond.yes)).ctx;
        var s: Scratch = .{};
        defer s.deinit(gpa);
        const applied = try apply(x.env(), &x.sums, u, &.{.{ .node = a, .kappa = ak }}, 0, &s);
        const v = applied.result.node;
        try testing.expectEqual(Shape.Kind.view, x.shapes.kind(v));
        x.account.allowance = x.account.growth + 1_000_000;
        const sh = &x.shapes;
        const sets = &x.cells.sets;
        // The cells: `a`'s, at the view, its answer and the delta side.
        const cells = try sh.cellsOf(gpa, &x.account, sets, v);
        try testing.expectEqual(x.shapes.cells(a), cells);
        const fu = try sh.force(gpa, &x.account, v);
        try testing.expectEqual(Shape.Kind.@"union", sh.kind(fu));
        try testing.expectEqual(cells, try sh.cellsOf(gpa, &x.account, sets, fu));
        const side = try sh.force(gpa, &x.account, .from(if (swap) sh.get(fu).a else sh.get(fu).b));
        try testing.expectEqual(Shape.Kind.delta, sh.kind(side));
        try testing.expectEqual(v.int(), sh.get(side).a);
        try testing.expectEqual(cells, try sh.cellsOf(gpa, &x.account, sets, side));
        // The eager image keeps a cycle as it is (§2.11 *The eager image*):
        // its cells are the same.
        try testing.expectEqual(cells, try sh.cellsOf(gpa, &x.account, sets, try sh.eager(gpa, &x.account, &x.places, &x.cells, v)));
        // The other readers end.
        _ = try sh.reach(gpa, &x.account, sets, v);
        _ = try sh.arrivals(gpa, &x.account, &x.cells, sets, v);
        _ = try sh.rank(gpa, &x.account, v);
        _ = try sh.namedSteps(gpa, &x.account, v);
        const elem = (try sh.proj(gpa, &x.account, &x.places, &x.cells, v, Place.Step.elem)).?;
        _ = try sh.cellsOf(gpa, &x.account, sets, elem);
        try testing.expect(try sh.leq(gpa, &x.account, &x.places, &x.cells, v, v));
        try testing.expect(try sh.eq(gpa, &x.account, &x.places, &x.cells, v, v));
        _ = try sh.widen(gpa, &x.account, &x.places, &x.cells, v);
        var two = [_]NodeId{ v, a };
        _ = try sh.join(gpa, &x.account, &x.places, &x.cells, &two);
        const whole = try sh.recastWhole(gpa, &x.account, sets, x.t_place, v);
        _ = try sh.cellsOf(gpa, &x.account, sets, whole);
        _ = try x.conds.kappaOf(gpa, x.env().charge, x.env().view(), applied.result.kappa, v, false);
        _ = try x.conds.deep(gpa, x.env().charge, x.env().view(), applied.result.kappa, v, false);
        // The view as an actual: a callee relying on `sep(π0, π1)`, applied
        // to `(v, a)`, is refused, `v` being `a`; one answering a node over
        // `π0` holds `a`'s cells.
        const p1 = try x.cells.symbolic(gpa, &x.account, &x.places, .param, 1, try x.places.rootPath(gpa, L), 0);
        const g = try x.sums.add(x.env(), .{ .params = &.{ .none, .none }, .res = try x.site(90, x.t_place), .kappas = .none, .xreq = try x.conds.flat(gpa, x.env().charge, try x.conds.sepAtom(gpa, x.env().charge, p0, p1)) });
        var s1: Scratch = .{};
        defer s1.deinit(gpa);
        const ga = try apply(x.env(), &x.sums, g, &.{ .{ .node = v, .kappa = applied.result.kappa }, .{ .node = a, .kappa = ak } }, 1, &s1);
        try testing.expect(Cond.Table.fails(try x.conds.resolved(gpa, x.env().charge, ga.xreq)));
        const h = try x.sums.add(x.env(), .{ .params = &.{.none}, .res = try x.shapes.node(gpa, &x.account, L, p0_set, try x.one(Place.Step.elem, try x.site(27, x.t_place))), .kappas = .none });
        var s2: Scratch = .{};
        defer s2.deinit(gpa);
        const ha = try apply(x.env(), &x.sums, h, &.{.{ .node = v, .kappa = applied.result.kappa }}, 2, &s2);
        try testing.expectEqual(cells, try sh.cellsOf(gpa, &x.account, sets, ha.result.node));
    }
}

test "#1335: Holders' closure of a view of a cycle with no node on it ends at its least fixed point" {
    // #1314's knot `U = union(leaf{π0}, delta(U, {[*]: site}))` (and its
    // sides swapped) applied to a list `a` whose `[*]` is `e`: a holder's
    // value that is the view. Its closure for `a`'s own cell holds it, with
    // no state to descend; for `e`'s cell it descends `a` alone, one of
    // several (the union's), and holds nothing at the root. The view, its
    // union answer and the delta side, all on the cycle, answer the same.
    // Each read is bounded by the allowance, so a closure that does not end
    // fails fast.
    const gpa = testing.allocator;
    for ([_]bool{ false, true }) |swap| {
        var x: KnotFixture = .{};
        try x.init();
        defer x.deinit();
        x.account.allowance = std.math.maxInt(u32) - 1;
        const L = x.list;
        const p0 = try x.cells.symbolic(gpa, &x.account, &x.places, .param, 0, try x.places.rootPath(gpa, L), 0);
        const p0_set = try x.cells.sets.insert(gpa, x.env().charge, .none, p0.int(), 0);
        const pleaf = try x.shapes.leaf(gpa, &x.account, L, p0_set);
        const uu = try x.shapes.knot(gpa, &x.account);
        const ud = try x.shapes.knot(gpa, &x.account);
        x.shapes.tie(ud, .{ .kind = .delta, .place = L, .cells = p0_set, .a = uu.int(), .b = try x.one(Place.Step.elem, try x.site(26, x.t_place)), .reach = .none });
        if (swap) try x.tieUnion(uu, ud, pleaf) else try x.tieUnion(uu, pleaf, ud);
        const u = try x.sums.add(x.env(), .{ .params = &.{.none}, .res = uu, .kappas = .none });
        const e = try x.site(21, x.t_place);
        const a = try listAt(&x, L, 20, e);
        var s: Scratch = .{};
        defer s.deinit(gpa);
        const v = (try apply(x.env(), &x.sums, u, &.{.{ .node = a, .kappa = .none }}, 0, &s)).result.node;
        try testing.expectEqual(Shape.Kind.view, x.shapes.kind(v));
        x.account.allowance = x.account.growth + 1_000_000;
        const sh = &x.shapes;
        const fu = try sh.force(gpa, &x.account, v);
        const side = try sh.force(gpa, &x.account, .from(if (swap) sh.get(fu).a else sh.get(fu).b));
        try testing.expectEqual(v.int(), sh.get(side).a);
        var ai = x.cells.sets.iterate(sh.cells(a));
        const xa: Cell.CellId = .from(ai.next().?.key);
        var ei = x.cells.sets.iterate(sh.cells(e));
        const xe: Cell.CellId = .from(ei.next().?.key);
        var kids: std.ArrayList(NodeId) = .empty;
        defer kids.deinit(gpa);
        for ([_]NodeId{ v, fu, side }) |n| {
            kids.clearRetainingCapacity();
            const root = try Holders.closureOf(x.env(), n, xa, xa, &kids);
            try testing.expect(root.any);
            try testing.expectEqual(@as(usize, 0), kids.items.len);
            const elem = try Holders.closureOf(x.env(), n, xe, xe, &kids);
            try testing.expect(!elem.any);
            try testing.expectEqualSlices(NodeId, &.{a}, kids.items);
        }
    }
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
    defer g.deinit();
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
        defer g.deinit();
        const seed = (try x.conds.kappaSet(gpa, x.env().charge, .none, lf, Cond.yes)).ctx;
        try testing.expectEqual(try linkByRootPaths(&g, seed, root), try g.linkArgs(seed, root));
    }
}

test "#1146: a chain of knots as deep as the source is linked on a small stack" {
    // The tables are built here; only the link walk runs on the small stack.
    const gpa = testing.allocator;
    const x = try gpa.create(KnotFixture);
    defer gpa.destroy(x);
    x.* = .{};
    try x.init();
    defer x.deinit();
    x.account.allowance = std.math.maxInt(u32) - 1;
    const lf = try x.site(7, x.t_place);
    const root = try linkChain(x, 1_024, true, lf);
    var s: Scratch = .{};
    defer s.deinit(gpa);
    const label = try x.cells.label(gpa, &x.account, 0, .none, false);
    var g: Grafter = .{ .env = x.env(), .sums = &x.sums, .args = &.{.{ .node = lf, .kappa = try linkArgKappa(x, lf) }}, .label = label, .s = &s };
    defer g.deinit();
    var result: anyerror!Cond.Kappas = .none;
    const th = try std.Thread.spawn(.{ .stack_size = 64 << 10 }, struct {
        fn run(gr: *Grafter, r: NodeId, out: *anyerror!Cond.Kappas) void {
            out.* = gr.linkArgs(.none, r);
        }
    }.run, .{ &g, root, &result });
    th.join();
    try testing.expect(try result != .none);
}

/// #1146's chain as a class's `res`, applied (`ownership-v2.md` §8 S3b
/// slice 5d2): the records `apply` spends answering its view and linking
/// the argument's snapshot, and a κ read of the answer (`kappaOf`). No
/// `Grafter` is built by hand: this is the path every call takes. The
/// answer's `deep` read is not counted here: it is quadratic on this chain,
/// with or without the view (#1488).
fn applyChainCost(n: usize, params: bool) !u64 {
    const gpa = testing.allocator;
    const x = try gpa.create(KnotFixture);
    defer gpa.destroy(x);
    x.* = .{};
    try x.init();
    defer x.deinit();
    x.account.allowance = std.math.maxInt(u32) - 1;
    const lf = try x.site(7, x.t_place);
    const root = try linkChain(x, n, params, lf);
    const c = try x.sums.add(x.env(), .{ .params = &.{.none}, .res = root, .kappas = .none });
    const arg: Value = .{ .node = lf, .kappa = try linkArgKappa(x, lf) };
    var s: Scratch = .{};
    defer s.deinit(gpa);
    const before = x.account.total();
    const v = (try apply(x.env(), &x.sums, c, &.{arg}, 1, &s)).result;
    try testing.expectEqual(Shape.Kind.view, x.shapes.kind(v.node));
    try testing.expect(v.kappa != .none);
    _ = try x.conds.kappaOf(gpa, x.env().charge, x.env().view(), v.kappa, v.node, false);
    return x.account.total() - before;
}

test "#1146: the chain of knots applied as a class, its view linked and read, costs each knot its own records" {
    // The count of `linkArgs` above, on the path `apply` takes since the
    // call view (§2.11): 197 / 799 / 3 429 / 14 891 / 64 561 records at
    // 4 … 1 024 knots (254 … 89 186 with parameters).
    for ([_]bool{ false, true }) |params| {
        const sizes = [_]usize{ 4, 16, 64, 256, 1_024 };
        var cost: [5]u64 = undefined;
        for (sizes, 0..) |n, i| cost[i] = try applyChainCost(n, params);
        // Four times the knots, about four times the records (n log n at
        // most), never sixteen; and at most about 1.7 times the most
        // measured per knot (63, 87 with parameters), so a doubled
        // constant fails too.
        const per: u64 = if (params) 150 else 110;
        for (1..5) |i| if (cost[i] > 6 * cost[i - 1] or cost[i] > per * sizes[i]) {
            std.debug.print("params {}: {any}\n", .{ params, cost });
            return error.TestUnexpectedResult;
        };
    }
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
    defer g.deinit();
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
    defer g.deinit();
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
        // The class relies on `excl π1·.arg[*]⟲.arg`: every kids list below the
        // root's first return exclusive. That return's value: `T{arg: L0}`, `L0[*] = [ T{arg: K}, T{arg:
        // L2} ]`, `L2[*] = T{arg: K or K′}` — one kids list at two depths, or
        // two distinct ones. No single path of the actual holds K twice.
        const root = try x.places.rootPath(gpa, x.t_place);
        // Below the root's first return, a plain path since #1253 (the
        // actual below is the old one as that return's value).
        const first = (try x.places.extend(gpa, .growth(&x.account), (try x.places.extend(gpa, .growth(&x.account), root, x.arg)).?, Place.Step.elem)).?;
        try testing.expect(x.places.pathStep(first).kind != .level);
        const down = (try x.places.extend(gpa, .growth(&x.account), (try x.places.extend(gpa, .growth(&x.account), first, x.arg)).?, Place.Step.elem)).?;
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
        const value = try tOf(&x, l0);
        const lw = try listOf(&x, 5, value);
        const arg = try tOf(&x, lw);
        // The actual's own snapshot: every built node `yes` where it stands.
        const e = Place.Step.elem;
        const at = [_]struct { n: NodeId, p: []const Step }{
            .{ .n = arg, .p = &.{} },                              .{ .n = lw, .p = &.{x.arg} },
            .{ .n = value, .p = &.{ x.arg, e } },                  .{ .n = l0, .p = &.{ x.arg, e, x.arg } },
            .{ .n = t1, .p = &.{ x.arg, e, x.arg, e } },           .{ .n = t2, .p = &.{ x.arg, e, x.arg, e } },
            .{ .n = k, .p = &.{ x.arg, e, x.arg, e, x.arg } },     .{ .n = l2, .p = &.{ x.arg, e, x.arg, e, x.arg } },
            .{ .n = t3, .p = &.{ x.arg, e, x.arg, e, x.arg, e } }, .{ .n = k2, .p = &.{ x.arg, e, x.arg, e, x.arg, e, x.arg } },
        };
        var ak: Cond.Kappas = .none;
        for (at) |q| ak = try x.conds.kappaSetAt(gpa, x.env().charge, ak, q.p, q.n, Cond.yes);
        var s: Scratch = .{};
        defer s.deinit(gpa);
        const applied = try apply(x.env(), &x.sums, c, &.{.{ .node = arg, .kappa = ak }}, 0, &s);
        try testing.expectEqual(repeat, Cond.Table.fails(try x.conds.resolved(gpa, x.env().charge, applied.xreq)));
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
    return x.conds.resolved(testing.allocator, x.env().charge, (try apply(x.env(), &x.sums, c, &.{.{ .node = arg, .kappa = ak }}, 0, &s)).xreq);
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
        // Each probe's value is the root's first return, a plain path since
        // #1253: every template takes one more trip around the cycle, so it
        // folds below that value as it folded below the root before.
        const got: CondId = switch (probe) {
            // A choice (0) or a union (1) in a field, `k` inside one arm and
            // beside it: `T [ T (if c then [T k] else []), T k ]`.
            0, 1 => blk: {
                const arm = try listAt(&x, L, 2, try ctorOf(&x, T, x.arg, k));
                const none_arm = try listAt(&x, L, 3, null);
                const field = if (probe == 0) try x.shapes.choice(gpa, &x.account, &x.cells.sets, arm, none_arm) else try x.shapes.@"union"(gpa, &x.account, &x.cells.sets, arm, none_arm);
                const l0 = try listAt(&x, L, 4, try x.shapes.collect(gpa, &x.account, &x.cells.sets, &.{ try ctorOf(&x, T, x.arg, field), try ctorOf(&x, T, x.arg, k) }));
                break :blk try foldProbe(&x, T, &.{ x.arg, e, x.arg, e, x.arg }, try ctorOf(&x, T, x.arg, try listAt(&x, L, 90, try ctorOf(&x, T, x.arg, l0))));
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
                break :blk try foldProbe(&x, A, &.{ a0, e, c0, e, a0, e, c0, e, a0 }, try ctorOf(&x, A, a0, try listAt(&x, LC, 91, try ctorOf(&x, C, c0, try listAt(&x, LA, 92, root)))));
            },
            // A prefix through `[*]`: `R2 [ T k, T [T k] ]`, q = `0·[*]·⟲·arg`.
            3 => blk: {
                const R2 = try x.places.of(gpa, &x.account, src, 6);
                const LT = try x.places.of(gpa, &x.account, src, 7);
                const r0 = try x.places.ctorStep(gpa, &x.account, 3, 0);
                const t2 = try ctorOf(&x, T, x.arg, try listAt(&x, L, 2, try ctorOf(&x, T, x.arg, k)));
                const w1 = try ctorOf(&x, T, x.arg, try listAt(&x, L, 90, try ctorOf(&x, T, x.arg, k)));
                const w2 = try ctorOf(&x, T, x.arg, try listAt(&x, L, 91, t2));
                const root = try ctorOf(&x, R2, r0, try listAt(&x, LT, 3, try x.shapes.collect(gpa, &x.account, &x.cells.sets, &.{ w1, w2 })));
                break :blk try foldProbe(&x, R2, &.{ r0, e, x.arg, e, x.arg, e, x.arg }, root);
            },
            // A symbolic leaf: the caller's own parameter as a kids list, its
            // projections below it out of the walk's sight.
            4 => blk: {
                const q = try x.cells.symbolic(gpa, &x.account, &x.places, .param, 7, try x.places.rootPath(gpa, L), 0);
                const ql = try x.shapes.leaf(gpa, &x.account, L, try x.cells.sets.insert(gpa, x.env().charge, .none, q.int(), 0));
                const l0 = try listAt(&x, L, 2, try x.shapes.collect(gpa, &x.account, &x.cells.sets, &.{ try ctorOf(&x, T, x.arg, ql), try ctorOf(&x, T, x.arg, k) }));
                break :blk try foldProbe(&x, T, &.{ x.arg, e, x.arg, e, x.arg }, try ctorOf(&x, T, x.arg, try listAt(&x, L, 90, try ctorOf(&x, T, x.arg, l0))));
            },
            // Control: an opened choice at the re-entry, `k` in one arm alone.
            else => blk: {
                const l0 = try listAt(&x, L, 2, try x.shapes.choice(gpa, &x.account, &x.cells.sets, try ctorOf(&x, T, x.arg, k), try ctorOf(&x, T, x.arg, try listAt(&x, L, 3, null))));
                break :blk try foldProbe(&x, T, &.{ x.arg, e, x.arg, e, x.arg }, try ctorOf(&x, T, x.arg, try listAt(&x, L, 90, try ctorOf(&x, T, x.arg, l0))));
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
        const applied = try apply(x.env(), &x.sums, c, &.{.{ .node = arg, .kappa = .none }}, 0, &s);
        // The conditions are instantiated when read (§2.11, part 3): every
        // entry of the result's κ and the `xreq` resolved, what that makes counted.
        const before = x.shapes.count();
        _ = try x.conds.resolved(gpa, x.env().charge, applied.xreq);
        var it = x.conds.kappaHere(x.conds.kappaChild(applied.result.kappa, e));
        while (it.next()) |en| _ = try x.conds.resolved(gpa, x.env().charge, en.cond);
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

/// `B [ arg ] []`: `arg` as the first return to `B` below a root, so a
/// template `.0[*]·t` reads `t` below `arg` as `t` read below a root did
/// before the first return stayed a plain path (#1253).
fn wrapB(x: *KnotFixture, arg: NodeId, ids: *u32) !NodeId {
    return bOf(x, try bList(x, nextId(ids), &.{arg}), try bList(x, nextId(ids), &.{}));
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
        // Template `π0·.0[*]⟲·.0` (B's `.0` lists at depth ≥ 1 below the
        // probe's value `arg`, which `wrapB` makes the root's first return,
        // a plain path since #1253), from `.0[*]·.0[*]·.0`.
        const steps = [_]Step{ b0, e, b0, e, b0 };
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
        const got = try foldProbe(&x, B, &steps, try wrapB(&x, arg, &ids));
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
        const value = try x.shapes.node(gpa, &x.account, W, .none, outer_over);
        // Below the root's first return, a plain path since #1253: `W [value] …`.
        var root_over = try x.shapes.overPut(gpa, &x.account, Ids.none_int, w0, try listAt(&x, LW, 400, value));
        for (1..65) |i| root_over = try x.shapes.overPut(gpa, &x.account, root_over, try x.places.ctorStep(gpa, &x.account, 5, @intCast(i)), try listAt(&x, LI, @intCast(500 + i), null));
        const arg = try x.shapes.node(gpa, &x.account, W, .none, root_over);
        // A class relying on `excl π1·#W.0[*]⟲·fₖ` for `paths` fields under one prefix.
        var xreq: CondId = Cond.yes;
        for (1..paths + 1) |i| {
            var p = try x.places.rootPath(gpa, W);
            for ([_]Step{ w0, e, w0, e, try x.places.ctorStep(gpa, &x.account, 5, @intCast(i)) }) |s| p = (try x.places.extend(gpa, .growth(&x.account), p, s)).?;
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
        try testing.expect(!Cond.Table.fails(try x.conds.resolved(gpa, x.env().charge, applied.xreq)));
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
    // Read below the root's first return (`wrapB`, #1253): `.0[*]` is `arg`.
    const root = try x.places.rootPath(gpa, B);
    var q = root;
    for ([_]Step{ b0, e, b0, e, b0 }) |s| q = (try x.places.extend(gpa, .growth(&x.account), q, s)).?;
    var r = root;
    for ([_]Step{ b0, e, b1, e, b0 }) |s| r = (try x.places.extend(gpa, .growth(&x.account), r, s)).?;
    try testing.expect(q == r); // both depth-1 `.0` lists below `arg`: one key, `.0[*]⟲·.0`
    const pre = try preimage(x.env(), try wrapB(&x, arg, &ids), root);
    try testing.expectEqual(Cond.lost, try x.conds.classesRead(gpa, x.env().charge, &x.cells, &x.places, pre, q.int()));
    // Above the cycle: `arg`'s own `.1` list once.
    var top = root;
    for ([_]Step{ b0, e, b1 }) |s| top = (try x.places.extend(gpa, .growth(&x.account), top, s)).?;
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
        // Below the root's first return, a plain path since #1253.
        const middle = try foldProbe(&x, T, &.{ x.arg, e, x.arg, e, x.arg }, try ctorOf(&x, T, x.arg, try listAt(&x, x.list, 3, middle_arg)));
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
        try testing.expectEqual(shared_list, Cond.Table.fails(try x.conds.resolved(gpa, x.env().charge, applied.xreq)));
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
        try testing.expectEqual(shared_list, Cond.Table.fails(try x.conds.resolved(gpa, x.env().charge, applied.xreq)));
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
        // Below the root's first return (`wrapB`, #1253).
        var ids: u32 = 40;
        const steps = [_]Step{ b0, e, b0, e, b0 };
        const want = try foldProbe(&x, B, &steps, try wrapB(&x, eager, &ids));
        try testing.expectEqual(if (probe == 0) Cond.lost else Cond.yes, want);
        try testing.expectEqual(want, try foldProbe(&x, B, &steps, try wrapB(&x, v, &ids)));
    }
}

test "a chain of 400 calls is read and its conditions resolved at its end on a small stack (#1130)" {
    // `ownership-v2.md` §2.11 *κ across a call*: `x_k = f x_{k-1}`, `f x`'s
    // result the join of `x` and a fresh cell, its κ `excl π1` there. The
    // last value is read only at the end: the read walks 400 views below
    // views and resolves 400 conditions in creation order, each on the
    // explicit stack: 64 KiB is 160 bytes a call, far below a native frame
    // per call in any build.
    const gpa = testing.allocator;
    const x = try gpa.create(KnotFixture);
    defer gpa.destroy(x);
    x.* = .{};
    try x.init();
    defer x.deinit();
    x.account.allowance = std.math.maxInt(u32) - 1;
    const p = try x.cells.symbolic(gpa, &x.account, &x.places, .param, 0, try x.places.rootPath(gpa, x.t_place), 0);
    const site = try x.cells.site(gpa, &x.account, 1, x.t_place, .record);
    const res = try x.shapes.leaf(gpa, &x.account, x.t_place, try x.cells.sets.insert(gpa, x.env().charge, try x.cells.sets.insert(gpa, x.env().charge, .none, p.int(), 0), site.int(), 0));
    const km = (try x.conds.kappaSet(gpa, x.env().charge, .none, res, try x.conds.excl(gpa, x.env().charge, p))).ctx;
    const c = try x.sums.add(x.env(), .{ .params = &.{.none}, .res = res, .kappas = km });
    var v: Value = .{ .node = try x.site(2, x.t_place) };
    v.kappa = (try x.conds.kappaSet(gpa, x.env().charge, .none, v.node, Cond.yes)).ctx;
    for (0..400) |i| {
        var s: Scratch = .{};
        defer s.deinit(gpa);
        v = (try apply(x.env(), &x.sums, c, &.{v}, @intCast(i + 1), &s)).result;
    }
    const Read = struct {
        fn run(f: *KnotFixture, at: Value, out: *anyerror!CondId) void {
            out.* = blk: {
                const k = f.conds.kappaOf(testing.allocator, f.env().charge, f.env().view(), at.kappa, at.node, false) catch |e| break :blk e;
                _ = f.conds.deep(testing.allocator, f.env().charge, f.env().view(), at.kappa, at.node, false) catch |e| break :blk e;
                break :blk k;
            };
        }
    };
    var result: anyerror!CondId = Cond.yes;
    const th = try std.Thread.spawn(.{ .stack_size = 64 << 10 }, Read.run, .{ x, v, &result });
    th.join();
    const k = try result;
    // Resolved: what a reader tests holds no `inst` atom.
    try x.conds.assertResolved(gpa, x.env().charge, k);
    try testing.expect(!Cond.Table.fails(k));
}

test "#1219: an actual below a level stands for a value inside it, so its sep and its image read its reach" {
    // `f` answers `π0·arg·[*]·arg·⟲·arg`; applied to `a = T [ T [ L22 [ T k ] ] ]` its
    // result is a whole recast of `a` at `L`, standing for `k` (or the list
    // around it). `g` relies on `sep(π0, π1)` and is applied to `(f a, k)`:
    // the recast's inner holds no list cell, so reading its own cells said
    // `yes`. It stands for a value inside `a`, which may be `k`: refused, and
    // so when the recast is one side of a union or a choice (`if c then f a
    // else xs`), or the base of a delta (`f a` with an element written), or
    // that delta a side of a union. A separate list accepts. `h` answers a
    // node over `π0`; applied to any of the recast actuals, its image holds
    // `k`, approximately, and so does `u`'s, whose result is a knot
    // `U = union(leaf{π0}, delta(U, {[*]: site}))`: a view of it reads its
    // cycle's cells as their least fixed point (§2.11, #1314).
    const gpa = testing.allocator;
    for (0..6) |kind| {
        var x: KnotFixture = .{};
        try x.init();
        defer x.deinit();
        x.account.allowance = std.math.maxInt(u32) - 1;
        const T = x.t_place;
        const L = x.list;
        const root = try x.places.rootPath(gpa, L);
        const p0 = try x.cells.symbolic(gpa, &x.account, &x.places, .param, 0, root, 0);
        const p1 = try x.cells.symbolic(gpa, &x.account, &x.places, .param, 1, root, 0);
        const sep = try x.conds.sepAtom(gpa, x.env().charge, p0, p1);
        const g = try x.sums.add(x.env(), .{ .params = &.{ .none, .none }, .res = try x.site(90, T), .kappas = .none, .xreq = try x.conds.flat(gpa, x.env().charge, sep) });
        const k = try listAt(&x, L, 20, null);
        // `a`'s value below the root's first return, a plain path since #1253.
        const a = try ctorOf(&x, T, x.arg, try listAt(&x, L, 21, try ctorOf(&x, T, x.arg, try listAt(&x, L, 22, try ctorOf(&x, T, x.arg, k)))));
        // `f`: its result is `π0` at `arg·[*]·arg·⟲·arg`.
        var fp = try x.places.rootPath(gpa, T);
        for ([_]Step{ x.arg, Place.Step.elem, x.arg, Place.Step.elem, x.arg }) |st| fp = (try x.places.extend(gpa, .growth(&x.account), fp, st)).?;
        const fcell = try x.cells.symbolic(gpa, &x.account, &x.places, .param, 0, fp, 0);
        const f = try x.sums.add(x.env(), .{ .params = &.{.none}, .res = try x.shapes.leaf(gpa, &x.account, L, try x.cells.sets.insert(gpa, x.env().charge, .none, fcell.int(), 0)), .kappas = .none });
        var sf: Scratch = .{};
        defer sf.deinit(gpa);
        const fa = try x.shapes.force(gpa, &x.account, (try apply(x.env(), &x.sums, f, &.{.{ .node = a, .kappa = .none }}, 0, &sf)).result.node);
        try testing.expect(x.shapes.isWhole(fa));
        const other = try listAt(&x, L, 23, null);
        const written = try x.shapes.delta(gpa, &x.account, fa, try x.one(Place.Step.elem, try x.site(24, T)));
        const first = switch (kind) {
            0 => other,
            1 => fa,
            2 => try x.shapes.@"union"(gpa, &x.account, &x.cells.sets, fa, other),
            3 => try x.shapes.choice(gpa, &x.account, &x.cells.sets, fa, other),
            4 => written,
            else => try x.shapes.@"union"(gpa, &x.account, &x.cells.sets, written, other),
        };
        var s: Scratch = .{};
        defer s.deinit(gpa);
        const applied = try apply(x.env(), &x.sums, g, &.{ .{ .node = first, .kappa = .none }, .{ .node = k, .kappa = .none } }, 0, &s);
        try testing.expectEqual(kind != 0, Cond.Table.fails(try x.conds.resolved(gpa, x.env().charge, applied.xreq)));
        // `h`'s result is a node at `L` whose object is `π0`.
        const p0_set = try x.cells.sets.insert(gpa, x.env().charge, .none, p0.int(), 0);
        const h = try x.sums.add(x.env(), .{ .params = &.{.none}, .res = try x.shapes.node(gpa, &x.account, L, p0_set, try x.one(Place.Step.elem, try listAt(&x, L, 25, null))), .kappas = .none });
        // `u`'s result is a knot: `U = union(leaf{π0}, D)`,
        // `D = delta(U, {[*]: site})`.
        const uu = try x.shapes.knot(gpa, &x.account);
        const ud = try x.shapes.knot(gpa, &x.account);
        x.shapes.tie(ud, .{ .kind = .delta, .place = L, .cells = p0_set, .a = uu.int(), .b = try x.one(Place.Step.elem, try x.site(26, T)), .reach = .none });
        try x.tieUnion(uu, try x.shapes.leaf(gpa, &x.account, L, p0_set), ud);
        const u = try x.sums.add(x.env(), .{ .params = &.{.none}, .res = uu, .kappas = .none });
        var it = x.cells.sets.iterate(x.shapes.cells(k));
        const kc = it.next().?.key;
        for ([_]ClassId{ h, u }) |c| {
            var s2: Scratch = .{};
            defer s2.deinit(gpa);
            const image = try apply(x.env(), &x.sums, c, &.{.{ .node = first, .kappa = .none }}, 0, &s2);
            // Bounded: a read that does not end exhausts the allowance.
            x.account.allowance = x.account.growth + 1_000_000;
            const cells = try x.shapes.cellsOf(gpa, &x.account, &x.cells.sets, image.result.node);
            x.account.allowance = std.math.maxInt(u32) - 1;
            try testing.expectEqual(kind != 0, x.cells.sets.member(cells, kc));
        }
    }
}

test "a view's cells through a level free the grafter's memos, however far a limit lets it get" {
    // `π0` at `arg·[*]·arg·⟲·arg` read through a view's grafter
    // (`Views.cellsImage`) reaches `foldedCells`, whose memos the testing
    // allocator must see freed (#1391). Read again with the allowance
    // `extra` records past the start, the read stops at each reservation in
    // turn, and a walk stopped by its limit frees what it allocated (#1381).
    const gpa = testing.allocator;
    for ([_]u32{ 0, 1, 2, 3, 4, 6, 9, 14, 30, std.math.maxInt(u32) - 1 }) |extra| {
        var x: KnotFixture = .{};
        try x.init();
        defer x.deinit();
        x.account.allowance = std.math.maxInt(u32) - 1;
        const T = x.t_place;
        const L = x.list;
        const k = try listAt(&x, L, 20, null);
        const a = try ctorOf(&x, T, x.arg, try listAt(&x, L, 21, try ctorOf(&x, T, x.arg, try listAt(&x, L, 22, try ctorOf(&x, T, x.arg, k)))));
        var fp = try x.places.rootPath(gpa, T);
        for ([_]Step{ x.arg, Place.Step.elem, x.arg, Place.Step.elem, x.arg }) |st| fp = (try x.places.extend(gpa, .growth(&x.account), fp, st)).?;
        const fcell = try x.cells.symbolic(gpa, &x.account, &x.places, .param, 0, fp, 0);
        const label = try x.cells.label(gpa, &x.account, 0, .none, false);
        const env_id = try x.views.add(x.env(), .from(0), &.{.{ .node = a }}, label);
        const template = try x.shapes.leaf(gpa, &x.account, L, try x.cells.sets.insert(gpa, x.env().charge, .none, fcell.int(), 0));
        x.account.allowance = @intCast(@min(@as(u64, x.account.growth) + extra, std.math.maxInt(u32) - 1));
        _ = Views.cellsImage(&x.views, &x.shapes, gpa, &x.account, env_id, x.shapes.cells(template), L) catch |err| {
            try testing.expectEqual(error.OwnershipLimit, err);
            try testing.expect(extra != std.math.maxInt(u32) - 1);
        };
    }
}

/// A class whose `res` is `joinRes(a, ka, b, kb)`, applied with no
/// argument, and κ at `[*]` read through the call's view as a caller reads
/// it, beside the same read in the class itself (#1399).
fn joinedElemThroughCall(x: *KnotFixture, a: NodeId, ka: Cond.Kappas, b: NodeId, kb: Cond.Kappas) !struct { class: CondId, caller: CondId } {
    const gpa = testing.allocator;
    const env = x.env();
    const e = Place.Step.elem;
    const j = try Summary.Table.joinRes(env, a, ka, b, kb, .choice);
    const class_k = try x.conds.kappaOf(gpa, env.charge, env.view(), x.conds.kappaChild(j.kappas, e), (try x.shapes.proj(gpa, &x.account, &x.places, &x.cells, j.node, e)).?, true);
    const c = try x.sums.add(env, .{ .params = &.{}, .res = j.node, .kappas = j.kappas });
    var s: Scratch = .{};
    defer s.deinit(gpa);
    const r = (try apply(env, &x.sums, c, &.{}, 1, &s)).result;
    const child = (try x.shapes.proj(gpa, &x.account, &x.places, &x.cells, r.node, e)).?;
    const caller_k = try x.conds.kappaOf(gpa, env.charge, env.view(), x.conds.kappaChild(r.kappa, e), child, true);
    return .{ .class = class_k, .caller = caller_k };
}

fn joinList(x: *KnotFixture, site_id: u32, elem: ?NodeId) !NodeId {
    const gpa = testing.allocator;
    const c = try x.cells.site(gpa, &x.account, site_id, x.list, .list);
    const cells = try x.cells.sets.insert(gpa, x.env().charge, .none, c.int(), 0);
    const over = if (elem) |el| try x.one(Place.Step.elem, el) else Ids.none_int;
    return x.shapes.node(gpa, &x.account, x.list, cells, over);
}

test "#1399: a joined κ below a choice whose rounds intern to one arm is read through the call" {
    // GroupJoinShared's rounds: one choice `c = choice([], [x])` in both, its
    // element `x` read `yes` in round 1 and `shared` in round 2. The join
    // keys `shared` on `proj(c, [*]) = choice(nothing, x)`, which no part of
    // `c` names; a caller descends the view's arms and meets `x`.
    const gpa = testing.allocator;
    var x: KnotFixture = .{};
    try x.init();
    defer x.deinit();
    const env = x.env();
    const e = Place.Step.elem;
    const elem = try x.site(10, x.t_place);
    const choice = try x.shapes.choice(gpa, &x.account, &x.cells.sets, try joinList(&x, 11, null), try joinList(&x, 12, elem));
    const root = (try x.conds.kappaSet(gpa, env.charge, .none, choice, Cond.yes)).ctx;
    const k1 = try x.conds.kappaSetAt(gpa, env.charge, root, &.{e}, elem, Cond.yes);
    const k2 = try x.conds.kappaSetAt(gpa, env.charge, root, &.{e}, elem, Cond.shared);
    const got = try joinedElemThroughCall(&x, choice, k1, choice, k2);
    try testing.expectEqual(Cond.shared, got.class);
    try testing.expectEqual(Cond.shared, got.caller);
}

test "#1399: a joined κ keyed on an interned union below a choice is read through the call" {
    // `a = [x]` reads `yes` at `[*]`; `b`'s element is the union `u = x ∪ y`,
    // `shared` there. The join keys `shared` on `choice(x, u)`, a node no part
    // of the choice names; a caller meets `x` and `u`'s sides.
    const gpa = testing.allocator;
    var x: KnotFixture = .{};
    try x.init();
    defer x.deinit();
    const env = x.env();
    const e = Place.Step.elem;
    const ex = try x.site(10, x.t_place);
    const ey = try x.site(13, x.t_place);
    const u = try x.shapes.@"union"(gpa, &x.account, &x.cells.sets, ex, ey);
    const a = try joinList(&x, 11, ex);
    const b = try joinList(&x, 12, u);
    const ka = try x.conds.kappaSetAt(gpa, env.charge, (try x.conds.kappaSet(gpa, env.charge, .none, a, Cond.yes)).ctx, &.{e}, ex, Cond.yes);
    const kb = try x.conds.kappaSetAt(gpa, env.charge, (try x.conds.kappaSet(gpa, env.charge, .none, b, Cond.yes)).ctx, &.{e}, u, Cond.shared);
    const got = try joinedElemThroughCall(&x, a, ka, b, kb);
    try testing.expectEqual(Cond.shared, got.class);
    try testing.expectEqual(Cond.shared, got.caller);
}

const v2_mutation = @import("ownership_options").v2_mutation;

/// A test-only mutation (`-Downership-v2-mutation`, which `gates` refuses).
fn mutated(comptime which: []const u8) bool {
    return std.mem.eql(u8, v2_mutation, which);
}

const v2_switch = @import("ownership_options").v2_switch;

/// A test-only switch (`-Downership-v2-switch`, comma-separated, which
/// `gates` refuses): an order of the checker reversed on purpose.
fn switched(comptime which: []const u8) bool {
    return comptime blk: {
        var it = std.mem.splitScalar(u8, v2_switch, ',');
        while (it.next()) |s| if (std.mem.eql(u8, s, which)) break :blk true;
        break :blk false;
    };
}

test "§2.9 rule 4: a group's image through `⟲` is one join name per member, never its level paths" {
    // The read's *Cost* (#1485): an image is `extend`'s canonical path, a
    // `⟲` at a root the join name `root⟲`, and is never expanded. The root
    // join of `Tree` stands for two level paths (`#Node.0`, `#Node.2`), so an
    // expansion would double the images; for a type of many level paths it
    // multiplies them. Two members, one key: two images.
    var x: KnotFixture = .{};
    try x.init();
    defer x.deinit();
    const gpa = testing.allocator;
    const charge = x.env().charge;
    const src: Place.Source = .{ .ctx = &x.graph, .describe = TestGraph.describe };
    const tree = try x.places.of(gpa, &x.account, src, 14);
    const n1 = try x.places.ctorStep(gpa, &x.account, 6, 1);
    const root = try x.places.rootPath(gpa, tree);
    const key_path = (try x.places.extend(gpa, charge, (try x.places.extend(gpa, charge, root, Step.level)).?, n1)).?;
    const key = try x.cells.symbolic(gpa, &x.account, &x.places, .param, 0, key_path, 0);
    var members: SetId = .none;
    for ([_]u32{ 5, 6 }) |i| members = try x.cells.sets.insert(gpa, charge, members, (try x.cells.symbolic(gpa, &x.account, &x.places, .param, i, root, 0)).int(), 0);
    const args = [_]Value{.{ .node = try x.shapes.leaf(gpa, &x.account, tree, members) }};
    var s: Scratch = .{};
    defer s.deinit(gpa);
    var g: Grafter = .{ .env = x.env(), .sums = &x.sums, .args = &args, .label = .none, .s = &s };
    defer g.deinit();
    const grp = (try g.groupOf(0, key_path)).?;
    var out: std.ArrayList(Cond.Table.HypKey) = .empty;
    defer out.deinit(gpa);
    try testing.expect(try g.groupImages(key, grp, 0, &out));
    try testing.expectEqual(@as(usize, 2), out.items.len);
    // The root join stands for two level paths, so an expansion would at
    // least double the images.
    try testing.expect((try x.places.levelsOf(gpa, charge, root)).len >= 2);
    for (out.items) |h| {
        const p: PathId = .from(x.cells.get(h.image).b);
        try testing.expectEqual(Step.level.word(), x.places.pathStep(x.places.pathParent(p)).word());
    }
}

test "§2.9 rule 4 (a′): row 19's certificate reads the same in either order of its parameters" {
    // Near-miss row 19 (#1485), its certificate built directly: four keys
    // over two parameters of type `Tree`, a condition that is not `lost`.
    // `π1`'s keys `π1#Node.1` and `π1#Node.0#Node.1` are apart and image
    // through `s` to two cells; `π2`'s `π2#Node.0#Node.1` and `π2⟲#Node.1`
    // overlap and image through `l` (the caller's `π3#Node.0`) to one cell
    // `X`. Both groups have the root as their prefix, so an overlap memo
    // keyed by the prefix alone would hand one group's answer to the
    // other. Keyed by the key set, `π2`'s group is no group in either
    // order: `X` arrives twice, and the read fails.
    var x: KnotFixture = .{};
    try x.init();
    defer x.deinit();
    const gpa = testing.allocator;
    const charge = x.env().charge;
    const src: Place.Source = .{ .ctx = &x.graph, .describe = TestGraph.describe };
    const tree = try x.places.of(gpa, &x.account, src, 14);
    const n0 = try x.places.ctorStep(gpa, &x.account, 6, 0);
    const n1 = try x.places.ctorStep(gpa, &x.account, 6, 1);
    const Keys = struct {
        x: *KnotFixture,
        tree: PlaceId,
        fn cell(k: @This(), i: u32, steps: []const Step) !CellId {
            var at = try k.x.places.rootPath(testing.allocator, k.tree);
            for (steps) |s| at = (try k.x.places.extend(testing.allocator, k.x.env().charge, at, s)).?;
            return k.x.cells.symbolic(testing.allocator, &k.x.account, &k.x.places, .param, i, at, 0);
        }
    };
    const k: Keys = .{ .x = &x, .tree = tree };
    const lv = Step.level;
    const ks = [_]Cond.Table.HypKey{
        .{ .key = try k.cell(0, &.{n1}), .image = try k.cell(5, &.{n1}), .approx = false, .group = 0 },
        .{ .key = try k.cell(0, &.{ n0, n1 }), .image = try k.cell(5, &.{ n0, n1 }), .approx = false, .group = 0 },
        .{ .key = try k.cell(1, &.{ n0, n1 }), .image = try k.cell(6, &.{ n0, n0, n1 }), .approx = false, .group = 1 },
        .{ .key = try k.cell(1, &.{ lv, n1 }), .image = try k.cell(6, &.{ n0, n0, n1 }), .approx = false, .group = 1 },
    };
    try testing.expectEqual(ks[2].image, ks[3].image);
    const Fake = struct {
        keys: []const Cond.Table.HypKey,
        reversed: bool,
        res: NodeId = .none,
        fn envOf(_: *anyopaque, _: *Shape.Table, _: NodeId) ?u32 {
            return null;
        }
        fn classOf(ctx: *anyopaque, _: u32) Cond.Table.HypClass {
            const f: *@This() = @ptrCast(@alignCast(ctx));
            return .{ .res = f.res, .kappas = .none };
        }
        fn keysOf(ctx: *anyopaque, gpa_: Allocator, _: Ids.Charge, _: u32, _: SetId, out: *std.ArrayList(Cond.Table.HypKey)) Error!void {
            const f: *@This() = @ptrCast(@alignCast(ctx));
            for (0..f.keys.len) |i| try out.append(gpa_, f.keys[if (f.reversed) f.keys.len - 1 - i else i]);
        }
    };
    var own: SetId = .none;
    for (ks) |h| own = try x.cells.sets.insert(gpa, charge, own, h.key.int(), 0);
    const tn = try x.shapes.leaf(gpa, &x.account, tree, own);
    var reads: [2]CondId = undefined;
    for (0..2) |order| {
        var fake: Fake = .{ .keys = &ks, .reversed = order == 1, .res = tn };
        x.conds.hyp = .{ .ctx = &fake, .envOf = Fake.envOf, .keys = Fake.keysOf, .class = Fake.classOf };
        defer x.conds.hyp = null;
        var keys: std.ArrayList(Cond.Table.HypKey) = .empty;
        defer keys.deinit(gpa);
        var merged: Ids.FixedDict(2) = .{};
        defer merged.deinit(gpa);
        const a = try x.conds.certClassAgg(gpa, charge, x.env().view(), 0, tn, &keys, &merged);
        // `X` is a repeat, and the images through `s` are not.
        try testing.expect(x.cells.sets.member(a.dups, ks[2].image.int()));
        try testing.expect(!x.cells.sets.member(a.dups, ks[0].image.int()));
        try testing.expect(!x.cells.sets.member(a.dups, ks[1].image.int()));
        reads[order] = try x.conds.canonical(gpa, charge, try x.conds.certRead(gpa, charge, x.env().view(), 0, tn, &.{}));
    }
    try testing.expectEqual(reads[0], reads[1]);
    try testing.expect(Cond.Table.fails(reads[0]));
}

test "§2.9 rule 4 across the classes of one certificate: cases (i)–(vii), each through the class-sum check" {
    // #1559: certificates of two classes built directly, as `ruleFourAgg`'s
    // input at one caller class. Keys are `π0` paths of `Tree`, images the
    // caller's `π5` cells. Each case lands two classes there, so under
    // `runtime_safety` `Cond.assertClassesSum` recounts it and must agree.
    var x: KnotFixture = .{};
    try x.init();
    defer x.deinit();
    const gpa = testing.allocator;
    const charge = x.env().charge;
    const src: Place.Source = .{ .ctx = &x.graph, .describe = TestGraph.describe };
    const tree = try x.places.of(gpa, &x.account, src, 14);
    const n0 = try x.places.ctorStep(gpa, &x.account, 6, 0);
    const n1 = try x.places.ctorStep(gpa, &x.account, 6, 1);
    const n2 = try x.places.ctorStep(gpa, &x.account, 6, 2);
    const lv = Step.level;
    const Keys = struct {
        x: *KnotFixture,
        tree: PlaceId,
        fn cell(k: @This(), i: u32, steps: []const Step) !CellId {
            var at = try k.x.places.rootPath(testing.allocator, k.tree);
            for (steps) |s| at = (try k.x.places.extend(testing.allocator, k.x.env().charge, at, s)).?;
            return k.x.cells.symbolic(testing.allocator, &k.x.account, &k.x.places, .param, i, at, 0);
        }
    };
    const k: Keys = .{ .x = &x, .tree = tree };
    // `same`'s four apart keys, and row 22's overlapping pair.
    const a0 = try k.cell(0, &.{ n0, n1 });
    const a1 = try k.cell(0, &.{ n0, lv, n1 });
    const b0 = try k.cell(0, &.{ n2, n1 });
    const b1 = try k.cell(0, &.{ n2, lv, n1 });
    const ys = a0;
    const join = try k.cell(0, &.{ lv, n1 });
    const root = try k.cell(0, &.{n1});
    const X = try k.cell(5, &.{ n0, n1 });
    const Y = try k.cell(5, &.{ n2, n1 });
    const X2 = try k.cell(5, &.{ n0, lv, n1 });
    const CK = Cond.Table.ClassKey;
    const key = struct {
        fn of(kk: CellId, img: CellId, group: u32, class: u32) CK {
            return .{ .k = .{ .key = kk, .image = img, .approx = false, .group = group }, .class = class };
        }
    }.of;
    const Want = struct { dups: []const CellId, once: []const CellId, excl: []const CellId };
    const Case = struct { keys: []const CK, want: Want };
    const cases = [_]Case{
        // (i) the sum: one key in two classes is a repeat.
        .{ .keys = &.{ key(root, X, 0, 0), key(root, X, 0, 1) }, .want = .{ .dups = &.{X}, .once = &.{}, .excl = &.{} } },
        // (ii) `L` in the group: two occurrences of one object are two
        // groups, and they add.
        .{ .keys = &.{ key(a0, X, 0, 0), key(b0, X, 1, 1) }, .want = .{ .dups = &.{X}, .once = &.{}, .excl = &.{} } },
        // (iii) (a′) on the union: row 22's pair over two classes overlaps,
        // so the group is no group and its image is a repeat.
        .{ .keys = &.{ key(ys, X, 0, 0), key(join, X, 0, 1) }, .want = .{ .dups = &.{X}, .once = &.{}, .excl = &.{} } },
        // (iv) the precision: four apart keys over two classes, one image
        // once with `exclOf`.
        .{ .keys = &.{ key(a0, X, 0, 0), key(a1, X, 0, 0), key(b0, X, 0, 1), key(b1, X, 0, 1) }, .want = .{ .dups = &.{}, .once = &.{X}, .excl = &.{X} } },
        // (v) (i) with (iv), in both orders of arrival.
        .{ .keys = &.{ key(a0, X, 0, 0), key(a1, X, 0, 0), key(a0, X, 0, 1) }, .want = .{ .dups = &.{X}, .once = &.{}, .excl = &.{X} } },
        .{ .keys = &.{ key(a1, X, 0, 0), key(a0, X, 0, 0), key(a0, X, 0, 1) }, .want = .{ .dups = &.{X}, .once = &.{}, .excl = &.{X} } },
        // (vi) the skip inside a class: one key at `X` through two members
        // of a union, and a second class's distinct key at `Y`.
        .{ .keys = &.{ key(a0, X, 0, 0), key(a0, X, 0, 0), key(b0, Y, 0, 1) }, .want = .{ .dups = &.{}, .once = &.{ X, Y }, .excl = &.{} } },
        // (vii) a dropped group beside a kept one at one caller class.
        .{ .keys = &.{ key(b0, Y, 0, 0), key(b1, Y, 0, 1), key(ys, X2, 1, 0), key(join, X2, 1, 1) }, .want = .{ .dups = &.{X2}, .once = &.{Y}, .excl = &.{Y} } },
    };
    for (cases, 0..) |c, ci| {
        errdefer std.debug.print("rule 4 across classes: case {d}\n", .{ci});
        const before = x.conds.classes_sum_checks;
        const a = try x.conds.ruleFourAgg(gpa, charge, x.env().view(), c.keys);
        if (std.debug.runtime_safety) try testing.expectEqual(before + 1, x.conds.classes_sum_checks);
        for (c.want.dups) |d| try testing.expect(x.cells.sets.member(a.dups, d.int()));
        for (c.want.once) |o| {
            try testing.expect(x.cells.sets.member(a.all, o.int()));
            try testing.expect(!x.cells.sets.member(a.dups, o.int()));
        }
        var want_pairs: CondId = Cond.yes;
        for (c.want.excl) |e| want_pairs = try x.conds.@"and"(gpa, charge, want_pairs, try x.conds.exclOf(gpa, charge, &x.cells, e));
        try testing.expectEqual(want_pairs, a.pairs);
    }
}

test "§2.9 rule 4: a group's id is one per (environment, i, L, node), whatever the class" {
    // #1559, case (ii)'s half: `a` at `#Node.0` and at `#Node.2` of the
    // actual `Node a ys a` are two groups; one key met again (from a second
    // class of the certificate) is the same group.
    var x: KnotFixture = .{};
    try x.init();
    defer x.deinit();
    const gpa = testing.allocator;
    const charge = x.env().charge;
    const src: Place.Source = .{ .ctx = &x.graph, .describe = TestGraph.describe };
    const tree = try x.places.of(gpa, &x.account, src, 14);
    const n0 = try x.places.ctorStep(gpa, &x.account, 6, 0);
    const n1 = try x.places.ctorStep(gpa, &x.account, 6, 1);
    const n2 = try x.places.ctorStep(gpa, &x.account, 6, 2);
    const root = try x.places.rootPath(gpa, tree);
    const list = x.places.pathPlace((try x.places.extend(gpa, charge, root, n1)).?);
    const a = try x.shapes.leaf(gpa, &x.account, tree, try x.cells.sets.insert(gpa, charge, .none, (try x.cells.symbolic(gpa, &x.account, &x.places, .param, 5, root, 0)).int(), 0));
    const ys = try x.shapes.leaf(gpa, &x.account, list, try x.cells.sets.insert(gpa, charge, .none, (try x.cells.site(gpa, &x.account, 3, list, .list)).int(), 0));
    var kids = try x.shapes.overPut(gpa, &x.account, Ids.none_int, n0, a);
    kids = try x.shapes.overPut(gpa, &x.account, kids, n1, ys);
    kids = try x.shapes.overPut(gpa, &x.account, kids, n2, a);
    const args = [_]Value{.{ .node = try x.shapes.node(gpa, &x.account, tree, .none, kids) }};
    var s: Scratch = .{};
    defer s.deinit(gpa);
    var g: Grafter = .{ .env = x.env(), .sums = &x.sums, .args = &args, .label = .none, .s = &s };
    defer g.deinit();
    const Path = struct {
        fn of(xx: *KnotFixture, r: PathId, steps: []const Step) !PathId {
            var at = r;
            for (steps) |st| at = (try xx.places.extend(testing.allocator, xx.env().charge, at, st)).?;
            return at;
        }
    };
    const k0 = try x.cells.symbolic(gpa, &x.account, &x.places, .param, 0, try Path.of(&x, root, &.{ n0, n1 }), 0);
    const k2 = try x.cells.symbolic(gpa, &x.account, &x.places, .param, 0, try Path.of(&x, root, &.{ n2, n1 }), 0);
    var groups: Ids.FixedDict(4) = .{};
    defer groups.deinit(gpa);
    var out: std.ArrayList(Cond.Table.HypKey) = .empty;
    defer out.deinit(gpa);
    try g.ruleFourKey(k0, false, 7, &groups, &out);
    try testing.expectEqual(@as(u32, 1), groups.count());
    try g.ruleFourKey(k2, false, 7, &groups, &out);
    try testing.expectEqual(@as(u32, 2), groups.count());
    // The first key again, as a second class would give it: no new group,
    // and its images carry the first one's id.
    const first = out.items.len;
    try g.ruleFourKey(k0, false, 7, &groups, &out);
    try testing.expectEqual(@as(u32, 2), groups.count());
    for (out.items[first..]) |h| if (h.group != Ids.none_int) try testing.expectEqual(out.items[0].group, h.group);
    // Another environment is another call: its own groups.
    try g.ruleFourKey(k0, false, 8, &groups, &out);
    try testing.expectEqual(@as(u32, 3), groups.count());
}

test "§2.9 rule 3: a shared image owes apart from the rest of the side it stays on" {
    // Sides {X, Z} and {X}: X is shared, stays on the first side and leaves
    // the second, so the multiset no longer pairs X (second side) with Z
    // (first side). `shareImages` must owe that pair itself; the symmetric
    // sides {X} and {X} owe only `excl X`.
    var x: KnotFixture = .{};
    try x.init();
    defer x.deinit();
    const gpa = testing.allocator;
    const charge = x.env().charge;
    const elems = (try x.places.extend(gpa, charge, try x.places.rootPath(gpa, x.list), Step.elem)).?;
    const cx = try x.cells.symbolic(gpa, &x.account, &x.places, .param, 0, elems, 0);
    const cz = try x.cells.symbolic(gpa, &x.account, &x.places, .param, 1, elems, 0);
    const sx = try x.cells.sets.insert(gpa, charge, .none, cx.int(), 0);
    const sxz = try x.cells.sets.insert(gpa, charge, sx, cz.int(), 0);
    var asym = [_]SetId{ sxz, sx };
    const got = try shareImages(&x.conds, gpa, charge, &x.cells, &x.places, &asym);
    try testing.expect(x.cells.sets.member(got.shared, cx.int()) and !x.cells.sets.member(got.shared, cz.int()));
    try testing.expectEqual(SetId.none, asym[1]);
    try testing.expect(try owesApart(&x.conds, charge, &x.cells, got.extra, cx, cz));

    var sym = [_]SetId{ sx, sx };
    const plain = try shareImages(&x.conds, gpa, charge, &x.cells, &x.places, &sym);
    try testing.expect(x.cells.sets.member(plain.shared, cx.int()));
    try testing.expect(!try owesApart(&x.conds, charge, &x.cells, plain.extra, cx, cz));
}

/// Whether `k` holds an `apart` or a `sep` over both `a` and `b`.
fn owesApart(t: *Cond.Table, charge: Ids.Charge, cells: *const Cell.Table, k: CondId, a: CellId, b: CellId) !bool {
    if (k == Cond.yes or k == Cond.lost or k == Cond.shared) return false;
    var it = t.atoms.iterate(try t.flat(testing.allocator, charge, k));
    while (it.next()) |e| {
        const d = t.get(.from(e.key));
        switch (d.atom) {
            .apart => if (cells.sets.member(.from(d.a), a.int()) and cells.sets.member(.from(d.a), b.int())) return true,
            .sep => if ((d.a == a.int() and d.b == b.int()) or (d.a == b.int() and d.b == a.int())) return true,
            else => {},
        }
    }
    return false;
}
