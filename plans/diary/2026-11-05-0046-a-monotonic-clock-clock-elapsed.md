## 2026-11-05 00:46 CET — A monotonic clock: `Clock.elapsed`

**What I did**

#1889, a gap of #142. The owner chose milliseconds as `Float` (`playground-beni-q9`). `core/Clock` gets `elapsed : ⊤ → Float`: the host's `performance.now()` on the real clock, the virtual clock's reading inside `Clock.run`. `transparent-effects-proposal.md` §17.6 has the dated amendment, `skills/beni/` names it, and two `run/` fixtures pin it: `VirtualClockElapsed` and `ClockElapsedNeverBack`. #1930 is the follow-up for the browser driver.

**What I learned**

- workerd's `performance.now()` is exactly its `Date.now()`, with `timeOrigin` 0. Its default path puts a floor at the last time it gave, but its precise-timers path has no floor. So "never goes back" needs a floor in core: a module-level `Js.Ref` that keeps the highest reading.
- A `run/` fixture with its own `platform/` can change a host global through `Js`. That is how a test makes the host's clock go back, which no ordinary program can do.
- A bless run of `test-blackbox-corpus` runs the development and release halves at once. For a new fixture, the release half reads the golden before the development half writes it and fails with `MissingGolden`. The second run is green.
- The browser driver makes `Date.now` virtual, but not `performance.now`. The fuzzer pins both.
- A new declaration in `core/` changes `tests/corpus/ownership/core.v2.unchecked`, which lists each core declaration with its line range. A filtered corpus run does not show it; the full gates do.
