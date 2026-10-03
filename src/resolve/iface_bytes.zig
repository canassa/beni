//! The interface record as BYTES (docs/design/checker.md §7, *The
//! serialized form*), and the hash over them (`fast-compiler.md` §8's *The
//! interface hash*).
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
//! the caller reports as `internal`. The cache's cross-process load is the case
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
const Bir = @import("../bir/Bir.zig");

const Symbol = InternPool.Symbol;

/// First eight bytes of every record.
pub const magic = "BENIIFC\x00";

/// Bumped whenever the meaning of any byte changes. An interface change is
/// a version bump and a cache discard, never a migration into spare bytes:
/// the alignment padding below is padding and NOT a reserved field.
/// 5: a derived row may be `private_method`, with its culprit
/// (`checker-v2.md` §14.2).
/// 6: a derived row may be `requirement`, with its culprit in the same
/// two words (§14.2).
/// 7: an `alias` term holds its arguments only; the alias's body is on its
/// `type_refs` row, which grows to 16 bytes (§14.2).
/// 8: a value may be a markup primitive (bit 1 of its flag byte), and a
/// vocabulary module has three tables, `elements`, `attributes` and
/// `events` (§25.8).
/// 9: a scheme row grows 12 → 16 bytes: the `extra` offset of its effect
/// block, or `no_terms` (transparent-effects-proposal.md §14.6).
/// 10: a class word of an effect block carries a demand in bit 8, `rung |
/// sync << 8` (§15.5).
/// 11: and whether the declaration's body reads the class, in bit 9: a
/// declaration with such a class has a second, suspendable body (§16.2).
/// 12: a quantifier's flag word carries bit 9, `identity`: the value takes
/// the quantifier's type identity as a hidden parameter (checker-v2.md §33).
pub const format_version: u32 = 12;

