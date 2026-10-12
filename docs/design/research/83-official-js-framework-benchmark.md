# 83 — beni in the official js-framework-benchmark runner

*2026-10-12. The table app of `bench/ui/apps/beni`, entered as two keyed implementations
(`beni-tea`, `beni-direct`) and run through js-framework-benchmark's own runner, suite and results
app, next to six of its official entries: vanillajs, Solid, Svelte, React (hooks), Vue and Elm.
Nothing in the compiler, the runtimes or the platforms changed. Every figure is **[measured]** by
`bench/jfb/run.mjs` (§6) with the runner's default counts: 15 CPU runs per operation (25 for
`select`), one memory and one size run. **The machine was shared and loaded**: the 1-minute load
went past 24, which is more than the cores left outside the runner's `taskset`, in all three passes
(§1). Read §1 before any number.*

*2026-10-13: §7 re-runs four of the eight on a quiet machine, twice. Where §7 and §0–§4 disagree on
CPU time, §7 is the measurement.*

---

## 0. The answer

1. **On the official runner's own metric, beni is at the front of this field, within noise of
   vanillajs.** In the quietest pass (pass 3), the table's weighted geometric mean of the CPU
   benchmarks (`total` time, their default view) ranks **beni-tea 1.08, vanillajs 1.17,
   beni-direct 1.24**, Svelte 1.26, Solid
   1.47, Vue 1.47, Elm 1.76, React 1.84. That figure is the benchmark's official metric, reported
   as theirs. It is not a parity claim (CLAUDE.md rule 8), and beni-tea ranking above vanillajs is not
   evidence: it rests on two vanillajs cells that load reached (§2.1). The per-operation medians
   below are the evidence.
2. **Per operation, where the cells were measured at a quiet load, both beni entries are within
   10 % of vanillajs in `total` and ahead of every framework.** These are `replace`,
   `update10th`, `select`, `swap`, `remove` and `clear`, at load 4–10 (§2). On `create10k`, measured
   at load 4–7 for both beni entries, they are level with Solid and Svelte (642–667 ms) and ahead
   of Elm and React. The cells that load reached are named in §1.
3. **Memory and size do not depend on load, and they agree in all three passes.** By memory, beni
   is next after vanillajs: beni-direct is 1.06–1.14× vanilla's geometric mean and beni-tea
   1.11–1.18×, ahead of Solid (1.19–1.26×), Svelte, Elm, Vue and React. By size, beni-direct ships
   **4.4 kB** compressed, level with Solid's 4.5, and beni-tea 5.5. vanillajs is 2.5 and Svelte 9.7.
4. **Our harness ranks the same way, and its `script` figures agree with the runner's where both
   were quiet** (§3). beni and vanillajs are within the spread on most operations, and Solid 1 is
   behind both on every operation. The differences between the two harnesses are in method, and
   they move `total` far more than `script` (§3, §4).
5. **The official rules changed nothing in the app** (§5). Both entries pass `isKeyed` and the
   strict-CSP check, so neither needs a note. The one rule question is the labels: they come from a
   seeded generator rather than `Math.random`, which the rules do not address.

## 1. What ran, and the load

