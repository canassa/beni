## 2026-11-01 18:20 CET — The v2 sanitiser catches the three fixed bugs

**What I did.** Answered the review of #1555. The poisoned array now takes the
written list's length, so a stale length-only read (`List.length`, a
pattern's `[]` test) prints the in-place answer and differs from the golden.
Each channel write records whether its verdict rests on callers, and each
wrapped site says whether every caller was checked: `whatever its callers`,
`every caller checked` (the whole program clean) or `a caller may be
unchecked`. I added three `run/` fixtures with `.sanitize-lists-v2-refuses`,
one for each of #1516, #1530 and #1523. v2 must refuse each one, and when it
accepts one the sanitised run is the evidence. The sweep generator gained
lists of lists, length-only and shape-only readers, and tree programs with
recursive writers and readers. §7.3 and §8 S8b now carry the manager's store
rule: the writer's module and every module that calls it must be clean, which
for now means the whole program.

**What I learned.** I reverted each fix locally. The sanitiser then caught
each bug: #1516 by output (length 2 for 1), #1530 by output (7 for 0), #1523
by a trap. The sweep at 1,500 programs, seed 1, found no unsafe program with
the fixes in, 6 with #1516 reverted, 59 with #1530 reverted and 32 with
#1523 reverted. Running the v1 list sweep showed a v1 harness mismatch in
`ReadDir`: inner spreads of a chain with interleaved items are wrapped. That
is #1565. The v1 path did not change in this work.
