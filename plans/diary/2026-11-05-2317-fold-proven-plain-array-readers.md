## 2026-11-05 23:17 CET — Fold proven plain-array readers

**What I did**

Reused existing closed-array facts to remove generated List base/offset dispatch
on proven single-root pages. Kept the fold loop, lookup, defect checks and
lifecycle. Added both follow-up guards from #2026: literal-tag validation for
array lengths and field-identity matching for producer layout facts, with
red/green witnesses. Part of #1861.

**What I learned**

Reader folding saves 37 B brotli on empty and sandbox, 34 B on the synthetic
static paragraph probe, and 16 B on element. Multi-program stays unchanged.
The existing scalar lattice merges the counter's entry and backedge values;
it cannot prove the remaining traversal runs once. The owner chose the small
win and deferred a new loop analysis as disproportionate to the bytes left.
