## 2026-10-22 12:08 CEST — Construction conditions as one pairwise-apart atom

**What I did**

Took #693 after the manager's decision. Wrote the dated amendment to §16.7 and
§28.4 first: one atom, `apart G₁ … Gₙ`, whose meaning is its expansion into
`sep` pairs, with a record form and a spine form. A condition holds an apart
only when its expansion is longer than its members. Summary blocks are version
21.

Built it in `src/own/`. `pairwiseApart` gives the conjunction of `sepCells`
over every pair of members of distinct groups in one pass. Pairs that their
kinds settle are not formed, related pairs are found through each cell's path
ancestors inside one family, and the arrivals that are left are one apart. A
call instantiates each group's provenances once (`instPairwiseApart`). The
construction, the constructor-function summary and the list literal all use
it. A failing `xreq` apart is discharged pair by pair, so every report keeps
its place. Safety builds compare each apart of at most 64 pairs with its
expansion, and every apart under `-Downership-full-cross-check`.

Every verdict is unchanged. Six ownership goldens print new condition text,
`WideFieldConditions` fell from 261 KB to 79 KB, and the full cross-check
fails only `RecordTree` and `LevelPlacesKinds`, as on `master`. The ownership
phase went from 121M to 87.8M instructions at N = 64 and from 1 140M to 597M
at N = 256.

**What I learned**

The construction conditions are no longer what grows. At N = 256 they take
43M of the phase's 597M, and the entry protocol takes 501M, so the ×6.8 from
N = 64 to 256 is the entry's and not the representation's. The per-entry
spine conditions of a result are a star around each entry and not a clique,
so one apart cannot state them.

The one pass costs the safe binary a little on core, where most constructions
are small: 8M to 17M, plus 21M to 23M for the check against the expansion.
Building a condition no longer than its members pair by pair removed most of
the rest. The cell creation order matters less than I feared, and no golden
moved outside the printed conditions.
