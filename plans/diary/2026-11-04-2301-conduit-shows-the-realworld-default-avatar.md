## 2026-11-04 23:01 CET — Conduit shows the RealWorld default avatar

**What I did**

I fixed #238. `Author.defaultAvatar` in the Conduit example was elm-spa-example's `smiley-cyrus.jpg`, which answers 404. It is now the RealWorld spec's `default-avatar.svg` (realworld-apps/realworld at `8776403114`, the commit that the theme pins; MIT), as a data URL. I blessed the three Conduit page transcripts, whose 66 changed lines are each an avatar `src`, and four goldens whose only change is the line numbers of `Author.beni`. I opened #1912 for the calendar that #239 needs, and I asked the owner four questions: `conduit-fixes-q1` (where the calendar goes), and `q2` to `q4` for the Markdown library of #240 (where it goes, raw HTML, the entity table).

**What I learned**

- `beni build` writes no file but the program and the page shell, so a data URL is the one way to give an image without a second host.
- Percent-encoding only `"`, `#` and the line ends keeps the file unchanged: `decodeURIComponent` of the URL gives the 449 bytes with SHA-256 `aca1167e…`. The unchanged file costs 100 bytes of brotli more than the issue's shorter SVG (+214 against +114, release `_main.mjs`).
- The page driver prints attribute values with its own `quote()` (`tests/browser/driver.mjs:1924`), so a `<` in a URL prints the same in happy-dom and in Chrome.
- `browser-direct` is gone, and Conduit builds only for `browser-tea`. The memory note on release size still names `browser-direct`.
- `BENI_WRITE_EXPECTED=1` can write a golden some seconds after the last `blessed` line that it prints. Check `git status` after the job ends, not while it runs.
- The page harness does not pin the time zone (this host is Europe/Berlin, CI is UTC). A date in the user's zone needs `TZ` pinned before a fixture can show it.
- The HTML5 entity table is 2,125 names and about 9.5 kB brotli, 34% of Conduit's release build. The HTML 4.01 table is 252 names and about 1.2 kB.
