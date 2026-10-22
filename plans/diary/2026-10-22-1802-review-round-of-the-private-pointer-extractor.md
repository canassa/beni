## 2026-10-22 18:02 CEST — review round of the private pointer extractor

**What I did**

- Rebased PR #764 on master `9674026fe`. #610 moved the `dev` lines of
  five run-hash files that the PR also changed. During the hash run, two
  more master commits changed `Browser.beni` and both `Tea.beni` files, so
  all 70 hash files of the PR moved again. I put the four other commits on
  the new master and recorded every run hash again in one commit.
- Added a dated amendment to `boundary.md` §9.8.20 (d): only `Html` can
  call `pointer` now. A package that may import `Js` can still make a
  `Pointer` with `Js.to`.

**What I learned**

- `git rerere` stages a resolution that it recorded in an earlier rebase.
  Before `rebase --continue`, compare each staged hash file with the side
  you want (`git diff --cached origin/master -- <file>`).
- `nix develop .#browser` inside `nix develop` gives Chromium a socket path
  under two nested temporary directories. That path is too long, and
  Chromium does not start. Start the browser shell from the top shell.
