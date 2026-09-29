//! The corpus walker (docs/design/frontend.md §7): the directory is the
//! assertion. One case per `.beni` under `tests/corpus/`, named by its path,
//! so adding a test is dropping in a file.
//!
//!   parse/good/X.beni + X.ast       `dump --stage=ast` equals the golden and
//!                                   stderr is empty (no diagnostic at all)
//!   parse/bad/X.beni  + X.diag      `check --diagnostics=json` equals the golden;
//!                                   a `.beni` WITHOUT `.diag` is a failure
//!   parse/*/X.beni    + X.tokens    optional, either kind: `dump --stage=tokens`
//!                                   equals it too (the lexer's own golden)
//!   fmt/X.beni        + X.expected  `fmt --stdout` equals the golden, formatting
//!                                   the golden again is a fixed point, both parse
//!                                   to the same AST, and both carry the same
//!                                   comments in the same order
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
//!   build/bad-release/X/            the same, with `--release` added — and
//!                                   without `--allow-debug` (backend.md §9)
//!   regress/X.beni    + .diag|.ast  behaves as bad or good by which golden exists
//!
//! A fixture under a `core/` subdirectory of its kind (`bir/core/Foreign.beni`)
//! is run with `--core` added to the argv (language.md §5.4); its goldens sit
//! next to it in that subdirectory. Every kind has this. A `check/good/`,
//! `check/bad/` or `dispatch/` fixture under `markup/` is run with
//! `--platform=html`, so its markup is typed against the HTML vocabulary.
//!
//! `BENI_WRITE_EXPECTED=1` blesses: goldens are (re)written from the actual
//! output, which is fully materialised before any file is touched. The
//! failure message says so. `BENI_BLESS_ONLY=<substring>` limits blessing to
//! the fixtures whose repo-relative path contains the substring (the rest
//! are compared as usual), so one kind — or one file — can be pinned while
//! the goldens a later milestone owns stay unwritten. Exit codes are asserted exactly and never
//! special-cased: a command that is not implemented returns 2, and any
//! fixture of a kind that runs it fails — which is correct, and why such a
//! kind's directory holds only its README until the command exists.
//!
//! The same walker runs `tests/pending/` (`plans/checker-rewrite.md` §2):
//! `BENI_CORPUS_ROOT` moves the root, `BENI_CORPUS_MODE=pending` reports
//! RED/GREEN per fixture instead of failing on it, and `BENI_CASE_TIMEOUT_MS`
//! bounds each run. Unset (or empty), each is today's strict corpus run; see
//! `Config`, and `tests/pending/README.md` for `.codes` and `RED`.
//! `BENI_CORPUS_PART` runs one part of `corpus_parts.zig` only, which is how
//! `test-blackbox` spreads the corpus over parallel processes.
//! `BENI_CORPUS_ONLY=<substring>` (`zig build … -Dcorpus=<substring>`) runs
//! only the fixtures whose repo-relative path contains it, in either mode;
//! one that matches no fixture at all is a failure.
//!
//! A `run/` fixture may carry a `.run-hash` (`run_hash.zig`): a digest of
//! the emitted output tree, the golden and the Node version, per build,
//! recorded when that JavaScript ran and matched. A build whose digest is
//! listed there is not run under Node again; any other build is run exactly
//! as without the record. `BENI_RUN_HASHES=record` (`zig build
//! test-run-hashes`) walks `run/` alone, runs every program, and rewrites
//! each record with the builds that matched. `BENI_RUN_HASH_REPORT=<dir>`
//! makes each process write its `run/` counts there — how many programs ran
//! for want of a record — which the build prints as one line.

const std = @import("std");
const world = @import("world.zig");
const diagnostic = @import("diagnostic");
const World = world.World;
const Io = std.Io;
const testing = std.testing;
const Part = @import("corpus_parts.zig").Part;
const run_hash = @import("run_hash.zig");

/// The root every `Kind` directory is joined onto unless
/// `BENI_CORPUS_ROOT` says otherwise (see `Config`).
const default_root = "tests/corpus";

/// The one directory whose fixtures may carry a `.codes` golden.
const pending_root = "tests/pending";

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
    build_bad_release,
    run,
    emit,
    regress,

    /// The kind's directory relative to the corpus root.
    fn sub(kind: Kind) []const u8 {
        return switch (kind) {
            .parse_good => "parse/good",
            .parse_bad => "parse/bad",
            .fmt => "fmt",
            .bir => "bir",
            .dispatch => "dispatch",
            .check_good => "check/good",
            .check_bad => "check/bad",
            .check_args => "check/args",
            .check_depth => "check/depth",
            .build_bad => "build/bad",
            .build_bad_release => "build/bad-release",
            .run => "run",
            .emit => "emit",
            .regress => "regress",
        };
    }

    /// The golden a fixture of this kind must carry, for pending mode's
    /// rule (a). A kind whose golden is a diagnostic list may carry a
    /// `.codes` instead under `tests/pending/` (`takesCodes`).
    fn golden(kind: Kind) ?[]const u8 {
        return switch (kind) {
            .parse_good => "ast",
            .parse_bad, .check_bad, .check_args, .build_bad, .build_bad_release => "diag",
            .fmt, .run => "expected",
            .bir => "bir",
            .dispatch => "dispatch",
            .check_good => "iface",
            .emit => "js",
            .check_depth, .regress => null,
        };
    }

    /// The kinds whose `.diag` may be a `.codes` in pending mode
    /// (`plans/checker-rewrite.md` §2.3): the ones `Case.bad` runs.
    fn takesCodes(kind: Kind) bool {
        return kind == .parse_bad or kind == .check_bad or kind == .check_args;
    }

    /// Whether a subdirectory of the kind is a PROJECT fixture rather than
    /// the `core/` flag directory every kind has.
    fn hasProjects(kind: Kind) bool {
        return kind == .check_good or kind == .check_bad or kind == .dispatch or
            kind == .build_bad or kind == .build_bad_release or kind == .run;
    }

    /// Whether the build this kind runs carries `--release` (and, for the
    /// same reason the kind exists, NOT `--allow-debug`).
    fn isRelease(kind: Kind) bool {
        return kind == .build_bad_release;
    }

    /// The part (`corpus_parts.zig`) that runs this kind — for `run/`, the
    /// part that runs one of its two passes. Exhaustive on purpose: a new
    /// kind does not compile until it is given to a part, so no kind can
    /// fall out of every `test-blackbox` process.
    fn partOf(kind: Kind, pass: RunPass) Part {
        return switch (kind) {
            .parse_good, .parse_bad, .fmt, .bir, .regress => .parse,
            .check_good, .check_bad, .check_args, .check_depth, .dispatch => .check,
            .build_bad, .build_bad_release, .emit => .build,
            .run => switch (pass) {
                .dev => .run_dev,
                .release => .run_release,
            },
        };
    }
};

/// `run/`'s two builds of one fixture. Every other kind has one pass,
/// which `partOf` is asked about as `.dev`.
const RunPass = enum { dev, release };

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
// with no ids and no positions, and a golden here is the contract the
// backend lowers against. A method call that resolved to the wrong function is
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

// The same kind with `--release` and WITHOUT `--allow-debug` (`backend.md`
// §9's *The release optimiser*). Its own directory rather than a flag file
// in `build/bad/`, because the flag is the whole assertion: every fixture
// here builds clean in development and is refused in release, which is a
// claim no other kind can make — `run/` passes `--allow-debug` on its
// release pass so that `Debug.log` keeps working as its instrument, and
// `build/bad/` never passes `--release` at all.
test "corpus: build/bad-release" {
    try walk(.build_bad_release);
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

    const cfg = try Config.read(arena);
    // Another process runs this kind (`corpus_parts.zig`): nothing to do.
    if (!cfg.runs(kind.partOf(.dev)) and !cfg.runs(kind.partOf(.release))) return;
    // Recording run hashes is about `run/` alone.
    if (cfg.run_hashes == .record and kind != .run) return;
    // Written whatever the cases say, so the build's summary never reads
    // counts left over from an earlier run.
    defer if (kind == .run) if (cfg.report_dir) |dir| run_counts.report(arena, dir, cfg.part) catch |err| {
        std.debug.print("BENI_RUN_HASH_REPORT: cannot write into {s}: {t}\n", .{ dir, err });
    };
    quiet = cfg.mode != .strict and !cfg.verbose;
    world.announce_timeouts = !quiet;
    defer world.announce_timeouts = true;
    defer quiet = false;
    const kind_dir = try std.fs.path.join(arena, &.{ cfg.root, kind.sub() });
    const all = try fixturesOf(arena, &cfg, kind);
    if (all.len == 0) {
        if (cfg.is_default_root) std.debug.print("corpus {s} is empty\n", .{kind_dir});
        return;
    }
    // `BENI_CORPUS_ONLY`: the fixtures whose path holds the text, and none
    // of this kind's when none does — but a filter that matches no fixture
    // of ANY kind fails, so a mistyped one cannot pass by running nothing.
    const fixtures = if (cfg.only) |text| blk: {
        if (!try anyFixtureMatches(arena, &cfg, text)) {
            std.debug.print("BENI_CORPUS_ONLY (-Dcorpus) `{s}` matches no fixture under {s}\n", .{ text, cfg.root });
            return error.CorpusFilterMatchesNothing;
        }
        var kept: std.ArrayList(Fixture) = .empty;
        for (all) |fixture| {
            if (try fixture.matches(arena, text)) try kept.append(arena, fixture);
        }
        break :blk kept.items;
    } else all;
    if (fixtures.len == 0) return;

    // Pending mode never blesses: a golden there is the CORRECT output,
    // written by hand, and the binary under test is the one known to be
    // wrong. Blessing happens after promotion, under `tests/corpus/`.
    var walker: Walker = .{
        .kind = kind,
        .cfg = &cfg,
        .fixtures = fixtures,
        .bless = blessing(gpa) and cfg.mode != .pending,
        .bless_only = blessOnly(arena),
    };
    // Every case is independent — its own world, its own arena — so the
    // cases are spread over a pool of workers, each pulling the next from
    // one counter. Pending mode stays on one thread: its report is one line
    // per fixture, read in order.
    const workers: usize = if (cfg.mode == .pending) 1 else @min(8, @max(1, std.Thread.getCpuCount() catch 1));
    const spent_before_workers = world.timing.testSpent();
    {
        var threads: std.ArrayList(std.Thread) = .empty;
        defer threads.deinit(gpa);
        defer for (threads.items) |t| t.join();
        for (1..workers) |_| try threads.append(gpa, try std.Thread.spawn(.{}, Walker.workOnThread, .{ &walker, io }));
        walker.work(io);
    }
    // The joined workers' instructions reach this test's count a moment
    // after the joins return; the runner must not read it before.
    world.timing.awaitFolded(spent_before_workers, walker.thread_totals.load(.monotonic));
    const failures = walker.failures.load(.monotonic);
    if (walker.fatal.load(.monotonic)) return error.CorpusWorkerFailed;
    // Only on failure: anything a passing test writes to stderr makes the
    // build runner print `failed command` next to a step that succeeded,
    // which reads as a broken suite to everyone who sees it.
    if (failures != 0) {
        std.debug.print("corpus {s}: {d} cases, {d} failures\n", .{ kind_dir, fixtures.len, failures });
        return error.CorpusFailures;
    }
}

