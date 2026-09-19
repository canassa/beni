//! The corpus walker (docs/design/frontend.md §7): the directory is the
//! assertion. One case per `.beni` under `tests/corpus/`, named by its path,
//! so adding a test is dropping in a file.
//!
//!   parse/good/X.beni + X.ast       `dump --stage=ast` equals the golden and
//!                                   stderr is empty (no diagnostic at all)
//!   parse/bad/X.beni  + X.diag      `check --diagnostics=json` equals the golden;
//!                                   a `.beni` WITHOUT `.diag` is a failure
//!   fmt/X.beni        + X.expected  `fmt --stdout` equals the golden, formatting
//!                                   the golden again is a fixed point, and both
//!                                   parse to the same AST
//!   bir/X.beni        + X.bir       `dump --stage=bir` equals the golden
//!   dispatch/X.beni   + X.dispatch  `dump --stage=dispatch` equals the golden
//!   check/good/X.beni + X.iface     `check` exits 0 and `dump --stage=interface`
//!                                   equals the golden; an optional X.diag holds
//!                                   the `warning`s it is allowed to print
//!   check/args/X.beni + X.diag      the arity suite (checker.md §8.3)
//!   run/X.beni        + X.expected  `build --platform=node`, then the emitted
//!                                   program under Node; its stdout is the golden.
//!                                   Built and run TWICE — once as today and once
//!                                   with `--release` — against the same golden,
//!                                   unless X.release-expected exists (backend.md
//!                                   §9's *Testing*, §12)
//!   emit/X.beni       + X.js        `build --platform=node`, then the module's
//!                                   own `.mjs` is the golden (backend.md §12)
//!   emit/release/X.beni + X.js      the same, with `--release` added: the golden
//!                                   is a shape claim about the optimiser (§9)
//!   check/depth/XOk.beni            checks clean: one level UNDER a guard
//!   check/depth/XDeep.beni + .diag  one level OVER it, and says so
//!   build/bad/X/ (a directory)      a whole project that must FAIL to build:
//!                                   exit 1, `_expected.diag` is the whole
//!                                   diagnostic list, and no `out/` is written
//!   regress/X.beni    + .diag|.ast  behaves as bad or good by which golden exists
//!
//! A fixture under a `core/` subdirectory of its kind (`bir/core/Foreign.beni`)
//! is run with `--core` added to the argv (language.md §5.4); its goldens sit
//! next to it in that subdirectory. Every kind has this.
//!
//! `BENI_WRITE_EXPECTED=1` blesses: goldens are (re)written from the actual
//! output, which is fully materialised before any file is touched. The
//! failure message says so. `BENI_BLESS_ONLY=<substring>` limits blessing to
//! the fixtures whose repo-relative path contains the substring (the rest
//! are compared as usual), so one kind — or one file — can be pinned while
//! the goldens a later milestone owns stay unwritten. Exit codes are asserted exactly and never
//! special-cased: while `dump` and `fmt` return 2 (M1 lands them), any
//! fixture in those kinds fails — which is correct, and why the directories
//! are empty except for their READMEs until then.

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const Io = std.Io;
const testing = std.testing;

const corpus_root = "tests/corpus";

const Kind = enum {
    parse_good,
    parse_bad,
    fmt,
    bir,
    dispatch,
    check_good,
    check_bad,
    check_args,
    check_depth,
    build_bad,
    run,
    emit,
    regress,

    fn dir(kind: Kind) []const u8 {
        return switch (kind) {
            .parse_good => corpus_root ++ "/parse/good",
            .parse_bad => corpus_root ++ "/parse/bad",
            .fmt => corpus_root ++ "/fmt",
            .bir => corpus_root ++ "/bir",
            .dispatch => corpus_root ++ "/dispatch",
            .check_good => corpus_root ++ "/check/good",
            .check_bad => corpus_root ++ "/check/bad",
            .check_args => corpus_root ++ "/check/args",
            .check_depth => corpus_root ++ "/check/depth",
            .build_bad => corpus_root ++ "/build/bad",
            .run => corpus_root ++ "/run",
            .emit => corpus_root ++ "/emit",
            .regress => corpus_root ++ "/regress",
        };
    }

    /// Whether a subdirectory of the kind is a PROJECT fixture rather than
    /// the `core/` flag directory every kind has.
    fn hasProjects(kind: Kind) bool {
        return kind == .check_good or kind == .check_bad or kind == .dispatch or kind == .build_bad;
    }
};

test "corpus: parse/good" {
    try walk(.parse_good);
}

test "corpus: parse/bad" {
    try walk(.parse_bad);
}

test "corpus: fmt" {
    try walk(.fmt);
}

test "corpus: bir" {
    try walk(.bir);
}

