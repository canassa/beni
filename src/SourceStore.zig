//! Source files by index (docs/design/frontend.md §3.1, language.md §1).
//!
//! Enumeration is the ONE serial, deterministic step that every later
//! structure is keyed by: paths are collected, sorted, deduplicated and only
//! then numbered, so file index `i` means the same file for every `--jobs`
//! value and every run (frontend.md §1). Everything a file has — its path,
//! its module name, its bytes with a sentinel so the tokenizer needs no
//! bounds check at EOF, and its line-start table — lives in one
//! `MultiArrayList` column set addressed by that index. No slice into a
//! file escapes this struct except the bytes themselves.
//!
//! Reading is per file and may run on a worker: `read(index)` writes only
//! that file's columns, so workers on disjoint indices never race.
//!
//! A file also has a PACKAGE (checker.md §4.1): a module's identity is
//! `(package, module name)`, not its name alone, so two packages may each
//! have a `List` and an importer's own package is searched first. M2 has
//! exactly two — the user's `app` and the embedded `core` — but nothing
//! here assumes that. The core package's bytes are usually `@embedFile`d
//! into the binary rather than read, which is what `File.embedded` marks;
//! `--core-root` reads them from disk instead and they are ordinary files
//! of package `core`.
//!
//! One rule joins the two: **an enumerated `app` file at a `core` file's
//! path IS that core module.** `beni check core` from the repo root walks
//! `core/` as app modules and would otherwise compile the standard library
//! twice — once as `app.Basics`, once as `core.Basics` — with `foreign`
//! illegal in the first. Instead the path is the identity, the on-disk
//! bytes win over the embedded ones, and checking core is spelled the same
//! way as checking anything else. The cost is that `core/` is a reserved
//! directory name at the source root; the benefit is that developing core
//! needs no flag.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const SourceStore = @This();

/// Paths given to `addPath` and found under directories, with the byte
/// offset of the part relative to their root, until `finish` numbers them.
pending: std.ArrayList(Pending) = .empty,
/// Numbered files. Empty until `finish`.
files: std.MultiArrayList(File) = .empty,

pub const Index = enum(u32) {
    _,

    pub fn int(i: Index) u32 {
        return @intFromEnum(i);
    }
};

/// Which package a file belongs to (checker.md §4.1, fast-compiler.md
/// §3.1 "Project model"). Declaration order is the search order: an import
/// resolves in the importing module's own package first, then `core`.
/// Dependencies as packages are M4; the column exists now so M4 needs no
/// retrofit.
/// `platform` is a package whose manifest says `"platform": true`
/// (`docs/design/boundary.md` §2): it may write `foreign`, it owns the
/// `Program` type and `main`'s shape, and anyone may publish one. It sits
/// above `core` in this enum because the dedup in `finish` keeps the
/// strongest package for a path and a platform's own copy of a file must
/// win over an app's view of it.
pub const Package = enum(u8) { app, core, platform };

pub const File = struct {
    /// Owned. As enumerated: the argument path joined with what the walk
    /// found under it.
    path: []const u8,
    /// Owned. `Json.Decode` for `src/Json/Decode.beni`; empty when the
    /// path is not a valid module path (see `module_path_valid`).
    module_name: []const u8,
    module_path_valid: bool,
    package: Package,
    /// The bytes are `@embedFile`d into the binary and must not be read or
    /// freed. Only ever true for `core` files.
    embedded: bool,
    /// Owned unless `embedded`; empty until `read`. Sentinel-terminated for
    /// the tokenizer.
    bytes: [:0]const u8,
    /// Owned; empty until the lexer fills it through `setLineStarts`.
    /// `line_starts[l]` is the byte offset of 0-based line `l`; `[0]` is 0.
    line_starts: []const u32,
};

const Pending = struct {
    path: []u8,
    /// Where the module-relative part of `path` begins, or `null` when the
    /// path does not lie under its root.
    rel_start: ?u32,
    package: Package,
    /// Embedded bytes, for a `core` file compiled into the binary.
    source: ?[:0]const u8,
};

pub const extension = ".beni";

/// The most bytes an argument path may have. A longer one could not be
/// opened anyway (`NameTooLong` is what the OS would say), and this is the
/// size of the buffer `normalize` works in.
pub const max_path_bytes = std.fs.max_path_bytes;

