//! The solver (checker-v2.md §6.1, §7, §8.1–§8.3, §8.5, §8.6): one walk
//! over a binding group's constraint tree, the arity suite of `checker.md`
//! §8.3, the obligations of §4.5, and the boundary of every frame.
//!
//! **A frame is pushed for every boundary** (§8.1): a top-level group's —
//! in SCC order, or nested at demand in the middle of another's solving, one
//! rank above every open frame (`Groups.zig`, §10) — and one per `let`
//! group. A top-level-kind frame merged into one below it (§10.4) runs steps
//! 1 and 2 only and hands down (`Groups.handDown`). At every other frame's
//! boundary, in this order (I16):
//!
//!   1. settle — drain the frame's own `ready` queue (a `let` frame's is
//!      its top-level-kind frame's, §9.1), `equatable` rows included. No
//!      default;
//!   2. adjust ranks over the young pool (`Generalize.adjustRanks`, `owned`),
//!      so a variable's rank now says whether it escapes;
//!   3. defaults — every `try` on this frame's open list whose target still
//!      sits at its rank is decided as `Result`; one whose target escaped
//!      moves to its frame's list (§8.6, D2 as amended); if one was decided,
//!      or anything was readied, back to 1;
//!   4. occurs over the frame's binders — parameters and pattern variables,
//!      then headers — one run of shared epochs (`Walk.Occurs`,
//!      `structural`): a cycle is `infinite_type` at the binder and its node
//!      is poisoned (§8.2, CK-04, CK-57). No `touched` walk: §18's fallback.
//!      Then from every wanted's method type and open obligation riding on the
//!      pool (R6a);
//!   5. quantify what is still at the young rank — at a `let`,
//!      what D5 does not generalise is held at the enclosing rank first
//!      (`Resolve.holdLet`, §8.4 *As built by R14*);
//!   6. check every annotated binding's rigids (§8.3, I1): still rigid, and
//!      generalised — an escaped one is `rigid_mismatch` at its first
//!      capture (CK-01), and the binding's scheme is poisoned;
//!   7. close — an obligation still open on a variable step 5 quantified is
//!      reported (`tuple_index`, `interpolatable`) or folded (`equatable`)
//!      (§8.5); one on an escaped variable stays attached to it (I3). At the
//!      top level, promotion and the proven-undetermined default
//!      (`Resolve.close`, §9.4);
//!   8. pop.
//!
//! **Obligations** (§4.5, §8.5, §8.6) are `Decide.zig`'s: a `tuple_index`,
//! `interpolatable` or `try` node is decided at once when what decides it is
//! already known, and otherwise becomes a row of `Obligations` riding on its
//! deciding flex variables, its dependants lowered to its owner's rank (I15 as
//! amended). `unify`
//! readies it when one of them is bound; the queue is drained after every
//! constraint node (§9.1's eager draining) and at step 1.
//!
//! **Wanteds** (§4.2, §9) are `Resolve.zig`'s: a `method` node creates one
//! and resolves it at once when its receiver is known (Rule U0), an
//! instantiation creates one per requirement (I5), and `unify` readies them
//! onto the same queue as obligations, drained in one `seq` order.
//!
//! **Errors never stop the build.** A failed unification reports once and
//! poisons both sides (research/02 §6), and a second bad argument to the
//! same call is poisoned quietly (v1's `last_bad_call`).
//!
//! The solver reads no generation-time context (I11): every reference was
//! resolved to a variable by the generator, or names an instruction whose
//! type `Instantiate.reference` reads from the Bir or an interface.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Dispatch = @import("Dispatch.zig");
const TypeStore = @import("TypeStore.zig");
const Context = @import("Context.zig");
const Decide = @import("Decide.zig");
const Generalize = @import("Generalize.zig");
const Groups = @import("Groups.zig");
const Recursion = @import("Recursion.zig");
const Marker = @import("Marker.zig");
const Instantiate = @import("Instantiate.zig");
const InternPool = @import("../InternPool.zig");
const Evidence = @import("Evidence.zig");
const Resolve = @import("Resolve.zig");
const Contexts = @import("Contexts.zig");
const Messages = @import("Messages.zig");
const Obligations = @import("Obligations.zig");
const Report = @import("Report.zig");
const Unify = @import("Unify.zig");
const Walk = @import("Walk.zig");
const Tree = @import("constrain/Tree.zig");

const Solve = @This();

pub const Var = TypeStore.Var;
pub const Error = Allocator.Error;
const Constraint = Tree.Constraint;
const Category = Tree.Category;
const Frame = Generalize.Frame;

