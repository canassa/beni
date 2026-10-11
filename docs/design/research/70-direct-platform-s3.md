# 70 — The direct platform, slice S3: the table app, and kill criterion 5

*2026-10-11. What `browser-direct.md` §14's slice S3 built and what it measured against §13's
kill criterion 5 and its P3 criterion. S3 is the reconciler, the identity walk and the filter
merge, the selector and the key map, helpers and components written in place under the size
gate with shared sites past it, `Html.map` composed at compile time with the dispatcher behind
it, and the fixtures `browser-direct.md`'s *Amended 2026-10-10 (slice S3, as specified)* lists.
The building-loop rule §14 also gave S3 was built, then **withdrawn by the owner on 2026-10-11**
(§7.2): prepending is an anti-pattern the compiler must not reward. All figures are
**[measured]** by the commands in §6.*

---

## 0. The answer in five sentences

1. **Kill criterion 5 fires, on bytes and on the swap; the P3 criterion fails on all three of
   its tests.** The design stops at S3 (§13), and nothing was tuned around it (CLAUDE.md
   rule 10).
2. **Bytes**: the table app on `browser-direct --release` is **4 524 B** brotli (terser, then
   brotli 11), against the 2 830 B bar and 0.85 × P3 (2 936 B on §13's 3 454; 2 718 B on P3 as measured today, 3 198). Its
   non-core part is **3 783 B** (bar 2 400), so this is the miss §13 calls the Million failure,
   not a miss by core alone; core's share is 741 B (bar 600).
3. **The swap** is **2.29 ms script against vanilla's 1.07 (2.1×) and P3's 0.87 (2.6× slower)**.
   The mechanism: `SwapRows` is an `indexedMap` with index guards, two element writes whose rows
   take keys the list holds; *Rank* turns each rekey away at the key map and hands the edit to
   the general reconciler, which builds a key map of the 1 000 rows and matches them — the exact
   edit §13 asked of the index guards is not delivered.
4. **`select`** is 1.45 ms against vanilla's 2.41 (0.60×, under the 1.0× bar) but only 24 %
   faster than P3's 1.91, short of the 30 % the P3 criterion asks.
5. **The TodoMVC shape** (`FilteredFor`, untraced): the toggle is 0.190 / 0.252 ms at 100 /
   1 000 todos against vanilla's 0.102 / 0.095 (1.9× / 2.7×), the filter switch 0.565 / 3.43
   against 1.06 at 1 000 (3.2×) — on par with Solid 1 and 2 and `browser-tea`, and the
   O(n)-per-toggle cost through the reconciler that §13 predicted for 1 000.

## 1. The table app (script ms, median [IQR], n = 5, 4× throttled)

Chrome 154 headless, `--taskset=8-15`. The machine was shared: the 1-minute load at the batch
starts ran from 3.7 to 21.3, so `update10th` and `clear` (wide IQRs) are not readable; the
others' quartiles are tight enough for the verdicts below.

| subject | run1k | replace1k | update10th | select | swap | remove | create10k | append | clear |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| vanilla | 4.25 | 8.51 | 3.35 [1.98–4.36] | 2.41 | 1.07 | 1.14 | 46.4 | 8.23 | 34.7 |
| **browser-direct** | 4.56 | 8.91 | 0.99 [0.83–5.84] | **1.45** | **2.29** | 0.40 | 46.3 | 7.69 | 41.6 [41.1–63.2] |
| P3 | 4.47 | 9.02 | 3.92 | 1.91 | 0.87 | 0.59 | 44.5 | 6.98 | 47.8 [29.8–60.1] |
| browser-tea | 4.29 | 9.37 | 12.9 | 0.91 | 1.84 | 0.59 | 45.3 | 6.89 | 32.5 |
| Solid 1 | 4.39 | 10.7 | 12.8 | 2.14 | 3.80 | 1.07 | 51.6 | 7.58 | 40.6 |
| Solid 2 | 5.39 | 11.8 | 17.2 | 4.28 | 4.26 | 1.59 | 61.0 | 9.51 | 50.4 |

Ratios of `browser-direct` to vanilla: 1.07, 1.05, 0.30, **0.60**, **2.13**, 0.35, 1.00, 0.93,
1.20 (clear, at the bar in a noisy cell). To P3: 1.02, 0.99, 0.25, **0.76**, **2.63**, 0.67,
1.04, 1.10, 0.87. A quieter run on 2026-10-10, before the rule was withdrawn, had the same
shape: swap 1.14 / 1.24 ms against P3's 0.53 / 0.46.

## 2. Bytes (B1, part by part, `size-parts.mjs`, terser then brotli 11)

| bundle | whole | core (leave-one-out) | runtime | program |
|---|--:|--:|--:|--:|
| `browser-direct --release` | **4 524** | 741 | 1 773 | 1 229 |
| `browser-tea --release` | 5 240 | 759 | 2 228 | 1 421 |
| P3 (scope-hoisted with its core) | 3 198 | | | |
| vanilla | 1 415 | | | |

`browser-direct`'s runtime, leave-one-out: the reconciler 721, the list scripts (mount, append,
clear, row patch, rekey, walk, select) 245, the scheduler and mount 287, the delegated listener
137, the merge 73, rows and the key map 116. Its page (templates, groups, handlers, listeners)
is 782, the program's data 333. Core: the trie and views reached by `++` 529, `get` 62,
`filter` 66, `indexedMap` 26. Building the rows in order (`[ …rows, row ]`, `List.append`)
reaches the trie's push half, as prepending reached its prepend half; `browser-tea`'s bundle is
5 240 B now against 5 266 with the withdrawn rule.

