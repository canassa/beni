//! Build graph for beni (docs/design/frontend.md §2).
//!
//! Steps, all of which must stay green at the end of every milestone:
//!   zig build                 install `beni`
//!   zig build test            hermetic unit tests (no processes, no files)
//!   zig build test-blackbox   spawns a ReleaseSafe `beni`; never folded into `test`
//!   zig build bench           ReleaseFast throughput harness over bench/corpus
//!   zig build fmt-check       `zig fmt --check` over every Zig source tree
//!   zig build gates           the three gates above, in one build graph
//!
//! The black-box suites spawn a ReleaseSafe `beni` built by Zig's
//! self-hosted backend, compiled in seconds. One option switches them to the
//! LLVM build, the code users get, at about a minute's single-threaded
//! compile (CLAUDE.md, *Testing tiers*):
//!   -Dllvm                build the black-box compiler with LLVM instead
//!
//! Options that make a run cheaper while a change is being written:
//!   -Dtest-filter=<text>  compile only the tests whose name contains <text>
//!                         (repeatable), in every test binary a step builds
//!   -Dcorpus=<text>       run only the corpus fixtures whose path contains
//!                         <text>, in `test-blackbox` and `test-pending`
//!   zig build test-blackbox-<file>   one black-box test file (`--list-steps`)
//! `gates` refuses the two filters: a gate runs everything.
//!
//! Every test of the gates' binaries, and every corpus case, is held to a
//! CPU budget (`tests/test_runner.zig`): one that spends more than 1000 ms
//! of CPU, its own and its children's, fails. For profiling only:
//!   -Dtest-budget-ms=<ms> another budget; 0 enforces none
//!
//! And three that are NOT gates — the first two because their fixtures are red
//! by design, the third because a timing claim is not a gate (rule 4):
//!   zig build test-pending        tests/pending/ and the non-timing scenarios
//!   zig build test-pending-perf   the timing scenarios, on a ReleaseFast beni
//!                                 (plans/checker-rewrite.md §2)
//!   zig build test-perf           the FIXED timing scenarios, on a ReleaseFast
//!                                 beni (promoted from test-pending-perf)
//! And the run hashes, not a gate either:
//!   zig build test-run-hashes     run every tests/corpus/run/ program and
//!                                 every program a black-box scenario runs
//!                                 under Node, and record a hash of each
//!                                 that did what its test expects
//!                                 (`tests/blackbox/run_hash.zig`); takes
//!                                 -Dtest-filter, -Dcorpus and -Dllvm
//! And where the test time goes, not a gate either:
//!   zig build test-time-report    run `gates` (or `-Dtime-step=<step>`) with
//!                                 every test process timed, and write the
//!                                 tables into plans/test-time-report.md
//!                                 (`tests/time_report.zig`)
//! And which lines the tests execute, not a gate either; needs kcov, from
//! `nix develop .#coverage`:
//!   zig build coverage            run the black-box suites and the corpus
//!                                 with every beni under kcov and write the
//!                                 merged report into zig-out/coverage/
//!                                 (`tests/coverage.zig`); takes -Dcorpus
//!                                 and -Dtest-filter
//! And random exploration, not a gate either (`src/fuzzing.zig`):
//!   zig build fuzz                the unit tests with their mutation sweeps
//!                                 and stress loops on (`BENI_FUZZ=1`)
//! And the benchmarks' own tests — benchmarks are not part of the gates:
//!   zig build test-bench          the generators' unit tests, and the check
//!                                 that beni accepts the benchmark's program
//! And the cross-language benchmark (docs/design/compare-bench.md §12), which
//! needs `nix develop .#compare` and is not a gate either:
//!   zig build compare-gen         write the generated projects
//!   zig build compare             time them; results/<date>.json and README
//!   zig build compare-smoke       size 1, both modes: acceptance only
//!   zig build compare-render      the README tables again, from a results file
const std = @import("std");
/// The parts the corpus walker is split into (one process each).
const corpus_parts = @import("tests/blackbox/corpus_parts.zig");

/// Where the ReleaseFast compiler the timing scenarios measure is installed,
/// under the prefix: apart from `bin/beni`, the `-Doptimize` build.
const perf_bin_dir = "perf/bin";

/// Where the ReleaseSafe compiler every other black-box suite spawns is
/// installed, under the prefix: the one Zig's self-hosted backend builds.
const safe_bin_dir = "safe/bin";

/// Where the same compiler is installed when `-Dllvm` builds it with LLVM:
/// its own directory, so switching between the two never overwrites the
/// other's binary and each stays cached.
const safe_llvm_bin_dir = "safe-llvm/bin";

/// How many processes `test-perf` spreads its CPU-time scenarios over.
const perf_shards = 7;

/// How many processes `test` runs the library's unit tests in. Past about
/// this many, the slowest single test is the whole step.
const unit_shards = 12;

/// The same for the compare generator's unit tests.
const compare_shards = 2;

/// The black-box test files `test-blackbox` runs besides the corpus walker,
/// each with the number of processes it is split into. `test-run-hashes`
/// records them and `coverage` measures them.
const blackbox_suites = [_]struct { []const u8, u32 }{
    .{ "tests/blackbox/blackbox_test.zig", 6 },
    .{ "tests/blackbox/abuse_test.zig", 3 },
    .{ "tests/blackbox/abuse_wide_test.zig", 4 },
    .{ "tests/blackbox/build_test.zig", 3 },
    .{ "tests/blackbox/cache_test.zig", 4 },
    .{ "tests/blackbox/check_test.zig", 1 },
    .{ "tests/blackbox/cutoff_test.zig", 3 },
    .{ "tests/blackbox/digest_test.zig", 3 },
    .{ "tests/blackbox/docs_test.zig", 1 },
    .{ "tests/blackbox/frontend_test.zig", 1 },
    .{ "tests/blackbox/iface_test.zig", 1 },
    .{ "tests/blackbox/ordering_test.zig", 2 },
};

/// Where `coverage-run` installs its compiler, and the wrapper the suites
/// spawn in its place, under the prefix.
const coverage_bin_dir = "coverage-work/bin";
const coverage_wrapper_dir = "coverage-work/wrapper";

/// Where every process run under kcov leaves its counts, under the prefix:
/// one directory each, merged by `tests/coverage.zig` and kept until the
/// next run, so `zig build coverage -- --report-only` can report it again.
const coverage_raw_dir = "coverage-work/raw";

/// Where the merged report goes, under the prefix.
const coverage_report_dir = "coverage";

/// Where the core package's sources live, relative to the build root. The
/// same string is the prefix of every embedded file's path, so a diagnostic
/// in core names `core/Basics.beni` whether it came from the embedded copy
/// or from the checkout (see `SourceStore`'s header).
const core_dir = "core";

