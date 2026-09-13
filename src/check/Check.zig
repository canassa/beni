//! The checker's driver (docs/design/checker.md §6): one `TypeStore` per
//! module, the module's top-level values SCC-decomposed into binding groups,
//! and for each group constrain → solve → generalise, followed by the
//! schemes going into the interface (§7).
//!
//! **Order.** Modules are checked in the graph's topological order, so every
//! import's interface is complete — and immutable — before anything reads
//! it. M2b runs that order serially; the data is laid out for the DAG
//! parallelism of §4.4 (a module's check reads only its own Bir, the
//! interfaces of its imports, and the store it owns), and nothing here is
//! shared between two modules' checks except the session-wide `Types`
//! table, which is read-only by then.
//!
//! **Binding groups.** Top-level values are SCC-decomposed over the
//! module's `refs`, and an edge exists only to an UNANNOTATED value: a
//! declaration with an annotation is checked against that annotation and
//! its annotation is what dependents see, which breaks recursion through it
//! (§6.1) and keeps groups minimal (design §7 #5). An annotated declaration
//! therefore can never be inside a cycle, which is also what lets every
//! annotated scheme be built in one pass before any body is checked.
//!
//! **An annotated declaration is read twice**, and deliberately: once as a
//! generalised scheme (what callers instantiate) and once as rigid variables
//! at the group's rank (what the body is held to). They are two readings of
//! the same tree, so they have the same shape by construction, and keeping
//! them apart is what makes `f : a -> a` reject a body that only works for
//! `Int` while still letting a caller use it at `Int`.
//!
//! **The store dies with the module** unless `keep_stores` is set, which
//! `dump --stage=types` does: the dump prints every local binding's type,
//! and a `Var` means nothing once its store is gone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diagnostic = @import("diagnostic");
const Arena = @import("../Arena.zig");
const Artifacts = @import("../Artifacts.zig");
const Profile = @import("../Profile.zig");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const Constrain = @import("Constrain.zig");
const Diagnostics = @import("Diagnostics.zig");
const Render = @import("Render.zig");
const Schemes = @import("Schemes.zig");
const Solve = @import("Solve.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");

const Check = @This();

pub const Var = TypeStore.Var;
pub const Symbol = InternPool.Symbol;
pub const Error = Allocator.Error;

/// What one checked module leaves behind for `dump --stage=types`. Present
/// only when the run asked for it.
pub const Module = struct {
    store: TypeStore,
    /// Scheme per top-level declaration; `.none` for a type. This is what
    /// the interface carries and what dependents instantiate.
    decl_scheme: []Var.Optional,
    /// What `dump --stage=types` prints for a declaration. It differs from
    /// `decl_scheme` for an ANNOTATED one: the scheme is a generalised
    /// reading of the annotation and the body was checked against a RIGID
    /// reading, two structurally identical trees over different variables.
    /// Printing the scheme next to locals that belong to the other tree
    /// would name the same `a` twice over, so the dump uses the tree the
    /// locals are in.
    decl_display: []Var.Optional,
    /// Type per local, indexed exactly like `Bir.locals`.
    local_type: []Var.Optional,
};

/// Owned. The session-wide type table.
types: Types,
/// Owned. Diagnostics in module-check order; the session sorts.
diagnostics: []const Diagnostics.Item,
/// Owned when `modules.len != 0`: one per graph module, in module index
/// order. Empty unless the run asked to keep them.
modules: []Module,
counters: Solve.Counters,

pub const empty: Check = .{ .types = .empty, .diagnostics = &.{}, .modules = &.{}, .counters = .{} };

pub fn deinit(check: *Check, gpa: Allocator) void {
    check.types.deinit(gpa);
    for (check.diagnostics) |d| gpa.free(d.message);
    gpa.free(check.diagnostics);
    for (check.modules) |*m| {
        m.store.deinit();
        gpa.free(m.decl_scheme);
        gpa.free(m.decl_display);
        gpa.free(m.local_type);
    }
    gpa.free(check.modules);
    check.* = empty;
}

pub const Options = struct {
    /// Where the per-module `constrain` and `solve` events go (checker.md
    /// §9). The two halves are timed separately because the
    /// constraint/solve split is the architecture (research/02 §1), and a
    /// trace that could not tell them apart would hide which half a
    /// regression is in.
    profile: ?*Profile = null,
    /// Keep each module's store and variable tables alive after the check,
    /// for `dump --stage=types`.
    keep_stores: bool = false,
    /// One per graph module: true when an EARLIER phase already reported on
    /// it. Such a module is still checked — its dependents need schemes —
    /// but silently.
    ///
    /// This is Elm's rule (`compile` chains parse → canonicalize → typecheck
    /// and stops at the first failure) and it is what keeps one mistake to
    /// one message: a file with a syntax error has a tree the parser
    /// GUESSED, and a file with an unbound name has a declaration whose type
    /// is unknowable, so every type error found in either is a consequence
    /// of the message the author already has.
    quiet: []const bool = &.{},
};

