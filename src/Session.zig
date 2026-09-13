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
//!      so the merge ORDER does not depend on scheduling. Note what this
//!      does and does not buy: a worker's local pool holds the identifiers
//!      of the files it happened to take, so the global index a given
//!      identifier ends up with still varies with `--jobs`. Nothing
//!      observable depends on it — no `Symbol` is ever printed; the dumps
//!      and the diagnostics print text — and the moment one reaches an
//!      artifact that is compared or cached, this becomes a bug and the
//!      ids have to be assigned by a pass keyed on file index instead.
//!   4. Diagnostics are gathered in file index order (each file's are
//!      produced serially by one worker, in source order) and then stably
//!      sorted by the schema's comparator.
//! Two runs with different `--jobs` therefore produce identical bytes on
//! every stream; the black-box determinism scenario checks exactly that.
//!
//! The per-file phase is a function pointer (`Phases`): M1a installed
//! read → tokenize (`lex_phases`), M1b added parse (`parse_phases`), M1c
//! lower (`lower_phases`), M1d format (`format_phases`), none of them
//! touching the driver. What a phase produces for a file goes into
//! `artifacts`, keyed by file index and owned by the session (see
//! `Artifacts.zig` for why they are not arena memory). Anything a command
//! must do in a fixed order — `fmt`'s compare/write/print — is done AFTER
//! the join, walking files by index, so the per-file work parallelises and
//! the product still does not depend on `--jobs`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const diagnostic = @import("diagnostic");
const Arena = @import("Arena.zig");
const Artifacts = @import("Artifacts.zig");
const InternPool = @import("InternPool.zig");
const Profile = @import("Profile.zig");
const SourceStore = @import("SourceStore.zig");
const Tokenizer = @import("lex/Tokenizer.zig");
const LexDiagnostics = @import("lex/Diagnostics.zig");
const Parse = @import("parse/Parse.zig");
const ParseDiagnostics = @import("parse/Diagnostics.zig");
const Lower = @import("bir/Lower.zig");
const Format = @import("fmt/Format.zig");
const LowerDiagnostics = @import("bir/Diagnostics.zig");
const render_text = @import("render/text.zig");
const render_json = @import("render/json.zig");

const Session = @This();

gpa: Allocator,
io: Io,
options: Options,
store: SourceStore = .{},
/// Per-file phase outputs, sized by `run` before the workers start.
artifacts: Artifacts = .{},
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
    /// legal (language.md §5.4). Consumed by lowering.
    core: bool = false,
    /// Capacity of each worker's profile buffer.
    profile_events_per_thread: usize = 4096,
};

pub const IoFailure = struct {
    path: []const u8,
    err: anyerror,
};

/// The per-file work; the driver does not change between them.
pub const Phases = struct {
    per_file: *const fn (session: *Session, worker: *Worker, file: SourceStore.Index) anyerror!void,
};

/// M1a: read the bytes, tokenize, install the lexical artifacts, report
/// the lexical diagnostics.
pub const lex_phases: Phases = .{ .per_file = lexPhase };

/// M1b: `lex_phases`, then parse into the file's `ast` column and report the
/// syntax diagnostics. What `dump --stage=tokens|ast` runs: those stages
/// show a file the lowering rules have not judged.
pub const parse_phases: Phases = .{ .per_file = parsePhase };

/// M1c: `parse_phases`, then lower into the file's `bir` column and report
/// the lowering diagnostics. What `check` and `dump --stage=bir` run.
pub const lower_phases: Phases = .{ .per_file = lowerPhase };

/// M1d: `parse_phases`, then format into the file's `formatted` column.
/// What `fmt` runs. Formatting is per-file work with no cross-file
/// knowledge, so it belongs on a worker like lexing and parsing; the
/// command that follows only compares, writes and prints, walking files in
/// index order. Output order and bytes are therefore a function of the
/// sorted path list alone and not of `--jobs`.
pub const format_phases: Phases = .{ .per_file = formatPhase };

