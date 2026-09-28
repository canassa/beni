//! Which lines of the compiler the black-box tests execute: `zig build
//! coverage`.
//!
//!   coverage --kcov=K --src=S --raw=R --out=O [--top=N] -- <command...>
//!   coverage --kcov=K --src=S --raw=R --out=O [--top=N] --report-only
//!
//! The first form empties `R` and `O`, runs the command (a child `zig build
//! coverage-run`, whose every `beni` process spawned by the black-box suites
//! and the corpus leaves kcov's counts in a directory of its own under
//! `R`; the unit tests do not run), measures its wall and CPU
//! time, then merges whatever was collected — also when a test failed —
//! into `O` with `kcov --merge`: HTML at `O/index.html`, Cobertura XML at
//! `O/kcov-merged/cobertura.xml`. `--report-only` merges and reports what
//! `R` holds without running anything (`zig build coverage --
//! --report-only`; the command, which the build step always passes, is then
//! ignored).
//!
//! The summary it prints, and writes with the per-file table to
//! `O/summary.md`, counts the compiler's lines only: a file named
//! `*_test.zig` and the lines of every `test` block are the tests
//! themselves, so they are left out of every figure. The compiler binary
//! compiles none of them, so this matters only when `R` holds counts from
//! some other binary.
//!
//! A covered line is one that ran, not one whose effect a test checked.
//!
//! Exits with the command's exit code, after reporting what was collected.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const usage =
    \\usage: coverage --kcov=K --src=S --raw=R --out=O [--top=N] -- <command...>
    \\       coverage --kcov=K --src=S --raw=R --out=O [--top=N] --report-only
    \\
;

const Options = struct {
    kcov: []const u8 = "",
    src: []const u8 = "",
    raw: []const u8 = "",
    out: []const u8 = "",
    /// How many files the "most uncovered" list names.
    top: usize = 10,
    report_only: bool = false,
    command: []const []const u8 = &.{},
};

/// What was measured around the command.
const Measured = struct {
    wall_us: u64 = 0,
    cpu_us: u64 = 0,
    load_start: ?[3]f64 = null,
    load_end: ?[3]f64 = null,
    exit: i32 = 0,
    ran: bool = false,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    var options: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            options.command = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, arg, "--report-only")) {
            options.report_only = true;
        } else if (value(arg, "--kcov=")) |v| {
            options.kcov = v;
        } else if (value(arg, "--src=")) |v| {
            options.src = v;
        } else if (value(arg, "--raw=")) |v| {
            options.raw = v;
        } else if (value(arg, "--out=")) |v| {
            options.out = v;
        } else if (value(arg, "--top=")) |v| {
            options.top = std.fmt.parseUnsigned(usize, v, 10) catch {
                try stderr.print("coverage: bad --top: {s}\n", .{arg});
                return 2;
            };
        } else {
            try stderr.print("coverage: unknown argument {s}\n{s}", .{ arg, usage });
            return 2;
        }
    }
    if (options.kcov.len == 0 or options.src.len == 0 or options.raw.len == 0 or options.out.len == 0 or
        (options.command.len == 0 and !options.report_only))
    {
        try stderr.writeAll(usage);
        return 2;
    }

    const cwd = Io.Dir.cwd();
    var measured: Measured = .{};
    if (!options.report_only) {
        try cwd.deleteTree(io, options.raw);
        try cwd.createDirPath(io, options.raw);
        measured = try runCommand(arena, io, init.environ_map, options, stderr);
    }

    try cwd.deleteTree(io, options.out);
    const collected = try merge(arena, io, options, stderr);
    if (collected == 0) {
        try stderr.print("coverage: nothing was collected under {s}\n", .{options.raw});
        return if (measured.exit != 0) 1 else 2;
    }
    const files = try readCobertura(arena, io, options);
    const markdown = try render(arena, files, measured, collected, options);
    const summary_path = try std.fs.path.join(arena, &.{ options.out, "summary.md" });
    try cwd.writeFile(io, .{ .sub_path = summary_path, .data = markdown.full });
    try stderr.writeAll(markdown.terminal);
    try stderr.print("coverage: HTML at {s}/index.html, per-file table at {s}\n", .{ options.out, summary_path });

    if (measured.exit != 0) {
        try stderr.print("coverage: `{s}` exited {d}; the report covers what ran\n", .{ options.command[0], measured.exit });
        return 1;
    }
    return 0;
}

