//! The pending scenarios (`plans/checker-rewrite.md` §2.5): one
//! test per finding of `plans/checker-findings.md` that a corpus
//! fixture cannot state, because its claim is about TIME, or about a program
//! too wide or deep to check in (generated, as `abuse_test.zig` generates
//! its inputs), or because the scenario costs more than the gates' test
//! budget (`over-budget`, in the budget's instructions). Run only by `zig build test-pending`
//! and `zig build test-pending-perf`, never by the gates: every scenario here
//! is expected to be RED on the checker the gates run.
//!
//! Each scenario generates its program into a `World`, times the installed
//! binary on it, and prints one line in the corpus walker's pending format:
//!
//!   PENDING  RED    CK-NN  scenario/CK-NN  [slow]  n=3000: 204 ms; 2n > 510 ms (2.5×) on 3 of 3 runs
//!
//! and fails the step only under the walker's rules:
//!   (b) GREEN: it is fixed on the checker the gates run, so it moves
//!       VERBATIM now — a timing scenario into `perf_test.zig`
//!       (`zig build test-perf`), any other into `abuse_test.zig`;
//!   (d) RED with another signature than `tests/pending/RED` records
//!       (`scenario/CK-NN <signature>`), or with no record at all.
//!
//! **Scaling findings assert a ratio**: time(2n) / time(n) ≤ 2.5, linear with
//! head-room (quadratic is about 4, cubic about 8), because a ratio holds
//! across machines where an absolute bound does not. **Each point is the best
//! of 3 runs**: time only ever gets ADDED by a loaded machine, so the
//! minimum is the measurement. A run of 2n is killed at twice the bound, so a
//! red scenario costs three kills and not three quadratic builds; GREEN needs
//! one run under the bound, RED needs all three over it.
//!
//! **Time is the child's CPU time** (user + system, from `wait4`'s rusage;
//! `world.Result.cpu_ms`), not the wall clock. A concurrent build can
//! stretch the two points' wall clocks unequally, and once gave a cubic
//! scenario a ratio of 1.85 — 87 s against 162 s — and a false GREEN; a loaded
//! machine cannot add CPU time the compiler did not spend, and every run is
//! `--jobs=1`. The wall clock only bounds how long a run may take before it
//! is killed.
//!
//! **Two steps.** The scenarios whose claim is about TIME run in `zig build
//! test-pending-perf`, on a ReleaseFast compiler (`BENI_EXE`), because the
//! budgets they guard (`fast-compiler.md` §2) are ReleaseFast budgets; the
//! rest run in `zig build test-pending`, on the ReleaseSafe binary the gates
//! run.
//! The `scenarios` table decides which; both steps apply rules (a)–(d).
//!
//! **Calibration (ReleaseFast, CPU time, idle 32-core Linux).** Each `n` is
//! the smallest, in steps of the numbers quoted per scenario, at which (i)
//! the defective checker is RED with its ratio clearly over 2.5, and (ii)
//! where a reference fix is known, the same checker WITH that fix reads
//! GREEN, both checked through this harness (`BENI_EXE` at a scratch build)
//! on three runs. An empty module checks in about 6 ms (process start plus
//! `core`), which is the floor under every point. Scenarios without a
//! reference fix say so. Sizes chosen for a Debug binary, with at least
//! 0.5 s of fixed work at `n`, cost eleven minutes a run.

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
///          on the ReleaseSafe binary the gates run — whose safety checks
///          are part of the claim (an overflowing cast is a panic there; in
///          ReleaseFast the same overflow is silent undefined behaviour).
///
/// `BENI_PENDING_SCENARIOS` (`fast` or `perf`, pinned by `build.zig`) picks
/// one; a scenario of the other is skipped. The table is the one place a
/// scenario's step is decided, and `Scenario.init` refuses an id missing
/// from it, so no scenario can fall out of both steps.
const scenarios = [_]struct { name: []const u8, step: Step }{
    // A fixed scenario leaves this table for `ordering_test.zig`,
    // `abuse_test.zig`, `abuse_wide_test.zig`, `perf_test.zig` or
    // `build_test.zig`, whichever states its claim.
    .{ .name = "scenario/CK-144", .step = .fast },
    // Over the test budget (`over-budget`): measured on the ReleaseSafe
    // binary the gates run, in the budget's unit, and promoted back into
    // the file they came from once they fit.
    .{ .name = "scenario/CK-198", .step = .fast },
    .{ .name = "scenario/CK-199", .step = .fast },
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

// An interface term expands every alias body inside every scheme,
// so a chain of nested record aliases is quadratic in BYTES (and in
// publication time, and in the cache entry). `pub type alias R{i} =
// { x : Int, p : R{i-1} }` with one `pub get{i} : R{i} -> Int` each. The
// claim is the size of `dump --stage=raw` (the interface as written), which
// is exact, so one run of each size. Today 60 / 120 levels write
// 1 021 435 / 4 140 731 bytes, a ratio of 4.05 (240 levels: 17.1 MB, a
// 4.9 MB cache entry; a `pub schema` chain of 240 writes a 22 MB entry).
// Expected: alias references by name, each body written once — linear.
test "an alias chain's interface is linear in its length" {
    var s = try Scenario.init("CK-144");
    defer s.deinit();
    try s.w.write("R.beni", try aliasChain(s.arena(), 60));
    try s.w.write("R2.beni", try aliasChain(s.arena(), 120));
    var bytes: [2]usize = undefined;
    for ([_][]const u8{ "R.beni", "R2.beni" }, &bytes) |file, *slot| {
        const run = try s.timed(&.{ "dump", "--stage=raw", "--diagnostics=json", file }, world.bulk_timeout_ms) orelse
            return s.finish(.{ .green = false, .signature = "timeout", .detail = "a dump did not finish" });
        if (run.result.exit_code != 0) return s.finish(try s.failed(run.result));
        slot.* = run.result.stdout.len;
    }
    const hundredths = bytes[1] * 100 / @max(bytes[0], 1);
    const green = hundredths <= 250;
    try s.finish(.{
        .green = green,
        .signature = if (green) "" else "superlinear",
        .detail = try std.fmt.allocPrint(s.arena(), "60 aliases: {d} bytes; 120: {d} bytes; ratio {d}.{d:0>2}", .{ bytes[0], bytes[1], hundredths / 100, hundredths % 100 }),
    });
}

/// `pub type alias R0 = { x : Int }`, then `R{i} = { x : Int, p : R{i-1} }`
/// with a `pub get{i} : R{i} -> Int` each, up to `count`.
fn aliasChain(arena: std.mem.Allocator, count: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "pub type alias R0 =\n    { x : Int }\n\n\n");
    for (1..count + 1) |i| try out.print(arena, "pub type alias R{d} =\n    {{ x : Int, p : R{d} }}\n\n\npub get{d} : R{d} -> Int\nget{d} r =\n    r.x\n\n\n", .{ i, i - 1, i, i, i });
    return out.items;
}

