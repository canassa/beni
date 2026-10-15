# 98 — Direct's bytes are mostly entry code, not dense mask data

*2026-10-15. Research only: unchanged compiler, platform and application sources.
Base `7ff72c031`; Node 24.19.0; Apple M2 Pro; Chrome 155.0.8059.80.
The compiler SHA-256 and every baseline bundle hash are in
[`measurements.json`](../../../bench/direct-bytes/results/measurements.json).
Read after [95](95-parameterised-markup-templates.md) and
[97](97-conduit-dispatch-profiles.md).*

## 1. Finding

Conduit's **6,379 B / 20.32%** excess reproduces exactly. The parameterised
protocol is conditional overhead: TodoMVC's excess is **566 B / 9.17%**;
the table app is **1,025 B / 19.11% smaller** under direct and emits none of
that protocol. This is the unchanged `Sandbox.beni` TodoMVC benchmark, with
editing but without persistence, and `bench/ui/apps/beni/Main.beni`'s table.
Neither a no-edit TodoMVC nor an externally minified table substitutes for them.

Removing Conduit's **41,039 raw bytes of mask pairs** saves only **1,598 B
brotli** in isolation. Removing **20,935 raw bytes of patch entry declarators**
saves **3,496 B**. These deletions break execution; they identify costs, not
available optimisations. Neither number can be added to another independent
removal. Small reusable entry functions still have distinct bodies, inputs,
instance fields and call wiring; the repeated long binary strings compress well.

The cheapest promising executable rewrite is **shorter compiler-owned path
IDs**: **589 B** on Conduit and **68 B** on TodoMVC, with the same group
selections. Building group records as complete array literals instead of
mutating separate descriptors saves **233/19 B**, but changes object layout
and needs broader application validation before adoption. No measured encoding here
removes the entire gap. Packing the masks into u32 limbs actually **adds 50 B**
on Conduit. Do not select an encoding by its raw size.

## 2. What was measured

All loaded JavaScript, one `_main.mjs` per subject, exactly as emitted by
`build --release --no-cache`. No external minifier, instrumentation, maps,
HTML, CSS or unloaded `_direct-plan.json` is included. Compression is Node
zlib, brotli quality 11 **with the input size hint**, gzip level 9. These
baselines match report 97's Conduit figures, including the served trailing
newline. The archived bundles can be repriced without rebuilding.

| App / platform | Raw | Gzip 9 | Brotli 11 |
| --- | ---: | ---: | ---: |
| Conduit tea | 125,961 | 36,836 | 31,389 |
| Conduit direct | 209,384 | 45,432 | 37,768 |
| TodoMVC tea | 16,391 | 6,914 | 6,169 |
| TodoMVC direct | 18,950 | 7,472 | 6,735 |
| Table tea | 13,416 | 5,945 | 5,365 |
| Table direct | 11,402 | 4,788 | 4,340 |

The analysis uses existing release source maps, not a compiler patch. For
all six subjects the mapped build, after removing its map trailer, must be
byte-identical to the plain build. AST declaration positions identify the
original `dg`, `dp`, `dr`, `p`, `k`, `t` names and Direct runtime functions.
Only top-level runtime declarations qualify; a local's inherited map position
must not charge it as another copy of its containing function. Binary matrix
pairs are recognized structurally. JS indices are UTF-16 source positions;
raw lengths use UTF-8 bytes.

Two accounts answer different questions:

1. **Alone:** replace just one part's initializers by `0`, or its matrix by
   `[]`, in the original full bundle. Recompress the whole file.
2. **Ordered:** accumulate those same edits in the table's order and charge
   each successive compression delta. The remainder includes stubs and all
   compression interactions. It reconciles exactly to the download.

Every intermediate file is syntax checked. Deletion variants are **not run**:
removing selection, restatement or a descriptor violates the runtime contract.
No optimisation or DCE follows the replacements. Counts are emitted definitions,
not live instances: Conduit's 146 descriptors are not report 95's 114 analysis
leaf groups. The matrix is 41,039 B of array expression; report 97's 41,045 B
includes its enclosing call syntax.

