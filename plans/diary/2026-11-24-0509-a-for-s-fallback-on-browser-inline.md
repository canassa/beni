## 2026-11-24 05:09 CET — A For's fallback on browser-inline

**What I did.** Compiled a `For`'s `fallback` on `browser-inline` (part of #2637): a page `For`
with a fallback shows it in a branch region of its own, made at the mount where the rows stand,
shown by `armShown` after `forRows` while the list's `length` is 0, its values evaluated only
then. The fallback is planned as a `Show`'s (one element, `Html.text e`, or `<></>`); interface
1.37 asks `programShowFallback*` of a `For`. Spec `browser-inline.md` §9, *A `fallback`*. The
adversarial review found two defects, both fixed: a `view` `let` that only a fallback's markup
reads was never bound (`ReferenceError` in dev, a wrong value in release; the same for a `Show`
since #2648) — `valueReadsLet` now reads into markup written in place; and evaluating the
fallback at every pass threw or logged where `browser-tea` does not. Page
`browser/inline/ForFallback` (checked against `browser-tea`), `emit/release/inline/ForFallback`,
`build/bad/inline/ForFallback` → `ForFallbackInRow`. No page newly builds: `WholeFor` also needs
a row whose top is a branch. Issue #2662 asks the owner whether a `Show`'s fallback should be
lazy too (`language.md` §6 says attributes are evaluated each render; `browser-tea` does not).

**What I learned.** `subtreeReadsLocal` does not descend into markup, so any analysis that asks
it about a markup value misses the reads inside; I fixed only `valueReadsLet`'s top-level case,
to keep other bytes still. Reviewers' scripts that build both platforms and diff normalised
transcripts are reusable for re-checking fixes in minutes.
