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
//!      wanted's method type;
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
const TypeStore = @import("../check/TypeStore.zig");
const Types = @import("../check/Types.zig");
const reads = @import("../check/reads.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Diagnostics = @import("../check/Diagnostics.zig");
const Solve = @import("Solve.zig");
const Resolve = @import("Resolve.zig");
const Evidence = @import("Evidence.zig");
const Walk = @import("Walk.zig");
const Messages = @import("Messages.zig");
const Producers = @import("Producers.zig");
const Contexts = @import("Contexts.zig");
const Derivable = @import("Derivable.zig");
const Schemes = @import("../check/Schemes.zig");

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
    const w = s.evidence.get(id);
    // A dot-call joined with a scheme's requirement is refused where the
    // requirement is (the use that needed a method), in every order (X1).
    const at = w.blocked_at.unwrap() orelse w.origin;
    try s.report.noMethodsOnShape(at, w.method, root, switch (s.store().resolvedContent(root)) {
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
            s.contexts.notePrivate(s, entry.module.int(), w.method);
            try s.report.privateMethod(w.origin, entry.module, w.method);
            return Resolve.reject(s, id, true);
        }
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

/// A nominal type's derived function (§11.2, D4): one sub-wanted per entry
/// of its derived CONTEXT — this module's (`Contexts`, read after the
/// verdict walk proved it present) or the one its module published (§14.2)
/// — in the context's `(param, method text)` order. A nullary `foreign
/// type` has no derived function, and a schema endpoint none yet (R8b).
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
    // A schema endpoint is compared structurally until R8b derives it
    // (§11.5): `build` refuses a schema before anything is emitted.
    if (entry.schema_endpoint) return Resolve.answer(s, id, .undetermined);
    const args = try s.cx.scratch.dupe(Var, Walk.positions(s.store(), root));
    defer s.cx.scratch.free(args);
    if (entry.module == cx.module) {
        const answer = try Contexts.query(s, a.type, kind, w.origin);
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
                try Messages.derivedNeedsAnnotation(s.report, w.origin, root, w.method, cx.bir.symbol(cx.bir.decls[answer.culprit].name));
                return Resolve.reject(s, id, true);
            },
            .absent_private => {
                s.contexts.notePrivate(s, answer.culprit, answer.method);
                try s.report.privateMethod(w.origin, @enumFromInt(answer.culprit), answer.method);
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
        // A record the old checker wrote, for a private type: v1's ABI, one
        // entry per parameter naming the derived method (§14.2 *as amended
        // by R8a*). A record v2 wrote has a row for every type it can reach.
        if (cx.oldCheckerWrote(entry.module)) return derivedPositions(s, id, root, a.type, args);
        try s.report.internal(s.evidence.get(id).origin, "another module of this package published no derived row for a type its record reaches (checker-v2.md §14.2)");
        return Resolve.reject(s, id, true);
    };
    const row = facts.derived(if (kind == .eq) .eq else .compare);
    switch (row.status) {
        .present => {},
        // Its module was never checked (a dependency that failed): its
        // failure has a message, so this one fails in silence.
        .unchecked => return Resolve.reject(s, id, false),
        else => return refuseDerived(s, id, root, .opaque_type),
    }
    Resolve.answer(s, id, .{ .derived = .{ .type_id = a.type, .args = .{} } });
    try Resolve.remember(s, id, root);
    const n = iface.contextLen(row.context);
    const subs = try s.cx.scratch.alloc(WantedId, n);
    defer s.cx.scratch.free(subs);
    // The row's method types, instantiated at the arguments once.
    const scheme = iface.contextScheme(row.context);
    const types: []const Var = if (scheme != .none)
        (try publishedMethodTypes(s, iface, entry.module, scheme, args, w)) orelse return Resolve.reject(s, id, true)
    else
        &.{};
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
fn publishedMethodTypes(s: *Solve, iface: *const Interface, module: Graph.Index, scheme: Interface.SchemeIndex, args: []const Var, w: Evidence.Wanted) Error!?[]const Var {
    const cx = s.cx;
    if (@intFromEnum(scheme) >= iface.schemes.len) return null;
    const mark = cx.store.count();
    const v = try Schemes.instantiate(iface, cx.types.refIds(module), cx.store, @intFromEnum(scheme), s.frame().rank, cx.scratch, null);
    try s.instantiate.adoptSince(mark);
    const elements = try cx.scratch.dupe(Var, Walk.positions(s.store(), v));
    defer cx.scratch.free(elements);
    if (elements.len != args.len + 1) return null;
    for (elements[0..args.len], args) |p, arg| {
        if (!try s.unifyQuiet(p, arg, w.origin)) return null;
    }
    return try cx.scratch.dupe(Var, Walk.positions(s.store(), elements[args.len]));
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
        if (end != .closed) return noMethods(s, id, root);
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
    if (!immediate and !w.field_ok) return noMethods(s, id, root);
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
    const node = (try run.check(s.store(), &s.stacks, s.cx.gpa, root)) orelse return false;
    try s.reportCycle(s.evidence.get(id).origin, .none, root, node);
    try Resolve.reject(s, id, false);
    return true;
}
