## 2026-10-21 03:54 CEST — compose the inline handlers' field reads through their load cells

**What I did.** Issue #562, on dagon (worktree `beni-compose`):
- Reproduced the diagnostic with a temporary build that counts `foldSite` per summary and names
  each summary's var and the reason it was joined. At N=64 the 609 summaries that fold about
  200 sites are not copies of `$model`. They are the parameters of the `inline` bind wrappers
  (`$bind$72($elements$8, $model$5.w1)`), passed a member read, and the `$t` locals bound to
  one. Their sites are widget records made in `Main` by the inliner, not `Main.Model` records.
  One summary, `Main$pushed`'s keyed model parameter, folds the 349 model records because the
  filter's link rule forbids the link. It stays so.
- `Pts.copySource`: a binding, an argument or a `return` of a member read that no guard narrows
  is a copy edge from the read's load cell, as a name's was already.
- `Pts.linksAcross`: no summary link across a site's own var (`VSet.site_var`) or a var two
  summaries deep (`VSet.depth`).
- An assignment stays a join (measured: composing it costs 99.7M edges at N=64).
- Four unit tests and `emit/release/inline/MergedChildren` (5 077M → 3 417M instructions). The
  golden was blessed with the base compiler.
- N=64: 2.03 s / 623 MB → 0.69 s / 247 MB, edges 7.54M → 1.36M. The `backend.md` §9 *As built*
  note has the table.

**What I learned.**
- A summary may be linked only where the number of summaries stays bounded. The first version
  linked into every var. It made summaries of site properties and summary vars through every
  spread record, and was 2–8× slower. The next one excluded site vars, and it looked right on
  all three programs. Then the gates' `run/` corpus ran 181 release builds out of memory: a
  function that passes `x.next` back to itself builds an endless tower of summaries of
  summaries' vars. The depth cap is what makes the count finite. A green measurement on three
  programs said nothing about termination; the corpus did.
- The issue's guesses (a guard in view, an assignment) were not the cause. The diagnostic
  counted no fold from a narrowed binding, and composing the assignment is a large loss.
- Another process wrote into my local scratchpad copy of `Spec.zig` mid-session: a queue
  rewrite with `pts_joins`, not my work. The Edit tool's "modified on disk" notes were that. The
  dagon worktree held the right file throughout, and I worked from it from then on.
