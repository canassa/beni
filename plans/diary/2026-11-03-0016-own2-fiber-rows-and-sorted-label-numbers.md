## 2026-11-03 00:16 CET — own2 fiber rows and sorted label numbers

**What I did**

- #1736, option (b). `Fiber` is a cell type. `spawn`, `spawnIn` and `spawnDetached` take an `escaped` work and
  answer `cellempty`. `join` is `lent`, as `Deferred.wait` is. The `cellempty` companion also accepts `escaped`.
- `check_test`'s reach rule follows the four new v2 rows. It takes out only Task's v1 rows, by name, so they keep
  v1's rule. I read all 107 bodies the four rows reach and pinned them.
- I amended the spec: `ownership-v2.md` §2.13.6, §2.13.7 (*the fiber rows*) and §2.13.18, and oc §24.8.
- New fixture `run/SanitiserFiberJoins`: two joins of one fiber, and an edit in place of one of them. An experiment
  build with a `fresh` join traps on it.
- #1737: I ported the values lane's fix to this lineage. The result's puts follow the renumbering of the labels. I
  also took over its fixture, which fails on the base.
- #1735: still refused. I posted probes showing that the `Task.scope` refusal is not the only guard. Restoring it
  needs a new row shape.
- Filed #1739: a live loan of a list refuses every in-place list edit.

**What I learned**

- Roots of only the v2-worded declarations would have dropped one need today: `List.trieDrop`, which only `List.view`'s
  v1 row reaches. Measure the need set of a guard before you narrow it.
- A fiber's `outcome` has exactly one writer, `complete`. That fact is what lets `join` be a plain loan.
- v2 takes a loan of a list as `⊤`. After `join` or `Deferred.wait` of a list, a frame cannot edit even a list it
  made itself.
- Running `beni build` inside `tests/corpus/run` leaves a `.beni-cache` there, which the corpus then fails on. Build
  probes from scratch directories.
