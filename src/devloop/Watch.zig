//! `beni build --watch` (docs/design/frontend.md §10.3): build, then poll
//! the inputs and rebuild on every change, until SIGINT or SIGTERM.
//!
//! **Polling, not a daemon.** Every build is the one-shot `build/Command.zig`
//! run again from scratch; what makes the second one fast is the on-disk
//! cache (`fast-compiler.md` §8), not anything held here. `fast-compiler.md`
//! §4's resident process — `inotify`/`FSEvents`, a socket, cancellation — is
//! M4's and replaces this loop; nothing here pre-empts the daemon's open
//! decisions.
//!
//! The state of the inputs is one 64-bit digest: per watched file, a hash of
//! its path, size and modification time, summed, plus the count — so the
//! walk's order does not matter and nothing is sorted or kept. A change is
//! followed by one more poll that must see the same digest (the debounce)
//! before the rebuild.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Cli = @import("../Cli.zig");
const Session = @import("../Session.zig");
const SourceStore = @import("../SourceStore.zig");
const BuildCommand = @import("../build/Command.zig");
const platform = @import("../platform.zig");

/// Called after every build with whether it succeeded: how `serve` learns
/// that the output directory moved (`frontend.md` §10.4).
pub const Hook = struct {
    context: *anyopaque,
    built: *const fn (context: *anyopaque, ok: bool) void,
};

/// Set by the signal handler; read between polls. A process-wide flag,
/// because a signal is process-wide: there is nothing else to hang it on.
var stop_requested: std.atomic.Value(bool) = .init(false);

/// Catch SIGINT and SIGTERM once each: the first asks the loop to stop after
/// the build in progress, and `RESETHAND` puts the default back, so a second
/// signal kills a hung build.
pub fn installSignals() void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESETHAND,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    stop_requested.store(true, .release);
}

pub fn stopping() bool {
    return stop_requested.load(.acquire);
}

/// Run the loop. Returns the process exit code: 0 when stopped by a
/// signal, or the first build's when that build failed with exit 2.
pub fn run(
    gpa: Allocator,
    io: Io,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    options: Session.Options,
    build: Cli.Build,
    hook: ?Hook,
) u8 {
    installSignals();
    var watched: Watched = .init(gpa, io, build);
    defer watched.deinit();

    var digest = watched.digest();
    const first = buildOnce(gpa, io, stdout, stderr, options, build, hook);
    if (first == 2) return 2;
    // A first build may have created `--out`: nothing changes for the
    // digest, which never looks inside it.
    while (true) {
        if (sleepOrStop(io, build.poll_interval_ms)) return 0;
        var next = watched.digest();
        if (next == digest) continue;
        // The debounce: one more interval in which nothing moved.
        while (true) {
            if (sleepOrStop(io, build.poll_interval_ms)) return 0;
            const again = watched.digest();
            if (again == next) break;
            next = again;
        }
        digest = next;
        _ = buildOnce(gpa, io, stdout, stderr, options, build, hook);
    }
}

/// Sleep one interval, in slices short enough that a signal is answered
/// within a fraction of a second whatever the interval; true when the
/// loop should stop.
fn sleepOrStop(io: Io, interval_ms: u32) bool {
    var left: u32 = interval_ms;
    while (left > 0) {
        if (stopping()) return true;
        const step = @min(left, 50);
        io.sleep(.fromMilliseconds(step), .awake) catch return true;
        left -= step;
    }
    return stopping();
}

/// One build, its diagnostics as a one-shot build prints them, then the
/// status line (`frontend.md` §10.3). Both streams are flushed, so a reader
/// of the pipe sees the line when the build is done.
fn buildOnce(
    gpa: Allocator,
    io: Io,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    options: Session.Options,
    build: Cli.Build,
    hook: ?Hook,
) u8 {
    const started = Io.Timestamp.now(io, .awake);
    const code = BuildCommand.run(gpa, io, stdout, stderr, options, build);
    const ms = started.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds();
    stderr.flush() catch {};
    // Before the status line: whoever reads the line may ask the server
    // straight away, and must find the build already counted.
    if (hook) |h| h.built(h.context, code == 0);
    if (code == 0)
        stdout.print("beni: built in {d} ms\n", .{ms}) catch {}
    else
        stdout.writeAll("beni: build failed; waiting for changes\n") catch {};
    stdout.flush() catch {};
    return code;
}

