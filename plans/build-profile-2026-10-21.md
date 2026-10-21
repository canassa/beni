# The whole release build, profiled (issue #464)

*Measurement only. No code change, no PR, not committed. 2026-10-21. The compiler is
`pts-batched-worklist` at `84da85d55` (PR #572, open, not yet merged), built on dagon (Ryzen 9
5950X, TSC 3.39 GHz) with ReleaseFast. Every build ran as `build --release --no-cache --jobs=1`.
The programs are the research dashboard at N=64 (`~/.cache/beni-codex-growth/n64-s1`) and its
no-`withDefault` variant (`~/beni-loads-m/nowd`). Both have 67 source modules, 89 modules with
core, and about 6.8k lines of beni.*

## Method

Three compilers were built from `84da85d55`:

1. **Plain** (`beni-prof2/zig-out/fast`). It gave the wall time, the user/sys split, minor page
   faults, `perf stat` counts and `--self-profile`. Medians are of 7 runs.
2. **Frame pointers** (`beni-prof2fp/zig-out/fastfp`, `.omit_frame_pointer = false`).
   - Sampled with `perf record --call-graph fp`, 20 runs per program per event. The events were
     `instructions:u` every 600k and `cycles:u` every 300k.
   - The host caps sampling at 10 kHz (`perf_event_max_sample_rate`). The first attempt sampled
     faster than that, was throttled to about 4k samples a run, and was thrown away.
   - Inlined frames come from one batched `addr2line -i` over the unique addresses.
   - Each sample is charged to the innermost "owner" frame (`~/prof2/attr2.pl`).
   - Page faults were also sampled (`page-faults:u`, every fault).
3. **Counters** (`beni-prof2i/zig-out/fastprof{,2}`, a scratch `Spec.zig` made by
   `~/prof2/patch.pl` + `post.pl`, plus `Prof.zig`).
   - It times about 30 functions of `Spec`/`Pts` with rdtsc and a self-opened `instructions:u`
     counter, and counts their minor faults with `getrusage`.
   - At the end of every fact-3 run it reports the sizes and the fold sources, and per summary
     its fate and owner (under `--points-to-largest`, for origins).
   - Overhead is about 5% of `specialise` (232.6 ms against 220.8 ms for `nowd`), so its ms
     are written "≈".
   - In `fastprof2`, nested prints inflate the cost of the inliner passes. Their costs below
     are taken from `fastprof`.

## Baseline (plain build)

| program | wall | user | sys | minor faults | peak RSS | instructions:u | cycles:u | `specialise` |
|---|---|---|---|---|---|---|---|---|
| N=64 | **0.37 s** | 0.27 s | **0.10 s** | 60 500 | 185 MB | 2 312M | 1 021M | 277 ms |
| `nowd` | **0.31 s** | 0.23 s | **0.08 s** | 46 500 | 163 MB | 1 993M | 864M | 221 ms |
| N=16 | 0.08 s | 0.06 s | 0.02 s | 13 600 | 56 MB | 434M | 223M | — |

The brief's 0.35 s / 266 ms and 0.29 s were taken on a quieter host. The proportions below do
not depend on it. **Over a quarter of the wall time is kernel time, and nearly all of that is
page faults** (cause 2).

## (1) Phase table of the whole build

The wall times are medians of the self-profile. The instruction shares come from `perf`
(attributed by the innermost phase marker), scaled to `perf stat`'s total.