| | |
|---|---|
| benchmark | js-framework-benchmark `44f20790ba5c` (2026-10-04, "chrome 154 results": the commit that published the official Chrome 154 table), submodule `references/js-framework-benchmark` |
| runner | `webdriver-ts/dist/benchmarkRunner.js`, its default `puppeteer` runner, `--headless`, `--chromeBinary` the system Chrome; CPU 15 runs (`select` 15 + 10), memory 1, size 1 (`common.ts`'s defaults; no `--count`) |
| Chrome | **154.0.8037.97** (the published table used 154.0.8037.98, headed) |
| Node | v24.19.0, npm 11.17.0 |
| beni | `0.1.0-m1`, build id `521799b9…` (ReleaseSafe), `master` at `86d161d0b` |
| frameworks | `vanillajs`, `solid` (solid-js 1.9.3), `svelte` (5.42.1), `react-hooks` (React 19.2.0), `vue` (3.5.39), `elm` (0.19.1-6), each built by its own `npm ci && npm run build-prod`; `beni-tea`, `beni-direct` |
| machine | AMD Ryzen 9 5950X (16 cores, 32 threads), Linux 6.12; the runner and every Chrome it starts pinned to `taskset -c 8-15,24-31`, eight whole physical cores |

The repository has no Solid 2 entry, so Solid here is Solid 1.9.3, the official `solid`.

**Load.** Other agents were compiling and benchmarking on the same machine. Pinning gives the
runner its own cores but does not keep other processes off them. The 1-minute load average:

| pass | wall time | load at start → end | highest load seen | load above 24 during |
|---|---|---|---|---|
| 1 | 17:59–19:38 | 28.6 (18:06) → 6.7 | **33.2** (5-min avg, 18:33) | `run1k`, `update10th`, `select`, `create10k`, `append` (sampled by hand) |
| 2 | 19:38–20:59 | 5.0 → 5.8 | **41.1** (20:09) | `swap`, `remove`, `create10k`, part of `select` |
| 3 | 21:07–22:14 | 21.3 → 5.3 | **40.0** (22:02) | `run1k` (all, 15–31), `create10k` for vue (26), `clear` for elm and react (40); `append` for both beni entries at 17 |

In pass 3 every other cell ran at load 4–10, and most at 4–7. One exception at a lower load: vanillajs `create10k`
and `append` ran at load 9.6–10, and they are its two worst cells. **Every pass exceeded load 24,
so none of them is a quiet-machine measurement.** The coordinator decides whether to re-run on a
quiet machine; `run.mjs` reproduces it in one command. Each pass's `meta.json` holds its `uptime`
before and after. Pass 3 also holds a load sample per minute. In passes 1 and 2 the in-process
sampler was blocked by the runner's synchronous spawn, so their samples were taken by hand.

The runner runs every framework's 15 iterations of an operation back to back, and the frameworks
in alphabetical order. A load burst therefore lands on one framework's cell, not on all of them,
and the passes disagree for that reason. React's `swap` `total` is 1 078 ms in pass 1 and 265 in
pass 3. vanillajs's `remove` is 183 ms in pass 1 and 32.5 in pass 3. Pass 3 is the headline. Passes
1 and 2 are committed beside it and summarised in §2.4.

**Failures and retries.** The README's remedy for a failed (framework, benchmark) pair is to run
that pair again, and `run.mjs` does this up to twice. Pass 1 lost vanillajs `append` (a puppeteer
protocol timeout) and beni-tea `run-memory` (a detached frame). Pass 2 lost `select` for seven
frameworks (`Protocol error (IO.read)` while the trace was read at load 41). All of them passed on
their first retry. Pass 3 had no failures.

## 2. The table (pass 3)

The static table is their results app, built by `run.mjs` (§6): `bench/jfb/results/2026-10-12/pass3/report/`.
These tables are `bench/jfb/summary.mjs`'s, which reproduces the app's factor and weighted
geometric mean (`webdriver-ts-results/src/Common.ts`). A factor is a framework's median over the
smallest median in the table. The CPU weights are theirs; memory and size are unweighted.

### 2.1 CPU, `total` ms (click to the first paint after it), median [IQR], 15 runs

A cell marked † was measured at load above 15. The heading also gives the CPU throttling the
runner applies to that operation.

| framework | run1k | replace1k | update10th ×4 | select ×4 | swap ×4 | remove ×2 | create10k | append | clear ×4 | weighted geomean |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| **beni-tea** | 88.7† [78.2–144.9] | 63.8 [63.5–64.5] | 27.6 [25.9–28.3] | **5.4** [5.3–5.6] | **36.7** [34.8–39.5] | **30.2** [28.7–31.4] | **642.5** [639.9–645.4] | 71.4† [66.9–80.8] | **21.9** [21.0–24.6] | **1.08** |
| vanillajs | 61.3† [58.8–67.9] | **61.2** [59.8–64.6] | **25.2** [24.3–26.6] | 6.1 [5.7–7.0] | **36.7** [35.0–38.8] | 32.5 [31.7–34.7] | 922.3 [855.6–1203.7] | 138.4 [131.3–144.6] | 22.4 [21.4–23.9] | 1.17 |
| **beni-direct** | 100.4† [90.5–130.9] | 65.2 [63.6–68.3] | 25.4 [24.9–26.6] | 6.0 [5.4–6.3] | 38.6 [36.6–39.5] | 32.5 [29.3–35.6] | 653.9 [648.4–663.0] | 159.4† [90.7–263.4] | 22.7 [22.0–24.3] | 1.24 |
| Svelte | 96.6† [75.3–105.6] | 71.4 [69.5–73.9] | 33.1 [30.9–35.0] | 11.6 [10.8–14.5] | 43.7 [39.8–47.4] | 37.7 [36.4–39.7] | 666.8 [660.0–676.1] | 74.7 [69.5–132.1] | 27.0 [25.2–29.4] | 1.26 |
| Solid 1 | 194.1† [117.8–377.2] | 84.3 [73.9–88.0] | 31.7 [28.0–33.0] | 7.8 [6.8–10.5] | 47.9 [43.5–54.4] | 47.5 [44.0–51.5] | 664.9 [663.5–676.0] | 73.8 [71.5–76.4] | 32.3 [31.5–33.0] | 1.47 |
| Vue | 72.9† [70.7–75.6] | 80.3 [77.8–82.5] | 34.7 [33.6–37.5] | 7.6 [7.1–8.2] | 42.2 [39.5–44.3] | 34.9 [34.1–38.4] | 1767.9† [1698.0–2259.5] | 112.4 [78.3–119.0] | 33.6 [29.4–40.6] | 1.47 |
| Elm | 155.7† [133.6–173.8] | 81.8 [77.4–87.9] | 36.0 [33.1–39.7] | 11.2 [10.4–13.6] | 42.0 [40.5–56.1] | 38.9 [36.3–41.8] | 1012.2 [764.2–1023.3] | 88.3 [85.8–94.2] | 124.0† [50.5–146.9] | 1.76 |
| React | 191.6† [183.6–196.3] | 90.7 [83.2–98.2] | 36.8 [35.6–38.6] | 12.1 [11.2–13.2] | 265.3 [257.1–282.8] | 41.3 [39.7–52.3] | 1010.0 [990.0–1507.3] | 85.0 [82.3–87.5] | 62.6† [53.1–68.1] | 1.84 |

`run1k` ran entirely at load 15–31, and its medians follow the load, not the frameworks.
vanillajs's `create10k` and `append`, at load ≈ 10, are 1.4× and 1.9× the beni entries. The
other runs of the same code say that is load: published, vanillajs is the fastest on both (§2.5).
So the geometric mean's order of beni-tea before vanillajs is not evidence. On the six quiet
operations (`replace` through `remove`, and `clear`, at load 4–10), the beni entries are within
10 % of vanillajs in total: from 11 % faster (beni-tea `select`) to 9.5 % slower (beni-tea
`update10th`). Their IQRs overlap vanilla's on every one except beni-tea's `select`, which is
faster.

### 2.2 CPU, `script` ms, median [IQR]

| framework | run1k | replace1k | update10th | select | swap | remove | create10k | append | clear | weighted geomean |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| vanillajs | 4.80 | 8.70 | 0.70 | 0.50 [0.40–0.90] | 0.50 [0.15–0.80] | 0.60 | 67.0† | 10.20† | 19.40 | 1.19 |
| beni-tea | 8.00† | 9.80 | 1.50 | 0.50 [0.10–0.60] | 0.90 [0.80–1.10] | 0.40 | 53.40 | 6.00 | 19.10 | 1.26 |
| beni-direct | 8.70† | 9.70 | 1.00 | 0.50 [0.10–0.80] | 0.30 [0.10–0.70] | 0.50 | 54.00 | 11.90† | 19.50 | 1.32 |
| Solid 1 | 19.40† | 15.90 | 1.90 | 1.80 | 2.60 | 1.10 | 63.30 | 8.00 | 28.60 | 2.21 |
| Svelte | 12.30† | 15.30 | 2.20 | 5.40 | 3.00 | 1.40 | 71.20 | 9.10 | 23.70 | 2.31 |
| Elm | 34.10† | 21.00 | 6.80 | 3.60 | 3.20 | 2.10 | 134.20 | 17.30 | 108.80† | 4.71 |
| Vue | 16.50† | 22.90 | 4.90 | 2.40 | 2.80 | 6.70 | 350.00† | 22.20 | 30.50 | 4.77 |
| React | 44.40† | 31.30 | 8.80 | 6.20 | 40.50 | 3.40 | 361.20 | 18.40 | 58.70† | 6.86 |

Quartiles for every cell are in `summary.mjs`'s output. The script ordering at quiet load is
`vanillajs ≈ beni-tea ≈ beni-direct < Solid 1 < Svelte < Elm, Vue < React`. The exceptions are
beni's `update10th` (1.0–1.5 ms against vanilla's 0.7) and beni-tea's `swap` (0.9 against 0.5,
§4), and on both beni stays ahead of every framework.

