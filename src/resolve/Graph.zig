//! The module graph (docs/design/checker.md §4.1–§4.4): which modules exist,
//! what each imports, and the order they may be checked in.
//!
//! A module's identity is `(package, module name)`, not the name alone
//! (`fast-compiler.md` §3.1, "Project model"): the user's package and core
//! may each have a `List`, and an import resolves in the importing module's
//! own package first, then `core`. That lookup is the only thing the rest
//! of the compiler asks this structure, and it is why the index is keyed by
//! the pair. It was a hash map on the argument that a `Symbol` is a sparse
//! key; it is asked once per qualified REFERENCE, three probes deep, and
//! the perf study of 2026-09-27 (item 4) measured it at 12 % of a warm
//! `check`. It is now an array indexed by the module-name symbol — sized by
//! the largest one, kilobytes — with the precedence precomputed per name
//! (`name_rows`, `rows`), so a lookup is a bounds check and two loads.
//!
//! Three things come out of one pass:
//!
//!   - **Edges.** One per explicit import and one per prelude row, because
//!     the prelude IS an import of core (language.md Appendix A) and the
//!     schedule has to know it. Deduplicated per module, in import order.
//!   - **Cycles.** Tarjan's SCC over the edges. Every non-trivial component
//!     is one `import_cycle`, reported once, on the lexically first module
//!     of the cycle, naming the whole cycle in the order the imports run —
//!     `A → B → C → A`, found by walking the component from that first
//!     module. The members are POISONED: their declarations get error types
//!     and no further diagnostic (checker.md §4.3), which is what stops one
//!     bad edge from producing a diagnostic per module in the loop.
//!   - **Order.** The stable topological order of §4.4: Kahn over the
//!     CONDENSATION, picking the ready component whose first member is
//!     lexically smallest, then its members in `(package, path)` order. The
//!     condensation is what makes this total even with cycles present, and
//!     picking by name rather than by discovery makes it a function of the
//!     input rather than of the traversal.
//!
//! **A module never imports itself.** Every operator inside `Basics`
//! desugars to a reference to `Basics` (language.md §6.5), so `Basics`'s Bir
//! is full of references to `Basics`. Those resolve to its OWN declarations,
//! add no edge and are never a cycle (checker.md §4.3). The prelude rows are
//! filtered the same way, so `List` does not depend on `List`.
//!
//! **A prelude row is an edge only when the module uses a name from it.**
//! checker.md §4.3 says "prelude imports are edges to core", and taken
//! literally that makes the standard library cyclic with itself: lowering
//! gives EVERY file all seven prelude rows (language.md Appendix A), so
//! `Basics` would depend on `List` and `List` on `Basics` before a line of
//! either was read. The prelude is not an import anyone wrote — it is a
//! fallback name table inside the compiler — so what makes it a dependency
//! is a name actually resolved through it, which is exactly what lowering
//! already recorded in `refs` (the dead-code-elimination edges of
//! `fast-compiler.md` §9.1). An import the author DID write is always an
//! edge, used or not: it is a statement about the project, and reporting
//! `unknown_module` for it is the point.
//!
//! **A type is a dependency too** (`static-dispatch-spike.md` §6.8). `x.m`
//! resolves in the module that DECLARES `x`'s type, so a module that can
//! SEE a type depends on that type's module whether or not it names it.
//! Naming one is already an edge and one reached through a dependency's
//! interface is an edge transitively; the gap is the type the checker
//! MINTS for an instruction that names nothing — a number, a list, a
//! string, a comparison. `mintedModules` is that third source of edges,
//! and its doc comment carries the argument in full.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diagnostic = @import("diagnostic");
const Artifacts = @import("../Artifacts.zig");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const SourceStore = @import("../SourceStore.zig");

const Graph = @This();

pub const Symbol = InternPool.Symbol;
pub const Package = SourceStore.Package;

/// A module of the graph. Dense, assigned in file-index order, so every
/// per-module array is indexed by this and nothing is keyed by a name.
pub const Index = enum(u32) {
    _,

    pub fn int(i: Index) u32 {
        return @intFromEnum(i);
    }
};

/// Owned. One per module, in file-index order.
modules: std.MultiArrayList(Module).Slice,
/// Owned. `modules[m].deps_start..deps_end` are `m`'s dependencies, each
/// once, in the order its import table lists them.
deps: []const Index,
/// Owned. Every module exactly once, dependencies before dependents
/// (§4.4). Members of a cycle keep a position so every module is visited.
order: []const Index,
/// Owned. Graph-level diagnostics, each pointing at a file and a token.
diagnostics: []const Item,
/// The `(package, name)` index, as arrays and not a hash map
/// (`fast-compiler.md` §5: a dense id indexes an array; perf study
/// 2026-09-27 item 4). Owned; lives as long as the graph because `Resolve`
/// looks modules up through it, once per qualified reference.
///
/// `name_rows[symbol]` is the row of a module NAME, or `no_row` for a
/// symbol no module is named — sized by the largest module-name symbol, so
/// kilobytes. `rows[row]` holds, per package, the module that package
/// declares under the name (`exact`, what `find` answers) and the module a
/// reference FROM that package resolves to (`visible`, `lookup`'s
/// precedence computed once at build).
name_rows: []u32,
rows: []Row,
/// Owned. The members named by every `import_cycle` item, in cycle order,
/// back to back; an item's `cycle_start..cycle_end` slices this.
cycle_members: []const Index,

