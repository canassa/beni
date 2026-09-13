//! The corpus walker (docs/design/frontend.md §7): the directory is the
//! assertion. One case per `.beni` under `tests/corpus/`, named by its path,
//! so adding a test is dropping in a file.
//!
//!   parse/good/X.beni + X.ast       `dump --stage=ast` equals the golden
//!   parse/bad/X.beni  + X.diag      `check --diagnostics=json` equals the golden;
//!                                   a `.beni` WITHOUT `.diag` is a failure
//!   fmt/X.beni        + X.expected  `fmt --stdout` equals the golden, formatting
//!                                   the golden again is a fixed point, and both
//!                                   parse to the same AST
//!   bir/X.beni        + X.bir       `dump --stage=bir` equals the golden
//!   regress/X.beni    + .diag|.ast  behaves as bad or good by which golden exists
//!
//! A fixture under a `core/` subdirectory of its kind (`bir/core/Foreign.beni`)
//! is run with `--core` added to the argv (language.md §5.4); its goldens sit
//! next to it in that subdirectory. Every kind has this.
//!
//! `BENI_WRITE_EXPECTED=1` blesses: goldens are (re)written from the actual
//! output, which is fully materialised before any file is touched. The
//! failure message says so. Exit codes are asserted exactly and never
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
    regress,

    fn dir(kind: Kind) []const u8 {
        return switch (kind) {
            .parse_good => corpus_root ++ "/parse/good",
            .parse_bad => corpus_root ++ "/parse/bad",
            .fmt => corpus_root ++ "/fmt",
            .bir => corpus_root ++ "/bir",
            .regress => corpus_root ++ "/regress",
        };
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
    try collect(arena, kind.dir(), false, true, &fixtures);
    try collect(arena, core_dir, true, false, &fixtures);

    if (fixtures.items.len == 0) {
        std.debug.print("corpus {s} is empty (M1 fills it)\n", .{kind.dir()});
        return;
    }

    const bless = blessing(gpa);
    var w = try World.init(gpa, io);
    defer w.deinit();

    var failures: usize = 0;
    for (fixtures.items) |fixture| {
        const case: Case = .{ .arena = arena, .w = &w, .kind = kind, .fixture = fixture, .bless = bless };
        case.run() catch |err| {
            std.debug.print("FAIL {s}/{s}: {t}\n", .{ fixture.dir, fixture.name, err });
            failures += 1;
        };
    }
    std.debug.print("corpus {s}: {d} cases, {d} failures\n", .{ kind.dir(), fixtures.items.len, failures });
    if (failures != 0) return error.CorpusFailures;
}

/// One `.beni` under a corpus directory.
const Fixture = struct {
    dir: []const u8,
    name: []const u8,
    /// Under `<kind>/core/`: run with `--core`.
    core: bool,
};

/// Append the `.beni` files directly under `dir`, sorted by name.
fn collect(arena: std.mem.Allocator, dir_path: []const u8, core: bool, required: bool, out: *std.ArrayList(Fixture)) !void {
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
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".beni")) continue;
        try out.append(arena, .{ .dir = dir_path, .name = try arena.dupe(u8, entry.name), .core = core });
    }
    std.mem.sort(Fixture, out.items[start..], {}, struct {
        fn lessThan(_: void, a: Fixture, b: Fixture) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
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

    fn fixturePath(c: Case) ![]const u8 {
        return std.fs.path.join(c.arena, &.{ c.fixture.dir, c.fixture.name });
    }

    /// `<dir>/<stem>.<ext>`, next to the fixture.
    fn goldenPath(c: Case, ext: []const u8) ![]const u8 {
        const stem = c.fixture.name[0 .. c.fixture.name.len - ".beni".len];
        return std.fmt.allocPrint(c.arena, "{s}/{s}.{s}", .{ c.fixture.dir, stem, ext });
    }

    fn run(c: Case) !void {
        switch (c.kind) {
            .parse_good => try c.good(),
            .parse_bad => try c.bad(),
            .fmt => try c.format(),
            .bir => try c.lowering(),
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

        // Structure-preserving: both parse to the same AST.
        const before = try c.compiler(&.{ "dump", "--stage=ast", fixture });
        const after = try c.inProject(&.{ "dump", "--stage=ast", "Fixed.beni" });
        try expectExit(0, before);
        try expectExit(0, after);
        if (!std.mem.eql(u8, before.stdout, after.stdout)) {
            std.debug.print("{s}: formatting changed the AST\n--- before ---\n{s}\n--- after ---\n{s}\n", .{ c.fixture.name, before.stdout, after.stdout });
            return error.AstChanged;
        }
    }

    fn lowering(c: Case) !void {
        const r = try c.compiler(&.{ "dump", "--stage=bir", try c.fixturePath() });
        try expectExit(0, r);
        try c.expectGolden("bir", r.stdout);
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

fn expectExit(expected: u8, r: world.Result) !void {
    if (r.exit_code != expected) {
        std.debug.print("expected exit {d}, got {d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n", .{ expected, r.exit_code, r.stdout, r.stderr });
        return error.UnexpectedExitCode;
    }
}
