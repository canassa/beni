## 2026-10-23 03:44 CEST — keep the happy-dom box at 0 for shapes it does not count

**What I did**

- Answered the review of #817. F1: the box rule of the driver read only
  the inline `position`, `left`, `top`, `width` and `height`. So a
  margin, a border, a transform, a parent that a stylesheet positions,
  `display: none` and a `fixed` element in a transformed ancestor got a
  wrong box, not the box at 0.
- The rule now starts from the inline `position` and reads all other
  values from `getComputedStyle`. `left`, `top`, `width` and `height`
  must be in pixels. The rule keeps the box at 0 for each shape that it
  does not count: a margin at the top or left, a padding, a border or a
  `min-`/`max-` size on the element, and `display: none`/`contents`, a
  transform, a filter or a containment on the element or an ancestor.
  The nearest positioned ancestor comes from the computed `position`,
  and it must be placed too. `tests/corpus/README.md` lists the shapes.
- F2: the intent comments of `PointerInput` and `PointerEvents` say
  what the gates now prove.
- The reviewer's probe page, plus three shapes, in both DOMs: each
  happy-dom box is Chrome's box or 0. Both red changes still fail the
  two pages under happy-dom.
- Rebuilt the branch on master without the old hash commit, because
  master moved many hash files. Then recorded the hashes once.

**What I learned**

- happy-dom's `getComputedStyle` applies `<style>` rules. It gives ""
  for a property that no rule sets, not the initial value, and it
  writes `0` as `0px`.
- When master moves the same hash files as the branch, a rebuild by
  cherry-pick that leaves out the hash commit has no conflict. One
  `test-run-hashes` after it records all the hashes.
