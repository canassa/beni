//! The `beni` that `zig build coverage` hands the black-box suites as
//! `BENI_EXE`: it replaces itself with
//!
//!   kcov --collect-only --include-path=<repo>/src <raw>/<unique> <beni> args...
//!
//! so every compiler process a test spawns runs under kcov and leaves its
//! line counts in a directory of its own, which `tests/coverage.zig` merges
//! once the suites are done.
//!
//! The process image is replaced, not spawned, so the harness still sees
//! one child: the arguments, the working directory, the environment and the
//! three standard streams pass through untouched, and kcov exits with the
//! compiler's exit code. Every path is baked in at build time
//! (`coverage_options`), because the harness runs the compiler with an empty
//! environment.

const std = @import("std");
const Io = std.Io;
const options = @import("coverage_options");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    const out = try uniqueDir(arena, io);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        options.kcov,
        "--collect-only",
        "--include-path=" ++ options.include_path,
        out,
        options.beni,
    });
    try argv.appendSlice(arena, args[1..]);
    const err = std.process.replace(io, .{ .argv = argv.items });
    std.debug.print("coverage wrapper: cannot run {s}: {t}\n", .{ options.kcov, err });
    return 127;
}

/// A directory under `options.raw_dir` that no other process has, created
/// here so that two compilers started in the same instant cannot share one:
/// the process id and the clock name it, and a name that exists already is
/// tried again with a counter.
fn uniqueDir(arena: std.mem.Allocator, io: Io) ![]const u8 {
    const pid = std.posix.system.getpid();
    const now = Io.Clock.real.now(io).nanoseconds;
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        const path = try std.fmt.allocPrint(arena, "{s}/beni-{d}-{d}-{d}", .{ options.raw_dir, pid, now, attempt });
        Io.Dir.cwd().createDir(io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return path;
    }
}
