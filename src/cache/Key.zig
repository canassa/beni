//! The persistent cache's key (docs/design/fast-compiler.md §8, *The
//! persistent cache, and its key*): 128 bits over everything that can reach
//! one module's check.
//!
//! ```
//! "BENIKEY\x00"           8       magic
//! key_version: u32                bumped whenever this recipe changes
//! build_id: [16]u8                the compiler build id (`src/build_id.zig`)
//! package: u8                     SourceStore.Package — app, core or platform
//! name_len: u32, name             the DOTTED module name ("Json.Decode"), UTF-8
//! options_len: u32, options       the canonical option string, below
//! source_hash: [16]u8             over the module's source bytes
//! sibling_hash: [16]u8            over its sibling .js, or 16 zero bytes when
//!                                 it declares no `foreign`
//! core_epoch: [16]u8              over every core module's key; 16 zero bytes
//!                                 for a core module itself
//! import_count: u32
//!   per direct import, sorted by (package, name), duplicates removed:
//!     package: u8, name_len: u32, name, key: [16]u8
//! ```
//!
//! **An import contributes its KEY, not its interface hash**, which is the
//! slice's central decision. A key is inductively the whole transitive input
//! set, so an equal key means every byte that could reach this module's check
//! is identical — and so is every whole-program fact recomputed from them.
//! The interface-hash form is *weaker* than the record, because a dependent's
//! check reads facts about its dependencies the record does not carry; proving
//! that enumeration complete is the whole content of M4-3. The cost is stated
//! plainly: **a comment-only edit to a leaf re-checks every transitive
//! importer**, because the leaf's key moved though its interface hash did not.
//!
//! **The DOTTED MODULE NAME, never a path and never a `Graph.Index`.** A path
//! depends on the cwd the compiler was run from and on `--root`; an index
//! depends on which files were named on the command line. A key that carried
//! either would miss for a build that is identical in every way that matters,
//! which is a cache that does nothing — and, worse, would make the fixtures
//! that assert "these keys moved and no others" pass for the wrong reason.
//!
//! **`core` is an unconditional input of every module's check**, with no
//! import edge to say so: the solver reaches `core/Basics` directly, the
//! well-known types come from core's interfaces, and `Reach` reads core's
//! `Bir`. `core_epoch`, one hash over the sorted `(module name, key)` list of
//! the core package, is how the key says so.
//!
//! **Keys are computed serially, in `graph.order`**, which is why an import's
//! key is always available before its importer's. Core first, all of it, so
//! that `core_epoch` exists before any module that needs it — `graph.order`
//! puts dependencies before dependents but does not promise that every core
//! module precedes every app one, and a module that resolves no prelude name
//! has no edge to core at all.
//!
//! **Uncacheability propagates.** A module the graph poisoned, or one an
//! earlier phase already reported on, has no well-founded key: it is marked
//! uncacheable, contributes 16 zero bytes to its importers, and marks them
//! uncacheable too. One `bool` beside the key.
//!
//! The hash is `iface_bytes.hash` — `SipHash128(1, 3)` with an all-zero key —
//! so there is one hash function in the compiler. It is **not a MAC**; the
//! threat model is accident.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Artifacts = @import("../Artifacts.zig");
const InternPool = @import("../InternPool.zig");
const SourceStore = @import("../SourceStore.zig");
const Graph = @import("../resolve/Graph.zig");
const iface_bytes = @import("../resolve/iface_bytes.zig");

/// First eight bytes of every key's byte string.
pub const magic = "BENIKEY\x00";

/// Bumped whenever the meaning of any byte of the recipe changes. Every
/// entry written by an older recipe then misses, which is the only
/// migration a cache ever needs.
pub const key_version: u32 = 1;

/// 128 bits, so that an accidental collision has to be impossible rather
/// than unlikely: a collision here is a wrong answer that depends on
/// history.
pub const Key = [16]u8;

/// What a term contributes when there is nothing to contribute: a module
/// with no `foreign`, a core module's `core_epoch`, an uncacheable import.
pub const none: Key = @splat(0);

/// The 32 lowercase hex digits `--cache-keys` prints, through the one hex
/// renderer in the compiler.
pub fn hex(k: Key) [32]u8 {
    return iface_bytes.hashHex(k);
}

/// One direct import's contribution. The caller sorts and deduplicates.
pub const Import = struct {
    package: SourceStore.Package,
    /// The dotted module name.
    name: []const u8,
    /// The import's own KEY, or `none` when it is uncacheable.
    key: Key,
};

