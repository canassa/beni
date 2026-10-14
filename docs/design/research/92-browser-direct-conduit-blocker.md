# 92 — Conduit on direct: an ownership blocker, preserved

*2026-10-14. Native/self-hosted beni from master `748745c01`, after the
owner's criterion-6 timing deferral and PR #89's rebase merge. No LLVM.*

Conduit's unchanged application is rejected by direct ownership enforcement.
This blocks completing slice S6: the direct transcripts, bundle size, three
Chrome timings and built-platform dispatch comparison cannot be measured.
The TodoMVC timing deferral does not waive this guarantee. No lists were
copied, no original application was edited, and no checker rule was weakened.

## 1. The pinned program

`beni build --platform=browser-direct --release --no-cache examples/conduit/src`
returns exit 1 with one `list_may_be_shared` diagnostic at
`Main.beni:254:5`, the `Tea.application` entry. Its four paths are:

- `model#Article.0.errors`
- `model#Home.0.feed#Loaded.0#Model.0.errors`
- `model#Profile.1.errors`
- `model#Profile.1.feed#Loaded.0#Model.0.errors`

The ownership dump reports all four as approximate `payload` rejections:
view-event messages may retain a model list, and the summary does not tell
update arms apart. Of 26 ownership demands, 22 are accepted and four rejected.
The original browser-tea pages still run; direct's stronger ownership guarantee
requires a proof that the checker currently cannot provide.

Reader, Editor and Tour are now explicit projects under
`tests/pending/browser/direct/`. Each retains its original external source
reference, script, behavior golden and owner-granted budget. `tests/pending/RED`
pins `dev: exit=1 codes=list_may_be_shared×1` for all three. Filtered pending
validation reports three RED cases with exactly those signatures. This extends
CK-223; it is not a new runtime refusal or a TodoMVC timing failure.

## 2. Measurements that remain possible

`bench/writesets/results/2026-10-14-conduit-baseline.json` records the complete
analysis/browser-tea rerun, with its compiler commit and direct blocker.

| Measure | Current baseline | What it establishes |
|---|---:|---|
| Conduit bounded keys | 96 / 97 (98.97%) | analysis exceeds the two-thirds bar |
| Constructors beneath `*` | 1 / 75 (1.33%) | only `ChangedUrl` is unbounded |
| Scripted dispatches mapped to `*` | 9 / 62 (14.52%) | browser-tea's S0 baseline; exceeds 10% |
| Reader / Editor / Tour | 2/18, 1/12, 6/32 | all 62 messages match a leaf key |
| Bounded-key/group pairs | 667 across 96 keys, 106 groups | 6.95 pairs per bounded key |
| Browser-tea release JS | 125,961 raw; 31,389 B brotli 11 | current comparison subject, not direct's size |

The historical S0 report had 90/91 bounded keys and 829 pairs. Today's source
and analysis have evolved, so those static numbers are not held constant.
The dynamic counts remain exactly S0's 9/62. No direct handler/group calls or
`patchAll` invocations were measured on Conduit: it does not build. Criterion 7
therefore remains unjudged, as does the direct 0.7× size target. There are no
substituted browser-tea timings presented as a direct comparison.

## 3. Independent composition coverage

Two small paired pages isolate the rendering behavior from the ownership
blocker. Their one golden was captured from the real Node/happy-dom driver,
then compared against direct and browser-tea, development and release.

`NestedPageKeys` wraps child messages through `Html.map`. It edits a controlled
input, rebuilds the same `Open` variant with a new serial, then sends an event
whose payload must use that serial. A stale payload produces `-100`, whereas
the golden has the expected increment. Leaving and returning remounts the page,
with its new controlled value and counter. The write dump has exact nested
`Child · Add` and `Child · Typed` keys; the cross-variant `Rebuild` and `Leave`
keys are `*`.

`OpaquePageKeys` repeats the same source behavior through a higher-order update
wrapper. The dump reports one `*` key and five dynamic groups, proving that
this twin exercises the opaque path rather than the two exact child keys.
Both scripts pass in happy-dom and Chrome in all four builds. Differential
value fuzz also passes; ten happy-dom run hashes were recorded with no failed
JavaScript run.

These are focused adversarial composition attempts: current event payloads,
controlled values, same-variant rebuilding, variant teardown and the opaque
update. They do not stand in for the full second V3 campaign after Conduit.
That campaign and the app measurements remain open with the blocked slice.

## 4. Reproduction

All compiler/test builds use `zorg` with its native backend. The baseline
script uses that installed ReleaseSafe compiler, not an LLVM benchmark build.

```sh
direnv exec . /opt/homebrew/bin/zorg build test-pending -Dcorpus=browser/direct/Conduit
direnv exec . /opt/homebrew/bin/zorg build test-blackbox-corpus -Dcorpus=PageKeys
direnv exec . /opt/homebrew/bin/zorg build test-browser -Dcorpus=PageKeys -Dchrome='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
direnv exec . /opt/homebrew/bin/zorg build test-run-hashes -Dcorpus=PageKeys
direnv exec . env BENI=zig-out/safe/bin/beni node bench/writesets/stats.mjs --json
```

The source of truth for the stop is ownership-checker.md §28.5's approximate
rejection rule and CLAUDE.md rule 10: preserve the intended design and report
the wall. Proceeding needs the event-payload summary proof, not a change to
Conduit or to its transcript oracle.

Unfiltered `zorg build gates` reports 1,295 passed, 15 skipped and only the
four owner-authorized macOS failures: two case-folding cases and two driver
cache-pruning CPU budgets. No additional failure or formatting error remains.
