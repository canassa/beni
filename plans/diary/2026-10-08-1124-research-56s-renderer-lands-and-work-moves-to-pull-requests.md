## 2026-10-08 11:24 CEST — Research 56's renderer lands, and work moves to pull requests

**What I did**
- Found research 56's slices A and B with three review rounds (25 commits from 10-04) unmerged in
  an agent worktree. Rebased them, ran the gates and opened PR #3. Slice C is not among them; it
  is still only on `r56-slice-C-over-budget`.
- The owner moved all work to GitHub pull requests reviewed by the Claude workflow. I recorded the
  procedure in CLAUDE.md (PR #4). I also fixed the review workflow, which could not read the PR it
  reviewed: only the inline-comment tool was allowed, so its first run was denied six times and
  posted nothing.
- Answered the `@claude` reviews.
  - Fixed: a turn is now a guard, so a throw from the runtime itself stops the page instead of
    leaving it never rendering.
  - Fixed: a group whose only read is `undefined` (a `⊤` under `--release`) now runs at mount; it
    used `NaN` fields, and `browser/dom/UnitReadMount` failed before and passes after.
  - Declined the reviewer's plain flag reset, because rule 9 says an unknown error must stop the
    program.
  - Found a separate, older defect: an event message of `⊤` is dead under `--release`. Queued in
    the handover §6 item 8.

**What I learned**
- A branch-history listing that concatenates two `git log` ranges reads as one branch: I credited
  PR #3 with slice C, and the reviewer caught it.
- The review is worth having but not obeying. One finding needed a better fix than the one it
  suggested; one needed a non-inlined function to reproduce at all (a `⊤` literal is `null`, and a
  trivial `⊤` function folds to `null`).
- Check a claim before telling the reviewer it: I said tuples cap at three; they do not.
