//! Reachability elimination (docs/design/backend.md §9): which top-level
//! declarations a build actually ships.
//!
//! **The unit is a top-level declaration** (§9, `boundary.md` §7.1), and
//! there are three kinds of node — a `.value` declaration with a body, a
//! `.foreign_value` binding, and a `Dispatch.Derived` row. The first two are
//! both `(Graph.Index, Bir.DeclIndex)` and cannot collide, so a module needs
//! **two** bitsets and not three; §9's "one bitset per module over each of
//! the three node kinds" counts kinds and not sets.
//!
//! Four things are deliberately NOT nodes, each because it has no separate
//! existence in the output: a `type`, a `type alias` and a `foreign type`
//! emit nothing; a **constructor** is an object literal at its use site, so
//! a constructor named only in a pattern needs no edge — and a padded
//! nullary one is a constant of the module that USES it, written when a
//! surviving body names it (`backend.md` §4, *A nullary constructor is one
//! object*), so it needs none either; a **`$$order`
//! table** lives and dies with the `compare` whose row it hangs off
//! (`Lower.orderTable` is reached only from a row whose arrow was built);
//! and the three **primitive comparators** are discovered by
//! `Lowerer.needs` while a surviving body is lowered, so they are emitted
//! exactly when one wanted them.
//!
//! **The edges, in three legs** (§9), are walked by `check/Edges.zig`, which
//! this pass shares with `check/Cycles.zig` — out of a value declaration `d`
//! of module `m`:
//!
//!   1. every `Bir.refs` row of `d` whose kind is `top_value`;
//!   2. every `.top` and `ext_value` instruction in `d`'s contiguous
//!      instruction range — `Resolve` has already rewritten the instruction
//!      to carry `(Graph.Index, ValueIndex)`, where the `refs` table's
//!      `import_value` rows stay symbolic and re-deriving that lookup here
//!      would be a second copy of resolution;
//!   3. every dispatch site of `d` — its callee and evidence roots — and
//!      recursively every term's `args` (checker-v2.md §13.3). These are the edges `Bir`
//!      deliberately does not have (`frontend.md` §3.6): a method call's
//!      callee is not known until the checker runs, and an evidence argument
//!      is a reference no source line spells.
//!
//! Out of a `Derived` row: every target in its `parts`, recursively — that
//! is how a derived `eq` for `type T = T (Maybe U)` reaches `Maybe`'s row.
//! Out of a foreign binding: nothing; its body is in a sibling file this
//! pass does not read.
//!
//! **What is this pass's own** is everything CROSS-MODULE, which is the whole
//! difference between the two consumers of `Edges.zig`: this one resolves an
//! `ext` edge through `Interface.Provenance.valueDecl`, an `ext_derived` edge
//! against the owning module's table, and the `primitive`/`err` edges against
//! core — where `Cycles.zig` keeps `.top` alone, because the module graph is
//! a DAG and a cycle cannot cross a module. The walk is shared so that a
//! fourth leg is added once and both passes are then made to answer for it;
//! `Edges.zig`'s own test is what pins the three that exist.
//!
//! **Two targets §9 calls edgeless are edges, and the spec is corrected
//! here.** `Edges.zig` yields both as tags and this pass is where they become
//! nodes. §9 says `primitive` and `err` add none "because each is an
//! operator or a poisoned table". That is true of `strict_eq`,
//! `num_compare` and `char_compare`, which the module synthesises for
//! itself — but `primitive string_compare` lowers to a CALL of core's
//! hand-written `String.compare` (`Lower.stringCompare` →
//! `Lower.coreValue`, §3.2/A.26: `<` on JavaScript strings is UTF-16
//! code-unit order and `String.compare` is Unicode scalar order, and the
//! two must agree), and `undetermined` lowers to a call of `Basics.eq`
//! (`Lower.partEq`'s `undetermined` arm). Both are references to another module's
//! declaration that no `refs` row and no `top`/`ext` target records, so
//! without them a program that orders `String`s inside a derived function
//! ships a call to a name its build never wrote — a `ReferenceError` at
//! load, which is exactly the failure this pass has to fear.
//!
//! **Where it runs.** Between `Emit.findEntry` and `Emit.emitModules`, over
//! `Bir` and the dispatch table and BEFORE lowering, so an unreachable
//! declaration is never lowered at all and the pass pays for itself in emit
//! time. §10's colouring wants the same graph, before anything has been
//! assigned to a file, and a cache can keep a module's edge list against the
//! §8.1 key.
//!
//! **Determinism.** Every node identity is input-derived end to end: a
//! `Graph.Index` comes from the sorted path (CLAUDE.md rule 5), a
//! declaration index is source order, and a `Derived` index is the
//! sorted-by-name order §7.1 of the spike fixes before anything indexes it.
//! The output is a SET, so visit order cannot reach the bytes.
//!
//! **Parallelism.** §9 asks for the per-module edge lists to be built in
//! parallel, one job per module, and `Emit` does so on its workers: each
//! module's list is a pure function of its own `Bir` and dispatch table,
//! built by one thread's `Builder` and written only into its own slot. The
//! walk over them (`walk`) is serial and O(declarations). `run` is the two
//! on one thread.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Edges = @import("../check/Edges.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");
const SourceStore = @import("../SourceStore.zig");
const Types = @import("../check/Types.zig");
const CtorEq = @import("CtorEq.zig");

