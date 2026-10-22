//! The harness of a `workers/` fixture (docs/design/boundary.md §9.12 (k);
//! tests/corpus/README.md, *A Worker*): where its driver is, how Miniflare
//! is found, and what a build's record line covers beyond a plain `run/`
//! one's.
//!
//! Such a fixture is a Worker. `tests/workers/driver.mjs` starts the build
//! under Miniflare — the `workerd` that nixpkgs' `wrangler` carries, found
//! through `BENI_MINIFLARE` (`nix develop .#workers`) and handed to the
//! driver as an argument, since a spawned program gets an empty environment
//! — sends the script's requests and prints a transcript: each request and
//! its answer, with what the Worker wrote to its console. The port never
//! appears in it, so the transcript is the golden. The record line's digest
//! (`run_hash.lineWith`) covers the driver's bytes, the script and the
//! Wrangler configuration as well as the output tree, the golden and the
//! Node version, so a change to any of them runs the Worker again.

const std = @import("std");
const world = @import("world.zig");
const run_hash = @import("run_hash.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The driver, relative to the repository root.
pub const driver_path = "tests/workers/driver.mjs";

/// The name on the record line where a `browser/` line has its DOM's.
pub const id = "workers";

/// The harness's files, resolved once per process from the working
/// directory, which is the repository root in every run the build makes.
pub const Harness = struct {
    /// Absolute, for a driver that runs in a fixture's project directory.
    driver: []const u8,
    driver_bytes: []const u8,
    /// Miniflare's entry file, `BENI_MINIFLARE`; empty when it is not set,
    /// when every `workers/` case fails and says so.
    miniflare: []const u8,
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
        .miniflare = std.testing.environ.getAlloc(gpa, "BENI_MINIFLARE") catch "",
    };
    return harness_value.?;
}

/// What a Worker build's record line covers besides the output tree and
/// the golden (`run_hash.lineWith`): the driver, the script and the
/// configuration. Not Miniflare's path: the versions are nixpkgs' pin, and
/// a path that moves with the store would stale every line for nothing.
pub fn inputs(arena: Allocator, h: Harness, steps: []const u8, config: []const u8) !run_hash.Page {
    return .{ .dom = id, .inputs = try arena.dupe(run_hash.Page.Input, &.{
        .{ .name = "driver", .bytes = h.driver_bytes },
        .{ .name = "steps", .bytes = steps },
        .{ .name = "wrangler", .bytes = config },
    }) };
}