// The checker→backend side table (static-dispatch-spike.md §7). Its own
// kind for the reason `bir/` is one: it is an OUTPUT of a phase, printed
// with no ids and no positions, and a golden here is the contract S4 and S5
// lower against. A method call that resolved to the wrong function is
// invisible in `--stage=types` and obvious here.
test "corpus: dispatch" {
    try walk(.dispatch);
}

test "corpus: check/good" {
    try walk(.check_good);
}

test "corpus: check/bad" {
    try walk(.check_bad);
}

// The arity suite (checker.md §8.3). Its own kind so its size and its pass
// rate are visible on their own: an arity mistake is the class currying
// could not localise, these are the messages that replaced it, and a number
// buried in `check/bad` is a number nobody looks at.
test "corpus: check/args" {
    try walk(.check_args);
}

// The depth sweep (checker.md §5, §7). Its own kind because the assertion
// is a PAIR, not a file: every guard that can stop the checker reading a
// type gets a fixture one level under it that must check clean and one
// level over it that must produce a diagnostic. Each of those guards used
// to poison the type and say nothing, and a poisoned type unifies with
// anything — so the declaration became a hole and a caller's mistake
// compiled clean, which is the one failure mode a compiler may not have.
//
// The pairing is enforced mechanically below rather than left to whoever
// adds a fixture: a `…Ok` file with a golden, or a `…Deep` file without
// one, is a failure. `generate.sh` in the directory rebuilds them all and
// records the measured boundary of each guard.
test "corpus: check/depth" {
    try walk(.check_depth);
}

// The second boundary (backend.md §12, and the whole reason boundary.md §8
// puts the Node platform before the optimiser): compile the fixture, run the
// emitted JavaScript under Node, and assert what it PRINTED. This is what
// Elm's deleted suite never had. A change that alters emitted shape but not
// behaviour leaves every one of these green; a change that alters behaviour
// fails one, by name.
// A BUILD that must fail (`boundary.md` §4, §5). Its own kind because two
// things no other kind can say are said here: the fixture carries its own
// PLATFORM PACKAGE, which is what makes §4's four sibling checks reachable
// at all, and the assertion is a build rather than a check — `check
// --platform` deliberately does not look for `main`, so `missing_main`,
// `main_not_program` and `duplicate_main` have no other kind to live in.
// Nine diagnostic codes were blackbox-only for exactly these two reasons
// (`plans/coverage-audit.md` Part A).
test "corpus: build/bad" {
    try walk(.build_bad);
}

test "corpus: run" {
    try walk(.run);
}

// The shape corpus (backend.md §12): what the emitter WROTE, for claims
// running cannot observe — that a `where`-constrained declaration grew a
// hidden parameter, that a call passed one, that `<` on `Int` is `<` and on
// `String` is a call. `run/` stays the default and proves behaviour; a
// fixture belongs here only when two different emissions would behave the
// same and the difference is the point.
//
// The golden is the module's own `.mjs` and not the whole build: core and
// the platform are somebody else's output, and a golden that held them
// would fail on every unrelated change to `core/`. §12 asks for an
// extracted declaration; one module of one tiny fixture is that extract
// with no extractor to get wrong.
test "corpus: emit" {
    try walk(.emit);
}

test "corpus: regress" {
    try walk(.regress);
}

