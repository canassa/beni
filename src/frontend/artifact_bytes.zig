//! One file's front-end artifact as BYTES (docs/design/fast-compiler.md §8,
//! *The front-end artifacts, and the file key*; `plans/m4-2.md` §2, §3).
//!
//! One file per SOURCE FILE, named by its **file key** — which is not M4-1's
//! module key: it holds no import, no sibling hash and no `core_epoch`, so a
//! body edit in a leaf moves the leaf's artifact and not its importers'.
//! What travels: the **pre-resolve** `Bir`, the token `tag` and `start`
//! columns, the `line_starts` table and the front-end diagnostics as the
//! lex/parse/lower phases RENDERED them. What does not: the `Ast` and the
//! `comments`, because nothing on a `check` or a `build` path reads either
//! after `lower` returns (`frontend.md` §3.5).
//!
//! ```
//! header    magic "BENIFE\x00\x00" (8)  format_version: u32  section_count: u32
//!           key: [16]u8                 the file key this artifact was written for
//!           total_len: u32              the WHOLE file's length, in bytes
//!           reserved: u32               zero
//!           body_hash: [16]u8           SipHash128(1,3) over everything after it
//! table     section_count × { offset: u32, len: u32 }        offsets from byte 0
//! sections  in table order, each 4-byte aligned, gaps zero-filled
//! ```
//!
//! Same shape as `resolve/iface_bytes.zig`'s record and `cache/entry_bytes.zig`'s
//! entry — magic, a version, the key repeated in the header, a `{offset, len}`
//! table from byte 0, little-endian scalars, and **a bad file is a MISS, never
//! a message and never an exit code**. Three formats and one shape is
//! deliberate (`checker.md` §7): a reader written against one is written
//! against all three.
//!
//! **THE TORN-FILE INVARIANT.** `cache/Dir.zig` writes this file with one
//! `create` + one sequential `writeStreamingAll` of one buffer — no temp file,
//! no `rename`, no seek, no sparse region (`plans/m4-2.md` §6 B). What makes
//! that safe is stated here because it is a property of the FORMAT: the header
//! carries `total_len`, and **the reader's first structural check is
//! `bytes.len == total_len`**. Every prefix a concurrent reader can observe is
//! therefore shorter than the file it is a prefix of, and is a miss. The
//! section table's bounds are checked next, and the body hash last, so a file
//! that is the right LENGTH but not the right BYTES — a same-length file with
//! flipped bits, which a content-addressed name cannot detect — is a miss too.
//! A content hash guards identity; `body_hash` guards integrity.
//!
//! **Little-endian by definition and host-alignment-independent**, exactly as
//! the record is: `plans/m4-2.md` §4 measured `read` beating `mmap` 2.2× at
//! this granularity, and a `read` has no alignment to satisfy. Nothing in a
//! cache directory is machine-specific *by layout*.
//!
//! **Symbols travel as text.** `Bir.symbols` is the one column that holds a
//! `Symbol` (`bir/Bir.zig:57-60`) and the token sections hold none at all,
//! because `payload` — the only place a token ever did — is not cached. On the
//! way out each slot becomes an index into a per-artifact `strings` table; on
//! the way in the loader `getOrPut`s each DISTINCT string once into the
//! WORKER's `Local` pool and then calls the existing `Bir.applyRemap`, which
//! is the loop that already exists for the interner merge. *Rejected: a lookup
//! per symbol SLOT — 3.4× the hashing for the same answer, and `strings` stops
//! deduplicating.*

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const BirDiagnostics = @import("../bir/Diagnostics.zig");
const InternPool = @import("../InternPool.zig");
const Token = @import("../lex/Token.zig");
const iface_bytes = @import("../resolve/iface_bytes.zig");

/// First eight bytes of every artifact.
pub const magic = "BENIFE\x00\x00";

/// Bumped whenever the meaning of any byte changes. A format change is a
/// version bump and a cache discard, never a migration into spare bytes
/// (`plans/m4-plan.md` D4) — and the compiler build id in the file key means
/// a version bump is belt and braces rather than the only defence.
pub const format_version: u32 = 1;

/// The sections, in this order and no other (`fast-compiler.md` §8).
///
/// `insts` is split into its four SoA columns for the reason the record's
/// `terms` is: that is what the structure already is, so a column is a
/// `memcpy` on a little-endian host rather than a walk.
///
/// **`bir_module_doc` is a correction to the spec's list**, which named
/// twenty sections and forgot `Bir.module_doc_start`/`module_doc_end` — two
/// scalars that are as much a part of the record as `decls` is, and that
/// `dump --stage=bir` prints. It is appended rather than inserted so every
/// section the spec DID name keeps the index the spec gave it.
pub const Section = enum(u32) {
    bir_insts_tag,
    bir_insts_token,
    bir_insts_lhs,
    bir_insts_rhs,
    bir_extra,
    bir_string_bytes,
    bir_symbols,
    bir_decls,
    bir_ctors,
    bir_locals,
    bir_refs,
    bir_imports,
    bir_exposed,
    bir_interface,
    bir_diagnostics,
    token_tags,
    token_starts,
    line_starts,
    diagnostics,
    strings,
    bir_module_doc,

    pub const count: u32 = @typeInfo(Section).@"enum".fields.len;
};

/// magic(8) + version(4) + section_count(4) + key(16) + total_len(4) +
/// reserved(4) + body_hash(16).
pub const header_bytes: u32 = 56;
const table_bytes: u32 = Section.count * 8;
const body_start: u32 = header_bytes + table_bytes;
/// Where `body_hash` covers from: everything after the header's own hash
/// field, which is the section table and every section.
const hashed_from: u32 = header_bytes;

/// Largest artifact this reads. A module's is ~13 kB; the bound exists so a
/// file somebody else put in the directory cannot be read into memory whole.
pub const max_artifact_bytes: usize = 256 * 1024 * 1024;

pub const ReadError = error{
    /// The bytes are not an artifact this compiler can read, or they are not
    /// the artifact that was asked for. The caller lexes from source.
    BadArtifact,
} || Allocator.Error;

// ---------------------------------------------------------------------------
// The rendered front-end diagnostic
// ---------------------------------------------------------------------------

/// One front-end diagnostic as the phase that will not run RENDERED it
/// (`plans/m4-2.md` §3).
///
/// **Positions rather than offsets**, because a position is a function of the
/// content the file key pins and a reporter would otherwise need the
/// line-start table twice. **`span.file` and `title` are NOT stored** and are
/// recomputed from the path and the code, so a file that MOVED without
/// changing its bytes still names itself correctly — which is also what keeps
/// a path out of the bytes.
pub const Diagnostic = struct {
    code: u16,
    severity: u8,
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
    /// Borrowed from the artifact's bytes on the way out.
    message: []const u8,
};

const diagnostic_row_bytes: u32 = 32; // code(2) severity(1) pad(1) 4×u32 + start(4) len(4)
const diagnostics_header: u32 = 8; // count(4) + messages_len(4)

// ---------------------------------------------------------------------------
// The `strings` table
// ---------------------------------------------------------------------------

/// The distinct identifier texts one artifact's `Bir.symbols` refers to:
/// `count`, then `count` × `{offset, len}` into the blob that follows.
///
/// `bir_symbols` holds one `u32` INDEX into this table per symbol slot, so a
/// name mentioned forty times costs forty four-byte slots and one string —
/// the measured ratio is 117 201 occurrences to 38 274 distinct-per-file
/// (`plans/m4-2.md` §7).
pub const Strings = struct {
    /// Borrowed from the artifact's bytes.
    bytes: []const u8,
    count: u32,

    pub const empty: Strings = .{ .bytes = &.{}, .count = 0 };

    const header: u32 = 4;
    const row: u32 = 8;

    /// The `i`th string. `i` must be `< count`, which `read` has checked.
    pub fn at(s: Strings, i: u32) []const u8 {
        const r = s.bytes[header + i * row ..][0..row];
        const offset = std.mem.readInt(u32, r[0..4], .little);
        const len = std.mem.readInt(u32, r[4..8], .little);
        return s.bytes[offset..][0..len];
    }
};

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/// Everything one artifact holds, as the producing worker has it.
pub const Input = struct {
    key: [16]u8,
    /// PRE-resolve. `Resolve` rewrites instructions in place into forms that
    /// hold a `Graph.Index`, which is the one thing a cache may not hold.
    bir: *const Bir,
    /// The producing worker's own pool — `bir.symbols` is local to it until
    /// the session's merge, and this is where their text comes from.
    interner: *const InternPool.Local,
    tokens: *const Token.TokenList,
    line_starts: []const u32,
    diagnostics: []const Diagnostic,
};

