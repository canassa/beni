## 2026-10-14 10:42 CEST — direct effects review boundaries

**What I did**

Opened draft PR #89 and requested review despite its negative size result.
The review found no definite correctness bug and raised seven boundary checks.
Verified checkbox activation in headless Chrome; added a paired, value-fuzzed
subscription whose let-bound model capture is absent from the view. Answered
state re-entry, evidence-cache restoration, dispatch paths, teardown and the
shared rendered hook against their implementations and fixtures.

**What I learned**

A subscription can need a new tagger while no DOM group needs a write. The new
fixture keeps that distinction observable. Restoring a statement-list pointer
alone cannot restore its evidence cache. The negative routing size result
remains the design's stop condition after review.
