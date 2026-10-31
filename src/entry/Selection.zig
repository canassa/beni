//! Preliminary publication selection, never checked entry contract evidence.
const std = @import("std");
const Graph = @import("../resolve/Graph.zig");
const InternPool = @import("../InternPool.zig");
const Types = @import("../check/Types.zig");
const Platform = @import("../platform.zig");
const Selection = @This();
pub const Request = struct { program: []const u8, layer: u32 = 0 };
selected: []bool = &.{},
pub fn deinit(s: *Selection, gpa: std.mem.Allocator) void {
    gpa.free(s.selected);
    s.* = .{};
}
pub fn contains(s: *const Selection, id: Types.TypeId) bool {
    return id != .none and id.int() < s.selected.len and s.selected[id.int()];
}
/// Returned request rows own no strings; chain must outlive the checking run.
pub fn fromChain(gpa: std.mem.Allocator, chain: ?*const Platform.Chain) std.mem.Allocator.Error![]Request {
    var rows: std.ArrayList(Request) = .empty;
    errdefer rows.deinit(gpa);
    if (chain) |c| for (c.layers, 0..) |layer, i| {
        for (layer.manifest.entryKinds) |kind| try rows.append(gpa, .{ .program = kind.programType, .layer = @intCast(i) });
    };
    return rows.toOwnedSlice(gpa);
}
pub fn resolve(gpa: std.mem.Allocator, requests: []const Request, graph: *const Graph, types: *const Types, interner: *const InternPool.Global) std.mem.Allocator.Error!Selection {
    if (requests.len == 0) return .{};
    const selected = try gpa.alloc(bool, types.entries.len);
    @memset(selected, false);
    for (requests) |request| {
        const dot = std.mem.lastIndexOfScalar(u8, request.program, '.');
        const module_name = if (dot) |at| request.program[0..at] else request.program;
        const type_name = if (dot) |at| request.program[at + 1 ..] else request.program;
        const module = interner.find(module_name) orelse continue;
        const name = interner.find(type_name) orelse continue;
        const id = types.find(graph, .platform, module, name);
        if (id != .none and types.entry(id).kind != .alias) selected[id.int()] = true;
    }
    return .{ .selected = selected };
}
