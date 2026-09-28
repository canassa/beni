//! The resolver (checker-v2.md §9): every wanted from the moment it is
//! created or readied until it is answered.
//!
//! **One step, by the receiver's root** (§9.2). `step` looks at
//! `find(w.receiver)`:
//!
//! | Root | Action |
//! |------|--------|
//! | `flex` of kind `number`, `eq`/`compare` | the `number` bridge (checker-v2.md §9.2): unify the method type with `t, t -> Bool\|Order`, answer `primitive` |
//! | any other `flex` | ride on it (Rule U1's join with a wanted of the same name), open |
//! | `rigid` | a given: unify the method types, answer `param`; else the bridge on a `number` rigid; else `missing_where_constraint` (or `type_dispatch_needs_annotation`) at `w.origin`, once per rigid, method and use |
//! | `err` | `poisoned`, silently (its message is where the `err` was made) |
//! | a structure | `Instances.lookup` (§9.3): the well-known table, the module rule, matching, derivation |
//!
//! **When** (§9.1): inline at the `method` node when the receiver is
//! already known (Rule U0, `immediate`); otherwise when `unify` readies it,
//! in the drain that runs after every constraint node (eager draining)
//! and at every boundary's step 1 — in `seq` order, shared with
//! the obligations.
//!
//! **Promotion and the proven-undetermined default** (§9.4) are step 7 of
//! the top-level boundary: `close`; at a `let` boundary they are `holdLet`
//! (step 5: what a `let` does not generalise drops to the enclosing rank)
//! and `closeLet` (step 7: a function binding's own requirements promoted to
//! it, §8.4). A promoted wanted
//! records its requirement `(root, method)`, never an index: the index is the
//! site's member's, which P6 computes by §12.3.
//!
//! **One failure, one owner.** A rejected wanted fails its whole lineage in
//! silence (a parent is never `answered` over a failed argument, and no
//! failure to decide is read as success), and
//! a concrete receiver that rejected a method rejects it again in silence —
//! §9.5's class flag, which `Unify` carries to the survivor of every merge.
//!
//! **Termination** (§9.5): a wanted on a receiver that lies on a cycle is
//! `infinite_type` (`Instances.cyclic`), the derivability walk is iterative and
//! coloured per `(node, method)`, and every top-level group has a step budget,
//! reported when spent — which is what stops a non-cyclic chain that grows
//! (a `where` clause may constrain another parameter, so a repeated receiver
//! is no cycle).
//!
//! **No speculation** (§7.5): nothing here may run while a
//! snapshot is open — checked, and `internal` if it ever is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Dispatch = @import("Dispatch.zig");
const TypeStore = @import("TypeStore.zig");
const Evidence = @import("Evidence.zig");
const Instances = @import("Instances.zig");
const Derivable = @import("Derivable.zig");
const Messages = @import("Messages.zig");
const Recursion = @import("Recursion.zig");
const Solve = @import("Solve.zig");
const Walk = @import("Walk.zig");
const Tree = @import("constrain/Tree.zig");
const Schemes = @import("Schemes.zig");
const EnvFile = @import("Env.zig");

const Var = TypeStore.Var;
const Symbol = InternPool.Symbol;
const Error = Solve.Error;
const WantedId = Evidence.WantedId;

/// The cap on an unannotated declaration's inferred requirements
/// (static-dispatch-spike.md §6.4, §10.11).
pub const max_inferred_constraints = 64;
/// How many names `too_many_inferred_constraints` lists.
const named_in_cap_message = 5;
/// The backstop on resolution steps (§9.5), per top-level
/// group: a runaway resolution is one group's, and a module of many ordinary
/// groups never reaches it.
pub const step_budget: u32 = 1 << 20;

/// The resolver's own tables: one owner.
pub const State = struct {
    /// Step 5's quantified variables that still carry wanteds (step 7).
    wanters: std.ArrayList(Var) = .empty,
    /// Per concrete receiver root and well-known method, the wanted that
    /// answered it with a DERIVED shape — the one answer that depends on the
    /// receiver alone: a DAG-shaped type is resolved once per
    /// node. A method found by the module rule is instantiated per
    /// use and never shared.
    derived: std.AutoHashMapUnmanaged(MemoKey, WantedId) = .empty,
    /// The `(root, method kind)` pairs the derivability walk proved
    /// derivable over a GROUND subgraph — no variable below, so the verdict
    /// cannot change (`Derivable.derivability`). A dense column indexed by
    /// the root, one bit per kind (a hash map's hashing would be half of the
    /// walk's cost).
    derivable: Derivable.GroundMemo = .{},
    /// The ground shapes proved derivable, by structure (`Derivable.Shapes`).
    shapes: Derivable.Shapes = .{},
    /// The pairs the walk proved derivable over a subgraph with variables
    /// below: true until a leaf below is given successors. The walk
    /// records each leaf it meets as proved (`TypeStore.prove`: a leaf is
    /// trivially acyclic), so such a write voids the proofs, and the memo is
    /// kept only while `TypeStore.proof_voids` is `derivable_open_voids`. A
    /// record nested d deep compared once resolves d positions, each over
    /// its subtree, and walked each one again: O(d²).
    derivable_open: std.AutoHashMapUnmanaged(Derivable.PairKey, void) = .empty,
    derivable_open_voids: u64 = std.math.maxInt(u64),
    /// `missing_where_constraint`s said, per use, rigid and method.
    missing: std.AutoHashMapUnmanaged(MissingKey, void) = .empty,
    /// Per imported method, receiver type and well-known name, its plain
    /// shape or null (`Instances.plainImported`): read off the
    /// interface once, keyed by every input of the verdict.
    plain: std.AutoHashMapUnmanaged(Instances.PlainKey, ?Instances.Plain) = .empty,
    /// The own well-known methods said once at their declaration, per type
    /// (`Instances.signatureOnce`).
    signatures: std.AutoHashMapUnmanaged(Instances.SignatureKey, TypeStore.Var) = .empty,
    /// Steps in the current top-level group.
    steps: u32 = 0,
    /// What promotion kept, per unannotated declaration: a range of
    /// `requirement_rows`, in canonical order (§12.1), for P9's table.
    decl_requirements: []Dispatch.Range = &.{},
    requirement_rows: std.ArrayList(Dispatch.Requirement) = .empty,
    /// Each row's quantifier, as a root: what P6 matches a `promoted`
    /// answer and a group call against (§12.3), never recomputed.
    requirement_roots: std.ArrayList(Var) = .empty,
    /// What each promoting `let` function binding kept (§8.4): its `let_def`, a range of `requirement_rows`, and its header.
    let_rows: std.ArrayList(LetRow) = .empty,

    pub fn deinit(r: *State, gpa: Allocator) void {
        r.let_rows.deinit(gpa);
        r.wanters.deinit(gpa);
        r.derived.deinit(gpa);
        r.derivable.bits.deinit(gpa);
        r.shapes.deinit(gpa);
        r.derivable_open.deinit(gpa);
        r.missing.deinit(gpa);
        r.plain.deinit(gpa);
        r.signatures.deinit(gpa);
        r.requirement_rows.deinit(gpa);
        r.requirement_roots.deinit(gpa);
    }
};

