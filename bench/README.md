# bench — measured numbers

`fast-compiler.md` §12: the budget is tracked as a visible trend, not a gate.
This file is the trend. **Newest entry first**, each dated, each naming the
machine it was taken on, because a number without a machine is not a number.

How to reproduce an entry:

```sh
direnv exec . zig build -Doptimize=ReleaseFast
direnv exec . zig build bench -- --generate=100000     # writes .zig-cache/bench-gen
time ./zig-out/bin/beni check --jobs=1 .zig-cache/bench-gen
```

Wall times are **best of 5** on an otherwise idle machine. Check the load
average first: an early draft of the M1d table was taken while another build
was saturating the four cores and read 784 ms where the real number was
51 ms — a 15× error that looked entirely plausible.

---

## 2026-09-13 — M2c (DAG-parallel checking, exhaustiveness)

**Machine:** Intel N100, 4 cores / 4 threads, 6 MiB L3, single memory
channel, 16 GB RAM, Linux 7.2, Zig 0.16.0, ReleaseFast. Best of 15, load
average 1.3 (shared machine; an earlier pass at load 12 read 15-20 % high
across the board, which is the M1d warning above happening again).
**Corpus:** `bench/gen.zig --generate=100000` — 624 files, 100 159 lines,
1 840 323 bytes, 635 modules (core included), 3 787 edges. `beni check` on it
is clean, exhaustiveness included.

### Wall time by worker count

| command | `--jobs=1` | `--jobs=2` | `--jobs=4` | default (4) | speedup at 4 |
|---|---:|---:|---:|---:|---:|
| `check`, M2b (checker serial) | 137 ms | 117 ms | 110 ms | 110 ms | 1.25× |
| `check`, M2c (checker on the DAG) | 136 ms | 86 ms | **70 ms** | 71 ms | **1.94×** |

The M2b row is the same binary one commit earlier, measured the same way, and
it is why M2c did the work: at M2b the checker was **74 of the 137 ms** and
none of it parallelised, so four workers bought 1.25×. On the module DAG
(checker.md §4.4) it is 1.94×, and 40 ms comes off the wall clock of a
100k-line project.

`--jobs=1` is unchanged at 136 ms: exhaustiveness (checker.md §6.6) adds
3.4 ms and the rest is noise.

### Where the time goes (`--self-profile`, same corpus)

| | `check` j=1 | `check` j=4 |
|---|---:|---:|
| profiled span | 136.0 ms | 61.0 ms |
| total worker CPU | 106.9 ms | 151.0 ms |
| `read` | 4.8 | 7.0 |
| `lex` | 15.1 | 21.5 |
| `parse` | 11.4 | 16.3 |
| `lower` | 15.9 | 23.8 |
| `constrain` | 17.1 | 24.7 |
| `solve` | 39.2 | 53.2 |
| `exhaustive` | 3.4 | 4.5 |
| `enumerate` + `merge_interners` + `graph` + `resolve` + `render` (serial) | 10.1 | 12.1 |

`check` is the parent event of the three checker rows: 73.6 ms at j=1,
105.7 ms of CPU at j=4. Worker busy time at `--jobs=4` is
**37.8 / 37.1 / 38.4 / 37.6 ms** — within 3.5 %. The DAG scheduler keeps all
four fed for the whole run despite 3 787 edges and a core package every module
depends on; there is no straggler and no tail.

### Why 1.94×, and not 4×

Two limits, both measured rather than argued.

1. **The serial tail is 12.1 ms**: enumerate, the interner merge, the graph
   build and `resolve`, which is still one module at a time. That is 20 % of
   the `--jobs=4` span and it is the next thing worth parallelising.
2. **The machine gives about 2.65×, not 4×.** Four independent
   single-threaded `beni check` processes over the same corpus take **205 ms**
   wall against **136 ms** for one alone: an aggregate of 4 × 136 / 205 =
   **2.65×**. The same work costs 41 % more CPU when four workers do it
   (106.9 → 151.0 ms) and every phase inflates, `read` included, which is a
   syscall and a memcpy and contends on nothing of ours. This is an N100 —
   four Alder Lake-N E-cores sharing 6 MiB of L3 and one DDR channel — and a
   checker that builds a type store per module is memory-bound long before it
   is core-bound.

