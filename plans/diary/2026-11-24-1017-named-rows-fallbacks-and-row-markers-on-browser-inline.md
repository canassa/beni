## 2026-11-24 10:17 CET — Named rows, fallbacks and row markers on browser-inline

**What I did.** On `browser-inline` (part of #2637, #2625, #966): a `For` or a `Show` whose row
function is a named function of the program's module enters the call with the item bound, as a
view helper's call is (interface 1.39; `Lower.directChain` of a `For`/`Show`, no step added
to the call path); a `Show` whose body is a lambda whose body is a branch picks its arm with `v`
bound through `emptyRow` and `rowArm`; a `For` in a row, an arm or a `Show` body may have a
`fallback`, a region of the unit; and a `For` or a region in a unit followed by text stands
before an empty comment of the unit's template. Pages `NamedRows`, `RowFallback`, `RowMarkers`
(checked against `browser-tea`), `ApiItems` and `ShowValueArms` copied; goldens
`emit/release/inline/NamedRow` (3 522 B raw, 1 512 B brotli) and `RowMarkers` (2 653 / 1 219);
`ForFallbackInRow`, `RowBranchBeforeText` withdrawn, `ShowBodyBranch` became
`ShowBodyFragment`, `ForRowFunction` a local function, new `ForRowOtherModule`, `RowMarkerPre`.
`Inline.beni` is unchanged. Sweep 198 → 200 of 357.

**What I learned.** The two reviews found what the corpus could not: a named function's `let`s
are bound once where the call is entered, so they must count what its arms and fallbacks read
(a `ReferenceError` in development and a silently wrong text in release, #2672); and the parser
drops a newline after `<pre>`, which happy-dom does not, so a comment's place counted over the
template's children was wrong only in Chrome. A row's `Debug.log` in a shown fallback logs again
when another row changes, since every row's `set` runs: a listed difference of when. Left: another
module's markup in a row (pieces need a path per item), arm statements, a region in an eager arm,
an effectful choice (`BranchOnce`: `browser-tea` re-draws at every render, a difference of
what, an owner question), a region on a prerendered page; 60 `browser/tea` pages build on inline
with no copy in `browser/inline/`.
