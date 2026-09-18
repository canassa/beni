//! Top-level value cycles (docs/design/language.md §7, §6 *Evaluation
//! order*; `checker.md` §6.7): a top-level VALUE may not be reachable from
//! its own initialiser.
//!
//! `backend.md` §5 emits top-level constants in **dependency order**, so
//! unlike a `let` there is no written-order rule to break — a constant may
//! name one written below it and the emitter puts them the right way round.
//! What dependency order cannot do is order a **cycle**: `emissionOrder`
//! falls back to source order for the members of one, and the result is a
//! JavaScript temporal dead zone. `x = y + 1` with `y = x` emits
//! `const M$y = M$x;` first and throws `ReferenceError: Cannot access 'M$x'
//! before initialization` at load, with the build exiting 0. That was the
//! defect this pass closes.
//!
//! **What counts as a cycle is initialisation, not reference.** A function
//! body runs when it is called, so mutual recursion between functions is
//! unrestricted and always was. The analysis is conservative in exactly the
//! shape `Bir.Lower.checkLetOrder` is one scope in (§7): **mentioning a
//! function counts as running it**, so a value that names a function reads
//! whatever that function's body reads; and a value whose right-hand side
//! **is a lambda** defers, because nothing runs when it is bound. So a
//! declaration is one of two things here:
//!
//!   - it **defers** — a function (`d.params != 0`), a declaration with
//!     evidence parameters (which the emitter also makes a function), or a
//!     value whose body is a `lambda`. Nothing of it runs at module load;
//!   - it **runs** — every other value with a body. Its initialiser is
//!     evaluated once, where `emissionOrder` puts it.
//!
//! A strongly connected component with at least one node that RUNS is
//! refused (`cyclic_value`); one made only of deferring nodes is fine and is
//! how `isEven`/`isOdd` are written. Those three readings are the emitter's
//! own: `js/Lower.declaration` splits on the same `params != 0`, evidence
//! and `lambda`-body triple.
//!
//! **The edges, in three legs**, and they are `js/Reach.zig`'s minus the
//! cross-module one, out of a value declaration `d`:
//!
//!   1. every `Bir.refs` row of `d` whose kind is `top_value`;
//!   2. every `.top` instruction in `d`'s contiguous instruction range.
//!      `refs` records a reference by the NAME the source wrote and an
//!      operator writes none, so inside `core/Basics` itself `0 - n`
//!      resolves to a `top` instruction while its `refs` row stays a
//!      symbolic `import_value` (`Reach.zig`'s leg 2, one module in);
//!   3. every dispatch site of `d`, and recursively every `top` nested in
//!      one through `Dispatch.partsAt`. A `method_call` adds no `refs` edge
//!      at all (`static-dispatch-spike.md` §1.4), so `x = (T 1).bump 2` with
//!      a `bump` that reads `x` is a cycle no `refs` walk can see.
//!
//! **`Reach.zig` and this file must agree**, and nothing but review makes
//! them: the two walks are the same three legs over the same tables and are
//! written twice because one lives under `src/js/` and runs over the whole
//! program after the checker, while this one runs per module inside the
//! checker's DAG and may not depend on the backend at all. The test at the
//! bottom of this file is what would notice a leg going missing here.
//!
//! **A cycle cannot cross a module**, so this needs nothing but the module's
//! own `Bir` and its own dispatch table: the module graph is a DAG and an
//! import cycle is already `import_cycle` with every member poisoned
//! (`resolve/Graph.zig`, `checker.md` §4.3). `ext_value` is therefore not a
//! leg.
//!
//! **Determinism.** Tarjan visits declarations in source order and follows
//! each node's edges in table order, so the components, the anchor of each
//! and the path printed in its message are functions of the input alone
//! (CLAUDE.md rule 5). Nothing here is shared across modules, which is what
//! makes it safe inside §4.4's DAG-parallel check.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Diagnostics = @import("Diagnostics.zig");
const Dispatch = @import("Dispatch.zig");

pub const Error = Allocator.Error;

/// A node has no component until Tarjan gives it one.
const no_scc: u32 = std.math.maxInt(u32);
const none: u32 = std.math.maxInt(u32);

/// A poisoned `parts` range could point back at itself; `Reach.target` and
/// `Lower.collectTops` cap the same walk at the same depth.
const max_depth: u8 = 32;

