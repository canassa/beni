## 2026-11-24 00:15 CET — browser-inline reads Cmd.batch over List.map again

**What I did**

- #2641 (part of #966). PR #2619 withdrew the write-set pass's reading of
  `Cmd.batch (List.map xs λx → Cmd.perform …)`. The reason was #2617: a body nested in the
  callback sent the new value of a field that the same arm writes in place. PR #2623 fixed
  #2617. I restored the reading (`allEffect`, the map branch of `effectConcat`, `applyRow`'s
  `.map`). I kept #2619's two stricter rules. The map branch now needs an element at `[*]`, so
  a list that summary substitution lost stays unread (`CommandHelperList`). It collects bodies
  with `commandParts`, so keyed and chosen commands in the callback are read as #2615 reads them.
- New page `browser/inline/BatchMapOldValue`. It reads a written field one, two and three
  closures deep, and a nested field. Every body sends the old value, and the transcript is
  browser-tea's. The ownership checker refuses mapping `model.items` in the arm that pushes
  onto it in place, so the page pushes onto a copy.
- I restored `CommandsOverModelList`, `SettlesManyFibers` and `RespondSettlesEachChunk`, and
  copied `AdvanceSettlesEachTimer` and `HttpFailures`, which also needed #2640. Each has its
  tea transcript.
- Sweep on the same master: 186 → 190. No tea or dom page stops at "could not read this
  command" now. `WebSocketEquality` stops at the subscription reader, a different limit.
- Runtime bytes: 0. Only `src/writes/` changed.

**What I learned**

- The reviewer tried about 20 shapes: helpers, `if`, `Cmd.map`, `Cmd.keyed`, `afterRender`,
  sleeps, `Task.spawn`, and closures four deep. No built program differed from browser-tea.
  The batch path is a second way to reach the open #2620 (a local function called after the
  write reads the new value). Master already reaches #2620 with a single `Cmd.perform`.
- A `-Dcorpus` run with `BENI_WRITE_EXPECTED=1` and a temporary `browser/tea/Zz…` twin is a
  quick way to get tea's transcript for a new inline page. Remove the twin and its known
  lines before you commit.
