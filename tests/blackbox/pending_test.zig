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
//!   PENDING  RED    v1  CK-40  scenario/CK-40  [slow]  n=400: 16979 ms; 2n > 42447 ms (2.5×) on 3 of 3 runs
//!
//! and fails the step only under the walker's rules:
//!   (b) GREEN under the default checker: it is fixed on the gated checker,
//!       so it moves VERBATIM now — a timing scenario into `perf_test.zig`
//!       (`zig build test-perf`, the manager's decision of 2026-09-25, CK-41
//!       the first), any other into `abuse_test.zig`;
//!   (c) listed as `scenario/CK-NN` in `tests/pending/CLAIMED` and RED under v2;
//!   (d) RED with another signature than `tests/pending/RED` records
//!       (`scenario/CK-NN v1 <signature>`), or with no record at all.
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
//! (CK-03, CK-40, CK-42, CK-75, CK-80, CK-88, NEST-UNDER) run in `zig build
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

/// The directory whose `CLAIMED` and `RED` the scenarios read.
const pending_root = "tests/pending";

/// Every scenario of this file, by the `scenario/<id>` name `CLAIMED` and `RED`
/// use for it, and the step that runs it (`plans/checker-rewrite.md` §2.5):
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
    .{ .name = "scenario/CK-03", .step = .perf },
    .{ .name = "scenario/CK-40", .step = .perf },
    .{ .name = "scenario/CK-42", .step = .perf },
    .{ .name = "scenario/CK-75", .step = .perf },
    .{ .name = "scenario/CK-80", .step = .perf },
    .{ .name = "scenario/NEST-UNDER", .step = .perf },
    .{ .name = "scenario/CK-88", .step = .perf },
    .{ .name = "scenario/PERM", .step = .fast },
    .{ .name = "scenario/NEST-OVER", .step = .fast },
    .{ .name = "scenario/NEST-DEEP", .step = .fast },
    .{ .name = "scenario/CK-82", .step = .fast },
    .{ .name = "scenario/CK-79", .step = .fast },
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

// CK-03: a receiver made cyclic by `( y, y ) == y` reaches method resolution,
// and on 7427828 the checker never stops (`targetFor → fillPart →
// derivedUse …`, about 150 MB/s). Fixed, it is `infinite_type` and the check
// ends at once. The bound is 500 ms of CPU (ReleaseFast since 2026-09-25;
// R0's 5 s was for Debug): an empty module checks in about 6 ms, so that is
// two orders of magnitude of head-room for a ten-line file, and a hang costs
// three kills at 1 s of wall time. The corpus twin is
// `tests/pending/check/bad/CyclicReceiverResolution.beni`.
test "CK-03: a cyclic receiver in a `let` reports infinite_type within 500 ms" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var s = try Scenario.init("CK-03");
    defer s.deinit();
    try s.w.write("Cyclic.beni",
        \\f : Int -> Int
        \\f z =
        \\    let
        \\        k y =
        \\            ( y, y ) == y
        \\    in
        \\    z
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const verdict = try s.bounded(&.{ "check", "--no-cache", "--diagnostics=json", "Cyclic.beni" }, 500, .infinite_type);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try s.finish(verdict);
}

// CK-40: `schemas.settleProperties` runs after every binding group holding a
// schema and recomputes every endpoint of the module, each over a store-sized
// memset: O(schemas² × store), cubic. Calibration (ReleaseFast, CPU): on
// 050cd2d 100 / 200 / 300 / 400 / 600 schemas take 19 / 92 / 293 / 716 /
// 2 393 ms, a ratio of about 8 at n = 300; with the per-group calls removed,
// 200 / 300 / 400 / 600 / 800 take 10 / 12 / 15 / 22 / 29 ms (ratio 1.8 at
// n = 300), so n = 300. Past 800 the fixed build is super-linear again —
// 1 000 / 1 600 take 77 / 158 ms, 800 → 1 600 is 5.5× — so the scenario must
// not be scaled up without another fix: that residue is not CK-40's (R0 saw
// none in Debug at 200 / 400 / 800: 339 / 596 / ~1 100 ms).
test "CK-40: schema property settling is linear in the number of schemas" {
    var s = try Scenario.init("CK-40");
    defer s.deinit();
    try s.w.write("S.beni", try generate(s.arena(), 300, "pub schema S{d} = Int\n\n\n", 1));
    try s.w.write("S2.beni", try generate(s.arena(), 600, "pub schema S{d} = Int\n\n\n", 1));
    const verdict = try s.ratio("S.beni", "S2.beni", 300);
    try s.finish(verdict);
}

// CK-42 (suspected in the catalogue, reproduced by R0): n declarations, each
// comparing its own nominal type with `==`. `ownDeclNamed` scans the
// declarations per resolution and `siteOrigins` de-duplicates
// quadratically. The same program with `x == x` on an `Int` in place of the
// nominal `==` is super-linear on its own (CK-75, the per-declaration
// residue), so this scenario measures the EXTRA cost of nominal dispatch:
// extra(n) = t(nominal, n) − t(control, n), and extra(2n) / extra(n) ≤ 2.5,
// each point the best of 3. R6's dispatch fix alone can turn it green.
// Calibration (ReleaseFast, CPU, 050cd2d): nominal / control take 22 / 17,
// 52 / 35, 170 / 100, 609 / 331 and 2 390 / 1 272 ms at 1 000 / 2 000 /
// 4 000 / 8 000 / 16 000, so the extra doubles to 4.0× its size at every
// step from 1 000 on (4.5 → 17 → 70 → 278 → 1 118 ms). n = 4 000, where the
// extra (70 ms) is well clear of the noise of two subtracted points. No
// reference fix exists: R6a's dispatch work is the first that can turn it
// green, and whether it does at n = 4 000 is R6a's to confirm.
//
// **Sized for v2 too (R8c, 2026-09-26).** Under `--checker=v2` the extra is
// the whole nominal cost (v2's control is linear, CK-75) and small: about 10
// ms at 4 000, so two subtracted best-of-3 points read 1.7 to 2.4 against the
// 2.5 bound and failed one run of five at `3c09146`. Under v2 the scenario
// takes n = 32 000 and the best of 7 runs per point, where the extra is about
// 65 / 137 ms. Ten runs on R8c read 1.92 to 2.22 (median 2.09; at 16 000 they
// read 1.73 to 2.22): the ratio sits near 2.1, not 2 — most likely an n log n
// term (sorting by name) — and the noise is what the larger n narrows. v1
// keeps n = 4 000 and 3 runs: it is red by a factor of four, and frozen.
test "CK-42: nominal dispatch adds linear cost per declaration" {
    var s = try Scenario.init("CK-42");
    defer s.deinit();
    const nominal = "type T{d}\n    = T{d} Int\n\n\nf{d} : Int -> Bool\nf{d} x =\n    T{d} x == T{d} x\n\n\n";
    const control = "type T{d}\n    = T{d} Int\n\n\nf{d} : Int -> Bool\nf{d} x =\n    x == x\n\n\n";
    const v2 = std.mem.eql(u8, s.checkerName(), "v2");
    const n: usize = if (v2) 32_000 else 4_000;
    try s.w.write("E.beni", try generate(s.arena(), n, nominal, 6));
    try s.w.write("E2.beni", try generate(s.arena(), 2 * n, nominal, 6));
    try s.w.write("X.beni", try generate(s.arena(), n, control, 4));
    try s.w.write("X2.beni", try generate(s.arena(), 2 * n, control, 4));
    s.best_of = if (v2) 7 else 3;
    const verdict = try s.extraRatio(.{ "E.beni", "E2.beni" }, .{ "X.beni", "X2.beni" }, n);
    try s.finish(verdict);
}

// CK-75: the per-declaration residue CK-42's control exposes. n
// declarations, each a `type` and a function comparing two `Int`s — no
// nominal dispatch at all — check super-linearly: on 7427828 (Debug) 2.6 s
// at 5 000 and 7.6 s at 10 000 (ratio about 2.9), and independent `pub
// type`s alone take 458 / 1 126 / 3 370 ms at 2 000 / 4 000 / 8 000 even
// with CK-40's and CK-41's fixes in. The self-profile puts it in the
// module's `check` event and in `dep_digest`. Slice R8a (manager).
// Calibration (ReleaseFast, CPU, 050cd2d): 1 000 / 2 000 / 3 000 / 4 000 /
// 6 000 / 8 000 / 12 000 / 16 000 take 17 / 35 / 63 / 100 / 196 / 331 / 727 /
// 1 272 ms. The ratio GROWS with n — 2.1 at 1 000, 2.9 at 2 000, 3.3 at
// 4 000, 3.7 at 6 000 — so below about 2 000 this scenario reads GREEN on
// the unfixed compiler; n = 6 000 keeps it clear. With CK-40's and CK-41's
// fixes the numbers do not move (197 / 688 ms at 6 000 / 12 000): no
// reference fix for this one exists.
test "CK-75: checking is linear in the number of declarations" {
    var s = try Scenario.init("CK-75");
    defer s.deinit();
    const control = "type T{d}\n    = T{d} Int\n\n\nf{d} : Int -> Bool\nf{d} x =\n    x == x\n\n\n";
    try s.w.write("X.beni", try generate(s.arena(), 6_000, control, 4));
    try s.w.write("X2.beni", try generate(s.arena(), 12_000, control, 4));
    const verdict = try s.ratio("X.beni", "X2.beni", 6_000);
    try s.finish(verdict);
}

