//! The interface record as BYTES (docs/design/checker.md §7, *The
//! serialized form*), and the hash over them (`fast-compiler.md` §8's *The
//! interface hash, and slice zero*).
//!
//! `write` turns an `Interface` into the format; `read` turns the format
//! back into an `Interface`; `hash` is `SipHash128(1, 3)` over the bytes in
//! full. The record's bytes ARE its contract — §8.1's firewall compares
//! them — so the format is specified beside the in-memory record rather
//! than wherever a cache happens to write it, and this file is that
//! specification made executable.
//!
//! ```
//! header    magic "BENIIFC\x00" (8)   format_version: u32   column_count: u32
//! table     column_count × { offset: u32, len: u32 }        offsets from byte 0
//! columns   in table order, each 4-byte aligned, gaps zero-filled
//! ```
//!
//! **Every scalar is little-endian by definition of the format**, converted
//! on write and on read, so the bytes — and therefore the hash — are a
//! function of the source on any host. What is host-specific is a *cache*,
//! not a record.
//!
//! **The one column that changes shape is `symbols`.** In memory it is
//! `[]Symbol`, an index into the session interner whose numbering depends on
//! which worker interned which file (`InternPool`'s header). On disk
//! `symbols[i]` is a byte offset into a `strings` blob, and loading turns
//! each string back into a symbol. The column keeps its length and its
//! order — every `SymbolIndex` in every other column means what it meant —
//! and only its contents are translated. Two slots holding the same text
//! share one `strings` record; the blob is built in first-occurrence order
//! over the column, so sharing does not move a byte.
//!
//! **Re-interning goes through `InternPool.Global.find`, never `getOrPut`.**
//! `read` runs on the worker that checked the module and `Global` is
//! thread-confined (`InternPool`'s header), so a load that APPENDED to the
//! pool would race with every other worker's. Within one session the lookup
//! cannot legitimately miss — every string in a record that session wrote
//! was interned by that session — so a miss is `error.UnknownSymbol`, which
//! the caller reports as `internal`. M4-1's cross-process load is the case
//! that can miss; it runs serially before any worker starts, and `getOrPut`
//! belongs there.
//!
//! **Loading validates, and a bad record is a MISS.** A wrong magic, an
//! unknown `format_version`, a short file, a column whose offset or length
//! leaves the file, an index that leaves its column, or a `strings` record
//! that runs past the blob: each is `error.BadRecord`, which a cache turns
//! into "recompute from source". None of them is a diagnostic and none is
//! an exit code — a stale cache must be indistinguishable from a cold
//! build. (checker.md §7 writes this as "returns null"; an error is the
//! same shape with a name on each failure, and `UnknownSymbol` needs to be
//! distinguishable from `BadRecord` because only the second one is a MISS.)
//!
//! What the bytes do NOT contain: `Interface.Provenance`, which is
//! `Bir.DeclIndex`es and meaningless once the Bir is gone; `Types.ref_ids`,
//! recomputed by `resolveRefs` once per module per build; any `Symbol`,
//! replaced by text above; any `Graph.Index`, of which the record holds
//! none since `type_refs` landed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const SourceStore = @import("../SourceStore.zig");
const Interface = @import("Interface.zig");

const Symbol = InternPool.Symbol;

/// First eight bytes of every record.
pub const magic = "BENIIFC\x00";

/// Bumped whenever the meaning of any byte changes. An interface change is
/// a version bump and a cache discard, never a migration into spare bytes:
/// the alignment padding below is padding and NOT a reserved field
/// (`plans/m4-plan.md` D4).
pub const format_version: u32 = 1;

/// The eleven columns, in this order and no other. `terms` is split into
/// its three SoA columns rather than written as a row of 12 bytes, because
/// that is what the record already is and what §8.3 wants to map.
pub const Column = enum(u32) {
    values,
    types,
    ctors,
    schemes,
    term_tags,
    term_lhs,
    term_rhs,
    extra,
    type_refs,
    symbols,
    strings,

    pub const count: u32 = @typeInfo(Column).@"enum".fields.len;

    /// Bytes per element. `strings` is the one column whose `len` is a BYTE
    /// count rather than an element count, so its width is 1 by definition.
    pub fn width(c: Column) u32 {
        return switch (c) {
            .values => 12,
            .types => 16,
            .ctors => 20,
            .schemes => 12,
            .term_tags => 1,
            .term_lhs, .term_rhs, .extra, .symbols => 4,
            .type_refs => 12,
            .strings => 1,
        };
    }
};

const header_bytes: u32 = 16; // magic(8) + format_version(4) + column_count(4)
const table_bytes: u32 = Column.count * 8;
const body_start: u32 = header_bytes + table_bytes;

pub const ReadError = error{
    /// The bytes are not a record this compiler can read: a wrong magic, an
    /// unknown version, a short file, a column that leaves the file, or an
    /// index that leaves its column. The caller recomputes from source.
    BadRecord,
    /// A string in the record is not in this session's interner. Within one
    /// session that is a compiler bug, not a stale file — see the header.
    UnknownSymbol,
} || Allocator.Error;

// ---------------------------------------------------------------------------
// The hash
// ---------------------------------------------------------------------------

/// `std.hash.SipHash128(1, 3)` with an all-zero key, over the record's bytes
/// IN FULL — magic, version, column table, columns and their alignment
/// padding — and not stored inside the record (`fast-compiler.md` §8).
///
/// 128 bits because an accidental collision then has to be impossible
/// rather than unlikely; SipHash-1-3 because it is the only 128-bit output
/// in `std.hash` that is not byte-at-a-time. **It is not a MAC**: the key is
/// a public constant, so nothing here resists someone who can choose the
/// source files. The threat model is accident.
pub const Hash = [16]u8;

const hash_key: [16]u8 = @splat(0);

pub fn hash(bytes: []const u8) Hash {
    var out: Hash = undefined;
    std.hash.SipHash128(1, 3).create(&out, bytes, &hash_key);
    return out;
}