// `==` on a record DERIVES one function with a parameter per field, and a
// JavaScript call that wide overflows the engine's stack: under Node 24 a
// 65 530-field `r == r` built and then threw `RangeError`. Past 4 096
// positions the evidence is one array (`static-dispatch-spike.md` §9.2), so
// this width builds and runs. It came from `abuse_wide_test.zig` and goes
// back there when it fits the test budget: today one build is about 5.3
// billion instructions against 4.3, spent emitting the record's derived
// function and literal (about 5 MB of JavaScript) and re-copying its type at
// each use (`plans/checker-findings.md`).
test "== on a record of 65 530 fields, a width that threw, builds and runs" {
    var s = try Scenario.init("CK-198");
    defer s.deinit();
    const budget = try s.budget();
    try s.w.write("Wide.beni", try wideEqProgram(s.arena(), 65_530));
    const counter = budget.counter;
    const before = counter.read();
    const built = try s.w.runWith(&.{ "build", "--platform=node", "--out=out", "--no-cache", "Wide.beni" }, .{ .raw_diagnostics = true });
    const spent = counter.read() - before;
    if (built.exit_code != 0) return s.finish(try s.failed(built));
    const ran = try s.w.node(world.entry_file);
    if (!std.mem.eql(u8, ran.stdout, "eq\n")) return s.finish(.{ .green = false, .signature = "wrong-output", .detail = ran.stdout });
    try s.finish(s.againstBudget(spent, budget.limit, "one build"));
}