/// Whether `text` is in the path of any fixture of any kind under the root.
fn anyFixtureMatches(arena: std.mem.Allocator, cfg: *const Config, text: []const u8) !bool {
    for (std.enums.values(Kind)) |kind| {
        for (try fixturesOf(arena, cfg, kind)) |fixture| {
            if (try fixture.matches(arena, text)) return true;
        }
    }
    return false;
}

/// Every fixture of `kind` under the root, in the order the walker runs
/// them.
fn fixturesOf(arena: std.mem.Allocator, cfg: *const Config, kind: Kind) ![]const Fixture {
    const kind_dir = try std.fs.path.join(arena, &.{ cfg.root, kind.sub() });
    const core_dir = try std.fs.path.join(arena, &.{ kind_dir, "core" });
    var fixtures: std.ArrayList(Fixture) = .empty;
    // Under a root that is not the default one, a kind that does not exist
    // there is simply not part of it: `tests/pending/` holds only the kinds
    // its red fixtures need (`plans/checker-rewrite.md` §2.1).
    try collect(arena, kind_dir, false, cfg.is_default_root, &fixtures, kind.hasProjects());
    // Projects under `core/` too, and for the same reason they exist above
    // it: a fixture about what one module may say to ANOTHER cannot be one
    // file, and `--core` is what lets a fixture write `foreign` at all
    // (`boundary.md` §2). Without this a two-module `--core` fixture could
    // not exist, and the one that wanted to be one carried an unrelated
    // `foreign_outside_platform` in its golden.
    try collect(arena, core_dir, true, false, &fixtures, kind.hasProjects());
    // `markup/`: the fixtures that write markup, checked against the `html`
    // platform's vocabulary (`checker-v2.md` §25), which a module sees only
    // under `--platform`. The same mechanism as `core/`, for the check kinds.
    if (kind == .check_good or kind == .check_bad or kind == .dispatch) {
        const markup_dir = try std.fs.path.join(arena, &.{ kind_dir, "markup" });
        const start = fixtures.items.len;
        try collect(arena, markup_dir, false, false, &fixtures, true);
        for (fixtures.items[start..]) |*fixture| fixture.markup = true;
    }
    // `emit/app/`: the goldens whose claim IS what elimination removes
    // (`backend.md` §9, §12). Everything else under `emit/` is built with
    // `--library`, so a golden is a claim about the shape of a declaration
    // and not about whether the fixture's own `main` happens to call it;
    // these are the application builds that `--library` would hide. It
    // takes PROJECTS as well as files, because "a module vanishes" needs a
    // second module to vanish.
    if (kind == .emit) {
        const app_dir = try std.fs.path.join(arena, &.{ kind_dir, "app" });
        const start = fixtures.items.len;
        try collect(arena, app_dir, false, false, &fixtures, true);
        for (fixtures.items[start..]) |*fixture| fixture.app = true;

        // `emit/release/`: the same mechanism a third time (`backend.md`
        // §9's *Testing*, §12). These keep `--library` and gain
        // `--release`, so a golden here is a shape claim about names,
        // whitespace and inlining — the things `run/` cannot observe
        // because they do not change what a program prints.
        const release_dir = try std.fs.path.join(arena, &.{ kind_dir, "release" });
        const release_start = fixtures.items.len;
        try collect(arena, release_dir, false, false, &fixtures, true);
        for (fixtures.items[release_start..]) |*fixture| fixture.release = true;
    }
    return fixtures.items;
}

/// One kind's fixtures, pulled by the workers of `walk` from one counter.
const Walker = struct {
    kind: Kind,
    cfg: *const Config,
    fixtures: []const Fixture,
    bless: bool,
    bless_only: ?[]const u8,
    next: std.atomic.Value(usize) = .init(0),
    failures: std.atomic.Value(usize) = .init(0),
    /// A worker that could not run a case at all (out of memory, a world
    /// it could not create): the kind fails whatever the cases said.
    fatal: std.atomic.Value(bool) = .init(false),
    /// What the workers on threads of their own spent in the budget's
    /// unit, each counted to its end (`timing.awaitFolded`).
    thread_totals: std.atomic.Value(u64) = .init(0),

    fn work(wk: *Walker, io: std.Io) void {
        const meter: world.timing.CaseMeter = .open();
        defer meter.close();
        wk.cases(io, meter) catch |err| {
            std.debug.print("corpus worker: {t}\n", .{err});
            wk.fatal.store(true, .monotonic);
        };
    }

    fn workOnThread(wk: *Walker, io: std.Io) void {
        const meter: world.timing.CaseMeter = .open();
        defer meter.close();
        wk.cases(io, meter) catch |err| {
            std.debug.print("corpus worker: {t}\n", .{err});
            wk.fatal.store(true, .monotonic);
        };
        if (meter.counter != null) _ = wk.thread_totals.fetchAdd(meter.read(), .monotonic);
    }

    fn cases(wk: *Walker, io: std.Io, meter: world.timing.CaseMeter) !void {
        const gpa = testing.allocator;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var w = try World.init(gpa, io);
        defer w.deinit();
        while (true) {
            const i = wk.next.fetchAdd(1, .monotonic);
            if (i >= wk.fixtures.len) return;
            const fixture = wk.fixtures[i];
            const path = try std.fs.path.join(arena, &.{ fixture.dir, fixture.name });
            const bless_this = wk.bless and (wk.bless_only == null or std.mem.indexOf(u8, path, wk.bless_only.?) != null);
            const case: Case = .{ .arena = arena, .w = &w, .kind = wk.kind, .fixture = fixture, .bless = bless_this, .cfg = wk.cfg };
            // Timing (`tests/timing.zig`): the case's own record, and its
            // name on every child it spawns.
            // The budget holds per case (`timing.budget_unit`): a kind is
            // hundreds of independent cases, and one case is what a
            // fixture costs.
            const spent_start = meter.read();
            const timed: ?[2]std.Io.Timestamp = if (world.timing.enabled()) .{ world.timing.now(), world.timing.threadCpu() } else null;
            world.timing.current_fixture = path;
            defer {
                world.timing.current_fixture = "";
                if (timed) |t| world.timing.write(.{ .fixture = .{
                    .@"test" = world.timing.current_test,
                    .kind = @tagName(wk.kind),
                    .path = path,
                    .wall_us = world.timing.sinceUs(t[0]),
                    .thread_cpu_us = world.timing.durationUs(t[1].durationTo(world.timing.threadCpu())),
                    .spent = if (world.timing.budget_unit == .instructions) meter.read() -% spent_start else 0,
                } });
            }
            switch (wk.cfg.mode) {
                .strict => {
                    const passed = if (case.run()) |_| true else |err| failed: {
                        std.debug.print("FAIL {s}/{s}: {t}\n", .{ fixture.dir, fixture.name, err });
                        _ = wk.failures.fetchAdd(1, .monotonic);
                        break :failed false;
                    };
                    const spent = meter.read() -% spent_start;
                    _ = world.timing.cases_spent.fetchAdd(spent, .monotonic);
                    if (passed and world.timing.budget_unit != .none and spent > world.timing.budget_limit) {
                        const got = world.timing.describe(spent);
                        const limit = world.timing.describe(world.timing.budget_limit);
                        std.debug.print("FAIL: {d} {s}, over the budget of {d} (the case's own and its children's): {s}/{s}\n", .{
                            got.value, got.unit, limit.value, fixture.dir, fixture.name,
                        });
                        _ = wk.failures.fetchAdd(1, .monotonic);
                    }
                },
                .pending => if (!try case.pending(path)) {
                    _ = wk.failures.fetchAdd(1, .monotonic);
                },
            }
        }
    }
};

