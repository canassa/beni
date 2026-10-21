## 2026-10-21 12:22 CEST — The points-to runs reuse their memory

**What I did.** Issue #574, cause 2 of `plans/build-profile-2026-10-21.md` (added here). Fact 3's
six runs now share one run arena (`Pts.tmp`, the repository's own `src/Arena.zig`), emptied with
a new reset mode, `keep_all`: it frees no chunk and opens them again in the order the last run
opened them. The per-node and per-name columns, the vars, sites, locals and statements moved
there from the compilation's arena, and so did `Spec`'s arrays of one analysis. The safety
build's reference run keeps its own arena. `inlineOne`, `fuseOne` and `inlineScan` keep their
per-name scratch across calls. Every output is byte for byte the same, and the run hashes did not
move. Against master with #575, N = 64 went from 56.3k to 31.1k faults, 180 to 115 MB, sys
0.08 to 0.04 s and wall 0.33 to 0.29 s. The 100k library build went from 348 to 273 MB. The table is in `backend.md` §9 *Memory*.

**What I learned.**

- Zig 0.17's `ArenaAllocator.reset(.retain_capacity)` frees every node but the last and then
  resizes or reallocates that one, so it does not keep pages mapped.
- Which spare chunk a run fills first matters. Filling the largest first sent N = 64's run 6 into
  the new 38 MB chunk that run 5 had only half touched: 6.8k faults with no growth. Reopening the
  chunks in the order they were first opened makes a run that repeats the last one fault almost
  nothing (run 3: 115 faults).
- About half of run 1's 38 MB is lists that grew in a bump arena and left their old copies
  behind. What remains between the runs is `Spec`'s own caches (`nameScan`, `preorder`,
  `inlineSmall`'s copies) in the compilation's arena.
- `perf record --call-graph dwarf` gave no stacks on the ReleaseFast compiler. A frame-pointer
  build (`.omit_frame_pointer = false`, as `beni-prof2fp` does) did.
- dagon's load went from 3 to 29 during the session, and it tripled the times. Faults and RSS did
  not move with it. The times reported are interleaved minima.
- #575 landed while this was in review: an analysis may now keep fact 3 and skip its solve.
  Its safety check, `checkKept`, swaps `tmp` for a fresh arena as the reference run does. With
  every run's state now in `tmp`, that swap saves the kept state whole.
- Every gates log on dagon prints a `failed command` line for `docs_test`, even when the gate
  passes. It is that test's informational stderr, not a failure.
