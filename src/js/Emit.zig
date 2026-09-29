//! `beni build`'s back half (docs/design/backend.md §2, §5;
//! boundary.md §4, §5): the platform contract's build-time checks, then one
//! `.mjs` per source module plus the sibling JavaScript the modules bind to
//! and the platform's entry file.
//!
//! **Development output is one ESM file per source module, mirroring the
//! source tree** (§2). Nothing is eliminated and every name is readable,
//! because this is the mode the §2 warm-rebuild budget of 15 ms is measured
//! against: one edit rewrites one small file. Release output as chunks is
//! future work (§10).
//!
//! Layout under `--out`:
//!
//! ```
//! out/Main.mjs                       the app's modules, mirroring their names
//! out/_core/List.mjs                 core, and its hand-written half beside it
//! out/_core/List.foreign.mjs
//! out/_platform/Node.mjs             the platform, its sibling, and its runtime
//! out/_platform/Node.foreign.mjs
//! out/_platform/runtime.foreign.mjs
//! out/_main.mjs                      the entry file: imports `main`, hands it to `run`
//! ```
//!
//! Packages get a directory each because a module's identity is
//! `(package, name)` (checker.md §4.1) and an app may perfectly well have
//! its own `List`.
//!
//! **Every name the compiler reserves in that tree begins with `_`, and
//! nothing else may collide with anything under case folding** (§2, *The
//! output tree does not depend on the file system's case sensitivity*).
//! A module is named by its path and every segment is an upper identifier,
//! so `_` is the one region of the name space no module can reach — which
//! is the whole reason the prefix is there. `core/`, `platform/` and
//! `main.mjs` were all reachable: `Core.List` lands on `Core/List.mjs`,
//! `Platform.Node` on `Platform/Node.mjs`, and `Main.beni` on `Main.mjs`,
//! which on APFS and NTFS IS `main.mjs`. The last of those was a live
//! defect and not a hazard — the entry shim was written second, so it
//! overwrote the module and then imported itself.
//!
//! `checkOutputPaths` is the backstop for what the prefix does not reach
//! (two modules `Json.Decode` and `JSON.Decode`, say): every produced path
//! is folded with ASCII lower-casing and a duplicate is
//! `output_path_collision`, before a byte is written.
//!
//! **Every emitted file is `.mjs`, the hand-written ones included** (§2:
//! "so nothing depends on a `package.json` the user owns"). A sibling that
//! landed as `.js` would be an ES module with no module type declared, and
//! Node reparses it and warns on every start — which is exactly the
//! dependency on a user-owned `package.json` the rule exists to avoid. The
//! source keeps its `.js` name, because that is what a hand-written
//! JavaScript file is called and `language.md` §5.4 fixes the sibling's NAME
//! and not its extension; only the copy is renamed.
//!
//! The copy cannot simply keep its stem — `out/_core/List.mjs` is already the
//! generated module — so it gains `.foreign.mjs`, which reads as what it is
//! and can never collide: a generated module's file name is its module name
//! with `.` turned into `/`, and every segment of a module name is an upper
//! identifier, so no generated file has two dots in its base name.
//!
//! **The four checks of boundary.md §4 run before a byte is written**, and
//! all four are things Elm does not do. Check 1 (the two-shape type rule)
//! is here because it reads the `Bir` annotation; checks 2 and 3 are
//! `js/Sibling.zig`'s, because they read JavaScript. Check 4 — the sibling
//! export's arity — is split: `Sibling.zig` counts what is written and
//! `checkArity` below compares it against evidence count + declared arity,
//! because only the `Bir` and the dispatch table know the second number.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const diagnostic = @import("diagnostic");
const Bir = @import("../bir/Bir.zig");
const Edges = @import("../check/Edges.zig");
const Graph = @import("../resolve/Graph.zig");
const InternPool = @import("../InternPool.zig");
const Session = @import("../Session.zig");
const SourceStore = @import("../SourceStore.zig");
const fs_read = @import("../fs_read.zig");
const Lower = @import("Lower.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Convention = @import("../check/Convention.zig");
const JsIr = @import("JsIr.zig");
const Opt = @import("Opt.zig");
const Print = @import("Print.zig");
const Rename = @import("Rename.zig");
const Arena = @import("../Arena.zig");
const Profile = @import("../Profile.zig");
const Reach = @import("Reach.zig");
const Sibling = @import("Sibling.zig");
const Manifest = @import("Manifest.zig");
const OutputRecord = @import("OutputRecord.zig");
const prelude = @import("../bir/prelude.zig");
const beni_markup = @import("beni_markup");
const Interface = @import("../resolve/Interface.zig");

const Emit = @This();

/// A diagnostic this phase produces, before rendering: a file, a token and
/// the message. Same shape as `Graph.Item` and for the same reason — the
/// session turns a token into a span and nothing else here needs positions.
pub const Item = struct {
    code: diagnostic.Code,
    file: SourceStore.Index,
    token: u32,
    /// Owned by the caller's allocator.
    message: []const u8,
    /// Where to report INSTEAD of `file`'s token, for a fault whose text is
    /// not in a beni source file: a sibling `.js`, a platform's
    /// `beni.json`, or a beni file this names without pointing inside it.
    /// Scratch-owned, so it lives as long as the arena the caller passed to
    /// `run`, which outlives the render. `file` and `token` are ignored
    /// when this is set.
    at: ?Session.At = null,
};

/// What the platform chain tells the emitter (boundary.md §5.2, §9.1): each
/// output key taken from the first package of the chain that declares it.
pub const Platform = struct {
    /// Module-qualified name of the opaque `Program` type `main` must have.
    /// Null for a chain that declares none, which only a library builds for.
    program: ?[]const u8 = null,
    /// The runtime file, relative to `runtime_root`, whose `run` export is
    /// handed `main`'s value. Null as `program` is.
    runtime: ?[]const u8 = null,
    /// The root of the package that declares `runtime`, and the directory of
    /// the output tree its files go to.
    runtime_root: []const u8 = "",
    runtime_dir: []const u8 = platform_dir,
    /// The entry file's name in the output tree (`boundary.md` §5.2's
    /// `"entry"`), already defaulted to `default_entry_file` by
    /// `platform.load`. Checked by `checkEntryFileName` before anything
    /// is built: it is data a platform author writes, and §2's rule 1 has
    /// to hold for a declared name exactly as it does for the default.
    entry: []const u8 = default_entry_file,
    /// The root of the package whose manifest declared `entry`, or the top
    /// platform's when none did: where a fault in the name is reported.
    entry_root: []const u8 = "",
    /// The selected (top) platform package's root, as paths in the
    /// `SourceStore` spell it.
    root: []const u8,
    /// Per package of the chain, the output directory of its modules,
    /// siblings and runtime (`platform.Layer.out_dir`).
    layer_dirs: []const []const u8 = &.{platform_dir},
    /// Per file, the chain index of a platform file's package
    /// (`Session.file_layers`); empty when every platform file is the top's.
    file_layers: []const u8 = &.{},
    /// The selected platform's name, for messages.
    name: []const u8 = "",
    /// The chain's `"markup".lowering` (`boundary.md` §9.2) and the root of
    /// the package that names it; null when no package names one.
    lowering: ?[]const u8 = null,
    lowering_root: []const u8 = "",
    /// The chain's `"markup".runtime`, relative to `lowering_root` — the
    /// same package's, `platform.resolveChain` sees to that — and the
    /// output directory of that package (`boundary.md` §9.2).
    markup_runtime: ?[]const u8 = null,
    markup_runtime_dir: []const u8 = platform_dir,
};

/// The markup lowerings compiled into this binary (`boundary.md` §9.5),
/// sorted by name: the registry `build.zig` generates from every platform's
/// Zig module.
pub const lowerings: []const beni_markup.Lowering = @import("markup_lowerings").all;

/// The lowering this binary has under `name`, or null.
pub fn findLowering(name: []const u8) ?*const beni_markup.Lowering {
    for (lowerings) |*l| {
        if (std.mem.eql(u8, l.name, name)) return l;
    }
    return null;
}

/// The entry file a platform gets when its manifest does not name one
/// (`backend.md` §2, rule 1; `boundary.md` §5.2).
///
/// The leading `_` is load-bearing and not a style: a module path segment
/// must be an upper identifier (`SourceStore.isUpperIdent`), so no module
/// can ever be written to a file whose name starts with `_`. It used to be
/// `main.mjs`, which the module `Main` folds onto exactly.
pub const default_entry_file = "_main.mjs";

/// Output directory of the `core` package. Reserved, and `_`-prefixed for
/// `default_entry_file`'s reason: a user module `Core.List` is legal and
/// lands on `Core/List.mjs`.
pub const core_dir = "_core/";
/// The build's one derived-comparison engine. A `_` name inside
/// `_core/`, which no module file can take (§2, rule 1).
pub const derived_runtime_path = core_dir ++ "_derived.mjs";
const derived_runtime_source = @embedFile("derived_runtime.mjs");
const derived_runtime_compact = @embedFile("derived_runtime.min.mjs");

/// Output directory of the platform package, its siblings and its runtime.
/// Reserved for `core_dir`'s reason: `Platform.Node` is a legal module name.
pub const platform_dir = "_platform/";

/// A file the build must copy out verbatim: a sibling `.js`, or a
/// platform's runtime. Embedded copies come from the binary; anything else
/// is read from disk.
pub const Asset = struct {
    /// Path as the `SourceStore` spells it (`core/Basics.js`).
    path: []const u8,
    bytes: []const u8,
};

pub const Options = struct {
    out_dir: []const u8,
    platform: Platform,
    /// Files embedded in the compiler binary, by store path.
    embedded: []const Asset,
    /// `--library` (§2): no `main` is required and no entry file is
    /// written, and §9's root set is every name the root package's modules
    /// export rather than `main` alone. It is not a second output mode — a
    /// library build emits the same `.mjs` per module as any other — and it
    /// never changes WHETHER elimination runs, only what it starts from.
    library: bool = false,
    /// `--release` (§2, §9's *The release optimiser*): local dead-binding
    /// elimination, short names, compact printing and joined `const` runs,
    /// all four between `Lower.lower` and `Print.print`. **Development
    /// output does not move by one byte**, which is what makes "a golden
    /// moved" a finding rather than a blessing for the whole slice.
    release: bool = false,
    /// `--allow-debug`, the hidden test-only flag (`src/Cli.zig`): turn off
    /// §9's refusal of a `--release` build that reaches `core/Debug`, and
    /// nothing else. It changes no emitted byte in either mode; it exists so
    /// that the corpus's `--release` second pass can keep running the
    /// fixtures whose instrument is `Debug.log`.
    allow_debug: bool = false,
    // No `source_maps`: the VLQ encoder is not written (§11), so
    // `--source-maps` is refused in `Cli.parseBuild` and never reaches here.
    // Positions ride in the IR either way (§9.6).
};

pub const Result = struct {
    /// Owned; messages are gpa-owned.
    diagnostics: []const Item,
    /// Files written, for the profile counter and the summary line.
    files_written: u32,
    bytes_written: u64,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        for (r.diagnostics) |d| gpa.free(d.message);
        gpa.free(r.diagnostics);
        r.* = undefined;
    }
};

pub const Error = error{
    /// A file could not be written. `io_failure` says which.
    OutputPath,
    /// `--out`'s record exists and could not be read. `io_failure` says
    /// why.
    OutputRecordUnreadable,
} || Allocator.Error;

/// Check the platform contract and emit. `scratch` is an arena the caller
/// resets afterwards; nothing here frees individually.
pub fn run(
    gpa: Allocator,
    scratch: Allocator,
    session: *Session,
    options: Options,
    io_failure: *?Session.IoFailure,
) Error!Result {
    var e: Emitter = .{
        .gpa = gpa,
        .scratch = scratch,
        .session = session,
        .options = options,
        .io_failure = io_failure,
    };
    errdefer for (e.diagnostics.items) |d| gpa.free(d.message);
    defer {
        for (e.owned.items) |text| gpa.free(text);
        e.owned.deinit(gpa);
    }

    // §2's rule 1, on the one part of the output shape a platform declares
    // (`boundary.md` §5.2). First, and before the entry-point search: a
    // platform whose manifest names an impossible entry file is broken
    // whatever the program does, and `--library` — which writes no entry
    // file at all — must not be the way to find out it is fine.
    try e.checkEntryFileName();
    try e.checkLowering();
    try e.checkForeignShapes();
    try e.checkSiblings();
    try e.checkMarkupRuntime();
    // The checker checks a schema's endpoint types and records the resolved
    // plan, but its parse and print runners are not generated yet.
    // Refuse here, before entry discovery and before a pending output tree
    // exists, so a schema can never build while silently omitting them.
    if (try e.refuseSchemas()) return e.nothingWritten(gpa);
    // A library has no entry point and is not asked for one (§2): the
    // search is off, so `missing_main` does not fire and a `main` that
    // happens to be there is not type-checked against the platform's
    // `Program`. It is still EXPORTED and still a root, because §5's export
    // list has the entry declaration in it and §9 roots a library at its
    // export list — `Reach.collectRoots` says why at length.
    const entry = if (options.library) null else try e.findEntry();
    if (e.diagnostics.items.len != 0 or (entry == null and !options.library)) return e.nothingWritten(gpa);

    // §9's reachability walk, between `findEntry` and `emitModules` and
    // BEFORE lowering: an unreachable declaration is then never lowered at
    // all, so the pass pays for itself in emit time rather than costing
    // anything.
    var pool: Emitter.Workers = try .init(gpa, session.io, e.workerCount());
    defer pool.deinit();
    e.pool = &pool;
    try e.eliminate(entry);

    // `boundary.md` §9.2: a markup primitive that survives needs the markup
    // runtime of a lowering, and a chain that names none has nothing to
    // bind it to.
    try e.refuseMarkupWithoutLowering();
    if (e.diagnostics.items.len != 0) return e.nothingWritten(gpa);

    // §9's *The release optimiser*: a `--release` build that still reaches
    // `Debug` is refused (the owner's decision, 2026-09-19). Here and not
    // earlier, because reachability is what "this build uses it" means; here
    // and not later, because nothing may be lowered or written.
    if (options.release and !options.allow_debug) {
        try e.refuseDebug();
        if (e.diagnostics.items.len != 0) return e.nothingWritten(gpa);
    }

    // Everything is produced into `pending` first and written afterwards.
    // A diagnostic can still appear here — `?` is not compiled yet
    // (backend.md §1) and says so — and a build that wrote half its modules
    // before finding out would leave an `out/` that looks fresh and is not.
    // Nothing is emitted until the whole project is known to emit.
    try e.emitModules(entry);
    try e.copyAssets();
    if (entry) |at| try e.emitEntry(at);
    // §2's rule 2, with everything produced and nothing written yet.
    try e.checkOutputPaths();
    if (e.diagnostics.items.len != 0) return e.nothingWritten(gpa);
    // A symbolic link where the build would write is somebody else's, and
    // writing its path would write wherever it points.
    try e.refuseLinks();
    if (e.diagnostics.items.len != 0) return e.nothingWritten(gpa);
    // §2's record, read before the first byte is written: a
    // `_manifest.txt` that is not beni's is somebody's file.
    const previous = try e.readRecord();
    if (e.diagnostics.items.len != 0) return e.nothingWritten(gpa);

    const write_token = session.profile.begin();
    try e.flush(previous);
    session.profile.end(0, write_token, .write, Profile.Event.no_file, 0);
    return .{
        .diagnostics = try e.diagnostics.toOwnedSlice(gpa),
        .files_written = e.files_written,
        .bytes_written = e.bytes_written,
    };
}