/// How this run of the walker behaves, read once per kind from the
/// environment (`plans/checker-rewrite.md` §2.4). Every variable defaults to
/// the corpus's own strict behaviour, and an EMPTY value counts as unset:
/// `build.zig` pins them on every run (the defaults for `test-blackbox`), so a
/// variable exported in a shell cannot change what a gate means (S11).
const Config = struct {
    /// `BENI_CORPUS_ROOT`, default `tests/corpus`.
    root: []const u8,
    is_default_root: bool,
    mode: Mode,
    /// `BENI_CASE_TIMEOUT_MS`: the bound on one compiler run. Pending mode
    /// defaults to 20 s so a hang is a fast RED(timeout).
    timeout_ms: i64,
    /// `BENI_PENDING_VERBOSE`: keep each failing case's full detail in
    /// pending mode, where by default only its one-line reason
    /// is printed.
    verbose: bool,
    /// `BENI_CORPUS_PART`: the one part (`corpus_parts.zig`) this process
    /// runs, or null for every part. `test-blackbox` runs each part in its
    /// own process, in parallel.
    part: ?Part,
    /// `BENI_CORPUS_ONLY` (`zig build -Dcorpus=<text>`): run only the
    /// fixtures whose repo-relative path contains the text, or every
    /// fixture when null. Strict and pending mode alike.
    only: ?[]const u8,
    /// `tests/pending/RED` (§2.4 rule (d)): the recorded red signature of
    /// each fixture, pending mode only.
    red: []const world.pending.RedLine,
    /// `BENI_RUN_HASHES`: what `run/` does with its `.run-hash` records.
    run_hashes: RunHashes,
    /// `BENI_RUN_HASH_REPORT`: the directory this process writes its
    /// `run/` counts into (`RunCounts.report`), or null for none.
    report_dir: ?[]const u8,

    const RunHashes = enum {
        /// Unset: a build whose digest is recorded is not run under Node.
        check,
        /// `record`: only `run/` is walked, every program runs, and each
        /// record is rewritten with the builds that matched their golden.
        record,
    };

    const Mode = enum {
        /// Unset: every fixture must pass (today's behaviour).
        strict,
        /// `pending`: every fixture is reported RED or GREEN, and the step
        /// fails only for rules (a), (b) and (d).
        pending,
    };

    fn read(arena: std.mem.Allocator) !Config {
        const root = envOr(arena, "BENI_CORPUS_ROOT") orelse default_root;
        const mode_text = envOr(arena, "BENI_CORPUS_MODE");
        const mode: Mode = if (mode_text == null)
            .strict
        else if (std.mem.eql(u8, mode_text.?, "pending"))
            .pending
        else {
            std.debug.print("BENI_CORPUS_MODE must be `pending` (or unset), not `{s}`\n", .{mode_text.?});
            return error.BadCorpusMode;
        };
        const timeout_ms: i64 = if (envOr(arena, "BENI_CASE_TIMEOUT_MS")) |text|
            std.fmt.parseInt(i64, text, 10) catch {
                std.debug.print("BENI_CASE_TIMEOUT_MS must be a number of milliseconds, not `{s}`\n", .{text});
                return error.BadCaseTimeout;
            }
        else if (mode == .pending) 20_000 else world.default_timeout_ms;
        const part: ?Part = if (envOr(arena, "BENI_CORPUS_PART")) |text|
            std.meta.stringToEnum(Part, text) orelse {
                std.debug.print("BENI_CORPUS_PART must name a part of tests/blackbox/corpus_parts.zig, not `{s}`\n", .{text});
                return error.BadCorpusPart;
            }
        else
            null;
        // A pending `run/` fixture's red signature names the pass that failed
        // FIRST (`dev: …` before `release: …`), so a process that ran one
        // pass could record another signature than the whole fixture has.
        // Pending mode runs whole fixtures, in one process.
        if (part != null and mode == .pending) {
            std.debug.print("BENI_CORPUS_PART is refused in pending mode: rule (d) compares whole fixtures\n", .{});
            return error.BadCorpusPart;
        }
        const run_hashes: RunHashes = if (envOr(arena, "BENI_RUN_HASHES")) |text|
            std.meta.stringToEnum(RunHashes, text) orelse {
                std.debug.print("BENI_RUN_HASHES must be `record` (or unset), not `{s}`\n", .{text});
                return error.BadRunHashes;
            }
        else
            .check;
        // Pending mode never records: its goldens are the CORRECT output,
        // written by hand, and the binary under test is known to be wrong.
        if (run_hashes == .record and mode == .pending) {
            std.debug.print("BENI_RUN_HASHES=record is refused in pending mode\n", .{});
            return error.BadRunHashes;
        }
        var cfg: Config = .{
            .run_hashes = run_hashes,
            .report_dir = envOr(arena, "BENI_RUN_HASH_REPORT"),
            .root = std.mem.trimEnd(u8, root, "/"),
            .part = part,
            .only = envOr(arena, "BENI_CORPUS_ONLY"),
            .is_default_root = std.mem.eql(u8, std.mem.trimEnd(u8, root, "/"), default_root),
            .mode = mode,
            .timeout_ms = timeout_ms,
            .verbose = envOr(arena, "BENI_PENDING_VERBOSE") != null,
            .red = &.{},
        };
        if (mode == .pending) cfg.red = try world.pending.readRed(arena, testing.io, cfg.root);
        return cfg;
    }

    /// The signature `RED` records for `repo_path`, or null.
    fn redSignature(cfg: *const Config, repo_path: []const u8) ?[]const u8 {
        for (cfg.red) |line| {
            if (std.mem.eql(u8, line.path, repo_path)) return line.signature;
        }
        return null;
    }

    /// Whether this process runs `part`.
    fn runs(cfg: *const Config, part: Part) bool {
        return cfg.part == null or cfg.part.? == part;
    }
};

/// An environment variable, or null when it is unset or empty.
fn envOr(arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const value = testing.environ.getAlloc(arena, name) catch return null;
    return if (value.len == 0) null else value;
}

/// What this process's `run/` builds did with their `.run-hash` records,
/// summed over every worker.
const RunCounts = struct {
    /// Not run: the digest was recorded.
    skipped: std.atomic.Value(u32) = .init(0),
    /// Run under Node because the digest was not recorded.
    stale: std.atomic.Value(u32) = .init(0),
    /// Recording mode: builds whose line was written.
    recorded: std.atomic.Value(u32) = .init(0),
    /// Recording mode: builds that failed, so nothing was written for them.
    refused: std.atomic.Value(u32) = .init(0),

    fn add(counter: *std.atomic.Value(u32)) void {
        _ = counter.fetchAdd(1, .monotonic);
    }

    /// Write `<dir>/<part>.txt` (`all.txt` without a part), one
    /// `<counter> <value>` line each, for `tests/run_hash_summary.zig`.
    fn report(counts: *const RunCounts, arena: std.mem.Allocator, dir: []const u8, part: ?Part) !void {
        const io = testing.io;
        try Io.Dir.cwd().createDirPath(io, dir);
        const path = try std.fmt.allocPrint(arena, "{s}/{s}.txt", .{ dir, if (part) |p| @tagName(p) else "all" });
        const text = try std.fmt.allocPrint(arena, "skipped {d}\nstale {d}\nrecorded {d}\nrefused {d}\n", .{
            counts.skipped.load(.monotonic),
            counts.stale.load(.monotonic),
            counts.recorded.load(.monotonic),
            counts.refused.load(.monotonic),
        });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
    }
};
var run_counts: RunCounts = .{};

/// Pending mode prints one line per fixture and keep the detail
/// of each failure to themselves, so `Case` writes its detail through
/// `detail` and records a one-line reason through `because`.
var quiet: bool = false;
threadlocal var reason_buf: [480]u8 = undefined;
threadlocal var reason_len: usize = 0;
/// Owns the text `expectExit` summarises; failures only, never freed.
threadlocal var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

fn detail(comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    std.debug.print(fmt, args);
}

/// Record why the current case failed, if nothing more specific has.
fn because(comptime fmt: []const u8, args: anytype) void {
    if (reason_len != 0) return;
    const text = std.fmt.bufPrint(&reason_buf, fmt, args) catch blk: {
        const dots = "…";
        @memcpy(reason_buf[reason_buf.len - dots.len ..], dots);
        break :blk reason_buf[0..];
    };
    reason_len = text.len;
}

fn reasonFor(err: anyerror, cfg: *const Config) []const u8 {
    if (err == error.CompilerTimeout) {
        return std.fmt.bufPrint(&reason_buf, "timeout after {d} ms", .{cfg.timeout_ms}) catch "timeout";
    }
    if (reason_len != 0) return reason_buf[0..reason_len];
    return @errorName(err);
}

/// The RED SIGNATURE of a failing case (`plans/checker-rewrite.md` §2.4
/// rule (d), S13): what the compiler and the program did, in a form
/// `tests/pending/RED` records per fixture, so pending mode can tell a
/// fixture that is red for its bug from one that has drifted into being red
/// for another reason — a typo, a malformed program, a different bug.
///
///   timeout                              the compiler did not finish
///   crash=<signal>                       the compiler died of a signal
///   exit=<n> codes=<code>×<k>,…          the compiler exited n; every code
///                                        it reported, sorted, with its count
///                                        (`codes=none` when there were none)
///   … why=<code|count|position|message|diag|stdout>
///                                        a bad fixture whose compiler exited
///                                        as expected: WHICH part of its
///                                        `.codes` (or `.diag`) disagreed —
///                                        the codes, their number, their
///                                        positions or their text
///   <pass>: …                            a `run/` fixture: `dev` or
///                                        `release`, the pass that failed
///   exit=0 program-exit=<n>              the emitted program exited n
///   exit=0 stdout-differs                it printed something else
///   exit=0 <ext>-differs                 a whole golden (`iface`, `ast`, …)
///
/// The `why=` suffix refines S13's signature for `.codes` fixtures: without
/// it a fixture red for its message and the same fixture red for a typo in
/// a line number would sign the same.
threadlocal var class_buf: [256]u8 = undefined;
threadlocal var class_len: usize = 0;