/// Where the platform packages that ship with the compiler live
/// (`docs/design/boundary.md` §5.3: "two platforms ship with the compiler").
/// Each subdirectory is one package: its `beni.json`, its `.beni` modules and
/// the JavaScript they bind to, all embedded so `beni build --platform=node`
/// needs nothing on disk.
const platforms_dir = "platforms";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const llvm = b.option(bool, "llvm", "Build the ReleaseSafe compiler the black-box suites spawn with LLVM, the code users get, instead of Zig's self-hosted backend: about a minute's compile instead of seconds") orelse false;
    const test_filters = b.option([]const []const u8, "test-filter", "Compile only the tests whose name contains this text (repeatable); `gates` refuses it") orelse &.{};
    const corpus_only = b.option([]const u8, "corpus", "Run only the corpus fixtures whose repo-relative path contains this text; `gates` refuses it") orelse "";
    // The CPU budget of one test or corpus case (`tests/test_runner.zig`),
    // on every run of a binary the gates run; the random sweeps of `fuzz`,
    // the pending and timing steps and the run-hash recording are not held
    // to it. Another value is for profiling a test locally.
    const test_budget_ms = b.option(u64, "test-budget-ms", "Fail a test or corpus case that spends more CPU than this, its own and its children's (default 1000; 0 enforces none; for local profiling)") orelse 1000;
    const budget_env = b.fmt("{d}", .{test_budget_ms});

    // `diagnostic` is a NAMED module because two roots need the same schema:
    // the compiler renders it and the black-box suite parses it back. A field
    // added or renamed in production then fails the tests at compile time
    // instead of silently (frontend.md §1.1). It imports only `std`.
    const diagnostic_mod = b.addModule("diagnostic", .{
        .root_source_file = b.path("src/diagnostic.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The library root. `src/main.zig` is a thin shell over it, so every
    // piece of behaviour (including argument parsing) is reachable from the
    // hermetic test root without spawning anything.
    const beni_mod = b.addModule("beni", .{
        .root_source_file = b.path("src/beni.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "diagnostic", .module = diagnostic_mod }},
    });
    // The core package (checker.md §3): every `core/**/*.beni` embedded, the
    // list generated from the directory at configure time so adding a core
    // module is dropping in a file. It is part of the compiler, not of a
    // test, so it hangs off the library module every root imports.
    beni_mod.addImport("core_package", embedCore(b, core_dir));
    // The platform packages (boundary.md §8, B2), embedded the same way.
    beni_mod.addImport("platform_packages", embedPlatforms(b, platforms_dir));
    // The compiler build id (`fast-compiler.md` §8): the cache key's term for
    // "which compiler produced this entry". Computed here rather than by
    // hashing the installed binary at run time, which is correct and costs
    // ~2 ms of a 15 ms warm budget.
    beni_mod.addImport("build_options", buildIdOptions(b, target, optimize, null));

    const exe = b.addExecutable(.{
        .name = "beni",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "beni", .module = beni_mod },
                .{ .name = "diagnostic", .module = diagnostic_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Build and run beni");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // ---- Hermetic suite. ----
    // `src/beni.zig` references every internal module from its test block;
    // `diagnostic` is its own module and therefore its own test artifact.
    // The generator is tested here too (same output for the same seed) so the
    // bench corpus can be trusted to be stable.
    // Fixture corpora reach the hermetic suite as embedded bytes (frontend.md
    // §2, tests/fixtures): a generated manifest module per directory, so a
    // test walks `@import("corpus_parse_good").fixtures` without touching
    // the filesystem. Only test blocks import them, so the binary does not
    // carry the bytes.
    beni_mod.addImport("corpus_parse_good", embedCorpus(b, "tests/corpus/parse/good"));
    beni_mod.addImport("corpus_bir", embedCorpus(b, "tests/corpus/bir"));

    const beni_tests = b.addTest(.{ .name = "unit_test", .root_module = beni_mod, .test_runner = testRunner(b), .filters = test_filters });
    const diagnostic_tests = b.addTest(.{ .name = "diagnostic_test", .root_module = diagnostic_mod, .test_runner = testRunner(b), .filters = test_filters });
    const gen_tests = b.addTest(.{
        .name = "bench_gen_test",
        .filters = test_filters,
        .test_runner = testRunner(b),
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/gen.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // The test-time report's aggregator (`tests/time_report.zig`), tested
    // with std's runner: `tests/test_runner.zig` imports the recorder the
    // aggregator reads, and one file cannot belong to two modules of a
    // binary.
    const time_report_tests = b.addTest(.{
        .name = "time_report_unit_test",
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/time_report.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run the hermetic unit tests");
    // One binary, `unit_shards` processes: the test runner runs a test in
    // the process whose number is its index modulo the count, so the suite
    // takes about as long as its slowest test instead of the sum of all.
    for (0..unit_shards) |k| {
        const run = runTests(b, beni_tests);
        run.setEnvironmentVariable("BENI_TEST_SHARD", b.fmt("{d}/{d}", .{ k, unit_shards }));
        run.setEnvironmentVariable("BENI_TEST_BUDGET_MS", budget_env);
        run.setName(b.fmt("run beni tests shard {d}/{d}", .{ k, unit_shards }));
        test_step.dependOn(&run.step);
    }
    {
        const run = runTests(b, diagnostic_tests);
        run.setEnvironmentVariable("BENI_TEST_BUDGET_MS", budget_env);
        test_step.dependOn(&run.step);
    }
    test_step.dependOn(&runTests(b, time_report_tests).step);
    // The coverage report's own logic (`tests/coverage.zig`), which needs no
    // kcov to test.
    const coverage_tests = b.addTest(.{
        .name = "coverage_unit_test",
        .filters = test_filters,
        .test_runner = testRunner(b),
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/coverage.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    {
        const run = runTests(b, coverage_tests);
        run.setEnvironmentVariable("BENI_TEST_BUDGET_MS", budget_env);
        test_step.dependOn(&run.step);
    }

    // The same unit tests with their random exploration on (`BENI_FUZZ=1`,
    // `src/fuzzing.zig`): the byte-format mutation sweeps and the lexer's
    // and parser's stress loops. The gates run one hand-picked input per
    // check instead; this finds the input nobody picked, and is not a gate.
    // `BENI_STRESS_ITERATIONS` in the environment raises the stress counts.
    const fuzz_step = b.step("fuzz", "Run the unit tests with their random sweeps on (not a gate)");
    for (0..unit_shards) |k| {
        const run = runTests(b, beni_tests);
        run.setEnvironmentVariable("BENI_FUZZ", "1");
        run.setEnvironmentVariable("BENI_TEST_SHARD", b.fmt("{d}/{d}", .{ k, unit_shards }));
        run.setName(b.fmt("run beni tests with fuzzing shard {d}/{d}", .{ k, unit_shards }));
        fuzz_step.dependOn(&run.step);
    }

    // The benchmarks' own tests: the generators' unit tests and the check
    // that beni accepts the cross-language benchmark's program. Benchmarks
    // are not part of the gates, so this step is not either.
    const bench_test_step = b.step("test-bench", "Run the benchmark generators' tests (not a gate)");
    bench_test_step.dependOn(&runTests(b, gen_tests).step);

    // ---- ReleaseFast and ReleaseSafe compilers. ----
    // Each has its own module instances, because a module's optimize mode is
    // fixed at creation, and each is installed apart from the `-Doptimize`
    // binary at `zig-out/bin/beni`.
    //
    // ReleaseFast, whatever `-Doptimize` says: a Debug throughput number is
    // not a number. The bench harness links its library, and the timing
    // scenarios of `test-perf` and `test-pending-perf` time its binary,
    // `zig-out/perf/bin/beni`.
    const fast = compiler(b, target, .ReleaseFast, .llvm, .default);
    const bench_beni = fast.beni;
    const perf_install = b.addInstallArtifact(fast.exe, .{ .dest_dir = .{ .override = .{ .custom = perf_bin_dir } } });
    // ReleaseSafe for every black-box suite that is not a timing claim,
    // `zig-out/safe/bin/beni`: bounds, overflow and `unreachable` still trap,
    // and every invariant check the compiler gates on
    // `std.debug.runtime_safety` still runs, at a fraction of Debug's cost.
    // Zig's self-hosted backend builds it, in seconds where LLVM takes more
    // than a minute on one thread; its code is slower, and it is not the
    // code users get. `-Dllvm` builds it with LLVM instead, into
    // `zig-out/safe-llvm/bin/beni`: the same safety checks in the shipped
    // code generator's output.
    const safe_dir = if (llvm) safe_llvm_bin_dir else safe_bin_dir;
    const safe = compiler(b, target, .ReleaseSafe, if (llvm) .llvm else .self_hosted, .default);
    const safe_install = b.addInstallArtifact(safe.exe, .{ .dest_dir = .{ .override = .{ .custom = safe_dir } } });

    // ---- Black-box suite. ----
    // Spawns the ReleaseSafe `zig-out/safe/bin/beni` (the timing steps below
    // spawn the ReleaseFast one), with cwd = repo root: the harness resolves
    // the binary and the corpus relative to it. The blackbox modules import
    // only `diagnostic`: reaching for an internal is a compile error, not a
    // code-review finding.
    //
    // Every test binary is its own process, and the build runner runs them
    // in parallel. A binary whose tests add up to more than a few seconds
    // runs as several processes, each running every n-th test
    // (`tests/test_runner.zig`); the counts are sized so that no process
    // runs much longer than the binary's slowest test. The corpus walker is
    // split into the parts of `tests/blackbox/corpus_parts.zig` instead.
    //
    // Each file is also a step of its own, `test-blackbox-<file>` (the file
    // name without `_test`, `_` spelled `-`), so a change can run the one
    // suite it touches.
    const blackbox_step = b.step("test-blackbox", "Run the black-box tests (spawns the ReleaseSafe compiler)");
    // The run-hash tool (`tests/run_hash_summary.zig`): it prints what the
    // processes did with their run hashes, merges a recording into the
    // index, and asks Node its version.
    const summary_exe = b.addExecutable(.{
        .name = "run-hash-summary",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/run_hash_summary.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // `node --version`, asked once per build and handed to every black-box
    // process (`--node-version=`), which feeds it to every run hash instead
    // of starting Node to learn it.
    const node_probe = b.addRunArtifact(summary_exe);
    node_probe.addArg("node-version");
    node_probe.has_side_effects = true;
    const bb: Blackbox = .{
        .node_version = node_probe.captureStdOut(.{}),
        .b = b,
        .target = target,
        .optimize = optimize,
        .diagnostic = diagnostic_mod,
        .filters = test_filters,
        .corpus_only = corpus_only,
        .safe_dir = safe_dir,
        .safe_install = &safe_install.step,
        .perf_install = &perf_install.step,
        .budget_ms = budget_env,
    };
    // A process that runs an emitted program skips Node when the run's
    // hash is recorded (`tests/blackbox/run_hash.zig`); every process of the
    // step writes its counts into a directory of this build's own, and
    // `run-hash-summary` prints them as one line once every process is
    // done — straight to the terminal, because a passing test that writes
    // to stderr reads as a failed command. The `test-blackbox-<file>` steps
    // run their own processes, which report nothing, except the corpus's,
    // which prints its own line.
    const counts_dir = b.getInstallPath(.prefix, b.fmt("run-hash-counts/{d}", .{std.posix.system.getpid()}));
    const gate_counts_dir = b.fmt("{s}-all", .{counts_dir});
    const gate_summary = runHashSummary(b, summary_exe, gate_counts_dir, &.{});
    blackbox_step.dependOn(&gate_summary.step);
    // The suites `test-run-hashes` records, with their process counts.
    const suites = blackbox_suites;
    var suite_tests: [suites.len]*std.Build.Step.Compile = undefined;
    for (suites, &suite_tests) |suite, *t| {
        // The walker's knobs are pinned on every binary, not only the
        // walker: `run.setEnvironmentVariable` is the one place a test's
        // environment is decided.
        t.* = bb.artifact(suite[0]);
        bb.runSharded(bb.fileStep(suite[0]), t.*, .{ .root = "tests/corpus" }, suite[1]);
        bb.runSharded(&gate_summary.step, t.*, .{ .root = "tests/corpus", .report_dir = gate_counts_dir }, suite[1]);
    }
    // The corpus's knobs (`plans/checker-rewrite.md` §2.4), pinned EMPTY —
    // which the walker reads as unset — so a variable exported in the
    // developer's shell (`BENI_CORPUS_MODE=pending zig build test-blackbox`)
    // cannot turn the gate into something else; only the part differs per
    // process. The one knob the build line sets is `BENI_CORPUS_ONLY`, from
    // `-Dcorpus`, which `gates` refuses.
    //
    // `run/` skips Node for a build whose output tree carries a recorded run
    // hash, and its parts report into the same directory.
    const corpus_test = bb.artifact("tests/blackbox/corpus_test.zig");
    const corpus_step = bb.fileStep("tests/blackbox/corpus_test.zig");
    const corpus_summary = runHashSummary(b, summary_exe, counts_dir, &.{});
    for (std.enums.values(corpus_parts.Part)) |part| {
        corpus_summary.step.dependOn(&bb.run(corpus_test, .{ .root = "tests/corpus", .part = @tagName(part), .report_dir = counts_dir }).step);
        gate_summary.step.dependOn(&bb.run(corpus_test, .{ .root = "tests/corpus", .part = @tagName(part), .report_dir = gate_counts_dir }).step);
    }
    corpus_step.dependOn(&corpus_summary.step);

    // Record the run hashes: every `run/` program and every program a
    // black-box scenario runs goes under Node. Each fixture's `.run-hash` is
    // rewritten with the builds that matched their golden (one process for
    // both builds of a fixture, so one worker writes each record), and
    // `tests/blackbox/run-hashes.txt` with the scenario runs that did what
    // their test expects. `-Dtest-filter` narrows the scenarios, and the
    // index keeps every other test's lines; `-Dcorpus` alone records only
    // the corpus. Takes `-Dllvm`; not a gate. The index is merged after the
    // last process, so a recording whose tests fail changes no line of it.
    const record_dir = b.fmt("{s}-record", .{counts_dir});
    const records_scenarios = test_filters.len != 0 or corpus_only.len == 0;
    const record_summary = runHashSummary(b, summary_exe, record_dir, if (!records_scenarios)
        &.{}
    else if (test_filters.len == 0)
        &.{ "--index=tests/blackbox/run-hashes.txt", "--whole" }
    else
        &.{"--index=tests/blackbox/run-hashes.txt"});
    record_summary.step.dependOn(&bb.run(corpus_test, .{ .root = "tests/corpus", .run_hashes = "record", .report_dir = record_dir, .budget = false }).step);
    if (records_scenarios) for (suites, suite_tests) |suite, t| {
        bb.runSharded(&record_summary.step, t, .{ .root = "tests/corpus", .run_hashes = "record", .report_dir = record_dir, .budget = false }, suite[1]);
    };
    b.step("test-run-hashes", "Run every emitted program the black-box suites run under Node, and record the hash of each that did what its test expects").dependOn(&record_summary.step);

    // The run hashes' own scenarios drive the corpus walker, a test binary
    // that runs one scenario program (`run_hash_probe.zig`, compiled without
    // `-Dtest-filter` so a filter never empties it) and the summary tool as
    // programs, on an index and a corpus of their own, so they need all
    // three installed. The test-time report's smoke test times the walker
    // too.
    const tools = std.Build.Step.InstallArtifact.Options{ .dest_dir = .{ .override = .{ .custom = "tools" } } };
    const corpus_tool_install = b.addInstallArtifact(corpus_test, tools);
    {
        const probe = b.addTest(.{
            .name = "run_hash_probe",
            .test_runner = testRunner(b),
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/blackbox/run_hash_probe.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "diagnostic", .module = diagnostic_mod }},
            }),
        });
        const file = "tests/blackbox/run_hash_test.zig";
        const step = bb.fileStep(file);
        const run = bb.run(bb.artifact(file), .{ .root = "tests/corpus" });
        run.setEnvironmentVariable("BENI_CORPUS_TEST_EXE", b.getInstallPath(.prefix, "tools/corpus_test"));
        run.setEnvironmentVariable("BENI_RUN_HASH_PROBE_EXE", b.getInstallPath(.prefix, "tools/run_hash_probe"));
        run.setEnvironmentVariable("BENI_RUN_HASH_SUMMARY_EXE", b.getInstallPath(.prefix, "tools/run-hash-summary"));
        run.step.dependOn(&corpus_tool_install.step);
        run.step.dependOn(&b.addInstallArtifact(probe, tools).step);
        run.step.dependOn(&b.addInstallArtifact(summary_exe, tools).step);
        step.dependOn(&run.step);
        blackbox_step.dependOn(step);
    }

    // ---- Pending fixtures (plans/checker-rewrite.md §2). ----
    // The red fixtures of `plans/checker-findings.md`, run by the corpus
    // walker in pending mode over `tests/pending/`, and the scenarios of
    // `pending_test.zig`. A fixture here is EXPECTED to be red: the step
    // fails only when one is malformed, green (promote it), or red for
    // another reason than `tests/pending/RED` records. Never part of
    // `test-blackbox`, so the three gates never run a red fixture.
    //
    // Two steps. `test-pending` runs the pending corpus and the scenarios
    // that measure no time (`BENI_PENDING_SCENARIOS=fast`), in parallel, on
    // the ReleaseSafe binary. `test-pending-perf` runs the timing scenarios
    // (`=perf`) on the ReleaseFast binary, because the budgets they guard
    // are ReleaseFast budgets.
    const pending_step = b.step("test-pending", "Run tests/pending/ (red fixtures of checker findings) in pending mode, and the non-timing scenarios");
    pending_step.dependOn(&bb.run(corpus_test, .{ .root = "tests/pending", .mode = "pending", .budget = false }).step);
    const pending_test = bb.artifact("tests/blackbox/pending_test.zig");
    pending_step.dependOn(&bb.run(pending_test, .{ .root = "tests/pending", .mode = "pending", .scenarios = "fast", .budget = false }).step);

    const perf_step = b.step("test-pending-perf", "Time the pending performance scenarios on a ReleaseFast compiler");
    perf_step.dependOn(&bb.run(pending_test, .{ .root = "tests/pending", .mode = "pending", .scenarios = "perf", .exe = .fast, .budget = false }).step);

    // The timing scenarios that are FIXED (`tests/blackbox/perf_test.zig`),
    // on the same ReleaseFast compiler by the same ratio method. Not a gate:
    // rule 4 names three. The scenarios judged on a ratio of CPU times run in
    // `perf_shards` processes at once; the few judged on the wall time of a
    // `--self-profile` event, or on a small difference of CPU times, run in
    // one process after them, alone (`perf_test.zig`'s `Run`). The
    // harness is built ReleaseSafe: it generates the large inputs and parses
    // the large traces, and in Debug that was half the step.
    const fixed_perf_step = b.step("test-perf", "Time the fixed performance scenarios on a ReleaseFast compiler");
    const perf_test = bb.artifactAt("tests/blackbox/perf_test.zig", .ReleaseSafe);
    const wall_perf = bb.run(perf_test, .{ .root = "tests/corpus", .exe = .fast, .perf_shard = "wall", .budget = false });
    for (0..perf_shards) |k| {
        const shard = bb.run(perf_test, .{ .root = "tests/corpus", .exe = .fast, .perf_shard = b.fmt("cpu:{d}/{d}", .{ k, perf_shards }), .budget = false });
        wall_perf.step.dependOn(&shard.step);
    }
    fixed_perf_step.dependOn(&wall_perf.step);

    // ---- Bench. ----
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "beni", .module = bench_beni }},
        }),
    });
    const bench_run = b.addRunArtifact(bench_exe);
    bench_run.setCwd(b.path("."));
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench", "Measure per-phase throughput over bench/corpus (ReleaseFast)");
    bench_step.dependOn(&bench_run.step);

    // ---- Cross-language benchmark (docs/design/compare-bench.md §3, §12). ----
    // The generator is its own target: it imports nothing from `src/`. It
    // runs ReleaseFast (it generates and prints ~1 M nodes per round); its
    // unit tests run in `test-bench` at the build's mode, like `bench/gen.zig`'s.
    // The beni it times is the ReleaseFast one of `test-pending-perf`.
    const compare_options = b.addOptions();
    compare_options.addOption([]const u8, "generator_hash", compareGeneratorHash(b));
    compare_options.addOption([]const u8, "beni_exe", b.getInstallPath(.prefix, perf_bin_dir ++ "/beni"));
    compare_options.addOption([]const u8, "repo_root", b.pathFromRoot("."));
    const compare_exe = b.addExecutable(.{
        .name = "compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/compare/gen/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "compare_options", .module = compare_options.createModule() }},
        }),
    });
    // Sharded like the unit tests: one of its tests takes most of a second
    // and the rest add up to as much again.
    const compare_tests = b.addTest(.{
        .name = "compare_gen_unit_test",
        .filters = test_filters,
        .test_runner = testRunner(b),
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/compare/gen/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "compare_options", .module = compare_options.createModule() }},
        }),
    });
    for (0..compare_shards) |k| {
        const run = runTests(b, compare_tests);
        run.setEnvironmentVariable("BENI_TEST_SHARD", b.fmt("{d}/{d}", .{ k, compare_shards }));
        run.setName(b.fmt("run compare generator tests shard {d}/{d}", .{ k, compare_shards }));
        bench_test_step.dependOn(&run.step);
    }
    inline for (.{
        .{ "compare-gen", "gen", "Generate the cross-language benchmark's projects (docs/design/compare-bench.md §12)" },
        .{ "compare", "run", "Run the cross-language type-checking benchmark; needs `nix develop .#compare` (compare-bench.md §12)" },
        .{ "compare-smoke", "smoke", "Size 1, both modes: every compiler accepts the generated projects (compare-bench.md §12)" },
        .{ "compare-render", "render", "Rewrite the benchmark README tables from a results file: -- --from=bench/compare/results/<name>.json (compare-bench.md §12)" },
    }) |s| {
        const run = b.addRunArtifact(compare_exe);
        run.addArg(s[1]);
        run.setCwd(b.path("."));
        if (b.args) |args| run.addArgs(args);
        // Timing and acceptance are facts about the machine now, never cached.
        run.has_side_effects = true;
        if (!std.mem.eql(u8, s[1], "gen") and !std.mem.eql(u8, s[1], "render")) run.step.dependOn(&perf_install.step);
        b.step(s[0], s[2]).dependOn(&run.step);
    }
    // The beni printer (compare-bench.md §15), in `test-bench`: the generated
    // project at seed 1, size 1, both modes, must check.
    const compare_lib = b.createModule(.{ .root_source_file = b.path("bench/compare/gen/lib.zig"), .target = target, .optimize = optimize });
    const compare_bb = b.addTest(.{
        .name = "compare_gen_test",
        .filters = test_filters,
        .test_runner = testRunner(b),
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/blackbox/compare_gen_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "diagnostic", .module = diagnostic_mod },
                .{ .name = "compare_gen", .module = compare_lib },
            },
        }),
    });
    const compare_bb_step = bb.fileStep("tests/blackbox/compare_gen_test.zig");
    compare_bb_step.dependOn(&bb.run(compare_bb, .{ .root = "tests/corpus", .budget = false }).step);
    bench_test_step.dependOn(compare_bb_step);

    // ---- Where the test time goes. ----
    // `time-report` runs a step of this build again, in a child `zig build`,
    // with `BENI_TEST_TIMING` set, so every test process records itself
    // (`tests/timing.zig`), and renders the records into
    // `plans/test-time-report.md` between its markers. The options that pick
    // what runs are passed on to the child build; `-- <args>` reach the
    // report tool (`--out=`, `--top=`, `--records=`).
    const time_step_name = b.option([]const u8, "time-step", "The step `test-time-report` times (default: gates)") orelse "gates";
    const time_report_exe = b.addExecutable(.{
        .name = "time-report",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/time_report.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const child_build_args = childBuildArgs(b, optimize, llvm, test_filters, corpus_only);
    {
        const run = b.addRunArtifact(time_report_exe);
        run.addArg("run");
        if (b.args) |args| run.addArgs(args);
        run.addArgs(&.{ "--", b.graph.zig_exe, "build", time_step_name });
        run.addArgs(child_build_args);
        // `-Dtest-budget-ms=0` measures every test to completion, for a
        // report on a suite that does not meet the budget.
        if (b.user_input_options.contains("test-budget-ms")) run.addArg(b.fmt("-Dtest-budget-ms={s}", .{budget_env}));
        run.setCwd(b.path("."));
        run.has_side_effects = true;
        b.step("test-time-report", "Run `gates` (or -Dtime-step) with every test timed; write the tables into plans/test-time-report.md").dependOn(&run.step);
    }
    // The smoke test runs the report tool around the corpus walker on one
    // fixture, so it needs the tool and the walker installed.
    {
        const tool_install = b.addInstallArtifact(time_report_exe, .{ .dest_dir = .{ .override = .{ .custom = "tools" } } });
        const smoke = bb.artifact("tests/blackbox/time_report_test.zig");
        const smoke_step = bb.fileStep("tests/blackbox/time_report_test.zig");
        const run = bb.run(smoke, .{ .root = "tests/corpus" });
        run.setEnvironmentVariable("BENI_TIME_REPORT_EXE", b.getInstallPath(.prefix, "tools/time-report"));
        run.setEnvironmentVariable("BENI_CORPUS_TEST_EXE", b.getInstallPath(.prefix, "tools/corpus_test"));
        run.step.dependOn(&tool_install.step);
        run.step.dependOn(&corpus_tool_install.step);
        smoke_step.dependOn(&run.step);
        blackbox_step.dependOn(smoke_step);
    }

    // ---- Line coverage (`tests/coverage.zig`). ----
    // `coverage` runs `coverage-run` in a child `zig build` and merges what
    // it collected even when a test failed, as `test-time-report` does. The
    // child builds a compiler with full debug info and a wrapper
    // (`tests/coverage_wrapper.zig`) that runs it under kcov, and points
    // every black-box suite's `BENI_EXE` at the wrapper: the report counts
    // only the lines the black-box suites and the corpus reach through the
    // binary. Neither step is a gate.
    const kcov_path: ?[]const u8 = b.findProgram(&.{"kcov"}, &.{}) catch null;
    const coverage_step = b.step("coverage", "Run the black-box suites and the corpus with every beni under kcov and report which lines of src/ they execute, into zig-out/coverage/ (not a gate; needs `nix develop .#coverage`)");
    const coverage_run_step = b.step("coverage-run", "The black-box suites and the corpus with every beni process under kcov, without the report; `coverage` runs it (not a gate)");
    if (kcov_path) |kcov| {
        const src_dir = b.pathFromRoot("src");
        const raw_dir = b.getInstallPath(.prefix, coverage_raw_dir);
        // The compiler measured is the LLVM ReleaseSafe build with its debug
        // info kept. kcov reads line tables through elfutils, which finds
        // none in what Zig's self-hosted backend emits for this program, so
        // that build reports nothing. An LLVM Debug build reports more lines,
        // but marks the body of an `if` that did not run as run: the jump
        // that skips it carries the body's line. The optimised build's line
        // table leaves out lines that were folded or merged away, and runs
        // under kcov about fifteen times faster.
        const measured = compiler(b, target, .ReleaseSafe, .llvm, .full);
        const beni_install = b.addInstallArtifact(measured.exe, .{ .dest_dir = .{ .override = .{ .custom = coverage_bin_dir } } });
        const wrapper_options = b.addOptions();
        wrapper_options.addOption([]const u8, "kcov", kcov);
        wrapper_options.addOption([]const u8, "include_path", src_dir);
        wrapper_options.addOption([]const u8, "raw_dir", raw_dir);
        wrapper_options.addOption([]const u8, "beni", b.getInstallPath(.prefix, coverage_bin_dir ++ "/beni"));
        // Named `beni`, like what it stands in for: the harness names a
        // spawned tool by its file name.
        const wrapper = b.addExecutable(.{
            .name = "beni",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/coverage_wrapper.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "coverage_options", .module = wrapper_options.createModule() }},
            }),
        });
        const wrapper_install = b.addInstallArtifact(wrapper, .{ .dest_dir = .{ .override = .{ .custom = coverage_wrapper_dir } } });
        wrapper_install.step.dependOn(&beni_install.step);

        var cbb = bb;
        cbb.safe_dir = coverage_wrapper_dir;
        cbb.safe_install = &wrapper_install.step;
        // A compiler under kcov runs several times slower than without it,
        // and every time limit in the harness guards against a hang, not a
        // speed: under coverage each is twenty times as long.
        const timeout_scale = "20";

        // `-Dcorpus` measures the chosen fixtures alone; without it, every
        // black-box file runs too. The unit tests never run here: the
        // report counts what a test reaches through the binary, so a line
        // that only a unit test runs shows as uncovered.
        if (corpus_only.len == 0) {
            for (blackbox_suites) |suite| {
                cbb.runSharded(coverage_run_step, cbb.artifact(suite[0]), .{ .root = "tests/corpus", .timeout_scale = timeout_scale, .budget = false }, suite[1]);
            }
        }
        for (std.enums.values(corpus_parts.Part)) |part| {
            coverage_run_step.dependOn(&cbb.run(corpus_test, .{ .root = "tests/corpus", .part = @tagName(part), .timeout_scale = timeout_scale, .budget = false }).step);
        }

        const coverage_exe = b.addExecutable(.{
            .name = "coverage",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/coverage.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run = b.addRunArtifact(coverage_exe);
        run.addArgs(&.{
            b.fmt("--kcov={s}", .{kcov}),
            b.fmt("--src={s}", .{src_dir}),
            b.fmt("--raw={s}", .{raw_dir}),
            b.fmt("--out={s}", .{b.getInstallPath(.prefix, coverage_report_dir)}),
        });
        if (b.args) |args| run.addArgs(args);
        run.addArgs(&.{ "--", b.graph.zig_exe, "build", "coverage-run" });
        run.addArgs(child_build_args);
        run.setCwd(b.path("."));
        run.stdio = .inherit;
        run.has_side_effects = true;
        coverage_step.dependOn(&run.step);
    } else {
        const missing = b.addFail("kcov is not on PATH: run `zig build coverage` inside `nix develop .#coverage` (Linux only)");
        coverage_step.dependOn(&missing.step);
        coverage_run_step.dependOn(&missing.step);
    }

    // ---- Formatting. ----
    const fmt_step = b.step("fmt-check", "Check formatting with `zig fmt --check`");
    fmt_step.dependOn(&b.addFmt(.{
        .paths = &.{ "src", "build.zig", "tests", "bench" },
        // The compare benchmark's generated projects and fetched
        // dependencies (Roc's sources among them) are not ours to format.
        .exclude_paths = &.{"bench/compare/work"},
        .check = true,
    }).step);

    // ---- The three gates as one step. ----
    // One build graph instead of three chained invocations: the unit tests
    // and the formatting check run while the black-box suites do, and the
    // compilers they share are built once.
    //
    // A filter would make a green gate say nothing about the tests it left
    // out, so a filtered `gates` fails before it runs anything.
    const gates_step = b.step("gates", "Run test, test-blackbox and fmt-check concurrently");
    if (test_filters.len != 0 or corpus_only.len != 0) {
        gates_step.dependOn(&b.addFail("`gates` runs every test: drop -Dtest-filter and -Dcorpus, or give them to `test`, `test-blackbox` or a `test-blackbox-<file>` step").step);
        return;
    }
    gates_step.dependOn(test_step);
    gates_step.dependOn(blackbox_step);
    gates_step.dependOn(fmt_step);
}

