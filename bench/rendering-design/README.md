# Rendering design research — issue #172 / research 106

[Interactive HTML report](report.html) · [Answer and decision](../../docs/design/research/106-rendering-design.md).
[Full-range mixed graph](results/stress/graphs/mixed-growth.svg),
[family stress graphs](results/stress/graphs/family-growth.svg),
[measured target crossings](results/stress/crossings.md).

The size-only extension is in progress. The mixed family has measured 512 kB
brotli crossings for all six successful strategies, including vanilla at
100,352 components; direct is compiler-limited. Open `report.html` in a browser,
or run `node bench/rendering-design/serve-report.mjs` from the repository root
and visit **http://127.0.0.1:8765/report.html**.

The [original N≤32 graphs](results/graphs/mixed-growth.png),
[slope matrix](results/graphs/slopes.png) and [fits](results/fits.md) are retained
as the small-app calibration, separately from the stress extension above.
This replaces the earlier synthetic dispatch experiment in `bench/compile-to-vanilla/`.
Research only: no compiler/runtime changes and no repository gates or suites.

## Subject and compiler derivation

`catalogue.mjs` emits ten distinct UI structures: keyed action lists, validation
forms, tabs, nested helpers, recursive comment trees, counter/toggle clusters,
sortable tables, modals, input filters and derived summaries. Each has real typed
beni Model/Msg/init/update/view source. Components vary fields, labels, nesting,
step values, validation thresholds and multi-field writes. Each seed shuffles the
catalogue; every N is a prefix of that ordering. N=1,2,4,8,16,32; seeds=17,101,2027.
Mixed plus ten homogeneous families gives **198 apps / 2,079 component instances**.
The catalogue is finite: adding a component is not adding an entirely new algorithm.
Vanilla and Solid reuse factories with configuration; the compiler candidates do
not yet factor equivalent factories across modules. This is an important part of
the measured residual gap, not grounds to extrapolate to a 500 kB application.

`build-today.mjs` builds every app with the real ReleaseFast compiler for
`browser-tea` and `browser-direct`, release plus source maps. It dumps each
component's public BIR. `bir.mjs` derives writes from reducer result records and
reads by walking expressions, lexical environments and helper calls; recursion
conservatively joins argument dependencies. `ownership.mjs` recognizes fresh
per-instance arrays, same-field operations, and absence of sibling/callback reads
of the old array. `audit.mjs` checks the closed sandbox root and pure-call subset:
no model snapshots escape, unknown/effectful primitives are rejected. This is a
restricted recognizer, **not a general ownership proof for all beni**. No reads,
writes, patch sets or mutation permissions appear in catalogue metadata.

All candidates lower the same BIR into run-once DOM factories, safe DOM text and
attribute operations, branch teardown, controlled input restoration, a defect
stop guard, and keyed identity. They differ in executed state/update machinery:

- **A / `partial`:** specializes each reducer arm, erases local DOM messages,
  and calls only bindings whose source-derived reads intersect its writes.
- **B / `static`:** retains TEA reducers/messages; instruments actual branch
  writes into dirty bits and emits static consumer calls. No dynamic read graph.
- **C / `local`:** retains reducers/messages, routes events through instance
  closures and patches that component's binding list. No language change.
- **D / `cells`:** lowers arms to owned cell writes; dynamically tracks root
  binding reads. `examples/*/Shape0.cells-proposal.beni.txt` shows the proposed surface.
  It is a design sketch, not a feature accepted by today's compiler.

The common array edit journal is inferred from actual List operations. It does
not skip the source's model computation: a `List.map` still visits its input.
Stable-key edits patch only changed rows; filtering, sorting, permutation,
duplicate keys or uncertain provenance keep a full keyed fallback. The fallback
uses Solid 2 rc.9's actual `reconcileArrays`, with detached new nodes.
`vanilla.js` independently implements all ten shapes in handwritten style;
`solid.jsx` independently ports list and form with Solid's JSX compiler, signals,
projection selector and `For`. See [actual prior-art compiler output](prior-art/README.md).

The original N≤32 campaign checks static types and exhaustive matches with the
real compiler before lowering. In the stress extension, after native curves end,
larger prototype points consume real per-module BIR dumps without another
whole-app build. The prototypes cover pure sandbox rendering. Managed effects and typed
host errors are fixed external costs; these apps do not exercise them. There is
no claim that this research lowerer implements all beni guarantees for arbitrary
input. A production pass must preserve those boundaries and reject/fall back
when a proof is absent; a runtime defect remains an uncaught defect and stops
further dispatch, never a fabricated typed error.

## Reproduce

From the repository root, with the pinned flake environment and a built compiler:

```sh
cd bench/rendering-design
npm ci --ignore-scripts
cd ../..
node bench/rendering-design/generate.mjs
BENI=zig-out/bin/beni node bench/rendering-design/build-today.mjs
node bench/rendering-design/audit.mjs
node bench/rendering-design/measure.mjs
node bench/rendering-design/solid.mjs
node bench/rendering-design/examples.mjs
CHROME=/path/to/chromium node bench/rendering-design/validate.mjs
CHROME=/path/to/chromium node bench/rendering-design/lifetimes.mjs
uv run --with matplotlib==3.10.7 --with numpy==2.3.4 python bench/rendering-design/report.py
```

