## 2026-10-23 08:31 CEST — a recursive region goes on across a cast, and the cut is gone (§16.7 (c))

**What I did.** Built the manager's decision on #853, option 1: a cast now ends only a closure's
region. A recursive type's region goes on across it, so a `Node` read through `Js.Value` below a
`Node` folds into the enclosing region. The *Stopped* note in §16.7 is replaced by an amendment
that gives the rule, its soundness argument, and where F2's rule still holds. Measured on a safe
self-hosted build, core as user code takes 1.27 s against master's 2.31 s, and `Schema.shapeOf`
has 1 344 entries against 2 848. No ownership-corpus verdict changed except the new `PathCut`.
`ownership/core/CastRegion` pins the shared and apart twins through one and two casts. The
`bench/ownership-everywhere` tables match master, apart from one new error.

**What I learned.** Without the cut, `run/EvidenceDagBuildDepth32` under `--ownership-everywhere`
reaches the `entries` limit: `w5`'s result is a tuple 16 levels deep, and its summary needs
1 276 786 entries. It is loud, not silent, and it fires only under the hidden flag. It is still a
refusal of a program that master accepts, so I left the merge to the manager.