/// `run-hash-summary <dir> <args>` in the repo root, printing to the
/// terminal.
fn runHashSummary(b: *std.Build, exe: *std.Build.Step.Compile, dir: []const u8, args: []const []const u8) *std.Build.Step.Run {
    const run = b.addRunArtifact(exe);
    run.addArg(dir);
    run.addArgs(args);
    run.setCwd(b.path("."));
    run.stdio = .inherit;
    run.has_side_effects = true;
    return run;
}

/// The options of this build that a child `zig build` needs to build and run
/// the same thing: `-Doptimize`, `-Dllvm`, `-Dtest-filter`, `-Dcorpus`.
fn childBuildArgs(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    llvm: bool,
    test_filters: []const []const u8,
    corpus_only: []const u8,
) []const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    if (optimize != .Debug) args.append(b.allocator, b.fmt("-Doptimize={t}", .{optimize})) catch @panic("OOM");
    if (llvm) args.append(b.allocator, "-Dllvm") catch @panic("OOM");
    for (test_filters) |filter| args.append(b.allocator, b.fmt("-Dtest-filter={s}", .{filter})) catch @panic("OOM");
    if (corpus_only.len != 0) args.append(b.allocator, b.fmt("-Dcorpus={s}", .{corpus_only})) catch @panic("OOM");
    return args.items;
}