/// Type-check every module of `graph`, filling `interfaces` with schemes.
pub fn run(
    gpa: Allocator,
    scratch: *Arena,
    graph: *const Graph,
    artifacts: *const Artifacts,
    interfaces: []Interface,
    interner: *const InternPool.Global,
    options: Options,
) Error!Check {
    var check: Check = .empty;
    errdefer check.deinit(gpa);
    check.types = try Types.build(gpa, graph, artifacts, interfaces, interner);

    var diagnostics: std.ArrayList(Diagnostics.Item) = .empty;
    errdefer {
        for (diagnostics.items) |d| gpa.free(d.message);
        diagnostics.deinit(gpa);
    }
    var modules: std.ArrayList(Module) = .empty;
    errdefer modules.deinit(gpa);
    if (options.keep_stores) {
        try modules.ensureTotalCapacity(gpa, graph.count());
        for (0..graph.count()) |_| modules.appendAssumeCapacity(.{
            .store = .init(std.heap.page_allocator),
            .decl_scheme = &.{},
            .decl_display = &.{},
            .local_type = &.{},
        });
    }

    for (graph.order) |m| {
        var one: ModuleCheck = .{
            .gpa = gpa,
            .scratch = scratch,
            .graph = graph,
            .artifacts = artifacts,
            .interfaces = interfaces,
            .interner = interner,
            .types = &check.types,
            .module = m,
            .diagnostics = &diagnostics,
            .quiet = m.int() < options.quiet.len and options.quiet[m.int()],
            .profile = options.profile,
        };
        const kept = try one.run(if (options.keep_stores) &modules.items[m.int()] else null);
        check.counters.unifications += kept.unifications;
        check.counters.generalisations += kept.generalisations;
        check.counters.instantiations += kept.instantiations;
        check.counters.obligations += kept.obligations;
    }

    check.diagnostics = try diagnostics.toOwnedSlice(gpa);
    check.modules = try modules.toOwnedSlice(gpa);
    return check;
}