/// Record the failure's signature, if nothing has yet: the FIRST failure of
/// a case is the one it stops on.
fn classify(comptime fmt: []const u8, args: anytype) void {
    if (class_len != 0) return;
    const text = std.fmt.bufPrint(&class_buf, fmt, args) catch return;
    class_len = text.len;
}

fn classFor(err: anyerror) []const u8 {
    if (err == error.CompilerTimeout) return "timeout";
    if (class_len != 0) return class_buf[0..class_len];
    return @errorName(err);
}

/// `exit=<n> codes=<code>×<count>,…` for a finished compiler run (the codes
/// sorted by name, `none` when there are none, `unparsed` when stderr is
/// not a JSON diagnostic list), or `crash=<signal>`. The whole multiset and
/// not only the first code: a second bug, or a typo that
/// adds one more diagnostic behind the first, changes the signature.
fn failSignature(arena: std.mem.Allocator, r: world.Result) []const u8 {
    return switch (r.term) {
        .exited => |n| std.fmt.allocPrint(arena, "exit={d} codes={s}", .{ n, codeCounts(arena, r.stderr) }) catch "exit",
        .signal => |sig| std.fmt.allocPrint(arena, "crash={t}", .{sig}) catch "crash",
        else => "crash=unknown",
    };
}

fn codeCounts(arena: std.mem.Allocator, stderr: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, stderr, " \r\n");
    if (trimmed.len == 0) return "none";
    const diags = std.json.parseFromSliceLeaky([]diagnostic.Diagnostic, arena, trimmed, .{}) catch return "unparsed";
    if (diags.len == 0) return "none";
    var names: std.ArrayList([]const u8) = .empty;
    for (diags) |d| names.append(arena, @tagName(d.code)) catch return "unparsed";
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < names.items.len) {
        var j = i;
        while (j < names.items.len and std.mem.eql(u8, names.items[j], names.items[i])) j += 1;
        if (i != 0) out.append(arena, ',') catch return "unparsed";
        out.print(arena, "{s}×{d}", .{ names.items[i], j - i }) catch return "unparsed";
        i = j;
    }
    return out.items;
}

/// A stderr stream in a few words: the codes and start positions of a JSON
/// diagnostic list, the titles of a rendered one, or its first line.
fn summarize(arena: std.mem.Allocator, stderr: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, stderr, " \r\n");
    if (trimmed.len == 0) return "(no stderr)";
    var out: std.ArrayList(u8) = .empty;
    if (trimmed[0] == '[') {
        if (std.json.parseFromSliceLeaky([]diagnostic.Diagnostic, arena, trimmed, .{})) |diags| {
            for (diags, 0..) |d, i| {
                if (i != 0) out.appendSlice(arena, ", ") catch return trimmed;
                out.print(arena, "{t} {d}:{d}", .{ d.code, d.span.start.line, d.span.start.col }) catch return trimmed;
            }
            return out.items;
        } else |_| {}
    }
    // The rendered form: every `-- TITLE ----- file` header.
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "-- ")) continue;
        const end = std.mem.indexOf(u8, line, " --") orelse line.len;
        if (out.items.len != 0) out.appendSlice(arena, ", ") catch return trimmed;
        out.appendSlice(arena, line[3..end]) catch return trimmed;
    }
    if (out.items.len != 0) return out.items;
    // A JavaScript error: its `SomethingError: …` line, else the first line.
    var js = std.mem.splitScalar(u8, trimmed, '\n');
    while (js.next()) |line| {
        if (std.mem.indexOf(u8, line, "Error") != null and std.mem.indexOf(u8, line, "    at ") == null) return line;
    }
    return trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len];
}

/// The first diagnostic's message, first line only: what a pending-mode RED
/// line adds to `summarize`'s codes, so a failed build says WHY without a
/// re-run by hand. Empty when there is none.
fn messageHead(arena: std.mem.Allocator, stderr: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, stderr, " \r\n");
    if (trimmed.len != 0 and trimmed[0] == '[') {
        if (std.json.parseFromSliceLeaky([]diagnostic.Diagnostic, arena, trimmed, .{})) |diags| {
            if (diags.len == 0) return "";
            const m = diags[0].message;
            return m[0 .. std.mem.indexOfScalar(u8, m, '\n') orelse m.len];
        } else |_| {}
    }
    // The rendered form: the first non-blank line after the first header.
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "-- ")) continue;
        while (lines.next()) |next| {
            const t = std.mem.trim(u8, next, " \r");
            if (t.len != 0) return t;
        }
    }
    return "";
}

