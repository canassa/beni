## 2026-11-24 05:44 CET — A Show's fallback is evaluated only while shown

**What I did.** Made a `Show`'s fallback on `browser-inline` evaluated only on `Nothing`, as a
`For`'s already was (#2662, the manager's decision under the owner's standing rule):
`writeShow` now prepares the fallback inside the `Nothing` branch. `language.md` §6's table and
§11.18 say a fallback is evaluated only while it is shown; `browser-inline.md` §8.2's wrong "as
on `browser-tea`" and §9's matching sentence are corrected. `ShowFallbackThrows` now pins the
rule (body shown, bumps past the limit throw nothing, the fallback throws when it shows again)
and agrees with `browser-tea` in dev and release; `FallbackShownOnly` pins it with logs for both
`Show` and `For`. `emit/release/inline/ShowKeyed`: 3 055 → 3 065 B raw, 1 210 → 1 214 B brotli.
Sweep unchanged (196 of 357).

**What I learned.** `browser-tea` is lazy for every fallback form but `Html.text e`, which its
`view` builds as a value at every render, so that form is a listed difference — and it already
was for a `For`'s fallback on master, unlisted. The review found the first spec text too broad
("any other form"): a helper call and a branch as a fallback are lazy on `browser-tea` too.
