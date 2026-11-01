//! Opt-in live UF identity/adjacency, NOT HostFree/Wire authority.
//! Construction history is counted; export visits live classes/edges only.
const std = @import("std");
const Store = @import("TypeStore.zig");
const Walk = @import("Walk.zig");
const S = @import("SolvedRepresentations.zig");
const Allocator = std.mem.Allocator;
const Index = @This();
pub const CursorError = Allocator.Error || error{InvalidatedCanonicalCursor};
const none = std.math.maxInt(u32);
const EdgeId = enum(u32) {
    none = std.math.maxInt(u32),
    _,
    fn int(id: EdgeId) u32 {
        return @backingInt(id);
    }
};
const Class = struct { incoming: EdgeId = .none, outgoing: EdgeId = .none, position: u32 = none };
const Edge = struct {
    owner: Store.Var,
    target: Store.Var,
    next_in: EdgeId = .none,
    prev_in: EdgeId = .none,
    next_out: EdgeId = .none,
    kind: S.EdgeKind,
    selector: u32,
};
pub const Counts = struct {
    canonical_fresh: u64 = 0,
    canonical_replace: u64 = 0,
    canonical_merge: u64 = 0,
    canonical_alias: u64 = 0,
    canonical_register: u64 = 0,
    canonical_remove: u64 = 0,
    canonical_redirect: u64 = 0,
    canonical_parent_steps: u64 = 0,
    canonical_live_edits: u64 = 0,
    canonical_export_nodes: u64 = 0,
    canonical_export_edges: u64 = 0,
    canonical_oracle_nodes: u64 = 0,
    canonical_oracle_edges: u64 = 0,
};
classes: std.MultiArrayList(Class) = .empty,
edges: std.MultiArrayList(Edge) = .empty,
live: std.ArrayList(Store.Var) = .empty,
free: EdgeId = .none,
failed: bool = false,
generation: u64 = 0,
counts: Counts = .{},

pub fn deinit(index: *Index, gpa: Allocator) void {
    index.classes.deinit(gpa);
    index.edges.deinit(gpa);
    index.live.deinit(gpa);
    index.* = .{};
}

