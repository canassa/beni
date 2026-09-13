//! The one object everything hangs off (docs/design/frontend.md §4,
//! fast-compiler.md §4): gpa, options, the `SourceStore`, the global
//! `InternPool`, the `Profile`, and the workers. There is no global mutable
//! state anywhere in beni; a daemon (M4) keeps one `Session` alive across
//! edits, which is why every structure here is owned explicitly and reset
//! rather than rebuilt.
//!
//! `run` is deterministic by construction, not by testing:
//!   1. Files are enumerated, sorted and numbered serially before any thread
//!      starts; the file index is the only id anything is keyed by.
//!   2. Workers pull file indices from one atomic counter. Which worker takes
//!      which file is unobservable: every per-file result lands in a column
//!      of that file's index, and every per-worker tally is a commutative sum.
//!   3. Interners are merged in worker index order, never completion order,
//!      so global symbol numbering does not depend on scheduling.
//!   4. Diagnostics are gathered in file index order (each file's are
//!      produced serially by one worker, in source order) and then stably
//!      sorted by the schema's comparator.
//! Two runs with different `--jobs` therefore produce identical bytes on
//! every stream; the black-box determinism scenario checks exactly that.
//!
//! The per-file phase is a function pointer (`Phases`): M0 installs a stub
//! that reads the file; M1 installs lex → parse → lower without touching the
//! driver.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const diagnostic = @import("diagnostic");
const Arena = @import("Arena.zig");
const InternPool = @import("InternPool.zig");
const Profile = @import("Profile.zig");
const SourceStore = @import("SourceStore.zig");
const render_text = @import("render/text.zig");
const render_json = @import("render/json.zig");

const Session = @This();

gpa: Allocator,
io: Io,
options: Options,
store: SourceStore = .{},
interner: InternPool.Global,
profile: Profile,
workers: []Worker,
/// Every diagnostic of the last run, in emission order after `run`.
/// Messages are gpa-owned; file paths point into `store`.
diagnostics: std.ArrayList(diagnostic.Diagnostic) = .empty,
/// Set when `run` fails on I/O so `main` can say which path.
io_failure: ?IoFailure = null,
/// Shared by all workers: the next file index to claim.
next_file: std.atomic.Value(u32) = .init(0),

pub const DiagnosticsFormat = enum { text, json };

pub const Options = struct {
    /// Worker count, at least 1. `1` runs on the calling thread.
    jobs: u32,
    diagnostics: DiagnosticsFormat = .text,
    /// Path of the trace to write at the end of `run`, if any.
    self_profile: ?[]const u8 = null,
    /// `--root`: what module names are relative to.
    root: ?[]const u8 = null,
    /// `--core`: the files are the core package; `foreign` declarations are
    /// legal (language.md §5.4). Consumed by lowering in M1c.
    core: bool = false,
    /// Capacity of each worker's profile buffer.
    profile_events_per_thread: usize = 4096,
};

pub const IoFailure = struct {
    path: []const u8,
    err: anyerror,
};

/// The per-file work. M1 PLUG POINT: replace `per_file` with the
/// lex → parse → lower pipeline; the driver does not change.
pub const Phases = struct {
    per_file: *const fn (session: *Session, worker: *Worker, file: SourceStore.Index) anyerror!void,
};

/// M0: read the bytes, count them, build the line table.
pub const read_phases: Phases = .{ .per_file = readPhase };

