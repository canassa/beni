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
const Graph = @import("resolve/Graph.zig");
const Interface = @import("resolve/Interface.zig");
const Resolve = @import("resolve/Resolve.zig");
const ResolveDiagnostics = @import("resolve/Diagnostics.zig");
const Check = @import("check/Check.zig");
const core_package = @import("core_package");

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
/// The module graph of the last run (checker.md §4). Empty unless the
/// phases included the serial resolve step.
graph: Graph = .empty,
/// The interfaces and cross-module diagnostics of the last run.
resolution: Resolve = .empty,
/// The type-check of the last run (checker.md §6). Empty unless the phases
/// included the check step.
checked: Check = .empty,
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
    /// `--core`: the files named on the command line are core sources, so
    /// `foreign` and `equatable` are legal in them (language.md §5.4,
    /// checker.md Appendix A). A file whose PACKAGE is `core` — the
    /// embedded copy, or anything under `--core-root` — gets the same
    /// permission without the flag; this is for the corpus fixtures and
    /// for one-off files that are not in a core tree.
    core: bool = false,
    /// `--core-root=<dir>` (checker.md §2): read the core package from this
    /// directory instead of the copy embedded in the binary.
    core_root: ?[]const u8 = null,
    /// Whether this run needs the core package at all. `check` and
    /// `dump --stage=interface` resolve against it and set this; `fmt` and
    /// the per-file dumps do not, and adding ~2,800 lines of parsing to
    /// every one of them would be pure cost (see `enumerateCore`).
    core_package: bool = false,
    /// Keep every module's `TypeStore` alive after the check, so
    /// `dump --stage=types` can print local bindings' types (checker.md §2).
    /// Off by default: a store is released the moment its interface has
    /// been extracted (§5), and keeping them costs memory proportional to
    /// the whole project rather than to one module.
    keep_type_stores: bool = false,
    /// Work one `case` may spend on pattern usefulness (checker.md §6.6)
    /// before it is abandoned and reports nothing. A knob for the tests
    /// that prove the bound, not a flag.
    pattern_budget: u32 = default_pattern_budget,
    /// Capacity of each worker's profile buffer. Allocated once at session
    /// start and never grown, so a worker records without allocating; a full
    /// buffer counts the drop and the trace says `dropped_events`.
    ///
    /// M2c's per-module events (checker.md §9: `resolve`, `check`,
    /// `constrain`, `solve` and `exhaustive` for every module) put five rows
    /// per module on top of four per file, so the old 4096 truncated the
    /// trace of the 100k-line corpus at `--jobs=1` — the run whose trace one
    /// most wants to read. 64 Ki events is 2 MiB per thread, paid only when
    /// `--self-profile` is on.
    profile_events_per_thread: usize = 64 * 1024,
};

/// The pattern-usefulness budget of checker.md §6.6, re-exported so the
/// tests can name it without reaching into the checker.
pub const default_pattern_budget = Check.Exhaustive.default_budget;

pub const IoFailure = struct {
    path: []const u8,
    err: anyerror,
};

