//! The cache directory (docs/design/fast-compiler.md §8, *The persistent
//! cache, and its key*; `frontend.md` §1 for the two flags).
//!
//! `--cache-dir=<path>`, and **there is no default: in M4-1 the cache is
//! opt-in**. A cache that is on by default must be right about every input,
//! and the fixtures that establish that are this slice's product rather than
//! its premise. It becomes the default in M4-3.
//!
//! Inside it, one file per module, **content-addressed by the key**:
//! `<dir>/v<n>/<key[0..2]>/<key[2..32]>.bec`, two levels so no directory
//! holds 100 000 entries. *Rejected: one entry per module path, overwritten —
//! two builds of one project with different options then fight over one file,
//! and a stale entry becomes a wrong answer instead of an unreferenced one.*
//!
//! **Writing is a plain `create` + one sequential write, with no temp file,
//! no `rename` and no locks** (`plans/m4-2.md` §6 B, measured: 26.1 → 12.9 ms
//! serial for 633 entries on btrfs, 15.9 → 7.0 ms on eight workers). Two
//! processes that compute the same key write IDENTICAL bytes, so any
//! interleaving is still the right bytes; two that compute different keys
//! never touch one file. *Rejected: keeping `rename` — 13 ms of a cold build
//! to buy an atomicity a content-addressed name already provides, and the
//! argument this file's header used to make for it was about not wedging the
//! next build, which a plain create does not do either. Rejected: a lockfile,
//! for the same reason it always was.*
//!
//! **Four conditions make that safe, and each is a property something else
//! enforces.** (1) One `create` and ONE sequential write of ONE buffer — no
//! seek, no sparse region — and the header carries the file's total length,
//! which the reader checks FIRST, so every prefix a concurrent reader can
//! observe is a miss (`frontend/artifact_bytes.zig`'s header states the
//! invariant; `cache/entry_bytes.zig` is covered by its section-table
//! bounds). (2) The file is opened with TRUNCATE and not `O_EXCL`, so a
//! stale partial file from a crashed process is overwritten by the next
//! miss rather than being believed forever — which is what makes the
//! failure self-healing and what the "corrupt → miss → overwritten" fixtures
//! demand. (3) Two writers of one name write the same bytes, so a reader
//! racing them cannot see a mixture that is not that file. (4) A
//! content-hash name guards IDENTITY and not integrity, so the front-end
//! artifact carries a SipHash over its own body; a same-length file with
//! flipped bits is refused by that and not by the name.
//!
//! **No garbage collection in M4-1** and no size cap: entries accumulate at
//! ~2 kB per checked module per distinct key, and the remedy is deleting the
//! directory, which is always safe.
//!
//! **A cache never changes an answer and never fails a build.** The directory
//! is created if it is missing and a failure to create THAT is `2` with the
//! path named, like `--out`'s — which is why `open` returns an error and the
//! command owns the message. After that, every per-entry read or write
//! failure is silent: a read-only directory, a full disk, a lost race, a
//! corrupt file. The run then produces byte-identical output to one with no
//! cache at all, and `--self-profile`'s counters are where a cache that is
//! doing nothing says so.
//!
//! The version directory and the two-level fan-out are created lazily, by the
//! writer, and a failure to create either is one of those silent ones —
//! **not** the exit-2 case. That is what makes "a read-only cache directory
//! that already exists" an ordinary run producing no entries rather than a
//! usage error.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Cli = @import("../Cli.zig");
const Key = @import("Key.zig");

const Dir = @This();

/// Bumped when the layout or the entry format changes. Entries written by an
/// older layout are then unreachable rather than misread, and deleting the
/// directory is the only cleanup there has ever been.
pub const layout_version: u32 = 1;

/// Largest entry this reads. An entry is ~2 kB; the bound exists so a file
/// somebody else put in the directory cannot be read into memory whole.
pub const max_entry_bytes = 64 * 1024 * 1024;

io: Io,
/// The directory `--cache-dir` named, open. Owned.
handle: Io.Dir,
/// The path as the user spelled it, for a message. Borrowed from the CLI.
path: []const u8,

pub const OpenError = error{
    /// The directory could not be created or opened. The caller exits 2 with
    /// the path named; `err` says why.
    CachePath,
};

pub const Failure = struct { path: []const u8, err: anyerror };

