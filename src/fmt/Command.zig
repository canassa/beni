//! `beni fmt [--check] [--stdout] <path>...` (docs/design/frontend.md §1,
//! language.md §9): the driver around `Format`.
//!
//! Formatting itself is a per-file worker phase (`Session.format_phases`):
//! read → tokenize → parse → format, on whichever worker took the file,
//! into a session-owned buffer in that file's `Artifacts` column. What is
//! left here is the part that must happen in a fixed order — compare the
//! canonical text with the source, then write it, print it, or list the
//! path — and it walks files by index (sorted paths) after the join. The
//! `--check` listing, the `--stdout` product and the bytes written are
//! therefore a function of the input alone, not of `--jobs`; the
//! determinism scenario compares all three across `--jobs=1` and `--jobs=8`.
//!
//! A file with any diagnostic — lexical, syntactic, or an invalid module
//! path — has no canonical form and is never written, printed or listed:
//! its diagnostics are the whole output for it, and the exit code is 1. The
//! worker decides that (a file's diagnostics are all known by the end of
//! its own phase), and leaves `formatted` null; here, null means skip.
//!
//! In-place writes go through `Io.Dir.createFileAtomic` + `replace`: the
//! text lands in a temporary file in the same directory and is renamed over
//! the original, so a crash or a full disk leaves either the old bytes or
//! the new ones, never a truncated module. A file whose formatted text
//! equals its source is not touched at all (its mtime stays put, which is
//! what editors and build tools watching it want).
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

/// Run the command to completion and return the process exit code.
/// `options` is the session configuration `main` derived from the common
/// flags; `fmt` carries the paths and the mode.
pub fn run(gpa: Allocator, io: Io, stdout: *Io.Writer, stderr: *Io.Writer, options: Session.Options, fmt: Cli.Fmt) u8 {
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
    for (0..session.store.count()) |i| {
        const file: SourceStore.Index = @enumFromInt(i);
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
/// directory, renamed over the original.
fn writeAtomic(io: Io, path: []const u8, text: []const u8) !void {
    var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, text);
    try atomic.replace(io);
}
