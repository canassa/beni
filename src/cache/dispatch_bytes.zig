//! The dispatch table as BYTES — the cache entry's sidecar (docs/design/
//! checker.md §7, *The cache entry, and the sidecar beside the record*).
//!
//! **Why the sidecar exists at all.** The dispatch table is the one product
//! of the solver the backend needs and nothing can reconstruct without
//! solving: every method call's target, every `?`'s shape, every evidence
//! parameter and every derived function the module emits. A cache that held
//! only the record could give `beni check` its skip and would give `beni
//! build` nothing, and `run/` and `emit/` are exactly where a serialization
//! bug shows up as a wrong PROGRAM rather than a wrong message.
//!
//! **It is also where a silent miscompile can hide**, which is why this file
//! is written the way it is. `plans/m4-plan.md` §8 risk 2 names the
//! configuration: a cached callee and a recompiled caller computing the
//! hidden-parameter order independently. `--roundtrip-dispatch` over the
//! whole corpus is one of the two things standing between that and a wrong
//! program, and the acceptance matrix's warm axis is the other.
//!
//! ```
//! header    magic "BENIDSP\x00" (8)   format_version: u32   column_count: u32
//! table     column_count × { offset: u32, len: u32 }        offsets from byte 0
//! columns   in table order, each 4-byte aligned, gaps zero-filled
//! ```
//!
//! **Two in-memory fields are session-relative and neither may reach the
//! bytes**, for the purity rule `checker.md` §7 gives. `Target.Ext.module`
//! and `Target.ExtDerivedUse.module` are a `Graph.Index` and become an index
//! into `module_refs`, each row `(package, module name)`; `Shape.nominal` and
//! `ExtDerivedUse.type` are a `TypeId` and become an index into `type_refs`,
//! with the record's own row shape `(package, declaring module's name, type's
//! name)`. Every NAME is an offset into `strings`, exactly as the record's
//! `symbols` column is.
//!
//! **What stays as-is** is every `Bir.DeclIndex` and `Bir.Inst.Index` — they
//! index the module's own `Bir`, which the key's `source_hash` and option
//! string pin — and every `Interface.ValueIndex`, which indexes an import
//! whose key the entry's key contains.
//!
//! **Resolving the two reference tables needs `Types`, which does not exist
//! when the entry is read**, so loading is two steps and the split is part of
//! the contract: `read` decodes and re-interns, serially, before any worker
//! starts; `resolve` translates `module_refs` and `type_refs` through
//! `Graph.find` and `Types.find` on the DAG, where `Types` is built and
//! read-only. Between the two, the ref-carrying fields hold reference INDICES
//! and not session ids, and nothing may read the table in that state.
//!
//! **Loading validates, and a bad sidecar is a MISS**, the posture
//! `resolve/iface_bytes.zig` established.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const SourceStore = @import("../SourceStore.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Types = @import("../check/Types.zig");

const Symbol = InternPool.Symbol;

pub const magic = "BENIDSP\x00";
pub const format_version: u32 = 1;

pub const Column = enum(u32) {
    sites,
    tries,
    decl_evidence,
    evidence,
    derived,
    parts,
    symbols,
    module_refs,
    type_refs,
    strings,

    pub const count: u32 = @typeInfo(Column).@"enum".fields.len;

    /// Bytes per element. `strings` is the one column whose `len` is a BYTE
    /// count rather than an element count, so its width is 1 by definition.
    pub fn width(c: Column) u32 {
        return switch (c) {
            .sites => 28,
            .tries => 8,
            .decl_evidence => 8,
            .evidence => 12,
            .derived => 24,
            .parts => target_bytes,
            .symbols => 4,
            .module_refs => 8,
            .type_refs => 12,
            .strings => 1,
        };
    }
};

/// A `Target` is a tagged union of five different payloads, so it is written
/// as one fixed-width row rather than five: `tag`, a second tag byte for the
/// one payload that needs it, and four operand words. A variable-width
/// encoding would buy a few bytes per module and cost every reader a length
/// to trust.
const target_bytes: u32 = 20;

const header_bytes: u32 = 16;
const table_bytes: u32 = Column.count * 8;
const body_start: u32 = header_bytes + table_bytes;

pub const ReadError = error{
    /// Not a sidecar this compiler can read, or one whose indices leave
    /// their columns. The caller recomputes from source.
    BadSidecar,
    /// A string in the sidecar is not in this session's interner. Within one
    /// session that is a compiler bug, not a stale file — see `read`.
    UnknownSymbol,
} || Allocator.Error;

/// A module named by `(package, name)` — never a `Graph.Index`.
pub const ModuleRef = struct { package: SourceStore.Package, name: Symbol };

/// A type named by its DECLARING module and its own name, the record's own
/// row shape (`Interface.TypeRef`) — never a `TypeId`.
pub const TypeRef = struct { package: SourceStore.Package, module: Symbol, name: Symbol };