/// Create `path` if it is missing and open it.
///
/// This is the ONE failure a cache is allowed to have, and it is a usage
/// failure rather than a cache one: a person who named a cache directory
/// meant it, and silently ignoring a typo would make every later build
/// mysteriously slow. `--cache-dir` naming an existing regular FILE lands
/// here too, because opening it as a directory fails.
pub fn open(io: Io, path: []const u8, failure: *?Failure) OpenError!Dir {
    Io.Dir.cwd().createDirPath(io, path) catch |err| {
        failure.* = .{ .path = path, .err = err };
        return error.CachePath;
    };
    const handle = Io.Dir.cwd().openDir(io, path, .{}) catch |err| {
        failure.* = .{ .path = path, .err = err };
        return error.CachePath;
    };
    return .{ .io = io, .handle = handle, .path = path };
}

/// The cache a `check` or a `build` was asked for, or null.
///
/// `--no-cache` wins over `--cache-dir` and produces the same null a run
/// with neither produces, so that no code below can behave differently for
/// "off" and "suppressed" — the flag exists before there is a default
/// precisely so a script that passes it keeps meaning "no cache" the day one
/// arrives.
pub fn fromCli(io: Io, cache: Cli.Cache, failure: *?Failure) OpenError!?Dir {
    if (cache.off) return null;
    const path = cache.dir orelse default_path;
    if (cache.dir == null) {
        // **The default, since M4-3.** `.beni-cache/` beside the invocation,
        // created on demand — and a failure to create it is NOT the exit-2
        // case that a named one is. A person who wrote `--cache-dir` meant
        // that directory and a typo must not become a mysteriously slow
        // build; a person who wrote nothing asked for a cache implicitly, and
        // a read-only working directory, a full disk or a sandbox must degrade
        // to no cache at all. **Silently**: stderr is byte-compared across the
        // whole corpus (`fast-compiler.md` §10), so a one-line note would be a
        // diagnostic in every golden.
        var ignored: ?Failure = null;
        return open(io, path, &ignored) catch null;
    }
    return try open(io, path, failure);
}

/// Where the cache lives when no `--cache-dir` is given: **the working
/// directory**, not the manifest's and not a user-wide one.
///
/// *Rejected: XDG* — a user-wide directory needs a garbage collector and a size
/// cap, and M4-3 deliberately has neither. *Rejected: beside `beni.json`* —
/// `check` may run with no manifest at all, so the rule would have two cases.
/// The key holds no path, so one project checked from two working directories
/// gets two directories of identical entries: correct, duplicated, and the
/// cheap failure.
///
/// Deleting it is always safe and is the documented remedy, because every
/// entry is content-addressed: `rm -rf .beni-cache`.
pub const default_path = ".beni-cache";

pub fn close(d: *Dir) void {
    d.handle.close(d.io);
    d.* = undefined;
}

/// `v<n>/<key[0..2]>/<key[2..32]>.bec`, written into `buffer`.
///
/// Two levels of fan-out over the key's own hex, so no directory holds one
/// entry per module of a large project — and the name IS the key, which is
/// what makes a lookup a single `open` with no index to keep consistent.
pub const name_len = "v4294967295/".len + 2 + 1 + 30 + ".bec".len;

/// The two file kinds the directory holds, under two different keys
/// (`fast-compiler.md` §8): M4-1's cache entry under the MODULE key, and
/// M4-2's front-end artifact under the FILE key. Same fan-out, same
/// directory, same "a bad file is a MISS" posture — a file is named by one
/// key or it is not content-addressed, which is why there are two files and
/// not two independently-keyed sections of one.
pub const Kind = enum {
    entry,
    frontend,

    fn extension(k: Kind) []const u8 {
        return switch (k) {
            .entry => ".bec",
            .frontend => ".bef",
        };
    }
};

pub fn entryPath(buffer: *[name_len]u8, key: Key.Key) []const u8 {
    return filePath(buffer, .entry, key);
}

pub fn filePath(buffer: *[name_len]u8, kind: Kind, key: Key.Key) []const u8 {
    const digits = Key.hex(key);
    return std.fmt.bufPrint(buffer, "v{d}/{s}/{s}{s}", .{
        layout_version,
        digits[0..2],
        digits[2..],
        kind.extension(),
    }) catch unreachable; // `name_len` is the bound
}

/// Write `bytes` as the entry for `key`. Every failure is silent — the run
/// must be byte-identical to one with no cache — and the return says whether
/// anything was written, for the counter.
pub fn store(d: *const Dir, key: Key.Key, bytes: []const u8) bool {
    return d.write(.entry, key, bytes);
}

/// Write `bytes` as the front-end artifact for `key`, from the WORKER that
/// produced it (`plans/m4-2.md` §6 A). Silent on failure, like `store`.
pub fn storeFrontend(d: *const Dir, key: Key.Key, bytes: []const u8) bool {
    return d.write(.frontend, key, bytes);
}

