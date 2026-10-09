# 66 — The direct platform, slice S1: holes, handlers, the two oracles, and kill criterion 3

*2026-10-09. What `browser-direct.md` §14's slice S1 built, and what it measured against
§13's kill criterion 3. S1 covers text and attribute holes, constancy and baking, groups and
slots, one handler per message key, direct listeners, the `*` key, the development verify mode and
`--fuzz`. The owner's addition to the brief, sent through the manager: every artificial benchmark
is run at every slice, with every page `browser-direct` cannot build yet listed as skipped and its
reason. All figures are **[measured]** by the commands in §8. The design as built is
`browser-direct.md`'s *Amended 2026-10-09 (slice S1, as built)*; the interface is `boundary.md`
§9.4.6, version 1.7.*

---

## 0. The answer in five sentences

1. **Kill criterion 3 fires, on bytes.** Its speed halves pass: the hole handler is one compare
   and one write (`emit/direct/HoleHandler`), and holes 10 000 runs at **1.08× vanilla**
   untraced (release build: 0.070 ms against 0.065). The page's growth fails: the release bundle
   is **662 B at 10 holes and 36 102 B at 10 000**, while vanilla's (whose growth is its HTML)
   stays at 195 B and P3's at 442 B.
2. **The cause is the bake rule, not the handler path.** A hole no key writes is either baked
   into the template — only a model path whose `init` is a plain string, standing alone
   (`write-sets.md` §9.1, B5, O8) — or written once at mount by code: a walk and a write, about
   3.5 B brotli a hole. The sweep's page is one third `{model.name}` (baked) and two thirds
   `{model.count}` and `class={model.cls}`. Those are an `Int` text hole and an attribute, which
   the rule leaves to mount code. Widening the rule is O8, the owner's call. §3 has the numbers;
   nothing was tuned to pass.
3. **The release build is at or under 1.1× vanilla wherever S1 builds.** That covers holes,
   width up to 256, bursts and the stream. The exception is width 1 024 at 5.1×, which is V8's
   dictionary-mode spread that §13 leaves to S7. The development build pays for its verify mode
   on top: 8.9× at 10 000 holes, because it computes every hole again after every message, the
   static ones too.
4. **Both oracles run on every `browser/direct/` page.** Every page is built for both
   platforms, development and release, against one golden, or a `.tea-expected` that says why
   the platforms differ: Q1, Q2, the precision of write sets. The gates' page fuzzer sends
   message values to every pair that has no `.tea-expected`, through `--fuzz` builds, and no
   difference was found. The verify mode caught a deliberately broken handler at the first
   message, and stays silent on a correct page (`VerifyQuiet`).
5. **What S1 does not build is refused, naming its slice.** These are `For` (S2), components
   and markup helpers (S3), markup as a value, branches, `Show` and controlled inputs (S4), and
   effects (S5). So of the eleven artificial benchmarks, beni-direct measures holes, width,
   burst and stream. Rows, live rows, helper rows, helper tree, depth, derived and the table app
   are skipped with the compiler's reasons (§4).

## 1. What was built

- **Compiler**:
  - The write-set pass runs in a build whose lowering compiles programs, over every program
    constructor call (`Writes.runCalls`), once, before lowering (`Emit.buildDirect`). Its
    result reaches the lowering through version 1.7's calls: `programKeys`, `programHole`,
    `programCalls`, `programUpdate`, `programArm`, `programViewEnter`, `programMessage`,
    `programDispatch` and `reachesDebug`.
  - Arms are written in place: `update`'s branch for the key's first constructor, its fields
    bound to the handler's parameters. The view's values are evaluated in `view`'s own
    declaration context.
  - A per-declaration "reaches `Debug`" table is built over the whole program's edges, for the
    verify mode.
- **Lowering** (`platforms/browser-direct/zig/direct.zig`): `dom`'s template planner, reused,
  with baked holes. The mount holds the program's state in its own scope. Groups are formed by
  anchored read set and merged so that an element's attributes stay in source order. There is
  one handler per key, a direct listener per handler node with its flags in the DOM listener, a
  dispatcher only where needed, `patchAll` for a `*` key, and the verify check.
- **Runtime** (`Direct.beni`): `dom`'s attribute and text writes, the verify registry, the
  structural `same` and the throwing `wrong`, and `fuzzMount`.
- **Fixtures**:
  - `browser/direct/` pages, each built for both platforms:
    - re-stated from `browser/dom`: `Holes`, `GroupedReads`, `TrustedTurn`, `DefectInHandler`;
    - new: `EventReadsModel`, `SubmitFromWrite`, `VerifyQuiet`, `UnitHoles`,
      `DefectInListener`, `DefectInMount`, `MessageKeys`, `OpaqueUpdate`.
  - `emit/direct/` goldens: `HoleHandler`, `ConstantWriteOnce`, `MessageKeys`, `OpaqueUpdate`.
    The release golden is `emit/release/direct/HoleHandler`.
  - `build/bad/direct/` refusals: `For`, `MarkupHole`, `Controlled`.
  - A black-box test of `--fuzz`.