const ModuleCheck = struct {
    gpa: Allocator,
    scratch: *Arena,
    graph: *const Graph,
    artifacts: *const Artifacts,
    interfaces: []Interface,
    interner: *const InternPool.Global,
    types: *const Types,
    module: Graph.Index,
    diagnostics: *std.ArrayList(Diagnostics.Item),
    quiet: bool,
    profile: ?*Profile,
    /// Nanoseconds this module spent in each half, summed over its binding
    /// groups and emitted as one event each when the module is done.
    constrain_ns: u64 = 0,
    solve_ns: u64 = 0,

    fn run(mc: *ModuleCheck, keep: ?*Module) Error!Solve.Counters {
        const gpa = mc.gpa;
        const bir = mc.artifacts.bir(mc.graph.moduleFile(mc.module));

        var owned_store: TypeStore = .init(std.heap.page_allocator);
        const store = if (keep) |k| &k.store else &owned_store;
        defer if (keep == null) owned_store.deinit();
        // One descriptor per instruction is a good first guess: most
        // instructions get a variable and most types are one node.
        try store.reserve(bir.insts.len + 64, bir.insts.len * 2 + 64);

        const decl_scheme = try gpa.alloc(Var.Optional, bir.decls.len);
        errdefer gpa.free(decl_scheme);
        @memset(decl_scheme, .none);
        const decl_display = try gpa.alloc(Var.Optional, bir.decls.len);
        errdefer gpa.free(decl_display);
        @memset(decl_display, .none);
        const local_type = try gpa.alloc(Var.Optional, bir.locals.len);
        errdefer gpa.free(local_type);
        @memset(local_type, .none);
        const inst_result = try gpa.alloc(Var.Optional, bir.insts.len);
        defer gpa.free(inst_result);
        @memset(inst_result, .none);

        var env: Constrain.Env = .{
            .scratch = mc.scratch.allocator(),
            .store = store,
            .types = mc.types,
            .graph = mc.graph,
            .artifacts = mc.artifacts,
            .interner = mc.interner,
            .interfaces = mc.interfaces,
            .module = mc.module,
            .bir = bir,
            .decl_scheme = decl_scheme,
            .local_var = &.{},
            .inst_result = &.{},
            .inst_base = 0,
        };
        var reporter: Diagnostics.Reporter = .{
            .gpa = gpa,
            .env = &env,
            .items = mc.diagnostics,
            // A module in an import cycle has error types and reports
            // nothing further (checker.md §4.3); so does one an earlier
            // phase already reported on (see `Options.quiet`).
            .quiet = mc.quiet or mc.graph.isPoisoned(mc.module),
        };

        // 1. Every annotated value's scheme, before any body is checked.
        for (bir.decls, 0..) |d, i| {
            if (!d.kind.isValue()) continue;
            const annotation = d.annotation.unwrap() orelse continue;
            var b = env.builder(.flex, TypeStore.generalized);
            defer b.deinit();
            decl_scheme[i] = (try b.read(annotation)).toOptional();
        }

        // 2. Binding groups over the values that still need inferring.
        const groups = try mc.bindingGroups(bir, &env);
        var counters: Solve.Counters = .{};
        for (0..groups.starts.len - 1) |g| {
            const members = groups.order[groups.starts[g]..groups.starts[g + 1]];
            counters = add(counters, try mc.checkGroup(bir, &env, &reporter, members, decl_display, local_type, inst_result));
        }

        if (mc.profile) |profile| {
            const file = mc.graph.moduleFile(mc.module).int();
            profile.record(0, .constrain, file, 0, mc.constrain_ns);
            profile.record(0, .solve, file, 0, mc.solve_ns);
        }

        // 3. The interface gains its schemes (checker.md §7).
        try mc.fillInterface(bir, store, decl_scheme);

        // A declaration with no body — a `foreign` value, an annotation the
        // parser found no definition for — has no check variable, so its
        // scheme is the only thing to show.
        for (decl_display, decl_scheme) |*display, scheme| {
            if (display.* == .none) display.* = scheme;
        }
        if (keep) |k| {
            k.decl_scheme = decl_scheme;
            k.decl_display = decl_display;
            k.local_type = local_type;
        } else {
            gpa.free(decl_scheme);
            gpa.free(decl_display);
            gpa.free(local_type);
        }
        return counters;
    }

    fn add(a: Solve.Counters, b: Solve.Counters) Solve.Counters {
        return .{
            .unifications = a.unifications + b.unifications,
            .generalisations = a.generalisations + b.generalisations,
            .instantiations = a.instantiations + b.instantiations,
            .obligations = a.obligations + b.obligations,
        };
    }

    /// SCC over the module's top-level values. An edge `d → e` exists when
    /// `d` mentions `e` and `e` is an unannotated value of this module —
    /// the only case where `d`'s check has to wait for `e`'s.
    fn bindingGroups(mc: *ModuleCheck, bir: *const Bir, env: *Constrain.Env) Error!Constrain.IndexGroups {
        const scratch = env.scratch;
        const n = bir.decls.len;
        var edges: std.ArrayList(u32) = .empty;
        defer edges.deinit(scratch);
        const edge_start = try scratch.alloc(u32, n + 1);
        for (bir.decls, 0..) |d, i| {
            edge_start[i] = @intCast(edges.items.len);
            if (!d.kind.isValue()) continue;
            for (bir.declRefs(d)) |ref| {
                if (ref.kind != .top_value) continue;
                const target = ref.a;
                if (target >= n or target == i) continue;
                const t = bir.decls[target];
                if (!t.kind.isValue() or t.annotation != .none) continue;
                if (std.mem.indexOfScalar(u32, edges.items[edge_start[i]..], target) != null) continue;
                try edges.append(scratch, target);
            }
        }
        edge_start[n] = @intCast(edges.items.len);
        _ = mc;
        return Constrain.sccGroups(scratch, n, edges.items, edge_start);
    }

    /// One binding group: constrain every member, then solve the whole
    /// group at rank `outermost`, generalise, and occurs-check.
    fn checkGroup(
        mc: *ModuleCheck,
        bir: *const Bir,
        env: *Constrain.Env,
        reporter: *Diagnostics.Reporter,
        members: []const u32,
        decl_display: []Var.Optional,
        local_type: []Var.Optional,
        inst_result: []Var.Optional,
    ) Error!Solve.Counters {
        const gpa = mc.gpa;
        var tree: Constrain.Tree = .{};
        defer {
            tree.nodes.deinit(gpa);
            tree.extra.deinit(gpa);
        }
        var generator: Constrain.Generator = .init(env, &tree, gpa, TypeStore.outermost);
        defer generator.deinit();
        const constrain_token = if (mc.profile) |p| p.begin() else null;

        var parts: std.ArrayList(Constrain.Constraint) = .empty;
        defer parts.deinit(env.scratch);
        var headers: std.ArrayList(Constrain.Header) = .empty;
        defer headers.deinit(env.scratch);

        // Declare first, define second: a mutually recursive group has to
        // see itself before any body is generated.
        // `.none` for a member with no body — a type, a `foreign` value, an
        // annotation whose definition the parser never found. Giving one a
        // variable would put it in the pool and generalise it, which shows
        // up as a counter that does not mean anything.
        const check_vars = try env.scratch.alloc(Var.Optional, members.len);
        defer env.scratch.free(check_vars);
        for (members, check_vars) |index, *cv| {
            const d = bir.decls[index];
            cv.* = .none;
            if (!d.kind.isValue() or d.body == .none) continue;
            if (d.annotation != .none) {
                const mark = generator.storeMark();
                var b = env.builder(.rigid, TypeStore.outermost);
                defer b.deinit();
                cv.* = (try b.read(d.annotation.unwrap().?)).toOptional();
                try generator.adoptSince(mark);
            } else {
                const v = try generator.freshForDecl();
                cv.* = v.toOptional();
                env.decl_scheme[index] = v.toOptional();
            }
            try headers.append(env.scratch, .{
                .v = cv.*.unwrap().?,
                .region = d.body.unwrap().?,
                .name = bir.symbol(d.name).toOptional(),
            });
        }
        for (members, check_vars) |index, cv_opt| {
            decl_display[index] = cv_opt;
            const cv = cv_opt.unwrap() orelse continue;
            const d = bir.decls[index];
            env.local_var = local_type[d.locals_start..d.locals_end];
            env.locals_base = d.locals_start;
            env.inst_base = d.inst_start.int();
            env.inst_result = inst_result[d.inst_start.int()..d.inst_end.int()];
            env.decl_result = .none;
            try parts.append(env.scratch, try generator.decl(@enumFromInt(index), cv));
        }
        tree.root = try generator.finishGroup(parts.items);
        if (mc.profile) |p| {
            mc.constrain_ns += p.since(constrain_token.?);
        }

        const solve_token = if (mc.profile) |p| p.begin() else null;
        var solver: Solve.Solver = .init(gpa, env, &tree, reporter);
        defer solver.deinit();
        solver.rank = TypeStore.outermost;
        try solver.enterTopLevel(generator.poolItems());
        try solver.solve(tree.root);
        try solver.finishTopLevel(headers.items);
        if (mc.profile) |p| {
            mc.solve_ns += p.since(solve_token.?);
        }
        return solver.counters;
    }

    /// Write every `pub` value's scheme into the interface (checker.md §7).
    /// A declaration whose type contains an error gets the `err` term, which
    /// the dump prints as `<error>`: dependents check against the rest.
    fn fillInterface(mc: *ModuleCheck, bir: *const Bir, store: *TypeStore, decl_scheme: []const Var.Optional) Error!void {
        const gpa = mc.gpa;
        const iface = &mc.interfaces[mc.module.int()];
        var writer: Schemes.Writer = .init(gpa, store, @intCast(iface.symbols.len));
        defer writer.deinit();

        const values = try gpa.alloc(Interface.Value, iface.values.len);
        errdefer gpa.free(values);
        @memcpy(values, iface.values);
        for (values) |*v| {
            const name = iface.symbol(v.name);
            const scheme = blk: {
                for (bir.decls, 0..) |d, i| {
                    if (!d.kind.isValue() or bir.symbol(d.name) != name) continue;
                    break :blk decl_scheme[i].unwrap();
                }
                break :blk null;
            };
            const target = scheme orelse {
                v.scheme = try writer.addError();
                continue;
            };
            v.scheme = if (hasError(store, target)) try writer.addError() else try writer.add(target);
        }
        gpa.free(@constCast(iface.values));
        iface.values = values;
        try writer.attach(iface);
    }
};