/// The bytes column before `read`: a static empty string, never allocated.
/// Compared by pointer in `freeBytes`, because an EMPTY file also reads as
/// a zero-length slice — one that was allocated and must be freed.
pub const empty_source: [:0]const u8 = "";

pub fn deinit(store: *SourceStore, gpa: Allocator) void {
    for (store.pending.items) |p| gpa.free(p.path);
    store.pending.deinit(gpa);
    const s = store.files.slice();
    for (s.items(.path), s.items(.module_name), s.items(.bytes), s.items(.embedded), s.items(.line_starts)) |p, name, b, embedded, lines| {
        gpa.free(p);
        gpa.free(name);
        if (!embedded) freeBytes(gpa, b);
        gpa.free(lines);
    }
    store.files.deinit(gpa);
    store.* = undefined;
}

pub fn count(store: *const SourceStore) u32 {
    return @intCast(store.files.len);
}

pub fn path(store: *const SourceStore, index: Index) []const u8 {
    return store.files.items(.path)[index.int()];
}

pub fn moduleName(store: *const SourceStore, index: Index) []const u8 {
    return store.files.items(.module_name)[index.int()];
}

pub fn modulePathValid(store: *const SourceStore, index: Index) bool {
    return store.files.items(.module_path_valid)[index.int()];
}

pub fn package(store: *const SourceStore, index: Index) Package {
    return store.files.items(.package)[index.int()];
}

/// Every file's package, in index order — for the phases that decide by
/// package without touching the rest of the column set.
pub fn packages(store: *const SourceStore) []const Package {
    return store.files.items(.package);
}

/// Whether the file's bytes came from the binary rather than from disk: a
/// core or platform module that was never walked, so its path names nothing
/// under the directory the user pointed at.
pub fn isEmbedded(store: *const SourceStore, index: Index) bool {
    return store.files.items(.embedded)[index.int()];
}

pub fn bytes(store: *const SourceStore, index: Index) [:0]const u8 {
    return store.files.items(.bytes)[index.int()];
}

pub fn lineStarts(store: *const SourceStore, index: Index) []const u32 {
    return store.files.items(.line_starts)[index.int()];
}

/// Every path, in index order (sorted). For the profile writer and the
/// renderer's lookup.
pub fn paths(store: *const SourceStore) []const []const u8 {
    return store.files.items(.path);
}

/// The index of `file_path`, by binary search over the sorted paths.
pub fn find(store: *const SourceStore, file_path: []const u8) ?Index {
    const i = std.sort.binarySearch([]const u8, store.paths(), file_path, comparePath) orelse return null;
    return @enumFromInt(i);
}

fn comparePath(target: []const u8, item: []const u8) std.math.Order {
    return std.mem.order(u8, target, item);
}

pub const AddPathError = Allocator.Error || Io.Dir.StatFileError || Io.Dir.OpenError || Io.Dir.Reader.Error || error{
    /// A `.beni` file was expected: the path is neither a directory nor a
    /// file with the extension.
    NotABeniFile,
};

/// Enumerate one argument: a `.beni` file, or a directory walked recursively
/// (hidden entries skipped). `root`, when given, is the `--root` the module
/// name is relative to; otherwise the directory itself, or the file's own
/// directory (frontend.md §1). Nothing is numbered until `finish`.
///
/// The argument and the root are normalised LEXICALLY first (`normalize`),
/// and every path the walk builds under them is normalised by construction,
/// so `.` is a usable path: `beni check .` walks `.`, finds `Aa.beni` rather
/// than `./Aa.beni`, and names the module `Aa`.
pub fn addPath(store: *SourceStore, gpa: Allocator, io: Io, arg: []const u8, root: ?[]const u8, pkg: Package) AddPathError!void {
    var arg_buffer: [max_path_bytes]u8 = undefined;
    var root_buffer: [max_path_bytes]u8 = undefined;
    if (arg.len > arg_buffer.len) return error.NameTooLong;
    const trimmed = normalize(&arg_buffer, arg);
    const normalized_root: ?[]const u8 = if (root) |r| blk: {
        if (r.len > root_buffer.len) return error.NameTooLong;
        break :blk normalize(&root_buffer, r);
    } else null;
    const cwd = Io.Dir.cwd();
    const stat = try cwd.statFile(io, trimmed, .{});
    switch (stat.kind) {
        .directory => {
            const effective_root = normalized_root orelse trimmed;
            try store.walk(gpa, io, trimmed, effective_root, pkg);
        },
        else => {
            if (!std.mem.endsWith(u8, trimmed, extension)) return error.NotABeniFile;
            const rel_start: ?u32 = if (normalized_root) |r|
                relStart(trimmed, r)
            else if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |slash|
                @intCast(slash + 1)
            else
                0;
            try store.addPending(gpa, trimmed, rel_start, pkg);
        },
    }
}