pub const Worker = struct {
    index: u32,
    arena: Arena,
    interner: InternPool.Local = .empty,
    /// This worker's diagnostics, each tagged with its file. Appended in
    /// source order per file; files in the order the worker took them.
    diagnostics: std.ArrayList(Pending) = .empty,
    /// Summed into the profile after the join.
    counters: [Profile.Counter.count]u64 = @splat(0),
    /// The first I/O error this worker hit, and on which file.
    failure: ?struct { file: SourceStore.Index, err: anyerror } = null,

    pub const Pending = struct { file: SourceStore.Index, diagnostic: diagnostic.Diagnostic };

    /// Record a diagnostic for `file`. `message` is copied into gpa memory
    /// owned by the session.
    pub fn report(worker: *Worker, session: *Session, file: SourceStore.Index, code: diagnostic.Code, start: diagnostic.Position, end: diagnostic.Position, message: []const u8) Allocator.Error!void {
        const owned = try session.gpa.dupe(u8, message);
        errdefer session.gpa.free(owned);
        try worker.diagnostics.append(session.gpa, .{ .file = file, .diagnostic = .{
            .code = code,
            .severity = .@"error",
            .span = .{ .file = session.store.path(file), .start = start, .end = end },
            .title = diagnostic.title(code),
            .message = owned,
        } });
    }

    pub fn addCounter(worker: *Worker, counter: Profile.Counter, value: u64) void {
        worker.counters[@intFromEnum(counter)] += value;
    }
};

pub fn init(gpa: Allocator, io: Io, options: Options) Allocator.Error!Session {
    std.debug.assert(options.jobs >= 1);
    var session: Session = .{
        .gpa = gpa,
        .io = io,
        .options = options,
        .interner = try InternPool.Global.init(gpa),
        .profile = undefined,
        .workers = &.{},
    };
    errdefer session.interner.deinit(gpa);
    session.profile = try Profile.init(gpa, io, .{
        .enabled = options.self_profile != null,
        .threads = options.jobs,
        .events_per_thread = options.profile_events_per_thread,
    });
    errdefer session.profile.deinit(gpa);
    session.workers = try gpa.alloc(Worker, options.jobs);
    for (session.workers, 0..) |*worker, i| {
        worker.* = .{ .index = @intCast(i), .arena = .init(std.heap.page_allocator) };
    }
    return session;
}

pub fn deinit(session: *Session) void {
    const gpa = session.gpa;
    for (session.workers) |*worker| {
        for (worker.diagnostics.items) |p| gpa.free(p.diagnostic.message);
        worker.diagnostics.deinit(gpa);
        worker.interner.deinit(gpa);
        worker.arena.deinit();
    }
    gpa.free(session.workers);
    session.diagnostics.deinit(gpa);
    session.profile.deinit(gpa);
    session.interner.deinit(gpa);
    session.store.deinit(gpa);
    session.* = undefined;
}

pub const Summary = struct {
    files: u32,
    errors: u32,
    warnings: u32,
};

pub const RunError = error{
    /// An argument path could not be enumerated, or a file could not be
    /// read. `io_failure` says which.
    InputPath,
} || Allocator.Error || std.Thread.SpawnError || Io.Writer.Error;