### 2.3 Memory (MB) and size

| framework | ready | run 1k | 5× create/clear | geomean | uncompressed kB | brotli kB | first paint ms | geomean |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| vanillajs | 0.57 | 1.88 | 0.58 | 1.00 | 11.3 | 2.5 | 50.6 | 1.01 |
| **beni-direct** | 0.60 | 2.08 | 0.73 | **1.14** | 11.1 | **4.4** | 60.0 | 1.28 |
| **beni-tea** | 0.62 | 2.13 | 0.78 | **1.18** | 13.5 | 5.5 | 53.7 | 1.42 |
| Solid 1 | 0.60 | 2.68 | 0.77 | 1.26 | 11.5 | 4.5 | 52.1 | 1.24 |
| Svelte | 0.64 | 2.87 | 0.98 | 1.42 | 26.6 | 9.7 | 70.2 | 2.35 |
| Elm | 0.69 | 3.64 | 1.02 | 1.60 | 31.7 | 10.4 | 76.9 | 2.62 |
| Vue | 0.87 | 3.88 | 1.16 | 1.84 | 64.3 | 23.3 | 130.7 | 5.19 |
| React | 1.15 | 4.37 | 1.98 | 2.52 | 190.3 | 51.4 | 334.4 | 13.26 |

The size benchmark sums the bytes the server sends, brotli-compressed by the server, so beni's
figure is its own `--release` output. Research 73 measured beni-direct at 4 110 B after terser,
and terser is not part of the entry's build. First paint is a single run and moves with load:
beni-direct reads 76.7, 64.4 and 60.0 ms in the three passes.

### 2.4 The other two passes

| pass | CPU weighted geomean, `total` (best first) | memory geomean |
|---|---|---|
| 1 (load to 33) | beni-direct 1.24, vanilla 1.42, beni-tea 1.59, Vue 1.74, Solid 1.85, Svelte 2.05, React 2.17, Elm 2.27 | vanilla 1.00, direct 1.06, tea 1.11, Solid 1.21, Svelte 1.38, Elm 1.55, Vue 1.79, React 2.42 |
| 2 (load to 41) | vanilla 1.31, Vue 1.51, beni-direct 1.61, Solid 1.64, beni-tea 1.95, Svelte 2.07, React 2.19, Elm 2.20 | vanilla 1.00, direct 1.10, tea 1.14, Solid 1.19, Svelte 1.39, Elm 1.52, Vue 1.75, React 2.43 |
| 3 (§2.1) | beni-tea 1.08, vanilla 1.17, beni-direct 1.24, Svelte 1.26, Solid 1.47, Vue 1.47, Elm 1.76, React 1.84 | vanilla 1.00, direct 1.14, tea 1.18, Solid 1.26, Svelte 1.42, Elm 1.60, Vue 1.84, React 2.52 |

