## 2026-10-15 09:45 CEST — Confirm the row regression proof and review limits

**What I did**

The final Claude pass found no blocking defect. Repeated the row-clock proof
with the shared row-fact fix explicitly withheld: TemplateClockRows fails with
tea's stale 0 against direct's 500 in the shrunk sequence, and passes after
restoration. The earlier red-first observation is therefore also reproduced
against the committed fix. Commented the sole epoch-emission call site's
send-guarded-entry requirement. Made the visit oracle's dependence on analysis
masks prominent in research 95's validation section, alongside the separate
DOM/value-fuzz backstop. These final edits are comments/documentation only.

Linux CI passed on functional head cbef7c6aa (run 38700246093), with its configured
budget disabled. The hardware instruction-budget gate remains owed and stays
explicit in the PR body. All review points are answered; keep the PR draft
and unmerged. The user-owned review plan remains untouched.

**What I learned**

An oracle independent of execution selections still depends on correct
analysis masks; paired behavior and value fuzz are necessary alongside visit
verification. Green hosted CI checks Linux behavior/hashes, not the hardware
budget. Criterion 7 passing settles the visit mismatch, not the larger output
or the lack of a demonstrated speed win against tea.
