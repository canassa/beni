//! Run hashes (`run_hash.zig`), through the corpus walker itself: the
//! walker binary (`BENI_CORPUS_TEST_EXE`, installed by `build.zig`) is run
//! as a program against a corpus of the scenario's own, a `run/` directory
//! in the world's project, with a run-hash cache of its own
//! (`BENI_RUN_HASH_DIR`, the project's `cache/`), and what it did is read
//! from what it leaves: the digests in the cache, and the counts
//! `BENI_RUN_HASH_REPORT` makes it write — how many builds it did not run
//! under Node, how many it ran because the cache held no digest for them.
//!
//! No `BENI_CORPUS_PART` is given, so one walker process runs both builds
//! of each fixture, development first.
//!
//! The scenario programs' cache is driven the same way, through
//! `run_hash_probe.zig` (`BENI_RUN_HASH_PROBE_EXE`): a test binary whose one
//! test builds and runs a program the environment describes, on a cache in
//! the world's project.
//!
//! These scenarios run Node on purpose, and every time: what they test is
//! whether a run is skipped, so a skip of their own would test nothing.
//! The ones that compare digests do not run Node: they build, then read
//! the digest a scenario's run hash would record.

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

/// The cache the walker and the probe are given: `cache/` in the world's
/// project, by its absolute path, since a walk from another directory
/// (`browser_test.zig`) must find the same one.
fn cachePath(w: *World) ![]const u8 {
    return w.projectSubPath(w.arena.allocator(), "cache");
}

/// Run the corpus walker over `corpus/` in the world's project, on the
/// project's `cache/`, writing its counts into `counts/`.
fn walker(w: *World) !world.Result {
    return walkerWith(w, try cachePath(w), false);
}

/// `walker`, on `cache` (empty for no cache) and, `bless`, writing the
/// goldens instead of comparing with them.
fn walkerWith(w: *World, cache: []const u8, bless: bool) !world.Result {
    const arena = w.arena.allocator();
    var env = std.process.Environ.Map.init(arena);
    // The walker finds Node on `PATH`, as the build's own runs of it do.
    try env.put("PATH", try testing.environ.getAlloc(arena, "PATH"));
    try env.put("BENI_EXE", w.exe);
    try env.put("BENI_CORPUS_ROOT", "corpus");
    try env.put(run_hash.dir_env, cache);
    try env.put("BENI_RUN_HASH_REPORT", "counts");
    if (bless) try env.put("BENI_WRITE_EXPECTED", "1");
    const argv = try arena.dupe([]const u8, &.{try testing.environ.getAlloc(arena, "BENI_CORPUS_TEST_EXE")});
    return world.spawnAndCaptureIn(arena, w.io, argv, .{ .dir = w.tmp.dir }, world.default_timeout_ms, &env);
}

/// `node --version`: what every digest covers — the build's answer, asked
/// once for every test process.
fn nodeVersion(w: *World) ![]const u8 {
    return run_hash.nodeVersion(w);
}

/// The cache's entries, sorted: each an empty file named by a SHA-256 in
/// lower-case hex, and nothing else in the directory.
fn digests(w: *World) ![]const []const u8 {
    const files = try w.listFiles("cache");
    for (files) |name| {
        try testing.expectEqual(run_hash.digest_len, name.len);
        for (name) |ch| try testing.expect(std.ascii.isDigit(ch) or (ch >= 'a' and ch <= 'f'));
        try testing.expectEqualStrings("", try w.read(try std.fmt.allocPrint(w.arena.allocator(), "cache/{s}", .{name})));
    }
    return files;
}

/// Assert the cache holds exactly `want` entries.
fn expectDigests(w: *World, want: usize) ![]const []const u8 {
    const found = try digests(w);
    try testing.expectEqual(want, found.len);
    return found;
}

fn expectCounts(w: *World, skipped: u32, stale: u32) !void {
    const want = try std.fmt.allocPrint(w.arena.allocator(), "skipped {d}\nstale {d}\n", .{ skipped, stale });
    try testing.expectEqualStrings(want, try w.read("counts/all.txt"));
}

