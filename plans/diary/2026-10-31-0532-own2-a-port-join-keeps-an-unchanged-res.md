## 2026-10-31 05:32 CET — own2: a port join keeps an unchanged res

**What I did**

- Profiled #1423 on two scratch merges of 4a and master: one with #1424
  reverted, one as is. I used temporary counters per walk, per port join and
  per reader, and I kept `Cond.propagate` apart.
- The walks of rounds 1 to 6 are the same in both merges. In round 7, #1424
  turns `wb`'s `disjoint` refusal into `xreq` atoms. Then three more rounds
  follow, and in them `xreq` grows from 0 to 1, 2 and 5 atoms. In those rounds
  the uses, `res` and κ of the round are under the port's, so only `xreq`
  moves. But `Summary.join` propagated κ over the whole unchanged `res`
  every time: 121 000 to 135 000 records for `wa`, and 37 000 to 43 000 for
  `wb`. That was 79% of `wa`'s growth.
- The fix: `Summary.join` keeps the first class's `res` and κ when the
  second's are under them. `wa` goes from 701 268 to 306 184, and `wb` from
  339 373 to 172 445. The quadtree and T3 rise by 24 and 12 records. I
  compared 984 v2 dumps of ownership/ and run/: no verdict changes. Some
  summaries are smaller, because each round's join no longer adds duplicate
  entries.

**What I learned**

- Two `res` values that are equal under `leq` can print differently. The join
  added redundant entries, for example `π1[*] π1[*]`, and every join after
  that paid for them. This is why the late walks of `wa` became more
  expensive too. Their Demands κ went from 13 800 to 21 000 records.
- The rest of the cost is the three extra rounds that `xreq` needs to reach
  its fixpoint. That is #1424's per-depth `excl` atoms moving around the
  cycle. They are not join work.
