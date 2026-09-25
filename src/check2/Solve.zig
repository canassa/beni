//! The solver (checker-v2.md §6.1, §7, §8.1–§8.3): one walk over a binding
//! group's constraint tree, the arity suite of `checker.md` §8.3, and the
//! boundary of every frame.
//!
//! **A frame is pushed for every boundary** (§8.1): the top-level group's,
//! and one per `let` group. At its boundary, in this order (I16):
//!
//!   1. settle — drain the frame's `ready` queue (empty until R6a);
//!   2. adjust ranks over the young pool (`Generalize.adjustRanks`, `owned`);
//!   3. defaults — R5's (`?`), skipped;
//!   4. occurs over the frame's binders — parameters and pattern variables,
//!      then headers — one run of shared epochs (`Walk.Occurs`,
//!      `structural`): a cycle is `infinite_type` at the binder and its node
//!      is poisoned (§8.2, CK-04, CK-57). No `touched` walk: §18's fallback;
//!   5. quantify what is still at the young rank;
//!   6. check every annotated binding's rigids (§8.3, I1): still rigid, and
//!      generalised — an escaped one is `rigid_mismatch` at its first
//!      capture (CK-01), and the binding's scheme is poisoned;
//!   7. close — nothing rides on a variable in R4b;
//!   8. pop.
//!
//! **Errors never stop the build.** A failed unification reports once and
//! poisons both sides (research/02 §6), and a second bad argument to the
//! same call is poisoned quietly (v1's `last_bad_call`).
//!
//! The solver reads no generation-time context (I11): every reference was
//! resolved to a variable by the generator, or names an instruction whose
//! type `Instantiate.reference` reads from the Bir or an interface.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Context = @import("Context.zig");
const Generalize = @import("Generalize.zig");
const Instantiate = @import("Instantiate.zig");
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
/// The call whose arguments already produced a message (v1's rule).
last_bad_call: Bir.Inst.OptionalIndex = .none,
depth: u32 = 0,
generalisations: u64 = 0,

/// In place: the unifier and instantiator point at `s`'s own lists.
pub fn init(s: *Solve, cx: *const Context, report: *Report) void {
    s.* = .{ .cx = cx, .report = report };
    s.unifier = .{
        .store = cx.store,
        .types = cx.types,
        .interner = cx.interner,
        .gpa = cx.gpa,
        .scratch = cx.scratch,
        .frames = &s.frames,
        .captures = &s.captures,
    };
    s.instantiate = .{ .cx = cx, .frames = &s.frames, .stacks = &s.stacks };
}

pub fn deinit(s: *Solve) void {
    for (s.frames.items) |*f| f.deinit(s.cx.gpa);
    s.frames.deinit(s.cx.gpa);
    s.captures.deinit(s.cx.gpa);
    s.stacks.deinit(s.cx.gpa);
    s.instantiate.deinit();
    s.unifier.deinit();
}

fn store(s: *const Solve) *TypeStore {
    return s.cx.store;
}

fn frame(s: *Solve) *Frame {
    return &s.frames.items[s.frames.items.len - 1];
}

fn fresh(s: *Solve, content: TypeStore.Content) Error!Var {
    const f = s.frame();
    const v = try s.store().fresh(content, f.rank);
    try f.pool.append(s.cx.gpa, v);
    return v;
}

fn poison(s: *Solve, v: Var) void {
    s.store().setContent(s.store().find(v), .err);
}

// ---------------------------------------------------------------------------
// A top-level group
// ---------------------------------------------------------------------------

/// What the generator produced for one top-level group.
pub const Group = struct {
    tree: *const Tree.Tree,
    root: Constraint,
    /// The group's young pool, its binders (`tree.binders` indices) and its
    /// annotated bindings (`tree.annotated` indices).
    pool: []const Var,
    binders: []const u32,
    annotated: []const u32,
    /// The members, for the failure rule of §15.2.
    members: []const u32,
};

/// Solve one top-level group at rank `outermost` and close its boundary.
pub fn group(s: *Solve, g: Group) Error!void {
    s.tree = g.tree;
    try s.push(TypeStore.outermost);
    try s.frame().pool.appendSlice(s.cx.gpa, g.pool);
    try s.solve(g.root);
    try s.boundary(g.binders, g.annotated, true);
    s.pop();
    s.report.failGroup(g.members);
    s.report.at(null);
    // A capture names a variable of this group; none can explain an escape
    // in a later one (review N1).
    s.captures.clearRetainingCapacity();
}