/// `in` as bytes. The caller owns the result; `scratch` holds the string
/// table and is the worker's arena in the compiler.
pub fn write(gpa: Allocator, scratch: Allocator, in: Input) Allocator.Error![]u8 {
    const bir = in.bir;

    // 1. The string table, in first-occurrence order over `bir.symbols` —
    //    source order, and therefore the same at every `--jobs`.
    var table: std.AutoArrayHashMapUnmanaged(InternPool.Symbol, u32) = .empty;
    defer table.deinit(scratch);
    const slots = try scratch.alloc(u32, bir.symbols.len);
    defer scratch.free(slots);
    var blob_len: u32 = 0;
    for (bir.symbols, slots) |symbol, *slot| {
        const got = try table.getOrPut(scratch, symbol);
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(table.count() - 1);
            blob_len += @intCast(in.interner.slice(symbol).len);
        }
        slot.* = got.value_ptr.*;
    }
    const distinct: u32 = @intCast(table.count());

    // 2. Section lengths, then the one buffer.
    var lengths: [Section.count]u32 = @splat(0);
    const tokens = in.tokens.slice();
    const insts = bir.insts;
    lengths[@intFromEnum(Section.bir_insts_tag)] = @intCast(insts.len);
    lengths[@intFromEnum(Section.bir_insts_token)] = @intCast(insts.len * 4);
    lengths[@intFromEnum(Section.bir_insts_lhs)] = @intCast(insts.len * 4);
    lengths[@intFromEnum(Section.bir_insts_rhs)] = @intCast(insts.len * 4);
    lengths[@intFromEnum(Section.bir_extra)] = @intCast(bir.extra.len * 4);
    lengths[@intFromEnum(Section.bir_string_bytes)] = @intCast(bir.string_bytes.len);
    lengths[@intFromEnum(Section.bir_symbols)] = @intCast(bir.symbols.len * 4);
    lengths[@intFromEnum(Section.bir_decls)] = @intCast(bir.decls.len * rowBytes(Bir.Decl));
    lengths[@intFromEnum(Section.bir_ctors)] = @intCast(bir.ctors.len * rowBytes(Bir.Ctor));
    lengths[@intFromEnum(Section.bir_locals)] = @intCast(bir.locals.len * rowBytes(Bir.Local));
    lengths[@intFromEnum(Section.bir_refs)] = @intCast(bir.refs.len * rowBytes(Bir.Ref));
    lengths[@intFromEnum(Section.bir_imports)] = @intCast(bir.imports.len * rowBytes(Bir.Import));
    lengths[@intFromEnum(Section.bir_exposed)] = @intCast(bir.exposed.len * rowBytes(Bir.Exposed));
    lengths[@intFromEnum(Section.bir_interface)] = @intCast(bir.interface.len * 4);
    lengths[@intFromEnum(Section.bir_diagnostics)] = @intCast(bir.diagnostics.len * rowBytes(BirDiagnostics.Item));
    lengths[@intFromEnum(Section.token_tags)] = @intCast(tokens.len);
    lengths[@intFromEnum(Section.token_starts)] = @intCast(tokens.len * 4);
    lengths[@intFromEnum(Section.line_starts)] = @intCast(in.line_starts.len * 4);
    lengths[@intFromEnum(Section.diagnostics)] = diagnosticsLen(in.diagnostics);
    lengths[@intFromEnum(Section.strings)] = Strings.header + distinct * Strings.row + blob_len;
    lengths[@intFromEnum(Section.bir_module_doc)] = 8;

    var offsets: [Section.count]u32 = @splat(0);
    var at: u32 = body_start;
    for (0..Section.count) |i| {
        offsets[i] = at;
        at += lengths[i];
        at += @intCast(pad4(at));
    }
    const total = at;

    const out = try gpa.alloc(u8, total);
    errdefer gpa.free(out);
    @memset(out, 0); // every gap is zero-filled, and hashed like everything else

    @memcpy(out[0..8], magic);
    std.mem.writeInt(u32, out[8..12], format_version, .little);
    std.mem.writeInt(u32, out[12..16], Section.count, .little);
    @memcpy(out[16..32], &in.key);
    std.mem.writeInt(u32, out[32..36], total, .little);
    // out[36..40] is the reserved word, left zero by the memset.
    for (0..Section.count) |i| {
        const row = out[header_bytes + i * 8 ..][0..8];
        std.mem.writeInt(u32, row[0..4], offsets[i], .little);
        std.mem.writeInt(u32, row[4..8], lengths[i], .little);
    }

    // 3. The sections.
    const s = struct {
        fn of(buffer: []u8, offs: [Section.count]u32, lens: [Section.count]u32, which: Section) []u8 {
            const i = @intFromEnum(which);
            return buffer[offs[i]..][0..lens[i]];
        }
    }.of;

    @memcpy(s(out, offsets, lengths, .bir_insts_tag), @as([]const u8, @ptrCast(insts.items(.tag))));
    writeU32s(s(out, offsets, lengths, .bir_insts_token), insts.items(.main_token));
    {
        const data = insts.items(.data);
        const lhs = s(out, offsets, lengths, .bir_insts_lhs);
        const rhs = s(out, offsets, lengths, .bir_insts_rhs);
        for (data, 0..) |d, i| {
            std.mem.writeInt(u32, lhs[i * 4 ..][0..4], d.lhs, .little);
            std.mem.writeInt(u32, rhs[i * 4 ..][0..4], d.rhs, .little);
        }
    }
    writeU32s(s(out, offsets, lengths, .bir_extra), bir.extra);
    @memcpy(s(out, offsets, lengths, .bir_string_bytes), bir.string_bytes);
    writeU32s(s(out, offsets, lengths, .bir_symbols), slots);
    writeRows(Bir.Decl, s(out, offsets, lengths, .bir_decls), bir.decls);
    writeRows(Bir.Ctor, s(out, offsets, lengths, .bir_ctors), bir.ctors);
    writeRows(Bir.Local, s(out, offsets, lengths, .bir_locals), bir.locals);
    writeRows(Bir.Ref, s(out, offsets, lengths, .bir_refs), bir.refs);
    writeRows(Bir.Import, s(out, offsets, lengths, .bir_imports), bir.imports);
    writeRows(Bir.Exposed, s(out, offsets, lengths, .bir_exposed), bir.exposed);
    {
        const dst = s(out, offsets, lengths, .bir_interface);
        for (bir.interface, 0..) |d, i| std.mem.writeInt(u32, dst[i * 4 ..][0..4], d.int(), .little);
    }
    writeRows(BirDiagnostics.Item, s(out, offsets, lengths, .bir_diagnostics), bir.diagnostics);
    @memcpy(s(out, offsets, lengths, .token_tags), @as([]const u8, @ptrCast(tokens.items(.tag))));
    writeU32s(s(out, offsets, lengths, .token_starts), tokens.items(.start));
    writeU32s(s(out, offsets, lengths, .line_starts), in.line_starts);
    writeDiagnostics(s(out, offsets, lengths, .diagnostics), in.diagnostics);
    {
        const dst = s(out, offsets, lengths, .strings);
        std.mem.writeInt(u32, dst[0..4], distinct, .little);
        var cursor: u32 = Strings.header + distinct * Strings.row;
        for (table.keys()) |symbol| {
            const text = in.interner.slice(symbol);
            const i = table.get(symbol).?;
            const row = dst[Strings.header + i * Strings.row ..][0..Strings.row];
            // The offset is from the SECTION's byte 0, not the file's, so a
            // section can be validated without knowing where it sits.
            std.mem.writeInt(u32, row[0..4], cursor, .little);
            std.mem.writeInt(u32, row[4..8], @intCast(text.len), .little);
            @memcpy(dst[cursor..][0..text.len], text);
            cursor += @intCast(text.len);
        }
    }
    {
        const dst = s(out, offsets, lengths, .bir_module_doc);
        std.mem.writeInt(u32, dst[0..4], bir.module_doc_start, .little);
        std.mem.writeInt(u32, dst[4..8], bir.module_doc_end, .little);
    }

    // 4. The body hash, last, over everything it covers.
    const digest = iface_bytes.hash(out[hashed_from..]);
    @memcpy(out[40..56], &digest);
    return out;
}

