//! `beni serve` (docs/design/frontend.md §10.4): `build --watch` and a
//! static HTTP server for `--out`, in one process.
//!
//! The server is a development server and nothing more: one task per
//! connection on the process's `Io`, files read from disk per request, no
//! TLS, compression or ranges. What it adds to a file server is the
//! single-page-application fallback and live reload, and live reload lives
//! in the HTTP RESPONSE — a script inserted into every HTML body on its way
//! out — so no file a build writes ever carries it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;
const net = std.Io.net;
const Cli = @import("../Cli.zig");
const Session = @import("../Session.zig");
const Watch = @import("Watch.zig");
const fs_read = @import("../fs_read.zig");

/// The largest file served. A development output tree holds modules, not
/// media libraries; a bigger file is a 500 rather than an allocation of
/// whatever is on disk.
const max_file_bytes = 256 * 1024 * 1024;

/// The server's own URL namespace (§10.4): no file a build writes begins
/// with `_beni`.
const own_prefix = "_beni/";

/// What the injected script polls, and reloads the page when it changes.
const build_endpoint = "/_beni/build";

/// Inserted before the last `</body>` of every HTML response. It polls
/// `/_beni/build` twice a second and reloads when the count of successful
/// builds moves; a server that went away and came back counts from zero, so
/// that reloads too. The one failure it expects is the network's — `fetch`
/// rejects with a `TypeError` while the server is down — and it re-throws
/// anything else (CLAUDE.md rule 9: no broad catch).
pub const reload_script =
    "<script type=\"module\">/* beni serve: live reload */" ++
    "let seen;for(;;){try{const r=await fetch(\"" ++ build_endpoint ++ "\",{cache:\"no-store\"});" ++
    "const n=await r.text();if(seen!==undefined&&n!==seen){location.reload();break}seen=n}" ++
    "catch(e){if(!(e instanceof TypeError))throw e}" ++
    "await new Promise(f=>setTimeout(f,500))}</script>";

const Shared = struct {
    io: Io,
    out: []const u8,
    reload: bool,
    /// The project's `"base"`, taken off the front of a request path.
    base: []const u8,
    /// Successful builds since the server started.
    builds: std.atomic.Value(u32) = .init(0),

    fn built(context: *anyopaque, ok: bool) void {
        const shared: *Shared = @ptrCast(@alignCast(context));
        if (ok) _ = shared.builds.fetchAdd(1, .release);
    }
};

pub fn run(gpa: Allocator, io: Io, stdout: *Io.Writer, stderr: *Io.Writer, options: Session.Options, serve: Cli.Serve) u8 {
    const address = net.IpAddress.parse(serve.host, serve.port) catch
        return fail(stderr, "beni: invalid value '{s}' for --host (expected an IPv4 or IPv6 address)", .{serve.host});
    var server = address.listen(io, .{ .reuse_address = true }) catch |err|
        return fail(stderr, "beni: cannot listen on {s}:{d}: {t}", .{ serve.host, serve.port, err });

    var shared: Shared = .{ .io = io, .out = serve.build.out, .reload = serve.reload, .base = serve.build.base };
    stdout.print("beni: serving {s}/ at http://{f}/\n", .{ serve.build.out, server.socket.address }) catch {};
    stdout.flush() catch {};

    var accepting = io.concurrent(acceptLoop, .{ &server, &shared }) catch |err| {
        server.deinit(io);
        return fail(stderr, "beni: cannot start the server: {t}", .{err});
    };
    _ = &accepting;

    const code = Watch.run(gpa, io, stdout, stderr, options, serve.build, .{ .context = &shared, .built = Shared.built });
    stdout.flush() catch {};
    stderr.flush() catch {};
    // Open connections are dropped, not drained (§10.4): a browser holding
    // a keep-alive connection would otherwise keep the process alive.
    std.process.exit(code);
}

fn acceptLoop(server: *net.Server, shared: *Shared) void {
    const io = shared.io;
    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.Canceled, error.SocketNotListening => return,
            else => continue,
        };
        group.concurrent(io, connection, .{ shared, stream }) catch {
            var copy = stream;
            copy.close(io);
        };
    }
}

fn connection(shared: *Shared, stream: net.Stream) void {
    const io = shared.io;
    defer {
        var copy = stream;
        copy.close(io);
    }
    var recv_buffer: [8192]u8 = undefined;
    var send_buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &recv_buffer);
    var writer = stream.writer(io, &send_buffer);
    var server: http.Server = .init(&reader.interface, &writer.interface);
    while (true) {
        var request = server.receiveHead() catch return;
        respond(shared, &request) catch return;
        if (!request.head.keep_alive) return;
    }
}