/// A sidecar between `read` and `resolve`: the table with reference INDICES
/// where a `Graph.Index` and a `TypeId` will go, and the two tables that say
/// what those indices mean.
pub const Loaded = struct {
    table: Dispatch,
    module_refs: []ModuleRef,
    type_refs: []TypeRef,

    pub const empty: Loaded = .{ .table = .empty, .module_refs = &.{}, .type_refs = &.{} };

    pub fn deinit(l: *Loaded, gpa: Allocator) void {
        l.table.deinit(gpa);
        gpa.free(l.module_refs);
        gpa.free(l.type_refs);
        l.* = empty;
    }
};

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/// `d` as bytes. The caller owns the result.
///
/// `graph` and `types` are read only to NAME things: a `Graph.Index` becomes
/// `(package, module name)` and a `TypeId` becomes `(package, declaring
/// module's name, type name)`. Nothing session-assigned survives the call.
pub fn write(
    gpa: Allocator,
    d: *const Dispatch,
    graph: *const Graph,
    types: *const Types,
    interner: *const InternPool.Global,
) Allocator.Error![]u8 {
    var w: Writer = .{ .gpa = gpa, .graph = graph, .types = types, .interner = interner };
    defer w.deinit();

    // The reference tables and the string blob first: every other column
    // indexes them, and their lengths decide the layout.
    const sites = try gpa.alloc(u8, d.sites.len * Column.sites.width());
    defer gpa.free(sites);
    for (d.sites, 0..) |s, i| {
        const row = sites[i * 28 ..][0..28];
        std.mem.writeInt(u32, row[0..4], @intFromEnum(s.inst), .little);
        std.mem.writeInt(u16, row[4..6], s.evidence_index, .little);
        std.mem.writeInt(u16, row[6..8], s.parent, .little);
        try w.writeTarget(row[8..28], s.target);
    }

    const parts = try gpa.alloc(u8, d.parts.len * target_bytes);
    defer gpa.free(parts);
    for (d.parts, 0..) |t, i| try w.writeTarget(parts[i * target_bytes ..][0..target_bytes], t);

    const derived = try gpa.alloc(u8, d.derived.len * Column.derived.width());
    defer gpa.free(derived);
    for (d.derived, 0..) |row_in, i| {
        const row = derived[i * 24 ..][0..24];
        row[0] = @intFromEnum(row_in.kind);
        std.mem.writeInt(u16, row[2..4], row_in.evidence_count, .little);
        try w.writeShape(row[4..16], row_in.shape);
        std.mem.writeInt(u32, row[16..20], row_in.parts.start, .little);
        std.mem.writeInt(u32, row[20..24], row_in.parts.len, .little);
    }

    const evidence = try gpa.alloc(u8, d.evidence.len * Column.evidence.width());
    defer gpa.free(evidence);
    for (d.evidence, 0..) |e, i| {
        const row = evidence[i * 12 ..][0..12];
        std.mem.writeInt(u16, row[0..2], e.quantified, .little);
        std.mem.writeInt(u32, row[4..8], if (e.var_name.unwrap()) |s| try w.string(s) else no_string, .little);
        std.mem.writeInt(u32, row[8..12], try w.string(e.method), .little);
    }

    const symbols = try gpa.alloc(u8, d.symbols.len * 4);
    defer gpa.free(symbols);
    for (d.symbols, 0..) |s, i| std.mem.writeInt(u32, symbols[i * 4 ..][0..4], try w.string(s), .little);

    const tries = try gpa.alloc(u8, d.tries.len * Column.tries.width());
    defer gpa.free(tries);
    for (d.tries, 0..) |t, i| {
        const row = tries[i * 8 ..][0..8];
        std.mem.writeInt(u32, row[0..4], @intFromEnum(t.inst), .little);
        row[4] = @intFromEnum(t.shape);
    }

    const decl_evidence = try gpa.alloc(u8, d.decl_evidence.len * Column.decl_evidence.width());
    defer gpa.free(decl_evidence);
    for (d.decl_evidence, 0..) |r, i| {
        const row = decl_evidence[i * 8 ..][0..8];
        std.mem.writeInt(u32, row[0..4], r.start, .little);
        std.mem.writeInt(u32, row[4..8], r.len, .little);
    }

    // The two reference tables are complete only now, because writing a
    // target is what appends to them.
    const module_refs = try gpa.alloc(u8, w.module_refs.items.len * Column.module_refs.width());
    defer gpa.free(module_refs);
    for (w.module_refs.items, 0..) |r, i| {
        const row = module_refs[i * 8 ..][0..8];
        row[0] = @intFromEnum(r.package);
        std.mem.writeInt(u32, row[4..8], r.name_offset, .little);
    }
    const type_refs = try gpa.alloc(u8, w.type_refs.items.len * Column.type_refs.width());
    defer gpa.free(type_refs);
    for (w.type_refs.items, 0..) |r, i| {
        const row = type_refs[i * 12 ..][0..12];
        row[0] = @intFromEnum(r.package);
        std.mem.writeInt(u32, row[4..8], r.module_offset, .little);
        std.mem.writeInt(u32, row[8..12], r.name_offset, .little);
    }

    const columns = [Column.count][]const u8{
        sites,
        tries,
        decl_evidence,
        evidence,
        derived,
        parts,
        symbols,
        module_refs,
        type_refs,
        w.strings.items,
    };
    const lengths = [Column.count]u32{
        @intCast(d.sites.len),
        @intCast(d.tries.len),
        @intCast(d.decl_evidence.len),
        @intCast(d.evidence.len),
        @intCast(d.derived.len),
        @intCast(d.parts.len),
        @intCast(d.symbols.len),
        @intCast(w.module_refs.items.len),
        @intCast(w.type_refs.items.len),
        @intCast(w.strings.items.len),
    };

    var offsets: [Column.count]u32 = undefined;
    var at: u32 = body_start;
    for (0..Column.count) |i| {
        offsets[i] = at;
        at += @intCast(columns[i].len);
        at += @intCast(pad4(at));
    }
    const out = try gpa.alloc(u8, at);
    errdefer gpa.free(out);
    @memset(out, 0);
    @memcpy(out[0..8], magic);
    std.mem.writeInt(u32, out[8..12], format_version, .little);
    std.mem.writeInt(u32, out[12..16], Column.count, .little);
    for (0..Column.count) |i| {
        const row = out[header_bytes + i * 8 ..][0..8];
        std.mem.writeInt(u32, row[0..4], offsets[i], .little);
        std.mem.writeInt(u32, row[4..8], lengths[i], .little);
        @memcpy(out[offsets[i]..][0..columns[i].len], columns[i]);
    }
    return out;
}

