//! The performance scenarios that are FIXED: timing claims promoted out of
//! `pending_test.zig` once they turned green. Run only by `zig build
//! test-perf`, on the ReleaseFast compiler `zig-out/perf/bin/beni`
//! (`BENI_EXE`), never by the three gates: rule 4 names those, and a timing
//! claim measured on the ReleaseSafe binary the gates run measures a
//! different compiler than the one its sizes were calibrated on.
//!
//! The method is `pending_test.zig`'s, so a scenario moves between the two
//! files verbatim, with one change of unit:
//!
//!   * **a ratio**, cost(2n) / cost(n) ≤ 2.5 — linear with head-room;
//!     quadratic is about 4 and cubic about 8 — because a ratio holds across
//!     machines where an absolute bound does not;
//!   * **cost is the retired user-space instructions** of the child
//!     compiler (`Perf.Unit`), every run `--jobs=1`: they repeat run to run
//!     whatever else shares the cores, so one run is a point. Where no
//!     counter opens it is the child's CPU time (user + system, `wait4`'s
//!     rusage), and each point the best of 3 runs, since a loaded machine
//!     only ever ADDS time; the wall clock only kills a run, at twice the
//!     bound.
//!
//! The scenarios judged on a ratio of counts run in several processes at
//! once (a `--jobs=1` child's count is its own work, whatever runs beside
//! it); the few judged on the wall time of a `--self-profile` event, or on a
//! small difference of two counts, which in CPU time would be load's, run
//! alone, after them (`Run`, `inShard`).
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

// `fillCtorTerms` grows the store before every constructor, so a scheme
// writer whose memo is reallocated and cleared to the store's EXACT size
// whenever the store grows is O(constructors × store). `Schemes.Writer` keeps
// its memo on epoch marks with amortised growth. ONE `pub` type with n
// constructors isolates it — a chain of n types also carries per-type work
// that the declaration-count scenario below measures. Calibration
// (ReleaseFast, CPU): the exact-size memo took 115 / 234 / 390 / 820 /
// 1 416 ms at 2 000 / 3 000 / 4 000 / 6 000 / 8 000 constructors, a ratio of
// 3.4 to 3.6 from 2 000 on; with amortised growth 2 000 / 4 000 / 8 000 /
// 16 000 / 32 000 take 9 / 13 / 18 / 30 / 54 ms, 1.4 to 1.8. n = 4 000.
test "interface writing is linear in the number of constructors" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var s = try Perf.init(.concurrent);
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
    try s.finish("interface writing per constructor", verdict);
}

/// `pub type Big = C0 Int | C1 Int | … ` with `count` constructors.
fn bigType(arena: std.mem.Allocator, count: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "pub type Big\n    = C0 Int\n");
    for (1..count) |i| try out.print(arena, "    | C{d} Int\n", .{i});
    return out.items;
}

