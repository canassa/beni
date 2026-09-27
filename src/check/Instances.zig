//! Instance lookup (checker-v2.md §9.3) (the derivability verdict is
//! `Derivable.zig`): the answer for a wanted on a structure.
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
//!      wanted's method type — or, for another module's PLAIN method,
//!      the requirements made directly, as that would make them
//!      (`plainImported`, CK-131);
//!   5. derivation, for a well-known name asked by anything but a dot-call:
//!      `Derivable.derivable`, the ONE verdict on "can this receiver derive
//!      the method" (I10; review B1), which reads the derived contexts and
//!      reports why not — then one sub-wanted per context entry of a nominal
//!      type (D4: `Contexts`, or the published row, §14.2), per field of a
//!      closed record, per element of a tuple;
//!   6. `unknown_method`.
//!
//! Inside a derived-context fixpoint (`Contexts`), a method in flight takes
//! §11.2's closed or parametric branch (`ownMethod`), and a function met is
//! noted, so an `absent` entry says why.

const std = @import("std");
const InternPool = @import("../InternPool.zig");
const Interface = @import("../resolve/Interface.zig");
const Graph = @import("../resolve/Graph.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const reads = @import("reads.zig");
const Dispatch = @import("Dispatch.zig");
const Diagnostics = @import("Diagnostics.zig");
const Solve = @import("Solve.zig");
const Resolve = @import("Resolve.zig");
const Evidence = @import("Evidence.zig");
const Walk = @import("Walk.zig");
const Messages = @import("Messages.zig");
const Producers = @import("Producers.zig");
const Contexts = @import("Contexts.zig");
const Derivable = @import("Derivable.zig");
const Schemes = @import("Schemes.zig");

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
            if (!try Derivable.derivable(s, id, root)) return;
            if (!try Resolve.unifyWellKnown(s, id, root)) return Resolve.reject(s, id, false);
            return derivedPositions(s, id, root, .none, childrenOf(s, root));
        },
        .func => {
            const w = s.evidence.get(id);
            s.contexts.noteFunction(s);
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
    return noMethodsWhen(s, id, root, false);
}

/// `late`: a requirement readied after its call met the record, whose text
/// is redrawn once P4 is done (`Report.noMethodsOnShapeLate`).
fn noMethodsWhen(s: *Solve, id: WantedId, root: Var, late: bool) Error!void {
    const w = s.evidence.get(id);
    return noMethodsAs(s, id, root, late, switch (s.store().resolvedContent(root)) {
        .structure => |flat| switch (flat) {
            .tuple => .tuple,
            .unit => .unit,
            .func => .function,
            // The field-call hint is a dot-call's (§10.3 *amended by R13*,
            // CK-54).
            .record, .empty_record => if (w.kind == .dot_call) .record else .record_required,
            else => .other,
        },
        else => .other,
    });
}

fn noMethodsAs(s: *Solve, id: WantedId, root: Var, late: bool, shape: Diagnostics.Reporter.ShapeKind) Error!void {
    const w = s.evidence.get(id);
    // A dot-call joined with a scheme's requirement is refused where the
    // requirement is (the use that needed a method), in every order (X1).
    const at = w.blocked_at.unwrap() orelse w.origin;
    // One failure, one owner: a receiver that already refused another
    // method at this very use (its `==`, as NOT EQUATABLE, when one
    // instantiation of a `let` helper asks both) says nothing more there
    // (R14's review N2).
    if (s.evidence.rejected.contains(s.store().find(root)) and s.report.hasErrorAt(at)) return Resolve.reject(s, id, true);
    if (late) {
        try s.report.noMethodsOnShapeLate(at, w.method, root, shape);
    } else {
        try s.report.noMethodsOnShape(at, w.method, root, shape);
    }
    return Resolve.reject(s, id, true);
}

// ---------------------------------------------------------------------------
// A nominal receiver: the table, the module rule, derivation
// ---------------------------------------------------------------------------

const WellKnownAnswer = union(enum) { primitive: Dispatch.Primitive, derived };