/// The sentinel for "no string": `Symbol.Optional.none`'s spelling, so a
/// reader that forgot the case reads an offset past the blob and misses
/// rather than returning a name nobody wrote.
const no_string: u32 = std.math.maxInt(u32);
const no_ref: u32 = std.math.maxInt(u32);

const Writer = struct {
    gpa: Allocator,
    graph: *const Graph,
    types: *const Types,
    interner: *const InternPool.Global,
    strings: std.ArrayList(u8) = .empty,
    /// Text → offset, so two slots holding the same name share one record
    /// and the blob is a function of the table rather than of its order.
    seen: std.StringHashMapUnmanaged(u32) = .empty,
    module_refs: std.ArrayList(struct { package: SourceStore.Package, name_offset: u32 }) = .empty,
    type_refs: std.ArrayList(struct { package: SourceStore.Package, module_offset: u32, name_offset: u32 }) = .empty,

    fn deinit(w: *Writer) void {
        w.strings.deinit(w.gpa);
        w.seen.deinit(w.gpa);
        w.module_refs.deinit(w.gpa);
        w.type_refs.deinit(w.gpa);
    }

    /// `s`'s text as a byte offset into `strings`, appending it if it is
    /// new. First-occurrence order over the walk, which is a function of the
    /// table alone.
    fn string(w: *Writer, s: Symbol) Allocator.Error!u32 {
        const text = w.interner.slice(s);
        const gop = try w.seen.getOrPut(w.gpa, text);
        if (gop.found_existing) return gop.value_ptr.*;
        const at: u32 = @intCast(w.strings.items.len);
        gop.value_ptr.* = at;
        var len_word: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_word, @intCast(text.len), .little);
        try w.strings.appendSlice(w.gpa, &len_word);
        try w.strings.appendSlice(w.gpa, text);
        // Every record is padded to four, so the blob's own length is a
        // multiple of four and the column after it needs no gap.
        try w.strings.appendNTimes(w.gpa, 0, pad4(text.len));
        return at;
    }

    fn moduleRef(w: *Writer, m: Graph.Index) Allocator.Error!u32 {
        if (m.int() >= w.graph.count()) return no_ref;
        const package = w.graph.module(m).package;
        const name_offset = try w.string(w.graph.moduleName(m));
        for (w.module_refs.items, 0..) |r, i| {
            if (r.package == package and r.name_offset == name_offset) return @intCast(i);
        }
        try w.module_refs.append(w.gpa, .{ .package = package, .name_offset = name_offset });
        return @intCast(w.module_refs.items.len - 1);
    }

    fn typeRef(w: *Writer, id: Types.TypeId) Allocator.Error!u32 {
        const named = w.types.named(id) orelse return no_ref;
        const module_offset = try w.string(named.module);
        const name_offset = try w.string(named.name);
        for (w.type_refs.items, 0..) |r, i| {
            if (r.package == named.package and r.module_offset == module_offset and r.name_offset == name_offset) {
                return @intCast(i);
            }
        }
        try w.type_refs.append(w.gpa, .{
            .package = named.package,
            .module_offset = module_offset,
            .name_offset = name_offset,
        });
        return @intCast(w.type_refs.items.len - 1);
    }

    fn writeTarget(w: *Writer, row: *[target_bytes]u8, t: Dispatch.Target) Allocator.Error!void {
        @memset(row, 0);
        row[0] = @intFromEnum(std.meta.activeTag(t));
        switch (t) {
            .top => |u| {
                std.mem.writeInt(u32, row[4..8], @intFromEnum(u.decl), .little);
                writeRange(row[12..20], u.parts);
            },
            .ext => |e| {
                std.mem.writeInt(u32, row[4..8], try w.moduleRef(e.module), .little);
                std.mem.writeInt(u32, row[8..12], @intFromEnum(e.value), .little);
                writeRange(row[12..20], e.parts);
            },
            .evidence => |k| std.mem.writeInt(u32, row[4..8], k, .little),
            .primitive => |p| std.mem.writeInt(u32, row[4..8], @intFromEnum(p), .little),
            .derived => |u| {
                std.mem.writeInt(u32, row[4..8], u.index, .little);
                writeRange(row[12..20], u.parts);
            },
            .ext_derived => |u| {
                row[1] = @intFromEnum(u.kind);
                std.mem.writeInt(u32, row[4..8], try w.moduleRef(u.module), .little);
                std.mem.writeInt(u32, row[8..12], try w.typeRef(u.type), .little);
                writeRange(row[12..20], u.parts);
            },
            .field, .err => {},
        }
    }

    fn writeShape(w: *Writer, row: *[12]u8, shape: Dispatch.Shape) Allocator.Error!void {
        @memset(row, 0);
        row[0] = @intFromEnum(std.meta.activeTag(shape));
        switch (shape) {
            .nominal => |id| std.mem.writeInt(u32, row[4..8], try w.typeRef(id), .little),
            .record => |r| writeRange(row[4..12], r),
            .tuple => |n| row[1] = n,
            .unit => {},
        }
    }
};

fn writeRange(row: *[8]u8, r: Dispatch.Range) void {
    std.mem.writeInt(u32, row[0..4], r.start, .little);
    std.mem.writeInt(u32, row[4..8], r.len, .little);
}

