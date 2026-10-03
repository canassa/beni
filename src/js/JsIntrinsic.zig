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
const same = @import("Operator.zig").same;

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
    /// `{ k: v, … }`: an object literal, its keys written as written — a
    /// list literal of `( "key", value )` pairs (`backend.md` §4, *`Js.object`
    /// is an object literal*).
    object,
    /// `function () { const self = this; … }`: a method JavaScript calls on
    /// a receiver, its lambda handed the receiver (`backend.md` §4,
    /// *`Js.method` is a `function`*).
    method,
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
    /// The identity of its argument's type: the identity term its site
    /// carries, a string literal or a concatenation (`backend.md` §4,
    /// *`Js.fingerprint` is its type's identity*).
    fingerprint,
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
    var scrutinee: Inst.Index = @fromBackingInt(@intCast(d.lhs));
    if (scrutinee.int() >= bir.insts.len) return null;
    // `Js.development ()`, a call since `Js` names no core type
    // (`boundary.md` §4.2, amended 2026-10-02): its callee is the intrinsic.
    if (bir.instTag(scrutinee) == .call) scrutinee = @fromBackingInt(@intCast(bir.instData(scrutinee).lhs));
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
    const scrutinee: Inst.Index = @fromBackingInt(@intCast(bir.instData(inst).lhs));
    if (scrutinee.int() >= bir.insts.len or bir.instTag(scrutinee) != .call) return null;
    const callee: Inst.Index = @fromBackingInt(@intCast(bir.instData(scrutinee).lhs));
    if (callee.int() >= bir.insts.len) return null;
    if ((of(graph, interfaces, bir, callee, interner) orelse return null) != .maySuspend) return null;
    return scrutinee;
}

/// The arm of `case` instruction `inst` whose pattern is core's `True`
/// (`which` true) or `False`: its `branch` instruction, or null.
pub fn armOf(graph: *const Graph, interfaces: []const Interface, bir: *const Bir, inst: Inst.Index, interner: anytype, which: bool) ?Inst.Index {
    const d = bir.instData(inst);
    const dropped: []const u8 = if (which) "True" else "False";
    for (bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(d.rhs))), Inst.Index)) |branch| {
        const b = bir.instData(branch);
        const pattern: Inst.Index = @fromBackingInt(@intCast(b.lhs));
        if (pattern.int() >= bir.insts.len or bir.instTag(pattern) != .pat_ctor) continue;
        const ref: Inst.Index = @fromBackingInt(@intCast(bir.instData(pattern).lhs));
        if (ref.int() >= bir.insts.len or bir.instTag(ref) != .ext_ctor) continue;
        const rd = bir.instData(ref);
        const module: Graph.Index = @fromBackingInt(@intCast(rd.lhs));
        if (module.int() >= interfaces.len or graph.modulePackage(module) != .core) continue;
        const iface = &interfaces[module.int()];
        if (rd.rhs >= iface.ctors.len) continue;
        if (std.mem.eql(u8, interner.slice(iface.symbols[@backingInt(iface.ctors[rd.rhs].name)]), dropped)) return branch;
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
        .array, .object => 0b001,
        .regExp => 0b011,
        .typeIs => 0b010,
        else => 0,
    };
}

/// What is wrong with `Js.object`'s argument (`boundary.md` §4.2), and the
/// instruction to report it at.
pub const ObjectFault = struct {
    kind: Kind,
    at: Inst.Index,

    pub const Kind = enum { not_a_list, not_a_pair, key_not_a_string, key_not_an_identifier, proto_key, duplicate_key };
};

/// Null when `arg` is a list literal of `( "key", value )` pairs, each key a
/// string literal that is an ASCII JavaScript identifier other than
/// `__proto__` — which in a literal sets the prototype rather than making
/// a field — and no key twice; otherwise the first fault. The checker
/// reports it (`invalid_js_object`); `Lower` relies on there being none.
pub fn objectFault(bir: *const Bir, arg: Inst.Index) ?ObjectFault {
    if (bir.instTag(arg) != .list) return .{ .kind = .not_a_list, .at = arg };
    const elements = bir.extraSlice(Bir.inlineRange(bir.instData(arg)), Inst.Index);
    for (elements, 0..) |el, i| {
        const key = objectKey(bir, el) orelse return .{ .kind = .not_a_pair, .at = el };
        if (bir.instTag(key) != .string) return .{ .kind = .key_not_a_string, .at = key };
        const bytes = bir.bytes(key);
        if (!isIdentifier(bytes)) return .{ .kind = .key_not_an_identifier, .at = key };
        if (std.mem.eql(u8, bytes, "__proto__")) return .{ .kind = .proto_key, .at = key };
        for (elements[0..i]) |before| {
            if (std.mem.eql(u8, bir.bytes(objectKey(bir, before).?), bytes)) return .{ .kind = .duplicate_key, .at = key };
        }
    }
    return null;
}

/// The key instruction of a field of `Js.object`, a pair literal, or null
/// when the field is not a pair.
pub fn objectKey(bir: *const Bir, field: Inst.Index) ?Inst.Index {
    if (bir.instTag(field) != .tuple) return null;
    const pair = bir.extraSlice(Bir.inlineRange(bir.instData(field)), Inst.Index);
    if (pair.len != 2) return null;
    return pair[0];
}

/// The value instruction of a well-formed field of `Js.object`.
pub fn objectValue(bir: *const Bir, field: Inst.Index) Inst.Index {
    return bir.extraSlice(Bir.inlineRange(bir.instData(field)), Inst.Index)[1];
}

/// An ASCII JavaScript identifier, `$` and `_` allowed.
pub fn isIdentifier(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes, 0..) |c, i| {
        const ok = std.ascii.isAlphabetic(c) or c == '_' or c == '$' or (i != 0 and std.ascii.isDigit(c));
        if (!ok) return false;
    }
    return true;
}

pub fn of(graph: *const Graph, interfaces: []const Interface, bir: *const Bir, inst: Inst.Index, interner: anytype) ?Which {
    if (bir.instTag(inst) != .ext_value) return null;
    const d = bir.instData(inst);
    const module: Graph.Index = @fromBackingInt(@intCast(d.lhs));
    if (module.int() >= interfaces.len) return null;
    if (graph.modulePackage(module) != .core) return null;
    if (!same(interner.slice(graph.moduleName(module)), "Js")) return null;
    const iface = &interfaces[module.int()];
    if (d.rhs >= iface.values.len) return null;
    return std.meta.stringToEnum(Which, interner.slice(iface.symbols[@backingInt(iface.values[d.rhs].name)]));
}
