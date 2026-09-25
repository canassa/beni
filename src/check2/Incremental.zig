//! The cutoff protocol, per module (`fast-compiler.md` §8, `plans/m4-3.md`;
//! checker.md §7): finish the key and load the entry (`claim`), compute
//! `--cutoff-compare`'s transitive key (`compareKey`), install a HIT
//! (`install`), assert the covered-read self-check (`verifyReads`), publish the
//! interface hash and dependency digest (`publish`), and close `core_surface`
//! (`closeCoreSurface`).
//!
//! Moved verbatim out of `src/check/Check.zig`'s `Driver` by R4a
//! (checker-v2.md §19, §19.1). Each function takes the `Driver` as its first
//! parameter and `Driver.zig` names it as a method, so the schedule calls
//! `d.claim(…)` exactly as before. The checker id is part of the key through
//! the own-terms blob `cache/Key.zig` builds (checker-v2.md §14.3), not here.

const std = @import("std");
const Arena = @import("../Arena.zig");
const Graph = @import("../resolve/Graph.zig");
const iface_bytes = @import("../resolve/iface_bytes.zig");
const Schemes = @import("../check/Schemes.zig");
const TypeStore = @import("../check/TypeStore.zig");
const reads = @import("../check/reads.zig");
const dispatch_bytes = @import("../cache/dispatch_bytes.zig");
const CacheEntry = @import("../cache/Entry.zig");
const Key = @import("../cache/Key.zig");
const Digest = @import("../cache/Digest.zig");
const Check = @import("Check.zig");
const Driver = @import("Driver.zig");

const Error = Check.Error;
const Var = Check.Var;

fn digestImportLessThan(_: void, a: Digest.Import, b: Digest.Import) bool {
    if (a.package != b.package) return @intFromEnum(a.package) < @intFromEnum(b.package);
    return std.mem.lessThan(u8, a.name, b.name);
}

fn sameDigestImport(a: Digest.Import, b: Digest.Import) bool {
    return a.package == b.package and std.mem.eql(u8, a.name, b.name);
}

