//! The runs that compile to a validator (`docs/design/schema.md` §6, *A run
//! whose failure is never read is a validator*). A run's error is never read
//! when the run is the scrutinee of a `case`, directly, every arm of which
//! that can match an `Err` matches it as `Err _`, or the first argument of
//! core's `Result.withDefault` or `Result.toMaybe`. Decided from the
//! program's text alone, so reachability and lowering, which both ask,
//! answer the same. Such a run is lowered in place of its own call:
//! - `Schema.read s v` calls `Schema.readValid`, or, when `s` is
//!   `S.schema ⊤` of a nongeneric declaration, is a **direct** run, which
//!   calls `S`'s validator worker where it stands, with a context of its
//!   own from `Schema.validContext` (`schema.md` §6, *A validator run calls
//!   its worker where it stands*);
//! - `Schema.parse (S.schema ⊤) text` of a nongeneric `S` is a direct run
//!   whose text `Schema.validJson` reads first; any other `parse` keeps its
//!   issues;
//! - `Json.decodeValue v` and `Json.decode text` whose evidence is a
//!   nongeneric derived codec are direct runs of the codec's validator
//!   worker.
//!
//! A run whose schema has a shape (`SchemaGraph.shapeable`) is a **shape
//! run** instead (`schema.md` §6, *A validator run is a shape that one
//! shared validator reads*): `S.schema ⊤` of a `read` or `parse`, or a
//! `Json` run's codec, written as its shape, and the run `Schema.validShape`
//! or `Schema.shapeParse` of it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");
const Dispatch = @import("../check/Dispatch.zig");
const SchemaGraph = @import("SchemaGraph.zig");
const SchemaCtor = @import("SchemaCtor.zig");

const Inst = Bir.Inst;

