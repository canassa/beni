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

// CK-03, CK-42 and CK-80 under checker v2, fixed by R6a (2026-09-25). Each is
// still a pending scenario under v1 (`pending_test.zig`), which is frozen and
// stays red; these are v2's twins, as CK-96 to CK-98 are v2-only.
//
// CK-03: `( y, y ) == y` makes the receiver cyclic. v2's eager drain runs the
// resolver's cycle-safe derivability walk right after the node that closes
// the cycle (checker-v2.md §9.5), so it is ONE `infinite_type` at the `==`
// and the check ends: under 10 ms (ReleaseFast, CPU) on R6a, where v1 never
// finishes. The bound is `pending_test.zig`'s, 500 ms.
test "CK-03: a cyclic receiver in a `let` reports infinite_type within 500 ms (checker v2)" {
    var s = try Perf.init();
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
    const verdict = try s.bounded(&.{ "check", "--no-cache", "--jobs=1", "--diagnostics=json", "--checker=v2", "Cyclic.beni" }, 500, "infinite_type");
    try s.finish("CK-03", verdict);
}

// CK-42: n declarations, each comparing its own nominal type with `==`. v2
// finds a method by P3's index (one binary search), not a scan of the
// declarations, and keeps no site lists. Its control (`x == x` on an `Int`)
// is linear too — v2 has no capability re-settling, CK-75's residue — so the
// scenario is the plain ratio of the nominal program; `pending_test.zig`'s
// v1 scenario subtracts the control because v1's is not. Calibration
// (ReleaseFast, CPU, R6a): the module's `check` event is 34 / 69 / 136 ms at
// 8 000 / 16 000 / 32 000 declarations, and the control 23 / 46 / 93 ms, so n
// = 8 000 keeps the fixed build clear of start-up.
test "CK-42: nominal dispatch is linear in the number of declarations (checker v2)" {
    var s = try Perf.init();
    defer s.deinit();
    const nominal = "type T{d}\n    = T{d} Int\n\n\nf{d} : Int -> Bool\nf{d} x =\n    T{d} x == T{d} x\n\n\n";
    try s.w.write("E.beni", try generate(s.arena(), 8_000, nominal, 6));
    try s.w.write("E2.beni", try generate(s.arena(), 16_000, nominal, 6));
    const verdict = try s.ratioWith("E.beni", "E2.beni", 8_000, &.{"--checker=v2"});
    try s.finish("CK-42", verdict);
}

// CK-40 and CK-75 under checker v2, fixed by R8a (2026-09-26); still pending
// scenarios under v1, which is frozen.
//
// CK-40: a module of `n` schemas. v1 settled every endpoint's properties
// after every group holding a schema, each settle over the whole module:
// cubic. v2 settles them when they are next READ, if a schema group finished
// since (`Solve.settleSchemas`) — never after each group — so a module that
// compares nothing settles twice in all. On R8a (ReleaseFast, CPU) 300 / 600
// schemas take 13 / 25 ms (ratio 1.9), where v1 takes 295 ms and over 737.
test "CK-40: schema property settling is linear in the number of schemas (checker v2)" {
    var s = try Perf.init();
    defer s.deinit();
    try s.w.write("S.beni", try generate(s.arena(), 300, "pub schema S{d} = Int\n\n\n", 1));
    try s.w.write("S2.beni", try generate(s.arena(), 600, "pub schema S{d} = Int\n\n\n", 1));
    const verdict = try s.ratioWith("S.beni", "S2.beni", 300, &.{"--checker=v2"});
    try s.finish("CK-40", verdict);
}

// CK-75: n declarations, each a `type` and a function comparing two `Int`s.
// v1's residue was its capability settling (`Types.settleDispatchCapabilities`
// per module and after every method group) and its eager derivation block;
// v2 settles nothing, and computes each type's derived contexts once, by a
// unit's fixpoint, in P5 (R8a, checker-v2.md §11.2). On R8a (ReleaseFast,
// CPU) 6 000 / 12 000 take 64 / 121 ms (ratio 1.9), where v1 takes 206 / 744.
// Profiled first, as the brief asks: the module's `check` event is 44 / 87 ms,
// `solve` and `constrain` 8 / 15 ms each — all linear — and `dep_digest` is
// too small to show, so none of CK-75 is R10's. A cache directory shows
// `cache_store` at 20 / 73 ms, super-linear: CK-107, a new finding (R10).
test "CK-75: checking is linear in the number of declarations (checker v2)" {
    var s = try Perf.init();
    defer s.deinit();
    const control = "type T{d}\n    = T{d} Int\n\n\nf{d} : Int -> Bool\nf{d} x =\n    x == x\n\n\n";
    try s.w.write("X.beni", try generate(s.arena(), 6_000, control, 4));
    try s.w.write("X2.beni", try generate(s.arena(), 12_000, control, 4));
    const verdict = try s.ratioWith("X.beni", "X2.beni", 6_000, &.{"--checker=v2"});
    try s.finish("CK-75", verdict);
}