The actual compiler was built in an isolated azathoth worktree at the commit in
`results/today-protocol.json` using `nix develop .#browser -c zig build
-Doptimize=ReleaseFast`. No gate was run. The attempted ordinary build on the Mac
was killed in `build_id`; all retained today builds use the fresh Linux compiler.
The compiler, source, BIR and bundle identities are retained. `.out/` and
`node_modules/` are disposable, ignored products; examples preserve readable
source, BIR, ideal output and full dependency witnesses for each shape. Source snapshots use `.beni.txt`: they
are archived generator inputs, including a proposed language, not canonical
repository source. Disposable projects live in `.out/`, outside the formatter's
source walk. Historical Chrome traces retain their original `/out/` URL paths.

For timing, generate the two extra apps with `node perf-generate.mjs` (from this
directory), then run build-today, measure and solid with
`CASES_FILE=/.out/perf-cases.json RESULT_PREFIX=perf-`. Copy generated output to the
same path in the isolated Linux checkout, then, with no other campaign running:

```sh
nix develop .#browser -c sh -c 'export CHROME=$(command -v chromium) CHROME_CPU=2-5,8-11 DRIVER_CPU=0-1,6-7; taskset -c 0-1,6-7 node bench/rendering-design/timing.mjs'
```

The driver and trace analysis reuse `bench/ui/lib/{cdp,trace}.mjs` from this repo.
The machine identity, governor, Chrome version, affinities and load samples are in
`results/timing.json`. The completed campaign retains 828 measured clicks. Twelve rotated trials use fresh pages and two warm cycles;
real CDP clicks are traced through commit. Report medians/IQR, not significance
from tiny percentage differences. Timing is end-to-end update plus rendering;
it does not separately subtract CPU spent in core/List. Raw per-click metrics
and first-trial Chrome traces are retained, including failed runs.

## Byte and validation accounting

All seven candidates use Terser 5.51.2, module mode, two compress passes and
identifier mangling. Original compiler-release prices are also retained. Price
one rendering response with brotli quality 11/size hint, gzip 9 and raw bytes.
`measure.mjs` deletes exact source-map spans owned by core, including inlined
spans. Unmapped gaps inherit their containing declaration. Runtime and app spans
stay in original order before recompression. Rendering extracts can be syntactically
incomplete: they are byte attribution artifacts, **never the files executed**.
Executable entry files are run with their dependencies. The `full` byte field
prices the emitted entry JavaScript before attribution. The fixed prototype
`core.mjs` is a separate dependency excluded from this rendering study, as are
real compiler core spans. Solid's imported code is all rendering in these ports.

Runtime compressed alone is a diagnostic; `rendering - runtime_alone` is the app
increment in that context. Separately compressed pieces are not additive. Vanilla
has no framework package, but its guard/reconciliation helpers are counted as
shared rendering support, not free bytes. Solid files retain their source-map URL
trailer for debugging; byte prices and size hashes exclude it, validation/timing
hashes identify the actual served file including the trailer.

`results/sizes.json` has 1,386 observations; `solid-sizes.json` has 36. Fits use
18 points per family/strategy, report per-seed slope ranges, upper-range slopes
and residual RMSE. An OLS intercept is not the rendering runtime floor; mixed
curves bend when all ten families have appeared. Avoid linear extrapolation.

