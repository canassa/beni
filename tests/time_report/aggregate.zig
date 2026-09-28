//! The tables of `zig build test-time-report`: reads the records of
//! `tests/timing.zig` and renders them as Markdown.
//!
//! Every table is a pure function of the records and the run's `Meta`, and
//! the rows are ordered by value with the key as tie-break, so the same
//! records always render the same bytes.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const timing = @import("../timing.zig");

/// What the driver measured around the whole run (`run.json` in the records
/// directory). Every field has a default, so a report can be rendered from
/// records alone.
pub const Meta = struct {
    /// The command that ran the suites, as typed.
    command: []const []const u8 = &.{},
    /// When it started, in seconds since the Unix epoch.
    started_unix_s: i64 = 0,
    /// Its exit code; -1 when a signal ended it.
    exit: i32 = 0,
    /// The whole command, every process under it included.
    wall_us: u64 = 0,
    user_us: u64 = 0,
    sys_us: u64 = 0,
    /// The 1-, 5- and 15-minute load averages before and after.
    load_start: ?[3]f64 = null,
    load_end: ?[3]f64 = null,
    cpu_model: []const u8 = "",
    threads: u32 = 0,
    /// A bare `node -e 0`, measured before the run: the median of
    /// `node_probe_runs` runs.
    node_probe_runs: u32 = 0,
    node_startup_cpu_us: u64 = 0,
    node_startup_wall_us: u64 = 0,
};

/// One test process: its record file, parsed.
pub const Process = struct {
    start: timing.Start,
    /// Null when the process did not run to its end.
    exit: ?timing.Exit,
    tests: []const timing.Test,
    fixtures: []const timing.Fixture,
    children: []const timing.Child,

    /// The build step this process is one share of: the binary and the
    /// part or timing shard it runs. Shards of one binary share a step.
    fn step(p: Process, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}{s}{s}{s}{s}", .{
            p.start.binary,
            if (p.start.part.len != 0) " part " else "",
            p.start.part,
            if (p.start.perf_shard.len != 0) " perf " else "",
            p.start.perf_shard,
        });
    }

    /// The process's own CPU: from its exit record, else the sum of its
    /// tests.
    fn selfCpu(p: Process) u64 {
        if (p.exit) |e| return e.user_us + e.sys_us;
        var sum: u64 = 0;
        for (p.tests) |t| sum += t.user_us + t.sys_us;
        return sum;
    }

    /// The CPU of every child it reaped, recorded or not.
    fn childCpu(p: Process) u64 {
        if (p.exit) |e| return e.child_user_us + e.child_sys_us;
        var sum: u64 = 0;
        for (p.tests) |t| sum += t.child_user_us + t.child_sys_us;
        return sum;
    }

    fn wall(p: Process) u64 {
        if (p.exit) |e| return e.wall_us;
        var sum: u64 = 0;
        for (p.tests) |t| sum += t.wall_us;
        return sum;
    }
};

pub const ParseError = error{ MissingStart, UnsupportedFormat, OutOfMemory } || std.json.ParseError(std.json.Scanner);

/// One record file. Blank lines are skipped; a line that does not parse
/// is an error, because the recorder never writes a partial line.
pub fn parseProcess(arena: Allocator, bytes: []const u8) ParseError!Process {
    var start: ?timing.Start = null;
    var exit: ?timing.Exit = null;
    var tests: std.ArrayList(timing.Test) = .empty;
    var fixtures: std.ArrayList(timing.Fixture) = .empty;
    var children: std.ArrayList(timing.Child) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
        const record = try std.json.parseFromSliceLeaky(timing.Record, arena, line, .{ .ignore_unknown_fields = true });
        switch (record) {
            .start => |s| {
                if (s.format != timing.format_version) return error.UnsupportedFormat;
                start = s;
            },
            .@"test" => |t| try tests.append(arena, t),
            .fixture => |f| try fixtures.append(arena, f),
            .child => |c| try children.append(arena, c),
            .exit => |e| exit = e,
        }
    }
    return .{
        .start = start orelse return error.MissingStart,
        .exit = exit,
        .tests = tests.items,
        .fixtures = fixtures.items,
        .children = children.items,
    };
}

/// Sort processes into a stable order: by binary, part, timing shard,
/// test shard, then pid.
pub fn sortProcesses(processes: []Process) void {
    std.mem.sort(Process, processes, {}, struct {
        fn lessThan(_: void, a: Process, b: Process) bool {
            inline for (.{ "binary", "part", "perf_shard", "shard" }) |field| {
                switch (std.mem.order(u8, @field(a.start, field), @field(b.start, field))) {
                    .lt => return true,
                    .gt => return false,
                    .eq => {},
                }
            }
            return a.start.pid < b.start.pid;
        }
    }.lessThan);
}

pub const Options = struct {
    /// Rows in each "top" table.
    top: usize = 40,
};

/// The whole generated block.
pub fn render(arena: Allocator, w: *Io.Writer, meta: Meta, processes: []const Process, options: Options) !void {
    try renderRun(w, meta, processes);
    try renderSteps(arena, w, meta, processes);
    try renderTests(arena, w, processes, options);
    try renderFixtures(arena, w, processes, options);
    try renderTools(arena, w, meta, processes);
    try renderHarness(arena, w, processes);
    try renderRepeats(arena, w, processes);
}

// ---- The run ----