pub const LetRow = struct { inst: Bir.Inst.Index, requirements: Dispatch.Range, scheme: Var };

pub const MemoKey = struct { root: Var, method: Symbol };
const MissingKey = struct { origin: Bir.Inst.Index, rigid: Var, method: Symbol };

// ---------------------------------------------------------------------------
// Creation
// ---------------------------------------------------------------------------

/// A new wanted at the solver's current declaration.
pub fn create(s: *Solve, name: Symbol, receiver: Var, method_type: Var, origin: Bir.Inst.Index, kind: Evidence.Kind, parent: WantedId.Optional) Error!WantedId {
    const id = try s.evidence.add(s.cx.gpa, .{
        .method = name,
        .receiver = receiver,
        .method_type = method_type,
        .origin = origin,
        .kind = kind,
        .decl = s.report.current orelse Evidence.Wanted.no_decl,
        .parent = parent,
        .seq = s.obligations.seq,
        .frame = s.obligations.current_queue,
    });
    s.obligations.seq += 1;
    return id;
}

/// The `method` node (Rule U0): the callee's wanted, resolved now when its
/// receiver is known, else riding on it.
pub fn method(s: *Solve, node: Tree.Node) Error!void {
    const info = s.tree.extraData(node.a, Tree.Method);
    const id = try create(s, info.name, info.receiver, info.method_type, node.region, @enumFromInt(info.kind), .none);
    // A hand-written dot-call's own wanted may become a field call (§11).
    if (s.evidence.get(id).kind == .dot_call) s.evidence.ptr(id).field_ok = true;
    try s.evidence.callees.append(s.cx.gpa, .{ .inst = node.region, .wanted = id });
    try step(s, id, true);
}

/// A readied wanted, drained (§9.1).
pub fn drained(s: *Solve, id: WantedId) Error!void {
    if (s.evidence.get(id).state != .ready) return;
    try step(s, id, false);
}

// ---------------------------------------------------------------------------
// One step (§9.2)
// ---------------------------------------------------------------------------

/// Resolve `id` against its receiver's root. `immediate` is Rule U0's inline
/// resolution. A dot-call on a record is a FIELD call, known at the call or
/// met later, unless it was joined with a scheme's requirement
/// (static-dispatch-spike.md §11 *Deferred receiver*, amended 2026-09-26).
pub fn step(s: *Solve, id: WantedId, immediate: bool) Error!void {
    const st = s.store();
    const saved = s.report.current;
    defer s.report.at(saved);
    const w = s.evidence.get(id);
    s.report.at(if (w.decl == Evidence.Wanted.no_decl) saved else w.decl);
    // A probe never resolves (§7.5).
    if (!try s.expect(st.depth == 0, w.origin, "the resolver ran inside a speculation (checker-v2.md §7.5)")) return reject(s, id, false);

    s.resolver.steps += 1;
    if (s.resolver.steps == step_budget) try Messages.resolutionBudget(s.report, w.origin, step_budget);
    if (s.resolver.steps >= step_budget) return reject(s, id, true);
    // Canonical pessimism (§10.7): in a recursive group, a wanted on a group-level
    // receiver is pessimistic whether it resolves now or rides on a flex.
    if (s.recursive_frames != 0) try Recursion.wanted(s, id);

    const root, const content = st.resolved(w.receiver);
    switch (content) {
        // A poisoned receiver has its message, said where the `err` was
        // made — maybe in a dependency: `poisoned`, in silence
        // (§7.1, §12.2). An over-long alias chain `resolved` answers as
        // `err` too.
        .err => return poisoned(s, id),
        // `resolved` never stops at an alias.
        .alias => {
            _ = try s.expect(false, w.origin, "`TypeStore.resolved` returned an alias (checker-v2.md §9.2)");
            return reject(s, id, false);
        },
        .flex => |flags| {
            // A receiver whose class is an alias of this flex (a flex that
            // absorbed `Id a` by name) now carries something, as a flex that
            // met the alias carrying it would have: it shows the expansion
            // (checker-v2.md §7.1), so the name it
            // prints does not depend on which came first.
            if (st.find(w.receiver) != root) try s.unifier.expand(w.receiver);
            if (flags.kind == .number and isWellKnownName(w.method)) return bridge(s, id, root);
            return attach(s, id, root, flags);
        },
        .rigid => |flags| return rigid(s, id, root, flags),
        .structure => |flat| {
            // §3.2's table on a primitive whose method type already IS
            // `root, root -> Bool|Order` (a derived shape's position, a
            // plain method's requirement readied at the element): the
            // answer `Instances.lookup` would give, without its
            // unification, which could only succeed. A nullary
            // application is on no cycle, and no derived answer is ever
            // remembered for a table primitive (`memoised`).
            if (Instances.tablePrimitive(s, w.method, flat)) |p| {
                if (s.evidence.isRejected(root, flagOf(w))) return reject(s, id, true);
                if (hasWellKnownType(s, w.method, w.method_type, root)) return answer(s, id, .{ .primitive = p });
            }
            // A receiver on a cycle is one `infinite_type`, before anything
            // is shared or looked up (§9.5, the cycle test that replaced the
            // lineage rule).
            //
            // A receiver an earlier cycle test proved acyclic, whose proof
            // nothing has voided since (`TypeStore.acyclic`), is not walked
            // again: a position of a receiver just resolved is in the graph
            // its parent's test proved. Debug checks the proof on
            // shallow positions (a check at every depth would make a Debug
            // build quadratic again).
            if (std.debug.runtime_safety and s.resolve_depth < 64 and st.proved(root)) {
                var run: Walk.Occurs = .begin(st);
                run.trusts = false;
                if (try run.check(st, &s.stacks, s.cx.gpa, root) != null) std.debug.panic("a receiver proved acyclic is on a cycle (checker-v2.md §8.2)", .{});
            }
            if (try Instances.cyclic(s, id, root)) return;
            if (s.evidence.isRejected(root, flagOf(w))) return reject(s, id, true);
            if (derives(w) and try memoised(s, id, root)) return;
            return Instances.lookup(s, id, root, flat, immediate);
        },
    }
}

