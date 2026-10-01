//! The checker, exercised through the real pipeline over sources in memory:
//! inference, generalisation, annotations, records, poisoning, `?`,
//! exhaustiveness and the usefulness budget, asserted on `dump --stage=types`
//! and on diagnostic codes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diagnostic = @import("diagnostic");

// ---------------------------------------------------------------------------
// Tests
//
// The checker is exercised through the real pipeline over sources in memory
// and asserted on the text of `dump --stage=types`. That is deliberate: a
// scheme is the only thing a person can read, `Render` is what every
// diagnostic prints types with, and asserting the store's internals instead
// would test an implementation that is meant to change. `TypeStore.zig`,
// `Schemes.zig` and the solver's own files keep the pieces that have no
// visible output — the term round trip, the occurs check,
// rank adjustment.
// ---------------------------------------------------------------------------

const testing = std.testing;
const TestProject = @import("../resolve/TestProject.zig");
const dump_types = @import("../dump/types.zig");
const Session = @import("../Session.zig");

/// A core package small enough to read and big enough for the scenarios:
/// the prelude's types, the ad-hoc annotations of `fast-compiler.md` §3.1,
/// and the handful of `List`/`Maybe`/`Result`/`String` functions the tests
/// call. The embedded core would work too and costs ~2,800 lines of parsing
/// per test; this way a test that turns on `number` says so in the fixture.
const test_core = [_]TestProject.Module{
    .{ .path = "Basics.beni", .package = .core, .source =
    \\pub equatable foreign type Int
    \\
    \\
    \\pub equatable foreign type Float
    \\
    \\
    \\pub type Bool
    \\    = True
    \\    | False
    \\
    \\
    \\pub type Order
    \\    = LT
    \\    | EQ
    \\    | GT
    \\
    \\
    \\pub foreign pure add : number, number -> number
    \\
    \\
    \\pub foreign pure sub : number, number -> number
    \\
    \\
    \\pub foreign pure mul : number, number -> number
    \\
    \\
    \\pub foreign pure lt : number, number -> Bool
    \\
    \\
    \\pub foreign pure eq : equatable a, a -> Bool
    \\
    \\
    \\pub foreign pure append : appendable, appendable -> appendable
    \\
    \\
    \\pub foreign pure toFloat : Int -> Float
    \\
    \\
    \\pub identity : a -> a
    \\identity a =
    \\    a
    \\
    \\
    \\pub max : number, number -> number
    \\max x y =
    \\    x
    \\
    },
    .{ .path = "List.beni", .package = .core, .source =
    \\pub equatable foreign type List a
    \\
    \\
    \\pub foreign pure cons : a, List a -> List a
    \\
    \\
    \\pub foreign pure map : (a -> b), List a -> List b
    \\
    \\
    \\pub foreign pure foldl : (a, b -> b), b, List a -> b
    \\
    \\
    \\pub foreign pure length : List a -> Int
    \\
    },
    .{ .path = "Maybe.beni", .package = .core, .source =
    \\pub type Maybe a
    \\    = Just a
    \\    | Nothing
    \\
    },
    .{ .path = "Result.beni", .package = .core, .source =
    \\pub type Result x a
    \\    = Ok a
    \\    | Err x
    \\
    },
    .{ .path = "String.beni", .package = .core, .source =
    \\pub equatable foreign type String
    \\
    \\
    \\pub foreign pure length : String -> Int
    \\
    \\
    \\pub foreign pure fromInt : Int -> String
    \\
    },
    .{ .path = "Char.beni", .package = .core, .source = "pub equatable foreign type Char\n\n\npub foreign pure isDigit : Char -> Bool\n" },
    .{ .path = "Debug.beni", .package = .core, .source = "pub foreign pure todo : String -> a\n" },
};

/// Run the checker over `source` as the module `M`, and compare
/// `dump --stage=types`.
fn expectTypes(expected: []const u8, source: [:0]const u8) !void {
    const gpa = testing.allocator;
    var modules: std.ArrayList(TestProject.Module) = .empty;
    defer modules.deinit(gpa);
    try modules.appendSlice(gpa, &test_core);
    try modules.append(gpa, .{ .path = "M.beni", .source = source });

    var p = try TestProject.initWith(gpa, modules.items, .{
        .phases = Session.check_phases,
        .keep_type_stores = true,
    });
    defer p.deinit();
    const m = p.module("M").?;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try dump_types.write(
        &out.writer,
        gpa,
        "M",
        p.session.artifacts.bir(p.session.graph.moduleFile(m)),
        &p.session.checked.modules[m.int()],
        &p.session.checked.types,
        &p.session.interner,
    );
    try testing.expectEqualStrings(expected, out.written());
}

