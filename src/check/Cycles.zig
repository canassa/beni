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
//!   - it **defers** — it is WRITTEN as a function: it has parameters, or its
//!     whole body is a `lambda`. Nothing of it runs at module load;
//!   - it **runs** — every other value with a body. A plain one is evaluated
//!     once, where `emissionOrder` puts it; one with evidence is computed at
//!     every read (a thunk, CK-34) or call (a point-free value of function
//!     type, `h = compose h g` under a `where`), so a self-reference
//!     recurses. A `where` does not make a value a function (`language.md`
//!     §7; R2b review B1), even where the emitter defines it as an arrow.
//!
//! A strongly connected component with at least one node that RUNS is
//! refused (`cyclic_value`); one made only of deferring nodes is fine and is
//! how `isEven`/`isOdd` are written. The reading is `check/Convention.zig`'s
//! (`checker-v2.md` §12.5), the same one `js/Lower.declaration` defines the
//! value by, so the two cannot drift.
//!
//! **The edges are `Edges.zig`'s**, shared with `js/Reach.zig` — the three
//! legs out of a value declaration `d` (`refs` rows of kind `top_value`; the
//! `.top` and `.ext_value` instructions of `d`'s contiguous instruction
//! range; every dispatch site of `d` and, recursively through each term's
//! `args`, every term nested in one). Leg 3 is the one no
//! `refs` walk can see: a `method_call` adds no `refs` row at all
//! (`static-dispatch-spike.md` §1.4), so `x = (T 1).bump 2` with a `bump`
//! that reads `x` is a cycle only the dispatch table records.
//!
//! **This pass keeps `.top` and drops every other tag.** A cycle cannot cross
//! a module, so this needs nothing but the module's own `Bir` and its own
//! dispatch table: the module graph is a DAG and an import cycle is already
//! `import_cycle` with every member poisoned (`resolve/Graph.zig`,
//! `checker.md` §4.3). `ext`, `ext_derived`, `primitive` and `err` are all
//! cross-module; a `derived` row is synthesised and cannot close a cycle
//! between two written declarations by itself — but the declarations its
//! body names are this declaration's `.top` edges (`Edges.declEdges` walks
//! through the rows it names, CK-104). `js/Reach.zig` takes all six, which is
//! the whole difference between the two consumers of one walk.
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
const Edges = @import("Edges.zig");
const Convention = @import("Convention.zig");

pub const Error = Allocator.Error;

/// A node has no component until Tarjan gives it one.
const no_scc: u32 = std.math.maxInt(u32);
const none: u32 = std.math.maxInt(u32);

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

/// Whether any declaration of the module is initialised at module load or
/// at a read: `Graph.build`'s reading, without building anything.
fn anyRuns(bir: *const Bir, dispatch: *const Dispatch) bool {
    for (bir.decls, 0..) |d, i| {
        if (d.kind != .value) continue;
        if (d.body == .none) continue;
        if (!declDefers(bir, dispatch, @intCast(i))) return true;
    }
    return false;
}

/// `Convention`'s initialisation reading (checker-v2.md §12.5), over the same
/// `Definition` `js/Lower.declaration` defines the value by: only a value
/// written as a function (parameters, or a `lambda` body) defers.
fn declDefers(bir: *const Bir, dispatch: *const Dispatch, index: u32) bool {
    return Convention.defers(Convention.definitionOf(dispatch, bir, index));
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
        // One buffer for the whole module, cleared per declaration: the
        // shared walk writes into a buffer its caller owns, so the edges of
        // one declaration cost no allocation after the first.
        var stream: std.ArrayList(Edges.Edge) = .empty;
        defer stream.deinit(g.scratch);
        for (g.bir.decls, 0..) |d, i| {
            g.at[i] = @intCast(g.targets.items.len);
            g.defers[i] = true;
            g.runs[i] = false;
            if (d.kind != .value) continue;
            if (d.body == .none) continue;
            g.runs[i] = true;
            // `Convention`'s reading, over the definition `js/Lower` emits.
            g.defers[i] = declDefers(g.bir, g.dispatch, @intCast(i));

            stream.clearRetainingCapacity();
            try Edges.declEdges(&stream, g.scratch, g.bir, g.dispatch, @intCast(i));
            for (stream.items) |edge| switch (edge) {
                // A poisoned index is dropped rather than followed: the
                // node arrays are sized from this same declaration table.
                .top => |target| if (target < count) try g.targets.append(g.scratch, target),
                // Cross-module or synthesised; neither can close a cycle
                // between two declarations of this module.
                .ext, .derived, .ext_derived, .primitive, .undetermined => {},
            };
        }
        g.at[count] = @intCast(g.targets.items.len);
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
        // The first node of the circle, anchor included, that is computed
        // at each read or call rather than once at load: a `thunk` or an
        // `applied` value (`Convention`), both of which take evidence. The
        // message's "computed once" is false for it, so it says so.
        const anchor_name = interner.slice(g.bir.symbol(g.bir.decls[anchor].name));
        var per_use: ?[]const u8 = if (g.perUse(anchor)) anchor_name else null;
        if (per_use == null) for (path, names) |node, name| {
            if (g.perUse(node)) {
                per_use = name;
                break;
            }
        };
        const d = g.bir.decls[anchor];
        try reporter.cyclicValue(
            d.body.unwrap() orelse return,
            d.name_token,
            anchor_name,
            names,
            through,
            per_use,
        );
    }

    fn perUse(g: *const Graph, node: u32) bool {
        return switch (Convention.definitionOf(g.dispatch, g.bir, node)) {
            .thunk, .applied => true,
            .constant, .params, .lambda => false,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
//
// A SUPPLEMENT and never the coverage (CLAUDE.md rule 3): what this pass
// decides is visible as diagnostics and as programs that run, so its
// evidence is `tests/corpus/check/bad/Cyclic*` and `run/EvalOrderTopLevel`.
// What is here is the component arithmetic those fixtures cannot point at —
// that a component of deferring nodes only is not a cycle, and that the
// printed path is the shortest one. That the EDGES are all three legs is
// `Edges.zig`'s test, once, for both consumers.
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
