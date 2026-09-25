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

/// The binary under test: `BENI_EXE` (absolute, or relative to the repo
/// root) when it is set and not empty, else `exe_relative`. Only
/// `test-pending-perf` sets it, to the ReleaseFast compiler its timing
/// scenarios measure
/// (`plans/checker-rewrite.md` §2.5); `build.zig` pins it EMPTY on every
/// other run, so a variable exported in a shell cannot point a gate at
/// another binary (S11).
pub fn exePath(arena: Allocator) []const u8 {
    const value = std.testing.environ.getAlloc(arena, "BENI_EXE") catch return exe_relative;
    return if (value.len == 0) exe_relative else value;
}

/// Where the emitted JavaScript goes when a scenario does not say. Relative
/// to the world's project directory.
pub const default_out = "out";

/// The entry file `beni build` writes: `Emit.default_entry_file` under
/// `default_out` (boundary.md §5.2, backend.md §2 rule 1). The leading `_`
/// is why `exists("out/_main.mjs")` is a question about the entry file and
/// not about a module called `Main` — on a case-insensitive file system
/// `exists("out/main.mjs")` could not tell them apart.
pub const entry_file = "out/_main.mjs";

/// Wall-clock bound on one compiler run, unless `RunOptions` raises it.
/// Generous: the point is to turn a hang into a failure, not to measure.
///
/// **It is wall clock and not cpu time, and that is a compromise** (queue row
/// 59). Wall clock cannot tell a hang from a run the scheduler parked: on
/// Apple Silicon a single-threaded process can land on an efficiency core,
/// and `check --jobs=1` over 5 000 empty modules was measured at 12.05,
/// 24.29, 26.11, 59.16 and 61.16 s for identical deterministic work — with
/// USER cpu itself varying 6.77 s to 16.22 s. A cpu-time bound would separate
/// the two, but reading a LIVE child's cpu time needs per-pid rusage
/// (`proc_pid_rusage` on macOS, `/proc/<pid>/stat` on Linux) and neither is
/// in std; `getrusage(RUSAGE_CHILDREN)` counts only children already reaped,
/// so it says nothing while the run is the thing being bounded. Rather than
/// carry two non-portable syscalls in a test harness, the bound stays wall
/// clock and the one case that needs more asks for more.
pub const default_timeout_ms: i64 = 60_000;

/// What a case gets when the thing being bounded is 5 000 files rather than a
/// program: five times the worst run ever measured, so that no scheduling
/// decision can reach it, and still a hang-detector. Raised from the default
/// with a number in hand (queue row 59) and not before.
pub const bulk_timeout_ms: i64 = 300_000;

/// Largest stream the harness keeps. Beyond it the run fails loudly rather
/// than silently truncating an assertion's input.
pub const max_stream_bytes = 64 * 1024 * 1024;

/// Whether a run killed at its bound says so on stderr. The pending walker
/// turns it off: there a timeout is an expected, recorded red signature, and
/// the line would be noise beside its own report.
pub var announce_timeouts: bool = true;

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
    /// The child's CPU time, user + system, in milliseconds, from the
    /// `rusage` `wait4` reports; null where the platform gives none. A
    /// timing assertion reads THIS and not the wall clock: a concurrent build
    /// on the same machine stretches wall time without adding a microsecond
    /// of the child's own work (`plans/checker-rewrite.md` §2.5).
    cpu_ms: ?i64 = null,
};