/// One module's check. `scratch` is freed by the caller's arena.
pub fn run(
    scratch: Allocator,
    bir: *const Bir,
    dispatch: *const Dispatch,
    interner: *const InternPool.Global,
    reporter: *Diagnostics.Reporter,
) Error!void {
    if (reporter.quiet) return;
    const count: u32 = @intCast(bir.decls.len);
    if (count == 0) return;
    // Nothing can be reported about a module with no constant in it, and a
    // module of nothing but functions is the common shape — so the cheap
    // question is asked first, over the declaration table alone, before
    // anything walks an instruction range. `bench --generate` is 624 such
    // modules and this is what keeps the pass off its check time.
    if (!anyRuns(bir, dispatch)) return;

    var g: Graph = .{ .scratch = scratch, .bir = bir, .dispatch = dispatch };
    try g.build(count);
    // The overwhelmingly common answer: no declaration of this module names
    // any other, so there is nothing to decompose.
    if (g.targets.items.len == 0) return;
    try g.tarjan(count);
    try g.report(count, interner, reporter);
}

/// Whether any declaration of the module is initialised at module load: the
/// three readings of `Graph.build`, without building anything.
fn anyRuns(bir: *const Bir, dispatch: *const Dispatch) bool {
    for (bir.decls, 0..) |d, i| {
        if (d.kind != .value) continue;
        const body = d.body.unwrap() orelse continue;
        if (d.params != 0) continue;
        if (dispatch.declEvidence(@intCast(i)).len != 0) continue;
        if (bir.instTag(body) == .lambda) continue;
        return true;
    }
    return false;
}

