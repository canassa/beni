## 2026-10-25 02:11 CET — List edits carry their reads (#989)

**What I did**

- Fixed #989: `List.push`, `cons`, `append`, `insertAt`, `removeAt` and `swap` now keep what
  they read beside their tag. Pinned by `writes/ListEditReads`, red on master.
- The first version minted an element root per evaluation, which kept two recursions from settling
  (`writes/Recursion`, `TableApp`). The same flaw was in #986's `Dict` reads, so a `Dict.insert`
  recursion hit the cap. Read-only elements now mint no root, a sequence merges them, and
  insertions sequence to `grow` (`writes/DictRecursion`, red on master).
- No `browser/inline/` page could show the stale hole on master: an edit of a model list in `view`
  is refused by the ownership checker, so the defect did not reach emitted code.

**What I learned**

- Anything a term holds is part of a fixpoint's equality, and a fresh root per evaluation breaks it.
  An existing recursion golden was the first sign, before any new test.