/// Everything the recipe reads about one module.
pub const Terms = struct {
    build_id: [16]u8,
    package: SourceStore.Package,
    name: []const u8,
    options: []const u8,
    source_hash: [16]u8,
    sibling_hash: Key = none,
    core_epoch: Key = none,
    /// Sorted by `(package, name)`, duplicates removed.
    imports: []const Import = &.{},
};

/// The recipe's byte string, appended to `out`. Exposed so a test can assert
/// the BYTES rather than only the digest: a recipe change that produced the
/// same 16 bytes for two different inputs would be invisible to a test that
/// only ever compared keys.
pub fn writeBytes(gpa: Allocator, out: *std.ArrayList(u8), t: Terms) Allocator.Error!void {
    try writeOwn(gpa, out, t);
    try writeRest(gpa, out, t.core_epoch, t.imports);
}

/// The prefix with NO import term: package, name, option string, source hash,
/// sibling hash, and the three constants in front of them.
///
/// **It is a prefix and not a hash**, which is the whole point: the key's bytes
/// are one string and the part that depends on nothing else in the project can
/// be produced serially, once, while the rest is appended on the DAG by the
/// worker that claimed the module. `writeBytes` is the two halves in order, and
/// a test asserts that it still is.
pub fn writeOwn(gpa: Allocator, out: *std.ArrayList(u8), t: Terms) Allocator.Error!void {
    try out.appendSlice(gpa, magic);
    try appendInt(gpa, out, u32, key_version);
    try out.appendSlice(gpa, &t.build_id);
    try out.append(gpa, @intFromEnum(t.package));
    try appendInt(gpa, out, u32, @intCast(t.name.len));
    try out.appendSlice(gpa, t.name);
    try appendInt(gpa, out, u32, @intCast(t.options.len));
    try out.appendSlice(gpa, t.options);
    try out.appendSlice(gpa, &t.source_hash);
    try out.appendSlice(gpa, &t.sibling_hash);
}

/// Everything `writeOwn` left out: the core term, then the import terms.
pub fn writeRest(gpa: Allocator, out: *std.ArrayList(u8), core: Key, imports: []const Import) Allocator.Error!void {
    try out.appendSlice(gpa, &core);
    try appendInt(gpa, out, u32, @intCast(imports.len));
    for (imports) |i| {
        try out.append(gpa, @intFromEnum(i.package));
        try appendInt(gpa, out, u32, @intCast(i.name.len));
        try out.appendSlice(gpa, i.name);
        try out.appendSlice(gpa, &i.key);
    }
}

/// `m`'s key, from its `own_terms` blob and the terms only the DAG knows.
///
/// This is the function the worker that claimed `m` calls. `scratch` holds one
/// module's byte string and may be reset the moment it returns.
pub fn finish(scratch: Allocator, own: []const u8, core: Key, imports: []const Import) Allocator.Error!Key {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(scratch);
    try bytes.appendSlice(scratch, own);
    try writeRest(scratch, &bytes, core, imports);
    return iface_bytes.hash(bytes.items);
}

pub fn compute(gpa: Allocator, t: Terms) Allocator.Error!Key {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try writeBytes(gpa, &bytes, t);
    return iface_bytes.hash(bytes.items);
}

fn appendInt(gpa: Allocator, out: *std.ArrayList(u8), comptime T: type, value: T) Allocator.Error!void {
    var word: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &word, value, .little);
    try out.appendSlice(gpa, &word);
}

/// One hash over the core package's `(module name, key)` list, sorted by
/// name text — the key's way of saying that every module's check reads core
/// whether or not it has an edge to it.
pub fn coreEpoch(gpa: Allocator, entries: []const CoreEntry) Allocator.Error!Key {
    if (entries.len == 0) return none;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    for (entries) |e| {
        try appendInt(gpa, &bytes, u32, @intCast(e.name.len));
        try bytes.appendSlice(gpa, e.name);
        try bytes.appendSlice(gpa, &e.key);
    }
    return iface_bytes.hash(bytes.items);
}

pub const CoreEntry = struct { name: []const u8, key: Key };

// ---------------------------------------------------------------------------
// The canonical option string
// ---------------------------------------------------------------------------

