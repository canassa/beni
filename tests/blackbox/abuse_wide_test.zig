//! Abuse scenarios over WIDE inputs — records and nominal payloads at and
//! past the evidence limits, operator chains as wide as the parser admits,
//! types at the parameter cap. A file of its own only so that it runs as a
//! separate process in parallel with `abuse_test.zig`. Everything
//! `abuse_test.zig`'s header says about what an abuse scenario asserts, and
//! about sizing an input just past the limit it reaches, holds here.

const std = @import("std");
const diagnostic = @import("diagnostic");
const world = @import("world.zig");
const World = world.World;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const support = @import("abuse_support.zig");
const expectExited = support.expectExited;
const chain = support.chain;
const nested = support.nested;

// ---------------------------------------------------------------------------
// The equatable walk over a wide record
// ---------------------------------------------------------------------------

/// `r = { f1 = 1, …, f<n> = 1 }` with field `fn_at` a function (0: none),
/// then `same = <compare>` — `Basics.eq r r` or `r == r`.
fn wideRecord(gpa: std.mem.Allocator, n: usize, fn_at: usize, compare: []const u8) ![]u8 {
    var source: std.Io.Writer.Allocating = .init(gpa);
    errdefer source.deinit();
    const out = &source.writer;
    try out.writeAll("r =\n    { ");
    for (1..n + 1) |i| {
        if (i != 1) try out.writeAll(", ");
        if (i == fn_at) try out.print("f{d} = \\x -> x", .{i}) else try out.print("f{d} = 1", .{i});
    }
    try out.print(" }}\n\n\nsame : Bool\nsame =\n    {s}\n", .{compare});
    return source.toOwnedSlice();
}