/// §3.2's answer for `name` on `a`: the row `Contexts.tableRow` states,
/// with each primitive's function (`Order`'s `eq` is `===`: all-nullary).
fn wellKnownAnswer(s: *Solve, name: Symbol, a: TypeStore.Structure.App) ?WellKnownAnswer {
    if (a.args.len != 0 or !Resolve.isWellKnownName(name)) return null;
    const kind = Contexts.kindOf(name);
    switch (Contexts.tableRow(s.cx.types, a.type, kind) orelse return null) {
        .derived => return .derived,
        .primitive => {},
    }
    if (kind == .eq) return .{ .primitive = .strict_eq };
    const wk = s.cx.types.well_known;
    if (a.type == wk.char) return .{ .primitive = .char_compare };
    if (a.type == wk.string) return .{ .primitive = .string_compare };
    return .{ .primitive = .num_compare };
}

const Symbol = InternPool.Symbol;

/// §3.2's primitive answer for `name` on `flat`, when the table has one.
pub fn tablePrimitive(s: *Solve, name: Symbol, flat: TypeStore.Structure) ?Dispatch.Primitive {
    const a = switch (flat) {
        .app => |a| a,
        else => return null,
    };
    return switch (wellKnownAnswer(s, name, a) orelse return null) {
        .primitive => |p| p,
        .derived => null,
    };
}

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
        if (iface.findValue(cx.interner, w.method)) |value| return importedMethod(s, id, root, a.type, entry, value);
        if (privateIn(s, entry.module, w.method)) return refusePrivate(s, id, a.type, w.method);
    }
    // 5. Derivation, for a well-known name on a shape that supports it.
    if (Resolve.derives(w)) {
        // A `foreign type` that does not derive (`Derivable.foreignDerives`)
        // falls through to `unknown_method`. Every other type asks
        // `derivability`.
        const foreign_refused = entry.kind == .foreign and !Derivable.foreignDerives(entry, Contexts.kindOf(w.method));
        if (!foreign_refused) {
            if (!try Derivable.derivable(s, id, root)) return;
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

/// The module rule in THIS module: declaration `decl`, `pub` or not. Its
/// group is demanded (§10.2): checked now when it is `unchecked` (the
/// nesting budget may refuse it, at this use), its scheme instantiated when
/// it is `done`; or, in flight — a member of the group being solved, or of
/// one merged with it (§10.3, §10.4) — its own variable, uninstantiated,
/// answered `group_call`.
fn ownMethod(s: *Solve, id: WantedId, root: Var, decl: u32, entry: Types.Entry) Error!void {
    const asked = s.evidence.get(id);
    // A derived-context fixpoint's own resolution meeting a method in flight
    // (§11.2): its closed and parametric branches, and never the link or the
    // merge, which the asker's replayed wanted takes in the asker's frame.
    if (s.contexts.active(s)) |ri| {
        if (s.cx.bir.decls[decl].annotation == .none and s.groups.statusOf(decl) == .checking) {
            return Contexts.inFlight(s, ri, id, decl);
        }
    }
    const demanded = try s.groups.demand(s, decl, asked.origin, asked.method);
    const w = s.evidence.get(id);
    switch (demanded) {
        .refused => return Resolve.reject(s, id, true),
        .missing => return Resolve.reject(s, id, false),
        // In flight (§10.3): the member's own variable, no instantiation.
        .in_flight => |v| {
            // A fixpoint pass that demanded an UNCHECKED group which, checked
            // nested, merged down into an older frame (§10.4) now meets a
            // method in flight: the same closed or parametric branch as one
            // in flight when asked, never the link — unifying this frame's
            // method type with the member's variable would put the pass's
            // variables into a class below its frame (CK-117, §11.2 *as
            // amended by R8b*).
            if (s.contexts.active(s)) |ri| {
                if (s.cx.bir.decls[decl].annotation == .none) return Contexts.inFlight(s, ri, id, decl);
            }
            if (!try s.unifyQuiet(v, w.method_type, w.origin)) {
                if (try Producers.cycle(s.groups, decl)) |cycle| {
                    try Messages.recursiveMethod(s.report, w.origin, w.method, v, w.method_type, cycle);
                } else {
                    try s.report.methodSignatureMismatch(w.origin, entry.module, entry.name, w.method, v, w.method_type);
                }
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

fn importedMethod(s: *Solve, id: WantedId, root: Var, type_id: Types.TypeId, entry: Types.Entry, value: Interface.ValueIndex) Error!void {
    if (try plainImported(s, id, root, type_id, entry, value)) return;
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

/// **The plain-method fast path** (CK-131; v1's `plainMethodMask`, diary
/// 2026-09-24 00:17). An imported method whose scheme is PLAIN —
/// `T q₁ … qₙ, T q₁ … qₙ -> Bool|Order` over distinct quantifiers, each
/// asked for nothing but the method's own name at `qᵢ, qᵢ -> Bool|Order`
/// (`List.compare … where a.compare`) — asked on `T t₁ … tₙ` at a method
/// type that already is `root, root -> Bool|Order`, every `tᵢ` a structure
/// (or an alias of one) no younger than the frame: the instantiation and
/// `match` could only succeed, and all they would leave is one sub-wanted
/// per constrained `qᵢ`, created in the scheme's canonical order (the
/// argument order: the quantifiers are discovered in the receiver) and
/// readied at once by the binding of `qᵢ` to `tᵢ`. Those are made here
/// directly — the same method, receiver, method type, kind, origin,
/// declaration, parent, `seq` and queue — so the resolution order and every
/// diagnostic are the slow path's. Anything else takes the slow path.
fn plainImported(s: *Solve, id: WantedId, root: Var, type_id: Types.TypeId, entry: Types.Entry, value: Interface.ValueIndex) Error!bool {
    const w = s.evidence.get(id);
    if (!Resolve.isWellKnownName(w.method)) return false;
    const plain = (try plainMethod(s, type_id, entry, value, w.method)) orelse return false;
    if (!Resolve.hasWellKnownType(s, w.method, w.method_type, root)) return false;
    const st = s.store();
    const rank = s.frame().rank;
    {
        const args = Walk.positions(st, root);
        if (args.len != plain.arity) return false;
        for (args) |arg| {
            const r = st.find(arg);
            if (st.rank(r) > rank) return false;
            switch (st.content(r)) {
                .structure, .alias => {},
                .flex, .rigid, .err => return false,
            }
        }
    }
    const gpa = s.cx.gpa;
    const args = try s.cx.scratch.dupe(Var, Walk.positions(st, root));
    defer s.cx.scratch.free(args);
    const made = &s.instantiate.made;
    made.clearRetainingCapacity();
    for (args, 0..) |arg, i| {
        if (plain.mask & (@as(u64, 1) << @intCast(i)) == 0) continue;
        const method_type = try Resolve.wellKnownType(s, w.method, arg);
        const sub = try Resolve.create(s, w.method, arg, method_type, w.origin, .where_clause, id.toOptional());
        // The sub-wanteds are the use's: its declaration owns their failures.
        s.evidence.ptr(sub).decl = w.decl;
        try made.append(gpa, sub);
    }
    // Readied as the binding of each quantifier would ready it, in order.
    for (made.items) |sub| {
        const p = s.evidence.ptr(sub);
        p.state = .ready;
        try s.unifier.enqueue(p.frame, sub.int() | Evidence.queued_wanted);
    }
    const sub_args = try s.evidence.addArgs(gpa, made.items);
    Resolve.answer(s, id, .{ .ext = .{ .module = entry.module, .value = value, .args = sub_args } });
    return true;
}

/// A plain method's shape (`plainImported`): its receiver's arity and the
/// arguments its requirements ask the method of.
pub const Plain = struct { arity: u32, mask: u64 };

/// The memo key of `plainMethod`: every input of `readPlain`, the
/// receiver's type among them. The module rule makes one value of a module
/// the method of each of the module's types, and whether it is plain differs
/// per type: a key without the type reused one type's verdict for a sibling
/// type of the same module, and called `A`'s `eq` on a `B` (CK-137).
pub const PlainKey = struct { module: Graph.Index, value: Interface.ValueIndex, type_id: Types.TypeId, method: InternPool.Symbol };

/// Whether `entry`'s module's value `value` is a plain `name` method on
/// `type_id`, read off its interface scheme once per module check.
fn plainMethod(s: *Solve, type_id: Types.TypeId, entry: Types.Entry, value: Interface.ValueIndex, name: Symbol) Error!?Plain {
    const key: PlainKey = .{ .module = entry.module, .value = value, .type_id = type_id, .method = name };
    const got = try s.resolver.plain.getOrPut(s.cx.gpa, key);
    if (!got.found_existing) got.value_ptr.* = readPlain(s, type_id, entry, value, name);
    return got.value_ptr.*;
}

fn readPlain(s: *Solve, type_id: Types.TypeId, entry: Types.Entry, value: Interface.ValueIndex, name: Symbol) ?Plain {
    const cx = s.cx;
    const iface = cx.iface(entry.module);
    const refs = cx.types.refIds(entry.module);
    const result_type = Resolve.wellKnownResult(s, name);
    if (result_type == .none or @intFromEnum(value) >= iface.values.len) return null;
    const index = iface.values[@intFromEnum(value)].scheme;
    if (index == .none or @intFromEnum(index) >= iface.schemes.len) return null;
    const scheme = iface.scheme(index);
    const body = iface.term(scheme.body);
    if (body.tag != .func) return null;
    const params = iface.range(body.lhs);
    if (params.len != 2 or !isNullaryRef(iface, refs, @enumFromInt(body.rhs), result_type)) return null;
    const p0 = iface.term(@enumFromInt(params[0]));
    const p1 = iface.term(@enumFromInt(params[1]));
    if (p0.tag != .app or p1.tag != .app or p0.lhs != p1.lhs) return null;
    if (p0.lhs >= refs.len or refs[p0.lhs] != type_id) return null;
    const a0 = iface.range(p0.rhs);
    const a1 = iface.range(p1.rhs);
    if (a0.len != a1.len or a0.len > 64 or a0.len != scheme.quantified_count) return null;
    var seen: u64 = 0;
    var mask: u64 = 0;
    for (a0, a1, 0..) |t0, t1, i| {
        const v0 = iface.term(@enumFromInt(t0));
        const v1 = iface.term(@enumFromInt(t1));
        if (v0.tag != .@"var" or v1.tag != .@"var" or v0.lhs != v1.lhs or v0.lhs >= scheme.quantified_count) return null;
        const bit = @as(u64, 1) << @intCast(v0.lhs);
        if (seen & bit != 0) return null;
        seen |= bit;
        const q = iface.quantified(scheme, v0.lhs);
        if (q.kind != @intFromEnum(TypeStore.Kind.any) or q.equatable or q.constraints_len > 1) return null;
        if (q.constraints_len == 0) continue;
        const c = iface.quantifiedConstraint(q, 0);
        if (iface.symbol(c.name) != name) return null;
        const ct = iface.term(c.type);
        if (ct.tag != .func) return null;
        const cps = iface.range(ct.lhs);
        if (cps.len != 2) return null;
        for (cps) |cp| {
            const cv = iface.term(@enumFromInt(cp));
            if (cv.tag != .@"var" or cv.lhs != v0.lhs) return null;
        }
        if (!isNullaryRef(iface, refs, @enumFromInt(ct.rhs), result_type)) return null;
        mask |= @as(u64, 1) << @intCast(i);
    }
    return .{ .arity = @intCast(a0.len), .mask = mask };
}

/// Whether interface term `t` is the nullary application of `type_id`.
fn isNullaryRef(iface: *const Interface, refs: []const Types.TypeId, t: Interface.TermIndex, type_id: Types.TypeId) bool {
    const term = iface.term(t);
    return term.tag == .app and term.lhs < refs.len and refs[term.lhs] == type_id and iface.range(term.rhs).len == 0;
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
    const type_id: ?Types.TypeId = switch (s.store().resolvedContent(root)) {
        .structure => |flat| switch (flat) {
            .app => |a| a.type,
            else => null,
        },
        else => null,
    };
    if (w.parent.unwrap()) |p| {
        if (s.evidence.answer(p) == .derived) {
            // The shape's refusal, naming the method and both types
            // (static-dispatch-spike.md §10.13, CK-116).
            if (type_id) |t| {
                try refuseRequirement(s, id, t, w.method, .{ .wanted = w.method_type, .found = copy });
            } else {
                try refuseDerived(s, id, root, .opaque_type);
            }
            return false;
        }
    }
    // Inside a fixpoint pass (a payload's position), its entry says why
    // (`absent_requirement`, CK-116); elsewhere this does nothing.
    if (type_id) |t| s.contexts.noteRequirement(s, t, w.method);
    try s.report.methodSignatureMismatch(w.origin, entry.module, entry.name, w.method, copy, w.method_type);
    try Resolve.reject(s, id, true);
    return false;
}

/// A private method of the module of `culprit` answers `id`, which is
/// asked outside that module (D1, §11.3): `private_method`, reported once
/// at the use for the lineage root's receiver — the value the author
/// compared, which names the wrapper, tuple, record or list the private
/// method is inside (`Messages.privateMethod`) — and the lineage root
/// rejected. Inside a fixpoint pass it is the entry's `absent_private`.
fn refusePrivate(s: *Solve, id: WantedId, culprit: Types.TypeId, method: Symbol) Error!void {
    s.contexts.notePrivate(s, culprit, method);
    const top = Resolve.lineageRoot(s, id);
    // Read BEFORE the rejection, as `refuseDerived` does (CK-102).
    const reported = top != id and s.evidence.get(top).state.rejected();
    try Resolve.reject(s, id, id != top);
    if (reported) return;
    const t = s.evidence.get(top);
    try Messages.privateMethod(s.report, t.origin, t.receiver, culprit, method);
    if (top != id) try Resolve.reject(s, top, true);
}

/// A method a derived answer needs has the wrong type (CK-116): said once,
/// at the use, for the lineage root's receiver, as `refuseDerived` does, and
/// noted on a fixpoint pass's run so its entry says why
/// (`absent_requirement`). The types are rendered before the rejection
/// poisons them.
fn refuseRequirement(s: *Solve, id: WantedId, culprit: Types.TypeId, need: Symbol, types: ?Messages.RequirementTypes) Error!void {
    s.contexts.noteRequirement(s, culprit, need);
    const top = Resolve.lineageRoot(s, id);
    const reported = top != id and s.evidence.get(top).state.rejected();
    if (!reported) {
        const t = s.evidence.get(top);
        try Messages.requirementFailed(s.report, t.origin, t.receiver, t.method, culprit, need, types);
    }
    try Resolve.reject(s, id, id != top);
    if (!reported and top != id) try Resolve.reject(s, top, true);
}

/// The derived answer for `id` on `root` cannot be given: reported once, at
/// the use, for the lineage root's receiver (v1's rule — the message names
/// the type the author compared), and the lineage root rejected.
fn refuseDerived(s: *Solve, id: WantedId, root: Var, reason: Diagnostics.Reporter.EquatableReason) Error!void {
    const top = Resolve.lineageRoot(s, id);
    // Read BEFORE the rejection, which fails the whole lineage: a root that
    // failed earlier has its message; one this rejection fails does not
    // (CK-102: the check after it returned in silence every time).
    const reported = top != id and s.evidence.get(top).state.rejected();
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

/// A nominal type's derived function (§11.2, D4): one sub-wanted per entry
/// of its derived CONTEXT — this module's (`Contexts`, read after the
/// verdict walk proved it present) or the one its module published (§14.2)
/// — in the context's `(param, method text)` order. A nullary `foreign
/// type` has no derived function. A tagged schema endpoint is derived like
/// any `type`, over its schema's payloads (§11.5, R8b).
fn derivedNominal(s: *Solve, id: WantedId, root: Var, a: TypeStore.Structure.App) Error!void {
    const cx = s.cx;
    const entry = cx.types.entry(a.type);
    const w = s.evidence.get(id);
    const kind = Contexts.kindOf(w.method);
    if (entry.kind == .foreign and a.args.len == 0) {
        // An `equatable` nullary foreign type: the one structural walk
        // answers (A.53, A.55), the proven-undetermined leaf's function.
        return Resolve.answer(s, id, .undetermined);
    }
    const args = try s.cx.scratch.dupe(Var, Walk.positions(s.store(), root));
    defer s.cx.scratch.free(args);
    if (entry.module == cx.module) {
        const answer = try Contexts.query(s, a.type, kind, w.origin, id);
        // The verdict walk read the same answer and passed it; one read
        // fresh here (a result no run could memoise, recomputed) is refused
        // for what it says.
        switch (answer.status) {
            .present => {},
            .absent_function => {
                s.contexts.noteFunction(s);
                return refuseDerived(s, id, root, .opaque_type);
            },
            .needs_annotation => {
                s.contexts.noteCulprit(s, answer.culprit);
                try Messages.derivedNeedsAnnotation(s.report, w.origin, root, w.method, cx.bir.decls[answer.culprit].kind == .schema, cx.bir.symbol(cx.bir.decls[answer.culprit].name), Contexts.schemaConversion(cx, answer.culprit));
                return Resolve.reject(s, id, true);
            },
            .absent_private => return refusePrivate(s, id, @enumFromInt(answer.culprit), answer.method),
            .absent_requirement => return refuseRequirement(s, id, @enumFromInt(answer.culprit), answer.method, null),
            .absent_budget => {
                try Messages.resolutionBudget(s.report, w.origin, Resolve.step_budget);
                return Resolve.reject(s, id, true);
            },
            .absent_other, .own_method, .foreign => return refuseDerived(s, id, root, .opaque_type),
        }
        const t = s.contexts.local(a.type).?;
        const entries = try s.cx.scratch.dupe(Contexts.Entry, s.contexts.entriesOf(answer));
        defer s.cx.scratch.free(entries);
        Resolve.answer(s, id, .{ .derived = .{ .type_id = a.type, .args = .{} } });
        try Resolve.remember(s, id, root);
        const subs = try s.cx.scratch.alloc(WantedId, entries.len);
        defer s.cx.scratch.free(subs);
        // The answer's method types, instantiated at the arguments once.
        const types: []const Var = if (answer.template.unwrap()) |template| blk: {
            const tuple = try s.instantiate.substitute(template, try s.contexts.paramsOf(t), args);
            break :blk try s.cx.scratch.dupe(Var, Walk.positions(s.store(), tuple));
        } else &.{};
        for (entries, subs) |e, *sub| {
            const receiver = args[e.param];
            const method_type = if (e.slot != Contexts.none and e.slot < types.len)
                types[e.slot]
            else
                try Resolve.wellKnownType(s, e.method, receiver);
            sub.* = try contextWanted(s, id, e.method, receiver, method_type);
        }
        return finishDerived(s, id, a.type, subs);
    }
    if (entry.module.int() >= cx.interfaces.len) return Resolve.reject(s, id, true);
    const iface = cx.iface(entry.module);
    const facts = iface.typeFacts(cx.interner, entry.name) orelse {
        // A record v2 wrote has a row for every type it can reach, and from
        // R9 every record a v2 build reads is v2's (§22.1): v1's ABI for a
        // row-less private type is gone from this checker.
        try s.report.internal(s.evidence.get(id).origin, "another module of this package published no derived row for a type its record reaches (checker-v2.md §14.2)");
        return Resolve.reject(s, id, true);
    };
    const row = facts.derived(if (kind == .eq) .eq else .compare);
    switch (row.status) {
        .present => {},
        // Its module was never checked (a dependency that failed): its
        // failure has a message, so this one is `poisoned`, in silence.
        .unchecked => return Resolve.poisoned(s, id),
        // D1 (§11.3): the row's context reaches a private method.
        .private_method => {
            const p = iface.privateCulprit(row.context) orelse return refuseDerived(s, id, root, .opaque_type);
            const refs = cx.types.refIds(entry.module);
            if (@intFromEnum(p.type_ref) >= refs.len) return refuseDerived(s, id, root, .opaque_type);
            return refusePrivate(s, id, refs[@intFromEnum(p.type_ref)], iface.symbol(p.method));
        },
        // CK-116: the row says which method failed (§14.2 *as amended by R13*).
        .requirement => {
            const p = iface.privateCulprit(row.context) orelse return refuseDerived(s, id, root, .opaque_type);
            const refs = cx.types.refIds(entry.module);
            if (@intFromEnum(p.type_ref) >= refs.len) return refuseDerived(s, id, root, .opaque_type);
            return refuseRequirement(s, id, refs[@intFromEnum(p.type_ref)], iface.symbol(p.method), null);
        },
        else => return refuseDerived(s, id, root, .opaque_type),
    }
    Resolve.answer(s, id, .{ .derived = .{ .type_id = a.type, .args = .{} } });
    try Resolve.remember(s, id, root);
    const n = iface.contextLen(row.context);
    const subs = try s.cx.scratch.alloc(WantedId, n);
    defer s.cx.scratch.free(subs);
    // The row's method types, instantiated at the arguments once.
    const scheme = iface.contextScheme(row.context);
    const types: []const Var = if (scheme != .none) switch (try publishedMethodTypes(s, iface, entry.module, scheme, args, w)) {
        .types => |t| t,
        // The row's module could not write its template, and said so
        // (`Publish.Facts.templateScheme`, CK-142): the answer is poisoned,
        // with no message here.
        .poisoned => return Resolve.poisoned(s, id),
        .malformed => return Resolve.reject(s, id, true),
    } else &.{};
    for (subs, 0..) |*sub, k| {
        const e = iface.contextEntry(row.context, k).?;
        const method = iface.symbol(e.method);
        if (e.param >= args.len) return Resolve.reject(s, id, false);
        const receiver = args[e.param];
        const method_type = if (e.slot != Contexts.none) blk: {
            if (e.slot >= types.len) return Resolve.reject(s, id, true);
            break :blk types[e.slot];
        } else try Resolve.wellKnownType(s, method, receiver);
        sub.* = try contextWanted(s, id, method, receiver, method_type);
    }
    return finishDerived(s, id, a.type, subs);
}

/// One context entry's sub-wanted of derived answer `parent`: `method` on
/// `receiver` at `method_type`, resolved now. A well-known entry is a
/// position of the derived shape (its parent's surface); any other is the
/// requirement a payload's method made (`where_clause`).
fn contextWanted(s: *Solve, parent: WantedId, method: Symbol, receiver: Var, method_type: Var) Error!WantedId {
    const p = s.evidence.get(parent);
    const kind: Evidence.Kind = if (Resolve.isWellKnownName(method)) p.kind else .where_clause;
    const sub = try Resolve.create(s, method, receiver, method_type, p.origin, kind, parent.toOptional());
    s.evidence.ptr(sub).decl = p.decl;
    // Resolution recursing into a derived answer's context spends native
    // stack the nesting budget counts (§10.2; R7's review, S7).
    s.resolve_depth += 1;
    defer s.resolve_depth -= 1;
    try Resolve.step(s, sub, false);
    return sub;
}

fn finishDerived(s: *Solve, id: WantedId, type_id: Types.TypeId, subs: []const WantedId) Error!void {
    const args = try s.evidence.addArgs(s.cx.gpa, subs);
    if (s.evidence.get(id).state == .answered) {
        s.evidence.setAnswer(id, .{ .derived = .{ .type_id = type_id, .args = args } });
    }
}

/// A published row's method types (§14.2 *as amended by R8a*): its
/// scheme's body is `( p₀, …, pₙ₋₁, ( τ₀, …, τₖ ) )`; the parameters are
/// unified with the use's arguments and each `τ` is the method type of the
/// entries whose `slot` it is.
fn publishedMethodTypes(s: *Solve, iface: *const Interface, module: Graph.Index, scheme: Interface.SchemeIndex, args: []const Var, w: Evidence.Wanted) Error!PublishedTypes {
    const cx = s.cx;
    if (@intFromEnum(scheme) >= iface.schemes.len) return .malformed;
    const mark = cx.store.count();
    const v = try Schemes.instantiateWith(iface, cx.types.refIds(module), cx.store, @intFromEnum(scheme), s.frame().rank, cx.scratch, &s.instantiate.term_memo, cx.gpa);
    try s.instantiate.adoptSince(mark);
    if (s.store().resolvedContent(v) == .err) return .poisoned;
    const elements = try cx.scratch.dupe(Var, Walk.positions(s.store(), v));
    defer cx.scratch.free(elements);
    if (elements.len != args.len + 1) return .malformed;
    for (elements[0..args.len], args) |p, arg| {
        if (!try s.unifyQuiet(p, arg, w.origin)) return .malformed;
    }
    return .{ .types = try cx.scratch.dupe(Var, Walk.positions(s.store(), elements[args.len])) };
}

/// A published row's method types, or why there are none: its scheme is
/// `<error>` (the publisher reported why), or it does not have the row's
/// shape (the compiler's).
const PublishedTypes = union(enum) { types: []const Var, poisoned, malformed };

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
/// dot-call's own wanted is a FIELD call (§1.2), whether the record was known
/// at the call or met later (§11 *Deferred receiver*, amended 2026-09-26);
/// any other wanted is `no_methods_on_shape` (§6.3, A.36).
fn onRecord(s: *Solve, id: WantedId, root: Var, rec: TypeStore.Structure.Record, immediate: bool) Error!void {
    const st = s.store();
    const w = s.evidence.get(id);
    if (Resolve.derives(w)) {
        const row = &s.stacks.fields;
        row.clearRetainingCapacity();
        var concatenated = false;
        const end = try Walk.recordRow(st, rec, row, s.cx.gpa, &concatenated);
        if (end != .closed) return noMethodsAs(s, id, root, false, .open_record);
        if (!try Derivable.derivable(s, id, root)) return;
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
    // A dot-call's own wanted is the field call whenever its receiver turns
    // out a record before it is generalised (static-dispatch-spike.md §11
    // *Deferred receiver*, amended 2026-09-26): "known at the call" would
    // read the solving order, which in a recursive group is the declaration
    // order (checker-v2.md I9). A requirement an instantiation made has no
    // field accessor to be, and neither has a dot-call joined with one
    // (`Wanted.field_ok`, R7's round-2 review, X1).
    if (!immediate and !w.field_ok) return noMethodsWhen(s, id, root, true);
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

/// A concrete receiver on a cycle (§9.5's cycle test, which replaced the
/// lineage rule: round-2 review, N1; review F5): one `infinite_type` at the
/// use, the cycle poisoned, and nothing shared or looked up on its head. An
/// occurs walk from the receiver, `structural` successors; `Resolve.step`
/// runs it for every wanted on a structure.
pub fn cyclic(s: *Solve, id: WantedId, root: Var) Error!bool {
    var run: Walk.Occurs = .begin(s.store());
    // It proves: a position met later in the same resolution stops here
    // (`TypeStore.acyclic`, CK-111).
    run.proves = true;
    run.interior = true;
    const node = (try run.check(s.store(), &s.stacks, s.cx.gpa, root)) orelse return false;
    try s.reportCycle(s.evidence.get(id).origin, .none, root, node);
    try Resolve.reject(s, id, false);
    return true;
}
