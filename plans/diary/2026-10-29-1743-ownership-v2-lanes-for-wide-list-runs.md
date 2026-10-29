## 2026-10-29 17:43 CET — Ownership v2: lanes for wide list runs

**What I did**

- #1157 (fold obligations at call reads and in blocks) got two review fixes and merged.
- #1158 (lazy cell sets for internal `positions` nodes): fixed its review finding. A recast or a delta is now interned without its wrapped node's cells. Rebased it onto master after #1157 and #1172's predecessors, and it merged.
- #1172 (#1139, per-item lanes for literal and spread runs): the first version put each item's share of every `propagate` state on the item's lane. The review found that this is items × positions on one lane, and that small programs (`[ b, b ]`, two 80-field records, nested records) reached `ownership_accounting_invariant`. The fix:
  - an item's lane carries only the positions node made before it;
  - everything value-sized is a growth task chosen before the work (`Transfer.sized`);
  - so is a walk from a `positions`, `union` or `choice` node (`Shape.dagWalk`).

  It merged with the corpus fixtures `WideItemValues` and `EarlierRunSpread`.
- #1187 (#1181): a spread's and an append's root work (`construct`, `prepend`, the first item's fit) still ran on the root's lane. A 64-arm `case`, then `[ y, …c ]`, reached the invariant. All of it is growth now. Fixture `WideChoiceSpread`. In review.
- Read-off continuations: built the per-request prepaid pool as §4.1 words it, and measured it. It cannot be sized before the work. I sent the manager a source-sized alternative, K records per source atom, and I am waiting for the decision.

**What I learned**

- On a lane, only work that is constant by construction is safe. Almost every per-item read in the checker costs as much as the item's value: `kappaOf` (`derivedCells`, a recast's inners), `reachAgg`/`aggMerge`, `lower`, `fit`, κ merges, and a demand's operand sweep. A test whose items are all `[ n ]` never shows this. Probe with nested, wide, earlier-built and chosen values before opening a PR (the manager's new rule).
- Making every DAG walk growth was too blunt: it took a call's view off its own source lane, which §4.1 keeps as baseline. Deciding by the root's node kind keeps both.
- Read-off reads more than the nodes and cells a per-request continuation would prepay: conditions, κ maps, set entries, paths. And re-reading one value at several positions costs its size each time.
- Over the corpus, growth per source atom tops out at 125. A literal of small lists needs about 50 to 60 per atom, an append chain about 19, and a 100-arm choice about 45.

**Questions for the owner**

- None of my own; the read-off pool's shape is with the manager.