fn expectExit(want: u8, r: world.Result) !void {
    if (r.exit_code != want) std.debug.print("--- stdout ---\n{s}\n--- stderr ---\n{s}\n", .{ r.stdout, r.stderr });
    try testing.expectEqual(want, r.exit_code);
}

test "a build whose run hash is verified is not run under Node" {
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
    // The first walk finds an empty cache: both builds run and, matching,
    // record their digests.
    const first = try walker(&w);
    try expectExit(0, first);
    try expectCounts(&w, 0, 2);
    const recorded = try expectDigests(&w, 2);
    const second = try walker(&w);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(0, second);
    // Both builds skipped, neither ran.
    try expectCounts(&w, 2, 0);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // A skipped build writes nothing: the cache is as the first walk left it.
    try testing.expectEqualDeep(recorded, try digests(&w));
}

test "a program whose output changed runs under Node though its golden still matches" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("corpus/run/Hello.beni", hello);
    try w.write("corpus/run/Hello.expected", "hello\n");
    try expectExit(0, try walker(&w));
    const recorded = try expectDigests(&w, 2);
    try w.write("corpus/run/Hello.beni", hello_joined);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try walker(&w);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(0, r);
    try expectCounts(&w, 0, 2);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // Two more digests, the first two kept: a digest is never removed.
    const now = try expectDigests(&w, 4);
    for (recorded) |d| try testing.expect(contains(now, d));
}

test "a changed program with a verified run hash that prints the wrong thing fails" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("corpus/run/Hello.beni", hello);
    try w.write("corpus/run/Hello.expected", "hello\n");
    try expectExit(0, try walker(&w));
    const recorded = try expectDigests(&w, 2);
    try w.write("corpus/run/Hello.beni", goodbye);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try walker(&w);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(1, r);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "FAIL corpus/run/Hello.beni: GoldenMismatch") != null);
    // The development build ran, failed, and ended the case.
    try expectCounts(&w, 0, 1);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // A failed run writes nothing.
    try testing.expectEqualDeep(recorded, try digests(&w));
}

test "an edited golden makes a verified run hash stale" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("corpus/run/Hello.beni", hello);
    try w.write("corpus/run/Hello.expected", "hello\n");
    try expectExit(0, try walker(&w));
    const recorded = try expectDigests(&w, 2);
    try w.write("corpus/run/Hello.expected", "hullo\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try walker(&w);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(1, r);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "FAIL corpus/run/Hello.beni: GoldenMismatch") != null);
    try expectCounts(&w, 0, 1);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualDeep(recorded, try digests(&w));
}

test "a run that fails writes no digest, and the runs beside it that passed write theirs" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("corpus/run/Good.beni", hello);
    try w.write("corpus/run/Good.expected", "hello\n");
    try w.write("corpus/run/Wrong.beni", hello);
    try w.write("corpus/run/Wrong.expected", "goodbye\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try walker(&w);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(1, r);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "FAIL corpus/run/Wrong.beni: GoldenMismatch") != null);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "FAIL corpus/run/Good.beni") == null);
    // Good's two builds ran and Wrong's development build ran and failed.
    try expectCounts(&w, 0, 3);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // Exactly two digests, and they are Good's: a walk of Good alone skips
    // both of its builds.
    _ = try expectDigests(&w, 2);
    try w.tmp.dir.deleteFile(w.io, "corpus/run/Wrong.beni");
    try w.tmp.dir.deleteFile(w.io, "corpus/run/Wrong.expected");
    try expectExit(0, try walker(&w));
    try expectCounts(&w, 2, 0);
    _ = try expectDigests(&w, 2);
}

fn expectReported(r: world.Result, text: []const u8) !void {
    if (std.mem.indexOf(u8, r.stderr, text) == null) {
        std.debug.print("the walker's report lacks:\n{s}\n--- stderr ---\n{s}\n", .{ text, r.stderr });
        return error.NotReported;
    }
}