fn pad4(n: usize) usize {
    return (4 - (n % 4)) % 4;
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/// The sidecar `bytes` describes, re-interned through the NON-MUTATING
/// `InternPool.Global.find`.
///
/// This is the in-session path — `--roundtrip-dispatch`, which runs on the
/// worker that checked the module, where `Global` is thread-confined and a
/// load that APPENDED to the pool would race with every other worker's.
/// Within one session the lookup cannot legitimately miss, so a miss is
/// `UnknownSymbol` and the caller reports `internal`.
pub fn read(gpa: Allocator, bytes: []const u8, interner: *const InternPool.Global) ReadError!Loaded {
    var in: Interning = .{ .find = interner };
    return decode(gpa, bytes, &in);
}

/// `read`, through `getOrPut`. M4-1's cross-process load is the case that
/// can legitimately miss — a name this session never interned — and it runs
/// serially before any worker starts, which is where growing the pool
/// belongs.
pub fn readGrowing(gpa: Allocator, bytes: []const u8, interner: *InternPool.Global) ReadError!Loaded {
    var in: Interning = .{ .get_or_put = .{ .pool = interner, .gpa = gpa } };
    return decode(gpa, bytes, &in);
}

const Interning = union(enum) {
    find: *const InternPool.Global,
    get_or_put: struct { pool: *InternPool.Global, gpa: Allocator },

    fn symbol(i: *Interning, text: []const u8) ReadError!Symbol {
        return switch (i.*) {
            .find => |pool| pool.find(text) orelse error.UnknownSymbol,
            .get_or_put => |g| g.pool.getOrPut(g.gpa, text),
        };
    }
};

fn decode(gpa: Allocator, bytes: []const u8, in: *Interning) ReadError!Loaded {
    if (bytes.len < body_start) return error.BadSidecar;
    if (!std.mem.eql(u8, bytes[0..8], magic)) return error.BadSidecar;
    if (std.mem.readInt(u32, bytes[8..12], .little) != format_version) return error.BadSidecar;
    if (std.mem.readInt(u32, bytes[12..16], .little) != Column.count) return error.BadSidecar;

    var offsets: [Column.count]u32 = undefined;
    var lengths: [Column.count]u32 = undefined;
    for (0..Column.count) |i| {
        const c: Column = @enumFromInt(i);
        const row = bytes[header_bytes + i * 8 ..][0..8];
        const offset = std.mem.readInt(u32, row[0..4], .little);
        const len = std.mem.readInt(u32, row[4..8], .little);
        if (offset % 4 != 0 or offset < body_start) return error.BadSidecar;
        if (@as(u64, offset) + @as(u64, len) * @as(u64, c.width()) > bytes.len) return error.BadSidecar;
        offsets[i] = offset;
        lengths[i] = len;
    }
    const blob = bytes[offsets[@intFromEnum(Column.strings)]..][0..lengths[@intFromEnum(Column.strings)]];

    var out: Loaded = .empty;
    errdefer out.deinit(gpa);

    // The reference tables first: every target indexes them, and `resolve`
    // needs them whole.
    {
        const in_bytes = bytes[offsets[@intFromEnum(Column.module_refs)]..];
        const refs = try gpa.alloc(ModuleRef, lengths[@intFromEnum(Column.module_refs)]);
        out.module_refs = refs;
        for (refs, 0..) |*r, i| {
            const row = in_bytes[i * 8 ..][0..8];
            r.* = .{
                .package = std.enums.fromInt(SourceStore.Package, row[0]) orelse return error.BadSidecar,
                .name = try symbolAt(blob, std.mem.readInt(u32, row[4..8], .little), in) orelse return error.BadSidecar,
            };
        }
    }
    {
        const in_bytes = bytes[offsets[@intFromEnum(Column.type_refs)]..];
        const refs = try gpa.alloc(TypeRef, lengths[@intFromEnum(Column.type_refs)]);
        out.type_refs = refs;
        for (refs, 0..) |*r, i| {
            const row = in_bytes[i * 12 ..][0..12];
            r.* = .{
                .package = std.enums.fromInt(SourceStore.Package, row[0]) orelse return error.BadSidecar,
                .module = try symbolAt(blob, std.mem.readInt(u32, row[4..8], .little), in) orelse return error.BadSidecar,
                .name = try symbolAt(blob, std.mem.readInt(u32, row[8..12], .little), in) orelse return error.BadSidecar,
            };
        }
    }

    const module_ref_count: u32 = @intCast(out.module_refs.len);
    const type_ref_count: u32 = @intCast(out.type_refs.len);

    {
        const in_bytes = bytes[offsets[@intFromEnum(Column.symbols)]..];
        const symbols = try gpa.alloc(Symbol, lengths[@intFromEnum(Column.symbols)]);
        out.table.symbols = symbols;
        for (symbols, 0..) |*s, i| {
            s.* = try symbolAt(blob, std.mem.readInt(u32, in_bytes[i * 4 ..][0..4], .little), in) orelse
                return error.BadSidecar;
        }
    }
    {
        const in_bytes = bytes[offsets[@intFromEnum(Column.parts)]..];
        const parts = try gpa.alloc(Dispatch.Target, lengths[@intFromEnum(Column.parts)]);
        out.table.parts = parts;
        for (parts, 0..) |*t, i| {
            t.* = try readTarget(in_bytes[i * target_bytes ..][0..target_bytes], module_ref_count, type_ref_count);
        }
    }
    {
        const in_bytes = bytes[offsets[@intFromEnum(Column.sites)]..];
        const sites = try gpa.alloc(Dispatch.Site, lengths[@intFromEnum(Column.sites)]);
        out.table.sites = sites;
        for (sites, 0..) |*s, i| {
            const row = in_bytes[i * 28 ..][0..28];
            s.* = .{
                .inst = @enumFromInt(std.mem.readInt(u32, row[0..4], .little)),
                .evidence_index = std.mem.readInt(u16, row[4..6], .little),
                .parent = std.mem.readInt(u16, row[6..8], .little),
                .target = try readTarget(row[8..28], module_ref_count, type_ref_count),
            };
        }
    }
    {
        const in_bytes = bytes[offsets[@intFromEnum(Column.tries)]..];
        const tries = try gpa.alloc(Dispatch.Try, lengths[@intFromEnum(Column.tries)]);
        out.table.tries = tries;
        for (tries, 0..) |*t, i| {
            const row = in_bytes[i * 8 ..][0..8];
            t.* = .{
                .inst = @enumFromInt(std.mem.readInt(u32, row[0..4], .little)),
                .shape = std.enums.fromInt(Dispatch.Try.Kind, row[4]) orelse return error.BadSidecar,
            };
        }
    }
    {
        const in_bytes = bytes[offsets[@intFromEnum(Column.decl_evidence)]..];
        const ranges = try gpa.alloc(Dispatch.Range, lengths[@intFromEnum(Column.decl_evidence)]);
        out.table.decl_evidence = ranges;
        for (ranges, 0..) |*r, i| r.* = readRange(in_bytes[i * 8 ..][0..8]);
    }
    {
        const in_bytes = bytes[offsets[@intFromEnum(Column.evidence)]..];
        const evidence = try gpa.alloc(Dispatch.Evidence, lengths[@intFromEnum(Column.evidence)]);
        out.table.evidence = evidence;
        for (evidence, 0..) |*e, i| {
            const row = in_bytes[i * 12 ..][0..12];
            const var_offset = std.mem.readInt(u32, row[4..8], .little);
            e.* = .{
                .quantified = std.mem.readInt(u16, row[0..2], .little),
                .var_name = if (var_offset == no_string)
                    .none
                else
                    (try symbolAt(blob, var_offset, in) orelse return error.BadSidecar).toOptional(),
                .method = try symbolAt(blob, std.mem.readInt(u32, row[8..12], .little), in) orelse
                    return error.BadSidecar,
            };
        }
    }
    {
        const in_bytes = bytes[offsets[@intFromEnum(Column.derived)]..];
        const derived = try gpa.alloc(Dispatch.Derived, lengths[@intFromEnum(Column.derived)]);
        out.table.derived = derived;
        for (derived, 0..) |*row_out, i| {
            const row = in_bytes[i * 24 ..][0..24];
            row_out.* = .{
                .kind = std.enums.fromInt(Dispatch.Derived.Kind, row[0]) orelse return error.BadSidecar,
                .evidence_count = std.mem.readInt(u16, row[2..4], .little),
                .shape = try readShape(row[4..16], type_ref_count),
                .parts = readRange(row[16..24]),
            };
        }
    }

    if (!verify(&out)) return error.BadSidecar;
    return out;
}

/// The string at byte offset `at` of `blob`, interned. Null when the offset
/// or the length leaves the blob, which the caller turns into `BadSidecar`.
fn symbolAt(blob: []const u8, at: u32, in: *Interning) ReadError!?Symbol {
    if (@as(u64, at) + 4 > blob.len) return null;
    const len = std.mem.readInt(u32, blob[at..][0..4], .little);
    if (@as(u64, at) + 4 + @as(u64, len) > blob.len) return null;
    return try in.symbol(blob[at + 4 ..][0..len]);
}

fn readRange(row: *const [8]u8) Dispatch.Range {
    return .{
        .start = std.mem.readInt(u32, row[0..4], .little),
        .len = std.mem.readInt(u32, row[4..8], .little),
    };
}

/// A `Target` row. The two reference fields come back as INDICES wearing a
/// `Graph.Index`/`TypeId` hat; `resolve` is what turns them into session ids,
/// and nothing between here and there may read them.
fn readTarget(row: *const [target_bytes]u8, module_refs: u32, type_refs: u32) ReadError!Dispatch.Target {
    const tag = std.enums.fromInt(std.meta.Tag(Dispatch.Target), row[0]) orelse return error.BadSidecar;
    const a = std.mem.readInt(u32, row[4..8], .little);
    const b = std.mem.readInt(u32, row[8..12], .little);
    const parts = readRange(row[12..20]);
    return switch (tag) {
        .top => .{ .top = .{ .decl = @enumFromInt(a), .parts = parts } },
        .ext => blk: {
            if (a != no_ref and a >= module_refs) return error.BadSidecar;
            break :blk .{ .ext = .{ .module = @enumFromInt(a), .value = @enumFromInt(b), .parts = parts } };
        },
        .evidence => .{ .evidence = std.math.cast(u16, a) orelse return error.BadSidecar },
        .primitive => .{
            .primitive = std.enums.fromInt(Dispatch.Target.Primitive, std.math.cast(u8, a) orelse
                return error.BadSidecar) orelse return error.BadSidecar,
        },
        .derived => .{ .derived = .{ .index = a, .parts = parts } },
        .ext_derived => blk: {
            if (a != no_ref and a >= module_refs) return error.BadSidecar;
            if (b != no_ref and b >= type_refs) return error.BadSidecar;
            break :blk .{ .ext_derived = .{
                .module = @enumFromInt(a),
                .type = @enumFromInt(b),
                .kind = std.enums.fromInt(Dispatch.Derived.Kind, row[1]) orelse return error.BadSidecar,
                .parts = parts,
            } };
        },
        .field => .field,
        .err => .err,
    };
}

fn readShape(row: *const [12]u8, type_refs: u32) ReadError!Dispatch.Shape {
    const tag = std.enums.fromInt(std.meta.Tag(Dispatch.Shape), row[0]) orelse return error.BadSidecar;
    return switch (tag) {
        .nominal => blk: {
            const at = std.mem.readInt(u32, row[4..8], .little);
            if (at != no_ref and at >= type_refs) return error.BadSidecar;
            break :blk .{ .nominal = @enumFromInt(at) };
        },
        .record => .{ .record = readRange(row[4..12]) },
        .tuple => .{ .tuple = row[1] },
        .unit => .unit,
    };
}

/// Whether every index and range in `l` stays inside the column it points at.
/// `decode` runs this before handing a sidecar back, so a caller never has to
/// trust one — which is what makes a corrupt file a miss rather than a wrong
/// answer, or an out-of-bounds read.
///
/// What it checks: every `derived` index of a target is a `derived` row;
/// every `parts` range fits `parts`; every `record` shape's range fits
/// `symbols`; every `derived` row's `parts` range fits `parts`; every
/// `decl_evidence` range fits `evidence`. The two reference indices were
/// bounded as they were read.
pub fn verify(l: *const Loaded) bool {
    const d = &l.table;
    for (d.sites) |s| {
        if (!targetOk(d, s.target)) return false;
    }
    for (d.parts) |t| {
        if (!targetOk(d, t)) return false;
    }
    for (d.derived) |row| {
        if (!rangeOk(row.parts, d.parts.len)) return false;
        switch (row.shape) {
            .record => |r| if (!rangeOk(r, d.symbols.len)) return false,
            else => {},
        }
    }
    for (d.decl_evidence) |r| {
        if (!rangeOk(r, d.evidence.len)) return false;
    }
    return true;
}

fn targetOk(d: *const Dispatch, t: Dispatch.Target) bool {
    if (!rangeOk(t.partsOf(), d.parts.len)) return false;
    return switch (t) {
        .derived => |u| u.index < d.derived.len,
        else => true,
    };
}

fn rangeOk(r: Dispatch.Range, limit: usize) bool {
    return @as(u64, r.start) + @as(u64, r.len) <= limit;
}

// ---------------------------------------------------------------------------
// Resolving
// ---------------------------------------------------------------------------

/// Turn every reference index into this session's `Graph.Index` and
/// `TypeId`, in place. Runs on the DAG, where `Types` is built and
/// read-only.
///
/// A reference that names no module or no type of it yields the poisoned id
/// the term would have carried anyway — `.none` for a type, and a module
/// index of `graph.count()`, which every accessor already treats as absent.
/// A sidecar mapped from disk that does not describe this project cannot
/// trap; whether it is WRONG is the cache key's problem and not the
/// reader's, which is the same split `checker.md` §7 draws for the record.
pub fn resolve(l: *Loaded, graph: *const Graph, types: *const Types) void {
    const modules = @as(u32, @intCast(l.module_refs.len));
    const type_count = @as(u32, @intCast(l.type_refs.len));
    for (@constCast(l.table.sites)) |*s| resolveTarget(&s.target, l, graph, types, modules, type_count);
    for (@constCast(l.table.parts)) |*t| resolveTarget(t, l, graph, types, modules, type_count);
    for (@constCast(l.table.derived)) |*row| {
        switch (row.shape) {
            .nominal => |at| row.shape = .{ .nominal = resolveType(l, graph, types, @intFromEnum(at), type_count) },
            else => {},
        }
    }
}

fn resolveTarget(
    t: *Dispatch.Target,
    l: *const Loaded,
    graph: *const Graph,
    types: *const Types,
    modules: u32,
    type_count: u32,
) void {
    switch (t.*) {
        .ext => |e| t.* = .{ .ext = .{
            .module = resolveModule(l, graph, @intFromEnum(e.module), modules),
            .value = e.value,
            .parts = e.parts,
        } },
        .ext_derived => |u| t.* = .{ .ext_derived = .{
            .module = resolveModule(l, graph, @intFromEnum(u.module), modules),
            .type = resolveType(l, graph, types, @intFromEnum(u.type), type_count),
            .kind = u.kind,
            .parts = u.parts,
        } },
        else => {},
    }
}

fn resolveModule(l: *const Loaded, graph: *const Graph, at: u32, modules: u32) Graph.Index {
    // `graph.count()` is the "not here" index: out of range for every
    // per-module array, which every accessor already guards.
    const absent: Graph.Index = @enumFromInt(graph.count());
    if (at >= modules) return absent;
    const ref = l.module_refs[at];
    return graph.find(ref.package, ref.name) orelse absent;
}

fn resolveType(l: *const Loaded, graph: *const Graph, types: *const Types, at: u32, type_count: u32) Types.TypeId {
    if (at >= type_count) return .none;
    const ref = l.type_refs[at];
    return types.find(graph, ref.package, ref.module, ref.name);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const TestProject = @import("../resolve/TestProject.zig");
const Session = @import("../Session.zig");

/// Two tables are equal in every byte the format carries. Symbols are
/// compared as TEXT, because the point of the `strings` column is that two
/// sessions may number the same name differently.
fn expectSameTable(a: *const Dispatch, b: *const Dispatch, interner: *const InternPool.Global) !void {
    try testing.expectEqualSlices(Dispatch.Site, a.sites, b.sites);
    try testing.expectEqualSlices(Dispatch.Try, a.tries, b.tries);
    try testing.expectEqualSlices(Dispatch.Range, a.decl_evidence, b.decl_evidence);
    try testing.expectEqualSlices(Dispatch.Derived, a.derived, b.derived);
    try testing.expectEqualSlices(Dispatch.Target, a.parts, b.parts);
    try testing.expectEqual(a.evidence.len, b.evidence.len);
    for (a.evidence, b.evidence) |x, y| {
        try testing.expectEqual(x.quantified, y.quantified);
        try testing.expectEqualStrings(optionalText(interner, x.var_name), optionalText(interner, y.var_name));
        try testing.expectEqualStrings(interner.slice(x.method), interner.slice(y.method));
    }
    try testing.expectEqual(a.symbols.len, b.symbols.len);
    for (a.symbols, b.symbols) |x, y| {
        try testing.expectEqualStrings(interner.slice(x), interner.slice(y));
    }
}

fn optionalText(interner: *const InternPool.Global, o: Symbol.Optional) []const u8 {
    return interner.slice(o.unwrap() orelse return "");
}

/// Write, read, resolve, and require the table back unchanged — and require
/// the bytes of the SECOND write to equal the first, which is what a stable
/// entry means.
fn expectRoundTrip(p: *TestProject, m: Graph.Index) !void {
    const gpa = testing.allocator;
    const table = &p.session.checked.dispatch[m.int()];
    const bytes = try write(gpa, table, &p.session.graph, &p.session.checked.types, &p.session.interner);
    defer gpa.free(bytes);

    var loaded = try read(gpa, bytes, &p.session.interner);
    defer loaded.deinit(gpa);
    resolve(&loaded, &p.session.graph, &p.session.checked.types);
    try expectSameTable(table, &loaded.table, &p.session.interner);

    const again = try write(gpa, &loaded.table, &p.session.graph, &p.session.checked.types, &p.session.interner);
    defer gpa.free(again);
    try testing.expectEqualSlices(u8, bytes, again);
}

test "an empty table round-trips" {
    var global = try InternPool.Global.init(testing.allocator);
    defer global.deinit(testing.allocator);
    const gpa = testing.allocator;
    const empty: Dispatch = .empty;
    const graph: Graph = .empty;
    const types: Types = .empty;
    const bytes = try write(gpa, &empty, &graph, &types, &global);
    defer gpa.free(bytes);
    var loaded = try read(gpa, bytes, &global);
    defer loaded.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), loaded.table.sites.len);
    try testing.expectEqual(@as(usize, 0), loaded.module_refs.len);
}

