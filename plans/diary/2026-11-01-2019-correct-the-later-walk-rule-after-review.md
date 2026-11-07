## 2026-11-01 20:19 CET — Correct the later-walk rule after review

**What I did.** I answered #1587's review in the design note:
- Part 2's carry-once lemma is withdrawn. Its counterexample is a node with no entry, which reads `lost`. The rule now carries once only onto a node no other arm reaches.
- Part 3 is off unless `-Downership-full-cross-check` is set. Its checks run on scratch tables (#1589).
- The cost bound now says "if part 3 holds" and gives the measured n^2.8.
- The arm quotient is a new question (#1590). It is not §2.3 question (b), which is decided.
- The pointwise-join claim is marked as a conjecture.
- The WriteOneLevel block change comes from part 1 alone. Its golden drift is #1591.

**What I learned.** The 864 arm tests that "passed" were all GroupFieldShift's, and none had the counterexample's shape. A cross-check over one family is no evidence for a lemma. The κ read's `lost` default for a built node with no entry breaks every "absorbed by the join" argument.