/// A module's validator runs. Every list of instructions is ascending.
pub const Sites = struct {
    /// The callees of the `Schema.read` and direct `Schema.parse` runs.
    callees: []const u32 = &.{},
    /// Of those, the ones whose schema is `S.schema ⊤` of a nongeneric
    /// declaration, which call `S`'s validator worker where they stand (a
    /// `parse` reading its text with `validJson`) and reach no root value of
    /// `S`; their argument calls and member instructions, with the
    /// declarations, in `args`, `members` and `refs`.
    direct_callees: []const u32 = &.{},
    /// Of the direct ones, the `parse` runs.
    parse_callees: []const u32 = &.{},
    args: []const u32 = &.{},
    members: []const u32 = &.{},
    refs: []const SchemaGraph.Ref = &.{},
    /// The calls of `Result.withDefault` and `Result.toMaybe` whose first
    /// argument is a direct run or a `Json` validator run, written with the
    /// run where it stands and never called, and their callees, which
    /// reach nothing (`schema.md` §6, *A validator run calls its worker
    /// where it stands*).
    defaults: []const u32 = &.{},
    maybes: []const u32 = &.{},
    consumer_callees: []const u32 = &.{},
    /// A `Json` validator run's call, written as a direct run of its
    /// codec's validator worker, its codec's index in this module's plan,
    /// and of those calls the `decode` ones, which parse.
    json_calls: []const u32 = &.{},
    json_codecs: []const u32 = &.{},
    json_parses: []const u32 = &.{},
    /// Their callees, `Json.decodeValue` and `Json.decode`, which are not
    /// called.
    json_callees: []const u32 = &.{},
    /// The callees of the shape runs, which call `validShape`, and of
    /// those the `parse` ones, which call `shapeParse`.
    shape_callees: []const u32 = &.{},
    shape_parses: []const u32 = &.{},
    /// A `Schema` shape run's argument call `S.schema ⊤`, written as `S`'s
    /// shape, and its member instruction, which reaches the shape alone.
    shape_args: []const u32 = &.{},
    shape_members: []const u32 = &.{},
    shape_refs: []const SchemaGraph.Ref = &.{},
    /// A `Json` shape run's call and its codec.
    shape_json: []const u32 = &.{},
    shape_codecs: []const u32 = &.{},

    /// The tags no run tells from a failure (`schema.md` §6, *A tag no
    /// run tells from a failure*, amended 2026-10-24): per declaration of
    /// this module in `dead_refs`, the orders of the variants of its root
    /// union that its validator worker and its shape read as unknown tags,
    /// ascending; and the `case` branches of those variants, which no run
    /// then reaches, ascending.
    dead_refs: []const SchemaGraph.Ref = &.{},
    dead_variants: []const []const u32 = &.{},
    dead_branches: []const u32 = &.{},

    pub fn deadVariants(s: Sites, r: SchemaGraph.Ref) []const u32 {
        for (s.dead_refs, s.dead_variants) |x, v| if (x.module == r.module and x.decl == r.decl) return v;
        return &.{};
    }

    pub fn shapeOfArg(s: Sites, inst: u32) ?SchemaGraph.Ref {
        for (s.shape_args, s.shape_refs) |a, r| if (a == inst) return r;
        return null;
    }

    pub fn shapeOfMember(s: Sites, inst: u32) ?SchemaGraph.Ref {
        for (s.shape_members, s.shape_refs) |x, r| if (x == inst) return r;
        return null;
    }

    pub fn shapeCodecOfCall(s: Sites, inst: u32) ?u32 {
        for (s.shape_json, s.shape_codecs) |x, k| if (x == inst) return k;
        return null;
    }

    /// The core-private value the callee instruction of a shape run calls.
    pub fn shapeRunner(s: Sites, inst: u32) []const u8 {
        return if (has(s.shape_parses, inst)) "shapeParse" else "validShape";
    }

    pub fn refOfArg(s: Sites, inst: u32) ?SchemaGraph.Ref {
        for (s.args, s.refs) |a, r| if (a == inst) return r;
        return null;
    }

    pub fn refOfMember(s: Sites, inst: u32) ?SchemaGraph.Ref {
        for (s.members, s.refs) |x, r| if (x == inst) return r;
        return null;
    }

    /// The codec a `Json` validator run's call reads with.
    pub fn codecOfCall(s: Sites, inst: u32) ?u32 {
        for (s.json_calls, s.json_codecs) |x, k| if (x == inst) return k;
        return null;
    }

    /// Whether two answers for one module name the same runs: what
    /// `Lower` asserts of its own answer and reachability's, which read
    /// the module's dispatch table from different places.
    pub fn sameRuns(a: Sites, b: Sites) bool {
        const eq = std.mem.eql;
        return eq(u32, a.callees, b.callees) and eq(u32, a.direct_callees, b.direct_callees) and
            eq(u32, a.parse_callees, b.parse_callees) and eq(u32, a.args, b.args) and
            eq(u32, a.members, b.members) and eq(u32, a.json_calls, b.json_calls) and
            eq(u32, a.json_codecs, b.json_codecs) and eq(u32, a.json_parses, b.json_parses) and
            eq(u32, a.json_callees, b.json_callees) and eq(u32, a.shape_callees, b.shape_callees) and
            eq(u32, a.shape_parses, b.shape_parses) and eq(u32, a.shape_args, b.shape_args) and
            eq(u32, a.shape_json, b.shape_json) and eq(u32, a.shape_codecs, b.shape_codecs) and
            eq(u32, a.defaults, b.defaults) and eq(u32, a.maybes, b.maybes) and
            eq(u32, a.consumer_callees, b.consumer_callees) and eq(u32, a.dead_branches, b.dead_branches);
    }
};

/// What a run's callee is.
const Run = enum { schema_read, schema_parse, json_read, json_parse };

/// The program's count of shape runs at and above which every shape run
/// takes its shape, and below which every one keeps its validator worker
/// (`schema.md` §6, *How a program chooses between shapes and workers*).
pub const shape_threshold = 29;

/// The shape runs `sites` finds in one module with shapes on: what a
/// program's count adds up, module by module.
pub fn shapeRunCount(s: Sites) usize {
    return s.shape_callees.len;
}

