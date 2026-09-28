//! The dispatch table as BYTES — the cache entry's sidecar (docs/design/
//! checker.md §7, *The cache entry, and the sidecar beside the record*).
//!
//! **Why the sidecar exists at all.** The dispatch table is the one product
//! of the solver the backend needs and nothing can reconstruct without
//! solving: every method call's callee, every `?`'s shape, every evidence
//! parameter and every derived function the module emits. A cache that held
//! only the record could give `beni check` its skip and would give `beni
//! build` nothing, and `run/` and `emit/` are exactly where a serialization
//! bug shows up as a wrong PROGRAM rather than a wrong message.
//!
//! **It is also where a silent miscompile can hide**, which is why this file
//! is written the way it is. `plans/m4-plan.md` §8 risk 2 names the
//! configuration: a cached callee and a recompiled caller computing the
//! hidden-parameter order independently. `--roundtrip-dispatch` on a build
//! whose evidence crosses modules is one of the two things standing between
//! that and a wrong program, and a warm build from the cache is the other.
//!
//! **Format v3** carries checker-v2.md §13.1's tree record: the `terms` and
//! `args` of every evidence tree, one `site` per instruction, `decls` with
//! their arity and calling convention (§12.5; byte 10 of the row, which
//! format v2 did not have), the `lets`,
//! `requirements`, each derived function's `contexts` and `body`. Version 1
//! held the flat sites and `parts` of static-dispatch-spike.md §7.1; a v1 or
//! v2 sidecar is a miss. Version 4 widens a context entry's `param`
//! to a `u32` in the same 8-byte row: a record past 65 535 fields has that
//! many positions.
//!
//! ```
//! header    magic "BENIDSP\x00" (8)   format_version: u32   column_count: u32
//! table     column_count × { offset: u32, len: u32 }        offsets from byte 0
//! columns   in table order, each 4-byte aligned, gaps zero-filled
//! ```
//!
//! **Two in-memory fields are session-relative and neither may reach the
//! bytes**, for the purity rule `checker.md` §7 gives. `Term.Ext.module` and
//! `Term.ExtDerivedUse.module` are a `Graph.Index` and become an index into
//! `module_refs`, each row `(package, module name)`; `Shape.nominal` and
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
//! `resolve/iface_bytes.zig` established — including the tree's one
//! structural rule, that every argument's term index is greater than its
//! owner's, so a file cannot hand the backend a cycle.

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
pub const format_version: u32 = 4;

pub const Column = enum(u32) {
    terms,
    args,
    sites,
    decls,
    lets,
    requirements,
    contexts,
    derived,
    tries,
    symbols,
    module_refs,
    type_refs,
    strings,

    pub const count: u32 = @typeInfo(Column).@"enum".fields.len;

    /// Bytes per element. `strings` is the one column whose `len` is a BYTE
    /// count rather than an element count, so its width is 1 by definition.
    pub fn width(c: Column) u32 {
        return switch (c) {
            .terms => term_bytes,
            .args => 4,
            .sites => 16,
            .decls => 12,
            .lets => 12,
            .requirements => 12,
            .contexts => 8,
            .derived => 32,
            .tries => 8,
            .symbols => 4,
            .module_refs => 8,
            .type_refs => 12,
            .strings => 1,
        };
    }
};

