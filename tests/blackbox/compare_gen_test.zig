//! beni's printer of the cross-language benchmark, in the gates
//! (docs/design/compare-bench.md §15, owner's decision 2026-09-27).
//!
//! The generator writes the benchmark's beni project at seed 1, size 1, in
//! both annotation modes, and the installed binary must check it clean. beni
//! is the one language of the benchmark that changes under this repository:
//! without this case a language change would break the benchmark silently
//! until its next manual run. A failure here is either a beni regression or
//! a printer that must follow the language.
//!
//! The generator reaches this file as the `compare_gen` module; it imports
//! nothing of the compiler, so the black-box rule holds.

const std = @import("std");
const testing = std.testing;
const compare_gen = @import("compare_gen");
const world = @import("world.zig");
const World = world.World;

fn checkMode(annotate: u32) !void {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: std.Io.Writer.Allocating = .init(a);
    const prog = compare_gen.gen.generate(a, .{ .seed = 1, .size = 1, .annotate = annotate }, &diag.writer) catch |err| {
        std.debug.print("the generator's oracle refused seed 1: {s}\n", .{diag.written()});
        return err;
    };
    for (prog.tree.modules.items, 0..) |_, mi| {
        const o = try compare_gen.print.module(a, &prog, @intCast(mi), .beni, .{});
        try w.write(o.path, o.text);
    }

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.run(&.{ "check", "--no-cache", "--platform=node", "." });

    // ┌─────────────────────────────────────────┐
    // │ ASSERT                                  │
    // └─────────────────────────────────────────┘
    // The one diagnostic the benchmark accepts is beni's warning on an
    // inferred `pub` interface that carries a method constraint, which the
    // inferred mode can produce (compare-bench.md §11).
    var unexpected: usize = 0;
    for (checked.diagnostics) |d| {
        if (d.code != .ambiguous_method_receiver) unexpected += 1;
    }
    if (checked.exit_code != 0 or unexpected != 0) {
        std.debug.print("beni refused the generated project (annotate {d}):\n{s}\n", .{ annotate, checked.stderr });
    }
    try testing.expectEqual(@as(u8, 0), checked.exit_code);
    try testing.expectEqual(@as(usize, 0), unexpected);
}

test "the benchmark's generated beni project checks, annotated" {
    try checkMode(100);
}

test "the benchmark's generated beni project checks, inferred" {
    try checkMode(0);
}
