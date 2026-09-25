//! One calling convention for a constrained value (docs/design/checker-v2.md
//! §12.5, slice R2b; `static-dispatch-spike.md` §8.1–§8.2 and §9.2 *The wide
//! form*).
//!
//! A value that takes evidence has hidden leading parameters, and four passes
//! have to agree about what they mean: `js/Lower` DEFINES the value and CALLS
//! it and REFERENCES it in value position, and `check/Cycles` decides whether
//! its initialiser RUNS at module load. Before R2b each of them read the
//! declaration's parameter count on its own, and they disagreed: a
//! zero-parameter value of function type, `h = maxOf` under a `where`, was
//! defined `($m) => value`, called `h(ev, 1, 2)` and, imported, eta-expanded
//! over its type's arity — three conventions for one value (CK-33) — and an
//! evidence-only constant counted as deferring though every read runs it
//! (CK-34). Every one of those readings is now a function of this file.
//!
//! **The three conventions.** A value is
//!
//!   - `plain` — it takes no evidence. Defined, called and referenced as
//!     `backend.md` §4 and §6 always did;
//!   - `function` — it takes evidence and is a function: it has parameters,
//!     its entire body is a `lambda`, or its TYPE is a function (a
//!     zero-parameter `h = maxOf`). Defined `($m…, p1…pn) => …` with `n` its
//!     type's arity, called flat `f(ev…, args…)`, and in value position
//!     eta-expanded over `n` (A.25);
//!   - `thunk` — it takes evidence, has no parameters and its type is not a
//!     function (`blank : List a where a.eq …`). Defined `($m…) => value`, and
//!     every read is `f(ev…)`: the body RUNS at each read (A.85).
//!
//! **Where the answer comes from.** The checker computes it once per
//! declaration with `of` and stores it in `Dispatch.DeclInfo.convention`
//! beside `requirements` and `value_arity` (§13.1); `ofDecl` reads it back.
//! An IMPORTED value has no `DeclInfo` here, so `ofImport` computes it with
//! the same `of` from the two facts its interface publishes, the requirement
//! count and the type's arity. That is the same answer the exporter stored,
//! because for a module that checked a value's parameter count, and a
//! `lambda` body's, IS its type's arity — which is why a definition with
//! parameters and one without agree across a module boundary.
//!
//! **The wide form** is a fifth reading and lives here for the same reason:
//! whether a DERIVED function takes its evidence one parameter per entry or
//! as one array is decided by the entry count, and the definition and every
//! caller must decide it alike (`derivedEvidence`, A.87).

const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const Dispatch = @import("Dispatch.zig");

/// The `DeclInfo.convention` column (§13.1). Its counts are not repeated in
/// it: the evidence is `DeclInfo.requirements.len` and the arity
/// `DeclInfo.value_arity`, one source each.
pub const Convention = enum(u8) {
    plain,
    function,
    thunk,
};

/// The convention of a value from what its declaration looks like: its
/// written parameter count, whether its entire body is a `lambda`, its
/// type's arity (0 for a non-function) and its evidence count.
///
/// The ONE function the question is answered by, for a declaration of this
/// module (the checker stores the answer) and for an import (`ofImport`,
/// which knows no parameters and no body and passes 0 and `false`).
pub fn of(decl_params: u32, body_is_lambda: bool, value_arity: u32, evidence: u32) Convention {
    if (evidence == 0) return .plain;
    if (decl_params != 0 or body_is_lambda or value_arity != 0) return .function;
    return .thunk;
}

/// A value as a CALLER sees it: its convention and the two counts that go
/// with it.
pub const Use = struct {
    convention: Convention,
    /// How many hidden leading parameters it takes.
    evidence: u32,
    /// Its beni arity: the parameters a `function` is defined over after
    /// its evidence. 0 for a `thunk` and for a non-function.
    arity: u32,
};

/// A declaration of THIS module, from its `DeclInfo`. The arity is the
/// written parameter count when there is one — the parameters the
/// definition really has — and the type's arity otherwise.
pub fn ofDecl(dispatch: *const Dispatch, bir: *const Bir, decl: u32) Use {
    const params: u32 = if (decl < bir.decls.len) bir.decls[decl].params else 0;
    if (decl >= dispatch.decls.len) return .{ .convention = .plain, .evidence = 0, .arity = params };
    const info = dispatch.decls[decl];
    return .{
        .convention = info.convention,
        .evidence = info.requirements.len,
        .arity = if (params != 0) params else info.value_arity,
    };
}

