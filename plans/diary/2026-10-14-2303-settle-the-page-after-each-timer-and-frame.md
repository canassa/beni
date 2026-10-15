## 2026-10-14 23:03 CEST — settle the page after each timer and frame

**What I did**

Rebased #103 onto master (with #96, #97 and #106; gates green) and marked
it ready, then rebased #109 onto it (gates green). Opened #111 and PR #112
(stacked on #109): `advance` and `frame` call `settle` after each timer
and frame, in place of one real turn. The new fixture
`browser/tea/AdvanceSettlesEachTimer` showed spread 10 for both a timer
burst and a frame burst with #109's driver, in happy-dom (3 runs) and
Chrome (2 runs), and spread 0 with this one. Full `test-browser` passed.
Answered the `@claude` review with three text fixes.

**What I learned**

`beni fmt --check` in a pipe with `tail` hides its exit code; the
`beni-fmt-check` gate caught the fixture's layout. A rebase with
diff3 conflicts in an append-only diary resolves mechanically: the base,
then the upstream's added entries, then mine.
