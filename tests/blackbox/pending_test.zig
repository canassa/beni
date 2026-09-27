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
    // `perf_test.zig` when R12 fixed it. The table was empty until R15's
    // audit (2026-09-27) added the findings below; R15-fix-A promoted
    // CK-140 into `abuse_test.zig`.
    .{ .name = "scenario/CK-143", .step = .perf },
    .{ .name = "scenario/CK-143-publish", .step = .perf },
    .{ .name = "scenario/CK-144", .step = .fast },
    .{ .name = "scenario/CK-163", .step = .fast },
    .{ .name = "scenario/CK-164", .step = .perf },
    .{ .name = "scenario/CK-165", .step = .perf },
    .{ .name = "scenario/CK-166", .step = .fast },
    .{ .name = "scenario/CK-167", .step = .fast },
    .{ .name = "scenario/CK-171", .step = .perf },
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

// (CK-88, the last of R0–R12's, was fixed and promoted into `perf_test.zig`
// by R12. The ones below are R15's audit, 2026-09-27.)

// CK-143: `Types.find` is a linear scan of the declaring module's types, and
// `Digest.collect` calls it once per exported type (then deduplicates with a
// linear `contains`), so the dependency digest — which runs with or without
// a cache — is quadratic in a module's `pub` types. Independent
// `pub type A{i} = A{i} Int | B{i}`, the `dep_digest` event of the file.
// Calibration (ReleaseFast, 8b98464, R15 red pass): 8 000 / 16 000 / 32 000
// types take 38 / 149 / 571 ms of `dep_digest` (ratio 3.9) against a `check`
// of 29 / 57 / 115 ms. No reference fix. n = 8 000.
test "CK-143: the dependency digest is linear in a module's pub types" {
    var s = try Scenario.init("CK-143");
    defer s.deinit();
    const template = "pub type A{d}\n    = A{d} Int\n    | B{d}\n\n\n";
    try s.w.write("I.beni", try generate(s.arena(), 8_000, template, 3));
    try s.w.write("I2.beni", try generate(s.arena(), 16_000, template, 3));
    try s.finish(try s.eventRatio("I.beni", "I2.beni", 8_000, "dep_digest"));
}

// CK-143's publication half: `Types.resolveRefs` calls the same linear
// `find` once per `type_refs` row, in P8 for every miss and in `install` for
// every hit, so publishing a CHAIN `pub type A{i} = A{i} Int A{i-1} | B{i}`
// is quadratic. The `publish` event of the file. Calibration (ReleaseFast,
// 8b98464): 8 000 / 16 000 / 32 000 take 32 / 53 / 183 ms (the ratio is
// 1.7, then 3.5: the scan only dominates from about 16 000). No reference
// fix. n = 16 000.
test "CK-143-publish: publishing a chain of pub types is linear" {
    var s = try Scenario.init("CK-143-publish");
    defer s.deinit();
    try s.w.write("C.beni", try typeChain(s.arena(), 16_000));
    try s.w.write("C2.beni", try typeChain(s.arena(), 32_000));
    try s.finish(try s.eventRatio("C.beni", "C2.beni", 16_000, "publish"));
}