pub fn sites(
    scratch: Allocator,
    graph: *const Graph,
    interfaces: []const Interface,
    provenance: []const Interface.Provenance,
    interner: *const InternPool.Global,
    bir: *const Bir,
    dispatch: ?*const Dispatch,
    module: Graph.Index,
    sg: ?*const SchemaGraph,
    library: bool,
    /// Whether this program's shape runs take their shapes: false, and each
    /// keeps the validator worker a run with no shape keeps.
    shapes: bool,
) Allocator.Error!Sites {
    var callee_list: std.ArrayList(u32) = .empty;
    var direct: std.ArrayList(u32) = .empty;
    var parses: std.ArrayList(u32) = .empty;
    var args: std.ArrayList(u32) = .empty;
    var members: std.ArrayList(u32) = .empty;
    var refs: std.ArrayList(SchemaGraph.Ref) = .empty;
    var json_calls: std.ArrayList(u32) = .empty;
    var json_codecs: std.ArrayList(u32) = .empty;
    var json_parses: std.ArrayList(u32) = .empty;
    var json_callees: std.ArrayList(u32) = .empty;
    var shape_callees: std.ArrayList(u32) = .empty;
    var shape_parses: std.ArrayList(u32) = .empty;
    var shape_args: std.ArrayList(u32) = .empty;
    var shape_members: std.ArrayList(u32) = .empty;
    var shape_refs: std.ArrayList(SchemaGraph.Ref) = .empty;
    var shape_json: std.ArrayList(u32) = .empty;
    var shape_codecs: std.ArrayList(u32) = .empty;
    var defaults: std.ArrayList(u32) = .empty;
    var maybes: std.ArrayList(u32) = .empty;
    var consumer_callees: std.ArrayList(u32) = .empty;
    var candidates: std.ArrayList(Candidate) = .empty;
    for (0..bir.insts.len) |i| {
        const inst: Inst.Index = @fromBackingInt(@intCast(i));
        const call = unreadRun(graph, interfaces, interner, bir, inst) orelse continue;
        const callee: Inst.Index = @fromBackingInt(@intCast(bir.instData(call).lhs));
        const run = runOf(graph, interfaces, interner, bir, callee) orelse continue;
        const call_args = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(bir.instData(call).rhs))), Inst.Index);
        switch (run) {
            .json_read, .json_parse => {
                // Under `--schema-library` every run is the library's.
                if (library) continue;
                const g = sg orelse continue;
                const d = dispatch orelse continue;
                if (call_args.len != 1) continue;
                const site = d.siteOf(call) orelse continue;
                const roots = d.argsAt(site.evidence);
                if (roots.len != 1) continue;
                const k = switch (d.term(roots[0])) {
                    .codec => |use| use.index,
                    else => continue,
                };
                if (d.argsOfTerm(roots[0]).len != 0) continue;
                const def = g.definition(module, g.codecTarget(module, k).decl) orelse continue;
                if (def.params_end != def.params_start) continue;
                if (shapes and try g.shapeable(scratch, g.codecTarget(module, k))) {
                    try shape_callees.append(scratch, callee.int());
                    if (run == .json_parse) try shape_parses.append(scratch, callee.int());
                    try shape_json.append(scratch, call.int());
                    try shape_codecs.append(scratch, k);
                    continue;
                }
                try json_calls.append(scratch, call.int());
                try json_codecs.append(scratch, k);
                try json_callees.append(scratch, callee.int());
                if (run == .json_parse) try json_parses.append(scratch, call.int());
                try consumer(graph, interfaces, interner, bir, scratch, inst, &defaults, &maybes, &consumer_callees);
            },
            .schema_read, .schema_parse => {
                // The schema `S.schema ⊤` of a nongeneric declaration, read
                // by its validator worker. Under `--schema-library` no worker
                // is written: a `read` calls `readValid`, which runs the
                // schema through the library, and a `parse` keeps its own.
                const direct_ref: ?struct { u32, u32, SchemaGraph.Ref } = blk: {
                    if (library) break :blk null;
                    const g = sg orelse break :blk null;
                    if (call_args.len != 2 or bir.instTag(call_args[0]) != .call) break :blk null;
                    const arg = call_args[0];
                    const member: Inst.Index = @fromBackingInt(@intCast(bir.instData(arg).lhs));
                    const ref = schemaRoot(provenance, interfaces, bir, module, member) orelse break :blk null;
                    const def = g.definition(ref.module, ref.decl) orelse break :blk null;
                    if (def.params_end != def.params_start) break :blk null;
                    break :blk .{ arg.int(), member.int(), ref };
                };
                if (direct_ref) |r| try candidates.append(scratch, .{ .unread = inst.int(), .member = r[1], .ref = r[2] });
                if (direct_ref) |r| if (shapes and try sg.?.shapeable(scratch, r[2])) {
                    try shape_callees.append(scratch, callee.int());
                    if (run == .schema_parse) try shape_parses.append(scratch, callee.int());
                    try shape_args.append(scratch, r[0]);
                    try shape_members.append(scratch, r[1]);
                    try shape_refs.append(scratch, r[2]);
                    continue;
                };
                // A `parse` of any other schema keeps its issues.
                if (run == .schema_parse and direct_ref == null) continue;
                try callee_list.append(scratch, callee.int());
                if (direct_ref) |r| {
                    try direct.append(scratch, callee.int());
                    if (run == .schema_parse) try parses.append(scratch, callee.int());
                    try args.append(scratch, r[0]);
                    try members.append(scratch, r[1]);
                    try refs.append(scratch, r[2]);
                    try consumer(graph, interfaces, interner, bir, scratch, inst, &defaults, &maybes, &consumer_callees);
                }
            },
        }
    }
    std.mem.sort(u32, callee_list.items, {}, std.sort.asc(u32));
    std.mem.sort(u32, direct.items, {}, std.sort.asc(u32));
    std.mem.sort(u32, parses.items, {}, std.sort.asc(u32));
    std.mem.sort(u32, json_parses.items, {}, std.sort.asc(u32));
    std.mem.sort(u32, json_callees.items, {}, std.sort.asc(u32));
    std.mem.sort(u32, shape_callees.items, {}, std.sort.asc(u32));
    std.mem.sort(u32, shape_parses.items, {}, std.sort.asc(u32));
    std.mem.sort(u32, consumer_callees.items, {}, std.sort.asc(u32));
    const dead = if (sg) |g| try deadTags(scratch, graph, interner, interfaces, provenance, bir, g, module, candidates.items) else Dead{};
    return .{
        .dead_refs = dead.refs,
        .dead_variants = dead.variants,
        .dead_branches = dead.branches,
        .defaults = defaults.items,
        .maybes = maybes.items,
        .consumer_callees = consumer_callees.items,
        .callees = callee_list.items,
        .direct_callees = direct.items,
        .parse_callees = parses.items,
        .args = args.items,
        .members = members.items,
        .refs = refs.items,
        .json_calls = json_calls.items,
        .json_codecs = json_codecs.items,
        .json_parses = json_parses.items,
        .json_callees = json_callees.items,
        .shape_callees = shape_callees.items,
        .shape_parses = shape_parses.items,
        .shape_args = shape_args.items,
        .shape_members = shape_members.items,
        .shape_refs = shape_refs.items,
        .shape_json = shape_json.items,
        .shape_codecs = shape_codecs.items,
    };
}