// CK-88 (found by R2c, 2026-09-25): one `case` of n integer literal branches
// is emitted in time quadratic in n — `check` takes 18 ms at 10 000
// branches and `build` 2.2 s, 8.6 s at 20 000 (ReleaseFast, 7ae452f and R2c
// alike), all of it in the emit phase. Past 65 046 branches the one `switch`
// it writes is also refused by SpiderMonkey (`backend.md` §4's table), so a
// fix that splits the `switch` closes both halves. Calibration (ReleaseFast,
// CPU, R2c): n = 3 000 / 6 000. No reference fix.
test "CK-88: a case of n literal branches builds in time linear in n" {
    var s = try Scenario.init("CK-88");
    defer s.deinit();
    try s.w.write("C.beni", try bigCase(s.arena(), 3_000));
    try s.w.write("C2.beni", try bigCase(s.arena(), 6_000));
    const build = [_][]const u8{ "build", "--no-cache", "--jobs=1", "--library", "--platform=node", "--out=out", "--diagnostics=json" };
    const verdict = try s.ratioOf(&(build ++ .{"C.beni"}), &(build ++ .{"C2.beni"}), 3_000);
    try s.finish(verdict);
}

// CK-80: `==` on a value whose type is a DAG — `f x = ( x, [ x ] )` applied
// n deep, so the type holds n distinct pieces but unfolds into a tree of
// 2^n leaves — costs time exponential in n, all of it in `solve`: the
// derived path walks and fills evidence over the unfolded tree
// (`walkDerivable`'s nested walks overwrite the outer marks; `fillPart`
// recurses per position). `Basics.eq w w` on the same value is instant.
// Found by R1's reviewer on both 22daa5f and R1 (not an R1 regression).
// Measured on a Debug build of R1: n=9 0.11 s, n=18 2.31 s, a ratio of 21
// where the rule allows 2.5. ReleaseFast (CPU, 050cd2d): depth 9 / 12 / 14 /
// 16 / 18 take 6 / 9 / 17 / 51 / 190 ms, so 9 / 18 is a ratio of about 30,
// and depth 8 / 16 still 7. Not calibrated to a floor of fixed work at n as
// §2.5 asks: a linear checker takes process start-up time at both points, so
// its ratio is about 1 and the scenario goes GREEN. No reference fix.
test "CK-80: == on a value whose type is a doubling DAG is not exponential in its depth" {
    var s = try Scenario.init("CK-80");
    defer s.deinit();
    try s.w.write("N9.beni", try nestedPair(s.arena(), 9));
    try s.w.write("N18.beni", try nestedPair(s.arena(), 18));
    const verdict = try s.ratio("N9.beni", "N18.beni", 9);
    try s.finish(verdict);
}

/// `w = f (f (… (f 1)))`, `depth` applications of `f x = ( x, [ x ] )`, and
/// `w == w`.
fn nestedPair(arena: std.mem.Allocator, depth: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "f x =\n    ( x, [ x ] )\n\n\nv =\n    let\n        w =\n            ");
    for (0..depth) |_| try out.appendSlice(arena, "f (");
    try out.append(arena, '1');
    for (0..depth) |_| try out.append(arena, ')');
    try out.appendSlice(arena, "\n    in\n    w == w\n");
    return out.items;
}