/// A program printing `eq` or `ne` for `r == r`, where `r` has `n` fields.
fn wideEqProgram(arena: std.mem.Allocator, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "import Node exposing (Program)\n\n\nr =\n    { ");
    for (1..n + 1) |i| {
        if (i != 1) try out.appendSlice(arena, ", ");
        try out.print(arena, "f{d} = {d}", .{ i, i });
    }
    try out.appendSlice(arena, " }\n\n\nmain : Program\nmain =\n    Node.printLines [ if r == r then \"eq\" else \"ne\" ]\n");
    return out.items;
}

// `static-dispatch-spike.md` §9.2's wide form across a module boundary: past
// 4 096 evidence entries a derived function takes ONE array `$m`, and every
// caller packs the same count, which an importer reads from the interface.
// `T` has 4 097 parameters. Three builds over one cache directory, one per
// place the count comes from: cold (the interface in memory), warm under
// `--release` (`Main`'s cached dispatch table), and `Main` edited (`Main`
// checked against `Wide`'s loaded record). It came from `cache_test.zig` and
// goes back there when it fits the test budget: today the three builds are
// about 4.8 billion instructions against 4.3, most of it emitting `T`'s
// derived `eq` and `compare` in both forms (`plans/checker-findings.md`).
test "an imported type of 4 097 parameters compares across modules in the wide form, cold, warm and partly warm" {
    var s = try Scenario.init("CK-199");
    defer s.deinit();
    const budget = try s.budget();
    const arena = s.arena();
    const n = 4_097;
    try wideImportProject(&s.w, arena, n, "");
    const expected = "True\nFalse\nTrue\nFalse\n";
    const passes = [_]struct {
        what: []const u8,
        edit: ?[]const u8,
        release: bool,
        /// Null on the cold pass, which checks core too: there it is
        /// `hits == 0` that says nothing came from the cache.
        checked: ?u64,
        hits_at_least: u64,
        expected: []const u8,
    }{
        .{ .what = "cold", .edit = null, .release = false, .checked = null, .hits_at_least = 0, .expected = expected },
        .{ .what = "warm, --release", .edit = null, .release = true, .checked = 0, .hits_at_least = 2, .expected = expected },
        .{ .what = "Main edited", .edit = ", show (y == y)", .release = false, .checked = 1, .hits_at_least = 1, .expected = expected ++ "True\n" },
    };
    var spent: u64 = 0;
    for (passes, 0..) |pass, i| {
        if (pass.edit) |extra| try wideImportProject(&s.w, arena, n, extra);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ "build", "--platform=node", "--out=out", "--cache-dir=cache", "--jobs=1" });
        if (pass.release) try argv.append(arena, "--release");
        try argv.append(arena, try std.fmt.allocPrint(arena, "--self-profile=pass{d}.json", .{i}));
        try argv.appendSlice(arena, &.{ "Main.beni", "Wide.beni" });
        const before = budget.counter.read();
        const built = try s.w.runWith(argv.items, .{ .raw_diagnostics = true });
        spent += budget.counter.read() - before;
        if (built.exit_code != 0) return s.finish(try s.failed(built));
        const ran = try s.w.node(world.entry_file);
        if (!std.mem.eql(u8, ran.stdout, pass.expected)) return s.finish(.{ .green = false, .signature = "wrong-output", .detail = pass.what });
        const counters = try cacheCounters(&s.w, arena, try std.fmt.allocPrint(arena, "pass{d}.json", .{i}));
        const as_expected = if (pass.checked) |checked|
            counters.checked == checked and counters.hits >= pass.hits_at_least
        else
            counters.hits == 0 and counters.checked >= 2;
        if (!as_expected) return s.finish(.{ .green = false, .signature = "cache-use", .detail = pass.what });
        // The importer packs the array: one `$m` of 4 097 entries per call,
        // never 4 097 arguments. (`--release` renames.)
        if (!pass.release) {
            const main_js = try s.w.read("out/Main.mjs");
            if (std.mem.indexOf(u8, main_js, "Wide$T$$eq([") == null or std.mem.indexOf(u8, main_js, "Wide$T$$compare([") == null)
                return s.finish(.{ .green = false, .signature = "positional", .detail = pass.what });
        }
    }
    try s.finish(s.againstBudget(spent, budget.limit, "three builds"));
}

