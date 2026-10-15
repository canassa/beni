# 95 — Parameterised helper templates match the visit plan, at a measured cost

*2026-10-15. Apple M2 Pro; zorg 0.17.1+zorg.1; Node 24.19.0;
Chrome 155.0.8059.80. Local native and LLVM ReleaseSafe suites were run; §7 records the
post-rebase hardware-budget gate refusal.
Research 94 and its artifacts remain the historical before measurement.*

## 1. Result

**Criterion 7 no longer fires.** Each of Conduit's 62 scripted dispatches
enters exactly its independently predicted instance/group set. Its five
`ClickedLink · Internal` dispatches now enter zero groups, versus the
5–24 value-kind comparisons in research 94. Actual `patchAll` calls remain
Reader 2/18, Editor 1/12 and Tour 6/32: exactly the `ChangedUrl` keys.

**This does not establish S6 performance acceptance.** Release brotli grows
32,411 → 38,030 B, and browser-tea is faster on all three timed messages in
the final fresh batch below. Direct before/after medians are mixed within
overlapping spreads; no speed improvement is established. No threshold, application source, budget or test
coverage was changed to conceal either result. The second full V3 campaign
is still owed; the focused composition regressions here do not claim to be
that campaign. Existing S0 tripwires remain visible in §5.

## 2. The general lowering rule

The dated amendments in `browser-direct.md` and `write-sets.md` precede the
implementation. Markup returned by a function is a parameterised template,
with groups that retain reads of its parameters and captures. Each call
substitutes those reads into its caller's model paths. The compiler emits
per-key masks for those substituted reads, including producer entry facts.
One helper can therefore serve different arguments and call sites, across
modules, without baking the first caller's paths into its reusable body.
There is no Conduit-specific lowering or runtime branch.

The selected groups are ordered entry functions cached by program, template,
call path and message key. An ordinary patch invokes that selection rather
than scanning every group's identity guard. Preparation still costs
O(arguments + local derivation checks), with cached local derivations.
Event capture refresh and every-render work retain their separate protocols.
A selection's first construction costs O(template groups). These costs are
real, even when no DOM value changes.

A branch's control dependencies follow each formal parameter separately.
They are discharged when every alternative supplies the same anchored path
or the same closed value. Different paths or values retain the choice read.
Path identity survives this metadata, including exact collection identities.
An opaque impure host result carries `ω`, which reaches only the holes that
consume it and conflicts with every dispatch, including an empty write set.
Passing the clock to a pure helper must not freeze it.

Component arguments and children are evaluated in the caller's substitution;
only the component body extends its call path. A fragment between component
tags is outlined over its enclosing input environment. Mapped value rows
retain their physical row scope. Overlapping structural reconciliation and
read walks coalesce each surviving instance/group once per dispatch; the
oracle still rejects repeated actual entries.

## 3. Precision, fallbacks and fixtures

Each new `Template*` case runs development and release on both platforms
against one transcript, with paired value fuzz and direct visit verification.
The cases also pass in Chrome, including value fuzz.

| Shape | Fixture | Built behavior |
|---|---|---|
| Nested/imported helpers; two calls with different arguments | `TemplateCalls` | Substituted hole groups |
| Keyed and positional inline rows calling helpers | `TemplateRows` | Row-scoped substituted groups |
| A helper owning keyed and positional lists | `TemplateOwnedRows` | Producer reads and row reads both retained |
| Helpers chosen by `case`; literal and path arguments; invariant shared path | `TemplateChoices` | Per-parameter control reads |
| Case-selected helpers in keyed value rows | `TemplateRowChoices` | Selected kind with the row's substitution |
| The same through `Html.map` | `TemplateMappedRows` | Physical row scope retained through maps |
| Runtime `Html.text` rows | `TemplatePrimitiveRows` | Native primitive payload, no array metadata mutation |
| Component children: one helper hole and a fragment containing one | `TemplateChildren` | Caller substitution, precise fragment groups |
| Root helper with local derivations | `TemplateRootLets` | Local preparation and substituted groups |
| Host-dependent argument, including a no-op message | `TemplateClock` | `ω` selects the dependent hole every render |
| Helpers inside a `List Html` produced by `List.map` | `TemplateListValues` | Hole read masks retained; general value-list reconciliation, no row edit plan |
| Stored markup, an opaque `*` preserving the same block, bound/unbound uses | `TemplateValue`, `TemplateMixedValue`, `TemplateRootValue` | Explicit placement fallback |

