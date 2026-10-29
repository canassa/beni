## 2026-10-29 17:43 CET — ownership v2 S4-verifier review fixes

**What I did**

- Fixed the three blocking holes the review of #1189 found, each pinned by a red-first witness. Each
  fix, reverted alone, fails that witness:
  - `within` counts a result, an answer or a split as one per call only when its label is under the
    `within`'s label;
  - `gen` goals are keyed by the answer's path (`genAt`);
  - `foldPair` checks that the label is the pair's fold, a conflicting second pair refuses the
    label's `within`, and `prefixWithin` carries provenance through an instantiation.
- JoinedClosurePorts' refusal now comes from a verifier evaluator, `writesCaptures`. The mark
  codec spells `single` with two distant words.
- Added witnesses for the folded-accumulator cross-depth alias and for RefinementFeedbackTwice's
  first positive control. Rebuilt TwoTraversals' and NestedTraversal's labels from the fold and
  instantiation rules.
- Corrected the design text: the invalidation counts, the exactness of a component's refusal, the
  codec's limit (a valid rewrite needs the block's integrity check), and gap 3's obstacle, which is
  the caller-side self pair and not the invariant form.

**What I learned**

- A within label alone says nothing about the cells under it. Each cell has to name a call the label
  stands for.
- A callee family's generativity is a claim about one path of its answer, not about the whole
  answer.
