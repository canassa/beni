//! Opt-in timing records for the test suites, read by `zig build
//! test-time-report` (`tests/time_report.zig`), and the budget every test
//! is held to (`budget_unit`).
//!
//! `BENI_TEST_TIMING=<dir>` turns it on. Every test process then writes one
//! file, `<dir>/<binary>-<pid>.jsonl`, of one JSON `Record` per line: a
//! `start` when the process begins, a `test` per test, a `fixture` per corpus
//! case, a `child` per process the black-box harness spawns and reaps, and
//! an `exit` with the process's own and its children's resource usage. One
//! file per process means no two processes ever share a file; the threads of
//! one process (the corpus walker's workers) share it under a mutex, one
//! `write` per record.
//!
//! Unset or empty, nothing is opened and every entry point returns after one
//! load of a global, so a suite that is not being timed pays nothing for the
//! instrumentation.
//!
//! The test runner owns the recorder (`tests/test_runner.zig` exposes it as
//! `timing`), and the black-box harness reaches it through `@import("root")`:
//! the runner is the root of every test binary the build graph makes.
//!
//! CPU time is user plus system time from `getrusage`/`wait4` and is the
//! stable metric: another build on the same machine stretches wall time
//! without adding to it.

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;

/// The version of the record format below. The reader refuses any other.
pub const format_version: u32 = 1;

/// The variable that turns timing on: the directory the records go to.
pub const env_var = "BENI_TEST_TIMING";

/// One line of a record file.
pub const Record = union(enum) {
    start: Start,
    @"test": Test,
    fixture: Fixture,
    child: Child,
    exit: Exit,
};

/// The first record of every file: which process this is.
pub const Start = struct {
    format: u32 = format_version,
    /// The test binary's file name: `blackbox_test`, `corpus_test`, `test`.
    binary: []const u8,
    pid: i64,
    /// `BENI_TEST_SHARD`, `BENI_CORPUS_PART` and `BENI_PERF_SHARD`: which
    /// share of the binary this process runs. Together with `binary` they
    /// name the build step the process belongs to.
    shard: []const u8 = "",
    part: []const u8 = "",
    perf_shard: []const u8 = "",
};

/// One test, measured by the runner around the test function.
pub const Test = struct {
    name: []const u8,
    status: []const u8,
    wall_us: u64,
    /// The test process's own CPU during the test (every thread of it).
    user_us: u64,
    sys_us: u64,
    /// The CPU of the processes the test spawned and reaped.
    child_user_us: u64,
    child_sys_us: u64,
    /// The unit of the budget (`Unit`'s name), and what the test spent in
    /// it, less what its cases were held to on their own.
    budget_unit: []const u8 = "none",
    spent: u64 = 0,
};

/// One corpus case, measured by the walker's worker that ran it.
pub const Fixture = struct {
    @"test": []const u8,
    /// The corpus kind (`run`, `check_bad`, …).
    kind: []const u8,
    /// The fixture's repo-relative path.
    path: []const u8,
    wall_us: u64,
    /// CPU of the worker thread that ran the case: the harness's own share.
    /// The case's compiler and Node runs are `child` records naming it.
    thread_cpu_us: u64,
    /// What the case spent in the budget's unit, its children included.
    spent: u64 = 0,
};

/// One process the harness spawned, measured when it was reaped.
pub const Child = struct {
    @"test": []const u8,
    /// The corpus case the child belongs to, or empty outside the walker.
    fixture: []const u8,
    /// The file name of what ran: `beni`, `node`, …
    tool: []const u8,
    /// The arguments after the program, joined by single spaces, cut at
    /// `max_args_bytes`.
    args: []const u8,
    /// Whether the child ran in the repository root. There the arguments
    /// name repository files, so two identical argument lists are the same
    /// work; in a temporary project they may not be.
    repo_cwd: bool,
    wall_us: u64,
    user_us: u64,
    sys_us: u64,
    max_rss_kib: u64,
    minor_faults: u64,
    /// The exit code; -1 when a signal ended it; -2 when the harness killed
    /// it (a timeout, or a crash banner on stderr) and no usage was reported.
    exit: i32,
};

/// The last record of a file that ran to completion.
pub const Exit = struct {
    tests: u32,
    wall_us: u64,
    user_us: u64,
    sys_us: u64,
    max_rss_kib: u64,
    child_user_us: u64,
    child_sys_us: u64,
    child_max_rss_kib: u64,
};

/// Where `args` of a `Child` record is cut: enough for any corpus command,
/// and it keeps every record inside one write buffer.
pub const max_args_bytes = 2048;

var file: ?Io.File = null;
var io: Io = undefined;
var mutex: Io.Mutex = .init;
var process_start: Io.Timestamp = undefined;

