//! The page fuzzer (`tests/browser/fuzz.mjs`, docs/design/browser-direct.md
//! §8.3, amended 2026-10-09) proved on a program of its own: the message
//! types it reads from the checker (`beni dump --stage=writes
//! --msg-types`), two clean builds that agree, and a build with one hole's
//! write broken, which it must catch — a fuzzer that never fails proves
//! nothing. The corpus walker runs the same fuzzer on every `browser/tea/`
//! and `browser/direct/` page (`corpus_test.zig`, `fuzzPair`).
//!
//! The broken build is a copy of a development build with the write of
//! the count's hole guarded by `count >= 0`: a missed write, the stale page
//! the fuzzer exists to find. No view event of the program makes the count
//! negative, so only a message drawn from the message type reaches it — a
//! payload no button of the page sends.
//!
//! Each fuzz run is recorded in `tests/blackbox/run-hashes.txt` like a
//! scenario's program run (`run_hash.checkDigested`): Node runs only when
//! the builds, the harness or the expectation changed.

const std = @import("std");
const testing = std.testing;
const world = @import("world.zig");
const World = world.World;
const browser = @import("browser.zig");
const run_hash = @import("run_hash.zig");

/// Every constructor of `Msg` is built by a button, so `update` keeps every
/// arm (backend.md §9, *A `case` arm on a constructor nothing builds*); a
/// message no code builds would reach no arm of its own.
const program =
    \\import Html exposing (Html)
    \\import Tea
    \\
    \\
    \\type Color
    \\    = Red
    \\    | Green
    \\
    \\
    \\type Msg
    \\    = Inc
    \\    | Add Int
    \\    | Name String
    \\    | Paint Color
    \\    | Set { count : Int, flag : Bool }
    \\    | Many (List Int)
    \\    | Pair (Int × String)
    \\    | Pick (Maybe Color)
    \\
    \\
    \\type alias Model =
    \\    color : Color
    \\    flag : Bool
    \\    n : Int
    \\    name : String
    \\
    \\
    \\update : Msg, Model → Model
    \\update msg m =
    \\    case msg of
    \\        Inc →
    \\            { m | n = m.n + 1 }
    \\
    \\        Add k →
    \\            { m | n = m.n + k }
    \\
    \\        Name s →
    \\            { m | name = s }
    \\
    \\        Paint c →
    \\            { m | color = c }
    \\
    \\        Set r →
    \\            { m | flag = r.flag, n = r.count }
    \\
    \\        Many xs →
    \\            { m | n = List.length xs }
    \\
    \\        Pair ( k, s ) →
    \\            { m | n = k, name = s }
    \\
    \\        Pick (Just c) →
    \\            { m | color = c }
    \\
    \\        Pick Nothing →
    \\            m
    \\
    \\
    \\view : Model → Html Msg
    \\view m =
    \\    <main>
    \\        <p id="n">{m.n}</p>
    \\        <p id="name">{m.name}</p>
    \\        <p id="color">{if m.color == Red then "red" else "green"}</p>
    \\        <p id="flag">{if m.flag then "on" else "off"}</p>
    \\        <button onClick={Inc}>inc</button>
    \\        <button onClick={Add 2}>add</button>
    \\        <button onClick={Name "x"}>name</button>
    \\        <button onClick={Paint Green}>paint</button>
    \\        <button onClick={Set { count = 7, flag = True }}>set</button>
    \\        <button onClick={Many [ 1, 2 ]}>many</button>
    \\        <button onClick={Pair ( 3, "p" )}>pair</button>
    \\        <button onClick={Pick (Just Red)}>pick</button>
    \\    </main>
    \\
    \\
    \\main : Tea.Program
    \\main =
    \\    Tea.sandbox
    \\        { init = { color = Red, flag = False, n = 0, name = "" }, update = update, view = view }
    \\
;