/// The flags that change what a module produces, and only those
/// (`fast-compiler.md` §8): `Lower.Options`' two permission bits, the
/// informational-warning switch, and the usefulness budget whose exhaustion
/// is an error of that module.
///
/// **The two permission bits are per MODULE, not per run**, because that is
/// what `Lower.Options` is: `Session.fileIsCore` and
/// `Session.fileMayDeclareForeign` are asked per file. Writing the run's
/// `--core` instead would say that `--core` changed what a core module
/// produces, which it does not — a core module is core either way — and
/// would invalidate core's entries for every corpus fixture that passes the
/// flag. The spec's string is reproduced exactly; only the source of the two
/// bits is sharpened, and sharper is a smaller key, never a wronger one.
///
/// Everything else on `Cli.Common`, `Cli.Check` and `Cli.Build` is OUT, each
/// for a reason `fast-compiler.md` §8 gives: `--jobs` because output is
/// identical for every `n` and keying on it would hide the bug that rule
/// forbids; `--root` and `--core-root` because they reach the key through
/// the module name and through `core_epoch`; `--platform` because what it
/// changes is what an import resolves to, which the import terms carry;
/// `--diagnostics`, `--self-profile`, `--explain`, `--iface-hash`,
/// `--positions` because they select a rendering; `--roundtrip-interfaces`
/// and `--roundtrip-dispatch` because a run with either must produce the
/// same record, and exempting them would excuse them from the acceptance
/// matrix; `--out`, `--library`, `--release` because they are the backend's
/// and no emitted byte is cached in M4-1.
pub const OptionBits = struct {
    /// `Lower.Options.core` for this module's file.
    core: bool,
    /// `Lower.Options.platform` for this module's file.
    platform: bool,
    informational: bool,
    pattern_budget: u32,
};

/// Room for `core=0;platform=0;informational=0;pattern_budget=` and ten
/// digits, with slack.
pub const options_buffer_len = 80;

pub fn writeOptions(buffer: *[options_buffer_len]u8, bits: OptionBits) []const u8 {
    return std.fmt.bufPrint(buffer, "core={d};platform={d};informational={d};pattern_budget={d}", .{
        @intFromBool(bits.core),
        @intFromBool(bits.platform),
        @intFromBool(bits.informational),
        bits.pattern_budget,
    }) catch unreachable; // `options_buffer_len` is the bound, asserted below
}

// ---------------------------------------------------------------------------
// The serial pass
// ---------------------------------------------------------------------------

/// One key and one cacheability bit per graph module, in module index order.
pub const Keys = struct {
    keys: []Key,
    /// True when this module has no well-founded key: the graph poisoned it,
    /// an earlier phase already reported on it, or one of its imports is
    /// itself uncacheable.
    uncacheable: []bool,
    /// Owned, one blob per module: `writeOwn`'s prefix, the part of the key
    /// that depends on nothing else in the project.
    ///
    /// **This is what the serial pass produces from M4-3 on.** An import's
    /// contribution exists only once that import has been checked or loaded,
    /// so the serial pass cannot finish a key it can no longer see the terms
    /// of; what it can still do — reading and hashing every source and every
    /// sibling `.js` — is all of it, and it keeps the `cache_key` row.
    own: [][]u8 = &.{},
    /// The core term every non-core module's key takes. Computed by the serial
    /// pass while the recipe is `core_epoch` over core's KEYS, which a serial
    /// pass can still see because a core module imports nothing outside core.
    core_epoch: Key = none,

    pub const empty: Keys = .{ .keys = &.{}, .uncacheable = &.{} };

    pub fn deinit(k: *Keys, gpa: Allocator) void {
        gpa.free(k.keys);
        gpa.free(k.uncacheable);
        for (k.own) |blob| gpa.free(blob);
        gpa.free(k.own);
        k.* = empty;
    }

    /// `m`'s `own_terms` blob, or empty when the run computed none.
    pub fn ownTerms(k: *const Keys, m: Graph.Index) []const u8 {
        if (m.int() >= k.own.len) return &.{};
        return k.own[m.int()];
    }

    /// Record the key the DAG finished for `m`. One writer per slot: the
    /// worker that claimed the module.
    pub fn set(k: *Keys, m: Graph.Index, key: Key) void {
        if (m.int() >= k.keys.len) return;
        k.keys[m.int()] = key;
    }

    pub fn len(k: *const Keys) usize {
        return k.keys.len;
    }

    /// `m`'s key, or `none` when the run computed none.
    pub fn of(k: *const Keys, m: Graph.Index) Key {
        if (m.int() >= k.keys.len) return none;
        return k.keys[m.int()];
    }

    pub fn isCacheable(k: *const Keys, m: Graph.Index) bool {
        if (m.int() >= k.uncacheable.len) return false;
        return !k.uncacheable[m.int()];
    }
};

