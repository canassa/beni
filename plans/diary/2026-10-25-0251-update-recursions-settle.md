## 2026-10-25 02:51 CET — Update recursions settle in the write-set pass (#998)

**What I did**

- Fixed #998. A recursion through `List.update`, `List.map` or `Dict.update` reached the round cap.
  The rounds are now compared up to the renaming of the element roots minted since the recursion
  began. A composed update keeps one copy of the elements that write the same against their own
  roots. No cap moved. Pinned by `writes/UpdateRecursion`, red on master.
- The first version shared one root per row site instead. The review found that it let a fold reached
  through a function value read its inner callback against the outer one's facts, so it dropped a
  write and the page stayed stale. That is pinned as `writes/NestedFoldValue` and a
  `browser/inline/` page, both red against the first version.

**What I learned**

- The round cap fires when a fixpoint's terms differ, not only when their values do.
- A bound name is not a cache key. Sharing it across evaluations has to be proved never to meet itself
  under different facts. Comparing terms up to renaming needs no such proof.