// R7's permutation scenario (plans/checker-rewrite.md §2.5, R7's exit
// criteria; checker-v2.md I9, §10.5): for every program below, every order of
// its top-level declarations — all of them up to 120, else 120 orders spread
// evenly over the whole permutation space by rank (the first and the
// reversed order among them) — must do what the program's oracle twin says:
//
//   - `prints`: build, exit 0 and print the twin's output (S13: "every
//     order prints the same" would pass if every order failed alike);
//   - `checks`: `check` exits 0;
//   - `refused`: exactly one diagnostic, of the code named, byte-identical
//     in every order — the same message, and the same source text under its
//     span (CK-70, CK-72, CK-76: D14's and §10.6's refusals with their hints).
//
// For `prints` and `checks`, `dump --stage=types` must also be the same in
// the written order, the reversed one and four orders between (each
// declaration's block, whatever its position): a group nested at its first
// demand, however deep, gets the types it gets written first (the reviewer
// focus "a nested check started two `let`s deep").
//
// The orders of one single-file program are packed into one build: each is a
// module `PermPxK` whose `main` became `pub lines : List String`, and a
// `Main` prints every module's lines in order, so one build and one run
// check them all (a failing order is named by the file its diagnostic is
// in). A project's module is permuted one build per order.
//
// R8a adds `cbA`/`cbB` (CK-77, the same `type_mismatch`) and `xm`/`xm2` (the
// guard `DerivedCrossMethodCycle`, the same refusal). On 8016030 v1 refuses
// every program that uses an own method above its definition with METHOD
// NEEDS AN ANNOTATION.
const perm_programs = [_]PermProgram{
    // Round 1: disp's `o1`, orch's `row75`, adv's `box` (CK-36).
    .{ .name = "o1", .path = "tests/pending/run/OwnMethodBeforeDefinition", .module = "O1.beni", .expect = .{ .prints = "tests/pending/run/OwnMethodBeforeDefinition/_expected.expected" } },
    .{ .name = "row75", .path = "tests/pending/run/OwnMethodBeforeDefinition", .module = "Row75.beni", .expect = .{ .prints = "tests/pending/run/OwnMethodBeforeDefinition/_expected.expected" } },
    .{ .name = "box", .path = "tests/pending/run/OwnMethodBeforeDefinition", .module = "Box.beni", .expect = .{ .prints = "tests/pending/run/OwnMethodBeforeDefinition/_expected.expected" } },
    // CK-30's `m1b` and its seven siblings, CK-30's miscount, CK-31's `p5`.
    .{ .name = "m1b", .path = "tests/pending/run/RecursionWithComparison.beni", .expect = .{ .prints = "tests/pending/run/RecursionWithComparison.expected" } },
    .{ .name = "dead", .path = "tests/pending/run/DeadMiscount.beni", .expect = .{ .prints = "tests/pending/run/DeadMiscount.expected" } },
    .{ .name = "p5", .path = "tests/pending/run/MutualGroupEvidenceOrder.beni", .expect = .{ .prints = "tests/pending/run/MutualGroupEvidenceOrder.expected" } },
    // CK-63 to CK-66.
    .{ .name = "ck63", .path = "tests/pending/run/OwnMethodDemandedEarly.beni", .expect = .{ .prints = "tests/pending/run/OwnMethodDemandedEarly.expected" } },
    .{ .name = "twolets", .path = "tests/pending/run/OwnMethodDemandedTwoLetsDeep.beni", .expect = .{ .prints = "tests/pending/run/OwnMethodDemandedTwoLetsDeep.expected" } },
    .{ .name = "ck64", .path = "tests/pending/run/OwnMethodValuePrefix.beni", .expect = .{ .prints = "tests/pending/run/OwnMethodValuePrefix.expected" } },
    .{ .name = "ck65", .path = "tests/pending/run/MutualDispatchMethods.beni", .expect = .{ .prints = "tests/pending/run/MutualDispatchMethods.expected" } },
    .{ .name = "ck66", .path = "tests/pending/run/GroupVariableOutsideCaller.beni", .expect = .{ .prints = "tests/pending/run/GroupVariableOutsideCaller.expected" } },
    // Merges of three and four methods, and a member that demands its
    // cycle at two nodes (§23 items 1 and 8).
    .{ .name = "three", .path = "tests/pending/run/OwnMethodThreeCycle.beni", .expect = .{ .prints = "tests/pending/run/OwnMethodThreeCycle.expected" } },
    .{ .name = "four", .path = "tests/pending/run/OwnMethodFourCycle.beni", .expect = .{ .prints = "tests/pending/run/OwnMethodFourCycle.expected" } },
    .{ .name = "twice", .path = "tests/pending/run/OwnMethodCycleDemandedTwice.beni", .expect = .{ .prints = "tests/pending/run/OwnMethodCycleDemandedTwice.expected" } },
    .{ .name = "value-back-edge", .path = "tests/pending/run/OwnMethodValueBackEdge.beni", .expect = .{ .prints = "tests/pending/run/OwnMethodValueBackEdge.expected" } },
    .{ .name = "nest-after-default", .path = "tests/pending/check/good/NestAfterDefault.beni", .expect = .checks },
    // The §6 guards.
    .{ .name = "annotated-or-first", .path = "tests/corpus/run/OwnMethodAnnotatedOrFirst.beni", .expect = .{ .prints = "tests/corpus/run/OwnMethodAnnotatedOrFirst.expected" } },
    .{ .name = "value-prefix", .path = "tests/corpus/run/OwnMethodValuePrefixOrdered.beni", .expect = .{ .prints = "tests/corpus/run/OwnMethodValuePrefixOrdered.expected" } },
    .{ .name = "in-scrutinee", .path = "tests/corpus/run/OwnMethodInScrutineeOrdered.beni", .expect = .{ .prints = "tests/corpus/run/OwnMethodInScrutineeOrdered.expected" } },
    // Round 3: `rq1`, `rq2` (CK-73 and its guard), `capt`, the annotated
    // `sccA`/`sccB`; and CK-73's merge variant, whose nested group must not
    // drain its demander's queue.
    .{ .name = "rq1", .path = "tests/pending/run/ScrutineeMethodLater.beni", .expect = .{ .prints = "tests/pending/run/ScrutineeMethodLater.expected" } },
    .{ .name = "rq2", .path = "tests/corpus/run/ScrutineeMethodFirst.beni", .expect = .{ .prints = "tests/corpus/run/ScrutineeMethodFirst.expected" } },
    .{ .name = "capt", .path = "tests/corpus/run/SingleMemberGroupReceiver.beni", .expect = .{ .prints = "tests/corpus/run/SingleMemberGroupReceiver.expected" } },
    .{ .name = "scc-annotated", .path = "tests/corpus/run/RecursiveGroupAnnotatedReceiver.beni", .expect = .{ .prints = "tests/corpus/run/RecursiveGroupAnnotatedReceiver.expected" } },
    .{ .name = "rq1-merge", .path = "tests/pending/check/good/ScrutineeMethodMergeVariant/Later.beni", .expect = .checks },
    // An annotated member of a dispatch cycle instantiates (§6.6).
    .{ .name = "ck70-annotated", .path = "tests/corpus/run/RecursiveDispatchAnnotated.beni", .expect = .{ .prints = "tests/corpus/run/RecursiveDispatchAnnotated.expected" } },
    // The refusals: one diagnostic, the same in every order.
    .{ .name = "ck70", .path = "tests/pending/check/bad/RecursiveDispatchTwoTypes.beni", .expect = .{ .refused = .type_mismatch } },
    .{ .name = "ck72", .path = "tests/pending/check/bad/RecursiveGroupReceiverNeedsAnnotation.beni", .expect = .{ .refused = .kind_mismatch } },
    .{ .name = "evA", .path = "tests/pending/check/bad/RecursiveGroupEvidenceReceiver/FirstF.beni", .expect = .{ .refused = .kind_mismatch } },
    .{ .name = "subA", .path = "tests/pending/check/bad/RecursiveGroupSubWanted/FirstF.beni", .expect = .{ .refused = .kind_mismatch } },
    .{ .name = "rq1-d14", .path = "tests/pending/check/bad/ScrutineeMethodMergeD14/Later.beni", .expect = .{ .refused = .kind_mismatch } },
    // R7's reviews: a dot-call's field-or-method choice (CK-105), D14's
    // hint naming one member or the final class and none for rule (a), a
    // merge during the root's boundary, and a refusal whose message shows
    // a type mid-solve (the same code and region in every order).
    .{ .name = "rec1", .path = "tests/pending/run/FieldCallThroughMember.beni", .expect = .{ .prints = "tests/pending/run/FieldCallThroughMember.expected" } },
    .{ .name = "rec1c", .path = "tests/pending/run/FieldCallThroughMemberCycle.beni", .expect = .{ .prints = "tests/pending/run/FieldCallThroughMemberCycle.expected" } },
    .{ .name = "rec2", .path = "tests/pending/run/FieldCallThroughValueRecursion.beni", .expect = .{ .prints = "tests/pending/run/FieldCallThroughValueRecursion.expected" } },
    .{ .name = "rec1v", .path = "tests/pending/run/FieldCallThroughValueDemand.beni", .expect = .{ .prints = "tests/pending/run/FieldCallThroughValueDemand.expected" } },
    .{ .name = "deferred-field", .path = "tests/pending/run/DeferredReceiverFieldCall.beni", .expect = .{ .prints = "tests/pending/run/DeferredReceiverFieldCall.expected" } },
    .{ .name = "t104", .path = "tests/pending/check/bad/RecursiveGroupFieldCallTwoTypes.beni", .expect = .{ .refused = .kind_mismatch } },
    .{ .name = "t102", .path = "tests/pending/check/bad/RecursiveGroupRefusalRendering.beni", .expect = .{ .refused_region = .not_equatable } },
    .{ .name = "hint2", .path = "tests/pending/check/bad/RecursiveGroupHintOneMember.beni", .expect = .{ .refused = .kind_mismatch } },
    .{ .name = "hint1", .path = "tests/pending/check/bad/RecursiveGroupHintAllMembers.beni", .expect = .{ .refused = .kind_mismatch } },
    .{ .name = "p3n", .path = "tests/pending/check/bad/RuleAMonomorphicNoRecursionHint.beni", .expect = .{ .refused = .kind_mismatch } },
    .{ .name = "merge-at-boundary", .path = "tests/pending/run/MergeAtBoundary", .module = "Main.beni", .expect = .{ .prints = "tests/pending/run/MergeAtBoundary/_expected.expected" } },
    // R7's round-2 review: a dot-call joined with a scheme's requirement (X1),
    // both halves of the rule (S2), a `number` receiver's method in a group
    // (CK-106).
    // Its message renders the record as it stood when met (§10.8, I9's scope).
    .{ .name = "joined-in-group", .path = "tests/pending/check/bad/DeferredReceiverJoinedInGroup.beni", .expect = .{ .refused_region = .no_methods_on_shape } },
    .{ .name = "joined-p-first", .path = "tests/pending/check/bad/DeferredReceiverJoinedRequirement/PFirst.beni", .expect = .{ .refused = .no_methods_on_shape } },
    .{ .name = "joined-q-first", .path = "tests/pending/check/bad/DeferredReceiverJoinedRequirement/QFirst.beni", .expect = .{ .refused = .no_methods_on_shape } },
    .{ .name = "generalised", .path = "tests/corpus/check/bad/DeferredReceiverGeneralised.beni", .expect = .{ .refused = .no_methods_on_shape } },
    .{ .name = "recursive-twin", .path = "tests/pending/run/DeferredReceiverRecursiveTwin.beni", .expect = .{ .prints = "tests/pending/run/DeferredReceiverRecursiveTwin.expected" } },
    .{ .name = "ck106", .path = "tests/pending/check/bad/NumberReceiverMethodInGroup.beni", .expect = .{ .refused = .unknown_method } },
    .{ .name = "ck106-dispatch", .path = "tests/pending/check/bad/NumberReceiverMethodInGroupDispatch.beni", .expect = .{ .refused = .unknown_method } },
    // R8a: derived contexts by fixpoint (checker-v2.md §11.2). A closed
    // in-flight method (CK-67, its nested and permuted twins), the
    // parametric refusal (CK-69), a re-entrant query (CK-74), the replayed
    // wanted that merges the asker (CK-77), a derived query inside an own
    // `eq`'s merged class (R7's S6), and `eq` and `compare` computed jointly
    // over one type-level SCC (round 4 R8-2).
    .{ .name = "ck67", .path = "tests/pending/run/DerivedContextClosedOwnMethod", .module = "Main.beni", .expect = .{ .prints = "tests/pending/run/DerivedContextClosedOwnMethod/_expected.expected" } },
    .{ .name = "ck67-nested", .path = "tests/pending/run/DerivedContextClosedOwnMethod", .module = "Nested.beni", .expect = .{ .prints = "tests/pending/run/DerivedContextClosedOwnMethod/_expected.expected" } },
    .{ .name = "ck67-permuted", .path = "tests/pending/run/DerivedContextClosedOwnMethodPermuted", .module = "Main.beni", .expect = .{ .prints = "tests/pending/run/DerivedContextClosedOwnMethodPermuted/_expected.expected" } },
    .{ .name = "ck69", .path = "tests/pending/check/bad/DerivedContextNeedsAnnotation", .module = "Main.beni", .expect = .{ .refused = .method_needs_annotation } },
    .{ .name = "ck74", .path = "tests/pending/check/bad/DerivedContextReentrant", .module = "Main.beni", .expect = .{ .refused = .type_mismatch } },
    .{ .name = "ck77", .path = "tests/pending/check/bad/DerivedContextMergesAsker", .module = "PickFirst.beni", .expect = .{ .refused = .kind_mismatch } },
    .{ .name = "s6-in-flight-eq", .path = "tests/pending/run/DerivedContextInFlightEq", .module = "Main.beni", .expect = .{ .prints = "tests/pending/run/DerivedContextInFlightEq/_expected.expected" } },
    .{ .name = "joint-eq-compare", .path = "tests/corpus/run/DerivedContextJointMethods", .module = "Main.beni", .expect = .{ .prints = "tests/corpus/run/DerivedContextJointMethods/_expected.expected" } },
    // R8b: a pass that demands a group which merges down into the asker
    // (CK-117); D1 inside the module and two modules away from the private
    // `eq`, permuting the declaring and the wrapping module (CK-22); schema
    // endpoints through the one fixpoint — an exclusion reached through a
    // `via` target that mentions the endpoint back, the same program
    // accepted, a record endpoint, and a comparison inside the schema's own
    // group (CK-24, CK-118).
    .{ .name = "ck117", .path = "tests/pending/run/DerivedContextPassMergesDown", .module = "Main.beni", .expect = .{ .prints = "tests/pending/run/DerivedContextPassMergesDown/_expected.expected" } },
    .{ .name = "d1-inside", .path = "tests/corpus/run/PrivateEqInsideModule", .module = "M.beni", .expect = .{ .prints = "tests/corpus/run/PrivateEqInsideModule/_expected.expected" } },
    .{ .name = "d1-declaring", .path = "tests/pending/check/bad/PrivateEqThroughThirdModule", .module = "A.beni", .refused_in = "C.beni", .expect = .{ .refused = .private_method } },
    .{ .name = "d1-wrapping", .path = "tests/pending/check/bad/PrivateEqThroughThirdModule", .module = "B.beni", .refused_in = "C.beni", .expect = .{ .refused = .private_method } },
    .{ .name = "ck24-through-own", .path = "tests/pending/check/bad/SchemaWrapperExclusionThroughOwnType.beni", .expect = .{ .refused = .not_equatable } },
    .{ .name = "ck24-in-flight", .path = "tests/pending/check/bad/SchemaEndpointInFlight.beni", .expect = .{ .refused = .method_needs_annotation } },
    // R8b's review round: a closed endpoint compared while its schema is in
    // flight is deferred (accepted, or refused once the group is done), an
    // encoded one is never in flight, and a ring closed only through `via`s
    // is one unit (CK-119).
    .{ .name = "ck24-in-flight-closed", .path = "tests/corpus/check/good/SchemaEndpointInFlightClosed.beni", .expect = .checks },
    .{ .name = "ck24-in-flight-function", .path = "tests/pending/check/bad/SchemaEndpointInFlightFunction.beni", .expect = .{ .refused = .not_equatable } },
    .{ .name = "ck24-encoded-in-flight", .path = "tests/corpus/check/good/SchemaEncodedInFlight.beni", .expect = .checks },
    .{ .name = "ck119-ring", .path = "tests/corpus/check/good/SchemaViaRing.beni", .expect = .checks },
    // R8b's round-2 review: the §11.4 gate demands the schemas it reaches
    // and defers one in flight (CK-120) — each use of the local fixture
    // counted — and a run's own step budget (CK-125).
    .{ .name = "ck120-local", .path = "tests/pending/check/bad/EquatableMarkerThroughWrappedEndpointLocal.beni", .count = 2, .expect = .{ .refused = .not_equatable } },
    .{ .name = "ck120-unchecked", .path = "tests/pending/check/bad/EquatableMarkerUncheckedSchema.beni", .expect = .{ .refused = .not_equatable } },
    .{ .name = "ck120-in-flight", .path = "tests/pending/check/bad/EquatableMarkerInFlightSchema.beni", .expect = .{ .refused = .not_equatable } },
    .{ .name = "ck118-joint", .path = "tests/pending/check/good/SchemaViaMutualOwnType.beni", .expect = .checks },
    .{ .name = "ck118-record", .path = "tests/pending/check/good/SchemaRecordViaWrapped.beni", .expect = .checks },
};