/// The hash as the 32 lowercase hex digits `--iface-hash` prints. The byte
/// ORDER is the digest's own, so the text is a function of the record on
/// every host exactly as the bytes are.
pub fn hashHex(h: Hash) [32]u8 {
    const digits = "0123456789abcdef";
    var out: [32]u8 = undefined;
    for (h, 0..) |byte, i| {
        out[i * 2] = digits[byte >> 4];
        out[i * 2 + 1] = digits[byte & 0xf];
    }
    return out;
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/// `iface` as bytes. The caller owns the result.
pub fn write(gpa: Allocator, iface: *const Interface, interner: *const InternPool.Global) Allocator.Error![]u8 {
    // 1. The `strings` blob and the on-disk `symbols` column. First
    //    occurrence order over the column, so sharing a record between two
    //    slots of the same text does not move a byte.
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(gpa);
    const offsets = try gpa.alloc(u32, iface.symbols.len);
    defer gpa.free(offsets);
    var seen: std.StringHashMapUnmanaged(u32) = .empty;
    defer seen.deinit(gpa);
    for (iface.symbols, offsets) |s, *offset| {
        const text = interner.slice(s);
        const gop = try seen.getOrPut(gpa, text);
        if (gop.found_existing) {
            offset.* = gop.value_ptr.*;
            continue;
        }
        const at: u32 = @intCast(blob.items.len);
        gop.value_ptr.* = at;
        offset.* = at;
        var len_word: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_word, @intCast(text.len), .little);
        try blob.appendSlice(gpa, &len_word);
        try blob.appendSlice(gpa, text);
        // Every record is padded to four, so the blob's own length is a
        // multiple of four and the column after it needs no gap.
        try blob.appendNTimes(gpa, 0, pad4(text.len));
    }

    // 2. Lengths, then offsets. `len` is the element count except for
    //    `strings`, where it is a byte count.
    var lengths: [Column.count]u32 = undefined;
    lengths[@intFromEnum(Column.values)] = @intCast(iface.values.len);
    lengths[@intFromEnum(Column.types)] = @intCast(iface.types.len);
    lengths[@intFromEnum(Column.ctors)] = @intCast(iface.ctors.len);
    lengths[@intFromEnum(Column.schemes)] = @intCast(iface.schemes.len);
    lengths[@intFromEnum(Column.term_tags)] = @intCast(iface.terms.len);
    lengths[@intFromEnum(Column.term_lhs)] = @intCast(iface.terms.len);
    lengths[@intFromEnum(Column.term_rhs)] = @intCast(iface.terms.len);
    lengths[@intFromEnum(Column.extra)] = @intCast(iface.extra.len);
    lengths[@intFromEnum(Column.type_refs)] = @intCast(iface.type_refs.len);
    lengths[@intFromEnum(Column.symbols)] = @intCast(iface.symbols.len);
    lengths[@intFromEnum(Column.strings)] = @intCast(blob.items.len);

    var offsets_of: [Column.count]u32 = undefined;
    var at: u32 = body_start;
    for (0..Column.count) |i| {
        const c: Column = @enumFromInt(i);
        offsets_of[i] = at;
        at += lengths[i] * c.width();
        at += @intCast(pad4(at)); // gaps are zero-filled by the memset below
    }

    const bytes = try gpa.alloc(u8, at);
    errdefer gpa.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..8], magic);
    std.mem.writeInt(u32, bytes[8..12], format_version, .little);
    std.mem.writeInt(u32, bytes[12..16], Column.count, .little);
    for (0..Column.count) |i| {
        const row = bytes[header_bytes + i * 8 ..][0..8];
        std.mem.writeInt(u32, row[0..4], offsets_of[i], .little);
        std.mem.writeInt(u32, row[4..8], lengths[i], .little);
    }

    // 3. The columns.
    {
        const out = bytes[offsets_of[@intFromEnum(Column.values)]..];
        for (iface.values, 0..) |v, i| {
            const row = out[i * 12 ..][0..12];
            std.mem.writeInt(u32, row[0..4], @intFromEnum(v.name), .little);
            std.mem.writeInt(u32, row[4..8], @intFromEnum(v.scheme), .little);
            row[8] = @intFromBool(v.is_foreign);
        }
    }
    {
        const out = bytes[offsets_of[@intFromEnum(Column.types)]..];
        for (iface.types, 0..) |t, i| {
            const row = out[i * 16 ..][0..16];
            std.mem.writeInt(u32, row[0..4], @intFromEnum(t.name), .little);
            std.mem.writeInt(u32, row[4..8], t.ctors_start, .little);
            std.mem.writeInt(u32, row[8..12], t.ctors_end, .little);
            row[12] = t.arity;
            row[13] = @intFromEnum(t.kind);
            row[14] = @as(u8, @intFromBool(t.is_opaque)) | (@as(u8, @intFromBool(t.is_equatable)) << 1);
        }
    }
    {
        const out = bytes[offsets_of[@intFromEnum(Column.ctors)]..];
        for (iface.ctors, 0..) |c, i| {
            const row = out[i * 20 ..][0..20];
            std.mem.writeInt(u32, row[0..4], @intFromEnum(c.name), .little);
            std.mem.writeInt(u32, row[4..8], @intFromEnum(c.type), .little);
            std.mem.writeInt(u32, row[8..12], c.arity, .little);
            std.mem.writeInt(u32, row[12..16], c.arg_terms, .little);
            std.mem.writeInt(u32, row[16..20], c.quantified_start, .little);
        }
    }
    {
        const out = bytes[offsets_of[@intFromEnum(Column.schemes)]..];
        for (iface.schemes, 0..) |s, i| {
            const row = out[i * 12 ..][0..12];
            std.mem.writeInt(u32, row[0..4], s.quantified_start, .little);
            std.mem.writeInt(u32, row[4..8], s.quantified_count, .little);
            std.mem.writeInt(u32, row[8..12], @intFromEnum(s.body), .little);
        }
    }
    if (iface.terms.len != 0) {
        const tags = iface.terms.items(.tag);
        const lhs = iface.terms.items(.lhs);
        const rhs = iface.terms.items(.rhs);
        const tags_out = bytes[offsets_of[@intFromEnum(Column.term_tags)]..];
        for (tags, 0..) |t, i| tags_out[i] = @intFromEnum(t);
        writeWords(bytes[offsets_of[@intFromEnum(Column.term_lhs)]..], lhs);
        writeWords(bytes[offsets_of[@intFromEnum(Column.term_rhs)]..], rhs);
    }
    writeWords(bytes[offsets_of[@intFromEnum(Column.extra)]..], iface.extra);
    {
        const out = bytes[offsets_of[@intFromEnum(Column.type_refs)]..];
        for (iface.type_refs, 0..) |r, i| {
            const row = out[i * 12 ..][0..12];
            std.mem.writeInt(u32, row[0..4], @intFromEnum(r.module), .little);
            std.mem.writeInt(u32, row[4..8], @intFromEnum(r.name), .little);
            row[8] = @intFromEnum(r.package);
        }
    }
    writeWords(bytes[offsets_of[@intFromEnum(Column.symbols)]..], offsets);
    @memcpy(bytes[offsets_of[@intFromEnum(Column.strings)]..][0..blob.items.len], blob.items);

    return bytes;
}

