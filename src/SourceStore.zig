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

pub const File = struct {
    /// Owned. As enumerated: the argument path joined with what the walk
    /// found under it.
    path: []const u8,
    /// Owned. `Json.Decode` for `src/Json/Decode.beni`; empty when the
    /// path is not a valid module path (see `module_path_valid`).
    module_name: []const u8,
    module_path_valid: bool,
    /// Owned; empty until `read`. Sentinel-terminated for the tokenizer.
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
};

pub const extension = ".beni";

/// The bytes column before `read`: a static empty string, never allocated.
/// Compared by pointer in `freeBytes`, because an EMPTY file also reads as
/// a zero-length slice — one that was allocated and must be freed.
pub const empty_source: [:0]const u8 = "";

pub fn deinit(store: *SourceStore, gpa: Allocator) void {
    for (store.pending.items) |p| gpa.free(p.path);
    store.pending.deinit(gpa);
    const s = store.files.slice();
    for (s.items(.path), s.items(.module_name), s.items(.bytes), s.items(.line_starts)) |p, name, b, lines| {
        gpa.free(p);
        gpa.free(name);
        freeBytes(gpa, b);
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
pub fn addPath(store: *SourceStore, gpa: Allocator, io: Io, arg: []const u8, root: ?[]const u8) AddPathError!void {
    const trimmed = trimSlashes(arg);
    const cwd = Io.Dir.cwd();
    const stat = try cwd.statFile(io, trimmed, .{});
    switch (stat.kind) {
        .directory => {
            const effective_root = if (root) |r| trimSlashes(r) else trimmed;
            try store.walk(gpa, io, trimmed, effective_root);
        },
        else => {
            if (!std.mem.endsWith(u8, trimmed, extension)) return error.NotABeniFile;
            const rel_start: ?u32 = if (root) |r|
                relStart(trimmed, trimSlashes(r))
            else if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |slash|
                @intCast(slash + 1)
            else
                0;
            try store.addPending(gpa, trimmed, rel_start);
        },
    }
}

fn trimSlashes(p: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, p, "/");
    return if (t.len == 0 and p.len > 0) p[0..1] else t;
}

/// Offset in `p` after `root/`, or null when `p` is not under `root`.
fn relStart(p: []const u8, root: []const u8) ?u32 {
    if (std.mem.eql(u8, root, ".")) return 0;
    if (p.len > root.len + 1 and std.mem.startsWith(u8, p, root) and p[root.len] == '/') {
        return @intCast(root.len + 1);
    }
    return null;
}

/// Queue one path for `finish`. Public so tests and the session can seed a
/// store without touching the filesystem.
pub fn addPending(store: *SourceStore, gpa: Allocator, p: []const u8, rel_start: ?u32) Allocator.Error!void {
    const owned = try gpa.dupe(u8, p);
    errdefer gpa.free(owned);
    try store.pending.append(gpa, .{ .path = owned, .rel_start = rel_start });
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
fn walk(store: *SourceStore, gpa: Allocator, io: Io, dir_path: []const u8, root: []const u8) AddPathError!void {
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
        const child = try std.fs.path.join(gpa, &.{ dir_path, e.name });
        defer gpa.free(child);
        switch (e.kind) {
            .directory => try store.walk(gpa, io, child, root),
            else => try store.addPending(gpa, child, relStart(child, root)),
        }
    }
}

/// Sort and deduplicate the pending paths, derive module names, and assign
/// indices. After this, `count()` files exist and `pending` is empty.
pub fn finish(store: *SourceStore, gpa: Allocator) Allocator.Error!void {
    std.mem.sort(Pending, store.pending.items, {}, struct {
        fn lessThan(_: void, a: Pending, b: Pending) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
    try store.files.ensureUnusedCapacity(gpa, store.pending.items.len);
    var previous: ?[]const u8 = null;
    for (store.pending.items) |*p| {
        if (previous) |prev| if (std.mem.eql(u8, prev, p.path)) {
            gpa.free(p.path);
            p.path = &.{};
            continue;
        };
        previous = p.path;
        const derived: ModuleName = if (p.rel_start) |start|
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
            .bytes = empty_source,
            .line_starts = &.{},
        });
        p.path = &.{}; // ownership moved
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

pub const ReadError = Io.Dir.ReadFileAllocError;

/// Read one file's bytes. Safe to call from a worker for its own index.
pub fn read(store: *SourceStore, gpa: Allocator, io: Io, index: Index) ReadError!void {
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
    try store.addPending(testing.allocator, "src/Page/Home.beni", 4);
    try store.addPending(testing.allocator, "src/Main.beni", 4);
    try store.addPending(testing.allocator, "src/Main.beni", 4);
    try store.addPending(testing.allocator, "src/bad name.beni", 4);
    try store.addPending(testing.allocator, "elsewhere/X.beni", null);
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
}
