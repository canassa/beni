## 2026-11-16 22:39 CET — own3: a location placed nowhere escapes

**What I did**

- Fixed blind round S's fault (#2542): a `foreign` row `returned a → Int` dropped its parameter, since
  "at every location of the result" was at none. Every word that places a parameter, and a function
  parameter's answer, now escapes where the result has no location to hold it; safe builds check each
  row's placement (`Check.checkWordedPlaced`).
- Found the same mistake at the call (a result read at an instance of fewer locations), where a function
  meets its holder, and, through three passes of one adversarial reviewer, wherever a reading has a
  part of no location (`Int`) that a cast can hide a cell in: `Loc.all` was "held at every entry", a
  cast behind a type variable, a wide parameter answered from inside a `Maybe` or a list, a closure that
  casts a captured value. Kernel §3.4, rule 10 and §9 revised; research report 150; 18 `run/`
  fixtures; a generator family, `worded-no-location.mjs`; `run.mjs` decodes its children's output as a
  stream.
- The real-writes ledger stays 294 of 308; the cost is 17 fixture roots (#2543). Residuals parked in
  #2544.

**What I learned**

- "Placed nowhere" has a second form: placed at a location that exists, while a part of the reading
  of no location (read out as `outside`) holds the same cell. Holding it elsewhere is not enough.
- Marking every `Js.Value` read at a type variable as a cast made all of `core/List` cast and cost real
  writes; the cast fact has to be per place, not per contract, to close the last residual.
- Root-dump comparisons index roots by position: adding a fixture shifts every later index, so the base
  must be dumped again on the same tree.
