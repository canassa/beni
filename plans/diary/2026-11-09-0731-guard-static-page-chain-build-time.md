## 2026-11-09 07:31 CET — Guard the build time of a static page over a long conditional chain

**What I did**

- Took issue #2089: the DOM root proof of #2026 ran with no site cap, so a
  static page over an n-long chain `v_k = if c then v_(k-1) else { a = k }`
  took quadratic time to build.
- Found that the root proof is not on master. PR #2026 merged into
  `workers-hostfree`, not into master. The owner deleted `workers-hostfree` on
  2026-11-06. `chooseRoot` is only on the old branch `dom-root-plan`.
- Timed the issue's program on master 9d5a878494 (ReleaseFast, wall): 1 000 /
  4 000 / 8 000 / 16 000 / 32 000 links build in 24 / 45 / 75 / 141 / 258 ms.
  That is linear.
- Added the `test-perf` scenario "building a static page whose model is a long
  conditional chain is linear in its length" (`tests/blackbox/perf_test.zig`).
  It builds for `--platform=browser` at 8 000 and 16 000 links. On master it is
  green: 535.7 M and 1 034.8 M instructions, a ratio of 1.93 (bound 2.5).

**What I learned**

- A PR that GitHub shows as "merged" can have merged into a stacked branch. Check
  `baseRefName` before you look for its code on master.
- No cap, no corpus fixture and no contract amendment were necessary: there is
  no root proof on master to cap. The scenario is the guard for the day a root
  proof lands again.
