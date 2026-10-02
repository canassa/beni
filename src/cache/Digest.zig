//! The dependency digest (docs/design/checker.md §7, *The dependency digest*;
//! `fast-compiler.md` §8, *The firewall cutoff, and the dependency digest*).
//!
//! **One sentence: the record is what a module PUBLISHES, the digest is what a
//! module's dependents READ.** The two are different sets, and the gap between
//! them is where a firewall keyed on the record alone answers exit 0 to a
//! program the compiler rejects — a private type whose constructor payload
//! becomes a function stops being `equatable` without moving one byte of its
//! module's record, and a `pub type alias` whose body no scheme of its own
//! module mentions has its expansion nowhere in the record at all.
//!
//! ```
//! header    magic "BENIDEP\x00" (8)   digest_version: u32
//! module    package: u8   name_len: u32, name
//! types     type_count: u32, then per type in the set below, sorted by name
//!           TEXT:
//!             name_len: u32, name
//!             arity: u16               (a `u8` in version 1)
//!             kind: u8                 adt | alias | foreign
//!             flags: u8                bit 0 opaque, bit 1 equatable,
//!                                      bit 2 comparable, bit 3 has_function,
//!                                      bit 4 holds_markup
//!             body_len: u32, body      `type_body.zig`, or length 0 when the
//!                                      type is not an alias
//! derived   derived_count: u32, then per NOMINAL row of this module's
//!           dispatch `derived` table, sorted by the emitted name text:
//!             kind: u8                 eq | compare
//!             module_len: u32, module  the DECLARING module's name
//!             name_len: u32, name      the type's name
//! imports   import_count: u32, then per direct import, sorted by
//!           (package, name), duplicates removed:
//!             package: u8, name_len: u32, name,
//!             iface_hash: [16]u8, digest: [16]u8
//! ```
//!
//! hashed with `iface_bytes.hash` — the same `SipHash128(1, 3)` and the same
//! all-zero key the record and the module key use, so there is one hash
//! function in the compiler.
//!
//! **It is a SECOND hash, never folded into the record.** Adding a private type
//! to a module must not move that module's interface hash, and folding the
//! digest in would put a module's private business into the bytes every
//! `.iface` golden and every `--stage=raw` output asserts. `format_version`
//! does not bump in this slice and no golden is re-blessed.
//!
//! **It is INDUCTIVE over direct imports.** A module's check can read facts
//! about a module it does not import — an inferred scheme may name `A.T`
//! through `B` and `Types.find` then resolves that name against `A`'s whole
//! declaration list — so one level of import terms has to carry every level of
//! reachability. It does, because each import contributes its own digest, which
//! contains ITS imports' digests. *Rejected: an explicit reachability closure —
//! it is the same answer computed twice, and the second computation is the one
//! that can be wrong.*
//!
//! **The type set is "named by this module's record", CLOSED under alias
//! bodies.** *The closure is a correction to `checker.md` §7, made in place.*
//! The record's set is its own `types` table plus every `type_refs` row whose
//! module is this module, which is how `pub make : Hidden` over a private type
//! puts that type's name into its own record — a dependent can reach a type of
//! this module only by naming it, and it can only name it through a `type_refs`
//! row of some record it reads. But a record carries only the bodies of the
//! aliases its terms name (`checker-v2.md` §14.2), so a `pub type alias Outer
//! = Inner` no scheme names, over a PRIVATE alias `Inner`, has `Inner`'s body
//! nowhere: the spec's set stops one level short of the very case §6.2 is
//! about. The closure adds every type of THIS module that a body already in the
//! set names, which reaches the same answer as expanding the aliases would, in
//! linear time and with no blow-up. A private type nothing mentions is still in
//! no record, no dependent can name it, and it is still in no digest — which is
//! what keeps adding such a type from moving any dependent's key.
//!
//! **Sorted by name TEXT and keyed by NAME, never by ordinal and never by
//! `TypeId`**: a `TypeId` is a whole-program dense index and a declaration
//! ordinal moves when a private declaration is added, and a digest that moved
//! for either would defeat the firewall exactly as the `TypeId` leak did.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Artifacts = @import("../Artifacts.zig");
const InternPool = @import("../InternPool.zig");
const SourceStore = @import("../SourceStore.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const iface_bytes = @import("../resolve/iface_bytes.zig");
const Types = @import("../check/Types.zig");
const Dispatch = @import("../check/Dispatch.zig");
const SchemaPlan = @import("../check/SchemaPlan.zig");
const type_body = @import("type_body.zig");

pub const magic = "BENIDEP\x00";

/// Bumped whenever the meaning of any byte of the recipe changes. It rides
/// inside the module key, so a bump discards every entry — the only migration
/// a cache ever needs.
///
/// Version 2 (`checker-v2.md` §14.2): `arity` is a `u16`, with
/// interface v3's `Type.arity`. Version 3: flag bit 4, `holds_markup`.
pub const digest_version: u32 = 3;

pub const Digest = [16]u8;

/// What a term contributes when there is nothing to contribute: an uncacheable
/// import, or a module whose digest the run did not compute.
pub const none: Digest = @splat(0);

/// The 32 lowercase hex digits `--dep-digest` prints, through the one hex
/// renderer in the compiler.
pub fn hex(d: Digest) [32]u8 {
    return iface_bytes.hashHex(d);
}

/// One type of the set, with every bit a dependent can observe about it.
pub const Type = struct {
    name: []const u8,
    arity: u16,
    kind: Interface.TypeKind,
    is_opaque: bool,
    equatable: bool,
    comparable: bool,
    has_function: bool,
    /// Whether the body holds the build's markup type: what a dependent
    /// platform module's `markup_type_in_foreign` reads of a type it names.
    holds_markup: bool,
    /// `type_body.zig`'s encoding of the alias's expansion, or empty.
    body: []const u8,
};

/// One nominal row of this module's dispatch `derived` table: a function this
/// module EMITS, which a dependent's cached table names through `ext_derived`.
pub const Derived = struct {
    kind: Dispatch.Derived.Kind,
    /// The DECLARING module's name — with the type's name it is the emitted
    /// name `<Module>$<Type>$<kind>` (`static-dispatch-spike.md` §8.5).
    module: []const u8,
    name: []const u8,
};

/// One direct import's contribution. The caller sorts and deduplicates.
pub const Import = struct {
    package: SourceStore.Package,
    name: []const u8,
    iface_hash: [16]u8,
    digest: Digest,
};

pub const Terms = struct {
    package: SourceStore.Package,
    name: []const u8,
    /// Sorted by name text.
    types: []const Type = &.{},
    /// Sorted by emitted name text.
    derived: []const Derived = &.{},
    /// Sorted by `(package, name)`, duplicates removed.
    imports: []const Import = &.{},
};

/// The recipe's byte string, appended to `out`. Exposed so a test can assert
/// the BYTES rather than only the digest: a recipe change that produced the
/// same 16 bytes for two different inputs would be invisible to a test that
/// only ever compared digests.
pub fn writeBytes(gpa: Allocator, out: *std.ArrayList(u8), t: Terms) Allocator.Error!void {
    try out.appendSlice(gpa, magic);
    try appendInt(gpa, out, u32, digest_version);
    try out.append(gpa, @intFromEnum(t.package));
    try appendText(gpa, out, t.name);

    try appendInt(gpa, out, u32, @intCast(t.types.len));
    for (t.types) |ty| {
        try appendText(gpa, out, ty.name);
        try appendInt(gpa, out, u16, ty.arity);
        try out.append(gpa, @intFromEnum(ty.kind));
        try out.append(gpa, flags(ty));
        try appendText(gpa, out, ty.body);
    }

    try appendInt(gpa, out, u32, @intCast(t.derived.len));
    for (t.derived) |d| {
        try out.append(gpa, @intFromEnum(d.kind));
        try appendText(gpa, out, d.module);
        try appendText(gpa, out, d.name);
    }

    try appendInt(gpa, out, u32, @intCast(t.imports.len));
    for (t.imports) |i| {
        try out.append(gpa, @intFromEnum(i.package));
        try appendText(gpa, out, i.name);
        try out.appendSlice(gpa, &i.iface_hash);
        try out.appendSlice(gpa, &i.digest);
    }
}

fn flags(ty: Type) u8 {
    var bits: u8 = 0;
    if (ty.is_opaque) bits |= 1;
    if (ty.equatable) bits |= 2;
    if (ty.comparable) bits |= 4;
    if (ty.has_function) bits |= 8;
    if (ty.holds_markup) bits |= 16;
    return bits;
}

pub fn compute(gpa: Allocator, t: Terms) Allocator.Error!Digest {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try writeBytes(gpa, &bytes, t);
    return iface_bytes.hash(bytes.items);
}

fn appendText(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    try appendInt(gpa, out, u32, @intCast(text.len));
    try out.appendSlice(gpa, text);
}

fn appendInt(gpa: Allocator, out: *std.ArrayList(u8), comptime T: type, value: T) Allocator.Error!void {
    var word: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &word, value, .little);
    try out.appendSlice(gpa, &word);
}

