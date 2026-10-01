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
//! Four things are deliberately NOT nodes that emit anything, each because
//! it has no separate existence in the output: a `type`, a `type alias` and
//! a `foreign type` emit nothing; a **constructor** is an object literal at
//! its use site, and a padded nullary one is a constant of the module that
//! USES it, written when a surviving body names it (`backend.md` §4, *A
//! nullary constructor is one object*) — *amended 2026-10-02*: a
//! constructor IS a node now, of kind `ctor`, but one that emits nothing:
//! it is reached when a surviving body builds one, and an edge inside a
//! `case` arm waits on the constructors of the arm's pattern (`Guards`,
//! `backend.md` §9, *A `case` arm on a constructor nothing builds*); a **`$$order`
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
const JsIntrinsic = @import("JsIntrinsic.zig");
const Operator = @import("Operator.zig");

const Reach = @This();

/// Which of the per-module tables a node lives in. `twin` is a
/// declaration's second, suspendable body (transparent-effects-proposal.md
/// §16.2): a node of its own, so a program that never suspends writes none.
/// `ctor` is a constructor, by its index in the module's `Bir.ctors`:
/// reached when a surviving body builds one, and what a guarded edge waits
/// on (`backend.md` §9, *A `case` arm on a constructor nothing builds*). It
/// emits nothing and has no edges of its own.
pub const Kind = enum(u8) { decl, derived, twin, ctor };

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
    twins: std.DynamicBitSetUnmanaged = .{},
    /// The constructors something that survived builds, and the exempt
    /// ones (`exempt`). `Lower` lowers an arm on any other as `undefined`.
    ctors: std.DynamicBitSetUnmanaged = .{},

    pub const empty: Live = .{ .decls = .{}, .derived = .{} };

    /// Whether constructor `index` of the module was reached. The one
    /// predicate both halves of the rule use: the walk follows a guarded
    /// edge only when this holds for every guard, and `Lower` keeps an arm
    /// only when it holds for every constructor of its pattern.
    pub fn ctor(l: *const Live, index: usize) bool {
        return index < l.ctors.bit_length and l.ctors.isSet(index);
    }

    pub fn decl(l: *const Live, index: usize) bool {
        return index < l.decls.bit_length and l.decls.isSet(index);
    }

    /// Whether a declaration's suspendable body survived.
    pub fn twin(l: *const Live, index: usize) bool {
        return index < l.twins.bit_length and l.twins.isSet(index);
    }

    pub fn derivedRow(l: *const Live, index: usize) bool {
        return index < l.derived.bit_length and l.derived.isSet(index);
    }

    /// Whether the module has anything left to write (§5, "a module with
    /// nothing reachable is not written at all").
    pub fn any(l: *const Live) bool {
        return l.decls.count() != 0 or l.derived.count() != 0 or l.twins.count() != 0;
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

    pub fn twin(r: *const Result, m: Graph.Index, index: usize) bool {
        return r.of(m).twin(index);
    }

    /// Whether constructor `index` of `m`'s `Bir.ctors` was reached.
    pub fn ctor(r: *const Result, m: Graph.Index, index: usize) bool {
        return r.of(m).ctor(index);
    }

    /// The same for another module's constructor, by its interface index,
    /// as an `ext_ctor` instruction names it. One whose provenance is
    /// missing answers `false`, as the walk does: it cannot be a node, so
    /// an edge guarded by it was never followed.
    pub fn extCtor(r: *const Result, m: Graph.Index, iface_ctor: u32) bool {
        const index = ctorOfExt(r.provenance, m, iface_ctor) orelse return false;
        return r.ctor(m, index);
    }

    /// Whether the suspendable body behind another module's interface value
    /// survived; `true` when the table cannot say, as `extValue`.
    pub fn extTwin(r: *const Result, m: Graph.Index, value: u32) bool {
        if (m.int() >= r.provenance.len) return true;
        const d = r.provenance[m.int()].valueDecl(value) orelse return true;
        return r.twin(m, d.int());
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
    /// `--release`: which arm of an `if Js.development` the build drops.
    release: bool = false,
    /// The vocabulary module of a build that lowers markup: an event's
    /// payload extractor is one of its values, reached by the markup leg
    /// (`checker-v2.md` §25.7).
    vocabulary: ?Graph.Index = null,
    /// Roots beside the build's own: the runtime module's values that the
    /// hand-written runtime or the entry file reads, or that a lowering
    /// imports (`backend.md` §15.1, *The runtime module*).
    extra_roots: []const Node = &.{},

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
        try out.appendSlice(scratch, in.extra_roots);
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

/// Another module's constructor, from its interface index to its index in
/// that module's `Bir.ctors`.
fn ctorOfExt(provenance: []const Interface.Provenance, m: Graph.Index, iface_ctor: u32) ?u32 {
    if (m.int() >= provenance.len) return null;
    return provenance[m.int()].ctorIndex(iface_ctor);
}

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
            .twins = try .initEmpty(scratch, in.birOf(m).decls.len),
            .ctors = try .initEmpty(scratch, in.birOf(m).ctors.len),
        };
    }
    try exempt(in, scratch, modules);

    var stack: std.ArrayList(Node) = .empty;
    var roots: std.ArrayList(Node) = .empty;
    // Edges blocked on a constructor not reached yet, by that constructor.
    var waiting: std.AutoHashMapUnmanaged(Node, std.ArrayList(Pending)) = .empty;
    try in.collectRoots(scratch, &roots);
    for (roots.items) |root| {
        if (mark(modules, root)) try stack.append(scratch, root);
    }
    while (stack.pop()) |node| {
        const module = node.module;
        for (edges[module.int()].targets(node)) |next| {
            try follow(scratch, modules, edges, &waiting, &stack, module, next);
        }
        if (node.kind != .ctor) continue;
        // A constructor just reached: every edge that waited on it is
        // looked at again, and waits on the next guard it lacks, if any.
        var blocked = (waiting.fetchRemove(node) orelse continue).value;
        defer blocked.deinit(scratch);
        for (blocked.items) |p| try follow(scratch, modules, edges, &waiting, &stack, p.module, p.target);
    }

    return .{ .modules = modules, .provenance = in.provenance, .dispatch = in.dispatch };
}

