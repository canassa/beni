//! The black-box harness (docs/design/frontend.md §7,
//! .claude/skills/write-tests/SKILL.md).
//!
//! A `World` is a temporary project directory plus the means to run the REAL
//! installed binary against it: `write` files, `run` the compiler with cwd =
//! the project, get back `{exit_code, stdout, stderr, diagnostics}` where
//! `diagnostics` is stderr parsed through the production `diagnostic` schema.
//! Nothing here links a compiler internal — the module imports `std` and
//! `diagnostic` only, which the build graph enforces.
//!
//! Process mechanics follow lar's verified-0.16 `session.zig`: a replacement
//! environment (the child sees nothing from the machine), both pipes drained
//! to EOF, every wait bounded, and kill-and-reap on every exit path so a
//! hung or crashed compiler fails the test instead of the suite. Both pipes
//! are multiplexed with `poll` on one thread, which is what makes the timeout
//! a single deadline rather than a thread to join.
//!
//! Cited 0.16 std APIs (verified against the installed std):
//!   - `std.process.spawn(io, .{ .argv, .cwd = .{ .dir }, .environ_map,
//!     .stdout = .pipe, .stderr = .pipe })` -> `Child` (`process.zig:442`).
//!   - `Child.kill(io)` terminates AND reaps; idempotent (`Child.zig:118`).
//!   - `Child.wait(io) -> Term` (`Child.zig:134`).
//!   - `File.readStreaming(io, &.{buf})` — one read (`Io/File.zig:474`).
//!   - `std.posix.poll(fds, timeout_ms)` (`posix.zig:1003`).
//!   - `std.testing.tmpDir` under `.zig-cache/tmp` (`testing.zig:634`).

const std = @import("std");
const diagnostic = @import("diagnostic");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Relative to the repo root, which the build step pins as cwd. Resolved to
/// an absolute path at `init` because the child runs with a different cwd.
pub const exe_relative = "zig-out/bin/beni";

/// Wall-clock bound on one compiler run. Generous: the point is to turn a
/// hang into a failure, not to measure.
pub const timeout_ms: i64 = 60_000;

/// Largest stream the harness keeps. Beyond it the run fails loudly rather
/// than silently truncating an assertion's input.
pub const max_stream_bytes = 64 * 1024 * 1024;

pub const Result = struct {
    /// The exit status, or 255 when the child died from a signal (`term`
    /// says which).
    exit_code: u8,
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,
    /// stderr parsed as the JSON diagnostics array; empty when stderr is
    /// empty. Only populated for JSON runs (see `RunOptions`).
    diagnostics: []const diagnostic.Diagnostic,
};

pub const RunOptions = struct {
    /// Leave stderr alone: no `--diagnostics=json` is added and nothing is
    /// parsed. For scenarios that assert the text renderer or usage errors.
    raw_diagnostics: bool = false,
    /// Where the child runs. Default: the world's project directory.
    cwd: ?std.process.Child.Cwd = null,
};

