# 103 — Which platform runtime a page actually runs, and why the rest ships

*2026-10-15. Beni master `1c5d16049`; Node 24.19.0; Google Chrome 154.0.8037.97 headless; x86-64
Linux, pinned to cores 8–23; azathoth was not used. Read after [102](102-beni-output-size.md),
whose byte protocol and unit cut this report reuses. 100 is reserved for S8; 101 and 102 exist;
master and the one open PR were checked before choosing 103. Measurements and scripts:
[`bench/runtime-coverage/`](../../../bench/runtime-coverage/).*

The owner, 2026-10-15: "I thought we were compiling the framework away. 8.1 kB is too much. …
Check what can be trimmed, only live code should be shipped."

## 0. Answer

**About 40 % of the platform runtime a real page ships never runs in its scripts, and most of that
is not dead.** Conduit on `browser-tea` ships 7.2 kB of platform runtime (brotli, *alone*); 3.0 kB of
it never executed in the three corpus scripts. Of those 3.0 kB, **1.0 kB could go** because the
compiler could know statically that it is unreachable. The other 2.1 kB is code a real session
reaches: defect teardown, rule 9's precise error wrapping, list edits the scripts do not make,
subscriptions that leave. On `browser-direct` the picture is different, and it answers the owner's
question directly. **The framework is not compiled away on `browser-direct` yet.** Conduit ships
8.4 kB of platform runtime there, and **3.2 kB of it is framework that direct's compile-time
analysis was meant to replace**, live and dead together. The TEA patch and row runtime (`Rt`'s
`forKeyed`, `forPosition`, `childList`, `restate`…) is 2.1 kB. Direct's own run-time template
selection protocol is 1.2 kB. Even TodoMVC on `browser-direct` ships 0.9 kB of the template
protocol.

| Platform runtime (brotli, alone) | shipped | never ran | removable: (a) known statically | (b) framework on direct | (d) can never run |
|---|---:|---:|---:|---:|---:|
| Conduit, tea | 7,211 | 2,997 | 1,040 | — | — |
| Conduit, direct | 8,448 | 3,232 | 1,042 | 1,486 dead · **3,214 live+dead** | 174 |
| TodoMVC, tea | 4,069 | 1,044 | 92 | — | — |
| TodoMVC, direct | 4,186 | 980 | 108 | 136 dead · 938 live+dead | 109 |
| Sternhalma, tea / direct | 1,438 / 2,421 | 346 / 597 | 50 / 64 | — / 293 dead · 1,257 | — / 90 |
| Bike Wars, tea / direct | 1,921 / 2,893 | 401 / 765 | 60 / 101 | — / 236 dead · 1,254 | — / 82 |
| table app, tea / direct | 2,577 / 1,841 | 637 / 610 | 12 / 8 | — | — |

The categories are the brief's. (a) is code reachable only through a value the compiler could
know statically. (b) is generic runtime that `browser-direct`'s compile-time analysis should have
replaced. (c) is needed but not reached by the scripts, and stays. (d) can never run. "Never ran" is every
never-executed byte, branches inside live functions included. Each figure is priced by deleting
those bytes and recompressing (§1), so the columns overlap and do not add.

**What this branch does about it** (§5). The coordinator assigned whole-program value-directed
elimination to another agent. This branch therefore records each (a) finding precisely for that
work (§3.1), and keeps its own changes to the runtime's structure. **One trim landed:
`Rt.template` is two exports**: a cloner for a template with no flag, and `templateOf` for the
rest. A page whose flagged templates share a flag then passes `templateOf` a constant, and the
release build folds it. It saves **Conduit 122 B tea / 63 B direct** and **Bike Wars 49 / 30 B**, measured on master
`afb554432`.
TodoMVC, Sternhalma and the table app stay byte for byte the same. A prototype of field-value
folding was measured and handed over instead of landed (§5.2): **−146 / −105 B** on Conduit (request
body kinds). It cannot reach the command arms, the largest (a) item, until fact 3 sees list
elements through `List`'s `base`.

