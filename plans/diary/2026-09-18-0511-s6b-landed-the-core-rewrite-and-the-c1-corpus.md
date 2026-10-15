## 2026-09-18 05:11 CEST — S6b landed: the core rewrite and the C1 corpus

**What I did**

- **Pre-order sites** (`8081b5f`): the S6a cursor exposed that a call with two
  constrained slots that each nest was numbered breadth-first, so `pair [[1]]
  [[2]]` under `where a.eq, b.eq` ran wrong with exit 0. Fixed with a parent
  link per site and a pre-order sort in `Dispatch.finish`, not by changing the
  drain — the drain alone could not have worked, since both slots are
  numbered by one instantiation before either is discharged.
- **S6b** (`5dfc082`, one commit as planned): `Dict`/`Set`/`List.sort` on
  `where k.compare`, `Dict.empty` a constant, `Dict.String`/`Dict.Int` deleted
  with all 24 use sites, `List.compare` foreign, the six `bench/corpus` files
  and three runtime programs rewritten by hand, the derived-body refusals
  removed from the backend. Reviewed against C0 with eight probe programs
  whose output was byte-identical on the `c870e9a` binary. Two checker
  defects surfaced under the rewrite and were fixed at the cause: a rebuilt
  constraint set stranded its inputs as live obligations (A.75, a redirect map
  journalled for `tryShape` rollback), and a joined constraint instantiated
  its callee's nested evidence for the first instruction only (A.76).
- **Measurements** appended to the results file: the `--dispatch` generator
  goes from 1 682 diagnostics to 0; M3 annotated rows stay at 0 interface
  changes on both corpora; M4 floor +5.5 % with derived `eq` 1 050 B and
  derived `compare` 1 889 B reported separately, about 200 B per derived
  function on the bench corpus; M5 R1–R3 flat within round-to-round spread
  with identical checksums; M8 17→0, 15→4, 7+17→0, two modules deleted.
- Fixed a harness flake: `bench/churn.sh` passed the corpus copy as a bare
  positional, and a tmp-dir name beginning with `-` was parsed as an option
  about once per 32 seeds. Now `--` precedes it.

**What I learned**

- **The corpus rewrite was cheap; the checker under it was not.** Every
  blocking finding in S5–S6b was in `Solve.zig`'s constraint bookkeeping, and
  every one was a *pre-existing* S3 defect that only a richer program shape
  could reach: nested constrained calls over a `let`-bound seed, two names on
  two variables, list keys. Report 19 should say that the table design held
  and the obligation plumbing needed four passes.
- **"Answered exactly once" needs an identity, and a constraint index is not
  one.** Sets are append-only ranges, so every rebuild changes the index;
  anything keyed on it (obligations, `resolved_methods`, `deferred`) must
  follow a redirect. This is the same lesson as the `evidence_index` key,
  one level down.
- **Structural `==` on `Dict` compares tree shape.** With four insertions in
  two orders `==` answers `False` while `toList` agrees. Left for report 19
  as a language decision (O-5), pinned by `run/DictStructuralEquality`.
- S7 is pin-and-close: the feature landed across S2–S4; what is missing is
  fixtures for the untested mechanisms (result-only quantifier across a
  module boundary, forwarded return-position evidence, the `.any`
  undetermined arm) and a §4.1 citation that names a Roc syntax which does
  not exist.
