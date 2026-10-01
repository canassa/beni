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
    each,
    array,
    at,
    setAt,
    throw,
    finally,
    ref,
    read,
    write,
    /// `true` in a development build, `false` under `--release`; an `if`
    /// on it keeps only the branch the build takes (`backend.md` §4,
    /// *`Js.development` is the build's mode*).
    development,
};

/// Whether `inst` is a `case` on `Js.development` — what an `if` on it
/// desugars to — and, when it is, which of its arms the build drops: the
/// `branch` instruction of the arm whose pattern is the constructor the build
/// does not take (`True` under `--release`, `False` otherwise). `Reach`
/// follows no edge out of that arm and `Lower` writes it as `undefined`,
/// so a declaration only it names is neither kept nor named.
pub fn droppedArm(graph: *const Graph, interfaces: []const Interface, bir: *const Bir, inst: Inst.Index, interner: anytype, release: bool) ?Inst.Index {
    if (inst.int() >= bir.insts.len or bir.instTag(inst) != .case) return null;
    const d = bir.instData(inst);
    const scrutinee: Inst.Index = @enumFromInt(d.lhs);
    if (scrutinee.int() >= bir.insts.len) return null;
    if ((of(graph, interfaces, bir, scrutinee, interner) orelse return null) != .development) return null;
    const dropped: []const u8 = if (release) "True" else "False";
    for (bir.extraSlice(bir.subRange(@enumFromInt(d.rhs)), Inst.Index)) |branch| {
        const b = bir.instData(branch);
        const pattern: Inst.Index = @enumFromInt(b.lhs);
        if (pattern.int() >= bir.insts.len or bir.instTag(pattern) != .pat_ctor) continue;
        const ref: Inst.Index = @enumFromInt(bir.instData(pattern).lhs);
        if (ref.int() >= bir.insts.len or bir.instTag(ref) != .ext_ctor) continue;
        const rd = bir.instData(ref);
        const module: Graph.Index = @enumFromInt(rd.lhs);
        if (module.int() >= interfaces.len or graph.module(module).package != .core) continue;
        const iface = &interfaces[module.int()];
        if (rd.rhs >= iface.ctors.len) continue;
        if (std.mem.eql(u8, interner.slice(iface.symbols[@intFromEnum(iface.ctors[rd.rhs].name)]), dropped)) return branch;
    }
    return null;
}

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