/// One hash over the core package's sorted `(module name, interface hash,
/// dependency digest)` list — `core_surface`, which REPLACES `core_epoch`.
///
/// `core_epoch` hashed core's KEYS, so a comment in `core/Dict.beni` under
/// `--core-root` moved every module in the project. The same one term over
/// core's public face instead gives the property that matters: an edit to core
/// that no module can observe re-checks nothing outside core.
pub fn coreSurface(gpa: Allocator, entries: []const CoreEntry) Allocator.Error!Digest {
    if (entries.len == 0) return none;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    for (entries) |e| {
        try appendText(gpa, &bytes, e.name);
        try bytes.appendSlice(gpa, &e.iface_hash);
        try bytes.appendSlice(gpa, &e.digest);
    }
    return iface_bytes.hash(bytes.items);
}

pub const CoreEntry = struct { name: []const u8, iface_hash: [16]u8, digest: Digest };

// ---------------------------------------------------------------------------
// Collecting one module's terms
// ---------------------------------------------------------------------------

/// Everything `collect` reads. All of it is read-only and all of it exists by
/// the time a module has been checked or its entry installed.
pub const Session = struct {
    graph: *const Graph,
    artifacts: *const Artifacts,
    types: *const Types,
    interfaces: []const Interface,
    dispatch: []const Dispatch,
    plans: []const SchemaPlan,
    interner: *const InternPool.Global,
};

