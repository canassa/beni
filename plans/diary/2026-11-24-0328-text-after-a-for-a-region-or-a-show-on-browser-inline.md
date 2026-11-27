## 2026-11-24 03:28 CET — Text after a For, a region or a Show on browser-inline

**What I did.** On `browser-inline`, a `For`, a branch region or a `Show` of the page followed
by anything but an element (text, a text hole, another `For`, region or `Show`) now stands
before an empty comment of its own, `<!>` in the markup, which the mount finds as
`parent.childNodes[k]` (a run of texts counted as one node) before it makes any text or region
state (part of #2625). Spec `browser-inline.md` §8.2, *What follows a `For`, a region or a
`Show`*, and §9. Page `browser/inline/MarkerPlaces` (checked against `browser-tea` for the
same source); `ShowAndBranches` and `LateResponse` copied from `browser/tea`;
`emit/release/inline/MarkerPlaces`. `ForBeforeText`, `ShowBeforeText`, `RegionBeforeText` and
`HelperBranchBeforeText` are withdrawn; `RowBranchBeforeText` (the same in a row) stays.
Sweep 194 → 196. No page that built before changed by a byte: a comment is written only where a
refusal stood.

**What I learned.** dom-expressions' `<!>` is the cheapest marker that survives the parser between
two texts, and needs no change to the element numbering. A `-Dcorpus=browser/` run with
`BENI_WRITE_EXPECTED=1` is a quick regression check: no golden moved.