pub const Module = struct {
    file: SourceStore.Index,
    package: Package,
    /// The module's name, interned: `Json.Decode` for
    /// `src/Json/Decode.beni`.
    name: Symbol,
    /// A member of an import cycle, or a module that failed to be named.
    /// Its declarations are error types and it produces no further
    /// diagnostics (checker.md §4.3).
    poisoned: bool,
    deps_start: u32,
    deps_end: u32,
};

const package_count = @typeInfo(Package).@"enum".fields.len;
const no_row = std.math.maxInt(u32);
const no_module = std.math.maxInt(u32);

/// One module name's answers, indexed by `@intFromEnum(Package)`;
/// `no_module` where there is none.
pub const Row = struct {
    exact: [package_count]u32 = @splat(no_module),
    visible: [package_count]u32 = @splat(no_module),
};

/// A graph diagnostic before it is rendered: which file, which token, and
/// for `import_cycle` the modules of the cycle in order.
pub const Item = struct {
    code: diagnostic.Code,
    file: SourceStore.Index,
    /// Token index into `file`'s token list.
    token: u32,
    /// `import_cycle`: `cycle_start..cycle_end` into `cycle_members`.
    /// `duplicate_module`: `cycle_start` is the module that already had
    /// the name, `cycle_end` is `cycle_start + 1`.
    cycle_start: u32 = 0,
    cycle_end: u32 = 0,
};

pub const empty: Graph = .{
    .modules = .empty,
    .deps = &.{},
    .order = &.{},
    .diagnostics = &.{},
    .name_rows = &.{},
    .rows = &.{},
    .cycle_members = &.{},
};

pub fn deinit(g: *Graph, gpa: Allocator) void {
    g.modules.deinit(gpa);
    gpa.free(g.deps);
    gpa.free(g.order);
    gpa.free(g.diagnostics);
    gpa.free(g.cycle_members);
    gpa.free(g.name_rows);
    gpa.free(g.rows);
    g.* = undefined;
}

pub fn count(g: *const Graph) u32 {
    return @intCast(g.modules.len);
}

pub fn module(g: *const Graph, i: Index) Module {
    return g.modules.get(i.int());
}

/// Module `i`'s package: one column, where `module` builds the whole row —
/// the resolver asks it once per reference.
pub fn modulePackage(g: *const Graph, i: Index) Package {
    return g.modules.items(.package)[i.int()];
}

pub fn moduleFile(g: *const Graph, i: Index) SourceStore.Index {
    return g.modules.items(.file)[i.int()];
}

pub fn moduleName(g: *const Graph, i: Index) Symbol {
    return g.modules.items(.name)[i.int()];
}

pub fn isPoisoned(g: *const Graph, i: Index) bool {
    return g.modules.items(.poisoned)[i.int()];
}

pub fn dependencies(g: *const Graph, i: Index) []const Index {
    const m = g.modules.get(i.int());
    return g.deps[m.deps_start..m.deps_end];
}

/// The module `(package, name)` EXACTLY, with none of `lookup`'s fallback:
/// what an `Interface.TypeRef` names is the module that DECLARES a type,
/// already decided, so falling back to another package would resolve a
/// stale reference onto the wrong module instead of poisoning it.
pub fn find(g: *const Graph, package: Package, name: Symbol) ?Index {
    const row = g.rowOf(name) orelse return null;
    return moduleOrNull(row.exact[@intFromEnum(package)]);
}

fn rowOf(g: *const Graph, name: Symbol) ?*const Row {
    return &g.rows[g.rowIndex(name) orelse return null];
}

fn moduleOrNull(m: u32) ?Index {
    return if (m == no_module) null else @enumFromInt(m);
}

/// Resolve `name` as seen from a module of `from`: its own package first,
/// then the platform package of this build, then `core` (checker.md §2,
/// boundary.md §5.3). An `app` module named like a core module therefore
/// shadows it for the whole project, with no diagnostic — the same rule as
/// a top-level name shadowing a prelude name.
///
/// The platform sits between the two because `boundary.md` §5.3 makes a
/// build a PAIR of entry point and platform: a module that names a
/// capability the chosen platform does not offer must fail to resolve,
/// which is the diagnostic §5.3 wants instead of a runtime surprise, and
/// that only works if the platform's modules are in the search path at all.
///
/// The precedence is applied once per name when the graph is built
/// (`Row.visible`), so this is a bounds check and two loads.
pub fn lookup(g: *const Graph, from: Package, name: Symbol) ?Index {
    const row = g.rowOf(name) orelse return null;
    return moduleOrNull(row.visible[@intFromEnum(from)]);
}

/// `lookup`'s precedence over one row's `exact` answers.
fn visibleFrom(exact: [package_count]u32, from: Package) u32 {
    if (exact[@intFromEnum(from)] != no_module) return exact[@intFromEnum(from)];
    if (from != .platform and exact[@intFromEnum(Package.platform)] != no_module) return exact[@intFromEnum(Package.platform)];
    if (from != .core and exact[@intFromEnum(Package.core)] != no_module) return exact[@intFromEnum(Package.core)];
    return no_module;
}

/// The number of edges, for the profile counter.
pub fn edgeCount(g: *const Graph) u32 {
    return @intCast(g.deps.len);
}

// ---------------------------------------------------------------------------
// Building
// ---------------------------------------------------------------------------