// CK-144: an interface term expands every alias body inside every scheme,
// so a chain of nested record aliases is quadratic in BYTES (and in
// publication time, and in the cache entry). `pub type alias R{i} =
// { x : Int, p : R{i-1} }` with one `pub get{i} : R{i} -> Int` each. The
// claim is the size of `dump --stage=raw` (the interface as written), which
// is exact, so one run of each size. At 8b98464: 60 / 120 levels write
// 1 021 435 / 4 140 731 bytes, a ratio of 4.05 (240 levels: 17.1 MB, a
// 4.9 MB cache entry; a `pub schema` chain of 240 writes a 22 MB entry).
// Expected: alias references by name, each body written once — linear.
test "CK-144: an alias chain's interface is linear in its length" {
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

// CK-163: `build --out` leaves the files of an earlier build behind. Build a
// program that imports `Half` and uses `Dict`, then change `Main` to use
// neither and build into the same `out/`. At 8b98464 `out/Half.mjs` (and
// `out/_core/Dict.mjs`) survive: stale modules beside a build that never
// wrote them. Expected: `out/` holds exactly what a build of the second
// program into an empty directory writes. (`backend.md` §2 does not yet
// say; this is the claim a reader of `out/` relies on.)
test "CK-163: a build's output directory holds only what that build wrote" {
    var s = try Scenario.init("CK-163");
    defer s.deinit();
    try s.w.write("Half.beni", "pub half : Int -> Int\nhalf n =\n    n // 2\n");
    try s.w.write("Main.beni", "import Node exposing (Program)\nimport Dict\nimport Half\nimport String\n\n\nmain : Program\nmain =\n    Node.printLines [ String.fromInt (Half.half (Dict.size (Dict.singleton 1 2))) ]\n");
    const first = try s.w.runWith(&.{ "build", "--platform=node", "--out=out", "--diagnostics=json", "Main.beni", "Half.beni" }, .{ .raw_diagnostics = true });
    if (first.exit_code != 0) return s.finish(try s.failed(first));
    try s.w.write("Main.beni", "import Node exposing (Program)\n\n\nmain : Program\nmain =\n    Node.printLines [ \"x\" ]\n");
    const second = try s.w.runWith(&.{ "build", "--platform=node", "--out=out", "--diagnostics=json", "Main.beni" }, .{ .raw_diagnostics = true });
    if (second.exit_code != 0) return s.finish(try s.failed(second));
    const fresh = try s.w.runWith(&.{ "build", "--platform=node", "--out=fresh", "--diagnostics=json", "Main.beni" }, .{ .raw_diagnostics = true });
    if (fresh.exit_code != 0) return s.finish(try s.failed(fresh));
    const got = try s.w.listFiles("out");
    const want = try s.w.listFiles("fresh");
    var stale: std.ArrayList(u8) = .empty;
    for (got) |path| {
        const expected = for (want) |w| {
            if (std.mem.eql(u8, w, path)) break true;
        } else false;
        if (!expected) try stale.print(s.arena(), " {s}", .{path});
    }
    const same = stale.items.len == 0 and got.len == want.len;
    try s.finish(.{
        .green = same,
        .signature = if (same) "" else "stale-files",
        .detail = if (same) "out/ equals a fresh build" else try std.fmt.allocPrint(s.arena(), "left behind:{s}", .{stale.items}),
    });
}

// CK-164: the frontend's `resolve` is quadratic in the qualified references
// of one module. `pub s{i} : List Int -> List Int` / `s{i} xs = List.map xs
// negate`, the file's `resolve` event. Calibration (ReleaseFast, 8b98464):
// 4 000 / 8 000 / 16 000 take 15 / 60 / 239 ms of `resolve` (ratio 4.0)
// against `check`'s 16 / 32 / 63. With `where` clauses and no qualified
// reference it is 8 ms. No reference fix. n = 8 000.
test "CK-164: resolving qualified references is linear in their number" {
    var s = try Scenario.init("CK-164");
    defer s.deinit();
    const template = "pub s{d} : List Int -> List Int\ns{d} xs =\n    List.map xs negate\n\n\n";
    try s.w.write("Q.beni", try generate(s.arena(), 8_000, template, 2));
    try s.w.write("Q2.beni", try generate(s.arena(), 16_000, template, 2));
    try s.finish(try s.eventRatio("Q.beni", "Q2.beni", 8_000, "resolve"));
}

// CK-165: `lower` is super-linear in a module's imports and their uses. A
// `Main` importing n one-value modules `M{i}` and listing `M{i}.v` once
// each; `Main`'s own `lower` event. Calibration (ReleaseFast, 8b98464, the
// uses summed with `+`): 2 000 / 4 000 / 8 000 modules take 28 / 131 / 265
// ms of `lower` (8 000 at 80 ms with the imports alone); `resolve` is
// quadratic beside it (7 / 27 / 54). No reference fix. n = 2 000.
test "CK-165: lowering a module is linear in its imports and their uses" {
    var s = try Scenario.init("CK-165");
    defer s.deinit();
    for ([_]usize{ 2_000, 4_000 }) |n| {
        for (0..n) |i| {
            try s.w.write(try std.fmt.allocPrint(s.arena(), "D{d}/M{d}.beni", .{ n, i }), try std.fmt.allocPrint(s.arena(), "pub v : Int\nv =\n    {d}\n", .{i}));
        }
        var main: std.ArrayList(u8) = .empty;
        for (0..n) |i| try main.print(s.arena(), "import M{d}\n", .{i});
        try main.appendSlice(s.arena(), "\n\nall : List Int\nall =\n    [ M0.v\n");
        for (1..n) |i| try main.print(s.arena(), "    , M{d}.v\n", .{i});
        try main.appendSlice(s.arena(), "    ]\n");
        try s.w.write(try std.fmt.allocPrint(s.arena(), "D{d}/Main.beni", .{n}), main.items);
    }
    try s.finish(try s.eventRatioOf("D2000", "D4000", 2_000, "lower", "D2000/Main.beni", "D4000/Main.beni"));
}

// CK-166: the parser's 4 096-links-per-declaration budget reports once per
// offending expression. A `let` of 5 000 bindings `x{i} = x{i-1} + 1` —
// flat, not nested — gets 906 NESTING TOO DEEP messages at 8b98464 (16 000
// bindings: 11 906), each saying the expression "is nested more than 4096
// levels deep", which it is not. (CK-91's fixture passes at 5 000 only
// because its bodies are `negate x{i}`.) Expected: at most ONE message for
// the declaration; accepting it (rule 7: a flat `let` endangers no stack)
// is green too.
test "CK-166: a long flat let is refused at most once" {
    var s = try Scenario.init("CK-166");
    defer s.deinit();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(s.arena(), "foo : Int -> Int\nfoo x0 =\n    let\n");
    for (1..5_001) |i| try src.print(s.arena(), "        x{d} =\n            x{d} + 1\n\n", .{ i, i - 1 });
    try src.appendSlice(s.arena(), "    in\n    x5000\n");
    try s.w.write("Main.beni", src.items);
    const run = try s.timed(&.{ "check", "--no-cache", "--jobs=1", "--diagnostics=json", "Main.beni" }, world.bulk_timeout_ms) orelse
        return s.finish(.{ .green = false, .signature = "timeout", .detail = "did not finish" });
    const diags = s.diagnosticsOf(run.result) catch return s.finish(try s.failed(run.result));
    const green = run.result.exit_code == 0 or
        (run.result.exit_code == 1 and diags.len == 1 and diags[0].code == .nesting_too_deep);
    try s.finish(if (green) .{ .green = true, .signature = "", .detail = "accepted, or one message" } else try s.failed(run.result));
}

// CK-167: a flat `case` over every constructor of a 2 000-constructor type
// is CASE TOO BIG TO CHECK at the default 5 M-step budget at 8b98464 (1 000
// constructors check in 9 ms; 4 000 fail the same way). One column of
// distinct constructors needs one split, O(n log n) at most. Expected: it
// checks.
test "CK-167: a case over a wide type's every constructor checks" {
    var s = try Scenario.init("CK-167");
    defer s.deinit();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(s.arena(), "type T\n    = C0 Int\n");
    for (1..2_000) |i| try src.print(s.arena(), "    | C{d} Int\n", .{i});
    try src.appendSlice(s.arena(), "\n\nf : T -> Int\nf t =\n    case t of\n");
    for (0..2_000) |i| try src.print(s.arena(), "        C{d} x ->\n            x\n\n", .{i});
    try s.w.write("Main.beni", src.items);
    const run = try s.timed(&.{ "check", "--no-cache", "--jobs=1", "--diagnostics=json", "Main.beni" }, world.bulk_timeout_ms) orelse
        return s.finish(.{ .green = false, .signature = "timeout", .detail = "did not finish" });
    try s.finish(if (run.result.exit_code == 0) .{ .green = true, .signature = "", .detail = "checks" } else try s.failed(run.result));
}

// CK-171 (R15-fix-C, found by R15-fix-A's review): an alias DAG is expanded
// as a tree. `A0 = Int`, `A{i} = ( A{i-1}, A{i-1} )` and one `f : A{n} ->
// A{n}`: `Types.Builder.aliasBody` reads each alias's body once per USE, so
// the annotation costs 2^n expansions for n declarations. Calibration
// (ReleaseFast, CPU, 346268b): depth 9 / 18 check in 7 / 535 ms (ratio 76;
// 18 s at 18 in Debug).
// Expected: each (alias, arguments) expanded once per annotation — linear
// in the depth.
test "CK-171: an annotation over a doubling alias DAG is linear in its depth" {
    var s = try Scenario.init("CK-171");
    defer s.deinit();
    try s.w.write("D9.beni", try aliasDag(s.arena(), 9));
    try s.w.write("D18.beni", try aliasDag(s.arena(), 18));
    const check: []const []const u8 = &.{ "check", "--no-cache", "--jobs=1", "--diagnostics=json" };
    const small = try std.mem.concat(s.arena(), []const u8, &.{ check, &.{"D9.beni"} });
    const large = try std.mem.concat(s.arena(), []const u8, &.{ check, &.{"D18.beni"} });
    try s.finish(try s.ratioOf(small, large, 9));
}

/// `type alias A0 = Int`, `type alias A{i} = ( A{i-1}, A{i-1} )` up to
/// `depth`, and `f : A{depth} -> A{depth}`.
fn aliasDag(arena: std.mem.Allocator, depth: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "type alias A0 =\n    Int\n\n\n");
    for (1..depth + 1) |i| try out.print(arena, "type alias A{d} =\n    ( A{d}, A{d} )\n\n\n", .{ i, i - 1, i - 1 });
    try out.print(arena, "f : A{d} -> A{d}\nf x =\n    x\n", .{ depth, depth });
    return out.items;
}

