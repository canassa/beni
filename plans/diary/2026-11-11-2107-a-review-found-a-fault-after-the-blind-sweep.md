## 2026-11-11 21:07 CET — A review found a fault after the blind sweep

**What I did.** Worker `ownership-v3-round2`, the same session as the entry of 17:40. After the push of
round 2 (pull request #2451), the second review read `argsApart` in `src/own3/Frame.zig` and found, with no
program, that it read a value that is no tuple, record or constructor application as one part. Seven
programs from that finding: five trap on the pushed code. A handed function over a tuple `( q, q )` that is
one arm of an `if`, or that is ten levels down in a nest, was accepted. I fixed it: `partsOf` has one case
for each kind of value in a `switch` with no default, and `sourcesApart` rests on the check of the arguments
for two parameter sources. I ran each sweep, report 111's generators, the sanitiser corpus, the real roots
and the gates again on the fixed code, with a ReleaseFast and a ReleaseSafe compiler: no trap. Research
report 112 has a new section (§6.5) and a new verdict for the border with the first-order core: "unclear".
`aliased-arguments.mjs` has three more alias forms (5 160 programs).

This entry corrects two figures of the entry of 17:40. The search by hand has 121 programs in seven rounds,
and 20 of them trap. That entry said 97 programs, five rounds and 15. The fault of the border has five
forms in five rounds of fixes. That entry said four.

**What I learned.**

- A blind sweep by the author of a fix is weak evidence for the fix. The sweep of 3 870 programs found no
  fault. Its dimensions were the forms that I had thought of, and the check followed each of them. A reader
  who did not write the code found what 3 870 programs did not. Ask for the review before the report has a
  verdict.
- I had probed the same `if` form by hand before the push, with no function, and each program was refused.
  The refusal came from another check, which was coarse. A probe that is refused says nothing about the
  check that it was written for, unless the cause of the refusal is that check.
- A predicate on a value needs one case for each kind of value, in a `switch` with no default. `partsOf` had
  a case for a construction and one "anything else". Each fault of this corner was a kind of value that fell
  into "anything else".
- A reviewer's one-line fix can be wrong while the finding is right. The fix asked `allLeaves` for a
  duplicate. `allLeaves` reports a cell that is two times in one summary location, and `( q, q )` has the
  list at two locations. Write the program for the finding first, then the fix.
- A limit that has "no claim" as its result is sound and has a price. `partsOf` stops at a nest eight levels
  deep, and that costs 78 safe programs of `recursive-levels.mjs`. Compare each program's verdict with the
  run before, not only the count of traps: the count of accepted programs went up by six while 42 programs
  went from accepted to refused.
- A speed figure that is measured while two sweeps run on the same machine is not a figure: 874 000 lines per
  second under load, 958 000 on the quiet machine, for one build.
- A verdict can go back. The report said "unclear" for the border, then "held in one blind sweep", then
  "unclear" again after the review. The last one is the true one, and the report says why.