/// Whether a solved type contains a poisoned variable anywhere. A
/// declaration that failed to check is `<error>` in the interface rather
/// than a type built out of `?` (checker.md §7).
fn hasError(store: *TypeStore, root_var: Var) bool {
    const mark = store.nextMark();
    var stack: [256]Var = undefined;
    var len: usize = 1;
    stack[0] = root_var;
    var budget: usize = 1 << 16;
    while (len > 0) {
        if (budget == 0) return false;
        budget -= 1;
        len -= 1;
        const v = stack[len];
        const root = store.find(v);
        if (store.mark(root) == mark) continue;
        store.setMark(root, mark);
        switch (store.content(root)) {
            .err => return true,
            .flex, .rigid => {},
            .alias => |a| {
                if (len < stack.len) {
                    stack[len] = a.actual;
                    len += 1;
                }
            },
            .structure => |flat| switch (flat) {
                .unit, .empty_record => {},
                .func => |f| {
                    for ([_]Var{ f.param, f.result }) |x| {
                        if (len >= stack.len) break;
                        stack[len] = x;
                        len += 1;
                    }
                },
                .app => |a| for (store.vars(a.args)) |x| {
                    if (len >= stack.len) break;
                    stack[len] = x;
                    len += 1;
                },
                .tuple => |t| for (store.vars(t)) |x| {
                    if (len >= stack.len) break;
                    stack[len] = x;
                    len += 1;
                },
                .record => |r| {
                    for (store.fields(r.fields)) |f| {
                        if (len >= stack.len) break;
                        stack[len] = f.value;
                        len += 1;
                    }
                    if (len < stack.len) {
                        stack[len] = r.ext;
                        len += 1;
                    }
                },
            },
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
//
// The checker is exercised through the real pipeline over sources in memory
// and asserted on the text of `dump --stage=types`. That is deliberate: a
// scheme is the only thing a person can read, `Render` is what every
// diagnostic prints types with, and asserting the store's internals instead
// would test an implementation that is meant to change. `TypeStore.zig`,
// `Schemes.zig` and `Solve.zig` keep the pieces that have no visible output
// — the journal, the term round trip, the occurs check, `adjustRank`.
// ---------------------------------------------------------------------------

const testing = std.testing;
const TestProject = @import("../resolve/TestProject.zig");
const dump_types = @import("../dump/types.zig");
const Session = @import("../Session.zig");

/// A core package small enough to read and big enough for the scenarios:
/// the prelude's types, the ad-hoc annotations of `fast-compiler.md` §3.1,
/// and the handful of `List`/`Maybe`/`Result`/`String` functions the tests
/// call. The embedded core would work too and costs ~2,800 lines of parsing
/// per test; this way a test that turns on `number` says so in the fixture.
const test_core = [_]TestProject.Module{
    .{ .path = "Basics.beni", .package = .core, .source =
    \\pub equatable foreign type Int
    \\
    \\
    \\pub equatable foreign type Float
    \\
    \\
    \\pub equatable foreign type Char
    \\
    \\
    \\pub equatable foreign type String
    \\
    \\
    \\pub type Bool
    \\    = True
    \\    | False
    \\
    \\
    \\pub type Order
    \\    = LT
    \\    | EQ
    \\    | GT
    \\
    \\
    \\pub foreign add : number -> number -> number
    \\
    \\
    \\pub foreign sub : number -> number -> number
    \\
    \\
    \\pub foreign mul : number -> number -> number
    \\
    \\
    \\pub foreign lt : number -> number -> Bool
    \\
    \\
    \\pub foreign eq : equatable a -> a -> Bool
    \\
    \\
    \\pub foreign append : appendable -> appendable -> appendable
    \\
    \\
    \\pub foreign toFloat : Int -> Float
    \\
    \\
    \\pub identity : a -> a
    \\identity a =
    \\    a
    \\
    \\
    \\pub max : number -> number -> number
    \\max x y =
    \\    x
    \\
    },
    .{ .path = "List.beni", .package = .core, .source =
    \\pub equatable foreign type List a
    \\
    \\
    \\pub foreign cons : a -> List a -> List a
    \\
    \\
    \\pub foreign map : (a -> b) -> List a -> List b
    \\
    \\
    \\pub foreign foldl : (a -> b -> b) -> b -> List a -> b
    \\
    \\
    \\pub foreign length : List a -> Int
    \\
    },
    .{ .path = "Maybe.beni", .package = .core, .source =
    \\pub type Maybe a
    \\    = Just a
    \\    | Nothing
    \\
    },
    .{ .path = "Result.beni", .package = .core, .source =
    \\pub type Result x a
    \\    = Ok a
    \\    | Err x
    \\
    },
    .{ .path = "String.beni", .package = .core, .source =
    \\pub foreign length : String -> Int
    \\
    \\
    \\pub foreign fromInt : Int -> String
    \\
    },
    .{ .path = "Char.beni", .package = .core, .source = "pub foreign isDigit : Char -> Bool\n" },
    .{ .path = "Debug.beni", .package = .core, .source = "pub foreign todo : String -> a\n" },
};

/// Run the checker over `source` as the module `M`, and compare
/// `dump --stage=types`.
fn expectTypes(expected: []const u8, source: [:0]const u8) !void {
    const gpa = testing.allocator;
    var modules: std.ArrayList(TestProject.Module) = .empty;
    defer modules.deinit(gpa);
    try modules.appendSlice(gpa, &test_core);
    try modules.append(gpa, .{ .path = "M.beni", .source = source });

    var p = try TestProject.initWith(gpa, modules.items, .{
        .phases = Session.check_phases,
        .keep_type_stores = true,
    });
    defer p.deinit();
    const m = p.module("M").?;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try dump_types.write(
        &out.writer,
        gpa,
        "M",
        p.session.artifacts.bir(p.session.graph.moduleFile(m)),
        &p.session.checked.modules[m.int()],
        &p.session.checked.types,
        &p.session.interner,
    );
    try testing.expectEqualStrings(expected, out.written());
}

/// Every diagnostic code the checker produced for `source`, in emission
/// order.
fn checkCodes(gpa: Allocator, source: [:0]const u8, out: *std.ArrayList(diagnostic.Code)) !void {
    var modules: std.ArrayList(TestProject.Module) = .empty;
    defer modules.deinit(gpa);
    try modules.appendSlice(gpa, &test_core);
    try modules.append(gpa, .{ .path = "M.beni", .source = source });
    var p = try TestProject.initWith(gpa, modules.items, .{ .phases = Session.check_phases });
    defer p.deinit();
    for (p.session.diagnostics.items) |d| try out.append(gpa, d.code);
}

fn expectCodes(expected: []const diagnostic.Code, source: [:0]const u8) !void {
    const gpa = testing.allocator;
    var codes: std.ArrayList(diagnostic.Code) = .empty;
    defer codes.deinit(gpa);
    try checkCodes(gpa, source, &codes);
    try testing.expectEqualSlices(diagnostic.Code, expected, codes.items);
}

test "inference: the principal type of an unannotated definition" {
    try expectTypes(
        \\module M
        \\  identity : a -> a
        \\    x : a
        \\  apply : (a -> b) -> a -> b
        \\    f : a -> b
        \\    x : a
        \\  count : List a -> Int
        \\    xs : List a
        \\
    ,
        \\identity x =
        \\    x
        \\
        \\
        \\apply f x =
        \\    f x
        \\
        \\
        \\count xs =
        \\    List.length xs
        \\
    );
}

test "generalisation: a let-bound name is used at two types in one body" {
    // The classic let-polymorphism check. `dup` is generalised when its
    // group closes, so the two uses instantiate it independently.
    try expectTypes(
        \\module M
        \\  both : ( ( number, number ), ( String, String ) )
        \\    dup : a -> ( a, a )
        \\    y : a
        \\
    ,
        \\both =
        \\    let
        \\        dup y =
        \\            ( y, y )
        \\    in
        \\    ( dup 1, dup "s" )
        \\
    );
}

test "generalisation: a lambda parameter is NOT generalised" {
    // A parameter belongs to the enclosing scope, so it may not be used at
    // two types. Without the rank discipline this would generalise `f` and
    // silently accept the program. (The code is `kind_mismatch` rather than
    // `type_mismatch` because the first use pinned `f`'s argument to
    // `number` and `String` is not one.)
    try expectCodes(&.{.kind_mismatch},
        \\useTwice f =
        \\    ( f 1, f "s" )
        \\
    );
}

test "sharing: instantiating a scheme with an internal repeat keeps it one variable" {
    // `let x = (y, y)` — the classic doubling case (design §7 #4). If the
    // copy memo were missing, the two components would come back as two
    // independent variables and `pair 1` would not force both to `number`.
    try expectTypes(
        \\module M
        \\  first : ( number, number )
        \\    pair : a -> ( a, a )
        \\    y : a
        \\
    ,
        \\first =
        \\    let
        \\        pair y =
        \\            ( y, y )
        \\    in
        \\    pair 1
        \\
    );
}

test "annotations: rigid variables hold the body to the promise" {
    try expectCodes(&.{.rigid_mismatch},
        \\pub wrong : a -> Int
        \\wrong value =
        \\    value
        \\
    );
    try expectCodes(&.{},
        \\pub right : a -> a
        \\right value =
        \\    value
        \\
    );
}

test "the kind lattice: number, appendable, and the pair that has no meet" {
    try expectTypes(
        \\module M
        \\  twice : number -> number
        \\    n : number
        \\  join : appendable -> appendable
        \\    a : appendable
        \\
    ,
        \\twice n =
        \\    n + n
        \\
        \\
        \\join a =
        \\    a ++ a
        \\
    );
    // `number ⊓ appendable = ⊥` (checker.md §6.2).
    try expectCodes(&.{.kind_mismatch},
        \\both x =
        \\    x + x ++ x
        \\
    );
    // A kind that meets a type outside its set.
    try expectCodes(&.{.kind_mismatch},
        \\bad c =
        \\    c ++ 'a'
        \\
    );
}

test "records: access is open, a literal is closed, an update keeps the base's type" {
    try expectTypes(
        \\module M
        \\  name : { r | name : a } -> a
        \\    r : { r | name : a }
        \\  bump : { r | count : number } -> { r | count : number }
        \\    r : { r | count : number }
        \\  literal : { a : number, b : String }
        \\
    ,
        \\name r =
        \\    r.name
        \\
        \\
        \\bump r =
        \\    { r | count = r.count + 1 }
        \\
        \\
        \\literal =
        \\    { a = 1, b = "x" }
        \\
    );
}

test "records: the four-way field partition" {
    // Two closed records that differ in both directions, one that is
    // missing a field the other requires, and one that has an extra.
    try expectCodes(&.{.unknown_field},
        \\pub type alias P =
        \\    { x : Int }
        \\
        \\
        \\pub p : P
        \\p =
        \\    { x = 1, y = 2 }
        \\
    );
    try expectCodes(&.{.missing_field},
        \\pub type alias P =
        \\    { x : Int, y : Int }
        \\
        \\
        \\pub p : P
        \\p =
        \\    { x = 1 }
        \\
    );
    // Two OPEN records merge: each side grows the fields the other has, so
    // one parameter ends up carrying both.
    try expectTypes(
        \\module M
        \\  merge : { r | a : a, c : b } -> a
        \\    r : { r | a : a, c : b }
        \\    left : a
        \\    right : b
        \\
    ,
        \\merge r =
        \\    let
        \\        left =
        \\            r.a
        \\
        \\        right =
        \\            r.c
        \\    in
        \\    left
        \\
    );
}

test "aliases are printed by name and never expanded away" {
    try expectTypes(
        \\module M
        \\  origin : Point
        \\  shift : Point -> Point
        \\    p : Point
        \\
    ,
        \\pub type alias Point =
        \\    { x : Int, y : Int }
        \\
        \\
        \\pub origin : Point
        \\origin =
        \\    { x = 0, y = 0 }
        \\
        \\
        \\pub shift : Point -> Point
        \\shift p =
        \\    { p | x = p.x + 1 }
        \\
    );
}

test "poisoning: one mistake yields one message" {
    // Three uses of a value whose type could not be worked out. Without the
    // `err` content merging silently, each use would report again
    // (research/02 §6).
    try expectCodes(&.{.type_mismatch},
        \\pub broken : Int
        \\broken =
        \\    "not an int"
        \\
        \\
        \\pub a : Int
        \\a =
        \\    broken + 1
        \\
        \\
        \\pub b : Int
        \\b =
        \\    broken * 2
        \\
    );
}

test "the occurs check fires once, at the binding" {
    try expectCodes(&.{.infinite_type},
        \\selfApply f =
        \\    f f
        \\
    );
}

test "obligations: equatable, interpolatable and tuple_index" {
    try expectCodes(&.{.not_equatable},
        \\pub same : (Int -> Int) -> (Int -> Int) -> Bool
        \\same f g =
        \\    f == g
        \\
    );
    try expectCodes(&.{.not_interpolatable},
        \\pub show : List Int -> String
        \\show xs =
        \\    "xs: ${xs}"
        \\
    );
    try expectCodes(&.{.ambiguous_interpolation},
        \\show value =
        \\    "value: ${value}"
        \\
    );
    try expectCodes(&.{.ambiguous_tuple},
        \\firstOf t =
        \\    t.0
        \\
    );
    try expectCodes(&.{.tuple_index_out_of_range},
        \\pub third : ( Int, Int ) -> Int
        \\third t =
        \\    t.2
        \\
    );
    // An `equatable` obligation that is SATISFIED leaves no trace, and a
    // `number` interpolation needs no annotation: `Int` and `Float` are
    // both on the list.
    try expectCodes(&.{},
        \\pub same : Int -> Int -> Bool
        \\same a b =
        \\    a == b
        \\
        \\
        \\pub show : Int -> String
        \\show n =
        \\    "n: ${n}"
        \\
    );
}

test "binding groups: mutual recursion shares one generalisation" {
    try expectTypes(
        \\module M
        \\  isEven : number -> Bool
        \\    n : number
        \\  isOdd : number -> Bool
        \\    n : number
        \\
    ,
        \\isEven n =
        \\    if n < 1 then
        \\        True
        \\    else
        \\        isOdd (n - 1)
        \\
        \\
        \\isOdd n =
        \\    if n < 1 then
        \\        False
        \\    else
        \\        isEven (n - 1)
        \\
    );
}

test "`?` picks Result or Maybe by shape, and refuses when it is neither" {
    try expectTypes(
        \\module M
        \\  step : Result String Int -> Result String Int
        \\    r : Result String Int
        \\    v : Int
        \\
    ,
        \\pub step : Result String Int -> Result String Int
        \\step r =
        \\    let
        \\        v =
        \\            r?
        \\    in
        \\    Ok (v + 1)
        \\
    );
    try expectTypes(
        \\module M
        \\  step : Maybe Int -> Maybe Int
        \\    m : Maybe Int
        \\    v : Int
        \\
    ,
        \\pub step : Maybe Int -> Maybe Int
        \\step m =
        \\    let
        \\        v =
        \\            m?
        \\    in
        \\    Just (v + 1)
        \\
    );
    try expectCodes(&.{.try_shape},
        \\pub step : Int -> Result String Int
        \\step n =
        \\    Ok (n? + 1)
        \\
    );
}

test "the arity rule of §8.3 fires before the generic mismatch" {
    try expectCodes(&.{.too_few_args},
        \\pub best : Int
        \\best =
        \\    max 1
        \\
    );
    try expectCodes(&.{.too_many_args},
        \\pub best : Int
        \\best =
        \\    max 1 2 3
        \\
    );
    try expectCodes(&.{.not_a_function},
        \\pub limit : Int
        \\limit =
        \\    1
        \\
        \\
        \\pub best : Int
        \\best =
        \\    limit 2
        \\
    );
    // A partial application flowing into something that has not decided it
    // is a value is NOT an error: that is what currying is for.
    try expectCodes(&.{},
        \\pub bump : List Int -> List Int
        \\bump xs =
        \\    List.map (max 1) xs
        \\
    );
}

test "a module with a type error still produces an interface" {
    const gpa = testing.allocator;
    var modules: std.ArrayList(TestProject.Module) = .empty;
    defer modules.deinit(gpa);
    try modules.appendSlice(gpa, &test_core);
    // `bad` is UNANNOTATED: an annotated declaration keeps its annotation
    // even when the body disagrees, because the annotation is what
    // dependents were promised (checker.md §6.1). `<error>` is for the case
    // where there is nothing else to say.
    try modules.append(gpa, .{ .path = "M.beni", .source =
        \\pub good : Int -> Int
        \\good n =
        \\    n
        \\
        \\
        \\pub bad =
        \\    "no" + 1
        \\
    });
    var p = try TestProject.initWith(gpa, modules.items, .{ .phases = Session.check_phases });
    defer p.deinit();

    const m = p.module("M").?;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try @import("../dump/interface.zig").write(
        &out.writer,
        gpa,
        "M",
        &p.session.resolution.interfaces[m.int()],
        &p.session.checked.types,
        &p.session.interner,
    );
    // The declaration that failed is `<error>`; the one that did not is
    // still there for dependents to check against (checker.md §7).
    try testing.expectEqualStrings(
        \\module M
        \\  value bad : <error>
        \\  value good : Int -> Int
        \\
    , out.written());
}

test "binding groups are solved dependencies first, so a call to an inferred helper is checked" {
    // The regression: `sccGroups` emitted Tarjan's components highest id
    // first, and with edges pointing dependent -> dependency that is
    // DEPENDENTS first. The caller was then checked while the callee's
    // scheme was still unset, `instantiate` poisoned the callee, and the
    // call was silently accepted. Both source orders, because the bug did
    // not depend on one.
    try expectCodes(&.{.type_mismatch},
        \\helper n =
        \\    n + 1
        \\
        \\
        \\pub bad : Int
        \\bad =
        \\    helper "s"
        \\
    );
    try expectCodes(&.{.type_mismatch},
        \\pub bad : Int
        \\bad =
        \\    helper "s"
        \\
        \\
        \\helper n =
        \\    n + 1
        \\
    );
    // And the same for `let`: a sibling binding defined after its user is
    // still generalised before the user is solved.
    // Locals print in BINDING order, which is the source order of the
    // `let`, not the dependency order the groups were solved in.
    try expectTypes(
        \\module M
        \\  useAfter : ( number, String )
        \\    both : ( number2, String )
        \\    idf : a -> a
        \\    x : a
        \\
    ,
        \\useAfter =
        \\    let
        \\        both =
        \\            ( idf 1, idf "s" )
        \\
        \\        idf x =
        \\            x
        \\    in
        \\    both
        \\
    );
}

test "unifying two cyclic types merges a pair that is already one root" {
    // The regression: `unifyFlat` unifies children BEFORE merging the two
    // roots (so a message can print two different types), and a recursive
    // type makes an inner unification merge the pair first. `merge` then
    // got two equal roots and tripped its own assertion — a compiler crash
    // on ordinary source.
    try expectCodes(&.{.infinite_type},
        \\pub two x y =
        \\    let
        \\        r =
        \\            [ x, y ]
        \\
        \\        p =
        \\            x x
        \\
        \\        q =
        \\            y y
        \\    in
        \\    p
        \\
    );
}

test "a local index is relative to its declaration, in every consumer" {
    // The regression: two places indexed the module-wide `bir.locals` with
    // a declaration-relative index, so everything after the first
    // declaration saw another declaration's names. In a record pattern
    // that is not cosmetic — the name IS the field being matched.
    try expectCodes(&.{},
        \\pub first : Int -> Int
        \\first zzz =
        \\    zzz
        \\
        \\
        \\pub second : { name : Int, other : Int } -> Int
        \\second rec =
        \\    let
        \\        { name } =
        \\            rec
        \\    in
        \\    name
        \\
    );
}

test "fuzz: the whole pipeline through the checker never panics" {
    // The checker eats a Bir TREE, not bytes, so its harness is the whole
    // front end plus the checker over arbitrary input: whatever the lexer,
    // the parser and lowering make of these bytes is what the checker has
    // to survive. Contract: no panic, and no diagnostic is required.
    try testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [1024]u8 = undefined;
            const len = smith.sliceWithHash(&buf, 0xC4EC6);
            const source = try testing.allocator.dupeZ(u8, buf[0..len]);
            defer testing.allocator.free(source);
            var codes: std.ArrayList(diagnostic.Code) = .empty;
            defer codes.deinit(testing.allocator);
            checkCodes(testing.allocator, source, &codes) catch |err| switch (err) {
                error.OutOfMemory => return,
                else => return err,
            };
        }
    }.testOne, .{});
}