**Fallbacks are inspectable.** `_direct-plan.json` classifies each source root
and records why it needs a value path. A value produced outside the active
view walk, including markup stored in the model or passed without a resolved
producer, has no parameter substitution: its placement mask gates entry, and
an entered fallback visits all its dynamic groups. An unchanged block object
does not silently bypass this declared cost. This composes through `Maybe`,
markup lists and `Html.map`. Quiet slots visit none.

`List Html` has no structural row edit plan. Its list reconciliation remains
O(list values), and value-root selection is constructed in O(template groups)
per entered patch rather than cached as a fully resolved template. Existing
hole masks still select individual known helper holes when facts are available;
this is not a claim of precise structural list edits. The fixture's consumer
plan pins this fallback on both helper roots. A `For` has the precise row path.
Recursive or unresolved producers and analysis caps also declare their fallback
reason and conservative cost; an unknown path without one is a verify defect.

Existing `view`-shape refusals remain: an arbitrary computed view factory and
a view field naming a function in another module are outside the program
entry lowering. A local view calling an imported helper is supported. These
are entry-shape limits, not silently rendered fallbacks.

## 4. The corpus-wide invariant

Every direct development page emits observations **before** group identity
comparisons. At handler end, its observed instance/group multiset must equal
the analysis's expected set: no missing group, no extra group, no repeated
entry. Structural scopes identify surviving eligible rows/arms; mount work
is excluded. A retained live-template inventory predicts children even when
the patch call that should have reached them is missing. The prediction uses
immutable analysis masks, never the execution selection cache or its trace.
It does not evaluate user expressions or effects again. Release omits it.

This applies to every browser-direct corpus page and value-fuzz dispatch in
`zorg build gates`, with no fixture opt-in. Four black-box negative probes
independently remove a group call, duplicate it, omit a child patch, and corrupt
only an execution-cache selection. All are rejected. The last probe leaves
the DOM correct: it proves the visit oracle checks precision as well as values.
`ChoiceParameter.writes` and selected `.plan` goldens also pin the analysis.

The focused red-first attempts found and fixed lost path-control provenance,
row traversal overlap, mapped row ownership, identical-block fallback bypass,
component-child call paths, and host-dependent helper arguments. These were
compiler/runtime findings; no application workaround was introduced.

## 5. Conduit measurements and remaining mechanisms

Release bytes are clean emitted JavaScript, concatenated in sorted path order
and compressed with brotli 11. Counts use instrumented development copies only.
The separate, unloaded consumer-plan JSON is 312,742 raw bytes on the current
release build; it is not part of the JavaScript byte figure.

| Platform | Raw JS | Brotli 11 |
|---|---:|---:|
| browser-tea | 125,961 | 31,389 |
| browser-direct before | 299,601 | 32,411 |
| browser-direct now | 361,594 | 38,030 |

The old compiler's binary SHA-256 exactly matches research 94. The new
artifact records both compiler hashes, the source diff hash and base commit.

Fifteen fresh pages per subject/operation/mode, three subjects with balanced
rotated/reversed order, real CDP clicks/input, the corpus's scripted API and
virtual clock, setup outside timing. Each post-event page/property transcript
must match across all subjects. No CSS. Medians in milliseconds:

