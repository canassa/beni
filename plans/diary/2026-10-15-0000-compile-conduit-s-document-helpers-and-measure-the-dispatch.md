## 2026-10-15 00:00 CEST — compile Conduit's document helpers and measure the dispatch miss

**What I did**

Rebased draft PR #98's browser-direct-s6 onto current origin/master, preserving
every diary entry and the workspace's existing review document. Specified
document choices before implementing interface 1.12: one complete helper
result for body/title, a common value slot retaining markup-kind identity,
and arm statements evaluated with the value. Promoted Reader, Editor and Tour
with original external sources/scripts, one normalized golden per paired case
and separate value fuzz. Added local, branch and imported-helper regressions;
observed the old lowering refusal and the intermediate focus-fuzz failure.
Native paired runs and helper Chrome runs pass. Conduit Chrome transcripts
match; Editor/Tour Chrome value fuzz hit the existing navigation-driver failure
tracked by PR #103. Re-recorded every run hash through zorg, with only the two
known case-folding failures in that recording step.

Measured S0 again, actual handler/group visits, the empty floor, whole Conduit
bytes and three Chrome operations on clean output. Criterion 7 fires: Internal
has no writes but enters 5–24 group guards through the document value path.
Actual patchAll is exactly 9/62. Direct release is 32,411 B brotli versus
31,389; untraced feed/favorite/editor medians are 0.465/0.435/0.480 ms versus
0.370/0.305/0.420, with traced orderings agreeing. Research 94 retains all raw
evidence and the stop; the second full adversarial campaign remains owed.

Corrected lost instruction-budget provenance in the CPU fallback. The owner
then explicitly granted 15,300M for the three paired page cases and separate
4,900M Reader/Editor fuzz grants; Tour fuzz keeps 4,300M. Fresh Node comparisons
fit, and removing only the explicit fuzz grant fails only that case under a
profiling budget. Cache-pruning tests now use 1,025 files, the smallest input
past the 1,024 threshold, retaining the deletion/age assertions and fitting
the budget. Preparing the final gate and Claude review; no merge.

**What I learned**

Compiling the view in place does not make helper-valued markup selective. Its
value-kind patches still enter groups that the anchored analysis excludes;
the zero-write Internal key gives a direct falsification without conflating
value-kind guard templates and analysis groups. Sharing complete documents
keeps effects and titles consistent, but this lowering does not deliver the
shared-site visit protocol its size and dispatch prediction assumed. A CPU
fallback must retain the instruction scale even when it skips opening a PMU.
