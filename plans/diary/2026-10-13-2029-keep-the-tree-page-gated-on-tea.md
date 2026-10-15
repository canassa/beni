## 2026-10-13 20:29 CEST — Keep the tree page gated on tea

**What I did.** Moved the direct ValuePath page into `tests/pending/`, where the pending walker pins `dev: exit=1 codes=list_may_be_shared×1`. Kept the same source and steps as a gated browser-tea page, with its own transcript and run hash. Added the missing direct Blocks fixture, fixed ControlledOptions' unsafe in-place edit with `List.copy`, and recorded hashes with zorg. Benchmarks were skipped as requested.

**What I learned.** The pending page harness needed JSON diagnostics and a build-failure signature to distinguish this checker limit from another refusal. The unfiltered macOS gate had four failures: two existing case-folding tests and two browser-driver cases over the 999 ms CPU fallback budget; the corpus and formatting checks passed. The user explicitly asked to leave the case-folding failures alone and commit this work.