Against those two: the parallel part is 136.0 − 10.1 = 125.9 ms of work and
takes 61.0 − 12.1 = 48.9 ms at four workers, which is **2.57×, or 97 % of the
2.65× the machine will give**. Amdahl over the measured ceiling predicts a
span of 125.9 / 2.65 + 12.1 = 59.6 ms against the 61.0 ms measured, so 98 % of
the model. **The parallelism is kept**: 40 ms of wall time on the budget's own
corpus, for one ready queue and one reverse-edge table, scaling as close to
the machine's ceiling as the front end's does.

### Type checking throughput (`zig build bench`, single-threaded)

```
{"phase":"resolve","modules":635,"edges":3787,"interfaces":635,"ms":8.37,"cold_check_ms":44.3}
{"phase":"check","modules":635,"lines":100159,"unifications":234875,"generalisations":121908,"instantiations":73934,"obligations":3151,"diagnostics":0,"ms":92.18,"loc_per_s":1086516,"cold_check_ms":136.5}
{"phase":"total","files":624,"bytes":1840323,"tokens":302615,"nodes":223928,"insts":207449,"ms":130.4,"mb_per_s":13.5,"loc_per_s":768270}
```

**1.09 M LOC/s** for checking alone against the §2 target of 250 k LOC/s per
core, and 70 ms of wall clock for the whole cold pipeline against the 800 ms
budget. `zig build bench` runs the check single-threaded on purpose — the
target is stated per core — and this line was taken under a neighbour's load,
so read it as a floor.

### Pattern usefulness (checker.md §6.6)

`exhaustive` is **3.4 ms of 136**, 2.5 % of a cold check, over 635 modules.
Its scratch is one arena per WORKER reset per `case`, not one per module: at
one arena per module the same pass cost 7.1 ms, half of it mapping and
unmapping a 256 KiB chunk 635 times.

The work budget that bounds the exponential worst case is never approached by
real code. Turning it down until answers change: every `case` in `core/`, in
the `check` corpus and in the generated corpus is decided on a budget of
**50**, and a deliberately hostile 200-constructor × 200-branch `case` with
two-deep nests lands between **25 600 and 51 200** — and still finishes in
**6 ms**. The shipped budget is 200 000, so ~4 000× what real code needs and
4× what the hostile case needs.

| input | diagnostics | exit | time |
|---|---:|---:|---:|
| 200 constructors × 200 branches, two-deep nests | 1 | 1 | **6 ms** |
| 2 000-deep `Just (Just (…))` pattern (a legal tree) | 0 | 0 | 9 ms |
| 8 000-deep `Just (Just (…))` pattern (past the limit) | 2 | 1 | 10 ms |

### A segfault the M2c abuse scenarios found

`Just (Just (…))` is **two** tree levels per source level — `pat_ctor` over
`pat_paren` — and `Parse`'s depth guard charged one, so a 4096-charge pattern
built an 8192-deep tree. Every consumer walks that tree by recursion: 4 000
levels segfaulted `check`, `dump --stage=ast`, `dump --stage=bir` and `fmt`.
Two narrow fixes: `parsePatAtom` charges the guard as well, so the bound is on
the TREE and not on the source nesting; and every worker is now spawned with
an explicit 64 MiB stack (the size M2b measured for the checker), `--jobs=1`
included, so a crash can no longer depend on the worker count. The AST dump
runs on such a thread too — 4 090 nested parentheses in an *expression*
crashed it, which had nothing to do with patterns.

Cost of always spawning: `beni version` is 1-2 ms, unchanged; `fmt --check` is
70 ms at `--jobs=1` and 35 ms at the default, within noise of M1d's 57/26.

One number in the M1d table below is stale as a result and is left as it was
taken: 100 000 nested lambdas now produce **4095** diagnostics, not 4096,
because a lambda's parameter is a pattern atom and the depth guard charges one
for it. The bound moved by one level; nothing else about that input changed.

---

## 2026-09-13 — M1d (parallel driver, formatter on the workers)

