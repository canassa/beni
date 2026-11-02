//! Direct recipes are available only for generated core operations. Adapters
//! that construct Result/Maybe stay in their generated, precisely typed sibling.
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const Operations = @import("../native/Operations.zig");
pub fn of(graph: *const Graph, interfaces: []const Interface, bir: *const Bir, module: Graph.Index, inst: Bir.Inst.Index, interner: anytype) ?Operations.Row {
    var owner = module;
    var name: []const u8 = undefined;
    const data = bir.instData(inst);
    switch (bir.instTag(inst)) {
        .ext_value => {
            owner = @fromBackingInt(@intCast(data.lhs));
            const iface = &interfaces[owner.int()];
            if (data.rhs >= iface.values.len) return null;
            name = interner.slice(iface.symbol(iface.values[data.rhs].name));
        },
        .top => {
            if (data.lhs >= bir.decls.len) return null;
            name = interner.slice(bir.symbol(bir.decls[data.lhs].name));
        },
        else => return null,
    }
    if (graph.modulePackage(owner) != .core) return null;
    return Operations.lookup(interner.slice(graph.moduleName(owner)), name);
}
