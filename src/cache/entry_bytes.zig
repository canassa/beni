//! One cache entry as BYTES (docs/design/checker.md §7, *The cache entry, and
//! the sidecar beside the record*).
//!
//! One file per module, named by its cache key, holding the record verbatim
//! and the two things a hit cannot recompute. Same shape as the record's:
//! magic, version, a section table, little-endian scalars, 4-byte alignment,
//! gaps zero-filled — and **a bad entry is a MISS, never a message and never
//! an exit code**.
//!
//! ```
//! header    magic "BENICAC\x00" (8)   format_version: u32   section_count: u32
//!           key: [16]u8               the key this entry was written for
//! table     section_count × { offset: u32, len: u32 }        offsets from byte 0
//! sections  in table order, each 4-byte aligned
//! ```
//!
//! Four sections, in this order and no other: `interface`, `dispatch`,
//! `schema_plan`, `diagnostics`.
//!
//! **`interface` is the bytes `iface_bytes.write` produced, verbatim**, so
//! `iface_bytes.hash` over that section IS the interface hash the firewall
//! compares, and the cutoff re-derives nothing. This file therefore does not know
//! what is inside it — it is a container over four opaque byte strings, and
//! `dispatch` and `schema_plan` are opaque to it in the same way.
//!
//! **The entry repeats its key in the header because the file NAME is the
//! key.** A mismatch is the "wrong build id" case — a directory entry moved,
//! a file copied, a name reused — and it must be detectable without trusting
//! the directory. `readFor` is the only entry point a cache should use.
//!
//! **Reading borrows.** `read` returns slices into the bytes it was given and
//! allocates nothing; the caller keeps the file's bytes alive for as long as
//! it holds the result. That is what makes a hit a `memcpy` and a header
//! walk, and it is the shape §8.3's eventual zero-copy map wants.
//!
//! **Every index is checked before the caller sees it**, which is what makes
//! a corrupt file a cache miss rather than a wrong answer: a wrong magic, an
//! unknown `format_version`, a short file, a section whose offset or length
//! leaves the file, a misaligned section, a diagnostics row whose message
//! runs past its blob. Each is `error.BadEntry`, which a cache turns into
//! "recompute from source". None is a diagnostic and none is an exit code —
//! a stale cache must be indistinguishable from a cold build.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// First eight bytes of every entry.
pub const magic = "BENICAC\x00";

/// Bumped whenever the meaning of any byte changes. A format change is a
/// version bump and a cache discard, never a migration into spare bytes
/// — and the compiler build id in the key means a
/// version bump is belt and braces rather than the only defence.
///
/// 3: the `dispatch` section became `dispatch_bytes` format 2,
/// checker-v2.md §13.1's evidence trees (§14.3).
pub const format_version: u32 = 3;

/// The four sections, in this order and no other.
pub const Section = enum(u32) {
    interface,
    dispatch,
    schema_plan,
    diagnostics,

    pub const count: u32 = @typeInfo(Section).@"enum".fields.len;
};

const header_bytes: u32 = 32; // magic(8) + version(4) + section_count(4) + key(16)
const table_bytes: u32 = Section.count * 8;
const body_start: u32 = header_bytes + table_bytes;

pub const ReadError = error{
    /// The bytes are not an entry this compiler can read, or they are not
    /// the entry that was asked for. The caller recomputes from source.
    BadEntry,
} || Allocator.Error;

