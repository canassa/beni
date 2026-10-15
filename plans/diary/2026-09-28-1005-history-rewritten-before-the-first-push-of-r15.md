## 2026-09-28 10:05 CEST — History rewritten before the first push of R15

**What I did**

- Squashed `7fdf8a2` (which promoted two fixtures one commit before their fix, so it failed
  the gates on its own) into R15-fix-B, then pushed `master`. The tree is byte-identical;
  only the hashes after `1bec73c` changed. Hashes quoted in earlier entries, in
  `plans/checker-rewrite.md`, `plans/checker-findings.md` and in
  `bench/compare/results/2026-09-27.json` (`beni_commit`) refer to the old ones:

  | old | new | commit |
  |---|---|---|
  | 7fdf8a2 + 34c3cd6 | 4563484 | R15-fix-B (with the emit specifier tables) |
  | 763b7c8 | 4f72a7e | R15-fix-A |
  | 346268b | 718fb4c | diary |
  | 17a42d0 | bbb08ea | compare generator (the benchmark's beni) |
  | 60a9558 | 1c8588a | compare first run |
  | 830e547 / 669826f | ce16243 / c474673 | R15-fix-C red / fix |
  | 01d0f21 | 83918e1 | R15-fix-D |
  | 8a68e12 | 5a90894 | R15-fix-E |
  | 31dd4bd | 5ebd0c1 | R15-fix-F |
  | 88256a3 / 6434900 | 6c54e1a / 7fb9172 | R15-fix-G red / fix |
  | c175745 / 3984c7c | 8c8937b / 275b203 | R15-fix-H red / fix |
  | 443a88b | f1aa9c3 | diary |

**What I learned**

- Rewrite before the first push, never after: nothing outside this machine held the old hashes.