/// `Wide.beni`: `pub type T a0 … a<n-1> = Mk a0 … a<n-1>`. And `Main.beni`:
/// `x` and `y` of it, all fields `1 … n` except `y`'s last, which is 0, and
/// a `main` printing `x == x`, `x == y`, `y < x` and `x < y` — then
/// `extra`, so a second version of `Main` can differ from the first.
fn wideImportProject(w: *World, arena: std.mem.Allocator, n: usize, extra: []const u8) !void {
    var wide: std.ArrayList(u8) = .empty;
    try wide.appendSlice(arena, "pub type T");
    for (0..n) |i| try wide.print(arena, " a{d}", .{i});
    try wide.appendSlice(arena, "\n    = Mk");
    for (0..n) |i| try wide.print(arena, " a{d}", .{i});
    try wide.appendSlice(arena, "\n");
    try w.write("Wide.beni", wide.items);

    var main: std.ArrayList(u8) = .empty;
    try main.appendSlice(arena, "import Node exposing (Program)\nimport Wide\n\n\nx =\n    Wide.Mk");
    for (1..n + 1) |i| try main.print(arena, " {d}", .{i});
    try main.appendSlice(arena, "\n\n\ny =\n    Wide.Mk");
    for (1..n + 1) |i| try main.print(arena, " {d}", .{if (i == n) 0 else i});
    try main.print(arena,
        \\
        \\
        \\
        \\show : Bool -> String
        \\show b =
        \\    if b then
        \\        "True"
        \\
        \\    else
        \\        "False"
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines [ show (x == x), show (x == y), show (y < x), show (x < y){s} ]
        \\
    , .{extra});
    try w.write("Main.beni", main.items);
}