| phase | N=64 wall | N=64 instr | `nowd` wall | `nowd` instr | notes |
|---|---|---|---|---|---|
| process start and exit (outside the trace) | ≈12 ms | — | ≈9 ms | — | exit unmaps about 185 MB |
| frontend: enumerate, read, lex, parse, lower to BIR, embedded core load, resolve, publish | 11.5 ms | 63M (2.7%) | 11.7 ms | 56M (2.8%) | read 0.7, lex 1.5, parse 1.5, BIR lower 2.0, embedded/cache load 2.4, resolve 1.2, publish 1.0 |
| check | 14.9 ms | 95M (4.1%) | 15.2 ms | 98M (4.9%) | solve 5.8, constrain 2.2. Above the >250k LOC/s budget. |
| ownership | 13.5 ms | 83M (3.6%) | 13.7 ms | 84M (4.2%) | `Walker.applySummary` recursion, flat profile |
| emit: writes | 8.6 ms | 65M (2.8%) | 8.7 ms | 66M (3.3%) | `Writes.analyseProgram`/`keyTree`; `SmpAllocator` lock 6% of it |
| emit: eliminate (reach) | 2.1 ms | 16M (0.7%) | 2.2 ms | 16M (0.8%) | |
| emit: `emit_module` (lower to JsIr, optimise, print tasks) | 21.8 ms | 151M (6.6%) | 21.8 ms | 150M (7.5%) | lower to JsIr 5.7% / 6.7%, of which markup (`viewPieces`, `MarkupTree.build`) is 31% |
| **emit: `specialise`** | **276.6 ms** | **1 797M (77.7%)** | **220.8 ms** | **1 469M (73.7%)** | below |
| emit: other (hoist plan, numbering, link, diagnostics) and `write` | 7.4 ms | 24M (1.0%) | 6.6 ms | 23M (1.2%) | |
| **total** | **≈370 ms** | 2 312M | **≈310 ms** | 1 993M | |

The cycle shares agree with the instruction shares to within a point. The page faults fall:

| | N=64 | `nowd` |
|---|---|---|
| in `specialise` | 82% (49.8k) | 77% (35.8k) |
| check | 4.3% | 5.7% |
| ownership | 3.3% | 4.2% |
| lower to JsIr | 3.1% | 4.1% |
| the rest | ≈7% | ≈8% |

## (2) Inside `specialise`

### By run and by pass

ms is from the counting build ("≈"); the instruction counts are exact. "f3" is the fact-3
fixpoint (`Pts.fixpoint`).

| step | N=64 ≈ms | N=64 Mi | `nowd` ≈ms | `nowd` Mi | faults (N=64 / `nowd`) |
|---|---|---|---|---|---|
| run 1 f3 / sweeps / rewrite / prune | 31.1 / 4.7 / 2.3 / 0.3 | 168 / 29 / 16 / 2.4 | 29.5 / 4.8 / 2.4 / 0.3 | 162 / 30 / 16 / 2.4 | 6 744 / 6 756 |
| run 2 | 28.3 / 3.0 / 1.3 / 0.3 | 161 / 23 / 11 / 2.3 | 27.2 / 3.1 / 1.3 / 0.3 | 155 / 23 / 11 / 2.4 | 5 973 / 5 874 |
| run 3 (identical to run 2 but for 1 node) | 22.2 / 2.9 / 1.2 / 0.3 | 161 / 21 / 10 / 2.3 | 21.7 / 2.9 / 1.2 / 0.3 | 155 / 21 / 10 / 2.4 | 2 826 / 2 836 |
| pass 1: inlineSmall / **inlineOnce** / fuseCalls / constructors / scalarReplace | 2.7 / **18.7** / 1.8 / 0.9 / 1.9 | 11 / **130** / 10 / 5 / 18 | 2.7 / **18.3** / 1.8 / 1.0 / 2.0 | 10 / **129** / 10 / 5 / 18 | |
| run 4 f3 / sweeps / rewrite | 22.1 / 2.6 / 1.0 | 158 / 20 / 9 | 22.0 / 2.7 / 1.0 | 152 / 20 / 9 | 2 810 / 2 817 |
| pass 2: same order | 2.1 / **14.9** / 1.2 / 0.7 / 0.4 | 8 / **105** / 7 / 4 / 3 | 2.0 / **14.7** / 1.1 / 0.7 / 0.4 | 8 / **105** / 7 / 4 / 3 | |
| **run 5** f3 / sweeps / rewrite | **51.4** / 2.5 / 0.9 | **305** / 19 / 8 | 20.0 / 2.5 / 0.9 | 139 / 19 / 8 | 8 836 / 2 695 |
| pass 3: same order | 1.9 / 6.3 / 1.3 / 0.7 / 0.4 | 8 / 36 / 8 / 4 / 3 | 1.8 / 6.1 / 1.2 / 0.7 / 0.4 | 7 / 36 / 8 / 4 / 3 | |
| **run 6** f3 / sweeps / rewrite | **53.0** / 2.5 / 0.9 | **270** / 19 / 8 | 19.5 / 2.4 / 0.9 | 136 / 19 / 8 | 10 600 / 2 706 |
| tail: list modes, releaseKeeps, trimArguments, forwardEntry, inlineReads, prune, finish | 5.4 | 34 | 5.2 | 34 | |
| **`Spec.run`** | **≈302** | **1 845** | **≈233** | **1 513** | 49 840 / 35 759 |

