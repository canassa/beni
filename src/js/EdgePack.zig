//! The reachability edge lists of the modules the binary carries, made once
//! when beni is built and carried in the checked core (`fast-compiler.md`
//! §8, *The checked core, embedded*, amended 2026-10-15; `backend.md` §9,
//! *Incrementality (M4) and chunking (§10)*).
//!
//! **An edge list is a function of its module's check and of two build
//! options.** `Reach.Builder.module` reads the module's `Bir` and dispatch
//! table, the interfaces, provenance and types of what it names, and of
//! the options only `--release` (which arm of an `if Js.development` it
//! drops) and `--schema-library` (what a schema member's workers call). It
//! reads no root. The module key is the whole input of the check, so a
//! row is keyed by that key and the two options, and a build whose module
//! has that key reads the row instead of building the list.
//!
//! **A node names its module by package and dotted name**, never by
//! `Graph.Index`: an index depends on which modules a build holds, and the
//! maker's graph holds every module of the core where a program's holds
//! the ones it imports. A row starts with the table of the modules its
//! nodes name, and a build resolves each with `Graph.find`.
//!
//! **A target in a module the build does not hold is dropped.** A
//! module's edges reach four kinds of target:
//!
//! 1. what its instructions and dispatch table name, which is always in a
//!    module it imports, so in every build that holds it;
//! 2. `String.compare` and `core/List`'s helpers, which lowering calls
//!    with no reference of the module's own (`Builder.string_compare`,
//!    `listEdges`);
//! 3. `Task.andThen` and `Task.isWaiting`, which a body that may suspend
//!    calls (`effectEdges`);
//! 4. the `core/Schema` values a schema member's code calls
//!    (`memberEdges`).
//!
//! The last three can name a core module the module does not import. The
//! builder finds each of them by name in the build's graph and adds no
//! edge when the module is not there, which is the drop. That is exact only
//! because **the maker's graph holds every module a build's graph can
//! hold**: `Session.isLazy` is false in a run that makes a pack, so each
//! maker run reads every core module and every module of its chain, and
//! core's rows come from the run that holds core alone. A change that
//! makes the maker's graph smaller breaks this rule.
//!
//! **A row that cannot be used is not used.** Another version, a length or
//! an order that does not fit the module, a node out of its module's
//! range, a chain out of the row's, or a guard in a module the build does
//! not hold: the build builds the list as before.
//!
//! ```
//! version: u32                     `version`
//! modules: u32, then per module    package: u8, name_len: u32, name
//! decl_at, derived_at, twin_at, schema_at
//!                                  each len: u32, then len u32 words
//! decl_targets, derived_targets, twin_targets, schema_targets
//!                                  each len: u32, then per target
//!                                  module, kind, index, chain: u32 each
//! chains: u32, then per chain      parent, start, end: u32 each
//! chain_ctors: u32, then per node  module, kind, index: u32 each
//! ```
//!
//! Little-endian by definition, like every byte format of the cache.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Graph = @import("../resolve/Graph.zig");
const InternPool = @import("../InternPool.zig");
const Session = @import("../Session.zig");
const SourceStore = @import("../SourceStore.zig");
const Key = @import("../cache/Key.zig");
const iface_bytes = @import("../resolve/iface_bytes.zig");
const Reach = @import("Reach.zig");
const SchemaGraph = @import("SchemaGraph.zig");

const magic = "BENIEDGE";
pub const version: u32 = 1;

/// The build options an edge list depends on.
pub const Options = struct {
    release: bool,
    schema_library: bool,
};

/// Every combination of `Options`: the rows the maker writes per module.
pub const every_options = [_]Options{
    .{ .release = false, .schema_library = false },
    .{ .release = true, .schema_library = false },
    .{ .release = false, .schema_library = true },
    .{ .release = true, .schema_library = true },
};

