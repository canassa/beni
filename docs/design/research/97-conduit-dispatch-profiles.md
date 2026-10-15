# 97 — Conduit's message latency and compiled bytes

*2026-10-15. Draft PR #98, unchanged Conduit sources. Before: `ff82485e5`;
measured compiler SHA-256 `5be2212c013adae893c701ed83e42c86ef4bc618fc24e58968163d28fd73e033`.
The profiled compiler is rebased onto `d9ae082e0`; that rebase changes no compiler,
platform or core source. Its Conduit bundles are byte-identical to the measured
fixed bundles. A later rebase and review follow-up are recorded separately below.
Full source fingerprints and raw observations accompany this report.*

## 0. Finding

The large excess in a dispatcher's sampled frame is mostly **compiling the
handler it calls**. The old lowering copies an unspecialised update and the
computed document selector into each message-key handler. Conduit's tuple match
on `(message, model)` cannot use the arm specialiser. A first-use key therefore
makes V8 compile another large copy, although the shared update and view logic
has already run for other keys. Tea keeps one update function and one view.

The general fix shares an update that cannot be specialised, shares the computed
root selector inside each mounted program, and shares adjacent message-key test
prefixes. A one-key update retains its existing inline lowering. No program or
message name is consulted. Read masks, source ordering, commands and the visit
oracle are unchanged.

In the rotated 30-fresh-page batch, feed/favorite/editor change from direct
**0.425/0.4075/0.450 ms** to **0.340/0.340/0.3725 ms**; tea is
**0.3175/0.3475/0.4175 ms**. The fixed and tea IQRs overlap. These point medians
do not establish an across-the-board ordering, and no geometric mean is used.

Raw JavaScript falls **361,594 → 209,384 B**. Brotli falls only
**38,030 → 37,768 B**, against tea's **31,389 B**: **6,379 B / 20.32%** still
remains. Repeated handlers compress well; parameterised-template entry code,
consumer masks and their runtime are the main compressed cost. This is a
remaining cost, not a byte acceptance or a silently changed target.

## 1. Protocol

All three candidates use their actual **release builds**, without an external
minifier or instrumentation in their JavaScript. Tea's bundle is unchanged.
Chrome 155.0.8059.80 and Node 24.19.0 run on the same Apple M2 Pro. The local
machine has other activity; each observation retains its one-minute load.
Candidates rotate and reverse across the Conduit samples. There is no CPU
throttling, forced GC, extra target-message warm-up or changed fixture.

`bench/conduit/time.mjs` uses the corpus driver's API scripts and virtual clock.
It recreates a page, replays setup outside the measured interval, and sends the
same real CDP click or `Input.insertText`. The interval is window capture through
eight microtasks after bubble; layout/paint after that boundary is outside it.
The serialized DOM, title, input properties and harness errors must agree after
every event. Conduit loads no CSS in this existing message protocol.

The untraced comparison has 30 independently mounted pages per operation and
candidate. Its separate trace samples are diagnostic, not substituted for its
untraced values. Medians use the two central observations for even counts;
quartiles below use linear interpolation. No observation is trimmed.

CPU profiling requests 25 µs sampling and collects the main-thread compilation
trace alongside it. A separate 30-page-per-cell allocation pass samples at
128 B, including objects collected by minor and major GC. Heap sampling is not
mixed into the CPU attribution table or the comparison timing.