fn renderRun(w: *Io.Writer, meta: Meta, processes: []const Process) !void {
    try w.writeAll("### The run\n\n");
    if (meta.command.len != 0) {
        try w.writeAll("- Command: `");
        for (meta.command, 0..) |arg, i| {
            // The program by its name: the path says where the toolchain
            // lives, which is not the report's business.
            if (i != 0) try w.writeByte(' ');
            try w.writeAll(if (i == 0) std.fs.path.basename(arg) else arg);
        }
        try w.print("`, exit {d}.\n", .{meta.exit});
    }
    if (meta.started_unix_s != 0) {
        const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(meta.started_unix_s) };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        try w.print("- Started: {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC.\n", .{ yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour() });
    }
    if (meta.cpu_model.len != 0 or meta.threads != 0) {
        try w.print("- Machine: {s}, {d} hardware threads.\n", .{ if (meta.cpu_model.len != 0) meta.cpu_model else "unknown CPU", meta.threads });
    }
    if (meta.load_start) |s| {
        try w.print("- Load average (1, 5, 15 min): {d:.2} {d:.2} {d:.2} at the start", .{ s[0], s[1], s[2] });
        if (meta.load_end) |e| try w.print(", {d:.2} {d:.2} {d:.2} at the end", .{ e[0], e[1], e[2] });
        try w.writeAll(".\n");
    }
    var in_tests: u64 = 0;
    for (processes) |p| in_tests += p.selfCpu() + p.childCpu();
    if (meta.wall_us != 0) {
        try w.print("- Whole run: {f} s wall, {f} CPU-s ({f} user + {f} sys).\n", .{ secs(meta.wall_us), secs(meta.user_us + meta.sys_us), secs(meta.user_us), secs(meta.sys_us) });
    }
    try w.print("- In test processes: {f} CPU-s over {d} processes", .{ secs(in_tests), processes.len });
    if (meta.wall_us != 0) {
        const total = meta.user_us + meta.sys_us;
        try w.print("; outside them (the build runner, compiles, `zig fmt`): {f} CPU-s", .{secs(total -| in_tests)});
    }
    try w.writeAll(".\n");
    var unfinished: usize = 0;
    for (processes) |p| {
        if (p.exit == null) unfinished += 1;
    }
    if (unfinished != 0) try w.print("- {d} test processes wrote no exit record (they crashed or were killed); their figures are the sums of their tests.\n", .{unfinished});
    try w.writeAll(
        \\
        \\CPU time (user + sys, from `getrusage` and `wait4`) is the stable metric.
        \\Under load, wall time stretches with whatever else the machine runs while
        \\CPU time barely moves, so compare wall times only between runs at a
        \\similar load.
        \\
        \\
    );
}

// ---- Per step ----

const StepRow = struct {
    name: []const u8,
    processes: u32 = 0,
    tests: u32 = 0,
    wall_max: u64 = 0,
    self_user: u64 = 0,
    self_sys: u64 = 0,
    child_cpu: u64 = 0,
    self_rss: u64 = 0,
    child_rss: u64 = 0,
    beni: u32 = 0,
    node: u32 = 0,

    fn cpu(r: StepRow) u64 {
        return r.self_user + r.self_sys + r.child_cpu;
    }
};

fn renderSteps(arena: Allocator, w: *Io.Writer, meta: Meta, processes: []const Process) !void {
    _ = meta;
    var rows: std.StringArrayHashMapUnmanaged(StepRow) = .empty;
    for (processes) |p| {
        const name = try p.step(arena);
        const gop = try rows.getOrPut(arena, name);
        if (!gop.found_existing) gop.value_ptr.* = .{ .name = name };
        const r = gop.value_ptr;
        r.processes += 1;
        r.tests += @intCast(p.tests.len);
        r.wall_max = @max(r.wall_max, p.wall());
        if (p.exit) |e| {
            r.self_user += e.user_us;
            r.self_sys += e.sys_us;
            r.self_rss = @max(r.self_rss, e.max_rss_kib);
            r.child_rss = @max(r.child_rss, e.child_max_rss_kib);
        } else for (p.tests) |t| {
            r.self_user += t.user_us;
            r.self_sys += t.sys_us;
        }
        r.child_cpu += p.childCpu();
        for (p.children) |c| {
            if (std.mem.eql(u8, c.tool, "beni")) r.beni += 1;
            if (std.mem.eql(u8, c.tool, "node")) r.node += 1;
        }
    }
    const sorted = try sortedValues(StepRow, arena, rows.values(), struct {
        fn key(r: StepRow) u64 {
            return r.cpu();
        }
        fn name(r: StepRow) []const u8 {
            return r.name;
        }
    });
    try w.writeAll(
        \\### Per step
        \\
        \\One row per test binary and part; the shards of a binary are summed. Wall
        \\is its longest process. "Harness" is the test process itself, "children"
        \\every process it reaped.
        \\
        \\| step | processes | tests | wall s | harness user s | harness sys s | children CPU s | **total CPU s** | harness max RSS MiB | child max RSS MiB | beni | node |
        \\|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
        \\
    );
    var total: StepRow = .{ .name = "" };
    for (sorted) |r| {
        try w.print("| {s} | {d} | {d} | {f} | {f} | {f} | {f} | **{f}** | {d} | {d} | {d} | {d} |\n", .{
            r.name,        r.processes,       r.tests,            secs(r.wall_max), secs(r.self_user), secs(r.self_sys), secs(r.child_cpu),
            secs(r.cpu()), r.self_rss / 1024, r.child_rss / 1024, r.beni,           r.node,
        });
        total.processes += r.processes;
        total.tests += r.tests;
        total.wall_max = @max(total.wall_max, r.wall_max);
        total.self_user += r.self_user;
        total.self_sys += r.self_sys;
        total.child_cpu += r.child_cpu;
        total.beni += r.beni;
        total.node += r.node;
    }
    try w.print("| **all** | {d} | {d} | {f} | {f} | {f} | {f} | **{f}** | | | {d} | {d} |\n\n", .{
        total.processes, total.tests, secs(total.wall_max), secs(total.self_user), secs(total.self_sys), secs(total.child_cpu), secs(total.cpu()), total.beni, total.node,
    });
}

// ---- Per test ----

const TestRow = struct {
    name: []const u8,
    binary: []const u8,
    wall: u64 = 0,
    self: u64 = 0,
    child: u64 = 0,
    beni: u32 = 0,
    node: u32 = 0,

    fn cpu(r: TestRow) u64 {
        return r.self + r.child;
    }
};

