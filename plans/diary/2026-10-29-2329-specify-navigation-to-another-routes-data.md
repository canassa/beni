## 2026-10-29 23:29 CET — Specify navigation to another route's data

**What I did.** Wrote `prerender.md` §8.12 and slice P4b for #1211 (PR #1258,
documentation only). A data site whose client reaches `Navigation.fetchData`
writes `_data/<route>.json` with the page's script text. `fetchData` takes a
schema and a `Url`, and gives a `Result DataError d`. Its errors are
`NotARoute`, `NotFound`, `BadStatus`, `NetworkError` and `BadData`. A later
call supersedes an earlier one. With the site's schema, the value is the one
the route's own page hands `init`. I checked the TEA example, formatted it and
built it against a stub platform (a copy of `browser-inline` passed as
`--platform=<dir>`). elm-pages and Solid Router are cited from source at
pinned commits.

**What I learned.**
- `browser-inline` refuses a message that wraps a `Result` beside another
  field when `update` splits on the `Result` (ArmWideWrapper, D-e). Because of
  that, "tag the answer with its route" cannot compile today. The superseding
  rule replaces it, and it is Solid Router's rule too: in `routing.ts`, the
  last call to `transition` wins.
- A command body on `browser-inline` may send later from a promise callback,
  because `Inline.send` enters the guard fresh. So an async answer needs no
  task kernel.
- Under folding, data files can collide where pages do not (`/a` and
  `/a.json/x`), so the route check has to cover them too.
- `backend.md` holds double-encoded UTF-8 (`â€”`) around §2's reserved-names
  table. It was there before this PR, and I did not touch it.
- The worktree hook refuses `cd <outside> && …`, and some `env -C` forms.
  Absolute paths from the worktree work.