/// Normalise `p` into `buf` (which must hold `@max(p.len, 1)` bytes) and
/// return the slice of it that holds the result: empty segments and `.`
/// segments are dropped, so `./Aa.beni`, `.//Aa.beni` and `./sub/../Aa.beni`
/// become `Aa.beni`, `sub/../Aa.beni`, and a trailing slash is trimmed.
/// A path that normalises to nothing is `.` (`/` if it was absolute).
///
/// **Lexical only, and `..` is never resolved.** Collapsing `a/../b` to `b`
/// is wrong the moment `a` is a symlink, and resolving the path for real
/// (`realpath`) would put an absolute path into every diagnostic where the
/// user typed a relative one. So `..` is left exactly as written: the path
/// still names the file the shell would name, and a `..` that survives into
/// the part BELOW the source root is not a module name — it fails
/// `isUpperIdent` and the file is `invalid_module_path`, which is the honest
/// answer for `--root=src src/../src/A.beni`.
pub fn normalize(buf: []u8, p: []const u8) []const u8 {
    const absolute = p.len != 0 and p[0] == '/';
    var len: usize = 0;
    if (absolute) {
        buf[0] = '/';
        len = 1;
    }
    var segments = std.mem.splitScalar(u8, p, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (len > @intFromBool(absolute)) {
            buf[len] = '/';
            len += 1;
        }
        @memcpy(buf[len..][0..segment.len], segment);
        len += segment.len;
    }
    if (len == 0) {
        buf[0] = '.';
        return buf[0..1];
    }
    return buf[0..len];
}

/// Offset in `p` after `root/`, or null when `p` is not under `root`. Both
/// are normalised, so this is a prefix test and nothing more.
fn relStart(p: []const u8, root: []const u8) ?u32 {
    if (std.mem.eql(u8, root, ".")) return 0;
    if (std.mem.eql(u8, root, "/")) return 1;
    if (p.len > root.len + 1 and std.mem.startsWith(u8, p, root) and p[root.len] == '/') {
        return @intCast(root.len + 1);
    }
    return null;
}

/// Queue one path for `finish`. Public so tests and the session can seed a
/// store without touching the filesystem.
pub fn addPending(store: *SourceStore, gpa: Allocator, p: []const u8, rel_start: ?u32, pkg: Package) Allocator.Error!void {
    try store.addPendingSource(gpa, p, rel_start, pkg, null);
}

/// Queue a file whose bytes are already in memory: the embedded core
/// package (checker.md §3), or a module a test writes rather than a file.
/// `source` must outlive the store — it is `@embedFile` data in the
/// binary's rodata, or a string literal — and is never freed.
pub fn addEmbedded(store: *SourceStore, gpa: Allocator, p: []const u8, rel_start: ?u32, pkg: Package, source: [:0]const u8) Allocator.Error!void {
    try store.addPendingSource(gpa, p, rel_start, pkg, source);
}

fn addPendingSource(store: *SourceStore, gpa: Allocator, p: []const u8, rel_start: ?u32, pkg: Package, source: ?[:0]const u8) Allocator.Error!void {
    const owned = try gpa.dupe(u8, p);
    errdefer gpa.free(owned);
    try store.pending.append(gpa, .{ .path = owned, .rel_start = rel_start, .package = pkg, .source = source });
}

