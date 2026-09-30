//! The `Js` intrinsics (research 47, a spike): core's `Js` module declares
//! each as a `foreign`, so the checker types every use, and the backend
//! writes a saturated call of one as the JavaScript it names — `o.f`,
//! `o.f = v`, `a === b` — with no call and no import. `Lower` writes them
//! and `Reach` drops the edge a written-in-place use would otherwise add,
//! so the sibling `core/Js.js` ships only for a declaration passed as a
//! value.
//!
//! Keyed on the core package and the module's name, never on a user's
//! spelling: a root-package module named `Js` is an ordinary module.

const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");

const Inst = Bir.Inst;

pub const Which = enum {
    null,
    undefined,
    from,
    to,
    same,
    isNull,
    isUndefined,
    isNullish,
    bitAnd,
    global,
    get,
    set,
    call,
    apply,
    construct,
    array,
    at,
    throw,
    ref,
    read,
    write,
};

/// The intrinsic `inst` names, or null: an `ext_value` of core's `Js`.
/// `interner` is anything with `slice(Symbol) []const u8`.
pub fn of(graph: *const Graph, interfaces: []const Interface, bir: *const Bir, inst: Inst.Index, interner: anytype) ?Which {
    if (bir.instTag(inst) != .ext_value) return null;
    const d = bir.instData(inst);
    const module: Graph.Index = @enumFromInt(d.lhs);
    if (module.int() >= interfaces.len) return null;
    if (graph.module(module).package != .core) return null;
    if (!std.mem.eql(u8, interner.slice(graph.moduleName(module)), "Js")) return null;
    const iface = &interfaces[module.int()];
    if (d.rhs >= iface.values.len) return null;
    return std.meta.stringToEnum(Which, interner.slice(iface.symbols[@intFromEnum(iface.values[d.rhs].name)]));
}