/// `program`'s message type, as the dump writes it.
const program_types =
    \\{"program":"Main.main","index":null,"kind":"Tea.sandbox","msg":[["n",0],[{"Inc":[],"Add":["i"],"Name":["s"],"Paint":[["n",1]],"Set":[{"count":"i","flag":"b"}],"Many":[["l","i"]],"Pair":[["t","i","s"]],"Pick":[["n",2,["n",1]]]},{"Red":[],"Green":[]},{"Just":[0],"Nothing":[]}]]}
    \\
;

/// Write `program`, build it twice for `browser-tea` in development, into
/// `a/` and `b/`, and dump its message types into `types.jsonl`.
fn setUp(w: *World) !void {
    try w.write("Main.beni", program);
    for ([_][]const u8{ "--out=a", "--out=b" }) |out| {
        const built = try w.runWith(&.{ "build", "--platform=browser-tea", out, "Main.beni" }, .{ .raw_diagnostics = true });
        if (built.exit_code != 0 or built.stderr.len != 0) {
            std.debug.print("beni build {s} exited {d}\n{s}\n", .{ out, built.exit_code, built.stderr });
            return error.BuildFailed;
        }
    }
    const dumped = try w.runWith(&.{ "dump", "--stage=writes", "--msg-types", "--platform=browser-tea", "Main.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), dumped.exit_code);
    try w.write("types.jsonl", dumped.stdout);
}

/// Break `b/`: the count's hole — the first text hole the patch function
/// writes, `<p id="n">` — is written only when the count is not negative.
fn breakCountHole(w: *World) !void {
    const arena = w.arena.allocator();
    const js = try w.read("b/Main.mjs");
    // `    i$1.w2.data = x$4;`: the first `.data = ` line is the first hole's.
    const at = std.mem.indexOf(u8, js, ".data = ") orelse return error.NoHoleWrite;
    const start = (std.mem.lastIndexOfScalar(u8, js[0..at], '\n') orelse return error.NoHoleWrite) + 1;
    const end = std.mem.indexOfScalarPos(u8, js, at, '\n') orelse return error.NoHoleWrite;
    const line = js[start..end];
    const write = std.mem.trimStart(u8, line, " ");
    const value = std.mem.trimEnd(u8, write[std.mem.indexOf(u8, write, "= ").? + 2 ..], ";");
    const guarded = try std.fmt.allocPrint(arena, "{s}if ({s} >= 0) {s}", .{ line[0 .. line.len - write.len], value, write });
    try w.write("b/Main.mjs", try std.mem.concat(arena, u8, &.{ js[0..start], guarded, js[end..] }));
}

/// The fuzz of `f`, expected to end with `code` and print `stdout`, unless
/// the index lists this exact run (`run_hash.checkDigested`).
fn expectFuzz(w: *World, f: browser.Fuzz, code: u8, stdout: []const u8) !void {
    const arena = w.arena.allocator();
    const h = try browser.harness(testing.io);
    const line = try browser.fuzzLine(arena, w, h, f);
    const digest = try run_hash.digestOf(arena, &.{ line, &.{code}, stdout });
    const Run = struct {
        w: *World,
        h: browser.Harness,
        f: browser.Fuzz,
        code: u8,
        stdout: []const u8,
        fn go(r: @This()) anyerror!bool {
            const got = try browser.fuzz(r.w, r.h, null, r.f, world.default_timeout_ms);
            if (got.exit_code == r.code and std.mem.eql(u8, got.stdout, r.stdout)) return true;
            std.debug.print("the fuzz did not do what the test expects\n--- stdout ---\n{s}--- stderr ---\n{s}--- code {d} ---\n", .{ got.stdout, got.stderr, got.exit_code });
            try testing.expectEqualStrings(r.stdout, got.stdout);
            try testing.expectEqual(r.code, got.exit_code);
            return false;
        }
    };
    if (try run_hash.checkDigested(w, digest, Run{ .w = w, .h = h, .f = f, .code = code, .stdout = stdout }, Run.go)) |ok| {
        if (!ok) return error.FuzzMismatch;
    }
}

test "the message type the fuzzer draws from is the checker's: every constructor and its payload's types" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", program);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "dump", "--stage=writes", "--msg-types", "--platform=browser-tea", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // A record's fields by name, a tuple, a list, a `Maybe` of another of
    // the program's types: `Debug.toString`'s descriptor of the type.
    try testing.expectEqualStrings(program_types, r.stdout);
    try testing.expectEqualStrings("", r.stderr);
    try testing.expectEqual(@as(u8, 0), r.exit_code);
}

test "a lambda's update has its parameter's type, and each of several programs its own" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Browser
        \\import Html exposing (Html)
        \\import Tea
        \\
        \\
        \\type Shape
        \\    = Dot
        \\    | Box Int Int
        \\
        \\
        \\counter : Int → Html Int
        \\counter n = <button onClick={1}>{n}</button>
        \\
        \\
        \\shapes : List Shape → Html Shape
        \\shapes all = <p onClick={Box 1 2}>{List.length all}</p>
        \\
        \\
        \\main : Tea.Program
        \\main =
        \\    Browser.programs
        \\        [ Tea.sandbox { init = 0, update = λstep n → n + step, view = counter }
        \\        , Browser.mountAt
        \\            (Tea.sandbox { init = [], update = λs all → [ s, …all ], view = shapes })
        \\            "shapes"
        \\        ]
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "dump", "--stage=writes", "--msg-types", "--platform=browser-tea", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // In the order `Browser.programs` mounts them, which is the order the
    // fuzzer numbers the mounts it sends messages to.
    try testing.expectEqualStrings(
        \\{"program":"Main.main","index":0,"kind":"Tea.sandbox","msg":["i",[]]}
        \\{"program":"Main.main","index":1,"kind":"Tea.sandbox","msg":[["n",0],[{"Dot":[],"Box":["i","i"]}]]}
        \\
    , r.stdout);
    try testing.expectEqual(@as(u8, 0), r.exit_code);
}

