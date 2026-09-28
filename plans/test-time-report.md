# Where the test time goes

Measured 2026-09-28 on `master` at `96f6054`, in a separate worktree. The
machine is a Ryzen 9 5950X (16 cores, 32 threads) with `/home` on btrfs. Other
agents were building on it throughout, and the 1-minute load average ranged
from 3 to 98 across the day. Every number below says which conditions it was
taken under. **CPU time (user + sys, from `wait4` rusage) is the primary
metric; wall-clock time is secondary and noisy.**

## 0. The short version

**§8 records what was done about it, and the result.** Test-process CPU
in the gates fell by 35–46% in three runs against `master` at matched
load, and a quiet gates run is now 13.5 s and 204 CPU-s. The matrix and
the spinner test are gone, and the default `--jobs` is sized by the work.
Everything from here to §7 describes the suite as it was before.

- **The gates are throughput-bound, not latency-bound.** A warm
  `zig build gates` took 26.2 s wall and 660 CPU-s (401 user + 259 sys) on the
  quietest run. Under the day's normal load it took 31–42 s and 790–970 CPU-s.
  32 hardware threads × 26 s ≈ 830 thread-seconds, so the machine is
  saturated for almost the whole run. **Cutting CPU cuts wall time roughly in
  proportion.** The longest single steps take 14–16 s, so the critical path is
  not what bounds the run.
- **38–40% of all gate CPU is kernel time.** One gates run makes 30.2 M minor
  page faults, 9 527 `execve`s and about 172 000 thread creations (`clone`).
  Of those threads, 167 076 belong to the 8 442 `beni` processes: about 20 per
  process on average, and 44 in a default-`--jobs` run of a one-file project.
- **Running concurrently roughly doubles the CPU cost of the same work.** Run
  one binary at a time, the black-box suite costs 364–405 CPU-s, the unit
  tests 29 and the compare generator's tests 4. In the gates the same work
  costs 660–970 CPU-s. Four things cause the inflation: SMT sharing, lower
  all-core clocks, contention on the kernel `mmap_lock` and page-fault paths,
  and btrfs.
- **The five biggest consumers** (single-binary CPU-s; multiply by about 2 for
  the gates):

  | consumer | CPU-s | share |
  |---|---:|---:|
  | `matrix_test` | 131 | 32% |
  | the "diagnostics … under load" spinner test | 85 | 21% |
  | `corpus_test` `run/` (two builds and two Node runs per fixture) | 71 | 18% |
  | `beni`'s default `--jobs` (32 workers + checker threads, each with a 64 MiB stack) | ≈54 of the 90 CPU-s that the default-`--jobs` runs cost | 13% of the suite |
  | Node | 55 (716 runs) | 14% |

- **A coverage hole, found in passing (§5.1):** every `dump` in
  `matrix_test` (1 040 runs per gates run) exits 2 with
  `unknown option '--no-cache'`. Every variant fails identically, so the
  matrix passes and asserts nothing about `--stage=raw`, `interface` or
  `dispatch`.
- **Top recommendations (§6):**
  1. Stop over-provisioning `beni` threads: −54 CPU-s single-binary,
     −150 to −230 CPU-s in the gates.
  2. Move or cheapen the spinner test: −85 CPU-s.
  3. Merge `matrix_test`'s baseline run into the corpus walker: −15 CPU-s.
  4. Mark the test run steps `has_side_effects`: the build runner hashes every
     114 MB test binary once per shard.
  5. Put the harness's temporary directories on tmpfs: this removed every
     1.7–3.7 s btrfs stall.

  Applying (1) and (2) together measured −27% to −35% gates CPU and −11% to
  −19% gates wall on this machine.

## 1. Method

- **Worktree.** A detached worktree at `96f6054`, with its `.zig-cache`
  symlinked onto the btrfs home disk so that test temporary directories live
  where they live in the real repo.
- **Instrumentation, worktree only; nothing tracked was edited:**
  - `tests/test_runner.zig` logs every test (wall time, plus `getrusage`
    deltas for SELF and CHILDREN) and every test process at exit.
  - `tests/blackbox/world.zig` logs every child `spawnAndCapture` reaps: argv,
    wall time, and user/sys/maxrss/minflt/nvcsw/nivcsw/exit from `wait4`.
    `wait4` rusage includes the child's own reaped descendants. The line is
    attributed to the current test (through `@import("root")`) and the current
    corpus case (a threadlocal).
  - `corpus_test.zig` and `matrix_test.zig` log each fixture's wall time and
    worker-thread CPU (`RUSAGE_THREAD`).

  The overhead is one `write` per event. Instrumented and pristine gates runs
  fall within each other's noise. Pristine runs took 928, 938 and
  964 CPU-s at loads 42–59; logging runs took 961 and 1 057 at loads 64–78.
- **Runs:**

  | run | what it measures | conditions |
  |---|---|---|
  | warm `zig build gates --summary all` under GNU `time -v` | pristine, 3+3+3 runs; instrumented, 6 runs | loads 3–98 |
  | each black-box binary alone, all shards in one process | per-test and per-fixture tables | twice, loads 13–34 |
  | the unit-test binary alone | per-test table | `ulimit -s unlimited`; see §3.2 |
  | `strace -f --seccomp-bpf -e execve,clone,clone3,fork` over a whole gates run | process and thread counts | — |
  | `perf record -F 499` (user space only; `perf_event_paranoid=2`) over a whole gates run | CPU share by process image | — |
  | `perf stat -r 40` | the micro-benchmarks | — |
  | four A/B experiments in the worktree | §6 | — |

- **What the tables call what:**
  - *Solo* means one binary at a time with no self-contention: the
    reproducible numbers. *Gates* means inside the concurrent build graph.
  - "Harness" is CPU the Zig test process itself spent. "Child" is its reaped
    children.
- **Caveat.** The gates' CPU drifted upward within back-to-back series:
  660 → 762 → 817 CPU-s. The likely causes are package heating (lower clocks
  mean more CPU-seconds for the same work) and other agents. Treat single
  gates-level deltas below about 100 CPU-s as unresolved.

## 2. Per step

### 2.1 `zig build gates`, inside the build graph

Instrumented run "base-1": load 40 before; 33.2 s wall; 845 CPU-s in total, of
which 784 were in test processes. Each row aggregates a binary's shards.

| step (binary) | procs | tests | wall s (min–max per process) | harness user | harness sys | child user | child sys | **total CPU s** | harness max RSS MB | child max RSS MB | beni | node |
|---|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| matrix_test | 1 | 1 | 18.8 | 9.2 | 18.0 | 75.3 | 70.2 | **172.7** | 22 | 29 | 3912 | 0 |
| blackbox_test | 6 | 118 | 9.9–12.8 | 67.3 | 2.1 | 11.2 | 12.5 | **93.1** | 22 | 58 | 778 | 14 |
| unit tests (`beni` module, 12 shards) | 12 | 484 | 0.8–15.3 | 61.4 | 18.3 | 0 | 0 | **79.7** | 170 | – | 0 | 0 |
| corpus_test part run_dev | 1 | 14 | 13.1 | 0.4 | 0.9 | 43.0 | 26.0 | **70.2** | 20 | 639 | 251 | 251 |
| corpus_test part run_release | 1 | 14 | 11.3 | 0.4 | 1.0 | 41.0 | 26.7 | **69.1** | 21 | 521 | 251 | 251 |
| corpus_test part check | 1 | 14 | 9.6 | 0.6 | 0.7 | 22.8 | 22.1 | **46.2** | 19 | 18 | 525 | 0 |
| abuse_test | 6 | 39 | 5.5–14.2 | 1.7 | 1.6 | 28.0 | 10.1 | **41.4** | 107 | 417 | 101 | 15 |
| ordering_test | 4 | 8 | 11.5–16.2 | 0.3 | 0.7 | 22.1 | 17.8 | **41.0** | 22 | 56 | 322 | 87 |
| abuse_wide_test | 3 | 10 | 11.8–21.3 | 1.4 | 0.2 | 21.7 | 12.0 | **35.3** | 19 | 378 | 29 | 21 |
| cache_test | 4 | 57 | 12.4–25.1 | 1.6 | 2.2 | 16.1 | 11.4 | **31.4** | 22 | 75 | 400 | 51 |
| corpus_test part parse | 1 | 14 | 8.2 | 0.6 | 0.9 | 11.6 | 14.7 | **27.8** | 20 | 79 | 567 | 0 |
| frontend_test | 1 | 4 | 6.9 | 0.4 | 1.1 | 9.0 | 16.3 | **26.8** | 21 | 11 | 715 | 0 |
| cutoff_test | 4 | 4 | 9.6–10.6 | 0.7 | 0.6 | 9.8 | 8.9 | **20.0** | 20 | 12 | 285 | 0 |
| build_test | 3 | 57 | 11.8–13.8 | 0.5 | 0.9 | 7.4 | 6.8 | **15.7** | 22 | 64 | 79 | 25 |
| corpus_test part build | 1 | 14 | 3.9 | 0.4 | 0.3 | 2.3 | 2.3 | **5.3** | 22 | 12 | 50 | 0 |
| digest_test | 3 | 20 | 7.1–12.5 | 0.4 | 0.9 | 1.7 | 1.6 | **4.5** | 22 | 8 | 85 | 0 |
| iface_test | 1 | 8 | 8.3 | 0.1 | 0.2 | 0.7 | 0.6 | **1.6** | 19 | 8 | 38 | 0 |
| check_test | 1 | 9 | 6.6 | 0.1 | 0.1 | 0.6 | 0.8 | **1.6** | 18 | 11 | 21 | 0 |
| docs_test | 1 | 1 | 1.5 | 0.2 | 0.1 | 0.2 | 0.1 | **0.5** | 19 | 58 | 1 | 1 |

The steps below use std's default runner, so the table above has no row for
them; their figures come from `--summary all` and from hand runs.

| step | tests | wall in gates | CPU |
|---|---:|---|---|
| compare generator unit tests (`bench/compare/gen/main.zig`, unsharded) | 18 | **14–18 s** | 3.9 CPU-s solo; one test, "the oracle accepts every family at sizes 1-4 over 16 seeds", is 3.0 s of it |
| `compare_gen_test` (black-box) | 2 | ≈1 s | — |
| `bench/gen.zig` tests | 11 | 0.5–1 s | — |
| `diagnostic` tests | 4 | 30 ms | — |
| `fmt-check` | — | 0.1–0.3 s | — |
| build runner itself | — | — | about 4.6% of all user-mode samples. Nearly all of it is SipHash over the test binaries (§4.4) |
| the 22 `zig` compile-step cache checks | — | — | 1.2% of user-mode samples |

Unit shard walls (s) in the same run:

| shard | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| wall s | 13 | 4 | 0.8 | 10 | 1 | 3 | 1 | 15 | 7 | 6 | 15 | 3 |

The imbalance follows the four heavy fuzz and stress tests (§3.2).

**Where the process time went in a whole gates run** (user-mode samples by
process image, from `perf`):

| image | share of user-mode samples |
|---|---:|
| beni | 53.8% |
| Node (`MainThread`, `V8Worker`, `node`) | 14.9% |
| unit test binary | 10.5% |
| `blackbox_test` (the spinner) | 9.6% |
| build runner | 4.6% |
| `matrix_test` harness | 2.75% |
| `zig` | 1.2% |
| everything else | under 3% |

### 2.2 `test-perf` and `test-pending`

Load 2–4 for both.

