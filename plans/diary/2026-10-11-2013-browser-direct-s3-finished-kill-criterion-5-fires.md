## 2026-10-11 20:13 CEST — browser-direct S3 finished, kill criterion 5 fires

**What I did.** Rebased S3 onto master; withdrew the accumulator-loop rule on the owner's
decision (reverted with its fixtures, dated notes in `backend.md` §8 and `browser-direct.md`
§7.2, §11, §13, §14, `compile-away.md`); rewrote the table app's `buildFrom` (and P3's verbatim
copy) to count up and push with `[ …rows, row ]`; added the `filtered` sweep and S3 size maps;
ran one batch — the table app on six subjects, `FilteredFor` at 100 and 1 000, B1 bytes on both
platforms — and wrote research 70.

**What I learned.** Kill criterion 5 fires and the P3 criterion fails: 4 524 B (non-core 3 783),
the swap 2.1× vanilla and 2.6× P3 because the rank rule turns the index guards' rekeys into a
full reconcile, `select` only 24 % faster than P3. Building in order without the rule made
`browser-tea`'s table bundle 26 B smaller than with it. The machine was loaded (up to 21) during
the table batch; the verdicts do not rest on the noisy cells.
