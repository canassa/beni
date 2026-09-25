//! v2's check of one module (checker-v2.md §5): named phases, in order, once
//! each, with no re-settling (I12, CK-15). `Driver.checkInner` runs it for
//! every module `Options.usesV2` selects.
//!
//! | Phase | What it does here (R4b)                                                                 |
//! |-------|-----------------------------------------------------------------------------------------|
//! | P0    | `Subset.scan`: a module that needs a later slice says so, once, and stops               |
//! | P1    | the store, the tables, `Schema.State`, the report                                       |
//! | P2    | every annotated value's published scheme, read at rank `generalized`                    |
//! | P4    | per top-level group in SCC order: generate, solve, boundary (`Solve.group`)             |
//! | P7    | exhaustiveness over the declarations whose failure bit is clear                         |
//! | P8    | the interface, through one publication routine (`Publish`); then `nesting_too_deep`s    |
//! | P9    | the dispatch table, its round trip, `Cycles`, then the schema plan (no error in module) |
//!
//! P3 (the own-name index) serves resolution, R6a's; P5 (eager derived rows)
//! is R8a's and P6 (elaboration) R6b's — `Subset.zig` keeps every module
//! that would need them out of R4b.
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
const Subset = @import("Subset.zig");
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

    // P0.
    if (Subset.scan(bir, in.interfaces)) |missing| {
        try refuse(in, bir, quiet, missing);
        return .{};
    }

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
    }

    // P4.
    try schemas.settleProperties(in.types, gpa);
    var solver: Solve = undefined;
    solver.init(&cx, &report);
    defer solver.deinit();
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
        for (members) |m| {
            decl_display[m.decl] = m.check;
            if (bir.decls[m.decl].kind == .schema) has_schema = true;
        }
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
    try finishTable(in, bir, store, decl_scheme, solver.tries.items);
    if (in.roundtrip_dispatch) try roundtripTable(in, &report);
    if (!quiet) {
        try Cycles.run(scratch, bir, in.dispatch, in.interner, report.staging());
        try report.flush();
    }
    // Gated on NO error in the module, after the last pass that can report
    // one (CK-15).
    in.plan.deinit(gpa);
    in.plan.* = if (!quiet and report.errors == 0)
        try SchemaPlanBuild.build(gpa, in.module, bir, in.graph, in.interfaces, in.interner, in.types, store, &schemas)
    else
        .empty;
    if (in.roundtrip_dispatch) try roundtripPlan(in, &report);

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

/// P0's answer: one `not_implemented`, and what a failed check leaves —
/// `Types.ref_ids` for the shell record every term reader indexes, and
/// `none`-filled tables for `dump --stage=types`. No scheme is published.
fn refuse(in: Input, bir: *const Bir, quiet: bool, missing: Subset.Missing) Error!void {
    const gpa = in.gpa;
    const ref_ids = &in.types.ref_ids[in.module.int()];
    gpa.free(ref_ids.*);
    ref_ids.* = &.{};
    ref_ids.* = try in.types.resolveRefs(gpa, &in.interfaces[in.module.int()], in.graph);
    if (in.keep) |k| {
        k.decl_scheme = try newTable(gpa, bir.decls.len);
        k.decl_display = try newTable(gpa, bir.decls.len);
        k.local_type = try newTable(gpa, bir.locals.len);
    }
    const message = try std.fmt.allocPrint(gpa, "checker v2 cannot check this module until slice {s}: {s}.\n", .{ missing.slice.name(), missing.slice.reason() });
    // Through the one emit path (§15.1, review S7).
    try Report.appendTo(gpa, in.diagnostics, quiet, .{
        .code = .not_implemented,
        .module = in.module,
        .region = missing.region,
        .token = missing.token,
        .message = message,
    });
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

/// P9's table: one `DeclInfo` per declaration — no site, no term, no
/// requirement in R4b's subset — with `value_arity` read off the scheme and
/// the convention `Convention.of` gives it (§12.5).
fn finishTable(in: Input, bir: *const Bir, store: *TypeStore, decl_scheme: []const Var.Optional, tries: []const Dispatch.Try) Error!void {
    const decls = try in.gpa.alloc(Dispatch.DeclInfo, bir.decls.len);
    for (decls, decl_scheme, 0..) |*info, scheme, i| {
        const arity: u16 = if (scheme.unwrap()) |v| std.math.cast(u16, store.paramCount(v)) orelse std.math.maxInt(u16) else 0;
        info.* = .{
            .value_arity = arity,
            .convention = Convention.of(bir.decls[i].params, Convention.bodyIsLambda(bir, @intCast(i)), arity, 0),
        };
    }
    in.dispatch.deinit(in.gpa);
    // Every `?` the solver decided, by instruction (`checker.md` §6.5): the
    // shape is the one thing about a `?` the backend cannot work out.
    const sorted = try in.gpa.dupe(Dispatch.Try, tries);
    std.mem.sort(Dispatch.Try, sorted, {}, tryLessThan);
    in.dispatch.* = .{ .decls = decls, .tries = sorted };
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