The CPU order changes from pass to pass because load landed on different frameworks' cells. In
pass 2, beni-direct's `create10k` was 2 810 ms against 654 in pass 3, and its `script` was 307 ms
against 54. In every pass beni and vanillajs are the top two or three, and React and Elm are last.
The memory order is the same in all three passes.

### 2.5 Against the published Chrome 154 table

The repository ships the published run (`webdriver-ts/results.json`), headed, on the maintainer's
quiet machine, from the same versions of the six frameworks. Its `total` figures are 2–3× below
ours: vanillajs `run1k` is 20.6 ms against 61.3, and `swap` 11.0 against 36.7. Research 29 §1.5
gave the cause. Headless Chrome rasterises in software, and the paint phases dominate `total`.
Published `script` is also about 2.5× below ours (vanillajs `run1k` 1.80 against 4.80), which
makes theirs a faster CPU. In the published table the order of the six is vanilla 1.00, Solid
1.08, Svelte 1.13, Vue 1.25, React 1.53, Elm 1.55. Ours (pass 3) orders the same six Svelte, Solid = Vue, Elm, React, with
vanillajs first. Their IQRs are ±1 %; ours are ±5–30 %
at quiet load. **Our numbers are not comparable with the published ones in absolute terms, only
within one batch.**

## 3. Against our own harness (research 70, 73)

`bench/ui/bench.mjs` ports this runner's measurement rule, `timeline.ts`, at commit `652198560d`.
Between that commit and the pinned one, `webdriver-ts/src` changed only its port handling, so the
rule is the same code. Research 73 §2 (n = 5, load 2–8) against pass 3 here, `script` ms medians:

| op | vanilla (ours / official) | beni-direct | beni-tea | Solid 1 |
|---|---|---|---|---|
| run1k | 4.15 / 4.80 | 4.47 / 8.70† | 4.35 / 8.00† | 4.68 / 19.4† |
| replace1k | 8.96 / 8.70 | 9.86 / 9.70 | 10.5 / 9.80 | 10.9 / 15.9 |
| update10th | 1.00 / 0.70 | 0.70 / 1.00 | 1.47 / 1.50 | 1.57 / 1.90 |
| select | 1.27 / 0.50 | 0.85 / 0.50 | 0.68 / 0.50 | 1.83 / 1.80 |
| swap | 0.66 / 0.50 | 0.11 / 0.30 | 0.88 / 0.90 | 1.50 / 2.60 |
| remove | 0.52 / 0.60 | 0.12 / 0.50 | 0.45 / 0.40 | 0.52 / 1.10 |
| create10k | 41.2 / 67.0† | 45.4 / 54.0 | 43.0 / 53.4 | 49.4 / 63.3 |
| append | 4.27 / 10.2† | 4.21 / 11.9† | 4.34 / 6.00 | 4.70 / 8.00 |
| clear | 18.3 / 19.4 | 19.2 / 19.5 | 19.1 / 19.1 | 17.3 / 28.6 |

**The two harnesses agree on the ranking.** beni and vanillajs are within the spread of each
other, and Solid 1 is behind beni on every quiet operation in both. On the quiet cells the
absolute figures agree to within the spread: `replace`, `update10th`, `swap`, `remove` and
`clear` are within a few tenths of a millisecond. One disagreement is at quiet load: `create10k`
is 54 ms here against 43–45 in research 73, for both beni entries. Where they differ, the official
runner differs in five ways.

- **A new browser per batch, not a new tab in one browser.** The runner starts Chrome once per
  (framework, operation), with a fresh profile, and runs its 15 iterations in new tabs. Ours keeps
  one Chrome for the whole run. The first iterations of a batch here meet a cold browser, which is
  one candidate for the `create10k` gap. This is not verified.
- **No rotation.** A framework's 15 iterations run back to back, so load lands on whole cells (§1).
  Ours rotates the subjects every iteration.
- **The V8 sampling profiler is on while the click is traced.** The puppeteer runner adds
  `disabled-by-default-v8.cpu_profiler` to the trace categories. Our port copies the
  `webdriverCDP` runner's three categories, which do not include it. Sampling costs every
  JavaScript call stack, so it inflates `script`, which is a second candidate for the gap. This is
  not measured either.
- **Throttling.** The runner sets the rate before tracing starts and forces a full, synchronous
  major GC (`gc({type:'major',execution:'sync',flavor:'last-resort'})`) before the click. Ours
  calls `gc()`.
- **15 runs and the median** (25 for `select`), against our 5–10. The table app shows the median
  by default and the mean with a 95 % interval on request.