/// Answer `id` with `a`.
pub fn answer(s: *Solve, id: WantedId, a: Evidence.Answer) void {
    s.evidence.ptr(id).state = .answered;
    s.evidence.setAnswer(id, a);
}

fn flagOf(w: Evidence.Wanted) Evidence.Flag {
    return .{ .method = w.method, .derives = derives(w) };
}

/// `id` is rejected; its message, if any, is the caller's. Its lineage
/// fails with it, in silence: a derived or instance answer whose argument
/// failed is no answer. The method type is poisoned when
/// `poison` (what the call returns is then silent), never the
/// receiver (§9.5: a rejection does not silence the receiver's other
/// uses); a concrete receiver is flagged for this method, so a later
/// wanted of the same method there fails in silence.
pub fn reject(s: *Solve, id: WantedId, poison: bool) Error!void {
    rejectLineage(s, id, .failed);
    if (!poison) return;
    const w = s.evidence.get(id);
    const root = s.store().find(w.receiver);
    if (s.store().content(root) == .structure) try s.evidence.setRejected(s.cx.gpa, root, flagOf(w));
    try s.poison(w.method_type);
}

/// `id` met `err` (its receiver, or a variable of it, was poisoned): it is
/// `poisoned`, and so is every ancestor not already rejected, in silence
/// (§12.2). The poison's message was said
/// where the `err` was made — this module, or a dependency whose `<error>`
/// value this module reads — so nothing here may assume THIS module
/// reported: P6 writes no site for a poisoned wanted, and the evidence
/// count check skips it.
pub fn poisoned(s: *Solve, id: WantedId) Error!void {
    rejectLineage(s, id, .poisoned);
}

/// `id` and its lineage rejected as `state` (a `failed` or `poisoned`
/// wanted's parent is no answer); an ancestor already rejected
/// keeps its own reason, and ends the walk.
fn rejectLineage(s: *Solve, id: WantedId, state: Evidence.State) void {
    s.evidence.ptr(id).state = state;
    var at = s.evidence.get(id).parent;
    while (at.unwrap()) |p| {
        const pp = s.evidence.ptr(p);
        if (pp.state.rejected()) break;
        pp.state = state;
        at = pp.parent;
    }
}

pub fn isWellKnownName(name: Symbol) bool {
    return name == InternPool.WellKnown.eq.symbol() or name == InternPool.WellKnown.compare.symbol();
}

/// Whether `w` may DERIVE (static-dispatch-spike.md §3.3 step 2): a
/// well-known name, whatever surface asked for it. A hand-written dot-call
/// derives too when the receiver's type declares no method of the name
/// (static-dispatch-spike.md §1.3 rule 2, reversed by checker-v2.md
/// §21.1); on a record it is still the field call (`Instances.onRecord`).
pub fn derives(w: Evidence.Wanted) bool {
    return isWellKnownName(w.method);
}

/// The result type of a well-known method: `Bool` for `eq`, `Order` for
/// `compare`.
pub fn wellKnownResult(s: *Solve, name: Symbol) TypeStore.TypeId {
    const wk = s.cx.types.well_known;
    return if (name == InternPool.WellKnown.eq.symbol()) wk.bool else wk.order;
}

/// `root, root -> Bool|Order` for method `name`, at the current frame.
pub fn wellKnownType(s: *Solve, name: Symbol, root: Var) Error!Var {
    const result_type = wellKnownResult(s, name);
    const result = if (result_type == .none)
        try s.fresh(.err)
    else
        try s.fresh(.{ .structure = .{ .app = .{ .type = result_type, .args = .empty } } });
    const params = try s.store().addVars(&.{ root, root });
    return s.fresh(.{ .structure = .{ .func = .{ .params = params, .result = result } } });
}

/// Whether `method_type` already is `root, root -> Bool|Order` for method
/// `name`: both parameters `root` itself, the result the well-known type. A
/// unification with `wellKnownType` could then only succeed.
pub fn hasWellKnownType(s: *Solve, name: Symbol, method_type: Var, root: Var) bool {
    const st = s.store();
    const f = Walk.function(st, method_type) orelse return false;
    if (f.params.len != 2 or st.find(f.params[0]) != root or st.find(f.params[1]) != root) return false;
    const result = wellKnownResult(s, name);
    if (result == .none) return false;
    return switch (st.resolvedContent(f.result)) {
        .structure => |flat| switch (flat) {
            .app => |a| a.type == result and a.args.len == 0,
            else => false,
        },
        else => false,
    };
}