// CK-107, fixed by R10 (2026-09-27): writing a module's cache entry searched
// the dispatch sidecar's `type_refs` table linearly once per derived row's
// shape (`dispatch_bytes.Writer.typeRef`), so a module of n types wrote its
// entry in O(n²), under both checkers. The two reference tables are indexed
// by a hash map now, first-occurrence order kept, so no byte moved. CK-75's
// program, with a fresh cache directory per run, timing the `cache_store`
// event. Calibration (ReleaseFast, wall time of the event, R10): before, 20 /
// 72 ms at 6 000 / 12 000 under both checkers (ratio 3.6); after, 4.4 / 8.1
// ms (1.8). n = 12 000, so the event is long enough to time.
test "CK-107: writing a module's cache entry is linear in its types (both checkers)" {
    var s = try Perf.init();
    defer s.deinit();
    const control = "type T{d}\n    = T{d} Int\n\n\nf{d} : Int -> Bool\nf{d} x =\n    x == x\n\n\n";
    try s.w.write("X.beni", try generate(s.arena(), 12_000, control, 4));
    try s.w.write("X2.beni", try generate(s.arena(), 24_000, control, 4));
    const v1 = try s.storeRatio("X.beni", "X2.beni", 12_000, "--checker=v1");
    const v2 = try s.storeRatio("X.beni", "X2.beni", 12_000, "--checker=v2");
    std.debug.print("PERF  {s}  CK-107  v1 {s}\n", .{ if (v1.green) "GREEN" else "RED  ", v1.detail });
    try s.finish("CK-107", v2);
    if (!v1.green) return error.PerfRegression;
}

// CK-80: `==` on a value whose type is a DAG — `f x = ( x, [ x ] )` applied n
// deep — must cost its n distinct nodes, not its 2^n leaves. v2's
// derivability verdict walks each `(node, method)` pair once, and a wanted on
// a receiver already given a DERIVED answer for the same method is an alias
// of it (checker-v2.md §9, *As built by R6a* as revised by its review). Calibration (ReleaseFast,
// CPU, R6a): depth 9 / 18 / 36 / 72 all under 10 ms; v1 takes 190 ms at 18.
test "CK-80: == on a value whose type is a doubling DAG is linear in its depth (checker v2)" {
    var s = try Perf.init();
    defer s.deinit();
    try s.w.write("N9.beni", try nestedPair(s.arena(), 9));
    try s.w.write("N18.beni", try nestedPair(s.arena(), 18));
    const verdict = try s.ratioWith("N9.beni", "N18.beni", 9, &.{"--checker=v2"});
    try s.finish("CK-80", verdict);
}

// CK-80's `build` half (R6b's reviews: structural N6, adversarial F3): the
// same doubling DAG, BUILT. P6 writes each distinct answer of a site once
// (checker-v2.md §13.1 as amended by R6b), and `Lower` binds a shared
// evidence closure to a `const` once and reads it by name, so the emitted
// JavaScript — and the time to write it — is linear in the depth. Before,
// `Lower` expanded every shared term at every use: 487 KB of JavaScript at
// depth 12 and 144 MB at 20 (×4 every two levels). Calibration
// (ReleaseFast, CPU, R6b's review): depth 9 / 18 build in 6 / 11 ms; with the
// binding off, 8 / 873 ms (ratio 109).
test "CK-80: building == on a value whose type is a doubling DAG is linear in its depth (checker v2)" {
    var s = try Perf.init();
    defer s.deinit();
    try s.w.write("N9.beni", try nestedPairApp(s.arena(), 9));
    try s.w.write("N18.beni", try nestedPairApp(s.arena(), 18));
    const build: []const []const u8 = &.{ "build", "--no-cache", "--jobs=1", "--diagnostics=json", "--platform=node", "--out=out" };
    const verdict = try s.ratioOf(build, "N9.beni", "N18.beni", 9, &.{"--checker=v2"});
    try s.finish("CK-80 build", verdict);
}