**What remains, and why** (§6). Most of direct's 3.2 kB is design work for `browser-direct`.
Rows and branches inside helper templates must be compiled the way the page's own rows already
are, and the template protocol's per-key masks must become code. The largest (a) items wait for
the value-directed pass: command kinds and policies (0.35–0.45 kB on Conduit), Http's tracked
body, form bodies and timeouts (0.5–0.7 kB; Http is owned by other slices), and controlled-input
kinds (0.1–0.2 kB). Rule 9's wrapping, defect teardown and list reconciliation are guarantees.
They are kept, and they are most of what "never ran" on `browser-tea`. Beni's keyed-row runtime
is **not** larger than Solid's (§4): 1.6–1.7 kB against 2.4 kB for Solid 2's `mapArray` and
`reconcileArrays`.

## 1. Method

`run.mjs` builds each app with `--release --source-maps` for both platforms. The apps are
Conduit (one bundle, three corpus scripts: `ConduitEditor`, `ConduitReader`, `ConduitTour`),
`TodoMVC`, `Sternhalma`, `BikeWars`, and `bench/ui`'s table app driven by `table.steps`. The
table steps are create 1k, update every 10th, select, swap, remove, append 1k, replace, clear,
create 10k and clear. Each build runs through the gates' own `tests/browser/driver.mjs` in
headless Chrome. The driver is copied with two edits: `Profiler.startPreciseCoverage({callCount:
true, detailed: true})` before the page loads, and `Profiler.takePreciseCoverage` before the
target closes. A script means here exactly what it means in `zig build test-browser`.
**Every transcript equals its corpus golden**, except Sternhalma's. Chrome serialises a style's
pixel value rounded (`275.751px` against happy-dom's `275.751289px`), and the fixture has no
`.chrome-expected`. That is a pre-existing gap in `test-browser`, not a behaviour difference.

`analyse.mjs` cuts each bundle into research 102's top-level units (`bench/output-size/units.mjs`).
Each unit is owned by the source holding most of its mapped bytes and named by the beni
declaration at its binding. A byte is executed when the innermost V8 block range containing it
has a non-zero count, and Conduit's three runs are a union. A unit whose function body never ran
is *never called*. `classify.mjs` assigns every never-executed range of a platform unit to (a)–(d)
by a rule naming the declaration, and an unclassified range fails the run. Prices are research
102's *alone*: a group's units stubbed and the bundle recompressed, for what ships. Never-executed
bytes are priced by deleting them and recompressing. The text left is not a program; the figure
is a price. Small figures are noisy (a few are negative), so only totals are quoted. Brotli is
quality 11 with the size hint, on the one `_main.mjs`.

## 2. Per module (Conduit)

Brotli; *alone* here, *ordered* from research 102 §2 (the same bundles, master `d10749f70`).

| tea | shipped alone | ordered (102) | never ran | removable |
|---|---:|---:|---:|---:|
| `Rt` (DOM runtime, rows) | 3,489 | 3,523 | 1,733 | 166 |
| `Http` | 1,537 | 1,475 | 676 | 504 (Http, §3.1) |
| `Tea` | 1,024 | 1,080 | 515 | 429 |
| `Navigation` | 526 | 541 | 213 | 0 |
| `Hosted`, `Cmd`, `Sub`, `Listen`, `Storage`, `Browser`, `Html` | 1,572 | 1,081 | 769 | 290 |
| **all** | **7,211** | 7,700 | **2,997** | **1,040** |

| direct | shipped alone | ordered (102) | never ran | removable |
|---|---:|---:|---:|---:|
| `Direct` | 2,513 | 2,771 | 615 | 361 (+ 1,188 live template protocol, §3.2) |
| `Rt` | 2,435 | 2,415 | 1,413 | 1,372 (+ live: 2,103 alone beyond the primitives, §3.2) |
| `Http` | 1,394 | 1,438 | 554 | 506 (Http) |
| `Tea` | 791 | 931 | 410 | 311 |
| `Navigation` | 537 | 552 | 41 | 0 |
| `Hosted`, `Cmd`, `Storage`, `Listen`, `Html`, `Sub` | 656 | 810 | 273 | 74 |
| **all** | **8,448** | 8,917 | **3,232** | **2,623** |

`results/classified.json` has every app, every module and every label.

## 3. Every never-executed piece, by why it ships

### 3.1 (a) Known statically: for the value-directed pass

Each finding names the deciding value. The (b)–(d) tables list what stays.

| Function, branch | Deciding value (statically known) | Apps | Dead, alone |
|---|---|---|---:|
| `Tea.item` (`perform`'s callback): arms `KeyedNow`, `Cancel`, `CancelAll`, `After` | the tags of `Cmd.Item` any reachable code builds: Conduit uses `Cmd.keyed` (whose two bodies both may suspend, so `Keyed`), `Cmd.task`, `Cmd.do`, never `cancel`, `cancelAll`, `afterRender` | Conduit both | 450 tea / 354 direct, with the next five rows |
| `Tea.keyed`: the `Ignore`, `Queue`, `Concurrent` arms of the policy `case` | the `Policy` field of every `Keyed` item: both call sites pass `Cmd.Restart` | Conduit | (above) |
| `Tea.starter`, `startAfter`, `settleFirst`, `stopped`, `canceller`, `waitFor` | reached only from the arms above | Conduit | (above) |
| `Cmd.map`: arms `KeyedNow`, `Cancel`, `CancelAll`, `After` | the tags of items flowing into `Cmd.map` (the app's) | Conduit | (above) |
| `Hosted.mapLater`, `Hosted.afterRender`, `Hosted.eq` (key equality in `startsWith`) | reached only from `After` and `CancelAll` | Conduit | (above) |
| `Tea.running`, `close`, `stop`: the `Queued` arms | a `Queued` run is kept under a key only by `KeyedNow` | Conduit | (above) |
| `Tea.begin`: the fiber kind (`Hosted.run`, `unhear`) | the `Kind` of every subscription: Conduit's one is `Storage.onChange`, a hook | Conduit | 148 tea / 20 direct |
| `Tea.item`'s whole `switch`, every arm folded to `return undefined` | every `update` returns `Cmd.none`: no item is ever built | Sternhalma, Bike Wars | 34 / 51 |
| `Rt.affected`: `select` → its `options`; a named radio → `getElementsByName` | the elements the program renders with a `stateful` attribute (markup, static): none is a `select` or a radio | Conduit, TodoMVC | 209 tea / 111 direct; 16 / 63 |
| `Rt.edits`, `Direct.edits`: `markAndHold`, `holdEdit` (a checkbox's or radio's click) | the same: Conduit has no checkbox | Conduit | (above) |
| `Rt.delegate`, `Rt.fire`, `Direct.listen`, `Direct.delegate`: `preventDefault`, `stopPropagation` | each handler's flags, known by the lowering per handler | most | ≤ 80 |
| `Rt.fire`, `Direct.listen`: the walk up the `Html.map` chain | whether the program uses `Html.map` | TodoMVC, Sternhalma | ≤ 20 |
| `Rt.template`: flag 1 (`importNode`), flag 2 (`firstChild` of the wrapper), flags 2+4 (`gather` into a fragment) | the flags of the program's templates | Conduit, Bike Wars | 133 tea / 39 direct; 72 / 62. **Done here, §5.1** |
| `Http.payload`: the form arm (`FormData`); `Http.size`'s form arm; `problemOf`'s multipart `content-type` check; `String.toLower` with it | the `Body` tags built: `emptyBody`, `jsonBody`, never `formBody` | Conduit | 103 tea / 49 direct. Prototyped, §5.2 |
| `Http.tracked$s`, `chunks$s`, `size`, `utf8`, `orEmpty`, `failed`; `answer$s`'s tracking branch | the `tracker` field of every request: always `Nothing` (`Http.request`, not `Http.track`) | Conduit | 404 / 433 |
| `Http.exchange$s`'s timeout branch; `settled`'s `clearTimeout`; `timerOf`, `readingOf`'s `Just` | the `timeout` field of every request: always `Nothing` | Conduit | 156 tea |

Every one of these is a `case` on a constructor whose possible tags the program decides. Two
mechanisms would remove them. The general one is value-directed elimination: the tags a
constructor can hold, propagated to the `case`s that read them. The other is a runtime reshaped
so that each variant is a declaration of its own, reached only from where the value is built. §5.1
is the second for templates. For commands it would mean an `Item` carrying its own handler: a
change to `boundary.md` §9.8's command protocol that the value-directed pass makes unnecessary.

### 3.2 (b) The framework on `browser-direct`

| What | Why it ships | Conduit | TodoMVC | Sternhalma | Bike Wars |
|---|---|---:|---:|---:|---:|
| `Rt` beyond the eleven primitives TodoMVC uses (`forKeyed`, `forPosition`, `childList`, `childMaybe`, `restate`, `restateRows`, `again`, `patch`, `trimmed`, `reconcile`, `patchRow`, `sameInputs`…), live and dead | a row or a list of blocks inside a helper's markup (research 95's parameterised templates) goes through `dom`'s kinds, so TEA's patch and row runtime ships with it | 2,103 | 0 | 290 | 291 |
| `Direct`'s template protocol (`templateSelect`, `templateWanted`, `templatePatch`, `templatePlace`, `templateCapture`, `templateRow`, `templateMap*`…), live and dead | a helper's groups are selected at run time from per-key masks the compiler emits as strings (`"0011111…"`, keyed by call path), cached by program, template, path and key | 1,188 | 938 | 936 | 983 |
| both | | **3,214** | **938** | **1,257** | **1,254** |

Direct's premise (`browser-direct.md` §0, §3's *generality* row) is that "an unreached runtime
piece is not written" and that a fact known at compile time "ships no runtime". Both rows above
are facts known at compile time and interpreted at run time. The masks are the compiler's
analysis, written as data, and the TEA row runtime stands in for edit scripts the compiler could
emit, as it already does for the page's own rows (§6.2 there). No guarantee depends on either.

### 3.3 (c) Needed, not reached by the scripts: kept

| Label | Conduit tea / direct, alone |
|---|---:|
| Defects, mount errors, list edits and live rows the scripts do not make (`Rt.stop`, `stopped`, `run`'s mount errors, `reconcile`'s and `trimmed`'s general paths, `restateRows`, `childMaybe` emptying, `head`/`tail` of a slot list, `Direct.send`'s re-entrant queue, `Direct.fault`, `arm`'s teardown…) | 1,574 / 338 |
| Rule 9: each host failure wrapped and typed (`Storage`'s `SecurityError`/`QuotaExceededError`, `Navigation`'s `SecurityError`/`SyntaxError`, `Http`'s `TypeError`s, method and header checks) | 448 / 192 |
| Subscriptions and runs the scripts do not change (`Listen`'s and `Events`' unsubscribe closures, `Hosted.hear`'s release, `Tea.diff`'s leaving keys, `settle`) | 164 / 223 |
| `Tea.application` opened from a `file:` page | 243 / — |
| After-render work and re-entrant sends (`Browser.hosted`) | 171 / — |
| The release file's `flush` export | — / 14 |

On the table app every never-run byte is (c), apart from 12 B and 8 B of event options. It is
the reconciler's general paths: the scripts swap two rows and remove one, and the moves, the
LIS-free fallback and the map path never run.

### 3.4 (d) Can never run: for the owner

`browser-direct`'s release build keeps the template protocol's assertions of the compiler's own
tables. `templateWanted` and `templateFallbackEntered` call `fault "browser-direct visit invariant:
unbound value has no placement mask"`, `"… undeclared template fallback at …"` and `"… declared
fallback has no placement mask"`. That is **82–174 B** per app, and a correct compiler never
fires them. This is not a guarantee beni gives programs. Making them development-only is still the owner's
call. Where the next statement reads the missing value (`d.charAt`), a `TypeError` would still
stop the page. Where it does not (the `$value/…` lookup), a compiler defect would pass silently.
They go with the protocol if §3.2's first step lands.

## 4. Live code against Solid (rule 8)

Research 102 found beni's row reconciliation (2.0 kB alone) "larger than all of Solid's `web.js`".
That is the wrong comparison. Solid's keyed list mapping is `mapArray` in its signals core, not
`web.js`, and the DOM half is dom-expressions' `reconcileArrays`. Each side was minified and
compressed on its own (`rows.mjs`). For Solid that is esbuild then Terser, and for beni the
`--release` units of `Rt.forKeyed` and what it calls:

| | brotli |
|---|---:|
| Solid 2 `mapArray`, keyed half (`references/solid/packages/signals/src/map.ts`, `repeat` left out) | 1,862 |
| dom-expressions `reconcileArrays` | 602 |
| **Solid's keyed rows** | **2,381** |
| beni `browser-tea` keyed rows, TodoMVC (`forKeyed`, `trimmed`, `reconcile`, `patchRow`, `mountRow`, `sameInputs`) | 1,717 |
| beni `browser-tea` keyed rows, table app (`sameInputsBut`, `reselect` in place of `sameInputs`) | 1,557 |

Beni's keyed rows are smaller than Solid's, so the row runtime is not oversized. The large live
piece without a Solid counterpart is §3.2's template protocol: Solid's compiler writes each
component's effects as code, and nothing selects them at run time.

## 5. What this branch changes, and what it hands over

### 5.1 `Rt.template` is two exports (landed)

`backend.md` §15.3, amended. The `dom` lowering picks the cloner per template.
`template(html)` is for a template with no flag (nearly all of them), and `templateOf(html,
flags)` for one with any. One cloner taking every template's flags made a page with two kinds of
template ship every flag's branch, because the release build folds a parameter only when every
call passes the same constant. Conduit's templates use flags 0 and 4, Bike Wars' 0 and 2. Now
`templateOf` is called with one constant and folds to that flag's steps. `Rt` writes `template`
as `templateOf`'s steps for flag 0, so a page with no flagged template is byte for byte what it
was. A first version that wrote the parse more tightly grew TodoMVC by 16 B, since brotli prices
shape, not length. `Direct` supplies both.

| Release, brotli, on master `afb554432` | before | after | Δ |
|---|---:|---:|---:|
| Conduit tea / direct | 31,497 / 36,502 | 31,375 / 36,439 | **−122 / −63** |
| Bike Wars tea / direct | 9,254 / 11,120 | 9,205 / 11,090 | **−49 / −30** |
| TodoMVC, Sternhalma, table app (both) | — | — | 0, byte for byte |
| `emit/release/split/HolesPage`, `emit/release/direct/MapKind` | 1,894 / 4,256 | 1,840 / 4,181 | −54 / −75 |

(On the audit's master `1c5d16049` the same change measured −148 / −101 B on Conduit and −63 /
−83 B on Bike Wars. Master's own release changes since then took part of the same bytes.)

The table app's and TodoMVC's bundles do not change, so no js-framework-benchmark operation can
move. Fixtures: `emit/release/split/TemplateOneFlag`, a page whose one flag is a fragment's, ships
no `importNode`, `createDocumentFragment` or `gather`. `browser/direct/TemplateShapes` uses every
flag in one page, on both platforms, development and release, each value shown, hidden and shown
again. The `emit/dom/` and `emit/direct/` goldens show the new calls, and `tests/oracle/`'s
extractor reads both.

### 5.2 Field-value folding (prototyped, measured, handed over)

`results/field-values-prototype.patch` adds slice 10 to `Spec`. It computes the set of literals a
constructor field may hold, `x.p` with every object `x` may be a program literal with a tag, by
`tagValue`'s immutability argument extended to every field. It folds `x.p === k` and drops the
`switch` clauses no value enters. It is sound where `tagValue` is, plus one refinement: a site
that never escaped cannot be written through an unseen reference, so writes of unknown keys on
host objects (`Rt.putBack`'s `el[prop] = v`, which today turns `tagValue` off in every page with
a controlled input) no longer veto it. It passed all six Conduit runs and the other apps'
scripts. **It saved 146 B tea / 105 B direct on Conduit**, all of it request body kinds (`payload`'s
form arm, `size`'s, `problemOf`'s multipart check, `String.toLower`). It saved nothing elsewhere.
**It cannot reach the command arms.** Every item reaches `Tea.item` through `List.foldl`, and
`List.base` reads a non-array list through `$plain()`, a method that reads `this`. Fact 3 then
makes every list element ⊤. The callback's parameter is also shared by every `foldl` of the
program, since fact 3 is context-insensitive. Precise element flow through `List`'s
representation is the prerequisite for §3.1's largest rows. The coordinator gave this whole
mechanism to the value-directed elimination agent, so it is not landed here.

## 6. What remains, ranked

1. **`browser-direct`: compile the helper templates' rows, lists of blocks and group selection**
   (§3.2). This is 3.2 kB on Conduit and about 0.94 kB on every other direct page. It is design
   work for `browser-direct.md` §5–§6 (research 95's general lowering), not a trim. The owner's
   "compile the framework away" is this item.
2. **Value-directed elimination** (§3.1, another agent): commands and policies, subscription
   kinds, controlled-input kinds, event options, `Html.map` walks. It saves about 0.5–0.6 kB tea
   and 0.4–0.5 kB direct on Conduit, more with Http.
3. **Http, owned by other slices**: the tracked body (0.4 kB), timeouts (0.16 kB) and form bodies
   (0.1 kB) are all (a). Rule 9's wrapping (about 0.2 kB) stays.
4. **The owner's call**: direct's invariant assertions, 82–174 B (§3.4).
5. **Kept**: defect teardown, rule 9, list reconciliation's general paths, unsubscription. That is
   2.1 kB of Conduit tea's 3.0 kB that never ran, and 0.7 kB of direct's 3.2 kB.

## 7. Reproduction

```sh
npm ci --prefix bench/output-size                 # acorn, trace-mapping, terser, esbuild
zig build -Doptimize=ReleaseFast
node bench/runtime-coverage/run.mjs               # builds, runs every script in Chrome, checks goldens
node bench/runtime-coverage/analyse.mjs           # units, coverage, per-group tables
node bench/runtime-coverage/classify.mjs          # (a)–(d), per module, per label
node bench/runtime-coverage/direct-b.mjs          # §3.2's live+dead framework on direct
REFERENCES=… node bench/runtime-coverage/rows.mjs # §4 against Solid
OUT=zig-out/sizes node bench/runtime-coverage/sizes.mjs --json=…   # §5.1's before/after
node bench/runtime-coverage/unitdiff.mjs <before> <after>          # which declarations a change moved
```

`CHROME` picks the browser (default `google-chrome-stable`); `BENI` the compiler; `WORK` the output
directory. Results: `results/summary.json` holds the group tables, `results/classified.json` the
categories, labels and modules, and `results/sizes-*.json` §5.1's figures. All of these are
generated by the scripts above; regenerate them, never edit them by hand.
