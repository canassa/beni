//! The benchmark instruments, run on one tiny program each so their output
//! cannot rot unnoticed: `bench/size.mjs` and `bench/runtime.mjs`.
//! Benchmarks are not part of the gates, so neither is this file: it runs
//! in `zig build test-bench`.
//!
//! Nothing here imports a compiler internal: `std` and the harness.

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;

// ─────────────────────────────────────────────────────────────────────────
// The measurement harness (plans/static-dispatch-spike.md §7, §10).
//
// `bench/size.mjs` and `bench/runtime.mjs` are instruments, and §10 asks
// that each be run on one tiny program here so their JSON cannot rot
// unnoticed. These scenarios assert SHAPE — the keys are there, the numbers
// are numbers — and never a value, because a byte count and a millisecond
// are properties of the machine, not of the compiler.
//
// Unlike the harness's own spawns, these children keep the test process's
// environment: the scripts find `node` on its `PATH`. `std.process.run`
// inherits it when no `environ_map` is given, and resolves `argv[0]` on it.
//
// They run Node every time, with no run hash: the program under test is the
// instrument itself, a script that runs beni and measures what it wrote,
// and what it prints is a property of the machine, so there is no expected
// output a hash could stand for.
// ─────────────────────────────────────────────────────────────────────────

const HarnessRun = struct {
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

/// Run one of the `bench/` scripts with the repository as the working
/// directory, which is where the build step leaves this process.
fn runHarness(w: *World, argv: []const []const u8) !HarnessRun {
    const arena = w.arena.allocator();
    const r = try std.process.run(w.gpa, w.io, .{
        .argv = argv,
        .cwd = .inherit,
        .stdout_limit = .limited(world.max_stream_bytes),
        .stderr_limit = .limited(world.max_stream_bytes),
    });
    defer w.gpa.free(r.stdout);
    defer w.gpa.free(r.stderr);
    return .{
        .exit_code = switch (r.term) {
            .exited => |code| code,
            else => 255,
        },
        .stdout = try arena.dupe(u8, r.stdout),
        .stderr = try arena.dupe(u8, r.stderr),
    };
}

/// The absolute path of the world's project directory. The harness scripts
/// take a corpus root as a flag and run from the repository, so a path
/// relative to the temporary project is no use to them.
fn projectPath(w: *World) ![]const u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try w.tmp.dir.realPath(w.io, &buffer);
    return w.arena.allocator().dupe(u8, buffer[0..len]);
}

/// The last non-empty line of `text`.
fn lastLine(text: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    var last: []const u8 = "";
    while (it.next()) |line| {
        if (line.len != 0) last = line;
    }
    return last;
}

fn harnessFailed(name: []const u8, r: HarnessRun) error{HarnessFailed} {
    std.debug.print("{s} exited {d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n", .{ name, r.exit_code, r.stdout, r.stderr });
    return error.HarnessFailed;
}