test "Basics.eq on a record past the old 256-entry worklist walks all of it: all Int is equatable, a function at its last field is not" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The `equatable` walk's worklist was a fixed 256 entries, and a full
    // worklist answered "unknown", which `Basics.eq` accepted — so a function
    // in field 257 of a record compared structurally at run time. It is
    // growable now, and never answers on width: the all-`Int` record of 300
    // fields is accepted because every field was walked, and the function at
    // field 299 — past the old capacity, at the far end of the worklist — is
    // found.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const all_int = try wideRecord(testing.allocator, 300, 0, "Basics.eq r r");
    defer testing.allocator.free(all_int);
    try w.write("AllInt.beni", all_int);
    const with_fn = try wideRecord(testing.allocator, 300, 299, "Basics.eq r r");
    defer testing.allocator.free(with_fn);
    try w.write("WithFn.beni", with_fn);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const ok = try w.run(&.{ "check", "--no-cache", "AllInt.beni" });
    const bad = try w.run(&.{ "check", "--no-cache", "WithFn.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExited(ok, 0);
    try testing.expectEqualSlices(diagnostic.Diagnostic, &.{}, ok.diagnostics);
    try expectExited(bad, 1);
    try testing.expectEqual(@as(usize, 1), bad.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.not_equatable, bad.diagnostics[0].code);
    // At the first argument of `Basics.eq`, on the last line.
    try testing.expectEqual(@as(u32, 7), bad.diagnostics[0].span.start.line);
    try testing.expectEqual(@as(u32, 15), bad.diagnostics[0].span.start.col);
}

/// A program printing `eq` or `ne` for `r == r`, where `r` has `n` fields.
fn wideEqProgram(gpa: std.mem.Allocator, n: usize) ![]u8 {
    var source: std.Io.Writer.Allocating = .init(gpa);
    errdefer source.deinit();
    const out = &source.writer;
    try out.writeAll("import Node exposing (Program)\n\n\nr =\n    { ");
    for (1..n + 1) |i| {
        if (i != 1) try out.writeAll(", ");
        try out.print("f{d} = {d}", .{ i, i });
    }
    try out.writeAll(" }\n\n\nmain : Program\nmain =\n    Node.printLines [ if r == r then \"eq\" else \"ne\" ]\n");
    return source.toOwnedSlice();
}

// `==` on a record DERIVES one function with a parameter per field, and a
// JavaScript call that wide overflows the engine's stack: under Node 24 a
// 60 000- and a 65 530-field `r == r` built and then threw `RangeError`. Up
// to 4 096 positions the evidence is positional; past it, one array
// (`static-dispatch-spike.md` §9.2), so the width that threw no longer makes
// a wide call. This scenario builds and runs the widest positional record;
// one past the positional limit is the scenario after it. A width that
// threw, 65 530 fields, is over the test budget on the compiler the gates
// run, so it waits in `pending_test.zig` until that compiler fits it.
test "== on a record builds and runs at the widest positional evidence" {
    try wideEqRuns(4_096);
}

fn wideEqRuns(n: usize) !void {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const source = try wideEqProgram(testing.allocator, n);
    defer testing.allocator.free(source);
    try w.write("Wide.beni", source);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // The program's output is asserted as it runs.
    const built = try w.buildAndRun(&.{ "--no-cache", "Wide.beni" }, .{ .stdout = "eq\n" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExited(built, 0);
    try testing.expectEqualStrings("", built.stderr);
}

// `==` and `<` on a record one field past the positional evidence limit. The
// old checker capped a derived record `eq`/`compare` at 4 096 fields
// (`not_equatable` and `no_methods_on_shape` past it), because a derived
// function took one JavaScript parameter per field and V8 threw between
// 40 000 and 60 000. The wide form (`static-dispatch-spike.md` §9.2) takes
// the evidence as one array past 4 096 positions, and the checker lifts the
// cap (checker-v2.md §11.2): the program builds, runs and prints its three
// answers; a refusal is the finding.
test "`==` and `<` on a record one field past the positional evidence limit build and run" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const n = 4_097;
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    const out = &text.writer;
    try out.writeAll("import Node exposing (Program)\n\n\nr =\n    { ");
    for (1..n + 1) |i| try out.print("{s}f{d} = {d}", .{ if (i == 1) "" else ", ", i, i });
    try out.print(" }}\n\n\nmain : Program\nmain =\n    Node.printLines [ if r == r then \"eq\" else \"ne\", if r == {{ r | f{d} = 0 }} then \"eq\" else \"ne\", if {{ r | f1 = 0 }} < r then \"lt\" else \"ge\" ]\n", .{n});
    try w.write("Main.beni", text.written());

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // The program's output is asserted as it runs.
    const built = try w.buildAndRun(&.{ "--no-cache", "--jobs=1", "Main.beni" }, .{ .stdout = "eq\nne\nlt\n" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExited(built, 0);
    try testing.expectEqualStrings("", built.stderr);
}

// A nominal payload record of 65 537 fields. The eager pass probes `T`'s
// derived `eq` whether or not anything compares `T`, and an older checker
// kept a derived row's context index in a `u16`: a panic in a safety build.
// 65 537 and not 65 536: the record's structural row has one entry per
// field, so its last entry's index is 65 536, one past what a `u16` holds.
// On the ReleaseSafe binary, whose safety checks are part of the claim. The
// index is the checker's, so `check` of the type alone is the whole claim:
// with `Dispatch.ContextEntry.param` narrowed back to a `u16` it panics. A
// build and a run of a comparison could not observe it anyway — every field
// has the same evidence — and the width a program runs at is the record
// scenarios' above.
test "a nominal payload of 65 537 fields checks" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const n = 65_537;
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    const out = &text.writer;
    try out.writeAll("type T =\n    T { ");
    for (1..n + 1) |i| try out.print("{s}f{d} : Int", .{ if (i == 1) "" else ", ", i });
    try out.writeAll(" }\n");
    try w.write("Main.beni", text.written());

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.run(&.{ "check", "--no-cache", "--jobs=1", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExited(checked, 0);
    try testing.expectEqual(@as(usize, 0), checked.diagnostics.len);
}

// ---------------------------------------------------------------------------
// Chains as long as their input is wide
// ---------------------------------------------------------------------------

// A 2 000-element list literal, which the compiler accepted and once lowered
// to JavaScript nested deeper than Node 24's parser loads — it threw
// `RangeError` from about 1 550 levels — one nested cell per element, which
// also segfaulted the printer. The parser's budget does not charge list
// elements; past 32 elements a list is one flat array (`backend.md` §4). It
// builds and runs, printing its length, in each build. Operator chains are
// the scenarios after it.
test "a 2 000-element list builds and runs" {
    try longListRuns("--no-cache");
}

test "a 2 000-element list builds and runs under --release" {
    try longListRuns("--release");
}

fn longListRuns(flag: []const u8) !void {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = w.arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "import Node exposing (Program)\n\n\nxs : List Int\nxs =\n    [ ");
    for (0..2_000) |i| try text.appendSlice(a, if (i == 0) "1" else ", 1");
    try text.appendSlice(a, " ]\n\n\nmain : Program\nmain =\n    Node.printLines [ String.fromInt (List.length xs) ]\n");
    try w.write("Main.beni", text.items);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // The program's output is asserted as it runs.
    const r = try w.buildAndRun(&.{ flag, "Main.beni" }, .{ .stdout = "2000\n" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExited(r, 0);
    try testing.expectEqualStrings("", r.stderr);
}

// The user's half: an operator chain a person writes. The parser charges
// every operator to `Parse.max_depth`, so a chain is bounded before the
// backend sees it: `&&` over `x == 3` reaches the budget at 1 366 terms
// (three charges each), `++` at 2 049 (two) and `+` at 4 096 (one), and one
// term past the widest is exactly one `nesting_too_deep`. Under it the chain
// goes through check, both walks and the printer — and RUNS at the widest
// the parser admits, in each build: `&&` prints as one flat run and
// `+`/`++` are bound to a `const` every `nesting.spill` units (`backend.md`
// §4), so no call nests one level per term (Node refuses such nesting from
// about 1 550), and `--release`'s inlining never folds a spilled `const`
// back into its user.
const OperatorChain = struct {
    head: []const u8,
    term: []const u8,
    op: []const u8,
    width: usize,
    tail: []const u8,
    expected: []const u8,

    const and_: OperatorChain = .{ .head = "x : Int\nx =\n    3\n\n\nb : Bool\nb =\n    ", .term = "x == 3", .op = " && ", .width = 1_365, .tail = "Node.printLines [ if b then \"yes\" else \"no\" ]", .expected = "yes\n" };
    const plus: OperatorChain = .{ .head = "x : Int\nx =\n    1\n\n\nb : Int\nb =\n    ", .term = "x", .op = " + ", .width = 4_095, .tail = "Node.printLines [ String.fromInt b ]", .expected = "4095\n" };
    const append: OperatorChain = .{ .head = "x : String\nx =\n    \"a\"\n\n\nb : String\nb =\n    ", .term = "x", .op = " ++ ", .width = 2_048, .tail = "Node.printLines [ String.fromInt (String.length b) ]", .expected = "2048\n" };

    /// The program whose `b` is the chain of `n` terms.
    fn write(chain_: OperatorChain, w: *World, n: usize) !void {
        var source: std.Io.Writer.Allocating = .init(testing.allocator);
        defer source.deinit();
        try source.writer.print("import Node exposing (Program)\n\n\n{s}", .{chain_.head});
        for (0..n) |i| try source.writer.print("{s}{s}", .{ if (i == 0) "" else chain_.op, chain_.term });
        try source.writer.print("\n\n\nmain : Program\nmain =\n    {s}\n", .{chain_.tail});
        try w.write("Main.beni", source.written());
    }

    /// At its widest, the chain builds and runs.
    fn runs(chain_: OperatorChain, build: enum { dev, release }) !void {
        // ┌─────────────────────────────────────┐
        // │ PREPARE                             │
        // └─────────────────────────────────────┘
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        try chain_.write(&w, chain_.width);

        // ┌─────────────────────────────────────┐
        // │ EXECUTE                             │
        // └─────────────────────────────────────┘
        // The program's output is asserted as it runs.
        const expected: world.Expected = .{ .stdout = chain_.expected };
        const r = switch (build) {
            .dev => try w.buildAndRun(&.{ "--no-cache", "Main.beni" }, expected),
            .release => try w.buildAndRun(&.{ "--no-cache", "--release", "Main.beni" }, expected),
        };

        // ┌─────────────────────────────────────┐
        // │ VERIFY OUTPUT                       │
        // └─────────────────────────────────────┘
        try expectExited(r, 0);
    }

    /// One term past its widest, the chain is one `nesting_too_deep`.
    fn refused(chain_: OperatorChain) !void {
        // ┌─────────────────────────────────────┐
        // │ PREPARE                             │
        // └─────────────────────────────────────┘
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        try chain_.write(&w, chain_.width + 1);

        // ┌─────────────────────────────────────┐
        // │ EXECUTE                             │
        // └─────────────────────────────────────┘
        const r = try w.run(&.{ "build", "--no-cache", "--platform=node", "--out=wide", "Main.beni" });

        // ┌─────────────────────────────────────┐
        // │ VERIFY OUTPUT                       │
        // └─────────────────────────────────────┘
        try expectExited(r, 1);
        try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
        try testing.expectEqual(diagnostic.Code.nesting_too_deep, r.diagnostics[0].code);

        // ┌─────────────────────────────────────┐
        // │ VERIFY SIDE EFFECTS                 │
        // └─────────────────────────────────────┘
        try testing.expect(!w.exists("wide"));
    }
};

test "a written && chain runs at the widest the parser admits" {
    try OperatorChain.and_.runs(.dev);
}

test "a written && chain runs at the widest the parser admits under --release" {
    try OperatorChain.and_.runs(.release);
}

test "a written && chain one term past the widest is one nesting_too_deep" {
    try OperatorChain.and_.refused();
}

test "a written + chain runs at the widest the parser admits" {
    try OperatorChain.plus.runs(.dev);
}

test "a written + chain runs at the widest the parser admits under --release" {
    try OperatorChain.plus.runs(.release);
}

test "a written + chain one term past the widest is one nesting_too_deep" {
    try OperatorChain.plus.refused();
}

test "a written ++ chain runs at the widest the parser admits" {
    try OperatorChain.append.runs(.dev);
}

test "a written ++ chain runs at the widest the parser admits under --release" {
    try OperatorChain.append.runs(.release);
}

test "a written ++ chain one term past the widest is one nesting_too_deep" {
    try OperatorChain.append.refused();
}

// ---------------------------------------------------------------------------
// Type arity (interface v3: `checker-v2.md` §14.2)
// ---------------------------------------------------------------------------

/// `pub type Wide a0 … a<n-1> = Wide a0`.
fn wideParams(gpa: Allocator, n: usize) ![]u8 {
    var source: std.Io.Writer.Allocating = .init(gpa);
    errdefer source.deinit();
    try source.writer.writeAll("pub type Wide");
    for (0..n) |i| try source.writer.print(" a{d}", .{i});
    try source.writer.writeAll("\n    = Wide a0\n");
    return source.toOwnedSlice();
}

// An arity is a `u16` in interface v3: as a `u8` it would saturate at 255 and
// a 256-parameter type would be imported at the wrong width
// (`check/good/WideTypeArity/`). §14.2's "a saturating cast becomes an error
// at 65 535" is this: lowering refuses the 65 536th parameter, once, at that
// parameter, so nothing downstream can saturate. The duplicate-parameter scan
// is a sort, so the 65 536-parameter declaration costs no pairwise work, and
// nothing reaches the checker's `@intCast` in `deriveOneParts` with a width
// it cannot hold.
test "a type of 65 535 parameters checks" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const widest = try wideParams(testing.allocator, 65_535);
    defer testing.allocator.free(widest);
    try w.write("Widest.beni", widest);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const ok = try w.run(&.{ "check", "--no-cache", "Widest.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExited(ok, 0);
    try testing.expectEqual(@as(usize, 0), ok.diagnostics.len);
}

test "a type's 65 536th parameter is one too_many_type_parameters" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const past = try wideParams(testing.allocator, 65_536);
    defer testing.allocator.free(past);
    try w.write("Past.beni", past);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const refused = try w.run(&.{ "build", "--no-cache", "--library", "--platform=node", "--out=past", "Past.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExited(refused, 1);
    // The 65 536th parameter is `a65535`, one past the space before it.
    const at: u32 = @intCast(std.mem.indexOf(u8, past, " a65535\n").? + 2);
    try testing.expectEqualDeep(&[_]diagnostic.Diagnostic{.{
        .code = .too_many_type_parameters,
        .severity = .@"error",
        .span = .{ .file = "Past.beni", .start = .{ .line = 1, .col = at }, .end = .{ .line = 1, .col = at + 6 } },
        .title = "TOO MANY TYPE PARAMETERS",
        .message = "This type has more than 65 535 type parameters, the most a type may declare.\n" ++
            "`a65535` is the first one past that.\n\n" ++
            "A type's number of parameters is a 16-bit count in the interface other modules\n" ++
            "read it through, so it cannot be recorded exactly. Group the parameters into\n" ++
            "records or into types of their own.",
    }}, refused.diagnostics);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("past"));
}

// ---------------------------------------------------------------------------
// A derived row past 65 535 context entries
// ---------------------------------------------------------------------------

test "a derived row of more than 65 535 context entries checks" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A derived row has one evidence parameter per context entry, and an
    // entry per (type parameter, method it is asked for), so entries outrun
    // parameters: `W`'s 656 parameters, each inside a `Holder` whose `eq`
    // asks 100 methods of it, are 65 600. Elaborating `W`'s derived `eq`
    // turns each method its body asks of a parameter into the index of that
    // entry, and the last index, 65 599, is past what a `u16` holds: an index
    // kept in one panicked in a safety build and, in ReleaseFast, wrapped to
    // another entry's evidence. The lookup is linear in the entries (it was
    // quadratic: 74 s and 3.1 GB of a Debug build). The index is the
    // checker's, so `check` is the whole claim; what a wide row's evidence
    // does at run time is the record scenarios' above.
    const methods = 100;
    const params = 656;
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    var holder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer holder.deinit();
    const h = &holder.writer;
    try h.writeAll("pub type Holder a\n    = Holder a\n\n\npub eq : Holder a, Holder a -> Bool\n    where ");
    for (0..methods) |j| try h.print("{s}a.m{d} : a, () -> Int", .{ if (j == 0) "" else ", ", j });
    try h.writeAll("\neq (Holder x) (Holder y) =\n    ");
    for (0..methods) |j| try h.print("{s}x.m{d} () == y.m{d} ()", .{ if (j == 0) "" else " && ", j, j });
    try h.writeAll("\n");
    try w.write("H.beni", holder.written());
    var wide: std.Io.Writer.Allocating = .init(testing.allocator);
    defer wide.deinit();
    const out = &wide.writer;
    try out.writeAll("import H\n\n\npub type W");
    for (0..params) |i| try out.print(" p{d}", .{i});
    try out.writeAll("\n    = W");
    for (0..params) |i| try out.print(" (H.Holder p{d})", .{i});
    try out.writeAll("\n");
    try w.write("Main.beni", wide.written());

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.run(&.{ "check", "--no-cache", "--platform=node", "H.beni", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExited(checked, 0);
    try testing.expectEqual(@as(usize, 0), checked.diagnostics.len);
}

// One `case` of n literal branches. `js/Decision.zig` compared every row with
// every other three times over, so a build of 20 000 branches took 8.6 s
// (ReleaseFast) and 70 000 would take minutes; and the one `switch` it
// wrote had n labels, where SpiderMonkey — Firefox and its shell — refuses
// more than 65 046 (`backend.md` §4's table), so the module would have
// thrown at load in Firefox while Node, which takes 300 000, ran it. The
// rows are grouped by literal now, and a fan of more than 16 384 labels is
// written as consecutive `switch`es over the same discriminant. The timing
// half is in `perf_test.zig`; this is the shape half, at 16 400 branches:
// just past one `switch`'s worth, so the fan must be split in two. Each
// build is its own scenario.
test "a case of 16 400 literal branches builds as switches of at most 16 384 labels and runs" {
    try wideLiteralCase("--no-cache");
}

test "a case of 16 400 literal branches builds as switches of at most 16 384 labels and runs under --release" {
    try wideLiteralCase("--release");
}

fn wideLiteralCase(flag: []const u8) !void {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    const branches = 16_400;
    const max_labels = 16_384;
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    var source: std.Io.Writer.Allocating = .init(testing.allocator);
    defer source.deinit();
    const out = &source.writer;
    try out.writeAll("import Node exposing (Program)\n\n\ng : Int -> Int\ng k =\n    case k of\n");
    for (0..branches) |i| try out.print("        {d} ->\n            {d}\n\n", .{ i, i + 1 });
    try out.writeAll("        _ ->\n            -1\n\n\n");
    // Each chunk's first and last label, the default, and a miss past the end.
    try out.writeAll(
        \\main : Program
        \\main =
        \\    Node.printLines (List.map [ 0, 16383, 16384, 16399, 16400, -5 ] (\k -> String.fromInt (g k)))
        \\
    );
    try w.write("Main.beni", source.written());

    {
        // ┌─────────────────────────────────────┐
        // │ EXECUTE                             │
        // └─────────────────────────────────────┘
        // The program's output is asserted as it runs.
        const r = try w.buildAndRun(&.{ flag, "Main.beni" }, .{ .stdout = "1\n16384\n16385\n16400\n-1\n-1\n" });

        // ┌─────────────────────────────────────┐
        // │ VERIFY OUTPUT                       │
        // └─────────────────────────────────────┘
        try expectExited(r, 0);
        try testing.expectEqualStrings("", r.stderr);

        // ┌─────────────────────────────────────┐
        // │ VERIFY SIDE EFFECTS                 │
        // └─────────────────────────────────────┘
        // The module's one `case` is ⌈16 401 / 16 384⌉ = 2 `switch`es, none
        // over the bound: every label between two `switch`es is counted
        // against the one before.
        const js = try w.read("out/Main.mjs");
        var switches: usize = 0;
        var labels: usize = 0;
        var worst: usize = 0;
        for (0..js.len) |i| {
            if (std.mem.startsWith(u8, js[i..], "switch")) {
                switches += 1;
                labels = 0;
            } else if (std.mem.startsWith(u8, js[i..], "case ") or std.mem.startsWith(u8, js[i..], "default:")) {
                labels += 1;
                worst = @max(worst, labels);
            }
        }
        try testing.expectEqual(@as(usize, 2), switches);
        try testing.expectEqual(@as(usize, max_labels), worst);
    }
}