/// A direct run of a declaration's schema and the instruction its result
/// goes to unread: a \`case\`, or a call of \`Result.withDefault\` or
/// \`Result.toMaybe\`.
const Candidate = struct { unread: u32, member: u32, ref: SchemaGraph.Ref };

const Dead = struct {
    refs: []const SchemaGraph.Ref = &.{},
    variants: []const []const u32 = &.{},
    branches: []const u32 = &.{},
};

/// The tags no run tells from a failure (`schema.md` §6, amended
/// 2026-10-24). A declaration of this module qualifies when the module
/// does not expose it, no other schema of the module and no derived codec
/// refers to it, it does not refer to itself, its root is a tagged union,
/// and every instruction that names one of its members is the schema
/// argument of a direct run whose result is a `case`'s scrutinee. A
/// variant is dead when, at every one of those `case`s, its first and only
/// arm is `Ok (S.V …)` with no pattern but names and `_` inside, ahead of
/// any arm that could match it otherwise, and that arm's body is the very
/// reference the `Err _` arm's body is — the same local or top-level value.
/// Reading such a tag as unknown makes the run fail, and the failure's arm
/// gives the same value the variant's arm would have: nothing the program
/// does changes.
fn deadTags(
    scratch: Allocator,
    graph: *const Graph,
    interner: *const InternPool.Global,
    interfaces: []const Interface,
    provenance: []const Interface.Provenance,
    bir: *const Bir,
    g: *const SchemaGraph,
    module: Graph.Index,
    candidates: []const Candidate,
) Allocator.Error!Dead {
    const cx: Cx = .{ .graph = graph, .interfaces = interfaces, .interner = interner, .bir = bir, .module = module };
    var refs: std.ArrayList(SchemaGraph.Ref) = .empty;
    var variants: std.ArrayList([]const u32) = .empty;
    var branches: std.ArrayList(u32) = .empty;
    for (candidates, 0..) |c, ci| {
        const r = c.ref;
        if (r.module != module) continue;
        // Each declaration once, at its first run.
        const first = for (candidates[0..ci]) |e| {
            if (e.ref.module == r.module and e.ref.decl == r.decl) break false;
        } else true;
        if (!first) continue;
        if (exposed(interfaces, provenance, module, r.decl)) continue;
        if (g.codecIndex(module, r.decl) != null) continue;
        if (try g.recursive(scratch, module, r.decl)) continue;
        const plan = g.planOf(module);
        const def = g.definition(module, r.decl) orelse continue;
        if (SchemaGraph.tag(plan, def.root) != .tagged) continue;
        const referred = for (plan.definitions) |other| {
            const od = @backingInt(other.decl);
            if (od != r.decl and try g.reaches(scratch, module, od, r.decl)) break true;
        } else false;
        if (referred) continue;
        // Every member reference is one of the runs, and each run's result
        // goes to a `case`.
        const only_runs = for (0..bir.insts.len) |i| {
            if (bir.instTag(@fromBackingInt(@intCast(i))) != .schema_member_top) continue;
            if (bir.instData(@fromBackingInt(@intCast(i))).lhs != r.decl) continue;
            const run = for (candidates) |e| {
                if (e.member == i) break e;
            } else break false;
            if (bir.instTag(@fromBackingInt(@intCast(run.unread))) != .case) break false;
        } else true;
        if (!only_runs) continue;
        const count = SchemaGraph.variants(plan, def.root).len;
        // The variants dead at every `case`, by order.
        const alive = try scratch.alloc(bool, count);
        @memset(alive, false);
        const arms = try scratch.alloc(?u32, count);
        var site_branches: std.ArrayList(u32) = .empty;
        for (candidates) |e| {
            if (e.ref.module != r.module or e.ref.decl != r.decl) continue;
            @memset(arms, null);
            siteArms(cx, r.decl, @fromBackingInt(@intCast(e.unread)), arms);
            for (arms, alive) |a, *live| {
                if (a) |b| try site_branches.append(scratch, b) else live.* = true;
            }
        }
        var dead: std.ArrayList(u32) = .empty;
        for (alive, 0..) |live, order| if (!live) try dead.append(scratch, @intCast(order));
        if (dead.items.len == 0) continue;
        // The branches of the dead variants, at every site.
        for (candidates) |e| {
            if (e.ref.module != r.module or e.ref.decl != r.decl) continue;
            @memset(arms, null);
            siteArms(cx, r.decl, @fromBackingInt(@intCast(e.unread)), arms);
            for (dead.items) |order| try branches.append(scratch, arms[order].?);
        }
        try refs.append(scratch, r);
        try variants.append(scratch, dead.items);
    }
    std.mem.sort(u32, branches.items, {}, std.sort.asc(u32));
    return .{ .refs = refs.items, .variants = variants.items, .branches = branches.items };
}

