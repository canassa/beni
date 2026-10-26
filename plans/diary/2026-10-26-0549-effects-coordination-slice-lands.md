## 2026-10-26 05:49 CET — the effects coordination slice lands

**What I did**

- Four more PRs merged after #1042 (`Semaphore`), each with an Opus or Sonnet implementer, my validation, and adversarial reviewers:
  - #1046 (closes #1043 and #1047): `race`, `raceAll`, `raceOk`, `timeout`, `parOk` and `forEachOk` now cancel losers from the deciding branch's end, before any loser runs again, and stop starting branches once one is decided. The implementer stopped first, rightly. The nested shape, where a grandchild has already returned its value, cannot be closed in a combinator. It is the general cost of a manual `acquire`, so §17.7 documents it, and `acquire`'s doc says to use `onExit` or `withPermits`. Review found that a canceller calling `spawn` crashed inside the winner's end, so cancellers now run on the combinator's own fiber. It also found a `TypeError` that was already on master (#1047).
  - #1050 (closes #1044): cancelling a waiter is O(1). `Deferred` uses a `Set`. `Semaphore` uses a doubly linked list, because V8's `Set.values().next()` walks every deleted front slot.
  - #1049 (closes #1040): `Queue`, `Latch` and `Task.forever`. Review found two problems. A value was lost when `end` met a cancelled hand-off; the fix counts outstanding hand-offs. And `offerAll` on `sliding` and `dropping` queues passed waiting takers.
- Issues opened as debt: #1048 (the checker generalises a `let` bound to an impure `Ref.make` or `Queue.unbounded`, a silent wrong answer on master; it awaits the owner's go) and #1051 (a taker dropped by a stopped scheduler loses its hand-off).
- The owner said no benchmarking for this work, so the measurement items were dropped from #1040, #1041, #1043 and #1044.

**What I learned**

- A FIFO hand-off has a cost in every place that can discard a result: combinators, `end`, and schedulers stopping. Effect's re-check-on-run design avoids all of them, at the price of fairness. List those places before building the next hand-off primitive.
- "Each canceller runs once" held, because `halt` and `abandon` both clear `parked` first. The `queued` guard in the linked list is a backstop that no program can reach.
- The mutation sweeps by reviewers (`--core-root` with one rule broken) found a fixture gap in every PR. They are worth asking for every time.
- A mass-cancellation fixture can only go red under the 120 s guard when the new code's cost stays flat. For `Queue`, making the fibers already costs O(n), so its fixture is a slow-on-old-code smoke test, and its PR says so.
- `Task.forever` must yield on each pass. The 64-resumption budget only counts resumptions, and a body that never suspends is never resumed.
