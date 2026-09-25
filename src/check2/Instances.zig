//! Instance lookup (checker-v2.md §9.3) and THE derivability verdict (§9.5,
//! as built by R6a's review): the answer for a wanted on a structure.
//!
//! Free functions over the solver: a lookup unifies, instantiates and
//! reports, which are the solver's (`Resolve.zig` calls in; nothing here runs
//! inside a probe, I14). The marker walk of §11.4 is `Marker.zig`'s. The
//! order is §9.3's, v1's rules verbatim (static-dispatch-spike.md §6.3,
//! §6.3.1):
//!
//!   1. the well-known table (§3.2), for `eq`/`compare` on a core primitive,
//!      after the method type is unified with `t, t -> Bool|Order` (CK-21);
//!   3. the module rule: `T`'s declaring module's value of that name — this
//!      module's any (the P3 index), another's `pub`, or `private_method` —
//!      whose scheme is instantiated per use, its requirements the
//!      sub-wanteds in canonical order (I5), and matched against the
//!      wanted's method type;
//!   5. derivation, for a well-known name asked by anything but a dot-call:
//!      `derivability`, the ONE answer to "can this receiver derive the
//!      method" (I10; review B1) — it reports why not — then one sub-wanted
//!      per position: a nominal type's arguments (v1's one-entry-per-
//!      parameter rule, until R8a's derived contexts), a closed record's
//!      fields, a tuple's elements;
//!   6. `unknown_method`.
//!
//! **Capability until R8a** is read here and only here: the session's
//! capability bits (`Types.answersEq`/`answersCompare`, `hasFunction`, the
//! method-boundary requirements), which `Module` settles with the shared
//! `Types.settleDispatchCapabilities`. R8a replaces all of it with §11.2's
//! fixpoint (`rules_test.zig` fences the names).