test "every table of a project round-trips: sites, evidence, derived, tries and ext targets" {
    // The fixture has to reach every arm of `Target` and every arm of
    // `Shape`, or the round trip is a claim about the arms it happened to
    // touch: a `top` call with evidence, an `ext` call into another module,
    // a derived `eq` over a record, a tuple, a nominal type, a `?`, and a
    // method on a type another module declares (`ext_derived`).
    var p = try TestProject.initWith(testing.allocator, &.{
        .{ .path = "Shapes.beni", .source =
        \\pub type Tag
        \\    = Tag Int
        \\
        \\
        \\pub type Pair a
        \\    = Pair a a
        \\
        \\
        \\pub wrap : a -> Pair a
        \\wrap x =
        \\    Pair x x
        \\
        },
        .{ .path = "Uses.beni", .source =
        \\import Shapes exposing (Tag, Pair)
        \\
        \\
        \\pub sameTag : Tag, Tag -> Bool
        \\sameTag a b =
        \\    a == b
        \\
        \\
        \\pub samePair : Pair Int, Pair Int -> Bool
        \\samePair a b =
        \\    a == b
        \\
        \\
        \\pub sameRecord : { x : Int, y : String }, { x : Int, y : String } -> Bool
        \\sameRecord a b =
        \\    a == b
        \\
        \\
        \\pub sameTuple : ( Int, Int ), ( Int, Int ) -> Bool
        \\sameTuple a b =
        \\    a == b
        \\
        \\
        \\pub bigger : a, a -> a
        \\    where a.compare : a, a -> Order
        \\bigger a b =
        \\    if a < b then b else a
        \\
        \\
        \\pub useBigger : Int
        \\useBigger =
        \\    bigger 1 2
        \\
        \\
        \\pub wrapped : Pair Int
        \\wrapped =
        \\    Shapes.wrap 1
        \\
        },
    }, .{ .phases = Session.check_phases });
    defer p.deinit();

    var any_sites = false;
    var any_derived = false;
    var any_evidence = false;
    for (0..p.session.graph.count()) |i| {
        const m: Graph.Index = @enumFromInt(i);
        try expectRoundTrip(&p, m);
        const table = &p.session.checked.dispatch[i];
        if (table.sites.len != 0) any_sites = true;
        if (table.derived.len != 0) any_derived = true;
        if (table.evidence.len != 0) any_evidence = true;
    }
    // A round trip of nothing proves nothing.
    try testing.expect(any_sites);
    try testing.expect(any_derived);
    try testing.expect(any_evidence);
}