/// Allocations use the owning store's arena; no independent lifetime.
pub fn check(index: *const Index) Allocator.Error!void {
    if (index.failed) return error.OutOfMemory;
}
pub fn statistics(index: *const Index) Allocator.Error!Counts {
    try index.check();
    return index.counts;
}
pub fn fresh(index: *Index, gpa: Allocator, store: *const Store, source: Store.Var) Allocator.Error!void {
    if (index.failed) return;
    index.generation += 1;
    errdefer index.failed = true;
    index.counts.canonical_fresh += 1;
    std.debug.assert(source.int() == index.classes.len);
    try index.classes.append(gpa, .{ .position = @intCast(index.live.items.len) });
    try index.live.append(gpa, source);
    index.counts.canonical_live_edits += 1;
    try index.register(gpa, store, source);
}
pub fn replace(index: *Index, gpa: Allocator, store: *const Store, source: Store.Var) Allocator.Error!void {
    if (index.failed) return;
    index.generation += 1;
    errdefer index.failed = true;
    index.counts.canonical_replace += 1;
    index.removeOutgoing(source);
    try index.register(gpa, store, source);
}
pub fn merge(index: *Index, gpa: Allocator, store: *const Store, a: Store.Var, b: Store.Var, keep: Store.Var) Allocator.Error!void {
    if (index.failed) return;
    index.generation += 1;
    errdefer index.failed = true;
    index.counts.canonical_merge += 1;
    index.removeOutgoing(a);
    index.removeOutgoing(b);
    const drop = if (a == keep) b else a;
    index.redirect(drop, keep);
    index.retire(drop);
    try index.register(gpa, store, keep);
}
pub fn expandAlias(index: *Index, alias: Store.Var, actual: Store.Var) void {
    if (index.failed) return;
    index.generation += 1;
    index.counts.canonical_alias += 1;
    index.removeOutgoing(alias);
    index.redirect(alias, actual);
    index.retire(alias);
}
fn retire(index: *Index, source: Store.Var) void {
    var old = index.classes.get(source.int());
    const position = old.position;
    const last = index.live.pop().?;
    if (position < index.live.items.len) {
        index.live.items[position] = last;
        var moved = index.classes.get(last.int());
        moved.position = position;
        index.classes.set(last.int(), moved);
        index.counts.canonical_live_edits += 1;
    }
    old.position = none;
    index.classes.set(source.int(), old);
    index.counts.canonical_live_edits += 1;
}
fn redirect(index: *Index, drop: Store.Var, keep: Store.Var) void {
    while (index.classes.get(drop.int()).incoming != .none) {
        const slot = index.classes.get(drop.int()).incoming;
        var edge = index.edges.get(slot.int());
        index.unlinkIncoming(slot, edge);
        edge.target = keep;
        edge.prev_in = .none;
        edge.next_in = index.classes.get(keep.int()).incoming;
        if (edge.next_in != .none) {
            var next = index.edges.get(edge.next_in.int());
            next.prev_in = slot;
            index.edges.set(edge.next_in.int(), next);
        }
        var target = index.classes.get(keep.int());
        target.incoming = slot;
        index.classes.set(keep.int(), target);
        index.edges.set(slot.int(), edge);
        index.counts.canonical_redirect += 1;
    }
}
fn unlinkIncoming(index: *Index, slot: EdgeId, edge: Edge) void {
    if (edge.prev_in == .none) {
        var target = index.classes.get(edge.target.int());
        std.debug.assert(target.incoming == slot);
        target.incoming = edge.next_in;
        index.classes.set(edge.target.int(), target);
    } else {
        var prev = index.edges.get(edge.prev_in.int());
        prev.next_in = edge.next_in;
        index.edges.set(edge.prev_in.int(), prev);
    }
    if (edge.next_in != .none) {
        var next = index.edges.get(edge.next_in.int());
        next.prev_in = edge.prev_in;
        index.edges.set(edge.next_in.int(), next);
    }
}
fn removeOutgoing(index: *Index, source: Store.Var) void {
    var owner = index.classes.get(source.int());
    var slot = owner.outgoing;
    owner.outgoing = .none;
    index.classes.set(source.int(), owner);
    while (slot != .none) {
        var edge = index.edges.get(slot.int());
        const next = edge.next_out;
        index.unlinkIncoming(slot, edge);
        edge.next_out = index.free;
        index.edges.set(slot.int(), edge);
        index.free = slot;
        index.counts.canonical_remove += 1;
        slot = next;
    }
}
fn register(index: *Index, gpa: Allocator, store: *const Store, source: Store.Var) Allocator.Error!void {
    var child_index: u32 = 0;
    var previous: EdgeId = .none;
    while (Walk.child(store, source, child_index, .structural)) |raw| : (child_index += 1) {
        var target = raw;
        while (store.get(target).parent != target) {
            index.counts.canonical_parent_steps += 1;
            target = store.get(target).parent;
        }
        const stepped: Walk.Stepped = if (store.content(source) == .alias)
            .{ .v = raw, .kind = if (child_index == 0) .expansion else .argument, .index = if (child_index == 0) 0 else child_index - 1 }
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
        const slot: EdgeId = if (index.free != .none) blk: {
            const reuse = index.free;
            index.free = index.edges.get(reuse.int()).next_out;
            break :blk reuse;
        } else blk: {
            const fresh_slot: EdgeId = @fromBackingInt(@intCast(index.edges.len));
            try index.edges.append(gpa, undefined);
            break :blk fresh_slot;
        };
        const incoming = index.classes.get(target.int()).incoming;
        index.edges.set(slot.int(), .{ .owner = source, .target = target, .next_in = incoming, .kind = kind, .selector = stepped.index });
        if (incoming != .none) {
            var next = index.edges.get(incoming.int());
            next.prev_in = slot;
            index.edges.set(incoming.int(), next);
        }
        var target_class = index.classes.get(target.int());
        target_class.incoming = slot;
        index.classes.set(target.int(), target_class);
        if (previous == .none) {
            var owner = index.classes.get(source.int());
            owner.outgoing = slot;
            index.classes.set(source.int(), owner);
        } else {
            var prev = index.edges.get(previous.int());
            prev.next_out = slot;
            index.edges.set(previous.int(), prev);
        }
        previous = slot;
        index.counts.canonical_register += 1;
    }
}