fn writeWords(out: []u8, words: []const u32) void {
    for (words, 0..) |word, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], word, .little);
}

/// Bytes of padding that take `n` up to a multiple of four.
fn pad4(n: usize) usize {
    return (4 - (n % 4)) % 4;
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/// The record `bytes` describes, or an error. The caller owns the result
/// and frees it with `Interface.deinit`.
///
/// EVERY index, range and offset is checked against its column's length
/// before the record is handed back (see `verify` for the list), so a
/// caller never has to trust one — which is what makes a corrupt file a
/// cache miss rather than a wrong answer.
pub fn read(gpa: Allocator, bytes: []const u8, interner: *const InternPool.Global) ReadError!Interface {
    var in: Interning = .{ .find = interner };
    return decode(gpa, bytes, &in);
}

/// `read`, through `getOrPut`. M4-1's cross-process load is the case the
/// header reserves this for: a record written by an earlier process names
/// strings this session may never have interned, and the load runs serially
/// before any worker starts, which is where growing the pool belongs.
pub fn readGrowing(gpa: Allocator, bytes: []const u8, interner: *InternPool.Global) ReadError!Interface {
    var in: Interning = .{ .get_or_put = .{ .pool = interner, .gpa = gpa } };
    return decode(gpa, bytes, &in);
}

/// How a string in the bytes becomes a `Symbol`: the non-mutating lookup for
/// an in-session round trip, and `getOrPut` for the serial cross-process
/// load. One indirection rather than two decoders, so the two paths cannot
/// drift apart about what the format means.
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

fn decode(gpa: Allocator, bytes: []const u8, interning: *Interning) ReadError!Interface {
    if (bytes.len < body_start) return error.BadRecord;
    if (!std.mem.eql(u8, bytes[0..8], magic)) return error.BadRecord;
    if (std.mem.readInt(u32, bytes[8..12], .little) != format_version) return error.BadRecord;
    if (std.mem.readInt(u32, bytes[12..16], .little) != Column.count) return error.BadRecord;

    var offsets_of: [Column.count]u32 = undefined;
    var lengths: [Column.count]u32 = undefined;
    for (0..Column.count) |i| {
        const c: Column = @enumFromInt(i);
        const row = bytes[header_bytes + i * 8 ..][0..8];
        const offset = std.mem.readInt(u32, row[0..4], .little);
        const len = std.mem.readInt(u32, row[4..8], .little);
        // Every column starts 4-byte aligned, and no column may leave the
        // file. `@as(u64, …)` so a length chosen to wrap 32 bits is caught
        // here rather than producing a short, plausible slice.
        if (offset % 4 != 0 or offset < body_start) return error.BadRecord;
        const end = @as(u64, offset) + @as(u64, len) * @as(u64, c.width());
        if (end > bytes.len) return error.BadRecord;
        offsets_of[i] = offset;
        lengths[i] = len;
    }
    // The three `terms` columns are one table split three ways.
    const terms_len = lengths[@intFromEnum(Column.term_tags)];
    if (lengths[@intFromEnum(Column.term_lhs)] != terms_len) return error.BadRecord;
    if (lengths[@intFromEnum(Column.term_rhs)] != terms_len) return error.BadRecord;

    var iface: Interface = .empty;
    errdefer iface.deinit(gpa);

    // `symbols` first: every other column indexes it, and a string that is
    // not in this session's interner is the one failure that is not a miss.
    {
        const blob = bytes[offsets_of[@intFromEnum(Column.strings)]..][0..lengths[@intFromEnum(Column.strings)]];
        const words = bytes[offsets_of[@intFromEnum(Column.symbols)]..];
        const n = lengths[@intFromEnum(Column.symbols)];
        const symbols = try gpa.alloc(Symbol, n);
        iface.symbols = symbols;
        for (symbols, 0..) |*s, i| {
            const offset = std.mem.readInt(u32, words[i * 4 ..][0..4], .little);
            // A record's length word must be inside the blob, and so must
            // the bytes it claims.
            if (@as(u64, offset) + 4 > blob.len) return error.BadRecord;
            const len = std.mem.readInt(u32, blob[offset..][0..4], .little);
            if (@as(u64, offset) + 4 + @as(u64, len) > blob.len) return error.BadRecord;
            s.* = try interning.symbol(blob[offset + 4 ..][0..len]);
        }
    }
    {
        const in = bytes[offsets_of[@intFromEnum(Column.values)]..];
        const values = try gpa.alloc(Interface.Value, lengths[@intFromEnum(Column.values)]);
        iface.values = values;
        for (values, 0..) |*v, i| {
            const row = in[i * 12 ..][0..12];
            v.* = .{
                .name = @enumFromInt(std.mem.readInt(u32, row[0..4], .little)),
                .scheme = @enumFromInt(std.mem.readInt(u32, row[4..8], .little)),
                .is_foreign = row[8] & 1 == 1,
            };
        }
    }
    {
        const in = bytes[offsets_of[@intFromEnum(Column.types)]..];
        const types = try gpa.alloc(Interface.Type, lengths[@intFromEnum(Column.types)]);
        iface.types = types;
        for (types, 0..) |*t, i| {
            const row = in[i * 16 ..][0..16];
            t.* = .{
                .name = @enumFromInt(std.mem.readInt(u32, row[0..4], .little)),
                .ctors_start = std.mem.readInt(u32, row[4..8], .little),
                .ctors_end = std.mem.readInt(u32, row[8..12], .little),
                .arity = row[12],
                .kind = std.enums.fromInt(Interface.TypeKind, row[13]) orelse return error.BadRecord,
                .is_opaque = row[14] & 1 == 1,
                .is_equatable = (row[14] >> 1) & 1 == 1,
            };
        }
    }
    {
        const in = bytes[offsets_of[@intFromEnum(Column.ctors)]..];
        const ctors = try gpa.alloc(Interface.Ctor, lengths[@intFromEnum(Column.ctors)]);
        iface.ctors = ctors;
        for (ctors, 0..) |*c, i| {
            const row = in[i * 20 ..][0..20];
            c.* = .{
                .name = @enumFromInt(std.mem.readInt(u32, row[0..4], .little)),
                .type = @enumFromInt(std.mem.readInt(u32, row[4..8], .little)),
                .arity = std.mem.readInt(u32, row[8..12], .little),
                .arg_terms = std.mem.readInt(u32, row[12..16], .little),
                .quantified_start = std.mem.readInt(u32, row[16..20], .little),
            };
        }
    }
    {
        const in = bytes[offsets_of[@intFromEnum(Column.schemes)]..];
        const schemes = try gpa.alloc(Interface.Scheme, lengths[@intFromEnum(Column.schemes)]);
        iface.schemes = schemes;
        for (schemes, 0..) |*s, i| {
            const row = in[i * 12 ..][0..12];
            s.* = .{
                .quantified_start = std.mem.readInt(u32, row[0..4], .little),
                .quantified_count = std.mem.readInt(u32, row[4..8], .little),
                .body = @enumFromInt(std.mem.readInt(u32, row[8..12], .little)),
            };
        }
    }
    {
        var terms: std.MultiArrayList(Interface.Term) = .empty;
        errdefer terms.deinit(gpa);
        try terms.resize(gpa, terms_len);
        const tags = bytes[offsets_of[@intFromEnum(Column.term_tags)]..];
        const lhs = bytes[offsets_of[@intFromEnum(Column.term_lhs)]..];
        const rhs = bytes[offsets_of[@intFromEnum(Column.term_rhs)]..];
        for (0..terms_len) |i| {
            terms.set(i, .{
                .tag = std.enums.fromInt(Interface.Term.Tag, tags[i]) orelse return error.BadRecord,
                .lhs = std.mem.readInt(u32, lhs[i * 4 ..][0..4], .little),
                .rhs = std.mem.readInt(u32, rhs[i * 4 ..][0..4], .little),
            });
        }
        iface.terms = terms.toOwnedSlice();
    }
    {
        const in = bytes[offsets_of[@intFromEnum(Column.extra)]..];
        const extra = try gpa.alloc(u32, lengths[@intFromEnum(Column.extra)]);
        iface.extra = extra;
        for (extra, 0..) |*word, i| word.* = std.mem.readInt(u32, in[i * 4 ..][0..4], .little);
    }
    {
        const in = bytes[offsets_of[@intFromEnum(Column.type_refs)]..];
        const refs = try gpa.alloc(Interface.TypeRef, lengths[@intFromEnum(Column.type_refs)]);
        iface.type_refs = refs;
        for (refs, 0..) |*r, i| {
            const row = in[i * 12 ..][0..12];
            r.* = .{
                .module = @enumFromInt(std.mem.readInt(u32, row[0..4], .little)),
                .name = @enumFromInt(std.mem.readInt(u32, row[4..8], .little)),
                .package = std.enums.fromInt(SourceStore.Package, row[8]) orelse return error.BadRecord,
            };
        }
    }

    if (!verify(&iface)) return error.BadRecord;
    return iface;
}

/// Whether every index, range and offset in `iface` stays inside the column
/// it points at. `read` runs this before handing a record back, and the
/// fuzz test below asserts that a mutated record either fails to load or
/// passes this — the two together being what "never a wrong answer, never
/// an out-of-bounds read" means for a record built from bytes.
///
/// What it checks, column by column:
///
///   * `values[i].name` is a symbol slot; `.scheme` is `none` or a scheme.
///   * `types[i].name` is a symbol slot; `ctors_start <= ctors_end <=
///     ctors.len`.
///   * `ctors[i].name` is a symbol slot; `.type` is a type slot;
///     `.arg_terms` is `no_terms` or an `extra` range whose length word and
///     words all fit, and each word is `none` or a term; `.quantified_start`
///     is inside `extra` (its LENGTH is the owning type's arity, which the
///     writer does not store, so each read stays `ctorQuantified`'s to
///     bound).
///   * `schemes[i].body` is `none` or a term; the quantifier block —
///     `quantified_count` × four words — fits in `extra`; every
///     quantifier's name is `none` or a symbol slot and its constraint
///     block — `constraints_len` × two words — fits, each constraint naming
///     a symbol slot and a term.
///   * every term's operands, by tag: `func` a parameter range and a result
///     term, `app`/`alias` a `type_refs` slot or `none` plus a range,
///     `tuple` a range, `record` an even-length range of (symbol, term)
///     pairs and an extension term, `alias`'s range non-empty. `var`'s
///     `lhs` is a quantifier ordinal with no scheme in hand, which
///     `Schemes.Reader` already bounds against the instantiation's own
///     variables.
///   * `type_refs[i].module` and `.name` are symbol slots.
pub fn verify(iface: *const Interface) bool {
    const symbols = iface.symbols.len;
    const terms = iface.terms.len;

    for (iface.values) |v| {
        if (@intFromEnum(v.name) >= symbols) return false;
        if (v.scheme != .none and @intFromEnum(v.scheme) >= iface.schemes.len) return false;
    }
    for (iface.types) |t| {
        if (@intFromEnum(t.name) >= symbols) return false;
        if (t.ctors_start > t.ctors_end or t.ctors_end > iface.ctors.len) return false;
    }
    for (iface.ctors) |c| {
        if (@intFromEnum(c.name) >= symbols) return false;
        if (@intFromEnum(c.type) >= iface.types.len) return false;
        if (c.quantified_start > iface.extra.len) return false;
        if (c.arg_terms != Interface.no_terms) {
            const words = rangeOf(iface, c.arg_terms) orelse return false;
            for (words) |word| {
                if (!isTerm(terms, word)) return false;
            }
        }
    }
    for (iface.schemes) |s| {
        if (!isTerm(terms, @intFromEnum(s.body))) return false;
        const block = @as(u64, s.quantified_start) + @as(u64, s.quantified_count) * Interface.Quantified.words;
        if (block > iface.extra.len) return false;
        for (0..s.quantified_count) |i| {
            const at = s.quantified_start + i * Interface.Quantified.words;
            const name = iface.extra[at + 1];
            if (name != std.math.maxInt(u32) and name >= symbols) return false;
            const start = iface.extra[at + 2];
            const len = iface.extra[at + 3];
            const end = @as(u64, start) + @as(u64, len) * 2;
            if (end > iface.extra.len) return false;
            for (0..len) |j| {
                if (iface.extra[start + j * 2] >= symbols) return false;
                if (!isTerm(terms, iface.extra[start + j * 2 + 1])) return false;
            }
        }
    }
    if (terms != 0) {
        const tags = iface.terms.items(.tag);
        const lhs = iface.terms.items(.lhs);
        const rhs = iface.terms.items(.rhs);
        for (tags, lhs, rhs) |tag, l, r| switch (tag) {
            .@"var", .unit, .empty_record, .err => {},
            .func => {
                const words = rangeOf(iface, l) orelse return false;
                for (words) |word| {
                    if (!isTerm(terms, word)) return false;
                }
                if (!isTerm(terms, r)) return false;
            },
            .app => {
                if (!isTypeRef(iface, l)) return false;
                const words = rangeOf(iface, r) orelse return false;
                for (words) |word| {
                    if (!isTerm(terms, word)) return false;
                }
            },
            .tuple => {
                const words = rangeOf(iface, l) orelse return false;
                for (words) |word| {
                    if (!isTerm(terms, word)) return false;
                }
            },
            .record => {
                const words = rangeOf(iface, l) orelse return false;
                if (words.len % 2 != 0) return false;
                var i: usize = 0;
                while (i < words.len) : (i += 2) {
                    if (words[i] >= symbols) return false;
                    if (!isTerm(terms, words[i + 1])) return false;
                }
                if (!isTerm(terms, r)) return false;
            },
            .alias => {
                if (!isTypeRef(iface, l)) return false;
                const words = rangeOf(iface, r) orelse return false;
                // An alias range is its arguments followed by the
                // expansion, so it is never empty.
                if (words.len == 0) return false;
                for (words) |word| {
                    if (!isTerm(terms, word)) return false;
                }
            },
        };
    }
    for (iface.type_refs) |r| {
        if (@intFromEnum(r.module) >= symbols) return false;
        if (@intFromEnum(r.name) >= symbols) return false;
    }
    return true;
}

/// `extra[start..][0..extra[start]]`, or null when the header or the words
/// leave the column. The shape `Interface.range` reads, checked instead of
/// degraded.
fn rangeOf(iface: *const Interface, start: u32) ?[]const u32 {
    if (start >= iface.extra.len) return null;
    const len = iface.extra[start];
    const rest = iface.extra[start + 1 ..];
    if (len > rest.len) return null;
    return rest[0..len];
}

fn isTerm(terms: usize, word: u32) bool {
    return word == std.math.maxInt(u32) or word < terms;
}

fn isTypeRef(iface: *const Interface, word: u32) bool {
    return word == std.math.maxInt(u32) or word < iface.type_refs.len;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const TestProject = @import("TestProject.zig");
const Session = @import("../Session.zig");

/// Whether two records are equal in every byte that the format carries.
/// Symbols are compared as TEXT, because the point of the column is that
/// two sessions may number the same name differently.
fn expectSameRecord(a: *const Interface, b: *const Interface, interner: *const InternPool.Global) !void {
    try testing.expectEqualSlices(Interface.Value, a.values, b.values);
    try testing.expectEqualSlices(Interface.Type, a.types, b.types);
    try testing.expectEqualSlices(Interface.Ctor, a.ctors, b.ctors);
    try testing.expectEqualSlices(Interface.Scheme, a.schemes, b.schemes);
    try testing.expectEqualSlices(u32, a.extra, b.extra);
    try testing.expectEqualSlices(Interface.TypeRef, a.type_refs, b.type_refs);
    try testing.expectEqual(a.terms.len, b.terms.len);
    if (a.terms.len != 0) {
        try testing.expectEqualSlices(Interface.Term.Tag, a.terms.items(.tag), b.terms.items(.tag));
        try testing.expectEqualSlices(u32, a.terms.items(.lhs), b.terms.items(.lhs));
        try testing.expectEqualSlices(u32, a.terms.items(.rhs), b.terms.items(.rhs));
    }
    try testing.expectEqual(a.symbols.len, b.symbols.len);
    for (a.symbols, b.symbols) |x, y| {
        try testing.expectEqualStrings(interner.slice(x), interner.slice(y));
    }
}

/// Write, read, and require the record back unchanged — and require the
/// bytes of the SECOND write to equal the first, which is what a hash over
/// them being stable means.
fn expectRoundTrip(iface: *const Interface, interner: *const InternPool.Global) !void {
    const gpa = testing.allocator;
    const bytes = try write(gpa, iface, interner);
    defer gpa.free(bytes);
    var back = try read(gpa, bytes, interner);
    defer back.deinit(gpa);
    try expectSameRecord(iface, &back, interner);

    const again = try write(gpa, &back, interner);
    defer gpa.free(again);
    try testing.expectEqualSlices(u8, bytes, again);
    try testing.expectEqual(hash(bytes), hash(again));
}

test "the empty record round-trips" {
    var global = try InternPool.Global.init(testing.allocator);
    defer global.deinit(testing.allocator);
    const iface: Interface = .empty;
    try expectRoundTrip(&iface, &global);
}

test "every record of a project round-trips, with schemes, ctors and where clauses" {
    var p = try TestProject.initWith(testing.allocator, &.{
        .{ .path = "A.beni", .source =
        \\pub type Shape a
        \\    = Box a a
        \\    | Empty
        \\
        \\
        \\pub opaque type Token
        \\    = Token Int
        \\
        \\
        \\pub type alias Pair a =
        \\    ( a, a )
        \\
        \\
        \\pub twice : a -> a
        \\twice x =
        \\    x
        \\
        \\
        \\pub widen r =
        \\    r.width
        \\
        \\
        \\pub pack : a, a -> Pair a
        \\pack x y =
        \\    ( x, y )
        \\
        },
        .{ .path = "B.beni", .source =
        \\import A
        \\
        \\
        \\pub use : A.Shape Int -> A.Pair Int
        \\use s =
        \\    case s of
        \\        A.Box a b ->
        \\            A.pack a b
        \\
        \\        A.Empty ->
        \\            A.pack 0 0
        \\
        \\
        \\pub biggest a b =
        \\    if a < b then
        \\        b
        \\    else
        \\        a
        \\
        },
    }, .{ .phases = Session.check_phases });
    defer p.deinit();

    var any_terms = false;
    var any_ctors = false;
    for (p.session.resolution.interfaces) |*iface| {
        try expectRoundTrip(iface, &p.session.interner);
        if (iface.terms.len != 0) any_terms = true;
        if (iface.ctors.len != 0) any_ctors = true;
    }
    // A round trip of nothing proves nothing.
    try testing.expect(any_terms);
    try testing.expect(any_ctors);
}

test "a record full of <error> round-trips" {
    var p = try TestProject.initWith(testing.allocator, &.{
        .{ .path = "E.beni", .source =
        \\pub broken : Int
        \\broken =
        \\    unknownName
        \\
        \\
        \\pub alsoBroken x =
        \\    x + "text"
        \\
        },
    }, .{ .phases = Session.check_phases });
    defer p.deinit();
    var saw_err = false;
    for (p.session.resolution.interfaces) |*iface| {
        try expectRoundTrip(iface, &p.session.interner);
        if (iface.terms.len != 0) {
            for (iface.terms.items(.tag)) |tag| {
                if (tag == .err) saw_err = true;
            }
        }
    }
    try testing.expect(saw_err);
}

test "a module that was never checked round-trips, no_terms and all" {
    // `resolve_phases` stops before the checker, so every ctor's
    // `arg_terms` is `no_terms` and every value's scheme is `none`.
    var p = try TestProject.init(testing.allocator, &.{
        .{ .path = "S.beni", .source =
        \\pub type Colour
        \\    = Red
        \\    | Green Int
        \\
        \\
        \\pub name : Int
        \\name =
        \\    1
        \\
        },
    });
    defer p.deinit();
    var saw_no_terms = false;
    for (p.session.resolution.interfaces) |*iface| {
        try expectRoundTrip(iface, &p.session.interner);
        for (iface.ctors) |c| {
            if (c.arg_terms == Interface.no_terms) saw_no_terms = true;
        }
    }
    try testing.expect(saw_no_terms);
}

test "the symbols column shares one strings record between equal names" {
    var global = try InternPool.Global.init(testing.allocator);
    defer global.deinit(testing.allocator);
    const a = try global.getOrPut(testing.allocator, "duplicated");
    const iface: Interface = .{
        .values = &.{},
        .types = &.{},
        .ctors = &.{},
        .schemes = &.{},
        .terms = .empty,
        .extra = &.{},
        .type_refs = &.{},
        .symbols = &.{ a, a, a },
    };
    const bytes = try write(testing.allocator, &iface, &global);
    defer testing.allocator.free(bytes);
    // Three slots, one record: 4 + 10 bytes padded to 16.
    const row = bytes[header_bytes + @intFromEnum(Column.strings) * 8 ..][0..8];
    try testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, row[4..8], .little));
    var back = try read(testing.allocator, bytes, &global);
    defer back.deinit(testing.allocator);
    try testing.expectEqualSlices(Symbol, iface.symbols, back.symbols);
}

