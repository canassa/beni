//! Declaration-order scenarios for own methods (`checker-v2.md` §10.2–
//! §10.5): whether a program checks, and what it prints or reports, never
//! depends on the order its declarations are written in; and the nesting
//! budget a check that nests another check spends.
//!
//! A process of its own so that it runs in parallel with the other
//! black-box binaries. A scenario that is not GREEN fails the step.

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const Io = std.Io;
const testing = std.testing;

// ┌─────────────────────────────────────────────────────────────────────────┐
// │ SCENARIOS                                                               │
// └─────────────────────────────────────────────────────────────────────────┘

// The checker's order-dependence regressions are corpus fixtures, and almost
// every one of them failed as written: the corpus walker's own case is its
// regression test. The programs below are the exception. Each checked, built
// or was refused correctly as written and went wrong only with its top-level
// declarations in another order — in every case here, the reverse of the
// written one — so each test writes that order and asserts what the
// fixture asserts as written. Top-level comments are dropped; nothing else
// about the program changes.

// An own method written below the annotated function whose parameter
// receives it, called from a `let` helper used at two types: the method's
// group is checked when it is first demanded, and the helper still
// generalises. It was refused with NOT IMPLEMENTED YET.
test "a let helper at two types calls an own method written below it, reversed, and prints the same" {
    try expectReversedPrints("tests/corpus/run/SingleMemberGroupReceiver.beni", "tests/corpus/run/SingleMemberGroupReceiver.expected");
}

// A recursive group's annotated receiver, in both member orders, calling an
// own method written below the group. It was refused with NOT IMPLEMENTED
// YET at each call.
test "an annotated recursive group calls an own method written below it, reversed, and prints the same" {
    try expectReversedPrints("tests/corpus/run/RecursiveGroupAnnotatedReceiver.beni", "tests/corpus/run/RecursiveGroupAnnotatedReceiver.expected");
}

// A dispatch cycle `show` → `eq` → `show` through an annotated `eq`, with
// `eq` written above `show` and both above the types they use. It was
// refused with NOT IMPLEMENTED YET at the comparisons.
test "a dispatch cycle through an annotated eq written above its caller, reversed, prints the same" {
    try expectReversedPrints("tests/corpus/run/RecursiveDispatchAnnotated.beni", "tests/corpus/run/RecursiveDispatchAnnotated.expected");
}

// A wrapper of a schema endpoint that reaches a function type only through
// a `via` conversion's own target type. Reversed, the endpoint's properties
// were settled before the target was inferred and the comparison checked
// clean; it must be the written order's one `not_equatable`, the same
// message at the same source text.
test "a schema endpoint's exclusion through its via target is the same refusal reversed" {
    var s = try Scenario.init("a schema endpoint's exclusion, reversed");
    defer s.deinit();
    const a = s.arena();
    const path = "tests/corpus/check/bad/SchemaWrapperExclusionThroughOwnType.beni";
    const written = try source(a, path, .written);
    const reversed = try source(a, path, .reversed);
    try s.w.write("Written.beni", written);
    try s.w.write("Reversed.beni", reversed);
    const run = try s.w.runWith(&.{ "check", "--no-cache", "--diagnostics=json", "--platform=node", "Written.beni", "Reversed.beni" }, .{ .raw_diagnostics = true });
    const trimmed = std.mem.trim(u8, run.stderr, " \r\n");
    const diags = std.json.parseFromSliceLeaky([]@import("diagnostic").Diagnostic, a, trimmed, .{}) catch return s.finish(try s.failed(run));
    const want = (refusals(diags, "Written.beni", written, .not_equatable)) orelse return s.finish(try s.failed(run));
    const got = (refusals(diags, "Reversed.beni", reversed, .not_equatable)) orelse return s.finish(try s.failed(run));
    const same = std.mem.eql(u8, want.message, got.message) and std.mem.eql(u8, want.text, got.text);
    try s.finish(.{ .green = same, .signature = if (same) "" else "exit=1 differs", .detail = "the reversed order's refusal differs from the written order's" });
}