- **`test-perf`**: 18.5 s wall, 22.0 CPU-s (14.0 user + 8.0 sys), 143 `beni`
  runs, on the ReleaseFast binary.
  - Critical path: the slowest CPU shard (`cpu:3/7`, 9.1 s) is dominated by
    "a chain of ever deeper bindings is linear or nesting_too_deep" (9.0 s;
    max RSS **3.2 GB**). Then the serial `wall` shard (9.2 s) is dominated by
    "many schemas with `via`s, each compared, cost linear time" (4.0 s).
  - So the step's wall is two 9-second processes in series.
  - Every other perf scenario is under 1.3 s.
- **`test-pending`**: 0.39 s wall, 0.56 CPU-s. `tests/pending/` holds only
  `README.md` and `RED` today, so the step runs no fixture, and two scenarios
  in 133 ms.

## 3. Per test

### 3.1 Black-box tests: top 40 by CPU

Single-binary runs, loads 13–34. "Harness" is CPU in the test process.
`corpus_test`'s rows are whole kinds; fixtures are in §3.3.

| # | test | wall s | harness CPU s | child CPU s | total CPU s | beni | node |
|---|---|---:|---:|---:|---:|---:|---:|
| 1 | matrix_test · the acceptance matrix: cold and round-tripped agree at every --jobs | 8.56 | 20.16 | 110.43 | 130.59 | 3912 | 0 |
| 2 | blackbox_test · diagnostics do not depend on which worker lexed which file, under load | 2.87 | 84.48 | 2.33 | 86.81 | 36 | 0 |
| 3 | corpus_test · corpus: run | 7.69 | 1.22 | 70.09 | 71.31 | 502 | 502 |
| 4 | corpus_test · corpus: check/bad | 1.11 | 0.32 | 12.18 | 12.50 | 267 | 0 |
| 5 | frontend_test · the identity oracle: every bir and parse/good fixture dumps the same three ways | 0.94 | 0.44 | 7.18 | 7.62 | 576 | 0 |
| 6 | corpus_test · corpus: check/good | 0.56 | 0.15 | 6.08 | 6.23 | 142 | 0 |
| 7 | abuse_wide_test · derived eq and compare over a 65 535-field nominal payload build and run, in both builds | 5.70 | 0.08 | 5.59 | 5.68 | 2 | 2 |
| 8 | corpus_test · corpus: fmt | 0.67 | 0.30 | 4.71 | 5.00 | 348 | 0 |
| 9 | corpus_test · corpus: parse/bad | 0.42 | 0.12 | 4.48 | 4.60 | 119 | 0 |
| 10 | abuse_wide_test · a derived row of more than 65 535 context entries checks, and builds and runs | 3.92 | 0.03 | 3.75 | 3.78 | 2 | 1 |
| 11 | ordering_test · … fixed set of orders, second quarter | 2.80 | 0.06 | 3.62 | 3.68 | 80 | 26 |
| 12 | ordering_test · … first quarter | 2.67 | 0.07 | 3.43 | 3.50 | 82 | 27 |
| 13 | ordering_test · … third quarter | 2.39 | 0.06 | 3.13 | 3.19 | 81 | 23 |
| 14 | corpus_test · corpus: dispatch | 0.24 | 0.08 | 2.47 | 2.55 | 62 | 0 |
| 15 | ordering_test · … fourth quarter | 1.70 | 0.04 | 2.33 | 2.38 | 72 | 11 |
| 16 | abuse_test · a record literal nested to the parser's limit compares and RUNS, release build | 1.89 | 0.00 | 1.89 | 1.89 | 1 | 1 |
| 17 | corpus_test · corpus: check/args | 0.17 | 0.08 | 1.75 | 1.82 | 40 | 0 |
| 18 | cache_test · an imported type of 4 097 parameters compares across modules in the wide form, cold, warm and partly warm, in both builds | 1.79 | 0.04 | 1.73 | 1.78 | 8 | 8 |
| 19 | cache_test · a warm rebuild after each edit of a dependency, and after reverting it, is a cold build | 1.69 | 0.14 | 1.63 | 1.77 | 48 | 20 |
| 20 | cutoff_test · the differential harness … third quarter | 1.19 | 0.09 | 1.58 | 1.67 | 75 | 0 |
| 21 | frontend_test · fmt --stdout is byte-identical under the flag over every fmt fixture | 0.22 | 0.10 | 1.52 | 1.62 | 116 | 0 |
| 22 | abuse_test · a chain of forwarders as deep as the parser allows compares and runs: `Just` nested 4 095 deep | 1.47 | 0.01 | 1.49 | 1.50 | 2 | 2 |
| 23 | cutoff_test · the differential harness … second quarter | 1.06 | 0.08 | 1.40 | 1.48 | 75 | 0 |
| 24 | cutoff_test · the differential harness … first quarter | 1.05 | 0.09 | 1.38 | 1.46 | 75 | 0 |
| 25 | abuse_test · a recursive type of 4 097 parameters compares past the derived depth limit, wide | 1.25 | 0.01 | 1.31 | 1.32 | 1 | 1 |
| 26 | blackbox_test · every stream of every command is byte-identical across --jobs=1 and --jobs=8, twice each | 1.17 | 0.16 | 1.12 | 1.28 | 492 | 0 |
| 27 | corpus_test · corpus: emit | 0.14 | 0.07 | 1.20 | 1.27 | 29 | 0 |
| 28 | cutoff_test · the differential harness … fourth quarter | 0.84 | 0.06 | 1.12 | 1.18 | 60 | 0 |
| 29 | cache_test · an edit that moves a dependency's derived context rebuilds its dependents' evidence exactly as a cold build | 1.07 | 0.09 | 1.04 | 1.12 | 36 | 10 |
| 30 | abuse_wide_test · a nominal payload of 65 537 fields checks, and builds and runs or is refused by name | 1.10 | 0.04 | 1.04 | 1.09 | 1 | 1 |
| 31 | abuse_test · a record literal nested to the parser's limit compares and RUNS, development build | 0.92 | 0.01 | 0.93 | 0.94 | 1 | 1 |
| 32 | corpus_test · corpus: parse/good | 0.14 | 0.17 | 0.74 | 0.91 | 69 | 0 |
| 33 | abuse_wide_test · a written operator chain runs at the widest the parser admits, and one term more is one nesting_too_deep | 0.66 | 0.02 | 0.77 | 0.79 | 9 | 6 |
| 34 | abuse_wide_test · == on a record builds and runs at the widest positional evidence and at a width that threw, never a runtime exception | 0.76 | 0.03 | 0.75 | 0.78 | 2 | 2 |
| 35 | corpus_test · corpus: check/depth | 0.09 | 0.05 | 0.69 | 0.74 | 14 | 0 |
| 36 | abuse_wide_test · a case of 16 400 literal branches builds as switches of at most 16 384 labels and runs, in both builds | 0.67 | 0.25 | 0.46 | 0.71 | 2 | 2 |
| 37 | build_test · bench/churn.sh reports every edit class against both variants, counts a rejection, and restores the tree | 0.61 | 0.00 | 0.70 | 0.70 | 0 (≈250 shell tools) | 0 |
| 38 | abuse_wide_test · a 2 000-element list and 2 000-term + and ++ chains build and run, in both builds | 0.57 | 0.01 | 0.64 | 0.66 | 6 | 6 |
| 39 | abuse_wide_test · a type of 65 535 parameters checks, and the 65 536th is one too_many_type_parameters | 0.54 | 0.07 | 0.54 | 0.61 | 2 | 0 |
| 40 | abuse_test · a flat let past what a summed budget allows is accepted, builds and runs: its bindings are siblings | 0.59 | 0.01 | 0.60 | 0.61 | 3 | 2 |

**Distribution of the 350 black-box tests, by CPU, single-binary runs:**

| CPU per test | tests | total CPU-s |
|---|---:|---:|
| under 10 ms | 13 | 0.05 |
| 10–100 ms | 235 | 10.3 |
| 0.1–1 s | 72 | 21.5 |
| 1–10 s | 26 | 70.5 |
| 10 s or more | 4 | **301.2**: the matrix, the spinner, `corpus: run`, `corpus: check/bad` |

So 248 of the 350 tests cost 10 CPU-s between them. **The suite's cost is four
tests and the corpus.**

### 3.2 Unit tests

484 tests. Run alone, serially: 29.5 s wall and 29.0 CPU-s. In the gates,
80–94 CPU-s across 12 shards.

| CPU per test | tests | total s |
|---|---:|---:|
| under 10 ms | 401 | 0.3 |
| 10–100 ms | 60 | 1.6 |
| 0.1–1 s | 16 | 6.5 |
| 1 s or more | 7 | **20.8** |

| # | unit test | wall = CPU s |
|---|---|---:|
| 1 | resolve.iface_bytes · fuzz: a mutated record never reads back as an unverified one | 6.16 |
| 2 | cache.dispatch_bytes · fuzz: a mutated sidecar never reads back as an unverified one | 4.74 |
| 3 | check.Instantiate · copy keeps sharing, shares what is not generalised, and walks 100 000 levels | 3.86 |
| 4 | fmt.Format · deep nesting and very long chains format without exhausting the stack | 1.92 |
| 5 | lex.Tokenizer · stress: random mixes of valid pieces, steering bytes and noise never panic | 1.55 |
| 6 | js.Print · a chain 200 000 links deep prints in a loop, not a stack frame per link | 1.33 |
| 7 | parse.Parse · stress: token soup and grammar fragments never panic and always yield a well-formed tree | 1.27 |
| 8 | resolve.Resolve · stress: mutated corpus fixtures resolve in pairs without a panic | 0.93 |
| 9 | render.text · excerpts for many diagnostics in one file are found by resuming, not rescanning | 0.83 |
| 10 | InternPool · randomized: Local agrees with a StringHashMap oracle across table growth | 0.75 |
| 11 | bir.Lower · stress: mutated corpus fixtures never panic and always lower in bounds | 0.74 |
| 12 | cache.entry_bytes · fuzz: a mutated entry never reads back as one that leaves the file | 0.62 |
| 13 | js.Print · generated: the recursive and the iterative printer agree at every switch-over depth | 0.53 |
| 14 | frontend.artifact_bytes · fuzz: every mutation is refused, and with the hash resealed some still load | 0.38 |
| 15 | check.Walk · a 100 000-deep type goes through occurs, the error scan and lowerTo | 0.32 |

**A hand run of the unit binary segfaults.** The test runner's header says a
hand run "prints one line per test", but run with this shell's 16 MiB stack
limit the binary dies with a stack overflow in `fmt/Format.zig:447`
(`measure`), inside test #4. `zig build` evidently runs it with a larger
stack. Hand runs need `ulimit -s unlimited`.

### 3.3 Corpus fixtures: top 40 by CPU

Single-binary run of `corpus_test`, all parts in one process. For `run/`, the
row sums both passes: two builds and two Node runs.