Totals per kind of work:

| kind | N=64 | `nowd` | share of `specialise` (N=64 / `nowd`) |
|---|---|---|---|
| fact-3 fixpoints | ≈208 ms / 1 223M | ≈140 ms / 899M | 66% / 60% |
| facts 1, 2, 4, 5 sweeps | 18 ms | 18 ms | 7.4% / 9.2% |
| `rewrite` | 7.5 ms | 7.6 ms | 3.0% / 3.8% |
| `prune` | ≈3 ms | ≈3 ms | 1.1% / 1.3% |
| `inlineOnce` | **40 ms / 270M** | 39 ms | **15% / 19%** |
| other structural passes and the list modes | ≈22 ms | ≈22 ms | ≈8% |

`perf` gives the same split: inlineSmall 1.7%, fuseCalls 1.5%, the list modes
(`eachFunctionList`: `srList`, `iife`, `self_assign`, `switches`) 2.5%, inlineReads 0.7%,
trimArguments 0.2%, forwardEntry 0.1%, releaseKeeps 0.1%, constructors 0.1% of `specialise`.

**`inlineOnce` writes one function per scan, capped at 256 per pass** (`max_inlines`), and it
hits the cap twice (`spec_inline_capped` 2).

| pass | inlined | `inlineAt` attempts |
|---|---|---|
| 1 | 256 (capped) | 2 430 |
| 2 | 256 (capped) | 23 582 |
| 3 | 90 | 9 981 |

Each `inlineOne` call rescans and reallocates arrays sized to every whole-program name
(`sites`, `assigned`, `fit`), retries every candidate that failed before, and recounts the
changed module (`inlineScan`). For `nowd` its inclusive split is:

| part of `inlineOnce` | share |
|---|---|
| `inlineAt` (Copy, `countNames`/`namedTwice`, `canName`/`occurrences`, `placeIndexed`) | 45% |
| `inlineScan` | 28% |
| `inlineOne` itself | 14% |
| `isRoot` | 6% |

### Fact 3, by phase of the run

Instruction shares of all fact-3 work, from `perf`:

| phase | N=64 | `nowd` |
|---|---|---|
| first walk (`walkStatements`) | 46% | **65%** |
| re-evaluation (`evaluate`/`evaluateWaiting`) | **52%** | 34% |
| `propagate` + entry + end-of-sweep escape/drain + `reset` | 1.5% | 1.6% |

The first walk costs **97–102M instructions and 13–18 ms in every run, whatever changed**. That
is 6 × ≈100M ≈ 600M, a third of `specialise`.

Re-evaluation in runs 1–4 is 45M (sweep 1) + 10M + 6M. In N=64 runs 5–6 it is 27M + **165M /
132M** + 8M. Each run converges in 3 sweeps of `byConstraints`, plus 7 empty ones (10 in all).

### Fact 3, by what does the work

Shares of all fact-3 instructions, charged to the innermost owner (cycles in brackets).

| category | N=64 | `nowd` | main leaves |
|---|---|---|---|
| join worklist (`enqueue`, `drain`, `joinNow`) | 16.1 (13.6) | 19.7 (17.4) | `joinNow` 4–5, `enqueue` 3.7–3.9, `linksAcross` 2.2–2.8, `binarySearch` 2–2.9, `drain` 1.8–2 |
| set table (`unionSets`, `difference`, `filterSites`, `intern`, `KeyMap(SetOpKey/SetHash)`) | 10.0 (9.1) | 12.2 (12.0) | `unionSets` 3.8–5.0, ops probe 1–1.3, `hashSites` 0.8–1 |
| copy edges (`copy`, `hasEdge`, `indexEdge`) | **14.8 (16.5)** | 7.5 (7.8) | `hasEdge` 8.2 / 4.7, `KeyMap(EdgeKey)` find+grow 2.1 |
| summaries (`summaryProp` 15.0/9.1, `fields` 4.5/3.4, `marks` 4.5/6.2, `foldSite` 1.6/1.1, alias 0.5/1.0, link 0.3/0.5) | **26.4** | 21.3 | `summaryProp` with its `partitionPoint` 12.3 / 7.2, `markSite`, `findMark` |
| lookups (`propAt`, `localVar`, `nodeVar`, `propId`, `siteOf`, `newVar`, `view`) | 14.1 (15.6) | **16.1 (18.6)** | `partitionPoint` over site properties 4.2 / 5.1, `propAt` 2.1, `VSet` append 1.4 |
| walk's own transfer (`combineNow`, `effectNow`, `expr`, `narrowed`, `copySource`) | 8.0 | 11.0 | |
| recording constraints (`begin`, `input`, `link`) | 2.2 | 2.8 | |
| re-evaluation's own (`evaluate`) | 2.0 | 2.2 | |
| `call` | 2.3 | 2.8 | |
| dependencies (`addDep`, `wake`, `varChanged`) | 1.6 | 2.0 | |
| loads (`load`, `newLoad`, `readAll`) | 0.8 | 1.2 | |
| `makeTop` / `escapeSite` / `escape` | 0.9 | 0.5 | |
| `propagate` | 0.2 | 0.2 | |
| setup (`reset`, `byConstraints`) | 0.6 | 0.8 | |

