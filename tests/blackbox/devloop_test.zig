//! The developer loop end to end (docs/design/frontend.md §10, backend.md
//! §2 *The page shell*): the page a browser build writes, a project's
//! `"build"` defaults, `beni new`, `beni build --watch` and `beni serve`.
//!
//! The last two never exit on their own, so they are driven as live
//! processes: started, read line by line from stdout until the status line
//! a scenario waits for, edited under, asked over HTTP, and stopped with
//! SIGINT — which is itself an assertion, since the contract is exit 0.
//! Every wait has a deadline, and a process is killed on every exit path.

const std = @import("std");
const diagnostic = @import("diagnostic");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;
const Io = std.Io;

/// The smallest program a browser builds: one mount, one hole.
const browser_main =
    \\import Browser
    \\import Html exposing (Html)
    \\
    \\
    \\view : Int → Html ()
    \\view n =
    \\    <p>{n}</p>
    \\
    \\
    \\main : Browser.Program
    \\main =
    \\    Browser.program { init = 0, update = λ_ n → n, view = view }
    \\
;

fn nodeMain(comptime text: []const u8) []const u8 {
    return
    \\import Node
    \\
    \\
    \\main : Node.Program
    \\main =
    \\    Node.print "
    ++ text ++
        \\"
        \\
    ;
}

test "a browser build writes the platform's page shell, the same in development and release" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", browser_main);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dev = try w.run(&.{ "build", "--platform=browser", "--out=dev", "Main.beni" });
    const release = try w.run(&.{ "build", "--platform=browser", "--release", "--out=rel", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), dev.exit_code);
    try testing.expectEqual(@as(u8, 0), release.exit_code);
    const page =
        \\<!doctype html>
        \\<html lang="en">
        \\  <head>
        \\    <meta charset="utf-8">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1">
        \\    <title>beni</title>
        \\    <script type="module" src="/_main.mjs"></script>
        \\  </head>
        \\  <body></body>
        \\</html>
        \\
    ;

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings(page, try w.read("dev/index.html"));
    try testing.expectEqualStrings(page, try w.read("rel/index.html"));
    // It is one of the files the build wrote, so the record lists it.
    try testing.expect(std.mem.indexOf(u8, try w.read("dev/_manifest.txt"), " index.html\n") != null);
}

test "a node build and a library build write no page" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", nodeMain("hi"));
    try w.write("lib/Lib.beni", "pub one : Int\none =\n    1\n");

    const node = try w.run(&.{ "build", "--platform=node", "--out=node-out", "Main.beni" });
    const library = try w.run(&.{ "build", "--platform=browser", "--library", "--out=lib-out", "lib" });

    try testing.expectEqual(@as(u8, 0), node.exit_code);
    try testing.expectEqual(@as(u8, 0), library.exit_code);
    try testing.expect(w.exists("node-out/_main.mjs"));
    try testing.expect(!w.exists("node-out/index.html"));
    try testing.expect(!w.exists("lib-out/index.html"));
}

test "an app's own page shell replaces the platform's, and every {{entry}} is the entry file" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", browser_main);
    try w.write("beni.json",
        \\{ "name": "mine", "html": "page.html" }
    );
    try w.write("page.html",
        \\<link rel="modulepreload" href="{{entry}}"><script type="module" src="{{entry}}"></script>
        \\
    );

    const built = try w.run(&.{ "build", "--platform=browser", "src" });

    try testing.expectEqual(@as(u8, 0), built.exit_code);
    try testing.expectEqualStrings(
        \\<link rel="modulepreload" href="/_main.mjs"><script type="module" src="/_main.mjs"></script>
        \\
    , try w.read("out/index.html"));
}

