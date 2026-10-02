//! `beni fmt [--check] [--stdout] <path>...` (docs/design/frontend.md §1,
//! language.md §9): the driver around `Format`.
//!
//! Formatting itself is a per-file worker phase (`Session.format_phases`):
//! read → tokenize → parse → format, on whichever worker took the file,
//! into a session-owned buffer in that file's `Artifacts` column. What is
//! left here is the part that must happen in a fixed order — compare the
//! canonical text with the source, then write it, print it, or list the
//! path — and it walks files in path order after the join. The
//! `--check` listing, the `--stdout` product and the bytes written are
//! therefore a function of the input alone, not of `--jobs`; the
//! determinism scenario compares all three across `--jobs=1` and `--jobs=8`.
//!
//! A file with any diagnostic — lexical or syntactic — has no canonical
//! form and is never written, printed or listed: its diagnostics are the
//! whole output for it, and the exit code is 1. The worker decides that (a
//! file's diagnostics are all known by the end of its own phase), and leaves
//! `formatted` null; here, null means skip. **A module name is not among
//! them**: formatting "is per file and resolves nothing" (`frontend.md` §1),
//! so `beni fmt notes.beni` formats a file whose path names no module
//! (`Session.format_phases` sets `module_names = false`).
//!
//! In-place writes go through `Io.Dir.createFileAtomic` + `replace`: the
//! text lands in a temporary file in the same directory and is renamed over
//! the original, so a crash or a full disk leaves either the old bytes or
//! the new ones, never a truncated module. A file whose formatted text
//! equals its source is not touched at all (its mtime stays put, which is
//! what editors and build tools watching it want). What the rename must not
//! take with it — the file's mode, and the link when the path is a symlink
//! — is `writeAtomic`'s business, at the bottom of this file.
//!
//! Exit codes: 2 for a usage or I/O failure (a path that cannot be read, a
//! file that cannot be written, `--stdout` with more than one file), 1 when
//! any file had an error or — under `--check` — would change, else 0.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Cli = @import("../Cli.zig");
const Session = @import("../Session.zig");
const SourceStore = @import("../SourceStore.zig");
const fs_read = @import("../fs_read.zig");
const diagnostic = @import("diagnostic");

/// Run the command to completion and return the process exit code.
/// `options` is the session configuration `main` derived from the common
/// flags; `fmt` carries the paths and the mode.
pub fn run(gpa: Allocator, io: Io, stdout: *Io.Writer, stderr: *Io.Writer, options_in: Session.Options, fmt: Cli.Fmt) u8 {
    var options = options_in;
    // `--discards=<file>` (frontend.md §11.9): the `unit_discarded` lines of
    // a `check --explain --diagnostics=json` run, read before any file is.
    var discards_arena: std.heap.ArenaAllocator = .init(gpa);
    defer discards_arena.deinit();
    if (fmt.discards) |path| {
        options.top_discards = readDiscards(discards_arena.allocator(), io, path) catch |err| {
            return fail(stderr, "beni: cannot read the discards in '{s}': {t}", .{ path, err });
        };
    }
    var session = Session.init(gpa, io, options) catch return fail(stderr, "beni: out of memory", .{});
    defer session.deinit();
    const summary = session.run(fmt.paths, Session.format_phases, stderr) catch |err| switch (err) {
        error.InputPath => {
            const failure = session.io_failure.?;
            return fail(stderr, "beni: cannot read '{s}': {t}", .{ failure.path, failure.err });
        },
        else => |e| return fail(stderr, "beni: {t}", .{e}),
    };
    if (fmt.stdout and session.store.count() != 1) return fail(stderr, "beni: fmt --stdout needs exactly one file", .{});

    return emitAll(&session, stdout, stderr, fmt, summary) catch |err| switch (err) {
        error.WriteFailed => 2,
    };
}

/// The `unit_discarded` diagnostics of the JSON array at `path`, every other
/// code skipped.
fn readDiscards(arena: Allocator, io: Io, path: []const u8) ![]const Session.TopDiscard {
    const bytes = try fs_read.readFileAlloc(io, Io.Dir.cwd(), path, arena, .limited(1 << 28));
    const Row = struct {
        code: []const u8,
        span: struct { file: []const u8, start: diagnostic.Position },
    };
    const rows = try std.json.parseFromSliceLeaky([]const Row, arena, bytes, .{ .ignore_unknown_fields = true });
    var out: std.ArrayList(Session.TopDiscard) = .empty;
    for (rows) |row| {
        if (!std.mem.eql(u8, row.code, "unit_discarded")) continue;
        try out.append(arena, .{ .file = row.span.file, .at = .{ .line = row.span.start.line, .col = row.span.start.col } });
    }
    return out.items;
}

