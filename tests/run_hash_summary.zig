//! Prints what the black-box processes did with their run hashes
//! (`tests/blackbox/run_hash.zig`), as one line each, merges what a
//! recording verified into the index of program runs, and deletes the
//! reports it read.
//!
//!   run-hash-summary <dir> [--index=<path>] [--whole]
//!   run-hash-summary node-version
//!
//! Every test process given `BENI_RUN_HASH_REPORT=<dir>` writes its counts
//! there: the corpus walker `<dir>/<part>.txt`, a process that runs
//! scenario programs `<dir>/program-<random>.txt`, lines of `<counter>
//! <value>`; recording, the latter also writes `<dir>/program-<random>.records`,
//! one `<run id> <digest>` line per run that matched and `<run id> -` per
//! run that did not. The build runs this tool after all of them, on a
//! directory no other build uses, and the tool removes it.
//!
//! Checking, it says how many programs ran under Node because their output
//! had no recorded hash — nothing when none did, and never a failure: the
//! programs were verified by running them, and the line only says that
//! recording would make the next run cheaper. Recording, it says how many
//! hashes were written and how many runs were left without one, and with
//! `--index=<path>` it rewrites that index: each reported run gets its line
//! or loses it, and every other line is kept — unless `--whole` says the
//! recording ran every test, when a line no run reported is dropped too,
//! so a renamed or deleted test leaves nothing behind. The index is sorted
//! by line.
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
    var index: ?[]const u8 = null;
    var whole = false;
    for (args[@min(args.len, 2)..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--index=")) {
            index = arg["--index=".len..];
        } else if (std.mem.eql(u8, arg, "--whole")) {
            whole = true;
        } else return usage();
    }
    if (args.len < 2) return usage();
    var dir = Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(io);

    var counts: Counts = .{};
    var names: std.ArrayList([]const u8) = .empty;
    var records: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const name = try arena.dupe(u8, entry.name);
        try names.append(arena, name);
        if (std.mem.endsWith(u8, name, ".records")) {
            const text = try dir.readFileAlloc(io, name, arena, .limited(16 * 1024 * 1024));
            var lines = std.mem.tokenizeScalar(u8, text, '\n');
            while (lines.next()) |line| try records.append(arena, line);
            continue;
        }
        if (!std.mem.endsWith(u8, name, ".txt")) continue;
        const text = try dir.readFileAlloc(io, name, arena, .limited(4096));
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const value = std.fmt.parseUnsigned(u64, line[space + 1 ..], 10) catch continue;
            inline for (@typeInfo(Counts).@"struct".fields) |field| {
                if (std.mem.eql(u8, line[0..space], field.name)) @field(counts, field.name) += value;
            }
        }
    }
    if (index) |path| if (records.items.len != 0 or whole) try merge(arena, io, path, records.items, whole);
    for (names.items) |name| try dir.deleteFile(io, name);
    // The directory is this build's own; an entry left in it is not ours.
    Io.Dir.cwd().deleteDir(io, args[1]) catch {};

    var buffer: [1024]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    const out = &writer.interface;
    const stale = counts.stale + counts.program_stale;
    if (stale != 0) try out.print(
        "{d} of {d} program runs had no recorded hash for their output and ran under Node (corpus run/ and browser/ {d} of {d}, scenarios {d} of {d}); `zig build test-run-hashes` records them\n",
        .{
            stale,
            stale + counts.skipped + counts.program_skipped,
            counts.stale,
            counts.stale + counts.skipped,
            counts.program_stale,
            counts.program_stale + counts.program_skipped,
        },
    );
    const recorded = counts.recorded + counts.program_recorded;
    const refused = counts.refused + counts.program_refused;
    if (recorded != 0 or refused != 0) try out.print(
        "recorded {d} run hashes (corpus run/ and browser/ {d}, scenarios {d}); {d} runs failed and have none\n",
        .{ recorded, counts.recorded, counts.program_recorded, refused },
    );
    try out.flush();
    return 0;
}

/// The counters the reports carry: `run/` builds of the corpus walker, and
/// `program_` runs of the scenarios.
const Counts = struct {
    skipped: u64 = 0,
    stale: u64 = 0,
    recorded: u64 = 0,
    refused: u64 = 0,
    program_skipped: u64 = 0,
    program_stale: u64 = 0,
    program_recorded: u64 = 0,
    program_refused: u64 = 0,
};

fn usage() u8 {
    std.debug.print("usage: run-hash-summary <dir> [--index=<path>] [--whole] | run-hash-summary node-version\n", .{});
    return 2;
}

/// Rewrite the index at `path` with `records` (`<id> <digest>` or `<id>
/// -`), keeping every line of an id no record names unless `whole`.
fn merge(arena: std.mem.Allocator, io: Io, path: []const u8, records: []const []const u8, whole: bool) !void {
    var lines: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    if (!whole) {
        const old = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
        var it = std.mem.tokenizeScalar(u8, old, '\n');
        while (it.next()) |line| {
            const space = std.mem.lastIndexOfScalar(u8, line, ' ') orelse continue;
            try lines.put(arena, line[0..space], line[space + 1 ..]);
        }
    }
    for (records) |line| {
        const space = std.mem.lastIndexOfScalar(u8, line, ' ') orelse continue;
        const digest = line[space + 1 ..];
        if (std.mem.eql(u8, digest, "-")) {
            _ = lines.orderedRemove(line[0..space]);
        } else {
            try lines.put(arena, line[0..space], digest);
        }
    }
    const sorted = try arena.alloc([]const u8, lines.count());
    for (lines.keys(), lines.values(), sorted) |id, digest, *slot| slot.* = try std.fmt.allocPrint(arena, "{s} {s}", .{ id, digest });
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    var text: std.ArrayList(u8) = .empty;
    for (sorted) |line| {
        try text.appendSlice(arena, line);
        try text.append(arena, '\n');
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text.items });
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