test "a record file that comes back into the corpus fails the walk by name, with the fix" {
    // The records left git for the cache (#881). A pull request from before
    // the change, or a rebase that kept a modified record, brings one back
    // with no conflict; every reader would ignore it. The walk refuses it.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("corpus/run/Good.beni", hello);
    try w.write("corpus/run/Good.expected", "hello\n");
    try w.write("corpus/run/Good.run-hash", "dev abc\n");
    const r = try walker(&w);
    try expectExit(1, r);
    try expectReported(r, "corpus/run/Good.run-hash: a run-hash record file; the records left git for the run-hash cache (#881): delete it");
    // Nothing ran: no digest.
    try testing.expect(!w.exists("cache"));
}

test "a page's old fuzz record is refused with the marker that replaces it" {
    // A `browser/tea` page's `.fuzz-run-hash` also opted it into its value
    // fuzz; one that comes back would silently stand where the page's
    // `.value-fuzz` marker belongs. The project form is caught too.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("corpus/run/Good.beni", hello);
    try w.write("corpus/run/Good.expected", "hello\n");
    try w.write("corpus/run/Good.fuzz-run-hash", "fuzz abc\n");
    const r = try walker(&w);
    try expectExit(1, r);
    try expectReported(r, "corpus/run/Good.fuzz-run-hash: a run-hash record file");
    try expectReported(r, "add an empty `<page>.value-fuzz` (`_expected.value-fuzz` in a project) beside the page");

    try w.tmp.dir.deleteFile(w.io, "corpus/run/Good.fuzz-run-hash");
    try w.write("corpus/run/Project/Main.beni", hello);
    try w.write("corpus/run/Project/_expected", "hello\n");
    try w.write("corpus/run/Project/_expected.release-run-hash", "release abc\n");
    const p = try walker(&w);
    try expectExit(1, p);
    try expectReported(p, "corpus/run/Project/_expected.release-run-hash: a run-hash record file");
}

test "the old run-hash index beside the corpus fails the walk" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("corpus/run/Good.beni", hello);
    try w.write("corpus/run/Good.expected", "hello\n");
    try w.write("blackbox/run-hashes.txt", "# the index\n");
    const r = try walker(&w);
    try expectExit(1, r);
    try expectReported(r, "blackbox/run-hashes.txt: the run-hash index; it left git for the run-hash cache (#881): delete it");
}

test "a blessed build looks nothing up and writes no digest; the pass compared with its golden is recorded" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The development build's golden is written from its output, not
    // compared with it: that is no verdict to cache. The release build is
    // compared with the golden the development build just wrote, as always
    // (`.expected` is the development build's golden), so it is verified
    // and recorded. The next ordinary run compares the development build
    // and records it.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("corpus/run/Hello.beni", hello);
    try w.write("corpus/run/Hello.expected", "stale\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try walkerWith(&w, try cachePath(&w), true);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(0, r);
    try testing.expectEqualStrings("hello\n", try w.read("corpus/run/Hello.expected"));
    // Only the release build was looked up, and it ran.
    try expectCounts(&w, 0, 1);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // The release build's digest alone; the next walk runs the development
    // build, records it, and skips the release build.
    _ = try expectDigests(&w, 1);
    try expectExit(0, try walker(&w));
    try expectCounts(&w, 1, 1);
    _ = try expectDigests(&w, 2);
}

test "without a cache directory every program runs and nothing is written" {
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
    try expectExit(0, try walkerWith(&w, "", false));
    try expectCounts(&w, 0, 2);
    const again = try walkerWith(&w, "", false);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(0, again);
    try expectCounts(&w, 0, 2);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("cache"));
}

/// The digest the concurrent writers record: any 64 hex digits name an
/// entry.
const shared_digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

test "eight writers that record one digest at the same time all succeed and leave one file" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The gates run many test processes at once, and two can verify the
    // same program: each writes an unnamed file and renames it over the
    // final name, so none fails on the other's entry.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const dir = try cachePath(&w);
    const Writer = struct {
        dir: []const u8,
        failures: *std.atomic.Value(u32),
        fn go(r: @This()) void {
            for (0..25) |_| run_hash.recordIn(testing.io, r.dir, shared_digest) catch {
                _ = r.failures.fetchAdd(1, .monotonic);
            };
        }
    };
    var failures: std.atomic.Value(u32) = .init(0);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Writer.go, .{Writer{ .dir = dir, .failures = &failures }});
    for (threads) |t| t.join();

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(0, failures.load(.monotonic));
    try testing.expect(try run_hash.verifiedIn(testing.io, dir, shared_digest));

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // One entry, and no unnamed file left behind.
    const found = try expectDigests(&w, 1);
    try testing.expectEqualStrings(shared_digest, found[0]);
}

