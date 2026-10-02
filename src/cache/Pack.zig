//! The checked core (docs/design/fast-compiler.md §8, *The checked core,
//! embedded*): every front-end artifact and every cache entry of the core
//! package and of the platforms the binary carries — one entry per chain a
//! platform module can be checked in — produced once when beni itself is
//! built and carried in the binary, so that no build re-lexes, re-parses,
//! re-lowers or re-checks an embedded core or platform module.
//!
//! **It is a read-only cache directory in one blob, keyed exactly as the
//! directory is.** A row is `(kind, key)` — the file key of a front-end
//! artifact or the module key of an entry — and the bytes under it are the
//! bytes `Dir` would hold under that name, in the same two formats. So a
//! lookup is the directory's lookup with the I/O taken out, a hit is
//! validated and installed by exactly the code that validates and installs
//! a directory's, and every way a row can fail to apply — another option
//! string, another `--pattern-budget`, a `--cache-build-id`, a core that is
//! not the embedded one — is a key that is not in the table, which is a
//! MISS and the module is checked as it always was.
//!
//! `build.zig` makes the blob by running `src/core_pack_main.zig` over the
//! core directory with the build id of the compiler that will carry it, and
//! embeds it as the module `core_pack`.
//!
//! ```
//! "BENIPACK"            8       magic
//! version: u32                  `version`
//! count: u32                    rows
//! rows[count], sorted by (kind, key):
//!   kind: u8, 3 zero bytes      `Dir.Kind`: 0 an entry, 1 a front-end artifact
//!   key: [16]u8
//!   offset: u32, len: u32       into the blob, from its first byte
//! the payloads, in row order
//! ```
//!
//! Little-endian by definition, like every byte format of the cache, and
//! read with `readInt` so the blob needs no alignment: `@embedFile` gives
//! it none.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = @import("Dir.zig");
const Key = @import("Key.zig");

pub const magic = "BENIPACK";
pub const version: u32 = 1;

const header_len = magic.len + 4 + 4;
const row_len = 4 + 16 + 4 + 4;

pub const Kind = Dir.Kind;

/// A pack, validated. `empty` holds no row and finds nothing.
pub const Pack = struct {
    bytes: []const u8,
    count: u32,

    pub const empty: Pack = .{ .bytes = &.{}, .count = 0 };

    /// `bytes` as a pack, or `empty` when they are not one. A compiler built
    /// without a checked core embeds no bytes at all, and that is the
    /// ordinary case of this branch; a blob that is there and malformed
    /// would be a bug in the build, and checking every module is what
    /// that bug costs, never a wrong answer.
    pub fn init(bytes: []const u8) Pack {
        if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..magic.len], magic)) return empty;
        if (readU32(bytes, magic.len) != version) return empty;
        const count = readU32(bytes, magic.len + 4);
        const table_end = @as(u64, header_len) + @as(u64, count) * row_len;
        if (table_end > bytes.len) return empty;
        const pack: Pack = .{ .bytes = bytes, .count = count };
        var previous: ?Row = null;
        for (0..count) |i| {
            const row = pack.rowAt(@intCast(i));
            if (row.kind > @intFromEnum(Kind.frontend)) return empty;
            if (@as(u64, row.offset) + row.len > bytes.len or row.offset < table_end) return empty;
            if (previous) |p| if (!p.lessThan(row)) return empty;
            previous = row;
        }
        return pack;
    }

    /// The payload stored under `(kind, key)`, borrowed from the pack, or
    /// null. A binary search over the sorted table.
    pub fn find(pack: Pack, kind: Kind, key: Key.Key) ?[]const u8 {
        const want: Row = .{ .kind = @intFromEnum(kind), .key = key, .offset = 0, .len = 0 };
        var lo: u32 = 0;
        var hi: u32 = pack.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const row = pack.rowAt(mid);
            if (row.lessThan(want)) {
                lo = mid + 1;
            } else if (want.lessThan(row)) {
                hi = mid;
            } else {
                return pack.bytes[row.offset..][0..row.len];
            }
        }
        return null;
    }

    /// How many rows of `kind` the pack holds.
    pub fn countOf(pack: Pack, kind: Kind) u32 {
        var n: u32 = 0;
        for (0..pack.count) |i| {
            if (pack.rowAt(@intCast(i)).kind == @intFromEnum(kind)) n += 1;
        }
        return n;
    }

    fn rowAt(pack: Pack, i: u32) Row {
        const at = header_len + @as(usize, i) * row_len;
        return .{
            .kind = pack.bytes[at],
            .key = pack.bytes[at + 4 ..][0..16].*,
            .offset = readU32(pack.bytes, at + 20),
            .len = readU32(pack.bytes, at + 24),
        };
    }
};

const Row = struct {
    kind: u8,
    key: Key.Key,
    offset: u32,
    len: u32,

    fn lessThan(a: Row, b: Row) bool {
        if (a.kind != b.kind) return a.kind < b.kind;
        return std.mem.order(u8, &a.key, &b.key) == .lt;
    }
};

fn readU32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