/// A stream on one line: newlines as ` | `, capped.
fn oneLine(arena: std.mem.Allocator, text: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, text, "\n");
    const capped = t[0..@min(t.len, 160)];
    const out = std.mem.replaceOwned(u8, arena, capped, "\n", " | ") catch return capped;
    return out;
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
    /// Under `<kind>/markup/`: `--platform=html` is added to the argv, so
    /// the fixture's markup is typed against the HTML vocabulary.
    markup: bool = false,

    /// Whether `text` is in the fixture's repo-relative path, the path
    /// `BENI_CORPUS_ONLY` and `BENI_BLESS_ONLY` are matched against.
    fn matches(fixture: Fixture, arena: std.mem.Allocator, text: []const u8) !bool {
        const path = try std.fs.path.join(arena, &.{ fixture.dir, fixture.name });
        return std.mem.indexOf(u8, path, text) != null;
    }
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
        if (entry.kind == .directory and projects and !std.mem.eql(u8, entry.name, "core") and !std.mem.eql(u8, entry.name, "markup")) {
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
    cfg: *const Config,

    /// Pending mode's verdict on one fixture (`plans/checker-rewrite.md`
    /// §2.4): print RED or GREEN, and return false only when the fixture
    /// breaks a rule — (a) it is malformed, (b) it is GREEN and so must be
    /// promoted, (d) it is red for another reason than `RED` records.
    fn pending(c: Case, path: []const u8) !bool {
        const rel = if (std.mem.startsWith(u8, path, c.cfg.root) and path.len > c.cfg.root.len)
            path[c.cfg.root.len + 1 ..]
        else
            path;

        // Rule (a): a finding named, and exactly the golden its kind needs.
        const ck = c.findingId() catch |err| {
            std.debug.print("PENDING  MALFORMED  {s}: {t} — the first line of a pending fixture (or of the first `.beni` of a project) is `-- CK-NN: <what it proves>`\n", .{ rel, err });
            return false;
        };
        if (c.malformedGolden()) |what| {
            std.debug.print("PENDING  MALFORMED  {s}  {s}  {s}\n", .{ ck, rel, what });
            return false;
        }
        const repo_path = std.mem.trimEnd(u8, path, "/");
        // Rule (d)'s record: the signature `tests/pending/RED` holds for this
        // fixture, so a change cannot drift it from "red for the bug" to "red
        // for a typo" unseen.
        const recorded = c.cfg.redSignature(repo_path);

        reason_len = 0;
        class_len = 0;
        const verdict: ?[]const u8 = if (c.run()) |_| null else |err| blk: {
            const signature = classFor(err);
            std.debug.print("PENDING  RED    {s}  {s}  [{s}]  {s}\n", .{ ck, rel, signature, reasonFor(err, c.cfg) });
            break :blk signature;
        };
        const green = verdict == null;
        if (green) std.debug.print("PENDING  GREEN  {s}  {s}\n", .{ ck, rel });

        // Rule (a), the record half: red with no `RED` line at all.
        if (verdict) |signature| if (recorded == null) {
            std.debug.print("PENDING  MALFORMED  {s}  {s}  no line in {s}/RED: add `{s} {s}` once the reason is checked against the finding (tests/pending/README.md)\n", .{ ck, rel, c.cfg.root, repo_path, signature });
            return false;
        };
        // Rule (d): red, but not for the recorded reason — a defect of the
        // fixture or a change in the bug. Either way `RED` is updated
        // deliberately, in the same commit, and never silently.
        if (verdict) |signature| if (!std.mem.eql(u8, signature, recorded.?)) {
            std.debug.print("PENDING  RULE (d)  {s}  {s} is red as [{s}], and {s}/RED records [{s}]\n", .{ ck, rel, signature, c.cfg.root, recorded.? });
            return false;
        };
        // Rule (b): fixed on the checker the gates run, so it belongs in the
        // corpus now, where the gates keep it fixed.
        if (green) {
            std.debug.print(
                "PENDING  RULE (b)  {s}  {s} is GREEN: promote it now — `git mv {s} {s}/{s}` (with its goldens), and bless a `.diag` for any `.codes` (plans/checker-rewrite.md §2.6)\n",
                .{ ck, rel, path, default_root, rel },
            );
            return false;
        }
        return true;
    }

    /// The `CK-NN` a pending fixture names on its first line: the fixture's
    /// own, or the alphabetically first `.beni` of a project.
    fn findingId(c: Case) ![]const u8 {
        var file = try c.fixturePath();
        if (c.fixture.project) {
            var dir = try Io.Dir.cwd().openDir(testing.io, file, .{ .iterate = true });
            defer dir.close(testing.io);
            var first: ?[]const u8 = null;
            var it = dir.iterate();
            while (try it.next(testing.io)) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".beni")) continue;
                if (first == null or std.mem.lessThan(u8, entry.name, first.?)) first = try c.arena.dupe(u8, entry.name);
            }
            file = try std.fs.path.join(c.arena, &.{ file, first orelse return error.ProjectHasNoModule });
        }
        const text = try Io.Dir.cwd().readFileAlloc(testing.io, file, c.arena, .limited(world.max_stream_bytes));
        const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
        const prefix = "-- CK-";
        if (!std.mem.startsWith(u8, line, prefix)) return error.NoFindingLine;
        // Two digits or more: finding IDs are never renumbered, and a
        // three-digit one parses like a two-digit one.
        var end = prefix.len;
        while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
        if (end - prefix.len < 2) return error.NoFindingLine;
        if (!std.mem.startsWith(u8, line[end..], ": ")) return error.NoFindingLine;
        return line[3..end];
    }

    /// Why the fixture's goldens are malformed for pending mode, or null.
    fn malformedGolden(c: Case) ?[]const u8 {
        const has_codes = c.goldenExists("codes");
        const ext = c.kind.golden() orelse return if (has_codes) "a `.codes` golden on a kind that runs no `check`" else null;
        const has_golden = c.goldenExists(ext);
        if (has_codes and !c.kind.takesCodes()) return "a `.codes` golden on a kind whose golden is not a diagnostic list";
        if (has_codes and has_golden) return "both a `.diag` and a `.codes`: keep one";
        if (!has_codes and !has_golden) return "no golden";
        if (has_codes) {
            const text = Io.Dir.cwd().readFileAlloc(testing.io, c.goldenPath("codes") catch return "unreadable .codes", c.arena, .limited(world.max_stream_bytes)) catch return "unreadable .codes";
            _ = parseCodes(c.arena, text) catch |err| return if (err == error.UnknownDiagnosticCode)
                "a `.codes` line names a code that `diagnostic.Code` does not have"
            else
                "a `.codes` line that does not parse: `code [file:]line:col|line:*|* [contains \"…\"|lacks \"…\"]…`";
        }
        return null;
    }

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
            .build_bad, .build_bad_release => try c.buildBad(),
            .run => try c.runProgram(),
            .emit => try c.emitted(),
            .regress => {
                const has_diag = c.goldenExists("diag");
                const has_ast = c.goldenExists("ast");
                if (has_diag) return c.bad();
                if (has_ast) return c.good();
                if (c.bless) return c.good(); // blessing a regress fixture pins it as good
                detail("{s}: a regress fixture needs a .diag or a .ast golden\n", .{c.fixture.name});
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
        return c.w.runWith(try c.argv(args), .{ .raw_diagnostics = true, .cwd = .inherit, .timeout_ms = c.cfg.timeout_ms });
    }

    /// Same as `compiler`, in the world's project directory (for files the
    /// case wrote itself).
    fn inProject(c: Case, args: []const []const u8) !world.Result {
        return c.w.runWith(try c.argv(args), .{ .raw_diagnostics = true, .timeout_ms = c.cfg.timeout_ms });
    }

    /// `args`, plus `--core` for a fixture under `core/`, plus `--no-cache`
    /// for the two commands that take it.
    ///
    /// **`--no-cache` is not tidiness, it is the corpus's premise.** The cache
    /// is on by default and these cases run with cwd = the REPO
    /// ROOT, so without the flag every one of ~576 fixtures would share one
    /// `.beni-cache/` that survives between suite runs — and a golden compared
    /// against a run that may have hit an entry written by a different case,
    /// or by yesterday's build, is a golden compared against history. The
    /// cached path is covered where it can be controlled, by `cache_test.zig`
    /// and `cutoff_test.zig`, each on a project of its own with a fresh cache
    /// directory.
    ///
    /// `fmt` and `dump` are left alone: neither takes a cache flag at all
    /// (`frontend.md` §1), so passing one would be `unknown option` and exit 2.
    fn argv(c: Case, args: []const []const u8) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        try list.appendSlice(c.arena, args);
        if (c.fixture.core) try list.append(c.arena, "--core");
        if (c.fixture.markup and args.len != 0 and !std.mem.eql(u8, args[0], "fmt")) try list.append(c.arena, "--platform=html");
        if (args.len != 0 and (std.mem.eql(u8, args[0], "check") or std.mem.eql(u8, args[0], "build"))) {
            try list.append(c.arena, "--no-cache");
        }
        return list.items;
    }

    fn good(c: Case) !void {
        const r = try c.compiler(&.{ "dump", "--stage=ast", try c.fixturePath() });
        try expectExit(0, r);
        // `dump` exits 0 even with syntax errors (the tree is its product);
        // "parses clean" means no diagnostic at all.
        if (r.stderr.len != 0) {
            detail("{s}: a good fixture must produce no diagnostics\n--- stderr ---\n{s}\n", .{ c.fixture.name, r.stderr });
            because("diagnostics where none are allowed: {s}", .{summarize(c.arena, r.stderr)});
            classify("{s}", .{failSignature(c.arena, r)});
            return error.GoodFixtureHasDiagnostics;
        }
        try c.expectGolden("ast", r.stdout);
        try c.tokens(0);
    }

    /// The optional token golden of a `parse/` fixture: when `X.tokens`
    /// exists, `dump --stage=tokens` must print it exactly. It is how the
    /// lexer's own decisions — which `<` opens markup, where a text run
    /// ends — are pinned where the AST cannot show them. A fixture opts in
    /// by carrying the file; blessing rewrites it. `exit_code` is the one
    /// the dump owes: 1 when the file has diagnostics, as a bad one has.
    fn tokens(c: Case, exit_code: u8) !void {
        if (!c.goldenExists("tokens")) return;
        const r = try c.compiler(&.{ "dump", "--stage=tokens", try c.fixturePath() });
        try expectExit(exit_code, r);
        try c.expectGolden("tokens", r.stdout);
    }

    fn bad(c: Case) !void {
        if (c.goldenExists("codes")) {
            // Keyed on WHERE the fixture is, not on the mode: a `.codes` is a
            // red fixture's stand-in for a `.diag`, and a fixture under the
            // gated corpus must pin the whole diagnostic, whatever mode a hand
            // run happens to use.
            const path = try c.fixturePath();
            if (!std.mem.startsWith(u8, path, pending_root ++ "/")) {
                detail("{s}: a `.codes` golden is accepted only under tests/pending/ (plans/checker-rewrite.md §2.3); bless the full `.diag`\n", .{c.fixture.name});
                because("a `.codes` golden outside tests/pending/", .{});
                return error.CodesOutsidePending;
            }
            return c.badCodes();
        }
        const golden = try c.goldenPath("diag");
        if (!c.goldenExists("diag") and !c.bless) {
            detail("{s}: a bad fixture without {s} is a failure, not a pass; set BENI_WRITE_EXPECTED=1 to create it\n", .{ c.fixture.name, golden });
            return error.MissingDiagGolden;
        }
        const r = try c.compiler(&.{ "check", "--diagnostics=json", try c.fixturePath() });
        try expectExit(1, r);
        c.expectGolden("diag", r.stderr) catch |err| {
            classify("{s} why=diag", .{failSignature(c.arena, r)});
            return err;
        };
        try c.tokens(1);
    }

    /// The pending form of `bad` (`plans/checker-rewrite.md` §2.3): the
    /// `.codes` golden names each diagnostic's code and start, and any
    /// substrings its message must or must not hold. Exit 1, nothing on
    /// stdout, and exactly as many diagnostics as lines, warnings included.
    fn badCodes(c: Case) !void {
        const text = try Io.Dir.cwd().readFileAlloc(testing.io, try c.goldenPath("codes"), c.arena, .limited(world.max_stream_bytes));
        const codes = try parseCodes(c.arena, text);
        const wanted = codes;
        const r = try c.compiler(&.{ "check", "--diagnostics=json", try c.fixturePath() });
        const got = summarize(c.arena, r.stderr);
        if (r.exit_code != 1) {
            detail("{s}: expected exit 1, got {d}\n--- stderr ---\n{s}\n", .{ c.fixture.name, r.exit_code, r.stderr });
            because("exit {d}, expected 1: {s}", .{ r.exit_code, got });
            classify("{s}", .{failSignature(c.arena, r)});
            return error.UnexpectedExitCode;
        }
        if (r.stdout.len != 0) {
            because("stdout is not empty: {s}", .{oneLine(c.arena, r.stdout)});
            classify("{s} why=stdout", .{failSignature(c.arena, r)});
            return error.UnexpectedStdout;
        }
        const trimmed = std.mem.trim(u8, r.stderr, " \r\n");
        const diags = std.json.parseFromSliceLeaky([]diagnostic.Diagnostic, c.arena, trimmed, .{}) catch {
            because("stderr is not a diagnostics array: {s}", .{got});
            classify("{s}", .{failSignature(c.arena, r)});
            return error.DiagnosticsNotJson;
        };

        // Whether the codes the run produced are the ones the golden lists:
        // if not, the fixture is red as `why=code`; if so, the difference is
        // in the count, the positions or the text.
        const sig = failSignature(c.arena, r);
        const same_set = std.mem.eql(u8, try codeSet(c.arena, diags), try wantedSet(c.arena, wanted));

        if (diags.len != wanted.len) {
            detail("{s}: expected {d} diagnostics, got {d}\n--- stderr ---\n{s}\n", .{ c.fixture.name, wanted.len, diags.len, r.stderr });
            because("{d} diagnostics, expected {d}: {s}", .{ diags.len, wanted.len, got });
            classify("{s} why={s}", .{ sig, if (same_set) "count" else "code" });
            return error.DiagnosticCount;
        }
        for (wanted, diags, 1..) |want, d, n| {
            const code = @tagName(d.code);
            if (!want.matchesAt(d)) {
                const expected_at = try want.at(c.arena);
                detail("{s}: diagnostic {d} is {s} at {s}:{d}:{d}, expected {s} at {s}\n--- stderr ---\n{s}\n", .{ c.fixture.name, n, code, d.span.file, d.span.start.line, d.span.start.col, want.code, expected_at, r.stderr });
                because("diagnostic {d} is {s} {d}:{d}, expected {s} {s} (all: {s})", .{ n, code, d.span.start.line, d.span.start.col, want.code, expected_at, got });
                classify("{s} why={s}", .{ sig, if (same_set) "position" else "code" });
                return error.DiagnosticMismatch;
            }
            for (want.contains) |needle| {
                if (std.mem.indexOf(u8, d.message, needle) == null) {
                    detail("{s}: diagnostic {d}'s message lacks \"{s}\"\n--- message ---\n{s}\n", .{ c.fixture.name, n, needle, d.message });
                    because("{s} {d}:{d} message lacks \"{s}\"", .{ code, d.span.start.line, d.span.start.col, needle });
                    classify("{s} why=message", .{sig});
                    return error.DiagnosticMismatch;
                }
            }
            for (want.lacks) |needle| {
                if (std.mem.indexOf(u8, d.message, needle) != null) {
                    detail("{s}: diagnostic {d}'s message contains \"{s}\"\n--- message ---\n{s}\n", .{ c.fixture.name, n, needle, d.message });
                    because("{s} {d}:{d} message contains \"{s}\"", .{ code, d.span.start.line, d.span.start.col, needle });
                    classify("{s} why=message", .{sig});
                    return error.DiagnosticMismatch;
                }
            }
        }
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
                detail("{s}: a check/depth `Deep` fixture needs a .diag golden\n", .{c.fixture.name});
                return error.MissingDiagGolden;
            }
            return c.bad();
        }
        if (!std.mem.endsWith(u8, stem, "Ok")) {
            detail("{s}: a check/depth fixture must be named `…Ok.beni` or `…Deep.beni`\n", .{c.fixture.name});
            return error.UnpairedDepthFixture;
        }
        if (c.goldenExists("diag")) {
            detail("{s}: a check/depth `Ok` fixture must check CLEAN, so it must have no .diag\n", .{c.fixture.name});
            return error.UnexpectedDiagGolden;
        }
        const r = try c.compiler(&.{ "check", try c.fixturePath() });
        try expectExit(0, r);
        if (r.stderr.len != 0) {
            detail("{s}: one level under the guard must produce no diagnostic\n--- stderr ---\n{s}\n", .{ c.fixture.name, r.stderr });
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
    ///
    /// **`build/bad-release/` is the same three assertions with `--release`
    /// added** (`backend.md` §9), plus a fourth that only this kind can
    /// make: the very same project must build CLEAN without the flag. That
    /// is what makes a fixture here a claim about `--release` and not about
    /// the program — `debug_in_release` is the one code in the catalogue
    /// that a development build does not have.
    fn buildBad(c: Case) !void {
        if (!c.fixture.project) {
            detail("{s}: a build/bad fixture is a DIRECTORY holding a whole project\n", .{c.fixture.name});
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
        if (c.kind.isRelease()) try args.append(c.arena, "--release");
        try args.appendSlice(c.arena, sources.items);

        // The fourth assertion, and it is `build/bad-release/`'s alone: the
        // same sources, same platform, no `--release`, must build clean.
        // Without it a fixture that is simply broken would pass here and
        // claim to be about the flag.
        if (c.kind.isRelease()) {
            var dev: std.ArrayList([]const u8) = .empty;
            try dev.appendSlice(c.arena, args.items[0..3]);
            try dev.append(c.arena, "--out=dev");
            try dev.appendSlice(c.arena, sources.items);
            const ok = try w.runWith(try c.argv(dev.items), .{ .raw_diagnostics = true, .timeout_ms = c.cfg.timeout_ms });
            if (ok.exit_code != 0 or ok.stderr.len != 0) {
                detail(
                    "{s}: a build/bad-release fixture must build CLEAN without --release; it exited {d}\n--- stderr ---\n{s}\n",
                    .{ c.fixture.name, ok.exit_code, ok.stderr },
                );
                because("the build without --release exited {d}: {s}: {s}", .{ ok.exit_code, summarize(c.arena, ok.stderr), messageHead(c.arena, ok.stderr) });
                return error.DevBuildFailed;
            }
        }

        const built = try w.runWith(try c.argv(args.items), .{ .raw_diagnostics = true, .timeout_ms = c.cfg.timeout_ms });
        if (built.exit_code != 1) {
            detail(
                "{s}: a build/bad fixture must FAIL the build; it exited {d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
                .{ c.fixture.name, built.exit_code, built.stdout, built.stderr },
            );
            return error.BuildDidNotFail;
        }
        if (w.exists("out")) {
            detail("{s}: a refused build must write no out/ (boundary.md §4)\n", .{c.fixture.name});
            return error.RefusedBuildWroteOutput;
        }
        if (!c.goldenExists("diag") and !c.bless) {
            detail("{s}: a build/bad fixture without its _expected.diag is a failure, not a pass; set BENI_WRITE_EXPECTED=1 to create it\n", .{c.fixture.name});
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
            detail("{s}: formatter output is not a fixed point\n--- first ---\n{s}\n--- second ---\n{s}\n", .{ c.fixture.name, r.stdout, again.stdout });
            return error.NotAFixedPoint;
        }

        // Structure-preserving: both parse to the same AST. The formatter
        // sorts imports (language.md §9), so the dumps are compared with
        // their import entries in sorted order.
        // Markup's text runs are left out of the comparison: the formatter
        // re-indents them and may break a line where the page shows
        // nothing (language.md §11.15), so their bytes move while what
        // they say does not — which the lowered file, whose text is
        // trimmed and decoded, is compared for below.
        const before = try c.compiler(&.{ "dump", "--stage=ast", fixture });
        const after = try c.inProject(&.{ "dump", "--stage=ast", "Fixed.beni" });
        try expectExit(0, before);
        try expectExit(0, after);
        if (!std.mem.eql(u8, try withoutMarkupText(c.arena, try sortImports(c.arena, before.stdout)), try withoutMarkupText(c.arena, try sortImports(c.arena, after.stdout)))) {
            detail("{s}: formatting changed the AST\n--- before ---\n{s}\n--- after ---\n{s}\n", .{ c.fixture.name, before.stdout, after.stdout });
            return error.AstChanged;
        }

        // Page-preserving: markup says the same after formatting as before
        // (language.md §11.15's governing rule), which the lowered trees
        // show, text as the page shows it.
        if (std.mem.indexOf(u8, before.stdout, "(markup_") != null) {
            const bir_before = try c.compiler(&.{ "dump", "--stage=bir", fixture });
            const bir_after = try c.inProject(&.{ "dump", "--stage=bir", "Fixed.beni" });
            if (bir_before.exit_code != bir_after.exit_code or !std.mem.eql(u8, bir_before.stdout, bir_after.stdout)) {
                detail("{s}: formatting changed what the markup says\n--- before ---\n{s}\n--- after ---\n{s}\n", .{ c.fixture.name, bir_before.stdout, bir_after.stdout });
                return error.PageChanged;
            }
        }

        // Comment-preserving: the same comments, in the same order. The AST
        // dump carries a doc comment as `(doc …)` and drops a plain `--` one
        // entirely, so every claim above is blind to a comment the formatter
        // lost, moved past its neighbour or rewrote — which is the data loss
        // this kind exists to prevent, and it would have shown up only as a
        // golden diff at bless time. The tokens dump lists every comment
        // with its kind and its text (`frontend.md` §1.2).
        const before_comments = try c.compiler(&.{ "dump", "--stage=tokens", fixture });
        const after_comments = try c.inProject(&.{ "dump", "--stage=tokens", "Fixed.beni" });
        try expectExit(0, before_comments);
        try expectExit(0, after_comments);
        const kept = try commentTrailer(c.arena, before_comments.stdout);
        const printed = try commentTrailer(c.arena, after_comments.stdout);
        if (!std.mem.eql(u8, kept, printed)) {
            detail("{s}: formatting changed the comments\n--- before ---\n{s}\n--- after ---\n{s}\n", .{ c.fixture.name, kept, printed });
            return error.CommentsChanged;
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
    ///
    /// **The release pass carries `--allow-debug`, uniformly** (`backend.md`
    /// §9's *The release optimiser*). Since 2026-09-19 a `--release` build
    /// that reaches `Debug` is REFUSED, and `Debug.log` is this corpus's
    /// only instrument for observing evaluation order: 24 of the 121
    /// fixtures use it, among them every `EvalOrder*`, `CallbackOrder*`,
    /// `QuestionOrder` and `SortByKeyOnce` — the very fixtures whose
    /// `--release` run proved the wide inliner unsafe. Without the flag the
    /// second pass would silently stop running them, which is the decay
    /// this pass exists to prevent. Uniformly rather than per fixture,
    /// because a fixture can reach `Debug` through a module it imports and
    /// no grep over its own text would know. That the refusal itself works
    /// is `build/bad-release/`'s, where no flag is passed.
    ///
    /// **A build is run under Node only when its run hash is not
    /// recorded** (`run_hash.zig`). Both builds happen every time and must
    /// be clean; then the digest of the output tree, the golden and the
    /// Node version is looked up in the fixture's `.run-hash`, and a listed
    /// digest means Node already ran exactly this JavaScript and it printed
    /// exactly this golden. Anything else — a changed emitter, runtime or
    /// golden, another Node — runs the program as if there were no record.
    fn runProgram(c: Case) !void {
        var sources: std.ArrayList([]const u8) = .empty;
        if (c.fixture.project) {
            const dir_path = try c.fixturePath();
            var dir = try Io.Dir.cwd().openDir(testing.io, dir_path, .{ .iterate = true });
            defer dir.close(testing.io);
            var it = dir.iterate();
            while (try it.next(testing.io)) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".beni")) continue;
                const name = try c.arena.dupe(u8, entry.name);
                const path = try std.fs.path.join(c.arena, &.{ dir_path, name });
                try c.w.write(name, try Io.Dir.cwd().readFileAlloc(testing.io, path, c.arena, .limited(world.max_stream_bytes)));
                try sources.append(c.arena, name);
            }
            std.mem.sort([]const u8, sources.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lessThan);
        } else {
            const source = try Io.Dir.cwd().readFileAlloc(testing.io, try c.fixturePath(), c.arena, .limited(world.max_stream_bytes));
            try c.w.write(c.fixture.name, source);
            try sources.append(c.arena, c.fixture.name);
        }

        var dev: std.ArrayList([]const u8) = .empty;
        try dev.appendSlice(c.arena, &.{ "build", "--platform=node", "--out=out" });
        // Pending mode reads the codes of a refused build, to classify why a
        // red fixture is red (`classify`); the corpus keeps the rendered form.
        if (c.cfg.mode == .pending) try dev.append(c.arena, "--diagnostics=json");
        try dev.appendSlice(c.arena, sources.items);
        // The fixture's run hashes (`run_hash.zig`): read to skip a build
        // already verified, or — recording — rewritten below with the
        // builds that verify now.
        const record_path = try c.goldenPath(run_hash.ext);
        const recording = c.cfg.run_hashes == .record;
        const record = if (recording) "" else try run_hash.read(c.arena, testing.io, record_path);
        var verified: [2]?[]const u8 = .{ null, null };
        // Recording runs both builds whatever the first did, so one failing
        // build does not cost the other its line.
        var first_error: ?anyerror = null;

        // Each pass runs in the process of its part (`corpus_parts.zig`):
        // the two build to different `--out` directories and compare with
        // their own golden, so neither reads anything the other wrote.
        if (c.cfg.runs(Kind.run.partOf(.dev))) {
            verified[0] = c.runOnce("out", .dev, dev.items, "expected", c.bless, record) catch |err| blk: {
                if (!recording) return err;
                RunCounts.add(&run_counts.refused);
                first_error = err;
                break :blk null;
            };
        }
        if (c.cfg.runs(Kind.run.partOf(.release))) release: {
            // The release pass never blesses `expected`: it is the DEV pass's
            // golden and a release build that disagrees with it is the finding
            // this pass exists to make. A fixture that is allowed to differ says
            // so by carrying its own `.release-expected`, which does bless.
            const separate = c.goldenExists("release-expected");
            var release: std.ArrayList([]const u8) = .empty;
            try release.appendSlice(c.arena, &.{ "build", "--platform=node", "--release", "--allow-debug", "--out=release" });
            if (c.cfg.mode == .pending) try release.append(c.arena, "--diagnostics=json");
            try release.appendSlice(c.arena, sources.items);
            verified[1] = c.runOnce(
                "release",
                .release,
                release.items,
                if (separate) "release-expected" else "expected",
                c.bless and separate,
                record,
            ) catch |err| {
                if (!recording) return err;
                RunCounts.add(&run_counts.refused);
                if (first_error == null) first_error = err;
                break :release;
            };
        }
        if (recording) {
            for (verified) |v| if (v != null) RunCounts.add(&run_counts.recorded);
            try run_hash.write(testing.io, record_path, try run_hash.render(c.arena, &verified));
        }
        if (first_error) |err| return err;
    }

    /// One build-and-run of a `run/` fixture, against `golden`. Node is not
    /// run when `record` (the fixture's `.run-hash`) lists this build's
    /// line. Recording, it returns the line of a build that Node ran and
    /// that matched; otherwise null.
    fn runOnce(c: Case, out_dir: []const u8, pass: RunPass, args: []const []const u8, golden: []const u8, bless: bool, record: []const u8) !?[]const u8 {
        const built = try c.inProject(args);
        if (built.exit_code != 0) {
            detail("{s} [{s}]: build failed\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n", .{ c.fixture.name, out_dir, built.stdout, built.stderr });
            because("[{s}] build exit {d}: {s}: {s}", .{ out_dir, built.exit_code, summarize(c.arena, built.stderr), messageHead(c.arena, built.stderr) });
            classify("{s}: {s}", .{ passName(out_dir), failSignature(c.arena, built) });
            return error.BuildFailed;
        }
        if (built.stderr.len != 0) {
            detail("{s} [{s}]: a run fixture must compile with no diagnostics\n--- stderr ---\n{s}\n", .{ c.fixture.name, out_dir, built.stderr });
            because("[{s}] diagnostics on a build that must be clean: {s}", .{ out_dir, summarize(c.arena, built.stderr) });
            classify("{s}: {s}", .{ passName(out_dir), failSignature(c.arena, built) });
            return error.GoodFixtureHasDiagnostics;
        }

        // Skip Node when this exact output tree, golden and Node were
        // verified together before. Pending mode has no records, and a
        // blessing run exists to look at the output.
        if (c.cfg.run_hashes == .check and c.cfg.mode == .strict and !bless) {
            if (Io.Dir.cwd().readFileAlloc(testing.io, try c.goldenPath(golden), c.arena, .limited(world.max_stream_bytes))) |bytes| {
                const line = try run_hash.line(c.arena, c.w, out_dir, @tagName(pass), golden, bytes);
                if (run_hash.listed(record, line)) {
                    RunCounts.add(&run_counts.skipped);
                    return null;
                }
                RunCounts.add(&run_counts.stale);
            } else |_| {
                // No golden: the comparison below reports it.
            }
        }

        const entry = try std.fmt.allocPrint(c.arena, "{s}/_main.mjs", .{out_dir});
        const program = c.w.nodeWith(entry, c.cfg.timeout_ms) catch |err| {
            detail("{s} [{s}]: cannot run the emitted program ({t}); is node on PATH?\n", .{ c.fixture.name, out_dir, err });
            return err;
        };
        if (program.exit_code != 0) {
            detail(
                "{s} [{s}]: the emitted program exited {d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
                .{ c.fixture.name, out_dir, program.exit_code, program.stdout, program.stderr },
            );
            because("[{s}] program exit {d}: {s}", .{ out_dir, program.exit_code, summarize(c.arena, program.stderr) });
            classify("{s}: exit=0 program-exit={d}", .{ passName(out_dir), program.exit_code });
            return error.ProgramFailed;
        }
        c.expectGoldenMaybeBless(golden, program.stdout, bless) catch |err| {
            classify("{s}: exit=0 stdout-differs", .{passName(out_dir)});
            return err;
        };
        // Verified: the golden now holds exactly what the program printed.
        if (c.cfg.run_hashes != .record) return null;
        return try run_hash.line(c.arena, c.w, out_dir, @tagName(pass), golden, program.stdout);
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
        // `--allow-debug` rides with `--release` here for `run/`'s reason:
        // one rule for the whole corpus, so that a shape golden can be about
        // a `Debug`-using program the day one is wanted.
        if (c.fixture.release) try args.appendSlice(c.arena, &.{ "--release", "--allow-debug" });
        try args.appendSlice(c.arena, sources.items);

        const built = try c.inProject(args.items);
        if (built.exit_code != 0) {
            detail("{s}: build failed\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n", .{ c.fixture.name, built.stdout, built.stderr });
            because("build exit {d}: {s}: {s}", .{ built.exit_code, summarize(c.arena, built.stderr), messageHead(c.arena, built.stderr) });
            return error.BuildFailed;
        }
        if (built.stderr.len != 0) {
            detail("{s}: an emit fixture must compile with no diagnostics\n--- stderr ---\n{s}\n", .{ c.fixture.name, built.stderr });
            return error.GoodFixtureHasDiagnostics;
        }

        const stem = if (c.fixture.project)
            c.fixture.name
        else
            c.fixture.name[0 .. c.fixture.name.len - ".beni".len];
        const emitted_path = try std.fmt.allocPrint(c.arena, "out/{s}.mjs", .{stem});
        const js = c.w.read(emitted_path) catch |err| {
            detail("{s}: the build wrote no {s} ({t})\n", .{ c.fixture.name, emitted_path, err });
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
                detail("{s}: the build wrote {s}, which elimination should have removed\n", .{ c.fixture.name, line });
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
            detail("{s}: a dispatch fixture must produce no diagnostics\n--- stderr ---\n{s}\n", .{ c.fixture.name, checked.stderr });
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
        // Pending mode reads the codes of a refusal to sign it (`classify`).
        const checked = try c.compiler(if (c.cfg.mode == .pending) &.{ "check", "--diagnostics=json", path } else &.{ "check", path });
        try expectExit(0, checked);
        if (checked.stderr.len != 0 or c.goldenExists("diag")) {
            const json = try c.compiler(&.{ "check", "--diagnostics=json", path });
            try expectExit(0, json);
            if (json.stderr.len == 0 and !c.bless) {
                detail("{s}: a silent check/good fixture must not have a .diag golden\n", .{c.fixture.name});
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
            detail("blessed {s}\n", .{golden});
            return;
        }
        const expected = Io.Dir.cwd().readFileAlloc(testing.io, golden, c.arena, .limited(world.max_stream_bytes)) catch |err| {
            detail("{s}: cannot read golden {s} ({t}); set BENI_WRITE_EXPECTED=1 to create it\n", .{ c.fixture.name, golden, err });
            return error.MissingGolden;
        };
        if (!std.mem.eql(u8, expected, actual)) {
            detail("{s}: output differs from {s}; set BENI_WRITE_EXPECTED=1 to bless\n--- expected ---\n{s}\n--- actual ---\n{s}\n", .{ c.fixture.name, golden, expected, actual });
            because("{s} differs: expected `{s}`, got `{s}`", .{ ext, oneLine(c.arena, expected), if (std.mem.eql(u8, ext, "diag")) summarize(c.arena, actual) else oneLine(c.arena, actual) });
            // `expected` is a `run/` stdout, which `runOnce` signs with its pass.
            if (!std.mem.eql(u8, ext, "diag") and !std.mem.eql(u8, ext, "expected") and !std.mem.eql(u8, ext, "release-expected")) classify("exit=0 {s}-differs", .{ext});
            return error.GoldenMismatch;
        }
    }
};

/// One line of a `.codes` golden (`plans/checker-rewrite.md` §2.3):
///
///   code [file:]line:col [contains "…" | lacks "…"]…
///   code [file:]line:*   [contains "…" | lacks "…"]…
///   code [file:]*        [contains "…" | lacks "…"]…
///
/// `file`, when given, must equal the span's file or be a path suffix of
/// it, which is how a project fixture names a diagnostic in one module.
///
/// `*` leaves the column (`line:*`) or the whole position open. It exists
/// for the one case a red fixture
/// cannot avoid: the finding fixes the code but the spec has not yet said
/// which region carries it. Each use says so in the fixture's intent
/// comment, and the slice that turns the fixture green blesses the real
/// `.diag`, which pins the position.
const CodeLine = struct {
    code: []const u8,
    file: ?[]const u8,
    /// Null: `*`, any position; a line with a null `col`: `line:*`.
    line: ?u32,
    col: ?u32,
    contains: []const []const u8,
    lacks: []const []const u8,

    /// The code, the file and the position agree (the text is checked
    /// separately, so a wrong text is reported as such).
    fn matchesAt(want: CodeLine, d: diagnostic.Diagnostic) bool {
        if (!std.mem.eql(u8, @tagName(d.code), want.code)) return false;
        if (want.file) |file| {
            const exact = std.mem.eql(u8, d.span.file, file);
            const suffix = std.mem.endsWith(u8, d.span.file, file) and d.span.file.len > file.len and
                d.span.file[d.span.file.len - file.len - 1] == '/';
            if (!exact and !suffix) return false;
        }
        if (want.line) |line| {
            if (d.span.start.line != line) return false;
        }
        if (want.col) |col| {
            if (d.span.start.col != col) return false;
        }
        return true;
    }

    fn at(want: CodeLine, arena: std.mem.Allocator) ![]const u8 {
        const line = want.line orelse return "*";
        const col = want.col orelse return std.fmt.allocPrint(arena, "{d}:*", .{line});
        return std.fmt.allocPrint(arena, "{d}:{d}", .{ line, col });
    }
};

/// `code:<a>,<b>…` over `diags`: their codes, sorted and unique.
fn codeSet(arena: std.mem.Allocator, diags: []const diagnostic.Diagnostic) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (diags) |d| try names.append(arena, @tagName(d.code));
    return joinSet(arena, names.items);
}

fn wantedSet(arena: std.mem.Allocator, wanted: []const CodeLine) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (wanted) |w| try names.append(arena, w.code);
    return joinSet(arena, names.items);
}

