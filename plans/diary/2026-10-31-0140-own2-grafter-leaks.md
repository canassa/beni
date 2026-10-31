## 2026-10-31 01:40 CET — own2: the view grafters free their memos

**What I did**

- #1391: `Calls.Grafter` holds three memo dictionaries (`folded`, `deeps`,
  `prefix_args`). Only the grafters of `apply` and `resolveImage` freed
  them; the six grafters `Views` makes for `placeImage`, `leafImage`, `partsImage`,
  `cellsImage` and the two reads of a cell's kappa and reach did not.
  Once `foldedCells` began to memoise `prefixArg` (#1159), every such read
  leaked the dictionary. `Grafter.deinit` now frees all three and every
  grafter, the tests' included, defers it. `LevelPlacesCall`,
  `LevelPlacesKinds` and `run/ViewBelowInPlace` print no leak in a Debug
  build.
- #1381: I could not make a walk that stops at `ownership_summary_size`
  leak on master. I swept the ownership and run corpora in a Debug build
  with growth reservations failing from the Nth on (N = 1 … 46 368), once
  as a single failure and once as every failure from N on, so the cold
  rerun fails too: no leak. The report came from a scratch copy of the
  4a branch (`MarkerAcross.keepRight`). The leaking grafters above are the
  likely owner, since a stopped walk is a read through a view. The new test
  reads a level-crossing cell through a view's grafter with the allowance
  `extra` records past the start, for ten values, so each stop point is
  covered under the testing allocator.
- The test fails with three leaks when `cellsImage` loses its
  `defer g.deinit()`.

**What I learned**

- The gates' ReleaseSafe binary and the unit tests never saw this leak
  because no unit test reached a `Views` grafter with a level-crossing
  cell; only a Debug `dump` of the corpus did.
- `test-blackbox-docs` fails on the main checkout and on this branch alike
  (the test passes when run by hand in 3 s), so it is not from this change.
