//! CLI entry (docs/design/frontend.md §1): parse arguments, dispatch, map
//! outcomes to exit codes. Nothing here is logic worth testing in isolation;
//! `Cli.zig` owns the parsing and `Session.zig` owns the work, and the
//! black-box suite drives this binary end to end.
//!
//! Exit codes: 0 no errors, 1 at least one error diagnostic, 2 usage or I/O
//! failure. stdout carries the product; stderr carries diagnostics and usage
//! errors and nothing else. `dump` exits 0 even when the file has lexical,
//! syntax or lowering errors: its product is the token stream, the tree or
//! the lowered file, placeholders and all, and the diagnostics still go to
//! stderr. `check` and `dump --stage=bir` run the lowering phases;
//! `--stage=tokens|ast` stop after the parser, so those dumps carry only
//! the diagnostics of the stages they show.

const std = @import("std");
const Io = std.Io;
const beni = @import("beni");
const Cli = beni.Cli;
const Session = beni.Session;
const SourceStore = beni.SourceStore;

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const args = init.minimal.args.toSlice(arena) catch return fail(stderr, "beni: out of memory", .{});
    const parsed = Cli.parse(arena, if (args.len == 0) args else args[1..]) catch
        return fail(stderr, "beni: out of memory", .{});
    const command = switch (parsed) {
        .command => |c| c,
        .usage => |u| return fail(stderr, "{s}", .{u.message()}),
    };

    switch (command) {
        .version => {
            stdout.print("beni {s}\n", .{beni.version}) catch return 2;
            return 0;
        },
        .help => {
            stdout.writeAll(Cli.usage) catch return 2;
            return 0;
        },
        .check => |check| return runCheck(gpa, io, stderr, check),
        .fmt => |fmt| return beni.fmt.Command.run(gpa, io, stdout, stderr, sessionOptions(fmt.common), fmt),
        .dump => |dump| return runDump(gpa, io, stdout, stderr, dump),
    }
}

fn fail(stderr: *Io.Writer, comptime fmt: []const u8, args: anytype) u8 {
    stderr.print(fmt ++ "\n", args) catch {};
    return 2;
}

fn sessionOptions(common: Cli.Common) Session.Options {
    const cpus: u32 = @intCast(@min(std.Thread.getCpuCount() catch 1, std.math.maxInt(u32) / 4));
    // More workers than this cannot help and does hurt: every worker costs
    // an `Arena`, an interner pre-seeded with the well-known symbols, and a
    // thread. `--jobs=20000` on a six-byte file spent 7.6 s building them.
    // Four per CPU leaves room for an oversubscribed build to ask for more
    // than it has cores without the flag becoming a way to hang the tool.
    const jobs: u32 = @min(common.jobs orelse cpus, cpus *| 4);
    return .{
        .jobs = @max(jobs, 1),
        .diagnostics = switch (common.diagnostics) {
            .text => .text,
            .json => .json,
        },
        .self_profile = common.self_profile,
        .root = common.root,
        .core = common.core,
    };
}

/// Run `phases` over `paths`, mapping the driver's failure to the exit-2
/// message. Returns the summary, or the exit code to return.
fn runSession(session: *Session, stderr: *Io.Writer, paths: []const []const u8, phases: Session.Phases) union(enum) { summary: Session.Summary, exit: u8 } {
    const summary = session.run(paths, phases, stderr) catch |err| switch (err) {
        error.InputPath => {
            const failure = session.io_failure.?;
            return .{ .exit = fail(stderr, "beni: cannot read '{s}': {t}", .{ failure.path, failure.err }) };
        },
        else => |e| return .{ .exit = fail(stderr, "beni: {t}", .{e}) },
    };
    return .{ .summary = summary };
}

fn runCheck(gpa: std.mem.Allocator, io: Io, stderr: *Io.Writer, check: Cli.Check) u8 {
    var session = Session.init(gpa, io, sessionOptions(check.common)) catch return fail(stderr, "beni: out of memory", .{});
    defer session.deinit();
    const summary = switch (runSession(&session, stderr, check.paths, Session.lower_phases)) {
        .summary => |s| s,
        .exit => |code| return code,
    };
    return if (summary.errors > 0) 1 else 0;
}

fn runDump(gpa: std.mem.Allocator, io: Io, stdout: *Io.Writer, stderr: *Io.Writer, dump: Cli.Dump) u8 {
    var session = Session.init(gpa, io, sessionOptions(dump.common)) catch return fail(stderr, "beni: out of memory", .{});
    defer session.deinit();
    const phases: Session.Phases = switch (dump.stage) {
        .tokens, .ast => Session.parse_phases,
        .bir => Session.lower_phases,
    };
    switch (runSession(&session, stderr, &.{dump.file}, phases)) {
        .summary => {},
        .exit => |code| return code,
    }
    // A directory argument would enumerate many files; the dump is of one.
    if (session.store.count() != 1) return fail(stderr, "beni: dump needs exactly one file", .{});
    const file: SourceStore.Index = @enumFromInt(0);
    switch (dump.stage) {
        .tokens => beni.dump.tokens.write(
            stdout,
            session.store.bytes(file),
            session.artifacts.tokens(file),
            session.artifacts.comments(file),
            session.store.lineStarts(file),
        ) catch return 2,
        .ast => beni.dump.ast.write(
            stdout,
            session.store.bytes(file),
            session.artifacts.tokens(file),
            session.artifacts.comments(file),
            session.store.lineStarts(file),
            session.artifacts.ast(file),
            .{ .positions = dump.positions },
        ) catch return 2,
        .bir => beni.dump.bir.write(
            stdout,
            session.store.bytes(file),
            session.artifacts.comments(file),
            session.artifacts.bir(file),
            .fromGlobal(&session.interner),
        ) catch return 2,
    }
    return 0;
}