fn diagnosticsLen(items: []const Diagnostic) u32 {
    if (items.len == 0) return 0;
    var messages: u32 = 0;
    for (items) |d| messages += @intCast(d.message.len);
    return diagnostics_header + @as(u32, @intCast(items.len)) * diagnostic_row_bytes + messages;
}

fn writeDiagnostics(dst: []u8, items: []const Diagnostic) void {
    if (items.len == 0) return;
    const rows_at = diagnostics_header;
    const blob_at = rows_at + @as(u32, @intCast(items.len)) * diagnostic_row_bytes;
    std.mem.writeInt(u32, dst[0..4], @intCast(items.len), .little);
    std.mem.writeInt(u32, dst[4..8], @intCast(dst.len - blob_at), .little);
    var cursor: u32 = 0;
    for (items, 0..) |d, i| {
        const row = dst[rows_at + i * diagnostic_row_bytes ..][0..diagnostic_row_bytes];
        std.mem.writeInt(u16, row[0..2], d.code, .little);
        row[2] = d.severity;
        row[3] = 0;
        std.mem.writeInt(u32, row[4..8], d.start_line, .little);
        std.mem.writeInt(u32, row[8..12], d.start_col, .little);
        std.mem.writeInt(u32, row[12..16], d.end_line, .little);
        std.mem.writeInt(u32, row[16..20], d.end_col, .little);
        std.mem.writeInt(u32, row[20..24], cursor, .little);
        std.mem.writeInt(u32, row[24..28], @intCast(d.message.len), .little);
        std.mem.writeInt(u32, row[28..32], 0, .little);
        @memcpy(dst[blob_at + cursor ..][0..d.message.len], d.message);
        cursor += @intCast(d.message.len);
    }
}

fn pad4(n: usize) usize {
    return (4 - (n % 4)) % 4;
}

fn writeU32s(dst: []u8, src: []const u32) void {
    if (native_little) {
        @memcpy(dst, std.mem.sliceAsBytes(src));
        return;
    }
    for (src, 0..) |v, i| std.mem.writeInt(u32, dst[i * 4 ..][0..4], v, .little);
}

const native_little = builtin.cpu.arch.endian() == .little;

// ---------------------------------------------------------------------------
// Fixed-size rows, by reflection
// ---------------------------------------------------------------------------
//
// `Decl` alone is twenty-five fields, and a hand-written pair of encoders
// would be twenty-five chances for the reader and the writer to disagree
// about one of them. The layout is declaration order, each field at its
// natural little-endian width — 1 byte for a `bool` or an `enum(u8)`, the
// enum's tag width otherwise — so the ONE thing a reader and a writer can
// disagree about is the struct, which they share.
//
// A field added to `Bir.Decl` changes the row width and therefore every
// offset in the file; nothing migrates, and nothing has to, because the
// compiler build id is in the file key and every file under `src/` is in the
// build id (`fast-compiler.md` §8).

fn fieldBytes(comptime T: type) u32 {
    return switch (@typeInfo(T)) {
        .bool => 1,
        .int => |i| widthFor(i.bits),
        .@"enum" => |e| widthFor(@typeInfo(e.tag_type).int.bits),
        else => @compileError("no on-disk width for " ++ @typeName(T)),
    };
}

fn widthFor(comptime bits: u16) u32 {
    return if (bits <= 8) 1 else if (bits <= 16) 2 else if (bits <= 32) 4 else @compileError("field too wide for the artifact format");
}

fn rowBytes(comptime T: type) u32 {
    return comptime blk: {
        var total: u32 = 0;
        for (std.meta.fields(T)) |f| total += fieldBytes(f.type);
        break :blk total;
    };
}

fn writeRows(comptime T: type, dst: []u8, rows: []const T) void {
    const size = rowBytes(T);
    for (rows, 0..) |row, i| {
        var at: u32 = @intCast(i * size);
        inline for (std.meta.fields(T)) |f| {
            const raw: u32 = switch (@typeInfo(f.type)) {
                .bool => @intFromBool(@field(row, f.name)),
                .int => @field(row, f.name),
                .@"enum" => @intFromEnum(@field(row, f.name)),
                else => unreachable,
            };
            switch (fieldBytes(f.type)) {
                1 => dst[at] = @intCast(raw),
                2 => std.mem.writeInt(u16, dst[at..][0..2], @intCast(raw), .little),
                4 => std.mem.writeInt(u32, dst[at..][0..4], raw, .little),
                else => unreachable,
            }
            at += fieldBytes(f.type);
        }
    }
}

/// One row, with every enum-valued field CHECKED before it is constructed.
///
/// A value no version of an exhaustive enum defines is `error.BadArtifact`
/// here and not in `verify`, and that is deliberate: `@enumFromInt` on an
/// out-of-range exhaustive enum is undefined behaviour, so the check has to
/// happen before the value exists, not after. `verify` then owns the checks
/// that are about STRUCTURE — ranges nested, indices in bounds — which is
/// everything a well-typed row can still get wrong.
fn readRow(comptime T: type, src: []const u8) ReadError!T {
    var out: T = undefined;
    var at: u32 = 0;
    inline for (std.meta.fields(T)) |f| {
        const raw: u32 = switch (fieldBytes(f.type)) {
            1 => src[at],
            2 => std.mem.readInt(u16, src[at..][0..2], .little),
            4 => std.mem.readInt(u32, src[at..][0..4], .little),
            else => unreachable,
        };
        @field(out, f.name) = switch (@typeInfo(f.type)) {
            .bool => raw != 0,
            .int => @intCast(raw),
            .@"enum" => blk: {
                if (!validEnum(f.type, raw)) return error.BadArtifact;
                break :blk @enumFromInt(raw);
            },
            else => unreachable,
        };
        at += fieldBytes(f.type);
    }
    return out;
}