const Reach = @This();

/// Which of the two per-module tables a node lives in.
pub const Kind = enum(u8) { decl, derived };

/// One node of the graph: a declaration of a module, or one of its derived
/// rows. Flat and comparable; nothing here is a pointer.
pub const Node = struct {
    module: Graph.Index,
    kind: Kind,
    index: u32,
};

/// The survivors of one module.
pub const Live = struct {
    decls: std.DynamicBitSetUnmanaged,
    derived: std.DynamicBitSetUnmanaged,

    pub const empty: Live = .{ .decls = .{}, .derived = .{} };

    pub fn decl(l: *const Live, index: usize) bool {
        return index < l.decls.bit_length and l.decls.isSet(index);
    }

    pub fn derivedRow(l: *const Live, index: usize) bool {
        return index < l.derived.bit_length and l.derived.isSet(index);
    }

    /// Whether the module has anything left to write (§5, "a module with
    /// nothing reachable is not written at all").
    pub fn any(l: *const Live) bool {
        return l.decls.count() != 0 or l.derived.count() != 0;
    }
};

/// What the pass produced, indexed by `Graph.Index`.
pub const Result = struct {
    modules: []Live,
    /// Kept for the debug self-check, which has to answer "is the
    /// declaration behind THIS interface value alive?" at every cross-module
    /// reference the lowerer emits — and the same question about another
    /// module's derived row, which only that module's table can answer.
    provenance: []const Interface.Provenance,
    dispatch: []const *const Dispatch,

    pub const empty: Result = .{ .modules = &.{}, .provenance = &.{}, .dispatch = &.{} };

    pub fn of(r: *const Result, m: Graph.Index) *const Live {
        if (m.int() >= r.modules.len) return &no_module;
        return &r.modules[m.int()];
    }

    pub fn decl(r: *const Result, m: Graph.Index, index: usize) bool {
        return r.of(m).decl(index);
    }

    pub fn derivedRow(r: *const Result, m: Graph.Index, index: usize) bool {
        return r.of(m).derivedRow(index);
    }

    /// Whether the declaration behind another module's interface value
    /// survived. A value whose provenance is missing answers `true`: the
    /// self-check reports what it is SURE is wrong and never invents a bug
    /// out of a table it cannot read.
    pub fn extValue(r: *const Result, m: Graph.Index, value: u32) bool {
        if (m.int() >= r.provenance.len) return true;
        const d = r.provenance[m.int()].valueDecl(value) orelse return true;
        return r.decl(m, d.int());
    }

    /// Whether another module's derived function for `(id, kind)` survived.
    /// A row that is not in that module's table answers `true`: whether the
    /// module emits a body at all is `Lower.derivedBodyExists`' question,
    /// and this one must not double as it.
    pub fn extDerived(r: *const Result, m: Graph.Index, id: Dispatch.TypeId, kind: Dispatch.Derived.Kind) bool {
        if (m.int() >= r.dispatch.len) return true;
        for (r.dispatch[m.int()].derived, 0..) |row, i| {
            if (row.kind != kind) continue;
            switch (row.shape) {
                .nominal => |other| if (other != id) continue,
                else => continue,
            }
            return r.derivedRow(m, i);
        }
        return true;
    }

    const no_module: Live = .empty;
};

