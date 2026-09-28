//! The acceptance matrix of the serialized interface and the cache
//! (`fast-compiler.md` §8's interface hash, `plans/m4-slice-zero.md` §6).
//!
//! **The claim.** An incremental build's every output stream and output
//! file must be byte-identical to a cold build of the same source tree. So
//! for every corpus case of every kind that runs the checker, a plain run at
//! `--jobs=1` and a round-tripped one at `--jobs=8` (`variants`) must agree
//! byte for byte on exit code, stdout, stderr and every file written.
//!
//! This is the first test in the project that asserts the firewall's
//! premise rather than assuming it: until it passes, every claim about a
//! warm rebuild is unfalsifiable (`plans/m4-plan.md` §3.4). It also closes
//! the `--jobs` half of that cross, which `tests/corpus/README.md` claimed
//! and the corpus runner never did — it passes no `--jobs` at all, so the
//! determinism claim was carried entirely by a handful of synthetic
//! projects in `blackbox_test.zig` and `abuse_test.zig`.
//!
//! **Why it is its own binary, and parallel.** Every invocation checks the
//! embedded core package, and the matrix makes several of them per fixture
//! for some 600 fixtures. `zig build test-blackbox` already runs its test
//! binaries concurrently, so a separate binary that also spreads its own
//! cases over a pool of workers costs wall-clock time only where it
//! overlaps. Every fixture of every checker-driven kind is here.
//!
//! **What is NOT compared, and why.** The `--release` half of a `run/`
//! fixture: `--release` changes the BACKEND's printing and inlining, which
//! is downstream of the record in exactly the way the development build
//! already is, so a second axis over it would quadruple the most expensive
//! kind to re-assert what the dev build asserts. And the emitted program is
//! not executed here — `corpus_test.zig` runs it, twice; this binary's
//! claim is about bytes.
//!
//! **The cache axis** adds two more runs per fixture: a cold one at
//! `--jobs=1` into a cache directory that is fresh because the `World` is,
//! and a warm one at `--jobs=8` against it. Both are byte-compared with the
//! plain run, and both assert counters — the cold one hits nothing, and the
//! warm one re-checks no module of a fixture that compiles. The `--jobs`
//! cross is deliberate: a cache written at one worker count and read at
//! another is what would catch a `Symbol` reaching the bytes.
//!
//! `build/bad/` is here too, with no output tree to compare: a refused
//! build writes nothing, so its claim is that the DIAGNOSTICS of a refusal
//! are a function of the input and not of `--jobs` — which is the same
//! claim, for the streams a failing build has instead of files.

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const Io = std.Io;
const testing = std.testing;

const corpus_root = "tests/corpus";

/// The kinds `fast-compiler.md` §8 names: every corpus kind that runs the
/// checker. `parse/good`, `fmt` and `bir` stop before it and have no
/// interface record to round-trip; `parse/bad` runs `check`, but a file
/// that does not parse has no record either, and its fixtures are already
/// the slowest third of the corpus.
const Kind = enum {
    check_good,
    check_bad,
    check_args,
    check_depth,
    dispatch,
    build_bad,
    build_bad_release,
    run,
    emit,
    regress,

    fn dir(kind: Kind) []const u8 {
        return switch (kind) {
            .check_good => corpus_root ++ "/check/good",
            .check_bad => corpus_root ++ "/check/bad",
            .check_args => corpus_root ++ "/check/args",
            .check_depth => corpus_root ++ "/check/depth",
            .dispatch => corpus_root ++ "/dispatch",
            .build_bad => corpus_root ++ "/build/bad",
            .build_bad_release => corpus_root ++ "/build/bad-release",
            .run => corpus_root ++ "/run",
            .emit => corpus_root ++ "/emit",
            .regress => corpus_root ++ "/regress",
        };
    }

    fn hasProjects(kind: Kind) bool {
        return kind == .check_good or kind == .check_bad or kind == .dispatch or
            kind == .build_bad or kind == .build_bad_release or kind == .run;
    }

    /// Whether a fixture of this kind is COMPILED (its assertion is the
    /// output tree) rather than checked (its assertion is a stream).
    fn builds(kind: Kind) bool {
        return kind == .run or kind == .emit or kind == .build_bad or kind == .build_bad_release;
    }

    /// `build/bad-release/` adds `--release`, which is what its fixtures are
    /// about (`backend.md` §9's refusal of `Debug`).
    fn isRelease(kind: Kind) bool {
        return kind == .build_bad_release;
    }

    /// Whether every module of a fixture of this kind CHECKS clean, even
    /// when the build then fails.
    ///
    /// It is true of both refused-build kinds and it is the sharp claim the
    /// cache axis can make about them: `findEntry`, the sibling checks and
    /// `--release`'s `Debug` refusal all run inside `Emit.run`, long after
    /// `Session.run` has written the entries — so a build that exits 1 for
    /// any of those reasons has nonetheless cached every module, and a warm
    /// run of it re-checks NOTHING. `build/bad-release/` is the one that
    /// proves it rather than assuming it: `corpus_test.buildBad`'s fourth
    /// assertion requires the same project to build clean without the flag.
    fn checksClean(kind: Kind) bool {
        return kind == .build_bad or kind == .build_bad_release;
    }
};

