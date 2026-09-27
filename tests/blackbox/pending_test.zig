//! The pending scenarios (`plans/checker-rewrite.md` §2.5): one
//! test per finding of `plans/checker-findings.md` that a corpus
//! fixture cannot state, because its claim is about TIME, or about a program
//! too wide or deep to check in (CK-82: generated, as `abuse_test.zig`
//! generates its inputs). (CK-71's claim about runs agreeing was promoted
//! into `blackbox_test.zig` by R1.) Run only by `zig build test-pending`
//! and `zig build test-pending-perf`, never by the gates: every scenario here
//! is expected to be RED on the checker the gates run.
//!
//! Each scenario generates its program into a `World`, times the installed
//! binary on it, and prints one line in the corpus walker's pending format:
//!
//!   PENDING  RED    CK-88  scenario/CK-88  [slow]  n=3000: 204 ms; 2n > 510 ms (2.5×) on 3 of 3 runs
//!
//! (CK-88's line before R12 fixed it)
//!
//! and fails the step only under the walker's rules:
//!   (b) GREEN: it is fixed on the checker the gates run, so it moves
//!       VERBATIM now — a timing scenario into `perf_test.zig`
//!       (`zig build test-perf`, the manager's decision of 2026-09-25, CK-41
//!       the first), any other into `abuse_test.zig`;
//!   (d) RED with another signature than `tests/pending/RED` records
//!       (`scenario/CK-NN <signature>`), or with no record at all.
//! (Rule (c), a `CLAIMED` scenario red under v2, and the checker column went
//! with v1 at R12.)
//!
//! **Scaling findings assert a ratio**: time(2n) / time(n) ≤ 2.5, linear with
//! head-room (quadratic is about 4, cubic about 8), because a ratio holds
//! across machines where an absolute bound does not. **Each point is the best
//! of 3 runs** (S13): time only ever gets ADDED by a loaded machine, so the
//! minimum is the measurement. A run of 2n is killed at twice the bound, so a
//! red scenario costs three kills and not three quadratic builds; GREEN needs
//! one run under the bound, RED needs all three over it.
//!
//! **Time is the child's CPU time** (user + system, from `wait4`'s rusage;
//! `world.Result.cpu_ms`), not the wall clock (review of R2a, 2026-09-24). A
//! concurrent build stretched the two points' wall clocks unequally and gave
//! CK-40 a ratio of 1.85 — 87 s against 162 s — and a false GREEN; a loaded
//! machine cannot add CPU time the compiler did not spend, and every run is
//! `--jobs=1`. The wall clock only bounds how long a run may take before it
//! is killed.
//!
//! **Two steps** (2026-09-25). The scenarios whose claim is about TIME
//! (none since R12 promoted CK-88) run in `zig build
//! test-pending-perf`, on a ReleaseFast compiler (`BENI_EXE`), because the
//! budgets they guard (`fast-compiler.md` §2) are ReleaseFast budgets; the
//! rest run in `zig build test-pending`, on the Debug binary the gates run.
//! The `scenarios` table decides which; both steps apply rules (a)–(d).
//!
//! **Calibration (2026-09-25, ReleaseFast, CPU time, idle 32-core Linux).**
//! Each `n` is the smallest, in steps of the numbers quoted per scenario,
//! at which (i) `050cd2d` is RED with its ratio clearly over 2.5, and
//! (ii) where a reference fix is known — orch's two scratch fixes, per-group
//! schema settling removed and `Schemes.Writer.resetMemo` growing to twice
//! what it needs — `050cd2d` WITH that fix reads GREEN, both checked through
//! this harness (`BENI_EXE` at a scratch build) on three runs. An empty module
//! checks in about 6 ms (process start plus `core`), which is the floor under
//! every point. Scenarios without a reference fix say so. R0's original sizes
//! were for a Debug binary and at least 0.5 s of fixed work at `n`; they cost
//! eleven minutes a run.

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const Io = std.Io;
const testing = std.testing;

/// The directory whose `RED` the scenarios read.
const pending_root = "tests/pending";