test "PERM: every declaration order of an own-method program does what its twin says" {
    var s = try Scenario.init("PERM");
    defer s.deinit();
    var orders: usize = 0;
    for (perm_programs, 0..) |p, i| {
        const outcome = try permuteProgram(&s, p, i);
        switch (outcome) {
            .orders => |n| orders += n,
            .red => |v| return s.finish(v),
        }
    }
    try s.finish(.{ .green = true, .signature = "", .detail = try std.fmt.allocPrint(s.arena(), "{d} programs, {d} orders", .{ perm_programs.len, orders }) });
}

const PermProgram = struct {
    name: []const u8,
    /// A single-file fixture, or a project directory with `module` the file
    /// whose declarations are permuted.
    path: []const u8,
    module: ?[]const u8 = null,
    /// A project refused in ANOTHER file than the one permuted (R8b: D1's
    /// comparison two modules away from the private `eq`): the one
    /// diagnostic is asserted there, at the same text in every order.
    refused_in: ?[]const u8 = null,
    /// How many diagnostics the refusal is, all of the expected code:
    /// exactly that many in every order (R8b's round-2 review).
    count: u32 = 1,
    expect: union(enum) {
        /// The oracle twin's stdout, as a file.
        prints: []const u8,
        checks,
        refused: @import("diagnostic").Code,
        /// One diagnostic of this code at the same source text in every
        /// order; its message may show a type as it stood when the refusal
        /// was found (checker-v2.md §10.8, I9's scope).
        refused_region: @import("diagnostic").Code,
    },
};

/// Most orders tried per program.
const perm_cap = 120;

/// A source file split at its top-level declarations: the `import` lines, and
/// each declaration with its annotation. Top-level comments are dropped.
const Split = struct { imports: []const u8, decls: []const []const u8 };

fn splitDecls(arena: std.mem.Allocator, text: []const u8) !Split {
    var imports: std.ArrayList(u8) = .empty;
    var decls: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    // The name the current declaration's annotation names, while its
    // definition has not started.
    var annotated: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == ' ') {
            if (current.items.len != 0) {
                try current.appendSlice(arena, line);
                try current.append(arena, '\n');
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "--")) continue;
        if (std.mem.startsWith(u8, line, "import ")) {
            try imports.appendSlice(arena, line);
            try imports.append(arena, '\n');
            continue;
        }
        const rest = if (std.mem.startsWith(u8, line, "pub ")) line[4..] else line;
        const name = rest[0 .. std.mem.indexOfAny(u8, rest, " (=:") orelse rest.len];
        const is_annotation = std.mem.startsWith(u8, rest[name.len..], " : ");
        const joins = !is_annotation and annotated != null and std.mem.eql(u8, annotated.?, name);
        if (!joins and current.items.len != 0) {
            try decls.append(arena, std.mem.trimEnd(u8, current.items, "\n"));
            current = .empty;
        }
        annotated = if (is_annotation) name else null;
        try current.appendSlice(arena, line);
        try current.append(arena, '\n');
    }
    if (current.items.len != 0) try decls.append(arena, std.mem.trimEnd(u8, current.items, "\n"));
    return .{ .imports = imports.items, .decls = decls.items };
}

/// `main : Program` / `main = Node.printLines X` made `pub lines : List
/// String` / `lines = X`, so a packing `Main` can print it.
fn asLines(arena: std.mem.Allocator, decl: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, decl, "main ")) return decl;
    const a = try std.mem.replaceOwned(u8, arena, decl, "main : Program", "pub lines : List String");
    const b = try std.mem.replaceOwned(u8, arena, a, "\nmain =", "\nlines =");
    return std.mem.replaceOwned(u8, arena, b, "Node.printLines", "");
}

/// n!, saturating.
fn factorial(n: usize) u128 {
    var f: u128 = 1;
    var i: usize = 2;
    while (i <= n) : (i += 1) f = std.math.mul(u128, f, i) catch return std.math.maxInt(u128);
    return f;
}

/// The permutation of `0..out.len` of lexicographic rank `rank`.
fn permutationAt(out: []usize, rank: u128) void {
    var pool: [32]usize = undefined;
    for (0..out.len) |i| pool[i] = i;
    var left = out.len;
    var r = rank;
    for (out) |*slot| {
        const f = factorial(left - 1);
        const d: usize = @intCast(r / f);
        r %= f;
        slot.* = pool[d];
        std.mem.copyForwards(usize, pool[d .. left - 1], pool[d + 1 .. left]);
        left -= 1;
    }
}

/// The orders tried for `n` declarations: every one when there are at most
/// `perm_cap`, else `perm_cap` ranks spread evenly from the first to the last
/// (the reversed order).
fn orderRanks(arena: std.mem.Allocator, n: usize) ![]const u128 {
    const total = factorial(n);
    const count: usize = if (total <= perm_cap) @intCast(total) else perm_cap;
    const ranks = try arena.alloc(u128, count);
    for (ranks, 0..) |*r, k| r.* = if (count == 1) 0 else if (total <= perm_cap) k else (total - 1) * k / (count - 1);
    return ranks;
}

const PermOutcome = union(enum) { orders: usize, red: Verdict };

fn readRepo(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(world.max_stream_bytes));
}

/// Program `p`'s orders, tried (`perm_programs`' comment); `index` names its
/// modules.
fn permuteProgram(s: *Scenario, p: PermProgram, index: usize) !PermOutcome {
    const a = s.arena();
    const source_path = if (p.module) |m| try std.fs.path.join(a, &.{ p.path, m }) else p.path;
    const split = try splitDecls(a, try readRepo(a, source_path));
    const ranks = try orderRanks(a, split.decls.len);
    const order = try a.alloc(usize, split.decls.len);
    const files = try a.alloc([]const u8, ranks.len);
    const texts = try a.alloc([]const u8, ranks.len);
    const orders = try a.alloc([]const usize, ranks.len);
    for (ranks, files, texts, orders, 0..) |rank, *file, *text, *o, k| {
        permutationAt(order, rank);
        o.* = try a.dupe(usize, order);
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, split.imports);
        for (order) |d| {
            try out.appendSlice(a, "\n\n");
            try out.appendSlice(a, if (p.module == null and p.expect == .prints) try asLines(a, split.decls[d]) else split.decls[d]);
            try out.append(a, '\n');
        }
        text.* = out.items;
        file.* = if (p.module) |m| m else try std.fmt.allocPrint(a, "Perm{d}x{d}.beni", .{ index, k });
    }
    const red = if (p.module) |module|
        try permuteProject(s, p, module, files, texts, orders)
    else switch (p.expect) {
        .prints => |twin| try permutePrints(s, p, index, twin, files, texts, orders),
        .checks => try permuteChecks(s, p, files, texts, orders),
        .refused => |code| try permuteRefused(s, p, code, true, files, texts, orders),
        .refused_region => |code| try permuteRefused(s, p, code, false, files, texts, orders),
    };
    if (red) |v| return .{ .red = v };
    return .{ .orders = ranks.len };
}

fn redAt(s: *Scenario, p: PermProgram, order: []const usize, v: Verdict, total: usize) !Verdict {
    return .{ .green = false, .signature = v.signature, .detail = try std.fmt.allocPrint(s.arena(), "{s} (of {d} orders), order {any}: {s}", .{ p.name, total, order, v.detail[0..@min(v.detail.len, 600)] }) };
}