cx: *const Context,
report: *Report,
tree: *const Tree.Tree = undefined,
frames: std.ArrayList(Frame) = .empty,
captures: std.ArrayList(Generalize.Capture) = .empty,
stacks: Walk.Stacks = .{},
unifier: Unify = undefined,
instantiate: Instantiate = undefined,
/// The module's obligations (§4.5), decided by `Decide.zig`.
obligations: Obligations = .{},
/// The `equatable` marker walk (§11.4).
marker: Marker = undefined,
/// The shape every `?` was decided as, for the dispatch table (`checker.md`
/// §6.5): P9 sorts them by instruction.
tries: std.ArrayList(Dispatch.Try) = .empty,
/// Step 5's quantified variables that still carry obligations (step 7).
carriers: std.ArrayList(Var) = .empty,
/// One `ready` queue per top-level-kind frame ever pushed (§9.1): a frame's
/// `queue` indexes here, and a `let` frame shares its top-level frame's.
/// `Unify` holds a pointer to the list.
queues: std.ArrayList(Generalize.Queue) = .empty,
/// The binding groups, their status and the nesting of §10 (`Groups.zig`).
groups: *Groups = undefined,
/// The solve depth at which the current top-level-kind group started: the
/// per-declaration guard counts from it (§10.2's budget counts from 0).
depth_base: u32 = 0,
/// What the nested checks now open were charged (§10.2's `nest_cost` each).
nest_units: u32 = 0,
/// How deep resolution is recursing into derived positions (`Resolve.position`),
/// which the nesting budget also counts (§10.2).
resolve_depth: u32 = 0,
/// Open frames that are a recursive group's (D14, §10.7): none, and D14 has
/// nothing to look up.
recursive_frames: u32 = 0,
/// The current top-level-kind frame's `ready` list, held here while its
/// frame is current (its `Queue.ready` is empty meanwhile), so the check
/// after every constraint node reads one field (`readied`). `pushFrame` and
/// `popFrame` swap it; `Unify.enqueue` appends here for the current queue.
ready: std.ArrayList(u32) = .empty,
/// The queue `ready` belongs to.
ready_queue: u32 = Generalize.Queue.none,
/// Queues free for reuse (`pushFrame`).
free_queues: std.ArrayList(u32) = .empty,
/// The `ready` buffers of popped queues, for the next frames to reuse.
spare: std.ArrayList(std.ArrayList(u32)) = .empty,
/// The call whose arguments already produced a message (v1's rule).
last_bad_call: Bir.Inst.OptionalIndex = .none,
depth: u32 = 0,
generalisations: u64 = 0,
/// The module's wanteds and givens (§4.2), resolved by `Resolve.zig`.
evidence: Evidence = .{},
/// The resolver's own tables (§9): one owner, `Resolve.zig` (S7).
resolver: Resolve.State = .{},
/// The module's derived contexts (§11.2): set by `Module` in P1.
contexts: Contexts = undefined,
/// The module's own report. A fixpoint resolves under a quiet one, and a
/// group it nests is checked with this one (`Groups.solveGroup`).
module_report: *Report = undefined,
/// Per declaration: its published scheme, or for an unannotated member of
/// the group being solved its monomorphic variable (Module's table).
decl_scheme: []const Var.Optional = &.{},
/// P3's own-name index: every value of this module by name, sorted by
/// symbol (§5, CK-42).
own_values: []const OwnValue = &.{},
/// `ambiguous_method_receiver` is emitted (static-dispatch-spike.md §10.9).
informational: bool = false,

pub const OwnValue = struct { name: InternPool.Symbol, decl: u32 };

/// In place: the unifier, instantiator and walks point at `s`'s own lists.
pub fn init(s: *Solve, cx: *const Context, report: *Report) void {
    s.* = .{ .cx = cx, .report = report, .module_report = report };
    s.stacks.obligations = &s.obligations;
    s.unifier = .{
        .store = cx.store,
        .types = cx.types,
        .interner = cx.interner,
        .gpa = cx.gpa,
        .scratch = cx.scratch,
        .frames = &s.frames,
        .captures = &s.captures,
        .obligations = &s.obligations,
        .queues = &s.queues,
        .ready = &s.ready,
        .ready_queue = &s.ready_queue,
        .stacks = &s.stacks,
        .evidence = &s.evidence,
    };
    s.instantiate = .{ .cx = cx, .frames = &s.frames, .stacks = &s.stacks, .evidence = &s.evidence, .seq = &s.obligations.seq, .queue = &s.obligations.current_queue };
    s.marker = .{ .cx = cx, .obligations = &s.obligations, .contexts = &s.contexts, .solve = s };
}

pub fn deinit(s: *Solve) void {
    const gpa = s.cx.gpa;
    for (s.frames.items) |*f| f.deinit(gpa);
    s.frames.deinit(gpa);
    s.captures.deinit(gpa);
    s.stacks.deinit(gpa);
    s.instantiate.deinit();
    s.unifier.deinit();
    s.obligations.deinit(gpa);
    s.marker.deinit();
    s.tries.deinit(gpa);
    s.carriers.deinit(gpa);
    for (s.queues.items) |*q| q.deinit(gpa);
    s.queues.deinit(gpa);
    for (s.spare.items) |*l| l.deinit(gpa);
    s.ready.deinit(gpa);
    s.free_queues.deinit(gpa);
    s.spare.deinit(gpa);
    s.evidence.deinit(gpa);
    s.resolver.deinit(gpa);
}

pub fn store(s: *const Solve) *TypeStore {
    return s.cx.store;
}

pub fn frame(s: *Solve) *Frame {
    return &s.frames.items[s.frames.items.len - 1];
}

pub fn fresh(s: *Solve, content: TypeStore.Content) Error!Var {
    const f = s.frame();
    const v = try s.store().fresh(content, f.rank);
    try f.pool.append(s.cx.gpa, v);
    return v;
}

