//! The one object everything hangs off (docs/design/frontend.md §4,
//! fast-compiler.md §4): gpa, options, the `SourceStore`, the global
//! `InternPool`, the `Profile`, and the workers. There is no global mutable
//! state anywhere in beni; a daemon keeps one `Session` alive across
//! edits, which is why every structure here is owned explicitly and reset
//! rather than rebuilt.
//!
//! `run` is deterministic by construction, not by testing:
//!   1. Files are enumerated, sorted and numbered serially before any thread
//!      starts; the file index is the only id anything is keyed by.
//!   2. Workers pull file indices from one atomic counter. Which worker takes
//!      which file is unobservable: every per-file result lands in a column
//!      of that file's index, and every per-worker tally is a commutative sum.
//!   3. Interners are merged in FILE index order (`mergeInterners`): each
//!      file's tokens, then its Bir's symbols, interned on first sight, and
//!      what no file references after them by text. So the global index an
//!      identifier gets is a function of the input, never of which worker
//!      took which file or of `--jobs` (worker index order would let any
//!      choice made by id vary between runs). An id
//!      still moves with every edit to an earlier file, so nothing a user
//!      sees may be chosen by one.
//!   4. Diagnostics are gathered in file index order (each file's are
//!      produced serially by one worker, in source order) and then stably
//!      sorted by the schema's comparator.
//! Two runs with different `--jobs` therefore produce identical bytes on
//! every stream; the black-box determinism scenario checks exactly that.
//!
//! The per-file phase is a function pointer (`Phases`): read → tokenize
//! (`lex_phases`), then parse (`parse_phases`), lower (`lower_phases`) or
//! format (`format_phases`), none of them touching the driver. What a phase produces for a file goes into
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
const Token = @import("lex/Token.zig");
const LexDiagnostics = @import("lex/Diagnostics.zig");
const Parse = @import("parse/Parse.zig");
const ParseDiagnostics = @import("parse/Diagnostics.zig");
const Bir = @import("bir/Bir.zig");
const Lower = @import("bir/Lower.zig");
const Format = @import("fmt/Format.zig");
const LowerDiagnostics = @import("bir/Diagnostics.zig");
const render_text = @import("render/text.zig");
const render_json = @import("render/json.zig");
const wrap = @import("render/wrap.zig");
const Graph = @import("resolve/Graph.zig");
const Interface = @import("resolve/Interface.zig");
const Resolve = @import("resolve/Resolve.zig");
const ResolveDiagnostics = @import("resolve/Diagnostics.zig");
const Check = @import("check/Check.zig");
const TypeStore = @import("check/TypeStore.zig");
const Key = @import("cache/Key.zig");
const FileKey = @import("cache/FileKey.zig");
const CacheDir = @import("cache/Dir.zig");
const Digest = @import("cache/Digest.zig");
const entry_bytes = @import("cache/entry_bytes.zig");
const CacheEntry = @import("cache/Entry.zig");
const dispatch_bytes = @import("cache/dispatch_bytes.zig");
const schema_plan_bytes = @import("cache/schema_plan_bytes.zig");
const iface_bytes = @import("resolve/iface_bytes.zig");
const build_id = @import("build_id.zig");
const core_package = @import("core_package");
const platform_packages = @import("platform_packages");
const platform_chain = @import("platform.zig");
const Manifest = @import("js/Manifest.zig");
const artifact_bytes = @import("frontend/artifact_bytes.zig");

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
/// The app package's manifest said `"platform": true`, so the app's own
/// modules may write `foreign` (boundary.md §2).
app_is_platform: bool = false,
/// Per file, the chain index of a platform file's package
/// (`platform.Chain`); 0 for every other file. Filled after enumeration.
/// Owned.
file_layers: []u8 = &.{},
/// The interfaces and cross-module diagnostics of the last run.
resolution: Resolve = .empty,
/// The type-check of the last run (checker.md §6). Empty unless the phases
/// included the check step.
checked: Check = .empty,
/// One persistent-cache key per module (`fast-compiler.md` §8), computed
/// serially between resolution and the check. Empty unless the phases
/// included the check step.
///
/// Filled on every checking run, cache directory or not: it is one code path
/// rather than two, and "was a key computed?" is exactly the kind of
/// condition a cache bug hides behind. What it costs is the `cache_key`
/// profile row.
keys: Key.Keys = .empty,
/// One FRONT-END key per FILE (`cache/FileKey.zig`), in file index order,
/// computed on the worker that took the file. `FileKey.none` for a file whose
/// key this run did not need.
///
/// Unlike `keys`, which is filled on every checking run for one-code-path's
/// sake, this is filled only when something asks for it: `--cache-dir`,
/// `--roundtrip-frontend` or `--frontend-keys` (`wantsFileKeys`). The module
/// key pass is serial and its cost is one profile row; the file key is paid on
/// the per-file phase by every command that lowers, `dump --stage=bir`
/// included, and 0.6 ms of source hashing that nothing reads is a cost a dump
/// should not carry.
file_keys: []FileKey.FileKey = &.{},
/// One INTERFACE HASH and one DEPENDENCY DIGEST per module, in module index
/// order (`checker.md` §7, *The dependency digest*). Empty unless the phases
/// included the check step.
///
/// The pair is what an import contributes to its importer's key,
/// in place of the import's own key: the hash says whether the module's public
/// face moved, and the digest carries what a dependent reads about it that the
/// record does not say — the settled `equatable`/`comparable`/`has_function`
/// bits of a PRIVATE type, an alias expansion no scheme mentions, and the set
/// of derived functions the module emits.
///
/// Filled on every checking run, cache directory or not, for `keys`' reason:
/// one code path, and a cost in the trace rather than in a branch. What it
/// costs is the `dep_digest` profile row.
iface_hashes: [][16]u8 = &.{},
digests: []Digest.Digest = &.{},
/// `--cutoff-compare`'s second key per module, or empty. Printed and never
/// used: the run is driven by `keys`.
compare_keys: []Key.Key = &.{},
/// The compiler build id every file key is computed with, resolved once at
/// `init` rather than per file: `--cache-build-id` substitutes a hash of its
/// bytes, and hashing that string 634 times would be 634 times too many.
build_id_bytes: [16]u8 = @splat(0),
/// Every diagnostic of the last run, in emission order after `run`.
/// Messages are gpa-owned; file paths point into `store`.
diagnostics: std.ArrayList(diagnostic.Diagnostic) = .empty,
/// Set for the duration of ONE `renderLate` call: the files a late
/// diagnostic points at that the store does not hold, or must not be asked
/// for. Borrowed from that call's stack.
late_sources: []const LateSource = &.{},
/// Set when `run` fails on I/O so `main` can say which path.
io_failure: ?IoFailure = null,
/// Shared by all workers: the next file index to claim.
next_file: std.atomic.Value(u32) = .init(0),

pub const DiagnosticsFormat = enum { text, json };

pub const Options = struct {
    /// Worker count, at least 1. `1` runs on the calling thread.
    jobs: u32,
    /// `jobs` is a ceiling rather than a request: it is the machine's CPU
    /// count because the user named none. The run then spawns a per-file
    /// worker per `frontend_bytes_per_worker` of source and a checker per
    /// `Check.tokens_per_checker` tokens still to check, so a small project
    /// pays for no thread it cannot keep busy. An explicit `--jobs` is
    /// honoured as given, up to the files and modules there are, which is
    /// what lets a test cross a real parallel run with a serial one.
    size_by_work: bool = false,
    /// `beni fmt --migrate-cons` (hidden): write each file's `::` chains in
    /// the list syntax and touch nothing else (`Format.migrateCons`).
    migrate_cons: bool = false,
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
    /// `--platform=<name>`: a platform package to enumerate alongside the
    /// app and core (boundary.md §5.3, "a build is per entry point and per
    /// platform"). Either the name of one that ships in the box, or a
    /// directory. Null means no platform, which is what `check` and `fmt`
    /// run with.
    platform: ?[]const u8 = null,
    /// The chain `platform` selects, already read by the command
    /// (`platform.resolveChain`): every package of it is enumerated. Null
    /// exactly when `platform` is.
    chain: ?*const platform_chain.Chain = null,
    /// Where to read `beni.json` from for the APP package. A manifest that
    /// says `"platform": true` makes the app's own modules privileged
    /// (boundary.md §2), which is how someone writes a platform package of
    /// their own. Null means "do not look".
    manifest_root: ?[]const u8 = null,
    /// Keep every module's `TypeStore` alive after the check, so
    /// `dump --stage=types` can print local bindings' types (checker.md §2).
    /// Off by default: a store is released the moment its interface has
    /// been extracted (§5), and keeping them costs memory proportional to
    /// the whole project rather than to one module.
    keep_type_stores: bool = false,
    /// `--roundtrip-interfaces` (`Cli.Common`, `fast-compiler.md` §8):
    /// replace every module's interface record with serialize → bytes →
    /// deserialize of itself the moment its check finishes, before any
    /// dependent reads it.
    roundtrip_interfaces: bool = false,
    /// `--roundtrip-dispatch` (`Cli.Common`, `fast-compiler.md` §8): the
    /// twin of the flag above for the dispatch sidecar, so every emitted
    /// file downstream is built from a table that has been through the
    /// format.
    roundtrip_dispatch: bool = false,
    /// `--roundtrip-frontend` (`Cli.Common`, `fast-compiler.md` §8): every
    /// file's `Bir`, token spans, line-start table and rendered front-end
    /// diagnostics are written to bytes and read back IN PLACE the moment its
    /// per-file phase ends — before `Resolve`, before the graph, before
    /// anything downstream reads them.
    roundtrip_frontend: bool = false,
    /// `--frontend-keys` (`Cli.Cache`, `frontend.md` §1): make `check` print
    /// one `<path> <32 hex digits>` line per file on stdout, sorted by path.
    frontend_keys: bool = false,
    /// `--cutoff-compare` (`Cli.Cache`): compute the CUTOFF key beside the one
    /// the run uses, into `Session.compare_keys`. Hidden, and it changes not
    /// one byte of what the run does — the key it computes is printed and
    /// never used.
    cutoff_compare: bool = false,
    /// Emit the informational `warning`s of static-dispatch-spike.md §10 —
    /// today only `ambiguous_method_receiver` (§10.9). Set by `check` and
    /// `build`, which are the two subcommands the decision names (A.83);
    /// `dump` and `fmt` leave it off so a dump's stderr stays a channel for
    /// problems with the input rather than advice about it.
    ///
    /// It was `--explain` until 2026-09-18. The flag is still parsed and
    /// accepted and now governs nothing (`Cli.Common.explain`, A.83).
    informational: bool = false,
    /// `run` collects, counts and profiles its diagnostics but does NOT
    /// render them; the caller renders once, later, through `renderLate`.
    ///
    /// `beni build` sets it, because its emit phase runs after `run` has
    /// returned and can produce diagnostics of its own — and two renders on
    /// one stream are two JSON arrays, which is not the format (§1.1). Until
    /// A.83 the two waves could not overlap, because a run that reached the
    /// emit phase had produced nothing at all; now it may have produced
    /// `warning`s, so the waves are joined instead of assumed disjoint.
    defer_render: bool = false,
    /// Work one `case` may spend on pattern usefulness (checker.md §6.6)
    /// before the analysis gives up. Giving up is `pattern_budget_exhausted`,
    /// an error, so `--pattern-budget=<n>` is a real flag and not only the
    /// knob the tests that prove the bound turn.
    pattern_budget: u32 = default_pattern_budget,
    /// `--cache-build-id=<s>` (`Cli.Cache`, `fast-compiler.md` §8): these
    /// bytes replace the compiler build id in every cache key, so a test can
    /// prove that a compiler change discards the whole cache without
    /// building a second compiler. Null is the real id.
    cache_build_id: ?[]const u8 = null,
    /// `--cache-dir=<path>`, already opened by the command that owns the
    /// exit-2 message for a directory that could not be created
    /// (`frontend.md` §1). Null is "no cache", which is also what
    /// `--no-cache` produces — the two are one state here on purpose, so
    /// that no code below can behave differently for "off" and "suppressed".
    cache: ?*const CacheDir = null,
    /// Capacity of each worker's profile buffer. Allocated once at session
    /// start and never grown, so a worker records without allocating; a full
    /// buffer counts the drop and the trace says `dropped_events`.
    ///
    /// The per-module events (checker.md §9: `resolve`, `check`,
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
    /// Whether a file's path has to name a MODULE. True everywhere but
    /// `fmt`: formatting "is per file and resolves nothing" (`frontend.md`
    /// §1), so a module name is not a thing it has an opinion about — and a
    /// `beni fmt` that refuses `notes.beni` or `my-scratch.beni` refuses to
    /// do the one job it has for a file it can read, parse and print.
    module_names: bool = true,
};