/// The order whose module a build's first diagnostic is in.
fn failingOrder(built: world.Result, files: []const []const u8) usize {
    var best: usize = 0;
    var at: usize = std.math.maxInt(usize);
    for (files, 0..) |f, k| {
        const pos = std.mem.indexOf(u8, built.stderr, f) orelse continue;
        if (pos < at) {
            at = pos;
            best = k;
        }
    }
    return best;
}

/// Every order of a single-file program in one build: `PermMain<i>` prints
/// each order's `lines`, so the run must print the twin's output once per
/// order.
fn permutePrints(s: *Scenario, p: PermProgram, index: usize, twin: []const u8, files: []const []const u8, texts: []const []const u8, orders: []const []const usize) !?Verdict {
    const a = s.arena();
    for (files, texts) |f, t| try s.w.write(f, t);
    var main: std.ArrayList(u8) = .empty;
    try main.appendSlice(a, "import Node exposing (Program)\n");
    for (0..files.len) |k| try main.print(a, "import Perm{d}x{d}\n", .{ index, k });
    try main.appendSlice(a, "\n\nmain : Program\nmain =\n    Node.printLines\n        (List.concat\n            [ ");
    for (0..files.len) |k| {
        if (k != 0) try main.appendSlice(a, "            , ");
        try main.print(a, "Perm{d}x{d}.lines\n", .{ index, k });
    }
    try main.appendSlice(a, "            ]\n        )\n");
    const entry = try std.fmt.allocPrint(a, "PermMain{d}.beni", .{index});
    try s.w.write(entry, main.items);
    const out_dir = try std.fmt.allocPrint(a, "out{d}", .{index});
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "build", "--no-cache", "--diagnostics=json", "--platform=node", try std.fmt.allocPrint(a, "--out={s}", .{out_dir}), entry });
    try args.appendSlice(a, files);
    const built = try s.w.runWith(try s.argv(args.items), .{ .raw_diagnostics = true, .timeout_ms = world.bulk_timeout_ms });
    if (built.exit_code != 0) {
        const k = failingOrder(built, files);
        return try redAt(s, p, orders[k], try s.failed(built), files.len);
    }
    const program = try s.w.nodeWith(try std.fmt.allocPrint(a, "{s}/_main.mjs", .{out_dir}), world.bulk_timeout_ms);
    if (program.exit_code != 0) return try redAt(s, p, orders[0], .{ .green = false, .signature = try std.fmt.allocPrint(a, "exit=0 program-exit={d}", .{program.exit_code}), .detail = std.mem.trim(u8, program.stderr[0..@min(program.stderr.len, 160)], " \r\n") }, files.len);
    const expected = try readRepo(a, twin);
    for (orders, 0..) |o, k| {
        const at = k * expected.len;
        if (program.stdout.len < at + expected.len or !std.mem.eql(u8, program.stdout[at..][0..expected.len], expected)) {
            return try redAt(s, p, o, .{ .green = false, .signature = "exit=0 stdout-differs", .detail = "" }, files.len);
        }
    }
    if (program.stdout.len != expected.len * files.len) return try redAt(s, p, orders[0], .{ .green = false, .signature = "exit=0 stdout-differs", .detail = "" }, files.len);
    return try sameTypes(s, p, files, orders);
}

/// Every order checks, and has the same types.
fn permuteChecks(s: *Scenario, p: PermProgram, files: []const []const u8, texts: []const []const u8, orders: []const []const usize) !?Verdict {
    const a = s.arena();
    for (files, texts) |f, t| try s.w.write(f, t);
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "check", "--no-cache", "--diagnostics=json", "--platform=node" });
    try args.appendSlice(a, files);
    const run = try s.w.runWith(try s.argv(args.items), .{ .raw_diagnostics = true, .timeout_ms = world.bulk_timeout_ms });
    if (run.exit_code != 0 or std.mem.trim(u8, run.stderr, " \r\n").len != 0) {
        return try redAt(s, p, orders[failingOrder(run, files)], try s.failed(run), files.len);
    }
    return try sameTypes(s, p, files, orders);
}

/// `dump --stage=types` of the written order, the reversed one and four
/// between: each declaration's block the same, wherever it is written.
fn sameTypes(s: *Scenario, p: PermProgram, files: []const []const u8, orders: []const []const usize) !?Verdict {
    const a = s.arena();
    const picks = [_]usize{ 0, files.len / 5, 2 * files.len / 5, 3 * files.len / 5, 4 * files.len / 5, files.len - 1 };
    var first: ?[]const u8 = null;
    for (picks) |k| {
        const run = try s.w.runWith(try s.argv(&.{ "dump", "--stage=types", "--platform=node", files[k] }), .{ .raw_diagnostics = true });
        if (run.exit_code != 0) return try redAt(s, p, orders[k], try s.failed(run), files.len);
        const blocks = try declBlocks(a, run.stdout);
        if (first) |f| {
            if (!std.mem.eql(u8, f, blocks)) {
                var at: usize = 0;
                while (at < f.len and at < blocks.len and f[at] == blocks[at]) at += 1;
                const from = std.mem.lastIndexOfScalar(u8, f[0..at], '\n') orelse 0;
                const detail = try std.mem.replaceOwned(u8, a, try std.fmt.allocPrint(a, "dump --stage=types differs from the written order's: {s} vs {s}", .{ f[from..@min(f.len, from + 90)], blocks[from..@min(blocks.len, from + 90)] }), "\n", " | ");
                return try redAt(s, p, orders[k], .{ .green = false, .signature = "exit=0 types-differ", .detail = detail }, files.len);
            }
        } else first = blocks;
    }
    return null;
}

/// A types dump's declaration blocks, sorted and joined, without its
/// `module` line.
fn declBlocks(a: std.mem.Allocator, dump: []const u8) ![]const u8 {
    var blocks: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, dump, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "module ") or std.mem.trim(u8, line, " ").len == 0) continue;
        if (line.len > 2 and line[0] == ' ' and line[1] == ' ' and line[2] != ' ') {
            if (current.items.len != 0) try blocks.append(a, current.items);
            current = .empty;
        }
        try current.appendSlice(a, line);
        try current.append(a, '\n');
    }
    if (current.items.len != 0) try blocks.append(a, current.items);
    std.mem.sort([]const u8, blocks.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    var out: std.ArrayList(u8) = .empty;
    for (blocks.items) |b| try out.appendSlice(a, b);
    return out.items;
}

/// Every order refused with one diagnostic of `code`, byte-identical: the
/// same message, and the same text under its span.
fn permuteRefused(s: *Scenario, p: PermProgram, code: @import("diagnostic").Code, same_text: bool, files: []const []const u8, texts: []const []const u8, orders: []const []const usize) !?Verdict {
    const a = s.arena();
    for (files, texts) |f, t| try s.w.write(f, t);
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "check", "--no-cache", "--diagnostics=json", "--platform=node" });
    try args.appendSlice(a, files);
    const run = try s.w.runWith(try s.argv(args.items), .{ .raw_diagnostics = true, .timeout_ms = world.bulk_timeout_ms });
    const trimmed = std.mem.trim(u8, run.stderr, " \r\n");
    const diags = std.json.parseFromSliceLeaky([]@import("diagnostic").Diagnostic, a, trimmed, .{}) catch return try redAt(s, p, orders[0], try s.failed(run), files.len);
    var reference: ?Refusals = null;
    for (files, texts, orders) |f, t, o| {
        const got = (try refusals(a, diags, f, t, code, p.count)) orelse return try redAt(s, p, o, try s.failed(run), files.len);
        if (reference) |r| {
            if ((same_text and !std.mem.eql(u8, r.message, got.message)) or !std.mem.eql(u8, r.text, got.text)) {
                return try redAt(s, p, o, .{ .green = false, .signature = try std.fmt.allocPrint(a, "exit=1 codes={t}×{d} differs", .{ code, p.count }), .detail = "the diagnostics differ from the written order's" }, files.len);
            }
        } else reference = got;
    }
    return null;
}

/// A permuted program's refusals in one file (R8b's round-2 review): exactly
/// `count` diagnostics, every one of `code`, as their messages and the source
/// text under their spans, sorted — so the same refusals in any order of
/// declarations compare equal. Null when the count or a code differs.
const Refusals = struct { message: []const u8, text: []const u8 };

fn refusals(a: std.mem.Allocator, diags: []const @import("diagnostic").Diagnostic, file: []const u8, source: []const u8, code: @import("diagnostic").Code, count: u32) !?Refusals {
    var pairs: std.ArrayList([2][]const u8) = .empty;
    for (diags) |d| {
        if (!std.mem.eql(u8, std.fs.path.basename(d.span.file), file)) continue;
        if (d.code != code) return null;
        try pairs.append(a, .{ spanText(source, d.span.start.line, d.span.start.col, d.span.end.line, d.span.end.col), d.message });
    }
    if (pairs.items.len != count) return null;
    std.mem.sort([2][]const u8, pairs.items, {}, struct {
        fn lessThan(_: void, x: [2][]const u8, y: [2][]const u8) bool {
            const o = std.mem.order(u8, x[0], y[0]);
            return if (o != .eq) o == .lt else std.mem.lessThan(u8, x[1], y[1]);
        }
    }.lessThan);
    var message: std.ArrayList(u8) = .empty;
    var text: std.ArrayList(u8) = .empty;
    for (pairs.items) |pr| {
        try text.appendSlice(a, pr[0]);
        try text.append(a, 0);
        try message.appendSlice(a, pr[1]);
        try message.append(a, 0);
    }
    return .{ .message = message.items, .text = text.items };
}

