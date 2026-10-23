//! Prints what the black-box processes did with their run hashes
//! (`tests/blackbox/run_hash.zig`), as one line, and deletes the reports
//! it read.
//!
//!   run-hash-summary <dir> <cache-dir>
//!   run-hash-summary node-version
//!
//! Every test process given `BENI_RUN_HASH_REPORT=<dir>` writes its counts
//! there: the corpus walker `<dir>/<part>.txt`, a process that runs
//! scenario programs `<dir>/program-<random>.txt`, lines of `<counter>
//! <value>`. The build runs this tool after all of them, on a directory no
//! other build uses, and the tool removes it.
//!
//! It says how many programs ran under Node because the cache held no
//! verified digest for them — nothing when none did, and never a failure:
//! the programs were verified by running them, and each that passed is in
//! the cache now, so the next run is cheaper by itself. `<cache-dir>` is
//! the cache's directory (`BENI_RUN_HASH_DIR`), empty for no cache: the
//! line then says that nothing was recorded.
//!
//! `node-version` prints what `node --version` prints, or nothing when
//! there is no `node` on `PATH`: the build runs it once and hands the text
//! to every test process.

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 2 and std.mem.eql(u8, args[1], "node-version")) return nodeVersion(arena, io);
    if (args.len != 3) return usage();
    const cached = args[2].len != 0;
    var dir = Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(io);

    var counts: Counts = .{};
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const name = try arena.dupe(u8, entry.name);
        try names.append(arena, name);
        if (!std.mem.endsWith(u8, name, ".txt")) continue;
        const text = try dir.readFileAlloc(io, name, arena, .limited(4096));
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const value = std.fmt.parseUnsigned(u64, line[space + 1 ..], 10) catch continue;
            inline for (@typeInfo(Counts).@"struct".field_names) |field_name| {
                if (std.mem.eql(u8, line[0..space], field_name)) @field(counts, field_name) += value;
            }
        }
    }
    for (names.items) |name| try dir.deleteFile(io, name);
    // The directory is this build's own; an entry left in it is not ours.
    Io.Dir.cwd().deleteDir(io, args[1]) catch {};

    var buffer: [1024]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    const out = &writer.interface;
    const stale = counts.stale + counts.program_stale;
    if (stale != 0) try out.print(
        "{d} of {d} program runs had no verified digest in the run-hash cache and ran under Node (corpus run/, browser/ and workers/ {d} of {d}, scenarios {d} of {d}); {s}\n",
        .{
            stale,
            stale + counts.skipped + counts.program_skipped,
            counts.stale,
            counts.stale + counts.skipped,
            counts.program_stale,
            counts.program_stale + counts.program_skipped,
            if (cached) "each that passed is cached now" else "there is no cache (BENI_RUN_HASH_DIR is empty), so nothing was recorded",
        },
    );
    try out.flush();
    return 0;
}

/// The counters the reports carry: the corpus walker's program runs, and
/// `program_` runs of the scenarios.
const Counts = struct {
    skipped: u64 = 0,
    stale: u64 = 0,
    program_skipped: u64 = 0,
    program_stale: u64 = 0,
};

fn usage() u8 {
    std.debug.print("usage: run-hash-summary <dir> <cache-dir> | run-hash-summary node-version\n", .{});
    return 2;
}

/// Print `node --version`'s line, or nothing when Node cannot be run.
fn nodeVersion(arena: std.mem.Allocator, io: Io) !u8 {
    const r = std.process.run(arena, io, .{ .argv = &.{ "node", "--version" } }) catch return 0;
    if (r.term != .exited or r.term.exited != 0) return 0;
    var buffer: [256]u8 = undefined;
    var writer = Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(std.mem.trim(u8, r.stdout, " \t\r\n"));
    try writer.interface.flush();
    return 0;
}