/// The two `--self-profile` counters a cache pass is judged by.
fn cacheCounters(w: *World, arena: std.mem.Allocator, trace: []const u8) !struct { hits: u64, checked: u64 } {
    const Event = struct {
        ph: []const u8,
        args: struct { cache_hits: ?u64 = null, modules_checked: ?u64 = null } = .{},
    };
    const parsed = try std.json.parseFromSliceLeaky(struct { traceEvents: []Event }, arena, try w.read(trace), .{ .ignore_unknown_fields = true });
    var hits: u64 = 0;
    var checked: u64 = 0;
    for (parsed.traceEvents) |e| {
        if (!std.mem.eql(u8, e.ph, "C")) continue;
        if (e.args.cache_hits) |v| hits = v;
        if (e.args.modules_checked) |v| checked = v;
    }
    return .{ .hits = hits, .checked = checked };
}

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
    /// ratio or the bound was exceeded on every run), `timeout`,
    /// `over-budget` (more instructions than the gates' test budget), or
    /// the walker's `exit=<n> first=<code>` when a run did not even finish
    /// the way the scenario needs.
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
            // A timing scenario on any other binary would measure another
            // compiler than the one its sizes were calibrated on.
            const exe = world.exePath(scratch.allocator());
            if (step == .perf and !std.mem.endsWith(u8, exe, "perf/bin/beni")) {
                std.debug.print("scenario/{s} is a timing scenario: it runs on the ReleaseFast compiler `zig build test-pending-perf` installs (BENI_EXE), never on {s}\n", .{ id, exe });
                return error.PerfScenarioOnWrongBinary;
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
    /// different amounts, and once turned a cubic 87 s / 162 s into a
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

    /// A run's stderr as the diagnostics array (a run passes
    /// `--diagnostics=json` itself: `timed` leaves stderr alone).
    fn diagnosticsOf(s: *Scenario, r: world.Result) ![]const @import("diagnostic").Diagnostic {
        const trimmed = std.mem.trim(u8, r.stderr, " \r\n");
        if (trimmed.len == 0) return &.{};
        return std.json.parseFromSliceLeaky([]@import("diagnostic").Diagnostic, s.arena(), trimmed, .{});
    }

    /// `perf_test.zig`'s `eventRatio`: time(2n) / time(n) ≤ 2.5 on one
    /// `--self-profile` event of the file's own module, each point the best
    /// of 3 `check --no-cache --jobs=1` runs, wall time of the event. For a
    /// finding in one phase whose program also carries other phases' costs.
    fn eventRatio(s: *Scenario, small: []const u8, large: []const u8, n: usize, event: []const u8) !Verdict {
        return s.eventRatioOf(small, large, n, event, small, large);
    }

    /// `eventRatio` where what is checked (a file or a directory) and the
    /// file whose event is timed differ (a project directory, and its
    /// `Main`).
    fn eventRatioOf(s: *Scenario, small: []const u8, large: []const u8, n: usize, event: []const u8, small_file: []const u8, large_file: []const u8) !Verdict {
        var ms: [2]f64 = undefined;
        for ([_][]const u8{ small, large }, [_][]const u8{ small_file, large_file }, &ms) |target, file, *slot| {
            var best: f64 = std.math.inf(f64);
            for (0..3) |_| {
                const run = try s.timed(&.{ "check", "--no-cache", "--jobs=1", "--diagnostics=json", "--self-profile=trace.json", target }, world.bulk_timeout_ms) orelse
                    return .{ .green = false, .signature = "timeout", .detail = try std.fmt.allocPrint(s.arena(), "{s} did not finish within {d} ms", .{ target, world.bulk_timeout_ms }) };
                if (run.result.exit_code != 0) return s.failed(run.result);
                const Event = struct { name: []const u8, ph: []const u8, dur: f64 = 0, args: struct { file: ?[]const u8 = null } = .{} };
                const text = try s.w.read("trace.json");
                const parsed = try std.json.parseFromSliceLeaky(struct { traceEvents: []Event }, s.arena(), text, .{ .ignore_unknown_fields = true });
                var total: ?f64 = null;
                for (parsed.traceEvents) |e| {
                    if (!std.mem.eql(u8, e.ph, "X") or !std.mem.eql(u8, e.name, event)) continue;
                    if (!std.mem.eql(u8, e.args.file orelse continue, file)) continue;
                    total = (total orelse 0) + e.dur / 1000.0;
                }
                best = @min(best, total orelse return error.PendingEventMissing);
            }
            slot.* = best;
        }
        const r = ms[1] / @max(ms[0], 0.001);
        return .{
            .green = r <= 2.5,
            .signature = if (r <= 2.5) "" else "slow",
            .detail = try std.fmt.allocPrint(s.arena(), "n={d}: {d:.1} ms; 2n: {d:.1} ms; ratio {d:.2}, `{s}` event", .{ n, ms[0], ms[1], r, event }),
        };
    }

    /// The gates' test budget in instructions (`BENI_PENDING_BUDGET_INSTRUCTIONS`,
    /// which `build.zig` sets from `-Dtest-budget`), and a counter of the
    /// instructions every process this scenario spawns from now on retires.
    /// A machine that cannot count them skips the scenario: its verdict
    /// would be in another unit than the gates'.
    fn budget(s: *Scenario) !struct { limit: u64, counter: world.timing.Counter } {
        const text = testing.environ.getAlloc(s.arena(), "BENI_PENDING_BUDGET_INSTRUCTIONS") catch "";
        const limit = std.fmt.parseUnsigned(u64, text, 10) catch {
            std.debug.print("{s}: no instruction budget to measure against (BENI_PENDING_BUDGET_INSTRUCTIONS); skipped\n", .{s.name});
            return error.SkipZigTest;
        };
        const counter = world.timing.Counter.open() orelse {
            std.debug.print("{s}: no instruction counter could be opened (perf_event_open); skipped\n", .{s.name});
            return error.SkipZigTest;
        };
        return .{ .limit = limit, .counter = counter };
    }

    /// `over-budget` when `spent` instructions exceed the gates' `limit`.
    fn againstBudget(s: *Scenario, spent: u64, limit: u64, what: []const u8) Verdict {
        const detail = std.fmt.allocPrint(s.arena(), "{s}: {d} million instructions; the test budget is {d} million", .{ what, spent / 1_000_000, limit / 1_000_000 }) catch "";
        return .{ .green = spent <= limit, .signature = if (spent <= limit) "" else "over-budget", .detail = detail };
    }

    /// Print the verdict and apply rules (b) and (d).
    fn finish(s: *Scenario, v: Verdict) !void {
        if (v.green) {
            std.debug.print("PENDING  GREEN  {s}  {s}  {s}\n", .{ s.id, s.name, v.detail });
        } else {
            std.debug.print("PENDING  RED    {s}  {s}  [{s}]  {s}\n", .{ s.id, s.name, v.signature, v.detail });
        }
        if (v.green) {
            std.debug.print("PENDING  RULE (b)  {s}  {s} is GREEN under the default checker: move it verbatim into tests/blackbox/perf_test.zig (a timing scenario), the gated file it came from (an over-budget one), or tests/blackbox/abuse_test.zig (any other) and delete its RED line (plans/checker-rewrite.md §2.5)\n", .{ s.id, s.name });
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