fn renderTests(arena: Allocator, w: *Io.Writer, processes: []const Process, options: Options) !void {
    // A test function of a binary split into parts runs in every part, so
    // one row sums its CPU over the processes and keeps its longest wall.
    var rows: std.StringArrayHashMapUnmanaged(TestRow) = .empty;
    for (processes) |p| {
        for (p.tests) |t| {
            const gop = try rows.getOrPut(arena, t.name);
            if (!gop.found_existing) gop.value_ptr.* = .{ .name = t.name, .binary = p.start.binary };
            const r = gop.value_ptr;
            r.wall = @max(r.wall, t.wall_us);
            r.self += t.user_us + t.sys_us;
            r.child += t.child_user_us + t.child_sys_us;
        }
        for (p.children) |c| {
            const r = rows.getPtr(c.@"test") orelse continue;
            if (std.mem.eql(u8, c.tool, "beni")) r.beni += 1;
            if (std.mem.eql(u8, c.tool, "node")) r.node += 1;
        }
    }
    const sorted = try sortedValues(TestRow, arena, rows.values(), struct {
        fn key(r: TestRow) u64 {
            return r.cpu();
        }
        fn name(r: TestRow) []const u8 {
            return r.name;
        }
    });
    try w.print(
        \\### Per test
        \\
        \\The {d} most expensive of {d} tests by CPU. "Harness" is CPU in the test
        \\process, "children" in what it spawned.
        \\
        \\| # | test | wall s | harness CPU s | children CPU s | **total CPU s** | beni | node |
        \\|---:|---|---:|---:|---:|---:|---:|---:|
        \\
    , .{ @min(options.top, sorted.len), sorted.len });
    for (sorted[0..@min(options.top, sorted.len)], 1..) |r, i| {
        try w.print("| {d} | {s} | {f} | {f} | {f} | **{f}** | {d} | {d} |\n", .{ i, try testName(arena, r.name), secs(r.wall), secs(r.self), secs(r.child), secs(r.cpu()), r.beni, r.node });
    }
    try w.writeAll("\n**Distribution of tests by CPU:**\n\n");
    const cpus = try arena.alloc(u64, sorted.len);
    for (sorted, cpus) |r, *c| c.* = r.cpu();
    try distribution(w, "CPU per test", "tests", cpus, &.{ 10_000, 100_000, 1_000_000, 10_000_000 });
}

/// `corpus_test.test.corpus: run` as `corpus_test · corpus: run`.
fn testName(arena: Allocator, name: []const u8) ![]const u8 {
    const marker = ".test.";
    const at = std.mem.indexOf(u8, name, marker) orelse return name;
    return std.fmt.allocPrint(arena, "{s} · {s}", .{ name[0..at], name[at + marker.len ..] });
}

// ---- Per fixture ----

const FixtureRow = struct {
    key: []const u8,
    path: []const u8,
    kind: []const u8,
    wall: u64 = 0,
    harness: u64 = 0,
    beni: u32 = 0,
    beni_cpu: u64 = 0,
    node: u32 = 0,
    node_cpu: u64 = 0,
    other_cpu: u64 = 0,

    fn cpu(r: FixtureRow) u64 {
        return r.harness + r.beni_cpu + r.node_cpu + r.other_cpu;
    }
};

const KindRow = struct {
    kind: []const u8,
    fixtures: u32 = 0,
    cpu: u64 = 0,
    beni: u32 = 0,
    node: u32 = 0,
};

fn renderFixtures(arena: Allocator, w: *Io.Writer, processes: []const Process, options: Options) !void {
    // A fixture is one case of one process: a `run/` program is two cases,
    // one per part, and each is its own row.
    var rows: std.StringArrayHashMapUnmanaged(FixtureRow) = .empty;
    for (processes) |p| {
        var mine: std.StringHashMapUnmanaged(usize) = .empty;
        for (p.fixtures) |f| {
            const kind = if (p.start.part.len != 0 and !std.mem.eql(u8, p.start.part, f.kind) and std.mem.startsWith(u8, p.start.part, f.kind))
                p.start.part
            else
                f.kind;
            const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ kind, f.path });
            const gop = try rows.getOrPut(arena, key);
            if (!gop.found_existing) gop.value_ptr.* = .{ .key = key, .path = f.path, .kind = kind };
            gop.value_ptr.wall += f.wall_us;
            gop.value_ptr.harness += f.thread_cpu_us;
            try mine.put(arena, f.path, gop.index);
        }
        for (p.children) |c| {
            if (c.fixture.len == 0) continue;
            const index = mine.get(c.fixture) orelse continue;
            const r = &rows.values()[index];
            const cpu = c.user_us + c.sys_us;
            if (std.mem.eql(u8, c.tool, "beni")) {
                r.beni += 1;
                r.beni_cpu += cpu;
            } else if (std.mem.eql(u8, c.tool, "node")) {
                r.node += 1;
                r.node_cpu += cpu;
            } else r.other_cpu += cpu;
        }
    }
    if (rows.count() == 0) {
        try w.writeAll("### Per fixture\n\nNo corpus fixture ran.\n\n");
        return;
    }
    const sorted = try sortedValues(FixtureRow, arena, rows.values(), struct {
        fn key(r: FixtureRow) u64 {
            return r.cpu();
        }
        fn name(r: FixtureRow) []const u8 {
            return r.key;
        }
    });
    try w.print(
        \\### Per fixture
        \\
        \\The {d} most expensive of {d} corpus cases by CPU: the walker thread's own
        \\time plus every process the case spawned.
        \\
        \\| # | fixture | kind | **CPU ms** | wall ms | harness ms | beni runs / CPU ms | node runs / CPU ms |
        \\|---:|---|---|---:|---:|---:|---:|---:|
        \\
    , .{ @min(options.top, sorted.len), sorted.len });
    for (sorted[0..@min(options.top, sorted.len)], 1..) |r, i| {
        try w.print("| {d} | {s} | {s} | **{d}** | {d} | {f} | {d} / {d} | {d} / {d} |\n", .{
            i, r.path, r.kind, ms(r.cpu()), ms(r.wall), msTenths(r.harness), r.beni, ms(r.beni_cpu), r.node, ms(r.node_cpu),
        });
    }
    try w.writeAll("\n**Distribution of cases by CPU:**\n\n");
    const cpus = try arena.alloc(u64, sorted.len);
    for (sorted, cpus) |r, *c| c.* = r.cpu();
    try distribution(w, "CPU per case", "cases", cpus, &.{ 10_000, 30_000, 100_000, 300_000, 1_000_000 });

    var kinds: std.StringArrayHashMapUnmanaged(KindRow) = .empty;
    for (sorted) |r| {
        const gop = try kinds.getOrPut(arena, r.kind);
        if (!gop.found_existing) gop.value_ptr.* = .{ .kind = r.kind };
        gop.value_ptr.fixtures += 1;
        gop.value_ptr.cpu += r.cpu();
        gop.value_ptr.beni += r.beni;
        gop.value_ptr.node += r.node;
    }
    const by_kind = try sortedValues(KindRow, arena, kinds.values(), struct {
        fn key(r: KindRow) u64 {
            return r.cpu;
        }
        fn name(r: KindRow) []const u8 {
            return r.kind;
        }
    });
    try w.writeAll(
        \\**By kind** (a `run/` program is one case per part):
        \\
        \\| kind | cases | CPU s | mean ms | beni runs | node runs |
        \\|---|---:|---:|---:|---:|---:|
        \\
    );
    for (by_kind) |k| {
        try w.print("| {s} | {d} | {f} | {d} | {d} | {d} |\n", .{ k.kind, k.fixtures, secs(k.cpu), ms(k.cpu / k.fixtures), k.beni, k.node });
    }
    try w.writeByte('\n');
}

