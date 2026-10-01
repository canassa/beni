//! The covered-read self-check (`plans/m4-3.md` §9, `fast-compiler.md`
//! §8, *The firewall cutoff, and the dependency digest*).
//!
//! **What it is for.** The firewall cutoff lets the cache SKIP a module's check on the
//! strength of an argument — the enumeration of `plans/m4-3.md` §3, which says
//! what a dependent's check can observe about its dependencies. A wrong
//! enumeration is a stale answer that depends on history and shows up only
//! after a particular edit sequence, so the enumeration is enforced by the
//! compiler rather than by the specification: in a safe build every
//! cross-module read on the checking path records `(kind of fact, module
//! read)`, and a module that read something its key does not cover reports
//! `internal`.
//!
//! It is the same move `Reach.requireLive` and `Rename.verify` make, and both
//! of those caught a specification error before any fixture did.
//!
//! **Two questions, and they have different teeth.**
//!
//! *Which KIND was read* is a COMPILE-time question: `Kind` is closed, and a
//! new cross-module accessor cannot be instrumented without adding a variant
//! and therefore without placing it in §3.2's table. There is no runtime
//! branch for it — every variant that exists is one the recipe covers, and the
//! kind is carried only so that a violation's message can name it.
//!
//! *Which MODULE was read* is a RUNTIME question, and it is the substantive
//! one. A module's key covers itself, its transitive imports and the implicit
//! core modules — the first two because the digest is inductive over direct
//! imports, the third because `core_surface` is one term over the prelude and
//! `Task` (`fast-compiler.md` §8, amended 2026-10-01; `Graph.implicit_core`). Anything else is a fact the key cannot see move,
//! which is exactly the failure mode this slice is about: `checker.md` §7's
//! first `type_refs` consequence says a check can read facts about a module it
//! never imported, and `Solve.methodOnApp` carries an `internal` guard that
//! says so in the source.
//!
//! **A cyclic project is not checked.** A cycle has no topological order, so
//! the coverage closure cannot be computed in one sweep; its members are
//! poisoned and report nothing anyway (checker.md §4.3), exactly as
//! `Driver.parallelisable` already decides.
//!
//! **The recorder is thread-local** because the accessors it instruments —
//! `Types.entry` above all — are three arguments deep in the solver and have
//! no reader to be handed. One `Recorder` per worker, owned by that worker's
//! frame; `begin` publishes it for the duration of one module's check and
//! `end` takes it away, so nothing outside the DAG's per-module phase records
//! anything. `Types.build` and `TypeFacts.settle` run before any worker and are
//! §3.2's row 1 and row 9: whole-program passes, not dependencies.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph = @import("../resolve/Graph.zig");

/// Compiled away outside a safe build. `Rename.verify`'s gate, spelled the
/// same way, so a reader who knows one knows both.
pub const enabled = std.debug.runtime_safety;

/// The kinds of cross-module fact a module's check reads, one per row group of
/// `plans/m4-3.md` §3.2. The enum is CLOSED on purpose: instrumenting a new
/// accessor means adding a variant, which means placing it in that table.
pub const Kind = enum(u8) {
    /// §3.2 rows 2–6 and 14 — the `Types.Entry` fields behind a `TypeId`:
    /// `arity`, `kind`, `equatable`, `comparable`, `has_function`, `name` and
    /// `module_name`. `R` for a `pub` type, `D` for a private one; the digest
    /// carries all five bits and the two names by NAME.
    types_entry,
    /// §3.2 row 1 — a declaration's `TypeId`, by the declaring module's own
    /// `Bir.DeclIndex`. The ORDINAL is not observable (§3.3); what is read
    /// through it is `types_entry`.
    types_of_decl,
    /// §3.2 row 10 — interface `TypeIndex` → `TypeId`. A session's internal
    /// translation; what a dependent reads through it is the type at
    /// interface slot `i`, which the record states by name (`R`).
    types_of_interface,
    /// §3.2 row 11 — `Types.find`'s name lookup in another module's whole
    /// declaration list, which is how a `type_refs` row resolves. The NAME is
    /// in the record (`R`); what the scan yields is `types_entry`.
    types_find,
    /// §3.2 row 11 — another module's resolved `type_refs` table, read when an
    /// imported scheme is instantiated.
    types_ref_ids,
    /// §3.2 row 12 — cross-module alias expansion, read from the declaring
    /// module's `Bir`. `D`: the digest carries the expansion, and
    /// `plans/m4-3.md` §6.2 is the miscompile it closes.
    types_alias_body,
    /// §3.2 rows 17–22 and 25–27 — another module's interface record: its
    /// values, types, constructors, schemes and `where` shapes. `R`, all of
    /// it: this is the firewall as it was always intended.
    iface,
    /// §3.2 row 23 — another module's `Bir`, read to tell `private_method`
    /// from `unknown_method`. `E`: an error path, closed by the clean-check
    /// rule, and §4.2 finding 2 measures it at 0 on every clean corpus.
    bir,
};

