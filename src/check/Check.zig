//! The checker's public API and its inter-module driver (checker-v2.md §5,
//! §19.1; checker.md §4.4): `run`, `Module`, `Options`, `Cutoff`.
//! `Driver.zig` walks the DAG, `Incremental.zig` finishes keys, loads,
//! installs and publishes, and each module is checked by `Module.zig`.
//!
//! **Order.** Modules are checked over the graph's topological order, so
//! every import's interface is complete — and immutable — before anything
//! reads it. `Driver` walks that order as a DAG (§4.4): a module whose
//! dependencies have all finished may start, on any worker, and the bound
//! that makes it safe is the interface firewall — a module's check reads
//! only its own Bir, the interfaces of its imports, and the store it owns,
//! and the one thing it shares with another module's check is the
//! session-wide `Types` table, which is built before any thread starts.
//! Each worker writes only its own module's slot of the table (`ref_ids`)
//! before releasing dependents. Nothing is keyed by completion order; see
//! `Driver`'s header for what makes the output identical at every
//! `--jobs`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Arena = @import("../Arena.zig");
const Artifacts = @import("../Artifacts.zig");
const Profile = @import("../Profile.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const Diagnostics = @import("Diagnostics.zig");
const Dispatch = @import("Dispatch.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const SchemaPlan = @import("SchemaPlan.zig");
const reads = @import("reads.zig");
const CacheEntry = @import("../cache/Entry.zig");
const CacheDir = @import("../cache/Dir.zig");
const CorePack = @import("../cache/Pack.zig");
const Key = @import("../cache/Key.zig");
const Digest = @import("../cache/Digest.zig");
const Driver = @import("Driver.zig");

const Check = @This();

/// Re-exported so `Session` can name the pattern-usefulness budget without
/// reaching past the checker's driver into its internals.
pub const Exhaustive = @import("Exhaustive.zig");
pub const Var = TypeStore.Var;
pub const Symbol = InternPool.Symbol;
pub const Error = Allocator.Error;

/// What `--self-profile` reports, and what the incrementality tests can
/// assert did NOT move when only a body changed (checker.md §9).
pub const Counters = struct {
    unifications: u64 = 0,
    generalisations: u64 = 0,
    instantiations: u64 = 0,
    /// The derived-context fixpoints the checker ran (`Contexts.run`,
    /// checker-v2.md §11.2), summed over the modules it CHECKED. A module
    /// installed from the cache runs none: its rows are read off its record
    /// (§14.3), which is what a warm run's 0 here says.
    derived_context_runs: u64 = 0,

    /// Field-by-field sum. Reflective on purpose: a counter added above and
    /// forgotten here would silently report a per-module figure as if it
    /// were the whole project's.
    pub fn add(a: Counters, b: Counters) Counters {
        var out: Counters = .{};
        inline for (@typeInfo(Counters).@"struct".field_names) |field_name| {
            @field(out, field_name) = @field(a, field_name) + @field(b, field_name);
        }
        return out;
    }
};

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
    /// would name the same `a` twice over, so the dump prints a third
    /// reading over the rigid reading's variables, which nothing unifies:
    /// the rigid reading's own alias names may have met others and show
    /// their expansions (checker-v2.md §7.1).
    decl_display: []Var.Optional,
    /// Type per local, indexed exactly like `Bir.locals`.
    local_type: []Var.Optional,
    /// What effect inference solved over `store`, for the dump's classes
    /// (transparent-effects-proposal.md §14.7); null for a module the run
    /// did not check.
    effects: ?Effects = null,

    pub fn release(m: *Module, gpa: Allocator) void {
        if (m.effects) |*e| e.deinit();
        m.store.deinit();
        gpa.free(m.decl_scheme);
        gpa.free(m.decl_display);
        gpa.free(m.local_type);
    }
};

const Effects = @import("Effects.zig");

/// Owned. The session-wide type table.
types: Types,
/// Owned. Diagnostics in module-check order; the session sorts.
diagnostics: []const Diagnostics.Item,
/// Owned when `modules.len != 0`: one per graph module, in module index
/// order. Empty unless the run asked to keep them.
modules: []Module,
/// Owned. One per graph module, in module index order: what the checker
/// decided about every method call (static-dispatch-spike.md §7).
///
/// Kept whatever `keep_stores` says, unlike `modules`: the backend needs it
/// on every build, and it holds no `Var` — everything in it is an index or a
/// name that outlives the store.
dispatch: []Dispatch,
/// Resolved immutable schema plan per module.
plans: []SchemaPlan,
counters: Counters,

pub const empty: Check = .{ .types = .empty, .diagnostics = &.{}, .modules = &.{}, .dispatch = &.{}, .plans = &.{}, .counters = .{} };

pub fn deinit(check: *Check, gpa: Allocator) void {
    check.types.deinit(gpa);
    for (check.diagnostics) |d| gpa.free(d.message);
    gpa.free(check.diagnostics);
    for (check.modules) |*m| m.release(gpa);
    gpa.free(check.modules);
    for (check.dispatch) |*d| d.deinit(gpa);
    gpa.free(check.dispatch);
    for (check.plans) |*plan| plan.deinit(gpa);
    gpa.free(check.plans);
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
    /// Emit the informational `warning`s of static-dispatch-spike.md §10 —
    /// today only `ambiguous_method_receiver` (§10.9), and then only for a
    /// module of the ROOT package. Set by `check` and `build` (A.83); a
    /// warning never changes the exit code.
    informational: bool = false,
    /// `--explain`: `unit_discarded` too (checker-v2.md §34), until the
    /// enforce step emits it by default.
    explain: bool = false,
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
    /// How many workers may check modules at once (checker.md §4.4). One
    /// runs everything on the calling thread and spawns nothing, which is
    /// what every hermetic test and every small project wants.
    jobs: u32 = 1,
    /// `jobs` is a ceiling and the pool is sized by the work: one checker
    /// per `tokens_per_checker` tokens of the modules still to check
    /// (`Session.Options.size_by_work`).
    size_by_work: bool = false,
    /// Work one `case` may spend on pattern usefulness before it is
    /// abandoned and reports nothing (`Exhaustive.default_budget`).
    /// Settable so a test can prove the bound is what makes it fall silent,
    /// rather than asserting the absence of a hang.
    pattern_budget: u32 = Exhaustive.default_budget,
    /// `--roundtrip-interfaces` (`fast-compiler.md` §8): replace every
    /// module's record with serialize → bytes → deserialize of itself, in
    /// place, the moment its check finishes — so every dependent, every
    /// dump, every dispatch table and every emitted file downstream is
    /// built from bytes that have been through the format.
    roundtrip_interfaces: bool = false,
    /// `--roundtrip-dispatch` (`fast-compiler.md` §8), the twin of the flag
    /// above for the cache entry's sidecar: write every module's dispatch
    /// table to bytes, read it back and re-resolve it IN PLACE the moment
    /// its check finishes, so every emitted file downstream is built from a
    /// table that has been through the format.
    ///
    /// It matters more than its twin does. The record has `dump --stage=raw`
    /// and a golden; the dispatch table's loss shows up as different
    /// JavaScript or a `requireLive` failure, which is a wrong PROGRAM, and
    /// `plans/m4-plan.md` §8 risk 2 names the sidecar as where a silent
    /// miscompile can hide.
    roundtrip_dispatch: bool = false,
    /// One slot per graph module: the cache entry a serial pre-pass loaded
    /// for it, or null (`fast-compiler.md` §8). A non-null slot is a HIT —
    /// the whole of `Module.check` is skipped and the entry is installed
    /// instead.
    ///
    /// The slots are borrowed. The hit path MOVES the record and the table
    /// out and leaves `.empty` behind; the caller still owns the entry's
    /// bytes and frees them afterwards.
    cached: []?CacheEntry.Loaded = &.{},
    /// The firewall cutoff's per-module work (`fast-compiler.md` §8). Null on
    /// a run that computes no keys at all — every checking run has one.
    cutoff: ?*Cutoff = null,
};

/// The key, the entry load and the two published values, done ON THE WORKER
/// that claimed the module (`fast-compiler.md` §8, `plans/m4-3.md` §8).
///
/// **Why it is not a serial pre-pass.** An import contributes its
/// `(interface hash, dependency digest)` pair, and that pair exists only
/// once the import has been CHECKED or LOADED — so a serial pass could only
/// finish the keys of modules all of whose imports hit, and the case the
/// cutoff exists for is precisely the one where an import MISSED and was
/// re-checked to the same interface.
///
/// **What makes it deterministic** is that a key is a function of `own_terms`
/// and of values published by modules the schedule guarantees are complete
/// before this one is released (`buildSchedule`, `finish`), so no key's value
/// depends on which worker got there first. **One writer per slot**, the
/// discipline `interfaces[m]`, `dispatch[m]` and `types.ref_ids[m]` already
/// keep. And at `--jobs=1` the serial walk is `graph.order`, so keys are
/// finished in the graph's order — one code path and one scheduling rule.
pub const Cutoff = struct {
    /// The serial pass's `own_terms` blobs, and the slots this fills.
    keys: *Key.Keys,
    /// The cache directory, or null. A run with none still finishes every
    /// key: one code path, and "was a key computed?" is exactly the kind of
    /// condition a cache bug hides behind.
    dir: ?*const CacheDir = null,
    /// The checked core the binary carries (`fast-compiler.md` §8, *The
    /// checked core, embedded*), looked up before `dir` for a module
    /// `packable` names. `empty` when the run reads its core from anywhere
    /// else.
    pack: CorePack.Pack = .empty,
    /// One slot per module: whether it may be installed from `pack` — a
    /// module of the embedded core or of a platform the binary carries
    /// (`Session.packCovers`). A module past the end may not.
    packable: []const bool = &.{},
    /// One slot per module, beside `hit`: whether the hit came from `pack`
    /// rather than from `dir`.
    embedded: []bool = &.{},
    /// Read-only, and read-only is the point: a worker re-interns through
    /// `InternPool.Global.find` (`CacheEntry.loadFinding`).
    interner: *const InternPool.Global,
    /// One slot per module, written by that module's own worker: the interface
    /// hash and the dependency digest its dependents fold into their keys.
    iface_hash: [][16]u8,
    digest: []Digest.Digest,
    /// One slot per module: whether it was a HIT. Summed after the run into
    /// the three counters `fast-compiler.md` §8's acceptance test asserts.
    hit: []bool,
    /// `--cutoff-compare` (hidden): also compute the CUTOFF key beside the one
    /// in use, so a fixture can assert the one direction that must hold —
    /// **old key equal ⇒ new key equal**. The new key is coarser and never
    /// finer; a violation would mean the new key depends on something the old
    /// transitive key did not, which is impossible unless a term is wrong.
    ///
    /// The other direction IS the cutoff, and what validates it is output
    /// identity (`plans/m4-3.md` §10.2), not an assertion.
    compare: []Key.Key = &.{},
    /// `core_surface`: one hash over the core package's sorted
    /// `(module name, interface hash, digest)` list, computed once by the
    /// driver after the last core module publishes and before any non-core
    /// module's key is finished.
    core_surface: Digest.Digest = Digest.none,
    /// `--cutoff-compare`'s own core term: `core_epoch` over core's TRANSITIVE
    /// keys, computed at the same barrier as `core_surface` so the two recipes
    /// see the same moment.
    core_epoch: Key.Key = Key.none,
};

/// Type-check every module of `graph`, filling `interfaces` with schemes.
///
/// `scratch` is the caller's arena, used for the serial path and by worker
/// zero; every other worker gets one of its own, reset after each module so
/// the peak is one module's constraints per worker and not the project's.
pub fn run(
    gpa: Allocator,
    io: Io,
    scratch: *Arena,
    graph: *const Graph,
    artifacts: *const Artifacts,
    interfaces: []Interface,
    provenance: []const Interface.Provenance,
    interner: *const InternPool.Global,
    options: Options,
) Error!Check {
    var check: Check = .empty;
    errdefer check.deinit(gpa);
    // Inside a profile event: on a project of long alias chains this step
    // was 1.3 s of a 1.35 s compile and did not appear in the trace at all,
    // and `fast-compiler.md` §12 makes the trace the instrument of record.
    const types_token = if (options.profile) |p| p.begin() else null;
    check.types = try Types.build(gpa, graph, artifacts, interfaces, provenance, interner);
    if (options.profile) |p| p.end(0, types_token.?, .types, Profile.Event.no_file, 0);

    const modules = graph.count();
    // One diagnostics list per module rather than one shared list: a shared
    // one would need a lock on the hot path AND would order messages by
    // completion, which `fast-compiler.md` §10 forbids. Concatenating them
    // in the graph's order afterwards is what makes the output identical at
    // every `--jobs`.
    const per_module = try gpa.alloc(std.ArrayList(Diagnostics.Item), modules);
    defer gpa.free(per_module);
    @memset(per_module, .empty);
    errdefer for (per_module) |*list| {
        for (list.items) |d| gpa.free(d.message);
        list.deinit(gpa);
    };
    const counters = try gpa.alloc(Counters, modules);
    defer gpa.free(counters);
    @memset(counters, .{});

    // One per module, filled at the end of that module's own check while
    // its store is still alive (§7.1). Allocated here so the driver can
    // write into it from any worker without a lock: a module writes only
    // its own slot.
    const dispatch = try gpa.alloc(Dispatch, modules);
    @memset(dispatch, .empty);
    check.dispatch = dispatch;
    const plans = try gpa.alloc(SchemaPlan, modules);
    @memset(plans, .empty);
    check.plans = plans;
    check.types.plans = plans;

    var kept: std.ArrayList(Module) = .empty;
    // Each kept `Module` owns an arena and three tables. On the OOM path
    // the list itself is not enough: the modules that DID finish have to
    // give theirs back, or the failure leaks one arena per checked module.
    errdefer {
        for (kept.items) |*m| m.release(gpa);
        kept.deinit(gpa);
    }
    if (options.keep_stores) {
        try kept.ensureTotalCapacity(gpa, modules);
        for (0..modules) |_| kept.appendAssumeCapacity(.{
            .store = .init(std.heap.page_allocator),
            .decl_scheme = &.{},
            .decl_display = &.{},
            .local_type = &.{},
        });
    }

    // What each module's key can see move, for the covered-read self-check
    // (`reads.zig`). Built once, before any worker: it is a function of the
    // graph, which is fixed before the DAG starts.
    var coverage: reads.Coverage = try .build(gpa, graph);
    defer coverage.deinit(gpa);

    // Which modules carry an error, their own or a dependency's (`Driver.tainted`).
    const tainted = try gpa.alloc(bool, modules);
    defer gpa.free(tainted);
    @memset(tainted, false);

    var driver: Driver = .{
        .tainted = tainted,
        .gpa = gpa,
        .io = io,
        .graph = graph,
        .artifacts = artifacts,
        .interfaces = interfaces,
        .provenance = provenance,
        .interner = interner,
        .types = &check.types,
        .options = options,
        .per_module = per_module,
        .counters = counters,
        .kept = if (options.keep_stores) kept.items else &.{},
        .dispatch = dispatch,
        .plans = plans,
        .coverage = coverage,
    };
    try driver.go(scratch);
    if (driver.failure) |err| return err;

    // Merge in the graph's order — the order the serial path produced them
    // in, and a function of the input alone.
    var diagnostics: std.ArrayList(Diagnostics.Item) = .empty;
    errdefer diagnostics.deinit(gpa);
    // Capacity first, then move: a partial `appendSlice` would leave some
    // messages owned by `diagnostics` and the rest by `per_module`, and the
    // two errdefers would free the moved ones twice. Reserving up front
    // makes the loop below infallible, so ownership transfers whole.
    var total: usize = 0;
    for (per_module) |list| total += list.items.len;
    try diagnostics.ensureTotalCapacity(gpa, total);
    for (graph.order) |m| diagnostics.appendSliceAssumeCapacity(per_module[m.int()].items);
    // A module missing from `graph.order` cannot happen — the order is a
    // permutation of every module — but if one ever were, its messages
    // would be leaked rather than freed, so they are released explicitly.
    if (diagnostics.items.len != total) {
        for (graph.order) |m| per_module[m.int()].clearRetainingCapacity();
        for (per_module) |list| for (list.items) |d| gpa.free(d.message);
    }
    for (per_module) |*list| list.deinit(gpa);
    for (counters) |c| check.counters = check.counters.add(c);

    check.diagnostics = try diagnostics.toOwnedSlice(gpa);
    check.modules = try kept.toOwnedSlice(gpa);
    return check;
}

/// Constraint generation and solving walk an expression TREE, and the parser
/// accepts 4096 levels of nesting (language.md §10). 4096 frames do not fit
/// in a default thread stack: `bench/pathological/PlusChain8000.beni`
/// was measured overflowing at 16 MiB and surviving at 32, and
/// `Session` runs the whole check on a 64 MiB thread for that reason. Every
/// worker here needs the same room, so the size is stated at every spawn —
/// `std.Thread.SpawnConfig`'s default is nowhere near it.
pub const stack_size = 64 * 1024 * 1024;
