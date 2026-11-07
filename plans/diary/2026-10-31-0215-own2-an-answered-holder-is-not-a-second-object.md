## 2026-10-31 02:15 CET — own2: an answered holder is not a second object

**What I did**

- #1367: `g i s = if i ≥ 10 then s else { top = s.top, kept = List.push
  s.kept s.top }` answers `π2` whole and writes `π2.kept`. Rule (a) of
  `ownership-v2.md` §2.11 item 3 took the whole reach of the answered
  record as another operand, and that reach holds the written list, so
  every call of `g` was refused `disjoint`. v1 accepts them.
- I amended rule (a) in place. At an exact write path, an answered value
  on the path counts only for what it holds beside the path: at each node
  from the answered one down to the write, its own cells and its children
  off the path, each whole. A leaf there holds the base as itself when the
  base's cell is the leaf's parameter cell the remaining steps below it. A
  `choice` or `union` is read arm by arm. Other kinds, and paths through
  `[*]` or `⟲`, are read whole, as before (`Transfer.keepAnswered`,
  `holdsCanonical`'s `rest`).
- New fixtures `AnsweredHolder` and `AnsweredHolderImported`, every line
  v1's: the issue's probe, the caller's own parameter, nested records and
  a chained call are accepted. A second field holding the list (at the
  outer and at the inner record, and in one arm of a choice) is refused
  `disjoint`. A read of the old record after the call is refused
  `later-use`. Both fixtures fail on master.
- A v2 dump of the ownership and `run/` corpora on master and on the
  branch is the same except for the new fixtures, summaries included. On a
  scratch merge of `own2-s3b4a` with master and this change, the only
  difference is `run/ListPrependDeep` 81:9 (`churn`): it goes from refused
  `disjoint` to accepted `param`, which is v1's verdict.

**What I learned**

- The callee's own walk already refuses an answer that holds what it
  writes on the same path (`keepAll`'s push is refused `alias`). So at the
  call, the only conflict an answered holder can add is an alias that the
  callee cannot see: the written object at another path of the actual.
- `g i (g 0 r)` hands `g` a choice of the inner call's arms. Without the
  arm-by-arm reading, the chained call stayed refused after the record
  case was fixed.
- `chainedTwice` (the list at two fields, through a chained call) is
  refused by both checkers, but with different causes: v1 says `call`
  (approximate) and v2 says `disjoint`. That difference is on master too.
  I left it out of the fixture, because the parity check compares causes.