| Message | Tea untraced | Direct before | Direct now | Tea traced script | Direct before | Direct now |
|---|---:|---:|---:|---:|---:|---:|
| Feed tab | 0.295 | 0.390 | 0.395 | 0.525 | 0.767 | 0.776 |
| Favorite | 0.250 | 0.325 | 0.315 | 0.453 | 0.655 | 0.702 |
| Editor keystroke | 0.315 | 0.340 | 0.365 | 0.510 | 0.657 | 0.703 |

These are sub-millisecond, loaded-machine measurements, not a parity claim.
All raw samples and loads are archived. Tea is faster on all three in both
measurement modes. Direct before/after untraced medians are mixed; traced
medians are higher after the change. The overlapping spreads do not establish
a statistically significant direct before/after difference. Untraced min/max
across the 15 samples, in milliseconds:

| Message | Tea range | Direct before range | Direct now range |
|---|---:|---:|---:|
| Feed tab | 0.265–0.490 | 0.335–0.525 | 0.370–0.435 |
| Favorite | 0.225–0.400 | 0.285–0.450 | 0.270–0.405 |
| Editor keystroke | 0.275–0.440 | 0.305–0.365 | 0.315–0.400 |

The group precision repair does not establish a speed win.
The mechanism added by this implementation is template context capture,
parameter preparation and selection lookup/first-use construction, plus
outlined entry functions and masks in the bundle. Instrumented counts show,
for the scripted feed tab, 6 template patches, 12 captures, 6 selection lookups
and 5 new selections for 8 actual groups; editor input has 3 patches, 7 captures,
3 lookups and 3 first-use selections for 3 groups (later inputs reuse them).
Favorite has zero selected DOM groups but still a root value patch and context
work. This identifies remaining work outside the group guards; it does not
attribute an exact portion of Chrome CPU time to any one operation. No timing
or byte tuning followed this batch.

The final S0 campaign enumerates 102 programs (99 before the rebase). Conduit has 96/97 bounded keys,
1/75 constructors under `*`, 79 sites and zero value roots. Its bounded leaf
facts now have 782 pairs over 114 groups, versus 667/106 before: choice-dependent
helper inputs now retain reads the old argument abstraction discarded. Message
write sets are not widened. Producer entry facts are additional consumer facts,
not counted as new S0 leaf holes. Actual instance/group visits are 105 Reader,
63 Editor and 145 Tour, each exactly predicted by the live-instance oracle.
These include structural scope and producer work, so summing old value guard
comparisons is not the same measurement. The direct empty floor stays 327 B.

Existing S0 tripwires still fire: dynamic star share is 9/62 (14.52%, above
10%); largest pairs/key is 8.146 versus the unchanged 0.667 limit; the separate
ValuePath program has 2/7 value roots; and the trie's write half remains in the
set-only subject. None is renamed a pass. These and the larger Conduit output, without an established speed win,
prevent treating the helper precision repair as overall S6 acceptance.

## 6. Validation and reproduction

- Final `zorg build test-run-hashes`: all corpus behavior and value fuzz
  verified; 546 passes and only the two known macOS case-folding failures.
  No hashes were hand-edited or hand-merged.
- Final unfiltered `zorg build test test-blackbox fmt-check beni-fmt-check`,
  also with `-Dllvm`: each has 1,304 passes, 15 skips and only those same two
  known failures. All four deliberate-corruption probes are included.
  **The hardware-budget `zorg build gates` run is owed on x86-64 Linux:**
  current master refuses this unsupported host (§7). The earlier pre-rebase
  CPU-fallback gate results are historical, not a final budget verdict.
- Final `zorg build test-browser -Dcorpus=Template -Dchrome=…` and the same
  with `-Dcorpus=Conduit`: all paired pages and value fuzz pass. Master's
  driver fixes remove the previous Editor/Tour Chrome navigation-fuzz wall;
  this work does not claim authorship of those driver fixes.