// ---- Per tool ----

const ToolRow = struct {
    tool: []const u8,
    runs: u32 = 0,
    user: u64 = 0,
    sys: u64 = 0,
    wall: u64 = 0,
    faults: u64 = 0,
    max_rss: u64 = 0,
    killed: u32 = 0,
    cpus: std.ArrayList(u64) = .empty,

    fn cpu(r: ToolRow) u64 {
        return r.user + r.sys;
    }
};

/// A child's row in the tool table: `beni <command> --jobs=<n>` for a
/// command that compiles (`default` when the argument list names no
/// `--jobs`), `beni <command>` for any other, or the program's name.
pub fn toolClass(arena: Allocator, c: timing.Child) ![]const u8 {
    if (!std.mem.eql(u8, c.tool, "beni")) return c.tool;
    var words = std.mem.tokenizeScalar(u8, c.args, ' ');
    const command = words.next() orelse "(no command)";
    // Only the commands that compile take `--jobs`.
    for ([_][]const u8{ "build", "check", "dump", "fmt" }) |compiles| {
        if (std.mem.eql(u8, command, compiles)) break;
    } else return std.fmt.allocPrint(arena, "beni {s}", .{command});
    var jobs: []const u8 = "default";
    while (words.next()) |word| {
        if (std.mem.startsWith(u8, word, "--jobs=")) jobs = word["--jobs=".len..];
    }
    return std.fmt.allocPrint(arena, "beni {s} --jobs={s}", .{ command, jobs });
}

fn renderTools(arena: Allocator, w: *Io.Writer, meta: Meta, processes: []const Process) !void {
    var rows: std.StringArrayHashMapUnmanaged(ToolRow) = .empty;
    var node_runs: u32 = 0;
    var node_cpu: u64 = 0;
    for (processes) |p| for (p.children) |c| {
        const class = try toolClass(arena, c);
        const gop = try rows.getOrPut(arena, class);
        if (!gop.found_existing) gop.value_ptr.* = .{ .tool = class };
        const r = gop.value_ptr;
        r.runs += 1;
        r.user += c.user_us;
        r.sys += c.sys_us;
        r.wall += c.wall_us;
        r.faults += c.minor_faults;
        r.max_rss = @max(r.max_rss, c.max_rss_kib);
        if (c.exit == -2) r.killed += 1;
        try r.cpus.append(arena, c.user_us + c.sys_us);
        if (std.mem.eql(u8, c.tool, "node")) {
            node_runs += 1;
            node_cpu += c.user_us + c.sys_us;
        }
    };
    const sorted = try sortedValues(ToolRow, arena, rows.values(), struct {
        fn key(r: ToolRow) u64 {
            return r.cpu();
        }
        fn name(r: ToolRow) []const u8 {
            return r.tool;
        }
    });
    try w.writeAll(
        \\### Per tool
        \\
        \\Every process the black-box harness spawned, by program; `beni` by command
        \\and `--jobs`.
        \\
        \\| tool | runs | user s | sys s | **CPU s** | wall s | CPU ms per run (mean / median) | minor faults per run | max RSS MiB |
        \\|---|---:|---:|---:|---:|---:|---:|---:|---:|
        \\
    );
    var total_runs: u32 = 0;
    var total_cpu: u64 = 0;
    var killed: u32 = 0;
    for (sorted) |r| {
        std.mem.sort(u64, r.cpus.items, {}, std.sort.asc(u64));
        const median = r.cpus.items[r.cpus.items.len / 2];
        try w.print("| {s} | {d} | {f} | {f} | **{f}** | {f} | {f} / {f} | {d} | {d} |\n", .{
            r.tool, r.runs, secs(r.user), secs(r.sys), secs(r.cpu()), secs(r.wall), msTenths(r.cpu() / r.runs), msTenths(median), r.faults / r.runs, r.max_rss / 1024,
        });
        total_runs += r.runs;
        total_cpu += r.cpu();
        killed += r.killed;
    }
    try w.print("| **all** | {d} | | | **{f}** | | | | |\n\n", .{ total_runs, secs(total_cpu) });
    if (killed != 0) try w.print("{d} of them were killed by the harness (a timeout or a crash), and report wall time only.\n\n", .{killed});
    if (meta.node_probe_runs != 0 and node_runs != 0) {
        const startup = @as(u64, node_runs) * meta.node_startup_cpu_us;
        try w.print(
            \\**Node start-up against execution.** A bare `node -e 0` took {f} ms CPU
            \\and {f} ms wall (median of {d} runs, before the suites). Across the
            \\{d} Node runs that is about {f} CPU-s of start-up, which leaves about
            \\{f} of Node's {f} CPU-s for loading and running the programs.
            \\
            \\
        , .{ msTenths(meta.node_startup_cpu_us), msTenths(meta.node_startup_wall_us), meta.node_probe_runs, node_runs, secs(startup), secs(node_cpu -| startup), secs(node_cpu) });
    }
}