/// The key of the row that holds the edge lists of the module whose key is
/// `module`, built with `options`.
pub fn key(module: Key.Key, options: Options) Key.Key {
    var bytes: [magic.len + 4 + 16 + 1]u8 = undefined;
    @memcpy(bytes[0..magic.len], magic);
    std.mem.writeInt(u32, bytes[magic.len..][0..4], version, .little);
    @memcpy(bytes[magic.len + 4 ..][0..16], &module);
    bytes[magic.len + 20] = @as(u8, @intFromBool(options.release)) | (@as(u8, @intFromBool(options.schema_library)) << 1);
    return iface_bytes.hash(&bytes);
}

/// What `Reach.Builder` reads of a checked session, with `options`. The
/// roots are the walk's and are left empty.
pub fn input(scratch: Allocator, session: *const Session, options: Options) Allocator.Error!Reach.Input {
    const count = session.graph.count();
    const birs = try scratch.alloc(*const Bir, count);
    const tables = try scratch.alloc(*const Dispatch, count);
    for (birs, tables, 0..) |*b, *d, i| {
        const m: Graph.Index = @fromBackingInt(@intCast(@as(u32, @intCast(i))));
        b.* = session.artifacts.bir(session.graph.moduleFile(m));
        d.* = if (i < session.checked.dispatch.len) &session.checked.dispatch[i] else &Dispatch.empty;
    }
    return .{
        .graph = &session.graph,
        .store = &session.store,
        .birs = birs,
        .dispatch = tables,
        .interfaces = session.resolution.interfaces,
        .provenance = session.resolution.provenance,
        .types = &session.checked.types,
        .interner = &session.interner,
        .release = options.release,
        .vocabulary = session.graph.markup.vocabulary,
        .plans = session.checked.plans,
        .schema_library = options.schema_library,
    };
}

/// One module's edge lists as a row's bytes, gpa-owned.
pub fn encode(gpa: Allocator, edges: Reach.ModuleEdges, graph: *const Graph, interner: *const InternPool.Global) Allocator.Error![]u8 {
    // The modules the nodes name, in the order a node first names each.
    const slot_of = try gpa.alloc(u32, graph.count());
    defer gpa.free(slot_of);
    @memset(slot_of, no_slot);
    var modules: std.ArrayList(Graph.Index) = .empty;
    defer modules.deinit(gpa);
    for ([_][]const Reach.Target{ edges.decl_targets, edges.derived_targets, edges.twin_targets, edges.schema_targets }) |targets| {
        for (targets) |t| try slotOf(gpa, &modules, slot_of, t.node.module);
    }
    for (edges.chain_ctors) |n| try slotOf(gpa, &modules, slot_of, n.module);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try appendU32(gpa, &out, version);
    try appendU32(gpa, &out, @intCast(modules.items.len));
    for (modules.items) |m| {
        const name = interner.slice(graph.moduleName(m));
        try out.append(gpa, @backingInt(graph.modulePackage(m)));
        try appendU32(gpa, &out, @intCast(name.len));
        try out.appendSlice(gpa, name);
    }
    for ([_][]const u32{ edges.decl_at, edges.derived_at, edges.twin_at, edges.schema_at }) |at| {
        try appendU32(gpa, &out, @intCast(at.len));
        for (at) |word| try appendU32(gpa, &out, word);
    }
    for ([_][]const Reach.Target{ edges.decl_targets, edges.derived_targets, edges.twin_targets, edges.schema_targets }) |targets| {
        try appendU32(gpa, &out, @intCast(targets.len));
        for (targets) |t| {
            try appendNode(gpa, &out, slot_of, t.node);
            try appendU32(gpa, &out, t.chain);
        }
    }
    try appendU32(gpa, &out, @intCast(edges.chains.len));
    for (edges.chains) |c| {
        try appendU32(gpa, &out, c.parent);
        try appendU32(gpa, &out, c.start);
        try appendU32(gpa, &out, c.end);
    }
    try appendU32(gpa, &out, @intCast(edges.chain_ctors.len));
    for (edges.chain_ctors) |n| try appendNode(gpa, &out, slot_of, n);
    return out.toOwnedSlice(gpa);
}