/// Build the graph from every lowered file. Serial, after the interner
/// merge, so the module names can be interned into the global pool and the
/// Birs' symbols are already global.
///
/// Files with an invalid module path (language.md §1) are not modules: they
/// have been reported already and nothing can import them.
pub fn build(
    gpa: Allocator,
    scratch: Allocator,
    store: *const SourceStore,
    artifacts: *const Artifacts,
    interner: *InternPool.Global,
) Allocator.Error!Graph {
    var g: Graph = .empty;
    errdefer g.deinit(gpa);
    var modules: std.MultiArrayList(Module) = .empty;
    errdefer modules.deinit(gpa);

    var deps: std.ArrayList(Index) = .empty;
    errdefer deps.deinit(gpa);
    var diagnostics: std.ArrayList(Item) = .empty;
    errdefer diagnostics.deinit(gpa);
    var cycle_members: std.ArrayList(Index) = .empty;
    errdefer cycle_members.deinit(gpa);

    // 1. Name every module and index it. File order is path order, so the
    //    FIRST file to claim a `(package, name)` keeps it and any later one
    //    is `duplicate_module` — deterministic without a tie-break rule.
    var name_limit: u32 = 0;
    for (0..store.count()) |i| {
        const file: SourceStore.Index = @enumFromInt(i);
        if (!store.modulePathValid(file)) continue;
        const name = try interner.getOrPut(gpa, store.moduleName(file));
        name_limit = @max(name_limit, @intFromEnum(name) + 1);
        try modules.append(gpa, .{
            .file = file,
            .package = store.package(file),
            .name = name,
            .poisoned = false,
            .deps_start = 0,
            .deps_end = 0,
        });
    }
    g.name_rows = try gpa.alloc(u32, name_limit);
    @memset(g.name_rows, no_row);
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(gpa);
    for (modules.items(.name), modules.items(.package), modules.items(.file), 0..) |name, pkg, file, i| {
        const slot = &g.name_rows[@intFromEnum(name)];
        if (slot.* == no_row) {
            slot.* = @intCast(rows.items.len);
            try rows.append(gpa, .{});
        }
        const exact = &rows.items[slot.*].exact[@intFromEnum(pkg)];
        if (exact.* != no_module) {
            try diagnostics.append(gpa, .{
                .code = .duplicate_module,
                .file = file,
                .token = 0,
                .cycle_start = exact.*,
                .cycle_end = exact.* + 1,
            });
            modules.items(.poisoned)[i] = true;
        } else {
            exact.* = @intCast(i);
        }
    }
    for (rows.items) |*row| {
        for (&row.visible, 0..) |*v, from| v.* = visibleFrom(row.exact, @enumFromInt(from));
    }
    g.rows = try rows.toOwnedSlice(gpa);
    g.modules = modules.toOwnedSlice();

    // 2. Edges: one per import the module uses, then one per module that
    //    declares a type it can see but never names (§6.8). A module's
    //    references to ITSELF add no edge (see the header).
    //    Both sets a module builds here — the module names its refs use,
    //    and its dependencies so far — are STAMPS (`i + 1`) in arrays
    //    indexed by name row and by module, not scans of a list: a module
    //    importing n modules would be n² here.
    const packages = g.modules.items(.package);
    const used_stamp = try scratch.alloc(u32, g.rows.len);
    @memset(used_stamp, 0);
    const dep_stamp = try scratch.alloc(u32, g.modules.len);
    @memset(dep_stamp, 0);
    for (0..g.modules.len) |i| {
        const index: Index = @enumFromInt(i);
        const stamp: u32 = @intCast(i + 1);
        const start: u32 = @intCast(deps.items.len);
        const file = g.modules.items(.file)[i];
        const bir = artifacts.bir(file);
        g.markReferencedModules(bir, used_stamp, stamp);
        for (bir.imports) |imp| {
            const module_name = bir.symbol(imp.module);
            // An unused prelude row adds no edge. One whose name no module
            // has would find no target below either, and says nothing.
            if (imp.prelude) {
                const row = g.rowIndex(module_name) orelse continue;
                if (used_stamp[row] != stamp) continue;
            }
            const target = g.lookup(packages[i], module_name) orelse {
                // The prelude names modules the compiler guarantees; a
                // missing one means core itself is missing or broken, and
                // that is not the importer's fault to report here. The
                // reference sites get `unknown_module_alias` from
                // `Resolve` instead (checker.md §4.5).
                if (!imp.prelude) {
                    try diagnostics.append(gpa, .{ .code = .unknown_module, .file = file, .token = imp.name_token });
                }
                continue;
            };
            // A module's references to ITSELF add no edge and are never a
            // cycle (checker.md §4.3): every operator inside `Basics`
            // produces one.
            if (target == index) continue;
            if (dep_stamp[target.int()] == stamp) continue;
            dep_stamp[target.int()] = stamp;
            try deps.append(gpa, target);
        }
        // The types the checker MINTS for this module
        // (`static-dispatch-spike.md` §6.8). Resolved against `core` and
        // not against the module's own package, because that is where
        // `check/Types.findWellKnown` resolves them: a user module called
        // `List` shadows the NAME for its dependents, and does not move
        // the type a list literal has out from under the checker — so the
        // two must not disagree about which module the edge is to.
        const minted = mintedModules(bir);
        for (minted_modules, 0..) |w, bit| {
            if (minted & (@as(u8, 1) << @intCast(bit)) == 0) continue;
            const target = g.lookup(.core, w.symbol()) orelse continue;
            if (target == index) continue;
            if (dep_stamp[target.int()] == stamp) continue;
            dep_stamp[target.int()] = stamp;
            try deps.append(gpa, target);
        }
        g.modules.items(.deps_start)[i] = start;
        g.modules.items(.deps_end)[i] = @intCast(deps.items.len);
    }
    g.deps = try deps.toOwnedSlice(gpa);

    // 3. Components, cycles and the order.
    try g.scheduleAndReportCycles(gpa, scratch, artifacts, &diagnostics, &cycle_members);

    g.diagnostics = try diagnostics.toOwnedSlice(gpa);
    g.cycle_members = try cycle_members.toOwnedSlice(gpa);
    return g;
}

