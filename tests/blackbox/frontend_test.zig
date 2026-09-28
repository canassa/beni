//! `--roundtrip-frontend` as an IDENTITY ORACLE (`plans/m4-2.md` §9.2,
//! `fast-compiler.md` §8's *The front-end artifacts, and the file key*).
//!
//! **This is the front-end cache's cut line.** Everything risky about the front-end artifact
//! — the symbol column travelling as text and being re-interned into a
//! worker's own pool, the token columns losing two of four, the `Bir` being
//! reached by raw index by four later passes — is settled here, with no cache
//! directory in sight and no byte written to one. The cache's disk I/O is
//! built on top of a format that is already known to be lossless.
//!
//! A build through all three `--roundtrip-*` flags is `iface_test.zig`'s,
//! on a project whose evidence crosses modules. What is HERE is the part of
//! the claim that reads the columns the artifact does not carry:
//!
//!   * `dump --stage=bir` over every `bir/` and `parse/good` fixture — the
//!     direct assertion, and the only one that prints the loaded record.
//!   * `dump --stage=tokens` and `--stage=ast` over the same — the `Ast` is
//!     not an artifact and a dump of it must be unchanged BY CONSTRUCTION,
//!     which is a fact worth asserting rather than assuming.
//!   * `fmt --stdout` over every `fmt/` fixture — the formatter reads the
//!     tokens, the `Ast` and the comments, and a round trip must leave all
//!     three as the phase left them.
//!   * a file with lex, parse and lower diagnostics, plus the four degenerate
//!     shapes: empty, comment-only, failed to lower, `Bir.empty`.

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const Io = std.Io;
const testing = std.testing;

const corpus_root = "tests/corpus";

/// Every `.beni` directly under `dir_path`, sorted. Run with cwd = the repo
/// root, as the corpus walker runs, so a diagnostic names the repo-relative
/// path the goldens hold.
fn fixtures(arena: std.mem.Allocator, dir_path: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var dir = Io.Dir.cwd().openDir(testing.io, dir_path, .{ .iterate = true }) catch return out.items;
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".beni")) continue;
        try out.append(arena, try std.fs.path.join(arena, &.{ dir_path, entry.name }));
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return out.items;
}

/// One command with and without the flag: same exit code, same stdout, same
/// stderr, to the byte.
fn expectSame(w: *World, arena: std.mem.Allocator, args: []const []const u8) !void {
    var with: std.ArrayList([]const u8) = .empty;
    try with.appendSlice(arena, args);
    try with.append(arena, "--roundtrip-frontend");

    const plain = try w.runWith(args, .{ .raw_diagnostics = true, .cwd = .inherit });
    const flagged = try w.runWith(with.items, .{ .raw_diagnostics = true, .cwd = .inherit });

    if (plain.exit_code != flagged.exit_code or
        !std.mem.eql(u8, plain.stdout, flagged.stdout) or
        !std.mem.eql(u8, plain.stderr, flagged.stderr))
    {
        std.debug.print("--roundtrip-frontend changed `{s}`:\n", .{args[args.len - 1]});
        std.debug.print("  exit {d} -> {d}\n", .{ plain.exit_code, flagged.exit_code });
        if (!std.mem.eql(u8, plain.stdout, flagged.stdout)) {
            std.debug.print("--- stdout, plain ---\n{s}\n--- stdout, round-tripped ---\n{s}\n", .{ plain.stdout, flagged.stdout });
        }
        if (!std.mem.eql(u8, plain.stderr, flagged.stderr)) {
            std.debug.print("--- stderr, plain ---\n{s}\n--- stderr, round-tripped ---\n{s}\n", .{ plain.stderr, flagged.stderr });
        }
        return error.RoundTripDiffers;
    }
}

/// One case of the sweep: a command to run twice, named by its fixture.
const Case = struct { args: []const []const u8 };