/// Run every `.beni` directly under `kind.dir()` and under its `core/`
/// subdirectory (both sorted). The kind directory must exist; `core/` is
/// optional; an empty kind is reported, not failed.
fn walk(kind: Kind) !void {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const core_dir = try std.fs.path.join(arena, &.{ kind.dir(), "core" });
    var fixtures: std.ArrayList(Fixture) = .empty;
    try collect(arena, kind.dir(), false, true, &fixtures, kind.hasProjects());
    // Projects under `core/` too, and for the same reason they exist above
    // it: a fixture about what one module may say to ANOTHER cannot be one
    // file, and `--core` is what lets a fixture write `foreign` at all
    // (`boundary.md` §2). Without this a two-module `--core` fixture could
    // not exist, and the one that wanted to be one carried an unrelated
    // `foreign_outside_platform` in its golden.
    try collect(arena, core_dir, true, false, &fixtures, kind.hasProjects());
    // `emit/app/`: the goldens whose claim IS what elimination removes
    // (`backend.md` §9, §12). Everything else under `emit/` is built with
    // `--library`, so a golden is a claim about the shape of a declaration
    // and not about whether the fixture's own `main` happens to call it;
    // these are the application builds that `--library` would hide. It
    // takes PROJECTS as well as files, because "a module vanishes" needs a
    // second module to vanish.
    if (kind == .emit) {
        const app_dir = try std.fs.path.join(arena, &.{ kind.dir(), "app" });
        const start = fixtures.items.len;
        try collect(arena, app_dir, false, false, &fixtures, true);
        for (fixtures.items[start..]) |*fixture| fixture.app = true;

        // `emit/release/`: the same mechanism a third time (`backend.md`
        // §9's *Testing*, §12). These keep `--library` and gain
        // `--release`, so a golden here is a shape claim about names,
        // whitespace and inlining — the things `run/` cannot observe
        // because they do not change what a program prints.
        const release_dir = try std.fs.path.join(arena, &.{ kind.dir(), "release" });
        const release_start = fixtures.items.len;
        try collect(arena, release_dir, false, false, &fixtures, true);
        for (fixtures.items[release_start..]) |*fixture| fixture.release = true;
    }

    if (fixtures.items.len == 0) {
        std.debug.print("corpus {s} is empty (M1 fills it)\n", .{kind.dir()});
        return;
    }

    const bless = blessing(gpa);
    const bless_only = blessOnly(arena);
    var w = try World.init(gpa, io);
    defer w.deinit();

    var failures: usize = 0;
    for (fixtures.items) |fixture| {
        const path = try std.fs.path.join(arena, &.{ fixture.dir, fixture.name });
        const bless_this = bless and (bless_only == null or std.mem.indexOf(u8, path, bless_only.?) != null);
        const case: Case = .{ .arena = arena, .w = &w, .kind = kind, .fixture = fixture, .bless = bless_this };
        case.run() catch |err| {
            std.debug.print("FAIL {s}/{s}: {t}\n", .{ fixture.dir, fixture.name, err });
            failures += 1;
        };
    }
    // Only on failure: anything a passing test writes to stderr makes the
    // build runner print `failed command` next to a step that succeeded,
    // which reads as a broken suite to everyone who sees it.
    if (failures != 0) {
        std.debug.print("corpus {s}: {d} cases, {d} failures\n", .{ kind.dir(), fixtures.items.len, failures });
        return error.CorpusFailures;
    }
}

/// One fixture under a corpus directory: a `.beni` file, or — for the
/// `check` kinds — a directory that is a whole project.
const Fixture = struct {
    dir: []const u8,
    name: []const u8,
    /// Under `<kind>/core/`: run with `--core`.
    core: bool,
    /// `name` is a directory holding a multi-module project (checker.md §3).
    project: bool = false,
    /// Under `emit/app/`: built as an APPLICATION, rooted at `main`, so the
    /// golden can be a claim about what elimination removes (backend.md
    /// §9). Everything else under `emit/` gets `--library`.
    app: bool = false,
    /// Under `emit/release/`: `--release` is added to the argv, so the
    /// golden is a shape claim about §9's release optimiser.
    release: bool = false,
};

