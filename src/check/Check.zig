//! The checker's driver (docs/design/checker.md §6): one `TypeStore` per
//! module, the module's top-level values SCC-decomposed into binding groups,
//! and for each group constrain → solve → generalise, followed by the
//! schemes going into the interface (§7).
//!
//! **Order.** Modules are checked over the graph's topological order, so
//! every import's interface is complete — and immutable — before anything
//! reads it. `Driver` walks that order as a DAG (§4.4): a module whose
//! dependencies have all finished may start, on any worker, and the bound
//! that makes it safe is the interface firewall — a module's check reads
//! only its own Bir, the interfaces of its imports, and the store it owns,
//! and the one thing it shares with another module's check is the
//! session-wide `Types` table, which is built before any thread starts and
//! read-only afterwards. Nothing is keyed by completion order; see
//! `Driver`'s header for what makes the output identical at every
//! `--jobs`.
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
//!
//! **Then exhaustiveness** (§6.6), over the declarations that solved clean:
//! `Exhaustive.zig` has the algorithm and `exhaustive` is what it costs in a
//! trace.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
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
const Dispatch = @import("Dispatch.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");

const Check = @This();

/// Re-exported so `Session` can name the pattern-usefulness budget without
/// reaching past the checker's driver into its internals.
pub const Exhaustive = @import("Exhaustive.zig");
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
/// Owned. One per graph module, in module index order: what the checker
/// decided about every method call (static-dispatch-spike.md §7).
///
/// Kept whatever `keep_stores` says, unlike `modules`: the backend needs it
/// on every build, and it holds no `Var` — everything in it is an index or a
/// name that outlives the store.
dispatch: []Dispatch,
counters: Solve.Counters,

