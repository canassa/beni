## 2026-10-15 15:00 CEST — deferred field reads

### What I did

Read CLAUDE.md, research 96 and the checker contract before continuing issue
#131 after #135. Kept the work in a separate worktree and used zorg.

Bare dots now delay their method arrow and wanted until dispatch needs them.
Unknown receivers retain a compact obligation and the original owner-rank
boundary default. Reserved effect-site positions preserve call order; inert
sentinels are ignored by effect solving and planning. Resolution still preserves
sequence slots, budget charges, rejected/cyclic cases and recursive provenance.

Owned walks enumerate live dependants directly. Rank adjustment treats escaped,
non-generalised flex/rigid roots as settled outer nodes: attachment and strict
rank drops already enforce I15, and their owning boundary still walks them.
Direct record reads into a plain flex avoid a temporary record only when the
existing field is a dependency-free leaf. Aliases retain ordinary record
unification, including its diagnostic spelling.

Added TaskBoard to bench/corpus with unannotated map/filter callbacks. Added a
black-box performance scenario doubling the pending reads on one receiver. On
current master the actual ReleaseFast test fails, 140/536 ms CPU, ratio 3.82;
on this tree it passes, 7/9 ms, ratio 1.28.

### What I learned

Removing eager method objects alone left repeated owned walks expensive.
Escaped receiver closures are already below the nested boundary's young rank;
revisiting them contributes no quantification information. Native profiles
confirmed that the remaining ordinary field unification was then significant.

A field shortcut must retain alias expansion side effects: the corpus caught
three diagnostic spelling differences in an initial version. The accepted
version restricts the shortcut to direct records; no golden was changed.

Full self-hosted `zorg build test test-blackbox fmt-check beni-fmt-check` passes.
The two filesystem-sensitive scenarios used a case-sensitive APFS temporary
volume, then the ordinary cache directory was restored. LLVM unit, corpus,
ordering, determinism and formatting checks also pass. All 118 direct before/
after dump comparisons match. The recorded 467 development, 467 release and
1,469 browser output hashes remain identical. The Linux instruction-budget
gate is still owed; this host cannot count it. Final three-way LLVM ReleaseSafe
medians and native profile details follow in the benchmark report.
