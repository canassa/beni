//! Run a test's body on a thread with a small stack of its own.
//!
//! The test runner gives every test a 256 MiB stack (`tests/test_runner.zig`),
//! so a depth test run on it has to build a tree deep enough to exhaust 256
//! MiB before a walk that recursed per level would fail — hundreds of
//! thousands of levels, and most of the test's time spent building them. On
//! `size` bytes the same claim needs a tree only as deep as a recursive walk
//! survives on that stack, and a walk that regressed into recursion overflows
//! it and takes the test process down with it.
//!
//! For tests only.

const std = @import("std");

/// The stack the depth tests run on. Every walk they guard iterates, so what
/// it uses is a handful of frames whatever the depth.
pub const size = 1024 * 1024;

/// Call `function` with `args` on a fresh thread whose stack is `size`
/// bytes, and return what it returned.
pub fn run(comptime function: anytype, args: anytype) anyerror!void {
    const Args = @TypeOf(args);
    const Call = struct {
        fn go(a: Args, result: *anyerror!void) void {
            result.* = @call(.auto, function, a);
        }
    };
    var result: anyerror!void = {};
    const thread = try std.Thread.spawn(.{ .stack_size = size }, Call.go, .{ args, &result });
    thread.join();
    return result;
}

test "a body run on the small stack returns its error" {
    const Body = struct {
        fn fails(n: u32) !void {
            if (n == 1) return error.TestUnexpectedResult;
        }
    };
    try run(Body.fails, .{@as(u32, 0)});
    try std.testing.expectError(error.TestUnexpectedResult, run(Body.fails, .{@as(u32, 1)}));
}