/// Unify `w.method_type` with `root, root -> Bool|Order`, reported at the
/// wanted's origin. False when it failed (and was reported).
pub fn unifyWellKnown(s: *Solve, id: WantedId, root: Var) Error!bool {
    const w = s.evidence.get(id);
    // Already that type (a comparison's operands, a position): the
    // unification could only succeed, silently.
    if (hasWellKnownType(s, w.method, w.method_type, root)) return true;
    const wanted = try wellKnownType(s, w.method, root);
    // A clause's declared type against the method's: `.where_clause`,
    // with the clause its message names (static-dispatch-spike.md §10.13).
    const category: Tree.Category = .{ .tag = if (w.kind == .where_clause) .where_clause else .general };
    if (w.kind == .where_clause) s.report.texts.clause = .{ .variable = w.receiver_name, .method = w.method };
    defer s.report.texts.clause = null;
    return try s.unify(wanted, w.method_type, w.origin, category) == .ok;
}

/// **The `number` bridge** (§9.2): a `number` is `Int` or
/// `Float`, and §3.2's table answers both alike, so `eq`/`compare` on one
/// needs no evidence — once the declared method type is checked against the
/// well-known one.
fn bridge(s: *Solve, id: WantedId, root: Var) Error!void {
    const w = s.evidence.get(id);
    if (!try unifyWellKnown(s, id, root)) return reject(s, id, false);
    answer(s, id, .{ .primitive = if (w.method == InternPool.WellKnown.eq.symbol()) .strict_eq else .num_compare });
}

/// A wanted on a flex rides on it: one entry of its constraint set (§4.1,
/// as decided). A wanted of the same name already there is Rule U1's
/// join: the older answers both, the younger is `alias(older)` and the two
/// method types must agree (`method_constraint_mismatch` at the younger's
/// origin otherwise). The method type is lowered to the receiver's rank
/// (so no variable reachable from it outranks the receiver). An entry that
/// is not paired with a wanted is `internal`.
fn attach(s: *Solve, id: WantedId, root: Var, flags: TypeStore.Flags) Error!void {
    const st = s.store();
    const gpa = s.cx.gpa;
    const w = s.evidence.get(id);
    // §11.2's frame assert (`Unify.assertContained`): a wanted made
    // while a fixpoint frame is current rides on that frame's variables,
    // never on an older frame's, whose wanteds would then carry the pass.
    if (std.debug.runtime_safety) {
        const f = s.frame();
        const rank = st.rank(root);
        if (f.kind == .fixpoint and rank != TypeStore.generalized and rank < f.rank)
            std.debug.panic("a fixpoint frame's wanted rides on a variable of an older frame (checker-v2.md §11.2)", .{});
    }
    s.evidence.ptr(id).state = .open;
    const set = Walk.constraints(flags);
    switch (s.evidence.named(st, set, w.method)) {
        .absent => {},
        .unpaired => {
            _ = try s.expect(false, w.origin, "a method requirement on a variable is paired with no wanted (checker-v2.md §4.2)");
            return reject(s, id, false);
        },
        .wanted => |other| {
            if (other == id) return;
            // A failed wanted left on a live flex (a call's requirement
            // failed in silence, `Solve.failInstantiation`) is no answer: the
            // new wanted takes its place in the set, open, and is never
            // aliased to it (§4.2: a flex's set is its open wanteds).
            if (s.evidence.get(other).state.rejected()) {
                try replaceEntry(s, root, flags, other, id);
                try Walk.lowerTo(st, &s.stacks, gpa, w.method_type, st.rank(root));
                return;
            }
            const older, const younger = if (s.evidence.get(other).seq < w.seq) .{ other, id } else .{ id, other };
            if (older == id) {
                // A readied wanted re-attached beside a younger one: it takes
                // the younger's place in the set.
                try replaceEntry(s, root, flags, other, id);
            }
            try Walk.lowerTo(st, &s.stacks, gpa, w.method_type, st.rank(root));
            answer(s, younger, .{ .alias = older });
            s.evidence.joinField(older, younger);
            try joinTypes(s, younger, older);
            return;
        },
    }
    const entry: TypeStore.MethodConstraint = .{ .name = w.method, .fn_var = w.method_type, .region = w.origin, .origin = w.kind };
    const old_start: ?u32 = if (set.set.unwrap()) |existing| st.constraint_sets.items[existing.int()].start else null;
    const n = set.count(st);
    const extended = try st.extendConstraints(set.set, entry);
    const new_start = st.constraint_sets.items[extended.unwrap().?.int()].start;
    // `extendConstraints` appends in place when the old range ends at the
    // tail and COPIES it otherwise: the copies' positions are paired again.
    if (old_start) |start| if (start != new_start) {
        var i: u32 = 0;
        while (i < n) : (i += 1) try s.evidence.setSlot(gpa, new_start + i, s.evidence.slotAt(start + i));
    };
    try s.evidence.setSlot(gpa, new_start + n, .wanted(id));
    var with = flags;
    with.constraints = extended;
    st.setContent(root, .{ .flex = with });
    try Walk.lowerTo(st, &s.stacks, gpa, w.method_type, st.rank(root));
}

/// `root`'s set with `was`'s entry replaced by `now`'s.
fn replaceEntry(s: *Solve, root: Var, flags: TypeStore.Flags, was: WantedId, now: WantedId) Error!void {
    const st = s.store();
    const gpa = s.cx.gpa;
    const set = Walk.constraints(flags);
    const n = set.count(st);
    const entries = try s.cx.scratch.alloc(TypeStore.MethodConstraint, n);
    defer s.cx.scratch.free(entries);
    const slots = try s.cx.scratch.alloc(Evidence.Slot, n);
    defer s.cx.scratch.free(slots);
    const w = s.evidence.get(now);
    for (entries, slots, 0..) |*e, *slot, i| {
        e.* = set.at(st, @intCast(i));
        slot.* = s.evidence.slotAt(Evidence.position(st, set.set, @intCast(i)));
        if (slot.asWanted() == was) {
            e.* = .{ .name = w.method, .fn_var = w.method_type, .region = w.origin, .origin = w.kind };
            slot.* = .wanted(now);
        }
    }
    const rebuilt = (try st.addConstraints(entries)).toOptional();
    for (slots, 0..) |slot, i| try s.evidence.setSlot(gpa, Evidence.position(st, rebuilt, @intCast(i)), slot);
    var with = flags;
    with.constraints = rebuilt;
    st.setContent(root, .{ .flex = with });
}