- **`ConstantWriteOnce` is an emit golden, not a page.** Its constant that needs code is
  `innerHTML` on `browser/dom`. That is a warning in the root package, and a page must build
  clean, so the golden pins the guard over a non-ASCII URL constant instead. The `innerHTML`
  page was run by hand on all four builds, and the typed text was kept.

## 2. The oracles

- **The verify mode catches a missed write.** A temporary edit to the compiler stopped the
  first key's handler from calling any group. The first click then stopped the page with:
  `browser-direct verify: the text hole at Main.beni:34:23 shows 0, but the model gives 1. The
  compiler missed a write`. The edit was removed. `VerifyQuiet` pins the other side: with
  `Debug.log` in a hole, a helper that logs two calls deep, `Random.value`, and a class list
  that `List.map` rebuilds of fresh tuples, the development transcript equals the release
  build's and `browser-tea`'s, so no value is evaluated twice that should not be.
- **The differential fuzz.** The gates fuzz every `browser/direct/` pair without a
  `.tea-expected`, `browser-tea` against `browser-direct`, by `--fuzz` builds that take message
  values: `Hello`, `Holes`, `MessageKeys`, `UnitHoles`, `VerifyQuiet`, `DefectAtMount`,
  `DefectInHandler`, `DefectInListener`, `DefectInMount`. Each is one seed of thirty steps,
  recorded by `zig build test-run-hashes`; every pair agreed. By hand, value messages, including
  a constructor no code builds (`Rename`, `Unbuilt`) and a nested one (`Nested (B 9)`), give
  identical pages on all four `--fuzz` builds: direct and tea, development and release.
  `zig build fuzz -Dcorpus=tea/Co` (Counters and the three Conduit scripts, fifty seeds of sixty
  steps, values on) passes.

## 3. Kill criterion 3

| part | bar | measured | verdict |
|---|---|---|---|
| the hole handler | one compare and one write | `$hany` = the arm, then `$g$14()`: `const $t = String$fromInt($model.tick); if ($t !== $s) { $w.data = $t; $s = $t; }` (`emit/direct/HoleHandler.js`) | **holds** |
| holes 10 000, untraced, release | ≤ 1.15× vanilla | **0.070 / 0.065 ms = 1.08×** (pages 0.070 and 0.075; vanilla 0.070 and 0.065). The in-page clock reads in 5 µs steps, so the ratio is ±0.08 | **holds** |
| the page's growth with N | no more than its HTML | release bundle, minified then brotli 11: **662 B at 10, 5 215 at 1 000, 36 102 at 10 000**. Vanilla 168 → 195; P3 394 → 442 | **fires** |