/// What an entry holds, as four opaque byte strings plus the key it was
/// written for. Borrowed from the file's bytes on the way in and out.
pub const Entry = struct {
    key: [16]u8,
    /// `iface_bytes.write`'s output, verbatim.
    interface: []const u8,
    /// `dispatch_bytes.write`'s output.
    dispatch: []const u8,
    /// `schema_plan_bytes.write`'s output.
    schema_plan: []const u8,
    /// `writeDiagnostics`' output.
    diagnostics: []const u8,

    fn section(e: *const Entry, s: Section) []const u8 {
        return switch (s) {
            .interface => e.interface,
            .dispatch => e.dispatch,
            .schema_plan => e.schema_plan,
            .diagnostics => e.diagnostics,
        };
    }
};

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/// `entry` as bytes. The caller owns the result.
pub fn write(gpa: Allocator, entry: Entry) Allocator.Error![]u8 {
    var offsets: [Section.count]u32 = undefined;
    var lengths: [Section.count]u32 = undefined;
    var at: u32 = body_start;
    for (0..Section.count) |i| {
        const s: Section = @enumFromInt(i);
        const bytes = entry.section(s);
        offsets[i] = at;
        lengths[i] = @intCast(bytes.len);
        at += lengths[i];
        at += @intCast(pad4(at));
    }

    const out = try gpa.alloc(u8, at);
    errdefer gpa.free(out);
    @memset(out, 0); // every gap is zero-filled, and hashed like everything else
    @memcpy(out[0..8], magic);
    std.mem.writeInt(u32, out[8..12], format_version, .little);
    std.mem.writeInt(u32, out[12..16], Section.count, .little);
    @memcpy(out[16..32], &entry.key);
    for (0..Section.count) |i| {
        const row = out[header_bytes + i * 8 ..][0..8];
        std.mem.writeInt(u32, row[0..4], offsets[i], .little);
        std.mem.writeInt(u32, row[4..8], lengths[i], .little);
        const s: Section = @enumFromInt(i);
        @memcpy(out[offsets[i]..][0..lengths[i]], entry.section(s));
    }
    return out;
}

