//! Conservative checked-declaration liveness. No deferred descriptor cuts or
//! interpretation of liveness as executed callbacks/initializers is performed.
const std = @import("std");
const Reach = @import("../js/Reach.zig");
const Ir = @import("Compact.zig");
const Graph = @import("CompactGraph.zig");
const Plan = @import("Plan.zig");
const sentinel = std.math.maxInt(u32);
const Root = struct { source: Ir.SiteId, next: u32 };

pub fn append(a: std.mem.Allocator, scratch: std.mem.Allocator, in: Reach.Input, plan: *const Plan, ir: *const Ir, graph: *Graph) std.mem.Allocator.Error!void {
    const heads = try scratch.alloc(u32, graph.entries.len);
    @memset(heads, sentinel);
    var sources: std.MultiArrayList(Root) = .empty;
    defer sources.deinit(scratch);
    for (0..graph.callbacks.len) |i| {
        const callback = graph.callbacks.get(i);
        const ei = @backingInt(callback.entry);
        const index: u32 = @intCast(sources.len);
        const origin = ir.origins.get(@backingInt(callback.origin));
        try sources.append(scratch, .{ .source = origin.site, .next = heads[ei] });
        heads[ei] = index;
    }
    const seen = try scratch.alloc(u32, ir.declarations.len);
    @memset(seen, sentinel);
    var roots: std.ArrayList(Reach.Node) = .empty;
    defer roots.deinit(scratch);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    for (0..graph.entries.len) |ei| {
        _ = arena.reset(.retain_capacity);
        roots.clearRetainingCapacity();
        const entry_id: Graph.EntryId = @fromBackingInt(@intCast(ei));
        const entry = graph.entries.get(ei);
        const anchor = ir.anchors.get(@backingInt(entry.anchor));
        const root: Reach.Node = .{ .module = @fromBackingInt(@backingInt(anchor.module)), .kind = .decl, .index = @backingInt(anchor.declaration) };
        const runtime = plan.kinds.get(@backingInt(entry.kind)).runtime;
        try addRoot(scratch, ir, seen, @intCast(ei), &roots, .{ .module = runtime.module, .kind = .decl, .index = runtime.decl });
        var source = heads[ei];
        while (source != sentinel) : (source = sources.get(source).next) {
            const site = ir.sites.get(@backingInt(sources.get(source).source));
            try addRoot(scratch, ir, seen, @intCast(ei), &roots, .{ .module = @fromBackingInt(@backingInt(site.module)), .kind = .decl, .index = @backingInt(site.declaration) });
        }
        var reach = in;
        reach.entry = root;
        reach.extra_roots = roots.items;
        reach.library = false;
        // No unproved callback deferral is smuggled into a liveness cut.
        reach.cuts = &.{};
        const live = try Reach.run(arena.allocator(), reach);
        graph.counts.liveness_runs += 1;
        for (live.modules, 0..) |module, mi| {
            const columns = .{ "decls", "derived", "twins", "ctors", "schemas", "lifts" };
            const tags = .{ Graph.LiveTag.decl, Graph.LiveTag.derived, Graph.LiveTag.twin, Graph.LiveTag.ctor, Graph.LiveTag.schema, Graph.LiveTag.lift };
            inline for (columns, tags) |column, tag| {
                const bits = @field(module, column);
                for (0..bits.bit_length) |index| if (bits.isSet(index)) {
                    try graph.live_nodes.append(a, .{ .entry = entry_id, .module = @fromBackingInt(@intCast(mi)), .tag = tag, .index = @fromBackingInt(@intCast(index)) });
                    graph.counts.liveness_nodes += 1;
                };
            }
        }
    }
    graph.declaration_liveness = .conservative;
}
fn addRoot(a: std.mem.Allocator, ir: *const Ir, seen: []u32, epoch: u32, roots: *std.ArrayList(Reach.Node), value: Reach.Node) !void {
    const slot = ir.modules.get(value.module.int()).declarations.start + value.index;
    if (seen[slot] == epoch) return;
    seen[slot] = epoch;
    try roots.append(a, value);
}