// Schema endpoints through the derived-context fixpoint whose `via` target
// mentions the endpoint back, or which wrap a record endpoint. Reversed,
// both stopped the checker with the invariant "an item was readied for a
// frame that is gone".
// A view whose `For` names an unannotated helper that writes markup: the
// helper's hole, its handler's form and the row function's arity are
// markup obligations, decided by types (`checker-v2.md` §25.4). Written with
// the view first it checks clean; reversed, it must too.
test "a view and the markup helper its For names check in the reverse order" {
    try expectReversedChecks("tests/corpus/check/good/markup/HelpersInEitherOrder.beni");
}

// A `let` whose markup's handler is the enclosing parameter `g`, and a
// binding that fixes `g`'s type. Written with the markup first, the markup's
// message variable was generalised before the handler's form was decided;
// with the call first it was not. Both orders must infer the fixture's type,
// `(String -> a) -> ( Html a, a )`.
test "a let's markup and the call that decides its handler infer one type in either binding order" {
    var s = try Scenario.init("a let's markup binding and the call after it, swapped");
    defer s.deinit();
    const a = s.arena();
    const written = try readRepo(a, "tests/corpus/check/good/markup/LetMarkupObligationLater.beni");
    const markup_first =
        \\        v = <input onInput={g} />
        \\
        \\        z = g "x"
        \\
    ;
    const call_first =
        \\        z = g "x"
        \\
        \\        v = <input onInput={g} />
        \\
    ;
    const swapped = try std.mem.replaceOwned(u8, a, written, markup_first, call_first);
    if (std.mem.eql(u8, swapped, written)) return s.finish(.{ .green = false, .signature = "fixture-changed", .detail = "the fixture no longer holds the two bindings this scenario swaps" });
    try s.w.write("Written.beni", written);
    try s.w.write("Swapped.beni", swapped);
    var faces: [2][]const u8 = undefined;
    for ([_][]const u8{ "Written.beni", "Swapped.beni" }, &faces) |file, *slot| {
        const run = try s.w.runWith(&.{ "dump", "--stage=interface", "--platform=html", file }, .{ .raw_diagnostics = true });
        if (run.exit_code != 0) return s.finish(try s.failed(run));
        // Everything after the `module` line, which names the file.
        slot.* = run.stdout[(std.mem.indexOfScalar(u8, run.stdout, '\n') orelse run.stdout.len)..];
    }
    const same = std.mem.eql(u8, faces[0], faces[1]);
    try s.finish(.{ .green = same, .signature = if (same) "" else "exit=0 iface-differs", .detail = if (same) "" else try std.mem.replaceOwned(u8, a, try std.fmt.allocPrint(a, "markup first: {s} call first: {s}", .{ faces[0], faces[1] }), "\n", " | ") });
}

test "a schema via a mutually recursive own type checks reversed" {
    try expectReversedChecks("tests/corpus/check/good/SchemaViaMutualOwnType.beni");
}

test "a type wrapping a record schema endpoint checks reversed" {
    try expectReversedChecks("tests/corpus/check/good/SchemaRecordViaWrapped.beni");
}

// Uses of an alias that drops its parameter, met in a recursive group: the
// group's result is one type whichever use it meets first. Reversed, `f`
// and `g` were inferred `number -> Int` where the written order says
// `number -> Tagged String`; every declaration's type must be the written
// order's.
test "an alias that drops its parameter names the same types reversed" {
    var s = try Scenario.init("a phantom alias in a recursive group, reversed");
    defer s.deinit();
    const a = s.arena();
    const path = "tests/corpus/run/PhantomAliasUnifiesByExpansion.beni";
    try s.w.write("Written.beni", try source(a, path, .written));
    try s.w.write("Reversed.beni", try source(a, path, .reversed));
    var blocks: [2][]const u8 = undefined;
    for ([_][]const u8{ "Written.beni", "Reversed.beni" }, &blocks) |file, *slot| {
        const run = try s.w.runWith(&.{ "dump", "--stage=types", "--platform=node", file }, .{ .raw_diagnostics = true });
        if (run.exit_code != 0) return s.finish(try s.failed(run));
        slot.* = try declBlocks(a, run.stdout);
    }
    const same = std.mem.eql(u8, blocks[0], blocks[1]);
    try s.finish(.{ .green = same, .signature = if (same) "" else "exit=0 types-differ", .detail = if (same) "" else try std.mem.replaceOwned(u8, a, try std.fmt.allocPrint(a, "written: {s} reversed: {s}", .{ blocks[0], blocks[1] }), "\n", " | ") });
}

