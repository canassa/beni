//! The performance scenarios that are FIXED: timing claims promoted out of
//! `pending_test.zig` once a slice turned them green (`plans/checker-rewrite.md`
//! §2.5, *Promotion*). Run only by `zig build test-perf`, on the ReleaseFast
//! compiler `zig-out/perf/bin/beni` (`BENI_EXE`), never by the three gates:
//! rule 4 names those, and a timing claim measured on the Debug binary the
//! gates run measures a different compiler than the one its sizes were
//! calibrated on (the manager's decision of 2026-09-25, when CK-41 became the
//! first scenario to be promoted).
//!
//! The method is `pending_test.zig`'s, unchanged, so a scenario moves between
//! the two files verbatim:
//!
//!   * **a ratio**, time(2n) / time(n) ≤ 2.5 — linear with head-room;
//!     quadratic is about 4 and cubic about 8 — because a ratio holds across
//!     machines where an absolute bound does not;
//!   * **each point the best of 3 runs**, since a loaded machine only ever
//!     ADDS time;
//!   * **time is the child compiler's CPU time** (user + system, `wait4`'s
//!     rusage), every run `--jobs=1`; the wall clock only kills a run, at
//!     twice the bound.
//!
//! Unlike a pending scenario, a red verdict here FAILS the step: the
//! scenario was green when it was promoted, and red is a regression.

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const Io = std.Io;
const testing = std.testing;

// ┌─────────────────────────────────────────────────────────────────────────┐
// │ SCENARIOS                                                               │
// └─────────────────────────────────────────────────────────────────────────┘

// CK-41, promoted by R3 (2026-09-25): `Schemes.Writer.resetMemo` reallocated
// and memset its memo to the store's EXACT size whenever the store had grown,
// and `fillCtorTerms` grows the store before every constructor: O(constructors
// × store). R3 put the writer on epoch marks with amortised growth. ONE `pub`
// type with n constructors isolates it — a chain of n types (the catalogue's
// program) also carries a per-type super-linear residue that is CK-75's, not
// this one's. Calibration (ReleaseFast, CPU): on 050cd2d 2 000 / 3 000 / 4 000
// / 6 000 / 8 000 constructors take 115 / 234 / 390 / 820 / 1 416 ms, a ratio
// of 3.4 to 3.6 from 2 000 on; with amortised growth 2 000 / 4 000 / 8 000 /
// 16 000 / 32 000 take 9 / 13 / 18 / 30 / 54 ms, 1.4 to 1.8. n = 4 000. On R3
// itself: see the slice's *As built* note.
test "CK-41: interface writing is linear in the number of constructors" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var s = try Perf.init();
    defer s.deinit();
    try s.w.write("C.beni", try bigType(s.arena(), 4_000));
    try s.w.write("C2.beni", try bigType(s.arena(), 8_000));

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const verdict = try s.ratio("C.beni", "C2.beni", 4_000);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try s.finish("CK-41", verdict);
}

/// `pub type Big = C0 Int | C1 Int | … ` with `count` constructors.
fn bigType(arena: std.mem.Allocator, count: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "pub type Big\n    = C0 Int\n");
    for (1..count) |i| try out.print(arena, "    | C{d} Int\n", .{i});
    return out.items;
}

// CK-96, found by R5's adversarial review and fixed in R5 (2026-09-25):
// obligation rows riding on ONE variable. Every `${p}` and `p.0` attaches a
// row to `p`, and R5 as first built joined `p`'s whole set, and lowered every
// row on it, at each attach and each merge with a fresh variable: O(rows²)
// (8 000 `${p}` took 31 s under `--checker=v2` against v1's 0.15 s). Checker
// v2 only (v1 has no rows). Calibration: see R5's *As built*.
test "CK-96: obligation rows on one variable cost linear time (checker v2)" {
    var s = try Perf.init();
    defer s.deinit();
    try s.w.write("R.beni", try rowsOnOne(s.arena(), 2_000));
    try s.w.write("R2.beni", try rowsOnOne(s.arena(), 4_000));
    const verdict = try s.ratioWith("R.beni", "R2.beni", 2_000, &.{"--checker=v2"});
    try s.finish("CK-96", verdict);
}