/// `boundary.md` §4's four checks with nothing emitted: what
/// `beni check --platform=<name>` runs after the check phases
/// (`frontend.md` §1).
///
/// It is the front half of `run` and nothing else — no entry-point search,
/// no elimination, no lowering, no output directory. The entry point is half
/// of a BUILD pair (§5.3) and `check` is handed paths; the four checks are
/// not, because a `foreign_arity_mismatch` is a defect of the module and its
/// sibling wherever it is found, and it is exactly what a pre-commit check
/// exists to catch. `options.out_dir` is unused here and nothing is written.
///
/// Diagnostics are owned by the caller, messages included, like `run`'s.
pub fn checkContract(gpa: Allocator, scratch: Allocator, session: *Session, options: Options) Allocator.Error![]const Item {
    var io_failure: ?Session.IoFailure = null;
    var e: Emitter = .{
        .gpa = gpa,
        .scratch = scratch,
        .session = session,
        .options = options,
        .io_failure = &io_failure,
    };
    errdefer for (e.diagnostics.items) |d| gpa.free(d.message);
    // A broken platform is broken for `check` too, and this is the check a
    // platform author runs before committing (`frontend.md` §1).
    try e.checkEntryFileName();
    try e.checkLowering();
    try e.checkForeignShapes();
    try e.checkSiblings();
    try e.checkMarkupRuntime();
    return e.diagnostics.toOwnedSlice(gpa);
}

