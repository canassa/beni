//! Helpers shared by `abuse_test.zig` and `abuse_wide_test.zig`, which are
//! one suite split into two processes so that `test-blackbox` runs them in
//! parallel (`plans/checker-rewrite.md` §2.4, *Parts*). No tests here: a file
//! with tests imported by both would run them twice.

const std = @import("std");
const world = @import("world.zig");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// The invariants every scenario shares: the child EXITED with `code`
/// rather than dying from a signal, and wrote nothing to stdout. A run that
/// did not finish inside its run's timeout never reaches here — the
/// harness kills it and returns `error.CompilerTimeout`.
///
/// stdout is checked here because no command in this file has stdout as its
/// product: `check` never writes there, and neither does `fmt` in place.
/// The two scenarios that use `fmt --check` (whose product IS a list of
/// paths on stdout) assert it themselves.
pub fn expectExited(r: world.Result, code: u8) !void {
    if (r.term != .exited) {
        std.debug.print("compiler did not exit normally: {any}\n--- stderr ---\n{s}\n", .{ r.term, r.stderr });
        return error.CompilerDiedFromSignal;
    }
    if (r.exit_code != code) {
        std.debug.print("expected exit {d}, got {d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n", .{ code, r.exit_code, r.stdout, r.stderr });
        return error.UnexpectedExitCode;
    }
    try testing.expectEqualStrings("", r.stdout);
}

/// `head` followed by `piece` repeated `links` times, all on one line.
pub fn chain(gpa: Allocator, head: []const u8, piece: []const u8, links: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, head.len + links * piece.len + 2);
    out.appendSliceAssumeCapacity(head);
    for (0..links) |_| out.appendSliceAssumeCapacity(piece);
    out.appendSliceAssumeCapacity("\n");
    return out.toOwnedSlice(gpa);
}

/// `main =\n    ` then `open` repeated `depth` times, `middle`, and `close`
/// repeated `depth` times — all on one line.
pub fn nested(gpa: Allocator, open: []const u8, middle: []const u8, close: []const u8, depth: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, 16 + depth * (open.len + close.len) + middle.len);
    out.appendSliceAssumeCapacity("main =\n    ");
    for (0..depth) |_| out.appendSliceAssumeCapacity(open);
    out.appendSliceAssumeCapacity(middle);
    for (0..depth) |_| out.appendSliceAssumeCapacity(close);
    out.appendSliceAssumeCapacity("\n");
    return out.toOwnedSlice(gpa);
}