/// What every test is held to: the test runner fails a test that spends
/// more (`budget_limit` in `budget_unit`), its own work and that of every
/// process it spawned. A test that runs independent cases, the corpus
/// walker, holds each case to the budget on its own and adds what the cases
/// spent to `cases_spent`; the rest of the test is held to the budget like
/// any other.
///
/// The unit is retired user-space instructions, counted by the kernel for
/// the thread and everything it creates (`Counter`): unlike CPU time, the
/// count does not grow when other work shares the cores. There is no other
/// unit. CPU time follows the machine as well as its load, so a budget in it
/// gave one test a different verdict on each machine; where no counter can
/// be opened, a budgeted process stops instead (`openThreadCounter`), and
/// `build.zig` sets no budget on a host that cannot count.
pub const Unit = enum { none, instructions };
pub var budget_unit: Unit = .none;
pub var budget_limit: u64 = 0;

/// The limit for a corpus case that carries its own budget, in millions of
/// instructions (a `.budget` file, owner-approved; `tests/corpus/README.md`).
pub fn caseLimit(millions: u64) u64 {
    return switch (budget_unit) {
        .none => 0,
        .instructions => millions * 1_000_000,
    };
}

/// The budget in instructions (`zig build -Dtest-budget=`, in millions).
pub const budget_instructions_env_var = "BENI_TEST_BUDGET_INSTRUCTIONS";

/// What the cases the running test budgeted one by one spent (see
/// `budget_unit`), which the runner leaves out of the test's own sum.
pub var cases_spent: std.atomic.Value(u64) = .init(0);

/// The calling thread's instruction counter, opened by `openThreadCounter`.
pub threadlocal var thread_counter: ?Counter = null;

/// A count of the user-space instructions retired by the thread that
/// opened it and by every thread and process that thread creates after,
/// each added in when it exits. A process is added before its parent can
/// reap it; a thread only shortly after a join returns (`awaitFolded`).
pub const Counter = struct {
    fd: i32,

    pub fn open() ?Counter {
        if (builtin.os.tag != .linux) return null;
        const linux = std.os.linux;
        var attr: linux.perf_event_attr = .{
            .type = .HARDWARE,
            .config = @backingInt(linux.PERF.COUNT.HW.INSTRUCTIONS),
            .flags = .{ .inherit = true, .exclude_kernel = true, .exclude_hv = true },
        };
        const rc = linux.perf_event_open(&attr, 0, -1, -1, linux.PERF.FLAG.FD_CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return null;
        return .{ .fd = @intCast(rc) };
    }

    pub fn read(c: Counter) u64 {
        var value: u64 = 0;
        _ = std.os.linux.read(c.fd, @ptrCast(&value), @sizeOf(u64));
        return value;
    }
};

/// Open the calling thread's counter when the budget counts instructions.
pub fn openThreadCounter() void {
    if (budget_unit != .instructions or thread_counter != null) return;
    thread_counter = Counter.open() orelse noCounter();
}

/// A process told to hold its tests to a budget that cannot count one
/// stops: a test that ran unmeasured would pass for a reason that is not
/// true. `build.zig` asks the kernel for a counter when it configures the
/// build, and sets no budget where it gets none; this is the check that
/// holds, in the process that counts.
fn noCounter() noreturn {
    std.debug.print("{s} is set, but no instruction counter can be opened here (perf_event_open), so no test can be held to it\n", .{budget_instructions_env_var});
    std.process.exit(1);
}

/// What the running test has spent so far, in the budget's unit: the test
/// thread's counter.
pub fn testSpent() u64 {
    return switch (budget_unit) {
        .none => 0,
        .instructions => if (thread_counter) |c| c.read() else 0,
    };
}

/// What one worker of independent cases spent, in the budget's unit: a
/// counter of its own, which counts the worker and the processes it spawns
/// and not the threads its test made.
pub const CaseMeter = struct {
    counter: ?Counter,

    pub fn open() CaseMeter {
        return .{ .counter = if (budget_unit == .instructions) Counter.open() orelse noCounter() else null };
    }

    pub fn read(m: CaseMeter) u64 {
        if (m.counter) |c| return c.read();
        return 0;
    }

    pub fn close(m: CaseMeter) void {
        if (m.counter) |c| _ = std.os.linux.close(c.fd);
    }
};

/// Wait until the test thread's counter has grown by `at_least` since it
/// read `start`: a joined thread's count is added to its creator's a moment
/// after the join returns, and a read before that would charge it to the
/// next test. Gives up after a second.
pub fn awaitFolded(start: u64, at_least: u64) void {
    if (budget_unit != .instructions) return;
    const c = thread_counter orelse return;
    var tries: u32 = 0;
    while (c.read() -% start < at_least and tries < 10_000) : (tries += 1) {
        const pause: std.os.linux.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_us };
        _ = std.os.linux.nanosleep(&pause, null);
    }
}

/// A number and its unit, for a failure message.
pub fn describe(amount: u64) struct { value: u64, unit: []const u8 } {
    return .{ .value = amount / 1_000_000, .unit = "million instructions" };
}

/// The test running now. Tests run one at a time in a process, so a global
/// is the truth for every thread of it.
pub var current_test: []const u8 = "";

/// The corpus case the calling thread is running, or empty.
pub threadlocal var current_fixture: []const u8 = "";

