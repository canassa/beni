## 2026-11-02 18:43 CET — own2 slot domain: tests lane, third session (stopped at the cost wall)

**What I did**
- Probed the four remaining "v2 accepts where v1 refused" rows. SplitCap's probe trapped: a callback label passed on
  through a callee whose supply slot is a type variable's (`apply : (a → b), a → b`) took a record argument as one
  arrival at the root, so the callback's `.f0` write checked nothing, and the record's parts were never judged
  against each other or later uses. Fixed in Eval's read-off of passed labels and in Resolve (each part judged as a
  direct label's argument), §2.11.3 amended, fixture `run/SanitiserPassedLabel`. 200 oracle probes, no trap.
- Regenerated the known list by category (642 stale, 2 303 new), the `.v2.unchecked`/`.v2.ownership` goldens and
  the run hashes; filed #1713 for 89 refusals outside #1704.
- Added the experiment's seven requirement fixtures (`ownership/Slot*`).
- Ported build_test's 96 failing v2 tests with three forks: 32 ported, 3 deleted (subject gone), 64 still fail on
  their cost property. Filed #1714 and stopped under rule 10.

**What I learned**
- The corpus harness read `ownership-v2-known.txt` with a 1 MB limit and `catch ""`: past 1 MB it would have
  read an empty list silently. The list is now about 1.07 MB, and the limit is 4 MB.
- The verdicts of the slot domain hold up under the oracle. Its cost does not: towers that were n log n are quadratic,
  doubling DAGs are exponential, and many per-call or per-field flat costs are now linear. The corpus has headroom
  and hides this. The cost tests in build_test are the only place that shows it.