/// `path`'s program with its declarations reversed builds, and prints
/// exactly `twin`.
fn expectReversedPrints(comptime path: []const u8, twin: []const u8) !void {
    var s = try Scenario.init(path);
    defer s.deinit();
    const a = s.arena();
    try s.w.write("Main.beni", try source(a, path, .reversed));
    const built = try s.w.runWith(&.{ "build", "--no-cache", "--diagnostics=json", "--platform=node", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });
    if (built.exit_code != 0) return s.finish(try s.failed(built));
    const expected = try readRepo(a, twin);
    const differs = try s.w.checkProgram(world.entry_file, .{ .stdout = expected });
    try s.finish(.{
        .green = differs == null,
        .signature = if (differs == null) "" else "exit=0 stdout-differs",
        .detail = if (differs) |program| program.stdout[0..@min(program.stdout.len, 300)] else "",
    });
}

/// `path`'s program with its declarations reversed checks clean.
fn expectReversedChecks(comptime path: []const u8) !void {
    var s = try Scenario.init(path);
    defer s.deinit();
    try s.w.write("Main.beni", try source(s.arena(), path, .reversed));
    const run = try s.w.runWith(&.{ "check", "--no-cache", "--diagnostics=json", "--platform=node", "Main.beni" }, .{ .raw_diagnostics = true });
    if (run.exit_code != 0 or std.mem.trim(u8, run.stderr, " \r\n").len != 0) return s.finish(try s.failed(run));
}

fn readRepo(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(world.max_stream_bytes));
}

/// A fixture's program rebuilt from its `import` lines and its top-level
/// declarations (each with its annotation), in the written order or
/// reversed. Top-level comments are dropped.
fn source(arena: std.mem.Allocator, path: []const u8, order: enum { written, reversed }) ![]const u8 {
    const text = try readRepo(arena, path);
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
    if (order == .reversed) std.mem.reverse([]const u8, decls.items);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, imports.items);
    for (decls.items) |d| {
        try out.appendSlice(arena, "\n\n");
        try out.appendSlice(arena, d);
        try out.append(arena, '\n');
    }
    return out.items;
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

/// A file's refusals: exactly one diagnostic, of `code`, as its message and
/// the source text under its span. Null when the count or the code differs.
const Refusals = struct { message: []const u8, text: []const u8 };