/// `m`'s digest, from its record, its dispatch table and its imports' already
/// published `(iface_hash, digest)` pairs.
///
/// `scratch` holds everything the terms point at and may be reset by the caller
/// the moment this returns — the digest is 16 bytes and keeps none of it.
pub fn collect(
    scratch: Allocator,
    s: Session,
    m: Graph.Index,
    imports: []const Import,
) Allocator.Error!Digest {
    const iface = &s.interfaces[m.int()];
    const module_name = s.graph.moduleName(m);
    const package = s.graph.modulePackage(m);

    // 1. The type set: the record's `types` table, plus every `type_refs` row
    //    that names THIS module, closed under alias bodies (see the header).
    var ids: IdSet = try .init(scratch, s.types, m);
    defer ids.deinit(scratch);
    for (iface.types) |row| {
        try pushId(scratch, &ids, s, package, module_name, iface.symbol(row.name));
    }
    for (iface.type_refs) |ref| {
        if (ref.package != package) continue;
        if (iface.symbol(ref.module) != module_name) continue;
        try pushId(scratch, &ids, s, package, module_name, iface.symbol(ref.name));
    }
    // The closure, as a worklist: an alias body in the set may name a type of
    // this module that no record mentions, and that type's own body is then in
    // the set too. It terminates because a type is appended only once.
    var local: std.ArrayList(Types.TypeId) = .empty;
    defer local.deinit(scratch);
    var at: usize = 0;
    while (at < ids.items.items.len) : (at += 1) {
        const id = ids.items.items[at];
        const e = s.types.entry(id);
        if (e.kind != .alias) continue;
        if (e.schema_endpoint) {
            if (m.int() >= s.plans.len) continue;
            const plan = &s.plans[m.int()];
            const body = schemaEndpointExpansion(plan, e) orelse continue;
            var term_iface = planTermInterface(plan);
            local.clearRetainingCapacity();
            try type_body.collectLocalInterface(scratch, &local, interfaceBodyContext(s, m, &term_iface), body);
            for (local.items) |found| try push(scratch, &ids, found);
            continue;
        }
        const bir = s.artifacts.bir(s.graph.moduleFile(e.module));
        const d = bir.decl(e.decl);
        const body = d.annotation.unwrap() orelse continue;
        local.clearRetainingCapacity();
        try type_body.collectLocal(scratch, &local, bodyContext(s, e, bir, d), body);
        for (local.items) |found| try push(scratch, &ids, found);
    }

    // 2. One row per type, sorted by name TEXT.
    const rows = try scratch.alloc(Type, ids.items.items.len);
    for (ids.items.items, rows) |id, *row| {
        const e = s.types.entry(id);
        const name = s.interner.slice(e.name);
        var body: []const u8 = &.{};
        if (e.kind == .alias) {
            if (e.schema_endpoint) {
                const plan = if (m.int() < s.plans.len) &s.plans[m.int()] else null;
                if (plan != null and schemaEndpointExpansion(plan.?, e) != null) {
                    const term = schemaEndpointExpansion(plan.?, e).?;
                    var term_iface = planTermInterface(plan.?);
                    var bytes: std.ArrayList(u8) = .empty;
                    try type_body.writeInterface(scratch, &bytes, interfaceBodyContext(s, m, &term_iface), term);
                    body = bytes.items;
                }
            } else {
                const bir = s.artifacts.bir(s.graph.moduleFile(e.module));
                const d = bir.decl(e.decl);
                if (d.annotation.unwrap()) |at_inst| {
                    var bytes: std.ArrayList(u8) = .empty;
                    try type_body.write(scratch, &bytes, bodyContext(s, e, bir, d), at_inst);
                    body = bytes.items;
                }
            }
        }
        row.* = .{
            .name = name,
            .arity = e.arity,
            .kind = e.kind,
            .is_opaque = isOpaque(iface, s.interner, e.name),
            .equatable = e.equatable,
            .comparable = e.comparable,
            .has_function = e.has_function,
            .holds_markup = e.holds_markup,
            .body = body,
        };
    }
    std.mem.sort(Type, rows, {}, typeLessThan);

    // 3. The nominal rows of this module's `derived` table, restricted to the
    //    types of the set above. The table is already sorted by emitted name
    //    text (`Dispatch`'s header), and a subsequence of a sorted sequence is
    //    sorted.
    //
    //    *The restriction is a correction to `checker.md` §7, made in place.*
    //    The spec says "per NOMINAL row of this module's dispatch `derived`
    //    table", and derivation is EAGER — `Check` derives `eq` and `compare`
    //    for every nominal type the module declares, used or not (A.23) — so
    //    the unrestricted set moves when a PRIVATE type nothing names is added,
    //    which is the case the whole `TypeId`-is-not-a-dependency argument
    //    exists to keep (`checker.md` §10.1). Measured:
    //    without the restriction, adding `type Unmentioned = U Int` to a leaf
    //    moved every digest in the project. A dependent names a derived
    //    function through `ext_derived`, which spells the TYPE, so a row it
    //    cannot name is a row it cannot observe — and the types it can name are
    //    exactly the set.
    var derived: std.ArrayList(Derived) = .empty;
    defer derived.deinit(scratch);
    if (m.int() < s.dispatch.len) {
        for (s.dispatch[m.int()].derived) |row| {
            const id = switch (row.shape) {
                .nominal => |id| id,
                else => continue,
            };
            if (!ids.has(id)) continue;
            const who = s.types.named(id) orelse continue;
            try derived.append(scratch, .{
                .kind = row.kind,
                .module = s.interner.slice(who.module),
                .name = s.interner.slice(who.name),
            });
        }
    }

    return compute(scratch, .{
        .package = package,
        .name = s.interner.slice(module_name),
        .types = rows,
        .derived = derived.items,
        .imports = imports,
    });
}

