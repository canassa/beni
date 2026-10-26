## 2026-10-26 21:41 CET — One alternative is a link

**What I did.** #1112: a one-element literal, and a join whose alternatives are one member (empty leaves with nothing stored aside), are now that member's snapshot, linked. Nothing below them is walked. The proof is in §2.9: one element is one position; the summary obligations are the reader's, so a built node read at a summary position now owes `excl` for its folded storage arrivals, as a leaf does; and `join` is idempotent, with `yes` its unit. A Rose tower now costs about 90–108 growth records a level, n log n, and 1 000 levels fit under a raised allowance. A tower of joins with an empty alternative is linear too. No verdict moved. Noted the #1100 test bounds on #1097.

**What I learned.** The quadratic came from the joined node not being the member's: `union(r, empty leaf)` is never `r`. The shortcut has to treat "nothing" alternatives as the join's unit, not compare nodes.