/// Whether `raw` is a value `E` defines. A non-exhaustive enum defines them
/// all; a contiguous one is a single compare, which matters because
/// `Inst.Tag` is asked this 208 092 times per project.
fn validEnum(comptime E: type, raw: u32) bool {
    const info = @typeInfo(E).@"enum";
    if (!info.is_exhaustive) return true;
    const contiguous = comptime blk: {
        for (info.fields, 0..) |f, i| {
            if (f.value != i) break :blk false;
        }
        break :blk true;
    };
    if (contiguous) return raw < info.fields.len;
    inline for (info.fields) |f| {
        if (raw == f.value) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/// What one artifact loads to. Every column is `gpa`-owned and is handed to
/// `Artifacts.set` exactly as a lexed or lowered one is (`plans/m4-2.md`
/// §10); `strings` and every `Diagnostic.message` BORROW the bytes `read` was
/// given, and are consumed before the read buffer is reused.
pub const Loaded = struct {
    /// `symbols` holds STRING-TABLE INDICES until `intern` has run.
    bir: Bir,
    /// `tag` and `start` from the artifact; `line` and `payload` zero,
    /// because they are not cached and nothing downstream of `lower` reads
    /// either (`frontend.md` §3.2).
    tokens: Token.TokenList,
    line_starts: []u32,
    diagnostics: []Diagnostic,
    strings: Strings,

    pub fn deinit(l: *Loaded, gpa: Allocator) void {
        l.bir.deinit(gpa);
        l.tokens.deinit(gpa);
        gpa.free(l.line_starts);
        gpa.free(l.diagnostics);
        l.* = undefined;
    }

    /// `getOrPut` each DISTINCT string once into `local`, then rewrite the
    /// symbol column through the existing `Bir.applyRemap`.
    ///
    /// On the WORKER, into its own `Local` pool, because `InternPool.Global`
    /// is thread-confined (`src/InternPool.zig:24-26`) — and because the
    /// numbering this produces is exactly the kind `Global.merge` was written
    /// to reconcile, so no rule changes and no new synchronisation appears.
    pub fn intern(l: *Loaded, gpa: Allocator, scratch: Allocator, local: *InternPool.Local) Allocator.Error!void {
        if (l.bir.symbols.len == 0) return;
        const table = try scratch.alloc(InternPool.Symbol, l.strings.count);
        defer scratch.free(table);
        for (table, 0..) |*slot, i| {
            slot.* = try local.getOrPut(gpa, l.strings.at(@intCast(i)));
        }
        l.bir.applyRemap(table);
    }
};

/// The artifact `bytes` describes, or `error.BadArtifact`.
///
/// The check ORDER is the contract (see this file's header): the length
/// against the header's `total_len` FIRST, so every prefix a concurrent
/// reader can observe is a miss; then the section table's bounds; then the
/// body hash, which is what catches a same-length file whose bytes moved.
pub fn read(gpa: Allocator, bytes: []const u8, key: [16]u8) ReadError!Loaded {
    if (bytes.len < body_start) return error.BadArtifact;
    if (!std.mem.eql(u8, bytes[0..8], magic)) return error.BadArtifact;
    if (std.mem.readInt(u32, bytes[8..12], .little) != format_version) return error.BadArtifact;
    // THE torn-file check. `Dir.store` writes one buffer in one sequential
    // write, so a reader racing a writer sees a PREFIX, and a prefix is
    // shorter than the length the header claims.
    if (std.mem.readInt(u32, bytes[32..36], .little) != bytes.len) return error.BadArtifact;
    if (std.mem.readInt(u32, bytes[12..16], .little) != Section.count) return error.BadArtifact;
    // The reserved word must be zero. It costs nothing to check and it is
    // what makes the mutation sweep's accepted-mutant count exactly zero:
    // every byte of the file is then either read, checked, or covered by
    // `body_hash` — there is no byte a flip can land in unnoticed. A future
    // version that wants the word bumps `format_version`, which is the
    // policy for every other byte here too.
    if (std.mem.readInt(u32, bytes[36..40], .little) != 0) return error.BadArtifact;
    // The file NAME is the key, so this is the check that does not trust the
    // directory: a file copied, renamed or left by a compiler whose build id
    // has moved is a miss here rather than a `Bir` installed for the wrong
    // file.
    if (!std.mem.eql(u8, bytes[16..32], &key)) return error.BadArtifact;
    // A content-hash name guards IDENTITY, not integrity: a same-length file
    // with flipped bits has the right name and the wrong bytes, and nothing
    // above can tell. This can.
    if (!std.mem.eql(u8, bytes[40..56], &iface_bytes.hash(bytes[hashed_from..]))) return error.BadArtifact;

    var offsets: [Section.count]u32 = @splat(0);
    var lengths: [Section.count]u32 = @splat(0);
    for (0..Section.count) |i| {
        const row = bytes[header_bytes + i * 8 ..][0..8];
        const offset = std.mem.readInt(u32, row[0..4], .little);
        const len = std.mem.readInt(u32, row[4..8], .little);
        if (offset % 4 != 0 or offset < body_start) return error.BadArtifact;
        if (@as(u64, offset) + @as(u64, len) > bytes.len) return error.BadArtifact;
        offsets[i] = offset;
        lengths[i] = len;
    }
    const sec = struct {
        fn of(b: []const u8, offs: [Section.count]u32, lens: [Section.count]u32, which: Section) []const u8 {
            const i = @intFromEnum(which);
            return b[offs[i]..][0..lens[i]];
        }
    }.of;

    // Every column's length has to agree with the row count the first column
    // fixes, or the artifact describes two different files.
    const inst_count = lengths[@intFromEnum(Section.bir_insts_tag)];
    const token_count = lengths[@intFromEnum(Section.token_tags)];
    if (lengths[@intFromEnum(Section.bir_insts_token)] != inst_count * 4) return error.BadArtifact;
    if (lengths[@intFromEnum(Section.bir_insts_lhs)] != inst_count * 4) return error.BadArtifact;
    if (lengths[@intFromEnum(Section.bir_insts_rhs)] != inst_count * 4) return error.BadArtifact;
    if (lengths[@intFromEnum(Section.token_starts)] != token_count * 4) return error.BadArtifact;
    if (lengths[@intFromEnum(Section.bir_extra)] % 4 != 0) return error.BadArtifact;
    if (lengths[@intFromEnum(Section.bir_symbols)] % 4 != 0) return error.BadArtifact;
    if (lengths[@intFromEnum(Section.bir_interface)] % 4 != 0) return error.BadArtifact;
    if (lengths[@intFromEnum(Section.line_starts)] % 4 != 0) return error.BadArtifact;
    if (lengths[@intFromEnum(Section.bir_module_doc)] != 8) return error.BadArtifact;
    inline for (.{
        .{ Section.bir_decls, Bir.Decl },
        .{ Section.bir_ctors, Bir.Ctor },
        .{ Section.bir_locals, Bir.Local },
        .{ Section.bir_refs, Bir.Ref },
        .{ Section.bir_imports, Bir.Import },
        .{ Section.bir_exposed, Bir.Exposed },
        .{ Section.bir_diagnostics, BirDiagnostics.Item },
    }) |pair| {
        if (lengths[@intFromEnum(pair[0])] % rowBytes(pair[1]) != 0) return error.BadArtifact;
    }

    var out: Loaded = .{
        .bir = .empty,
        .tokens = .empty,
        .line_starts = &.{},
        .diagnostics = &.{},
        .strings = .empty,
    };
    errdefer out.deinit(gpa);

    // The string table, first, because `bir_symbols` is checked against it.
    out.strings = try readStrings(sec(bytes, offsets, lengths, .strings));

    {
        var insts: Bir.InstList = .empty;
        errdefer insts.deinit(gpa);
        try insts.resize(gpa, inst_count);
        const s = insts.slice();
        @memcpy(@as([]u8, @ptrCast(s.items(.tag))), sec(bytes, offsets, lengths, .bir_insts_tag));
        for (s.items(.tag)) |tag| {
            if (!validEnum(Bir.Inst.Tag, @intFromEnum(tag))) return error.BadArtifact;
        }
        readU32s(s.items(.main_token), sec(bytes, offsets, lengths, .bir_insts_token));
        const lhs = sec(bytes, offsets, lengths, .bir_insts_lhs);
        const rhs = sec(bytes, offsets, lengths, .bir_insts_rhs);
        for (s.items(.data), 0..) |*d, i| {
            d.* = .{
                .lhs = std.mem.readInt(u32, lhs[i * 4 ..][0..4], .little),
                .rhs = std.mem.readInt(u32, rhs[i * 4 ..][0..4], .little),
            };
        }
        out.bir.insts = insts.toOwnedSlice();
    }

    out.bir.extra = try dupeU32s(gpa, sec(bytes, offsets, lengths, .bir_extra));
    out.bir.string_bytes = try gpa.dupe(u8, sec(bytes, offsets, lengths, .bir_string_bytes));
    {
        const src = sec(bytes, offsets, lengths, .bir_symbols);
        const symbols = try gpa.alloc(Bir.Symbol, src.len / 4);
        out.bir.symbols = symbols;
        for (symbols, 0..) |*slot, i| {
            const index = std.mem.readInt(u32, src[i * 4 ..][0..4], .little);
            // A slot past the string table is the shape a truncated or
            // spliced artifact produces, and the one `intern` must never be
            // handed: `applyRemap` indexes the table by it, unchecked.
            if (index >= out.strings.count) return error.BadArtifact;
            slot.* = @enumFromInt(index);
        }
    }
    out.bir.decls = try readRowsAlloc(Bir.Decl, gpa, sec(bytes, offsets, lengths, .bir_decls));
    out.bir.ctors = try readRowsAlloc(Bir.Ctor, gpa, sec(bytes, offsets, lengths, .bir_ctors));
    out.bir.locals = try readRowsAlloc(Bir.Local, gpa, sec(bytes, offsets, lengths, .bir_locals));
    out.bir.refs = try readRowsAlloc(Bir.Ref, gpa, sec(bytes, offsets, lengths, .bir_refs));
    out.bir.imports = try readRowsAlloc(Bir.Import, gpa, sec(bytes, offsets, lengths, .bir_imports));
    out.bir.exposed = try readRowsAlloc(Bir.Exposed, gpa, sec(bytes, offsets, lengths, .bir_exposed));
    {
        const src = sec(bytes, offsets, lengths, .bir_interface);
        const list = try gpa.alloc(Bir.DeclIndex, src.len / 4);
        out.bir.interface = list;
        for (list, 0..) |*slot, i| slot.* = @enumFromInt(std.mem.readInt(u32, src[i * 4 ..][0..4], .little));
    }
    out.bir.diagnostics = try readRowsAlloc(BirDiagnostics.Item, gpa, sec(bytes, offsets, lengths, .bir_diagnostics));
    {
        const doc = sec(bytes, offsets, lengths, .bir_module_doc);
        out.bir.module_doc_start = std.mem.readInt(u32, doc[0..4], .little);
        out.bir.module_doc_end = std.mem.readInt(u32, doc[4..8], .little);
    }

    try out.tokens.resize(gpa, token_count);
    {
        const s = out.tokens.slice();
        @memcpy(@as([]u8, @ptrCast(s.items(.tag))), sec(bytes, offsets, lengths, .token_tags));
        for (s.items(.tag)) |tag| {
            if (!validEnum(Token.Tag, @intFromEnum(tag))) return error.BadArtifact;
        }
        readU32s(s.items(.start), sec(bytes, offsets, lengths, .token_starts));
        @memset(s.items(.line), 0);
        @memset(s.items(.payload), 0);
    }

    out.line_starts = try dupeU32s(gpa, sec(bytes, offsets, lengths, .line_starts));
    out.diagnostics = try readDiagnostics(gpa, sec(bytes, offsets, lengths, .diagnostics));
    return out;
}

fn readStrings(section: []const u8) ReadError!Strings {
    if (section.len == 0) return .empty;
    if (section.len < Strings.header) return error.BadArtifact;
    const count = std.mem.readInt(u32, section[0..4], .little);
    const rows_end = @as(u64, Strings.header) + @as(u64, count) * Strings.row;
    if (rows_end > section.len) return error.BadArtifact;
    const out: Strings = .{ .bytes = section, .count = count };
    for (0..count) |i| {
        const row = section[Strings.header + i * Strings.row ..][0..Strings.row];
        const offset = std.mem.readInt(u32, row[0..4], .little);
        const len = std.mem.readInt(u32, row[4..8], .little);
        // A record overrunning its blob is the shape a truncated artifact
        // produces, and the one `at` must never be asked for.
        if (offset < rows_end) return error.BadArtifact;
        if (@as(u64, offset) + @as(u64, len) > section.len) return error.BadArtifact;
    }
    return out;
}

fn readDiagnostics(gpa: Allocator, section: []const u8) ReadError![]Diagnostic {
    if (section.len == 0) return &.{};
    if (section.len < diagnostics_header) return error.BadArtifact;
    const count = std.mem.readInt(u32, section[0..4], .little);
    const messages_len = std.mem.readInt(u32, section[4..8], .little);
    const blob_at = @as(u64, diagnostics_header) + @as(u64, count) * diagnostic_row_bytes;
    if (blob_at + messages_len > section.len) return error.BadArtifact;
    const blob = section[@intCast(blob_at)..][0..messages_len];

    const out = try gpa.alloc(Diagnostic, count);
    errdefer gpa.free(out);
    for (out, 0..) |*d, i| {
        const row = section[diagnostics_header + i * diagnostic_row_bytes ..][0..diagnostic_row_bytes];
        const start = std.mem.readInt(u32, row[20..24], .little);
        const len = std.mem.readInt(u32, row[24..28], .little);
        if (@as(u64, start) + @as(u64, len) > blob.len) return error.BadArtifact;
        d.* = .{
            .code = std.mem.readInt(u16, row[0..2], .little),
            .severity = row[2],
            .start_line = std.mem.readInt(u32, row[4..8], .little),
            .start_col = std.mem.readInt(u32, row[8..12], .little),
            .end_line = std.mem.readInt(u32, row[12..16], .little),
            .end_col = std.mem.readInt(u32, row[16..20], .little),
            .message = blob[start..][0..len],
        };
    }
    return out;
}

fn readRowsAlloc(comptime T: type, gpa: Allocator, section: []const u8) ReadError![]const T {
    const size = rowBytes(T);
    const out = try gpa.alloc(T, section.len / size);
    errdefer gpa.free(out);
    for (out, 0..) |*slot, i| slot.* = try readRow(T, section[i * size ..][0..size]);
    return out;
}

fn dupeU32s(gpa: Allocator, section: []const u8) Allocator.Error![]u32 {
    const out = try gpa.alloc(u32, section.len / 4);
    readU32s(out, section);
    return out;
}

fn readU32s(dst: []u32, src: []const u8) void {
    if (native_little) {
        @memcpy(std.mem.sliceAsBytes(dst), src[0 .. dst.len * 4]);
        return;
    }
    for (dst, 0..) |*slot, i| slot.* = std.mem.readInt(u32, src[i * 4 ..][0..4], .little);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the row encoder's widths are the structures', with the padding gone" {
    // 88 bytes a `Decl` is `plans/m4-2.md` §3.1's figure, and the estimate
    // the whole size table was built on; a field added without a thought
    // about the cache moves it here first.
    //
    // **A correction to §3.1**: a row with a `u8` or a `bool` field is
    // NARROWER on disk than in memory, because the on-disk form has no
    // alignment to satisfy. `Ref` is 12 bytes in memory and 9 here, `Local`
    // 12 and 9, `Import` 24 and 21. The estimate was therefore high for
    // three of the rows it counted, and §11 reports what the bytes actually
    // came to.
    try testing.expectEqual(@as(u32, 88), rowBytes(Bir.Decl));
    try testing.expectEqual(@as(u32, 20), rowBytes(Bir.Ctor));
    try testing.expectEqual(@as(u32, 9), rowBytes(Bir.Ref));
    try testing.expectEqual(@as(u32, 9), rowBytes(Bir.Local));
    try testing.expectEqual(@as(u32, 21), rowBytes(Bir.Import));
    try testing.expectEqual(@as(u32, 8), rowBytes(Bir.Exposed));
}

const sample_key: [16]u8 = .{ 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 1, 2, 3, 4, 5, 6 };

/// A small artifact with every section non-empty and several lengths that
/// are NOT multiples of four, so the padding between sections is exercised
/// rather than assumed. Built by hand rather than lowered: this file's claim
/// is about the CONTAINER, and `--roundtrip-frontend` (M2-c) is what asserts
/// it over the whole corpus.
const Sample = struct {
    bir: Bir,
    tokens: Token.TokenList,
    line_starts: []u32,
    local: InternPool.Local,

    fn init(gpa: Allocator) !Sample {
        var local: InternPool.Local = try .init(gpa);
        errdefer local.deinit(gpa);
        const a = try local.getOrPut(gpa, "alpha");
        const b = try local.getOrPut(gpa, "beta");

        var bir: Bir = .empty;
        var insts: Bir.InstList = .empty;
        errdefer insts.deinit(gpa);
        try insts.append(gpa, .{ .tag = .top, .main_token = 0, .data = .{ .lhs = 0, .rhs = 0 } });
        try insts.append(gpa, .{ .tag = .int, .main_token = 1, .data = .{ .lhs = 0, .rhs = 3 } });
        try insts.append(gpa, .{ .tag = .call, .main_token = 2, .data = .{ .lhs = 0, .rhs = 0 } });
        bir.insts = insts.toOwnedSlice();
        bir.extra = try gpa.dupe(u32, &.{ 1, 2, 3, 0 });
        bir.string_bytes = try gpa.dupe(u8, "123");
        // `alpha` twice, so the string table's deduplication is exercised
        // and not merely present.
        bir.symbols = try gpa.dupe(Bir.Symbol, &.{ a, b, a });
        bir.decls = try gpa.dupe(Bir.Decl, &.{.{
            .kind = .value,
            .name = @enumFromInt(0),
            .name_token = 0,
            .is_pub = true,
            .is_opaque = false,
            .is_equatable = false,
            .doc_start = 0,
            .doc_end = 1,
            .params = 0,
            .params_start = @enumFromInt(0),
            .params_end = @enumFromInt(0),
            .type_params_start = 0,
            .type_params_end = 0,
            .annotation = .none,
            .where_start = @enumFromInt(0),
            .where_end = @enumFromInt(0),
            .body = @enumFromInt(2),
            .inst_start = @enumFromInt(0),
            .inst_end = @enumFromInt(3),
            .ctors_start = 0,
            .ctors_end = 1,
            .locals_start = 0,
            .locals_end = 1,
            .refs_start = 0,
            .refs_end = 1,
        }});
        bir.ctors = try gpa.dupe(Bir.Ctor, &.{.{
            .name = @enumFromInt(1),
            .name_token = 1,
            .decl = @enumFromInt(0),
            .args_start = @enumFromInt(0),
            .args_end = @enumFromInt(0),
        }});
        bir.locals = try gpa.dupe(Bir.Local, &.{.{ .name = @enumFromInt(2), .kind = .param, .inst = @enumFromInt(0) }});
        bir.refs = try gpa.dupe(Bir.Ref, &.{.{ .kind = .top_value, .a = 0, .b = 0 }});
        bir.imports = try gpa.dupe(Bir.Import, &.{.{
            .module = @enumFromInt(0),
            .name_token = 1,
            .alias = @enumFromInt(0),
            .exposed_start = 0,
            .exposed_end = 1,
            .prelude = true,
        }});
        bir.exposed = try gpa.dupe(Bir.Exposed, &.{.{ .name = @enumFromInt(1), .token = 2 }});
        bir.interface = try gpa.dupe(Bir.DeclIndex, &.{@enumFromInt(0)});
        bir.diagnostics = try gpa.dupe(BirDiagnostics.Item, &.{.{
            .code = .let_forward_reference,
            .start = 1,
            .end = 2,
            .other_start = 3,
            .other_end = 4,
            .forward = .through,
            .inside_constraint = true,
        }});
        bir.module_doc_start = 2;
        bir.module_doc_end = 5;

        var tokens: Token.TokenList = .empty;
        try tokens.append(gpa, .{ .tag = .lower_ident, .start = 0, .line = 0, .payload = 7 });
        try tokens.append(gpa, .{ .tag = .int, .start = 6, .line = 0, .payload = 0 });
        try tokens.append(gpa, .{ .tag = .eof, .start = 9, .line = 1, .payload = 0 });

        return .{
            .bir = bir,
            .tokens = tokens,
            .line_starts = try gpa.dupe(u32, &.{ 0, 8 }),
            .local = local,
        };
    }

    fn deinit(s: *Sample, gpa: Allocator) void {
        s.bir.deinit(gpa);
        s.tokens.deinit(gpa);
        gpa.free(s.line_starts);
        s.local.deinit(gpa);
    }

    fn input(s: *const Sample, diagnostics: []const Diagnostic) Input {
        return .{
            .key = sample_key,
            .bir = &s.bir,
            .interner = &s.local,
            .tokens = &s.tokens,
            .line_starts = s.line_starts,
            .diagnostics = diagnostics,
        };
    }
};

const sample_diagnostics = [_]Diagnostic{
    .{ .code = 7, .severity = 0, .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 4, .message = "a rendered message" },
    // A `warning`, and an empty message: the two rows most likely to be got
    // wrong by a writer that assumes every diagnostic has prose.
    .{ .code = 300, .severity = 1, .start_line = 2, .start_col = 9, .end_line = 3, .end_col = 1, .message = "" },
};

test "an artifact round-trips: every column, the symbols and the diagnostics" {
    const gpa = testing.allocator;
    var sample = try Sample.init(gpa);
    defer sample.deinit(gpa);

    const bytes = try write(gpa, gpa, sample.input(&sample_diagnostics));
    defer gpa.free(bytes);
    var loaded = try read(gpa, bytes, sample_key);
    defer loaded.deinit(gpa);

    // The `Bir`, column by column. `symbols` is compared after `intern`,
    // because on disk it holds string-table indices and not symbols.
    try testing.expectEqualSlices(Bir.Inst.Tag, sample.bir.insts.items(.tag), loaded.bir.insts.items(.tag));
    try testing.expectEqualSlices(u32, sample.bir.insts.items(.main_token), loaded.bir.insts.items(.main_token));
    try testing.expectEqualSlices(Bir.Inst.Data, sample.bir.insts.items(.data), loaded.bir.insts.items(.data));
    try testing.expectEqualSlices(u32, sample.bir.extra, loaded.bir.extra);
    try testing.expectEqualStrings(sample.bir.string_bytes, loaded.bir.string_bytes);
    try testing.expectEqualDeep(sample.bir.decls, loaded.bir.decls);
    try testing.expectEqualDeep(sample.bir.ctors, loaded.bir.ctors);
    try testing.expectEqualDeep(sample.bir.locals, loaded.bir.locals);
    try testing.expectEqualDeep(sample.bir.refs, loaded.bir.refs);
    try testing.expectEqualDeep(sample.bir.imports, loaded.bir.imports);
    try testing.expectEqualDeep(sample.bir.exposed, loaded.bir.exposed);
    try testing.expectEqualDeep(sample.bir.interface, loaded.bir.interface);
    try testing.expectEqualDeep(sample.bir.diagnostics, loaded.bir.diagnostics);
    try testing.expectEqual(sample.bir.module_doc_start, loaded.bir.module_doc_start);
    try testing.expectEqual(sample.bir.module_doc_end, loaded.bir.module_doc_end);

    // The two token columns that are cached, and the two that are not.
    try testing.expectEqualSlices(Token.Tag, sample.tokens.items(.tag), loaded.tokens.items(.tag));
    try testing.expectEqualSlices(u32, sample.tokens.items(.start), loaded.tokens.items(.start));
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0 }, loaded.tokens.items(.line));
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0 }, loaded.tokens.items(.payload));

    try testing.expectEqualSlices(u32, sample.line_starts, loaded.line_starts);
    try testing.expectEqual(@as(usize, 2), loaded.diagnostics.len);
    for (sample_diagnostics, loaded.diagnostics) |want, got| {
        try testing.expectEqual(want.code, got.code);
        try testing.expectEqual(want.severity, got.severity);
        try testing.expectEqual(want.start_line, got.start_line);
        try testing.expectEqual(want.start_col, got.start_col);
        try testing.expectEqual(want.end_line, got.end_line);
        try testing.expectEqual(want.end_col, got.end_col);
        try testing.expectEqualStrings(want.message, got.message);
    }

    // The symbols, re-interned into a pool that has never seen them. The
    // remap is `applyRemap`'s, unchanged — only where the table comes from
    // moved.
    try testing.expectEqual(@as(u32, 2), loaded.strings.count);
    var fresh: InternPool.Local = try .init(gpa);
    defer fresh.deinit(gpa);
    try loaded.intern(gpa, gpa, &fresh);
    try testing.expectEqualStrings("alpha", fresh.slice(loaded.bir.symbols[0]));
    try testing.expectEqualStrings("beta", fresh.slice(loaded.bir.symbols[1]));
    try testing.expectEqualStrings("alpha", fresh.slice(loaded.bir.symbols[2]));
    // Two distinct strings, one of them mentioned twice: the slot count and
    // the string count are not the same number, which is the whole point of
    // a table.
    try testing.expectEqual(loaded.bir.symbols[0], loaded.bir.symbols[2]);
}