**What starts the join, set and copy work** (share of fact 3):

| started by | N=64 | `nowd` |
|---|---|---|
| a statement's transfer (`effectOf`: bindings, assignments, returns) | 12.9 | 17.4 |
| `shareField` under a spread | **9.3** | 1.6 |
| `combine` (object properties, arrays) | 8.5 | 9.1 |
| `foldSite` | 3.6 | 2.9 |
| `call` | 2.5 | 3.2 |

**Inclusive, as % of the whole build** (`perf`, instructions; N=64 / `nowd`):

| function | N=64 | `nowd` | where (N=64) |
|---|---|---|---|
| `spreadSummary` | **12.7** | 3.3 | 11.5 in re-evaluation |
| `foldSite` | 11.5 | 10.7 | 8.2 in the first walk |
| `copy` | 12.5 | 8.4 | 41% from `call`, 39% from `shareField` |
| `propAt` | 8.5 | 3.9 | 78% from `spreadSummary` |
| `summaryProp` | 8.2 | 4.2 | 45% from `propAt` under a spread, 33% from `foldSite` |

Per fold: `foldSite` costs about **11.6k instructions** on `nowd` (213M over 18.4k folds). A fold
walks every property of the site (`summaryProp`: a binary search, and `addSumProp`, which wakes
every spread of the summary), copies it (`copyField`/`copy`), and marks each of the summary's
marks on the site (`markSite` → `propAt`). The model summary has 64 properties and 64 marks.

### Per run, sizes (N=64; `nowd` the same for runs 1–4)

| run | edges | joins | folds | vars (top) | sites | summaries | object re-evals / Mcyc | faults |
|---|---|---|---|---|---|---|---|---|
| 1 | 29 984 | 88 361 | 3 961 | 22 284 (7 625) | 3 339 | 1 683 | 1 691 / 17.0 | 6 744 |
| 2 | 28 764 | 85 464 | 3 925 | 19 700 | 2 863 | 1 529 | 1 244 / 13.5 | 5 973 |
| 3 | 28 764 | 85 463 | 3 925 | 19 699 | 2 863 | 1 529 | 1 244 / 10.9 | 2 826 |
| 4 | 26 557 | 81 436 | 3 698 | 16 737 | 2 318 | 1 025 | 1 244 / 13.0 | 2 810 |
| **5** | **138 080** | 93 552 | **11 594** | 30 499 (12 100) | 2 062 | 1 001 | 1 486 / **110.2** | 8 836 |
| **6** | **108 719** | 87 994 | **8 810** | 29 636 (11 992) | 1 973 | 1 001 | 1 489 / **93.2** | 10 600 |
| `nowd` 5 / 6 | 18 482 / 17 176 | 72 979 / 71 760 | 1 883 / 1 718 | ≈15k | ≈2k | 1 050 | 1 003 / 6.2, 1 006 / 5.6 | 2 695 / 2 706 |

The edges sum to `spec_pts_edges` (360 868 and 151 994). The joins sum to `spec_pts_joins`. An
object's value never changes (it is its own site), yet every one of its re-evaluations re-runs its
keys' joins and its spread.

## (3) N=64 runs 5–6: do they still dominate, and what do they fill?