/// Read the bytes, tokenize, install the lexical artifacts, report
/// the lexical diagnostics.
pub const lex_phases: Phases = .{ .per_file = lexPhase };

/// `lex_phases`, then parse into the file's `ast` column and report the
/// syntax diagnostics. What `dump --stage=tokens|ast` runs: those stages
/// show a file the lowering rules have not judged.
pub const parse_phases: Phases = .{ .per_file = parsePhase };

/// `parse_phases`, then lower into the file's `bir` column and report
/// the lowering diagnostics. What `check` and `dump --stage=bir` run.
pub const lower_phases: Phases = .{ .per_file = lowerPhase };

/// `lower_phases` per file, then — serially, once — the module graph
/// and cross-module name resolution (checker.md §4). What `check` and
/// `dump --stage=interface` run.
pub const resolve_phases: Phases = .{ .per_file = lowerPhase, .after = resolveModules };

/// `resolve_phases`, then type-check every module in the graph's
/// topological order (checker.md §6). What `check` and the two typed dumps
/// run. Serial for now; §4.4 allows DAG parallelism and the data is laid
/// out for it.
pub const check_phases: Phases = .{ .per_file = lowerPhase, .after = checkSerial };

/// `parse_phases`, then format into the file's `formatted` column.
/// What `fmt` runs. Formatting is per-file work with no cross-file
/// knowledge, so it belongs on a worker like lexing and parsing; the
/// command that follows only compares, writes and prints, walking files in
/// index order. Output order and bytes are therefore a function of the
/// sorted path list alone and not of `--jobs`.
pub const format_phases: Phases = .{ .per_file = formatPhase, .module_names = false };

pub const Worker = struct {
    index: u32,
    arena: Arena,
    /// Made by `InternPool.Local.init`, so the well-known prefix is in place
    /// and lowering recognises prelude names by index.
    interner: InternPool.Local,
    /// This worker's diagnostics, each tagged with its file. Appended in
    /// source order per file; files in the order the worker took them.
    diagnostics: std.ArrayList(Pending) = .empty,
    /// The buffer one front-end artifact is read into, REUSED across the
    /// files this worker takes (`plans/m4-2.md` §4): a read into a reused
    /// buffer is 2.23 ms over 633 files where `readFileAlloc` into an arena
    /// is 5.76. It is `gpa`'s and not the arena's because an arena only
    /// grows, and a buffer that is reused must be able to shrink to nothing
    /// between runs — the property a daemon needs.
    artifact_buffer: std.ArrayList(u8) = .empty,
    /// Summed into the profile after the join.
    counters: [Profile.Counter.count]u64 = @splat(0),
    /// The LOWEST-numbered file this worker could not process, and why.
    /// Lowest, not first: a worker takes files in the order the shared
    /// counter hands them out, so "first" is a race and "lowest" is not.
    failure: ?Failure = null,

    pub const Failure = struct { file: SourceStore.Index, err: anyerror };

    pub const Pending = struct { file: SourceStore.Index, diagnostic: diagnostic.Diagnostic };

    /// Record a diagnostic for `file`. `message` is copied into gpa memory
    /// owned by the session, and re-wrapped on the way (`render/wrap.zig`):
    /// every message is a format string wrapped by hand around holes whose
    /// contents are not known until here, so the 80-column rule is enforced
    /// AFTER interpolation or not at all.
    pub fn report(worker: *Worker, session: *Session, file: SourceStore.Index, code: diagnostic.Code, start: diagnostic.Position, end: diagnostic.Position, message: []const u8) Allocator.Error!void {
        return worker.reportAs(session, file, code, .@"error", start, end, message);
    }

    /// As `report`, with an explicit severity. A `warning` does not change
    /// the exit code (`frontend.md` §1), which is what lets
    /// `ambiguous_method_receiver` be emitted by default without ever
    /// turning a passing build into a failing one
    /// (static-dispatch-spike.md §10 preamble, A.83).
    pub fn reportAs(worker: *Worker, session: *Session, file: SourceStore.Index, code: diagnostic.Code, severity: diagnostic.Severity, start: diagnostic.Position, end: diagnostic.Position, message: []const u8) Allocator.Error!void {
        const owned = try wrap.reflow(session.gpa, message);
        errdefer session.gpa.free(owned);
        try worker.diagnostics.append(session.gpa, .{ .file = file, .diagnostic = .{
            .code = code,
            .severity = severity,
            .span = .{ .file = session.store.path(file), .start = start, .end = end },
            .title = diagnostic.title(code),
            .message = owned,
        } });
    }

    /// Append a diagnostic whose prose has ALREADY been through
    /// `render/wrap.zig` — one replayed from a front-end artifact.
    ///
    /// It is `reportAs` minus the reflow, and the difference is the whole
    /// point: a stored message was wrapped when the phase that will not run
    /// rendered it, and wrapping it a second time is not guaranteed to be
    /// the identity. Every message in the stream still passes through
    /// exactly one wrap.
    pub fn replay(worker: *Worker, session: *Session, file: SourceStore.Index, code: diagnostic.Code, severity: diagnostic.Severity, start: diagnostic.Position, end: diagnostic.Position, message: []const u8) Allocator.Error!void {
        const owned = try session.gpa.dupe(u8, message);
        errdefer session.gpa.free(owned);
        try worker.diagnostics.append(session.gpa, .{ .file = file, .diagnostic = .{
            .code = code,
            .severity = severity,
            .span = .{ .file = session.store.path(file), .start = start, .end = end },
            .title = diagnostic.title(code),
            .message = owned,
        } });
    }

    /// Drop every diagnostic this worker appended from `mark` on, freeing
    /// the messages. `mark` is a length taken before the phase reported
    /// anything for the file being replaced.
    fn truncateDiagnostics(worker: *Worker, gpa: Allocator, mark: usize) void {
        for (worker.diagnostics.items[mark..]) |p| gpa.free(p.diagnostic.message);
        worker.diagnostics.shrinkRetainingCapacity(mark);
    }

    fn deinit(worker: *Worker, gpa: Allocator) void {
        for (worker.diagnostics.items) |p| gpa.free(p.diagnostic.message);
        worker.diagnostics.deinit(gpa);
        worker.artifact_buffer.deinit(gpa);
        worker.interner.deinit(gpa);
        worker.arena.deinit();
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
    session.build_id_bytes = compilerBuildId(options.cache_build_id);
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
    for (session.workers) |*worker| worker.deinit(gpa);
    gpa.free(session.workers);
    gpa.free(session.file_keys);
    gpa.free(session.file_layers);
    gpa.free(session.iface_hashes);
    gpa.free(session.digests);
    gpa.free(session.compare_keys);
    session.keys.deinit(gpa);
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
    try session.readAppManifest();
    try session.enumerateCore();
    try session.enumeratePlatform();
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
    try session.assignLayers();
    try session.fitWorkers(session.frontendWorkers());
    try session.artifacts.resize(gpa, session.store.count());
    // Sized before any worker starts, and written only by the worker that
    // took the file — the one-index-one-writer discipline `Artifacts.set`
    // follows, which is what keeps the column independent of `--jobs`.
    gpa.free(session.file_keys);
    session.file_keys = try gpa.alloc(FileKey.FileKey, session.store.count());
    @memset(session.file_keys, FileKey.none);
    session.profile.end(0, enumerate_token, .enumerate, Profile.Event.no_file, 0);

    // Module-path validation is decided by the path alone, so it is
    // reported here, serially, before any worker touches the file — and not
    // at all for the phases that never ask a file its module name.
    if (phases.module_names) {
        for (0..session.store.count()) |i| {
            const file: SourceStore.Index = @enumFromInt(i);
            if (session.store.modulePathValid(file)) continue;
            try session.reportInvalidModulePath(file);
        }
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

    // 3. Merge interners in FILE order (`mergeInterners`), then rewrite
    //    every file's interned payloads and Bir symbols through its
    //    worker's remap table.
    const merge_token = session.profile.begin();
    const remaps = try session.mergeInterners();
    defer {
        for (remaps) |remap| gpa.free(remap);
        gpa.free(remaps);
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
    if (session.diagnostics.items.len != 0 and !session.options.defer_render) {
        try session.render(session.diagnostics.items, stderr);
    }
    session.profile.end(0, render_token, .render, Profile.Event.no_file, 0);

    if (session.options.self_profile) |profile_path| try session.writeProfile(profile_path);
    return summary;
}

/// Source bytes one per-file worker is worth spawning for, when the run
/// sizes its pools by work (`Options.size_by_work`). The front end gets
/// through about 50 KB a millisecond, so this is some 5 ms of lexing,
/// parsing and lowering per thread; a thread costs a spawn, a stack
/// mapping, an interner seeded with the well-known symbols and a pass of
/// the interner merge. The embedded core package is about 100 KB, so core
/// plus a small project runs on one worker.
pub const frontend_bytes_per_worker = 256 * 1024;

/// How many per-file workers the run keeps: never more than one per file,
/// and under `size_by_work` one per `frontend_bytes_per_worker` of source.
/// Embedded files' sizes are known; a file on disk is asked its size, and
/// the walk stops as soon as the sum has reached the ceiling, so a large
/// project stats only as many files as it takes to know it is large.
fn frontendWorkers(session: *Session) u32 {
    const files = session.store.count();
    const ceiling: u32 = @intCast(@min(session.workers.len, @max(files, 1)));
    if (!session.options.size_by_work) return ceiling;
    const enough = @as(u64, ceiling) * frontend_bytes_per_worker;
    var bytes: u64 = 0;
    for (0..files) |i| {
        if (bytes >= enough) break;
        const file: SourceStore.Index = @enumFromInt(i);
        if (session.store.isEmbedded(file)) {
            bytes += session.store.bytes(file).len;
            continue;
        }
        // A file that cannot be asked cannot be read either, and the
        // worker that tries reports it; it adds no work here.
        const stat = Io.Dir.cwd().statFile(session.io, session.store.path(file), .{}) catch continue;
        bytes += stat.size;
    }
    const wanted = @max(1, std.math.divCeil(u64, bytes, frontend_bytes_per_worker) catch unreachable);
    return @intCast(@min(ceiling, wanted));
}

/// Drop the workers beyond `keep`. A worker with no file to claim still
/// costs a thread with a `check_stack_size` stack, an interner seeded with
/// the well-known symbols and a pass of the interner merge. Which worker
/// took which file is unobservable in the output (see the header), so this
/// changes the cost and nothing else.
fn fitWorkers(session: *Session, keep_wanted: u32) Allocator.Error!void {
    const keep = @max(keep_wanted, 1);
    if (keep >= session.workers.len) return;
    const kept = try session.gpa.dupe(Worker, session.workers[0..keep]);
    for (session.workers[keep..]) |*worker| worker.deinit(session.gpa);
    session.gpa.free(session.workers);
    session.workers = kept;
}

/// Queue the core package's files (checker.md §3, §4.1) when the run needs
/// them. The embedded copy costs no I/O — the bytes are in the binary's
/// rodata and `SourceStore.read` hands them straight to the tokenizer —
/// but it still costs a lex, a parse and a lower per module, which is why
/// it is opt-in per command rather than unconditional.
/// The platform package of this build (boundary.md §5.3). Resolved the same
/// way core is — an embedded copy costs no I/O, a directory is walked —
/// and given `Package.platform`, which is what puts it in `Graph.lookup`'s
/// search path and what makes `foreign` legal inside it.
///
/// Every package of the chain is enumerated (`boundary.md` §9.1), each a
/// platform package: `foreign` and vocabulary declarations are legal in all
/// of them, and which of their modules a module may import is the graph's
/// question (`Graph.Platforms`).
fn enumeratePlatform(session: *Session) RunError!void {
    const chain = session.options.chain orelse return;
    const gpa = session.gpa;
    for (chain.layers) |layer| {
        if (layer.embedded) |platform| {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            for (platform.files) |f| {
                const p = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ platform.root, f.rel }) catch return error.OutOfMemory;
                try session.store.addEmbedded(gpa, p, @intCast(platform.root.len + 1), .platform, f.source);
            }
            continue;
        }
        // A directory: `--platform=./my-platform` is how someone uses one
        // they wrote, which is the whole point of making privilege a role
        // rather than an author list (§2). Its manifest has been read, so a
        // failure here is an I/O failure like any input's.
        session.store.addPath(gpa, session.io, layer.root, layer.root, .platform) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                session.io_failure = .{ .path = layer.root, .err = err };
                return error.InputPath;
            },
        };
    }
}

