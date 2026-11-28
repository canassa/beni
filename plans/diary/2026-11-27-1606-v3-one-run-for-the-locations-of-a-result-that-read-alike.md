## 2026-11-27 16:06 CET — v3: one run for the locations of a result that read alike

**What I did**

- Worker `own3-speed`, issue #2539, branch `own3-speed-2539` on `ownership-v2-design-review`
  (127cce0419). `Gpu.Engine.checkedAwaitIn` of `platforms/browser-base` walked to its whole budget,
  10.5 million units, and the module was not judged.
- Cause, counted with a temporary patch (units by the caller of the counter, the atoms before and
  after `uniqueTail`, and for each call's result its locations and its distinct runs): the function
  calls `classified classify True value`. `classified` is generic in its answer and answers what its
  function parameter answers, so its result has one wide location whose only source is the answer of
  `classify`. The caller reads it at the 712 locations of its `Result`. Each of them built the same run
  of 711 atoms and removed its repeats (none): 505 524 atoms for each of two calls. With every budget
  lifted the walk needs 14.9 million units.
- Kernel §8, written first: *An expansion that reads nothing of its location is made once for a call's
  result*; §9 has the row of the safe-build check.
- Code: `SrcState.entry_read` is set where an expansion reads the caller's location (a parameter
  source, `pairedLeaves`) or the labels below the callee's entry (the body of a known function,
  `answerOfCode`). `applyAt` keeps the run of the first location for each entry of the callee's result
  whose expansion set no flag, and a later location that the same entry covers takes that run for one
  unit: two entries of the result name one range of atoms. A safe build expands again and compares
  atom for atom (`checkSharedRun`).
- Tests: `run/AnswerAtEachLocation` (256 constructors; the base stops on the limit of `run`), one
  black-box test in `check_test.zig`, and a sweep generator, `answered-through.mjs` (120 programs: 3
  sizes, 4 ways to the function's answer, a function that makes new lists or that answers a captured
  list, a write of the list parameter or of a list taken out of the answer, dead and live twins).
- Evidence (ReleaseFast LLVM): the four limits of `platforms/browser-base` go (`checkedAwaitIn`,
  `Gpu.Diagnostics.Device.forward`, and the module budgets of two modules), and the root's dump is
  byte-equal to the dump with every budget lifted. One write is judged that was not:
  `createMappedBuffer`'s update of its `descriptor` parameter, accepted as a write of a parameter. Of
  the 2 944 ownership roots, 2 941 have the same dump; `tests/platforms/gpu` differs in 66 summary
  lines and no verdict. Ledger 310 of 319 on both. Four-leg oracle on the sweep: 0 faults; 9 programs
  go from LIMIT to SAME and 21 from LIMIT to REFUSED, and each of the 40 shapes has one verdict at
  every size. The walks of the root take 611.9 ms where they took 654.6 ms; `checkedAwaitIn` needs
  8.67 million units and takes 146 ms, where the base gave up after 129 ms.

**What I learned**

- A partial memo can make a walk slower: this issue exists because report 146's memo let the walk get
  further. I ran the root with every budget lifted before I wrote a line of the fix. The walk needed
  1.4 times its budget, and the build side was 6.1 of 14.9 million units, so the fix ends the limit
  and does not only move it. Without that run I had no way to know.
- The readers are still N². A reader that takes the result location by location (`rootLeaves`,
  `escapeOnly`) reads N atoms at each of N locations. The generated shape is judged up to 512
  constructors and reaches its limit again at 1 024, and at 512 its walk takes 46 ms where the base
  gave up after 20 ms. A linear walk needs one atom for each location: the answer of a function
  parameter paired with the caller's location, as a known function's answer is. That changes what v3
  accepts, so it is a rule of §3.4 and a decision of the precision work, not a limit.
- My comment on the issue from this morning was wrong for this path. I wrote that `expandSrcs` reads
  the caller's entry, so one run for all entries is not correct. An answer source resolved by
  `ownAnswer` reads neither the entry nor its suffix. I had read the function's signature and not the
  path that this call takes; a print of the sources of three entries showed it in a minute.
- The first gates run failed on a rule of the repository: no hash map keyed by a dense id
  (`fast-compiler.md` §5 rule 5, `rules_test.zig`). The kept runs are a column by the callee's entry
  now, made at the first kept run, so a call with one location pays no allocation.
- A newly judged module of a platform can hold a write that no Node oracle runs. Here it is a record
  update, and records are written in place only under a hidden flag, so no default build changes. I
  checked that before I called the result safe to ship.
