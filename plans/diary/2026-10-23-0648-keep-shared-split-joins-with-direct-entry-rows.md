## 2026-10-23 06:48 CEST — Keep shared split joins with direct entry rows

**What I did**

Rebased #850 over d0c9257ab after the shared split/join optimization landed.
The rebase is clean and preserves that implementation. Its new SplitArmsJoin
fixture had seven platform refusals on browser-tea; the entry word gives those
record writes their direct-row acceptance. Its other demand lines, summaries
and pending counts stay unchanged. The complete verdict audit now covers 291
transitions in twelve goldens, including the previous 284 unchanged transitions.
The source fixture and its browser-inline report are unchanged.

**What I learned**

A newly added platform fixture can carry the old renderer refusal even when
its optimization preserves every analysis fact. Its report needs the same
entry-row transition as the older corpus; the shared split implementation
needs no change. No measurements were run.