// CK-101's timing twin (R6a's review, B2): `==` on a doubling DAG whose every
// level passes two method boundaries that alternate the method — `A`'s `eq`
// asks its payload for `compare`, `B`'s `compare` asks for `eq`. v2's
// derivability verdict walks `(node, method)` pairs, each once per walk, so
// the cost is the distinct pairs (checker-v2.md §9 *As built by R6a*, §18).
// v1 recurses once per boundary with fresh marks and does not finish at depth
// 9. Calibration (ReleaseFast, CPU, R6a's review): depth 9 / 18, 6 / 6 ms.
test "CK-101: == across alternating method boundaries on a doubling DAG is linear in its depth (checker v2)" {
    var s = try Perf.init();
    defer s.deinit();
    for ([_][]const u8{ "A9", "A18" }) |dir| {
        try s.w.write(try std.fmt.allocPrint(s.arena(), "{s}/Pa.beni", .{dir}), alternating_a);
        try s.w.write(try std.fmt.allocPrint(s.arena(), "{s}/Pb.beni", .{dir}), alternating_b);
    }
    try s.w.write("A9/Main.beni", try alternatingDag(s.arena(), 9));
    try s.w.write("A18/Main.beni", try alternatingDag(s.arena(), 18));
    const verdict = try s.ratioWith("A9", "A18", 9, &.{"--checker=v2"});
    try s.finish("CK-101", verdict);
}

const alternating_a =
    \\pub type A a = A a
    \\
    \\pub eq : A a, A a -> Bool
    \\    where a.compare : a, a -> Order
    \\eq l r =
    \\    case ( l, r ) of
    \\        ( A x, A y ) ->
    \\            x.compare y == EQ
    \\
;

const alternating_b =
    \\pub type B a = B a
    \\
    \\pub compare : B a, B a -> Order
    \\    where a.eq : a, a -> Bool
    \\compare l r =
    \\    case ( l, r ) of
    \\        ( B x, B y ) ->
    \\            if x.eq y then EQ else LT
    \\
;

/// `w = f (f (… (f 1)))`, `depth` applications of `f x = ( A (B x), [ A (B x) ] )`,
/// and `w == w`.
fn alternatingDag(arena: std.mem.Allocator, depth: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "import Pa exposing (A)\nimport Pb exposing (B)\n\n\nf x =\n    ( A (B x), [ A (B x) ] )\n\n\nv =\n    let\n        w =\n            ");
    for (0..depth) |_| try out.appendSlice(arena, "f (");
    try out.append(arena, '1');
    for (0..depth) |_| try out.append(arena, ')');
    try out.appendSlice(arena, "\n    in\n    w == w\n");
    return out.items;
}
/// `pending_test.zig`'s `generate`, verbatim: `count` copies of `template`,
/// `{d}` the index, `per` holes in each.
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

