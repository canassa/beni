## 2026-11-01 15:21 CET — own2: fold first, the resumed hit

**What I did**

- Fixed the clean-hit stop in §2.9 *Fold first* after the verification at c06021bad.
  - The states below a hit are not all acyclic: a rank-0 node projects to rank 0. A `{⊤}` leaf at a
    `List` place under an exact-fold cursor is a self-loop of `Σ`.
  - Pass 2 now runs over each resumed subgraph. The guarantee is reworded to "no cycle bit above the
    hit depends on anything below it".
- Weakened the claim of equal reads to "today's walk's states, plus the lazily expanded hits". Their
  extra projections are `memo_proj` hits only.
- Pinned the shared-DAG test's mode (no traversal, alternatives) and what it counts. Added a resumed-hit
  test for the self-loop.

**What I learned**

- "Rank falls along every edge" holds only from rank 1. A rank-0 leaf can loop on itself, so a bound
  argued from rank has to say where it starts.
