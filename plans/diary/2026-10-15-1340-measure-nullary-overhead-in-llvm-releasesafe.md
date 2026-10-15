## 2026-10-15 13:40 CEST — Measure nullary overhead in LLVM ReleaseSafe

**What I did**

For the follow-up on PR #135, built three isolated LLVM ReleaseSafe compilers
with zorg: pre-#126 134d24ab9, current master 2ca55a928, and PR 310fd7887.
Verbose commands confirm -fllvm -fstrip -Osafe. On this Apple M2 Pro, measured
the same input paths in twelve triples, covering every compiler order twice
after warm-up. The runner asserts identical stdout, stderr and successful exits.
Added an unannotated mode to the retained field generator and retained all
samples, input hashes, recovery arithmetic, counter instrumentation and profile
summaries. Compiler sources in the PR are unchanged.

Known-record checking: 50.44 → 76.03 → 65.21 ms, so the PR removes 42.3% of
the added cost but remains 29.3% above pre-#126. Unannotated checking:
49.38 → 153.05 → 152.95 ms, essentially no recovery. The generated 100k corpus:
68.32 → 70.85 → 70.18 ms, too small and noisy a delta for a precise recovery
claim. All three LLVM builds also passed beni-fmt-check; fmt-check passes.

Collected branch counts with a separate, untimed self-hosted ReleaseSafe build:
59,000/60,000 annotated reads take the fast path; all 60,000 unannotated reads
start flexible and retain both rows. Native LLVM ReleaseSafe profiling, with
debug symbols retained separately, puts 55.4% of unannotated checker samples in
rank adjustment, including 22.7% in its safety invariant check. Updated the
benchmark report and research 96 to distinguish these findings from the prior
two-way ReleaseFast numbers, and to identify further optimisation candidates.

**What I learned**

The main unannotated cost is repeatedly traversing deferred dependencies across
local-binding boundaries, not just allocating the rows. The known-record path
still pays for generated method arrows and effect edges: effects remain
0.99 → 4.15 ms. There is room to delay those objects, materialise method wanteds
only when needed, and improve dependency iteration. Unknown receivers must
still defer and default at the existing boundary; disabling safety checks or
eagerly assuming a record would not preserve the accepted contract. These are
follow-up candidates, not improvements implemented or proven by this session.
