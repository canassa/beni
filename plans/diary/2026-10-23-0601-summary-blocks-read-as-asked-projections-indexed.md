## 2026-10-23 06:01 CEST — summary blocks read as asked, projections indexed, wide arms joined through their split

**What I did.** I worked on four pieces under #464.

- **#814, PR #822.** Core `Schema`'s summary block cost 14.8M instructions in every build that calls `Schema.read`. The block was not the problem; the eager read was. `summary_bytes.read` read and normalised all of the block's 300 or so summaries, and `normalizeRaw` with `canonicalOf` was 10.2M of that.
  - Block version 27 writes each summary's length before it.
  - `open` reads only the tables and the directory.
  - A summary, and the paths it names, are read the first time the run asks for them.
  - The ownership phase went from 26.5M to 11.4M at N = 16. Every output hash is unchanged.
- **#816, PR #823.** The bench generator wrote `modBy` and `clamp 0 10 x`. It now writes `Int.mod x 3` and `clamp x 0 10`, and draws the same numbers. `tests/blackbox/bench_gen_test.zig` checks a generated corpus with no diagnostic, in both modes.
- **#825, PR #835.** The entry (`Main.main`) cost 18.1M at N = 64 and 19.8M at N = 256. It grew ×8.2 up to `wide_index` and then stayed flat, because a model below that width was scanned once per projected path. A holder that keeps a value unchanged now indexes it by first step (`StepIndex`). This holder is the entry for the model, or an instantiation for its arguments. The entry went from 18.05M to 5.91M at N = 64.
- **#825, the split-join PR.** The arms of `step` and `replaced` each copied the model's split, and their join merged N² entries. A split known whole is now a run. An update builds its value from the run. Its guards come from the run's entries that face a list, in `spineValue`'s order. A join of values over one run merges only what they do not share. `step` went from 36.26M to 20.58M at N = 256. `ownership/SplitArmsJoin` pins a mixed join, with a golden written by master.

**What I learned.**

- `master` moved twice under these PRs. First the ownership cast work changed `proj`'s loop, and then the module workers moved the pass. Each time I had to rebase, resolve, and measure again. When a projection is restructured, its loop body must be shared, not copied, or the next change to the loop splits the two.
- On the reference build, valgrind stops with SIGILL at N = 256 after the ownership phase. `Ownership.run`'s counts are complete, but `dist` is not written, so check the output hash with a native run.
- A remote branch called `own-entry-linear` was still there from #716, and my first PR (#834) opened on it. Use a branch name that is new.
- `pkill -f 'maker build --zig-lib'` matches every zig build runner on dagon, not only yours. I ran it once, at about 04:35 CEST. Kill processes by their working directory.
- On the new `master`, opening blocks costs 1.3M at N = 16, 6.3M at N = 64 and 54.8M at N = 256. That is about 3.3 opens per module, and each open costs more as N grows. I filed it as #848 and did not fix it here.
