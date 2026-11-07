## 2026-10-30 23:41 CET — own2: a shared image reads lost for a missing entry

**What I did**

- Answered #1384's review. `kappaRelabel` joined only the κ entries that exist, so once `map`
  interns two built nodes at one position into one image, one node's entry answered for the other,
  which reads `lost` with none. Read-off now counts, per position, the built sources of each image.
  It runs one paired walk of the value and its snapshot (`Presence`), only when a `map` shared an
  image. A source with no entry there makes the image's entry `lost` (`Cond.Relabel.present`).
- `armCount` stores only final counts. The §2.3 text now says the knot test is not Tarjan's low link,
  and harmlessly so. It also says why the join only weakens, with the review's `pickList` case.
- No corpus line changes. GroupFieldShift at n = 16 is 388 130 records on 4a + master (385 482 before
  the fix), and `mergeSort` is 125 868.

**What I learned**

- Two simpler fixes failed. Reading `lost` for every image with two sources blurred
  `RecursiveSiblings`' summaries, because the sources stood at different positions. Refusing every
  collision inside one map cost GroupFieldShift ×2.8 (1 079 083 at n = 16), since equal fresh lists
  in different fields stop sharing across rounds. The count has to be per position.
- 4a's `renumber` also maps a class and relabels its κ, so it needs the same `present` hook.
