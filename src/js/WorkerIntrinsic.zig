//! The platform-private worker event build constant. Emit supplies the trusted
//! embedded owner and the conservative answer for this projection; no stored
//! value or runtime type inspection is involved (boundary.md §4.2).
const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const JsIntrinsic = @import("JsIntrinsic.zig");

pub fn isReference(owner: ?Graph.Index, module: Graph.Index, interfaces: []const Interface, bir: *const Bir, inst: Bir.Inst.Index, interner: anytype) bool {
    const target = owner orelse return false;
    if (inst.int() >= bir.insts.len) return false;
    const data = bir.instData(inst);
    const name = switch (bir.instTag(inst)) {
        .top => blk: {
            if (module != target or data.lhs >= bir.decls.len) return false;
            break :blk bir.symbol(bir.decls[data.lhs].name);
        },
        .ext_value => blk: {
            if (data.lhs != target.int() or target.int() >= interfaces.len) return false;
            const iface = &interfaces[target.int()];
            if (data.rhs >= iface.values.len) return false;
            break :blk iface.symbols[@backingInt(iface.values[data.rhs].name)];
        },
        else => return false,
    };
    return std.mem.eql(u8, interner.slice(name), "eventsPossible");
}

pub fn droppedArm(owner: ?Graph.Index, module: Graph.Index, graph: *const Graph, interfaces: []const Interface, bir: *const Bir, inst: Bir.Inst.Index, interner: anytype, possible: bool) ?Bir.Inst.Index {
    if (inst.int() >= bir.insts.len or bir.instTag(inst) != .case) return null;
    const condition: Bir.Inst.Index = @fromBackingInt(@intCast(bir.instData(inst).lhs));
    if (condition.int() >= bir.insts.len or bir.instTag(condition) != .call) return null;
    const call = bir.instData(condition);
    if (!isReference(owner, module, interfaces, bir, @fromBackingInt(@intCast(call.lhs)), interner)) return null;
    const args = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(call.rhs))), Bir.Inst.Index);
    // A nonliteral unit argument may do work. Lower still writes the constant,
    // but preserves argument evaluation before testing the resulting literal.
    if (args.len != 1 or bir.instTag(args[0]) != .unit) return null;
    return JsIntrinsic.armOf(graph, interfaces, bir, inst, interner, !possible);
}