/// At `case` instruction `case_inst` on a run of schema declaration
/// `decl`, the branch of each variant, by order, whose arm gives what the
/// `Err _` arm gives (`deadTags`); the others stay null.
fn siteArms(cx: Cx, decl: u32, case_inst: Inst.Index, arms: []?u32) void {
    const bir = cx.bir;
    const d = bir.instData(case_inst);
    const list = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(d.rhs))), Inst.Index);
    // The `Err _` arm's body: the first arm that matches an `Err`.
    const err_body: Inst.Index = for (list) |branch| {
        const pattern: Inst.Index = @fromBackingInt(@intCast(bir.instData(branch).lhs));
        switch (bir.instTag(pattern)) {
            .pat_wild => break @fromBackingInt(@intCast(bir.instData(branch).rhs)),
            .pat_ctor => {
                const arm = resultArm(cx, pattern) orelse return;
                if (!arm.ok) break @fromBackingInt(@intCast(bir.instData(branch).rhs));
            },
            else => return,
        }
    } else return;
    if (!sameReference(bir, err_body, err_body)) return;
    // Each `Ok (S.V …)` arm, in order, until an arm that could match more.
    var twice: u64 = 0;
    for (list) |branch| {
        const pattern: Inst.Index = @fromBackingInt(@intCast(bir.instData(branch).lhs));
        if (bir.instTag(pattern) != .pat_ctor) break;
        const arm = resultArm(cx, pattern) orelse break;
        if (!arm.ok) continue;
        const inner = arm.inner;
        if (bir.instTag(inner) != .pat_ctor) break;
        const ctor: Inst.Index = @fromBackingInt(@intCast(bir.instData(inner).lhs));
        if (bir.instTag(ctor) != .schema_ctor_top or bir.instData(ctor).lhs != decl) break;
        const info = SchemaCtor.of(bir, cx.module, cx.interfaces, ctor) orelse break;
        if (Bir.SchemaCtorRef.unpack(bir.instData(ctor).rhs).encoded) break;
        if (info.order >= arms.len) break;
        const subs = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(bir.instData(inner).rhs))), Inst.Index);
        const plain = for (subs) |sub| switch (bir.instTag(sub)) {
            .pat_wild, .pat_var => {},
            else => break false,
        } else true;
        const body: Inst.Index = @fromBackingInt(@intCast(bir.instData(branch).rhs));
        // A variant with a second arm keeps both.
        if (info.order < 64) {
            const bit = @as(u64, 1) << @intCast(info.order);
            if (twice & bit != 0) {
                arms[info.order] = null;
                continue;
            }
            twice |= bit;
        } else continue;
        if (plain and sameReference(bir, body, err_body)) arms[info.order] = branch.int();
    }
}