fn joinSet(arena: std.mem.Allocator, names: [][]const u8) ![]const u8 {
    std.mem.sort([]const u8, names, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    var unique: std.ArrayList([]const u8) = .empty;
    for (names) |name| {
        if (unique.items.len != 0 and std.mem.eql(u8, unique.items[unique.items.len - 1], name)) continue;
        try unique.append(arena, name);
    }
    return std.mem.join(arena, ",", unique.items);
}

fn parseCodes(arena: std.mem.Allocator, text: []const u8) ![]const CodeLine {
    var out: std.ArrayList(CodeLine) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var rest = line;
        const code = try word(&rest);
        // A misspelt code would keep a fixture red forever, signed as if
        // the finding were the reason: refuse it as malformed instead.
        if (std.meta.stringToEnum(diagnostic.Code, code) == null) return error.UnknownDiagnosticCode;
        const where = try word(&rest);
        // `[file:]line:col`, `[file:]line:*` (the line is fixed and the
        // column is open), or `[file:]*` (the position is open).
        var file: ?[]const u8 = null;
        var row: ?u32 = null;
        var col: ?u32 = null;
        const last = std.mem.lastIndexOfScalar(u8, where, ':');
        const tail = if (last) |l| where[l + 1 ..] else where;
        const head = if (last) |l| where[0..l] else "";
        if (std.mem.eql(u8, tail, "*")) {
            if (last != null) {
                // `line:*`, `file:line:*` or `file:*`.
                const mid = std.mem.lastIndexOfScalar(u8, head, ':');
                const piece = if (mid) |m| head[m + 1 ..] else head;
                if (std.fmt.parseInt(u32, piece, 10)) |n| {
                    row = n;
                    if (mid) |m| file = head[0..m];
                } else |_| file = head;
            }
        } else {
            if (last == null) return error.BadCodesLine;
            col = try std.fmt.parseInt(u32, tail, 10);
            const mid = std.mem.lastIndexOfScalar(u8, head, ':');
            row = try std.fmt.parseInt(u32, if (mid) |m| head[m + 1 ..] else head, 10);
            if (mid) |m| file = head[0..m];
        }
        var contains: std.ArrayList([]const u8) = .empty;
        var lacks: std.ArrayList([]const u8) = .empty;
        while (true) {
            rest = std.mem.trimStart(u8, rest, " \t");
            if (rest.len == 0) break;
            const verb = try word(&rest);
            rest = std.mem.trimStart(u8, rest, " \t");
            if (rest.len < 2 or rest[0] != '"') return error.BadCodesLine;
            const close = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return error.BadCodesLine;
            const needle = rest[1..close];
            rest = rest[close + 1 ..];
            if (std.mem.eql(u8, verb, "contains")) {
                try contains.append(arena, needle);
            } else if (std.mem.eql(u8, verb, "lacks")) {
                try lacks.append(arena, needle);
            } else return error.BadCodesLine;
        }
        try out.append(arena, .{
            .code = code,
            .file = file,
            .line = row,
            .col = col,
            .contains = contains.items,
            .lacks = lacks.items,
        });
    }
    if (out.items.len == 0) return error.EmptyCodes;
    return out.items;
}

