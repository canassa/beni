# 73 — The direct platform's lean slice: research 70 §7's lean direct, emitted by the compiler

*2026-10-12. What the lean slice (`browser-direct.md`, *Amended 2026-10-11 (the lean slice, as
specified)*) built and measured. Research 70 §4 deferred kill criterion 5 for a measurement of
direct with a P3-sized reconciler, exact edits and the emission waste removed; research 70 §7's
hand-written lean direct priced it at ≈ 2.9 kB with the persistent `List` kept. This slice makes
the compiler emit that shape while keeping every guarantee S3 had. All figures are **[measured]**
by the commands in §6.*

---

## 0. The answer in five sentences

1. **Bytes drop, but not to 2.9 kB**: the table app on `browser-direct --release` is **4 080 B**
   brotli with the markup in the bundle and **3 872 B** with it in the HTML (S3: 4 524 / 4 305),
   −10 %; against the 2 830 B bar, P3's 3 198 B and 0.85 × P3 = 2 718 B, it misses all three.
   Its non-core part is 3 348 B (bar 2 400) and core's share 732 B (bar 600).
2. **Speed: every operation is at or better than S3, and the swap is fixed**: `swap` 0.11 ms
   median (S3 1.01), with the same fast and slow sample groups as vanilla in 20 samples each
   (§2: consistent with vanilla's, not a proof of it). Against S3 and against vanilla:
   `update10th` 0.64× / 0.70×, `select` 0.84× / **0.67×**, `remove` 0.35× / 0.23×. `run1k`,
   `replace1k`, `create10k` and `clear` are 0.96–1.03× S3 **in the n = 10 re-run after a fix**
   (§2), not in the main table, where they read 1.02–1.12×.
3. **Kill criterion 5 still fires on bytes**; every operation is ≤ 1.2× vanilla (the highest,
   `replace1k` and `create10k`, at 1.10× in the main table) and `select` ≤ 1.0×.
   **The P3 criterion**: no operation is slower than P3 beyond its spread (`replace1k` 1.12× in
   the first batch, 1.00× at n = 10), `select` is **20 % faster than P3** (the 30 % test is
   withdrawn by the owner, §13 as amended), `swap` is 0.22× P3 — but bytes are 1.28× P3, not
   ≤ 0.85×.
4. **What separates 4.1 kB from lean's 2.9 kB is guarantees and generality, not compiling away**
   (§3): lean dropped rank-correct duplicate keys (CK-221) and the key map that pays for them,
   moved rows differently from `browser-tea` (so a focus the oracle keeps is lost, and the other
   way round), dropped the dispatch guard's `finally` and the multi-program mount, and wrote its
   list edits against one page; keeping each of these is a few hundred bytes of runtime.
5. **Stopped here, as the brief and rule 10 require**: the remaining gap is a design decision
   for the owner (§5), not something to tune.

## 1. What was built

Each item is the amendment's; this is what it measured.

| change | bytes (leave-one-out, brotli) | what it bought |
|---|---|---|
| the descriptor no longer escapes: a row carries its list's number, not the descriptor | ≈ −130 with the folds it unlocks (measured on S3 alone) | `backend.md` §9's facts now specialise the runtime to the page: `o`, `i`, the end marker's `null`, the key function, the key map's `null` test folded away |
| reconciler: one rank-correct matcher (a map from key to first row left, a link to the next), S3's two matchers and end trimming gone | 721 → 623 | the same contract; `browser-tea`'s make-and-patch order and moves kept |
| one loop makes rows (`append`); `mount` gone; a reconcile from none kept S3's direct insertion (§4) | in the scripts' 239 | |
| `exchange`: a swap's two writes checked once, after both | +≈ 40 | swap 1.01 → 0.11 ms |
| visits handed as names (`w`, a group function) | −6 | |
| `on` for listeners outside a list, the handler itself where it can be | in "the page" | six wrapper lambdas and listeners gone |
| the dispatch queue only where a send can arrive during a dispatch | −40 | |
| short release errors at the mount | in the scheduler's 151 (S3 287, with the queue) | |
| `NaN`-aware key equality gone (a `NaN` key reaches the reconcile, whose `Map` is right) | −10 | |

**Rejected on the way, measured**: P3's own moves (both ends, crossed ends, the middle put from
the back) in place of `browser-tea`'s udomdiff would save **140 B** (3 918 B). The page fuzzer's
50-seed sweep found eleven `browser/direct/` pages where the focus differs from `browser-tea`'s:
in ten, P3's moves keep a focus `browser-tea` loses (rotating a list moves one row where udomdiff
moves two); in one (`ExchangeRows`: a row taking a key the list holds), they move two rows where
one suffices and lose a focus `browser-tea` keeps. Neither is the minimal-move order; the oracle is
`browser-tea`'s, so its moves stay (§5 asks the owner).