| # | fixture | kind | CPU ms | wall ms | harness ms | beni runs / ms | node runs / ms |
|---|---|---|---:|---:|---:|---:|---:|
| 1 | run/DerivedDeepPaths.beni | run | 2720 | 2026 | 4.2 | 2 / 89 | 2 / 2627 |
| 2 | run/ListMapNDeep.beni | run | 2632 | 2157 | 5.0 | 2 / 92 | 2 / 2534 |
| 3 | run/ListMapFilterDeep.beni | run | 1815 | 1610 | 4.6 | 2 / 84 | 2 / 1726 |
| 4 | run/SortByKeyOnce.beni | run | 1313 | 1077 | 5.3 | 2 / 93 | 2 / 1215 |
| 5 | run/DerivedDeepAcrossModules | run | 898 | 700 | 4.6 | 2 / 93 | 2 / 800 |
| 6 | run/ListFoldDeep.beni | run | 833 | 720 | 4.5 | 2 / 91 | 2 / 738 |
| 7 | run/DerivedDeepData.beni | run | 607 | 459 | 3.7 | 2 / 94 | 2 / 509 |
| 8 | run/AliasChainThroughLet.beni | run | 508 | 478 | 3.9 | 2 / 353 | 2 / 150 |
| 9 | run/NestingLogicalStatements.beni | run | 386 | 330 | 11.9 | 2 / 191 | 2 / 183 |
| 10 | run/DerivedDeepOrder | run | 357 | 283 | 4.4 | 2 / 97 | 2 / 255 |
| 11 | check/bad/LetOfManyBindings.beni | check_bad | 355 | 349 | 1.0 | 1 / 354 | 0 / 0 |
| 12 | run/ViewMap40x12.beni | run | 339 | 289 | 7.1 | 2 / 136 | 2 / 196 |
| 13 | run/ViewMapEvery3.beni | run | 328 | 274 | 7.9 | 2 / 139 | 2 / 181 |
| 14 | run/TailCallEvidence.beni | run | 316 | 268 | 4.9 | 2 / 91 | 2 / 221 |
| 15 | run/ViewMap20x30.beni | run | 314 | 274 | 6.1 | 2 / 105 | 2 / 203 |
| 16 | run/ReleaseAliasChain1000.beni | run | 306 | 272 | 4.6 | 2 / 169 | 2 / 132 |
| 17 | run/MatchInLoop.beni | run | 306 | 250 | 4.5 | 2 / 90 | 2 / 211 |
| 18 | run/DerivedPartTypedLater | run | 283 | 237 | 5.6 | 2 / 115 | 2 / 163 |
| 19 | run/WideTypeArityEq | run | 278 | 242 | 4.7 | 2 / 123 | 2 / 150 |
| 20 | run/DerivedEqThroughCustom | run | 278 | 228 | 5.1 | 2 / 111 | 2 / 162 |
| 21 | run/NestingChains.beni | run | 278 | 237 | 9.2 | 2 / 100 | 2 / 169 |
| 22 | run/TailCallLetFunction.beni | run | 276 | 232 | 4.3 | 2 / 83 | 2 / 188 |
| 23 | run/CallbackOrderDict.beni | run | 275 | 245 | 5.9 | 2 / 101 | 2 / 168 |
| 24 | run/PipeFirst.beni | run | 275 | 236 | 4.8 | 2 / 106 | 2 / 164 |
| 25 | run/MatchNested.beni | run | 275 | 234 | 5.3 | 2 / 100 | 2 / 169 |
| 26 | run/MatchRecordsTuples.beni | run | 274 | 234 | 4.8 | 2 / 100 | 2 / 169 |
| 27 | run/Placeholder.beni | run | 273 | 234 | 5.5 | 2 / 101 | 2 / 167 |
| 28 | run/MatchListDepth.beni | run | 273 | 234 | 5.2 | 2 / 103 | 2 / 165 |
| 29 | run/NestingElseIf.beni | run | 272 | 229 | 8.9 | 2 / 101 | 2 / 162 |
| 30 | run/MatchLiteralFallthrough.beni | run | 271 | 231 | 4.9 | 2 / 101 | 2 / 165 |
| 31 | run/DerivedPinnedAcrossModules | run | 271 | 228 | 4.3 | 2 / 106 | 2 / 161 |
| 32 | run/CallbackOrderFoldr.beni | run | 270 | 236 | 5.6 | 2 / 101 | 2 / 163 |
| 33 | run/NeverAndOrderDerived.beni | run | 267 | 230 | 5.1 | 2 / 102 | 2 / 160 |
| 34 | run/DerivedOverSpecialisedEq | run | 266 | 224 | 4.4 | 2 / 103 | 2 / 158 |
| 35 | run/ConstrainedFunctionConstantRoutes | run | 265 | 227 | 4.2 | 2 / 103 | 2 / 158 |
| 36 | run/DerivedEqDeepRecord.beni | run | 264 | 230 | 4.4 | 2 / 100 | 2 / 159 |
| 37 | run/PhantomAliasNested.beni | run | 264 | 226 | 5.1 | 2 / 94 | 2 / 165 |
| 38 | run/CallbackOrderList.beni | run | 264 | 224 | 6.0 | 2 / 102 | 2 / 156 |
| 39 | run/CoreStringRest.beni | run | 263 | 229 | 3.9 | 2 / 98 | 2 / 161 |
| 40 | run/NestingEvidence.beni | run | 263 | 231 | 5.6 | 2 / 91 | 2 / 166 |

