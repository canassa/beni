//! `beni fmt [--check] [--stdout] <path>...` (docs/design/frontend.md §1,
//! language.md §9): the driver around `Format`.
//!
//! The session runs the ordinary read → lex → parse phases over every path
//! and renders whatever diagnostics they produce; formatting happens
//! afterwards, serially, file by file in index order (sorted paths), so the
//! `--check` listing and the `--stdout` product are deterministic whatever
//! `--jobs` is. A file with any diagnostic — lexical, syntactic, or an
//! invalid module path — has no canonical form and is never written, printed
//! or listed: its diagnostics are the whole output for it, and the exit code
//! is 1. Every other file formats totally.
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
const Arena = @import("../Arena.zig");
const Cli = @import("../Cli.zig");
const Session = @import("../Session.zig");
const SourceStore = @import("../SourceStore.zig");
const Format = @import("Format.zig");

/// Run the command to completion and return the process exit code.
/// `options` is the session configuration `main` derived from the common
/// flags; `fmt` carries the paths and the mode.
pub fn run(gpa: Allocator, io: Io, stdout: *Io.Writer, stderr: *Io.Writer, options: Session.Options, fmt: Cli.Fmt) u8 {
    var session = Session.init(gpa, io, options) catch return fail(stderr, "beni: out of memory", .{});
    defer session.deinit();
    const summary = session.run(fmt.paths, Session.parse_phases, stderr) catch |err| switch (err) {
        error.InputPath => {
            const failure = session.io_failure.?;
            return fail(stderr, "beni: cannot read '{s}': {t}", .{ failure.path, failure.err });
        },
        else => |e| return fail(stderr, "beni: {t}", .{e}),
    };
    if (fmt.stdout and session.store.count() != 1) return fail(stderr, "beni: fmt --stdout needs exactly one file", .{});

    return formatAll(&session, stdout, stderr, fmt, summary) catch |err| switch (err) {
        error.OutOfMemory => fail(stderr, "beni: out of memory", .{}),
        error.WriteFailed => 2,
    };
}

fn fail(stderr: *Io.Writer, comptime format_string: []const u8, args: anytype) u8 {
    stderr.print(format_string ++ "\n", args) catch {};
    return 2;
}

fn formatAll(session: *Session, stdout: *Io.Writer, stderr: *Io.Writer, fmt: Cli.Fmt, summary: Session.Summary) (Allocator.Error || Io.Writer.Error)!u8 {
    const gpa = session.gpa;
    const count = session.store.count();

    // Files with a diagnostic keep their bytes. The diagnostics carry the
    // store's own path strings, so the lookup is exact.
    const failed = try gpa.alloc(bool, count);
    defer gpa.free(failed);
    @memset(failed, false);
    for (session.diagnostics.items) |d| {
        if (session.store.find(d.span.file)) |index| failed[index.int()] = true;
    }

    var scratch: Arena = .init(std.heap.page_allocator);
    defer scratch.deinit();
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var changed = false;
    var io_failed = false;
    for (0..count) |i| {
        if (failed[i]) continue;
        const file: SourceStore.Index = @enumFromInt(i);
        out.clearRetainingCapacity();
        scratch.reset(.retain_capacity);
        Format.format(
            scratch.allocator(),
            session.artifacts.ast(file),
            session.artifacts.tokens(file),
            session.artifacts.comments(file),
            session.store.bytes(file),
            session.store.lineStarts(file),
            &out.writer,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Every syntax error was reported and flagged above; this is
            // belt and braces, and the file is simply left alone.
            error.SyntaxErrors => continue,
            error.WriteFailed => return error.OutOfMemory, // an allocating writer fails only for memory
        };
        const text = out.written();
        const path = session.store.path(file);

        if (fmt.stdout) {
            try stdout.writeAll(text);
            try stdout.flush();
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
