## 2026-10-22 17:19 CEST — A command keeps its log context

**What I did**

- Rebased #688 onto `master` once more (8 run-hash conflicts); Cesar merged it.
- Built #597, the owner's decision `node-log-q3`: a page command's body keeps the log context of
  the place where the command was made. Spec first (`boundary.md` §9.8.16 (b), proposal §17.5 and
  §17.11), then `Task.keepLogContext`, used by `Hosted.job` and `Hosted.later`.
- Fixtures: `browser/tea/LogContext` (the command lines carry the annotation, the `Debug` line is
  written) and `browser/tea/LogCommandContext`. Each fails on `master`, and three mutants fail them.
- Asked the owner which context a message's `update` has when a body sends it (`node-log-q4`). My
  first draft decided that in the spec; the coordinator had me take it out.
- Opened #751 (`browser-inline` parity) and #765 (release-optimiser traces of folded code).
- Answered `node-log-review`'s round on #769: rebased past 521 run-hash conflicts, opened #774
  (ownership precision) and #775 (a defect fixture), said in the spec that 17 command makers are
  now `impure`, and added the review's keyed, task, after-render and subscription paths to the page.

**What I learned**

- A guard on `slotted` folds only when no code in the build writes `slotted`, and that includes
  dead code. My first build called `Task.withLogContext`, which writes it, so each page with a
  command lost the fold: +115 to +4 591 raw in release. The fix was a run path without the write.
- The release optimiser inlines only a function with one use. A function with two uses that folds
  to `()=>undefined` stays a call. A function that gives back its parameter is removed at any number
  of uses. So `keepLogContext` returns its argument when nothing sets a slot, and the guard reads
  `slotted` inside `Task`, not in the platform.
- An immediately called arrow, `(()=>f(x))()`, is not reduced: a fast path must not pass a lambda.
- `--platform=<dir>` takes a platform package from a directory. With `--core-root`, one compiler
  measures a change to `core/` and `platforms/` together. A dependency must be a path such as
  `../browser`, because an embedded name wins over a directory.
- The bench through the page driver has more noise than the effect: two equal release builds
  differed by 6% per command. A Node loop of 1 000 000 calls gave stable numbers.
- A function that reads a cell is `impure`, and so is each function that calls it: one read in
  `keepLogContext` made 17 public command makers `impure`. The API pages show it; read their diff.
- Ownership reports summarise platform code too. Wrapping each job in `keepLogContext` changed the
  summaries of 28 `ownership/` goldens (more `{lost}`), though no verdict. A change to a platform's
  command path must bless `ownership/` and read the diff for verdict lines.