**Seven "Deep" `run/` programs** (#1–7) spend **10.1 CPU-s in Node**. That is
14% of the corpus. Otherwise a typical `run/` fixture costs about 265 ms for
both passes, and about 60% of that is Node.

`matrix_test`'s top 10 is led by:

| fixture | kind | CPU | beni runs |
|---|---|---:|---:|
| check/bad/LetOfManyBindings | matrix check/bad | 1484 ms | 6 |
| run/AliasChainThroughLet | matrix run | 722 ms | 4 |
| run/ReleaseAliasChain1000 | matrix run | 383 ms | 4 |
| run/NestingLogicalStatements | matrix run | 358 ms | 4 |

After those, every `run/` fixture costs 235–280 ms in the matrix.

**Fixture distribution, single-binary runs:**

| CPU per fixture | corpus_test (994 cases) | matrix_test (718 fixtures) |
|---|---|---|
| under 10 ms | 0 | 0 |
| 10–30 ms | 115 cases, 1.7 s | — |
| 30–100 ms | 617, 33.2 s | — |
| 100–300 ms | 245, 58.7 s | 714, 127.6 s |
| 0.3–1 s | 13, 5.9 s | 3, 1.5 s |
| 1 s or more | 4, 8.5 s | 1, 1.5 s |
| **total** | **108.0 s** | **130.6 s** |

Nothing in the corpus is under 10 ms, because every case starts at least one
`beni`, and every `beni` checks the embedded core.

**By kind, single-binary runs:**

| kind | fixtures | CPU s | mean ms | beni runs | node runs |
|---|---:|---:|---:|---:|---:|
| run (both passes) | 251 | 71.3 | 284 | 502 | 502 |
| check/bad | 267 | 12.5 | 47 | 267 | 0 |
| check/good | 68 | 6.2 | 91 | 142 | 0 |
| fmt | 58 | 5.0 | 86 | 348 | 0 |
| parse/bad | 119 | 4.6 | 39 | 119 | 0 |
| dispatch | 31 | 2.5 | 82 | 62 | 0 |
| check/args | 40 | 1.8 | 45 | 40 | 0 |
| emit | 29 | 1.2 | 42 | 29 | 0 |
| parse/good | 69 | 0.9 | 13 | 69 | 0 |
| check/depth | 14 | 0.7 | 51 | 14 | 0 |
| build/bad | 13 | 0.6 | 44 | 13 | 0 |
| bir | 30 | 0.4 | 13 | 30 | 0 |
| build/bad-release | 4 | 0.3 | 83 | 8 | 0 |
| regress | 1 | 0.0 | 33 | 1 | 0 |

In the matrix:

| matrix kind | CPU s | beni runs |
|---|---:|---:|
| run | 52.2 | 1004 |
| check/bad | 44.6 | 1602 |
| check/good | 9.8 | 544 |
| check/args | 6.8 | 240 |
| emit | 5.5 | 116 |
| dispatch | 5.4 | 248 |
| everything else | 6.3 | — |

## 4. Per tool

### 4.1 Child processes across the whole suite

From `strace -f` over one gates run:

| image | `execve` | threads created | forks |
|---|---:|---:|---:|
| beni | 8 442 | **167 076** (19.8 per process) | 0 |
| node | 724 | 4 344 | 20 |
| test processes (15 binaries, 44 of them `blackbox_test`-family) | 44 | ≈750 | 9 225 (one `fork()` per spawn; std has no `vfork` or `posix_spawn` path) |
| zig | 22 (compile-step cache checks) | – | – |
| build runner | 1 | 31 | 80 |
| shell tools (`sh`, `awk`, `grep`, `cp`, `cat`, `wc`, `tr`, `cmp`, `sort`, …; all from `build_test`'s `bench/churn.sh` scenario) | ≈260 | – | – |
| **total** | **9 527** | | |

**By kind, single-binary runs (loads 13–27):**

| tool | count | user s | sys s | CPU s | CPU ms per run | minor faults per run |
|---|---:|---:|---:|---:|---:|---:|
| node (all) | 716 | 36.5 | 18.8 | **55.3** | 77 | 6.2 k |
| beni build, default `--jobs` | 785 | 18.3 | 17.5 | **35.8** | 46 | 5.8 k |
| beni check, `--jobs=8` | 928 | 15.5 | 17.3 | **32.8** | 35 | 4.1 k |
| beni check, default `--jobs` | 781 | 12.4 | 14.1 | **26.5** | 34 | 4.7 k |
| beni build, `--jobs=8` | 640 | 12.3 | 13.8 | **26.1** | 41 | 4.4 k |
| beni dump, default `--jobs` | 1 441 | 9.5 | 14.6 | **24.0** | 17 | 3.1 k |
| beni check, `--jobs=1` | 1 263 | 12.4 | 9.8 | **22.2** | 18 | 1.5 k |
| beni build, `--jobs=1` | 680 | 11.2 | 8.6 | **19.8** | 29 | 2.1 k |
| beni fmt, default `--jobs` | 279 | 1.1 | 2.4 | 3.5 | 12.5 | 2.5 k |
| beni dump, `--jobs=8` | 692 | 0.4 | 1.1 | 1.5 | 2.2 | 0.3 k |
| beni dump, `--jobs=1` | 702 | 0.3 | 0.9 | 1.2 | 1.6 | 0.2 k |
| beni check, `--jobs=2`/`3`/`4` | 49 | – | – | 0.6 | – | – |
| **all children** | **9 126** | | | **249.8** | | |

Harness self-CPU was 112 s. 84 s of that is the spinner test and 20 s the
matrix harness.

Inside the gates, the same work costs about **1.3–1.8×** as much:

| tool | CPU-s in the gates |
|---|---:|
| node | 149 |
| beni, default `--jobs` | 286 |
| beni, `--jobs=8` | 112 |
| beni, `--jobs=1` | 94 |
| **all children** | **646** (the harness is on top) |

**Node.** A bare `node -e 0` costs 26 ms CPU on a quiet machine. A trivial
emitted program costs 37 ms. So of Node's 55 CPU-s, about **19–31 s is bare
start-up** (716 × the p10 cost of 43 ms). About 11 s is the seven heavy "Deep"
programs, and the rest is module loading and short programs.

**`beni` by `--jobs`.** Quiet machine, `perf stat -r 40`, one-file `run/Adt`
project:

| command | default `--jobs` (32 on this machine) | `--jobs=1` | `--jobs=8` |
|---|---|---|---|
| `check --platform=node --no-cache` | 21.3 ms CPU / 14.3 ms wall / 4 292 faults | **9.3 / 9.8 / 1 216** | 14.7 / 8.8 / 2 313 |
| `build --platform=node --no-cache` | 22.2 / 15.1 / 4 394 | 10.3 / 10.9 / 1 325 | 15.7 / 9.7 / 2 423 |
| `dump --stage=ast` | 8.0 / 8.2 / 2 421 | **1.1 / 1.6 / 303** | 2.6 / 2.9 / 783 |
| `dump --stage=interface` | 21.8 / 14.3 / 4 246 | 8.9 / 9.4 / 1 170 | 14.6 / 8.6 / 2 268 |
| `fmt --stdout` | 7.9 / 8.1 / 2 351 | **0.9 / 1.3 / 233** | 2.4 / 2.7 / 713 |

A default-`--jobs` `check` of a one-file project made 44 `clone`s, 165
`munmap`s and 122 `mmap`s (`strace -c`). At `--jobs=1` it made 2, 97 and 58.
Under load the gap widens: 93 against 32 ms CPU at load 50, with sys time
equal to user time.

### 4.2 Kernel time

- **Sys time is 37–40% of every gates run.** The pristine quiet run was
  259 of 660 CPU-s; the loaded runs were 306–370 of 790–970.
- **Page faults.** A gates run makes **30.2 M minor faults**:

  | source | faults |
  |---|---:|
  | beni, default `--jobs` (3 292 runs, about 4.1 k each) | 13.4 M |
  | beni, explicit `--jobs` (5 118 runs) | 10.3 M |
  | node | 4.4 M |
  | harness | 0.9–1.9 M (copy-on-write after `fork()`) |
  | the rest | unit tests and zig |

  With the default capped to 1 (§6, experiment E1), the default-`--jobs` share
  fell from 13.35 M to 4.17 M.
- **Threads.** 167 k `beni` threads per gates run, each with a 64 MiB stack
  (`Check.stack_size`). That means an `mmap` plus a guard `mprotect` plus a
  `munmap` each, and in a 44-thread process every `munmap` is a TLB shootdown
  across the cores its threads ran on.
- **`fork()` from the harness.**
  - Harness sys time per spawn: **3.5 ms in `matrix_test`**, whose 16 worker
    threads each `fork()` a 16-thread process; 0.9 ms in `corpus_test`
    (8 threads); 0.6 ms in the single-threaded `frontend_test`.
  - The matrix harness spends 13.8 s of sys time single-binary and 18–25 s in
    the gates, most of it on this.
- **Disk.**
  - Under concurrent disk load from the other agents, 215–452 of the 8 412
    `beni` runs per gates run (2.5–5%) **stalled for 1.7–3.7 s** of wall on
    70–130 ms of CPU. They showed 400–900 voluntary context switches against
    8–45 for a normal run.
  - They are mostly cache-writing runs (`--cache-dir` on btrfs, `mkdirat` at
    268 µs per call) in `matrix_test`, `digest_test`, `cutoff_test` and
    `cache_test`.
  - That is 419–697 s of child wall per gates run, spread over the parallel
    steps.
  - With `.zig-cache` on tmpfs the count was **0** in both runs (§6,
    experiment E3).
  - The same stalls explain why `digest_test` (1.1 s alone) and `check_test`
    (0.4 s alone) took 23–34 s and 9–21 s inside the gates.

### 4.3 The Zig toolchain

- **Compile steps.** In a warm gates run all 22 compile steps are cache hits
  of 9–15 ms each, plus the build runner's configure. The pieces are small:
  `fmt-check` is 0.27 s and `zig build install` 0.19 s.
- **The build runner** is 4.6% of the gates' user-mode samples and 16.5% of
  `zig build test`'s. §4.4 explains why.
- **Compile times** after a source change were not measured; they fall
  outside "warm gates" and were not in scope.

### 4.4 The build runner hashes every test binary once per run step

- `perf record -g` on `zig build test` puts the runner's time in
  `Build.Step.Run.make → cacheHitAndWatch → Manifest.hit → hashFile →
  SipHash(1,3)`.
- Each test run step has the test executable in its argv, so the step checks
  the manifest before running the test. That means hashing the whole
  executable: **114 MB for each of the 12 unit shards**, and 15–30 MB for each
  of the 41 black-box run steps.
- The hit never happens, because the tests re-run on every invocation. The
  hash is pure overhead.
- **Experiment E4:** setting `has_side_effects = true` on those run steps,
  which skips the check, took `zig build test` from 27.6–29.7 to
  24.0–25.9 user-s. The runner's share of user samples fell from 16.5% to
  3.9%, and wall stayed the same (5.3 s).
- The gates-level saving is estimated at 10–20 CPU-s. It could not be
  resolved against the run-to-run drift.

### 4.5 Harness overhead

- **Totals.** Test-process self-CPU single-binary is 112 CPU-s. Take away the
  spinner test (84) and **28 CPU-s** remain, 7% of the suite:

  | binary | harness CPU | split |
  |---|---:|---|
  | `matrix_test` | 20.2 s | 6.4 user + 13.8 sys |
  | `corpus_test` | 2.8 s | — |
  | `frontend_test` | 0.6 s | — |
  | everything else | under 0.6 s each | — |

- **Where the user time goes** (a `perf` profile of the `matrix_test` and
  `corpus_test` harnesses):
  - The largest single item is **DWARF stack unwinding**
    (`debug.Dwarf.SelfUnwinder.*`, `SelfInfo.Elf.unwindFrame`, 20–35% of
    harness user samples). The test binaries are Debug, so
    `std.testing.allocator` records a 6-frame stack trace on every allocation
    and free (`DebugAllocator` `stack_trace_frames`), and a `World`'s arena
    and every spawn's environment map allocate through it.
  - Next come directory walking and sorting in `listFiles` and
    `expectSameTree` (`Io.Dir.Reader.read`, `sort.pdq`, `math.order`), then
    environment-block building for each spawn (`Environ.Map.putPosixBlock`,
    `Environ.scan`), then wyhash.
  - JSON parsing of diagnostics does not appear in the top 25.
- **Sys time** in the harness is dominated by `fork()` from multi-threaded
  processes (§4.2) and by temporary-directory creation and deletion.
- **Per fixture**, the corpus harness costs 1–12 ms. The matrix harness costs
  9–81 ms, most of it `fork` plus tree comparison.

## 5. Redundancy

### 5.1 A coverage hole: the matrix's dumps are all usage errors

`matrix_test.streamMatrix` runs `dump --stage=raw` (every fixture),
`--stage=interface` (`check/good`) and `--stage=dispatch` (`dispatch/`) with
variant 0's flags (`--jobs=1 --no-cache`) and variant 1's (`--jobs=8
--no-cache --roundtrip-*`). **`dump` does not accept `--no-cache`**, as
`corpus_test.zig`'s own comment says. All **1 040** dump runs per gates run
exit 2 with `beni: unknown option '--no-cache'`, identically in both variants,
so the comparison passes.

The claim in the comment, "`--stage=raw` is the one that can see a byte
difference the two pretty printers hide … which is why it is here for every
kind", is currently unmet. The same goes for the `interface` and `dispatch`
halves of the round-trip claim.

Fixing it is a coverage gain, at about 2.5 CPU-s single-binary, since a dump
is 1–9 ms. It needs a red-first fixture per `CLAUDE.md` rule 3. For example:
assert in `streamMatrix` that variant 0's exit code is not 2, which fails
today.

### 5.2 The same `beni` command on the same inputs

For commands on repository paths, where argv identifies the input exactly:

- **Exact duplicates.** 154 runs, 1.8 CPU-s single-binary: `corpus: parse/good`
  runs `dump --stage=ast` on the same 69 fixtures (plus the `bir/` ones) as
  `frontend_test`'s identity oracle, which runs it again untransformed. Two
  more are in `blackbox_test`.
- **The same command apart from `--jobs`, `--no-cache`, `--roundtrip-*` and
  cache flags:** 2 707 extra runs, 55.8 CPU-s single-binary.

  | overlap | extra runs | CPU-s |
  |---|---:|---:|
  | matrix and corpus | 1 486 | 42.0 |
  | within the matrix | 718 | 8.2 |
  | frontend and corpus | 308 | 3.5 |
  | within frontend | 192 | 2.1 |

  Most of this is deliberate: the variants *are* the test. The part that is
  not is §5.3.

### 5.3 `matrix_test` against `corpus_test`

Every fixture of every checker-driven kind runs in both binaries.

**Matrix cost by variant, single-binary:**

| variant | flags | runs | CPU s | check / build ms per run |
|---|---|---:|---:|---|
| 0, cold | `--jobs=1 --no-cache` | 1 238 | 15.0 | 17.4 / 23.6 |
| 1, round-tripped | `--jobs=8 --roundtrip-*` | 1 238 | 25.7 | 31.7 / 39.2 |
| 2, cache cold | `--jobs=1 --cache-dir` | 718 | 21.3 | 26.1 / 34.7 |
| 3, cache warm | `--jobs=8 --cache-dir` | 718 | 29.8 | 38.8 / 45.5 |

The dump runs in variants 0 and 1 are the 1 040 usage errors of §5.1.

- **Variant 0 duplicates corpus work.** It is the same command and inputs as
  the corpus walker's run, differing only in `--jobs` (1 against the
  default). Its role is to be the byte baseline.
- **Two product observations from the same numbers:**
  - For these small fixtures, **a warm cache run costs more CPU than a cold
    uncached one**: 38.8 against 17.4 ms per `check`; 5.8 k faults against
    1.3 k.
  - **Writing the cache adds 50%**: 26.1 against 17.4 ms. On btrfs under load
    the write also stalls for seconds (§4.2).
  - Both belong to the `fast-compiler.md` budget discussion rather than to the
    tests.

### 5.4 Duplicate coverage between corpus kinds and black-box tests

- **Two passes of `run/`.**
  - The release pass (35 CPU-s single-binary) is the half of the corpus the
    matrix deliberately skips ("would quadruple the most expensive kind").
  - It is the only release-build behavioural check for 251 programs; keep it.
  - The seven "Deep" programs pay about 5 s of Node in each pass.
- **The `fmt/` kind** runs 6 `beni` per fixture: fmt twice, `dump ast` twice
  and `dump tokens` twice.
- **`frontend_test`'s `fmt --stdout` oracle** re-runs `fmt` on the same 58
  fixtures 2 × (plain + round-trip), 116 runs.
- **`check/good` and `dispatch/`** run `check` and then a `dump` that re-checks
  from scratch. That is 2 runs where one could do if `check` could emit the
  dump, a compiler change worth about 2.5 CPU-s. Not recommended for time
  alone.
- **`ordering_test`** (13 CPU-s single-binary, 322 builds + 87 Node runs)
  builds its own regression programs in fixed declaration orders. There is no
  overlap with `corpus/run/` beyond using the same pipeline.
- **`abuse_test` and `abuse_wide_test`** build and run most of their programs
  "in both builds". Their giants (65 535 fields, 4 095-deep nests) are single
  runs of 1–6 s each and have no corpus twin.

### 5.5 What determinism costs

| test | CPU (single-binary) | share |
|---|---:|---:|
| "every stream of every command is byte-identical across --jobs=1 and --jobs=8, twice each" (the `CLAUDE.md` determinism test; 492 runs) | 1.3 s | **0.3%** |
| "600 modules check identically at one worker and at eight, twice each" | 1.6 s in the gates | — |
| the spinner, "diagnostics do not depend on which worker lexed which file, under load" | 85 s | 21% |
| `matrix_test` (the `--jobs` × round-trip × cache cross) | 131 s | 32% |
| `ordering_test` (I9) | 13 s | 3% |
| **determinism and order properties in total** | **about 230 of about 400 CPU-s** | **57%** |

The black-box totals behind the shares above:

| | CPU (single-binary) | share |
|---|---:|---:|
| everything else in the black-box suite | about 170 CPU-s | — |
| of which the corpus | about 108 | — |
| of which `run/` | 71 | — |

## 6. Recommendations, ranked by CPU saved

Savings are single-binary CPU-s unless marked. In the gates, multiply by about
2 for CPU; wall time drops by roughly the CPU fraction, because the machine is
saturated. The two experiments run through the whole gates are E1 and E2:

| run pair (same series) | base | E1 + E2 (default `--jobs=1`, spinner skipped) |
|---|---|---|
| 1 | 845 CPU-s / 33.2 s | **612 CPU-s / 29.7 s** |
| 2 | 972 CPU-s / 39.3 s | **635 CPU-s / 31.9 s** |

E2 alone: 882 against 972 CPU-s, and 37.5 against 39.3 s.

1. **Stop over-provisioning `beni`'s threads** (compiler change). **About
   −54 CPU-s single-binary (−15% of the suite, −60% of the default-`--jobs`
   runs); −150 to −230 CPU-s in the gates.**
   - **The waste.** `Session` allocates `--jobs` = 32 workers and spawns all
     of them, each with an arena, a pre-seeded interner and a 64 MiB stack,
     whatever the file count. The checker's `Driver` adds more.
   - **E1 measured it.** Capping the default to 1 (in the worktree's
     `main.zig`) moved:

     | measure | before | after |
     |---|---:|---:|
     | default-`--jobs` runs, single-binary | 89.8 CPU-s | 35.4 CPU-s |
     | whole black-box suite | 364 CPU-s | 272 CPU-s (spinner noise included) |
     | gates | 935–960 CPU-s | 780–865 CPU-s |

   - **The realistic fix** is to spawn no more workers than there are files
     to lex (about 11 core modules plus the project) and no more checker
     threads than the schedule's width; spawning lazily would also work. The
     one-file project then drops from 21 to about 10 ms CPU and from 14 to
     about 10 ms wall, which also serves `fast-compiler.md`'s cold-start
     budget.
   - **Coverage cost: none.** Output is independent of `--jobs` by
     guarantee, and the explicit `--jobs=1`/`8` crosses stay.
   - Note: the main checkout has uncommitted edits to `src/Session.zig` and
     `src/check/Driver.zig`, possibly in this area.
2. **Move the "under load" spinner test out of the gates, or cheapen it.**
   **About −85 CPU-s single-binary (21% of the black-box suite); −70 to −90
   CPU-s and about −2 s wall in the gates (E2).**
   - For its 3–5 s it spins one thread per CPU, so in the gates it also
     starves every concurrent step.
   - Its own comment names the deterministic half, `Session.zig`'s
     `mergeInterners` test with the files handed out backwards. Keep that in
     `test`.
   - Put the probabilistic spinner in an opt-in step, `test-stress`, next to
     `test-pending`.
   - **Coverage cost:** the gates lose the scheduler-dependent chance of
     catching a worker-order race; the deterministic test stays.
   - A cheaper middle ground: run the 36 `beni` runs pinned to 2 CPUs with
     2–4 spinners. A saturated machine is what gives the scheduler a choice,
     and pinning buys that without 32 spinners. The p≈0.2 flip rate would
     need re-measuring.
3. **Fix `matrix_test` and fold its baseline into the corpus walker.**
   **−15 CPU-s (1 238 runs), plus −10 to −14 CPU-s of harness `fork` cost.**
   - First fix §5.1, a coverage gain.
   - Then use the corpus walker's own golden-checked run as variant 0, so the
     matrix runs only variants 1–3 per fixture. The `--jobs=1` point moves to
     the cache-cold variant, which already runs at `--jobs=1`.
   - Merged into the walker's 8 workers (or with 16 matrix workers spawning
     through a single-threaded spawner), the 3.5 ms-per-spawn `fork` tax of
     the 16-thread harness mostly goes.
   - **Coverage cost:** the baseline becomes default `--jobs` rather than
     `--jobs=1`. Every claim is still crossed against both `--jobs=1` and
     `--jobs=8`.
