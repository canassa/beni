## 2026-10-22 08:25 CEST — slice 6, part 2b: one rewrite per solve

**What I did.** I removed the rounds. Each structural pass now solves once and rewrites once from
the final facts. The cascades the rounds used to find are found inside the rewrite: a
statement-local patch fixpoint, the liveness of local bindings, parameter drops that iterate,
unread keys judged by what the patch left, and declined reads written by the final counts.
Reachability before the solve keeps unreferenced declarations out of it. `self_assign` and
`iife` moved into the pass loop. `spec_analyses` became `spec_solves`. Along the way I found
#685: fact 3's call graph misses calls, so body executability was not sound. I fixed it in #686 by
making every body a root. I opened #689 (reachability inside the solve), #690 (an inlining shape)
and #691 (the cost of one huge statement).

**What I learned.** Most of what the rounds bought came from the structural passes and the rewrite
feeding the next solve. Three mechanisms recover nearly all of it without a round: patching to a
fixpoint per statement, liveness, and reachability. A dead binding may only be removed when its
initialiser does nothing. Lowering keeps only the bindings it expected to go unread, and `Opt`
was safe only because it never cascades; `run/QuestionOrder` caught the difference. A pass that
walks every preorder is the first thing to look at when the instruction count grows: the unread-key
pass cost 20% of N = 64 until it asked only the keys fact 3 had seen read. And a dump hook that
prints Spec's IR after each rewrite, kept out of the tree, answered in minutes what tracing by
node index could not.