/// The two method types of a Rule-U1 join must agree:
/// `method_constraint_mismatch` at the younger's origin,
/// both types poisoned.
pub fn joinTypes(s: *Solve, younger: WantedId, older: WantedId) Error!void {
    const y = s.evidence.get(younger);
    const o = s.evidence.get(older);
    if (try s.unifyQuiet(o.method_type, y.method_type, y.origin)) return;
    try s.report.methodConstraintMismatch(y.origin, o.origin, y.method, y.method_type, o.method_type);
    try s.poison(o.method_type);
    try s.poison(y.method_type);
}

/// §9.2's `rigid` row: a given answers (its method type checked against the
/// wanted's), else the `number` bridge on a `number` rigid, else the
/// annotation does not allow the method — reported at the USE, once
/// per rigid, method and use (a rigid met twice inside one derived shape
/// is one missing clause).
fn rigid(s: *Solve, id: WantedId, root: Var, flags: TypeStore.Flags) Error!void {
    const w = s.evidence.get(id);
    if (s.evidence.givenNamed(s.store(), Walk.constraints(flags), w.method)) |given| {
        if (!try s.unifyQuiet(given.method_type, w.method_type, w.origin)) {
            try s.report.methodConstraintMismatch(w.origin, w.origin, w.method, w.method_type, given.method_type);
            return reject(s, id, true);
        }
        if (!try s.expect(given.decl != Evidence.Wanted.no_decl, w.origin, "a `where` clause's requirement has no evidence parameter (checker-v2.md §4.2)")) {
            return reject(s, id, false);
        }
        return answer(s, id, .{ .param = .{ .decl = given.decl, .k = given.k } });
    }
    if (flags.kind == .number and isWellKnownName(w.method)) return bridge(s, id, root);
    const key: MissingKey = .{ .origin = lineageOrigin(s, id), .rigid = root, .method = w.method };
    const seen = try s.resolver.missing.getOrPut(s.cx.gpa, key);
    if (seen.found_existing) return reject(s, id, false);
    if (w.kind == .type_dispatch) {
        try s.report.typeDispatchNeedsAnnotation(w.origin, flags.name, w.method, w.method_type);
        return reject(s, id, true);
    }
    try s.report.missingWhereConstraint(w.origin, w.kind == .where_clause, flags.name, w.method, w.method_type, letBindingOf(s, root));
    return reject(s, id, false);
}

/// The `let` binding whose annotation holds rigid `root`, if one does: a
/// `let` annotation takes no `where`, so §10.4's hint must not suggest one
/// (static-dispatch-spike.md §10.4). An error path
/// only: a walk of the group's annotated bindings.
fn letBindingOf(s: *Solve, root: Var) Symbol.Optional {
    const st = s.store();
    for (s.tree.annotated.items) |a| {
        if (!a.let) continue;
        for (s.tree.vars(a.rigids_start, a.rigids_len)) |r| {
            if (st.find(r) == root) return a.name;
        }
    }
    return .none;
}

/// §6.6: a given on a `number` rigid for
/// `eq` or `compare` is the `number` bridge's, so its declared type is
/// checked against `number, number -> Bool|Order` where the clause is
/// written, before the body uses it. Called at the declaration's `member`
/// node.
pub fn checkGivens(s: *Solve, decl: u32) Error!void {
    const st = s.store();
    for (s.evidence.givensOf(decl)) |g| {
        if (!isWellKnownName(g.method)) continue;
        const root = st.find(g.rigid);
        const flags = switch (st.content(root)) {
            .rigid => |f| f,
            else => continue,
        };
        if (flags.kind != .number) continue;
        const wanted = try wellKnownType(s, g.method, root);
        s.report.texts.clause = .{ .variable = flags.name, .method = g.method };
        defer s.report.texts.clause = null;
        _ = try s.unify(wanted, g.method_type, g.region, .{ .tag = .where_clause });
    }
}

// ---------------------------------------------------------------------------
// Sharing, and the lineage rule (§9.5)
// ---------------------------------------------------------------------------

/// A well-known wanted on a concrete receiver whose derived answer the module
/// already has: answered `alias` of it — its own method type checked against
/// `root, root -> Bool|Order` first, a unification that reports, never a
/// test. A hit that has since failed is never shared.
fn memoised(s: *Solve, id: WantedId, root: Var) Error!bool {
    const w = s.evidence.get(id);
    const hit = s.resolver.derived.get(.{ .root = root, .method = w.method }) orelse return false;
    if (hit == id or s.evidence.get(hit).state != .answered) return false;
    if (!try unifyWellKnown(s, id, root)) {
        try reject(s, id, false);
        return true;
    }
    answer(s, id, .{ .alias = hit });
    return true;
}

/// Remember `id`'s derived answer for its receiver `root` (`memoised`).
pub fn remember(s: *Solve, id: WantedId, root: Var) Error!void {
    try s.resolver.derived.put(s.cx.gpa, .{ .root = root, .method = s.evidence.get(id).method }, id);
}

/// A sub-wanted of `parent`: `method` on `receiver` at a fresh
/// `receiver, receiver -> Bool|Order` (a derived shape's position), stepped
/// at once. Its own resolution runs the derivability verdict again: nothing
/// is taken on trust from the parent's walk.
pub fn position(s: *Solve, parent: WantedId, receiver: Var) Error!WantedId {
    const p = s.evidence.get(parent);
    const method_type = try wellKnownType(s, p.method, receiver);
    const id = try create(s, p.method, receiver, method_type, p.origin, p.kind, parent.toOptional());
    s.evidence.ptr(id).decl = p.decl;
    // Resolution recursing into positions spends native stack the nesting
    // budget counts (§10.2).
    s.resolve_depth += 1;
    defer s.resolve_depth -= 1;
    try step(s, id, false);
    return id;
}

/// The root of `id`'s lineage: the wanted a use raised.
pub fn lineageRoot(s: *const Solve, id: WantedId) WantedId {
    var at = id;
    while (s.evidence.get(at).parent.unwrap()) |p| at = p;
    return at;
}

fn lineageOrigin(s: *const Solve, id: WantedId) Bir.Inst.Index {
    return s.evidence.get(lineageRoot(s, id)).origin;
}