/// One `create` with TRUNCATE, one sequential `writeStreamingAll` of one
/// buffer. See this file's header for the four conditions that make the
/// missing `rename` safe.
///
/// The fan-out directory is created only when the write says it is missing,
/// which is once per two-hex-digit bucket per run rather than once per file:
/// `createFileAtomic`'s `make_path` used to pay that on every entry.
fn write(d: *const Dir, kind: Kind, key: Key.Key, bytes: []const u8) bool {
    var buffer: [name_len]u8 = undefined;
    const p = filePath(&buffer, kind, key);
    var file = d.handle.createFile(d.io, p, .{}) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const slash = std.mem.lastIndexOfScalar(u8, p, '/') orelse return false;
            d.handle.createDirPath(d.io, p[0..slash]) catch return false;
            break :blk d.handle.createFile(d.io, p, .{}) catch return false;
        },
        else => return false,
    };
    defer file.close(d.io);
    file.writeStreamingAll(d.io, bytes) catch return false;
    return true;
}

/// The entry for `key`, or null. The caller owns the bytes.
///
/// A missing file, an unreadable one and one too large to be an entry are
/// all null: a stale cache must be indistinguishable from a cold build, so
/// none of them is a diagnostic and none is an exit code.
pub fn load(d: *const Dir, gpa: Allocator, key: Key.Key) ?[]u8 {
    var buffer: [name_len]u8 = undefined;
    const p = filePath(&buffer, .entry, key);
    return d.handle.readFileAlloc(d.io, p, gpa, .limited(max_entry_bytes)) catch null;
}

/// The front-end artifact for `key`, read into `scratch.*` and returned as a
/// slice of it, or null.
///
/// **`open` + `read` into a REUSED buffer, not `readFileAlloc` and not
/// `mmap`** (`plans/m4-2.md` §4, measured on btrfs over 633 files at 13 kB):
/// a read into a reused buffer is 2.23 ms, `readFileAlloc` into an arena is
/// 5.76, and `open`+`mmap`+`munmap` is 4.99 whether the loader touches one
/// byte or every page — so what an `mmap` costs at this granularity is the
/// syscall pair and not the paging. One mapping over MANY entries is the
/// shape that wins, and that is the pack file, which is M4-4's.
///
/// `scratch` is the worker's own buffer and grows to the largest artifact
/// that worker has read; `gpa` owns it and the caller frees it once.
pub fn loadFrontend(d: *const Dir, gpa: Allocator, scratch: *std.ArrayList(u8), key: Key.Key) ?[]const u8 {
    var buffer: [name_len]u8 = undefined;
    const p = filePath(&buffer, .frontend, key);
    var file = d.handle.openFile(d.io, p, .{}) catch return null;
    defer file.close(d.io);
    const info = file.stat(d.io) catch return null;
    if (info.size == 0 or info.size > max_entry_bytes) return null;
    const size: usize = @intCast(info.size);
    scratch.clearRetainingCapacity();
    scratch.ensureTotalCapacity(gpa, size) catch return null;
    scratch.items.len = size;
    var filled: usize = 0;
    while (filled < size) {
        // A short read is not a failure — it is what a reader racing a
        // writer sees — so the loop keeps going until the file is exhausted,
        // and a file that ended early is a MISS through the header's
        // `total_len` rather than an error here.
        const n = file.readStreaming(d.io, &.{scratch.items[filled..]}) catch break;
        if (n == 0) break;
        filled += n;
    }
    scratch.items.len = filled;
    return scratch.items;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "an entry path is the key, fanned out two levels" {
    var buffer: [name_len]u8 = undefined;
    const key: Key.Key = .{ 0xAB, 0xCD, 0xEF, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 };
    try testing.expectEqualStrings(
        "v1/ab/cdef0102030405060708090a0b0c0d.bec",
        entryPath(&buffer, key),
    );
    // The name is the whole key and nothing else: 32 hex digits split 2/30.
    const path = entryPath(&buffer, key);
    const slash = std.mem.lastIndexOfScalar(u8, path, '/').?;
    try testing.expectEqual(@as(usize, 30 + ".bec".len), path.len - slash - 1);
}

test "a key of all zeroes and a key of all ones both name a file" {
    // The two keys most likely to be produced by a bug, and the two a path
    // builder is most likely to get wrong.
    var buffer: [name_len]u8 = undefined;
    try testing.expectEqualStrings("v1/00/" ++ "0" ** 30 ++ ".bec", entryPath(&buffer, @splat(0)));
    try testing.expectEqualStrings("v1/ff/" ++ "f" ** 30 ++ ".bec", entryPath(&buffer, @splat(0xFF)));
}
