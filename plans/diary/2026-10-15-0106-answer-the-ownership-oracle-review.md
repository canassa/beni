## 2026-10-15 01:06 CEST — Answer the ownership oracle review

**What I did**

PR #113's Claude review found no blocking defect. Made the callback `xres`
guard read `ex.deep` explicitly and confined the branch-escape mutant to the
escape row, retaining prior calls and uses. The full Lean build and targeted
branch-escape control pass; the control still finds three disagreements.
Kept the conservative single forged site and the selected evidence logs:
they are intentional negative-control and reproduction choices. Verified that
all 159 numbered headings in the ownership design document keep their numbers.
GitHub CI on the implementation commit also passed.

**What I learned**

A compatibility coercion can keep existing code working while making a new
classification less obvious to a reader. Keep the two certificate guards
explicit at the point where a callback's class is queried. A planted escape
hole should preserve unrelated summary rows so its witnesses test that rule.
