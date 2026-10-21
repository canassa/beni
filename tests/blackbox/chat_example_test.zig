//! The chat example (`examples/chat`, #524): a `node` server and a
//! `browser-tea` page, both beni, over one WebSocket per page
//! (`boundary.md` §9.11 (l), the page and the server together). The corpus
//! proves each side alone — the `run/WebSocket…` cases drive the server
//! with the serve driver's own RFC 6455 client, and the
//! `browser/tea/WebSocket…` pages run against a scripted socket — and
//! neither holds the other side. This file proves the part only the two
//! together can: the page's socket, happy-dom's own `WebSocket` (it wraps
//! the `ws` library), reaches the server; what the page says, another
//! client hears; what that client says, the page shows; the server serves
//! the page's build, refuses a socket from another site, and closes the
//! rest with 1001 when it shuts down; and the page then connects again,
//! and waits a second longer after each failure in a row.
//!
//! Boundary 2: both programs are built exactly as the README says, from
//! their directories, and the server runs under `tests/serve/driver.mjs`,
//! which learns the port from the preload and starts the page under
//! `tests/browser/driver.mjs` with `--server` set to it, so no port reaches
//! the transcript. The order of the transcript is the script's: what the
//! page's socket does reaches the page only in a `socket <n> wait` step,
//! and the serve driver waits for the page's steps (`page-wait`), so no
//! line depends on timing. The page runs with `--wait-handshakes`: after
//! each step the host has answered the handshake before the snapshot, so a
//! page driver that gave the page the open at once would show it after the
//! load, not after `socket 1 wait open`.

const std = @import("std");
const world = @import("world.zig");
const serve = @import("serve.zig");
const World = world.World;
const testing = std.testing;

// The page's script: it opens its socket as it loads, says a line, and
// waits for the answer of the driver's own client. When the server shuts
// down, the page waits 1 s and connects again; that fails, as the server is
// gone, and the page waits 2 s before the next attempt. The waits are on
// the page's virtual clock.
const steps =
    \\socket 1 wait open
    \\input #draft "hello"
    \\click #say
    \\socket 1 wait 1
    \\socket 1 wait closed
    \\advance 1000
    \\socket 2 wait closed
    \\advance 1000
    \\advance 1000
    \\
;

// The driver's own client joins first, as guest1; the page is guest2. The
// shutdown waits until the page has the client's answer.
const requests =
    \\{"socket": "a", "path": "/chat"}
    \\{"page": "../page/out/_main.mjs", "steps": "chat.steps", "wait": false, "wait-handshakes": true}
    \\{"receive": "a"}
    \\{"receive": "a"}
    \\{"page-wait": "click #say"}
    \\{"send": "a", "text": "say hi, guest2"}
    \\{"page-wait": "socket 1 wait 1"}
    \\{"socket": "x", "path": "/chat", "headers": {"origin": "http://evil.example"}}
    \\{"path": "/"}
    \\{"path": "/.env"}
    \\{"method": "POST", "path": "/api/shutdown"}
    \\{"receive": "a"}
    \\{"page-end": true}
    \\
;

// A page that does not do what the script waits for: it says two empty
// lines, then fails at a step whose element does not exist.
const failing_steps =
    \\socket 1 wait open
    \\click #say
    \\click #say
    \\click #missing
    \\
;

// A third wait for `click #say` waits for a third such step, and a wait
// for a step the page never runs stops when the page ends. The second
// `page-end` finds no page.
const failing_requests =
    \\{"page": "../page/out/_main.mjs", "steps": "failing.steps", "wait": false}
    \\{"page-wait": "click #say"}
    \\{"page-wait": "click #say"}
    \\{"page-wait": "click #say"}
    \\{"page-wait": "click #missing"}
    \\{"page-end": true}
    \\{"page-end": true}
    \\{"method": "POST", "path": "/api/shutdown"}
    \\
;