/// Stamp, in `used` (indexed by name row), the module names a file
/// actually names something from, from its `refs` table. A name no module
/// has has no row and cannot be an edge, so it is not recorded.
///
/// A type this file WRITES is in here too: a `type_import` or a
/// `type_qualified` records an `import_type` ref, which is the
/// `static-dispatch-spike.md` §6.8 edge for every type with a name on it.
/// `mintedModules` below covers the types that never get one.
fn markReferencedModules(g: *const Graph, bir: *const Bir, used: []u32, stamp: u32) void {
    for (bir.refs) |ref| {
        switch (ref.kind) {
            .import_value, .import_ctor, .import_type, .import_schema => {},
            .top_value, .top_ctor, .top_type, .top_schema => continue,
        }
        const row = g.rowIndex(bir.symbol(@enumFromInt(ref.a))) orelse continue;
        used[row] = stamp;
    }
}

/// The row of module name `name` in `rows`, or null when no module has it.
fn rowIndex(g: *const Graph, name: Symbol) ?u32 {
    const s = @intFromEnum(name);
    if (s >= g.name_rows.len or g.name_rows[s] == no_row) return null;
    return g.name_rows[s];
}

/// Which of `minted_modules` declare a type this file's instructions mint
/// without naming it (`static-dispatch-spike.md` §6.8), as a bit set.
///
/// `x.m` resolves in the module that DECLARES `x`'s type (§1.2), so that
/// module has to be checked before this one or the lookup reads a
/// half-built interface — a data race, not a wrong answer. A type this
/// file names is already an edge (see `referencedModules`), and a type
/// that arrives through a dependency's interface is covered transitively,
/// because a module starts only once every dependency has FINISHED and
/// those only once theirs had. What neither covers is the type an
/// instruction mints out of nothing: `1` is a `Basics.Int`, `[ … ]` a
/// `List.List`, `"…"` a `String.String`, and — since §1.4 gives
/// `method_call` no `refs` edge — `a < b` is a `Basics.Bool` written
/// without the word `Basics`. A module of nothing but literals has no
/// import, no ref and, before this, no dependency at all: `--jobs=8` ran
/// it beside the very core modules its methods resolve in.
///
/// The invariant the three together buy, by induction over the order:
/// **every nominal type visible while a module is checked is declared by
/// that module itself or by a transitive dependency of it.**
///
/// **Inside core this rule bites.** A minted edge always points into
/// `core`, so it can never make a user project cyclic — but a string
/// literal in `Basics` would make `Basics` depend on `String`, which
/// already depends on `Basics`, and the author would get an
/// `import_cycle` for writing a literal. No core module mints a type from
/// a module that names it back today; a rewrite of core has to keep it
/// that way, or this rule needs an exemption stated in §6.8 first.
///
/// One pass over the tag column — the whole point of the SoA — reading a
/// 256-byte table instead of branching per instruction, four accumulators
/// deep so no iteration waits on the last one's OR. Measured on
/// `zig build bench -- --generate=100000`: 635 modules, 202k instructions,
/// 3837 edges before and 3938 after, `resolve` 4.93 ms before and 4.85 ms
/// after (best of twelve, interleaved ABBA against a build of the parent
/// commit) — the scan does not show. The one accumulator the first draft
/// used, with an early exit per instruction, cost a consistent 0.4 ms:
/// every instruction waited on the previous one's OR.
fn mintedModules(bir: *const Bir) u8 {
    const tags = bir.insts.items(.tag);
    var acc: [4]u8 = @splat(0);
    var i: usize = 0;
    while (i + 4 <= tags.len) : (i += 4) {
        inline for (0..4) |k| acc[k] |= minted_bits[@intFromEnum(tags[i + k])];
    }
    var seen = acc[0] | acc[1] | acc[2] | acc[3];
    while (i < tags.len) : (i += 1) seen |= minted_bits[@intFromEnum(tags[i])];
    return seen;
}

/// The modules that declare a well-known type, one bit each in the order
/// `minted_bits` uses. `check/Types.findWellKnown` names the same six.
const minted_modules = [_]InternPool.WellKnown{ .Basics, .List, .String, .Char, .Maybe, .Result, .Schema };

