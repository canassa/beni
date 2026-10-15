## 2026-09-23 23:28 CEST — row 76: cyclic receivers end the drain; `pub` in the §10.12 hint

**What I did**

- A review found a regression: `pairEq x y = let inner a b = a == b in inner x y
  && inner [ x ] [ y ]` panicked on 875f623 after 2^20 drain rounds (about
  10 s). On the round 3 tree it never finished. Cause: a constrained `let`
  helper is monomorphic (§11), so the two calls make `x ~ List x`. The occurs
  check waits for generalisation, and `List.eq`'s `where a.eq` re-asks for
  the element's `eq` forever. Instrumenting showed the round 3 tree's drain
  ending after about 100k rounds, not the 2^20 that panicked. A `sample`
  of the hung process showed it inside `Dispatch.Builder.finish`, sorting a
  huge number of sites for one instruction. So each pass wasn't slower; the
  endless chain now leaves its output in the dispatch table, and `finish` is
  superlinear in it.
- Fix: `Obligation.depth` records how long the discharge chain that raised an
  obligation is (`Solver.discharge_depth`, stamped in `register`). Every
  `cycle_check_depth` (64) generations the drain runs `occurs` on the
  receiver. A cyclic one is reported `infinite_type` and poisoned. All four
  reported bodies now fail with `infinite_type` in under a second. It is a
  real error: the program is not valid under §11's rule.
- `method_needs_annotation`'s hint now carries `pub` when the method is
  `pub` (`pub eq : T, T -> Bool`); the fixture's `.diag` was re-blessed.
- Recorded queue row 77, the Tree/record hidden-argument miscount (same on
  875f623; not fixed). Row 75 now notes that eq-before-compare is the common
  case, so the method-group ordering is the next step.
- New fixtures: `check/bad/LetHelperCyclicReceiver`, plus an `abuse_test.zig`
  scenario over all four bodies with an 8 s limit. The round 3 binary times
  out on the fixture at 15 s. Gates: 468/468 unit, 289/289 black-box (33/33
  steps), fmt-check green. Nothing committed.

**What I learned**

- "It hangs" and "it loops" are different claims: sample the process before
  guessing. The loop had become finite. The cost had moved into a later
  phase that is superlinear in what the loop leaves behind.
- A deferred occurs check means every consumer that walks a type between
  unification and generalisation must survive a cyclic graph. Charging the
  check to obligation generations keeps it off the hot path.
