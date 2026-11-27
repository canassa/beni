## 2026-11-27 10:21 CET — A fake child notes the write it fails

**What I did**

I answered the review of the three commits that changed #2023's work to `stdin : Input` (PR #2692). This entry continues the one of 09:34.

- **The review's one finding of substance.** The case `an empty text, EPIPE` of `run/ChildProcessInputFaults` printed the same line whether or not the platform wrote to the pipe: the fake child's pipe closes after `end` on the two routes. The test platform's child now notes each write that it fails, with its length, and the fixture prints the notes: `a write of 0 bytes failed with EPIPE`, and `of 4 bytes` for the text.
- **The proof.** A mutation of the emitted JavaScript that calls `end()` with no text for `Text ""` passed the old fixture and fails the new one.
- **The contract.** `boundary.md` §9.14 (h)'s list of facts with no fixture has a third fact: Node gives `EPIPE` for the end of an empty text when the child stopped before the `spawn` event. A real child shows that only when the event is held back.
- **The gates** ran two times this session, each on a local merge of the branch with `origin/master`, which was 21 commits ahead: exit 0 each time.

**What I learned**

- **A line that is the same on two routes pins neither.** The fake child went on at the `close` of its input pipe, and `close` comes after an `end` that wrote nothing and after a write that failed. A fake must note what was done to it, and not only that it finished.
- **A reviewer that cannot run Node still finds this.** It read the fake and asked which route ran. I had the measurement (`Writable.end("", "utf8")` calls `write` with 0 bytes), but the fixture did not show it.
- **A branch that is behind `master` is gated on the merge.** `git merge-tree --write-tree` gives the tree of the merge with no checkout. The gates ran on a detached merge commit with that tree, and the push stayed a fast-forward of the branch.