/// Enumerate `paths`, run `phases.per_file` over every file on
/// `options.jobs` workers, merge, sort, and render diagnostics to `stderr`.
pub fn run(session: *Session, paths: []const []const u8, phases: Phases, stderr: *Io.Writer) RunError!Summary {
    const gpa = session.gpa;

    // 1. Enumerate — serial, sorted, numbered.
    const enumerate_token = session.profile.begin();
    for (paths) |p| {
        session.store.addPath(gpa, session.io, p, session.options.root) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                session.io_failure = .{ .path = p, .err = err };
                return error.InputPath;
            },
        };
    }
    try session.store.finish(gpa);
    session.profile.end(0, enumerate_token, .enumerate, Profile.Event.no_file, 0);

    // Module-path validation is decided by the path alone, so it is
    // reported here, serially, before any worker touches the file.
    for (0..session.store.count()) |i| {
        const file: SourceStore.Index = @enumFromInt(i);
        if (session.store.modulePathValid(file)) continue;
        try session.reportInvalidModulePath(file);
    }

    // 2. Per-file phases on workers.
    if (session.workers.len == 1) {
        session.workerMain(&session.workers[0], phases);
    } else {
        var threads: std.ArrayList(std.Thread) = .empty;
        defer threads.deinit(gpa);
        try threads.ensureTotalCapacity(gpa, session.workers.len);
        defer for (threads.items) |t| t.join();
        for (session.workers) |*worker| {
            threads.appendAssumeCapacity(try std.Thread.spawn(.{}, workerMain, .{ session, worker, phases }));
        }
    }
    session.next_file.store(0, .monotonic);
    for (session.workers) |worker| {
        if (worker.failure) |f| {
            session.io_failure = .{ .path = session.store.path(f.file), .err = f.err };
            return error.InputPath;
        }
    }

    // 3. Merge interners in worker index order.
    const merge_token = session.profile.begin();
    for (session.workers) |*worker| {
        const remap = try session.interner.merge(gpa, &worker.interner);
        // M1 PLUG POINT: apply `remap` to the worker's token payloads and
        // Bir symbol references. M0 has no tokens, so the table is dropped.
        gpa.free(remap);
    }
    session.profile.end(0, merge_token, .merge_interners, Profile.Event.no_file, 0);

    // 4. Collect (file order, then stable sort), count, render.
    try session.collectDiagnostics();
    var summary: Summary = .{ .files = session.store.count(), .errors = 0, .warnings = 0 };
    for (session.diagnostics.items) |d| switch (d.severity) {
        .@"error" => summary.errors += 1,
        .warning => summary.warnings += 1,
    };

    for (session.workers) |worker| {
        inline for (@typeInfo(Profile.Counter).@"enum".fields) |field| {
            session.profile.addCounter(@enumFromInt(field.value), worker.counters[field.value]);
        }
    }
    session.profile.addCounter(.files, summary.files);
    session.profile.addCounter(.diagnostics, session.diagnostics.items.len);

    const render_token = session.profile.begin();
    if (session.diagnostics.items.len != 0) {
        switch (session.options.diagnostics) {
            .text => try render_text.render(stderr, session.diagnostics.items, .{ .context = session, .lookup = lookupSource }),
            .json => try render_json.render(stderr, session.diagnostics.items),
        }
        try stderr.flush();
    }
    session.profile.end(0, render_token, .render, Profile.Event.no_file, 0);

    if (session.options.self_profile) |profile_path| try session.writeProfile(profile_path);
    return summary;
}

fn workerMain(session: *Session, worker: *Worker, phases: Phases) void {
    while (true) {
        const i = session.next_file.fetchAdd(1, .monotonic);
        if (i >= session.store.count()) return;
        const file: SourceStore.Index = @enumFromInt(i);
        phases.per_file(session, worker, file) catch |err| {
            if (worker.failure == null) worker.failure = .{ .file = file, .err = err };
            return;
        };
        // Each file's artifacts are moved to session storage inside the
        // phase, so the arena is free to be reused for the next one.
        worker.arena.reset(.retain_capacity);
    }
}

/// The M0 per-file phase: read the bytes into the store, count them, and
/// build the line table the text renderer needs. `readPhase` allocates the
/// table from the gpa because it outlives the phase (session storage).
fn readPhase(session: *Session, worker: *Worker, file: SourceStore.Index) anyerror!void {
    const token = session.profile.begin();
    try session.store.read(session.gpa, session.io, file);
    const text = session.store.bytes(file);
    const line_starts = try SourceStore.scanLineStarts(session.gpa, text);
    session.store.setLineStarts(session.gpa, file, line_starts);
    worker.addCounter(.bytes, text.len);
    session.profile.end(worker.index, token, .read, file.int(), @intCast(text.len));
}

fn reportInvalidModulePath(session: *Session, file: SourceStore.Index) Allocator.Error!void {
    const p = session.store.path(file);
    const message = try std.fmt.allocPrint(session.gpa,
        \\I cannot turn the path `{s}` into a module name.
        \\
        \\A module name comes from the path: `src/Json/Decode.beni` is `Json.Decode`. Every
        \\segment of the path after the source root must be an upper identifier — a capital
        \\letter followed by letters, digits or underscores.
    , .{p});
    errdefer session.gpa.free(message);
    // Reported on worker 0's list so it is collected like any other; the
    // sort keys it by file and position regardless.
    try session.workers[0].diagnostics.append(session.gpa, .{ .file = file, .diagnostic = .{
        .code = .invalid_module_path,
        .severity = .@"error",
        .span = .{ .file = p, .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 1 } },
        .title = diagnostic.title(.invalid_module_path),
        .message = message,
    } });
}