/// `count` copies of `template`, `{d}` the index, `per` holes in each
/// (`perf_test.zig`'s `generate`, verbatim).
fn generate(arena: std.mem.Allocator, count: usize, comptime template: []const u8, comptime per: usize) ![]const u8 {
    comptime std.debug.assert(std.mem.count(u8, template, "{d}") == per);
    var out: std.ArrayList(u8) = .empty;
    for (0..count) |i| {
        var rest: []const u8 = template;
        while (std.mem.indexOf(u8, rest, "{d}")) |at| {
            try out.appendSlice(arena, rest[0..at]);
            try out.print(arena, "{d}", .{i});
            rest = rest[at + 3 ..];
        }
        try out.appendSlice(arena, rest);
    }
    return out.items;
}

/// `pub type A0 = A0 Int | B0`, then `pub type A{i} = A{i} Int A{i-1} | B{i}`
/// up to `count`.
fn typeChain(arena: std.mem.Allocator, count: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "pub type A0\n    = A0 Int\n    | B0\n\n\n");
    for (1..count + 1) |i| try out.print(arena, "pub type A{d}\n    = A{d} Int A{d}\n    | B{d}\n\n\n", .{ i, i, i - 1, i });
    return out.items;
}

/// `pub type alias R0 = { x : Int }`, then `R{i} = { x : Int, p : R{i-1} }`
/// with a `pub get{i} : R{i} -> Int` each, up to `count`.
fn aliasChain(arena: std.mem.Allocator, count: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "pub type alias R0 =\n    { x : Int }\n\n\n");
    for (1..count + 1) |i| try out.print(arena, "pub type alias R{d} =\n    {{ x : Int, p : R{d} }}\n\n\npub get{d} : R{d} -> Int\nget{d} r =\n    r.x\n\n\n", .{ i, i - 1, i, i, i });
    return out.items;
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

    /// A run's stderr as the diagnostics array (a run passes
    /// `--diagnostics=json` itself: `timed` leaves stderr alone).
    fn diagnosticsOf(s: *Scenario, r: world.Result) ![]const @import("diagnostic").Diagnostic {
        const trimmed = std.mem.trim(u8, r.stderr, " \r\n");
        if (trimmed.len == 0) return &.{};
        return std.json.parseFromSliceLeaky([]@import("diagnostic").Diagnostic, s.arena(), trimmed, .{});
    }

    /// `perf_test.zig`'s `eventRatio`: time(2n) / time(n) ≤ 2.5 on one
    /// `--self-profile` event of the file's own module, each point the best
    /// of 3 `check --no-cache --jobs=1` runs, wall time of the event (R8c,
    /// CK-93). For a finding in one phase whose program also carries other
    /// phases' costs.
    fn eventRatio(s: *Scenario, small: []const u8, large: []const u8, n: usize, event: []const u8) !Verdict {
        return s.eventRatioOf(small, large, n, event, small, large);
    }

    /// `eventRatio` where what is checked (a file or a directory) and the
    /// file whose event is timed differ (CK-165: a project directory, and
    /// its `Main`).
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
