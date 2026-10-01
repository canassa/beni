//! `zig build beni-fmt-check`, part of `gates` (`docs/design/frontend.md`
//! §11.6, `language.md` §12.5): every `.beni` file under `core/`,
//! `platforms/`, `bench/`, `tests/corpus/` and `tests/platforms/` must be
//! what `beni fmt` writes, unless `tests/fmt-exempt.txt` names it.
//!
//!   beni-fmt-check <beni>
//!
//! Run from the repository root (the black-box test runs it from a world of
//! its own). The exemption list is one glob per line, then ` -- ` and a
//! reason; blank lines and lines that begin `--` are ignored. `**` matches
//! any run of characters, `*` any run without a `/`, everything else
//! itself, against the root-relative path. An entry fails the step when it
//! has no reason, when a glob matches no file, and when an entry naming one
//! file names a file that does not exist or is already canonical — so the
//! list cannot rot. Every other file goes to `beni fmt --check`; one it
//! would change, or cannot parse, fails the step with its path.
//!
//! The files go to the compiler in chunks, in sorted path order, so no one
//! process grows with the repository.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The directories the gate covers, relative to the root.
const roots = [_][]const u8{ "core", "platforms", "bench", "tests/corpus", "tests/platforms" };

/// Trees under the roots that are not the repository's own sources: what
/// `.gitignore` keeps out (generated projects, fetched dependencies, build
/// output). A directory whose name begins with `.` is skipped too.
const skipped_dirs = [_][]const u8{ "bench/compare/work", "bench/fiber/node_modules", "bench/fiber/out" };

const exempt_path = "tests/fmt-exempt.txt";

/// Files per `beni fmt --check` process.
const chunk_size = 400;

/// Why `beni fmt --check` refused a file.
const Why = enum { format, parse };

const Entry = struct {
    pattern: []const u8,
    line: usize,
    /// Whether the pattern holds a `*`; one that does not names one file.
    glob: bool,
    matched: bool = false,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: beni-fmt-check <beni>\n", .{});
        return 2;
    }
    const beni = args[1];

    var problems: std.ArrayList([]const u8) = .empty;

    // The exemption list.
    const list_text = Io.Dir.cwd().readFileAlloc(io, exempt_path, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    var entries: std.ArrayList(Entry) = .empty;
    var lines = std.mem.splitScalar(u8, list_text, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "--")) continue;
        const sep = std.mem.indexOf(u8, line, " -- ");
        const reason = if (sep) |s| std.mem.trim(u8, line[s + 4 ..], " \t") else "";
        if (sep == null or reason.len == 0) {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}:{d}: an exemption needs ` -- ` and a reason", .{ exempt_path, line_no }));
            continue;
        }
        const pattern = std.mem.trim(u8, line[0..sep.?], " \t");
        try entries.append(arena, .{
            .pattern = pattern,
            .line = line_no,
            .glob = std.mem.indexOfScalar(u8, pattern, '*') != null,
        });
    }

    // Every `.beni` file under the roots, sorted.
    var files: std.ArrayList([]const u8) = .empty;
    for (roots) |root| try collect(arena, io, root, &files);
    std.mem.sort([]const u8, files.items, {}, lessThan);

    // Split them: a file an exemption matches is not checked, but an entry
    // naming one file is, to prove it still needs its exemption.
    var checked: std.ArrayList([]const u8) = .empty;
    for (files.items) |path| {
        var exempt = false;
        for (entries.items) |*e| if (match(e.pattern, path)) {
            e.matched = true;
            exempt = true;
        };
        if (!exempt) try checked.append(arena, path);
    }
    var single: std.ArrayList([]const u8) = .empty;
    for (entries.items) |e| {
        if (!e.matched) {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}:{d}: `{s}` {s}; delete the entry", .{
                exempt_path,
                e.line,
                e.pattern,
                if (e.glob) "matches no file" else "does not exist",
            }));
        } else if (!e.glob) try single.append(arena, e.pattern);
    }

    // `beni fmt --check` over both lists, a chunk at a time.
    var failing: std.StringHashMapUnmanaged(Why) = .empty;
    var all: std.ArrayList([]const u8) = .empty;
    try all.appendSlice(arena, checked.items);
    try all.appendSlice(arena, single.items);
    var start: usize = 0;
    while (start < all.items.len) : (start += chunk_size) {
        const chunk = all.items[start..@min(start + chunk_size, all.items.len)];
        try check(arena, io, beni, chunk, &failing);
    }

    for (checked.items) |path| if (failing.get(path)) |why| {
        try problems.append(arena, if (why == .parse)
            try std.fmt.allocPrint(arena, "{s}: does not parse; fix it, or exempt it in {s} with a reason", .{ path, exempt_path })
        else
            try std.fmt.allocPrint(arena, "{s}: not what `beni fmt` writes; run `beni fmt {s}`, or exempt it in {s} with a reason", .{ path, path, exempt_path }));
    };
    for (entries.items) |e| if (!e.glob and e.matched and !failing.contains(e.pattern)) {
        try problems.append(arena, try std.fmt.allocPrint(arena, "{s}:{d}: `{s}` is already canonical; delete the entry", .{ exempt_path, e.line, e.pattern }));
    };

    if (problems.items.len == 0) return 0;
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    const out = &writer.interface;
    for (problems.items) |p| try out.print("{s}\n", .{p});
    try out.print("beni-fmt-check: {d} problem{s} (language.md §12.5)\n", .{ problems.items.len, if (problems.items.len == 1) "" else "s" });
    try out.flush();
    return 1;
}