/// The whole-program input. Every slice is indexed by `Graph.Index`.
pub const Input = struct {
    graph: *const Graph,
    store: *const SourceStore,
    birs: []const *const Bir,
    dispatch: []const *const Dispatch,
    interfaces: []const Interface,
    provenance: []const Interface.Provenance,
    types: *const Types,
    /// What `CtorEq` reads an imported constructor's published context
    /// through. Null leaves every `==` site's edge in, which is only ever
    /// more than the code needs.
    interner: ?*const InternPool.Global = null,
    /// `main`, when this build has one. The only root of an application
    /// build (§9's "Roots").
    entry: ?Node = null,
    /// `--library`: every name the ROOT PACKAGE's modules export is a root
    /// (§2, §9). A library's callers are not in the build, so its public
    /// surface is its root set.
    library: bool = false,
    /// The vocabulary module of a build that lowers markup: an event's
    /// payload extractor is one of its values, reached by the markup leg
    /// (`checker-v2.md` §25.7).
    vocabulary: ?Graph.Index = null,

    fn birOf(in: Input, m: Graph.Index) *const Bir {
        if (m.int() >= in.birs.len) return &Bir.empty;
        return in.birs[m.int()];
    }

    fn dispatchOf(in: Input, m: Graph.Index) *const Dispatch {
        if (m.int() >= in.dispatch.len) return &Dispatch.empty;
        return in.dispatch[m.int()];
    }

    /// A named value of a core module, as a node: how `Lower.coreValue`
    /// reaches `String.compare` and `Basics.eq`, resolved once. The
    /// declaration is found in the module's own `Bir` rather than through
    /// its interface, because `coreValue` takes the local path when the
    /// module being lowered IS that module and both paths name one
    /// declaration.
    fn coreDecl(in: Input, owner: InternPool.WellKnown, value: InternPool.WellKnown) ?Node {
        const m = in.graph.lookup(.core, owner.symbol()) orelse return null;
        const bir = in.birOf(m);
        for (bir.decls, 0..) |d, i| {
            if (!d.kind.isValue()) continue;
            if (bir.symbol(d.name) != value.symbol()) continue;
            return .{ .module = m, .kind = .decl, .index = @intCast(i) };
        }
        return null;
    }

    /// §9's root set.
    ///
    /// An application build has exactly ONE root, `main` of the entry
    /// module: `pub` means nothing to elimination in a program, because
    /// `pub` is a MODULE boundary and a whole-program compiler knows the
    /// program — and treating it as a root would pin all of core forever,
    /// every core value being `pub`.
    ///
    /// A `--library` build roots **every name the root package's modules
    /// export**, which is the list `Lower.exports` already builds: `pub`
    /// values with a body, every nominal `derived` row, and the entry
    /// declaration. Core and the platform are dependencies, not public
    /// surface, so their exports root nothing.
    ///
    /// **The entry declaration is part of that list, and §2's parenthetical
    /// "a `main` that happens to exist is not special" is wrong.** §5 gives
    /// the export list three sources and the entry is the third; `main` is
    /// not `pub` in any fixture of the corpus, so a rule that dropped it
    /// would take `main` and its `import Node` out of all seventeen `emit/`
    /// goldens — against §9's own measured, thrice-stated acceptance that
    /// none of them moves. What `--library` turns off is the REQUIREMENT
    /// for a `main` (`missing_main` does not fire, and its type is not
    /// checked against the platform's `Program`) and the entry file.
    fn collectRoots(in: Input, scratch: Allocator, out: *std.ArrayList(Node)) Allocator.Error!void {
        if (!in.library) {
            if (in.entry) |node| try out.append(scratch, node);
            return;
        }
        for (0..in.graph.count()) |i| {
            const m: Graph.Index = @enumFromInt(@as(u32, @intCast(i)));
            if (in.store.package(in.graph.moduleFile(m)) != .app) continue;
            const bir = in.birOf(m);
            for (bir.interface) |index| {
                const d = bir.decl(index);
                if (!d.kind.isValue()) continue;
                if (d.kind == .annotation_only) continue;
                if (d.kind == .vocab_markup) continue;
                if (d.kind == .value and d.body == .none) continue;
                try out.append(scratch, .{ .module = m, .kind = .decl, .index = index.int() });
            }
            for (in.dispatchOf(m).derived, 0..) |row, index| {
                if (row.shape != .nominal) continue;
                try out.append(scratch, .{ .module = m, .kind = .derived, .index = @intCast(index) });
            }
            if (mainOf(bir)) |index| try out.append(scratch, .{ .module = m, .kind = .decl, .index = index });
        }
    }
};