/// `file_layers`, once the store is numbered.
fn assignLayers(session: *Session) Allocator.Error!void {
    const gpa = session.gpa;
    gpa.free(session.file_layers);
    session.file_layers = &.{};
    session.file_layers = try gpa.alloc(u8, session.store.count());
    @memset(session.file_layers, 0);
    const chain = session.options.chain orelse return;
    if (chain.layers.len < 2) return;
    for (session.file_layers, 0..) |*slot, i| {
        const file: SourceStore.Index = @enumFromInt(i);
        if (session.store.package(file) != .platform) continue;
        slot.* = @intCast(chain.layerOfPath(session.store.path(file)) orelse 0);
    }
}

/// Read the app package's `beni.json`, if the command asked for one. A
/// missing manifest is the ordinary case and not an error; a malformed one
/// is reported by the command, which owns the message.
fn readAppManifest(session: *Session) RunError!void {
    const root = session.options.manifest_root orelse return;
    var arena_state: std.heap.ArenaAllocator = .init(session.gpa);
    defer arena_state.deinit();
    const manifest = Manifest.read(arena_state.allocator(), session.io, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    } orelse return;
    session.app_is_platform = manifest.platform;
}

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

/// Whether `file` may write `equatable` (checker.md Appendix A): it is in
/// the core package, or the whole run was told its inputs are core sources.
/// This one stays core's alone — an ordinary annotation gets the mark by
/// inference.
pub fn fileIsCore(session: *const Session, file: SourceStore.Index) bool {
    return session.options.core or session.store.package(file) == .core;
}

