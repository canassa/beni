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
    /// Borrowed from `bytes`.
    diagnostics: []const entry_bytes.Diagnostic,

    pub const empty: Loaded = .{
        .bytes = &.{},
        .record = .empty,
        .sidecar = .empty,
        .diagnostics = &.{},
    };

    pub fn deinit(l: *Loaded, gpa: Allocator) void {
        gpa.free(l.bytes);
        l.record.deinit(gpa);
        l.sidecar.deinit(gpa);
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
    const bytes = dir.load(gpa, key) orelse return null;
    var out: Loaded = .{ .bytes = bytes, .record = .empty, .sidecar = .empty, .diagnostics = &.{} };
    errdefer out.deinit(gpa);

    const entry = entry_bytes.readFor(bytes, key) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadEntry => {
            out.deinit(gpa);
            return null;
        },
    };
    out.record = iface_bytes.readGrowing(gpa, entry.interface, interner) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // `UnknownSymbol` cannot happen on this path — `readGrowing`
        // interns what it does not find — but it is in the error set, and a
        // cache turns everything that is not OOM into a miss.
        error.BadRecord, error.UnknownSymbol => {
            out.deinit(gpa);
            return null;
        },
    };
    out.sidecar = dispatch_bytes.readGrowing(gpa, entry.dispatch, interner) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadSidecar, error.UnknownSymbol => {
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
/// same number of values, types and constructors, each with the same name in
/// the same slot.
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
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a record whose shape disagrees with the shell is a miss, not a miscompile" {
    // `plans/m4-1.md` §6.2 row 21. A fabricated record with one extra `pub`
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
        .schemes = &.{},
        .terms = .empty,
        .extra = &.{},
        .type_refs = &.{},
        .symbols = &.{a},
    };
    try testing.expect(!matchesShell(&foreign, &shell));
}