/// Poison `v`'s root. A flex that carried obligations settles them: nothing
/// can decide them now, so each is closed as a decision on `err` would close
/// it — its results poisoned, in silence (§7.1's rule for `err`), without a
/// trip through the queue (review S7).
pub fn poison(s: *Solve, v: Var) Error!void {
    const st = s.store();
    const root = st.find(v);
    const flags: TypeStore.Flags = switch (st.content(root)) {
        .flex => |f| f,
        // A rigid's constraints are givens, not wanteds: only its rows (an
        // interpolation held on it, CK-154) are settled.
        .rigid => |f| {
            st.setContent(root, .err);
            if (f.obls != .none) try Decide.settle(s, f.obls);
            return;
        },
        else => .{},
    };
    st.setContent(root, .err);
    if (flags.obls != .none) try Decide.settle(s, flags.obls);
    // The wanteds riding on it are answered against `err`: poisoned, silently
    // (§7.1).
    const set = Walk.constraints(flags);
    const n = set.count(st);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const id = s.evidence.slotAt(Evidence.position(st, set.set, i)).asWanted() orelse {
            _ = try s.expect(false, s.unifier.region, "a method requirement on a flex is paired with no wanted (checker-v2.md §4.2 *As built by R6a*)");
            continue;
        };
        const w = s.evidence.ptr(id);
        if (w.state == .open) try Resolve.poisoned(s, id);
    }
}

/// An invariant the solver relies on (review S2, S8): false is a bug in the
/// checker, never in the program. A debug build stops at it; a release build
/// reports `internal` at `region` and the caller takes its safe path, so a
/// broken invariant is never a silent drop.
pub fn expect(s: *Solve, cond: bool, region: Bir.Inst.Index, what: []const u8) Error!bool {
    if (cond) return true;
    if (builtin.mode == .Debug) std.debug.panic("checker v2 invariant: {s}", .{what});
    try s.report.internal(region, what);
    return false;
}

/// Every requirement the last instantiation copied became a wanted (S2).
pub fn paired(s: *Solve, region: Bir.Inst.Index) Error!void {
    if (s.instantiate.unpaired == 0) return;
    s.instantiate.unpaired = 0;
    _ = try s.expect(false, region, "an instantiation's requirement is paired with no wanted (checker-v2.md §4.2 *As built by R6a*)");
}

/// After an instantiation at `inst`: the wanteds it made, in the callee's
/// canonical order (I5), are its `inst_evidence` row — recorded HERE, where
/// they are created, so R6b reads the order and never recomputes it (review
/// B4). An entry the copy could not pair is `internal` (S2).
pub fn instantiated(s: *Solve, inst: Bir.Inst.Index) Error!void {
    try s.paired(inst);
    const made = s.instantiate.made.items;
    if (made.len == 0) return;
    const args = try s.evidence.addArgs(s.cx.gpa, made);
    try s.evidence.inst_evidence.append(s.cx.gpa, .{ .inst = inst, .args = args });
}

/// The value of this module named `name`, `pub` or not: P3's index (§5),
/// one binary search, never a scan of the declarations (CK-42).
pub fn ownValue(s: *const Solve, name: InternPool.Symbol) ?u32 {
    var lo: usize = 0;
    var hi: usize = s.own_values.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const at = @intFromEnum(s.own_values[mid].name);
        if (at < @intFromEnum(name)) lo = mid + 1 else if (at > @intFromEnum(name)) hi = mid else return s.own_values[mid].decl;
    }
    return null;
}

// ---------------------------------------------------------------------------
// A top-level group
// ---------------------------------------------------------------------------

/// Whether the current frame's queue holds something readied.
pub fn readied(s: *const Solve) bool {
    return s.ready.items.len != 0;
}

// ---------------------------------------------------------------------------
// The walk
// ---------------------------------------------------------------------------