/// A run of a test binary. Marked as having side effects, which is true of
/// every one of them (the black-box ones spawn the compiler and write
/// temporary projects) and which is what skips the build runner's cache
/// check: that check hashes the whole test executable, 114 MB for the unit
/// tests, before every run, and can never hit, because each invocation
/// passes the test binary a fresh `--seed`.
fn runTests(b: *std.Build, t: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = b.addRunArtifact(t);
    run.has_side_effects = true;
    return run;
}

/// `tests/test_runner.zig`: std's runner plus `BENI_TEST_SHARD`, which lets
/// one test binary run as several processes.
fn testRunner(b: *std.Build) std.Build.Step.Compile.TestRunner {
    return .{ .path = b.path("tests/test_runner.zig"), .mode = .server };
}

/// Which code generator compiles a `compiler`.
const Backend = enum {
    llvm,
    /// Zig's own backend: a compile of seconds instead of LLVM's minute, and
    /// slower code. Safety checks are decided by the optimize mode, not by
    /// the backend, so a ReleaseSafe build still carries every one.
    self_hosted,
};

/// The compiler at a fixed optimize mode, whatever `-Doptimize` says: its
/// library module (the bench harness links the ReleaseFast one) and its
/// executable. Every module is its own instance, because a module's optimize
/// mode is fixed at creation, and the build id covers the mode and the
/// backend.
fn compiler(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    mode: std.builtin.OptimizeMode,
    backend: Backend,
    debug_info: DebugInfo,
) Compiler {
    // The LLVM ReleaseSafe compiler (`-Dllvm`) is built without debug info:
    // it is the longest compile after a change under `src/`, and debug info
    // is about a quarter of that time. Its safety checks are unaffected; a
    // panic it hits prints no symbolised stack trace, so a crash is traced
    // by re-running the command with `zig-out/bin/beni` or without `-Dllvm`,
    // whose self-hosted build keeps its debug info because there it costs
    // little.
    const strip: ?bool = switch (debug_info) {
        .full => false,
        .default => if (mode == .ReleaseSafe and backend == .llvm) true else null,
    };
    const diagnostic = b.createModule(.{
        .root_source_file = b.path("src/diagnostic.zig"),
        .target = target,
        .optimize = mode,
        .strip = strip,
    });
    const beni = b.createModule(.{
        .root_source_file = b.path("src/beni.zig"),
        .target = target,
        .optimize = mode,
        .strip = strip,
        .imports = &.{.{ .name = "diagnostic", .module = diagnostic }},
    });
    beni.addImport("core_package", embedCore(b, core_dir));
    beni.addImport("platform_packages", embedPlatforms(b, platforms_dir));
    beni.addImport("build_options", buildIdOptions(b, target, mode, backend));
    const exe = b.addExecutable(.{
        .name = "beni",
        .use_llvm = backend == .llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = mode,
            .strip = strip,
            .imports = &.{
                .{ .name = "beni", .module = beni },
                .{ .name = "diagnostic", .module = diagnostic },
            },
        }),
    });
    return .{ .beni = beni, .diagnostic = diagnostic, .exe = exe };
}