/// The module's `main`, if it declares one with a body: the entry
/// declaration `Lower.exports` exports whether or not it is `pub`.
pub fn mainOf(bir: *const Bir) ?u32 {
    for (bir.decls, 0..) |d, i| {
        if (d.kind != .value or d.body == .none) continue;
        if (bir.symbol(d.name) != InternPool.WellKnown.main.symbol()) continue;
        return @intCast(i);
    }
    return null;
}

/// Build the graph, walk it from the roots, and answer with one survivor
/// set per module. Everything lives in `scratch`, the caller's arena: the
/// answer is read by `Lower` during the same `Emit.run` and by nothing
/// afterwards.
pub fn run(scratch: Allocator, in: Input) Allocator.Error!Result {
    const edges = try scratch.alloc(ModuleEdges, in.graph.count());
    var b: Builder = .init(in, scratch);
    for (edges, 0..) |*slot, i| slot.* = try b.module(@enumFromInt(@as(u32, @intCast(i))));
    return walk(scratch, in, edges);
}

/// The walk over every module's edges (`Builder.module`), from the roots:
/// serial, because a fixpoint over a whole-program graph is, and it is
/// small — O(declarations). The survivor sets live in `scratch`; `edges` is
/// read and not kept.
pub fn walk(scratch: Allocator, in: Input, edges: []const ModuleEdges) Allocator.Error!Result {
    const count = in.graph.count();
    const modules = try scratch.alloc(Live, count);
    for (modules, 0..) |*slot, i| {
        const m: Graph.Index = @enumFromInt(@as(u32, @intCast(i)));
        slot.* = .{
            .decls = try .initEmpty(scratch, in.birOf(m).decls.len),
            .derived = try .initEmpty(scratch, in.dispatchOf(m).derived.len),
        };
    }

    var stack: std.ArrayList(Node) = .empty;
    var roots: std.ArrayList(Node) = .empty;
    try in.collectRoots(scratch, &roots);
    for (roots.items) |root| {
        if (mark(modules, root)) try stack.append(scratch, root);
    }
    while (stack.pop()) |node| {
        const list = edges[node.module.int()].targets(node);
        for (list) |next| {
            if (mark(modules, next)) try stack.append(scratch, next);
        }
    }

    return .{ .modules = modules, .provenance = in.provenance, .dispatch = in.dispatch };
}