const no_slot = std.math.maxInt(u32);

fn slotOf(gpa: Allocator, modules: *std.ArrayList(Graph.Index), slot_of: []u32, m: Graph.Index) Allocator.Error!void {
    if (slot_of[m.int()] != no_slot) return;
    slot_of[m.int()] = @intCast(modules.items.len);
    try modules.append(gpa, m);
}

fn appendNode(gpa: Allocator, out: *std.ArrayList(u8), slot_of: []const u32, n: Reach.Node) Allocator.Error!void {
    try appendU32(gpa, out, slot_of[n.module.int()]);
    try appendU32(gpa, out, @backingInt(n.kind));
    try appendU32(gpa, out, n.index);
}

fn appendU32(gpa: Allocator, out: *std.ArrayList(u8), value: u32) Allocator.Error!void {
    var word: [4]u8 = undefined;
    std.mem.writeInt(u32, &word, value, .little);
    try out.appendSlice(gpa, &word);
}

/// A row's edge lists for the build `in` describes, in `arena`, or null when
/// the row cannot be used: malformed, of another `version`, a node out of
/// its module's range, or a guard in a module the build does not hold. The
/// caller then builds the lists.
pub fn decode(arena: Allocator, bytes: []const u8, in: Reach.Input, m: Graph.Index) Allocator.Error!?Reach.ModuleEdges {
    var r: Reader = .{ .bytes = bytes };
    if ((r.word() orelse return null) != version) return null;
    const interner = in.interner orelse return null;

    // Each slot's module in this build, or none when the build lacks it.
    const module_count = r.word() orelse return null;
    if (@as(u64, module_count) * 5 > r.rest()) return null;
    const modules = try arena.alloc(?Graph.Index, module_count);
    for (modules) |*slot| {
        const package = r.byte() orelse return null;
        if (package > @backingInt(SourceStore.Package.platform)) return null;
        const name = r.take(r.word() orelse return null) orelse return null;
        const symbol = interner.find(name);
        slot.* = if (symbol) |s| in.graph.find(@fromBackingInt(package), s) else null;
    }

    // One start per node of the module and one past the last, as
    // `Builder.module` makes them: declarations, derived rows, suspendable
    // bodies and schema members.
    const bir = in.birOf(m);
    const nodes = [4]usize{ bir.decls.len, in.dispatchOf(m).derived.len, bir.decls.len, bir.decls.len * SchemaGraph.Member.count };
    var ats: [4][]const u32 = undefined;
    for (&ats, nodes) |*at, n| {
        at.* = try r.words(arena) orelse return null;
        if (at.len != n + 1 or at.*[0] != 0) return null;
        for (at.*[0 .. at.len - 1], at.*[1..]) |a, b| if (a > b) return null;
    }
    var lists: [4][]Reach.Target = undefined;
    var starts: [4][]u32 = undefined;
    for (&lists, &starts, ats) |*list, *start, at| {
        const len = r.word() orelse return null;
        if (at[at.len - 1] != len) return null;
        if (@as(u64, len) * 16 > r.rest()) return null;
        var kept: std.ArrayList(Reach.Target) = try .initCapacity(arena, len);
        // Each node's start, moved down by the targets dropped before it.
        const moved = try arena.alloc(u32, at.len);
        var next: usize = 0;
        for (0..len) |t| {
            while (next < at.len and at[next] <= t) : (next += 1) moved[next] = @intCast(kept.items.len);
            const n = r.node(modules, in) orelse return null;
            const chain = r.word() orelse return null;
            const node = switch (n) {
                .absent => continue,
                .at => |node| node,
            };
            kept.appendAssumeCapacity(.{ .node = node, .chain = chain });
        }
        while (next < at.len) : (next += 1) moved[next] = @intCast(kept.items.len);
        list.* = kept.items;
        start.* = moved;
    }

    const chain_count = r.word() orelse return null;
    if (@as(u64, chain_count) * 12 > r.rest()) return null;
    const chains = try arena.alloc(Reach.Chain, chain_count);
    for (chains) |*c| c.* = .{
        .parent = r.word() orelse return null,
        .start = r.word() orelse return null,
        .end = r.word() orelse return null,
    };
    // Chain 0 is no chain; any other names one of the row's.
    for (lists) |list| for (list) |t| if (t.chain != 0 and t.chain >= chain_count) return null;
    for (chains) |c| if (c.parent != 0 and c.parent >= chain_count) return null;
    const ctor_count = r.word() orelse return null;
    if (@as(u64, ctor_count) * 12 > r.rest()) return null;
    const chain_ctors = try arena.alloc(Reach.Node, ctor_count);
    for (chain_ctors) |*slot| slot.* = switch (r.node(modules, in) orelse return null) {
        .absent => return null,
        .at => |node| node,
    };
    for (chains) |c| if (c.start > c.end or c.end > chain_ctors.len) return null;
    if (r.rest() != 0) return null;

    return .{
        .decl_at = starts[0],
        .decl_targets = lists[0],
        .derived_at = starts[1],
        .derived_targets = lists[1],
        .twin_at = starts[2],
        .twin_targets = lists[2],
        .schema_at = starts[3],
        .schema_targets = lists[3],
        .chains = chains,
        .chain_ctors = chain_ctors,
    };
}

