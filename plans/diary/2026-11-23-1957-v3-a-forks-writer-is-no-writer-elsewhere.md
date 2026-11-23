## 2026-11-23 19:57 CET — v3: a fork's writer is no writer elsewhere, and hosting stays started

**What I did**

- Fix lane fix193 on `ownership-v2-design-review`, for #2622 (code reader CR5 on 0f3b62eac0): a
  closure that `Task.spawn` registered as a writer or reader stayed one at every later holder, and a
  hosting function inside a wrapper a callee answers reached `Task.uninterruptible` unchecked.
- Kernel §13 item 12, *A defect*, (d), then `src/own3/`:
  - *Down*: `flowCode`, `captureCells` and `applyAt` ask whether the holder forks before they ask
    whether the closure is a writer, so a registration is the fork's. `FlowKey` keys whether a
    call runs the use above within it (`up_within`) and `started`.
  - *Up*: a hosting function is refused wherever no call runs it within and nothing starts it in
    a fiber of its own (`startedAt`). New facts: `Fn.starts` (`Task.start`'s work: a root fiber of
    the program's scheduler, so Up only, never a writer's fork), `Fn.kept_out` (the frame's own
    function parameter held where nothing starts it), `Use.started_above`.
  - *After such a call*: the frame's own function parameter called after a call the frame knows
    can mask or lend has `Fn.runs_on`; a call that runs within it both a function that can mask
    or lend and a hosting one is refused; a function run within a call that runs what its holder
    hands it (a list of functions) runs code the walk does not know; and `Fn.after_call` lets a
    forked closure's holder refuse a hosting capture run after one that can lend.
- `run/CellRunsOnHeld` and its live twin (the base refuses 3 of the live's 20 refusals);
  `run/CellClosureWritesLive` refuses one more call. `cells.mjs` `runon.*` 66 → 98 pages: base
  11 TRAP, head 0 faults.
- One Opus reviewer found two more ways in, both on the base too (a list of functions run by a
  callback, and a forked closure that runs a captured lend and then a captured hosting function):
  11 TRAP pages, all refused now.
- Evidence: root dumps 2 550 roots, 0 root verdict changes, one refusal line more in an already
  refused fixture; ledger 309 of 319 before and after, identical lines; sweep dump-diff of the
  75 608 cell and fiber programs of every sweep: only the new `runon` pages differ (12 accepted →
  refused, 9 of them live faults; the 4 newest pages are judged by the runner); v3 on the real roots 2 466 / 2 684 ms base against 2 663 /
  2 562 ms head, two runs each, noise on a loaded machine. Gates exit 0.

**What I learned**

- A rule written for one holder level misses the levels above it. The *Up* rule read only the
  holder's own `lost`, so a callee that put a closure over its parameter in a list published the
  parameter as "called and kept", which the caller read as run within. Every judgment that a
  function cannot run masked has to read the whole chain, and the facts that chain needs have to
  be in the memo key.
- `Io.run` and a helper that stashes a closure in a list have the same contract unless the
  contract says who starts the closure. The fix needed one new fact (`Fn.starts`) that is true for
  the *Up* rule and false for the *Down* rule: `Task.start`'s fiber has no slots, so it belongs to
  the program's scheduler wherever the caller runs.
- Making every own-parameter call after a window `runs_on` was too coarse (it refused safe
  programs that call two parameters in a row); judging the pair where both meet, at the call or at
  the fork, kept the precision.