/// Gather every worker's diagnostics into `session.diagnostics` in file
/// index order (stable on the per-file production order), then stably sort
/// by the schema comparator. Ownership of messages stays with the workers'
/// lists until `deinit`.
fn collectDiagnostics(session: *Session) Allocator.Error!void {
    const gpa = session.gpa;
    var total: usize = 0;
    for (session.workers) |w| total += w.diagnostics.items.len;
    session.diagnostics.clearRetainingCapacity();
    try session.diagnostics.ensureTotalCapacity(gpa, total);

    // Stable sort each worker's list by file (already grouped), then a
    // k-way pick by file index keeps the whole thing in file order.
    var cursors = try gpa.alloc(usize, session.workers.len);
    defer gpa.free(cursors);
    @memset(cursors, 0);
    for (session.workers) |*w| {
        std.mem.sort(Worker.Pending, w.diagnostics.items, {}, struct {
            fn lessThan(_: void, a: Worker.Pending, b: Worker.Pending) bool {
                return a.file.int() < b.file.int();
            }
        }.lessThan);
    }
    while (true) {
        var best: ?usize = null;
        for (session.workers, cursors) |w, c| {
            if (c >= w.diagnostics.items.len) continue;
            const file = w.diagnostics.items[c].file.int();
            if (best == null or file < session.workers[best.?].diagnostics.items[cursors[best.?]].file.int()) {
                best = w.index;
            }
        }
        const b = best orelse break;
        session.diagnostics.appendAssumeCapacity(session.workers[b].diagnostics.items[cursors[b]].diagnostic);
        cursors[b] += 1;
    }
    diagnostic.sort(session.diagnostics.items);
}

fn lookupSource(context: *const anyopaque, file: []const u8) ?[]const u8 {
    const session: *const Session = @ptrCast(@alignCast(context));
    const index = session.store.find(file) orelse return null;
    return session.store.bytes(index);
}

fn writeProfile(session: *Session, profile_path: []const u8) RunError!void {
    var file = Io.Dir.cwd().createFile(session.io, profile_path, .{}) catch |err| {
        session.io_failure = .{ .path = profile_path, .err = err };
        return error.InputPath;
    };
    defer file.close(session.io);
    var buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(session.io, &buffer);
    try session.profile.write(&writer.interface, session.store.paths());
    try writer.interface.flush();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "collectDiagnostics orders by file then comparator regardless of worker" {
    var session = try Session.init(testing.allocator, testing.io, .{ .jobs = 2, .diagnostics = .json });
    defer session.deinit();
    // Two fake files so the spans have paths to point at.
    try session.store.addPending(testing.allocator, "a/B.beni", 2);
    try session.store.addPending(testing.allocator, "a/A.beni", 2);
    try session.store.finish(testing.allocator);
    const file_a: SourceStore.Index = @enumFromInt(0);
    const file_b: SourceStore.Index = @enumFromInt(1);

    // Worker 1 reports on file B first, then A; worker 0 only on B.
    try session.workers[1].report(&session, file_b, .tab_in_source, .{ .line = 2, .col = 1 }, .{ .line = 2, .col = 2 }, "w1-b");
    try session.workers[1].report(&session, file_a, .tab_in_source, .{ .line = 5, .col = 1 }, .{ .line = 5, .col = 2 }, "w1-a");
    try session.workers[0].report(&session, file_b, .invalid_utf8, .{ .line = 1, .col = 1 }, .{ .line = 1, .col = 2 }, "w0-b");
    try session.collectDiagnostics();

    try testing.expectEqual(@as(usize, 3), session.diagnostics.items.len);
    try testing.expectEqualStrings("w1-a", session.diagnostics.items[0].message);
    try testing.expectEqualStrings("w0-b", session.diagnostics.items[1].message);
    try testing.expectEqualStrings("w1-b", session.diagnostics.items[2].message);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .tab_in_source,
        .severity = .@"error",
        .span = .{ .file = "a/A.beni", .start = .{ .line = 5, .col = 1 }, .end = .{ .line = 5, .col = 2 } },
        .title = "TAB CHARACTER",
        .message = "w1-a",
    }, session.diagnostics.items[0]);
}
