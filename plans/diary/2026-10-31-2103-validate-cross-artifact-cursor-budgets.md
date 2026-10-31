# Validate the cross-artifact cursor budgets

## What I did

Reviewed the owned cursor checkpoint on top of fef928da4, including the
independent review and source patch b4213661af49ec5babf86e04e7dc052916b26de0b64abd7903875da5680150bd.
The source tree 43cedeac98c3a94fa4680d8d6dd9f97803f188cd had already passed the
full unfiltered development-Zig gates: 318 steps, 2173 tests passed, 17 skipped.

Kept the original failing full-CLI matrix and the interrupted repeat. The first
matrix had four candidate and four baseline builds at or above 800 ms, so it
was not accepted. A corrected all-UID process guard found unrelated Dagon
compiler work; this does not establish causation for those earlier failures.
The second full matrix stopped after nine rows and supplies no acceptance rows.

Reviewed the frozen segmented protocol before execution: eight indivisible
configurations in the original fixed order, each with one baseline/candidate
warmup pair and three alternating measured pairs. No old rows were reused.
All owned work paused during these windows. Each configuration had a fresh
before/after guard and a sibling-CPU monitor sampling every three seconds.
All eight completed first attempts; all 64 commands exited successfully.
The 24 candidate measured builds were 140.768595–566.284925 ms, each below the
unchanged 800 ms budget. Every complete output tree matched within its
configuration. Independently rehashed 62,480 output files (161,657,664 bytes),
checked every raw row, argv/order, source and compiler hashes, 16 clear guards,
12 clear monitor samples, and the exact timer-method receipts.

The controlled checker repeat also passed all twelve measured rows and four
warmups: plain 301755–302733 microseconds (median 301958), dispatch
289993–290247 (median 290147). Its nine monitor samples found no blocker.
Earlier ordinary and inspector matrices retain all samples and output receipts;
the inspector adds work and its output is not a speed-equivalence comparison.

Parent evidence is retained under the Dagon manager scratch cursor-planning/.
The final full-CLI aggregate SHA256 is
54f449e6e3413e16b041e156a9c6a3e200818e31e1ac46eda7e768668e1cb957.
The independent receipt is manager-segmented-full-cli-verification.json.
All previous failed or held attempts remain available for review and archival.

## What I learned

These are sampled quiet windows, not continuous proof of a quiet machine.
Separate configurations ran at different times and may have different OS or
thermal state; no cross-configuration speed claim follows. The individual
build budget, inputs, compiler settings, units and timer were unchanged.

This checkpoint provides the finite owned cross-artifact cursor and its
regressions. It does not certify generated control bodies, Wire, realm safety,
Task migration, worker launching, or UI performance. Those remain later work.
A final full unfiltered gate must pass the exact tree containing this diary
before it is committed and pushed to PR #1304.