test "a digest that is not 64 lower-case hex digits names no entry" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The digest is the file's name: anything else would name a file the
    // caller did not mean, `../x` included.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const dir = try cachePath(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY                        │
    // └─────────────────────────────────────────┘
    try testing.expectError(error.MalformedDigest, run_hash.recordIn(testing.io, dir, "../escape"));
    try testing.expectError(error.MalformedDigest, run_hash.recordIn(testing.io, dir, shared_digest[0..63]));
    try testing.expectError(error.MalformedDigest, run_hash.verifiedIn(testing.io, dir, "0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef"));
    try testing.expect(!w.exists("cache"));
}

/// Run the probe binary in the world's project: `source` built and
/// expected to print `stdout`, against the project's `cache/`, reporting
/// into `report_dir`. `with_node` false hands it the Node version and a
/// `PATH` with nothing on it, so a probe that started Node would fail.
fn probe(w: *World, source: []const u8, stdout: []const u8, report_dir: []const u8, with_node: bool) !world.Result {
    const arena = w.arena.allocator();
    var env = std.process.Environ.Map.init(arena);
    try env.put("PATH", if (with_node) try testing.environ.getAlloc(arena, "PATH") else "");
    try env.put("BENI_EXE", w.exe);
    try env.put(run_hash.dir_env, try cachePath(w));
    try env.put("BENI_RUN_HASH_REPORT", report_dir);
    try env.put("BENI_PROBE_SOURCE", source);
    try env.put("BENI_PROBE_STDOUT", stdout);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, try testing.environ.getAlloc(arena, "BENI_RUN_HASH_PROBE_EXE"));
    if (!with_node) try argv.append(arena, try std.fmt.allocPrint(arena, "--node-version={s}", .{try nodeVersion(w)}));
    return world.spawnAndCaptureIn(arena, w.io, argv.items, .{ .dir = w.tmp.dir }, world.default_timeout_ms, &env);
}

/// Assert the counts the probe wrote into `report_dir`, its one report.
fn expectProgramCounts(w: *World, report_dir: []const u8, skipped: u32, stale: u32) !void {
    const arena = w.arena.allocator();
    var got: ?[]const u8 = null;
    for (try w.listFiles(report_dir)) |name| if (std.mem.endsWith(u8, name, ".txt")) {
        try testing.expectEqual(null, got);
        got = try w.read(try std.fmt.allocPrint(arena, "{s}/{s}", .{ report_dir, name }));
    };
    const want = try std.fmt.allocPrint(arena, "program_skipped {d}\nprogram_stale {d}\n", .{ skipped, stale });
    try testing.expectEqualStrings(want, got orelse return error.NoProgramCounts);
}

test "a scenario program whose run hash is verified is not run under Node" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const first = try probe(&w, hello, "hello\n", "first", true);
    try expectExit(0, first);
    try expectProgramCounts(&w, "first", 0, 1);
    const recorded = try expectDigests(&w, 1);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // No Node on `PATH`: a run that started it would fail.
    const second = try probe(&w, hello, "hello\n", "second", false);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(0, second);
    try expectProgramCounts(&w, "second", 1, 0);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualDeep(recorded, try digests(&w));
}

test "a changed expectation in a scenario's code runs its verified program under Node again" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try expectExit(0, try probe(&w, hello, "hello\n", "first", true));
    const recorded = try expectDigests(&w, 1);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // The same program, so the same output tree, expected to print
    // something else.
    const r = try probe(&w, hello, "hullo\n", "second", true);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // The digest did not stand for the new expectation: Node ran, printed
    // `hello`, and the test failed.
    try expectExit(1, r);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "--- stdout ---\nhello\n") != null);
    try expectProgramCounts(&w, "second", 0, 1);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // A failed run writes nothing.
    try testing.expectEqualDeep(recorded, try digests(&w));
}