test "bench/size.mjs reports raw, gzip and brotli bytes per program, net of a floor, and a total" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Tiny.beni",
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (String.fromInt 7)
        \\
    );
    const node_exe = w.node_exe orelse return error.NodeNotOnPath;
    const arena = w.arena.allocator();

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try runHarness(&w, &.{
        node_exe,
        "bench/size.mjs",
        try std.fmt.allocPrint(arena, "--beni={s}", .{w.exe}),
        try std.fmt.allocPrint(arena, "--corpus={s}", .{try projectPath(&w)}),
    });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    if (r.exit_code != 0) return harnessFailed("bench/size.mjs", r);

    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, r.stdout, "\n"), '\n');
    const floor = try parseJson(SizeFloor, arena, it.next() orelse return error.NoOutput);
    // The floor is core plus the platform reached by a `main` that does
    // nothing: a real build, so every one of these is positive.
    try testing.expect(floor.floor);
    try testing.expect(floor.files > 0);
    try testing.expect(floor.raw_bytes > 0);
    try testing.expect(floor.gzip_bytes > 0);
    try testing.expect(floor.brotli_bytes > 0);

    const program = try parseJson(SizeProgram, arena, it.next() orelse return error.NoProgramLine);
    try testing.expect(std.mem.endsWith(u8, program.program, "Tiny.beni"));
    try testing.expect(program.files > 0);
    try testing.expect(program.gzip_bytes <= program.raw_bytes);
    try testing.expect(program.brotli_bytes <= program.raw_bytes);
    // Net is the subtraction the totals are built from, so it has to be
    // exactly that and not a second compression.
    try testing.expectEqual(program.raw_bytes - floor.raw_bytes, program.net_raw_bytes);
    try testing.expectEqual(program.gzip_bytes - floor.gzip_bytes, program.net_gzip_bytes);
    try testing.expectEqual(program.brotli_bytes - floor.brotli_bytes, program.net_brotli_bytes);
    // A program that prints one number adds bytes to the floor and does not
    // remove any: the floor is the MINIMUM a program can ship
    // (`backend.md` §9), so nothing can come in under it.
    try testing.expect(program.net_raw_bytes > 0);
    // **§9's acceptance, first half: `derived_bytes` is 0 on the floor and
    // on any program that uses no `==` and no `compare`.** Derivation is
    // still EAGER (§8.5, A.23) — core declares a nominal `eq` and `compare`
    // for every type it has, whether or not anything calls them — and
    // reachability elimination is what keeps them out of a build that does
    // not. Before §9 this same line asserted the opposite, `> 0` and at
    // least four functions, and that was the cost the pass exists to
    // remove.
    try testing.expectEqual(@as(u64, 0), floor.derived_bytes);
    try testing.expectEqual(@as(u32, 0), floor.derived_functions);
    try testing.expectEqual(@as(u64, 0), program.derived_bytes);
    try testing.expectEqual(@as(u32, 0), program.derived_functions);
    // And the floor really is ~2 kB rather than ~70 kB: the number §9
    // predicted by hand before the pass was written. Generous bounds, so
    // that an unrelated core edit does not move the test, but tight enough
    // that a build which stopped eliminating fails here.
    try testing.expect(floor.raw_bytes < 8 * 1024);
    try testing.expect(floor.files <= 8);

    // The empty mounted page, once per browser platform, dev and release,
    // after the programs. `browser-tea` is `browser` plus The Elm
    // Architecture's one module, so it is `browser`'s page and one file more.
    const page = try parseJson(SizePage, arena, it.next() orelse return error.NoPageLine);
    try testing.expect(page.page);
    try testing.expectEqualStrings("browser", page.platform);
    try testing.expect(page.brotli_bytes > 0 and page.brotli_bytes <= page.raw_bytes);
    try testing.expect(page.release_raw_bytes > 0 and page.release_raw_bytes <= page.raw_bytes);
    const tea = try parseJson(SizePage, arena, it.next() orelse return error.NoPageLine);
    try testing.expectEqualStrings("browser-tea", tea.platform);
    try testing.expectEqual(page.files + 1, tea.files);
    try testing.expect(tea.raw_bytes > page.raw_bytes);

    const total = try parseJson(SizeTotal, arena, lastLine(r.stdout));
    try testing.expect(total.total);
    try testing.expectEqual(@as(u32, 1), total.programs);
    // The shared tree counted ONCE plus what the program adds, and the gross
    // sum kept beside it. Each field says which of the two it is, so that
    // the release column can be divided by the right one.
    try testing.expectEqual(floor.raw_bytes + program.net_raw_bytes, total.floor_once_raw_bytes);
    try testing.expectEqual(floor.gzip_bytes + program.net_gzip_bytes, total.floor_once_gzip_bytes);
    try testing.expectEqual(floor.brotli_bytes + program.net_brotli_bytes, total.floor_once_brotli_bytes);
    try testing.expectEqual(program.raw_bytes, total.gross_raw_bytes);
    try testing.expectEqual(floor.raw_bytes, total.floor_raw_bytes);
    // **The pair that may be compared.** `release_gross_*` is summed exactly
    // as `gross_*` is — whole trees, floor included, once per program — so
    // the ratio of the two is a fact about the optimiser. With one program
    // in this corpus the sum IS that program's release tree, and it is
    // smaller than the dev one, which the old netted `raw_bytes` next to a
    // gross `release_raw_bytes` said the opposite of.
    try testing.expect(total.release_gross_raw_bytes > 0);
    try testing.expect(total.release_gross_raw_bytes < total.gross_raw_bytes);
}

