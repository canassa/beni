## 2026-11-01 15:13 CET — own2: fold first, the re-review's three items

**What I did**

- Fixed the three items that #1535's re-review of 2a1882b9a left in §2.9 *Fold first* and §4.1. The
  review confirmed the seven earlier findings and the proof.
  - Pass 1 now stops at a clean-memo hit and expands that state lazily. So it reads exactly the states
    that today's walk expands, and a family of joins over one shared DAG costs `O(N + C)`. Added that
    family as a counted-test spec.
  - The open-set count is stated as exponential in the worst case, `O(2^√|Σ|)`. It is charged per set,
    it ends at `ownership_summary_size`, and a hidden dump flag reports it.
  - Corrected the per-path argument: chains of children repeat no node. The sets along a path need not
    be disjoint.
  - Stated the cost of the fold closures.
  - Said that a single state with a self-edge is cyclic.
  - The cycle bits are now numbered per node-graph component, with their cost and their quadratic case.
  - Gave the measured `|Q|`: 40 of 221 nodes in walk 3's largest join.
- Filed #1541 for the exponential family's fixture, which I did not build.

**What I learned**

- "Pass 1 reads what today's walk reads" was true of the corpus but not in general: a clean-memo hit
  is where today's walk stops early. A claim of equal cost needs the same stopping points.
