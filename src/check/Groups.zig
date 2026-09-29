//! Binding groups, their effective status, and own methods without a scheme
//! (checker-v2.md §4.4, §10): nesting at demand, the in-flight link and the
//! merge of top-level groups on a back-edge.
//!
//! **The groups are the SCCs of P4** (`Module.bindingGroups`: top-level
//! values over `refs`, dependencies first). Each has a status — `unchecked`,
//! `checking`, `done` — and a union-find parent after a merge; its
//! **effective status** is its root's (§4.4), so a group merged into a root
//! that is `done` reads `done`.
//!
//! **Nesting at demand** (§10.2). A use that needs an unannotated own
//! declaration whose group is `unchecked` — a method call resolved to it, a
//! value reference from a group checked out of SCC order, a derived query
//! that reads its capability — checks that group at once (`check`), in a
//! fresh top-level-kind frame one rank above every open frame, and continues
//! at the same solving step with its scheme. An annotated declaration is
//! never a demand: its scheme is P2's (§6.6).
//!
//! **Back-edges merge** (§10.4). A demand on a group that is `checking`
//! lower on the stack than the current top-level-kind frame closes a cycle
//! of demands (per-frame queues keep the stack a demand chain, §9.1), so
//! every top-level-kind frame above that group's frame is merged into it:
//! each runs steps 1 and 2 of §8.1 at its end and hands its pool, binders,
//! open-`?` list, members and queue down to the root's frame (`handDown`),
//! which generalises them together. `let` frames never merge. The use takes
//! the in-flight link (§10.3): the member's own variable, no instantiation.
//!
//! **Nesting is bounded** (§10.2): one budget of two
//! declarations' worth for the whole stack, `nest_cost` charged per nested
//! check, and a check admitted only when one declaration's worth is left;
//! otherwise `nesting_too_deep` at the demanding use, with the hint to
//! annotate the method (`Messages.nestingAtDemand`).
//!
//! Everything here is per module and single-threaded, and every choice is by
//! SCC index, stack position or source order (rule 5).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Profile = @import("../Profile.zig");
const Scc = @import("Scc.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Context = @import("Context.zig");
const Decide = @import("Decide.zig");
const Generalize = @import("Generalize.zig");
const Messages = @import("Messages.zig");
const Recursion = @import("Recursion.zig");
const Resolve = @import("Resolve.zig");
const Solve = @import("Solve.zig");
const Walk = @import("Walk.zig");
const Tree = @import("constrain/Tree.zig");
const Decl = @import("constrain/Decl.zig");

const Groups = @This();

pub const Var = TypeStore.Var;
pub const Error = Allocator.Error;

pub const Status = enum(u8) { unchecked, checking, done };

/// What a use of an own declaration gets (§6.6, §10): the scheme to
/// instantiate, the in-flight variable to share (§10.3), or nothing: `refused`
/// when the nesting budget refused the check and the use was reported
/// (§10.2); `missing` when the declaration has no type at all (its
/// annotation or body could not be read, already reported), which poisons
/// in silence.
pub const Demand = union(enum) { scheme: Var, in_flight: Var, refused, missing };

pub const none = std.math.maxInt(u32);

/// One declaration's worth of nesting (§10.2): the generator's and the
/// solver's per-declaration guard, `Parse.max_depth + 104`, in the solver's
/// depth units (`Solve.depth`, one per nested constraint).
pub const declaration_worth: u32 = Tree.Generator.max_depth;

/// The budget of the whole frame stack (§10.2): two declarations' worth.
/// What is charged against it is the solver's depth, summed over every open
/// group (`Solve.depth` is not reset by a nested check), plus `nest_cost` per
/// nested check; a nested check is admitted only with one declaration's
/// worth left over, for its own generation and solving.
pub const budget: u32 = 2 * declaration_worth;

/// What one nested check charges against `budget`, in solver depth units.
/// **Calibrated once, in a Debug build** (2026-09-26), where frames are
/// largest, and never measured at run time, so Debug and ReleaseFast refuse
/// the same programs (§10.2):
///
///   - one solver depth unit costs at most 2 528 bytes of native stack (a
///     `let` chain, `solve` → `let_` → `solve`; 2 048 through `and_`);
///   - one level of resolution recursing into a derived shape's positions
///     (`Resolve.position`, counted in `Solve.resolve_depth`) costs 2 496
///     bytes: one unit;
///   - one nesting in a reverse-ordered chain of own methods costs 15 552
///     bytes, of which 4 depth units (10 112 bytes at most) are the method
///     body's own nodes, which `Solve.depth` already counts;
///   - the rest, 7 360 bytes — resolution, the module rule, `demand`,
///     `check`, the generator's and the solver's entry frames — is 2.9
///     units: 3.
///
/// So the charged total bounds the demanders' stack at about 4 200 × 2 528
/// bytes ≈ 10.6 MB, and the admitted group has the rest of `Check.stack_size`
/// (64 MiB) for itself.
pub const nest_cost: u32 = 3;

/// `order[starts[g]..starts[g + 1]]` is group `g`'s members.
order: []const u32,
starts: []const u32,
/// Per declaration, its group; `none` for a declaration in no group.
group_of: []u32,
status: []Status,
/// Per group while `checking`: its frame's index on the solver's stack.
frame_of: []u32,
/// The union-find parent of a merged group (§10.4); `none` for a root.
merged_into: []u32,
/// Checks in progress: the level the next one's tree is taken from
/// (`Retained.level`).
active: u32 = 0,

// What a check writes besides the solver's state (Module's tables).
cx: *const Context,
local_type: []Var.Optional,
decl_scheme: []Var.Optional,
decl_display: []Var.Optional,
profile: ?*Profile = null,
/// Nanoseconds spent generating constraints, nested checks included.
constrain_ns: u64 = 0,
/// Mismatches made by the canonical pessimism of recursive groups (§10.7),
/// whose hint waits for their class to be final
/// (`Recursion.note`, `Recursion.finish`).
hints: std.ArrayList(Recursion.Pending) = .empty,

pub fn init(cx: *const Context, sccs: Scc.IndexGroups, local_type: []Var.Optional, decl_scheme: []Var.Optional, decl_display: []Var.Optional) Error!Groups {
    const scratch = cx.scratch;
    const n = sccs.starts.len - 1;
    const group_of = try scratch.alloc(u32, cx.bir.decls.len);
    @memset(group_of, none);
    for (0..n) |g| {
        for (sccs.order[sccs.starts[g]..sccs.starts[g + 1]]) |d| group_of[d] = @intCast(g);
    }
    const status = try scratch.alloc(Status, n);
    @memset(status, .unchecked);
    const frame_of = try scratch.alloc(u32, n);
    @memset(frame_of, none);
    const merged_into = try scratch.alloc(u32, n);
    @memset(merged_into, none);
    return .{
        .order = sccs.order,
        .starts = sccs.starts,
        .group_of = group_of,
        .status = status,
        .frame_of = frame_of,
        .merged_into = merged_into,
        .cx = cx,
        .local_type = local_type,
        .decl_scheme = decl_scheme,
        .decl_display = decl_display,
    };
}

pub fn deinit(gs: *Groups) void {
    gs.hints.deinit(gs.cx.gpa);
}

pub fn count(gs: *const Groups) u32 {
    return @intCast(gs.starts.len - 1);
}

pub fn members(gs: *const Groups, g: u32) []const u32 {
    return gs.order[gs.starts[g]..gs.starts[g + 1]];
}

/// The root of `g`'s merge class (§4.4), with path halving.
pub fn root(gs: *Groups, g: u32) u32 {
    var at = g;
    while (gs.merged_into[at] != none) {
        const parent = gs.merged_into[at];
        if (gs.merged_into[parent] != none) gs.merged_into[at] = gs.merged_into[parent];
        at = parent;
    }
    return at;
}

/// `decl`'s group's effective status; `done` for a declaration in no group.
pub fn statusOf(gs: *Groups, decl: u32) Status {
    if (decl >= gs.group_of.len or gs.group_of[decl] == none) return .done;
    return gs.status[gs.root(gs.group_of[decl])];
}

/// Whether a use of `decl` from the group being generated, `current`, must
/// be resolved at solving time (`Tree.Node.Tag.demand`): an unannotated
/// value or a schema of another group that is not `done` yet. Only a group
/// checked out of SCC order — nested — ever generates one.
pub fn demands(gs: *Groups, decl: u32, current: u32) bool {
    if (decl >= gs.group_of.len) return false;
    const g = gs.group_of[decl];
    if (g == none or g == current or gs.status[gs.root(g)] == .done) return false;
    const d = &gs.cx.bir.decls[decl];
    return !(d.kind.isValue() and d.annotation != .none);
}

// ---------------------------------------------------------------------------
// P4: every group, in SCC order
// ---------------------------------------------------------------------------

/// P4 (§5): check every group still `unchecked`, dependencies first. A group
/// a demand already checked, or merged into one, is skipped.
pub fn checkAll(gs: *Groups, s: *Solve) Error!void {
    for (0..gs.count()) |g| {
        if (gs.status[gs.root(@intCast(g))] != .unchecked) continue;
        _ = try gs.check(s, @intCast(g));
    }
}

/// Generate and solve group `g` in a fresh top-level-kind frame (§10.2's
/// `checkGroup`): `done` when its boundary generalised it (and every group
/// merged into it), `merged` when a back-edge merged it into a group lower
/// on the stack, which will.
pub fn check(gs: *Groups, s: *Solve, g: u32) Error!Ended {
    const cx = gs.cx;
    const gpa = cx.gpa;
    const scratch = cx.scratch;
    const level = gs.active;
    gs.active += 1;
    defer gs.active -= 1;
    // The tree and the generator's lists are this nesting level's, the
    // worker's (`Retained`): a nested group's are needed only while it is
    // checked, and nested checks finish innermost first.
    const lists = try s.retained.level(gpa, level);
    const tree = &lists.tree;

    const indices = gs.members(g);
    const dm = try scratch.alloc(Decl.Member, indices.len);
    defer scratch.free(dm);
    for (dm, indices) |*m, i| m.* = .{ .decl = i, .check = .none };

    // The group is `checking` from its generation on: a member's variable
    // exists from the moment `Decl.group` declares it.
    gs.status[g] = .checking;
    var gen: Tree.Generator = .{
        .cx = cx,
        .tree = tree,
        .gpa = gpa,
        .rank = @intCast(s.frames.items.len + 1),
        .local_type = gs.local_type,
        .decl_scheme = gs.decl_scheme,
        .evidence = &s.evidence,
        .groups = gs,
        .group = g,
        .pool = lists.pool,
        .frame_binders = lists.frame_binders,
        .frame_annotated = lists.frame_annotated,
        .targets = lists.targets,
    };
    lists.pool = .empty;
    lists.frame_binders = .empty;
    lists.frame_annotated = .empty;
    lists.targets = .empty;
    defer {
        gen.pool.clearRetainingCapacity();
        gen.frame_binders.clearRetainingCapacity();
        gen.frame_annotated.clearRetainingCapacity();
        gen.targets.clearRetainingCapacity();
        lists.pool = gen.pool;
        lists.frame_binders = gen.frame_binders;
        lists.frame_annotated = gen.frame_annotated;
        lists.targets = gen.targets;
    }
    const token = if (gs.profile) |p| p.begin() else null;
    const root_con = try Decl.group(&gen, dm);
    if (gs.profile) |p| gs.constrain_ns += p.since(token.?);

    var done: []const u32 = &.{};
    const ended = try solveGroup(s, .{
        .tree = tree,
        .root = root_con,
        .pool = gen.pool.items,
        .binders = gen.frame_binders.items,
        .annotated = gen.frame_annotated.items,
        .members = indices,
        .id = g,
        .recursive = indices.len > 1,
    }, &done);
    for (dm) |m| gs.decl_display[m.decl] = if (m.display != .none) m.display else m.check;
    if (ended == .merged) return .merged;

    gs.status[g] = .done;
    gs.frame_of[g] = none;
    // A derived context computed while a member was in flight is stale from
    // now on (§11.2, *Memo generations*).
    s.contexts.groupDone();
    return .done;
}

// ---------------------------------------------------------------------------
// A top-level-kind frame
// ---------------------------------------------------------------------------

/// What the generator produced for one top-level group.
pub const Group = struct {
    tree: *const Tree.Tree,
    root: Tree.Constraint,
    /// The group's young pool, its binders (`tree.binders` indices) and its
    /// annotated bindings (`tree.annotated` indices).
    pool: []const Var,
    binders: []const u32,
    annotated: []const u32,
    /// The members, for the failure rule of §15.2.
    members: []const u32,
    /// Its `Groups` index.
    id: u32,
    /// A value SCC of two or more members: the canonical pessimism of
    /// recursive groups applies from its first node
    /// (§10.7).
    recursive: bool,
};

/// How a top-level group's check ended (§10.2): generalised at its own
/// boundary, or merged into a group lower on the stack (§10.4), whose
/// boundary generalises it.
pub const Ended = enum { done, merged };

/// Solve one top-level group in a fresh top-level-kind frame one rank above
/// every open frame — rank `outermost` in SCC order, higher when nested at
/// demand (§10.2) — and close its boundary, or hand it down when a back-edge
/// merged it (§10.4). `done` receives every member the boundary generalised:
/// this group's and those merged into it. The demander's state is restored.
pub fn solveGroup(s: *Solve, g: Group, done: *[]const u32) Error!Ended {
    // A group a derived-context fixpoint nested is checked with the
    // module's own report, never the fixpoint's quiet one (§11.2).
    const saved_report = s.report;
    s.report = s.module_report;
    defer s.report = saved_report;
    const saved_tree = s.tree;
    const saved_decl = s.report.current;
    const saved_instantiate = s.instantiate.decl;
    const saved_bad = s.last_bad_call;
    const saved_base = s.depth_base;
    defer {
        s.tree = saved_tree;
        s.report.at(saved_decl);
        s.instantiate.decl = saved_instantiate;
        s.last_bad_call = saved_bad;
        s.depth_base = saved_base;
    }
    s.tree = g.tree;
    s.depth_base = s.depth;
    s.last_bad_call = .none;
    // The resolution budget is per top-level group; a nested
    // group counts against its demander's (§10.2).
    if (s.frames.items.len == 0) s.resolver.steps = 0;
    try Generalize.pushFrame(s, @intCast(s.frames.items.len + 1), .top);
    const index = s.frames.items.len - 1;
    s.frames.items[index].group = g.id;
    s.frames.items[index].recursive = g.recursive;
    if (g.recursive) s.recursive_frames += 1;
    s.groups.frame_of[g.id] = @intCast(index);
    try s.frames.items[index].pool.appendSlice(s.cx.gpa, g.pool);
    try s.solve(g.root);
    // Steps 1 to 3 first: they can merge this frame, or merge more groups
    // into it (a default's consequence nests one that back-edges, §10.8), so
    // the members are read after them.
    if (!s.frames.items[index].merged) try s.settle();
    if (s.frames.items[index].merged) {
        // An annotated declaration is a singleton SCC, never nested or merged
        // (`Module.bindingGroups` drops edges to it), so a merged frame has
        // no generality check to hand down.
        std.debug.assert(g.annotated.len == 0);
        try s.groups.handDown(s, g.binders, g.members);
        return .merged;
    }
    const inherited: []const u32 = if (s.frames.items[index].inherited) |i| i.members.items else &.{};
    // Into the per-module scratch arena, freed with it: never `free` it here.
    done.* = if (inherited.len == 0) g.members else try std.mem.concat(s.cx.scratch, u32, &.{ g.members, inherited });
    try s.closeFrame(g.binders, g.annotated, done.*);
    if (s.groups.hints.items.len != 0) try Recursion.finish(s, done.*);
    const captures_start = s.frames.items[index].captures_start;
    Generalize.popFrame(s);
    s.report.failGroup(done.*);
    // A capture names a variable of this group; none can explain an escape
    // in another.
    s.captures.shrinkRetainingCapacity(captures_start);
    return .done;
}

/// The index of the innermost top-level-kind frame: the current group's.
pub fn topFrame(s: *const Solve) u32 {
    var i = s.frames.items.len;
    while (i > 0) {
        i -= 1;
        if (s.frames.items[i].kind == .top) return @intCast(i);
    }
    unreachable;
}

/// Step 4 at the root of a merged group (§10.4): its own binders and those
/// its merged frames handed down, patterns before headers and each kind in
/// source order, so which binder names a cycle does not depend on which
/// member happened to be the root.
pub fn occursMerged(s: *Solve, run: *Walk.Occurs, binders: []const u32) Error!void {
    const scratch = s.cx.scratch;
    var all: std.ArrayList(Generalize.Binder) = .empty;
    defer all.deinit(scratch);
    for (binders) |i| try all.append(scratch, s.tree.binders.items[i]);
    if (s.frame().inherited) |i| try all.appendSlice(scratch, i.binders.items);
    std.mem.sort(Generalize.Binder, all.items, {}, binderLessThan);
    for (all.items) |b| {
        if (b.kind != .ended) try s.occursBinder(run, b);
    }
}

fn binderLessThan(_: void, a: Generalize.Binder, b: Generalize.Binder) bool {
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    if (a.region != b.region) return a.region.int() < b.region.int();
    // Ties, which binders sharing a region would be, by declaration and
    // name: a total order, so the unstable sort cannot reorder them.
    const ad = a.decl orelse std.math.maxInt(u32);
    const bd = b.decl orelse std.math.maxInt(u32);
    if (ad != bd) return ad < bd;
    return @intFromEnum(a.name) < @intFromEnum(b.name);
}

/// A `demand` node (§10.2, §10.3): a reference to a declaration of a group
/// that was not `done` when this one was generated — only a nested group
/// has one. The group is checked now if it is `unchecked`; then the
/// reference instantiates its scheme, or shares an in-flight member's
/// variable (a back-edge merges first, §10.4). A schema's reference is then
/// typed as any other (`Instantiate.reference`), which copies what is
/// generalised and shares what is in flight.
pub fn demanded(s: *Solve, node: Tree.Node) Error!void {
    const target: Var = @enumFromInt(node.a);
    const bir = s.cx.bir;
    const d = bir.decls[node.b];
    // First: a nested check uses the instantiator's state too.
    const got = try s.groups.demand(s, node.b, node.region, bir.symbol(d.name));
    if (got == .refused or got == .missing) return s.poison(target);
    s.instantiate.origin = node.region;
    s.instantiate.made.clearRetainingCapacity();
    if (d.kind == .schema) {
        const scheme = (try s.instantiate.reference(node.region)) orelse return s.poison(target);
        const copy = try s.instantiate.copy(scheme);
        try s.instantiated(node.region);
        _ = try s.unify(target, copy, node.region, node.category);
        return;
    }
    const copy = switch (got) {
        .scheme => |v| try s.instantiate.copy(v),
        .in_flight => |v| v,
        .refused, .missing => unreachable,
    };
    try s.instantiated(node.region);
    _ = try s.unify(target, copy, node.region, node.category);
}

// ---------------------------------------------------------------------------
// Demand (§10.2, §10.3)
// ---------------------------------------------------------------------------

/// What a use of own declaration `decl` at `region` gets: an annotated or
/// `done` declaration's scheme; an in-flight member's variable, merging the
/// frames above its group's when the use is a back-edge (§10.4); or, for an
/// `unchecked` group, whatever checking it now gives (§10.2). `name` is what
/// the refusal's hint says to annotate.
pub fn demand(gs: *Groups, s: *Solve, decl: u32, region: Bir.Inst.Index, name: TypeStore.Symbol) Error!Demand {
    const d = &gs.cx.bir.decls[decl];
    const annotated = d.kind.isValue() and d.annotation != .none;
    const g = if (decl < gs.group_of.len) gs.group_of[decl] else none;
    if (annotated or g == none) return schemeOf(gs, decl);
    const r = gs.root(g);
    switch (gs.status[r]) {
        .done => return schemeOf(gs, decl),
        .checking => {
            const j = gs.frame_of[r];
            if (j < topFrame(s)) gs.merge(s, j);
            return inFlight(gs, decl);
        },
        .unchecked => {
            // Admitted only with one declaration's worth left after the
            // charge (§10.2): a nested group that has started can never run
            // out inside its own walks.
            if (s.depth + s.resolve_depth + s.nest_units + nest_cost + declaration_worth > budget) {
                try Messages.nestingAtDemand(s.report, region, name);
                return .refused;
            }
            s.nest_units += nest_cost;
            defer s.nest_units -= nest_cost;
            return switch (try gs.check(s, g)) {
                .done => schemeOf(gs, decl),
                .merged => inFlight(gs, decl),
            };
        },
    }
}

fn schemeOf(gs: *Groups, decl: u32) Demand {
    const v = gs.decl_scheme[decl].unwrap() orelse return .missing;
    return .{ .scheme = v };
}

fn inFlight(gs: *Groups, decl: u32) Demand {
    const v = gs.decl_scheme[decl].unwrap() orelse return .missing;
    return .{ .in_flight = v };
}

/// Frame `j` checks a group a back-edge from the current chain reached:
/// every top-level-kind frame above it is merged into it (§10.4: a dispatch
/// back-edge merges the groups on the stack). Their groups join `j`'s class;
/// each frame keeps solving and hands down at its end. Every frame of the
/// class is now a recursive group's (§10.7).
fn merge(gs: *Groups, s: *Solve, j: u32) void {
    const frames = s.frames.items;
    const into = gs.root(frames[j].group);
    if (!frames[j].recursive) s.recursive_frames += 1;
    frames[j].recursive = true;
    for (frames[j + 1 ..]) |*f| {
        if (f.kind != .top) continue;
        if (!f.recursive) s.recursive_frames += 1;
        f.recursive = true;
        const r = gs.root(f.group);
        if (r != into) gs.merged_into[r] = into;
        f.merged = true;
    }
}

/// The end of a merged frame (§8.1, §10.4): steps 1 and 2, then its pool
/// (lowered to the root frame's rank), its binders, its open-`?` list, its
/// members and whatever its queue still holds go to the frame of its
/// group's root, whose boundary generalises them; its items route there.
/// No default, no occurs check, no quantification here. The frame is popped.
pub fn handDown(gs: *Groups, s: *Solve, binders: []const u32, own: []const u32) Error!void {
    const gpa = gs.cx.gpa;
    const st = gs.cx.store;
    const index = s.frames.items.len - 1;
    const rank = s.frames.items[index].rank;
    // 1. Settle: this frame's own queue, as any frame drains it.
    try Decide.drain(s, s.frames.items[index].queue, true);
    // 2. Adjust ranks without quantifying.
    try Generalize.adjustRanks(st, &s.stacks, gpa, gs.cx.scratch, &s.frames.items[index].pool, rank, false);

    const j = gs.frame_of[gs.root(s.frames.items[index].group)];
    std.debug.assert(j < index);
    const to_rank = s.frames.items[j].rank;
    var from = &s.frames.items[index];
    var to = &s.frames.items[j];
    for (from.pool.items) |v| try Walk.lowerTo(st, &s.stacks, gpa, v, to_rank);
    try to.pool.appendSlice(gpa, from.pool.items);
    try to.tries.appendSlice(gpa, from.tries.items);
    if (to.inherited == null) {
        const created = try gpa.create(Generalize.Frame.Inherited);
        created.* = .{};
        to.inherited = created;
    }
    const into = to.inherited.?;
    for (binders) |i| try into.binders.append(gpa, s.tree.binders.items[i]);
    try into.members.appendSlice(gpa, own);
    if (from.inherited) |mine| {
        try into.binders.appendSlice(gpa, mine.binders.items);
        try into.members.appendSlice(gpa, mine.members.items);
    }
    try Generalize.handQueueDown(s, to.queue);
    // Read only through its root from now on.
    gs.frame_of[from.group] = none;
    from = undefined;
    to = undefined;
    Generalize.popFrame(s);
}
