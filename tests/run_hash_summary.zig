//! Prints what the corpus walker's `run/` processes did with their run
//! hashes (`tests/blackbox/run_hash.zig`), as one line each, and deletes the
//! counts it read.
//!
//!   run-hash-summary <dir>
//!
//! Every walker process given `BENI_RUN_HASH_REPORT=<dir>` writes
//! `<dir>/<part>.txt`, lines of `<counter> <value>`; the build runs this
//! tool after all of them, on a directory no other build uses, and the tool
//! removes it. Checking, it says how many programs ran under
//! Node because their output had no recorded hash — nothing when none did,
//! and never a failure: the programs were verified by running them, and the
//! line only says that recording would make the next run cheaper.
//! Recording, it says how many hashes were written and how many builds were
//! left without one.

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: run-hash-summary <dir>\n", .{});
        return 2;
    }
    var dir = Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(io);

    var skipped: u64 = 0;
    var stale: u64 = 0;
    var recorded: u64 = 0;
    var refused: u64 = 0;
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".txt")) continue;
        const name = try arena.dupe(u8, entry.name);
        try names.append(arena, name);
        const text = try dir.readFileAlloc(io, name, arena, .limited(4096));
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const value = std.fmt.parseUnsigned(u64, line[space + 1 ..], 10) catch continue;
            const key = line[0..space];
            if (std.mem.eql(u8, key, "skipped")) skipped += value;
            if (std.mem.eql(u8, key, "stale")) stale += value;
            if (std.mem.eql(u8, key, "recorded")) recorded += value;
            if (std.mem.eql(u8, key, "refused")) refused += value;
        }
    }
    for (names.items) |name| try dir.deleteFile(io, name);
    // The directory is this build's own; an entry left in it is not ours.
    Io.Dir.cwd().deleteDir(io, args[1]) catch {};

    var buffer: [1024]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    const out = &writer.interface;
    if (stale != 0) try out.print(
        "run/: {d} of {d} builds had no recorded hash for their output and ran under Node; `zig build test-run-hashes` records them\n",
        .{ stale, stale + skipped },
    );
    if (recorded != 0 or refused != 0) try out.print(
        "run/: recorded {d} run hashes; {d} builds failed and have none\n",
        .{ recorded, refused },
    );
    try out.flush();
    return 0;
}