pub fn solve(s: *Solve, first: Constraint) Error!void {
    if (first == .none) return;
    s.depth += 1;
    defer s.depth -= 1;
    // The parser bounds how deep one declaration's expressions nest, and a
    // `let`'s groups are a TAIL chain the loop below walks without
    // recursing, so an accepted file cannot reach this. If one ever does it
    // says so (I4): v1 returned here in silence, and a `let` of 5 000
    // bindings lost its last constraints and published a wrong scheme
    // (CK-91).
    if (s.depth - s.depth_base > Tree.Generator.max_depth) {
        return s.report.nestingTooDeep(s.tree.node(first).region, Tree.Generator.max_depth);
    }
    var c = first;
    while (c != .none) {
        const node = s.tree.node(c);
        c = .none;
        switch (node.tag) {
            .true_ => {},
            .and_ => for (s.tree.constraints(node.a, node.b)) |child| try s.solve(child),
            .equal => _ = try s.unify(@enumFromInt(node.a), @enumFromInt(node.b), node.region, node.category),
            .call => try s.call(node),
            .instantiate => {
                s.instantiate.origin = node.region;
                s.instantiate.made.clearRetainingCapacity();
                const copy = try s.instantiate.copy(@enumFromInt(node.b));
                try s.instantiated(node.region);
                _ = try s.unify(@enumFromInt(node.a), copy, node.region, node.category);
            },
            .reference => {
                const target: Var = @enumFromInt(node.a);
                s.instantiate.made.clearRetainingCapacity();
                if (try s.instantiate.reference(node.region)) |scheme| {
                    const copy = try s.instantiate.copy(scheme);
                    try s.instantiated(node.region);
                    _ = try s.unify(target, copy, node.region, node.category);
                } else try s.poison(target);
            },
            // A `let` group's body is its tail: the loop continues with it.
            .let_ => c = try s.let_(node),
            .binders_end => {
                var run: Walk.Occurs = .begin(s.store());
                for (node.a..node.a + node.b) |i| try s.occursBinder(&run, s.tree.binders.items[i]);
            },
            .member => {
                s.report.at(node.a);
                s.instantiate.decl = node.a;
                try Resolve.checkGivens(s, node.a);
            },
            .tuple_index => {
                const payload = s.tree.extraData(node.b, Tree.TupleIndex);
                const id = try s.obligations.create(s.cx.gpa, .tuple_index, node.region, &.{ @enumFromInt(node.a), payload.result }, payload.index, null);
                try Decide.begin(s, id);
            },
            .interpolatable => {
                const id = try s.obligations.create(s.cx.gpa, .interpolatable, node.region, &.{@enumFromInt(node.a)}, 0, null);
                try Decide.begin(s, id);
            },
            .record => {
                const info = s.tree.extraData(node.a, Tree.RecordLiteral);
                if (try s.takesFields(info.expected, info.record)) {
                    _ = try s.unify(info.expected, info.record, node.region, node.category);
                    try s.solveFields(info.fields);
                } else {
                    try s.solveFields(info.fields);
                    _ = try s.unify(info.expected, info.record, node.region, node.category);
                }
            },
            .try_ => {
                const payload = s.tree.extraData(node.a, Tree.Try);
                const id = try s.obligations.create(s.cx.gpa, .@"try", node.region, &.{ payload.subject, payload.target, payload.value }, 0, null);
                try Decide.begin(s, id);
            },
            .method => try Resolve.method(s, node),
            .demand => try Groups.demanded(s, node),
            .internal => {
                try s.poison(@enumFromInt(node.a));
                try s.report.internal(node.region, "checker v2 met a form its subset excludes; the subset gate (checker-v2.md §5, *As built by R4b*) should have refused this module");
            },
        }
        // Eager draining (§9.1): what this node readied is decided now, at
        // the same step a type known earlier would have been.
        if (s.readied()) try Decide.drain(s, s.frame().queue, false);
    }
}

/// A record literal's fields: their conjunction's children solved from the
/// literal's own frame, not through a frame and a depth unit of the
/// conjunction's own. A literal nested d deep was 2d units deep, and one
/// past about 2 100 levels was refused though the parser accepts 4 096
/// (CK-114); now it is d, one unit per level like every other expression.
inline fn solveFields(s: *Solve, fields: Constraint) Error!void {
    if (fields == .none) return;
    const node = s.tree.node(fields);
    if (node.tag != .and_) return s.solve(fields);
    for (s.tree.constraints(node.a, node.b)) |child| try s.solve(child);
}

/// §6.5 as built by R5: whether a record literal is checked against the
/// expectation first (pushed down, as v1 does) — because the meeting cannot
/// fail on a field name, on closedness or on a kind. That is an unkinded
/// variable; a closed record with exactly the literal's field names; or a
/// record open on a flex whose names are all the literal's. Otherwise the
/// fields are constrained first, so the message shows the literal's own
/// field types (CK-59): a `number` or `appendable` variable (review S1), a
/// missing or unexpected name, or a row on a rigid.
fn takesFields(s: *Solve, expected: Var, literal: Var) Error!bool {
    const st = s.store();
    const gpa = s.cx.gpa;
    const wanted = switch (st.resolvedContent(expected)) {
        .flex => |flags| return flags.kind == .any,
        .structure => |flat| switch (flat) {
            .record => |r| r,
            else => return false,
        },
        else => return false,
    };
    const own = switch (st.resolvedContent(literal)) {
        .structure => |flat| switch (flat) {
            .record => |r| r,
            else => return false,
        },
        else => return false,
    };
    const row = &s.stacks.fields;
    row.clearRetainingCapacity();
    var concatenated = false;
    const end = try Walk.recordRow(st, wanted, row, gpa, &concatenated);
    const open = switch (end) {
        .closed => false,
        .open => |v| if (st.content(st.find(v)) == .flex) true else return false,
    };
    const names = Walk.recordFields(st, own);
    if (row.items.len > names.len or (!open and row.items.len != names.len)) return false;
    if (concatenated) std.mem.sort(TypeStore.Field, row.items, {}, symbolLessThan);
    // Both sorted by symbol: every wanted name must be one of the literal's.
    var j: usize = 0;
    for (row.items) |w| {
        while (j < names.len and @intFromEnum(names[j].name) < @intFromEnum(w.name)) j += 1;
        if (j == names.len or names[j].name != w.name) return false;
        j += 1;
    }
    return true;
}

fn symbolLessThan(_: void, a: TypeStore.Field, b: TypeStore.Field) bool {
    return @intFromEnum(a.name) < @intFromEnum(b.name);
}