/// Every scenario of this file, by the `scenario/<id>` name `RED` uses for
/// it, and the step that runs it (`plans/checker-rewrite.md` §2.5):
///
///   .perf  `zig build test-pending-perf`: a claim about TIME, measured on
///          the ReleaseFast compiler (`BENI_EXE`), alone, sized for it;
///   .fast  `zig build test-pending`: a claim about what the compiler SAYS,
///          on the Debug binary the gates run — whose safety checks are part
///          of the claim (CK-82's red is a Debug panic; in ReleaseFast the
///          same overflow is silent undefined behaviour).
///
/// `BENI_PENDING_SCENARIOS` (`fast` or `perf`, pinned by `build.zig`) picks
/// one; a scenario of the other is skipped. The table is the one place a
/// scenario's step is decided, and `Scenario.init` refuses an id missing
/// from it, so no scenario can fall out of both steps.
const scenarios = [_]struct { name: []const u8, step: Step }{
    // Since the cut-over (R11) the rest are promoted: PERM, NEST-OVER and
    // NEST-DEEP into `ordering_test.zig`, CK-79 and CK-82 into
    // `abuse_wide_test.zig`, NEST-UNDER into `perf_test.zig`; CK-03, CK-40,
    // CK-42, CK-75 and CK-80 were red under v1 only, and their v2 twins were
    // already in `perf_test.zig` (R6a, R8a). CK-88, the last, went to
    // `perf_test.zig` when R12 fixed it. The table is empty, and the harness
    // stays for the next finding a fixture cannot state.
};

const Step = enum { fast, perf };

/// The step this process runs, from `BENI_PENDING_SCENARIOS`. Unset or
/// empty is refused rather than read as "both": a timing scenario run on the
/// Debug binary measures a different compiler than its sizes were
/// calibrated on, and its verdict would mean nothing.
fn selectedStep(arena: std.mem.Allocator) !Step {
    const text = testing.environ.getAlloc(arena, "BENI_PENDING_SCENARIOS") catch "";
    return std.meta.stringToEnum(Step, text) orelse {
        std.debug.print("BENI_PENDING_SCENARIOS must be `fast` or `perf`, not `{s}`: run `zig build test-pending` or `zig build test-pending-perf`\n", .{text});
        return error.BadPendingScenarios;
    };
}

// ┌─────────────────────────────────────────────────────────────────────────┐
// │ SCENARIOS                                                               │
// └─────────────────────────────────────────────────────────────────────────┘

// (None left: CK-88, the last, was fixed and promoted into `perf_test.zig`
// by R12.)

// The list stays honest: every `RED` entry names a pending fixture that
// exists or a scenario of this file. A fixture promoted into the corpus takes
// its line with it; a stale one would make rule (d) silently check nothing.
test "pending: RED names fixtures and scenarios that exist" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Once, in `test-pending`: the lists do not depend on the binary.
    if (try selectedStep(arena) != .fast) return error.SkipZigTest;
    const red = try world.pending.readRed(arena, testing.io, pending_root);
    var stale: usize = 0;
    for (red) |line| {
        if (!exists(line.path)) {
            std.debug.print("PENDING  STALE  RED names {s}, which is neither a pending fixture nor a scenario\n", .{line.path});
            stale += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), stale);
}

// ┌─────────────────────────────────────────────────────────────────────────┐
// │ HARNESS                                                                 │
// └─────────────────────────────────────────────────────────────────────────┘

fn exists(path: []const u8) bool {
    for (scenarios) |e| if (std.mem.eql(u8, e.name, path)) return true;
    if (!std.mem.startsWith(u8, path, pending_root ++ "/")) return false;
    Io.Dir.cwd().access(testing.io, path, .{}) catch return false;
    return true;
}

const Verdict = struct {
    green: bool,
    /// `tests/pending/RED`'s vocabulary, extended for time: `slow` (the
    /// ratio or the bound was exceeded on every run), `timeout`, or the
    /// walker's `exit=<n> first=<code>` when a run did not even finish the
    /// way the scenario needs.
    signature: []const u8,
    detail: []const u8,
};

