## 2026-10-15 11:59 CEST — deploy the examples with the Pages actions

**What I did**

I changed PR #121 to carry issue #127, as Cesar decided on the dashboard.
Pages takes its site from GitHub Actions, so the `gh-pages` branch that the
PR published to was never served. The workflow now uploads the site with
`actions/upload-pages-artifact` and deploys it with `actions/deploy-pages` on
a push to master only. The index is at `/beni/` and each program at
`/beni/<name>/`. All three programs are `--release` builds:

- Bike Wars: I removed the one `Debug.log` in `Helpers.toLine`, in its own
  commit, and said why in `PORTING.md`.
- Conduit: a new `Deploy` module holds the base path and the API origin.
  Its defaults keep the corpus as it was; the site build writes the module
  again in its copy, with `/beni/conduit` and `https://api.realworld.show`.
- A `404.html` runs Conduit for a deep link after a reload, because GitHub
  Pages has no fallback to a single-page app.
- The index has a slot for the playground (#128). The workflow builds it
  when `zig build playground` exists, and the site build copies
  `zig-out/playground/` to `/playground/`.

I served the site under `/beni/` with a GitHub Pages 404 rule and loaded
each page in headless Chrome: every program renders, and Conduit lists,
opens and reloads articles from the public API.

**What I learned**

The public RealWorld API was live, and its CORS headers allowed the site,
but Conduit still showed "Error loading feed.". The current RealWorld spec
leaves `body` out of an article in a list, and Conduit's list schema
required it. A curl check of the API was not enough: only the page in a
browser showed the mismatch. Cesar decided that Conduit reads a list
without `body` (`pages-examples-q2`). A schema ignores unknown keys by
default, so the corpus pages, whose fake API still sends `body`, did not
change.

A program that routes by path needs its deployment's path:
`boundary.md` §9.8.13 (e) says nothing hides the base from the router, so
Conduit's routes and links take it from `Deploy.basePath`.