const Emitter = struct {
    gpa: Allocator,
    scratch: Allocator,
    session: *Session,
    options: Options,
    io_failure: *?Session.IoFailure,
    diagnostics: std.ArrayList(Item) = .empty,
    /// §9's answer: which declarations and derived rows this build ships.
    /// Scratch-owned, filled by `eliminate` before the first module is
    /// lowered.
    live: Reach.Result = .empty,
    /// §9 item 2's whole-program namespace: one table for the BUILD, so that
    /// an `import` specifier in one file and the `export` in another are
    /// given the same short name. Empty and unused in a dev build.
    globals: Rename.Globals = .{},
    /// What the build produced, path and bytes, before any of it reaches
    /// the disk. Scratch-owned.
    pending: std.ArrayList(Output) = .empty,
    /// Whether a module written imports the markup runtime, which the
    /// build then copies (`backend.md` §15.1).
    uses_markup_runtime: bool = false,
    /// The program start data every module's markup lowering contributed
    /// (`boundary.md` §9.4.5), in module order. Scratch-owned.
    start: std.ArrayList(Lower.StartPair) = .empty,
    /// The printed modules in `pending`, gpa-owned: they are handed over
    /// rather than copied, and freed when the phase ends.
    owned: std.ArrayList([]u8) = .empty,
    /// The threads of every parallel step from reachability on, made by
    /// `run` before the first of them.
    pool: *Workers = undefined,
    files_written: u32 = 0,
    bytes_written: u64 = 0,

    /// One file the build will write. `origin` is the SOURCE file the
    /// output was produced for — a module's `.beni`, a sibling's or the
    /// runtime's `.js`, or, for the entry file that no source declares, the
    /// platform's manifest. It exists for `checkOutputPaths`: a collision
    /// is a fault of two inputs and naming only the output paths would
    /// leave the reader to work out which files to rename.
    const Output = struct { path: []const u8, bytes: []const u8, origin: []const u8 };

    fn nothingWritten(e: *Emitter, gpa: Allocator) Allocator.Error!Result {
        return .{
            .diagnostics = try e.diagnostics.toOwnedSlice(gpa),
            .files_written = 0,
            .bytes_written = 0,
        };
    }

    /// A `foreign` value's name and the token that declared it, so a
    /// mismatch points at the declaration and not at the module.
    const Declared = struct {
        name: []const u8,
        token: u32,
        /// Check 4's right-hand side: the hidden leading parameters of
        /// `static-dispatch-spike.md` §8.1, one per entry of this
        /// declaration's evidence list.
        evidence: u32,
        /// The parameters the annotation lists, or `null` when there is no
        /// annotation to read — the parser has already reported that, and a
        /// second diagnostic about the sibling would be noise.
        params: ?u32,
        /// Whether the annotation is a function type at all. A `foreign`
        /// that is not one binds to a VALUE, so `() => …` is wrong for it
        /// even though both sides count zero parameters.
        is_function: bool,

        /// Whether the export has to be written as a function: a function
        /// type, or a `where` clause, which gives even a non-function one
        /// leading parameters.
        fn wantsFunction(d: Declared) bool {
            return d.is_function or d.evidence != 0;
        }
    };

    fn graph(e: *Emitter) *const Graph {
        return &e.session.graph;
    }

    fn bir(e: *Emitter, m: Graph.Index) *const Bir {
        return e.session.artifacts.bir(e.graph().moduleFile(m));
    }

    /// `boundary.md` §9.2: a `"markup".lowering` names a lowering compiled
    /// into this binary, checked when the platform is loaded — by `check
    /// --platform` as by `build` — against the manifest that names it.
    fn checkLowering(e: *Emitter) !void {
        const name = e.options.platform.lowering orelse return;
        if (findLowering(name) != null) return;
        var known: std.ArrayList(u8) = .empty;
        for (lowerings, 0..) |l, i| {
            if (i != 0) try known.appendSlice(e.scratch, ", ");
            try known.print(e.scratch, "`{s}`", .{l.name});
        }
        try e.reportInFile(
            .unknown_markup_lowering,
            .{ .path = try std.fmt.allocPrint(e.scratch, "{s}/{s}", .{ e.options.platform.lowering_root, Manifest.file_name }) },
            \\This platform names the markup lowering `{s}`, which this beni does not have.
            \\
            \\A markup lowering is Zig compiled into the compiler (`docs/design/boundary.md`
            \\§9.5), and this build of beni has {s}.
        ,
            .{ name, if (lowerings.len == 0) "none" else known.items },
        );
    }

    /// A markup primitive or a markup root that survives elimination, in a
    /// build whose chain names no lowering, is `unknown_markup_lowering`
    /// against the selected platform's manifest (`boundary.md` §9.2): the
    /// primitive's implementation is the lowering's runtime, the root's
    /// compilation is the lowering's, and there is none.
    fn refuseMarkupWithoutLowering(e: *Emitter) !void {
        if (e.options.platform.lowering != null) return;
        for (0..e.graph().count()) |i| {
            const m: Graph.Index = @enumFromInt(@as(u32, @intCast(i)));
            const b = e.bir(m);
            for (b.decls, 0..) |d, index| {
                if (!e.live.decl(m, index)) continue;
                if (d.kind.isValue() and writesMarkup(b, d)) return e.reportInFile(
                    .unknown_markup_lowering,
                    .{ .path = try std.fmt.allocPrint(e.scratch, "{s}/{s}", .{ e.options.platform.root, Manifest.file_name }) },
                    \\This build writes markup in `{s}.{s}`, but the platform `{s}` names no markup
                    \\lowering to compile it.
                    \\
                    \\Markup compiles through the build's markup lowering (`docs/design/boundary.md`
                    \\§9.4), which a platform names in its manifest's `"markup"` `"lowering"`, or
                    \\inherits from a platform it depends on.
                ,
                    .{ e.session.store.moduleName(e.graph().moduleFile(m)), e.session.interner.slice(b.symbol(d.name)), e.options.platform.name },
                );
                if (d.kind != .vocab_markup) continue;
                return e.reportInFile(
                    .unknown_markup_lowering,
                    .{ .path = try std.fmt.allocPrint(e.scratch, "{s}/{s}", .{ e.options.platform.root, Manifest.file_name }) },
                    \\This build uses the markup primitive `{s}.{s}`, but the platform `{s}` names no
                    \\markup lowering to implement it.
                    \\
                    \\A markup primitive is implemented by the runtime of the build's markup lowering
                    \\(`docs/design/boundary.md` §9.3), which a platform names in its manifest's
                    \\`"markup"` `"lowering"`, or inherits from a platform it depends on.
                ,
                    .{ e.session.store.moduleName(e.graph().moduleFile(m)), e.session.interner.slice(b.symbol(d.name)), e.options.platform.name },
                );
            }
        }
    }

    fn writesMarkup(b: *const Bir, d: Bir.Decl) bool {
        const tags = b.insts.items(.tag);
        for (tags[d.inst_start.int()..d.inst_end.int()]) |tag| {
            if (tag == .markup) return true;
        }
        return false;
    }

    fn refuseSchemas(e: *Emitter) !bool {
        var found = false;
        for (0..e.graph().count()) |i| {
            const module: Graph.Index = @enumFromInt(@as(u32, @intCast(i)));
            const file = e.graph().moduleFile(module);
            for (e.bir(module).decls) |decl| {
                if (decl.kind != .schema) continue;
                found = true;
                try e.report(
                    .not_implemented,
                    file,
                    decl.name_token,
                    "This schema is checked, but its parse and print are not generated yet.",
                    .{},
                );
            }
        }
        return found;
    }

    /// The 1-based line and column of `token` in `file`.
    ///
    /// Nothing else in this phase needs positions — the session turns the
    /// reported token into a span. A message that has to name a SECOND
    /// location is the exception, the way `duplicate_declaration` names the
    /// first of two by line; two `main`s are in different modules, so the
    /// path is named with it.
    fn tokenPosition(e: *Emitter, file: SourceStore.Index, token: u32) diagnostic.Position {
        const line_starts = e.session.store.lineStarts(file);
        if (line_starts.len == 0) return .{ .line = 1, .col = 1 };
        const tokens = e.session.artifacts.spans(file);
        if (token >= tokens.len()) return .{ .line = 1, .col = 1 };
        return diagnostic.position(line_starts, tokens.starts[token]);
    }

    fn report(e: *Emitter, code: diagnostic.Code, file: SourceStore.Index, token: u32, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(e.gpa, fmt, args);
        errdefer e.gpa.free(message);
        try e.diagnostics.append(e.gpa, .{ .code = code, .file = file, .token = token, .message = message });
    }

    /// Report against a PATH rather than a source file. The one caller is
    /// the platform's missing runtime: the `"runtime"` key of a manifest
    /// names a file that is not on disk, which is a fault of the platform
    /// package and of no beni module. It used to be reported on file 0,
    /// token 0 — the first token of whatever source the run happened to
    /// enumerate first, which is the user's own — and a caret under an
    /// `import` the reader wrote is worse than no caret at all. Every other
    /// manifest failure is an exit-2 line naming the path
    /// (`src/platform.zig`), and this is the same honesty inside a
    /// diagnostic.
    fn reportInFile(e: *Emitter, code: diagnostic.Code, at: Session.At, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(e.gpa, fmt, args);
        errdefer e.gpa.free(message);
        try e.diagnostics.append(e.gpa, .{
            .code = code,
            .file = @enumFromInt(0),
            .token = 0,
            .message = message,
            .at = at,
        });
    }

    /// `boundary.md` §4's *a diagnostic points at the file whose text is
    /// wrong*: an `At` covering `length` bytes of `source` from `offset`,
    /// which is what `js/Sibling.zig` hands back for every export,
    /// reference and specifier it reads.
    fn inSibling(path: []const u8, source: []const u8, offset: u32, length: u32) Session.At {
        return .{
            .path = path,
            .start = positionIn(source, offset),
            .end = positionIn(source, offset + length),
            .source = source,
        };
    }

    /// 1-based line and byte column of `offset` in `text`.
    ///
    /// A sibling `.js` has no token list and no line table — it is not beni
    /// source and nothing but a diagnostic ever asks it for a position — so
    /// this counts newlines rather than building one. It runs once per
    /// diagnostic, on the error path, over a file `max_asset_bytes` bounds.
    fn positionIn(text: []const u8, offset: u32) diagnostic.Position {
        const end = @min(offset, text.len);
        var line: u32 = 1;
        var line_start: usize = 0;
        var at: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text[0..end], at, '\n')) |nl| {
            line += 1;
            line_start = nl + 1;
            at = nl + 1;
        }
        return .{ .line = line, .col = @intCast(end - line_start + 1) };
    }

    // ---- boundary.md §4, check 1: the two-shape type rule -----------------

    /// Either (a) a function over admitted types, or (b) an effect value.
    ///
    /// There are no effect types yet (`Task`, `Cmd` and `Sub` are still to
    /// come), so shape (b) is approximated by its structural property: a
    /// CONCRETE type, with no type variable anywhere in it. That admits
    /// `foreign pi : Float` and `foreign type Program`'s values, and
    /// refuses `foreign xs : List a` and `foreign anything : a`, which are
    /// the shapes that would let a `foreign` invent a value of a type the
    /// caller chose.
    ///
    /// **This is weaker than §4 as written, and §4 as written is wrong.**
    /// §4 says "all 65 of core's current foreign values are shape (a)";
    /// `Basics.e` and `Basics.pi` are not functions and never were, so the
    /// rule as stated rejects core. The rule the compiler can actually
    /// enforce is about the TYPE, and the dangerous case §4 names —
    /// `foreign now : Float` — is indistinguishable from `pi` by type
    /// alone. What the check buys is real but narrower than advertised: no
    /// `foreign` may be polymorphic in a way that lets it fabricate a value.
    fn checkForeignShapes(e: *Emitter) !void {
        for (0..e.graph().count()) |i| {
            const m: Graph.Index = @enumFromInt(i);
            const file = e.graph().moduleFile(m);
            const b = e.bir(m);
            for (b.decls) |d| {
                if (d.kind != .foreign_value) continue;
                const annotation = d.annotation.unwrap() orelse continue;
                if (b.instTag(annotation) == .type_fn) continue;
                const offender = try firstTypeVar(e.scratch, b, annotation) orelse continue;
                _ = offender;
                try e.report(
                    .foreign_bad_shape,
                    file,
                    d.name_token,
                    \\This `foreign` value is neither a function nor a concrete value.
                    \\
                    \\A `foreign` declaration binds to JavaScript, and the type is all the compiler
                    \\can check about it (`docs/design/boundary.md` §4). It must be a function, or a
                    \\value of a type with no variables in it. A polymorphic value like this one
                    \\claims to produce whatever the caller asks for, which nothing in JavaScript
                    \\can honour.
                ,
                    .{},
                );
            }
        }
    }

    // ---- boundary.md §4, checks 2, 3 and 4 --------------------------------

    fn checkSiblings(e: *Emitter) !void {
        for (0..e.graph().count()) |i| {
            const m: Graph.Index = @enumFromInt(i);
            const file = e.graph().moduleFile(m);
            const b = e.bir(m);
            const dispatch = e.dispatchOf(m);

            var declared: std.ArrayList(Declared) = .empty;
            for (b.decls, 0..) |d, index| {
                if (d.kind != .foreign_value) continue;
                // The calling convention every call of this `foreign` is
                // lowered with (`check/Convention.zig`, checker-v2.md §12.5),
                // so check 4 and the call sites cannot disagree: the arity is
                // the TYPE's, through any alias, and not the annotation's
                // spelling (`pub foreign p : Pred a where …` takes evidence
                // and one argument).
                const use = Convention.ofDecl(dispatch, b, @intCast(index));
                try declared.append(e.scratch, .{
                    .name = e.session.interner.slice(b.symbol(d.name)),
                    .token = d.name_token,
                    .evidence = use.evidence,
                    .params = if (d.annotation == .none) null else use.arity,
                    .is_function = use.arity != 0,
                });
            }
            if (declared.items.len == 0) continue;
            const first_token = declared.items[0].token;

            const source_path = e.session.store.path(file);
            const sibling_path = try e.siblingPath(source_path);
            const bytes = e.readAsset(sibling_path) orelse {
                try e.report(
                    .foreign_sibling_missing,
                    file,
                    first_token,
                    \\I cannot find `{s}`.
                    \\
                    \\A module with `foreign` declarations binds them to a sibling JavaScript file
                    \\of the same name, one export per foreign value
                    \\(`docs/design/boundary.md` §4). Write that file next to `{s}`.
                ,
                    .{ sibling_path, source_path },
                );
                continue;
            };

            const found = try Sibling.scan(e.scratch, bytes);
            try e.compareExports(file, sibling_path, bytes, declared.items, found.exports);
            // The next two faults are the `.js` file's own, so they are
            // reported IN it: path, line, column and an excerpt with the
            // caret under the specifier or the name (`boundary.md` §4, *a
            // diagnostic points at the file whose text is wrong*). They
            // used to land on this module's first `foreign` declaration,
            // which is an arbitrary line that has nothing to do with either.
            for (found.relative_imports) |specifier| {
                try e.reportInFile(
                    .not_implemented,
                    inSibling(sibling_path, bytes, specifier.offset, @intCast(specifier.text.len)),
                    \\This file imports {s}, and I cannot relocate that yet.
                    \\
                    \\A sibling file is RENAMED as it is copied into the output — `{s}` becomes
                    \\`<Module>{s}`, so that every emitted file is an ES module by extension
                    \\(`docs/design/backend.md` §2). A specifier that names a file would then point
                    \\at a name that no longer exists, and the build would succeed while the program
                    \\failed to load. Beni cannot rewrite them yet; for now, import a package
                    \\(`node:process`, a dependency) or inline the helper.
                ,
                    .{ specifier.text, std.fs.path.basename(sibling_path), foreign_extension },
                );
            }
            for (found.unbound) |reference| {
                try e.reportInFile(
                    .foreign_unbound_reference,
                    inSibling(sibling_path, bytes, reference.offset, @intCast(reference.text.len)),
                    \\This file uses `{s}`, which it never imports.
                    \\
                    \\A sibling file's references have to be covered by its own `import`
                    \\statements (`docs/design/boundary.md` §4, check 3). That is what keeps dead
                    \\code elimination declaration-granular: the compiler reads the imports to
                    \\learn the file's dependencies, and a name that comes from nowhere is an edge
                    \\it cannot see. Write `import {s} from "node:{s}";` — or whatever module
                    \\really provides it — at the top of this file.
                ,
                    .{ reference.text, reference.text, reference.text },
                );
            }
        }
    }

    /// Check 2, whose two arms point at DIFFERENT files, because they are
    /// two different mistakes (`boundary.md` §4).
    ///
    /// A declaration with no export is the beni file's promise gone
    /// unkept — the promise is written there, so the caret goes there and
    /// the message names the `.js`. An export nothing declares is the
    /// `.js` file's own surplus, so the caret goes THERE and the message
    /// names the module.
    fn compareExports(
        e: *Emitter,
        file: SourceStore.Index,
        sibling_path: []const u8,
        sibling_source: []const u8,
        declared: []const Declared,
        exported: []const Sibling.Export,
    ) !void {
        for (declared) |entry| {
            const name = entry.name;
            if (find(exported, name)) |found| {
                try e.checkArity(file, sibling_path, sibling_source, entry, found);
                continue;
            }
            try e.report(
                .foreign_export_mismatch,
                file,
                entry.token,
                \\`{s}` does not export `{s}`.
                \\
                \\A sibling JavaScript file exports exactly the `foreign` values its module
                \\declares — no more, no fewer (`docs/design/boundary.md` §4, check 2). Add
                \\`export const {s} = …;` to it, or delete the `foreign` declaration.
            ,
                .{ sibling_path, name, name },
            );
        }
        const module_path = e.session.store.path(file);
        for (exported) |entry| {
            const name = entry.name;
            if (containsDeclared(declared, name)) continue;
            try e.reportInFile(
                .foreign_export_mismatch,
                inSibling(sibling_path, sibling_source, entry.offset, @intCast(name.len)),
                \\This file exports `{s}`, and `{s}` declares no `foreign {s}`.
                \\
                \\A sibling JavaScript file exports exactly the `foreign` values its module
                \\declares — no more, no fewer (`docs/design/boundary.md` §4, check 2). One
                \\export per foreign value is one node in the dependency graph per foreign value,
                \\which is what keeps elimination declaration-granular; an extra export is a node
                \\nothing can reach. Declare `foreign {s} : …` in `{s}`, or stop exporting it here.
            ,
                .{ name, module_path, name, name, module_path },
            );
        }
    }

    /// Check 4: the export takes evidence count + declared arity
    /// parameters, and a `foreign` that is not a function is not written as
    /// one. A declaration with no annotation is skipped — the parser
    /// reported that already and the sibling is not the problem.
    ///
    /// **This one keeps the beni declaration as its region** (`boundary.md`
    /// §4, check 4), because the expected count is written there and the
    /// export is only where it was miscounted. The message names the `.js`
    /// with its LINE AND COLUMN, so the other half is one jump away.
    fn checkArity(
        e: *Emitter,
        file: SourceStore.Index,
        sibling_path: []const u8,
        sibling_source: []const u8,
        entry: Declared,
        found: Sibling.Export,
    ) !void {
        const arity = found.arity;
        const params = entry.params orelse return;
        const expected = entry.evidence + params;
        const at = positionIn(sibling_source, found.offset);
        const site = try std.fmt.allocPrint(e.scratch, "{s}:{d}:{d}", .{ sibling_path, at.line, at.col });
        // A `foreign` that is not a function binds to a VALUE, so any
        // function literal is wrong for it and the count never comes into
        // it — `() => …` and `(...xs) => …` are the same mistake.
        if (!entry.wantsFunction()) {
            if (arity == .opaque_value) return;
            try e.report(
                .foreign_arity_mismatch,
                file,
                entry.token,
                \\`{s}` writes `{s}` as a function, and `{s}` is not one.
                \\
                \\This declaration's type is a value, not a function, so the export is the
                \\value itself — `export const {s} = …;` and never `() => …`
                \\(`docs/design/boundary.md` §4, check 4). `core/Basics.js` writes `pi` as
                \\`Math.PI` for exactly this reason.
            ,
                .{ site, entry.name, entry.name, entry.name },
            );
            return;
        }
        switch (arity) {
            .function => |written| {
                if (written == expected) return;
                try e.report(
                    .foreign_arity_mismatch,
                    file,
                    entry.token,
                    \\`{s}` writes `{s}` with {d} parameter{s}, and `{s}` takes {d}.
                    \\
                    \\{s}
                ,
                    .{
                        site,
                        entry.name,
                        written,
                        plural(written),
                        entry.name,
                        expected,
                        try e.arityRule(entry),
                    },
                );
            },
            .opaque_value => {
                try e.report(
                    .foreign_arity_mismatch,
                    file,
                    entry.token,
                    \\`{s}` exports `{s}` as a value, and `{s}` takes {d} parameter{s}.
                    \\
                    \\{s}
                    \\
                    \\The parameter list has to be written AT the export, so that a reader can
                    \\count it against the declaration. `export const {s} = other;` does not say
                    \\how many parameters `other` has, and neither does re-exporting an import:
                    \\write `export const {s} = (…) => other(…);` instead.
                ,
                    .{
                        site,
                        entry.name,
                        entry.name,
                        expected,
                        plural(expected),
                        try e.arityRule(entry),
                        entry.name,
                        entry.name,
                    },
                );
            },
            .uncountable => {
                try e.report(
                    .foreign_arity_mismatch,
                    file,
                    entry.token,
                    \\`{s}` writes `{s}` with a rest parameter, so I cannot count its parameters.
                    \\
                    \\{s}
                    \\
                    \\A sibling is privileged code and its exports are checked by counting, so a
                    \\parameter list with no fixed length is refused rather than trusted
                    \\(`docs/design/boundary.md` §4, check 4). Write the {d} parameter{s} out.
                ,
                    .{ site, entry.name, try e.arityRule(entry), expected, plural(expected) },
                );
            },
        }
    }

    /// The paragraph that says where the expected count comes from. A
    /// declaration with a `where` clause has hidden leading parameters and
    /// nothing in its own text shows them, so the split is spelled out;
    /// one without needs only the rule.
    fn arityRule(e: *Emitter, entry: Declared) ![]const u8 {
        if (entry.evidence == 0) return
        \\A sibling export takes exactly the parameters its `foreign` declaration promises
        \\(`docs/design/boundary.md` §4, check 4). Every call the compiler emits is
        \\saturated (`docs/design/backend.md` §6), so a miscount is never a partial
        \\application: it is an argument that arrives nowhere.
        ;
        return std.fmt.allocPrint(e.scratch,
            \\`{s}`'s annotation carries a `where` clause, so its export takes the EVIDENCE
            \\parameters first and the declared ones after
            \\(`docs/design/static-dispatch-spike.md` §8.1): {d} for the `where` clause and
            \\{d} declared, {d} in all. `core/List.js` writes a 2-ary `eq` with one
            \\constraint as `(m0, xs, ys)` for exactly this reason.
        , .{ entry.name, entry.evidence, entry.params.?, entry.evidence + entry.params.? });
    }

    // ---- boundary.md §9.4.5: the markup runtime's exports ----------------

    /// The markup runtime's source path, when the chain names a lowering
    /// this binary has and a runtime for it.
    fn markupRuntimePath(e: *Emitter) !?[]const u8 {
        const name = e.options.platform.lowering orelse return null;
        if (findLowering(name) == null) return null;
        const rel = e.options.platform.markup_runtime orelse return null;
        return try std.fmt.allocPrint(e.scratch, "{s}/{s}", .{ e.options.platform.lowering_root, rel });
    }

    /// Whether the markup runtime is also the program runtime (§9.2): one
    /// file, copied once, whose exports include `run`.
    fn markupRuntimeIsProgramRuntime(e: *Emitter) bool {
        const p = e.options.platform;
        const markup = p.markup_runtime orelse return false;
        const program = p.runtime orelse return false;
        return std.mem.eql(u8, markup, program) and std.mem.eql(u8, p.lowering_root, p.runtime_root);
    }

    /// One export the markup runtime must have: a lowering's well-known
    /// one, a markup primitive of the vocabulary (with the declaration it
    /// answers to), or `run`.
    const Expected = struct {
        name: []const u8,
        arity: u32,
        primitive: ?struct { file: SourceStore.Index, token: u32, declared: Declared } = null,
    };

    /// `boundary.md` §9.4.5: the markup runtime is held to §4's checks 2, 3
    /// and 4 against the union of the lowering's declared exports, one per
    /// markup primitive of the vocabulary, and `run` when it is also the
    /// program runtime — as a sibling is against its module's `foreign`s.
    fn checkMarkupRuntime(e: *Emitter) !void {
        const path = try e.markupRuntimePath() orelse return;
        const lowering = findLowering(e.options.platform.lowering.?).?;
        var expected: std.ArrayList(Expected) = .empty;
        for (lowering.runtime) |r| try expected.append(e.scratch, .{ .name = r.name, .arity = r.arity });
        if (e.markupRuntimeIsProgramRuntime()) try expected.append(e.scratch, .{ .name = "run", .arity = 1 });
        if (e.graph().markup.vocabulary) |vocabulary| {
            const b = e.bir(vocabulary);
            const file = e.graph().moduleFile(vocabulary);
            const dispatch = e.dispatchOf(vocabulary);
            for (b.decls, 0..) |d, index| {
                if (d.kind != .vocab_markup) continue;
                const name = e.session.interner.slice(b.symbol(d.name));
                // A primitive named like one of the lowering's own exports
                // would be two exports of one name.
                var clash = false;
                for (lowering.runtime) |r| clash = clash or std.mem.eql(u8, r.name, name);
                if (clash) {
                    try e.report(
                        .duplicate_declaration,
                        file,
                        d.name_token,
                        \\The markup primitive `{s}` has the name of an export the markup lowering `{s}`
                        \\imports from its runtime.
                        \\
                        \\A markup primitive is the markup runtime's export of its name, beside the
                        \\lowering's own exports (`docs/design/boundary.md` §9.4.5), so the two would be
                        \\one export. Rename the primitive.
                    ,
                        .{ name, lowering.name },
                    );
                    continue;
                }
                const use = Convention.ofDecl(dispatch, b, @intCast(index));
                try expected.append(e.scratch, .{
                    .name = name,
                    .arity = use.evidence + use.arity,
                    .primitive = .{ .file = file, .token = d.name_token, .declared = .{
                        .name = name,
                        .token = d.name_token,
                        .evidence = use.evidence,
                        .params = if (d.annotation == .none) null else use.arity,
                        .is_function = use.arity != 0,
                    } },
                });
            }
        }

        const bytes = e.readAsset(path) orelse {
            try e.reportInFile(
                .foreign_sibling_missing,
                .{ .path = try std.fmt.allocPrint(e.scratch, "{s}/{s}", .{ e.options.platform.lowering_root, Manifest.file_name }) },
                \\I cannot find the markup runtime `{s}`.
                \\
                \\A platform that names a markup lowering names the JavaScript file its emitted
                \\code imports in its manifest's `"markup"` `"runtime"`
                \\(`docs/design/boundary.md` §9.2).
            ,
                .{path},
            );
            return;
        };
        const found = try Sibling.scan(e.scratch, bytes);
        for (expected.items) |want| {
            const got = find(found.exports, want.name) orelse {
                if (want.primitive) |p| {
                    try e.report(
                        .foreign_export_mismatch,
                        p.file,
                        p.token,
                        \\The markup runtime `{s}` does not export `{s}`.
                        \\
                        \\A markup primitive is implemented by the build's markup runtime, one export of
                        \\its name (`docs/design/boundary.md` §9.3, §9.4.5). Add
                        \\`export const {s} = …;` to it.
                    ,
                        .{ path, want.name, want.name },
                    );
                } else try e.reportInFile(
                    .foreign_export_mismatch,
                    .{ .path = path, .source = bytes },
                    \\This markup runtime does not export `{s}`, which the markup lowering `{s}` imports.
                    \\
                    \\A markup runtime exports exactly what its lowering declares, the vocabulary's
                    \\markup primitives and, when it is the program runtime too, `run`
                    \\(`docs/design/boundary.md` §9.4.5). Add `export const {s} = …;` taking {d}
                    \\parameter{s}.
                ,
                    .{ want.name, lowering.name, want.name, want.arity, plural(want.arity) },
                );
                continue;
            };
            if (want.primitive) |p| {
                try e.checkArity(p.file, path, bytes, p.declared, got);
                continue;
            }
            const written: ?u32 = switch (got.arity) {
                .function => |n| n,
                else => null,
            };
            if (written == want.arity) continue;
            try e.reportInFile(
                .foreign_arity_mismatch,
                inSibling(path, bytes, got.offset, @intCast(want.name.len)),
                \\`{s}` is written {s}, and the markup lowering `{s}` calls it with {d} argument{s}.
                \\
                \\Every call emitted code makes is saturated (`docs/design/backend.md` §6), so a
                \\miscounted export takes an argument that never arrives
                \\(`docs/design/boundary.md` §4, check 4; §9.4.5). Write its parameter list at the
                \\export: {d} parameter{s}.
            ,
                .{
                    want.name,
                    if (written) |n| try std.fmt.allocPrint(e.scratch, "with {d} parameter{s}", .{ n, plural(n) }) else "so that its parameters cannot be counted",
                    lowering.name,
                    want.arity,
                    plural(want.arity),
                    want.arity,
                    plural(want.arity),
                },
            );
        }
        for (found.exports) |got| {
            var known = false;
            for (expected.items) |want| known = known or std.mem.eql(u8, want.name, got.name);
            if (known) continue;
            try e.reportInFile(
                .foreign_export_mismatch,
                inSibling(path, bytes, got.offset, @intCast(got.name.len)),
                \\This markup runtime exports `{s}`, which neither the markup lowering `{s}` nor the
                \\vocabulary declares.
                \\
                \\A markup runtime exports exactly the lowering's declared exports and one per
                \\markup primitive (`docs/design/boundary.md` §9.4.5), so that every export is a
                \\node elimination can see. Stop exporting it, or declare the primitive.
            ,
                .{ got.name, lowering.name },
            );
        }
        for (found.unbound) |reference| {
            try e.reportInFile(
                .foreign_unbound_reference,
                inSibling(path, bytes, reference.offset, @intCast(reference.text.len)),
                \\This file uses `{s}`, which it never imports.
                \\
                \\A markup runtime's references are covered by its own `import` statements, as a
                \\sibling's are (`docs/design/boundary.md` §4, check 3; §9.4.5).
            ,
                .{reference.text},
            );
        }
        for (found.relative_imports) |specifier| {
            try e.reportInFile(
                .not_implemented,
                inSibling(path, bytes, specifier.offset, @intCast(specifier.text.len)),
                \\This file imports {s}, and I cannot relocate that yet.
                \\
                \\A markup runtime is renamed as it is copied into the output, as a sibling is
                \\(`docs/design/backend.md` §2), so a specifier that names a file would name
                \\nothing. Import a package, or inline the helper.
            ,
                .{specifier.text},
            );
        }
    }

    fn dispatchOf(e: *Emitter, m: Graph.Index) *const Dispatch {
        if (m.int() >= e.session.checked.dispatch.len) return &Dispatch.empty;
        return &e.session.checked.dispatch[m.int()];
    }

    // ---- boundary.md §5: `main`, resolved per platform --------------------

    /// The module that declares `main`, and the declaration's index.
    ///
    /// The entry point is found rather than named on the command line: a
    /// build is a pair of entry point and platform (§5.3), and in a project
    /// with one `main` the entry point is not information the user should
    /// have to repeat. A project with two would be two builds, which is
    /// exactly §5.3's full-stack case, and the build says so rather than guessing.
    fn findEntry(e: *Emitter) !?Entry {
        var found: ?Entry = null;
        for (0..e.graph().count()) |i| {
            const m: Graph.Index = @enumFromInt(i);
            const file = e.graph().moduleFile(m);
            if (e.session.store.package(file) != .app) continue;
            const b = e.bir(m);
            for (b.decls, 0..) |d, index| {
                if (d.kind != .value) continue;
                if (b.symbol(d.name) != InternPool.WellKnown.main.symbol()) continue;
                if (found) |previous| {
                    // Which of the two is "the first" is the lower MODULE
                    // INDEX, which comes from the sorted path and never
                    // from argument or completion order (CLAUDE.md rule 5),
                    // so the message is the same however the build was
                    // invoked.
                    const first_file = e.graph().moduleFile(previous.module);
                    const first_token = e.bir(previous.module).decl(previous.decl).name_token;
                    const first = e.tokenPosition(first_file, first_token);
                    const second = e.tokenPosition(file, d.name_token);
                    try e.report(
                        .duplicate_main,
                        file,
                        d.name_token,
                        \\This project has more than one `main`.
                        \\
                        \\`{s}` declares one at `{s}:{d}:{d}` and `{s}` another at
                        \\`{s}:{d}:{d}`. A build is a pair of ONE entry point and ONE platform
                        \\(`docs/design/boundary.md` §5.3), so two entry points are two builds: give
                        \\each its own, or pass `--library` if this project is not a program.
                    ,
                        .{
                            e.session.store.moduleName(first_file),
                            e.session.store.path(first_file),
                            first.line,
                            first.col,
                            e.session.store.moduleName(file),
                            e.session.store.path(file),
                            second.line,
                            second.col,
                        },
                    );
                    return null;
                }
                found = .{ .module = m, .decl = @enumFromInt(@as(u32, @intCast(index))) };
            }
        }
        const entry = found orelse {
            // **An absence has no token** (§5). It used to be reported on
            // file 0, token 0 — whatever the run enumerated first, which in
            // the corpus golden was an `import` and read as if the import
            // were the mistake. There is no honest thing to underline, so
            // nothing is: the diagnostic is reported against a FILE at 1:1
            // with no excerpt, and the message says which file and why.
            // Which file is `rule 5` deterministic — the first app module
            // by module index, which comes from the sorted path and never
            // from argument or completion order.
            const app = e.firstAppModule();
            const path = if (app) |a| e.session.store.path(e.graph().moduleFile(a)) else "";
            try e.reportInFile(
                .missing_main,
                .{ .path = path, .source = null },
                \\I cannot find `main` in this project.
                \\
                \\A program's entry point is a declaration called `main` whose type is the
                \\`Program` the platform owns — here `{s}` (`docs/design/boundary.md` §5). Add
                \\one to any module of this project.
                \\
                \\There is nothing to underline, because the mistake is an absence: this is
                \\reported against `{s}`, {s}.
            ,
                .{
                    try e.writtenProgramName(null),
                    path,
                    try e.entryFileRule(),
                },
            );
            return null;
        };
        try e.checkMainType(entry);
        return entry;
    }

    const Entry = struct { module: Graph.Index, decl: Bir.DeclIndex };

    /// `main`'s type is a platform fact (§5), so it is checked against the
    /// platform's declared `Program` rather than against a hardcoded name.
    ///
    /// The check reads the ANNOTATION and requires there to be one. That is
    /// a real rule and worth stating: `main` is where the program meets the
    /// platform, and an inferred type there would let a build succeed with
    /// `main` bound to something the runtime cannot run. With the annotation
    /// present the checker has already proved the body matches it, so
    /// comparing the annotation is a complete check and costs no inference.
    fn checkMainType(e: *Emitter, entry: Entry) !void {
        const file = e.graph().moduleFile(entry.module);
        const b = e.bir(entry.module);
        const d = b.decl(entry.decl);
        const annotation = d.annotation.unwrap() orelse return e.report(
            .main_not_program,
            file,
            d.name_token,
            \\`main` needs a type annotation.
            \\
            \\It is where your program meets the platform, and the platform decides what type
            \\it has (`docs/design/boundary.md` §5). Write:
            \\
            \\    main : {s}
            \\
            \\above the definition.
        ,
            .{try e.writtenProgramName(entry.module)},
        );
        const actual = e.typeName(b, annotation);
        if (actual) |t| {
            if (std.mem.eql(u8, t.module, platformModule(e.options.platform.program orelse "")) and
                std.mem.eql(u8, t.name, shortName(e.options.platform.program orelse ""))) return;
        }
        try e.report(
            .main_not_program,
            file,
            d.name_token,
            \\`main` must be a `{s}`.
            \\
            \\This one is annotated `{s}`. The platform owns the type of the entry point and
            \\hands out the only values of it (`docs/design/boundary.md` §5); a `Program` is
            \\what you get back from one of its functions.
        ,
            .{
                try e.writtenProgramName(entry.module),
                if (actual) |t| e.writtenTypeName(entry.module, t) else "something else",
            },
        );
    }

    /// A resolved type reference, split into the two halves a message needs.
    const TypeRef = struct { module: []const u8, name: []const u8 };

    /// The type a reference names, or null for anything else (a function, a
    /// record, an application).
    fn typeName(e: *Emitter, b: *const Bir, inst: Bir.Inst.Index) ?TypeRef {
        const d = b.instData(inst);
        switch (b.instTag(inst)) {
            .ext_type => {
                const m: Graph.Index = @enumFromInt(d.lhs);
                if (m.int() >= e.session.resolution.interfaces.len) return null;
                const iface = &e.session.resolution.interfaces[m.int()];
                if (d.rhs >= iface.types.len) return null;
                return .{
                    .module = e.session.interner.slice(e.graph().moduleName(m)),
                    .name = e.session.interner.slice(iface.symbols[@intFromEnum(iface.types[d.rhs].name)]),
                };
            },
            .type_top => {
                if (d.lhs >= b.decls.len) return null;
                return .{
                    .module = e.session.store.moduleName(e.graph().moduleFile(e.currentModuleOf(b))),
                    .name = e.session.interner.slice(b.symbol(b.decls[d.lhs].name)),
                };
            },
            else => return null,
        }
    }

    /// **A type is printed the way the reader could write it** where the
    /// diagnostic points (`checker.md` §8.2's rule, applied to a message
    /// the checker does not raise).
    ///
    /// `Render.zig` prints every type name bare because it prints from a
    /// type store, where a name has no module attached; this message reads
    /// a BIR annotation instead, and used to print the resolver's internal
    /// `Module.Name` — so a user who wrote `main : Int` was told about
    /// `Basics.Int`, which is a name no beni source may contain. The rule
    /// here is the conservative one: bare when `scope` can read it bare —
    /// the prelude (`language.md` Appendix A), the module's own types, and
    /// a name an import exposes — and `Alias.Name` otherwise, which is
    /// always writable given the import that is already there.
    fn writtenTypeName(e: *Emitter, scope: Graph.Index, t: TypeRef) []const u8 {
        if (e.readsBare(scope, t)) return t.name;
        const b = e.bir(scope);
        for (b.imports) |imp| {
            if (!std.mem.eql(u8, e.session.interner.slice(b.symbol(imp.module)), t.module)) continue;
            const alias = e.session.interner.slice(b.symbol(imp.alias));
            return std.fmt.allocPrint(e.scratch, "{s}.{s}", .{ alias, t.name }) catch t.name;
        }
        return std.fmt.allocPrint(e.scratch, "{s}.{s}", .{ t.module, t.name }) catch t.name;
    }

    /// Whether `scope` may write `t` with no qualifier at all.
    fn readsBare(e: *Emitter, scope: Graph.Index, t: TypeRef) bool {
        // The module's own declarations.
        if (std.mem.eql(u8, e.session.store.moduleName(e.graph().moduleFile(scope)), t.module)) return true;
        const symbol = e.session.interner.find(t.name) orelse return false;
        // The prelude (Appendix A): in scope in every module, with no
        // import to qualify it by.
        if (prelude.wellKnown(symbol)) |w| {
            if (prelude.typeModule(w)) |owner| {
                if (std.mem.eql(u8, e.session.interner.slice(owner.symbol()), t.module)) return true;
            }
        }
        const b = e.bir(scope);
        for (b.imports) |imp| {
            if (!std.mem.eql(u8, e.session.interner.slice(b.symbol(imp.module)), t.module)) continue;
            for (b.importExposed(imp)) |name| {
                if (b.symbol(name.name) == symbol) return true;
            }
        }
        return false;
    }

    /// The platform's `Program` as the module the diagnostic points at
    /// could write it. `scope` is null when there is no module to ask —
    /// `missing_main` before an entry module exists — and the answer is
    /// then the manifest's own module-qualified spelling, which is always
    /// readable.
    fn writtenProgramName(e: *Emitter, scope: ?Graph.Index) ![]const u8 {
        const qualified = e.options.platform.program orelse "";
        const at = scope orelse e.firstAppModule() orelse return qualified;
        return e.writtenTypeName(at, .{
            .module = platformModule(qualified),
            .name = shortName(qualified),
        });
    }

    /// The first module of the ROOT package by module index — the sorted
    /// path, never argument or completion order (CLAUDE.md rule 5). It is
    /// the file `missing_main` is reported against, because an absence has
    /// no file of its own and this one is the same however the build was
    /// invoked.
    fn firstAppModule(e: *Emitter) ?Graph.Index {
        for (0..e.graph().count()) |i| {
            const m: Graph.Index = @enumFromInt(i);
            if (e.session.store.package(e.graph().moduleFile(m)) == .app) return m;
        }
        return null;
    }

    /// Why `missing_main` names the file it names, in a form that can be
    /// finished with a full stop.
    fn entryFileRule(e: *Emitter) ![]const u8 {
        var count: u32 = 0;
        for (0..e.graph().count()) |i| {
            const m: Graph.Index = @enumFromInt(i);
            if (e.session.store.package(e.graph().moduleFile(m)) == .app) count += 1;
        }
        if (count <= 1) return "this project's only module";
        return std.fmt.allocPrint(
            e.scratch,
            "the first of this project's {d} modules by path",
            .{count},
        );
    }

    fn currentModuleOf(e: *Emitter, b: *const Bir) Graph.Index {
        for (0..e.graph().count()) |i| {
            const m: Graph.Index = @enumFromInt(i);
            if (e.bir(m) == b) return m;
        }
        return @enumFromInt(0);
    }

    // ---- backend.md §9: reachability elimination --------------------------

    /// Walk §9's declaration graph and keep the answer. **Always on, for
    /// every `beni build`** (§9): not release-only, because eager
    /// derivation is the difference between an empty program shipping 70 kB
    /// and shipping 2 kB, and a development build that ships fifty times
    /// what it needs is not a development build anyone would run.
    fn eliminate(e: *Emitter, entry: ?Entry) !void {
        const token = e.session.profile.begin();
        defer e.session.profile.end(0, token, .eliminate, Profile.Event.no_file, 0);
        const count = e.graph().count();
        const birs = try e.scratch.alloc(*const Bir, count);
        const tables = try e.scratch.alloc(*const Dispatch, count);
        var insts: usize = 0;
        for (birs, tables, 0..) |*b, *d, i| {
            const m: Graph.Index = @enumFromInt(@as(u32, @intCast(i)));
            b.* = e.bir(m);
            d.* = e.dispatchOf(m);
            insts += b.*.insts.len;
        }
        const in: Reach.Input = .{
            .graph = e.graph(),
            .store = &e.session.store,
            .birs = birs,
            .dispatch = tables,
            .interfaces = e.session.resolution.interfaces,
            .provenance = e.session.resolution.provenance,
            .types = &e.session.checked.types,
            .entry = if (entry) |at| .{ .module = at.module, .kind = .decl, .index = at.decl.int() } else null,
            .library = e.options.library,
        };
        // Every module's edges on the workers, each into its own slot and
        // its worker's `kept` arena, then the walk here.
        const edges = try e.scratch.alloc(Reach.ModuleEdges, count);
        const builders = try e.scratch.alloc(Reach.Builder, e.pool.workers.len);
        for (builders, e.pool.workers) |*b, *w| b.* = .init(in, w.kept.allocator());
        const all = try e.scratch.alloc(u32, count);
        for (all, 0..) |*slot, i| slot.* = @intCast(i);
        try e.pool.run(all, EdgeTask{ .edges = edges, .builders = builders }, EdgeTask.build, e.wanted(insts, insts_per_edge_builder));
        e.live = try Reach.walk(e.scratch, in, edges);
        for (e.pool.workers) |*w| w.kept.reset(.retain_capacity);
    }

    /// One module's reachability edges (`Reach.Builder.module`).
    const EdgeTask = struct {
        edges: []Reach.ModuleEdges,
        builders: []Reach.Builder,

        fn build(t: EdgeTask, w: *Worker, i: u32) Allocator.Error!void {
            t.edges[i] = try t.builders[w.tid].module(@enumFromInt(i));
        }
    };

    // ---- backend.md §9: `--release` refuses `Debug` ----------------------

    /// One live declaration's reference to a `pub` value of `core/Debug`.
    /// Flat, and ordered by construction: modules in `Graph.Index` order,
    /// which is sorted path (CLAUDE.md rule 5), then declarations in source
    /// order, then references in instruction order.
    const DebugSite = struct {
        file: SourceStore.Index,
        /// The reference itself where the instruction stream has one, and
        /// the referring declaration's name otherwise.
        token: u32,
        /// The referring module and declaration, for the message.
        module: []const u8,
        decl: []const u8,
        /// `log`, `toString` or `todo`.
        used: []const u8,
    };

    /// How many sites the message lists before it counts the rest. A program
    /// full of logs prints a diagnostic, not a wall.
    const max_debug_sites = 5;

    /// **A `--release` build that reaches `Debug` is refused** (§9's *The
    /// release optimiser*; the owner's decision, 2026-09-19, which is Elm's
    /// rule for `--optimize`).
    ///
    /// **The rule is reachability and nothing softer.** A `Debug` call in a
    /// declaration §9's walk drops — an unused helper — does not refuse the
    /// build, because the build does not ship it; reachability is the honest
    /// definition of "this build uses it" and it is already computed, so
    /// there is no second notion of use to disagree with the first. A
    /// development build is untouched.
    ///
    /// **Why it is refused rather than tolerated.** `Debug.toString` reads a
    /// value's runtime representation — field names, constructor tags —
    /// which is exactly the surface a release optimiser must be free to
    /// change: §9's *Item 4* had to carry "if `Debug` survives reachability,
    /// renaming is off for the build", and integer constructor tags
    /// (`fast-compiler.md` §9.5) want the same pin. And a `Debug.log` inside
    /// a binding nothing reads is dropped whole by item 1
    /// (`language.md` §6's *What an optimiser may assume*), which is the one
    /// place the two builds print different things. With the refusal, "a
    /// release build behaves exactly as the development build does" holds
    /// with no exception and no pinned set.
    ///
    /// **The sites.** The `Live` set says WHETHER, and the instruction
    /// stream says WHERE: an `ext_value` naming a `Debug` value inside a
    /// live declaration's contiguous range is a use site with a token of its
    /// own. `Edges.declEdges` — the shared walk §9 and `check/Cycles.zig`
    /// both read — is then consulted for the same declaration, so a
    /// reference through a leg the instruction scan cannot see (leg 3's
    /// dispatch targets) still refuses the build; it has no token, so that
    /// site falls back to the declaration's name.
    fn refuseDebug(e: *Emitter) !void {
        const debug = e.graph().lookup(.core, InternPool.WellKnown.Debug.symbol()) orelse return;
        if (debug.int() >= e.session.resolution.provenance.len) return;
        const debug_bir = e.bir(debug);
        const provenance = &e.session.resolution.provenance[debug.int()];

        // The fast path, and it is nearly every build: nothing of `Debug`
        // survived, so there is nothing to look for.
        var survived = false;
        for (0..debug_bir.decls.len) |i| {
            if (e.live.decl(debug, i)) survived = true;
        }
        if (!survived) return;

        var sites: std.ArrayList(DebugSite) = .empty;
        var stream: std.ArrayList(Edges.Edge) = .empty;
        for (0..e.graph().count()) |i| {
            const m: Graph.Index = @enumFromInt(@as(u32, @intCast(i)));
            if (m == debug) continue;
            const b = e.bir(m);
            const file = e.graph().moduleFile(m);
            const tags = b.insts.items(.tag);
            const data = b.insts.items(.data);
            const tokens = b.insts.items(.main_token);
            for (b.decls, 0..) |d, index| {
                if (d.kind != .value or !e.live.decl(m, index)) continue;
                const before = sites.items.len;
                const start = @min(d.inst_start.int(), b.insts.len);
                const end = @min(d.inst_end.int(), b.insts.len);
                for (tags[start..end], data[start..end], tokens[start..end]) |tag, payload, token| {
                    if (tag != .ext_value or payload.lhs != debug.int()) continue;
                    const target = provenance.valueDecl(payload.rhs) orelse continue;
                    try sites.append(e.scratch, e.debugSite(b, d, file, token, debug_bir, target.int()));
                }
                if (sites.items.len != before) continue;
                // Nothing in the instructions, so ask the shared walk: leg 3
                // is the only other way to name another module's value, and
                // it carries no token.
                stream.clearRetainingCapacity();
                try Edges.declEdges(&stream, e.scratch, b, e.dispatchOf(m), @intCast(index));
                for (stream.items) |edge| {
                    const ext = switch (edge) {
                        .ext => |x| x,
                        else => continue,
                    };
                    if (ext.module != debug) continue;
                    const target = provenance.valueDecl(ext.value) orelse continue;
                    try sites.append(e.scratch, e.debugSite(b, d, file, d.name_token, debug_bir, target.int()));
                    break;
                }
            }
        }
        if (sites.items.len == 0) return;

        // One diagnostic with a list, the shape `duplicate_main` set: two
        // locations in one message rather than two messages. The list is
        // `-` lines, which `checker.md` §8.4's wrap leaves alone.
        var list: std.ArrayList(u8) = .empty;
        for (sites.items[0..@min(sites.items.len, max_debug_sites)]) |site| {
            const at = e.tokenPosition(site.file, site.token);
            try list.print(e.scratch, "- `{s}:{d}:{d}` — `{s}.{s}` uses `Debug.{s}`\n", .{
                e.session.store.path(site.file),
                at.line,
                at.col,
                site.module,
                site.decl,
                site.used,
            });
        }
        if (sites.items.len > max_debug_sites) {
            try list.print(e.scratch, "- … and {d} more.\n", .{sites.items.len - max_debug_sites});
        }

        const first = sites.items[0];
        try e.report(
            .debug_in_release,
            first.file,
            first.token,
            \\This `--release` build reaches `Debug`.
            \\
            \\{s}
            \\`Debug` is for developing: `toString` reads a value's runtime representation,
            \\which a release build is free to change; a `Debug.log` in a binding nothing
            \\reads is dropped along with the binding; and `todo` crashes. A release build
            \\must behave exactly as the development build does, so it may not reach `Debug`
            \\at all. Remove the call, or build without `--release`.
        ,
            .{list.items},
        );
    }

    fn debugSite(
        e: *Emitter,
        b: *const Bir,
        d: Bir.Decl,
        file: SourceStore.Index,
        token: u32,
        debug_bir: *const Bir,
        target: usize,
    ) DebugSite {
        return .{
            .file = file,
            .token = token,
            .module = e.session.store.moduleName(file),
            .decl = e.session.interner.slice(b.symbol(d.name)),
            .used = e.session.interner.slice(debug_bir.symbol(debug_bir.decls[target].name)),
        };
    }

    /// The declaration a module exports as its entry point (§5): `main` of
    /// the build's entry module in an application build, and every root
    /// module's own `main` in a library one, where there is no single entry
    /// and a `main` is just another exported name.
    fn entryDeclOf(e: *Emitter, m: Graph.Index, entry: ?Entry) ?u32 {
        if (entry) |at| return if (at.module == m) at.decl.int() else null;
        if (!e.options.library) return null;
        if (e.session.store.package(e.graph().moduleFile(m)) != .app) return null;
        return Reach.mainOf(e.bir(m));
    }

    // ---- Emission ---------------------------------------------------------

    /// Lower and print every live module, on as many workers as the build
    /// has and the work can keep busy, and produce the files in module
    /// order.
    ///
    /// **The output is the serial walk's, byte for byte, at every
    /// `--jobs`** (CLAUDE.md rule 5). Each module is lowered into its own
    /// `ModuleSlot` through its own overlay on the session's pool
    /// (`InternPool.Overlay`), so no worker writes anything another reads;
    /// a name is printed from its text, never from a symbol id, so which
    /// pool held it does not reach a byte. Everything the modules share is
    /// decided serially, in module order, before or between the parallel
    /// steps: the specifier tables before, and under `--release` the
    /// whole-program names in between (`numberGlobals`).
    fn emitModules(e: *Emitter, entry: ?Entry) !void {
        const count = e.graph().count();
        // The output path of every module, so a specifier is a string join
        // and not a second walk.
        const paths = try e.scratch.alloc([]const u8, count);
        for (paths, 0..) |*slot, i| slot.* = try e.outputPath(@enumFromInt(@as(u32, @intCast(i))));
        // Every module's specifier table, one per importer DEPTH: a specifier
        // depends on the target's path and on nothing of the importer but its
        // directory depth, so the modules at one depth share one table. One
        // table per module was count² strings in an arena nothing frees —
        // 8.7 % of a 100k-line build's cycles and half its page faults
        // (plans/perf-study-2026-09-27.md, item 1).
        var by_depth: std.ArrayList(?[]const []const u8) = .empty;
        // The build's markup lowering, with what every module's lowering of
        // its markup needs (`boundary.md` §9.4).
        const markup_output = try e.markupRuntimeOutputPath();
        const lowering: ?*const beni_markup.Lowering = if (e.options.platform.lowering) |name| findLowering(name) else null;
        const vocabulary: ?*const Interface = if (e.graph().markup.vocabulary) |v|
            (if (v.int() < e.session.resolution.interfaces.len) &e.session.resolution.interfaces[v.int()] else null)
        else
            null;

        // What each worker needs of the shared arena is made here, first:
        // the arena is the calling thread's alone.
        const slots = try e.scratch.alloc(ModuleSlot, count);
        @memset(slots, .{ .overlay = .init(&e.session.interner) });
        defer for (slots) |*slot| slot.deinit(e.gpa);
        var todo: std.ArrayList(u32) = .empty;
        var insts: usize = 0;
        for (slots, 0..) |*slot, i| {
            const m: Graph.Index = @enumFromInt(@as(u32, @intCast(i)));
            // §5: a module with nothing reachable is not written at all,
            // and nothing imports it, because imports are use-driven and a
            // use is an edge.
            if (!e.live.of(m).any() or e.onlyPrimitivesLive(m)) continue;
            const source_path = e.session.store.path(e.graph().moduleFile(m));
            slot.specifiers = try specifierTable(e.scratch, &by_depth, paths, paths[i]);
            slot.sibling = try e.siblingSpecifier(source_path);
            slot.derived_runtime = try relativeSpecifier(e.scratch, paths[i], derived_runtime_path);
            if (lowering != null and vocabulary != null and markup_output != null) slot.markup = .{
                .lowering = lowering.?,
                .vocabulary = vocabulary.?,
                .runtime = try relativeSpecifier(e.scratch, paths[i], markup_output.?),
                .build = .{ .release = e.options.release, .library = e.options.library },
            };
            try todo.append(e.scratch, @intCast(i));
            insts += e.bir(m).insts.len;
        }

        // The last write to the session's pool until every module is
        // lowered: from here on the workers only read it.
        try Lower.internFixedNames(e.gpa, &e.session.interner);
        const context: Task = .{ .e = e, .slots = slots, .entry = entry };
        try e.pool.run(todo.items, context, Task.lower, e.wanted(insts, insts_per_emitter));
        if (e.options.release) {
            try e.numberGlobals(slots, todo.items);
            try e.pool.run(todo.items, context, Task.print, e.wanted(insts, insts_per_emitter));
        }

        // Diagnostics and files in module order, whatever order the workers
        // finished in.
        var uses_runtime = false;
        for (todo.items) |i| {
            const slot = &slots[i];
            const m: Graph.Index = @enumFromInt(i);
            const file = e.graph().moduleFile(m);
            if (slot.lowered) |*lowered| if (lowered.diagnostics.len != 0) {
                for (lowered.diagnostics) |d| {
                    const token = d.token orelse if (d.region.int() < e.bir(m).insts.len)
                        e.bir(m).insts.items(.main_token)[d.region.int()]
                    else
                        0;
                    try e.diagnostics.append(e.gpa, .{ .code = d.code, .file = file, .token = token, .message = d.message });
                }
                // The messages are the diagnostics' now.
                e.gpa.free(lowered.diagnostics);
                lowered.diagnostics = &.{};
                continue;
            };
            uses_runtime = uses_runtime or slot.uses_runtime;
            e.uses_markup_runtime = e.uses_markup_runtime or slot.uses_markup_runtime;
            for (slot.start) |pair| try e.start.append(e.scratch, .{
                .key = try e.scratch.dupe(u8, pair.key),
                .value = try e.scratch.dupe(u8, pair.value),
            });
            if (slot.rename_failure) |failure| try e.reportRenameFailure(&slot.lowered.?.ir, &slot.overlay, file, failure);
            const text = slot.text orelse continue;
            slot.text = null;
            try e.produceOwned(paths[i], text, e.session.store.path(file));
        }
        if (uses_runtime) try e.emitDerivedRuntime();
    }

    /// One module's way from `Bir` to bytes. Written by the one worker that
    /// took the module, read by the calling thread once every worker is done.
    const ModuleSlot = struct {
        specifiers: []const []const u8 = &.{},
        sibling: []const u8 = "",
        derived_runtime: []const u8 = "",
        /// What the build's markup lowering needs of this module, when it
        /// has one (`boundary.md` §9.4).
        markup: ?Lower.Markup = null,
        /// The names this module's lowering invents, and the printer's way
        /// to spell every name.
        overlay: InternPool.Overlay,
        /// Kept past printing only under `--release`, and for a module whose
        /// lowering reported, whose diagnostics are read in module order.
        lowered: ?Lower.Result = null,
        /// Whether the module imports the derived-comparison engine, and
        /// the markup runtime.
        uses_runtime: bool = false,
        uses_markup_runtime: bool = false,
        /// The program start data its markup lowering contributed, in the
        /// lowering worker's `kept` arena.
        start: []const Lower.StartPair = &.{},
        /// `--release` only: §9 item 1's plan, and the whole-program names
        /// the module mentions in print order (`Rename.collectGlobals`),
        /// both in the lowering worker's `kept` arena.
        plan: Opt.Plan = .none,
        met: []const JsIr.NameIndex = &.{},
        /// The module's bytes, gpa-owned until `produceOwned` takes them.
        text: ?[]u8 = null,
        rename_failure: ?Rename.Failure = null,

        fn deinit(slot: *ModuleSlot, gpa: Allocator) void {
            if (slot.lowered) |*lowered| lowered.deinit(gpa);
            if (slot.text) |text| gpa.free(text);
            slot.overlay.deinit(gpa);
            slot.* = undefined;
        }
    };

    /// What a worker runs per module.
    const Task = struct {
        e: *Emitter,
        slots: []ModuleSlot,
        entry: ?Entry,

        /// `Bir` → `JsIr`, and in a development build straight on to the
        /// bytes. Under `--release`, the plan and the module's whole-program
        /// names instead: its bytes wait for `numberGlobals`.
        fn lower(t: Task, w: *Worker, i: u32) Allocator.Error!void {
            const e = t.e;
            const slot = &t.slots[i];
            const m: Graph.Index = @enumFromInt(i);
            const file = e.graph().moduleFile(m);
            const token = e.session.profile.begin();
            defer e.session.profile.end(w.tid, token, .emit_module, file.int(), 0);
            const scratch = w.module.allocator();
            slot.lowered = try Lower.lower(e.gpa, scratch, &slot.overlay, .{
                .bir = e.bir(m),
                .token_starts = e.session.artifacts.spans(file).starts,
                .module = m,
                .graph = e.graph(),
                .interfaces = e.session.resolution.interfaces,
                .dispatch = e.dispatchOf(m),
                .types = &e.session.checked.types,
                .specifiers = slot.specifiers,
                .sibling = slot.sibling,
                .entry_decl = e.entryDeclOf(m, t.entry),
                .live = &e.live,
                .derived_runtime = slot.derived_runtime,
                .markup = slot.markup,
            });
            const lowered = &slot.lowered.?;
            if (lowered.diagnostics.len != 0) return;
            slot.uses_runtime = lowered.uses_runtime;
            slot.uses_markup_runtime = lowered.uses_markup_runtime;
            // Read in module order once every module is lowered; the
            // lowering's own copy goes with its tree.
            const start = try w.kept.allocator().alloc(Lower.StartPair, lowered.start.len);
            for (start, lowered.start) |*to, pair| to.* = .{
                .key = try w.kept.allocator().dupe(u8, pair.key),
                .value = try w.kept.allocator().dupe(u8, pair.value),
            };
            slot.start = start;
            if (!e.options.release) {
                slot.text = try Print.print(e.gpa, scratch, &lowered.ir, .fromOverlay(&slot.overlay), .{});
                // Nothing after this reads the tree or the overlay: the bytes
                // are what is left of the module.
                lowered.deinit(e.gpa);
                slot.lowered = null;
                slot.overlay.deinit(e.gpa);
                slot.overlay = .init(&e.session.interner);
                return;
            }
            // §9's release optimiser, between `Lower.lower` and
            // `Print.print`: item 1 plans, item 2 names, the printer spends
            // both.
            const plan = try Opt.run(scratch, &lowered.ir);
            const kept = w.kept.allocator();
            slot.plan = .{
                .dropped = try kept.dupe(u32, plan.dropped),
                .inlined = try kept.dupe(JsIr.Node.OptionalIndex, plan.inlined),
            };
            slot.met = try kept.dupe(JsIr.NameIndex, try Rename.collectGlobals(scratch, &lowered.ir, &slot.plan));
        }

        /// `--release`'s second step: short names and compact bytes, once
        /// every whole-program name has its ordinal.
        fn print(t: Task, w: *Worker, i: u32) Allocator.Error!void {
            const e = t.e;
            const slot = &t.slots[i];
            const token = e.session.profile.begin();
            defer e.session.profile.end(w.tid, token, .emit_module, e.graph().moduleFile(@enumFromInt(i)).int(), 0);
            const lowered = &(slot.lowered orelse return);
            if (lowered.diagnostics.len != 0) return;
            const scratch = w.module.allocator();
            var renamer = try Rename.begin(scratch, &lowered.ir, &e.globals);
            slot.text = try Print.print(e.gpa, scratch, &lowered.ir, .fromOverlay(&slot.overlay), .{
                .plan = &slot.plan,
                .rename = &renamer,
                .compact = true,
            });
            slot.rename_failure = renamer.failure;
        }
    };

    /// §9 item 2's whole-program namespace, numbered serially and in module
    /// order from each module's names in print order — the order a serial
    /// build meets them in while printing one module after another. Each
    /// name is moved out of its module's overlay into the session's pool
    /// first, because two modules name one function by the same TEXT and
    /// the table is keyed by symbol.
    fn numberGlobals(e: *Emitter, slots: []ModuleSlot, todo: []const u32) Allocator.Error!void {
        const interner = &e.session.interner;
        for (todo) |i| {
            const slot = &slots[i];
            const lowered = &(slot.lowered orelse continue);
            if (lowered.diagnostics.len != 0) continue;
            for (slot.met) |n| {
                var name = lowered.ir.name(n);
                var moved = false;
                if (name.module.unwrap()) |module| if (InternPool.Overlay.isOverlay(module)) {
                    name.module = (try interner.getOrPut(e.gpa, slot.overlay.slice(module))).toOptional();
                    moved = true;
                };
                if (InternPool.Overlay.isOverlay(name.base)) {
                    name.base = try interner.getOrPut(e.gpa, slot.overlay.slice(name.base));
                    moved = true;
                }
                if (moved) lowered.ir.setName(n, name);
                _ = try e.globals.intern(e.scratch, name);
            }
        }
    }

    /// Whether a module's only survivors are markup primitives: each is the
    /// markup runtime's export and not the module's (`boundary.md` §9.3),
    /// so the module has nothing to write and nothing imports it.
    fn onlyPrimitivesLive(e: *Emitter, m: Graph.Index) bool {
        const live = e.live.of(m);
        if (live.derived.count() != 0) return false;
        for (e.bir(m).decls, 0..) |d, index| {
            if (live.decl(index) and d.kind != .vocab_markup) return false;
        }
        return true;
    }

    /// The most threads emit may use: the build's `--jobs`, but no more
    /// than there are modules.
    fn workerCount(e: *Emitter) usize {
        return @min(e.session.options.jobs, @max(e.graph().count(), 1));
    }

    /// The threads one round can keep busy: one per `per` units of `work`,
    /// so a small project does not pay for threads it cannot keep busy.
    /// An explicit `--jobs` above 1 still gets two, so that asking for a
    /// parallel emit always runs one, whatever the project's size.
    fn wanted(e: *const Emitter, work: usize, per: usize) usize {
        const by_work = std.math.divCeil(usize, work, per) catch unreachable;
        return @max(@as(usize, if (e.session.options.size_by_work) 1 else 2), by_work);
    }

    /// One emit worker's own memory. Nothing in it is shared: a worker
    /// reads the session and writes the slot of the item it took.
    const Worker = struct {
        /// Index into the profile's per-thread buffers.
        tid: u32,
        /// One item's working memory, reset before the next: nothing a
        /// module builds on the way to its bytes outlives it.
        module: Arena = .init(std.heap.page_allocator),
        /// What one round hands a later one: the reachability edges until
        /// the walk, and under `--release` what lowering hands printing.
        kept: Arena = .init(std.heap.page_allocator),
        failure: ?Allocator.Error = null,
    };

    /// The emit phase's threads: the calling one and up to `jobs - 1` more,
    /// spawned the first time a round wants them, and kept for every
    /// round of the phase — the reachability edges, lowering, `--release`'s
    /// printing and the writes. Each is spawned with the stack every tree
    /// walk in the compiler gets (`Session.check_stack_size`), because
    /// lowering and printing recurse on expression depth.
    const Workers = struct {
        gpa: Allocator,
        io: Io,
        workers: []Worker,
        threads: std.ArrayList(std.Thread) = .empty,
        /// A spawn failed once: the phase goes on with the threads it has.
        spawn_failed: bool = false,
        mutex: Io.Mutex = .init,
        /// Signalled when a round starts, and to leave.
        start: Io.Condition = .init,
        /// Signalled by the last spawned thread to finish a round.
        done: Io.Condition = .init,
        /// Bumped once per round: a thread that has done round `r` waits
        /// for `r + 1`.
        round: u32 = 0,
        /// Spawned threads still in the current round.
        busy: usize = 0,
        quit: bool = false,
        job: Job = undefined,

        const Job = struct {
            context: *const anyopaque,
            call: *const fn (context: *const anyopaque, w: *Worker, item: u32) Allocator.Error!void,
            items: []const u32,
            next: std.atomic.Value(u32),
        };

        fn init(gpa: Allocator, io: Io, n: usize) Allocator.Error!Workers {
            const workers = try gpa.alloc(Worker, @max(n, 1));
            for (workers, 0..) |*w, tid| w.* = .{ .tid = @intCast(tid) };
            return .{ .gpa = gpa, .io = io, .workers = workers };
        }

        fn deinit(p: *Workers) void {
            p.mutex.lockUncancelable(p.io);
            p.quit = true;
            p.start.broadcast(p.io);
            p.mutex.unlock(p.io);
            for (p.threads.items) |t| t.join();
            p.threads.deinit(p.gpa);
            for (p.workers) |*w| {
                w.module.deinit();
                w.kept.deinit();
            }
            p.gpa.free(p.workers);
        }

        /// `task(context, worker, item)` for every item of `items`, claimed
        /// in order by whichever thread is free. Which thread ran an item
        /// changes nothing but the time: a task writes only its item's slot.
        fn run(
            p: *Workers,
            items: []const u32,
            context: anytype,
            comptime task: fn (@TypeOf(context), *Worker, u32) Allocator.Error!void,
            want: usize,
        ) Allocator.Error!void {
            const Context = @TypeOf(context);
            const Thunk = struct {
                fn call(cx: *const anyopaque, w: *Worker, item: u32) Allocator.Error!void {
                    const c: *const Context = @ptrCast(@alignCast(cx));
                    return task(c.*, w, item);
                }
            };
            p.job = .{ .context = &context, .call = Thunk.call, .items = items, .next = .init(0) };
            for (p.workers) |*w| w.failure = null;
            // Threads are spawned the first time a round wants them and kept
            // for the rounds after; a round that wants fewer still wakes
            // them all, and the extra ones find nothing to claim.
            const threads = @min(want, p.workers.len) -| 1;
            if (!p.spawn_failed and p.threads.items.len < threads) {
                try p.threads.ensureTotalCapacity(p.gpa, p.workers.len - 1);
                for (p.workers[1 + p.threads.items.len .. 1 + threads]) |*w| {
                    const t = std.Thread.spawn(.{ .stack_size = Session.check_stack_size }, loop, .{ p, w, p.round }) catch {
                        // Fewer threads is a slower emit, not a failed one:
                        // the ones there are take every item.
                        p.spawn_failed = true;
                        break;
                    };
                    p.threads.appendAssumeCapacity(t);
                }
            }
            p.mutex.lockUncancelable(p.io);
            p.round += 1;
            p.busy = p.threads.items.len;
            p.start.broadcast(p.io);
            p.mutex.unlock(p.io);

            p.drain(&p.workers[0]);

            // No worker is still writing a slot once this returns.
            p.mutex.lockUncancelable(p.io);
            while (p.busy != 0) p.done.waitUncancelable(p.io, &p.mutex);
            p.mutex.unlock(p.io);
            for (p.workers) |*w| {
                if (w.failure) |err| return err;
            }
        }

        fn drain(p: *Workers, w: *Worker) void {
            while (true) {
                const k = p.job.next.fetchAdd(1, .monotonic);
                if (k >= p.job.items.len) return;
                w.module.reset(.retain_capacity);
                p.job.call(p.job.context, w, p.job.items[k]) catch |err| {
                    w.failure = err;
                    return;
                };
            }
        }

        fn loop(p: *Workers, w: *Worker, done_round: u32) void {
            // A thread is spawned before its first round is announced, so it
            // starts as having done the round before and waits for the bump.
            var seen = done_round;
            while (true) {
                p.mutex.lockUncancelable(p.io);
                while (p.round == seen and !p.quit) p.start.waitUncancelable(p.io, &p.mutex);
                if (p.quit) {
                    p.mutex.unlock(p.io);
                    return;
                }
                seen = p.round;
                p.mutex.unlock(p.io);

                p.drain(w);

                p.mutex.lockUncancelable(p.io);
                p.busy -= 1;
                if (p.busy == 0) p.done.signal(p.io);
                p.mutex.unlock(p.io);
            }
        }
    };

    /// `_core/_derived.mjs`, written iff a module written imports it
    /// (`backend.md` §4, *Derived comparisons do not grow the native stack*):
    /// the compiler's own JavaScript, `src/js/derived_runtime.mjs`, or its
    /// compact copy under `--release`. Importers name its exports by their
    /// fixed names (`import { deep as _derived$deep }`), as they name a
    /// sibling's, so renaming touches only the local side.
    fn emitDerivedRuntime(e: *Emitter) !void {
        const text = if (e.options.release) derived_runtime_compact else derived_runtime_source;
        try e.produce(derived_runtime_path, text, derived_runtime_path);
    }

    /// §9 item 2's self-check, in the spirit of `Lower`'s `requireLive`: in a
    /// safety build the renamer asserts that no two names in one scope share a
    /// spelling, that no spelling is a reserved word or a host global, and
    /// that every reference resolved to something. A failure is `internal`
    /// with the offending name in it, because the alternative is a
    /// `SyntaxError` at load — or, worse, a silently wrong value — in a
    /// program nobody thought to test.
    fn reportRenameFailure(e: *Emitter, ir: *const JsIr, overlay: *const InternPool.Overlay, file: SourceStore.Index, failure: Rename.Failure) !void {
        const base = if (failure.name.unwrap()) |i|
            overlay.slice(ir.names[i].base)
        else
            "a name";
        try e.report(
            .internal,
            file,
            0,
            \\`--release` renaming went wrong on `{s}`: {s}.
            \\
            \\`docs/design/backend.md` §9 item 2 gives every top-level declaration's locals a
            \\fresh alphabet, skipping the short names the globals that declaration mentions
            \\were given. This build produced a name that breaks that promise, which would
            \\have loaded as a `SyntaxError` or read the wrong binding at run time.
            \\
            \\That is a compiler bug, not a mistake in this program. Please report it, and
            \\build without `--release` in the meantime.
        ,
            .{ base, failure.kind.text() },
        );
    }

    /// Sibling `.js` files and the platform runtime, copied verbatim next to
    /// the modules that import them.
    fn copyAssets(e: *Emitter) !void {
        for (0..e.graph().count()) |i| {
            const m: Graph.Index = @enumFromInt(@as(u32, @intCast(i)));
            const b = e.bir(m);
            // §5: a sibling file is copied iff the module has a SURVIVING
            // `foreign_value`, which replaces the old "declares any
            // `foreign`" test. A sibling is hand-written JavaScript copied
            // whole, so the unit is the file and not the export — §9 leaves
            // per-export elimination on the table deliberately, with the
            // number.
            var has_foreign = false;
            for (b.decls, 0..) |d, index| {
                if (d.kind == .foreign_value and e.live.decl(m, index)) has_foreign = true;
            }
            if (!has_foreign) continue;
            const source_path = e.session.store.path(e.graph().moduleFile(m));
            const sibling_source = try e.siblingPath(source_path);
            const bytes = e.readAsset(sibling_source) orelse continue;
            const out = try e.siblingOutputPath(m);
            try e.produce(out, bytes, sibling_source);
        }
        try e.copyMarkupRuntime();
        // The platform's runtime (§5.2). It is not a sibling of any module,
        // so nothing above would have copied it. A chain with none is one
        // only a library builds for, and a library has no entry to run it.
        const runtime = e.options.platform.runtime orelse return;
        const runtime_source = try std.fmt.allocPrint(e.scratch, "{s}/{s}", .{
            e.options.platform.runtime_root,
            runtime,
        });
        const bytes = e.readAsset(runtime_source) orelse {
            const manifest_path = try std.fmt.allocPrint(e.scratch, "{s}/{s}", .{ e.options.platform.runtime_root, Manifest.file_name });
            try e.reportInFile(
                .foreign_sibling_missing,
                .{ .path = manifest_path },
                \\I cannot find the platform's runtime file `{s}`.
                \\
                \\A platform declares its output shape in its manifest (`"runtime"`), and that
                \\file is what the entry point hands `main` to
                \\(`docs/design/boundary.md` §5.2).
            ,
                .{runtime_source},
            );
            return;
        };
        try e.produce(try e.runtimeOutputPath(), bytes, runtime_source);
    }

    /// The markup runtime, copied iff a module written imports it
    /// (`backend.md` §15.1) — and not a second time when it is the program
    /// runtime, which is one file (`boundary.md` §9.2).
    fn copyMarkupRuntime(e: *Emitter) !void {
        if (!e.uses_markup_runtime or e.markupRuntimeIsProgramRuntime()) return;
        const source = try e.markupRuntimePath() orelse return;
        // A missing file was reported by `checkMarkupRuntime` already.
        const bytes = e.readAsset(source) orelse return;
        try e.produce((try e.markupRuntimeOutputPath()).?, bytes, source);
    }

    /// Where the markup runtime is written: its package's output directory,
    /// under `.foreign.mjs`, as a sibling is.
    fn markupRuntimeOutputPath(e: *Emitter) !?[]const u8 {
        if (try e.markupRuntimePath() == null) return null;
        if (e.markupRuntimeIsProgramRuntime()) return try e.runtimeOutputPath();
        const base = std.fs.path.basename(e.options.platform.markup_runtime.?);
        return try std.fmt.allocPrint(e.scratch, "{s}{s}{s}", .{ e.options.platform.markup_runtime_dir, stripExtension(base, ".js"), foreign_extension });
    }

    /// The entry file. A platform declares how `main` is invoked (§5.2) and
    /// this is the smallest honest form of that: import the runtime's `run`,
    /// import `main`, apply one to the other.
    fn emitEntry(e: *Emitter, entry: Entry) !void {
        const module_path = try e.outputPath(entry.module);
        const runtime_path = try e.runtimeOutputPath();
        const module_name = e.session.store.moduleName(e.graph().moduleFile(entry.module));
        var qualified: std.ArrayList(u8) = .empty;
        for (module_name) |c| try qualified.append(e.scratch, if (c == '.') '$' else c);
        try qualified.appendSlice(e.scratch, "$main");
        // Under `--release` the exporting module spelled `main` short, and
        // both ends of an `import` must agree (§9 item 2). `run` does NOT
        // move: it is the platform manifest's runtime export, read by
        // hand-written JavaScript (`boundary.md` §5.2).
        const imported = e.entryName(entry) orelse qualified.items;
        const start = try e.startData();

        // The header comment is a development affordance: it says which
        // document decided the shape of a file the user did not write. Under
        // `--release` it is 135 bytes of the floor's 2 009 — **7%** — and a
        // release build is not where anyone reads it (§9 item 3: whitespace
        // and anything that is only there to be read goes).
        const text = if (e.options.release)
            try std.fmt.allocPrint(e.scratch,
                \\import{{run}}from"./{s}";
                \\{s}import{{{s}}}from"./{s}";
                \\{s}run({s});
                \\
            , .{
                runtime_path,
                if (start) |s| try std.fmt.allocPrint(e.scratch, "import{{start}}from\"./{s}\";\n", .{s.path}) else "",
                imported,
                module_path,
                if (start) |s| try std.fmt.allocPrint(e.scratch, "start({s});\n", .{s.data}) else "",
                imported,
            })
        else
            try std.fmt.allocPrint(e.scratch,
                \\// Generated by `beni build` (docs/design/boundary.md §5.2): the entry file
                \\// the platform's output shape asks for.
                \\import {{ run }} from "./{s}";
                \\{s}import {{ {s} }} from "./{s}";
                \\
                \\{s}run({s});
                \\
            , .{
                runtime_path,
                if (start) |s| try std.fmt.allocPrint(e.scratch, "import {{ start }} from \"./{s}\";\n", .{s.path}) else "",
                imported,
                module_path,
                if (start) |s| try std.fmt.allocPrint(e.scratch, "start({s});\n", .{s.data}) else "",
                imported,
            });
        // The NAME is the platform's (`boundary.md` §5.2's `"entry"`,
        // defaulted to `default_entry_file` by `platform.finish` and checked
        // by `checkEntryFileName`), so the manifest is what a collision
        // would have to name: no beni source asked for this file.
        try e.produce(e.options.platform.entry, text, try e.manifestPath());
    }

    /// The program start call's import path and its argument, when the
    /// build's markup lowering declares a `start` export and a module
    /// written imports the markup runtime (`boundary.md` §9.4.5): one object
    /// whose keys are sorted, each an array of its sorted, distinct values.
    /// A build with no markup, or a lowering with no `start`, calls none,
    /// so its entry file does not move by a byte.
    fn startData(e: *Emitter) !?struct { path: []const u8, data: []const u8 } {
        if (!e.uses_markup_runtime) return null;
        const lowering = findLowering(e.options.platform.lowering orelse return null) orelse return null;
        var declares = false;
        for (lowering.runtime) |r| declares = declares or std.mem.eql(u8, r.name, "start");
        if (!declares) return null;
        const pairs = e.start.items;
        std.mem.sort(Lower.StartPair, pairs, {}, struct {
            fn lessThan(_: void, x: Lower.StartPair, y: Lower.StartPair) bool {
                return switch (std.mem.order(u8, x.key, y.key)) {
                    .lt => true,
                    .gt => false,
                    .eq => std.mem.order(u8, x.value, y.value) == .lt,
                };
            }
        }.lessThan);
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(e.scratch, "{");
        var i: usize = 0;
        while (i < pairs.len) {
            const key = pairs[i].key;
            if (i != 0) try out.appendSlice(e.scratch, if (e.options.release) "," else ", ");
            try jsString(e.scratch, &out, key);
            try out.appendSlice(e.scratch, if (e.options.release) ":[" else ": [");
            var first = true;
            var previous: ?[]const u8 = null;
            while (i < pairs.len and std.mem.eql(u8, pairs[i].key, key)) : (i += 1) {
                if (previous) |p| if (std.mem.eql(u8, p, pairs[i].value)) continue;
                previous = pairs[i].value;
                if (!first) try out.appendSlice(e.scratch, if (e.options.release) "," else ", ");
                first = false;
                try jsString(e.scratch, &out, pairs[i].value);
            }
            try out.append(e.scratch, ']');
        }
        try out.appendSlice(e.scratch, "}");
        return .{ .path = (try e.markupRuntimeOutputPath()).?, .data = out.items };
    }

    /// `<platform root>/beni.json` of the package that declared the entry
    /// file, the file a fault in that declaration is reported against
    /// (`boundary.md` §5.2).
    fn manifestPath(e: *Emitter) ![]const u8 {
        return std.fmt.allocPrint(e.scratch, "{s}/{s}", .{ e.options.platform.entry_root, Manifest.file_name });
    }

    /// The short name `--release` gave the entry declaration, or null when
    /// this is a development build. Looked up by the `Name` VALUE, which is
    /// the only thing the entry file and the module that exports `main` have
    /// in common: `Lower.topName` builds it from the module's name symbol and
    /// the declaration's own, both of which are in the session interner.
    fn entryName(e: *Emitter, entry: Entry) ?[]const u8 {
        if (!e.options.release) return null;
        const b = e.bir(entry.module);
        if (entry.decl.int() >= b.decls.len) return null;
        const ordinal = e.globals.lookup(.{
            .module = e.graph().moduleName(entry.module).toOptional(),
            .base = b.symbol(b.decls[entry.decl.int()].name),
            .tag = JsIr.Name.no_tag,
        }) orelse return null;
        var buf: [8]u8 = undefined;
        return e.scratch.dupe(u8, Rename.spell(ordinal, &buf)) catch null;
    }

    // ---- Paths and files --------------------------------------------------

    /// `<package prefix>/<module name with dots as directories>.mjs`.
    fn outputPath(e: *Emitter, m: Graph.Index) ![]const u8 {
        const file = e.graph().moduleFile(m);
        const prefix: []const u8 = switch (e.session.store.package(file)) {
            .app => "",
            .core => core_dir,
            .platform => e.platformDir(file),
        };
        const name = e.session.store.moduleName(file);
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(e.scratch, prefix);
        for (name) |c| try out.append(e.scratch, if (c == '.') '/' else c);
        try out.appendSlice(e.scratch, ".mjs");
        return out.items;
    }

    /// Where a module's sibling JavaScript is WRITTEN: beside the module,
    /// under `.foreign.mjs`. See the header for why it is not `.js`.
    fn siblingOutputPath(e: *Emitter, m: Graph.Index) ![]const u8 {
        const mjs = try e.outputPath(m);
        return std.fmt.allocPrint(e.scratch, "{s}{s}", .{ mjs[0 .. mjs.len - ".mjs".len], foreign_extension });
    }

    /// Where a module's sibling JavaScript is READ from: next to the source,
    /// under its own name. `core/Basics.beni` becomes `core/Basics.js`.
    fn siblingPath(e: *Emitter, source_path: []const u8) ![]const u8 {
        return std.fmt.allocPrint(e.scratch, "{s}.js", .{stripExtension(source_path, SourceStore.extension)});
    }

    /// What the emitted module writes in its `import`: the sibling sits in
    /// the same output directory, so it is `./Name.foreign.mjs`.
    fn siblingSpecifier(e: *Emitter, source_path: []const u8) ![]const u8 {
        const base = std.fs.path.basename(source_path);
        return std.fmt.allocPrint(e.scratch, "./{s}{s}", .{ stripExtension(base, SourceStore.extension), foreign_extension });
    }

    /// Where the platform's runtime is written. It is not a sibling of any
    /// module, but it is hand-written JavaScript all the same, so it takes
    /// the same extension — and that is also what keeps a platform whose
    /// runtime is called `Node.js` from overwriting the module `Node`.
    fn runtimeOutputPath(e: *Emitter) ![]const u8 {
        const base = std.fs.path.basename(e.options.platform.runtime orelse "");
        return std.fmt.allocPrint(e.scratch, "{s}{s}{s}", .{ e.options.platform.runtime_dir, stripExtension(base, ".js"), foreign_extension });
    }

    /// The output directory of a platform file: the top platform's modules
    /// go to `_platform/`, a dependency's to `_platform/_<name>/`
    /// (`boundary.md` §9.1), so a one-platform build's tree does not move.
    fn platformDir(e: *Emitter, file: SourceStore.Index) []const u8 {
        const layers = e.options.platform.file_layers;
        const dirs = e.options.platform.layer_dirs;
        if (file.int() >= layers.len) return platform_dir;
        const layer = layers[file.int()];
        return if (layer < dirs.len) dirs[layer] else platform_dir;
    }

    /// The bytes of an asset: the embedded copy when the compiler carries
    /// one, else the file on disk.
    fn readAsset(e: *Emitter, path: []const u8) ?[]const u8 {
        for (e.options.embedded) |asset| {
            if (std.mem.eql(u8, asset.path, path)) return asset.bytes;
        }
        return fs_read.readFileAlloc(e.session.io, Io.Dir.cwd(), path, e.scratch, .limited(max_asset_bytes)) catch null;
    }

    /// Record one output file. `bytes` is copied into the scratch arena
    /// because the printer's buffer is freed as soon as the module is done.
    /// `produce` for bytes the build already owns, gpa-allocated: they are
    /// taken rather than copied, and freed when the phase ends.
    fn produceOwned(e: *Emitter, relative_path: []const u8, bytes: []u8, origin: []const u8) Allocator.Error!void {
        {
            errdefer e.gpa.free(bytes);
            try e.owned.append(e.gpa, bytes);
        }
        try e.pending.append(e.scratch, .{
            .path = try e.scratch.dupe(u8, relative_path),
            .bytes = bytes,
            .origin = try e.scratch.dupe(u8, origin),
        });
    }

    fn produce(e: *Emitter, relative_path: []const u8, bytes: []const u8, origin: []const u8) Allocator.Error!void {
        try e.pending.append(e.scratch, .{
            .path = try e.scratch.dupe(u8, relative_path),
            .bytes = try e.scratch.dupe(u8, bytes),
            .origin = try e.scratch.dupe(u8, origin),
        });
    }

    /// **Rule 1's half that is data** (§2, *The output tree does not depend
    /// on the file system's case sensitivity*; `boundary.md` §5.2): a
    /// platform may name its own entry file, and a name a module could take
    /// puts back the very collision the `_` prefix exists to prevent. So a
    /// declared name is checked, and that check is the only reason `"entry"`
    /// was safe to add at all.
    ///
    /// One path segment, a leading `_`, a trailing `.mjs`, ASCII letters,
    /// digits, `_` or `-` between. A separator is refused rather than
    /// resolved: `_a/_b.mjs` would put the entry inside a directory subject
    /// to the same rule, and one segment is all any platform has wanted.
    fn checkEntryFileName(e: *Emitter) !void {
        const name = e.options.platform.entry;
        if (entryNameIsLegal(name)) return;
        try e.reportInFile(
            .invalid_entry_file,
            .{ .path = try e.manifestPath() },
            \\This platform declares its entry file as `{s}`, which is a name a module
            \\could take.
            \\
            \\A module is named by its path and every segment is an upper identifier
            \\(`docs/design/language.md` §5), so a name beginning with `_` is one no module
            \\can ever occupy — on macOS and Windows included, where `{s}` and a module
            \\`{s}`'s own file are one and the same. An entry file name is one path segment,
            \\begins with `_`, ends in `.mjs`, and has ASCII letters, digits, `_` or `-`
            \\between (`docs/design/boundary.md` §5.2).
        ,
            .{ name, name, try e.collidingModuleName(name) },
        );
    }

    /// The module a rejected entry file name would fold onto, for the
    /// message: the stem with its first letter upper-cased, because a module
    /// name segment always begins with a capital. `main.mjs` names `Main`
    /// and not `main`, which is not a name any module can have — the point
    /// of the sentence is the file the two would share.
    fn collidingModuleName(e: *Emitter, name: []const u8) ![]const u8 {
        const stem = stripExtension(std.fs.path.basename(name), ".mjs");
        const out = try e.scratch.dupe(u8, stem);
        if (out.len != 0) out[0] = std.ascii.toUpper(out[0]);
        return out;
    }

    /// **Rule 2** (§2): two files this build would write whose paths are
    /// equal under ASCII case folding. On APFS and NTFS they are ONE file,
    /// the second write wins, and the build exits 0 having shipped
    /// something that throws at load.
    ///
    /// Folding is `std.ascii.toLower` and nothing else. Every module name
    /// segment is an ASCII upper identifier (`SourceStore.isUpperIdent`) and
    /// every name the compiler reserves is ASCII, so there is no Unicode
    /// case folding to perform and none is performed.
    ///
    /// It runs over `pending`, which is everything the build produced and
    /// nothing it dropped, and it runs BEFORE `flush`, so a refused build
    /// leaves nothing behind exactly as `boundary.md` §4's checks do.
    /// `pending` is filled in module order — sorted path, never completion
    /// order — and the comparison below breaks a tie on that index, so the
    /// pair reported is the same at every `--jobs` (CLAUDE.md rule 5).
    ///
    /// It is a check of what is WRITTEN and not of what exists, which is the
    /// one place it differs from §4: a module the reachability walk dropped
    /// cannot collide with anything, because it is not there.
    fn checkOutputPaths(e: *Emitter) !void {
        const Folded = struct { key: []const u8, index: u32 };
        const folded = try e.scratch.alloc(Folded, e.pending.items.len);
        for (e.pending.items, folded, 0..) |output, *slot, index| {
            const key = try e.scratch.dupe(u8, output.path);
            for (key) |*c| c.* = std.ascii.toLower(c.*);
            slot.* = .{ .key = key, .index = @intCast(index) };
        }
        std.mem.sort(Folded, folded, {}, struct {
            fn lessThan(_: void, x: Folded, y: Folded) bool {
                return switch (std.mem.order(u8, x.key, y.key)) {
                    .lt => true,
                    .gt => false,
                    .eq => x.index < y.index,
                };
            }
        }.lessThan);
        for (1..folded.len) |i| {
            if (!std.mem.eql(u8, folded[i - 1].key, folded[i].key)) continue;
            const first = e.pending.items[folded[i - 1].index];
            const second = e.pending.items[folded[i].index];
            try e.reportInFile(
                .output_path_collision,
                .{ .path = first.origin },
                \\Two files this build would write have the same name on a case-insensitive
                \\file system:
                \\
                \\- `{s}`, written for `{s}`
                \\- `{s}`, written for `{s}`
                \\
                \\macOS (APFS) and Windows (NTFS) fold case, so those are ONE file there and
                \\the second would overwrite the first — the build would exit 0 and the program
                \\would throw at load. A build's output is the same set of files on every file
                \\system (`docs/design/backend.md` §2), so this is refused and nothing is
                \\written. Rename one of the two sources.
            ,
                .{ first.path, first.origin, second.path, second.origin },
            );
        }
    }

    /// Write everything, in the order it was produced. The first failure
    /// stops the build; a half-written `out/` is the price of a disk that
    /// filled up, not of a diagnostic.
    ///
    /// Around the writes, §2's *The output directory holds what the last
    /// build wrote*: the record of the previous build is read, rewritten as
    /// the union of both builds (so a build killed halfway still lists
    /// everything either may have written), the outputs are written, what
    /// only the previous build wrote is removed, and the record is rewritten
    /// with this build's files alone. An old path equal to a new
    /// one under case folding is removed only when it is another file
    /// (`OutputRecord.removeStale`).
    fn flush(e: *Emitter, old: []const OutputRecord.Entry) Error!void {
        const io = e.session.io;
        const out_dir = e.options.out_dir;
        const new = try e.scratch.alloc(OutputRecord.Entry, e.pending.items.len);
        for (e.pending.items, new) |output, *entry| entry.* = .{ .hash = OutputRecord.hash(output.bytes), .path = output.path };
        const both = try std.mem.concat(e.scratch, OutputRecord.Entry, &.{ old, new });
        try e.writeRecord(both);
        try e.writeOutputs();
        _ = try OutputRecord.removeStale(e.scratch, io, out_dir, old, new);
        try e.writeRecord(new);
    }

    /// The previous build's record, or a refusal when `--out` holds a
    /// `_manifest.txt` that is not one (`backend.md` §2). Reading such a
    /// file as an empty record would overwrite it: a user's notes of that
    /// name would be lost without a word. Refused rather
    /// than renamed around, because the name is the record's by §2's rule 1
    /// and a build that silently wrote its record elsewhere could never find
    /// it again.
    fn readRecord(e: *Emitter) Error![]const OutputRecord.Entry {
        switch (try OutputRecord.read(e.scratch, e.session.io, e.options.out_dir)) {
            .none => return &.{},
            .record => |entries| return entries,
            // A file that cannot be read says nothing about whose it is:
            // the read failure is the answer, as for any file beni reads,
            // and nothing is written.
            .unreadable => |err| {
                e.io_failure.* = .{ .path = try std.fmt.allocPrint(e.scratch, "{s}/{s}", .{ e.options.out_dir, OutputRecord.file_name }), .err = err };
                return error.OutputRecordUnreadable;
            },
            .unrecognised => {
                const path = try std.fmt.allocPrint(e.scratch, "{s}/{s}", .{ e.options.out_dir, OutputRecord.file_name });
                try e.reportInFile(
                    .unknown_output_record,
                    .{ .path = path },
                    \\The output directory already holds a `{s}` that beni did not write.
                    \\
                    \\A build records the files it writes in `{s}` and, on the next build,
                    \\removes the ones that build no longer writes (`docs/design/backend.md` §2).
                    \\This file does not begin with `beni-manifest 1`, or has a line that is not
                    \\a record line, so it is somebody else's, and writing the record would
                    \\overwrite it. Nothing was written. Move the file, or build into another
                    \\directory with `--out`.
                ,
                    .{ OutputRecord.file_name, path },
                );
                return &.{};
            },
        }
    }

    /// §2's *beni writes through no link it did not make*: every path this
    /// build would write — the record and each output — is looked at under
    /// `--out`, component by component, without following links, and the
    /// first link on each is refused, before anything is written. beni
    /// makes no links, so one there is somebody else's: a dangling
    /// `_manifest.txt` link read as no record, and the build wrote the
    /// record wherever it pointed. Each link is named once, in the order of
    /// the paths (the record first, then `pending`, which is module order).
    fn refuseLinks(e: *Emitter) !void {
        const io = e.session.io;
        const out_dir = e.options.out_dir;
        var named: std.StringHashMapUnmanaged(void) = .empty;
        const paths = try e.scratch.alloc([]const u8, e.pending.items.len + 1);
        paths[0] = OutputRecord.file_name;
        for (e.pending.items, paths[1..]) |output, *p| p.* = output.path;
        for (paths) |path| {
            const link = try OutputRecord.firstLink(e.scratch, io, out_dir, path) orelse continue;
            if ((try named.getOrPut(e.scratch, link)).found_existing) continue;
            const full = try std.fmt.allocPrint(e.scratch, "{s}/{s}", .{ out_dir, path });
            const what = if (std.mem.eql(u8, full, link))
                "This build writes that file"
            else
                try std.fmt.allocPrint(e.scratch, "This build writes `{s}` inside it", .{full});
            try e.reportInFile(
                .unknown_output_record,
                .{ .path = link },
                \\`{s}` is a symbolic link, and beni never makes one in the output directory,
                \\so it is somebody else's.
                \\
                \\{s}, and writing through the link would write into whatever it points at,
                \\which may be outside the output directory altogether. Nothing was written.
                \\Remove the link, or build into another directory with `--out`.
            ,
                .{ link, what },
            );
        }
    }

    fn writeRecord(e: *Emitter, entries: []const OutputRecord.Entry) Error!void {
        const io = e.session.io;
        Io.Dir.cwd().createDirPath(io, e.options.out_dir) catch |err| {
            e.io_failure.* = .{ .path = e.options.out_dir, .err = err };
            return error.OutputPath;
        };
        const path = try std.fmt.allocPrint(e.scratch, "{s}/{s}", .{ e.options.out_dir, OutputRecord.file_name });
        OutputRecord.write(e.scratch, io, path, entries) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                e.io_failure.* = .{ .path = path, .err = err };
                return error.OutputPath;
            },
        };
    }

    fn writeOutputs(e: *Emitter) Error!void {
        // Each directory once, and not once per file: a tree of 600 modules
        // in a dozen directories made 600 `mkdirat` calls, almost all of
        // them answered "exists". In the order the files come, so a
        // directory that cannot be made is the one the first file needing
        // it would have named.
        var made: std.StringHashMapUnmanaged(void) = .empty;
        for (e.pending.items) |output| {
            const dir = std.fs.path.dirname(output.path) orelse continue;
            if ((try made.getOrPut(e.scratch, dir)).found_existing) continue;
            const path = try std.fmt.allocPrint(e.scratch, "{s}/{s}", .{ e.options.out_dir, dir });
            Io.Dir.cwd().createDirPath(e.session.io, path) catch |err| {
                e.io_failure.* = .{ .path = path, .err = err };
                return error.OutputPath;
            };
        }
        // The files on the emit workers: every one has its own path, so no
        // two writes touch one file, and the failure reported is the first
        // in `pending` order whichever worker met it.
        const failures = try e.scratch.alloc(?anyerror, e.pending.items.len);
        @memset(failures, null);
        const all = try e.scratch.alloc(u32, e.pending.items.len);
        for (all, 0..) |*slot, i| slot.* = @intCast(i);
        try e.pool.run(all, WriteTask{ .e = e, .failures = failures }, WriteTask.write, e.wanted(all.len, files_per_writer));
        for (e.pending.items, failures) |output, failure| {
            if (failure) |err| {
                e.io_failure.* = .{ .path = try e.outputFilePath(e.scratch, output.path), .err = err };
                return error.OutputPath;
            }
            e.files_written += 1;
            e.bytes_written += output.bytes.len;
        }
    }

    fn outputFilePath(e: *const Emitter, arena: Allocator, relative: []const u8) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(arena, "{s}/{s}", .{ e.options.out_dir, relative });
    }

    /// Write one of `pending`, recording a failure rather than stopping:
    /// which one is reported is decided afterwards, in `pending` order.
    const WriteTask = struct {
        e: *Emitter,
        failures: []?anyerror,

        fn write(t: WriteTask, w: *Worker, i: u32) Allocator.Error!void {
            const output = t.e.pending.items[i];
            const path = try t.e.outputFilePath(w.module.allocator(), output.path);
            Io.Dir.cwd().writeFile(t.e.session.io, .{ .sub_path = path, .data = output.bytes }) catch |err| {
                t.failures[i] = err;
            };
        }
    };
};

