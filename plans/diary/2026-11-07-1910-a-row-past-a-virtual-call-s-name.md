## 2026-11-07 19:10 CET — a row past a virtual call's name

**What I did.** Rebased #2175 past #2173: `Replay.inside` went into `RefRead` and the choice of a supply's type into `Virtual.make`, with master's mutants kept. Ran the whole bar at that code. `X1`–`X6` are refused, and every generator has no TRAP and no DIFF.

**What I learned.** Merging master once and squashing took one resolution; rebasing ten commits past a moved function took one per commit. A diff3 conflict has a third section that a two-way pattern leaves behind, so read the file after a scripted resolution. Comparing a head with a head hides what master did: 780 refusals looked new until master past #2173 refused them too.
