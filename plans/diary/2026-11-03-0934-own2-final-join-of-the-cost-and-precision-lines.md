## 2026-11-03 09:34 CET — own2-final: join of the cost and precision lines

**What I did**

- Made `own2-final` from `own2-cost-joined` and replayed the 14 commits of `own2-precision-6`
  since `own2-integrated` onto it, in order. Then I carried the values lane's six new commits
  of `own2-cost-joined` (result slot columns, pointwise join).
- Ported each precision rule onto the cost lineage's representation:
  - the `fed` occurrence (`Fed.zig`): split off before `CallGraft.sel`; `Graft.fold` keeps it
    and `Graft.movedReq` refuses it; `CallGraft`'s rename mask leaves its bit alone;
  - host leaves: `Put.arrive`, and `host` kept by `CallGraft.hits`;
  - fold candidates (`one`): in `Coexist.Entry`, `listsInto`, `mayPair`, `pairMay`,
    `answerMeets`; the candidate key also holds the route set; `Chains.onChain` stays;
  - `wildBelow` kept in `BelowSize` (not a second copy in `Subtree`).
- Kept every line target. `singular` and `answerMeets` moved into `Distinct` to keep `Entries`
  under 400 lines. Some comments in `Eval`, `Walk` and `Value` were joined. Bumped the block
  version once, to 19.
- Found a join defect with the three-way summary union: 17 summaries lost `host`. The cost
  lineage's read-off shortcuts (`CallGraft.slotArrivals`, `AtomGraft`) never expand a call's
  leaf, so `hosted` never saw the call's fresh objects. Fixed. A build_test pins
  `Schema.read`'s issues as `host`; it fails without the fix.
- Made `chainCallCold`'s subtraction saturate: the plain chain's read-off now asks about host
  objects, so the call can cost less than the plain chain and its demands.

**What I learned**

- Verdicts: the joined head is `own2-precision-6`'s at every position. The 25 positions that
  move are the line shifts from the removed `@ownership_summary_size` raises. Against
  `own2-cost-joined` the differences are exactly precision-6's.
- The union check (per summary: is J the union of A's and V's changes from their base?) found
  the defect that the verdicts did not show. Run it after every join.
- Carrying the pointwise join took `bench/corpus oneOfHelp` under its limit (growth 55 235).
  So JsonCodecs' decoders now read `fresh shared` where both lines had said `⊤`.
