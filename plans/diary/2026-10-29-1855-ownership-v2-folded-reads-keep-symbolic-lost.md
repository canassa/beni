## 2026-10-29 18:55 CET — ownership v2: folded reads keep symbolic `lost`

**What I did**

- Per #1196's review (F1): below a symbolic leaf, every canonical path again reads `⊤`, as master
  does. Repro A and Repro B are pinned as refused. The precise projections are #1199.
- Moved the BlockRead deep-snapshot test's tables to the heap. Its 64 KiB thread stack held two
  table fixtures and needed 58–62 KiB on master, so the 32 bytes this branch adds to `Cond.Table`
  overflowed it. The crash then deadlocked the test runner (#1197).

**What I learned**

- A small-stack test that holds its fixtures on that stack measures fixture size, not recursion
  depth.
