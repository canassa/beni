//! Run hashes (`run_hash.zig`), through the corpus walker itself: the
//! walker binary (`BENI_CORPUS_TEST_EXE`, installed by `build.zig`) is run
//! as a program against a corpus of the scenario's own, a `run/` directory
//! in the world's project, and what it did is read from the files it leaves:
//! the `.run-hash` records, and the counts `BENI_RUN_HASH_REPORT` makes it
//! write — how many builds it did not run under Node, how many it ran
//! because their digest was not recorded, and, recording, how many lines it
//! wrote and how many builds it refused one.
//!
//! No `BENI_CORPUS_PART` is given, so one walker process runs both builds
//! of each fixture, development first, the way `zig build test-run-hashes`
//! does.

const std = @import("std");
const testing = std.testing;
const world = @import("world.zig");
const World = world.World;

const hello =
    \\import Node exposing (Program)
    \\
    \\
    \\main : Program
    \\main =
    \\    Node.printLines [ "hello" ]
    \\
;

/// The same output as `hello`, from a program that emits different
/// JavaScript.
const hello_joined =
    \\import Node exposing (Program)
    \\
    \\
    \\main : Program
    \\main =
    \\    Node.printLines [ "hel" ++ "lo" ]
    \\
;

const goodbye =
    \\import Node exposing (Program)
    \\
    \\
    \\main : Program
    \\main =
    \\    Node.printLines [ "goodbye" ]
    \\
;

/// Run the corpus walker over `corpus/` in the world's project, with
/// `BENI_RUN_HASHES=<mode>` ("" to check), writing its counts into
/// `counts/`.
fn walker(w: *World, mode: []const u8) !world.Result {
    const arena = w.arena.allocator();
    var env = std.process.Environ.Map.init(arena);
    // The walker finds Node on `PATH`, as the build's own runs of it do.
    try env.put("PATH", try testing.environ.getAlloc(arena, "PATH"));
    try env.put("BENI_EXE", w.exe);
    try env.put("BENI_CORPUS_ROOT", "corpus");
    try env.put("BENI_RUN_HASHES", mode);
    try env.put("BENI_RUN_HASH_REPORT", "counts");
    const argv = try arena.dupe([]const u8, &.{try testing.environ.getAlloc(arena, "BENI_CORPUS_TEST_EXE")});
    return world.spawnAndCaptureIn(arena, w.io, argv, .{ .dir = w.tmp.dir }, world.default_timeout_ms, &env);
}

/// `node --version`: what every record line names after its build.
fn nodeVersion(w: *World) ![]const u8 {
    const arena = w.arena.allocator();
    const r = try world.spawnAndCapture(arena, w.gpa, w.io, &.{ w.node_exe orelse return error.NodeNotOnPath, "--version" }, .inherit, world.default_timeout_ms);
    try testing.expectEqual(0, r.exit_code);
    return std.mem.trim(u8, r.stdout, "\n");
}

/// Assert `record` is exactly one `<build> <node version> <sha-256 hex>`
/// line per build of `builds`, in order.
fn expectRecord(w: *World, record: []const u8, builds: []const []const u8) !void {
    const version = try nodeVersion(w);
    var lines = std.mem.splitScalar(u8, record, '\n');
    for (builds) |build| {
        const line = lines.next() orelse return error.RecordTooShort;
        var fields = std.mem.splitScalar(u8, line, ' ');
        try testing.expectEqualStrings(build, fields.next().?);
        try testing.expectEqualStrings(version, fields.next() orelse return error.NoVersion);
        const digest = fields.next() orelse return error.NoDigest;
        try testing.expectEqual(64, digest.len);
        for (digest) |ch| try testing.expect(std.ascii.isDigit(ch) or (ch >= 'a' and ch <= 'f'));
        try testing.expectEqual(null, fields.next());
    }
    // The file ends in a newline and holds nothing else.
    try testing.expectEqualStrings("", lines.next().?);
    try testing.expectEqual(null, lines.next());
}