4. **Put the harness's temporary directories on tmpfs.** **CPU: small. Wall:
   removes 215–452 stalled runs (1.7–3.7 s each) per gates run under disk
   contention.**
   - `std.testing.tmpDir` hard-codes `.zig-cache/tmp`, and a symlink there
     breaks `zig build` (`error: CrossDevice`; the build runner renames from
     it). So `World` needs its own temporary root, such as `$XDG_RUNTIME_DIR`
     or `/tmp`, with the same cleanup.
   - **Coverage cost:** the tests stop exercising btrfs, which nothing claims
     to test. The permission scenarios work on tmpfs.
5. **Shrink the seven "Deep" `run/` programs.** **About −8 CPU-s (10 s of
   Node).**
   - Their claim is that the emitted loop or `foldl` does not overflow the
     stack.
   - Run them under a smaller V8 stack, e.g. `node --stack-size=…` passed by
     the walker for `run/` only, or through a per-fixture flag file. The same
     claim then needs a far smaller n.
   - **Coverage cost:** none if n still exceeds the recursion depth the
     smaller stack allows, which a fixture can assert by also carrying a
     recursive twin that must overflow.
6. **Set `has_side_effects = true` on every test run step** in `build.zig`
   (`addRunArtifact` of the unit shards and `Blackbox.run`). **About −4 CPU-s
   in `zig build test`; an estimated −10 to −20 CPU-s in the gates (§4.4).**
   Coverage cost: none, since the steps never hit the cache.
7. **Stop DWARF unwinding in the harness.** **About −3 to −5 CPU-s.**
   - Back `World`'s arena and the per-spawn environment map with
     `std.heap.page_allocator` instead of `std.testing.allocator`, keeping
     the testing allocator for leak checks of what outlives a test.
   - Alternatively, build the black-box roots `ReleaseSafe`. They are
     harnesses, not the product, but that costs compile time after harness
     edits.
   - Coverage cost: leak reports lose stack traces for arena chunks.
8. **Spawn with `vfork` or `posix_spawn` semantics instead of `fork()`.**
   **About −10 to −15 CPU-s harness sys single-binary, more in the gates.**
   - Zig 0.16's `std.process.spawn` always uses `fork()`. A
     `clone(CLONE_VM|CLONE_VFORK)` spawn in `world.zig` would drop the
     copy-on-write page-table copy and its faults, about 1.9 M faults per
     gates run.
   - It is a harness-only change, but a delicate one. Recommendation 3 gets
     most of it more cheaply.
9. **Rebalance the long poles (wall only).** In the quiet run the gates took
   26 s and several single steps took 14–16 s, so these matter once the CPU
   items land:
   - **The three 13–15 s unit shards.** Each holds one of `iface_bytes` fuzz
     (6.2 s alone), `Instantiate`'s 100 000-level walk (3.9 s) and
     `dispatch_bytes` fuzz (4.7 s). Split them into seed-range or size-range
     tests so that the sharding can spread them.
   - **The compare generator's unit tests.** Give them `testRunner` and two
     shards (14–18 s in the gates, single process).
   - **`abuse_wide_test` shard 1 (16 s).** Its 65 535-field test is 5.7 s
     alone.
   - **`test-perf`**'s wall is two 9-second scenarios in series. Start the
     serial `wall` shard's slowest scenario first, or move "a chain of ever
     deeper bindings…" (9 s, 3.2 GB RSS) into the `wall` set if its judgment
     allows.
10. **Remove exact duplicates.** `frontend_test`'s identity oracle and
    `corpus: parse/good` both run `dump --stage=ast` untransformed on the
    same files (154 runs, 1.8 CPU-s). The oracle could compare its round-trip
    dumps against the `.ast` golden instead. Low value.

**Not recommended.**

- **Dropping `run/`'s release pass (35 CPU-s).** It is the only behavioural
  check of `--release` for 251 programs.
- **Dropping Node start-up (about 25 CPU-s).** A shared Node process
  importing many programs would break per-program isolation of globals and
  stdout, which the goldens rely on.

## 7. Reproducing

The measurements above were taken with throwaway instrumentation, since
deleted. The recording is now part of the harness, and one command
regenerates §8:

```sh
zig build test-time-report                      # times `zig build gates`
zig build test-time-report -Dtime-step=test-blackbox -Dquick
zig build test-time-report -- --out=- --top=20  # print instead of writing here
```

- **Recording.** `BENI_TEST_TIMING=<dir>` makes every test process write
  `<dir>/<binary>-<pid>.jsonl` (`tests/timing.zig`): each test's wall time
  and its own and its children's CPU (`tests/test_runner.zig`), each corpus
  case's wall time and worker-thread CPU (`corpus_test.zig`), and each
  process `world.zig` spawns, with its arguments, wall time, user, sys, max
  RSS and minor faults from `wait4`. Unset, nothing is recorded.
- **The run.** `tests/time_report.zig` measures the CPU model, the load
  average before and after, and a bare `node -e 0`. It runs the step in a
  child `zig build` with the variable set, and takes that build's own wall
  and CPU time (its whole process tree) from `wait4`. The records stay in
  `zig-out/test-timing/`; `time-report render --records=<dir>` renders them
  again.
- **What it does not replace.** These were one-off investigations and are
  not regenerated: the `strace` counts of §4.1, the `perf` profiles of §2.1
  and §4.5, the `perf stat` micro-benchmarks of §4.1 and the experiments of
  §6. For a single-binary run, time one file with
  `-Dtime-step=test-blackbox-<file>`.

## 8. After the fixes

Applied on 2026-09-28, each as its own commit, then measured with
`zig build test-time-report` against a copy of `master` from before them,
the two run alternately so that each pair saw about the same load.

### 8.1 What changed

| item | what was done | why that way |
|---|---|---|
| `matrix_test` (§5.1, §5.3, recommendation 3) | **Deleted**, by the owner's decision: "one or a few hand-picked tests that reach the branches we want, no matrix". Its dumps were never repaired. | Every claim it made has a hand-picked test. Already covered: a warm build byte-identical to a cold one, with a generic, a derived `eq`/`compare` and a type crossing modules (`cache_test` *a warm build emits byte-identical JavaScript, and it runs*); a cache written at `--jobs=1` and read at `--jobs=8`, and the reverse (the same test, and *a cache written in one configuration and read in another*); the cold run hits nothing and the warm run checks, lexes and derives nothing (*a cold run with --cache-dir writes entries…*, *a warm run lexes, parses and lowers NOTHING…*, *a cache hit installs the published derived contexts and runs no fixpoint*); a refused build's diagnostics at both `--jobs` (`build_test` *the debug_in_release site list does not depend on thread count or argument order*). New, in `iface_test`: a build through all three `--roundtrip-*` flags whose evidence crosses modules, byte-compared and run, and an importer's type error that prints types read back from the record. |
| the spinner test (recommendation 2) | **Deleted**, by the owner's decision, not trimmed. | It no longer reached its branch: a record mismatch names the failing field by text, so its message cannot move with interner ids. The deterministic coverage is `Session.zig`'s `mergeInterners` unit test, which hands the files to the workers backwards. It was checked to fail with the merge done in worker order and in reverse file order. |
| `beni`'s thread pools (recommendation 1) | With no `--jobs`, the CPU count is a ceiling: one per-file worker per 256 KiB of source (embedded files by length, files on disk by `stat`, stopping once the ceiling is reached), and one checker thread per 16 Ki tokens. An explicit `--jobs` is honoured as before. | The determinism tests pass explicit `--jobs=1`/`8` and still cross real parallel runs. The worker stacks stay at 64 MiB: only the pages a thread touches are mapped, and the deep-tree limits are measured against that size. |
| tmpfs (recommendation 4) | A `World` lives under `/dev/shm/beni-test-<uid>` when that exists, else in `.zig-cache/tmp` as before. | `/dev/shm` is 16 GB here, `$XDG_RUNTIME_DIR` 3.2 GB. It also keeps a leftover tree out of the worktree. |
| the "Deep" `run/` programs (recommendation 5) | `ListMapNDeep`, `ListMapFilterDeep`, `ListFoldDeep` and `SortByKeyOnce` now use 20 000 cells, `DerivedDeepPaths` 25 000 levels; the goldens were re-blessed. No Node flag. | Measured: a non-tail recursive `map` overflows Node 24's default stack between 7 000 and 8 000 cells, and `backend.md` records the recursive derived comparison throwing at 8 940. The new sizes are 2.5–3 times past both; the old ones were 12–125 times past. |
| `has_side_effects` (recommendation 6) | Every test run step sets it. | `zig build test`: 42 → 30 CPU-s, 6.0 → 5.1 s wall (three runs against three, load 3–5). |
| long shards (recommendation 9) | The interface-record and dispatch-sidecar fuzz tests are each split into three tests (the systematic mutations, and two halves of the random writes with their own seeds); the compare generator's unit tests run in two shards; `abuse_wide_test` in five. | Run alone, the two sweeps were 4.1 and 3.1 s as single tests; split, no part is over 2 s. In the gates, the unit step's wall stayed inside the load noise (10.8 and 26.3 s before, 18.8 and 15.0 s after, in the paired runs of §8.4). |
| the exact-duplicate dump (recommendation 10) | Not done. | 1.8 CPU-s, and removing it means rebuilding `frontend_test`'s identity oracle on the goldens. That oracle is itself a sweep over the corpus, so the owner's rule would replace it with hand-picked cases instead. That is a separate decision. |
| the unit binary's stack overflow (§3.2) | `tests/test_runner.zig` runs every test on a 256 MiB thread. | Reproduced at `ulimit -s 8192` (abort in the formatter's deep-nesting test), and gone after: 484 passed by hand. |

