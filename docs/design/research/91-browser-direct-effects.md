# Browser-direct effects: full TodoMVC comparison

2026-10-14. Native `zorg` 0.17.1+zorg.1 backend, Node 24.19.0; LLVM was not used.

The previous size-only stop was wrong. A foreign mount wrapper's signature
mentions `Cmd msg`, but the wrapper only returns the supplied mount in a
program record. Reach had exempted all command constructors, keeping the
whole driver. The generic inert-forwarder proof in `Sibling` now removes
that exemption; it is independent of platform or module names. Unknown
JavaScript, callback calls and tagged literals stay conservative. The entire
sibling must contain only inert exports: other code could produce a type
exposed by their annotations. Whole returned parameters also need matching
constructor-bearing type structure; nominal casts and casts of returned
callbacks retain the whole annotation. Both consumer and returned-value
fixtures lose the dead arm; producer and callback twins retain it. The consumer fixture fails with the fix disabled.
`backend.md` §9 owns the dated rule and its soundness argument.

The implementation supplies `Tea.element`, `Tea.document` and `Tea.application`
through compiled handlers, keyed policies, owned sends, value-taking and
navigation commands, subscriptions, dispatch-end rendered waits and after-render
work. This report replaces the earlier incomplete measurement, not the
specified acceptance criteria.

## Same-batch release bytes

`Sandbox.beni` has editing and local filters, without storage or routing.
`NoEditing.beni` is the routing/persistence build without editing. Each was
built with the same compiler and `--release --no-cache`. These are all emitted
JavaScript bytes, brotli quality 11; CSS and HTML are excluded consistently
with the existing TodoMVC size harness.

| Variant | tea raw | tea brotli | direct raw | direct brotli | direct / tea brotli |
|---|---:|---:|---:|---:|---:|
| Sandbox | 16,391 | 6,169 | 14,647 | 5,344 | 0.866 |
| Routing without editing | 21,757 | 8,258 | 19,136 | 7,026 | 0.851 |
| tastejs vanilla-es6, whole spec | 5,339 | 1,722 | — | — | — |

The vanilla subject is vendored unchanged from tastejs commit
`302b409c2b8510dc634fdd0e481196845109dc97`, with source/HTML/license checksums,
a pinned esbuild 0.27.0 production bundle, and its original static HTML
(1,055 raw bytes, served separately). It includes editing, hash routing and
JSON persistence. Beni's routing build omits editing and stores lines;
its sandbox omits routing/storage. These feature and persistence-format
differences matter when comparing to vanilla; they do not affect the
same-source direct/tea comparison. All five subjects pass their supported
feature contract in `2026-10-14-s5-parity.json` with no runtime errors.

The size-only stop is withdrawn: routing saves **14.9%**, sandbox **13.4%**.
The stronger absolute §13 targets still miss: routing is 4.08× vanilla's
JavaScript, over the 2× target and Svelte 4's recorded 4,246 B. The remaining
routing bundle genuinely reaches the subscription host, URL handling,
scopes and queued command execution. In particular, `Tea.begin` calls
`Hosted.fibered`, whose runtime `__beniFiberSubscriptions` test hook retains
`Tea.inFiber`, `Task.spawnIn` and fiber teardown even in release. This is an
identifiable retained mechanism, unlike the removed command-constructor
exemption. Its compressed share is not attributed by subtracting independent
module sizes.

## The three messages, 100 and 1,000 todos

Chrome 155.0.8059.41, Apple M2 Pro, one batch with rotated subjects. Every
sample uses a fresh page, six toggle warmups and preparation outside timing.
Each result verifies the rendered row/completed counts and persisted state.
No build or test suite ran alongside this final batch. Raw samples, machine
load, bundle hashes and compiler hash are in `2026-10-14-s5.json`.

Untraced real CDP input is timed from capture through the operation and eight
microtasks. Beni handles checkbox activation in `change`, after `click`, so
the endpoint waits through `change`; timing only `click` misses the update.
Vanilla commits add on Tab/`change`, beni on Enter/`keydown`. Traced samples
use the union of script intervals between user-timing marks, separately from
untraced samples. Nine untraced and three traced samples per cell: 360 total.
No geometric mean or aggregate speed claim is made.

### Untraced medians, ms

| Todos | Subject | Add one | Toggle one | Clear completed |
|---:|---|---:|---:|---:|
| 100 | browser-tea-Sandbox | 0.295 | 0.235 | 0.405 |
| 100 | browser-direct-Sandbox | 0.265 | 0.220 | 0.330 |
| 100 | browser-tea-NoEditing | 0.590 | 0.310 | 0.575 |
| 100 | browser-direct-NoEditing | 0.485 | 0.260 | 0.475 |
| 100 | vanilla-es6 | 0.765 | 0.205 | 0.500 |
| 1000 | browser-tea-Sandbox | 0.330 | 0.240 | 1.320 |
| 1000 | browser-direct-Sandbox | 0.365 | 0.250 | 1.385 |
| 1000 | browser-tea-NoEditing | 0.700 | 0.360 | 1.415 |
| 1000 | browser-direct-NoEditing | 0.680 | 0.335 | 1.465 |
| 1000 | vanilla-es6 | 4.560 | 0.485 | 3.150 |

### Traced script medians, ms

