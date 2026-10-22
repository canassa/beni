## 2026-10-22 07:46 CEST — pointer skill notes after the merge

**What I did**

- Rebased the pointer events branch (PR #548) onto master. 551 hash files and
  the two `ownership/WordsBrowser` goldens conflicted. I took master's side of
  each, recorded the hashes again and blessed the goldens again. The goldens'
  diff against master was the same as before the rebase.
- After the merge, corrected the pointer text of the beni skill
  (`skills/beni/references/markup.md`). `user-select: none` and
  `-webkit-user-select: none` stop a long press that selects text, and
  `-webkit-touch-callout: none` stops the iOS long-press menu. None of the
  three stops scroll or zoom. The text also says that a program cannot call
  `Html.pointer`, and that on iOS a double-tap still zooms an element with
  `position: absolute`.

**What I learned**

- Jayson's machine sets `rebase.updateRefs` in `~/.gitconfig`. A branch made as a backup
  at the head before a rebase moves with the rebase, so it keeps nothing. Keep
  the old head as a tag, or read it from the remote branch.
- After `git rebase -X ours`, compare the sorted `+`/`-` lines of the
  hand-written files before and after. The option takes master's side of each
  conflicting hunk, also in files that are not generated.