Not done: recommendations 7 (DWARF unwinding in the harness) and 8
(`vfork`). With the matrix gone, the harness's own CPU is a few CPU-s.

### 8.2 The warm cache

At equal `--jobs`, a warm run is **cheaper** than a cold one, and the
report's 38.8 against 17.4 ms compared a warm run at `--jobs=8` with a cold
one at `--jobs=1`. It also ran under load, with the cache on btrfs. A
one-file project (`run/Adt`), 40 runs each, cache on tmpfs, load 2, after
the pool sizing:

| run | CPU ms | wall ms |
|---|---:|---:|
| `--no-cache`, `--jobs=1` | 8.2 | 8.5 |
| cold, writing the cache, `--jobs=1` | 10.3 | 10.3 |
| warm, `--jobs=1` | 3.2 | 3.2 |
| warm, `--jobs=8` | 6.5 | 4.8 |
| warm, default `--jobs` | 3.2 | 3.5 |

The cold-with-cache figures have the loop's `rm -rf` of the cache taken
off. Writing the cache costs about 2 ms on a 9 ms run: `cache_store`
0.76 ms and `frontend_store` 0.68 ms in the profile, 23 files and 312 KB
for one app module plus core and the platform. That is a real cost for a
cold build of a tiny project. Making it cheaper means fewer files per
entry, which is a cache-format change and not a quick fix, so it is left
as a finding. The warm `--jobs=8` run is the per-file pool that an explicit
`--jobs` still spawns with nothing to lex.

### 8.3 `beni`, one file, before and after the pool sizing

`run/Adt` as one file, 40 runs each, ReleaseSafe, load under 7:

| command | before: CPU / wall ms | after: CPU / wall ms |
|---|---|---|
| `check --platform=node --no-cache` | 15.3 / 9.2 | **9.0 / 9.2** |
| `build --platform=node --no-cache` | 16.0 / 10.0 | **9.8 / 10.0** |
| `dump --stage=interface` | 14.3 / 8.5 | **8.8 / 9.0** |
| `dump --stage=ast`, `fmt --stdout` | 1.5 / 1.5 | 1.5 / 1.5 |
| `check`, warm cache | 8.5 / 6.5 | **4.0 / 4.2** |
| threads created by one `check` | 21 | **2** |

The dump and fmt of one file already ran on one worker. The explicit
`--jobs=8` rows did not move, and a default run lost about 1 ms of wall
against `--jobs=8` on this one-file project (9.2 against 8.0 ms). That is
the price of 40% less CPU.

### 8.4 The gates

`zig build test-time-report` (a warm `gates`), before and after run one
after the other, three pairs. The machine was shared, and each row gives
the 1-minute load average at the start and end of the run.

| pair | before: load | before: wall s | before: CPU-s (all / in tests) | after: load | after: wall s | after: CPU-s (all / in tests) |
|---|---|---:|---:|---|---:|---:|
| 1 | 10.8 → 29.4 | 22.5 | 580.9 / 551.1 | 27.4 → 31.5 | 19.0 | **434.7 / 354.1** |
| 2 | 31.5 → 54.2 | 31.1 | 858.3 / 730.9 | 50.0 → 45.0 | 25.2 | **496.4 / 397.0** |
| 3 | 6.7 → 18.4 | 17.8 | 493.2 / 424.4 | 18.4 → 21.3 | 17.9 | **338.5 / 274.5** |

And alone on a quiet machine (load 7.5 → 9.2), after: **13.5 s wall,
203.7 CPU-s**, 202.6 of them in test processes. The last generated run on
`master` before these changes, at load 9.7 → 25.5, was 31.4 s and 726.0
CPU-s.

- **CPU in test processes fell by 35–46%** in every pair, and by about 150
  to 330 CPU-s. The black-box suite spawns 4 470 `beni` processes instead of
  8 412.
- **Wall fell in two pairs of three** (−16%, −19%), and was the same in the
  third, whose "after" run started at more than twice the load.
- About 65–130 CPU-s of each loaded run is outside the test processes
  (the build runner and its children). On the quiet run it was 1.1 CPU-s,
  so that share is contention and not work these changes could remove.

Where the rest goes now (the quiet run): the unit tests 34 CPU-s, the two
`run/` passes 56 (a build and a Node run per program in each), and every
other black-box binary under 15.

## 9. The latest generated run

Everything between the markers is generated; the analysis in §0–§7 is not,
and compares against runs from before the fixes it recommends. §8 compares
against runs after them.

<!-- test-time-report:begin -->
<!-- Generated by `zig build test-time-report`; edits between the markers are overwritten. -->

### The run

- Command: `zig build gates`, exit 0.
- Started: 2026-09-28 14:49 UTC.
- Machine: AMD Ryzen 9 5950X 16-Core Processor, 32 hardware threads.
- Load average (1, 5, 15 min): 5.23 3.21 4.96 at the start, 7.72 3.91 5.16 at the end.
- Whole run: 14.4 s wall, 198.4 CPU-s (134.0 user + 64.4 sys).
- In test processes: 197.1 CPU-s over 63 processes; outside them (the build runner, compiles, `zig fmt`): 1.3 CPU-s.

CPU time (user + sys, from `getrusage` and `wait4`) is the stable metric.
Under load, wall time stretches with whatever else the machine runs while
CPU time barely moves, so compare wall times only between runs at a
similar load.

### Per step

One row per test binary and part; the shards of a binary are summed. Wall
is its longest process. "Harness" is the test process itself, "children"
every process it reaped.

| step | processes | tests | wall s | harness user s | harness sys s | children CPU s | **total CPU s** | harness max RSS MiB | child max RSS MiB | beni | node |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| unit_test | 12 | 488 | 9.3 | 31.7 | 7.5 | 0.0 | **39.2** | 171 | 0 | 0 | 0 |
| abuse_test | 6 | 39 | 5.3 | 0.9 | 0.7 | 18.4 | **20.1** | 118 | 417 | 101 | 15 |
| cache_test | 4 | 57 | 6.5 | 1.0 | 0.6 | 16.7 | **18.3** | 21 | 70 | 400 | 51 |
| abuse_wide_test | 5 | 10 | 7.1 | 0.6 | 0.2 | 16.9 | **17.6** | 23 | 377 | 29 | 21 |
| ordering_test | 4 | 8 | 4.4 | 0.2 | 0.3 | 15.6 | **16.1** | 23 | 56 | 322 | 87 |
| corpus_test part check | 1 | 14 | 2.9 | 0.4 | 0.5 | 13.0 | **13.8** | 20 | 14 | 525 | 0 |
| blackbox_test | 6 | 117 | 3.2 | 0.8 | 0.7 | 7.9 | **9.4** | 23 | 58 | 742 | 14 |
| compare_gen_unit_test | 2 | 18 | 7.3 | 8.8 | 0.3 | 0.0 | **9.1** | 43 | 0 | 0 | 0 |
| corpus_test part run_release | 1 | 14 | 2.2 | 0.5 | 0.5 | 7.7 | **8.7** | 21 | 21 | 251 | 1 |
| corpus_test part run_dev | 1 | 14 | 2.2 | 0.5 | 0.5 | 7.7 | **8.7** | 21 | 22 | 251 | 1 |
| cutoff_test | 4 | 4 | 2.7 | 0.4 | 0.3 | 6.3 | **7.0** | 21 | 8 | 285 | 0 |
| build_test | 3 | 57 | 3.2 | 0.3 | 0.2 | 6.1 | **6.6** | 21 | 67 | 79 | 25 |
| corpus_test part parse | 1 | 14 | 2.0 | 0.4 | 0.5 | 5.3 | **6.2** | 21 | 79 | 567 | 0 |
| frontend_test | 1 | 4 | 1.2 | 0.2 | 0.8 | 3.7 | **4.7** | 23 | 10 | 715 | 0 |
| run_hash_test | 1 | 5 | 3.2 | 0.0 | 0.0 | 2.5 | **2.6** | 20 | 55 | 0 | 2 |
| digest_test | 3 | 20 | 2.3 | 0.2 | 0.2 | 1.8 | **2.1** | 21 | 8 | 85 | 0 |
| time_report_test | 1 | 1 | 1.3 | 0.0 | 0.0 | 1.8 | **1.9** | 22 | 56 | 0 | 0 |
| corpus_test part build | 1 | 14 | 0.8 | 0.2 | 0.1 | 1.3 | **1.7** | 21 | 8 | 50 | 0 |
| iface_test | 1 | 10 | 1.3 | 0.1 | 0.1 | 1.1 | **1.2** | 22 | 55 | 44 | 1 |
| bench_gen_test | 1 | 11 | 0.8 | 0.7 | 0.0 | 0.0 | **0.8** | 16 | 0 | 0 | 0 |
| compare_gen_test | 1 | 2 | 0.7 | 0.4 | 0.0 | 0.1 | **0.6** | 20 | 10 | 2 | 0 |
| check_test | 1 | 9 | 0.6 | 0.1 | 0.0 | 0.4 | **0.5** | 23 | 6 | 21 | 0 |
| docs_test | 1 | 1 | 0.4 | 0.1 | 0.0 | 0.2 | **0.4** | 22 | 58 | 1 | 1 |
| diagnostic_test | 1 | 4 | 0.0 | 0.0 | 0.0 | 0.0 | **0.0** | 17 | 0 | 0 | 0 |
| **all** | 63 | 935 | 9.3 | 48.5 | 14.0 | 134.5 | **197.1** | | | 4470 | 219 |

### Per test

The 40 most expensive of 879 tests by CPU. "Harness" is CPU in the test
process, "children" in what it spawned.

