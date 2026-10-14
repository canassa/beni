# 94 — Conduit's document helpers compile; the built dispatch misses its prediction

*2026-10-14. Native ReleaseSafe compiler built with zorg 0.17.1+zorg.1,
Node 24.19.0, Apple M2 Pro, Chrome 155.0.8059.80. The raw count artifact
records the compiler binary's SHA-256 and base commit; timing records both
release entry hashes. No LLVM.*

## 1. Verdict and mechanism

**Criterion 7 fires. S6 stops here.** The analysis predicts no group visits
for `ClickedLink · Internal`: its write set is empty. The emitted handler
actually enters 11 group comparisons in Reader, and 11, 24, 11 and 5 in Tour.
None of these visits is a `patchAll` call.

The document view is compiled in place, but its helper-returned document
remains a value. Each handler chooses that value again. It calls the page
view and `Page.frame`, then the existing markup value path patches their
kinds. Those patches enter their groups' identity comparisons, including
frame groups whose reads the key did not change. A root branch has no hole
read set and is visited on every key; its complete document computation now
reaches these shared helpers. S0's analysis instead walks those helpers as
sites and predicts selective visits from anchored reads. The emitted value
path does not implement that selective shared-site protocol.

This is a disagreement between the implemented lowering and its analysis,
not a new unknown message key or an ownership rejection. Renaming the value
visits, adding them to the prediction, or treating every key as `*` would
hide the miss. No such adjustment was made. The second full V3 campaign and
acceptance of S6 remain stopped at this criterion; the focused regressions
below do not stand in for that campaign.

## 2. What now builds

The dated document-helper amendment in browser-direct.md and interface 1.12
specify the complete document choice. The compiler binds the view's model,
outer bindings and decision in place; there is no runtime call of `view`.
A direct helper call or a taken source arm computes one document. Body and
title read that same result. The root has one value slot, so switching
source arms that return the same markup kind preserves focus, and rebuilding
the same model variant refreshes handlers and controlled values. Document-arm
statements run with the value; verify mode does not repeat effects.

Reader, Editor and Tour move together from pending to the paired direct
corpus. Their external application sources and steps are retained. The owner
extended the direct page grants to 15,300M on 2026-10-14; separate Reader/Editor
value-fuzz grants are 4,900M. Both platforms, development and release, compare with
one golden per promoted script. Goldens were captured with the paired driver's
existing `--no-comments` mode, which also collapses elements made empty by
removing renderer sentinels. No application code was rewritten. Each script
has a separate differential value-fuzz case; Tour retains the global budget.

Focused coverage:

- `DocumentHelper`: a direct helper call with body/title and one effectful
  helper evaluation per message.
- `DocumentHelperBranch`: same-variant changes, switching arms returning the
  same helper kind, arm statements, and body/title agreement. Its first fuzz
  run found focus lost after `focus #inc; message Switch`; the common slot
  fixes it. With the implementation set aside, it fails to compile.
- `DocumentHelperExternal`: an imported helper, with no markup root in Main.
- The branch's existing `NestedPageKeys` and `OpaquePageKeys` retain nested
  handlers, updated payloads after a same-variant rebuild, controlled inputs,
  teardown/remount, and the opaque update's actual `*` path.

All ownership limits remain pinned under pending. Conduit's enforcing
ownership case still accepts all 26 demands. No new `List.copy` was added.

## 3. Analysis and built counts

The full S0 analysis campaign was re-run over 99 programs, including current
corpus additions, TodoMVC, the table and all eight Conduit page programs.
Its Conduit prediction is unchanged from research 92's current baseline:

| Measure | Analysis | Built observation |
|---|---:|---:|
| Keys bounded | 96 / 97 | 97 emitted handlers, the one star key is ChangedUrl |
| Constructors under `*` | 1 / 75 | ChangedUrl alone calls `patchAll` |
| Sites / value roots | 79 / 0 | helper documents run through a root value slot |
| Bounded pairs / groups | 667 / 106 | zero-write Internal visits 5–24 group guards |
| Dynamic star dispatches | 9 / 62 | 9 / 62 actual `patchAll` calls |
| Empty direct page | ≤ 500 B tripwire | 327 B brotli; imports only `run`, no fibers |

| Script | Dispatches | Actual `patchAll` | Entered group comparisons |
|---|---:|---:|---:|
| Reader | 18 | 2 | 378 |
| Editor | 12 | 1 | 215 |
| Tour | 32 | 6 | 473 |

The counting harness instruments copies of development output. At each
emitted key handler it opens a record; each emitted kind's group guard records
an entry before comparing its inputs, and `patchAll` records its actual call.
The instrumented guard identities include module, source line and group.
This counts guarded groups; unguarded/every-render work is outside this
measurement. There are 105 guard templates; this is not a claim that value-kind guards
and the analysis's 106 groups have identical grouping. A zero prediction
versus positive actual visits establishes the miss without conflating them.
Mount visits are outside handler records. The copies do not supply timings
or sizes. All 62 scripted dispatches are observed; none is an unmatched key.

