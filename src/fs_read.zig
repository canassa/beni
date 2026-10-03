//! Reading a whole file that may change while it is read.
//!
//! Every file beni reads can be rewritten under it: a source by the user,
//! an editor or a formatter; a sibling `.js` file the same way; a cache
//! entry by another beni process storing the same key; an output record or
//! a manifest by anything at all. So no read here trusts a `stat`. The size
//! a `stat` reports is a HINT for the first allocation, never a bound and
//! never a term in a subtraction: the read goes on until the file says it
//! has ended, growing the buffer as it must, and stops at the caller's
//! limit.
//!
//! This is what `std.Io.Dir.readFileAlloc` does not do in Zig 0.16: it
//! stats the file once and later computes that size minus the position, so
//! a file that grew between the `stat` and the reads made the subtraction
//! overflow and the build trap.
//!
//! What a file that changed during the read MEANS is the caller's to say,
//! and there are two answers:
//!
//! - `readAtMost` fills a buffer the caller sized and returns what the reads
//!   returned, stopping early at the end of the file or at a failed read. A
//!   cache entry is read this way, into a buffer the size its `stat` saw: its
//!   writer rewrites the same bytes, so what comes back is a prefix of the
//!   one true contents, and a prefix is a miss through the format's own
//!   bounds.
//! - `readFile` and `readFileSentinel` compare a `stat` taken before the
//!   read with one taken after it, and read the file once more when the two
//!   differ in size or modification time, or when the byte count differs from
//!   the size. The second read is accepted whatever it finds: a file that is
//!   still being written is one the next build reads again, and what matters
//!   here is that beni never crashes and never reads past what it was given.
//!   Every consumer of these bytes — the lexer, a hash, a parser of beni's
//!   own formats — accepts any bytes at all.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const ReadError = Io.File.OpenError || Io.File.ReadStreamingError || Allocator.Error || error{
    /// The file holds at least `limit` bytes.
    StreamTooLong,
};

/// Fill `buffer` from `file`'s current position and return how many bytes
/// were read: fewer than `buffer.len` when the file ended first or a read
/// failed. A short read is not a failure — it is what a reader racing a
/// writer sees — so the reads go on until the buffer is full or the file is
/// exhausted, and a caller that needs the whole file declares a short
/// result a miss itself.
pub fn readAtMost(io: Io, file: Io.File, buffer: []u8) usize {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const n = file.readStreaming(io, &.{buffer[filled..]}) catch break;
        if (n == 0) break;
        filled += n;
    }
    return filled;
}

/// Read `file` from its current position to its end into `out`, replacing
/// what `out` held. `size_hint` sizes the first allocation and nothing else;
/// the file may turn out longer or shorter. A file of `limit` bytes or more
/// is `error.StreamTooLong`, and no more than `limit` bytes are ever read.
///
/// `out` keeps at least one unused byte of capacity, because the read that
/// finds the end needs somewhere to land; a caller that appends a sentinel
/// therefore never reallocates for it when the hint was right.
pub fn readToEnd(
    io: Io,
    file: Io.File,
    gpa: Allocator,
    out: *std.ArrayList(u8),
    size_hint: u64,
    limit: Io.Limit,
) ReadError!void {
    const max: usize = @backingInt(limit);
    out.clearRetainingCapacity();
    const hint: usize = @intCast(@min(size_hint, max));
    try out.ensureTotalCapacityPrecise(gpa, hint +| 1);
    while (out.items.len < max) {
        if (out.items.len == out.capacity) try out.ensureUnusedCapacity(gpa, 1);
        const free = out.unusedCapacitySlice();
        const room = free[0..@min(free.len, max - out.items.len)];
        const n = file.readStreaming(io, &.{room}) catch |err| switch (err) {
            error.EndOfStream => return,
            else => |e| return e,
        };
        // Only an empty buffer reads zero bytes; `room` is never empty, so
        // this is an end the reader did not name, and it ends the loop.
        if (n == 0) return;
        out.items.len += n;
    }
    return error.StreamTooLong;
}

/// Read the whole of `sub_path`, relative to `dir`, into `out`, replacing
/// what `out` held; the file is read a second time when it changed during
/// the first read (see the file comment). A file of `limit` bytes or more is
/// `error.StreamTooLong`.
pub fn readFile(
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    gpa: Allocator,
    out: *std.ArrayList(u8),
    limit: Io.Limit,
) ReadError!void {
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        var file = try dir.openFile(io, sub_path, .{});
        defer file.close(io);
        // A file that cannot be stated, or is not a regular file, has no
        // size to compare against: it is read to its end, once.
        const before: ?Io.File.Stat = file.stat(io) catch null;
        const regular = if (before) |b| b.kind == .file else false;
        try readToEnd(io, file, gpa, out, if (regular) before.?.size else 0, limit);
        if (!regular or attempt == 1) return;
        const after = file.stat(io) catch return;
        if (unchanged(before.?, after, out.items.len)) return;
    }
}