/// What a hand-written JavaScript file is called once the build has copied
/// it into the output tree. `backend.md` §2 requires every emitted file to be
/// `.mjs`; the `.foreign` part keeps the copy from colliding with the
/// generated module of the same name and says which half of the module it is.
pub const foreign_extension = ".foreign.mjs";

/// `Bir` instructions one emit worker is worth spawning for (`wanted`).
/// Lowering and printing get through about ten thousand instructions a millisecond,
/// so this is some 1.5 ms of work per thread, against a spawn and a
/// `Session.check_stack_size` mapping.
pub const insts_per_emitter = 16 * 1024;

/// The same for building the reachability edges (`Reach.Builder`), which
/// gets through about a hundred thousand instructions a millisecond.
pub const insts_per_edge_builder = 128 * 1024;

/// Output files one writing thread is worth, under the same rule: a file is
/// an open, a write and a close, some 20 µs.
pub const files_per_writer = 64;

/// Whether `name` is a legal entry file name (§2's rule 1, `boundary.md`
/// §5.2's `"entry"`): one path segment, a leading `_`, a trailing `.mjs`,
/// and ASCII letters, digits, `_` or `-` between.
///
/// The leading `_` is what does the work. A module path segment must be an
/// upper identifier, so it begins with an ASCII capital letter
/// (`SourceStore.isUpperIdent`) — and a name beginning with `_` is
/// therefore one no module can ever be written to, on a case-insensitive
/// file system included.
/// `text` as a double-quoted JavaScript string literal.
fn jsString(scratch: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    try out.append(scratch, '"');
    for (text) |c| switch (c) {
        '"' => try out.appendSlice(scratch, "\\\""),
        '\\' => try out.appendSlice(scratch, "\\\\"),
        0...0x1f => try out.print(scratch, "\\x{x:0>2}", .{c}),
        else => try out.append(scratch, c),
    };
    try out.append(scratch, '"');
}