/// The eighteen columns, in this order and no other (`hidden_types` since
/// format 4, the vocabulary tables since format 8, `checker-v2.md` §14.2,
/// §25.8). `terms` is split into
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
    hidden_types,
    schemas,
    schema_members,
    schema_ctors,
    elements,
    attributes,
    events,
    symbols,
    strings,

    pub const count: u32 = @typeInfo(Column).@"enum".field_names.len;

    /// Bytes per element. `strings` is the one column whose `len` is a BYTE
    /// count rather than an element count, so its width is 1 by definition.
    pub fn width(c: Column) u32 {
        return switch (c) {
            .values => 12,
            .types => 32,
            .ctors => 28,
            .schemes => 16,
            .term_tags => 1,
            .term_lhs, .term_rhs, .extra, .symbols => 4,
            .type_refs => 16,
            .hidden_types => 24,
            .elements, .attributes, .events => 24,
            .schemas => 32,
            .schema_members, .schema_ctors => 16,
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

const native_little = @import("builtin").cpu.arch.endian() == .little;

pub fn hash(bytes: []const u8) Hash {
    // `std.hash.SipHash128(1, 3).create(&out, bytes, &hash_key)`, written
    // out for the one key it is ever given: every key, every artifact's and
    // every entry's check runs through it, and Zig's own backend — which
    // compiles the compiler the tests run — calls `std.math.rotl` and the
    // streaming state's helpers out of line, several times the work. The
    // unit test below holds the two equal.
    //
    // The blocks are the bulk of it — a checked core reads every embedded
    // artifact through here, every build — so their round is written out
    // on four locals and the word read in place: through `sipRound`'s
    // pointer that backend reloads the array's address for every operand.
    var v0: u64 = 0x736f6d6570736575;
    var v1: u64 = 0x646f72616e646f6d ^ 0xee;
    var v2: u64 = 0x6c7967656e657261;
    var v3: u64 = 0x7465646279746573;
    const aligned = bytes.len - bytes.len % 8;
    const at: [*]const u8 = bytes.ptr;
    var off: usize = 0;
    while (off < aligned) : (off += 8) {
        const m: u64 = if (native_little) @bitCast(at[off..][0..8].*) else std.mem.readInt(u64, at[off..][0..8], .little);
        v3 ^= m;
        v0 +%= v1;
        v1 = (v1 << 13) | (v1 >> 51);
        v1 ^= v0;
        v0 = (v0 << 32) | (v0 >> 32);
        v2 +%= v3;
        v3 = (v3 << 16) | (v3 >> 48);
        v3 ^= v2;
        v0 +%= v3;
        v3 = (v3 << 21) | (v3 >> 43);
        v3 ^= v0;
        v2 +%= v1;
        v1 = (v1 << 17) | (v1 >> 47);
        v1 ^= v2;
        v2 = (v2 << 32) | (v2 >> 32);
        v0 ^= m;
    }
    var v: [4]u64 = .{ v0, v1, v2, v3 };
    var last: [8]u8 = @splat(0);
    for (bytes[aligned..], 0..) |b, i| last[i] = b;
    last[7] = @truncate(bytes.len);
    const m = std.mem.littleToNative(u64, @bitCast(last));
    v[3] ^= m;
    sipRound(&v);
    v[0] ^= m;
    v[2] ^= 0xee;
    sipRound(&v);
    sipRound(&v);
    sipRound(&v);
    const low = v[0] ^ v[1] ^ v[2] ^ v[3];
    v[1] ^= 0xdd;
    sipRound(&v);
    sipRound(&v);
    sipRound(&v);
    const high = v[0] ^ v[1] ^ v[2] ^ v[3];
    var out: Hash = undefined;
    std.mem.writeInt(u128, &out, (@as(u128, high) << 64) | low, .little);
    return out;
}

inline fn sipRound(v: *[4]u64) void {
    v[0] +%= v[1];
    v[1] = (v[1] << 13) | (v[1] >> 51);
    v[1] ^= v[0];
    v[0] = (v[0] << 32) | (v[0] >> 32);
    v[2] +%= v[3];
    v[3] = (v[3] << 16) | (v[3] >> 48);
    v[3] ^= v[2];
    v[0] +%= v[3];
    v[3] = (v[3] << 21) | (v[3] >> 43);
    v[3] ^= v[0];
    v[2] +%= v[1];
    v[1] = (v[1] << 17) | (v[1] >> 47);
    v[1] ^= v[2];
    v[2] = (v[2] << 32) | (v[2] >> 32);
}

test "hash is std's SipHash-1-3-128 with the all-zero key, at every length" {
    var bytes: [600]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    prng.random().bytes(&bytes);
    for (0..bytes.len + 1) |len| {
        var want: Hash = undefined;
        std.hash.SipHash128(1, 3).create(&want, bytes[0..len], &hash_key);
        try std.testing.expectEqualSlices(u8, &want, &hash(bytes[0..len]));
    }
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
    lengths[@backingInt(Column.values)] = @intCast(iface.values.len);
    lengths[@backingInt(Column.types)] = @intCast(iface.types.len);
    lengths[@backingInt(Column.ctors)] = @intCast(iface.ctors.len);
    lengths[@backingInt(Column.schemes)] = @intCast(iface.schemes.len);
    lengths[@backingInt(Column.term_tags)] = @intCast(iface.terms.len);
    lengths[@backingInt(Column.term_lhs)] = @intCast(iface.terms.len);
    lengths[@backingInt(Column.term_rhs)] = @intCast(iface.terms.len);
    lengths[@backingInt(Column.extra)] = @intCast(iface.extra.len);
    lengths[@backingInt(Column.type_refs)] = @intCast(iface.type_refs.len);
    lengths[@backingInt(Column.hidden_types)] = @intCast(iface.hidden_types.len);
    lengths[@backingInt(Column.schemas)] = @intCast(iface.schemas.len);
    lengths[@backingInt(Column.schema_members)] = @intCast(iface.schema_members.len);
    lengths[@backingInt(Column.schema_ctors)] = @intCast(iface.schema_ctors.len);
    lengths[@backingInt(Column.elements)] = @intCast(iface.elements.len);
    lengths[@backingInt(Column.attributes)] = @intCast(iface.attributes.len);
    lengths[@backingInt(Column.events)] = @intCast(iface.events.len);
    lengths[@backingInt(Column.symbols)] = @intCast(iface.symbols.len);
    lengths[@backingInt(Column.strings)] = @intCast(blob.items.len);

    var offsets_of: [Column.count]u32 = undefined;
    var at: u32 = body_start;
    for (0..Column.count) |i| {
        const c: Column = @fromBackingInt(@intCast(i));
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
        const out = bytes[offsets_of[@backingInt(Column.values)]..];
        for (iface.values, 0..) |v, i| {
            const row = out[i * 12 ..][0..12];
            std.mem.writeInt(u32, row[0..4], @backingInt(v.name), .little);
            std.mem.writeInt(u32, row[4..8], @backingInt(v.scheme), .little);
            row[8] = @as(u8, @intFromBool(v.is_foreign)) | (@as(u8, @intFromBool(v.is_markup_primitive)) << 1);
        }
    }
    writeVocab(bytes[offsets_of[@backingInt(Column.elements)]..], iface.elements);
    writeVocab(bytes[offsets_of[@backingInt(Column.attributes)]..], iface.attributes);
    writeVocab(bytes[offsets_of[@backingInt(Column.events)]..], iface.events);
    {
        const out = bytes[offsets_of[@backingInt(Column.types)]..];
        for (iface.types, 0..) |t, i| {
            const row = out[i * 32 ..][0..32];
            std.mem.writeInt(u32, row[0..4], @backingInt(t.name), .little);
            std.mem.writeInt(u32, row[4..8], t.ctors_start, .little);
            std.mem.writeInt(u32, row[8..12], t.ctors_end, .little);
            std.mem.writeInt(u16, row[12..14], t.arity, .little);
            row[14] = @backingInt(t.kind);
            row[15] = @as(u8, @intFromBool(t.is_opaque)) | (@as(u8, @intFromBool(t.is_equatable)) << 1) | (@as(u8, @intFromBool(t.no_function)) << 2);
            std.mem.writeInt(u32, row[16..20], t.payload_params, .little);
            std.mem.writeInt(u32, row[20..24], t.eq.context, .little);
            std.mem.writeInt(u32, row[24..28], t.compare.context, .little);
            row[28] = @backingInt(t.eq.status);
            row[29] = @backingInt(t.compare.status);
        }
    }
    {
        const out = bytes[offsets_of[@backingInt(Column.ctors)]..];
        for (iface.ctors, 0..) |c, i| {
            const row = out[i * 28 ..][0..28];
            std.mem.writeInt(u32, row[0..4], @backingInt(c.name), .little);
            std.mem.writeInt(u32, row[4..8], @backingInt(c.type), .little);
            std.mem.writeInt(u32, row[8..12], c.arity, .little);
            std.mem.writeInt(u32, row[12..16], c.arg_terms, .little);
            std.mem.writeInt(u32, row[16..20], c.quantified_start, .little);
            std.mem.writeInt(u32, row[20..24], c.fields, .little);
            row[24] = @backingInt(c.result);
        }
    }
    {
        const out = bytes[offsets_of[@backingInt(Column.schemes)]..];
        for (iface.schemes, 0..) |s, i| {
            const row = out[i * 16 ..][0..16];
            std.mem.writeInt(u32, row[0..4], s.quantified_start, .little);
            std.mem.writeInt(u32, row[4..8], s.quantified_count, .little);
            std.mem.writeInt(u32, row[8..12], @backingInt(s.body), .little);
            std.mem.writeInt(u32, row[12..16], s.effects, .little);
        }
    }
    if (iface.terms.len != 0) {
        const tags = iface.terms.items(.tag);
        const lhs = iface.terms.items(.lhs);
        const rhs = iface.terms.items(.rhs);
        const tags_out = bytes[offsets_of[@backingInt(Column.term_tags)]..];
        for (tags, 0..) |t, i| tags_out[i] = @backingInt(t);
        writeWords(bytes[offsets_of[@backingInt(Column.term_lhs)]..], lhs);
        writeWords(bytes[offsets_of[@backingInt(Column.term_rhs)]..], rhs);
    }
    writeWords(bytes[offsets_of[@backingInt(Column.extra)]..], iface.extra);
    {
        const out = bytes[offsets_of[@backingInt(Column.type_refs)]..];
        for (iface.type_refs, 0..) |r, i| {
            const row = out[i * 16 ..][0..16];
            std.mem.writeInt(u32, row[0..4], @backingInt(r.module), .little);
            std.mem.writeInt(u32, row[4..8], @backingInt(r.name), .little);
            std.mem.writeInt(u32, row[8..12], @backingInt(r.body), .little);
            row[12] = @backingInt(r.package);
        }
    }
    {
        const out = bytes[offsets_of[@backingInt(Column.hidden_types)]..];
        for (iface.hidden_types, 0..) |t, i| {
            const row = out[i * 24 ..][0..24];
            std.mem.writeInt(u32, row[0..4], @backingInt(t.name), .little);
            std.mem.writeInt(u16, row[4..6], t.arity, .little);
            row[6] = @backingInt(t.kind);
            row[7] = @as(u8, @intFromBool(t.is_equatable)) | (@as(u8, @intFromBool(t.no_function)) << 1);
            std.mem.writeInt(u32, row[8..12], t.payload_params, .little);
            std.mem.writeInt(u32, row[12..16], t.eq.context, .little);
            std.mem.writeInt(u32, row[16..20], t.compare.context, .little);
            row[20] = @backingInt(t.eq.status);
            row[21] = @backingInt(t.compare.status);
        }
    }
    {
        const out = bytes[offsets_of[@backingInt(Column.schemas)]..];
        for (iface.schemas, 0..) |s, i| {
            const row = out[i * 32 ..][0..32];
            std.mem.writeInt(u32, row[0..4], @backingInt(s.name), .little);
            std.mem.writeInt(u32, row[4..8], s.params_len, .little);
            std.mem.writeInt(u32, row[8..12], s.members_start, .little);
            std.mem.writeInt(u32, row[12..16], s.members_end, .little);
            std.mem.writeInt(u32, row[16..20], s.program_ctors_start, .little);
            std.mem.writeInt(u32, row[20..24], s.program_ctors_end, .little);
            std.mem.writeInt(u32, row[24..28], s.encoded_ctors_start, .little);
            std.mem.writeInt(u32, row[28..32], s.encoded_ctors_end, .little);
        }
    }
    {
        const out = bytes[offsets_of[@backingInt(Column.schema_members)]..];
        for (iface.schema_members, 0..) |m, i| {
            const row = out[i * 16 ..][0..16];
            std.mem.writeInt(u32, row[0..4], @backingInt(m.name), .little);
            std.mem.writeInt(u32, row[4..8], @backingInt(m.schema), .little);
            std.mem.writeInt(u32, row[8..12], @backingInt(m.scheme), .little);
            row[12] = @backingInt(m.kind);
            row[13] = m.arity;
            row[14] = @intFromBool(m.visible);
        }
    }
    {
        const out = bytes[offsets_of[@backingInt(Column.schema_ctors)]..];
        for (iface.schema_ctors, 0..) |c, i| {
            const row = out[i * 16 ..][0..16];
            std.mem.writeInt(u32, row[0..4], @backingInt(c.name), .little);
            std.mem.writeInt(u32, row[4..8], @backingInt(c.schema), .little);
            std.mem.writeInt(u32, row[8..12], @backingInt(c.scheme), .little);
            row[12] = @backingInt(c.endpoint);
            row[13] = c.arity;
            row[14] = @intFromBool(c.visible);
        }
    }
    writeWords(bytes[offsets_of[@backingInt(Column.symbols)]..], offsets);
    @memcpy(bytes[offsets_of[@backingInt(Column.strings)]..][0..blob.items.len], blob.items);

    return bytes;
}

/// A vocabulary table (`Interface.VocabRow`): six words per row.
fn writeVocab(out: []u8, rows: []const Interface.VocabRow) void {
    for (rows, 0..) |r, i| {
        writeWords(out[i * 24 ..][0..24], &.{
            @backingInt(r.name),
            r.facts,
            @backingInt(r.arg),
            @backingInt(r.via),
            r.on,
            @backingInt(r.scheme),
        });
    }
}

fn readVocab(gpa: Allocator, in: []const u8, n: u32) Allocator.Error![]Interface.VocabRow {
    const rows = try gpa.alloc(Interface.VocabRow, n);
    for (rows, 0..) |*r, i| {
        const row = in[i * 24 ..][0..24];
        r.* = .{
            .name = @fromBackingInt(@intCast(std.mem.readInt(u32, row[0..4], .little))),
            .facts = std.mem.readInt(u32, row[4..8], .little),
            .arg = @fromBackingInt(@intCast(std.mem.readInt(u32, row[8..12], .little))),
            .via = @fromBackingInt(@intCast(std.mem.readInt(u32, row[12..16], .little))),
            .on = std.mem.readInt(u32, row[16..20], .little),
            .scheme = @fromBackingInt(@intCast(std.mem.readInt(u32, row[20..24], .little))),
        };
    }
    return rows;
}

/// Whether a vocabulary table's names, `on` ranges and schemes stay inside
/// their columns, and its facts name only fact words and the pattern bit.
fn verifyVocab(iface: *const Interface, rows: []const Interface.VocabRow) bool {
    const symbols = iface.symbols.len;
    const known: u32 = (@as(u32, 1) << @typeInfo(Bir.FactWord).@"enum".field_names.len) - 1;
    for (rows) |r| {
        if (@backingInt(r.name) >= symbols) return false;
        if (r.facts & ~(known | Interface.VocabRow.pattern_bit) != 0) return false;
        if (r.arg.unwrap()) |s| if (@backingInt(s) >= symbols) return false;
        if (r.via.unwrap()) |s| if (@backingInt(s) >= symbols) return false;
        if (r.scheme != .none and @backingInt(r.scheme) >= iface.schemes.len) return false;
        if (r.on != Interface.no_terms) {
            const names = rangeOf(iface, r.on) orelse return false;
            for (names) |name| {
                if (name >= symbols) return false;
            }
        }
    }
    return true;
}

fn writeWords(out: []u8, words: []const u32) void {
    for (words, 0..) |word, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], word, .little);
}