// Obligation rows riding on ONE variable. Every `${p}` and `p.0` attaches a
// row to `p`; joining `p`'s whole set, and lowering every row on it, at each
// attach and each merge with a fresh variable would be O(rows²) (8 000 `${p}`
// took 31 s that way, where a linear checker takes 0.15 s).
test "obligation rows on one variable cost linear time" {
    var s = try Perf.init(.concurrent);
    defer s.deinit();
    try s.w.write("R.beni", try rowsOnOne(s.arena(), 2_000));
    try s.w.write("R2.beni", try rowsOnOne(s.arena(), 4_000));
    const verdict = try s.ratioWith("R.beni", "R2.beni", 2_000, &.{});
    try s.finish("obligation rows on one variable", verdict);
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

// A chain of merges of variables that each carry rows. `[ p1, …, pn, … ]`
// merges a set of i rows into one of 1, n times; copying both sets and
// re-lowering every row of the survivor at every merge would be
// O(rows × merges).
test "merging variables that carry obligation rows is linear" {
    var s = try Perf.init(.concurrent);
    defer s.deinit();
    try s.w.write("M.beni", try mergeChain(s.arena(), 2_000));
    try s.w.write("M2.beni", try mergeChain(s.arena(), 4_000));
    const verdict = try s.ratioWith("M.beni", "M2.beni", 2_000, &.{});
    try s.finish("merging variables that carry rows", verdict);
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

// §8.1 step 3 must not scan every open `?` of the module at every boundary,
// or a declaration of n `let` bindings each holding an undecided `u?` costs
// O(n²). Step 3 reads the frame's own list, and a row that escaped moves
// down once.
test "the `?` default step is linear in the open `?`s and the boundaries" {
    var s = try Perf.init(.concurrent);
    defer s.deinit();
    try s.w.write("D.beni", try openTries(s.arena(), 1_500));
    try s.w.write("D2.beni", try openTries(s.arena(), 3_000));
    const verdict = try s.ratioWith("D.beni", "D2.beni", 1_500, &.{});
    try s.finish("the ? default step", verdict);
}

/// `pub f u =` a block of `a1 = u?` … `an = u?`, then `Ok [ a1, …, an ]`.
fn openTries(arena: std.mem.Allocator, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "pub f u =\n");
    for (1..n + 1) |i| try out.print(arena, "    a{d} =\n        u?\n\n", .{i});
    try out.appendSlice(arena, "    Ok [ a1");
    for (2..n + 1) |i| try out.print(arena, ", a{d}", .{i});
    try out.appendSlice(arena, " ]\n");
    return out.items;
}

// `( y, y ) == y` makes the receiver cyclic. The eager drain runs the
// resolver's cycle-safe derivability walk right after the node that closes
// the cycle (checker-v2.md §9.5), so it is ONE `infinite_type` at the `==`
// and the check ends: under 10 ms (ReleaseFast, CPU), where a checker without
// that walk never finishes. The bound is 500 ms.
test "a cyclic receiver in a `let` reports infinite_type within 500 ms" {
    var s = try Perf.init(.concurrent);
    defer s.deinit();
    try s.w.write("Cyclic.beni",
        \\f : Int → Int
        \\f z =
        \\    k y =
        \\        ( y, y ) == y
        \\    z
        \\
    );
    const verdict = try s.bounded(&.{ "check", "--no-cache", "--jobs=1", "--diagnostics=json", "Cyclic.beni" }, 500, "infinite_type");
    try s.finish("a cyclic receiver", verdict);
}

// n declarations, each comparing its own nominal type with `==`. The checker
// finds a method by P3's index (one binary search), not a scan of the
// declarations, and keeps no site lists. Its control (`x == x` on an `Int`)
// is linear too — nothing re-settles capabilities per group — so the
// scenario is the plain ratio of the nominal program. Calibration
// (ReleaseFast, CPU): the module's `check` event is 34 / 69 / 136 ms at
// 8 000 / 16 000 / 32 000 declarations, and the control 23 / 46 / 93 ms, so n
// = 8 000 keeps the build clear of start-up.
test "nominal dispatch is linear in the number of declarations" {
    var s = try Perf.init(.concurrent);
    defer s.deinit();
    const nominal = "type T{d}\n    = T{d} Int\n\n\nf{d} : Int -> Bool\nf{d} x =\n    T{d} x == T{d} x\n\n\n";
    try s.w.write("E.beni", try generate(s.arena(), 8_000, nominal, 6));
    try s.w.write("E2.beni", try generate(s.arena(), 16_000, nominal, 6));
    const verdict = try s.ratioWith("E.beni", "E2.beni", 8_000, &.{});
    try s.finish("nominal dispatch per declaration", verdict);
}

// A module of `n` schemas. Settling every endpoint's properties after every
// group holding a schema, each settle over the whole module, is cubic. The
// checker settles them when they are next READ, if a schema group finished
// since (`Solve.settleSchemas`) — never after each group — so a module that
// compares nothing settles twice in all. (ReleaseFast, CPU) 300 / 600
// schemas take 13 / 25 ms (ratio 1.9), where settling after every group
// took 295 ms and over 737.
test "schema property settling is linear in the number of schemas" {
    var s = try Perf.init(.concurrent);
    defer s.deinit();
    try s.w.write("S.beni", try generate(s.arena(), 300, "pub schema S{d} = Int\n\n\n", 1));
    try s.w.write("S2.beni", try generate(s.arena(), 600, "pub schema S{d} = Int\n\n\n", 1));
    const verdict = try s.ratioWith("S.beni", "S2.beni", 300, &.{});
    try s.finish("schema property settling", verdict);
}

// n declarations, each a `type` and a function comparing two `Int`s.
// Capability settling per module and after every method group, and an eager
// derivation block, made this super-linear; the checker settles nothing, and
// computes each type's derived contexts once, by a unit's fixpoint, in P5
// (checker-v2.md §11.2). (ReleaseFast, CPU) 6 000 / 12 000 take 64 / 121 ms
// (ratio 1.9), where the settling checker took 206 / 744. The module's
// `check` event is 44 / 87 ms, `solve` and `constrain` 8 / 15 ms each — all
// linear — and `dep_digest` is too small to show. The cache store's share is
// the next scenario's.
test "checking is linear in the number of declarations" {
    var s = try Perf.init(.concurrent);
    defer s.deinit();
    const control = "type T{d}\n    = T{d} Int\n\n\nf{d} : Int -> Bool\nf{d} x =\n    x == x\n\n\n";
    try s.w.write("X.beni", try generate(s.arena(), 6_000, control, 4));
    try s.w.write("X2.beni", try generate(s.arena(), 12_000, control, 4));
    const verdict = try s.ratioWith("X.beni", "X2.beni", 6_000, &.{});
    try s.finish("checking per declaration", verdict);
}

// Writing a module's cache entry must not search the dispatch sidecar's
// `type_refs` table linearly once per derived row's shape
// (`dispatch_bytes.Writer.typeRef`), or a module of n types writes its entry
// in O(n²). The two reference tables are indexed by a hash map, in
// first-occurrence order. The previous scenario's program, with a fresh
// cache directory per run, timing the `cache_store` event. Calibration
// (ReleaseFast, wall time of the event): a linear search took 20 / 72 ms at
// 6 000 / 12 000 (ratio 3.6); the index 4.4 / 8.1 ms (1.8). n = 12 000, so
// the event is long enough to time.
test "writing a module's cache entry is linear in its types" {
    var s = try Perf.init(.alone);
    defer s.deinit();
    const control = "type T{d}\n    = T{d} Int\n\n\nf{d} : Int -> Bool\nf{d} x =\n    x == x\n\n\n";
    try s.w.write("X.beni", try generate(s.arena(), 12_000, control, 4));
    try s.w.write("X2.beni", try generate(s.arena(), 24_000, control, 4));
    try s.finish("writing a cache entry", try s.storeRatio("X.beni", "X2.beni", 12_000));
}

// `==` on a value whose type is a DAG — `f x = ( x, [ x ] )` applied n deep —
// must cost its n distinct nodes, not its 2^n leaves. The derivability
// verdict walks each `(node, method)` pair once, and a wanted on a receiver
// already given a DERIVED answer for the same method is an alias of it
// (checker-v2.md §9). Calibration (ReleaseFast, CPU): depth 9 / 18 / 36 / 72
// all under 10 ms; a checker walking the tree takes 190 ms at 18.
test "== on a value whose type is a doubling DAG is linear in its depth" {
    var s = try Perf.init(.concurrent);
    defer s.deinit();
    try s.w.write("N9.beni", try nestedPair(s.arena(), 9));
    try s.w.write("N18.beni", try nestedPair(s.arena(), 18));
    const verdict = try s.ratioWith("N9.beni", "N18.beni", 9, &.{});
    try s.finish("== on a doubling DAG", verdict);
}

// The same doubling DAG, BUILT. P6 writes each distinct answer of a site once
// (checker-v2.md §13.1), and `Lower` binds a shared evidence closure to a
// `const` once and reads it by name, so the emitted JavaScript — and the time
// to write it — is linear in the depth. Expanding every shared term at every
// use writes 487 KB of JavaScript at depth 12 and 144 MB at 20 (×4 every two
// levels). Calibration (ReleaseFast, CPU): depth 9 / 18 build in 6 / 11 ms;
// with the binding off, 8 / 873 ms (ratio 109).
test "building == on a value whose type is a doubling DAG is linear in its depth" {
    var s = try Perf.init(.concurrent);
    defer s.deinit();
    try s.w.write("N9.beni", try nestedPairApp(s.arena(), 9));
    try s.w.write("N18.beni", try nestedPairApp(s.arena(), 18));
    const build: []const []const u8 = &.{ "build", "--no-cache", "--jobs=1", "--diagnostics=json", "--platform=node", "--out=out" };
    const verdict = try s.ratioOf(build, "N9.beni", "N18.beni", 9, &.{});
    try s.finish("building == on a doubling DAG", verdict);
}

// The same doubling DAG with both halves ONE type, `( x, x )` per level, so
// every level of the table is one shared term named twice.
// `Lower.derivedBodiesExist` — the re-check that every derived body a site
// names exists, which the build runs before lowering it — and
// `dump --stage=dispatch` each judge a shared term once (`readTable`, and
// labels in the dump); walked as a tree, it is 2^depth visits. Calibration
// (ReleaseFast, CPU, this generator): walked as a tree, `build` takes 21 / 57
// / 196 ms at depth 20 / 22 / 24, ×4 every two levels, so depth 32 is about
// 50 s; judged once, depth 32 / 64 build in 8 / 9 ms and dump in 22 / 22 ms,
// the process floor.
test "building and dumping == on a doubling DAG of one shared term is linear in its depth" {
    var s = try Perf.init(.concurrent);
    defer s.deinit();
    try s.w.write("D32.beni", try sharedPairApp(s.arena(), 32));
    try s.w.write("D64.beni", try sharedPairApp(s.arena(), 64));
    const build: []const []const u8 = &.{ "build", "--no-cache", "--jobs=1", "--diagnostics=json", "--platform=node", "--out=out" };
    try s.finish("building a DAG of one shared term", try s.ratioOf(build, "D32.beni", "D64.beni", 32, &.{}));
    const dump: []const []const u8 = &.{ "dump", "--stage=dispatch", "--platform=node" };
    try s.finish("dumping a DAG of one shared term", try s.ratioOf(dump, "D32.beni", "D64.beni", 32, &.{}));
}

/// `d1 x = ( x, x )`, `dk x = d1 (d(k-1) x)` to `depth`, and a `main` that
/// compares two values of the deepest: a type `depth` levels deep whose two
/// halves are one type at every level.
fn sharedPairApp(arena: std.mem.Allocator, depth: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "import Node exposing (Program)\n\n\nd1 x =\n    ( x, x )\n\n\n");
    for (2..depth + 1) |k| try out.print(arena, "d{d} x =\n    d1 (d{d} x)\n\n\n", .{ k, k - 1 });
    try out.print(arena, "main : Program\nmain =\n    Node.print (if d{d} 1 == d{d} 2 then \"T\" else \"F\")\n", .{ depth, depth });
    return out.items;
}

