## 2026-10-29 19:40 CET — Prerender P4 specified: build-time data

**What I did.** Wrote `docs/design/prerender.md` §8 as a contract (#1207, part of #1160):
§8.1–§8.11, the P4 row of §11, four new codes in §9, and pointers in §3.3, §5.4 and §7.4,
`frontend.md` §10.1/§10.3 and `boundary.md` §5.3. Documentation only. A site with data is two
programs over a shared schema module: a `node` data program, `main = Prerender.pages schema body`,
named by `"build"."data"`, which gives the routes and each route's value; and the site,
`main = Browser.prerenderData schema λvalue → program`, whose `init` alone reads the value. The
build runs the data program first, writes each page's text in a
`<script type="application/json" data-beni-data>` with `<` as `<`, and renders each page in
the prerender tree from the value the site's schema decodes from those bytes. The client decodes
the same bytes before `init`. Filed #1210 (`Io` has no directory listing) and #1211 (client
navigation to another route's data).

**What I learned.** The inline lowering already accepts a program constructor called inside a
lambda (a stub `prerenderData` built), so the function-of-the-value form needs no new spine walk
beyond the lambda. The value cannot reach `view` directly: the write sets are model paths, so it
goes through `init` into the model, which is TEA's own discipline. A data site cannot write P3's
"shell with no view" `index.html`, since a page with no value cannot start; `index.html` is the
`/` route or nothing. `?` cannot be used inside a lambda, so the data program's body is a named
function. `core/Schema` has no `formatIssues` yet, and `node` has no HTTP client, so the spec
names neither.