// ---------------------------------------------------------------------------
// Step 7 of a top-level boundary (§8.1, §9.4)
// ---------------------------------------------------------------------------

/// Inside a binding group of two or more members, a requirement on a
/// `number`-kinded variable whose method is not `eq` or `compare`, which some
/// member's type does not reach. That member fixed the variable with a
/// literal (`ma 0 3`), so for its uses the receiver is a `number` never
/// chosen between `Int` and `Float` — the case a caller outside the group
/// reports as `unknown_method` at the instantiation (§9.4's default) — and
/// §12.3's case 3 has no structural answer for the method. Reported the same
/// way here, at the requirement's use, and the variable poisoned so nothing
/// promotes it: one answer in every declaration order.
fn undeterminedInGroup(s: *Solve, members: []const u32) Error!void {
    const st = s.store();
    const bir = s.cx.bir;
    const scratch = s.cx.scratch;
    var reqs: std.ArrayList(Evidence.Requirement) = .empty;
    defer reqs.deinit(scratch);
    for (members) |m| {
        const d = bir.decls[m];
        if (!d.kind.isValue() or d.body == .none or d.annotation != .none) continue;
        const header = s.decl_scheme[m].unwrap() orelse continue;
        reqs.clearRetainingCapacity();
        try Evidence.requirements(st, s.cx.interner, header, scratch, &reqs);
        for (reqs.items) |r| {
            if (isWellKnownName(r.method)) continue;
            const flags = switch (st.content(st.find(r.root))) {
                .flex => |f| f,
                else => continue,
            };
            if (flags.kind != .number) continue;
            const unreached = for (members) |other| {
                const od = bir.decls[other];
                if (!od.kind.isValue() or od.body == .none or od.annotation != .none) continue;
                const oh = s.decl_scheme[other].unwrap() orelse continue;
                if (!try Walk.reaches(st, &s.stacks, s.cx.gpa, oh, r.root)) break true;
            } else false;
            if (!unreached) continue;
            const id = s.evidence.slotAt(r.position).asWanted() orelse continue;
            const w = s.evidence.get(id);
            s.report.at(if (w.decl == Evidence.Wanted.no_decl) null else w.decl);
            try s.report.undeterminedMethodReceiver(w.origin, w.method, flags.kind);
            try s.poison(r.root);
        }
    }
    s.report.at(null);
}

/// Promotion, the cap, the two promotion diagnostics, then the proven-
/// undetermined default, for the wanteds still open on the variables step 5
/// quantified (`wanters`). `members` are the group's declarations.
pub fn close(s: *Solve, members: []const u32) Error!void {
    const st = s.store();
    const bir = s.cx.bir;
    const scratch = s.cx.scratch;
    if (members.len > 1) try undeterminedInGroup(s, members);
    // The roots some member's scheme reaches.
    var promoted: std.AutoHashMapUnmanaged(Var, void) = .empty;
    defer promoted.deinit(scratch);
    var reqs: std.ArrayList(Evidence.Requirement) = .empty;
    defer reqs.deinit(scratch);
    for (members) |m| {
        const d = bir.decls[m];
        if (!d.kind.isValue() or d.body == .none or d.annotation != .none) continue;
        const header = s.decl_scheme[m].unwrap() orelse continue;
        reqs.clearRetainingCapacity();
        try Evidence.requirements(st, s.cx.interner, header, scratch, &reqs);
        if (reqs.items.len == 0) continue;
        s.report.at(m);
        if (reqs.items.len > max_inferred_constraints) {
            try cap(s, m, reqs.items, &promoted);
            continue;
        }
        // The declaration's requirement list, for P9's table (§12.1).
        const first: u32 = @intCast(s.resolver.requirement_rows.items.len);
        for (reqs.items) |r| {
            try s.resolver.requirement_rows.append(s.cx.gpa, .{ .quantified = r.quantified, .var_name = st.flagsOf(r.root).name, .method = r.method });
            try s.resolver.requirement_roots.append(s.cx.gpa, r.root);
        }
        s.resolver.decl_requirements[m] = .{ .start = first, .len = @intCast(reqs.items.len) };
        for (reqs.items) |r| {
            try promoted.put(scratch, r.root, {});
            const id = s.evidence.slotAt(r.position).asWanted() orelse {
                _ = try s.expect(false, d.body.unwrap().?, "a promoted requirement is paired with no wanted (checker-v2.md §4.2)");
                continue;
            };
            const wp = s.evidence.ptr(id);
            if (wp.state != .open) continue;
            wp.state = .promoted;
            s.evidence.setAnswer(id, .{ .promoted = .{ .root = r.root, .method = r.method } });
        }
        // A scheme that failed publishes `<error>` (§14.1) and says nothing
        // more about its requirements.
        if (try Walk.hasError(st, &s.stacks, s.cx.gpa, header) != .clean) continue;
        if (!d.is_pub) continue;
        const region = d.body.unwrap().?;
        // A `pub` constant whose inferred scheme needs evidence would turn
        // into a thunk of it (§10.10).
        if (d.params == 0 and st.paramCount(header) == 0) {
            try s.report.constrainedConstant(region, d.name_token, bir.symbol(d.name), st.flagsOf(reqs.items[0].root).name, reqs.items[0].method);
            continue;
        }
        if (s.informational and s.cx.graph.module(s.cx.module).package == .app) {
            try s.report.ambiguousMethodReceiver(region, d.name_token, bir.symbol(d.name), @intCast(reqs.items.len), header);
        }
    }
    s.report.at(null);
    // The proven-undetermined default: a quantified receiver no scheme of
    // the group reaches can hold no value any execution passes, so `eq` and
    // `compare` are answered structurally; any other method has no type to
    // be looked up in.
    for (s.resolver.wanters.items) |v| {
        const root = st.find(v);
        if (promoted.contains(root)) continue;
        const flags = switch (st.content(root)) {
            .flex => |f| f,
            else => continue,
        };
        const set = Walk.constraints(flags);
        const n = set.count(st);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const id = s.evidence.slotAt(Evidence.position(st, set.set, i)).asWanted() orelse {
                _ = try s.expect(false, set.at(st, i).region, "a requirement on a quantified variable is paired with no wanted (checker-v2.md §4.2)");
                continue;
            };
            const w = s.evidence.get(id);
            if (w.state != .open) continue;
            if (isWellKnownName(w.method)) {
                s.evidence.ptr(id).state = .defaulted;
                s.evidence.setAnswer(id, .undetermined);
                continue;
            }
            s.report.at(if (w.decl == Evidence.Wanted.no_decl) null else w.decl);
            try s.report.undeterminedMethodReceiver(w.origin, w.method, flags.kind);
            s.evidence.ptr(id).state = .failed;
        }
    }
    s.report.at(null);
}