/// The runs. Variant 0 is the baseline every other is compared with; it is
/// also the shape the corpus walker uses today, so a difference here is a
/// difference from the goldens.
const Variant = struct {
    label: []const u8,
    flags: []const []const u8,
};

/// The round-tripped variant passes ALL THREE flags, so the dispatch
/// sidecar's format and the front-end artifact's are proven lossless over the
/// same fixtures at no extra runs. They belong together: a `run/` fixture
/// whose emitted JavaScript is byte-identical through the record, through the
/// table AND through the `Bir` that was written to bytes and read back before
/// `Resolve` ever saw it is the strongest single claim available about any of
/// them. The sidecar is the one whose loss shows up as a wrong program rather
/// than a wrong message; the front-end artifact is the one whose loss shows
/// up as a wrong program that depends on HISTORY, which is worse.
///
/// It runs at `--jobs=8` against a `--jobs=1` baseline, so one run crosses
/// both axes: a difference from either the worker count or the round trip
/// moves its bytes. Running each axis alone as well would only say which of
/// the two moved them, which the failure's own diff is enough to find.
///
/// **The first two pass `--no-cache` explicitly**, and they must. The cache
/// is on by default, these fixtures run with cwd = the repo root, and variant
/// 0 is the ORACLE every other variant is byte-compared against — so without
/// the flag the oracle would be a run whose behaviour depended on a
/// `.beni-cache/` left by whatever ran before it. A golden compared against
/// something history-dependent is not a golden. The cached path has variants
/// 2 and 3, which name their own fresh directory.
const variants = [_]Variant{
    .{ .label = "cold --jobs=1", .flags = &.{ "--jobs=1", "--no-cache" } },
    .{ .label = "round-tripped --jobs=8", .flags = &.{ "--jobs=8", "--no-cache", "--roundtrip-interfaces", "--roundtrip-dispatch", "--roundtrip-frontend" } },
    // The cache axis (`fast-compiler.md` §8): a COLD-WITH-CACHE run at
    // `--jobs=1` into a fresh directory, then a WARM one at `--jobs=8`
    // against it. Both must be byte-identical to variant 0 on every stream
    // and every file written.
    //
    // Two runs and not four: the `--jobs` cross rides on the pair, and it is
    // deliberate — a cache written at one worker count and read at another
    // is what would catch a `Symbol` reaching the bytes.
    //
    // `{cache}` in a flag is replaced with this fixture's own cache
    // directory, which is fresh per fixture because a `World` is.
    .{ .label = "cold into a cache --jobs=1", .flags = &.{ "--jobs=1", "--cache-dir={cache}" } },
    .{ .label = "warm from the cache --jobs=8", .flags = &.{ "--jobs=8", "--cache-dir={cache}" } },
};

/// Variant index of the first cached run. From here on the runs assert
/// counters as well as bytes.
const first_cached_variant = 2;

