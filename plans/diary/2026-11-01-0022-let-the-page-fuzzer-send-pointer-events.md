## 2026-11-01 00:22 CET — let the page fuzzer send pointer events

**What I did**

- Rebased the branch of #527 onto master, after #817 and #862 merged.
  The page walk of the driver marks each element that holds a pointer
  handler, and on a page with one, three in ten view events of the
  fuzzer are a `pointer` step at a random point, id and type.
- A page with no pointer handler draws no extra number, so its
  sequences did not change: the new and the old generator drew the same
  200 actions in each of 30 seeds.
- A release-only plant in `Html.localX` that only a pointer step reaches
  fails the gate fuzz of `PointerInput` with the new fuzzer and passed
  it with the old one.
- Added T1 of the second review round of #862 to `boundary.md`: the
  note of `PointerNested` now gives the trusted move's count too.
- Removed the review worktrees of #817 and #862, after a check that
  they were clean and that no job used them.

**What I learned**

- After #862, the `dom` runtime keeps a pointer handler in the node's
  `$$` property both for a delegated event and for an event with a
  listener of its own. So one test of the node finds every pointer
  target.
- `zig build gates -j4` now goes over the 10 GB cap of `heavy-run`.
  `-j2` passed in about six minutes.