/// Cases pulled from one atomic counter, as the compiler's own workers pull
/// files. ~380 invocation
/// PAIRS at ~100 ms each would be four minutes serially; spread over eight
/// workers it is seconds, and `zig build test-blackbox` already runs its test
/// binaries concurrently, so the cost lands where it overlaps.
const Runner = struct {
    gpa: std.mem.Allocator,
    cases: []const Case,
    next: std.atomic.Value(usize) = .init(0),
    failures: std.atomic.Value(u32) = .init(0),

    fn work(r: *Runner) void {
        var w = World.init(r.gpa, testing.io) catch {
            _ = r.failures.fetchAdd(1, .monotonic);
            return;
        };
        defer w.deinit();
        var arena_state: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena_state.deinit();
        while (true) {
            const i = r.next.fetchAdd(1, .monotonic);
            if (i >= r.cases.len) return;
            _ = arena_state.reset(.retain_capacity);
            expectSame(&w, arena_state.allocator(), r.cases[i].args) catch {
                _ = r.failures.fetchAdd(1, .monotonic);
            };
        }
    }

    fn run(gpa: std.mem.Allocator, cases: []const Case) !void {
        var runner: Runner = .{ .gpa = gpa, .cases = cases };
        const workers = @min(8, @max(1, std.Thread.getCpuCount() catch 1));
        {
            var threads: std.ArrayList(std.Thread) = .empty;
            defer threads.deinit(gpa);
            defer for (threads.items) |t| t.join();
            for (0..workers) |_| try threads.append(gpa, try std.Thread.spawn(.{}, work, .{&runner}));
        }
        const failed = runner.failures.load(.monotonic);
        if (failed != 0) {
            std.debug.print("--roundtrip-frontend: {d} of {d} cases differ\n", .{ failed, cases.len });
            return error.RoundTripDiffers;
        }
    }
};

test "the identity oracle: every bir and parse/good fixture dumps the same three ways" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var paths: std.ArrayList([]const u8) = .empty;
    try paths.appendSlice(arena, try fixtures(arena, corpus_root ++ "/bir"));
    try paths.appendSlice(arena, try fixtures(arena, corpus_root ++ "/parse/good"));
    // An oracle over nothing would pass.
    try testing.expect(paths.items.len > 80);

    var cases: std.ArrayList(Case) = .empty;
    for (paths.items) |path| {
        // `--stage=bir` is the direct assertion: it prints the record that
        // came off the format. `--stage=ast` must be unchanged by
        // construction — the `Ast` is not an artifact — and `--stage=tokens`
        // is what says the two columns that ARE cached did not disturb the
        // two that are not.
        for ([_][]const u8{ "--stage=bir", "--stage=ast", "--stage=tokens" }) |stage| {
            try cases.append(arena, .{ .args = try arena.dupe([]const u8, &.{ "dump", stage, path }) });
        }
    }
    try Runner.run(gpa, cases.items);
}

test "fmt --stdout is byte-identical under the flag over every fmt fixture" {
    // The formatter reads the tokens, the `Ast` AND the comments, which is
    // the combination no other command asks for: two of those are not
    // artifacts and the third loses two of its four columns. If a round trip
    // ever replaced a live token list wholesale, this is the test that would
    // catch it, because `Format` reads `line` and `payload`.
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const paths = try fixtures(arena, corpus_root ++ "/fmt");
    try testing.expect(paths.len > 20);
    var cases: std.ArrayList(Case) = .empty;
    for (paths) |path| {
        try cases.append(arena, .{ .args = try arena.dupe([]const u8, &.{ "fmt", "--stdout", path }) });
    }
    try Runner.run(gpa, cases.items);
}

