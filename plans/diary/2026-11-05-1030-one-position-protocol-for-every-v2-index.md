## 2026-11-05 10:30 CET — One position protocol for every v2 index

**What I did**

- Finished #1963 on `own2-slot-pr` (`c3de3957dd`), from a stalled agent's
  work in progress. The distinct check's index (used past eight entries),
  the holder buckets (`Sweep.Live`) and the pending operands
  (`Stack.Index`) each walked positions by hand and never met a `[*]`
  position with a front, back or slice one. Now `Steps.zig` holds the
  step relation `Frame.related` uses, the classes that may meet
  (`meetClasses`) and one protocol (`fileUnder`, `askFor`, and
  `PosLists` for Sweep and Stack). Entries keeps its own keys but files
  and asks through the same two functions.
- Two unit tests: `meetClasses` lists exactly the classes of some related
  pair of steps; and over a tree of every step class, the shared storage
  and Entries' keys meet every pair `Frame.related` relates (and an
  unrelated one only where a slice's indices part them). Removing `.elem`
  from `.front`'s classes fails the second test.
- Fixtures `run/SanitiserWideDistinct` (refused; traps on the base) and
  `run/SanitiserWideDistinctApart` (accepted). Spec §2.3.2 and §2.9.3
  amended in place.
- Evidence: probe sets (h4's 1 015 dirs plus `pp/` and new ones, 1 083 in
  all): 0 TRAP, 0 DIFF; on the base the 7 TRAPs were the issue's probes
  and the fixture. Ledger by root name vs `a6c05c32bc`: a2r 3, all the new
  fixture's refused edits; r2a 0. Vs master's v2: the same figures as the
  base. Cost table: growth unchanged everywhere, no limit lines; totals
  up 1–5% (more lists asked per query).

**What I learned**

- No program I could write reaches a `[*]` position in the Sweep or Stack
  index: holders and pending operands key a parameter at its root or at a
  front, back or slice position, and a spread's elements are projected to
  front positions before a demand sees them. The temporary prints showed
  both indices are queried (front and back queries), but the new class
  pairs were never non-empty there. The fix there is for consistency; the
  unit test is what checks it.
- `beni fmt` rewrote the fixture's long `main`, which moved every pinned
  `line:col`; re-pin after formatting, not before.