## 3. `FilteredFor` (untraced, script ms, 2 pages × 4 samples per point)

| op | N | browser-direct | browser-tea | Solid 1 | Solid 2 | vanilla |
|---|--:|--:|--:|--:|--:|--:|
| toggle | 100 | 0.190 | 0.257 | 0.172 | 0.220 | 0.102 |
| toggle | 1 000 | 0.252 | 0.208 | 0.165 | 0.203 | 0.095 |
| filter | 100 | 0.565 | 0.657 | 0.540 | 0.640 | 0.185 |
| filter | 1 000 | 3.43 | 3.32 | 3.53 | 3.91 | 1.06 |

There is no P3 page for this shape (research 60 wrote none). §13 set ≤ 1.2× at 100 and ≤ 1.3×
at 1 000 as S5's TodoMVC target; this shape is above both now.

## 4. Verdicts

- **Kill criterion 5: fires.** Bytes 4 524 > 2 830 with the non-core part 3 783 > 2 400 (the
  design's, not core's); swap 2.13× > 1.2×. `select` ≤ 1.0× holds. Every other operation is at
  or under 1.2× but `clear`, whose cell is too noisy to call.
- **The P3 criterion: fails** on all three tests: slower than P3 on `swap` (2.6×); `select` 24 %
  faster, not 30 %; 4 524 B against ≤ 2 936 B (≤ 2 718 on today's P3).
- **The swap bar the owner moved to S7** (≤ 1.15× vanilla and no slower than P3 until S7) is the
  rows sweep's; the table app's swap misses it too, and its cause is not the model's
  `List.swap` but the reconciler the rank rule falls back to.
- **The owner's verdict (2026-10-11): deferred, not accepted.** A size investigation by
  leave-one-out brotli measurement found the miss is not compiling away: the per-message and
  per-site code is ≈ 200 B, less than vanilla's hand-written DOM methods (≈ 500 B). The gap is
  the persistent `List` (741 B; building rows reaches the trie), the general reconciler used as
  the universal fallback (715 B; P3's whole `reconcile` is 406 B), one runtime script per write
  shape plus a key map (≈ 460 B), mount checks and prose errors (275 B), and the page markup
  vanilla keeps in its HTML (219 B). Fixable emission waste is ≈ 260 B. If the ownership
  thesis (`docs/thesis/ownership/`) holds, a `List` becomes a plain array edited in place and
  the library's cost mostly disappears, so the bar is judged again on a measurement of direct
  with native arrays, a P3-sized reconciler and the waste removed.

## 5. What the withdrawn rule changes

The building-loop rule (`backend.md` §8, *withdrawn*) was built on 2026-10-10 and reverted with
its fixtures; the table app's `buildFrom`, and P3's verbatim copy of it, now count up and push.
Code that still builds by prepending, left as it is for the owner: `core/Task.beni`'s `values`
(a `foldr` prepending), `platforms/browser-tea/Tea.beni`'s `Concurrent` policy (one prepend per
command) and `platforms/browser/Cmd.beni`'s key paths; `tests/corpus/writes/Recursion.beni`;
the `run/` fixtures that exist to test prepend and tail calls (`ListPrepend`, `ListPrependDeep`,
`TailCallClosures`, `TailModConsMerge`, `SpecializeScalars`, `SuspendLoopClosure`,
`OperatorSectionApplied`, `ReleaseEverything`, `ListSpreadPatterns`) and `emit/TailCallInPlace`;
`browser/{dom,direct}/KeyedEnds` (the prepend script); and in `bench/`, `arrays/lists`,
`arrays/scenarios`, `corpus/Codec`, `DictExtra`, `ExprParser`, `PrettyPrinter` and
`schema-prototype`.

## 6. Commands

From `bench/ui/`, `CHROME=google-chrome`, after `node build.mjs`:

- `node verify.mjs --subjects=beni,beni-release,beni-direct,beni-direct-release,p3,vanillajs,solid1,solid2`
  and `node p3-verify.mjs --cases=table` (both pass);
- `node bench.mjs --subjects=beni-release,beni-direct-release,p3,vanillajs,solid1,solid2 --n=5
  --taskset=8-15 --out=results/2026-10-11-s3-table.json` (532 s);
- `node scaling.mjs --full --untraced --sweeps=filtered
  --subjects=beni-release,beni-direct-release,vanillajs,solid1,solid2 --taskset=8-15
  --out=results/2026-10-11-s3-filtered-untraced.json` (56 s);
- `node sizes.mjs`; `node size-parts.mjs --map=table-s3[-coarse]`; `node size-parts.mjs
  --file=out/beni-direct-rel/_main.mjs --map=direct-s3[-coarse]`.

## 7. Lean direct: the S3 table app in the shape the ownership thesis enables (2026-10-11)

§4's deferral asked for direct to be judged with native arrays, a P3-sized reconciler and the
waste removed. A hand-written variant of the S3 release bundle (`95de7d89b`) measured it: plain
arrays edited in place, exact edits in the handlers (swap as two assignments, remove, append, set),
P3's `reconcile` only for genuine rebuilds (Run, RunLots), no key map, one delegated listener, a
one-line mount and dispatch guard. It is a prototype of what the compiler would emit, not compiler
work. Its DOM equals direct-S3's after every step of a 36-operation sequence, and `verify.mjs`
passes. Artifacts, raw results and the generator are in
`bench/ui/results/2026-10-11-lean-direct/`.

**Bytes** (terser then brotli 11): lean direct **1 764 B** with the page markup in the HTML, as
vanilla's 1 415 B is counted, and **1 982 B** with it in the bundle, as §2 counted — under both
the 2 830 B bar and P3 (3 198 B). Building new arrays where the thesis does not yet edit in place
(`indexedMap`, `filter`; its O1 is open): 2 053 B. With S3's persistent `List` put back: 2 931 B.
By leave-one-out the reductions were plain arrays −878 B (in-place over freshly built arrays only
−71 B more), the reconciler ≈ −330 B, mount and dispatch ≈ −300 B, per-shape scripts and the key
map replaced by ≈ 254 B of exact edits, and the markup −218 B.

**Speed** (script ms medians, 4× throttle, Chrome pinned to cores 24–31, load 3–5; ² = rerun at
n = 10): run1k 4.40 vs vanilla 4.37; update² 1.02 vs 0.97 (1.05×); select² 0.92 vs 1.32 (0.70×);
remove² 0.35 vs 0.53; create10k² 43.4 vs 41.8; append 4.37 vs 4.41; clear 15.5 vs 18.0;
replace1k unreliable (load 24 at its start). Swap² 0.53 vs 0.26 (2.0×), but every subject's swap
samples are bimodal — ≈ 0.11 ms or 0.4–1.0 ms — with identical fast samples for vanilla and lean
(the same two `insertBefore`s); direct-S3 was the only subject slow on every sample. The cause of
the slow mode (a collection inside the trace is likely) is unconfirmed; the median does not
separate lean from vanilla at this n.

**Against the bars.** Kill criterion 5: bytes pass; every operation is ≤ 1.14× and `select`
0.70×, except swap's median, which the measurement cannot yet judge. The P3 criterion: bytes pass
(62 % of P3), swap ties, `select` is 18–25 % faster than P3 against the 30 % asked.

**What it means.** The S3 miss was runtime weight and the persistent list, not compiling away.
Two tracks follow: slimming the direct runtime (P3-sized reconcile, minimal mount, exact edits for
per-shape scripts, the ≈ 260 B of emission waste) reaches ≈ 2.9 kB without the thesis; plain arrays
in place — the ownership thesis — take it to ≈ 1.8–2.0 kB. Every in-place edit lean makes is one the
thesis accepts, given `init` as a function and the swap written as `List.swap`. Open: a swap
measurement that separates the two modes, and whether P3's 30 % `select` test still applies.