fn interfaceBodyContext(s: Session, module: Graph.Index, iface: *const Interface) type_body.InterfaceContext {
    return .{
        .graph = s.graph,
        .types = s.types,
        .interner = s.interner,
        .module = module,
        .iface = iface,
    };
}

/// Find the structural expansion carried by the schema endpoint alias term.
/// The interface writer interns one TypeRef identity per named endpoint; a
/// private endpoint reachable from a public signature is present for the same
/// reason an ordinary reachable private type is present in `type_refs`.
fn schemaEndpointExpansion(plan: *const SchemaPlan, entry: Types.Entry) ?Interface.TermIndex {
    for (plan.definitions) |definition| {
        const program_ref = plan.type_refs[@intFromEnum(definition.type_ref)];
        const encoded_ref = plan.type_refs[@intFromEnum(definition.encoded_ref)];
        const endpoint = if (plan.symbols[@intFromEnum(program_ref.name)] == entry.name)
            definition.program_term
        else if (plan.symbols[@intFromEnum(encoded_ref.name)] == entry.name)
            definition.encoded_term
        else
            continue;
        // The endpoint applied to its own parameters: its row's body.
        if (endpoint.int() >= plan.terms.len) return null;
        const term = plan.terms.get(endpoint.int());
        if (term.tag != .alias or term.lhs >= plan.type_refs.len) return null;
        const body = plan.type_refs[term.lhs].body;
        return if (body.int() < plan.terms.len) body else null;
    }
    return null;
}