/// Run `beni fmt --check` on `paths` and record each that would change or
/// does not parse in `failing`, with why.
fn check(arena: Allocator, io: Io, beni: []const u8, paths: []const []const u8, failing: *std.StringHashMapUnmanaged(Why)) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ beni, "fmt", "--check", "--diagnostics=json" });
    try argv.appendSlice(arena, paths);
    const r = try std.process.run(arena, io, .{ .argv = argv.items });
    const code: u8 = switch (r.term) {
        .exited => |c| c,
        else => 255,
    };
    // `--check` prints the path of each file it would change, as given.
    var out_lines = std.mem.tokenizeScalar(u8, r.stdout, '\n');
    while (out_lines.next()) |line| try failing.put(arena, try arena.dupe(u8, line), .format);
    // A file it cannot format is an error diagnostic naming it.
    const stderr = std.mem.trim(u8, r.stderr, " \t\r\n");
    if (stderr.len != 0) {
        const Diag = struct { severity: []const u8, span: struct { file: []const u8 } };
        const diags = std.json.parseFromSliceLeaky([]const Diag, arena, stderr, .{ .ignore_unknown_fields = true }) catch {
            std.debug.print("beni-fmt-check: `beni fmt --check` wrote what is not a diagnostic list:\n{s}\n", .{r.stderr});
            return error.UnexpectedOutput;
        };
        for (diags) |d| if (std.mem.eql(u8, d.severity, "error")) try failing.put(arena, d.span.file, .parse);
    }
    if (code > 1 or (code == 1 and failing.count() == 0)) {
        std.debug.print("beni-fmt-check: `beni fmt --check` exited {d}:\n{s}\n", .{ code, r.stderr });
        return error.UnexpectedExit;
    }
}

/// Append the `.beni` files under `dir_path` (root-relative) to `files`.
fn collect(arena: Allocator, io: Io, dir_path: []const u8, files: *std.ArrayList([]const u8)) !void {
    for (skipped_dirs) |s| if (std.mem.eql(u8, s, dir_path)) return;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.name });
        switch (entry.kind) {
            .directory => try collect(arena, io, path, files),
            .file => if (std.mem.endsWith(u8, entry.name, ".beni")) try files.append(arena, path),
            else => {},
        }
    }
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Whether `path` matches `pattern`: `**` any run of characters, `*` any
/// run without a `/`, every other byte itself.
fn match(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return path.len == 0;
    if (pattern[0] == '*') {
        const double = pattern.len > 1 and pattern[1] == '*';
        const rest = pattern[if (double) 2 else 1..];
        var i: usize = 0;
        while (true) : (i += 1) {
            if (match(rest, path[i..])) return true;
            if (i == path.len or (!double and path[i] == '/')) return false;
        }
    }
    return path.len != 0 and path[0] == pattern[0] and match(pattern[1..], path[1..]);
}