/// `{cache}` replaced by an ABSOLUTE path inside this fixture's own temp
/// tree, and `--self-profile` appended so the counters can be read.
///
/// Absolute and not relative because the stream fixtures run with cwd = the
/// repo root, exactly as the corpus walker runs them — a relative cache
/// directory would be created in the repository.
fn expandFlags(
    arena: std.mem.Allocator,
    w: *World,
    flags: []const []const u8,
    variant: usize,
    out: *std.ArrayList([]const u8),
) ![]const u8 {
    const root = try w.projectPath();
    var profile: []const u8 = &.{};
    for (flags) |flag| {
        if (std.mem.eql(u8, flag, "--cache-dir={cache}")) {
            try out.append(arena, try std.fmt.allocPrint(arena, "--cache-dir={s}/_cache", .{root}));
            profile = try std.fmt.allocPrint(arena, "{s}/_p{d}.json", .{ root, variant });
            try out.append(arena, try std.fmt.allocPrint(arena, "--self-profile={s}", .{profile}));
            continue;
        }
        try out.append(arena, flag);
    }
    return profile;
}

const Counters = struct {
    hits: u64 = 0,
    checked: u64 = 0,
    /// The front end's three, and the reason the warm run asserts anything at all
    /// beyond byte equality: a front end that ran and produced the same
    /// answer is indistinguishable from one that did not run.
    files: u64 = 0,
    lexed: u64 = 0,
    parsed: u64 = 0,
    lowered: u64 = 0,
    frontend_hits: u64 = 0,
    /// The checker's derived-context fixpoints (`derived_context_runs`): a
    /// warm run that checks no module derives nothing.
    derived: u64 = 0,
};

fn readCounters(arena: std.mem.Allocator, path: []const u8) !Counters {
    const Event = struct {
        ph: []const u8,
        args: struct {
            cache_hits: ?u64 = null,
            modules_checked: ?u64 = null,
            files: ?u64 = null,
            files_lexed: ?u64 = null,
            files_parsed: ?u64 = null,
            files_lowered: ?u64 = null,
            frontend_hits: ?u64 = null,
            derived_context_runs: ?u64 = null,
        } = .{},
    };
    const text = try Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(world.max_stream_bytes));
    const parsed = try std.json.parseFromSlice(
        struct { traceEvents: []Event },
        arena,
        text,
        .{ .ignore_unknown_fields = true },
    );
    var out: Counters = .{};
    for (parsed.value.traceEvents) |e| {
        if (!std.mem.eql(u8, e.ph, "C")) continue;
        if (e.args.cache_hits) |v| out.hits = v;
        if (e.args.modules_checked) |v| out.checked = v;
        if (e.args.files) |v| out.files = v;
        if (e.args.files_lexed) |v| out.lexed = v;
        if (e.args.files_parsed) |v| out.parsed = v;
        if (e.args.files_lowered) |v| out.lowered = v;
        if (e.args.frontend_hits) |v| out.frontend_hits = v;
        if (e.args.derived_context_runs) |v| out.derived = v;
    }
    return out;
}