fn refusals(diags: []const @import("diagnostic").Diagnostic, file: []const u8, text: []const u8, code: @import("diagnostic").Code) ?Refusals {
    var found: ?Refusals = null;
    for (diags) |d| {
        if (!std.mem.eql(u8, std.fs.path.basename(d.span.file), file)) continue;
        if (d.code != code or found != null) return null;
        found = .{ .message = d.message, .text = spanText(text, d.span.start.line, d.span.start.col, d.span.end.line, d.span.end.col) };
    }
    return found;
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

// The name an inferred type shows is the same in every declaration order
// ("agree or expand", checker-v2.md §7.1, §21.1). `x : Name` (`type alias
// Name = String`), `y : String`, and a recursive group `f` → `x`, `g` → `y`:
// its members' result is one flex that meets both `Name` and `String`, so it
// shows the expansion, `String`, whichever it meets first; and `x` still
// prints as its annotation is written.
test "an inferred type names the same alias in every declaration order" {
    var s = try Scenario.init("an inferred alias name");
    defer s.deinit();
    const head = "type alias Name =\n    String\n\n\nx : Name\nx =\n    \"x\"\n\n\ny : String\ny =\n    \"y\"\n\n\n";
    const f = "f n =\n    if n == 0 then\n        x\n\n    else\n        g (n - 1)\n\n\n";
    const g = "g n =\n    if n == 0 then\n        y\n\n    else\n        f (n - 1)\n\n\n";
    try s.w.write("FG.beni", head ++ f ++ g);
    try s.w.write("GF.beni", head ++ g ++ f);
    var types: [2][]const u8 = undefined;
    for ([_][]const u8{ "FG.beni", "GF.beni" }, &types) |file, *slot| {
        const run = try s.w.runWith(&.{ "dump", "--stage=types", "--diagnostics=json", file }, .{ .raw_diagnostics = true });
        if (run.exit_code != 0) return s.finish(try s.failed(run));
        // The annotation prints as written.
        if (std.mem.indexOf(u8, run.stdout, "\n  x : Name\n") == null) return s.finish(.{ .green = false, .signature = "stdout-differs", .detail = "`x : Name` is not printed as written" });
        // `f`'s line: the module line and the declaration order differ.
        const at = std.mem.indexOf(u8, run.stdout, "\n  f : ") orelse return s.finish(.{ .green = false, .signature = "stdout-differs", .detail = "no `f` in the dump" });
        const end = std.mem.indexOfScalarPos(u8, run.stdout, at + 1, '\n') orelse run.stdout.len;
        slot.* = run.stdout[at + 1 .. end];
    }
    const same = std.mem.eql(u8, types[0], types[1]);
    try s.finish(.{
        .green = same,
        .signature = if (same) "" else "order-dependent",
        .detail = try std.fmt.allocPrint(s.arena(), "f above g: `{s}`; g above f: `{s}`", .{ types[0], types[1] }),
    });
}

// The same rule inside a structure: `names : List Name`, `labels : List
// Label` (both aliases of `String`) and a recursive group `g` → `labels`, `f`
// → `names`. Its result meets `List Name` and `List Label`, so it shows `List
// String`. `check/good/AliasNamesInsideStructures.beni` writes `f` above `g`
// (and both branch orders of an `if`); this is the reverse, where the group
// kept `List Label` and the written order `List Name`.
test "alias names inside a structure show the expansion with the group reversed" {
    var s = try Scenario.init("alias names inside a structure");
    defer s.deinit();
    const head = "type alias Name =\n    String\n\n\ntype alias Label =\n    String\n\n\nnames : List Name\nnames =\n    [ \"x\" ]\n\n\nlabels : List Label\nlabels =\n    [ \"y\" ]\n\n\n";
    const g = "g n =\n    if n == 0 then\n        labels\n\n    else\n        f (n - 1)\n\n\n";
    const f = "f n =\n    if n == 0 then\n        names\n\n    else\n        g (n - 1)\n";
    try s.w.write("GF.beni", head ++ g ++ f);
    const run = try s.w.runWith(&.{ "dump", "--stage=types", "--diagnostics=json", "GF.beni" }, .{ .raw_diagnostics = true });
    if (run.exit_code != 0) return s.finish(try s.failed(run));
    for ([_][]const u8{ "\n  f : number -> List String\n", "\n  g : number -> List String\n", "\n  names : List Name\n", "\n  labels : List Label\n" }) |line| {
        if (std.mem.indexOf(u8, run.stdout, line) == null) return s.finish(.{
            .green = false,
            .signature = "order-dependent",
            .detail = try std.mem.replaceOwned(u8, s.arena(), run.stdout, "\n", " | "),
        });
    }
}

// The same two names met by an `if`, in both branch orders, each the only
// declaration of its module: `pick` is `Bool -> List String` either way. With
// the first name kept, the two printed `List Name` and `List Label`.
test "alias names met by an if show the expansion in either branch order" {
    var s = try Scenario.init("alias names in two branch orders");
    defer s.deinit();
    const head = "type alias Name =\n    String\n\n\ntype alias Label =\n    String\n\n\nnames : List Name\nnames =\n    [ \"x\" ]\n\n\nlabels : List Label\nlabels =\n    [ \"y\" ]\n\n\n";
    try s.w.write("NamesFirst.beni", head ++ "pick c =\n    if c then\n        names\n\n    else\n        labels\n");
    try s.w.write("LabelsFirst.beni", head ++ "pick c =\n    if c then\n        labels\n\n    else\n        names\n");
    for ([_][]const u8{ "NamesFirst.beni", "LabelsFirst.beni" }) |file| {
        const run = try s.w.runWith(&.{ "dump", "--stage=types", "--diagnostics=json", file }, .{ .raw_diagnostics = true });
        if (run.exit_code != 0) return s.finish(try s.failed(run));
        if (std.mem.indexOf(u8, run.stdout, "\n  pick : Bool -> List String\n") == null) return s.finish(.{
            .green = false,
            .signature = "order-dependent",
            .detail = try std.mem.replaceOwned(u8, s.arena(), run.stdout, "\n", " | "),
        });
    }
}

// An own method whose type fits no use of two types of its module is one
// mistake, said once at its declaration, after every use was checked
// (`Instances.ownSignatures`): `type T`, `type V`, `pub eq : T, Int -> Bool`
// and a `==` on each, in two declaration orders, print the same messages in
// the same order.
test "one own method's messages print the same in every declaration order" {
    var s = try Scenario.init("an own method's messages");
    defer s.deinit();
    const t = "type T\n    = T Int\n\n\n";
    const v = "type V\n    = V Int\n\n\n";
    const eq = "pub eq : T, Int -> Bool\neq (T a) b =\n    a == b\n\n\n";
    const one = "one =\n    T 1 == T 1\n\n\n";
    const two = "two =\n    V 2 == V 2\n\n\n";
    // One module name in both orders (a message names `Main.eq`): each order
    // is a project of its own.
    try s.w.write("tv/Main.beni", t ++ v ++ eq ++ one ++ two);
    try s.w.write("vt/Main.beni", two ++ one ++ eq ++ v ++ t);
    var texts: [2][]const u8 = undefined;
    for ([_][]const u8{ "tv", "vt" }, &texts) |file, *slot| {
        const run = try s.w.runWith(&.{ "check", "--no-cache", "--diagnostics=json", file }, .{ .raw_diagnostics = true });
        if (run.exit_code != 1) return s.finish(try s.failed(run));
        const trimmed = std.mem.trim(u8, run.stderr, " \r\n");
        const diags = std.json.parseFromSliceLeaky([]@import("diagnostic").Diagnostic, s.arena(), trimmed, .{}) catch return s.finish(try s.failed(run));
        var out: std.ArrayList(u8) = .empty;
        for (diags) |d| try out.print(s.arena(), "{t}: {s}\n", .{ d.code, d.message });
        slot.* = out.items;
    }
    const same = std.mem.eql(u8, texts[0], texts[1]);
    try s.finish(.{
        .green = same,
        .signature = if (same) "" else "order-dependent",
        .detail = if (same) "one text in both orders" else "the messages differ in text or in order between the two declaration orders",
    });
}

// The nesting budget (checker-v2.md §10.2): chains of own methods `m0 … mn`
// on one type, each calling the next, written in REVERSE dependency order
// (`m0`, which needs `m1`, first), so checking `m0` nests `m1`, which nests
// `m2`, and so on. The budget admits a nested check while the solver depth
// summed over the open groups, plus `nest_cost` (3) per nesting, leaves one
// declaration's worth (4 200) of the budget (8 400): a chain's link costs 4
// depth units and 3, so about 599 nest (`Groups.nest_cost`'s comment). The
// same chains below the budget are timed for linearity in `perf_test.zig`.
//
//   - A chain of 650 links, just past the budget, is refused exactly once —
//     the check that `m0` started runs out at about the 600th link and is
//     refused at that use, and the rest is checked from the next group in
//     SCC order, within the budget — with the hint, and no crash.
//   - A "pair of deep declarations" (§5.6), which the budget admits one at a
//     time (a demand at depth 2 500 leaves 5 900 units): what reaches the
//     refusal is a chain of TWO demands each about 2 150 levels deep. Written
//     with the user first, exactly one `nesting_too_deep`, at the second
//     use, with the hint; with the methods first, it checks (the stated
//     exception to order independence, §10.5).
test "a chain of own methods just past the nesting budget is one nesting_too_deep" {
    var s = try Scenario.init("nesting budget");
    defer s.deinit();
    try s.w.write("C.beni", try chains(s.arena(), 1, 650));
    const verdict = try s.exactlyOneHinted(&.{ "check", "--no-cache", "--diagnostics=json", "C.beni" }, .nesting_too_deep);
    try s.finish(verdict);
}

test "two deep demands in a row are refused once, and the other order checks" {
    var s = try Scenario.init("two deep demands");
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

// A derived `eq` worked out at the end of a chain that nearly spends the
// budget: `W (H.Holder K)`'s pass needs `H.eq`'s requirement `a.key` of
// `K`, whose own `key` is written below everything and is still unchecked,
// and checking it there is refused. The pass is no answer about `W`: one
// NESTING TOO DEEP at the `==`, never a NOT EQUATABLE saying `W` holds a
// function (the refusal inside the pass went to its quiet report, and the
// pass read on as if nothing had failed). The chain is 600 links, where the
// comparison's own demand is admitted and the pass's is not.
test "a derived eq whose pass is refused a nested check says so at the comparison" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = w.arena.allocator();
    try w.write("H.beni",
        \\pub type Holder a
        \\    = Holder a
        \\
        \\
        \\pub eq : Holder a, Holder a -> Bool
        \\    where a.key : a, () -> Int
        \\eq l r =
        \\    case ( l, r ) of
        \\        ( Holder x, Holder y ) ->
        \\            x.key () == y.key ()
        \\
    );
    const n = 600;
    var main: std.ArrayList(u8) = .empty;
    try main.appendSlice(a, "import H\n\n\ntype T\n    = T Int\n\n\ntype K\n    = K Int\n\n\ntype W\n    = W (H.Holder K)\n\n\n");
    for (0..n) |i| try main.print(a, "pub m{d} (T x) u =\n    (T x).m{d} ()\n\n\n", .{ i, i + 1 });
    try main.print(a, "pub m{d} (T x) u =\n    W (H.Holder (K x)) == W (H.Holder (K 1))\n\n\n", .{n});
    try main.appendSlice(a, "pub key (K v) u =\n    v\n");
    try w.write("Main.beni", main.items);

    const run = try w.runWith(&.{ "check", "--no-cache", "--diagnostics=json", "H.beni", "Main.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 1), run.exit_code);
    try testing.expectEqualStrings("", run.stdout);
    const diags = try std.json.parseFromSliceLeaky([]@import("diagnostic").Diagnostic, a, std.mem.trim(u8, run.stderr, " \r\n"), .{});
    // The comparison's line: 15 lines of header, 4 per link.
    const line = 15 + 4 * n + 2;
    try testing.expectEqualDeep(&[_]@import("diagnostic").Diagnostic{.{
        .code = .nesting_too_deep,
        .severity = .@"error",
        .span = .{ .file = "Main.beni", .start = .{ .line = line, .col = 24 }, .end = .{ .line = line, .col = 26 } },
        .title = "NESTING TOO DEEP",
        .message =
        \\I could not work out the derived `eq` of this type:
        \\
        \\    W
        \\
        \\Deriving it means checking what its parts need, and here that went deeper
        \\than I will follow: a declaration it reaches would have to be checked nested
        \\inside too many others, or the types its method calls are made on are too
        \\many or keep growing. This is a limit of mine, not a fact about the type.
        \\
        \\Hint: annotate the methods this comparison reaches, so I can use their
        \\annotations instead of checking their bodies here.
        \\
        ,
    }}, diags);
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

// ┌─────────────────────────────────────────────────────────────────────────┐
// │ HARNESS                                                                 │
// └─────────────────────────────────────────────────────────────────────────┘

/// A scenario's verdict, in `pending_test.zig`'s vocabulary: GREEN, or the
/// red signature and a detail naming the program and order that failed.
const Verdict = struct {
    green: bool,
    signature: []const u8,
    detail: []const u8,
};

/// `pending_test.zig`'s `Scenario`, cut to what these scenarios use.
const Scenario = struct {
    id: []const u8,
    w: World,
    arena_state: std.heap.ArenaAllocator,

    fn init(comptime id: []const u8) !Scenario {
        return .{
            .id = id,
            .w = try World.init(testing.allocator, testing.io),
            .arena_state = .init(testing.allocator),
        };
    }

    fn deinit(s: *Scenario) void {
        s.w.deinit();
        s.arena_state.deinit();
    }

    fn arena(s: *Scenario) std.mem.Allocator {
        return s.arena_state.allocator();
    }

    /// `args` as they are.
    fn argv(_: *Scenario, args: []const []const u8) ![]const []const u8 {
        return args;
    }

    /// One compiler run, timed; null when it was killed at `kill_ms` of WALL
    /// time.
    ///
    /// `ms` is the child's own CPU time, user + system (`world.Result.cpu_ms`,
    /// from `wait4`'s rusage), and the wall clock only where the platform
    /// reports none. Every verdict below compares `ms`: a concurrent build on
    /// the same machine stretches the wall clock of the two points by
    /// different amounts, and can turn a cubic 87 s / 162 s into a
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

    /// A verdict that is not GREEN fails the test, with its signature and
    /// detail.
    fn finish(s: *Scenario, v: Verdict) !void {
        if (v.green) return;
        std.debug.print("{s}: RED [{s}] {s}\n", .{ s.id, v.signature, v.detail });
        return error.ScenarioRed;
    }
};
