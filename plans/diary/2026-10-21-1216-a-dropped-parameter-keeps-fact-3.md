## 2026-10-21 12:16 CEST — a dropped parameter keeps fact 3

**What I did.** Issue #582, the follow-up #575 found: a parameter `rewrite`
drops with its arguments no longer asks fact 3 to solve again when the
parameter's var held no object and was not `top`, no identifier of its
statement names it any more, and every dropped argument is a literal or a
name. The drop is recorded (`keepDrop`, `keepArgs`) and applied to the
kept state only when the next analysis keeps it (`applyKeptDrops`: the
site's `params`, the local, the arguments' nodes unreached), so passes in
between read what they read before. The identifier-to-literal exception now
admits a node with a type key: fact 3 reads keys only of site nodes.

**What I learned.** That was the whole of N = 64's third run: it now keeps
the state (runs/reused 6/0 → 5/1, 352 → 322 ms; `nowd` 306 → 281 ms; N = 16
unchanged), and 81 of 453 `run/` release builds keep a state against 3.
Recording the drop and applying it at the next analysis, rather than
patching `Pts` inside `rewrite`, matters for bytes: `inlineSmall` and the
other passes that may run before that analysis read `s.pts`, and patching
early would have changed what they saw.
