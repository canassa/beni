//! Whether an `==` or `/=` is written as a tag and field test in place
//! (`docs/design/backend.md` §4, *`==` against a constructor is a tag and
//! field test*) — asked by two passes that must agree.
//!
//! `Lower` asks it to decide what to write: when one operand is a
//! constructor application of a `tagged` type and every field it carries is
//! compared by `===` (or, one level down, by the same test), the operator
//! is `a.$ === "Just" && a.a === e` and calls nothing. `Reach` asks it
//! BEFORE lowering, to decide the operator's dispatch edge: a site that
//! compares in place calls no derived `eq`, so it must not keep one alive
//! (§9). The two answers are one function, because a disagreement is either
//! dead code shipped (Reach keeps what Lower never calls) or a
//! `ReferenceError` at load (Reach drops what Lower still calls) — and the
//! second is the failure elimination exists to never have.
//!
//! A pure function of the module's `Bir` and dispatch table and the
//! build's interfaces: nothing here is a lowering decision that depends on
//! what was lowered before it.

const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");
const Types = @import("../check/Types.zig");

const Inst = Bir.Inst;

pub const Context = struct {
    bir: *const Bir,
    dispatch: *const Dispatch,
    interfaces: []const Interface,
    types: *const Types,
    interner: *const InternPool.Global,
};

/// A constructor application of a `tagged` type — its constructor and its
/// arguments, exactly its arity of them. A nullary constructor is its own
/// reference. `tagged` is `Lower.ctorRepOf`'s representation for a type
/// with a constructor that has fields (§4's correction 2): not `Bool`, whose
/// constructors are nullary, and not a record alias's constructor.
pub const Application = struct { ctor: Inst.Index, args: []const Inst.Index };

pub fn application(c: Context, inst: Inst.Index) ?Application {
    const bir = c.bir;
    const ctor: Inst.Index, const args: []const Inst.Index = switch (bir.instTag(inst)) {
        .call => .{ @enumFromInt(bir.instData(inst).lhs), bir.extraSlice(bir.subRange(@enumFromInt(bir.instData(inst).rhs)), Inst.Index) },
        .ctor, .ext_ctor => .{ inst, &.{} },
        else => return null,
    };
    const arity = taggedArity(c, ctor) orelse return null;
    if (arity != args.len) return null;
    return .{ .ctor = ctor, .args = args };
}

/// The arity of a constructor reference of a `tagged` type; null for any
/// other reference.
fn taggedArity(c: Context, inst: Inst.Index) ?usize {
    const bir = c.bir;
    const d = bir.instData(inst);
    switch (bir.instTag(inst)) {
        .ctor => {
            if (d.lhs >= bir.ctors.len) return null;
            const ctor = bir.ctors[d.lhs];
            const owner = bir.decls[ctor.decl.int()];
            if (owner.kind == .type_alias) return null;
            var widest: usize = 0;
            for (bir.ctors[owner.ctors_start..owner.ctors_end]) |sibling| {
                widest = @max(widest, Bir.SubRange.len(.{ .start = sibling.args_start, .end = sibling.args_end }));
            }
            if (widest == 0) return null;
            return Bir.SubRange.len(.{ .start = ctor.args_start, .end = ctor.args_end });
        },
        .ext_ctor => {
            if (d.lhs >= c.interfaces.len) return null;
            const iface = &c.interfaces[d.lhs];
            if (d.rhs >= iface.ctors.len) return null;
            const ctor = iface.ctors[d.rhs];
            if (ctor.result == .record_alias) return null;
            const owner = iface.types[@intFromEnum(ctor.type)];
            var widest: usize = 0;
            for (iface.ctors[owner.ctors_start..owner.ctors_end]) |sibling| widest = @max(widest, sibling.arity);
            if (widest == 0) return null;
            return ctor.arity;
        },
        else => return null,
    }
}

pub const FieldEq = union(enum) { strict, nested: Dispatch.TermIndex, none };