/// Collects rows and writes the blob. The rows are sorted when the blob is
/// written, so the order they were added in — which worker finished first —
/// never reaches a byte of it (`fast-compiler.md` §10).
pub const Writer = struct {
    rows: std.ArrayList(Pending) = .empty,

    const Pending = struct {
        kind: Kind,
        key: Key.Key,
        /// Owned.
        bytes: []u8,
    };

    pub fn deinit(w: *Writer, gpa: Allocator) void {
        for (w.rows.items) |p| gpa.free(p.bytes);
        w.rows.deinit(gpa);
        w.* = undefined;
    }

    /// Add a copy of `bytes` under `(kind, key)`.
    pub fn add(w: *Writer, gpa: Allocator, kind: Kind, key: Key.Key, bytes: []const u8) Allocator.Error!void {
        const owned = try gpa.dupe(u8, bytes);
        errdefer gpa.free(owned);
        try w.rows.append(gpa, .{ .kind = kind, .key = key, .bytes = owned });
    }

    pub fn countOf(w: *const Writer, kind: Kind) u32 {
        var n: u32 = 0;
        for (w.rows.items) |p| {
            if (p.kind == kind) n += 1;
        }
        return n;
    }

    /// The blob. Two rows under one `(kind, key)` hold the same bytes by
    /// construction — a key names its content — and only the first is kept.
    pub fn write(w: *Writer, gpa: Allocator) Allocator.Error![]u8 {
        std.mem.sort(Pending, w.rows.items, {}, struct {
            fn lessThan(_: void, a: Pending, b: Pending) bool {
                if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
                return std.mem.order(u8, &a.key, &b.key) == .lt;
            }
        }.lessThan);
        var unique: std.ArrayList(Pending) = .empty;
        defer unique.deinit(gpa);
        for (w.rows.items) |p| {
            if (unique.items.len != 0) {
                const last = unique.items[unique.items.len - 1];
                if (last.kind == p.kind and std.mem.eql(u8, &last.key, &p.key)) continue;
            }
            try unique.append(gpa, p);
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, magic);
        try appendU32(gpa, &out, version);
        try appendU32(gpa, &out, @intCast(unique.items.len));
        var offset: usize = header_len + unique.items.len * row_len;
        for (unique.items) |p| {
            try out.append(gpa, @intFromEnum(p.kind));
            try out.appendNTimes(gpa, 0, 3);
            try out.appendSlice(gpa, &p.key);
            try appendU32(gpa, &out, @intCast(offset));
            try appendU32(gpa, &out, @intCast(p.bytes.len));
            offset += p.bytes.len;
        }
        for (unique.items) |p| try out.appendSlice(gpa, p.bytes);
        return out.toOwnedSlice(gpa);
    }
};

fn appendU32(gpa: Allocator, out: *std.ArrayList(u8), value: u32) Allocator.Error!void {
    var word: [4]u8 = undefined;
    std.mem.writeInt(u32, &word, value, .little);
    try out.appendSlice(gpa, &word);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a pack finds what was written under each kind and key, and nothing else" {
    var w: Writer = .{};
    defer w.deinit(testing.allocator);
    const a: Key.Key = @splat(0x22);
    const b: Key.Key = @splat(0x11);
    // Added out of order and once twice: the blob does not care.
    try w.add(testing.allocator, .frontend, a, "front a");
    try w.add(testing.allocator, .entry, a, "entry a");
    try w.add(testing.allocator, .entry, b, "entry b");
    try w.add(testing.allocator, .entry, a, "entry a");
    const blob = try w.write(testing.allocator);
    defer testing.allocator.free(blob);

    const pack = Pack.init(blob);
    try testing.expectEqual(@as(u32, 3), pack.count);
    try testing.expectEqualStrings("entry a", pack.find(.entry, a).?);
    try testing.expectEqualStrings("entry b", pack.find(.entry, b).?);
    try testing.expectEqualStrings("front a", pack.find(.frontend, a).?);
    try testing.expect(pack.find(.frontend, b) == null);
    try testing.expect(pack.find(.entry, @splat(0)) == null);
    try testing.expectEqual(@as(u32, 2), pack.countOf(.entry));
}

test "bytes that are not a pack are the empty pack" {
    try testing.expectEqual(@as(u32, 0), Pack.init("").count);
    try testing.expectEqual(@as(u32, 0), Pack.init("BENIPACK\x02\x00\x00\x00\x00\x00\x00\x00").count);
    // A table that runs past the end.
    try testing.expectEqual(@as(u32, 0), Pack.init("BENIPACK\x01\x00\x00\x00\x05\x00\x00\x00").count);
    var w: Writer = .{};
    defer w.deinit(testing.allocator);
    try w.add(testing.allocator, .entry, @splat(1), "x");
    const blob = try w.write(testing.allocator);
    defer testing.allocator.free(blob);
    // A payload that runs past the end.
    try testing.expectEqual(@as(u32, 0), Pack.init(blob[0 .. blob.len - 1]).count);
    try testing.expectEqual(@as(u32, 1), Pack.init(blob).count);
}
