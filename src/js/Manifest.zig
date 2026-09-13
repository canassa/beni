//! A package manifest, `beni.json` (docs/design/boundary.md §2).
//!
//! **The manifest key is what makes a package privileged.** Elm compares the
//! package author against two GitHub organisation names; here a package
//! declares itself a platform and §4's three checks are what make that safe.
//! The difference matters: none of Evan's four stated reasons for the author
//! list is a property of *who wrote the code*, and making privilege a role
//! is what lets anyone ship a Bun platform, a Deno platform or a Workers
//! platform without a compiler change (§5.1).
//!
//! M3a reads exactly four keys, and M4's package manifest will be a superset
//! rather than a replacement:
//!
//! ```json
//! { "platform": true, "name": "node", "program": "Node.Program", "runtime": "runtime.js" }
//! ```
//!
//! - `platform` — this package may write `foreign` (§2). An ordinary package
//!   omits it and gets `foreign_outside_platform` for trying.
//! - `name` — what `--platform=<name>` matches.
//! - `program` — the module-qualified opaque type `main` must have (§5).
//! - `runtime` — the JavaScript file, relative to the package root, whose
//!   `run` export is handed `main`'s value. This is §5.2's "a platform
//!   declares its output shape", at the smallest size that is still a real
//!   declaration rather than a hardcoded one.
//!
//! An unknown key is ignored rather than rejected: a manifest is a forward
//! compatibility surface, and M4 adds to it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Manifest = @This();

pub const file_name = "beni.json";

/// Largest manifest read. A manifest is a handful of keys; a file bigger
/// than this is a mistake or an attack, and failing loudly beats allocating
/// whatever is on disk.
pub const max_bytes = 64 * 1024;

/// Owned by the arena the caller passed to `parse`.
platform: bool = false,
name: ?[]const u8 = null,
program: ?[]const u8 = null,
runtime: ?[]const u8 = null,

pub const ParseError = error{
    /// Not JSON, or not a JSON object.
    Malformed,
} || Allocator.Error;

/// Parse `bytes`. Strings in the result are owned by `arena`.
pub fn parse(arena: Allocator, bytes: []const u8) ParseError!Manifest {
    const Schema = struct {
        platform: ?bool = null,
        name: ?[]const u8 = null,
        program: ?[]const u8 = null,
        runtime: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSliceLeaky(Schema, arena, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Malformed,
    };
    return .{
        .platform = parsed.platform orelse false,
        .name = parsed.name,
        .program = parsed.program,
        .runtime = parsed.runtime,
    };
}

pub const ReadError = ParseError || error{ReadFailed};

/// Read `<dir>/beni.json`. Null when there is no manifest, which is the
/// ordinary case: a package without one is an ordinary package.
pub fn read(arena: Allocator, io: Io, dir: []const u8) ReadError!?Manifest {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ dir, file_name }) catch return error.ReadFailed;
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ReadFailed,
    };
    return try parse(arena, bytes);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a manifest that declares a platform" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(),
        \\{ "platform": true, "name": "node", "program": "Node.Program", "runtime": "runtime.js" }
    );
    try testing.expect(m.platform);
    try testing.expectEqualStrings("node", m.name.?);
    try testing.expectEqualStrings("Node.Program", m.program.?);
    try testing.expectEqualStrings("runtime.js", m.runtime.?);
}

test "an ordinary package, and forward compatibility" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(),
        \\{ "name": "my-app", "dependencies": { "core": "1.0.0" } }
    );
    try testing.expect(!m.platform);
    try testing.expectEqualStrings("my-app", m.name.?);
    try testing.expectEqual(@as(?[]const u8, null), m.program);
}

test "malformed manifests are reported, not guessed at" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.Malformed, parse(arena.allocator(), "not json"));
    try testing.expectError(error.Malformed, parse(arena.allocator(), "[1, 2]"));
    try testing.expectError(error.Malformed, parse(arena.allocator(),
        \\{ "platform": "yes" }
    ));
}