/// Recursive walk in sorted entry order, skipping `.`-prefixed entries and
/// every symlink. The order does not affect numbering (`finish` sorts
/// globally) but keeps the directory reads themselves deterministic.
///
/// **The walk never follows a symlink.** A single `dir/loop -> ..` makes the
/// tree infinite, and following it either never terminates or — what beni
/// did before this rule — dies with the OS's `SymLinkLoop` on a path the
/// user never wrote, failing the whole run with exit 2 because of one link
/// somewhere in the tree. Cycle *detection* (a device/inode set) would cost
/// a stat per entry and a growing set for the one case in a thousand where
/// a symlinked directory is wanted; skipping is O(1), needs no state, and
/// has an obvious escape hatch — name the target on the command line, where
/// an argument path IS followed (`addPath` stats with the default
/// `follow_symlinks`). Symlinked *files* are skipped by the same rule, so
/// "the walk does not follow symlinks" is one sentence rather than two.
fn walk(store: *SourceStore, gpa: Allocator, io: Io, dir_path: []const u8, root: []const u8, pkg: Package) AddPathError!void {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    const Entry = struct { name: []u8, kind: Io.File.Kind };
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |e| gpa.free(e.name);
        entries.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        var kind = entry.kind;
        if (kind == .unknown) {
            // A filesystem without `d_type`. Ask, but do NOT follow: a
            // symlink must still report as one so the rule above holds.
            const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
            kind = stat.kind;
        }
        if (kind != .directory and !(kind == .file and std.mem.endsWith(u8, entry.name, extension))) continue;
        const name = try gpa.dupe(u8, entry.name);
        errdefer gpa.free(name);
        try entries.append(gpa, .{ .name = name, .kind = kind });
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    for (entries.items) |e| {
        const child = try joinEntry(gpa, dir_path, e.name);
        defer gpa.free(child);
        switch (e.kind) {
            .directory => try store.walk(gpa, io, child, root, pkg),
            else => try store.addPending(gpa, child, relStart(child, root), pkg),
        }
    }
}

/// `dir_path` (already normalised) plus one entry name, still normalised:
/// the walk never writes the `./` prefix that `std.fs.path.join` would leave
/// on a walk of `.`, because a stored path with one in it is not the path
/// relative to the root and its first segment is not a module name.
fn joinEntry(gpa: Allocator, dir_path: []const u8, name: []const u8) Allocator.Error![]u8 {
    if (std.mem.eql(u8, dir_path, ".")) return gpa.dupe(u8, name);
    const separator: []const u8 = if (std.mem.endsWith(u8, dir_path, "/")) "" else "/";
    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ dir_path, separator, name });
}

/// Sort and deduplicate the pending paths, derive module names, and assign
/// indices. After this, `count()` files exist and `pending` is empty.
///
/// The sort key is `(path, package)` rather than the path alone, so entries
/// for one path are adjacent with `app` first and `find` can still binary
/// search `paths()`. Adjacent entries with the same path collapse, and the
/// collapse is what implements the "an app file at a core path IS that core
/// module" rule of the header: the surviving entry keeps the CORE package
/// and the APP source of bytes, so the on-disk copy is what gets compiled.
pub fn finish(store: *SourceStore, gpa: Allocator) Allocator.Error!void {
    std.mem.sort(Pending, store.pending.items, {}, struct {
        fn lessThan(_: void, a: Pending, b: Pending) bool {
            return switch (std.mem.order(u8, a.path, b.path)) {
                .lt => true,
                .gt => false,
                .eq => @intFromEnum(a.package) < @intFromEnum(b.package),
            };
        }
    }.lessThan);
    try store.files.ensureUnusedCapacity(gpa, store.pending.items.len);
    var i: usize = 0;
    while (i < store.pending.items.len) {
        const p = &store.pending.items[i];
        // Fold every later entry for this path into `p`. The strongest
        // package wins (core over app) and a non-embedded source wins over
        // an embedded one, whichever order they arrived in.
        var pkg = p.package;
        var source = p.source;
        var rel_start = p.rel_start;
        var j = i + 1;
        while (j < store.pending.items.len and std.mem.eql(u8, store.pending.items[j].path, p.path)) : (j += 1) {
            const dup = &store.pending.items[j];
            if (@intFromEnum(dup.package) > @intFromEnum(pkg)) {
                pkg = dup.package;
                rel_start = dup.rel_start;
            }
            if (dup.source == null) source = null;
            gpa.free(dup.path);
            dup.path = &.{};
        }
        const derived: ModuleName = if (rel_start) |start|
            try moduleNameFromRelative(gpa, p.path[start..])
        else
            .{ .invalid_segment = p.path };
        const name: []const u8 = switch (derived) {
            .valid => |n| n,
            .invalid_segment => &.{},
        };
        store.files.appendAssumeCapacity(.{
            .path = p.path,
            .module_name = name,
            .module_path_valid = derived == .valid,
            .package = pkg,
            .embedded = source != null,
            .bytes = source orelse empty_source,
            .line_starts = &.{},
        });
        p.path = &.{}; // ownership moved
        i = j;
    }
    store.pending.clearRetainingCapacity();
}