/// `w = f (f (… (f 1)))`, `depth` applications of `f x = ( x, [ x ] )`, and
/// `w == w` (`pending_test.zig`'s `nestedPair`).
fn nestedPair(arena: std.mem.Allocator, depth: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "f x =\n    ( x, [ x ] )\n\n\nv =\n    let\n        w =\n            ");
    for (0..depth) |_| try out.appendSlice(arena, "f (");
    try out.append(arena, '1');
    for (0..depth) |_| try out.append(arena, ')');
    try out.appendSlice(arena, "\n    in\n    w == w\n");
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
        return s.ratioOf(&.{ "check", "--no-cache", "--jobs=1", "--diagnostics=json" }, small, large, n, extra);
    }

    /// `ratioWith` for any command: `prefix` comes first, then `extra`, then
    /// the file.
    fn ratioOf(s: *Perf, prefix: []const []const u8, small: []const u8, large: []const u8, n: usize, extra: []const []const u8) !Verdict {
        var small_list: std.ArrayList([]const u8) = .empty;
        try small_list.appendSlice(s.arena(), prefix);
        try small_list.appendSlice(s.arena(), extra);
        try small_list.append(s.arena(), small);
        var large_list: std.ArrayList([]const u8) = .empty;
        try large_list.appendSlice(s.arena(), prefix);
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

    /// One run under `bound_ms` of CPU time, the best of 3, that exits 1 and
    /// reports `code`: `pending_test.zig`'s `bounded`, a failed compile an
    /// expected outcome here.
    fn bounded(s: *Perf, args: []const []const u8, bound_ms: i64, code: []const u8) !Verdict {
        for (0..3) |_| {
            // Killed at twice the bound of WALL time, judged on CPU time.
            const run = try s.timed(args, bound_ms * 2) orelse continue;
            if (run.ms > bound_ms) continue;
            const quoted = try std.fmt.allocPrint(s.arena(), "\"code\":\"{s}\"", .{code});
            if (run.result.exit_code != 1 or std.mem.indexOf(u8, run.result.stderr, quoted) == null) {
                std.debug.print("a bounded run exited {d}:\n{s}\n", .{ run.result.exit_code, run.result.stderr[0..@min(run.result.stderr.len, 400)] });
                return error.PerfRunFailed;
            }
            return .{ .green = true, .detail = try std.fmt.allocPrint(s.arena(), "{s} in {d} ms, CPU time", .{ code, run.ms }) };
        }
        return .{ .green = false, .detail = try std.fmt.allocPrint(s.arena(), "no run of 3 finished within {d} ms of CPU time", .{bound_ms}) };
    }
    /// `ratioWith` on one `--self-profile` event of the file's own module
    /// rather than the process (R8c, CK-93): for a finding in one phase whose
    /// program also carries another phase's super-linear cost, a finding of
    /// its own. The event's duration is wall time, of a `--jobs=1` run; each
    /// point the best of 3.
    fn eventRatio(s: *Perf, small: []const u8, large: []const u8, n: usize, event: []const u8, extra: []const []const u8) !Verdict {
        var ms: [2]f64 = undefined;
        for ([_][]const u8{ small, large }, &ms) |file, *slot| {
            var args: std.ArrayList([]const u8) = .empty;
            try args.appendSlice(s.arena(), &.{ "check", "--no-cache", "--jobs=1", "--diagnostics=json", "--self-profile=trace.json" });
            try args.appendSlice(s.arena(), extra);
            try args.append(s.arena(), file);
            var best: f64 = std.math.inf(f64);
            for (0..3) |_| {
                const run = try s.timed(args.items, world.bulk_timeout_ms) orelse return error.PerfRunTimedOut;
                try expectClean(run.result);
                const Event = struct { name: []const u8, ph: []const u8, dur: f64 = 0, args: struct { file: ?[]const u8 = null } = .{} };
                const text = try s.w.read("trace.json");
                const parsed = try std.json.parseFromSliceLeaky(struct { traceEvents: []Event }, s.arena(), text, .{ .ignore_unknown_fields = true });
                var total: ?f64 = null;
                for (parsed.traceEvents) |e| {
                    if (!std.mem.eql(u8, e.ph, "X") or !std.mem.eql(u8, e.name, event)) continue;
                    if (!std.mem.eql(u8, e.args.file orelse continue, file)) continue;
                    total = (total orelse 0) + e.dur / 1000.0;
                }
                best = @min(best, total orelse return error.PerfEventMissing);
            }
            slot.* = best;
        }
        const r = ms[1] / @max(ms[0], 0.001);
        return .{
            .green = r <= 2.5,
            .detail = try std.fmt.allocPrint(s.arena(), "n={d}: {d:.1} ms; 2n: {d:.1} ms; ratio {d:.2}, `{s}` event", .{ n, ms[0], ms[1], r, event }),
        };
    }

    /// `eventRatio` on the `cache_store` event (CK-107): a `--jobs=1` check
    /// into a FRESH cache directory every run, so every run writes the
    /// module's entry. The event is the whole serial store pass, not one
    /// file's. Each point the best of 3, wall time of the event.
    fn storeRatio(s: *Perf, small: []const u8, large: []const u8, n: usize, checker: []const u8) !Verdict {
        var ms: [2]f64 = undefined;
        var fresh: usize = 0;
        for ([_][]const u8{ small, large }, &ms) |file, *slot| {
            var best: f64 = std.math.inf(f64);
            for (0..3) |_| {
                fresh += 1;
                const dir = try std.fmt.allocPrint(s.arena(), "--cache-dir=store-{d}", .{fresh});
                const args = [_][]const u8{ "check", dir, "--jobs=1", "--diagnostics=json", "--self-profile=trace.json", checker, file };
                const run = try s.timed(&args, world.bulk_timeout_ms) orelse return error.PerfRunTimedOut;
                try expectClean(run.result);
                const Event = struct { name: []const u8, ph: []const u8, dur: f64 = 0 };
                const text = try s.w.read("trace.json");
                const parsed = try std.json.parseFromSliceLeaky(struct { traceEvents: []Event }, s.arena(), text, .{ .ignore_unknown_fields = true });
                var total: ?f64 = null;
                for (parsed.traceEvents) |e| {
                    if (!std.mem.eql(u8, e.ph, "X") or !std.mem.eql(u8, e.name, "cache_store")) continue;
                    total = (total orelse 0) + e.dur / 1000.0;
                }
                best = @min(best, total orelse return error.PerfEventMissing);
            }
            slot.* = best;
        }
        const r = ms[1] / @max(ms[0], 0.001);
        return .{
            .green = r <= 2.5,
            .detail = try std.fmt.allocPrint(s.arena(), "n={d}: {d:.1} ms; 2n: {d:.1} ms; ratio {d:.2}, `cache_store` event, {s}", .{ n, ms[0], ms[1], r, checker }),
        };
    }

    /// The file's own `check` event under `--checker=v2` over the same under
    /// `--checker=v1` (CK-131): not a ratio of sizes but of checkers, on one
    /// binary, so a constant factor v2 adds per use is what it sees. Each
    /// checker the best of `runs`, interleaved (a loaded machine only adds
    /// time, and to both alike); green when v2 ≤ `bound_pct` % of v1.
    fn checkerRatio(s: *Perf, file: []const u8, runs: usize, bound_pct: u64) !Verdict {
        var best = [2]f64{ std.math.inf(f64), std.math.inf(f64) };
        for (0..runs) |_| {
            for ([_][]const u8{ "--checker=v1", "--checker=v2" }, &best) |checker, *slot| {
                const run = try s.timed(&.{ "check", "--no-cache", "--jobs=1", "--diagnostics=json", "--self-profile=trace.json", checker, file }, world.bulk_timeout_ms) orelse return error.PerfRunTimedOut;
                try expectClean(run.result);
                slot.* = @min(slot.*, try fileEvent(s, "trace.json", "check", file));
            }
        }
        const pct: u64 = @intFromFloat(@round(best[1] * 100.0 / @max(best[0], 0.001)));
        return .{
            .green = pct <= bound_pct,
            .detail = try std.fmt.allocPrint(s.arena(), "{s}: v1 {d:.1} ms, v2 {d:.1} ms ({d} % of v1, bound {d} %), `check` event, best of {d}", .{ file, best[0], best[1], pct, bound_pct, runs }),
        };
    }

    /// The summed duration of `event`'s events for `file` in a trace, in ms.
    fn fileEvent(s: *Perf, trace: []const u8, event: []const u8, file: []const u8) !f64 {
        const Event = struct { name: []const u8, ph: []const u8, dur: f64 = 0, args: struct { file: ?[]const u8 = null } = .{} };
        const text = try s.w.read(trace);
        const parsed = try std.json.parseFromSliceLeaky(struct { traceEvents: []Event }, s.arena(), text, .{ .ignore_unknown_fields = true });
        var total: ?f64 = null;
        for (parsed.traceEvents) |e| {
            if (!std.mem.eql(u8, e.ph, "X") or !std.mem.eql(u8, e.name, event)) continue;
            if (!std.mem.eql(u8, e.args.file orelse continue, file)) continue;
            total = (total orelse 0) + e.dur / 1000.0;
        }
        return total orelse error.PerfEventMissing;
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

// CK-131, fixed by R9b (2026-09-27): 6 000 declarations each comparing
// `( a, [ b ] ) < ( b, [ a ] )` over `Int` (`s_tup6000`, checker-v2.md §18)
// checked at 1.6× v1: per derived position v2 made and stepped a wanted,
// unified its method type again, instantiated `List.compare`'s scheme from
// its interface, and walked the derivability of a shape it had proved in the
// declaration before. The fixes (§18 *as measured by R9b*) answer a table
// primitive whose method type already has the table's shape directly, take a
// plain imported method's requirements without instantiating it, and keep
// the derivability of a ground shape by its structure. Not a size ratio: a
// constant factor is what it was, so the scenario is v2 against v1 on one
// binary. `s_int6000` (`a < b`) is its control. The budget is 1.10× on
// medians (§18); the bound here, 1.25× on the best of 5, leaves room for a
// busy machine and still fails the 1.6× this was.
test "CK-131: a derived comparison per declaration checks within 1.25× v1 (checker v2)" {
    var s = try Perf.init();
    defer s.deinit();
    try s.w.write("Tup.beni", try generate(s.arena(), 6_000, "f{d} : Int, Int -> Bool\nf{d} a b =\n    ( a, [ b ] ) < ( b, [ a ] )\n\n\n", 2));
    try s.w.write("IntLt.beni", try generate(s.arena(), 6_000, "f{d} : Int, Int -> Bool\nf{d} a b =\n    a < b\n\n\n", 2));
    const tuple = try s.checkerRatio("Tup.beni", 5, 125);
    const control = try s.checkerRatio("IntLt.beni", 5, 125);
    try s.finish("CK-131", .{ .green = tuple.green and control.green, .detail = try std.fmt.allocPrint(s.arena(), "{s}; {s}", .{ tuple.detail, control.detail }) });
}

/// `nestedPair` as a program: `main` prints whether `v` holds.
fn nestedPairApp(arena: std.mem.Allocator, depth: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "import Node exposing (Program)\n\n\n");
    try out.appendSlice(arena, try nestedPair(arena, depth));
    try out.appendSlice(arena, "\n\nmain : Program\nmain =\n    Node.print (if v then \"T\" else \"F\")\n");
    return out.items;
}

// CK-119 under checker v2, found and fixed by R8b's review round
// (2026-09-26). A ring of `n` types closed through one schema's `via`
// conversion: `M0 → M1 → … → M(n-1) → S.Type`, and `S`'s `via` target is
// `M0`, with `==` on `M0` and `<` on `S.Type`. The ring's last link is a
// mention only the `via` target makes, which the unit graph could not see
// until R8b's review: every `M_i` was its own unit, a run that read the
// approximation of a run below it made the runs above it `partial`, and a
// partial run was never memoised, so each level re-ran the one above it —
// exponential (on the R8b tree, Debug: 1.3 s at n = 5, 8.4 s at 6, and from
// 7 on the step budget ran out inside a quiet run, which said a FALSE
// `not_equatable`). Now `Contexts.complete` adds the `via` target's
// mentions as edges before the unit runs, the ring is one unit, and it is
// one joint fixpoint (checker-v2.md §11.5 *as amended by R8b's review*).
// Calibration (ReleaseFast, CPU): see the scenario's detail line.
test "CK-119: a ring of types closed through a `via` is one joint fixpoint, in linear time (checker v2)" {
    var s = try Perf.init();
    defer s.deinit();
    try s.w.write("V.beni", try viaRing(s.arena(), 4_000));
    try s.w.write("V2.beni", try viaRing(s.arena(), 8_000));
    const verdict = try s.ratioWith("V.beni", "V2.beni", 4_000, &.{"--checker=v2"});
    try s.finish("CK-119", verdict);
}

/// CK-119's ring (R8b's structural review's generator).
fn viaRing(arena: std.mem.Allocator, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "import Schema exposing (Conversion)\n\n\nconv : Conversion Int M0\nconv =\n    Debug.todo \"x\"\n\n\n");
    for (0..n) |i| {
        if (i + 1 < n) {
            try out.print(arena, "type M{d}\n    = M{d} Int\n    | B{d} M{d}\n\n\n", .{ i, i, i, i + 1 });
        } else {
            try out.print(arena, "type M{d}\n    = M{d} Int\n    | B{d} S.Type\n\n\n", .{ i, i, i });
        }
    }
    try out.appendSlice(arena, "pub schema S tagged \"kind\" of\n    A as \"a\"\n        p : Int via conv\n\n\nsame : M0, M0 -> Bool\nsame a b =\n    a == b\n\n\ncmp : S.Type, S.Type -> Bool\ncmp a b =\n    a < b\n");
    return out.items;
}