**What grows.** The sweep's page repeats `<p>{model.name}</p><p>{model.count}</p><p
class={model.cls}>x</p>`, and no key writes any of the three. `name`'s holes are baked: plain
strings from `init`. `count`'s holes (an `Int`) and `cls`'s attributes are not, by §9.1 as the
owner decided it (O8: "numbers aren't baked yet"; an attribute is never baked). Each is written
once at mount by a walk and a write, `w.data = String(model.count)`, which brotli does not
deduplicate the way it does repeated HTML: about **3.5 B a hole**. The handler path is direct;
the page's mount code grows. The two ways out are both the owner's to decide. One is O8 widened
to integers and attributes (a compile-time printer bit-exact with the runtime's). The other is a
mount that writes static holes from a table, one loop over all of them, which is a design change
§5.1 does not make. Neither was done here (rule 10).

**Which points the criterion judges.** Only holes 10 000 untraced (speed), the hole handler's
shape, and the holes page's bytes. Every other figure below is informational at this slice.

## 4. Every benchmark (the owner's addition)

Subjects: `beni` and `beni-release` (today's `browser-tea`), `beni-direct` (development, with its
verify mode) and `beni-direct-release`, `p3`, `solid1` and `vanillajs`. Chrome 153 headless,
`--taskset=8-15`, unthrottled.
- Traced: click to paint, script ms from a trace.
- Untraced: a real click timed in the page, in 5 µs steps.
- Holes, width, burst and stream are `--full` (every point, 2 pages × 4 samples).
- Rows, depth, derived, live, helper rows and tree are quick (3 points, 1 page × 3 samples).
- The table app is `bench.mjs`, n = 5, 4× throttled as js-framework-benchmark.

**Skipped by `browser-direct`, with the compiler's reason:**

| page | reason (`not_implemented`) | slice |
|---|---|---|
| rows (change, swap) | `browser-direct` does not compile a `For` yet | S2 |
| depth | markup as a value: the depth page's `view1 … viewD` are markup helpers | S3 inlines helpers; §14 schedules the sweep at S4 |
| derived | a `view` whose body computes its markup (a `let`) | S4 (§5.4) |
| live | markup as a value (each row's helper) and controlled inputs | S4 |
| helper rows, helper tree | markup as a value | S3 (helpers), S4 (recursive helper) |
| the table app (`bench.mjs`) | markup as a value: the app's `button` helper, and its `For` | S3, S2 |

`p3` has no page for width, derived, helper rows or tree (its pages time out; research 60 wrote
P3 for holes, rows, live and depth only).

### 4.1 The sweeps beni-direct builds

| sweep | point | traced, release ÷ vanilla | untraced, release ÷ vanilla | untraced, development ÷ vanilla (verify on) |
|---|--:|--:|--:|--:|
| holes | 10 | 0.99 | 1.08 | 1.25 |
| holes | 1 000 | 0.96 | 1.04 | 1.81 |
| holes | 10 000 | 1.39 | **1.08** | 8.85 |
| width | 256 | 2.14 | 1.18 | 1.45 |
| width | 1 024 | 6.11 | 5.12 | 5.71 |
| burst | 1 | 1.26 | 1.03 | 1.70 |
| burst | 1 000 | 1.07 | 1.03 | 8.25 |
| stream | 100 per tick | 1.02 | (stream is traced only) | 3.07 |

- **Width 1 024** is §13's "≤ 1.3× until S7" missed at 5.1×, by the same amount as today's
  `browser-tea` (5.6×). The cost is V8's 1 024-field spread, which only S7's in-place update
  removes.
- **Bursts hold the K = 1 ratio at every K** (1.03× at K = 1 and K = 1 000), as Q2 predicted.
  The 13 % batching win today's platform had at K = 1 000 is gone, and nothing is worse for it.
- **The development build is the verify mode's cost**: every hole computed again and compared
  after each dispatch, static holes included. `browser-direct.md`'s S1 amendment states this
  against §8.3's "today's cost".

Bytes (minified, brotli 11 / gzip -9), release:

| page | beni-direct | beni (`browser-tea`) | Solid 1 | vanilla | P3 |
|---|--:|--:|--:|--:|--:|
| holes 10 | 662 / 780 | 1 248 / 1 419 | 2 948 / 3 276 | 168 / 253 | 394 / 482 |
| holes 1 000 | 5 215 / 10 043 | 8 348 / 15 673 | 9 105 / 16 713 | 194 / 363 | 433 / 610 |
| holes 10 000 | 36 102 / 84 692 | 62 296 / 128 268 | 55 497 / 109 799 | 195 / 946 | 442 / 1 206 |
| width 8 | 661 / 781 | 1 234 / 1 435 | 4 088 / 4 513 | 228 / 323 | — |
| width 256 | 2 736 / 4 902 | 5 418 / 10 860 | 5 766 / 8 177 | 680 / 1 392 | — |
| width 1 024 | 7 887 / 17 251 | 17 552 / 37 739 | 10 064 / 19 387 | 1 742 / 4 705 | — |

### 4.2 Every point, traced and untraced

The full tables, median script ms (× vanilla), every subject. The same data is in
`bench/ui/results/2026-10-09-s1-*.json`.


#### 2026-10-09-s1-holes-traced.json (traced, full, 175.197 s)

##### holes/tick: median script ms (× vanilla)

| point | beni | beni-release | beni-direct | beni-direct-release | p3 | solid1 | vanillajs |
|--:|--:|--:|--:|--:|--:|--:|--:|
| 10 | 0.095 (1.54) | 0.140 (2.27) | 0.073 (1.20) | 0.061 (0.99) | 0.061 (0.99) | 0.102 (1.67) | 0.061 |
| 30 | 0.084 (1.99) | 0.087 (2.05) | 0.063 (1.48) | 0.052 (1.21) | 0.048 (1.13) | 0.093 (2.19) | 0.042 |
| 100 | 0.097 (1.58) | 0.122 (1.98) | 0.077 (1.25) | 0.064 (1.03) | 0.065 (1.05) | 0.117 (1.91) | 0.061 |
| 300 | 0.088 (1.95) | 0.089 (1.97) | 0.069 (1.52) | 0.051 (1.13) | 0.050 (1.09) | 0.087 (1.91) | 0.045 |
| 1000 | 0.096 (1.85) | 0.089 (1.73) | 0.096 (1.86) | 0.050 (0.96) | 0.055 (1.07) | 0.088 (1.71) | 0.052 |
| 3000 | 0.115 (2.63) | 0.114 (2.58) | 0.176 (4.01) | 0.056 (1.26) | 0.052 (1.18) | 0.089 (2.02) | 0.044 |
| 10000 | 0.122 (2.62) | 0.138 (2.97) | 0.493 (10.61) | 0.065 (1.39) | 0.060 (1.30) | 0.120 (2.59) | 0.046 |


#### 2026-10-09-s1-holes-untraced.json (untraced real, full, 100.857 s)

##### holes/tick: median script ms (× vanilla)

| point | beni | beni-release | beni-direct | beni-direct-release | p3 | solid1 | vanillajs |
|--:|--:|--:|--:|--:|--:|--:|--:|
| 10 | 0.085 (1.42) | 0.090 (1.50) | 0.075 (1.25) | 0.065 (1.08) | 0.063 (1.04) | 0.095 (1.58) | 0.060 |
| 30 | 0.080 (1.33) | 0.085 (1.42) | 0.065 (1.08) | 0.060 (1.00) | 0.065 (1.08) | 0.090 (1.50) | 0.060 |
| 100 | 0.087 (1.46) | 0.075 (1.25) | 0.067 (1.12) | 0.065 (1.08) | 0.065 (1.08) | 0.095 (1.58) | 0.060 |
| 300 | 0.083 (1.43) | 0.080 (1.39) | 0.075 (1.30) | 0.060 (1.04) | 0.065 (1.13) | 0.090 (1.57) | 0.058 |
| 1000 | 0.095 (1.46) | 0.090 (1.38) | 0.117 (1.81) | 0.068 (1.04) | 0.070 (1.08) | 0.095 (1.46) | 0.065 |
| 3000 | 0.090 (1.50) | 0.085 (1.42) | 0.207 (3.46) | 0.070 (1.17) | 0.065 (1.08) | 0.105 (1.75) | 0.060 |
| 10000 | 0.097 (1.50) | 0.100 (1.54) | 0.575 (8.85) | 0.070 (1.08) | 0.075 (1.15) | 0.110 (1.69) | 0.065 |


#### 2026-10-09-s1-wbs-traced.json (traced, full, 1401.717 s)

##### width/field: median script ms (× vanilla)

| point | beni | beni-release | beni-direct | beni-direct-release | solid1 | vanillajs |
|--:|--:|--:|--:|--:|--:|--:|
| 4 | 0.089 (1.91) | 0.090 (1.94) | 0.072 (1.55) | 0.071 (1.53) | 0.116 (2.51) | 0.046 |
| 8 | 0.090 (1.78) | 0.088 (1.75) | 0.060 (1.20) | 0.055 (1.09) | 0.118 (2.34) | 0.051 |
| 16 | 0.094 (1.74) | 0.111 (2.05) | 0.093 (1.72) | 0.062 (1.15) | 0.113 (2.09) | 0.054 |
| 17 | 0.098 (2.20) | 0.095 (2.13) | 0.068 (1.52) | 0.052 (1.17) | 0.114 (2.56) | 0.044 |
| 20 | 0.095 (2.12) | 0.093 (2.09) | 0.066 (1.47) | 0.050 (1.12) | 0.120 (2.70) | 0.044 |
| 32 | 0.092 (1.78) | 0.102 (1.96) | 0.068 (1.31) | 0.055 (1.06) | 0.114 (2.19) | 0.052 |
| 64 | 0.111 (2.16) | 0.107 (2.08) | 0.080 (1.54) | 0.055 (1.07) | 0.127 (2.46) | 0.051 |
| 128 | 0.342 (1.94) | 0.260 (1.47) | 0.210 (1.19) | 0.121 (0.69) | 0.257 (1.46) | 0.176 |
| 256 | 0.330 (3.00) | 0.555 (5.05) | 0.445 (4.05) | 0.235 (2.14) | 0.439 (3.99) | 0.110 |
| 1024 | 0.407 (9.15) | 0.386 (8.66) | 0.368 (8.27) | 0.272 (6.11) | 0.117 (2.63) | 0.044 |

##### burst/burst: median script ms (× vanilla)

| point | beni | beni-release | beni-direct | beni-direct-release | p3 | solid1 | vanillajs |
|--:|--:|--:|--:|--:|--:|--:|--:|
| 1 | 0.191 (3.18) | 0.177 (2.95) | 0.126 (2.10) | 0.075 (1.26) | 0.111 (1.85) | 0.140 (2.33) | 0.060 |
| 3 | 0.183 (2.58) | 0.198 (2.79) | 0.231 (3.25) | 0.072 (1.01) | 0.131 (1.85) | 0.188 (2.64) | 0.071 |
| 10 | 0.254 (2.22) | 0.250 (2.18) | 0.486 (4.24) | 0.126 (1.10) | 0.175 (1.53) | 0.289 (2.53) | 0.115 |
| 30 | 0.362 (1.46) | 0.397 (1.60) | 1.220 (4.92) | 0.255 (1.03) | 0.307 (1.24) | 0.536 (2.16) | 0.248 |
| 100 | 0.865 (1.22) | 0.885 (1.25) | 3.604 (5.09) | 0.736 (1.04) | 0.734 (1.04) | 1.291 (1.82) | 0.708 |
| 300 | 2.201 (1.06) | 2.133 (1.03) | 10.512 (5.06) | 2.054 (0.99) | 2.029 (0.98) | 3.234 (1.56) | 2.077 |
| 1000 | 6.731 (1.03) | 7.012 (1.08) | 35.699 (5.48) | 6.941 (1.07) | 6.303 (0.97) | 10.128 (1.55) | 6.514 |

##### stream/stream: median script ms (× vanilla)

| point | beni | beni-release | beni-direct | beni-direct-release | p3 | solid1 | vanillajs |
|--:|--:|--:|--:|--:|--:|--:|--:|
| 1 | 0.069 (1.50) | 0.071 (1.54) | 0.086 (1.88) | 0.050 (1.09) | 0.074 (1.61) | 0.081 (1.75) | 0.046 |
| 10 | 0.014 (1.11) | 0.013 (1.09) | 0.046 (3.78) | 0.012 (0.97) | 0.013 (1.04) | 0.017 (1.40) | 0.012 |
| 100 | 0.008 (1.02) | 0.008 (1.04) | 0.025 (3.30) | 0.008 (1.02) | 0.007 (0.97) | 0.011 (1.43) | 0.007 |


#### 2026-10-09-s1-width-untraced.json (untraced real, full, 921.293 s)

##### width/field: median script ms (× vanilla)

| point | beni | beni-release | beni-direct | beni-direct-release | solid1 | vanillajs |
|--:|--:|--:|--:|--:|--:|--:|
| 4 | 0.120 (1.20) | 0.180 (1.80) | 0.143 (1.43) | 0.138 (1.38) | 0.218 (2.18) | 0.100 |
| 8 | 0.105 (1.62) | 0.085 (1.31) | 0.065 (1.00) | 0.068 (1.04) | 0.105 (1.62) | 0.065 |
| 16 | 0.095 (0.90) | 0.160 (1.52) | 0.115 (1.10) | 0.112 (1.07) | 0.190 (1.81) | 0.105 |
| 17 | 0.108 (0.96) | 0.095 (0.84) | 0.085 (0.76) | 0.095 (0.84) | 0.300 (2.67) | 0.112 |
| 20 | 0.102 (1.58) | 0.113 (1.73) | 0.078 (1.19) | 0.075 (1.15) | 0.127 (1.96) | 0.065 |
| 32 | 0.093 (1.48) | 0.085 (1.36) | 0.065 (1.04) | 0.065 (1.04) | 0.105 (1.68) | 0.063 |
| 64 | 0.080 (1.33) | 0.080 (1.33) | 0.070 (1.17) | 0.060 (1.00) | 0.110 (1.83) | 0.060 |
| 128 | 0.090 (1.57) | 0.085 (1.48) | 0.070 (1.22) | 0.065 (1.13) | 0.105 (1.83) | 0.057 |
| 256 | 0.095 (1.73) | 0.097 (1.77) | 0.080 (1.45) | 0.065 (1.18) | 0.100 (1.82) | 0.055 |
| 1024 | 0.338 (5.62) | 0.345 (5.75) | 0.343 (5.71) | 0.308 (5.12) | 0.100 (1.67) | 0.060 |


#### 2026-10-09-s1-bs-untraced.json (untraced real, full, 297.641 s)

##### burst/burst: median script ms (× vanilla)

| point | beni | beni-release | beni-direct | beni-direct-release | p3 | solid1 | vanillajs |
|--:|--:|--:|--:|--:|--:|--:|--:|
| 1 | 0.100 (1.33) | 0.105 (1.40) | 0.127 (1.70) | 0.077 (1.03) | 0.085 (1.13) | 0.140 (1.87) | 0.075 |
| 3 | 0.115 (1.53) | 0.108 (1.43) | 0.205 (2.73) | 0.080 (1.07) | 0.080 (1.07) | 0.155 (2.07) | 0.075 |
| 10 | 0.135 (1.26) | 0.160 (1.49) | 0.465 (4.33) | 0.115 (1.07) | 0.110 (1.02) | 0.240 (2.23) | 0.108 |
| 30 | 0.232 (1.22) | 0.240 (1.26) | 1.037 (5.46) | 0.205 (1.08) | 0.190 (1.00) | 0.420 (2.21) | 0.190 |
| 100 | 0.505 (1.09) | 0.500 (1.08) | 2.843 (6.11) | 0.460 (0.99) | 0.400 (0.86) | 0.835 (1.80) | 0.465 |
| 300 | 1.130 (1.04) | 1.087 (1.00) | 7.858 (7.24) | 1.112 (1.03) | 0.953 (0.88) | 2.020 (1.86) | 1.085 |
| 1000 | 3.043 (0.96) | 3.025 (0.96) | 26.055 (8.25) | 3.240 (1.03) | 2.745 (0.87) | 5.783 (1.83) | 3.160 |

##### stream/stream: median script ms (× vanilla)

| point | beni | beni-release | beni-direct | beni-direct-release | p3 | solid1 | vanillajs |
|--:|--:|--:|--:|--:|--:|--:|--:|
| 1 | 0.066 (1.43) | 0.071 (1.55) | 0.091 (1.97) | 0.049 (1.06) | 0.061 (1.33) | 0.071 (1.54) | 0.046 |
| 10 | 0.014 (1.18) | 0.013 (1.14) | 0.045 (3.85) | 0.012 (1.03) | 0.012 (1.06) | 0.017 (1.48) | 0.012 |
| 100 | 0.007 (1.01) | 0.007 (1.01) | 0.023 (3.07) | 0.007 (1.01) | 0.007 (0.98) | 0.011 (1.44) | 0.007 |


#### 2026-10-09-s1-rdd-traced.json (traced, quick, 233.041 s)

##### rows/change: median script ms (× vanilla)

| point | beni | beni-release | p3 | solid1 | vanillajs |
|--:|--:|--:|--:|--:|--:|
| 10 | 0.095 (1.86) | 0.099 (1.94) | 0.059 (1.16) | 0.116 (2.27) | 0.051 |
| 1000 | 0.113 (2.46) | 0.140 (3.04) | 0.073 (1.59) | 0.117 (2.54) | 0.046 |
| 30000 | 0.484 (7.68) | 0.425 (6.75) | 0.090 (1.43) | 0.146 (2.32) | 0.063 |

##### rows/swap: median script ms (× vanilla)

| point | beni | beni-release | p3 | solid1 | vanillajs |
|--:|--:|--:|--:|--:|--:|
| 10 | 0.148 (2.03) | 0.159 (2.18) | 0.087 (1.19) | 0.166 (2.27) | 0.073 |
| 1000 | 0.176 (2.23) | 0.296 (3.75) | 0.115 (1.46) | 0.469 (5.94) | 0.079 |
| 30000 | 1.415 (15.72) | 0.818 (9.09) | 0.128 (1.42) | 4.915 (54.61) | 0.090 |

##### depth/leaf: median script ms (× vanilla)

| point | beni | beni-release | p3 | solid1 | vanillajs |
|--:|--:|--:|--:|--:|--:|
| 1 | 0.087 (2.07) | 0.076 (1.81) | 0.056 (1.33) | 0.128 (3.05) | 0.042 |
| 16 | 0.085 (1.98) | 0.090 (2.09) | 0.052 (1.21) | 0.129 (3.00) | 0.043 |
| 128 | 0.227 (4.93) | 0.230 (5.00) | 0.073 (1.59) | 0.246 (5.35) | 0.046 |

##### derived/tick: median script ms (× vanilla)

| point | beni | beni-release | solid1 | vanillajs |
|--:|--:|--:|--:|--:|
| 100 | 0.079 (2.14) | 0.072 (1.95) | 0.117 (3.16) | 0.037 |
| 3000 | 0.074 (1.32) | 0.063 (1.13) | 0.127 (2.27) | 0.056 |
| 100000 | 0.120 (2.18) | 0.092 (1.67) | 0.147 (2.67) | 0.055 |


#### 2026-10-09-s1-rdd-untraced.json (untraced real, quick, 229.157 s)

##### rows/change: median script ms (× vanilla)

| point | beni | beni-release | p3 | solid1 | vanillajs |
|--:|--:|--:|--:|--:|--:|
| 10 | 0.105 (1.62) | 0.105 (1.62) | 0.080 (1.23) | 0.105 (1.62) | 0.065 |
| 1000 | 0.125 (1.79) | 0.135 (1.93) | 0.085 (1.21) | 0.105 (1.50) | 0.070 |
| 30000 | 0.465 (6.20) | 0.420 (5.60) | 0.100 (1.33) | 0.125 (1.67) | 0.075 |

##### rows/swap: median script ms (× vanilla)

| point | beni | beni-release | p3 | solid1 | vanillajs |
|--:|--:|--:|--:|--:|--:|
| 10 | 0.150 (1.67) | 0.140 (1.56) | 0.100 (1.11) | 0.155 (1.72) | 0.090 |
| 1000 | 0.195 (2.05) | 0.205 (2.16) | 0.120 (1.26) | 0.390 (4.11) | 0.095 |
| 30000 | 0.825 (7.50) | 0.770 (7.00) | 0.135 (1.23) | 5.070 (46.09) | 0.110 |

##### depth/leaf: median script ms (× vanilla)

| point | beni | beni-release | p3 | solid1 | vanillajs |
|--:|--:|--:|--:|--:|--:|
| 1 | 0.100 (1.54) | 0.090 (1.38) | 0.065 (1.00) | 0.115 (1.77) | 0.065 |
| 16 | 0.125 (1.92) | 0.100 (1.54) | 0.080 (1.23) | 0.140 (2.15) | 0.065 |
| 128 | 0.240 (3.69) | 0.205 (3.15) | 0.095 (1.46) | 0.210 (3.23) | 0.065 |

##### derived/tick: median script ms (× vanilla)

| point | beni | beni-release | solid1 | vanillajs |
|--:|--:|--:|--:|--:|
| 100 | 0.095 (1.58) | 0.085 (1.42) | 0.095 (1.58) | 0.060 |
| 3000 | 0.090 (1.50) | 0.090 (1.50) | 0.100 (1.67) | 0.060 |
| 100000 | 0.090 (1.50) | 0.090 (1.50) | 0.095 (1.58) | 0.060 |


#### 2026-10-09-s1-lht-traced.json (traced, quick, 302.483 s)

##### live/tick: median script ms (× vanilla)

| point | beni | beni-release | p3 | solid1 | vanillajs |
|--:|--:|--:|--:|--:|--:|
| 100 | 0.130 (2.32) | 0.137 (2.45) | 0.067 (1.20) | 0.163 (2.91) | 0.056 |
| 1000 | 0.145 (2.42) | 0.140 (2.33) | 0.074 (1.23) | 0.165 (2.75) | 0.060 |
| 10000 | 0.155 (2.98) | 0.126 (2.42) | 0.058 (1.12) | 0.127 (2.44) | 0.052 |

##### helperRows/tick: median script ms (× vanilla)

| point | beni | beni-release | solid1 | vanillajs |
|--:|--:|--:|--:|--:|
| 100 | 0.079 (1.23) | 0.070 (1.09) | 0.121 (1.89) | 0.064 |
| 1000 | 0.087 (1.81) | 0.080 (1.67) | 0.111 (2.31) | 0.048 |
| 10000 | 0.090 (2.00) | 0.082 (1.82) | 0.129 (2.87) | 0.045 |

##### tree/tick: median script ms (× vanilla)

| point | beni | beni-release | solid1 | vanillajs |
|--:|--:|--:|--:|--:|
| 4 | 0.090 (2.05) | 0.080 (1.82) | 0.107 (2.43) | 0.044 |
| 8 | 0.080 (1.90) | 0.072 (1.71) | 0.107 (2.55) | 0.042 |
| 12 | 0.079 (1.76) | 0.077 (1.71) | 0.118 (2.62) | 0.045 |


#### 2026-10-09-s1-lht-untraced.json (untraced real, quick, 282.201 s)

##### live/tick: median script ms (× vanilla)

| point | beni | beni-release | p3 | solid1 | vanillajs |
|--:|--:|--:|--:|--:|--:|
| 100 | 0.090 (1.64) | 0.080 (1.45) | 0.065 (1.18) | 0.095 (1.73) | 0.055 |
| 1000 | 0.090 (1.50) | 0.090 (1.50) | 0.065 (1.08) | 0.095 (1.58) | 0.060 |
| 10000 | 0.110 (1.83) | 0.105 (1.75) | 0.075 (1.25) | 0.110 (1.83) | 0.060 |

##### helperRows/tick: median script ms (× vanilla)

| point | beni | beni-release | solid1 | vanillajs |
|--:|--:|--:|--:|--:|
| 100 | 0.090 (1.64) | 0.095 (1.73) | 0.090 (1.64) | 0.055 |
| 1000 | 0.090 (1.64) | 0.095 (1.73) | 0.110 (2.00) | 0.055 |
| 10000 | 0.100 (1.54) | 0.100 (1.54) | 0.120 (1.85) | 0.065 |

##### tree/tick: median script ms (× vanilla)

| point | beni | beni-release | solid1 | vanillajs |
|--:|--:|--:|--:|--:|
| 4 | 0.095 (1.46) | 0.090 (1.38) | 0.105 (1.62) | 0.065 |
| 8 | 0.090 (1.64) | 0.085 (1.55) | 0.100 (1.82) | 0.055 |
| 12 | 0.100 (1.67) | 0.100 (1.67) | 0.110 (1.83) | 0.060 |


### 4.3 The table app (`bench.mjs`), script ms median

| subject | run1k | replace1k | update10th | select | swap | remove | create10k | append1k | clear |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| beni | 4.51 | 10.2 | 1.53 | 0.71 | 1.03 | 0.47 | 49.5 | 5.50 | 22.7 |
| beni-release | 4.55 | 10.5 | 1.29 | 0.51 | 0.73 | 0.46 | 48.7 | 4.98 | 22.7 |
| p3 | 4.63 | 10.1 | 0.76 | 1.30 | 0.39 | 0.41 | 48.1 | 4.59 | 21.1 |
| vanillajs | 4.63 | 9.64 | 0.82 | 1.27 | 0.13 | 0.53 | 47.3 | 4.84 | 18.6 |
| solid1 | 4.88 | 11.9 | 1.78 | 1.84 | 1.42 | 0.55 | 55.1 | 5.26 | 23.8 |

`beni-direct` and `beni-direct-release`: skipped (the app's `button` helper is markup as a
value, S3; its rows are a `For`, S2).

## 5. Walls and findings

- **Kill criterion 3 fires on bytes** (§3). This is the decision §13 says stops the design at
  S1: "the page grows with N by more than the HTML — the handler path is not direct". The
  handler path is direct. The growth is the narrowed bake rule, which leaves an `Int` hole or an
  attribute that never changes to mount code. That is reported, not restated.
- **The development verify mode is not "today's cost"** (§4.1). It is 0.6 ms a message at
  10 000 holes against 0.1. A development-only cost, and no criterion judges it.
- **Batches over fifteen minutes.** The traced width-burst-stream batch took 23 minutes,
  against the brief's 15. Later batches were split.
- **The fuzz harness.** Once `--fuzz` existed, master's gates fuzzed every `browser/tea/` pair
  with two more builds and a dump each, and 55 pages went over budget. The manager decided the
  split in `browser-direct.md`'s amendment. Three `browser/direct/` pages are over the budget
  with the value fuzz: `Holes` 4 597, `MessageKeys` 4 382 and `VerifyQuiet` 5 007 million
  instructions. They pass the gates on recorded run hashes, as `ApiAndRoutes` does; not
  trimmed.
- **`zig build fuzz -Dcorpus=tea/HttpDefect` now builds** with its own `platform/`, but its
  development build does not replay itself (seed 1, step 4): a fuzzer determinism finding on
  that page, sweep-only.
- **Q1's removed-input shape needs branches** (S4). S1 pins Q1 by bubbling
  (`EventReadsModel`).

## 6. The harness changes (owned since the fuzzer agent finished)

Separate from S1's own work, in `tests/blackbox/corpus_test.zig`'s fuzz plumbing,
`tests/browser/fuzz.mjs` and the `--fuzz` hook:
- The gates send values only on `browser/direct/` pairs. `browser/tea/` pairs get values in
  `zig build fuzz`'s sweep.
- A `--fuzz` pair is built with the fixture's own `platform/` (HttpDefect's `Fault` module).
- Message types are dumped from a project's directory, not its files, so the four `--msg-types`
  failures (Counters, ConduitReader, ConduitTour, ConduitEditor) were the walker passing several
  files to a one-path dump. They are not a compiler bug.
- On `browser-tea`, a value enters through `Rt.fuzzInstall`'s guarded send (installed only by a
  `--fuzz` build's markup).
- The fuzzer sends either platform's value from a listener of a node of its own, so a throw is
  reported as a click's is.
- `page_fuzz_test.zig` builds its pairs with `--fuzz`.

## 7. What S1 leaves for later slices

The specialiser for a nested key's inner `case` (§4.1, `--release`), group inlining on single
use (§5.3), the dispatcher as a decision tree (§4.4), O8's wider baking, and everything §14
assigns to S2–S8.

## 8. Commands

```sh
zig build gates                                          # green, with --fuzz present
zig build test-blackbox-corpus -Dcorpus=direct           # the direct fixtures and refusals
zig build fuzz -Dcorpus=tea/Co                           # the value sweep on four tea projects
cd bench/ui                                              # each under the bench lock, in nix develop .#browser
node scaling.mjs --full [--untraced] --sweeps=holes --subjects=beni,beni-release,beni-direct,beni-direct-release,p3,vanillajs,solid1 --taskset=8-15
node scaling.mjs --full [--untraced] --sweeps=width|burst,stream …
node scaling.mjs [--untraced] --sweeps=rows,depth,derived|live,helperRows,tree …
node bench.mjs --subjects=… --n=5 --taskset=8-15
node scaling.mjs --full --build-only --subjects=beni,beni-release,beni-direct-release,p3,solid1,vanillajs && node scaling-sizes.mjs
```
