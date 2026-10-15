## 2026-10-15 13:14 CEST — answer the adversarial review of the Pages site

**What I did**

I answered the `@claude` review of PR #121 and then the coordinator's
adversarial review, in new commits:

- `Route.fromUrl` now matches `Deploy.basePath` only at the end of a path
  segment. Before, `/beni/conduitlogin` was the login page. Chrome showed it
  before the fix and "Not Found" after it.
- The site build refuses an `"html"` shell for a program that `404.html`
  runs, and every style of `404.html` is under `#not-found`. Before, a deep
  link into Conduit got the not-found page's background and font.
- The site build refuses to empty an `<out>` that holds the repository, or a
  non-empty directory with no marker file from an earlier site build.
- `pages.yml` builds the site on every pull request. A paths filter missed
  most of the site build's inputs: the compiler, `core/`, the platforms, the
  flake, `build.zig` and the playground.
- I merged master three more times. The last merge conflicted on the
  `writes/Conduit` golden, and I blessed it again from a run.

I asked the owner if Conduit ships elm-spa-example's MIT notice
(`pages-examples-q3`).

**What I learned**

- A stale run hash costs instructions, and a budget grant does not include
  that cost. Master moved the three `browser/direct/Conduit*` pages into the
  corpus with grants of their count plus 10%. My Conduit changes made their
  hashes stale, so Node ran the pages, and each case went over its grant
  (22.2–22.5G against 21.7G). After `zig build test-run-hashes`, all six
  cases fit. Record the hashes first, then read a budget failure.
- Read the gate's run-hash line by its exact words: "had no recorded hash".
  I searched the gate log for "for want of" and found nothing, so I wrote
  that no program ran under Node. Four black-box scenarios did, from
  master's merged changes, and the review found my claim wrong.
- Before I give a page's styles to a program, I check what the program
  looks like without them. A computed-style check in Chrome found the
  `404.html` leak in one line.
