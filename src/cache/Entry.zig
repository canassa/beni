//! Loading one cache entry (docs/design/checker.md §7, *The cache entry, and
//! the sidecar beside the record*; `fast-compiler.md` §8 for what a hit
//! skips).
//!
//! The container is `entry_bytes.zig` and the two payload formats are
//! `resolve/iface_bytes.zig` and `dispatch_bytes.zig`; what is here is the
//! step above all three — read the file, decode it, re-intern it, and decide
//! whether it describes THIS module.
//!
//! **Loading runs serially, before any worker starts.** `InternPool.Global`
//! is thread-confined and a cross-process load must `getOrPut` — the case
//! `iface_bytes`' header reserves `readGrowing` for. What is deliberately NOT
//! done here is resolving the sidecar's two reference tables: that needs
//! `Types`, which does not exist yet, and it happens on the DAG in the hit
//! path.
//!
//! **A loaded record is validated against the SHELL.** `Interface.build` has
//! already run at resolve time and produced this module's `values`, `types`
//! and `ctors` tables and its `Provenance`; the loaded record replaces the
//! shell wholesale, so the counts and the name of every entry of all three
//! tables must agree first. `Provenance` is `Bir.DeclIndex`es indexed by
//! slot, it is never serialized, and a record whose slots did not line up
//! with it would be a silent miscompile rather than a miss. On the 100k
//! corpus that is ~2 500 comparisons for the whole project.
//!
//! **Every failure is a MISS**, returned as `null`: a missing file, a
//! corrupt one, an entry written for another key, a record naming a string
//! that cannot be interned, or one whose shape disagrees with the shell. A
//! stale cache must be indistinguishable from a cold build, so none of them
//! is a diagnostic and none is an exit code.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const Interface = @import("../resolve/Interface.zig");
const iface_bytes = @import("../resolve/iface_bytes.zig");
const Dir = @import("Dir.zig");
const Key = @import("Key.zig");
const entry_bytes = @import("entry_bytes.zig");
const dispatch_bytes = @import("dispatch_bytes.zig");
const SchemaPlan = @import("../check/SchemaPlan.zig");
const schema_plan_bytes = @import("schema_plan_bytes.zig");

/// One entry, decoded and validated, waiting to be installed.
///
/// `bytes` is kept because the diagnostics' messages point into it: they are
/// copied into session memory only when they are replayed, which keeps a hit
/// to one allocation per module for the common case of no diagnostics at all.
pub const Loaded = struct {
    /// Owned. The file's bytes; `diagnostics` borrows from them.
    bytes: []u8,
    /// Owned. Moved into `interfaces[m]` by the hit path.
    record: Interface,
    /// Owned, and still holding reference INDICES: `dispatch_bytes.resolve`
    /// turns them into this session's ids on the DAG.
    sidecar: dispatch_bytes.Loaded,
    /// Owned resolved schema plan; stable references are resolved by the
    /// checker after graph/interface installation.
    plan: SchemaPlan,
    /// Borrowed from `bytes`.
    diagnostics: []const entry_bytes.Diagnostic,

    pub const empty: Loaded = .{
        .bytes = &.{},
        .record = .empty,
        .sidecar = .empty,
        .plan = .empty,
        .diagnostics = &.{},
    };

    pub fn deinit(l: *Loaded, gpa: Allocator) void {
        gpa.free(l.bytes);
        l.record.deinit(gpa);
        l.sidecar.deinit(gpa);
        l.plan.deinit(gpa);
        gpa.free(@constCast(l.diagnostics));
        l.* = empty;
    }
};

/// The entry for `key`, or null for a miss.
///
/// `interner` is grown: a record written by an earlier process names strings
/// this session may never have seen. That is safe here and only here,
/// because this runs before any worker starts.
pub fn load(
    gpa: Allocator,
    dir: *const Dir,
    key: Key.Key,
    interner: *InternPool.Global,
    shell: *const Interface,
) Allocator.Error!?Loaded {
    return loadWith(gpa, dir, key, .{ .grow = interner }, shell);
}