/// One worker's record of what the module it is checking has read.
///
/// No allocation and no atomics on the recording path: one thread-local load,
/// one bit test and one bit set. The two arrays are sized once per worker.
pub const Recorder = struct {
    reader: Graph.Index = @enumFromInt(0),
    /// One bit per graph module: was it read during this module's check?
    read: std.DynamicBitSetUnmanaged = .{},
    /// The kind of the FIRST read recorded for each module, so a violation's
    /// message can name one. Parallel to `read`, and meaningful only where
    /// `read` is set.
    kind: []Kind = &.{},

    pub const empty: Recorder = .{};

    pub fn init(gpa: Allocator, modules: u32) Allocator.Error!Recorder {
        if (!enabled) return .{};
        return .{
            .read = try std.DynamicBitSetUnmanaged.initEmpty(gpa, modules),
            .kind = try gpa.alloc(Kind, modules),
        };
    }

    pub fn deinit(r: *Recorder, gpa: Allocator) void {
        if (!enabled) return;
        r.read.deinit(gpa);
        gpa.free(r.kind);
        r.* = .{};
    }
};

/// The recorder of the worker running on this thread, or null outside a
/// module's check. Written only by `begin` and `end`, and only ever with a
/// pointer into the calling worker's own frame.
threadlocal var current: ?*Recorder = null;

/// Start recording `m`'s check on this thread.
pub fn begin(r: *Recorder, m: Graph.Index) void {
    if (!enabled) return;
    r.reader = m;
    r.read.unsetAll();
    current = r;
}

/// Stop recording. Called on every path out of a module's check, including
/// the failing one.
pub fn end() void {
    if (!enabled) return;
    current = null;
}

/// Record that the module being checked read a fact of `kind` about `m`.
///
/// The whole of the hot path: a thread-local load, a null test, a bounds test
/// and at most one bit set per (module, check) pair. Outside a safe build the
/// body is dead and the call vanishes.
pub inline fn note(kind: Kind, m: Graph.Index) void {
    if (!enabled) return;
    const r = current orelse return;
    const i = m.int();
    if (i >= r.kind.len) return;
    if (r.read.isSet(i)) return;
    r.read.set(i);
    r.kind[i] = kind;
}

/// What a module's key can see move: itself, its transitive imports, and the
/// whole core package.
///
/// One row per module, built once per run in `graph.order` — which is
/// topological, so a dependency's row is complete before its dependent's is
/// read. `rows.len == 0` means "not built", which is what a cyclic project and
/// a release build both get.
pub const Coverage = struct {
    rows: []std.DynamicBitSetUnmanaged = &.{},

    pub const empty: Coverage = .{};

    /// Null when the graph has a cycle (see the header) or outside a safe
    /// build.
    pub fn build(gpa: Allocator, graph: *const Graph) Allocator.Error!Coverage {
        if (!enabled) return .{};
        const n = graph.count();
        for (0..n) |i| {
            if (graph.isPoisoned(@enumFromInt(i))) return .{};
        }
        var out: Coverage = .{ .rows = try gpa.alloc(std.DynamicBitSetUnmanaged, n) };
        errdefer out.deinit(gpa);
        for (out.rows) |*row| row.* = .{};
        for (out.rows) |*row| row.* = try .initEmpty(gpa, n);

        // `core_surface` is one term over the implicit core modules
        // (`Graph.implicit_core`), so every module's key sees those move;
        // any other core module it reads must be an edge, like any import.
        for (0..n) |i| {
            if (!graph.isImplicitCore(@enumFromInt(i))) continue;
            for (out.rows) |*row| row.set(i);
        }
        for (graph.order) |m| {
            const row = &out.rows[m.int()];
            row.set(m.int());
            for (graph.dependencies(m)) |dep| {
                if (dep == m) continue;
                row.set(dep.int());
                // The digest folds each import's own digest, so one level of
                // import terms carries every level (`fast-compiler.md` §8).
                row.setUnion(out.rows[dep.int()]);
            }
        }
        return out;
    }

    pub fn deinit(c: *Coverage, gpa: Allocator) void {
        for (c.rows) |*row| row.deinit(gpa);
        gpa.free(c.rows);
        c.* = .{};
    }

    pub fn built(c: *const Coverage) bool {
        return c.rows.len != 0;
    }
};