/// `CLet`: a frame one rank in for the header, and its boundary. Returns the
/// body, which the caller solves as its tail at the enclosing rank.
fn let_(s: *Solve, node: Tree.Node) Error!Constraint {
    const info = s.tree.extraData(node.a, Tree.Let);
    try Generalize.pushFrame(s, info.rank, .let);
    try s.frame().pool.appendSlice(s.cx.gpa, s.tree.vars(info.vars_start, info.vars_len));
    try s.solve(info.header_con);
    try s.boundary(s.tree.words(info.binders_start, info.binders_len), s.tree.words(info.annotated_start, info.annotated_len), null);
    Generalize.popFrame(s);
    return info.body_con;
}

// ---------------------------------------------------------------------------
// Unification and its report
// ---------------------------------------------------------------------------

pub const Outcome = enum { ok, reported, suppressed };

pub fn unify(s: *Solve, expected: Var, actual: Var, region: Bir.Inst.Index, category: Category) Error!Outcome {
    // A call's argument meeting its parameter is where a comparison's
    // `equatable` question is asked (§11.4 *As built by R5*).
    const result = try s.unifier.unifyAt(expected, actual, region, category.tag == .call_arg);
    try s.reportJoins();
    const problem = switch (result) {
        .ok => return .ok,
        .mismatch => |p| p,
    };
    const owner = if (category.tag == .call_arg) category.owner else .none;
    if (owner != .none and owner == s.last_bad_call) {
        // A second bad argument to the SAME call: poison, stay quiet.
        try s.poison(expected);
        try s.poison(actual);
        return .suppressed;
    }
    s.last_bad_call = owner;
    try s.reportFailure(region, category, expected, actual, problem);
    try s.poison(expected);
    try s.poison(actual);
    return .reported;
}

/// Rule-U1 joins the last unification left disagreeing (`Unify.join_failures`):
/// `method_constraint_mismatch` at the younger wanted's origin, both method
/// types poisoned (v1's `unifyPending`).
/// `unify` without a message of its own: the caller reports what failed.
/// A Rule-U1 join inside it is still reported (`reportJoins`).
pub fn unifyQuiet(s: *Solve, a: Var, b: Var, region: Bir.Inst.Index) Error!bool {
    const result = try s.unifier.unify(a, b, region);
    try s.reportJoins();
    return result == .ok;
}

pub fn reportJoins(s: *Solve) Error!void {
    if (s.unifier.fault == null and s.unifier.join_failures.items.len == 0) return;
    if (s.unifier.fault) |what| {
        s.unifier.fault = null;
        try s.report.internal(s.unifier.region, what);
    }
    const failures = &s.unifier.join_failures;
    while (failures.items.len != 0) {
        const j = failures.orderedRemove(0);
        const y = s.evidence.get(j.younger);
        const o = s.evidence.get(j.older);
        try s.report.methodConstraintMismatch(y.origin, o.origin, y.method, y.method_type, o.method_type);
        try s.poison(o.method_type);
        try s.poison(y.method_type);
    }
}

fn reportFailure(s: *Solve, region: Bir.Inst.Index, category: Category, expected: Var, actual: Var, problem: ?Unify.Problem) Error!void {
    // A mismatch D14 caused says so (§10.7): read now, before the report
    // poisons both sides; written when the class is final (§10.8).
    const d14 = !s.report.quiet and try Recursion.involved(s, expected, actual);
    const before = s.report.items.items.len;
    try s.reportFailureText(region, category, expected, actual, problem);
    if (d14 and s.report.items.items.len > before) {
        const owner: Bir.Inst.OptionalIndex = if (category.tag == .call_arg) category.owner else .none;
        try Recursion.note(s, before, region, owner);
    }
}

fn reportFailureText(s: *Solve, region: Bir.Inst.Index, category: Category, expected: Var, actual: Var, problem: ?Unify.Problem) Error!void {
    const r = s.report;
    // A cycle on either side is the mistake, and the failure its consequence
    // (§7.3 *amended by R15-fix-G*, CK-177): `[ x, ( x, x ), { zb = x } ]`
    // is `a = ( a, a )`, never a mismatch printing that tuple unrolled.
    // Unification does not occurs-check a binding — the boundary does
    // (§8.2) — so a cycle made earlier in the group is still here. Only on
    // the error path, which is where `too_deep` always looked.
    for ([_]Var{ expected, actual }) |side| {
        var run: Walk.Occurs = .begin(s.store());
        const cycle = (try run.check(s.store(), &s.stacks, s.cx.gpa, side)) orelse continue;
        return s.reportCycle(region, .none, side, cycle);
    }
    const p = problem orelse return r.mismatch(region, category, expected, actual, s.rigidOf(expected, actual));
    switch (p) {
        .kinds => |k| try r.kindMismatch(region, k.left, k.right),
        .kind_not_satisfied => |k| try r.kindNotSatisfied(region, category, k.kind, expected, actual),
        .not_equatable_rigid => |v| try r.notEquatableRigid(region, v),
        .missing_field => |f| try r.missingField(region, f.names, f.actual, f.expected),
        .unknown_field => |f| try r.unknownField(region, f.names, f.actual, f.expected),
        .record_not_closed => |f| try r.recordNotClosed(region, f.actual, f.expected),
        // §7.3: past the guard, a reported refusal and never "ok".
        // A cycle is `infinite_type`, never "nested too deep" (review B1):
        // the error path looked for one from both sides above.
        .too_deep => try r.nestingTooDeep(region, Unify.max_depth),
    }
}