/// What `compiler` builds.
const Compiler = struct {
    beni: *std.Build.Module,
    diagnostic: *std.Build.Module,
    exe: *std.Build.Step.Compile,
};

/// Whether a `compiler` keeps its debug info.
const DebugInfo = enum {
    /// Whatever suits the mode and backend (see `compiler`).
    default,
    /// Always, for a tool that maps machine code back to source lines.
    full,
};

/// The `build_options` module, carrying the 16-byte compiler build id of
/// `docs/design/fast-compiler.md` §8 — the cache key's term for "which
/// compiler produced this entry" (`src/build_id.zig` has what it is for).
///
/// `backend` is null for the `-Doptimize` build, which leaves the choice to
/// Zig's default for the mode.
fn buildIdOptions(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    backend: ?Backend,
) *std.Build.Module {
    const options = b.addOptions();
    options.addOption([16]u8, "build_id", compilerBuildId(b, target, optimize, backend));
    return options.createModule();
}

/// Bumped whenever the recipe below changes, so that two compilers which
/// hash the same inputs differently cannot collide on an id.
const build_id_recipe: []const u8 = "BENIBUILDID\x00v1";

/// `SipHash128(1, 3)` — the compiler's one hash function
/// (`src/resolve/iface_bytes.zig`) — over the recipe tag, the Zig version
/// string, the optimize mode, the target triple, the backend when it is the
/// self-hosted one, and every file under `src/`:
/// path then bytes, in sorted path order, each preceded by its length so that
/// two different splits of the same concatenation cannot agree.
///
/// Configure time, not run time: the whole tree is ~2 MB and hashing it costs
/// under a millisecond, and `build.zig` re-runs on every `zig build` — so the
/// id is fresh whenever the sources are, which is also exactly when the
/// compiler is relinked anyway.
///
/// `beni.version` is not a separate term; see `src/build_id.zig`'s header.
fn compilerBuildId(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    backend: ?Backend,
) [16]u8 {
    var hasher = std.hash.SipHash128(1, 3).init(&@as([16]u8, @splat(0)));
    feed(&hasher, build_id_recipe);
    feed(&hasher, @import("builtin").zig_version_string);
    feed(&hasher, @tagName(optimize));
    feed(&hasher, target.result.zigTriple(b.allocator) catch @panic("OOM"));
    // Only the self-hosted build adds a term, so every other id is what it
    // was before the term existed.
    if (backend == .self_hosted) feed(&hasher, "self_hosted");

    var paths: std.ArrayList([]const u8) = .empty;
    collectAll(b, "src", "", &paths);
    sortPaths(&paths);
    if (paths.items.len == 0) std.debug.panic("the compiler source tree at src/ is empty", .{});

    const io = b.graph.io;
    for (paths.items) |rel| {
        feed(&hasher, rel);
        const full = b.pathJoin(&.{ "src", rel });
        const bytes = b.build_root.handle.readFileAlloc(io, full, b.allocator, .unlimited) catch |err| {
            std.debug.panic("cannot read compiler source {s}: {t}", .{ full, err });
        };
        feed(&hasher, bytes);
        b.allocator.free(bytes);
    }

    var out: [16]u8 = undefined;
    hasher.final(&out);
    return out;
}