pub const World = struct {
    gpa: Allocator,
    io: Io,
    tmp: std.testing.TmpDir,
    /// Owns every `Result` and everything `read` returns, for the life of
    /// the world.
    arena: std.heap.ArenaAllocator,
    /// Absolute path of the binary under test (sentinel-terminated because
    /// `realPathFileAlloc` returns one, and `free` counts the sentinel).
    exe: [:0]u8,

    pub fn init(gpa: Allocator, io: Io) !World {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const exe = try Io.Dir.cwd().realPathFileAlloc(io, exe_relative, gpa);
        return .{
            .gpa = gpa,
            .io = io,
            .tmp = tmp,
            .arena = .init(gpa),
            .exe = exe,
        };
    }

    /// Remove the project tree and free every result.
    pub fn deinit(world: *World) void {
        world.tmp.cleanup();
        world.arena.deinit();
        world.gpa.free(world.exe);
        world.* = undefined;
    }

    /// Create `rel_path` (and its parents) with `contents`.
    pub fn write(world: *World, rel_path: []const u8, contents: []const u8) !void {
        if (std.fs.path.dirname(rel_path)) |dir| try world.tmp.dir.createDirPath(world.io, dir);
        try world.tmp.dir.writeFile(world.io, .{ .sub_path = rel_path, .data = contents });
    }

    /// Read a file from the project. Owned by the world.
    pub fn read(world: *World, rel_path: []const u8) ![]u8 {
        return world.tmp.dir.readFileAlloc(world.io, rel_path, world.arena.allocator(), .limited(max_stream_bytes));
    }

    pub fn exists(world: *World, rel_path: []const u8) bool {
        world.tmp.dir.access(world.io, rel_path, .{}) catch return false;
        return true;
    }

    /// Run `beni <args>` in the project directory with `--diagnostics=json`
    /// appended for `check`/`fmt`/`dump`, and parse stderr.
    pub fn run(world: *World, args: []const []const u8) !Result {
        return world.runWith(args, .{});
    }

    pub fn runWith(world: *World, args: []const []const u8, options: RunOptions) !Result {
        const arena = world.arena.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, world.exe);
        try argv.appendSlice(arena, args);
        const wants_json = !options.raw_diagnostics and args.len > 0 and
            (std.mem.eql(u8, args[0], "check") or std.mem.eql(u8, args[0], "fmt") or std.mem.eql(u8, args[0], "dump"));
        if (wants_json) try argv.append(arena, "--diagnostics=json");

        const cwd = options.cwd orelse std.process.Child.Cwd{ .dir = world.tmp.dir };
        var result = try spawnAndCapture(arena, world.gpa, world.io, argv.items, cwd);
        if (wants_json) {
            const trimmed = std.mem.trim(u8, result.stderr, " \r\n");
            if (trimmed.len != 0) {
                result.diagnostics = std.json.parseFromSliceLeaky([]diagnostic.Diagnostic, arena, trimmed, .{}) catch |err| {
                    std.debug.print("stderr is not a diagnostics array ({t}):\n{s}\n", .{ err, result.stderr });
                    return error.DiagnosticsNotJson;
                };
            }
        }
        return result;
    }
};

/// Spawn `argv` with an EMPTY environment, capture both streams to EOF
/// within `timeout_ms`, reap, and return everything. `arena` owns the
/// captured bytes.
pub fn spawnAndCapture(arena: Allocator, gpa: Allocator, io: Io, argv: []const []const u8, cwd: std.process.Child.Cwd) !Result {
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd,
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    // Whatever happens below, no process outlives this call.
    defer child.kill(io);

    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    try drain(arena, io, &child, &stdout, &stderr);

    const term = try child.wait(io);
    return .{
        .exit_code = switch (term) {
            .exited => |code| code,
            else => 255,
        },
        .term = term,
        .stdout = stdout.items,
        .stderr = stderr.items,
        .diagnostics = &.{},
    };
}

/// Read both pipes to EOF, multiplexed with `poll`, within the deadline.
/// A pipe that fills while the other is being read would block the child
/// forever; polling both is what prevents that.
fn drain(arena: Allocator, io: Io, child: *std.process.Child, stdout: *std.ArrayList(u8), stderr: *std.ArrayList(u8)) !void {
    const out_file = child.stdout.?;
    const err_file = child.stderr.?;
    var fds = [2]std.posix.pollfd{
        .{ .fd = out_file.handle, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = err_file.handle, .events = std.posix.POLL.IN, .revents = 0 },
    };
    const sinks = [2]*std.ArrayList(u8){ stdout, stderr };
    const files = [2]Io.File{ out_file, err_file };
    var open: u32 = 2;
    const deadline = Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(timeout_ms));
    var buf: [64 * 1024]u8 = undefined;

    while (open > 0) {
        const now = Io.Timestamp.now(io, .awake);
        const remaining_ms = now.durationTo(deadline).toMilliseconds();
        if (remaining_ms <= 0) {
            std.debug.print("compiler did not exit within {d} ms; killing it\n", .{timeout_ms});
            return error.CompilerTimeout;
        }
        _ = try std.posix.poll(&fds, @intCast(@min(remaining_ms, std.math.maxInt(i32))));
        for (&fds, 0..) |*pfd, i| {
            if (pfd.fd < 0 or pfd.revents == 0) continue;
            const n = files[i].readStreaming(io, &.{&buf}) catch 0;
            if (n == 0) {
                pfd.fd = -1; // EOF or error: stop polling this one
                open -= 1;
                continue;
            }
            if (sinks[i].items.len + n > max_stream_bytes) return error.StreamTooLong;
            try sinks[i].appendSlice(arena, buf[0..n]);
        }
    }
}
