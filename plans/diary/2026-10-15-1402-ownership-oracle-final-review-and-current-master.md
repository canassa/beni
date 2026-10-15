# 2026-10-15 14:02 — Finish the oracle reviews against current master

A further explicit review found a shadowed `tail` boolean in the Chain-case
translator. Renamed the generated binder to `tailVar` and added real-compiler
regressions for both End and Link arms containing an intermediate Result case.
The old translator returns Err 7 instead of continuing to Ok 99; the restored
selftest passes both cases. Before/after logs are retained. The reviewer then
found no new correctness issue and requested only an eligibility clarification.

Clarified `privateToInit`: eligibility removes publication sharing; it does not
upgrade exclusivity or bound capture reads. Ordinary Dead/separation/summary
checks still apply. The duplicated captured-local initializer is actually
rejected by Dead in the retained fixture log; its copied twin passes. Answered
all review notes, including the optional combined-test suggestion, with pointers
to existing repeated-capture writes and explicit limits on what was added.

Master moved and #116 merged while the round ran. Merged 1ed777195 into this
branch, resolving one gap-list conflict without restoring the now-modelled
initialization gap. Hidden evidence, suspension and coarsened foreign summaries
remain explicit boundaries. No shipping compiler policy is changed by this PR.
The combined macOS checks have 1,329 passed, 15 skipped and the same two known
case-folding failures. The hardware-budget gate remains owed on supported Linux.

Reran both complete campaigns against one frozen ReleaseSafe compiler built
from 1ed777195. CI: 960 inputs, 467 translated, 6 forward / 8 reverse / 0 unsafe.
Long: 116,650 inputs, 43,185 translated, 1,725 forward / 401 reverse / 0 unsafe.
Seed forward counts remain 491 / 470 / 470. Both original-program audits agree
on all forward traces, replay all 401 historical reverse refusals with identical
details and pin the full original 490 fixed programs by source/verdict/table hash.
All retained evidence bundles, source hashes and interpreter judgments verify.
Initialization remains Lean-only, with entry/private-root bridge cases skipped.

The clean-checkout source/kernel audit of dac480495 (requested as HEAD while
that commit was checked out) passes: 32 files, 4,720 constants replayed, exactly
the existing three unproved statements and no swapped attributes. The comment
is the only Lean-source change after c6e206fef's full CI run. Updated evidence,
report, compiler/source provenance and review regression logs are retained in
proofs/ownership/evidence/oracle-extension/. The earlier pre-merge campaign is
also retained in git history at 813d6bbca, with identical lead counts.

PR #132 remains open and mergeable, with the explicit reviews and answers on
GitHub. Hosted CI is running on the synchronized tree; nothing was merged.