fn fail(stderr: *Io.Writer, comptime format_string: []const u8, args: anytype) u8 {
    stderr.print(format_string ++ "\n", args) catch {};
    return 2;
}

/// Walk the files in index order and act on each one's canonical text.
/// Nothing here formats: the text is already in `artifacts`, so this loop
/// is a byte compare plus at most one write or print per file.
fn emitAll(session: *Session, stdout: *Io.Writer, stderr: *Io.Writer, fmt: Cli.Fmt, summary: Session.Summary) Io.Writer.Error!u8 {
    var changed = false;
    var io_failed = false;
    for (session.store.byPath()) |file| {
        // Null means the file has a diagnostic and no canonical form.
        const text = session.artifacts.formatted(file) orelse continue;
        const path = session.store.path(file);

        if (fmt.stdout) {
            try stdout.writeAll(text);
            continue;
        }
        if (std.mem.eql(u8, text, session.store.bytes(file))) continue;
        changed = true;
        if (fmt.check) {
            try stdout.print("{s}\n", .{path});
            continue;
        }
        writeAtomic(session.io, path, text) catch |err| {
            try stderr.print("beni: cannot write '{s}': {t}\n", .{ path, err });
            io_failed = true;
        };
    }
    try stdout.flush();
    if (io_failed) return 2;
    if (summary.errors > 0) return 1;
    if (fmt.check and changed) return 1;
    return 0;
}

/// Replace `path` with `text` through a temporary file in the same
/// directory, renamed over the original — keeping everything about the file
/// that is not its contents.
///
/// **A symlink is followed.** `rename` replaces the name it is given, so a
/// link handed to `fmt` was turned into a regular file holding the formatted
/// text while the module it pointed at kept the old bytes: the link
/// destroyed, the file unformatted, exit 0. The destination is resolved
/// first and the temporary lands in the TARGET's directory, so the link is
/// untouched and the real file is the one rewritten. (The walk still never
/// follows a link — `SourceStore.walk` — so this is about a path the user
/// named.)
///
/// **The mode is preserved.** The temporary is created with the
/// destination's permissions AND chmod'd to them before the rename, because
/// `createFile` puts the mode through the process umask: without the second
/// step a `0666` file comes back `0644`. Before this, every rewritten file
/// came back at the umask default whatever it had been — a `0600` source
/// file became world-readable and a `0755` script lost its `x`.
///
/// **A file the user cannot write is refused**, not rewritten: `0444` means
/// what it says, and silently ignoring it was the worst of the three
/// possible answers. The refusal is an I/O failure — exit 2 (`frontend.md`
/// §1) — and the file keeps every byte.
///
/// Two things are NOT preserved, both by design. Ownership does not survive
/// a rename for an unprivileged process, so a file someone else owns in a
/// directory this user can write changes hands; that is what the filesystem
/// offers. And a rename breaks a HARD link: the other names keep the old
/// contents. Writing in place would keep them and give up atomicity for
/// every file, and "a crash mid-format never leaves a truncated module" is
/// worth more than a link count a source tree almost never has.
fn writeAtomic(io: Io, path: []const u8, text: []const u8) !void {
    const cwd = Io.Dir.cwd();
    var resolved: [SourceStore.max_path_bytes]u8 = undefined;
    const link = (try cwd.statFile(io, path, .{ .follow_symlinks = false })).kind == .sym_link;
    const destination = if (link) resolved[0..try cwd.realPathFile(io, path, &resolved)] else path;

    const permissions = (try cwd.statFile(io, destination, .{})).permissions;
    try cwd.access(io, destination, .{ .write = true });

    var atomic = try cwd.createFileAtomic(io, destination, .{ .replace = true, .permissions = permissions });
    defer atomic.deinit(io);
    // The mode the temporary was created with went through the umask; this
    // one does not. It is set on the open file, so it travels with the
    // inode through the rename. A filesystem that cannot chmod still gets
    // the text — the alternative is refusing to format over a detail.
    atomic.file.setPermissions(io, permissions) catch {};
    try atomic.file.writeStreamingAll(io, text);
    try atomic.replace(io);
}