/// Set a node's bit, and say whether this call is the one that set it. A
/// node outside its module's table is silently dropped: the tables are
/// sized from the same `Bir` and `Dispatch` the edges were read out of, so
/// only a poisoned index gets here and following it would be worse.
fn mark(modules: []Live, node: Node) bool {
    if (node.module.int() >= modules.len) return false;
    const live = &modules[node.module.int()];
    const set = switch (node.kind) {
        .decl => &live.decls,
        .derived => &live.derived,
    };
    if (node.index >= set.bit_length) return false;
    if (set.isSet(node.index)) return false;
    set.set(node.index);
    return true;
}

/// One module's edge lists: two flat target arrays with a start offset per
/// node, the same shape every other sidecar table here has.
pub const ModuleEdges = struct {
    decl_at: []const u32 = &.{},
    decl_targets: []const Node = &.{},
    derived_at: []const u32 = &.{},
    derived_targets: []const Node = &.{},

    fn targets(e: ModuleEdges, node: Node) []const Node {
        const at, const list = switch (node.kind) {
            .decl => .{ e.decl_at, e.decl_targets },
            .derived => .{ e.derived_at, e.derived_targets },
        };
        if (node.index + 1 >= at.len) return &.{};
        return list[at[node.index]..at[node.index + 1]];
    }
};