/// Which side was an annotation's promise, for `rigid_mismatch`: looked for
/// through an alias, which is a name for its expansion (CK-176: `Id b` is
/// the rigid `b`, and the hint names it).
fn rigidOf(s: *Solve, expected: Var, actual: Var) ?Report.Rigid {
    const st = s.store();
    const re, const ce = st.resolved(expected);
    if (ce == .rigid) return .{ .v = re, .against = actual };
    const ra, const ca = st.resolved(actual);
    if (ca == .rigid) return .{ .v = ra, .against = expected };
    return null;
}

// ---------------------------------------------------------------------------
// Calls: checker.md §8.3, v1's rule verbatim
// ---------------------------------------------------------------------------

fn call(s: *Solve, node: Tree.Node) Error!void {
    const info = s.tree.extraData(node.a, Tree.Call);
    const scratch = s.cx.scratch;
    const args = try scratch.dupe(Var, s.tree.vars(info.args_start, info.args_len));
    defer scratch.free(args);
    const st = s.store();
    const given: u32 = @intCast(args.len);
    const arg_regions = s.argRegions(node.region);
    // The callee's instantiation row, taken HERE: the callee expression is
    // solved just before the call node and the arguments just after, so a
    // row for the callee's instruction is the last one now (round-2 S1).
    const callee_row = s.calleeRow(node.region);

    // A nullary constructor pattern: the constructor's type is the
    // pattern's. The callee must be nullary too, or §8.3's message is lost.
    if (given == 0 and st.paramCount(info.callee) == 0) {
        _ = try s.unify(info.result, info.callee, node.region, node.category);
        return;
    }

    const callee_func: Walk.Function = Walk.function(st, info.callee) orelse switch (st.resolvedContent(info.callee)) {
        .err => return,
        .flex => |flags| blk: {
            // A `number` or an `appendable` is never a function.
            if (flags.kind != .any) break :blk @as(?Walk.Function, null);
            const range = try st.addVars(args);
            const wanted = try s.fresh(.{ .structure = .{ .func = .{ .params = range, .result = info.result } } });
            _ = try s.unify(info.callee, wanted, node.region, node.category);
            return;
        },
        else => null,
    } orelse {
        if (info.flavor == .ctor_pattern) {
            try s.report.ctorPatternArity(node.region, s.report.calleeOf(node.region), 0, given);
        } else {
            try s.report.notAFunction(node.region, s.report.calleeOf(node.region), given, info.callee);
        }
        try s.poison(info.result);
        for (args) |arg| try s.poison(arg);
        return;
    };

    const params = try scratch.dupe(Var, callee_func.params);
    defer scratch.free(params);
    const arity: u32 = @intCast(params.len);
    // The arity rule comes FIRST and suppresses the generic mismatch.
    if (arity != given) {
        if (info.flavor == .ctor_pattern) {
            try s.report.ctorPatternArity(node.region, s.report.calleeOf(node.region), arity, given);
        } else if (arity > given) {
            try s.report.tooFewArgs(node.region, s.report.calleeOf(node.region), arity, given, params[given..]);
        } else {
            try s.report.tooManyArgs(node.region, s.report.calleeOf(node.region), arity, given);
        }
        try s.poison(info.result);
        for (args) |arg| try s.poison(arg);
        return;
    }

    // The arguments, stopping at the first that reports: every later
    // parameter was computed from a type the author did not mean.
    for (args, 0..) |arg, i| {
        const region = if (i < arg_regions.len) arg_regions[i] else node.region;
        const outcome = try s.unify(params[i], arg, region, .{
            .tag = .call_arg,
            .index = @intCast(i + 1),
            .owner = node.region.toOptional(),
        });
        if (outcome == .reported) {
            try s.poison(info.result);
            return;
        }
    }
    // What the arguments readied is decided before the result meets its
    // expectation (review F6.1): a method the callee's requirement finds
    // wrong is reported as that, and poisons its result, so the result's
    // mismatch — its consequence — is not reported beside it.
    if (s.readied()) try Decide.drain(s, s.frame().queue, false);
    // The variables the callee's result is made of, before a failed
    // unification poisons it (`failInstantiation`).
    var result_vars: std.ArrayList(Var) = .empty;
    defer result_vars.deinit(scratch);
    if (callee_row != null) try Walk.variables(st, &s.stacks, s.cx.gpa, scratch, callee_func.result, &result_vars);
    if (try s.unify(info.result, callee_func.result, node.region, node.category) == .reported) {
        if (callee_row) |row| try s.failInstantiation(row, result_vars.items);
    }
}

/// The index of the `inst_evidence` row of `call_inst`'s callee, if the
/// callee instantiated a scheme with requirements: read at the call node,
/// where it is the last row (the callee is solved just before).
fn calleeRow(s: *Solve, call_inst: Bir.Inst.Index) ?usize {
    const bir = s.cx.bir;
    if (call_inst.int() >= bir.insts.len or bir.instTag(call_inst) != .call) return null;
    const callee: Bir.Inst.Index = @enumFromInt(bir.instData(call_inst).lhs);
    const rows = s.evidence.inst_evidence.items;
    if (rows.len == 0 or rows[rows.len - 1].inst != callee) return null;
    return rows.len - 1;
}

