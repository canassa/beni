# Result, recursive payload and initialization oracle — 2026-10-15

The Lean core now models typed Result constructors and elimination, a CPS
lowering of `?` scoped to its definition, the unbounded recursive type
`Chain a = End | Link a (Chain a)`, and private initialization transfer with
retained entry environments. The six §29 rules from PR #124 already had
corresponding protections in the checker; each now has its own required hole.
PR #116's initialization condition is projected in the Lean core. The final
bridge uses the frozen compiler at `1ed777195`, including #116 after it merged
while this round was running. This PR changes no shipping compiler policy.

There are **176 verdict fixtures** (98 original + 78 sync), **508 targeted
programs**, and **twelve new required holes**. Historical fixture/targeted ids
are unchanged; 34 verdict fixtures and 160 targeted programs append. The new
recursive Result fixture exercises optimistic bottom propagation before the
base arm is discovered. An additional initialization regression prevents a
subsequent module entry from reusing a spent private-transfer permission to clear
a later permanent publication. A callee cannot borrow the pending permission
while solving or reusing its summary, even at a colliding relative allocation site.

## Planted holes

Every fixed witness is well typed, refused by the corrected checker, accepted
under its hole, and disagrees between the value and in-place interpreters.
The independent finite targeted product must catch every hole too; an error
or a rejection does not count. Its corrected run accepted 192 of 508 programs,
with zero disagreements, execution errors or invalid result certificates.

| Hole | Newly accepted targeted programs | Interpreter disagreements |
|---|---:|---:|
| `arm-result` | 8 | 7 |
| `block-result` | 4 | 4 |
| `capture-read` | 4 | 4 |
| `fold-loan` | 4 | 4 |
| `recursive-capture` | 4 | 4 |
| `callee-capture` | 4 | 4 |
| `early-err` | 8 | 8 |
| `recursive-payload` | 12 | 12 |
| `init-shared` | 16 | 12 |
| `init-retained` | 8 | 8 |
| `init-authority` | 4 | 4 |
| `init-frame` | 4 | 4 |

One changed `arm-result` verdict agrees on its particular executed condition;
four `init-shared` verdicts also agree (the function-source backstop). None of
those agreeing executions counts as a control catch. All twelve controls have actual disagreements,
with zero inconclusive executions. The table counts newly accepted programs,
not every verdict a deliberately damaged liveness analysis can change.
[Control counters](evidence/oracle-extension/controls.json),
[replayable fixed cores and both interpreter outcomes](evidence/oracle-extension/hole-witnesses.jsonl.gz),
and the [complete CI log](evidence/oracle-extension/ci.log.gz) retain the evidence.
The ten earlier required targeted holes and the existing `branch-live` witness
also pass: all 23 targeted controls are caught.

## Shipping bridge

| Campaign | Inputs | Translated / value-checked | Skipped | Zig accepts / Lean refuses | Zig refuses / Lean accepts | Confirmed unsafe originals |
|---|---:|---:|---:|---:|---:|---:|
| CI bound | 960 | 467 | 493 | **6** | **8** | **0** |
| Bound 2 + three seeds × 20,000 | 116,650 | 43,185 | 73,465 | **1,725** | **401** | **0** |

| Full stream | Inputs | Translated | Forward leads | Reverse leads | Confirmed unsafe |
|---|---:|---:|---:|---:|---:|
| Fixtures / sync / targeted | 684 | 343 | 0 | 6 | 0 |
| Bound-2 enumeration | 55,966 | 27,769 | 294 | 267 | 0 |
| Seed 17 | 20,000 | 5,006 | 491 | 37 | 0 |
| Seed 20261011 | 20,000 | 5,054 | 470 | 43 | 0 |
| Seed 314159 | 20,000 | 5,013 | 470 | 48 | 0 |

Compared with the post-#124 campaign, the forward and reverse counts are
unchanged. The expanded fixed set contributes **119 new translated agreements**
and **75 counted skips**, with no additional whole-program lead in either
direction. All historical enumeration and generator stream SHA-256 hashes and
input/translation/skip/value-check counts match exactly; the fixed stream
changes only by the appended examples. Both audits also pin the full original
490-program fixed prefix, including source, declaration tables and verdicts,
to SHA-256 `27c16813417690b56c0968697dd32017542fc5c352ce0c8fcab050fe8b580c3a`.
Negative controls change a source, flip a verdict, reorder or omit a row; each
is rejected by that check. Total full-run agreements rise from
40,940 to **41,059**.

