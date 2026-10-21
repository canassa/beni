//! The chat example (`examples/chat`, #524): a `node` server and a
//! `browser-tea` page, both beni, over one WebSocket per page
//! (`boundary.md` §9.11 (l), the page and the server together). The corpus
//! proves each side alone — the `run/WebSocket…` cases drive the server
//! with the serve driver's own RFC 6455 client, and the
//! `browser/tea/WebSocket…` pages run against a scripted socket — and
//! neither holds the other side. This file proves the part only the two
//! together can: the page's socket, Node's own `WebSocket` (undici), reaches
//! the server; what the page says, another client hears; what that client
//! says, the page shows; and the server refuses a socket from another site
//! and closes the rest with 1001 when it shuts down.
//!
//! Boundary 2: both programs are built exactly as the README says, from
//! their directories, and the server runs under `tests/serve/driver.mjs`,
//! which learns the port from the preload and starts the page under
//! `tests/browser/driver.mjs` with `--server` set to it, so no port reaches
//! the transcript. The order of the transcript is the script's: the page
//! waits for what its socket receives, and the serve driver waits for the
//! page's steps (`page-wait`), so no line depends on timing.

const std = @import("std");
const world = @import("world.zig");
const serve = @import("serve.zig");
const World = world.World;
const testing = std.testing;

// The page's script: it opens its socket as it loads, says a line, and
// waits for the answer of the driver's own client.
const steps =
    \\socket 1 wait open
    \\input #draft "hello"
    \\click #say
    \\socket 1 wait 1
    \\
;

// The driver's own client joins first, as guest1; the page is guest2.
const requests =
    \\{"socket": "a", "path": "/chat"}
    \\{"page": "../page/out/_main.mjs", "steps": "chat.steps", "wait": false}
    \\{"receive": "a"}
    \\{"receive": "a"}
    \\{"page-wait": "click #say"}
    \\{"send": "a", "text": "say hi, guest2"}
    \\{"page-end": true}
    \\{"receive": "a"}
    \\{"socket": "x", "path": "/chat", "headers": {"origin": "http://evil.example"}}
    \\{"method": "POST", "path": "/api/shutdown"}
    \\{"receive": "a"}
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
    // The driver's client hears the page join and speak, and then leave
    // when the page's script ends; the page shows its own line and the
    // client's answer (its transcript, `| …`, is printed when it ends); a
    // socket whose `origin` is another site's is refused with 403; the
    // shutdown closes the client's socket with 1001, and the server prints
    // its one line.
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
        \\< (socket a) "left guest2"
        \\> (socket x) GET /chat
        \\< (socket x) 403
        \\< (socket x) content-type: text/plain; charset=utf-8
        \\< (socket x) content-length: 18
        \\< (socket x) connection: close
        \\< (socket x)
        \\< (socket x) not from this site
        \\> POST /api/shutdown
        \\< 200
        \\< content-type: text/plain; charset=utf-8
        \\< connection: close
        \\< content-length: 8
        \\<
        \\< stopping
        \\< (socket a) close 1001 ""
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
}
