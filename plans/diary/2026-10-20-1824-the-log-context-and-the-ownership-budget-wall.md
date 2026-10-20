## 2026-10-20 18:24 CEST — the log context, and the ownership budget wall

**What I did**

- Answered the review of #512. One finding was a real defect: `round (0 / 0)` is an `Int` that
  is `NaN`, and a virtual clock that read it made `logfmt` throw `RangeError`. The line now says
  `timestamp=NaN`. I proved the fixture red against the old `Log.beni` with `--core-root`.
- Built the log context (`annotate`, `span`, `minimum`, `withSink`) in the fiber's log-context
  slot, with `Task.withLogContext` and `Task.currentLogContext` beside the clock's pair. Wrote
  `run/LogLevels`, `run/LogMinimumLevel`, `run/LogAnnotationsInherited` and `run/LogSpanLabel`.
- Added `node.mjs --group=log` to `bench/fiber`: beni is faster than Effect v4 on every line.
- Found that `check_test`'s "ownership words: core's are catalogued" was at 99% of its budget on
  `master`, and the new code put it 10M over. Opened #514 and asked the owner (`node-log-q2`).
- Opened #515 for a race in `run/HttpServerBadClients` that showed once under load.

**What I learned**

- In `core/`, the ownership checker refuses `[ …xs, x ]` and `++` on a list that came from
  JavaScript (here, a slot), because both write in place. That was right: the outer log context
  still held the list. `List.push (List.copy xs) x` says it.
- Source maps carry each module's whole source (`sourcesContent`). So any edit of
  `core/Task.beni` changes the run hash of every development build that ships `Task.mjs`, wherever
  in the file the edit is.
- `dump --stage=ownership core` costs about 3 050M instructions of its 4 250M in the ownership
  stage. The test that runs it grows with every line of `core/`.
- In zsh, `$W:core/…` is the `:c` modifier. Write `"${W}:core/…"`.