fn entryNameIsLegal(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "_")) return false;
    if (!std.mem.endsWith(u8, name, ".mjs")) return false;
    const stem = name["_".len .. name.len - ".mjs".len];
    if (stem.len == 0) return false;
    for (stem) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}

/// `name` without `extension`, or `name` when it does not end in one.
fn stripExtension(name: []const u8, extension: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, name, extension))
        name[0 .. name.len - extension.len]
    else
        name;
}

/// Largest sibling or runtime file read. Privileged JavaScript is small by
/// construction — one export per foreign value — and a file past this is a
/// mistake worth failing on rather than allocating for.
pub const max_asset_bytes = 8 * 1024 * 1024;

fn find(haystack: []const Sibling.Export, needle: []const u8) ?Sibling.Export {
    for (haystack) |item| {
        if (std.mem.eql(u8, item.name, needle)) return item;
    }
    return null;
}

fn plural(n: u32) []const u8 {
    return if (n == 1) "" else "s";
}

/// How many parameters a `foreign` declaration's annotation lists, or null
/// when it has none to read. A non-function annotation is zero: `foreign pi
/// : Float` binds to a value and not to a `() => …`.
///
/// **It is `params`, read back.** `bir/Lower` counts a `foreign`'s
/// parameters off exactly this annotation and records them there
/// (`frontend.md` §3.6), so check 4 and `js/Lower.termArity` measure the
/// sibling against ONE number. Computing it a second time here is how the
/// two came to disagree: the backend eta-expanded `List.eq` at arity 0
/// while this check happily accepted its binary sibling.
fn containsDeclared(haystack: []const Emitter.Declared, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item.name, needle)) return true;
    }
    return false;
}

