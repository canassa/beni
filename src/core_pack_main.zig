//! Makes the checked core (docs/design/fast-compiler.md §8, *The checked
//! core, embedded*): `core_pack <core dir> <build id, 32 hex digits> <out>`.
//!
//! Only `build.zig` runs this, once per compiler it builds, between building
//! this small program and building that compiler: it checks every module of
//! the core in `<core dir>` exactly as `beni check` would — the same option
//! string, every key computed with the build id of the compiler that will
//! carry the result — and writes each core file's front-end artifact and
//! each core module's cache entry into one blob (`cache/Pack.zig`), which
//! that compiler embeds as `core_pack`.
//!
//! **It refuses to make an incomplete pack.** A core module that is not in
//! it would be checked by every build, which is the cost the pack exists to
//! remove, and nothing else would say so; a core with an error cannot be
//! carried at all. Either fails the build of beni, with the diagnostics.
//!
//! A program of its own, and not a hidden command of `beni`, because it is
//! on the path of every build of beni after an edit under `src/`: this root
//! reaches the front end and the checker and not the backend, the formatter
//! or the development loop, so it compiles in about half the time.

const std = @import("std");
const beni = @import("beni");
const Session = beni.Session;
const Pack = beni.cache.Pack;

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const io = init.io;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return fail(stderr, "out of memory", .{});
    if (args.len != 4) return fail(stderr, "usage: core_pack <core dir> <build id> <out>", .{});
    const core_dir = args[1];
    var build_id: [16]u8 = undefined;
    const digits = args[2];
    if (digits.len != 32) return fail(stderr, "the build id is 32 hex digits, not '{s}'", .{digits});
    _ = std.fmt.hexToBytes(&build_id, digits) catch return fail(stderr, "the build id is 32 hex digits, not '{s}'", .{digits});

    var writer: Pack.Writer = .{};
    defer writer.deinit(gpa);
    const cpus: u32 = @intCast(@min(std.Thread.getCpuCount() catch 1, 64));
    // `beni check`'s options, every one that is a term of a key
    // (`cache/Key.zig`'s option string): a pack made with any other would
    // hold rows no build looks up.
    var session = Session.init(gpa, io, .{
        .jobs = @max(cpus, 1),
        .size_by_work = true,
        .core_package = true,
        .core_root = core_dir,
        .informational = true,
        .pack_out = &writer,
        .pack_build_id = build_id,
    }) catch return fail(stderr, "out of memory", .{});
    defer session.deinit();

    const summary = session.run(&.{}, Session.check_phases, stderr) catch |err| switch (err) {
        error.InputPath => {
            const failure = session.io_failure.?;
            return fail(stderr, "cannot read '{s}': {t}", .{ failure.path, failure.err });
        },
        else => |e| return fail(stderr, "{t}", .{e}),
    };
    if (summary.errors != 0) return fail(stderr, "the core in '{s}' does not check", .{core_dir});

    // Every core file and every core module, or no pack.
    var files: u32 = 0;
    for (0..session.store.count()) |i| {
        if (session.store.package(@enumFromInt(i)) == .core) files += 1;
    }
    if (files == 0) return fail(stderr, "no core modules under '{s}'", .{core_dir});
    if (writer.countOf(.frontend) != files or writer.countOf(.entry) != files) {
        return fail(stderr, "the pack holds {d} front-end artifacts and {d} entries for {d} core modules", .{
            writer.countOf(.frontend), writer.countOf(.entry), files,
        });
    }

    const blob = writer.write(gpa) catch return fail(stderr, "out of memory", .{});
    defer gpa.free(blob);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[3], .data = blob }) catch |err|
        return fail(stderr, "cannot write '{s}': {t}", .{ args[3], err });
    return 0;
}

fn fail(stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype) u8 {
    stderr.print("core_pack: " ++ fmt ++ "\n", args) catch {};
    return 1;
}