fn push(s: *Solve, rank: u32) Error!void {
    // `Generalize.quantify` hands an escaped variable to `frames[rank - 1]`:
    // a frame's rank is its depth (review N4).
    std.debug.assert(rank == s.frames.items.len + 1);
    try s.frames.append(s.cx.gpa, .{ .rank = rank, .captures_start = @intCast(s.captures.items.len) });
}

fn pop(s: *Solve) void {
    var f = s.frames.pop().?;
    f.deinit(s.cx.gpa);
}

// ---------------------------------------------------------------------------
// The walk
// ---------------------------------------------------------------------------

fn solve(s: *Solve, first: Constraint) Error!void {
    if (first == .none) return;
    s.depth += 1;
    defer s.depth -= 1;
    // The parser bounds how deep one declaration's expressions nest, and a
    // `let`'s groups are a TAIL chain the loop below walks without
    // recursing, so an accepted file cannot reach this. If one ever does it
    // says so (I4): v1 returned here in silence, and a `let` of 5 000
    // bindings lost its last constraints and published a wrong scheme
    // (CK-91).
    if (s.depth > Tree.Generator.max_depth) {
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
                const copy = try s.instantiate.copy(@enumFromInt(node.b));
                _ = try s.unify(@enumFromInt(node.a), copy, node.region, node.category);
            },
            .reference => {
                const target: Var = @enumFromInt(node.a);
                if (try s.instantiate.reference(node.region)) |scheme| {
                    const copy = try s.instantiate.copy(scheme);
                    _ = try s.unify(target, copy, node.region, node.category);
                } else s.poison(target);
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
            },
            .internal => {
                s.poison(@enumFromInt(node.a));
                try s.report.internal(node.region, "checker v2 met a form its subset excludes; the subset gate (checker-v2.md §5, *As built by R4b*) should have refused this module");
            },
        }
    }
}

/// `CLet`: a frame one rank in for the header, and its boundary. Returns the
/// body, which the caller solves as its tail at the enclosing rank.
fn let_(s: *Solve, node: Tree.Node) Error!Constraint {
    const info = s.tree.extraData(node.a, Tree.Let);
    try s.push(info.rank);
    try s.frame().pool.appendSlice(s.cx.gpa, s.tree.vars(info.vars_start, info.vars_len));
    try s.solve(info.header_con);
    try s.boundary(s.tree.words(info.binders_start, info.binders_len), s.tree.words(info.annotated_start, info.annotated_len), false);
    s.pop();
    return info.body_con;
}

// ---------------------------------------------------------------------------
// Unification and its report
// ---------------------------------------------------------------------------

const Outcome = enum { ok, reported, suppressed };

fn unify(s: *Solve, expected: Var, actual: Var, region: Bir.Inst.Index, category: Category) Error!Outcome {
    const result = try s.unifier.unify(expected, actual, region);
    const problem = switch (result) {
        .ok => return .ok,
        .mismatch => |p| p,
    };
    const owner = if (category.tag == .call_arg) category.owner else .none;
    if (owner != .none and owner == s.last_bad_call) {
        // A second bad argument to the SAME call: poison, stay quiet.
        s.poison(expected);
        s.poison(actual);
        return .suppressed;
    }
    s.last_bad_call = owner;
    try s.reportFailure(region, category, expected, actual, problem);
    s.poison(expected);
    s.poison(actual);
    return .reported;
}

fn reportFailure(s: *Solve, region: Bir.Inst.Index, category: Category, expected: Var, actual: Var, problem: ?Unify.Problem) Error!void {
    const r = s.report;
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
        // the error path looks for one from both sides before saying the
        // source is deep.
        .too_deep => {
            for ([_]Var{ expected, actual }) |side| {
                var run: Walk.Occurs = .begin(s.store());
                const cycle = (try run.check(s.store(), &s.stacks, s.cx.gpa, side)) orelse continue;
                return s.reportCycle(region, .none, side, cycle);
            }
            try r.nestingTooDeep(region, Unify.max_depth);
        },
        .constrained => try r.internal(region, "a method constraint reached checker v2's unification, which R4b's subset excludes (checker-v2.md §5, *As built by R4b*)"),
    }
}

/// Which side was an annotation's promise, for `rigid_mismatch`.
fn rigidOf(s: *Solve, expected: Var, actual: Var) ?Report.Rigid {
    const st = s.store();
    if (st.content(st.find(expected)) == .rigid) return .{ .v = expected, .against = actual };
    if (st.content(st.find(actual)) == .rigid) return .{ .v = actual, .against = expected };
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
        s.poison(info.result);
        for (args) |arg| s.poison(arg);
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
        s.poison(info.result);
        for (args) |arg| s.poison(arg);
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
            s.poison(info.result);
            return;
        }
    }
    _ = try s.unify(info.result, callee_func.result, node.region, node.category);
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