/// Which of `minted_modules` an instruction of each tag makes a dependency.
/// `Int`, `Float` and `Bool` all live in `Basics`: a comparison is a
/// `method_call` whose result is `Bool` (§3.1) and which records no `refs`
/// edge of its own (§1.4), while `if` is a `case` on `Basics.True` — that
/// one DOES record a ref, and costs nothing to name twice.
const minted_bits: [256]u8 = blk: {
    const basics: u8 = 1 << 0;
    const list: u8 = 1 << 1;
    const string: u8 = 1 << 2;
    const char: u8 = 1 << 3;
    // `e?` is a `Maybe` shape or a `Result` shape, and WHICH is the
    // checker's decision on this instruction — so both modules are a
    // dependency of a file that writes one.
    const maybe_result: u8 = (1 << 4) | (1 << 5);
    const schema: u8 = 1 << 6;
    var table: [256]u8 = @splat(0);
    for ([_]struct { Bir.Inst.Tag, u8 }{
        .{ .int, basics },
        .{ .float, basics },
        .{ .pat_int, basics },
        .{ .method_call, basics },
        .{ .type_dispatch, basics },
        .{ .list, list },
        .{ .pat_list, list },
        .{ .pat_cons, list },
        .{ .string, string },
        .{ .chunk, string },
        .{ .interp, string },
        .{ .pat_string, string },
        .{ .char, char },
        .{ .pat_char, char },
        .{ .@"try", maybe_result },
        .{ .schema_ref, schema },
        .{ .schema_app, schema },
        .{ .schema_record, schema },
        .{ .schema_field, schema },
        .{ .schema_value, schema },
        .{ .schema_tagged, schema },
        .{ .schema_variant, schema },
        .{ .schema_type_ref, schema },
        .{ .schema_value_ref, schema },
        .{ .schema_ctor_ref, schema },
        .{ .schema_type_top, schema },
        .{ .ext_schema_type, schema },
        .{ .schema_member_top, schema },
        .{ .ext_schema_member, schema },
        .{ .schema_ctor_top, schema },
        .{ .ext_schema_ctor, schema },
        .{ .schema_parameter, schema },
        .{ .schema_primitive, schema },
        .{ .schema_target_top, schema },
        .{ .ext_schema_target, schema },
    }) |entry| table[@intFromEnum(entry[0])] = entry[1];
    break :blk table;
};

/// Tarjan's SCC, then Kahn over the condensation. Both are iterative: a
/// project is allowed to be 100k lines deep in imports and the compiler may
/// not put that on the C stack.
fn scheduleAndReportCycles(
    g: *Graph,
    gpa: Allocator,
    scratch: Allocator,
    artifacts: *const Artifacts,
    diagnostics: *std.ArrayList(Item),
    cycle_members: *std.ArrayList(Index),
) Allocator.Error!void {
    const n = g.modules.len;
    var t: Tarjan = try .init(scratch, n);
    try t.run(scratch, g);
    const component = t.component;
    const component_count = t.component_count;

    // Members of each component, grouped: the condensation's node `c` owns
    // `members[starts[c]..starts[c + 1]]`, filled in module-index order,
    // which is `(package, path)` order because that is how files are
    // numbered.
    const starts = try scratch.alloc(u32, component_count + 1);
    @memset(starts, 0);
    for (component) |c| starts[c + 1] += 1;
    for (1..component_count + 1) |c| starts[c] += starts[c - 1];
    const members = try scratch.alloc(Index, n);
    const cursor = try scratch.alloc(u32, component_count);
    @memcpy(cursor, starts[0..component_count]);
    for (0..n) |i| {
        const c = component[i];
        members[cursor[c]] = @enumFromInt(i);
        cursor[c] += 1;
    }

    // Report each cycle once and poison its members.
    for (0..component_count) |c| {
        const group = members[starts[c]..starts[c + 1]];
        if (group.len < 2) continue;
        for (group) |m| g.modules.items(.poisoned)[m.int()] = true;
        const first = group[0]; // lexically first: module order is path order
        const cycle_start: u32 = @intCast(cycle_members.items.len);
        try g.appendCyclePath(gpa, scratch, component, group, first, cycle_members);
        try diagnostics.append(gpa, .{
            .code = .import_cycle,
            .file = g.moduleFile(first),
            .token = g.cycleImportToken(artifacts, first, cycle_members.items[cycle_start + 1]),
            .cycle_start = cycle_start,
            .cycle_end = @intCast(cycle_members.items.len),
        });
    }

    // Kahn over the condensation. `in_degree[c]` counts the module-level
    // edges out of `c` that land in a DIFFERENT component, and `rdeps` is
    // that same edge set reversed — `c`'s dependents — so emitting `c`
    // decrements exactly the components that were waiting on it instead of
    // rescanning every module. Both sides are MULTISETS: a component that
    // reaches another through three modules is counted three times on each,
    // so the decrements cancel the increments exactly.
    //
    // The ready set is a min-heap keyed by a component's FIRST MEMBER,
    // which is its lexically smallest module — `members` is filled in
    // file-index order and files are numbered in `(package, path)` order.
    // A module belongs to exactly one component, so the key is unique and
    // the heap has no tie to break: the order is a function of the names
    // and never of the traversal (`fast-compiler.md` §10), which is the
    // same rule the previous linear scan for the smallest first member
    // implemented, and the emitted order is identical.
    //
    // Together this is O((n + E) log C) rather than the O(C × (n + E)) a
    // rescan per emitted component costs.
    const in_degree = try scratch.alloc(u32, component_count);
    @memset(in_degree, 0);
    // The reverse edges as a CSR: `rdeps[rstarts[c]..rstarts[c + 1]]` are
    // the components that depend on `c`, one entry per module-level edge.
    const rstarts = try scratch.alloc(u32, component_count + 1);
    @memset(rstarts, 0);
    var cross_edges: u32 = 0;
    for (0..n) |i| {
        const from = component[i];
        for (g.dependencies(@enumFromInt(i))) |d| {
            const to = component[d.int()];
            if (from == to) continue;
            in_degree[from] += 1;
            rstarts[to + 1] += 1;
            cross_edges += 1;
        }
    }
    for (1..component_count + 1) |c| rstarts[c] += rstarts[c - 1];
    const rdeps = try scratch.alloc(u32, cross_edges);
    const rcursor = try scratch.alloc(u32, component_count);
    @memcpy(rcursor, rstarts[0..component_count]);
    for (0..n) |i| {
        const from = component[i];
        for (g.dependencies(@enumFromInt(i))) |d| {
            const to = component[d.int()];
            if (from == to) continue;
            rdeps[rcursor[to]] = from;
            rcursor[to] += 1;
        }
    }

    const emitted = try scratch.alloc(bool, component_count);
    @memset(emitted, false);
    var order: std.ArrayList(Index) = .empty;
    errdefer order.deinit(gpa);
    try order.ensureTotalCapacity(gpa, n);

    // The heap holds first MEMBERS rather than component ids, so the key is
    // the element itself and `component[first]` recovers the component.
    var ready: ReadyQueue = .initContext({});
    defer ready.deinit(scratch);
    try ready.ensureTotalCapacity(scratch, component_count);
    for (0..component_count) |c| {
        if (in_degree[c] == 0) try ready.push(scratch, members[starts[c]].int());
    }
    var remaining = component_count;
    while (remaining > 0) {
        const first = ready.pop() orelse break;
        const c = component[first];
        emitted[c] = true;
        remaining -= 1;
        order.appendSliceAssumeCapacity(members[starts[c]..starts[c + 1]]);
        for (rdeps[rstarts[c]..rstarts[c + 1]]) |dependent| {
            in_degree[dependent] -= 1;
            if (in_degree[dependent] == 0) try ready.push(scratch, members[starts[dependent]].int());
        }
    }
    // Cannot happen: a condensation is acyclic, so as long as a component
    // is left, one of the remaining ones has in-degree zero and is in the
    // heap. If the heap ever did run dry early, emitting the rest in index
    // order keeps the compiler running rather than losing modules.
    if (remaining > 0) {
        for (0..component_count) |rest| {
            if (emitted[rest]) continue;
            emitted[rest] = true;
            order.appendSliceAssumeCapacity(members[starts[rest]..starts[rest + 1]]);
        }
    }
    g.order = try order.toOwnedSlice(gpa);
}

