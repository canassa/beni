## 2026-10-14 13:44 CEST — track a command's progress and send credentials to any origin

**What I did**

Closed GitHub issue #92. Specified `boundary.md` §9.8.19 first, with dated
amendments in §9.8.12 and §9.8.16. Then built it in `browser`'s `Http`:
`send`'s record has elm/http 2.0's `tracker : Maybe String`, `Http.track` is
a `Sub.on` listener keyed by the name, and `riskySend` is `send` with
`include` credentials. A tracked request reports §9.8.12 (e)'s values to the
listeners of its name in one table for the page.

New fixture `browser/tea/HttpTrack`; `HttpRequestShape` gained `send` and
`riskySend`. The two existing `send` callers add `tracker = Nothing`. The
`ownership/EntryValueCommand` goldens moved by one line number and one finer
summary path; the verdicts did not change. Gates green.

**What I learned**

A listener subscription is added by queued work behind the bodies of the
update that declared it (§9.8.5 point 1). So a request that reports at once
loses its first `Sending`. A click needs one `yieldNow`. An update in a drain
renders only when the drain ends, so it needs a wait for the render too. A
204 has no wait between its last value and the answer, so the end needs a
yield. Each wait has a mutation that fails the fixture.

`Js.from` at a concrete type pins its tags for `--release`. `Js.from p` with
`p : Progress` gave every `Http` page string `Maybe` tags. A generic
`publish` and `listening` fixed it. A top-level `new Map()` also stays in
every build, so the table is made by the first listener.

Left for the owner: the tracker table is the page's, not one for each
program, and there is no `Http.cancel` (§9.8.19 (f)).