/// Every diagnostic code the checker produced for `source`, in emission
/// order.
fn checkCodes(gpa: Allocator, source: [:0]const u8, out: *std.ArrayList(diagnostic.Code)) !void {
    var modules: std.ArrayList(TestProject.Module) = .empty;
    defer modules.deinit(gpa);
    try modules.appendSlice(gpa, &test_core);
    try modules.append(gpa, .{ .path = "M.beni", .source = source });
    var p = try TestProject.initWith(gpa, modules.items, .{ .phases = Session.check_phases });
    defer p.deinit();
    for (p.session.diagnostics.items) |d| try out.append(gpa, d.code);
}

fn expectCodes(expected: []const diagnostic.Code, source: [:0]const u8) !void {
    const gpa = testing.allocator;
    var codes: std.ArrayList(diagnostic.Code) = .empty;
    defer codes.deinit(gpa);
    try checkCodes(gpa, source, &codes);
    try testing.expectEqualSlices(diagnostic.Code, expected, codes.items);
}

/// Every diagnostic code of a WHOLE project — `modules` on top of the test
/// core — for the scenarios that are about crossing a module boundary.
fn expectProjectCodes(expected: []const diagnostic.Code, extra: []const TestProject.Module) !void {
    const gpa = testing.allocator;
    var modules: std.ArrayList(TestProject.Module) = .empty;
    defer modules.deinit(gpa);
    try modules.appendSlice(gpa, &test_core);
    try modules.appendSlice(gpa, extra);
    var p = try TestProject.initWith(gpa, modules.items, .{ .phases = Session.check_phases });
    defer p.deinit();
    const got = try p.codes(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(diagnostic.Code, expected, got);
}

/// One module checked with a chosen pattern-usefulness budget
/// (checker.md §6.6).
fn budgetedCodes(gpa: Allocator, source: [:0]const u8, budget: u32) ![]diagnostic.Code {
    var modules: std.ArrayList(TestProject.Module) = .empty;
    defer modules.deinit(gpa);
    try modules.appendSlice(gpa, &test_core);
    try modules.append(gpa, .{ .path = "M.beni", .source = source });
    var p = try TestProject.initWith(gpa, modules.items, .{
        .phases = Session.check_phases,
        .pattern_budget = budget,
    });
    defer p.deinit();
    return p.codes(gpa);
}

fn expectBudgetedCodes(expected: []const diagnostic.Code, source: [:0]const u8, budget: u32) !void {
    const gpa = testing.allocator;
    const got = try budgetedCodes(gpa, source, budget);
    defer gpa.free(got);
    try testing.expectEqualSlices(diagnostic.Code, expected, got);
}

test "inference: the principal type of an unannotated definition" {
    try expectTypes(
        \\module M
        \\  identity : a -> a
        \\    x : a
        \\  apply : (a -> b !e1), a -> b !e1
        \\    f : a -> b !e1
        \\    x : a
        \\  count : List a -> Int
        \\    xs : List a
        \\
    ,
        \\identity x =
        \\    x
        \\
        \\
        \\apply f x =
        \\    f x
        \\
        \\
        \\count xs =
        \\    List.length xs
        \\
    );
}

test "generalisation: a let-bound name is used at two types in one body" {
    // The classic let-polymorphism check. `dup` is generalised when its
    // group closes, so the two uses instantiate it independently.
    try expectTypes(
        \\module M
        \\  both : ( ( number, number ), ( String, String ) )
        \\    dup : a -> ( a, a )
        \\    y : a
        \\
    ,
        \\both =
        \\    dup y =
        \\        ( y, y )
        \\    ( dup 1, dup "s" )
        \\
    );
}

test "generalisation: a lambda parameter is NOT generalised" {
    // A parameter belongs to the enclosing scope, so it may not be used at
    // two types. Without the rank discipline this would generalise `f` and
    // silently accept the program. (The code is `kind_mismatch` rather than
    // `type_mismatch` because the first use pinned `f`'s argument to
    // `number` and `String` is not one.)
    try expectCodes(&.{.kind_mismatch},
        \\useTwice f =
        \\    ( f 1, f "s" )
        \\
    );
}

test "sharing: instantiating a scheme with an internal repeat keeps it one variable" {
    // `let x = (y, y)` — the classic doubling case (design §7 #4). If the
    // copy memo were missing, the two components would come back as two
    // independent variables and `pair 1` would not force both to `number`.
    try expectTypes(
        \\module M
        \\  first : ( number, number )
        \\    pair : a -> ( a, a )
        \\    y : a
        \\
    ,
        \\first =
        \\    pair y =
        \\        ( y, y )
        \\    pair 1
        \\
    );
}

test "annotations: rigid variables hold the body to the promise" {
    try expectCodes(&.{.rigid_mismatch},
        \\pub wrong : a -> Int
        \\wrong value =
        \\    value
        \\
    );
    try expectCodes(&.{},
        \\pub right : a -> a
        \\right value =
        \\    value
        \\
    );
}

test "the kind lattice: number, appendable, and the pair that has no meet" {
    try expectTypes(
        \\module M
        \\  twice : number -> number
        \\    n : number
        \\  join : appendable -> appendable
        \\    a : appendable
        \\
    ,
        \\twice n =
        \\    n + n
        \\
        \\
        \\join a =
        \\    a ++ a
        \\
    );
    // `number ⊓ appendable = ⊥` (checker.md §6.2).
    try expectCodes(&.{.kind_mismatch},
        \\both x =
        \\    x + x ++ x
        \\
    );
    // A kind that meets a type outside its set.
    try expectCodes(&.{.kind_mismatch},
        \\bad c =
        \\    c ++ 'a'
        \\
    );
}

test "records: access is open, a literal is closed, an update keeps the base's type" {
    try expectTypes(
        \\module M
        \\  name : { r | name : a } -> a
        \\    r : { r | name : a }
        \\  bump : { r | count : number } -> { r | count : number }
        \\    r : { r | count : number }
        \\  literal : { a : number, b : String }
        \\
    ,
        \\name r =
        \\    r.name
        \\
        \\
        \\bump r =
        \\    { r | count = r.count + 1 }
        \\
        \\
        \\literal =
        \\    { a = 1, b = "x" }
        \\
    );
}

test "records: the four-way field partition" {
    // Two closed records that differ in both directions, one that is
    // missing a field the other requires, and one that has an extra.
    try expectCodes(&.{.unknown_field},
        \\pub type alias P =
        \\    { x : Int }
        \\
        \\
        \\pub p : P
        \\p =
        \\    { x = 1, y = 2 }
        \\
    );
    try expectCodes(&.{.missing_field},
        \\pub type alias P =
        \\    { x : Int, y : Int }
        \\
        \\
        \\pub p : P
        \\p =
        \\    { x = 1 }
        \\
    );
    // Two OPEN records merge: each side grows the fields the other has, so
    // one parameter ends up carrying both.
    try expectTypes(
        \\module M
        \\  merge : { r | a : a, c : b } -> a
        \\    r : { r | a : a, c : b }
        \\    left : a
        \\    right : b
        \\
    ,
        \\merge r =
        \\    left =
        \\        r.a
        \\
        \\    right =
        \\        r.c
        \\    left
        \\
    );
}

// An annotation prints its alias by name. The parameter `p` took the name
// and then met the open record `p.x` asks for, so it shows the expansion
// (checker-v2.md §7.1, §21.1).
test "annotations print aliases by name, and a parameter that met the record shows it" {
    try expectTypes(
        \\module M
        \\  origin : Point
        \\  shift : Point -> Point
        \\    p : { x : Int, y : Int }
        \\
    ,
        \\pub type alias Point =
        \\    { x : Int, y : Int }
        \\
        \\
        \\pub origin : Point
        \\origin =
        \\    { x = 0, y = 0 }
        \\
        \\
        \\pub shift : Point -> Point
        \\shift p =
        \\    { p | x = p.x + 1 }
        \\
    );
}

test "poisoning: one mistake yields one message" {
    // Three uses of a value whose type could not be worked out. Without the
    // `err` content merging silently, each use would report again
    // (research/02 §6).
    try expectCodes(&.{.type_mismatch},
        \\pub broken : Int
        \\broken =
        \\    "not an int"
        \\
        \\
        \\pub a : Int
        \\a =
        \\    broken + 1
        \\
        \\
        \\pub b : Int
        \\b =
        \\    broken * 2
        \\
    );
}

test "the occurs check fires once, at the binding" {
    try expectCodes(&.{.infinite_type},
        \\selfApply f =
        \\    f f
        \\
    );
}

test "obligations: equatable, interpolatable and tuple_index" {
    try expectCodes(&.{.not_equatable},
        \\pub same : (Int -> Int), (Int -> Int) -> Bool
        \\same f g =
        \\    f == g
        \\
    );
    try expectCodes(&.{.not_interpolatable},
        \\pub show : List Int -> String
        \\show xs =
        \\    "xs: ${xs}"
        \\
    );
    try expectCodes(&.{.ambiguous_interpolation},
        \\show value =
        \\    "value: ${value}"
        \\
    );
    try expectCodes(&.{.ambiguous_tuple},
        \\firstOf t =
        \\    t.0
        \\
    );
    try expectCodes(&.{.tuple_index_out_of_range},
        \\pub third : ( Int, Int ) -> Int
        \\third t =
        \\    t.2
        \\
    );
    // An `equatable` obligation that is SATISFIED leaves no trace, and a
    // `number` interpolation needs no annotation: `Int` and `Float` are
    // both on the list.
    try expectCodes(&.{},
        \\pub same : Int, Int -> Bool
        \\same a b =
        \\    a == b
        \\
        \\
        \\pub show : Int -> String
        \\show n =
        \\    "n: ${n}"
        \\
    );
}

test "binding groups: mutual recursion shares one generalisation" {
    try expectTypes(
        \\module M
        \\  isEven : number -> Bool
        \\    n : number
        \\  isOdd : number -> Bool
        \\    n : number
        \\
    ,
        \\isEven n =
        \\    if n < 1 then
        \\        True
        \\    else
        \\        isOdd (n - 1)
        \\
        \\
        \\isOdd n =
        \\    if n < 1 then
        \\        False
        \\    else
        \\        isEven (n - 1)
        \\
    );
}

test "`?` picks Result or Maybe by shape, and refuses when it is neither" {
    try expectTypes(
        \\module M
        \\  step : Result String Int -> Result String Int
        \\    r : Result String Int
        \\    v : Int
        \\
    ,
        \\pub step : Result String Int -> Result String Int
        \\step r =
        \\    v =
        \\        r?
        \\    Ok (v + 1)
        \\
    );
    try expectTypes(
        \\module M
        \\  step : Maybe Int -> Maybe Int
        \\    m : Maybe Int
        \\    v : Int
        \\
    ,
        \\pub step : Maybe Int -> Maybe Int
        \\step m =
        \\    v =
        \\        m?
        \\    Just (v + 1)
        \\
    );
    try expectCodes(&.{.try_shape},
        \\pub step : Int -> Result String Int
        \\step n =
        \\    Ok (n? + 1)
        \\
    );
}

test "the arity rule of §8.3 fires before the generic mismatch" {
    try expectCodes(&.{.too_few_args},
        \\pub best : Int
        \\best =
        \\    max 1
        \\
    );
    try expectCodes(&.{.too_many_args},
        \\pub best : Int
        \\best =
        \\    max 1 2 3
        \\
    );
    try expectCodes(&.{.not_a_function},
        \\pub limit : Int
        \\limit =
        \\    1
        \\
        \\
        \\pub best : Int
        \\best =
        \\    limit 2
        \\
    );
    // The case currying could not localise (§8.3): a lambda of the wrong
    // arity in higher-order position is wrong WHERE IT IS WRITTEN, and the
    // message is about the lambda rather than about the list two arguments
    // later.
    try expectCodes(&.{.type_mismatch},
        \\pub total : List Int -> Int
        \\total xs =
        \\    List.foldl (λx -> x) 0 xs
        \\
    );
    // `_` is how a call leaves one argument open, and it is not an arity
    // mistake.
    try expectCodes(&.{},
        \\pub bump : List Int -> List Int
        \\bump xs =
        \\    List.map (max 1 _) xs
        \\
    );
}

test "a module with a type error still produces an interface" {
    const gpa = testing.allocator;
    var modules: std.ArrayList(TestProject.Module) = .empty;
    defer modules.deinit(gpa);
    try modules.appendSlice(gpa, &test_core);
    // `bad` is UNANNOTATED: an annotated declaration keeps its annotation
    // even when the body disagrees, because the annotation is what
    // dependents were promised (checker.md §6.1). `<error>` is for the case
    // where there is nothing else to say.
    try modules.append(gpa, .{ .path = "M.beni", .source =
        \\pub good : Int -> Int
        \\good n =
        \\    n
        \\
        \\
        \\pub bad =
        \\    "no" + 1
        \\
    });
    var p = try TestProject.initWith(gpa, modules.items, .{ .phases = Session.check_phases });
    defer p.deinit();

    const m = p.module("M").?;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try @import("../dump/interface.zig").write(
        &out.writer,
        gpa,
        "M",
        &p.session.resolution.interfaces[m.int()],
        p.session.checked.types.refIds(m),
        &p.session.checked.types,
        &p.session.interner,
    );
    // The declaration that failed is `<error>`; the one that did not is
    // still there for dependents to check against (checker.md §7).
    try testing.expectEqualStrings(
        \\module M
        \\  value bad : <error>
        \\  value good : Int -> Int
        \\
    , out.written());
}

test "binding groups are solved dependencies first, so a call to an inferred helper is checked" {
    // The regression: `sccGroups` emitted Tarjan's components highest id
    // first, and with edges pointing dependent -> dependency that is
    // DEPENDENTS first. The caller was then checked while the callee's
    // scheme was still unset, `instantiate` poisoned the callee, and the
    // call was silently accepted. Both source orders, because the bug did
    // not depend on one.
    try expectCodes(&.{.type_mismatch},
        \\helper n =
        \\    n + 1
        \\
        \\
        \\pub bad : Int
        \\bad =
        \\    helper "s"
        \\
    );
    try expectCodes(&.{.type_mismatch},
        \\pub bad : Int
        \\bad =
        \\    helper "s"
        \\
        \\
        \\helper n =
        \\    n + 1
        \\
    );
    // And the same for `let`: a sibling binding defined after its user is
    // still generalised before the user is solved.
    // Locals print in BINDING order, which is the source order of the
    // `let`, not the dependency order the groups were solved in.
    try expectTypes(
        \\module M
        \\  useAfter : ( number, String )
        \\    both : ( number2, String )
        \\    idf : a -> a
        \\    x : a
        \\
    ,
        \\useAfter =
        \\    both =
        \\        ( idf 1, idf "s" )
        \\
        \\    idf x =
        \\        x
        \\    both
        \\
    );
}

test "unifying two cyclic types merges a pair that is already one root" {
    // The regression: `unifyFlat` unifies children BEFORE merging the two
    // roots (so a message can print two different types), and a recursive
    // type makes an inner unification merge the pair first. `merge` then
    // got two equal roots and tripped its own assertion — a compiler crash
    // on ordinary source.
    try expectCodes(&.{.infinite_type},
        \\pub two x y =
        \\    r =
        \\        [ x, y ]
        \\
        \\    p =
        \\        x x
        \\
        \\    q =
        \\        y y
        \\    p
        \\
    );
}

test "a local index is relative to its declaration, in every consumer" {
    // The regression: two places indexed the module-wide `bir.locals` with
    // a declaration-relative index, so everything after the first
    // declaration saw another declaration's names. In a record pattern
    // that is not cosmetic — the name IS the field being matched.
    try expectCodes(&.{},
        \\pub first : Int -> Int
        \\first zzz =
        \\    zzz
        \\
        \\
        \\pub second : { name : Int, other : Int } -> Int
        \\second rec =
        \\    { name } =
        \\        rec
        \\    name
        \\
    );
}

// ---------------------------------------------------------------------------
// Pattern usefulness (checker.md §6.6)
// ---------------------------------------------------------------------------

test "exhaustiveness: a constructor with no branch is reported, one with a branch is not" {
    try expectCodes(&.{.missing_patterns},
        \\pub f : Maybe Int -> Int
        \\f m =
        \\    case m of
        \\        Just n ->
        \\            n
        \\
    );
    try expectCodes(&.{},
        \\pub f : Maybe Int -> Int
        \\f m =
        \\    case m of
        \\        Just n ->
        \\            n
        \\
        \\        Nothing ->
        \\            0
        \\
    );
    // A variable covers the rest, exactly as a wildcard does.
    try expectCodes(&.{},
        \\pub f : Maybe Int -> Int
        \\f m =
        \\    case m of
        \\        Just n ->
        \\            n
        \\
        \\        other ->
        \\            0
        \\
    );
}

test "exhaustiveness: `if` lowers to a `case` on Bool and must not be reported" {
    // `if` becomes `case c of True -> …; False -> …` (Bir's `case` tag), and
    // those two ARE every constructor of `Bool`. A spurious `missing_patterns`
    // on every `if` in the language is the failure mode this test exists for.
    try expectCodes(&.{},
        \\pub sign : Int -> Int
        \\sign n =
        \\    if n < 0 then
        \\        0 - 1
        \\    else
        \\        1
        \\
    );
    // And a written `case` on `Bool` behaves the same way.
    try expectCodes(&.{.missing_patterns},
        \\pub yes : Bool -> Int
        \\yes b =
        \\    case b of
        \\        True ->
        \\            1
        \\
    );
}

test "exhaustiveness: literals are infinite, so a wildcard is the only way to cover them" {
    try expectCodes(&.{.missing_patterns},
        \\pub f : Int -> Int
        \\f n =
        \\    case n of
        \\        1 ->
        \\            1
        \\
        \\        2 ->
        \\            2
        \\
    );
    try expectCodes(&.{},
        \\pub f : Int -> Int
        \\f n =
        \\    case n of
        \\        1 ->
        \\            1
        \\
        \\        _ ->
        \\            0
        \\
    );
    try expectCodes(&.{.missing_patterns},
        \\pub f : String -> Int
        \\f s =
        \\    case s of
        \\        "a" ->
        \\            1
        \\
    );
    try expectCodes(&.{.missing_patterns},
        \\pub f : Char -> Int
        \\f c =
        \\    case c of
        \\        'a' ->
        \\            1
        \\
    );
    // The same VALUE spelled two ways is one pattern, so the second branch
    // is dead: `0x10` and `16` are the same integer.
    try expectCodes(&.{.redundant_pattern},
        \\pub f : Int -> Int
        \\f n =
        \\    case n of
        \\        0x10 ->
        \\            1
        \\
        \\        16 ->
        \\            2
        \\
        \\        _ ->
        \\            0
        \\
    );
}

test "exhaustiveness: a list column is split by length" {
    try expectCodes(&.{}, listCase("[]", "[ x, ...rest ]"));
    try expectCodes(&.{.missing_patterns}, listCase("[]", "[ x ]"));
    try expectCodes(&.{.missing_patterns}, listCase("[ x ]", "[ x2, y ]"));
    // Items after a spread: every non-empty list ends somewhere.
    try expectCodes(&.{}, listCase("[]", "[ ...init, last ]"));
    try expectCodes(&.{.missing_patterns}, listCase("[ ...init, 0 ]", "[]"));
    // `[]`, `[ x ]` and `[ x2, y, ...rest ]` between them are every list.
    try expectCodes(&.{},
        \\pub f : List Int -> Int
        \\f xs =
        \\    case xs of
        \\        [] ->
        \\            0
        \\
        \\        [ x ] ->
        \\            x
        \\
        \\        [ x2, y, ...rest ] ->
        \\            y
        \\
    );
    // …and a fourth branch for a non-empty list is therefore dead.
    try expectCodes(&.{.redundant_pattern},
        \\pub f : List Int -> Int
        \\f xs =
        \\    case xs of
        \\        [] ->
        \\            0
        \\
        \\        [ x ] ->
        \\            x
        \\
        \\        [ x2, y, ...rest ] ->
        \\            y
        \\
        \\        [ ...more, z ] ->
        \\            z
        \\
    );
}

/// A `case` over `List Int` with two branch patterns, for the list cases
/// above. The bodies are constants so nothing but the patterns is in play.
fn listCase(comptime a: []const u8, comptime b: []const u8) [:0]const u8 {
    return "pub f : List Int -> Int\nf xs =\n    case xs of\n        " ++ a ++
        " ->\n            0\n\n        " ++ b ++ " ->\n            1\n";
}

test "exhaustiveness: tuples, unit and records are products with one shape" {
    // A tuple has one constructor, so what is missing is a COMBINATION —
    // and the example names it in source syntax.
    try expectCodes(&.{.missing_patterns},
        \\pub f : ( Bool, Bool ) -> Int
        \\f p =
        \\    case p of
        \\        ( True, True ) ->
        \\            1
        \\
        \\        ( False, False ) ->
        \\            2
        \\
    );
    try expectCodes(&.{},
        \\pub f : ( Bool, Bool ) -> Int
        \\f p =
        \\    case p of
        \\        ( True, b ) ->
        \\            1
        \\
        \\        ( False, b2 ) ->
        \\            2
        \\
    );
    // `()` has exactly one value, and a record pattern always matches.
    try expectCodes(&.{},
        \\pub f : () -> Int
        \\f u =
        \\    case u of
        \\        () ->
        \\            1
        \\
    );
    try expectCodes(&.{},
        \\pub f : { name : Int } -> Int
        \\f r =
        \\    case r of
        \\        { name } ->
        \\            name
        \\
    );
}

test "exhaustiveness: nesting" {
    try expectCodes(&.{.missing_patterns},
        \\pub f : Maybe (Maybe Int) -> Int
        \\f m =
        \\    case m of
        \\        Just (Just n) ->
        \\            n
        \\
        \\        Nothing ->
        \\            0
        \\
    );
    try expectCodes(&.{},
        \\pub f : Maybe (Maybe Int) -> Int
        \\f m =
        \\    case m of
        \\        Just (Just n) ->
        \\            n
        \\
        \\        Just Nothing ->
        \\            1
        \\
        \\        Nothing ->
        \\            0
        \\
    );
    // A `Result` of a `Maybe`, with three of the four combinations missing.
    try expectCodes(&.{.missing_patterns},
        \\pub f : Result String (Maybe Int) -> Int
        \\f r =
        \\    case r of
        \\        Ok (Just n) ->
        \\            n
        \\
    );
}

test "exhaustiveness: a branch under a wildcard can never run" {
    try expectCodes(&.{.redundant_pattern},
        \\pub f : Maybe Int -> Int
        \\f m =
        \\    case m of
        \\        other ->
        \\            0
        \\
        \\        Nothing ->
        \\            1
        \\
    );
    // The FIRST redundant branch is the one reported, and the missing-
    // pattern search does not also run: the matrix past a dead row is not
    // what the author meant (Elm's `toNonRedundantRows` stops the same way).
    try expectCodes(&.{.redundant_pattern},
        \\pub f : Maybe Int -> Int
        \\f m =
        \\    case m of
        \\        Just n ->
        \\            n
        \\
        \\        Just q ->
        \\            q
        \\
        \\        Just z ->
        \\            z
        \\
    );
}

test "exhaustiveness: a declaration with a type error is not judged twice" {
    // One mistake, one message: the `case` below is also non-exhaustive,
    // and saying so would be a second complaint about a declaration whose
    // types are already unknown (checker.md §6.6).
    try expectCodes(&.{.type_mismatch},
        \\pub f : Maybe Int -> Int
        \\f m =
        \\    case m of
        \\        Just n ->
        \\            "not an int"
        \\
    );
    // A GOOD declaration in the same module is still checked, though.
    try expectCodes(&.{ .type_mismatch, .missing_patterns },
        \\pub bad : Maybe Int -> Int
        \\bad m =
        \\    case m of
        \\        Just n ->
        \\            "not an int"
        \\
        \\
        \\pub good : Maybe Int -> Int
        \\good m =
        \\    case m of
        \\        Just n ->
        \\            n
        \\
    );
}

test "exhaustiveness: a case on an opaque imported type needs a variable, and that is enough" {
    // The importer cannot name the constructors at all (`opaque_constructor`
    // refuses them), so a variable is the only pattern it can write — and a
    // variable is exhaustive. The point is that nothing is reported: an
    // opaque type must not look non-exhaustive from outside.
    try expectProjectCodes(&.{}, &.{
        .{ .path = "Token.beni", .source =
        \\pub opaque type Token
        \\    = Word String
        \\    | Number Int
        \\
        \\
        \\pub make : Token
        \\make =
        \\    Number 1
        \\
        },
        .{ .path = "M.beni", .source =
        \\import Token exposing (Token, make)
        \\
        \\
        \\pub size : Token -> Int
        \\size t =
        \\    case t of
        \\        anything ->
        \\            1
        \\
        },
    });
}

test "exhaustiveness: an imported type's constructors come from its interface" {
    // `Tri` is not even imported, and it is still what is missing: the union
    // comes from the TYPE's declaration, reached through `Shape`'s
    // interface, not from what the importer happened to name.
    try expectProjectCodes(&.{.missing_patterns}, &.{
        .{ .path = "Shape.beni", .source =
        \\pub type Shape
        \\    = Circle Int
        \\    | Square Int
        \\    | Tri Int Int
        \\
        },
        .{ .path = "M.beni", .source =
        \\import Shape exposing (Shape, Circle, Square)
        \\
        \\
        \\pub area : Shape -> Int
        \\area s =
        \\    case s of
        \\        Circle r ->
        \\            r
        \\
        \\        Square w ->
        \\            w
        \\
        },
    });
}

test "the usefulness budget: an analysis that would cost too much is refused, not skipped" {
    // The algorithm is exponential in the worst case (Maranget §3.3), so a
    // `case` that exceeds a fixed work budget is abandoned. Proving that
    // with a hang is not a test; proving it by turning the budget down to
    // where an ordinary `case` cannot be analysed is.
    //
    // Silence here would be a miscompile: `backend.md` §7's decision tree
    // emits no default arm because the checker is supposed to have proved
    // exhaustiveness, so a `case` the checker never decided would fall into
    // its last edge and answer wrongly at exit 0. An analysis that gave up
    // SAYS it gave up.
    const source =
        \\pub f : Maybe Int -> Int
        \\f m =
        \\    case m of
        \\        Just n ->
        \\            n
        \\
    ;
    try expectBudgetedCodes(&.{.missing_patterns}, source, Session.default_pattern_budget);
    try expectBudgetedCodes(&.{.pattern_budget_exhausted}, source, 1);
}

test "the usefulness budget: exhaustion reports ONE code, not a partial answer" {
    // The same `case` is both non-exhaustive (no `Nothing` branch) and
    // redundant (`Just n` twice). With room to think the analysis reports
    // the redundancy, which is the first answer it reaches; out of budget it
    // reports neither, because a half-searched matrix proves nothing at all
    // — only `pattern_budget_exhausted`, once.
    const source =
        \\pub f : Maybe Int -> Int
        \\f m =
        \\    case m of
        \\        Just n ->
        \\            n
        \\
        \\        Just k ->
        \\            k
        \\
    ;
    try expectBudgetedCodes(&.{.redundant_pattern}, source, Session.default_pattern_budget);
    try expectBudgetedCodes(&.{.pattern_budget_exhausted}, source, 1);
}

test "the usefulness budget: an irrefutable position refuses instead of going silent" {
    // An irrefutable position the analysis cannot decide would lose the
    // guarantee that `backend.md` §4's unchecked destructure stands on, so
    // there the undecided answer has always been a refusal (checker.md §6.6).
    //
    // Both answers are refusals; what differs is the message
    // and the way out. A `case` can be split or given a bigger budget; an
    // irrefutable position has no branch to fall through to at all, so its
    // message says "`case` on it instead".
    //
    // `Boxed` is its type's only constructor, so with room to think the
    // analysis proves the parameter irrefutable and says nothing.
    const source =
        \\pub type Boxed
        \\    = Boxed Int
        \\
        \\
        \\pub f : Boxed -> Int
        \\f (Boxed n) =
        \\    n
        \\
    ;
    try expectBudgetedCodes(&.{}, source, Session.default_pattern_budget);
    try expectBudgetedCodes(&.{.refutable_parameter_pattern}, source, 1);
}

test "the usefulness budget: many constructors times many branches terminates" {
    // Forty constructors and forty branches, each branch a two-deep nest of
    // them: the shape that makes every column of the matrix complete, which
    // is where the exponent lives. The contract is that this FINISHES —
    // with the default budget it is analysed and answers `missing_patterns`,
    // with a small one it is refused as `pattern_budget_exhausted`, and
    // neither answer is a hang or a crash.
    const gpa = testing.allocator;
    const ctors = 40;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("pub type T\n");
    for (0..ctors) |i| try w.print("    {s} C{d} T\n", .{ if (i == 0) "=" else "|", i });
    try w.writeAll("\n\npub f : T -> Int\nf t =\n    case t of\n");
    for (0..ctors) |i| {
        if (i != 0) try w.writeAll("\n");
        try w.print("        C{d} (C{d} rest{d}) ->\n            {d}\n", .{ i, (i + 1) % ctors, i, i });
    }
    const text = try gpa.dupeZ(u8, out.written());
    defer gpa.free(text);

    for ([_]u32{ Session.default_pattern_budget, 64 }) |budget| {
        const codes = try budgetedCodes(gpa, text, budget);
        defer gpa.free(codes);
        // Exactly one message either way: the real answer, or the refusal
        // that says there is no real answer. Never a crash, never two.
        try testing.expectEqual(@as(usize, 1), codes.len);
        try testing.expect(codes[0] == .missing_patterns or codes[0] == .pattern_budget_exhausted);
    }
}

test "fuzz: arbitrary bytes as the patterns of a `case` never panic the usefulness check" {
    // The general pipeline fuzz below reaches `Exhaustive` only when random
    // bytes happen to make a declaration that type-checks, which is almost
    // never. This one puts the fuzzed bytes where the patterns of a `case`
    // over a real ADT go, so whatever the parser makes of them is what the
    // matrix is built from — mixed columns, poisoned references, nesting,
    // arities that do not match. Contract: no panic, and no diagnostic is
    // required.
    try testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const len = smith.sliceWithHash(&buf, 0x5E6A2);
            const gpa = testing.allocator;
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            out.writer.writeAll(
                \\pub type T
                \\    = A Int
                \\    | B
                \\    | C T T
                \\
                \\
                \\pub f : T -> Int
                \\f t =
                \\    case t of
                \\
            ) catch return;
            // One branch per line of the fuzzed bytes, each at the branch
            // indent, so a line that happens to be a pattern becomes one.
            var it = std.mem.splitScalar(u8, buf[0..len], '\n');
            while (it.next()) |line| {
                out.writer.print("        {s} ->\n            0\n\n", .{line}) catch return;
            }
            out.writer.writeAll("        _ ->\n            1\n") catch return;
            const source = gpa.dupeZ(u8, out.written()) catch return;
            defer gpa.free(source);
            var codes: std.ArrayList(diagnostic.Code) = .empty;
            defer codes.deinit(gpa);
            checkCodes(gpa, source, &codes) catch |err| switch (err) {
                error.OutOfMemory => return,
                else => return err,
            };
        }
    }.testOne, .{});
}

test "fuzz: the whole pipeline through the checker never panics" {
    // The checker eats a Bir TREE, not bytes, so its harness is the whole
    // front end plus the checker over arbitrary input: whatever the lexer,
    // the parser and lowering make of these bytes is what the checker has
    // to survive. Contract: no panic, and no diagnostic is required.
    try testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [1024]u8 = undefined;
            const len = smith.sliceWithHash(&buf, 0xC4EC6);
            const source = try testing.allocator.dupeZ(u8, buf[0..len]);
            defer testing.allocator.free(source);
            var codes: std.ArrayList(diagnostic.Code) = .empty;
            defer codes.deinit(testing.allocator);
            checkCodes(testing.allocator, source, &codes) catch |err| switch (err) {
                error.OutOfMemory => return,
                else => return err,
            };
        }
    }.testOne, .{});
}
