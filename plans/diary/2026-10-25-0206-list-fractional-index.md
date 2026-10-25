## 2026-10-25 02:06 CET — a fractional Int is no list index

**What I did**
- #988: `List.get xs (2 ^ (0 - 1))` returned `Just undefined`, because the bounds check `0 ≤ i && i < length`
  lets `0.5` through and `a[0.5]` reads `undefined`. `set`, `update`, `insertAt`, `removeAt` and `swap` had
  the same hole (`swap` wrote `undefined` into the list; `insertAt` and `removeAt` cut at a fraction).
- One private `outside i n = i >>> 0 ≠ i || i ≥ n` now replaces every bounds test. `i >>> 0` is `i` exactly
  for a whole number in 0…2^32-1, which holds every array length, so it also rejects negatives, fractions,
  NaN and infinities in one comparison. A fraction is out of range: `get` gives `Nothing`, the editors
  give the list back.
- `slice`, `take`, `drop` and the `String` slice family are clamps, not reads. They already cut a fraction
  toward zero through JS `slice`, except that a negative fraction counted from the end first (`right "abcd"
  1.5` was `cd` while `left` gave `a`), and `drop 1.5` built a view at offset 1.5 and then threw
  `RangeError`. `clampIndex` and `String.clamp` now truncate first, and NaN is 0.
- Fixture `tests/corpus/run/CoreListFractionalIndex`, red on master's `core/` (checked by restoring
  `core/List.beni` and `core/String.beni` from origin/master). Run hashes re-recorded, five release
  goldens re-blessed.
- Left alone: `List.repeat`, `range`, `initialize` and `String.repeat` throw `RangeError` on a fractional
  count (`new Array(1.5)`). Those are counts, not positions: #990.

**What I learned**
- `git checkout HEAD -- core` after a red-proof restores HEAD, not my edits. Commit before a red-proof, or
  copy the files aside.