/// A call whose result met its expectation with a message (review F6.1, as
/// narrowed by round 2's S1): a requirement of the callee's instantiation
/// whose method type reaches a variable of the callee's result had that
/// variable read off the same wrong result, so it is the message's
/// consequence and fails in silence (one failure, one owner). A requirement
/// that shares nothing with the result is independent and is resolved as
/// usual — its own error is still reported.
fn failInstantiation(s: *Solve, row: usize, result_vars: []const Var) Error!void {
    if (result_vars.len == 0) return;
    const st = s.store();
    for (s.evidence.argsOf(s.evidence.inst_evidence.items[row].args)) |id| {
        const w = s.evidence.get(id);
        switch (w.state) {
            .open, .ready => {},
            else => continue,
        }
        for (result_vars) |v| {
            if (!try Walk.reaches(st, &s.stacks, s.cx.gpa, w.method_type, v)) continue;
            try Resolve.reject(s, id, false);
            break;
        }
    }
}

/// A call's argument instructions, so a mismatch underlines the argument.
fn argRegions(s: *Solve, region: Bir.Inst.Index) []const Bir.Inst.Index {
    const bir = s.cx.bir;
    if (region.int() >= bir.insts.len) return &.{};
    return switch (bir.instTag(region)) {
        .call, .pat_ctor => bir.extraSlice(bir.subRange(@enumFromInt(bir.instData(region).rhs)), Bir.Inst.Index),
        .method_call => {
            const m = bir.extraData(@enumFromInt(bir.instData(region).rhs), Bir.MethodCall);
            return bir.extraSlice(.{ .start = m.args_start, .end = m.args_end }, Bir.Inst.Index);
        },
        else => &.{},
    };
}

// ---------------------------------------------------------------------------
// The boundary (§8.1)
// ---------------------------------------------------------------------------

pub fn boundary(s: *Solve, binders: []const u32, annotated: []const u32, members: ?[]const u32) Error!void {
    try s.settle();
    try s.closeFrame(binders, annotated, members);
}

/// Steps 1 to 3 of §8.1. A top-level-kind frame can be merged into one
/// below it while they run — a default readies a wanted whose resolution
/// nests a group that back-edges (§10.8) — and then stops: a merged frame
/// applies no more defaults and hands down (`Groups.solveGroup`).
pub fn settle(s: *Solve) Error!void {
    const gpa = s.cx.gpa;
    const rank = s.frame().rank;
    while (true) {
        // 1. Settle: the last drain. No default is applied here.
        try Decide.drain(s, s.frame().queue, true);
        if (s.frame().merged) return;
        // 2. Adjust ranks without quantifying: from here a variable's rank
        // says whether it escapes this frame.
        try Generalize.adjustRanks(s.store(), &s.stacks, gpa, s.cx.scratch, &s.frame().pool, rank, true);
        // 3. Defaults (§8.6): back to 1 when one was applied or anything was
        // readied, which a default makes happen. It terminates: a default
        // decides its obligation, and there are finitely many.
        if (!try Decide.defaults(s, rank)) break;
    }
}

/// Steps 4 to 7 of §8.1, over `members` at the top level (null at a `let`):
/// the group's own members and every one merged into it, read AFTER
/// `settle`, which can merge more (§10.8).
pub fn closeFrame(s: *Solve, binders: []const u32, annotated: []const u32, members: ?[]const u32) Error!void {
    const top = members != null;
    const gpa = s.cx.gpa;
    const rank = s.frame().rank;
    // 4. Occurs over the binders — patterns and parameters first, so a
    // cycle one carries is named by it, then headers; a lambda's or a
    // branch's were checked by its `binders_end`. Only binders: Elm's
    // placement, §18's fallback (*As built by R4b*).
    var run: Walk.Occurs = .begin(s.store());
    // The whole run stamps what it proves (CK-93): a header walk may stop at
    // a node a pattern's walk blackened, whose variables must be stamped too.
    run.proves = true;
    run.limit = Unify.max_depth;
    if (s.frame().inherited != null) {
        try Groups.occursMerged(s, &run, binders);
    } else {
        for (binders) |i| {
            const b = s.tree.binders.items[i];
            if (b.kind == .pattern) try s.occursBinder(&run, b);
        }
        for (binders) |i| {
            const b = s.tree.binders.items[i];
            if (b.kind == .header) try s.occursBinder(&run, b);
        }
    }
    // ... and from every wanted and obligation riding on the frame's pool
    // (§8.1 step 4 as R4b's review restated it, S4): a cycle closed through
    // a requirement no binder reaches.
    const f = s.frame();
    const requirements = s.evidence.wanteds.items.len != f.wanteds_start or s.obligations.rows.items.len != f.rows_start;
    if (requirements) try s.occursRequirements(&run);
    // 5. Quantify. At a `let`, what §8.4 *As built by R14* does not
    // generalise (D5: no function binding reaches it, a value binding does,
    // or only dot-calls ride on it) stays at the enclosing rank, with its
    // method types (I15).
    if (!top and requirements) try Resolve.holdLet(s, rank, binders);
    s.carriers.clearRetainingCapacity();
    s.resolver.wanters.clearRetainingCapacity();
    s.generalisations += try Generalize.quantify(s.store(), gpa, s.frames.items, rank, &s.carriers, &s.resolver.wanters);
    // 6. The generality check.
    for (annotated) |i| try Generalize.generality(s, s.tree.annotated.items[i], top);
    // 7. Close what rides on a quantified variable (§8.5). What rides on an
    // escaped one stays attached to it (I3). At the top level, promotion and
    // the proven-undetermined default (§9.4).
    try Decide.close(s);
    // A `let` function binding's own requirements are promoted to it (D5).
    if (!top and s.resolver.wanters.items.len != 0) try Resolve.closeLet(s, binders);
    if (members) |m| {
        if (s.resolver.wanters.items.len != 0) {
            // Step 7 unifies nothing in R6a: a default answers `undetermined`, a
            // promotion `promoted` (§8.1 *As built by R6a*, the restated assert),
            // reported in a release build too (review S8).
            const before = s.unifier.unifications;
            try Resolve.close(s, m);
            const region: Bir.Inst.Index = if (m.len != 0) s.cx.bir.decls[m[0]].body.unwrap() orelse @enumFromInt(0) else @enumFromInt(0);
            _ = try s.expect(s.unifier.unifications == before, region, "step 7 of a top-level boundary unified (checker-v2.md §8.1 *As built by R6a*)");
        }
    }
}

