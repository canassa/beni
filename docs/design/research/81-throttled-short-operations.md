# 81 — Why `swap` is bimodal: Chrome's CPU throttler, not the DOM

*2026-10-12. Research 73 §2 found the table app's `swap` bimodal for every subject, vanilla
included: a sample takes ≈ 0.11 ms or ≈ 0.4–1.0 ms of `script`, so its median depends on which
mode most samples land in. This note finds the cause and proposes how to measure short operations.
All figures are **[measured]** with `bench/ui/swap-modes.mjs` (§5); nothing in the compiler,
the runtimes or the platforms changed.*

---

## 0. The answer

**The slow mode is DevTools' CPU throttling, and it makes no DOM call slower.** On POSIX, Chrome's
`ThreadCPUThrottler` sends the renderer's main thread `SIGUSR2` about every 200 µs. The signal
handler busy-waits for (rate − 1) × the wall time since it last returned, capped at 1 000 µs
([`thread_cpu_throttler.cc` L129–L167](https://github.com/chromium/chromium/blob/6d5b18ed9b34bbae153c57735ff301d272d173bf/third_party/blink/renderer/platform/scheduler/common/thread_cpu_throttler.cc#L129-L167)).
At 4× a click handler runs in a window of up to ≈ 250 µs between two such pauses. If no signal
lands while the handler runs, the trace sees its real cost. If one does, the trace also counts a
busy-wait of 3 × that window, 0.3–0.8 ms. The pause is not a trace event, so research 73's traces
put the time "inside `insertBefore`": that is where the thread was when the signal came.

Under this mechanism the **mean** at rate R estimates R × the real cost. A sample is hit with
probability c / w (c the handler's cost, w its window) and the hit costs (R − 1) × w, so the
expected extra time is (R − 1) × c. In §1–§2 the 4× means are 4.1–4.9× the 1× means. For the swap,
vanilla and direct lie within their ±0.08–0.12 ms intervals of 4×, but P3 (4.9×) does not, so
the model is approximate. The **median** has no such property. Once c is near half a
window, the median jumps from about c to about c + 3w. Every throttled operation under ≈ 1 ms of
script is therefore affected: `swap`, `remove`, `select` and `update10th`.

## 1. Reproduction, and the hypotheses

`script` in ms, n = 30 per condition, every condition in one batch, rotated each iteration. Chrome
154 headless, `--taskset=24-31`, load 10.0 at the start and 4.8 at the end. A sample is *fast*
when it is within 0.15 ms of its condition's minimum.

| condition | median | mean | p25–p75 | fast | fast median | slow median |
|---|--:|--:|--:|--:|--:|--:|
| vanilla swap @4 | 0.536 | 0.521 | 0.169–0.736 | 9 / 30 | 0.118 | 0.684 |
| direct swap @4 | 0.504 | 0.490 | 0.123–0.731 | 10 / 30 | 0.114 | 0.702 |
| P3 swap @4 | 0.641 | 0.612 | 0.534–0.745 | 3 / 30 | 0.111 | 0.651 |
| vanilla swap **@1** | **0.108** | 0.109 | 0.098–0.118 | 30 / 30 | — | — |
| direct swap **@1** | **0.118** | 0.119 | 0.113–0.126 | 30 / 30 | — | — |
| P3 swap **@1** | **0.122** | 0.125 | 0.115–0.128 | 30 / 30 | — | — |
| vanilla swap @2 | 0.330 | 0.273 | 0.113–0.374 | 12 / 30 | 0.109 | 0.366 |
| vanilla, swap without warm-up @4 | 0.863 | 0.836 | 0.724–0.958 | 1 / 30 | 0.250 | 0.867 |
| one `insertBefore` of adjacent rows @4 | 0.720 | 0.692 | 0.533–0.835 | 3 / 30 | 0.173 | 0.738 |
| **empty listener @4** | **0.438** | 0.418 | 0.084–0.663 | **11 / 30** | 0.079 | **0.631** |
| pure-JS loop, no DOM @4 / @1 | 1.286 / 0.265 | 1.257 / 0.276 | | 2 / 29 of 30 | | |

- **Throttling (supported).** Unthrottled, the swap is unimodal for all three subjects, with an
  IQR of about 0.02 ms. An empty listener at 4× has the same two modes as the swap: 0.08 ms and
  0.63 ms. At 2× the slow mode's excess is 0.21–0.29 ms, against 0.34–0.82 ms at 4×, about
  (R − 1) / 3 of it, as the handler's formula predicts.
- **Style or layout forced inside `insertBefore` (refuted).** None of the 840 traced clicks in
  this note held a `Layout` or `UpdateLayoutTree` event. An empty listener is just as bimodal.
- **Which rows move (refuted as a cause of the split).** Moving adjacent rows (one
  `insertBefore`) is bimodal too. Its fast mode is 0.17 ms, so the 2/999 distance is not where
  the cost lies.
- **The state left by the previous step (refuted as the cause; it changes the cost).** Without
  the five warm-up swaps the first swap costs 0.25 ms when fast: the code is cold. It is still
  bimodal. The fast/slow sequence over iterations has no period
  (vanilla `ssssFFFssFsFssssssFsFsFssssFss`).
- **JIT tiering, GC (refuted as the cause).** A loop of pure JavaScript with no DOM and no
  allocation shows the same penalty: its 4× minimum is 3.1 × its 1× median, and its slow samples
  add 0.2–1.2 ms more.

## 2. Every short throttled operation, at its official rate and at 1×

`script` median [p25–p75] in ms, n = 20, one batch, load 4.7–6.6.

| operation | rate | vanilla | direct | P3 |
|---|--:|--:|--:|--:|
| `update10th` | 4 | 1.18 [1.01–1.31] | 1.23 [1.07–1.53] | **0.98** [0.81–1.10] |
| `update10th` | 1 | **0.234** [0.223–0.306] | 0.277 [0.260–0.298] | 0.241 [0.228–0.270] |
| `select` | 4 | 1.78 [1.16–1.94] | **1.10** [1.02–1.30] | 1.60 [1.47–1.78] |
| `select` | 1 | 0.357 [0.334–0.390] | **0.270** [0.251–0.288] | 0.380 [0.335–0.404] |
| `remove` | 2 | 0.606 [0.550–0.746] | **0.379** [0.315–0.414] | 0.396 [0.170–0.426] |
| `remove` | 1 | 0.316 [0.289–0.339] | **0.139** [0.131–0.150] | 0.174 [0.163–0.185] |

The throttled medians change the subjects' order. At 4× `update10th` puts P3 first and vanilla
second; unthrottled, vanilla is first and lean direct is **1.18× vanilla**. Research 73 §2 read
0.70× from n = 5 throttled medians. The throttled means stay within ≈ 4.1–4.4× (`remove`: within
1.9–2.5× at its official 2×) of the unthrottled ones, as §0 predicts. Research 73's 4× figures
for `swap`, `update10th`, `select` and `remove` therefore should not be read as rankings. Its
`select` and `remove` orderings among direct, vanilla and P3 survive at 1×; its `update10th`
ordering does not.

## 3. What js-framework-benchmark does

- It throttles `update10th`, `select`, `swap` and `clear` at 4× and `remove` at 2×
  ([`benchmarksCommon.ts` L105–L111](https://github.com/krausest/js-framework-benchmark/blob/bf894b681fb56433ccb6efb4a3c93e35eda2b20d/webdriver-ts/src/benchmarksCommon.ts#L105-L111)).
  It takes 15 samples per CPU benchmark and drops none
  ([`common.ts` L69–L70](https://github.com/krausest/js-framework-benchmark/blob/bf894b681fb56433ccb6efb4a3c93e35eda2b20d/webdriver-ts/src/common.ts#L69-L70)).
  The results page shows the **median of `total`** (click to paint) by default; mean, `script`
  and `paint` are options
  ([`store.ts` L223, L232](https://github.com/krausest/js-framework-benchmark/blob/bf894b681fb56433ccb6efb4a3c93e35eda2b20d/webdriver-ts-results/src/store.ts#L223-L232)),
  with a 95 % interval of 1.96 · sd / √n
  ([`Common.ts` L462](https://github.com/krausest/js-framework-benchmark/blob/bf894b681fb56433ccb6efb4a3c93e35eda2b20d/webdriver-ts-results/src/Common.ts#L462)).
  For `swap`, `total` is ≈ 36 ms, so the throttler's ≤ 0.8 ms coin toss is ≤ 2 % of the headline
  figure. Our harness reads `script`, where the same coin toss is 3–7× the operation.
- Throttling was introduced because select and swap were "too fast" to separate
  ([#451](https://github.com/krausest/js-framework-benchmark/issues/451),
  [#424](https://github.com/krausest/js-framework-benchmark/issues/424)). In #424 the owner
  observed that more iterations did not reduce the variance of the short benchmarks. In
  [#633](https://github.com/krausest/js-framework-benchmark/issues/633) he notes that throttled
  results vary a lot between operating systems. The Windows throttler suspends the thread in
  fixed slices rather than through a signal. None of the issues found
  (`gh search issues` for swap, variance, throttling) names the signal handler's lumpiness.

## 4. Protocol for operations under ≈ 1 ms of script

1. **Primary figure: `script` unthrottled (rate 1)**, median and IQR, n ≥ 20, every subject in
   one batch. It measures the code with the throttler removed for every subject alike. The
   spreads are ±0.01–0.03 ms, against ±0.3 ms at 4×.
2. **When a throttled figure is wanted** (to compare with js-framework-benchmark's published
   tables), report the **mean with its 95 % interval** and the fast/slow counts, never the
   median. With sd ≈ 0.2–0.33 ms per sample at 4×, telling two subjects 0.05 ms apart at 95 % takes
   n ≈ 140–330 per subject; at n = 30 the swap means' intervals are ±0.08–0.12 ms.
3. Do not quote a throttled `script` median below ≈ 1 ms as a ranking. `total`, which
   js-framework-benchmark shows by default, is not distorted the same way.

No rule here favours one subject: rate 1 is the same machine for everyone, and it ranks beni
below vanilla on `swap` (0.118 against 0.108) and `update10th`, where the 4× medians had ranked
it ahead.

## 5. Commands

From `bench/ui/`, `CHROME=google-chrome`, after `node build.mjs --no-solid`:

- `node swap-modes.mjs --n=30 --taskset=24-31 --out=results/2026-10-12-swap-modes/modes.json`
  (7 min; §1);
- `node swap-modes.mjs --others=06_remove-one-1k,04_select1k,03_update10th1k_x16 --n=20
  --taskset=24-31 --out=results/2026-10-12-swap-modes/others.json` (6 min; §2);
- `node swap-modes.mjs --report=results/2026-10-12-swap-modes/modes.json` prints a batch's table.