fn shortName(qualified: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, qualified, '.') orelse return qualified;
    return qualified[dot + 1 ..];
}

/// The module half of a manifest's `"program"` key (`Node.Program` →
/// `Node`), or the whole string when it names no module.
fn platformModule(qualified: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, qualified, '.') orelse return qualified;
    return qualified[0..dot];
}

/// The first type variable reachable from `inst`, or null when the type is
/// concrete. Iterative: a type is a tree the parser bounds, but the bound is
/// 4096 levels (language.md §10) and recursion here would be bounded by the
/// C stack instead of by the input.
///
/// **Total**: a fixed-size stack or a node budget would have to answer null
/// — "concrete", the ADMITTING answer — when it ran out, so a `foreign` value
/// of a record with 65 fields, one of them `a`, could pass the shape check.
/// The stack grows in `scratch` and the walk visits every node once, a type
/// being a tree.
fn firstTypeVar(scratch: Allocator, b: *const Bir, root: Bir.Inst.Index) Allocator.Error!?Bir.Inst.Index {
    var stack: std.ArrayList(Bir.Inst.Index) = .empty;
    defer stack.deinit(scratch);
    try stack.append(scratch, root);
    while (stack.pop()) |inst| {
        if (inst.int() >= b.insts.len) continue;
        const d = b.instData(inst);
        switch (b.instTag(inst)) {
            .type_var => return inst,
            .type_fn => {
                try stack.appendSlice(scratch, b.extraSlice(b.subRange(@enumFromInt(d.lhs)), Bir.Inst.Index));
                try stack.append(scratch, @enumFromInt(d.rhs));
            },
            .type_app => try stack.appendSlice(scratch, b.extraSlice(b.subRange(@enumFromInt(d.rhs)), Bir.Inst.Index)),
            .type_tuple => try stack.appendSlice(scratch, b.extraSlice(Bir.inlineRange(d), Bir.Inst.Index)),
            .type_record => for (b.extraSlice(Bir.inlineRange(d), Bir.Field)) |f| try stack.append(scratch, f.value),
            .type_record_ext => return @enumFromInt(d.lhs),
            else => {},
        }
    }
    return null;
}