test "bench/size.mjs counts §8.5's derived names and not a user's own `eq`" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `derived_bytes` is the whole point of the output-size measurement's
    // "grows per type x method" row (static-dispatch-spike.md), and it is worth something only if it counts DERIVED code and
    // nothing else. Two programs in one corpus root, and the pair is the
    // assertion:
    //
    //   - `DerivesCompare` orders a three-constructor type, so §8.5 emits
    //     `DerivesCompare$Colour$$compare` and its §9.4 `$$order` table —
    //     and NOT `Colour$$eq`, which is derived eagerly and then
    //     eliminated, nothing having compared a `Colour` for equality
    //     (`backend.md` §9).
    //   - `UserWrittenEq` writes `pub eq` by hand. It is emitted as
    //     `UserWrittenEq$eq`, which is the shape the old matcher —
    //     `$(eq|compare|order)($|end)` — charged to derivation, and which
    //     §8.5 cannot produce: a derived nominal name takes a DOUBLE
    //     separator (`Colour$$eq`) and a structural one an enumerated
    //     suffix (`eq$r$…`, `eq$t2`, `eq$unit`, `eq$prim`). So the answer
    //     is zero, where it used to be one.
    //
    // The same exactness retires the list of nine hand-written core values
    // (`Basics$compare`, `String$compare`, `List$eq`, …) the matcher needed
    // in order to stop claiming those as well: none of them matches now.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("DerivesCompare.beni",
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\pub type Colour
        \\    = Red
        \\    | Green
        \\    | Blue
        \\
        \\
        \\pub rank : Colour, Colour -> Bool
        \\rank a b =
        \\    a < b
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (String.fromInt (if rank Red Blue then 1 else 0))
        \\
    );
    try w.write("UserWrittenEq.beni",
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\pub eq : Int, Int -> Bool
        \\eq x y =
        \\    x == y
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (String.fromInt (if eq 1 1 then 1 else 0))
        \\
    );
    const node_exe = w.node_exe orelse return error.NodeNotOnPath;
    const arena = w.arena.allocator();

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try runHarness(&w, &.{
        node_exe,
        "bench/size.mjs",
        try std.fmt.allocPrint(arena, "--beni={s}", .{w.exe}),
        try std.fmt.allocPrint(arena, "--corpus={s}", .{try projectPath(&w)}),
    });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    if (r.exit_code != 0) return harnessFailed("bench/size.mjs", r);
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, r.stdout, "\n"), '\n');
    _ = it.next(); // the floor
    // Sorted by path, so `DerivesCompare` comes first.
    const derives = try parseJson(SizeProgram, arena, it.next() orelse return error.NoProgramLine);
    try testing.expect(std.mem.endsWith(u8, derives.program, "DerivesCompare.beni"));
    try testing.expectEqualStrings("main", derives.roots);
    // Exactly two, and the list is the assertion:
    //
    //     DerivesCompare$Colour$$compare
    //     DerivesCompare$Colour$$order
    //
    // Three would mean `Colour$$eq` survived an elimination nothing reaches
    // it through — derivation is eager and the type is never compared for
    // equality. One would mean the `$$order` table stopped being charged to
    // derivation. Twenty-something would mean core's own eager rows were
    // shipped again, which is the whole cost §9 exists to remove. And a
    // number that moves when core changes would mean the matcher had gone
    // back to guessing from a name's family resemblance.
    try testing.expectEqual(@as(u32, 2), derives.derived_functions);
    try testing.expectEqual(@as(u32, 0), derives.eq_functions);
    try testing.expectEqual(@as(u32, 1), derives.compare_functions);
    try testing.expectEqual(@as(u32, 1), derives.order_tables);
    // `Colour`'s `compare` reads a table and calls nothing, so it passes no
    // depth and needs no `derived$deep` (backend.md §4).
    try testing.expectEqual(@as(u32, 0), derives.engines);
    try testing.expect(derives.derived_bytes > 0);
    try testing.expect(derives.derived_bytes < derives.raw_bytes);
    // The split is a partition of the same walk, so it adds up on both
    // axes — that is what makes it safe to report the three separately
    // (§11, A.38).
    try testing.expectEqual(
        derives.derived_functions,
        derives.eq_functions + derives.compare_functions + derives.order_tables + derives.engines,
    );
    try testing.expectEqual(
        derives.derived_bytes,
        derives.eq_bytes + derives.compare_bytes + derives.order_bytes + derives.engine_bytes,
    );
    try testing.expect(derives.compare_bytes > 0);
    try testing.expect(derives.order_bytes > 0);

    const user = try parseJson(SizeProgram, arena, it.next() orelse return error.NoProgramLine);
    try testing.expect(std.mem.endsWith(u8, user.program, "UserWrittenEq.beni"));
    // The claim. `UserWrittenEq$eq` IS in the output — it is what `main`
    // calls — and it is not derived code, so none of it is counted.
    try testing.expectEqual(@as(u32, 0), user.derived_functions);
    try testing.expectEqual(@as(u64, 0), user.derived_bytes);
    try testing.expectEqual(@as(u32, 0), user.eq_functions);
    try testing.expectEqual(@as(u32, 0), user.compare_functions);
    try testing.expectEqual(@as(u32, 0), user.order_tables);
}