/// What the two cached runs have to report, beyond byte equality.
///
/// The cold one hits nothing — the directory is this fixture's own and is
/// fresh. The warm one re-checks NO clean module, which for a fixture that
/// exits 0 means zero modules checked at all.
///
/// A fixture that exits 1 or 2 divides in two. When the CHECK is what
/// failed, its broken modules are uncacheable by construction and are
/// re-checked every time, so the claim is the byte equality alone. When the
/// check passed and the BUILD refused — a missing `main`, a sibling that
/// does not match, `--release` reaching `Debug` — every module was cached
/// all the same, because all three of those run inside `Emit.run` after
/// `Session.run` wrote the entries, and the warm run checks none.
/// `Kind.checksClean` is which is which.
fn expectCacheCounters(f: Fixture, v: Variant, variant: usize, baseline_exit: u8, c: Counters) !void {
    if (variant == first_cached_variant) {
        if (c.hits != 0 or c.frontend_hits != 0) {
            std.debug.print(
                "{s}/{s}: the cold-with-cache run reported {d} module hits and {d} file hits\n",
                .{ f.dir, f.name, c.hits, c.frontend_hits },
            );
            return error.MatrixDiffers;
        }
        // A COLD run does all the front-end work, every file of it. This is
        // the floor the warm assertion below is measured against: without it
        // "the front end did not run" could be true because there was no
        // front end to run (`fast-compiler.md` §8).
        if (c.files == 0 or c.lexed != c.files or c.parsed != c.files or c.lowered != c.files) {
            std.debug.print(
                "{s}/{s}: a cold run over {d} files lexed {d}, parsed {d} and lowered {d}\n",
                .{ f.dir, f.name, c.files, c.lexed, c.parsed, c.lowered },
            );
            return error.MatrixDiffers;
        }
        return;
    }

    // The warm run. Every file is either a hit or was lowered again, on
    // every fixture — including the ones that do not compile, where what was
    // lowered again is exactly the files whose front end errored and were
    // therefore never written.
    if (c.frontend_hits + c.lowered != c.files or c.lexed != c.lowered or c.parsed != c.lowered) {
        std.debug.print(
            "{s}/{s}: {s} over {d} files hit {d} and lexed/parsed/lowered {d}/{d}/{d}\n",
            .{ f.dir, f.name, v.label, c.files, c.frontend_hits, c.lexed, c.parsed, c.lowered },
        );
        return error.MatrixDiffers;
    }
    // On a fixture that compiles, NOTHING is lexed, parsed or lowered. That
    // is the front-end cache's acceptance test, and it is a counter rather than a
    // timing on purpose.
    if (baseline_exit == 0 and c.lowered != 0) {
        std.debug.print(
            "{s}/{s}: {s} re-lowered {d} files of a fixture that compiles\n",
            .{ f.dir, f.name, v.label, c.lowered },
        );
        return error.MatrixDiffers;
    }

    if (baseline_exit != 0 and !f.kind.checksClean()) return;
    if (c.checked != 0 or c.hits == 0 or c.derived != 0) {
        std.debug.print(
            "{s}/{s}: {s} re-checked {d} modules, hit {d} and ran {d} derived-context fixpoints; a warm run of a clean fixture must check and derive none\n",
            .{ f.dir, f.name, v.label, c.checked, c.hits, c.derived },
        );
        return error.MatrixDiffers;
    }
}

const Fixture = struct {
    kind: Kind,
    dir: []const u8,
    name: []const u8,
    core: bool,
    project: bool = false,
    /// Under `emit/app/`: an application build, so elimination is rooted at
    /// `main` instead of at every export.
    app: bool = false,
    /// Under `emit/release/`.
    release: bool = false,
};

test "the acceptance matrix: cold and round-tripped agree at every --jobs" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixtures: std.ArrayList(Fixture) = .empty;
    inline for (@typeInfo(Kind).@"enum".fields) |field| {
        const kind: Kind = @enumFromInt(field.value);
        try collect(arena, kind, kind.dir(), false, &fixtures, .{});
        try collect(arena, kind, try std.fs.path.join(arena, &.{ kind.dir(), "core" }), true, &fixtures, .{});
        if (kind == .emit) {
            try collect(arena, kind, try std.fs.path.join(arena, &.{ kind.dir(), "app" }), false, &fixtures, .{ .app = true, .projects = true });
            try collect(arena, kind, try std.fs.path.join(arena, &.{ kind.dir(), "release" }), false, &fixtures, .{ .release = true, .projects = true });
        }
    }
    // A matrix over nothing would pass.
    try testing.expect(fixtures.items.len > 200);

    var runner: Runner = .{ .gpa = gpa, .fixtures = fixtures.items };
    const workers = @min(16, @max(1, std.Thread.getCpuCount() catch 1));
    {
        var threads: std.ArrayList(std.Thread) = .empty;
        defer threads.deinit(gpa);
        defer for (threads.items) |t| t.join();
        for (0..workers) |_| {
            try threads.append(gpa, try std.Thread.spawn(.{}, Runner.work, .{&runner}));
        }
    }
    if (runner.failures.load(.monotonic) != 0) {
        std.debug.print(
            "acceptance matrix: {d} of {d} fixtures differ between a cold run and a round-tripped one\n",
            .{ runner.failures.load(.monotonic), fixtures.items.len },
        );
        return error.MatrixFailures;
    }
}

