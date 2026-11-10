## 2026-11-10 02:29 CET — a call's mixed condition is instantiated once (#2418)

**What I did.** Worker `ownership-v2-fable`, epic #1006. While building S5 (records, #1018) four corpus
programs reached `ownership_summary_size`, and the cause was not S5: on master a chain
`s_k = keep s_(k-1) { list = [ k ], model = [] }`, where `keep` answers a record of its argument's
fields with one list field pushed, costs 4 324 records at 4 calls, 48 571 at 8 and the limit at 12,
with no write refused. I filed it as #2418 and counted the check's steps: the pair relation stays
small (30 pairs at 8 calls), `instCond` misses once per call, and `instSelOn` runs 71, 265 and 1 035
times at 6, 8 and 10 calls. The caller is `PlainReach.instCondMixed`: a check that holds apart and
plain entries of one call asks the callee's condition with some occurrences marked apart, at each
round in which the call's group gains entries, and each asking instantiated the condition on the
call's arguments again, a check of the call before it. `CondOnce.zig` (L6) keeps the value by call,
mode, `keeping` and the marked selection for the evaluation. The chain is 3 520 / 10 731 / 38 264 /
147 163 / 556 424 records at 4 / 8 / 16 / 32 / 64 calls, growth 0 up to 32. Fixture
`ownership/StateChain` (12 calls, the limit on master), a counted test at 8, 16 and 32 calls, mutant
`mixed_memo_off`, §2.9.1 amendment.

**What I learned.** The account line prints its categories only when a declaration has growth, so
a declaration that dies inside its continuation shows nothing: raise `@ownership_summary_size` on
the declaration to see them (`cond` was 8 of 13.6 million records at 16 calls). The first guess,
the pair relation's product in `apartIn`, was wrong; counters at each `cond` charge found the real
step in three builds. `instCond` had its memo from the start and the mixed twin beside it had only
a guard against re-entry. A strict check's `hoped` is a side effect that a kept value must replay.
What is left is quadratic: twice the calls cost 3.8 times the records, and the chain that pushes
onto a plain list does the same on master (11 940 at 16 calls, 42 679 at 32).
