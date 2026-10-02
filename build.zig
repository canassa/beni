//! Build graph for beni (docs/design/frontend.md §2).
//!
//! Steps, all of which must stay green at the end of every milestone:
//!   zig build                 install `beni`
//!   zig build test            hermetic unit tests (no processes, no files)
//!   zig build test-blackbox   spawns a ReleaseSafe `beni`; never folded into `test`
//!   zig build bench           ReleaseFast throughput harness over bench/corpus
//!   zig build fmt-check       `zig fmt --check` over every Zig source tree
//!   zig build beni-fmt-check  `beni fmt --check` over the .beni files, minus tests/fmt-exempt.txt
//!   zig build gates           the gates above, in one build graph
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
//! budget (`tests/test_runner.zig`): one that retires more than 4 300
//! million user-space instructions, its own and its children's, fails. For
//! profiling only:
//!   -Dtest-budget=<millions> another budget; 0 enforces none
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
//! And which lines the tests execute, not a gate either; x86-64 Linux only:
//!   zig build coverage            run the black-box suites and the corpus
//!                                 on an instrumented LLVM beni and write
//!                                 the report into zig-out/coverage/
//!                                 (`tests/coverage.zig`); takes -Dcorpus
//!                                 and -Dtest-filter
//! And random exploration, not a gate either (`src/fuzzing.zig`):
//!   zig build fuzz                the unit tests with their mutation sweeps
//!                                 and stress loops on (`BENI_FUZZ=1`)
//! And the benchmarks' own tests — benchmarks are not part of the gates:
//!   zig build test-bench          the generators' unit tests, the check that
//!                                 beni accepts the benchmark's program, and
//!                                 bench/size.mjs and bench/runtime.mjs on one
//!                                 tiny program each
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

/// The external platform the toy compiler carries, and where that compiler
/// is installed under the prefix.
const toy_platform_dir = "tests/platforms/toy";
const toy_bin_dir = "toy/bin";

/// Where the compiler with a variant core is installed under the prefix,
/// and the module that is its whole difference (`variant_core`).
const variant_bin_dir = "variant/bin";
const variant_core: Core = .{ .dir = core_dir, .extra = .{
    .rel = "BuildVariant.beni",
    .text =
    \\--! Embedded only by the compiler `build.zig` installs at
    \\--! `zig-out/variant/bin/beni`, which differs from the shipped one in this
    \\--! module alone (`tests/blackbox/build_id_test.zig`).
    \\
    \\
    \\--| What a program built by that compiler can read, and no other can.
    \\pub marker : String
    \\marker =
    \\    "variant"
    \\
    ,
} };

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
    .{ "tests/blackbox/abuse_wide_test.zig", 3 },
    .{ "tests/blackbox/build_test.zig", 3 },
    .{ "tests/blackbox/cache_test.zig", 4 },
    .{ "tests/blackbox/check_test.zig", 1 },
    .{ "tests/blackbox/cutoff_test.zig", 3 },
    .{ "tests/blackbox/devloop_test.zig", 1 },
    .{ "tests/blackbox/digest_test.zig", 3 },
    .{ "tests/blackbox/docs_test.zig", 1 },
    .{ "tests/blackbox/frontend_test.zig", 1 },
    .{ "tests/blackbox/iface_test.zig", 1 },
    .{ "tests/blackbox/ordering_test.zig", 2 },
    .{ "tests/blackbox/platform_test.zig", 1 },
    .{ "tests/blackbox/oracle_test.zig", 2 },
};

/// Where `coverage-run` installs the instrumented compiler the suites
/// spawn, under the prefix.
const coverage_bin_dir = "coverage-work/bin";

/// The file every instrumented compiler process records the blocks it ran
/// in, under the prefix (`tests/coverage/runtime.zig`). `tests/coverage.zig`
/// deletes it before a run and keeps it after, so `zig build coverage --
/// --report-only` can report it again.
const coverage_hits_path = "coverage-work/hits";