/// The next space-delimited word of `rest`, advancing past it.
fn word(rest: *[]const u8) ![]const u8 {
    const s = std.mem.trimStart(u8, rest.*, " \t");
    if (s.len == 0) return error.BadCodesLine;
    const end = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
    rest.* = s[end..];
    return s[0..end];
}

/// The `-- comments` trailer of a tokens dump, one line per comment as
/// `<kind> <body>`.
///
/// Two things are dropped on the way, because the formatter is allowed to
/// change them: the POSITION, which is the whole point of moving a comment
/// onto its own line, and the whitespace between the marker and the body,
/// because `fmt/DocNoSpace` pins that `--|x` becomes `--| x`. The kind stays
/// — a doc block turning into a plain comment is a change of meaning — and
/// so does every byte of the body.
fn commentTrailer(arena: std.mem.Allocator, dump: []const u8) ![]const u8 {
    const heading = "-- comments\n";
    const at = std.mem.indexOf(u8, dump, heading) orelse return "";
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, dump[at + heading.len ..], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // `<line>:<col> <kind> <text>`, and the text runs to the end.
        const after_position = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const rest = line[after_position + 1 ..];
        const after_kind = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        const kind = rest[0..after_kind];
        var body = std.mem.trimStart(u8, rest[@min(after_kind + 1, rest.len)..], "-");
        if (body.len != 0 and (body[0] == '|' or body[0] == '!')) body = body[1..];
        try out.appendSlice(arena, kind);
        try out.append(arena, ' ');
        try out.appendSlice(arena, std.mem.trimStart(u8, body, " \t"));
        try out.append(arena, '\n');
    }
    return out.items;
}