/// A file the compiler carries rather than reads: core's siblings and the
/// chosen platform's. Its own type rather than `js/Emit.zig`'s `Asset`, so
/// that the cache does not depend on the backend to compute a key.
pub const Asset = struct { path: []const u8, bytes: []const u8 };

pub const Options = struct {
    build_id: [16]u8,
    informational: bool,
    pattern_budget: u32,
    /// Per FILE index: `Lower.Options`' two bits as that file's lowering
    /// actually ran with them.
    lower_core: []const bool,
    lower_platform: []const bool,
    /// Modules an earlier phase already reported on (`Check.Options.quiet`),
    /// per graph module. Such a module's interface is a guess the parser or
    /// the resolver made, so it has no well-founded key.
    reported: []const bool,
    embedded: []const Asset,
    io: Io,
};

/// Every module's `own_terms` blob and cacheability bit, plus — while the core
/// term is still `core_epoch` over core's KEYS — every CORE module's finished
/// key and the epoch itself.
///
/// **Why core stays here and the rest does not.** A core module imports nothing
/// outside core, so `graph.order` restricted to core is a valid order for it
/// and a serial pass can finish every core key in one sweep. An APP module's
/// key needs its imports' contributions, and from M4-3 on an import contributes
/// something that exists only after it has been checked — so that half moves to
/// the DAG, where the schedule already guarantees an import has finished before
/// its importer is released.
///
/// `scratch` is reset by the caller.
pub fn build(
    gpa: Allocator,
    scratch: Allocator,
    graph: *const Graph,
    store: *const SourceStore,
    artifacts: *const Artifacts,
    interner: *const InternPool.Global,
    options: Options,
) Allocator.Error!Keys {
    const n = graph.count();
    var out: Keys = .{
        .keys = try gpa.alloc(Key, n),
        .uncacheable = try gpa.alloc(bool, n),
        .own = try gpa.alloc([]u8, n),
    };
    errdefer out.deinit(gpa);
    @memset(out.keys, none);
    @memset(out.uncacheable, true);
    @memset(out.own, &.{});

    // Every module's own terms, and its cacheability. Uncacheability
    // propagates along import edges and needs no key at all, so it stays
    // serial: `graph.order` visits an import before its importer.
    for (graph.order) |m| {
        out.own[m.int()] = try ownTermsOf(gpa, scratch, graph, store, artifacts, interner, options, m);
        var cacheable = !graph.isPoisoned(m) and
            !(m.int() < options.reported.len and options.reported[m.int()]);
        for (graph.dependencies(m)) |dep| {
            if (dep == m) continue;
            if (!out.isCacheable(dep)) cacheable = false;
        }
        out.uncacheable[m.int()] = !cacheable;
    }

    // Core's keys, and the epoch over them.
    var core_entries: std.ArrayList(CoreEntry) = .empty;
    defer core_entries.deinit(scratch);
    for (graph.order) |m| {
        if (graph.module(m).package != .core) continue;
        var imports: std.ArrayList(Import) = .empty;
        defer imports.deinit(scratch);
        for (graph.dependencies(m)) |dep| {
            if (dep == m) continue;
            try imports.append(scratch, .{
                .package = graph.module(dep).package,
                .name = interner.slice(graph.moduleName(dep)),
                .key = out.of(dep),
            });
        }
        sortImports(&imports);
        // A core module's own `core_epoch` term is `none` by definition.
        out.keys[m.int()] = try finish(scratch, out.own[m.int()], none, imports.items);
        try core_entries.append(scratch, .{
            .name = interner.slice(graph.moduleName(m)),
            .key = out.keys[m.int()],
        });
    }
    std.mem.sort(CoreEntry, core_entries.items, {}, coreEntryLessThan);
    out.core_epoch = try coreEpoch(scratch, core_entries.items);
    return out;
}

