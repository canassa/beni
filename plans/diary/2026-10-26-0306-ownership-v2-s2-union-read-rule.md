## 2026-10-26 03:06 CET — Ownership v2 S2: the union clause of the κ read rule

**What I did.** Closed the last hole #1036's re-check found: at a summary
position a union's derived κ joined its sides' reads but never compared
cells across sides, so `[*].a` of `[ { a = (g 1).a }, { a = (g 2).a } ]`
read `yes` from an empty map where the one leaf over the same two cells
derives `apart`. `Cond.unionKappa` now also applies the leaf rule to the
union's own (united) cell set at a summary position, once per read,
charged and never memoised; the depth-1000 union DAG test stays linear.
The reviewer's program is the red twin `CallbackFieldPositionsUnion`.
Committed on `own2-s2-conditions` (449ad5608), rebased `own2-s2-summaries`
onto it (2d86faaf0), pushed both, replied on #1036 finding by finding with
the one-line design text for #1038 §2.9/§3.4.

**What I learned.** The read rule's backstop has to hold for every node
KIND, not only leaves: a union a walk never stored (every union
`Shape.map` makes at an instantiation) has no stored κ, so whatever the
union read derives is all there is. Deriving over the union's cell set
costs one set walk and keeps the read linear. The set deduplicates a cell
that arrives in both sides, so a repeated-side union is read at `yes` on
its own; the multiset fact lives in `propagate(.together)`'s stored
`shared` for a built literal — stated on the PR as a limit, not hidden.
Waiting on #1038's re-review verdict before any rank₂ work in Liveness.