test "writing a loaded artifact again gives the same bytes" {
    // What makes two processes that compute one key write one file, and
    // therefore what makes `plans/m4-2.md` §6 B's dropped `rename` safe.
    const gpa = testing.allocator;
    var sample = try Sample.init(gpa);
    defer sample.deinit(gpa);
    const bytes = try write(gpa, gpa, sample.input(&sample_diagnostics));
    defer gpa.free(bytes);
    const again = try write(gpa, gpa, sample.input(&sample_diagnostics));
    defer gpa.free(again);
    try testing.expectEqualSlices(u8, bytes, again);
}

test "an empty file round-trips: every section is allowed to be zero-length" {
    // The floor: `Bir.empty`, no tokens, no lines, no diagnostics. Nothing
    // in the format may need a section to be non-empty, because a
    // comment-only file is exactly this.
    const gpa = testing.allocator;
    var empty_local: InternPool.Local = try .init(gpa);
    defer empty_local.deinit(gpa);
    const empty_bir: Bir = .empty;
    const empty_tokens: Token.TokenList = .empty;
    const bytes = try write(gpa, gpa, .{
        .key = sample_key,
        .bir = &empty_bir,
        .interner = &empty_local,
        .tokens = &empty_tokens,
        .line_starts = &.{},
        .diagnostics = &.{},
    });
    defer gpa.free(bytes);
    var loaded = try read(gpa, bytes, sample_key);
    defer loaded.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), loaded.bir.insts.len);
    try testing.expectEqual(@as(usize, 0), loaded.tokens.len);
    try testing.expectEqual(@as(usize, 0), loaded.line_starts.len);
    try testing.expectEqual(@as(usize, 0), loaded.diagnostics.len);
    try loaded.intern(gpa, gpa, &empty_local);
}