Every remaining original forward lead was judged with both Lean interpreters,
comparing the complete final value, reads and external-reader observations.
**All 1,725 agree.** *Qualified 2026-10-15 (the oracle review, F7):* only
351 of them write a list when run in place (the review counted 375 containing a
writer; the rest are mostly model limits, which write nothing and cannot
diverge), so the meaningful statement is that all 351 write-bearing leads agree.
`CONSTRUCTIONS-RESULTS.md` reports both counts for later campaigns. All six old defect-cluster membership sets have zero
surviving accepted originals. A replay of all **401 historical reverse sources**
still refuses each, with **zero changed refusal details**. The judge checks
original source fidelity and frozen compiler hashes; no historical minimum
classifies an original. The optional persistent-runtime minimizer was disabled
for these evidence runs; ordinary `ownership ci` also passed its default bridge.

The bridge emits actual beni `?` for the canonical question lowering in
definition-tail position, ordinary cases for bound intermediate results, and a
native recursive Chain ADT. Their normalized final values match the oracle.
Entry/private-root projections remain counted skips because the bridge has no
runtime entry-delivery model. Initialization controls are Lean-only; the zero
confirmed count applies to the translated common subset. The emitted direct
library still uses persistent lists; its execution is not the in-place judge. Agreeing finite traces are
precision evidence on these inputs, not proofs of global safety.

[CI report](evidence/oracle-extension/ci/report.json) and
[original-program audit](evidence/oracle-extension/ci/audit.json);
[full report](evidence/oracle-extension/long/report.json) and
[original-program audit](evidence/oracle-extension/long/audit.json).
Compressed sources, verdict evidence and complete interpreter judgments are
retained beside each report.

## Review follow-up

The explicit review found that a syntactically unique read in a traversal body
could qualify for transfer. The duplicated-model scenario was already refused
by separation checking (`container contents: positions may share`); private
publication removal never upgrades a certificate. The source-read eligibility
contract nevertheless needed its direct-initializer boundary enforced. Free
reads in traversal, focus and runtime-entry bodies, and recursive initializer
reads, now stay ineligible. A direct source operand still counts once. Both
new policy guards fail with the read-count fix set aside and pass restored.
The repeated-payload initializer rejects; reading the shared source to allocate
fresh payloads passes. Explicit capture atoms are eager in this core; deferred
global references are not represented as eager captures.

Function-bearing private initializers also remain shared under #116's explicit
backstop. Its refusal fixture fails with that guard set aside; a copied returned
spine passes. Pending transfer authority belongs only to the module-initializer
context: callees and runtime-entry bodies cannot borrow it. The new `init-frame`
hole admits four actual interpreter disagreements if that boundary is removed.
Finally, the liveness controls now propagate through Result cases, Chain cases
and entry expressions. Shadowing is already rejected before the corrected walk.