**The swap.** Research 84 found the swap's `script` bimodal for every subject because of Chrome's
CPU throttler, which interrupts the main thread about every 200 µs at 4×. The official runner
throttles `swap` at 4× in the same way and does nothing about it. The IQRs show it: vanillajs
0.15–0.80 ms, beni-direct 0.10–0.70. With 15 samples the median lands in either mode. The table's
headline is `total`, though, and there the swap is 36–48 ms of style, layout and paint for every
framework except React (`bench/jfb/phases.mjs 05_swap1k`). Measured at quiet load, beni-direct is
16.8 ms of Layout against vanilla's 15.2, and the bimodal 0.5 ms of script does not show at that
scale. So in their metric the swap ranks frameworks by how many rows they move, as the published
table does: React 265 ms, everyone else 37–48. It does not rank them by the throttler's mode.

## 4. Two things worth a second look

- **beni-tea's `swap` script is 0.9 ms against beni-direct's 0.3 and vanilla's 0.5**, in this
  runner as in ours (0.88 / 0.11 / 0.66). It is research 73's known `browser-tea` cost, not new.
- **beni-direct's `append` is bimodal**: pass 3's IQR is 90.7–263.4 ms `total` and 7.65–19.05 ms
  `script`. That cell ran at load 17, so this pass cannot say whether it is load. In passes 1 and 2
  the same cell read 154 and 74 ms. Research 73 measured 4.21 ms of script at n = 5. Worth one
  quiet re-run before anyone reads a cause into it.

## 5. The rules, and what they changed

The entries live in `bench/jfb/frameworks/keyed/{beni-tea,beni-direct}`. `run.mjs` copies them into
the work tree, so the submodule stays clean. Each entry is `index.html`, `package.json` (with the
`js-framework-benchmark` block, `frameworkVersion` filled in from `beni version`), a
dependency-free `package-lock.json`, and `build-prod`: `node build.mjs <platform>`, which is
`beni build --platform=<platform> --release --no-source-maps --out=dist src/Main.beni`.
`src/Main.beni` is a symlink to `bench/ui/apps/beni/Main.beni`, so both harnesses build the same
program.

- **Keyed**: `npm run isKeyed` passes for both, keyed for run, remove and swap. `run.mjs` runs
  `isKeyed` on the beni entries only, and takes the official entries as correct at the pinned
  commit. `isCSPCompliant` checks every framework in the work tree, and no official entry fails
  it in a way that contradicts its declared notes.
- **HTML**: the rows are vanillajs's markup with `class=""` on the `<tr>`, as Solid's are. The
  structure check in `isKeyed` (`checkTRcorrect`) passes. The page has no `<div id="main">`,
  because `Tea.sandbox` mounts at `document.body`. Elm's entry also renders its own container, and
  the rules check only the table.
- **Strict CSP** (note 1139): both pass `isCSPCompliant`, so neither declares the note. Elm fails
  it and declares it.
- **Notes 772, 796, 800, 801, 1261**: none applies. The app does no DOM work of its own, no
  `requestAnimationFrame`, keeps one `selected` id in the model, and delegates no events itself
  (the runtime does, which the rules allow).
- **Labels** come from a seeded Park–Miller generator in the model (`Main.beni`'s comment says
  why). The rules ask for "randomized entries" and say nothing against a fixed seed. The label
  sequence is the same on every page load, which a `Math.random` entry's is not. It is noted here
  and left as it is (rule 10).
- **Not the framework's concern, but run differently**: the root package's lock does not install
  under npm 11, so `run.mjs` starts the server from `server/`, which is what the root's `npm start`
  does. The Elm entry's `build-prod` calls a globally installed `elm-tooling`, so a shim runs
  `npx elm-tooling@1.21.0`. npm 11 skips dependency install scripts without an allowScripts
  policy, and `elm-tooling install` puts the `elm` binary where that script would have.
- **Not run**: the Lighthouse startup benchmark (`30_startup`). It is defined but left out of
  `benchmarkInfos` at this commit, so the published table does not have it either.

## 6. Reproducing

```sh
zig build -Doptimize=ReleaseSafe                       # zig-out/bin/beni
node bench/jfb/run.mjs --taskset=8-15,24-31            # all eight, the full default suite, about 70 min quiet
node bench/jfb/run.mjs --report-only --out=bench/jfb/results/2026-10-12/pass3   # the table again, from raw/
node bench/jfb/summary.mjs bench/jfb/results/2026-10-12/pass3                     # §2's tables
node bench/jfb/phases.mjs 05_swap1k                    # §3's phase split, from the last run's traces
```

`bench/jfb/results/2026-10-12/pass{1,2,3}/` hold `raw/`, the runner's own result files, plus
`results.json` from `createResultJS` and `meta.json` (versions, `taskset`, `uptime` before and
after, load, retried pairs). The built table, `report/`, is about 840 kB of minified React app,
so it is not committed. `--report-only` rebuilds it from `raw/`, and it is served from any static
server: `npx http-server bench/jfb/results/2026-10-12/pass3/report`.

## 7. The quiet re-run (2026-10-13, azathoth)

