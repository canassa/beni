## 2026-10-20 03:07 CEST — share points-to site sets in a hash-consed table

**What I did.** Issue #496: `Pts.Sets` in `src/js/Spec.zig`, the content-addressed set table
`backend.md` §9 *Cells* specifies. Every set a var takes and every union and difference is one
entry; `joinNow`'s batch is an entry, and an operation on two ids is memoised, so copies of a var
(the handlers' `$before = $model`, the arms' locals) share each grown set instead of each keeping
its own. Var and `Val` sites stay slices, so nothing outside `Pts` changed. A unit test that two
vars fed the same batches share storage and an earlier read keeps its slice; the corpus case
`emit/release/inline/SpreadArms` (29 children × 6 messages), 4 537M instructions before (over the
budget) and 3 843M after, golden blessed by the base compiler. Gates green, run hashes unchanged.
An *As built 2026-10-20* note in `backend.md` §9 has the numbers.

**What I learned.** Storage was 20–117× too big (`spec_pts_set_words` N=64 175.6M → 1.50M, the
no-`withDefault` build 57.7M → 1.25M), but it was not most of the time or the memory: RSS falls
15–18% and time 3–10%. What is left is the copy-edge worklist, one pending join and one
containment test per var per batch, and that is linear in vars × batches whatever the storage.
Instruction savings sit at about 17% across every shape I generated, so a case that fails before
and passes after has to be sized to the budget (29 children: 4 537M → 3 843M; 28 already passes
before). The scratch-then-intern pattern matters: interning a caller's slice must copy, since
callers hand in stack temporaries (`&.{site}`), and only an entry's own slice may be looked up by
address.