/// One length-prefixed field of the digest.
fn feed(hasher: *std.hash.SipHash128(1, 3), slice: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, slice.len, .little);
    hasher.update(&len);
    hasher.update(slice);
}

/// Every file under `<root>/<prefix>`, recursively, as paths relative to
/// `root`. Unlike `collectFiles` it does not sort files into two buckets:
/// every file under `src/` is compiler source, whatever its extension.
fn collectAll(b: *std.Build, root: []const u8, prefix: []const u8, out: *std.ArrayList([]const u8)) void {
    const io = b.graph.io;
    const full = if (prefix.len == 0) b.dupe(root) else b.pathJoin(&.{ root, prefix });
    var handle = b.build_root.handle.openDir(io, full, .{ .iterate = true }) catch |err| {
        std.debug.panic("cannot open compiler source directory {s}: {t}", .{ full, err });
    };
    defer handle.close(io);
    var it = handle.iterate();
    while (it.next(io) catch |err| std.debug.panic("cannot read {s}: {t}", .{ full, err })) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const rel = if (prefix.len == 0) b.dupe(entry.name) else b.fmt("{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .directory => collectAll(b, root, rel, out),
            .file => out.append(b.allocator, rel) catch @panic("OOM"),
            else => {},
        }
    }
}

/// A module whose root exports `fixtures`, one `{ name, source }` per
/// `.beni` file directly under `dir` (sorted by name), each embedded. The
/// files are copied next to a generated manifest so `@embedFile` resolves
/// them inside that module's root; the directory is enumerated at
/// configure time, so adding a fixture is dropping in a file.
fn embedCorpus(b: *std.Build, dir: []const u8) *std.Build.Module {
    const io = b.graph.io;
    var names: std.ArrayList([]const u8) = .empty;
    var handle = b.build_root.handle.openDir(io, dir, .{ .iterate = true }) catch |err| {
        std.debug.panic("cannot open corpus directory {s}: {t}", .{ dir, err });
    };
    defer handle.close(io);
    var it = handle.iterate();
    while (it.next(io) catch |err| std.debug.panic("cannot read corpus directory {s}: {t}", .{ dir, err })) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".beni")) continue;
        names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);

    const wf = b.addWriteFiles();
    var manifest: std.ArrayList(u8) = .empty;
    manifest.appendSlice(b.allocator, "pub const Fixture = struct { name: []const u8, source: [:0]const u8 };\npub const fixtures = [_]Fixture{\n") catch @panic("OOM");
    for (names.items) |name| {
        _ = wf.addCopyFile(b.path(b.pathJoin(&.{ dir, name })), name);
        manifest.appendSlice(b.allocator, b.fmt("    .{{ .name = \"{s}\", .source = @embedFile(\"{s}\") }},\n", .{ name, name })) catch @panic("OOM");
    }
    manifest.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    const root = wf.add("manifest.zig", manifest.items);
    return b.createModule(.{ .root_source_file = root });
}