pub const empty: Check = .{ .types = .empty, .diagnostics = &.{}, .modules = &.{}, .dispatch = &.{}, .counters = .{} };

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
    for (check.dispatch) |*d| d.deinit(gpa);
    gpa.free(check.dispatch);
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
    /// Work one `case` may spend on pattern usefulness before it is
    /// abandoned and reports nothing (`Exhaustive.default_budget`).
    /// Settable so a test can prove the bound is what makes it fall silent,
    /// rather than asserting the absence of a hang.
    pattern_budget: u32 = Exhaustive.default_budget,
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
    const counters = try gpa.alloc(Solve.Counters, modules);
    defer gpa.free(counters);
    @memset(counters, .{});

    // One per module, filled at the end of that module's own check while
    // its store is still alive (§7.1). Allocated here so the driver can
    // write into it from any worker without a lock: a module writes only
    // its own slot.
    const dispatch = try gpa.alloc(Dispatch, modules);
    @memset(dispatch, .empty);
    check.dispatch = dispatch;

    var kept: std.ArrayList(Module) = .empty;
    // Each kept `Module` owns an arena and three tables. On the OOM path
    // the list itself is not enough: the modules that DID finish have to
    // give theirs back, or the failure leaks one arena per checked module.
    errdefer {
        for (kept.items) |*m| {
            m.store.deinit();
            gpa.free(m.decl_scheme);
            gpa.free(m.decl_display);
            gpa.free(m.local_type);
        }
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

    var driver: Driver = .{
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
/// in a default thread stack: M2b measured `bench/pathological/
/// PlusChain8000.beni` overflowing at 16 MiB and surviving at 32, and
/// `Session` runs the whole check on a 64 MiB thread for that reason. Every
/// worker here needs the same room, so the size is stated at every spawn —
/// `std.Thread.SpawnConfig`'s default is nowhere near it.
pub const stack_size = 64 * 1024 * 1024;

/// Schedules modules over the graph's DAG (checker.md §4.4).
///
/// **What makes this safe** is the interface firewall: a module's check
/// reads its own Bir, the session-wide `Types` table (built before any
/// thread starts and read-only afterwards), and the INTERFACES of its
/// dependencies — and every reference to another module was rewritten by
/// `Resolve` into `(module index, interface index)`, so a module can only
/// ever read an interface it has an edge to. It writes its own interface,
/// its own slot of every per-module array, and nothing else.
///
/// **What makes it deterministic** is that nothing is keyed by completion:
/// results land in the slot of a module index assigned before any thread
/// started, diagnostics are per module and concatenated in the graph's
/// order afterwards, and the counters are a commutative sum
/// (`fast-compiler.md` §10).
///
/// **A cyclic project runs serially.** A cycle has no topological order, so
/// a member may read a co-member's interface that is still being written —
/// a data race, not merely a wrong answer. The members are poisoned and
/// report nothing anyway (checker.md §4.3), so the whole run falls back to
/// one thread rather than growing a second scheduling rule for the case
/// where the answer is already "this project does not compile".
const Driver = struct {
    gpa: Allocator,
    io: Io,
    graph: *const Graph,
    artifacts: *const Artifacts,
    interfaces: []Interface,
    provenance: []const Interface.Provenance,
    interner: *const InternPool.Global,
    types: *const Types,
    options: Options,
    per_module: []std.ArrayList(Diagnostics.Item),
    counters: []Solve.Counters,
    kept: []Module,
    /// One per module, written by the worker that checked it.
    dispatch: []Dispatch,

    mutex: Io.Mutex = .init,
    /// A worker waits here for a module to become ready.
    wake: Io.Condition = .init,
    /// Modules ready to check, claimed from the front.
    queue: []Graph.Index = &.{},
    queue_len: usize = 0,
    queue_head: usize = 0,
    /// Dependencies of each module that are earlier in the graph's order and
    /// have not finished yet. A module is ready at zero.
    blockers: []u32 = &.{},
    /// Reverse edges: `dependents[dependent_start[m]..dependent_start[m+1]]`
    /// are the modules whose `blockers` count drops when `m` finishes.
    dependents: []Graph.Index = &.{},
    dependent_start: []u32 = &.{},
    /// Modules finished, so the workers know when to stop.
    finished: usize = 0,
    /// The first allocation failure any worker hit. One flag for all of
    /// them: the run is over either way.
    failure: ?Error = null,

    fn go(d: *Driver, scratch: *Arena) Error!void {
        const jobs = if (d.parallelisable()) @min(d.options.jobs, d.graph.count()) else 1;
        if (jobs <= 1) return d.serial(scratch);
        try d.buildSchedule();
        defer d.freeSchedule();

        const threads = try d.gpa.alloc(std.Thread, jobs - 1);
        defer d.gpa.free(threads);
        var spawned: usize = 0;
        // The joins must happen even if a spawn fails halfway, or a live
        // thread would outlive the `Driver` on this stack.
        defer for (threads[0..spawned]) |t| t.join();
        while (spawned < threads.len) : (spawned += 1) {
            threads[spawned] = std.Thread.spawn(
                .{ .stack_size = stack_size },
                worker,
                .{ d, @as(u32, @intCast(spawned + 1)), null },
            ) catch |err| switch (err) {
                // Fewer threads than asked for is a slower run, not a
                // failed one; the caller's thread finishes the queue.
                error.ThreadQuotaExceeded, error.SystemResources, error.LockedMemoryLimitExceeded => break,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.OutOfMemory,
            };
        }
        // The calling thread is worker zero: it already has the 64 MiB
        // stack `Session` gave it, and one fewer spawn is one fewer join.
        d.worker(0, scratch);
    }

    /// Whether the DAG can be walked concurrently at all: more than one
    /// module, more than one worker, and no import cycle (see the header).
    fn parallelisable(d: *const Driver) bool {
        if (d.options.jobs <= 1 or d.graph.count() <= 1) return false;
        for (0..d.graph.count()) |i| {
            if (d.graph.isPoisoned(@enumFromInt(i))) return false;
        }
        return true;
    }

    fn serial(d: *Driver, scratch: *Arena) Error!void {
        var patterns: Arena = .init(std.heap.page_allocator);
        defer patterns.deinit();
        for (d.graph.order) |m| {
            try d.check(m, scratch, &patterns, 0);
            scratch.reset(.retain_capacity);
        }
    }

    /// The ready queue and the reverse edges, built once before any thread
    /// starts. A dependency that comes LATER in the graph's order is not a
    /// blocker: the serial path would not have had its interface either, and
    /// only a cycle can produce one — which `parallelisable` has already
    /// ruled out.
    fn buildSchedule(d: *Driver) Error!void {
        const gpa = d.gpa;
        const n = d.graph.count();
        const position = try gpa.alloc(u32, n);
        defer gpa.free(position);
        for (d.graph.order, 0..) |m, i| position[m.int()] = @intCast(i);

        d.blockers = try gpa.alloc(u32, n);
        @memset(d.blockers, 0);
        d.dependent_start = try gpa.alloc(u32, n + 1);
        @memset(d.dependent_start, 0);

        var edges: u32 = 0;
        for (0..n) |i| {
            const m: Graph.Index = @enumFromInt(i);
            for (d.graph.dependencies(m)) |dep| {
                if (dep == m or position[dep.int()] >= position[i]) continue;
                d.blockers[i] += 1;
                d.dependent_start[dep.int() + 1] += 1;
                edges += 1;
            }
        }
        for (1..n + 1) |i| d.dependent_start[i] += d.dependent_start[i - 1];
        d.dependents = try gpa.alloc(Graph.Index, edges);
        const cursor = try gpa.alloc(u32, n);
        defer gpa.free(cursor);
        @memcpy(cursor, d.dependent_start[0..n]);
        for (0..n) |i| {
            const m: Graph.Index = @enumFromInt(i);
            for (d.graph.dependencies(m)) |dep| {
                if (dep == m or position[dep.int()] >= position[i]) continue;
                d.dependents[cursor[dep.int()]] = m;
                cursor[dep.int()] += 1;
            }
        }

        d.queue = try gpa.alloc(Graph.Index, n);
        // Seeded in the graph's order, so the first modules claimed are the
        // ones the serial path would have taken first.
        for (d.graph.order) |m| {
            if (d.blockers[m.int()] != 0) continue;
            d.queue[d.queue_len] = m;
            d.queue_len += 1;
        }
    }

    fn freeSchedule(d: *Driver) void {
        d.gpa.free(d.blockers);
        d.gpa.free(d.dependents);
        d.gpa.free(d.dependent_start);
        d.gpa.free(d.queue);
        d.blockers = &.{};
        d.dependents = &.{};
        d.dependent_start = &.{};
        d.queue = &.{};
    }

    /// Claim ready modules until every module is done. `own` is worker
    /// zero's arena, handed in so the caller's warm one is reused; every
    /// other worker makes its own and drops it on the way out.
    fn worker(d: *Driver, tid: u32, own: ?*Arena) void {
        var arena: Arena = .init(std.heap.page_allocator);
        defer if (own == null) arena.deinit();
        const scratch = own orelse &arena;
        // A SECOND arena, reset per `case` rather than per module, so the
        // usefulness check's matrices never pile up — and one per worker
        // rather than one per module, because an arena's first allocation
        // maps a chunk and a module that has one `case` should not pay a
        // map and an unmap for it.
        var patterns: Arena = .init(std.heap.page_allocator);
        defer patterns.deinit();

        while (true) {
            d.mutex.lockUncancelable(d.io);
            while (d.queue_head == d.queue_len and d.finished < d.graph.count() and d.failure == null) {
                d.wake.waitUncancelable(d.io, &d.mutex);
            }
            if (d.failure != null or d.queue_head == d.queue_len) {
                d.mutex.unlock(d.io);
                // Everything is done, or somebody failed: wake the rest so
                // they see it too and do not wait forever.
                d.wake.broadcast(d.io);
                return;
            }
            const m = d.queue[d.queue_head];
            d.queue_head += 1;
            d.mutex.unlock(d.io);

            const result = d.check(m, scratch, &patterns, tid);
            scratch.reset(.retain_capacity);
            d.finish(m, result);
        }
    }

    /// Record `m` as done, release whatever it was blocking, and wake
    /// anybody waiting.
    fn finish(d: *Driver, m: Graph.Index, result: Error!void) void {
        d.mutex.lockUncancelable(d.io);
        defer d.mutex.unlock(d.io);
        d.finished += 1;
        if (result) |_| {} else |err| {
            if (d.failure == null) d.failure = err;
        }
        for (d.dependents[d.dependent_start[m.int()]..d.dependent_start[m.int() + 1]]) |dependent| {
            d.blockers[dependent.int()] -= 1;
            if (d.blockers[dependent.int()] != 0) continue;
            d.queue[d.queue_len] = dependent;
            d.queue_len += 1;
        }
        d.wake.broadcast(d.io);
    }

    fn check(d: *Driver, m: Graph.Index, scratch: *Arena, patterns: *Arena, tid: u32) Error!void {
        var one: ModuleCheck = .{
            .gpa = d.gpa,
            .scratch = scratch,
            .patterns = patterns,
            .graph = d.graph,
            .artifacts = d.artifacts,
            .interfaces = d.interfaces,
            .provenance = d.provenance,
            .interner = d.interner,
            .types = d.types,
            .module = m,
            .diagnostics = &d.per_module[m.int()],
            .quiet = m.int() < d.options.quiet.len and d.options.quiet[m.int()],
            .profile = d.options.profile,
            .tid = tid,
            .pattern_budget = d.options.pattern_budget,
            .informational = d.options.informational,
            .dispatch = &d.dispatch[m.int()],
        };
        d.counters[m.int()] = try one.run(if (d.kept.len != 0) &d.kept[m.int()] else null);
    }
};

const ModuleCheck = struct {
    gpa: Allocator,
    scratch: *Arena,
    /// The pattern-usefulness scratch (checker.md §6.6), owned by the worker
    /// and reset per `case` rather than per module.
    patterns: *Arena,
    graph: *const Graph,
    artifacts: *const Artifacts,
    interfaces: []Interface,
    provenance: []const Interface.Provenance,
    interner: *const InternPool.Global,
    types: *const Types,
    module: Graph.Index,
    diagnostics: *std.ArrayList(Diagnostics.Item),
    quiet: bool,
    profile: ?*Profile,
    /// Which profile thread buffer this module's events go in: the worker
    /// checking it. Only that worker writes it, which is what makes the
    /// buffers lock-free.
    tid: u32 = 0,
    pattern_budget: u32 = Exhaustive.default_budget,
    /// `Options.informational`, for this module.
    informational: bool = false,
    /// This module's slot of the run's dispatch tables (§7.1), filled at
    /// the end of `run`.
    dispatch: *Dispatch = undefined,
    /// `(rigid variable, method) → evidence index` for this module's
    /// annotated declarations; owned by `run`.
    rigid_evidence: *std.ArrayList(Dispatch.RigidEvidence) = undefined,
    /// Nanoseconds this module spent in each half, summed over its binding
    /// groups and emitted as one event each when the module is done.
    constrain_ns: u64 = 0,
    solve_ns: u64 = 0,

    fn run(mc: *ModuleCheck, keep: ?*Module) Error!Solve.Counters {
        const gpa = mc.gpa;
        const file = mc.graph.moduleFile(mc.module);
        const bir = mc.artifacts.bir(file);
        // One `check` event per module (checker.md §9), with `constrain`,
        // `solve` and `exhaustive` nested inside it. Per module and not per
        // run, because "this module was not re-checked" is the thing M4's
        // incrementality tests have to be able to see.
        const check_token = if (mc.profile) |p| p.begin() else null;

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

        // Empty on every input a person writes; see `Env.too_deep`.
        var too_deep: std.ArrayList(Bir.Inst.Index) = .empty;
        defer too_deep.deinit(mc.scratch.allocator());
        // The module's dispatch table as it is built (§7.1). It outlives
        // the store — everything in it is an index or a name — and is kept
        // whatever `keep_stores` says.
        var dispatch: Dispatch.Builder = .{ .gpa = gpa };
        defer dispatch.deinit();
        // `(rigid variable, method) → evidence index` for every annotated
        // declaration of this module, in the canonical order of §7.2.
        var rigid_evidence: std.ArrayList(Dispatch.RigidEvidence) = .empty;
        defer rigid_evidence.deinit(mc.scratch.allocator());
        var monomorphic: std.ArrayList(Constrain.Monomorphic) = .empty;
        defer monomorphic.deinit(mc.scratch.allocator());
        mc.rigid_evidence = &rigid_evidence;

        var env: Constrain.Env = .{
            .scratch = mc.scratch.allocator(),
            .too_deep = &too_deep,
            .dispatch = &dispatch,
            .monomorphic = &monomorphic,
            .informational = mc.informational,
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
        //    The `where` clause is read with the SAME builder, so a variable
        //    a constraint mentions is the one the annotation introduced
        //    (§2.4); the constraints then ride on the scheme's flags and
        //    `Schemes.Writer` carries them into the interface (§6.5).
        for (bir.decls, 0..) |d, i| {
            if (!d.kind.isValue()) continue;
            const annotation = d.annotation.unwrap() orelse continue;
            var b = env.builder(.flex, TypeStore.generalized);
            defer b.deinit();
            const v = try env.readAnnotation(&b, annotation);
            try ModuleCheck.attachWhere(&env, bir, d, &b);
            decl_scheme[i] = v.toOptional();
            // A declaration with no BODY never reaches `checkGroup`, so its
            // evidence list has to be recorded here — a `pub foreign … where`
            // (§5.2, A.7) is exactly that, and without this it got no `decl`
            // line and no evidence at all. The scheme's own variables carry
            // the clause, and they are never met by a body, so nothing is
            // added to `rigid_evidence`.
            if (d.body == .none and d.where_start != d.where_end) {
                try mc.recordEvidence(&env, bir, @intCast(i), v, false);
            }
        }

        // 2. Every nominal type this module declares gets `eq` and
        //    `compare` derived, used or not (A.23) — BEFORE any body is
        //    checked, so a use site can ask whether a type derives at all
        //    by looking the entry up rather than re-deciding it. The two
        //    answers have to agree: a `compare` that derived at a use but
        //    was excluded here would name a function nobody emits.
        {
            var empty_tree: Constrain.Tree = .{};
            var deriver: Solve.Solver = .init(gpa, &env, &empty_tree, &reporter);
            defer deriver.deinit();
            deriver.rank = TypeStore.generalized;
            try deriver.deriveDeclaredTypes();
        }

        // 3. Binding groups over the values that still need inferring.
        const groups = try ModuleCheck.bindingGroups(bir, &env);
        var counters: Solve.Counters = .{};
        for (0..groups.starts.len - 1) |g| {
            const members = groups.order[groups.starts[g]..groups.starts[g + 1]];
            counters = add(counters, try mc.checkGroup(bir, &env, &reporter, members, decl_display, local_type, inst_result));
        }

        // 4. Pattern usefulness, over the declarations that solved clean
        //    (checker.md §6.6). It runs here rather than inside the group
        //    loop because "did THIS declaration produce a diagnostic?" is
        //    only settled once every group is done.
        const exhaustive_token = if (mc.profile) |p| p.begin() else null;
        try mc.exhaustive(bir, &reporter);
        if (mc.profile) |profile| {
            profile.record(mc.tid, .constrain, file.int(), 0, mc.constrain_ns);
            profile.record(mc.tid, .solve, file.int(), 0, mc.solve_ns);
            profile.end(mc.tid, exhaustive_token.?, .exhaustive, file.int(), 0);
        }

        // 5. The interface gains its schemes (checker.md §7).
        try mc.fillInterface(&env, bir, store, decl_scheme);

        // 7. Whatever was too deeply nested to read. Last, so a declaration
        //    that tripped the guard in more than one place is one message.
        try ModuleCheck.reportTooDeep(&env, &reporter);

        // 6. The dispatch table, sorted once (§7.1, §7.3). Built while the
        //    store was alive; nothing in it needs the store afterwards.
        var namer: DerivedNamer = .{ .mc = mc, .types = mc.types, .builder = &dispatch };
        mc.dispatch.* = try dispatch.finish(
            gpa,
            bir.decls.len,
            mc.scratch.allocator(),
            DerivedNamer.write,
            @ptrCast(&namer),
        );

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
        if (mc.profile) |profile| profile.end(mc.tid, check_token.?, .check, file.int(), 0);
        return counters;
    }

    fn add(a: Solve.Counters, b: Solve.Counters) Solve.Counters {
        return a.add(b);
    }

    /// Attach an annotation's `where` clause to the variables the
    /// annotation introduced (static-dispatch-spike.md §2.4, §6.1).
    ///
    /// Read with the SAME `Types.Builder` as the annotation, which is what
    /// makes `where k.compare : k, k -> Order` talk about the `k` of
    /// `Dict k v` and not a fresh variable. §2.4's closure rule guarantees
    /// every variable a constraint mentions is already in that scope, so no
    /// quantifier can appear here that the body does not also introduce —
    /// which is what makes §7.2's canonical order total.
    fn attachWhere(env: *Constrain.Env, bir: *const Bir, d: Bir.Decl, b: *Types.Builder) Error!void {
        const clause = bir.declWhere(d);
        if (clause.len == 0) return;
        const scratch = env.scratch;
        const store = env.store;
        // Every type first: reading one can grow `b.scope`, and the lookup
        // below wants the finished scope.
        const fn_vars = try scratch.alloc(Var, clause.len);
        defer scratch.free(fn_vars);
        for (clause, fn_vars) |wc, *v| v.* = try env.readAnnotation(b, wc.type_inst);
        const taken = try scratch.alloc(bool, clause.len);
        defer scratch.free(taken);
        @memset(taken, false);
        var built: std.ArrayList(TypeStore.MethodConstraint) = .empty;
        defer built.deinit(scratch);
        for (clause, 0..) |wc, i| {
            if (taken[i]) continue;
            const variable = bir.symbol(wc.variable);
            built.clearRetainingCapacity();
            for (clause[i..], fn_vars[i..], i..) |other, fn_var, j| {
                if (bir.symbol(other.variable) != variable) continue;
                taken[j] = true;
                try built.append(scratch, .{
                    .name = bir.symbol(other.method),
                    .fn_var = fn_var,
                    .region = other.type_inst,
                    .origin = .where_clause,
                    .sites = .empty,
                });
            }
            const target = blk: {
                for (b.scope.items) |scoped| {
                    if (scoped.name == variable) break :blk scoped.v;
                }
                // `where_variable_unbound` already refused this in lowering
                // (§2.4); a poisoned clause simply attaches nothing.
                continue;
            };
            const set = try store.addConstraints(built.items);
            const root = store.find(target);
            const flags = store.flagsOf(root);
            const with: TypeStore.Flags = .{
                .name = flags.name,
                .kind = flags.kind,
                .equatable = flags.equatable,
                .constraints = set.toOptional(),
            };
            store.setContent(root, switch (store.content(root)) {
                .rigid => .{ .rigid = with },
                else => .{ .flex = with },
            });
        }
    }

    /// The evidence list of one ANNOTATED declaration, in §7.2's canonical
    /// order: the scheme's quantifiers in the order `Schemes.Writer`
    /// records them, and within each for its constraints in name-text
    /// order.
    ///
    /// Computed over the RIGID reading, which is the tree the body's
    /// constraints live in; it is structurally identical to the flex
    /// reading a caller instantiates, so both sides number the same slots.
    fn recordEvidence(mc: *ModuleCheck, env: *Constrain.Env, bir: *const Bir, decl: u32, rigid: Var, keyed: bool) Error!void {
        const scratch = env.scratch;
        var order: std.ArrayList(Var) = .empty;
        defer order.deinit(scratch);
        try Schemes.quantifierOrder(env.store, env.interner, rigid, &order, scratch);
        var entries: std.ArrayList(Dispatch.Evidence) = .empty;
        defer entries.deinit(scratch);
        var index: u16 = 0;
        for (order.items, 0..) |root, q| {
            const flags = env.store.flagsOf(root);
            const n = env.store.constraintCount(flags.constraints);
            if (n == 0) continue;
            const sorted = try scratch.alloc(TypeStore.MethodConstraint, n);
            defer scratch.free(sorted);
            for (sorted, 0..) |*c, j| c.* = env.store.constraintAt(flags.constraints, @intCast(j));
            std.mem.sort(TypeStore.MethodConstraint, sorted, env.interner, constraintNameLessThan);
            for (sorted) |c| {
                try entries.append(scratch, .{
                    .quantified = @intCast(q),
                    .var_name = flags.name,
                    .method = c.name,
                });
                if (keyed) try mc.rigid_evidence.append(scratch, .{ .v = root, .method = c.name, .index = index });
                index += 1;
            }
        }
        if (entries.items.len == 0) return;
        const range = try env.dispatch.addEvidence(entries.items);
        try env.dispatch.setDeclEvidence(bir.decls.len, decl, range);
    }

    /// SCC over the module's top-level values. An edge `d → e` exists when
    /// `d` mentions `e` and `e` is an unannotated value of this module —
    /// the only case where `d`'s check has to wait for `e`'s.
    fn bindingGroups(bir: *const Bir, env: *Constrain.Env) Error!Constrain.IndexGroups {
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
        // The annotation's rigid variables per member, so a `type_dispatch`
        // in the body can name one (§4.2) and so the `where` clause can be
        // read into them.
        const member_rigids = try env.scratch.alloc([]const Types.Builder.Scoped, members.len);
        defer env.scratch.free(member_rigids);
        @memset(member_rigids, &.{});
        for (members, check_vars, member_rigids) |index, *cv, *rigids| {
            const d = bir.decls[index];
            cv.* = .none;
            if (!d.kind.isValue() or d.body == .none) continue;
            if (d.annotation != .none) {
                const mark = generator.storeMark();
                var b = env.builder(.rigid, TypeStore.outermost);
                defer b.deinit();
                cv.* = (try env.readAnnotation(&b, d.annotation.unwrap().?)).toOptional();
                try ModuleCheck.attachWhere(env, bir, d, &b);
                rigids.* = try env.scratch.dupe(Types.Builder.Scoped, b.scope.items);
                try generator.adoptSince(mark);
                try mc.recordEvidence(env, bir, @intCast(index), cv.*.unwrap().?, true);
            } else {
                const v = try generator.freshForDecl();
                cv.* = v.toOptional();
                env.decl_scheme[index] = v.toOptional();
            }
            try headers.append(env.scratch, .{
                .v = cv.*.unwrap().?,
                .region = d.body.unwrap().?,
                .name = bir.symbol(d.name).toOptional(),
                .decl = @intCast(index),
            });
        }
        for (members, check_vars, member_rigids) |index, cv_opt, rigids| {
            decl_display[index] = cv_opt;
            const cv = cv_opt.unwrap() orelse continue;
            const d = bir.decls[index];
            env.local_var = local_type[d.locals_start..d.locals_end];
            env.locals_base = d.locals_start;
            env.inst_base = d.inst_start.int();
            env.inst_result = inst_result[d.inst_start.int()..d.inst_end.int()];
            env.decl_result = .none;
            env.decl = @intCast(index);
            env.decl_rigids = rigids;
            try parts.append(env.scratch, try generator.decl(@enumFromInt(index), cv));
        }
        env.decl_rigids = &.{};
        // After the declare loop, so the list has stopped growing: an
        // earlier slice would dangle the moment another annotation added a
        // constraint.
        env.rigid_evidence = mc.rigid_evidence.items;
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

    /// Check every `case` of every declaration that has no type error of
    /// its own (checker.md §6.6).
    ///
    /// The gate is per DECLARATION and not per module: a module with one bad
    /// function still has good ones, and their `case`s are worth checking.
    /// What it buys is the algorithm's precondition — a column of a matrix
    /// holds one type's constructors — which only holds where unification
    /// succeeded. A declaration that failed has patterns the checker already
    /// complained about, and a second message about them would be noise.
    fn exhaustive(mc: *ModuleCheck, bir: *const Bir, reporter: *Diagnostics.Reporter) Error!void {
        if (reporter.quiet) return;
        const gpa = mc.gpa;
        const skip = try gpa.alloc(bool, bir.decls.len);
        defer gpa.free(skip);
        @memset(skip, false);
        for (mc.diagnostics.items) |item| {
            const at = item.region.int();
            for (bir.decls, 0..) |d, i| {
                if (at >= d.inst_start.int() and at < d.inst_end.int()) {
                    skip[i] = true;
                    break;
                }
            }
        }
        try Exhaustive.run(gpa, mc.patterns, .{
            .graph = mc.graph,
            .artifacts = mc.artifacts,
            .interfaces = mc.interfaces,
            .types = mc.types,
            .interner = mc.interner,
            .module = mc.module,
            .bir = bir,
        }, reporter, skip, mc.pattern_budget);
    }

    /// Write every `pub` value's scheme and every visible constructor's
    /// argument terms into the interface (checker.md §7).
    ///
    /// A declaration whose type contains an error gets the `err` term,
    /// which the dump prints as `<error>`: dependents check against the
    /// rest.
    ///
    /// Both halves go through `Interface.Provenance` rather than looking a
    /// name up in `bir.decls`. The scan this replaced was O(pub values ×
    /// declarations) and was the single largest measured cost in the M2
    /// review: 32 000 mutually recursive `pub` declarations spent 12.8 s
    /// here, against 73 ms for the same declarations without `pub`, and
    /// none of it showed in `--self-profile` because it sits between the
    /// profiled events.
    fn fillInterface(mc: *ModuleCheck, env: *Constrain.Env, bir: *const Bir, store: *TypeStore, decl_scheme: []const Var.Optional) Error!void {
        const gpa = mc.gpa;
        const iface = &mc.interfaces[mc.module.int()];
        const prov = if (mc.module.int() < mc.provenance.len)
            &mc.provenance[mc.module.int()]
        else
            &Interface.Provenance.empty;
        var writer: Schemes.Writer = .init(gpa, store, mc.interner, @intCast(iface.symbols.len));
        defer writer.deinit();
        // One frontier for the whole module; `hasError` clears it per call.
        var scan: std.ArrayList(Var) = .empty;
        defer scan.deinit(gpa);

        const values = try gpa.alloc(Interface.Value, iface.values.len);
        errdefer gpa.free(values);
        @memcpy(values, iface.values);
        for (values, 0..) |*v, i| {
            const target = blk: {
                const decl = prov.valueDecl(i) orelse break :blk null;
                if (decl.int() >= decl_scheme.len) break :blk null;
                break :blk decl_scheme[decl.int()].unwrap();
            };
            const scheme = target orelse {
                v.scheme = try writer.addError();
                continue;
            };
            switch (try hasError(gpa, &scan, store, scheme)) {
                .clean => {},
                .poisoned => {
                    v.scheme = try writer.addError();
                    continue;
                },
                // The declaration solved CLEAN and the scan ran out of
                // budget on it, so `<error>` here is the scanner's answer
                // and not the program's. Publishing it in silence is the
                // one failure mode §5 forbids — `beni check` exits 0 and
                // every importer sees a hole — so it is reported like any
                // other guard that poisons.
                .unknown => {
                    try noteDeepDecl(env, bir, prov.valueDecl(i));
                    v.scheme = try writer.addError();
                    continue;
                },
            }
            v.scheme = try writer.add(scheme);
            if (writer.too_deep) {
                // A truncated scheme is worse than no scheme: the `err`
                // term sits INSIDE an otherwise concrete type, so it
                // unifies with anything and a dependent's mistake against
                // this declaration compiles clean. Report, then publish
                // `<error>` (checker.md §7).
                try noteDeepDecl(env, bir, prov.valueDecl(i));
                v.scheme = try writer.addError();
            }
        }
        gpa.free(@constCast(iface.values));
        iface.values = values;

        try mc.fillCtorTerms(env, bir, store, prov, iface, &writer);
        try writer.attach(iface);
    }

    /// Every visible constructor's argument types, as terms (checker.md §7's
    /// `arg_terms`).
    ///
    /// This is the interface firewall of `fast-compiler.md` §8.1 made real
    /// for constructors: with the terms here, a dependent instantiates an
    /// imported constructor from this record alone. Without them the solver
    /// opened the declaring module's `Bir` and found the constructor BY
    /// NAME, which §4.5 forbids and which M4 cannot do at all — a
    /// dependency's Bir may not be in memory.
    ///
    /// The quantifiers are the owning TYPE's parameters, in declaration
    /// order, so `var(i)` in an argument term is parameter `i` and the
    /// result half — `T p0 … pk` — needs no storage.
    fn fillCtorTerms(
        mc: *ModuleCheck,
        env: *Constrain.Env,
        bir: *const Bir,
        store: *TypeStore,
        prov: *const Interface.Provenance,
        iface: *Interface,
        writer: *Schemes.Writer,
    ) Error!void {
        if (iface.ctors.len == 0) return;
        const gpa = mc.gpa;
        const scratch = mc.scratch.allocator();
        const ctors = try gpa.alloc(Interface.Ctor, iface.ctors.len);
        errdefer gpa.free(ctors);
        @memcpy(ctors, iface.ctors);

        for (ctors, 0..) |*c, i| {
            const bir_index = prov.ctorIndex(i) orelse continue;
            if (bir_index >= bir.ctors.len) continue;
            const bc = bir.ctors[bir_index];
            const owner = bir.decl(bc.decl);
            const params = bir.declTypeParams(owner);

            var b: Types.Builder = .init(
                store,
                mc.types,
                mc.graph,
                mc.artifacts,
                mc.module,
                bir,
                .flex,
                TypeStore.generalized,
                scratch,
                mc.interner,
            );
            defer b.deinit();
            const param_vars = try scratch.alloc(Var, params.len);
            defer scratch.free(param_vars);
            for (params, param_vars) |p, *v| {
                v.* = try store.fresh(.{ .flex = .{ .name = p.toOptional() } }, TypeStore.generalized);
                try b.bind(p, v.*);
            }
            const args = bir.extraSlice(.{ .start = bc.args_start, .end = bc.args_end }, Bir.Inst.Index);
            const arg_vars = try scratch.alloc(Var, args.len);
            defer scratch.free(arg_vars);
            for (args, arg_vars) |arg, *v| v.* = try b.read(arg);
            if (b.too_deep) {
                try noteDeepDecl(env, bir, bc.decl);
                continue; // leaves `arg_terms` at `no_terms`: a use poisons
            }
            const written = try writer.addCtor(param_vars, arg_vars);
            if (writer.too_deep) {
                try noteDeepDecl(env, bir, bc.decl);
                continue;
            }
            c.arg_terms = written.arg_terms;
            c.quantified_start = written.quantified_start;
        }
        gpa.free(@constCast(iface.ctors));
        iface.ctors = ctors;
    }

    /// One `nesting_too_deep` per over-deep type, in source order.
    ///
    /// Sorted and deduplicated here rather than at each note: the same
    /// annotation is read more than once — once generalised for callers,
    /// once rigid for the body — and one mistake gets one message. Sorting
    /// also makes the order a function of the source and not of the order
    /// the readers happened to run in, which `fast-compiler.md` §10
    /// requires of everything a build prints.
    fn reportTooDeep(env: *Constrain.Env, reporter: *Diagnostics.Reporter) Error!void {
        const regions = env.too_deep.items;
        if (regions.len == 0) return;
        std.mem.sort(Bir.Inst.Index, regions, {}, regionLessThan);
        var previous: Bir.Inst.OptionalIndex = .none;
        for (regions) |region| {
            if (previous == region.toOptional()) continue;
            previous = region.toOptional();
            try reporter.nestingTooDeep(region, Types.Builder.max_depth);
        }
    }

    fn regionLessThan(_: void, a: Bir.Inst.Index, b: Bir.Inst.Index) bool {
        return a.int() < b.int();
    }
};

fn constraintNameLessThan(
    interner: *const InternPool.Global,
    a: TypeStore.MethodConstraint,
    b: TypeStore.MethodConstraint,
) bool {
    return std.mem.lessThan(u8, interner.slice(a.name), interner.slice(b.name));
}

/// Spells a derived function the way §8.5 prints it, so
/// `Dispatch.Builder.finish` can sort by EMITTED NAME TEXT and not by the
/// order discharge happened to reach them in (A.15).
const DerivedNamer = struct {
    mc: *ModuleCheck,
    types: *const Types,
    builder: *const Dispatch.Builder,

    fn write(ctx: *anyopaque, d: Dispatch.Derived, out: *std.ArrayList(u8), a: Allocator) Allocator.Error!void {
        const self: *DerivedNamer = @ptrCast(@alignCast(ctx));
        const interner = self.mc.interner;
        const kind = switch (d.kind) {
            .eq => "eq",
            .compare => "compare",
        };
        switch (d.shape) {
            // `<Module>$<Type>$eq`: the DECLARING module, which is where it
            // is emitted (§8.5).
            .nominal => |id| {
                const entry = self.types.entry(id);
                try out.appendSlice(a, interner.slice(self.mc.graph.moduleName(entry.module)));
                try out.append(a, '$');
                try out.appendSlice(a, interner.slice(entry.name));
                try out.append(a, '$');
                try out.appendSlice(a, kind);
            },
            // `<Module>$<kind>$<shape>`: the CONSUMING module, this one.
            else => {
                try out.appendSlice(a, interner.slice(self.mc.graph.moduleName(self.mc.module)));
                try out.append(a, '$');
                try out.appendSlice(a, kind);
                try out.append(a, '$');
                switch (d.shape) {
                    .record => |r| {
                        try out.append(a, 'r');
                        for (self.builder.symbols.items[r.start..][0..r.len]) |name| {
                            try out.append(a, '$');
                            try out.appendSlice(a, interner.slice(name));
                        }
                    },
                    .tuple => |n| {
                        var buf: [8]u8 = undefined;
                        try out.appendSlice(a, std.fmt.bufPrint(&buf, "t{d}", .{n}) catch "t?");
                    },
                    .unit => try out.appendSlice(a, "unit"),
                    .nominal => unreachable,
                }
            },
        }
    }
};

/// The instruction a `nesting_too_deep` about `decl` points at: its
/// annotation, or its body, or its first instruction. The guard that
/// stopped the walk may have stopped it inside ANOTHER module's alias body,
/// so the deepest instruction is not necessarily one of this module's.
fn noteDeepDecl(env: *Constrain.Env, bir: *const Bir, decl: ?Bir.DeclIndex) Error!void {
    const index = decl orelse return;
    if (index.int() >= bir.decls.len) return;
    const d = bir.decl(index);
    try env.noteTooDeep(d.annotation.unwrap() orelse d.body.unwrap() orelse d.inst_start);
}

/// Whether a solved type contains a poisoned variable anywhere. A
/// declaration that failed to check is `<error>` in the interface rather
/// than a type built out of `?` (checker.md §7).
///
/// Three-valued on purpose. A type the walk could not finish is `unknown` —
/// which the caller must treat exactly like `poisoned`, because the
/// alternative is what this used to do: drop the frontier, answer "clean",
/// and publish a scheme with a raw `err` term inside it. A dependent
/// instantiating that scheme gets a component that unifies with anything,
/// which is cascade suppression leaking across the module firewall — the
/// one place checker.md §7 says it must not.
///
/// `unknown` is also not free: the caller publishes `<error>` for a
/// declaration that solved clean, so it REPORTS as well. The worklist is
/// grown rather than fixed for exactly that reason — a fixed 256 entries
/// made `unknown` reachable from ordinary source (255 record extension
/// links clean, 256 `<error>` and exit 0), which turned a formatting bound
/// into a silent wrong answer.
const ErrorScan = enum {
    clean,
    poisoned,
    /// The budget ran out; the caller treats it as `poisoned` AND reports.
    unknown,
};

/// `scratch` is the caller's, reused across declarations: this runs once per
/// public value of the module and a fresh list per call would allocate the
/// whole frontier again every time.
fn hasError(gpa: Allocator, scratch: *std.ArrayList(Var), store: *TypeStore, root_var: Var) Allocator.Error!ErrorScan {
    const mark = store.nextMark();
    const stack = scratch;
    stack.clearRetainingCapacity();
    try stack.append(gpa, root_var);
    // Every variable is VISITED at most once, so the budget is the store's
    // own variable count; it only bounds a store that is itself malformed,
    // and it is stated in terms of the input so it cannot become the real
    // limit. It is charged per visit and not per pop, because a shared
    // component is pushed once per parent that references it — charging
    // those would make the budget a function of the edges and reachable on
    // a type nothing is wrong with.
    var budget: usize = @as(usize, store.count()) + 16;
    while (stack.pop()) |v| {
        const root = store.find(v);
        if (store.mark(root) == mark) continue;
        if (budget == 0) return .unknown;
        budget -= 1;
        store.setMark(root, mark);
        switch (store.content(root)) {
            .err => return .poisoned,
            .flex, .rigid => {},
            .alias => |a| try stack.append(gpa, a.actual),
            .structure => |flat| switch (flat) {
                .unit, .empty_record => {},
                .func => |f| {
                    try stack.appendSlice(gpa, store.vars(f.params));
                    try stack.append(gpa, f.result);
                },
                .app => |a| try stack.appendSlice(gpa, store.vars(a.args)),
                .tuple => |t| try stack.appendSlice(gpa, store.vars(t)),
                .record => |r| {
                    for (store.fields(r.fields)) |f| try stack.append(gpa, f.value);
                    try stack.append(gpa, r.ext);
                },
            },
        }
    }
    return .clean;
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
    \\pub foreign add : number, number -> number
    \\
    \\
    \\pub foreign sub : number, number -> number
    \\
    \\
    \\pub foreign mul : number, number -> number
    \\
    \\
    \\pub foreign lt : number, number -> Bool
    \\
    \\
    \\pub foreign eq : equatable a, a -> Bool
    \\
    \\
    \\pub foreign append : appendable, appendable -> appendable
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
    \\pub max : number, number -> number
    \\max x y =
    \\    x
    \\
    },
    .{ .path = "List.beni", .package = .core, .source =
    \\pub equatable foreign type List a
    \\
    \\
    \\pub foreign cons : a, List a -> List a
    \\
    \\
    \\pub foreign map : (a -> b), List a -> List b
    \\
    \\
    \\pub foreign foldl : (a, b -> b), b, List a -> b
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
    \\pub equatable foreign type String
    \\
    \\
    \\pub foreign length : String -> Int
    \\
    \\
    \\pub foreign fromInt : Int -> String
    \\
    },
    .{ .path = "Char.beni", .package = .core, .source = "pub equatable foreign type Char\n\n\npub foreign isDigit : Char -> Bool\n" },
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

/// Every diagnostic code of a WHOLE project — `modules` on top of the test
/// core — for the scenarios that are about crossing a module boundary.
fn expectProjectCodes(expected: []const diagnostic.Code, extra: []const TestProject.Module) !void {
    const gpa = testing.allocator;
    var modules: std.ArrayList(TestProject.Module) = .empty;
    defer modules.deinit(gpa);
    try modules.appendSlice(gpa, &test_core);
    try modules.appendSlice(gpa, extra);
    var p = try TestProject.initWith(gpa, modules.items, .{ .phases = Session.check_phases });
    defer p.deinit();
    const got = try p.codes(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(diagnostic.Code, expected, got);
}

/// One module checked with a chosen pattern-usefulness budget
/// (checker.md §6.6).
fn budgetedCodes(gpa: Allocator, source: [:0]const u8, budget: u32) ![]diagnostic.Code {
    var modules: std.ArrayList(TestProject.Module) = .empty;
    defer modules.deinit(gpa);
    try modules.appendSlice(gpa, &test_core);
    try modules.append(gpa, .{ .path = "M.beni", .source = source });
    var p = try TestProject.initWith(gpa, modules.items, .{
        .phases = Session.check_phases,
        .pattern_budget = budget,
    });
    defer p.deinit();
    return p.codes(gpa);
}

fn expectBudgetedCodes(expected: []const diagnostic.Code, source: [:0]const u8, budget: u32) !void {
    const gpa = testing.allocator;
    const got = try budgetedCodes(gpa, source, budget);
    defer gpa.free(got);
    try testing.expectEqualSlices(diagnostic.Code, expected, got);
}

test "inference: the principal type of an unannotated definition" {
    try expectTypes(
        \\module M
        \\  identity : a -> a
        \\    x : a
        \\  apply : (a -> b), a -> b
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
        \\pub same : (Int -> Int), (Int -> Int) -> Bool
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
        \\pub same : Int, Int -> Bool
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
    // The case currying could not localise (§8.3): a lambda of the wrong
    // arity in higher-order position is wrong WHERE IT IS WRITTEN, and the
    // message is about the lambda rather than about the list two arguments
    // later.
    try expectCodes(&.{.type_mismatch},
        \\pub total : List Int -> Int
        \\total xs =
        \\    List.foldl (\x -> x) 0 xs
        \\
    );
    // `_` is how a call leaves one argument open, and it is not an arity
    // mistake.
    try expectCodes(&.{},
        \\pub bump : List Int -> List Int
        \\bump xs =
        \\    List.map (max 1 _) xs
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

// ---------------------------------------------------------------------------
// Pattern usefulness (checker.md §6.6)
// ---------------------------------------------------------------------------

test "exhaustiveness: a constructor with no branch is reported, one with a branch is not" {
    try expectCodes(&.{.missing_patterns},
        \\pub f : Maybe Int -> Int
        \\f m =
        \\    case m of
        \\        Just n ->
        \\            n
        \\
    );
    try expectCodes(&.{},
        \\pub f : Maybe Int -> Int
        \\f m =
        \\    case m of
        \\        Just n ->
        \\            n
        \\
        \\        Nothing ->
        \\            0
        \\
    );
    // A variable covers the rest, exactly as a wildcard does.
    try expectCodes(&.{},
        \\pub f : Maybe Int -> Int
        \\f m =
        \\    case m of
        \\        Just n ->
        \\            n
        \\
        \\        other ->
        \\            0
        \\
    );
}

test "exhaustiveness: `if` lowers to a `case` on Bool and must not be reported" {
    // `if` becomes `case c of True -> …; False -> …` (Bir's `case` tag), and
    // those two ARE every constructor of `Bool`. A spurious `missing_patterns`
    // on every `if` in the language is the failure mode this test exists for.
    try expectCodes(&.{},
        \\pub sign : Int -> Int
        \\sign n =
        \\    if n < 0 then
        \\        0 - 1
        \\    else
        \\        1
        \\
    );
    // And a written `case` on `Bool` behaves the same way.
    try expectCodes(&.{.missing_patterns},
        \\pub yes : Bool -> Int
        \\yes b =
        \\    case b of
        \\        True ->
        \\            1
        \\
    );
}

test "exhaustiveness: literals are infinite, so a wildcard is the only way to cover them" {
    try expectCodes(&.{.missing_patterns},
        \\pub f : Int -> Int
        \\f n =
        \\    case n of
        \\        1 ->
        \\            1
        \\
        \\        2 ->
        \\            2
        \\
    );
    try expectCodes(&.{},
        \\pub f : Int -> Int
        \\f n =
        \\    case n of
        \\        1 ->
        \\            1
        \\
        \\        _ ->
        \\            0
        \\
    );
    try expectCodes(&.{.missing_patterns},
        \\pub f : String -> Int
        \\f s =
        \\    case s of
        \\        "a" ->
        \\            1
        \\
    );
    try expectCodes(&.{.missing_patterns},
        \\pub f : Char -> Int
        \\f c =
        \\    case c of
        \\        'a' ->
        \\            1
        \\
    );
    // The same VALUE spelled two ways is one pattern, so the second branch
    // is dead: `0x10` and `16` are the same integer.
    try expectCodes(&.{.redundant_pattern},
        \\pub f : Int -> Int
        \\f n =
        \\    case n of
        \\        0x10 ->
        \\            1
        \\
        \\        16 ->
        \\            2
        \\
        \\        _ ->
        \\            0
        \\
    );
}

test "exhaustiveness: a list is `[]` and `::`, in both spellings" {
    try expectCodes(&.{}, listCase("[]", "x :: rest"));
    try expectCodes(&.{.missing_patterns}, listCase("[]", "[ x ]"));
    try expectCodes(&.{.missing_patterns}, listCase("[ x ]", "[ x2, y ]"));
    // `[]`, `[ x ]` and `x :: y :: rest` between them are every list.
    try expectCodes(&.{},
        \\pub f : List Int -> Int
        \\f xs =
        \\    case xs of
        \\        [] ->
        \\            0
        \\
        \\        [ x ] ->
        \\            x
        \\
        \\        x2 :: y :: rest ->
        \\            y
        \\
    );
    // …and a fourth branch for a non-empty list is therefore dead.
    try expectCodes(&.{.redundant_pattern},
        \\pub f : List Int -> Int
        \\f xs =
        \\    case xs of
        \\        [] ->
        \\            0
        \\
        \\        [ x ] ->
        \\            x
        \\
        \\        x2 :: y :: rest ->
        \\            y
        \\
        \\        z :: more ->
        \\            z
        \\
    );
}

/// A `case` over `List Int` with two branch patterns, for the list cases
/// above. The bodies are constants so nothing but the patterns is in play.
fn listCase(comptime a: []const u8, comptime b: []const u8) [:0]const u8 {
    return "pub f : List Int -> Int\nf xs =\n    case xs of\n        " ++ a ++
        " ->\n            0\n\n        " ++ b ++ " ->\n            1\n";
}

test "exhaustiveness: tuples, unit and records are products with one shape" {
    // A tuple has one constructor, so what is missing is a COMBINATION —
    // and the example names it in source syntax.
    try expectCodes(&.{.missing_patterns},
        \\pub f : ( Bool, Bool ) -> Int
        \\f p =
        \\    case p of
        \\        ( True, True ) ->
        \\            1
        \\
        \\        ( False, False ) ->
        \\            2
        \\
    );
    try expectCodes(&.{},
        \\pub f : ( Bool, Bool ) -> Int
        \\f p =
        \\    case p of
        \\        ( True, b ) ->
        \\            1
        \\
        \\        ( False, b2 ) ->
        \\            2
        \\
    );
    // `()` has exactly one value, and a record pattern always matches.
    try expectCodes(&.{},
        \\pub f : () -> Int
        \\f u =
        \\    case u of
        \\        () ->
        \\            1
        \\
    );
    try expectCodes(&.{},
        \\pub f : { name : Int } -> Int
        \\f r =
        \\    case r of
        \\        { name } ->
        \\            name
        \\
    );
}

test "exhaustiveness: nesting" {
    try expectCodes(&.{.missing_patterns},
        \\pub f : Maybe (Maybe Int) -> Int
        \\f m =
        \\    case m of
        \\        Just (Just n) ->
        \\            n
        \\
        \\        Nothing ->
        \\            0
        \\
    );
    try expectCodes(&.{},
        \\pub f : Maybe (Maybe Int) -> Int
        \\f m =
        \\    case m of
        \\        Just (Just n) ->
        \\            n
        \\
        \\        Just Nothing ->
        \\            1
        \\
        \\        Nothing ->
        \\            0
        \\
    );
    // A `Result` of a `Maybe`, with three of the four combinations missing.
    try expectCodes(&.{.missing_patterns},
        \\pub f : Result String (Maybe Int) -> Int
        \\f r =
        \\    case r of
        \\        Ok (Just n) ->
        \\            n
        \\
    );
}

test "exhaustiveness: a branch under a wildcard can never run" {
    try expectCodes(&.{.redundant_pattern},
        \\pub f : Maybe Int -> Int
        \\f m =
        \\    case m of
        \\        other ->
        \\            0
        \\
        \\        Nothing ->
        \\            1
        \\
    );
    // The FIRST redundant branch is the one reported, and the missing-
    // pattern search does not also run: the matrix past a dead row is not
    // what the author meant (Elm's `toNonRedundantRows` stops the same way).
    try expectCodes(&.{.redundant_pattern},
        \\pub f : Maybe Int -> Int
        \\f m =
        \\    case m of
        \\        Just n ->
        \\            n
        \\
        \\        Just q ->
        \\            q
        \\
        \\        Just z ->
        \\            z
        \\
    );
}

test "exhaustiveness: a declaration with a type error is not judged twice" {
    // One mistake, one message: the `case` below is also non-exhaustive,
    // and saying so would be a second complaint about a declaration whose
    // types are already unknown (checker.md §6.6).
    try expectCodes(&.{.type_mismatch},
        \\pub f : Maybe Int -> Int
        \\f m =
        \\    case m of
        \\        Just n ->
        \\            "not an int"
        \\
    );
    // A GOOD declaration in the same module is still checked, though.
    try expectCodes(&.{ .type_mismatch, .missing_patterns },
        \\pub bad : Maybe Int -> Int
        \\bad m =
        \\    case m of
        \\        Just n ->
        \\            "not an int"
        \\
        \\
        \\pub good : Maybe Int -> Int
        \\good m =
        \\    case m of
        \\        Just n ->
        \\            n
        \\
    );
}

test "exhaustiveness: a case on an opaque imported type needs a variable, and that is enough" {
    // The importer cannot name the constructors at all (`opaque_constructor`
    // refuses them), so a variable is the only pattern it can write — and a
    // variable is exhaustive. The point is that nothing is reported: an
    // opaque type must not look non-exhaustive from outside.
    try expectProjectCodes(&.{}, &.{
        .{ .path = "Token.beni", .source =
        \\pub opaque type Token
        \\    = Word String
        \\    | Number Int
        \\
        \\
        \\pub make : Token
        \\make =
        \\    Number 1
        \\
        },
        .{ .path = "M.beni", .source =
        \\import Token exposing (Token, make)
        \\
        \\
        \\pub size : Token -> Int
        \\size t =
        \\    case t of
        \\        anything ->
        \\            1
        \\
        },
    });
}

test "exhaustiveness: an imported type's constructors come from its interface" {
    // `Tri` is not even imported, and it is still what is missing: the union
    // comes from the TYPE's declaration, reached through `Shape`'s
    // interface, not from what the importer happened to name.
    try expectProjectCodes(&.{.missing_patterns}, &.{
        .{ .path = "Shape.beni", .source =
        \\pub type Shape
        \\    = Circle Int
        \\    | Square Int
        \\    | Tri Int Int
        \\
        },
        .{ .path = "M.beni", .source =
        \\import Shape exposing (Shape, Circle, Square)
        \\
        \\
        \\pub area : Shape -> Int
        \\area s =
        \\    case s of
        \\        Circle r ->
        \\            r
        \\
        \\        Square w ->
        \\            w
        \\
        },
    });
}

test "the usefulness budget: an analysis that would cost too much is refused, not skipped" {
    // The algorithm is exponential in the worst case (Maranget §3.3), so a
    // `case` that exceeds a fixed work budget is abandoned. Proving that
    // with a hang is not a test; proving it by turning the budget down to
    // where an ordinary `case` cannot be analysed is.
    //
    // Until queue slice 14 the second line of this test expected `&.{}` —
    // silence — and that silence was a miscompile: `backend.md` §7's
    // decision tree emits no default arm because the checker is supposed to
    // have proved exhaustiveness, so a `case` the checker never decided
    // falls into its last edge and answers wrongly at exit 0. An analysis
    // that gave up now SAYS it gave up.
    const source =
        \\pub f : Maybe Int -> Int
        \\f m =
        \\    case m of
        \\        Just n ->
        \\            n
        \\
    ;
    try expectBudgetedCodes(&.{.missing_patterns}, source, Session.default_pattern_budget);
    try expectBudgetedCodes(&.{.pattern_budget_exhausted}, source, 1);
}

test "the usefulness budget: exhaustion reports ONE code, not a partial answer" {
    // The same `case` is both non-exhaustive (no `Nothing` branch) and
    // redundant (`Just n` twice). With room to think the analysis reports
    // the redundancy, which is the first answer it reaches; out of budget it
    // reports neither, because a half-searched matrix proves nothing at all
    // — only `pattern_budget_exhausted`, once.
    const source =
        \\pub f : Maybe Int -> Int
        \\f m =
        \\    case m of
        \\        Just n ->
        \\            n
        \\
        \\        Just k ->
        \\            k
        \\
    ;
    try expectBudgetedCodes(&.{.redundant_pattern}, source, Session.default_pattern_budget);
    try expectBudgetedCodes(&.{.pattern_budget_exhausted}, source, 1);
}

test "the usefulness budget: an irrefutable position refuses instead of going silent" {
    // An irrefutable position the analysis cannot decide would lose the
    // guarantee that `backend.md` §4's unchecked destructure stands on, so
    // there the undecided answer has always been a refusal (checker.md §6.6).
    //
    // Both answers are refusals since slice 14; what differs is the message
    // and the way out. A `case` can be split or given a bigger budget; an
    // irrefutable position has no branch to fall through to at all, so its
    // message says "`case` on it instead".
    //
    // `Boxed` is its type's only constructor, so with room to think the
    // analysis proves the parameter irrefutable and says nothing.
    const source =
        \\pub type Boxed
        \\    = Boxed Int
        \\
        \\
        \\pub f : Boxed -> Int
        \\f (Boxed n) =
        \\    n
        \\
    ;
    try expectBudgetedCodes(&.{}, source, Session.default_pattern_budget);
    try expectBudgetedCodes(&.{.refutable_parameter_pattern}, source, 1);
}

test "the usefulness budget: many constructors times many branches terminates" {
    // Forty constructors and forty branches, each branch a two-deep nest of
    // them: the shape that makes every column of the matrix complete, which
    // is where the exponent lives. The contract is that this FINISHES —
    // with the default budget it is analysed and answers `missing_patterns`,
    // with a small one it is refused as `pattern_budget_exhausted`, and
    // neither answer is a hang or a crash.
    const gpa = testing.allocator;
    const ctors = 40;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("pub type T\n");
    for (0..ctors) |i| try w.print("    {s} C{d} T\n", .{ if (i == 0) "=" else "|", i });
    try w.writeAll("\n\npub f : T -> Int\nf t =\n    case t of\n");
    for (0..ctors) |i| {
        if (i != 0) try w.writeAll("\n");
        try w.print("        C{d} (C{d} rest{d}) ->\n            {d}\n", .{ i, (i + 1) % ctors, i, i });
    }
    const text = try gpa.dupeZ(u8, out.written());
    defer gpa.free(text);

    for ([_]u32{ Session.default_pattern_budget, 64 }) |budget| {
        const codes = try budgetedCodes(gpa, text, budget);
        defer gpa.free(codes);
        // Exactly one message either way: the real answer, or the refusal
        // that says there is no real answer. Never a crash, never two.
        try testing.expectEqual(@as(usize, 1), codes.len);
        try testing.expect(codes[0] == .missing_patterns or codes[0] == .pattern_budget_exhausted);
    }
}

test "fuzz: arbitrary bytes as the patterns of a `case` never panic the usefulness check" {
    // The general pipeline fuzz below reaches `Exhaustive` only when random
    // bytes happen to make a declaration that type-checks, which is almost
    // never. This one puts the fuzzed bytes where the patterns of a `case`
    // over a real ADT go, so whatever the parser makes of them is what the
    // matrix is built from — mixed columns, poisoned references, nesting,
    // arities that do not match. Contract: no panic, and no diagnostic is
    // required.
    try testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const len = smith.sliceWithHash(&buf, 0x5E6A2);
            const gpa = testing.allocator;
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            out.writer.writeAll(
                \\pub type T
                \\    = A Int
                \\    | B
                \\    | C T T
                \\
                \\
                \\pub f : T -> Int
                \\f t =
                \\    case t of
                \\
            ) catch return;
            // One branch per line of the fuzzed bytes, each at the branch
            // indent, so a line that happens to be a pattern becomes one.
            var it = std.mem.splitScalar(u8, buf[0..len], '\n');
            while (it.next()) |line| {
                out.writer.print("        {s} ->\n            0\n\n", .{line}) catch return;
            }
            out.writer.writeAll("        _ ->\n            1\n") catch return;
            const source = gpa.dupeZ(u8, out.written()) catch return;
            defer gpa.free(source);
            var codes: std.ArrayList(diagnostic.Code) = .empty;
            defer codes.deinit(gpa);
            checkCodes(gpa, source, &codes) catch |err| switch (err) {
                error.OutOfMemory => return,
                else => return err,
            };
        }
    }.testOne, .{});
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
