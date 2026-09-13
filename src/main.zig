//! CLI entry (docs/design/frontend.md §1): parse arguments, dispatch, map
//! outcomes to exit codes. Nothing here is logic worth testing in isolation;
//! `Cli.zig` owns the parsing and `Session.zig` owns the work, and the
//! black-box suite drives this binary end to end.
//!
//! Exit codes: 0 no errors, 1 at least one error diagnostic, 2 usage or I/O
//! failure. stdout carries the product; stderr carries diagnostics and usage
//! errors and nothing else.

const std = @import("std");
const Io = std.Io;
const beni = @import("beni");
const Cli = beni.Cli;
const Session = beni.Session;

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const args = init.minimal.args.toSlice(arena) catch return fail(stderr, "beni: out of memory", .{});
    const parsed = Cli.parse(arena, if (args.len == 0) args else args[1..]) catch
        return fail(stderr, "beni: out of memory", .{});
    const command = switch (parsed) {
        .command => |c| c,
        .usage => |u| return fail(stderr, "{s}", .{u.message()}),
    };

    switch (command) {
        .version => {
            stdout.print("beni {s}\n", .{beni.version}) catch return 2;
            return 0;
        },
        .help => {
            stdout.writeAll(Cli.usage) catch return 2;
            return 0;
        },
        .check => |check| return runCheck(gpa, io, stderr, check),
        .fmt => return fail(stderr, "beni: fmt is not implemented in M0", .{}),
        .dump => return fail(stderr, "beni: dump is not implemented in M0", .{}),
    }
}

fn fail(stderr: *Io.Writer, comptime fmt: []const u8, args: anytype) u8 {
    stderr.print(fmt ++ "\n", args) catch {};
    return 2;
}

fn runCheck(gpa: std.mem.Allocator, io: Io, stderr: *Io.Writer, check: Cli.Check) u8 {
    const jobs: u32 = check.common.jobs orelse @intCast(@min(std.Thread.getCpuCount() catch 1, std.math.maxInt(u32)));
    var session = Session.init(gpa, io, .{
        .jobs = @max(jobs, 1),
        .diagnostics = switch (check.common.diagnostics) {
            .text => .text,
            .json => .json,
        },
        .self_profile = check.common.self_profile,
        .root = check.common.root,
        .core = check.common.core,
    }) catch return fail(stderr, "beni: out of memory", .{});
    defer session.deinit();

    const summary = session.run(check.paths, Session.read_phases, stderr) catch |err| switch (err) {
        error.InputPath => {
            const failure = session.io_failure.?;
            return fail(stderr, "beni: cannot read '{s}': {t}", .{ failure.path, failure.err });
        },
        else => |e| return fail(stderr, "beni: {t}", .{e}),
    };
    return if (summary.errors > 0) 1 else 0;
}