// An alias DAG must not be expanded as a tree. `A0 = Int`,
// `A{i} = ( A{i-1}, A{i-1} )` and one `f : A{n} -> A{n}`: reading each
// alias's body once per USE is 2^n expansions for n declarations.
// `Builder.aliases` expands each `(alias, argument roots)` once per read
// (checker-v2.md §7.4). Calibration (ReleaseFast, CPU): expanded per use,
// depth 9 / 18 check in 7 / 535 ms (ratio 76; 18 s at 18 in Debug); once
// per read, both at the floor.
test "an annotation over a doubling alias DAG is linear in its depth" {
    var s = try Perf.init(.concurrent);
    defer s.deinit();
    try s.w.write("D9.beni", try aliasDag(s.arena(), 9));
    try s.w.write("D18.beni", try aliasDag(s.arena(), 18));
    try s.finish("an annotation over an alias DAG", try s.ratio("D9.beni", "D18.beni", 9));
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

// An alias DAG whose uses differ in their arguments: `A0 a = Maybe a`, `A{i}
// a = ( A{i-1} a, A{i-1} (List a) )`, read by one `f : A{n} Int -> Int`. Its
// distinct types are the `A{i} (List^k Int)`, about n²/2 of them. Expanding
// once per `(alias, argument roots)` is not enough when every body read
// builds its `List a` afresh: no pair repeats, and the DAG is read as a tree,
// 2^n. `Builder.apply` builds each applied type once per `(type, argument
// roots)` in a read, as it expands each alias once. Calibration (ReleaseFast,
// CPU): depth 16 checks in 144 ms and depth 32 does not finish within 360
// ms, when the applications are built afresh; 6 / 6 ms, the floor, when
// they are shared.
test "an annotation over an alias DAG whose uses differ in their arguments is not exponential" {
    var s = try Perf.init(.concurrent);
    defer s.deinit();
    try s.w.write("D16.beni", try argumentDag(s.arena(), 16));
    try s.w.write("D32.beni", try argumentDag(s.arena(), 32));
    try s.finish("an annotation over an alias DAG with arguments", try s.ratio("D16.beni", "D32.beni", 16));
}

/// `type alias A0 a = Maybe a`, `type alias A{i} a = ( A{i-1} a, A{i-1}
/// (List a) )` up to `depth`, and `f : A{depth} Int -> Int`.
fn argumentDag(arena: std.mem.Allocator, depth: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "type alias A0 a =\n    Maybe a\n\n\n");
    for (1..depth + 1) |i| try out.print(arena, "type alias A{d} a =\n    ( A{d} a, A{d} (List a) )\n\n\n", .{ i, i - 1, i - 1 });
    try out.print(arena, "f : A{d} Int -> Int\nf _ =\n    1\n", .{depth});
    return out.items;
}

// `==` on a doubling DAG whose every level passes two method boundaries that
// alternate the method — `A`'s `eq` asks its payload for `compare`, `B`'s
// `compare` asks for `eq`. The derivability verdict walks `(node, method)`
// pairs, each once per walk, so the cost is the distinct pairs
// (checker-v2.md §9, §18). A checker that recurses once per boundary with
// fresh marks does not finish at depth 9. Calibration (ReleaseFast, CPU):
// depth 9 / 18, 6 / 6 ms.
test "== across alternating method boundaries on a doubling DAG is linear in its depth" {
    var s = try Perf.init(.concurrent);
    defer s.deinit();
    for ([_][]const u8{ "A9", "A18" }) |dir| {
        try s.w.write(try std.fmt.allocPrint(s.arena(), "{s}/Pa.beni", .{dir}), alternating_a);
        try s.w.write(try std.fmt.allocPrint(s.arena(), "{s}/Pb.beni", .{dir}), alternating_b);
    }
    try s.w.write("A9/Main.beni", try alternatingDag(s.arena(), 9));
    try s.w.write("A18/Main.beni", try alternatingDag(s.arena(), 18));
    const verdict = try s.ratioWith("A9", "A18", 9, &.{});
    try s.finish("== across alternating method boundaries", verdict);
}

const alternating_a =
    \\pub type A a = A a
    \\
    \\pub eq : A a, A a → Bool
    \\    where a.compare : a, a → Order
    \\eq l r =
    \\    case ( l, r ) of
    \\        ( A x, A y ) →
    \\            x.compare y == EQ
    \\
;

const alternating_b =
    \\pub type B a = B a
    \\
    \\pub compare : B a, B a → Order
    \\    where a.eq : a, a → Bool
    \\compare l r =
    \\    case ( l, r ) of
    \\        ( B x, B y ) →
    \\            if x.eq y then EQ else LT
    \\
;

/// `w = f (f (… (f 1)))`, `depth` applications of `f x = ( A (B x), [ A (B x) ] )`,
/// and `w == w`.
fn alternatingDag(arena: std.mem.Allocator, depth: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "import Pa exposing (A)\nimport Pb exposing (B)\n\n\nf x =\n    ( A (B x), [ A (B x) ] )\n\n\nv =\n    w =\n        ");
    for (0..depth) |_| try out.appendSlice(arena, "f (");
    try out.append(arena, '1');
    for (0..depth) |_| try out.append(arena, ')');
    try out.appendSlice(arena, "\n    w == w\n");
    return out.items;
}
/// `count` copies of `template`,
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
/// `w == w`.
fn nestedPair(arena: std.mem.Allocator, depth: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "f x =\n    ( x, [ x ] )\n\n\nv =\n    w =\n        ");
    for (0..depth) |_| try out.appendSlice(arena, "f (");
    try out.append(arena, '1');
    for (0..depth) |_| try out.append(arena, ')');
    try out.appendSlice(arena, "\n    w == w\n");
    return out.items;
}
// ┌─────────────────────────────────────────────────────────────────────────┐
// │ HARNESS                                                                 │
// └─────────────────────────────────────────────────────────────────────────┘

const Verdict = struct {
    green: bool,
    detail: []const u8,
};

/// Whether a scenario may share the machine with others. A ratio of two
/// `--jobs=1` children's costs (`Perf.Unit`) is their own work, whatever
/// runs beside them, so `.concurrent` scenarios are spread over several
/// processes at once. The duration of a `--self-profile` event is wall time
/// inside the child, which a busy machine stretches, and a small difference
/// of two large costs, where they fall back to CPU time, is within the noise
/// that cores shared with other work add to each; those scenarios are
/// `.alone`, in a process of their own after the others.
const Run = enum { concurrent, alone };