test "a project's base puts the page under a sub-path, and a base without a trailing slash is refused" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", browser_main);
    try w.write("beni.json",
        \\{ "html": "page.html", "build": { "platform": "browser", "paths": ["src"], "base": "/app/" } }
    );
    try w.write("page.html",
        \\<link rel="icon" href="{{base}}favicon.ico"><script type="module" src="{{entry}}"></script>
        \\
    );

    const built = try w.runWith(&.{"build"}, .{ .raw_diagnostics = true });

    try testing.expectEqual(@as(u8, 0), built.exit_code);
    try testing.expectEqualStrings(
        \\<link rel="icon" href="/app/favicon.ico"><script type="module" src="/app/_main.mjs"></script>
        \\
    , try w.read("out/index.html"));

    try w.write("beni.json",
        \\{ "build": { "platform": "browser", "paths": ["src"], "base": "/app" } }
    );
    const refused = try w.runWith(&.{"build"}, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 2), refused.exit_code);
    try testing.expectEqualStrings("beni: beni.json's \"build\" \"base\" must be a URL path ending in '/', not '/app'\n", refused.stderr);
}

test "a page shell that never names the entry file is refused, and nothing is written" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", browser_main);
    try w.write("beni.json",
        \\{ "html": "page.html" }
    );
    try w.write("page.html", "<p>no script here</p>\n");

    const built = try w.run(&.{ "build", "--platform=browser", "src" });

    try testing.expectEqual(@as(u8, 1), built.exit_code);
    try testing.expectEqual(@as(usize, 1), built.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .invalid_html_shell,
        .severity = .@"error",
        .span = .{ .file = "page.html", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 1 } },
        .title = "INVALID PAGE SHELL",
        .message = "This page shell never says `{{entry}}`, so the page it makes would not load the\n" ++
            "program.\n" ++
            "\n" ++
            "Write `<script type=\"module\" src=\"{{entry}}\"></script>` where the program should\n" ++
            "load; the build replaces `{{entry}}` with the entry file, `/_main.mjs`\n" ++
            "(`docs/design/backend.md` §2, *The page shell*).",
    }, built.diagnostics[0]);
    try testing.expect(!w.exists("out"));
}

test "a page shell that cannot be read is refused against the manifest that names it" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", browser_main);
    try w.write("beni.json",
        \\{ "html": "pages/gone.html" }
    );

    const built = try w.run(&.{ "build", "--platform=browser", "src" });

    try testing.expectEqual(@as(u8, 1), built.exit_code);
    try testing.expectEqual(@as(usize, 1), built.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.invalid_html_shell, built.diagnostics[0].code);
    try testing.expectEqualStrings("beni.json", built.diagnostics[0].span.file);
    try testing.expect(std.mem.startsWith(u8, built.diagnostics[0].message, "I cannot read the page shell `pages/gone.html`"));
    try testing.expect(!w.exists("out"));
}

test "a project's beni.json supplies build's platform, paths and output directory" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", nodeMain("from the project"));
    try w.write("beni.json",
        \\{ "name": "p", "build": { "platform": "node", "paths": ["src"], "out": "dist" } }
    );

    const built = try w.runWith(&.{"build"}, .{ .raw_diagnostics = true });

    try testing.expectEqual(@as(u8, 0), built.exit_code);
    try testing.expectEqualStrings("", built.stderr);
    try w.expectProgram("dist/_main.mjs", .{ .stdout = "from the project\n" });

    // A manifest that is not JSON is an exit-2 line, not a silent default.
    try w.write("beni.json", "{ \"build\": ");
    const broken = try w.runWith(&.{"build"}, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 2), broken.exit_code);
    try testing.expectEqualStrings("beni: cannot read 'beni.json': it is not a JSON object\n", broken.stderr);
}

