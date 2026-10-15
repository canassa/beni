# 2026-10-15 13:50 — Keep Result cases in their frame and pin old fixture identity

The follow-up explicit review on PR #132 found a genuine translator bug: a
canonical-shaped Result case in a let RHS became `?`, returning Err 7 from
the definition instead of continuing to Ok 99. Added a real-compiler bridge
regression, proved it fails before the tail-context guard and passes restored,
and retained both logs. Tail context now follows cases and branches, stops at
a binding RHS, and starts fresh in each callback definition.

The historical fixed population is now checked by full source/verdict and
declaration-table bytes, reconstructing its original table ids and pinning
all 490 programs to SHA-256 27c16813417690b56c0968697dd32017542fc5c352ce0c8fcab050fe8b580c3a.
Source edits, verdict flips, reordering and omissions are caught independently.
Added the requested captured-local getter fixture: duplicating its list across
two result fields is refused; its distinct-copy twin passes. Initialization
controls remain explicitly Lean-only and their bridge projections are skips.

Final committed implementation c6e206fef passes 176 verdict fixtures, 508
targeted programs (192 accepted), and all 23 required targeted controls,
including the twelve new holes. The in-build audit replays 3,258 constants;
a clean-checkout source/kernel audit passes all 32 sources and 4,720 constants,
with the existing three unproved statements and no swapped attributes.

Fresh bridge: CI 960 inputs, 467 translated, 6 forward / 8 reverse / 0 confirmed
unsafe. Long: 116,650 inputs, 43,185 translated, 1,725 forward / 401 reverse /
0 confirmed unsafe. Seed forward counts are 491 / 470 / 470 for 17 / 20261011 /
314159. Every original forward trace agrees in both interpreters, all 401
historical reverse refusals and details are unchanged, and both audits pin the
historical fixed prefix. The appended 194 fixed programs add 119 translated
agreements and 75 counted skips. Reports and compressed replay evidence are
under proofs/ownership/evidence/oracle-extension/.

Answered all four review findings on PR #132. Request another explicit review
of the final source and evidence after this push. The PR stays open, unmerged.
No shipping compiler source changed. The macOS constituent result remains
1,302 passed, 15 skipped, with two documented case-folding failures; the exact
hardware-budget gate is owed on supported x86-64 Linux. Earlier hosted tests
without the budget passed.