/// The core package as a module exporting `dir`, `files` and `assets`: one
/// `{ rel, source }` per `.beni` under `core/` (recursively, sorted by path)
/// and one `{ path, bytes }` per other file — the sibling JavaScript of
/// `boundary.md` §4, which `beni build` copies next to the module that
/// imports it. Same mechanism as `embedCorpus` — the files are copied next to
/// a generated manifest so `@embedFile` resolves inside the generated module
/// — but the paths keep their subdirectories, because a `core/Dict/Int.beni`
/// would be the module `Dict.Int` and the path IS the name. Nothing under
/// `core/` is nested today; the mechanism outlives the modules that used it.
fn embedCore(b: *std.Build, dir: []const u8) *std.Build.Module {
    var paths: std.ArrayList([]const u8) = .empty;
    var assets: std.ArrayList([]const u8) = .empty;
    collectFiles(b, dir, "", &paths, &assets);
    sortPaths(&paths);
    sortPaths(&assets);
    if (paths.items.len == 0) std.debug.panic("the core package at {s} is empty", .{dir});

    const wf = b.addWriteFiles();
    var manifest: std.ArrayList(u8) = .empty;
    manifest.appendSlice(b.allocator,
        \\//! Generated by build.zig: the core package, embedded (checker.md §3,
        \\//! boundary.md §4).
        \\
        \\pub const File = struct {
        \\    /// Relative to `dir`, with `/` separators: `Dict/Int.beni`
        \\    /// would be one, were any core module nested.
        \\    rel: []const u8,
        \\    source: [:0]const u8,
        \\};
        \\
        \\/// A file `beni build` copies out verbatim, keyed by the path the
        \\/// `SourceStore` spells it with (`core/Basics.js`).
        \\pub const Asset = struct {
        \\    path: []const u8,
        \\    bytes: []const u8,
        \\};
        \\
    ) catch @panic("OOM");
    manifest.appendSlice(b.allocator, b.fmt("pub const dir = \"{s}\";\npub const files = [_]File{{\n", .{dir})) catch @panic("OOM");
    for (paths.items) |rel| {
        _ = wf.addCopyFile(b.path(b.pathJoin(&.{ dir, rel })), rel);
        manifest.appendSlice(b.allocator, b.fmt("    .{{ .rel = \"{s}\", .source = @embedFile(\"{s}\") }},\n", .{ rel, rel })) catch @panic("OOM");
    }
    manifest.appendSlice(b.allocator, "};\npub const assets = [_]Asset{\n") catch @panic("OOM");
    for (assets.items) |rel| {
        _ = wf.addCopyFile(b.path(b.pathJoin(&.{ dir, rel })), rel);
        manifest.appendSlice(b.allocator, b.fmt("    .{{ .path = \"{s}/{s}\", .bytes = @embedFile(\"{s}\") }},\n", .{ dir, rel, rel })) catch @panic("OOM");
    }
    manifest.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    return b.createModule(.{ .root_source_file = wf.add("core_package.zig", manifest.items) });
}

/// Every platform package under `dir`, embedded: its manifest bytes, its
/// `.beni` modules and its JavaScript. `--platform=<name>` matches the
/// subdirectory name, so adding a platform to the box is dropping in a
/// directory (boundary.md §5.1: supporting a runtime is a package, not a
/// compiler change).
fn embedPlatforms(b: *std.Build, dir: []const u8) *std.Build.Module {
    const io = b.graph.io;
    var names: std.ArrayList([]const u8) = .empty;
    var handle = b.build_root.handle.openDir(io, dir, .{ .iterate = true }) catch |err| {
        std.debug.panic("cannot open platforms directory {s}: {t}", .{ dir, err });
    };
    defer handle.close(io);
    var it = handle.iterate();
    while (it.next(io) catch |err| std.debug.panic("cannot read {s}: {t}", .{ dir, err })) |entry| {
        if (entry.kind != .directory or entry.name[0] == '.') continue;
        names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }
    sortPaths(&names);

    const wf = b.addWriteFiles();
    var manifest: std.ArrayList(u8) = .empty;
    manifest.appendSlice(b.allocator,
        \\//! Generated by build.zig: the platform packages that ship with the
        \\//! compiler (boundary.md §5.3, §8).
        \\
        \\pub const File = struct { rel: []const u8, source: [:0]const u8 };
        \\pub const Asset = struct { path: []const u8, bytes: []const u8 };
        \\pub const Platform = struct {
        \\    /// What `--platform=<name>` matches.
        \\    name: []const u8,
        \\    /// The package root as the `SourceStore` spells it.
        \\    root: []const u8,
        \\    /// The bytes of its `beni.json`.
        \\    manifest: []const u8,
        \\    files: []const File,
        \\    assets: []const Asset,
        \\};
        \\
    ) catch @panic("OOM");
    var bodies: std.ArrayList(u8) = .empty;
    var table: std.ArrayList(u8) = .empty;
    table.appendSlice(b.allocator, "pub const platforms = [_]Platform{\n") catch @panic("OOM");
    for (names.items) |name| {
        const root = b.fmt("{s}/{s}", .{ dir, name });
        var files: std.ArrayList([]const u8) = .empty;
        var assets: std.ArrayList([]const u8) = .empty;
        collectFiles(b, root, "", &files, &assets);
        sortPaths(&files);
        sortPaths(&assets);
        if (files.items.len == 0) std.debug.panic("the platform package at {s} has no modules", .{root});

        const manifest_rel = b.fmt("{s}/beni.json", .{name});
        _ = wf.addCopyFile(b.path(b.pathJoin(&.{ root, "beni.json" })), manifest_rel);
        bodies.appendSlice(b.allocator, b.fmt("const files_{s} = [_]File{{\n", .{name})) catch @panic("OOM");
        for (files.items) |rel| {
            const key = b.fmt("{s}/{s}", .{ name, rel });
            _ = wf.addCopyFile(b.path(b.pathJoin(&.{ root, rel })), key);
            bodies.appendSlice(b.allocator, b.fmt("    .{{ .rel = \"{s}\", .source = @embedFile(\"{s}\") }},\n", .{ rel, key })) catch @panic("OOM");
        }
        bodies.appendSlice(b.allocator, b.fmt("}};\nconst assets_{s} = [_]Asset{{\n", .{name})) catch @panic("OOM");
        for (assets.items) |rel| {
            if (std.mem.eql(u8, rel, "beni.json")) continue;
            const key = b.fmt("{s}/{s}", .{ name, rel });
            _ = wf.addCopyFile(b.path(b.pathJoin(&.{ root, rel })), key);
            bodies.appendSlice(b.allocator, b.fmt("    .{{ .path = \"{s}/{s}\", .bytes = @embedFile(\"{s}\") }},\n", .{ root, rel, key })) catch @panic("OOM");
        }
        bodies.appendSlice(b.allocator, "};\n") catch @panic("OOM");
        table.appendSlice(b.allocator, b.fmt(
            "    .{{ .name = \"{s}\", .root = \"{s}\", .manifest = @embedFile(\"{s}\"), .files = &files_{s}, .assets = &assets_{s} }},\n",
            .{ name, root, manifest_rel, name, name },
        )) catch @panic("OOM");
    }
    table.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    manifest.appendSlice(b.allocator, bodies.items) catch @panic("OOM");
    manifest.appendSlice(b.allocator, table.items) catch @panic("OOM");
    return b.createModule(.{ .root_source_file = wf.add("platform_packages.zig", manifest.items) });
}

fn sortPaths(list: *std.ArrayList([]const u8)) void {
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
}

/// Append every file under `<root>/<prefix>` to `sources` (the `.beni`
/// modules) or `assets` (everything else), as paths relative to `root`,
/// descending into subdirectories.
fn collectFiles(
    b: *std.Build,
    root: []const u8,
    prefix: []const u8,
    sources: *std.ArrayList([]const u8),
    assets: *std.ArrayList([]const u8),
) void {
    const io = b.graph.io;
    const full = if (prefix.len == 0) b.dupe(root) else b.pathJoin(&.{ root, prefix });
    var handle = b.build_root.handle.openDir(io, full, .{ .iterate = true }) catch |err| {
        std.debug.panic("cannot open package directory {s}: {t}", .{ full, err });
    };
    defer handle.close(io);
    var it = handle.iterate();
    while (it.next(io) catch |err| std.debug.panic("cannot read package directory {s}: {t}", .{ full, err })) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const rel = if (prefix.len == 0) b.dupe(entry.name) else b.fmt("{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .directory => collectFiles(b, root, rel, sources, assets),
            .file => if (std.mem.endsWith(u8, entry.name, ".beni"))
                sources.append(b.allocator, rel) catch @panic("OOM")
            else
                assets.append(b.allocator, rel) catch @panic("OOM"),
            else => {},
        }
    }
}