**They are no longer 80% of the build, but they are still the two largest runs.** Each costs
2.3–2.4× an ordinary run: 51 + 53 ms and 575M instructions. That is 50% of fact 3's time, 35% of
`specialise`, and about 28% of N=64's wall time.

Their excess over an ordinary run (≈ 2 × 30 ms) is almost exactly the gap between N=64 and
`nowd` (277 − 221 = 56 ms). The excess is in sweep 2's re-evaluation (165M and 132M against 10M),
and it is started by **object re-evaluations** (110 and 93 Mcyc against 11–17).

**#565's premise still holds for what is left.** End-of-run state, counted per edge by the
summary its target var belongs to:

| run 5 / run 6 | edges | into summaries | owner var ends `top` | summary dead | escaped/unknown, not dead | read whole by a spread |
|---|---|---|---|---|---|---|
| N=64 run 5 | 138 080 | 125 718 | **120 353 (87% of all, 96% of summary edges)** | **67 244 (49%)** | ≈53 000 | 118 228 |
| N=64 run 6 | 108 719 | 97 582 | **92 555 (85%)** | 26 882 (25%) | ≈65 700 | 91 422 |
| `nowd` run 5 | 18 482 | 9 772 | 4 113 | 1 533 | — | 3 003 |
| `nowd` runs 1–4 | ≈30 000 | ≈18 700 | ≈10 000 | **8 370 (28%)** | — | 7 178 |

In run 5, 11 456 of 11 594 folds come from `joinNow` and 138 from `feedSummary`. 10 333 of them
land in summaries whose owner ends `top`, and 5 240 in summaries that are provably wasted: dead,
or escaped with no spread reading them and no successor. In run 6 the figures are 8 672, 7 599
and 2 342.

The largest summaries are the case the previous profile named, now without #562's member-read
part:

- **Dead summaries of locals in the widget modules** (modules 59–65, `const_decl` locals at
  offsets 476–1123, the lifted `update` arms). Each folds 177–200 merged widget-model sites with
  70–78 properties, about 2 400–2 860 in-edges each. The owner is capped and goes `top` after
  folding, so the summary dies with everything it folded.
- **Escaped, uncapped summaries of `Main`'s summary-property vars** (offset 1969, the
  `browser-inline` handlers' code). Each holds 179–200 sites with 71–78 properties, is read whole
  by spreads, and has 4 successors. Its owner is `top`, so a read through it is `top`. A spread
  still copies its properties, so these are not provably dead. They keep the spreads awake: each
  new property (`addSumProp` → `summaryChanged`) wakes every spread of the summary, and each
  re-evaluation re-walks all ~78 properties (`propAt`, `shareField`, `copy`).

So the residue of runs 5–6 is the `withDefault` merge folding into summaries that end dead or
`top`, plus the spreads it wakes again. It did not exist before pass 2 put those arms in, and
`nowd`'s runs 5–6 are ordinary (20 ms).

## (4) Outside `specialise`

- **Kernel time, 0.10 s of N=64's 0.37 s (0.08 of 0.31 for `nowd`), is page faults.** There are
  60.5k minor faults at about 1.7 µs each, 82% of them in `specialise`.
  - `Pts.reset` allocates every per-node column anew (`vals`, `site_of`, `node_var`/`node_top`,
    `name_var`/`name_top`, `ones`, `globals`) from the permanent `Spec.arena`. That is about
    2.5–3 MB per run that never comes back, the D4 pattern *Memory* names.
  - `tmp.reset(.retain_capacity)` in Zig 0.17 frees every node but one and reallocates that one to
    the total size. When the allocation moves, a fresh mapping faults again.
  - So every run faults 2.7k–10.6k pages (≈11–42 MB) even when it needs no more memory than the
    last one. `P.reset` itself takes 0.9–3.4 ms for 0.4M instructions: zeroing fresh pages.
  - `inlineOne`'s arrays sized to the whole program take 5.7k faults over 602 calls.
- **`emit_module`, 21.8 ms.** Lowering to JsIr is 131M instructions (5.7%):
  - declarations 56%;
  - `viewPieces`/`inline.piece` 20%;
  - `beginMarkup`/`MarkupTree.build` 11%.

  Printing is about 0.9% (≈3 ms) and the per-module optimiser 0.7%. All of it runs per module,
  and it is serial here only because of `--jobs=1`.