test "bench/size.mjs builds a root that declares no main behind a synthesised entry" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `bench/corpus` is a library, not a program: no module in it declares
    // `main : Program`, so `beni build` refuses it and the script has to
    // write an entry point of its own. That path is most of what the output-size measurement covers
    // on that corpus, and nothing else exercises it.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Alpha.beni",
        \\pub double : Int -> Int
        \\double n =
        \\    n * 2
        \\
    );
    const node_exe = w.node_exe orelse return error.NodeNotOnPath;
    const arena = w.arena.allocator();

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try runHarness(&w, &.{
        node_exe,
        "bench/size.mjs",
        try std.fmt.allocPrint(arena, "--beni={s}", .{w.exe}),
        try std.fmt.allocPrint(arena, "--corpus={s}", .{try projectPath(&w)}),
    });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    if (r.exit_code != 0) return harnessFailed("bench/size.mjs", r);
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, r.stdout, "\n"), '\n');
    _ = it.next(); // the floor
    const program = try parseJson(SizeSynthesised, arena, it.next() orelse return error.NoProgramLine);
    try testing.expectEqualStrings("BenchMain (synthesised)", program.entry);
    try testing.expectEqual(@as(u32, 1), program.modules_measured);
    try testing.expectEqual(@as(usize, 0), program.modules_excluded.len);
    // The module really is in the output, not merely imported and dropped:
    // there is no DCE, so an import is enough (§11).
    try testing.expect(program.net_raw_bytes > 0);
}