const Scenario = struct {
    id: []const u8,
    name: []const u8,
    w: World,
    arena_state: std.heap.ArenaAllocator,
    red: []const world.pending.RedLine,

    fn init(comptime id: []const u8) !Scenario {
        const entry = comptime for (scenarios) |e| {
            if (std.mem.eql(u8, e.name, "scenario/" ++ id)) break e;
        } else @compileError("scenario/" ++ id ++ " is not in the `scenarios` table");
        {
            var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
            defer scratch.deinit();
            const step = try selectedStep(scratch.allocator());
            if (step != entry.step) return error.SkipZigTest;
            // A timing scenario on the Debug binary would measure another
            // compiler than the one its sizes were calibrated on.
            if (step == .perf and std.mem.eql(u8, world.exePath(scratch.allocator()), world.exe_relative)) {
                std.debug.print("scenario/{s} is a timing scenario: it runs on the ReleaseFast compiler `zig build test-pending-perf` installs (BENI_EXE), never on {s}\n", .{ id, world.exe_relative });
                return error.PerfScenarioOnDebugBinary;
            }
        }
        // A kill at the bound is an expected, recorded red signature here,
        // as in the pending walker: its own line would be noise.
        world.announce_timeouts = false;
        var s: Scenario = .{
            .id = id,
            .name = "scenario/" ++ id,
            .w = try World.init(testing.allocator, testing.io),
            .arena_state = .init(testing.allocator),
            .red = &.{},
        };
        s.red = try world.pending.readRed(s.arena_state.allocator(), testing.io, pending_root);
        return s;
    }

    fn deinit(s: *Scenario) void {
        s.w.deinit();
        s.arena_state.deinit();
    }

    fn arena(s: *Scenario) std.mem.Allocator {
        return s.arena_state.allocator();
    }

    /// One compiler run, timed; null when it was killed at `kill_ms` of WALL
    /// time.
    ///
    /// `ms` is the child's own CPU time, user + system (`world.Result.cpu_ms`,
    /// from `wait4`'s rusage), and the wall clock only where the platform
    /// reports none. Every verdict below compares `ms`: a concurrent build on
    /// the same machine stretches the wall clock of the two points by
    /// different amounts, and once turned CK-40's cubic 87 s / 162 s into a
    /// ratio of 1.85 and a false GREEN. It cannot add CPU time the child did
    /// not spend, and `--jobs=1` everywhere keeps CPU time equal to work.
    fn timed(s: *Scenario, args: []const []const u8, kill_ms: i64) !?struct { ms: i64, wall_ms: i64, result: world.Result } {
        const start = Io.Timestamp.now(testing.io, .awake);
        const result = s.w.runWith(args, .{ .raw_diagnostics = true, .timeout_ms = kill_ms }) catch |err| switch (err) {
            error.CompilerTimeout => return null,
            else => return err,
        };
        const wall_ms = start.durationTo(Io.Timestamp.now(testing.io, .awake)).toMilliseconds();
        return .{ .ms = result.cpu_ms orelse wall_ms, .wall_ms = wall_ms, .result = result };
    }

    /// The walker's `exit=<n> codes=<code>×<k>,…` for a run that did not end
    /// the way the scenario needs; the detail lists the first few
    /// diagnostics.
    fn failed(s: *Scenario, r: world.Result) !Verdict {
        const a = s.arena();
        const trimmed = std.mem.trim(u8, r.stderr, " \r\n");
        var detail: std.ArrayList(u8) = .empty;
        const codes = codes: {
            if (trimmed.len == 0) break :codes "none";
            const diags = std.json.parseFromSliceLeaky([]@import("diagnostic").Diagnostic, a, trimmed, .{}) catch {
                try detail.appendSlice(a, trimmed[0..@min(trimmed.len, 160)]);
                break :codes "unparsed";
            };
            for (diags[0..@min(diags.len, 4)], 0..) |d, i| {
                if (i != 0) try detail.appendSlice(a, ", ");
                try detail.print(a, "{t} {s}:{d}:{d}", .{ d.code, std.fs.path.basename(d.span.file), d.span.start.line, d.span.start.col });
            }
            if (diags.len > 4) try detail.print(a, " and {d} more", .{diags.len - 4});
            if (diags.len == 0) break :codes "none";
            const names = try a.alloc([]const u8, diags.len);
            for (diags, names) |d, *n| n.* = @tagName(d.code);
            std.mem.sort([]const u8, names, {}, struct {
                fn lessThan(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.lessThan(u8, x, y);
                }
            }.lessThan);
            var out: std.ArrayList(u8) = .empty;
            var i: usize = 0;
            while (i < names.len) {
                var j = i;
                while (j < names.len and std.mem.eql(u8, names[j], names[i])) j += 1;
                if (i != 0) try out.append(a, ',');
                try out.print(a, "{s}×{d}", .{ names[i], j - i });
                i = j;
            }
            break :codes out.items;
        };
        return .{
            .green = false,
            .signature = try std.fmt.allocPrint(a, "exit={d} codes={s}", .{ r.exit_code, codes }),
            .detail = detail.items,
        };
    }

    /// `ratio` over any two commands: `args_small` at n, `args_large` at 2n.
    fn ratioOf(s: *Scenario, args_small: []const []const u8, args_large: []const []const u8, n: usize) !Verdict {

        // time(n): the best of 3, each bounded only by the harness's own
        // hang detector.
        var best_small: i64 = std.math.maxInt(i64);
        for (0..3) |_| {
            const run = try s.timed(args_small, world.bulk_timeout_ms) orelse
                return .{ .green = false, .signature = "timeout", .detail = try std.fmt.allocPrint(s.arena(), "n={d} did not finish within {d} ms", .{ n, world.bulk_timeout_ms }) };
            if (run.result.exit_code != 0) return s.failed(run.result);
            best_small = @min(best_small, run.ms);
        }

        // time(2n): judged on CPU time against 2.5 × time(n), and killed at
        // twice that of WALL time — so a super-linear build still costs three
        // kills, and a loaded machine cannot kill a linear one early. One run
        // under the bound makes the best of 3 GREEN.
        const bound: i64 = @divTrunc(best_small * 5, 2);
        var best_large: ?i64 = null;
        for (0..3) |_| {
            const run = try s.timed(args_large, @max(bound * 2, 1_000)) orelse continue;
            if (run.result.exit_code != 0) return s.failed(run.result);
            best_large = @min(best_large orelse run.ms, run.ms);
            if (run.ms <= bound) break;
        }
        const large_ms = best_large orelse
            return .{ .green = false, .signature = "slow", .detail = try std.fmt.allocPrint(s.arena(), "n={d}: {d} ms; 2n > {d} ms (2.5×) on 3 of 3 runs, CPU time", .{ n, best_small, bound }) };
        const hundredths: u64 = @intCast(@divTrunc(large_ms * 100, @max(best_small, 1)));
        const text = try std.fmt.allocPrint(s.arena(), "n={d}: {d} ms; 2n: {d} ms; ratio {d}.{d:0>2}, CPU time", .{ n, best_small, large_ms, hundredths / 100, hundredths % 100 });
        return .{ .green = large_ms <= bound, .signature = if (large_ms <= bound) "" else "slow", .detail = text };
    }

    /// Print the verdict and apply rules (b) and (d).
    fn finish(s: *Scenario, v: Verdict) !void {
        if (v.green) {
            std.debug.print("PENDING  GREEN  {s}  {s}  {s}\n", .{ s.id, s.name, v.detail });
        } else {
            std.debug.print("PENDING  RED    {s}  {s}  [{s}]  {s}\n", .{ s.id, s.name, v.signature, v.detail });
        }
        if (v.green) {
            std.debug.print("PENDING  RULE (b)  {s}  {s} is GREEN under the default checker: move it verbatim into tests/blackbox/perf_test.zig (a timing scenario) or tests/blackbox/abuse_test.zig (any other) and delete its RED line (plans/checker-rewrite.md §2.5)\n", .{ s.id, s.name });
            return error.PendingScenarioIsGreen;
        }
        // Rule (d) and the record half of rule (a), as the corpus walker
        // applies them.
        const recorded = for (s.red) |line| {
            if (std.mem.eql(u8, line.path, s.name)) break line.signature;
        } else null;
        if (recorded == null) {
            std.debug.print("PENDING  MALFORMED  {s}  no line in {s}/RED: `{s} {s}`\n", .{ s.id, pending_root, s.name, v.signature });
            return error.PendingScenarioUnrecorded;
        } else if (!std.mem.eql(u8, recorded.?, v.signature)) {
            std.debug.print("PENDING  RULE (d)  {s}  {s} is red as [{s}], and {s}/RED records [{s}]\n", .{ s.id, s.name, v.signature, pending_root, recorded.? });
            return error.PendingScenarioDrifted;
        }
    }
};