/// Whether declaration `decl`'s ENTIRE body is a `lambda` — the one place
/// the question is asked, by `Dispatch.finish` (for `of`), `Cycles` and
/// `Lower` (for `definition`). False for a declaration with no body.
pub fn bodyIsLambda(bir: *const Bir, decl: u32) bool {
    if (decl >= bir.decls.len) return false;
    const body = bir.decls[decl].body.unwrap() orelse return false;
    return bir.instTag(body) == .lambda;
}

/// `definition` of declaration `decl` of this module, from its stored
/// convention, its written parameters and `bodyIsLambda`.
pub fn definitionOf(dispatch: *const Dispatch, bir: *const Bir, decl: u32) Definition {
    const params: u32 = if (decl < bir.decls.len) bir.decls[decl].params else 0;
    return definition(ofDecl(dispatch, bir, decl).convention, params, bodyIsLambda(bir, decl));
}

/// A value of ANOTHER module, from its interface scheme: the requirement
/// count `Dispatch.extRequirementCount` gives every consumer, and the arity
/// of the scheme's body through any alias (`importArity`).
pub fn ofImport(interfaces: []const Interface, module: Graph.Index, value: u32) Use {
    const evidence = Dispatch.extRequirementCount(interfaces, module, value);
    const arity = importArity(interfaces, module, value);
    return .{ .convention = of(0, false, arity, evidence), .evidence = evidence, .arity = arity };
}