/// The source text from `line:col` to `end_line:end_col` (1-based, the end
/// exclusive).
fn spanText(text: []const u8, line: usize, col: usize, end_line: usize, end_col: usize) []const u8 {
    const start = offsetOf(text, line, col) orelse return "";
    const end = offsetOf(text, end_line, end_col) orelse return "";
    return if (end >= start) text[start..end] else "";
}

fn offsetOf(text: []const u8, line: usize, col: usize) ?usize {
    var at: usize = 0;
    var l: usize = 1;
    while (l < line) : (l += 1) at = (std.mem.indexOfScalarPos(u8, text, at, '\n') orelse return null) + 1;
    return @min(at + col - 1, text.len);
}

/// A project's module in every order, one build each: the project's other
/// files as they are.
fn permuteProject(s: *Scenario, p: PermProgram, module: []const u8, files: []const []const u8, texts: []const []const u8, orders: []const []const usize) !?Verdict {
    const a = s.arena();
    _ = files;
    var dir = try Io.Dir.cwd().openDir(testing.io, p.path, .{ .iterate = true });
    defer dir.close(testing.io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".beni")) continue;
        const name = try a.dupe(u8, entry.name);
        try names.append(a, name);
        if (std.mem.eql(u8, name, module)) continue;
        try s.w.write(name, try readRepo(a, try std.fs.path.join(a, &.{ p.path, name })));
    }
    switch (p.expect) {
        .prints => |twin_path| {
            const twin = try readRepo(a, twin_path);
            var sources: std.ArrayList([]const u8) = .empty;
            try sources.appendSlice(a, &.{ "build", "--no-cache", "--diagnostics=json", "--platform=node", "--out=out" });
            try sources.appendSlice(a, names.items);
            for (texts, orders) |t, o| {
                try s.w.write(module, t);
                const built = try s.w.runWith(try s.argv(sources.items), .{ .raw_diagnostics = true });
                if (built.exit_code != 0) return try redAt(s, p, o, try s.failed(built), texts.len);
                const program = try s.w.node(world.entry_file);
                if (program.exit_code != 0 or !std.mem.eql(u8, program.stdout, twin)) {
                    return try redAt(s, p, o, .{ .green = false, .signature = "exit=0 stdout-differs", .detail = "" }, texts.len);
                }
            }
            return null;
        },
        .refused, .refused_region => |code| {
            // R8a: a project's module refused in every order — one
            // diagnostic of `code` in that module (another module of the
            // project may say its own), at the same source text in every
            // order, with the same message unless `refused_region`.
            const same_text = p.expect == .refused;
            // R8b: the refusal may be in another file than the permuted one.
            const target = p.refused_in orelse module;
            const target_text: ?[]const u8 = if (p.refused_in) |f| try readRepo(a, try std.fs.path.join(a, &.{ p.path, f })) else null;
            var args: std.ArrayList([]const u8) = .empty;
            try args.appendSlice(a, &.{ "check", "--no-cache", "--diagnostics=json", "--platform=node" });
            try args.appendSlice(a, names.items);
            var reference: ?Refusals = null;
            for (texts, orders) |t, o| {
                try s.w.write(module, t);
                const run = try s.w.runWith(try s.argv(args.items), .{ .raw_diagnostics = true, .timeout_ms = world.bulk_timeout_ms });
                const trimmed = std.mem.trim(u8, run.stderr, " \r\n");
                const diags = std.json.parseFromSliceLeaky([]@import("diagnostic").Diagnostic, a, trimmed, .{}) catch return try redAt(s, p, o, try s.failed(run), texts.len);
                const got = (try refusals(a, diags, target, target_text orelse t, code, p.count)) orelse return try redAt(s, p, o, try s.failed(run), texts.len);
                if (reference) |ref| {
                    if ((same_text and !std.mem.eql(u8, ref.message, got.message)) or !std.mem.eql(u8, ref.text, got.text)) {
                        return try redAt(s, p, o, .{ .green = false, .signature = try std.fmt.allocPrint(a, "exit=1 codes={t}×{d} differs", .{ code, p.count }), .detail = "the diagnostics differ from the written order's" }, texts.len);
                    }
                } else reference = got;
            }
            return null;
        },
        .checks => unreachable,
    }
}

// R7's nesting scenarios (S-3, S-4; checker-v2.md §10.2): chains of own
// methods `m0 … mn` on one type, each calling the next, written in REVERSE
// dependency order (`m0`, which needs `m1`, first), so checking `m0` nests
// `m1`, which nests `m2`, and so on. The budget admits a nested check while
// the solver depth summed over the open groups, plus `nest_cost` (3) per
// nesting, leaves one declaration's worth (4 200) of the budget (8 400): a
// chain's link costs 4 depth units and 3, so about 599 nest (calibrated in
// a Debug build, 2026-09-26: `Groups.nest_cost`'s comment).
//
//   - NEST-UNDER (ReleaseFast, timed): 40 chains of 250 and of 500 links,
//     below the budget, check in linear time, best-of-3 CPU ratio ≤ 2.5.
//     (Each chain's depth doubles with n; a nesting cost that grew with the
//     depth — a queue or a frame walk per nesting — reads as 4.)
//   - NEST-OVER (Debug): one chain of 1 000 links is refused exactly once —
//     the check that `m0` started runs out at about the 600th link and is
//     refused at that use, and the rest is checked from the next group in
//     SCC order, within the budget — with the hint, and no crash.
//   - NEST-DEEP (Debug): round 4's "pair of deep declarations" (§5.6),
//     which the budget as specified admits (a demand at depth 2 500 leaves
//     5 900 units): what reaches the refusal is a chain of TWO demands each
//     about 2 150 levels deep. Written with the user first, exactly one
//     `nesting_too_deep`, at the second use, with the hint; with the
//     methods first, it checks (I9's stated exception, §10.5).
test "NEST-UNDER: a reverse-ordered chain of own methods checks in linear time" {
    var s = try Scenario.init("NEST-UNDER");
    defer s.deinit();
    try s.w.write("C.beni", try chains(s.arena(), 40, 250));
    try s.w.write("C2.beni", try chains(s.arena(), 40, 500));
    const verdict = try s.ratio("C.beni", "C2.beni", 250);
    try s.finish(verdict);
}

test "NEST-OVER: a chain past the nesting budget is one nesting_too_deep" {
    var s = try Scenario.init("NEST-OVER");
    defer s.deinit();
    try s.w.write("C.beni", try chains(s.arena(), 1, 1_000));
    const verdict = try s.exactlyOneHinted(&.{ "check", "--no-cache", "--diagnostics=json", "C.beni" }, .nesting_too_deep);
    try s.finish(verdict);
}

test "NEST-DEEP: two deep demands in a row are refused once, and the other order checks" {
    var s = try Scenario.init("NEST-DEEP");
    defer s.deinit();
    const a = s.arena();
    const user = try deepUse(a, "use u =\n    ", "(T 0).m ()", 2_150);
    const method = try deepUse(a, "pub m (T x) u =\n    ", "(T x).m2 ()", 2_150);
    const last = "pub m2 (T x) u =\n    x\n";
    try s.w.write("First.beni", try std.mem.concat(a, u8, &.{ "type T\n    = T Int\n\n\nf x =\n    x\n\n\n", user, "\n\n", method, "\n\n", last }));
    try s.w.write("Last.beni", try std.mem.concat(a, u8, &.{ "type T\n    = T Int\n\n\nf x =\n    x\n\n\n", last, "\n\n", method, "\n\n", user }));
    const refused = try s.exactlyOneHinted(&.{ "check", "--no-cache", "--diagnostics=json", "First.beni" }, .nesting_too_deep);
    if (!refused.green) return s.finish(refused);
    const run = try s.timed(&.{ "check", "--no-cache", "--diagnostics=json", "Last.beni" }, world.bulk_timeout_ms) orelse
        return s.finish(.{ .green = false, .signature = "timeout", .detail = "Last.beni did not finish" });
    if (run.result.exit_code != 0) return s.finish(try s.failed(run.result));
    try s.finish(.{ .green = true, .signature = "", .detail = try std.fmt.allocPrint(a, "{s}; the other order checks", .{refused.detail}) });
}

/// `head` then `f (f (… inner …))`, `depth` calls deep.
fn deepUse(arena: std.mem.Allocator, head: []const u8, inner: []const u8, depth: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, head);
    for (0..depth) |_| try out.appendSlice(arena, "f (");
    try out.appendSlice(arena, inner);
    for (0..depth) |_| try out.append(arena, ')');
    try out.append(arena, '\n');
    return out.items;
}

