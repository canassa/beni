## 2026-11-06 11:58 CET — A need on a label

**What I did.** Finished #2116's need from the staged work a previous agent left: moved `RelText` down to L3 so that `ContractText` may import it, split `ComparisonWalks` out of `Groups` when the rebase pushed it past its target, and added the fixtures: `ownership/NeedOuterOnly` out of pending, `run/SanitiserNeed`, `run/SanitiserNeedApart`, `run/SanitiserNeedLevel`, and `NeedAcrossModules` in both `run/` and `ownership/`.

**What I learned.**

- The checker's early `unknown` was doing two jobs. It refused a write of an answer, which is what a need replaces, and it also made `Supplied.judge` take its slow path, so letting the first through changed `kept` on supplies and refused `SanitiserAnswerHandedOnApart`. `Demand.supplied` keeps the second job. The ownership corpus alone did not show this; the `run/` corpus did.
- `v2` writes no cache entry until S6: `Session` turns the cache off. So "cached and uncached" means nothing for a need yet. The block in the interface is what a future entry will hold, and the imported fixtures test that path.
- `LvlCb` went from refused to a wrong answer. Master refused it only by accident of the same `unknown`; a `⟲` past a non-regular type's places is dropped by `Slots.replay`, and its parameter twin is a live wrong answer on master, in #2062's family. A step an answer cannot follow is now `⊤`, which also fixed `LvlCbRd`. The parameter case stays #2062's.
- A count word per label cost two records on `shapeOf`. A bit in the label's word costs nothing.
- A mutation that removes the need's refusals makes every negative control trap, so the fixtures test the rule.
