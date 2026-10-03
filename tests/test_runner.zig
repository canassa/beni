//! The test runner of every beni test binary: std's default runner, cut
//! down to what the build graph uses, plus sharding.
//!
//! One test binary is run as several processes, each of which runs only its
//! share of the tests: `BENI_TEST_SHARD=k/n` selects the tests whose index
//! `i` satisfies `i % n == k`, so neighbours in a file (often of a similar
//! cost) land in different processes. Unset or empty, the process runs every
//! test. `build.zig` sets it on each run, so the shards of one binary
//! partition its tests exactly, and a test cannot be left out of every
//! process.
//!
//! Two ways in, like std's runner:
//!   - `--listen=-`: the `std.zig.Server` protocol the build runner speaks,
//!     reporting the shard's tests as the binary's whole list.
//!   - no argument: run the shard and print one line per test with its wall
//!     and CPU time in milliseconds and what it spent against the budget
//!     (`zig build` does not show them), then a summary; exit 1 on any
//!     failure, leak or logged error.
//!
//! `BENI_TEST_BUDGET_INSTRUCTIONS=<n>` is the budget of every test: one
//! that passes but retired more user-space instructions than that, its own
//! and those of every thread and process it created, fails, named with its
//! count (`timing.Counter`). Where no instruction counter can be opened the
//! budget is `BENI_TEST_BUDGET_CPU_MS` of CPU time instead, user plus
//! system from `getrusage`, and the process says so once. `build.zig` sets
//! both on every run of the gates' binaries (`-Dtest-budget=`); unset,
//! nothing is enforced. A test that runs independent cases holds each to
//! the budget instead (`timing.budget_unit`).
//!
//! `--node-version=<text>` hands the black-box harness the Node version the
//! build asked for once (`node_version`).
//!
//! `BENI_TEST_TIMING=<dir>` makes the process record each test's wall and
//! CPU time, and everything the black-box harness spawns, into `<dir>`
//! (`timing.zig`); `zig build test-time-report` reads the records.
//!
//! Each test gets a fresh `std.testing.allocator` (leaks are reported per
//! test), a fresh `std.testing.io`, and `std.testing.environ`. Fuzz tests run
//! their corpus and the empty input, as std's runner does in a build that is
//! not `-ffuzz`; this runner refuses `-ffuzz` builds.

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
/// The recorder, reached by the black-box harness as `@import("root").timing`.
pub const timing = @import("timing.zig");

/// `--node-version=<text>`: what `node --version` printed, asked once by
/// the build for every test process (`build.zig`), so a black-box process
/// does not start Node to learn it (`tests/blackbox/run_hash.zig`). Empty
/// when not given, and then the harness asks Node itself.
pub var node_version: []const u8 = "";

comptime {
    if (builtin.fuzz) @compileError("tests/test_runner.zig does not support -ffuzz builds");
}

pub const std_options: std.Options = .{
    .logFn = log,
};

var log_err_count: usize = 0;
var fba_buffer: [16 * 1024]u8 = undefined;
var fba: std.heap.FixedBufferAllocator = .init(&fba_buffer);
var stdin_buffer: [4096]u8 = undefined;
var stdout_buffer: [4096]u8 = undefined;
const runner_io: Io = Io.Threaded.global_single_threaded.io();

/// The indices into `builtin.test_functions` this process runs, ascending.
var selected: []u32 = &.{};

pub fn main(init: std.process.Init.Minimal) void {
    const args = init.args.toSlice(fba.allocator()) catch @panic("unable to parse command line arguments");
    var listen = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--listen=-")) {
            listen = true;
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                @panic("unable to parse --seed command line argument");
        } else if (std.mem.startsWith(u8, arg, "--node-version=")) {
            node_version = arg["--node-version=".len..];
        } else if (std.mem.startsWith(u8, arg, "--cache-dir=")) {
            // Only a fuzzing build reads it.
        } else {
            std.debug.panic("unrecognized command line argument: {s}", .{arg});
        }
    }
    selectShard(init.environ);
    timing.open(runner_io, init.environ, args[0]);
    // The tests run on a thread with a stack of their own rather than on the
    // main thread, whose size is whatever the shell's limit is: `zig build`
    // raises that limit for everything it spawns and a shell does not, so
    // the deep-tree tests passed under the build and overflowed when the
    // binary was run by hand.
    const thread = std.Thread.spawn(.{ .stack_size = test_stack_size }, runAll, .{ init, listen }) catch
        return runAll(init, listen);
    thread.join();
}

/// The stack every test runs on. The compiler walks trees by recursion on
/// threads of 64 MiB; a Debug test binary's frames are several times a
/// release build's, and the deepest unit tests walk the deepest trees the
/// parser admits. Only the pages a test touches are ever mapped in.
const test_stack_size = 256 * 1024 * 1024;