/// `out.len` little-endian words from the front of `in`: one `memcpy` on a
/// little-endian host, a word at a time elsewhere.
fn readWords(out: []u32, in: []const u8) void {
    if (comptime @import("builtin").cpu.arch.endian() == .little) {
        @memcpy(std.mem.sliceAsBytes(out), in[0 .. out.len * 4]);
        return;
    }
    for (out, 0..) |*word, i| word.* = std.mem.readInt(u32, in[i * 4 ..][0..4], .little);
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

/// `read`, through `getOrPut`. The cache's cross-process load is the case the
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
            .find => |p| p.find(text) orelse error.UnknownSymbol,
            .get_or_put => |g| g.pool.getOrPut(g.gpa, text),
        };
    }

    /// The pool the record's symbols now live in, for `verify`'s text order.
    fn pool(i: *const Interning) *const InternPool.Global {
        return switch (i.*) {
            .find => |p| p,
            .get_or_put => |g| g.pool,
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
        const c: Column = @fromBackingInt(@intCast(i));
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
    const terms_len = lengths[@backingInt(Column.term_tags)];
    if (lengths[@backingInt(Column.term_lhs)] != terms_len) return error.BadRecord;
    if (lengths[@backingInt(Column.term_rhs)] != terms_len) return error.BadRecord;

    var iface: Interface = .empty;
    errdefer iface.deinit(gpa);

    // `symbols` first: every other column indexes it, and a string that is
    // not in this session's interner is the one failure that is not a miss.
    {
        const blob = bytes[offsets_of[@backingInt(Column.strings)]..][0..lengths[@backingInt(Column.strings)]];
        const words = bytes[offsets_of[@backingInt(Column.symbols)]..];
        const n = lengths[@backingInt(Column.symbols)];
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
        const in = bytes[offsets_of[@backingInt(Column.values)]..];
        const values = try gpa.alloc(Interface.Value, lengths[@backingInt(Column.values)]);
        iface.values = values;
        for (values, 0..) |*v, i| {
            const row = in[i * 12 ..][0..12];
            v.* = .{
                .name = @fromBackingInt(@intCast(std.mem.readInt(u32, row[0..4], .little))),
                .scheme = @fromBackingInt(@intCast(std.mem.readInt(u32, row[4..8], .little))),
                .is_foreign = row[8] & 1 == 1,
                .is_markup_primitive = row[8] & 2 == 2,
            };
        }
    }
    iface.elements = try readVocab(gpa, bytes[offsets_of[@backingInt(Column.elements)]..], lengths[@backingInt(Column.elements)]);
    iface.attributes = try readVocab(gpa, bytes[offsets_of[@backingInt(Column.attributes)]..], lengths[@backingInt(Column.attributes)]);
    iface.events = try readVocab(gpa, bytes[offsets_of[@backingInt(Column.events)]..], lengths[@backingInt(Column.events)]);
    {
        const in = bytes[offsets_of[@backingInt(Column.types)]..];
        const types = try gpa.alloc(Interface.Type, lengths[@backingInt(Column.types)]);
        iface.types = types;
        for (types, 0..) |*t, i| {
            const row = in[i * 32 ..][0..32];
            // Flags past bit 1 and the padding are zero in every record a
            // writer produced (`checker.md` §7: padding is not a field).
            if (row[15] & ~@as(u8, 7) != 0 or row[30] != 0 or row[31] != 0) return error.BadRecord;
            t.* = .{
                .name = @fromBackingInt(@intCast(std.mem.readInt(u32, row[0..4], .little))),
                .ctors_start = std.mem.readInt(u32, row[4..8], .little),
                .ctors_end = std.mem.readInt(u32, row[8..12], .little),
                .arity = std.mem.readInt(u16, row[12..14], .little),
                .kind = std.enums.fromInt(Interface.TypeKind, row[14]) orelse return error.BadRecord,
                .is_opaque = row[15] & 1 == 1,
                .is_equatable = (row[15] >> 1) & 1 == 1,
                .no_function = (row[15] >> 2) & 1 == 1,
                .payload_params = std.mem.readInt(u32, row[16..20], .little),
                .eq = .{
                    .context = std.mem.readInt(u32, row[20..24], .little),
                    .status = std.enums.fromInt(Interface.Derived.Status, row[28]) orelse return error.BadRecord,
                },
                .compare = .{
                    .context = std.mem.readInt(u32, row[24..28], .little),
                    .status = std.enums.fromInt(Interface.Derived.Status, row[29]) orelse return error.BadRecord,
                },
            };
        }
    }
    {
        const in = bytes[offsets_of[@backingInt(Column.ctors)]..];
        const ctors = try gpa.alloc(Interface.Ctor, lengths[@backingInt(Column.ctors)]);
        iface.ctors = ctors;
        for (ctors, 0..) |*c, i| {
            const row = in[i * 28 ..][0..28];
            if (row[25] != 0 or row[26] != 0 or row[27] != 0) return error.BadRecord;
            c.* = .{
                .name = @fromBackingInt(@intCast(std.mem.readInt(u32, row[0..4], .little))),
                .type = @fromBackingInt(@intCast(std.mem.readInt(u32, row[4..8], .little))),
                .arity = std.mem.readInt(u32, row[8..12], .little),
                .arg_terms = std.mem.readInt(u32, row[12..16], .little),
                .quantified_start = std.mem.readInt(u32, row[16..20], .little),
                .fields = std.mem.readInt(u32, row[20..24], .little),
                .result = std.enums.fromInt(Interface.CtorResult, row[24]) orelse return error.BadRecord,
            };
        }
    }
    {
        const in = bytes[offsets_of[@backingInt(Column.schemes)]..];
        const schemes = try gpa.alloc(Interface.Scheme, lengths[@backingInt(Column.schemes)]);
        iface.schemes = schemes;
        for (schemes, 0..) |*s, i| {
            const row = in[i * 16 ..][0..16];
            s.* = .{
                .quantified_start = std.mem.readInt(u32, row[0..4], .little),
                .quantified_count = std.mem.readInt(u32, row[4..8], .little),
                .body = @fromBackingInt(@intCast(std.mem.readInt(u32, row[8..12], .little))),
                .effects = std.mem.readInt(u32, row[12..16], .little),
            };
        }
    }
    {
        // Column by column, each one copy into a list of exactly its length:
        // the tags are checked in the bytes first, because a `Tag` value
        // outside the enum must never exist.
        const tags = bytes[offsets_of[@backingInt(Column.term_tags)]..][0..terms_len];
        var bad: u8 = 0;
        for (tags) |tag| bad |= @intFromBool(std.enums.fromInt(Interface.Term.Tag, tag) == null);
        if (bad != 0) return error.BadRecord;
        var terms: std.MultiArrayList(Interface.Term) = .empty;
        errdefer terms.deinit(gpa);
        try terms.setCapacity(gpa, terms_len);
        terms.len = terms_len;
        const s = terms.slice();
        @memcpy(@as([]u8, @ptrCast(s.items(.tag))), tags);
        readWords(s.items(.lhs), bytes[offsets_of[@backingInt(Column.term_lhs)]..]);
        readWords(s.items(.rhs), bytes[offsets_of[@backingInt(Column.term_rhs)]..]);
        iface.terms = terms.toOwnedSlice();
    }
    {
        const extra = try gpa.alloc(u32, lengths[@backingInt(Column.extra)]);
        iface.extra = extra;
        readWords(extra, bytes[offsets_of[@backingInt(Column.extra)]..]);
    }
    {
        const in = bytes[offsets_of[@backingInt(Column.type_refs)]..];
        const refs = try gpa.alloc(Interface.TypeRef, lengths[@backingInt(Column.type_refs)]);
        iface.type_refs = refs;
        for (refs, 0..) |*r, i| {
            const row = in[i * 16 ..][0..16];
            r.* = .{
                .module = @fromBackingInt(@intCast(std.mem.readInt(u32, row[0..4], .little))),
                .name = @fromBackingInt(@intCast(std.mem.readInt(u32, row[4..8], .little))),
                .body = @fromBackingInt(@intCast(std.mem.readInt(u32, row[8..12], .little))),
                .package = std.enums.fromInt(SourceStore.Package, row[12]) orelse return error.BadRecord,
            };
        }
    }
    {
        const in = bytes[offsets_of[@backingInt(Column.hidden_types)]..];
        const hidden = try gpa.alloc(Interface.HiddenType, lengths[@backingInt(Column.hidden_types)]);
        iface.hidden_types = hidden;
        for (hidden, 0..) |*t, i| {
            const row = in[i * 24 ..][0..24];
            if (row[7] & ~@as(u8, 3) != 0 or row[22] != 0 or row[23] != 0) return error.BadRecord;
            t.* = .{
                .name = @fromBackingInt(@intCast(std.mem.readInt(u32, row[0..4], .little))),
                .arity = std.mem.readInt(u16, row[4..6], .little),
                .kind = std.enums.fromInt(Interface.TypeKind, row[6]) orelse return error.BadRecord,
                .is_equatable = row[7] & 1 == 1,
                .no_function = (row[7] >> 1) & 1 == 1,
                .payload_params = std.mem.readInt(u32, row[8..12], .little),
                .eq = .{
                    .context = std.mem.readInt(u32, row[12..16], .little),
                    .status = std.enums.fromInt(Interface.Derived.Status, row[20]) orelse return error.BadRecord,
                },
                .compare = .{
                    .context = std.mem.readInt(u32, row[16..20], .little),
                    .status = std.enums.fromInt(Interface.Derived.Status, row[21]) orelse return error.BadRecord,
                },
            };
        }
    }
    {
        const in = bytes[offsets_of[@backingInt(Column.schemas)]..];
        const schemas = try gpa.alloc(Interface.Schema, lengths[@backingInt(Column.schemas)]);
        iface.schemas = schemas;
        for (schemas, 0..) |*s, i| {
            const row = in[i * 32 ..][0..32];
            s.* = .{
                .name = @fromBackingInt(@intCast(std.mem.readInt(u32, row[0..4], .little))),
                .params_len = std.mem.readInt(u32, row[4..8], .little),
                .members_start = std.mem.readInt(u32, row[8..12], .little),
                .members_end = std.mem.readInt(u32, row[12..16], .little),
                .program_ctors_start = std.mem.readInt(u32, row[16..20], .little),
                .program_ctors_end = std.mem.readInt(u32, row[20..24], .little),
                .encoded_ctors_start = std.mem.readInt(u32, row[24..28], .little),
                .encoded_ctors_end = std.mem.readInt(u32, row[28..32], .little),
            };
        }
    }
    {
        const in = bytes[offsets_of[@backingInt(Column.schema_members)]..];
        const members = try gpa.alloc(Interface.SchemaMember, lengths[@backingInt(Column.schema_members)]);
        iface.schema_members = members;
        for (members, 0..) |*m, i| {
            const row = in[i * 16 ..][0..16];
            if (row[15] != 0 or row[14] & ~@as(u8, 1) != 0) return error.BadRecord;
            m.* = .{
                .name = @fromBackingInt(@intCast(std.mem.readInt(u32, row[0..4], .little))),
                .schema = @fromBackingInt(@intCast(std.mem.readInt(u32, row[4..8], .little))),
                .scheme = @fromBackingInt(@intCast(std.mem.readInt(u32, row[8..12], .little))),
                .kind = std.enums.fromInt(Interface.SchemaMember.Kind, row[12]) orelse return error.BadRecord,
                .arity = row[13],
                .visible = row[14] & 1 == 1,
            };
        }
    }
    {
        const in = bytes[offsets_of[@backingInt(Column.schema_ctors)]..];
        const ctors = try gpa.alloc(Interface.SchemaCtor, lengths[@backingInt(Column.schema_ctors)]);
        iface.schema_ctors = ctors;
        for (ctors, 0..) |*c, i| {
            const row = in[i * 16 ..][0..16];
            if (row[15] != 0 or row[14] & ~@as(u8, 1) != 0) return error.BadRecord;
            c.* = .{
                .name = @fromBackingInt(@intCast(std.mem.readInt(u32, row[0..4], .little))),
                .schema = @fromBackingInt(@intCast(std.mem.readInt(u32, row[4..8], .little))),
                .scheme = @fromBackingInt(@intCast(std.mem.readInt(u32, row[8..12], .little))),
                .endpoint = std.enums.fromInt(Interface.SchemaCtor.Endpoint, row[12]) orelse return error.BadRecord,
                .arity = row[13],
                .visible = row[14] & 1 == 1,
            };
        }
    }

    if (!verify(&iface, interning.pool())) return error.BadRecord;
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
///     ctors.len`; `.payload_params` is `no_terms` or a range of exactly
///     ⌈arity / 32⌉ words with no bit past the last parameter; each derived
///     row is `present` with an even range of `(param, symbol slot)` pairs,
///     parameters below the arity, strictly increasing by `(param, method
///     text)` — so no pair twice — or absent with `no_terms` (interface v3,
///     `checker-v2.md` §14.2). The text order is why `verify` takes the
///     interner the record's symbols live in.
///   * `ctors[i].result` is `record_alias` exactly when its type row is an
///     alias; a `nominal` one has `fields == no_terms`, a `record_alias` one
///     a range of one symbol slot per argument.
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
///     pairs and an extension term, an `alias` term's row carrying a body. `var`'s
///     `lhs` is a quantifier ordinal with no scheme in hand, which
///     `InterfaceTerms.Reader` already bounds against the instantiation's own
///     variables.
///   * `type_refs[i].module` and `.name` are symbol slots, `.body` `none` or a term.
pub fn verify(iface: *const Interface, interner: *const InternPool.Global) bool {
    const symbols = iface.symbols.len;
    const terms = iface.terms.len;

    for (iface.values) |v| {
        if (@backingInt(v.name) >= symbols) return false;
        if (v.scheme != .none and @backingInt(v.scheme) >= iface.schemes.len) return false;
    }
    if (!verifyVocab(iface, iface.elements) or !verifyVocab(iface, iface.attributes) or !verifyVocab(iface, iface.events)) return false;
    for (iface.types) |t| {
        if (@backingInt(t.name) >= symbols) return false;
        if (t.ctors_start > t.ctors_end or t.ctors_end > iface.ctors.len) return false;
        if (!verifyFacts(iface, interner, t.arity, t.payload_params, t.eq, t.compare)) return false;
    }
    for (iface.hidden_types, 0..) |t, i| {
        if (@backingInt(t.name) >= symbols) return false;
        if (t.kind == .alias) return false;
        if (!verifyFacts(iface, interner, t.arity, t.payload_params, t.eq, t.compare)) return false;
        // Sorted by name text, each name once (`Interface.typeFacts`
        // binary-searches it).
        if (i != 0) {
            const before = interner.slice(iface.symbols[@backingInt(iface.hidden_types[i - 1].name)]);
            if (std.mem.order(u8, before, interner.slice(iface.symbols[@backingInt(t.name)])) != .lt) return false;
        }
    }
    for (iface.ctors) |c| {
        if (@backingInt(c.name) >= symbols) return false;
        if (@backingInt(c.type) >= iface.types.len) return false;
        if (c.quantified_start > iface.extra.len) return false;
        // A record-alias constructor is exactly the constructor of an alias
        // row, and only an alias row's constructor is one.
        if ((c.result == .record_alias) != (iface.types[@backingInt(c.type)].kind == .alias)) return false;
        switch (c.result) {
            .nominal => if (c.fields != Interface.no_terms) return false,
            .record_alias => {
                // One name per argument: argument `i` is field `i`.
                const names = rangeOf(iface, c.fields) orelse return false;
                if (names.len != c.arity) return false;
                for (names) |name| {
                    if (name >= symbols) return false;
                }
            },
        }
        if (c.arg_terms != Interface.no_terms) {
            const words = rangeOf(iface, c.arg_terms) orelse return false;
            for (words) |word| {
                if (!isTerm(terms, word)) return false;
            }
        }
    }
    for (iface.schemes) |s| {
        if (!isTerm(terms, @backingInt(s.body))) return false;
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
        // The effect block (transparent-effects-proposal.md §14.6): it fits,
        // its classes and steps are in range, and a field step names a
        // symbol slot.
        if (s.effects != Interface.no_terms) {
            if (s.effects >= iface.extra.len) return false;
            const words = iface.extra[s.effects..];
            const len = Interface.EffectBlock.measure(words) orelse return false;
            var sites = (Interface.EffectBlock{ .words = words[0..len] }).sites();
            while (sites.next()) |site| {
                for (site.steps) |step| {
                    if (Interface.EffectBlock.stepKind(step) == 4 and Interface.EffectBlock.stepIndex(step) >= symbols) return false;
                }
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
                // The body is on the row the term names (§14.2).
                if (l != std.math.maxInt(u32) and iface.type_refs[l].body == .none) return false;
                const words = rangeOf(iface, r) orelse return false;
                for (words) |word| {
                    if (!isTerm(terms, word)) return false;
                }
            },
        };
    }
    for (iface.type_refs) |r| {
        if (@backingInt(r.module) >= symbols) return false;
        if (@backingInt(r.name) >= symbols) return false;
        if (!isTerm(terms, @backingInt(r.body))) return false;
    }
    var members_end: u32 = 0;
    var ctors_end: u32 = 0;
    for (iface.schemas, 0..) |s, schema_i| {
        if (@backingInt(s.name) >= symbols) return false;
        if (s.members_start > s.members_end or s.members_end > iface.schema_members.len) return false;
        if (s.members_start != members_end or s.members_end - s.members_start != 7) return false;
        if (s.program_ctors_start > s.program_ctors_end or s.program_ctors_end > iface.schema_ctors.len) return false;
        if (s.encoded_ctors_start > s.encoded_ctors_end or s.encoded_ctors_end > iface.schema_ctors.len) return false;
        if (s.program_ctors_start != ctors_end or s.program_ctors_end != s.encoded_ctors_start) return false;
        if (s.program_ctors_end - s.program_ctors_start != s.encoded_ctors_end - s.encoded_ctors_start) return false;
        for (iface.schema_members[s.members_start..s.members_end], 0..) |m, kind_i| {
            if (@backingInt(m.schema) != schema_i or @backingInt(m.kind) != kind_i) return false;
            const extra_arity: u32 = switch (kind_i) {
                0, 1 => 0,
                2 => @intFromBool(s.params_len == 0),
                3, 4 => 1,
                5, 6 => 2,
                else => unreachable,
            };
            const full_arity = @as(u64, s.params_len) + @as(u64, extra_arity);
            const expected: u8 = if (full_arity >= std.math.maxInt(u8)) std.math.maxInt(u8) else @intCast(full_arity);
            if (m.arity != expected) return false;
        }
        for (iface.schema_ctors[s.program_ctors_start..s.program_ctors_end]) |c| {
            if (@backingInt(c.schema) != schema_i or c.endpoint != .type) return false;
        }
        for (iface.schema_ctors[s.encoded_ctors_start..s.encoded_ctors_end]) |c| {
            if (@backingInt(c.schema) != schema_i or c.endpoint != .encoded) return false;
        }
        const program = iface.schema_ctors[s.program_ctors_start..s.program_ctors_end];
        const encoded = iface.schema_ctors[s.encoded_ctors_start..s.encoded_ctors_end];
        for (program, encoded) |p, e| {
            if (iface.symbol(p.name) != iface.symbol(e.name) or p.arity != e.arity) return false;
        }
        members_end = s.members_end;
        ctors_end = s.encoded_ctors_end;
    }
    if (members_end != iface.schema_members.len or ctors_end != iface.schema_ctors.len) return false;
    for (iface.schema_members) |m| {
        if (@backingInt(m.name) >= symbols or @backingInt(m.schema) >= iface.schemas.len) return false;
        if (m.scheme == .none or @backingInt(m.scheme) >= iface.schemes.len) return false;
        if (!m.visible) return false;
    }
    for (iface.schema_ctors) |c| {
        if (@backingInt(c.name) >= symbols or @backingInt(c.schema) >= iface.schemas.len) return false;
        if (c.scheme == .none or @backingInt(c.scheme) >= iface.schemes.len) return false;
        if (!c.visible or c.arity > 1) return false;
    }
    return true;
}

/// `extra[start..][0..extra[start]]`, or null when the header or the words
/// leave the column. The shape `Interface.range` reads, checked instead of
/// degraded.
/// A type row's interface v3 facts (checker-v2.md §14.2): the
/// `payload_params` bitset, and each derived row `present` with a range of
/// `(param, symbol slot, scheme or none)` triples, parameters below the
/// arity, strictly increasing by `(param, method text)`, or absent with
/// `no_terms`.
fn verifyFacts(iface: *const Interface, interner: *const InternPool.Global, arity: u16, payload_params: u32, eq: Interface.Derived, compare: Interface.Derived) bool {
    const symbols = iface.symbols.len;
    if (payload_params != Interface.no_terms) {
        const bits = rangeOf(iface, payload_params) orelse return false;
        if (bits.len != (@as(usize, arity) + 31) / 32) return false;
        // No bit past the last parameter.
        if (arity % 32 != 0 and bits[bits.len - 1] >> @intCast(arity % 32) != 0) return false;
    }
    const n = Interface.context_words;
    for ([_]Interface.Derived{ eq, compare }) |d| {
        // A private method's row (§14.2): `(type_ref, method)`, a type
        // this record names and a symbol.
        if (d.status == .private_method or d.status == .requirement) {
            const words = rangeOf(iface, d.context) orelse return false;
            if (words.len != 2 or words[0] >= iface.type_refs.len or words[1] >= symbols) return false;
            continue;
        }
        if (d.status != .present) {
            if (d.context != Interface.no_terms) return false;
            continue;
        }
        const all = rangeOf(iface, d.context) orelse return false;
        // The row's scheme word: `none`, or a scheme.
        if (all.len == 0 or (all.len - 1) % n != 0) return false;
        const none = std.math.maxInt(u32);
        if (all[0] != none and all[0] >= iface.schemes.len) return false;
        const words = all[1..];
        var i: usize = 0;
        while (i < words.len) : (i += n) {
            // Every parameter one the type has, every method a slot, and a
            // slot only with a scheme to hold it.
            if (words[i] >= arity or words[i + 1] >= symbols) return false;
            if (words[i + 2] != none and all[0] == none) return false;
            // Strictly sorted by `(param, method text)` (§14.2): an entry
            // out of order, or the same pair twice, is refused.
            if (i == 0) continue;
            if (words[i] < words[i - n]) return false;
            if (words[i] == words[i - n]) {
                const this = interner.slice(iface.symbols[words[i + 1]]);
                const before = interner.slice(iface.symbols[words[i + 1 - n]]);
                if (std.mem.order(u8, before, this) != .lt) return false;
            }
        }
    }
    return true;
}

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
const fuzzing = @import("../fuzzing.zig");

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
    try testing.expectEqualSlices(Interface.HiddenType, a.hidden_types, b.hidden_types);
    try testing.expectEqualSlices(Interface.VocabRow, a.elements, b.elements);
    try testing.expectEqualSlices(Interface.VocabRow, a.attributes, b.attributes);
    try testing.expectEqualSlices(Interface.VocabRow, a.events, b.events);
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
        \\    a × a
        \\
        \\
        \\pub type alias Point =
        \\    { y : Int, x : Int }
        \\
        \\
        \\pub twice : a → a
        \\twice x =
        \\    x
        \\
        \\
        \\pub widen r =
        \\    r.width
        \\
        \\
        \\pub pack : a, a → Pair a
        \\pack x y =
        \\    ( x, y )
        \\
        },
        .{ .path = "B.beni", .source =
        \\import A
        \\
        \\
        \\pub use : A.Shape Int → A.Pair Int
        \\use s =
        \\    case s of
        \\        A.Box a b →
        \\            A.pack a b
        \\
        \\        A.Empty →
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
        .schemas = &.{},
        .schema_members = &.{},
        .schema_ctors = &.{},
        .schemes = &.{},
        .terms = .empty,
        .extra = &.{},
        .type_refs = &.{},
        .symbols = &.{ a, a, a },
    };
    const bytes = try write(testing.allocator, &iface, &global);
    defer testing.allocator.free(bytes);
    // Three slots, one record: 4 + 10 bytes padded to 16.
    const row = bytes[header_bytes + @backingInt(Column.strings) * 8 ..][0..8];
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
        .schemas = &.{},
        .schema_members = &.{},
        .schema_ctors = &.{},
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
        .schemas = &.{},
        .schema_members = &.{},
        .schema_ctors = &.{},
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
        .schemas = &.{},
        .schema_members = &.{},
        .schema_ctors = &.{},
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

test "interface v3's rows round-trip, and verify refuses each one that does not describe itself" {
    // `checker-v2.md` §14.2: a `u16` arity, a record-alias constructor's
    // field names, the payload bitset and a derived context. The good record
    // first, then one mutation per rule `verify` states for them.
    var global = try InternPool.Global.init(testing.allocator);
    defer global.deinit(testing.allocator);
    const name = try global.getOrPut(testing.allocator, "P");
    const x = try global.getOrPut(testing.allocator, "x");
    const eq = try global.getOrPut(testing.allocator, "eq");
    const compare = try global.getOrPut(testing.allocator, "compare");
    // extra: [0] fields range (x, x); [3] bitset, 300 parameters = 10 words;
    // [14] context, (299, compare) then (299, eq) — `compare` sorts first —
    // the row's scheme word (none), then three words per entry, no slot
    // (§14.2).
    var extra: [22]u32 = @splat(0);
    extra[0] = 2;
    extra[1] = 1;
    extra[2] = 1;
    extra[3] = 10;
    extra[4 + 9] = @as(u32, 1) << 11; // parameter 299 = word 9, bit 11
    extra[14] = 7;
    extra[15] = std.math.maxInt(u32);
    extra[16] = 299;
    extra[17] = 3;
    extra[18] = std.math.maxInt(u32);
    extra[19] = 299;
    extra[20] = 2;
    extra[21] = std.math.maxInt(u32);
    // Type 0 is a nominal type of 300 parameters; type 1 the alias `P`,
    // whose one constructor is its record's.
    const good_types = [_]Interface.Type{ .{
        .name = @fromBackingInt(@intCast(0)),
        .arity = 300,
        .kind = .adt,
        .is_opaque = false,
        .is_equatable = false,
        .ctors_start = 0,
        .ctors_end = 0,
        .payload_params = 3,
        .eq = .{ .status = .present, .context = 14 },
        .compare = .{ .status = .function },
    }, .{
        .name = @fromBackingInt(@intCast(0)),
        .arity = 0,
        .kind = .alias,
        .is_opaque = false,
        .is_equatable = false,
        .ctors_start = 0,
        .ctors_end = 1,
        .eq = .{ .status = .alias },
        .compare = .{ .status = .alias },
    } };
    const good_ctors = [_]Interface.Ctor{.{ .name = @fromBackingInt(@intCast(0)), .type = @fromBackingInt(@intCast(1)), .arity = 2, .result = .record_alias, .fields = 0 }};
    const record = struct {
        fn of(types: []const Interface.Type, ctors: []const Interface.Ctor, words: []const u32, symbols: []const Symbol) Interface {
            return .{
                .values = &.{},
                .types = types,
                .ctors = ctors,
                .schemas = &.{},
                .schema_members = &.{},
                .schema_ctors = &.{},
                .schemes = &.{},
                .terms = .empty,
                .extra = words,
                .type_refs = &.{},
                .symbols = symbols,
            };
        }
    }.of;
    const symbols = [_]Symbol{ name, x, eq, compare };
    const good = record(&good_types, &good_ctors, &extra, &symbols);
    try testing.expect(verify(&good, &global));
    try expectRoundTrip(&good, &global);

    // A bit past the last parameter.
    var bad_bits = extra;
    bad_bits[4 + 9] |= @as(u32, 1) << 12;
    try testing.expect(!verify(&record(&good_types, &good_ctors, &bad_bits, &symbols), &global));
    // A bitset one word short.
    var short_bits = good_types;
    short_bits[0].arity = 330;
    try testing.expect(!verify(&record(&short_bits, &good_ctors, &extra, &symbols), &global));
    // A context naming a parameter the type does not have.
    var narrow = good_types;
    narrow[0].arity = 299;
    narrow[0].payload_params = Interface.no_terms;
    try testing.expect(!verify(&record(&narrow, &good_ctors, &extra, &symbols), &global));
    // A context on an absent row.
    var absent = good_types;
    absent[0].compare = .{ .status = .function, .context = 14 };
    try testing.expect(!verify(&record(&absent, &good_ctors, &extra, &symbols), &global));
    // A record-alias row whose names do not number its arguments, and a
    // nominal row with names.
    var three = good_ctors;
    three[0].arity = 3;
    try testing.expect(!verify(&record(&good_types, &three, &extra, &symbols), &global));
    var nominal = good_ctors;
    nominal[0].result = .nominal;
    nominal[0].fields = Interface.no_terms;
    try testing.expect(!verify(&record(&good_types, &nominal, &extra, &symbols), &global));
    // A record-alias constructor of a nominal type.
    var on_adt = good_ctors;
    on_adt[0].type = @fromBackingInt(@intCast(0));
    try testing.expect(!verify(&record(&good_types, &on_adt, &extra, &symbols), &global));
    // One parameter's methods out of text order, and the same pair twice.
    var swapped = extra;
    swapped[17] = 2;
    swapped[20] = 3;
    try testing.expect(!verify(&record(&good_types, &good_ctors, &swapped, &symbols), &global));
    var twice = extra;
    twice[17] = 2;
    try testing.expect(!verify(&record(&good_types, &good_ctors, &twice, &symbols), &global));
    // A row naming a scheme the record does not have, and an entry naming a
    // slot of a row with no scheme.
    var no_scheme = extra;
    no_scheme[15] = 0;
    try testing.expect(!verify(&record(&good_types, &good_ctors, &no_scheme, &symbols), &global));
    var no_row_scheme = extra;
    no_row_scheme[18] = 0;
    try testing.expect(!verify(&record(&good_types, &good_ctors, &no_row_scheme, &symbols), &global));

    // A hidden row round-trips with its facts, and is held to the
    // same rules; hidden rows are sorted by name text.
    const hidden = [_]Interface.HiddenType{
        .{ .name = @fromBackingInt(@intCast(3)), .arity = 300, .kind = .adt, .is_equatable = false, .payload_params = 3, .eq = .{ .status = .present, .context = 14 }, .compare = .{ .status = .function } },
        .{ .name = @fromBackingInt(@intCast(2)), .arity = 0, .kind = .foreign, .is_equatable = true, .eq = .{ .status = .foreign }, .compare = .{ .status = .foreign } },
    };
    var with_hidden = good;
    with_hidden.hidden_types = &hidden;
    try testing.expect(verify(&with_hidden, &global));
    try expectRoundTrip(&with_hidden, &global);
    const unsorted = [_]Interface.HiddenType{ hidden[1], hidden[0] };
    with_hidden.hidden_types = &unsorted;
    try testing.expect(!verify(&with_hidden, &global));
    var hidden_absent = hidden;
    hidden_absent[1].eq.context = 14;
    with_hidden.hidden_types = &hidden_absent;
    try testing.expect(!verify(&with_hidden, &global));
}

test "a column offset past the end, and a strings record that overruns the blob" {
    var global = try InternPool.Global.init(testing.allocator);
    defer global.deinit(testing.allocator);
    const name = try global.getOrPut(testing.allocator, "field");
    const iface: Interface = .{
        .values = &.{.{ .name = @fromBackingInt(@intCast(0)), .is_foreign = false, .scheme = .none }},
        .types = &.{},
        .ctors = &.{},
        .schemas = &.{},
        .schema_members = &.{},
        .schema_ctors = &.{},
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
        const row = copy[header_bytes + @backingInt(Column.values) * 8 ..][0..8];
        std.mem.writeInt(u32, row[0..4], @intCast(bytes.len), .little);
        try testing.expectError(error.BadRecord, read(testing.allocator, copy, &global));
    }
    // A column length that leaves the file.
    {
        const copy = try testing.allocator.dupe(u8, bytes);
        defer testing.allocator.free(copy);
        const row = copy[header_bytes + @backingInt(Column.values) * 8 ..][0..8];
        std.mem.writeInt(u32, row[4..8], 1000, .little);
        try testing.expectError(error.BadRecord, read(testing.allocator, copy, &global));
    }
    // A length chosen to wrap 32 bits.
    {
        const copy = try testing.allocator.dupe(u8, bytes);
        defer testing.allocator.free(copy);
        const row = copy[header_bytes + @backingInt(Column.values) * 8 ..][0..8];
        std.mem.writeInt(u32, row[4..8], std.math.maxInt(u32) / 6, .little);
        try testing.expectError(error.BadRecord, read(testing.allocator, copy, &global));
    }
    // A misaligned column.
    {
        const copy = try testing.allocator.dupe(u8, bytes);
        defer testing.allocator.free(copy);
        const row = copy[header_bytes + @backingInt(Column.values) * 8 ..][0..8];
        std.mem.writeInt(u32, row[0..4], body_start + 1, .little);
        try testing.expectError(error.BadRecord, read(testing.allocator, copy, &global));
    }
    // A `strings` record whose length word overruns the blob.
    {
        const copy = try testing.allocator.dupe(u8, bytes);
        defer testing.allocator.free(copy);
        const at = std.mem.readInt(u32, copy[header_bytes + @backingInt(Column.strings) * 8 ..][0..4], .little);
        std.mem.writeInt(u32, copy[at..][0..4], 1000, .little);
        try testing.expectError(error.BadRecord, read(testing.allocator, copy, &global));
    }
    // A `symbols` slot pointing past the blob.
    {
        const copy = try testing.allocator.dupe(u8, bytes);
        defer testing.allocator.free(copy);
        const at = std.mem.readInt(u32, copy[header_bytes + @backingInt(Column.symbols) * 8 ..][0..4], .little);
        std.mem.writeInt(u32, copy[at..][0..4], 1000, .little);
        try testing.expectError(error.BadRecord, read(testing.allocator, copy, &global));
    }
    // A `values` row naming a symbol slot that is not there.
    {
        const copy = try testing.allocator.dupe(u8, bytes);
        defer testing.allocator.free(copy);
        const at = std.mem.readInt(u32, copy[header_bytes + @backingInt(Column.values) * 8 ..][0..4], .little);
        std.mem.writeInt(u32, copy[at..][0..4], 9, .little);
        try testing.expectError(error.BadRecord, read(testing.allocator, copy, &global));
    }
}

/// The module whose record the mutation tests below start from: types,
/// constructors, schemes, terms and a reference to an imported type.
const mutation_fixture: TestProject.Module = .{ .path = "F.beni", .source =
    \\pub type Tree a
    \\    = Leaf
    \\    | Node (Tree a) a (Tree a)
    \\
    \\
    \\pub type alias Named a =
    \\    { name : String, value : a }
    \\
    \\
    \\pub wrap : a → Named a
    \\wrap v =
    \\    { name = "x", value = v }
    \\
    \\
    \\pub compareBoth a b =
    \\    a < b
    \\
    \\
    \\pub pairUp : a, b → a × b
    \\pairUp x y =
    \\    ( x, y )
    \\
};

/// Where column `c`'s first row starts in `bytes`, from the column table.
fn columnAt(bytes: []const u8, c: Column) u32 {
    return std.mem.readInt(u32, bytes[header_bytes + @backingInt(c) * 8 ..][0..4], .little);
}

/// The length word of column `c` in the column table.
fn columnLen(bytes: []u8, c: Column) *[4]u8 {
    return bytes[header_bytes + @backingInt(c) * 8 + 4 ..][0..4];
}

test "each check the reader makes refuses the one mutation aimed at it" {
    // One mutation per check `decode` makes on the rows this record has,
    // each applied alone to a copy of a record that loads. The header, the
    // column table's bounds, the strings and a symbol index are the tests
    // above; these are the rest. A byte a writer always leaves zero is
    // refused so that one record has one encoding.
    var p = try TestProject.initWith(testing.allocator, &.{mutation_fixture}, .{ .phases = Session.check_phases });
    defer p.deinit();
    const gpa = testing.allocator;
    const interner = &p.session.interner;
    const bytes = try write(gpa, &p.session.resolution.interfaces[p.module("F").?.int()], interner);
    defer gpa.free(bytes);
    {
        var back = try read(gpa, bytes, interner);
        back.deinit(gpa);
    }
    // Every row a mutation below lands in is there.
    for ([_]Column{ .types, .ctors, .term_tags, .type_refs }) |c| {
        try testing.expect(std.mem.readInt(u32, columnLen(bytes, c), .little) != 0);
    }
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, columnLen(bytes, .hidden_types), .little));

    const Mutation = struct {
        what: []const u8,
        column: Column,
        /// The byte of the column's first row to overwrite, or null to
        /// change the column table instead (`table`).
        byte: ?u32 = null,
        value: u8 = 0,
        table: enum { none, offset_in_header, misaligned, one_short } = .none,
    };
    const mutations = [_]Mutation{
        // The two offsets go on an empty column, so nothing but the offset
        // check stands between them and a record that loads.
        .{ .what = "a column that starts inside the header", .column = .hidden_types, .table = .offset_in_header },
        .{ .what = "a column that starts off a four-byte boundary", .column = .hidden_types, .table = .misaligned },
        .{ .what = "a term_lhs column shorter than the term tags", .column = .term_lhs, .table = .one_short },
        .{ .what = "a term_rhs column shorter than the term tags", .column = .term_rhs, .table = .one_short },
        .{ .what = "a type's flags past bit 2", .column = .types, .byte = 15, .value = 0x08 },
        .{ .what = "a type's padding", .column = .types, .byte = 30, .value = 1 },
        .{ .what = "a type kind no version defines", .column = .types, .byte = 14, .value = 0xff },
        .{ .what = "an eq status no version defines", .column = .types, .byte = 28, .value = 0xff },
        .{ .what = "a compare status no version defines", .column = .types, .byte = 29, .value = 0xff },
        .{ .what = "a constructor's padding", .column = .ctors, .byte = 25, .value = 1 },
        .{ .what = "a constructor result no version defines", .column = .ctors, .byte = 24, .value = 0xff },
        .{ .what = "a term tag no version defines", .column = .term_tags, .byte = 0, .value = 0xff },
        .{ .what = "a type reference's package no version defines", .column = .type_refs, .byte = 12, .value = 0xff },
    };
    var loaded: usize = 0;
    for (mutations) |m| {
        const copy = try gpa.dupe(u8, bytes);
        defer gpa.free(copy);
        switch (m.table) {
            .none => copy[columnAt(copy, m.column) + m.byte.?] = m.value,
            .offset_in_header => std.mem.writeInt(u32, copy[header_bytes + @backingInt(m.column) * 8 ..][0..4], header_bytes, .little),
            .misaligned => std.mem.writeInt(u32, copy[header_bytes + @backingInt(m.column) * 8 ..][0..4], body_start + 1, .little),
            .one_short => {
                const len = columnLen(copy, m.column);
                std.mem.writeInt(u32, len, std.mem.readInt(u32, len, .little) - 1, .little);
            },
        }
        var back = read(gpa, copy, interner) catch |err| switch (err) {
            error.BadRecord => continue,
            else => return err,
        };
        back.deinit(gpa);
        std.debug.print("read back a record with {s}\n", .{m.what});
        loaded += 1;
    }
    try testing.expectEqual(@as(usize, 0), loaded);
}

