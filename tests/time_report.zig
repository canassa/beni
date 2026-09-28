//! Where the test suites spend their time: `zig build test-time-report`.
//!
//!   time-report run    [--records=DIR] [--out=FILE] [--top=N] -- <command…>
//!   time-report render [--records=DIR] [--out=FILE] [--top=N]
//!
//! `run` measures the machine (CPU model, load average, a bare `node -e 0`),
//! empties the records directory, runs the command with
//! `BENI_TEST_TIMING=<records>` so that every test process under it records
//! itself (`timing.zig`), measures the command's own wall and CPU time (its
//! whole process tree), writes `run.json` beside the records, and renders.
//! `render` renders the records of an earlier run again, with no suite run.
//!
//! The report replaces the text between `<!-- test-time-report:begin -->` and
//! `<!-- test-time-report:end -->` in `--out` (default
//! `plans/test-time-report.md`), so the hand-written analysis around it
//! stays; a file without the markers gets the block appended, and `--out=-`
//! prints it. The records default to `zig-out/test-timing/`.
//!
//! Exits with the command's exit code, after rendering what was recorded.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const timing = @import("timing.zig");
const aggregate = @import("time_report/aggregate.zig");

pub const begin_marker = "<!-- test-time-report:begin -->";
pub const end_marker = "<!-- test-time-report:end -->";

const usage =
    \\usage: time-report run    [--records=DIR] [--out=FILE] [--top=N] -- <command...>
    \\       time-report render [--records=DIR] [--out=FILE] [--top=N]
    \\
;

/// How many `node -e 0` runs measure Node's start-up.
const node_probe_runs = 9;

const Options = struct {
    records: []const u8 = "zig-out/test-timing",
    out: []const u8 = "plans/test-time-report.md",
    top: usize = 40,
    command: []const []const u8 = &.{},
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        try stderr.writeAll(usage);
        return 2;
    }
    var options: Options = .{};
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            options.command = args[i + 1 ..];
            break;
        } else if (std.mem.startsWith(u8, arg, "--records=")) {
            options.records = arg["--records=".len..];
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
            options.out = arg["--out=".len..];
        } else if (std.mem.startsWith(u8, arg, "--top=")) {
            options.top = std.fmt.parseUnsigned(usize, arg["--top=".len..], 10) catch {
                try stderr.print("time-report: bad --top: {s}\n", .{arg});
                return 2;
            };
        } else {
            try stderr.print("time-report: unknown argument {s}\n{s}", .{ arg, usage });
            return 2;
        }
    }

    if (std.mem.eql(u8, args[1], "run")) {
        if (options.command.len == 0) {
            try stderr.print("time-report run: no command after --\n{s}", .{usage});
            return 2;
        }
        const meta = try runCommand(arena, io, init.environ_map, options, stderr);
        try renderTo(arena, io, options, meta, stderr);
        if (meta.exit != 0) {
            try stderr.print("time-report: `{s}` exited {d}; the report covers what ran\n", .{ options.command[0], meta.exit });
            return 1;
        }
        return 0;
    } else if (std.mem.eql(u8, args[1], "render")) {
        const meta = readMeta(arena, io, options.records) catch |err| switch (err) {
            error.FileNotFound => aggregate.Meta{},
            else => return err,
        };
        try renderTo(arena, io, options, meta, stderr);
        return 0;
    }
    try stderr.print("time-report: unknown command {s}\n{s}", .{ args[1], usage });
    return 2;
}