const CollectOptions = struct {
    app: bool = false,
    release: bool = false,
    /// `emit/app/` and `emit/release/` take project directories too: "a
    /// module vanishes" needs a second module to vanish.
    projects: bool = false,
};

/// Every `.beni` directly under `dir_path`, sorted, plus the project
/// subdirectories for the kinds that have them. A missing directory is not
/// an error — `core/` is optional for every kind.
fn collect(
    arena: std.mem.Allocator,
    kind: Kind,
    dir_path: []const u8,
    core: bool,
    out: *std.ArrayList(Fixture),
    options: CollectOptions,
) !void {
    const io = testing.io;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    const start = out.items.len;
    const projects = kind.hasProjects() or options.projects;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory and projects and !std.mem.eql(u8, entry.name, "core")) {
            try out.append(arena, .{
                .kind = kind,
                .dir = dir_path,
                .name = try arena.dupe(u8, entry.name),
                .core = core,
                .project = true,
                .app = options.app,
                .release = options.release,
            });
            continue;
        }
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".beni")) continue;
        try out.append(arena, .{
            .kind = kind,
            .dir = dir_path,
            .name = try arena.dupe(u8, entry.name),
            .core = core,
            .app = options.app,
            .release = options.release,
        });
    }
    std.mem.sort(Fixture, out.items[start..], {}, struct {
        fn lessThan(_: void, a: Fixture, b: Fixture) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
}

/// Fixtures pulled from one atomic counter, exactly as the compiler's own
/// workers pull files: which worker takes which fixture is unobservable,
/// because every case's verdict is its own.
const Runner = struct {
    gpa: std.mem.Allocator,
    fixtures: []const Fixture,
    next: std.atomic.Value(usize) = .init(0),
    failures: std.atomic.Value(u32) = .init(0),

    fn work(r: *Runner) void {
        while (true) {
            const i = r.next.fetchAdd(1, .monotonic);
            if (i >= r.fixtures.len) return;
            const f = r.fixtures[i];
            one(r.gpa, f) catch |err| {
                std.debug.print("MATRIX FAIL {s}/{s}: {t}\n", .{ f.dir, f.name, err });
                _ = r.failures.fetchAdd(1, .monotonic);
            };
        }
    }
};

/// One fixture through the whole cross. A fresh `World` per fixture: a
/// build writes an output tree and a stale file from the previous fixture
/// would be compared as if this build had written it.
fn one(gpa: std.mem.Allocator, f: Fixture) !void {
    var w = try World.init(gpa, testing.io);
    defer w.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (f.kind == .build_bad or f.kind == .build_bad_release) return failedBuildMatrix(&w, arena, f);
    if (f.kind.builds()) return buildMatrix(&w, arena, f);

    const path = try std.fs.path.join(arena, &.{ f.dir, f.name });
    // The diagnostics, then the record's own bytes, then the rendering the
    // `.iface` golden is. `--stage=raw` is the one that can see a byte
    // difference the two pretty printers hide (`Cli.Stage`), which is why
    // it is here for every kind and not only the ones with a golden.
    try streamMatrix(&w, arena, f, &.{ "check", "--diagnostics=json", path });
    try streamMatrix(&w, arena, f, &.{ "dump", "--stage=raw", path });
    if (f.kind == .check_good) try streamMatrix(&w, arena, f, &.{ "dump", "--stage=interface", path });
    if (f.kind == .dispatch) try streamMatrix(&w, arena, f, &.{ "dump", "--stage=dispatch", path });
}

/// One command every way `variants` lists, compared on exit code, stdout and
/// stderr. Run with cwd = the repo root, as the corpus walker runs it, so the
/// paths in the diagnostics are the repo-relative ones the goldens hold.
fn streamMatrix(w: *World, arena: std.mem.Allocator, f: Fixture, args: []const []const u8) !void {
    // `dump` takes no cache flag at all — it prints a representation rather
    // than a result (`frontend.md` §1) — so the cache axis applies to the
    // `check` invocations and the dumps keep the two uncached ones.
    const cached_axis = std.mem.eql(u8, args[0], "check");
    var base: ?world.Result = null;
    for (variants, 0..) |v, i| {
        if (i >= first_cached_variant and !cached_axis) break;
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, args);
        const profile = try expandFlags(arena, w, v.flags, i, &argv);
        if (f.core) try argv.append(arena, "--core");
        const r = try w.runWith(argv.items, .{ .raw_diagnostics = true, .cwd = .inherit });
        const b = base orelse {
            base = r;
            continue;
        };
        try expectSame(f, v, args[0], "exit code", b.exit_code, r.exit_code);
        try expectSameBytes(f, v, args[0], "stdout", b.stdout, r.stdout);
        try expectSameBytes(f, v, args[0], "stderr", b.stderr, r.stderr);
        if (profile.len != 0) {
            try expectCacheCounters(f, v, i, b.exit_code, try readCounters(arena, profile));
        }
    }
}