/// §8.1 step 4's second half: an occurs check from the method type of every
/// wanted, and every variable of every open obligation, riding on the
/// frame's pool. A cycle is `infinite_type` at the wanted's origin (the
/// obligation's region), drawn as its structure, and poisoned.
fn occursRequirements(s: *Solve, run: *Walk.Occurs) Error!void {
    const st = s.store();
    for (s.frame().pool.items) |v| {
        if (st.find(v) != v) continue;
        const flags = switch (st.content(v)) {
            .flex => |f| f,
            else => continue,
        };
        const set = Walk.constraints(flags);
        const n = set.count(st);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const c = set.at(st, i);
            if (try run.check(st, &s.stacks, s.cx.gpa, c.fn_var) == null) continue;
            const id = s.evidence.slotAt(Evidence.position(st, set.set, i)).asWanted();
            const region = if (id) |w| s.evidence.get(w).origin else c.region;
            try s.reportCycle(region, .none, c.fn_var, null);
            run.restart(st);
        }
        for (s.obligations.members(flags.obls)) |o| {
            const row = s.obligations.row(o);
            if (row.state != .open) continue;
            for (row.vars) |x| {
                if (try run.check(st, &s.stacks, s.cx.gpa, x) == null) continue;
                try s.reportCycle(row.region, .none, x, null);
                run.restart(st);
            }
        }
    }
}

/// §8.2: an occurs check from one binder; a cycle is reported at the
/// binder, drawn as its structure, and its node poisoned.
///
/// A boundary's run is bounded by `Unify.max_depth` (checker-v2.md
/// §7.3): a binder whose type is deeper is `nesting_too_deep` at
/// the binder, and poisoned, so no use copies it again. A chain of bindings
/// each one deeper than the last (`x2 = Just x1`) otherwise copied and
/// walked its whole type at every link, quadratic in time and in memory.
pub fn occursBinder(s: *Solve, run: *Walk.Occurs, b: Generalize.Binder) Error!void {
    const found = try run.check(s.store(), &s.stacks, s.cx.gpa, b.v);
    if (run.too_deep) {
        // A type that holds a poisoned part grew from a binding already
        // refused (the next links of the chain): its consequence, poisoned
        // in silence, as a cycle through one is (`reportCycle`).
        if (try Walk.hasError(s.store(), &s.stacks, s.cx.gpa, b.v) == .clean) {
            if (b.decl) |d| s.report.at(d);
            try Messages.inferredTooDeep(s.report, b.region, b.name, run.limit);
        }
        try s.poison(b.v);
        run.restart(s.store());
        return;
    }
    _ = found orelse return;
    if (b.decl) |d| s.report.at(d);
    try s.reportCycle(b.region, b.name, b.v, null);
    run.restart(s.store());
}

/// One `infinite_type` for the cycles reachable from `from`, at `region`
/// (§8.2, as amended by R4b's review):
///
///   - the cycle drawn is the one a search in field-NAME order meets first
///     (S5, I13), not whichever the store's symbol order reaches;
///   - a cycle whose drawing would show a poisoned node (`?`) is a
///     consequence of a message already given, and is poisoned silently
///     (F4);
///   - then EVERY cycle reachable from `from` is poisoned, not only the one
///     drawn, so no use of the binder meets another and reports again (F3).
pub fn reportCycle(s: *Solve, region: Bir.Inst.Index, name: Tree.Symbol.Optional, from: Var, found: ?Var) Error!void {
    const st = s.store();
    const gpa = s.cx.gpa;
    const cycle = (try Walk.firstCycle(st, &s.stacks, gpa, s.cx.interner, from)) orelse found orelse return;
    if (try Walk.hasError(st, &s.stacks, gpa, cycle) == .clean) {
        try Messages.infiniteType(s.report, region, name, cycle);
    }
    try s.poison(cycle);
    while (try Walk.firstCycle(st, &s.stacks, gpa, s.cx.interner, from)) |more| try s.poison(more);
}