**Machine:** Intel N100, 4 cores / 4 threads, 6 MiB L3, single memory
channel, 16 GB RAM, Linux 7.2, Zig 0.16.0, ReleaseFast.
**Corpus:** `bench/gen.zig --generate=100000` — 627 files, 100 073 lines,
1 825 939 bytes, 300 416 tokens, 221 471 AST nodes. `beni check` on it is
clean (zero diagnostics).

### Wall time by worker count

| command | `--jobs=1` | `--jobs=2` | `--jobs=4` | default (4) | speedup at 4 |
|---|---:|---:|---:|---:|---:|
| `check` | 51 ms | 31 ms | 25 ms | 25 ms | **2.1×** |
| `fmt --check` | 57 ms | 35 ms | 26 ms | 26 ms | **2.2×** |

`beni version` — the empty run — is 2 ms, so ~8 % of the `--jobs=4` wall
time is process start and exit. `--jobs` is capped at four times the CPU
count: `--jobs=20000` on one six-byte file used to spend 7.6 s building
twenty thousand arenas, interners and threads.

### Where the time goes (`--self-profile`, same corpus)

| | `check` j=1 | `check` j=4 | `fmt --check` j=1 | `fmt --check` j=4 |
|---|---:|---:|---:|---:|
| profiled span | 48.3 ms | 19.1 ms | 55.1 ms | 20.4 ms |
| total worker CPU | 47.8 ms | 65.5 ms | 54.6 ms | 71.4 ms |
| `read` | 5.0 | 7.0 | 4.9 | 6.5 |
| `lex` | 14.9 | 19.4 | 14.6 | 18.9 |
| `parse` | 11.2 | 16.1 | 11.4 | 16.8 |
| `lower` | 14.2 | 20.4 | — | — |
| `format` | — | — | 21.2 | 26.8 |
| `enumerate` + `merge_interners` + `render` (serial) | 2.6 | 2.6 | 2.5 | 2.4 |

Worker busy time at `--jobs=4` is 18.6 / 15.8 / 15.7 / 15.4 ms for `check`
and 20.0 / 17.3 / 17.2 / 17.0 ms for `fmt`: the work-stealing counter
balances the four queues to within 20 %, so nothing is waiting on a straggler.

### Why 2.1×, and not 4×

The serial part is not the limit. It is 2.6 ms — enumerate, the interner
merge and the render — against 48 ms of per-file work, so Amdahl alone would
predict 48/4 + 2.6 = 14.6 ms at four workers, not the 19.1 ms measured.

The gap is that **the same per-file work costs 37 % more CPU when four
workers do it** (47.8 → 65.5 ms). Every phase inflates, including `read`
(+40 %), which is a syscall and a memcpy and contends on nothing of ours.
That points at the machine, and the machine says so directly: **four
independent single-threaded `beni check` processes** over the same corpus
take **67-74 ms** wall against **51 ms** for one alone — an aggregate of
2.8-3.0×, not 4× (`fmt --check`: 78-81 ms against 57 ms, so 2.8-2.9×).
This is an N100: four Alder Lake-N E-cores sharing 6 MiB of L3 and one DDR
channel, and a front end that streams 1.8 MB of source into tens of
megabytes of token, tree and BIR arrays is memory-bound long before it is
core-bound.

Against that ~2.9× ceiling the driver gets 48.3/19.1 = **2.5×, or ~86 % of
what the machine will give**; for `fmt` it is 55.1/20.4 = 2.7×, or **~93 %**.
What remains is the 2.6 ms serial tail and ~5 ms of process start and
teardown outside the profiled span. Nothing in the driver is worth changing
for this workload on this machine; the numbers to re-take on a machine with
more memory bandwidth are the ones in the first table.

### `fmt` on the workers

Formatting was serial until M1d: `fmt --check` ran the parse phases in
parallel and then formatted every file on the main thread. It is now a
per-file worker phase (`Session.format_phases`) writing into a session-owned
buffer per file, and the command walks the files in index order afterwards
to compare, write and print — so the listing and the bytes are a function of
the sorted path list alone. `format` is 39 % of the per-file work at
`--jobs=1`, which is what the speedup reflects.

Measured effect at four workers: **34 ms → 26 ms**. At `--jobs=1` it is
50 ms before and 57 ms after — the same work plus one copy of each file's
canonical text into a session-owned buffer, which is what buys the
parallelism, and what the `formatted_bytes` counter now reports
(1 856 438 bytes for this corpus).

