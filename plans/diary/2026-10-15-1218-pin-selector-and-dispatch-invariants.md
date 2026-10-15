## 2026-10-15 12:18 CEST — Pin selector and dispatch invariants

**What I did**

Answered every point in the sharing review on PR #98. Added safety assertions
for one handler per analysis key and the computed-root selector's program-only
scope, documented emission order and inline eligibility, and added paired/fuzz
RootSelectorDerived. Its derived scrutinee and label cover current values when
staying in an arm and leaving/returning to it. Proved from keyTree's depth-first
construction why interleaved prefixes and a root catch-all in the middle cannot
be generated. Model destructuring is bound before specialisation; branch guards
are not in the language.

Master advanced while profiling. Rebased again onto 2f397d7b6, retaining both
conflicting write-set amendments and every diary entry. Re-recorded hashes with
zorg. Final native and LLVM unfiltered test/blackbox/format runs each pass 1,315,
skip 15 and fail only the two known macOS case-folding cases. Full direct Chrome
passes, as does the new case's hash replay. The hardware-budget gate remains owed.

Compared the final compiler's served Conduit tea/direct release bundles and all
57 direct sweep programs byte-for-byte against the profiled versions: all match.
A fresh S0 run is identical too. Archived those comparisons and validation in
research 97's dataset. Pushing the resolved rebase and requesting review of the
follow-up; this remains draft and must not merge.

**What I learned**

The computed-root path has no cached derived slots: leading view lets run inside
the shared selector, whose only outside view binding is the program's current
model. The stronger assertions leave emitted JavaScript unchanged. New upstream
ownership, nullary-method, edge/print and release-map work does not change any
of the measured programs, so the recorded timing/byte evidence still applies.
