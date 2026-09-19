//! The acceptance matrix of M4 slice zero (`fast-compiler.md` §8's *The
//! interface hash, and slice zero*, `plans/m4-slice-zero.md` §6).
//!
//! **The claim.** An incremental build's every output stream and output
//! file must be byte-identical to a cold build of the same source tree. So
//! for every corpus case of every kind that runs the checker, four runs —
//! {plain, `--roundtrip-interfaces`} × {`--jobs=1`, `--jobs=8`} — must
//! agree byte for byte on exit code, stdout, stderr and every file written.
//!
//! This is the first test in the project that asserts the firewall's
//! premise rather than assuming it: until it passes, every claim about a
//! warm rebuild is unfalsifiable (`plans/m4-plan.md` §3.4). It also closes
//! the `--jobs` half of that cross, which `tests/corpus/README.md` claimed
//! and the corpus runner never did — it passes no `--jobs` at all, so the
//! determinism claim was carried entirely by a handful of synthetic
//! projects in `blackbox_test.zig` and `abuse_test.zig`.
//!
//! **Why it is its own binary, and parallel.** One invocation of the
//! installed (Debug) compiler costs ~100 ms, almost all of it lexing,
//! parsing and checking the embedded core package, and the cross adds three
//! runs to every primary invocation of ~600 of them. Serially that is ~4
//! minutes on top of a 86-second suite. `zig build test-blackbox` already
//! runs its test binaries concurrently, so a separate binary that also
//! spreads its own cases over a pool of workers costs wall-clock time only
//! where it overlaps — measured at +6 s of `test-blackbox`, against ~240 s
//! of work. No coverage is traded for it: every fixture of every
//! checker-driven kind is here.
//!
//! **What is NOT compared, and why.** The `--release` half of a `run/`
//! fixture: `--release` changes the BACKEND's printing and inlining, which
//! is downstream of the record in exactly the way the development build
//! already is, so a second axis over it would quadruple the most expensive
//! kind to re-assert what the dev build asserts. And the emitted program is
//! not executed here — `corpus_test.zig` runs it, twice; this binary's
//! claim is about bytes.
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
            .run => corpus_root ++ "/run",
            .emit => corpus_root ++ "/emit",
            .regress => corpus_root ++ "/regress",
        };
    }

    fn hasProjects(kind: Kind) bool {
        return kind == .check_good or kind == .check_bad or kind == .dispatch or kind == .build_bad;
    }

    /// Whether a fixture of this kind is COMPILED (its assertion is the
    /// output tree) rather than checked (its assertion is a stream).
    fn builds(kind: Kind) bool {
        return kind == .run or kind == .emit or kind == .build_bad;
    }
};

/// The four runs. Variant 0 is the baseline every other is compared with;
/// it is also the shape the corpus walker uses today, so a difference here
/// is a difference from the goldens.
const Variant = struct {
    label: []const u8,
    flags: []const []const u8,
};

/// The round-tripped variants pass BOTH flags, so the dispatch sidecar's
/// format is proven lossless over the same fixtures at no extra runs
/// (`plans/m4-1.md` M1-d). The two belong together: a `run/` fixture whose
/// emitted JavaScript is byte-identical through the record AND through the
/// table is the strongest single claim available about either, and the
/// sidecar is the one whose loss shows up as a wrong program rather than a
/// wrong message.
const variants = [_]Variant{
    .{ .label = "cold --jobs=1", .flags = &.{"--jobs=1"} },
    .{ .label = "cold --jobs=8", .flags = &.{"--jobs=8"} },
    .{ .label = "round-tripped --jobs=1", .flags = &.{ "--jobs=1", "--roundtrip-interfaces", "--roundtrip-dispatch" } },
    .{ .label = "round-tripped --jobs=8", .flags = &.{ "--jobs=8", "--roundtrip-interfaces", "--roundtrip-dispatch" } },
};

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
    const workers = @min(8, @max(1, std.Thread.getCpuCount() catch 1));
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

    if (f.kind == .build_bad) return failedBuildMatrix(&w, arena, f);
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

/// One command, four ways, compared on exit code, stdout and stderr. Run
/// with cwd = the repo root, as the corpus walker runs it, so the paths in
/// the diagnostics are the repo-relative ones the goldens hold.
fn streamMatrix(w: *World, arena: std.mem.Allocator, f: Fixture, args: []const []const u8) !void {
    var base: ?world.Result = null;
    for (variants) |v| {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, args);
        try argv.appendSlice(arena, v.flags);
        if (f.core) try argv.append(arena, "--core");
        const r = try w.runWith(argv.items, .{ .raw_diagnostics = true, .cwd = .inherit });
        const b = base orelse {
            base = r;
            continue;
        };
        try expectSame(f, v, args[0], "exit code", b.exit_code, r.exit_code);
        try expectSameBytes(f, v, args[0], "stdout", b.stdout, r.stdout);
        try expectSameBytes(f, v, args[0], "stderr", b.stderr, r.stderr);
    }
}

/// A `build/bad/` project four ways: the whole fixture tree is the project
/// (`corpus_test.buildBad`), and a `platform/` subdirectory means
/// `--platform=platform`. There is no output tree to compare — the build
/// fails and §4 says it writes nothing — so the claim is the one that
/// matters for a refusal: the DIAGNOSTICS a rejected build prints do not
/// move with `--jobs` or with a round-tripped interface record.
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
    for (variants) |v| {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{
            "build",
            "--diagnostics=json",
            if (has_platform) "--platform=platform" else "--platform=node",
            "--out=out",
        });
        try argv.appendSlice(arena, v.flags);
        try argv.appendSlice(arena, sources.items);
        const r = try w.runWith(argv.items, .{ .raw_diagnostics = true });
        const b = base orelse {
            base = r;
            continue;
        };
        try expectSame(f, v, "build", "exit code", b.exit_code, r.exit_code);
        try expectSameBytes(f, v, "build", "stdout", b.stdout, r.stdout);
        try expectSameBytes(f, v, "build", "stderr", b.stderr, r.stderr);
    }
}

/// One fixture compiled four ways into four output directories, compared on
/// the streams AND on every file written. The fixture is copied into the
/// world's project directory for the reason the corpus walker copies it:
/// the module name comes from the path, and a build writes an `out/` that
/// has no business in the repository.
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
        try argv.appendSlice(arena, v.flags);
        if (f.core) try argv.append(arena, "--core");
        try argv.appendSlice(arena, sources.items);

        const r = try w.runWith(argv.items, .{ .raw_diagnostics = true });
        const b = base orelse {
            base = r;
            base_dir = out_dir;
            continue;
        };
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
