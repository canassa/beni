//! The pending scenarios (`plans/checker-rewrite.md` §2.5): one
//! test per finding of `plans/checker-findings.md` that a corpus
//! fixture cannot state, because its claim is about TIME, or about a program
//! too wide or deep to check in (CK-82, CK-83: generated, as `abuse_test.zig`
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
//!       so it moves VERBATIM into `abuse_test.zig` now;
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
//! (CK-03, CK-40, CK-41, CK-42, CK-75, CK-80, NEST-UNDER) run in `zig build
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
    .{ .name = "scenario/CK-41", .step = .perf },
    .{ .name = "scenario/CK-42", .step = .perf },
    .{ .name = "scenario/CK-75", .step = .perf },
    .{ .name = "scenario/CK-80", .step = .perf },
    .{ .name = "scenario/NEST-UNDER", .step = .perf },
    .{ .name = "scenario/PERM", .step = .fast },
    .{ .name = "scenario/NEST-OVER", .step = .fast },
    .{ .name = "scenario/CK-82", .step = .fast },
    .{ .name = "scenario/CK-83", .step = .fast },
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

// CK-41: `Schemes.Writer.resetMemo` reallocates and memsets its memo to the
// store's size whenever the store grew, and `fillCtorTerms` grows the store
// before every constructor: O(constructors × store). ONE `pub` type with n
// constructors isolates it — a chain of n types (the catalogue's program)
// also carries a per-type super-linear residue that the fix leaves behind
// (CK-75), so its ratio stays over 2.5 with the fix in. Calibration
// (ReleaseFast, CPU): on 050cd2d 2 000 / 3 000 / 4 000 / 6 000 / 8 000
// constructors take 115 / 234 / 390 / 820 / 1 416 ms, a ratio of 3.4 to 3.6
// from 2 000 on; with amortised growth 2 000 / 4 000 / 8 000 / 16 000 / 32 000
// take 9 / 13 / 18 / 30 / 54 ms, 1.4 to 1.8. n = 4 000.
test "CK-41: interface writing is linear in the number of constructors" {
    var s = try Scenario.init("CK-41");
    defer s.deinit();
    try s.w.write("C.beni", try bigType(s.arena(), 4_000));
    try s.w.write("C2.beni", try bigType(s.arena(), 8_000));
    const verdict = try s.ratio("C.beni", "C2.beni", 4_000);
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
test "CK-42: nominal dispatch adds linear cost per declaration" {
    var s = try Scenario.init("CK-42");
    defer s.deinit();
    const nominal = "type T{d}\n    = T{d} Int\n\n\nf{d} : Int -> Bool\nf{d} x =\n    T{d} x == T{d} x\n\n\n";
    const control = "type T{d}\n    = T{d} Int\n\n\nf{d} : Int -> Bool\nf{d} x =\n    x == x\n\n\n";
    try s.w.write("E.beni", try generate(s.arena(), 4_000, nominal, 6));
    try s.w.write("E2.beni", try generate(s.arena(), 8_000, nominal, 6));
    try s.w.write("X.beni", try generate(s.arena(), 4_000, control, 4));
    try s.w.write("X2.beni", try generate(s.arena(), 8_000, control, 4));
    const verdict = try s.extraRatio(.{ "E.beni", "E2.beni" }, .{ "X.beni", "X2.beni" }, 4_000);
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
// criteria), started by R0 with its first program so the hook exists: every
// order of the top-level declarations must build, exit 0 and print the
// oracle twin's output. Merely checking that every order prints the same
// thing would pass if every order failed the same way (S13). The first
// program is CK-64's (`OwnMethodValuePrefix`), whose twin is the corpus
// guard `run/OwnMethodValuePrefixOrdered.beni`; R7 adds the rest of its list
// (`o1`, `row75`, `box`, `m1b`, `p5`, CK-63 to CK-66, the §6 guards, round
// 3's programs, the 3-cycle, and round 4's `evA`/`evB` and `subA`/`subB`
// (CK-76, the same single diagnostic in every order); R8a adds `cbA`/`cbB`
// (CK-77, the same `type_mismatch`) and `xm`/`xm2` (the guard
// `DerivedCrossMethodCycle`, the same refusal). On 7427828 the orders that
// write `use` before
// `eq` are METHOD NEEDS AN ANNOTATION.
// OWED BY R7: the cap of 120 in lexicographic order never moves the first
// declarations (`type T` stays first), which is enough for this program but
// not for R7's larger ones — sample across the whole permutation space.
test "PERM: every declaration order of an own-method program prints the twin's output" {
    var s = try Scenario.init("PERM");
    defer s.deinit();
    const verdict = try s.permutations(
        "import Node exposing (Program)\n\n\n",
        &.{
            "type T\n    = T Int\n",
            "use a b =\n    T a == T b\n",
            "eq (T x) (T y) =\n    helper x y\n",
            "helper x y =\n    modBy x 10 == modBy y 10\n",
            "show : Bool -> String\nshow value =\n    if value then\n        \"True\"\n\n    else\n        \"False\"\n",
            "main : Program\nmain =\n    Node.printLines [ show (use 1 11), show (use 1 2) ]\n",
        },
        "True\nFalse\n",
        120,
    );
    try s.finish(verdict);
}

// R7's nesting scenarios (S-3, S-4), started by R0 as stubs that are red on
// 7427828: a chain of own methods `m0 … mn` on one type, each calling the
// next, written in REVERSE dependency order (`m0`, which needs `m1`, first).
// Below the nesting budget it must check in linear time; above it, it must
// report exactly one `nesting_too_deep` and neither crash nor hang. `n` and
// the budget are R7's to calibrate (`nest_cost`, recorded in the diary);
// the stub's 200 and 20 000 are placeholders that 7427828 refuses with
// METHOD NEEDS AN ANNOTATION either way. OWED BY R7: at 200/400 a fixed
// build takes milliseconds, startup dominates and the ratio reads near 1, so
// a quadratic regression would pass; R7 must size n so the fixed build takes
// at least 0.5 s (§2.5), as CK-40 to CK-42 were sized.
// Round 4 (plans/checker-rewrite.md §5.6) adds a PAIR of deep declarations
// for R7: a method about 2 500 levels deep, used about 2 500 levels deep in
// another declaration — in the order that nests, exactly one
// `nesting_too_deep` at the use, with the hint, and never a crash; in the
// other order it checks (checker-v2.md §10.2, R7-3).
test "NEST-UNDER: a reverse-ordered chain of own methods checks in linear time" {
    var s = try Scenario.init("NEST-UNDER");
    defer s.deinit();
    try s.w.write("C.beni", try chain(s.arena(), 200));
    try s.w.write("C2.beni", try chain(s.arena(), 400));
    const verdict = try s.ratio("C.beni", "C2.beni", 200);
    try s.finish(verdict);
}

test "NEST-OVER: a chain past the nesting budget is one nesting_too_deep" {
    var s = try Scenario.init("NEST-OVER");
    defer s.deinit();
    try s.w.write("C.beni", try chain(s.arena(), 20_000));
    const verdict = try s.exactlyOne(&.{ "check", "--no-cache", "--diagnostics=json", "C.beni" }, .nesting_too_deep);
    try s.finish(verdict);
}

// CK-82: a nominal payload record of 65 536 fields. The eager pass probes
// `T`'s derived `eq`, and `Solve.derivedUse` casts the field count into the
// `u16` evidence count: a panic in Debug (`crash=ABRT`), whether or not
// anything compares `T`. 65 535 builds and runs (`abuse_test.zig`, CK-81).
// GREEN is the program built and run, printing its two answers, or a named
// refusal: exit 1 with diagnostics and not one of them `internal`.
test "CK-82: a nominal payload of 65 536 fields checks, and builds and runs or is refused by name" {
    var s = try Scenario.init("CK-82");
    defer s.deinit();
    const n = 65_536;
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

// CK-83: programs the compiler accepts, lowered to JavaScript nested deeper
// than Node 24's parser loads: it throws `RangeError` from about 1 700
// levels (1 500 runs). A 2 000-element list literal (uncharged by the
// parser's budget), and 2 000-term `+` and `++` chains (under it). GREEN is
// every one built and run, printing its length.
// The three cases are three files of ONE project, built in turn to the same
// `--out=out`: `build` compiles only the named entry's import graph, and each
// build rewrites `out/_main.mjs` for its own entry before it is run, so no
// case reads another's output.
test "CK-83: a 2 000-element list and 2 000-term + and ++ chains build and run" {
    var s = try Scenario.init("CK-83");
    defer s.deinit();
    const a = s.arena();
    const n = 2_000;
    const Case = struct { head: []const u8, term: []const u8, op: []const u8, tail: []const u8, close: []const u8 };
    const cases = [_]Case{
        .{ .head = "xs : List Int\nxs =\n    [ ", .term = "1", .op = ", ", .tail = " ]", .close = "String.fromInt (List.length xs)" },
        .{ .head = "xs : Int\nxs =\n    ", .term = "one", .op = " + ", .tail = "", .close = "String.fromInt xs" },
        .{ .head = "xs : String\nxs =\n    ", .term = "a", .op = " ++ ", .tail = "", .close = "String.fromInt (String.length xs)" },
    };
    var verdict: Verdict = .{ .green = true, .signature = "", .detail = "" };
    for (cases, 0..) |case, k| {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(a, "import Node exposing (Program)\n\n\none : Int\none =\n    1\n\n\na : String\na =\n    \"a\"\n\n\n");
        try text.appendSlice(a, case.head);
        for (0..n) |i| try text.print(a, "{s}{s}", .{ if (i == 0) "" else case.op, case.term });
        try text.print(a, "{s}\n\n\nmain : Program\nmain =\n    Node.printLines [ {s} ]\n", .{ case.tail, case.close });
        const file = try std.fmt.allocPrint(a, "Case{d}.beni", .{k});
        try s.w.write(file, text.items);
        const v = try s.runsOrRefuses(file, "2000\n");
        // A refusal is not what this finding wants: every one must run.
        const ran = v.green and std.mem.startsWith(u8, v.detail, "ran");
        if (!ran and verdict.green) verdict = .{ .green = false, .signature = if (v.green) "refused" else v.signature, .detail = try std.fmt.allocPrint(a, "{s}: {s}", .{ file, v.detail }) };
    }
    if (verdict.green) verdict.detail = "all three ran";
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

/// `pub type Big = C0 Int | C1 Int | … ` with `count` constructors.
fn bigType(arena: std.mem.Allocator, count: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "pub type Big\n    = C0 Int\n");
    for (1..count) |i| try out.print(arena, "    | C{d} Int\n", .{i});
    return out.items;
}

/// `pub m0 (T x) u = (T x).m1 ()` … `pub mn (T x) u = x`: a chain of `n + 1`
/// own methods, each written BEFORE the one it calls.
fn chain(arena: std.mem.Allocator, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "type T\n    = T Int\n\n\n");
    for (0..n) |i| try out.print(arena, "pub m{d} (T x) u =\n    (T x).m{d} ()\n\n\n", .{ i, i + 1 });
    try out.print(arena, "pub m{d} (T x) u =\n    x\n", .{n});
    return out.items;
}

/// The next permutation of `order` in lexicographic order, or false after
/// the last.
fn nextPermutation(order: []usize) bool {
    if (order.len < 2) return false;
    var i = order.len - 1;
    while (i > 0 and order[i - 1] >= order[i]) i -= 1;
    if (i == 0) return false;
    var j = order.len - 1;
    while (order[j] <= order[i - 1]) j -= 1;
    std.mem.swap(usize, &order[i - 1], &order[j]);
    std.mem.reverse(usize, order[i..]);
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
    checker: ?[]const u8,
    claimed: []const []const u8,
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

    /// Every order of `decls` (up to `cap` orders, lexicographic from the
    /// written one), each written after `header` as `Main.beni`, built for
    /// Node and run: GREEN when every order exits 0 and prints `expected`.
    /// A red verdict carries the first failing order's signature.
    fn permutations(s: *Scenario, header: []const u8, decls: []const []const u8, expected: []const u8, cap: usize) !Verdict {
        const order = try s.arena().alloc(usize, decls.len);
        for (order, 0..) |*slot, i| slot.* = i;
        var tried: usize = 0;
        var failing: usize = 0;
        var first_failure: ?Verdict = null;
        while (tried < cap) {
            tried += 1;
            var text: std.ArrayList(u8) = .empty;
            try text.appendSlice(s.arena(), header);
            for (order, 0..) |d, i| {
                if (i != 0) try text.appendSlice(s.arena(), "\n\n");
                try text.appendSlice(s.arena(), decls[d]);
            }
            try s.w.write("Main.beni", text.items);
            const built = try s.w.runWith(try s.argv(&.{ "build", "--no-cache", "--diagnostics=json", "--platform=node", "--out=out", "Main.beni" }), .{ .raw_diagnostics = true });
            const verdict: ?Verdict = if (built.exit_code != 0)
                try s.failed(built)
            else blk: {
                const program = try s.w.node(world.entry_file);
                if (program.exit_code != 0) break :blk .{ .green = false, .signature = try std.fmt.allocPrint(s.arena(), "exit=0 program-exit={d}", .{program.exit_code}), .detail = "" };
                if (!std.mem.eql(u8, program.stdout, expected)) break :blk .{ .green = false, .signature = "exit=0 stdout-differs", .detail = "" };
                break :blk null;
            };
            if (verdict) |v| {
                failing += 1;
                if (first_failure == null) first_failure = .{ .green = false, .signature = v.signature, .detail = try std.fmt.allocPrint(s.arena(), "order {any}: {s}", .{ order, v.detail[0..@min(v.detail.len, 120)] }) };
            }
            if (!nextPermutation(order)) break;
        }
        if (first_failure) |v| {
            return .{ .green = false, .signature = v.signature, .detail = try std.fmt.allocPrint(s.arena(), "{d} of {d} orders fail; first, {s}", .{ failing, tried, v.detail }) };
        }
        return .{ .green = true, .signature = "", .detail = try std.fmt.allocPrint(s.arena(), "{d} orders", .{tried}) };
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

    /// The best of 3 `check --jobs=1` runs of `file`, or a red verdict.
    fn best(s: *Scenario, file: []const u8) !union(enum) { ms: i64, red: Verdict } {
        const args = [_][]const u8{ "check", "--no-cache", "--jobs=1", "--diagnostics=json", file };
        var fastest: i64 = std.math.maxInt(i64);
        for (0..3) |_| {
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
        const args_small = [_][]const u8{ "check", "--no-cache", "--jobs=1", "--diagnostics=json", small };
        const args_large = [_][]const u8{ "check", "--no-cache", "--jobs=1", "--diagnostics=json", large };

        // time(n): the best of 3, each bounded only by the harness's own
        // hang detector.
        var best_small: i64 = std.math.maxInt(i64);
        for (0..3) |_| {
            const run = try s.timed(&args_small, world.bulk_timeout_ms) orelse
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
            const run = try s.timed(&args_large, @max(bound * 2, 1_000)) orelse continue;
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
            std.debug.print("PENDING  RULE (b)  {s}  {s} is GREEN under the default checker: move it verbatim into tests/blackbox/abuse_test.zig and delete its RED line (plans/checker-rewrite.md §2.5)\n", .{ s.id, s.name });
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