pub const Worker = struct {
    index: u32,
    arena: Arena,
    /// Made by `InternPool.Local.init`, so the well-known prefix is in place
    /// and lowering recognises prelude names by index.
    interner: InternPool.Local,
    /// This worker's diagnostics, each tagged with its file. Appended in
    /// source order per file; files in the order the worker took them.
    diagnostics: std.ArrayList(Pending) = .empty,
    /// Summed into the profile after the join.
    counters: [Profile.Counter.count]u64 = @splat(0),
    /// The LOWEST-numbered file this worker could not process, and why.
    /// Lowest, not first: a worker takes files in the order the shared
    /// counter hands them out, so "first" is a race and "lowest" is not.
    failure: ?Failure = null,

    pub const Failure = struct { file: SourceStore.Index, err: anyerror };

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
    errdefer gpa.free(session.workers);
    var made: usize = 0;
    errdefer for (session.workers[0..made]) |*worker| worker.interner.deinit(gpa);
    for (session.workers, 0..) |*worker, i| {
        worker.* = .{ .index = @intCast(i), .arena = .init(std.heap.page_allocator), .interner = try InternPool.Local.init(gpa) };
        made += 1;
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
    session.artifacts.deinit(gpa);
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
    try session.artifacts.resize(gpa, session.store.count());
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
    // Which unreadable file gets named must not depend on scheduling
    // (fast-compiler.md §10): the workers each keep their own
    // lowest-numbered failure and every one of them finishes its queue, so
    // the lowest across all of them is the lowest in the project, whatever
    // `--jobs` was. Reporting the first FAILING WORKER in worker-index
    // order — which is what this did — named whichever file the
    // `next_file` race happened to hand to the lowest-numbered worker, and
    // alternated between runs at the same `--jobs`.
    var failure: ?Worker.Failure = null;
    for (session.workers) |*worker| {
        const f = worker.failure orelse continue;
        if (failure == null or f.file.int() < failure.?.file.int()) failure = f;
    }
    if (failure) |f| {
        session.io_failure = .{ .path = session.store.path(f.file), .err = f.err };
        return error.InputPath;
    }

    // 3. Merge interners in worker index order, then rewrite every file's
    //    interned payloads and Bir symbols through its worker's remap table.
    const merge_token = session.profile.begin();
    const remaps = try gpa.alloc([]InternPool.Symbol, session.workers.len);
    defer gpa.free(remaps);
    var merged: usize = 0;
    defer for (remaps[0..merged]) |remap| gpa.free(remap);
    for (session.workers, remaps) |*worker, *remap| {
        remap.* = try session.interner.merge(gpa, &worker.interner);
        merged += 1;
    }
    for (0..session.store.count()) |i| {
        const file: SourceStore.Index = @enumFromInt(i);
        session.artifacts.applyRemap(file, remaps[session.artifacts.worker(file)]);
    }
    session.profile.end(0, merge_token, .merge_interners, Profile.Event.no_file, 0);

    // 4. Collect (file order, then stable sort), count, render.
    try session.collectDiagnostics();
    var summary: Summary = .{ .files = session.store.count(), .errors = 0, .warnings = 0 };
    for (session.diagnostics.items) |d| switch (d.severity) {
        .@"error" => summary.errors += 1,
        .warning => summary.warnings += 1,
    };

    for (session.workers) |*worker| {
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
            // Keep the lowest-numbered failure and KEEP GOING. Returning
            // here abandoned the rest of this worker's queue, which is how
            // a second unreadable file could be found by one run and not
            // the next; see the pick in `run`.
            if (worker.failure == null or i < worker.failure.?.file.int()) {
                worker.failure = .{ .file = file, .err = err };
            }
        };
        // Each file's artifacts are moved to session storage inside the
        // phase, so the arena is free to be reused for the next one.
        worker.arena.reset(.retain_capacity);
    }
}

/// The M1a per-file phase: read the bytes into the store, tokenize them into
/// session-owned artifacts (tokens, comments; the line table goes to the
/// store), and turn the lexical diagnostics into reported ones with
/// positions from that table. Two profile events, `read` and `lex`, so the
/// I/O and the scanning are visible separately in a trace.
fn lexPhase(session: *Session, worker: *Worker, file: SourceStore.Index) anyerror!void {
    const gpa = session.gpa;
    const read_token = session.profile.begin();
    try session.store.read(gpa, session.io, file);
    const text = session.store.bytes(file);
    session.profile.end(worker.index, read_token, .read, file.int(), @intCast(text.len));
    worker.addCounter(.bytes, text.len);

    const lex_token = session.profile.begin();
    var out: Tokenizer.Output = .empty;
    errdefer out.deinit(gpa);
    try Tokenizer.tokenize(gpa, text, &worker.interner, &out);
    session.profile.end(worker.index, lex_token, .lex, file.int(), @intCast(text.len));
    worker.addCounter(.tokens, out.tokens.len);

    const line_starts = try out.line_starts.toOwnedSlice(gpa);
    session.store.setLineStarts(gpa, file, line_starts);

    var message: Io.Writer.Allocating = .init(gpa);
    defer message.deinit();
    for (out.diagnostics.items()) |item| {
        message.clearRetainingCapacity();
        try LexDiagnostics.message(item, text, &message.writer);
        try worker.report(
            session,
            file,
            item.code,
            LexDiagnostics.position(line_starts, item.start),
            LexDiagnostics.position(line_starts, item.end),
            message.written(),
        );
    }

    const comments = try out.comments.toOwnedSlice(gpa);
    errdefer gpa.free(comments);
    const lex_diagnostics = try out.diagnostics.toOwnedSlice(gpa);
    session.artifacts.set(gpa, file, .{
        .tokens = out.tokens,
        .comments = comments,
        .lex_diagnostics = lex_diagnostics,
        .ast = .empty,
        .bir = .empty,
        .formatted = null,
        .worker = worker.index,
    });
}

