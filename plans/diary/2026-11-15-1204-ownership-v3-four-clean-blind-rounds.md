## 2026-11-15 12:04 CET — ownership v3: four clean blind rounds

**What I did**
- Managed the v3 checker loop on `ownership-v2-design-review` (PR #2451). The fix rounds were: linear walks with a budget per declaration (report 138), a real in-place build and an identity trap in the sanitiser (report 140), and a group's rounds independent of declaration order plus a release leg in the oracle (report 141).
- Ran four blind rounds in a row (readers J, K, L and M), about 139,000 programs in total. Each program was built plain, under the sanitiser with the identity trap, really in place, and as a release pair. There were 0 traps, diffs, crashes or hangs. That meets the owner's goal of 4 rounds with 0 faults.
- Opened #2514 (a release miscompile: two inlined loops declare the same name) and added the record-pattern case to #2512.

**What I learned**
- A background agent that ends its turn "waiting" on a job is not woken when the job ends. The fix agent sat idle for 5 hours overnight. Briefs now say never to end a turn waiting, and the manager checks the job's output itself.
- The sanitiser could not see identity faults. Only the real in-place build and the identity trap found the `Js.same` row, which did not count as reading its operands. The same hole was in v1 and v2.
