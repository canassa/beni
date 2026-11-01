//! Read-only O(D+E) source inventory. No fresh type or template instantiation.
const std = @import("std");
const S = @import("SolvedRepresentations.zig");
const Store = @import("TypeStore.zig");
const Walk = @import("Walk.zig");
const Allocator = std.mem.Allocator;
pub fn build(gpa: Allocator, store: *const Store, capture: *const S.Capture) Allocator.Error!S.Artifact {
    var out: S.Artifact = .{ .present = true, .counts = .{ .descriptors = store.count() } };
    errdefer out.deinit(gpa);
    const parents = try gpa.alloc(u32, store.count());
    defer gpa.free(parents);
    @memset(parents, S.none);
    var path: std.ArrayList(u32) = .empty;
    defer path.deinit(gpa);
    for (0..parents.len) |i| {
        var at: u32 = @intCast(i);
        while (parents[at] == S.none) {
            const parent = store.get(@fromBackingInt(at)).parent.int();
            if (parent == at) {
                parents[at] = at;
                break;
            }
            out.counts.parent_edges += 1;
            try path.append(gpa, at);
            at = parent;
        }
        const representative = parents[at];
        while (path.pop()) |p| parents[p] = representative;
    }
    out.descriptor_nodes = try gpa.alloc(S.NodeIndex, parents.len);
    @memset(out.descriptor_nodes, .none);
    var nodes: std.MultiArrayList(S.Node) = .empty;
    defer nodes.deinit(gpa);
    for (parents, 0..) |parent, i| {
        if (parent != i) continue;
        out.descriptor_nodes[i] = @fromBackingInt(@intCast(nodes.len));
        try nodes.append(gpa, .{ .source = @fromBackingInt(@intCast(i)), .tag = .err, .start = 0, .len = 0, .rank = store.get(@fromBackingInt(@intCast(i))).rank });
    }
    for (parents, 0..) |parent, i| out.descriptor_nodes[i] = out.descriptor_nodes[parent];
    // A representative may appear after its children or before them. All IDs
    // are installed first, so decoding a cycle needs no recursive allocation.
    var edges: std.MultiArrayList(S.Edge) = .empty;
    defer edges.deinit(gpa);
    for (0..nodes.len) |i| {
        var node = nodes.get(i);
        node.start = @intCast(edges.len);
        const source: Store.Var = @fromBackingInt(@backingInt(node.source));
        switch (store.content(source)) {
            .err => node.tag = .err,
            .flex, .rigid => |flags| {
                node.tag = if (store.content(source) == .flex) .flex else .rigid;
                node.kind = flags.kind;
                node.marker_eq = flags.equatable;
            },
            .alias => |alias| {
                node.tag = .alias;
                node.nominal = alias.type;
            },
            .structure => |flat| switch (flat) {
                .unit => node.tag = .unit,
                .empty_record => node.tag = .empty_record,
                .func => node.tag = .function,
                .app => |app| {
                    node.tag = .app;
                    node.nominal = app.type;
                },
                .tuple => node.tag = .tuple,
                .record => node.tag = .record,
            },
        }
        var child_index: u32 = 0;
        while (Walk.child(store, source, child_index, .structural)) |child| : (child_index += 1) {
            const stepped: Walk.Stepped = if (node.tag == .alias)
                .{ .v = child, .kind = if (child_index == 0) .expansion else .argument, .index = if (child_index == 0) 0 else child_index - 1 }
            else
                Walk.stepped(store, source, child_index).?;
            const kind: S.EdgeKind = switch (stepped.kind) {
                .param, .argument => .argument,
                .result => .result,
                .element => .tuple_field,
                .field => .record_field,
                .extension => .extension,
                .expansion => .actual,
            };
            if (kind == .record_field) out.counts.fields += 1;
            try edges.append(gpa, .{ .target = out.descriptor_nodes[child.int()], .kind = kind, .selector = stepped.index });
        }
        node.len = @intCast(edges.len - node.start);
        nodes.set(i, node);
    }
    var roots: std.MultiArrayList(S.Root) = .empty;
    defer roots.deinit(gpa);
    for (0..capture.roots.len) |i| {
        const raw = capture.roots.get(i);
        try roots.append(gpa, .{ .kind = raw.kind, .declaration = raw.declaration, .nominal = raw.nominal, .anchor = raw.anchor, .origin = raw.origin, .node = out.descriptor_nodes[raw.node.int()], .start = raw.start, .len = raw.len });
    }
    out.formals = try gpa.alloc(S.NodeIndex, capture.formals.items.len);
    for (capture.formals.items, out.formals) |raw, *index| index.* = out.descriptor_nodes[raw.int()];
    out.counts.representatives = @intCast(nodes.len);
    out.counts.edges = @intCast(edges.len);
    out.nodes = nodes.toOwnedSlice();
    out.edges = edges.toOwnedSlice();
    out.roots = roots.toOwnedSlice();
    std.debug.assert(out.verify());
    return out;
}

test "solved representation ordinary inventory canonicalizes UF chains and preserves real alias actual edges" {
    const gpa = std.testing.allocator;
    var store: Store = .init(gpa);
    defer store.deinit();
    const a = try store.fresh(.{ .flex = .{} }, 1);
    const b = try store.fresh(.{ .flex = .{} }, 1);
    _ = store.merge(a, b, .{ .structure = .unit });
    const alias = try store.fresh(.{ .alias = .{ .type = @fromBackingInt(0), .args = try store.addVars(&.{b}), .actual = a } }, 0);
    var capture: S.Capture = .{};
    defer capture.deinit(gpa);
    try capture.add(gpa, .entry, .entry, 0, .none, 0, alias, &.{});
    const before = store.get(b).parent;
    var graph = try build(gpa, &store, &capture);
    defer graph.deinit(gpa);
    try std.testing.expect(graph.verify());
    try std.testing.expectEqual(before, store.get(b).parent);
    try std.testing.expectEqualDeep(S.Counts{ .descriptors = 3, .representatives = 2, .parent_edges = 1, .edges = 2 }, graph.counts);
    try std.testing.expectEqual(graph.descriptor_nodes[a.int()], graph.descriptor_nodes[b.int()]);
    const root = graph.nodes.get(@backingInt(graph.roots.get(0).node));
    try std.testing.expectEqual(S.Tag.alias, root.tag);
    try std.testing.expectEqual(S.EdgeKind.actual, graph.edges.get(root.start).kind);
    try std.testing.expectEqual(graph.descriptor_nodes[a.int()], graph.edges.get(root.start).target);
    try std.testing.checkAllAllocationFailures(gpa, struct {
        fn one(allocator: Allocator, input: *const Store, scopes: *const S.Capture) !void {
            var inventory = try build(allocator, input, scopes);
            defer inventory.deinit(allocator);
        }
    }.one, .{ &store, &capture });
    graph.descriptor_nodes[a.int()] = .none;
    try std.testing.expect(!graph.verify());
}