test "the chat page and the chat server talk over a real WebSocket" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The example as checked in, with one change the README names: a
    // `Config` that listens on port 0, so the operating system picks the
    // port and the transcript never holds it (rule 5).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    // The skip prefix matches nothing the example holds: every file is copied.
    try w.copyTree("examples/chat", "_expected.");
    try w.write("server/config/Config.beni",
        \\pub host : String
        \\host = "127.0.0.1"
        \\
        \\
        \\pub port : Int
        \\port = 0
        \\
        \\
        \\pub pageDir : String
        \\pageDir = "../page/out"
        \\
    );
    try w.write("server/chat.steps", steps);
    try w.write("server/chat.requests", requests);
    try w.write("server/failing.steps", failing_steps);
    try w.write("server/failing.requests", failing_requests);
    const arena = w.arena.allocator();
    const page_dir = try w.projectSubPath(arena, "page");
    const server_dir = try w.projectSubPath(arena, "server");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // `beni build` in each directory, with no arguments: the manifests say
    // the platform, the paths — `src` and the shared `../shared` — and the
    // output.
    const page = try w.runWith(&.{ "build", "--no-cache" }, .{ .cwd = .{ .path = page_dir }, .raw_diagnostics = true });
    if (page.exit_code != 0) std.debug.print("the page did not build\n--- stderr ---\n{s}\n", .{page.stderr});
    try testing.expectEqual(@as(u8, 0), page.exit_code);
    try testing.expectEqualStrings("", page.stderr);
    const server = try w.runWith(&.{ "build", "--no-cache" }, .{ .cwd = .{ .path = server_dir }, .raw_diagnostics = true });
    if (server.exit_code != 0) std.debug.print("the server did not build\n--- stderr ---\n{s}\n", .{server.stderr});
    try testing.expectEqual(@as(u8, 0), server.exit_code);
    try testing.expectEqualStrings("", server.stderr);

    const node = w.node_exe orelse return error.NodeNotOnPath;
    const harness = try serve.harness(testing.io);
    const ran = try world.spawnAndCapture(
        arena,
        testing.allocator,
        testing.io,
        &.{ node, harness.driver, "out/_main.mjs", "chat.requests" },
        .{ .path = server_dir },
        world.default_timeout_ms,
    );

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // The driver's client hears the page join and speak; the page shows
    // its own line and the client's answer (its transcript, `| …`, is
    // printed when it ends). A socket whose `origin` is another site's is
    // refused with 403. `/` is the page's shell, and a hidden file is 404.
    // The shutdown closes both sockets with 1001, and the server prints its
    // one line. The page shows "connecting" until `socket 1 wait open`,
    // although its open arrived before the load's snapshot. After the close
    // it connects again at 1 s, socket 2 fails at once, and socket 3 starts
    // only 2 s after that. The HTML ends in a newline, so its last line is
    // `< ` with a space: a string of its own, which no editor strips (with
    // the newline before it, which a multiline literal's last line lacks).
    const expected =
        \\> (socket a) GET /chat
        \\< (socket a) 101
        \\< (socket a) upgrade: websocket
        \\< (socket a) connection: Upgrade
        \\< (socket a) sec-websocket-accept: (the right key)
        \\> (page) ../page/out/_main.mjs chat.steps (not waited for)
        \\< (socket a) "joined guest2"
        \\< (socket a) "said guest2 hello"
        \\> (socket a) "say hi, guest2"
        \\> (socket x) GET /chat
        \\< (socket x) 403
        \\< (socket x) content-type: text/plain; charset=utf-8
        \\< (socket x) content-length: 18
        \\< (socket x) connection: close
        \\< (socket x)
        \\< (socket x) not from this site
        \\> GET /
        \\< 200
        \\< content-type: text/html; charset=utf-8
        \\< content-length: 253
        \\< connection: keep-alive
        \\< keep-alive: timeout=5
        \\<
        \\< <!doctype html>
        \\< <html lang="en">
        \\<   <head>
        \\<     <meta charset="utf-8">
        \\<     <meta name="viewport" content="width=device-width, initial-scale=1">
        \\<     <title>chat</title>
        \\<     <script type="module" src="/_main.mjs"></script>
        \\<   </head>
        \\<   <body></body>
        \\< </html>
    ++ "\n< \n" ++
        \\> GET /.env
        \\< 404
        \\< content-type: text/plain; charset=utf-8
        \\< content-length: 12
        \\< connection: keep-alive
        \\< keep-alive: timeout=5
        \\<
        \\< no such file
        \\> POST /api/shutdown
        \\< 200
        \\< content-type: text/plain; charset=utf-8
        \\< connection: close
        \\< content-length: 8
        \\<
        \\< stopping
        \\< (socket a) close 1001 ""
        \\| -- load
        \\| (socket 1: /chat)
        \\| <body>
        \\|   <main>
        \\|     <p id="status">"connecting"</p>
        \\|     <ol id="lines"></ol>
        \\|     <input id="draft" .value="">
        \\|     <button id="say">"say"</button>
        \\|   </main>
        \\| </body>
        \\| -- socket 1 wait open
        \\| <body>
        \\|   <main>
        \\|     <p id="status">"connected"</p>
        \\|     <ol id="lines"></ol>
        \\|     <input id="draft" .value="">
        \\|     <button id="say">"say"</button>
        \\|   </main>
        \\| </body>
        \\| -- input #draft "hello"
        \\| <body>
        \\|   <main>
        \\|     <p id="status">"connected"</p>
        \\|     <ol id="lines"></ol>
        \\|     <input id="draft" .value="hello">
        \\|     <button id="say">"say"</button>
        \\|   </main>
        \\| </body>
        \\| -- click #say
        \\| (socket 1 sent: "say hello")
        \\| <body>
        \\|   <main>
        \\|     <p id="status">"connected"</p>
        \\|     <ol id="lines">
        \\|       <li>"you: hello"</li>
        \\|     </ol>
        \\|     <input id="draft" .value="">
        \\|     <button id="say">"say"</button>
        \\|   </main>
        \\| </body>
        \\| -- socket 1 wait 1
        \\| <body>
        \\|   <main>
        \\|     <p id="status">"connected"</p>
        \\|     <ol id="lines">
        \\|       <li>"you: hello"</li>
        \\|       <li>"guest1: hi, guest2"</li>
        \\|     </ol>
        \\|     <input id="draft" .value="">
        \\|     <button id="say">"say"</button>
        \\|   </main>
        \\| </body>
        \\| -- socket 1 wait closed
        \\| <body>
        \\|   <main>
        \\|     <p id="status">"offline"</p>
        \\|     <ol id="lines">
        \\|       <li>"you: hello"</li>
        \\|       <li>"guest1: hi, guest2"</li>
        \\|       <li>"closed (1001)"</li>
        \\|     </ol>
        \\|     <input id="draft" .value="">
        \\|     <button id="say">"say"</button>
        \\|   </main>
        \\| </body>
        \\| -- advance 1000
        \\| (socket 2: /chat)
        \\| <body>
        \\|   <main>
        \\|     <p id="status">"connecting"</p>
        \\|     <ol id="lines">
        \\|       <li>"you: hello"</li>
        \\|       <li>"guest1: hi, guest2"</li>
        \\|       <li>"closed (1001)"</li>
        \\|     </ol>
        \\|     <input id="draft" .value="">
        \\|     <button id="say">"say"</button>
        \\|   </main>
        \\| </body>
        \\| -- socket 2 wait closed
        \\| <body>
        \\|   <main>
        \\|     <p id="status">"offline"</p>
        \\|     <ol id="lines">
        \\|       <li>"you: hello"</li>
        \\|       <li>"guest1: hi, guest2"</li>
        \\|       <li>"closed (1001)"</li>
        \\|       <li>"cannot connect"</li>
        \\|     </ol>
        \\|     <input id="draft" .value="">
        \\|     <button id="say">"say"</button>
        \\|   </main>
        \\| </body>
        \\| -- advance 1000
        \\| (the DOM did not change)
        \\| -- advance 1000
        \\| (socket 3: /chat)
        \\| <body>
        \\|   <main>
        \\|     <p id="status">"connecting"</p>
        \\|     <ol id="lines">
        \\|       <li>"you: hello"</li>
        \\|       <li>"guest1: hi, guest2"</li>
        \\|       <li>"closed (1001)"</li>
        \\|       <li>"cannot connect"</li>
        \\|     </ol>
        \\|     <input id="draft" .value="">
        \\|     <button id="say">"say"</button>
        \\|   </main>
        \\| </body>
        \\--- stdout ---
        \\chat server stopped
        \\--- stderr ---
        \\--- exit 0 ---
        \\
    ;
    if (!std.mem.eql(u8, expected, ran.stdout)) {
        std.debug.print("the served transcript differs\n--- got ---\n{s}\n--- stderr ---\n{s}\n", .{ ran.stdout, ran.stderr });
    }
    try testing.expectEqualStrings(expected, ran.stdout);
    try testing.expectEqual(@as(u8, 0), ran.exit_code);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE: a page that fails              │
    // └─────────────────────────────────────────┘
    // The serve driver's page steps when the page does not do what the
    // script waits for, against the same two builds.
    const failed = try world.spawnAndCapture(
        arena,
        testing.allocator,
        testing.io,
        &.{ node, harness.driver, "out/_main.mjs", "failing.requests" },
        .{ .path = server_dir },
        world.default_timeout_ms,
    );

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // The first two waits for `click #say` find the page's two such steps.
    // The third finds none, and stops when the page ends: a wait uses the
    // lines up to the one it found. The wait for `click #missing` stops
    // too, since the page failed at that step. The first `page-end` prints
    // the page and its failure; the second finds no page and says so. Then
    // the driver ends, as after any script.
    const failed_expected =
        \\> (page) ../page/out/_main.mjs failing.steps (not waited for)
        \\| (the page ended before it reached "click #say")
        \\| (the page ended before it reached "click #missing")
        \\| -- load
        \\| (socket 1: /chat)
        \\| <body>
        \\|   <main>
        \\|     <p id="status">"connecting"</p>
        \\|     <ol id="lines"></ol>
        \\|     <input id="draft" .value="">
        \\|     <button id="say">"say"</button>
        \\|   </main>
        \\| </body>
        \\| -- socket 1 wait open
        \\| <body>
        \\|   <main>
        \\|     <p id="status">"connected"</p>
        \\|     <ol id="lines"></ol>
        \\|     <input id="draft" .value="">
        \\|     <button id="say">"say"</button>
        \\|   </main>
        \\| </body>
        \\| -- click #say
        \\| (socket 1 sent: "say ")
        \\| <body>
        \\|   <main>
        \\|     <p id="status">"connected"</p>
        \\|     <ol id="lines">
        \\|       <li>"you: "</li>
        \\|     </ol>
        \\|     <input id="draft" .value="">
        \\|     <button id="say">"say"</button>
        \\|   </main>
        \\| </body>
        \\| -- click #say
        \\| (socket 1 sent: "say ")
        \\| <body>
        \\|   <main>
        \\|     <p id="status">"connected"</p>
        \\|     <ol id="lines">
        \\|       <li>"you: "</li>
        \\|       <li>"you: "</li>
        \\|     </ol>
        \\|     <input id="draft" .value="">
        \\|     <button id="say">"say"</button>
        \\|   </main>
        \\| </body>
        \\| -- click #missing
        \\| (the page driver exited 1: failing.steps:4: click #missing: no element matches `#missing`)
        \\| (no page runs: a `page` step with `"wait": false` starts one)
        \\> POST /api/shutdown
        \\< 200
        \\< content-type: text/plain; charset=utf-8
        \\< connection: close
        \\< content-length: 8
        \\<
        \\< stopping
        \\--- stdout ---
        \\chat server stopped
        \\--- stderr ---
        \\--- exit 0 ---
        \\
    ;
    if (!std.mem.eql(u8, failed_expected, failed.stdout)) {
        std.debug.print("the failing page's transcript differs\n--- got ---\n{s}\n--- stderr ---\n{s}\n", .{ failed.stdout, failed.stderr });
    }
    try testing.expectEqualStrings(failed_expected, failed.stdout);
    try testing.expectEqual(@as(u8, 0), failed.exit_code);
}