/// The ESM specifier for `to` as written inside `from`. Both are paths under
/// the output root, so the answer is `../` once per directory `from` sits
/// in, then `to`. It always starts with `./` or `../`, because a bare
/// specifier is a package name in ESM and not a relative path.
/// The specifier of every module in `paths` as the file at `from` imports
/// it: built once per directory depth of `from` and cached in `by_depth`,
/// since `relativeSpecifier` reads nothing else of `from`.
fn specifierTable(
    arena: Allocator,
    by_depth: *std.ArrayList(?[]const []const u8),
    paths: []const []const u8,
    from: []const u8,
) Allocator.Error![]const []const u8 {
    const depth = std.mem.count(u8, from, "/");
    while (by_depth.items.len <= depth) try by_depth.append(arena, null);
    if (by_depth.items[depth]) |table| return table;
    const table = try arena.alloc([]const u8, paths.len);
    for (table, paths) |*slot, to| slot.* = try relativeSpecifier(arena, from, to);
    by_depth.items[depth] = table;
    return table;
}

fn relativeSpecifier(arena: Allocator, from: []const u8, to: []const u8) Allocator.Error![]const u8 {
    const depth = std.mem.count(u8, from, "/");
    var out: std.ArrayList(u8) = .empty;
    if (depth == 0) {
        try out.appendSlice(arena, "./");
    } else {
        for (0..depth) |_| try out.appendSlice(arena, "../");
    }
    try out.appendSlice(arena, to);
    return out.items;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "an ESM specifier is relative to the importing file's directory" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try testing.expectEqualStrings("./_core/List.mjs", try relativeSpecifier(arena, "Main.mjs", "_core/List.mjs"));
    try testing.expectEqualStrings("../_core/List.mjs", try relativeSpecifier(arena, "Dict/Int.mjs", "_core/List.mjs"));
    try testing.expectEqualStrings("../../Main.mjs", try relativeSpecifier(arena, "a/b/C.mjs", "Main.mjs"));
    try testing.expectEqualStrings("./Main.mjs", try relativeSpecifier(arena, "Other.mjs", "Main.mjs"));
}