## 2. The table app (script ms, median [IQR], n = 5, 4× throttled)

Chrome 154 headless, `--taskset=24-31`, load 2.3–7.9 at the batch starts. `beni-direct-s3` is the
S3 release bundle (`master` at `6c5f636de`) in the same batch.

| subject | run1k | replace1k | update10th | select | swap | remove | create10k | append | clear |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| vanilla | 4.15 | 8.96 | 1.00 | 1.27 | 0.66 [0.39–0.74] | 0.52 | 41.2 | 4.27 | 18.3 |
| **direct (lean)** | 4.47 | 9.86 [9.28–11.8] | **0.70** | **0.85** | **0.11 [0.11–0.73]** | **0.12** | 45.4 | 4.21 | 19.2 |
| direct S3 | 4.37 | 8.80 | 1.10 | 1.01 | 1.01 | 0.35 | 42.5 | 4.45 | 17.8 |
| P3 | 4.30 | 8.78 | 1.07 | 1.07 | 0.50 | 0.15 | 42.7 | 4.07 | 18.1 |
| old beni (`browser-tea`) | 4.35 | 10.5 | 1.47 | 0.68 | 0.88 | 0.45 | 43.0 | 4.34 | 19.1 |
| Solid 1 | 4.68 | 10.9 | 1.57 | 1.83 | 1.50 | 0.52 | 49.4 | 4.70 | 17.3 |
| Solid 2 | 5.60 | 12.9 | 2.40 | 3.03 | 1.40 | 0.92 | 60.5 | 5.84 | 21.6 |

That batch's `run1k`, `replace1k`, `create10k` and `clear` read 1.02–1.12× S3; a reconcile from
no rows was building a fragment through `append` where S3 put each row straight into the page.
S3's path was restored for that case (it is the reconcile's, measured at S3), and the four were
measured again at n = 10 (load 5–12): **run1k 4.32 / S3 4.49 (0.96×), replace1k 8.59 / 8.60
(1.00×), create10k 73.1 / 71.1 (1.03×, a cell at load 12 where vanilla read 64.9), clear 19.0 /
18.9 (1.00×)** — at S3 within the spread. No operation is slower than S3.

**The swap's two modes** (n = 20 per subject, its own batch; a sample under 0.25 ms is fast):

| subject | fast samples | fast median | slow samples | slow median |
|---|--:|--:|--:|--:|
| vanilla | 5 / 20 | 0.105 | 15 | 0.783 |
| **direct (lean)** | **6 / 20** | **0.120** | 14 | **0.735** |
| P3 | 3 / 20 | 0.115 | 17 | 0.826 |
| direct S3 | 0 / 20 | — | 20 | 1.138 |
| old beni | 0 / 20 | — | 20 | 0.998 |
| Solid 1 | 0 / 20 | — | 20 | 1.905 |
| Solid 2 | 0 / 20 | — | 20 | 1.973 |

