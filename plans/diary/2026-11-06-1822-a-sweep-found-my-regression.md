## 2026-11-06 18:22 CET — a sweep found my regression

**What I did.** Took the review of #2156. Fixed the new miscompile, added the keep edge's callback write
and closure rules, left open records, and moved the PR to `Part of` with the rest in #.

**What I learned.** Corrections to my entry of earlier today. "Over 2018 roots no verdict moved" was true
and missed the point: the corpus has no program that shows the regression, and a generator did. My
reasoning that the probe was only made stricter was false, because master's probe failed on a value with
no record at its root, and I had made it succeed. The bar for a soundness change must be a
differential sweep, not the corpus. Three sweeps now give 0 refused-to-wrong and wrong counts of 913 → 120,
495 → 55 and 566 → 551. The last family, records the callee makes, is untouched. The guard is not
observable alone once the callback rule is in, and I kept it for the property; the PR says so. I also
claimed a `node` handler cost I had only inferred from a summary, which the review disproved. The review's
claim that edit 1 has no effect did not reproduce here.