## 4. Bytes and timed messages

Whole emitted JavaScript, concatenated in path order, brotli quality 11:

| Build | browser-tea raw / brotli | browser-direct raw / brotli |
|---|---:|---:|
| Development, no source maps | 428,763 / 68,879 B | 1,267,702 / 105,032 B |
| Release | 125,961 / 31,389 B | 299,601 / 32,411 B |

Release direct is 3.3% larger, and misses the 0.7× target (21,972 B against
this tea subject). Its handlers duplicate the root view decision and helper
calls while retaining the value-kind machinery; the byte result is consistent
with the group-visit finding.

Chrome medians in milliseconds, 15 fresh pages per platform, operation and
mode. Platforms alternate order per sample. Setup uses the corpus scripts'
API answers and happens outside timing. Feed/favorite use real CDP clicks;
the editor appends one character with `Input.insertText`. Untraced starts in
window capture and ends eight microtasks after window bubble. Trace script
is the union of EventDispatch, FunctionCall and RunMicrotasks intervals
clipped to the same user-timing marks. Body and title agree after each sample.
There is no CSS or vanilla Conduit subject. Initial host load averages were
10.61 / 8.41 / 7.24; each sample's one-minute load is retained.

| Message | Tea untraced | Direct untraced | Tea traced | Direct traced |
|---|---:|---:|---:|---:|
| Feed tab | 0.370 | 0.465 | 0.652 | 0.858 |
| Favorite | 0.305 | 0.435 | 0.539 | 0.803 |
| Editor keystroke | 0.420 | 0.480 | 0.658 | 0.832 |

Direct is slower on all three in both modes in this batch. These are small,
loaded-host measurements, not a geometric aggregate or a parity claim. The
criterion verdict rests on actual visits, independently of these timings.

## 5. Validation and remaining boundaries

Happy-dom: all three scripts match both platforms in both builds; their
value fuzz passes. The three helper regressions also pass their paired runs
and value fuzz. Run hashes are re-recorded with `zorg build test-run-hashes`;
none is hand-merged. The negative helper compile and the earlier focus-fuzz
failure were observed before their fixes.

Chrome: the three scripts' page transcripts match. Reader value fuzz passes;
Editor and Tour value fuzz hit the existing driver failure where a navigation
leaves the document and the next generated send finds no fuzz mount. PR #103
tracks the navigation stop; PR #109 tracks Chrome's settle phase. Neither
unmerged harness change is incorporated here, and these two fuzz runs are
not claimed green. The three helper regressions and their value fuzz pass in Chrome.

The CPU fallback had lost the configured instruction limit, so existing
owner grants became 999 ms rather than being scaled. The build graph now
retains that limit separately for scaling. With recorded hashes the original
Conduit grants fit, but fresh page runs cost 3.17–3.23 s against the old
2.787 s fallback, and Reader/Editor fuzz cost 1.01–1.02 s against 0.999 s.
The owner explicitly approved increasing them: page cases now have 15,300M
and Reader/Editor value fuzz have separate 4,900M `.fuzz-budget` grants,
sized from those measurements plus 10%. Tour fuzz keeps the global budget.
A page grant still never covers fuzz implicitly. Profiling with a 1,000M global
limit passes Reader with both explicit grants; removing only its fuzz grant
fails only value fuzz (622 ms against 232 ms). Fresh comparisons with the
records set aside pass the new grants: 18 unverified Node runs among 38 runs
for the three scripts and four existing Conduit-shape pages. Two cache-pruning tests also
spent about 1.47 s creating/deleting 5,000 files. Their smallest threshold
input is 1,025: it still tests pruning above 1,024, the 128-entry bound, and
retention of recent entries. Those tests now fit without changing assertions
or limits. The owner's two case-folding failures remain untouched.

Final unfiltered `zorg build gates`: 1,297 passed, 15 skipped and only the
owner's two existing case-folding failures. Full `test-run-hashes`: 546 passed
and those same two failures; all executing corpus cases succeeded and their
hashes were recorded. Native formatting and every new paired case are green.

## 6. Reproduction and retained evidence

```sh
direnv exec . zorg build test-run-hashes
direnv exec . zorg build gates
direnv exec . zorg build test-browser -Dcorpus=Conduit -Dchrome="$BENI_CHROME"
direnv exec . env BENI=zig-out/safe/bin/beni node bench/writesets/stats.mjs --json
direnv exec . node bench/conduit/measure.mjs
direnv exec . node bench/conduit/time.mjs --chrome="$BENI_CHROME"
direnv exec . node bench/size.mjs --beni=zig-out/safe/bin/beni --pages-only
```

The complete raw results are `bench/conduit/results/2026-10-14-analysis.json`,
`2026-10-14-counts.json`, `2026-10-14-timing.json`, and
`2026-10-14-floor.jsonl`, plus the budget observations in
`2026-10-14-budgets.json`. The count result records the prediction and each
actual handler's visits. The timing result records every sample and entry
hash. Measurements must use clean output for speed, never the count copies.
