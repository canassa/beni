## 2026-10-22 04:11 CEST — Preserve current master ownership verdicts

**What I did**

Opened #672 for #670, then integrated current origin/master after the PR
reported a conflict. Preserved the representative-prefix correction's
PolyRecCps verdicts and refreshed only extent annotations. All 105 existing
reports differ from current master only by those annotations. The full
unfiltered self-hosted gate passed again on dagon on the resolved tree.

**What I learned**

The concurrent representative-prefix correction added ownership evidence
while this fix was being validated. Comparison must use the current master
verdicts, including that correction. No unexpected verdict changed. No
measurements, budget changes or local builds were used.