| Todos | Subject | Add one | Toggle one | Clear completed |
|---:|---|---:|---:|---:|---:|
| 100 | browser-tea-Sandbox | 0.335 | 0.300 | 0.434 |
| 100 | browser-direct-Sandbox | 0.287 | 0.258 | 0.358 |
| 100 | browser-tea-NoEditing | 0.619 | 0.397 | 0.596 |
| 100 | browser-direct-NoEditing | 0.533 | 0.328 | 0.530 |
| 100 | vanilla-es6 | 0.962 | 0.267 | 0.661 |
| 1000 | browser-tea-Sandbox | 0.357 | 0.292 | 1.371 |
| 1000 | browser-direct-Sandbox | 0.383 | 0.290 | 1.458 |
| 1000 | browser-tea-NoEditing | 0.752 | 0.437 | 1.505 |
| 1000 | browser-direct-NoEditing | 0.688 | 0.391 | 1.565 |
| 1000 | vanilla-es6 | 6.167 | 0.496 | 4.192 |

At 100 todos direct improves all three operations on both variants. At 1,000,
sandbox add is **1.11× tea**, sandbox clear **1.05×**, and routing clear
**1.04×**. The traced batch agrees on those three orderings. Sandbox toggle
is a near tie (untraced 1.04×, traced 0.99×), not evidence of a win or a
regression. Routing add/toggle improve. Against vanilla at 100, routing's
0.260 ms toggle is **1.27×** 0.205 ms, above §13's 1.2× target; the three
sandbox operations meet that target. At 1,000, both beni toggles meet the
separate 1.3× vanilla target.

**Criterion 6 still fires on the complete timing result**, not on bytes.
It requires the three messages to improve on today's platform at the two
specified sizes; wins at 100 do not erase the 1,000-todo misses. The old
size-only conclusion is withdrawn. *Amended 2026-10-14 (the owner):* the
owner deferred the timing condition to S8 (browser-direct.md §13 criterion 6).
S6 and S7 proceed; the misses remain recorded rather than claimed as wins.

The remaining timing mechanism is visible in generated handlers. Both add
and clear hand `List.filter(model.todos, visible)` to `Direct.reconcile`:
a derived list has lost the original append/removal script, as §6.2 predicts.
They also rescan the list to compute the active count. The editing sandbox's
row callback retains `isEditing`, `editingDraft` and `childHtml(editor(...))`,
as well as the ordinary completed/title groups. General reconciliation and
row/helper machinery remain instead of the exact list edit; eliminating a
render loop does not eliminate that work. These are structural observations
from the emitted code, not a numerical attribution of every microsecond.
Routing additionally serializes and schedules its storage command. The
0.050 ms routing and 0.065 ms sandbox clear gaps are reported as measured;
their individual CPU instructions were not sampled.

## Coverage corrections and remaining boundaries

- BikeWars is now explicitly built on direct using the unchanged external
  example sources, in `tests/pending/browser/direct/BikeWars`. RED pins two
  `list_still_used`, one `top_level_list_changed` and the existing two prepend
  warnings. No copy or source workaround was added.
- `RenderedWaiterCancelled` parks a real `Dom.rendered` waiter within a
  scheduler host turn before a second fiber defects. It logs `Cancelled`,
  never resumes, and passes dev/release on both platforms with one golden
  per build mode, plus value fuzz. Its platform adapter uses `Task.onTurn`
  for one drain only; cleanup drains keep the ordinary direct protocol.
- `DefectAfterRender`, also omitted previously, now runs unchanged on both
  platforms, with common goldens and value fuzz.
- `flush` is rooted only for an active effectful-host embedding protocol,
  or the existing library surface. Inert sandbox/empty pages no longer export
  it. Empty direct drops 347 → **327 B**, compared to master’s 316 B. The
  remaining 11 B are the new queued-send guard, required by the dated
  all-pages reentrant-send contract, not a hidden flush export.
- RandomValues is still a generator-result ownership summary limit, but its
  **diagnostic was a checker bug**. The exact-only tagger probe now discards
  approximate supplies. `RandomTaggerDiagnostic` proves the before/after
  whole diagnostic. RandomValues and ValueCommands remain rejected, now with
  `list_may_be_shared`; no other ownership verdict changed.
- The original `DefectInTurnRender` statement oracle is now explicitly checked
  in pending (CK-224, `PageFailed`). It compiles; its `throws press #bad` fails
  because direct evaluates that unused statement at mount only, as the existing
  S4/§8.4 contract says. This is a documented phase boundary, not an ownership
  rejection. The shared corpus still tests throwing value groups and stopped
  pages. No throws assertion was removed to manufacture parity.

There are now sixteen original tea programs pinned for ownership (CK-223),
including the full editing TodoMVC. Conduit’s three S6 pages remain at their
previous boundary; every other tea fixture is paired or explicitly pending.
Four instrumented phase cases retain their already decided separate transcripts:
`FlushLatched`, `FocusInFlush`, `SyncCommandOrder`, `DefectQueuedDropped`.

## Reproduction and validation

Build the compiler with `zorg build` (native backend), then use
`bench/todomvc/direct-size.mjs`, `vanilla-build.mjs`, `direct-time.mjs` and
`parity.mjs`. The vanilla README records installation and subject differences.
Results live in `bench/todomvc/results/2026-10-14-s5*.json`.

Native `zorg build gates` has only the four authorized macOS baseline failures:
two case-folding tests and two browser-driver CPU-budget tests. Run-hash
recording has only the two existing case-folding failures; it records no hash
for a failed run. The pending direct suite matches every pinned failure.
Review follow-ups add executable dev/release checks for nominal casts,
record-field casts, returned callbacks, callback-argument casts, tagged ABI
producers and mixed inert/producing siblings. A cross-type identity printed
`dropped` instead of `kept` with typed-result protection disabled; the
whole-sibling guard has its own before-fix regression. The tagger probe now
restores its previous exact-only flag with `defer`, including allocation errors.

The Reach and diagnostic regression fixtures were each run with their fix
disabled and failed, then restored and passed. No LLVM build was used.