test "beni new writes a browser-tea project that builds, and refuses a directory that is not empty" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    const made = try w.runWith(&.{ "new", "counter" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), made.exit_code);
    try testing.expectEqualStrings(
        \\Created a browser-tea project in counter/. Next:
        \\
        \\  cd counter
        \\  beni serve
        \\
    , made.stdout);
    try testing.expectEqualStrings(
        \\{
        \\  "name": "counter",
        \\  "build": { "platform": "browser-tea", "paths": ["src"], "out": "out" }
        \\}
        \\
    , try w.read("counter/beni.json"));
    try testing.expectEqualStrings("out/\n.beni-cache/\n", try w.read("counter/.gitignore"));

    var dir = try w.tmp.dir.openDir(w.io, "counter", .{});
    defer dir.close(w.io);
    const built = try w.runWith(&.{"build"}, .{ .raw_diagnostics = true, .cwd = .{ .dir = dir } });
    try testing.expectEqual(@as(u8, 0), built.exit_code);
    try testing.expectEqualStrings("", built.stderr);
    try testing.expect(w.exists("counter/out/index.html"));
    // The template is in the formatter's own shape.
    const formatted = try w.runWith(&.{ "fmt", "--check", "src" }, .{ .raw_diagnostics = true, .cwd = .{ .dir = dir } });
    try testing.expectEqual(@as(u8, 0), formatted.exit_code);

    const again = try w.runWith(&.{ "new", "counter" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 2), again.exit_code);
    try testing.expectEqualStrings("beni: 'counter' is not empty; beni new writes only into a new or empty directory\n", again.stderr);
}

test "beni new --platform=node writes a program that runs" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    const made = try w.runWith(&.{ "new", "--platform=node", "hello" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), made.exit_code);

    var dir = try w.tmp.dir.openDir(w.io, "hello", .{});
    defer dir.close(w.io);
    const built = try w.runWith(&.{"build"}, .{ .raw_diagnostics = true, .cwd = .{ .dir = dir } });
    try testing.expectEqual(@as(u8, 0), built.exit_code);
    try w.expectProgram("hello/out/_main.mjs", .{ .stdout = "Hello, beni!\n" });
    const formatted = try w.runWith(&.{ "fmt", "--check", "src" }, .{ .raw_diagnostics = true, .cwd = .{ .dir = dir } });
    try testing.expectEqual(@as(u8, 0), formatted.exit_code);
}

test "build --watch rebuilds after an edit, reports a failed build, and stops on SIGINT" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", nodeMain("one"));

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    var live = try Live.start(&w, &.{ "build", "--watch", "--poll-interval=10", "--platform=node", "src" });
    defer live.deinit();
    try live.waitFor("beni: built in ", 1);
    try w.write("src/Main.beni", nodeMain("two, after an edit"));
    try live.waitFor("beni: built in ", 2);
    try w.write("src/Main.beni", comptime nodeMain("three") ++ "broken = 1 + \"x\"\n");
    try live.waitFor("beni: build failed; waiting for changes\n", 1);
    const term = try live.stop();

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
    // Diagnostics as a one-shot build prints them.
    try testing.expect(std.mem.indexOf(u8, live.err.items, "-- TYPE MISMATCH") != null);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // The failed build wrote nothing: the output is the last good one.
    try w.expectProgram("out/_main.mjs", .{ .stdout = "two, after an edit\n" });
}