pub const Node = struct { source: Store.Var, position: u32, generation: u64 };
pub const Child = struct { source: Store.Var, position: u32, kind: S.EdgeKind, selector: u32 };
pub const Nodes = struct {
    index: *Index,
    position: u32 = 0,
    generation: u64,
    pub fn next(cursor: *Nodes) CursorError!?Node {
        try cursor.index.check();
        if (cursor.generation != cursor.index.generation) return error.InvalidatedCanonicalCursor;
        if (cursor.position == cursor.index.live.items.len) return null;
        const position = cursor.position;
        cursor.position += 1;
        cursor.index.counts.canonical_export_nodes += 1;
        return .{ .source = cursor.index.live.items[position], .position = position, .generation = cursor.generation };
    }
};
pub const Children = struct {
    index: *Index,
    slot: EdgeId,
    generation: u64,
    pub fn next(cursor: *Children) CursorError!?Child {
        try cursor.index.check();
        if (cursor.generation != cursor.index.generation) return error.InvalidatedCanonicalCursor;
        if (cursor.slot == .none) return null;
        const edge = cursor.index.edges.get(cursor.slot.int());
        cursor.slot = edge.next_out;
        cursor.index.counts.canonical_export_edges += 1;
        return .{ .source = edge.target, .position = cursor.index.classes.get(edge.target.int()).position, .kind = edge.kind, .selector = edge.selector };
    }
};
pub fn nodes(index: *Index) Allocator.Error!Nodes {
    try index.check();
    return .{ .index = index, .generation = index.generation };
}
pub fn children(index: *Index, node: Node) CursorError!Children {
    try index.check();
    if (node.generation != index.generation) return error.InvalidatedCanonicalCursor;
    std.debug.assert(index.classes.get(node.source.int()).position == node.position);
    return .{ .index = index, .slot = index.classes.get(node.source.int()).outgoing, .generation = index.generation };
}

/// Independent A oracle; this is verification work, not canonical construction.
/// Does not scan A's descriptor history; only live nodes/edges and O(1) source refs.
pub fn compare(index: *Index, artifact: *const S.Artifact) (CursorError || error{InvalidCanonicalIndex})!void {
    try index.check();
    if (index.live.items.len != artifact.nodes.len) return error.InvalidCanonicalIndex;
    var node_cursor = try index.nodes();
    while (try node_cursor.next()) |node| {
        index.counts.canonical_oracle_nodes += 1;
        const ordinary = artifact.nodes.get(@backingInt(artifact.descriptor_nodes[node.source.int()]));
        if (@backingInt(ordinary.source) != node.source.int()) return error.InvalidCanonicalIndex;
        var child_cursor = try index.children(node);
        var child: u32 = 0;
        while (try child_cursor.next()) |edge| : (child += 1) {
            index.counts.canonical_oracle_edges += 1;
            if (child >= ordinary.len) return error.InvalidCanonicalIndex;
            const expected = artifact.edges.get(ordinary.start + child);
            if (edge.kind != expected.kind or edge.selector != expected.selector or
                artifact.descriptor_nodes[edge.source.int()] != expected.target or edge.position == none)
                return error.InvalidCanonicalIndex;
        }
        if (child != ordinary.len) return error.InvalidCanonicalIndex;
    }
}
