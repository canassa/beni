//! One black-box scenario program, described by the environment, for
//! `run_hash_test.zig` to run as a child process: it builds
//! `BENI_PROBE_SOURCE` as `Main.beni` and expects the program to print
//! `BENI_PROBE_STDOUT`, through `World.buildAndRun`, the path every
//! scenario's program run takes. So the parent drives the run hashes of a
//! scenario program the way a black-box suite meets them — its own index
//! (`BENI_RUN_HASH_INDEX`), its own mode (`BENI_RUN_HASHES`), its own
//! report directory — and reads what happened from the files it leaves.
//!
//! Not part of any step's test list: `build.zig` only installs it.

const std = @import("std");
const testing = std.testing;
const world = @import("world.zig");
const World = world.World;

test "the program the scenario describes does what it expects" {
    const arena = std.heap.page_allocator;
    const source = try testing.environ.getAlloc(arena, "BENI_PROBE_SOURCE");
    const stdout = try testing.environ.getAlloc(arena, "BENI_PROBE_STDOUT");
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", source);
    _ = try w.buildAndRun(&.{"Main.beni"}, .{ .stdout = stdout });
}