test "a string the session never interned is UnknownSymbol, not a miss" {
    var writer_pool = try InternPool.Global.init(testing.allocator);
    defer writer_pool.deinit(testing.allocator);
    const only_here = try writer_pool.getOrPut(testing.allocator, "onlyInTheWriter");
    const iface: Interface = .{
        .values = &.{},
        .types = &.{},
        .ctors = &.{},
        .schemes = &.{},
        .terms = .empty,
        .extra = &.{},
        .type_refs = &.{},
        .symbols = &.{only_here},
    };
    const bytes = try write(testing.allocator, &iface, &writer_pool);
    defer testing.allocator.free(bytes);

    var reader_pool = try InternPool.Global.init(testing.allocator);
    defer reader_pool.deinit(testing.allocator);
    try testing.expectError(error.UnknownSymbol, read(testing.allocator, bytes, &reader_pool));
    // The reader's pool was NOT grown by the failed load.
    try testing.expectEqual(@as(u32, InternPool.WellKnown.count), reader_pool.count());
}

test "the symbol column is text, so a different interner numbering reads back the same names" {
    var a_pool = try InternPool.Global.init(testing.allocator);
    defer a_pool.deinit(testing.allocator);
    var b_pool = try InternPool.Global.init(testing.allocator);
    defer b_pool.deinit(testing.allocator);
    // The two sessions intern the same three names in opposite orders, so
    // every `Symbol` differs between them.
    const a_zeta = try a_pool.getOrPut(testing.allocator, "zeta");
    const a_mid = try a_pool.getOrPut(testing.allocator, "mid");
    _ = try b_pool.getOrPut(testing.allocator, "mid");
    _ = try b_pool.getOrPut(testing.allocator, "zeta");
    try testing.expect(a_zeta != b_pool.find("zeta").?);

    const iface: Interface = .{
        .values = &.{},
        .types = &.{},
        .ctors = &.{},
        .schemes = &.{},
        .terms = .empty,
        .extra = &.{},
        .type_refs = &.{},
        .symbols = &.{ a_zeta, a_mid },
    };
    const bytes = try write(testing.allocator, &iface, &a_pool);
    defer testing.allocator.free(bytes);
    var back = try read(testing.allocator, bytes, &b_pool);
    defer back.deinit(testing.allocator);
    try testing.expectEqualStrings("zeta", b_pool.slice(back.symbols[0]));
    try testing.expectEqualStrings("mid", b_pool.slice(back.symbols[1]));
    // And the BYTES do not depend on the numbering either: the same record
    // written from the other pool's symbols is identical.
    const from_b: Interface = .{
        .values = &.{},
        .types = &.{},
        .ctors = &.{},
        .schemes = &.{},
        .terms = .empty,
        .extra = &.{},
        .type_refs = &.{},
        .symbols = &.{ b_pool.find("zeta").?, b_pool.find("mid").? },
    };
    const b_bytes = try write(testing.allocator, &from_b, &b_pool);
    defer testing.allocator.free(b_bytes);
    try testing.expectEqualSlices(u8, bytes, b_bytes);
}