test "serve answers from the output directory, falls back to index.html, and counts builds for reload" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", browser_main);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    var live = try Live.start(&w, &.{ "serve", "--port=0", "--poll-interval=10", "--platform=browser", "src" });
    defer live.deinit();
    try live.waitFor("beni: built in ", 1);
    const port = try live.port();

    const root = try get(&w, port, "/");
    const module = try get(&w, port, "/_main.mjs?v=1");
    const route = try get(&w, port, "/todos/3");
    // A nested route loads: the script the fallback page names, resolved
    // against `/todos/3` as a browser resolves it, is the program.
    const nested_script = try get(&w, port, try resolveAgainst(&w, "/todos/3", try scriptSrc(route.body)));
    const missing = try get(&w, port, "/missing.mjs");
    // A route whose last segment has a `.` is a page when a browser
    // navigates to it, which says so in `Accept`; a fetch of it is not.
    const navigated = try getWith(&w, port, "/users/jane.doe", "accept: text/html,application/xhtml+xml;q=0.9,*/*;q=0.8\r\n");
    const fetched = try get(&w, port, "/users/jane.doe");
    const missing_navigated = try getWith(&w, port, "/missing.mjs", "accept: */*\r\n");
    const escape = try get(&w, port, "/%2e%2e/beni.json");
    const before = try get(&w, port, "/_beni/build");
    try w.write("src/Main.beni", browser_main ++ "\n\nunused : Int\nunused =\n    2\n");
    try live.waitFor("beni: built in ", 2);
    const after = try get(&w, port, "/_beni/build");
    const term = try live.stop();

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
    try testing.expectEqual(@as(u16, 200), root.status);
    try testing.expectEqualStrings("text/html; charset=utf-8", root.content_type);
    try testing.expect(std.mem.indexOf(u8, root.body, "<script type=\"module\" src=\"/_main.mjs\"></script>") != null);
    // The reload script is in the response, before `</body>`.
    try testing.expect(std.mem.indexOf(u8, root.body, "<body><script type=\"module\">/* beni serve: live reload */") != null);
    try testing.expectEqual(@as(u16, 200), module.status);
    try testing.expectEqualStrings("text/javascript; charset=utf-8", module.content_type);
    try testing.expectEqual(@as(u16, 200), route.status);
    try testing.expectEqualStrings(root.body, route.body);
    try testing.expectEqual(@as(u16, 200), nested_script.status);
    try testing.expectEqualStrings("text/javascript; charset=utf-8", nested_script.content_type);
    try testing.expectEqualStrings(module.body, nested_script.body);
    try testing.expectEqual(@as(u16, 404), missing.status);
    try testing.expectEqual(@as(u16, 200), navigated.status);
    try testing.expectEqualStrings(root.body, navigated.body);
    try testing.expectEqual(@as(u16, 404), fetched.status);
    try testing.expectEqual(@as(u16, 404), missing_navigated.status);
    try testing.expectEqual(@as(u16, 400), escape.status);
    try testing.expectEqualStrings("1", before.body);
    try testing.expectEqualStrings("2", after.body);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // Never in a file the build wrote.
    try testing.expect(std.mem.indexOf(u8, try w.read("out/index.html"), "live reload") == null);
}