test "a scenario program that does not do what its test expects writes no digest" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try probe(&w, hello, "goodbye\n", "report", true);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(1, r);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "--- stdout ---\nhello\n") != null);
    try expectProgramCounts(&w, "report", 0, 1);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("cache"));
}

test "a scenario's run hash covers the emitted output and the expectation, not the build cache" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A script in the project directory used to make the digest cover every
    // file there, `.beni-cache` included. A cache entry names the compiler
    // that wrote it, so any change under `src/` staled the digest even when
    // the emitted JavaScript was identical. The digest covers the output
    // tree and the expectation, as a `run/` digest does.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", hello);
    const built = try w.run(&.{ "build", "--platform=node", "--out=out", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), built.exit_code);
    try testing.expect(w.exists(".beni-cache"));
    const script =
        \\await import("./out/_main.mjs");
        \\
    ;
    try w.write("check.mjs", script);
    const expected: world.Expected = .{ .stdout = "hello\n" };

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const digest = try requireDigest(&w, "check.mjs", expected);
    const in_tree = try requireDigest(&w, "out/_main.mjs", expected);
    try w.write(".beni-cache/noise.txt", "not part of the program\n");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // A cache entry is not the emitted program, for a script in the
    // project directory or for one inside the output tree.
    try testing.expectEqualStrings(digest, try requireDigest(&w, "check.mjs", expected));
    try testing.expectEqualStrings(in_tree, try requireDigest(&w, "out/_main.mjs", expected));
    // Nor is a source the build did not compile again.
    try w.write("Main.beni", hello ++ "\n\n-- the build did not see this\n");
    try testing.expectEqualStrings(digest, try requireDigest(&w, "check.mjs", expected));
    // The expectation, the emitted bytes and the script are.
    try testing.expect(!std.mem.eql(u8, digest, try requireDigest(&w, "check.mjs", .{ .stdout = "goodbye\n" })));
    const js = try w.read("out/_main.mjs");
    try w.write("out/_main.mjs", try std.mem.concat(w.arena.allocator(), u8, &.{ js, "\n" }));
    const emitted = try requireDigest(&w, "check.mjs", expected);
    try testing.expect(!std.mem.eql(u8, digest, emitted));
    try w.write("check.mjs", "console.log(\"hello\");\n");
    try testing.expect(!std.mem.eql(u8, emitted, try requireDigest(&w, "check.mjs", expected)));

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // Nothing here runs Node.
    try testing.expect(w.exists(".beni-cache/noise.txt"));
}

test "a directory the run-hash walk cannot open fails the digest" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // Skipping the directory would hash fewer files and still succeed.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("check.mjs", "console.log(\"x\");\n");
    try w.write("sealed/note.txt", "x\n");
    defer w.restoreDirMode("sealed");
    if (!try w.setMode("sealed", 0)) {
        std.debug.print("skipping: chmod 000 did not make the directory unreadable (running as root?)\n", .{});
        return;
    }

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const opened = run_hash.programRunDigest(&w, "check.mjs", .{ .stdout = "x\n" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectError(error.AccessDenied, opened);
}

test "a beni manifest at the project root is refused" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // No scenario builds with `--out=.`. Hashing that manifest would cover
    // the project's top-level files and miss nested output such as `_core/`.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("check.mjs", "console.log(\"x\");\n");
    try w.write("_manifest.txt", "notes\n");
    const expected: world.Expected = .{ .stdout = "x\n" };

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const digest = try requireDigest(&w, "check.mjs", expected);
    try w.write("_manifest.txt", "notes changed\n");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // A file of that name that is not a beni manifest is not an output tree.
    try testing.expectEqualStrings(digest, try requireDigest(&w, "check.mjs", expected));
    try w.write("_manifest.txt", "beni-manifest 1\n");
    try testing.expectError(error.ProjectRootOutput, run_hash.programRunDigest(&w, "check.mjs", expected));
}

fn requireDigest(w: *World, script: []const u8, expected: world.Expected) ![]const u8 {
    return try run_hash.programRunDigest(w, script, expected) orelse return error.NoDigest;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |entry| if (std.mem.eql(u8, entry, item)) return true;
    return false;
}