pub const RunOptions = struct {
    /// Leave stderr alone: no `--diagnostics=json` is added and nothing is
    /// parsed. For scenarios that assert the text renderer or usage errors.
    raw_diagnostics: bool = false,
    /// Where the child runs. Default: the world's project directory.
    cwd: ?std.process.Child.Cwd = null,
    /// Wall-clock bound on this run. Raise it only for a case whose INPUT is
    /// large enough that the default is measuring the machine rather than
    /// catching a hang — see `bulk_timeout_ms`.
    timeout_ms: i64 = default_timeout_ms,
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
        const exe = exe: {
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            break :exe try Io.Dir.cwd().realPathFileAlloc(io, exePath(scratch.allocator()), gpa);
        };
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

    /// Copy every file under `src_path` — a directory RELATIVE TO THE REPO
    /// ROOT — into the project at the same relative layout, skipping names
    /// that start with `skip_prefix` at any level.
    ///
    /// A corpus fixture that is a whole project is more than its `.beni`
    /// files: `build/bad/` fixtures carry a platform package, which is a
    /// manifest, modules and their sibling `.js`. Naming the files a
    /// scenario expects would let a new one slip through, so the whole tree
    /// is copied and the fixture directory IS the project.
    pub fn copyTree(world: *World, src_path: []const u8, skip_prefix: []const u8) !void {
        const arena = world.arena.allocator();
        var dir = try Io.Dir.cwd().openDir(world.io, src_path, .{ .iterate = true });
        defer dir.close(world.io);
        var walker = try dir.walk(world.gpa);
        defer walker.deinit();
        while (try walker.next(world.io)) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.startsWith(u8, entry.basename, skip_prefix)) continue;
            const from = try std.fs.path.join(arena, &.{ src_path, entry.path });
            const bytes = try Io.Dir.cwd().readFileAlloc(world.io, from, arena, .limited(max_stream_bytes));
            try world.write(entry.path, bytes);
        }
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

    /// Take write permission off a DIRECTORY (chmod 555), so the compiler
    /// can open it and cannot create anything inside it. Returns false when
    /// it is still writable afterwards — running as root, or a filesystem
    /// that does not carry permissions — so a scenario can say so instead of
    /// asserting something the machine will not do.
    ///
    /// The read-only-cache-directory scenarios need exactly this shape: the
    /// directory exists, so it is not the usage failure, and every write
    /// inside it fails, which is the silent path.
    pub fn makeDirUnwritable(world: *World, rel_path: []const u8) !bool {
        try world.tmp.dir.setFilePermissions(world.io, rel_path, @enumFromInt(0o555), .{});
        var probe: [64]u8 = undefined;
        const inside = try std.fmt.bufPrint(&probe, "{s}/probe", .{rel_path});
        world.tmp.dir.writeFile(world.io, .{ .sub_path = inside, .data = "x" }) catch return true;
        return false;
    }

    /// Undo `makeDirUnwritable`. **Every caller must `defer` this**, and not
    /// for tidiness: `deinit`'s cleanup cannot unlink anything inside a 0555
    /// directory, so a scenario that leaves one leaves a tree behind in
    /// `.zig-cache/tmp/` that `git worktree remove` then refuses to delete.
    /// Silent on failure, because a test that already failed must not fail
    /// again on the way out.
    pub fn restoreDirMode(world: *World, rel_path: []const u8) void {
        world.tmp.dir.setFilePermissions(world.io, rel_path, @enumFromInt(0o755), .{}) catch {};
    }

    /// Make `rel_path` executable (chmod 755), so a scenario can point a
    /// harness script at a stand-in for the compiler. `write` creates a
    /// plain data file, and a harness that takes a `--beni=<path>` checks
    /// the executable bit before it runs anything.
    pub fn makeExecutable(world: *World, rel_path: []const u8) !void {
        try world.tmp.dir.setFilePermissions(world.io, rel_path, @enumFromInt(0o755), .{});
    }

    /// The absolute path of the project directory: the SAME directory the
    /// child's cwd is, spelled the other way. A scenario that pins "`.` and
    /// `$PWD` are the same project" needs both spellings, and no scenario
    /// may hardcode one — the world is a fresh temporary directory.
    pub fn projectPath(world: *World) ![]const u8 {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const n = try world.tmp.dir.realPath(world.io, &buffer);
        return world.arena.allocator().dupe(u8, buffer[0..n]);
    }

    /// The POSIX permission bits of `rel_path`, following symlinks — the
    /// file-type bits `Stat.permissions` also carries are masked off. `fmt`
    /// rewrites the user's files in place, so "the file came back with the
    /// mode it had" is a claim about an output and belongs in this harness.
    pub fn mode(world: *World, rel_path: []const u8) !u32 {
        const stat = try world.tmp.dir.statFile(world.io, rel_path, .{});
        return @as(u32, @intCast(@intFromEnum(stat.permissions))) & 0o7777;
    }

    /// Set the mode bits of `rel_path`. Returns false when the filesystem
    /// did not take them (a mount without permissions, or root), so a
    /// scenario says so instead of asserting what the machine will not do.
    pub fn setMode(world: *World, rel_path: []const u8, bits: u32) !bool {
        try world.tmp.dir.setFilePermissions(world.io, rel_path, @enumFromInt(bits), .{});
        return try world.mode(rel_path) == bits;
    }

    /// The file kind of `rel_path` WITHOUT following a symlink, so a
    /// scenario can tell a link from the file that replaced it.
    pub fn kind(world: *World, rel_path: []const u8) !std.Io.File.Kind {
        const stat = try world.tmp.dir.statFile(world.io, rel_path, .{ .follow_symlinks = false });
        return stat.kind;
    }

    /// What the symlink at `rel_path` points at, exactly as written. Owned
    /// by the world.
    pub fn readLink(world: *World, rel_path: []const u8) ![]const u8 {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const n = try world.tmp.dir.readLink(world.io, rel_path, &buffer);
        return world.arena.allocator().dupe(u8, buffer[0..n]);
    }

    /// The last-modified time of `rel_path` in nanoseconds: what a "nothing
    /// to do, so nothing was touched" claim compares.
    pub fn mtime(world: *World, rel_path: []const u8) !i96 {
        const stat = try world.tmp.dir.statFile(world.io, rel_path, .{});
        return stat.mtime.nanoseconds;
    }

    /// The link count of `rel_path`: how many names the file has.
    pub fn linkCount(world: *World, rel_path: []const u8) !u64 {
        const stat = try world.tmp.dir.statFile(world.io, rel_path, .{});
        return @intCast(stat.nlink);
    }

    /// Give `rel_path` a second name in the same directory (a hard link).
    pub fn hardLink(world: *World, rel_path: []const u8, new_path: []const u8) !void {
        try world.tmp.dir.hardLink(rel_path, world.tmp.dir, new_path, world.io, .{});
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

    /// The absolute path of `rel_path` inside the project — `projectPath`
    /// joined with a sub-path, for the scenarios that run the compiler
    /// against the SAME tree spelled two ways: a relative path from the
    /// project directory and an absolute one from somewhere else.
    pub fn projectSubPath(world: *World, allocator: Allocator, rel_path: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &.{ try world.projectPath(), rel_path });
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
        return world.nodeWith(script, default_timeout_ms);
    }

    /// `node` with its own wall-clock bound, for a caller that bounds the
    /// compiler differently too (the corpus walker's `BENI_CASE_TIMEOUT_MS`).
    pub fn nodeWith(world: *World, script: []const u8, timeout_ms: i64) !Result {
        const arena = world.arena.allocator();
        const exe = world.node_exe orelse return error.NodeNotOnPath;
        const argv = try arena.dupe([]const u8, &.{ exe, script });
        return spawnAndCapture(arena, world.gpa, world.io, argv, .{ .dir = world.tmp.dir }, timeout_ms);
    }

    /// `beni build --platform=node --out=out <paths>`, then `node out/_main.mjs`.
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
        var result = try spawnAndCapture(arena, world.gpa, world.io, argv.items, cwd, options.timeout_ms);
        if (wants_json) {
            const trimmed = std.mem.trim(u8, result.stderr, " \r\n");
            if (trimmed.len != 0) {
                result.diagnostics = std.json.parseFromSliceLeaky([]diagnostic.Diagnostic, arena, trimmed, .{}) catch |err| {
                    std.debug.print("stderr is not a diagnostics array ({t}):\n{s}\n", .{ err, result.stderr });
                    return error.DiagnosticsNotJson;
                };
            }
        }
        // `backend.md` §2's guarantee, asserted after every build the suite
        // makes rather than in a scenario of its own (see the function).
        if (options.cwd == null and result.exit_code == 0 and
            args.len != 0 and std.mem.eql(u8, args[0], "build"))
        {
            try world.checkOutputPathFolding(args);
        }
        return result;
    }

    /// **A build's output is the same set of files on every file system**
    /// (`backend.md` §2, *The output tree does not depend on the file
    /// system's case sensitivity*). Two written paths equal under ASCII
    /// case folding break that: on APFS and NTFS they are ONE file, the
    /// second write wins, and the build still exits 0.
    ///
    /// It is checked here, on every successful `build`, and not in a
    /// scenario of its own, because **the defect is invisible where it
    /// bites**. On a case-insensitive file system the two files already
    /// collapsed into one, so a directory listing sees nothing wrong and
    /// only the emitted program misbehaves — which is how `main.mjs`
    /// against a module `Main`'s `Main.mjs` survived every green Linux run
    /// until someone built on a Mac (queue row 58). On a case-SENSITIVE
    /// file system both files are there and this fires. That is the whole
    /// value: a Linux run catching a defect only a Mac can suffer, for one
    /// directory listing per build.
    fn checkOutputPathFolding(world: *World, args: []const []const u8) !void {
        var out_dir: []const u8 = default_out;
        for (args) |a| {
            if (std.mem.startsWith(u8, a, "--out=")) out_dir = a["--out=".len..];
        }
        // An absolute `--out` is outside the project directory and
        // `listFiles` reads relative to it; those scenarios assert their own
        // tree.
        if (out_dir.len == 0 or out_dir[0] == '/') return;

        const arena = world.arena.allocator();
        const files = try world.listFiles(out_dir);
        const Entry = struct { folded: []const u8, written: []const u8 };
        const entries = try arena.alloc(Entry, files.len);
        for (files, entries) |written, *slot| {
            const folded = try arena.dupe(u8, written);
            for (folded) |*c| c.* = std.ascii.toLower(c.*);
            slot.* = .{ .folded = folded, .written = written };
        }
        std.mem.sort(Entry, entries, {}, struct {
            fn lessThan(_: void, x: Entry, y: Entry) bool {
                return std.mem.lessThan(u8, x.folded, y.folded);
            }
        }.lessThan);
        for (1..entries.len) |i| {
            if (!std.mem.eql(u8, entries[i - 1].folded, entries[i].folded)) continue;
            std.debug.print(
                \\two output paths are equal under ASCII case folding, so they are ONE
                \\file on macOS (APFS) and Windows (NTFS):
                \\
                \\  {s}/{s}
                \\  {s}/{s}
                \\
                \\`backend.md` §2: a build's output is the same set of files on every
                \\file system. The compiler must refuse this build with
                \\`output_path_collision`, or not produce the pair at all.
                \\
            , .{ out_dir, entries[i - 1].written, out_dir, entries[i].written });
            return error.OutputPathsCollide;
        }
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
pub fn spawnAndCapture(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    argv: []const []const u8,
    cwd: std.process.Child.Cwd,
    timeout_ms: i64,
) !Result {
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd,
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .request_resource_usage_statistics = true,
    });
    // Whatever happens below, no process outlives this call.
    defer child.kill(io);

    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    try drain(arena, io, &child, &stdout, &stderr, timeout_ms);

    const term = try child.wait(io);
    const cpu_ms: ?i64 = if (comptime @TypeOf(child.resource_usage_statistics.rusage) == ?std.posix.rusage) cpu: {
        const ru = child.resource_usage_statistics.rusage orelse break :cpu null;
        const us = (@as(i64, ru.utime.sec) + @as(i64, ru.stime.sec)) * 1_000_000 + @as(i64, ru.utime.usec) + @as(i64, ru.stime.usec);
        break :cpu @divTrunc(us, 1000);
    } else null;
    return .{
        .cpu_ms = cpu_ms,
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
fn drain(
    arena: Allocator,
    io: Io,
    child: *std.process.Child,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    timeout_ms: i64,
) !void {
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
            if (announce_timeouts) std.debug.print("compiler did not exit within {d} ms; killing it\n", .{timeout_ms});
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

/// The two lists `tests/pending/` keeps beside its fixtures
/// (`plans/checker-rewrite.md` §2.4, §2.6), read by the corpus walker in
/// pending mode and by `pending_test.zig`'s scenarios, so both apply rules
/// (c) and (d) to the same records.
pub const pending = struct {
    /// One line of `tests/pending/RED`: the red signature a fixture (a
    /// repo-relative path) or a scenario (`scenario/<id>`) has under a checker.
    pub const RedLine = struct { path: []const u8, checker: []const u8, signature: []const u8 };

    /// `<root>/CLAIMED`: one repo-relative path (or `scenario/<id>`) per line;
    /// `#` lines and blank lines are ignored. A missing file is empty.
    pub fn readClaimed(arena: Allocator, io: Io, root: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var it = try lines(arena, io, root, "CLAIMED");
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const path = std.mem.trimEnd(u8, line, "/");
            for (out.items) |seen| if (std.mem.eql(u8, seen, path)) {
                std.debug.print("{s}/CLAIMED lists {s} twice\n", .{ root, path });
                return error.DuplicateClaim;
            };
            try out.append(arena, path);
        }
        return out.items;
    }

    /// `<root>/RED`: `<path> <checker> <signature…>` per line, the signature
    /// running to the end of the line; `#` lines and blank lines are
    /// ignored. A missing file is empty.
    pub fn readRed(arena: Allocator, io: Io, root: []const u8) ![]const RedLine {
        var out: std.ArrayList(RedLine) = .empty;
        var it = try lines(arena, io, root, "RED");
        while (it.next()) |raw| {
            var rest = std.mem.trim(u8, raw, " \t\r");
            if (rest.len == 0 or rest[0] == '#') continue;
            const path = try word(&rest);
            const checker = try word(&rest);
            const signature = std.mem.trim(u8, rest, " \t");
            if (signature.len == 0) return error.BadRedLine;
            const entry: RedLine = .{ .path = std.mem.trimEnd(u8, path, "/"), .checker = checker, .signature = signature };
            // A second line for the same fixture and checker would make one of
            // the two silently unread: a malformed file, not a choice.
            for (out.items) |seen| if (std.mem.eql(u8, seen.path, entry.path) and std.mem.eql(u8, seen.checker, entry.checker)) {
                std.debug.print("{s}/RED has two lines for {s} under {s}\n", .{ root, entry.path, entry.checker });
                return error.DuplicateRedLine;
            };
            try out.append(arena, entry);
        }
        return out.items;
    }

    /// `<root>/v2-green.txt` (`plans/checker-rewrite.md` §2.4, S12): the
    /// corpus fixtures a landed slice made green under `--checker=v2`, one
    /// repo-relative path per line; `#` lines and blank lines are ignored.
    /// `test-v2`'s ratchet fails when one of them is red.
    pub fn readV2Green(arena: Allocator, io: Io, root: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var it = try lines(arena, io, root, "v2-green.txt");
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const path = std.mem.trimEnd(u8, line, "/");
            for (out.items) |seen| if (std.mem.eql(u8, seen, path)) {
                std.debug.print("{s}/v2-green.txt lists {s} twice\n", .{ root, path });
                return error.DuplicateGreen;
            };
            try out.append(arena, path);
        }
        return out.items;
    }

    /// `<root>/v2-expected.md` (`plans/checker-rewrite.md` §2.4,
    /// `checker-v2.md` §22.1): the corpus fixtures `test-v2` skips. Every
    /// list item whose text starts with a back-quoted path — "- `<path>` …"
    /// — is an entry; a path ending in `/` names every fixture under that
    /// directory. Everything else in the file is prose.
    pub fn readV2Expected(arena: Allocator, io: Io, root: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var it = try lines(arena, io, root, "v2-expected.md");
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, "- `")) continue;
            const rest = line["- `".len..];
            const end = std.mem.indexOfScalar(u8, rest, '`') orelse return error.BadExpectedLine;
            const path = rest[0..end];
            if (path.len == 0) return error.BadExpectedLine;
            for (out.items) |seen| if (std.mem.eql(u8, seen, path)) {
                std.debug.print("{s}/v2-expected.md lists {s} twice\n", .{ root, path });
                return error.DuplicateExpected;
            };
            try out.append(arena, path);
        }
        return out.items;
    }

    /// Whether `v2-expected.md`'s `entries` cover the fixture at `path`: the
    /// same path, or a directory entry (ending in `/`) above it.
    pub fn expectedCovers(entries: []const []const u8, path: []const u8) bool {
        for (entries) |entry| {
            if (std.mem.endsWith(u8, entry, "/")) {
                if (std.mem.startsWith(u8, path, entry)) return true;
            } else if (std.mem.eql(u8, entry, std.mem.trimEnd(u8, path, "/"))) return true;
        }
        return false;
    }

    fn lines(arena: Allocator, io: Io, root: []const u8, name: []const u8) !std.mem.SplitIterator(u8, .scalar) {
        const path = try std.fs.path.join(arena, &.{ root, name });
        const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_stream_bytes)) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
        return std.mem.splitScalar(u8, text, '\n');
    }

    fn word(rest: *[]const u8) ![]const u8 {
        const s = std.mem.trimStart(u8, rest.*, " \t");
        if (s.len == 0) return error.BadRedLine;
        const end = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
        rest.* = s[end..];
        return s[0..end];
    }
};
