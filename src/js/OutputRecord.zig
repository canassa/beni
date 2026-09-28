//! The record of what a build wrote into `--out`, and the removal of what
//! an earlier build wrote there and this one did not (`backend.md` §2, *The
//! output directory holds what the last build wrote, and nothing it wrote
//! before*; CK-163).
//!
//! The record is `_manifest.txt` at the root of `--out`: a first line
//! `beni-manifest 1`, then `<hash> <path>` per file, the hash the 64-bit
//! Wyhash of the bytes written as 16 lower-case hex digits. Everything here
//! errs toward leaving a file where it is: a path that could leave `--out`,
//! bytes that are no longer what beni wrote, or a path that is, on this file
//! system, the same file as one this build writes (CK-191: `Ab.mjs` and
//! `AB.mjs` on APFS) all mean "not beni's to delete". And a `_manifest.txt` that is not in this format at all is not
//! beni's to overwrite (CK-192): `read` says so, and the build is refused.

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

/// What `--out` held under the record's name before this build.
pub const Previous = union(enum) {
    /// No `_manifest.txt`: a first build, or an `--out` that does not exist.
    none,
    /// beni's record: the entries it lists that stay inside `--out`.
    record: []const Entry,
    /// A file of that name that is not beni's record — the header is not
    /// `beni-manifest 1`, a line is not `<16 hex digits> <path>`, or it
    /// cannot be read at all. Somebody else's file, which a build must
    /// neither overwrite nor act on (CK-192).
    unrecognised,
};

/// Read the previous build's record. Paths point into `arena`.
///
/// **Strict** since CK-192: every line after the header must have the
/// record's shape, and the last may only be the empty one after the final
/// newline, or the file is not beni's. A well-formed line whose path would
/// leave `--out` is still skipped rather than refused: it is beni's format,
/// edited by somebody, and acting on it is the one thing that is ruled out.
pub fn read(arena: Allocator, io: Io, out_dir: []const u8) Allocator.Error!Previous {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir, file_name });
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_stale_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound, error.NotDir => return .none,
        else => return .unrecognised,
    };
    return parse(arena, text);
}

/// `read`'s parse of a record's text, apart so that it is testable without
/// a file system.
pub fn parse(arena: Allocator, text: []const u8) Allocator.Error!Previous {
    if (!std.mem.endsWith(u8, text, "\n")) return .unrecognised;
    var lines = std.mem.splitScalar(u8, text[0 .. text.len - 1], '\n');
    if (!std.mem.eql(u8, lines.first(), header)) return .unrecognised;
    var out: std.ArrayList(Entry) = .empty;
    while (lines.next()) |line| {
        if (line.len < 18 or line[16] != ' ') return .unrecognised;
        const h = std.fmt.parseInt(u64, line[0..16], 16) catch return .unrecognised;
        const p = line[17..];
        if (!isContained(p)) continue;
        try out.append(arena, .{ .hash = h, .path = p });
    }
    return .{ .record = out.items };
}

/// `path` with ASCII letters lower-cased: the key two paths share when they
/// are one file on APFS and NTFS. The same folding `output_path_collision`
/// uses (`Emit.checkOutputPaths`), and for the same reason no other: module
/// path segments and the compiler's reserved names are ASCII.
fn fold(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    const key = try arena.dupe(u8, path);
    for (key) |*c| c.* = std.ascii.toLower(c.*);
    return key;
}

/// Which of `old`'s paths `removeStale` may consider: not written by this
/// build byte for byte (`.written`), and — when this build writes a path
/// equal to it under case folding — which one (`.folds_onto`), so the
/// caller can ask the file system whether the two names are one file.
pub const Verdict = union(enum) {
    written,
    folds_onto: []const u8,
    stale,
};

/// A lookup of the new build's paths, exact and folded (CK-191).
pub const Written = struct {
    exact: std.StringHashMapUnmanaged(void) = .empty,
    folded: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn init(arena: Allocator, new: []const Entry) Allocator.Error!Written {
        var w: Written = .{};
        for (new) |entry| {
            try w.exact.put(arena, entry.path, {});
            try w.folded.put(arena, try fold(arena, entry.path), entry.path);
        }
        return w;
    }

    pub fn judge(w: *const Written, arena: Allocator, path: []const u8) Allocator.Error!Verdict {
        if (w.exact.contains(path)) return .written;
        if (w.folded.get(try fold(arena, path))) |other| return .{ .folds_onto = other };
        return .stale;
    }
};

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
///
/// **A stale path equal to a written one under ASCII case folding** is
/// removed only when the file system says the two names are two files
/// (CK-191). `Ab.mjs` from the last build and `AB.mjs` from this one are
/// one file on APFS and NTFS, and there a byte-for-byte comparison read the
/// file just written, found the old hash when the bytes happened to agree,
/// and deleted it. On a case-sensitive file system they are two, and the
/// older is stale like any other — so `--out` still matches a fresh build.
/// A name that cannot be stat'd stays: not knowing is "not beni's to
/// delete".
pub fn removeStale(arena: Allocator, io: Io, out_dir: []const u8, old: []const Entry, new: []const Entry) Allocator.Error!u32 {
    const written: Written = try .init(arena, new);
    var removed: u32 = 0;
    for (old) |entry| {
        if (!isContained(entry.path)) continue;
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir, entry.path });
        switch (try written.judge(arena, entry.path)) {
            .written => continue,
            .stale => {},
            .folds_onto => |other| {
                const other_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir, other });
                const a = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
                const b = Io.Dir.cwd().statFile(io, other_path, .{}) catch continue;
                if (a.inode == b.inode) continue;
            },
        }
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

test "only beni's own format parses as a record (CK-192)" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const good = try parse(a, header ++ "\n00000000000000ff Main.mjs\n0000000000000001 ../out.mjs\n");
    try testing.expectEqual(@as(usize, 1), good.record.len);
    try testing.expectEqual(@as(u64, 0xff), good.record[0].hash);
    try testing.expectEqualStrings("Main.mjs", good.record[0].path);
    try testing.expectEqual(@as(usize, 0), (try parse(a, header ++ "\n")).record.len);
    for ([_][]const u8{
        "",
        "my own notes\n",
        header,
        "beni-manifest 2\n",
        header ++ "\nnot a line\n",
        header ++ "\n\n",
        header ++ "\n00000000000000zz Main.mjs\n",
        header ++ "\n00000000000000ff Main.mjs",
    }) |text| try testing.expectEqual(Previous.unrecognised, try parse(a, text));
}

test "a stale path is compared with the written ones exactly, then under ASCII case folding (CK-191)" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const new = [_]Entry{ .{ .hash = 1, .path = "AB.mjs" }, .{ .hash = 3, .path = "_core/List.mjs" } };
    const w: Written = try .init(a, &new);
    try testing.expectEqual(Verdict.written, try w.judge(a, "AB.mjs"));
    try testing.expectEqual(Verdict.written, try w.judge(a, "_core/List.mjs"));
    try testing.expectEqualStrings("AB.mjs", (try w.judge(a, "Ab.mjs")).folds_onto);
    try testing.expectEqualStrings("AB.mjs", (try w.judge(a, "ab.mjs")).folds_onto);
    try testing.expectEqualStrings("_core/List.mjs", (try w.judge(a, "_CORE/list.MJS")).folds_onto);
    try testing.expectEqual(Verdict.stale, try w.judge(a, "Gone.mjs"));
}