/// `readFile`, returning the bytes with a zero after them, owned by `gpa`.
pub fn readFileSentinel(io: Io, dir: Io.Dir, sub_path: []const u8, gpa: Allocator, limit: Io.Limit) ReadError![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try readFile(io, dir, sub_path, gpa, &out, limit);
    return out.toOwnedSliceSentinel(gpa, 0);
}

/// `readFile`, returning the bytes, owned by `gpa`.
pub fn readFileAlloc(io: Io, dir: Io.Dir, sub_path: []const u8, gpa: Allocator, limit: Io.Limit) ReadError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try readFile(io, dir, sub_path, gpa, &out, limit);
    return out.toOwnedSlice(gpa);
}

/// Whether a read of `len` bytes, between a `stat` of `before` and one of
/// `after`, saw a file nobody touched.
fn unchanged(before: Io.File.Stat, after: Io.File.Stat, len: usize) bool {
    return before.size == len and after.size == len and
        before.mtime.nanoseconds == after.mtime.nanoseconds;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// For tests: an `Io` that reports every file's size as `reported`, the size
/// a `stat` sees when it lands at a different moment of a concurrent
/// writer's work than the reads that follow it. Smaller than the file is a
/// file that grew after the `stat`; larger is one that shrank.
pub const StaleStat = struct {
    pub var reported: u64 = 0;
    var vtable: Io.VTable = undefined;

    pub fn io() Io {
        vtable = testing.io.vtable.*;
        vtable.fileStat = fileStat;
        return .{ .userdata = testing.io.userdata, .vtable = &vtable };
    }

    fn fileStat(userdata: ?*anyopaque, file: Io.File) Io.File.StatError!Io.File.Stat {
        var info = try testing.io.vtable.fileStat(userdata, file);
        info.size = reported;
        return info;
    }

    /// The sizes a test runs through: a little, nothing, most, all, and
    /// more than there is, for a file of `len` bytes.
    pub fn sizes(len: u64) [5]u64 {
        return .{ 1, 0, len - 1, len, len + 100 };
    }

    /// `len` bytes with no run long enough for a prefix to pass for the
    /// whole, written to `sub_path` in `dir`.
    pub fn writeSample(dir: Io.Dir, sub_path: []const u8, bytes: []u8) !void {
        for (bytes, 0..) |*b, i| b.* = @truncate(i *% 7 +% 1);
        try dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = bytes });
    }
};

test "a file whose size changes between the stat and the reads is read whole" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var bytes: [4096]u8 = undefined;
    try StaleStat.writeSample(tmp.dir, "f", &bytes);
    const io = StaleStat.io();
    for (StaleStat.sizes(bytes.len)) |size| {
        StaleStat.reported = size;
        const got = try readFileSentinel(io, tmp.dir, "f", testing.allocator, .unlimited);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, &bytes, got);
        const plain = try readFileAlloc(io, tmp.dir, "f", testing.allocator, .unlimited);
        defer testing.allocator.free(plain);
        try testing.expectEqualSlices(u8, &bytes, plain);
    }
}

test "the limit refuses a file of that many bytes and accepts one fewer" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var bytes: [100]u8 = undefined;
    try StaleStat.writeSample(tmp.dir, "f", &bytes);
    const io = StaleStat.io();
    for (StaleStat.sizes(bytes.len)) |size| {
        StaleStat.reported = size;
        try testing.expectError(error.StreamTooLong, readFileAlloc(io, tmp.dir, "f", testing.allocator, .limited(100)));
        const got = try readFileAlloc(io, tmp.dir, "f", testing.allocator, .limited(101));
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, &bytes, got);
    }
}

test "an empty file reads as empty, with its sentinel" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "" });
    const got = try readFileSentinel(testing.io, tmp.dir, "f", testing.allocator, .unlimited);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
    try testing.expectEqual(@as(u8, 0), got[0]);
}

test "a missing file is the open's error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectError(error.FileNotFound, readFileAlloc(testing.io, tmp.dir, "absent", testing.allocator, .unlimited));
}