fn counts(skipped: u32, stale: u32, recorded: u32, refused: u32) ![]const u8 {
    return std.fmt.allocPrint(testing.allocator, "skipped {d}\nstale {d}\nrecorded {d}\nrefused {d}\n", .{ skipped, stale, recorded, refused });
}

fn expectCounts(w: *World, skipped: u32, stale: u32, recorded: u32, refused: u32) !void {
    const want = try counts(skipped, stale, recorded, refused);
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, try w.read("counts/all.txt"));
}

fn expectExit(want: u8, r: world.Result) !void {
    if (r.exit_code != want) std.debug.print("--- stdout ---\n{s}\n--- stderr ---\n{s}\n", .{ r.stdout, r.stderr });
    try testing.expectEqual(want, r.exit_code);
}

test "a build whose run hash is recorded is not run under Node" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("corpus/run/Hello.beni", hello);
    try w.write("corpus/run/Hello.expected", "hello\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const recording = try walker(&w, "record");
    try expectExit(0, recording);
    try expectCounts(&w, 0, 0, 2, 0);
    const record = try w.read("corpus/run/Hello.run-hash");
    const checking = try walker(&w, "");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(0, checking);
    try expectRecord(&w, record, &.{ "dev", "release" });
    // Both builds skipped, neither ran.
    try expectCounts(&w, 2, 0, 0, 0);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // Checking never writes a record.
    try testing.expectEqualStrings(record, try w.read("corpus/run/Hello.run-hash"));
}

test "a program whose output changed runs under Node though its golden still matches" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("corpus/run/Hello.beni", hello);
    try w.write("corpus/run/Hello.expected", "hello\n");
    try expectExit(0, try walker(&w, "record"));
    const record = try w.read("corpus/run/Hello.run-hash");
    try w.write("corpus/run/Hello.beni", hello_joined);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try walker(&w, "");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(0, r);
    try expectCounts(&w, 0, 2, 0, 0);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings(record, try w.read("corpus/run/Hello.run-hash"));
}

test "a changed program with a stale run hash that prints the wrong thing fails" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("corpus/run/Hello.beni", hello);
    try w.write("corpus/run/Hello.expected", "hello\n");
    try expectExit(0, try walker(&w, "record"));
    const record = try w.read("corpus/run/Hello.run-hash");
    try w.write("corpus/run/Hello.beni", goodbye);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try walker(&w, "");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(1, r);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "FAIL corpus/run/Hello.beni: GoldenMismatch") != null);
    // The development build ran, failed, and ended the case.
    try expectCounts(&w, 0, 1, 0, 0);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings(record, try w.read("corpus/run/Hello.run-hash"));
}

test "an edited golden makes a recorded run hash stale" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("corpus/run/Hello.beni", hello);
    try w.write("corpus/run/Hello.expected", "hello\n");
    try expectExit(0, try walker(&w, "record"));
    try w.write("corpus/run/Hello.expected", "hullo\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try walker(&w, "");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(1, r);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "FAIL corpus/run/Hello.beni: GoldenMismatch") != null);
    try expectCounts(&w, 0, 1, 0, 0);
}

test "recording writes no run hash for a program whose output does not match" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("corpus/run/Good.beni", hello);
    try w.write("corpus/run/Good.expected", "hello\n");
    try w.write("corpus/run/Wrong.beni", hello);
    try w.write("corpus/run/Wrong.expected", "goodbye\n");
    // A record from when the golden matched does not survive a recording
    // that no longer matches.
    try w.write("corpus/run/Wrong.run-hash", "dev v0.0.0 0000000000000000000000000000000000000000000000000000000000000000\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try walker(&w, "record");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(1, r);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "FAIL corpus/run/Wrong.beni: GoldenMismatch") != null);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "FAIL corpus/run/Good.beni") == null);
    // Both builds of each program ran; only `Good`'s two were recorded.
    try expectCounts(&w, 0, 0, 2, 2);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try expectRecord(&w, try w.read("corpus/run/Good.run-hash"), &.{ "dev", "release" });
    try testing.expect(!w.exists("corpus/run/Wrong.run-hash"));
}
