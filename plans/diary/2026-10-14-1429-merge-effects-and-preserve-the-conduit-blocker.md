## 2026-10-14 14:29 CEST — merge effects and preserve the Conduit blocker

**What I did**

Marked PR #89 ready and rebase-merged it with the owner's timing deferral.
Started browser-direct-s6 from updated master. Pinned all three unchanged
Conduit script projects with their original budgets and one exact diagnostic
signature each. Added nested-key and opaque-update composition twins, verified
on both platforms in development/release, happy-dom and Chrome, with value
fuzz and ten recorded hashes. Re-ran the analysis/browser-tea stats baseline
and recorded research 92. Gates have only the four authorized macOS failures.

**What I learned**

Conduit still hits approximate view-event payload ownership for four nested
errors lists. Direct's application cannot build, so its bytes, timed messages
and built-platform dispatch comparison are blocked. The analysis has 96/97
bounded keys; browser-tea's dynamic count is unchanged at 9/62 unknown-key
dispatches. Independent composition coverage is green but does not complete
the blocked slice or replace its second full adversarial campaign.