/// Sort by `(package, name)` and drop duplicates, in place.
///
/// `graph.dependencies` is already deduplicated per module, but the sort is
/// what a duplicate would have to survive, so the removal is here.
pub fn sortImports(imports: *std.ArrayList(Import)) void {
    std.mem.sort(Import, imports.items, {}, importLessThan);
    var unique: usize = 0;
    for (imports.items, 0..) |i, at| {
        if (at != 0 and sameImport(imports.items[unique - 1], i)) continue;
        imports.items[unique] = i;
        unique += 1;
    }
    imports.shrinkRetainingCapacity(unique);
}

fn coreEntryLessThan(_: void, a: CoreEntry, b: CoreEntry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn ownTermsOf(
    gpa: Allocator,
    scratch: Allocator,
    graph: *const Graph,
    store: *const SourceStore,
    artifacts: *const Artifacts,
    interner: *const InternPool.Global,
    options: Options,
    m: Graph.Index,
) Allocator.Error![]u8 {
    const file = graph.moduleFile(m);
    const module = graph.module(m);

    var options_buffer: [options_buffer_len]u8 = undefined;
    const option_string = writeOptions(&options_buffer, .{
        .core = file.int() < options.lower_core.len and options.lower_core[file.int()],
        .platform = file.int() < options.lower_platform.len and options.lower_platform[file.int()],
        .informational = options.informational,
        .pattern_budget = options.pattern_budget,
    });

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    try writeOwn(gpa, &bytes, .{
        .build_id = options.build_id,
        .package = module.package,
        .name = interner.slice(module.name),
        .options = option_string,
        .source_hash = iface_bytes.hash(store.bytes(file)),
        .sibling_hash = try siblingHash(scratch, store, artifacts, options, file),
    });
    return bytes.toOwnedSlice(gpa);
}

fn importLessThan(_: void, a: Import, b: Import) bool {
    if (a.package != b.package) return @intFromEnum(a.package) < @intFromEnum(b.package);
    return std.mem.lessThan(u8, a.name, b.name);
}

fn sameImport(a: Import, b: Import) bool {
    return a.package == b.package and std.mem.eql(u8, a.name, b.name);
}

/// The content hash of a module's sibling JavaScript (`boundary.md` §7.3), or
/// `none` when it declares no `foreign` value.
///
/// **`foreign_value`, not `foreign_type`**, exactly as `Emit.checkSiblings`
/// decides it: a module of `foreign type` declarations alone binds to no
/// JavaScript and has no sibling to read.
///
/// A sibling the compiler carries is read from the embedded table; anything
/// else is read from disk, and a sibling that cannot be read hashes as the
/// empty string rather than failing the run. That is conservative in the
/// right direction: `boundary.md` §4's `foreign_sibling_missing` is an error
/// of the build, so a module whose sibling is unreadable never gets an entry
/// anyway.
fn siblingHash(
    scratch: Allocator,
    store: *const SourceStore,
    artifacts: *const Artifacts,
    options: Options,
    file: SourceStore.Index,
) Allocator.Error!Key {
    const bir = artifacts.bir(file);
    var declares = false;
    for (bir.decls) |d| {
        if (d.kind == .foreign_value) {
            declares = true;
            break;
        }
    }
    if (!declares) return none;

    const source_path = store.path(file);
    if (!std.mem.endsWith(u8, source_path, SourceStore.extension)) return none;
    const stem = source_path[0 .. source_path.len - SourceStore.extension.len];
    const sibling_path = try std.fmt.allocPrint(scratch, "{s}.js", .{stem});
    defer scratch.free(sibling_path);

    for (options.embedded) |asset| {
        if (std.mem.eql(u8, asset.path, sibling_path)) return iface_bytes.hash(asset.bytes);
    }
    const bytes = Io.Dir.cwd().readFileAlloc(options.io, sibling_path, scratch, .limited(max_sibling_bytes)) catch
        return iface_bytes.hash("");
    defer scratch.free(bytes);
    return iface_bytes.hash(bytes);
}

/// The same bound `js/Emit.zig` reads a sibling with.
const max_sibling_bytes = 16 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const sample_build_id: [16]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };

/// `a`'s key differs from `b`'s. Named rather than inlined so the failure
/// message says which pair, and so the two keys are values rather than
/// temporaries taken by reference.
fn expectDifferentKeys(a: Terms, b: Terms) !void {
    const ka = try compute(testing.allocator, a);
    const kb = try compute(testing.allocator, b);
    if (std.mem.eql(u8, &ka, &kb)) {
        std.debug.print("two different inputs produced the same key {s}\n", .{&hex(ka)});
        return error.KeysCollided;
    }
}

