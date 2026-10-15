## 2026-10-15 13:10 CEST — Known record reads without deferred rows

**What I did**

Read CLAUDE.md, research 96 and the checker/dispatch contracts for issue #131.
Profiled a retained replacement for the missing original field-dense generator
before editing. Added a solver fast path for already-proved record receivers
outside recursive frames, sharing the existing field unification and preserving
rejection flags, sequence slots and resolution-budget charges. Unknown receivers
and recursive provenance retain the full wanted/obligation path.

Retained the 63,000-line generator, interleaved measurement script and individual
samples in bench/. On an Apple M2 Pro with zorg 0.17.1+zorg.1 ReleaseFast,
checking is 44.69 → 41.36 ms (−7.5%), solving 30.48 → 27.15 ms (−10.9%). The
100,082-line generated corpus is effectively unchanged: checking 43.27 → 42.60 ms,
whole process 277.92 → 281.48 ms. Both binaries measure the same generated input
after the existing name migration removes stale modBy spellings.

zorg build test test-blackbox fmt-check beni-fmt-check passed on the final
source. Two case-sensitive output-cleanup tests fail on the default Mac volume,
including with the baseline binary; the full command passed with temporary test
directories on a case-sensitive APFS image. Restored the original temporary
directory and detached that image afterwards. All 467 development and 467 release
run hashes, and browser hashes, stayed current. Ordering and determinism tests
passed; 114 direct before/after dump commands had identical streams and exits.
The instruction-budget gate remains owed on x86-64 Linux.

Opened PR #135 and posted @claude review. The automatic review passed, and the
requested review found no blockers, with suggestions about sequence accounting,
fallback documentation, a budget-edge case and this diary. Verified that
Resolve.create and Obligations.create each increment the sequence once;
the guarded step-budget fallback preserves the existing diagnostic path. No
million-step corpus case was added merely to exercise that branch. The PR stays
unmerged. Moved this work to an isolated worktree after another session switched
the shared checkout's branch; restored that other branch and preserved its work.

**What I learned**

A known record can bypass evidence storage without changing any field constraint,
but recursive rows also serve diagnostic provenance and must stay. Current-epoch
cycle proofs and rejection flags are part of resolution, including for fields
named eq or compare. The profile includes substantial necessary record
unification, so removing deferred rows recovers only part of the measured cost.
The old 41% figure cannot be reproduced exactly without its machine and generator.
The benchmark generator's removed names need a separate maintenance fix; measuring
its unmodified diagnostics would benchmark an error path.