Lean direct's swap looks like vanilla's in both modes (6 against 5 fast samples of 20: consistent
with one distribution, too few to prove it): the same two `insertBefore`s. S3, `browser-tea`
and both Solids are never fast. **The slow mode's cause**: six traces of vanilla's slow samples
(`trace-dump.mjs` with the `v8`, `v8.execute`, GC and compile categories, down to 10 µs) show no
GC, compile or other event inside the click's `FunctionCall`; the 0.6–1.0 ms is spent in the
listener's own DOM calls. Which part of `insertBefore` (the removal steps, style invalidation of
1 000 siblings) is not separated by these categories, so the cause stays unconfirmed past "the
DOM calls, not V8".

**The TodoMVC shape** (`FilteredFor`: a `For` over `List.filter`, which reconciles on every
message; untraced, script ms, 2 pages × 4 samples per point; research 70 §3's command, load 3.6).
It answers whether dropping S3's end trimming costs a reconcile that keeps most rows: no.

| op | N | lean direct | `browser-tea` | Solid 1 | Solid 2 | vanilla | lean ÷ vanilla | S3 ÷ vanilla (research 70 §3) |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| toggle | 100 | 0.085 | 0.090 | 0.083 | 0.098 | 0.055 | 1.5 | 1.9 |
| toggle | 1 000 | 0.113 | 0.100 | 0.090 | 0.110 | 0.060 | 1.9 | 2.7 |
| filter | 100 | 0.528 | 0.613 | 0.583 | 0.693 | 0.245 | 2.2 | 3.1 |
| filter | 1 000 | 3.77 | 4.06 | 4.32 | 4.67 | 1.84 | 2.0 | 3.2 |

The machine was quieter than in research 70's batch, so only the ratios compare across the two.

## 3. Bytes (B1, part by part, `size-parts.mjs --map=direct-lean`, terser then brotli 11)

| part | lean slice, leave-one-out | S3 (research 70 §2) |
|---|--:|--:|
| core (the trie, `get`, `indexedMap`, `filter`, `modBy`) | 656 (coarse: 732) | 741 |
| Rt scheduler: `send`, mount, `run` | 151 | 287 |
| Rt lists: rows, keys, the key map | 58 | 116 |
| Rt list scripts: `append`, `clear`, `exchange`, walk, select | 239 | 245 |
| Rt reconciler | 623 | 721 |
| Rt merge | 79 | 73 |
| Rt delegation, `on` | 141 | 137 |
| program data, update | 398 | 403 |
| program: the page | 716 | 782 |
| **whole** | **4 080** (3 872 with the markup in the HTML) | 4 524 (4 305) |

Coarse, leave-one-out: core 732, the platform runtime 1 464, the program 1 146. Leave-one-out
figures do not add up to the whole (brotli shares context across parts: they sum to 3 061 of
4 080), so the comparisons below are part against part, never sums against a total.

**Against lean direct with the persistent list kept (2 931 B), where the 1 150 B are**: the
reconciler (623 against P3's 393: rank-correct matching for any list and `browser-tea`'s
moves); the scripts, the merge and the key map (≈ 380 against lean's ≈ 250 of exact edits: each
keeps rank — a script whose rows a repeated key would match by rank runs only while every key is
one row's, and otherwise reconciles — and works for any page, a list in a row, a list not owning
its parent, a row reading its position); the scheduler (151 against lean's 34: the `finally`
that stops the page on a throw, the multi-program mount with its two checks); the delegation walk
(nested lists, `disabled`, the flags, other programs' mounts); and the page's descriptor, slots
and group functions. None of these is code the compiler failed to compile away: each is a
guarantee lean's prototype did not keep or a case the table app does not reach.

## 4. Correctness

Every `browser/direct/` page passes on both platforms against its one golden; `zig build gates`
is green; the page fuzzer's 50-seed, 60-step sweep (`zig build fuzz -Dcorpus=browser/direct`)
finds no difference on any direct page; `verify.mjs` passes for every subject. New fixtures:
`browser/direct/ExchangeRows` (the swap one exchange, a focused row the edit does not touch
keeping the focus; then a key that repeats sends the swap to the reconcile, rank-correct, as
`browser-tea` matches it) and `ReconcileMoves` (a row moved alone, crossed ends, a reversal, a
replacement keeping the middle row's node), and `emit/release/direct/TableSwap` (the exchange,
`on` with the handler, no test of `o` or `i`, no queue). The release errors at the mount changed
text: `DefectAtMount.release-expected`, `LocalMountedTwice.release-expected`, with
`DefectAtMount.tea-release-expected` keeping `browser-tea`'s.

**Found on the way, not fixed (out of scope)**: the release optimiser declares two locals under
one name when two loops written in place leave results a folded branch never reads. Folding the
reconcile's `once && not repeats` to `False` made `--release` print `let …,v=false … let m=h,v=true`
(terser: `"v" is redeclared`), and a 20-line user program does the same and does not load in
Node. It is catalogued as CK-222 in `plans/checker-findings.md`, with its red fixture
`tests/pending/run/ReleaseRedeclared.beni`; the shipped runtime does not reach it (its fold
does not happen).

## 5. Verdicts, and what is the owner's

- **Kill criterion 5**: fires on bytes (4 080 > 2 830; non-core 3 348 > 2 400; core 732 > 600).
  Speed passes: every operation ≤ 1.2× vanilla (the highest `replace1k` and `create10k` at 1.10×
  in loaded cells), `select` 0.67×.
- **The P3 criterion**: speed passes (no operation slower than P3 beyond its spread, `swap`
  0.22× P3, `select` 0.80× P3); bytes fail (1.28× P3 against ≤ 0.85×).
- **Decisions this measurement puts to the owner**, each with what it is worth:
  1. *Move rows by another order than `browser-tea`'s*: −140 B, and the focus differs from the
     oracle where the two orders differ. A minimal-move order (LIS) would keep focus at least as
     often as either, and would then need `browser-tea` to adopt it for the two to stay each
     other's oracle.
  2. *Plain arrays edited in place* (the ownership thesis): research 70 §7 measured −878 B on
     lean; on this bundle core is 732 B.
  3. *Rank-correct duplicates and the key map*: they are CK-221's guarantee and stay; their
     cost is most of the scripts' and the merge's ≈ 130 B over lean's.
  Without 1 and 2 the design does not reach 2.83 kB; with 2 alone the estimate is ≈ 3.4 kB [estimate: core's 732 B mostly gone].

## 6. Commands

From `bench/ui/`, `CHROME=google-chrome`, after `node build.mjs --no-solid`, with
`out/beni-direct-s3/` holding the S3 release bundle and `out/extra-subjects.json` naming it:

- `node verify.mjs --subjects=beni-release,beni-direct-release,beni-direct-s3,p3,vanillajs,solid1,solid2`;
- `node bench.mjs --subjects=vanillajs,beni-direct-release,beni-direct-s3,p3,beni-release,solid1,solid2
  --n=5 --taskset=24-31 --out=results/2026-10-11-lean-slice/table.json` (8 min);
- the same with `--benchmarks=05_swap1k --n=20 --out=…/swap.json` (2 min);
- after the fill fix, `--subjects=vanillajs,beni-direct-release,beni-direct-s3,p3
  --benchmarks=01_run1k,02_replace1k,07_create10k,09_clear1k_x8 --n=10 --out=…/rerun.json` (7 min);
- `node trace-dump.mjs --subject=vanillajs --benchmark=05_swap1k --min=0.01
  --categories=v8,v8.execute,disabled-by-default-v8.gc,disabled-by-default-v8.compile,blink`;
- `node sizes.mjs`; `node size-parts.mjs --file=out/beni-direct-rel/_main.mjs
  --map=direct-lean[-coarse]`; the markup-in-the-HTML figure empties the page template's string
  literal and measures the same way.

Load before the batches 4.1, after 11.1 (another job); the table batch's per-benchmark loads are
in its JSON.
