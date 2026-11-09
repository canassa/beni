## 2026-11-09 05:04 CET — bike-wars: lists grow at their end

**What I did**

- Issue #1918. `examples/bike-wars/src/Helpers.beni` had two loops that put
  elements in front of their accumulator, so each `--release` site build
  printed two `prepend_in_loop` warnings.
- `trailToLines` now pairs each point with the next one:
  `List.map2 l (List.drop l 1) toLine`. No accumulator, no `List.reverse`.
- `linesToTrail` now reads the lines from first to last with a local
  `joinLines done current lines`, which pushes at the end of `current` or
  of `done`. The result is the same as the old right fold.
- A Node program (not committed) compared the old and the new functions on
  20 000 random trails: 0 differences.
- The `BikeWars` page fixture compiles silently now, so its `.diag` golden
  is removed. Its transcript did not change.
- `PORTING.md` records the change as item 13.

**What I learned**

- The first version kept a `List.foldl` and wrote
  `[ …accInit, [ …accLast, end ] ]`. v1 accepted it, but v2 refused the
  fold's literal and its element write, so the corpus v2 parity failed.
  A recursive function with two plain accumulators avoids the element write.
  v2 then makes one more demand than v1 (the second accumulator), the case
  that `ownership-v2-known.txt` already excuses for `List.unzipHelp`.
- The old `recurse … [ b, …tail ]` rebuilt the rest of the list at each
  step too. That copy was quadratic, but no warning named it, because it is
  not the accumulator.