/// The M1b per-file phase: everything `lexPhase` does, then the parser over
/// the installed tokens. Scratch comes from the worker's arena (reset by
/// the driver after the file); the tree goes to session storage next to
/// the tokens it indexes.
fn parsePhase(session: *Session, worker: *Worker, file: SourceStore.Index) anyerror!void {
    try lexPhase(session, worker, file);
    const gpa = session.gpa;
    const text = session.store.bytes(file);
    const line_starts = session.store.lineStarts(file);
    const tokens = session.artifacts.tokens(file);
    const comments = session.artifacts.comments(file);
    const lex_diagnostics = session.artifacts.lexDiagnostics(file);

    const parse_token = session.profile.begin();
    var tree = try Parse.parse(gpa, worker.arena.allocator(), text, tokens.slice(), comments, line_starts, lex_diagnostics);
    errdefer tree.deinit(gpa);
    session.profile.end(worker.index, parse_token, .parse, file.int(), @intCast(text.len));
    worker.addCounter(.nodes, tree.nodes.len);

    var message: Io.Writer.Allocating = .init(gpa);
    defer message.deinit();
    for (tree.errors) |item| {
        message.clearRetainingCapacity();
        try ParseDiagnostics.message(item, text, line_starts, &message.writer);
        try worker.report(
            session,
            file,
            item.code,
            LexDiagnostics.position(line_starts, item.start),
            LexDiagnostics.position(line_starts, item.end),
            message.written(),
        );
    }

    session.artifacts.files.items(.ast)[file.int()] = tree;
}

/// The M1c per-file phase: everything `parsePhase` does, then lowering
/// over the installed tree. Scratch from the worker's arena; the Bir goes
/// to session storage next to the tree, its symbols local to the worker
/// until the merge.
fn lowerPhase(session: *Session, worker: *Worker, file: SourceStore.Index) anyerror!void {
    try parsePhase(session, worker, file);
    const gpa = session.gpa;
    const text = session.store.bytes(file);
    const line_starts = session.store.lineStarts(file);
    const tokens = session.artifacts.tokens(file);
    const tree = session.artifacts.ast(file);

    const lower_token = session.profile.begin();
    var bir = try Lower.lower(gpa, worker.arena.allocator(), text, tokens.slice(), tree, &worker.interner, .{
        .core = session.options.core,
        .module_name = session.store.moduleName(file),
    });
    errdefer bir.deinit(gpa);
    session.profile.end(worker.index, lower_token, .lower, file.int(), @intCast(text.len));
    worker.addCounter(.insts, bir.insts.len);

    var message: Io.Writer.Allocating = .init(gpa);
    defer message.deinit();
    for (bir.diagnostics) |item| {
        message.clearRetainingCapacity();
        try LowerDiagnostics.message(item, text, line_starts, &message.writer);
        try worker.report(
            session,
            file,
            item.code,
            LexDiagnostics.position(line_starts, item.start),
            LexDiagnostics.position(line_starts, item.end),
            message.written(),
        );
    }

    session.artifacts.files.items(.bir)[file.int()] = bir;
}

/// The M1d per-file phase: everything `parsePhase` does, then the formatter
/// over the installed tree, into a session-owned buffer next to it.
///
/// A file with any diagnostic has no canonical form and is never written,
/// printed or listed (`fmt/Command.zig`), so it is not formatted at all —
/// and the worker can decide that by itself, which is what keeps this phase
/// free of cross-file knowledge. Every diagnostic a `fmt` run can produce
/// for a file is already known here: the module-path check is a function of
/// the path alone (`run` reports it serially before any worker starts), and
/// the lexer's and the parser's have both finished for this file. Skipped
/// files leave `formatted` null, which is what the command tests.
fn formatPhase(session: *Session, worker: *Worker, file: SourceStore.Index) anyerror!void {
    try parsePhase(session, worker, file);
    if (!session.store.modulePathValid(file)) return;
    if (session.artifacts.lexDiagnostics(file).len != 0) return;
    const tree = session.artifacts.ast(file);
    if (tree.errors.len != 0) return;

    const gpa = session.gpa;
    const text = session.store.bytes(file);
    const format_token = session.profile.begin();
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    Format.format(
        worker.arena.allocator(),
        tree,
        session.artifacts.tokens(file),
        session.artifacts.comments(file),
        text,
        session.store.lineStarts(file),
        &out.writer,
    ) catch |err| switch (err) {
        // Guarded above; belt and braces, and the file is left alone.
        error.SyntaxErrors => {
            out.deinit();
            return;
        },
        // An allocating writer fails for one reason only.
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    session.profile.end(worker.index, format_token, .format, file.int(), @intCast(text.len));
    worker.addCounter(.formatted_bytes, out.written().len);

    var list = out.toArrayList();
    errdefer list.deinit(gpa);
    session.artifacts.setFormatted(gpa, file, try list.toOwnedSlice(gpa));
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
    for (session.workers) |*w| total += w.diagnostics.items.len;
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
        for (session.workers, cursors) |*w, c| {
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