/// Append the `.beni` files directly under `dir`, sorted by name — plus,
/// for a kind that has them, the project subdirectories.
fn collect(arena: std.mem.Allocator, dir_path: []const u8, core: bool, required: bool, out: *std.ArrayList(Fixture), projects: bool) !void {
    const io = testing.io;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        if (!required and err == error.FileNotFound) return;
        std.debug.print("corpus directory {s} must exist: {t}\n", .{ dir_path, err });
        return err;
    };
    defer dir.close(io);

    const start = out.items.len;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory and projects and !std.mem.eql(u8, entry.name, "core")) {
            try out.append(arena, .{ .dir = dir_path, .name = try arena.dupe(u8, entry.name), .core = core, .project = true });
            continue;
        }
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".beni")) continue;
        try out.append(arena, .{ .dir = dir_path, .name = try arena.dupe(u8, entry.name), .core = core });
    }
    std.mem.sort(Fixture, out.items[start..], {}, struct {
        fn lessThan(_: void, a: Fixture, b: Fixture) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
}

/// The `BENI_BLESS_ONLY` substring, if set and non-empty.
fn blessOnly(arena: std.mem.Allocator) ?[]const u8 {
    const value = testing.environ.getAlloc(arena, "BENI_BLESS_ONLY") catch return null;
    return if (value.len == 0) null else value;
}

fn blessing(gpa: std.mem.Allocator) bool {
    const value = testing.environ.getAlloc(gpa, "BENI_WRITE_EXPECTED") catch return false;
    defer gpa.free(value);
    return value.len != 0 and !std.mem.eql(u8, value, "0");
}

const Case = struct {
    arena: std.mem.Allocator,
    w: *World,
    kind: Kind,
    fixture: Fixture,
    bless: bool,

    /// The path the compiler is pointed at: the `.beni` file, or the
    /// project directory.
    fn fixturePath(c: Case) ![]const u8 {
        return std.fs.path.join(c.arena, &.{ c.fixture.dir, c.fixture.name });
    }

    /// `<dir>/<stem>.<ext>` next to the fixture, or
    /// `<dir>/<project>/_expected.<ext>` inside a project (checker.md §3).
    fn goldenPath(c: Case, ext: []const u8) ![]const u8 {
        if (c.fixture.project) {
            return std.fmt.allocPrint(c.arena, "{s}/{s}/_expected.{s}", .{ c.fixture.dir, c.fixture.name, ext });
        }
        const stem = c.fixture.name[0 .. c.fixture.name.len - ".beni".len];
        return std.fmt.allocPrint(c.arena, "{s}/{s}.{s}", .{ c.fixture.dir, stem, ext });
    }

    fn run(c: Case) !void {
        switch (c.kind) {
            .parse_good => try c.good(),
            .parse_bad => try c.bad(),
            .fmt => try c.format(),
            .bir => try c.lowering(),
            .dispatch => try c.dispatching(),
            .check_good => try c.checkGood(),
            .check_bad, .check_args => try c.bad(),
            .check_depth => try c.depth(),
            .build_bad => try c.buildBad(),
            .run => try c.runProgram(),
            .emit => try c.emitted(),
            .regress => {
                const has_diag = c.goldenExists("diag");
                const has_ast = c.goldenExists("ast");
                if (has_diag) return c.bad();
                if (has_ast) return c.good();
                if (c.bless) return c.good(); // blessing a regress fixture pins it as good
                std.debug.print("{s}: a regress fixture needs a .diag or a .ast golden\n", .{c.fixture.name});
                return error.MissingGolden;
            },
        }
    }

    fn goldenExists(c: Case, ext: []const u8) bool {
        const p = c.goldenPath(ext) catch return false;
        Io.Dir.cwd().access(testing.io, p, .{}) catch return false;
        return true;
    }

    /// Run the compiler in the repo root (fixtures are referenced by their
    /// repo-relative path, which is also what appears in diagnostics).
    fn compiler(c: Case, args: []const []const u8) !world.Result {
        return c.w.runWith(try c.argv(args), .{ .raw_diagnostics = true, .cwd = .inherit });
    }

    /// Same as `compiler`, in the world's project directory (for files the
    /// case wrote itself).
    fn inProject(c: Case, args: []const []const u8) !world.Result {
        return c.w.runWith(try c.argv(args), .{ .raw_diagnostics = true });
    }

    /// `args`, plus `--core` for a fixture under `core/`.
    fn argv(c: Case, args: []const []const u8) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        try list.appendSlice(c.arena, args);
        if (c.fixture.core) try list.append(c.arena, "--core");
        return list.items;
    }

    fn good(c: Case) !void {
        const r = try c.compiler(&.{ "dump", "--stage=ast", try c.fixturePath() });
        try expectExit(0, r);
        // `dump` exits 0 even with syntax errors (the tree is its product);
        // "parses clean" means no diagnostic at all.
        if (r.stderr.len != 0) {
            std.debug.print("{s}: a good fixture must produce no diagnostics\n--- stderr ---\n{s}\n", .{ c.fixture.name, r.stderr });
            return error.GoodFixtureHasDiagnostics;
        }
        try c.expectGolden("ast", r.stdout);
    }

    fn bad(c: Case) !void {
        const golden = try c.goldenPath("diag");
        if (!c.goldenExists("diag") and !c.bless) {
            std.debug.print("{s}: a bad fixture without {s} is a failure, not a pass; set BENI_WRITE_EXPECTED=1 to create it\n", .{ c.fixture.name, golden });
            return error.MissingDiagGolden;
        }
        const r = try c.compiler(&.{ "check", "--diagnostics=json", try c.fixturePath() });
        try expectExit(1, r);
        try c.expectGolden("diag", r.stderr);
    }

    /// One arm of the depth sweep. The suffix of the NAME says which:
    /// `…Ok` must check clean and have no golden, `…Deep` must fail with
    /// the whole diagnostic as its golden. Anything else is a failure —
    /// a fixture that names neither would pass by not being looked at,
    /// which is the decay this kind exists to prevent.
    fn depth(c: Case) !void {
        const stem = c.fixture.name[0 .. c.fixture.name.len - ".beni".len];
        if (std.mem.endsWith(u8, stem, "Deep")) {
            if (!c.goldenExists("diag") and !c.bless) {
                std.debug.print("{s}: a check/depth `Deep` fixture needs a .diag golden\n", .{c.fixture.name});
                return error.MissingDiagGolden;
            }
            return c.bad();
        }
        if (!std.mem.endsWith(u8, stem, "Ok")) {
            std.debug.print("{s}: a check/depth fixture must be named `…Ok.beni` or `…Deep.beni`\n", .{c.fixture.name});
            return error.UnpairedDepthFixture;
        }
        if (c.goldenExists("diag")) {
            std.debug.print("{s}: a check/depth `Ok` fixture must check CLEAN, so it must have no .diag\n", .{c.fixture.name});
            return error.UnexpectedDiagGolden;
        }
        const r = try c.compiler(&.{ "check", try c.fixturePath() });
        try expectExit(0, r);
        if (r.stderr.len != 0) {
            std.debug.print("{s}: one level under the guard must produce no diagnostic\n--- stderr ---\n{s}\n", .{ c.fixture.name, r.stderr });
            return error.GoodFixtureHasDiagnostics;
        }
    }

    /// A whole project that must FAIL to build (`boundary.md` §4, §5).
    ///
    /// The fixture directory IS the project: every file under it is copied
    /// into the world (not only the `.beni`s, because a platform package is
    /// a manifest, modules and their sibling `.js`), and the `.beni` files
    /// at its top level, sorted, are the build's arguments.
    ///
    /// **The platform is a convention, not a flag file.** A `platform/`
    /// subdirectory means `--platform=platform`, which is how a fixture
    /// carries the package `boundary.md` §4's four sibling checks are
    /// checks OF; without one the build takes the embedded `--platform=node`,
    /// which is all the entry-point codes need. Nothing else is
    /// configurable, so a fixture is still one directory and one golden.
    ///
    /// Three assertions, and the third is the point of a *build* kind: exit
    /// 1, the whole diagnostic list as `_expected.diag`, and **no `out/`** —
    /// a refused build leaves nothing behind, which is the half of §4 a
    /// diagnostic golden cannot state.
    ///
    /// A world of its own per fixture, unlike every other kind: these
    /// fixtures write whole trees rather than one file, so the previous
    /// fixture's platform package would still be sitting in a shared one and
    /// its modules would be compiled into this build.
    fn buildBad(c: Case) !void {
        if (!c.fixture.project) {
            std.debug.print("{s}: a build/bad fixture is a DIRECTORY holding a whole project\n", .{c.fixture.name});
            return error.NotAProjectFixture;
        }
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        const dir_path = try c.fixturePath();
        try w.copyTree(dir_path, "_expected.");

        var sources: std.ArrayList([]const u8) = .empty;
        var dir = try Io.Dir.cwd().openDir(testing.io, dir_path, .{ .iterate = true });
        defer dir.close(testing.io);
        var has_platform = false;
        var it = dir.iterate();
        while (try it.next(testing.io)) |entry| {
            if (entry.kind == .directory and std.mem.eql(u8, entry.name, "platform")) has_platform = true;
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".beni")) continue;
            try sources.append(c.arena, try c.arena.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, sources.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(c.arena, &.{
            "build",
            "--diagnostics=json",
            if (has_platform) "--platform=platform" else "--platform=node",
            "--out=out",
        });
        try args.appendSlice(c.arena, sources.items);

        const built = try w.runWith(try c.argv(args.items), .{ .raw_diagnostics = true });
        if (built.exit_code != 1) {
            std.debug.print(
                "{s}: a build/bad fixture must FAIL the build; it exited {d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
                .{ c.fixture.name, built.exit_code, built.stdout, built.stderr },
            );
            return error.BuildDidNotFail;
        }
        if (w.exists("out")) {
            std.debug.print("{s}: a refused build must write no out/ (boundary.md §4)\n", .{c.fixture.name});
            return error.RefusedBuildWroteOutput;
        }
        if (!c.goldenExists("diag") and !c.bless) {
            std.debug.print("{s}: a build/bad fixture without its _expected.diag is a failure, not a pass; set BENI_WRITE_EXPECTED=1 to create it\n", .{c.fixture.name});
            return error.MissingDiagGolden;
        }
        try c.expectGolden("diag", built.stderr);
    }

    fn format(c: Case) !void {
        const fixture = try c.fixturePath();
        const r = try c.compiler(&.{ "fmt", "--stdout", fixture });
        try expectExit(0, r);
        try c.expectGolden("expected", r.stdout);

        // Fixed point: formatting the formatted text changes nothing.
        try c.w.write("Fixed.beni", r.stdout);
        const again = try c.inProject(&.{ "fmt", "--stdout", "Fixed.beni" });
        try expectExit(0, again);
        if (!std.mem.eql(u8, r.stdout, again.stdout)) {
            std.debug.print("{s}: formatter output is not a fixed point\n--- first ---\n{s}\n--- second ---\n{s}\n", .{ c.fixture.name, r.stdout, again.stdout });
            return error.NotAFixedPoint;
        }

        // Structure-preserving: both parse to the same AST. The formatter
        // sorts imports (language.md §9), so the dumps are compared with
        // their import entries in sorted order.
        const before = try c.compiler(&.{ "dump", "--stage=ast", fixture });
        const after = try c.inProject(&.{ "dump", "--stage=ast", "Fixed.beni" });
        try expectExit(0, before);
        try expectExit(0, after);
        if (!std.mem.eql(u8, try sortImports(c.arena, before.stdout), try sortImports(c.arena, after.stdout))) {
            std.debug.print("{s}: formatting changed the AST\n--- before ---\n{s}\n--- after ---\n{s}\n", .{ c.fixture.name, before.stdout, after.stdout });
            return error.AstChanged;
        }
    }

    /// Compile the fixture for the Node platform and run what came out.
    ///
    /// The fixture is COPIED into the world's project directory rather than
    /// compiled in place, for two reasons: the module name comes from the
    /// path (`tests/corpus/run/Arithmetic.beni` would be the module
    /// `Tests.Corpus.Run.Arithmetic`, which is not what the fixture writes
    /// `main` in), and a build writes an `out/` directory that has no
    /// business appearing in the repository.
    /// Both passes. **The whole `run/` corpus is built and run a second
    /// time under `--release`**, not a marked subset (`backend.md` §9's
    /// *Testing*, §12): the failure mode of a minifier is a wrong answer in
    /// a program nobody thought to mark, so the guard has to be the corpus
    /// and not a guess. Measured cost: about 7 seconds, +11% of
    /// `zig build test-blackbox`.
    ///
    /// The two builds go to different `--out` directories so that neither
    /// can read the other's `out/`, and the release pass asserts the SAME
    /// `.expected` — unless the fixture carries a `.release-expected`, which
    /// exists for the one claim §9 makes that the two outputs legitimately
    /// differ on: a dead local binding holding a `Debug.log` is dropped in
    /// release and kept in dev.
    fn runProgram(c: Case) !void {
        const source = try Io.Dir.cwd().readFileAlloc(testing.io, try c.fixturePath(), c.arena, .limited(world.max_stream_bytes));
        try c.w.write(c.fixture.name, source);

        try c.runOnce("out", &.{ "build", "--platform=node", "--out=out", c.fixture.name }, "expected", c.bless);
        // The release pass never blesses `expected`: it is the DEV pass's
        // golden and a release build that disagrees with it is the finding
        // this pass exists to make. A fixture that is allowed to differ says
        // so by carrying its own `.release-expected`, which does bless.
        const separate = c.goldenExists("release-expected");
        try c.runOnce(
            "release",
            &.{ "build", "--platform=node", "--release", "--out=release", c.fixture.name },
            if (separate) "release-expected" else "expected",
            c.bless and separate,
        );
    }

    /// One build-and-run of a `run/` fixture, against `golden`.
    fn runOnce(c: Case, out_dir: []const u8, args: []const []const u8, golden: []const u8, bless: bool) !void {
        const built = try c.inProject(args);
        if (built.exit_code != 0) {
            std.debug.print("{s} [{s}]: build failed\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n", .{ c.fixture.name, out_dir, built.stdout, built.stderr });
            return error.BuildFailed;
        }
        if (built.stderr.len != 0) {
            std.debug.print("{s} [{s}]: a run fixture must compile with no diagnostics\n--- stderr ---\n{s}\n", .{ c.fixture.name, out_dir, built.stderr });
            return error.GoodFixtureHasDiagnostics;
        }

        const entry = try std.fmt.allocPrint(c.arena, "{s}/main.mjs", .{out_dir});
        const program = c.w.node(entry) catch |err| {
            std.debug.print("{s} [{s}]: cannot run the emitted program ({t}); is node on PATH?\n", .{ c.fixture.name, out_dir, err });
            return err;
        };
        if (program.exit_code != 0) {
            std.debug.print(
                "{s} [{s}]: the emitted program exited {d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
                .{ c.fixture.name, out_dir, program.exit_code, program.stdout, program.stderr },
            );
            return error.ProgramFailed;
        }
        try c.expectGoldenMaybeBless(golden, program.stdout, bless);
    }

    /// Compile the fixture for the Node platform and golden the module it
    /// produced. Copied into the world's project directory for the same two
    /// reasons `run/` copies: the module name comes from the path, and a
    /// build writes an `out/` directory that has no business in the repo.
    ///
    /// **Built with `--library` unless it is under `emit/app/`**
    /// (`backend.md` §9, §12, the same per-fixture mechanism `core/` uses
    /// for `--core`). An `emit/` golden is a claim about the SHAPE of a
    /// declaration and must not be contingent on something calling it: with
    /// `main` as the only root, all seventeen goldens here would be gutted
    /// and `DerivedCompareNominal.js` — 115 lines of which 114 are derived
    /// code and one is `main` — would lose the very evidence its intent
    /// comment is about. `emit/app/` is where elimination's own goldens go,
    /// because their claim IS what an application build removes.
    ///
    /// A fixture that is a DIRECTORY is a multi-module project: every
    /// `.beni` in it is copied and passed to one build, the entry is the
    /// module named after the directory, and `_expected.js` is that
    /// module's emitted file. `_expected.absent`, if present, lists output
    /// paths the build must NOT have written, one per line — which is how
    /// "a module vanishes" is asserted, there being no other way to golden
    /// a file that is not there.
    fn emitted(c: Case) !void {
        var sources: std.ArrayList([]const u8) = .empty;
        if (c.fixture.project) {
            const dir_path = try c.fixturePath();
            var dir = try Io.Dir.cwd().openDir(testing.io, dir_path, .{ .iterate = true });
            defer dir.close(testing.io);
            var it = dir.iterate();
            while (try it.next(testing.io)) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".beni")) continue;
                try sources.append(c.arena, try c.arena.dupe(u8, entry.name));
            }
            std.mem.sort([]const u8, sources.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lessThan);
            for (sources.items) |name| {
                const path = try std.fs.path.join(c.arena, &.{ dir_path, name });
                try c.w.write(name, try Io.Dir.cwd().readFileAlloc(testing.io, path, c.arena, .limited(world.max_stream_bytes)));
            }
        } else {
            const source = try Io.Dir.cwd().readFileAlloc(testing.io, try c.fixturePath(), c.arena, .limited(world.max_stream_bytes));
            try c.w.write(c.fixture.name, source);
            try sources.append(c.arena, c.fixture.name);
        }

        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(c.arena, &.{ "build", "--platform=node", "--out=out" });
        if (!c.fixture.app) try args.append(c.arena, "--library");
        if (c.fixture.release) try args.append(c.arena, "--release");
        try args.appendSlice(c.arena, sources.items);

        const built = try c.inProject(args.items);
        if (built.exit_code != 0) {
            std.debug.print("{s}: build failed\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n", .{ c.fixture.name, built.stdout, built.stderr });
            return error.BuildFailed;
        }
        if (built.stderr.len != 0) {
            std.debug.print("{s}: an emit fixture must compile with no diagnostics\n--- stderr ---\n{s}\n", .{ c.fixture.name, built.stderr });
            return error.GoodFixtureHasDiagnostics;
        }

        const stem = if (c.fixture.project)
            c.fixture.name
        else
            c.fixture.name[0 .. c.fixture.name.len - ".beni".len];
        const emitted_path = try std.fmt.allocPrint(c.arena, "out/{s}.mjs", .{stem});
        const js = c.w.read(emitted_path) catch |err| {
            std.debug.print("{s}: the build wrote no {s} ({t})\n", .{ c.fixture.name, emitted_path, err });
            return err;
        };
        try c.expectGolden("js", js);
        try c.expectAbsent();
    }

    /// The `_expected.absent` half of a project fixture: every non-empty,
    /// non-comment line is an output path the build must not have written.
    /// It is never blessed — a file that should not exist cannot be
    /// captured from a run, only asserted.
    fn expectAbsent(c: Case) !void {
        if (!c.fixture.project or !c.goldenExists("absent")) return;
        const text = try Io.Dir.cwd().readFileAlloc(testing.io, try c.goldenPath("absent"), c.arena, .limited(world.max_stream_bytes));
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (c.w.read(line)) |_| {
                std.debug.print("{s}: the build wrote {s}, which elimination should have removed\n", .{ c.fixture.name, line });
                return error.UnexpectedOutputFile;
            } else |_| {}
        }
    }

    fn lowering(c: Case) !void {
        const r = try c.compiler(&.{ "dump", "--stage=bir", try c.fixturePath() });
        try expectExit(0, r);
        try c.expectGolden("bir", r.stdout);
    }

    /// The dispatch table of one module (§7.3). Both halves matter: the
    /// fixture must check CLEAN — a diagnostic means the table describes a
    /// program the compiler rejected — and the table is the golden.
    fn dispatching(c: Case) !void {
        const path = try c.fixturePath();
        const checked = try c.compiler(&.{ "check", path });
        try expectExit(0, checked);
        if (checked.stderr.len != 0) {
            std.debug.print("{s}: a dispatch fixture must produce no diagnostics\n--- stderr ---\n{s}\n", .{ c.fixture.name, checked.stderr });
            return error.GoodFixtureHasDiagnostics;
        }
        const r = try c.compiler(&.{ "dump", "--stage=dispatch", path });
        try expectExit(0, r);
        try c.expectGolden("dispatch", r.stdout);
    }

    /// A module — or a project — that resolves clean: exit 0, no
    /// `error`-severity diagnostic, and its interface(s) are the golden
    /// (checker.md §3). Both halves matter: the exit code says the names
    /// resolved, the golden says what the module now offers its dependents.
    ///
    /// A `warning` is legitimate output from a fixture that compiles, so a
    /// `check/good` fixture MAY carry a `.diag` golden and then its
    /// warnings are compared against it byte for byte — the same golden
    /// discipline `check/bad` gets, applied to the one `warning` the
    /// compiler has (`static-dispatch-spike.md` §10.9, A.83). Without the
    /// golden it must still be silent, so a fixture cannot start warning
    /// unnoticed.
    fn checkGood(c: Case) !void {
        const path = try c.fixturePath();
        const checked = try c.compiler(&.{ "check", path });
        try expectExit(0, checked);
        if (checked.stderr.len != 0 or c.goldenExists("diag")) {
            const json = try c.compiler(&.{ "check", "--diagnostics=json", path });
            try expectExit(0, json);
            if (json.stderr.len == 0 and !c.bless) {
                std.debug.print("{s}: a silent check/good fixture must not have a .diag golden\n", .{c.fixture.name});
                return error.UnexpectedDiagGolden;
            }
            try c.expectGolden("diag", json.stderr);
        }
        const r = try c.compiler(&.{ "dump", "--stage=interface", path });
        try expectExit(0, r);
        try c.expectGolden("iface", r.stdout);
    }

    /// Compare `actual` (fully materialised by the caller) with the golden,
    /// or write it when blessing.
    fn expectGolden(c: Case, ext: []const u8, actual: []const u8) !void {
        return c.expectGoldenMaybeBless(ext, actual, c.bless);
    }

    fn expectGoldenMaybeBless(c: Case, ext: []const u8, actual: []const u8, bless: bool) !void {
        const golden = try c.goldenPath(ext);
        if (bless) {
            try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = golden, .data = actual });
            std.debug.print("blessed {s}\n", .{golden});
            return;
        }
        const expected = Io.Dir.cwd().readFileAlloc(testing.io, golden, c.arena, .limited(world.max_stream_bytes)) catch |err| {
            std.debug.print("{s}: cannot read golden {s} ({t}); set BENI_WRITE_EXPECTED=1 to create it\n", .{ c.fixture.name, golden, err });
            return error.MissingGolden;
        };
        if (!std.mem.eql(u8, expected, actual)) {
            std.debug.print("{s}: output differs from {s}; set BENI_WRITE_EXPECTED=1 to bless\n--- expected ---\n{s}\n--- actual ---\n{s}\n", .{ c.fixture.name, golden, expected, actual });
            return error.GoldenMismatch;
        }
    }
};

