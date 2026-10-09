//! The page fuzzer (`tests/browser/fuzz.mjs`, docs/design/browser-direct.md
//! §8.3, amended 2026-10-09) proved on a program of its own: the message
//! types it reads from the checker (`beni dump --stage=writes
//! --msg-types`), two clean builds that agree, and builds with one write
//! broken, each of which it must catch — a fuzzer that never fails proves
//! nothing. The corpus walker runs the same fuzzer on every `browser/tea/`
//! and `browser/direct/` page (`corpus_test.zig`, `fuzzPair`).
//!
//! A broken build is a copy of a development build with one write
//! skipped, the stale page the fuzzer exists to find: a text hole's when
//! the count is negative — which no view event of `program` makes, so
//! only a message drawn from the message type reaches it — and, in
//! `document`, every write after the first of an attribute hole, a
//! controlled input's `.value`, a keyed list, and the page's title.
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

/// A document program whose every message writes one other kind of
/// thing: a controlled input's value, the title, an attribute, a keyed
/// list. Every constructor is built by a button or a row.
const document =
    \\import Cmd exposing (Cmd)
    \\import Html exposing (Html)
    \\import Sub
    \\import Tea
    \\
    \\
    \\type Msg
    \\    = Typed String
    \\    | Retitle String
    \\    | Mark Bool
    \\    | Push Int
    \\    | Remove Int
    \\
    \\
    \\type alias Model =
    \\    marked : Bool
    \\    rows : List Int
    \\    text : String
    \\    title : String
    \\
    \\
    \\update : Msg, Model → Model × Cmd Msg
    \\update msg m =
    \\    case msg of
    \\        Typed s →
    \\            ( { m | text = s }, Cmd.none )
    \\
    \\        Retitle s →
    \\            ( { m | title = s }, Cmd.none )
    \\
    \\        Mark b →
    \\            ( { m | marked = b }, Cmd.none )
    \\
    \\        Push k →
    \\            ( { m | rows = [ …m.rows, k ] }, Cmd.none )
    \\
    \\        Remove k →
    \\            ( { m | rows = List.filter m.rows λr → r ≠ k }, Cmd.none )
    \\
    \\
    \\view : Model → Tea.Document Msg
    \\view m =
    \\    { title = m.title
    \\    , body =
    \\        <main>
    \\            <input id="text" value={m.text} onInput={Typed} />
    \\            <p id="mark" class={if m.marked then "on" else "off"}>mark</p>
    \\            <ul>
    \\                <For each={m.rows} keyed={String.fromInt}>
    \\                    {λr → <li onClick={Remove r}>{r}</li>}
    \\                </For>
    \\            </ul>
    \\            <button onClick={Retitle "x"}>retitle</button>
    \\            <button onClick={Mark True}>mark</button>
    \\            <button onClick={Push 1}>push</button>
    \\        </main>
    \\    }
    \\
    \\
    \\main : Tea.Program
    \\main =
    \\    Tea.document
    \\        { init = ( { marked = False, rows = [ 1, 2, 3 ], text = "", title = "start" }, Cmd.none )
    \\        , update = update
    \\        , view = view
    \\        , subscriptions = λ_ → Sub.none
    \\        }
    \\
;