*The same runner, suite, Chrome binary and entries as §1, run twice on a second machine that ran
nothing else. By the owner's instruction it runs four frameworks: vanillajs, Solid 1.9.3,
beni-direct and beni-tea. Svelte, React, Vue and Elm are in the 2026-10-12 run on dagon only (§2), so
this section says nothing about where they stand on a quiet machine. Every figure is **[measured]**
with the runner's default counts (no `--count`).*

### 7.1 What ran, and the load

| | |
|---|---|
| machine | azathoth: Intel Xeon E-2386G, 6 cores and 12 threads (CPU *n* and *n*+6 share a core), 31 GB, NixOS, Linux 6.18.55, governor `powersave` with turbo, left as configured |
| benchmark | js-framework-benchmark `44f20790ba5c`, as §1 |
| Chrome | **154.0.8037.97**, dagon's own Nix store path (`/nix/store/ds7933z0…-google-chrome-154.0.8037.97`) copied with `nix copy`, headless |
| Node | v24.19.0, npm 11.17.0, from `nix develop` |
| beni | `zig build -Doptimize=ReleaseFast` at `161eae05`. Both entries' `_main.mjs` are **byte-identical** to the output of `86d161d0b`, §1's commit (checked by building both on azathoth), so the pages are the ones dagon measured |
| pinning | `--taskset=1-5,7-11` |
| results | `bench/jfb/results/2026-10-13-azathoth/pass{1,2}/` (`raw/`, `results.json`, `meta.json`) |

**The pinning.** The runner and every Chrome it starts get physical cores 1–5 with both of their
threads. Core 0 (CPUs 0 and 6) is left to the OS, `run.mjs`, the benchmark's server and the load
sampler. Pinning to one thread per core (CPUs 1–5) was the alternative. It was not chosen because
it gains nothing on an idle machine. The scheduler puts runnable threads on idle cores before it
doubles them up on siblings, and the benchmark has only a few busy threads at a time: the renderer's
main thread, the compositor, raster and the browser process. Whole cores is also what dagon used
(`8-15,24-31`). The IQRs below are ±1 % on most cells, so the pinning added no noise that shows.

| pass | wall time | load at start → end | highest 1-minute load | retries |
|---|---|---|---|---|
| 1 | 00:07–00:38 (1 842 s) | 0.41 → 1.42 | **1.33** | none |
| 2 | 00:38–01:09 (1 848 s) | 1.38 → 0.09 | **1.23** | none |

