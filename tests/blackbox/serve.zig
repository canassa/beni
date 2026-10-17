//! The harness of a `run/` fixture that carries a `.requests` script
//! (docs/design/boundary.md §9.10 (h); tests/corpus/README.md, *A server
//! program*): where its driver and its preload are, and what a build's
//! record line covers beyond a plain `run/` one's.
//!
//! Such a fixture is a server. `tests/serve/driver.mjs` starts the build as
//! a child with `tests/serve/preload.mjs` imported first, learns the port
//! the program bound from a pipe the preload writes to, sends the script's
//! requests and prints a transcript: each request and its answer, then the
//! program's streams and its exit. The port never appears in it, so the
//! transcript is the golden. The record line's digest (`run_hash.lineWith`)
//! covers the driver's bytes, the preload's and the script as well as the
//! output tree, the golden and the Node version, so a change to any of them
//! runs the program again.

const std = @import("std");
const world = @import("world.zig");
const run_hash = @import("run_hash.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The driver and the preload, relative to the repository root.
pub const driver_path = "tests/serve/driver.mjs";
pub const preload_path = "tests/serve/preload.mjs";

/// The name on the record line where a `browser/` line has its DOM's.
pub const id = "serve";

/// The harness's files, resolved once per process from the working
/// directory, which is the repository root in every run the build makes.
pub const Harness = struct {
    /// Absolute, for a driver that runs in a test's project directory.
    driver: []const u8,
    driver_bytes: []const u8,
    preload_bytes: []const u8,
};

var harness_mutex: Io.Mutex = .init;
var harness_value: ?Harness = null;

pub fn harness(io: Io) !Harness {
    harness_mutex.lockUncancelable(io);
    defer harness_mutex.unlock(io);
    if (harness_value) |h| return h;
    const gpa = std.heap.page_allocator;
    harness_value = .{
        .driver = try Io.Dir.cwd().realPathFileAlloc(io, driver_path, gpa),
        .driver_bytes = try Io.Dir.cwd().readFileAlloc(io, driver_path, gpa, .limited(world.max_stream_bytes)),
        .preload_bytes = try Io.Dir.cwd().readFileAlloc(io, preload_path, gpa, .limited(world.max_stream_bytes)),
    };
    return harness_value.?;
}

/// What a served build's record line covers besides the output tree and
/// the golden (`run_hash.lineWith`).
pub fn inputs(arena: Allocator, h: Harness, requests: []const u8) !run_hash.Page {
    return .{ .dom = id, .inputs = try arena.dupe(run_hash.Page.Input, &.{
        .{ .name = "driver", .bytes = h.driver_bytes },
        .{ .name = "preload", .bytes = h.preload_bytes },
        .{ .name = "requests", .bytes = requests },
    }) };
}
