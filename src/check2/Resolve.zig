//! The resolver (checker-v2.md §9): every wanted from the moment it is
//! created or readied until it is answered.
//!
//! **One step, by the receiver's root** (§9.2). `step` looks at
//! `find(w.receiver)`:
//!
//! | Root | Action |
//! |------|--------|
//! | `flex` of kind `number`, `eq`/`compare` | the `number` bridge (D9 as amended): unify the method type with `t, t -> Bool\|Order`, answer `primitive` |
//! | any other `flex` | ride on it (Rule U1's join with a wanted of the same name), open |
//! | `rigid` | a given: unify the method types, answer `param`; else the bridge on a `number` rigid; else `missing_where_constraint` (or `type_dispatch_needs_annotation`) at `w.origin` (CK-48), once per rigid, method and use |
//! | `err` | `failed`, silently |
//! | a structure | `Instances.lookup` (§9.3): the well-known table, the module rule, matching, derivation |
//!
//! **When** (§9.1): inline at the `method` node when the receiver is
//! already known (Rule U0, `immediate`); otherwise when `unify` readies it,
//! in the drain that runs after every constraint node (eager draining,
//! round 3 B-1) and at every boundary's step 1 — in `seq` order, shared with
//! the obligations.
//!
//! **Promotion and the proven-undetermined default** (§9.4) are step 7 of
//! the top-level boundary: `close`. A `let` binding keeps rule (a) until
//! R14 (§8.4's `let_constrained_monomorphic` switch): a young variable that
//! carries a wanted is not quantified by a `let` (`Solve.holdConstrained`),
//! so every promotion is a top-level declaration's. A promoted wanted
//! records its requirement `(root, method)`, never an index: the index is the
//! site's member's, which P6 computes by §12.3.
//!
//! **One failure, one owner.** A rejected wanted fails its whole lineage in
//! silence (a parent is never `answered` over a failed argument, I6/I8), and
//! a concrete receiver that rejected a method rejects it again in silence —
//! §9.5's class flag, which `Unify` carries to the survivor of every merge.
//!
//! **Termination** (§9.5): a wanted on a receiver that lies on a cycle is
//! `infinite_type` (`Instances.cyclic`), the derivability walk is iterative and
//! coloured per `(node, method)`, and every top-level group has a step budget,
//! reported when spent — which is what stops a non-cyclic chain that grows
//! (a `where` clause may constrain another parameter, so a repeated receiver
//! is no cycle: round-2 review, N1).
//!
//! **No speculation** (§7.5, I14, CK-35): nothing here may run while a
//! snapshot is open — checked, and `internal` if it ever is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Dispatch = @import("../check/Dispatch.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Evidence = @import("Evidence.zig");
const Instances = @import("Instances.zig");
const Messages = @import("Messages.zig");
const Solve = @import("Solve.zig");
const Walk = @import("Walk.zig");
const Tree = @import("constrain/Tree.zig");

const Var = TypeStore.Var;
const Symbol = InternPool.Symbol;
const Error = Solve.Error;
const WantedId = Evidence.WantedId;

/// The cap on an unannotated declaration's inferred requirements
/// (static-dispatch-spike.md §6.4, §10.11): v1's, unchanged.
pub const max_inferred_constraints = 64;
/// How many names `too_many_inferred_constraints` lists.
const named_in_cap_message = 5;
/// The backstop on resolution steps (§9.5, round 4 S4-3), per top-level
/// group: a runaway resolution is one group's, and a module of many ordinary
/// groups never reaches it (review F1).
pub const step_budget: u32 = 1 << 20;

/// The resolver's own tables (review S7): one owner.
pub const State = struct {
    /// Step 5's quantified variables that still carry wanteds (step 7).
    wanters: std.ArrayList(Var) = .empty,
    /// Per concrete receiver root and well-known method, the wanted that
    /// answered it with a DERIVED shape — the one answer that depends on the
    /// receiver alone (review B3): a DAG-shaped type is resolved once per
    /// node (CK-80). A method found by the module rule is instantiated per
    /// use and never shared.
    derived: std.AutoHashMapUnmanaged(MemoKey, WantedId) = .empty,
    /// The `(root, method kind)` pairs the derivability walk proved
    /// derivable over a GROUND subgraph — no variable below, so the verdict
    /// cannot change (`Instances.derivability`).
    derivable: std.AutoHashMapUnmanaged(Instances.PairKey, void) = .empty,
    /// `missing_where_constraint`s said, per use, rigid and method (F4).
    missing: std.AutoHashMapUnmanaged(MissingKey, void) = .empty,
    /// Steps in the current top-level group.
    steps: u32 = 0,
    /// What promotion kept, per unannotated declaration: a range of
    /// `requirement_rows`, in canonical order (§12.1), for P9's table.
    decl_requirements: []Dispatch.Range = &.{},
    requirement_rows: std.ArrayList(Dispatch.Requirement) = .empty,

    pub fn deinit(r: *State, gpa: Allocator) void {
        r.wanters.deinit(gpa);
        r.derived.deinit(gpa);
        r.derivable.deinit(gpa);
        r.missing.deinit(gpa);
        r.requirement_rows.deinit(gpa);
    }
};

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
    });
    s.obligations.seq += 1;
    return id;
}

