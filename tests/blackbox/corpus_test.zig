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
//!   check/args/X.beni + X.diag      the missing-argument suite (checker.md §8.3)
//!   check/depth/XOk.beni            checks clean: one level UNDER a guard
//!   check/depth/XDeep.beni + .diag  one level OVER it, and says so
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
    check_good,
    check_bad,
    check_args,
    check_depth,
    regress,

    fn dir(kind: Kind) []const u8 {
        return switch (kind) {
            .parse_good => corpus_root ++ "/parse/good",
            .parse_bad => corpus_root ++ "/parse/bad",
            .fmt => corpus_root ++ "/fmt",
            .bir => corpus_root ++ "/bir",
            .check_good => corpus_root ++ "/check/good",
            .check_bad => corpus_root ++ "/check/bad",
            .check_args => corpus_root ++ "/check/args",
            .check_depth => corpus_root ++ "/check/depth",
            .regress => corpus_root ++ "/regress",
        };
    }

    /// Whether a subdirectory of the kind is a PROJECT fixture rather than
    /// the `core/` flag directory every kind has.
    fn hasProjects(kind: Kind) bool {
        return kind == .check_good or kind == .check_bad;
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

test "corpus: check/good" {
    try walk(.check_good);
}

test "corpus: check/bad" {
    try walk(.check_bad);
}

// The missing-argument suite (checker.md §8.3). Its own kind so its size
// and its pass rate are visible on their own: `fast-compiler.md` §9.3 keeps
// currying on the condition that these read as THE right message, and a
// number that is buried in `check/bad` is a number nobody looks at.
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
    try collect(arena, core_dir, true, false, &fixtures, false);

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
            .check_good => try c.checkGood(),
            .check_bad, .check_args => try c.bad(),
            .check_depth => try c.depth(),
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

    fn lowering(c: Case) !void {
        const r = try c.compiler(&.{ "dump", "--stage=bir", try c.fixturePath() });
        try expectExit(0, r);
        try c.expectGolden("bir", r.stdout);
    }

    /// A module — or a project — that resolves clean: no diagnostic at
    /// all, and its interface(s) are the golden (checker.md §3). Both
    /// halves matter: the exit code says the names resolved, the golden
    /// says what the module now offers its dependents.
    fn checkGood(c: Case) !void {
        const path = try c.fixturePath();
        const checked = try c.compiler(&.{ "check", path });
        try expectExit(0, checked);
        if (checked.stderr.len != 0) {
            std.debug.print("{s}: a check/good fixture must produce no diagnostics\n--- stderr ---\n{s}\n", .{ c.fixture.name, checked.stderr });
            return error.GoodFixtureHasDiagnostics;
        }
        const r = try c.compiler(&.{ "dump", "--stage=interface", path });
        try expectExit(0, r);
        try c.expectGolden("iface", r.stdout);
    }

    /// Compare `actual` (fully materialised by the caller) with the golden,
    /// or write it when blessing.
    fn expectGolden(c: Case, ext: []const u8, actual: []const u8) !void {
        const golden = try c.goldenPath(ext);
        if (c.bless) {
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
