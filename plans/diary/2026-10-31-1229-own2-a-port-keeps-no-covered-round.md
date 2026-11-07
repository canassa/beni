## 2026-10-31 12:29 CET — own2: a port keeps no covered round (spec)

**What I did**

- Measured the canonical-port question of #1372 and #1368 in scratch copies of master `fe086e557`, of
  master with #1459, and of 5a's side branch `b030bedcc`. I used instrumentation that dumps every port's
  DAG and every expensive `propagate` call's states, and a scratch analyser. The analyser counts each port
  raw, hash-consed, with choices as arm sets, and with unions as sets.
- Found that most of a group's port is the history of its rounds. The join keeps every earlier round,
  although the last round covers it.
- Prototyped the fix in `Summary.join`: a side, or an arm of a side's top choice, that the other side
  covers (`Shape.leq` and `kappaLeq`) is dropped.
  - `mergeSort`: 168 829 → 38 477 records, growth 0.
  - DerivedDeepPaths' `rose` on 5a: 177 371 → 45 507.
  - `descend`: −59 %.
  - Over all 2 043 roots, no verdict changes, except that limits become checked. The corpus's records
    fall by 5.5 %.
- Wrote it as §2.3 *A port keeps no round that its last round covers*, with §8's rows 4d and 4e and the
  outcomes for #1368, #1372 and questions 8 and 9.

**What I learned**

- The rule is exact for a join, but not for the fixpoint. Widen is not invariant under representation,
  and the history made it coarser. #1423's `wa`/`wb` on 5a's branch then do not settle: raw, their port
  grows 196 → 548 nodes, but as union sets it stays at 67. A guarded variant, which takes the smaller
  value only when the two are `leq`-equal, did not help either. That choice is the manager's, and it is
  recorded as option (a) or (b) in §2.3.
- `removeMin` and `descend` are not port-bound. `removeMin`'s round-2 port has 119 nodes, but walk 2
  unfolds 63–125-node DAGs into 29 624 positions. That is #1465's F2 regime.
- The no-cycle fold was not needed for `mergeSort`. It would also change κ, because a cycle through
  `positions` reads `repeated`.
- When a scratch merge or `git apply --3way` hits a conflict, it records a rerere preimage unless you
  pass `-c rerere.enabled=false`. Run `git rerere clear` afterwards.
