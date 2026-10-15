## 2026-10-13 04:36 CEST — the list identity promises dropped

**What I did.** On the owner's decision, made every `core/List` function that builds — `map`, `indexedMap`,
`filter`, `slice`, `take`, `reverse`, the sorts, `concat`, `concatMap`, `append` with an empty side — and
`Basics.append`'s list half return a fresh list, at the same cost; removed `identical`, `kept`, their emitter
operators and asserted rows, the `K` bit, and §25.3's record rule. Spec first: `language.md` §6.8,
`backend.md` §4 and §15, `browser-direct.md` §6.2, `write-sets.md` §3.7, and `ownership-checker.md` §27, which
supersedes thesis O2. Fixtures re-pinned to copies; research 90 measures it. PR opened, not merged.

**What I learned.** The summaries came out `fresh` from the bodies with no checker change, and two binaries
with §25.3's record rule and §16.4's type filter switched off moved no line of 1 299 units, so the record rule
was O2's alone. Rejections fell 233 → 221 with none added; Sternhalma's S3 clears; Bike Wars, Conduit, the table
app and TodoMVC do not move. `browser-tea` loses only the skip of a `For` over a list `view` rebuilds unchanged —
≈ 10 µs on FilteredFor's new `tick` at 1 000 rows. Writers keep returning their input: under in-place writes
that is what a writer returns anyway. The flake's Chromium does not start here (glibc); Chrome 154 via
`-Dchrome` passes all but BikeWars, whose golden has happy-dom's `#222` where Chrome writes `rgb(34, 34, 34)`.