fn coreEntryLessThan(_: void, a: Digest.CoreEntry, b: Digest.CoreEntry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn oldCoreEntryLessThan(_: void, a: Key.CoreEntry, b: Key.CoreEntry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Compute `core_surface` once, the moment the last core module has
/// published. Called from `finish` under the lock on the parallel path and
/// straight after each module on the serial one.
pub fn closeCoreSurface(d: *Driver, scratch: *Arena) Error!void {
    const cutoff = d.options.cutoff orelse return;
    if (d.core_pending != 0) return;
    if (!std.mem.eql(u8, &cutoff.core_surface, &Digest.none)) return;
    var entries: std.ArrayList(Digest.CoreEntry) = .empty;
    defer entries.deinit(scratch.allocator());
    for (0..d.graph.count()) |i| {
        const m: Graph.Index = @enumFromInt(i);
        if (d.graph.module(m).package != .core) continue;
        try entries.append(scratch.allocator(), .{
            .name = d.interner.slice(d.graph.moduleName(m)),
            .iface_hash = cutoff.iface_hash[i],
            .digest = cutoff.digest[i],
        });
    }
    std.mem.sort(Digest.CoreEntry, entries.items, {}, coreEntryLessThan);
    cutoff.core_surface = try Digest.coreSurface(scratch.allocator(), entries.items);

    if (cutoff.compare.len == 0) return;
    var old: std.ArrayList(Key.CoreEntry) = .empty;
    defer old.deinit(scratch.allocator());
    for (0..d.graph.count()) |i| {
        const m: Graph.Index = @enumFromInt(i);
        if (d.graph.module(m).package != .core) continue;
        try old.append(scratch.allocator(), .{
            .name = d.interner.slice(d.graph.moduleName(m)),
            .key = cutoff.compare[i],
        });
    }
    std.mem.sort(Key.CoreEntry, old.items, {}, oldCoreEntryLessThan);
    cutoff.core_epoch = try Key.coreEpoch(scratch.allocator(), old.items);
}

/// Finish `m`'s key and try to load its entry, on this worker.
pub fn claim(d: *Driver, m: Graph.Index, scratch: *Arena, tid: u32) Error!void {
    const cutoff = d.options.cutoff orelse return;
    // `cache_load` is per MODULE from here on, not one serial pass: it is
    // the first time reading an entry is parallel at all, and "what did
    // the load cost once it was on the DAG?" is a number the slice owes.
    const token = if (d.options.profile) |p| p.begin() else null;
    defer if (d.options.profile) |p| {
        p.end(tid, token.?, .cache_load, @intFromEnum(d.graph.moduleFile(m)), 0);
    };
    var pairs: std.ArrayList(Key.ImportPair) = .empty;
    defer pairs.deinit(scratch.allocator());
    for (d.graph.dependencies(m)) |dep| {
        if (dep == m) continue;
        try pairs.append(scratch.allocator(), .{
            .package = d.graph.module(dep).package,
            .name = d.interner.slice(d.graph.moduleName(dep)),
            .iface_hash = cutoff.iface_hash[dep.int()],
            .digest = cutoff.digest[dep.int()],
        });
    }
    Key.sortPairs(&pairs);
    // A CORE module's own core term is `none` by definition: core is not a
    // dependency of itself, exactly as `core_epoch` was not.
    const surface = if (d.graph.module(m).package == .core) Digest.none else cutoff.core_surface;
    cutoff.keys.set(m, try Key.finish(
        scratch.allocator(),
        cutoff.keys.ownTerms(m),
        surface,
        pairs.items,
    ));
    try d.compareKey(m, scratch);
    const dir = cutoff.dir orelse return;
    if (!cutoff.keys.isCacheable(m)) return;
    if (m.int() >= d.options.cached.len) return;
    d.options.cached[m.int()] = try CacheEntry.loadFinding(
        d.gpa,
        dir,
        cutoff.keys.of(m),
        cutoff.interner,
        &d.interfaces[m.int()],
    );
    cutoff.hit[m.int()] = d.options.cached[m.int()] != null;
}

/// `--cutoff-compare`: `m`'s key under the TRANSITIVE recipe M4-1 and M4-2
/// used, beside the cutoff key the run is now driven by.
///
/// It is itself inductive — over `compare`, not over the keys in use — so
/// it reproduces the old recipe exactly, including its `core_epoch` term.
/// Nothing is ever stored under it: it exists for the one invariant, **old
/// key equal ⇒ new key equal**, which needs both keys of one run.
pub fn compareKey(d: *Driver, m: Graph.Index, scratch: *Arena) Error!void {
    const cutoff = d.options.cutoff orelse return;
    if (m.int() >= cutoff.compare.len) return;
    var imports: std.ArrayList(Key.Import) = .empty;
    defer imports.deinit(scratch.allocator());
    for (d.graph.dependencies(m)) |dep| {
        if (dep == m) continue;
        try imports.append(scratch.allocator(), .{
            .package = d.graph.module(dep).package,
            .name = d.interner.slice(d.graph.moduleName(dep)),
            .key = cutoff.compare[dep.int()],
        });
    }
    Key.sortImports(&imports);
    const epoch = if (d.graph.module(m).package == .core) Key.none else cutoff.core_epoch;
    cutoff.compare[m.int()] = try Key.finishTransitive(
        scratch.allocator(),
        cutoff.keys.ownTerms(m),
        epoch,
        imports.items,
    );
}

/// Publish `m`'s interface hash and dependency digest, for its dependents.
pub fn publish(d: *Driver, m: Graph.Index, scratch: *Arena, tid: u32) Error!void {
    const cutoff = d.options.cutoff orelse return;
    // Per MODULE, on the worker that produced it. `dep_digest` is
    // `cache_key`'s twin and is in the trace for the same reason: it runs
    // on every checking run, cache directory or not.
    const token = if (d.options.profile) |p| p.begin() else null;
    defer if (d.options.profile) |p| {
        p.end(tid, token.?, .dep_digest, @intFromEnum(d.graph.moduleFile(m)), 0);
    };
    const record = try iface_bytes.write(scratch.allocator(), &d.interfaces[m.int()], d.interner);
    cutoff.iface_hash[m.int()] = iface_bytes.hash(record);

    var imports: std.ArrayList(Digest.Import) = .empty;
    defer imports.deinit(scratch.allocator());
    for (d.graph.dependencies(m)) |dep| {
        if (dep == m) continue;
        try imports.append(scratch.allocator(), .{
            .package = d.graph.module(dep).package,
            .name = d.interner.slice(d.graph.moduleName(dep)),
            .iface_hash = cutoff.iface_hash[dep.int()],
            .digest = cutoff.digest[dep.int()],
        });
    }
    std.mem.sort(Digest.Import, imports.items, {}, digestImportLessThan);
    var unique: usize = 0;
    for (imports.items, 0..) |i, at| {
        if (at != 0 and sameDigestImport(imports.items[unique - 1], i)) continue;
        imports.items[unique] = i;
        unique += 1;
    }
    imports.shrinkRetainingCapacity(unique);

    cutoff.digest[m.int()] = try Digest.collect(scratch.allocator(), .{
        .graph = d.graph,
        .artifacts = d.artifacts,
        .types = d.types,
        .interfaces = d.interfaces,
        .dispatch = d.dispatch,
        .plans = d.plans,
        .interner = d.interner,
    }, m, imports.items);
}

/// The covered-read self-check (`reads.zig`, `plans/m4-3.md` §9 M3-a).
///
/// A module that read a fact about a module its key cannot see move is an
/// incomplete enumeration, which is a stale answer waiting for the right
/// edit sequence. It is `internal` rather than a panic for
/// `fast-compiler.md` §5's reason — the build says what it could not do —
/// and it is compiled away outside a safe build.
pub fn verifyReads(d: *Driver, m: Graph.Index, recorder: *const reads.Recorder) Error!void {
    if (!reads.enabled) return;
    const bad = reads.firstUncovered(recorder, &d.coverage) orelse return;
    const message = try std.fmt.allocPrint(
        d.gpa,
        \\Something went wrong inside the compiler here: checking `{s}` read a fact of kind `{t}` about `{s}`, which its cache key does not cover.
        \\
        \\This is a bug in beni, not in your code. Please report it.
        \\
    ,
        .{
            d.interner.slice(d.graph.moduleName(m)),
            bad.kind,
            d.interner.slice(d.graph.moduleName(bad.read)),
        },
    );
    errdefer d.gpa.free(message);
    try d.per_module[m.int()].append(d.gpa, .{
        .code = .internal,
        .module = m,
        .region = @enumFromInt(0),
        .message = message,
    });
}

/// A HIT: install the entry instead of checking the module
/// (`fast-compiler.md` §8's *What a hit skips, and what still runs*).
///
/// `constrain`, `solve`, `exhaustive`, `deriveDeclaredTypes`, the binding
/// groups, `fillInterface`, `fillCtorTerms`, `Schemes.Writer.attach`,
/// `dispatch.finish` and `Cycles.run` never run for this module. What
/// does run is exactly four things, and this function is all four.
///
/// It runs on the DAG, on whichever worker claimed the module, for one
/// reason: `Types` is built by then, and every capability write is to
/// this module's own dense range before dependents are released. That
/// is what makes installation as safe here as a check is.
pub fn install(d: *Driver, m: Graph.Index, loaded: *CacheEntry.Loaded) Error!void {
    const gpa = d.gpa;

    // 1. The record replaces the shell WHOLESALE, which is why
    //    `Schemes.Writer.attach`'s non-idempotence does not bite —
    //    nothing re-attaches to a loaded record — and it is the same
    //    move `--roundtrip-interfaces` already makes.
    d.interfaces[m.int()].deinit(gpa);
    d.interfaces[m.int()] = loaded.record;
    loaded.record = .empty;

    // 2. The dispatch table, once its two reference tables are this
    //    session's ids.
    dispatch_bytes.resolve(&loaded.sidecar, d.graph, d.types);
    d.dispatch[m.int()].deinit(gpa);
    d.dispatch[m.int()] = loaded.sidecar.table;
    loaded.sidecar.table = .empty;
    d.plans[m.int()].deinit(gpa);
    d.plans[m.int()] = loaded.plan;
    loaded.plan = .empty;

    for (d.plans[m.int()].definitions) |definition| {
        d.types.restoreSchemaPropertyBits(
            d.types.ofSchemaDecl(m, definition.decl, .type),
            definition.program_properties,
        );
        d.types.restoreSchemaPropertyBits(
            d.types.ofSchemaDecl(m, definition.decl, .encoded),
            definition.encoded_properties,
        );
    }

    // Translate type references before rebuilding the schema endpoint
    // properties below; every imported term reader indexes this table.
    const ref_ids = &d.types.ref_ids[m.int()];
    gpa.free(ref_ids.*);
    ref_ids.* = try d.types.resolveRefs(gpa, &d.interfaces[m.int()], d.graph);

    // A cache entry stores the public schemes that define this
    // module's dispatch boundaries, while the two answer bits are
    // deliberately session-local TypeStore facts. Rebuild them before
    // `finish` releases dependents, using exactly the same completed
    // schemes as a cold check. This temporary store dies here; only the
    // module-owned dense type range is published.
    {
        const bir = d.artifacts.bir(d.graph.moduleFile(m));
        const iface = &d.interfaces[m.int()];
        const provenance = &d.provenance[m.int()];
        var store: TypeStore = .init(std.heap.page_allocator);
        defer store.deinit();
        try store.reserve(iface.terms.len + iface.schemes.len * 2 + 16, iface.extra.len + 16);
        const schemes = try gpa.alloc(Var.Optional, bir.decls.len);
        defer gpa.free(schemes);
        @memset(schemes, .none);
        for (iface.values, 0..) |value, i| {
            const decl = provenance.valueDecl(i) orelse continue;
            if (decl.int() >= schemes.len or value.scheme == .none) continue;
            const root = try Schemes.instantiate(
                iface,
                ref_ids.*,
                &store,
                @intFromEnum(value.scheme),
                TypeStore.generalized,
                gpa,
                null,
            );
            schemes[decl.int()] = root.toOptional();
        }
        try d.types.settleDispatchCapabilities(gpa, m, d.graph, d.artifacts, &store, schemes);
        d.types.restoreDerivedCapabilities(m, &d.dispatch[m.int()]);
    }

    // 3. The diagnostics, replayed. The message is the prose the
    //    checker rendered when it wrote the entry; the SPAN is not
    //    stored and is recomputed from this build's `SourceStore`, so a
    //    module that moved without changing its name still points at
    //    the right file.
    const list = &d.per_module[m.int()];
    try list.ensureUnusedCapacity(gpa, loaded.diagnostics.len);
    for (loaded.diagnostics) |row| {
        const message = try gpa.dupe(u8, row.message);
        errdefer gpa.free(message);
        list.appendAssumeCapacity(.{
            .code = @enumFromInt(row.code),
            .module = m,
            .region = @enumFromInt(row.region),
            .severity = @enumFromInt(row.severity),
            .token = if (row.has_token) row.token else null,
            .message = message,
        });
    }

    // 4. `Types.ref_ids`, which is not part of the record and is
    //    recomputed once per module per build — here for the same
    //    reason `fillInterface` does it for a miss, and against
    //    whichever record ended up in the slot.
    // `ref_ids` was filled above before schema endpoint restoration.
}