pub const ModuleName = union(enum) {
    /// Owned by the caller.
    valid: []u8,
    /// The first path segment that is not an upper identifier (a slice of
    /// the input).
    invalid_segment: []const u8,
};

/// `Json/Decode.beni` → `Json.Decode` (language.md §1). Every segment must
/// be an upper identifier (§2.4): `[A-Z][A-Za-z0-9_]*`.
pub fn moduleNameFromRelative(gpa: Allocator, rel: []const u8) Allocator.Error!ModuleName {
    const stem = if (std.mem.endsWith(u8, rel, extension)) rel[0 .. rel.len - extension.len] else rel;
    var segments = std.mem.splitScalar(u8, stem, '/');
    while (segments.next()) |segment| {
        if (!isUpperIdent(segment)) return .{ .invalid_segment = segment };
    }
    const name = try gpa.dupe(u8, stem);
    std.mem.replaceScalar(u8, name, '/', '.');
    return .{ .valid = name };
}

fn isUpperIdent(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isUpper(s[0])) return false;
    for (s[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

/// Whether `index`'s bytes are already in the store: an embedded file, whose
/// bytes are in the binary's rodata, or one a worker has read.
///
/// M4-2 needs it because the front-end cache turns the per-file phase inside
/// out: the source has to be READ before the file key can be computed, and
/// the key decides whether the lexer runs at all — so `read` is called from
/// two places on a miss and must be idempotent between them. Comparing
/// against the `empty_source` sentinel rather than keeping a bit: the
/// sentinel is what "not read" already means here, and a second column would
/// be a second thing to keep true.
pub fn isRead(store: *const SourceStore, index: Index) bool {
    return store.files.items(.embedded)[index.int()] or
        store.files.items(.bytes)[index.int()].ptr != empty_source.ptr;
}

pub const ReadError = Io.Dir.ReadFileAllocError;

/// Read one file's bytes. Safe to call from a worker for its own index.
/// An embedded file already has its bytes and is not touched.
pub fn read(store: *SourceStore, gpa: Allocator, io: Io, index: Index) ReadError!void {
    if (store.files.items(.embedded)[index.int()]) return;
    const p = store.path(index);
    const data = try Io.Dir.cwd().readFileAllocOptions(io, p, gpa, .limited(std.math.maxInt(u32)), .of(u8), 0);
    const slot = &store.files.items(.bytes)[index.int()];
    freeBytes(gpa, slot.*);
    slot.* = data;
}

/// Free a bytes column unless it is still the `empty_source` placeholder.
fn freeBytes(gpa: Allocator, b: [:0]const u8) void {
    if (b.ptr != empty_source.ptr) gpa.free(b);
}

/// Install a line-start table for `index`, taking ownership.
pub fn setLineStarts(store: *SourceStore, gpa: Allocator, index: Index, line_starts: []const u32) void {
    const slot = &store.files.items(.line_starts)[index.int()];
    gpa.free(slot.*);
    slot.* = line_starts;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "moduleNameFromRelative accepts upper identifiers and rejects the rest" {
    const cases = [_]struct { rel: []const u8, want: ModuleName }{
        .{ .rel = "Main.beni", .want = .{ .valid = @constCast("Main") } },
        .{ .rel = "Json/Decode.beni", .want = .{ .valid = @constCast("Json.Decode") } },
        .{ .rel = "A_1/B2/C.beni", .want = .{ .valid = @constCast("A_1.B2.C") } },
        .{ .rel = "main.beni", .want = .{ .invalid_segment = "main" } },
        .{ .rel = "Json/decode.beni", .want = .{ .invalid_segment = "decode" } },
        .{ .rel = "My-Module.beni", .want = .{ .invalid_segment = "My-Module" } },
        .{ .rel = "src//Main.beni", .want = .{ .invalid_segment = "src" } },
        .{ .rel = ".beni", .want = .{ .invalid_segment = "" } },
        .{ .rel = "Über.beni", .want = .{ .invalid_segment = "Über" } },
    };
    for (cases) |case| {
        const got = try moduleNameFromRelative(testing.allocator, case.rel);
        defer if (got == .valid) testing.allocator.free(got.valid);
        try testing.expectEqualDeep(case.want, got);
    }
}

test "finish sorts, deduplicates and derives module names; find is exact" {
    var store: SourceStore = .{};
    defer store.deinit(testing.allocator);
    try store.addPending(testing.allocator, "src/Page/Home.beni", 4, .app);
    try store.addPending(testing.allocator, "src/Main.beni", 4, .app);
    try store.addPending(testing.allocator, "src/Main.beni", 4, .app);
    try store.addPending(testing.allocator, "src/bad name.beni", 4, .app);
    try store.addPending(testing.allocator, "elsewhere/X.beni", null, .app);
    try store.finish(testing.allocator);

    try testing.expectEqual(@as(u32, 4), store.count());
    try testing.expectEqualDeep(@as([]const []const u8, &.{
        "elsewhere/X.beni", "src/Main.beni", "src/Page/Home.beni", "src/bad name.beni",
    }), store.paths());
    try testing.expectEqualStrings("Main", store.moduleName(@enumFromInt(1)));
    try testing.expectEqualStrings("Page.Home", store.moduleName(@enumFromInt(2)));
    try testing.expect(!store.modulePathValid(@enumFromInt(0)));
    try testing.expect(!store.modulePathValid(@enumFromInt(3)));
    try testing.expectEqualStrings("", store.moduleName(@enumFromInt(3)));
    try testing.expectEqual(@as(?Index, @enumFromInt(2)), store.find("src/Page/Home.beni"));
    try testing.expectEqual(@as(?Index, null), store.find("src/Page"));
    try testing.expectEqual(@as(usize, 0), store.pending.items.len);
}

test "relStart" {
    try testing.expectEqual(@as(?u32, 4), relStart("src/Main.beni", "src"));
    try testing.expectEqual(@as(?u32, null), relStart("srcs/Main.beni", "src"));
    try testing.expectEqual(@as(?u32, null), relStart("Main.beni", "src"));
    try testing.expectEqual(@as(?u32, 0), relStart("Main.beni", "."));
    try testing.expectEqual(@as(?u32, 1), relStart("/Main.beni", "/"));
}

test "normalize drops `.` and empty segments and keeps everything else" {
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = ".", .want = "." },
        .{ .in = "./", .want = "." },
        .{ .in = ".//.", .want = "." },
        .{ .in = "./Aa.beni", .want = "Aa.beni" },
        .{ .in = ".//Aa.beni", .want = "Aa.beni" },
        .{ .in = "src/./Main.beni", .want = "src/Main.beni" },
        .{ .in = "src//Main.beni", .want = "src/Main.beni" },
        .{ .in = "src/", .want = "src" },
        .{ .in = "src///", .want = "src" },
        .{ .in = "/", .want = "/" },
        .{ .in = "//", .want = "/" },
        .{ .in = "/tmp/./p/Main.beni", .want = "/tmp/p/Main.beni" },
        // `..` is never resolved: the path still names what the shell names.
        .{ .in = "./sub/..", .want = "sub/.." },
        .{ .in = "../proj/Main.beni", .want = "../proj/Main.beni" },
        .{ .in = "", .want = "." },
    };
    var buffer: [max_path_bytes]u8 = undefined;
    for (cases) |case| {
        try testing.expectEqualStrings(case.want, normalize(&buffer, case.in));
    }
}

test "joinEntry writes no `./` prefix when the walk is rooted at `.`" {
    const cases = [_]struct { dir: []const u8, name: []const u8, want: []const u8 }{
        .{ .dir = ".", .name = "Aa.beni", .want = "Aa.beni" },
        .{ .dir = "src", .name = "Aa.beni", .want = "src/Aa.beni" },
        .{ .dir = "/", .name = "Aa.beni", .want = "/Aa.beni" },
        .{ .dir = "sub/..", .name = "Aa.beni", .want = "sub/../Aa.beni" },
    };
    for (cases) |case| {
        const got = try joinEntry(testing.allocator, case.dir, case.name);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(case.want, got);
    }
}