fn sampleTerms() Terms {
    return .{
        .build_id = sample_build_id,
        .package = .app,
        .name = "Mid",
        .options = "core=0;platform=0;informational=1;pattern_budget=1000000",
        .source_hash = @splat(0xAA),
    };
}

test "the option string is the four flags and nothing else, and it fits its buffer" {
    var buffer: [options_buffer_len]u8 = undefined;
    try testing.expectEqualStrings(
        "core=0;platform=0;informational=1;pattern_budget=1000000",
        writeOptions(&buffer, .{ .core = false, .platform = false, .informational = true, .pattern_budget = 1_000_000 }),
    );
    try testing.expectEqualStrings(
        "core=1;platform=1;informational=0;pattern_budget=4294967295",
        writeOptions(&buffer, .{ .core = true, .platform = true, .informational = false, .pattern_budget = std.math.maxInt(u32) }),
    );
}

test "the key's byte string is the recipe, field by field" {
    // The BYTES and not only the digest: a recipe that dropped a term would
    // still produce 16 plausible bytes, and a test that compared only keys
    // would pass on every input that happened not to collide.
    const gpa = testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    var t = sampleTerms();
    t.sibling_hash = @splat(0xBB);
    t.core_epoch = @splat(0xCC);
    t.imports = &.{
        .{ .package = .app, .name = "Leaf", .key = @splat(0xDD) },
    };
    try writeBytes(gpa, &bytes, t);

    var at: usize = 0;
    try testing.expectEqualStrings(magic, bytes.items[at..][0..8]);
    at += 8;
    try testing.expectEqual(key_version, std.mem.readInt(u32, bytes.items[at..][0..4], .little));
    at += 4;
    try testing.expectEqualSlices(u8, &sample_build_id, bytes.items[at..][0..16]);
    at += 16;
    try testing.expectEqual(@as(u8, @intFromEnum(SourceStore.Package.app)), bytes.items[at]);
    at += 1;
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, bytes.items[at..][0..4], .little));
    at += 4;
    try testing.expectEqualStrings("Mid", bytes.items[at..][0..3]);
    at += 3;
    const options_len = std.mem.readInt(u32, bytes.items[at..][0..4], .little);
    at += 4;
    try testing.expectEqualStrings(t.options, bytes.items[at..][0..options_len]);
    at += options_len;
    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(0xAA)), bytes.items[at..][0..16]);
    at += 16;
    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(0xBB)), bytes.items[at..][0..16]);
    at += 16;
    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(0xCC)), bytes.items[at..][0..16]);
    at += 16;
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, bytes.items[at..][0..4], .little));
    at += 4;
    try testing.expectEqual(@as(u8, @intFromEnum(SourceStore.Package.app)), bytes.items[at]);
    at += 1;
    try testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, bytes.items[at..][0..4], .little));
    at += 4;
    try testing.expectEqualStrings("Leaf", bytes.items[at..][0..4]);
    at += 4;
    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(0xDD)), bytes.items[at..][0..16]);
    at += 16;
    try testing.expectEqual(bytes.items.len, at);
}

test "every term of the recipe moves the key" {
    // The test that would catch a term the writer forgot: change one field
    // at a time and require a different key each time. A recipe missing a
    // term is a stale entry, which is a wrong answer that depends on
    // history — the worst kind, because it is unreproducible from a clean
    // checkout.
    {
        var t = sampleTerms();
        t.build_id = @splat(0);
        try expectDifferentKeys(sampleTerms(), t);
    }
    {
        var t = sampleTerms();
        t.package = .core;
        try expectDifferentKeys(sampleTerms(), t);
    }
    {
        var t = sampleTerms();
        t.name = "Mid2";
        try expectDifferentKeys(sampleTerms(), t);
    }
    {
        var t = sampleTerms();
        t.options = "core=1;platform=0;informational=1;pattern_budget=1000000";
        try expectDifferentKeys(sampleTerms(), t);
    }
    {
        var t = sampleTerms();
        t.source_hash = @splat(0xAB);
        try expectDifferentKeys(sampleTerms(), t);
    }
    {
        var t = sampleTerms();
        t.sibling_hash = @splat(1);
        try expectDifferentKeys(sampleTerms(), t);
    }
    {
        var t = sampleTerms();
        t.core_epoch = @splat(1);
        try expectDifferentKeys(sampleTerms(), t);
    }
    {
        var with_import = sampleTerms();
        with_import.imports = &.{.{ .package = .app, .name = "Leaf", .key = none }};
        try expectDifferentKeys(sampleTerms(), with_import);

        // An import whose KEY moved moves the importer's key, which is the
        // whole inductive claim.
        var moved_key = sampleTerms();
        moved_key.imports = &.{.{ .package = .app, .name = "Leaf", .key = @splat(1) }};
        try expectDifferentKeys(with_import, moved_key);
        // As does one whose NAME moved, at the same key.
        var moved_name = sampleTerms();
        moved_name.imports = &.{.{ .package = .app, .name = "Leaves", .key = @splat(1) }};
        try expectDifferentKeys(moved_key, moved_name);
        // As does one whose PACKAGE moved.
        var moved_package = sampleTerms();
        moved_package.imports = &.{.{ .package = .core, .name = "Leaf", .key = @splat(1) }};
        try expectDifferentKeys(moved_key, moved_package);
    }
}