fn planTermInterface(plan: *const SchemaPlan) Interface {
    var iface = Interface.empty;
    iface.terms = plan.terms;
    iface.extra = plan.type_extra;
    iface.type_refs = plan.type_refs;
    iface.symbols = plan.symbols;
    return iface;
}

fn bodyContext(s: Session, e: Types.Entry, bir: *const Bir, d: Bir.Decl) type_body.Context {
    return .{
        .graph = s.graph,
        .types = s.types,
        .interner = s.interner,
        .module = e.module,
        .bir = bir,
        .params = bir.declTypeParams(d),
    };
}

fn pushId(
    scratch: Allocator,
    ids: *IdSet,
    s: Session,
    package: SourceStore.Package,
    module_name: InternPool.Symbol,
    name: InternPool.Symbol,
) Allocator.Error!void {
    const id = s.types.find(s.graph, package, module_name, name);
    if (id == .none) return;
    return push(scratch, ids, id);
}

fn push(scratch: Allocator, ids: *IdSet, id: Types.TypeId) Allocator.Error!void {
    return ids.add(scratch, id);
}

/// The digest's type set: the ids in first-pushed order, and one bit per type
/// of the module for membership (a linear `contains` would make the digest
/// quadratic in a module's types). Every id pushed is the
/// module's own (`Types.find` of its own name, `type_body.collectLocal*`), so
/// the bits cover the module's range of the table; an id outside it would be
/// a broken invariant, and is ignored rather than trusted.
const IdSet = struct {
    items: std.ArrayList(Types.TypeId) = .empty,
    from: u32,
    bits: std.DynamicBitSetUnmanaged,

    fn init(gpa: Allocator, types: *const Types, m: Graph.Index) Allocator.Error!IdSet {
        const offsets = types.entry_offsets;
        const in_range = m.int() + 1 < offsets.len;
        const from: u32 = if (in_range) offsets[m.int()] else 0;
        const to: u32 = if (in_range) offsets[m.int() + 1] else 0;
        return .{ .from = from, .bits = try .initEmpty(gpa, to - from) };
    }

    fn deinit(set: *IdSet, gpa: Allocator) void {
        set.items.deinit(gpa);
        set.bits.deinit(gpa);
    }

    fn slot(set: *const IdSet, id: Types.TypeId) ?usize {
        if (id == .none or id.int() < set.from) return null;
        const at = id.int() - set.from;
        return if (at < set.bits.bit_length) at else null;
    }

    fn has(set: *const IdSet, id: Types.TypeId) bool {
        const at = set.slot(id) orelse return false;
        return set.bits.isSet(at);
    }

    fn add(set: *IdSet, gpa: Allocator, id: Types.TypeId) Allocator.Error!void {
        const at = set.slot(id) orelse return;
        if (set.bits.isSet(at)) return;
        set.bits.set(at);
        try set.items.append(gpa, id);
    }
};

/// Whether the record exposes this type WITHOUT its constructors. Read from the
/// record because that is where the fact lives; a private type is in no `types`
/// row and is not opaque, it is invisible.
fn isOpaque(iface: *const Interface, interner: *const InternPool.Global, name: InternPool.Symbol) bool {
    const index = iface.findType(interner, name) orelse return false;
    return iface.types[@intFromEnum(index)].is_opaque;
}

fn typeLessThan(_: void, a: Type, b: Type) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn sampleTerms() Terms {
    return .{ .package = .app, .name = "Leaf" };
}

fn expectDifferent(a: Terms, b: Terms) !void {
    const da = try compute(testing.allocator, a);
    const db = try compute(testing.allocator, b);
    if (std.mem.eql(u8, &da, &db)) {
        std.debug.print("two different inputs produced the same digest {s}\n", .{&hex(da)});
        return error.DigestsCollided;
    }
}

