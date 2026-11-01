//! Source record inspection boundary; execution solver integration follows.
//! This section does not claim realm/entry/callable availability certification.
const std = @import("std");
const Graph = @import("../resolve/Graph.zig");
const InternPool = @import("../InternPool.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Source = @import("../check/RealmSource.zig");
const Allocator = std.mem.Allocator;
pub const Input = struct { graph: *const Graph, interner: *const InternPool.Global, dispatch: []const Dispatch };
pub const Prepared = struct {
    bytes: []u8,
    pub fn deinit(p: *Prepared, gpa: Allocator) void {
        gpa.free(p.bytes);
        p.* = undefined;
    }
    pub fn write(p: *const Prepared, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(p.bytes);
    }
};
pub const Error = Allocator.Error || error{ MissingRealmSource, InvalidRealmSource };
pub fn prepare(gpa: Allocator, in: Input) Error!Prepared {
    if (in.dispatch.len != in.graph.count()) return error.MissingRealmSource;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    w.writeAll("native-realm-source schema=1 proof=source-records realmProved=false entryComplete=false\n") catch return error.OutOfMemory;
    for (in.dispatch, 0..) |*table, mi| {
        const artifact = &table.realm_sources;
        if (!artifact.present) return error.MissingRealmSource;
        if (!artifact.verify()) return error.InvalidRealmSource;
        const module: Graph.Index = @fromBackingInt(@as(u32, @intCast(mi)));
        w.print("  realm-module {d} {t}:{s} scopes={d} nodes={d} refs={d}\n", .{ mi, in.graph.modulePackage(module), in.interner.slice(in.graph.moduleName(module)), artifact.scopes.len, artifact.nodes.len, artifact.refs.len }) catch return error.OutOfMemory;
        for (0..artifact.scopes.len) |i| {
            const scope = artifact.scopes.get(i);
            w.print("  realm-scope {d}:{d} decl={d} source={d} kind={t} parent={d} body={d} params={d}\n", .{ mi, i, scope.declaration, scope.instruction, scope.kind, @backingInt(scope.parent), scope.body, scope.parameters.len }) catch return error.OutOfMemory;
        }
        for (0..artifact.nodes.len) |i| {
            const node = artifact.nodes.get(i);
            if (node.scope == .none) continue;
            if (node.role != .expression and node.role != .pattern and node.role != .annotation) w.print("  realm-literal {d}:{d} decl={d} scope={d} role={t}\n", .{ mi, i, node.declaration, @backingInt(node.scope), node.role }) catch return error.OutOfMemory;
            if (node.role != .expression) continue;
            if (Source.isCall(node, artifact.refs)) w.print("  realm-call {d}:{d} decl={d} scope={d} tag={t} blocked={}\n", .{ mi, i, node.declaration, @backingInt(node.scope), node.tag, node.blocked }) catch return error.OutOfMemory;
            if (node.ref != Source.none) {
                const ref = artifact.refs.get(node.ref);
                w.print("  realm-reference {d}:{d} decl={d} scope={d} kind={t} module={d} value={d}\n", .{ mi, i, node.declaration, @backingInt(node.scope), ref.kind, @backingInt(ref.module), ref.value }) catch return error.OutOfMemory;
            }
        }
    }
    return .{ .bytes = try out.toOwnedSlice() };
}