## 3. Price each part alone

Cells are **raw source-span bytes / brotli saved by removing that part alone**.
Raw declarator spans include binding names; replacements retain those names.
A zero means absent, not proven free in all programs.

| Part | Conduit direct | TodoMVC direct | Table direct |
| --- | ---: | ---: | ---: |
| Consumer matrix | 41,039 / 1,598 | 483 / 142 | 0 / 0 |
| Group descriptors | 4,821 / 471 | 101 / 46 | 0 / 0 |
| Patch entry functions | 20,935 / 3,496 | 389 / 124 | 0 / 0 |
| Restate entry functions | 984 / 123 | 0 / 0 | 0 / 0 |
| Template factories, HTML and preparation | 26,884 / 4,568 | 437 / 146 | 0 / 0 |
| Selection runtime | 1,285 / 487 | 1,282 / 430 | 0 / 0 |
| Context and patch runtime | 1,957 / 696 | 1,259 / 467 | 0 / 0 |

Factories/preparation include `pN`, `kN` and `tN`: common template code as well
as the direct wrapper. They are **not all extra direct bytes**. Tea's equivalent
row costs 38,849 / 7,195 on Conduit, 4,588 / 1,464 on TodoMVC and
2,848 / 905 on table. Direct moves root work into the mounted program;
absence from the template row does not mean the DOM no longer needs building.

Selection runtime means `templateWanted`, `templateAny`, `templateSelect`,
`templateSelectNew`, `templateGroup`, `templateSameInputs`, insofar as they
survive optimisation. Several are inlined. Context/patch means the other
surviving top-level `template*` declarations, including row/map adapters and
state. This table does not silently include all Direct command/DOM runtime.

The following **ordered direct-minus-tea** account includes every downloaded
byte. Negative entries are offsets to the excess, not proposed savings.

| Part, removal order | Conduit | TodoMVC | Table |
| --- | ---: | ---: | ---: |
| Consumer matrix | +1,598 | +142 | 0 |
| Group descriptors | +550 | +19 | 0 |
| Patch entries | +3,534 | +99 | 0 |
| Restate entries | +163 | 0 | 0 |
| Factories / preparation | −2,161 | −1,337 | −905 |
| Selection runtime | +415 | +438 | 0 |
| Context / patch runtime | +664 | +497 | 0 |
| Remaining application, root handlers, core and runtime | +1,616 | +708 | −120 |
| **Total gap** | **+6,379** | **+566** | **−1,025** |

The last row before total is an explicit residual, not an attribution to one
mechanism. It includes direct's ungrouped root callbacks/row edits and tea's
ordinary view/update/host machinery. Report 97 §4 independently splits the
**whole** Conduit bundle into core, runtime, handlers, templates and startup;
its broader accounting charges only +39 B to core and +832 B to handlers
in the fixed comparison. Different removal orders/classifications cannot be
mixed. This finer table explains the parameterised cost within that result.

## 4. What the bytes buy, and Solid's equivalent

The sources below are the checked-out references, read for this investigation:
Solid `be46a04de7235607e83658627e82b0b3d30003d9`, dom-expressions
`e97e4290ec544bdade3c368ceae156baf54fab57`. The hashes identify what was actually inspected. This is a source comparison,
not a new full Solid benchmark or a claim that its runtime is free.

