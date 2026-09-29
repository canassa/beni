//! Schedules modules over the graph's DAG (checker.md §4.4).
//!
//! **What makes this safe** is the interface firewall: a module's check
//! reads its own Bir, the session-wide `Types` table (built before any
//! thread starts; each module writes only its own `ref_ids` slot), and the
//! INTERFACES of its
//! dependencies — and every reference to another module was rewritten by
//! `Resolve` into `(module index, interface index)`, so a module can only
//! ever read an interface it has an edge to. It writes its own interface,
//! its own slot of every per-module array, and nothing else.
//!
//! **What makes it deterministic** is that nothing is keyed by completion:
//! results land in the slot of a module index assigned before any thread
//! started, diagnostics are per module and concatenated in the graph's
//! order afterwards, and the counters are a commutative sum
//! (`fast-compiler.md` §10).
//!
//! **A cyclic project runs serially.** A cycle has no topological order, so
//! a member may read a co-member's interface that is still being written —
//! a data race, not merely a wrong answer. The members are poisoned and
//! report nothing anyway (checker.md §4.3), so the whole run falls back to
//! one thread rather than growing a second scheduling rule for the case
//! where the answer is already "this project does not compile".
//!
//! The key, load, install and publish steps a module goes through on its
//! worker are `Incremental.zig`'s (checker-v2.md §19); this file is the
//! schedule and, per module, a cache hit's install or `Module.check`
//! (`checkInner`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Arena = @import("../Arena.zig");
const Artifacts = @import("../Artifacts.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const Diagnostics = @import("Diagnostics.zig");
const Dispatch = @import("Dispatch.zig");
const Types = @import("Types.zig");
const SchemaPlan = @import("SchemaPlan.zig");
const reads = @import("reads.zig");
const Check = @import("Check.zig");
const Incremental = @import("Incremental.zig");
const ModuleCheck = @import("Module.zig");

const Driver = @This();
const Error = Check.Error;
const Options = Check.Options;
const Module = Check.Module;
const stack_size = Check.stack_size;

gpa: Allocator,
io: Io,
graph: *const Graph,
artifacts: *const Artifacts,
interfaces: []Interface,
provenance: []const Interface.Provenance,
interner: *const InternPool.Global,
types: *Types,
options: Options,
per_module: []std.ArrayList(Diagnostics.Item),
counters: []Check.Counters,
kept: []Module,
/// One per module, written by the worker that checked it.
dispatch: []Dispatch,
plans: []SchemaPlan,
/// Per module, written by the worker that checked it before `finish`
/// releases its dependents: whether an error reached it — its own (an
/// earlier phase's, which quiets it, or its check's), or any dependency's,
/// transitively. A clean module's `<error>` scheme is always one of these
/// (§12.2); `Module.assertErrorsReported` holds a
/// module with none to having no `err` of its own making.
tainted: []bool = &.{},
/// What each module's cache key can see move (`reads.zig`). Empty outside
/// a safe build and on a cyclic project, and then the self-check is off.
coverage: reads.Coverage = .empty,

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
/// **`core_surface`'s barrier** (`plans/m4-3.md` §7.1). Core modules the
/// walk has not yet published; while it is non-zero, no NON-core module is
/// ready, because `core_surface` is one term over core's whole public face
/// and a key finished before it existed would be a key that depends on
/// thread timing.
///
/// It is a gate on the existing schedule and not a wait on a condition: a
/// worker that BLOCKED on core while core modules sat unclaimed in the
/// queue would deadlock at `--jobs=n` the moment `n` non-core modules were
/// claimed first. Instead every non-core module carries one extra blocker
/// until the last core module finishes, which is `buildSchedule`'s own
/// mechanism and is provably deadlock-free — a core module never depends
/// on a non-core one.
///
/// At `--jobs=1` it costs nothing at all: the walk is reordered to put
/// core first, which `graph.order` permits for the same reason.
core_pending: usize = 0,
/// The first allocation failure any worker hit. One flag for all of
/// them: the run is over either way.
failure: ?Error = null,

pub fn go(d: *Driver, scratch: *Arena) Error!void {
    const jobs = if (d.parallelisable()) @min(d.options.jobs, try d.widthBound(), d.workBound()) else 1;
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

/// The most modules the walk can ever have in flight at once, bounded
/// from above so a pool is never larger than its work. Modules checked at
/// the same time are pairwise unordered, so no two of them lie on one
/// chain of imports, and a DAG with `n` modules whose longest chain has
/// `l` of them has at most `n - l + 1` such modules. The core barrier
/// splits the walk in two (see `core_pending`), so the bound is taken
/// over each half and the larger one kept. A thread past it would cost a
/// spawn and a 64 MiB stack and could never add parallelism.
fn widthBound(d: *const Driver) Allocator.Error!usize {
    const n = d.graph.count();
    const depth = try d.gpa.alloc(u32, n);
    defer d.gpa.free(depth);
    @memset(depth, 0);
    var modules: [2]usize = .{ 0, 0 };
    var longest: [2]u32 = .{ 0, 0 };
    // `graph.order` is topological on an unpoisoned graph, so every
    // dependency's depth is final before its dependents read it.
    for (d.graph.order) |m| {
        const half = @intFromBool(d.graph.modulePackage(m) == .core);
        var deepest: u32 = 0;
        for (d.graph.dependencies(m)) |dep| {
            if (dep == m) continue;
            if (@intFromBool(d.graph.modulePackage(dep) == .core) != half) continue;
            deepest = @max(deepest, depth[dep.int()]);
        }
        depth[m.int()] = deepest + 1;
        modules[half] += 1;
        longest[half] = @max(longest[half], deepest + 1);
    }
    var bound: usize = 1;
    for (modules, longest) |count, chain| {
        if (count != 0) bound = @max(bound, count - chain + 1);
    }
    return bound;
}

/// Tokens one checker thread is worth spawning for, under
/// `Options.size_by_work`. Checking runs at about 2 500 tokens a
/// millisecond, so this is some 6 ms of work per thread, against a spawn,
/// a `stack_size` mapping and the queue's hand-offs. The embedded core
/// package is about 10 000 tokens, so core plus a small project is checked
/// on the calling thread alone.
pub const tokens_per_checker = 16 * 1024;

/// The most threads the modules' size can keep busy: one per
/// `tokens_per_checker` tokens of every module in the graph, when the pool
/// is sized by work, and no bound otherwise. A module whose cache entry
/// will hit costs far less than its tokens, but whether it hits is known
/// only once its dependencies are done, so it is counted in full.
fn workBound(d: *const Driver) usize {
    if (!d.options.size_by_work) return std.math.maxInt(usize);
    var tokens: usize = 0;
    for (0..d.graph.count()) |i| {
        tokens += d.artifacts.spans(d.graph.moduleFile(@enumFromInt(i))).len();
    }
    return @max(1, std.math.divCeil(usize, tokens, tokens_per_checker) catch unreachable);
}

fn serial(d: *Driver, scratch: *Arena) Error!void {
    var patterns: Arena = .init(std.heap.page_allocator);
    defer patterns.deinit();
    var recorder: reads.Recorder = try .init(d.gpa, d.graph.count());
    defer recorder.deinit(d.gpa);
    // Core first, then the rest — still a topological order, because a
    // core module imports nothing outside core, and the order in which
    // `core_surface` becomes computable at `--jobs=1`. Within each half
    // the sequence is `graph.order`'s, so the walk is a function of the
    // input alone (`fast-compiler.md` §10).
    for (0..d.graph.count()) |i| {
        if (d.graph.modulePackage(@enumFromInt(i)) == .core) d.core_pending += 1;
    }
    for ([_]bool{ true, false }) |core| {
        for (d.graph.order) |m| {
            if ((d.graph.modulePackage(m) == .core) != core) continue;
            try d.check(m, scratch, &patterns, 0, &recorder);
            scratch.reset(.retain_capacity);
            if (core and d.core_pending != 0) d.core_pending -= 1;
            if (d.core_pending == 0) try d.closeCoreSurface(scratch);
            scratch.reset(.retain_capacity);
        }
    }
}

// The per-module steps of the cutoff protocol, called as methods so the
// schedule above and below reads exactly as it did in one file.
pub const closeCoreSurface = Incremental.closeCoreSurface;
pub const claim = Incremental.claim;
pub const compareKey = Incremental.compareKey;
pub const publish = Incremental.publish;
pub const verifyReads = Incremental.verifyReads;
pub const install = Incremental.install;

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

    // `core_surface`'s gate: one extra blocker on every non-core module
    // until the last core module has published (see `core_pending`).
    d.core_pending = 0;
    for (0..n) |i| {
        if (d.graph.modulePackage(@enumFromInt(i)) == .core) d.core_pending += 1;
    }
    if (d.core_pending != 0) {
        for (0..n) |i| {
            if (d.graph.modulePackage(@enumFromInt(i)) == .core) continue;
            d.blockers[i] += 1;
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

/// Drop the core gate from every non-core module and enqueue what that
/// released. Under the lock, once.
fn openCoreGate(d: *Driver) void {
    for (0..d.graph.count()) |i| {
        if (d.graph.modulePackage(@enumFromInt(i)) == .core) continue;
        d.blockers[i] -= 1;
        if (d.blockers[i] != 0) continue;
        d.queue[d.queue_len] = @enumFromInt(@as(u32, @intCast(i)));
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
    // One per WORKER, not one per module: the arrays are sized by the
    // module count and cleared per module, so the whole self-check costs
    // `jobs` allocations for the run. An allocation failure here is not
    // worth failing a build over — the self-check turns itself off.
    var recorder: reads.Recorder = reads.Recorder.init(d.gpa, d.graph.count()) catch reads.Recorder.empty;
    defer recorder.deinit(d.gpa);

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

        const result = d.check(m, scratch, &patterns, tid, &recorder);
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
    if (d.graph.modulePackage(m) == .core and d.core_pending != 0) {
        d.core_pending -= 1;
        if (d.core_pending == 0) {
            // The last core module has PUBLISHED — `check` publishes
            // before it returns, and `finish` is what releases anybody.
            var arena: Arena = .init(std.heap.page_allocator);
            defer arena.deinit();
            d.closeCoreSurface(&arena) catch |err| {
                if (d.failure == null) d.failure = err;
            };
            d.openCoreGate();
        }
    }
    for (d.dependents[d.dependent_start[m.int()]..d.dependent_start[m.int() + 1]]) |dependent| {
        d.blockers[dependent.int()] -= 1;
        if (d.blockers[dependent.int()] != 0) continue;
        d.queue[d.queue_len] = dependent;
        d.queue_len += 1;
    }
    d.wake.broadcast(d.io);
}

fn check(d: *Driver, m: Graph.Index, scratch: *Arena, patterns: *Arena, tid: u32, recorder: *reads.Recorder) Error!void {
    // The key and the entry load, before the check: whichever of the two
    // paths runs, it runs with the key already finished.
    try d.claim(m, scratch, tid);
    {
        reads.begin(recorder, m);
        // On every path out, including the failing one: a recorder left
        // published would attribute the NEXT module's reads to this one.
        defer reads.end();
        try d.checkInner(m, scratch, patterns, tid);
        try d.verifyReads(m, recorder);
    }
    // **Published before `finish(m)` releases the dependents.** `finish`
    // is what drops their blocker counts, and a dependent that woke to an
    // unwritten slot would fold `none` into its key — a wrong answer that
    // depends on thread timing, which is the one thing §10 forbids.
    try d.publish(m, scratch, tid);
}

fn checkInner(d: *Driver, m: Graph.Index, scratch: *Arena, patterns: *Arena, tid: u32) Error!void {
    const dependency_errors = d.dependencyErrors(m);
    defer if (m.int() < d.tainted.len) {
        d.tainted[m.int()] = dependency_errors or d.reportedError(m);
    };
    if (m.int() < d.options.cached.len) {
        if (d.options.cached[m.int()]) |*loaded| {
            const file = d.graph.moduleFile(m);
            const bir = d.artifacts.bir(file);
            const token_count: u32 = @intCast(d.artifacts.spans(file).len());
            if (loaded.plan.verifyAgainstBir(bir, token_count) and
                loaded.plan.verifyTargets(m, bir, d.graph, d.interfaces, d.interner, d.types))
                return d.install(m, loaded);
            // A malformed or stale sidecar is a cache miss. Release the
            // entry here because the normal check below replaces it. The
            // slot and hit bit must agree with that path: `storeEntries`
            // uses the slot to decide whether the newly checked entry
            // needs writing, and the cache profile reports the hit bit.
            loaded.deinit(d.gpa);
            d.options.cached[m.int()] = null;
            if (d.options.cutoff) |cutoff| cutoff.hit[m.int()] = false;
        }
    }
    d.counters[m.int()] = try ModuleCheck.check(.{
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
        .dispatch = &d.dispatch[m.int()],
        .plan = &d.plans[m.int()],
        .roundtrip_interfaces = d.options.roundtrip_interfaces,
        .roundtrip_dispatch = d.options.roundtrip_dispatch,
        .informational = d.options.informational,
        .keep = if (d.kept.len != 0) &d.kept[m.int()] else null,
        .dependency_errors = dependency_errors,
    });
}

/// Whether an error reached one of `m`'s dependencies (`tainted`). Every
/// dependency has finished: `m` was not ready before.
fn dependencyErrors(d: *const Driver, m: Graph.Index) bool {
    for (d.graph.dependencies(m)) |dep| {
        if (dep.int() >= d.tainted.len or d.tainted[dep.int()]) return true;
    }
    return false;
}

/// Whether `m` itself carries an error: an earlier phase reported one (it
/// was checked quietly), the graph poisoned it, or its check reported one.
fn reportedError(d: *const Driver, m: Graph.Index) bool {
    if (m.int() < d.options.quiet.len and d.options.quiet[m.int()]) return true;
    if (d.graph.isPoisoned(m)) return true;
    for (d.per_module[m.int()].items) |item| {
        if (item.severity == .@"error") return true;
    }
    return false;
}