/// The ready set of the Kahn loop: a min-heap of module indices, each the
/// first member of a component whose dependencies have all been emitted.
const ReadyQueue = std.PriorityQueue(u32, void, orderByFirstMember);

fn orderByFirstMember(_: void, a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

/// Append one concrete cycle starting and ending at `from`: a depth-first
/// walk restricted to `from`'s component, taking edges in import order.
/// The result is what the diagnostic names — `A → B → C` — with the closing
/// edge back to `A` left implicit. `group` is the component's members, used
/// for the budget and for the fallback below.
///
/// **The walk is bounded.** `on_path` restricts it to SIMPLE paths, but a
/// node popped off the path may be entered again down another branch, so on
/// its own it enumerates simple paths and is worst-case exponential in the
/// size of a strongly connected component. The budget is therefore stated
/// in the input rather than as a constant: the walk may examine
/// `max_edge_visits` times as many edges as its component's members have
/// between them. A walk that finds the closing edge on its first descent —
/// which is every cycle anyone writes, since `A`'s import of `B` is
/// normally answered by `B`'s import of `A` — examines each of those edges
/// at most once, so the multiplier is room for a handful of dead ends and
/// nothing more, and the pass stays linear in the graph. Every push follows
/// an edge examination and every pop follows a push, so bounding the edge
/// examinations bounds the whole loop. On exhaustion nothing has been
/// appended and the fallback below names the component's members instead,
/// which is a weaker message but a true one.
fn appendCyclePath(
    g: *const Graph,
    gpa: Allocator,
    scratch: Allocator,
    component: []const u32,
    group: []const Index,
    from: Index,
    out: *std.ArrayList(Index),
) Allocator.Error!void {
    const c = component[from.int()];
    // How many times over the component's own edges the walk may look; see
    // the budget paragraph above.
    const max_edge_visits = 4;
    var budget: usize = 0;
    for (group) |m| budget += g.dependencies(m).len;
    budget *= max_edge_visits;
    const on_path = try scratch.alloc(bool, g.modules.len);
    @memset(on_path, false);
    var path: std.ArrayList(Index) = .empty;
    defer path.deinit(scratch);
    try path.append(scratch, from);
    on_path[from.int()] = true;
    // Iterative DFS with an explicit cursor per frame.
    var cursors: std.ArrayList(u32) = .empty;
    defer cursors.deinit(scratch);
    try cursors.append(scratch, 0);
    while (path.items.len > 0) {
        const node = path.items[path.items.len - 1];
        const edges = g.dependencies(node);
        const cursor = &cursors.items[cursors.items.len - 1];
        if (cursor.* >= edges.len) {
            on_path[node.int()] = false;
            _ = path.pop();
            _ = cursors.pop();
            continue;
        }
        if (budget == 0) break; // out of steps: fall through to `group`
        budget -= 1;
        const next = edges[cursor.*];
        cursor.* += 1;
        if (component[next.int()] != c) continue;
        if (next == from) {
            try out.appendSlice(gpa, path.items);
            return;
        }
        if (on_path[next.int()]) continue;
        on_path[next.int()] = true;
        try path.append(scratch, next);
        try cursors.append(scratch, 0);
    }
    // Strong connectivity guarantees a path back, so only the budget above
    // can land here; naming the component's members is still a true
    // statement about which modules are in the circle.
    try out.appendSlice(gpa, group);
}

/// The token in `from`'s source that imports `to`, so the cycle is reported
/// at the import that closes it rather than at line 1.
fn cycleImportToken(g: *const Graph, artifacts: *const Artifacts, from: Index, to: Index) u32 {
    const bir = artifacts.bir(g.moduleFile(from));
    const wanted = g.moduleName(to);
    for (bir.imports) |imp| {
        if (!imp.prelude and bir.symbol(imp.module) == wanted) return imp.name_token;
    }
    return 0;
}

/// Tarjan's strongly connected components, iterative. Components come out
/// in reverse topological order; the numbering is not used for ordering
/// (see `scheduleAndReportCycles`), only for grouping.
const Tarjan = struct {
    index: []u32,
    low: []u32,
    on_stack: []bool,
    component: []u32,
    stack: std.ArrayList(Index),
    next_index: u32 = 0,
    component_count: u32 = 0,

    const unvisited = std.math.maxInt(u32);

    fn init(scratch: Allocator, n: usize) Allocator.Error!Tarjan {
        const t: Tarjan = .{
            .index = try scratch.alloc(u32, n),
            .low = try scratch.alloc(u32, n),
            .on_stack = try scratch.alloc(bool, n),
            .component = try scratch.alloc(u32, n),
            .stack = .empty,
        };
        @memset(t.index, unvisited);
        @memset(t.on_stack, false);
        @memset(t.component, 0);
        return t;
    }

    fn run(t: *Tarjan, scratch: Allocator, g: *const Graph) Allocator.Error!void {
        var frames: std.ArrayList(Frame) = .empty;
        defer frames.deinit(scratch);
        for (0..g.modules.len) |root| {
            if (t.index[root] != unvisited) continue;
            try frames.append(scratch, .{ .node = @enumFromInt(root), .cursor = 0 });
            try t.visit(scratch, g, &frames);
        }
    }

    const Frame = struct { node: Index, cursor: u32 };

    fn visit(t: *Tarjan, scratch: Allocator, g: *const Graph, frames: *std.ArrayList(Frame)) Allocator.Error!void {
        while (frames.items.len > 0) {
            const frame = &frames.items[frames.items.len - 1];
            const v = frame.node.int();
            if (frame.cursor == 0) {
                t.index[v] = t.next_index;
                t.low[v] = t.next_index;
                t.next_index += 1;
                try t.stack.append(scratch, frame.node);
                t.on_stack[v] = true;
            }
            const edges = g.dependencies(frame.node);
            if (frame.cursor < edges.len) {
                const w = edges[frame.cursor];
                frame.cursor += 1;
                if (t.index[w.int()] == unvisited) {
                    try frames.append(scratch, .{ .node = w, .cursor = 0 });
                } else if (t.on_stack[w.int()]) {
                    t.low[v] = @min(t.low[v], t.index[w.int()]);
                }
                continue;
            }
            // Done with `v`: close a component, then fold into the parent.
            if (t.low[v] == t.index[v]) {
                while (true) {
                    const w = t.stack.pop().?;
                    t.on_stack[w.int()] = false;
                    t.component[w.int()] = t.component_count;
                    if (w.int() == v) break;
                }
                t.component_count += 1;
            }
            _ = frames.pop();
            if (frames.items.len > 0) {
                const parent = frames.items[frames.items.len - 1].node.int();
                t.low[parent] = @min(t.low[parent], t.low[v]);
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a chain of imports is a stable topological order and nothing is poisoned" {
    const TestProject = @import("TestProject.zig");
    var p = try TestProject.init(testing.allocator, &.{
        .{ .path = "A.beni", .source = "import B exposing (b)\n\n\npub a : Int\na =\n    b\n" },
        .{ .path = "B.beni", .source = "import C exposing (c)\n\n\npub b : Int\nb =\n    c\n" },
        .{ .path = "C.beni", .source = "pub c : Int\nc =\n    1\n" },
    });
    defer p.deinit();

    const order = try p.order(testing.allocator);
    defer testing.allocator.free(order);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "C", "B", "A" }), order);
    try testing.expectEqual(@as(u32, 3), p.graph().count());
    try testing.expectEqual(@as(u32, 2), p.graph().edgeCount());
    for (0..3) |i| try testing.expect(!p.graph().isPoisoned(@enumFromInt(i)));

    const a = p.module("A").?;
    try testing.expectEqualSlices(Index, &.{p.module("B").?}, p.graph().dependencies(a));
    try testing.expectEqualSlices(Index, &.{}, p.graph().dependencies(p.module("C").?));
}

test "independent modules are ordered by path, not by traversal" {
    const TestProject = @import("TestProject.zig");
    // `Z` imports nothing and `A` imports nothing; a depth-first schedule
    // would emit them in discovery order, which is not a property of the
    // source. The order is the file order, which IS.
    var p = try TestProject.init(testing.allocator, &.{
        .{ .path = "Z.beni", .source = "pub z : Int\nz =\n    1\n" },
        .{ .path = "A.beni", .source = "pub a : Int\na =\n    1\n" },
        .{ .path = "M.beni", .source = "pub m : Int\nm =\n    1\n" },
    });
    defer p.deinit();
    const order = try p.order(testing.allocator);
    defer testing.allocator.free(order);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "A", "M", "Z" }), order);
    try testing.expectEqual(@as(u32, 0), p.graph().edgeCount());
}

