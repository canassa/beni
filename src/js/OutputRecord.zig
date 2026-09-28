//! The record of what a build wrote into `--out`, and the removal of what
//! an earlier build wrote there and this one did not (`backend.md` §2, *The
//! output directory holds what the last build wrote, and nothing it wrote
//! before*; CK-163).
//!
//! The record is `_manifest.txt` at the root of `--out`: a first line
//! `beni-manifest 1`, then `<hash> <path>` per file, the hash the 64-bit
//! Wyhash of the bytes written as 16 lower-case hex digits. Everything here
//! errs toward leaving a file where it is: a line it cannot read, a path
//! that could leave `--out`, or bytes that are no longer what beni wrote all
//! mean "not beni's to delete".

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The record's name, relative to `--out`. Reserved by §2's rule 1: it
/// begins with `_`, which no module path can, and it does not end in
/// `.mjs`, which every platform `"entry"` must.
pub const file_name = "_manifest.txt";

const header = "beni-manifest 1";

/// A stale output is read back to compare its hash. A generated file past
/// this is not one beni wrote (§9's outputs are nowhere near it) and is
/// left alone.
const max_stale_bytes = 64 * 1024 * 1024;

pub const Entry = struct {
    hash: u64,
    /// Relative to `--out`, `/`-separated.
    path: []const u8,
};

pub fn hash(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

/// The previous build's entries, or none: no record, an unreadable one, or
/// one with another header all read as empty, and a malformed line is
/// skipped. Paths point into `arena`.
pub fn read(arena: Allocator, io: Io, out_dir: []const u8) Allocator.Error![]const Entry {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir, file_name });
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_stale_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    var lines = std.mem.splitScalar(u8, text, '\n');
    if (!std.mem.eql(u8, lines.first(), header)) return &.{};
    var out: std.ArrayList(Entry) = .empty;
    while (lines.next()) |line| {
        if (line.len < 18 or line[16] != ' ') continue;
        const h = std.fmt.parseInt(u64, line[0..16], 16) catch continue;
        const p = line[17..];
        if (!isContained(p)) continue;
        try out.append(arena, .{ .hash = h, .path = p });
    }
    return out.items;
}

/// Whether `path` names something inside `--out` and is not the record:
/// relative, `/`-separated, and without an empty, `.` or `..` segment. A
/// record is a file in a directory anyone may edit, and a line that could
/// name a path outside it is never acted on.
pub fn isContained(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/') return false;
    if (std.mem.eql(u8, path, file_name)) return false;
    for (path) |c| if (c == '\\' or c == 0 or c == '\r') return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |s| {
        if (s.len == 0 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return false;
    }
    return true;
}

/// Write the record: `entries` in order, each path once (a later duplicate
/// is dropped, so the union of an old and a new record is well formed).
pub fn write(arena: Allocator, io: Io, out_dir: []const u8, entries: []const Entry) (Allocator.Error || Io.Dir.WriteFileError || Io.Dir.CreateDirPathError)!void {
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, header ++ "\n");
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (entries) |entry| {
        if ((try seen.getOrPut(arena, entry.path)).found_existing) continue;
        try text.print(arena, "{x:0>16} {s}\n", .{ entry.hash, entry.path });
    }
    try Io.Dir.cwd().createDirPath(io, out_dir);
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir, file_name });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text.items });
}

/// Remove every file `old` lists that `new` does not, when its bytes still
/// hash to what `old` recorded, and then every directory that removal left
/// empty, up to but not including `out_dir`. Failures are not errors: a
/// file that cannot be read or removed stays, which is the outcome this
/// module always prefers. Returns how many files it removed.
pub fn removeStale(arena: Allocator, io: Io, out_dir: []const u8, old: []const Entry, new: []const Entry) Allocator.Error!u32 {
    var kept: std.StringHashMapUnmanaged(void) = .empty;
    for (new) |entry| try kept.put(arena, entry.path, {});
    var removed: u32 = 0;
    for (old) |entry| {
        if (kept.contains(entry.path) or !isContained(entry.path)) continue;
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir, entry.path });
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_stale_bytes)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        if (hash(bytes) != entry.hash) continue;
        Io.Dir.cwd().deleteFile(io, path) catch continue;
        removed += 1;
        // The directories the file was in, innermost first, while each is
        // empty; `deleteDir` refuses a non-empty one, which ends the walk.
        var dir = entry.path;
        while (std.mem.lastIndexOfScalar(u8, dir, '/')) |slash| {
            dir = dir[0..slash];
            const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir, dir });
            Io.Dir.cwd().deleteDir(io, full) catch break;
        }
    }
    return removed;
}

const testing = std.testing;

test "a record path is acted on only when it stays inside the output directory" {
    try testing.expect(isContained("Main.mjs"));
    try testing.expect(isContained("_core/List.mjs"));
    try testing.expect(!isContained(""));
    try testing.expect(!isContained("/etc/passwd"));
    try testing.expect(!isContained("../x.mjs"));
    try testing.expect(!isContained("a/../../x.mjs"));
    try testing.expect(!isContained("a//b.mjs"));
    try testing.expect(!isContained("./a.mjs"));
    try testing.expect(!isContained("a\\..\\b.mjs"));
    try testing.expect(!isContained(file_name));
}