test "the recipe is length-prefixed, so two different splits cannot agree" {
    // Without the length words, `name = "AB", options = "C"` and
    // `name = "A", options = "BC"` would hash the same bytes — and two
    // modules would share one cache entry.
    var a = sampleTerms();
    a.name = "AB";
    a.options = "C";
    var b = sampleTerms();
    b.name = "A";
    b.options = "BC";
    try expectDifferentKeys(a, b);

    // The same for two imports whose names concatenate alike.
    var c = sampleTerms();
    c.imports = &.{
        .{ .package = .app, .name = "AB", .key = none },
        .{ .package = .app, .name = "C", .key = none },
    };
    var d = sampleTerms();
    d.imports = &.{
        .{ .package = .app, .name = "A", .key = none },
        .{ .package = .app, .name = "BC", .key = none },
    };
    try expectDifferentKeys(c, d);
}

test "the key's byte string is its own terms followed by the rest, exactly" {
    // What makes finishing a key on the DAG the SAME key the serial pass
    // produced: `writeBytes` is `writeOwn` then `writeRest`, so the split is a
    // split of one byte string and not a second recipe. A commit that let the
    // two drift would be a cache that misses everything, or worse.
    const gpa = testing.allocator;
    var t = sampleTerms();
    t.sibling_hash = @splat(0xBB);
    t.core_epoch = @splat(0xCC);
    t.imports = &.{.{ .package = .app, .name = "Leaf", .key = @splat(0xDD) }};

    var whole: std.ArrayList(u8) = .empty;
    defer whole.deinit(gpa);
    try writeBytes(gpa, &whole, t);

    var own: std.ArrayList(u8) = .empty;
    defer own.deinit(gpa);
    try writeOwn(gpa, &own, t);
    var split: std.ArrayList(u8) = .empty;
    defer split.deinit(gpa);
    try split.appendSlice(gpa, own.items);
    try writeRest(gpa, &split, t.core_epoch, t.imports);

    try testing.expectEqualSlices(u8, whole.items, split.items);
    try testing.expectEqual(try compute(gpa, t), try finish(gpa, own.items, t.core_epoch, t.imports));
}

test "the key is a pure function: the same terms twice give the same bytes" {
    const gpa = testing.allocator;
    try testing.expectEqual(try compute(gpa, sampleTerms()), try compute(gpa, sampleTerms()));
}

test "the core epoch is a function of the sorted list, and empty core is `none`" {
    const gpa = testing.allocator;
    try testing.expectEqual(none, try coreEpoch(gpa, &.{}));
    const a: []const CoreEntry = &.{
        .{ .name = "Basics", .key = @splat(1) },
        .{ .name = "List", .key = @splat(2) },
    };
    const first = try coreEpoch(gpa, a);
    try testing.expectEqual(first, try coreEpoch(gpa, a));
    // One core module's key moving moves the epoch, which is what makes
    // "core changed" reach every module in the project.
    const moved = try coreEpoch(gpa, &.{
        .{ .name = "Basics", .key = @splat(1) },
        .{ .name = "List", .key = @splat(3) },
    });
    try testing.expect(!std.mem.eql(u8, &first, &moved));
    // And a core module appearing moves it too.
    const grown = try coreEpoch(gpa, &.{
        .{ .name = "Basics", .key = @splat(1) },
        .{ .name = "List", .key = @splat(2) },
        .{ .name = "Set", .key = @splat(2) },
    });
    try testing.expect(!std.mem.eql(u8, &first, &grown));
}
