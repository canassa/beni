## 2026-11-03 02:09 CET — values lane: twin demands and a one-node identity

**What I did**

- Fast-forwarded `own2-cost-values` to `own2-integrated` (`d4aa38289`) and built on it (#1714, part of #1685).
- The k-list-fields family: profiled `incAll` + `incList` at k = 4 / 8 / 16. A callee's writes `[*]#B.j⟲`, one
  per field j, all project onto the same k canonical slots of the caller (the `⟲` folds at `B` and forgets j).
  So one call made k demands with one set of targets: about 2k² demands an evaluation, about 5k distinct.
  New `Twins.zig` (§2.8 *Twin demands*): demands that one call makes for one argument, equal in all but their
  text's path, are judged once. Each line keeps its own text. Also `instCondMixed` walks the callee's result
  tree once per plain slot, not once per (occurrence, slot). 62 464 / 315 380 / 2 208 571 → 48 644 / 208 446 /
  1 151 345 records. The test flips. The ledger, every dump line, the summaries, the oracle and the cost table
  are unchanged.
- #1715: a parameter's subtree that the result returns at its own path (one PathId for both) folds below it as
  the result does, so it is one open arrival once written out it would pass 256 slots. `same : K0 → K0` over
  five mutual types was over the limit at any allowance. It is now `res ε… π1ε`. A new build_test fails before.
- `Dict.descend`'s two F7 rounds: found what moves (only `res_cond`: explicit deep occurrences in round 0,
  `#0.4*` and then `#0.3⟲*` in rounds 1 and 2, the same slots spelled two ways). I did not find where the
  symbol spelling is made. Neither `selOf` nor the distinct check's parameter groups spell it, because
  rewriting both changed nothing. Not fixed.
- `Schema.shapesOf`'s growth: not started.

**What I learned**

- An open arrival at every cyclic own path is exact but costs more to read than the written-out slots
  (`Dict.descend` 37 191 → 66 105). So the open form pays only where writing out is the blow-up.
- A callback supply read back from an open node says only its top slot (`Codec.Decode.decodeString`'s label).
  An open node in a supply would say less than the slots written out.
- `covsum` did not read an open arrival `q… π_j·s` as covering `q·r … π_j·(s·r)`. `cv8/covsum.mjs` adds that
  rule and compares the supplies inside labels.
- When I need a message with a blank line after the subject, I write it to a file and use `-F`.