// CK-125 under checker v2, found by R8b's round-2 review and fixed in it
// (2026-09-26). Not a ratio: an answer that must not depend on declaration
// order, measured here because a Debug build takes 26 s per order. `g`
// makes 262 comparisons of a 4 000-field record — about the per-group step
// budget (2²⁰) — and then `t == u` on `T = T R`; `h` is just `t == u`. On
// R8b's first review round a derived-context run shared its asker's step
// budget, so with `g` first `T`'s context ran out inside `g`, was memoised
// permanently as `absent_budget`, and `h` — three lines — was refused with
// `nesting_too_deep` too; with `h` first both checked. Now a run has a
// budget of its own and a budget run out is never memoised
// (checker-v2.md §11.5 *as amended by R8b's review rounds*).
test "CK-125: a derived context's step budget is its own, in either declaration order (checker v2)" {
    var s = try Perf.init();
    defer s.deinit();
    try s.w.write("G.beni", try budgetOrders(s.arena(), true));
    try s.w.write("H.beni", try budgetOrders(s.arena(), false));
    for ([_][]const u8{ "G.beni", "H.beni" }) |file| {
        const run = (try s.timed(&.{ "check", "--no-cache", "--jobs=1", "--diagnostics=json", "--checker=v2", file }, world.bulk_timeout_ms)) orelse return error.PerfRunTimedOut;
        try Perf.expectClean(run.result);
        try testing.expectEqualStrings("", std.mem.trim(u8, run.result.stderr, " \r\n"));
    }
    try s.finish("CK-125", .{ .green = true, .detail = "both declaration orders check clean" });
}

