## 2026-11-04 21:28 CET — A short link for each playground sample

**What I did**

- Issue #1903, worker `playground-sample-links`. Each sample in `playground/samples/index.json` has a
  stable id: `counter`, `todomvc`, `ball-machine`, `fibonacci`. The page sets the address to
  `#sample=<id>` when it opens a sample, and **Share** copies that short link while the sample is
  unchanged. A person's change clears it, and **Share** then makes the code link, as before.
- Spec first: `playground.md` §4.3 (the ids never change and are never used again), §4.5 (the
  short link), §6 (the checks) and a note in §10.1.
- I wrote it in JavaScript first. Jayson then asked: "write it in beni already to avoid introducing
  more js". The short link needs no host API of §10.6, so it is `playground/src/Share.beni` now,
  and `share.js` gets no new code. `page.js` keeps the wiring until the page is beni (§10.7 step
  7). The branch stacks on #1902, which brings the build of `playground/src/`.
- Tests: `page_test.mjs links <library>` on the beni build, 15 fragments compared with
  `URLSearchParams`; the ids in `samples`; the Chrome test selects each sample, opens a short link,
  an unknown id, edits, and clicks **Share**. Master's page files fail the new Chrome checks (10
  FAIL lines). The Chrome test: 134 ok, 0 failed. `zig build gates -j2`: green in 289 s.

**What I learned**

- `Url.percentEncode` is `impure` in the core interface. An id is limited to `[a-z0-9-]`, so the
  short link needs no escape, and `sampleFragment` stays pure.
- The Chrome test needs only a built site. To prove that new checks fail on old code, copy
  `zig-out/playground`, put the old page files into the copy, and run
  `node tests/browser/playground.mjs <copy>` in `nix develop .#browser`. No heavy-run slot is
  necessary.
- In this repository "the owner" is Cesar Canassa. A request from Jayson is quoted with his name.