const Header = http.Header;

fn respond(shared: *Shared, request: *http.Server.Request) !void {
    const method = request.head.method;
    if (method != .GET and method != .HEAD) {
        // The connection is closed after this one: a request that may carry
        // a body would have to be read to its end first, and a development
        // server has no use for it.
        request.head.keep_alive = false;
        return request.respond("method not allowed\n", .{
            .status = .method_not_allowed,
            .keep_alive = false,
            .extra_headers = &.{ text_plain, no_store, .{ .name = "allow", .value = "GET, HEAD" } },
        });
    }
    var path_buffer: [4096]u8 = undefined;
    const target = resolveTarget(&path_buffer, request.head.target) orelse
        return request.respond("bad request\n", .{ .status = .bad_request, .extra_headers = &.{ text_plain, no_store } });
    const rel = underBase(target, shared.base);

    if (std.mem.startsWith(u8, rel, own_prefix)) {
        if (std.mem.eql(u8, rel, build_endpoint[1..])) {
            var number: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&number, "{d}", .{shared.builds.load(.acquire)}) catch unreachable;
            return request.respond(text, .{ .extra_headers = &.{ text_plain, no_store } });
        }
        return notFound(request);
    }

    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const found = try locate(arena, shared, rel, acceptsHtml(request)) orelse return notFound(request);
    const bytes = fs_read.readFileAlloc(shared.io, Io.Dir.cwd(), found, arena, .limited(max_file_bytes)) catch
        return notFound(request);
    const mime = mimeType(found);
    const body = if (shared.reload and std.mem.startsWith(u8, mime, "text/html"))
        try injectReload(arena, bytes)
    else
        bytes;
    return request.respond(body, .{ .extra_headers = &.{ .{ .name = "content-type", .value = mime }, no_store } });
}

const text_plain: Header = .{ .name = "content-type", .value = "text/plain; charset=utf-8" };
const no_store: Header = .{ .name = "cache-control", .value = "no-store" };

fn notFound(request: *http.Server.Request) !void {
    return request.respond("not found\n", .{ .status = .not_found, .extra_headers = &.{ text_plain, no_store } });
}

/// Whether the request's `Accept` lists `text/html`: what a browser sends
/// when it navigates to an address, and a module or a `fetch` does not.
fn acceptsHtml(request: *const http.Server.Request) bool {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "accept")) continue;
        var types = std.mem.splitScalar(u8, header.value, ',');
        while (types.next()) |item| {
            const media = std.mem.trim(u8, item[0 .. std.mem.indexOfScalar(u8, item, ';') orelse item.len], " \t");
            if (std.ascii.eqlIgnoreCase(media, "text/html")) return true;
        }
    }
    return false;
}

/// The file under `--out` that answers `rel`, or null for a 404: the file
/// itself, a directory's `index.html`, or — for a path that names nothing
/// and whose last segment has no `.`, or any such path when the request
/// accepts HTML — the root `index.html` (§10.4's single-page-application
/// fallback, as amended for a route like `/users/jane.doe`).
fn locate(arena: Allocator, shared: *Shared, rel: []const u8, html: bool) !?[]const u8 {
    const io = shared.io;
    const cwd = Io.Dir.cwd();
    const full = if (rel.len == 0)
        try std.fmt.allocPrint(arena, "{s}/index.html", .{shared.out})
    else
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ shared.out, rel });
    if (cwd.statFile(io, full, .{})) |stat| switch (stat.kind) {
        .file => return full,
        .directory => {
            const index = try std.fmt.allocPrint(arena, "{s}/index.html", .{full});
            const s = cwd.statFile(io, index, .{}) catch return null;
            return if (s.kind == .file) index else null;
        },
        else => return null,
    } else |_| {}
    const last = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| rel[i + 1 ..] else rel;
    if (!html and std.mem.indexOfScalar(u8, last, '.') != null) return null;
    const index = try std.fmt.allocPrint(arena, "{s}/index.html", .{shared.out});
    const s = cwd.statFile(io, index, .{}) catch return null;
    return if (s.kind == .file) index else null;
}

/// A request target as a path relative to `--out`, or null for a 400: the
/// query and fragment dropped, `%XX` decoded, and nothing that could leave
/// the directory — no `..`, `.` or empty segment (one trailing `/` aside),
/// no NUL and no backslash. `/` is the empty path.
pub fn resolveTarget(buffer: []u8, target: []const u8) ?[]const u8 {
    var t = target;
    if (std.mem.indexOfAny(u8, t, "?#")) |i| t = t[0..i];
    if (t.len == 0 or t[0] != '/') return null;
    var len: usize = 0;
    var i: usize = 1;
    while (i < t.len) {
        var c = t[i];
        if (c == '%') {
            if (i + 2 >= t.len) return null;
            c = std.fmt.parseInt(u8, t[i + 1 .. i + 3], 16) catch return null;
            i += 3;
        } else i += 1;
        if (c == 0 or c == '\\') return null;
        if (len == buffer.len) return null;
        buffer[len] = c;
        len += 1;
    }
    var path = buffer[0..len];
    if (path.len > 0 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
    if (path.len == 0) return path;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return null;
    }
    return path;
}