| # | test | wall s | harness CPU s | children CPU s | **total CPU s** | beni | node |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | corpus_test · corpus: run | 2.1 | 1.7 | 15.4 | **17.2** | 502 | 2 |
| 2 | corpus_test · corpus: check/bad | 1.2 | 0.4 | 6.8 | **7.2** | 267 | 0 |
| 3 | gen · the oracle accepts every family at sizes 1-4 over 16 seeds | 7.2 | 7.0 | 0.0 | **7.0** | 0 | 0 |
| 4 | abuse_wide_test · derived eq and compare over a 65 535-field nominal payload build and run, in both builds | 6.3 | 0.2 | 6.1 | **6.2** | 2 | 2 |
| 5 | ordering_test · every order-dependence regression program does what its twin says in a fixed set of orders, first quarter | 4.4 | 0.1 | 4.2 | **4.3** | 82 | 27 |
| 6 | abuse_wide_test · a derived row of more than 65 535 context entries checks, and builds and runs | 4.5 | 0.0 | 4.2 | **4.3** | 2 | 1 |
| 7 | ordering_test · every order-dependence regression program does what its twin says in a fixed set of orders, second quarter | 4.3 | 0.1 | 4.2 | **4.2** | 80 | 26 |
| 8 | ordering_test · every order-dependence regression program does what its twin says in a fixed set of orders, third quarter | 4.2 | 0.1 | 4.0 | **4.1** | 81 | 23 |
| 9 | corpus_test · corpus: check/good | 1.0 | 0.2 | 3.8 | **4.0** | 142 | 0 |
| 10 | cache.dispatch_bytes · fuzz: a sidecar with random bytes overwritten never reads back as an unverified one, second seed | 4.1 | 3.8 | 0.0 | **3.8** | 0 | 0 |
| 11 | check.Instantiate · copy keeps sharing, shares what is not generalised, and walks 100 000 levels | 3.9 | 3.8 | 0.0 | **3.8** | 0 | 0 |
| 12 | frontend_test · the identity oracle: every bir and parse/good fixture dumps the same three ways | 0.8 | 0.7 | 3.0 | **3.7** | 576 | 0 |
| 13 | cache_test · a warm rebuild after each edit of a dependency, and after reverting it, is a cold build | 3.5 | 0.3 | 3.3 | **3.5** | 48 | 20 |
| 14 | cache_test · an imported type of 4 097 parameters compares across modules in the wide form, cold, warm and partly warm, in both builds | 3.5 | 0.1 | 3.4 | **3.5** | 8 | 8 |
| 15 | corpus_test · corpus: parse/bad | 0.9 | 0.2 | 3.2 | **3.4** | 119 | 0 |
| 16 | resolve.iface_bytes · fuzz: a record with random bytes overwritten never reads back as an unverified one, second seed | 3.4 | 3.3 | 0.0 | **3.3** | 0 | 0 |
| 17 | ordering_test · every order-dependence regression program does what its twin says in a fixed set of orders, fourth quarter | 3.2 | 0.1 | 3.0 | **3.1** | 72 | 11 |
| 18 | abuse_test · a record literal nested to the parser's limit compares and RUNS, release build | 3.1 | 0.0 | 3.0 | **3.1** | 1 | 1 |
| 19 | abuse_test · a recursive type of 4 097 parameters compares past the derived depth limit, wide | 3.0 | 0.0 | 3.0 | **3.0** | 1 | 1 |
| 20 | fmt.Format · deep nesting and very long chains format without exhausting the stack | 2.9 | 2.9 | 0.0 | **2.9** | 0 | 0 |
| 21 | abuse_test · a chain of forwarders as deep as the parser allows compares and runs: `Just` nested 4 095 deep | 2.7 | 0.0 | 2.6 | **2.7** | 2 | 2 |
| 22 | lex.Tokenizer · stress: random mixes of valid pieces, steering bytes and noise never panic | 2.4 | 2.4 | 0.0 | **2.4** | 0 | 0 |
| 23 | cache_test · an edit that moves a dependency's derived context rebuilds its dependents' evidence exactly as a cold build | 2.4 | 0.2 | 2.1 | **2.3** | 36 | 10 |
| 24 | parse.Parse · stress: token soup and grammar fragments never panic and always yield a well-formed tree | 2.4 | 2.3 | 0.0 | **2.3** | 0 | 0 |
| 25 | abuse_test · a record literal nested to the parser's limit compares and RUNS, development build | 2.3 | 0.0 | 2.3 | **2.3** | 1 | 1 |
| 26 | resolve.iface_bytes · fuzz: a record with random bytes overwritten never reads back as an unverified one, first seed | 2.2 | 2.2 | 0.0 | **2.2** | 0 | 0 |
| 27 | abuse_wide_test · a nominal payload of 65 537 fields checks, and builds and runs or is refused by name | 2.6 | 0.1 | 2.1 | **2.2** | 1 | 1 |
| 28 | corpus_test · corpus: fmt | 0.6 | 0.4 | 1.6 | **2.1** | 348 | 0 |
| 29 | cache.dispatch_bytes · fuzz: a sidecar with random bytes overwritten never reads back as an unverified one, first seed | 2.1 | 2.1 | 0.0 | **2.1** | 0 | 0 |
| 30 | blackbox_test · every stream of every command is byte-identical across --jobs=1 and --jobs=8, twice each | 2.1 | 0.4 | 1.6 | **2.0** | 492 | 0 |
| 31 | gen · the same seed gives the same program, and size k is a prefix of 2k | 2.0 | 1.9 | 0.0 | **1.9** | 0 | 0 |
| 32 | time_report_test · the time report of one corpus fixture has every table and names the fixture | 1.3 | 0.0 | 1.8 | **1.9** | 0 | 0 |
| 33 | cutoff_test · the differential harness: every edit class, byte-identical AND cut off exactly, second quarter | 2.7 | 0.2 | 1.7 | **1.8** | 75 | 0 |
| 34 | cutoff_test · the differential harness: every edit class, byte-identical AND cut off exactly, third quarter | 2.7 | 0.2 | 1.6 | **1.8** | 75 | 0 |
| 35 | abuse_wide_test · == on a record builds and runs at the widest positional evidence and at a width that threw, never a runtime exception | 2.2 | 0.1 | 1.7 | **1.8** | 2 | 2 |
| 36 | cutoff_test · the differential harness: every edit class, byte-identical AND cut off exactly, first quarter | 2.6 | 0.2 | 1.6 | **1.8** | 75 | 0 |
| 37 | render.text · excerpts for many diagnostics in one file are found by resuming, not rescanning | 1.7 | 1.7 | 0.0 | **1.7** | 0 | 0 |
| 38 | js.Print · a chain 200 000 links deep prints in a loop, not a stack frame per link | 1.6 | 1.6 | 0.0 | **1.6** | 0 | 0 |
| 39 | cutoff_test · the differential harness: every edit class, byte-identical AND cut off exactly, fourth quarter | 2.5 | 0.1 | 1.3 | **1.5** | 60 | 0 |
| 40 | bir.Lower · stress: mutated corpus fixtures never panic and always lower in bounds | 1.5 | 1.5 | 0.0 | **1.5** | 0 | 0 |

**Distribution of tests by CPU:**

| CPU per test | tests | total CPU s |
|---|---:|---:|
| under 10 ms | 440 | 0.7 |
| 10 ms – 0.1 s | 258 | 11.5 |
| 0.1 s – 1 s | 138 | 43.7 |
| 1 s – 10 s | 42 | 121.4 |
| 10 s or more | 1 | 17.2 |

### Per fixture

The 40 most expensive of 1245 corpus cases by CPU: the walker thread's own
time plus every process the case spawned.

| # | fixture | kind | **CPU ms** | wall ms | harness ms | beni runs / CPU ms | node runs / CPU ms |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | tests/corpus/check/bad/LetOfManyBindings.beni | check_bad | **361** | 400 | 1.2 | 1 / 360 | 0 / 0 |
| 2 | tests/corpus/parse/bad/OneMegabyteLine.beni | parse_bad | **313** | 434 | 1.1 | 1 / 312 | 0 / 0 |
| 3 | tests/corpus/run/AliasChainThroughLet.beni | run_release | **203** | 315 | 2.0 | 1 / 201 | 0 / 0 |
| 4 | tests/corpus/run/AliasChainThroughLet.beni | run_dev | **199** | 275 | 2.9 | 1 / 196 | 0 / 0 |
| 5 | tests/corpus/check/good/RequirementBelowDepth512.beni | check_good | **166** | 284 | 1.7 | 2 / 164 | 0 / 0 |
| 6 | tests/corpus/run/NestingLogicalStatements.beni | run_dev | **96** | 116 | 4.2 | 1 / 92 | 0 / 0 |
| 7 | tests/corpus/run/ReleaseAliasChain1000.beni | run_dev | **96** | 176 | 3.3 | 1 / 92 | 0 / 0 |
| 8 | tests/corpus/run/ReleaseAliasChain1000.beni | run_release | **95** | 123 | 2.9 | 1 / 92 | 0 / 0 |
| 9 | tests/corpus/run/NestingLogicalStatements.beni | run_release | **93** | 136 | 3.3 | 1 / 90 | 0 / 0 |
| 10 | tests/corpus/check/good/PairLookupTable.beni | check_good | **90** | 94 | 1.9 | 2 / 88 | 0 / 0 |
| 11 | tests/corpus/check/good/SixtyFourConstraints.beni | check_good | **82** | 86 | 3.1 | 3 / 79 | 0 / 0 |
| 12 | tests/corpus/check/good/WarningWithoutExplain.beni | check_good | **82** | 105 | 3.0 | 3 / 79 | 0 / 0 |
| 13 | tests/corpus/check/good/TypeOwnerEdges | check_good | **82** | 120 | 2.8 | 3 / 79 | 0 / 0 |
| 14 | tests/corpus/check/good/ConstrainedPubFunctionConstant | check_good | **78** | 158 | 2.8 | 3 / 75 | 0 / 0 |
| 15 | tests/corpus/check/good/DerivedNestedEvidence.beni | check_good | **78** | 237 | 3.0 | 3 / 74 | 0 / 0 |
| 16 | tests/corpus/check/good/InferredConstraint.beni | check_good | **77** | 170 | 3.0 | 3 / 74 | 0 / 0 |
| 17 | tests/corpus/check/good/SchemaMembers | check_good | **75** | 116 | 2.2 | 2 / 73 | 0 / 0 |
| 18 | tests/corpus/check/good/RecordExtChain.beni | check_good | **68** | 129 | 2.0 | 2 / 66 | 0 / 0 |
| 19 | tests/corpus/build/bad-release/DebugManySites | build_bad_release | **60** | 111 | 5.6 | 2 / 54 | 0 / 0 |
| 20 | tests/corpus/run/ViewMapEvery3.beni | run_dev | **60** | 80 | 6.3 | 1 / 54 | 0 / 0 |
| 21 | tests/corpus/run/ViewMapEvery3.beni | run_release | **60** | 67 | 6.5 | 1 / 53 | 0 / 0 |
| 22 | tests/corpus/build/bad-release/DebugToStringTwoModules | build_bad_release | **59** | 172 | 6.0 | 2 / 53 | 0 / 0 |
| 23 | tests/corpus/check/good/SchemaEndpointAliasAcrossModules | check_good | **59** | 64 | 1.9 | 2 / 57 | 0 / 0 |
| 24 | tests/corpus/build/bad-release/DebugLog | build_bad_release | **58** | 154 | 5.6 | 2 / 53 | 0 / 0 |
| 25 | tests/corpus/build/bad-release/DebugTodo | build_bad_release | **57** | 115 | 5.7 | 2 / 52 | 0 / 0 |
| 26 | tests/corpus/check/good/WideTypeArity | check_good | **57** | 90 | 1.9 | 2 / 55 | 0 / 0 |
| 27 | tests/corpus/check/good/DeepInferredScheme.beni | check_good | **56** | 130 | 1.8 | 2 / 54 | 0 / 0 |
| 28 | tests/corpus/check/good/LookupTable.beni | check_good | **56** | 133 | 1.8 | 2 / 54 | 0 / 0 |
| 29 | tests/corpus/check/good/QualifiedAcrossModules | check_good | **56** | 103 | 1.9 | 2 / 54 | 0 / 0 |
| 30 | tests/corpus/check/good/SchemaViaMutualOwnType.beni | check_good | **56** | 112 | 2.2 | 2 / 54 | 0 / 0 |
| 31 | tests/corpus/check/good/SchemaViaRing.beni | check_good | **56** | 97 | 1.9 | 2 / 54 | 0 / 0 |
| 32 | tests/corpus/check/good/WhereOnOtherParameterSameReceiver | check_good | **55** | 78 | 1.6 | 2 / 54 | 0 / 0 |
| 33 | tests/corpus/check/good/SchemaWinsModuleAlias | check_good | **55** | 75 | 2.0 | 2 / 53 | 0 / 0 |
| 34 | tests/corpus/check/good/Prelude.beni | check_good | **55** | 103 | 1.9 | 2 / 53 | 0 / 0 |
| 35 | tests/corpus/check/good/ScrutineeMethodMergeVariant | check_good | **54** | 82 | 1.9 | 2 / 53 | 0 / 0 |
| 36 | tests/corpus/check/good/SharedType | check_good | **54** | 111 | 1.5 | 2 / 53 | 0 / 0 |
| 37 | tests/corpus/check/good/OrderingPrimitives.beni | check_good | **54** | 127 | 1.8 | 2 / 52 | 0 / 0 |
| 38 | tests/corpus/check/good/SchemaEndpointInFlightClosed.beni | check_good | **54** | 96 | 2.0 | 2 / 52 | 0 / 0 |
| 39 | tests/corpus/check/good/SchemaUnsupported.beni | check_good | **54** | 105 | 2.0 | 2 / 52 | 0 / 0 |
| 40 | tests/corpus/check/good/QuestionShapes.beni | check_good | **53** | 85 | 2.0 | 2 / 51 | 0 / 0 |