/// An edge waiting on a constructor, with the module whose chains its
/// guard indexes.
const Pending = struct { module: Graph.Index, target: Target };

/// Follow `target`, an edge out of a node of `module`: mark and push it
/// when every guard of its chain is reached, else wait on the first that
/// is not.
fn follow(
    scratch: Allocator,
    modules: []Live,
    edges: []const ModuleEdges,
    waiting: *std.AutoHashMapUnmanaged(Node, std.ArrayList(Pending)),
    stack: *std.ArrayList(Node),
    module: Graph.Index,
    target: Target,
) Allocator.Error!void {
    if (edges[module.int()].blocker(modules, target.chain)) |guard| {
        const slot = try waiting.getOrPut(scratch, guard);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(scratch, .{ .module = module, .target = target });
        return;
    }
    if (mark(modules, target.node)) try stack.append(scratch, target.node);
}

/// Mark the constructors no instruction's reach decides (`backend.md` §9,
/// *A `case` arm on a constructor nothing builds*): every one in a
/// `--library` build or a build with a `schema`; every one of `core`; and
/// every one of a type a `foreign`, `foreign type` or vocabulary
/// declaration names, and of every type those types' constructors and
/// aliases name, transitively — what hand-written JavaScript can build.
fn exempt(in: Input, scratch: Allocator, modules: []Live) Allocator.Error!void {
    const count = in.graph.count();
    var all = in.library;
    if (!all) for (0..count) |i| {
        for (in.birOf(@enumFromInt(@as(u32, @intCast(i)))).decls) |d| {
            if (d.kind == .schema) all = true;
        }
    };
    for (modules, 0..) |*live, i| {
        const m: Graph.Index = @enumFromInt(@as(u32, @intCast(i)));
        if (all or in.store.package(in.graph.moduleFile(m)) == .core) live.ctors.setAll();
    }
    if (all) return;

    // Type declarations whose constructors hand-written code may build: a
    // worklist over `(module, declaration)`, each looked at once.
    const seen = try scratch.alloc(std.DynamicBitSetUnmanaged, count);
    for (seen, 0..) |*s, i| s.* = try .initEmpty(scratch, in.birOf(@enumFromInt(@as(u32, @intCast(i)))).decls.len);
    var work: std.ArrayList(TypeDecl) = .empty;
    for (0..count) |i| {
        const m: Graph.Index = @enumFromInt(@as(u32, @intCast(i)));
        for (in.birOf(m).decls, 0..) |d, index| switch (d.kind) {
            .foreign_value, .foreign_type, .vocab_element, .vocab_attribute, .vocab_event, .vocab_markup => try typesNamed(in, scratch, m, @intCast(index), &work),
            else => {},
        };
    }
    while (work.pop()) |t| {
        const bir = in.birOf(t.module);
        if (t.decl >= bir.decls.len) continue;
        const s = &seen[t.module.int()];
        if (s.isSet(t.decl)) continue;
        s.set(t.decl);
        const d = bir.decls[t.decl];
        if (d.kind == .type) {
            const ctors = &modules[t.module.int()].ctors;
            for (d.ctors_start..d.ctors_end) |c| if (c < ctors.bit_length) ctors.set(c);
        }
        try typesNamed(in, scratch, t.module, t.decl, &work);
    }
}

const TypeDecl = struct { module: Graph.Index, decl: u32 };

/// Every type declaration a type reference in declaration `decl`'s
/// instructions names — its annotation, a type's constructor arguments, an
/// alias's body — onto `work`.
fn typesNamed(in: Input, scratch: Allocator, m: Graph.Index, decl: u32, work: *std.ArrayList(TypeDecl)) Allocator.Error!void {
    const bir = in.birOf(m);
    const d = bir.decls[decl];
    const tags = bir.insts.items(.tag);
    const data = bir.insts.items(.data);
    const start = @min(d.inst_start.int(), bir.insts.len);
    const end = @min(d.inst_end.int(), bir.insts.len);
    for (tags[start..end], data[start..end]) |tag, payload| switch (tag) {
        .type_top => try work.append(scratch, .{ .module = m, .decl = payload.lhs }),
        .ext_type => {
            const owner: Graph.Index = @enumFromInt(payload.lhs);
            if (owner.int() >= in.provenance.len) continue;
            const t = in.provenance[owner.int()].typeDecl(payload.rhs) orelse continue;
            try work.append(scratch, .{ .module = owner, .decl = t.int() });
        },
        else => {},
    };
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
        .twin => &live.twins,
        .ctor => &live.ctors,
    };
    if (node.index >= set.bit_length) return false;
    if (set.isSet(node.index)) return false;
    set.set(node.index);
    return true;
}