// ---- Harness overhead ----

const HarnessRow = struct {
    binary: []const u8,
    self_user: u64 = 0,
    self_sys: u64 = 0,
    children: u64 = 0,
    recorded: u64 = 0,
};

fn renderHarness(arena: Allocator, w: *Io.Writer, processes: []const Process) !void {
    var rows: std.StringArrayHashMapUnmanaged(HarnessRow) = .empty;
    for (processes) |p| {
        const gop = try rows.getOrPut(arena, p.start.binary);
        if (!gop.found_existing) gop.value_ptr.* = .{ .binary = p.start.binary };
        const r = gop.value_ptr;
        if (p.exit) |e| {
            r.self_user += e.user_us;
            r.self_sys += e.sys_us;
        } else for (p.tests) |t| {
            r.self_user += t.user_us;
            r.self_sys += t.sys_us;
        }
        r.children += p.childCpu();
        for (p.children) |c| r.recorded += c.user_us + c.sys_us;
    }
    const sorted = try sortedValues(HarnessRow, arena, rows.values(), struct {
        fn key(r: HarnessRow) u64 {
            return r.self_user + r.self_sys;
        }
        fn name(r: HarnessRow) []const u8 {
            return r.binary;
        }
    });
    try w.writeAll(
        \\### Harness overhead against children
        \\
        \\The test process's own CPU against its children's, per binary.
        \\"Unrecorded" is child CPU the harness did not spawn through `World`
        \\(a `std.process.run`, say), so no `child` record names it.
        \\
        \\| binary | harness user s | harness sys s | children CPU s | of which unrecorded | harness share |
        \\|---|---:|---:|---:|---:|---:|
        \\
    );
    var self: u64 = 0;
    var children: u64 = 0;
    for (sorted) |r| {
        const own = r.self_user + r.self_sys;
        try w.print("| {s} | {f} | {f} | {f} | {f} | {f}% |\n", .{ r.binary, secs(r.self_user), secs(r.self_sys), secs(r.children), secs(r.children -| r.recorded), percent(own, own + r.children) });
        self += own;
        children += r.children;
    }
    try w.print("| **all** | | | {f} | | {f}% |\n\n", .{ secs(children), percent(self, self + children) });
}

// ---- Repeated invocations ----

const RepeatRow = struct {
    key: []const u8,
    runs: u32 = 0,
    cpu: u64 = 0,

    fn extraCpu(r: RepeatRow) u64 {
        return r.cpu / r.runs * (r.runs - 1);
    }
};

/// The argument list with the flags that change how, not what, a command
/// runs taken out: `--jobs`, `--no-cache`, `--cache-dir` and the
/// `--roundtrip-*` family.
pub fn withoutVariantFlags(arena: Allocator, args: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var words = std.mem.tokenizeScalar(u8, args, ' ');
    while (words.next()) |word| {
        if (std.mem.startsWith(u8, word, "--jobs=") or std.mem.eql(u8, word, "--no-cache") or
            std.mem.startsWith(u8, word, "--cache-dir") or std.mem.startsWith(u8, word, "--roundtrip")) continue;
        if (out.items.len != 0) try out.append(arena, ' ');
        try out.appendSlice(arena, word);
    }
    return out.items;
}

fn renderRepeats(arena: Allocator, w: *Io.Writer, processes: []const Process) !void {
    var exact: std.StringArrayHashMapUnmanaged(RepeatRow) = .empty;
    var loose: std.StringArrayHashMapUnmanaged(RepeatRow) = .empty;
    for (processes) |p| for (p.children) |c| {
        // Only in the repository root do equal arguments mean equal inputs.
        if (!c.repo_cwd) continue;
        const cpu = c.user_us + c.sys_us;
        for ([_]struct { *std.StringArrayHashMapUnmanaged(RepeatRow), []const u8 }{
            .{ &exact, c.args },
            .{ &loose, try withoutVariantFlags(arena, c.args) },
        }) |pair| {
            const key = try std.fmt.allocPrint(arena, "{s} {s}", .{ c.tool, pair[1] });
            const gop = try pair[0].getOrPut(arena, key);
            if (!gop.found_existing) gop.value_ptr.* = .{ .key = key };
            gop.value_ptr.runs += 1;
            gop.value_ptr.cpu += cpu;
        }
    };
    try w.writeAll(
        \\### Repeated invocations
        \\
        \\Commands run in the repository root, where the same arguments read the
        \\same files. "Extra" is every run after the first.
        \\
        \\
    );
    for ([_]struct { []const u8, *std.StringArrayHashMapUnmanaged(RepeatRow) }{
        .{ "Identical command lines", &exact },
        .{ "The same command apart from `--jobs`, `--no-cache`, `--cache-dir` and `--roundtrip-*`", &loose },
    }) |pair| {
        var repeated: std.ArrayList(RepeatRow) = .empty;
        var extra_runs: u64 = 0;
        var extra_cpu: u64 = 0;
        for (pair[1].values()) |r| if (r.runs > 1) {
            try repeated.append(arena, r);
            extra_runs += r.runs - 1;
            extra_cpu += r.extraCpu();
        };
        const sorted = try sortedValues(RepeatRow, arena, repeated.items, struct {
            fn key(r: RepeatRow) u64 {
                return r.extraCpu();
            }
            fn name(r: RepeatRow) []const u8 {
                return r.key;
            }
        });
        try w.print("**{s}:** {d} extra runs, {f} CPU-s.\n\n", .{ pair[0], extra_runs, secs(extra_cpu) });
        if (sorted.len == 0) continue;
        try w.writeAll("| command | runs | extra CPU ms |\n|---|---:|---:|\n");
        for (sorted[0..@min(10, sorted.len)]) |r| {
            try w.print("| `{s}` | {d} | {d} |\n", .{ r.key, r.runs, ms(r.extraCpu()) });
        }
        try w.writeByte('\n');
    }
}