test "a wrong magic, an unknown version and a short file are all BadRecord" {
    var global = try InternPool.Global.init(testing.allocator);
    defer global.deinit(testing.allocator);
    const iface: Interface = .empty;
    const bytes = try write(testing.allocator, &iface, &global);
    defer testing.allocator.free(bytes);

    try testing.expectError(error.BadRecord, read(testing.allocator, &.{}, &global));
    try testing.expectError(error.BadRecord, read(testing.allocator, bytes[0 .. bytes.len - 1], &global));

    const copy = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(copy);
    copy[0] = 'X';
    try testing.expectError(error.BadRecord, read(testing.allocator, copy, &global));
    @memcpy(copy[0..8], magic);
    std.mem.writeInt(u32, copy[8..12], format_version + 1, .little);
    try testing.expectError(error.BadRecord, read(testing.allocator, copy, &global));
    std.mem.writeInt(u32, copy[8..12], format_version, .little);
    std.mem.writeInt(u32, copy[12..16], Column.count + 1, .little);
    try testing.expectError(error.BadRecord, read(testing.allocator, copy, &global));
}

test "a column offset past the end, and a strings record that overruns the blob" {
    var global = try InternPool.Global.init(testing.allocator);
    defer global.deinit(testing.allocator);
    const name = try global.getOrPut(testing.allocator, "field");
    const iface: Interface = .{
        .values = &.{.{ .name = @enumFromInt(0), .is_foreign = false, .scheme = .none }},
        .types = &.{},
        .ctors = &.{},
        .schemes = &.{},
        .terms = .empty,
        .extra = &.{},
        .type_refs = &.{},
        .symbols = &.{name},
    };
    const bytes = try write(testing.allocator, &iface, &global);
    defer testing.allocator.free(bytes);
    // The unmutated record loads, so every failure below is the mutation's.
    {
        var back = try read(testing.allocator, bytes, &global);
        back.deinit(testing.allocator);
    }

    // A column offset that leaves the file.
    {
        const copy = try testing.allocator.dupe(u8, bytes);
        defer testing.allocator.free(copy);
        const row = copy[header_bytes + @intFromEnum(Column.values) * 8 ..][0..8];
        std.mem.writeInt(u32, row[0..4], @intCast(bytes.len), .little);
        try testing.expectError(error.BadRecord, read(testing.allocator, copy, &global));
    }
    // A column length that leaves the file.
    {
        const copy = try testing.allocator.dupe(u8, bytes);
        defer testing.allocator.free(copy);
        const row = copy[header_bytes + @intFromEnum(Column.values) * 8 ..][0..8];
        std.mem.writeInt(u32, row[4..8], 1000, .little);
        try testing.expectError(error.BadRecord, read(testing.allocator, copy, &global));
    }
    // A length chosen to wrap 32 bits.
    {
        const copy = try testing.allocator.dupe(u8, bytes);
        defer testing.allocator.free(copy);
        const row = copy[header_bytes + @intFromEnum(Column.values) * 8 ..][0..8];
        std.mem.writeInt(u32, row[4..8], std.math.maxInt(u32) / 6, .little);
        try testing.expectError(error.BadRecord, read(testing.allocator, copy, &global));
    }
    // A misaligned column.
    {
        const copy = try testing.allocator.dupe(u8, bytes);
        defer testing.allocator.free(copy);
        const row = copy[header_bytes + @intFromEnum(Column.values) * 8 ..][0..8];
        std.mem.writeInt(u32, row[0..4], body_start + 1, .little);
        try testing.expectError(error.BadRecord, read(testing.allocator, copy, &global));
    }
    // A `strings` record whose length word overruns the blob.
    {
        const copy = try testing.allocator.dupe(u8, bytes);
        defer testing.allocator.free(copy);
        const at = std.mem.readInt(u32, copy[header_bytes + @intFromEnum(Column.strings) * 8 ..][0..4], .little);
        std.mem.writeInt(u32, copy[at..][0..4], 1000, .little);
        try testing.expectError(error.BadRecord, read(testing.allocator, copy, &global));
    }
    // A `symbols` slot pointing past the blob.
    {
        const copy = try testing.allocator.dupe(u8, bytes);
        defer testing.allocator.free(copy);
        const at = std.mem.readInt(u32, copy[header_bytes + @intFromEnum(Column.symbols) * 8 ..][0..4], .little);
        std.mem.writeInt(u32, copy[at..][0..4], 1000, .little);
        try testing.expectError(error.BadRecord, read(testing.allocator, copy, &global));
    }
    // A `values` row naming a symbol slot that is not there.
    {
        const copy = try testing.allocator.dupe(u8, bytes);
        defer testing.allocator.free(copy);
        const at = std.mem.readInt(u32, copy[header_bytes + @intFromEnum(Column.values) * 8 ..][0..4], .little);
        std.mem.writeInt(u32, copy[at..][0..4], 9, .little);
        try testing.expectError(error.BadRecord, read(testing.allocator, copy, &global));
    }
}