/// Builds modules' edge lists, one module at a time. One per thread: its
/// `stream` is its own, and `scratch` is where the lists it returns live.
pub const Builder = struct {
    in: Input,
    scratch: Allocator,
    /// `core.String`'s `compare` and `core.Basics`' `eq`, the two
    /// declarations the lowerer names with no target of its own (see the
    /// header).
    string_compare: ?Node = null,
    basics_eq: ?Node = null,
    /// The shared walk's output for one node, cleared and refilled per
    /// node: a caller-owned buffer, so the whole module's edges cost one
    /// allocation.
    stream: std.ArrayList(Edges.Edge) = .empty,

    /// The two corrected `primitive`/`err` legs name one declaration each,
    /// the same one for every module, so they are resolved once here rather
    /// than at every edge.
    pub fn init(in: Input, scratch: Allocator) Builder {
        return .{
            .in = in,
            .scratch = scratch,
            .string_compare = in.coreDecl(.String, .compare),
            .basics_eq = in.coreDecl(.Basics, .eq),
        };
    }

    /// Every edge out of every node of one module. Writes nothing outside
    /// its own return value, so modules can be built on several threads at
    /// once, each with its own `Builder`.
    pub fn module(b: *Builder, m: Graph.Index) Allocator.Error!ModuleEdges {
        const bir = b.in.birOf(m);
        const dispatch = b.in.dispatchOf(m);

        // An `==` written as a tag and field test calls no derived `eq`
        // (`backend.md` §4), so its site is not an edge: `CtorEq` is the
        // decision `Lower` takes, asked here first.
        const ctor_eq: ?CtorEq.Context = if (b.in.interner) |interner| .{
            .bir = bir,
            .dispatch = dispatch,
            .interfaces = b.in.interfaces,
            .types = b.in.types,
            .interner = interner,
        } else null;
        const filter: ?Edges.SiteFilter = if (ctor_eq) |*context| .{ .context = context, .skip = skipInPlace } else null;

        const decl_at = try b.scratch.alloc(u32, bir.decls.len + 1);
        var decl_targets: std.ArrayList(Node) = .empty;
        for (bir.decls, 0..) |d, i| {
            decl_at[i] = @intCast(decl_targets.items.len);
            switch (d.kind) {
                // A foreign binding's body is in a sibling file; a type, an
                // alias and a foreign type emit nothing at all.
                .value => {},
                .foreign_value, .type, .type_alias, .foreign_type, .annotation_only, .schema, .vocab_element, .vocab_attribute, .vocab_event, .vocab_markup => continue,
            }
            b.stream.clearRetainingCapacity();
            try Edges.declEdgesExcept(&b.stream, b.scratch, bir, dispatch, @intCast(i), filter);
            if (b.in.vocabulary) |vocabulary| try Edges.markupEdges(&b.stream, b.scratch, bir, dispatch, @intCast(i), vocabulary);
            // Most edges become exactly one node, so one reservation per
            // declaration is the growth the resolve loop would otherwise do
            // a word at a time.
            try decl_targets.ensureUnusedCapacity(b.scratch, b.stream.items.len);
            for (b.stream.items) |edge| try b.resolve(m, edge, &decl_targets);
        }
        decl_at[bir.decls.len] = @intCast(decl_targets.items.len);

        const derived_at = try b.scratch.alloc(u32, dispatch.derived.len + 1);
        var derived_targets: std.ArrayList(Node) = .empty;
        for (0..dispatch.derived.len) |i| {
            derived_at[i] = @intCast(derived_targets.items.len);
            b.stream.clearRetainingCapacity();
            try Edges.derivedEdges(&b.stream, b.scratch, dispatch, @intCast(i));
            for (b.stream.items) |edge| try b.resolve(m, edge, &derived_targets);
        }
        derived_at[dispatch.derived.len] = @intCast(derived_targets.items.len);

        return .{
            .decl_at = decl_at,
            .decl_targets = decl_targets.items,
            .derived_at = derived_at,
            .derived_targets = derived_targets.items,
        };
    }

    fn skipInPlace(context: *const anyopaque, site: Dispatch.Site) bool {
        const c: *const CtorEq.Context = @ptrCast(@alignCast(context));
        return CtorEq.inPlace(c.*, site);
    }

    /// One edge of the shared stream, as whole-program nodes. Everything
    /// cross-module is resolved here, because this is the pass that has the
    /// tables for it.
    inline fn resolve(b: *Builder, m: Graph.Index, edge: Edges.Edge, out: *std.ArrayList(Node)) Allocator.Error!void {
        switch (edge) {
            .top => |index| try out.append(b.scratch, .{ .module = m, .kind = .decl, .index = index }),
            .ext => |e| try b.extValue(out, e.module, e.value),
            .derived => |index| try out.append(b.scratch, .{ .module = m, .kind = .derived, .index = index }),
            .ext_derived => |use| try b.extDerived(out, use),
            // `String.compare` and `Basics.eq`: real cross-module calls the
            // lowerer writes with no target of their own (see the header).
            // The other three primitives are this module's own synthesised
            // comparators and are discovered during lowering.
            .primitive => |prim| if (prim == .string_compare) {
                if (b.string_compare) |node| try out.append(b.scratch, node);
            },
            .undetermined => if (b.basics_eq) |node| try out.append(b.scratch, node),
        }
    }

    fn extValue(b: *Builder, out: *std.ArrayList(Node), m: Graph.Index, value: u32) Allocator.Error!void {
        if (m.int() >= b.in.provenance.len) return;
        const d = b.in.provenance[m.int()].valueDecl(value) orelse return;
        try out.append(b.scratch, .{ .module = m, .kind = .decl, .index = d.int() });
    }

    /// The `Derived` row another module emits for one of its nominal types.
    /// That table is exactly what its module EMITS (A.47), so the row is
    /// found by `(kind, nominal type)` — the same pair `Lower.derivedName`
    /// spells `<Module>$<Type>$$<kind>` from.
    ///
    /// **Both spellings of "which module" are followed**, because the table
    /// carries one and the lowerer reads the other: `ExtDerivedUse.module`
    /// is what the checker wrote, and `Lower.derivedName` names
    /// `types.entry(use.type).module`. They agree in every program, and an
    /// extra edge costs bytes where a missing one costs a `ReferenceError`.
    fn extDerived(b: *Builder, out: *std.ArrayList(Node), use: Edges.Edge.ExtDerived) Allocator.Error!void {
        try b.derivedRowOf(out, use.module, use.type, use.kind);
        const owner = b.in.types.entry(use.type).module;
        if (owner != use.module) try b.derivedRowOf(out, owner, use.type, use.kind);
    }

    fn derivedRowOf(b: *Builder, out: *std.ArrayList(Node), m: Graph.Index, id: Dispatch.TypeId, kind: Dispatch.Derived.Kind) Allocator.Error!void {
        if (m.int() >= b.in.dispatch.len) return;
        for (b.in.dispatchOf(m).derived, 0..) |row, i| {
            if (row.kind != kind) continue;
            switch (row.shape) {
                .nominal => |other| if (other != id) continue,
                else => continue,
            }
            try out.append(b.scratch, .{ .module = m, .kind = .derived, .index = @intCast(i) });
            return;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
//
// A SUPPLEMENT and never the coverage (CLAUDE.md rule 3): what this pass
// does is visible in emitted JavaScript, so its evidence is
// `tests/corpus/emit/app/` and the six `run/Dce*` programs. What is here is
// the arithmetic those cannot reach — an out-of-range node index, and the
// empty tables a module that failed to lower contributes. That the EDGES are
// all three legs is `check/Edges.zig`'s test, once, for both consumers.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a node outside its module's tables is dropped rather than followed" {
    var live = [_]Live{.{
        .decls = try .initEmpty(testing.allocator, 2),
        .derived = try .initEmpty(testing.allocator, 1),
    }};
    defer live[0].decls.deinit(testing.allocator);
    defer live[0].derived.deinit(testing.allocator);

    const m: Graph.Index = @enumFromInt(0);
    try testing.expect(mark(&live, .{ .module = m, .kind = .decl, .index = 1 }));
    // Twice is once: the walk pushes a node only on the call that set it,
    // which is what stops a cycle.
    try testing.expect(!mark(&live, .{ .module = m, .kind = .decl, .index = 1 }));
    // Past the end of the table, and past the end of the graph. A poisoned
    // index is refused, not followed into memory that is not there.
    try testing.expect(!mark(&live, .{ .module = m, .kind = .decl, .index = 2 }));
    try testing.expect(!mark(&live, .{ .module = m, .kind = .derived, .index = 1 }));
    try testing.expect(!mark(&live, .{ .module = @enumFromInt(7), .kind = .decl, .index = 0 }));

    try testing.expect(live[0].decl(1));
    try testing.expect(!live[0].decl(0));
    try testing.expect(!live[0].derivedRow(0));
    try testing.expect(live[0].any());
}

test "a module with no survivor answers `any` false, and an absent one answers nothing" {
    var live = [_]Live{.{
        .decls = try .initEmpty(testing.allocator, 3),
        .derived = try .initEmpty(testing.allocator, 2),
    }};
    defer live[0].decls.deinit(testing.allocator);
    defer live[0].derived.deinit(testing.allocator);
    // Nothing set: §5's "a module with nothing reachable is not written at
    // all" is this answer and `Emit.emitModules` reads exactly it.
    try testing.expect(!live[0].any());
    live[0].derived.set(1);
    try testing.expect(live[0].any());

    // A module past the end of the result — which is every module of a
    // build that produced no result at all — is dead, not alive: the empty
    // `Result` eliminates everything, so it can only ever be the state of a
    // build that writes nothing.
    const r: Result = .empty;
    try testing.expect(!r.decl(@enumFromInt(0), 0));
    try testing.expect(!r.derivedRow(@enumFromInt(0), 0));
    try testing.expect(!r.of(@enumFromInt(0)).any());
    // The two self-check questions answer TRUE on a table they cannot read,
    // because the wall reports what it is sure of and never invents a bug
    // out of a missing record.
    try testing.expect(r.extValue(@enumFromInt(0), 0));
    try testing.expect(r.extDerived(@enumFromInt(0), .none, .eq));
}