// ---- Helpers ----

/// `values`, copied and sorted by `By.key` descending, then `By.name`.
fn sortedValues(comptime T: type, arena: Allocator, values: []const T, comptime By: type) ![]T {
    const out = try arena.dupe(T, values);
    std.mem.sort(T, out, {}, struct {
        fn lessThan(_: void, a: T, b: T) bool {
            const ka = By.key(a);
            const kb = By.key(b);
            if (ka != kb) return ka > kb;
            return std.mem.lessThan(u8, By.name(a), By.name(b));
        }
    }.lessThan);
    return out;
}

/// A table of how many of `values` (microseconds) fall under each bound,
/// and their sum.
fn distribution(w: *Io.Writer, what: []const u8, unit: []const u8, values: []const u64, bounds: []const u64) !void {
    try w.print("| {s} | {s} | total CPU s |\n|---|---:|---:|\n", .{ what, unit });
    var lower: u64 = 0;
    for (0..bounds.len + 1) |i| {
        var count: usize = 0;
        var sum: u64 = 0;
        const upper: u64 = if (i < bounds.len) bounds[i] else std.math.maxInt(u64);
        for (values) |v| if (v >= lower and v < upper) {
            count += 1;
            sum += v;
        };
        if (i == 0) {
            try w.print("| under {f} | {d} | {f} |\n", .{ span(upper), count, secs(sum) });
        } else if (i == bounds.len) {
            try w.print("| {f} or more | {d} | {f} |\n", .{ span(lower), count, secs(sum) });
        } else {
            try w.print("| {f} – {f} | {d} | {f} |\n", .{ span(lower), span(upper), count, secs(sum) });
        }
        lower = upper;
    }
    try w.writeByte('\n');
}

/// Microseconds as seconds with one decimal.
const Secs = struct {
    us: u64,
    pub fn format(s: Secs, w: *Io.Writer) Io.Writer.Error!void {
        const tenths = (s.us + 50_000) / 100_000;
        try w.print("{d}.{d}", .{ tenths / 10, tenths % 10 });
    }
};

fn secs(us: u64) Secs {
    return .{ .us = us };
}

/// Microseconds as milliseconds, rounded.
fn ms(us: u64) u64 {
    return (us + 500) / 1000;
}

/// Microseconds as milliseconds with one decimal.
const MsTenths = struct {
    us: u64,
    pub fn format(m: MsTenths, w: *Io.Writer) Io.Writer.Error!void {
        const tenths = (m.us + 50) / 100;
        try w.print("{d}.{d}", .{ tenths / 10, tenths % 10 });
    }
};

fn msTenths(us: u64) MsTenths {
    return .{ .us = us };
}

/// A duration bound, in the unit that reads best: `10 ms`, `0.3 s`, `1 s`.
const Span = struct {
    us: u64,
    pub fn format(s: Span, w: *Io.Writer) Io.Writer.Error!void {
        if (s.us < 100_000) return w.print("{d} ms", .{s.us / 1000});
        if (s.us % 1_000_000 == 0) return w.print("{d} s", .{s.us / 1_000_000});
        try w.print("{d}.{d} s", .{ s.us / 1_000_000, s.us % 1_000_000 / 100_000 });
    }
};

fn span(us: u64) Span {
    return .{ .us = us };
}

/// `part` of `whole` as a percentage with one decimal.
const Percent = struct {
    part: u64,
    whole: u64,
    pub fn format(p: Percent, w: *Io.Writer) Io.Writer.Error!void {
        if (p.whole == 0) return w.writeAll("0.0");
        const tenths = (p.part * 1000 + p.whole / 2) / p.whole;
        try w.print("{d}.{d}", .{ tenths / 10, tenths % 10 });
    }
};

fn percent(part: u64, whole: u64) Percent {
    return .{ .part = part, .whole = whole };
}

// ---- Tests ----

const testing = std.testing;

/// Two processes of a small, made-up run: a corpus part that ran one `run/`
/// fixture (a build and a Node run) and a sharded binary with two tests,
/// one of which ran the same `check` twice in the repository root.
const sample_corpus =
    \\{"start":{"format":1,"binary":"corpus_test","pid":20,"shard":"","part":"run_dev","perf_shard":""}}
    \\{"child":{"test":"corpus_test.test.corpus: run","fixture":"tests/corpus/run/A.beni","tool":"beni","args":"build --platform=node --out=out tests/corpus/run/A.beni --no-cache","repo_cwd":false,"wall_us":30000,"user_us":20000,"sys_us":10000,"max_rss_kib":20480,"minor_faults":4000,"exit":0}}
    \\{"child":{"test":"corpus_test.test.corpus: run","fixture":"tests/corpus/run/A.beni","tool":"node","args":"out/_main.mjs","repo_cwd":false,"wall_us":60000,"user_us":40000,"sys_us":20000,"max_rss_kib":51200,"minor_faults":6000,"exit":0}}
    \\{"fixture":{"test":"corpus_test.test.corpus: run","kind":"run","path":"tests/corpus/run/A.beni","wall_us":95000,"thread_cpu_us":5000}}
    \\{"test":{"name":"corpus_test.test.corpus: run","status":"pass","wall_us":100000,"user_us":6000,"sys_us":2000,"child_user_us":60000,"child_sys_us":30000}}
    \\{"exit":{"tests":1,"wall_us":120000,"user_us":10000,"sys_us":4000,"max_rss_kib":10240,"child_user_us":60000,"child_sys_us":30000,"child_max_rss_kib":51200}}
    \\