/// `.concurrent` scenarios met so far in this process, in declaration order.
var concurrent_seen: usize = 0;

/// Whether this process runs a scenario of `run`, from `BENI_PERF_SHARD`:
/// `cpu:<k>/<n>` runs the `.concurrent` scenarios whose position in
/// declaration order is k modulo n, `wall` runs the `.alone` ones, and unset
/// or empty runs every scenario (a hand run).
fn inShard(arena: std.mem.Allocator, run: Run) !bool {
    const position = if (run == .concurrent) concurrent_seen else 0;
    if (run == .concurrent) concurrent_seen += 1;
    const text = testing.environ.getAlloc(arena, "BENI_PERF_SHARD") catch return true;
    if (text.len == 0) return true;
    if (std.mem.eql(u8, text, "wall")) return run == .alone;
    if (!std.mem.startsWith(u8, text, "cpu:")) return error.BadPerfShard;
    const slash = std.mem.indexOfScalar(u8, text, '/') orelse return error.BadPerfShard;
    const k = try std.fmt.parseInt(usize, text["cpu:".len..slash], 10);
    const n = try std.fmt.parseInt(usize, text[slash + 1 ..], 10);
    if (n == 0 or k >= n) return error.BadPerfShard;
    return run == .concurrent and position % n == k;
}

