//! The check of one module (checker-v2.md §5): named phases, in order, once
//! each, with no re-settling (I12, CK-15). `Driver.checkInner` runs it for
//! every module that is not a cache hit.
//!
//! | Phase | What it does here (R6b)                                                                 |
//! |-------|-----------------------------------------------------------------------------------------|
//! | P1    | the store, the tables, `Schema.State`, the report                                       |
//! | P2    | every annotated value's published scheme, read at rank `generalized`, with its `where` |
//! | P3    | the own-name index: every value by name, for the module rule (CK-42)                    |
//! | P4    | per top-level group in SCC order, or nested at demand: generate, solve, boundary (`Groups`) |
//! | P5    | every derived context settled (`Contexts`, §11.2), and the eager rows it gives (`Eager`) |
//! | P6    | elaboration: the dispatch table's trees (`Elaborate`)                                  |
//! | P7    | exhaustiveness over the declarations whose failure bit is clear                         |
//! | P8    | the interface, through one publication routine (`Publish`); then `nesting_too_deep`s    |
//! | P9    | the table's round trip, `Cycles`, the I7 assert, the schema plan (no error in module) |
//!
//! A derived context is computed at the first use that asks for it, even in
//! the middle of P4, and every other one in P5; P8 publishes them (§14.2).
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
const Convention = @import("Convention.zig");
const Cycles = @import("Cycles.zig");
const Diagnostics = @import("Diagnostics.zig");
const Dispatch = @import("Dispatch.zig");
const Exhaustive = @import("Exhaustive.zig");
const Scc = @import("Scc.zig");
const Schema = @import("Schema.zig");
const Derivable = @import("Derivable.zig");
const SchemaPlan = @import("SchemaPlan.zig");
const SchemaPlanBuild = @import("SchemaPlanBuild.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
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
const Groups = @import("Groups.zig");
const Contexts = @import("Contexts.zig");
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

    // P1.
    var owned_store: TypeStore = .init(std.heap.page_allocator);
    const store = if (in.keep) |k| &k.store else &owned_store;
    defer if (in.keep == null) owned_store.deinit();
    // v2 makes two to three variables per instruction (R9 measured 2.1× on
    // the generated corpora, 3× on a module of 6 000 tuple comparisons, and
    // at most 4.1× in one module): reserving one per instruction, as v1
    // does, grew the store two or three times, each a copy of every
    // descriptor. The tail a module never touches costs no page.
    try store.reserve(bir.insts.len * 3 + 64, bir.insts.len * 2 + 64);
    // The acyclicity proofs (§8.2 *as restated by R8c's review rounds*).
    store.tracks_proofs = true;
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
        // An Elm curried annotation over a definition of as many
        // parameters is one mistake, reported at the body; its callers are
        // not held to a promise the author did not mean (checker.md §8.7,
        // CK-56).
        const params = bir.extraSlice(.{ .start = d.params_start, .end = d.params_end }, Bir.Inst.Index).len;
        if (cx.store.isCurried(decl_scheme[i].unwrap().?, @intCast(params))) {
            decl_scheme[i] = (try cx.store.freshErr(TypeStore.generalized)).toOptional();
        }
    }

    // P3: the own-name index (§5, CK-42): every value by name, once.
    const own_values = try ownIndex(scratch, bir);

    // P4.
    var solver: Solve = undefined;
    solver.init(&cx, &report);
    defer solver.deinit();
    solver.decl_scheme = decl_scheme;
    solver.own_values = own_values;
    solver.informational = in.informational;
    solver.resolver.decl_requirements = try scratch.alloc(Dispatch.Range, bir.decls.len);
    @memset(solver.resolver.decl_requirements, .empty);
    // The derived contexts (§11.2): the type-level units now, each answer
    // when a use first asks for it, and every other one in P5.
    solver.contexts = try Contexts.init(&cx);
    defer solver.contexts.deinit();
    const sccs = try bindingGroups(scratch, bir);
    var groups: Groups = try .init(&cx, sccs, local_type, decl_scheme, decl_display);
    defer groups.deinit();
    groups.profile = in.profile;
    solver.groups = &groups;
    const p4_token = if (in.profile) |p| p.begin() else null;
    try groups.checkAll(&solver);
    // A record a deferred wanted refused, as P4 left it (checker.md §8.7).
    try report.renderLate();
    const p4_ns: u64 = if (in.profile) |p| p.since(p4_token.?) else 0;
    const constrain_ns = groups.constrain_ns;
    const solve_ns = p4_ns -| constrain_ns;

    // What P2 and P4 found too deep, reported now so its declaration's
    // failure bit is set before P7 reads it (review S10).
    var reported_deep: std.ArrayList(Bir.Inst.Index) = .empty;
    defer reported_deep.deinit(scratch);
    try reportTooDeep(&report, too_deep.items, &reported_deep, scratch);
    const p4_notes = too_deep.items.len;

    // P5 (the derived contexts, settled, and their rows) and P6: the
    // table's trees.
    var eager: Eager = .{};
    defer eager.deinit(gpa);
    const p5_token = if (in.profile) |p| p.begin() else null;
    try eager.build(&solver);
    if (in.profile) |p| p.end(in.tid, p5_token.?, .derived, file.int(), 0);
    const p6_token = if (in.profile) |p| p.begin() else null;
    const p6_internals = try elaborate(in, bir, store, decl_scheme, &groups, &solver, &eager, &report);
    if (in.profile) |p| p.end(in.tid, p6_token.?, .elaborate, file.int(), 0);

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
    const p8_token = if (in.profile) |p| p.begin() else null;
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
        .contexts = &solver.contexts,
    });
    try reportTooDeep(&report, too_deep.items[p4_notes..], &reported_deep, scratch);
    if (in.profile) |p| p.end(in.tid, p8_token.?, .publish, file.int(), 0);

    // P9.
    const p9_token = if (in.profile) |p| p.begin() else null;
    if (in.roundtrip_dispatch) try roundtripTable(in, &report);
    if (!quiet) {
        try Cycles.run(scratch, bir, in.dispatch, in.interner, report.staging());
        try report.flush();
        // Last, so every error the module has gates it (v1's rule, S2).
        if (report.errors == 0) try assertEvidence(in, bir, &report, p6_internals);
    }
    // Gated on NO error in the module, after the last pass that can report
    // one (CK-15).
    in.plan.deinit(gpa);
    in.plan.* = if (!quiet and report.errors == 0) blk: {
        // The endpoints' property bytes, read off the settled contexts (§11.5
        // *as built by R8b*): nothing settles them in the session table.
        const properties = try scratch.alloc([2]u8, bir.decls.len);
        for (bir.decls, properties, 0..) |d, *p, i| {
            p.* = .{ 0, 0 };
            if (d.kind != .schema or d.schema_body == .none) continue;
            const pair = schemas.endpoints[i];
            p.* = .{ try Derivable.propertyBits(&solver, pair.program), try Derivable.propertyBits(&solver, pair.encoded) };
        }
        break :blk try SchemaPlanBuild.build(gpa, in.module, bir, in.graph, in.interfaces, in.interner, in.types, store, &schemas, properties);
    } else .empty;
    if (in.roundtrip_dispatch) try roundtripPlan(in, &report);
    if (in.profile) |p| p.end(in.tid, p9_token.?, .finish, file.int(), 0);

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
        .derived_context_runs = solver.contexts.runs_total,
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
fn elaborate(in: Input, bir: *const Bir, store: *TypeStore, decl_scheme: []const Var.Optional, groups: *Groups, solver: *Solve, eager: *const Eager, report: *Report) Error![]const Elaborate.Internal {
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
                // scheme's: its givens are what a group call matches. A
                // declaration with no body — an annotation with no definition
                // (already reported), a `foreign` — has no rigid reading, and
                // nothing inside it calls anything: its scheme's roots (CK-121).
                if (d.body == .none) {
                    try roots.append(scratch, r.root);
                    continue;
                }
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
        .contexts = &solver.contexts,
        .decls = decls,
        .requirements = requirements.items,
        .roots = roots.items,
        .decl_scheme = decl_scheme,
        .group_of = try groupOf(scratch, groups),
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

/// Each declaration's binding group after P4: the root of its merge class
/// (§10.4), so the members of a merged group are one group to §12.3.
fn groupOf(scratch: Allocator, groups: *Groups) Error![]const u32 {
    const out = try scratch.alloc(u32, groups.group_of.len);
    for (out, groups.group_of) |*o, g| o.* = if (g == Groups.none) g else groups.root(g);
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
    try in.dispatch.checkI7(bir, in.interfaces, in.types, in.interner, scratch, &bad);
    if (bad.items.len == 0) return;
    // From the cut-over (R11) a violation is a v2 bug with no known
    // exception, so a safe build stops at it (§13.1); a release build still
    // says `internal` below and writes nothing.
    if (std.debug.runtime_safety) std.debug.panic("I7: {d} instruction(s) whose evidence tree does not add up (checker-v2.md §13.1)", .{bad.items.len});
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