/// Run `options.command` with timing on, and measure around it.
fn runCommand(arena: Allocator, io: Io, parent_env: *const std.process.Environ.Map, options: Options, stderr: *Io.Writer) !aggregate.Meta {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, options.records);
    try clearRecords(arena, io, options.records);
    const records_abs = try cwd.realPathFileAlloc(io, options.records, arena);

    var meta: aggregate.Meta = .{
        .command = options.command,
        .cpu_model = cpuModel(arena, io),
        .threads = @intCast(std.Thread.getCpuCount() catch 0),
    };
    try probeNode(arena, io, parent_env, &meta);
    meta.load_start = loadAverage(arena, io);
    meta.started_unix_s = @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));

    var env = try parent_env.clone(arena);
    try env.put(timing.env_var, records_abs);
    // The command reports its own progress to the terminal, not to a
    // progress pipe this process was handed.
    _ = env.swapRemove("ZIG_PROGRESS");

    try stderr.print("time-report: running `{s}` with {s}={s}\n", .{ options.command[0], timing.env_var, records_abs });
    try stderr.flush();
    const started = Io.Clock.awake.now(io);
    var child = try std.process.spawn(io, .{
        .argv = options.command,
        .environ_map = &env,
        .request_resource_usage_statistics = true,
    });
    const term = try child.wait(io);
    meta.wall_us = timing.durationUs(started.durationTo(Io.Clock.awake.now(io)));
    meta.load_end = loadAverage(arena, io);
    meta.exit = switch (term) {
        .exited => |code| code,
        else => -1,
    };
    if (comptime @TypeOf(child.resource_usage_statistics.rusage) == ?std.posix.rusage) {
        if (child.resource_usage_statistics.rusage) |ru| {
            const used = timing.fromRusage(ru);
            meta.user_us = used.user_us;
            meta.sys_us = used.sys_us;
        }
    }

    const json = try std.json.Stringify.valueAlloc(arena, meta, .{ .whitespace = .indent_2 });
    const meta_path = try std.fs.path.join(arena, &.{ options.records, "run.json" });
    try cwd.writeFile(io, .{ .sub_path = meta_path, .data = json });
    return meta;
}

/// Delete what an earlier run left: every record file and `run.json`.
/// Nothing else in the directory is touched.
fn clearRecords(arena: Allocator, io: Io, records: []const u8) !void {
    var dir = try Io.Dir.cwd().openDir(io, records, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".jsonl") or std.mem.eql(u8, entry.name, "run.json")) {
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
    }
    for (names.items) |name| try dir.deleteFile(io, name);
}

fn readMeta(arena: Allocator, io: Io, records: []const u8) !aggregate.Meta {
    const path = try std.fs.path.join(arena, &.{ records, "run.json" });
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
    return std.json.parseFromSliceLeaky(aggregate.Meta, arena, bytes, .{ .ignore_unknown_fields = true });
}

/// Every record file of `records`, parsed, in a stable order.
fn readProcesses(arena: Allocator, io: Io, records: []const u8) ![]aggregate.Process {
    var dir = try Io.Dir.cwd().openDir(io, records, .{ .iterate = true });
    defer dir.close(io);
    var processes: std.ArrayList(aggregate.Process) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const bytes = try dir.readFileAlloc(io, entry.name, arena, .unlimited);
        const process = aggregate.parseProcess(arena, bytes) catch |err| {
            std.debug.print("time-report: {s}/{s}: {t}\n", .{ records, entry.name, err });
            return err;
        };
        try processes.append(arena, process);
    }
    aggregate.sortProcesses(processes.items);
    return processes.items;
}

fn renderTo(arena: Allocator, io: Io, options: Options, meta: aggregate.Meta, stderr: *Io.Writer) !void {
    const processes = try readProcesses(arena, io, options.records);
    var block: Io.Writer.Allocating = .init(arena);
    try block.writer.writeAll("<!-- Generated by `zig build test-time-report`; edits between the markers are overwritten. -->\n\n");
    try aggregate.render(arena, &block.writer, meta, processes, .{ .top = options.top });
    if (std.mem.eql(u8, options.out, "-")) {
        var stdout_writer = Io.File.stdout().writer(io, &.{});
        try stdout_writer.interface.writeAll(block.written());
        return;
    }
    const cwd = Io.Dir.cwd();
    const old = cwd.readFileAlloc(io, options.out, arena, .limited(1 << 24)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    try cwd.writeFile(io, .{ .sub_path = options.out, .data = try splice(arena, old, block.written()) });
    try stderr.print("time-report: {d} test processes; wrote {s}\n", .{ processes.len, options.out });
}

/// `document` with the text between the markers replaced by `block`, or
/// with the marked block appended when it has no markers.
pub fn splice(arena: Allocator, document: []const u8, block: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, document, begin_marker)) |b| {
        if (std.mem.indexOfPos(u8, document, b, end_marker)) |e| {
            return std.mem.concat(arena, u8, &.{ document[0 .. b + begin_marker.len], "\n", block, document[e..] });
        }
    }
    const sep: []const u8 = if (document.len == 0) "" else if (std.mem.endsWith(u8, document, "\n")) "\n" else "\n\n";
    return std.mem.concat(arena, u8, &.{ document, sep, begin_marker, "\n", block, end_marker, "\n" });
}