/// Which of core `Result`'s constructors `pattern` matches, and the
/// pattern inside it.
const ResultArm = struct { ok: bool, inner: Inst.Index };

fn resultArm(cx: Cx, pattern: Inst.Index) ?ResultArm {
    const pd = cx.bir.instData(pattern);
    const subs = cx.bir.extraSlice(cx.bir.subRange(@fromBackingInt(@intCast(pd.rhs))), Inst.Index);
    if (subs.len != 1) return null;
    const name = ctorName(cx.graph, cx.interfaces, cx.interner, cx.bir, @fromBackingInt(@intCast(pd.lhs))) orelse return null;
    if (std.mem.eql(u8, name, "Ok")) return .{ .ok = true, .inner = subs[0] };
    if (std.mem.eql(u8, name, "Err")) return .{ .ok = false, .inner = subs[0] };
    return null;
}

/// What `deadTags` reads the module's instructions with.
const Cx = struct {
    graph: *const Graph,
    interfaces: []const Interface,
    interner: *const InternPool.Global,
    bir: *const Bir,
    module: Graph.Index,
};

/// Whether `a` and `b` are one reference to one binding: the same local,
/// or the same top-level value.
fn sameReference(bir: *const Bir, a: Inst.Index, b: Inst.Index) bool {
    const t = bir.instTag(a);
    if (t != bir.instTag(b)) return false;
    if (t != .local and t != .top) return false;
    return bir.instData(a).lhs == bir.instData(b).lhs;
}

