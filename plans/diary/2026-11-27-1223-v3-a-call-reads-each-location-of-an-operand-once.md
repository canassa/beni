## 2026-11-27 12:23 CET — v3: a call reads each location of an operand once

**What I did**

- Worker `own3-speed`, issue #2567, branch `own3-speed-2567` on `ownership-v2-design-review` (base
  e22c75218e). `loop t k = if k ≤ 0 then t else loop (step t) (k - 1)`, where `step` is a `case` over n
  constructors with two lists each, was judged at n = 12 and passed the budget of `loop` (1.66 M units)
  at n = 13. The dump's `total` said `pending 0, rejected 0` beside `limits 1`.
- Cause, measured with callgrind and with a temporary count of units by the caller of the counter:
  the recursive call writes all 2n locations of its argument, each write is tested against every other
  location of the operand (kernel §5, test 2), and the test walked that location's value again for
  each write: (2n)² walks in each round, and the group takes n rounds (2n where n is odd, which is why
  13 failed before 14).
- Kernel §8, written first: *A call reads each location of an operand once for all the locations that
  it writes*, and *A limit in the dump*; §9 has the row of the safe-build check.
- Code: `Frame.otherLeaves` keeps the first read of an operand's location while `applyAt` judges the
  writes of one call, under the judging context and time, and copies it at each later read (1 unit and
  1 for each atom). It keeps no read under a set of the callee's paths, and none that met a function
  value or a value of no claim. A call that writes one location keeps nothing. A safe build reads again
  at each copy and compares the two as sets of atoms (`checkOtherLeaves`). `Enforce.writeReport` is
  v3's own writer of the dump: each limit is one pending demand of its module and of the total.
- Tests: `run/LoopOverCaseOfConstructors` (14 constructors: the base stops on the limit, the fix accepts
  it and prints the same under `--sanitize-lists`, `--lists-in-place` and a release in place); two
  black-box tests in `check_test.zig`; two sweep generators, `constructor-loops.mjs` (165 programs) and
  `two-writes.mjs` (69 programs: a callee that writes two locations of a constructor, a record or a
  tuple, where the operand is fresh, named, a join, an answer, a parameter, a part of a larger value,
  or holds one list twice), each with dead and live twins. The fixture is at 14 and not at 16 on
  purpose: the walks of `loop` take 871 018 units of 1 658 496 at 14 (52 %) and 1 229 764 at 16 (74 %),
  and other work changes what a walk costs.
- Evidence: the walks of `loop` at n = 12 take 590 480 units where they took 1 422 080. Dumps of the 2 586 roots: 2 579 the
  same, 7 differ only in their `total` and `demands` lines (the roots with a limit), none in a verdict
  line. The safe compiler's dumps of all roots equal the fast one's and its check never fired. Ledger
  309 of 319. Four-leg oracle on the sweep: 0 faults; against the base 8 dead twins go from LIMIT to
  SAME and 12 live twins from LIMIT to REFUSED (all at 14 and 16 constructors), and no other verdict
  moves; on `two-writes` the base and the change agree on all 69 (18 SAME, 51 REFUSED). Dumps of 7 829
  programs of seven existing sweeps (records, dicts, cells, recursive-levels, aliased-arguments,
  wider-functions, function-values, alias-ctors; the large ones sampled), base against the change: no
  byte differs. v3 on the 33 real roots, ReleaseFast LLVM, alternated, least of 5 rounds: 2 353 ms on
  the base, 2 342 ms with the change. The dump of the loop itself, least of 25: 55.2 against 54.2 ms
  at 12 constructors, 55.4 (the base gives up) against 57.2 (judged) at 14.
- How often a kept read is copied, counted by a temporary build with the check on: 646 784 copies in
  2 363 of the roots (80 in each from `core/`, 744 where the browser platform is walked, 188 561 in
  `ownership/WideFieldConditions`), 1 069 040 in the constructor loops, and about 100 000 in each of
  the sweeps. The check never fired.
- The review branch moved by 157 commits while I measured (to 127cce0419: a master merge, and
  `browser-inline` now names the checker v3). The change rebased with no conflict. I repeated on the
  new base: the gates (green), the dumps of its 2 944 roots (2 936 the same, 7 with other totals, and
  the new fixture, which the base stops on), the safe compiler's dumps (equal, no check fired), the
  ledger (310 of 319 on both) and the four-leg oracle on both sweeps (the same 20 moves from LIMIT,
  0 faults). The units and the times above are from the old base.
- Not reached: 13 constructors (26 rounds) and 20 or more. With the budget lifted the loop needs
  1.96 M units at n = 13, 2.22 M at 20, 3.65 M at 24 and 16.6 M at 40. What remains at 40 is the
  duplicate test (32 %), the pairs of a write and another location (28 %), the walks of values (16 %)
  and the removal of repeats (9 %). The options are on the issue.

**What I learned**

- The work of this fixed point is at least rounds × locations × sources, about n³: the settled
  contract of `loop` has 2n locations with n sources each, and each round reads them all. No memo
  makes it linear. The budget of a declaration does not grow with its rounds, so the question of 20
  constructors is a question of what a member of a recursive group earns, which is the owner's.
- The first version of the fix switched the kept reads on for every call, and `examples/todo/page`
  looked 10 to 30 % slower in three noisy rounds. With the store on only where a call writes two or
  more locations, five rounds show no difference. A hash store that is cleared at each call is not
  free where nothing is ever read twice.
- A safe-build check that counts no work reads no context of an arm (`quiet_n`), and can keep one of
  two atoms that differ in their contexts alone. So the kept read and the new read are compared as
  sets of atoms without contexts, not atom by atom.
- I patched the sources for an analysis build while a background job was still in `nix develop` and
  had not started its compile. I stopped the job and ran it again. A job reads the sources about a
  minute and a half after it starts: wait for the `zig build-exe` process before any edit.
- "The check never fired" says nothing until the copies are counted. My first count showed that
  almost every copy on the real roots came from 16 calls inside `core/`, the same in each root, and
  that no existing sweep has a callee that writes two locations of one argument. I wrote the
  `two-writes` generator for that shape. My first comparison of the sweeps was also empty for each
  program of two files: `dump` takes one file or a directory with `--root`, both compilers failed the
  same way, and the script called that "same".
- The corpus compares the checkers v1 and v2 on each `run/` program, and each difference must be in
  `tests/blackbox/ownership-v2-known.txt` with its reason. My fixture has 81: v1 has a demand for each
  list of the argument where v2 has one that names them all, and v1 has a demand for each list of
  every constructor of a built argument where v2 has the two of the constructor that it is.
- A global table for an analysis build is not safe with `--jobs` above 1: 214 dumps of the counting
  build stopped in the table's own lock check. The compiler under test was not the cause.
