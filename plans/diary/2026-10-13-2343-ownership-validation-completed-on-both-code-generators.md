## 2026-10-13 23:43 CEST — ownership validation completed on both code generators

**What I did**

Completed unfiltered zorg build gates and zorg build gates -Dllvm. Each has exactly
the four owner-acknowledged macOS failures, with 1 292 tests passing and 15 skipped;
no additional failure appeared. The case-folding and CPU-budget tests are unchanged.
The pending suite passes with the resolved cases promoted. Existing ownership
goldens and runtime transcripts remain unchanged; refreshed browser-tea development
and differential hashes include its changed source map. Prepared the PR with the
per-case classification, explicit borrow-preserving copy, soundness arguments and
before/after evidence. S5's work stays on browser-direct-s5.

**What I learned**

The exception the owner supplied permits this PR while preserving the four known
Mac failures. Both code generators agree on the new acceptances and the rejected
sharing twins; the whole copied driver can now be checked for the direct platform.