| Paid part | Runtime work it avoids / retains | Solid / dom-expressions encoding |
| --- | --- | --- |
| Consumer matrix | Substitutes each helper's formal reads into its actual call path. A quiet message skips unrelated groups before identity guards. Producer and placement masks still route live children. First selection reads these masks; cached selections do not scan them again. | No message × hole string matrix in the inspected JSX emission. Reactive reads link sources to computations in Solid's `graph.ts:link`; writes notify the graph. The graph is allocated at runtime, with ownership and stale-dependency cleanup. |
| Descriptors | Records source holes, every-render, capture-refresh and once-only facts plus patch/restate operations. Keeps event capture refresh separate from DOM entry. | `wrapDynamics` emits an effect's read and write callbacks. Previous-value objects/checks belong to generated effect code; runtime graph nodes carry scheduling/ownership state. Static facts need no per-message descriptor. |
| Patch entries | Callable group bodies let a cached selection enter only its ordered operations, rather than scanning all template identity guards. Identity checks still avoid redundant DOM writes inside entered groups. Each body reloads its own environment from the prepared arguments. | Direct element references live in the mounted template closure; the generated effect callback contains the DOM assignments and previous-value tests. There is still callback/code size, but no generic positional environment reconstruction for this TEA template protocol. |
| Restate entries | Propagate every-render work into already-present slots even when that producer's ordinary reads were not selected. Removing them can freeze nested clock/effect values. | Nested owned computations subscribe to their own sources; disposal follows owners. This is not equivalent to deleting restatement from beni without another scheduling mechanism. |
| Factories / preparation | Clone static HTML, retain node walks, cache local derivations, reconstruct the environment. Preparation remains O(arguments + derivation checks), even with precise group entry. | `template()` lazily parses and clones; JSX emits direct `firstChild`/`nextSibling` walks. Memo/effect reads retain dependencies. Both systems pay for templates; the difference is how later work is reached. |
| Selection runtime | Builds ordered normal/changed-input operation lists on first template/path/key use; reuses them later. O(groups) cold construction, O(selected operations) warm invocation, plus restates/captures. It does not eliminate all template patch/capture work. | Source-to-subscriber links and the scheduler's dirty queues select work. `readNodeFast` can link a read; `trimStaleDeps` removes obsolete links after recomputation. This trades static matrices/cache keys for runtime graph maintenance. |
| Context / patch runtime | Carries program, call path, row ownership and fallback placement through nested helpers. Refreshes event captures and restores ambient state in `finally`; coalesces overlapping row work. | Lexical closures/accessors and owner-scoped reactive computations retain inputs; `mapArray` manages row identity/owners. `insert` has a specialized patch-list seam for proven rows, with a classic fallback. A generic nested reactive helper still has lifecycle costs. |