// **The fuzz sweep**, opt-in (`zig build fuzz`, `fuzzing.zig`): the record
// above, mutated exhaustively at every place the format has a boundary, and
// then at random; every mutation must end in an error or in a record that
// `verify` accepts, and never in an out-of-bounds read. Debug, so `std`'s
// own bounds checks are live and a read past a slice is a panic rather than
// a silent wrong answer. Deterministic: a fixed seed, a fixed corpus and a
// fixed mutation schedule, so a failure reproduces exactly.
/// Which part of the mutation sweep below a test runs: they are three tests so
/// that the test runner's shards can run them at the same time.
const SweepPart = enum { systematic, random_first, random_second };

test "fuzz: a record truncated or with a bit flipped never reads back as an unverified one" {
    try fuzzing.skipUnlessFuzzing();
    try mutatedRecordSweep(.systematic);
}

test "fuzz: a record with random bytes overwritten never reads back as an unverified one, first seed" {
    try fuzzing.skipUnlessFuzzing();
    try mutatedRecordSweep(.random_first);
}

test "fuzz: a record with random bytes overwritten never reads back as an unverified one, second seed" {
    try fuzzing.skipUnlessFuzzing();
    try mutatedRecordSweep(.random_second);
}

/// Random single-byte writes per random part of the sweep.
const random_writes = 15_000;

fn mutatedRecordSweep(part: SweepPart) !void {
    var p = try TestProject.initWith(testing.allocator, &.{mutation_fixture}, .{ .phases = Session.check_phases });
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
            try testing.expect(verify(&back, interner));
            const again = try write(testing.allocator, &back, interner);
            testing.allocator.free(again);
            ok.* += 1;
        }
    }.go;

    // 1. Truncation at every byte: the whole header and table, then every
    //    fourth byte of the body (a column boundary is always at a multiple
    //    of four, so this hits all of them).
    if (part == .systematic) {
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
    if (part == .systematic) {
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
    if (part == .systematic) {
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
    if (part != .systematic) {
        var prng: std.Random.DefaultPrng = .init(if (part == .random_first) 0xBE1_1FACE else ~@as(u64, 0xBE1_1FACE));
        const random = prng.random();
        const copy = try gpa.dupe(u8, bytes);
        defer gpa.free(copy);
        for (0..random_writes) |_| {
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
    try testing.expect(attempts >= @as(usize, if (part == .systematic) 1_000 else random_writes));
}