test "a file with lex, parse and lower diagnostics replays them byte for byte" {
    // `plans/m4-2.md` §9.2 item 19. The front end's diagnostics travel as the
    // PROSE the phase rendered, with positions rather than offsets, so a
    // replay has to reproduce the message, the severity, the span and the
    // ORDER — and a run with the flag renders from the replayed rows and not
    // from the ones the phase made.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    // A tab (lex), an unterminated declaration (parse) and a duplicate
    // definition (lower), in one file, so all three waves are in one stream
    // and their relative order is asserted with them.
    // The tab is written as an escape because a Zig multiline literal may not
    // hold one — which is the same reason `tab_in_source` exists.
    try w.write("src/Bad.beni", "pub one : Int\none =\n\t1\n\n\npub one : Int\none =\n    2\n");
    try w.write("src/Empty.beni", "");
    try w.write("src/Comment.beni", "-- nothing but a comment\n");
    try w.write("src/Unparsed.beni", "pub x = = =\n");

    for ([_][]const u8{ "src/Bad.beni", "src/Empty.beni", "src/Comment.beni", "src/Unparsed.beni" }) |path| {
        const abs = try w.projectSubPath(arena, path);
        try expectSameInProject(&w, arena, &.{ "dump", "--stage=bir", abs });
        try expectSameInProject(&w, arena, &.{ "check", "--diagnostics=json", abs });
    }
    // And the whole project at once, which is the shape that puts several
    // files' replayed rows into one sorted stream.
    try expectSameInProject(&w, arena, &.{ "check", "--diagnostics=json", "src" });
}

/// `expectSame` with cwd = the world's project directory, for fixtures this
/// test wrote rather than ones the repository holds.
fn expectSameInProject(w: *World, arena: std.mem.Allocator, args: []const []const u8) !void {
    var with: std.ArrayList([]const u8) = .empty;
    try with.appendSlice(arena, args);
    try with.append(arena, "--roundtrip-frontend");
    const plain = try w.runWith(args, .{ .raw_diagnostics = true });
    const flagged = try w.runWith(with.items, .{ .raw_diagnostics = true });
    if (plain.exit_code != flagged.exit_code or
        !std.mem.eql(u8, plain.stdout, flagged.stdout) or
        !std.mem.eql(u8, plain.stderr, flagged.stderr))
    {
        std.debug.print(
            "--roundtrip-frontend changed `{s} {s}`:\nexit {d} -> {d}\n--- plain ---\n{s}{s}\n--- round-tripped ---\n{s}{s}\n",
            .{ args[0], args[args.len - 1], plain.exit_code, flagged.exit_code, plain.stdout, plain.stderr, flagged.stdout, flagged.stderr },
        );
        return error.RoundTripDiffers;
    }
}

test "--roundtrip-frontend is hidden, and is accepted by every subcommand" {
    // Hidden for `--roundtrip-interfaces`' reasons: it is diagnostic surface
    // rather than product surface. Accepted everywhere because it is on
    // `Common`, which is what lets `dump` and `fmt` be oracles for it.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    const help = try w.runWith(&.{"--help"}, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), help.exit_code);
    try testing.expect(std.mem.indexOf(u8, help.stdout, "--roundtrip-frontend") == null);

    try w.write("src/M.beni", "pub x : Int\nx =\n    1\n");
    for ([_][]const u8{ "check", "fmt", "dump" }) |command| {
        const r = if (std.mem.eql(u8, command, "dump"))
            try w.runWith(&.{ "dump", "--stage=bir", "--roundtrip-frontend", "src/M.beni" }, .{ .raw_diagnostics = true })
        else
            try w.runWith(&.{ command, "--roundtrip-frontend", "src" }, .{ .raw_diagnostics = true });
        if (r.exit_code == 2) {
            std.debug.print("`beni {s} --roundtrip-frontend` exited 2:\n{s}\n", .{ command, r.stderr });
            return error.FlagRefused;
        }
    }
    // It takes no value, like its two siblings.
    const valued = try w.runWith(&.{ "check", "--roundtrip-frontend=1", "src" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 2), valued.exit_code);
}