/// Where the report goes, under the prefix.
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
    // The budget of one test or corpus case (`tests/test_runner.zig`), on
    // every run of a binary the gates run; the random sweeps of `fuzz`, the
    // pending and timing steps, the run-hash recording and coverage are not
    // held to it. Another value is for profiling a test locally.
    const test_budget = b.option(u64, "test-budget", b.fmt("Fail a test or corpus case that retires more than this many million user-space instructions, its own and its children's (default {d}; 0 enforces none; for local profiling)", .{default_test_budget})) orelse default_test_budget;
    const budget_env = testBudget(b, test_budget);

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
    beni_mod.addImport("core_package", embedCore(b, shipped_core));
    // The platform packages (boundary.md §8, B2), embedded the same way:
    // the ones under `platforms/`, and any `-Dplatform=<dir>` adds
    // (`docs/design/boundary.md` §9.5), with their markup lowerings.
    const platform_dirs = b.option([]const []const u8, "platform", "Compile the platform package in this directory into beni, its Zig markup lowerings included, as if it shipped with it (repeatable; docs/design/boundary.md §9.5)") orelse &.{};
    const platform_sources = platformSources(b, platform_dirs);
    beni_mod.addImport("platform_packages", embedPlatforms(b, platform_sources));
    const markup = markupModules(b, platform_sources, null);
    beni_mod.addImport("beni_markup", markup.interface);
    beni_mod.addImport("markup_lowerings", markup.registry);
    // HTML's character references, which markup text decodes (frontend.md §9.7).
    beni_mod.addImport("markup_entity_table", entityTable(b));
    // The compiler build id (`fast-compiler.md` §8): the cache key's term for
    // "which compiler produced this entry". Computed here rather than by
    // hashing the installed binary at run time, which is correct and costs
    // ~2 ms of a 15 ms warm budget.
    const default_id = compilerBuildId(b, target, optimize, null, shipped_core, platform_sources);
    beni_mod.addImport("build_options", buildIdOptions(b, default_id));
    // The hermetic suite's library carries no checked core: its tests build
    // their own projects, and the pack is the installed compilers' (below).
    beni_mod.addImport("core_pack", emptyCorePack(b));

    // The installed compiler carries the checked core (`fast-compiler.md`
    // §8, *The checked core, embedded*), so it is built from a library
    // module of its own: the same sources and imports as `beni_mod`, and the
    // pack made for its build id.
    const exe_beni = b.createModule(.{
        .root_source_file = b.path("src/beni.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "diagnostic", .module = diagnostic_mod }},
    });
    exe_beni.addImport("core_package", embedCore(b, shipped_core));
    exe_beni.addImport("platform_packages", embedPlatforms(b, platform_sources));
    exe_beni.addImport("beni_markup", markup.interface);
    exe_beni.addImport("markup_lowerings", markup.registry);
    exe_beni.addImport("markup_entity_table", entityTable(b));
    exe_beni.addImport("build_options", buildIdOptions(b, default_id));
    exe_beni.addImport("core_pack", corePack(b, shipped_core, default_id));

    const exe = b.addExecutable(.{
        .name = "beni",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "beni", .module = exe_beni },
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
        setBudget(run, budget_env);
        run.setName(b.fmt("run beni tests shard {d}/{d}", .{ k, unit_shards }));
        test_step.dependOn(&run.step);
    }
    {
        const run = runTests(b, diagnostic_tests);
        setBudget(run, budget_env);
        test_step.dependOn(&run.step);
    }
    test_step.dependOn(&runTests(b, time_report_tests).step);
    // The markup interface's own tests and the platforms' Zig — the `ssr`
    // lowering, `html`'s parser table — each module its own binary, since a
    // platform's Zig is a module of its own and not the compiler's.
    {
        const tested = markupModules(b, platform_sources, .{ .target = target, .optimize = optimize });
        for (tested.all) |module| {
            const t = b.addTest(.{ .name = "markup_unit_test", .root_module = module, .test_runner = testRunner(b), .filters = test_filters });
            const run = runTests(b, t);
            setBudget(run, budget_env);
            test_step.dependOn(&run.step);
        }
    }
    // The coverage report's own logic (`tests/coverage.zig`): its decoder,
    // control-flow rules and output, on hand-built inputs.
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
        setBudget(run, budget_env);
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
    const bench_test_step = b.step("test-bench", "Run the benchmarks' own tests: the generators and the size and runtime instruments (not a gate)");
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
    const fast = compiler(b, target, .ReleaseFast, .llvm, .default, shipped_core, platform_sources);
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
    const safe = compiler(b, target, .ReleaseSafe, if (llvm) .llvm else .self_hosted, .default, shipped_core, platform_sources);
    const safe_install = b.addInstallArtifact(safe.exe, .{ .dest_dir = .{ .override = .{ .custom = safe_dir } } });
    // The same compiler with `tests/platforms/toy` compiled in, exactly as
    // `-Dplatform=tests/platforms/toy` would compile it
    // (`docs/design/boundary.md` §9.5), at `zig-out/toy/bin/beni`: the
    // external path, which one black-box scenario builds a program through.
    const toy = compiler(b, target, .ReleaseSafe, .self_hosted, .default, shipped_core, platformSources(b, &.{toy_platform_dir}));
    const toy_install = b.addInstallArtifact(toy.exe, .{ .dest_dir = .{ .override = .{ .custom = toy_bin_dir } } });
    // The same compiler with one more core module embedded, at
    // `zig-out/variant/bin/beni`: a binary that differs from the safe one in
    // its embedded core and in nothing else, which `build_id_test.zig` runs
    // beside it against one cache directory.
    const variant = compiler(b, target, .ReleaseSafe, .self_hosted, .default, variant_core, platform_sources);
    const variant_install = b.addInstallArtifact(variant.exe, .{ .dest_dir = .{ .override = .{ .custom = variant_bin_dir } } });

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
        .toy_install = &toy_install.step,
        .variant_install = &variant_install.step,
        .budget = budget_env,
        .chrome = b.option([]const u8, "chrome", "The Chrome or Chromium `test-browser` runs pages in (default: the first of chromium, google-chrome-stable and google-chrome on PATH)") orelse "",
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
    // The external platform's scenario, against the toy compiler.
    const external_file = "tests/blackbox/external_platform_test.zig";
    const external_test = bb.artifact(external_file);
    bb.runSharded(bb.fileStep(external_file), external_test, .{ .root = "tests/corpus", .exe = .toy }, 1);
    bb.runSharded(&gate_summary.step, external_test, .{ .root = "tests/corpus", .exe = .toy, .report_dir = gate_counts_dir }, 1);
    // Two compilers that differ in their embedded core alone, against one
    // cache directory.
    const build_id_file = "tests/blackbox/build_id_test.zig";
    const build_id_test = bb.artifact(build_id_file);
    bb.runSharded(bb.fileStep(build_id_file), build_id_test, .{ .root = "tests/corpus", .variant = true }, 1);
    bb.runSharded(&gate_summary.step, build_id_test, .{ .root = "tests/corpus", .variant = true, .report_dir = gate_counts_dir }, 1);

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
    if (records_scenarios) bb.runSharded(&record_summary.step, external_test, .{ .root = "tests/corpus", .exe = .toy, .run_hashes = "record", .report_dir = record_dir, .budget = false }, 1);
    if (records_scenarios) bb.runSharded(&record_summary.step, build_id_test, .{ .root = "tests/corpus", .variant = true, .run_hashes = "record", .report_dir = record_dir, .budget = false }, 1);
    b.step("test-run-hashes", "Run every emitted program the black-box suites run under Node, and record the hash of each that did what its test expects").dependOn(&record_summary.step);

    // The `browser/` corpus in a real browser: every fixture's pages run in
    // one headless Chrome instead of happy-dom, against the same goldens
    // (`tests/blackbox/browser.zig`), so a difference between the two DOMs
    // that a fixture reaches fails here. Chrome comes from `-Dchrome` or
    // `PATH` (`nix develop .#browser`); with none the step fails and says
    // so. Takes `-Dcorpus`; not a gate, and no budget: the browser is one
    // process shared by every case.
    const browser_step = b.step("test-browser", "Run the browser/ corpus in a headless Chrome instead of happy-dom");
    browser_step.dependOn(&bb.run(corpus_test, .{ .root = "tests/corpus", .part = "browser", .browser = "chrome", .budget = false }).step);

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
    // The browser kind's scenarios drive the corpus walker too, on corpora
    // of their own; each loads a page or two, so they run as three
    // processes.
    {
        const file = "tests/blackbox/browser_test.zig";
        const step = bb.fileStep(file);
        const t = bb.artifact(file);
        const shards = 3;
        for (0..shards) |k| {
            const run = bb.run(t, .{ .root = "tests/corpus", .shard = b.fmt("{d}/{d}", .{ k, shards }) });
            run.setEnvironmentVariable("BENI_CORPUS_TEST_EXE", b.getInstallPath(.prefix, "tools/corpus_test"));
            run.step.dependOn(&corpus_tool_install.step);
            step.dependOn(&run.step);
        }
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
    // rule 4 names three. The scenarios judged on a ratio of retired
    // instructions (CPU time where none can be counted) run in
    // `perf_shards` processes at once; the few judged on the wall time of a
    // `--self-profile` event, or on a small difference of two costs, run in
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
    // The measurement instruments (`bench/size.mjs`, `bench/runtime.mjs`),
    // each run on one tiny program so its output cannot rot unnoticed.
    const bench_scripts_step = bb.fileStep("tests/blackbox/bench_test.zig");
    bench_scripts_step.dependOn(&bb.run(bb.artifact("tests/blackbox/bench_test.zig"), .{ .root = "tests/corpus", .budget = false }).step);
    bench_test_step.dependOn(bench_scripts_step);

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
        // `-Dtest-budget=0` measures every test to completion, for a report
        // on a suite that does not meet the budget.
        if (b.user_input_options.contains("test-budget")) run.addArg(b.fmt("-Dtest-budget={d}", .{test_budget}));
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
    // `coverage` runs `coverage-run` in a child `zig build` and reports what
    // it collected even when a test failed, as `test-time-report` does. The
    // child builds a compiler whose every instrumented basic block records,
    // the first time it runs, one byte in a hits file all its processes
    // share (`tests/coverage/runtime.zig`), and points every black-box
    // suite's `BENI_EXE` at it: the report counts only the lines the
    // black-box suites and the corpus reach through the binary. Neither
    // step is a gate.
    const coverage_step = b.step("coverage", "Run the black-box suites and the corpus on an instrumented beni and report which lines of src/ they execute, into zig-out/coverage/ (not a gate; x86-64 Linux)");
    const coverage_run_step = b.step("coverage-run", "The black-box suites and the corpus on the instrumented beni, without the report; `coverage` runs it (not a gate)");
    if (target.result.cpu.arch == .x86_64 and target.result.os.tag == .linux) {
        const hits_path = b.getInstallPath(.prefix, coverage_hits_path);
        const exe_path = b.getInstallPath(.prefix, coverage_bin_dir ++ "/beni");
        // The compiler measured is the LLVM ReleaseSafe build with its debug
        // info kept, instrumented by LLVM's SanitizerCoverage: Zig's
        // self-hosted backend has no such instrumentation. Only the blocks
        // LLVM chose to guard record anything; the report infers the rest
        // from the control-flow graph, and maps blocks to lines through the
        // line table, which leaves out lines the optimiser folded away.
        const measured = compiler(b, target, .ReleaseSafe, .llvm, .full, shipped_core, platform_sources);
        const runtime_options = b.addOptions();
        runtime_options.addOption([:0]const u8, "hits_path", b.allocator.dupeZ(u8, hits_path) catch @panic("OOM"));
        const instrumented = b.addExecutable(.{
            .name = "beni",
            .use_llvm = true,
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/coverage/runtime.zig"),
                .target = target,
                .optimize = .ReleaseSafe,
                .strip = false,
                .imports = &.{
                    .{ .name = "beni_main", .module = b.createModule(.{
                        .root_source_file = b.path("src/main.zig"),
                        .target = target,
                        .optimize = .ReleaseSafe,
                        .strip = false,
                        .imports = &.{
                            .{ .name = "beni", .module = measured.beni },
                            .{ .name = "diagnostic", .module = measured.diagnostic },
                        },
                    }) },
                    .{ .name = "coverage_options", .module = runtime_options.createModule() },
                },
            }),
        });
        instrumented.sanitize_coverage_trace_pc_guard = true;
        // The report reads jump tables as absolute addresses.
        instrumented.pie = false;
        instrumented.root_module.addCSourceFile(.{ .file = b.path("tests/coverage/lowest_stack.c") });
        const instrumented_install = b.addInstallArtifact(instrumented, .{ .dest_dir = .{ .override = .{ .custom = coverage_bin_dir } } });

        var cbb = bb;
        cbb.safe_dir = coverage_bin_dir;
        cbb.safe_install = &instrumented_install.step;
        // `-Dcorpus` measures the chosen fixtures alone; without it, every
        // black-box file runs too. The unit tests never run here: the
        // report counts what a test reaches through the binary, so a line
        // that only a unit test runs shows as uncovered.
        if (corpus_only.len == 0) {
            for (blackbox_suites) |suite| {
                cbb.runSharded(coverage_run_step, cbb.artifact(suite[0]), .{ .root = "tests/corpus", .budget = false }, suite[1]);
            }
        }
        for (std.enums.values(corpus_parts.Part)) |part| {
            coverage_run_step.dependOn(&cbb.run(corpus_test, .{ .root = "tests/corpus", .part = @tagName(part), .budget = false }).step);
        }

        const coverage_exe = b.addExecutable(.{
            .name = "coverage",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/coverage.zig"),
                .target = target,
                .optimize = .ReleaseSafe,
            }),
        });
        const run = b.addRunArtifact(coverage_exe);
        run.addArgs(&.{
            b.fmt("--exe={s}", .{exe_path}),
            b.fmt("--hits={s}", .{hits_path}),
            b.fmt("--src={s}", .{b.pathFromRoot("src")}),
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
        const unsupported = b.addFail("zig build coverage reads x86-64 machine code: it runs on x86-64 Linux only");
        coverage_step.dependOn(&unsupported.step);
        coverage_run_step.dependOn(&unsupported.step);
    }

    // ---- Formatting. ----
    const fmt_step = b.step("fmt-check", "Check formatting with `zig fmt --check`");
    fmt_step.dependOn(&b.addFmt(.{
        .paths = &.{ "src", "build.zig", "tests", "bench", "platforms" },
        // The compare benchmark's generated projects and fetched
        // dependencies (Roc's sources among them) are not ours to format.
        .exclude_paths = &.{"bench/compare/work"},
        .check = true,
    }).step);

    // `beni fmt --check` over the repository's `.beni` files, except what
    // `tests/fmt-exempt.txt` names (`docs/design/frontend.md` §11.6), on
    // the gates' own ReleaseSafe beni; `tests/fmt_check.zig` is the tool,
    // and `fmt_check_test.zig` drives it on a world of its own.
    const beni_fmt_step = b.step("beni-fmt-check", "Check that every .beni file in the gate's scope is what `beni fmt` writes");
    const fmt_check_exe = b.addExecutable(.{
        .name = "beni-fmt-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fmt_check.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const beni_safe_path = b.getInstallPath(.prefix, b.fmt("{s}/beni", .{safe_dir}));
    {
        const run = b.addRunArtifact(fmt_check_exe);
        run.addArg(beni_safe_path);
        run.setCwd(b.path("."));
        run.has_side_effects = true;
        run.step.dependOn(&safe_install.step);
        beni_fmt_step.dependOn(&run.step);
    }
    {
        const file = "tests/blackbox/fmt_check_test.zig";
        const step = bb.fileStep(file);
        const run = bb.run(bb.artifact(file), .{ .root = "tests/corpus" });
        run.setEnvironmentVariable("BENI_FMT_CHECK_EXE", b.getInstallPath(.prefix, "tools/beni-fmt-check"));
        run.step.dependOn(&b.addInstallArtifact(fmt_check_exe, tools).step);
        step.dependOn(&run.step);
        blackbox_step.dependOn(step);
    }

    // ---- The three gates as one step. ----
    // One build graph instead of three chained invocations: the unit tests
    // and the formatting check run while the black-box suites do, and the
    // compilers they share are built once.
    //
    // A filter would make a green gate say nothing about the tests it left
    // out, so a filtered `gates` fails before it runs anything.
    const gates_step = b.step("gates", "Run test, test-blackbox, fmt-check and beni-fmt-check concurrently");
    if (test_filters.len != 0 or corpus_only.len != 0) {
        gates_step.dependOn(&b.addFail("`gates` runs every test: drop -Dtest-filter and -Dcorpus, or give them to `test`, `test-blackbox` or a `test-blackbox-<file>` step").step);
        return;
    }
    gates_step.dependOn(test_step);
    gates_step.dependOn(blackbox_step);
    gates_step.dependOn(fmt_step);
    gates_step.dependOn(beni_fmt_step);
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

/// The budget every test and corpus case is held to, in millions of
/// user-space instructions retired (`tests/test_runner.zig`): what one
/// second of CPU retires on this code. Measured on a quiet machine, every
/// unit and black-box test run one process at a time (`-j1`): 213 billion
/// instructions in 49.5 s of CPU, user plus system, 4.3 billion a second
/// (the median test 4.2).
const default_test_budget = 4_300;

/// The CPU time one million instructions of `default_test_budget` stands
/// for, in nanoseconds, when a budget falls back to CPU time: 1 s spread
/// over the default.
const fallback_ns_per_million = 1_000_000_000 / default_test_budget;

/// A test budget as the runner reads it: instructions, and the CPU time
/// they correspond to where no instruction counter can be opened. Empty is
/// none.
const TestBudget = struct {
    instructions: []const u8,
    cpu_ms: []const u8,

    const none: TestBudget = .{ .instructions = "", .cpu_ms = "" };
};

/// `-Dtest-budget=<millions>` as the runner's variables. Counting another
/// process's instructions from user space needs `perf_event_paranoid` of 2
/// or less; above it, or off Linux, the budget is CPU time, which a loaded
/// machine inflates, and the build says so once.
fn testBudget(b: *std.Build, millions: u64) TestBudget {
    if (millions == 0) return .none;
    const cpu_ms = b.fmt("{d}", .{millions * fallback_ns_per_million / 1_000_000});
    if (!perfCountersPermitted()) {
        std.debug.print("note: perf_event_paranoid does not permit counting instructions; each test's budget is {s} ms of CPU instead\n", .{cpu_ms});
        return .{ .instructions = "", .cpu_ms = cpu_ms };
    }
    return .{ .instructions = b.fmt("{d}", .{millions * 1_000_000}), .cpu_ms = cpu_ms };
}

fn perfCountersPermitted() bool {
    if (@import("builtin").os.tag != .linux) return false;
    const linux = std.os.linux;
    const rc = linux.open("/proc/sys/kernel/perf_event_paranoid", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buffer: [16]u8 = undefined;
    const n = linux.read(fd, &buffer, buffer.len);
    if (linux.errno(n) != .SUCCESS) return false;
    const level = std.fmt.parseInt(i32, std.mem.trim(u8, buffer[0..n], " \n"), 10) catch return false;
    return level <= 2;
}

fn setBudget(run: *std.Build.Step.Run, budget: TestBudget) void {
    run.setEnvironmentVariable("BENI_TEST_BUDGET_INSTRUCTIONS", budget.instructions);
    run.setEnvironmentVariable("BENI_TEST_BUDGET_CPU_MS", budget.cpu_ms);
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
    core: Core,
    sources: []const PlatformSource,
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
    beni.addImport("core_package", embedCore(b, core));
    beni.addImport("platform_packages", embedPlatforms(b, sources));
    const markup = markupModules(b, sources, null);
    beni.addImport("beni_markup", markup.interface);
    beni.addImport("markup_lowerings", markup.registry);
    beni.addImport("markup_entity_table", entityTable(b));
    const id = compilerBuildId(b, target, mode, backend, core, sources);
    beni.addImport("build_options", buildIdOptions(b, id));
    beni.addImport("core_pack", corePack(b, core, id));
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
fn buildIdOptions(b: *std.Build, id: [16]u8) *std.Build.Module {
    const options = b.addOptions();
    options.addOption([16]u8, "build_id", id);
    return options.createModule();
}

/// The checked core a compiler with build id `id` carries, as the module
/// `core_pack` (`docs/design/fast-compiler.md` §8, *The checked core,
/// embedded*; `src/cache/Pack.zig`): `src/core_pack_main.zig` run over
/// `core`'s files with that id, its output embedded.
///
/// **One maker for every compiler, run once per compiler.** The maker is
/// built once, ReleaseSafe on the self-hosted backend — every safety check
/// fires while it checks core — and the pack it writes depends on the core
/// and on the id, never on the maker's own mode: every key is computed with
/// `id`, and a check's result does not depend on the code generator that
/// compiled the checker (§10). Each run is a few hundred milliseconds; the
/// maker's compile is what an edit under `src/` adds to the path of every
/// compiler, which is why its root reaches the checker and nothing after it.
fn corePack(b: *std.Build, core: Core, id: [16]u8) *std.Build.Module {
    const run = b.addRunArtifact(corePackMaker(b));
    run.setName(b.fmt("check {s} for the compiler {s}", .{ core.dir, &std.fmt.bytesToHex(id, .lower) }));
    run.addDirectoryArg(coreDirectory(b, core));
    run.addArg(&std.fmt.bytesToHex(id, .lower));
    const pack = run.addOutputFileArg("core.pack");
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(pack, "core.pack");
    const root = wf.add("core_pack.zig",
        \\//! Generated by build.zig: the checked core (fast-compiler.md §8).
        \\pub const bytes: []const u8 = @embedFile("core.pack");
        \\
    );
    return b.createModule(.{ .root_source_file = root });
}

/// A `core_pack` that holds nothing: every core module is then checked by
/// every build, as before the pack existed. The maker's own, and the
/// hermetic suite's.
fn emptyCorePack(b: *std.Build) *std.Build.Module {
    const wf = b.addWriteFiles();
    const root = wf.add("core_pack.zig",
        \\//! Generated by build.zig: no checked core (fast-compiler.md §8).
        \\pub const bytes: []const u8 = "";
        \\
    );
    return b.createModule(.{ .root_source_file = root });
}

/// `src/core_pack_main.zig`, built once per `zig build` for the host.
fn corePackMaker(b: *std.Build) *std.Build.Step.Compile {
    if (core_pack_maker) |exe| return exe;
    const host = b.graph.host;
    const mode: std.builtin.OptimizeMode = .ReleaseSafe;
    const diagnostic = b.createModule(.{
        .root_source_file = b.path("src/diagnostic.zig"),
        .target = host,
        .optimize = mode,
    });
    const beni = b.createModule(.{
        .root_source_file = b.path("src/beni.zig"),
        .target = host,
        .optimize = mode,
        .imports = &.{.{ .name = "diagnostic", .module = diagnostic }},
    });
    beni.addImport("core_package", embedCore(b, shipped_core));
    beni.addImport("platform_packages", embedPlatforms(b, &.{}));
    const markup = markupModules(b, &.{}, null);
    beni.addImport("beni_markup", markup.interface);
    beni.addImport("markup_lowerings", markup.registry);
    beni.addImport("markup_entity_table", entityTable(b));
    // Its own id is never a key's term: every key it computes takes the id
    // of the compiler it makes the pack for.
    beni.addImport("build_options", buildIdOptions(b, compilerBuildId(b, host, mode, .self_hosted, shipped_core, &.{})));
    beni.addImport("core_pack", emptyCorePack(b));
    const exe = b.addExecutable(.{
        .name = "core_pack",
        .use_llvm = false,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core_pack_main.zig"),
            .target = host,
            .optimize = mode,
            .imports = &.{.{ .name = "beni", .module = beni }},
        }),
    });
    core_pack_maker = exe;
    return exe;
}

var core_pack_maker: ?*std.Build.Step.Compile = null;

/// `core`'s files in a directory of their own, for the maker's
/// `--core-root`: the files `embedCore` embeds, under the same names.
fn coreDirectory(b: *std.Build, core: Core) std.Build.LazyPath {
    const wf = b.addWriteFiles();
    for (coreFiles(b, core)) |file| switch (file.origin) {
        .disk => |full| _ = wf.addCopyFile(b.path(full), file.rel),
        .text => |text| _ = wf.add(file.rel, text),
    };
    return wf.getDirectory();
}

/// Bumped whenever the recipe below changes, so that two compilers which
/// hash the same inputs differently cannot collide on an id. **v2**: the
/// build script, the embedded core and every file of every platform the
/// binary carries joined `src/`, so the id is over everything the binary is
/// built from.
const build_id_recipe: []const u8 = "BENIBUILDID\x00v2";

/// `SipHash128(1, 3)` — the compiler's one hash function
/// (`src/resolve/iface_bytes.zig`) — over the recipe tag, the Zig version
/// string, the optimize mode, the target triple, the backend when it is the
/// self-hosted one, this file, every file under `src/`, every file of the
/// core package the binary embeds, and every file of every platform it
/// carries: each a name, then its bytes, in sorted path order, each field
/// preceded by its length so that two different splits of the same
/// concatenation cannot agree.
///
/// **Everything the binary is built from**, because the id is the cache's
/// one term for "this compiler", and a term that left out an input the
/// binary carries lets two compilers that behave differently serve each
/// other's entries. The per-module key terms hash each `.beni` and sibling
/// `.js` a check reads, which is finer, and they stay; but they cannot see
/// what this script does with the files, a platform's manifest, or a file
/// of a package no key term names. Folding all of it in here costs nothing
/// at run time.
///
/// Configure time, not run time: the trees are a few MB and hashing them
/// costs milliseconds, and `build.zig` re-runs on every `zig build` — so the
/// id is fresh whenever the sources are, which is also exactly when the
/// compiler is relinked anyway.
///
/// `beni.version` is not a separate term; see `src/build_id.zig`'s header.
fn compilerBuildId(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    backend: ?Backend,
    core: Core,
    sources: []const PlatformSource,
) [16]u8 {
    var hasher = std.hash.SipHash128(1, 3).init(&@as([16]u8, @splat(0)));
    feed(&hasher, build_id_recipe);
    feed(&hasher, @import("builtin").zig_version_string);
    feed(&hasher, @tagName(optimize));
    feed(&hasher, target.result.zigTriple(b.allocator) catch @panic("OOM"));
    // Only the self-hosted build adds a term, so every other id is what it
    // was before the term existed.
    if (backend == .self_hosted) feed(&hasher, "self_hosted");

    // The build script: what it does with the files below — which it
    // embeds, under which names — is as much the compiler as they are.
    feedFile(b, &hasher, "build:", ".", "build.zig");

    var paths: std.ArrayList([]const u8) = .empty;
    collectAll(b, "src", "", &paths);
    sortPaths(&paths);
    if (paths.items.len == 0) std.debug.panic("the compiler source tree at src/ is empty", .{});
    for (paths.items) |rel| feedFile(b, &hasher, "", "src", rel);

    // The core package, exactly as `embedCore` embeds it.
    for (coreFiles(b, core)) |file| {
        feed(&hasher, b.fmt("core:{s}", .{file.rel}));
        switch (file.origin) {
            .disk => |full| {
                const bytes = readBuildFile(b, full);
                feed(&hasher, bytes);
                b.allocator.free(bytes);
            },
            .text => |text| feed(&hasher, text),
        }
    }

    // Every platform the binary carries, built in or added by `-Dplatform`:
    // its Zig, because a markup lowering is part of the compiler
    // (`boundary.md` §9.6), and every other file, because the binary embeds
    // it (`embedPlatforms`).
    for (sources) |source| {
        var platform_paths: std.ArrayList([]const u8) = .empty;
        collectAll(b, source.dir, "", &platform_paths);
        sortPaths(&platform_paths);
        const label = b.fmt("platform:{s}/", .{source.name});
        for (platform_paths.items) |rel| feedFile(b, &hasher, label, source.dir, rel);
    }

    var out: [16]u8 = undefined;
    hasher.final(&out);
    return out;
}

/// One file of the digest: `label` and `rel` as its name, then its bytes.
fn feedFile(b: *std.Build, hasher: *std.hash.SipHash128(1, 3), label: []const u8, dir: []const u8, rel: []const u8) void {
    feed(hasher, if (label.len == 0) rel else b.fmt("{s}{s}", .{ label, rel }));
    const bytes = readBuildFile(b, b.pathJoin(&.{ dir, rel }));
    feed(hasher, bytes);
    b.allocator.free(bytes);
}

/// A file the build id hashes: relative to the build root, or absolute.
fn readBuildFile(b: *std.Build, full: []const u8) []u8 {
    return b.build_root.handle.readFileAlloc(b.graph.io, full, b.allocator, .unlimited) catch |err| {
        std.debug.panic("cannot read {s} for the compiler build id: {t}", .{ full, err });
    };
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
fn embedCore(b: *std.Build, core: Core) *std.Build.Module {
    const dir = core.dir;
    const files = coreFiles(b, core);
    const wf = b.addWriteFiles();
    for (files) |file| switch (file.origin) {
        .disk => |full| _ = wf.addCopyFile(b.path(full), file.rel),
        .text => |text| _ = wf.add(file.rel, text),
    };
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
    for (files) |file| {
        if (!file.module) continue;
        manifest.appendSlice(b.allocator, b.fmt("    .{{ .rel = \"{s}\", .source = @embedFile(\"{s}\") }},\n", .{ file.rel, file.rel })) catch @panic("OOM");
    }
    manifest.appendSlice(b.allocator, "};\npub const assets = [_]Asset{\n") catch @panic("OOM");
    for (files) |file| {
        if (file.module) continue;
        manifest.appendSlice(b.allocator, b.fmt("    .{{ .path = \"{s}/{s}\", .bytes = @embedFile(\"{s}\") }},\n", .{ dir, file.rel, file.rel })) catch @panic("OOM");
    }
    manifest.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    return b.createModule(.{ .root_source_file = wf.add("core_package.zig", manifest.items) });
}

/// The core package a compiler embeds: the files under `dir`, and `extra`
/// beside them — which only the variant compiler of `tests/blackbox/
/// build_id_test.zig` has, to be a binary that differs from the shipped one
/// in its embedded core and nothing else.
const Core = struct {
    dir: []const u8,
    extra: ?struct { rel: []const u8, text: []const u8 } = null,
};

/// The core every shipped compiler embeds.
const shipped_core: Core = .{ .dir = core_dir };

/// One file of a `Core`, as `embedCore` embeds it and the build id hashes it.
const CoreFile = struct {
    /// Relative to the core directory, with `/` separators.
    rel: []const u8,
    /// A `.beni` module rather than an asset.
    module: bool,
    origin: union(enum) {
        /// Its path relative to the build root.
        disk: []const u8,
        /// Its bytes, made by this script.
        text: []const u8,
    },
};

/// Every file of `core`: the modules sorted by path, then the assets sorted
/// by path — the order `embedCore` writes them in.
fn coreFiles(b: *std.Build, core: Core) []const CoreFile {
    var paths: std.ArrayList([]const u8) = .empty;
    var assets: std.ArrayList([]const u8) = .empty;
    collectFiles(b, core.dir, "", &paths, &assets);
    if (core.extra) |extra| {
        const list = if (std.mem.endsWith(u8, extra.rel, ".beni")) &paths else &assets;
        for (list.items) |rel| if (std.mem.eql(u8, rel, extra.rel)) std.debug.panic("{s}/{s} exists; a core's extra file must be a new one", .{ core.dir, rel });
        list.append(b.allocator, extra.rel) catch @panic("OOM");
    }
    sortPaths(&paths);
    sortPaths(&assets);
    if (paths.items.len == 0) std.debug.panic("the core package at {s} is empty", .{core.dir});

    var out: std.ArrayList(CoreFile) = .empty;
    for ([_][]const []const u8{ paths.items, assets.items }, [_]bool{ true, false }) |list, module| {
        for (list) |rel| {
            const extra_text: ?[]const u8 = if (core.extra) |extra|
                (if (std.mem.eql(u8, extra.rel, rel)) extra.text else null)
            else
                null;
            out.append(b.allocator, .{
                .rel = rel,
                .module = module,
                .origin = if (extra_text) |text| .{ .text = text } else .{ .disk = b.pathJoin(&.{ core.dir, rel }) },
            }) catch @panic("OOM");
        }
    }
    return out.items;
}

/// The HTML character references markup text decodes (`frontend.md` §9.7,
/// `language.md` §11.4), as the module `markup_entity_table`: WHATWG's
/// `entities.json`, pinned at `src/markup/entities.json`, read here at
/// configure time into one table sorted by name bytes, so the decoder in
/// `src/markup/entities.zig` can search it for the longest match. The JSON
/// is under `src/`, so the compiler build id covers it. Made once per
/// `zig build` and shared by every compiler the graph builds.
fn entityTable(b: *std.Build) *std.Build.Module {
    if (entity_table_module) |m| return m;
    const io = b.graph.io;
    const json_path = "src/markup/entities.json";
    const bytes = b.build_root.handle.readFileAlloc(io, json_path, b.allocator, .unlimited) catch |err| {
        std.debug.panic("cannot read {s}: {t}", .{ json_path, err });
    };
    const parsed = std.json.parseFromSlice(std.json.Value, b.allocator, bytes, .{}) catch |err| {
        std.debug.panic("{s} is not JSON: {t}", .{ json_path, err });
    };
    const Entry = struct { name: []const u8, value: []const u8 };
    var entries: std.ArrayList(Entry) = .empty;
    var it = parsed.value.object.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        if (key.len < 2 or key[0] != '&') std.debug.panic("{s}: an entity name must begin with '&': {s}", .{ json_path, key });
        const characters = kv.value_ptr.*.object.get("characters") orelse std.debug.panic("{s}: {s} has no characters", .{ json_path, key });
        entries.append(b.allocator, .{ .name = key[1..], .value = characters.string }) catch @panic("OOM");
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, x: Entry, y: Entry) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.lessThan);

    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(b.allocator,
        \\//! Generated by build.zig from src/markup/entities.json: every named
        \\//! character reference of HTML, without its `&`, sorted by name bytes.
        \\
        \\pub const Entity = struct { name: []const u8, value: []const u8 };
        \\
        \\pub const table = [_]Entity{
        \\
    ) catch @panic("OOM");
    var longest: usize = 0;
    for (entries.items) |e| {
        longest = @max(longest, e.name.len);
        out.appendSlice(b.allocator, b.fmt("    .{{ .name = \"{s}\", .value = \"", .{e.name})) catch @panic("OOM");
        for (e.value) |c| out.appendSlice(b.allocator, b.fmt("\\x{x:0>2}", .{c})) catch @panic("OOM");
        out.appendSlice(b.allocator, "\" },\n") catch @panic("OOM");
    }
    out.appendSlice(b.allocator, b.fmt("}};\n\n/// The longest name, `;` included.\npub const longest_name: usize = {d};\n", .{longest})) catch @panic("OOM");
    const wf = b.addWriteFiles();
    const m = b.createModule(.{ .root_source_file = wf.add("markup_entity_table.zig", out.items) });
    entity_table_module = m;
    return m;
}

var entity_table_module: ?*std.Build.Module = null;

/// One platform package compiled into beni (`docs/design/boundary.md`
/// §9.5): a directory under `platforms/`, or one `-Dplatform=<dir>` adds.
const PlatformSource = struct {
    /// What `--platform=<name>` matches: the directory's name for a
    /// platform that ships, the manifest's `"name"` (else the directory's)
    /// for one added.
    name: []const u8,
    /// Where it is on disk: relative to the build root for a platform that
    /// ships, absolute for one added.
    dir: []const u8,
    /// The manifest's `"zig"`: the root of the platform's Zig module,
    /// relative to `dir`.
    zig: ?[]const u8,
    /// The manifest's `"platforms"`: the platforms it depends on, by name.
    deps: []const []const u8,
};

/// The platforms this beni carries: every directory under `platforms/`,
/// sorted by name, then each `-Dplatform` directory in the order given.
/// Two with one name are a configure-time failure.
fn platformSources(b: *std.Build, added: []const []const u8) []const PlatformSource {
    const io = b.graph.io;
    var out: std.ArrayList(PlatformSource) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var handle = b.build_root.handle.openDir(io, platforms_dir, .{ .iterate = true }) catch |err| {
        std.debug.panic("cannot open platforms directory {s}: {t}", .{ platforms_dir, err });
    };
    defer handle.close(io);
    var it = handle.iterate();
    while (it.next(io) catch |err| std.debug.panic("cannot read {s}: {t}", .{ platforms_dir, err })) |entry| {
        if (entry.kind != .directory or entry.name[0] == '.') continue;
        names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }
    sortPaths(&names);
    for (names.items) |name| {
        const dir = b.fmt("{s}/{s}", .{ platforms_dir, name });
        const m = readPlatformManifest(b, dir);
        out.append(b.allocator, .{ .name = name, .dir = dir, .zig = m.zig, .deps = m.platforms }) catch @panic("OOM");
    }
    for (added) |spelled| {
        const dir = if (std.fs.path.isAbsolute(spelled)) b.dupe(spelled) else b.pathFromRoot(spelled);
        const m = readPlatformManifest(b, dir);
        const name = m.name orelse std.fs.path.basename(dir);
        out.append(b.allocator, .{ .name = name, .dir = dir, .zig = m.zig, .deps = m.platforms }) catch @panic("OOM");
    }
    for (out.items, 0..) |x, i| for (out.items[0..i]) |y| {
        if (std.mem.eql(u8, x.name, y.name)) std.debug.panic("two platforms are named '{s}': {s} and {s}", .{ x.name, y.dir, x.dir });
    };
    return out.items;
}

const PlatformManifest = struct {
    name: ?[]const u8 = null,
    zig: ?[]const u8 = null,
    platforms: []const []const u8 = &.{},
};

/// The keys of `<dir>/beni.json` the build reads: the platform's name, its
/// Zig module's root and the platforms it depends on.
fn readPlatformManifest(b: *std.Build, dir: []const u8) PlatformManifest {
    const io = b.graph.io;
    const path = b.pathJoin(&.{ dir, "beni.json" });
    const bytes = b.build_root.handle.readFileAlloc(io, path, b.allocator, .limited(64 * 1024)) catch |err| {
        std.debug.panic("cannot read the platform manifest {s}: {t}", .{ path, err });
    };
    return std.json.parseFromSliceLeaky(PlatformManifest, b.allocator, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
        std.debug.panic("the platform manifest {s} is not a JSON object of the expected shape: {t}", .{ path, err });
    };
}

/// The disk path of a platform's file, as a build input.
fn platformFile(b: *std.Build, source: PlatformSource, rel: []const u8) std.Build.LazyPath {
    const full = b.pathJoin(&.{ source.dir, rel });
    if (std.fs.path.isAbsolute(full)) return .{ .cwd_relative = full };
    return b.path(full);
}

/// The markup lowering interface (`src/markup/Interface.zig`, imported as
/// `beni_markup`), each platform's Zig module (`platform_<name>`, `-`
/// spelled `_`), and the registry the compiler reads: every lowering of
/// every platform module, sorted by name, checked against the interface's
/// version at compile time (`docs/design/boundary.md` §9.4.6, §9.5).
///
/// A platform's module may import `beni_markup`, `std`, and the modules of
/// the platforms it depends on, transitively, and nothing of the compiler.
/// `test_build` gives every module a target and a mode, for the unit tests
/// that run each as a root of its own; otherwise they inherit the
/// compiler's.
fn markupModules(
    b: *std.Build,
    sources: []const PlatformSource,
    test_build: ?struct { target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode },
) MarkupModules {
    const target = if (test_build) |t| t.target else null;
    const optimize = if (test_build) |t| t.optimize else null;
    const interface = b.createModule(.{ .root_source_file = b.path("src/markup/Interface.zig"), .target = target, .optimize = optimize });
    const modules = b.allocator.alloc(?*std.Build.Module, sources.len) catch @panic("OOM");
    var all: std.ArrayList(*std.Build.Module) = .empty;
    all.append(b.allocator, interface) catch @panic("OOM");
    for (sources, modules) |source, *slot| {
        const zig = source.zig orelse {
            slot.* = null;
            continue;
        };
        const m = b.createModule(.{ .root_source_file = platformFile(b, source, zig), .target = target, .optimize = optimize });
        m.addImport("beni_markup", interface);
        slot.* = m;
        all.append(b.allocator, m) catch @panic("OOM");
    }
    // The dependencies' modules, transitively, by the names the manifests
    // give them.
    for (sources, modules) |source, maybe_module| {
        const m = maybe_module orelse continue;
        var pending: std.ArrayList([]const u8) = .empty;
        pending.appendSlice(b.allocator, source.deps) catch @panic("OOM");
        var seen: std.ArrayList([]const u8) = .empty;
        while (pending.pop()) |dep| {
            var repeated = false;
            for (seen.items) |s| repeated = repeated or std.mem.eql(u8, s, dep);
            if (repeated) continue;
            seen.append(b.allocator, dep) catch @panic("OOM");
            for (sources, modules) |other, other_module| {
                if (!std.mem.eql(u8, other.name, dep)) continue;
                pending.appendSlice(b.allocator, other.deps) catch @panic("OOM");
                if (other_module) |om| m.addImport(zigModuleName(b, other.name), om);
            }
        }
    }

    var text: std.ArrayList(u8) = .empty;
    text.appendSlice(b.allocator,
        \\//! Generated by build.zig: every markup lowering compiled into this beni
        \\//! (docs/design/boundary.md §9.5), sorted by name, each checked against
        \\//! the interface's version at compile time (§9.4.6).
        \\
        \\const beni_markup = @import("beni_markup");
        \\
        \\const groups = .{
        \\
    ) catch @panic("OOM");
    const registry_wf = b.addWriteFiles();
    for (sources, modules) |source, maybe_module| {
        if (maybe_module == null) continue;
        text.appendSlice(b.allocator, b.fmt("    @import(\"{s}\").lowerings,\n", .{zigModuleName(b, source.name)})) catch @panic("OOM");
    }
    text.appendSlice(b.allocator,
        \\};
        \\
        \\pub const all: []const beni_markup.Lowering = blk: {
        \\    var n: usize = 0;
        \\    for (groups) |group| n += group.len;
        \\    var list: [n]beni_markup.Lowering = undefined;
        \\    var at: usize = 0;
        \\    for (groups) |group| for (group) |l| {
        \\        beni_markup.checkTargets(l);
        \\        // Insertion by name, so the table is sorted whatever the
        \\        // order the platforms were given in.
        \\        var i = at;
        \\        while (i > 0 and lessThan(l.name, list[i - 1].name)) : (i -= 1) list[i] = list[i - 1];
        \\        if (i > 0 and eql(l.name, list[i - 1].name)) @compileError("two markup lowerings are named '" ++ l.name ++ "'");
        \\        list[i] = l;
        \\        at += 1;
        \\    };
        \\    const final = list;
        \\    break :blk &final;
        \\};
        \\
        \\fn lessThan(a: []const u8, b: []const u8) bool {
        \\    var i: usize = 0;
        \\    while (i < a.len and i < b.len) : (i += 1) {
        \\        if (a[i] != b[i]) return a[i] < b[i];
        \\    }
        \\    return a.len < b.len;
        \\}
        \\
        \\fn eql(a: []const u8, b: []const u8) bool {
        \\    return !lessThan(a, b) and !lessThan(b, a);
        \\}
        \\
    ) catch @panic("OOM");
    const registry = b.createModule(.{ .root_source_file = registry_wf.add("markup_lowerings.zig", text.items), .target = target, .optimize = optimize });
    registry.addImport("beni_markup", interface);
    for (sources, modules) |source, maybe_module| {
        const m = maybe_module orelse continue;
        registry.addImport(zigModuleName(b, source.name), m);
    }
    return .{ .interface = interface, .registry = registry, .all = all.items };
}

const MarkupModules = struct {
    interface: *std.Build.Module,
    registry: *std.Build.Module,
    /// The interface and every platform module, for their unit tests.
    all: []const *std.Build.Module,
};

/// `platform_<name>`, with `-` spelled `_`.
fn zigModuleName(b: *std.Build, name: []const u8) []const u8 {
    const out = b.fmt("platform_{s}", .{name});
    std.mem.replaceScalar(u8, out, '-', '_');
    return out;
}

/// For a build that depends on beni: the beni dependency with the platform
/// in `dir`, relative to the depending build's root, compiled in exactly as
/// `-Dplatform=<dir>` compiles one (`docs/design/boundary.md` §9.5).
pub fn addPlatform(b: *std.Build, options: struct { dir: []const u8, dependency: []const u8 = "beni" }) *std.Build.Dependency {
    const dirs: []const []const u8 = &.{b.pathFromRoot(options.dir)};
    return b.dependency(options.dependency, .{ .platform = dirs });
}

/// Every platform package this beni carries, embedded: its manifest bytes,
/// its `.beni` modules and its JavaScript, and not its Zig, which is
/// compiled in rather than shipped. `--platform=<name>` matches the
/// platform's name, so adding a platform to the box is dropping in a
/// directory (boundary.md §5.1: supporting a runtime is a package, not a
/// compiler change). A platform added with `-Dplatform` is spelled
/// `platforms/<name>` in paths, as one that ships is.
fn embedPlatforms(b: *std.Build, sources: []const PlatformSource) *std.Build.Module {
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
    for (sources, 0..) |source, index| {
        const name = source.name;
        const root = b.fmt("{s}/{s}", .{ platforms_dir, name });
        var files: std.ArrayList([]const u8) = .empty;
        var assets: std.ArrayList([]const u8) = .empty;
        collectFiles(b, source.dir, "", &files, &assets);
        sortPaths(&files);
        sortPaths(&assets);
        if (files.items.len == 0) std.debug.panic("the platform package at {s} has no modules", .{source.dir});

        const manifest_rel = b.fmt("{s}/beni.json", .{name});
        _ = wf.addCopyFile(platformFile(b, source, "beni.json"), manifest_rel);
        bodies.appendSlice(b.allocator, b.fmt("const files_{d} = [_]File{{\n", .{index})) catch @panic("OOM");
        for (files.items) |rel| {
            const key = b.fmt("{s}/{s}", .{ name, rel });
            _ = wf.addCopyFile(platformFile(b, source, rel), key);
            bodies.appendSlice(b.allocator, b.fmt("    .{{ .rel = \"{s}\", .source = @embedFile(\"{s}\") }},\n", .{ rel, key })) catch @panic("OOM");
        }
        bodies.appendSlice(b.allocator, b.fmt("}};\nconst assets_{d} = [_]Asset{{\n", .{index})) catch @panic("OOM");
        for (assets.items) |rel| {
            if (std.mem.eql(u8, rel, "beni.json")) continue;
            if (std.mem.endsWith(u8, rel, ".zig")) continue;
            const key = b.fmt("{s}/{s}", .{ name, rel });
            _ = wf.addCopyFile(platformFile(b, source, rel), key);
            bodies.appendSlice(b.allocator, b.fmt("    .{{ .path = \"{s}/{s}\", .bytes = @embedFile(\"{s}\") }},\n", .{ root, rel, key })) catch @panic("OOM");
        }
        bodies.appendSlice(b.allocator, "};\n") catch @panic("OOM");
        table.appendSlice(b.allocator, b.fmt(
            "    .{{ .name = \"{s}\", .root = \"{s}\", .manifest = @embedFile(\"{s}\"), .files = &files_{d}, .assets = &assets_{d} }},\n",
            .{ name, root, manifest_rel, index, index },
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
    part: []const u8 = "",
    scenarios: []const u8 = "",
    /// `perf_test.zig`'s `BENI_PERF_SHARD`: which of its scenarios this
    /// process runs.
    perf_shard: []const u8 = "",
    /// `tests/test_runner.zig`'s `BENI_TEST_SHARD` (`k/n`): which of the
    /// binary's tests this process runs.
    shard: []const u8 = "",
    /// The compiler under test: the ReleaseSafe one unless a timing step
    /// names the ReleaseFast one, or the external platform's scenario the one
    /// with the toy platform compiled in.
    exe: enum { safe, fast, toy } = .safe,
    /// Whether the run also needs the compiler with a variant core, which
    /// it finds through `BENI_VARIANT_EXE` (`build_id_test.zig`).
    variant: bool = false,
    /// The corpus walker's `BENI_RUN_HASHES` (`record`) and
    /// `BENI_RUN_HASH_REPORT` (where its `run/` counts go).
    run_hashes: []const u8 = "",
    report_dir: []const u8 = "",
    /// The corpus walker's `BENI_BROWSER`: `chrome` runs the `browser/`
    /// pages in Chrome instead of happy-dom.
    browser: []const u8 = "",
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
    /// Install `toy_bin_dir/beni`, the beni with the toy platform compiled in.
    toy_install: *std.Build.Step,
    /// Install `variant_bin_dir/beni`, the beni with a variant core.
    variant_install: *std.Build.Step,
    /// `-Dtest-budget`, for every run held to it.
    budget: TestBudget,
    /// `-Dchrome`, pinned as `BENI_CHROME` on every run: the Chrome
    /// `test-browser` runs pages in, or empty to find one on `PATH`.
    chrome: []const u8,

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
            .toy => bb.toy_install,
        });
        if (env.variant) r.step.dependOn(bb.variant_install);
        r.setEnvironmentVariable("BENI_VARIANT_EXE", if (env.variant) bb.b.getInstallPath(.prefix, bb.b.fmt("{s}/beni", .{variant_bin_dir})) else "");
        r.setCwd(bb.b.path("."));
        r.setEnvironmentVariable("BENI_CORPUS_ROOT", env.root);
        r.setEnvironmentVariable("BENI_CORPUS_MODE", env.mode);
        r.setEnvironmentVariable("BENI_CASE_TIMEOUT_MS", env.timeout_ms);
        r.setEnvironmentVariable("BENI_CORPUS_PART", env.part);
        r.setEnvironmentVariable("BENI_CORPUS_ONLY", bb.corpus_only);
        r.setEnvironmentVariable("BENI_PENDING_SCENARIOS", env.scenarios);
        r.setEnvironmentVariable("BENI_PERF_SHARD", env.perf_shard);
        r.setEnvironmentVariable("BENI_TEST_SHARD", env.shard);
        r.setEnvironmentVariable("BENI_RUN_HASHES", env.run_hashes);
        r.setEnvironmentVariable("BENI_RUN_HASH_REPORT", env.report_dir);
        r.setEnvironmentVariable("BENI_BROWSER", env.browser);
        r.setEnvironmentVariable("BENI_CHROME", bb.chrome);
        // The gates' budget in instructions, for the pending scenarios whose
        // finding is that they do not fit it (`pending_test.zig`).
        r.setEnvironmentVariable("BENI_PENDING_BUDGET_INSTRUCTIONS", bb.budget.instructions);
        setBudget(r, if (env.budget) bb.budget else .none);
        const exe_dir = switch (env.exe) {
            .safe => bb.safe_dir,
            .fast => perf_bin_dir,
            .toy => toy_bin_dir,
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
