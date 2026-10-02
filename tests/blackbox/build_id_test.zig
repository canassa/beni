//! Two compilers, one cache directory (`docs/design/fast-compiler.md` §8,
//! *The compiler build id*; `src/build_id.zig`).
//!
//! A cache entry is keyed by the compiler that wrote it, and the build id is
//! that term: it must move whenever anything the binary is built from moves,
//! or a compiler serves another's entries — a wrong answer that depends on
//! which compiler ran in that directory before. `build.zig` builds a second
//! ReleaseSafe compiler, `zig-out/variant/bin/beni`, that differs from the
//! one under test in its embedded core alone (one more module,
//! `BuildVariant`); every run here has both.
//!
//! `--core-root` is the same question asked of one binary: a core read from
//! disk and the embedded one, against one cache directory.
//!
//! Boundary 2: the emitted programs run under Node. Nothing here imports a
//! compiler internal.

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;

/// The variant compiler's absolute path, or a failure naming the variable:
/// `build.zig` sets it on every run of this file.
fn variantExe(w: *World) ![]const u8 {
    return world.variantExePath(w.arena.allocator()) orelse {
        std.debug.print("BENI_VARIANT_EXE is not set: run this file through `zig build test-blackbox-build-id`\n", .{});
        return error.NoVariantCompiler;
    };
}

/// `beni version`'s build id: its last word.
fn buildId(version: []const u8) []const u8 {
    const line = std.mem.trimEnd(u8, version, "\n");
    const space = std.mem.lastIndexOfScalar(u8, line, ' ') orelse return line;
    return line[space + 1 ..];
}

/// Every file of `got_dir` is the file of the same name in `want_dir`, and
/// there are no others.
fn expectSameTree(w: *World, want_dir: []const u8, got_dir: []const u8) !void {
    const arena = w.arena.allocator();
    const want = try w.listFiles(want_dir);
    const got = try w.listFiles(got_dir);
    try testing.expect(want.len > 1);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |a, b| {
        try testing.expectEqualStrings(a, b);
        const want_bytes = try w.read(try std.fs.path.join(arena, &.{ want_dir, a }));
        const got_bytes = try w.read(try std.fs.path.join(arena, &.{ got_dir, b }));
        testing.expectEqualStrings(want_bytes, got_bytes) catch |err| {
            std.debug.print("{s} differs between {s} and {s}\n", .{ a, want_dir, got_dir });
            return err;
        };
    }
}

test "two compilers that differ only in their embedded core have different build ids" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The id is the cache's whole notion of "this compiler", so an input the
    // binary carries that the id leaves out is two compilers sharing one
    // name. The embedded core is such an input.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const variant = try variantExe(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const shipped = try w.run(&.{"version"});
    const other = try w.runWith(&.{"version"}, .{ .exe = variant });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), shipped.exit_code);
    try testing.expectEqual(@as(u8, 0), other.exit_code);
    // One version, two compilers.
    try testing.expectEqualStrings(
        shipped.stdout[0 .. shipped.stdout.len - buildId(shipped.stdout).len - 1],
        other.stdout[0 .. other.stdout.len - buildId(other.stdout).len - 1],
    );
    try testing.expectEqual(@as(usize, 32), buildId(shipped.stdout).len);
    try testing.expect(!std.mem.eql(u8, buildId(shipped.stdout), buildId(other.stdout)));
}

test "two compilers that differ only in their embedded core share a cache and each builds its own program" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A program only the variant's core can build. Each compiler runs
    // against the cache the other just wrote, and each must say what it says
    // with no cache at all.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const variant = try variantExe(&w);
    try w.write("Main.beni",
        \\import BuildVariant
        \\import Node
        \\
        \\
        \\main : Node.Program
        \\main =
        \\    Node.print BuildVariant.marker
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const variant_cold = try w.runWith(&.{ "build", "--platform=node", "--cache-dir=cache", "--out=v1", "Main.beni" }, .{ .exe = variant });
    const shipped_shared = try w.runWith(&.{ "build", "--platform=node", "--cache-dir=cache", "--out=s1", "Main.beni" }, .{ .raw_diagnostics = true });
    const shipped_alone = try w.runWith(&.{ "build", "--platform=node", "--no-cache", "--out=s2", "Main.beni" }, .{ .raw_diagnostics = true });
    const variant_warm = try w.runWith(&.{ "build", "--platform=node", "--cache-dir=cache", "--out=v2", "Main.beni" }, .{ .exe = variant });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), variant_cold.exit_code);
    try testing.expectEqualStrings("", variant_cold.stderr);
    // The shipped compiler has no `BuildVariant`, whatever the cache holds.
    try testing.expectEqual(@as(u8, 1), shipped_alone.exit_code);
    try testing.expect(std.mem.indexOf(u8, shipped_alone.stderr, "BuildVariant") != null);
    try testing.expectEqual(shipped_alone.exit_code, shipped_shared.exit_code);
    try testing.expectEqualStrings(shipped_alone.stderr, shipped_shared.stderr);
    try testing.expectEqual(@as(u8, 0), variant_warm.exit_code);
    try testing.expectEqualStrings("", variant_warm.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("s1/_main.mjs"));
    try expectSameTree(&w, "v1", "v2");
    try w.expectProgram("v2/_main.mjs", .{ .stdout = "variant\n" });
}

test "a core read with --core-root and the embedded core share a cache, and each builds with its own" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The same module, `String`, with the same interface and a different
    // body: the case a cache keyed on anything coarser than the bytes would
    // serve to the wrong core.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    try w.copyTreeInto("core", "mycore", "_");
    const string = try w.read("mycore/String.beni");
    const from_int = "\nfromInt n =";
    if (std.mem.count(u8, string, from_int) != 1) return error.CoreChanged;
    try w.write("mycore/String.beni", try std.mem.replaceOwned(u8, arena, string, from_int,
        \\
        \\fromInt n =
        \\    append "core-root " (fromIntShipped n)
        \\
        \\
        \\fromIntShipped : Int → String
        \\fromIntShipped n =
    ));
    try w.write("Main.beni",
        \\import Node
        \\
        \\
        \\main : Node.Program
        \\main =
        \\    Node.print (String.fromInt 7)
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const embedded_cold = try w.run(&.{ "build", "--platform=node", "--cache-dir=cache", "--out=e1", "Main.beni" });
    const root_cold = try w.run(&.{ "build", "--platform=node", "--cache-dir=cache", "--core-root=mycore", "--out=r1", "Main.beni" });
    const embedded_warm = try w.run(&.{ "build", "--platform=node", "--cache-dir=cache", "--out=e2", "Main.beni" });
    const root_warm = try w.run(&.{ "build", "--platform=node", "--cache-dir=cache", "--core-root=mycore", "--out=r2", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for ([_]world.Result{ embedded_cold, root_cold, embedded_warm, root_warm }) |r| {
        try testing.expectEqual(@as(u8, 0), r.exit_code);
        try testing.expectEqualStrings("", r.stderr);
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try expectSameTree(&w, "e1", "e2");
    try expectSameTree(&w, "r1", "r2");
    try w.expectProgram("e2/_main.mjs", .{ .stdout = "7\n" });
    try w.expectProgram("r2/_main.mjs", .{ .stdout = "core-root 7\n" });
}
