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
//! For tests only, so it needs no guard for a build with no threads
//! (fast-compiler.md §10): no test binary is built single-threaded. The one
//! exception is `mark`, which a walk calls where it stops recursing: outside
//! a test binary it is empty.
//!
//! A depth test proves that a walk survives a deep tree; a margin test proves
//! that the walk's capped recursion leaves room. An overflow is found only as
//! a crash (#1171), so a frame that grows must fail a test first: the walk
//! calls `mark` at its cap, and the margin test compares `deepest` with
//! `size`.

const builtin = @import("builtin");
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
            top = @frameAddress();
            lowest = top;
            result.* = @call(.auto, function, a);
        }
    };
    var result: anyerror!void = {};
    const thread = try std.Thread.spawn(.{ .stack_size = size }, Call.go, .{ args, &result });
    thread.join();
    return result;
}

/// On a thread that `run` started: the frame address of its first frame,
/// and the lowest frame address that `mark` saw. Zero on every other thread.
/// std's thread entry, above the first frame, is not counted: a few hundred
/// bytes.
threadlocal var top: usize = 0;
threadlocal var lowest: usize = 0;

/// Note the caller's frame as a depth that the small stack reached. A
/// recursive walk calls it where it stops recursing, at its cap. It does
/// nothing outside a test binary, and nothing on a thread that `run` did not
/// start.
pub inline fn mark() void {
    if (builtin.is_test) {
        if (top != 0) lowest = @min(lowest, @frameAddress());
    }
}

/// The bytes of this thread's small stack from its first frame down to the
/// lowest frame that `mark` saw; 0 when `mark` saw none.
pub fn deepest() usize {
    return top - lowest;
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

test "mark records the deepest frame of a recursion on the small stack" {
    const Body = struct {
        fn down(n: u32) void {
            var pad: [256]u8 = undefined;
            std.mem.doNotOptimizeAway(&pad);
            if (n == 0) return mark();
            @call(.never_tail, down, .{n - 1});
        }
        fn twice() !void {
            try std.testing.expectEqual(@as(usize, 0), deepest());
            down(16);
            const shallow = deepest();
            down(64);
            const deep = deepest();
            // At least the 48 more frames of 256 bytes each.
            try std.testing.expect(shallow > 0 and deep >= shallow + 48 * 256);
            try std.testing.expect(deep < size);
        }
    };
    try run(Body.twice, .{});
    // Off the small stack, `mark` does nothing.
    mark();
    try std.testing.expectEqual(@as(usize, 0), deepest());
}
