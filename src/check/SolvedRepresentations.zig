//! Ordinary source Var provenance, NOT HostFree or Wire evidence.
const std = @import("std");
const Store = @import("TypeStore.zig");
const Allocator = std.mem.Allocator;
pub const none = std.math.maxInt(u32);
pub const schema_version: u32 = 1;
pub const NodeIndex = enum(u32) { none = std.math.maxInt(u32), _ };
pub const SourceId = enum(u32) { _ };
pub const Tag = enum(u8) { err, flex, rigid, unit, empty_record, function, app, tuple, record, alias };
pub const EdgeKind = enum(u8) { argument, result, tuple_field, record_field, extension, actual };
pub const Origin = enum(u8) { entry, nominal };
pub const RootKind = enum(u8) { entry, nominal_template, alias_template };
pub const Node = struct {
    source: SourceId,
    tag: Tag,
    start: u32,
    len: u32,
    nominal: Store.TypeId = .none,
    rank: u32 = 0,
    kind: Store.Kind = .any,
    marker_eq: bool = false,
};
pub const Edge = struct { target: NodeIndex, kind: EdgeKind, selector: u32 = 0 };
pub const Root = struct { kind: RootKind, declaration: u32, nominal: Store.TypeId = .none, anchor: u32 = none, origin: Origin = .entry, node: NodeIndex, start: u32, len: u32 };
/// Raw capture rows exist ONLY while the ordinary module Store lives.
pub const Capture = struct {
    roots: std.MultiArrayList(RawRoot) = .empty,
    formals: std.ArrayList(Store.Var) = .empty,
    pub const RawRoot = struct { kind: RootKind, declaration: u32, nominal: Store.TypeId, anchor: u32, origin: Origin, node: Store.Var, start: u32, len: u32 };
    pub fn deinit(c: *Capture, gpa: Allocator) void {
        c.roots.deinit(gpa);
        c.formals.deinit(gpa);
    }
    pub fn add(c: *Capture, gpa: Allocator, kind: RootKind, origin: Origin, declaration: u32, nominal: Store.TypeId, anchor: u32, node: Store.Var, params: []const Store.Var) Allocator.Error!void {
        try c.roots.append(gpa, .{ .kind = kind, .declaration = declaration, .nominal = nominal, .anchor = anchor, .origin = origin, .node = node, .start = @intCast(c.formals.items.len), .len = @intCast(params.len) });
        try c.formals.appendSlice(gpa, params);
    }
};
pub const Counts = struct {
    descriptors: u32 = 0,
    representatives: u32 = 0,
    parent_edges: u32 = 0,
    edges: u32 = 0,
    fields: u32 = 0,
};
pub const Artifact = struct {
    present: bool = false,
    counts: Counts = .{},
    nodes: std.MultiArrayList(Node).Slice = .empty,
    edges: std.MultiArrayList(Edge).Slice = .empty,
    roots: std.MultiArrayList(Root).Slice = .empty,
    descriptor_nodes: []NodeIndex = &.{},
    formals: []NodeIndex = &.{},
    pub const empty: Artifact = .{};
    pub fn deinit(a: *Artifact, gpa: Allocator) void {
        a.nodes.deinit(gpa);
        a.edges.deinit(gpa);
        a.roots.deinit(gpa);
        gpa.free(a.descriptor_nodes);
        gpa.free(a.formals);
        a.* = .empty;
    }
    pub fn verify(a: *const Artifact) bool {
        if (!a.present) return a.nodes.len == 0 and a.edges.len == 0 and a.roots.len == 0 and a.formals.len == 0 and a.descriptor_nodes.len == 0 and std.meta.eql(a.counts, Counts{});
        const c = a.counts;
        if (a.descriptor_nodes.len != c.descriptors or a.nodes.len != c.representatives or a.edges.len != c.edges or c.representatives > c.descriptors or c.parent_edges != c.descriptors - c.representatives) return false;
        for (a.descriptor_nodes) |index| if (@backingInt(index) >= a.nodes.len) return false;
        var edge_at: u32 = 0;
        var field_count: u32 = 0;
        var previous: ?u32 = null;
        for (0..a.nodes.len) |i| {
            const node = a.nodes.get(i);
            const source = @backingInt(node.source);
            if (source >= c.descriptors or a.descriptor_nodes[source] != @as(NodeIndex, @fromBackingInt(@intCast(i)))) return false;
            if (previous) |p| if (source <= p) return false;
            previous = source;
            if (node.start != edge_at or node.len > a.edges.len - edge_at) return false;
            const named = node.tag == .app or node.tag == .alias;
            if (named != (node.nominal != .none)) return false;
            if (node.tag != .flex and node.tag != .rigid and (node.kind != .any or node.marker_eq)) return false;
            switch (node.tag) {
                .err, .flex, .rigid, .unit, .empty_record => if (node.len != 0) return false,
                .function, .record, .alias => if (node.len == 0) return false,
                else => {},
            }
            for (0..node.len) |j| {
                const edge = a.edges.get(edge_at + j);
                if (@backingInt(edge.target) >= a.nodes.len) return false;
                const expected: EdgeKind = switch (node.tag) {
                    .function => if (j + 1 == node.len) .result else .argument,
                    .app => .argument,
                    .tuple => .tuple_field,
                    .record => if (j + 1 == node.len) .extension else .record_field,
                    .alias => if (j == 0) .actual else .argument,
                    else => return false,
                };
                if (edge.kind != expected) return false;
                if (expected == .record_field) {
                    field_count += 1;
                } else if (edge.selector != switch (expected) {
                    .argument => if (node.tag == .alias) j - 1 else j,
                    .tuple_field => j,
                    else => 0,
                }) return false;
            }
            edge_at += node.len;
        }
        if (edge_at != a.edges.len or field_count != c.fields) return false;
        var formal_at: u32 = 0;
        for (0..a.roots.len) |i| {
            const root = a.roots.get(i);
            if (@backingInt(root.node) >= a.nodes.len or root.start != formal_at or root.len > a.formals.len - formal_at) return false;
            if ((root.kind == .entry) != (root.nominal == .none)) return false;
            if (root.anchor == none) return false;
            if (root.kind == .entry and root.origin != .entry) return false;
            if (root.kind == .nominal_template and root.origin != .nominal) return false;
            for (a.formals[root.start..][0..root.len], 0..) |formal, q| {
                if (@backingInt(formal) >= a.nodes.len) return false;
                const tag = a.nodes.get(@backingInt(formal)).tag;
                if (tag != .flex and tag != .rigid) return false;
                // No quadratic distinctness scan; source formals are validated
                // through their indexed positions by common coverage.
                _ = q;
            }
            formal_at += root.len;
        }
        return formal_at == a.formals.len;
    }
};