fn runAll(init: std.process.Init.Minimal, listen: bool) void {
    // On the thread the tests run on, so the count covers them and every
    // thread and process they create.
    timing.openThreadCounter();
    if (listen) {
        mainServer(init) catch |err| std.debug.panic("internal test runner failure: {t}", .{err});
    } else {
        mainTerminal(init);
    }
}

/// Fill `selected` from `BENI_TEST_SHARD`.
fn selectShard(environ: std.process.Environ) void {
    const all = builtin.test_functions.len;
    var k: u32 = 0;
    var n: u32 = 1;
    const text = environ.getAlloc(std.heap.page_allocator, "BENI_TEST_SHARD") catch |err| switch (err) {
        error.EnvironmentVariableMissing => "",
        else => std.debug.panic("cannot read BENI_TEST_SHARD: {t}", .{err}),
    };
    if (text.len != 0) {
        const slash = std.mem.indexOfScalar(u8, text, '/') orelse
            std.debug.panic("BENI_TEST_SHARD must be k/n, got '{s}'", .{text});
        k = std.fmt.parseUnsigned(u32, text[0..slash], 10) catch
            std.debug.panic("BENI_TEST_SHARD must be k/n, got '{s}'", .{text});
        n = std.fmt.parseUnsigned(u32, text[slash + 1 ..], 10) catch
            std.debug.panic("BENI_TEST_SHARD must be k/n, got '{s}'", .{text});
        if (n == 0 or k >= n) std.debug.panic("BENI_TEST_SHARD must be k/n with k < n, got '{s}'", .{text});
    }
    const count = (all + n - 1 - k) / n;
    selected = std.heap.page_allocator.alloc(u32, count) catch @panic("out of memory");
    for (selected, 0..) |*s, j| s.* = @intCast(k + j * n);
}

const Outcome = struct {
    status: enum { pass, skip, fail },
    /// Allocations the test left behind in `std.testing.allocator`.
    leaks: usize,
    /// The CPU the test spent, its own and its children's.
    cpu_us: u64,
    /// What the test spent in the budget's unit (`timing.budget_unit`),
    /// less what its cases were held to on their own.
    spent: u64,
};

/// Set up the per-test globals std's runner sets, run test `index`, tear
/// down.
fn runOne(init: std.process.Init.Minimal, index: u32) Outcome {
    testing.environ = init.environ;
    testing.allocator_instance = .init(std.heap.page_allocator, .{
        .canary = 0xc3a701ba,
        .check_write_after_free = true,
    });
    testing.io_instance = .init(testing.allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    testing.log_level = .warn;
    log_err_count = 0;
    const test_fn = builtin.test_functions[index];
    timing.current_test = test_fn.name;
    timing.cases_spent.store(0, .monotonic);
    const started: Started = .now();
    const spent_before = timing.testSpent();
    var status: @FieldType(Outcome, "status") = if (test_fn.func()) |_|
        .pass
    else |err| switch (err) {
        error.SkipZigTest => .skip,
        else => s: {
            std.debug.print("{s}: FAIL ({t})\n", .{ test_fn.name, err });
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            break :s .fail;
        },
    };
    testing.io_instance.deinit();
    const leaks = testing.allocator_instance.deinit();
    const cpu_us = started.cpuUs();
    const spent = (timing.testSpent() -% spent_before) -| timing.cases_spent.load(.monotonic);
    // The budget (`timing.budget_unit`): instructions, which a loaded
    // machine does not inflate, or CPU time where they cannot be counted.
    if (status == .pass and timing.budget_unit != .none and spent > timing.budget_limit) {
        const got = timing.describe(spent);
        const limit = timing.describe(timing.budget_limit);
        // The amount first: the build runner cuts a long line.
        std.debug.print("FAIL: {d} {s}, over the budget of {d} (its own and its children's): {s}\n", .{
            got.value, got.unit, limit.value, test_fn.name,
        });
        status = .fail;
    }
    if (timing.enabled()) started.record(test_fn.name, status, spent);
    timing.current_test = "";
    return .{ .status = status, .leaks = leaks, .cpu_us = cpu_us, .spent = spent };
}

/// The clocks at the start of a test, for its `timing.Test` record.
const Started = struct {
    at: Io.Timestamp,
    self: timing.Usage,
    children: timing.Usage,

    fn now() Started {
        return .{ .at = timing.now(), .self = timing.usage(.self), .children = timing.usage(.children) };
    }

    /// The CPU the process and its reaped children spent since `s`.
    fn cpuUs(s: Started) u64 {
        const self = timing.usage(.self);
        const children = timing.usage(.children);
        return (self.user_us -| s.self.user_us) + (self.sys_us -| s.self.sys_us) +
            (children.user_us -| s.children.user_us) + (children.sys_us -| s.children.sys_us);
    }

    fn record(s: Started, name: []const u8, status: @FieldType(Outcome, "status"), spent: u64) void {
        const self = timing.usage(.self);
        const children = timing.usage(.children);
        timing.write(.{ .@"test" = .{
            .name = name,
            .status = @tagName(status),
            .wall_us = timing.sinceUs(s.at),
            .user_us = self.user_us -| s.self.user_us,
            .sys_us = self.sys_us -| s.self.sys_us,
            .child_user_us = children.user_us -| s.children.user_us,
            .child_sys_us = children.sys_us -| s.children.sys_us,
            .budget_unit = @tagName(timing.budget_unit),
            .spent = spent,
        } });
    }
};

fn mainServer(init: std.process.Init.Minimal) !void {
    var stdin_reader: Io.File.Reader = .initStreaming(.stdin(), runner_io, &stdin_buffer);
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), runner_io, &stdout_buffer);
    var server: std.zig.Server = .{
        .in = &stdin_reader.interface,
        .out = &stdout_writer.interface,
    };
    try server.serveStringMessage(.zig_version, builtin.zig_version_string);

    while (true) {
        const hdr = try server.receiveMessage();
        switch (hdr.tag) {
            .exit => {
                timing.close(@intCast(selected.len));
                return std.process.exit(0);
            },
            .query_test_metadata => {
                var gpa_state: std.heap.DebugAllocator(.{}) = .init;
                defer _ = gpa_state.deinit();
                const gpa = gpa_state.allocator();

                var string_bytes: std.ArrayList(u8) = .empty;
                defer string_bytes.deinit(gpa);
                try string_bytes.append(gpa, 0); // 0 is the null string.
                const names = try gpa.alloc(u32, selected.len);
                defer gpa.free(names);
                const expected_panic_msgs = try gpa.alloc(u32, selected.len);
                defer gpa.free(expected_panic_msgs);
                for (selected, names, expected_panic_msgs) |index, *name, *panic_msg| {
                    const test_name = builtin.test_functions[index].name;
                    name.* = @intCast(string_bytes.items.len);
                    try string_bytes.appendSlice(gpa, test_name);
                    try string_bytes.append(gpa, 0);
                    panic_msg.* = 0;
                }
                try server.serveTestMetadata(.{
                    .names = names,
                    .expected_panic_msgs = expected_panic_msgs,
                    .string_bytes = string_bytes.items,
                });
            },
            .run_test => {
                const position = try server.receiveBody_u32();
                try server.serveStringMessage(.test_started, &.{});
                const outcome = runOne(init, selected[position]);
                const Flags = std.zig.Server.Message.TestResults.Flags;
                try server.serveTestResults(.{
                    .index = position,
                    .flags = .{
                        .status = switch (outcome.status) {
                            .pass => .pass,
                            .skip => .skip,
                            .fail => .fail,
                        },
                        .fuzz = false,
                        .log_err_count = std.math.lossyCast(@FieldType(Flags, "log_err_count"), log_err_count),
                        .leak_count = std.math.lossyCast(@FieldType(Flags, "leak_count"), outcome.leaks),
                    },
                });
            },
            else => {
                std.debug.print("unsupported message: {x}\n", .{@backingInt(hdr.tag)});
                std.process.exit(1);
            },
        }
    }
}