const sample_type: Type = .{
    .name = "Hidden",
    .arity = 0,
    .kind = .adt,
    .is_opaque = false,
    .equatable = true,
    .comparable = true,
    .has_function = false,
    .holds_markup = false,
    .body = &.{},
};

test "the digest's byte string is the recipe, field by field" {
    const gpa = testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    var t = sampleTerms();
    t.types = &.{sample_type};
    t.derived = &.{.{ .kind = .eq, .module = "Leaf", .name = "Hidden" }};
    t.imports = &.{.{ .package = .core, .name = "Basics", .iface_hash = @splat(0xAA), .digest = @splat(0xBB) }};
    try writeBytes(gpa, &bytes, t);

    var at: usize = 0;
    try testing.expectEqualStrings(magic, bytes.items[at..][0..8]);
    at += 8;
    try testing.expectEqual(digest_version, std.mem.readInt(u32, bytes.items[at..][0..4], .little));
    at += 4;
    try testing.expectEqual(@as(u8, @intFromEnum(SourceStore.Package.app)), bytes.items[at]);
    at += 1;
    try testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, bytes.items[at..][0..4], .little));
    at += 4;
    try testing.expectEqualStrings("Leaf", bytes.items[at..][0..4]);
    at += 4;
    // types
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, bytes.items[at..][0..4], .little));
    at += 4;
    try testing.expectEqual(@as(u32, 6), std.mem.readInt(u32, bytes.items[at..][0..4], .little));
    at += 4;
    try testing.expectEqualStrings("Hidden", bytes.items[at..][0..6]);
    at += 6;
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bytes.items[at..][0..2], .little)); // arity
    at += 2;
    try testing.expectEqual(@as(u8, @intFromEnum(Interface.TypeKind.adt)), bytes.items[at]);
    at += 1;
    try testing.expectEqual(@as(u8, 2 | 4), bytes.items[at]); // equatable | comparable
    at += 1;
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bytes.items[at..][0..4], .little)); // body
    at += 4;
    // derived
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, bytes.items[at..][0..4], .little));
    at += 4;
    try testing.expectEqual(@as(u8, @intFromEnum(Dispatch.Derived.Kind.eq)), bytes.items[at]);
    at += 1;
    at += 4 + 4; // "Leaf"
    at += 4 + 6; // "Hidden"
    // imports
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, bytes.items[at..][0..4], .little));
    at += 4;
    try testing.expectEqual(@as(u8, @intFromEnum(SourceStore.Package.core)), bytes.items[at]);
    at += 1;
    at += 4 + 6; // "Basics"
    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(0xAA)), bytes.items[at..][0..16]);
    at += 16;
    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(0xBB)), bytes.items[at..][0..16]);
    at += 16;
    try testing.expectEqual(bytes.items.len, at);
}

test "every term of the recipe moves the digest" {
    // The test that would catch a term the writer forgot. A recipe missing a
    // term is a stale entry, which is a wrong answer that depends on history.
    {
        var t = sampleTerms();
        t.package = .core;
        try expectDifferent(sampleTerms(), t);
    }
    {
        var t = sampleTerms();
        t.name = "Leaves";
        try expectDifferent(sampleTerms(), t);
    }
    var base = sampleTerms();
    base.types = &.{sample_type};
    try expectDifferent(sampleTerms(), base);
    // The five settled bits, one at a time. `equatable` is
    // `plans/m4-3.md` §6.1's demonstrated miscompile and `comparable` and
    // `has_function` are in the record for NO type at all.
    inline for (.{ "is_opaque", "equatable", "comparable", "has_function", "holds_markup" }) |field| {
        var moved = sample_type;
        @field(moved, field) = !@field(sample_type, field);
        var t = sampleTerms();
        t.types = &.{moved};
        try expectDifferent(base, t);
    }
    {
        var moved = sample_type;
        moved.arity = 1;
        var t = sampleTerms();
        t.types = &.{moved};
        try expectDifferent(base, t);
    }
    {
        var moved = sample_type;
        moved.kind = .alias;
        var t = sampleTerms();
        t.types = &.{moved};
        try expectDifferent(base, t);
    }
    {
        // The alias body — `plans/m4-3.md` §6.2's demonstrated miscompile.
        var moved = sample_type;
        moved.kind = .alias;
        moved.body = &.{ 5, 6 };
        var t = sampleTerms();
        t.types = &.{moved};
        var other = moved;
        other.body = &.{ 5, 7 };
        var u = sampleTerms();
        u.types = &.{other};
        try expectDifferent(t, u);
    }
    {
        // A derived row appearing, and the same row for a different kind.
        var with: Terms = sampleTerms();
        with.derived = &.{.{ .kind = .eq, .module = "Leaf", .name = "Hidden" }};
        try expectDifferent(sampleTerms(), with);
        var other = sampleTerms();
        other.derived = &.{.{ .kind = .compare, .module = "Leaf", .name = "Hidden" }};
        try expectDifferent(with, other);
    }
    {
        // An import's hash, its digest, its name and its package, one at a
        // time: the inductive claim.
        var with = sampleTerms();
        with.imports = &.{.{ .package = .app, .name = "Deep", .iface_hash = none, .digest = none }};
        try expectDifferent(sampleTerms(), with);
        var hash_moved = sampleTerms();
        hash_moved.imports = &.{.{ .package = .app, .name = "Deep", .iface_hash = @splat(1), .digest = none }};
        try expectDifferent(with, hash_moved);
        var digest_moved = sampleTerms();
        digest_moved.imports = &.{.{ .package = .app, .name = "Deep", .iface_hash = none, .digest = @splat(1) }};
        try expectDifferent(with, digest_moved);
        var renamed = sampleTerms();
        renamed.imports = &.{.{ .package = .app, .name = "Deeper", .iface_hash = none, .digest = none }};
        try expectDifferent(with, renamed);
        var repackaged = sampleTerms();
        repackaged.imports = &.{.{ .package = .core, .name = "Deep", .iface_hash = none, .digest = none }};
        try expectDifferent(with, repackaged);
    }
}