test "a string the session never interned is UnknownSymbol, not a miss" {
    // The split `resolve/iface_bytes.zig` draws and this file keeps: only
    // `BadSidecar` is a cache miss. `UnknownSymbol` inside one session means
    // the writer and the pool disagree, which is a compiler bug.
    const gpa = testing.allocator;
    var writer_pool = try InternPool.Global.init(gpa);
    defer writer_pool.deinit(gpa);
    const only_here = try writer_pool.getOrPut(gpa, "onlyInTheWriter");
    const table: Dispatch = .{
        .symbols = &.{only_here},
    };
    const graph: Graph = .empty;
    const types: Types = .empty;
    const bytes = try write(gpa, &table, &graph, &types, &writer_pool);
    defer gpa.free(bytes);

    var reader_pool = try InternPool.Global.init(gpa);
    defer reader_pool.deinit(gpa);
    try testing.expectError(error.UnknownSymbol, read(gpa, bytes, &reader_pool));
    // The reader's pool was NOT grown by the failed load.
    try testing.expectEqual(@as(u32, InternPool.WellKnown.count), reader_pool.count());

    // …and `readGrowing`, which is the cross-process path, takes it.
    var growing = try InternPool.Global.init(gpa);
    defer growing.deinit(gpa);
    var loaded = try readGrowing(gpa, bytes, &growing);
    defer loaded.deinit(gpa);
    try testing.expectEqualStrings("onlyInTheWriter", growing.slice(loaded.table.symbols[0]));
}