/// The edge lists, then the components, then the report. Three flat arrays
/// per node and no pointers, like every other sidecar table here.
const Graph = struct {
    scratch: Allocator,
    bir: *const Bir,
    dispatch: *const Dispatch,
    /// `at[i]..at[i + 1]` is node `i`'s run of `targets`.
    at: []u32 = &.{},
    targets: std.ArrayList(u32) = .empty,
    /// Whether nothing of this declaration runs at module load.
    defers: []bool = &.{},
    /// Whether it is a value with a body at all: a `type`, a `foreign`
    /// value and an annotation with no definition emit no initialiser and
    /// are not nodes.
    runs: []bool = &.{},
    scc: []u32 = &.{},

    fn build(g: *Graph, count: u32) Error!void {
        g.at = try g.scratch.alloc(u32, count + 1);
        g.defers = try g.scratch.alloc(bool, count);
        g.runs = try g.scratch.alloc(bool, count);
        const tags = g.bir.insts.items(.tag);
        const data = g.bir.insts.items(.data);
        for (g.bir.decls, 0..) |d, i| {
            g.at[i] = @intCast(g.targets.items.len);
            g.defers[i] = true;
            g.runs[i] = false;
            if (d.kind != .value) continue;
            const body = d.body.unwrap() orelse continue;
            g.runs[i] = true;
            // The emitter's own three readings (`js/Lower.declaration`): a
            // declaration with parameters or with evidence parameters is an
            // arrow, and so is a parameterless one whose entire body is a
            // `lambda`. All three run nothing where they are bound.
            g.defers[i] = d.params != 0 or
                g.dispatch.declEvidence(@intCast(i)).len != 0 or
                g.bir.instTag(body) == .lambda;

            // Leg 1.
            for (g.bir.refs[d.refs_start..d.refs_end]) |ref| {
                if (ref.kind != .top_value) continue;
                if (ref.a < count) try g.targets.append(g.scratch, ref.a);
            }
            // Leg 2. A declaration's instructions are contiguous, so this is
            // a slice walk and not a tree traversal.
            const start = @min(d.inst_start.int(), g.bir.insts.len);
            const end = @min(d.inst_end.int(), g.bir.insts.len);
            for (tags[start..end], data[start..end]) |tag, payload| {
                if (tag != .top) continue;
                if (payload.lhs < count) try g.targets.append(g.scratch, payload.lhs);
            }
            // Leg 3.
            const range = siteRange(g.dispatch.sites, d.inst_start.int(), d.inst_end.int());
            for (g.dispatch.sites[range.start..][0..range.len]) |site| {
                try g.collect(site.target, count, 0);
            }
        }
        g.at[count] = @intCast(g.targets.items.len);
    }

    fn collect(g: *Graph, target: Dispatch.Target, count: u32, depth: u8) Error!void {
        if (depth > max_depth) return;
        switch (target) {
            .top => |use| if (use.decl.int() < count) try g.targets.append(g.scratch, use.decl.int()),
            // A derived function, another module's value and the evidence
            // parameters are all either cross-module or synthesised, and
            // neither can close a cycle inside this module.
            else => {},
        }
        for (g.dispatch.partsAt(target.partsOf())) |part| try g.collect(part, count, depth + 1);
    }

    fn edges(g: *const Graph, node: u32) []const u32 {
        return g.targets.items[g.at[node]..g.at[node + 1]];
    }

    /// Tarjan's strongly-connected components, iteratively: a module may
    /// have tens of thousands of declarations and recursion here would be
    /// bounded by the C stack rather than by the input.
    fn tarjan(g: *Graph, count: u32) Error!void {
        g.scc = try g.scratch.alloc(u32, count);
        @memset(g.scc, no_scc);
        const index = try g.scratch.alloc(u32, count);
        @memset(index, none);
        const lowlink = try g.scratch.alloc(u32, count);
        const on_stack = try g.scratch.alloc(bool, count);
        @memset(on_stack, false);
        var stack: std.ArrayList(u32) = .empty;
        var frames: std.ArrayList(Frame) = .empty;
        var counter: u32 = 0;
        var components: u32 = 0;

        for (0..count) |root| {
            if (index[root] != none) continue;
            index[root] = counter;
            lowlink[root] = counter;
            counter += 1;
            try stack.append(g.scratch, @intCast(root));
            on_stack[root] = true;
            try frames.append(g.scratch, .{ .node = @intCast(root), .next = 0 });
            while (frames.items.len != 0) {
                const f = &frames.items[frames.items.len - 1];
                const list = g.edges(f.node);
                if (f.next < list.len) {
                    const w = list[f.next];
                    f.next += 1;
                    if (index[w] == none) {
                        index[w] = counter;
                        lowlink[w] = counter;
                        counter += 1;
                        try stack.append(g.scratch, w);
                        on_stack[w] = true;
                        try frames.append(g.scratch, .{ .node = w, .next = 0 });
                    } else if (on_stack[w]) {
                        lowlink[f.node] = @min(lowlink[f.node], index[w]);
                    }
                    continue;
                }
                const node = f.node;
                if (lowlink[node] == index[node]) {
                    while (stack.pop()) |member| {
                        on_stack[member] = false;
                        g.scc[member] = components;
                        if (member == node) break;
                    }
                    components += 1;
                }
                _ = frames.pop();
                if (frames.items.len != 0) {
                    const parent = &frames.items[frames.items.len - 1];
                    lowlink[parent.node] = @min(lowlink[parent.node], lowlink[node]);
                }
            }
        }
    }

    const Frame = struct { node: u32, next: usize };

    /// One diagnostic per component, at the first declaration of it that
    /// RUNS — the value whose initialisation is the one that cannot happen.
    /// A component of deferring nodes only is mutual recursion between
    /// functions and is reported nowhere.
    fn report(
        g: *Graph,
        count: u32,
        interner: *const InternPool.Global,
        reporter: *Diagnostics.Reporter,
    ) Error!void {
        const done = try g.scratch.alloc(bool, count);
        @memset(done, false);
        var path: std.ArrayList(u32) = .empty;
        for (0..count) |i| {
            const anchor: u32 = @intCast(i);
            if (!g.runs[anchor] or g.defers[anchor]) continue;
            const component = g.scc[anchor];
            if (component == no_scc or done[component]) continue;
            if (!g.cyclic(anchor)) continue;
            done[component] = true;
            path.clearRetainingCapacity();
            try g.cycleFrom(anchor, count, &path);
            try g.emit(anchor, path.items, interner, reporter);
        }
    }

    /// Whether the component of `node` is one the node can get back into:
    /// every component of more than one member is, and a single member only
    /// when it names itself.
    fn cyclic(g: *const Graph, node: u32) bool {
        for (g.edges(node)) |w| {
            if (w == node) return true;
            if (g.scc[w] == g.scc[node]) return true;
        }
        return false;
    }

    /// The shortest cycle from `anchor` back to `anchor`, as the nodes after
    /// it in order. `x = x + 1` gives an empty path; `x = y + 1` with
    /// `y = x` gives `[y]`. Breadth-first over edges in table order, so the
    /// path printed is a function of the input.
    fn cycleFrom(g: *const Graph, anchor: u32, count: u32, out: *std.ArrayList(u32)) Error!void {
        const parent = try g.scratch.alloc(u32, count);
        defer g.scratch.free(parent);
        @memset(parent, none);
        const seen = try g.scratch.alloc(bool, count);
        defer g.scratch.free(seen);
        @memset(seen, false);
        seen[anchor] = true;
        var queue: std.ArrayList(u32) = .empty;
        defer queue.deinit(g.scratch);
        try queue.append(g.scratch, anchor);
        var head: usize = 0;
        var closer: u32 = none;
        search: while (head < queue.items.len) : (head += 1) {
            const v = queue.items[head];
            for (g.edges(v)) |w| {
                if (g.scc[w] != g.scc[anchor]) continue;
                if (w == anchor) {
                    closer = v;
                    break :search;
                }
                if (seen[w]) continue;
                seen[w] = true;
                parent[w] = v;
                try queue.append(g.scratch, w);
            }
        }
        if (closer == none or closer == anchor) return;
        // Back to the anchor, then reversed: the message reads forwards.
        var v = closer;
        while (v != anchor) : (v = parent[v]) try out.append(g.scratch, v);
        std.mem.reverse(u32, out.items);
    }

    fn emit(
        g: *const Graph,
        anchor: u32,
        path: []const u32,
        interner: *const InternPool.Global,
        reporter: *Diagnostics.Reporter,
    ) Error!void {
        const names = try g.scratch.alloc([]const u8, path.len);
        defer g.scratch.free(names);
        var through: ?[]const u8 = null;
        for (path, names) |node, *name| {
            name.* = interner.slice(g.bir.symbol(g.bir.decls[node].name));
            // The first FUNCTION on the way round, for the sentence that
            // says why naming one is enough to close a cycle.
            if (through == null and g.defers[node]) through = name.*;
        }
        const d = g.bir.decls[anchor];
        try reporter.cyclicValue(
            d.body.unwrap() orelse return,
            d.name_token,
            interner.slice(g.bir.symbol(d.name)),
            names,
            through,
        );
    }
};