test "a three-module cycle is one diagnostic on its first module, and every member is poisoned" {
    const TestProject = @import("TestProject.zig");
    var p = try TestProject.init(testing.allocator, &.{
        .{ .path = "A.beni", .source = "import B exposing (b)\n\n\npub a : Int\na =\n    b\n" },
        .{ .path = "B.beni", .source = "import C exposing (c)\n\n\npub b : Int\nb =\n    c\n" },
        .{ .path = "C.beni", .source = "import A exposing (a)\n\n\npub c : Int\nc =\n    a\n" },
    });
    defer p.deinit();

    try testing.expectEqual(@as(usize, 1), p.graph().diagnostics.len);
    const item = p.graph().diagnostics[0];
    try testing.expectEqual(diagnostic.Code.import_cycle, item.code);
    try testing.expectEqual(p.module("A").?, @as(Index, @enumFromInt(0)));
    try testing.expectEqualSlices(Index, &.{ p.module("A").?, p.module("B").?, p.module("C").? }, p.graph().cycle_members[item.cycle_start..item.cycle_end]);
    for (0..3) |i| try testing.expect(p.graph().isPoisoned(@enumFromInt(i)));

    // Every module still gets a place in the schedule, so nothing is
    // silently skipped; and the cycle is the ONLY thing reported.
    const order = try p.order(testing.allocator);
    defer testing.allocator.free(order);
    try testing.expectEqual(@as(usize, 3), order.len);
    const codes = try p.codes(testing.allocator);
    defer testing.allocator.free(codes);
    try testing.expectEqualSlices(diagnostic.Code, &.{.import_cycle}, codes);
}