/// A `Term` is a tagged union of several payloads, so it is written as one
/// fixed-width row: `tag`, a second tag byte (the binder of a `param`, the
/// kind of an `ext_derived`), two padding bytes, two operand words (a
/// `param`'s `k` is the second, a `u32` since format 4)
/// and the `args` range.
const term_bytes: u32 = 20;

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

    const terms = try gpa.alloc(u8, d.terms.len * term_bytes);
    defer gpa.free(terms);
    for (d.terms, 0..) |t, i| try w.writeTerm(terms[i * term_bytes ..][0..term_bytes], t);

    const args = try gpa.alloc(u8, d.args.len * 4);
    defer gpa.free(args);
    for (d.args, 0..) |a, i| std.mem.writeInt(u32, args[i * 4 ..][0..4], a.int(), .little);

    const sites = try gpa.alloc(u8, d.sites.len * Column.sites.width());
    defer gpa.free(sites);
    for (d.sites, 0..) |s, i| {
        const row = sites[i * 16 ..][0..16];
        std.mem.writeInt(u32, row[0..4], @intFromEnum(s.inst), .little);
        std.mem.writeInt(u32, row[4..8], @intFromEnum(s.callee), .little);
        writeRange(row[8..16], s.evidence);
    }

    const decls = try gpa.alloc(u8, d.decls.len * Column.decls.width());
    defer gpa.free(decls);
    @memset(decls, 0);
    for (d.decls, 0..) |info, i| {
        const row = decls[i * 12 ..][0..12];
        writeRange(row[0..8], info.requirements);
        std.mem.writeInt(u16, row[8..10], info.value_arity, .little);
        row[10] = @intFromEnum(info.convention);
    }

    const lets = try gpa.alloc(u8, d.lets.len * Column.lets.width());
    defer gpa.free(lets);
    for (d.lets, 0..) |let, i| {
        const row = lets[i * 12 ..][0..12];
        std.mem.writeInt(u32, row[0..4], @intFromEnum(let.inst), .little);
        writeRange(row[4..12], let.requirements);
    }

    const requirements = try gpa.alloc(u8, d.requirements.len * Column.requirements.width());
    defer gpa.free(requirements);
    @memset(requirements, 0);
    for (d.requirements, 0..) |e, i| {
        const row = requirements[i * 12 ..][0..12];
        std.mem.writeInt(u16, row[0..2], e.quantified, .little);
        std.mem.writeInt(u32, row[4..8], if (e.var_name.unwrap()) |s| try w.string(s) else no_string, .little);
        std.mem.writeInt(u32, row[8..12], try w.string(e.method), .little);
    }

    const contexts = try gpa.alloc(u8, d.contexts.len * Column.contexts.width());
    defer gpa.free(contexts);
    @memset(contexts, 0);
    for (d.contexts, 0..) |c, i| {
        const row = contexts[i * 8 ..][0..8];
        std.mem.writeInt(u32, row[0..4], c.param, .little);
        std.mem.writeInt(u32, row[4..8], try w.string(c.method), .little);
    }

    const derived = try gpa.alloc(u8, d.derived.len * Column.derived.width());
    defer gpa.free(derived);
    @memset(derived, 0);
    for (d.derived, 0..) |row_in, i| {
        const row = derived[i * 32 ..][0..32];
        row[0] = @intFromEnum(row_in.kind);
        try w.writeShape(row[4..16], row_in.shape);
        writeRange(row[16..24], row_in.context);
        writeRange(row[24..32], row_in.body);
    }

    const symbols = try gpa.alloc(u8, d.symbols.len * 4);
    defer gpa.free(symbols);
    for (d.symbols, 0..) |s, i| std.mem.writeInt(u32, symbols[i * 4 ..][0..4], try w.string(s), .little);

    const tries = try gpa.alloc(u8, d.tries.len * Column.tries.width());
    defer gpa.free(tries);
    @memset(tries, 0);
    for (d.tries, 0..) |t, i| {
        const row = tries[i * 8 ..][0..8];
        std.mem.writeInt(u32, row[0..4], @intFromEnum(t.inst), .little);
        row[4] = @intFromEnum(t.shape);
    }

    // The two reference tables are complete only now, because writing a
    // term or a shape is what appends to them.
    const module_refs = try gpa.alloc(u8, w.module_refs.items.len * Column.module_refs.width());
    defer gpa.free(module_refs);
    @memset(module_refs, 0);
    for (w.module_refs.items, 0..) |r, i| {
        const row = module_refs[i * 8 ..][0..8];
        row[0] = @intFromEnum(r.package);
        std.mem.writeInt(u32, row[4..8], r.name_offset, .little);
    }
    const type_refs = try gpa.alloc(u8, w.type_refs.items.len * Column.type_refs.width());
    defer gpa.free(type_refs);
    @memset(type_refs, 0);
    for (w.type_refs.items, 0..) |r, i| {
        const row = type_refs[i * 12 ..][0..12];
        row[0] = @intFromEnum(r.package);
        std.mem.writeInt(u32, row[4..8], r.module_offset, .little);
        std.mem.writeInt(u32, row[8..12], r.name_offset, .little);
    }

    const columns = [Column.count][]const u8{
        terms,
        args,
        sites,
        decls,
        lets,
        requirements,
        contexts,
        derived,
        tries,
        symbols,
        module_refs,
        type_refs,
        w.strings.items,
    };
    const lengths = [Column.count]u32{
        @intCast(d.terms.len),
        @intCast(d.args.len),
        @intCast(d.sites.len),
        @intCast(d.decls.len),
        @intCast(d.lets.len),
        @intCast(d.requirements.len),
        @intCast(d.contexts.len),
        @intCast(d.derived.len),
        @intCast(d.tries.len),
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
    module_refs: std.ArrayList(ModuleRow) = .empty,
    type_refs: std.ArrayList(TypeRow) = .empty,
    /// Row → its index in `module_refs` / `type_refs`, so the tables are not
    /// searched linearly once per term and per derived row's shape, which
    /// would make writing a module of n types' dispatch table O(n²). The rows keep
    /// their first-occurrence order, so the bytes do not move.
    module_index: std.AutoHashMapUnmanaged(ModuleRow, u32) = .empty,
    type_index: std.AutoHashMapUnmanaged(TypeRow, u32) = .empty,

    const ModuleRow = struct { package: SourceStore.Package, name_offset: u32 };
    const TypeRow = struct { package: SourceStore.Package, module_offset: u32, name_offset: u32 };

    fn deinit(w: *Writer) void {
        w.strings.deinit(w.gpa);
        w.seen.deinit(w.gpa);
        w.module_refs.deinit(w.gpa);
        w.type_refs.deinit(w.gpa);
        w.module_index.deinit(w.gpa);
        w.type_index.deinit(w.gpa);
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
        const row: ModuleRow = .{ .package = package, .name_offset = name_offset };
        const gop = try w.module_index.getOrPut(w.gpa, row);
        if (gop.found_existing) return gop.value_ptr.*;
        gop.value_ptr.* = @intCast(w.module_refs.items.len);
        try w.module_refs.append(w.gpa, row);
        return gop.value_ptr.*;
    }

    fn typeRef(w: *Writer, id: Types.TypeId) Allocator.Error!u32 {
        const named = w.types.named(id) orelse return no_ref;
        const module_offset = try w.string(named.module);
        const name_offset = try w.string(named.name);
        const row: TypeRow = .{ .package = named.package, .module_offset = module_offset, .name_offset = name_offset };
        const gop = try w.type_index.getOrPut(w.gpa, row);
        if (gop.found_existing) return gop.value_ptr.*;
        gop.value_ptr.* = @intCast(w.type_refs.items.len);
        try w.type_refs.append(w.gpa, row);
        return gop.value_ptr.*;
    }

    fn writeTerm(w: *Writer, row: *[term_bytes]u8, t: Dispatch.Term) Allocator.Error!void {
        @memset(row, 0);
        row[0] = @intFromEnum(std.meta.activeTag(t));
        switch (t) {
            .param => |p| {
                row[1] = @intFromEnum(std.meta.activeTag(p.binder));
                std.mem.writeInt(u32, row[8..12], p.k, .little);
                switch (p.binder) {
                    .decl => {},
                    .let => |inst| std.mem.writeInt(u32, row[4..8], @intFromEnum(inst), .little),
                    .derived => |index| std.mem.writeInt(u32, row[4..8], index, .little),
                }
            },
            .top => |u| std.mem.writeInt(u32, row[4..8], @intFromEnum(u.decl), .little),
            .ext => |e| {
                std.mem.writeInt(u32, row[4..8], try w.moduleRef(e.module), .little);
                std.mem.writeInt(u32, row[8..12], @intFromEnum(e.value), .little);
            },
            .primitive => |p| std.mem.writeInt(u32, row[4..8], @intFromEnum(p), .little),
            .derived => |u| std.mem.writeInt(u32, row[4..8], u.index, .little),
            .ext_derived => |u| {
                row[1] = @intFromEnum(u.kind);
                std.mem.writeInt(u32, row[4..8], try w.moduleRef(u.module), .little);
                std.mem.writeInt(u32, row[8..12], try w.typeRef(u.type), .little);
            },
            .undetermined, .field => {},
        }
        writeRange(row[12..20], t.argsOf());
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

/// `read`, through `getOrPut`. The cache's cross-process load is the case that
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
    const col = struct {
        fn at(b: []const u8, o: [Column.count]u32, c: Column) []const u8 {
            return b[o[@intFromEnum(c)]..];
        }
    }.at;

    var out: Loaded = .empty;
    errdefer out.deinit(gpa);

    // The reference tables first: every term indexes them, and `resolve`
    // needs them whole.
    {
        const in_bytes = col(bytes, offsets, .module_refs);
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
        const in_bytes = col(bytes, offsets, .type_refs);
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
        const in_bytes = col(bytes, offsets, .symbols);
        const symbols = try gpa.alloc(Symbol, lengths[@intFromEnum(Column.symbols)]);
        out.table.symbols = symbols;
        for (symbols, 0..) |*s, i| {
            s.* = try symbolAt(blob, std.mem.readInt(u32, in_bytes[i * 4 ..][0..4], .little), in) orelse
                return error.BadSidecar;
        }
    }
    {
        const in_bytes = col(bytes, offsets, .terms);
        const terms = try gpa.alloc(Dispatch.Term, lengths[@intFromEnum(Column.terms)]);
        out.table.terms = terms;
        for (terms, 0..) |*t, i| {
            t.* = try readTerm(in_bytes[i * term_bytes ..][0..term_bytes], module_ref_count, type_ref_count);
        }
    }
    {
        const in_bytes = col(bytes, offsets, .args);
        const args = try gpa.alloc(Dispatch.TermIndex, lengths[@intFromEnum(Column.args)]);
        out.table.args = args;
        for (args, 0..) |*a, i| a.* = @enumFromInt(std.mem.readInt(u32, in_bytes[i * 4 ..][0..4], .little));
    }
    {
        const in_bytes = col(bytes, offsets, .sites);
        const sites = try gpa.alloc(Dispatch.Site, lengths[@intFromEnum(Column.sites)]);
        out.table.sites = sites;
        for (sites, 0..) |*s, i| {
            const row = in_bytes[i * 16 ..][0..16];
            s.* = .{
                .inst = @enumFromInt(std.mem.readInt(u32, row[0..4], .little)),
                .callee = @enumFromInt(std.mem.readInt(u32, row[4..8], .little)),
                .evidence = readRange(row[8..16]),
            };
        }
    }
    {
        const in_bytes = col(bytes, offsets, .decls);
        const decls = try gpa.alloc(Dispatch.DeclInfo, lengths[@intFromEnum(Column.decls)]);
        out.table.decls = decls;
        for (decls, 0..) |*info, i| {
            const row = in_bytes[i * 12 ..][0..12];
            info.* = .{
                .requirements = readRange(row[0..8]),
                .value_arity = std.mem.readInt(u16, row[8..10], .little),
                .convention = std.enums.fromInt(Dispatch.Convention, row[10]) orelse return error.BadSidecar,
            };
        }
    }
    {
        const in_bytes = col(bytes, offsets, .lets);
        const lets = try gpa.alloc(Dispatch.LetInfo, lengths[@intFromEnum(Column.lets)]);
        out.table.lets = lets;
        for (lets, 0..) |*let, i| {
            const row = in_bytes[i * 12 ..][0..12];
            let.* = .{
                .inst = @enumFromInt(std.mem.readInt(u32, row[0..4], .little)),
                .requirements = readRange(row[4..12]),
            };
        }
    }
    {
        const in_bytes = col(bytes, offsets, .requirements);
        const requirements = try gpa.alloc(Dispatch.Requirement, lengths[@intFromEnum(Column.requirements)]);
        out.table.requirements = requirements;
        for (requirements, 0..) |*e, i| {
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
        const in_bytes = col(bytes, offsets, .contexts);
        const contexts = try gpa.alloc(Dispatch.ContextEntry, lengths[@intFromEnum(Column.contexts)]);
        out.table.contexts = contexts;
        for (contexts, 0..) |*c, i| {
            const row = in_bytes[i * 8 ..][0..8];
            c.* = .{
                .param = std.mem.readInt(u32, row[0..4], .little),
                .method = try symbolAt(blob, std.mem.readInt(u32, row[4..8], .little), in) orelse
                    return error.BadSidecar,
            };
        }
    }
    {
        const in_bytes = col(bytes, offsets, .derived);
        const derived = try gpa.alloc(Dispatch.Derived, lengths[@intFromEnum(Column.derived)]);
        out.table.derived = derived;
        for (derived, 0..) |*row_out, i| {
            const row = in_bytes[i * 32 ..][0..32];
            row_out.* = .{
                .kind = std.enums.fromInt(Dispatch.Derived.Kind, row[0]) orelse return error.BadSidecar,
                .shape = try readShape(row[4..16], type_ref_count),
                .context = readRange(row[16..24]),
                .body = readRange(row[24..32]),
            };
        }
    }
    {
        const in_bytes = col(bytes, offsets, .tries);
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

/// A `Term` row. The two reference fields come back as INDICES wearing a
/// `Graph.Index`/`TypeId` hat; `resolve` is what turns them into session ids,
/// and nothing between here and there may read them.
fn readTerm(row: *const [term_bytes]u8, module_refs: u32, type_refs: u32) ReadError!Dispatch.Term {
    const tag = std.enums.fromInt(std.meta.Tag(Dispatch.Term), row[0]) orelse return error.BadSidecar;
    const a = std.mem.readInt(u32, row[4..8], .little);
    const b = std.mem.readInt(u32, row[8..12], .little);
    const args = readRange(row[12..20]);
    // Only the four terms that name a function take arguments; any other
    // row with a non-empty range is not one this writer produced.
    switch (tag) {
        .top, .ext, .derived, .ext_derived => {},
        else => if (args.len != 0) return error.BadSidecar,
    }
    return switch (tag) {
        .param => blk: {
            const binder_tag = std.enums.fromInt(std.meta.Tag(Dispatch.Binder), row[1]) orelse return error.BadSidecar;
            const binder: Dispatch.Binder = switch (binder_tag) {
                .decl => .decl,
                .let => .{ .let = @enumFromInt(a) },
                .derived => .{ .derived = a },
            };
            break :blk .{ .param = .{ .binder = binder, .k = b } };
        },
        .top => .{ .top = .{ .decl = @enumFromInt(a), .args = args } },
        .ext => blk: {
            if (a != no_ref and a >= module_refs) return error.BadSidecar;
            break :blk .{ .ext = .{ .module = @enumFromInt(a), .value = @enumFromInt(b), .args = args } };
        },
        .primitive => .{
            .primitive = std.enums.fromInt(Dispatch.Primitive, std.math.cast(u8, a) orelse
                return error.BadSidecar) orelse return error.BadSidecar,
        },
        .derived => .{ .derived = .{ .index = a, .args = args } },
        .ext_derived => blk: {
            if (a != no_ref and a >= module_refs) return error.BadSidecar;
            if (b != no_ref and b >= type_refs) return error.BadSidecar;
            break :blk .{ .ext_derived = .{
                .module = @enumFromInt(a),
                .type = @enumFromInt(b),
                .kind = std.enums.fromInt(Dispatch.Derived.Kind, row[1]) orelse return error.BadSidecar,
                .args = args,
            } };
        },
        .undetermined => .undetermined,
        .field => .field,
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

/// Whether every index and range in `l` stays inside the column it points
/// at, and the trees are trees. `decode` runs this before handing a sidecar
/// back, so a caller never has to trust one — which is what makes a corrupt
/// file a miss rather than a wrong answer, an out-of-bounds read or a walk
/// that never ends.
///
/// What it checks: every term's `args` range fits `args`, and every argument
/// it names is a LATER term (the pre-order rule that makes the table
/// acyclic); every `top` term names a declaration (`decls` has one row per
/// `Bir.Decl`); every `derived` term and `Binder.derived` names a `derived`
/// row; every site's callee is a term or none, and its roots fit `args` and
/// name terms; every `derived` row's `context` fits `contexts`, its `body`
/// fits `args` and names terms, and a record shape fits `symbols`; every
/// `decls` and `lets` range fits `requirements`. The two reference indices
/// were bounded as they were read. NOT checked, because the reader has
/// neither table: an `ext` term's value index against the imported
/// interface, and a site's instruction against the Bir — the entry's key
/// pins both (it contains the source hash and every import's key).
pub fn verify(l: *const Loaded) bool {
    const d = &l.table;
    const terms = d.terms.len;
    for (d.terms, 0..) |t, i| {
        const r = t.argsOf();
        if (!rangeOk(r, d.args.len)) return false;
        for (d.argsAt(r)) |arg| {
            if (arg.int() >= terms or arg.int() <= i) return false;
        }
        switch (t) {
            .derived => |u| if (u.index >= d.derived.len) return false,
            // `decls` has one row per `Bir.Decl` of the module (`finish`),
            // so it bounds a `top` without the Bir: `Lower.termName` indexes
            // `bir.decls` with only a debug assert.
            .top => |u| if (u.decl.int() >= d.decls.len) return false,
            .param => |p| switch (p.binder) {
                .derived => |index| if (index >= d.derived.len) return false,
                else => {},
            },
            else => {},
        }
    }
    for (d.sites) |s| {
        if (s.callee.unwrap()) |c| if (c.int() >= terms) return false;
        if (!rootsOk(d, s.evidence)) return false;
    }
    for (d.derived) |row| {
        if (!rangeOk(row.context, d.contexts.len)) return false;
        if (!rootsOk(d, row.body)) return false;
        switch (row.shape) {
            .record => |r| if (!rangeOk(r, d.symbols.len)) return false,
            else => {},
        }
    }
    for (d.decls) |info| {
        if (!rangeOk(info.requirements, d.requirements.len)) return false;
        // `Convention.of`'s first rule: evidence is exactly what makes a
        // value not `plain`, so a row that says otherwise was not written
        // by `finish`.
        if ((info.convention == .plain) != (info.requirements.len == 0)) return false;
        // A thunk is a value of non-function type: arity 0 by `of`.
        if (info.convention == .thunk and info.value_arity != 0) return false;
    }
    for (d.lets) |let| {
        if (!rangeOk(let.requirements, d.requirements.len)) return false;
    }
    return true;
}

fn rootsOk(d: *const Dispatch, r: Dispatch.Range) bool {
    if (!rangeOk(r, d.args.len)) return false;
    for (d.argsAt(r)) |root| {
        if (root.int() >= d.terms.len) return false;
    }
    return true;
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
pub fn resolve(l: *Loaded, graph: *const Graph, types: *const Types) void {
    const modules = @as(u32, @intCast(l.module_refs.len));
    const type_count = @as(u32, @intCast(l.type_refs.len));
    for (@constCast(l.table.terms)) |*t| resolveTerm(t, l, graph, types, modules, type_count);
    for (@constCast(l.table.derived)) |*row| {
        switch (row.shape) {
            .nominal => |at| row.shape = .{ .nominal = resolveType(l, graph, types, @intFromEnum(at), type_count) },
            else => {},
        }
    }
}

fn resolveTerm(
    t: *Dispatch.Term,
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
            .args = e.args,
        } },
        .ext_derived => |u| t.* = .{ .ext_derived = .{
            .module = resolveModule(l, graph, @intFromEnum(u.module), modules),
            .type = resolveType(l, graph, types, @intFromEnum(u.type), type_count),
            .kind = u.kind,
            .args = u.args,
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
const fuzzing = @import("../fuzzing.zig");

/// Two tables are equal in every byte the format carries. Symbols are
/// compared as TEXT, because the point of the `strings` column is that two
/// sessions may number the same name differently.
fn expectSameTable(a: *const Dispatch, b: *const Dispatch, interner: *const InternPool.Global) !void {
    try testing.expectEqualSlices(Dispatch.Term, a.terms, b.terms);
    try testing.expectEqualSlices(Dispatch.TermIndex, a.args, b.args);
    try testing.expectEqualSlices(Dispatch.Site, a.sites, b.sites);
    try testing.expectEqualSlices(Dispatch.Try, a.tries, b.tries);
    try testing.expectEqualSlices(Dispatch.DeclInfo, a.decls, b.decls);
    try testing.expectEqualSlices(Dispatch.LetInfo, a.lets, b.lets);
    try testing.expectEqualSlices(Dispatch.Derived, a.derived, b.derived);
    try testing.expectEqual(a.requirements.len, b.requirements.len);
    for (a.requirements, b.requirements) |x, y| {
        try testing.expectEqual(x.quantified, y.quantified);
        try testing.expectEqualStrings(optionalText(interner, x.var_name), optionalText(interner, y.var_name));
        try testing.expectEqualStrings(interner.slice(x.method), interner.slice(y.method));
    }
    try testing.expectEqual(a.contexts.len, b.contexts.len);
    for (a.contexts, b.contexts) |x, y| {
        try testing.expectEqual(x.param, y.param);
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
        if (table.requirements.len != 0) any_evidence = true;
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

/// The module whose sidecar the mutation tests below start from: derived
/// rows with a context and a nominal shape, parameter and derived terms, a
/// requirement, and a reference to a type.
const mutation_fixture: TestProject.Module = .{ .path = "F.beni", .source =
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
};

/// Where column `c`'s first row starts in `bytes`, from the column table.
fn columnAt(bytes: []const u8, c: Column) u32 {
    return std.mem.readInt(u32, bytes[header_bytes + @intFromEnum(c) * 8 ..][0..4], .little);
}

/// The length word of column `c` in the column table.
fn columnLen(bytes: []u8, c: Column) *[4]u8 {
    return bytes[header_bytes + @intFromEnum(c) * 8 + 4 ..][0..4];
}

test "each check the reader makes refuses the one mutation aimed at it" {
    // One mutation per check `decode` makes on the rows this sidecar has,
    // each applied alone to a copy of a sidecar that loads. The header and
    // the tree rules `verify` states are the tests above and below; these
    // are the column table, the strings and every row's own bytes.
    var p = try TestProject.initWith(testing.allocator, &.{mutation_fixture}, .{ .phases = Session.check_phases });
    defer p.deinit();
    const gpa = testing.allocator;
    const interner = &p.session.interner;
    const table = &p.session.checked.dispatch[p.module("F").?.int()];
    const bytes = try write(gpa, table, &p.session.graph, &p.session.checked.types, interner);
    defer gpa.free(bytes);
    {
        var back = try read(gpa, bytes, interner);
        back.deinit(gpa);
    }
    // Every row a mutation below lands in is there, and `tries` is empty.
    for ([_]Column{ .terms, .decls, .derived, .type_refs }) |c| {
        try testing.expect(std.mem.readInt(u32, columnLen(bytes, c), .little) != 0);
    }
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, columnLen(bytes, .tries), .little));
    const param: u32 = for (table.terms, 0..) |t, i| {
        if (t == .param) break @intCast(i);
    } else return error.TestUnexpectedResult;
    try testing.expect(table.derived[0].shape == .nominal);

    const terms = columnAt(bytes, .terms);
    const param_row = terms + param * term_bytes;
    const derived = columnAt(bytes, .derived);
    const type_ref = columnAt(bytes, .type_refs);
    const module_name = std.mem.readInt(u32, bytes[type_ref + 4 ..][0..4], .little);
    const strings = columnAt(bytes, .strings);

    const Mutation = struct {
        what: []const u8,
        /// Where to write, and the little-endian word or byte to write.
        at: u32,
        word: ?u32 = null,
        byte: u8 = 0,
        /// A second word, for a mutation that is two writes.
        also: ?struct { at: u32, word: u32 } = null,
    };
    const tries_row = header_bytes + @intFromEnum(Column.tries) * 8;
    const mutations = [_]Mutation{
        // The first three go on the empty `tries`, so nothing but the column
        // table's checks stands between them and a sidecar that loads; the
        // third gives it one row, past the end of the file.
        .{ .what = "a column that starts inside the header", .at = tries_row, .word = header_bytes },
        .{ .what = "a column that starts off a four-byte boundary", .at = tries_row, .word = body_start + 1 },
        .{ .what = "a column that runs past the end", .at = tries_row, .word = @intCast(bytes.len - 4), .also = .{ .at = tries_row + 4, .word = 1 } },
        .{ .what = "a type reference's package no version defines", .at = type_ref, .byte = 0xff },
        .{ .what = "a string offset past the strings", .at = type_ref + 4, .word = 0xffff_fff0 },
        .{ .what = "a string whose length runs past the strings", .at = strings + module_name, .word = 0xffff },
        .{ .what = "a term tag no version defines", .at = param_row, .byte = 0xff },
        .{ .what = "a parameter term with arguments", .at = param_row + 16, .word = 1 },
        .{ .what = "a parameter's binder no version defines", .at = param_row + 1, .byte = 0xff },
        .{ .what = "a declaration's convention no version defines", .at = columnAt(bytes, .decls) + 10, .byte = 0xff },
        .{ .what = "a derived kind no version defines", .at = derived, .byte = 0xff },
        .{ .what = "a derived shape no version defines", .at = derived + 4, .byte = 0xff },
        .{ .what = "a nominal shape naming a type reference past the table", .at = derived + 8, .word = 1 },
    };
    var loaded: usize = 0;
    for (mutations) |m| {
        const copy = try gpa.dupe(u8, bytes);
        defer gpa.free(copy);
        if (m.word) |w| std.mem.writeInt(u32, copy[m.at..][0..4], w, .little) else copy[m.at] = m.byte;
        if (m.also) |a| std.mem.writeInt(u32, copy[a.at..][0..4], a.word, .little);
        var back = read(gpa, copy, interner) catch |err| switch (err) {
            error.BadSidecar => continue,
            else => return err,
        };
        back.deinit(gpa);
        std.debug.print("read back a sidecar with {s}\n", .{m.what});
        loaded += 1;
    }
    try testing.expectEqual(@as(usize, 0), loaded);
}

// **The fuzz sweep**, opt-in (`zig build fuzz`, `fuzzing.zig`), in
// `resolve/iface_bytes.zig`'s shape: the sidecar above mutated
// exhaustively at every boundary and then at random, with every mutation
// required to end in an error or in a table that `verify` accepts.
// Deterministic, and Debug, so a read past a slice is a panic rather than a
// silent wrong answer.

/// Which part of the mutation sweep below a test runs: they are three tests so
/// that the test runner's shards can run them at the same time.
const SweepPart = enum { systematic, random_first, random_second };

test "fuzz: a sidecar truncated or with a bit flipped never reads back as an unverified one" {
    try fuzzing.skipUnlessFuzzing();
    try mutatedSidecarSweep(.systematic);
}

test "fuzz: a sidecar with random bytes overwritten never reads back as an unverified one, first seed" {
    try fuzzing.skipUnlessFuzzing();
    try mutatedSidecarSweep(.random_first);
}

test "fuzz: a sidecar with random bytes overwritten never reads back as an unverified one, second seed" {
    try fuzzing.skipUnlessFuzzing();
    try mutatedSidecarSweep(.random_second);
}

/// Random single-byte writes per random part of the sweep.
const random_writes = 15_000;

fn mutatedSidecarSweep(part: SweepPart) !void {
    var p = try TestProject.initWith(testing.allocator, &.{mutation_fixture}, .{ .phases = Session.check_phases });
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

    if (part == .systematic) {
        var len: usize = 0;
        while (len <= bytes.len) : (len += if (len < body_start) 1 else 4) {
            attempts += 1;
            try check(bytes[0..len], &p.session.interner, &loaded_count);
        }
    }
    if (part == .systematic) {
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
    if (part == .systematic) {
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
    if (part != .systematic) {
        var prng: std.Random.DefaultPrng = .init(if (part == .random_first) 0xD15_A7CE else ~@as(u64, 0xD15_A7CE));
        const random = prng.random();
        const copy = try gpa.dupe(u8, bytes);
        defer gpa.free(copy);
        for (0..random_writes) |_| {
            const at = random.uintLessThan(usize, bytes.len);
            const was = copy[at];
            copy[at] = random.int(u8);
            attempts += 1;
            try check(copy, &p.session.interner, &loaded_count);
            copy[at] = was;
        }
    }

    try testing.expect(loaded_count > 100);
    try testing.expect(attempts >= @as(usize, if (part == .systematic) 1_000 else random_writes));
}

test "an argument that does not follow its owner is BadSidecar, not a cycle handed to the backend" {
    // checker-v2.md §13.1: terms are allocated in
    // pre-order, so every argument's index is greater than its owner's, and
    // that is what lets every walker recurse without a guard. A file is not
    // trusted to keep the rule: `verify` checks it, so a sidecar whose term
    // names ITSELF as an argument is a miss.
    const gpa = testing.allocator;
    var global = try InternPool.Global.init(gpa);
    defer global.deinit(gpa);
    const graph: Graph = .empty;
    const types: Types = .empty;

    const good_terms = [_]Dispatch.Term{
        .{ .top = .{ .decl = @enumFromInt(0), .args = .{ .start = 0, .len = 1 } } },
        .{ .primitive = .strict_eq },
    };
    const good_args = [_]Dispatch.TermIndex{@enumFromInt(1)};
    const decls = [_]Dispatch.DeclInfo{.{}};
    const good: Dispatch = .{ .terms = &good_terms, .args = &good_args, .decls = &decls };
    const bytes = try write(gpa, &good, &graph, &types, &global);
    defer gpa.free(bytes);
    var loaded = try read(gpa, bytes, &global);
    loaded.deinit(gpa);

    const cyclic_args = [_]Dispatch.TermIndex{@enumFromInt(0)};
    const cyclic: Dispatch = .{ .terms = &good_terms, .args = &cyclic_args, .decls = &decls };
    const bad = try write(gpa, &cyclic, &graph, &types, &global);
    defer gpa.free(bad);
    try testing.expectError(error.BadSidecar, read(gpa, bad, &global));
}

test "a top term naming a declaration past the module's is BadSidecar" {
    // `Lower.termName` indexes `bir.decls` by a `top`
    // term's declaration with only a debug assert, so an index past the
    // module's declarations must not survive the load. `decls` has one row
    // per `Bir.Decl` (`Module.zig`'s P6 writes one each), which bounds it without
    // the Bir.
    const gpa = testing.allocator;
    var global = try InternPool.Global.init(gpa);
    defer global.deinit(gpa);
    const graph: Graph = .empty;
    const types: Types = .empty;
    const decls = [_]Dispatch.DeclInfo{ .{}, .{} };

    const inside = [_]Dispatch.Term{.{ .top = .{ .decl = @enumFromInt(1) } }};
    const ok: Dispatch = .{ .terms = &inside, .decls = &decls };
    const bytes = try write(gpa, &ok, &graph, &types, &global);
    defer gpa.free(bytes);
    var loaded = try read(gpa, bytes, &global);
    loaded.deinit(gpa);

    const past = [_]Dispatch.Term{.{ .top = .{ .decl = @enumFromInt(2) } }};
    const bad_table: Dispatch = .{ .terms = &past, .decls = &decls };
    const bad = try write(gpa, &bad_table, &graph, &types, &global);
    defer gpa.free(bad);
    try testing.expectError(error.BadSidecar, read(gpa, bad, &global));
}

test "a decl row whose convention finish could not have written is BadSidecar" {
    // checker-v2.md §12.5: `Convention.of` makes a row `plain` exactly
    // when it has no requirements, and a `thunk` only at arity 0. A row that
    // says otherwise would hand `Lower` a definition and its callers two
    // different conventions, so it is refused on load like any other
    // malformed table.
    const gpa = testing.allocator;
    var global = try InternPool.Global.init(gpa);
    defer global.deinit(gpa);
    const graph: Graph = .empty;
    const types: Types = .empty;
    const eq = try global.getOrPut(gpa, "eq");
    const requirements = [_]Dispatch.Requirement{.{ .quantified = 0, .var_name = .none, .method = eq }};
    const one: Dispatch.Range = .{ .start = 0, .len = 1 };

    const rows = [_]struct { info: Dispatch.DeclInfo, ok: bool }{
        .{ .info = .{}, .ok = true },
        .{ .info = .{ .requirements = one, .value_arity = 2, .convention = .function }, .ok = true },
        .{ .info = .{ .requirements = one, .convention = .thunk }, .ok = true },
        // `plain` with a requirement, and a convention with none.
        .{ .info = .{ .requirements = one, .value_arity = 2, .convention = .plain }, .ok = false },
        .{ .info = .{ .value_arity = 2, .convention = .function }, .ok = false },
        // A thunk is not a function.
        .{ .info = .{ .requirements = one, .value_arity = 1, .convention = .thunk }, .ok = false },
    };
    for (rows) |row| {
        const decls = [_]Dispatch.DeclInfo{row.info};
        const table: Dispatch = .{ .decls = &decls, .requirements = &requirements };
        const bytes = try write(gpa, &table, &graph, &types, &global);
        defer gpa.free(bytes);
        if (row.ok) {
            var loaded = try read(gpa, bytes, &global);
            defer loaded.deinit(gpa);
            try testing.expectEqual(row.info.convention, loaded.table.decls[0].convention);
        } else {
            try testing.expectError(error.BadSidecar, read(gpa, bytes, &global));
        }
    }
    // Byte 10 past the enum is refused by the decoder itself.
    const decls = [_]Dispatch.DeclInfo{.{}};
    const table: Dispatch = .{ .decls = &decls };
    const bytes = try write(gpa, &table, &graph, &types, &global);
    defer gpa.free(bytes);
    const at = std.mem.readInt(u32, bytes[header_bytes + 8 * @intFromEnum(Column.decls) ..][0..4], .little);
    bytes[at + 10] = 3;
    try testing.expectError(error.BadSidecar, read(gpa, bytes, &global));
}
