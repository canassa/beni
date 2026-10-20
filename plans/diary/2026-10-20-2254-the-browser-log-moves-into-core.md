## 2026-10-20 22:54 CEST — the browser's Log moves into core

**What I did**

- Recorded the owner's decision (`node-log-q1`) in `boundary.md` §9.8.16 (b) before the code:
  `Log.write` becomes `Cmd.log : Log.Level, String → Cmd msg` in `browser`'s `Cmd`.
- Removed `platforms/browser/Log.beni`, added `Cmd.log`, and took `Log` out of `browser-tea`'s
  `"reexports"`. Renamed the two call sites and the three rows of `ownership-checker.md`.
- Wrote the pages `browser/tea/LogContext` and `browser/tea/LogContextDefect`, and checked the
  second against a mutant that restores nothing on a cancellation.
- Measured every `browser/tea` and `browser/dom` page and the four browser examples against an
  `origin/master` compiler.
- Answered both reviews of #517 and fixed their findings; rebased #517 and this branch twice as
  #512 and #517 merged. Resumed after the 21:23 OOM kill.

**What I learned**

- A comment line in an ownership fixture moves the line numbers in its `.ownership` goldens. To
  rename a call there without touching the goldens, keep the line count.
- On a page, the release optimiser folds every slot read to `undefined` when nothing sets a slot,
  so the log context costs a page that logs no fiber machinery; the cost is the entry, the time
  and the list helpers.
- A `browser/tea` page that throws needs a `.release-expected`: the release build draws no crash
  screen, so its last step is `(the DOM did not change)`.
- `git rebase --onto <new base> <old base> <branch>` replays only a stacked branch's own commits
  after the base PR merged with new hashes.
