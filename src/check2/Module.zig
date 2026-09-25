//! v2's check of one module (checker-v2.md §5): named phases, in order, once
//! each, with no re-settling (I12, CK-15). `Driver.checkInner` runs it for
//! every module `Options.usesV2` selects.
//!
//! | Phase | What it does here (R6b)                                                                 |
//! |-------|-----------------------------------------------------------------------------------------|
//! | P1    | the store, the tables, `Schema.State`, the report                                       |
//! | P2    | every annotated value's published scheme, read at rank `generalized`, with its `where` |
//! | P3    | the own-name index: every value by name, for the module rule (CK-42)                    |
//! | P4    | per top-level group in SCC order: generate, solve, boundary (`Solve.group`)             |
//! | P5    | the eager derived rows, v1's rule until R8a (`Eager`)                                  |
//! | P6    | elaboration: the dispatch table's trees (`Elaborate`)                                  |
//! | P7    | exhaustiveness over the declarations whose failure bit is clear                         |
//! | P8    | the interface, through one publication routine (`Publish`); then `nesting_too_deep`s    |
//! | P9    | the table's round trip, `Cycles`, the I7 assert, the schema plan (no error in module) |
//!
//! P5 writes v1's rows under v1's one-entry-per-parameter context until R8a;
//! a use of a row it could not write is refused (R8a) by P6.
//! A module that met a construct of R7's keeps only its `not_implemented`s
//! (`Report.keepOnlyRefusals`).
//!
//! A module an earlier phase reported on, or the graph poisoned, is checked
//! silently (checker.md §4.3): `Report` drops its messages, once.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Arena = @import("../Arena.zig");
const Artifacts = @import("../Artifacts.zig");
const Profile = @import("../Profile.zig");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const Convention = @import("../check/Convention.zig");
const Cycles = @import("../check/Cycles.zig");
const Diagnostics = @import("../check/Diagnostics.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Exhaustive = @import("../check/Exhaustive.zig");
const Scc = @import("../check/Scc.zig");
const Schema = @import("../check/Schema.zig");
const SchemaPlan = @import("../check/SchemaPlan.zig");
const SchemaPlanBuild = @import("../check/SchemaPlanBuild.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Types = @import("../check/Types.zig");
const dispatch_bytes = @import("../cache/dispatch_bytes.zig");
const schema_plan_bytes = @import("../cache/schema_plan_bytes.zig");
const Check = @import("Check.zig");
const Context = @import("Context.zig");
const Publish = @import("Publish.zig");
const Report = @import("Report.zig");
const Solve = @import("Solve.zig");
const Resolve = @import("Resolve.zig");
const Evidence = @import("Evidence.zig");
const Eager = @import("Eager.zig");
const Elaborate = @import("Elaborate.zig");
const Tree = @import("constrain/Tree.zig");
const Decl = @import("constrain/Decl.zig");

pub const Error = Allocator.Error;
const Var = TypeStore.Var;

/// What `Driver.checkInner` hands v2 for one module.
pub const Input = struct {
    gpa: Allocator,
    scratch: *Arena,
    patterns: *Arena,
    graph: *const Graph,
    artifacts: *const Artifacts,
    interfaces: []Interface,
    provenance: []const Interface.Provenance,
    interner: *const InternPool.Global,
    types: *Types,
    module: Graph.Index,
    diagnostics: *std.ArrayList(Diagnostics.Item),
    quiet: bool,
    profile: ?*Profile,
    tid: u32 = 0,
    pattern_budget: u32 = Exhaustive.default_budget,
    /// This module's slots of the run's tables, written here.
    dispatch: *Dispatch,
    plan: *SchemaPlan,
    roundtrip_interfaces: bool = false,
    roundtrip_dispatch: bool = false,
    /// `ambiguous_method_receiver` is emitted (static-dispatch-spike.md §10.9).
    informational: bool = false,
    /// This module's slot of `Check.modules`, under `keep_stores`.
    keep: ?*Check.Module = null,
};

pub fn check(in: Input) Error!Check.Counters {
    const gpa = in.gpa;
    const file = in.graph.moduleFile(in.module);
    const bir = in.artifacts.bir(file);
    const token = if (in.profile) |p| p.begin() else null;
    defer if (in.profile) |p| p.end(in.tid, token.?, .check, file.int(), 0);
    const quiet = in.quiet or in.graph.isPoisoned(in.module);
    const first_diagnostic = in.diagnostics.items.len;

    // P1.
    var owned_store: TypeStore = .init(std.heap.page_allocator);
    const store = if (in.keep) |k| &k.store else &owned_store;
    defer if (in.keep == null) owned_store.deinit();
    try store.reserve(bir.insts.len + 64, bir.insts.len * 2 + 64);
    const scratch = in.scratch.allocator();

    const decl_scheme = try newTable(gpa, bir.decls.len);
    var tables_kept = false;
    defer if (!tables_kept) gpa.free(decl_scheme);
    const decl_display = try newTable(gpa, bir.decls.len);
    defer if (!tables_kept) gpa.free(decl_display);
    const local_type = try newTable(gpa, bir.locals.len);
    defer if (!tables_kept) gpa.free(local_type);

    var schemas = try Schema.State.init(scratch, store, in.types, in.graph, in.artifacts, in.interfaces, in.interner, in.module, bir);
    defer schemas.deinit();
    try schemas.buildAll();
    var too_deep: std.ArrayList(Context.TooDeep) = .empty;
    defer too_deep.deinit(scratch);
    const cx: Context = .{
        .gpa = gpa,
        .scratch = scratch,
        .store = store,
        .types = in.types,
        .graph = in.graph,
        .artifacts = in.artifacts,
        .interner = in.interner,
        .interfaces = in.interfaces,
        .module = in.module,
        .bir = bir,
        .schemas = &schemas,
        .too_deep = &too_deep,
    };
    var report: Report = undefined;
    try report.init(&cx, in.diagnostics, quiet, decl_scheme, local_type);
    defer report.deinit();
    for (schemas.recursive_aliases.items) |region| {
        try report.emitText(.recursive_alias, region, null, "This schema endpoint is a structural alias that refers to itself.\n\nUse a tagged schema for recursive data so the endpoint has a nominal constructor.\n");
    }
    for (schemas.errors.items) |e| try report.emitText(e.code, e.region, null, e.message);

    // P2: every annotated value's scheme, before any body is checked.
    for (bir.decls, 0..) |d, i| {
        if (!d.kind.isValue()) continue;
        const annotation = d.annotation.unwrap() orelse continue;
        var b = cx.builder(.flex, TypeStore.generalized);
        defer b.deinit();
        decl_scheme[i] = (try cx.readAnnotation(&b, annotation, @intCast(i))).toOptional();
        // The `where` clause is read with the SAME builder, so a variable a
        // requirement names is the annotation's (static-dispatch-spike.md
        // §2.4): the scheme's requirements, which the writer publishes.
        try Decl.attachWhere(&cx, d, &b, @intCast(i));
    }

    // P3: the own-name index (§5, CK-42): every value by name, once.
    const own_values = try ownIndex(scratch, bir);

    // P4.
    try schemas.settleProperties(in.types, gpa);
    var solver: Solve = undefined;
    solver.init(&cx, &report);
    defer solver.deinit();
    solver.decl_scheme = decl_scheme;
    solver.own_values = own_values;
    solver.informational = in.informational;
    solver.resolver.decl_requirements = try scratch.alloc(Dispatch.Range, bir.decls.len);
    @memset(solver.resolver.decl_requirements, .empty);
    // Whether each of this module's nominal types can derive `eq` and
    // `compare`: v1's capability bits, over the method schemes known so far
    // (`Types.settleDispatchCapabilities`, the shared table's own settle);
    // again after a group that publishes an unannotated `pub eq` or
    // `compare`. R8a replaces them with derived contexts (§11.2).
    try in.types.settleDispatchCapabilities(gpa, in.module, in.graph, in.artifacts, store, decl_scheme);
    const groups = try bindingGroups(scratch, bir);
    var constrain_ns: u64 = 0;
    var solve_ns: u64 = 0;
    var tree: Tree.Tree = .{};
    defer tree.deinit(gpa);
    for (0..groups.starts.len - 1) |gi| {
        const indices = groups.order[groups.starts[gi]..groups.starts[gi + 1]];
        const members = try scratch.alloc(Decl.Member, indices.len);
        defer scratch.free(members);
        for (members, indices) |*m, i| m.* = .{ .decl = i, .check = .none };

        tree.nodes.clearRetainingCapacity();
        tree.extra.clearRetainingCapacity();
        tree.binders.clearRetainingCapacity();
        tree.annotated.clearRetainingCapacity();
        var g: Tree.Generator = .{
            .cx = &cx,
            .tree = &tree,
            .gpa = gpa,
            .rank = TypeStore.outermost,
            .local_type = local_type,
            .decl_scheme = decl_scheme,
            .evidence = &solver.evidence,
        };
        defer g.deinit();
        const constrain_token = if (in.profile) |p| p.begin() else null;
        const root = try Decl.group(&g, members);
        if (in.profile) |p| constrain_ns += p.since(constrain_token.?);

        const solve_token = if (in.profile) |p| p.begin() else null;
        try solver.group(.{
            .tree = &tree,
            .root = root,
            .pool = g.pool.items,
            .binders = g.frame_binders.items,
            .annotated = g.frame_annotated.items,
            .members = indices,
        });
        if (in.profile) |p| solve_ns += p.since(solve_token.?);

        var has_schema = false;
        var has_method = false;
        for (members) |m| {
            decl_display[m.decl] = m.check;
            const d = bir.decls[m.decl];
            if (d.kind == .schema) has_schema = true;
            if (d.kind.isValue() and d.is_pub and d.annotation == .none and Resolve.isWellKnownName(bir.symbol(d.name))) has_method = true;
        }
        if (has_method) try in.types.settleDispatchCapabilities(gpa, in.module, in.graph, in.artifacts, store, decl_scheme);
        // v1's order: a schema's endpoint properties can depend on the
        // conversions its group just inferred.
        if (has_schema) try schemas.settleProperties(in.types, gpa);
    }

    // What P2 and P4 found too deep, reported now so its declaration's
    // failure bit is set before P7 reads it (review S10).
    var reported_deep: std.ArrayList(Bir.Inst.Index) = .empty;
    defer reported_deep.deinit(scratch);
    try reportTooDeep(&report, too_deep.items, &reported_deep, scratch);
    const p4_notes = too_deep.items.len;

    // P5 (v1's rows until R8a) and P6: the table's trees.
    var eager: Eager = .{};
    defer eager.deinit(gpa);
    try eager.build(&solver);
    const p6_internals = try elaborate(in, bir, store, decl_scheme, groups, &solver, &eager, &report);

    // P7.
    const exhaustive_token = if (in.profile) |p| p.begin() else null;
    if (!quiet) {
        const skip = try scratch.alloc(bool, bir.decls.len);
        defer scratch.free(skip);
        for (skip, 0..) |*s, i| s.* = report.failed_patterns.isSet(i);
        try Exhaustive.run(gpa, in.patterns, .{
            .graph = in.graph,
            .artifacts = in.artifacts,
            .interfaces = in.interfaces,
            .types = in.types,
            .interner = in.interner,
            .module = in.module,
            .bir = bir,
        }, report.staging(), skip, in.pattern_budget);
        try report.flush();
    }
    if (in.profile) |p| {
        p.record(in.tid, .constrain, file.int(), 0, constrain_ns);
        p.record(in.tid, .solve, file.int(), 0, solve_ns);
        p.end(in.tid, exhaustive_token.?, .exhaustive, file.int(), 0);
    }

    // P8.
    const empty_provenance: Interface.Provenance = .empty;
    try Publish.fill(.{
        .cx = &cx,
        .report = &report,
        .stacks = &solver.stacks,
        .iface = &in.interfaces[in.module.int()],
        .provenance = if (in.module.int() < in.provenance.len) &in.provenance[in.module.int()] else &empty_provenance,
        .decl_scheme = decl_scheme,
        .roundtrip = in.roundtrip_interfaces,
        .types = in.types,
    });
    try reportTooDeep(&report, too_deep.items[p4_notes..], &reported_deep, scratch);

    // P9.
    if (in.roundtrip_dispatch) try roundtripTable(in, &report);
    if (!quiet) {
        try Cycles.run(scratch, bir, in.dispatch, in.interner, report.staging());
        try report.flush();
        // Last, so every error the module has gates it (v1's rule, S2).
        if (report.errors == 0) try assertEvidence(in, bir, &report, p6_internals);
    }
    // What this module's rows say its types derive is what a dependent may
    // name: v1's rows decide it (`Incremental.install` reads the same table
    // on a hit), so a type P5 could not write a row for is not derived
    // elsewhere either (§5, *As built by R6b*; R8a's contexts replace it).
    in.types.restoreDerivedCapabilities(in.module, in.dispatch);
    // Gated on NO error in the module, after the last pass that can report
    // one (CK-15).
    in.plan.deinit(gpa);
    in.plan.* = if (!quiet and report.errors == 0)
        try SchemaPlanBuild.build(gpa, in.module, bir, in.graph, in.interfaces, in.interner, in.types, store, &schemas)
    else
        .empty;
    if (in.roundtrip_dispatch) try roundtripPlan(in, &report);

    report.keepOnlyRefusals(first_diagnostic);

    // A declaration with no body shows its scheme.
    for (decl_display, decl_scheme) |*display, scheme| {
        if (display.* == .none) display.* = scheme;
    }
    if (in.keep) |k| {
        k.decl_scheme = decl_scheme;
        k.decl_display = decl_display;
        k.local_type = local_type;
        tables_kept = true;
    }
    return .{
        .unifications = solver.unifier.unifications,
        .generalisations = solver.generalisations,
        .instantiations = solver.instantiate.instantiations,
    };
}

fn newTable(gpa: Allocator, len: usize) Error![]Var.Optional {
    const table = try gpa.alloc(Var.Optional, len);
    @memset(table, .none);
    return table;
}

/// SCC over the module's top-level values and schemas, dependencies first:
/// an edge `d → e` exists when `d` mentions `e` and `e` is an unannotated
/// value or a schema of this module (v1's `bindingGroups`, kept: §4.4).
fn bindingGroups(scratch: Allocator, bir: *const Bir) Error!Scc.IndexGroups {
    const n = bir.decls.len;
    var edges: std.ArrayList(u32) = .empty;
    defer edges.deinit(scratch);
    const edge_start = try scratch.alloc(u32, n + 1);
    for (bir.decls, 0..) |d, i| {
        edge_start[i] = @intCast(edges.items.len);
        if (!d.kind.isValue() and d.kind != .schema) continue;
        for (bir.declRefs(d)) |ref| {
            if (ref.kind != .top_value and ref.kind != .top_schema) continue;
            const target = ref.a;
            if (target >= n or target == i) continue;
            const t = bir.decls[target];
            if ((!t.kind.isValue() and t.kind != .schema) or (t.kind.isValue() and t.annotation != .none)) continue;
            if (std.mem.indexOfScalar(u32, edges.items[edge_start[i]..], target) != null) continue;
            try edges.append(scratch, target);
        }
    }
    edge_start[n] = @intCast(edges.items.len);
    return Scc.sccGroups(scratch, n, edges.items, edge_start);
}

/// One `nesting_too_deep` per over-deep type, sorted and deduplicated: the
/// same annotation is read more than once, and one mistake is one message.
/// Called twice — after P4, so the declaration's failure bit is set before
/// P7 reads it (review S10), and after P8 for what publication noted — and
/// `reported` keeps the second from repeating the first.
fn reportTooDeep(report: *Report, notes: []Context.TooDeep, reported: *std.ArrayList(Bir.Inst.Index), scratch: Allocator) Error!void {
    if (notes.len == 0) return;
    std.mem.sort(Context.TooDeep, notes, {}, noteLessThan);
    const before = reported.items.len;
    var previous: Bir.Inst.OptionalIndex = .none;
    for (notes) |note| {
        if (previous == note.region.toOptional()) continue;
        previous = note.region.toOptional();
        if (std.sort.binarySearch(Bir.Inst.Index, reported.items[0..before], note.region, regionOrder) != null) continue;
        report.at(note.decl);
        try report.nestingTooDeep(note.region, Types.Builder.max_depth);
        try reported.append(scratch, note.region);
    }
    report.at(null);
    std.mem.sort(Bir.Inst.Index, reported.items, {}, regionLessThan);
}

fn noteLessThan(_: void, a: Context.TooDeep, b: Context.TooDeep) bool {
    return a.region.int() < b.region.int();
}

fn regionOrder(key: Bir.Inst.Index, item: Bir.Inst.Index) std.math.Order {
    return std.math.order(key.int(), item.int());
}

fn regionLessThan(_: void, a: Bir.Inst.Index, b: Bir.Inst.Index) bool {
    return a.int() < b.int();
}

/// P6 (§12.2, §13): the whole dispatch table.
///
///   - one `DeclInfo` per declaration: `value_arity` from the scheme, its
///     requirement list in canonical order (§12.1, `Evidence.requirements`
///     — an annotation's `where` clause, or what promotion kept), and the
///     convention `Convention.of` gives it with that count (§12.5);
///   - each requirement's quantifier root, which `Elaborate` matches a
///     `promoted` answer and a group call against (§12.3): an annotation's
///     givens, on the rigid reading its body was checked against, or what
///     promotion recorded;
///   - the trees, sites and derived rows (`Elaborate.run`), and the `tries`.
fn elaborate(in: Input, bir: *const Bir, store: *TypeStore, decl_scheme: []const Var.Optional, groups: Scc.IndexGroups, solver: *Solve, eager: *const Eager, report: *Report) Error![]const Elaborate.Internal {
    const gpa = in.gpa;
    const scratch = in.scratch.allocator();
    const decls = try gpa.alloc(Dispatch.DeclInfo, bir.decls.len);
    errdefer gpa.free(decls);
    var requirements: std.ArrayList(Dispatch.Requirement) = .empty;
    errdefer requirements.deinit(gpa);
    var roots: std.ArrayList(Var) = .empty;
    defer roots.deinit(scratch);
    var reqs: std.ArrayList(Evidence.Requirement) = .empty;
    defer reqs.deinit(scratch);
    for (decls, decl_scheme, 0..) |*info, scheme, i| {
        const arity: u16 = if (scheme.unwrap()) |v| std.math.cast(u16, store.paramCount(v)) orelse std.math.maxInt(u16) else 0;
        // An annotation's list is its `where` clause's; an unannotated
        // declaration's is what promotion kept (`Resolve.close`). Only a
        // `where` clause is walked here, so a dispatch-free module pays nothing.
        const start: u32 = @intCast(requirements.items.len);
        const d = bir.decls[i];
        if (d.kind.isValue() and d.annotation != .none and d.where_start != d.where_end) {
            reqs.clearRetainingCapacity();
            if (scheme.unwrap()) |v| try Evidence.requirements(store, in.interner, v, scratch, &reqs);
            const givens = solver.evidence.givensOf(@intCast(i));
            for (reqs.items, 0..) |r, k| {
                try requirements.append(gpa, .{ .quantified = r.quantified, .var_name = store.flagsOf(r.root).name, .method = r.method });
                // The body met the rigid reading's variables, not the
                // scheme's: its givens are what a group call matches.
                const given = givens.len == reqs.items.len;
                if (!try solver.expect(given, d.inst_start, "an annotated declaration's `where` clause registered a different number of givens (checker-v2.md §4.2, review S2)")) {
                    try roots.append(scratch, r.root);
                    continue;
                }
                try roots.append(scratch, givens[k].rigid);
            }
        } else {
            const kept = solver.resolver.decl_requirements[i];
            try requirements.appendSlice(gpa, solver.resolver.requirement_rows.items[kept.start..][0..kept.len]);
            try roots.appendSlice(scratch, solver.resolver.requirement_roots.items[kept.start..][0..kept.len]);
        }
        const count: u32 = @intCast(requirements.items.len - start);
        info.* = .{
            .requirements = .{ .start = start, .len = count },
            .value_arity = arity,
            .convention = Convention.of(bir.decls[i].params, Convention.bodyIsLambda(bir, @intCast(i)), arity, count),
        };
    }
    const out = try Elaborate.run(.{
        .cx = solver.cx,
        .evidence = &solver.evidence,
        .eager = eager,
        .decls = decls,
        .requirements = requirements.items,
        .roots = roots.items,
        .decl_scheme = decl_scheme,
        .group_of = try groupOf(scratch, bir, groups),
        .report = report,
        .clean = !report.quiet and report.errors == 0,
    });
    in.dispatch.deinit(gpa);
    // Every `?` the solver decided, by instruction (`checker.md` §6.5): the
    // shape is the one thing about a `?` the backend cannot work out.
    const sorted = try gpa.dupe(Dispatch.Try, solver.tries.items);
    std.mem.sort(Dispatch.Try, sorted, {}, tryLessThan);
    in.dispatch.* = .{
        .decls = decls,
        .tries = sorted,
        .requirements = try requirements.toOwnedSlice(gpa),
        .terms = out.terms,
        .args = out.args,
        .sites = out.sites,
        .derived = out.derived,
        .contexts = out.contexts,
        .symbols = out.symbols,
    };
    return out.internals;
}

/// Each declaration's top-level binding group (`bindingGroups`' index).
fn groupOf(scratch: Allocator, bir: *const Bir, groups: Scc.IndexGroups) Error![]const u32 {
    const out = try scratch.alloc(u32, bir.decls.len);
    @memset(out, std.math.maxInt(u32));
    for (0..groups.starts.len - 1) |g| {
        for (groups.order[groups.starts[g]..groups.starts[g + 1]]) |d| out[d] = @intCast(g);
    }
    return out;
}

/// I7 (§2, §13.1) over the finished table, the one the backend will read:
/// `internal` at each instruction whose tree does not add up, and only in a
/// module that reported nothing — so it runs after the last pass that can
/// report (v1's `assertEvidenceShape`, the same predicate and text). P6's own
/// failures are said here too, under the same gate (review S4): one whose
/// message a later pass says is not the compiler's.
fn assertEvidence(in: Input, bir: *const Bir, report: *Report, p6: []const Elaborate.Internal) Error!void {
    for (p6) |x| try report.internal(x.region, x.what);
    const scratch = in.scratch.allocator();
    var bad: std.ArrayList(Bir.Inst.Index) = .empty;
    defer bad.deinit(scratch);
    try in.dispatch.checkI7(bir, in.interfaces, in.types, scratch, &bad);
    if (bad.items.len == 0) return;
    std.mem.sort(Bir.Inst.Index, bad.items, {}, regionLessThan);
    var previous: ?Bir.Inst.Index = null;
    for (bad.items) |inst| {
        if (previous == inst) continue;
        previous = inst;
        try report.internal(
            inst,
            "the hidden arguments here do not add up — the evidence tree the checker " ++
                "recorded here gives a function a different number of arguments than it has " ++
                "requirements (`docs/design/checker-v2.md` §13.1, invariant I7)",
        );
    }
}

/// `--roundtrip-dispatch` on the table (v1's, verbatim for the table): right
/// after it is finished, before `Cycles` reads it.
fn roundtripTable(in: Input, report: *Report) Error!void {
    const gpa = in.gpa;
    const bytes = try dispatch_bytes.write(gpa, in.dispatch, in.graph, in.types, in.interner);
    defer gpa.free(bytes);
    var loaded = dispatch_bytes.read(gpa, bytes, in.interner) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadSidecar => return report.internal(@enumFromInt(0), "this module's dispatch table did not load back from its own bytes"),
        error.UnknownSymbol => return report.internal(@enumFromInt(0), "this module's dispatch table names a string the session's interner does not hold"),
    };
    dispatch_bytes.resolve(&loaded, in.graph, in.types);
    in.dispatch.deinit(gpa);
    in.dispatch.* = loaded.table;
    loaded.table = .empty;
    loaded.deinit(gpa);
}

/// The plan's canonical round trip under the same flag, once the plan
/// exists (§5, *As built by R4b*).
fn roundtripPlan(in: Input, report: *Report) Error!void {
    const gpa = in.gpa;
    const plan_bytes = try schema_plan_bytes.write(gpa, in.plan, in.interner);
    defer gpa.free(plan_bytes);
    var loaded = schema_plan_bytes.read(gpa, plan_bytes, in.interner) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return report.internal(@enumFromInt(0), "this module's schema plan did not load back from its own bytes"),
    };
    errdefer loaded.deinit(gpa);
    const canonical = try schema_plan_bytes.write(gpa, &loaded, in.interner);
    defer gpa.free(canonical);
    if (!std.mem.eql(u8, plan_bytes, canonical)) {
        loaded.deinit(gpa);
        return report.internal(@enumFromInt(0), "this module's schema plan changed across its canonical round trip");
    }
    in.plan.deinit(gpa);
    in.plan.* = loaded;
}

fn tryLessThan(_: void, a: Dispatch.Try, b: Dispatch.Try) bool {
    return a.inst.int() < b.inst.int();
}

/// P3 (§5, CK-42): every value of the module by name, sorted by symbol, so
/// the module rule's lookup is one binary search and never a scan of the
/// declarations per resolution (v1's `ownDeclNamed`). A name declared twice
/// was refused by resolution; the first declaration wins, as v1's scan did.
fn ownIndex(scratch: Allocator, bir: *const Bir) Error![]const Solve.OwnValue {
    var list: std.ArrayList(Solve.OwnValue) = .empty;
    for (bir.decls, 0..) |d, i| {
        if (!d.kind.isValue()) continue;
        try list.append(scratch, .{ .name = bir.symbol(d.name), .decl = @intCast(i) });
    }
    std.mem.sort(Solve.OwnValue, list.items, {}, ownLessThan);
    return list.items;
}

fn ownLessThan(_: void, a: Solve.OwnValue, b: Solve.OwnValue) bool {
    if (a.name != b.name) return @intFromEnum(a.name) < @intFromEnum(b.name);
    return a.decl < b.decl;
}