fn value(arg: []const u8, comptime prefix: []const u8) ?[]const u8 {
    return if (std.mem.startsWith(u8, arg, prefix)) arg[prefix.len..] else null;
}

/// Run the command with the terminal as its output, and measure it.
fn runCommand(arena: Allocator, io: Io, parent_env: *const std.process.Environ.Map, options: Options, stderr: *Io.Writer) !Measured {
    var measured: Measured = .{ .ran = true, .load_start = loadAverage(arena, io) };
    var env = try parent_env.clone(arena);
    // The command reports its own progress to the terminal, not to a
    // progress pipe this process was handed.
    _ = env.swapRemove("ZIG_PROGRESS");

    try stderr.print("coverage: running `{s}` with every compiler under kcov\n", .{try std.mem.join(arena, " ", options.command)});
    try stderr.flush();
    const started = Io.Clock.awake.now(io);
    var child = try std.process.spawn(io, .{
        .argv = options.command,
        .environ_map = &env,
        .request_resource_usage_statistics = true,
    });
    const term = try child.wait(io);
    measured.wall_us = durationUs(started.durationTo(Io.Clock.awake.now(io)));
    measured.load_end = loadAverage(arena, io);
    measured.exit = switch (term) {
        .exited => |code| code,
        else => -1,
    };
    if (comptime @TypeOf(child.resource_usage_statistics.rusage) == ?std.posix.rusage) {
        if (child.resource_usage_statistics.rusage) |ru| {
            measured.cpu_us = tvUs(ru.utime) + tvUs(ru.stime);
        }
    }
    return measured;
}

fn tvUs(tv: std.posix.timeval) u64 {
    return @as(u64, @intCast(tv.sec)) * std.time.us_per_s + @as(u64, @intCast(tv.usec));
}

fn durationUs(d: Io.Duration) u64 {
    return @intCast(@divFloor(d.nanoseconds, std.time.ns_per_us));
}

/// Merge every directory under `options.raw` into `options.out`, and return
/// how many there were. One `kcov --merge` of thousands of directories runs
/// on one core for minutes, so the directories are merged in one batch per
/// core first, all at once, and the batches then into the report.
fn merge(arena: Allocator, io: Io, options: Options, stderr: *Io.Writer) !usize {
    const cwd = Io.Dir.cwd();
    var dirs: std.ArrayList([]const u8) = .empty;
    {
        var raw = cwd.openDir(io, options.raw, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        defer raw.close(io);
        var it = raw.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            try dirs.append(arena, try std.fs.path.join(arena, &.{ options.raw, entry.name }));
        }
    }
    if (dirs.items.len == 0) return 0;
    std.mem.sort([]const u8, dirs.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    const started = Io.Clock.awake.now(io);
    const batches_dir = try std.fmt.allocPrint(arena, "{s}-batches", .{options.raw});
    try cwd.deleteTree(io, batches_dir);
    try cwd.createDirPath(io, batches_dir);
    const cores: usize = std.Thread.getCpuCount() catch 1;
    const batch_count = @min(cores, dirs.items.len);
    const per_batch = std.math.divCeil(usize, dirs.items.len, batch_count) catch unreachable;

    var batch_outs: std.ArrayList([]const u8) = .empty;
    var children: std.ArrayList(std.process.Child) = .empty;
    var start: usize = 0;
    while (start < dirs.items.len) : (start += per_batch) {
        const end = @min(start + per_batch, dirs.items.len);
        const out = try std.fmt.allocPrint(arena, "{s}/{d}", .{ batches_dir, batch_outs.items.len });
        try batch_outs.append(arena, out);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ options.kcov, "--merge", out });
        try argv.appendSlice(arena, dirs.items[start..end]);
        try children.append(arena, try std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = .ignore,
            .stdout = .ignore,
        }));
    }
    var failed = false;
    for (children.items) |*child| {
        const term = try child.wait(io);
        if (term != .exited or term.exited != 0) failed = true;
    }
    if (failed) return error.KcovMergeFailed;

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ options.kcov, "--merge", options.out });
    try argv.appendSlice(arena, batch_outs.items);
    var final = try std.process.spawn(io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .ignore });
    const term = try final.wait(io);
    if (term != .exited or term.exited != 0) return error.KcovMergeFailed;
    try cwd.deleteTree(io, batches_dir);

    try stderr.print("coverage: merged {d} kcov runs in {d:.1} s\n", .{
        dirs.items.len,
        @as(f64, @floatFromInt(durationUs(started.durationTo(Io.Clock.awake.now(io))))) / std.time.us_per_s,
    });
    return dirs.items.len;
}