const Read = union(enum) { absent, at: Reach.Node };

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn rest(r: *const Reader) usize {
        return r.bytes.len - r.at;
    }

    fn take(r: *Reader, n: usize) ?[]const u8 {
        if (n > r.rest()) return null;
        defer r.at += n;
        return r.bytes[r.at..][0..n];
    }

    fn byte(r: *Reader) ?u8 {
        const b = r.take(1) orelse return null;
        return b[0];
    }

    fn word(r: *Reader) ?u32 {
        const b = r.take(4) orelse return null;
        return std.mem.readInt(u32, b[0..4], .little);
    }

    fn words(r: *Reader, arena: Allocator) Allocator.Error!?[]u32 {
        const len = r.word() orelse return null;
        if (@as(u64, len) * 4 > r.rest()) return null;
        const out = try arena.alloc(u32, len);
        for (out) |*w| w.* = r.word().?;
        return out;
    }

    /// A node, in this build's numbering: `absent` when its module is not
    /// in the build, null when it is out of shape.
    fn node(r: *Reader, modules: []const ?Graph.Index, in: Reach.Input) ?Read {
        const slot = r.word() orelse return null;
        const kind_word = r.word() orelse return null;
        const index = r.word() orelse return null;
        if (slot >= modules.len) return null;
        if (kind_word > @backingInt(Reach.Kind.schema)) return null;
        const m = modules[slot] orelse return .absent;
        const kind: Reach.Kind = @fromBackingInt(@intCast(kind_word));
        const bir = in.birOf(m);
        const bound: usize = switch (kind) {
            .decl, .twin => bir.decls.len,
            .derived => in.dispatchOf(m).derived.len,
            .ctor => bir.ctors.len,
            .schema => bir.decls.len * SchemaGraph.Member.count,
        };
        if (index >= bound and !(kind == .ctor and index == Reach.never_ctor)) return null;
        return .{ .at = .{ .module = m, .kind = kind, .index = index } };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a key depends on the module key and on each option" {
    const a: Key.Key = @splat(0x11);
    const b: Key.Key = @splat(0x22);
    var seen: [8]Key.Key = undefined;
    var n: usize = 0;
    for ([_]Key.Key{ a, b }) |module| {
        for (every_options) |options| {
            const k = key(module, options);
            for (seen[0..n]) |s| try testing.expect(!std.mem.eql(u8, &s, &k));
            seen[n] = k;
            n += 1;
        }
    }
    try testing.expectEqualSlices(u8, &key(a, every_options[1]), &key(a, every_options[1]));
}
