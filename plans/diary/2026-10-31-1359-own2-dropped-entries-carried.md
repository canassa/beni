## 2026-10-31 13:59 CET — own2: a dropped positions node's entries are carried

**What I did**

- The review of #1471 showed the "empty κ home" claim is false, because a dropped node can have
  snapshot entries. A construction merges its operands' snapshots, and an operand keys its own
  positions node. I built a read-time check of the lemma (each entry of a dropped node must be implied
  by the read of the rebuilt node) and a fuzz generator. The fuzz found a case where it fails:
  `m4 = [ a, a ]` stores `shared`, and `[ a, l2, …m4 ]` drops that node. A read at a summary
  position then derives only `lost`.
- Following the manager's decision, constructions now carry the entries over. Each rebuild records
  what it dropped (`Shape.dropsOf`, `dropsClosure`). The literal, the construction and the prepend
  walk the new snapshot and join each dropped node's entry onto the node at that position, unless
  the node's reads already imply it.
- The read machine checks the lemma under `runtime_safety` and panics when it fails. The fixture
  `ownership/PositionsSaturate` makes the gates exercise the check: `shared` at a prepend,
  `apart` at a lazy `[*][*]`, and a pushed element. A black-box test pins that `sharedLost`'s
  summary stays `{shared}`. Before the carry it printed `{lost}`.
- Rewrote §2.3 (*The entries of a dropped node*) and amended §5's line targets.

**What I learned**

- The corpus never reaches the check with an entry: across 2 044 roots, zero checks. Only the
  fuzz did.
- Carry reads must run without the memo. Otherwise a later read hits the memo, the check never runs,
  and the mutation test cannot fire.
- Map images of a rebuilt node are not checked at read time, because the drops are kept under the
  node, not under its images. The carry is what reaches them.
- With no carry, the check panics on the fixture. With neither carry nor pair rule, it panics on the
  `apart` case. Without the pair rule, the carry would copy the pair into the block.
- 5 400 fuzz programs gave zero verdict differences from master and zero lemma failures. Summary
  text still differs: cells that occur three times print twice, and fresh names follow the new order.