;

const sample_shard =
    \\{"start":{"format":1,"binary":"check_test","pid":10,"shard":"0/2","part":"","perf_shard":""}}
    \\{"child":{"test":"check_test.test.a check twice","fixture":"","tool":"beni","args":"check --jobs=1 tests/corpus/check/good/B.beni","repo_cwd":true,"wall_us":12000,"user_us":8000,"sys_us":2000,"max_rss_kib":10240,"minor_faults":1000,"exit":0}}
    \\{"child":{"test":"check_test.test.a check twice","fixture":"","tool":"beni","args":"check --jobs=1 tests/corpus/check/good/B.beni","repo_cwd":true,"wall_us":14000,"user_us":8000,"sys_us":2000,"max_rss_kib":10240,"minor_faults":1000,"exit":0}}
    \\{"test":{"name":"check_test.test.a check twice","status":"pass","wall_us":30000,"user_us":1000,"sys_us":1000,"child_user_us":16000,"child_sys_us":4000}}
    \\{"test":{"name":"check_test.test.nothing spawned","status":"pass","wall_us":2000,"user_us":1500,"sys_us":500,"child_user_us":0,"child_sys_us":0}}
    \\
;

fn sampleProcesses(arena: Allocator) ![]Process {
    const processes = try arena.alloc(Process, 2);
    processes[0] = try parseProcess(arena, sample_corpus);
    processes[1] = try parseProcess(arena, sample_shard);
    sortProcesses(processes);
    return processes;
}

test "a record file parses into its process, tests, fixtures and children" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const p = try parseProcess(arena_state.allocator(), sample_shard);
    try testing.expectEqualDeep(timing.Start{ .binary = "check_test", .pid = 10, .shard = "0/2" }, p.start);
    try testing.expectEqual(null, p.exit);
    try testing.expectEqual(2, p.tests.len);
    try testing.expectEqual(0, p.fixtures.len);
    try testing.expectEqual(2, p.children.len);
    try testing.expectEqualDeep(timing.Test{
        .name = "check_test.test.nothing spawned",
        .status = "pass",
        .wall_us = 2000,
        .user_us = 1500,
        .sys_us = 500,
        .child_user_us = 0,
        .child_sys_us = 0,
    }, p.tests[1]);
}

test "a file without a start record, or of another format, is refused" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.MissingStart, parseProcess(arena,
        \\{"test":{"name":"x","status":"pass","wall_us":1,"user_us":1,"sys_us":1,"child_user_us":0,"child_sys_us":0}}
    ));
    try testing.expectError(error.UnsupportedFormat, parseProcess(arena,
        \\{"start":{"format":999,"binary":"x","pid":1}}
    ));
    try testing.expectError(error.UnexpectedEndOfInput, parseProcess(arena,
        \\{"start":{"format":1,"binary":"x","pid":1}}
        \\{"test":{"na
    ));
}

test "a beni run is classed by command and --jobs, anything else by its name" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base: timing.Child = .{ .@"test" = "", .fixture = "", .tool = "beni", .args = "", .repo_cwd = false, .wall_us = 0, .user_us = 0, .sys_us = 0, .max_rss_kib = 0, .minor_faults = 0, .exit = 0 };
    var c = base;
    c.args = "check --jobs=8 --no-cache A.beni";
    try testing.expectEqualStrings("beni check --jobs=8", try toolClass(arena, c));
    c.args = "dump --stage=ast A.beni";
    try testing.expectEqualStrings("beni dump --jobs=default", try toolClass(arena, c));
    c.args = "";
    try testing.expectEqualStrings("beni (no command)", try toolClass(arena, c));
    c.args = "version";
    try testing.expectEqualStrings("beni version", try toolClass(arena, c));
    c.tool = "node";
    try testing.expectEqualStrings("node", try toolClass(arena, c));
}

test "the variant flags come out of a command line and nothing else does" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings(
        "check A.beni --core",
        try withoutVariantFlags(arena_state.allocator(), "check --jobs=8 A.beni --no-cache --cache-dir=/tmp/c --roundtrip-interfaces --core"),
    );
}

