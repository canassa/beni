## 2026-09-18 15:36 CEST — static dispatch adopted and landed; the loop; the cap

**What I did**

- **The decision.** The owner read report 19's options, asked what `where` is
  for, and chose option (b): adopt the whole spike — `where` is the extension
  point library authors need, the code is written and measured, and pre-1.0 it
  can still be withdrawn. Then went offline with "continue, don't stop; you are
  manager, planner and validator; Opus agents implement". The running order is
  `plans/queue.md`.
- **L1** (`89ce028`): the spec promoted in place to a normative document —
  file name and every §N kept, because ~100 files cite them — instead of the
  re-slice into four documents report 19 §14 assumed; `fast-compiler.md` §3.1
  records points 3 and 4 as reversed; pointers at every extended section;
  `checker.md` Appendix B brought back in line with `core/`. `master` had not
  moved since the branch was cut, so it **fast-forwarded** (owner-approved) and
  was pushed.
- **The stale hint** (`cfe4665`): two "numbers only" hints still named `<`.
- **Tail-call loop**: spec (`1cbf68e`) then code (`bbfc869`, built in an
  isolated worktree beside the checker slice and cherry-picked after).
  `$in$<i>` slots plus a per-iteration `const`, no temporaries; `foldl` and
  `foldr` are beni now and **no `foreign` value in the repository takes a
  function**. Validated by reverting `Lower.zig` and core to the parent: seven
  `run/` fixtures overflow the stack, the `emit/` golden mismatches.
- **The warning and the cap** (`9074538`, A.83) — **manager decisions, taken
  with the owner offline, each reversible in one commit**: §10.9's
  inferred-interface warning is on by default for the author's own package; an
  unannotated declaration inferring more than 64 method constraints is
  `too_many_inferred_constraints` and hands nothing on. The 3 000-link chain:
  4.4 s / 3.7 GB → 0.10 s check (re-run by me: 46 diagnostics). 64 because the
  pre-dispatch checker already refused such chains there. The slice also found
  `beni build` asserting that no warning exists before emit — a panic the
  moment one did.
- CLAUDE.md corrected: the no-currying change had already landed in the backend
  (the "still to come" line was stale), and both of the effects proposal's
  blockers are now discharged.

**What I learned**

- **"The branch never merges" was a statement about documents, not code.** The
  obstacle was rule 1 — a contract living in a file that called itself a spike
  while four documents described a different language. Promoting the spec in
  place cost one docs slice; the re-slice would have renumbered what a hundred
  files cite.
- **I briefed "evidence parameters are loop-invariant" and the spec author
  proved it a miscompile**: polymorphic recursion type-checks with an
  annotation and passes different evidence at the self-call. Second time today
  a brief's premise was wrong and the instruction "verify before you build on
  it" is what caught it (the first was my bisect). Briefs now state premises as
  things to check.
- **Elm's `$temp$` scheme is wrong here even with the temporaries**: the
  closures fixture prints `0 0 0` under it. The ordering hazard and the capture
  hazard are different bugs and only the per-iteration binding fixes the second.
- **A worktree per building agent works on this machine** and keeps two code
  slices honest; the cost is a cherry-pick and one more gate run on the
  combined tree. The harness moves the session's cwd into the worktree when its
  agent reports — never use bare `git stash` from there, the stack is shared.
- Replacing `foldr`'s JS array walk with reverse + `foldl` in beni did not
  slow R1–R6; R3 moved ~11 % the good way. Attribution unverified.