/// Every environment variable the black-box harness reads to decide what a
/// run MEANS: the corpus walker's knobs (`tests/blackbox/corpus_test.zig`'s
/// `Config`), its part (`corpus_parts.zig`), which pending scenarios run
/// (`pending_test.zig`), which timing scenarios run (`perf_test.zig`) and
/// which binary is under test (`world.zig`'s
/// `exePath`). An empty value is the harness's "unset": every field but the
/// root and the binary defaults to it.
const HarnessEnvironment = struct {
    root: []const u8,
    mode: []const u8 = "",
    timeout_ms: []const u8 = "",
    /// `world.zig`'s `BENI_TIMEOUT_SCALE`: what every child's time limit
    /// is multiplied by. Only `coverage` sets it.
    timeout_scale: []const u8 = "",
    part: []const u8 = "",
    scenarios: []const u8 = "",
    /// `perf_test.zig`'s `BENI_PERF_SHARD`: which of its scenarios this
    /// process runs.
    perf_shard: []const u8 = "",
    /// `tests/test_runner.zig`'s `BENI_TEST_SHARD` (`k/n`): which of the
    /// binary's tests this process runs.
    shard: []const u8 = "",
    /// The compiler under test: the ReleaseSafe one unless a timing step
    /// names the ReleaseFast one.
    exe: enum { safe, fast } = .safe,
    /// The corpus walker's `BENI_RUN_HASHES` (`record`) and
    /// `BENI_RUN_HASH_REPORT` (where its `run/` counts go).
    run_hashes: []const u8 = "",
    report_dir: []const u8 = "",
    /// Whether each test and corpus case is held to the CPU budget
    /// (`tests/test_runner.zig`): every run the gates make is.
    budget: bool = true,
};

/// The black-box test roots, compiled against the build's target and
/// optimize mode and run from the repo root.
const Blackbox = struct {
    b: *std.Build,
    /// What `node --version` printed, asked once per build; every process
    /// gets it as `--node-version=` (`tests/test_runner.zig`).
    node_version: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    diagnostic: *std.Build.Module,
    /// `-Dtest-filter`, given to every test binary.
    filters: []const []const u8,
    /// `-Dcorpus`, pinned as `BENI_CORPUS_ONLY` on every run.
    corpus_only: []const u8,
    /// Where the ReleaseSafe compiler is installed under the prefix:
    /// `safe_bin_dir`, or `safe_llvm_bin_dir` under `-Dllvm`.
    safe_dir: []const u8,
    /// Install `<safe_dir>/beni` and `perf_bin_dir/beni`.
    safe_install: *std.Build.Step,
    perf_install: *std.Build.Step,
    /// `-Dtest-budget-ms`, as `BENI_TEST_BUDGET_MS`.
    budget_ms: []const u8,

    /// `test-blackbox-<file>`: the step that runs one black-box test file.
    fn fileStep(bb: Blackbox, root: []const u8) *std.Build.Step {
        var name = bb.b.dupe(std.fs.path.stem(root));
        if (std.mem.endsWith(u8, name, "_test")) name = name[0 .. name.len - "_test".len];
        std.mem.replaceScalar(u8, name, '_', '-');
        return bb.b.step(
            bb.b.fmt("test-blackbox-{s}", .{name}),
            bb.b.fmt("Run the black-box tests of {s} only", .{root}),
        );
    }

    fn artifact(bb: Blackbox, root: []const u8) *std.Build.Step.Compile {
        return bb.artifactAt(root, bb.optimize);
    }

    /// `artifact` with the harness itself built at `mode`.
    fn artifactAt(bb: Blackbox, root: []const u8, mode: std.builtin.OptimizeMode) *std.Build.Step.Compile {
        return bb.b.addTest(.{
            // `blackbox_test`, not `test`: the step names in a build
            // summary say which suite a run is.
            .name = std.fs.path.stem(root),
            .test_runner = testRunner(bb.b),
            .filters = bb.filters,
            .root_module = bb.b.createModule(.{
                .root_source_file = bb.b.path(root),
                .target = bb.target,
                .optimize = mode,
                .imports = &.{.{ .name = "diagnostic", .module = bb.diagnostic }},
            }),
        });
    }

    /// One process of `t`, after the compiler it spawns is installed, cwd =
    /// repo root, with every variable of `env` set explicitly — whatever the
    /// developer's shell exports: the Run step otherwise hands the child the
    /// build's whole environment, and one stray `export
    /// BENI_CORPUS_MODE=pending` would silently change what a gate means.
    fn run(bb: Blackbox, t: *std.Build.Step.Compile, env: HarnessEnvironment) *std.Build.Step.Run {
        const r = runTests(bb.b, t);
        r.addPrefixedFileContentArg("--node-version=", bb.node_version);
        r.step.dependOn(switch (env.exe) {
            .safe => bb.safe_install,
            .fast => bb.perf_install,
        });
        r.setCwd(bb.b.path("."));
        r.setEnvironmentVariable("BENI_CORPUS_ROOT", env.root);
        r.setEnvironmentVariable("BENI_CORPUS_MODE", env.mode);
        r.setEnvironmentVariable("BENI_CASE_TIMEOUT_MS", env.timeout_ms);
        r.setEnvironmentVariable("BENI_TIMEOUT_SCALE", env.timeout_scale);
        r.setEnvironmentVariable("BENI_CORPUS_PART", env.part);
        r.setEnvironmentVariable("BENI_CORPUS_ONLY", bb.corpus_only);
        r.setEnvironmentVariable("BENI_PENDING_SCENARIOS", env.scenarios);
        r.setEnvironmentVariable("BENI_PERF_SHARD", env.perf_shard);
        r.setEnvironmentVariable("BENI_TEST_SHARD", env.shard);
        r.setEnvironmentVariable("BENI_RUN_HASHES", env.run_hashes);
        r.setEnvironmentVariable("BENI_RUN_HASH_REPORT", env.report_dir);
        r.setEnvironmentVariable("BENI_TEST_BUDGET_MS", if (env.budget) bb.budget_ms else "");
        const exe_dir = switch (env.exe) {
            .safe => bb.safe_dir,
            .fast => perf_bin_dir,
        };
        r.setEnvironmentVariable("BENI_EXE", bb.b.getInstallPath(.prefix, bb.b.fmt("{s}/beni", .{exe_dir})));
        r.setName(bb.b.fmt("run {s}{s}{s}{s}{s}{s}{s}", .{
            t.name,
            if (env.part.len != 0) " part " else "",
            env.part,
            if (env.perf_shard.len != 0) " perf " else "",
            env.perf_shard,
            if (env.shard.len != 0) " shard " else "",
            env.shard,
        }));
        return r;
    }

    /// `run` as `shards` processes, each running every `shards`-th test of
    /// `t`, all of them dependencies of `step`.
    fn runSharded(bb: Blackbox, step: *std.Build.Step, t: *std.Build.Step.Compile, env: HarnessEnvironment, shards: u32) void {
        if (shards == 1) return step.dependOn(&bb.run(t, env).step);
        for (0..shards) |k| {
            var e = env;
            e.shard = bb.b.fmt("{d}/{d}", .{ k, shards });
            step.dependOn(&bb.run(t, e).step);
        }
    }
};

/// SHA-256 over every file under `bench/compare/gen/` (sources and
/// templates), path then bytes in sorted path order, length-prefixed like
/// `compilerBuildId`: the generator hash every results file records
/// (docs/design/compare-bench.md §3.2).
fn compareGeneratorHash(b: *std.Build) []const u8 {
    const root = "bench/compare/gen";
    var paths: std.ArrayList([]const u8) = .empty;
    collectAll(b, root, "", &paths);
    sortPaths(&paths);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const io = b.graph.io;
    for (paths.items) |rel| {
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, &len, rel.len, .little);
        hasher.update(&len);
        hasher.update(rel);
        const full = b.pathJoin(&.{ root, rel });
        const bytes = b.build_root.handle.readFileAlloc(io, full, b.allocator, .unlimited) catch |err| {
            std.debug.panic("cannot read generator source {s}: {t}", .{ full, err });
        };
        std.mem.writeInt(u64, &len, bytes.len, .little);
        hasher.update(&len);
        hasher.update(bytes);
        b.allocator.free(bytes);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return b.fmt("sha256:{x}", .{digest});
}