/// `pub f p = "${p}…" ++ …` and `pub g q = ( [ q.0, … ], snd q )`, `n` of
/// each (a declaration holds fewer than 4 096 list elements: the parser's
/// nesting bound).
fn rowsOnOne(arena: std.mem.Allocator, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "snd : ( Int, Int ) -> Int\nsnd ( _, b ) =\n    b\n\n\npub f p =\n    \"");
    for (0..n) |_| try out.appendSlice(arena, "${p}");
    try out.appendSlice(arena, "\" ++ String.fromInt p\n\n\npub g q =\n    ( [ q.0");
    for (1..n) |_| try out.appendSlice(arena, ", q.0");
    try out.appendSlice(arena, " ]\n    , snd q\n    )\n");
    return out.items;
}

// CK-97, found by R5's adversarial review and fixed in R5 (2026-09-25): a
// chain of merges of variables that each carry rows. `[ p1, …, pn, … ]`
// merges a set of i rows into one of 1, n times; R5 as first built copied
// both sets and re-lowered every row of the survivor at every merge,
// O(rows × merges). Checker v2 only.
test "CK-97: merging variables that carry obligation rows is linear (checker v2)" {
    var s = try Perf.init();
    defer s.deinit();
    try s.w.write("M.beni", try mergeChain(s.arena(), 2_000));
    try s.w.write("M2.beni", try mergeChain(s.arena(), 4_000));
    const verdict = try s.ratioWith("M.beni", "M2.beni", 2_000, &.{"--checker=v2"});
    try s.finish("CK-97", verdict);
}

/// `pub f x1 … xn = ( [ "${x1}", … ], [ x1, …, xn, 1 ] )`.
fn mergeChain(arena: std.mem.Allocator, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "pub f");
    for (1..n + 1) |i| try out.print(arena, " x{d}", .{i});
    try out.appendSlice(arena, " =\n    ( [ \"${x1}\"");
    for (2..n + 1) |i| try out.print(arena, ", \"${{x{d}}}\"", .{i});
    try out.appendSlice(arena, " ], [ x1");
    for (2..n + 1) |i| try out.print(arena, ", x{d}", .{i});
    try out.appendSlice(arena, ", 1 ] )\n");
    return out.items;
}

// CK-98, found by R5's adversarial review and fixed in R5 (2026-09-25):
// §8.1 step 3 scanned every open `?` of the module at every boundary, so a
// declaration of n `let` bindings each holding an undecided `u?` cost
// O(n²). Step 3 now reads the frame's own list, and a row that escaped moves
// down once. Checker v2 only.
test "CK-98: the `?` default step is linear in the open `?`s and the boundaries (checker v2)" {
    var s = try Perf.init();
    defer s.deinit();
    try s.w.write("D.beni", try openTries(s.arena(), 1_500));
    try s.w.write("D2.beni", try openTries(s.arena(), 3_000));
    const verdict = try s.ratioWith("D.beni", "D2.beni", 1_500, &.{"--checker=v2"});
    try s.finish("CK-98", verdict);
}

/// `pub f u = let a1 = u? … an = u? in Ok [ a1, …, an ]`.
fn openTries(arena: std.mem.Allocator, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "pub f u =\n    let\n");
    for (1..n + 1) |i| try out.print(arena, "        a{d} =\n            u?\n\n", .{i});
    try out.appendSlice(arena, "    in\n    Ok [ a1");
    for (2..n + 1) |i| try out.print(arena, ", a{d}", .{i});
    try out.appendSlice(arena, " ]\n");
    return out.items;
}

// ┌─────────────────────────────────────────────────────────────────────────┐
// │ HARNESS                                                                 │
// └─────────────────────────────────────────────────────────────────────────┘

const Verdict = struct {
    green: bool,
    detail: []const u8,
};

