## 2026-09-27 — R12: the old checker is deleted

**What I did**

- v1 is gone: `Solve.zig`, `Constrain.zig`, v1's `Check.zig`, the capability code in `Types.zig`,
  the flat dispatch builder, `--checker`, `BENI_CHECKER`, the checker id in the cache key
  (`key_version` 5). `src/check2/` is now `src/check/` (git mv); three files over 1 500 lines were
  split; `rules_test` fences every file with a 1 500-line cap. Scenarios that existed to compare
  the checkers were deleted or folded.
- CK-88 (a `case` of many literal branches: quadratic, and one `switch` past SpiderMonkey's limit)
  and CK-95/127 (lowering a big `let`: quadratic) fixed with perf scenarios red before; CK-133
  (a Debug-only re-walk budget) fixed.
- Final numbers, check phase against `7427828` (the commit the rewrite started from), medians of
  five interleaved rounds: plain 92.98 → 101.05 ms (1.087×), `--dispatch` 101.05 → 113.38 ms
  (1.122×, over the 1.10× line: CK-134). Whole-process user cycles: 1.06× and 1.10×. The new
  checker does strictly more (occurs at every binder, generality checks, one derived-context
  fixpoint, deep-safe comparisons) and fixes ~130 catalogued defects; the gap is CK-134's.

**What I learned**

- Compare against the baseline the budget names. R11's "1.01×" compared both checkers inside
  R11's binary, which hid the drift from `7427828` that R12's measurement exposed.
