## 2026-10-30 00:50 CET — The view node kind and its readers

**What I did**

- **#1261's re-review.** Rule (c) owed `excl` when each of two class paths
  met a leaf somewhere. `g l = f { x = l, y = l }` meets `l` through `.x` and
  through `.y`: one list held twice, so it is a conflict. `excl` is now owed
  only when both paths reach the same leaf through the same prefix and part
  below it (`foldBelowLeaf`). `CallOtherPathsSharedLeaf` pins the repro (red
  before the fix) and its variants. The variants are one actual for two
  parameters, a choice, a record built by a call and two distinct lists.
- **The probes of three-level chains and a capture** agree with v1. The
  capture is unbuilt (a lambda).
- **`--ownership-both` against master.** Over 251 ownership fixtures, v1's
  section is the same in every file. v2's section changes 85 lines in 44 files,
  and no verdict flips on a line both binaries check.
- **Slice 2a.** The `view` kind has a reader in every switch of `src/own2/`.
  A view is read at its answer. Cond's κ joins the entries stored under every
  view of a chain, which `force` now records step by step. A callee's template,
  a published block and a summary hold no views.
  - A unit test runs a view through a test instantiation: proj, cells, reach
    and a chain.
  - Guards for 2b, pinned on today's eager path: `KappaAtView`, the cost of the
    `pick` chain and the `id` tower per call at 50 and 200, a push at depth 32
    and 64, and a twin of eight chains at `--jobs=1` and `--jobs=8`.
  - Shape's §5 target is now 2 200 lines, and BlockRead's 980.

**What I learned**

- "Both paths are read through a leaf" was not evidence of distinct
  positions. The leaf must be the same one, met through the same prefix. A
  record that holds one value in two fields reaches that value through two
  prefixes.
- Today's eager path already holds the guards: about 111 records a call for
  the `pick` chain at 100 and at 1 000, and about 20 records a level of depth.
  So 2b keeps a cost; it does not have to earn one.
