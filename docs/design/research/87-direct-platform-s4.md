# 87 — Direct rendering after slice S4: guarantees, costs, and the app boundary

*2026-10-15. Measurement of the rendering introduced by PR [#86](https://github.com/canassa/beni/pull/86),
merged at `c1e422284`, on master `e2aed9171507978edef58e1ee8cf601020f538e2`. The owner asked for
master on azathoth; this revision also includes the later ownership and S5 effects work.
This is a measurement of that complete revision, not a before/after attribution to S4 alone.
The report branch later fast-forwarded to `6e041631f` (proof synchronization and a test-only
cache-pruning fix); compiler, platform, application and benchmark sources did not change between
those base commits. The final review gate uses that refreshed base.
No compiler, runtime, application source, target or budget was changed for these measurements.
All figures below are **[measured]**, except explicitly marked explanations or outstanding work.*

## 0. The answer

**S4 does not meet its three speed targets.** At the required endpoints, direct/vanilla is
**1.50× on live rows 10,000** (0.105/0.070 ms), **1.317× on derived 100,000** (0.270/0.205 ms),
and **2.123× at depth 128** (0.563/0.265 ms), against **1.15×, 1.15× and 1.3×**. Live and
derived have bounded per-message work; their residual cost is the fixed guarded handler/model/
hole path, not a scan or sort. Depth is worse: the eight-step analysis cap widens the write,
and the emitted handler calls 121 groups and evaluates 8,107 child-property accesses.
These misses are reported without replacing the program, the output or the thresholds.

**Criterion 5 still fires on bytes.** The table app is **4,102 B brotli**, versus the 2,830 B bar;
core's in-context share is **699 B** and the whole minus core is **3,403 B**, versus 600 and
2,400 B respectively. The non-core miss survives even if core were free. The mechanism is
priced in §3: the reconciler and row patching, the guard and delegation, the generated page and
its data. This is the existing table criterion, not a new S4 threshold or permission to proceed.

**S4's own byte hypotheses miss too:** live 10,000 is **2,681 B**, versus 1.1 kB; derived
100,000 is **1,403 B**, versus 1 kB; depth 128 is **2,671 B**. The live page pays for editable
rows and controlled restoration, the derived page for the sort/filter code still needed at
mount, and depth for nested immutable updates and the emitted paths. Section 3 separates those
parts. The normative S4 amendment names no standalone S4 kill criterion: target misses are
reported; criterion 8 continues to apply.

**None of the four unchanged full real apps builds on direct at this master.** Conduit passes
ownership but its helper-computed document view reaches `not_implemented`; full editing
TodoMVC reaches `list_may_be_shared`; Bike Wars reaches two `list_still_used` errors and one
`top_level_list_changed`; Sternhalma reaches three `top_level_list_changed` errors. The reduced
sandbox and non-editing routing TodoMVC subjects do build. Those subjects do not establish
support for the full TodoMVC application. Section 6 gives the commands and exact diagnostics.

**Correctness validation is incomplete, not accepted by silence.** Linux gates pass. Chrome's
360 direct corpus cases have two failures, both value-fuzz infrastructure failures after full
navigation. The mechanism was reproduced with either platform first: the page leaves the app,
then the fuzzer sends into a new document with no dispatch hooks. This is not an observed stale
screen or a differential disagreement; it is also not a green Chrome result. The first full V3
adversarial campaign remains owed. Section 5 distinguishes that debt from the rendering checks
that passed.

## 1. Protocol and provenance

The checkout on **azathoth** (`~/src/github.com/canassa/beni`) was pulled to master. Its untracked
2026-10-13 JFB results, which blocked the pull because master now tracks them, were moved to
`~/beni-preserved-20261014/` first. No local S6 work was included: the report branch is an isolated
worktree based on the same master.

The machine is an Intel Xeon E-2386G, six physical cores and twelve logical CPUs. Chromium
153.0.8010.36 and Node 24.19.0 come from `nix develop .#browser`; the compiler was built by
**Zorg 0.17.1+zorg.1**, `zorg build -Doptimize=ReleaseFast`. The source revision and compiler
build ID are retained with the raw results. Chrome and its renderer threads are pinned to
**2–5,8–11** (physical cores 2–5 and their SMT siblings); the Node timing harness is pinned to
**0–1,6–7**. There was no competing user computation. These are dedicated measurement cores
by scheduling, not kernel `isolcpus` isolation. The host's existing `powersave` governor with
`balance_performance` preference was retained for the complete batch.

One serial campaign rebuilt every subject, verified the table, measured all table operations,
then measured every scaling sweep, with every available candidate in each segment. Subject order
rotates between iterations/pages. The sweep harness initially attempted P3 on `filtered`, although that sweep has no P3 generator.
The incomplete `filtered/toggle/100` point was stopped after the missing-page timeout. After
fixing the static-subject availability check, the remaining sweeps resumed together; completed
holes and rows were not rerun. `sweeps-prefix.json` and `sweeps-rest.json` preserve both epochs
and their original metadata; the merged summary selects the completed prefix and remaining
conditions. No candidate was measured in a separate corrective timing run, and no completed
point's sample was trimmed. Every harness postcondition was checked. P3 is included wherever the
harness has its hand-written subject; its absence from a sweep is explicit, not an invented
comparison. Both beni subjects are **release builds**, Solid 1 is **1.9.15**, and Solid 2 is
**2.0.0-rc.9**, as pinned by `bench/ui/apps/solid{1,2}`. Timings use the build outputs as
served; external Terser is byte normalization only, not another timed candidate. The table
subjects keep their existing data builders (beni and P3 use the seeded beni builder), so the
comparison prices the whole application, not an isolated renderer.

Research [84](84-throttled-short-operations.md) §4 is the timing protocol: **rate 1 throughout**;
medians and p25–p75, with **20 fresh-page samples per table operation and candidate**. Scaling
uses untraced real clicks: two independently mounted pages, five warm-up clicks per page, and
12 measured clicks per page, **24 samples per point**. The 24 clicks are clustered in two pages,
not 24 independently compiled or mounted programs. The cross-origin isolated server preserves
`performance.now()` resolution. The untraced interval is window capture through the microtask
queued at window bubble, including the platform's queued work, excluding layout/paint.

The table uses the existing trace-derived `script` column at rate 1. It must not be compared
numerically with the untraced sweep intervals. `stream` is the harness's exception: two traced
three-second windows per point, reported as script per message. Those two-window medians/IQRs
are informational; they do not satisfy research 84's n ≥ 20 click protocol or certify a stream
threshold. No throttled sub-ms median is used as a ranking.

The table contains **1,080 samples**; the completed sweeps contain **10,188 observations**,
including 36 stream windows. All 441 observed sweep cells have their full count (24 clicks or
2 stream windows), and every requested candidate is present at every condition. P3 has 29
explicitly unsupported generated pages, corresponding to the sweeps without its generator.
There are no failed completed points or lost samples; the incomplete availability failure is
retained in `sweeps-prefix.log` and the merged `interruption` field. Batch-start one-minute
load is **0.30–1.54**, median **0.725**. The table ran 00:07:42–00:36:38 CEST; the sweeps
continued through 01:04 CEST (exact UTC timestamps remain in each epoch).

Raw results, commands, byte maps and the release bundles behind the part measurements are in
[`bench/ui/results/2026-10-15-azathoth-s4/`](../../../bench/ui/results/2026-10-15-azathoth-s4/).
An IQR describes sample spread, not a confidence interval for a ratio.
The harness changes add Solid 2 to scaling sizes, accept checked JSON binding maps for the
part reporter, and list absent static P3 subjects as skipped rather than timing an empty page.
They change no timed program or timing interval.

## 2. The table app

`script` ms, rate 1, median [p25–p75] (n). No samples dropped.

| operation | vanilla | Solid 1 | Solid 2 | tea | direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 01_run1k | 12.929 [10.844–14.694] (20) | 14.579 [11.211–17.052] (20) | 17.781 [15.021–19.466] (20) | 12.080 [8.030–15.097] (20) | 13.750 [9.314–16.717] (20) | 14.191 [12.030–16.137] (20) |
| 02_replace1k | 15.867 [12.642–16.495] (20) | 19.089 [16.499–19.624] (20) | 19.931 [18.463–21.087] (20) | 17.482 [15.385–18.014] (20) | 16.410 [13.197–16.960] (20) | 15.338 [13.773–16.196] (20) |
| 03_update10th1k_x16 | 0.746 [0.718–0.780] (20) | 1.406 [1.252–1.509] (20) | 2.276 [2.082–2.328] (20) | 1.306 [1.248–1.690] (20) | 0.897 [0.874–0.976] (20) | 0.701 [0.587–0.716] (20) |
| 04_select1k | 0.548 [0.499–0.623] (20) | 0.608 [0.534–0.780] (20) | 1.022 [0.970–1.106] (20) | 0.311 [0.296–0.333] (20) | 0.429 [0.382–0.454] (20) | 0.469 [0.418–0.487] (20) |
| 05_swap1k | 0.414 [0.407–0.446] (20) | 1.517 [1.302–1.739] (20) | 1.751 [1.702–1.978] (20) | 0.766 [0.688–0.823] (20) | 0.458 [0.419–0.532] (20) | 0.438 [0.384–0.509] (20) |
| 06_remove-one-1k | 0.593 [0.558–0.633] (20) | 0.615 [0.579–0.650] (20) | 0.901 [0.809–0.964] (20) | 0.383 [0.362–0.417] (20) | 0.252 [0.235–0.264] (20) | 0.303 [0.293–0.328] (20) |
| 07_create10k | 52.906 [48.067–55.758] (20) | 66.000 [63.779–67.027] (20) | 78.470 [73.636–79.546] (20) | 56.317 [50.090–59.519] (20) | 60.008 [55.096–62.697] (20) | 58.675 [56.780–60.668] (20) |
| 08_create1k-after1k_x2 | 9.468 [8.979–10.499] (20) | 10.546 [8.633–11.029] (20) | 11.745 [10.662–13.067] (20) | 10.546 [9.295–11.226] (20) | 8.463 [7.699–10.748] (20) | 9.767 [7.941–10.402] (20) |
| 09_clear1k_x8 | 10.904 [7.569–11.579] (20) | 11.035 [9.268–11.459] (20) | 10.841 [8.444–11.596] (20) | 10.541 [9.764–10.873] (20) | 10.402 [8.350–11.088] (20) | 9.894 [8.808–10.890] (20) |


Direct/vanilla median ratios, in row order: **1.064, 1.034, 1.202, 0.784, 1.106, 0.424,
1.134, 0.894, 0.954**. Direct/P3: **0.969, 1.070, 1.280, 0.916, 1.046, 0.829, 1.023,
0.867, 1.051**. These are per-operation results, not a geometric mean.

- `select` meets ≤ 1.0× vanilla; direct and vanilla's IQRs are separate. Tea is faster than
  direct on this operation (0.311 versus 0.429 ms), so this batch does not support an across-the-board
  direct-over-tea claim. The earlier 30 % P3-select stop was already withdrawn by the owner;
  this batch's direct is 8.4 % faster than P3 by its median, with overlapping IQRs.
- `swap` meets ≤ 1.2× vanilla, **at rate 1**, with overlapping IQRs against vanilla and P3.
  No throttling-mode explanation or n = 5 median is needed to excuse it.
- `remove` is faster than both vanilla and P3 with separate IQRs. The filter-merge path remains.
- `update10th` is **0.897 versus 0.746 ms**, a point ratio **1.2016075×**, just over the 1.2 bar;
  the tiny amount beyond 1.2 is not a resolved threshold crossing. But direct is observably
  slower than vanilla and than P3's **0.701 ms** in this batch: their IQRs are separate. The
  P3 test (no operation slower beyond its spread) fails on this operation. It is not hidden
  behind the table's byte failure.
- Create/replace/clear have wider spreads. Their point ratios are reported, but the overlapping
  IQRs do not establish their close orderings. All eight non-update point ratios satisfy the
  table's vanilla bars.

The update investigation profiles the **same cold table warm-up**, all six candidates rotated
in one batch, 20 fresh pages each, rate 1, nominal sampling interval 25 µs. Direct's named JS
samples concentrate in **`da` (the full identity walk, 111 µs self/page)** and **`F` (the label
writer, 154 µs)**; P3's prefix reconciler samples **33 µs** and its marked-row `render` loop
**116 µs**. Direct's indexed-map loop samples about **20 µs**, versus **30 µs** for P3's loop:
the slower path is not identified as the shared row-data builder.

The emitted update calls `da(P, rows, F)`: it walks all 1,000 instance references, then calls a
separate row writer for the 100 changes. P3 also walks the list, but its prefix pass marks rows
and one render loop writes the marked labels. Direct's specialized walk/indirect writer path
costs more in this exact warm-up, despite avoiding the general reconciler. The profiles localize
that residual; they do not establish a JIT-tier explanation or a precise decomposition of the
0.196 ms median gap. Most busy profile time is native/unattributed `(program)` and includes
layout after the click. Those samples, idle and the profiler's own overhead are retained and
excluded from the named-JS figures, not folded into a new speed comparison. Raw profiles and
source columns are archived; no warm-up or candidate was changed to make the ordering reverse.

## 3. Bytes, part by part

Sizes follow the earlier UI reports: all JavaScript the page loads, each file minified with
Terser 5.51.2 (`compress`, `mangle`, `module`), then concatenated and compressed with **brotli 11**;
gzip 9 and raw bytes are also retained. CSS, HTML and dependencies not loaded by the page are
outside the JavaScript total. Beni's page markup is inside its JavaScript, as earlier reports
count it; vanilla's static shell is in HTML. The table target is judged with that stated convention,
not with the shell moved out after measurement.

**Table application.**

| subject | files | as served raw | gzip -9 | brotli 11 | minified raw | minified brotli |
|---|--:|--:|--:|--:|--:|--:|
| beni, development | 10 | 65255 | 16596 | 14490 | 21916 | 8178 |
| beni, --release | 1 | 13416 | 5945 | 5365 | 12791 | 5206 |
| beni-direct, --release | 1 | 11088 | 4687 | 4254 | 10636 | 4102 |
| Solid 2.0.0-rc.9 | 1 | 68518 | 24404 | 22131 | 68031 | 21988 |
| Solid 1.9.15 | 1 | 11513 | 4803 | 4356 | 11512 | 4354 |
| P2 (hand-written) | 1 | 7946 | 2903 | 2491 | 3726 | 1537 |
| P3 (research 60) | 1 | 22234 | 7072 | 6261 | 8699 | 3122 |
| vanillajs | 1 | 9486 | 2521 | 2172 | 4743 | 1415 |

**Rendering endpoints: minified brotli bytes.**

| page | vanilla | Solid 1 | Solid 2 | tea | direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| holes 10000 | 195 | 55497 | 60760 | 62503 | 561 | 442 |
| rows 30000 | 415 | 3576 | 13738 | 3836 | 2655 | 1644 |
| live 10000 | 243 | 3516 | 13727 | 3867 | 2681 | 1010 |
| derived 100000 | 367 | 3557 | 13762 | 3565 | 1403 | — |
| depth 128 | 294 | 4486 | 19364 | 3110 | 2671 | 1237 |
| helperRows 10000 | 243 | 3481 | 13649 | 3231 | 979 | — |
| tree 12 | 175 | 3067 | 12254 | 1523 | 1184 | — |
| width 1024 | 1742 | 10064 | 24269 | 17552 | 2983 | — |


The columns below use B1's **leave-one-out in-context delta**. Removing a part replaces its
bindings by reference-preserving stubs and re-minifies/recompresses the whole. Brotli is not
additive: the columns must **not** be summed or treated as independent downloads. The archived
`*-parts.txt` files also give standalone compression and ordered peeling; peeling plus the
startup/stub residue sums to the whole. The part tool runs on the archived Linux bundles
under local Node 24.19.0/Terser 5.51.2; the complete size tools also run on azathoth. JSON maps cover every emitted top-level declarator,
with duplicate assignments rejected; the matching bundles are archived so renaming cannot
silently invalidate a map.

| page / platform | whole | core Δ | runtime Δ | program Δ |
|---|--:|--:|--:|--:|--:|
| table / tea | 5206 | 746 | 2249 | 1439 |
| table / direct | 4102 | 699 | 1532 | 1147 |
| live / tea | 3867 | 86 | 2586 | 494 |
| live / direct | 2681 | 178 | 1682 | 383 |
| derived / tea | 3565 | 379 | 2128 | 436 |
| derived / direct | 1403 | 422 | 323 | 271 |
| depth / tea | 3110 | 0 | 731 | 935 |
| depth / direct | 2671 | 0 | 307 | 1613 |
| helperRows / tea | 3231 | 30 | 2201 | 401 |
| helperRows / direct | 979 | 134 | 308 | 245 |
| tree / tea | 1523 | 0 | 732 | 420 |
| tree / direct | 1184 | 0 | 522 | 355 |
| width / direct | 2983 | 0 | 237 | 2622 |


**Direct table, finer split (same leave-one-out method).**

| part | alone raw | alone br | leave-one-out br | peel br |
|---|--:|--:|--:|--:|
| core: List representation, append and indexed get | 2029 | 946 | 594 | 594 |
| core: array allocation, indexedMap and filter | 393 | 219 | 72 | 88 |
| runtime: guard, queue, mount and run | 617 | 336 | 184 | 199 |
| runtime: list descriptor and row helpers | 414 | 242 | 47 | 78 |
| runtime: append and clear | 267 | 188 | 44 | 52 |
| runtime: reconciler and row patch | 2040 | 970 | 607 | 695 |
| runtime: exact swap and walk | 533 | 317 | 126 | 154 |
| runtime: filter merge and selection | 584 | 351 | 136 | 208 |
| runtime: delegation and listener | 631 | 309 | 167 | 239 |
| core: modBy and Nothing | 72 | 76 | 0 | 6 |
| runtime: sandbox | 42 | 46 | 6 | 0 |
| program: data and row building | 830 | 483 | 341 | 358 |
| program: swap and rowClass | 242 | 173 | 62 | 86 |
| program: page, handlers and init | 2713 | 899 | 712 | 823 |
| what is left (start-up statements) | | | | 522 |
| **sum** | | 5555 | 3098 | 4102 |


The table's generic `List.append` row builder still reaches List's persistent representation;
this is visible in the archived bundle's `t`/`sa` path, not inferred from an old report's bytes.
The general rank-correct reconciler/row-patch part costs **607 B** in context; delegation/listeners
**167 B**, guard/queue/mount **184 B**, the page/handlers/init **712 B**, and row-building data
**341 B**. These are individual deltas, not an additive explanation of the entire 4,102 B.
Core's **699 B** and the **3,403 B non-core remainder** are the arithmetic criterion 5 names.
No in-place list or record-update implementation was substituted for the compiler's output.

The live page's **429 B** controlled-input delta buys edited-set restoration, including click/
change activation. It is paid even when the timed `Go` key edits no row. Its list/reconciler
part is **841 B**, because the same page must handle editable rows (`Edit Int String` with a
mapped list). The timing target is the unrelated tick; the byte target judges the **whole
program**, not a tick-only rewrite with those events removed.

The derived page retains **422 B of core** in context: filtering, sorting and taking the first
50 are still needed at mount. Its tick handler keeps the derived value rather than sorting it
again. Removing those declarations would change what the page initially shows. The ≤ 1 kB
estimate did not pay for all that code.

The depth-128 bundle retains **128 initial nested records and 128 immutable update helpers**.
The update helpers cost **224 B** by leave-one-out; the page/handler part, including HTML and
explicit repeated model paths, costs **1,314 B**. A dynamic leaf is reached through emitted
`.a` chains; this is a data path, not a single constant-time update. S7's in-place work has not
been substituted. More significantly, the write dump is `exact (cap k)` at the eight-step path
limit: the leaf change widens to the subtree below that prefix. The emitted `Jk` handler calls
**121 groups**, evaluating **8,107 `.a` child accesses** per dispatch before comparing unchanged
labels. These are AST counts of the archived as-served bundle, recorded in `depth-paths.json`;
they are not timings or a revised S0 pair count. Root-relative paths repeated for successive
levels make that work quadratic in depth. Eliminating model spreads alone would leave those
group reads; increasing precision or sharing path prefixes is a separate mechanism to measure.
The widening is documented in `write-sets.md` §6.1 and its O1 limit; it preserves correctness
but contradicts any assumption that all 128 levels cost only the leaf's DOM write. P3's depth
subject keeps the same nested spread helpers and reads/compares only the leaf; it is therefore
the useful control for this rendering overhead, not evidence that immutable models alone cause
the direct miss. Section 4 reports the measured curve and the compressed marginal cost;
≤ 4 B per level must be judged as growth, not whole size divided by 128.

## 4. Scaling sweeps

All ordinary cells are untraced real-click ms, median [p25–p75] (n), at rate 1.
For `stream`, units are traced ms per message and n counts windows.
P3 is unavailable for filtered, width, derived, helper rows and tree.

**holes / tick: view size: N holes, one changes.**

| N | vanilla | Solid 1 | Solid 2 | tea | direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 10 | 0.225 [0.200–0.231] (24) | 0.385 [0.370–0.406] (24) | 0.425 [0.410–0.559] (24) | 0.327 [0.304–0.371] (24) | 0.217 [0.195–0.240] (24) | 0.225 [0.205–0.244] (24) |
| 30 | 0.220 [0.204–0.272] (24) | 0.385 [0.365–0.410] (24) | 0.460 [0.428–0.561] (24) | 0.310 [0.294–0.363] (24) | 0.228 [0.219–0.246] (24) | 0.243 [0.220–0.260] (24) |
| 100 | 0.205 [0.190–0.215] (24) | 0.365 [0.344–0.414] (24) | 0.435 [0.410–0.545] (24) | 0.298 [0.275–0.365] (24) | 0.215 [0.204–0.223] (24) | 0.230 [0.215–0.285] (24) |
| 300 | 0.195 [0.190–0.210] (24) | 0.355 [0.344–0.376] (24) | 0.423 [0.402–0.549] (24) | 0.320 [0.297–0.360] (24) | 0.218 [0.210–0.267] (24) | 0.263 [0.249–0.290] (24) |
| 1000 | 0.200 [0.184–0.210] (24) | 0.365 [0.350–0.411] (24) | 0.530 [0.410–0.621] (24) | 0.303 [0.277–0.403] (24) | 0.210 [0.200–0.241] (24) | 0.215 [0.200–0.246] (24) |
| 3000 | 0.210 [0.195–0.226] (24) | 0.382 [0.350–0.406] (24) | 0.445 [0.424–0.520] (24) | 0.350 [0.319–0.396] (24) | 0.227 [0.215–0.236] (24) | 0.248 [0.223–0.270] (24) |
| 10000 | 0.245 [0.199–0.265] (24) | 0.408 [0.354–0.431] (24) | 0.407 [0.359–0.461] (24) | 0.282 [0.229–0.329] (24) | 0.230 [0.210–0.281] (24) | 0.222 [0.204–0.251] (24) |

**rows / change: list length: N keyed rows.**

| N | vanilla | Solid 1 | Solid 2 | tea | direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 10 | 0.257 [0.205–0.282] (24) | 0.387 [0.369–0.429] (24) | 0.452 [0.416–0.535] (24) | 0.390 [0.341–0.421] (24) | 0.250 [0.235–0.276] (24) | 0.285 [0.255–0.331] (24) |
| 30 | 0.227 [0.210–0.275] (24) | 0.382 [0.359–0.416] (24) | 0.452 [0.419–0.547] (24) | 0.380 [0.337–0.440] (24) | 0.238 [0.219–0.272] (24) | 0.268 [0.239–0.335] (24) |
| 100 | 0.220 [0.209–0.235] (24) | 0.387 [0.374–0.408] (24) | 0.460 [0.429–0.571] (24) | 0.425 [0.347–0.495] (24) | 0.273 [0.239–0.300] (24) | 0.255 [0.240–0.307] (24) |
| 300 | 0.215 [0.190–0.238] (24) | 0.480 [0.365–0.505] (24) | 0.553 [0.425–0.590] (24) | 0.425 [0.392–0.511] (24) | 0.315 [0.249–0.341] (24) | 0.335 [0.252–0.382] (24) |
| 1000 | 0.225 [0.214–0.235] (24) | 0.470 [0.437–0.506] (24) | 0.540 [0.419–0.574] (24) | 0.392 [0.359–0.488] (24) | 0.265 [0.234–0.311] (24) | 0.262 [0.250–0.396] (24) |
| 3000 | 0.202 [0.179–0.236] (24) | 0.262 [0.254–0.295] (24) | 0.332 [0.304–0.370] (24) | 0.360 [0.340–0.419] (24) | 0.197 [0.174–0.274] (24) | 0.225 [0.209–0.281] (24) |
| 10000 | 0.127 [0.105–0.145] (24) | 0.207 [0.170–0.228] (24) | 0.202 [0.189–0.236] (24) | 0.538 [0.426–0.573] (24) | 0.127 [0.114–0.169] (24) | 0.132 [0.115–0.156] (24) |
| 30000 | 0.090 [0.080–0.100] (24) | 0.137 [0.130–0.150] (24) | 0.172 [0.155–0.186] (24) | 0.560 [0.515–0.595] (24) | 0.115 [0.095–0.121] (24) | 0.125 [0.109–0.132] (24) |

**rows / swap: list length: N keyed rows.**

| N | vanilla | Solid 1 | Solid 2 | tea | direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 10 | 0.350 [0.320–0.415] (24) | 0.560 [0.539–0.670] (24) | 0.780 [0.730–0.866] (24) | 0.465 [0.440–0.530] (24) | 0.442 [0.382–0.491] (24) | 0.388 [0.349–0.450] (24) |
| 30 | 0.327 [0.310–0.357] (24) | 0.590 [0.565–0.631] (24) | 0.780 [0.684–0.867] (24) | 0.545 [0.459–0.601] (24) | 0.380 [0.345–0.426] (24) | 0.365 [0.325–0.425] (24) |
| 100 | 0.350 [0.313–0.407] (24) | 0.778 [0.706–0.805] (24) | 0.975 [0.908–1.161] (24) | 0.667 [0.606–0.760] (24) | 0.382 [0.337–0.430] (24) | 0.350 [0.334–0.392] (24) |
| 300 | 0.340 [0.303–0.456] (24) | 1.020 [0.882–1.098] (24) | 1.088 [0.989–1.204] (24) | 0.715 [0.624–0.803] (24) | 0.385 [0.356–0.428] (24) | 0.410 [0.355–0.555] (24) |
| 1000 | 0.320 [0.299–0.341] (24) | 1.713 [1.539–2.781] (24) | 1.468 [1.375–2.244] (24) | 0.595 [0.545–0.711] (24) | 0.373 [0.334–0.430] (24) | 0.395 [0.350–0.486] (24) |
| 3000 | 0.255 [0.224–0.341] (24) | 2.080 [1.955–2.159] (24) | 2.823 [1.930–3.320] (24) | 0.517 [0.461–0.664] (24) | 0.340 [0.276–0.366] (24) | 0.275 [0.264–0.288] (24) |
| 10000 | 0.165 [0.150–0.216] (24) | 3.743 [3.354–5.379] (24) | 3.140 [2.921–3.515] (24) | 0.587 [0.574–0.661] (24) | 0.207 [0.188–0.243] (24) | 0.205 [0.174–0.223] (24) |
| 30000 | 0.135 [0.124–0.149] (24) | 6.997 [5.834–9.714] (24) | 4.558 [4.472–4.708] (24) | 1.323 [0.984–1.453] (24) | 0.153 [0.145–0.165] (24) | 0.152 [0.145–0.185] (24) |

**filtered / toggle: TodoMVC's shape: a keyed list of N todos filtered, every other one done.**

| N | vanilla | Solid 1 | Solid 2 | tea | direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 100 | 0.190 [0.174–0.211] (24) | 0.340 [0.329–0.375] (24) | 0.458 [0.420–0.555] (24) | 0.373 [0.310–0.515] (24) | 0.382 [0.338–0.465] (24) | — |
| 1000 | 0.193 [0.164–0.226] (24) | 0.345 [0.329–0.356] (24) | 0.450 [0.390–0.521] (24) | 0.445 [0.369–0.510] (24) | 0.485 [0.447–0.519] (24) | — |

**filtered / filter: TodoMVC's shape: a keyed list of N todos filtered, every other one done.**

| N | vanilla | Solid 1 | Solid 2 | tea | direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 100 | 0.855 [0.445–1.499] (24) | 2.993 [2.089–3.692] (24) | 3.312 [2.413–4.187] (24) | 3.020 [2.313–3.643] (24) | 2.140 [1.699–3.042] (24) | — |
| 1000 | 2.995 [2.120–6.794] (24) | 9.337 [7.518–13.292] (24) | 10.042 [8.158–12.898] (24) | 8.540 [7.351–12.573] (24) | 8.708 [6.660–11.756] (24) | — |

**filtered / tick: TodoMVC's shape: a keyed list of N todos filtered, every other one done.**

| N | vanilla | Solid 1 | Solid 2 | tea | direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 100 | 0.213 [0.199–0.226] (24) | 0.363 [0.344–0.391] (24) | 0.480 [0.434–0.626] (24) | 0.318 [0.270–0.351] (24) | 0.212 [0.185–0.240] (24) | — |
| 1000 | 0.180 [0.174–0.190] (24) | 0.347 [0.339–0.366] (24) | 0.470 [0.404–0.566] (24) | 0.355 [0.292–0.406] (24) | 0.202 [0.190–0.219] (24) | — |

**width / field: model width: W fields, one changes.**

| N | vanilla | Solid 1 | Solid 2 | tea | direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 4 | 0.205 [0.195–0.218] (24) | 0.405 [0.380–0.481] (24) | 0.520 [0.474–0.718] (24) | 0.325 [0.309–0.371] (24) | 0.220 [0.205–0.230] (24) | — |
| 8 | 0.232 [0.208–0.255] (24) | 0.405 [0.385–0.441] (24) | 0.515 [0.485–0.640] (24) | 0.358 [0.302–0.385] (24) | 0.222 [0.209–0.255] (24) | — |
| 16 | 0.208 [0.200–0.221] (24) | 0.405 [0.390–0.452] (24) | 0.555 [0.519–0.696] (24) | 0.303 [0.284–0.335] (24) | 0.220 [0.204–0.238] (24) | — |
| 17 | 0.213 [0.199–0.230] (24) | 0.423 [0.400–0.451] (24) | 0.593 [0.505–0.668] (24) | 0.303 [0.295–0.351] (24) | 0.230 [0.214–0.259] (24) | — |
| 20 | 0.222 [0.204–0.252] (24) | 0.415 [0.395–0.466] (24) | 0.567 [0.528–0.655] (24) | 0.332 [0.306–0.363] (24) | 0.238 [0.230–0.251] (24) | — |
| 32 | 0.205 [0.195–0.220] (24) | 0.450 [0.389–0.476] (24) | 0.570 [0.505–0.690] (24) | 0.298 [0.275–0.354] (24) | 0.232 [0.210–0.257] (24) | — |
| 64 | 0.195 [0.185–0.205] (24) | 0.393 [0.369–0.436] (24) | 0.558 [0.519–0.707] (24) | 0.343 [0.310–0.360] (24) | 0.225 [0.210–0.235] (24) | — |
| 128 | 0.195 [0.190–0.221] (24) | 0.418 [0.394–0.461] (24) | 0.562 [0.532–0.760] (24) | 0.325 [0.299–0.392] (24) | 0.233 [0.209–0.270] (24) | — |
| 256 | 0.215 [0.200–0.230] (24) | 0.427 [0.390–0.471] (24) | 0.558 [0.530–0.749] (24) | 0.405 [0.346–0.494] (24) | 0.220 [0.194–0.236] (24) | — |
| 1024 | 0.200 [0.190–0.216] (24) | 0.408 [0.394–0.448] (24) | 0.625 [0.535–0.773] (24) | 1.420 [1.368–1.504] (24) | 1.235 [1.165–1.481] (24) | — |

**depth / leaf: model depth: the value D records deep.**

| N | vanilla | Solid 1 | Solid 2 | tea | direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 1 | 0.210 [0.195–0.216] (24) | 0.445 [0.419–0.465] (24) | 0.530 [0.514–0.775] (24) | 0.333 [0.300–0.368] (24) | 0.235 [0.220–0.250] (24) | 0.230 [0.219–0.250] (24) |
| 2 | 0.215 [0.205–0.226] (24) | 0.425 [0.409–0.448] (24) | 0.565 [0.525–0.706] (24) | 0.315 [0.292–0.376] (24) | 0.235 [0.225–0.255] (24) | 0.235 [0.210–0.256] (24) |
| 4 | 0.227 [0.210–0.250] (24) | 0.425 [0.400–0.461] (24) | 0.590 [0.524–0.754] (24) | 0.332 [0.314–0.405] (24) | 0.227 [0.209–0.261] (24) | 0.238 [0.215–0.251] (24) |
| 8 | 0.210 [0.200–0.221] (24) | 0.452 [0.426–0.485] (24) | 0.560 [0.534–0.779] (24) | 0.368 [0.324–0.418] (24) | 0.253 [0.229–0.275] (24) | 0.245 [0.220–0.281] (24) |
| 16 | 0.215 [0.200–0.271] (24) | 0.510 [0.479–0.556] (24) | 0.725 [0.604–0.821] (24) | 0.352 [0.325–0.446] (24) | 0.235 [0.215–0.280] (24) | 0.267 [0.235–0.296] (24) |
| 32 | 0.207 [0.194–0.220] (24) | 0.583 [0.534–0.625] (24) | 0.817 [0.671–0.925] (24) | 0.438 [0.394–0.537] (24) | 0.290 [0.240–0.350] (24) | 0.245 [0.229–0.272] (24) |
| 64 | 0.210 [0.185–0.220] (24) | 0.645 [0.570–0.690] (24) | 0.995 [0.769–1.205] (24) | 0.465 [0.420–0.690] (24) | 0.360 [0.310–0.436] (24) | 0.255 [0.235–0.310] (24) |
| 128 | 0.265 [0.214–0.286] (24) | 0.682 [0.619–0.931] (24) | 1.095 [1.006–1.271] (24) | 0.660 [0.583–0.880] (24) | 0.563 [0.535–0.775] (24) | 0.300 [0.270–0.385] (24) |

**derived / tick: derived view: top 50 of N items filtered and sorted, an unrelated field changes.**

| N | vanilla | Solid 1 | Solid 2 | tea | direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 100 | 0.198 [0.185–0.210] (24) | 0.360 [0.349–0.385] (24) | 0.455 [0.415–0.576] (24) | 0.350 [0.289–0.415] (24) | 0.220 [0.210–0.243] (24) | — |
| 300 | 0.200 [0.189–0.215] (24) | 0.385 [0.354–0.491] (24) | 0.488 [0.410–0.585] (24) | 0.323 [0.281–0.387] (24) | 0.210 [0.204–0.231] (24) | — |
| 1000 | 0.198 [0.190–0.210] (24) | 0.365 [0.360–0.389] (24) | 0.480 [0.439–0.613] (24) | 0.340 [0.307–0.397] (24) | 0.228 [0.220–0.245] (24) | — |
| 3000 | 0.215 [0.210–0.241] (24) | 0.363 [0.350–0.386] (24) | 0.515 [0.429–0.602] (24) | 0.288 [0.270–0.346] (24) | 0.248 [0.225–0.289] (24) | — |
| 10000 | 0.210 [0.200–0.231] (24) | 0.433 [0.379–0.481] (24) | 0.493 [0.420–0.616] (24) | 0.298 [0.289–0.347] (24) | 0.248 [0.229–0.285] (24) | — |
| 30000 | 0.208 [0.200–0.220] (24) | 0.375 [0.364–0.388] (24) | 0.450 [0.408–0.561] (24) | 0.305 [0.279–0.368] (24) | 0.273 [0.235–0.308] (24) | — |
| 100000 | 0.205 [0.190–0.216] (24) | 0.368 [0.350–0.392] (24) | 0.437 [0.409–0.585] (24) | 0.342 [0.304–0.376] (24) | 0.270 [0.234–0.315] (24) | — |

**live / tick: live rows: N keyed rows, each a controlled input and a helper's markup, an unrelated field changes.**

| N | vanilla | Solid 1 | Solid 2 | tea | direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 100 | 0.197 [0.185–0.240] (24) | 0.445 [0.369–0.480] (24) | 0.438 [0.410–0.578] (24) | 0.333 [0.299–0.390] (24) | 0.248 [0.239–0.274] (24) | 0.222 [0.210–0.267] (24) |
| 300 | 0.230 [0.219–0.250] (24) | 0.360 [0.354–0.371] (24) | 0.538 [0.441–0.639] (24) | 0.345 [0.319–0.401] (24) | 0.260 [0.245–0.287] (24) | 0.228 [0.214–0.257] (24) |
| 1000 | 0.200 [0.185–0.216] (24) | 0.385 [0.370–0.395] (24) | 0.520 [0.446–0.626] (24) | 0.338 [0.295–0.386] (24) | 0.310 [0.269–0.370] (24) | 0.240 [0.219–0.266] (24) |
| 3000 | 0.125 [0.115–0.140] (24) | 0.250 [0.224–0.311] (24) | 0.305 [0.274–0.341] (24) | 0.210 [0.200–0.230] (24) | 0.187 [0.164–0.221] (24) | 0.147 [0.134–0.160] (24) |
| 10000 | 0.070 [0.065–0.075] (24) | 0.148 [0.139–0.156] (24) | 0.202 [0.179–0.236] (24) | 0.132 [0.115–0.159] (24) | 0.105 [0.094–0.111] (24) | 0.095 [0.085–0.105] (24) |

**helperRows / tick: rows holding a helper: N keyed rows, each a helper's markup and no input, an unrelated field changes.**

| N | vanilla | Solid 1 | Solid 2 | tea | direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 100 | 0.205 [0.195–0.220] (24) | 0.350 [0.339–0.375] (24) | 0.425 [0.390–0.555] (24) | 0.322 [0.310–0.360] (24) | 0.218 [0.199–0.248] (24) | — |
| 300 | 0.200 [0.187–0.215] (24) | 0.380 [0.353–0.466] (24) | 0.438 [0.410–0.570] (24) | 0.330 [0.304–0.389] (24) | 0.217 [0.204–0.235] (24) | — |
| 1000 | 0.215 [0.189–0.231] (24) | 0.375 [0.354–0.414] (24) | 0.565 [0.520–0.601] (24) | 0.308 [0.289–0.355] (24) | 0.230 [0.214–0.240] (24) | — |
| 3000 | 0.125 [0.115–0.132] (24) | 0.360 [0.349–0.381] (24) | 0.442 [0.409–0.480] (24) | 0.305 [0.290–0.336] (24) | 0.215 [0.188–0.235] (24) | — |
| 10000 | 0.073 [0.065–0.080] (24) | 0.193 [0.184–0.216] (24) | 0.248 [0.234–0.287] (24) | 0.178 [0.165–0.195] (24) | 0.123 [0.114–0.141] (24) | — |

**tree / tick: helper tree: a recursive helper D levels deep, an unrelated field changes.**

| N | vanilla | Solid 1 | Solid 2 | tea | direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 4 | 0.205 [0.195–0.220] (24) | 0.382 [0.357–0.409] (24) | 0.450 [0.415–0.551] (24) | 0.308 [0.280–0.344] (24) | 0.230 [0.219–0.240] (24) | — |
| 6 | 0.210 [0.199–0.241] (24) | 0.380 [0.365–0.401] (24) | 0.423 [0.409–0.546] (24) | 0.310 [0.284–0.341] (24) | 0.260 [0.231–0.301] (24) | — |
| 8 | 0.250 [0.224–0.303] (24) | 0.375 [0.365–0.415] (24) | 0.520 [0.455–0.567] (24) | 0.310 [0.295–0.328] (24) | 0.222 [0.214–0.236] (24) | — |
| 10 | 0.223 [0.205–0.246] (24) | 0.382 [0.368–0.401] (24) | 0.475 [0.410–0.565] (24) | 0.338 [0.315–0.385] (24) | 0.225 [0.214–0.240] (24) | — |
| 12 | 0.200 [0.192–0.216] (24) | 0.353 [0.187–0.370] (24) | 0.450 [0.395–0.560] (24) | 0.317 [0.280–0.361] (24) | 0.225 [0.212–0.250] (24) | — |

**burst / burst: K messages in one task, on the 1 000-hole page of `holes`.**

| K | vanilla | Solid 1 | Solid 2 | tea | direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 1 | 0.255 [0.225–0.301] (24) | 0.488 [0.462–0.516] (24) | 0.565 [0.465–0.667] (24) | 0.425 [0.390–0.496] (24) | 0.302 [0.269–0.336] (24) | 0.275 [0.255–0.314] (24) |
| 3 | 0.290 [0.269–0.305] (24) | 0.585 [0.570–0.627] (24) | 0.542 [0.505–0.631] (24) | 0.452 [0.414–0.534] (24) | 0.322 [0.289–0.355] (24) | 0.302 [0.290–0.330] (24) |
| 10 | 0.365 [0.350–0.395] (24) | 0.960 [0.860–1.055] (24) | 0.815 [0.704–0.891] (24) | 0.685 [0.647–0.726] (24) | 0.440 [0.395–0.531] (24) | 0.428 [0.375–0.486] (24) |
| 30 | 0.715 [0.675–0.751] (24) | 1.777 [1.701–2.275] (24) | 1.270 [1.207–1.353] (24) | 1.010 [0.924–1.140] (24) | 0.780 [0.734–0.810] (24) | 0.680 [0.650–0.718] (24) |
| 100 | 1.757 [1.682–1.901] (24) | 3.855 [3.640–4.005] (24) | 2.928 [2.829–3.035] (24) | 2.075 [1.988–2.286] (24) | 1.985 [1.836–2.066] (24) | 1.540 [1.504–1.616] (24) |
| 300 | 4.570 [4.434–4.780] (24) | 9.540 [9.180–9.695] (24) | 6.752 [6.635–6.884] (24) | 4.685 [4.517–4.870] (24) | 4.892 [4.651–5.081] (24) | 3.928 [3.766–4.046] (24) |
| 1000 | 13.230 [12.994–13.464] (24) | 18.817 [18.017–19.113] (24) | 16.367 [16.192–16.643] (24) | 12.398 [12.228–12.571] (24) | 13.402 [13.263–13.506] (24) | 11.720 [11.581–11.893] (24) |

**stream / stream: K messages per 60 Hz tick for 3 s, on the 1 000-hole page of `holes`.**

| K | vanilla | Solid 1 | Solid 2 | tea | direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 1 | 0.232 [0.231–0.233] (2) | 0.375 [0.374–0.376] (2) | 0.453 [0.452–0.455] (2) | 0.348 [0.345–0.350] (2) | 0.258 [0.257–0.260] (2) | 0.305 [0.299–0.310] (2) |
| 10 | 0.041 [0.041–0.041] (2) | 0.067 [0.067–0.067] (2) | 0.068 [0.068–0.068] (2) | 0.050 [0.050–0.050] (2) | 0.044 [0.043–0.044] (2) | 0.046 [0.045–0.048] (2) |
| 100 | 0.020 [0.019–0.020] (2) | 0.032 [0.032–0.032] (2) | 0.028 [0.028–0.028] (2) | 0.019 [0.019–0.019] (2) | 0.019 [0.019–0.019] (2) | 0.018 [0.018–0.018] (2) |



- **Live 10,000:** 0.105 [0.094–0.111] versus vanilla 0.070 [0.065–0.075] ms,
  **1.50×**, above 1.15×; direct is faster than tea's 0.133 ms. The `Go` handler is one model
  spread and one tick-group call; the edited set is empty and no row walk runs. The control
  capture listener and guarded dispatch are still reached. See `fixed-paths.json` and the profiles.
- **Derived 100,000:** 0.270 [0.234–0.315] versus 0.205 [0.190–0.216] ms,
  **1.317×**, above 1.15×. The endpoint slope from N=100 to 100,000 is approximately 0.03:
  the work is flat, but flat is not the same as within the ratio bar. Its handler calls only
  the tick group; the sort/filter/take computation runs at mount, not per tick.
- **Depth 128:** **2.123×**, above 1.3×, with separate IQRs from both vanilla and P3.
  Direct worsens from 1.12× at depth 1 to 1.40× at 32 and 1.71× at 64. The k-cap and repeated
  paths are the mechanism (§3), not a DOM operation growing with depth. Bytes grow from
  **516 to 2671 B**, **16.97 B per added level** over this interval, above the 4 B hypothesis.
- **Helper rows 10,000:** 0.123 versus 0.073 ms, **1.690×**, above the static-heavy 1.15× bar;
  this page has no controlled inputs. Its unrelated handler likewise spreads the model and
  calls one tick group; it does not traverse the rows. The residual constant path is therefore
  not explained by controlled restoration alone. **Helper tree depth 12** is 0.225 versus
  0.200 ms, **1.125×**, within that bar, with overlapping IQRs. Neither grows with tree size
  per message in this batch.
- **Width 1,024:** **1.235 versus 0.200 ms**, **6.175×**, above the pre-S7 1.3× bar. The
  archived bundle has a 1,024-property model and exactly one data setter; its handler is
  `e = { ...e, a: e.a + 1 }; q()`. It copies the entire wide record, not the whole view.
  This is the dictionary/spread cost research 59 §2 investigated; S7 owns in-place model work,
  but the earlier bound is still a measured miss. The 1,024-field byte total is reported above.
- **Earlier shapes:** holes 10,000 is **0.939× vanilla**; rows 30,000 one edit is **1.278×**,
  within the pre-S7 1.3× bar; that list's swap is **1.130×**, within 1.15× and tied with P3's
  median inside the spread. Their earlier speed checks hold in this batch.
- **Bursts:** K=1 is **1.186× vanilla**, a point miss of 1.15× with overlapping IQRs; K=1,000
  is **1.013×**. The fixed dispatch path is visible at the small end, then amortized by the
  burst's native synthetic-click work. These do not prove "the K=1 ratio at every K".
  `stream` point ratios are 1.112, 1.057 and 0.990 at K=1/10/100; two windows cannot certify
  the stream criterion.
- **Filtered list shape:** the filter switch at 1,000 rows remains much slower than vanilla.
  The derived list uses the general reconciler; this is informative rendering coverage, not
  the full TodoMVC application or a substitute for S5's recorded TodoMVC campaign.

The live/derived/helper-row misses are bounded fixed paths, not hidden O(N) rendering. That
localizes the problem without pretending each nanosecond belongs to a particular guard or
spread: source structure proves which work executes, and the diagnostic profiles separately
sample that path. No profiling result replaces the comparison medians or lowers a threshold.

The endpoint investigation uses 20 fresh pages per available candidate and the same five
warm-up clicks, with one profiled real click at each endpoint (540 profiles total). All five
requested candidates participate; P3 additionally participates on live and depth, where its
page exists. In live-10k, direct's tick writer samples **22.5 µs self/page**, the control-capture
listener **10.4 µs**, model update **8.65 µs**, and the guard **4.2 µs**. No list walk appears.
Derived samples concentrate in the model update (**13.15 µs**) and one tick writer (**9.15 µs**),
with guard/listener samples and no sort. Helper rows samples likewise stay in the one writer
and fixed update/listener. Width's wide-record handler alone samples **565 µs/page**, against
**12 µs** in its one hole writer; it is not 1,024 DOM patches.

These profiles confirm the executed paths and localize the work, but **do not price every
microsecond of the untraced median gap**: sampling, native/unattributed work and page warm-up
matter, especially on helper rows. Source proves the absence of a row traversal/sort; the
remaining guarded record-update/one-hole path is still slower than vanilla's mutable counter.
That is a remaining fixed-cost miss, not permission to call the 1.15× targets met. The
native/JS split of that residual remains unresolved; no invented fraction is assigned to a
particular guarantee. `profile-summary.md` carries all candidates and source columns, and the
complete profiles are losslessly gzip-compressed with uncompressed SHA-256s.

## 5. Guarantees and the navigation-fuzz boundary

`zorg build gates` passed on azathoth at the measured revision with the unchanged budgets.
The local macOS gate reproduced the two existing APFS case-folding failures and two browser
cache-pruning cases over the 999 ms CPU fallback (1,582 and 1,571 ms). The Linux run is the
green gate; the macOS result is retained, not called green.

`zorg build test-browser -Dcorpus=browser/direct` ran **360 cases**, with **358 passing** and
**two failing value-fuzz cases**, `NavigateCommands` and `Router`. The deterministic page
transcripts and the other paired value-fuzz cases passed. The two failures are driver code 2,
not a shrunk code-1 difference between platforms.

The diagnostic records the current action and `location.href` immediately before a value send,
with either platform as the first fuzz subject. For `NavigateCommands`, seed 1 sends
`Load "<b>"`; the next `Refused` send finds `chrome-error://chromewebdata/` and both fuzz-hook
globals undefined. For `Router`, `ClickedLink (External "😀")` leaves the app; the next
`UrlChanged` send finds the same error document. This happens with browser-tea first **and**
with direct first. `fuzzInstall` runs once after the original navigation; Chrome's new-document
script installs the driver's prelude, not the fuzzer's mount registry. A full load replaces the
JS realm, and the next `fuzzSend` unconditionally indexes its missing tea fallback registry.
The sequence never reaches the intended two-platform comparison.

The probes are **local Chrome 155 on macOS, diagnostic only**; all performance measurements
are azathoth's Chromium 153. The uninstrumented azathoth failures have the same missing-registry
stack. The diagnostic adds observation only; no navigation API, fixture, oracle or target was
changed to get a green result. The captured actions/hooks and the portable probe script are
archived alongside the Linux log.

**Criterion 8:** no stale-screen or differential rendering defect was established by this batch.
A failed harness is not a correctness pass: these two native navigation sequences still need a
lifecycle-aware oracle, and the first full V3 adversarial campaign specified after S4 remains
unperformed here. Existing corpus checks do not replace that campaign. This report does not
accept S4's guarantees as complete or waive that requirement.

## 6. Which real applications build today

Each entry below is an actual **release build** of the unchanged application's source on the
measured master, with `--platform=browser-direct --no-cache --diagnostics=json`. The complete
commands, exit codes and diagnostics are in `app-builds.json`. Warnings are separated from
errors; none is converted to a workaround or a permission to widen the platform.

| application | builds | observed boundary |
|---|---|---|
| Conduit, `examples/conduit/src` | **no** | one `not_implemented`, `Main.beni:257:18`: helper-computed document view, after ownership succeeds |
| full editing TodoMVC, `tests/corpus/browser/tea/TodoMVC.beni` | **no** | one `list_may_be_shared` at `Tea.element`, line 363: update changes `model.todos`, its deep exclusivity is not proven |
| Bike Wars, `examples/bike-wars/src` | **no** | two `list_still_used`, one `top_level_list_changed`; also two `prepend_in_loop` warnings |
| Sternhalma, `examples/sternhalma/src` | **no** | three `top_level_list_changed` observed; no port repair applied |
| non-editing routing TodoMVC, `browser/direct/TodoRouting.beni` | **yes** | reduced subject; release build exits 0 |
| sandbox TodoMVC, `bench/todomvc/apps/beni/Sandbox.beni` | **yes** | reduced subject; release build exits 0 |

These are build claims, not new full-app transcript or speed-parity claims. The ownership
refusals protect or conservatively enforce list ownership; they are not evidence that S4's
renderer threw. Conduit's helper gap is a lowering boundary. Later unpublished local Conduit
work is outside the measured revision, and none of these applications was edited for this inventory.

## 7. Verdict against the contract

| check | result in this batch | mechanism / limit |
|---|---|---|
| S4 live-10k ≤ 1.15× | **miss, 1.50×**; bytes 2,681 > 1,100 | fixed guarded update/one-hole path; control capture, no row scan |
| S4 derived-100k flat and ≤ 1.15× | flat, **ratio misses at 1.317×**; bytes 1,403 > 1,000 | derived computation skipped on tick; fixed update/one-hole path remains |
| S4 depth-128 ≤ 1.3× | **miss, 2.123×**; marginal 16.97 > 4 B/level | k=8 widening, 121 groups / 8,107 child reads plus nested model copies |
| helper rows / tree ≤ 1.15× | helper rows **miss, 1.690×**; tree passes, 1.125× | no per-message traversal; residual fixed cost / spread, overlapping tree IQRs |
| width-1024 ≤ 1.3× before S7 | **miss, 6.175×** | whole wide record copied; one DOM writer |
| earlier holes / rows speed checks | pass at required endpoints | holes 0.939×; row edit 1.278×; row swap 1.130×, tied with P3 |
| criterion 5 / table vanilla bars | eight point ratios meet; update is 1.2016075× | update is at the boundary; no claim that its tiny excess beyond 1.2 is resolved |
| criterion 5 / P3 speed | **fails on update**, 1.280×, separate IQRs | identity walk + separate indirect row writer, profiled in the exact warm-up |
| criterion 5 / bytes | **fires**, 4,102 B; non-core 3,403 > 2,400, core 699 > 600 | generic list representation, reconciler, guarded runtime and generated page/data |
| P3 bytes ≤ 0.85× | **fails**, 4,102 versus 3,122 B; bar 2,654 B today | direct is 1.314× P3, not 0.85×; also above the original fixed 2,936 B reading |
| criterion 8 | **not accepted**; no demonstrated stale-screen difference, native oracle still red | two full-navigation fuzz faults, reproduced on either platform first; full V3 owed |

The S4 amendment explicitly says it has no new numbered kill criterion of its own. Its speed
and byte hypotheses nevertheless miss. **The existing table kill criterion remains fired**,
and correctness debt prevents treating the slice as closed. The endpoint profiles localize the
constant paths but leave the exact native share of their small absolute gaps open; the depth
and width growth mechanisms and the byte miss are concrete.

No threshold has been moved. The existing owner deferrals remain exactly what
[`browser-direct.md` §13](../browser-direct.md#13-targets-and-kill-criteria) records; this report
supplies measurements and mechanisms, not a new deferral. A byte miss does not justify removing
controlled-input restoration, duplicate-key behavior, defect guards, or focus-preserving moves.
A performance miss is not repaired by replacing compiler output with P3.

## 8. Reproduction

At the measured source revision on azathoth, after installing Zorg 0.17.1+zorg.1:

```sh
cd ~/src/github.com/canassa/beni
nix develop .#browser -c bash
export PATH="$HOME/.local/bin:$PATH"
zorg build -Doptimize=ReleaseFast
bash bench/ui/results/2026-10-15-azathoth-s4/run.sh
```

`run.sh` includes every comparison candidate, rate 1, core masks, verification, all sweeps
and whole sizes. The captured run required the availability-fix continuation described in
§1. The final harness checks generator capability rather than accepting a stale file from
an unsupported P3 sweep; the 29 skipped pages agree with the continuation's manifest.
The exact continuation command was:

```sh
cd bench/ui
taskset -c 0-1,6-7 node scaling.mjs --full --no-build --untraced \
  --sweeps=filtered,width,depth,derived,live,helperRows,tree,burst,stream \
  --subjects=beni-release,beni-direct-release,p3,vanillajs,solid1,solid2 \
  --taskset=2-5,8-11 --out=results/2026-10-15-azathoth-s4/sweeps-rest.json
```

Regenerate the merged summary and read raw epochs as the result-directory README describes.
`node …/summarise.mjs` regenerates all median/IQR tables. Part-size reports use `size-parts.mjs`
with the matching `--file` and `--map-file`; full sizes use `sizes.mjs` and
`scaling-sizes.mjs`. `app-builds.mjs` records the unchanged release app inventory.

The diagnostic profiles run **after** all comparison timings and whole-size work, each in
one rotated batch with every available candidate, under the same masks:

```sh
taskset -c 0-1,6-7 node results/2026-10-15-azathoth-s4/profile-update.mjs \
  --n=20 --taskset=2-5,8-11
taskset -c 0-1,6-7 node results/2026-10-15-azathoth-s4/profile-rendering.mjs \
  --n=20 --taskset=2-5,8-11
node results/2026-10-15-azathoth-s4/profile-summary.mjs
```

For the native navigation fault, use `navigation-probe.mjs --beni=<binary> --chrome=<Chrome>`
with `--first=tea` and `--first=direct`. It patches only temporary driver copies to log the
current action/hooks. The two `code: 2` results, not the driver's report-writing exit 0,
are the reproduced failures. No profiling or diagnostic value is substituted into the
comparison tables.