**Distribution of cases by CPU:**

| CPU per case | cases | total CPU s |
|---|---:|---:|
| under 10 ms | 99 | 0.5 |
| 10 ms – 30 ms | 520 | 13.2 |
| 30 ms – 0.1 s | 621 | 22.9 |
| 0.1 s – 0.3 s | 3 | 0.6 |
| 0.3 s – 1 s | 2 | 0.7 |
| 1 s or more | 0 | 0.0 |

**By kind** (a `run/` program is one case per part):

| kind | cases | CPU s | mean ms | beni runs | node runs |
|---|---:|---:|---:|---:|---:|
| run_release | 251 | 8.5 | 34 | 251 | 1 |
| run_dev | 251 | 8.5 | 34 | 251 | 1 |
| check_bad | 267 | 7.1 | 27 | 267 | 0 |
| check_good | 68 | 3.9 | 58 | 142 | 0 |
| parse_bad | 119 | 3.3 | 28 | 119 | 0 |
| fmt | 58 | 2.0 | 35 | 348 | 0 |
| dispatch | 31 | 1.4 | 44 | 62 | 0 |
| check_args | 40 | 0.9 | 22 | 40 | 0 |
| emit | 29 | 0.8 | 29 | 29 | 0 |
| build_bad | 13 | 0.4 | 28 | 13 | 0 |
| parse_good | 69 | 0.3 | 5 | 69 | 0 |
| check_depth | 14 | 0.3 | 20 | 14 | 0 |
| build_bad_release | 4 | 0.2 | 59 | 8 | 0 |
| bir | 30 | 0.2 | 6 | 30 | 0 |
| regress | 1 | 0.0 | 27 | 1 | 0 |

### Per tool

Every process the black-box harness spawned, by program; `beni` by command
and `--jobs`.

| tool | runs | user s | sys s | **CPU s** | wall s | CPU ms per run (mean / median) | minor faults per run | max RSS MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| beni build --jobs=default | 785 | 24.3 | 12.4 | **36.7** | 55.1 | 46.8 / 29.1 | 2677 | 377 |
| node | 219 | 20.8 | 8.2 | **29.0** | 30.9 | 132.5 / 92.0 | 6286 | 417 |
| beni check --jobs=default | 783 | 14.4 | 8.5 | **22.8** | 32.4 | 29.2 / 24.4 | 1693 | 179 |
| beni dump --jobs=default | 1441 | 8.9 | 7.8 | **16.8** | 27.3 | 11.6 / 5.3 | 707 | 118 |
| beni check --jobs=1 | 423 | 4.5 | 3.6 | **8.1** | 12.7 | 19.2 / 14.0 | 1308 | 42 |
| beni build --jobs=1 | 87 | 3.5 | 1.7 | **5.2** | 6.1 | 60.3 / 29.7 | 4101 | 207 |
| corpus_test | 9 | 1.7 | 0.8 | **2.5** | 3.1 | 274.4 / 292.6 | 13553 | 55 |
| beni build --jobs=8 | 47 | 1.0 | 1.2 | **2.1** | 2.4 | 45.3 / 52.3 | 4952 | 24 |
| beni check --jobs=8 | 52 | 0.8 | 1.0 | **1.9** | 2.1 | 36.2 / 29.5 | 2847 | 24 |
| time-report | 1 | 1.3 | 0.6 | **1.8** | 1.3 | 1845.4 / 1845.4 | 64840 | 56 |
| beni fmt --jobs=default | 279 | 0.6 | 1.1 | **1.8** | 3.2 | 6.3 / 4.5 | 481 | 118 |
| beni dump --jobs=8 | 172 | 0.4 | 0.6 | **1.0** | 1.0 | 5.7 / 3.4 | 427 | 8 |
| beni dump --jobs=1 | 182 | 0.4 | 0.5 | **1.0** | 1.2 | 5.3 / 2.9 | 374 | 6 |
| beni check --jobs=2 | 35 | 0.5 | 0.3 | **0.9** | 1.0 | 25.4 / 26.6 | 1421 | 7 |
| beni fmt --jobs=8 | 82 | 0.1 | 0.2 | **0.3** | 0.3 | 3.2 / 3.1 | 265 | 4 |
| beni fmt --jobs=1 | 82 | 0.1 | 0.2 | **0.2** | 0.3 | 2.5 / 2.6 | 228 | 4 |
| beni check --jobs=4 | 7 | 0.1 | 0.1 | **0.2** | 0.2 | 29.1 / 26.7 | 1726 | 7 |
| beni check --jobs=3 | 7 | 0.1 | 0.1 | **0.2** | 0.1 | 24.9 / 28.1 | 1490 | 6 |
| beni version | 2 | 0.0 | 0.0 | **0.0** | 0.0 | 1.1 / 1.2 | 93 | 3 |
| beni --help | 2 | 0.0 | 0.0 | **0.0** | 0.0 | 1.0 / 1.1 | 94 | 3 |
| beni help | 1 | 0.0 | 0.0 | **0.0** | 0.0 | 1.0 / 1.0 | 93 | 3 |
| beni frobnicate | 1 | 0.0 | 0.0 | **0.0** | 0.0 | 1.0 / 1.0 | 93 | 3 |
| **all** | 4699 | | | **132.5** | | | | |

**Node start-up against execution.** A bare `node -e 0` took 28.9 ms CPU
and 28.6 ms wall (median of 9 runs, before the suites). Across the
219 Node runs that is about 6.3 CPU-s of start-up, which leaves about
22.7 of Node's 29.0 CPU-s for loading and running the programs.

### Harness overhead against children

The test process's own CPU against its children's, per binary.
"Unrecorded" is child CPU the harness did not spawn through `World`
(a `std.process.run`, say), so no `child` record names it.

| binary | harness user s | harness sys s | children CPU s | of which unrecorded | harness share |
|---|---:|---:|---:|---:|---:|
| unit_test | 31.7 | 7.5 | 0.0 | 0.0 | 100.0% |
| compare_gen_unit_test | 8.8 | 0.3 | 0.0 | 0.0 | 100.0% |
| corpus_test | 1.9 | 2.1 | 35.0 | 0.0 | 10.3% |
| abuse_test | 0.9 | 0.7 | 18.4 | 0.0 | 8.1% |
| cache_test | 1.0 | 0.6 | 16.7 | 0.0 | 8.8% |
| blackbox_test | 0.8 | 0.7 | 7.9 | 0.0 | 15.9% |
| frontend_test | 0.2 | 0.8 | 3.7 | 0.0 | 20.9% |
| abuse_wide_test | 0.6 | 0.2 | 16.9 | 0.0 | 4.4% |
| bench_gen_test | 0.7 | 0.0 | 0.0 | 0.0 | 100.0% |
| cutoff_test | 0.4 | 0.3 | 6.3 | 0.0 | 10.0% |
| ordering_test | 0.2 | 0.3 | 15.6 | 0.0 | 3.5% |
| build_test | 0.3 | 0.2 | 6.1 | 2.0 | 7.4% |
| compare_gen_test | 0.4 | 0.0 | 0.1 | 0.0 | 79.0% |
| digest_test | 0.2 | 0.2 | 1.8 | 0.0 | 17.2% |
| docs_test | 0.1 | 0.0 | 0.2 | 0.0 | 40.2% |
| iface_test | 0.1 | 0.1 | 1.1 | 0.0 | 10.2% |
| check_test | 0.1 | 0.0 | 0.4 | 0.0 | 21.6% |
| run_hash_test | 0.0 | 0.0 | 2.5 | 0.0 | 2.6% |
| time_report_test | 0.0 | 0.0 | 1.8 | 0.0 | 1.7% |
| diagnostic_test | 0.0 | 0.0 | 0.0 | 0.0 | 100.0% |
| **all** | | | 134.5 | | 31.7% |

### Repeated invocations

Commands run in the repository root, where the same arguments read the
same files. "Extra" is every run after the first.

**Identical command lines:** 159 extra runs, 0.8 CPU-s.

| command | runs | extra CPU ms |
|---|---:|---:|
| `node --version` | 4 | 58 |
| `beni dump --stage=graph --jobs=8 tests/corpus/check/good/TypeOwnerEdges` | 2 | 15 |
| `beni dump --stage=graph --jobs=1 tests/corpus/check/good/TypeOwnerEdges` | 2 | 9 |
| `beni dump --stage=ast tests/corpus/parse/good/LongModule.beni` | 2 | 6 |
| `beni dump --stage=ast tests/corpus/parse/good/DeepParens.beni` | 2 | 6 |
| `beni dump --stage=bir tests/corpus/bir/ResolvePrelude.beni` | 2 | 5 |
| `beni dump --stage=bir tests/corpus/bir/SchemaDeclarations.beni` | 2 | 5 |
| `beni dump --stage=ast tests/corpus/parse/good/OperatorsAll.beni` | 2 | 5 |
| `beni dump --stage=bir tests/corpus/bir/PipelineSaturation.beni` | 2 | 5 |
| `beni fmt --stdout tests/corpus/fmt/BindValueBlockForms.beni` | 2 | 5 |

**The same command apart from `--jobs`, `--no-cache`, `--cache-dir` and `--roundtrip-*`:** 506 extra runs, 2.5 CPU-s.

| command | runs | extra CPU ms |
|---|---:|---:|
| `node --version` | 4 | 58 |
| `beni dump --stage=graph tests/corpus/check/good/TypeOwnerEdges` | 4 | 36 |
| `beni dump --stage=ast tests/corpus/parse/good/LongModule.beni` | 3 | 13 |
| `beni dump --stage=ast tests/corpus/parse/good/DeepParens.beni` | 3 | 12 |
| `beni dump --stage=ast tests/corpus/parse/good/DictCache.beni` | 3 | 11 |
| `beni dump --stage=bir tests/corpus/bir/ResolvePrelude.beni` | 3 | 11 |
| `beni dump --stage=ast tests/corpus/parse/good/ExtensibleRecords.beni` | 3 | 11 |
| `beni dump --stage=ast tests/corpus/parse/good/LongList.beni` | 3 | 11 |
| `beni dump --stage=ast tests/corpus/parse/good/CaseBranchAtCaseColumn.beni` | 3 | 11 |
| `beni dump --stage=bir tests/corpus/bir/RestOfBlockBind.beni` | 3 | 10 |

<!-- test-time-report:end -->
