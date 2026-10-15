## 2026-10-09 01:12 CEST — The direct platform's design: the second review's cases closed

**What I did**
- Revised `docs/design/browser-direct.md` for the second review of PR #24, each case with its
  fixture: the guard loops `drain; end()` until an `end()` queues nothing, so a message a
  `Dom.rendered` continuation sends applies in its own dispatch (`RenderedSends`); an event's
  `preventDefault`/`stopPropagation` run synchronously in the DOM listener and only the body is
  ever queued (`SubmitFromWrite`); a delegated walk buffers the bodies it meets and discards them
  at another list's row root or a program's mount root, so a nested `For` or a nested program
  runs each handler once, inner first (`NestedFor`, `NestedPrograms`); an arm's derived values
  run at the arm's mount and in step 4 under liveness, never in step 2 (`LetInArm`); a
  bubble-phase document listener sends a no-op after every user edit so a handler-less control
  is reconciled at once, which is stronger than today's "at the next render" (`ControlledNoHandler`);
  step 5 withdrawn for the one after-render point; the verify mode checks structure (scrutinees
  against `br`, items against `insts`), skips every-render groups and anything with `Debug`
  (`VerifyQuiet`); a program built by a function gets a mount record per mount and only one
  value mounted twice is refused, the message naming the escape (`ProgramsByFunction`). §13's
  stats gate gained numbers: a static `*` share ≤ 5 % per constructor, `Tour` in the dispatch
  log, ≤ 3 value roots or 5 % of sites, pairs ÷ keys fitted over the apps and Conduit's pages,
  criterion 5's split at 2 400 B non-core / 600 B core; the fuzzer draws from the checker's
  message type, not the key tree; Q6 gated before S0 and Q3 before S4.
- Gates green (docs only).

**What I learned**
- A queue that drains before `end()` and not after strands exactly the messages the after-render
  point exists to send; the loop has to end on an `end()` that queued nothing.
- Delegation needs an ownership rule the moment lists nest: "run what you collected only at
  your own row root" is the whole of it, and it gives Elm's inner-first order for free.
- The verify mode's own evaluation is an observable event for `Debug` and for every-render
  values; an oracle that re-runs the program must skip whatever running twice would change.
