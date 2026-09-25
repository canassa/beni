//! Minimal mutually recursive groups over an index graph, dependencies
//! first: an iterative Tarjan and a counting sort. Shared by both checkers'
//! top-level and `let` binding groups; moved out of v1's `Constrain.zig` by
//! R4b's review (S2).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error;

/// `sccGroups`'s answer over plain indices: `order[starts[i]..starts[i + 1]]`
/// is group `i`, and the groups are in dependency order.
pub const IndexGroups = struct {
    order: []u32,
    starts: []u32,
};

/// Minimal mutually recursive groups over an arbitrary index graph,
/// dependencies first. `edges[edge_start[i]..edge_start[i + 1]]` are `i`'s
/// targets. Shared by the `let` decompositions and the top-level ones of
/// both checkers, which are the same problem over different edges.
pub fn sccGroups(scratch: Allocator, n: usize, edges: []const u32, edge_start: []const u32) Error!IndexGroups {
    var t: LetTarjan = try .init(scratch, n, edges, edge_start);
    defer t.deinit(scratch);
    try t.run(scratch);
    // Tarjan closes a component only once everything it points AT is done,
    // and the edges here point dependent → dependency — so component 0 is
    // the deepest dependency and ASCENDING id order is dependencies first.
    // Both callers need that: `Check.run` checks group 0 first, and
    // `letExpr` makes group 0 the outermost `let`, which is the one
    // generalised first. Emitting them the other way round left every
    // unannotated callee's scheme unset at the point its caller was
    // checked, so the call was silently poisoned instead of checked.
    //
    // Grouped by a COUNTING SORT rather than a scan per component. The
    // normal shape of real code is mostly independent top-level
    // declarations, so components ≈ n and "for each component, scan every
    // member" was quadratic in the module's declaration count: 8 000
    // declarations took 44 ms, 16 000 took 139 ms and 32 000 took 506 ms,
    // while the same 32 000 in ONE component took 73 ms.
    const order = try scratch.alloc(u32, n);
    const starts = try scratch.alloc(u32, t.component_count + 1);
    @memset(starts, 0);
    for (t.component) |c| starts[c + 1] += 1;
    for (1..t.component_count + 1) |c| starts[c] += starts[c - 1];
    const cursor = try scratch.alloc(u32, t.component_count);
    defer scratch.free(cursor);
    @memcpy(cursor, starts[0..t.component_count]);
    for (t.component, 0..) |c, i| {
        order[cursor[c]] = @intCast(i);
        cursor[c] += 1;
    }
    return .{ .order = order, .starts = starts };
}

/// Tarjan over a `let`'s bindings; iterative for the same reason
/// `resolve/Graph.zig`'s is.
const LetTarjan = struct {
    index: []u32,
    low: []u32,
    on_stack: []bool,
    component: []u32,
    stack: std.ArrayList(u32) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    edges: []const u32,
    edge_start: []const u32,
    next_index: u32 = 0,
    component_count: u32 = 0,

    const unvisited = std.math.maxInt(u32);
    const Frame = struct { node: u32, cursor: u32 };

    fn init(scratch: Allocator, n: usize, edges: []const u32, edge_start: []const u32) Error!LetTarjan {
        const t: LetTarjan = .{
            .index = try scratch.alloc(u32, n),
            .low = try scratch.alloc(u32, n),
            .on_stack = try scratch.alloc(bool, n),
            .component = try scratch.alloc(u32, n),
            .edges = edges,
            .edge_start = edge_start,
        };
        @memset(t.index, unvisited);
        @memset(t.on_stack, false);
        @memset(t.component, 0);
        return t;
    }

    fn deinit(t: *LetTarjan, scratch: Allocator) void {
        scratch.free(t.index);
        scratch.free(t.low);
        scratch.free(t.on_stack);
        t.stack.deinit(scratch);
        t.frames.deinit(scratch);
    }

    fn run(t: *LetTarjan, scratch: Allocator) Error!void {
        for (0..t.index.len) |root| {
            if (t.index[root] != unvisited) continue;
            try t.frames.append(scratch, .{ .node = @intCast(root), .cursor = 0 });
            while (t.frames.items.len > 0) {
                const frame = &t.frames.items[t.frames.items.len - 1];
                const v = frame.node;
                if (frame.cursor == 0) {
                    t.index[v] = t.next_index;
                    t.low[v] = t.next_index;
                    t.next_index += 1;
                    try t.stack.append(scratch, v);
                    t.on_stack[v] = true;
                }
                const edges = t.edges[t.edge_start[v]..t.edge_start[v + 1]];
                if (frame.cursor < edges.len) {
                    const w = edges[frame.cursor];
                    frame.cursor += 1;
                    if (t.index[w] == unvisited) {
                        try t.frames.append(scratch, .{ .node = w, .cursor = 0 });
                    } else if (t.on_stack[w]) {
                        t.low[v] = @min(t.low[v], t.index[w]);
                    }
                    continue;
                }
                if (t.low[v] == t.index[v]) {
                    while (true) {
                        const w = t.stack.pop().?;
                        t.on_stack[w] = false;
                        t.component[w] = t.component_count;
                        if (w == v) break;
                    }
                    t.component_count += 1;
                }
                _ = t.frames.pop();
                if (t.frames.items.len > 0) {
                    const parent = t.frames.items[t.frames.items.len - 1].node;
                    t.low[parent] = @min(t.low[parent], t.low[v]);
                }
            }
        }
    }
};
