//! The per-module context the shared diagnostic texts read
//! (`Diagnostics.Reporter.env`), and v1's generator and solver with them.
//! Moved out of v1's `Constrain.zig` by R4b's review (S2): `Diagnostics.zig`
//! is kept at R12 and `Constrain.zig` is not, so the texts may not depend on
//! it. v2 builds one only inside `check2/Report.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Artifacts = @import("../Artifacts.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const reads = @import("reads.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Schema = @import("Schema.zig");
const Dispatch = @import("Dispatch.zig");

pub const Var = TypeStore.Var;
pub const Symbol = InternPool.Symbol;
pub const Error = Allocator.Error;

/// One `let` binding rule (a) refused to generalise; see `Env.monomorphic`.
pub const Monomorphic = struct { v: Var, method: Symbol };

/// A plain `eq`/`compare` scheme (`Solve.Solver.plainMethodMask`): its
/// receiver type, and which of the receiver's arguments carry the method.
pub const PlainMethod = struct { receiver: Types.TypeId, mask: u64 };

/// Everything one module's check needs. Built once by `Check`, handed to the
/// generator and then to the solver; a module's check reads only its own Bir,
/// the interfaces of its imports and the store it owns, which is the
/// property checker.md §4.4 needs for DAG parallelism later.
pub const Env = struct {
    scratch: Allocator,
    store: *TypeStore,
    types: *const Types,
    graph: *const Graph,
    artifacts: *const Artifacts,
    interner: *const InternPool.Global,
    interfaces: []const Interface,
    module: Graph.Index,
    bir: *const Bir,
    schemas: ?*Schema.State = null,
    /// Per module: whether an imported `eq`/`compare` value has a PLAIN
    /// scheme (`Solve.Solver.plainMethodMask`), keyed by module and value.
    /// Null for a scheme that is not plain. Lives in `scratch`.
    plain_methods: std.AutoHashMapUnmanaged(u64, ?PlainMethod) = .empty,
    /// Scheme variable per top-level declaration; `.none` for a type or for
    /// a value whose scheme is not built yet.
    decl_scheme: []Var.Optional,
    /// Per local of the declaration being checked. Indices in the Bir are
    /// relative to the declaration, so this is a SLICE of the module's
    /// table and `locals_base` is where it starts — anything that reaches
    /// past this slice into `bir.locals` has to add it.
    local_var: []Var.Optional,
    /// The declaration's `locals_start`.
    locals_base: u32 = 0,
    /// Per instruction of the declaration being checked, relative to
    /// `inst_base`: the RESULT variable of a `let_def`, which `?` needs
    /// (checker.md §6.5). Only `let_def` slots are filled.
    inst_result: []Var.Optional,
    inst_base: u32,
    /// The enclosing declaration's result variable, for a `?` whose target
    /// is the declaration itself.
    decl_result: Var.Optional = .none,
    /// The declaration being checked, and its annotation's rigid type
    /// variables in first-appearance order (static-dispatch-spike.md §2.4,
    /// §4.2). Empty for an unannotated declaration; `decl` is
    /// `Bir.decls.len` when nothing is being checked.
    decl: u32 = 0,
    decl_rigids: []const Types.Builder.Scoped = &.{},
    /// Which evidence parameter answers each `(rigid variable, method)` of
    /// this module's annotated declarations, in the canonical order of
    /// §7.2. Flat across the module: a rigid variable belongs to exactly
    /// one declaration, so the variable alone identifies the entry.
    rigid_evidence: []const Dispatch.RigidEvidence = &.{},
    /// Every variable §6.4 rule (a) held back from a `let` generalisation,
    /// with the constraint that held it.
    ///
    /// It exists for ONE message. The boundary A.30 buys surfaces as an
    /// ordinary `type_mismatch` at the second use, by which time the
    /// constraint has been discharged against the first use's type and
    /// nothing in the store says why the binding was monomorphic. Without
    /// this the hint on that message told the author to check their
    /// arithmetic (M7).
    monomorphic: *std.ArrayList(Monomorphic),
    /// The module's dispatch table as it is built (§7.1). Owned by
    /// `ModuleCheck`; the solver appends to it and `finish` sorts it once.
    dispatch: *Dispatch.Builder,
    /// Emit the informational `warning`s of §10 — today only
    /// `ambiguous_method_receiver` (§10.9), and then only for a module of
    /// the ROOT package. True under `check` and `build` (A.83).
    informational: bool = false,
    /// Written types the reader could not finish (`Types.Builder.max_depth`,
    /// `Schemes.Writer.max_depth`), by the instruction a message points at.
    ///
    /// Collected rather than reported where the guard trips, for two
    /// reasons: the reader crosses modules (an alias body is read in ITS
    /// module, so the instruction it gave up on names no position here),
    /// and the same annotation is read more than once — once generalised
    /// for callers, once rigid for the body. `Check` sorts, deduplicates
    /// and reports this once per module. Empty on every input a person
    /// writes.
    too_deep: *std.ArrayList(Bir.Inst.Index),

    /// Another module's interface record, noted for the covered-read
    /// self-check (`reads.zig`, `plans/m4-3.md` §3.2 rows 17–22 and 25–27).
    ///
    /// **Every cross-module read of `interfaces` on the checking path goes
    /// through this**, which is what makes the `&interfaces[N]` handoff one of
    /// the three channels the enumeration is finite over. Callers keep their
    /// own bounds tests: this is a note, not a guard.
    pub fn iface(env: *const Env, m: Graph.Index) *const Interface {
        reads.note(.iface, m);
        return &env.interfaces[m.int()];
    }

    pub fn localVar(env: *const Env, index: u32) ?Var {
        if (index >= env.local_var.len) return null;
        return env.local_var[index].unwrap();
    }

    pub fn builder(env: *const Env, mode: Types.VarMode, rank: u32) Types.Builder {
        var b: Types.Builder = .init(env.store, env.types, env.graph, env.artifacts, env.module, env.bir, mode, rank, env.scratch, env.interner);
        if (env.schemas) |schemas| {
            b.schema_context = schemas;
            b.schema_lookup = Schema.State.lookupOpaque;
        }
        b.interfaces = env.interfaces;
        return b;
    }

    /// Read `annotation` with `b` and note it when the reader ran out of
    /// depth. Every caller of `Types.Builder.read` goes through this or
    /// through `noteTooDeep`, so no guard in the checker can poison a type
    /// without a message: an `err` unifies with anything, and a
    /// declaration silently turned into one is a hole a caller's mistake
    /// falls through (`fast-compiler.md` §5).
    pub fn readAnnotation(env: *const Env, b: *Types.Builder, annotation: Bir.Inst.Index) Error!Var {
        const v = try b.read(annotation);
        if (b.too_deep) try env.noteTooDeep(annotation);
        return v;
    }

    /// Note that the type at `region` was too deeply nested to read. Not
    /// deduplicated here — `Check` sorts and deduplicates at the end,
    /// because a linear scan per note is quadratic on a generated file
    /// where every declaration trips the guard.
    pub fn noteTooDeep(env: *const Env, region: Bir.Inst.Index) Error!void {
        try env.too_deep.append(env.scratch, region);
    }
};
