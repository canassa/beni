## 2026-10-31 04:47 CET — propagate reads a repeated run once per call

**What I did**

- Built #1372's fix F1 in `Cond.propagate`: two per-call memos, keyed by
  content. A run met again through another parent now reads the slice made
  for it (κ from the members, the cursors' steps), and its run one step below
  is keyed by the run, not by the index it was cut at. A frontier is made once
  per (node, class, slice).
- The slice memo is not a dictionary. Each run id has a `(call, slice)` word
  pair on the table, and a call reads only the pairs that carry its own number.
  A slice keeps its first frontier inline, so `front_at` is looked up only for a
  slice's second node. With a dictionary for both, the corpus cost 0.17% to
  0.45% more records, because most runs are met once. Now no fixture costs
  more, and six cost less.
- Exactness: verdicts, summaries, block hashes and `crossing` lines are byte
  for byte the same on 980 ownership and `run/` fixtures, on core, and on 4a's
  corpus except `MarkerAcross.keepRight`. That one is #1372's known limit, and
  it now settles, as the prototype found. `-Downership-full-cross-check` walks
  every call again with no memo and panics if the snapshot differs. The whole
  corpus ran clean under it. A unit test compares a memoised walk and an
  unmemoised walk over a repeated substructure.
- Counted `build_test`: a branch join of a record that doubles at 8 levels
  costs 12 975 records with the memos and 20 883 without them. The states
  stay one per path. The join memo is written only once the call has finished,
  so the cost still doubles per level, but each level costs less.
- Growth of the cliff programs, with the allowance raised, before → after:

  | build | `wa` | `wb` | quadtree | T3 | `descend` |
  |---|---|---|---|---|---|
  | 4a alone | 150 712 → 97 826 | 58 473 → 57 188 | 70 707 → 59 592 | 72 363 → 61 327 | 349 546 → 296 922 |
  | 4a + master (#1422 in it) | 186 454 → 133 568 | 79 351 → 78 067 | 142 075 → 130 960 | 111 487 → 100 451 | 249 213 → 222 957 |
  | 4a + master + #1424 (#1422 fixed) | 701 268 → 453 475 | 339 373 → 279 719 | 153 414 → 142 299 | 118 133 → 107 097 | 249 213 → 222 957 |

  Master is 2d80b494c, with #1408. Its figures are not the ones the issue gives,
  which were measured before #1408. On every row, the verdict and summary lines
  are the same before and after. With #1424, `wa` costs about 3.8 times what
  it costs on 4a + master. That is
  #1424's cost, not this change's.
- Four counted tests near the allowance (the genuine product, the summary that
  is not printed, and the two near-limit orders) used a record of 200 records
  read at 16 positions. With the memos, that is no longer a product: its
  growth went from past the limit to 0, because the repeated runs are read
  once. They now use `doublingProduct`, a record that doubles at 11 levels.
  Its 3·2¹¹ paths are still states, one per path, and the number of extra
  lists sets its growth: 126 000, 65 227 (its print passes the allowance), and
  62 300.
- `Cond.zig`'s §5 target is now 4 540. It was 4 500 after #1408. The memos and
  their cross-check take 38 lines.

**What I learned**

- §4.1 says every dictionary lookup is charged, hits and misses alike. So a
  memo that rarely hits costs records on ordinary code. An epoch-tagged array
  indexed by an id the walk already has, or a one-entry cache on a record the
  frame already reads, gives the saving and no tax.
- The scratch merge of 4a and master has conflicts in `Calls.zig`, in
  `rules_test.zig` and in the docs, not only in `ownership-v2-known.txt`. Check
  for conflict markers before you build.
