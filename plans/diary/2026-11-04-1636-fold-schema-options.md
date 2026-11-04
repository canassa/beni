## 2026-11-04 16:36 CET — Fold schema options and guarded result reads

**What I did**

Corrected the native catalogue's three non-coercing Number predicates to pure,
regenerated Data.beni, and carried those operations into JsIr for literal folding.
Added held-sentinel branch refinement, closed-array length facts and recognition
of a small return inside a sole unlabelled block, with narrow black-box fixtures.
An early ValidatorRun probe measured 841 → 751 brotli bytes before the array work.

**What I learned**

Concrete Opt sites already have checked identity lowering. Generic workers lose
the required payload representation before JavaScript specialization; threading
that evidence is deferred to #1865 by the manager. This is Part of #1859, which
stays open. The unmodified baseline gates have inherited failures. Dagon's btrfs
metadata exhaustion stalled writes; the manager requested a source checkpoint
before gates and final benchmarks, which wait for the disk all-clear.