test "the recipe is length-prefixed, so two different splits cannot agree" {
    // Without the length words, one type called `AB` and one called `A`
    // followed by a body of `B` would hash the same bytes.
    var a = sampleTerms();
    a.name = "AB";
    var b = sampleTerms();
    b.name = "A";
    b.types = &.{.{
        .name = "B",
        .arity = 0,
        .kind = .adt,
        .is_opaque = false,
        .equatable = false,
        .comparable = false,
        .has_function = false,
        .holds_markup = false,
        .body = &.{},
    }};
    try expectDifferent(a, b);

    var c = sampleTerms();
    c.derived = &.{
        .{ .kind = .eq, .module = "AB", .name = "C" },
    };
    var d = sampleTerms();
    d.derived = &.{
        .{ .kind = .eq, .module = "A", .name = "BC" },
    };
    try expectDifferent(c, d);
}

test "the digest is a pure function, and core_surface is one term over its list" {
    const gpa = testing.allocator;
    try testing.expectEqual(try compute(gpa, sampleTerms()), try compute(gpa, sampleTerms()));

    try testing.expectEqual(none, try coreSurface(gpa, &.{}));
    const list: []const CoreEntry = &.{
        .{ .name = "Basics", .iface_hash = @splat(1), .digest = @splat(2) },
        .{ .name = "List", .iface_hash = @splat(3), .digest = @splat(4) },
    };
    const first = try coreSurface(gpa, list);
    try testing.expectEqual(first, try coreSurface(gpa, list));
    // A core module's HASH moving moves the surface, and so does its DIGEST:
    // the second is what `core_epoch` could not see, because it hashed keys.
    const hash_moved = try coreSurface(gpa, &.{
        .{ .name = "Basics", .iface_hash = @splat(9), .digest = @splat(2) },
        .{ .name = "List", .iface_hash = @splat(3), .digest = @splat(4) },
    });
    try testing.expect(!std.mem.eql(u8, &first, &hash_moved));
    const digest_moved = try coreSurface(gpa, &.{
        .{ .name = "Basics", .iface_hash = @splat(1), .digest = @splat(9) },
        .{ .name = "List", .iface_hash = @splat(3), .digest = @splat(4) },
    });
    try testing.expect(!std.mem.eql(u8, &first, &digest_moved));
    // And a core module appearing.
    const grown = try coreSurface(gpa, &.{
        .{ .name = "Basics", .iface_hash = @splat(1), .digest = @splat(2) },
        .{ .name = "List", .iface_hash = @splat(3), .digest = @splat(4) },
        .{ .name = "Set", .iface_hash = @splat(3), .digest = @splat(4) },
    });
    try testing.expect(!std.mem.eql(u8, &first, &grown));
}