/// Write `source`, build it twice for `browser-tea` in development, into
/// `a/` and `b/`, and dump its message types into `types.jsonl`.
fn setUp(w: *World, source: []const u8) !void {
    try w.write("Main.beni", source);
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

/// Break `b/`'s file `path`: the statement on the first line holding
/// `needle` runs once, at mount, and never again — every later write it
/// would make is missed.
fn breakAfterMount(w: *World, path: []const u8, needle: []const u8) !void {
    const arena = w.arena.allocator();
    const js = try w.read(path);
    const at = std.mem.indexOf(u8, js, needle) orelse {
        std.debug.print("{s} holds no `{s}`: the emitted write this test breaks moved\n", .{ path, needle });
        return error.NoWriteToBreak;
    };
    const start = (std.mem.lastIndexOfScalar(u8, js[0..at], '\n') orelse 0) + 1;
    const end = std.mem.indexOfScalarPos(u8, js, at, '\n') orelse js.len;
    const line = js[start..end];
    const statement = std.mem.trimStart(u8, line, " ");
    try w.write(path, try std.mem.concat(arena, u8, &.{
        "let broken$ = false;\n",
        js[0..start],
        line[0 .. line.len - statement.len],
        "if (!broken$) { broken$ = true; ",
        statement,
        " }",
        js[end..],
    }));
}

/// The fuzz of `f`, expected to end with `code` and print `stdout`, unless
/// the index lists this exact run (`run_hash.checkDigested`).
fn expectFuzz(w: *World, given: browser.Fuzz, code: u8, stdout: []const u8) !void {
    const arena = w.arena.allocator();
    // Two seeds of fifteen steps, whatever the gates' corpus fuzz runs.
    var f = given;
    f.seeds = "1,2";
    f.steps = 15;
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
    // A verdict that may be recorded proves the page replays itself.
    var replayed = f;
    replayed.replay = true;
    if (try run_hash.checkDigested(w, digest, Run{ .w = w, .h = h, .f = replayed, .code = code, .stdout = stdout }, Run.go)) |ok| {
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
    try setUp(&w, program);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY OUTPUT                 │
    // └─────────────────────────────────────────┘
    // Every constructor can be made, and the first eight messages of a
    // sequence send each in turn.
    try expectFuzz(&w, .{ .a = "a", .b = "b", .label_a = "development", .label_b = "again", .types = "types.jsonl" }, 0,
        \\the program: 8 constructors sent
        \\seed 1: 15 steps agree (4 view events, 8 messages, 3 host steps)
        \\seed 2: 15 steps agree (9 view events, 6 messages, 0 host steps)
        \\
    );
}

test "a build that misses one hole's write is caught, at the message that shows it, and shrunk to it" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try setUp(&w, program);
    try breakCountHole(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY OUTPUT                 │
    // └─────────────────────────────────────────┘
    // The seed, the step and its message; the sequence shrunk to the one
    // message that shows the stale count; the element where the pages
    // differ.
    try expectFuzz(&w, .{ .a = "a", .b = "b", .label_a = "development", .label_b = "broken", .types = "types.jsonl" }, 1,
        \\the program: 8 constructors sent
        \\seed 1: 15 steps agree (4 view events, 8 messages, 3 host steps)
        \\development and broken differ: seed 2, step 11 of 15, message Set { count = -3, flag = False }
        \\shrunk from 11 steps to 1:
        \\  message Set { count = -3, flag = False }
        \\(a `message` line is a value sent to the program; the others are `.steps` lines)
        \\after message Set { count = -3, flag = False }, the body differs:
        \\--- development ---
        \\    <p id="n">"-3"</p>
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
    try setUp(&w, program);
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

test "a missed attribute write is caught at the message that changes the attribute" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try setUp(&w, document);
    try breakAfterMount(&w, "b/Main.mjs", "setAttribute(\"class\"");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY OUTPUT                 │
    // └─────────────────────────────────────────┘
    try expectFuzz(&w, .{ .a = "a", .b = "b", .label_a = "development", .label_b = "broken", .types = "types.jsonl" }, 1,
        \\the program: 5 constructors sent
        \\development and broken differ: seed 1, step 6 of 15, message Mark True
        \\shrunk from 6 steps to 1:
        \\  message Mark True
        \\(a `message` line is a value sent to the program; the others are `.steps` lines)
        \\after message Mark True, the body differs:
        \\--- development ---
        \\    <p id="mark" class="on">"mark"</p>
        \\--- broken ---
        \\    <p id="mark" class="off">"mark"</p>
        \\
    );
}

test "a missed write of a controlled input's value is caught" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try setUp(&w, document);
    try breakAfterMount(&w, "b/Main.mjs", "Rt$control(");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY OUTPUT                 │
    // └─────────────────────────────────────────┘
    // `.value` is the control's live value, not its attribute.
    try expectFuzz(&w, .{ .a = "a", .b = "b", .label_a = "development", .label_b = "broken", .types = "types.jsonl" }, 1,
        \\the program: 5 constructors sent
        \\development and broken differ: seed 1, step 4 of 15, message Typed "1"
        \\shrunk from 4 steps to 1:
        \\  message Typed "1"
        \\(a `message` line is a value sent to the program; the others are `.steps` lines)
        \\after message Typed "1", the body differs:
        \\--- development ---
        \\    <input id="text" .value="1">
        \\--- broken ---
        \\    <input id="text" .value="">
        \\
    );
}

test "a keyed list that misses a change is caught, its element the list" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try setUp(&w, document);
    try breakAfterMount(&w, "b/Main.mjs", "Rt$forKeyed(");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY OUTPUT                 │
    // └─────────────────────────────────────────┘
    try expectFuzz(&w, .{ .a = "a", .b = "b", .label_a = "development", .label_b = "broken", .types = "types.jsonl" }, 1,
        \\the program: 5 constructors sent
        \\development and broken differ: seed 1, step 7 of 15, message Push 1
        \\shrunk from 7 steps to 1:
        \\  message Push 1
        \\(a `message` line is a value sent to the program; the others are `.steps` lines)
        \\after message Push 1, the body differs:
        \\--- development ---
        \\    <ul>
        \\      <li>"1"</li>
        \\      <li>"2"</li>
        \\      <li>"3"</li>
        \\      <li>"1"</li>
        \\    </ul>
        \\--- broken ---
        \\    <ul>
        \\      <li>"1"</li>
        \\      <li>"2"</li>
        \\      <li>"3"</li>
        \\    </ul>
        \\
    );
}

test "a missed title write is caught though the body is the same" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try setUp(&w, document);
    // The title is written by the platform (`Hosted.title`), not the program.
    try breakAfterMount(&w, "b/_platform/_browser/Hosted.mjs", ".title = ");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY OUTPUT                 │
    // └─────────────────────────────────────────┘
    try expectFuzz(&w, .{ .a = "a", .b = "b", .label_a = "development", .label_b = "broken", .types = "types.jsonl" }, 1,
        \\the program: 5 constructors sent
        \\development and broken differ: seed 1, step 5 of 15, message Retitle "ab"
        \\shrunk from 5 steps to 1:
        \\  message Retitle "ab"
        \\(a `message` line is a value sent to the program; the others are `.steps` lines)
        \\after message Retitle "ab", document.title differs:
        \\--- development ---
        \\ab
        \\--- broken ---
        \\start
        \\
    );
}