// CK-82: a nominal payload record of 65 537 fields. The eager pass probes
// `T`'s derived `eq`, and `Solve.derivedUse` casts the field count into the
// `u16` evidence count: a panic in Debug (`crash=ABRT`), whether or not
// anything compares `T`. 65 535 builds and runs (`abuse_test.zig`, CK-81).
// 65 537 and not 65 536 since R8a's review: the record's structural row has
// one entry per field, so its last entry's index `k` is 65 536, one past
// what a `u16` `Dispatch.Param.k` holds (CK-109).
// GREEN is the program built and run, printing its two answers, or a named
// refusal: exit 1 with diagnostics and not one of them `internal`.
test "CK-82: a nominal payload of 65 537 fields checks, and builds and runs or is refused by name" {
    var s = try Scenario.init("CK-82");
    defer s.deinit();
    const n = 65_537;
    const a = s.arena();
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "import Node exposing (Program)\n\n\ntype T =\n    T { ");
    for (1..n + 1) |i| try text.print(a, "{s}f{d} : Int", .{ if (i == 1) "" else ", ", i });
    try text.appendSlice(a, " }\n\n\nr =\n    { ");
    for (1..n + 1) |i| try text.print(a, "{s}f{d} = {d}", .{ if (i == 1) "" else ", ", i, i });
    try text.print(a, " }}\n\n\nmain : Program\nmain =\n    Node.printLines [ if T r == T r then \"eq\" else \"ne\", if T r == T {{ r | f{d} = 0 }} then \"eq\" else \"ne\" ]\n", .{n});
    try s.w.write("Main.beni", text.items);
    const verdict = try s.runsOrRefuses("Main.beni", "eq\nne\n");
    try s.finish(verdict);
}

// CK-79: `==` and `<` on a record of 40 000 fields. The old checker caps a
// derived record `eq`/`compare` at `max_derived_record_fields` = 4 096
// (`not_equatable` and `no_methods_on_shape` past it, R1), because a derived
// function took one JavaScript parameter per field and V8 threw between
// 40 000 and 60 000. The wide form (`static-dispatch-spike.md` §9.2, CK-81)
// takes the evidence as one array past 4 096 positions, so R8a's checker
// lifts the cap (checker-v2.md §11.2's D4 bullet). GREEN is the program
// built and run, printing its three answers; a refusal is RED.
test "CK-79: `==` and `<` on a 40 000-field record build and run" {
    var s = try Scenario.init("CK-79");
    defer s.deinit();
    const n = 40_000;
    const a = s.arena();
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "import Node exposing (Program)\n\n\nr =\n    { ");
    for (1..n + 1) |i| try text.print(a, "{s}f{d} = {d}", .{ if (i == 1) "" else ", ", i, i });
    try text.print(a, " }}\n\n\nmain : Program\nmain =\n    Node.printLines [ if r == r then \"eq\" else \"ne\", if r == {{ r | f{d} = 0 }} then \"eq\" else \"ne\", if {{ r | f1 = 0 }} < r then \"lt\" else \"ge\" ]\n", .{n});
    try s.w.write("Main.beni", text.items);
    const verdict = try s.runs("Main.beni", "eq\nne\nlt\n");
    try s.finish(verdict);
}

// The two lists stay honest: every `CLAIMED` and `RED` entry names a pending
// fixture that exists or a scenario of this file. A fixture promoted into
// the corpus takes its lines with it; a stale one would make rule (c) or (d)
// silently check nothing.
test "pending: CLAIMED and RED name fixtures and scenarios that exist" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Once, in `test-pending`: the lists do not depend on the binary.
    if (try selectedStep(arena) != .fast) return error.SkipZigTest;
    const claimed = try world.pending.readClaimed(arena, testing.io, pending_root);
    const red = try world.pending.readRed(arena, testing.io, pending_root);
    var stale: usize = 0;
    for (claimed) |path| {
        if (!exists(path)) {
            std.debug.print("PENDING  STALE  CLAIMED names {s}, which is neither a pending fixture nor a scenario\n", .{path});
            stale += 1;
        }
    }
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

/// `count` copies of `template` with every `{d}` replaced by the index, 0 to
/// count − 1. `per` is the number of `{d}` in the template, which is only a
/// check that the template says what its caller thinks it says.
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

/// `pub g k = case k of 0 -> 0; 1 -> 1; … _ -> -1` with `count` literal
/// branches.
fn bigCase(arena: std.mem.Allocator, count: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "pub g : Int -> Int\ng k =\n    case k of\n");
    for (0..count) |i| try out.print(arena, "        {d} ->\n            {d}\n\n", .{ i, i });
    try out.appendSlice(arena, "        _ ->\n            -1\n");
    return out.items;
}