/// Over the cap (§6.4, §10.11): report, and generalise the declaration with
/// no requirements — every quantified variable loses its set, so the scheme
/// published has no `where` and the next link of a chain starts from zero.
fn cap(s: *Solve, decl: u32, reqs: []const Evidence.Requirement, promoted: *std.AutoHashMapUnmanaged(Var, void)) Error!void {
    const st = s.store();
    const bir = s.cx.bir;
    const d = bir.decls[decl];
    var names: [named_in_cap_message]Symbol = undefined;
    var receivers: [named_in_cap_message]Var = undefined;
    var named: usize = 0;
    for (reqs) |r| {
        if (named < names.len) {
            names[named] = r.method;
            receivers[named] = r.root;
            named += 1;
        }
        try promoted.put(s.cx.scratch, r.root, {});
        const id = s.evidence.slotAt(r.position).asWanted() orelse {
            _ = try s.expect(false, d.body.unwrap().?, "a requirement over the cap is paired with no wanted (checker-v2.md §4.2)");
            continue;
        };
        s.evidence.ptr(id).state = .failed;
    }
    for (reqs) |r| {
        switch (st.content(r.root)) {
            .flex => |flags| {
                var with = flags;
                with.constraints = .none;
                st.setContent(r.root, .{ .flex = with });
            },
            else => {},
        }
    }
    try s.report.tooManyInferredConstraints(d.body.unwrap().?, d.name_token, bir.symbol(d.name), @intCast(reqs.len), max_inferred_constraints, names[0..named], receivers[0..named]);
}

// ---------------------------------------------------------------------------
// Steps 5 and 7 of a `let` boundary (§8.4)
// ---------------------------------------------------------------------------

/// What a header binder of a `let` frame is, for §8.4's three rules.
const LetBinding = enum { function, value, annotated };

fn letBinding(s: *const Solve, b: Tree.Binder) LetBinding {
    const bir = s.cx.bir;
    if (b.region.int() >= bir.insts.len or bir.instTag(b.region) != .let_def) return .value;
    const data = bir.instData(b.region);
    const def = bir.extraData(@enumFromInt(data.lhs), Bir.LetDef);
    if (def.annotation != .none) return .annotated;
    if (def.params_end != def.params_start) return .function;
    const rhs: Bir.Inst.Index = @enumFromInt(data.rhs);
    return if (rhs.int() < bir.insts.len and bir.instTag(rhs) == .lambda) .function else .value;
}

/// Step 5's hold at a `let` frame of rank `rank`, before `quantify`: a young
/// root carrying an open wanted is quantified only when a function binding
/// of the frame reaches it, no value or pattern binding does, and not every
/// wanted on it is a dot-call's own. Everything else drops, with its method
/// types, to the enclosing rank, where the enclosing frame receives it
/// — rule (a)'s mechanism, for what §8.4 still holds. Each held root is
/// recorded for `type_mismatch`'s A.30 hint and for canonical pessimism
/// in recursive groups (`Recursion`).
pub fn holdLet(s: *Solve, rank: u32, binders: []const u32) Error!void {
    const st = s.store();
    const gpa = s.cx.gpa;
    const scratch = s.cx.scratch;
    var young: std.ArrayList(Var) = .empty;
    defer young.deinit(scratch);
    for (s.frame().pool.items) |v| {
        if (st.find(v) != v or st.rank(v) < rank) continue;
        const flags = switch (st.content(v)) {
            .flex => |f| f,
            else => continue,
        };
        if (Walk.constraints(flags).count(st) == 0) continue;
        try young.append(scratch, v);
    }
    if (young.items.len == 0) return;
    // What the frame's headers reach, by the walk §12.1's order reads.
    var by_function: std.AutoHashMapUnmanaged(Var, void) = .empty;
    defer by_function.deinit(scratch);
    var by_value: std.AutoHashMapUnmanaged(Var, void) = .empty;
    defer by_value.deinit(scratch);
    var reached: std.ArrayList(Var) = .empty;
    defer reached.deinit(scratch);
    for (binders) |i| {
        const b = s.tree.binders.items[i];
        if (!b.header) continue;
        const into = switch (letBinding(s, b)) {
            .function => &by_function,
            .value => &by_value,
            .annotated => continue,
        };
        reached.clearRetainingCapacity();
        try Schemes.quantifierOrder(st, s.cx.interner, b.v, &reached, scratch);
        for (reached.items) |r| try into.put(scratch, st.find(r), {});
    }
    // The decision per young root, before anything is lowered.
    var held: std.AutoArrayHashMapUnmanaged(Var, EnvFile.Monomorphic.Why) = .empty;
    defer held.deinit(scratch);
    for (young.items) |v| {
        const why: EnvFile.Monomorphic.Why = if (by_value.contains(v))
            .value
        else if (!by_function.contains(v))
            .unreached
        else if (onlyDotCalls(s, v))
            .dot_call
        else
            continue;
        try held.put(scratch, v, why);
    }
    // Over the cap (spike §10.11), a function binding is held whole rather
    // than refused: a `let` annotation cannot carry the `where` clause that
    // lifts the cap at the top level, so a refusal would have no escape
    // hatch (rule 7); such a helper is built monomorphically. The count is what `closeLet` would
    // promote: every entry on a young root the binding reaches and the
    // rules above do not hold.
    for (binders) |i| {
        const b = s.tree.binders.items[i];
        if (!b.header or letBinding(s, b) != .function) continue;
        reached.clearRetainingCapacity();
        try Schemes.quantifierOrder(st, s.cx.interner, b.v, &reached, scratch);
        var count: usize = 0;
        for (reached.items) |r| {
            const root = st.find(r);
            if (root != r or st.rank(root) < rank or held.contains(root)) continue;
            if (st.content(root) != .flex) continue;
            count += Walk.constraints(st.flagsOf(root)).count(st);
        }
        if (count <= max_inferred_constraints) continue;
        for (reached.items) |r| {
            const root = st.find(r);
            if (root != r or st.rank(root) < rank or held.contains(root)) continue;
            if (st.content(root) != .flex or Walk.constraints(st.flagsOf(root)).count(st) == 0) continue;
            try held.put(scratch, root, .cap);
        }
    }
    // In `young`'s order, so the store and the hint list are the same in
    // every run.
    for (young.items) |v| {
        const why = held.get(v) orelse continue;
        // A root an earlier hold lowered, or merged away, is no longer young.
        if (st.find(v) != v or st.rank(v) < rank) continue;
        const set = Walk.constraints(st.flagsOf(v));
        try s.report.monomorphic.append(scratch, .{ .v = v, .method = set.at(st, 0).name, .why = why });
        try Walk.lowerTo(st, &s.stacks, gpa, v, rank - 1);
    }
}

