## 2026-11-26 17:44 CET — v3: a writer runs on every version a call shows

**What I did**

- Fix lane fix218 on `ownership-v2-design-review` (base 3137e2183d), for #2698 (code reader
  CR11): a callee that forks a writer fiber, sleeps and then stores into the cell was wholly
  accepted while the caller held a loan of the old contents. `runEnd` ran the writer made in the
  call once, on the frame's latest version, which already held the callee's store; the fiber
  really ran during the sleep, on the old contents.
- Kernel §13 item 12, *A run of a writer*, amended: a writer or a reader that can run inside a
  call is judged against every version of its cell the frame's loans can see during the call.
  The version before the call, the version after it, and, in between, the callee's own stores,
  which its mark already names. Item 11 is the same rule, and the text says why.
- Code: `runBegin` keeps the latest version of each tracked root (`latestNow`). `runEnd` runs
  each writer made in the call on the version before the call and on the version after it. It
  runs each older writer whose cell code run within the call renewed (`within_renews`: a closure
  run within, a writer's run) on the version after the call. It probes the tracked parameters
  and captures there too (`probeCells`). The last two close two more holes of the same class that
  I found while I probed: a writer forked before `runSleep (λ⊤ → Ref.set r xs)`, and the same
  when the cell is a helper's parameter or a closure's capture (TRAP on the base).
- CR11's U1: `registerWriter` registers nothing after a call in a hole of markup that is a switch
  point. U2: `Contract.joinFn`'s mismatch path takes the pessimistic side of every fact.
- Fixtures: `run/CellWriterBeforeRenew` and its live twin (15 shapes: `Ref.set`, `update`,
  `modify`, a record cell, a method, a wrapper, a local, another module, a push and a reader
  fiber, and the writer forked before the call in the frame, a helper and a closure).
  `cells.mjs` has `renew.*` (288 programs). The base has 100 live TRAPs. The fix refuses every
  live program and has 0 faults. 10 dead record twins of `param`/`capture` are newly refused,
  which is the pessimistic side.
- `run/CellWriterStoresFresh`'s `dictFold` (a fiber whose `List.foldl` callback inserts a fresh
  list) was accepted only through the hole: the unrolled form, two updates in a row, is refused
  on the base. It moved to the live twin as a pinned pessimistic refusal.
- Evidence: root dumps, 7 of 2 582 differ, all cell fixtures, and no real root differs. The sweep
  dump-diff covers 6 574 programs (cells, corpus, five generators): 114 go from accepted to
  refused, which are the 110 `renew.*` programs, 2 dict probes and the two fixtures. Browser-inline
  pages: none differ. Ledger 309 of 319, line for line. Changed programs under all legs: 0
  faults. The adversarial reviewer ran about 75 probes and found 0 faults.

**What I learned**

- "The latest version" is the wrong question at a call. The right question is which versions the
  code that runs inside the call can see. Asking it found two more holes than the issue named.
- A fold over a callback is a sequence of calls. A rule that refuses the unrolled sequence must
  refuse the fold, and a fixture that passed only for the fold pinned a hole.
