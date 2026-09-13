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

/// Where the emitted JavaScript goes when a scenario does not say. Relative
/// to the world's project directory.
pub const default_out = "out";

/// The entry file `beni build` writes (boundary.md §5.2).
pub const entry_file = "out/main.mjs";

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
    /// Absolute path of the Node binary, resolved from the TEST process's
    /// `PATH` — which is the dev shell's, because that is what the build
    /// step inherits. Never a hardcoded `/usr/bin/node`: the flake pins
    /// Node 24 and the point of pinning it is that CI and a laptop agree.
    /// Null when nothing on `PATH` is called `node`, which a scenario
    /// reports rather than silently skipping.
    node_exe: ?[]const u8,

    pub fn init(gpa: Allocator, io: Io) !World {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const exe = try Io.Dir.cwd().realPathFileAlloc(io, exe_relative, gpa);
        errdefer gpa.free(exe);
        var world: World = .{
            .gpa = gpa,
            .io = io,
            .tmp = tmp,
            .arena = .init(gpa),
            .exe = exe,
            .node_exe = null,
        };
        world.node_exe = findOnPath(world.arena.allocator(), io, "node");
        return world;
    }

    pub const BuildAndRun = struct {
        build: Result,
        /// Null when the build failed, so nothing was run.
        program: ?Result,
    };

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

    /// Create an empty directory (and its parents). A project shape a
    /// scenario needs that `write` cannot make, because an empty directory
    /// holds no file.
    pub fn createDir(world: *World, rel_path: []const u8) !void {
        try world.tmp.dir.createDirPath(world.io, rel_path);
    }

    /// Create a symlink at `rel_path` pointing at `target` exactly as
    /// written (never resolved). The compiler's walk must not follow it —
    /// `dir/loop -> ..` is an infinite tree — so the scenarios that pin
    /// that rule need to be able to build one.
    pub fn symlink(world: *World, target: []const u8, rel_path: []const u8) !void {
        if (std.fs.path.dirname(rel_path)) |dir| try world.tmp.dir.createDirPath(world.io, dir);
        try world.tmp.dir.symLink(world.io, target, rel_path, .{});
    }

    /// Take away every permission on `rel_path` (chmod 000), so the
    /// compiler's read of it fails. Returns false when the file is still
    /// readable afterwards — running as root, or a filesystem that does
    /// not carry permissions — so a scenario can say so instead of
    /// asserting something the machine will not do.
    pub fn makeUnreadable(world: *World, rel_path: []const u8) !bool {
        try world.tmp.dir.setFilePermissions(world.io, rel_path, @enumFromInt(0), .{});
        _ = world.tmp.dir.readFileAlloc(world.io, rel_path, world.arena.allocator(), .limited(1)) catch return true;
        return false;
    }

    /// Read a file from the project. Owned by the world.
    pub fn read(world: *World, rel_path: []const u8) ![]u8 {
        return world.tmp.dir.readFileAlloc(world.io, rel_path, world.arena.allocator(), .limited(max_stream_bytes));
    }

    /// Every file under `rel_path`, recursively, as paths relative to it,
    /// sorted. Owned by the world. Empty when the directory does not exist,
    /// so a scenario asserting "nothing was written" reads the same as one
    /// asserting "these files were written".
    ///
    /// This is how a scenario makes a claim about the WHOLE output tree —
    /// "every emitted file is `.mjs`" is not a claim about any one file, and
    /// checking the files a test happens to name would let a new one slip
    /// through.
    pub fn listFiles(world: *World, rel_path: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        try world.collectFiles(rel_path, "", &out);
        std.mem.sort([]const u8, out.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
        return out.items;
    }

    fn collectFiles(world: *World, root: []const u8, prefix: []const u8, out: *std.ArrayList([]const u8)) !void {
        const arena = world.arena.allocator();
        const full = if (prefix.len == 0) root else try std.fs.path.join(arena, &.{ root, prefix });
        var dir = world.tmp.dir.openDir(world.io, full, .{ .iterate = true }) catch return;
        defer dir.close(world.io);
        var it = dir.iterate();
        while (try it.next(world.io)) |entry| {
            const rel = if (prefix.len == 0)
                try arena.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.name });
            switch (entry.kind) {
                .directory => try world.collectFiles(root, rel, out),
                .file => try out.append(arena, rel),
                else => {},
            }
        }
    }

    pub fn exists(world: *World, rel_path: []const u8) bool {
        world.tmp.dir.access(world.io, rel_path, .{}) catch return false;
        return true;
    }

    /// Run `beni <args>` in the project directory with `--diagnostics=json`
    /// appended for `build`/`check`/`fmt`/`dump`, and parse stderr.
    pub fn run(world: *World, args: []const []const u8) !Result {
        return world.runWith(args, .{});
    }

    /// Run `node <script>` in the project directory and capture everything.
    /// This is the write-tests skill's **second boundary**: the emitted
    /// program is the thing under test and what it printed is the
    /// assertion. A bug that changes emitted SHAPE but not behaviour must
    /// not fail here; a bug that changes behaviour must.
    pub fn node(world: *World, script: []const u8) !Result {
        const arena = world.arena.allocator();
        const exe = world.node_exe orelse return error.NodeNotOnPath;
        const argv = try arena.dupe([]const u8, &.{ exe, script });
        return spawnAndCapture(arena, world.gpa, world.io, argv, .{ .dir = world.tmp.dir });
    }

    /// `beni build --platform=node --out=out <paths>`, then `node out/main.mjs`.
    /// The whole second boundary in one call, because every `run/` fixture
    /// and every codegen scenario wants exactly this pair.
    ///
    /// `build` is always returned; `program` is null when the build did not
    /// exit 0, so a scenario asserts the compile before the run rather than
    /// reading a stale `out/`.
    pub fn buildAndRun(world: *World, args: []const []const u8) !BuildAndRun {
        const arena = world.arena.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ "build", "--platform=node", "--out=" ++ default_out });
        try argv.appendSlice(arena, args);
        const built = try world.runWith(argv.items, .{ .raw_diagnostics = true });
        if (built.exit_code != 0) return .{ .build = built, .program = null };
        return .{ .build = built, .program = try world.node(entry_file) };
    }

    pub fn runWith(world: *World, args: []const []const u8, options: RunOptions) !Result {
        const arena = world.arena.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, world.exe);
        try argv.appendSlice(arena, args);
        const wants_json = !options.raw_diagnostics and args.len > 0 and
            (std.mem.eql(u8, args[0], "build") or std.mem.eql(u8, args[0], "check") or
                std.mem.eql(u8, args[0], "fmt") or std.mem.eql(u8, args[0], "dump"));
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

/// The absolute path of `name` on the TEST process's `PATH`, or null. The
/// child sees an empty environment, so a bare `node` would not resolve
/// there; resolving it here is what makes the pinned toolchain's Node the
/// one that runs, whatever the child's environment is.
fn findOnPath(arena: Allocator, io: Io, name: []const u8) ?[]const u8 {
    const path = std.testing.environ.getAlloc(arena, "PATH") catch return null;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name }) catch return null;
        Io.Dir.cwd().access(io, candidate, .{}) catch continue;
        return candidate;
    }
    return null;
}

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
