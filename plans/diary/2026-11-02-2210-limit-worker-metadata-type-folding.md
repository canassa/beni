## Limit allocation-type folding to worker metadata

**What I did**

Marked the compiler's worker-definition metadata guard with its own internal
unary operator, printed as ordinary typeof. Source typeof expressions keep their
normal evaluation in every realm. Allocation refinement now respects possible
undefined and null/function combinations. Added Chrome coverage for cells read
before a function/object write, and a gate assertion that a parent worker retains
forced child abandonment while its leaf child omits it.

**What I learned**

An allocation set is only the heap part of a points-to value. Its separate null
and undefined flags matter before concluding what typeof returns. Scoping an
optimization to its intended emitted site also needs an explicit IR marker;
being in the same realm is not a sufficient boundary.