const std = @import("std");
const InternPool = @import("../InternPool.zig");
const Interface = @import("../resolve/Interface.zig");
const Graph = @import("../resolve/Graph.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Types = @import("../check/Types.zig");
const reads = @import("../check/reads.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Diagnostics = @import("../check/Diagnostics.zig");
const Solve = @import("Solve.zig");
const Resolve = @import("Resolve.zig");
const Evidence = @import("Evidence.zig");
const Walk = @import("Walk.zig");

const Var = TypeStore.Var;
const Error = Solve.Error;
const WantedId = Evidence.WantedId;

/// Resolve wanted `id` on the concrete root `root`, whose content is `flat`.
pub fn lookup(s: *Solve, id: WantedId, root: Var, flat: TypeStore.Structure, immediate: bool) Error!void {
    switch (flat) {
        .app => |a| return onApp(s, id, root, a),
        .record => |r| return onRecord(s, id, root, r, immediate),
        .empty_record => return onRecord(s, id, root, .{ .fields = .empty, .ext = root }, immediate),
        .tuple, .unit => {
            const w = s.evidence.get(id);
            if (!Resolve.derives(w)) return noMethods(s, id, root);
            if (!try derivable(s, id, root)) return;
            if (!try Resolve.unifyWellKnown(s, id, root)) return Resolve.reject(s, id, false);
            return derivedPositions(s, id, root, .none, childrenOf(s, root));
        },
        .func => {
            const w = s.evidence.get(id);
            // `eq` on a function keeps `not_equatable`, the better message.
            if (w.method == InternPool.WellKnown.eq.symbol()) {
                try s.report.notEquatable(w.origin, root, .function);
            } else {
                try s.report.noMethodsOnShape(w.origin, w.method, root, .function);
            }
            return Resolve.reject(s, id, true);
        },
    }
}

fn childrenOf(s: *Solve, root: Var) []const Var {
    return Walk.positions(s.store(), root);
}

fn noMethods(s: *Solve, id: WantedId, root: Var) Error!void {
    const w = s.evidence.get(id);
    try s.report.noMethodsOnShape(w.origin, w.method, root, switch (s.store().resolvedContent(root)) {
        .structure => |flat| switch (flat) {
            .tuple => .tuple,
            .unit => .unit,
            .func => .function,
            .record, .empty_record => .record,
            else => .other,
        },
        else => .other,
    });
    return Resolve.reject(s, id, true);
}

// ---------------------------------------------------------------------------
// A nominal receiver: the table, the module rule, derivation
// ---------------------------------------------------------------------------

const WellKnownAnswer = union(enum) { primitive: Dispatch.Primitive, derived };

/// §3.2's table: `eq` and `compare` on `Int`, `Float`, `Bool`, `Char`,
/// `String`, `Order` and `Never`.
fn wellKnownAnswer(s: *Solve, name: Symbol, a: TypeStore.Structure.App) ?WellKnownAnswer {
    if (a.args.len != 0) return null;
    const wk = s.cx.types.well_known;
    const is_eq = name == InternPool.WellKnown.eq.symbol();
    if (!Resolve.isWellKnownName(name)) return null;
    const t = a.type;
    if (t == .none) return null;
    if (t == wk.int or t == wk.float or t == wk.bool) return .{ .primitive = if (is_eq) .strict_eq else .num_compare };
    if (t == wk.char) return .{ .primitive = if (is_eq) .strict_eq else .char_compare };
    if (t == wk.string) return .{ .primitive = if (is_eq) .strict_eq else .string_compare };
    // `Order` is all-nullary, so `eq` is `===`; `compare` is not
    // alphabetic, so it is derived.
    if (t == wk.order) return if (is_eq) .{ .primitive = .strict_eq } else .derived;
    if (t == wk.never) return .derived;
    return null;
}

const Symbol = InternPool.Symbol;

fn onApp(s: *Solve, id: WantedId, root: Var, a: TypeStore.Structure.App) Error!void {
    const cx = s.cx;
    const w = s.evidence.get(id);
    // 1. The table, before the module rule: `Int`, `Float`, `Bool`,
    //    `Order` and `Never` share `core/Basics.beni`, whose `compare` is
    //    `number`'s.
    if (wellKnownAnswer(s, w.method, a)) |wk| {
        if (!try Resolve.unifyWellKnown(s, id, root)) return Resolve.reject(s, id, false);
        switch (wk) {
            .primitive => |p| return Resolve.answer(s, id, .{ .primitive = p }),
            .derived => return derivedNominal(s, id, root, a),
        }
    }
    // 3. The module rule, keyed on `(TypeId, name)`.
    const entry = cx.types.entry(a.type);
    if (entry.module == cx.module) {
        if (s.ownValue(w.method)) |decl| return ownMethod(s, id, root, decl, entry);
    } else if (entry.module.int() >= cx.interfaces.len) {
        try s.report.internal(w.origin, "a method's declaring module has no interface");
        return Resolve.reject(s, id, true);
    } else {
        const iface = cx.iface(entry.module);
        if (iface.findValue(cx.interner, w.method)) |value| return importedMethod(s, id, root, entry, value);
        if (privateIn(s, entry.module, w.method)) {
            try s.report.privateMethod(w.origin, entry.module, w.method);
            return Resolve.reject(s, id, true);
        }
    }
    // 5. Derivation, for a well-known name on a shape that supports it.
    if (Resolve.derives(w)) {
        // A `foreign type` whose own head cannot answer falls through to
        // `unknown_method`, which names the `pub compare` its module is
        // missing (A.50); every other type asks `derivability`.
        if (!(entry.kind == .foreign and !headAnswers(s, a.type, kindOf(w.method)))) {
            if (!try derivable(s, id, root)) return;
            if (!try Resolve.unifyWellKnown(s, id, root)) return Resolve.reject(s, id, false);
            // An all-nullary type is a bare tag string, so `eq` is `===`
            // (A.18); `compare` is not alphabetic.
            if (w.method == InternPool.WellKnown.eq.symbol() and allNullary(s, a.type)) {
                return Resolve.answer(s, id, .{ .primitive = .strict_eq });
            }
            return derivedNominal(s, id, root, a);
        }
    }
    // 6. `unknown_method`.
    try s.report.unknownMethod(w.origin, w.kind == .where_clause, entry.module, entry.name, w.method);
    return Resolve.reject(s, id, true);
}

/// Whether module `module` declares `name` without `pub` (§10.2). An error
/// path only: it reads another module's Bir, as v1's did (`reads.zig`
/// notes it).
fn privateIn(s: *Solve, module: Graph.Index, name: Symbol) bool {
    reads.note(.bir, module);
    const bir = s.cx.artifacts.bir(s.cx.graph.moduleFile(module));
    for (bir.decls) |d| {
        if (d.kind.isValue() and bir.symbol(d.name) == name) return true;
    }
    return false;
}

/// The module rule in THIS module: declaration `decl`, `pub` or not.
fn ownMethod(s: *Solve, id: WantedId, root: Var, decl: u32, entry: Types.Entry) Error!void {
    const w = s.evidence.get(id);
    switch (s.schemeOf(decl)) {
        // Its group has not been checked: R7 checks it at demand (§10.2).
        .unchecked => {
            try s.report.notImplementedR7(w.origin, w.method);
            return Resolve.reject(s, id, true);
        },
        // In flight (§10.3): the member's own variable, no instantiation.
        .in_flight => |v| {
            if (!try s.unifyQuiet(v, w.method_type, w.origin)) {
                try s.report.methodSignatureMismatch(w.origin, entry.module, entry.name, w.method, v, w.method_type);
                return Resolve.reject(s, id, true);
            }
            return Resolve.answer(s, id, .{ .group_call = decl });
        },
        .scheme => |scheme| {
            s.instantiate.made.clearRetainingCapacity();
            s.instantiate.origin = w.origin;
            s.instantiate.parent = id.toOptional();
            defer s.instantiate.parent = .none;
            const copy = try s.instantiate.copy(scheme);
            try s.paired(w.origin);
            // The sub-wanteds are the use's: its declaration owns their failures.
            for (s.instantiate.made.items) |sub| s.evidence.ptr(sub).decl = w.decl;
            const args = try s.evidence.addArgs(s.cx.gpa, s.instantiate.made.items);
            if (!try match(s, id, root, copy, entry)) return;
            return Resolve.answer(s, id, .{ .top = .{ .decl = decl, .args = args } });
        },
    }
}

fn importedMethod(s: *Solve, id: WantedId, root: Var, entry: Types.Entry, value: Interface.ValueIndex) Error!void {
    const w = s.evidence.get(id);
    s.instantiate.made.clearRetainingCapacity();
    s.instantiate.origin = w.origin;
    s.instantiate.parent = id.toOptional();
    defer s.instantiate.parent = .none;
    const copy = (try s.instantiate.importedValue(entry.module, @intFromEnum(value))) orelse
        return Resolve.reject(s, id, true);
    try s.paired(w.origin);
    // The sub-wanteds are the use's: its declaration owns their failures.
    for (s.instantiate.made.items) |sub| s.evidence.ptr(sub).decl = w.decl;
    const args = try s.evidence.addArgs(s.cx.gpa, s.instantiate.made.items);
    if (!try match(s, id, root, copy, entry)) return;
    return Resolve.answer(s, id, .{ .ext = .{ .module = entry.module, .value = value, .args = args } });
}

/// §9.3 step 4: the instantiated method against the wanted's method type.
/// A mismatch is the module-rule clash, v1's `type_mismatch` naming the
/// method's type — at a use, and for a requirement of an instance's
/// context (review F2) — except at a DERIVED shape's position, where it is
/// the shape's refusal, reported at the use for the whole receiver (v1's
/// rule for a method specialised to another application: row 72).
fn match(s: *Solve, id: WantedId, root: Var, copy: Var, entry: Types.Entry) Error!bool {
    const w = s.evidence.get(id);
    if (try s.unifyQuiet(copy, w.method_type, w.origin)) return true;
    if (w.parent.unwrap()) |p| {
        if (s.evidence.answer(p) == .derived) {
            try refuseDerived(s, id, root, .opaque_type);
            return false;
        }
    }
    try s.report.methodSignatureMismatch(w.origin, entry.module, entry.name, w.method, copy, w.method_type);
    try Resolve.reject(s, id, true);
    return false;
}

/// The derived answer for `id` on `root` cannot be given: reported once, at
/// the use, for the lineage root's receiver (v1's rule — the message names
/// the type the author compared), and the lineage root rejected.
fn refuseDerived(s: *Solve, id: WantedId, root: Var, reason: Diagnostics.Reporter.EquatableReason) Error!void {
    const top = Resolve.lineageRoot(s, id);
    // Read BEFORE the rejection, which fails the whole lineage: a root that
    // failed earlier has its message; one this rejection fails does not
    // (CK-102: the check after it returned in silence every time).
    const reported = top != id and s.evidence.get(top).state == .failed;
    try Resolve.reject(s, id, id != top);
    if (reported) return;
    const t = s.evidence.get(top);
    const shown = if (top == id) root else t.receiver;
    if (t.method == InternPool.WellKnown.eq.symbol()) {
        try s.report.notEquatable(t.origin, shown, reason);
    } else {
        try s.report.noMethodsOnShape(t.origin, t.method, shown, .not_orderable);
    }
    try Resolve.reject(s, top, true);
}

/// Every constructor of `id` takes no argument: its values are bare tag
/// strings (`backend.md` §4). A type with none (a `foreign type`) is not one.
fn allNullary(s: *Solve, id: Types.TypeId) bool {
    const cx = s.cx;
    const entry = cx.types.entry(id);
    if (entry.module == cx.module) {
        const bir = cx.bir;
        if (entry.decl.int() >= bir.decls.len) return false;
        const d = bir.decls[entry.decl.int()];
        if (d.ctors_start == d.ctors_end) return false;
        for (bir.ctors[d.ctors_start..d.ctors_end]) |ctor| {
            if (ctor.args_start != ctor.args_end) return false;
        }
        return true;
    }
    if (entry.module.int() >= cx.interfaces.len) return false;
    const iface = cx.iface(entry.module);
    const index = iface.findType(cx.interner, entry.name) orelse return false;
    const t = iface.types[@intFromEnum(index)];
    if (t.ctors_start == t.ctors_end) return false;
    for (iface.ctors[t.ctors_start..t.ctors_end]) |ctor| {
        if (ctor.arity != 0) return false;
    }
    return true;
}

/// A nominal type's derived function: one sub-wanted per type argument, of
/// the same method (v1's one-entry-per-parameter rule; D4's inferred
/// contexts are R8a's). A nullary `foreign type` has no derived function.
fn derivedNominal(s: *Solve, id: WantedId, root: Var, a: TypeStore.Structure.App) Error!void {
    const entry = s.cx.types.entry(a.type);
    if (entry.kind == .foreign and a.args.len == 0) {
        // An `equatable` nullary foreign type: the one structural walk
        // answers (A.53, A.55), the proven-undetermined leaf's function.
        return Resolve.answer(s, id, .undetermined);
    }
    return derivedPositions(s, id, root, a.type, Walk.positions(s.store(), root));
}

/// A derived answer with one sub-wanted per position, each resolved now
/// (a flex position rides on its variable; a rigid one needs a given, and
/// without one is `missing_where_constraint` at the use: CK-20).
fn derivedPositions(s: *Solve, id: WantedId, root: Var, type_id: Types.TypeId, positions: []const Var) Error!void {
    const gpa = s.cx.gpa;
    const owned = try s.cx.scratch.dupe(Var, positions);
    defer s.cx.scratch.free(owned);
    // Answered first, so a position that meets the same receiver again is
    // shared and not walked again (CK-80).
    Resolve.answer(s, id, .{ .derived = .{ .type_id = type_id, .args = .{} } });
    try Resolve.remember(s, id, root);
    const subs = try s.cx.scratch.alloc(WantedId, owned.len);
    defer s.cx.scratch.free(subs);
    for (owned, subs) |p, *sub| sub.* = try Resolve.position(s, id, p);
    const args = try s.evidence.addArgs(gpa, subs);
    if (s.evidence.get(id).state == .answered) {
        s.evidence.setAnswer(id, .{ .derived = .{ .type_id = type_id, .args = args } });
    }
}

// ---------------------------------------------------------------------------
// A record receiver
// ---------------------------------------------------------------------------

/// A record: a well-known name derives over a CLOSED record (A.28); a
/// method known at the call is a FIELD call (§1.2); one met only later is
/// `no_methods_on_shape` (§6.3, A.36).
fn onRecord(s: *Solve, id: WantedId, root: Var, rec: TypeStore.Structure.Record, immediate: bool) Error!void {
    const st = s.store();
    const w = s.evidence.get(id);
    if (Resolve.derives(w)) {
        const row = &s.stacks.fields;
        row.clearRetainingCapacity();
        var concatenated = false;
        const end = try Walk.recordRow(st, rec, row, s.cx.gpa, &concatenated);
        if (end != .closed) return noMethods(s, id, root);
        if (!try derivable(s, id, root)) return;
        if (!try Resolve.unifyWellKnown(s, id, root)) return Resolve.reject(s, id, false);
        // Positions in field-name TEXT order: the shape's key (§9.2).
        row.clearRetainingCapacity();
        concatenated = false;
        _ = try Walk.recordRow(st, rec, row, s.cx.gpa, &concatenated);
        const fields = try s.cx.scratch.dupe(TypeStore.Field, row.items);
        defer s.cx.scratch.free(fields);
        std.mem.sort(TypeStore.Field, fields, s.cx.interner, fieldTextLess);
        const values = try s.cx.scratch.alloc(Var, fields.len);
        defer s.cx.scratch.free(values);
        for (fields, values) |f, *v| v.* = f.value;
        return derivedPositions(s, id, root, .none, values);
    }
    if (!immediate) return noMethods(s, id, root);
    return fieldCall(s, id, root);
}

fn fieldTextLess(interner: *const InternPool.Global, a: TypeStore.Field, b: TypeStore.Field) bool {
    return std.mem.lessThan(u8, interner.slice(a.name), interner.slice(b.name));
}

/// `x.m a` on a record known at the call: `(x.m) a`, the ordinary field and
/// arity diagnostics (v1's `methodOnRecord`, verbatim in its rules).
fn fieldCall(s: *Solve, id: WantedId, root: Var) Error!void {
    const st = s.store();
    const w = s.evidence.get(id);
    const origin = w.origin;
    const f = Walk.function(st, w.method_type) orelse return noMethods(s, id, root);
    const rest = try s.cx.scratch.dupe(Var, f.params[1..]);
    defer s.cx.scratch.free(rest);
    const result = f.result;
    // The FIELD first, against an open record, so a name the record lacks is
    // `unknown_field` and not an arity message about a type nobody wrote.
    const callee = try s.fresh(.{ .flex = .{} });
    var pairs = [_]TypeStore.Field{.{ .name = w.method, .value = callee }};
    const range = try st.addFields(&pairs);
    const ext = try s.fresh(.{ .flex = .{} });
    const required = try s.fresh(.{ .structure = .{ .record = .{ .fields = range, .ext = ext } } });
    _ = try s.unify(required, root, origin, .{ .tag = .field_access, .index = @intFromEnum(w.method) });
    Resolve.answer(s, id, .field);
    const given: u32 = @intCast(rest.len);
    switch (st.resolvedContent(callee)) {
        .err => return,
        .flex => |flags| {
            if (flags.kind == .any) {
                const wanted = try funcOf(s, rest, result);
                _ = try s.unify(callee, wanted, origin, .{ .tag = .general });
                return;
            }
            try s.report.notAFunction(origin, s.report.calleeOf(origin), given, callee);
            return s.poison(result);
        },
        .structure => |flat| switch (flat) {
            .func => |fun| {
                const arity: u32 = fun.params.len;
                if (arity != given) {
                    const declared = try s.cx.scratch.dupe(Var, (Walk.function(st, callee) orelse return).params);
                    defer s.cx.scratch.free(declared);
                    if (arity > given) {
                        try s.report.tooFewArgs(origin, s.report.calleeOf(origin), arity, given, declared[given..]);
                    } else {
                        try s.report.tooManyArgs(origin, s.report.calleeOf(origin), arity, given);
                    }
                    return s.poison(result);
                }
                const wanted = try funcOf(s, rest, result);
                _ = try s.unify(callee, wanted, origin, .{ .tag = .general });
            },
            else => {
                try s.report.notAFunction(origin, s.report.calleeOf(origin), given, callee);
                return s.poison(result);
            },
        },
        else => {
            try s.report.notAFunction(origin, s.report.calleeOf(origin), given, callee);
            return s.poison(result);
        },
    }
}

fn funcOf(s: *Solve, params: []const Var, result: Var) Error!Var {
    const range = try s.store().addVars(params);
    return s.fresh(.{ .structure = .{ .func = .{ .params = range, .result = result } } });
}

// ---------------------------------------------------------------------------
// The derivability verdict (§9.5, as built by R6a's review)
// ---------------------------------------------------------------------------

pub const PairKey = struct { root: Var, kind: Dispatch.Derived.Kind };

/// Why a receiver cannot derive a well-known method, or that it can. v1's
/// verdicts (`walkDerivable`), plus a cycle and R7's pending own method.
pub const Verdict = union(enum) {
    ok,
    function,
    contains_function,
    opaque_type,
    too_wide,
    cycle: Var,
    pending,
};

fn kindOf(name: Symbol) Dispatch.Derived.Kind {
    return if (name == InternPool.WellKnown.eq.symbol()) .eq else .compare;
}

fn methodKind(kind: Dispatch.Derived.Kind) Types.MethodKind {
    return switch (kind) {
        .eq => .eq,
        .compare => .compare,
    };
}

/// Whether nominal type `id`'s own head answers `kind`: the session's
/// capability bit, R8a's to replace.
fn headAnswers(s: *Solve, id: Types.TypeId, kind: Dispatch.Derived.Kind) bool {
    return switch (kind) {
        .eq => s.cx.types.answersEq(id),
        .compare => s.cx.types.answersCompare(id),
    };
}

/// `derivability` for wanted `id` on `root`, reported at the use when it
/// is not `ok` (v1's texts).
fn derivable(s: *Solve, id: WantedId, root: Var) Error!bool {
    const w = s.evidence.get(id);
    const is_eq = w.method == InternPool.WellKnown.eq.symbol();
    switch (try derivability(s, root, kindOf(w.method))) {
        .ok => return true,
        .cycle => |node| {
            try s.reportCycle(w.origin, .none, root, node);
            try Resolve.reject(s, id, false);
            return false;
        },
        // An own type whose method of this name has no scheme yet: its
        // group is later, and R7 checks it at demand (§10.2).
        .pending => try s.report.notImplementedR7(w.origin, w.method),
        .too_wide => if (is_eq) {
            try s.report.notEquatable(w.origin, root, .too_wide);
        } else {
            try s.report.noMethodsOnShape(w.origin, w.method, root, .too_wide);
        },
        .function => if (is_eq) {
            try s.report.notEquatable(w.origin, root, .function);
        } else {
            try s.report.noMethodsOnShape(w.origin, w.method, root, .contains_function);
        },
        .contains_function => if (is_eq) {
            try s.report.notEquatable(w.origin, root, .opaque_type);
        } else {
            try s.report.noMethodsOnShape(w.origin, w.method, root, .contains_function);
        },
        .opaque_type => if (is_eq) {
            try s.report.notEquatable(w.origin, root, .opaque_type);
        } else {
            try s.report.noMethodsOnShape(w.origin, w.method, root, .not_orderable);
        },
    }
    try Resolve.reject(s, id, true);
    return false;
}

const Colour = enum { grey, black, black_open };

const Frame = struct {
    key: PairKey,
    cursor: u32 = 0,
    /// No variable below it, so far: a black ground node's verdict cannot
    /// change, and is kept (`Resolve.State.derivable`).
    ground: bool = true,
    /// Its successors are chosen by a method boundary's requirements.
    boundary: bool,
    /// The verdict a failure below it is reported as: the other method a
    /// boundary asked for maps it (v1's rule: a failed `eq` requirement is
    /// `contains_function`, a failed `compare` one `opaque_type`).
    map: ?Verdict,
};

const Step = struct { v: Var, kind: Dispatch.Derived.Kind, map: ?Verdict };

/// THE answer to "can `start` derive `kind`?" (I10; review B1, B2), which
/// every derivation reads. One iterative walk over `(node, method)` pairs,
/// coloured per pair (a pair met grey again is a cycle, whichever method
/// the boundaries alternate through), over `structural` successors (an
/// alias contributes its expansion), no native recursion (I4), and linear
/// on a DAG: a pair is walked once per walk, and a ground pair once per
/// module. A method boundary's requirements are pushed onto the same stack
/// as pairs of their own method, never walked by a nested walk.
pub fn derivability(s: *Solve, start: Var, kind: Dispatch.Derived.Kind) Error!Verdict {
    const st = s.store();
    const gpa = s.cx.gpa;
    const scratch = s.cx.scratch;
    const first: PairKey = .{ .root = st.find(start), .kind = kind };
    if (s.resolver.derivable.contains(first)) return .ok;
    var colours: std.AutoHashMapUnmanaged(PairKey, Colour) = .empty;
    defer colours.deinit(scratch);
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(scratch);
    if (try gate(s, first)) |refusal| return refusal;
    try colours.put(scratch, first, .grey);
    try frames.append(scratch, .{ .key = first, .boundary = isBoundary(s, first), .map = null });
    while (frames.items.len > 0) {
        const top = &frames.items[frames.items.len - 1];
        const next = nextStep(s, top) orelse {
            const done = frames.pop().?;
            try colours.put(scratch, done.key, if (done.ground) .black else .black_open);
            if (done.ground) try s.resolver.derivable.put(gpa, done.key, {});
            if (frames.items.len > 0 and !done.ground) frames.items[frames.items.len - 1].ground = false;
            continue;
        };
        const key: PairKey = .{ .root = st.find(next.v), .kind = next.kind };
        const map = top.map orelse next.map;
        if (colours.get(key)) |c| switch (c) {
            .grey => return .{ .cycle = key.root },
            .black => continue,
            .black_open => {
                top.ground = false;
                continue;
            },
        };
        if (s.resolver.derivable.contains(key)) continue;
        switch (st.content(key.root)) {
            // A variable holds nothing yet: not a verdict, but not ground.
            .flex, .rigid, .err => {
                top.ground = false;
                continue;
            },
            else => {},
        }
        if (try gate(s, key)) |refusal| return map orelse refusal;
        try colours.put(scratch, key, .grey);
        try frames.append(scratch, .{ .key = key, .boundary = isBoundary(s, key), .map = map });
    }
    return .ok;
}

/// A node's own verdict: a function, a record too wide to derive over, or
/// a nominal type whose head cannot answer the method (or whose method of
/// that name is this module's and has no scheme yet).
fn gate(s: *Solve, key: PairKey) Error!?Verdict {
    const st = s.store();
    const types = s.cx.types;
    switch (st.content(key.root)) {
        .structure => |flat| switch (flat) {
            .func => return .function,
            .record => |r| {
                if (Walk.recordFields(st, r).len > Diagnostics.max_derived_record_fields) return .too_wide;
            },
            .app => |a| {
                if (types.entry(a.type).module == s.cx.module) {
                    const name = if (key.kind == .eq) InternPool.WellKnown.eq.symbol() else InternPool.WellKnown.compare.symbol();
                    if (s.ownValue(name)) |d| if (s.schemeOf(d) == .unchecked) return .pending;
                }
                if (!headAnswers(s, a.type, key.kind)) return if (types.hasFunction(a.type)) .contains_function else .opaque_type;
            },
            else => {},
        },
        else => {},
    }
    return null;
}

/// Whether `key`'s node is a nominal type with a `pub` method of its kind:
/// its arguments are then asked what that method's requirements say.
fn isBoundary(s: *Solve, key: PairKey) bool {
    const a = switch (s.store().content(key.root)) {
        .structure => |flat| switch (flat) {
            .app => |a| a,
            else => return false,
        },
        else => return false,
    };
    return s.cx.types.hasPublicDispatchMethod(a.type, methodKind(key.kind));
}

/// The next pair to visit below `frame`, or null when it has none left: an
/// alias's expansion; a boundary's arguments, each for the method kinds its
/// requirement bits name (1 `eq`, 2 `compare`, 4 its own); every other
/// node's `structural` successors, for the same kind.
fn nextStep(s: *Solve, frame: *Frame) ?Step {
    const st = s.store();
    const root = frame.key.root;
    switch (st.content(root)) {
        .alias => {
            if (frame.cursor != 0) return null;
            frame.cursor = 1;
            return .{ .v = Walk.child(st, root, 0, .payload).?, .kind = frame.key.kind, .map = null };
        },
        else => {},
    }
    if (!frame.boundary) {
        const c = Walk.child(st, root, frame.cursor, .structural) orelse return null;
        frame.cursor += 1;
        return .{ .v = c, .kind = frame.key.kind, .map = null };
    }
    const app = st.content(root).structure.app;
    while (true) {
        const i = frame.cursor / 3;
        const which = frame.cursor % 3;
        const arg = Walk.child(st, root, i, .structural) orelse return null;
        frame.cursor += 1;
        const req = s.cx.types.methodParamRequirement(app.type, i, methodKind(frame.key.kind));
        switch (which) {
            0 => if (req & 4 != 0) return .{ .v = arg, .kind = frame.key.kind, .map = null },
            1 => if (req & 1 != 0) return .{ .v = arg, .kind = .eq, .map = .contains_function },
            else => if (req & 2 != 0) return .{ .v = arg, .kind = .compare, .map = .opaque_type },
        }
    }
}

/// A concrete receiver on a cycle (§9.5's cycle test, which replaced the
/// lineage rule: round-2 review, N1; review F5): one `infinite_type` at the
/// use, the cycle poisoned, and nothing shared or looked up on its head. An
/// occurs walk from the receiver, `structural` successors; `Resolve.step`
/// runs it for every wanted on a structure.
pub fn cyclic(s: *Solve, id: WantedId, root: Var) Error!bool {
    var run: Walk.Occurs = .begin(s.store());
    const node = (try run.check(s.store(), &s.stacks, s.cx.gpa, root)) orelse return false;
    try s.reportCycle(s.evidence.get(id).origin, .none, root, node);
    try Resolve.reject(s, id, false);
    return true;
}
