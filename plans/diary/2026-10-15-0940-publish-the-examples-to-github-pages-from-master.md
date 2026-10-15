## 2026-10-15 09:40 CEST — publish the examples to GitHub Pages from master

**What I did**

Jayson asked for the compiled examples on the `gh-pages` branch at
`/examples/`, with `/index.html` left alone. I first pushed the branch by
hand. Then I wrote the workflow that keeps it current:
`.github/workflows/pages.yml` builds beni and runs
`examples/build-pages.mjs` on every push to master. A second job, the only
one with write access, replaces `/examples/` and `/.nojekyll` on
`gh-pages`. A pull request that changes `examples/` or the workflow builds
the site and does not publish it. Sternhalma is a release build. Bike Wars
is a development build, because the port keeps `Debug.log` and `--release`
refuses `Debug`. Conduit is left out: it calls its API at `/api` on its own
origin. Each port's BSD-3-Clause notice ships beside its build. Both pages
render in headless Chrome under `/beni/examples/`.

**What I learned**

The page shell loads the entry by an absolute path, `/_main.mjs`, so a
build served under `/beni/` loads nothing until the project says
`"build"."base"` (`backend.md` §2, *The page shell*). That is the designed
answer, not a defect; the base has no flag, so the script builds each
program from a copy whose `beni.json` sets it. GitHub Pages runs Jekyll on
a branch by default, and Jekyll drops every path that starts with `_`,
which is all of a beni build's runtime: `/.nojekyll` is required.