test "a module's references to itself are not a self-loop" {
    const TestProject = @import("TestProject.zig");
    // Every operator desugars to a reference to the module that defines
    // its function (language.md §6.5), so a `Basics` that uses `+` refers
    // to `Basics`. That must resolve to its own declaration and add no
    // edge, or the standard library would be a cycle of one.
    var p = try TestProject.init(testing.allocator, &.{
        .{
            .path = "Basics.beni",
            .source =
            \\pub foreign type Int
            \\
            \\
            \\pub foreign add : Int -> Int -> Int
            \\
            \\
            \\pub twice : Int -> Int
            \\twice n =
            \\    n + n
            \\
            ,
            .package = .core,
        },
    });
    defer p.deinit();

    try testing.expectEqual(@as(u32, 1), p.graph().count());
    try testing.expectEqual(@as(u32, 0), p.graph().edgeCount());
    try testing.expect(!p.graph().isPoisoned(p.module("Basics").?));
    const codes = try p.codes(testing.allocator);
    defer testing.allocator.free(codes);
    try testing.expectEqualSlices(diagnostic.Code, &.{}, codes);
}

test "two files claiming one module name is duplicate_module on the second" {
    const TestProject = @import("TestProject.zig");
    // Both paths end in `M.beni` but sit under different roots, so both
    // are the module `M` of the app package. The FIRST path keeps the
    // name (file order is path order), so the report lands on `b/M.beni`.
    var p = try TestProject.init(testing.allocator, &.{
        .{ .path = "a/M.beni", .source = "pub x : Int\nx =\n    1\n", .rel_start = 2 },
        .{ .path = "b/M.beni", .source = "pub y : Int\ny =\n    2\n", .rel_start = 2 },
    });
    defer p.deinit();

    try testing.expectEqual(@as(usize, 1), p.graph().diagnostics.len);
    try testing.expectEqual(diagnostic.Code.duplicate_module, p.graph().diagnostics[0].code);
    try testing.expectEqualStrings("b/M.beni", p.session.store.path(p.graph().diagnostics[0].file));
    try testing.expect(p.graph().isPoisoned(@enumFromInt(1)));
    try testing.expect(!p.graph().isPoisoned(@enumFromInt(0)));
}

test "lookup searches the importing package first, then core" {
    const TestProject = @import("TestProject.zig");
    var p = try TestProject.init(testing.allocator, &.{
        .{ .path = "app/List.beni", .source = "pub mine : Int\nmine =\n    1\n", .rel_start = 4 },
        .{ .path = "core/List.beni", .source = "pub theirs : Int\ntheirs =\n    1\n", .package = .core, .rel_start = 5 },
        .{ .path = "core/Other.beni", .source = "pub x : Int\nx =\n    1\n", .package = .core, .rel_start = 5 },
    });
    defer p.deinit();

    const list = p.session.interner.getOrPut(testing.allocator, "List") catch unreachable;
    const other = p.session.interner.getOrPut(testing.allocator, "Other") catch unreachable;
    const app_list = p.graph().lookup(.app, list).?;
    const core_list = p.graph().lookup(.core, list).?;
    try testing.expect(app_list != core_list);
    try testing.expectEqual(SourceStore.Package.app, p.graph().module(app_list).package);
    try testing.expectEqual(SourceStore.Package.core, p.graph().module(core_list).package);
    // An app module falls through to core for a name its own package has
    // not got; a core module never looks in app.
    try testing.expect(p.graph().lookup(.app, other) != null);
    try testing.expect(p.graph().lookup(.core, other) != null);
}