/// `load`, on a WORKER, re-interning through the non-mutating
/// `InternPool.Global.find` (`fast-compiler.md` §8, `plans/m4-3.md` §4.3).
///
/// **This is what makes a load on the DAG legal at all.** `Global` is
/// thread-confined, so a `getOrPut` from a worker is a data race; `find` is a
/// read and is not. What it costs is that a string the session never interned
/// makes the load fail — and *measured over the warm 100k corpus, `core` and
/// `tests/corpus/run`, at `--jobs=1` and `--jobs=8`, 24 281 strings were
/// re-interned on cross-process loads and 0 of them would have missed `find`*:
/// every string a cache entry names is one some module of this build already
/// interned, because an entry names declarations and modules of this build and
/// the front-end cache re-interns every module's whole `Bir.symbols` column on every run.
///
/// **And the posture is DEGRADE, not trap.** A `find` miss is a cache MISS and
/// the module is checked, never an `internal` — so even if the argument is one
/// day wrong, the failure is a slow build and not a wrong one.
pub fn loadFinding(
    gpa: Allocator,
    dir: *const Dir,
    key: Key.Key,
    interner: *const InternPool.Global,
    shell: *const Interface,
) Allocator.Error!?Loaded {
    return loadWith(gpa, dir, key, .{ .find = interner }, shell);
}

/// Which of the two interning postures a load takes. `iface_bytes`' own
/// `Interning` union by another name, carried here so the two payload readers
/// are chosen together and can never disagree.
const Interning = union(enum) {
    grow: *InternPool.Global,
    find: *const InternPool.Global,
};

