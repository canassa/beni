## 2026-10-12 22:58 CEST — Ownership slice 3f: a prepend copies, maps across records, the default read

**What I did.** Specified and built `ownership-checker.md` §25. A prepend (`[ x, …xs ]`, items only before the
one spread, and `List.cons`) is no demand: it reads its base, and its result is a new cell plus the base's cells,
approximately, because core's `cons` re-conses onto a view. Two closed records with different fields no longer
"may share", so the type filter drops `map`'s identity promise between them. `Maybe.withDefault (Maybe.map m f) d`
with `m`, `d` variable paths and `f` a lambda or top-level value is walked as a two-arm `case`. Fixtures
`Prepend`, `MapAcrossTypes`, `MaybeDefault` (accepted and rejected variants), T33's push projection beside the
Lean model's. Research 85 measures it.

**What I learned.** Bike Wars goes from 31/82 rejected to 6/19: the prepend rule alone clears 23 lines, because
most of research 82's causes were writes a prepend made in place. The `map` rule was applied all along — `mayShare`
answered yes for any two records — and clears nothing in Bike Wars, since R4 was a prepend. Every prepend shape
the backend emits copies or answers a header over the base (`cons`'s re-cons, `close` handing the tail back), so
the result must alias the base: dropping that would be unsound for the suffix re-built after `[ a, b, …tail ]`.
The corpus sweep only loses lines (281 acceptances, 3 pending, 32 rejections); nothing flips.