/// Whether module `module` exposes schema declaration `decl`.
fn exposed(interfaces: []const Interface, provenance: []const Interface.Provenance, module: Graph.Index, decl: u32) bool {
    if (module.int() >= interfaces.len or module.int() >= provenance.len) return true;
    for (0..interfaces[module.int()].schemas.len) |i| {
        const at = provenance[module.int()].schemaDecl(i) orelse return true;
        if (at.int() == decl) return true;
    }
    return false;
}

/// Records `inst`, the instruction whose run is unread, when it is a call
/// of `Result.withDefault` or `Result.toMaybe`: the run is written where
/// it stands, with the call's answer, and the call is never made.
fn consumer(
    graph: *const Graph,
    interfaces: []const Interface,
    interner: *const InternPool.Global,
    bir: *const Bir,
    scratch: Allocator,
    inst: Inst.Index,
    defaults: *std.ArrayList(u32),
    maybes: *std.ArrayList(u32),
    callees: *std.ArrayList(u32),
) Allocator.Error!void {
    if (bir.instTag(inst) != .call) return;
    const callee: Inst.Index = @fromBackingInt(@intCast(bir.instData(inst).lhs));
    if (isCoreValue(graph, interfaces, interner, bir, callee, "Result", "withDefault")) {
        try defaults.append(scratch, inst.int());
    } else if (isCoreValue(graph, interfaces, interner, bir, callee, "Result", "toMaybe")) {
        try maybes.append(scratch, inst.int());
    } else return;
    try callees.append(scratch, callee.int());
}

/// The declaration a `schema` member instruction names, `S.schema`.
fn schemaRoot(provenance: []const Interface.Provenance, interfaces: []const Interface, bir: *const Bir, module: Graph.Index, inst: Inst.Index) ?SchemaGraph.Ref {
    const d = bir.instData(inst);
    switch (bir.instTag(inst)) {
        .schema_member_top => {
            const kind = std.enums.fromInt(Interface.SchemaMember.Kind, d.rhs) orelse return null;
            if (kind != .schema) return null;
            return .{ .module = module, .decl = d.lhs };
        },
        .ext_schema_member => {
            const owner: Graph.Index = @fromBackingInt(@intCast(d.lhs));
            if (owner.int() >= interfaces.len or owner.int() >= provenance.len) return null;
            const iface = &interfaces[owner.int()];
            if (d.rhs >= iface.schema_members.len) return null;
            const m = iface.schema_members[d.rhs];
            if (m.kind != .schema) return null;
            const decl = provenance[owner.int()].schemaDecl(@backingInt(m.schema)) orelse return null;
            return .{ .module = owner, .decl = decl.int() };
        },
        else => return null,
    }
}

/// Whether instruction `inst` is in `list`, which is ascending.
pub fn has(list: []const u32, inst: u32) bool {
    return std.sort.binarySearch(u32, list, inst, struct {
        fn order(key: u32, x: u32) std.math.Order {
            return std.math.order(key, x);
        }
    }.order) != null;
}

/// The call whose error instruction `inst` never reads: a `case`'s
/// scrutinee whose `Err` arms are all `Err _`, or the first argument of a
/// call of `Result.withDefault` or `Result.toMaybe`. Null otherwise.
fn unreadRun(graph: *const Graph, interfaces: []const Interface, interner: *const InternPool.Global, bir: *const Bir, inst: Inst.Index) ?Inst.Index {
    const d = bir.instData(inst);
    switch (bir.instTag(inst)) {
        .case => {
            const scrutinee: Inst.Index = @fromBackingInt(@intCast(d.lhs));
            if (bir.instTag(scrutinee) != .call) return null;
            if (!errUnread(graph, interfaces, interner, bir, inst)) return null;
            return scrutinee;
        },
        .call => {
            const callee: Inst.Index = @fromBackingInt(@intCast(d.lhs));
            if (!isCoreValue(graph, interfaces, interner, bir, callee, "Result", "withDefault") and
                !isCoreValue(graph, interfaces, interner, bir, callee, "Result", "toMaybe")) return null;
            const call_args = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(d.rhs))), Inst.Index);
            if (call_args.len == 0 or bir.instTag(call_args[0]) != .call) return null;
            return call_args[0];
        },
        else => return null,
    }
}