CPU timestamps are reconstructed and stably sorted, as in the
[Chrome DevTools CPU profile model](https://github.com/ChromeDevTools/devtools-frontend/blob/main/front_end/models/cpu_profile/CPUProfileDataModel.ts#L240).
The raw profiles contain negative deltas; those samples are retained. Intervals
are clipped to the event's two marks. Main-thread `V8.CompileCode` intervals are
unioned and separated from their caller's sampled interval, without counting
nested parse/compile events again. Missing `(program)` stacks remain
unattributed; no interpolation fills them in. Function columns refer to the
archived, as-served release bundles.

Untraced medians [Q1, Q3], milliseconds:

| Message | Tea | Direct before | Direct fixed |
| --- | --- | --- | --- |
| feed tab | 0.3175 [0.3050, 0.3488] | 0.4250 [0.4050, 0.4550] | 0.3400 [0.3200, 0.3638] |
| favorite | 0.3475 [0.3063, 0.3925] | 0.4075 [0.3750, 0.4525] | 0.3400 [0.2863, 0.4025] |
| editor keystroke | 0.4175 [0.3850, 0.4288] | 0.4500 [0.4200, 0.4750] | 0.3725 [0.3563, 0.3937] |

## 2. CPU profiles and allocation

Mean self time, µs per instrumented page. A dash means no sampled interval.

**feed tab**

| Attribution | Tea | Direct before | Direct fixed |
| --- | --- | --- | --- |
| V8 compilation | 175.3 | 309.4 | 193.5 |
| harness | 72.4 | 68.6 | 68.3 |
| host / unattributed | 164.3 | 148.3 | 151.8 |
| runtime patching / control | 64.1 | 68.3 | 55.0 |
| runtime dispatch | 36.9 | 10.2 | 9.5 |
| generated handler / template | 16.9 | 42.0 | 36.5 |
| core | 54.1 | 71.8 | 81.3 |
| effects / commands | 47.6 | 48.3 | 33.5 |
| handler / application | 1.6 | 5.3 | 9.1 |
| scheduler | 8.9 | 2.5 | 0.6 |
| generated dispatcher | — | 19.4 | 18.9 |
| template runtime | — | 45.0 | 22.5 |
| GC | — | 10.0 | 5.1 |
| generated handler | — | 3.0 | 5.3 |

**favorite**

| Attribution | Tea | Direct before | Direct fixed |
| --- | --- | --- | --- |
| V8 compilation | 79.0 | 199.0 | 98.3 |
| harness | 63.8 | 66.0 | 78.5 |
| host / unattributed | 149.2 | 183.4 | 151.7 |
| generated handler / template | 26.1 | 12.3 | 13.6 |
| runtime patching / control | 20.7 | 14.8 | 10.5 |
| handler / application | 21.6 | 13.0 | 16.7 |
| effects / commands | 62.1 | 39.7 | 35.6 |
| runtime dispatch | 24.2 | 16.7 | 15.5 |
| scheduler | 5.9 | — | — |
| core | 23.5 | 26.4 | 37.9 |
| GC | 18.0 | — | — |
| generated dispatcher | — | 19.7 | 20.9 |
| generated handler | — | 10.1 | 3.7 |
| template runtime | — | 6.0 | 3.2 |

**editor keystroke**

| Attribution | Tea | Direct before | Direct fixed |
| --- | --- | --- | --- |
| V8 compilation | 223.6 | 359.0 | 268.9 |
| harness | 43.0 | 41.1 | 43.1 |
| host / unattributed | 68.9 | 86.5 | 80.3 |
| runtime patching / control | 58.7 | 29.0 | 24.2 |
| scheduler | 12.2 | — | — |
| handler / application | 16.9 | 10.3 | 17.4 |
| core | 47.9 | 0.3 | 2.9 |
| generated handler / template | 24.7 | 29.2 | 23.3 |
| runtime dispatch | 27.6 | 14.7 | 15.2 |
| effects / commands | 5.0 | 1.2 | — |
| generated dispatcher | — | 6.2 | 2.8 |
| template runtime | — | 25.8 | 23.1 |
| generated handler | — | 0.5 | 0.3 |


These are sampled self intervals averaged across instrumented pages, not a
microsecond decomposition of the untraced median. The requested sampling period
is not the delivered resolution. Unknown/native work includes host calls and
stack gaps, and is not assigned to the dispatcher's comparisons. Command and
scheduler boundaries use named source functions; reentrant queue work inside
`Direct.send` stays in the dispatch guard's row.

| Message | Direct | Profile frame (column) | Sampled µs | Overlapping compile µs | All compile µs |
| --- | --- | --- | --- | --- | --- |
| feed tab | before | `Main.main / eb:356571` | 127.8 | 108.4 | 309.4 |
| feed tab | fixed | `Main.main / eb:206027` | 26.4 | 7.5 | 193.5 |
| favorite | before | `Main.main / eb:356571` | 123.1 | 103.4 | 199.0 |
| favorite | fixed | `Main.main / eb:206027` | 27.8 | 6.9 | 98.3 |
| editor keystroke | before | `Main.main / eb:356571` | 117.3 | 111.1 | 359.0 |
| editor keystroke | fixed | `Main.main / eb:206027` | 24.3 | 21.5 | 268.9 |

Delivered median sample spacing is 39–40 µs. The archived per-function tables retain the unmodified profile columns and compilation overlap for all three platforms.

The compilation overlap is the evidence distinguishing code compilation from a
long chain of JavaScript comparisons. The prefix tree reduces repeated tests,
but the measurements do not isolate a separate timing gain for that change.
The sharing changes reduce the number and total size of executable copies;
they do not pre-warm the timed keys or merely move an unchanged set of copies
to startup.

| Profile-window bytes per page | Tea | Direct before | Direct fixed |
| --- | --- | --- | --- |
| feed tab | 27,482 | 38,272 | 32,821 |
| favorite | 27,646 | 31,708 | 25,276 |
| editor keystroke | 28,938 | 34,020 | 27,637 |

For the fixed editor, sampled allocations include `Direct.templateSelectNew` (1,498 B/page), `Direct.templatePatch` (910), `Editor.update` (874) and `Direct.edits` (712); 17,686 B/page are native/unknown. The full function tables are archived.

Allocation samples cover the profiling window, including inspector/harness
work outside the event marks. Native/unknown bytes cannot all be called
application allocation. Source-attributed template selection and context work
remain visible. The profiles do not isolate an allocation-only CPU percentage;
its execution is included in the named JS/native intervals. GC samples remain
separate. Neither an absent GC trace event nor an unsampled short function is
proof of zero work.

## 3. The same editor message, emitted on both platforms

Tea's `Main.update` contains one `GotEditorMsg` arm, calls `Editor.update`, and
wraps its result. `Tea.application` invokes that shared update through its host;
its view callback invokes the shared application view. The direct handler used
to contain the *whole* tuple-match update, including unrelated routes, followed
by a copy of the document selector. It now calls the shared update and selector
under the current handler's substitution. The selector closes over the current
model, not its mount-time value.

| Work for `EnteredTitle` | Tea | Direct before | Direct fixed |
| --- | --- | --- | --- |
| Update body | Shared `Main.update`, then `Editor.update` | Whole tuple update copied into this key | Shared `update$46` call, then `Editor.update` |
| Root view selection | Shared application view | Selector copied into this key | Shared `$chooseRoot$81` call |
| Hole selection | Template value comparisons during view patch | Predicted per-key template mask | Same predicted per-key template mask |

The following exact excerpts expose those calls with readable development names.

**Tea: one arm of the shared update**

```js
case "GotEditorMsg":
        {
          if (model$2.$ === "Editor") {
            const subMsg$21 = msg$1.a;
            const slug$22 = model$2.a;
            const editor$23 = model$2.b;
            return Main$updateWith(($p$56) => ({ $: "Editor", a: slug$22, b: $p$56 }), ($x$57) => ({ $: "GotEditorMsg", a: $x$57 }), Editor$update(subMsg$21, editor$23));
          } else {
            break $j$0$10;
          }
        }
```

**Direct before: each key receives the whole update** (two disjoint exact excerpts; unrelated arms and selector body omitted):

```js
$hGotEditorMsg$EnteredTitle$3108 = ($p$3073) => {
    Direct$groupProgram(null);
    const $visitBefore$3074 = Direct$visitBegin($templatePlan$37, 84);
    const $before$3075 = $model$27;
    let $t$3076;
    $c$0: {
      $j$0$10: {
        switch ($p$3073.$) {
// … other message arms …
          case "GotEditorMsg":
            {
              if ($before$3075.$ === "Editor") {
                const subMsg$2972 = $p$3073.a;
                const slug$2973 = $before$3075.a;
                const editor$2974 = $before$3075.b;
                $t$3076 = Main$updateWith(($p$3092) => ({ $: "Editor", a: slug$2973, b: $p$3092 }), ($x$3093) => ({ $: "GotEditorMsg", a: $x$3093 }), Editor$update(subMsg$2972, editor$2974));
                break $c$0;
              } else {
                break $j$0$10;
              }
            }
          default:
            {
// … remaining arms …
    const $templateBefore$3095 = Direct$templateProgram($templatePlan$37, 84);
    Direct$visitScope($root$24, []);
    {
      const viewer$2977 = Session$viewer(Main$toSession($model$27));
      let $t$3107;
      {
```

**Direct fixed: this key calls the shared update and root selector**

```js
$hGotEditorMsg$EnteredTitle$756 = ($p$749) => {
    Direct$groupProgram(null);
    const $visitBefore$750 = Direct$visitBegin($templatePlan$54, 84);
    const $before$751 = $model$43;
    const $result$752 = update$46($p$749, $before$751);
    $model$43 = $result$752.a;
    const $templateBefore$753 = Direct$templateProgram($templatePlan$54, 84);
    Direct$visitScope($root$40, []);
    {
      const $a$754 = $chooseRoot$81();
      const $n$755 = $a$754[0];
      if ($n$755 !== $B$53.k) {
        Direct$arm($B$53, $n$755, null, $a$754);
      } else {
        if ($B$53.i !== null) {
          $B$53.i.a = $a$754;
        }
        {
          if ($B$53.k === 0) {
            Direct$childHtml($B$53.i.c, $B$53.i.a[1].body);
          }
        }
      }
    }
    Direct$title($B$53.i.a[1].title);
    Direct$commands($host$45, $result$752.b);
    Direct$templateEnd($templateBefore$753);
    Direct$visitEnd($visitBefore$750);
  }
```

The source excerpts and complete served bundles are archived. Development
excerpts make the identifiers readable; the profile columns and part sizes use
release output. In release, the development visit oracle and the unloaded
`_direct-plan.json` are absent from the timed/byte-counted code.

This adopts the code sharing already used by
`platforms/browser-tea/Tea.beni`'s `application`: its callbacks call
`app.update` and `app.view`, rather than copying them per message. The runtime
patch comparison was also checked against
`references/dom-expressions/packages/runtime/src/client.js`'s `insert` and
`insertExpression`: it preserves immutable value identity before changing the
DOM. Neither that identity rule nor direct's analysis masks is removed to get
a timing improvement.

## 4. Bytes by part

All loaded JavaScript, as served; brotli quality 11, matching the +6.6 kB claim.
CSS, HTML, maps and the unloaded plan JSON are excluded. Both release pages load
one JavaScript file.

Brotli is not additive. The accounting below replaces source declarators by
`name=0` stubs in a fixed order, without reoptimising unrelated code, and charges
the change in whole-bundle compression to that part. Every intermediate source
is syntax-checked. The last row retains startup, stubs and remaining compression
interactions. These are accounting partitions, not executable variants or
independent downloads. Raw columns count original source spans. Part maps and
matching bundles are retained so short-name reuse cannot change classification.

| Part | Tea raw / br B | Direct before raw / br B | Direct fixed raw / br B |
| --- | --- | --- | --- |
| core | 26,825 / 8,138 | 27,835 / 8,237 | 27,835 / 8,177 |
| runtime | 22,150 / 7,682 | 25,643 / 8,895 | 25,643 / 8,855 |
| handlers | 7,994 / 1,336 | 182,193 / 2,282 | 29,963 / 2,168 |
| templates | 19,454 / 3,282 | 89,134 / 9,582 | 89,134 / 9,501 |
| application and startup | 49,538 / 10,951 | 36,789 / 9,034 | 36,809 / 9,067 |
| Total | 125,961 / 31,389 | 361,594 / 38,030 | 209,384 / 37,768 |

Of the original +6,641 compressed bytes, this convention charges +99 to core, +1,213 to runtime, +946 to handlers, +6,300 to templates, offset by −1,917 in application/startup. The direct template consumer matrix alone occupies 41,045 raw bytes.

The large raw handler reduction produces only a small compressed saving. The
runtime still carries parameter-context capture, argument preparation,
selection/cache construction and row/value adaptation. Templates carry the
source-read descriptors, patch/restate entry functions and the per-program
consumer matrix. Those costs are outside the group-entry count. Core is not
the cause of the 21% gap: the binding maps show largely the same core, with
`Dict.foldl` additionally reachable on direct, `Dict.getHelp` on tea, and tea's
`Task.turn`/`onTurn` absent on direct. Whole-program naming/representation and
compression context also affect their byte charges.

## 5. General rule and regression coverage

`Lower.updateArmShape` only permits a multi-key update to be consumed into its
handlers when `specialisedArm` can select its constructor arms. Otherwise the
existing shared-update path is used. Single-key programs have no duplication
and keep their old inline path and static-page consumption.

`chooseArm` outlines the computed root's selector once per mounted program.
It recomputes the arm-and-input result at the same point in each selected
handler, inside that handler's template context. Instance-dependent row/arm
selectors retain their scope. Error paths restore the compiler's entry context.

`directDispatch` groups adjacent identical constructor steps and descends only
after a shared prefix matches. It retains leaf parameters, key priority,
defaults and the final fallback. It changes no analysis key or write set.

`DispatchPrefixes` pins nested left/right keys, all three inner constructors,
a quiet default and the shared tuple update, on both platforms with value fuzz.
`RootSelector` pins current-model reads across root switches and same-arm
changes, also paired and fuzzed. Narrow emit fixtures pin the two sharing shapes.
The original compiler fails their emitted-shape goldens: it repeats the Left
test three times and has no shared root selector. Existing helper/volatile-row,
control, command and negative visit-oracle fixtures remain in the gates.

All 62 scripted dispatches match the predicted group instances. Reader visits 105 groups over 18 dispatches, Editor 63 over 12, and Tour 145 over 32. The three timed keys visit 8/0/3 groups respectively. All five empty-write internal-link handlers visit zero groups. The nine `patchAll` calls correspond exactly to the nine `ChangedUrl` star-key dispatches. **Criterion 7 does not fire.**

The built-platform S0 campaign covers the same 102 programs as report 95: Conduit has 96/97 bounded keys, 1/75 constructors under `*`, 79 markup sites with zero value roots, and 782 key/group pairs over 114 groups (8.146 per key). Dynamic star dispatches remain 9/62 (14.52%). The campaign still fires the previously reported dynamic-star, general-value-root (2/7 in `ValuePath`), pair-cost and trie tripwires; sharing does not repair those mechanisms or withdraw their recorded findings. Empty/hello direct floors are 327/368 B brotli (tea 447/466 B).

## 6. Report 87 sweeps

The full campaign retains all eleven sweeps, 79 operation/size cells and 10,980 observations, with no failure or skipped cell. It uses the original and frozen compilers on the same machine, real untraced events, pinned CSS, two fresh pages per cell, five warm-ups and twelve measured clicks per page. Stream has two three-second windows instead. `beni-start` development output is also retained in the raw file; the table compares release output.

Largest-size point medians, milliseconds (stream is per message):

| Sweep/op | Size | Vanilla | Solid 2 | Tea | Direct before | Direct fixed |
| --- | --- | --- | --- | --- | --- | --- |
| holes/tick | 10000 | 0.0725 | 0.1700 | 0.1050 | 0.0775 | 0.0800 |
| rows/change | 30000 | 0.0600 | 0.1250 | 0.3800 | 0.0850 | 0.0850 |
| rows/swap | 30000 | 0.1200 | 4.6975 | 0.6625 | 0.1350 | 0.1350 |
| filtered/toggle | 1000 | 0.0850 | 0.2000 | 0.1700 | 0.1550 | 0.1725 |
| filtered/filter | 1000 | 2.6550 | 7.5475 | 7.0075 | 6.9475 | 6.7075 |
| filtered/tick | 1000 | 0.0775 | 0.1700 | 0.1175 | 0.0800 | 0.0800 |
| width/field | 1024 | 0.0800 | 0.2375 | 0.4850 | 0.3850 | 0.3875 |
| depth/leaf | 128 | 0.0700 | 0.3100 | 0.1775 | 0.1775 | 0.1625 |
| derived/tick | 100000 | 0.0550 | 0.1375 | 0.0775 | 0.0600 | 0.0600 |
| live/tick | 10000 | 0.0550 | 0.1300 | 0.0850 | 0.0750 | 0.0775 |
| helperRows/tick | 10000 | 0.0575 | 0.1400 | 0.0800 | 0.0650 | 0.0600 |
| tree/tick | 12 | 0.0650 | 0.1425 | 0.0850 | 0.0700 | 0.0700 |
| burst/burst | 1000 | 1.7575 | 2.3175 | 1.6050 | 1.8025 | 1.7575 |
| stream/stream | 100 | 0.0037 | 0.0055 | 0.0039 | 0.0038 | 0.0033 |

Of the 79 paired before/fixed condition medians, 27 are higher after the change; **0 have a slower-side disjoint IQR** (fixed Q1 greater than before Q3). This is descriptive spread from two page clusters, not a statistical equivalence claim or an invented regression allowance. The entire distributions remain archived.

There are 57 distinct release programs: 47 are byte-identical before/after. The ten changed programs are the five `live` and five `tree` sizes. Each differs only by a seven-byte terminal `;return` in the generated dispatcher. All 57 outputs are identical after report 87's Terser normalization, including compressed sizes; production Conduit bytes above use their separate as-served convention.

The additional control batch reruns exactly those ten changed pages with the original report’s Solid 1 and P3 controls as well. P3 has no tree implementation (five explicit skips); every supported cell completes without failures.

| Page | Size | Vanilla | Solid 1 | Solid 2 | P3 | Tea | Direct before | Direct fixed |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| live | 100 | 0.0550 | 0.1225 | 0.1625 | 0.0675 | 0.1150 | 0.0825 | 0.0850 |
| live | 300 | 0.0650 | 0.1200 | 0.1775 | 0.0800 | 0.1225 | 0.0925 | 0.0850 |
| live | 1000 | 0.0700 | 0.1300 | 0.1625 | 0.0800 | 0.1150 | 0.0900 | 0.0925 |
| live | 3000 | 0.0625 | 0.1150 | 0.1550 | 0.0750 | 0.1075 | 0.0850 | 0.0875 |
| live | 10000 | 0.0500 | 0.1025 | 0.1300 | 0.0625 | 0.0875 | 0.0750 | 0.0700 |
| tree | 4 | 0.0575 | 0.1125 | 0.1300 | unsupported | 0.1025 | 0.0575 | 0.0675 |
| tree | 6 | 0.0725 | 0.1300 | 0.1525 | unsupported | 0.1050 | 0.0800 | 0.0825 |
| tree | 8 | 0.0725 | 0.1325 | 0.1425 | unsupported | 0.0950 | 0.0625 | 0.0600 |
| tree | 10 | 0.0625 | 0.1250 | 0.1625 | unsupported | 0.0850 | 0.0750 | 0.0775 |
| tree | 12 | 0.0550 | 0.1100 | 0.1550 | unsupported | 0.1000 | 0.0725 | 0.0700 |

Report 87’s older threshold misses remain visible: the accepted full batch’s largest live-row point ratio to vanilla is 1.409, above 1.15; tree is 1.077. Older width/depth misses remain on unchanged source. This change adds no observed disjoint-IQR regression; it does not discharge those older limits.


## 7. Validation and limits

The frozen compiler was checked sequentially, with no compiler rebuild during a suite:

- `zorg build test-run-hashes -j1`: 546/548 pass; only the two known macOS case-folding failures. Hashes were recorded by the tool after rebase.
- `zorg build gates`: refuses this aarch64-macOS host because hardware instruction counting is unavailable. The hardware-budget gate is still owed on a supported x86-64 Linux PMU host.
- `zorg build test test-blackbox fmt-check beni-fmt-check test-bench -j1`: 1,340 pass, 15 skip, the same two known failures.
- `zorg build test test-blackbox fmt-check beni-fmt-check -Dllvm -j1`: 1,304 pass, 15 skip, the same two known failures.
- `zorg build test-browser -Dcorpus=browser/direct -Dchrome=… -j1`: passes, including paired pages and value fuzz in real Chrome.

No budget or coverage was weakened. The two known tests are `stale path same file under case folding not removed` and `stale path equal under case folding but another removed`. Hosted Linux CI and review results are recorded separately in the PR; a hosted run with budgets disabled is not the hardware gate.

*Review and second rebase, 2026-10-15:* master advanced to `2f397d7b6` while
profiling. The rebase preserves both the nullary-method amendment and the
parameterised-read amendment, and every diary entry. The review follow-up adds
scope/count assertions and paired/fuzz `RootSelectorDerived`. The computed-root
path has no cached derived slots: leading view lets execute inside the shared
selector. `directArm` binds a destructured model before selecting the arm; branch
guards are absent from the language. `Writes.keyTree` emits depth-first keys,
so interleaved prefixes and an empty-path catch-all in the middle cannot arise.

After that follow-up, both unfiltered native and LLVM test/blackbox/format
runs pass 1,315 tests, skip 15 and fail only the same two known macOS cases.
The full direct Chrome corpus passes again. The full rebased hash replay has
552 passes and the same two known failures; the added derived-root case's
focused `zorg build test-run-hashes` passes. `post-review-validation.json`
retains these final commands separately from the original frozen batch.
The hardware-budget gate is still owed.

The final ReleaseSafe LLVM compiler emits **byte-identical Conduit tea/direct
release bundles and all 57 direct sweep programs** compared with the profiled
compiler. A fresh S0 run is byte-identical too. The hashes, compiler fingerprint
and every program comparison are `post-review-rebase.json` / `post-review-s0.json`
in the archive. The profiles and timings therefore still describe the served
programs after rebase; no second timing batch is substituted.

The PR remains draft and unmerged. This work does not withdraw report 87's
older threshold misses or claim the outstanding full V3 campaign has run.
The remaining template/runtime byte cost is priced above; it is not attributed
to core or hidden by a changed compression convention.

## 8. Reproduction

Raw profiles, code/part maps, summaries, build fingerprints, interrupted-run
notes and exact commands are in
[`bench/conduit/results/2026-10-15-profiles/`](../../../bench/conduit/results/2026-10-15-profiles/).
Run through `direnv exec .`; all compiler builds and tests use `zorg`.
`attribute.mjs` also accepts an archived profile pack as `--profiles=<pack.json.gz>`.