Validation executes all 1,422 minified pages. Every shape's messages are exercised
on first/last instances; every instance is driven for mixed N32. Compare initial,
transition and final DOM to today's TEA, including controlled values, batched list
edits and surviving keyed row identity. Separate probes cover detached row/branch
callbacks. Full DOM transcripts are disposable `.out/validation/`; their hashes,
counts, bundle hashes and errors are retained. Direct fails 28 pages in the nested
helper path, filed as [#189](https://github.com/canassa/beni/issues/189); its bytes
remain plotted but failed operations are not reported as fast timings. The three selected mixed-app timing actions pass on direct; they do not exercise its failing nested action.

After building the extra timing apps, run `CHROME=/path/to/chromium node
bench/rendering-design/perf-validate.mjs` for the complete 1,000/10,000-row order,
content and identity checks (16 pages). Run `node bench/rendering-design/manifest.mjs`
last: it verifies campaign counts, raw-byte attribution, price hashes, served
validation/timing hashes and known versus unexpected failures, then hashes the
retained artifacts. It requires all outputs from the preceding steps.

During development, this broader oracle found an incorrect reconciler integration
(new nodes were attached too soon) and an incorrect Solid projection call. Both
were fixed, all affected prices rebuilt, and the complete final sweep repeated.
The earlier invalid measurements are not included in these results.

## Size-only stress sweep and HTML report

The follow-up request extends the same catalogue until each strategy/family curve
actually reaches **512,000 brotli bytes**. It does not increase row population,
append padding or fill labels with random strings. N counts independently owned
shape instances. Original N≤32 has three seeds; the larger sweep uses seed 17 on
a 1.5× grid starting at 64, rounded up to multiples of 16, with closer
measured inputs selected from the observed slope near 512 kB. This estimates
only the next component count; every reported byte size is measured. Each curve stops at its
own first measured crossing. Vanilla and Solid's shared factories can need many
more components than compiler-emitted separate factories.

`stress.mjs` checkpoints whole-response measurements in
`results/stress/observations.jsonl`; `protocol.json` records the compiler and
measurement-source hashes. It builds each native platform until that curve crosses or encounters a
recorded resource failure, then measures each active strategy in a separate
process. Larger prototype points still use real per-component BIR dumps, but
are not newly checked full-app builds after the native curves have ended. Once every compiler-derived curve has crossed, the shared-factory
baselines continue independently from the same reproducible app specs. Concurrent
size workers are memory-bounded; this is neither a speed campaign nor a project
suite. A failure is retained, never substituted with an extrapolated size.

```sh
BENI=zig-out/bin/beni node bench/rendering-design/stress.mjs
node bench/rendering-design/html-report.mjs
uv run --with matplotlib==3.10.7 --with numpy==2.3.4 python bench/rendering-design/stress-report.py
node bench/rendering-design/serve-report.mjs
```

Open **http://127.0.0.1:8765/report.html**. The generated `report.html` is also a
standalone offline file: no CDN, fetch, framework or external asset is required.
It includes interactive family/strategy/metric controls, exact point values,
local slopes, the crossing matrix, all measured results, CSV/JSON downloads,
the original native release-build ledger with input/output hashes,
conclusions and methodological limits. Incomplete curves are explicitly marked.
`watch-report.mjs` can refresh it from the isolated azathoth campaign while it
runs; reload the page to see new checkpoints. `stress-report.py` exports the
size-only PNG/SVG figures, CSV and interval fits. Neither reads timing data.

Run the size sweep on Linux: its resource controls use `prlimit` and `flock`.
HTML generation and viewing work independently of that compiler host. The native
ledger retains `build_ms` as an orchestration diagnostic that includes resource
admission wait, not a compiler-speed benchmark.

The extended sweep found two limits before its first large target crossings:
`browser-direct` was killed by the kernel at mixed N=1,728 (about 30 GB resident
memory), tracked in [#203](https://github.com/canassa/beni/issues/203). A separate
64-child routing-module layout also failed direct under a 16 GiB address-space
cap; it is not substituted into the flat-source curves. Subsequent compiler
invocations use that cap and retain failed endpoints in `stopped.jsonl`.
Terser overflowed the default JavaScript stack on the flat N1,728 TEA output;
the harness resumes with a 16 MiB V8 stack / 32 MiB OS stack, retaining exactly
the same minifier and compression options. Protocol amendments record these
resource changes. Three disjoint family queues rotate through component counts rather than finishing
one family before starting the next. Native compiler builds remain serialized.
`resource-run.mjs` admits at most six CPU slots and 26,000 MiB of estimated
concurrent memory reservations; large minifiers can run alongside smaller jobs.
A native build reserves four CPU slots and an N-dependent 1–16 GiB;
its enforced address-space cap remains 16 GiB. These are scheduling limits,
not measured application costs or repository gates. Repeated identical byte
strings are compressed only once within each account; a seven-strategy check
retains exact equality of every price and attribution field.

Large accounts can borrow one additional CPU slot and 1 GiB for two independent
compression jobs. The parent's thread is parked while they run. Admission is
nonblocking: a full pool uses the original serial path, so workers cannot
hold all slots while waiting for extra slots. Brotli/gzip options and byte
strings are identical; `results/stress/parallel-compression-check.json` records
exact agreement of all seven account fields on the actual 9.34 MB N3,888 TEA
bundle. This changes measurement throughput only, not application timings.

Immutable compiler-pinned BIR dumps are hard-linked from the source-hash cache
into larger apps instead of rewriting every unchanged prefix module. Existing
per-app dumps must byte-match the cache; cross-device links fall back to copies.
`results/stress/bir-link-check.json` retains exact source, chunk and witness
agreement for all four lowerings through 32 linked dumps. This reduces filesystem
I/O without changing the generated programs.

Ordinary resource requests are admitted in arrival order, preventing a large
job from starving behind newer small jobs. Optional compression helpers can
borrow otherwise idle capacity while the oldest request cannot yet fit; they
yield immediately when it can. `results/stress/fair-admission-check.json`
records the controlled ordering check. The six CPU-slot and 26,000 MiB
reservation limits are unchanged.

The report also compares a mixed app with the mean of ten homogeneous apps at
the same measured component count. At N2,592, C's brotli response is 24.8%
larger while its raw size changes by only 0.01%; B's brotli response changes
by −1.2%. This demonstrates a composition-dependent compression effect, so
homogeneous slopes are not additive predictions for mixed apps. The comparison
and its plotted values are in `results/stress/mixture-compression.json` and
`results/stress/graphs/mixture-compression.svg`.