/// Which run a call's callee is, if it is one.
fn runOf(graph: *const Graph, interfaces: []const Interface, interner: *const InternPool.Global, bir: *const Bir, callee: Inst.Index) ?Run {
    if (isCoreValue(graph, interfaces, interner, bir, callee, "Schema", "read")) return .schema_read;
    if (isCoreValue(graph, interfaces, interner, bir, callee, "Schema", "parse")) return .schema_parse;
    if (isCoreValue(graph, interfaces, interner, bir, callee, "Json", "decodeValue")) return .json_read;
    if (isCoreValue(graph, interfaces, interner, bir, callee, "Json", "decode")) return .json_parse;
    return null;
}

/// Whether every arm of `case` instruction `inst` that can match an `Err`
/// matches it as `Err _`.
fn errUnread(graph: *const Graph, interfaces: []const Interface, interner: *const InternPool.Global, bir: *const Bir, inst: Inst.Index) bool {
    const d = bir.instData(inst);
    for (bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(d.rhs))), Inst.Index)) |branch| {
        if (bir.instTag(branch) != .branch) return false;
        const pattern: Inst.Index = @fromBackingInt(@intCast(bir.instData(branch).lhs));
        switch (bir.instTag(pattern)) {
            .pat_wild => {},
            .pat_ctor => {
                const pd = bir.instData(pattern);
                const name = ctorName(graph, interfaces, interner, bir, @fromBackingInt(@intCast(pd.lhs))) orelse return false;
                if (std.mem.eql(u8, name, "Ok")) continue;
                if (!std.mem.eql(u8, name, "Err")) return false;
                const subs = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(pd.rhs))), Inst.Index);
                for (subs) |sub| if (bir.instTag(sub) != .pat_wild) return false;
            },
            else => return false,
        }
    }
    return true;
}

fn isCoreValue(graph: *const Graph, interfaces: []const Interface, interner: *const InternPool.Global, bir: *const Bir, inst: Inst.Index, module_name: []const u8, value_name: []const u8) bool {
    if (bir.instTag(inst) != .ext_value) return false;
    const d = bir.instData(inst);
    const module: Graph.Index = @fromBackingInt(@intCast(d.lhs));
    if (module.int() >= interfaces.len or module.int() >= graph.count()) return false;
    if (graph.modulePackage(module) != .core) return false;
    if (!std.mem.eql(u8, interner.slice(graph.moduleName(module)), module_name)) return false;
    const iface = &interfaces[module.int()];
    if (d.rhs >= iface.values.len) return false;
    return std.mem.eql(u8, interner.slice(iface.symbols[@backingInt(iface.values[d.rhs].name)]), value_name);
}

/// The name of the constructor a `pat_ctor`'s constructor instruction names,
/// when it is core `Result`'s, else null.
fn ctorName(graph: *const Graph, interfaces: []const Interface, interner: *const InternPool.Global, bir: *const Bir, inst: Inst.Index) ?[]const u8 {
    if (bir.instTag(inst) != .ext_ctor) return null;
    const d = bir.instData(inst);
    const module: Graph.Index = @fromBackingInt(@intCast(d.lhs));
    if (module.int() >= interfaces.len or module.int() >= graph.count()) return null;
    if (graph.modulePackage(module) != .core) return null;
    if (!std.mem.eql(u8, interner.slice(graph.moduleName(module)), "Result")) return null;
    const iface = &interfaces[module.int()];
    if (d.rhs >= iface.ctors.len) return null;
    return interner.slice(iface.symbols[@backingInt(iface.ctors[d.rhs].name)]);
}