/// A `build/bad/` project every way: the whole fixture tree is the project
/// (`corpus_test.buildBad`), and a `platform/` subdirectory means
/// `--platform=platform`. There is no output tree to compare — the build
/// fails and §4 says it writes nothing — so the claim is the one that
/// matters for a refusal: the DIAGNOSTICS a rejected build prints do not
/// move with `--jobs`, with a round-tripped record, or with a cache.
///
/// `build/bad-release/` comes through here too, with `--release` added. It
/// is the sharpest fixture the cache axis has for a failing build: its
/// project checks CLEAN — `corpus_test.buildBad`'s fourth assertion proves
/// it by building the same sources without the flag — so every module is
/// cached, the refusal happens afterwards inside `Emit.run`, and the warm
/// run re-checks nothing while still printing the same refusal.
fn failedBuildMatrix(w: *World, arena: std.mem.Allocator, f: Fixture) !void {
    const dir_path = try std.fs.path.join(arena, &.{ f.dir, f.name });
    try w.copyTree(dir_path, "_expected.");

    var sources: std.ArrayList([]const u8) = .empty;
    var dir = try Io.Dir.cwd().openDir(testing.io, dir_path, .{ .iterate = true });
    defer dir.close(testing.io);
    var has_platform = false;
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (entry.kind == .directory and std.mem.eql(u8, entry.name, "platform")) has_platform = true;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".beni")) continue;
        try sources.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, sources.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var base: ?world.Result = null;
    for (variants, 0..) |v, i| {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{
            "build",
            "--diagnostics=json",
            if (has_platform) "--platform=platform" else "--platform=node",
            "--out=out",
        });
        if (f.kind.isRelease()) try argv.append(arena, "--release");
        const profile = try expandFlags(arena, w, v.flags, i, &argv);
        try argv.appendSlice(arena, sources.items);
        const r = try w.runWith(argv.items, .{ .raw_diagnostics = true });
        const b = base orelse {
            base = r;
            continue;
        };
        try expectSame(f, v, "build", "exit code", b.exit_code, r.exit_code);
        try expectSameBytes(f, v, "build", "stdout", b.stdout, r.stdout);
        try expectSameBytes(f, v, "build", "stderr", b.stderr, r.stderr);
        if (profile.len != 0) {
            try expectCacheCounters(f, v, i, b.exit_code, try readCounters(arena, profile));
        }
    }
}

