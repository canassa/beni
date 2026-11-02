//! Recognize the direct Program definitions whose references become descriptors.
//! This early classification only removes descriptor edges from value-cycle
//! analysis. Emit validates the complete entryKinds contract before executing or
//! emitting any such definition. Manifest selectors also enter checker cache keys.
const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");

pub fn definitions(a: std.mem.Allocator, b: *const Bir, m: Graph.Index, graph: *const Graph, interfaces: []const Interface, interner: *const InternPool.Global, constructors: []const []const u8) std.mem.Allocator.Error![]const bool {
    if (constructors.len == 0) return &.{};
    const out = try a.alloc(bool, b.decls.len);
    @memset(out, false);
    for (b.decls, 0..) |d, i| {
        if (d.kind != .value or d.params_start != d.params_end) continue;
        const body = d.body.unwrap() orelse continue;
        if (b.instTag(body) != .call) continue;
        const callee: Bir.Inst.Index = @fromBackingInt(b.instData(body).lhs);
        const data = b.instData(callee);
        var module = m;
        const name = switch (b.instTag(callee)) {
            .top => b.symbol(b.decls[data.lhs].name),
            .ext_value => blk: {
                module = @fromBackingInt(data.lhs);
                if (module.int() >= interfaces.len or data.rhs >= interfaces[module.int()].values.len) continue;
                const iface = &interfaces[module.int()];
                break :blk iface.symbol(iface.values[data.rhs].name);
            },
            else => continue,
        };
        if (graph.modulePackage(module) != .platform) continue;
        const module_name = interner.slice(graph.moduleName(module));
        const base = interner.slice(name);
        for (constructors) |qualified| {
            if (qualified.len == module_name.len + 1 + base.len and std.mem.startsWith(u8, qualified, module_name) and qualified[module_name.len] == '.' and std.mem.endsWith(u8, qualified, base)) out[i] = true;
        }
    }
    return out;
}