// **The fuzz test.** A real record's bytes, mutated exhaustively at every
// place the format has a boundary, and then at random; every mutation must
// end in an error or in a record that `verify` accepts, and never in an
// out-of-bounds read. Run under `zig build test`, which is Debug, so
// `std`'s own bounds checks are live and a read past a slice is a panic
// rather than a silent wrong answer.
//
// Deterministic: a fixed seed, a fixed corpus and a fixed mutation
// schedule, so a failure reproduces exactly.
test "fuzz: a mutated record never reads back as an unverified one" {
    var p = try TestProject.initWith(testing.allocator, &.{
        .{ .path = "F.beni", .source =
        \\pub type Tree a
        \\    = Leaf
        \\    | Node (Tree a) a (Tree a)
        \\
        \\
        \\pub type alias Named a =
        \\    { name : String, value : a }
        \\
        \\
        \\pub wrap : a -> Named a
        \\wrap v =
        \\    { name = "x", value = v }
        \\
        \\
        \\pub compareBoth a b =
        \\    a < b
        \\
        \\
        \\pub pairUp : a, b -> ( a, b )
        \\pairUp x y =
        \\    ( x, y )
        \\
        },
    }, .{ .phases = Session.check_phases });
    defer p.deinit();

    const gpa = testing.allocator;
    const m = p.module("F").?;
    const original = &p.session.resolution.interfaces[m.int()];
    const bytes = try write(gpa, original, &p.session.interner);
    defer gpa.free(bytes);
    // The fixture has to be big enough for the sweep to mean something.
    try testing.expect(bytes.len > 512);

    var attempts: usize = 0;
    var loaded: usize = 0;

    const check = struct {
        fn go(mutated: []const u8, interner: *const InternPool.Global, ok: *usize) !void {
            var back = read(testing.allocator, mutated, interner) catch |err| switch (err) {
                error.BadRecord, error.UnknownSymbol => return,
                error.OutOfMemory => return err,
            };
            defer back.deinit(testing.allocator);
            // A record that loaded must describe itself, and must survive
            // being written again.
            try testing.expect(verify(&back));
            const again = try write(testing.allocator, &back, interner);
            testing.allocator.free(again);
            ok.* += 1;
        }
    }.go;

    // 1. Truncation at every byte: the whole header and table, then every
    //    fourth byte of the body (a column boundary is always at a multiple
    //    of four, so this hits all of them).
    {
        const copy = try gpa.dupe(u8, bytes);
        defer gpa.free(copy);
        var len: usize = 0;
        while (len <= bytes.len) : (len += if (len < body_start) 1 else 4) {
            attempts += 1;
            try check(copy[0..len], &p.session.interner, &loaded);
        }
    }

    // 2. Every bit of the header and the column table flipped, one at a
    //    time: this is where a length or an offset lives, and where a
    //    mutation is most likely to produce a plausible-looking record.
    {
        const copy = try gpa.dupe(u8, bytes);
        defer gpa.free(copy);
        for (0..body_start) |i| {
            for (0..8) |bit| {
                copy[i] ^= @as(u8, 1) << @intCast(bit);
                attempts += 1;
                try check(copy, &p.session.interner, &loaded);
                copy[i] ^= @as(u8, 1) << @intCast(bit);
            }
        }
    }

    // 3. Every byte of the body flipped in its high and low bits, which is
    //    what turns an index into one that is out of range.
    {
        const copy = try gpa.dupe(u8, bytes);
        defer gpa.free(copy);
        for (body_start..bytes.len) |i| {
            for ([_]u8{ 0x01, 0x80 }) |mask| {
                copy[i] ^= mask;
                attempts += 1;
                try check(copy, &p.session.interner, &loaded);
                copy[i] ^= mask;
            }
        }
    }

    // 4. Random single-byte writes, fixed seed.
    {
        var prng: std.Random.DefaultPrng = .init(0xBE1_1FACE);
        const random = prng.random();
        const copy = try gpa.dupe(u8, bytes);
        defer gpa.free(copy);
        for (0..30_000) |_| {
            const at = random.uintLessThan(usize, bytes.len);
            const was = copy[at];
            copy[at] = random.int(u8);
            attempts += 1;
            try check(copy, &p.session.interner, &loaded);
            copy[at] = was;
        }
    }

    // The sweep is worth nothing if nothing ever loaded: a mutation that
    // lands in padding, or in a byte the format does not read, must still
    // produce a readable record.
    try testing.expect(loaded > 100);
    try testing.expect(attempts > 30_000);
}
