## 2026-10-30 04:13 CET — A view-free memo for the class checks

**What I did**

- #1279's CI failed the 1 s CPU budget on two codec tests:
  - `BlockRead` #1138, a snapshot as deep as the source;
  - `BlockRead` #1141, codec work linear in depth.
- On dagon (Debug, each test alone):

  | Test | master | #1279 |
  |---|---|---|
  | #1138 | 215 ms | 476 ms |
  | #1141 | 221 ms | 745 ms |

- **Cause.** `Summary.Table.add`'s safety checks walked every class's whole `res`, use shapes and κ for views, at every class. When I turned the checks off, master's times came back.
- **Fix.** `holdsView` and `kappaHoldsView` now remember the nodes and positions they found view-free. The memo is valid until a knot is tied, which is the one change to a made node's record. So each class checks only what it adds.
- After the fix: #1138 takes 233 ms and #1141 takes 255 ms, both under 0.3 s.

**What I learned**

- A debug check over a value is a cost like any other walk. Run once per class over a growing DAG, it made a linear test quadratic. Safety builds run it on every CI test.