/// CK-125's program, `g` written first or `h` (R8b's round-2 review's probe).
fn budgetOrders(arena: std.mem.Allocator, g_first: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "type alias R =\n    { f0 : Int\n");
    for (1..4_000) |i| try out.print(arena, "    , f{d} : Int\n", .{i});
    try out.appendSlice(arena, "    }\n\n\ntype T\n    = T R\n\n\n");
    var g: std.ArrayList(u8) = .empty;
    try g.appendSlice(arena, "g : ");
    for (0..262) |_| try g.appendSlice(arena, "R, R, ");
    try g.appendSlice(arena, "T, T -> Bool\ng");
    for (0..262) |i| try g.print(arena, " a{d} b{d}", .{ i, i });
    try g.appendSlice(arena, " t u =\n    ");
    for (0..262) |i| try g.print(arena, "(a{d} == b{d}) && ", .{ i, i });
    try g.appendSlice(arena, "(t == u)\n\n\n");
    const h = "h : T, T -> Bool\nh t u =\n    t == u\n\n\n";
    if (g_first) {
        try out.appendSlice(arena, g.items);
        try out.appendSlice(arena, h);
    } else {
        try out.appendSlice(arena, h);
        try out.appendSlice(arena, g.items);
    }
    return out.items;
}

// CK-119's second shape, from R8b's round-2 review (S2): `n` schemas, each
// with a `via` to its own `type`, each compared by its own function. Every
// comparison reaches one new schema, so R8b's first review round rebuilt
// every unit once per comparison — O(n²) time and memory (8 000 schemas:
// 10.7 s and 11.6 GB, ReleaseFast). Now `Contexts.complete` walks only the
// types not yet completed and merges units locally, so each type and each
// `via` target is read once (checker-v2.md §11.5 *as amended by R8b's review
// rounds*). The frontend's own cost at this size is CK-124's.
test "CK-119: many schemas with `via`s, each compared, cost linear time (checker v2)" {
    var s = try Perf.init();
    defer s.deinit();
    const head = "import Schema exposing (Conversion)\n\n\n";
    const measured = "conv{d} : Conversion Int W{d}\nconv{d} =\n    Debug.todo \"c\"\n\n\ntype W{d}\n    = W{d} Int\n\n\npub schema S{d} tagged \"k\" of\n    A as \"a\"\n        p : Int via conv{d}\n\n\nf{d} : S{d}.Type, S{d}.Type -> Bool\nf{d} a b =\n    a == b\n\n\n";
    const control = "conv{d} : Conversion Int W{d}\nconv{d} =\n    Debug.todo \"c\"\n\n\ntype W{d}\n    = W{d} Int\n\n\npub schema S{d} tagged \"k\" of\n    A as \"a\"\n        p : Int via conv{d}\n\n\nf{d} : S{d}.Type, S{d}.Type -> Bool\nf{d} a b =\n    True\n\n\n";
    for ([_][]const u8{ "M.beni", "M2.beni", "X.beni", "X2.beni" }, [_]usize{ 4_000, 8_000, 4_000, 8_000 }, [_]bool{ true, true, false, false }) |file, n, cmp| {
        const body = if (cmp) try generate(s.arena(), n, measured, 11) else try generate(s.arena(), n, control, 11);
        try s.w.write(file, try std.mem.concat(s.arena(), u8, &.{ head, body }));
    }
    var ms: [4]i64 = undefined;
    for ([_][]const u8{ "M.beni", "X.beni", "M2.beni", "X2.beni" }, &ms) |file, *slot| {
        var best: i64 = std.math.maxInt(i64);
        for (0..3) |_| {
            const run = (try s.timed(&.{ "check", "--no-cache", "--jobs=1", "--diagnostics=json", "--checker=v2", file }, world.bulk_timeout_ms)) orelse return error.PerfRunTimedOut;
            try Perf.expectClean(run.result);
            best = @min(best, run.ms);
        }
        slot.* = best;
    }
    // The comparisons' own cost — `complete`, the runs — over a control with
    // the same schemas and no comparison, whose frontend cost at this size
    // is CK-124's (super-linear, and not this scenario's). Within 5 % of the
    // control it is noise, and green.
    const small = @max(ms[0] - ms[1], 1);
    const large = ms[2] - ms[3];
    const green = large * 2 <= small * 5 or large * 20 <= ms[3];
    try s.finish("CK-119 many", .{ .green = green, .detail = try std.fmt.allocPrint(s.arena(), "extra at n=4000: {d} − {d} = {d} ms; at 2n: {d} − {d} = {d} ms (5 % of the control: {d} ms), CPU time", .{ ms[0], ms[1], small, ms[2], ms[3], large, @divTrunc(ms[3], 20) }) });
}