fn loadWith(
    gpa: Allocator,
    dir: *const Dir,
    key: Key.Key,
    interning: Interning,
    shell: *const Interface,
) Allocator.Error!?Loaded {
    const bytes = dir.load(gpa, key) orelse return null;
    var out: Loaded = .{ .bytes = bytes, .record = .empty, .sidecar = .empty, .plan = .empty, .diagnostics = &.{} };
    errdefer out.deinit(gpa);

    const entry = entry_bytes.readFor(bytes, key) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadEntry => {
            out.deinit(gpa);
            return null;
        },
    };
    out.record = (switch (interning) {
        .grow => |pool| iface_bytes.readGrowing(gpa, entry.interface, pool),
        .find => |pool| iface_bytes.read(gpa, entry.interface, pool),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // On the growing path `UnknownSymbol` cannot happen; on the finding
        // path it is the degradation above. A cache turns everything that is
        // not OOM into a miss either way.
        error.BadRecord, error.UnknownSymbol => {
            out.deinit(gpa);
            return null;
        },
    };
    out.sidecar = (switch (interning) {
        .grow => |pool| dispatch_bytes.readGrowing(gpa, entry.dispatch, pool),
        .find => |pool| dispatch_bytes.read(gpa, entry.dispatch, pool),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadSidecar, error.UnknownSymbol => {
            out.deinit(gpa);
            return null;
        },
    };
    out.plan = (switch (interning) {
        .grow => |pool| schema_plan_bytes.readGrowing(gpa, entry.schema_plan, pool),
        .find => |pool| schema_plan_bytes.read(gpa, entry.schema_plan, pool),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadPlan, error.UnknownSymbol => {
            out.deinit(gpa);
            return null;
        },
    };
    out.diagnostics = entry_bytes.readDiagnostics(gpa, entry.diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadEntry => {
            out.deinit(gpa);
            return null;
        },
    };
    if (!matchesShell(&out.record, shell)) {
        out.deinit(gpa);
        return null;
    }
    return out;
}

/// Whether a loaded record describes the module the shell describes: the
/// same number of values, types, constructors and schema namespace rows, each
/// with the same lexical shape in the same slot.
///
/// This is what stands between a key collision — or a file somebody moved —
/// and a silent miscompile. `Provenance` is indexed by slot and is never
/// serialized, so a record whose slots did not line up with it would install
/// one declaration's scheme under another's name.
///
/// Names are compared as SYMBOLS and not as text, which is sound because the
/// loaded record was interned into this session's pool on the way in.
fn matchesShell(loaded: *const Interface, shell: *const Interface) bool {
    if (loaded.values.len != shell.values.len) return false;
    if (loaded.types.len != shell.types.len) return false;
    if (loaded.ctors.len != shell.ctors.len) return false;
    if (loaded.schemas.len != shell.schemas.len) return false;
    if (loaded.schema_members.len != shell.schema_members.len) return false;
    if (loaded.schema_ctors.len != shell.schema_ctors.len) return false;
    for (loaded.values, shell.values) |a, b| {
        if (loaded.symbol(a.name) != shell.symbol(b.name)) return false;
        // Foreignness is one bit derived from the source; a record that
        // disagreed with the shell about it would emit a call to JavaScript
        // that does not exist, or fail to.
        if (a.is_foreign != b.is_foreign) return false;
    }
    for (loaded.types, shell.types) |a, b| {
        if (loaded.symbol(a.name) != shell.symbol(b.name)) return false;
        if (a.arity != b.arity or a.kind != b.kind or a.is_opaque != b.is_opaque) return false;
    }
    for (loaded.ctors, shell.ctors) |a, b| {
        if (loaded.symbol(a.name) != shell.symbol(b.name)) return false;
        if (a.type != b.type) return false;
        // A record alias's field names are lexical, so the shell has them
        // (interface v3): a record whose names disagreed would build the
        // record with the wrong keys, which is a miscompile and not a miss.
        if (a.result != b.result or a.arity != b.arity) return false;
        const names_a = loaded.range(a.fields);
        const names_b = shell.range(b.fields);
        if (names_a.len != names_b.len) return false;
        for (names_a, names_b) |x, y| {
            if (loaded.symbol(@enumFromInt(x)) != shell.symbol(@enumFromInt(y))) return false;
        }
    }
    for (loaded.schemas, shell.schemas) |a, b| {
        if (loaded.symbol(a.name) != shell.symbol(b.name)) return false;
        if (a.params_len != b.params_len or a.members_start != b.members_start or a.members_end != b.members_end) return false;
        if (a.program_ctors_start != b.program_ctors_start or a.program_ctors_end != b.program_ctors_end) return false;
        if (a.encoded_ctors_start != b.encoded_ctors_start or a.encoded_ctors_end != b.encoded_ctors_end) return false;
    }
    for (loaded.schema_members, shell.schema_members) |a, b| {
        if (loaded.symbol(a.name) != shell.symbol(b.name)) return false;
        if (a.schema != b.schema or a.kind != b.kind or a.arity != b.arity or a.visible != b.visible) return false;
    }
    for (loaded.schema_ctors, shell.schema_ctors) |a, b| {
        if (loaded.symbol(a.name) != shell.symbol(b.name)) return false;
        if (a.schema != b.schema or a.endpoint != b.endpoint or a.arity != b.arity or a.visible != b.visible) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a record whose shape disagrees with the shell is a miss, not a miscompile" {
    // A fabricated record with one extra `pub`
    // value — the shape a key collision or a moved file would produce — must
    // be refused, because `Provenance` is indexed by slot and installing this
    // record would put one declaration's scheme under another's name.
    const gpa = testing.allocator;
    var pool = try InternPool.Global.init(gpa);
    defer pool.deinit(gpa);
    const a = try pool.getOrPut(gpa, "alpha");
    const b = try pool.getOrPut(gpa, "beta");

    const shell: Interface = .{
        .values = &.{.{ .name = @enumFromInt(0), .scheme = .none, .is_foreign = false }},
        .types = &.{},
        .ctors = &.{},
        .schemas = &.{},
        .schema_members = &.{},
        .schema_ctors = &.{},
        .schemes = &.{},
        .terms = .empty,
        .extra = &.{},
        .type_refs = &.{},
        .symbols = &.{a},
    };
    try testing.expect(matchesShell(&shell, &shell));

    // One extra value.
    const extra: Interface = .{
        .values = &.{
            .{ .name = @enumFromInt(0), .scheme = .none, .is_foreign = false },
            .{ .name = @enumFromInt(1), .scheme = .none, .is_foreign = false },
        },
        .types = &.{},
        .ctors = &.{},
        .schemas = &.{},
        .schema_members = &.{},
        .schema_ctors = &.{},
        .schemes = &.{},
        .terms = .empty,
        .extra = &.{},
        .type_refs = &.{},
        .symbols = &.{ a, b },
    };
    try testing.expect(!matchesShell(&extra, &shell));

    // The same count, a different name in the slot.
    const renamed: Interface = .{
        .values = &.{.{ .name = @enumFromInt(0), .scheme = .none, .is_foreign = false }},
        .types = &.{},
        .ctors = &.{},
        .schemas = &.{},
        .schema_members = &.{},
        .schema_ctors = &.{},
        .schemes = &.{},
        .terms = .empty,
        .extra = &.{},
        .type_refs = &.{},
        .symbols = &.{b},
    };
    try testing.expect(!matchesShell(&renamed, &shell));

    // The same name, a different foreignness.
    const foreign: Interface = .{
        .values = &.{.{ .name = @enumFromInt(0), .scheme = .none, .is_foreign = true }},
        .types = &.{},
        .ctors = &.{},
        .schemas = &.{},
        .schema_members = &.{},
        .schema_ctors = &.{},
        .schemes = &.{},
        .terms = .empty,
        .extra = &.{},
        .type_refs = &.{},
        .symbols = &.{a},
    };
    try testing.expect(!matchesShell(&foreign, &shell));
}
