//! The todo example (`examples/todo`, issue #356): a `node` server and a
//! `browser-tea` page, both beni, over one shared module. The corpus proves
//! each program alone — `run/TodoServer` drives the API, and
//! `browser/tea/TodoPage` drives the page against scripted answers —
//! and neither case holds the page's build. This file proves the part only
//! the two together can: the server built from the example's own manifest
//! serves the page `beni build` wrote, with the `content-type` of each
//! file, and refuses what is not a file of the page.
//!
//! Boundary 2: both programs are built exactly as the README says, from
//! their directories, and the server runs under `tests/serve/driver.mjs`,
//! which learns the port from the preload so none reaches the transcript
//! (`boundary.md` §9.10 (h)). The requests are `HEAD`s where a body is the
//! page's own text — the shell and the emitted entry file are the browser
//! platform's shape, pinned elsewhere — and `GET`s where the body is the
//! server's.

const std = @import("std");
const world = @import("world.zig");
const serve = @import("serve.zig");
const World = world.World;
const testing = std.testing;

const requests =
    \\{"method": "HEAD", "path": "/"}
    \\{"method": "HEAD", "path": "/index.html"}
    \\{"method": "HEAD", "path": "/_main.mjs"}
    \\{"method": "HEAD", "path": "/Main.mjs.map"}
    \\{"method": "GET", "path": "/missing.mjs"}
    \\{"method": "GET", "path": "/_core"}
    \\{"method": "GET", "path": "/api/todos"}
    \\{"method": "POST", "path": "/api/shutdown"}
    \\
;

test "the todo server serves the page its sibling build wrote" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The example as checked in, with one change the README names: a
    // `Config` that listens on port 0, so the operating system picks the
    // port and the transcript never holds it (rule 5).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    // The skip prefix matches nothing the example holds: every file is copied.
    try w.copyTree("examples/todo", "_expected.");
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
    try w.write("server/serve.requests", requests);
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
        &.{ node, harness.driver, "out/_main.mjs", "serve.requests" },
        .{ .path = server_dir },
        world.default_timeout_ms,
    );

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // The shell and the entry file answer with their types and no body
    // (`HEAD`); the source map is JSON; a file the build did not write is
    // 404 with the server's own text, and so is a directory of the build;
    // the API answers; the shutdown route ends the program, which prints
    // its one line. The `content-length` lines are left out of the
    // comparison: they are the sizes of the shell and of the browser
    // platform's entry file, shapes pinned elsewhere.
    const expected =
        \\> HEAD /
        \\< 200
        \\< content-type: text/html; charset=utf-8
        \\< connection: keep-alive
        \\< keep-alive: timeout=5
        \\> HEAD /index.html
        \\< 200
        \\< content-type: text/html; charset=utf-8
        \\< connection: keep-alive
        \\< keep-alive: timeout=5
        \\> HEAD /_main.mjs
        \\< 200
        \\< content-type: text/javascript; charset=utf-8
        \\< connection: keep-alive
        \\< keep-alive: timeout=5
        \\> HEAD /Main.mjs.map
        \\< 200
        \\< content-type: application/json; charset=utf-8
        \\< connection: keep-alive
        \\< keep-alive: timeout=5
        \\> GET /missing.mjs
        \\< 404
        \\< content-type: text/plain; charset=utf-8
        \\< connection: keep-alive
        \\< keep-alive: timeout=5
        \\<
        \\< no such file: build the page first (see the README)
        \\> GET /_core
        \\< 404
        \\< content-type: text/plain; charset=utf-8
        \\< connection: keep-alive
        \\< keep-alive: timeout=5
        \\<
        \\< no such file
        \\> GET /api/todos
        \\< 200
        \\< content-type: application/json; charset=utf-8
        \\< connection: keep-alive
        \\< keep-alive: timeout=5
        \\<
        \\< []
        \\> POST /api/shutdown
        \\< 200
        \\< content-type: text/plain; charset=utf-8
        \\< connection: close
        \\<
        \\< stopping
        \\--- stdout ---
        \\todo server stopped
        \\--- stderr ---
        \\--- exit 0 ---
        \\
    ;
    const got = try withoutLengths(arena, ran.stdout);
    if (!std.mem.eql(u8, expected, got)) {
        std.debug.print("the served transcript differs\n--- got ---\n{s}\n--- stderr ---\n{s}\n", .{ ran.stdout, ran.stderr });
    }
    try testing.expectEqualStrings(expected, got);
    try testing.expectEqual(@as(u8, 0), ran.exit_code);
}

/// `text` without its `< content-length: …` lines.
fn withoutLengths(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "< content-length: ")) continue;
        if (!first) try out.append(arena, '\n');
        first = false;
        try out.appendSlice(arena, line);
    }
    return out.items;
}