/// Whether `file` may write `foreign` (language.md §5.4, boundary.md §2):
/// it is in core, it is in the platform package of this build, or its own
/// package's manifest says `"platform": true`.
///
/// Split from `fileIsCore` because the two permissions are not one
/// permission. boundary.md §2 is explicit that privilege is a ROLE with a
/// checked contract and not an author list: anyone may publish a platform
/// package and write `foreign` in it, and that is the fix for the sparseness
/// §1 diagnoses. `equatable` is different — it is a claim about the type
/// system that core alone makes by hand.
pub fn fileMayDeclareForeign(session: *const Session, file: SourceStore.Index) bool {
    return switch (session.store.package(file)) {
        .core, .platform => true,
        .app => session.options.core or session.app_is_platform,
    };
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

/// Read one file's bytes into the store, once, with the `read` row and the
/// `bytes` counter.
///
/// It is idempotent because the front-end cache turns the per-file phase inside out: the
/// front-end cache must READ the source before it can hash it into a file
/// key, and the key is what decides whether the lexer runs at all — so on a
/// MISS the phase asks for the bytes again and must not pay for them twice.
///
/// **This read is what a `stat` fast path would remove, and the front-end
/// cache does not**: the file key is over the source BYTES, so the source is
/// still read and still hashed. That is 5.2 ms + 0.6 ms of a predicted ~33 ms
/// warm `check`, and it belongs to a daemon, which holds the sources and
/// whose watcher already knows what changed (`fast-compiler.md` §8).
fn readSource(session: *Session, worker: *Worker, file: SourceStore.Index) anyerror!void {
    if (session.store.isRead(file)) return;
    const read_token = session.profile.begin();
    try session.store.read(session.gpa, session.io, file);
    const text = session.store.bytes(file);
    session.profile.end(worker.index, read_token, .read, file.int(), @intCast(text.len));
    worker.addCounter(.bytes, text.len);
}

/// The lex per-file phase: read the bytes into the store, tokenize them into
/// session-owned artifacts (tokens, comments; the line table goes to the
/// store), and turn the lexical diagnostics into reported ones with
/// positions from that table. Two profile events, `read` and `lex`, so the
/// I/O and the scanning are visible separately in a trace.
fn lexPhase(session: *Session, worker: *Worker, file: SourceStore.Index) anyerror!void {
    const gpa = session.gpa;
    try readSource(session, worker, file);
    const text = session.store.bytes(file);

    const lex_token = session.profile.begin();
    var out: Tokenizer.Output = .empty;
    errdefer out.deinit(gpa);
    try Tokenizer.tokenize(gpa, text, &worker.interner, &out);
    session.profile.end(worker.index, lex_token, .lex, file.int(), @intCast(text.len));
    worker.addCounter(.tokens, out.tokens.len);
    worker.addCounter(.files_lexed, 1);

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

/// The parse per-file phase: everything `lexPhase` does, then the parser over
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
    worker.addCounter(.files_parsed, 1);

    var message: Io.Writer.Allocating = .init(gpa);
    defer message.deinit();
    for (tree.errors) |item| {
        // `fmt --migrate-cons` is the fix for these: it rewrites them.
        if (session.options.migrate_cons and item.code == .cons_removed) continue;
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

/// The lower per-file phase: everything `parsePhase` does, then lowering
/// over the installed tree. Scratch from the worker's arena; the Bir goes
/// to session storage next to the tree, its symbols local to the worker
/// until the merge.
fn lowerPhase(session: *Session, worker: *Worker, file: SourceStore.Index) anyerror!void {
    // Where this file's diagnostics begin in this worker's list. A worker
    // takes one file at a time, so everything appended from here on is this
    // file's — which is what lets the round trip REPLACE them with the rows
    // it read back rather than merely compare them.
    const diagnostics_mark = worker.diagnostics.items.len;

    // The hit path (`frontend.md` §4, step 2): read the bytes, hash them into
    // the file key, and — if the artifact is on disk and validates — install
    // the loaded `Bir`, token spans, line-start table and rendered
    // diagnostics instead of lexing, parsing and lowering. Reading stays on
    // the worker because the per-file phase already does file I/O and is
    // already parallel; the one thing that could not stay there is the string
    // table's re-interning, and it does not have to, because a worker has a
    // `Local` pool to hand where the module cache's entry has only `Global`.
    if (session.wantsFileKeys()) {
        try readSource(session, worker, file);
        session.file_keys[file.int()] = session.fileKey(file);
        if (session.options.cache) |cache| {
            if (try loadFrontend(session, worker, cache, file, diagnostics_mark)) return;
        }
    }

    try parsePhase(session, worker, file);
    const gpa = session.gpa;
    const text = session.store.bytes(file);
    const line_starts = session.store.lineStarts(file);
    const tokens = session.artifacts.tokens(file);
    const tree = session.artifacts.ast(file);

    const lower_token = session.profile.begin();
    var bir = try Lower.lower(gpa, worker.arena.allocator(), text, tokens.slice(), tree, &worker.interner, .{
        .core = session.fileIsCore(file),
        .platform = session.fileMayDeclareForeign(file),
        .module_name = session.store.moduleName(file),
    });
    errdefer bir.deinit(gpa);
    session.profile.end(worker.index, lower_token, .lower, file.int(), @intCast(text.len));
    worker.addCounter(.insts, bir.insts.len);
    worker.addCounter(.files_lowered, 1);

    var message: Io.Writer.Allocating = .init(gpa);
    defer message.deinit();
    for (bir.diagnostics) |item| {
        if (isLowerNameDiagnostic(item.code) and
            session.isMalformedSchemaOffset(file, &bir, item.start)) continue;
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

    if (session.options.roundtrip_frontend) try roundTripFrontend(session, worker, file, diagnostics_mark);
    if (session.options.cache) |cache| try storeFrontend(session, worker, cache, file, diagnostics_mark);
}

/// Try to install `file`'s front-end artifact from the cache. True on a hit.
///
/// **Every failure is a MISS and nothing is said about it**: a missing file,
/// an unreadable one, one written for another key, one whose bytes moved
/// under it, one `verify` refuses. A stale cache must be indistinguishable
/// from a cold build (`frontend.md` §1), so none of them is a diagnostic and
/// none is an exit code.
///
/// **The order is read, validate, VERIFY, re-intern, install**, and `verify`
/// is not optional: `Reach`, `js/Lower`, `Types.build` and `Emit` index a
/// `Bir` by raw index with no bounds check, which is correct for one the
/// builder just made and is a crash or a wrong answer for one that came off a
/// disk. The re-intern is last before the install because it is the one step
/// that mutates the worker's pool, and a pool that grew for an artifact that
/// was then refused would be a pool with dead strings in it — harmless, but
/// not free.
fn loadFrontend(
    session: *Session,
    worker: *Worker,
    cache: *const CacheDir,
    file: SourceStore.Index,
    diagnostics_mark: usize,
) anyerror!bool {
    const gpa = session.gpa;
    const token = session.profile.begin();
    const key = session.file_keys[file.int()];

    const read_token = session.profile.begin();
    const bytes = cache.loadFrontend(gpa, &worker.artifact_buffer, key) orelse
        return miss(session, worker, token, file);
    session.profile.end(worker.index, read_token, .frontend_read, file.int(), @intCast(bytes.len));

    const decode_token = session.profile.begin();
    var loaded = artifact_bytes.read(gpa, bytes, key) catch |err| switch (err) {
        error.BadArtifact => return miss(session, worker, token, file),
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer loaded.deinit(gpa);
    session.profile.end(worker.index, decode_token, .frontend_decode, file.int(), @intCast(bytes.len));

    const verify_token = session.profile.begin();
    const structural = loaded.bir.verify(@intCast(loaded.spans.len));
    session.profile.end(worker.index, verify_token, .frontend_verify, file.int(), 0);
    if (!structural) {
        loaded.deinit(gpa);
        return miss(session, worker, token, file);
    }

    const intern_token = session.profile.begin();
    try loaded.intern(gpa, worker.arena.allocator(), &worker.interner);
    session.profile.end(worker.index, intern_token, .frontend_intern, file.int(), 0);
    try installFrontend(session, worker, file, &loaded, diagnostics_mark, .fresh);

    worker.addCounter(.frontend_hits, 1);
    session.profile.end(worker.index, token, .frontend_load, file.int(), @intCast(bytes.len));
    return true;
}

fn miss(session: *Session, worker: *Worker, token: Profile.Token, file: SourceStore.Index) bool {
    worker.addCounter(.frontend_misses, 1);
    session.profile.end(worker.index, token, .frontend_load, file.int(), 0);
    return false;
}

/// This file's rendered front-end diagnostics, as rows, borrowed from the
/// worker's own list. Everything appended from `mark` on is this file's: a
/// worker takes one file at a time.
fn frontendDiagnostics(
    worker: *Worker,
    scratch: Allocator,
    mark: usize,
    out: *std.ArrayList(artifact_bytes.Diagnostic),
) Allocator.Error!void {
    for (worker.diagnostics.items[mark..]) |p| {
        try out.append(scratch, .{
            .code = @intFromEnum(p.diagnostic.code),
            .severity = @intFromEnum(p.diagnostic.severity),
            .start_line = p.diagnostic.span.start.line,
            .start_col = p.diagnostic.span.start.col,
            .end_line = p.diagnostic.span.end.line,
            .end_col = p.diagnostic.span.end.col,
            .message = p.diagnostic.message,
        });
    }
}

/// Write this file's front-end artifact, from the worker that produced it
/// (`plans/m4-2.md` §6 A).
///
/// **A file whose front end produced an `error` is never written.** That is
/// the module cache's "produced by a clean check" bit, one phase earlier and for the same
/// reason: a file that did not lex, parse or lower has a `Bir` the recovery
/// invented, and a later run that installed it would be reporting the
/// recovery's guesses as facts. `warning`s ARE written and replayed, because
/// a warning is a true statement about a file that compiled.
///
/// Every failure is silent, like every other cache write: the run must be
/// byte-identical to one with no cache at all.
fn storeFrontend(
    session: *Session,
    worker: *Worker,
    cache: *const CacheDir,
    file: SourceStore.Index,
    diagnostics_mark: usize,
) anyerror!void {
    const gpa = session.gpa;
    const scratch = worker.arena.allocator();
    const token = session.profile.begin();

    var rows: std.ArrayList(artifact_bytes.Diagnostic) = .empty;
    defer rows.deinit(scratch);
    try frontendDiagnostics(worker, scratch, diagnostics_mark, &rows);
    for (rows.items) |row| {
        if (row.severity == @intFromEnum(diagnostic.Severity.@"error")) {
            session.profile.end(worker.index, token, .frontend_store, file.int(), 0);
            return;
        }
    }

    const bytes = try artifact_bytes.write(gpa, scratch, .{
        .key = session.file_keys[file.int()],
        .bir = session.artifacts.bir(file),
        .interner = &worker.interner,
        .spans = session.artifacts.spans(file),
        .line_starts = session.store.lineStarts(file),
        .diagnostics = rows.items,
    });
    defer gpa.free(bytes);
    if (cache.storeFrontend(session.file_keys[file.int()], bytes)) {
        worker.addCounter(.frontend_bytes, bytes.len);
    }
    session.profile.end(worker.index, token, .frontend_store, file.int(), @intCast(bytes.len));
}

/// Whether this run needs a front-end key per file at all.
///
/// A departure from the module cache's "one code path, and the cost is in the trace":
/// there the key pass is serial and once, here it is on the per-file phase
/// every lowering command runs, and a `dump --stage=bir` that hashed every
/// source for a key nothing reads would be paying 0.6 ms for nothing. The
/// three flags that ask for it are exactly the three that read it.
pub fn wantsFileKeys(session: *const Session) bool {
    return session.options.cache != null or
        session.options.roundtrip_frontend or
        session.options.frontend_keys;
}

/// `file`'s front-end key (`cache/FileKey.zig`): the compiler build id, the
/// package, `Lower.Options`' two permission bits, the dotted module name and
/// the source hash — the inputs to lowering and nothing else.
///
/// On the worker, with no allocation: the recipe fits a stack buffer, and the
/// source hash is `iface_bytes.hash` over bytes the phase has already read.
fn fileKey(session: *const Session, file: SourceStore.Index) FileKey.FileKey {
    return FileKey.compute(.{
        .build_id = session.build_id_bytes,
        .package = session.store.package(file),
        .core = session.fileIsCore(file),
        .platform = session.fileMayDeclareForeign(file),
        .name = session.store.moduleName(file),
        .source_hash = iface_bytes.hash(session.store.bytes(file)),
    });
}

/// `--roundtrip-frontend` (`fast-compiler.md` §8): write this file's
/// artifacts to bytes, read them back, and INSTALL what came back — before
/// `Resolve` runs and before anything downstream has read a thing.
///
/// It runs inside the phase rather than after it, and that is deliberate: it
/// is what makes the oracle strong. Every dump, every diagnostic, every
/// dispatch table and every emitted byte of a run with the flag is built from
/// artifacts that have been through the format, so a fixture that differs is
/// a lossy format and not a lossy test.
///
/// **What is replaced and what is kept.** The `Bir` wholesale; the token
/// `tag` and `start` columns in place; the line-start table; and this file's
/// rendered diagnostics, dropped and re-appended from the bytes. The `Ast`,
/// the `comments`, the lexer's offset-only diagnostics and the token `line`
/// and `payload` columns are KEPT, because they are not artifacts (§3) — and
/// keeping them is what makes `dump --stage=ast|tokens` and `fmt` unchanged
/// under the flag by construction.
///
/// A `verify` that refuses what this very process just wrote is a bug in the
/// format, not a stale file, so it FAILS the run instead of falling back.
fn roundTripFrontend(session: *Session, worker: *Worker, file: SourceStore.Index, diagnostics_mark: usize) anyerror!void {
    const gpa = session.gpa;
    const scratch = worker.arena.allocator();

    var rows: std.ArrayList(artifact_bytes.Diagnostic) = .empty;
    defer rows.deinit(scratch);
    try frontendDiagnostics(worker, scratch, diagnostics_mark, &rows);

    const key = session.file_keys[file.int()];
    const bytes = try artifact_bytes.write(gpa, scratch, .{
        .key = key,
        .bir = session.artifacts.bir(file),
        .interner = &worker.interner,
        .spans = session.artifacts.spans(file),
        .line_starts = session.store.lineStarts(file),
        .diagnostics = rows.items,
    });
    defer gpa.free(bytes);

    var loaded = try artifact_bytes.read(gpa, bytes, key);
    errdefer loaded.deinit(gpa);
    try loaded.intern(gpa, scratch, &worker.interner);
    if (!loaded.bir.verify(@intCast(loaded.spans.len))) return error.ArtifactVerifyFailed;

    try installFrontend(session, worker, file, &loaded, diagnostics_mark, .in_place);
}

/// Put a loaded artifact in place of what the phase produced (or would have).
///
/// Consumes `loaded`: the `Bir` and the line-start table are handed to the
/// session by pointer, the token spans are copied into the live columns, and
/// the diagnostics are duped out of the read buffer, which the caller then
/// frees. Every column that stays is `session.gpa`'s, exactly as a lexed or
/// lowered one is — `plans/m4-2.md` §10's ownership rule, so that a daemon
/// can free one file's columns and rebuild them without touching another's.
const InstallKind = enum {
    /// The phase ran and its output is being replaced by its own bytes
    /// (`--roundtrip-frontend`): the live token list stays and only the two
    /// cached columns are overwritten, so `line` and `payload` survive for
    /// `dump --stage=tokens` and `fmt`.
    in_place,
    /// The phase did not run (a cache hit): every column this file has comes
    /// from the artifact, and the ones it does not carry are empty.
    fresh,
};

fn installFrontend(
    session: *Session,
    worker: *Worker,
    file: SourceStore.Index,
    loaded: *artifact_bytes.Loaded,
    diagnostics_mark: usize,
    kind: InstallKind,
) anyerror!void {
    const gpa = session.gpa;

    // The diagnostics first, because a failure here must not leave the file
    // with half an artifact installed.
    worker.truncateDiagnostics(gpa, diagnostics_mark);
    for (loaded.diagnostics) |d| {
        const code = diagnostic.codeFromInt(d.code) orelse return error.ArtifactVerifyFailed;
        const severity = diagnostic.severityFromInt(d.severity) orelse return error.ArtifactVerifyFailed;
        try worker.replay(
            session,
            file,
            code,
            severity,
            .{ .line = d.start_line, .col = d.start_col },
            .{ .line = d.end_line, .col = d.end_col },
            d.message,
        );
    }

    switch (kind) {
        .in_place => {
            const tokens = session.artifacts.tokensMut(file);
            if (tokens.len != loaded.spans.len) return error.ArtifactVerifyFailed;
            @memcpy(tokens.items(.tag), loaded.spans.items(.tag));
            @memcpy(tokens.items(.start), loaded.spans.items(.start));
            loaded.spans.deinit(gpa);
            loaded.spans = .empty;
            session.artifacts.setBir(gpa, file, loaded.bir);
            loaded.bir = .empty;
        },
        .fresh => {
            session.artifacts.set(gpa, file, .{
                .tokens = .empty,
                .spans = loaded.spans,
                .comments = &.{},
                .lex_diagnostics = &.{},
                .ast = .empty,
                .bir = loaded.bir,
                .formatted = null,
                .worker = worker.index,
            });
            loaded.spans = .empty;
            loaded.bir = .empty;
        },
    }

    session.store.setLineStarts(gpa, file, loaded.line_starts);
    loaded.line_starts = &.{};
    gpa.free(loaded.diagnostics);
    loaded.diagnostics = &.{};
}

/// The format per-file phase: everything `parsePhase` does, then the formatter
/// over the installed tree, into a session-owned buffer next to it.
///
/// A file with any diagnostic has no canonical form and is never written,
/// printed or listed (`fmt/Command.zig`), so it is not formatted at all —
/// and the worker can decide that by itself, which is what keeps this phase
/// free of cross-file knowledge. Every diagnostic a `fmt` run can produce
/// for a file is already known here: the lexer's and the parser's have both
/// finished for this file, and `format_phases` asks for no others
/// (`module_names = false`, so a path that names no module is still
/// formatted — `frontend.md` §1). Skipped files leave `formatted` null,
/// which is what the command tests.
fn formatPhase(session: *Session, worker: *Worker, file: SourceStore.Index) anyerror!void {
    try parsePhase(session, worker, file);
    if (session.artifacts.lexDiagnostics(file).len != 0) return;
    const tree = session.artifacts.ast(file);
    if (tree.errors.len != 0 and !(session.options.migrate_cons and Format.onlyConsRemoved(tree))) return;

    const gpa = session.gpa;
    const text = session.store.bytes(file);
    const format_token = session.profile.begin();
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var skipped: u32 = 0;
    (if (session.options.migrate_cons) Format.migrateCons(
        worker.arena.allocator(),
        tree,
        session.artifacts.tokens(file),
        session.artifacts.comments(file),
        text,
        &out.writer,
        &skipped,
    ) else Format.format(
        worker.arena.allocator(),
        tree,
        session.artifacts.tokens(file),
        session.artifacts.comments(file),
        text,
        session.store.lineStarts(file),
        &out.writer,
    )) catch |err| switch (err) {
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

/// The second half of `resolve_phases` (checker.md §4.2–§4.5): build the
/// module graph from every file's import table, serially, then resolve every
/// reference against the interfaces, each module once its imports are
/// resolved, on up to `jobs` threads (`Resolve.Schedule`).
///
/// It starts on the calling thread, after the join, with the interners
/// merged — the graph interns module names into the global pool and the
/// Birs' symbols are already global, so neither step can be done earlier.
/// Worker 0's arena is the calling thread's scratch for both, because
/// worker 0 is idle here and its arena is already warm; it is reset on the
/// way out.
fn resolveModules(session: *Session) RunError!void {
    const gpa = session.gpa;
    const worker = &session.workers[0];
    defer worker.arena.reset(.retain_capacity);

    const graph_token = session.profile.begin();
    session.graph.deinit(gpa);
    session.graph = try Graph.build(gpa, worker.arena.allocator(), &session.store, &session.artifacts, &session.interner, try session.graphPlatforms(worker.arena.allocator()));
    session.profile.end(0, graph_token, .graph, Profile.Event.no_file, 0);
    session.profile.addCounter(.modules, session.graph.count());
    session.profile.addCounter(.edges, session.graph.edgeCount());
    try session.reportGraphDiagnostics();

    session.resolution.deinit(gpa);
    // One `resolve` event per module (checker.md §9), emitted inside, not
    // one for the whole step: the per-module rows are what the
    // incrementality tests read.
    session.resolution = try Resolve.run(gpa, worker.arena.allocator(), &session.graph, &session.store, &session.artifacts, &session.interner, &session.profile, .{
        .io = session.io,
        .jobs = session.options.jobs,
        .size_by_work = session.options.size_by_work,
        .stack_size = check_stack_size,
    });
    session.profile.addCounter(.interfaces, session.resolution.interfaces.len);
    try session.reportResolveDiagnostics();
}

/// What the graph needs of the platform chain (`Graph.Platforms`), in
/// `scratch`.
fn graphPlatforms(session: *const Session, scratch: Allocator) Allocator.Error!Graph.Platforms {
    const privileged = session.options.core or session.app_is_platform;
    const chain = session.options.chain orelse return .{ .file_layers = session.file_layers, .app_privileged = privileged };
    const sees = try scratch.alloc(u64, chain.layers.len);
    var reexports: std.ArrayList(Graph.Platforms.Reexport) = .empty;
    const lowerings = try scratch.alloc(?[]const u8, chain.layers.len);
    for (chain.layers, sees, lowerings, 0..) |layer, *s, *l, i| {
        s.* = layer.sees;
        l.* = layer.manifest.markup.lowering;
        for (layer.manifest.reexports) |name| try reexports.append(scratch, .{ .module = name, .layer = @intCast(i) });
    }
    return .{
        .file_layers = session.file_layers,
        .sees = sees,
        .reexports = reexports.items,
        .chain = true,
        .vocabulary = if (chain.firstMarkup("vocabulary")) |f| f.value else null,
        .markup_type = if (chain.firstMarkup("type")) |f| f.value else null,
        .lowerings = lowerings,
        .app_privileged = privileged,
    };
}

/// One remap table per worker, `local symbol → global symbol`, with every
/// worker's pool merged into `session.interner` in FILE order.
///
/// A symbol's global id is the order its text is first met walking the
/// files by index — sorted path order — and each file's tokens, then its
/// Bir's symbol column. That is a function of the input alone
/// (`fast-compiler.md` §10, rule 5). Merging whole pools in WORKER order
/// would number a symbol by which worker the `next_file` race handed its
/// file to, so any choice made by id would
/// change between runs of the same input at the same `--jobs`.
/// How many interned names make `mergeInterners` rank them by text.
const rank_by_text_from = 1 << 14;

fn mergeInterners(session: *Session) Allocator.Error![][]InternPool.Symbol {
    const gpa = session.gpa;
    const remaps = try gpa.alloc([]InternPool.Symbol, session.workers.len);
    var made: usize = 0;
    errdefer {
        for (remaps[0..made]) |remap| gpa.free(remap);
        gpa.free(remaps);
    }
    for (session.workers, remaps) |*worker, *remap| {
        remap.* = try gpa.alloc(InternPool.Symbol, worker.interner.count());
        @memset(remap.*, InternPool.unmapped);
        made += 1;
    }
    for (0..session.store.count()) |i| {
        const file: SourceStore.Index = @enumFromInt(i);
        const w = session.artifacts.worker(file);
        const local = &session.workers[w].interner;
        const remap = remaps[w];
        const list = session.artifacts.tokens(file);
        for (list.items(.tag), list.items(.payload)) |tag, payload| {
            if (tag.isInterned()) try session.interner.mergeOne(gpa, local, remap, @enumFromInt(payload));
        }
        for (session.artifacts.bir(file).symbols) |s| try session.interner.mergeOne(gpa, local, remap, s);
    }
    // Whatever no file references — the well-known prefix, which maps to
    // itself — is merged last, by text, so even an unreferenced id is
    // input-derived.
    const locals = try gpa.alloc(*const InternPool.Local, session.workers.len);
    defer gpa.free(locals);
    for (session.workers, locals) |*worker, *local| local.* = &worker.interner;
    try session.interner.mergeRest(gpa, locals, remaps);
    // A project this many names long has rows long enough that sorting them
    // by text is worth ranking every name once: the checker sorts each wide
    // record's fields by text several times over. Below it the ranking
    // would cost more than the sorts it saves.
    if (session.interner.count() >= rank_by_text_from) try TypeStore.rankByText(gpa, &session.interner);
    return remaps;
}

/// `quiet[m]` for every module whose file an earlier phase reported an
/// ERROR on (checker.md §4.3, `Check.Options.quiet`). A WARNING leaves the
/// module loud: it says nothing is wrong, and silencing a module's type
/// errors for one would let a program with a type error print only the
/// warning and exit 0. `graph` is anything with `count` and
/// `moduleFile`, so the rule can be tested without building one.
fn markQuiet(quiet: []bool, graph: anytype, pending: []const Worker.Pending) void {
    for (pending) |p| {
        if (p.diagnostic.severity != .@"error") continue;
        for (0..graph.count()) |i| {
            const m: Graph.Index = @enumFromInt(i);
            if (graph.moduleFile(m) == p.file) quiet[i] = true;
        }
    }
}

/// The type checker (checker.md §6), after the graph and resolution: one
/// `TypeStore` per module, in topological order, each reading only its own
/// Bir and the interfaces of its imports.
fn checkSerial(session: *Session) RunError!void {
    try resolveModules(session);
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
    for (session.workers) |*w| markQuiet(quiet, &session.graph, w.diagnostics.items);

    // The keys' OWN terms (`fast-compiler.md` §8), serially, between
    // resolution and the check: `quiet` is what says which modules have no
    // well-founded key, and the import half is finished on the DAG.
    try session.computeKeys(quiet);

    const n = session.graph.count();
    // The entries land here, one slot per module, written by that module's
    // own worker — `InternPool.Global` is thread-confined, and what makes a
    // load on a worker legal is that it re-interns through the non-mutating
    // `find` (`CacheEntry.loadFinding`).
    const cached = try gpa.alloc(?CacheEntry.Loaded, n);
    defer {
        for (cached) |*slot| {
            if (slot.*) |*l| l.deinit(gpa);
        }
        gpa.free(cached);
    }
    @memset(cached, null);

    gpa.free(session.iface_hashes);
    gpa.free(session.digests);
    session.iface_hashes = &.{};
    session.digests = &.{};
    session.iface_hashes = try gpa.alloc([16]u8, n);
    session.digests = try gpa.alloc(Digest.Digest, n);
    @memset(session.iface_hashes, Digest.none);
    @memset(session.digests, Digest.none);
    const hit = try gpa.alloc(bool, n);
    defer gpa.free(hit);
    @memset(hit, false);

    gpa.free(session.compare_keys);
    session.compare_keys = &.{};
    if (session.options.cutoff_compare) {
        session.compare_keys = try gpa.alloc(Key.Key, n);
        @memset(session.compare_keys, Key.none);
    }

    var cutoff: Check.Cutoff = .{
        .keys = &session.keys,
        .dir = session.options.cache,
        .interner = &session.interner,
        .iface_hash = session.iface_hashes,
        .digest = session.digests,
        .hit = hit,
        .compare = session.compare_keys,
    };

    session.checked.deinit(gpa);
    // `check` is one event per MODULE (checker.md §9), emitted by the
    // checker itself on the worker that took the module, with `constrain`,
    // `solve` and `exhaustive` nested inside each.
    session.checked = try runCheckOnBigStack(session, quiet, cached, &cutoff);
    // The three counters a warm-rebuild claim is made of (`fast-compiler.md`
    // §8). They are summed from the per-module flags the workers set, because
    // the decision is now theirs: there is no serial load pass left to count.
    {
        var hits: u64 = 0;
        var misses: u64 = 0;
        for (0..n) |i| {
            if (!session.keys.isCacheable(@enumFromInt(i))) continue;
            if (hit[i]) hits += 1 else misses += 1;
        }
        session.profile.addCounter(.cache_hits, hits);
        session.profile.addCounter(.cache_misses, misses);
        session.profile.addCounter(.modules_checked, n - hits);
    }
    // By name, so a counter added to `Check.Counters` without a matching
    // `Profile.Counter` is a compile error rather than a number that never
    // reaches the trace.
    inline for (@typeInfo(Check.Counters).@"struct".fields) |f| {
        session.profile.addCounter(@field(Profile.Counter, f.name), @field(session.checked.counters, f.name));
    }
    try session.reportCheckDiagnostics();
    try session.storeEntries(cached);
}

/// Write one cache entry per module whose check produced nothing to hide
/// (`fast-compiler.md` §8), serially, after the check.
///
/// **An entry is written only for a module whose own check produced no
/// `error`-severity diagnostic and which the graph did not poison.** That is
/// §3.2's "produced by a clean check" bit, and it is a refusal to WRITE
/// rather than a bit to read: an `<error>` scheme is a hole every importer
/// checks clean against, and the one failure mode a compiler may not have is
/// `beni check` exiting 0 over it. **Warnings are cached** and replayed
/// byte-identically — `ambiguous_method_receiver` is on by default, so "a
/// module with any diagnostic is never cached" would exempt most real
/// projects.
///
/// Serial, and after `Check.run` rather than on the checking worker
/// (`plans/m4-1.md` decision 9 is about reads; this is where the writes'
/// cost is measurable). Every failure is silent.
fn storeEntries(session: *Session, cached: []const ?CacheEntry.Loaded) RunError!void {
    const cache = session.options.cache orelse return;
    const gpa = session.gpa;
    const token = session.profile.begin();

    // One pass over the check's diagnostics to learn which modules spoke,
    // and with what severity. Grouping here rather than per module keeps it
    // linear instead of quadratic in a project with many messages.
    const count = session.graph.count();
    const clean = try gpa.alloc(bool, count);
    defer gpa.free(clean);
    @memset(clean, true);
    for (session.checked.diagnostics) |item| {
        if (item.severity != .@"error") continue;
        if (item.module.int() < count) clean[item.module.int()] = false;
    }
    // A module an earlier phase reported on is not clean either, whatever
    // its own check said: it was checked QUIETLY, so its silence is the
    // `quiet` flag's and not the program's. `Key`'s uncacheable bit already
    // carries that, and this is the second place it is honoured.

    var written: u64 = 0;
    var bytes_written: u64 = 0;
    for (0..count) |i| {
        const m: Graph.Index = @enumFromInt(i);
        if (!session.keys.isCacheable(m)) continue;
        if (!clean[i]) continue;
        // A hit is already on disk under this very key, and re-writing it
        // would produce the same bytes at the price of a create and a
        // rename per module — which is exactly the cost `plans/m4-1.md` §7
        // measurement 3 exists to watch.
        if (i < cached.len and cached[i] != null) continue;

        const entry = session.entryBytes(gpa, m) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer gpa.free(entry);
        if (cache.store(session.keys.of(m), entry)) {
            written += 1;
            bytes_written += entry.len;
        }
    }
    session.profile.addCounter(.cache_bytes, bytes_written);
    session.profile.end(0, token, .cache_store, Profile.Event.no_file, @intCast(@min(bytes_written, std.math.maxInt(u32))));
}

/// One module's entry: the record's bytes verbatim, the dispatch sidecar and
/// the module's own diagnostics (`checker.md` §7).
fn entryBytes(session: *Session, gpa: Allocator, m: Graph.Index) Allocator.Error![]u8 {
    const record = try iface_bytes.write(gpa, &session.resolution.interfaces[m.int()], &session.interner);
    defer gpa.free(record);
    const sidecar = try dispatch_bytes.write(
        gpa,
        &session.checked.dispatch[m.int()],
        &session.graph,
        &session.checked.types,
        &session.interner,
    );
    defer gpa.free(sidecar);
    const plan = try schema_plan_bytes.write(gpa, &session.checked.plans[m.int()], &session.interner);
    defer gpa.free(plan);

    var rows: std.ArrayList(entry_bytes.Diagnostic) = .empty;
    defer rows.deinit(gpa);
    for (session.checked.diagnostics) |item| {
        if (item.module != m) continue;
        try rows.append(gpa, .{
            .code = @intFromEnum(item.code),
            .severity = @intFromEnum(item.severity),
            .has_token = item.token != null,
            .region = @intFromEnum(item.region),
            .token = item.token orelse 0,
            .message = item.message,
        });
    }
    const diagnostics = try entry_bytes.writeDiagnostics(gpa, rows.items);
    defer gpa.free(diagnostics);

    return entry_bytes.write(gpa, .{
        .key = session.keys.of(m),
        .interface = record,
        .dispatch = sidecar,
        .schema_plan = plan,
        .diagnostics = diagnostics,
    });
}

/// One persistent-cache key per module (`fast-compiler.md` §8, `cache/Key.zig`).
///
/// It runs on every checking run, with or without a cache directory, for the
/// reason `Session.keys` gives: one code path, and a cost that is in the
/// trace rather than in a branch. `reported` is `checkSerial`'s `quiet` — a
/// module an earlier phase already spoke about has an interface the parser or
/// the resolver guessed, so it has no well-founded key and neither has
/// anything that imports it.
fn computeKeys(session: *Session, reported: []const bool) RunError!void {
    const gpa = session.gpa;
    const worker = &session.workers[0];
    const token = session.profile.begin();

    const files = session.store.count();
    const lower_core = try gpa.alloc(bool, files);
    defer gpa.free(lower_core);
    const lower_platform = try gpa.alloc(bool, files);
    defer gpa.free(lower_platform);
    for (0..files) |i| {
        const file: SourceStore.Index = @enumFromInt(i);
        lower_core[i] = session.fileIsCore(file);
        lower_platform[i] = session.fileMayDeclareForeign(file);
    }

    // The siblings the compiler carries, so a `foreign` in `core/` hashes
    // the bytes in the binary rather than a file the user does not have.
    // Same rule `platform.collectEmbedded` follows: a `--core-root` run
    // reads core from disk, so the embedded copy must not shadow it.
    var embedded: std.ArrayList(Key.Asset) = .empty;
    defer embedded.deinit(gpa);
    if (session.options.core_root == null) {
        for (core_package.assets) |asset| {
            try embedded.append(gpa, .{ .path = asset.path, .bytes = asset.bytes });
        }
    }
    if (session.options.chain) |chain| for (chain.layers) |layer| {
        const p = layer.embedded orelse continue;
        for (p.assets) |asset| try embedded.append(gpa, .{ .path = asset.path, .bytes = asset.bytes });
    };

    session.keys.deinit(gpa);
    session.keys = try Key.build(
        gpa,
        worker.arena.allocator(),
        &session.graph,
        &session.store,
        &session.artifacts,
        &session.interner,
        .{
            .build_id = compilerBuildId(session.options.cache_build_id),
            .informational = session.options.informational,
            .pattern_budget = session.options.pattern_budget,
            .lower_core = lower_core,
            .lower_platform = lower_platform,
            .reported = reported,
            .embedded = embedded.items,
            .io = session.io,
        },
    );
    worker.arena.reset(.retain_capacity);
    session.profile.end(0, token, .cache_key, Profile.Event.no_file, 0);
}

/// The build id a key is computed with: this compiler's, or the bytes
/// `--cache-build-id=<s>` substituted for it, hashed down to sixteen so the
/// term keeps its width whatever the string is.
fn compilerBuildId(override: ?[]const u8) [16]u8 {
    const text = override orelse return build_id.bytes;
    return @import("resolve/iface_bytes.zig").hash(text);
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
/// DAG-parallel checking (checker.md §4.4) needs the same room on
/// every worker, which is why the number lives in `Check` and is stated at
/// every spawn: `std.Thread.SpawnConfig`'s default is nowhere near it.
pub const check_stack_size = Check.stack_size;

fn runCheckOnBigStack(session: *Session, quiet: []const bool, cached: []?CacheEntry.Loaded, cutoff: *Check.Cutoff) RunError!Check {
    const Runner = struct {
        session: *Session,
        quiet: []const bool,
        cached: []?CacheEntry.Loaded,
        cutoff: *Check.Cutoff,
        result: Check.Error!Check = undefined,

        fn go(r: *@This()) void {
            r.result = Check.run(
                r.session.gpa,
                r.session.io,
                &r.session.workers[0].arena,
                &r.session.graph,
                &r.session.artifacts,
                r.session.resolution.interfaces,
                r.session.resolution.provenance,
                &r.session.interner,
                .{
                    .profile = &r.session.profile,
                    .keep_stores = r.session.options.keep_type_stores,
                    .informational = r.session.options.informational,
                    .quiet = r.quiet,
                    .jobs = r.session.options.jobs,
                    .size_by_work = r.session.options.size_by_work,
                    .pattern_budget = r.session.options.pattern_budget,
                    .roundtrip_interfaces = r.session.options.roundtrip_interfaces,
                    .roundtrip_dispatch = r.session.options.roundtrip_dispatch,
                    .cached = r.cached,
                    .cutoff = r.cutoff,
                },
            );
        }
    };
    var runner: Runner = .{ .session = session, .quiet = quiet, .cached = cached, .cutoff = cutoff };
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
        // A message ABOUT a declaration carries the token it should
        // underline, because no instruction carries a declaration's name
        // (static-dispatch-spike.md §10.9, §10.10).
        const token = item.token orelse if (item.region.int() < bir.insts.len)
            bir.insts.items(.main_token)[item.region.int()]
        else
            0;
        const start, const end = session.tokenSpan(file, token);
        try session.workers[0].reportAs(session, file, item.code, item.severity, start, end, item.message);
    }
}

/// The span of `token` in `file`, from the token list the parser produced.
/// This is what `Bir.Inst.main_token` buys: a resolution diagnostic points
/// at an instruction, and an instruction points at the exact bytes. A string
/// literal's opening quote stands for the whole literal: it spans to the
/// closing quote. So does a multiline literal's first line: it spans to the
/// end of its last.
fn tokenSpan(session: *const Session, file: SourceStore.Index, token: u32) struct { diagnostic.Position, diagnostic.Position } {
    const line_starts = session.store.lineStarts(file);
    if (line_starts.len == 0) return .{ .{ .line = 1, .col = 1 }, .{ .line = 1, .col = 1 } };
    const tokens = session.artifacts.spans(file);
    if (token >= tokens.len()) return .{ .{ .line = 1, .col = 1 }, .{ .line = 1, .col = 1 } };
    const tags = tokens.tags;
    const starts = tokens.starts;
    const source = session.store.bytes(file);
    const start = starts[token];
    const end = switch (tags[token]) {
        .str_start => stringLiteralEnd(source, tags, starts, token),
        .multiline_line => multilineLiteralEnd(source, tags, starts, line_starts, token),
        else => Tokenizer.tokenEnd(source, tags[token], start),
    };
    return .{ diagnostic.position(line_starts, start), diagnostic.position(line_starts, end) };
}

/// Where the multiline literal whose first line is the `multiline_line` at
/// `first` ends: the end of its last line. The literal is the run of
/// `multiline_line`s on consecutive lines, the parser's rule (a blank line
/// ends it).
fn multilineLiteralEnd(source: [:0]const u8, tags: []const Token.Tag, starts: []const u32, line_starts: []const u32, first: u32) u32 {
    var last = first;
    var line = diagnostic.position(line_starts, starts[first]).line;
    var i = first + 1;
    while (i < tags.len and tags[i] == .multiline_line) : (i += 1) {
        const next = diagnostic.position(line_starts, starts[i]).line;
        if (next != line + 1) break;
        last = i;
        line = next;
    }
    return Tokenizer.tokenEnd(source, .multiline_line, starts[last]);
}

/// Where the string literal opened by the `str_start` at `open` ends: just
/// past its closing quote. A literal whose closing quote the lexer never
/// produced (it met a line end, a nested string or the end of the file,
/// each already a parse error) keeps the opening quote's own extent.
fn stringLiteralEnd(source: [:0]const u8, tags: []const Token.Tag, starts: []const u32, open: u32) u32 {
    var i = open + 1;
    while (i < tags.len) : (i += 1) switch (tags[i]) {
        .str_end => return Tokenizer.tokenEnd(source, .str_end, starts[i]),
        .str_start, .invalid, .eof => break,
        else => {},
    };
    return Tokenizer.tokenEnd(source, .str_start, starts[open]);
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
                const members = session.graph.cycle_members[item.cycle_start..item.cycle_end];
                for (members) |m| {
                    try cycle_names.append(gpa, session.interner.slice(session.graph.moduleName(m)));
                }
                cx.cycle = cycle_names.items;
                // A step of the circle that is markup's dependency on the
                // vocabulary module, not an import (`frontend.md` §9.8).
                for (members, 0..) |m, i| {
                    if (!session.graph.isMarkupEdge(m, members[(i + 1) % members.len])) continue;
                    cx.markup_edge = session.interner.slice(session.graph.moduleName(m));
                    cx.name = session.interner.slice(session.graph.moduleName(members[(i + 1) % members.len]));
                    break;
                }
            },
            .duplicate_module => {
                cx.name = session.store.moduleName(item.file);
                cx.other_path = session.store.path(session.graph.moduleFile(@enumFromInt(item.cycle_start)));
            },
            else => {
                cx.name = session.moduleNameOfImport(item.file, item.token);
                if (item.code == .unknown_module) {
                    cx.platform = session.platformOffering(cx.name);
                    session.hiddenByChain(item.file, cx.name, &cx);
                }
            },
        }
        try ResolveDiagnostics.message(item.code, cx, &message.writer);
        const start, const end = session.tokenSpan(item.file, item.token);
        try session.workers[0].report(session, item.file, item.code, start, end, message.written());
    }
}

/// When the module `name` that `file` failed to import exists in the platform
/// chain and the chain hides it from `file` (`boundary.md` §9.1), fill in
/// which platform has it and, for a platform importer, which platform that
/// is: the message then names the key that would expose it.
fn hiddenByChain(session: *const Session, file: SourceStore.Index, name: []const u8, cx: *ResolveDiagnostics.Context) void {
    const chain = session.options.chain orelse return;
    const symbol = session.interner.find(name) orelse return;
    const graph = &session.graph;
    const from: Graph.Index = for (0..graph.count()) |i| {
        const m: Graph.Index = @enumFromInt(i);
        if (graph.moduleFile(m) == file) break m;
    } else return;
    const target = graph.hiddenPlatformModule(from, symbol) orelse return;
    const layers = graph.modules.items(.layer);
    cx.hidden_in = chain.layers[layers[target.int()]].name;
    if (graph.modulePackage(from) == .platform) cx.importer_platform = chain.layers[layers[from.int()]].name;
}

/// The module path an import token spells, for `unknown_module`. Taken
/// from the source rather than from a symbol so a path the interner never
/// saw still prints.
fn moduleNameOfImport(session: *const Session, file: SourceStore.Index, token: u32) []const u8 {
    const tokens = session.artifacts.spans(file);
    if (token >= tokens.len()) return "";
    return Tokenizer.slice(session.store.bytes(file), tokens.tags[token], tokens.starts[token]);
}

/// The name of a platform EMBEDDED IN THIS BINARY that has a module called
/// `module_name`, when this run named no `--platform` — the honest half of
/// the hint `frontend.md` §1 attaches to an unknown module. Empty otherwise.
///
/// Empty when a platform WAS named, because then the module really is not
/// there and advice to name one is noise; and empty for anything not in the
/// box, because a platform given as a directory cannot be guessed at. The
/// name is compared against the platform's file list rather than derived
/// into a buffer: `Node.beni` is the module `Node` and `A/B.beni` is `A.B`,
/// which is a character rewrite and needs no allocation.
fn platformOffering(session: *const Session, module_name: []const u8) []const u8 {
    if (session.options.platform != null or module_name.len == 0) return "";
    for (platform_packages.platforms) |platform| {
        for (platform.files) |f| {
            if (relIsModule(f.rel, module_name)) return platform.name;
        }
    }
    return "";
}

fn relIsModule(rel: []const u8, name: []const u8) bool {
    const stem = if (std.mem.endsWith(u8, rel, SourceStore.extension))
        rel[0 .. rel.len - SourceStore.extension.len]
    else
        rel;
    if (stem.len != name.len) return false;
    for (stem, name) |a, b| {
        if ((if (a == '/') @as(u8, '.') else a) != b) return false;
    }
    return true;
}

fn reportResolveDiagnostics(session: *Session) RunError!void {
    const gpa = session.gpa;
    var message: Io.Writer.Allocating = .init(gpa);
    defer message.deinit();
    for (session.resolution.diagnostics) |item| {
        const file = session.graph.moduleFile(item.module);
        // A malformed schema body can retain valid-looking references while
        // the parser recovers to its next field. The syntax diagnostic owns
        // that declaration: resolving another reference from the same
        // recovered body would be a cascade. Ordinary declarations keep the
        // established recovery contract and report all later name errors.
        if (session.isMalformedSchemaReference(file, item.token)) continue;
        message.clearRetainingCapacity();
        var cx: ResolveDiagnostics.Context = .{
            .name = session.symbolText(item.name),
            .module = session.symbolText(item.module_name),
            .owner = session.symbolText(item.owner),
            .expected = item.expected,
            .found = item.found,
        };
        const schema_location = if (item.schema_origin_module) |origin|
            try session.resolveOriginLocation(gpa, origin, item.schema_origin_token)
        else
            null;
        defer if (schema_location) |location| gpa.free(location);
        const alias_location = if (item.alias_origin_module) |origin|
            try session.resolveOriginLocation(gpa, origin, item.alias_origin_token)
        else
            null;
        defer if (alias_location) |location| gpa.free(location);
        cx.schema_location = schema_location orelse "";
        cx.alias_location = alias_location orelse "";
        const available_symbols = session.resolution.available_names[item.available_start..item.available_end];
        const available = try gpa.alloc([]const u8, available_symbols.len);
        defer gpa.free(available);
        for (available_symbols, available) |symbol, *name| name.* = session.interner.slice(symbol);
        cx.available = available;
        // The qualified uses that follow a failed import get the same hint:
        // the fix is the same flag (frontend.md §1).
        if (item.code == .unknown_module_alias) cx.platform = session.platformOffering(cx.module);
        try ResolveDiagnostics.message(item.code, cx, &message.writer);
        const start, const end = session.tokenSpan(file, item.token);
        if (item.code == .expected_token and try session.rewriteMessage(file, item.code, start, message.written())) continue;
        try session.workers[0].report(session, file, item.code, start, end, message.written());
    }
}

/// Replace the text of the diagnostic an earlier phase reported for
/// `file` with `code` at `start`, and say whether there was one. Elm's
/// `exposing (T(..))` is the one user: the parser reports it where
/// it is written, and only resolution can name `T`'s constructors — one
/// diagnostic, with the better text, and not two.
fn rewriteMessage(session: *Session, file: SourceStore.Index, code: diagnostic.Code, start: diagnostic.Position, message: []const u8) Allocator.Error!bool {
    for (session.workers) |*w| {
        for (w.diagnostics.items) |*pending| {
            const d = &pending.diagnostic;
            if (pending.file != file or d.code != code) continue;
            if (d.span.start.line != start.line or d.span.start.col != start.col) continue;
            const owned = try wrap.reflow(session.gpa, message);
            session.gpa.free(d.message);
            d.message = owned;
            return true;
        }
    }
    return false;
}

fn isMalformedSchemaReference(session: *const Session, file: SourceStore.Index, token: u32) bool {
    const bir = session.artifacts.bir(file);
    const starts = session.artifacts.spans(file).starts;
    if (token >= starts.len) return false;
    return session.isMalformedSchemaOffset(file, bir, starts[token]);
}

fn isMalformedSchemaOffset(session: *const Session, file: SourceStore.Index, bir: *const Bir, offset: u32) bool {
    const starts = session.artifacts.spans(file).starts;

    for (bir.decls, 0..) |decl, i| {
        if (decl.kind != .schema or decl.name_token >= starts.len) continue;
        const start = starts[decl.name_token];
        const end = if (i + 1 < bir.decls.len and bir.decls[i + 1].name_token < starts.len)
            starts[bir.decls[i + 1].name_token]
        else
            std.math.maxInt(u32);
        if (offset < start or offset >= end) continue;

        for (session.artifacts.lexDiagnostics(file)) |item| {
            if (item.start >= start and item.start < end) return true;
        }
        for (session.artifacts.ast(file).errors) |item| {
            if (item.start >= start and item.start < end) return true;
        }
        // Modifier duplication is diagnosed while lowering because the AST
        // deliberately preserves every modifier for formatting and dumps.
        // It is still a malformed schema declaration for recovery purposes;
        // only this syntax diagnostic marks the declaration, never one of
        // the name errors that the marker suppresses.
        for (bir.diagnostics) |item| {
            if (item.code == .duplicate_schema_modifier and item.start >= start and item.start < end) return true;
        }
        return false;
    }
    return false;
}

fn isLowerNameDiagnostic(code: diagnostic.Code) bool {
    return switch (code) {
        .unbound_variable,
        .unbound_constructor,
        .unbound_type,
        .unbound_type_variable,
        .unknown_module_alias,
        => true,
        else => false,
    };
}

fn resolveOriginLocation(session: *const Session, gpa: Allocator, module: Graph.Index, token: u32) Allocator.Error![]u8 {
    const file = session.graph.moduleFile(module);
    const start, _ = session.tokenSpan(file, token);
    return std.fmt.allocPrint(gpa, "{s}:{d}:{d}", .{ session.store.path(file), start.line, start.col });
}

fn symbolText(session: *const Session, s: InternPool.Symbol.Optional) []const u8 {
    return session.interner.slice(s.unwrap() orelse return "");
}

fn reportInvalidModulePath(session: *Session, file: SourceStore.Index) Allocator.Error!void {
    const p = session.store.path(file);
    const formatted = try std.fmt.allocPrint(session.gpa,
        \\I cannot turn the path `{s}` into a module name.
        \\
        \\A module name comes from the path: `src/Json/Decode.beni` is `Json.Decode`. Every
        \\segment of the path after the source root must be an upper identifier — a capital
        \\letter followed by letters, digits or underscores.
    , .{p});
    defer session.gpa.free(formatted);
    // The path is interpolated, so the first line's width is the user's and
    // not this file's: re-wrap like every other message (`render/wrap.zig`).
    const message = try wrap.reflow(session.gpa, formatted);
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

/// One diagnostic produced AFTER `run` returned: `beni build`'s emit phase
/// is not a `Phases.after`, because it must not run at all when the check
/// failed. `message` is borrowed for the call.
pub const LateItem = struct {
    code: diagnostic.Code,
    file: SourceStore.Index,
    /// Token index into `file`'s token list.
    token: u32,
    message: []const u8,
    /// Where to report INSTEAD of `file`'s token, for a fault whose text is
    /// not in a beni source file. `file` and `token` are ignored when this
    /// is set. Borrowed for the call, like `message`.
    at: ?At = null,
};

/// A place in a file the `SourceStore` does not hold: a sibling `.js`
/// (read from disk, or carried in the binary for `core/`), a platform's
/// `beni.json`, or a beni file a diagnostic names WITHOUT pointing inside
/// it.
///
/// `boundary.md` §4's rule is that a diagnostic points at the file whose
/// text is wrong, and a sibling's text is exactly as wrong as a module's.
/// The scanner knows the byte offset of every export, reference and
/// specifier it reads (`js/Sibling.zig`), so the only thing missing was a
/// way to carry a position and the bytes to cut an excerpt from — the
/// store cannot supply either, because a `.js` is not one of its files.
pub const At = struct {
    path: []const u8,
    /// Default is the whole-file 1:1 that `reportInvalidModulePath` uses
    /// for a fault about a file rather than a place in one.
    start: diagnostic.Position = .{ .line = 1, .col = 1 },
    end: diagnostic.Position = .{ .line = 1, .col = 1 },
    /// `path`'s bytes, for the excerpt. **`null` means no excerpt for THIS
    /// diagnostic**, and says so even when the store holds `path`:
    /// `missing_main` reports against a module that is perfectly fine, so
    /// underlining any of its text would be a lie — and a warning in the
    /// same file, in the same stream, still gets its own. That is why
    /// `render/text.zig`'s lookup is asked per diagnostic. Borrowed for the
    /// call.
    source: ?[]const u8 = null,
};

/// What `renderLate` hands `lookupSource` for the duration of one render:
/// one entry per late item that carried an `At`, keyed by the whole SPAN
/// rather than by the path. The path alone is not enough, because two
/// diagnostics in one stream may name the same file and want different
/// answers — `missing_main` wants none, and a warning ten lines down wants
/// its own line.
const LateSource = struct { span: diagnostic.Span, source: ?[]const u8 };

fn sameSpan(a: diagnostic.Span, b: diagnostic.Span) bool {
    return std.mem.eql(u8, a.file, b.file) and
        a.start.order(b.start) == .eq and a.end.order(b.end) == .eq;
}

/// Render `items` on `stderr` in the run's diagnostics format, sorted by the
/// schema's comparator like every other wave. Returns how many of `items`
/// were errors.
///
/// **What `run` held back comes with them.** Under `defer_render` — which is
/// how `build` runs — `run` collected its own wave and rendered nothing, so
/// this is the single render of the whole stream and both waves are sorted
/// together into ONE array. Two renders would be two JSON arrays and not
/// one, and the black-box harness parses the stream as a whole.
///
/// Called exactly once per run, and safe with `items` empty: a run that had
/// warnings and an emit phase that had nothing still has to print them.
pub fn renderLate(session: *Session, items: []const LateItem, stderr: *Io.Writer) RunError!u32 {
    const held = if (session.options.defer_render) session.diagnostics.items else &.{};
    if (items.len == 0 and held.len == 0) return 0;
    const gpa = session.gpa;
    const rendered = try gpa.alloc(diagnostic.Diagnostic, items.len + held.len);
    defer gpa.free(rendered);
    // The late messages are re-wrapped here rather than where they were
    // built, so that every message in the stream passes through exactly one
    // wrap (`render/wrap.zig`); `held` already did on its way into a
    // worker's list.
    var late_messages: std.ArrayList([]u8) = .empty;
    defer {
        for (late_messages.items) |m| gpa.free(m);
        late_messages.deinit(gpa);
    }
    try late_messages.ensureTotalCapacityPrecise(gpa, items.len);
    var late_sources: std.ArrayList(LateSource) = .empty;
    defer late_sources.deinit(gpa);
    for (items, rendered[0..items.len]) |item, *slot| {
        const start, const end = if (item.at) |at|
            .{ at.start, at.end }
        else
            session.tokenSpan(item.file, item.token);
        late_messages.appendAssumeCapacity(try wrap.reflow(gpa, item.message));
        slot.* = .{
            .code = item.code,
            .severity = .@"error",
            .span = .{
                .file = if (item.at) |at| at.path else session.store.path(item.file),
                .start = start,
                .end = end,
            },
            .title = diagnostic.title(item.code),
            .message = late_messages.items[late_messages.items.len - 1],
        };
        if (item.at) |at| try late_sources.append(gpa, .{ .span = slot.span, .source = at.source });
    }
    @memcpy(rendered[items.len..], held);
    diagnostic.sort(rendered);
    session.late_sources = late_sources.items;
    defer session.late_sources = &.{};
    try session.render(rendered, stderr);
    var errors: u32 = 0;
    for (rendered[0..items.len]) |d| {
        if (d.severity == .@"error") errors += 1;
    }
    return errors;
}

/// One wave of diagnostics onto `stderr`, in the run's format. The only
/// place either renderer is called from, so "one array per stream" is a
/// property of who calls this and how often.
fn render(session: *Session, items: []const diagnostic.Diagnostic, stderr: *Io.Writer) RunError!void {
    switch (session.options.diagnostics) {
        .text => try render_text.render(stderr, items, .{ .context = session, .lookup = lookupSource }),
        .json => try render_json.render(stderr, items),
    }
    try stderr.flush();
}

/// The bytes the text renderer cuts an excerpt from. `late_sources` comes
/// first and is AUTHORITATIVE for the span it names: a sibling `.js` is not
/// in the store at all, and an entry with no source means this diagnostic
/// shows no excerpt even when the store does hold its file (`At.source`).
fn lookupSource(context: *const anyopaque, d: *const diagnostic.Diagnostic) ?[]const u8 {
    const session: *const Session = @ptrCast(@alignCast(context));
    for (session.late_sources) |entry| {
        if (sameSpan(entry.span, d.span)) return entry.source;
    }
    const index = session.store.find(d.span.file) orelse return null;
    return session.store.bytes(index);
}

/// Write the Chrome trace. `run` calls this at its end; `beni build` calls
/// it AGAIN afterwards, because the emit phase runs after `run` has
/// returned and its counters would otherwise never reach the file.
pub fn writeProfile(session: *Session, profile_path: []const u8) RunError!void {
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

// A documented exception to black-box testing: no frontend phase emits a
// warning today, so no program can show a module silenced by one, and the
// rule is pinned here instead.
test "markQuiet: an earlier phase's ERROR quiets its module, a WARNING does not" {
    const FakeGraph = struct {
        files: []const SourceStore.Index,
        fn count(g: *const @This()) usize {
            return g.files.len;
        }
        fn moduleFile(g: *const @This(), m: Graph.Index) SourceStore.Index {
            return g.files[m.int()];
        }
    };
    const f0: SourceStore.Index = @enumFromInt(0);
    const f1: SourceStore.Index = @enumFromInt(1);
    const f2: SourceStore.Index = @enumFromInt(2);
    // Module i lives in file 2 - i, so a mix-up of the two numberings shows.
    const graph: FakeGraph = .{ .files = &.{ f2, f1, f0 } };
    const span: diagnostic.Span = .{ .file = "x.beni", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 2 } };
    const pending = [_]Worker.Pending{
        .{ .file = f0, .diagnostic = .{ .code = .ambiguous_method_receiver, .severity = .warning, .span = span, .title = "", .message = "" } },
        .{ .file = f1, .diagnostic = .{ .code = .tab_in_source, .severity = .@"error", .span = span, .title = "", .message = "" } },
    };
    var quiet = [_]bool{ false, false, false };
    markQuiet(&quiet, &graph, &pending);
    try testing.expectEqualSlices(bool, &.{ false, true, false }, &quiet);
}

// Input-ordered symbol numbering. The files are handed to the workers in
// the one order the race can produce and a fixed run cannot — file 0 to
// worker 1, file 1 to worker 0 — and the ids must still follow the FILES.
// A merge in worker order, or in reverse file order, fails the ordering
// assertions below. No black-box test can reach this deterministically: a
// program shows the ids only through a choice made by id, and only a
// racing scheduler would vary them.
test "mergeInterners numbers symbols in file order, whichever worker lexed the file" {
    const gpa = testing.allocator;
    var session = try Session.init(gpa, testing.io, .{ .jobs = 2, .diagnostics = .json });
    defer session.deinit();
    try session.store.addPending(gpa, "A.beni", 2, .app);
    try session.store.addPending(gpa, "B.beni", 2, .app);
    try session.store.finish(gpa);
    try session.artifacts.resize(gpa, 2);

    // Worker 0 lexed B (file 1) and worker 1 lexed A (file 0). Both files
    // name `shared`; only A names `fromA` and only B names `fromB`.
    const w0 = &session.workers[0].interner;
    const w1 = &session.workers[1].interner;
    const b_only = try w0.getOrPut(gpa, "fromB");
    const b_shared = try w0.getOrPut(gpa, "shared");
    const a_shared = try w1.getOrPut(gpa, "shared");
    const a_only = try w1.getOrPut(gpa, "fromA");
    const files = [_]struct { worker: u32, symbols: [2]InternPool.Symbol }{
        .{ .worker = 1, .symbols = .{ a_shared, a_only } },
        .{ .worker = 0, .symbols = .{ b_only, b_shared } },
    };
    for (files, 0..) |f, i| {
        var list: @import("lex/Token.zig").TokenList = .empty;
        for (f.symbols) |s| try list.append(gpa, .{ .tag = .lower_ident, .start = 0, .line = 0, .payload = @intFromEnum(s) });
        try list.append(gpa, .{ .tag = .eof, .start = 0, .line = 0, .payload = 0 });
        session.artifacts.set(gpa, @enumFromInt(i), .{ .tokens = list, .comments = &.{}, .lex_diagnostics = &.{}, .ast = .empty, .bir = .empty, .formatted = null, .worker = f.worker });
    }

    const remaps = try session.mergeInterners();
    defer {
        for (remaps) |remap| gpa.free(remap);
        gpa.free(remaps);
    }

    // File A's names come first, in A's token order, then B's new one —
    // however the pools were filled and in whatever order they were built.
    const shared = remaps[1][@intFromEnum(a_shared)];
    const from_a = remaps[1][@intFromEnum(a_only)];
    const from_b = remaps[0][@intFromEnum(b_only)];
    try testing.expectEqual(shared, remaps[0][@intFromEnum(b_shared)]);
    try testing.expect(@intFromEnum(shared) < @intFromEnum(from_a));
    try testing.expect(@intFromEnum(from_a) < @intFromEnum(from_b));
    try testing.expectEqualStrings("fromB", session.interner.slice(from_b));
    // Every slot is filled, the well-known prefix to itself.
    for (remaps) |remap| {
        for (remap, 0..) |g, local| {
            try testing.expect(g != InternPool.unmapped);
            if (local < InternPool.WellKnown.count) try testing.expectEqual(@as(u32, @intCast(local)), @intFromEnum(g));
        }
    }
}
