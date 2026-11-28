## 2026-11-27 18:15 CET — v3: the check of a shared run, found by the safe dumps

**What I did**

- Worker `own3-speed`, issue #2539, PR #2735, after its first push. Four things changed.
- The safe build stopped on `bench/corpus`: "a check that counts no work built nodes of the frame".
  `checkSharedRun` expands a location a second time. A source that is a function held in an argument
  walks to it by `project`, and `project` makes a value at each step (`refVal`), so the second
  expansion made them again. My first fix dropped those values before `loud` compares the frame's
  parts (the review below shows why that was not enough). The gates did not find this; the safe
  compiler's dumps of all 2 946 ownership roots did, on one root.
- The check has a bound: the first 16 locations that take each run. Without one, a safe build did the
  N expansions that the walk no longer does, outside every budget.
- One kept run in place of a column of kept runs. The column was allocated in each call whose first
  expansion read nothing of its location, also where no two locations share an entry of the callee.
  In my timing four small roots were 5 to 6 % slower (20 to 70 ms each; the sum of 33 roots was 1.2 %
  faster). The locations that one entry of the callee covers are one after another in the caller's
  layout, so the run of the last location expanded serves the next ones, and a call allocates nothing.
- The adversarial review of the first push (25 095 generated programs: base and change agree on each
  dump but the 30 programs of the new sweep that go from a limit to a verdict) found two more defects
  of the same check, both in the safe build only. It compared the two runs atom for atom, and an atom
  has the context of an arm that a walk that counts no work does not set: a lost answer with a join of
  two lists of the frame as its argument stopped the compiler, also in a plain `check` for
  `browser-inline`. The runs are compared as sets without contexts now, by the one helper that the
  check of a kept read uses (`sameButCtx`). And a walk to a function held in a record of more than 16
  fields makes the index of the record's parts at its second step, which a check may not build. So
  dropping the values that the check made was the wrong fix: an expansion that walks to a held
  function is not kept for the next location (`SrcState.held_walk`), the check never repeats such a
  walk, and it drops nothing.
- Mutation checks of `entry_read`, with the safe compiler: with the assignment at a parameter source
  removed, 153 of 153 programs stop in `checkSharedRun`; with the one in `answerOfCode` removed, 30 of
  30. So a reader of the location that sets no flag is found by the check, on almost any program
  (`core` has such calls).
- The review branch moved two more times (to 0ea25cd34b, then to fb795abe27 with my own PR #2733). I
  merged it; the one conflict was a row of the kernel's §9 table.
- A correction of my entry of 16:06: the newly judged write of `Gpu.Diagnostics.Device` changes no
  emitted code because a module outside the application publishes no write of its own
  (`Enforce.walkModule` empties its channel), not because records are written in place only under a
  hidden flag. `browser-inline` writes records in place by default.

**What I learned**

- "The gates are green" said nothing about the new check. It runs only where a call shares a run, and
  the corpus of the gates has few such calls under v3. The safe dumps of all roots take 25 minutes and
  I had stopped them two times to save that time. They are the test of a safe-build check; run them to
  the end before the pull request opens.
- A check that runs an expansion a second time is not free of effects even where the expansion is the
  same: making a value is an effect on the frame. The rule for checks that count no work caught it.
- I knew that a quiet walk sets no context: I wrote the comparison without contexts for the check
  of #2567 this morning, and wrote "atom for atom" for this one in the afternoon. One helper for both
  checks is the fix that stays.
- A per-call allocation for a rare case shows as a few percent on small roots. One slot that is
  replaced serves the same case with no allocation, because the locations of one entry are contiguous.