test "bench/runtime.mjs times a program against a beni floor, checks its answer and reports ns/op" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    // The `-- ops:` header is what `ns_per_op` is divided by; a program
    // without one is an error, so the smoke test carries one.
    try w.write("c0/Tiny.beni",
        \\-- ops: 10
        \\import List
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (String.fromInt (List.sum (List.range 1 10)))
        \\
    );
    const node_exe = w.node_exe orelse return error.NodeNotOnPath;
    const arena = w.arena.allocator();

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try runHarness(&w, &.{
        node_exe,
        "bench/runtime.mjs",
        try std.fmt.allocPrint(arena, "--beni={s}", .{w.exe}),
        try std.fmt.allocPrint(arena, "--dir={s}", .{try projectPath(&w)}),
        "--variant=c0",
        "--runs=2",
    });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    if (r.exit_code != 0) return harnessFailed("bench/runtime.mjs", r);
    const line = try parseJson(RuntimeLine, arena, lastLine(r.stdout));
    try testing.expectEqualStrings("Tiny", line.program);
    try testing.expectEqualStrings("c0", line.variant);
    try testing.expectEqual(@as(u32, 2), line.runs);
    try testing.expectEqual(@as(u64, 10), line.ops);
    try testing.expect(line.best_ms > 0);
    try testing.expect(line.median_ms >= line.best_ms);
    // The floor is a null beni PROGRAM, so it pays for the ESM load of core
    // and the platform as well as for starting Node. That is several
    // milliseconds, and it is what makes the subtraction meaningful.
    try testing.expect(line.floor_ms > 0);
    // `ns_per_op` is the printed pair divided by the printed op count, to a
    // tenth: the line is self-checking, and a floor that stopped being
    // subtracted would fail here rather than quietly inflate every number.
    const expected = @max(line.best_ms - line.floor_ms, 0) * 1e6 / @as(f64, @floatFromInt(line.ops));
    try testing.expectApproxEqAbs(@round(expected * 10) / 10, line.ns_per_op, 0.05);
    // The checksum is the program's own answer, which is how a run that got
    // faster by getting the wrong result fails instead of scoring.
    try testing.expectEqualStrings("55", line.checksum);
}

const SizePage = struct {
    page: bool,
    platform: []const u8,
    files: u32,
    raw_bytes: i64,
    brotli_bytes: i64,
    release_raw_bytes: i64,
};

const SizeFloor = struct {
    floor: bool,
    files: u32,
    raw_bytes: i64,
    gzip_bytes: i64,
    brotli_bytes: i64,
    /// §9's acceptance number, and the reason the floor line carries the
    /// split at all: a program that compares nothing ships no derived code.
    derived_bytes: u64,
    derived_functions: u32,
};

const SizeProgram = struct {
    program: []const u8,
    /// Which §9 root rule built this line: `main` or `library`.
    roots: []const u8 = "",
    files: u32,
    raw_bytes: i64,
    gzip_bytes: i64,
    brotli_bytes: i64,
    net_raw_bytes: i64,
    net_gzip_bytes: i64,
    net_brotli_bytes: i64,
    derived_bytes: u64,
    derived_functions: u32,
    // The per-method split the output-size measurement reports as three numbers and never as a sum
    // (§11, A.38).
    eq_functions: u32,
    eq_bytes: u64,
    compare_functions: u32,
    compare_bytes: u64,
    order_tables: u32,
    order_bytes: u64,
    // `derived$deep`, the explicit-stack engine of backend.md §4.
    engines: u32,
    engine_bytes: u64,
};

const SizeSynthesised = struct {
    program: []const u8,
    entry: []const u8,
    modules_measured: u32,
    modules_excluded: []const []const u8,
    net_raw_bytes: i64,
};

/// The `{"total":…}` line. Every figure names its ARITHMETIC: `floor_once_*`
/// counts the floor once and adds each program's net, `gross_*` sums whole
/// trees, and `release_gross_*` sums whole release trees. They were
/// `raw_bytes` and `release_raw_bytes` for one milestone, one netted and one
/// gross, and the obvious comparison of the two said `--release` made
/// programs bigger.
const SizeTotal = struct {
    total: bool,
    programs: u32,
    floor_once_raw_bytes: i64,
    floor_once_gzip_bytes: i64,
    floor_once_brotli_bytes: i64,
    floor_raw_bytes: i64,
    gross_raw_bytes: i64,
    release_gross_raw_bytes: i64 = 0,
};

const RuntimeLine = struct {
    program: []const u8,
    variant: []const u8,
    runs: u32,
    ops: u64,
    floor_ms: f64,
    best_ms: f64,
    median_ms: f64,
    ns_per_op: f64,
    checksum: []const u8,
};

fn parseJson(comptime T: type, arena: std.mem.Allocator, line: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, line, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("not a {s} line ({t}): {s}\n", .{ @typeName(T), err, line });
        return error.NotJson;
    };
}
