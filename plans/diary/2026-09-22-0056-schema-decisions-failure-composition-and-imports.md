## 2026-09-22 00:56 CEST — schema decisions: failure, composition and imports

**What I did**

- Recorded the owner's three accepted decisions in `plans/queue.md`: encoding may
  fail with `Result`; generic schemas receive explicit schema arguments; multiple
  schemas may live in one module, reachable through full qualification or explicit
  exposure of the schema name.
- Added a notice to report 32 marking conflicting revision-2 recommendations as
  superseded. A full specification revision remains owed; no implementation changed.

**What I learned**

- A schema's imported name keeps its members qualified: exposing `User` does not
  expose bare `Type` or `parse`. Ordinary import behavior matters to the owner;
  these decisions do not request a general-purpose namespace feature.
- Fallible encoding and explicit schema arguments resolve two central design
  conflicts. Wire presence, arbitrary keys and union representations remain open.