test "an artifact written for another key is a miss, not an artifact" {
    const gpa = testing.allocator;
    var sample = try Sample.init(gpa);
    defer sample.deinit(gpa);
    const bytes = try write(gpa, gpa, sample.input(&sample_diagnostics));
    defer gpa.free(bytes);
    var other = sample_key;
    other[0] +%= 1;
    try testing.expectError(error.BadArtifact, read(gpa, bytes, other));
}

test "the corrupt-artifact table: each shape is a miss, never a crash" {
    // `plans/m4-2.md` §9.4 item 23, in-source. Every shape a fixture can
    // plant on disk, one at a time, with the artifact restored between so
    // the sweep tests the mutation and not a file it quietly destroyed.
    const gpa = testing.allocator;
    var sample = try Sample.init(gpa);
    defer sample.deinit(gpa);
    const bytes = try write(gpa, gpa, sample.input(&sample_diagnostics));
    defer gpa.free(bytes);
    {
        var ok = try read(gpa, bytes, sample_key);
        ok.deinit(gpa);
    }

    // Zero length, a stub shorter than the header, and truncation.
    try testing.expectError(error.BadArtifact, read(gpa, &.{}, sample_key));
    try testing.expectError(error.BadArtifact, read(gpa, bytes[0..20], sample_key));
    try testing.expectError(error.BadArtifact, read(gpa, bytes[0 .. bytes.len - 4], sample_key));

    const copy = try gpa.dupe(u8, bytes);
    defer gpa.free(copy);
    const Case = struct { what: []const u8, at: usize, write_u32: ?u32 = null, xor: u8 = 0 };
    const cases = [_]Case{
        .{ .what = "wrong magic", .at = 0, .xor = 1 },
        .{ .what = "unknown format version", .at = 8, .write_u32 = format_version + 1 },
        .{ .what = "a section count no version defines", .at = 12, .write_u32 = Section.count + 1 },
        .{ .what = "a total_len that is not the file's length", .at = 32, .write_u32 = 12345 },
        .{ .what = "a header key that is not the file's name", .at = 16, .xor = 1 },
        .{ .what = "a body hash that is not the body's", .at = 40, .xor = 1 },
    };
    for (cases) |c| {
        if (c.write_u32) |v| {
            const was = std.mem.readInt(u32, copy[c.at..][0..4], .little);
            std.mem.writeInt(u32, copy[c.at..][0..4], v, .little);
            try expectMiss(gpa, copy, c.what);
            std.mem.writeInt(u32, copy[c.at..][0..4], was, .little);
        } else {
            copy[c.at] ^= c.xor;
            try expectMiss(gpa, copy, c.what);
            copy[c.at] ^= c.xor;
        }
    }
    // The artifact is whole again.
    {
        var ok = try read(gpa, copy, sample_key);
        ok.deinit(gpa);
    }

    // A section offset or length past the end, a length chosen to wrap 32
    // bits, and a misaligned offset. The body hash would catch these too, so
    // it is recomputed after each mutation — the point is that the BOUNDS
    // check refuses them on its own, which is what makes the hash a second
    // line and not the only one.
    const row = header_bytes + @intFromEnum(Section.bir_extra) * 8;
    const offset = std.mem.readInt(u32, copy[row..][0..4], .little);
    const len = std.mem.readInt(u32, copy[row + 4 ..][0..4], .little);
    for ([_][2]u32{
        .{ @intCast(bytes.len + 4), len },
        .{ offset, 1_000_000 },
        .{ offset, std.math.maxInt(u32) },
        .{ offset + 1, len },
        .{ 0, len },
    }) |pair| {
        std.mem.writeInt(u32, copy[row..][0..4], pair[0], .little);
        std.mem.writeInt(u32, copy[row + 4 ..][0..4], pair[1], .little);
        reseal(copy);
        try expectMiss(gpa, copy, "a section offset or length that leaves the file");
    }
    std.mem.writeInt(u32, copy[row..][0..4], offset, .little);
    std.mem.writeInt(u32, copy[row + 4 ..][0..4], len, .little);
    reseal(copy);
    {
        var ok = try read(gpa, copy, sample_key);
        ok.deinit(gpa);
    }

    // A `bir_symbols` slot past the string table, and a `strings` record
    // overrunning its blob — the two indices a caller is handed unchecked.
    {
        const symbols_at = std.mem.readInt(u32, copy[header_bytes + @intFromEnum(Section.bir_symbols) * 8 ..][0..4], .little);
        std.mem.writeInt(u32, copy[symbols_at..][0..4], 99, .little);
        reseal(copy);
        try expectMiss(gpa, copy, "a `bir_symbols` slot past the string table");
        std.mem.writeInt(u32, copy[symbols_at..][0..4], 0, .little);
        reseal(copy);
    }
    {
        const strings_at = std.mem.readInt(u32, copy[header_bytes + @intFromEnum(Section.strings) * 8 ..][0..4], .little);
        const record = strings_at + Strings.header;
        std.mem.writeInt(u32, copy[record + 4 ..][0..4], 1_000_000, .little);
        reseal(copy);
        try expectMiss(gpa, copy, "a `strings` record overrunning its blob");
    }
}