/// `count` chains of `n + 1` own methods, chain `c` on type `Tc`:
/// `pub mc_0 (Tc x) u = (Tc x).mc_1 ()` … `pub mc_n (Tc x) u = x`, each
/// written BEFORE the one it calls.
fn chains(arena: std.mem.Allocator, count: usize, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..count) |c| {
        try out.print(arena, "type T{d}\n    = T{d} Int\n\n\n", .{ c, c });
        for (0..n) |i| try out.print(arena, "pub m{d}_{d} (T{d} x) u =\n    (T{d} x).m{d}_{d} ()\n\n\n", .{ c, i, c, c, c, i + 1 });
        try out.print(arena, "pub m{d}_{d} (T{d} x) u =\n    x\n\n\n", .{ c, n, c });
    }
    return out.items;
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
    checker: ?[]const u8,
    claimed: []const []const u8,
    red: []const world.pending.RedLine,
    /// Runs per point of `best` (`extraRatio`); a scenario may raise it.
    best_of: usize = 3,

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
            .checker = null,
            .claimed = &.{},
            .red = &.{},
        };
        const a = s.arena_state.allocator();
        s.checker = blk: {
            const value = testing.environ.getAlloc(a, "BENI_CHECKER") catch break :blk null;
            break :blk if (value.len == 0) null else value;
        };
        s.claimed = try world.pending.readClaimed(a, testing.io, pending_root);
        s.red = try world.pending.readRed(a, testing.io, pending_root);
        return s;
    }

    fn deinit(s: *Scenario) void {
        s.w.deinit();
        s.arena_state.deinit();
    }

    fn arena(s: *Scenario) std.mem.Allocator {
        return s.arena_state.allocator();
    }

    fn checkerName(s: *const Scenario) []const u8 {
        return s.checker orelse "v1";
    }

    /// `args` plus `--checker=<value>` when `BENI_CHECKER` is set, as the
    /// corpus walker does.
    fn argv(s: *Scenario, args: []const []const u8) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        try list.appendSlice(s.arena(), args);
        if (s.checker) |checker| try list.append(s.arena(), try std.fmt.allocPrint(s.arena(), "--checker={s}", .{checker}));
        return list.items;
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
        const result = s.w.runWith(try s.argv(args), .{ .raw_diagnostics = true, .timeout_ms = kill_ms }) catch |err| switch (err) {
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

    /// An absolute bound: GREEN when one of 3 runs (the best of 3) finishes
    /// within `bound_ms`, exits 1 and reports `code`.
    fn bounded(s: *Scenario, args: []const []const u8, bound_ms: i64, code: @import("diagnostic").Code) !Verdict {
        for (0..3) |_| {
            // Killed at twice the bound of WALL time, judged on CPU time.
            const run = try s.timed(args, bound_ms * 2) orelse continue;
            if (run.ms > bound_ms) continue;
            const trimmed = std.mem.trim(u8, run.result.stderr, " \r\n");
            const diags = std.json.parseFromSliceLeaky([]@import("diagnostic").Diagnostic, s.arena(), trimmed, .{}) catch return s.failed(run.result);
            const reported = for (diags) |d| {
                if (d.code == code) break true;
            } else false;
            if (run.result.exit_code != 1 or !reported) return s.failed(run.result);
            return .{ .green = true, .signature = "", .detail = try std.fmt.allocPrint(s.arena(), "{t} in {d} ms", .{ code, run.ms }) };
        }
        return .{ .green = false, .signature = "timeout", .detail = try std.fmt.allocPrint(s.arena(), "no run of 3 finished within {d} ms of CPU time", .{bound_ms}) };
    }

    /// `file` built for Node and run: GREEN when it runs and prints
    /// `expected` (detail `ran …`), or when the build is REFUSED by name —
    /// exit 1, diagnostics, none of them `internal` (detail `refused …`). Red
    /// is `crash=<signal>`, `exit=<n> codes=…`, `exit=0 program-exit=<n>` or
    /// `exit=0 stdout-differs`.
    fn runsOrRefuses(s: *Scenario, file: []const u8, expected: []const u8) !Verdict {
        const a = s.arena();
        const run = try s.timed(&.{ "build", "--no-cache", "--jobs=1", "--diagnostics=json", "--platform=node", "--out=out", file }, world.bulk_timeout_ms) orelse
            return .{ .green = false, .signature = "timeout", .detail = try std.fmt.allocPrint(a, "{s} did not finish within {d} ms", .{ file, world.bulk_timeout_ms }) };
        const built = run.result;
        switch (built.term) {
            .exited => {},
            .signal => |sig| return .{ .green = false, .signature = try std.fmt.allocPrint(a, "crash={t}", .{sig}), .detail = std.mem.trim(u8, built.stderr[0..@min(built.stderr.len, 160)], " \r\n") },
            else => return .{ .green = false, .signature = "crash=unknown", .detail = "" },
        }
        if (built.exit_code != 0) {
            const trimmed = std.mem.trim(u8, built.stderr, " \r\n");
            const diags = std.json.parseFromSliceLeaky([]@import("diagnostic").Diagnostic, a, trimmed, .{}) catch return s.failed(built);
            if (built.exit_code != 1 or diags.len == 0) return s.failed(built);
            for (diags) |d| if (d.code == .internal) return s.failed(built);
            return .{ .green = true, .signature = "", .detail = try std.fmt.allocPrint(a, "refused: {t} in {d} ms", .{ diags[0].code, run.ms }) };
        }
        const program = try s.w.nodeWith(world.entry_file, world.bulk_timeout_ms);
        if (program.exit_code != 0) return .{ .green = false, .signature = try std.fmt.allocPrint(a, "exit=0 program-exit={d}", .{program.exit_code}), .detail = std.mem.trim(u8, program.stderr[0..@min(program.stderr.len, 160)], " \r\n") };
        if (!std.mem.eql(u8, program.stdout, expected)) return .{ .green = false, .signature = "exit=0 stdout-differs", .detail = "" };
        return .{ .green = true, .signature = "", .detail = try std.fmt.allocPrint(a, "ran in {d} ms", .{run.ms}) };
    }

    /// `runsOrRefuses` where a refusal is RED: the program must build, run
    /// and print `expected` (CK-79, whose refusal IS the finding).
    fn runs(s: *Scenario, file: []const u8, expected: []const u8) !Verdict {
        const a = s.arena();
        const run = try s.timed(&.{ "build", "--no-cache", "--jobs=1", "--diagnostics=json", "--platform=node", "--out=out", file }, world.bulk_timeout_ms) orelse
            return .{ .green = false, .signature = "timeout", .detail = try std.fmt.allocPrint(a, "{s} did not finish within {d} ms", .{ file, world.bulk_timeout_ms }) };
        const built = run.result;
        switch (built.term) {
            .exited => {},
            .signal => |sig| return .{ .green = false, .signature = try std.fmt.allocPrint(a, "crash={t}", .{sig}), .detail = std.mem.trim(u8, built.stderr[0..@min(built.stderr.len, 160)], " \r\n") },
            else => return .{ .green = false, .signature = "crash=unknown", .detail = "" },
        }
        if (built.exit_code != 0) return s.failed(built);
        const program = try s.w.nodeWith(world.entry_file, world.bulk_timeout_ms);
        if (program.exit_code != 0) return .{ .green = false, .signature = try std.fmt.allocPrint(a, "exit=0 program-exit={d}", .{program.exit_code}), .detail = std.mem.trim(u8, program.stderr[0..@min(program.stderr.len, 160)], " \r\n") };
        if (!std.mem.eql(u8, program.stdout, expected)) return .{ .green = false, .signature = "exit=0 stdout-differs", .detail = "" };
        return .{ .green = true, .signature = "", .detail = try std.fmt.allocPrint(a, "ran in {d} ms", .{run.ms}) };
    }

    /// Exactly one diagnostic, with `code`, exit 1, within the harness's
    /// bulk bound.
    fn exactlyOne(s: *Scenario, args: []const []const u8, code: @import("diagnostic").Code) !Verdict {
        const run = try s.timed(args, world.bulk_timeout_ms) orelse
            return .{ .green = false, .signature = "timeout", .detail = "did not finish" };
        const trimmed = std.mem.trim(u8, run.result.stderr, " \r\n");
        const diags = std.json.parseFromSliceLeaky([]@import("diagnostic").Diagnostic, s.arena(), trimmed, .{}) catch return s.failed(run.result);
        if (run.result.exit_code != 1 or diags.len != 1 or diags[0].code != code) return s.failed(run.result);
        return .{ .green = true, .signature = "", .detail = try std.fmt.allocPrint(s.arena(), "one {t} in {d} ms", .{ code, run.ms }) };
    }

    /// `exactlyOne`, and its message says what to annotate (§10.2's hint).
    fn exactlyOneHinted(s: *Scenario, args: []const []const u8, code: @import("diagnostic").Code) !Verdict {
        const run = try s.timed(args, world.bulk_timeout_ms) orelse
            return .{ .green = false, .signature = "timeout", .detail = "did not finish" };
        const trimmed = std.mem.trim(u8, run.result.stderr, " \r\n");
        const diags = std.json.parseFromSliceLeaky([]@import("diagnostic").Diagnostic, s.arena(), trimmed, .{}) catch return s.failed(run.result);
        if (run.result.exit_code != 1 or diags.len != 1 or diags[0].code != code) return s.failed(run.result);
        if (std.mem.indexOf(u8, diags[0].message, "Hint: annotate `") == null) return .{ .green = false, .signature = "exit=1 no-hint", .detail = diags[0].message[0..@min(diags[0].message.len, 160)] };
        return .{ .green = true, .signature = "", .detail = try std.fmt.allocPrint(s.arena(), "one {t} at {d}:{d}, with the hint, in {d} ms", .{ code, diags[0].span.start.line, diags[0].span.start.col, run.ms }) };
    }

    /// The best of `best_of` (3 unless a scenario says) `check --jobs=1` runs of
    /// `file`, or a red verdict.
    fn best(s: *Scenario, file: []const u8) !union(enum) { ms: i64, red: Verdict } {
        const args = [_][]const u8{ "check", "--no-cache", "--jobs=1", "--diagnostics=json", file };
        var fastest: i64 = std.math.maxInt(i64);
        for (0..s.best_of) |_| {
            const run = try s.timed(&args, world.bulk_timeout_ms) orelse
                return .{ .red = .{ .green = false, .signature = "timeout", .detail = try std.fmt.allocPrint(s.arena(), "{s} did not finish within {d} ms", .{ file, world.bulk_timeout_ms }) } };
            if (run.result.exit_code != 0) return .{ .red = try s.failed(run.result) };
            fastest = @min(fastest, run.ms);
        }
        return .{ .ms = fastest };
    }

    /// A ratio of EXTRA costs: `measured` minus `control` at n and at 2n,
    /// each the best of 3, and extra(2n) / extra(n) ≤ 2.5. For a finding
    /// whose program also carries a super-linear cost that is another
    /// finding's (CK-42 over CK-75): only the difference is this one's.
    fn extraRatio(s: *Scenario, measured: [2][]const u8, control: [2][]const u8, n: usize) !Verdict {
        var ms: [4]i64 = undefined;
        for ([_][]const u8{ measured[0], control[0], measured[1], control[1] }, &ms) |file, *slot| {
            switch (try s.best(file)) {
                .ms => |t| slot.* = t,
                .red => |v| return v,
            }
        }
        const small = @max(ms[0] - ms[1], 1);
        const large = ms[2] - ms[3];
        const hundredths: u64 = @intCast(@max(@divTrunc(large * 100, small), 0));
        const green = large * 2 <= small * 5;
        const detail = try std.fmt.allocPrint(s.arena(), "extra at n={d}: {d} − {d} = {d} ms; at 2n: {d} − {d} = {d} ms; ratio {d}.{d:0>2}, CPU time", .{ n, ms[0], ms[1], small, ms[2], ms[3], large, hundredths / 100, hundredths % 100 });
        return .{ .green = green, .signature = if (green) "" else "slow", .detail = detail };
    }

    /// A ratio: time(2n) / time(n) ≤ 2.5, each the best of 3 `check` runs.
    fn ratio(s: *Scenario, small: []const u8, large: []const u8, n: usize) !Verdict {
        return s.ratioOf(
            &.{ "check", "--no-cache", "--jobs=1", "--diagnostics=json", small },
            &.{ "check", "--no-cache", "--jobs=1", "--diagnostics=json", large },
            n,
        );
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

    /// Print the verdict and apply rules (b)–(d).
    fn finish(s: *Scenario, v: Verdict) !void {
        const checker = s.checkerName();
        if (v.green) {
            std.debug.print("PENDING  GREEN  {s}  {s}  {s}  {s}\n", .{ checker, s.id, s.name, v.detail });
        } else {
            std.debug.print("PENDING  RED    {s}  {s}  {s}  [{s}]  {s}\n", .{ checker, s.id, s.name, v.signature, v.detail });
        }
        const default = s.checker == null;
        if (v.green and default) {
            std.debug.print("PENDING  RULE (b)  {s}  {s} is GREEN under the default checker: move it verbatim into tests/blackbox/perf_test.zig (a timing scenario) or tests/blackbox/abuse_test.zig (any other) and delete its RED line (plans/checker-rewrite.md §2.5)\n", .{ s.id, s.name });
            return error.PendingScenarioIsGreen;
        }
        if (!v.green and s.checker != null and std.mem.eql(u8, s.checker.?, "v2")) {
            for (s.claimed) |path| if (std.mem.eql(u8, path, s.name)) {
                std.debug.print("PENDING  RULE (c)  {s}  {s} is listed in CLAIMED and is RED under v2\n", .{ s.id, s.name });
                return error.ClaimedScenarioIsRed;
            };
        }
        // Rule (d) and the record half of rule (a), under every checker, as
        // the corpus walker applies them.
        const recorded = for (s.red) |line| {
            if (std.mem.eql(u8, line.path, s.name) and std.mem.eql(u8, line.checker, checker)) break line.signature;
        } else null;
        if (!v.green) {
            if (recorded == null) {
                std.debug.print("PENDING  MALFORMED  {s}  {s}  no line in {s}/RED: `{s} {s} {s}`\n", .{ checker, s.id, pending_root, s.name, checker, v.signature });
                return error.PendingScenarioUnrecorded;
            } else if (!std.mem.eql(u8, recorded.?, v.signature)) {
                std.debug.print("PENDING  RULE (d)  {s}  {s}  {s} is red as [{s}], and {s}/RED records [{s}]\n", .{ checker, s.id, s.name, v.signature, pending_root, recorded.? });
                return error.PendingScenarioDrifted;
            }
        } else if (recorded != null and !default) {
            std.debug.print("PENDING  RULE (d)  {s}  {s}  {s} is GREEN, and {s}/RED still records [{s}]: delete the `{s}` line\n", .{ checker, s.id, s.name, pending_root, recorded.?, checker });
            return error.PendingScenarioStaleRecord;
        }
    }
};