/// The dispatch sites of one instruction range. `Dispatch.sites` is grouped
/// by `inst` and a declaration's instructions are contiguous, so this is a
/// lower bound plus a scan — `Reach.siteRange` reads the same table the same
/// way.
fn siteRange(sites: []const Dispatch.Site, start: u32, end: u32) Dispatch.Range {
    const lo = std.sort.lowerBound(Dispatch.Site, sites, start, siteBefore);
    var hi = lo;
    while (hi < sites.len and sites[hi].inst.int() < end) hi += 1;
    return .{ .start = @intCast(lo), .len = @intCast(hi - lo) };
}

fn siteBefore(inst: u32, s: Dispatch.Site) std.math.Order {
    return std.math.order(inst, s.inst.int());
}

// ---------------------------------------------------------------------------
// Tests
//
// A SUPPLEMENT and never the coverage (CLAUDE.md rule 3): what this pass
// decides is visible as diagnostics and as programs that run, so its
// evidence is `tests/corpus/check/bad/Cyclic*` and `run/EvalOrderTopLevel`.
// What is here is the component arithmetic those fixtures cannot point at —
// that a component of deferring nodes only is not a cycle, and that the
// printed path is the shortest one.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A graph with no `Bir` behind it: `build` is what reads the tables, and
/// the decomposition below is what the fixtures cannot inspect.
fn testGraph(scratch: Allocator, at: []const u32, targets: []const u32, defers: []const bool) !Graph {
    var g: Graph = .{ .scratch = scratch, .bir = undefined, .dispatch = undefined };
    g.at = @constCast(at);
    g.defers = @constCast(defers);
    g.runs = try scratch.alloc(bool, defers.len);
    @memset(g.runs, true);
    try g.targets.appendSlice(scratch, targets);
    try g.tarjan(@intCast(defers.len));
    return g;
}

test "a component of more than one node is a cycle; a lone node only when it names itself" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    // 0 → 1 → 0, and 2 → 2, and 3 → 1 (into the cycle but not on it).
    var g = try testGraph(
        scratch,
        &.{ 0, 1, 2, 3, 4 },
        &.{ 1, 0, 2, 1 },
        &.{ false, false, false, false },
    );
    try testing.expect(g.scc[0] == g.scc[1]);
    try testing.expect(g.scc[2] != g.scc[0]);
    try testing.expect(g.cyclic(0));
    try testing.expect(g.cyclic(1));
    try testing.expect(g.cyclic(2));
    // Reaching a cycle is not being on one: nothing recomputes node 3.
    try testing.expect(!g.cyclic(3));

    var path: std.ArrayList(u32) = .empty;
    try g.cycleFrom(0, 4, &path);
    try testing.expectEqualSlices(u32, &.{1}, path.items);
    // A self-reference has no node in between, and the message says so by
    // naming nothing.
    path.clearRetainingCapacity();
    try g.cycleFrom(2, 4, &path);
    try testing.expectEqualSlices(u32, &.{}, path.items);
}

test "the path printed is the shortest way round, not the first one found" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    // 0 → 1 → 2 → 3 → 0, and 0 → 3 as well: the long way is discovered
    // first because it leaves the anchor first, and the short way is what a
    // reader wants.
    var g = try testGraph(
        scratch,
        &.{ 0, 2, 3, 4, 5 },
        &.{ 1, 3, 2, 3, 0 },
        &.{ false, false, false, false },
    );
    var path: std.ArrayList(u32) = .empty;
    try g.cycleFrom(0, 4, &path);
    try testing.expectEqualSlices(u32, &.{3}, path.items);
}