/// One fixture compiled every way `variants` lists, each into an output
/// directory of its own, compared on the streams AND on every file written.
/// The fixture is copied into the world's project directory for the reason
/// the corpus walker copies it: the module name comes from the path, and a
/// build writes an `out/` that has no business in the repository.
fn buildMatrix(w: *World, arena: std.mem.Allocator, f: Fixture) !void {
    var sources: std.ArrayList([]const u8) = .empty;
    if (f.project) {
        const dir_path = try std.fs.path.join(arena, &.{ f.dir, f.name });
        var dir = try Io.Dir.cwd().openDir(testing.io, dir_path, .{ .iterate = true });
        defer dir.close(testing.io);
        var it = dir.iterate();
        while (try it.next(testing.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".beni")) continue;
            try sources.append(arena, try arena.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, sources.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
        for (sources.items) |name| {
            const p = try std.fs.path.join(arena, &.{ dir_path, name });
            try w.write(name, try Io.Dir.cwd().readFileAlloc(testing.io, p, arena, .limited(world.max_stream_bytes)));
        }
    } else {
        const p = try std.fs.path.join(arena, &.{ f.dir, f.name });
        try w.write(f.name, try Io.Dir.cwd().readFileAlloc(testing.io, p, arena, .limited(world.max_stream_bytes)));
        try sources.append(arena, f.name);
    }

    var base: ?world.Result = null;
    var base_dir: []const u8 = &.{};
    for (variants, 0..) |v, i| {
        const out_dir = try std.fmt.allocPrint(arena, "out{d}", .{i});
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ "build", "--platform=node" });
        try argv.append(arena, try std.fmt.allocPrint(arena, "--out={s}", .{out_dir}));
        // `emit/` builds with `--library` unless it is under `emit/app/`
        // (backend.md §9, §12); `run/` is always an application.
        if (f.kind == .emit and !f.app) try argv.append(arena, "--library");
        if (f.release) try argv.append(arena, "--release");
        const profile = try expandFlags(arena, w, v.flags, i, &argv);
        if (f.core) try argv.append(arena, "--core");
        try argv.appendSlice(arena, sources.items);

        const r = try w.runWith(argv.items, .{ .raw_diagnostics = true });
        const b = base orelse {
            base = r;
            base_dir = out_dir;
            continue;
        };
        if (profile.len != 0) {
            try expectCacheCounters(f, v, i, b.exit_code, try readCounters(arena, profile));
        }
        try expectSame(f, v, "build", "exit code", b.exit_code, r.exit_code);
        try expectSameBytes(f, v, "build", "stdout", b.stdout, r.stdout);
        try expectSameBytes(f, v, "build", "stderr", b.stderr, r.stderr);
        try expectSameTree(w, arena, f, v, base_dir, out_dir);
    }
}

/// Every file under `want_dir` is under `got_dir`, with the same name and
/// the same bytes, and there is nothing extra. Not "the files this test
/// thought to name": a module that appears or vanishes under the flag is
/// exactly the sort of difference the matrix exists to catch.
fn expectSameTree(
    w: *World,
    arena: std.mem.Allocator,
    f: Fixture,
    v: Variant,
    want_dir: []const u8,
    got_dir: []const u8,
) !void {
    const want = try w.listFiles(want_dir);
    const got = try w.listFiles(got_dir);
    if (want.len != got.len) {
        std.debug.print(
            "{s}/{s}: {s} wrote {d} files, the cold build wrote {d}\n",
            .{ f.dir, f.name, v.label, got.len, want.len },
        );
        return error.OutputTreeDiffers;
    }
    for (want, got) |a, b| {
        try expectSameBytes(f, v, "build", "an output path", a, b);
        const want_bytes = try w.read(try std.fs.path.join(arena, &.{ want_dir, a }));
        const got_bytes = try w.read(try std.fs.path.join(arena, &.{ got_dir, b }));
        expectSameBytes(f, v, a, "the emitted bytes", want_bytes, got_bytes) catch |err| {
            std.debug.print("{s}/{s}: {s} emitted a different {s}\n", .{ f.dir, f.name, v.label, a });
            return err;
        };
    }
}

fn expectSame(f: Fixture, v: Variant, what: []const u8, field: []const u8, want: anytype, got: @TypeOf(want)) !void {
    if (want == got) return;
    std.debug.print(
        "{s}/{s}: `{s}` {s} is {any} under {s} and {any} cold\n",
        .{ f.dir, f.name, what, field, got, v.label, want },
    );
    return error.MatrixDiffers;
}

fn expectSameBytes(f: Fixture, v: Variant, what: []const u8, field: []const u8, want: []const u8, got: []const u8) !void {
    if (std.mem.eql(u8, want, got)) return;
    std.debug.print(
        "{s}/{s}: `{s}` {s} moved under {s}\n--- cold ---\n{s}\n--- round-tripped ---\n{s}\n",
        .{ f.dir, f.name, what, field, v.label, want, got },
    );
    return error.MatrixDiffers;
}