fn pad4(n: usize) usize {
    return (4 - (n % 4)) % 4;
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/// The entry `bytes` describes, with every section bounds-checked. The result
/// borrows from `bytes`.
pub fn read(bytes: []const u8) ReadError!Entry {
    if (bytes.len < body_start) return error.BadEntry;
    if (!std.mem.eql(u8, bytes[0..8], magic)) return error.BadEntry;
    if (std.mem.readInt(u32, bytes[8..12], .little) != format_version) return error.BadEntry;
    if (std.mem.readInt(u32, bytes[12..16], .little) != Section.count) return error.BadEntry;

    var entry: Entry = .{
        .key = bytes[16..32].*,
        .interface = &.{},
        .dispatch = &.{},
        .schema_plan = &.{},
        .diagnostics = &.{},
    };
    for (0..Section.count) |i| {
        const row = bytes[header_bytes + i * 8 ..][0..8];
        const offset = std.mem.readInt(u32, row[0..4], .little);
        const len = std.mem.readInt(u32, row[4..8], .little);
        // Every section starts 4-byte aligned and none may leave the file.
        // `@as(u64, …)` so a length chosen to wrap 32 bits is caught here
        // rather than producing a short, plausible slice.
        if (offset % 4 != 0 or offset < body_start) return error.BadEntry;
        if (@as(u64, offset) + @as(u64, len) > bytes.len) return error.BadEntry;
        const slice = bytes[offset..][0..len];
        switch (@as(Section, @enumFromInt(i))) {
            .interface => entry.interface = slice,
            .dispatch => entry.dispatch = slice,
            .schema_plan => entry.schema_plan = slice,
            .diagnostics => entry.diagnostics = slice,
        }
    }
    return entry;
}

/// `read`, refusing an entry that was written for a different key.
///
/// The file's NAME is the key, so this is the check that does not trust the
/// directory: a file copied, renamed or left behind by a compiler whose
/// build id has since moved is a miss here rather than a record installed
/// for the wrong module.
pub fn readFor(bytes: []const u8, key: [16]u8) ReadError!Entry {
    const entry = try read(bytes);
    if (!std.mem.eql(u8, &entry.key, &key)) return error.BadEntry;
    return entry;
}

// ---------------------------------------------------------------------------
// The `diagnostics` section
// ---------------------------------------------------------------------------

/// One replayed diagnostic (`checker.md` §7): `check/Diagnostics.Item` minus
/// its `module`, which the entry is for.
///
/// **The message is the prose the checker rendered**, because a checker's
/// message is built from types that die with the store. **The span is NOT
/// stored** and is recomputed from this build's `SourceStore`, so a module
/// that moved without changing its name still points at the right file —
/// which is also what keeps a path out of the bytes.
///
/// `code` is an integer, which is meaningful only for the compiler build the
/// key names: adding a diagnostic renumbers the enum and changes the build
/// id, and that is the mechanism rather than a version field here.
pub const Diagnostic = struct {
    code: u16,
    severity: u8,
    /// `Item.token` is optional — a message ABOUT a declaration underlines
    /// its name, and no instruction carries that token.
    has_token: bool,
    region: u32,
    token: u32,
    /// Borrowed from the section's bytes on the way out.
    message: []const u8,
};

const row_bytes: u32 = 20; // code(2) severity(1) has_token(1) region(4) token(4) start(4) len(4)
const diagnostics_header: u32 = 8; // count(4) + messages_len(4)

pub fn writeDiagnostics(gpa: Allocator, items: []const Diagnostic) Allocator.Error![]u8 {
    var messages: u32 = 0;
    for (items) |d| messages += @intCast(d.message.len);
    const rows_at = diagnostics_header;
    const blob_at = rows_at + @as(u32, @intCast(items.len)) * row_bytes;
    const total = blob_at + messages + @as(u32, @intCast(pad4(blob_at + messages)));

    const out = try gpa.alloc(u8, total);
    errdefer gpa.free(out);
    @memset(out, 0);
    std.mem.writeInt(u32, out[0..4], @intCast(items.len), .little);
    std.mem.writeInt(u32, out[4..8], messages, .little);
    var cursor: u32 = 0;
    for (items, 0..) |d, i| {
        const row = out[rows_at + i * row_bytes ..][0..row_bytes];
        std.mem.writeInt(u16, row[0..2], d.code, .little);
        row[2] = d.severity;
        row[3] = @intFromBool(d.has_token);
        std.mem.writeInt(u32, row[4..8], d.region, .little);
        std.mem.writeInt(u32, row[8..12], d.token, .little);
        std.mem.writeInt(u32, row[12..16], cursor, .little);
        std.mem.writeInt(u32, row[16..20], @intCast(d.message.len), .little);
        @memcpy(out[blob_at + cursor ..][0..d.message.len], d.message);
        cursor += @intCast(d.message.len);
    }
    return out;
}

/// The diagnostics a section holds. The rows are allocated; every `message`
/// borrows from `bytes`.
pub fn readDiagnostics(gpa: Allocator, bytes: []const u8) ReadError![]Diagnostic {
    if (bytes.len == 0) return &.{};
    if (bytes.len < diagnostics_header) return error.BadEntry;
    const count = std.mem.readInt(u32, bytes[0..4], .little);
    const messages_len = std.mem.readInt(u32, bytes[4..8], .little);
    const rows_at = diagnostics_header;
    const blob_at = @as(u64, rows_at) + @as(u64, count) * row_bytes;
    if (blob_at + messages_len > bytes.len) return error.BadEntry;
    const blob = bytes[@intCast(blob_at)..][0..messages_len];

    const out = try gpa.alloc(Diagnostic, count);
    errdefer gpa.free(out);
    for (out, 0..) |*d, i| {
        const row = bytes[rows_at + i * row_bytes ..][0..row_bytes];
        const start = std.mem.readInt(u32, row[12..16], .little);
        const len = std.mem.readInt(u32, row[16..20], .little);
        // A message that runs past its blob is the shape a truncated file
        // produces, and the one a caller must never be handed.
        if (@as(u64, start) + @as(u64, len) > blob.len) return error.BadEntry;
        d.* = .{
            .code = std.mem.readInt(u16, row[0..2], .little),
            .severity = row[2],
            .has_token = row[3] & 1 == 1,
            .region = std.mem.readInt(u32, row[4..8], .little),
            .token = std.mem.readInt(u32, row[8..12], .little),
            .message = blob[start..][0..len],
        };
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const sample_key: [16]u8 = .{ 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 1, 2, 3, 4, 5, 6 };

fn sampleEntry() Entry {
    return .{
        .key = sample_key,
        // Deliberately lengths that are NOT multiples of four, so the
        // padding between sections is exercised rather than assumed.
        .interface = "record bytes, verbatim",
        .dispatch = "sidecar",
        .schema_plan = "plan",
        .diagnostics = "rows and a blob!!",
    };
}

test "an entry round-trips, sections and key alike" {
    const gpa = testing.allocator;
    const entry = sampleEntry();
    const bytes = try write(gpa, entry);
    defer gpa.free(bytes);

    const back = try readFor(bytes, sample_key);
    try testing.expectEqualSlices(u8, &entry.key, &back.key);
    try testing.expectEqualStrings(entry.interface, back.interface);
    try testing.expectEqualStrings(entry.dispatch, back.dispatch);
    try testing.expectEqualStrings(entry.schema_plan, back.schema_plan);
    try testing.expectEqualStrings(entry.diagnostics, back.diagnostics);

    // Writing the loaded entry again gives the same bytes, which is what
    // makes two processes that compute one key write one file.
    const again = try write(gpa, back);
    defer gpa.free(again);
    try testing.expectEqualSlices(u8, bytes, again);
}

test "an entry with four empty sections round-trips" {
    // The floor: a module with no `pub` declaration, no dispatch and no
    // diagnostic. Nothing here may need a section to be non-empty.
    const gpa = testing.allocator;
    const bytes = try write(gpa, .{
        .key = sample_key,
        .interface = "",
        .dispatch = "",
        .schema_plan = "",
        .diagnostics = "",
    });
    defer gpa.free(bytes);
    const back = try readFor(bytes, sample_key);
    try testing.expectEqual(@as(usize, 0), back.interface.len);
    try testing.expectEqual(@as(usize, 0), back.dispatch.len);
    try testing.expectEqual(@as(usize, 0), back.schema_plan.len);
    try testing.expectEqual(@as(usize, 0), back.diagnostics.len);
}

test "an entry written for another key is a miss, not an entry" {
    // The file NAME is the key, so this is the check that does not trust the
    // directory. Without it, a file copied or renamed installs a record for
    // the wrong module and the build is wrong in a way no diagnostic says.
    const gpa = testing.allocator;
    const bytes = try write(gpa, sampleEntry());
    defer gpa.free(bytes);
    var other = sample_key;
    other[0] +%= 1;
    try testing.expectError(error.BadEntry, readFor(bytes, other));
    // …and `read` alone still hands the key back, so a caller that wants to
    // say WHICH key it found can.
    try testing.expectEqualSlices(u8, &sample_key, &(try read(bytes)).key);
}

test "the six corrupt-entry shapes are each a miss" {
    // `plans/m4-1.md` §6.4: zero-length, truncated mid-section, wrong magic,
    // unknown version, a section offset or length past the end, a header key
    // that is not the file's name. Each must be `error.BadEntry` — never a
    // crash, never a plausible-looking entry.
    const gpa = testing.allocator;
    const bytes = try write(gpa, sampleEntry());
    defer gpa.free(bytes);
    // The unmutated entry loads, so every failure below is the mutation's.
    _ = try readFor(bytes, sample_key);

    // 1. Zero length.
    try testing.expectError(error.BadEntry, read(&.{}));
    // 2. Truncated mid-section.
    try testing.expectError(error.BadEntry, read(bytes[0 .. bytes.len - 4]));
    // …and truncated inside the header, which is a different branch.
    try testing.expectError(error.BadEntry, read(bytes[0..20]));

    const copy = try gpa.dupe(u8, bytes);
    defer gpa.free(copy);
    // 3. Wrong magic.
    copy[0] = 'X';
    try testing.expectError(error.BadEntry, read(copy));
    @memcpy(copy[0..8], magic);
    // 4. Unknown format version.
    std.mem.writeInt(u32, copy[8..12], format_version + 1, .little);
    try testing.expectError(error.BadEntry, read(copy));
    std.mem.writeInt(u32, copy[8..12], format_version, .little);
    // …and a section count no version defines.
    std.mem.writeInt(u32, copy[12..16], Section.count + 1, .little);
    try testing.expectError(error.BadEntry, read(copy));
    std.mem.writeInt(u32, copy[12..16], Section.count, .little);
    // 5. A section offset past the end, a length past the end, a length
    //    chosen to wrap 32 bits, and a misaligned offset.
    {
        const row = copy[header_bytes + @intFromEnum(Section.dispatch) * 8 ..][0..8];
        const offset = std.mem.readInt(u32, row[0..4], .little);
        const len = std.mem.readInt(u32, row[4..8], .little);

        std.mem.writeInt(u32, row[0..4], @intCast(bytes.len + 4), .little);
        try testing.expectError(error.BadEntry, read(copy));
        std.mem.writeInt(u32, row[0..4], offset, .little);

        std.mem.writeInt(u32, row[4..8], 1_000_000, .little);
        try testing.expectError(error.BadEntry, read(copy));

        std.mem.writeInt(u32, row[4..8], std.math.maxInt(u32), .little);
        try testing.expectError(error.BadEntry, read(copy));
        std.mem.writeInt(u32, row[4..8], len, .little);

        std.mem.writeInt(u32, row[0..4], offset + 1, .little);
        try testing.expectError(error.BadEntry, read(copy));
        std.mem.writeInt(u32, row[0..4], offset, .little);
    }
    // The entry is intact again, so the sweep above tested the mutations and
    // not a file it had quietly destroyed.
    _ = try readFor(copy, sample_key);
    // 6. A header key that is not the one asked for — above.
}

test "diagnostics round-trip, with and without a token, and an empty list" {
    const gpa = testing.allocator;
    const items = [_]Diagnostic{
        .{ .code = 7, .severity = 0, .has_token = false, .region = 42, .token = 0, .message = "first message" },
        // A `warning`, which is the severity that makes replay necessary at
        // all: `ambiguous_method_receiver` is on by default, so "a module
        // with any diagnostic is never cached" would exempt most projects.
        .{ .code = 300, .severity = 1, .has_token = true, .region = 0, .token = 19, .message = "" },
        .{ .code = 65535, .severity = 0, .has_token = true, .region = 1, .token = 2, .message = "a\nmultiline\nmessage" },
    };
    const bytes = try writeDiagnostics(gpa, &items);
    defer gpa.free(bytes);
    const back = try readDiagnostics(gpa, bytes);
    defer gpa.free(back);
    try testing.expectEqual(items.len, back.len);
    for (items, back) |want, got| {
        try testing.expectEqual(want.code, got.code);
        try testing.expectEqual(want.severity, got.severity);
        try testing.expectEqual(want.has_token, got.has_token);
        try testing.expectEqual(want.region, got.region);
        try testing.expectEqual(want.token, got.token);
        try testing.expectEqualStrings(want.message, got.message);
    }

    const none = try writeDiagnostics(gpa, &.{});
    defer gpa.free(none);
    const none_back = try readDiagnostics(gpa, none);
    defer gpa.free(none_back);
    try testing.expectEqual(@as(usize, 0), none_back.len);
    // A section of zero bytes — which is what a module with no diagnostics
    // gets once the writer skips the empty blob — reads as no diagnostics.
    const empty_back = try readDiagnostics(gpa, &.{});
    try testing.expectEqual(@as(usize, 0), empty_back.len);
}

test "a diagnostics section whose row overruns its blob is a miss" {
    const gpa = testing.allocator;
    const items = [_]Diagnostic{
        .{ .code = 1, .severity = 0, .has_token = false, .region = 0, .token = 0, .message = "hello" },
    };
    const bytes = try writeDiagnostics(gpa, &items);
    defer gpa.free(bytes);
    {
        const back = try readDiagnostics(gpa, bytes);
        gpa.free(back);
    }
    const copy = try gpa.dupe(u8, bytes);
    defer gpa.free(copy);
    // A message length past the end of the blob.
    std.mem.writeInt(u32, copy[diagnostics_header + 16 ..][0..4], 1000, .little);
    try testing.expectError(error.BadEntry, readDiagnostics(gpa, copy));
    std.mem.writeInt(u32, copy[diagnostics_header + 16 ..][0..4], 5, .little);
    // A message START past the end of the blob.
    std.mem.writeInt(u32, copy[diagnostics_header + 12 ..][0..4], 1000, .little);
    try testing.expectError(error.BadEntry, readDiagnostics(gpa, copy));
    std.mem.writeInt(u32, copy[diagnostics_header + 12 ..][0..4], 0, .little);
    // A row count the file cannot hold.
    std.mem.writeInt(u32, copy[0..4], 1_000_000, .little);
    try testing.expectError(error.BadEntry, readDiagnostics(gpa, copy));
    // A row count chosen to wrap 64 bits' worth of multiplication.
    std.mem.writeInt(u32, copy[0..4], std.math.maxInt(u32), .little);
    try testing.expectError(error.BadEntry, readDiagnostics(gpa, copy));
    // Truncated below its own header.
    try testing.expectError(error.BadEntry, readDiagnostics(gpa, bytes[0..4]));
}

// **The fuzz sweep**, the shape `resolve/iface_bytes.zig` established: a real
// entry's bytes mutated at every place the format has a boundary and then at
// random, with every mutation required to end in an error or in an entry
// whose sections are inside the file. Deterministic — a fixed seed, a fixed
// corpus and a fixed schedule — so a failure reproduces exactly, and run
// under `zig build test`, which is Debug, so a read past a slice is a panic
// rather than a silent wrong answer.
test "fuzz: a mutated entry never reads back as one that leaves the file" {
    const gpa = testing.allocator;
    const diagnostics = try writeDiagnostics(gpa, &.{
        .{ .code = 11, .severity = 0, .has_token = true, .region = 3, .token = 4, .message = "a message with some length to it" },
        .{ .code = 12, .severity = 1, .has_token = false, .region = 5, .token = 0, .message = "another" },
    });
    defer gpa.free(diagnostics);
    const bytes = try write(gpa, .{
        .key = sample_key,
        .interface = "a" ** 130,
        .dispatch = "b" ** 71,
        .schema_plan = "p" ** 69,
        .diagnostics = diagnostics,
    });
    defer gpa.free(bytes);
    try testing.expect(bytes.len > 256);

    var loaded: usize = 0;
    var attempts: usize = 0;

    const check = struct {
        fn go(mutated: []const u8, ok: *usize) !void {
            const entry = read(mutated) catch |err| switch (err) {
                error.BadEntry => return,
                error.OutOfMemory => return err,
            };
            // Every section it handed back is inside the bytes it was
            // given — which is the whole claim, because the caller will
            // hand these slices to `iface_bytes.read` and to
            // `readDiagnostics`.
            for ([_][]const u8{ entry.interface, entry.dispatch, entry.diagnostics }) |s| {
                if (s.len == 0) continue;
                try testing.expect(@intFromPtr(s.ptr) >= @intFromPtr(mutated.ptr));
                try testing.expect(@intFromPtr(s.ptr) + s.len <= @intFromPtr(mutated.ptr) + mutated.len);
            }
            // And a diagnostics section that loads has every message inside
            // its own blob.
            const rows = readDiagnostics(testing.allocator, entry.diagnostics) catch |err| switch (err) {
                error.BadEntry => {
                    ok.* += 1;
                    return;
                },
                error.OutOfMemory => return err,
            };
            defer testing.allocator.free(rows);
            for (rows) |d| {
                if (d.message.len == 0) continue;
                try testing.expect(@intFromPtr(d.message.ptr) >= @intFromPtr(entry.diagnostics.ptr));
            }
            ok.* += 1;
        }
    }.go;

    // 1. Truncation at every byte of the header and table, then every fourth
    //    byte of the body — a section boundary is always a multiple of four.
    {
        var len: usize = 0;
        while (len <= bytes.len) : (len += if (len < body_start) 1 else 4) {
            attempts += 1;
            try check(bytes[0..len], &loaded);
        }
    }
    // 2. Every bit of the header and the section table, one at a time: that
    //    is where a length and an offset live, and where a mutation is most
    //    likely to produce something plausible.
    {
        const copy = try gpa.dupe(u8, bytes);
        defer gpa.free(copy);
        for (0..body_start) |i| {
            for (0..8) |bit| {
                copy[i] ^= @as(u8, 1) << @intCast(bit);
                attempts += 1;
                try check(copy, &loaded);
                copy[i] ^= @as(u8, 1) << @intCast(bit);
            }
        }
    }
    // 3. Random single-byte writes, fixed seed.
    {
        var prng: std.Random.DefaultPrng = .init(0xCAC4E);
        const random = prng.random();
        const copy = try gpa.dupe(u8, bytes);
        defer gpa.free(copy);
        for (0..20_000) |_| {
            const at = random.uintLessThan(usize, bytes.len);
            const was = copy[at];
            copy[at] = random.int(u8);
            attempts += 1;
            try check(copy, &loaded);
            copy[at] = was;
        }
    }

    // A sweep in which nothing ever loaded would prove nothing: a mutation
    // that lands in padding, or in a byte the format does not read, must
    // still produce a readable entry.
    try testing.expect(loaded > 100);
    try testing.expect(attempts > 20_000);
}