/// A read the reader's key does not cover.
pub const Violation = struct {
    read: Graph.Index,
    kind: Kind,
};

/// The first module `r` read that `coverage` says its key cannot see move, or
/// null when every read is covered. Deterministic: the scan is in module index
/// order, which is assigned before any thread starts.
pub fn firstUncovered(r: *const Recorder, coverage: *const Coverage) ?Violation {
    if (!enabled) return null;
    if (!coverage.built()) return null;
    if (r.reader.int() >= coverage.rows.len) return null;
    const row = &coverage.rows[r.reader.int()];
    var it = r.read.iterator(.{});
    while (it.next()) |i| {
        if (row.isSet(i)) continue;
        return .{ .read = @enumFromInt(@as(u32, @intCast(i))), .kind = r.kind[i] };
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a recorder keeps the first kind per module and nothing else" {
    if (!enabled) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r: Recorder = try .init(gpa, 4);
    defer r.deinit(gpa);
    begin(&r, @enumFromInt(0));
    defer end();

    note(.iface, @enumFromInt(2));
    note(.types_entry, @enumFromInt(2)); // the first kind wins
    note(.bir, @enumFromInt(3));
    // Out of range is dropped rather than trapping: a poisoned index must not
    // crash a self-check.
    note(.iface, @enumFromInt(99));

    try testing.expect(!r.read.isSet(1));
    try testing.expect(r.read.isSet(2));
    try testing.expectEqual(Kind.iface, r.kind[2]);
    try testing.expect(r.read.isSet(3));
    try testing.expectEqual(Kind.bir, r.kind[3]);
}

test "an uncovered read is found, in module index order, and a covered one is not" {
    // The verdict half of the self-check, against a hand-built coverage: the
    // closure `Coverage.build` computes needs a `Graph`, and what is asserted
    // here is the decision made once the closure exists. The real closure is
    // exercised by every corpus fixture from this commit on, which is the
    // point of landing it first.
    if (!enabled) return error.SkipZigTest;
    const gpa = testing.allocator;
    var coverage: Coverage = .{ .rows = try gpa.alloc(std.DynamicBitSetUnmanaged, 4) };
    defer coverage.deinit(gpa);
    for (coverage.rows) |*row| row.* = .{};
    for (coverage.rows) |*row| row.* = try .initEmpty(gpa, 4);
    // Module 0's key covers itself and module 1, and nothing else.
    coverage.rows[0].set(0);
    coverage.rows[0].set(1);

    var r: Recorder = try .init(gpa, 4);
    defer r.deinit(gpa);

    begin(&r, @enumFromInt(0));
    note(.iface, @enumFromInt(1));
    try testing.expectEqual(@as(?Violation, null), firstUncovered(&r, &coverage));

    // Two uncovered reads: the LOWER module index is reported, because the
    // message may not depend on which read happened first — the scan is over
    // indices assigned before any thread started (`fast-compiler.md` §10).
    note(.bir, @enumFromInt(3));
    note(.types_alias_body, @enumFromInt(2));
    const bad = firstUncovered(&r, &coverage).?;
    try testing.expectEqual(@as(u32, 2), bad.read.int());
    try testing.expectEqual(Kind.types_alias_body, bad.kind);
    end();

    // A coverage that was never built — a cyclic project, or a release
    // build — says nothing rather than saying everything is uncovered.
    var unbuilt: Coverage = .empty;
    begin(&r, @enumFromInt(0));
    defer end();
    note(.bir, @enumFromInt(3));
    try testing.expectEqual(@as(?Violation, null), firstUncovered(&r, &unbuilt));
}

test "recording stops outside a module's check" {
    if (!enabled) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r: Recorder = try .init(gpa, 2);
    defer r.deinit(gpa);
    begin(&r, @enumFromInt(0));
    end();
    note(.iface, @enumFromInt(1));
    try testing.expect(!r.read.isSet(1));
}