fn boundary(s: *Solve, binders: []const u32, annotated: []const u32, top: bool) Error!void {
    const gpa = s.cx.gpa;
    const f = s.frame();
    // 1. Settle: nothing is readied in R4b (§9.1 arrives with R6a).
    std.debug.assert(f.ready.items.len == 0);
    // 2. Adjust ranks without quantifying.
    try Generalize.adjustRanks(s.store(), &s.stacks, gpa, s.cx.scratch, f.pool.items, f.rank);
    // 3. Defaults: R5 (`?`).
    // 4. Occurs over the binders — patterns and parameters first, so a
    // cycle one carries is named by it, then headers; a lambda's or a
    // branch's were checked by its `binders_end`. Only binders: Elm's
    // placement, §18's fallback (*As built by R4b*).
    var run: Walk.Occurs = .begin(s.store());
    for (binders) |i| {
        const b = s.tree.binders.items[i];
        if (b.kind == .pattern) try s.occursBinder(&run, b);
    }
    for (binders) |i| {
        const b = s.tree.binders.items[i];
        if (b.kind == .header) try s.occursBinder(&run, b);
    }
    // 5. Quantify.
    s.generalisations += try Generalize.quantify(s.store(), gpa, s.frames.items, s.frame().rank);
    // 6. The generality check.
    for (annotated) |i| try s.generality(s.tree.annotated.items[i], top);
    // 7. Close: no wanted or obligation rides on a variable in R4b.
}

/// §8.2: an occurs check from one binder; a cycle is reported at the
/// binder, drawn as its structure, and its node poisoned.
fn occursBinder(s: *Solve, run: *Walk.Occurs, b: Generalize.Binder) Error!void {
    _ = (try run.check(s.store(), &s.stacks, s.cx.gpa, b.v)) orelse return;
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
fn reportCycle(s: *Solve, region: Bir.Inst.Index, name: Tree.Symbol.Optional, from: Var, found: ?Var) Error!void {
    const st = s.store();
    const gpa = s.cx.gpa;
    const cycle = (try Walk.firstCycle(st, &s.stacks, gpa, s.cx.interner, from)) orelse found orelse return;
    if (try Walk.hasError(st, &s.stacks, gpa, cycle) == .clean) {
        try s.report.infiniteType(region, name, cycle);
    }
    s.poison(cycle);
    while (try Walk.firstCycle(st, &s.stacks, gpa, s.cx.interner, from)) |more| s.poison(more);
}

/// §8.3 (I1): every rigid of an annotated binding's checked reading must
/// still be a rigid root, and generalised. One message per binding.
fn generality(s: *Solve, a: Generalize.Annotated, top: bool) Error!void {
    const st = s.store();
    s.report.at(a.decl);
    const rigids = s.tree.vars(a.rigids_start, a.rigids_len);
    for (rigids, 0..) |r, i| {
        const root = st.find(r);
        switch (st.content(root)) {
            // Already reported where it was poisoned.
            .err => continue,
            .rigid => {},
            else => return s.report.internal(a.annotation, "an annotation's type variable stopped being rigid (checker-v2.md §8.3, invariant I1)"),
        }
        for (rigids[0..i]) |other| {
            if (st.find(other) == root) return s.report.internal(a.annotation, "two type variables of one annotation became one (checker-v2.md §8.3, invariant I1)");
        }
        if (st.rank(root) == TypeStore.generalized) continue;
        // A top-level rigid has nothing to escape into (§8.3): a failure is
        // the compiler's.
        if (top) return s.report.internal(a.annotation, "a top-level annotation's type variable was not generalised (checker-v2.md §8.3, invariant I1)");
        const region = try s.captureOf(root) orelse a.annotation;
        const enclosing = s.cx.bir.symbol(s.cx.bir.decls[a.decl].name);
        try s.report.escape(region, a.name, enclosing, a.scheme, root);
        // The scheme, so callers are not held to the false promise, and the
        // rigid itself, so what the body tied it to (a lambda parameter, say)
        // adds no second message about `a` outside `g` (F5).
        s.poison(a.scheme);
        s.poison(root);
        return;
    }
}

/// The first capture since the current frame was pushed whose node is the
/// escaped rigid or reaches it (§7.1, *As built by R4b*).
fn captureOf(s: *Solve, rigid: Var) Error!?Bir.Inst.Index {
    const start = s.frame().captures_start;
    for (s.captures.items[start..]) |c| {
        if (try Walk.reaches(s.store(), &s.stacks, s.cx.gpa, c.v, rigid)) return c.region;
    }
    return null;
}