- **`check`, 14.9 ms** for 67 modules: 16k unifications, 20k generalisations. The profile is flat
  (`Markup.pattern` 4%, `TypeStore` lookups, `Generalize.adjustRanks`). At 6.8k lines that is
  about 450k LOC/s, above the 250k budget.
- **`ownership`, 13.5 ms.** One whole-program walk (`computeGroup` → `walkSummary` →
  `applySummary`, recursive), flat: `proj`, `resolveRaw`, hash maps keyed by step and words.
- **`writes`, 8.6 ms.** `analyseProgram`/`keyTree` recursion. 6.4% of it is `SmpAllocator`'s lock
  and 3–4% its size classes: many small general-purpose allocations in single-threaded code.
- **Print, link and write: about 4 ms. Process start and exit: about 9–12 ms**, most of it
  tearing down 160–185 MB of mappings.

## The top five causes, with remedies

The estimates are for this program and overlap. They are not additive past the first two.

### 1. The N=64 merge folds into summaries that die, and the spreads it wakes walk every property again (N=64 −55…−65 ms)

**Evidence.** Section (3).

- Runs 5–6 cost 51 and 53 ms against 22 ms. Re-evaluation in sweep 2 takes 165M and 132M
  instructions, and object re-evaluations 110 and 93 Mcyc.
- 87% of run 5's edges point into summaries whose owner ends `top`, and 49% into dead ones.
- `spreadSummary` is 12.7% of the whole N=64 build and `copy` 12.5%.
- Every `addSumProp` wakes every spread of the summary (`summaryChanged`). Each re-evaluated
  spread re-walks every property, even though `pr.from == sp.vals` skips most of them at the
  end. The cost before that point is `propAt`'s binary search, `shareField`'s chain walk and
  `hasEdge`.

**Remedies, each a change of order or laziness and no change of facts:**