The load was sampled once a minute (`meta.json`'s `load`). It stayed between 0.1 and 1.4, on 12
threads, for the whole of both passes. An earlier pass with all eight frameworks was stopped after
53 minutes, when the owner narrowed the field. Its partial results were discarded and are not in
the tables.

### 7.2 CPU, `total` ms, median [IQR], 15 runs (25 for `select`)

Pass 1, then pass 2. The weighted geometric mean is the table's own (§2), over these four.

| framework | run1k | replace1k | update10th | select | swap | remove | create10k | append | clear | weighted geomean |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| vanillajs | 45.7 [45.5–45.8] | 50.0 [49.7–50.2] | 24.1 [23.8–24.3] | 5.5 [5.3–5.7] | 27.6 [27.4–28.0] | 24.5 [24.4–24.8] | 476.1 [475.5–479.1] | 53.7 [53.5–54.2] | 18.0 [17.1–18.2] | **1.01** |
| beni-direct | 46.6 [46.5–47.1] | 51.2 [50.9–51.6] | 24.8 [24.6–24.9] | 5.4 [5.2–5.6] | 28.9 [28.6–29.3] | 24.4 [24.3–24.7] | 498.3 [497.7–500.4] | 54.5 [54.3–54.6] | 17.3 [17.0–18.0] | **1.02** |
| beni-tea | 46.8 [46.7–47.0] | 52.1 [51.8–52.5] | 25.3 [25.0–25.9] | 5.7 [5.6–5.9] | 30.0 [29.9–30.4] | 24.4 [24.1–24.5] | 499.0 [497.3–502.1] | 54.4 [54.2–54.6] | 17.7 [17.4–18.1] | **1.03** |
| Solid 1 | 48.6 [48.3–48.8] | 53.8 [53.6–54.2] | 26.0 [25.6–26.4] | 7.0 [6.8–7.2] | 30.7 [30.0–31.0] | 25.0 [24.9–25.4] | 510.2 [506.4–522.1] | 56.4 [56.2–56.8] | 20.8 [20.2–22.9] | **1.09** |

| framework | run1k | replace1k | update10th | select | swap | remove | create10k | append | clear | weighted geomean |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| vanillajs | 45.7 [45.6–45.8] | 49.7 [49.5–49.9] | 23.9 [23.8–24.5] | 5.5 [5.3–5.8] | 27.3 [27.1–27.8] | 24.5 [24.4–24.8] | 477.0 [474.9–478.3] | 53.7 [53.5–53.9] | 17.3 [17.1–18.1] | **1.00** |
| beni-direct | 46.5 [46.3–46.6] | 51.0 [50.8–51.0] | 24.8 [24.3–25.2] | 5.5 [5.3–5.6] | 28.8 [28.7–29.1] | 24.5 [24.4–24.6] | 499.0 [496.3–500.4] | 54.6 [54.3–54.7] | 17.7 [17.5–18.1] | **1.02** |
| beni-tea | 47.0 [46.8–47.4] | 51.9 [51.6–52.5] | 25.4 [25.2–25.6] | 5.5 [5.3–5.8] | 30.2 [29.7–30.6] | 24.4 [24.3–24.5] | 496.4 [493.9–498.5] | 54.4 [54.2–54.7] | 17.7 [17.3–18.3] | **1.03** |
| Solid 1 | 48.9 [48.5–49.2] | 53.8 [53.6–55.2] | 26.1 [25.8–26.2] | 7.2 [7.0–7.4] | 30.6 [30.3–30.9] | 24.9 [24.8–25.1] | 522.1 [509.1–524.2] | 56.5 [56.3–56.8] | 20.6 [20.1–23.1] | **1.09** |

As a ratio to vanillajs's median, pass 1 / pass 2:

| | run1k | replace1k | update10th | select | swap | remove | create10k | append | clear |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| beni-direct | 1.02 / 1.02 | 1.02 / 1.03 | 1.03 / 1.04 | 0.98 / 1.00 | 1.05 / 1.06 | 1.00 / 1.00 | 1.05 / 1.05 | 1.02 / 1.02 | 0.96 / 1.02 |
| beni-tea | 1.02 / 1.03 | 1.04 / 1.04 | 1.05 / 1.06 | 1.04 / 1.00 | 1.09 / 1.11 | 1.00 / 1.00 | 1.05 / 1.04 | 1.01 / 1.01 | 0.98 / 1.02 |
| Solid 1 | 1.06 / 1.07 | 1.08 / 1.08 | 1.08 / 1.09 | 1.27 / 1.31 | 1.11 / 1.12 | 1.02 / 1.02 | 1.07 / 1.10 | 1.05 / 1.05 | 1.16 / 1.19 |

### 7.3 `script` ms, memory and size

| framework | run1k | replace1k | update10th | select | swap | remove | create10k | append | clear | weighted geomean (p1 / p2) |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| vanillajs | 3.60 | 7.00 | 0.90 | 0.60 [0.50–0.70] | 0.10 [0.10–0.65] | 0.60 | 35.20 | 3.80 | 14.40 | 1.11 / 1.15 |
| beni-direct | 3.90 | 7.50 | 0.90 | 0.20 [0.10–0.50] | 0.40 [0.10–0.50] | 0.40 | 41.30 | 4.20 | 14.60 | 1.11 / 1.14 |
| beni-tea | 4.00 | 8.10 | 1.50 | 0.70 [0.20–0.80] | 1.20 [0.95–1.20] | 0.50 | 40.00 | 4.20 | 14.80 | 1.36 / 1.39 |
| Solid 1 | 5.60 | 10.40 | 2.00 | 1.30 | 1.70 | 0.80 | 49.30 | 5.80 | 17.60 | 1.85 / 1.85 |

These are pass 1's medians. Pass 2's are within 0.3 ms of them, except on the sub-millisecond
`select` and `swap` cells, whose quartiles span the throttler's two modes (§3, *The swap*).

| framework | ready MB | run 1k MB | 5× create/clear MB | geomean (p1 / p2) | uncompressed kB | brotli kB | first paint ms (p1 / p2) |
|---|--:|--:|--:|--:|--:|--:|--:|
| vanillajs | 0.53 | 1.87 | 0.62 | 1.00 / 1.01 | 11.3 | 2.5 | 86.5 / 86.8 |
| beni-direct | 0.60 | 2.08 | 0.75 | 1.15 / 1.08 | 11.1 | 4.4 | 44.0 / 62.9 |
| beni-tea | 0.62 | 2.13 | 0.79 | 1.19 / 1.13 | 13.5 | 5.5 | 51.2 / 61.9 |
| Solid 1 | 0.59 | 2.69 | 0.77 | 1.26 / 1.21 | 11.5 | 4.5 | 85.0 / 75.7 |

Memory and size are pass 1's. First paint is one run per pass. vanillajs reads 86 ms in both
passes here and 50.6 on dagon, so the figure is not read as a ranking.

### 7.4 Pass to pass

The largest change in any `total` median between the two passes is 4.0 % (vanillajs `clear`,
18.0 → 17.3 ms). The next are the 5–7 ms `select` cells (beni-tea 3.6 %, Solid 2.9 %), where
0.2 ms is one step of the trace's resolution. Every other cell moved by 2.3 % or less. The weighted geometric means moved by
at most 0.01, and the order is the same in both passes: **vanillajs, beni-direct, beni-tea,
Solid 1**. Most IQRs are under ±1 % of the median, against ±5–30 % on dagon at its quietest
(§2.5). The published table's are ±1 %, so this is the variance of a quiet machine.

### 7.5 What held from the dagon run, and what did not

- **"beni-tea ahead of vanillajs" (§0 item 1) did not hold.** On the quiet machine vanillajs is
  first, at 1.00–1.01, in both passes. beni-tea's lead on dagon came from vanillajs's `create10k`
  (922 ms) and `append` (138 ms), measured at load ≈ 10. Quiet, vanillajs is 476 and 54 ms, the
  fastest of the four on both. §2.1 already said not to read that order as evidence. This run
  shows it was load.
- **"Within 10 % of vanillajs in `total`" (§0 item 2) held, and is tighter.** beni-direct is
  between 4 % ahead of vanillajs and 6 % behind it on every operation in both passes, the extremes
  being `clear` and `swap`. beni-tea is 0–11 % behind, and its widest gap is `swap` (+9–11 %), which is
  §4's known `browser-tea` cost. Over the table's metric the two are 2 % and 3 % behind vanillajs.
- **"Ahead of every framework" held for the one framework this run measured.** Both beni entries
  have a lower median than Solid 1.9.3 on every operation in both passes, and a lower weighted
  geomean (1.02–1.03 against 1.09). On `remove` (24.4 against 24.9–25.0) and beni-tea's `swap`
  (30.0–30.2 against 30.6–30.7) the margin is about one IQR, and pass 2's quartiles overlap on
  `swap`, so those two are level. On `select` and
  `clear`, Solid is 16–31 % behind vanillajs and 15–30 % behind beni.
- **`create10k`: dagon had beni level with Solid and Svelte. Here beni is ahead of Solid 1 by
  2–5 % and 5 % behind vanillajs.** In `script`, beni is 17 % behind vanillajs on it (41.3 ms
  against 35.2), where dagon's loaded pass 3 put beni ahead (53.4 against 67.0†). The quiet figure
  is the one that stands, and it is the largest `script` gap between beni-direct and vanillajs in
  the suite.
- **The `script` ordering held**: vanillajs ≈ beni-direct (1.11–1.15, level), then beni-tea
  (1.36–1.39), then Solid 1 (1.85). The two exceptions §2.2 named are still there: beni-tea's
  `update10th` (1.4–1.5 ms against 0.8–0.9) and its `swap`.
- **beni-direct's bimodal `append` (§4) was load.** Quiet, it is 54.5 ms [54.3–54.6] and
  54.6 [54.3–54.7], level with vanillajs.
- **Memory and size held exactly.** The memory order is vanillajs, beni-direct, beni-tea, Solid 1,
  as in all three dagon passes, at the same geometric means within 0.07. Sizes are the same bytes.
- **Against the published table**: there, Solid 1.9.3 is 1.08 of vanillajs over this suite, and here
  it is 1.08 in both passes (1.09 / 1.01 and 1.09 / 1.00). The absolute figures are 2.1–2.3× above
  the published ones (vanillajs `run1k` 45.7 ms against 20.6), from headless software
  rasterisation (§2.5) and different hardware. So this run reproduces the published *relative*
  standing of the two frameworks they share.

### 7.6 What can be claimed

On a quiet machine, in js-framework-benchmark's own runner, headless Chrome 154, with the runner's
default counts and two passes that agree to within 4 %:

- by the official weighted geometric mean of `total`, **vanillajs 1.00, beni-direct 1.02, beni-tea
  1.03, Solid 1.9.3 1.09**;
- per operation, beni-direct is between 4 % ahead of vanillajs and 6 % behind it, and beni-tea
  between 2 % ahead and 11 % behind. Both are ahead of Solid 1.9.3 on seven of nine operations
  and level with it on `remove`; beni-tea is also level on `swap`;
- by memory, beni is between vanillajs and Solid; by brotli size, beni-direct is level with Solid.

What cannot be claimed:

- that beni is faster than vanillajs. Where its median is lower (`select`, `remove`, `clear` in
  one pass), the difference is inside the IQRs and does not repeat in the other pass;
- where Svelte, React, Vue or Elm stand on a quiet machine. They were not run here, and their
  dagon figures are contaminated by load (§1);
- anything about Solid 2. The benchmark has no Solid 2 entry, and rule 8's bar is Solid 2;
- absolute milliseconds against the published table, or against dagon. The hardware differs, and
  the published run is headed;
- that the order holds headed, with GPU rasterisation, where paint is a smaller share of `total`.
  `script` is the closer guide to that, and there beni-direct is level with vanillajs and beni-tea
  between it and Solid.

### 7.7 Reproducing

The checkout on azathoth is `~/src/github.com/canassa/beni` (at `161eae05`, with its work tree in
`bench/jfb/work/`). From a clone, with `nix develop`:

```sh
zig build -Doptimize=ReleaseFast
node bench/jfb/run.mjs --frameworks=vanillajs,solid,svelte,react-hooks,vue,elm,beni-tea,beni-direct \
    --chrome=$CHROME --skip-run                              # installs and builds, once
node bench/jfb/run.mjs --frameworks=vanillajs,solid,beni-tea,beni-direct --chrome=$CHROME \
    --taskset=1-5,7-11 --skip-install --skip-build \
    --out=bench/jfb/results/2026-10-13-azathoth/pass1        # 31 min
node bench/jfb/summary.mjs bench/jfb/results/2026-10-13-azathoth/pass1
```

Setup on a fresh NixOS machine took about 15 minutes: the clone with only the
`js-framework-benchmark` submodule, `nix develop`, a 285 s ReleaseFast build, and the npm installs.
Nothing in the machine's configuration changed.