/// An AST dump with its top-level `(import …)` entries (each with the
/// `(exposed …)` lines under it) reordered by their text.
fn sortImports(arena: std.mem.Allocator, dump: []const u8) ![]const u8 {
    // Each import block as `[start, end)` offsets into `dump`.
    var blocks: std.ArrayList([2]usize) = .empty;
    var out: std.ArrayList(u8) = .empty;
    var first_import: ?usize = null;
    var in_import = false;
    var pos: usize = 0;
    while (pos < dump.len) {
        const nl = std.mem.indexOfScalarPos(u8, dump, pos, '\n') orelse dump.len;
        const line_end = @min(nl + 1, dump.len);
        const line = dump[pos..nl];
        if (std.mem.startsWith(u8, line, "  (import")) {
            if (first_import == null) first_import = out.items.len;
            try blocks.append(arena, .{ pos, line_end });
            in_import = true;
        } else if (in_import and std.mem.startsWith(u8, line, "    ")) {
            blocks.items[blocks.items.len - 1][1] = line_end; // a continuation of the import above
        } else {
            try out.appendSlice(arena, dump[pos..line_end]);
            in_import = false;
        }
        pos = line_end;
    }
    const at = first_import orelse return dump;
    std.mem.sort([2]usize, blocks.items, dump, struct {
        fn lessThan(d: []const u8, a: [2]usize, b: [2]usize) bool {
            return std.mem.lessThan(u8, d[a[0]..a[1]], d[b[0]..b[1]]);
        }
    }.lessThan);
    var sorted: std.ArrayList(u8) = .empty;
    try sorted.appendSlice(arena, out.items[0..at]);
    for (blocks.items) |b| try sorted.appendSlice(arena, dump[b[0]..b[1]]);
    try sorted.appendSlice(arena, out.items[at..]);
    return sorted.items;
}

fn expectExit(expected: u8, r: world.Result) !void {
    if (r.exit_code != expected) {
        std.debug.print("expected exit {d}, got {d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n", .{ expected, r.exit_code, r.stdout, r.stderr });
        return error.UnexpectedExitCode;
    }
}
