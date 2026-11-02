## 2026-11-02 16:55 CET — Slot domain: no accepted→refused, keys below a prefix (#1685)

**What I did.** Continued branch `own2-slot-domain`.

- **Zero accepted→refused against master's v2** (2 158 roots, per position: 2 543 same, 0 accepted→refused, 90
  refused→accepted, the same 90 as before). `CastCallHolds` 25:9: an unstepped cast read back at its inner's
  own place is the inner (§2.13.9), so `deepGeneric` writes only `π1ε`. `List.unzipHelp`: a distinct check
  that asks some of a call's slots only to be apart now asks apart the callee's occurrences that reach no
  plain slot; the builders no longer ask the pairs' elements to be pairwise distinct.
- **Summary size, partly.** A whole subtree of a call's or a supply's result is read through one key below its
  position (`instBelow`), an open entry whose arrival projects to the same atoms at every slot (`⊤`, shared,
  a pessimistic or cast callee's `⊤`) is one open entry, and a leaf's parameter effects are said once.
  `Schema.madeNode` went from past the limit to 21 470 records, growth 0. `shapeOf` and `shapesOf` are still
  past it (about 125 000 growth with a raised limit): their results are fresh lists at ~190 slots of `Shape`,
  and the per-slot keys of the effect and supply consumers dominate. Not solved.
- Three attempts that changed verdicts were reverted: an open arrival for a parameter's whole subtree (wrong
  under `⟲` folding: `CycleLinkReadAfter` accepted its stale read), a structural reading of a wide leaf from its
  position (mixed `.0`/`.1` in Tea's tables), and opaque continuations (project cannot step past an opaque in
  the middle of a path: `CastRegion` accepted its shared case). Each was caught by the ledger.

**What I learned.** (1) A compact "open" fact is only sound for what a projection leaves unchanged (atoms,
everything inside an opaque); anything else must be read slot by slot. (2) Check every cost change against
the cost table at once: one change made `Dict.removeMin` 30% dearer and was only seen later. `Dict.descend`
is still 42 942 records with growth 3 999 (was 30 659, growth 0) and its cause is not found yet.
