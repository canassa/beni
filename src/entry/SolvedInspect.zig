//! Installed ordinary graph inventory, never a HostFree/Wire certificate.
const std = @import("std");
const S = @import("../check/SolvedRepresentations.zig");
pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error || error{MissingRepresentations};
pub fn validate(session: anytype) error{MissingRepresentations}!void {
    for (session.checked.dispatch) |*table| if (!table.solved_representations.present) return error.MissingRepresentations;
}
pub fn write(gpa: std.mem.Allocator, w: *std.Io.Writer, session: anytype) Error!void {
    try validate(session);
    try w.writeAll("solved-representations schema=1 hostfree=false wire=false phase=P9-before-ownership\n");
    for (session.checked.dispatch, 0..) |*table, mi| {
        const a = &table.solved_representations;
        const module: @import("../resolve/Graph.zig").Index = @fromBackingInt(@intCast(mi));
        const marks = try gpa.alloc(bool, a.nodes.len);
        defer gpa.free(marks);
        @memset(marks, false);
        var queue: std.ArrayList(S.NodeIndex) = .empty;
        defer queue.deinit(gpa);
        for (0..a.roots.len) |i| {
            const root = a.roots.get(i);
            if (!marks[@backingInt(root.node)]) {
                marks[@backingInt(root.node)] = true;
                try queue.append(gpa, root.node);
            }
            for (a.formals[root.start..][0..root.len]) |formal| if (!marks[@backingInt(formal)]) {
                marks[@backingInt(formal)] = true;
                try queue.append(gpa, formal);
            };
        }
        var reachable_edges: u64 = 0;
        var at: usize = 0;
        while (at < queue.items.len) : (at += 1) {
            const node = a.nodes.get(@backingInt(queue.items[at]));
            reachable_edges += node.len;
            for (node.start..node.start + node.len) |ei| {
                const target = a.edges.get(ei).target;
                if (!marks[@backingInt(target)]) {
                    marks[@backingInt(target)] = true;
                    try queue.append(gpa, target);
                }
            }
        }
        try w.print("solved-module {t}:{s} D={d} T_store={d} E_store={d} F_store={d} parentEdges={d} roots={d} formals={d} reachedNodes={d} reachedEdges={d}\n", .{ session.graph.modulePackage(module), session.interner.slice(session.graph.moduleName(module)), a.counts.descriptors, a.counts.representatives, a.counts.edges, a.counts.fields, a.counts.parent_edges, a.roots.len, a.formals.len, queue.items.len, reachable_edges });
        for (0..a.roots.len) |i| {
            const root = a.roots.get(i);
            try w.print("  solved-root {d} {t} declaration={d} anchor={d} origin={t} node={d} owner=", .{ i, root.kind, root.declaration, root.anchor, root.origin, @backingInt(root.node) });
            if (root.nominal == .none) try w.writeAll("<entry>") else {
                const named = session.checked.types.named(root.nominal).?;
                try w.print("{t}:{s}.{s}", .{ named.package, session.interner.slice(named.module), session.interner.slice(named.name) });
            }
            try w.writeAll(" formals=");
            for (a.formals[root.start..][0..root.len], 0..) |formal, q| {
                if (q != 0) try w.writeByte(',');
                try w.print("{d}:{d}", .{ q, @backingInt(formal) });
            }
            try w.writeByte('\n');
        }
        for (0..a.nodes.len) |i| {
            if (!marks[i]) continue;
            const n = a.nodes.get(i);
            try w.print("  solved-node {d} source={d} {t} rank={d} kind={t} equatable={} edges=", .{ i, @backingInt(n.source), n.tag, n.rank, n.kind, n.marker_eq });
            for (n.start..n.start + n.len) |ei| {
                const edge = a.edges.get(ei);
                if (ei != n.start) try w.writeByte(',');
                try w.print("{t}:", .{edge.kind});
                if (edge.kind == .record_field) try w.print("{s}", .{session.interner.slice(@fromBackingInt(edge.selector))}) else try w.print("{d}", .{edge.selector});
                try w.print("->{d}", .{@backingInt(edge.target)});
            }
            if (n.nominal != .none) {
                const named = session.checked.types.named(n.nominal).?;
                try w.print(" nominal={t}:{s}.{s}", .{ named.package, session.interner.slice(named.module), session.interner.slice(named.name) });
            }
            try w.writeByte('\n');
        }
    }
    try w.writeAll("end-solved-representations\n");
}