/// What a watch looks at (`frontend.md` §10.3): every file with a watched
/// extension under the build's paths and under each platform package read
/// from a directory, and those directly in the project root — never inside
/// `--out`, and never a hidden entry.
const Watched = struct {
    gpa: Allocator,
    io: Io,
    arena: std.heap.ArenaAllocator,
    /// Recursive roots.
    trees: []const []const u8,
    /// The project root, read one level deep.
    root: []const u8,
    /// `--out`, normalised: never descended into.
    out: []const u8,

    fn init(gpa: Allocator, io: Io, build: Cli.Build) Watched {
        var w: Watched = .{ .gpa = gpa, .io = io, .arena = .init(gpa), .trees = &.{}, .root = ".", .out = "" };
        const arena = w.arena.allocator();
        var trees: std.ArrayList([]const u8) = .empty;
        for (build.paths) |p| trees.append(arena, normalized(arena, p)) catch {};
        // A platform read from a directory is source too, with every
        // package of its chain; an embedded one is in the binary.
        var failure: ?platform.Failure = null;
        if (platform.resolveChain(arena, io, build.platform, &failure)) |chain| {
            for (chain.layers) |layer| {
                if (layer.embedded == null) trees.append(arena, layer.root) catch {};
            }
        } else |_| {}
        w.trees = trees.items;
        w.root = normalized(arena, build.common.root orelse ".");
        w.out = normalized(arena, build.out);
        return w;
    }

    fn deinit(w: *Watched) void {
        w.arena.deinit();
    }

    fn digest(w: *Watched) u64 {
        var acc: Accumulator = .{};
        for (w.trees) |tree| w.walk(&acc, tree, true);
        w.walk(&acc, w.root, false);
        return acc.sum +% acc.count *% 0x9e3779b97f4a7c15;
    }

    const Accumulator = struct { sum: u64 = 0, count: u64 = 0 };

    /// Add `path` — a file, or a directory read `recursive`ly or one level
    /// deep — to `acc`. Anything that cannot be read counts as absent: a
    /// file being replaced mid-poll is seen at the next one.
    fn walk(w: *Watched, acc: *Accumulator, path: []const u8, recursive: bool) void {
        if (w.isOut(path)) return;
        const stat = Io.Dir.cwd().statFile(w.io, path, .{}) catch return;
        switch (stat.kind) {
            .file => if (watchedName(path)) add(acc, path, stat),
            .directory => {
                var dir = Io.Dir.cwd().openDir(w.io, path, .{ .iterate = true }) catch return;
                defer dir.close(w.io);
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                var it = dir.iterate();
                while (it.next(w.io) catch return) |entry| {
                    if (entry.name.len == 0 or entry.name[0] == '.') continue;
                    const child = if (std.mem.eql(u8, path, "."))
                        entry.name
                    else
                        std.fmt.bufPrint(&buffer, "{s}/{s}", .{ path, entry.name }) catch continue;
                    switch (entry.kind) {
                        .directory => if (recursive) {
                            // `buffer` is reused below this frame: copy.
                            var copy: [std.fs.max_path_bytes]u8 = undefined;
                            @memcpy(copy[0..child.len], child);
                            w.walk(acc, copy[0..child.len], true);
                        },
                        .file, .sym_link => {
                            if (!watchedName(child) or w.isOut(child)) continue;
                            const s = dir.statFile(w.io, entry.name, .{}) catch continue;
                            if (s.kind == .file) add(acc, child, s);
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    fn isOut(w: *const Watched, path: []const u8) bool {
        if (w.out.len == 0) return false;
        if (std.mem.eql(u8, w.out, ".")) return true;
        return std.mem.eql(u8, path, w.out) or
            (path.len > w.out.len and std.mem.startsWith(u8, path, w.out) and path[w.out.len] == '/');
    }

    fn add(acc: *Accumulator, path: []const u8, stat: Io.File.Stat) void {
        var h = std.hash.Wyhash.init(0);
        h.update(path);
        h.update(std.mem.asBytes(&stat.size));
        const mtime: i128 = stat.mtime.nanoseconds;
        h.update(std.mem.asBytes(&mtime));
        acc.sum +%= h.final();
        acc.count += 1;
    }
};

/// The extensions a watch looks at: sources, siblings, manifests, pages and
/// stylesheets a page shell may name.
fn watchedName(path: []const u8) bool {
    for ([_][]const u8{ ".beni", ".js", ".json", ".html", ".css" }) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }
    return false;
}

fn normalized(arena: Allocator, path: []const u8) []const u8 {
    const buffer = arena.alloc(u8, @max(path.len, 1)) catch return path;
    return SourceStore.normalize(buffer, path);
}

test "watched names" {
    try std.testing.expect(watchedName("src/Main.beni"));
    try std.testing.expect(watchedName("index.html"));
    try std.testing.expect(!watchedName("out/Main.mjs"));
    try std.testing.expect(!watchedName("notes.txt"));
}