// **The mutation sweep** (`plans/m4-2.md` §9.4 item 24), in the shape
// `resolve/iface_bytes.zig` established and `cache/entry_bytes.zig` repeated:
// one real artifact, every byte flipped in turn and set to `0x00` and
// `0xFF`, with every outcome either a load `verify` accepts or a refusal —
// never a trap, never a read past the buffer. Deterministic, bounded, and run
// under `zig build test`, which is Debug, so a read past a slice is a panic
// rather than a silent wrong answer.
//
// **It runs twice, and the two halves answer two different questions.**
//
// RESEALED: the body hash is recomputed after each mutation, so the hash is
// out of the way and every structural check is the thing under test. Some
// mutants load — a byte in a section's padding, a `line_starts` entry, a
// diagnostic's prose — and that is required, because a sweep in which
// nothing ever loaded would prove only that the reader says no.
//
// AS IS: the hash is left alone, which is what a flipped bit on a disk
// actually looks like. **Nothing may be accepted.** That is the integrity
// claim a content-addressed name cannot make on its own — the name says the
// bytes were written for this key, not that the disk kept them — and it is
// why `body_hash` is in the header at all.
test "fuzz: every mutation is refused, and with the hash resealed some still load" {
    const gpa = testing.allocator;
    var sample = try Sample.init(gpa);
    defer sample.deinit(gpa);
    const bytes = try write(gpa, gpa, sample.input(&sample_diagnostics));
    defer gpa.free(bytes);
    try testing.expect(bytes.len > 512);
    const token_count: u32 = @intCast(sample.tokens.len);

    const copy = try gpa.dupe(u8, bytes);
    defer gpa.free(copy);

    var resealed_loaded: usize = 0;
    var resealed_refused: usize = 0;
    var as_is_loaded: usize = 0;
    var attempts: usize = 0;

    for ([_]bool{ true, false }) |reseal_it| {
        for (0..bytes.len) |at| {
            for ([_]u8{ 0x00, 0xFF, 0x5A }) |value| {
                const was = copy[at];
                copy[at] = if (value == 0x5A) was ^ 0x5A else value;
                if (copy[at] == was) {
                    copy[at] = was;
                    continue;
                }
                if (reseal_it) reseal(copy);
                attempts += 1;
                if (read(gpa, copy, sample_key)) |loaded_const| {
                    var loaded = loaded_const;
                    defer loaded.deinit(gpa);
                    // A loaded artifact must satisfy `verify` or be refused
                    // by it; either way the caller never sees an index that
                    // leaves its array.
                    if (loaded.bir.verify(token_count)) {
                        if (reseal_it) resealed_loaded += 1 else as_is_loaded += 1;
                    } else {
                        resealed_refused += 1;
                    }
                } else |err| {
                    try testing.expectEqual(error.BadArtifact, err);
                    resealed_refused += 1;
                }
                copy[at] = was;
                if (reseal_it) reseal(copy);
            }
        }
    }

    // The integrity claim: with the hash as the writer left it, **no**
    // mutation of any byte of the file is accepted.
    try testing.expectEqual(@as(usize, 0), as_is_loaded);
    // And the sweep is not vacuous: with the hash resealed, mutations that
    // land where the format has slack do load.
    try testing.expect(resealed_loaded > 50);
    try testing.expect(resealed_refused > 50);
    try testing.expect(attempts > 2000);
}