test "a wrong magic, an unknown version and a short file are all BadSidecar" {
    const gpa = testing.allocator;
    var global = try InternPool.Global.init(gpa);
    defer global.deinit(gpa);
    const table: Dispatch = .empty;
    const graph: Graph = .empty;
    const types: Types = .empty;
    const bytes = try write(gpa, &table, &graph, &types, &global);
    defer gpa.free(bytes);

    try testing.expectError(error.BadSidecar, read(gpa, &.{}, &global));
    try testing.expectError(error.BadSidecar, read(gpa, bytes[0 .. bytes.len - 1], &global));

    const copy = try gpa.dupe(u8, bytes);
    defer gpa.free(copy);
    copy[0] = 'X';
    try testing.expectError(error.BadSidecar, read(gpa, copy, &global));
    @memcpy(copy[0..8], magic);
    std.mem.writeInt(u32, copy[8..12], format_version + 1, .little);
    try testing.expectError(error.BadSidecar, read(gpa, copy, &global));
    std.mem.writeInt(u32, copy[8..12], format_version, .little);
    std.mem.writeInt(u32, copy[12..16], Column.count + 1, .little);
    try testing.expectError(error.BadSidecar, read(gpa, copy, &global));
}

// **The fuzz sweep**, `resolve/iface_bytes.zig`'s shape: a real sidecar's
// bytes mutated exhaustively at every boundary and then at random, with
// every mutation required to end in an error or in a table that `verify`
// accepts. Deterministic, and run under `zig build test`, which is Debug, so
// a read past a slice is a panic rather than a silent wrong answer.
test "fuzz: a mutated sidecar never reads back as an unverified one" {
    var p = try TestProject.initWith(testing.allocator, &.{
        .{ .path = "F.beni", .source =
        \\pub type Tree a
        \\    = Leaf
        \\    | Node (Tree a) a (Tree a)
        \\
        \\
        \\pub sameTree : Tree Int, Tree Int -> Bool
        \\sameTree a b =
        \\    a == b
        \\
        \\
        \\pub sameRecord : { name : String, value : Int }, { name : String, value : Int } -> Bool
        \\sameRecord a b =
        \\    a == b
        \\
        \\
        \\pub bigger : a, a -> a
        \\    where a.compare : a, a -> Order
        \\bigger a b =
        \\    if a < b then b else a
        \\
        \\
        \\pub used : Int
        \\used =
        \\    bigger 1 2
        \\
        },
    }, .{ .phases = Session.check_phases });
    defer p.deinit();

    const gpa = testing.allocator;
    const m = p.module("F").?;
    const table = &p.session.checked.dispatch[m.int()];
    const bytes = try write(gpa, table, &p.session.graph, &p.session.checked.types, &p.session.interner);
    defer gpa.free(bytes);
    // The fixture has to be big enough for the sweep to mean something.
    try testing.expect(bytes.len > 256);

    var loaded_count: usize = 0;
    var attempts: usize = 0;

    const check = struct {
        fn go(mutated: []const u8, interner: *const InternPool.Global, ok: *usize) !void {
            var back = read(testing.allocator, mutated, interner) catch |err| switch (err) {
                error.BadSidecar, error.UnknownSymbol => return,
                error.OutOfMemory => return err,
            };
            defer back.deinit(testing.allocator);
            try testing.expect(verify(&back));
            ok.* += 1;
        }
    }.go;

    {
        var len: usize = 0;
        while (len <= bytes.len) : (len += if (len < body_start) 1 else 4) {
            attempts += 1;
            try check(bytes[0..len], &p.session.interner, &loaded_count);
        }
    }
    {
        const copy = try gpa.dupe(u8, bytes);
        defer gpa.free(copy);
        for (0..body_start) |i| {
            for (0..8) |bit| {
                copy[i] ^= @as(u8, 1) << @intCast(bit);
                attempts += 1;
                try check(copy, &p.session.interner, &loaded_count);
                copy[i] ^= @as(u8, 1) << @intCast(bit);
            }
        }
    }
    {
        const copy = try gpa.dupe(u8, bytes);
        defer gpa.free(copy);
        for (body_start..bytes.len) |i| {
            for ([_]u8{ 0x01, 0x80 }) |mask| {
                copy[i] ^= mask;
                attempts += 1;
                try check(copy, &p.session.interner, &loaded_count);
                copy[i] ^= mask;
            }
        }
    }
    {
        var prng: std.Random.DefaultPrng = .init(0xD15_A7CE);
        const random = prng.random();
        const copy = try gpa.dupe(u8, bytes);
        defer gpa.free(copy);
        for (0..30_000) |_| {
            const at = random.uintLessThan(usize, bytes.len);
            const was = copy[at];
            copy[at] = random.int(u8);
            attempts += 1;
            try check(copy, &p.session.interner, &loaded_count);
            copy[at] = was;
        }
    }

    try testing.expect(loaded_count > 100);
    try testing.expect(attempts > 30_000);
}
