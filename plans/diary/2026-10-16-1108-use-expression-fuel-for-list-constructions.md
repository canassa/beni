## 2026-10-16 11:08 CEST — Use expression fuel for list constructions

**What I did**

Removed the in-place interpreter's tick for each later-spread element, as Cesar directed in dashboard q3.
Kept both growth checks and the bounded loop.
Changed the retained closed regression to prove equal traces and equal remaining fuel.
Recorded the former counterexample to `accepted_traces_agree` in `COVERAGE.md`.
Recorded the q4 decision: read-only view/source splits are legal.
The required enumerator check concerns a write while the other side remains live.

**What I learned**

A construction's internal loop must not spend expression fuel.
The value interpreter defines that schedule.
The closed fuel-5 counterexample refuted the public main theorem, beyond the invariant's fuel clause.
The three general soundness obligations remain open.
The coordinator requires a shared build lock and a systemd memory cap for every heavy command.