/// One edge: the node it reaches, and the chain of `case`-arm guards it
/// occurs under (0: none), in its module's `ModuleEdges.chains`.
pub const Target = struct {
    node: Node,
    chain: u32 = 0,
};

/// One guarded arm a position is inside: the constructors its pattern
/// names (`chain_ctors[start..end]`), and the chain of the arm around it.
pub const Chain = struct {
    parent: u32,
    start: u32,
    end: u32,
};

/// How many enclosing guarded arms an edge waits on: the innermost ones.
/// Dropping the outer conditions keeps more and never less.
pub const chain_depth = 4;

/// One module's edge lists: flat target arrays with a start offset per
/// node, the same shape every other sidecar table here has, and the guard
/// chains their targets name.
pub const ModuleEdges = struct {
    decl_at: []const u32 = &.{},
    decl_targets: []const Target = &.{},
    derived_at: []const u32 = &.{},
    derived_targets: []const Target = &.{},
    twin_at: []const u32 = &.{},
    twin_targets: []const Target = &.{},
    /// Index 0 is no chain.
    chains: []const Chain = &.{},
    chain_ctors: []const Node = &.{},

    fn targets(e: ModuleEdges, node: Node) []const Target {
        const at, const list = switch (node.kind) {
            .decl => .{ e.decl_at, e.decl_targets },
            .derived => .{ e.derived_at, e.derived_targets },
            .twin => .{ e.twin_at, e.twin_targets },
            .ctor => return &.{},
        };
        if (node.index + 1 >= at.len) return &.{};
        return list[at[node.index]..at[node.index + 1]];
    }

    /// The first guard of `chain`, innermost arm first, that is not
    /// reached; null when every one is (or there is none).
    fn blocker(e: ModuleEdges, modules: []const Live, chain: u32) ?Node {
        var c = chain;
        var depth: u32 = 0;
        while (c != 0 and c < e.chains.len and depth < chain_depth) : (depth += 1) {
            const link = e.chains[c];
            for (e.chain_ctors[link.start..link.end]) |guard| {
                if (guard.module.int() >= modules.len or !modules[guard.module.int()].ctor(guard.index)) return guard;
            }
            c = link.parent;
        }
        return null;
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
    /// The `core/List` values `Lower` calls with no reference of the
    /// program's own to them (`backend.md` §7, §8): `unsafeGet` and `view`
    /// for a list pattern, `slice` for a spread with items after it, and
    /// `close` for a building loop's exit — an edge of every declaration
    /// that writes one. `cons` is how a building loop is recognised.
    list_get: ?Node = null,
    list_view: ?Node = null,
    /// `base` and `offset`, which a loop that walks a list by a scalar
    /// view reads it through (`backend.md` §8, *Scalar views*).
    list_base: ?Node = null,
    list_offset: ?Node = null,
    list_slice: ?Node = null,
    list_close: ?Node = null,
    list_cons: ?Node = null,
    /// `List.append`, which a `++` on lists calls in place of
    /// `Basics.append` (`Dispatch.appends`).
    list_append: ?Node = null,
    /// The shared walk's output for one node, cleared and refilled per
    /// node: a caller-owned buffer, so the whole module's edges cost one
    /// allocation.
    stream: std.ArrayList(Edges.Edge) = .empty,
    /// The instruction each edge of `stream` occurs at.
    at: std.ArrayList(u32) = .empty,

    /// The two corrected `primitive`/`err` legs name one declaration each,
    /// the same one for every module, so they are resolved once here rather
    /// than at every edge.
    pub fn init(in: Input, scratch: Allocator) Builder {
        return .{
            .in = in,
            .scratch = scratch,
            .string_compare = in.coreDecl(.String, .compare),
            .basics_eq = in.coreDecl(.Basics, .eq),
            .list_get = in.coreDecl(.List, .unsafeGet),
            .list_view = in.coreDecl(.List, .view),
            .list_base = in.coreDecl(.List, .base),
            .list_offset = in.coreDecl(.List, .offset),
            .list_slice = in.coreDecl(.List, .slice),
            .list_close = in.coreDecl(.List, .close),
            .list_cons = in.coreDecl(.List, .cons),
            .list_append = in.coreDecl(.List, .append),
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

        // A `Js` intrinsic written in place — a call's callee, or a
        // constant — is JavaScript and not a reference (research 47), so
        // its instruction adds no edge and the sibling is not imported.
        const in_place = try b.jsInPlace(bir, m);

        const decl_at = try b.scratch.alloc(u32, bir.decls.len + 1);
        var decl_targets: std.ArrayList(Target) = .empty;
        var twin_extra: std.ArrayList(TwinEdge) = .empty;
        var guards: Guards = .{ .b = b, .m = m };
        var nodes: std.ArrayList(Node) = .empty;
        for (bir.decls, 0..) |d, i| {
            decl_at[i] = @intCast(decl_targets.items.len);
            switch (d.kind) {
                // A foreign binding's body is in a sibling file; a type, an
                // alias and a foreign type emit nothing at all.
                .value => {},
                .foreign_value, .type, .type_alias, .foreign_type, .annotation_only, .schema, .vocab_element, .vocab_attribute, .vocab_event, .vocab_markup => continue,
            }
            try guards.declaration(d);
            b.stream.clearRetainingCapacity();
            b.at.clearRetainingCapacity();
            try Edges.declEdgesAt(&b.stream, &b.at, b.scratch, bir, dispatch, @intCast(i), filter);
            if (b.in.vocabulary) |vocabulary| try Edges.markupEdgesAt(&b.stream, &b.at, b.scratch, bir, dispatch, @intCast(i), vocabulary);
            // Most edges become exactly one node, so one reservation per
            // declaration is the growth the resolve loop would otherwise do
            // a word at a time.
            try decl_targets.ensureUnusedCapacity(b.scratch, b.stream.items.len);
            for (b.stream.items, b.at.items) |edge, position| {
                // A leg-1 row has no position. The `.top` instruction made
                // with it is guarded where it stands, so the row adds an
                // edge only when no instruction names its target.
                if (position != Edges.no_position and position < in_place.len and in_place[position]) continue;
                const chain = if (position == Edges.no_position) blk: {
                    if (edge == .top and guards.namesTop(edge.top)) continue;
                    break :blk 0;
                } else guards.at(position);
                nodes.clearRetainingCapacity();
                try b.resolve(m, edge, &nodes);
                for (nodes.items) |node| try decl_targets.append(b.scratch, .{ .node = node, .chain = chain });
            }
            try guards.constructions(&decl_targets);
            try b.effectEdges(m, @intCast(i), &guards, &decl_targets, &twin_extra);
            try b.listEdges(m, bir, d, &decl_targets);
        }
        decl_at[bir.decls.len] = @intCast(decl_targets.items.len);

        // A declaration's suspendable body (§16.2) reaches what its direct
        // one does, and the suspendable bodies its `poly` answers choose.
        const twin_at = try b.scratch.alloc(u32, bir.decls.len + 1);
        var twin_targets: std.ArrayList(Target) = .empty;
        for (0..bir.decls.len) |i| {
            twin_at[i] = @intCast(twin_targets.items.len);
            if (!dispatch.effectDecl(@intCast(i)).twin) continue;
            try twin_targets.appendSlice(b.scratch, decl_targets.items[decl_at[i]..decl_at[i + 1]]);
            for (twin_extra.items) |x| if (x.decl == i) try twin_targets.append(b.scratch, x.target);
        }
        twin_at[bir.decls.len] = @intCast(twin_targets.items.len);

        const derived_at = try b.scratch.alloc(u32, dispatch.derived.len + 1);
        var derived_targets: std.ArrayList(Target) = .empty;
        for (0..dispatch.derived.len) |i| {
            derived_at[i] = @intCast(derived_targets.items.len);
            b.stream.clearRetainingCapacity();
            try Edges.derivedEdges(&b.stream, b.scratch, dispatch, @intCast(i));
            for (b.stream.items) |edge| {
                nodes.clearRetainingCapacity();
                try b.resolve(m, edge, &nodes);
                for (nodes.items) |node| try derived_targets.append(b.scratch, .{ .node = node });
            }
        }
        derived_at[dispatch.derived.len] = @intCast(derived_targets.items.len);

        return .{
            .decl_at = decl_at,
            .decl_targets = decl_targets.items,
            .derived_at = derived_at,
            .derived_targets = derived_targets.items,
            .twin_at = twin_at,
            .twin_targets = twin_targets.items,
            .chains = guards.chains.items,
            .chain_ctors = guards.chain_ctors.items,
        };
    }

    /// Per instruction of `bir`, whether it is a `Js` intrinsic `Lower`
    /// writes in place (`JsIntrinsic`): the callee of a `call`, or `null`,
    /// `undefined` and `development` wherever they stand. Empty without an
    /// interner.
    fn jsInPlace(b: *Builder, bir: *const Bir, m: Graph.Index) Allocator.Error![]const bool {
        const interner = b.in.interner orelse return &.{};
        const dispatch = b.in.dispatchOf(m);
        const tags = bir.insts.items(.tag);
        const data = bir.insts.items(.data);
        const marks = try b.scratch.alloc(bool, bir.insts.len);
        @memset(marks, false);
        for (tags, data, 0..) |tag, d, i| switch (tag) {
            .call => if (d.lhs < marks.len) {
                // A `++` on lists calls `List.append` (`listEdges`), and
                // its `Basics.append` is no reference.
                if (dispatch.isListAppend(@enumFromInt(i))) {
                    marks[d.lhs] = true;
                } else if (JsIntrinsic.of(b.in.graph, b.in.interfaces, bir, @enumFromInt(d.lhs), interner) != null) {
                    marks[d.lhs] = true;
                } else if (Operator.of(b.in.graph, b.in.interfaces, bir, m, @enumFromInt(d.lhs), interner)) |which| {
                    // An operator is written in place when the call passes
                    // its arity (`Lower.callExpr`), which a saturated call
                    // always does.
                    if (bir.subRange(@enumFromInt(d.rhs)).len() == which.arity()) marks[d.lhs] = true;
                }
            },
            .ext_value => if (JsIntrinsic.of(b.in.graph, b.in.interfaces, bir, @enumFromInt(i), interner)) |which| {
                if (which == .null or which == .undefined or which == .development) marks[i] = true;
            },
            else => {},
        };
        return marks;
    }

    /// The `core/List` edges of declaration `d` that no instruction names
    /// (`list_get` and the rest): `unsafeGet`, `view`, `base` and `offset`
    /// when it holds a list pattern — the last two for a loop that walks
    /// its list by a scalar view (`backend.md` §8), which only lowering
    /// decides — `slice` when one has an item after its spread
    /// (`[ ...init, last ]`), and `close` when it calls `List.cons` in a way
    /// a building loop's step can (`isBuildingStep`) — the loop's exit
    /// calls it (`backend.md` §8). Coarse by a little: a pattern that reads no
    /// element or binds no tail still keeps the two alive, which costs
    /// their export and never a wrong program.
    fn listEdges(b: *Builder, m: Graph.Index, bir: *const Bir, d: Bir.Decl, out: *std.ArrayList(Target)) Allocator.Error!void {
        var pattern = false;
        var end = false;
        var cons = false;
        var append = false;
        const dispatch = b.in.dispatchOf(m);
        const list = b.in.graph.lookup(.core, InternPool.WellKnown.List.symbol());
        var inst = d.inst_start.int();
        while (inst < d.inst_end.int() and inst < bir.insts.len) : (inst += 1) {
            const at: Bir.Inst.Index = @enumFromInt(inst);
            const data = bir.instData(at);
            switch (bir.instTag(at)) {
                .pat_list => {
                    pattern = true;
                    const items = bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index);
                    for (items, 0..) |item, k| {
                        if (bir.instTag(item) == .pat_spread and k + 1 < items.len) end = true;
                    }
                },
                .call => {
                    if (!append and dispatch.isListAppend(at)) append = true;
                    if (!cons and list != null) cons = b.isBuildingStep(m, bir, list.?, data);
                },
                else => {},
            }
        }
        const picks = [_]struct { bool, ?Node }{
            .{ pattern, b.list_get },
            .{ pattern, b.list_view },
            .{ pattern, b.list_base },
            .{ pattern, b.list_offset },
            .{ end, b.list_slice },
            .{ cons, b.list_close },
            .{ append, b.list_append },
        };
        for (picks) |pick| {
            if (!pick[0]) continue;
            if (pick[1]) |node| try out.append(b.scratch, .{ .node = node, .chain = 0 });
        }
    }

    /// Whether the call `data` could be a step of a building loop (§8,
    /// *Tail calls modulo cons, onto an array*), whose exit calls `close`:
    /// a call of `List.cons` whose tail is itself a call, a `let` or a
    /// `case` — what a step's tail must be to reach the self-call. A cons
    /// onto a name, a literal or a parameter (`[ x, ...acc ]`) never is,
    /// so a program that only prepends onto what it holds ships no `close`.
    fn isBuildingStep(b: *Builder, m: Graph.Index, bir: *const Bir, list: Graph.Index, data: Bir.Inst.Data) bool {
        const cons_node = b.list_cons orelse return false;
        const callee: Bir.Inst.Index = @enumFromInt(data.lhs);
        if (callee.int() >= bir.insts.len) return false;
        const named = switch (bir.instTag(callee)) {
            .ext_value => blk: {
                const d = bir.instData(callee);
                if (d.lhs != @intFromEnum(list)) break :blk false;
                const t = b.twinOfExt(list, d.rhs) orelse break :blk false;
                break :blk t.index == cons_node.index;
            },
            .top => m == list and bir.instData(callee).lhs == cons_node.index,
            else => false,
        };
        if (!named) return false;
        const args = bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index);
        if (args.len != 2) return false;
        return switch (bir.instTag(args[1])) {
            .call, .let, .case => true,
            else => false,
        };
    }

    /// An edge only a declaration's suspendable body has.
    const TwinEdge = struct { decl: u32, target: Target };

    /// The `case`-arm guards of one module's declarations (`backend.md` §9,
    /// *A `case` arm on a constructor nothing builds*): for the declaration
    /// being walked, the chain every one of its instructions is under, and
    /// the constructors it builds.
    const Guards = struct {
        b: *Builder,
        m: Graph.Index,
        /// Index 0 is no chain; the rest are the module's, all its
        /// declarations', in the order they were made.
        chains: std.ArrayList(Chain) = .empty,
        chain_ctors: std.ArrayList(Node) = .empty,
        /// The declaration being walked: its first instruction, and the
        /// chain of each of its instructions.
        start: u32 = 0,
        chain_of: std.ArrayList(u32) = .empty,
        /// Its `.top` targets, for the leg-1 net.
        tops: std.ArrayList(u32) = .empty,
        /// Its instructions that are a `pat_ctor`'s head, which build
        /// nothing.
        heads: std.DynamicBitSetUnmanaged = .{},
        arms: std.ArrayList(Arm) = .empty,
        stack: std.ArrayList(Open) = .empty,

        const Arm = struct { from: u32, to: u32, start: u32, end: u32 };
        const Open = struct { to: u32, chain: u32 };

        fn declaration(g: *Guards, d: Bir.Decl) Allocator.Error!void {
            const scratch = g.b.scratch;
            const bir = g.b.in.birOf(g.m);
            if (g.chains.items.len == 0) try g.chains.append(scratch, .{ .parent = 0, .start = 0, .end = 0 });
            const tags = bir.insts.items(.tag);
            const data = bir.insts.items(.data);
            const start: u32 = @intCast(@min(d.inst_start.int(), bir.insts.len));
            const end: u32 = @intCast(@min(d.inst_end.int(), bir.insts.len));
            g.start = start;
            g.chain_of.clearRetainingCapacity();
            try g.chain_of.appendNTimes(scratch, 0, end - start);
            g.tops.clearRetainingCapacity();
            g.arms.clearRetainingCapacity();
            try g.heads.resize(scratch, end - start, false);
            g.heads.unsetAll();

            // Every arm whose pattern names a constructor that can be a
            // guard: its body is `(pattern root, body root]` (`Bir` is
            // post-order; `bir/Lower.lowerBranch`).
            for (tags[start..end], data[start..end], start..) |tag, payload, p| switch (tag) {
                .top => try g.tops.append(scratch, payload.lhs),
                .pat_ctor => if (payload.lhs >= start and payload.lhs < end) g.heads.set(payload.lhs - start),
                .branch => {
                    const pattern = payload.lhs;
                    const body = payload.rhs;
                    if (!(pattern >= start and pattern < body and body < p)) continue;
                    const first: u32 = @intCast(g.chain_ctors.items.len);
                    try g.patternCtors(@enumFromInt(pattern), 0);
                    if (g.chain_ctors.items.len == first) continue;
                    try g.arms.append(scratch, .{ .from = pattern + 1, .to = body, .start = first, .end = @intCast(g.chain_ctors.items.len) });
                },
                // The arm of an `if Js.development` this build does not
                // take (`backend.md` §4, *`Js.development` is the build's
                // mode*): guarded by a constructor no build reaches, so no
                // edge out of it is ever followed.
                .case => if (g.b.in.interner) |interner| {
                    const branch = JsIntrinsic.droppedArm(g.b.in.graph, g.b.in.interfaces, bir, @enumFromInt(@as(u32, @intCast(p))), interner, g.b.in.release) orelse continue;
                    const arm = bir.instData(branch);
                    if (!(arm.lhs >= start and arm.lhs < arm.rhs and arm.rhs < p)) continue;
                    const first: u32 = @intCast(g.chain_ctors.items.len);
                    try g.chain_ctors.append(scratch, .{ .module = g.m, .kind = .ctor, .index = std.math.maxInt(u32) });
                    try g.arms.append(scratch, .{ .from = arm.lhs + 1, .to = arm.rhs, .start = first, .end = first + 1 });
                },
                else => {},
            };
            std.mem.sort(u32, g.tops.items, {}, std.sort.asc(u32));
            if (g.arms.items.len == 0) return;

            // Outer arms first where two begin together; then one sweep,
            // the open arms a stack. Arms of one tree nest, and a pair that
            // did not would leave every position of the declaration
            // unguarded — more kept, never less.
            std.mem.sort(Arm, g.arms.items, {}, struct {
                fn lessThan(_: void, a: Arm, x: Arm) bool {
                    return a.from < x.from or (a.from == x.from and a.to > x.to);
                }
            }.lessThan);
            g.stack.clearRetainingCapacity();
            var next: usize = 0;
            for (start..end) |p| {
                while (g.stack.items.len != 0 and g.stack.items[g.stack.items.len - 1].to < p) _ = g.stack.pop();
                while (next < g.arms.items.len and g.arms.items[next].from <= p) : (next += 1) {
                    const arm = g.arms.items[next];
                    const parent: u32 = if (g.stack.items.len == 0) 0 else g.stack.items[g.stack.items.len - 1].chain;
                    if (g.stack.items.len != 0 and g.stack.items[g.stack.items.len - 1].to < arm.to) {
                        @memset(g.chain_of.items, 0);
                        return;
                    }
                    const chain: u32 = @intCast(g.chains.items.len);
                    try g.chains.append(scratch, .{ .parent = parent, .start = arm.start, .end = arm.end });
                    try g.stack.append(scratch, .{ .to = arm.to, .chain = chain });
                }
                if (g.stack.items.len != 0) g.chain_of.items[p - start] = g.stack.items[g.stack.items.len - 1].chain;
            }
        }

        /// The chain the instruction at `position` is under.
        fn at(g: *const Guards, position: u32) u32 {
            if (position < g.start or position - g.start >= g.chain_of.items.len) return 0;
            return g.chain_of.items[position - g.start];
        }

        /// Whether an instruction of the declaration is a `.top` of `decl`.
        fn namesTop(g: *const Guards, decl: u32) bool {
            return std.sort.binarySearch(u32, g.tops.items, decl, struct {
                fn order(key: u32, item: u32) std.math.Order {
                    return std.math.order(key, item);
                }
            }.order) != null;
        }

        /// The constructors a pattern names, at any depth, that can guard:
        /// not `core`'s, which are always reached.
        fn patternCtors(g: *Guards, pattern: Bir.Inst.Index, depth: u32) Allocator.Error!void {
            if (depth > 64) return;
            const bir = g.b.in.birOf(g.m);
            if (pattern.int() >= bir.insts.len) return;
            const d = bir.instData(pattern);
            switch (bir.instTag(pattern)) {
                .pat_ctor => {
                    if (g.ctorNode(@enumFromInt(d.lhs))) |node| try g.chain_ctors.append(g.b.scratch, node);
                    for (bir.extraSlice(bir.subRange(@enumFromInt(d.rhs)), Bir.Inst.Index)) |arg| try g.patternCtors(arg, depth + 1);
                },
                .pat_tuple, .pat_list => for (bir.extraSlice(Bir.inlineRange(d), Bir.Inst.Index)) |e| try g.patternCtors(e, depth + 1),
                .pat_as => try g.patternCtors(@enumFromInt(d.lhs), depth + 1),
                else => {},
            }
        }

        /// The node of the constructor a `ctor`/`ext_ctor` instruction
        /// names, or null for `core`'s and for anything else.
        fn ctorNode(g: *const Guards, ref: Bir.Inst.Index) ?Node {
            const in = g.b.in;
            const bir = in.birOf(g.m);
            if (ref.int() >= bir.insts.len) return null;
            const d = bir.instData(ref);
            const owner: Graph.Index, const index: u32 = switch (bir.instTag(ref)) {
                .ctor => .{ g.m, d.lhs },
                .ext_ctor => .{ @enumFromInt(d.lhs), ctorOfExt(in.provenance, @enumFromInt(d.lhs), d.rhs) orelse return null },
                else => return null,
            };
            if (owner.int() >= in.graph.count()) return null;
            if (in.store.package(in.graph.moduleFile(owner)) == .core) return null;
            return .{ .module = owner, .kind = .ctor, .index = index };
        }

        /// Every constructor the declaration builds — a `ctor`/`ext_ctor`
        /// that is not a pattern's head — as an edge where it stands.
        fn constructions(g: *Guards, out: *std.ArrayList(Target)) Allocator.Error!void {
            const bir = g.b.in.birOf(g.m);
            const tags = bir.insts.items(.tag);
            const start = g.start;
            const end: u32 = start + @as(u32, @intCast(g.chain_of.items.len));
            for (tags[start..end], start..) |tag, p| {
                if (tag != .ctor and tag != .ext_ctor) continue;
                if (g.heads.isSet(p - start)) continue;
                const node = g.ctorNode(@enumFromInt(p)) orelse continue;
                try out.append(g.b.scratch, .{ .node = node, .chain = g.chain_of.items[p - start] });
            }
        }
    };

    /// The edges the effect answers add (transparent-effects-proposal.md
    /// §16.2): a reference or a method call that takes a target's
    /// suspendable body — always (`yes`), into both of `decl`'s bodies, or
    /// only in its own suspendable one (`poly`, into `twin`) — evidence
    /// naming a declaration with two bodies, which takes the suspendable one
    /// wherever it is passed; and core's `Task.andThen` and `Task.isWaiting`,
    /// which the code of a body that may suspend calls.
    fn effectEdges(b: *Builder, m: Graph.Index, decl: u32, guards: *const Guards, direct: *std.ArrayList(Target), twin: *std.ArrayList(TwinEdge)) Allocator.Error!void {
        const bir = b.in.birOf(m);
        const dispatch = b.in.dispatchOf(m);
        const d = bir.decls[decl];
        const sites = dispatch.effectsIn(d.inst_start.int(), d.inst_end.int());
        const own = dispatch.effectDecl(decl).own;
        if (sites.len == 0 and own == .no) return;
        var protocol: Dispatch.Suspend = own;
        for (sites) |s| {
            if (s.own == .yes) protocol = .yes else if (s.own == .poly and protocol == .no) protocol = .poly;
            if (s.body == .no) continue;
            const node = b.bodyTarget(m, s.inst) orelse continue;
            const target: Target = .{ .node = node, .chain = guards.at(s.inst.int()) };
            if (s.body == .yes) try direct.append(b.scratch, target) else try twin.append(b.scratch, .{ .decl = decl, .target = target });
        }
        // Evidence a site passes takes the body the site's callee takes.
        for (dispatch.sitesIn(d.inst_start.int(), d.inst_end.int())) |site| {
            const choice = dispatch.evidenceChoice(bir, site.inst);
            if (choice == .no) continue;
            try b.evidenceTwins(m, dispatch.argsAt(site.evidence), decl, choice, guards.at(site.inst.int()), direct, twin);
        }
        if (protocol == .no) return;
        const task = b.in.graph.lookup(.core, InternPool.WellKnown.Task.symbol()) orelse return;
        const task_bir = b.in.birOf(task);
        for (task_bir.decls, 0..) |td, i| {
            if (td.kind != .foreign_value) continue;
            const name = task_bir.symbol(td.name);
            if (name != InternPool.WellKnown.andThen.symbol() and name != InternPool.WellKnown.isWaiting.symbol()) continue;
            const target: Target = .{ .node = .{ .module = task, .kind = .decl, .index = @intCast(i) } };
            if (protocol == .yes) try direct.append(b.scratch, target) else try twin.append(b.scratch, .{ .decl = decl, .target = target });
        }
    }

    /// The suspendable body a reference or a method call at `inst` names.
    fn bodyTarget(b: *Builder, m: Graph.Index, inst: Bir.Inst.Index) ?Node {
        const bir = b.in.birOf(m);
        const dispatch = b.in.dispatchOf(m);
        const data = bir.instData(inst);
        return switch (bir.instTag(inst)) {
            .top => .{ .module = m, .kind = .twin, .index = data.lhs },
            .ext_value => b.twinOfExt(@enumFromInt(data.lhs), data.rhs),
            .method_call, .type_dispatch => blk: {
                const site = dispatch.siteOf(inst) orelse break :blk null;
                const callee = site.callee.unwrap() orelse break :blk null;
                break :blk switch (dispatch.term(callee)) {
                    .top => |u| .{ .module = m, .kind = .twin, .index = u.decl.int() },
                    .ext => |e| b.twinOfExt(e.module, @intFromEnum(e.value)),
                    else => null,
                };
            },
            else => null,
        };
    }

    fn twinOfExt(b: *Builder, m: Graph.Index, value: u32) ?Node {
        if (m.int() >= b.in.provenance.len) return null;
        const d = b.in.provenance[m.int()].valueDecl(value) orelse return null;
        return .{ .module = m, .kind = .twin, .index = d.int() };
    }

    /// Every declaration with two bodies that `roots` name, as evidence a
    /// site passes whose callee takes its suspendable body (`choice`): the
    /// evidence takes its suspendable body too (§16.2).
    fn evidenceTwins(b: *Builder, m: Graph.Index, roots: []const Dispatch.TermIndex, decl: u32, choice: Dispatch.Suspend, chain: u32, direct: *std.ArrayList(Target), twin: *std.ArrayList(TwinEdge)) Allocator.Error!void {
        if (roots.len == 0) return;
        const dispatch = b.in.dispatchOf(m);
        var edges: std.ArrayList(Edges.Edge) = .empty;
        defer edges.deinit(b.scratch);
        try Edges.termsEdges(&edges, b.scratch, dispatch, roots, false);
        for (edges.items) |edge| {
            const node: Node = switch (edge) {
                .top => |t| .{ .module = m, .kind = .twin, .index = t },
                .ext => |e| b.twinOfExt(e.module, e.value) orelse continue,
                else => continue,
            };
            if (!b.in.dispatchOf(node.module).effectDecl(node.index).twin) continue;
            const target: Target = .{ .node = node, .chain = chain };
            if (choice == .yes) try direct.append(b.scratch, target) else try twin.append(b.scratch, .{ .decl = decl, .target = target });
        }
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

test "a guarded edge waits on the first guard it lacks and is followed when the last arrives" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const scratch = arena.allocator();

    const m: Graph.Index = @enumFromInt(0);
    var live = [_]Live{.{
        .decls = try .initEmpty(scratch, 2),
        .derived = try .initEmpty(scratch, 0),
        .ctors = try .initEmpty(scratch, 2),
    }};
    const c0: Node = .{ .module = m, .kind = .ctor, .index = 0 };
    const c1: Node = .{ .module = m, .kind = .ctor, .index = 1 };
    // Chain 2 is an arm on `c1` inside an arm on `c0` (chain 1).
    const edges = [_]ModuleEdges{.{
        .chains = &.{ .{ .parent = 0, .start = 0, .end = 0 }, .{ .parent = 0, .start = 0, .end = 1 }, .{ .parent = 1, .start = 1, .end = 2 } },
        .chain_ctors = &.{ c0, c1 },
    }};
    var waiting: std.AutoHashMapUnmanaged(Node, std.ArrayList(Pending)) = .empty;
    var stack: std.ArrayList(Node) = .empty;
    const target: Target = .{ .node = .{ .module = m, .kind = .decl, .index = 1 }, .chain = 2 };

    // Neither arm's constructor is built: the innermost one is waited on.
    try follow(scratch, &live, &edges, &waiting, &stack, m, target);
    try testing.expect(!live[0].decl(1));
    try testing.expect(waiting.contains(c1));

    // `c1` arrives, `c0` has not: the edge moves to wait on `c0`.
    _ = mark(&live, c1);
    const on_c1 = waiting.fetchRemove(c1).?.value;
    for (on_c1.items) |p| try follow(scratch, &live, &edges, &waiting, &stack, p.module, p.target);
    try testing.expect(!live[0].decl(1));
    try testing.expect(waiting.contains(c0));

    // Both built: followed.
    _ = mark(&live, c0);
    const on_c0 = waiting.fetchRemove(c0).?.value;
    for (on_c0.items) |p| try follow(scratch, &live, &edges, &waiting, &stack, p.module, p.target);
    try testing.expect(live[0].decl(1));
    try testing.expectEqual(@as(usize, 1), stack.items.len);
}

test "an edge waits on the innermost four guarded arms around it, and no more" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const scratch = arena.allocator();

    const m: Graph.Index = @enumFromInt(0);
    var live = [_]Live{.{
        .decls = try .initEmpty(scratch, 1),
        .derived = try .initEmpty(scratch, 0),
        .ctors = try .initEmpty(scratch, 5),
    }};
    // Five arms nested, chain k on constructor k-1; only the outermost
    // constructor (0) is unbuilt.
    var ctors: [5]Node = undefined;
    var chains: [6]Chain = undefined;
    chains[0] = .{ .parent = 0, .start = 0, .end = 0 };
    for (0..5) |k| {
        ctors[k] = .{ .module = m, .kind = .ctor, .index = @intCast(k) };
        chains[k + 1] = .{ .parent = @intCast(k), .start = @intCast(k), .end = @intCast(k + 1) };
        if (k != 0) _ = mark(&live, ctors[k]);
    }
    const edges: ModuleEdges = .{ .chains = &chains, .chain_ctors = &ctors };
    // From the innermost arm the outermost is the fifth: past the cap, so
    // nothing blocks — a condition dropped, which keeps more and never less.
    try testing.expectEqual(@as(?Node, null), edges.blocker(&live, 5));
    // From the fourth arm in, it is within the cap and blocks.
    try testing.expectEqual(@as(?Node, ctors[0]), edges.blocker(&live, 4));
    try testing.expectEqual(@as(?Node, null), edges.blocker(&live, 0));
}