/// How field `j` of constructor `ctor` is compared under the derived `eq`
/// term `t_index`: `===`, another derived `eq`, or neither.
pub fn fieldEq(c: Context, t_index: Dispatch.TermIndex, ctor: Inst.Index, j: usize) FieldEq {
    const dispatch = c.dispatch;
    const bir = c.bir;
    const t = dispatch.term(t_index);
    const args = dispatch.argsAt(t.argsOf());
    const d = bir.instData(ctor);
    switch (t) {
        .derived => |use| {
            if (bir.instTag(ctor) != .ctor or use.index >= dispatch.derived.len) return .none;
            const row = dispatch.derived[use.index];
            if (row.kind != .eq or row.shape != .nominal) return .none;
            const ctor_row = bir.ctors[d.lhs];
            const owner = bir.decls[ctor_row.decl.int()];
            if (d.lhs < owner.ctors_start) return .none;
            var offset: usize = 0;
            for (bir.ctors[owner.ctors_start..d.lhs]) |sibling| offset += Bir.SubRange.len(.{ .start = sibling.args_start, .end = sibling.args_end });
            const parts = dispatch.argsAt(row.body);
            if (offset + j >= parts.len) return .none;
            const part = parts[offset + j];
            return switch (dispatch.term(part)) {
                .param => |param| if (param.binder == .derived and param.k < args.len) siteEq(c, args[param.k]) else .none,
                else => siteEq(c, part),
            };
        },
        .ext_derived => |use| {
            if (use.kind != .eq or bir.instTag(ctor) != .ext_ctor) return .none;
            if (d.lhs >= c.interfaces.len) return .none;
            const iface = &c.interfaces[d.lhs];
            if (d.rhs >= iface.ctors.len) return .none;
            const ctor_row = iface.ctors[d.rhs];
            if (ctor_row.arg_terms == Interface.no_terms) return .none;
            const words = iface.range(ctor_row.arg_terms);
            if (j >= words.len) return .none;
            const field = iface.term(@enumFromInt(words[j]));
            if (field.tag != .@"var") return .none;
            const published = Dispatch.publishedContext(c.interfaces, c.types, c.interner, use.type, .eq) orelse return .none;
            const count = published.iface.contextLen(published.row.context);
            for (0..count) |k| {
                const e = published.iface.contextEntry(published.row.context, k) orelse return .none;
                if (e.param != field.lhs) continue;
                if (published.iface.symbol(e.method) != InternPool.WellKnown.eq.symbol()) return .none;
                return if (k < args.len) siteEq(c, args[k]) else .none;
            }
            return .none;
        },
        else => return .none,
    }
}

fn siteEq(c: Context, t_index: Dispatch.TermIndex) FieldEq {
    return switch (c.dispatch.term(t_index)) {
        .primitive => |prim| if (prim == .strict_eq) .strict else .none,
        .derived => |use| if (use.index < c.dispatch.derived.len and c.dispatch.derived[use.index].kind == .eq) .{ .nested = t_index } else .none,
        .ext_derived => |use| if (use.kind == .eq) .{ .nested = t_index } else .none,
        else => .none,
    };
}

/// Whether `inst` is a constructor application every field of which the
/// test can compare in place under `t_index`.
pub fn testable(c: Context, t_index: Dispatch.TermIndex, inst: Inst.Index) bool {
    const app = application(c, inst) orelse return false;
    for (app.args, 0..) |arg, j| switch (fieldEq(c, t_index, app.ctor, j)) {
        .strict => {},
        .nested => |n| if (!testable(c, n, arg)) return false,
        .none => return false,
    };
    return true;
}

/// Which operand an in-place test compares against, when the operator is
/// one: the constructor application on the right, or the one on the left.
pub const Side = enum { right, left };

/// `left == right` (or `/=`) under the callee `callee`: which side is the
/// constructor application the test compares, or null when the operator
/// keeps its call. The ONE decision `Lower.ctorEquality` and `Reach` share.
pub fn side(c: Context, callee: Dispatch.TermIndex, origin: Bir.WellKnown, left: Inst.Index, right: Inst.Index) ?Side {
    if (origin != .eq and origin != .neq) return null;
    if (testable(c, callee, right)) return .right;
    if (testable(c, callee, left)) return .left;
    return null;
}

/// Whether dispatch site `site` is an operator `Lower` writes as a tag and
/// field test — so it calls neither its callee nor anything the callee's
/// evidence names. The conditions are `Lower.methodCallExpr`'s, in its
/// order: a `method_call` whose callee is a derived function, with no
/// evidence roots of its own and exactly one argument besides the receiver.
pub fn inPlace(c: Context, site: Dispatch.Site) bool {
    const bir = c.bir;
    const inst = site.inst;
    if (inst.int() >= bir.insts.len or bir.instTag(inst) != .method_call) return false;
    const callee = site.callee.unwrap() orelse return false;
    switch (c.dispatch.term(callee)) {
        .derived, .ext_derived => {},
        else => return false,
    }
    if (site.evidence.len != 0) return false;
    const d = bir.instData(inst);
    const m = bir.extraData(@enumFromInt(d.rhs), Bir.MethodCall);
    const args: Bir.SubRange = .{ .start = m.args_start, .end = m.args_end };
    if (Bir.SubRange.len(args) != 1) return false;
    const right: Inst.Index = bir.extraSlice(args, Inst.Index)[0];
    return side(c, callee, m.origin, @enumFromInt(d.lhs), right) != null;
}