### Abuse inputs (`tests/blackbox/abuse_test.zig`)

`beni check --diagnostics=json`, best of 3, peak RSS from
`getrusage(RUSAGE_CHILDREN)` around the run. Every one of these exits
normally — none is a signal, a hang, or a partial write.

| input | diagnostics | exit | time | peak RSS |
|---|---:|---:|---:|---:|
| 10 MB one-line list literal (valid) | 0 | 0 | **500 ms** | **228 MB** |
| 10 MB one-line string literal | 0 | 0 | 64 ms | 22 MB |
| 10 MB file that is one identifier | 1 | 1 | 39 ms | 31 MB |
| 100 000 nested parentheses | 1 | 1 | 9 ms | 13 MB |
| 100 000 nested lists | 1 | 1 | 9 ms | 13 MB |
| 100 000 nested lambdas `\x -> \x -> …` | 4096 | 1 | 19 ms | 19 MB |
| 8 000-link `1 + 1 + …` chain | 1 | 1 | 3 ms | 13 MB |
| 8 000-link `r.a.a.a…` chain | 1 | 1 | 3 ms | 13 MB |
| 8 000-link `r????…` chain | 1 | 1 | 3 ms | 13 MB |
| 200 000 blank lines | 0 | 0 | 2 ms | 13 MB |
| every byte value 0–255 | 162 | 1 | 2 ms | 14 MB |
| mixed CRLF / LF / bare CR | 3 | 1 | 1 ms | 13 MB |
| unterminated string / char / interpolation at EOF | 1 / 1 / 2 | 1 | 1 ms | 13 MB |
| unterminated `(` / `[` / `{` at EOF | 2 each | 1 | 1 ms | 13 MB |
| a file that is only `--\|` | 1 | 1 | 1 ms | 13 MB |
| a file that is only `\` | 1 | 1 | 1 ms | 13 MB |
| 1 MB `--` comment line | 0 | 0 | 3 ms | 13 MB |
| `(x as)` with no name | 1 | 1 | 1 ms | 13 MB |
| empty directory | 0 | 0 | 1 ms | 13 MB |
| 5 000 empty modules, `--jobs=1` | 0 | 0 | 32 ms | 19 MB |
| 5 000 empty modules, default jobs | 0 | 0 | 19 ms | 19 MB |
| directory with a non-`.beni` file and a hidden subdirectory | 0 | 0 | 1 ms | 13 MB |
| `.hidden.beni` named explicitly | 2 | 1 | 1 ms | 13 MB |
| symlink loop `dir/loop -> ..` | 0 | 0 | 1 ms | 13 MB |
| the same file twice on the command line | 1 | 1 | 1 ms | 13 MB |

The 13 MB floor is the empty process. Only one input is over 200 ms — the
10 MB list literal, which is 3.5 M tokens and 3.5 M nodes of *valid*
program, at 22 bytes of front-end memory per source byte. It is the
`--pathological=big-list` generator case.

**No diagnostics cap is needed.** The 100 000 nested lambdas were the
candidate — every parameter but the first shadows the one outside it — and
they produce 4096 diagnostics, not 100 000, because the parser's nesting
limit stops the parse first. Peak RSS is 19 MB, three orders of magnitude
under the 2 GB bar. A cap would only ever fire on input the nesting guard
has already bounded, and it would cost every honest run a counter.

### Per-phase throughput, single-threaded (`zig build bench`)

```
{"phase":"read","files":627,"bytes":1825939,"ms":2.1,"mb_per_s":815.9}
{"phase":"lex","files":627,"bytes":1825939,"tokens":300416,"ms":9.7,"mb_per_s":180.4}
{"phase":"parse","files":627,"nodes":221471,"ms":6.2,"mb_per_s":280.6}
{"phase":"lower","files":627,"insts":205562,"ms":8.8,"mb_per_s":198.4}
{"phase":"total","files":627,"ms":26.8,"mb_per_s":65.1}
```

These are warm best-of-5 per-phase numbers with everything preallocated, so
they are lower than the cold `check` above (48 ms) by design: `check` reads,
allocates and keeps every artifact once.
