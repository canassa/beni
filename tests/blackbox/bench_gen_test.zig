//! The plain benchmark's generator (`bench/gen.zig`), run by `zig build
//! test-bench`. Benchmarks are not part of the gates, so neither is this
//! file.
//!
//! `zig build bench -- --generate=<lines>` measures the 100 000-line
//! budget (`fast-compiler.md` §2) on the corpus this generator writes. It
//! must be current beni, or the bench measures the error path, or a
//! migration someone ran first: the generated tree, in both of its modes,
//! must check with no diagnostic. A failure here is a generator that must
//! follow the language, or a beni regression.
//!
//! The generator reaches this file as the `bench_gen` module; it imports
//! nothing of the compiler, so the black-box rule holds.

const std = @import("std");
const testing = std.testing;
const bench_gen = @import("bench_gen");
const world = @import("world.zig");
const World = world.World;

/// At the bench's own seed, about sixty modules: every kind of declaration
/// the generator writes, at a size the test budget holds.
const lines = 10_000;

fn checkMode(mode: bench_gen.Mode) !void {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try w.tmp.dir.realPath(w.io, &buffer);
    const stats = try bench_gen.generateMode(testing.allocator, w.io, buffer[0..len], bench_gen.default_seed, lines, mode);
    try testing.expect(stats.lines >= lines);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.run(&.{ "check", "--no-cache", "." });

    // ┌─────────────────────────────────────────┐
    // │ ASSERT                                  │
    // └─────────────────────────────────────────┘
    if (checked.exit_code != 0 or checked.diagnostics.len != 0) {
        std.debug.print("beni refused the generated corpus ({t}):\n{s}\n", .{ mode, checked.stderr });
    }
    try testing.expectEqual(@as(u8, 0), checked.exit_code);
    try testing.expectEqual(@as(usize, 0), checked.diagnostics.len);
}

test "the generated benchmark corpus checks with no diagnostic" {
    try checkMode(.plain);
}

test "the generated benchmark corpus checks with no diagnostic, in the dispatch shape" {
    try checkMode(.dispatch);
}