/// The per-file work, plus whatever must happen once, serially, after
/// every file has been through it. The driver does not change between
/// them: `after` runs on the calling thread with the interners merged and
/// every file's artifacts in place, which is exactly the firewall of
/// `fast-compiler.md` §6 — nothing above it knows another module exists,
/// nothing below it is per file.
pub const Phases = struct {
    per_file: *const fn (session: *Session, worker: *Worker, file: SourceStore.Index) anyerror!void,
    after: ?*const fn (session: *Session) RunError!void = null,
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

/// M2a: `lower_phases` per file, then — serially, once — the module graph
/// and cross-module name resolution (checker.md §4). What `check` and
/// `dump --stage=interface` run.
pub const resolve_phases: Phases = .{ .per_file = lowerPhase, .after = resolveSerial };

/// M2b: `resolve_phases`, then type-check every module in the graph's
/// topological order (checker.md §6). What `check` and the two typed dumps
/// run. Serial for now; §4.4 allows DAG parallelism and the data is laid
/// out for it.
pub const check_phases: Phases = .{ .per_file = lowerPhase, .after = checkSerial };

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
    session.checked.deinit(gpa);
    session.resolution.deinit(gpa);
    session.graph.deinit(gpa);
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
    try session.enumerateCore();
    for (paths) |p| {
        session.store.addPath(gpa, session.io, p, session.options.root, .app) catch |err| switch (err) {
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
    //
    // Every worker is spawned with an EXPLICIT stack, the calling thread's
    // included, and that is not a detail: the parser bounds a tree at
    // `Parse.max_depth` levels and every consumer of that tree — the AST
    // dump, the formatter, lowering — walks it by recursion, so a
    // legitimately deep tree needs `check_stack_size` frames of room.
    // `std.Thread.SpawnConfig`'s default does not have it, and neither does
    // the 8 MiB a main thread gets, which is why `--jobs=1` no longer runs
    // the phases inline: a crash that depends on the worker count is worse
    // than the thread it costs to avoid, and one spawn is microseconds
    // against a 2 ms process start.
    {
        var threads: std.ArrayList(std.Thread) = .empty;
        defer threads.deinit(gpa);
        try threads.ensureTotalCapacity(gpa, session.workers.len);
        defer for (threads.items) |t| t.join();
        for (session.workers) |*worker| {
            threads.appendAssumeCapacity(try std.Thread.spawn(
                .{ .stack_size = check_stack_size },
                workerMain,
                .{ session, worker, phases },
            ));
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

    // 3b. Whatever the command needs done once, with every file lowered
    //     and the symbols global: the module graph and resolution.
    if (phases.after) |after| try after(session);

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

/// Queue the core package's files (checker.md §3, §4.1) when the run needs
/// them. The embedded copy costs no I/O — the bytes are in the binary's
/// rodata and `SourceStore.read` hands them straight to the tokenizer —
/// but it still costs a lex, a parse and a lower per module, which is why
/// it is opt-in per command rather than unconditional.
fn enumerateCore(session: *Session) RunError!void {
    if (!session.options.core_package) return;
    const gpa = session.gpa;
    if (session.options.core_root) |dir| {
        session.store.addPath(gpa, session.io, dir, dir, .core) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                session.io_failure = .{ .path = dir, .err = err };
                return error.InputPath;
            },
        };
        return;
    }
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    for (core_package.files) |f| {
        const p = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ core_package.dir, f.rel }) catch return error.OutOfMemory;
        try session.store.addEmbedded(gpa, p, core_package.dir.len + 1, .core, f.source);
    }
}

/// Whether `file` may write `foreign` and `equatable` (language.md §5.4,
/// checker.md Appendix A): it is in the core package, or the whole run was
/// told its inputs are core sources.
pub fn fileIsCore(session: *const Session, file: SourceStore.Index) bool {
    return session.options.core or session.store.package(file) == .core;
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
            diagnostic.position(line_starts, item.start),
            diagnostic.position(line_starts, item.end),
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
            diagnostic.position(line_starts, item.start),
            diagnostic.position(line_starts, item.end),
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
        .core = session.fileIsCore(file),
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
            diagnostic.position(line_starts, item.start),
            diagnostic.position(line_starts, item.end),
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

/// The serial half of `resolve_phases` (checker.md §4.2–§4.5): build the
/// module graph from every file's import table, then resolve every
/// reference against the interfaces in topological order.
///
/// It runs on the calling thread, after the join, with the interners
/// merged — the graph interns module names into the global pool and the
/// Birs' symbols are already global, so neither step can be done earlier.
/// Worker 0's arena is the scratch for both, because worker 0 is idle here
/// and its arena is already warm; it is reset on the way out.
fn resolveSerial(session: *Session) RunError!void {
    const gpa = session.gpa;
    const worker = &session.workers[0];
    defer worker.arena.reset(.retain_capacity);

    const graph_token = session.profile.begin();
    session.graph.deinit(gpa);
    session.graph = try Graph.build(gpa, worker.arena.allocator(), &session.store, &session.artifacts, &session.interner);
    session.profile.end(0, graph_token, .graph, Profile.Event.no_file, 0);
    session.profile.addCounter(.modules, session.graph.count());
    session.profile.addCounter(.edges, session.graph.edgeCount());
    try session.reportGraphDiagnostics();

    session.resolution.deinit(gpa);
    // One `resolve` event per module (checker.md §9), emitted inside, not
    // one for the whole step: the per-module rows are what M4's
    // incrementality tests read.
    session.resolution = try Resolve.run(gpa, worker.arena.allocator(), &session.graph, &session.artifacts, &session.interner, &session.profile);
    session.profile.addCounter(.interfaces, session.resolution.interfaces.len);
    try session.reportResolveDiagnostics();
}

/// The type checker (checker.md §6), after the graph and resolution: one
/// `TypeStore` per module, in topological order, each reading only its own
/// Bir and the interfaces of its imports.
fn checkSerial(session: *Session) RunError!void {
    try resolveSerial(session);
    const gpa = session.gpa;
    const worker = &session.workers[0];
    defer worker.arena.reset(.retain_capacity);

    // A module an earlier phase already reported on is checked silently:
    // see `Check.Options.quiet` for why, and note this has to be computed
    // BEFORE the check runs, while the pending lists hold only the earlier
    // phases' items.
    const quiet = try gpa.alloc(bool, session.graph.count());
    defer gpa.free(quiet);
    @memset(quiet, false);
    for (session.workers) |*w| {
        for (w.diagnostics.items) |pending| {
            for (0..session.graph.count()) |i| {
                const m: Graph.Index = @enumFromInt(i);
                if (session.graph.moduleFile(m) == pending.file) quiet[i] = true;
            }
        }
    }

    session.checked.deinit(gpa);
    // `check` is one event per MODULE (checker.md §9), emitted by the
    // checker itself on the worker that took the module, with `constrain`,
    // `solve` and `exhaustive` nested inside each.
    session.checked = try runCheckOnBigStack(session, quiet);
    session.profile.addCounter(.unifications, session.checked.counters.unifications);
    session.profile.addCounter(.generalisations, session.checked.counters.generalisations);
    session.profile.addCounter(.instantiations, session.checked.counters.instantiations);
    session.profile.addCounter(.obligations, session.checked.counters.obligations);
    try session.reportCheckDiagnostics();
}

/// Constraint generation and solving walk an expression TREE, and the
/// parser accepts 4096 levels of nesting (language.md §10) — a chain of
/// 8000 `+` is one of the pathological inputs `bench/pathological/` keeps
/// on purpose. The parser survives those because it builds an operator
/// chain iteratively; the checker cannot, because a constraint for `a + b`
/// is a constraint about `a`. 4096 frames do not fit in the 8 MiB the main
/// thread gets, so the check runs on a thread with room for them.
///
/// The size is MEASURED, not guessed, against `bench/pathological`'s three
/// 8000-link spines (`tests/blackbox/abuse_test.zig` runs the same shapes):
/// 512 KiB and 16 MiB both overflow, 32 MiB does not. 64 MiB is that with a
/// factor of two of headroom, because the frames grow whenever the solver
/// gains a field and the failure mode is a segfault rather than a
/// diagnostic.
///
/// M2c's DAG-parallel checking (checker.md §4.4) needs the same room on
/// every worker, which is why the number lives in `Check` and is stated at
/// every spawn: `std.Thread.SpawnConfig`'s default is nowhere near it.
pub const check_stack_size = Check.stack_size;

fn runCheckOnBigStack(session: *Session, quiet: []const bool) RunError!Check {
    const Runner = struct {
        session: *Session,
        quiet: []const bool,
        result: Check.Error!Check = undefined,

        fn go(r: *@This()) void {
            r.result = Check.run(
                r.session.gpa,
                r.session.io,
                &r.session.workers[0].arena,
                &r.session.graph,
                &r.session.artifacts,
                r.session.resolution.interfaces,
                &r.session.interner,
                .{
                    .profile = &r.session.profile,
                    .keep_stores = r.session.options.keep_type_stores,
                    .quiet = r.quiet,
                    .jobs = @intCast(r.session.workers.len),
                    .pattern_budget = r.session.options.pattern_budget,
                },
            );
        }
    };
    var runner: Runner = .{ .session = session, .quiet = quiet };
    const thread = try std.Thread.spawn(.{ .stack_size = check_stack_size }, Runner.go, .{&runner});
    thread.join();
    return runner.result;
}

/// Turn each checker item into a reported diagnostic. The message was
/// rendered when the item was made — the store it names variables from is
/// gone by now — so this only has to find the span, which is the token the
/// item's Bir instruction came from (checker.md §6.1).
fn reportCheckDiagnostics(session: *Session) RunError!void {
    for (session.checked.diagnostics) |item| {
        const file = session.graph.moduleFile(item.module);
        const bir = session.artifacts.bir(file);
        const token = if (item.region.int() < bir.insts.len)
            bir.insts.items(.main_token)[item.region.int()]
        else
            0;
        const start, const end = session.tokenSpan(file, token);
        try session.workers[0].report(session, file, item.code, start, end, item.message);
    }
}

/// The span of `token` in `file`, from the token list the parser produced.
/// This is what `Bir.Inst.main_token` buys: a resolution diagnostic points
/// at an instruction, and an instruction points at the exact bytes.
fn tokenSpan(session: *const Session, file: SourceStore.Index, token: u32) struct { diagnostic.Position, diagnostic.Position } {
    const line_starts = session.store.lineStarts(file);
    if (line_starts.len == 0) return .{ .{ .line = 1, .col = 1 }, .{ .line = 1, .col = 1 } };
    const tokens = session.artifacts.tokens(file);
    if (token >= tokens.len) return .{ .{ .line = 1, .col = 1 }, .{ .line = 1, .col = 1 } };
    const tags = tokens.items(.tag);
    const starts = tokens.items(.start);
    const source = session.store.bytes(file);
    const start = starts[token];
    const end = Tokenizer.tokenEnd(source, tags[token], start);
    return .{ diagnostic.position(line_starts, start), diagnostic.position(line_starts, end) };
}

fn reportGraphDiagnostics(session: *Session) RunError!void {
    const gpa = session.gpa;
    var message: Io.Writer.Allocating = .init(gpa);
    defer message.deinit();
    var cycle_names: std.ArrayList([]const u8) = .empty;
    defer cycle_names.deinit(gpa);
    for (session.graph.diagnostics) |item| {
        message.clearRetainingCapacity();
        cycle_names.clearRetainingCapacity();
        var cx: ResolveDiagnostics.Context = .{};
        switch (item.code) {
            .import_cycle => {
                for (session.graph.cycle_members[item.cycle_start..item.cycle_end]) |m| {
                    try cycle_names.append(gpa, session.interner.slice(session.graph.moduleName(m)));
                }
                cx.cycle = cycle_names.items;
            },
            .duplicate_module => {
                cx.name = session.store.moduleName(item.file);
                cx.other_path = session.store.path(session.graph.moduleFile(@enumFromInt(item.cycle_start)));
            },
            else => cx.name = session.moduleNameOfImport(item.file, item.token),
        }
        try ResolveDiagnostics.message(item.code, cx, &message.writer);
        const start, const end = session.tokenSpan(item.file, item.token);
        try session.workers[0].report(session, item.file, item.code, start, end, message.written());
    }
}

/// The module path an import token spells, for `unknown_module`. Taken
/// from the source rather than from a symbol so a path the interner never
/// saw still prints.
fn moduleNameOfImport(session: *const Session, file: SourceStore.Index, token: u32) []const u8 {
    const tokens = session.artifacts.tokens(file);
    if (token >= tokens.len) return "";
    return Tokenizer.slice(session.store.bytes(file), tokens.items(.tag)[token], tokens.items(.start)[token]);
}

fn reportResolveDiagnostics(session: *Session) RunError!void {
    const gpa = session.gpa;
    var message: Io.Writer.Allocating = .init(gpa);
    defer message.deinit();
    for (session.resolution.diagnostics) |item| {
        message.clearRetainingCapacity();
        const file = session.graph.moduleFile(item.module);
        const cx: ResolveDiagnostics.Context = .{
            .name = session.symbolText(item.name),
            .module = session.symbolText(item.module_name),
            .owner = session.symbolText(item.owner),
            .expected = item.expected,
            .found = item.found,
        };
        try ResolveDiagnostics.message(item.code, cx, &message.writer);
        const start, const end = session.tokenSpan(file, item.token);
        try session.workers[0].report(session, file, item.code, start, end, message.written());
    }
}

fn symbolText(session: *const Session, s: InternPool.Symbol.Optional) []const u8 {
    return session.interner.slice(s.unwrap() orelse return "");
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
    try session.store.addPending(testing.allocator, "a/B.beni", 2, .app);
    try session.store.addPending(testing.allocator, "a/A.beni", 2, .app);
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