const Perf = struct {
    w: World,
    arena_state: std.heap.ArenaAllocator,
    /// A code `ratioOf` accepts as an answer: a run that exits 1
    /// with every diagnostic of this code is timed like a clean one. Null:
    /// every run must be clean.
    refusable: ?@import("diagnostic").Code = null,

    fn init(comptime run: Run) !Perf {
        {
            var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
            defer scratch.deinit();
            if (!try inShard(scratch.allocator(), run)) return error.SkipZigTest;
            // A timing scenario on any other binary would measure another
            // compiler than the one its sizes were calibrated on.
            const exe = world.exePath(scratch.allocator());
            if (!std.mem.endsWith(u8, exe, "perf/bin/beni")) {
                std.debug.print("perf_test.zig times the ReleaseFast compiler `zig build test-perf` installs (BENI_EXE), never {s}\n", .{exe});
                return error.PerfScenarioOnWrongBinary;
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

    /// What a run's cost is counted in. Retired user-space instructions
    /// (`world.timing.Counter`, the unit of the gates' test budget) repeat
    /// run to run within a few parts in a million, whatever else shares the
    /// cores: one run is a point, and a ratio or a difference of two is
    /// exact. Where no counter opens (`perf_event_paranoid` above 2, no PMU,
    /// not Linux), the cost is CPU time in milliseconds, which load moves: each
    /// point is then the best of 3.
    const Unit = enum { instructions, cpu_ms };

    /// One compiler run: its cost (`Unit`) and its CPU time, or null when it
    /// was killed at `kill_ms` of WALL time. The counter also counts this
    /// thread from the spawn to the reap, a constant well under a million
    /// beside the child's tens of millions. The wall clock stands in for CPU
    /// time only where the platform reports no rusage.
    fn timed(s: *Perf, args: []const []const u8, kill_ms: i64) !?struct { cost: u64, unit: Unit, ms: i64, result: world.Result } {
        const counter = world.timing.Counter.open();
        defer if (counter) |c| {
            _ = std.os.linux.close(c.fd);
        };
        const start = Io.Timestamp.now(testing.io, .awake);
        const result = s.w.runWith(args, .{ .raw_diagnostics = true, .timeout_ms = kill_ms }) catch |err| switch (err) {
            error.CompilerTimeout => return null,
            else => return err,
        };
        const wall_ms = start.durationTo(Io.Timestamp.now(testing.io, .awake)).toMilliseconds();
        const ms = result.cpu_ms orelse wall_ms;
        if (counter) |c| return .{ .cost = c.read(), .unit = .instructions, .ms = ms, .result = result };
        return .{ .cost = @intCast(@max(ms, 0)), .unit = .cpu_ms, .ms = ms, .result = result };
    }

    /// `amount` of `unit`, for a detail line.
    fn show(s: *Perf, amount: u64, unit: Unit) ![]const u8 {
        return switch (unit) {
            .instructions => std.fmt.allocPrint(s.arena(), "{d}.{d} M instructions", .{ amount / 1_000_000, amount / 100_000 % 10 }),
            .cpu_ms => std.fmt.allocPrint(s.arena(), "{d} ms of CPU", .{amount}),
        };
    }

    /// cost(2n) / cost(n) ≤ 2.5 of `check --jobs=1` runs (`Unit`):
    /// `pending_test.zig`'s `ratioOf`, judged in instructions where they
    /// can be counted, with a failed compile an error rather than a red
    /// signature.
    fn ratio(s: *Perf, small: []const u8, large: []const u8, n: usize) !Verdict {
        return s.ratioWith(small, large, n, &.{});
    }

    /// `ratio` with extra flags on every run.
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
        var small_cost: u64 = std.math.maxInt(u64);
        var small_ms: i64 = std.math.maxInt(i64);
        var unit: Unit = .instructions;
        for (0..3) |_| {
            const run = try s.timed(small_args, world.bulk_timeout_ms) orelse {
                std.debug.print("n={d} did not finish within {d} ms\n", .{ n, world.bulk_timeout_ms });
                return error.PerfRunTimedOut;
            };
            try s.expectAnswered(run.result);
            small_cost = @min(small_cost, run.cost);
            small_ms = @min(small_ms, run.ms);
            unit = run.unit;
            if (unit == .instructions) break;
        }
        // Killed at twice the bound, in wall time from n's CPU time: a run
        // far past the bound is cut short, and judged red if every one is.
        const bound = small_cost * 5 / 2;
        const kill_ms = @max(@divTrunc(small_ms * 5, 2) * 2, 1_000);
        var best_large: ?u64 = null;
        for (0..3) |_| {
            const run = try s.timed(large_args, kill_ms) orelse continue;
            try s.expectAnswered(run.result);
            if (run.unit != unit) return error.PerfCounterLost;
            best_large = @min(best_large orelse run.cost, run.cost);
            if (unit == .instructions or run.cost <= bound) break;
        }
        const large_cost = best_large orelse return .{
            .green = false,
            .detail = try std.fmt.allocPrint(s.arena(), "n={d}: {s}; 2n killed at {d} ms of wall time on 3 of 3 runs", .{ n, try s.show(small_cost, unit), kill_ms }),
        };
        const hundredths = large_cost * 100 / @max(small_cost, 1);
        return .{
            .green = large_cost <= bound,
            .detail = try std.fmt.allocPrint(s.arena(), "n={d}: {s}; 2n: {s}; ratio {d}.{d:0>2}", .{ n, try s.show(small_cost, unit), try s.show(large_cost, unit), hundredths / 100, hundredths % 100 }),
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
    /// rather than the process: for a claim about one phase whose program
    /// also carries another phase's cost. The event's duration is wall time, of a `--jobs=1` run; each
    /// point the best of 3.
    fn eventRatio(s: *Perf, small: []const u8, large: []const u8, n: usize, event: []const u8, extra: []const []const u8) !Verdict {
        return s.eventRatioOf(small, large, n, event, extra, small, large);
    }

    /// `eventRatio` where what is checked (a file or a directory) and the
    /// file whose event is timed differ (a project directory, and its
    /// `Main`).
    fn eventRatioOf(s: *Perf, small: []const u8, large: []const u8, n: usize, event: []const u8, extra: []const []const u8, small_file: []const u8, large_file: []const u8) !Verdict {
        var ms: [2]f64 = undefined;
        for ([_][]const u8{ small, large }, [_][]const u8{ small_file, large_file }, &ms) |target, file, *slot| {
            var args: std.ArrayList([]const u8) = .empty;
            try args.appendSlice(s.arena(), &.{ "check", "--no-cache", "--jobs=1", "--diagnostics=json", "--self-profile=trace.json" });
            try args.appendSlice(s.arena(), extra);
            try args.append(s.arena(), target);
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

    /// `eventRatio` on the `cache_store` event: a `--jobs=1` check
    /// into a FRESH cache directory every run, so every run writes the
    /// module's entry. The event is the whole serial store pass, not one
    /// file's. Each point the best of 3, wall time of the event.
    fn storeRatio(s: *Perf, small: []const u8, large: []const u8, n: usize) !Verdict {
        var ms: [2]f64 = undefined;
        var fresh: usize = 0;
        for ([_][]const u8{ small, large }, &ms) |file, *slot| {
            var best: f64 = std.math.inf(f64);
            for (0..3) |_| {
                fresh += 1;
                const dir = try std.fmt.allocPrint(s.arena(), "--cache-dir=store-{d}", .{fresh});
                const args = [_][]const u8{ "check", dir, "--jobs=1", "--diagnostics=json", "--self-profile=trace.json", file };
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
            .detail = try std.fmt.allocPrint(s.arena(), "n={d}: {d:.1} ms; 2n: {d:.1} ms; ratio {d:.2}, `cache_store` event", .{ n, ms[0], ms[1], r }),
        };
    }

    /// The file's own `check` event over its CONTROL's, the same number of
    /// declarations each doing the cheapest form of the same work: not a
    /// ratio of sizes, so a constant factor added
    /// per use is what it sees. Each file the best of `runs`, interleaved (a
    /// loaded machine only adds time, and to both alike); green when the
    /// file costs ≤ `bound_pct` % of its control.
    fn controlRatio(s: *Perf, file: []const u8, control: []const u8, runs: usize, bound_pct: u64) !Verdict {
        var best = [2]f64{ std.math.inf(f64), std.math.inf(f64) };
        for (0..runs) |_| {
            for ([_][]const u8{ control, file }, &best) |one, *slot| {
                const run = try s.timed(&.{ "check", "--no-cache", "--jobs=1", "--diagnostics=json", "--self-profile=trace.json", one }, world.bulk_timeout_ms) orelse return error.PerfRunTimedOut;
                try expectClean(run.result);
                slot.* = @min(slot.*, try fileEvent(s, "trace.json", "check", one));
            }
        }
        const pct: u64 = @intFromFloat(@round(best[1] * 100.0 / @max(best[0], 0.001)));
        return .{
            .green = pct <= bound_pct,
            .detail = try std.fmt.allocPrint(s.arena(), "{s} {d:.1} ms, {s} {d:.1} ms ({d} % of it, bound {d} %), `check` event, best of {d}", .{ file, best[1], control, best[0], pct, bound_pct, runs }),
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

    /// `expectClean`, or a refusal of exactly the `refusable` code.
    fn expectAnswered(s: *Perf, r: world.Result) !void {
        const code = s.refusable orelse return expectClean(r);
        if (r.exit_code == 1) refused: {
            const trimmed = std.mem.trim(u8, r.stderr, " \r\n");
            const diags = std.json.parseFromSliceLeaky([]@import("diagnostic").Diagnostic, s.arena(), trimmed, .{}) catch break :refused;
            if (diags.len == 0) break :refused;
            for (diags) |d| if (d.code != code) break :refused;
            return;
        }
        return expectClean(r);
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

// 6 000 declarations each comparing `( a, [ b ] ) < ( b, [ a ] )` over `Int`
// (`s_tup6000`, checker-v2.md §18), against its control, `s_int6000`
// (`a < b`): a constant factor per derived position is exactly what it sees.
// Per derived position a checker can make and step a wanted, unify its
// method type again, instantiate `List.compare`'s scheme from its interface,
// and walk the derivability of a shape it proved in the declaration before;
// this one answers a table primitive whose method type already has the
// table's shape directly, takes a plain imported method's requirements
// without instantiating it, and keeps the derivability of a ground shape by
// its structure (§18). Calibration (ReleaseFast, this scenario on an idle
// machine, three rounds): the checker without those fixes 287 / 292 / 299 %;
// with them 217 / 213 / 224 %; the old checker's 178–190 %. The bound,
// 250 %, is the old checker's ratio with §18's 1.25 of room over it, near
// enough, about 12 % over today's and 12 % under the unfixed one.
test "a derived comparison per declaration checks within 2.5× its a < b control" {
    var s = try Perf.init(.alone);
    defer s.deinit();
    try s.w.write("Tup.beni", try generate(s.arena(), 6_000, "f{d} : Int, Int -> Bool\nf{d} a b =\n    ( a, [ b ] ) < ( b, [ a ] )\n\n\n", 2));
    try s.w.write("IntLt.beni", try generate(s.arena(), 6_000, "f{d} : Int, Int -> Bool\nf{d} a b =\n    a < b\n\n\n", 2));
    try s.finish("a derived comparison per declaration", try s.controlRatio("Tup.beni", "IntLt.beni", 5, 250));
}

/// `nestedPair` as a program: `main` prints whether `v` holds.
fn nestedPairApp(arena: std.mem.Allocator, depth: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "import Node exposing (Program)\n\n\n");
    try out.appendSlice(arena, try nestedPair(arena, depth));
    try out.appendSlice(arena, "\n\nmain : Program\nmain =\n    Node.print (if v then \"T\" else \"F\")\n");
    return out.items;
}

// A ring of `n` types closed through one schema's `via` conversion:
// `M0 → M1 → … → M(n-1) → S.Type`, and `S`'s `via` target is `M0`, with `==`
// on `M0` and `<` on `S.Type`. The ring's last link is a mention only the
// `via` target makes. A unit graph blind to it makes every `M_i` its own
// unit; a run that reads the approximation of a run below it makes the runs
// above it `partial`, and a partial run is never memoised, so each level
// re-runs the one above it — exponential (Debug: 1.3 s at n = 5, 8.4 s at 6,
// and from 7 on the step budget ran out inside a quiet run, which said a
// FALSE `not_equatable`). `Contexts.complete` adds the `via` target's
// mentions as edges before the unit runs, so the ring is one unit and one
// joint fixpoint (checker-v2.md §11.5). Calibration (ReleaseFast, CPU): see
// the scenario's detail line.
test "a ring of types closed through a `via` is one joint fixpoint, in linear time" {
    var s = try Perf.init(.concurrent);
    defer s.deinit();
    try s.w.write("V.beni", try viaRing(s.arena(), 4_000));
    try s.w.write("V2.beni", try viaRing(s.arena(), 8_000));
    const verdict = try s.ratioWith("V.beni", "V2.beni", 4_000, &.{});
    try s.finish("a ring through a via", verdict);
}

/// The ring of types closed through a `via`.
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
    try out.appendSlice(arena, "pub schema S tagged \"kind\" of\n    A as \"a\"\n        p : Int via conv\n\n\nsame : M0, M0 → Bool\nsame a b =\n    a == b\n\n\ncmp : S.Type, S.Type → Bool\ncmp a b =\n    a < b\n");
    return out.items;
}

// Not a ratio: an answer that must not depend on declaration order, measured
// here because a Debug build takes 26 s per order. `g` makes 262 comparisons
// of a 4 000-field record — about the per-group step budget (2²⁰) — and then
// `t == u` on `T = T R`; `h` is just `t == u`. A derived-context run that
// shared its asker's step budget would, with `g` first, run `T`'s context
// out inside `g`, memoise it permanently as `absent_budget`, and refuse `h` —
// three lines — with `nesting_too_deep` too; with `h` first both check. A
// run has a budget of its own and a budget run out is never memoised
// (checker-v2.md §11.5).
test "a derived context's step budget is its own, in either declaration order" {
    var s = try Perf.init(.concurrent);
    defer s.deinit();
    try s.w.write("G.beni", try budgetOrders(s.arena(), true));
    try s.w.write("H.beni", try budgetOrders(s.arena(), false));
    for ([_][]const u8{ "G.beni", "H.beni" }) |file| {
        const run = (try s.timed(&.{ "check", "--no-cache", "--jobs=1", "--diagnostics=json", file }, world.bulk_timeout_ms)) orelse return error.PerfRunTimedOut;
        try Perf.expectClean(run.result);
        try testing.expectEqualStrings("", std.mem.trim(u8, run.result.stderr, " \r\n"));
    }
    try s.finish("a derived context's own step budget", .{ .green = true, .detail = "both declaration orders check clean" });
}

/// The step-budget program, `g` written first or `h`.
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
    const h = "h : T, T → Bool\nh t u =\n    t == u\n\n\n";
    if (g_first) {
        try out.appendSlice(arena, g.items);
        try out.appendSlice(arena, h);
    } else {
        try out.appendSlice(arena, h);
        try out.appendSlice(arena, g.items);
    }
    return out.items;
}

// The ring's second shape: `n` schemas, each with a `via` to its own `type`,
// each compared by its own function. Every comparison reaches one new schema,
// so rebuilding every unit once per comparison is O(n²) time and memory
// (8 000 schemas: 10.7 s and 11.6 GB, ReleaseFast). `Contexts.complete` walks
// only the types not yet completed and merges units locally, so each type and
// each `via` target is read once (checker-v2.md §11.5). The frontend's own
// cost at this size is not this scenario's.
test "many schemas with `via`s, each compared, cost linear time" {
    var s = try Perf.init(.alone);
    defer s.deinit();
    const head = "import Schema exposing (Conversion)\n\n\n";
    const measured = "conv{d} : Conversion Int W{d}\nconv{d} =\n    Debug.todo \"c\"\n\n\ntype W{d}\n    = W{d} Int\n\n\npub schema S{d} tagged \"k\" of\n    A as \"a\"\n        p : Int via conv{d}\n\n\nf{d} : S{d}.Type, S{d}.Type -> Bool\nf{d} a b =\n    a == b\n\n\n";
    const control = "conv{d} : Conversion Int W{d}\nconv{d} =\n    Debug.todo \"c\"\n\n\ntype W{d}\n    = W{d} Int\n\n\npub schema S{d} tagged \"k\" of\n    A as \"a\"\n        p : Int via conv{d}\n\n\nf{d} : S{d}.Type, S{d}.Type -> Bool\nf{d} a b =\n    True\n\n\n";
    for ([_][]const u8{ "M.beni", "M2.beni", "X.beni", "X2.beni" }, [_]usize{ 4_000, 8_000, 4_000, 8_000 }, [_]bool{ true, true, false, false }) |file, n, cmp| {
        const body = if (cmp) try generate(s.arena(), n, measured, 11) else try generate(s.arena(), n, control, 11);
        try s.w.write(file, try std.mem.concat(s.arena(), u8, &.{ head, body }));
    }
    // Counted in instructions, one run of each file is exact. In CPU time
    // each file is the best of 3, the four interleaved: a load that comes
    // and goes adds time to a file and its control alike, where four blocks
    // of three runs would hand it to one of them.
    var cost = [_]u64{std.math.maxInt(u64)} ** 4;
    var unit: Perf.Unit = .instructions;
    for (0..3) |_| {
        for ([_][]const u8{ "M.beni", "X.beni", "M2.beni", "X2.beni" }, &cost) |file, *slot| {
            const run = (try s.timed(&.{ "check", "--no-cache", "--jobs=1", "--diagnostics=json", file }, world.bulk_timeout_ms)) orelse return error.PerfRunTimedOut;
            try Perf.expectClean(run.result);
            slot.* = @min(slot.*, run.cost);
            unit = run.unit;
        }
        if (unit == .instructions) break;
    }
    // The comparisons' own cost — `complete`, the runs — over a control with
    // the same schemas and no comparison, whose frontend cost at this size
    // is super-linear and not this scenario's. That extra is a few percent
    // of each run — 13 to 26 ms of CPU beside 170 to 400 — and the noise in
    // a difference of two CPU times is of its size: judged in CPU time the
    // verdict went red about once in three runs, so a CPU-time verdict also
    // calls anything within 5 % of the control noise, and green.
    // In instructions the difference is exact: 58.5 M at n and 118.2 M at
    // 2n (2.02), and with a unit rebuild at each schema met put back,
    // 5 044 M and 20 047 M (3.97), the control unmoved (ReleaseFast).
    const small = @max(cost[0] -| cost[1], 1);
    const large = cost[2] -| cost[3];
    const green = large * 2 <= small * 5 or (unit == .cpu_ms and large * 20 <= cost[3]);
    const hundredths = large * 100 / small;
    try s.finish("many schemas with vias", .{ .green = green, .detail = try std.fmt.allocPrint(s.arena(), "extra at n=4000: {s}; at 2n: {s}; ratio {d}.{d:0>2}", .{ try s.show(small, unit), try s.show(large, unit), hundredths / 100, hundredths % 100 }) });
}

// `==` on a record literal nested d deep, `uses` times. Each use resolves d
// nested positions; walking each position's whole subtree twice more — the
// derivability walk (a `number` leaf keeps every position non-ground, so
// nothing is memoised) and the occurs walk `Resolve.step` runs on every
// structure — is quadratic. A position's walks read its parent's:
// `Resolve.State.derivable_open` holds a verdict proved over variables until
// a variable is bound, and `State.proofs` carries the parent's acyclicity
// proof to its positions. Calibration (ReleaseFast, CPU, 64 uses): walking
// every subtree takes 9.6 s at d = 1 000 and 40 s at 2 000, a ratio of 4.2;
// reading the parent's walks 0.25 / 0.52 s, 2.1. d stays under 2 100, the
// depth bound the abuse test holds.
test "derived == on a deeply nested record is linear per use" {
    var s = try Perf.init(.concurrent);
    defer s.deinit();
    try s.w.write("R.beni", try nestedRecord(s.arena(), 1_000, 64));
    try s.w.write("R2.beni", try nestedRecord(s.arena(), 2_000, 64));
    const verdict = try s.ratioWith("R.beni", "R2.beni", 1_000, &.{});
    try s.finish("derived == on a nested record", verdict);
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

// A type of n parameters. Looking each type variable up by a scan of the
// declaration's parameters when lowering, and by a scan of its scope in the
// type reader (`Types.Builder.typeVar`), is O(n²). Lowering indexes a
// declaration of more than 8 parameters by name, and the reader takes a
// parameter's slot from the index lowering recorded. Calibration
// (ReleaseFast, CPU): the scans take 0.21 s at 16 000 and 0.8 s at 32 000;
// the index 40 / 70 ms.
test "a type of n parameters costs linear time" {
    var s = try Perf.init(.concurrent);
    defer s.deinit();
    try s.w.write("W.beni", try manyParams(s.arena(), 16_000));
    try s.w.write("W2.beni", try manyParams(s.arena(), 32_000));
    const verdict = try s.ratioWith("W.beni", "W2.beni", 16_000, &.{});
    try s.finish("a type of n parameters", verdict);
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

// `foo x0 = let x1 = [ x0 ] … xN = [ xN-1 ] in List.length xN`. Every `let`
// boundary occurs-checks its header, and xi's type holds the whole chain
// below it: O(N²) unless a boundary's run stamps what it proves (`Walk.Stacks.acyclic`) — the root and every flex in
// the proved graph — and a later walk stops at a stamped root, until a
// stamped flex is bound (the one change that can close a cycle). Each link
// binds a fresh element variable, so the proofs hold down the chain.
//
// Measured on the module's `check` event, not the process: lowering the
// `let` itself is quadratic in its bindings (`bir.Lower.lowerBindings`, a
// scope scan per name), which is the frontend's and timed below, not here.
// Calibration (ReleaseFast, the event's wall time at --jobs=1): without the
// stamps 635 / 2 520 ms at N = 8 000 / 16 000 (4.0); with them 9 / 15 ms
// (1.7).
test "a let chain whose types grow is linear to check" {
    var s = try Perf.init(.alone);
    defer s.deinit();
    try s.w.write("L.beni", try letChain(s.arena(), 8_000));
    try s.w.write("L2.beni", try letChain(s.arena(), 16_000));
    const verdict = try s.eventRatio("L.beni", "L2.beni", 8_000, "check", &.{});
    try s.finish("a let chain whose types grow", verdict);
}

// A chain of top-level bindings, each wrapping the one before (`x0 = 0`,
// `x{i} = Just x{i-1}`), builds an i-deep polymorphic type, which every link
// copies and walks. Checking must stay linear in the chain's length, or
// refuse the first binder past `Unify.max_depth` once with
// `nesting_too_deep` and the rest in silence (checker-v2.md §7.3); it may
// never run out of memory. 5 000 and 10 000 links, cost(2n) / cost(n) ≤
// 2.5 (`Perf.Unit`).
test "a chain of ever deeper bindings is linear or nesting_too_deep" {
    var s = try Perf.init(.concurrent);
    defer s.deinit();
    s.refusable = .nesting_too_deep;
    const n = 5000;
    try s.w.write("Small.beni", try justChain(s.arena(), n));
    try s.w.write("Large.beni", try justChain(s.arena(), 2 * n));
    try s.finish("a chain of ever deeper bindings", try s.ratio("Small.beni", "Large.beni", n));
}

/// `x0 = 0`, then `x{i} = Just x{i-1}` up to `count`.
fn justChain(arena: std.mem.Allocator, count: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "x0 =\n    0\n\n\n");
    for (1..count + 1) |i| try out.print(arena, "x{d} =\n    Just x{d}\n\n\n", .{ i, i - 1 });
    return out.items;
}

fn letChain(arena: std.mem.Allocator, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "foo x0 =\n");
    for (1..n + 1) |i| try out.print(arena, "    x{d} =\n        [ x{d} ]\n\n", .{ i, i - 1 });
    try out.print(arena, "    List.length x{d}\n", .{n});
    return out.items;
}

// The nesting scenario (checker-v2.md §10.2): chains of own methods
// `m0 … mn` on one type, each calling the next, written in REVERSE
// dependency order (`m0`, which needs `m1`, first), so checking `m0`
// nests `m1`, which nests `m2`, and so on. 40 chains of 250 and of 500
// links, below the nesting budget, check in linear time. Each chain's depth
// doubles with n; a nesting cost that grew with the depth — a queue or a
// frame walk per nesting — reads as 4. Calibration (ReleaseFast, CPU):
// 77 / 151 ms, a ratio of 1.96.
test "a reverse-ordered chain of own methods checks in linear time" {
    var s = try Perf.init(.concurrent);
    defer s.deinit();
    try s.w.write("C.beni", try chains(s.arena(), 40, 250));
    try s.w.write("C2.beni", try chains(s.arena(), 40, 500));
    const verdict = try s.ratioWith("C.beni", "C2.beni", 250, &.{});
    try s.finish("a reverse-ordered chain of own methods", verdict);
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

// One `case` of n integer literal branches must emit in time linear in n.
// `js/Decision.zig` groups rows by head in one pass; comparing every row with
// every other, three times over (the key set, the column choice's distinct
// count, the specialisation), made `build` take 2.2 s at 10 000 branches and
// 8.6 s at 20 000 (ReleaseFast) while `check` took 18 ms. n = 3 000 / 6 000.
// (ReleaseFast, CPU): 190 / 800 ms with the pairwise comparison (ratio 4.2);
// grouped, both points are the process floor, and 20 000 branches build in
// 0.04 s. The shape half, the `switch` SpiderMonkey refused past 65 046
// labels, is `abuse_wide_test.zig`'s.
test "a case of n literal branches builds in time linear in n" {
    var s = try Perf.init(.concurrent);
    defer s.deinit();
    try s.w.write("C.beni", try bigCase(s.arena(), 3_000));
    try s.w.write("C2.beni", try bigCase(s.arena(), 6_000));
    const build = [_][]const u8{ "build", "--no-cache", "--jobs=1", "--library", "--platform=node", "--out=out", "--diagnostics=json" };
    const verdict = try s.ratioOf(&build, "C.beni", "C2.beni", 3_000, &.{});
    try s.finish("a case of n literal branches", verdict);
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

// Lowering a `let` to Bir must be linear in its binding count, before the
// checker sees it. Four scans of the whole block per binding would make it
// quadratic: the shadowing check and every name lookup walking the scope
// stack, which holds every binding of the block from phase 1 on;
// `localOfInst` searching the declaration's locals backwards for each
// `let_def`; and §7's initialisation check resetting its visited set and
// scanning every edge once per binding. The scope is indexed by name past 64
// entries, the local is recorded where it is bound, and the order check walks
// each binding's own edges. The let-chain program above (a bracket per
// binding, which the parser's depth guard releases; an operator in every
// binding would be charged to the declaration, `Parse.depth`), timed on the
// module's `lower` event. Calibration (ReleaseFast): see the detail line; the
// whole `check` was 0.12 / 0.45 s CPU at 10 000 / 20 000 with the scans
// (ratio 3.8).
test "a let of n chained bindings lowers in time linear in n" {
    var s = try Perf.init(.alone);
    defer s.deinit();
    try s.w.write("L.beni", try letChain(s.arena(), 20_000));
    try s.w.write("L2.beni", try letChain(s.arena(), 40_000));
    const verdict = try s.eventRatio("L.beni", "L2.beni", 20_000, "lower", &.{});
    try s.finish("lowering a let of chained bindings", verdict);
}

// `Digest.collect` looks up every exported type (`Types.find`) and
// deduplicates the set, and the dependency digest runs with or without a
// cache. With a linear scan for the lookup and a linear `contains` for the
// set it is quadratic in a module's `pub` types; `find` is a binary search of
// a per-module name index (`Types.by_name`), and the digest's type set a bit
// per type of the module. Independent `pub type A{i} = A{i} Int | B{i}`, the
// `dep_digest` event of the file. Calibration (ReleaseFast): with the scans,
// 38 / 149 ms at 8 000 / 16 000 types (ratio 3.9); indexed, 5.1 / 10.1 ms.
// n = 8 000.
test "the dependency digest is linear in a module's pub types" {
    var s = try Perf.init(.alone);
    defer s.deinit();
    const template = "pub type A{d}\n    = A{d} Int\n    | B{d}\n\n\n";
    try s.w.write("I.beni", try generate(s.arena(), 8_000, template, 3));
    try s.w.write("I2.beni", try generate(s.arena(), 16_000, template, 3));
    try s.finish("the dependency digest per pub type", try s.eventRatio("I.beni", "I2.beni", 8_000, "dep_digest", &.{}));
}

// The publication half: `Types.resolveRefs` calls the same `find` once per
// `type_refs` row, in P8 for every miss and in `install` for every hit, so a
// linear `find` makes publishing a CHAIN `pub type A{i} = A{i} Int A{i-1} |
// B{i}` quadratic. The `publish` event of the file. Calibration
// (ReleaseFast): with a linear `find`, 53 / 183 ms at 16 000 / 32 000 (ratio
// 3.5); indexed, 15.0 / 31.4 ms. n = 16 000.
test "publishing a chain of pub types is linear" {
    var s = try Perf.init(.alone);
    defer s.deinit();
    try s.w.write("C.beni", try typeChain(s.arena(), 16_000));
    try s.w.write("C2.beni", try typeChain(s.arena(), 32_000));
    try s.finish("publishing a chain of pub types", try s.eventRatio("C.beni", "C2.beni", 16_000, "publish", &.{}));
}

// An interface term that wrote every alias it named with its whole
// expansion made a chain of nested record aliases quadratic in BYTES:
// `pub type alias R{i} = { x : Int, p : R{i-1} }` with one `pub get{i} :
// R{i} -> Int` each. An alias is named in a term now and its body written
// once per record, on its `type_refs` row (checker-v2.md §14.2). The claim is
// the size of `dump --stage=raw` (the interface as written), which is exact,
// so one run of each size. Calibration: expanded, 1 021 435 / 4 140 731
// bytes at 60 / 120 links (ratio 4.05; 240: 17.3 MB); by name, 49 507 /
// 101 460 (2.04; 240: 209 385).
test "an alias chain's interface is linear in its length" {
    var s = try Perf.init(.concurrent);
    defer s.deinit();
    try s.w.write("R.beni", try aliasChain(s.arena(), 60));
    try s.w.write("R2.beni", try aliasChain(s.arena(), 120));
    var bytes: [2]usize = undefined;
    for ([_][]const u8{ "R.beni", "R2.beni" }, &bytes) |file, *slot| {
        const run = try s.timed(&.{ "dump", "--stage=raw", "--diagnostics=json", file }, world.bulk_timeout_ms) orelse
            return error.PerfRunFailed;
        try Perf.expectClean(run.result);
        slot.* = run.result.stdout.len;
    }
    const hundredths = bytes[1] * 100 / @max(bytes[0], 1);
    try s.finish("interface bytes of an alias chain", .{
        .green = hundredths <= 250,
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

// The frontend's `resolve` asks, for EVERY qualified reference, whether its
// root names a schema; answered by a scan of the module's declarations and of
// every import's `exposing` list, a module's resolution is quadratic in its
// size. `Resolve.Tables` answers from per-module sorted name tables, and
// `Graph.lookup` is an array load rather than three hash probes. `pub s{i} :
// List Int -> List Int` / `s{i} xs = List.map xs negate`, the file's
// `resolve` event. Calibration (ReleaseFast): with the scans, 51.9 / 204.8 ms
// at 8 000 / 16 000 (ratio 3.9); with the tables, 3.5 / 6.5 ms. n = 8 000.
test "resolving qualified references is linear in their number" {
    var s = try Perf.init(.alone);
    defer s.deinit();
    const template = "pub s{d} : List Int -> List Int\ns{d} xs =\n    List.map xs negate\n\n\n";
    try s.w.write("Q.beni", try generate(s.arena(), 8_000, template, 2));
    try s.w.write("Q2.beni", try generate(s.arena(), 16_000, template, 2));
    try s.finish("resolving qualified references", try s.eventRatio("Q.beni", "Q2.beni", 8_000, "resolve", &.{}));
}

// Looking a qualified reference's alias up by scanning the import table, and
// deduplicating a declaration's import edges by scanning the edges it has,
// makes a `Main` importing n modules and naming each n². Lowering keeps the
// imports by alias and by module, and a declaration past 64 edges indexes
// them; the graph's per-module edge sets are stamps. A `Main` importing n
// one-value modules `M{i}` and listing each `M{i}.v` once; `Main`'s own
// `lower` event. Calibration (ReleaseFast): with the scans, 24.4 / 121.3 ms
// at 2 000 / 4 000 modules (ratio 5.0); indexed, 0.8 / 1.5 ms. n = 2 000.
test "lowering a module is linear in its imports and their uses" {
    var s = try Perf.init(.alone);
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
    try s.finish("lowering a module's imports", try s.eventRatioOf("D2000", "D4000", 2_000, "lower", &.{}, "D2000/Main.beni", "D4000/Main.beni"));
}

/// `pub type A0 = A0 Int | B0`, then `pub type A{i} = A{i} Int A{i-1} | B{i}`
/// up to `count`.
fn typeChain(arena: std.mem.Allocator, count: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "pub type A0\n    = A0 Int\n    | B0\n\n\n");
    for (1..count + 1) |i| try out.print(arena, "pub type A{d}\n    = A{d} Int A{d}\n    | B{d}\n\n\n", .{ i, i, i - 1, i });
    return out.items;
}
