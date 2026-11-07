## 2026-10-29 23:40 CET — Ownership v2: the call view's node, specified (S3b slice 2)

**What I did**

- Specified `view(T, E)` in §2.3, §2.11 (*Representation of a view*) and §3.3: the node, its
  step-at-a-time expansion and memo key, re-rooting at a parameter, cycles, links and folds, the
  readers, and blocks forcing a view at publish. §8's S3b note splits slice 2 into three PRs.
- Measured the starting point on #1261: the push chain spends about 60 continuation records a call
  (670 / 6 070 / 60 070 at 10 / 100 / 1 000 pushes). `ValueCellsGuards.rebuilt` spends 13 717.

**What I learned**

- Since #1198, "growth 0" says nothing about a graft: the source continuation pays for it. The
  target has to be stated in continuation per call.
- Forcing at publish, not encoding, keeps the block format free of class references. That is why
  it is S6's import that would have to change, not the format.
