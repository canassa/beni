# The whole release build, profiled again (issue #464)

*Measurement only. No code change, no PR, not committed. 2026-10-21, 16:58 CEST. Measured on
`origin/master` at `f4cee4260`. That commit has #584, #591, #592 and #602, then #604 (merged at
13:38) and `9adae2ba2`, the first #577 commit (lookups that start where the last one ended). I
also kept `b49e65025` (the master before #604 and #577) for one interleaved comparison. Host:
dagon (Ryzen 9 5950X, TSC 3.39 GHz), ReleaseFast. Every build ran as `build --release --no-cache
--jobs=1` unless a `--jobs` is given. Load average during the timed runs was 0.4–1.5. Some
earlier runs overlapped a compile at load 2–4 and were thrown away. The programs are the
research dashboard at N=64 (`~/.cache/beni-codex-growth/n64-s1`) and its no-`withDefault`
variant (`~/beni-loads-m/nowd`): 67 source modules, 89 with core and platforms, about 6.8k
lines. Both outputs are byte-identical to before (`5742b6307271`, `a33c0aa5fe70`).*

## Headline

| program | wall `--jobs=1` | wall `--jobs=8` | user / sys | minor faults | peak RSS | instructions:u | `specialise` |
|---|---|---|---|---|---|---|---|
| N=64 | **190 ms** (min 188) | 177 ms | 0.13 / **0.05 s** | 29 000 | 106 MB | 1 303M | 113 ms |
| `nowd` | **176 ms** (min 174) | 162 ms | 0.12 / 0.04 s | 25 600 | 93 MB | 1 202M | 95 ms |

The walls are medians of 11 runs timed with `date`, without `--self-profile`. Under `perf stat`
(7 runs) they are 195.4 ± 0.5 ms and 181.2 ± 1.1 ms.

In an interleaved run, `b49e65025` → `f4cee4260` took N=64 from 207.6 to 198.5 ms (medians of
11) and from 1 384M to 1 303M instructions. `nowd` went from 187.5 to 180.9 ms and from 1 278M to
1 202M. #577's first commit is real, and it is about 8 ms.

**The build is no longer dominated by one degenerate solve. It is dominated by repetition.**

- Three of the four analyses change nothing in the output of these two programs.
  - Cutting `rounds` to one round and skipping the analysis after the structural pass leaves
    **one** analysis.
  - The output is still byte for byte the same: N=64 goes 190 → **145 ms**, `nowd` 176 → **144
    ms**.
- Page faults are still about a quarter of the wall time.
  - `madvise(MADV_HUGEPAGE)` on `src/Arena.zig`'s large chunks, five lines, takes 16–17 ms off
    both programs.
  - The output is again byte-identical.

## Method

Five throwaway worktrees on dagon, all detached at `f4cee4260`:

1. **`beni-prof3`** (plain, `zig-out/fast`). Wall time, `/run/current-system/sw/bin/time` (user,
   sys, faults, RSS), `perf stat`, `--self-profile` (medians of 9), and the `--jobs` sweep.
2. **`beni-prof3fp`** (`omit_frame_pointer = false` on the four modules, `zig-out/fastfp`).
   - Sampled with `perf record --call-graph fp`, 25 runs per program per event:
     `instructions:u` every 1M and `cycles:u` every 500k. That stays under the host's 10 kHz cap:
     about 1 250 samples a run.
   - Page faults were sampled one by one.
   - The samples were read with `perf script --no-inline` (the default, with inlining, takes over
     a minute a file), then resolved with one batched `addr2line -i -f`.
   - Attribution: `~/prof3/perf2/*.pl`, the scripts of `~/prof2`.
3. **`beni-prof3i`** (counters: `~/prof3/patch.pl`/`post.pl` regenerated on the new
   `Spec.zig`, plus `P.foldWaiting` and a `NOTE` line after every analysis, rewrite, prune and
   structural pass).
   - It reports the change count (the sum of `Mod.epoch`), the nodes, the names and the
   top-level statements after each step.
   - Its overhead is about 5% of `specialise` (119 against 113 ms), so its milliseconds are
   written "≈". Its instruction counts are exact.
4. **`beni-prof3thp`** — the THP experiment (cause 2): after `openChunk`'s `rawAlloc`,
   `madvise(…, MADV_HUGEPAGE)` on the 2 MiB-aligned interior of every chunk of 2 MiB or more.
5. **`beni-prof3x`** — the analysis-skip experiments (cause 1), switched by the files
   `/tmp/beni_skip_a4` (no `rounds()` after a structural pass) and `/tmp/beni_one_round` (each
   `rounds()` stops after its first round).

## (1) The whole build, by phase

Wall time is the median of 9 self-profiles. Instructions are `perf` shares (innermost phase
marker) scaled to `perf stat`'s total. Faults are the sampled faults' shares of the total. Sys
time is not traced by phase. Nearly all of it is faults, at ≈1.5 µs each: run 1's first walk
runs the same instructions as run 2's and takes 6.6 ms more for 4 000 more faults.

| phase | N=64 wall | N=64 instr | N=64 faults | `nowd` wall | `nowd` instr | `nowd` faults |
|---|---|---|---|---|---|---|
| process start, exit, outside the trace | ≈2–5 ms | — | — | ≈5 ms | — | — |
| frontend: enumerate, read, lex, parse, BIR, embedded load, resolve, cache load, digests | 10.5 ms | 48M (3.7%) | 1.5k | 10.8 ms | 48M (4.0%) | 1.6k |
| check (67 modules) | 13.2 ms | 83M (6.4%) | 2.6k | 13.5 ms | 84M (7.0%) | 2.6k |
| ownership | 12.2 ms | 83M (6.4%) | 2.0k | 12.0 ms | 82M (6.8%) | 2.0k |
| emit: writes | 8.1 ms | 70M (5.4%) | 0.6k | 7.6 ms | 70M (5.8%) | 0.6k |
| emit: eliminate (two walks) | 2.0 ms | 16M (1.2%) | 0.4k | 1.9 ms | 16M (1.4%) | 0.4k |
| emit: lower BIR → JsIr, **twice** | **7.8 + 9.2 ms** | 119M (9.1%) | 1.9k | 7.9 + 9.1 ms | 120M (10.0%) | 1.9k |
| emit: other before `specialise` (boundary, rep keys, piece waves, `buildDirect`) | ≈3.8 ms | 33M (2.5%, all "other") | 0.4k | ≈3.8 ms | 33M | 0.4k |
| **emit: `specialise`** | **113.1 ms** | **809M (62.1%)** | **18.2k** | **95.4 ms** | **706M (58.7%)** | **14.8k** |
| emit after it: optimise + print (`emit_module`), hoist, numbering, fields, `write` | ≈6.9 ms | 37M (2.9%) | 1.0k | ≈6.9 ms | 38M | 1.0k |
| **total** | **190 ms** (trace ends at 188) | 1 303M | 29.0k | **176 ms** (171) | 1 202M | 25.6k |

The cycle shares agree within 1–3 points. Lowering and check are a little higher in cycles
(10.4% and 8.4% at N=64), because they fault more per instruction.

## (2) Inside `specialise`

### By analysis, pass and step

The ms are ≈ (the counting build). Mi are exact millions of instructions. Each cell is N=64 /
`nowd` where the two differ.

| step | ≈ms | Mi | faults | what it changed (N=64; `nowd` the same) |
|---|---|---|---|---|
| **analysis 1**: fact 3 | 25.5 / 23.8 | 140 / 135 | 7.0k | |
| — first walk (`walkStatements`) | 12.2 / 11.6 | 56.6 | **4.0k** | |
| — re-evaluation, sweeps 1–3 | 6.8 / 6.3 | 52 / 47 | | |
| — end-of-sweep folds (`foldWaiting`) | 3.9 | 27.7 | | |
| — `reset`, `propagate` + entry | 1.0 + 0.2 | 1.3 | 584 | |
| — facts 1/2/4/5 sweeps (4 walks) | 4.3 | 29.5 | 547 | |
| — `rewrite` / `prune` | 2.1 / 0.3 | 16.1 / 2.4 | | rewrite **731** changes; prune 205 changes, 154 statements |
| **analysis 2**: fact 3 | 13.4 / 12.5 | 132 / 128 | 141 | |
| — walk / re-evaluation / folds | 4.8 / 5.3 / 2.1 | 51.3 / 50.0 / 27.6 | | |
| — sweeps / `rewrite` / `prune` | 2.7 / 1.2 / 0.3 | 22.6 / 11.2 / 2.3 | | rewrite **3** changes; prune nothing |
| **analysis 3**: fact 3 kept (#584) | — | — | | |
| — sweeps / `rewrite` / `prune` | 2.4 / 1.0 / 0.3 | 21.2 / 9.9 / 2.3 | | **nothing**, so `rounds` ends |
| **structural pass 1** | | | | |
| — `inlineSmall` | 2.6 | 10.6 | 834 | 13 changes |
| — **`inlineOnce`** | **17.0** | **96.5** | 2.3k | 601 functions, +10.7k nodes |
| —— of which `inlineAt`, 878 calls | 11.5 | 92.5 | | |
| —— of which `inlineScan` | 2.3 | 4.7 | | |
| — `fuseCalls` | 1.5 | 9.1 | 399 | returns false, yet +29 changes and +1.9k nodes |
| — `constructors` | 0.8 | 5.3 | | 15 / 64 changes |
| — `scalarReplace` | 1.5 | 12.7 | | 568 changes |
| — `prune` + `grow` | 0.5 | 2.1 | | 606 statements dropped |
| **analysis 4**: fact 3 | **28.2** / 13.5 | **212** / 114 | 4.2k / 1.0k | |
| — walk | 6.0 | 51.9 | 841 | |
| — re-evaluation, sweeps 1–2 | 3.4 | 32.4 | | |
| — **re-evaluation, sweep 3** | **11.4** / 0.03 | **68.4** / 0.2 | | |
| — folds | **5.2** / 2.2 | **51.7** / 28.3 | | |
| — sweeps / `rewrite` / `prune` | 2.2 / 0.8 / 0.2 | 19.2 / 7.4 / 1.8 | | **nothing** |
| **structural pass 2** (all five return false) | 5.3 | 25 | | +1.9k nodes (`fuseCalls` again), otherwise nothing |
| tail | 1.3 | 12.2 | | list modes `self_assign` / `iife` / `switches`: 1 change |
| — `releaseKeeps` | 0.04 | 0.3 | | |
| — `trimArguments` | 0.5 | 5.2 | | 214 changes |
| — `forwardEntry` | 0.25 | 2.2 | | |
| — `inlineReads` + `prune` | 1.9 | 11.1 | 530 | |
| — `init`, `grow`, `finish` | 0.55 | 0.6 | | |
| **`Spec.run`** | **≈119 / ≈101** | | 18.2k / 14.8k | |

By kind of work, at N=64 (`nowd`):

| kind | ≈ms | share of `specialise` | `perf` instructions |
|---|---|---|---|
| fact 3, 3 solves | **67 (50)** | 56% (49%) | 450M (349M) |
| facts 1/2/4/5 sweeps, 16 whole-program walks | 11.6 | 10% (12%) | 93M |
| `rewrite` ×4 | 5.1 | 4.3% | 44M |
| `prune` ×6 | 1.6 | 1.4% | 13M |
| `inlineOnce` ×2 | 20.0 | 17% (20%) | 100M |
| other structural passes and list modes | ≈10 | 8% | ≈60M |
| tail (`inlineReads`, `trimArguments`, `forwardEntry`) | ≈2.5 | 2% | 16M |

### What the four analyses change

These are the `NOTE` lines of the counting build.

- **Analysis 1** does the work: 731 rewrite changes, then a prune of 205 changes.
- **Analysis 2** is a full fact-3 solve plus sweeps, ≈17.6 ms, and its rewrite makes 3 changes:
  #575's `"root"` literal and the parameter it drops.
- **Analysis 3** keeps fact 3 (#584). It costs 3.7 ms of sweeps, rewrite and prune, and changes
  nothing.
- **Analysis 4** follows the structural pass. It is the solve whose sweep 3 still carries the
  `withDefault` merge, ≈31.4 ms at N=64 and 16.7 ms for `nowd`. **Its rewrite and prune change
  nothing.** Its facts feed structural pass 2, which changes nothing (5.3 ms), and the tail,
  where `trimArguments` makes 214 changes.

**Experiment** (`beni-prof3x`, output compared byte for byte):

| variant | analyses | N=64 output | N=64 wall | `nowd` output | `nowd` wall | N=16 output |
|---|---|---|---|---|---|---|
| master | 4 (5 at N=16) | 115 243 B | 190 ms | 116 413 B | 176 ms | 32 511 B |
| no `rounds()` after the structural pass | 3 | **identical** | 168 ms | **identical** | 163 ms | 32 745 B (**+234**) |
| one round per `rounds()` | 2 | **identical** | 176 ms | **identical** | 160 ms | 32 466 B (**−45**) |
| both | **1** | **identical** | **145 ms** | **identical** | **144 ms** | — |

On these two programs, three analyses (≈58 ms of instrumented time, −45 / −32 ms of wall) buy
nothing. At N=16 they do buy something, and in both directions:

- Skipping the analysis after the structural pass loses 234 bytes.
- Stopping each `rounds` after one round **saves** 45 bytes.

That is the fingerprint of facts approximated by repetition, which *The combined solver*
names. It is not a licence to drop analyses.

### Fact 3, per solve

| run | walk | re-evaluation | folds | total | sizes (N=64) |
|---|---|---|---|---|---|
| 1 | 12.2 ms / 56.6M (4.0k faults) | 6.8 / 52.0 | 3.9 / 27.7 | 25.5 / 140M | 30.0k edges, 85.6k joins, 3 692 folds, 22.3k vars (7.6k `top`), 3 339 sites, 1 683 summaries |
| 2 | 4.8 / 51.3 | 5.3 / 50.0 | 2.1 / 27.6 | 13.4 / 132M | 28.8k edges, 3 656 folds |
| 3 (after pass 1) | 6.0 / 51.9 | **14.8 / 100.8** (sweep 3: 11.4 / 68.4) | **5.2 / 51.7** | **28.2 / 212M** | **87.3k edges**, 8 766 folds, 28.7k vars (11.6k `top`), 1 973 sites |
| `nowd` 3 | 6.2 / 52.2 | 3.2 / 30.2 | 2.2 / 28.3 | 13.5 / 114M | 17.0k edges, 1 718 folds |

- **A warm solve of this 50k-node program is about 13 ms and 130M instructions**, about 2 600
  instructions a node: 40% the walk, 38% re-evaluation, 21% folds.
- **Run 1 is twice that** because it faults its arena in.
- **The N=64 excess is now one place**: run 3 is 28.2 ms against 13.5 for `nowd`. That is
  ≈15–17 ms, the whole N=64 − `nowd` gap in `specialise` (113 − 95).
  - It sits in sweep 3's re-evaluation: 1 505 object constraints re-evaluated, every one with an
    unchanged value, 41 Mcyc (≈12 ms) against 3.7 Mcyc for `nowd`.
  - It sits in the folds: 51.7 against 28.3 Mi.
  - 70 956 of run 3's 87 312 edges point into summaries whose owner is `top` and which a spread
    reads whole.
  - 42 summaries took ≥100 folds each (6 666 folds). The largest is 199 sites × 78 properties,
    escaped, with 4 successors.
- **Folds that are thrown away.** In runs 1 and 2, 1 503 of about 3 670 folds (41%) and 8 383 of
  30k edges (28%) go into summaries that die.

Where fact-3 instructions go now, after `9adae2ba2`. These are leaf groups, as % of fact 3 (N=64
/ `nowd`); the bulk of the "rest" is the transfer functions and their callers.

| leaf group | N=64 | `nowd` | main leaves |
|---|---|---|---|
| lookups: `indexAt`, `summaryPropAt`, `propAtHint`, `summaryProp`, `propIndex`, the remaining `partitionPoint` | 15.4 | 10.7 | `indexAt` 2.9, `partitionPoint` 2.8, `summaryPropAt` 2.6 |
| join worklist's own (`joinNow`, `enqueue`, `drain`, `linksAcross`) | 12.2 | 14.2 | |
| set table (`unionSets`, `difference`, `filterSites`, `hashSites`, `holdsSite`, op probes) | 11.0 | 13.0 | `unionSets` 5.7 / 6.6 |
| list growth, alloc, `lists.push` | 7.9 | 8.7 | |
| edge dedupe (`hasEdge`, `indexEdge`) | 5.1 | 1.1 | was 7.7 / 3.9 at `b49e65025` |
| memcpy / memset, other hashing | 4.1 | 4.8 | |
| rest: transfer functions (`combineNow`, `call`, `narrowed`, `copy`, `copyField`, `foldSite`, `evaluate`, …) | 44.4 | 47.5 | |

**#577's area** is the lookups, the set table, the edge checks and the list layout. It is still
≈39% of fact 3 at N=64 and 33% for `nowd`, about 26 ms and 16 ms. I quantify it here and leave
the design of its fix to #577.

## (3) Outside `specialise`

- **Lowering to JsIr runs twice**: 7.8 ms, then 9.2 ms (`Emit.emitModules`, the `refined`
  loop).
  - The first lowering (`lower_only`) skips core and the runtime module. It exists to compute
    `preciseRuntimeRoots`.
  - Then `walk` runs again and every module is lowered again.
  - `src/Main.beni` alone is 3.7 + 3.6 ms of the two.
  - Inside lowering, `declarations` is 57%, `viewPieces`/`inline.piece` 19% and
    `beginMarkup`/`MarkupTree.build` 12%.
- **Ownership is one module**: 12.2 ms, of which `ownership_module` for `src/Main.beni` is 11.3
  ms (`computeGroup` under `ensureSummary`, 93%; `summaryText` 4%).
  - It is serial at every `--jobs`.
  - The profile is flat: `Walker.proj` 11%, `resolveRaw`, the `WordsKey`/`StepKey` maps.
- **Check: 13.2 ms for 67 modules**, about 515k LOC/s, so within budget.
  - `src/Main.beni` is 4.1 ms of it.
  - The profile is flat (`TypeStore.find`/`content`/`sortKeyed`, `Markup.build`/`pattern`,
    `adjustRanks`).
- **Writes: 8.1 ms, serial** (`analyseProgram`).
  - The `Table.Interned` hash map is 9%.
  - `SmpAllocator`'s lock and size classes are 11%, in single-threaded code.
- **Facts 1/2/4/5 sweeps: 11.6 ms**, 16 whole-program walks (`walkTop` → `evalStmt`
  86%, `prepareTop`/`countTop` 13%), about 5.8M instructions each.
- **The inliner.** `inlineAt` is 878 calls of about 105k instructions each.
  - **38% of it is one linear scan**: `Copy.property`, `for (c.dst.names.items, 0..) |x, i| if
    (x.eql(name))`, a walk over the destination module's every name for every property name
    copied across modules. `JsIr.Name.eql` is 2.2% of the whole build, ≈4 ms.
  - The next 27% is `extend`/`retract` → `countNames` (`namedTwice`, `findUse`,
    `Mod.globalOf`).
- **Faults outside `specialise`**: 10.8k at N=64 (check 2.6k, ownership 2.0k, lowering 1.9k,
  print 0.8k, frontend 1.5k), ≈16 ms of sys time.
- **Process start and exit**: `beni version` is 2.7 ms. The build's wall time is 2–5 ms past the
  trace's end, most of it unmapping 106 MB.

## (4) Parallelism today

| `--jobs` | N=64 median (min) | `nowd` median (min) |
|---|---|---|
| 1 | 190.3 (188.1) | 176.1 (173.7) |
| 2 | 179.2 (177.2) | 169.1 (166.5) |
| 4 | **175.9** (174.2) | **161.2** (158.6) |
| 8 | 176.9 (175.4) | 162.0 (159.7) |
| 16 | 183.3 (179.1) | 170.5 (163.8) |

**`--jobs=8` saves 13–14 ms (7–8%). `--jobs=4` is as good, and 16 is worse.**

What runs in parallel at `--jobs=8` (N=64 trace, `jobs=1` span → `jobs=8` span):

| phase | `jobs=1` | `jobs=8` | threads | note |
|---|---|---|---|---|
| frontend, per file (read, lex, parse, BIR lower, embedded load) | 6.3 ms | 2.5 ms | 8 | |
| `cache_load` / `dep_digest` | | | 8 | |
| check, DAG-parallel | 13.7 ms | 6.1 ms | 8 | critical path: `Main` at 4.1 ms, after the widgets |
| lowering, two waves × two passes | 17.0 ms | 11.7 ms | 3 | `Emitter.wanted` asks for 3 threads; `Main` 3.7 ms is each pass's floor |
| reachability's edge build, optimise, print | | | | parallel, ≈3 ms in all |

Serial whatever `--jobs` is:

- ownership, 12 ms
- writes, 7.7 ms
- eliminate's walks
- **`specialise`, 110 ms**
- hoist planning, numbering and field assignment

That is ≈150 of 177 ms at `--jobs=8`. Amdahl caps `--jobs` at about −15 ms until `specialise`,
ownership and writes are parallel, or much shorter.

## (5) The five causes, with remedies

The estimates are for N=64 single-threaded. They overlap, so do not add them past the first
two.

### 1. Three of four analyses buy nothing here, and the design pays for them anyway (−30…−45 ms)

**Evidence.** Section (2), *What the four analyses change*.

- Analysis 2 (≈17.6 ms) rewrites 3 nodes. Analysis 3 (3.7 ms) rewrites none. Analysis 4 (≈31.4
  ms) and pass 2 (5.3 ms) rewrite and prune none.
- A build with one analysis is byte-identical on N=64 and `nowd`: 190 → 145 ms and 176 → 144 ms.
- At N=16 the same cuts move the output by +234 and −45 bytes, so the repetitions are an
  approximation, not dead weight.

**Remedy.** *The combined solver*'s slices 5–6: one optimistic solve per structural pass, read
once by one rewrite. Analyses 1 + 2 + 3 become one solve, and analysis 4 + pass 2 become the
second and last solve. This build then has 2 solves instead of 3 and 4 rewrite rounds, and the
facts no longer depend on how often the rounds ran (N=16's ±bytes).

Inside today's design, two smaller steps:

- (a) A structural pass whose analysis then rewrote and pruned nothing is not tried again (pass
  2: −5 ms). This is sound only for passes that read no facts the analysis could have changed,
  or with the passes looped to their own fixpoint inside the pass.
- (b) `fuseCalls` builds 1.9k nodes per pass that it then reports as no change. Find why.

**Gain.** About −17 ms for analyses 2–3 merged into analysis 1, −5 ms for pass 2, and analysis 4
becomes the one solve after the pass, with no rewrite round of its own. That is −30…−45 ms
measured as an upper bound, by the one-analysis experiment.

### 2. A quarter of the wall time is still page faults (−16 ms measured, −20…−30 ms in reach)

**Evidence.**

- sys 0.05 s of 0.19 s; 29.0k faults (25.6k for `nowd`) at ≈1.5 µs.
- 63% of the faults are in `specialise`:
  - run 1's first touch: 7.0k, of which the walk takes 4.0k and 6–7 ms;
  - run 3, which outgrows the arena: 4.2k;
  - the inliners: 2.3k + 0.8k + 0.5k (`NameUse` in `useAt`).
- The leading allocation sites are lists that grow by doubling in the bump arena and leave the
  old copy behind (#592's note says half of run 1's 38 MB):
  - `VSet` in `newVar`: 1.0k;
  - `FieldOut` in `copyField`: 1.4k in run 3;
  - `Edge`s, `NameUse`.
- The rest is check 2.6k, ownership 2.0k, lowering 1.9k and print 0.8k.

**Experiment.** `madvise(MADV_HUGEPAGE)` on every `Arena` chunk of 2 MiB or more
(`beni-prof3thp`, 5 lines in `openChunk`). THP on dagon is `madvise`/`madvise`. The output is
byte-identical.

| program | faults | sys | wall (median of 11, interleaved) | peak RSS |
|---|---|---|---|---|
| N=64 | 29.1k → 15.4k | 0.06 → 0.03 s | 198.5 → **182.5 ms** | 107 → 113 MB |
| `nowd` | 25.7k → 14.4k | 0.04 → 0.02 s | 180.9 → **163.9 ms** | 94 → 100 MB |

**Remedy.**

- **Portable, and the structural one**: grow the hot columns of a run (`vars`, `sites`,
  `edges`, `FieldOut`, the inliner's `NameUse`) without copying.
  - One way is to reserve each column's address range once (`mmap` of a large `PROT_NONE`
    region, committed as it grows) so growth is in place.
  - Another is to size them from the program's node count before the first run.
  - Either way there is no doubling garbage, and run 1 touches about half the pages.
- Give check, ownership and lowering the same `keep_all` reuse, or one process-wide arena per
  phase.
- **Linux only**: huge pages for large chunks, as measured. It does not reach the playground's
  wasm, and macOS has no THP.

**Gain.** −16 ms measured for THP alone. With in-place growth, −20…−30 ms on Linux and
−10…−15 ms elsewhere.

### 3. The N=64 merge still costs one solve its size again (−12…−15 ms at N=64, ≈0 for `nowd`)

**Evidence.**

- Run 3 is 28.2 ms against 13.5 ms.
- Sweep 3's re-evaluation is 68.4M against 0.2M instructions: 1 505 object constraints, each
  with an unchanged value, cost ≈12 ms.
- Folds are 51.7M against 28.3M instructions.
- 81% of run 3's edges point into escaped summaries of uncapped `top` owners that spreads read
  whole: 42 summaries of 141–199 sites × 63–78 properties.
- The previous profile's cause 1 is not gone. #563/#565 moved it, and it is all in the one solve
  after the structural pass. Cause 1's remedy keeps that solve, so this cause stays when cause 1
  lands.

**Remedy** (no fact moves): *The worklist*'s difference propagation applied to keys.

- A summary keeps an append-only log of the properties it has added.
- A spread constraint keeps a cursor into that log.
- An object re-evaluated because `summaryChanged` woke it processes only the properties past the
  cursor, since the object's own value (its site) cannot change.
- Folds into a summary whose owner is already `top` and capped are skipped (dead).

**Gain.** Run 3 back to ≈14 ms: −12…−15 ms at N=64. `nowd` −1…−2 ms (its spreads are 1.4% of
fact 3).

### 4. Every solve rebuilds fact 3 from the program, and a third of each is #577's constant factors (−15…−25 ms over today's three solves)

**Evidence.**

- A warm solve is 13 ms and 130M instructions: the walk 51M, re-evaluation 50M, folds 28M.
- The walk makes every constraint, var, site and summary anew, whatever changed.
- 41% of runs 1–2's folds are into summaries that die.
- #577's area is ≈39% / 33% of fact 3 (the table above).

**Remedy.**

- *Extraction* (slice 4–5): per-module constraint arrays, made on workers and kept while
  `Mod.version` stands. The previous profile found 62–72 of 78 modules changed between runs, so the gain is from the workers and from not rebuilding lookups, not from reuse.
- #577's remaining constant factors.
- Folds made only for summaries some consumer still reads.

**Gain.** About −30% to −40% of each solve: −15…−25 ms at today's three solves, and −10…−15 ms
after cause 1. Extraction on workers moves the walk's ≈5 ms a solve to `--jobs`.

### 5. Lowering twice, and the serial work bound to `Main` (−8 ms single-threaded, and it decides what `--jobs` can give)

**Evidence.**

- Lowering is 7.8 + 9.2 ms because of the `refined` loop.
- `src/Main.beni` is the critical path of every phase it is in:
  - check 4.1 ms of 13.2;
  - ownership 11.3 ms of 12.2;
  - lowering 3.7 + 3.6 ms of 17.
- So `--jobs=8` gains 13 ms. The lowering pool uses 3 threads, and ownership and writes use 1.

**Remedy.**

- Lower once. Keep the first pass's slots for every module whose lowering does not depend on
  the refined roots, and lower only core and the runtime module again. Better still, compute
  `preciseRuntimeRoots` from BIR and reach before lowering anything.
- Split ownership and lowering of a large module by declaration group, as check already
  schedules per module.
- Run writes per module.
- The inliner's `Copy.property` name scan (≈4 ms, 2.2% of the build) wants a per-module name
  index, interned once. `countNames` recounting per write (27% of `inlineAt`) wants incremental
  counts.

**Gain.** −8 ms (lower once) and −4…−6 ms (inliner) single-threaded. With per-group ownership
and lowering, `--jobs=8` would give −30…−40 ms instead of −13.

**Not in the five.** Facts 1/2/4/5's 16 walks (11.6 ms) fold into cause 1's solver (slice 4).
Writes' `SmpAllocator` (≈1 ms) wants an arena.

## (6) Estimate of the floor

| phase | today (N=64) | floor | why |
|---|---|---|---|
| start + exit | ≈4 ms | ≈2 ms | smaller RSS to unmap |
| frontend | 10.5 | ≈6 | already per file |
| check | 13.2 | ≈10 | 515k LOC/s now |
| ownership | 12.2 | ≈6 | flatter walker; core's summaries from the pack |
| writes + eliminate | 10.1 | ≈5 | arena, not `SmpAllocator` |
| lowering | 17.0 | ≈8 | once |
| emit other, before and after | 10.7 | ≈6 | |
| fact 3 | 67 (3 solves) | ≈12–16 | 2 solves × 6–8 ms: extraction cached, cause 3, #577 |
| facts 1/2/4/5 + rewrite + prune | 18.3 | ≈5 | inside the solver, one rewrite per solve |
| structural passes + tail | 32.6 | ≈12 | inliner without the scan, no pass 2 |
| faults not already counted above | ≈(in the rows) | — | in-place growth, reuse |
| **total, single thread** | **190 ms** | **≈75–90 ms** | |
| **with `--jobs=8`** | 177 ms | **≈50–60 ms** | |

The `--jobs=8` figure needs frontend and check on workers (as now), lowering, extraction and
rewrite per module, and ownership per group.

Order for #464's next slices, by gain for the risk:

1. **Faults** (cause 2). No fact moves. THP is −16 ms for five lines on Linux; in-place column
   growth is the portable half.
2. **Spread by difference** (cause 3). No fact moves; −12…−15 ms at N=64.
3. **Lower once and the inliner's name index** (cause 5). No fact moves; −12 ms.
4. **The combined solver's slices 4–6** (causes 1 and 4). Outputs move, as slice 6 foresees;
   −40…−60 ms.
5. Parallel ownership, writes and lowering by group (cause 5), for `--jobs`.

With 1–3 alone, N=64 goes from ≈190 to ≈145–150 ms. With 4 as well it reaches about 90 ms.

## Files (dagon, throwaway; delete when done)

- Worktrees, all detached at `f4cee4260`:
  - `~/src/github.com/canassa/beni-prof3`: plain, `zig-out/fast`;
  - `beni-prof3fp`: frame pointers, `build.zig` patched, `zig-out/fastfp`;
  - `beni-prof3i`: counters, `src/js/Spec.zig` patched and `src/js/Prof.zig`,
    `zig-out/fastprof`;
  - `beni-prof3thp`: `src/Arena.zig` madvise, `zig-out/fast`;
  - `beni-prof3x`: the analysis-skip switches.
- `~/prof3/` (296 MB):
  - `beni-b49e`: the `b49e65025` binary;
  - `base2/`: self-profiles;
  - `cmp/`: the interleaved old / new / THP runs;
  - `jobs2/`: the `--jobs` sweep and its traces;
  - `inst2/`: counter reports;
  - `perf2/`: `*.ins/cyc/pf.raw`, `ips*.a2l` and the scripts;
  - `inst-b49e.diff`;
  - `patch.pl`, `post.pl`, `med.pl`, `jobs/span.pl`;
  - `perf/` and `inst/`: the same at `b49e65025`.