test "two development builds of one program agree on every seed, messages and events alike" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try setUp(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY OUTPUT                 │
    // └─────────────────────────────────────────┘
    try expectFuzz(&w, .{ .a = "a", .b = "b", .label_a = "development", .label_b = "again", .types = "types.jsonl" }, 0,
        \\seed 1: 15 steps agree (7 view events, 4 messages, 4 host steps)
        \\seed 2: 15 steps agree (9 view events, 5 messages, 1 host step)
        \\
    );
}

test "a build that misses one hole's write is caught, at the message that shows it, and shrunk to it" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try setUp(&w);
    try breakCountHole(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY OUTPUT                 │
    // └─────────────────────────────────────────┘
    // The seed, the step and its message; the sequence shrunk to the one
    // message that shows the stale count; the element where the pages
    // differ.
    try expectFuzz(&w, .{ .a = "a", .b = "b", .label_a = "development", .label_b = "broken", .types = "types.jsonl" }, 1,
        \\seed 1: 15 steps agree (7 view events, 4 messages, 4 host steps)
        \\development and broken differ: seed 2, step 4 of 15, message Add -100
        \\shrunk from 4 steps to 1:
        \\  message Add -100
        \\(a `message` line is a value sent to the program; the others are `.steps` lines)
        \\after message Add -100:
        \\--- development ---
        \\    <p id="n">"-100"</p>
        \\--- broken ---
        \\    <p id="n">"0"</p>
        \\
    );
}

test "view events alone never reach the broken hole: no button makes the count negative" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try setUp(&w);
    try breakCountHole(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY OUTPUT                 │
    // └─────────────────────────────────────────┘
    // Why messages are drawn from the type: the same seeds with no message
    // as a value agree on the broken build.
    try expectFuzz(&w, .{ .a = "a", .b = "b", .label_a = "development", .label_b = "broken" }, 0,
        \\seed 1: 15 steps agree (13 view events, 0 messages, 2 host steps)
        \\seed 2: 15 steps agree (13 view events, 0 messages, 2 host steps)
        \\
    );
}
