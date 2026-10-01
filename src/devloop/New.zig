//! `beni new <dir>` (docs/design/frontend.md §10.2): a project that builds
//! and runs, and nothing else — `beni.json` with its `"build"` defaults,
//! `src/Main.beni`, and a `.gitignore` for the two directories a build makes.
//!
//! The templates are the compiler's, written here as text. A black-box test
//! builds both, runs the `node` one, and holds both to `beni fmt --check`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Cli = @import("../Cli.zig");

pub const browser_tea_main =
    \\-- A counter: The Elm Architecture in a page. `update` turns a message
    \\-- into the next model, and `view` draws the model; the page re-renders
    \\-- whatever changed after every message.
    \\import Html exposing (Html)
    \\import Tea
    \\
    \\
    \\type Msg
    \\    = Increment
    \\    | Decrement
    \\
    \\
    \\update : Msg, Int -> Int
    \\update msg count =
    \\    case msg of
    \\        Increment ->
    \\            count + 1
    \\
    \\        Decrement ->
    \\            count - 1
    \\
    \\
    \\view : Int -> Html Msg
    \\view count =
    \\    <main>
    \\        <h1>Hello, beni</h1>
    \\        <button onClick={Decrement}>-</button>
    \\        <output>{count}</output>
    \\        <button onClick={Increment}>+</button>
    \\    </main>
    \\
    \\
    \\main : Tea.Program
    \\main = Tea.sandbox { init = 0, update = update, view = view }
    \\
;

pub const node_main =
    \\-- A program for Node: `main` is what the platform runs.
    \\import Node
    \\
    \\
    \\greeting : String -> String
    \\greeting name = "Hello, ${name}!"
    \\
    \\
    \\main : Node.Program
    \\main = Node.print (greeting "beni")
    \\
;

pub const gitignore =
    \\out/
    \\.beni-cache/
    \\
;

pub fn run(io: Io, stdout: *Io.Writer, stderr: *Io.Writer, new: Cli.New) u8 {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = Io.Dir.cwd();

    // An existing directory must be empty: `new` never writes beside, or
    // over, somebody's files.
    if (cwd.openDir(io, new.dir, .{ .iterate = true })) |opened| {
        var dir = opened;
        defer dir.close(io);
        var it = dir.iterate();
        const any = it.next(io) catch return notEmpty(stderr, new.dir);
        if (any != null) return notEmpty(stderr, new.dir);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return notEmpty(stderr, new.dir),
    }

    const src = std.fmt.allocPrint(arena, "{s}/src", .{new.dir}) catch return oom(stderr);
    cwd.createDirPath(io, src) catch |err|
        return fail(stderr, "beni: cannot write '{s}': {t}", .{ src, err });

    const name = projectName(arena, io, new.dir);
    const platform_name = @tagName(new.template);
    var manifest: std.ArrayList(u8) = .empty;
    manifest.appendSlice(arena, "{\n  \"name\": ") catch return oom(stderr);
    jsonString(arena, &manifest, name) catch return oom(stderr);
    manifest.print(arena, ",\n  \"build\": {{ \"platform\": \"{s}\", \"paths\": [\"src\"], \"out\": \"out\" }}\n}}\n", .{platform_name}) catch return oom(stderr);

    const files = [_]struct { []const u8, []const u8 }{
        .{ "beni.json", manifest.items },
        .{ "src/Main.beni", switch (new.template) {
            .@"browser-tea" => browser_tea_main,
            .node => node_main,
        } },
        .{ ".gitignore", gitignore },
    };
    for (files) |file| {
        const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ new.dir, file[0] }) catch return oom(stderr);
        cwd.writeFile(io, .{ .sub_path = path, .data = file[1] }) catch |err|
            return fail(stderr, "beni: cannot write '{s}': {t}", .{ path, err });
    }

    const next = switch (new.template) {
        .@"browser-tea" => "beni serve",
        .node => "beni build && node out/_main.mjs",
    };
    stdout.print(
        \\Created a {s} project in {s}/. Next:
        \\
        \\  cd {s}
        \\  {s}
        \\
    , .{ platform_name, new.dir, new.dir, next }) catch return 2;
    return 0;
}

/// The last segment of `dir`, or of its real path when that is `.`/`..`.
fn projectName(arena: Allocator, io: Io, dir: []const u8) []const u8 {
    const base = std.fs.path.basename(dir);
    if (base.len != 0 and !std.mem.eql(u8, base, ".") and !std.mem.eql(u8, base, "..")) return base;
    const real = Io.Dir.cwd().realPathFileAlloc(io, dir, arena) catch return "app";
    const real_base = std.fs.path.basename(real);
    return if (real_base.len == 0) "app" else real_base;
}

fn jsonString(arena: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(arena, '"');
    for (text) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        0...0x1f => try out.print(arena, "\\u{x:0>4}", .{c}),
        else => try out.append(arena, c),
    };
    try out.append(arena, '"');
}

fn notEmpty(stderr: *Io.Writer, dir: []const u8) u8 {
    return fail(stderr, "beni: '{s}' is not empty; beni new writes only into a new or empty directory", .{dir});
}

fn oom(stderr: *Io.Writer) u8 {
    return fail(stderr, "beni: out of memory", .{});
}

fn fail(stderr: *Io.Writer, comptime format_string: []const u8, args: anytype) u8 {
    stderr.print(format_string ++ "\n", args) catch {};
    return 2;
}