test "every prefix of a real artifact is a miss, which is what makes the dropped rename safe" {
    // `plans/m4-2.md` §6 B drops write-to-temp-plus-`rename` for both file
    // kinds, so a reader CAN see a partial file: `cache/Dir.zig` does one
    // `create` and one sequential write of one buffer, and a reader racing it
    // observes a PREFIX. This is the deterministic proof that every one of
    // them is refused — the black-box race fixture is the same claim under
    // real concurrency, and this is the one that covers every length.
    const gpa = testing.allocator;
    var sample = try Sample.init(gpa);
    defer sample.deinit(gpa);
    const bytes = try write(gpa, gpa, sample.input(&sample_diagnostics));
    defer gpa.free(bytes);
    try testing.expect(bytes.len > 512);

    for (0..bytes.len) |len| {
        var loaded = read(gpa, bytes[0..len], sample_key) catch |err| {
            try testing.expectEqual(error.BadArtifact, err);
            continue;
        };
        loaded.deinit(gpa);
        std.debug.print("a {d}-byte prefix of a {d}-byte artifact was accepted\n", .{ len, bytes.len });
        return error.PrefixAccepted;
    }
    // …and the whole thing is not.
    var whole = try read(gpa, bytes, sample_key);
    whole.deinit(gpa);
}

test "verify refuses the structural faults a well-typed record can still have" {
    // `plans/m4-2.md` §9.4's structural half, stated against `Bir.verify`
    // directly so a failure names the promise rather than a byte offset.
    const gpa = testing.allocator;
    var sample = try Sample.init(gpa);
    defer sample.deinit(gpa);
    const token_count: u32 = @intCast(sample.tokens.len);
    try testing.expect(sample.bir.verify(token_count));

    // A `main_token` past the token list.
    {
        const slot = &sample.bir.insts.items(.main_token)[0];
        const was = slot.*;
        slot.* = token_count;
        try testing.expect(!sample.bir.verify(token_count));
        slot.* = was;
    }
    const decls: []Bir.Decl = @constCast(sample.bir.decls);
    const Case = struct { what: []const u8, apply: *const fn (*Bir.Decl) void };
    const cases = [_]Case{
        .{ .what = "inst_end before inst_start", .apply = struct {
            fn go(d: *Bir.Decl) void {
                d.inst_end = @enumFromInt(0);
                d.inst_start = @enumFromInt(1);
            }
        }.go },
        .{ .what = "an instruction range past the column", .apply = struct {
            fn go(d: *Bir.Decl) void {
                d.inst_end = @enumFromInt(99);
            }
        }.go },
        .{ .what = "a locals range past the table", .apply = struct {
            fn go(d: *Bir.Decl) void {
                d.locals_end = 99;
            }
        }.go },
        .{ .what = "a refs range past the table", .apply = struct {
            fn go(d: *Bir.Decl) void {
                d.refs_end = 99;
            }
        }.go },
        .{ .what = "a ctors range past the table", .apply = struct {
            fn go(d: *Bir.Decl) void {
                d.ctors_end = 99;
            }
        }.go },
        .{ .what = "a type_params range past `symbols`", .apply = struct {
            fn go(d: *Bir.Decl) void {
                d.type_params_end = 99;
            }
        }.go },
        .{ .what = "a `where` range past `extra`", .apply = struct {
            fn go(d: *Bir.Decl) void {
                d.where_end = @enumFromInt(99);
            }
        }.go },
        .{ .what = "a SymbolIndex past `symbols`", .apply = struct {
            fn go(d: *Bir.Decl) void {
                d.name = @enumFromInt(99);
            }
        }.go },
        .{ .what = "a body past `insts`", .apply = struct {
            fn go(d: *Bir.Decl) void {
                d.body = @enumFromInt(99);
            }
        }.go },
        .{ .what = "a name_token past the token list", .apply = struct {
            fn go(d: *Bir.Decl) void {
                d.name_token = 4242;
            }
        }.go },
    };
    for (cases) |c| {
        const was = decls[0];
        c.apply(&decls[0]);
        if (sample.bir.verify(token_count)) {
            std.debug.print("verify accepted {s}\n", .{c.what});
            return error.VerifyAcceptedABadRecord;
        }
        decls[0] = was;
    }
    try testing.expect(sample.bir.verify(token_count));

    // Two declarations whose instruction ranges OVERLAP: each is in bounds
    // on its own, and the partition `Bir.zig:10-14` promises is broken.
    {
        const two = try gpa.alloc(Bir.Decl, 2);
        defer gpa.free(two);
        two[0] = decls[0];
        two[1] = decls[0];
        two[0].inst_start = @enumFromInt(0);
        two[0].inst_end = @enumFromInt(2);
        two[1].inst_start = @enumFromInt(1);
        two[1].inst_end = @enumFromInt(3);
        const was = sample.bir.decls;
        sample.bir.decls = two;
        try testing.expect(!sample.bir.verify(token_count));
        two[1].inst_start = @enumFromInt(2);
        try testing.expect(sample.bir.verify(token_count));
        sample.bir.decls = was;
    }
}

/// `bytes` must not read back as an artifact, and `what` says which mutation
/// made it so when it does.
fn expectMiss(gpa: Allocator, bytes: []const u8, what: []const u8) !void {
    var loaded = read(gpa, bytes, sample_key) catch |err| {
        try testing.expectEqual(error.BadArtifact, err);
        return;
    };
    loaded.deinit(gpa);
    std.debug.print("{s} was accepted\n", .{what});
    return error.CorruptArtifactAccepted;
}

/// Recompute the body hash after a deliberate mutation, so a test that means
/// to exercise a BOUNDS check is not silently answered by the hash instead.
fn reseal(bytes: []u8) void {
    const digest = iface_bytes.hash(bytes[hashed_from..]);
    @memcpy(bytes[40..56], &digest);
}

test "an enum value no version defines is refused, and a non-exhaustive one is not" {
    try testing.expect(validEnum(Bir.Decl.Kind, 0));
    try testing.expect(!validEnum(Bir.Decl.Kind, 99));
    try testing.expect(!validEnum(Bir.Local.Kind, 4));
    try testing.expect(!validEnum(Bir.Ref.Kind, 6));
    // `SymbolIndex` is non-exhaustive: `none` is `maxInt(u32)` and every
    // other value is a slot.
    try testing.expect(validEnum(Bir.SymbolIndex, 12345));
    try testing.expect(validEnum(Bir.SymbolIndex, std.math.maxInt(u32)));
}
