## 2026-10-21 14:48 CEST — constructor folding steps back and finishes in one pass

**What I did.** Issue #589. With the inliner uncapped (#591), the research dashboard still took
3 structural passes (capped) and 6 analyses because of constructor folding. I instrumented
`foldConstructors` and found that the refold was not an unrolling, and not the `return f(…, g(…))`
arm the issue named (that arm folds nothing on the dashboard). It was `const x = e; return R`
taking one binding of a run of field bindings per pass. The walk only went forward after a fold,
so the binding before it waited for the next pass and its analysis, and `max_passes` cut the run
short. The walk now steps back one statement after each fold. That folded some unread bindings of
pure calls into returned literals, where `dropKeys` (inert values only) then kept them. So an
unread key now goes under `effectFree`, the rule for an unread binding. The dashboard takes 1 pass
and 4 analyses, and `specialise` at N = 64 went from 247.6 to 165.0 ms. `bench/corpus` and
development output are unchanged. 45 `run/` programs and 7 `emit/release` goldens moved, net
−588 brotli bytes, and 4 programs grew a few bytes (#601).

**What I learned.** The structural loop was also an extra analysis between folds, and a few size
heuristics leaned on it. A literal longer than the read it would replace stays a read in an
expression, but replaces a binding read once. So folding earlier can lose a constant that a
binding would have exposed. `patchStmt` ignores `dropKeys`' result, so a dropped key never
starts another round. That is the lead in #601. The issue's own guess (an unrolling of
`return f(…, g(…))`) was wrong. The debug prints on `foldAt`'s arms showed this in one build.