/// The beni arity of an imported value: the parameter count of its scheme's
/// body when that body is a function type, looking through `alias` terms as
/// `TypeStore.paramCount` does for the exporter's `value_arity` — so
/// `pub same : Pred a` with `type alias Pred a = a -> Bool` has arity 1 on
/// both sides of the boundary (CK-84). Zero for a non-function.
pub fn importArity(interfaces: []const Interface, module: Graph.Index, value: u32) u32 {
    if (module.int() >= interfaces.len) return 0;
    const iface = &interfaces[module.int()];
    if (value >= iface.values.len) return 0;
    const index = iface.values[value].scheme;
    if (index == .none or @intFromEnum(index) >= iface.schemes.len) return 0;
    var at = iface.scheme(index).body;
    // An alias term's LAST extra word is its expansion (`Interface.Term`).
    // Each step moves to a term written before it, so the walk ends; the
    // bound is only a guard against a malformed interface.
    var steps: u32 = 0;
    while (steps < iface.terms.len) : (steps += 1) {
        if (at == .none or at.int() >= iface.terms.len) return 0;
        const t = iface.term(at);
        switch (t.tag) {
            .func => return @intCast(iface.range(t.lhs).len),
            .alias => {
                const words = iface.range(t.rhs);
                if (words.len == 0) return 0;
                at = @enumFromInt(words[words.len - 1]);
            },
            else => return 0,
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// The readings
// ---------------------------------------------------------------------------

/// How `Lower.declaration` DEFINES a value with a body.
pub const Definition = enum {
    /// `const f = value;` — plain, no parameters, a body that is not a
    /// `lambda`. Evaluated once, at load.
    constant,
    /// `($m…, p1…pn) => body` over the written parameters.
    params,
    /// `($m…, x…) => e` for a body `\x… -> e`: the lambda's own parameters,
    /// which is what makes `f x = e` and `f = \x -> e` one program (§8's
    /// narrow rule in `backend.md`, and with evidence too).
    lambda,
    /// `($m…, $p1…$pn) => body($p1…$pn)`: a zero-parameter `function` whose
    /// body is not a lambda, applied to fresh parameters over its type's
    /// arity. The body is evaluated at each call (`language.md` §6, CK-85),
    /// and for `Cycles` it is still a VALUE (`defers`).
    applied,
    /// `($m…) => value`: every read runs it.
    thunk,
};

pub fn definition(c: Convention, decl_params: u32, body_is_lambda: bool) Definition {
    if (decl_params != 0) return .params;
    if (body_is_lambda) return .lambda;
    return switch (c) {
        .plain => .constant,
        .function => .applied,
        .thunk => .thunk,
    };
}

/// Whether the value is a FUNCTION for `language.md` §7's initialisation
/// rule — the `Cycles` reading (`checker.md` §6.7). The rule is stated over
/// the SOURCE: a value written with parameters or with a `lambda` as its
/// whole body is a function and defers; every other value is a value, and
/// may not be reachable from its own initialiser, whether or not a `where`
/// gives it evidence. So `constant`, `thunk` (every read runs it, CK-34)
/// and `applied` (`h = compose h g` under a `where`: the emitter makes it an
/// arrow, but the source wrote a value, and its twin without the `where` is
/// refused) all RUN. The manager's decision on R2b's review (B1): a `where`
/// is a type annotation and must not change which programs are accepted.
pub fn defers(d: Definition) bool {
    return switch (d) {
        .params, .lambda => true,
        .constant, .thunk, .applied => false,
    };
}

/// How a CALL of the value passes its evidence: `flat`, `f(ev…, args…)`,
/// or `applied`, `f(ev…)(args…)` — a thunk's evidence yields the value, and
/// only then can it be applied. A thunk's type is not a function, so no
/// checked program calls one; the answer is still the one its definition
/// implies.
pub const Call = enum { flat, applied };

pub fn call(c: Convention) Call {
    return switch (c) {
        .plain, .function => .flat,
        .thunk => .applied,
    };
}

/// A REFERENCE in value position (spike §8.2, A.25, A.85): `null` is the
/// bare name (no evidence to bind), 0 is the evidence applied — the thunk's
/// read — and `n` the eta-expansion `(p1…pn) => f(ev…, p1…pn)`.
pub fn referenceArity(u: Use) ?u32 {
    return switch (u.convention) {
        .plain => null,
        .function => u.arity,
        .thunk => 0,
    };
}

// ---------------------------------------------------------------------------
// The wide form (spike §9.2, A.87)
// ---------------------------------------------------------------------------

/// The widest derived function that takes its evidence one parameter per
/// position; a wider one, of any shape, takes one array. An ABI number of
/// the BACKEND's, deliberately not tied to the checker: it equals CK-79's
/// cap on a record `==` today, which is why no golden moved, and R8a lifting
/// that cap must not change the calling convention with it. Measured under
/// Node 24 only: a 60 002-argument call from inside another function
/// overflows the default stack, and a function of more than 65 535
/// parameters is a `SyntaxError` in V8 (CK-81). Browser engines are
/// unmeasured (R2c).
pub const max_positional_evidence: usize = 4096;

/// How a derived function with `count` evidence entries takes them, and so
/// how every caller passes them. Decided by the COUNT, which the declaring
/// module and every caller agree on (the row's context length either way),
/// so a cross-module nominal needs no flag in any table.
pub const DerivedEvidence = enum { positional, array };

pub fn derivedEvidence(count: usize) DerivedEvidence {
    return if (count > max_positional_evidence) .array else .positional;
}

test "of: evidence decides plain, the type decides function or thunk" {
    const t = std.testing;
    try t.expectEqual(Convention.plain, of(0, false, 0, 0));
    try t.expectEqual(Convention.plain, of(2, false, 2, 0));
    try t.expectEqual(Convention.function, of(2, false, 2, 1));
    try t.expectEqual(Convention.function, of(0, true, 2, 1));
    // CK-33: `h = maxOf`, no parameters, a function TYPE.
    try t.expectEqual(Convention.function, of(0, false, 2, 1));
    // CK-34: `zs : List a where a.eq …`.
    try t.expectEqual(Convention.thunk, of(0, false, 0, 1));
}

test "definition and defers agree for every convention" {
    const t = std.testing;
    try t.expectEqual(Definition.constant, definition(.plain, 0, false));
    try t.expectEqual(Definition.lambda, definition(.plain, 0, true));
    try t.expectEqual(Definition.params, definition(.function, 1, false));
    try t.expectEqual(Definition.lambda, definition(.function, 0, true));
    try t.expectEqual(Definition.applied, definition(.function, 0, false));
    try t.expectEqual(Definition.thunk, definition(.thunk, 0, false));
    try t.expect(!defers(.constant));
    try t.expect(!defers(.thunk));
    try t.expect(!defers(.applied));
    try t.expect(defers(.lambda));
    try t.expect(defers(.params));
}

test "a reference is the bare name, the applied thunk, or the eta-expansion" {
    const t = std.testing;
    try t.expectEqual(@as(?u32, null), referenceArity(.{ .convention = .plain, .evidence = 0, .arity = 2 }));
    try t.expectEqual(@as(?u32, 0), referenceArity(.{ .convention = .thunk, .evidence = 1, .arity = 0 }));
    try t.expectEqual(@as(?u32, 2), referenceArity(.{ .convention = .function, .evidence = 1, .arity = 2 }));
    try t.expectEqual(Call.flat, call(.function));
    try t.expectEqual(Call.applied, call(.thunk));
}

test "the wide form starts past the positional limit" {
    const t = std.testing;
    try t.expectEqual(DerivedEvidence.positional, derivedEvidence(max_positional_evidence));
    try t.expectEqual(DerivedEvidence.array, derivedEvidence(max_positional_evidence + 1));
}