The before-fix probes, source-rule-removal failures and restored fixture log are
retained in `evidence/oracle-extension/review-*.log.gz`. The review response is
on [PR #132](https://github.com/canassa/beni/pull/132#issuecomment-6190721943).

The follow-up review found a genuine bridge bug: an intermediate bound Result
case matching the question shape was emitted as `?`, so `Err 7` escaped the
definition instead of allowing its continuation to return `Ok 99`. The retained
compiler regression fails before the tail-context guard and passes after it.
Case/branch arms inherit their context; a let RHS is non-tail and a callback
starts its own definition frame. `review-tail-*.log.gz` retains both executions.

That review also requested source-level fixed-prefix pinning and an initialization
closure fixture. The prefix check and its four negative controls are described
above. An initializer calling a local getter and putting its captured list into
both result fields is refused (`Dead`); the distinct-copy twin is accepted.
Both are fixed verdict fixtures and targeted products. The
[follow-up response](https://github.com/canassa/beni/pull/132#issuecomment-6191335011)
answers all four findings.

A further review found that the Chain tail binder shadowed the boolean tail
context. It is now `tailVar`. Two real-compiler regressions cover a bound
Chain case with a forwarding Result case inside either constructor arm; the
before-fix run returns `Err 7`, while both restored regressions return `Ok 99`.
The `review-chain-tail-*.log.gz` artifacts retain those executions. The later `privateToInit` comment explicitly separates eligibility from the
Dead/separation obligations; no Lean behavior changed. The bridge correction is
`a85abcabf`. The [review response](https://github.com/canassa/beni/pull/132#issuecomment-6191446217)
answers the finding. The [last review and reply](https://github.com/canassa/beni/pull/132#issuecomment-6191498075)
record no new correctness defect and the clarification that the duplicated
capture fixture is rejected by Dead, while the copy twin passes.

## Validation and boundaries

`lake build` passes: 3,258 constants replayed through the kernel, no swapped
compiler attributes, and exactly the existing three unproved statements. The
independent `scripts/audit.sh` over committed `dac480495` also passes: all
32 sources parsed, 4,720 constants replayed module by module, only the four
pinned constants dependent on the three existing unproved statements, no
swapped attributes and no build-time source changes.
`ownership ci 20000 17` passes all 176 verdict fixtures, the v5 campaign
(2,911 accepted, 1,815 writing in place, zero disagreements), every required
control, all 55,966 bound-2 programs (31,680 accepted, 10,468 writing, zero
disagreements), all 508 targeted programs and the bounded shipping bridge.
Expected observations independently pin inner/outer question frames, recursive
Result errors, successful questions and the recursive Chain consumer.

`zorg build test test-blackbox fmt-check beni-fmt-check -j4` completed with
**1,329 passed, 15 skipped and only the two documented macOS case-folding
failures** on the combined tree after updating to master. The earlier compiler
check had 1,302 passed, 15 skipped and the same two failures. Exact
`zorg build gates` refuses this Apple Silicon host because
it cannot count reference x86-64 Linux instructions. The hardware-budget gate
remains owed on a supported Linux host; no budget or exemption changed.

This is a core model. Arbitrary named/mutually recursive type declarations,
dictionary representatives, opaque/wildcard compiler encodings, effects,
rendering and unbounded event delivery remain explicit boundaries. The gap
list in ownership-checker.md §26.7 removes the newly modelled rules and retains
those residual boundaries. Private-read proofs deliberately support a narrow
single-read allocation/alias/capture chain; unsupported graphs stay shared.
The three soundness statements remain unproved.

## Reproduce

Inside `nix develop .#ownership`, with `LEAN_NUM_THREADS=8`:

```sh
zorg build test test-blackbox fmt-check beni-fmt-check -j4
cp zig-out/safe/bin/beni zig-out/ownership-oracle-current-beni
cd proofs/ownership
lake build
lake build triage
lake exe ownership ci 20000 17
lake exe ownership enumerate-targeted --mutant=init-authority
# Use fresh, separate output directories for each campaign.
node scripts/bridge.mjs --ci --no-build --no-minimize \
  --compiler=../../zig-out/ownership-oracle-current-beni --out=../../zig-out/ownership-oracle-current-ci --jobs=8
node scripts/bridge-fix-audit.mjs ../../zig-out/ownership-oracle-current-ci \
  ../../zig-out/ownership-oracle-current-beni ../../zig-out/ownership-oracle-current-audit-ci
node scripts/bridge.mjs --long --no-build --no-minimize \
  --compiler=../../zig-out/ownership-oracle-current-beni --out=../../zig-out/ownership-oracle-current-long --jobs=8
node scripts/bridge-fix-audit.mjs ../../zig-out/ownership-oracle-current-long \
  ../../zig-out/ownership-oracle-current-beni ../../zig-out/ownership-oracle-current-audit-long
```

Both final campaigns use the same frozen ReleaseSafe compiler from the
combined-tree test steps, shipping source `1ed777195`. Exact compiler/oracle
hashes are in the reports. The earlier pre-merge pairing at `bcf28a6ee` also
had the same lead and zero-confirmed counts (retained in commit `813d6bbca`).
The evidence README records artifact replay commands and the independent audit.