fn mainTerminal(init: std.process.Init.Minimal) void {
    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var leaked: usize = 0;
    var logged: usize = 0;
    for (selected) |index| {
        const start = Io.Clock.awake.now(runner_io);
        const outcome = runOne(init, index);
        const elapsed = start.durationTo(Io.Clock.awake.now(runner_io));
        const ms = @as(f64, @floatFromInt(elapsed.nanoseconds)) / std.time.ns_per_ms;
        const cpu_ms = @as(f64, @floatFromInt(outcome.cpu_us)) / std.time.us_per_ms;
        const spent = timing.describe(outcome.spent);
        std.debug.print("{d:>10.1} ms  {d:>10.1} ms CPU  {d:>8} {s}  {t}  {s}\n", .{ ms, cpu_ms, spent.value, spent.unit, outcome.status, builtin.test_functions[index].name });
        switch (outcome.status) {
            .pass => passed += 1,
            .skip => skipped += 1,
            .fail => failed += 1,
        }
        if (outcome.leaks != 0) leaked += 1;
        if (log_err_count != 0) logged += 1;
    }
    timing.close(@intCast(selected.len));
    std.debug.print("{d} passed; {d} skipped; {d} failed; {d} leaked; {d} logged errors.\n", .{ passed, skipped, failed, leaked, logged });
    if (failed != 0 or leaked != 0 or logged != 0) std.process.exit(1);
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@backingInt(level) <= @backingInt(std.log.Level.err)) log_err_count +|= 1;
    if (@backingInt(level) <= @backingInt(testing.log_level)) {
        std.debug.print("[" ++ @tagName(scope) ++ "] (" ++ @tagName(level) ++ "): " ++ format ++ "\n", args);
    }
}

/// `std.testing.fuzz` lands here: run the corpus, then the empty input.
pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), *testing.Smith) anyerror!void,
    options: testing.FuzzInputOptions,
) anyerror!void {
    for (options.corpus) |input| {
        var smith: testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }
    var smith: testing.Smith = .{ .in = "" };
    try testOne(context, &smith);
}
