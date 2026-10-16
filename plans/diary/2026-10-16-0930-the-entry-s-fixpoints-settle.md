## 2026-10-16 09:30 CEST — The entry's fixpoints settle over finite cells (#229)

**What I did.** Found why the model's exclusivity invariant never settled and fixed it, per the owner's
decision on #229. Instrumenting T29 showed the cells each round appended were all closures: §24.9's
`carry` made a new closure for a lambda a callee's result carries at every instantiation, and `update`
returns its commands' lambdas, so every round made two new cells and `cell_cond` was longer than the
round's starting copy. Every other cell instantiation makes was already named by where it is made. A
carried lambda is now one closure per site (call, callee summary, lambda, depth, namespace, merge flag),
its captures the union of every instantiation's, restored by snapshot/restore like the rest; a round has
settled when it makes no cell, grows no carried lambda (`carry_grew`) and moves no condition. The walk's
five fixpoints — model shape (was 8 rounds + silent `⊤`), invariant (32, silent `lost`), callback result
and fold shape (4, silent `⊤`), fold spine (32, silent `lost`) — share a new `fixpoint` limit of 32,
reported as `ownership_limit` at the declaration, shapes adding `⊤limit`. Summary blocks v13. Spec:
§16.7's table and §28's dated amendment *the entry's fixpoints settle*; §26.7 row. Fixtures:
`ownership/EntryInvariantCommand` (rejected on master, accepted), its shared twin (rejected both),
`ownership/EntryRelay` (a nine-field relay: master's 8-round `⊤` made an unrelated edit "from JavaScript";
accepted), `ownership/CarriedFold` (master's `at` summary had `~⊤{lost}`), and
`build/bad/direct/OwnershipEntryRounds` (33 fields, 35 rounds: the loud limit).

**What I learned.** Rounds to fixpoint over 948 programs plus core and the platforms: model ≤ 4,
invariant ≤ 2, callback ≤ 3, fold shape ≤ 3, fold spine ≤ 2; the dashboard to N = 1 024 needs 3 and 2.
No verdict in the corpus, examples, bench or dashboard moved — the dropped proof had not been deciding
any of them — but the backstops did cost the new fixtures above, and one summary in `bench/corpus`.
Instructions (ReleaseFast, `check --jobs=1 --no-cache`): Conduit 142.9M → 122.0M (−15 %), peak RSS
25.3 → 22.3 MB; TodoMVC 36.9 → 36.2M; dashboard N = 1 024 unchanged at 42.7G. Wall times were useless
under a load average of 60. A relay chain shows the rounds really do grow with the program (n + 2 for n
fields), so the cap is a limit of the compiler, not a backstop: past 32 it is an error. The Lean model
already names cells by site and fails non-convergence loudly at 24 rounds; the bridge at its CI bound
(1 341 programs, 959 translated) confirms nothing unsafe.