/// A `beni` that keeps running: both pipes are read as the scenario waits,
/// with a deadline, and it is killed on every exit path.
const Live = struct {
    w: *World,
    child: std.process.Child,
    out: std.ArrayList(u8) = .empty,
    err: std.ArrayList(u8) = .empty,
    open: [2]bool = .{ true, true },
    done: bool = false,

    const timeout_ms = 20_000;

    fn start(w: *World, args: []const []const u8) !Live {
        const arena = w.arena.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, w.exe);
        try argv.appendSlice(arena, args);
        var env = std.process.Environ.Map.init(w.gpa);
        defer env.deinit();
        const child = try std.process.spawn(w.io, .{
            .argv = argv.items,
            .cwd = .{ .dir = w.tmp.dir },
            .environ_map = &env,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        return .{ .w = w, .child = child };
    }

    fn deinit(live: *Live) void {
        if (!live.done) live.child.kill(live.w.io);
    }

    /// Read until stdout holds `needle` `count` times.
    fn waitFor(live: *Live, needle: []const u8, count: usize) !void {
        const io = live.w.io;
        const deadline = Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(timeout_ms));
        while (std.mem.count(u8, live.out.items, needle) < count) {
            const left = Io.Timestamp.now(io, .awake).durationTo(deadline).toMilliseconds();
            if (left <= 0 or !(live.open[0] or live.open[1])) {
                std.debug.print("waited for {d}× `{s}`\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n", .{ count, needle, live.out.items, live.err.items });
                return error.LiveTimeout;
            }
            try live.pump(@intCast(@min(left, 1000)));
        }
    }

    /// One `poll` of both pipes, at most `wait_ms`.
    fn pump(live: *Live, wait_ms: i32) !void {
        const io = live.w.io;
        const files = [2]Io.File{ live.child.stdout.?, live.child.stderr.? };
        var fds: [2]std.posix.pollfd = undefined;
        for (&fds, files, live.open) |*fd, file, open| {
            fd.* = .{ .fd = if (open) file.handle else -1, .events = std.posix.POLL.IN, .revents = 0 };
        }
        _ = try std.posix.poll(&fds, wait_ms);
        const sinks = [2]*std.ArrayList(u8){ &live.out, &live.err };
        var buf: [16 * 1024]u8 = undefined;
        for (fds, files, sinks, 0..) |fd, file, sink, i| {
            if (fd.fd < 0 or fd.revents == 0) continue;
            const n = file.readStreaming(io, &.{&buf}) catch 0;
            if (n == 0) {
                live.open[i] = false;
                continue;
            }
            try sink.appendSlice(live.w.arena.allocator(), buf[0..n]);
        }
    }

    /// SIGINT, then read both pipes to their end and reap.
    fn stop(live: *Live) !std.process.Child.Term {
        try std.posix.kill(live.child.id.?, .INT);
        const io = live.w.io;
        const deadline = Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(timeout_ms));
        while (live.open[0] or live.open[1]) {
            const left = Io.Timestamp.now(io, .awake).durationTo(deadline).toMilliseconds();
            if (left <= 0) return error.LiveTimeout;
            try live.pump(@intCast(@min(left, 1000)));
        }
        live.done = true;
        return live.child.wait(io);
    }

    /// The port from `beni: serving <out>/ at http://127.0.0.1:<port>/`.
    fn port(live: *const Live) !u16 {
        const marker = "http://127.0.0.1:";
        const at = std.mem.indexOf(u8, live.out.items, marker) orelse return error.NoServingLine;
        const rest = live.out.items[at + marker.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '/') orelse return error.NoServingLine;
        return std.fmt.parseInt(u16, rest[0..end], 10);
    }
};

/// The `src` of the first `<script type="module" src="…">` in `html`.
fn scriptSrc(html: []const u8) ![]const u8 {
    const marker = "<script type=\"module\" src=\"";
    const at = std.mem.indexOf(u8, html, marker) orelse return error.NoScript;
    const rest = html[at + marker.len ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse return error.NoScript];
}

/// `src` resolved against the page path `page`, as a browser resolves a
/// path reference: an absolute one is itself, a relative one is taken from
/// the page's directory.
fn resolveAgainst(w: *World, page: []const u8, src: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, src, "/")) return src;
    const dir = page[0 .. std.mem.lastIndexOfScalar(u8, page, '/').? + 1];
    const rel = if (std.mem.startsWith(u8, src, "./")) src[2..] else src;
    return std.fmt.allocPrint(w.arena.allocator(), "{s}{s}", .{ dir, rel });
}

const Response = struct { status: u16, content_type: []const u8, body: []const u8 };

/// One `GET` over a fresh connection that the request asks to close.
fn get(w: *World, port: u16, target: []const u8) !Response {
    return getWith(w, port, target, "");
}

/// `get` with more header lines, each ending in `\r\n`.
fn getWith(w: *World, port: u16, target: []const u8, headers: []const u8) !Response {
    const io = w.io;
    const arena = w.arena.allocator();
    const address = try Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var send_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &send_buffer);
    try writer.interface.print("GET {s} HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n{s}\r\n", .{ target, headers });
    try writer.interface.flush();
    var recv_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &recv_buffer);
    const raw = try reader.interface.allocRemaining(arena, .limited(16 * 1024 * 1024));
    const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.NoHead;
    var lines = std.mem.splitSequence(u8, raw[0..head_end], "\r\n");
    const status_line = lines.next().?;
    const status = try std.fmt.parseInt(u16, status_line[9..12], 10);
    var content_type: []const u8 = "";
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-type: ")) content_type = line["content-type: ".len..];
    }
    return .{ .status = status, .content_type = content_type, .body = raw[head_end + 4 ..] };
}
