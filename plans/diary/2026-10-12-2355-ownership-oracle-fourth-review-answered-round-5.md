## 2026-10-12 23:55 CEST — ownership oracle: fourth review answered (round 5)

**What I did.** Answered the fourth review on PR #65. The invariant ties every closure at a field or
element path to its own declaration (a writing closure described as a reading one made the step lemma
false); the falsifier mislabels closures, aliases written variables and runs a quarter of samples on
low fuel. Shrinking no longer overflows the stack (candidates on small fuel) and a mismatch is flushed
and saved before shrinking; the mutant runner flags crashes. The audit reads compiler attributes of every
constant and bans elaboration-time code and qualified spellings. A forked agent added many-off,
shared-fn and no-scope controls, reached xres, tsupplyexcl, callback-escapes and forward-guards, and
re-ran all 55 source edits on the final generator: 41 caught 3/3, 12 argued equivalent (verdict
counts), two gaps no generated program can reach (no-scope, hiddencopy).

**What I learned.** A miss and a crash look alike unless the runner says which; two "uncaught" holes
were crashes. Counting the verdicts a mutant changes turns an equivalence argument into a measurement.
