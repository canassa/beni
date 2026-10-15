## 2026-10-15 01:39 CEST — clarify the rendering report after review

**What I did.** Answered Claude's report review by fixing the part-table
separator, stating that ratios use raw medians and that the whole-core
leave-one-out delta is authoritative, and aligning the tea rounding. Moved
sampling and native-work limits into the answer; the derived elapsed cost
rises 23%, which remains unexplained, rather than establishing flatness.
Recorded delivered profile resolution and sparse function hit counts.
Verified malformed and unmapped byte maps fail loudly, and all supported
P2/P3 generators are functions. No comparison timing or target changed.

**What I learned.** A requested 25 µs sampling period delivered 78 µs at
the median. Live's guard was hit once across twenty profiles, so its
weighted per-page average cannot be presented as a function cost. Static
counts prove extra emitted depth work, not its precise elapsed share. The
measured target misses survive these narrower, more honest claims.