test "the report of a small run is exactly these tables" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const processes = try sampleProcesses(arena);
    var out: Io.Writer.Allocating = .init(arena);
    try render(arena, &out.writer, .{
        .command = &.{ "zig", "build", "gates" },
        .started_unix_s = 1_790_000_000,
        .exit = 0,
        .wall_us = 1_000_000,
        .user_us = 300_000,
        .sys_us = 100_000,
        .load_start = .{ 1.5, 2.25, 3 },
        .load_end = .{ 4, 5, 6 },
        .cpu_model = "Test CPU",
        .threads = 8,
        .node_probe_runs = 5,
        .node_startup_cpu_us = 25_000,
        .node_startup_wall_us = 30_000,
    }, processes, .{ .top = 1 });
    try testing.expectEqualStrings(
        \\### The run
        \\
        \\- Command: `zig build gates`, exit 0.
        \\- Started: 2026-09-21 14:13 UTC.
        \\- Machine: Test CPU, 8 hardware threads.
        \\- Load average (1, 5, 15 min): 1.50 2.25 3.00 at the start, 4.00 5.00 6.00 at the end.
        \\- Whole run: 1.0 s wall, 0.4 CPU-s (0.3 user + 0.1 sys).
        \\- In test processes: 0.1 CPU-s over 2 processes; outside them (the build runner, compiles, `zig fmt`): 0.3 CPU-s.
        \\- 1 test processes wrote no exit record (they crashed or were killed); their figures are the sums of their tests.
        \\
        \\CPU time (user + sys, from `getrusage` and `wait4`) is the stable metric.
        \\Under load, wall time stretches with whatever else the machine runs while
        \\CPU time barely moves, so compare wall times only between runs at a
        \\similar load.
        \\
        \\### Per step
        \\
        \\One row per test binary and part; the shards of a binary are summed. Wall
        \\is its longest process. "Harness" is the test process itself, "children"
        \\every process it reaped.
        \\
        \\| step | processes | tests | wall s | harness user s | harness sys s | children CPU s | **total CPU s** | harness max RSS MiB | child max RSS MiB | beni | node |
        \\|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
        \\| corpus_test part run_dev | 1 | 1 | 0.1 | 0.0 | 0.0 | 0.1 | **0.1** | 10 | 50 | 1 | 1 |
        \\| check_test | 1 | 2 | 0.0 | 0.0 | 0.0 | 0.0 | **0.0** | 0 | 0 | 2 | 0 |
        \\| **all** | 2 | 3 | 0.1 | 0.0 | 0.0 | 0.1 | **0.1** | | | 3 | 1 |
        \\
        \\### Per test
        \\
        \\The 1 most expensive of 3 tests by CPU. "Harness" is CPU in the test
        \\process, "children" in what it spawned.
        \\
        \\| # | test | wall s | harness CPU s | children CPU s | **total CPU s** | beni | node |
        \\|---:|---|---:|---:|---:|---:|---:|---:|
        \\| 1 | corpus_test · corpus: run | 0.1 | 0.0 | 0.1 | **0.1** | 1 | 1 |
        \\
        \\**Distribution of tests by CPU:**
        \\
        \\| CPU per test | tests | total CPU s |
        \\|---|---:|---:|
        \\| under 10 ms | 1 | 0.0 |
        \\| 10 ms – 0.1 s | 2 | 0.1 |
        \\| 0.1 s – 1 s | 0 | 0.0 |
        \\| 1 s – 10 s | 0 | 0.0 |
        \\| 10 s or more | 0 | 0.0 |
        \\
        \\### Per fixture
        \\
        \\The 1 most expensive of 1 corpus cases by CPU: the walker thread's own
        \\time plus every process the case spawned.
        \\
        \\| # | fixture | kind | **CPU ms** | wall ms | harness ms | beni runs / CPU ms | node runs / CPU ms |
        \\|---:|---|---|---:|---:|---:|---:|---:|
        \\| 1 | tests/corpus/run/A.beni | run_dev | **95** | 95 | 5.0 | 1 / 30 | 1 / 60 |
        \\
        \\**Distribution of cases by CPU:**
        \\
        \\| CPU per case | cases | total CPU s |
        \\|---|---:|---:|
        \\| under 10 ms | 0 | 0.0 |
        \\| 10 ms – 30 ms | 0 | 0.0 |
        \\| 30 ms – 0.1 s | 1 | 0.1 |
        \\| 0.1 s – 0.3 s | 0 | 0.0 |
        \\| 0.3 s – 1 s | 0 | 0.0 |
        \\| 1 s or more | 0 | 0.0 |
        \\
        \\**By kind** (a `run/` program is one case per part):
        \\
        \\| kind | cases | CPU s | mean ms | beni runs | node runs |
        \\|---|---:|---:|---:|---:|---:|
        \\| run_dev | 1 | 0.1 | 95 | 1 | 1 |
        \\
        \\### Per tool
        \\
        \\Every process the black-box harness spawned, by program; `beni` by command
        \\and `--jobs`.
        \\
        \\| tool | runs | user s | sys s | **CPU s** | wall s | CPU ms per run (mean / median) | minor faults per run | max RSS MiB |
        \\|---|---:|---:|---:|---:|---:|---:|---:|---:|
        \\| node | 1 | 0.0 | 0.0 | **0.1** | 0.1 | 60.0 / 60.0 | 6000 | 50 |
        \\| beni build --jobs=default | 1 | 0.0 | 0.0 | **0.0** | 0.0 | 30.0 / 30.0 | 4000 | 20 |
        \\| beni check --jobs=1 | 2 | 0.0 | 0.0 | **0.0** | 0.0 | 10.0 / 10.0 | 1000 | 10 |
        \\| **all** | 4 | | | **0.1** | | | | |
        \\
        \\**Node start-up against execution.** A bare `node -e 0` took 25.0 ms CPU
        \\and 30.0 ms wall (median of 5 runs, before the suites). Across the
        \\1 Node runs that is about 0.0 CPU-s of start-up, which leaves about
        \\0.0 of Node's 0.1 CPU-s for loading and running the programs.
        \\
        \\### Harness overhead against children
        \\
        \\The test process's own CPU against its children's, per binary.
        \\"Unrecorded" is child CPU the harness did not spawn through `World`
        \\(a `std.process.run`, say), so no `child` record names it.
        \\
        \\| binary | harness user s | harness sys s | children CPU s | of which unrecorded | harness share |
        \\|---|---:|---:|---:|---:|---:|
        \\| corpus_test | 0.0 | 0.0 | 0.1 | 0.0 | 13.5% |
        \\| check_test | 0.0 | 0.0 | 0.0 | 0.0 | 16.7% |
        \\| **all** | | | 0.1 | | 14.1% |
        \\
        \\### Repeated invocations
        \\
        \\Commands run in the repository root, where the same arguments read the
        \\same files. "Extra" is every run after the first.
        \\
        \\**Identical command lines:** 1 extra runs, 0.0 CPU-s.
        \\
        \\| command | runs | extra CPU ms |
        \\|---|---:|---:|
        \\| `beni check --jobs=1 tests/corpus/check/good/B.beni` | 2 | 10 |
        \\
        \\**The same command apart from `--jobs`, `--no-cache`, `--cache-dir` and `--roundtrip-*`:** 1 extra runs, 0.0 CPU-s.
        \\
        \\| command | runs | extra CPU ms |
        \\|---|---:|---:|
        \\| `beni check tests/corpus/check/good/B.beni` | 2 | 10 |
        \\
        \\
    , out.written());
}