/// Whether every open wanted riding on `v` is a dot-call's own
/// (`Wanted.field_ok`): the owner's decision of 2026-09-26 that a `let`
/// over only dot-calls' requirements is not generalised over them.
fn onlyDotCalls(s: *Solve, v: Var) bool {
    const st = s.store();
    const set = Walk.constraints(st.flagsOf(v));
    const n = set.count(st);
    var i: u32 = 0;
    var any = false;
    while (i < n) : (i += 1) {
        const id = s.evidence.slotAt(Evidence.position(st, set.set, i)).asWanted() orelse return false;
        const w = s.evidence.get(id);
        if (w.state.rejected()) continue;
        if (!w.field_ok) return false;
        any = true;
    }
    return any;
}

/// Step 7's promotion at a `let` frame, after `quantify` (whose wanted
/// carriers are `wanters`): each unannotated function binding's list is its
/// header's requirements on roots this frame quantified, in canonical order
/// (§12.1); its open wanteds are answered `promoted`, and the list is one
/// `LetRow`. Over the cap `holdLet` has already held the binding. A
/// quantified carrier no list holds is `internal`: `holdLet` held it.
pub fn closeLet(s: *Solve, binders: []const u32) Error!void {
    const st = s.store();
    const scratch = s.cx.scratch;
    var own: std.AutoHashMapUnmanaged(Var, void) = .empty;
    defer own.deinit(scratch);
    for (s.resolver.wanters.items) |v| try own.put(scratch, st.find(v), {});
    var listed: std.AutoHashMapUnmanaged(Var, void) = .empty;
    defer listed.deinit(scratch);
    var all: std.ArrayList(Evidence.Requirement) = .empty;
    defer all.deinit(scratch);
    var reqs: std.ArrayList(Evidence.Requirement) = .empty;
    defer reqs.deinit(scratch);
    for (binders) |i| {
        const b = s.tree.binders.items[i];
        if (!b.header or letBinding(s, b) != .function) continue;
        all.clearRetainingCapacity();
        try Evidence.requirements(st, s.cx.interner, b.v, scratch, &all);
        reqs.clearRetainingCapacity();
        for (all.items) |r| {
            if (own.contains(st.find(r.root))) try reqs.append(scratch, r);
        }
        if (reqs.items.len == 0) continue;
        for (reqs.items) |r| try listed.put(scratch, st.find(r.root), {});
        const first: u32 = @intCast(s.resolver.requirement_rows.items.len);
        for (reqs.items) |r| {
            try s.resolver.requirement_rows.append(s.cx.gpa, .{ .quantified = r.quantified, .var_name = st.flagsOf(r.root).name, .method = r.method });
            try s.resolver.requirement_roots.append(s.cx.gpa, r.root);
            const id = s.evidence.slotAt(r.position).asWanted() orelse {
                _ = try s.expect(false, b.region, "a `let` binding's promoted requirement is paired with no wanted (checker-v2.md §4.2)");
                continue;
            };
            const wp = s.evidence.ptr(id);
            if (wp.state != .open) continue;
            wp.state = .promoted;
            s.evidence.setAnswer(id, .{ .promoted = .{ .root = r.root, .method = r.method } });
        }
        try s.resolver.let_rows.append(s.cx.gpa, .{
            .inst = b.region,
            .requirements = .{ .start = first, .len = @intCast(reqs.items.len) },
            .scheme = b.v,
        });
    }
    // Every carrier this frame quantified is some binding's (rule 1). It
    // holds because `holdLet` decides "reached" by `Schemes.quantifierOrder`,
    // the very walk `Evidence.requirements` lists a scheme's requirements by:
    // change one and the other must follow. Asked only of a module that has
    // reported nothing, so an error's poisoned types never reach the assert.
    if (s.module_report.errors == 0 and !s.module_report.quiet) for (s.resolver.wanters.items) |v| {
        const root = st.find(v);
        if (listed.contains(root)) continue;
        if (st.content(root) != .flex or !carriesOpen(s, root)) continue;
        const region: Bir.Inst.Index = if (binders.len != 0) s.tree.binders.items[binders[0]].region else @enumFromInt(0);
        _ = try s.expect(false, region, "a `let` quantified a constrained variable no function binding lists (checker-v2.md §8.4)");
        break;
    };
}

/// Whether an open wanted rides on `v`.
fn carriesOpen(s: *Solve, v: Var) bool {
    const st = s.store();
    const set = Walk.constraints(st.flagsOf(v));
    const n = set.count(st);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const id = s.evidence.slotAt(Evidence.position(st, set.set, i)).asWanted() orelse continue;
        if (s.evidence.get(id).state == .open) return true;
    }
    return false;
}
