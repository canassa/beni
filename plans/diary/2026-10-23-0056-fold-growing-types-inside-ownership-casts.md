## 2026-10-23 00:56 CEST — Fold growing types inside ownership casts

**What I did**

Resumed #748 and #760, Part of #286. Specified the owner's composed-type
fold as dated §16.7 amendments, then extended the existing growing-call
mark to terms inside full cast types. The first crossing stays exact;
later crossings fold only the growing term. Fixed surrounding types remain
complete, and wildcard views keep every possible holder conservatively.

Added the accepted erased-polymorphic-recursion case and cast-write negative
twins, including record, tuple, callback, deferred and cached-local-class
routes. Completed the physical trailing-cast identity, folded-occurrence
conditions and portable-variable audit. Deferred captures now compose their
whole binding before normalization and propagate metadata-only changes.
Unknown descendants retain their prefix when selecting a write root.
Type views share a dense column; call-scoped alternatives have sparse keys.
Rebased repeatedly through the concurrent checker changes.

On dagon, the locked run-hash refresh and unfiltered gates pass. The complete
ownership corpus passes with every existing accepted/refused verdict intact.
Full cross-checks pass core and every platform, ownership/core (including
FullCast and GrowingCast), and the changed-consumer cache regression.
The first final gate caught two dense-id maps; both were corrected before
the successful rerun. No local Zig, LLVM, measurements, new caps, raised
limits or weakened ownership assertions.

**What I learned**

The growing vocabulary of full cast types is bounded by applying the adopted
composed-path fold inside the growing substitution. Folding the entire type
would lose the fixed context that makes distinct casts useful. A delayed
capture crosses the enclosing call even before its body runs, and equal row
counts do not imply equal crossing metadata.

A root wildcard can name a written object; a wildcard after a precise prefix
still names a descendant. Confusing those cases caused the browser-tea
precision regression and is now fixed.

The separate cut-removal experiment exposes the native recursive-schema
constructor fold gap already tracked in #201. Its code and evidence are
preserved outside this PR. This is a prerequisite for §16.7(c), not a cast
marker design wall; the existing cut remains for that separate step.
The wider optional oracle's unrelated #427/#694 failures remain tracked.