- No new budget grant is used. The owner approved 5,300M for Tour fuzz;
  the earlier hash-recorded gate fitted the existing CPU fallback. Final
  instruction-budget validation remains owed; no instruction count is inferred
  from that CPU evidence.

Raw artifacts are under `bench/conduit/results/2026-10-15-rebased-*`, plus
`2026-10-15-validation.json`. The initial pre-rebase batch remains archived
under `2026-10-15-*` without the `rebased` suffix; final tables use the later batch. From the repo root,
use `direnv exec .` with `node bench/conduit/measure.mjs` and `BASELINE_BENI`
pointing to the research-94 compiler, then `node bench/conduit/time.mjs
--baseline=browser-direct-before-release --samples=15`. S0 is `BENI=zig-out/safe/bin/beni
node bench/writesets/stats.mjs --json`; the floor is `node bench/size.mjs
--beni=zig-out/safe/bin/beni --pages-only`. The results README maps each artifact.

## 7. Review and rebase follow-up

The branch was subsequently rebased onto master `df04ca2db`; all previous diary
blocks were checked to survive verbatim. Conflicted run hashes were discarded
and regenerated with `zorg build test-run-hashes`, never hand-merged. Master’s
new budget contract supersedes the CPU fallback used by the earlier gate runs
in §6: on this aarch64 macOS host `zorg build gates` now deliberately refuses.
The prescribed local validation is `zorg build test test-blackbox fmt-check
beni-fmt-check`, also run with `-Dllvm`. The hardware instruction-budget gate
remains owed on a suitable x86-64 Linux host. CI’s no-budget test job does not
substitute for that gate. No rule or limit is changed to avoid the refusal.

Claude’s review found no blocking defect and requested targeted probes.
`TemplateControlLists` adds a formal first receiving a closed literal and then
a model path, plus a helper consuming a conditional choice between distinct
list paths. `TemplateMaybe` switches a held Maybe Html slot between a runtime
text value, a template and Nothing. `TemplateClockRows` exercises a clock
argument inside a helper-owned For. This last probe found a shared compiler
bug: the ordinary DOM lowering had no every-render facts for ungrouped markup
rows, so tea’s clock stayed stale while direct’s advanced. Those facts are now
computed independently of grouped template eligibility; tea is not opted into
the parameterised protocol. The paired transcript and value fuzz pass after
the fix. Backend.md records the rule. Missing dispatch metadata is also
conservatively volatile, with an assertion for checked application call sites.

The review’s remaining points are confirmed or clarified: only the two
`anchorPath*` readers expand deferred control bases, after their early opaque
root checks; hole/let accumulation resolves them at finish. Function term
identity includes its body and captures. `templateMapPatch` restores row state
even if scope publication throws. Global `send` queues reentrant sends across
all programs, and every queued handler begins a fresh group epoch; existing
RenderedSends/RenderedWaiterCancelled cases exercise this. Rt.childList skips
identical pure blocks, so the direct prepass enters them once; that is now
commented. The corruption tests intentionally pin development emitter shapes.

“Independent” means independent of the emitted execution selection, not of
Writes’ analysis. The visit oracle shares those masks and cannot catch an
analysis omission by itself; paired DOM/value fuzz is the separate backstop.
It checks group entry granularity, not whether every instruction inside a
selected group is minimal. Source-order preparation and conservative read-set
unions can do more work without an extra group entry. Raw timing spreads must
be read alongside medians; overlapping sub-millisecond samples do not prove a
statistically significant regression from the median difference alone.

Final post-rebase artifacts use the `2026-10-15-rebased-*` prefix, retaining
the original batch as well. S0 now enumerates 102 programs because master added
fixtures; Conduit's 782/114 leaf facts, bounded counts, value roots and 9/62
star dispatches are unchanged. The empty floor remains 327 B. The final source
includes the shared row-fact repair and row-state cleanup; it does not contain
a timing/size optimisation tuned after either measurement batch.
