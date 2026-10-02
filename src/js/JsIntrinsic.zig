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
    /// `|`, `^`, `<<`, `>>`, `>>>` and `%` (`boundary.md` §4.2, the
    /// operators core's arithmetic is written over).
    bitOr,
    bitXor,
    shiftLeft,
    shiftRight,
    shiftRightZero,
    rem,
    /// `typeof v` and `v instanceof C`.
    typeOf,
    instanceOf,
    /// `typeof v === "name"`, the name a string literal written in place
    /// (`boundary.md` §4.2, amended 2026-10-02).
    typeIs,
    /// `/pattern/flags`, from two string literals.
    regExp,
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
    /// `try { … } catch (e) { if (!test) throw e; … }` (`backend.md` §4,
    /// *`Js.catchIf` is `try … catch`*).
    catchIf,
    /// The body of `Js.pure (\() -> body)`, declared pure (`backend.md` §4,
    /// *`Js.pure` is its body*).
    pure,
    /// The body of `Js.suspending (\() -> body)`, whose call may suspend:
    /// how the fiber runtime returns its sentinel from beni (`backend.md`
    /// §4, *`Js.suspending` is its body*).
    suspending,
    ref,
    read,
    write,
    /// `true` in a development build, `false` under `--release`; an `if`
    /// on it keeps only the branch the build takes (`backend.md` §4,
    /// *`Js.development` is the build's mode*).
    development,
    /// Whether its argument, a function, may suspend: the checker's
    /// answer for the argument's class at the call, `true` or `false` in
    /// the body being written, and an `if` on it keeps only the branch
    /// that body takes (`backend.md` §4, *`Js.maySuspend` is the body's
    /// answer*).
    maySuspend,
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
    var scrutinee: Inst.Index = @enumFromInt(d.lhs);
    if (scrutinee.int() >= bir.insts.len) return null;
    // `Js.development ()`, a call since `Js` names no core type
    // (`boundary.md` §4.2, amended 2026-10-02): its callee is the intrinsic.
    if (bir.instTag(scrutinee) == .call) scrutinee = @enumFromInt(bir.instData(scrutinee).lhs);
    if (scrutinee.int() >= bir.insts.len) return null;
    if ((of(graph, interfaces, bir, scrutinee, interner) orelse return null) != .development) return null;
    return armOf(graph, interfaces, bir, inst, interner, release);
}

/// The `Js.maySuspend` call `inst`, a `case`, tests — what `if
/// Js.maySuspend f then … else …` desugars to — or null. Which arm a body
/// drops is read off the call's answer and the body being written:
/// `True`'s where the answer is no, `False`'s where it is yes (`armOf`).
pub fn probeCall(graph: *const Graph, interfaces: []const Interface, bir: *const Bir, inst: Inst.Index, interner: anytype) ?Inst.Index {
    if (inst.int() >= bir.insts.len or bir.instTag(inst) != .case) return null;
    const scrutinee: Inst.Index = @enumFromInt(bir.instData(inst).lhs);
    if (scrutinee.int() >= bir.insts.len or bir.instTag(scrutinee) != .call) return null;
    const callee: Inst.Index = @enumFromInt(bir.instData(scrutinee).lhs);
    if (callee.int() >= bir.insts.len) return null;
    if ((of(graph, interfaces, bir, callee, interner) orelse return null) != .maySuspend) return null;
    return scrutinee;
}

/// The arm of `case` instruction `inst` whose pattern is core's `True`
/// (`which` true) or `False`: its `branch` instruction, or null.
pub fn armOf(graph: *const Graph, interfaces: []const Interface, bir: *const Bir, inst: Inst.Index, interner: anytype, which: bool) ?Inst.Index {
    const d = bir.instData(inst);
    const dropped: []const u8 = if (which) "True" else "False";
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
/// The argument positions, one bit each, where a call of `which` writes a
/// literal in place: a property or global name, a regular expression's
/// pattern and flags, a JavaScript argument list. A string or list literal
/// there mints no module edge (`resolve/Graph.zig`'s `mintedModules`) and
/// is typed as a fresh variable (`check/constrain/Expr.zig`'s `call`):
/// `boundary.md` §4.2, `static-dispatch-spike.md` §6.8 and `checker-v2.md`
/// §30, amended 2026-10-02.
pub fn inPlaceLiterals(which: Which) u8 {
    return switch (which) {
        .global => 0b001,
        .get, .set => 0b010,
        .call => 0b110,
        .apply, .construct => 0b010,
        .array => 0b001,
        .regExp => 0b011,
        .typeIs => 0b010,
        else => 0,
    };
}

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