/// `rel` with the project's `"base"` taken off its front (§10.4): a page
/// built for `/app/` asks for `/app/_main.mjs`, which is `_main.mjs` in
/// `--out`. A path outside the base, and every path when the base is `/` or
/// relative, is left as it is.
pub fn underBase(rel: []const u8, base: []const u8) []const u8 {
    if (base.len < 2 or base[0] != '/') return rel;
    const prefix = base[1..]; // `app/`
    if (std.mem.eql(u8, rel, prefix[0 .. prefix.len - 1])) return "";
    if (std.mem.startsWith(u8, rel, prefix)) return rel[prefix.len..];
    return rel;
}

/// §10.4's table.
pub fn mimeType(path: []const u8) []const u8 {
    const Row = struct { []const u8, []const u8 };
    const rows = [_]Row{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".json", "application/json; charset=utf-8" },
        .{ ".map", "application/json; charset=utf-8" },
        .{ ".txt", "text/plain; charset=utf-8" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".webp", "image/webp" },
        .{ ".ico", "image/x-icon" },
        .{ ".wasm", "application/wasm" },
        .{ ".woff2", "font/woff2" },
    };
    for (rows) |row| {
        if (std.ascii.endsWithIgnoreCase(path, row[0])) return row[1];
    }
    return "application/octet-stream";
}

/// `html` with `reload_script` before its last `</body>`, in any case, or
/// at its end when it has none.
pub fn injectReload(arena: Allocator, html: []const u8) ![]const u8 {
    const close = "</body>";
    var at: usize = html.len;
    var i: usize = html.len;
    while (i >= close.len) : (i -= 1) {
        if (std.ascii.eqlIgnoreCase(html[i - close.len .. i], close)) {
            at = i - close.len;
            break;
        }
    }
    return std.mem.concat(arena, u8, &.{ html[0..at], reload_script, html[at..] });
}

fn fail(stderr: *Io.Writer, comptime format_string: []const u8, args: anytype) u8 {
    stderr.print(format_string ++ "\n", args) catch {};
    return 2;
}

const testing = std.testing;

test "a request target is a path under the output directory, or nothing" {
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings("", resolveTarget(&buffer, "/").?);
    try testing.expectEqualStrings("_main.mjs", resolveTarget(&buffer, "/_main.mjs?v=1#x").?);
    try testing.expectEqualStrings("a b/c", resolveTarget(&buffer, "/a%20b/c/").?);
    try testing.expectEqualStrings("todos/3", resolveTarget(&buffer, "/todos/3").?);
    for ([_][]const u8{ "", "x", "/..", "/a/../b", "/./a", "/a//b", "/%2e%2e/x", "/a%00", "/a%5cb", "/a\\b", "/%zz", "/%4" }) |bad| {
        try testing.expectEqual(@as(?[]const u8, null), resolveTarget(&buffer, bad));
    }
}

test "a request under the project's base is a path in the output directory" {
    try testing.expectEqualStrings("_main.mjs", underBase("_main.mjs", "/"));
    try testing.expectEqualStrings("_main.mjs", underBase("app/_main.mjs", "/app/"));
    try testing.expectEqualStrings("", underBase("app", "/app/"));
    try testing.expectEqualStrings("todos/3", underBase("a/b/todos/3", "/a/b/"));
    try testing.expectEqualStrings("other/x", underBase("other/x", "/app/"));
    try testing.expectEqualStrings("app/x", underBase("app/x", "./"));
}

test "MIME types and the reload script's place" {
    try testing.expectEqualStrings("text/javascript; charset=utf-8", mimeType("_main.mjs"));
    try testing.expectEqualStrings("text/html; charset=utf-8", mimeType("index.HTML"));
    try testing.expectEqualStrings("application/json; charset=utf-8", mimeType("a.js.map"));
    try testing.expectEqualStrings("application/octet-stream", mimeType("_manifest.bin"));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("<p></p>" ++ reload_script ++ "</BODY>", try injectReload(arena.allocator(), "<p></p></BODY>"));
    try testing.expectEqualStrings("<p>" ++ reload_script, try injectReload(arena.allocator(), "<p>"));
}