- **`top` first.** A var whose batch will make it `top` (capped) is drained before any var whose
  batch only adds sites. Today the FIFO lets 180 sites fold before the `top` that kills the
  summary arrives (#565). *The worklist* allows any fair order.
- **Fold lazily.** A summary's per-property edges are made only when a consumer, a spread or a
  load cell, reads that property. A dead summary is never filled.
- **Spread by difference.** A summary keeps an append-only log of the properties it has added,
  and a spread constraint keeps a cursor into it. A re-evaluation woken by `summaryChanged`
  processes only the properties added since its last evaluation. This is *The worklist*'s
  "propagate the difference" applied to keys, and it also removes `nowd`'s smaller share
  (spreads are 3.3% of its build).

**Gain.** Runs 5–6 back to an ordinary run's ≈22 ms: N=64 −55…−65 ms (0.37 → ≈0.31 s). `nowd`
−5…−10 ms, since 28% of its run-1–4 summary edges feed dead summaries too.

### 2. A quarter of the wall time is page faults, because memory is not reused across runs (N=64 −45…−70 ms, `nowd` −35…−50 ms)

**Evidence.**

- sys 0.10 s / 0.08 s; 60.5k / 46.5k minor faults.
- Faults per fact-3 run: 6.7k, 6.0k, 2.8k, 2.8k, 8.8k and 10.6k (N=64). `nowd`'s runs 3–6 fault
  2.7–2.8k pages each with flat memory needs.
- Run 1 costs 29.5 ms against run 3's 21.7 ms for 162M against 155M instructions. About
  4k extra faults explain the difference.
- `P.reset` takes 1–3.4 ms on 0.4M instructions.
- Peak RSS is 185 MB for a 6.8k-line program, and exit spends ≈10 ms unmapping it.

**Remedy, as *Memory* already specifies.**

- Three arenas, with the solve's columns and pools **reset and reused** after each rewrite, not
  freshly allocated:
  - size `vals`, `site_of`, `node_var`, … once per pass, grown with `grow`, and `@memset` them
    each run;
  - keep `tmp` as one retained region, with no `reset(.retain_capacity)` realloc;
  - allocate `inlineOne`'s per-name arrays once per pass.
- Optionally `madvise(MADV_HUGEPAGE)` the large regions (THP is `madvise` on dagon), so that one
  fault maps 2 MB.

**Gain.** The faults fall toward the peak working set of one run, about 60–70 MB: −40k faults ≈
−45…−70 ms on N=64, −35…−50 ms on `nowd`. Peak RSS should fall by half or more, which also
shortens exit.

### 3. Every run rebuilds every constraint, var, site, edge and summary from nothing, and run 3 recomputes run 2 (−22 ms now, −40…−60 ms with slice 6)

**Evidence.**

- The first walk is ≈100M instructions and 13–18 ms in each of the six runs: a third of
  `specialise`, and 65% of fact 3 on `nowd`.
- Inside the walk (% of fact 3, `nowd`): joins 12.2, lookups 12.0, `summaryProp` 8.1, set table
  7.7, marks 5.4, own transfer 6.5, copy 4.3, constraint recording 2.8.
- Run 3 has the same edges, constraints and summaries as run 2, to the unit (28 764 edges,
  29 161 / 29 160 constraints), and costs 22 ms on both programs (#499).

**Remedy.**

- (a) Skip run 3 when round 2's rewrite is fact-3-neutral (#499 (b)): −22 ms on both programs,
  no fact changed.
- (b) Then *The combined solver*'s Extraction, with arrays kept per module while
  `Mod.version` stands, and slice 6's one solve per structural pass: the walk becomes extraction
  plus a solve over flat arrays.

The previous profile found 62–72 of 78 modules changed between runs, so module-grain reuse alone
buys little. Most of the gain is from fewer solves and a solver that does not rebuild its
lookups: `localVar`'s `KeyMap`, `propAt`'s sorted insert, `newVar` appends.

**Gain.** (a) −22 ms. (a)+(b) −40…−60 ms.

### 4. The inliner writes one function per whole-program scan, capped at 256 per pass, so the program needs three passes and two more solves (−25…−30 ms of inliner, and up to −1 solve)

**Evidence.**

- `inlineOnce` is 40 ms and 270M instructions, 15–19% of `specialise` and the largest item
  outside fact 3.
- It wrote 256, 256 and 90 functions with 2 430, 23 582 and 9 981 `inlineAt` attempts: about
  92 failed attempts per success in pass 2.
- Each success rescans: `inlineScan` (28%), the per-name candidate loops and allocations (14% +
  `isRoot` 6%), and failing candidates retried from scratch.
- The cap is hit in passes 1 and 2 (`spec_inline_capped` 2). Pass 3 still changes the program
  (`spec_passes_capped` 1).
- Runs 5 and 6, and at N=64 their degenerate cost, exist because the inlining that exposes the
  `withDefault` merge to the widget arms arrives in passes 2–3.

**Remedy.**

- Write every independent candidate of one scan in innermost-first order, marking the
  statements each write touched. Retry only candidates whose call statement or callee changed,
  and remember refusals by `(callee, statement version)`.
- Make the per-pass cap a budget of nodes, not 256 functions.

Then the structural loop should converge in 1–2 passes, so the build needs 4 solves, or 3 with
#499 (b), not 6.

This one **can move output**: the inlining order and the facts between passes change, so goldens
may move and need justifying. Slice 6 already plans that kind of move.

**Gain.** Inliner 40 → ≈8–12 ms (−25…−30 ms). One solve fewer is −20 ms on `nowd`. At N=64 it
removes one of the 50 ms runs (the degenerate one would then be run 4) unless cause 1 lands
first.

### 5. The solver's constant factors: a binary search or a hash probe per step, and duplicate checks (−25…−35% of what is left of fact 3)

**Evidence** (% of fact 3, N=64 / `nowd`):

| work | N=64 | `nowd` |
|---|---|---|
| `partitionPoint`/`binarySearch` in all: site properties (`propAt`), summary properties (`summaryProp`/`findSumProp`), marks (`findMark`), and a site in a var's set (`joinNow`/`enqueue`) | 15 | 13 |
| `hasEdge` and `KeyMap(EdgeKey)` | 10.3 | 6.3 |
| `unionSets` and set-op probes | 5 | 6.3 |
| `linksAcross` per successor per join | 2.2 | 2.8 |
| `VSet` appends: `newVar` copies a struct that grew by 28 bytes with #563 | 1.4 | 1.4 |

There are 522k joins for 361k edges, and 85k joins a run on `nowd`.

**Remedy, consistent with *Cells*.**

- **Field cells per declared shape.** A site's properties and a summary's properties live in a
  dense array indexed by the field's slot in its record type: the declared-type keys
  (`RepKey`) give every `Main.Model` field a fixed slot. Every property lookup becomes an index,
  and `propAt`'s sorted insert disappears.
- **Marks** as a bitset per summary.
- **Edge dedupe by stamping.** Mark the source on the target with an epoch, instead of a list
  scan plus a hash.
- **`linksAcross` cached** on the edge.
- **`VSet` hot/cold split.** The queue fields and the summary/alias fields move out of the hot
  record.

**Gain.** About a third of each run's instructions after causes 1–3: N=64 −30…−45 ms, `nowd`
−35…−45 ms at today's six runs, and proportionally less with fewer runs.

## Estimated outcome and floor

**After causes 1–5** (one-thread, this program): N=64 0.37 s and `nowd` 0.31 s both fall to
about **0.13–0.16 s**. Most of the gain comes from 1 + 2 + 3(a) on N=64, from 2 + 3 + 5 on
`nowd`, and from 4 on both. What is left is then:

- `specialise` ≈60–80 ms;
- emit outside it ≈35 ms;
- check + ownership ≈28 ms;
- frontend ≈12 ms;
- start and exit ≈5 ms.

**Floor for this program**, each phase at its best:

| phase | today (N=64) | floor | why |
|---|---|---|---|
| start and exit | ≈12 ms | ≈3 ms | small RSS, nothing to unmap |
| frontend (read → publish) | 11.5 ms | ≈6 ms | already fast; core from the pack |
| check | 14.9 ms | ≈10 ms | already at 450k LOC/s |
| ownership | 13.5 ms | ≈6 ms | core's summaries precomputed in the pack, a flatter walker |
| lower to JsIr, optimise, print | 21.8 ms | ≈12 ms single-thread, ≈4 ms at `--jobs=8` | per module, parallel already |
| writes + eliminate | 10.7 ms | ≈5 ms | arena in place of `SmpAllocator` |
| fact 3 | 208 ms (6 runs) | ≈15–20 ms | 3–4 solves × ≈5 ms: ≈30k constraints, ≈30k edges, ≈80k joins on flat arrays is ≈30–40M instructions a solve |
| facts 1/2/4/5 + rewrite + prune | 28 ms | ≈8 ms | one rewrite per solve (slice 6) |
| structural passes | ≈62 ms | ≈10 ms | batched inliner (cause 4) |
| link + write | ≈4 ms | ≈3 ms | |
| **total** | **≈370 ms** | **≈80–90 ms single-thread, ≈60 ms with `--jobs`** | |

So a release build of this program in "milliseconds", meaning under 0.1 s, is reachable. It
needs causes 1–5 and slice 6. Under 50 ms needs parallel lowering and checking and a solver
close to the floor above.

**Order for #464's next slices:**

1. Memory reuse across runs (cause 2): no fact moves, and both programs gain about 20%.
2. `top` first, lazy folds and spreads by difference (cause 1, #565).
3. Skip run 3 (#499 (b)).
4. The batched inliner (cause 4, output may move).
5. Shaped field cells and the constant factors (cause 5).
6. Slice 6.

## Files (dagon)

- Worktrees, all throwaway and detached at `84da85d55`. Delete them when done.
  - `~/src/github.com/canassa/beni-prof2`: plain, `zig-out/fast`.
  - `beni-prof2fp`: frame pointers, `build.zig` patched, `zig-out/fastfp`.
  - `beni-prof2i`: instrumented `src/js/Spec.zig` + `Prof.zig`, `zig-out/fastprof`,
    `zig-out/fastprof2`.
- `~/prof2/`, 193 MB:
  - instrumentation: `patch.pl` and `post.pl` (they regenerate `SpecProf.zig` from any `Spec.zig`
    of this shape) and `Prof.zig`;
  - counter reports: `{n64,nowd}.prof.{1,2,3}.txt`, `*.prof2.*.txt`, and
    `*.prof2.largest.txt` (with origins);
  - self-profiles: `*.sp.{1..7}`; times: `*.time`;
  - perf data: `*.{ins,cyc}{1..20}.data`, `*.pf.data`; resolved samples: `*.raw`, `ips*.a2l`;
  - scripts: `agg.pl` (self-profile), `runs.pl` (per run and per pass), `attr2.pl` (fact-3
    categories), `build.pl` (whole-build phases), `tree.pl`/`sub.pl`/`callers.pl`/`incl.pl`/
    `leafsub.pl`/`pf.pl`.
