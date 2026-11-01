//! Common-install coverage for the requested diagnostic provenance artifact.
const std = @import("std");
const S = @import("SolvedRepresentations.zig");
const Dispatch = @import("Dispatch.zig");
const Bir = @import("../bir/Bir.zig");
const Types = @import("Types.zig");
const Graph = @import("../resolve/Graph.zig");
pub fn check(gpa: std.mem.Allocator, table: *const Dispatch, bir: *const Bir, types: *const Types, graph: *const Graph, resolver: anytype) std.mem.Allocator.Error!bool {
    const a = &table.solved_representations;
    if (!a.present or !a.verify()) return false;
    // A single epoch table for ALL formal scopes, never one global-ID table
    // per root. Coverage consumes only current installed declaring evidence.
    const seen = try gpa.alloc(u32, a.nodes.len);
    defer gpa.free(seen);
    @memset(seen, 0);
    const entry_aliases = try gpa.alloc(bool, table.entry_roots.types.type_refs.len);
    defer gpa.free(entry_aliases);
    @memset(entry_aliases, false);
    const nominal_aliases = try gpa.alloc(bool, table.nominal_layouts.types.type_refs.len);
    defer gpa.free(nominal_aliases);
    @memset(nominal_aliases, false);
    const entry_ids = try gpa.alloc(Types.TypeId, entry_aliases.len);
    defer gpa.free(entry_ids);
    const nominal_ids = try gpa.alloc(Types.TypeId, nominal_aliases.len);
    defer gpa.free(nominal_ids);
    for ([_]*const @import("../resolve/Interface.zig"){ &table.entry_roots.types, &table.nominal_layouts.types }, [_][]Types.TypeId{ entry_ids, nominal_ids }) |iface, ids| {
        for (iface.type_refs, ids) |ref, *id| {
            id.* = types.find(graph, ref.package, iface.symbol(ref.module), iface.symbol(ref.name));
            if (id.* == .none) return false;
        }
    }
    var entries: usize = 0;
    var nominals: usize = 0;
    for (0..a.nodes.len) |i| {
        const node = a.nodes.get(i);
        if (node.nominal == .none) continue;
        const id = resolver.id(node.nominal);
        if (id == .none or id.int() >= types.count()) return false;
        const arity = types.entry(id).arity;
        if (node.len != @as(u32, arity) + @as(u32, @intFromBool(node.tag == .alias))) return false;
        if (node.tag == .alias and types.entry(id).kind != .alias) return false;
    }
    for (0..a.roots.len) |i| {
        const root = a.roots.get(i);
        for (a.formals[root.start..][0..root.len]) |formal| {
            const ni = @backingInt(formal);
            if (seen[ni] == i + 1) return false;
            seen[ni] = @intCast(i + 1);
        }
        switch (root.kind) {
            .entry => {
                if (entries >= table.entry_roots.roots.len) return false;
                const expected = table.entry_roots.roots.get(entries);
                if (root.declaration != expected.decl.int() or root.anchor != @backingInt(expected.scheme) or root.declaration >= bir.decls.len) return false;
                const scheme = table.entry_roots.types.scheme(expected.scheme);
                if (root.len != scheme.quantified_count) return false;
                for (a.formals[root.start..][0..root.len], 0..) |formal, q| {
                    const n = a.nodes.get(@backingInt(formal));
                    const flags = table.entry_roots.types.quantified(scheme, @intCast(q));
                    if (@backingInt(n.kind) != flags.kind or n.marker_eq != flags.equatable) return false;
                }
                entries += 1;
            },
            .nominal_template => {
                while (nominals < table.nominal_layouts.owners.len and table.nominal_layouts.owners.get(nominals).kind != .adt) : (nominals += 1) {}
                if (nominals >= table.nominal_layouts.owners.len) return false;
                const owner = table.nominal_layouts.owners.get(nominals);
                const expected = nominal_ids[owner.type_ref.int()];
                if (expected == .none or resolver.id(root.nominal) != expected or root.declaration != owner.decl.int() or root.anchor != @backingInt(owner.scheme) or root.len != owner.arity) return false;
                const node = a.nodes.get(@backingInt(root.node));
                if (node.tag != .tuple or node.len == 0) return false;
                const head = a.nodes.get(@backingInt(a.edges.get(node.start).target));
                if (head.tag != .app or resolver.id(head.nominal) != expected or head.len != root.len) return false;
                for (a.formals[root.start..][0..root.len], 0..) |formal, q| if (a.edges.get(head.start + q).target != formal) return false;
                nominals += 1;
            },
            .alias_template => {
                const id = resolver.id(root.nominal);
                if (id == .none or id.int() >= types.count() or types.entry(id).kind != .alias or types.entry(id).schema_endpoint or root.len != types.entry(id).arity or root.declaration != S.none) return false;
                const iface = if (root.origin == .entry) &table.entry_roots.types else &table.nominal_layouts.types;
                const aliases = if (root.origin == .entry) entry_aliases else nominal_aliases;
                if (root.anchor >= iface.type_refs.len or aliases[root.anchor]) return false;
                aliases[root.anchor] = true;
                const ref = iface.type_refs[root.anchor];
                if (ref.body == @import("../resolve/Interface.zig").TermIndex.none or (if (root.origin == .entry) entry_ids else nominal_ids)[root.anchor] != id) return false;
            },
        }
    }
    while (nominals < table.nominal_layouts.owners.len and table.nominal_layouts.owners.get(nominals).kind != .adt) : (nominals += 1) {}
    for ([_][]const Types.TypeId{ entry_ids, nominal_ids }, [_][]bool{ entry_aliases, nominal_aliases }) |ids, marked| {
        for (ids, marked) |id, present| {
            const expected = types.entry(id).kind == .alias and !types.entry(id).schema_endpoint;
            if (expected != present) return false;
        }
    }
    return entries == table.entry_roots.roots.len and nominals == table.nominal_layouts.owners.len;
}
