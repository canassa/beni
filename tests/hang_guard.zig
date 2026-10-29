//! A generous wall-clock deadline for one test or one corpus case.
//! The watchdog runs independently so a loop in the harness is bounded too.
const Guard = @This();
const std = @import("std");
const Io = std.Io;

pub const timeout_seconds = 120;

name: []const u8 = "",
done: Io.Event = .unset,
thread: ?std.Thread = null,
// This IO is independent of std.testing.io, which the test tears down.
backend: Io.Threaded = .init_single_threaded,
deadline: Io.Clock.Timestamp = undefined,

pub fn start(g: *Guard, name: []const u8) !void {
    try g.startFor(name, .fromSeconds(timeout_seconds));
}

/// Short deadlines are only for the runner's subprocess smoke tests.
pub fn startFor(g: *Guard, name: []const u8, duration: Io.Duration) !void {
    g.name = name;
    g.deadline = .{ .raw = Io.Timestamp.now(g.backend.io(), .awake).addDuration(duration), .clock = .awake };
    g.thread = try std.Thread.spawn(.{}, watch, .{g});
}

pub fn finish(g: *Guard) void {
    g.done.set(g.backend.io());
    if (g.thread) |thread| thread.join();
    g.thread = null;
}

fn watch(g: *Guard) void {
    const io = g.backend.io();
    while (!g.done.isSet()) {
        g.done.waitTimeout(io, .{ .deadline = g.deadline }) catch |err| switch (err) {
            error.Canceled => unreachable,
            error.Timeout => {
                // Event waits may wake spuriously; keep the original deadline.
                if (Io.Timestamp.now(io, .awake).nanoseconds < g.deadline.raw.nanoseconds) continue;
                if (g.done.isSet()) return;
                rawWrite("FAIL: test timed out: ");
                rawWrite(g.name);
                rawWrite("\n");
                killChildren();
                hardExit(1);
            },
        };
    }
}

// A timeout exits the test process, so first kill every child process group
// it owns, including grandchildren. Registration is shared by corpus workers.
// A fixed table of atomic slots (0 empty): a crash handler reads it with no
// lock and no reallocation under its feet.
const max_children = 1024;
var children: [max_children]std.atomic.Value(std.posix.pid_t) = @splat(.init(0));

pub fn trackChild(pid: std.posix.pid_t) !void {
    for (&children) |*slot| {
        if (slot.cmpxchgStrong(0, pid, .acq_rel, .acquire) == null) return;
    }
    return error.TooManyTestChildren;
}

pub fn untrackChild(pid: std.posix.pid_t) void {
    for (&children) |*slot| {
        if (slot.cmpxchgStrong(pid, 0, .acq_rel, .acquire) == null) return;
    }
    unreachable;
}

fn killChildren() void {
    for (&children) |*slot| {
        const pid = slot.load(.acquire);
        if (pid == 0) continue;
        std.posix.kill(-pid, .KILL) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => rawWrite("cannot kill a test child group\n"),
        };
    }
}

/// `killChildren` for a crash handler: no lock, no allocation, no print.
pub fn killChildrenNow() void {
    for (&children) |*slot| {
        const pid = slot.load(.acquire);
        if (pid != 0) std.posix.kill(-pid, .KILL) catch {};
    }
}

/// Exit at once with `_exit` (`exit_group` on Linux without libc): no atexit
/// handler, no stdio flush, so a crash inside malloc cannot hang it.
pub fn hardExit(code: u8) noreturn {
    if (@import("builtin").os.tag == .linux and !@import("builtin").link_libc) std.os.linux.exit_group(code);
    std.c._exit(code);
}

/// `s` to stderr with `write(2)` alone, so a timeout reports even while a
/// crashed or printing thread holds stderr's lock.
fn rawWrite(s: []const u8) void {
    var rest = s;
    while (rest.len > 0) {
        const rc = std.posix.system.write(2, rest.ptr, rest.len);
        const n: isize = if (@TypeOf(rc) == usize) @bitCast(rc) else rc;
        if (n <= 0) return;
        rest = rest[@intCast(n)..];
    }
}