test "an entry file name is one `_`-prefixed segment ending in .mjs" {
    // §2's rule 1: the leading `_` is the whole guarantee, because a module
    // path segment must start with an ASCII capital.
    try testing.expect(entryNameIsLegal("_main.mjs"));
    try testing.expect(entryNameIsLegal("_start.mjs"));
    try testing.expect(entryNameIsLegal("_index-2.mjs"));
    try testing.expect(entryNameIsLegal("__.mjs"));
    // The name the emitter used to hardcode, and the module it folded onto.
    try testing.expect(!entryNameIsLegal("main.mjs"));
    try testing.expect(!entryNameIsLegal("Main.mjs"));
    // A separator would put the entry under a directory subject to the same
    // rule, so it is refused rather than resolved.
    try testing.expect(!entryNameIsLegal("_a/_b.mjs"));
    try testing.expect(!entryNameIsLegal("../_main.mjs"));
    // Extension and stem.
    try testing.expect(!entryNameIsLegal("_main.js"));
    try testing.expect(!entryNameIsLegal("_main"));
    try testing.expect(!entryNameIsLegal(".mjs"));
    try testing.expect(!entryNameIsLegal("_.mjs"));
    try testing.expect(!entryNameIsLegal(""));
}

test "a qualified platform type shortens to its own name for the hint" {
    try testing.expectEqualStrings("Program", shortName("Node.Program"));
    try testing.expectEqualStrings("Program", shortName("Program"));
}