/// The `method` node (Rule U0): the callee's wanted, resolved now when its
/// receiver is known, else riding on it.
pub fn method(s: *Solve, node: Tree.Node) Error!void {
    const info = s.tree.extraData(node.a, Tree.Method);
    const id = try create(s, info.name, info.receiver, info.method_type, node.region, @enumFromInt(info.kind), .none);
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
/// resolution: a record receiver known at the call is a FIELD call, one met
/// only later is `no_methods_on_shape` (static-dispatch-spike.md §6.3).
pub fn step(s: *Solve, id: WantedId, immediate: bool) Error!void {
    const st = s.store();
    const saved = s.report.current;
    defer s.report.at(saved);
    const w = s.evidence.get(id);
    s.report.at(if (w.decl == Evidence.Wanted.no_decl) saved else w.decl);
    // I14: a probe never resolves (§7.5).
    if (!try s.expect(st.depth == 0, w.origin, "the resolver ran inside a speculation (checker-v2.md §7.5, I14)")) return reject(s, id, false);

    s.resolver.steps += 1;
    if (s.resolver.steps == step_budget) try Messages.resolutionBudget(s.report, w.origin, step_budget);
    if (s.resolver.steps >= step_budget) return reject(s, id, true);

    const root, const content = st.resolved(w.receiver);
    switch (content) {
        // A poisoned receiver has its message: fail in silence (§7.1). An
        // over-long alias chain `resolved` answers as `err` too.
        .err => return reject(s, id, false),
        // `resolved` never stops at an alias (nit).
        .alias => {
            _ = try s.expect(false, w.origin, "`TypeStore.resolved` returned an alias (checker-v2.md §9.2)");
            return reject(s, id, false);
        },
        .flex => |flags| {
            if (flags.kind == .number and isWellKnownName(w.method)) return bridge(s, id, root);
            return attach(s, id, root, flags);
        },
        .rigid => |flags| return rigid(s, id, root, flags),
        .structure => |flat| {
            // A receiver on a cycle is one `infinite_type`, before anything
            // is shared or looked up (§9.5, the cycle test that replaced the
            // lineage rule: round-2 review, N1).
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
/// failed is no answer (I6, I8; review S3). The method type is poisoned when
/// `poison` (v1's rule: what the call returns is then silent), never the
/// receiver (§9.5: a rejection does not silence the receiver's other uses,
/// CK-37); a concrete receiver is flagged for this method, so a later
/// wanted of the same method there fails in silence.
pub fn reject(s: *Solve, id: WantedId, poison: bool) Error!void {
    s.evidence.ptr(id).state = .failed;
    var at = s.evidence.get(id).parent;
    while (at.unwrap()) |p| {
        const pp = s.evidence.ptr(p);
        if (pp.state == .failed) break;
        pp.state = .failed;
        at = pp.parent;
    }
    if (!poison) return;
    const w = s.evidence.get(id);
    const root = s.store().find(w.receiver);
    if (s.store().content(root) == .structure) try s.evidence.setRejected(s.cx.gpa, root, flagOf(w));
    try s.poison(w.method_type);
}

pub fn isWellKnownName(name: Symbol) bool {
    return name == InternPool.WellKnown.eq.symbol() or name == InternPool.WellKnown.compare.symbol();
}

/// Whether `w` may DERIVE (static-dispatch-spike.md §3.3 step 2, §1.3 rule
/// 2): a well-known name asked by anything but a hand-written dot-call.
pub fn derives(w: Evidence.Wanted) bool {
    return w.kind != .dot_call and isWellKnownName(w.method);
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

/// Unify `w.method_type` with `root, root -> Bool|Order`, reported at the
/// wanted's origin. False when it failed (and was reported).
pub fn unifyWellKnown(s: *Solve, id: WantedId, root: Var) Error!bool {
    const w = s.evidence.get(id);
    const wanted = try wellKnownType(s, w.method, root);
    // A clause's declared type against the method's: `.where_clause` (CK-55).
    const category: Tree.Category = .{ .tag = if (w.kind == .where_clause) .where_clause else .general };
    return try s.unify(wanted, w.method_type, w.origin, category) == .ok;
}

/// **The `number` bridge** (D9 as amended, §9.2): a `number` is `Int` or
/// `Float`, and §3.2's table answers both alike, so `eq`/`compare` on one
/// needs no evidence — once the declared method type is checked against the
/// well-known one (CK-21).
fn bridge(s: *Solve, id: WantedId, root: Var) Error!void {
    const w = s.evidence.get(id);
    if (!try unifyWellKnown(s, id, root)) return reject(s, id, false);
    answer(s, id, .{ .primitive = if (w.method == InternPool.WellKnown.eq.symbol()) .strict_eq else .num_compare });
}

/// A wanted on a flex rides on it: one entry of its constraint set (§4.1,
/// *Decided by R5*). A wanted of the same name already there is Rule U1's
/// join: the older answers both, the younger is `alias(older)` and the two
/// method types must agree (`method_constraint_mismatch` at the younger's
/// origin otherwise). The method type is lowered to the receiver's rank
/// (I15). An entry that is not paired with a wanted is `internal` (S2).
fn attach(s: *Solve, id: WantedId, root: Var, flags: TypeStore.Flags) Error!void {
    const st = s.store();
    const gpa = s.cx.gpa;
    const w = s.evidence.get(id);
    s.evidence.ptr(id).state = .open;
    const set = Walk.constraints(flags);
    switch (s.evidence.named(st, set, w.method)) {
        .absent => {},
        .unpaired => {
            _ = try s.expect(false, w.origin, "a method requirement on a variable is paired with no wanted (checker-v2.md §4.2 *As built by R6a*)");
            return reject(s, id, false);
        },
        .wanted => |other| {
            if (other == id) return;
            // A failed wanted left on a live flex (a call's requirement
            // failed in silence, `Solve.failInstantiation`) is no answer: the
            // new wanted takes its place in the set, open, and is never
            // aliased to it (§4.2: a flex's set is its open wanteds; round-2
            // review, S1).
            if (s.evidence.get(other).state == .failed) {
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

/// The two method types of a Rule-U1 join must agree (v1's
/// `unifyPending`): `method_constraint_mismatch` at the younger's origin,
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
/// annotation does not allow the method — reported at the USE (CK-48), once
/// per rigid, method and use (F4: a rigid met twice inside one derived shape
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
    try s.report.missingWhereConstraint(w.origin, w.kind == .where_clause, flags.name, w.method, w.method_type);
    return reject(s, id, false);
}

/// §6.6 as refined by R6a's review (S6): a given on a `number` rigid for
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
        _ = try s.unify(wanted, g.method_type, g.region, .{ .tag = .where_clause });
    }
}

// ---------------------------------------------------------------------------
// Sharing, and the lineage rule (§9.5)
// ---------------------------------------------------------------------------

/// A well-known wanted on a concrete receiver whose derived answer the module
/// already has: answered `alias` of it — its own method type checked against
/// `root, root -> Bool|Order` first, a unification that reports, never a
/// test (review B3). A hit that has since failed is never shared.
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
/// is taken on trust from the parent's walk (review B1).
pub fn position(s: *Solve, parent: WantedId, receiver: Var) Error!WantedId {
    const p = s.evidence.get(parent);
    const method_type = try wellKnownType(s, p.method, receiver);
    const id = try create(s, p.method, receiver, method_type, p.origin, p.kind, parent.toOptional());
    s.evidence.ptr(id).decl = p.decl;
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

/// Promotion, the cap, the two promotion diagnostics, then the proven-
/// undetermined default, for the wanteds still open on the variables step 5
/// quantified (`wanters`). `members` are the group's declarations.
pub fn close(s: *Solve, members: []const u32) Error!void {
    const st = s.store();
    const bir = s.cx.bir;
    const scratch = s.cx.scratch;
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
        for (reqs.items) |r| try s.resolver.requirement_rows.append(s.cx.gpa, .{ .quantified = r.quantified, .var_name = st.flagsOf(r.root).name, .method = r.method });
        s.resolver.decl_requirements[m] = .{ .start = first, .len = @intCast(reqs.items.len) };
        for (reqs.items) |r| {
            try promoted.put(scratch, r.root, {});
            const id = s.evidence.slotAt(r.position).asWanted() orelse {
                _ = try s.expect(false, d.body.unwrap().?, "a promoted requirement is paired with no wanted (checker-v2.md §4.2 *As built by R6a*)");
                continue;
            };
            const wp = s.evidence.ptr(id);
            if (wp.state != .open) continue;
            wp.state = .promoted;
            s.evidence.setAnswer(id, .{ .promoted = .{ .root = r.root, .method = r.method } });
        }
        // A scheme that failed publishes `<error>` (§14.1) and says nothing
        // more about its requirements (review F6).
        if (try Walk.hasError(st, &s.stacks, s.cx.gpa, header) != .clean) continue;
        if (!d.is_pub) continue;
        const region = d.body.unwrap().?;
        // A `pub` constant whose inferred scheme needs evidence would turn
        // into a thunk of it (§10.10, narrowed by R2b's review).
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
                _ = try s.expect(false, set.at(st, i).region, "a requirement on a quantified variable is paired with no wanted (checker-v2.md §4.2 *As built by R6a*)");
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
    var named: usize = 0;
    for (reqs) |r| {
        if (named < names.len) {
            names[named] = r.method;
            named += 1;
        }
        try promoted.put(s.cx.scratch, r.root, {});
        const id = s.evidence.slotAt(r.position).asWanted() orelse {
            _ = try s.expect(false, d.body.unwrap().?, "a requirement over the cap is paired with no wanted (checker-v2.md §4.2 *As built by R6a*)");
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
    try s.report.tooManyInferredConstraints(d.body.unwrap().?, d.name_token, bir.symbol(d.name), @intCast(reqs.len), max_inferred_constraints, names[0..named]);
}
