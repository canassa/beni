## 2026-11-01 22:06 CET — Measure the two ways out for removeMin

**What I did.** Prototyped, in scratch, a widen that folds earlier-round knot images held under whole recasts
into the root class's node, and measured it on a copy of `Dict.removeMin`, `descend`, the 2 131 corpus roots
and a 60-program Dict-like oracle sweep with its forced control. Read `Demands`, `Holders` and
`TransferArms` for the pointwise form under `lost`. Wrote both results and the decision into
`ownership-v2.md` §2.3 and Q8 (#1372). Docs only.

**What I learned.**
- Every held knot is the inner of a whole recast that the graft makes at a `⟲` level. The fold is sound for γ
  but not exact: the read-off's held image lacks the root parameter's own cells.
- Unguarded, the fold lets `removeMin` settle at 10⁸ (5 walks, 35.6 M growth), still far over the default.
  The growth left is unions at the key and value place, which lies on no cycle.
- A cycle of only unions and recasts makes `Shape.map` loop with no charge until memory runs out.
- The pointwise form under `lost` keeps the verdicts, but condition 4 can refuse before condition 6, and a hold
  loses its `alt` bit, so causes and exactness change. The worked example is the counterexample.
- Debug `removeMin` at 4 194 304 takes about 15 s; the folded run at 10⁸ takes 2.5 min.
