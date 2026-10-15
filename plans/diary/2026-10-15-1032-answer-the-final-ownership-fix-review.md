## 2026-10-15 10:32 CEST — answer the final ownership fix review

**What I did**

The second explicit Claude review found no blocking correctness or evidence
accounting defect. Answered its residual notes: kept the fail-closed top fallback,
explained the deliberately asymmetric loan/result checks, and documented that
exact baseline equality is asserted only for canonical CI/long populations.
Separately replayed all 220 historical divergent minima; all are refused using
only list_still_used diagnostics. Retained those results without adding them
to the original-program counts. No checker source changed after the campaigns.
PR #124 is ready for review and remains open and unmerged.

**What I learned**

A replay audit can safely support custom populations while stating explicitly
that they make no baseline-equality claim. Historical minimized programs remain
useful additional regression probes, but their changed inputs must never inflate
the number of confirmed original witnesses.
