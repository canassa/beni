## 2026-11-23 17:08 CET — rebase the title write-set change on master

**What I did**

- Rebased #2440 on `origin/master` `f84cdd28cc`.
- Master took the markup interface to version 1.31 while this PR used 1.26. `programRetitles` is now version 1.32: `src/markup/Interface.zig`, the `inline` lowering's target, `boundary.md` §9.4.6 and `browser-inline.md` §10.2.
- The `retitleAfter` change merged without conflict. Master still had the same two direct retitle calls that the PR replaces.
- `zig build gates -j2` through heavy-run: green in 7 minutes.

**What I learned**

- A PR that adds an interface version conflicts with every other PR that adds one. Take the next free number at the rebase and change the docs with it. The PR's earlier diary entry keeps the old number, because the log is append-only.
