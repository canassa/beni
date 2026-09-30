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
//!
//! The scenario programs' index is driven the same way, through
//! `run_hash_probe.zig` (`BENI_RUN_HASH_PROBE_EXE`): a test binary whose one
//! test builds and runs a program the environment describes, on an index in
//! the world's project, followed by the summary tool
//! (`BENI_RUN_HASH_SUMMARY_EXE`) where a recording merges into the index.
//!
//! These scenarios run Node on purpose, and every time: what they test is
//! whether a run is skipped, so a skip of their own would test nothing.

const std = @import("std");
const testing = std.testing;
const world = @import("world.zig");
const World = world.World;
const run_hash = @import("run_hash.zig");

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
/// JavaScript in both builds — a call, which a release build cannot fold
/// into the literal `hello` has (it did fold `"hel" ++ "lo"`).
const hello_joined =
    \\import Node exposing (Program)
    \\
    \\
    \\main : Program
    \\main =
    \\    Node.printLines [ String.toLower "HELLO" ]
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

/// `node --version`: what every record line names after its build — the
/// build's answer, asked once for every test process.
fn nodeVersion(w: *World) ![]const u8 {
    return run_hash.nodeVersion(w);
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

/// The index line id of the probe's one program run.
const probe_id = "run_hash_probe.test.the program the scenario describes does what it expects #0";

const ProbeMode = enum { check, record };

/// Run the probe binary in the world's project: `source` built and
/// expected to print `stdout`, against `index.txt`, reporting into
/// `report_dir`. `with_node` false hands it the Node version and a `PATH`
/// with nothing on it, so a probe that started Node would fail.
fn probe(w: *World, mode: ProbeMode, source: []const u8, stdout: []const u8, report_dir: []const u8, with_node: bool) !world.Result {
    const arena = w.arena.allocator();
    var env = std.process.Environ.Map.init(arena);
    try env.put("PATH", if (with_node) try testing.environ.getAlloc(arena, "PATH") else "");
    try env.put("BENI_EXE", w.exe);
    try env.put("BENI_RUN_HASH_INDEX", "index.txt");
    try env.put("BENI_RUN_HASHES", if (mode == .record) "record" else "");
    try env.put("BENI_RUN_HASH_REPORT", report_dir);
    try env.put("BENI_PROBE_SOURCE", source);
    try env.put("BENI_PROBE_STDOUT", stdout);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, try testing.environ.getAlloc(arena, "BENI_RUN_HASH_PROBE_EXE"));
    if (!with_node) try argv.append(arena, try std.fmt.allocPrint(arena, "--node-version={s}", .{try nodeVersion(w)}));
    return world.spawnAndCaptureIn(arena, w.io, argv.items, .{ .dir = w.tmp.dir }, world.default_timeout_ms, &env);
}

/// Merge the recording reported into `report_dir` into `index.txt`, as
/// `zig build test-run-hashes` does after its last process.
fn merge(w: *World, report_dir: []const u8) !void {
    const arena = w.arena.allocator();
    var env = std.process.Environ.Map.init(arena);
    const argv = try arena.dupe([]const u8, &.{ try testing.environ.getAlloc(arena, "BENI_RUN_HASH_SUMMARY_EXE"), report_dir, "--index=index.txt" });
    try expectExit(0, try world.spawnAndCaptureIn(arena, w.io, argv, .{ .dir = w.tmp.dir }, world.default_timeout_ms, &env));
}

/// Assert the counts the probe wrote into `report_dir`, its one report.
fn expectProgramCounts(w: *World, report_dir: []const u8, skipped: u32, stale: u32, recorded: u32, refused: u32) !void {
    const arena = w.arena.allocator();
    var got: ?[]const u8 = null;
    for (try w.listFiles(report_dir)) |name| if (std.mem.endsWith(u8, name, ".txt")) {
        try testing.expectEqual(null, got);
        got = try w.read(try std.fmt.allocPrint(arena, "{s}/{s}", .{ report_dir, name }));
    };
    const want = try std.fmt.allocPrint(arena, "program_skipped {d}\nprogram_stale {d}\nprogram_recorded {d}\nprogram_refused {d}\n", .{ skipped, stale, recorded, refused });
    try testing.expectEqualStrings(want, got orelse return error.NoProgramCounts);
}

/// Assert `index` is exactly the probe's line, with a SHA-256 digest.
fn expectIndexOfProbe(index: []const u8) !void {
    try testing.expect(std.mem.startsWith(u8, index, probe_id ++ " "));
    const digest = index[probe_id.len + 1 ..];
    try testing.expectEqual(64 + 1, digest.len);
    for (digest[0..64]) |ch| try testing.expect(std.ascii.isDigit(ch) or (ch >= 'a' and ch <= 'f'));
    try testing.expectEqual('\n', digest[64]);
}

test "a scenario program whose run hash is recorded is not run under Node" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const recording = try probe(&w, .record, hello, "hello\n", "recorded", true);
    try expectExit(0, recording);
    try expectProgramCounts(&w, "recorded", 0, 0, 1, 0);
    try merge(&w, "recorded");
    const index = try w.read("index.txt");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // No Node on `PATH`: a run that started it would fail.
    const checking = try probe(&w, .check, hello, "hello\n", "checked", false);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(0, checking);
    try expectIndexOfProbe(index);
    try expectProgramCounts(&w, "checked", 1, 0, 0, 0);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // Checking never writes the index, nor a record for it.
    try testing.expectEqualStrings(index, try w.read("index.txt"));
    for (try w.listFiles("checked")) |name| try testing.expect(!std.mem.endsWith(u8, name, ".records"));
}

test "a changed expectation in a scenario's code runs its recorded program under Node again" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try expectExit(0, try probe(&w, .record, hello, "hello\n", "recorded", true));
    try merge(&w, "recorded");
    const index = try w.read("index.txt");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // The same program, so the same output tree, expected to print
    // something else.
    const r = try probe(&w, .check, hello, "hullo\n", "checked", true);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // The record did not stand for the new expectation: Node ran, printed
    // `hello`, and the test failed.
    try expectExit(1, r);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "--- stdout ---\nhello\n") != null);
    try expectProgramCounts(&w, "checked", 0, 1, 0, 0);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings(index, try w.read("index.txt"));
}

test "recording writes no run hash for a scenario program that does not do what its test expects" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const other = "other_test.test.another #0 1111111111111111111111111111111111111111111111111111111111111111\n";
    // Another test's line, and a line from when this expectation held.
    try w.write("index.txt", other ++ probe_id ++ " 0000000000000000000000000000000000000000000000000000000000000000\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try probe(&w, .record, hello, "goodbye\n", "recorded", true);
    try expectProgramCounts(&w, "recorded", 0, 0, 0, 1);
    try merge(&w, "recorded");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(1, r);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "--- stdout ---\nhello\n") != null);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // The probe's line is gone and the other test's is kept.
    try testing.expectEqualStrings(other, try w.read("index.txt"));
    // The merge consumed the report.
    try testing.expect(!w.exists("recorded"));
}
