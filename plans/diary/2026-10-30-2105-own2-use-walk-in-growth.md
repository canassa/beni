## 2026-10-30 21:05 CET — own2: a callee's use walked in growth (#1369 review)

**What I did.** The review of #1369 found that `Calls.Routes.start` ran
`marksBelow` outside any growth kernel in `Transfer`'s writes loop, so its one
record per use node landed on the call's `call_view` lane. On master that walk
ran inside `Calls.apply`'s `graft` growth. A record of 600 fields of distinct
types, read through, stopped `caller w = wall w` on
`ownership_accounting_invariant (call_view lane …)`. `start` now enters
growth itself. Its memo belongs to the nodes, so one memo serves the escape walk
and the write walk of every parameter of the call. Counted test at 300 and 600
types: 4 662 and 9 681 records (1 200 types: 19 740 records, but that dump takes
1 s alone, so it is not a test). The lane test went from 640 to 480 fields (40 057
records, 0.64 s).

**What I learned.** Moving a walk out of a function also moves it out of the
kernel the caller had put around it. Each new call site needs the same
question: which lane is this on?