/// One source file's lines as the report counts them.
const File = struct {
    /// Relative to `src/`.
    path: []const u8,
    /// Lines with code, and how many of them ran.
    total: u32,
    covered: u32,

    fn uncovered(f: File) u32 {
        return f.total - f.covered;
    }
};

/// Every file under `options.src` in the merged Cobertura report, with the
/// tests' own lines taken out, sorted by path.
fn readCobertura(arena: Allocator, io: Io, options: Options) ![]File {
    const cwd = Io.Dir.cwd();
    const xml_path = try std.fs.path.join(arena, &.{ options.out, "kcov-merged", "cobertura.xml" });
    const xml = try cwd.readFileAlloc(io, xml_path, arena, .unlimited);
    var files: std.ArrayList(File) = .empty;
    var rest: []const u8 = xml;
    while (std.mem.indexOf(u8, rest, "<class ")) |at| {
        rest = rest[at..];
        const class_end = std.mem.indexOf(u8, rest, "</class>") orelse rest.len;
        const class = rest[0..class_end];
        rest = rest[class_end..];
        const filename = attribute(class, "filename") orelse continue;
        const path = relativeToSrc(arena, filename, options.src) orelse continue;
        if (std.mem.endsWith(u8, path, "_test.zig")) continue;
        const full = try std.fs.path.join(arena, &.{ options.src, path });
        const source = cwd.readFileAlloc(io, full, arena, .unlimited) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        const file = tallyClass(path, class, try testLines(arena, source));
        if (file.total != 0) try files.append(arena, file);
    }
    std.mem.sort(File, files.items, {}, struct {
        fn lessThan(_: void, a: File, b: File) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
    return files.items;
}

/// The lines of one Cobertura `<class>` element, `class`, that are not in
/// `test_lines`, and how many of them ran.
fn tallyClass(path: []const u8, class: []const u8, test_lines: []const bool) File {
    var file: File = .{ .path = path, .total = 0, .covered = 0 };
    var lines: []const u8 = class;
    while (std.mem.indexOf(u8, lines, "<line ")) |line_at| {
        // `attribute` reads the tag this points into; the next search
        // starts past its opening `<`.
        lines = lines[line_at + 1 ..];
        const number = std.fmt.parseUnsigned(u32, attribute(lines, "number") orelse continue, 10) catch continue;
        const hits = std.fmt.parseUnsigned(u64, attribute(lines, "hits") orelse continue, 10) catch continue;
        if (number == 0 or (number <= test_lines.len and test_lines[number - 1])) continue;
        file.total += 1;
        if (hits != 0) file.covered += 1;
    }
    return file;
}

/// The value of `name="..."` in the first tag of `text`.
fn attribute(text: []const u8, comptime name: []const u8) ?[]const u8 {
    const tag_end = std.mem.indexOfScalar(u8, text, '>') orelse text.len;
    const tag = text[0..tag_end];
    const key = " " ++ name ++ "=\"";
    const at = std.mem.indexOf(u8, tag, key) orelse return null;
    const begin = at + key.len;
    const end = std.mem.indexOfScalarPos(u8, tag, begin, '"') orelse return null;
    return tag[begin..end];
}

/// `filename` relative to `src`, or null when it is not under it. kcov
/// writes absolute paths, or paths relative to the longest prefix every
/// file shares, which is `src/` itself once more than one directory ran.
fn relativeToSrc(arena: Allocator, filename: []const u8, src: []const u8) ?[]const u8 {
    if (std.fs.path.isAbsolute(filename)) {
        if (!std.mem.startsWith(u8, filename, src) or filename.len <= src.len or filename[src.len] != '/') return null;
        return arena.dupe(u8, filename[src.len + 1 ..]) catch null;
    }
    return filename;
}

/// For each line of `source`, whether it belongs to a `test` block: from a
/// line that opens one to the line that closes it at the same indentation,
/// which `zig fmt` guarantees.
pub fn testLines(arena: Allocator, source: []const u8) ![]bool {
    var count: usize = 1;
    for (source) |c| count += @intFromBool(c == '\n');
    const marks = try arena.alloc(bool, count);
    @memset(marks, false);
    var lines = std.mem.splitScalar(u8, source, '\n');
    var index: usize = 0;
    var closing: ?[]const u8 = null;
    while (lines.next()) |line| : (index += 1) {
        const trimmed = std.mem.trimEnd(u8, line, " \r");
        if (closing) |indent| {
            marks[index] = true;
            if (trimmed.len == indent.len + 1 and std.mem.startsWith(u8, trimmed, indent) and trimmed[indent.len] == '}') closing = null;
            continue;
        }
        const body = std.mem.trimStart(u8, trimmed, " ");
        const opens = std.mem.startsWith(u8, body, "test ") or std.mem.startsWith(u8, body, "test{");
        if (opens and std.mem.endsWith(u8, body, "{")) {
            marks[index] = true;
            closing = trimmed[0 .. trimmed.len - body.len];
        }
    }
    return marks;
}

const Rendered = struct {
    /// `summary.md`: the headline, the directory table and every file.
    full: []const u8,
    /// What the terminal gets: the headline, the directory table and the
    /// files with the most uncovered lines.
    terminal: []const u8,
};

/// A line count and how many of it ran.
const Tally = struct {
    total: u64 = 0,
    covered: u64 = 0,

    fn add(t: *Tally, f: File) void {
        t.total += f.total;
        t.covered += f.covered;
    }

    fn percent(t: Tally) f64 {
        if (t.total == 0) return 0;
        return 100.0 * @as(f64, @floatFromInt(t.covered)) / @as(f64, @floatFromInt(t.total));
    }
};

/// The top-level directory under `src/` a file belongs to, or `.` for a
/// file directly in it.
fn topDirectory(path: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return ".";
    return path[0..slash];
}

fn render(arena: Allocator, files: []const File, measured: Measured, collected: usize, options: Options) !Rendered {
    var total: Tally = .{};
    var dirs: std.StringArrayHashMapUnmanaged(Tally) = .empty;
    for (files) |f| {
        total.add(f);
        const entry = try dirs.getOrPut(arena, topDirectory(f.path));
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.add(f);
    }
    const Dir = struct { name: []const u8, tally: Tally };
    var dir_list: std.ArrayList(Dir) = .empty;
    for (dirs.keys(), dirs.values()) |name, tally| try dir_list.append(arena, .{ .name = name, .tally = tally });
    std.mem.sort(Dir, dir_list.items, {}, struct {
        fn lessThan(_: void, a: Dir, b: Dir) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    const by_uncovered = try arena.dupe(File, files);
    std.mem.sort(File, by_uncovered, {}, struct {
        fn lessThan(_: void, a: File, b: File) bool {
            if (a.uncovered() != b.uncovered()) return a.uncovered() > b.uncovered();
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);

    var head: Io.Writer.Allocating = .init(arena);
    const h = &head.writer;
    try h.print("Line coverage of src/: {d:.1}% ({d} of {d} lines)\n\n", .{ total.percent(), total.covered, total.total });
    if (measured.ran) {
        try h.print("Collected from {d} processes in {d:.0} s wall, {d:.0} CPU-s", .{
            collected,
            @as(f64, @floatFromInt(measured.wall_us)) / std.time.us_per_s,
            @as(f64, @floatFromInt(measured.cpu_us)) / std.time.us_per_s,
        });
        if (measured.load_start) |l| try h.print("; load average {d:.1} at the start", .{l[0]});
        if (measured.load_end) |l| try h.print(", {d:.1} at the end", .{l[0]});
        try h.writeAll(".\n\n");
    }
    try h.writeAll("| Directory | Lines | Covered | % |\n|---|---:|---:|---:|\n");
    for (dir_list.items) |d| {
        try h.print("| {s} | {d} | {d} | {d:.1} |\n", .{ d.name, d.tally.total, d.tally.covered, d.tally.percent() });
    }
    try h.print("| **total** | {d} | {d} | {d:.1} |\n\n", .{ total.total, total.covered, total.percent() });

    var term: Io.Writer.Allocating = .init(arena);
    try term.writer.writeAll(head.written());
    try term.writer.print("The {d} files with the most uncovered lines:\n\n| File | Uncovered | Lines | % |\n|---|---:|---:|---:|\n", .{@min(options.top, by_uncovered.len)});
    for (by_uncovered[0..@min(options.top, by_uncovered.len)]) |f| {
        try term.writer.print("| {s} | {d} | {d} | {d:.1} |\n", .{ f.path, f.uncovered(), f.total, (Tally{ .total = f.total, .covered = f.covered }).percent() });
    }
    try term.writer.writeAll("\n");

    var full: Io.Writer.Allocating = .init(arena);
    const w = &full.writer;
    try w.writeAll(
        \\# Line coverage
        \\
        \\Generated by `zig build coverage` (`tests/coverage.zig`): the lines of
        \\`src/` that some `beni` process spawned by the black-box suites or the
        \\corpus ran. The unit tests are not measured. A covered line is one that
        \\ran, not one whose effect a test checked.
        \\Files named `*_test.zig` and the lines of `test` blocks are left out.
        \\
        \\
    );
    try w.writeAll(head.written());
    try w.writeAll("## Every file\n\n| File | Lines | Covered | Uncovered | % |\n|---|---:|---:|---:|---:|\n");
    for (files) |f| {
        try w.print("| {s} | {d} | {d} | {d} | {d:.1} |\n", .{ f.path, f.total, f.covered, f.uncovered(), (Tally{ .total = f.total, .covered = f.covered }).percent() });
    }
    return .{ .full = full.written(), .terminal = term.written() };
}

/// `/proc/loadavg`'s three averages, or null where there is none.
fn loadAverage(arena: Allocator, io: Io) ?[3]f64 {
    const file = Io.Dir.cwd().openFile(io, "/proc/loadavg", .{}) catch return null;
    defer file.close(io);
    var buffer: [256]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const text = reader.interface.allocRemaining(arena, .limited(4096)) catch return null;
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    var out: [3]f64 = undefined;
    for (&out) |*v| v.* = std.fmt.parseFloat(f64, words.next() orelse return null) catch return null;
    return out;
}

test "a class counts its lines that ran, leaving out the tests' lines" {
    const class =
        \\<class name="A_zig__1" filename="lex/A.zig" line-rate="0.5">
        \\    <lines>
        \\        <line number="1" hits="3"/>
        \\        <line number="2" hits="0"/>
        \\        <line number="3" hits="1"/>
        \\        <line number="4" hits="0"/>
        \\    </lines>
    ;
    const file = tallyClass("lex/A.zig", class, &.{ false, false, true, true });
    try std.testing.expectEqual(@as(u32, 2), file.total);
    try std.testing.expectEqual(@as(u32, 1), file.covered);
    try std.testing.expectEqualStrings("lex/A.zig", attribute(class, "filename").?);
}

test "the lines of a test block are marked, and nothing else" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const marks = try testLines(arena.allocator(),
        \\fn f() void {}
        \\test "f" {
        \\    f();
        \\}
        \\const S = struct {
        \\    test {
        \\        if (true) {}
        \\    }
        \\    fn g() void {}
        \\};
    );
    try std.testing.expectEqualSlices(bool, &.{ false, true, true, true, false, true, true, true, false, false }, marks);
}