/// An AST dump with its top-level `(import …)` entries (each with the
/// `(exposed …)` lines under it) reordered by their text.
/// An AST dump without its markup text nodes: every `(markup_text "…")`
/// child is cut out with the line break and indentation before it, so the
/// parentheses after it close where they would have had it not been there.
fn withoutMarkupText(arena: std.mem.Allocator, dump: []const u8) ![]const u8 {
    const marker = "(markup_text \"";
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, dump, pos, marker)) |at| {
        // Back over the indentation to the line break before the node.
        var cut = at;
        while (cut > pos and dump[cut - 1] == ' ') cut -= 1;
        if (cut > pos and dump[cut - 1] == '\n') cut -= 1;
        try out.appendSlice(arena, dump[pos..cut]);
        // Past the quoted text, its escapes included, and the `)`.
        var i = at + marker.len;
        while (i < dump.len and dump[i] != '"') : (i += 1) {
            if (dump[i] == '\\') i += 1;
        }
        pos = @min(i + 2, dump.len);
    }
    try out.appendSlice(arena, dump[pos..]);
    return out.items;
}

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
        detail("expected exit {d}, got {d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n", .{ expected, r.exit_code, r.stdout, r.stderr });
        because("exit {d}, expected {d}: {s}: {s}", .{ r.exit_code, expected, summarize(scratch.allocator(), r.stderr), messageHead(scratch.allocator(), r.stderr) });
        classify("{s}", .{failSignature(scratch.allocator(), r)});
        return error.UnexpectedExitCode;
    }
}

/// The pass a `run/` fixture's build belongs to, by its `--out`: `dev` or
/// `release`.
fn passName(out_dir: []const u8) []const u8 {
    return if (std.mem.eql(u8, out_dir, "release")) "release" else "dev";
}