// CK-111, fixed by R8c (2026-09-26): `==` on a record literal nested d deep,
// `uses` times. Each use resolves d nested positions, and v2 walked each
// position's whole subtree twice more: the derivability walk (a `number`
// leaf keeps every position non-ground, so nothing was memoised) and the
// occurs walk `Resolve.step` runs on every structure. A position's walks now
// read its parent's: `Resolve.State.derivable_open` holds a verdict proved
// over variables until a variable is bound, and `State.proofs` carries the
// parent's acyclicity proof to its positions. Calibration (ReleaseFast, CPU,
// 64 uses): `b64342b`+CK-122 takes 9.6 s at d = 1 000 and 40 s at 2 000, a
// ratio of 4.2; R8c 0.25 / 0.52 s, 2.1. d stays under 2 100, where the
// unfixed build refused the literal (CK-114, which the abuse test holds).
test "CK-111: derived == on a deeply nested record is linear per use (checker v2)" {
    var s = try Perf.init();
    defer s.deinit();
    try s.w.write("R.beni", try nestedRecord(s.arena(), 1_000, 64));
    try s.w.write("R2.beni", try nestedRecord(s.arena(), 2_000, 64));
    const verdict = try s.ratioWith("R.beni", "R2.beni", 1_000, &.{"--checker=v2"});
    try s.finish("CK-111", verdict);
}