/// Whether this process records anything.
pub fn enabled() bool {
    return file != null;
}

/// Read the budget; open this process's record file when
/// `BENI_TEST_TIMING` names a directory, and write its `start` record.
/// `the_io` must stay usable for the life of the process and from any
/// thread.
pub fn open(the_io: Io, environ: std.process.Environ, argv0: []const u8) void {
    const a = std.heap.page_allocator;
    io = the_io;
    const instructions = envNumber(environ, budget_instructions_env_var);
    if (instructions != 0) {
        budget_unit = .instructions;
        budget_limit = instructions;
    }
    const dir_path = environ.getAlloc(a, env_var) catch return;
    if (dir_path.len == 0) return;
    process_start = Io.Clock.awake.now(io);
    const binary = std.fs.path.basename(argv0);
    const pid: i64 = @intCast(std.posix.system.getpid());
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(io, dir_path) catch |err| std.debug.panic("{s}: cannot create {s}: {t}", .{ env_var, dir_path, err });
    const name = std.fmt.allocPrint(a, "{s}/{s}-{d}.jsonl", .{ dir_path, binary, pid }) catch @panic("out of memory");
    file = cwd.createFile(io, name, .{}) catch |err| std.debug.panic("{s}: cannot create {s}: {t}", .{ env_var, name, err });
    write(.{ .start = .{
        .binary = binary,
        .pid = pid,
        .shard = envOr(environ, "BENI_TEST_SHARD"),
        .part = envOr(environ, "BENI_CORPUS_PART"),
        .perf_shard = envOr(environ, "BENI_PERF_SHARD"),
    } });
}

/// A whole number from the environment; unset or empty is 0.
fn envNumber(environ: std.process.Environ, key: []const u8) u64 {
    const text = envOr(environ, key);
    if (text.len == 0) return 0;
    return std.fmt.parseUnsigned(u64, text, 10) catch
        std.debug.panic("{s} must be a whole number, got '{s}'", .{ key, text });
}

fn envOr(environ: std.process.Environ, key: []const u8) []const u8 {
    return environ.getAlloc(std.heap.page_allocator, key) catch "";
}

/// Append one record. A record that does not fit the buffer is dropped
/// rather than cut, so every line of the file parses.
pub fn write(record: Record) void {
    const f = file orelse return;
    var buffer: [16 * 1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    std.json.Stringify.value(record, .{}, &w) catch return;
    w.writeByte('\n') catch return;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    f.writeStreamingAll(io, w.buffered()) catch {};
}

/// Write the `exit` record and close the file.
pub fn close(tests: u32) void {
    const f = file orelse return;
    const self = usage(.self);
    const children = usage(.children);
    write(.{ .exit = .{
        .tests = tests,
        .wall_us = sinceUs(process_start),
        .user_us = self.user_us,
        .sys_us = self.sys_us,
        .max_rss_kib = self.max_rss_kib,
        .child_user_us = children.user_us,
        .child_sys_us = children.sys_us,
        .child_max_rss_kib = children.max_rss_kib,
    } });
    f.close(io);
    file = null;
}

/// Now, on the monotonic clock.
pub fn now() Io.Timestamp {
    return Io.Clock.awake.now(io);
}

/// Microseconds from `start` to now, on the monotonic clock.
pub fn sinceUs(start: Io.Timestamp) u64 {
    return durationUs(start.durationTo(now()));
}

/// The calling thread's CPU time so far.
pub fn threadCpu() Io.Timestamp {
    return Io.Clock.cpu_thread.now(io);
}

pub fn durationUs(d: Io.Duration) u64 {
    return @intCast(@max(0, @divTrunc(d.nanoseconds, std.time.ns_per_us)));
}

pub const Usage = struct {
    user_us: u64 = 0,
    sys_us: u64 = 0,
    max_rss_kib: u64 = 0,
    minor_faults: u64 = 0,
};

/// The resource usage of this process, or of its reaped children.
pub fn usage(who: enum { self, children }) Usage {
    if (builtin.os.tag == .windows) return .{};
    const R = std.posix.rusage;
    return fromRusage(std.posix.getrusage(switch (who) {
        .self => R.SELF,
        .children => R.CHILDREN,
    }));
}

/// `ru` in the units the records use. `maxrss` is KiB on Linux and bytes on
/// the BSDs and macOS.
pub fn fromRusage(ru: std.posix.rusage) Usage {
    const rss: u64 = @intCast(@max(0, ru.maxrss));
    return .{
        .user_us = timevalUs(ru.utime),
        .sys_us = timevalUs(ru.stime),
        .max_rss_kib = if (builtin.os.tag.isDarwin() or builtin.os.tag.isBSD()) rss / 1024 else rss,
        .minor_faults = @intCast(@max(0, ru.minflt)),
    };
}

fn timevalUs(tv: std.posix.timeval) u64 {
    return @intCast(@max(0, @as(i64, tv.sec) * std.time.us_per_s + @as(i64, tv.usec)));
}
