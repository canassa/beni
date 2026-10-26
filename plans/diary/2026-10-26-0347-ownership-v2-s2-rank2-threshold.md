## 2026-10-26 03:47 CET — Ownership v2 S2: compatibility as a rank₂ threshold

**What I did.** Built §2.5's second order, merged with #1038, into
`Regions` and `Liveness` on #1037's branch. Each region gets `base₂`, its
start in an order that reverses every case's arms in place and keeps every
other point's offset, so `rank2(p)` is one region read and, for p < u,
compatible ⇔ `rank2(p) < rank2(u)`. The virtual `withDefault (map m f) d`
case now puts the inner call in the f arm, so its arms tile the span.
`rangesAfter` and the sibling-arm walk are gone; a liveness query is a
binary search past p and a max-tree walk per merge-sort node, one record
each. Tests: the threshold agrees with the LCA climb on every pair of
points of two lowered declarations, the inner call is in the f arm, and a
query from an arm skips the sibling arm's uses. Layouts moved (Region 32
→ 36 bytes, Pair 8 → 12), so the gates run with -Dllvm.

**What I learned.** The dimension-two argument makes the "after p,
compatible" query a single threshold only because arms are adjacent in
the point order; the pipeline form's reference between two virtual arms
breaks adjacency by one point that no query ever asks about, so the
cross-check test skips exactly that point and nothing else. The prepass
does not recognise the pipeline form `m ▷ Maybe.map f ▷ Maybe.withDefault d`
as a join at all (only the applied form), which is why the gap can only
be described, not exercised, today.