const Perf = struct {
    w: World,
    arena_state: std.heap.ArenaAllocator,

    fn init() !Perf {
        {
            var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
            defer scratch.deinit();
            // A timing scenario on the Debug binary would measure another
            // compiler than the one its sizes were calibrated on.
            if (std.mem.eql(u8, world.exePath(scratch.allocator()), world.exe_relative)) {
                std.debug.print("perf_test.zig times the ReleaseFast compiler `zig build test-perf` installs (BENI_EXE), never {s}\n", .{world.exe_relative});
                return error.PerfScenarioOnDebugBinary;
            }
        }
        return .{
            .w = try World.init(testing.allocator, testing.io),
            .arena_state = .init(testing.allocator),
        };
    }

    fn deinit(s: *Perf) void {
        s.w.deinit();
        s.arena_state.deinit();
    }

    fn arena(s: *Perf) std.mem.Allocator {
        return s.arena_state.allocator();
    }

    /// One compiler run: its CPU time, or null when it was killed at
    /// `kill_ms` of WALL time. The wall clock stands in only where the
    /// platform reports no rusage.
    fn timed(s: *Perf, args: []const []const u8, kill_ms: i64) !?struct { ms: i64, result: world.Result } {
        const start = Io.Timestamp.now(testing.io, .awake);
        const result = s.w.runWith(args, .{ .raw_diagnostics = true, .timeout_ms = kill_ms }) catch |err| switch (err) {
            error.CompilerTimeout => return null,
            else => return err,
        };
        const wall_ms = start.durationTo(Io.Timestamp.now(testing.io, .awake)).toMilliseconds();
        return .{ .ms = result.cpu_ms orelse wall_ms, .result = result };
    }

    /// time(2n) / time(n) ≤ 2.5, each the best of 3 `check --jobs=1` runs:
    /// `pending_test.zig`'s `ratioOf`, with a failed compile an error rather
    /// than a red signature.
    fn ratio(s: *Perf, small: []const u8, large: []const u8, n: usize) !Verdict {
        return s.ratioWith(small, large, n, &.{});
    }

    /// `ratio` with extra flags on every run (`--checker=v2` for a v2-only
    /// scenario).
    fn ratioWith(s: *Perf, small: []const u8, large: []const u8, n: usize, extra: []const []const u8) !Verdict {
        var small_list: std.ArrayList([]const u8) = .empty;
        try small_list.appendSlice(s.arena(), &.{ "check", "--no-cache", "--jobs=1", "--diagnostics=json" });
        try small_list.appendSlice(s.arena(), extra);
        try small_list.append(s.arena(), small);
        var large_list: std.ArrayList([]const u8) = .empty;
        try large_list.appendSlice(s.arena(), &.{ "check", "--no-cache", "--jobs=1", "--diagnostics=json" });
        try large_list.appendSlice(s.arena(), extra);
        try large_list.append(s.arena(), large);
        const small_args = small_list.items;
        const large_args = large_list.items;
        var best_small: i64 = std.math.maxInt(i64);
        for (0..3) |_| {
            const run = try s.timed(small_args, world.bulk_timeout_ms) orelse {
                std.debug.print("n={d} did not finish within {d} ms\n", .{ n, world.bulk_timeout_ms });
                return error.PerfRunTimedOut;
            };
            try expectClean(run.result);
            best_small = @min(best_small, run.ms);
        }
        // Killed at twice the bound of wall time, judged on CPU time; one run
        // under the bound is the best of 3.
        const bound: i64 = @divTrunc(best_small * 5, 2);
        var best_large: ?i64 = null;
        for (0..3) |_| {
            const run = try s.timed(large_args, @max(bound * 2, 1_000)) orelse continue;
            try expectClean(run.result);
            best_large = @min(best_large orelse run.ms, run.ms);
            if (run.ms <= bound) break;
        }
        const large_ms = best_large orelse return .{
            .green = false,
            .detail = try std.fmt.allocPrint(s.arena(), "n={d}: {d} ms; 2n > {d} ms (2.5×) on 3 of 3 runs, CPU time", .{ n, best_small, bound }),
        };
        const hundredths: u64 = @intCast(@divTrunc(large_ms * 100, @max(best_small, 1)));
        return .{
            .green = large_ms <= bound,
            .detail = try std.fmt.allocPrint(s.arena(), "n={d}: {d} ms; 2n: {d} ms; ratio {d}.{d:0>2}, CPU time", .{ n, best_small, large_ms, hundredths / 100, hundredths % 100 }),
        };
    }

    fn expectClean(r: world.Result) !void {
        if (r.exit_code == 0) return;
        std.debug.print("a timed run exited {d}:\n{s}\n", .{ r.exit_code, r.stderr[0..@min(r.stderr.len, 400)] });
        return error.PerfRunFailed;
    }

    /// Print the verdict; red fails the step.
    fn finish(_: *Perf, id: []const u8, v: Verdict) !void {
        std.debug.print("PERF  {s}  {s}  {s}\n", .{ if (v.green) "GREEN" else "RED  ", id, v.detail });
        if (!v.green) return error.PerfRegression;
    }
};
