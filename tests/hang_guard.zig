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
                std.process.exit(1);
            },
        };
    }
}

// A timeout exits the test process, so first kill every child process group
// it owns, including grandchildren. Registration is shared by corpus workers.
var children: std.ArrayList(std.posix.pid_t) = .empty;
var children_mutex: Io.Mutex = .init;
var children_backend: Io.Threaded = .init_single_threaded;

pub fn trackChild(pid: std.posix.pid_t) !void {
    const io = children_backend.io();
    children_mutex.lockUncancelable(io);
    defer children_mutex.unlock(io);
    try children.append(std.heap.page_allocator, pid);
}

pub fn untrackChild(pid: std.posix.pid_t) void {
    const io = children_backend.io();
    children_mutex.lockUncancelable(io);
    defer children_mutex.unlock(io);
    for (children.items, 0..) |child, i| {
        if (child == pid) {
            _ = children.swapRemove(i);
            return;
        }
    }
    unreachable;
}

fn killChildren() void {
    const io = children_backend.io();
    children_mutex.lockUncancelable(io);
    defer children_mutex.unlock(io);
    for (children.items) |pid| std.posix.kill(-pid, .KILL) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => std.debug.print("cannot kill test child group {d}: {t}\n", .{ pid, err }),
    };
}

/// `killChildren` without the lock, for a crash handler: the list may be
/// mid-update, so this kills what it can read.
pub fn killChildrenNow() void {
    for (children.items) |pid| std.posix.kill(-pid, .KILL) catch {};
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