/// The first `model name` of `/proc/cpuinfo`, or empty where there is none.
fn cpuModel(arena: Allocator, io: Io) []const u8 {
    const text = readProc(arena, io, "/proc/cpuinfo") orelse return "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "model name")) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return "";
}

/// The whole of a `/proc` file, or null where there is none. Read as a
/// stream: `/proc` reports a size of zero.
fn readProc(arena: Allocator, io: Io, path: []const u8) ?[]const u8 {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(arena, .limited(1 << 22)) catch null;
}

/// `/proc/loadavg`'s three averages, or null where there is none.
fn loadAverage(arena: Allocator, io: Io) ?[3]f64 {
    const text = readProc(arena, io, "/proc/loadavg") orelse return null;
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    var out: [3]f64 = undefined;
    for (&out) |*v| v.* = std.fmt.parseFloat(f64, words.next() orelse return null) catch return null;
    return out;
}

/// The median CPU and wall time of a bare `node -e 0`, when Node is on
/// `PATH`: what one Node run costs before it loads anything.
fn probeNode(arena: Allocator, io: Io, env: *const std.process.Environ.Map, meta: *aggregate.Meta) !void {
    const path = env.get("PATH") orelse return;
    const node = found: {
        var dirs = std.mem.splitScalar(u8, path, ':');
        while (dirs.next()) |dir| {
            if (dir.len == 0) continue;
            const candidate = try std.fs.path.join(arena, &.{ dir, "node" });
            Io.Dir.cwd().access(io, candidate, .{}) catch continue;
            break :found candidate;
        }
        return;
    };
    var cpu: [node_probe_runs]u64 = undefined;
    var wall: [node_probe_runs]u64 = undefined;
    for (&cpu, &wall) |*c, *w| {
        const started = Io.Clock.awake.now(io);
        var child = try std.process.spawn(io, .{
            .argv = &.{ node, "-e", "0" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .request_resource_usage_statistics = true,
        });
        _ = try child.wait(io);
        w.* = timing.durationUs(started.durationTo(Io.Clock.awake.now(io)));
        c.* = 0;
        if (comptime @TypeOf(child.resource_usage_statistics.rusage) == ?std.posix.rusage) {
            if (child.resource_usage_statistics.rusage) |ru| {
                const used = timing.fromRusage(ru);
                c.* = used.user_us + used.sys_us;
            }
        }
    }
    std.mem.sort(u64, &cpu, {}, std.sort.asc(u64));
    std.mem.sort(u64, &wall, {}, std.sort.asc(u64));
    meta.node_probe_runs = node_probe_runs;
    meta.node_startup_cpu_us = cpu[node_probe_runs / 2];
    meta.node_startup_wall_us = wall[node_probe_runs / 2];
}

test {
    _ = aggregate;
}

test "the block replaces the text between the markers and nothing else" {
    const arena_state = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(arena_state);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "# Title\n\nprose\n" ++ begin_marker ++ "\nNEW\n" ++ end_marker ++ "\nafter\n",
        try splice(a, "# Title\n\nprose\n" ++ begin_marker ++ "\nOLD\nOLDER\n" ++ end_marker ++ "\nafter\n", "NEW\n"),
    );
    try std.testing.expectEqualStrings(
        "# Title\n\n" ++ begin_marker ++ "\nNEW\n" ++ end_marker ++ "\n",
        try splice(a, "# Title\n", "NEW\n"),
    );
    try std.testing.expectEqualStrings(
        begin_marker ++ "\nNEW\n" ++ end_marker ++ "\n",
        try splice(a, "", "NEW\n"),
    );
}