/// `mk` a record literal nested `depth` deep, and `uses` declarations
/// comparing it with itself.
fn nestedRecord(arena: std.mem.Allocator, depth: usize, uses: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "mk =\n    ");
    for (0..depth) |_| try out.appendSlice(arena, "{ x = ");
    try out.append(arena, '1');
    for (0..depth) |_| try out.appendSlice(arena, ", y = 0 }");
    try out.appendSlice(arena, "\n\n\n");
    for (0..uses) |j| try out.print(arena, "u{d} =\n    mk == mk\n\n\n", .{j});
    return out.items;
}

// CK-112, fixed by R8c (2026-09-26): a type of n parameters. Lowering looked
// each type variable up by a scan of the declaration's parameters, and the
// type reader (`Types.Builder.typeVar`) by a scan of its scope: O(n²) in both
// checkers. Lowering now indexes a declaration of more than 8 parameters by
// name, and the reader takes a parameter's slot from the index lowering
// recorded. v1 has a quadratic of its own beyond these two (21 s at 32 000),
// and is frozen; the scenario is v2's. Calibration (ReleaseFast, CPU):
// `b64342b`+CK-122 takes 0.21 s at 16 000 and 0.8 s at 32 000; R8c 40 / 70
// ms.
test "CK-112: a type of n parameters costs linear time (checker v2)" {
    var s = try Perf.init();
    defer s.deinit();
    try s.w.write("W.beni", try manyParams(s.arena(), 16_000));
    try s.w.write("W2.beni", try manyParams(s.arena(), 32_000));
    const verdict = try s.ratioWith("W.beni", "W2.beni", 16_000, &.{"--checker=v2"});
    try s.finish("CK-112", verdict);
}

/// `pub type W p0 … pn = W p0 … pn`.
fn manyParams(arena: std.mem.Allocator, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "pub type W");
    for (0..n) |i| try out.print(arena, " p{d}", .{i});
    try out.appendSlice(arena, "\n    = W");
    for (0..n) |i| try out.print(arena, " p{d}", .{i});
    try out.append(arena, '\n');
    return out.items;
}

// CK-93, fixed by R8c (2026-09-26): `foo x0 = let x1 = [ x0 ] … xN = [ xN-1 ]
// in List.length xN`. Every `let` boundary occurs-checks its header, and
// xi's type holds the whole chain below it: O(N²). A boundary's run now
// stamps what it proves (`Walk.Stacks.acyclic`) — the root and every flex in
// the proved graph — and a later walk stops at a stamped root, until a
// stamped flex is bound (the one change that can close a cycle). Each link
// binds a fresh element variable, so the proofs hold down the chain.
//
// Measured on the module's `check` event, not the process: lowering the
// `let` itself is quadratic in its bindings (`bir.Lower.lowerBindings`, a
// scope scan per name), which is the frontend's (CK-127), not this finding.
// Calibration (ReleaseFast, the event's wall time at --jobs=1): R8c's parent
// takes 635 / 2 520 ms at N = 8 000 / 16 000 (4.0); R8c 9 / 15 ms (1.7).
test "CK-93: a let chain whose types grow is linear to check (checker v2)" {
    var s = try Perf.init();
    defer s.deinit();
    try s.w.write("L.beni", try letChain(s.arena(), 8_000));
    try s.w.write("L2.beni", try letChain(s.arena(), 16_000));
    const verdict = try s.eventRatio("L.beni", "L2.beni", 8_000, "check", &.{"--checker=v2"});
    try s.finish("CK-93", verdict);
}

fn letChain(arena: std.mem.Allocator, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "foo x0 =\n    let\n");
    for (1..n + 1) |i| try out.print(arena, "        x{d} =\n            [ x{d} ]\n\n", .{ i, i - 1 });
    try out.print(arena, "    in\n    List.length x{d}\n", .{n});
    return out.items;
}