Source anchors: [beni's protocol](../../../platforms/browser-direct/Direct.beni#L2760),
[entry generation](../../../platforms/browser/zig/dom.zig#L943),
[JSX dynamic effects](../../../references/dom-expressions/packages/babel-plugin-jsx/src/dom/template.ts#L323),
[template cloning](../../../references/dom-expressions/packages/runtime/src/client.js#L150),
[list insertion seam](../../../references/dom-expressions/packages/runtime/src/client.js#L605),
[Solid links](../../../references/solid/packages/signals/src/core/graph.ts#L124),
[read fast path](../../../references/solid/packages/signals/src/core/core.ts#L1855),
[row mapping](../../../references/solid/packages/signals/src/map.ts#L45).
These are local source links, not claims about a moving upstream release.

There is evidence for **visits avoided**, but not a 20% speed dividend:
report 95's 62 Conduit dispatches enter exactly their predicted live groups;
all five empty-write `ClickedLink · Internal` dispatches enter **zero** groups,
where report 94 compared 5–24 value kinds. Reader/Editor/Tour enter
105/63/145 instance/groups in total. `patchAll` remains 2/18, 1/12 and 6/32.
On the feed-tab example there are still 6 template patches, 12 captures,
6 selection lookups and 5 first constructions for 8 actual groups; editor input
has 3/7/3/3 for 3 groups. Those are development-copy observations from report
95, not CPU attribution or newly collected release counts.

TodoMVC has one 19-entry matrix for 11 message keys and only four outlined
helper groups (the edit input); the main list/controls use direct root code.
Its 7 distinct mask strings explain why a fixed selection/context runtime
cost dominates its 566 B net excess. Table has no helper protocol, no matrix
and no outlined groups: its message-specialised root/row code obtains the
1,025 B net saving without this generic helper machinery.

Report 97's rotated 30-page untraced Conduit medians, tea/direct, are
feed **0.3175/0.3400 ms**, favorite **0.3475/0.3400 ms**, editor
**0.4175/0.3725 ms**. IQRs overlap. These whole-message results do not isolate
a speed benefit for any one row in the byte table. In particular, removing
selection and scanning every group is a semantic/precision regression even
if one tiny benchmark appeared faster.

## 5. Independent executable trials

Every row starts from the original baseline, not the previous row. Cells show
**resulting brotli / saved brotli**; positive saving is smaller. Full raw/gzip/
brotli ledgers and compressed source snapshots are retained beside the scripts.

| Encoding | Conduit | TodoMVC | Table |
| --- | ---: | ---: | ---: |
| Baseline | 37,768 / 0 | 6,735 / 0 | 4,340 / 0 |
| Short path IDs | 37,179 / 589 | 6,667 / 68 | 4,340 / 0 |
| Complete group array records | 37,535 / 233 | 6,716 / 19 | 4,340 / 0 |
| Literal plan object | 37,715 / 53 | 6,728 / 7 | 4,340 / 0 |
| Trim trailing mask zeroes | 37,721 / 47 | 6,728 / 7 | 4,340 / 0 |
| Short internal protocol fields | 37,781 / −13 | 6,716 / 19 | 4,340 / 0 |
| u32 mask limbs | 37,818 / −50 | 6,746 / −11 | 4,340 / 0 |
| Short paths + trimmed zeroes | 37,209 / 559 | 6,697 / 38 | 4,340 / 0 |

**Short paths:** replace each `module:site` token with a deterministic dense
base-36 token, consistently in source-hole IDs, source IDs and every slash
component of call/producer keys. For example, `"10:101/8:552"` becomes two
short tokens separated by the same slash. Runtime concatenation and lookups
remain; there is **no decoder**. The prototype recognizes only protocol-shaped
string literals. An implementation must operate on typed metadata before
printing, with input-derived stable numbering; never rename ordinary user
strings or make IDs depend on worker completion. Keep readable inspection IDs
in the unloaded plan/debug output through a separate mapping if needed.

**Complete group records:** replace `dg=[holes,every,capture,once]` plus
`templateGroup(dg,patch,restate)` with the complete literal
`[holes,every,capture,once,patch,restate]`; read indices 4/5 instead of named
`$$patch`/`$$restate` properties. There is still one distinct descriptor per
group: **do not deduplicate equal descriptors**, because operation attachment
makes their identity load-bearing. The prototype leaves dead `dg=0` and
`templateGroup=0` stubs, a conservative estimate of what real DCE could emit.
It removes initialization calls/mutations, but changes arrays with named
properties into longer arrays: timing is required before recommending adoption.

**Literal plan:** emit `{key:mask,...,$$templates:new Map()}` directly, instead
of allocating pairs and populating an initially empty object in a loop.
Conduit's now-dead `templatePlan` function remains in the measured prototype;
no unrelated cleanup is credited. Object construction/hidden classes change,
so this needs a mount/first-selection check; 53 B is a small prize.

**Trim zeroes:** `"101000"` → `"101"`. The runtime only asks whether
`charAt(key)==="1"`; an out-of-range `""` remains false. It saves 16,464 raw
Conduit bytes but just 47 brotli. Composing it with short paths **loses 30 B**
relative to short paths alone; TodoMVC's 7 B is only a direction. This is why
the ledger measures each step and does not sum independent wins.

**u32 limbs:** convert each mask to little-endian words, replacing its read by
`(words[key>>>5] >>> (key&31) & 1)===1`. This preserves selection and introduces
no load-time decoder. It saves 27,084 raw Conduit bytes but **loses** compressed
bytes, so it is not proposed for size. Missing high words shift as zero for
the same false result as the original out-of-range test.

**Short fields:** consistently shorten the six private `$$directContext`,
`$$templates`, `$$patch`, `$$restate`, `$$arguments`, `$$template` protocol
properties across every reader/writer in the complete bundle. The Conduit loss
rules out applying this blindly. Renaming across a separately shipped boundary
would require agreement with its reader, not a token-only guess.

## 6. Speed risk and ranking

The small Chrome kernel experiment is separate from application timing:
20 alternating-order rounds after 5 warm-ups, 2,000,000 reads each, using
Conduit's 331 masks and 97 key positions. Both mask kernels return 106,259;
both dictionary kernels return 194,000,000. Raw observations are
[`speed.json`](../../../bench/direct-bytes/results/speed.json).

| Kernel | Median ms | Observed range ms |
| --- | ---: | ---: |
| String `charAt` mask test | 5.30 | 5.00–5.60 |
| u32 limb test | 4.50 | 4.30–4.80 |
| Full-string dictionary keys | 41.00 | 35.70–51.40 |
| Dense short dictionary keys | 32.20 | 31.80–35.80 |

These are warmed lookup kernels, not template patch timings. Dictionary keys
are prebuilt; the experiment excludes call-path construction, ownership, DOM,
mount and JIT first use. Dense numeric-looking keys also change the engine's
property representation. A shorter-key kernel is not evidence for a specified
percentage application speedup. The limbs' kernel speed does not rescue their
negative size result.

Ranked next steps, with runtime acceptance conditions:

1. **Short typed protocol IDs — 589/68/0 B.** Best measured size return; same
   asymptotic work and exact masks. Compiler metadata/printing change, not
   `Minify.zig` token work. Preserve path uniqueness and deterministic IDs,
   verify the visit oracle and paired value fuzz. Application timing follows below.
2. **Literal complete group records — 233/19/0 B.** Keep all existing entries,
   selections, capture refresh and restates. Emitter plus runtime-layout change.
   The targeted Chrome timing below has overlapping spreads; check mount and
   warmed patch across the full UI harness before acceptance. Reject a
   reproducible slowdown. This is **not full speed acceptance**.
3. **Literal plan objects — 53/7/0 B.** Remove temporary arrays/population loop;
   emitter change. Check mount, first selection and object lookup shape before
   accepting. Do not spend a hot-path regression on a 53 B saving.
4. **Trim trailing zeroes — 47/7/0 B alone.** Metadata printing change, no new
   work or decode. Consider only without short IDs, or reprice in the eventual
   final bundle; the measured combination loses bytes against rank 1.
5. **Ahead-of-time selected operation lists.** Replace first-use mask scanning,
   string-key cache construction and selection runtime with ordered lists per
   template/call path/key, sharing equal selections. This targets the measured
   487 B selection-runtime removal ceiling plus part of the 1,598 B matrix
   ceiling, **not their guaranteed sum**. Added list literals and call-site
   pointers may exceed the saving. No prototype size or speed claim here.
   Needs whole-program analysis, bounded emitted data, a conservative value-root
   fallback and correct every-render/capture/restate/row modes. Preserve the
   independent visit oracle; benchmark cold and warm paths against Solid 2.
6. **Direct lexical group environments / specialization of helper entries.**
   Avoid reloading prepared positional environments in each `dp` and consider
   eliminating generic wrappers for statically resolved call patterns. The
   3,496 B entry-removal experiment locates the opportunity; it is **not** a
   saving estimate, since DOM work must remain. Needs whole-program closure/
   escape analysis, sharing to prevent code duplication, and unchanged row,
   event and immutable-field identity. Solid's closure emission is the reference.
   Larger design work, unpriced, no runtime-speed recommendation yet.

Do not exchange precise group entry for a generic scan, merge functions by
adding a per-hole branch, pack strings that need runtime decoding, remove
restates, or install a signal graph merely because it looks smaller in JSX.
Those add work or change the scheduling model; none is supported by these
measurements. The first four candidates preserve the current scheduling model.

The path-ID prototype was also run through report 97's fresh-page Conduit
harness: 15 fresh pages per operation/subject/mode, rotated and reversed order,
real CDP clicks/input, unchanged scripted API/virtual clock, setup outside the
measurement, no CSS. Every post-event DOM/property transcript agrees. The
`browser-direct-release` label in the new artifact means **short IDs**, and
`direct-original` means the unchanged direct baseline.

| Message | Tea ms | Direct original ms | Short IDs ms | Original / short-ID ranges ms |
| --- | ---: | ---: | ---: | --- |
| Feed tab | 0.430 | 0.440 | 0.420 | 0.340–0.655 / 0.355–0.580 |
| Favorite | 0.365 | 0.360 | 0.365 | 0.265–0.410 / 0.265–0.520 |
| Editor input | 0.365 | 0.355 | 0.345 | 0.315–0.410 / 0.310–0.415 |

Traced script medians, original/short IDs, are 0.767/0.748, 0.607/0.580 and
0.588/0.609 ms respectively. The mixed directions and overlapping spreads
establish **no reproducible slowdown or speedup** in this batch. They do not
prove parity with Solid or speed acceptance across all helper/fallback shapes.
This is the best-supported byte candidate to implement and then gate against
Solid 2 with the full UI harness. Raw observations, hashes and host load are in
[`path-timing.json`](../../../bench/direct-bytes/results/path-timing.json).

The complete group-record prototype received a separate batch with the same
protocol and sample count. Its `browser-direct-release` label means **complete
group records**, not short IDs. Do not compare absolute latencies across the
two batches as if load had been fixed.

| Message | Tea ms | Original ms | Group arrays ms | Original / group-array ranges ms |
| --- | ---: | ---: | ---: | --- |
| Feed tab | 0.340 | 0.360 | 0.355 | 0.290–0.545 / 0.310–0.560 |
| Favorite | 0.280 | 0.310 | 0.325 | 0.225–0.435 / 0.220–0.430 |
| Editor input | 0.305 | 0.285 | 0.300 | 0.250–0.345 / 0.260–0.345 |

Traced original/group-array medians are 0.651/0.637, 0.573/0.574 and
0.545/0.543 ms. All transcripts agree. The two higher untraced medians remain
inside overlapping spreads; this single batch establishes neither a reproducible
slowdown nor a speed win. The changed array layout remains a full-harness risk,
rather than grounds for a claim that these 233 B are free. Raw observations are
[`group-timing.json`](../../../bench/direct-bytes/results/group-timing.json).

## 7. Validation and reproduction

The eight executable variants (including baseline) pass **40 differential
page transcripts**: all Conduit Reader/Editor/Tour scripts, a TodoMVC script
covering add/toggle/filter/edit/toggle-all/clear, and a table script covering
create/select/swap/update/remove/append/clear. The driver seeds crypto so table
labels compare exactly. Comparison includes the driver's DOM/property/error
transcript; no random-label normalization is used. Full value fuzz and the
development visit oracle are required for an implementation; these release
bundle edits do not claim to run those development checks.

`zorg build test test-blackbox fmt-check beni-fmt-check` completed with
**1,318 passes, 15 skips and the two already documented macOS case-folding
failures** in `build_test`. No test or budget was changed. The instruction-budget
`zorg build gates` remains owed on supported x86-64 Linux; macOS cannot provide
that verdict. This PR changes research scripts/artifacts/docs only. No compiler,
platform, core, application or run-hash change is included.

Reproduce from the repository root with the pinned shell and UI benchmark's
pinned npm dependencies installed (`npm ci` in `bench/ui/apps/solid1`):

```sh
direnv exec . zorg build test test-blackbox fmt-check beni-fmt-check
# The safe compiler was frozen for this experiment; BENI may name another one.
direnv exec . node bench/direct-bytes/measure.mjs
direnv exec . node bench/direct-bytes/prototypes.mjs
direnv exec . node bench/direct-bytes/verify.mjs
CHROME=/path/to/chrome direnv exec . node bench/direct-bytes/speed.mjs
CHROME=/path/to/chrome direnv exec . node bench/direct-bytes/timing.mjs > path-timing.json
CHROME=/path/to/chrome direnv exec . node bench/direct-bytes/timing.mjs inline-group-records > group-timing.json
```

The archive stores baseline/prototype JavaScript as lossless `.mjs.gz` files;
these gzip envelopes are storage, not the measured gzip/brotli delivery result.
`measurements.json` has both independent and ordered accounting, original
bindings/source names and exact spans; `prototypes.json` prices additional
encodings independently. Scripts reconstruct all variants from the baseline.
No `src/` patch or measurement compiler is needed.
