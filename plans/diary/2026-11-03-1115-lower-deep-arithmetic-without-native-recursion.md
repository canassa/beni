## 2026-11-03 11:15 CET — Lower deep arithmetic without native recursion

**What I did**

Reproduced #1673's 4,095-term written addition on workers-hostfree in development
and release. Confirmed workers b688a8ffd2 and master 9a50f9b1f3 pass both existing
black-box cases. Bisected the hostfree regression to 59045729fd, whose list
primitives enlarged the recursive operator frame. Added a corpus reproduction
and a mixed-operator evaluation-order case, and replaced arithmetic traversal
with an explicit scratch work stack that shares operand ordering and expression
completion with the ordinary lowering path.

**What I learned**

The earlier 3161ab0362 fix moved general-call temporaries out of arithmetic's
recursive path, but left the path recursive. GDB on f238c3d355 found a repeated
16,544-byte stack stride; 4,095 terms exhaust the existing 64 MiB thread stack.
Unrelated operator additions can therefore revive a fix based on frame size.
The iterative traversal retains source grouping, hoists, keys and spill boundaries.

Validation: the entire abuse-wide suite and both new corpus fixtures pass with
the self-hosted ReleaseSafe compiler, in development and release. The exact new
wide fixture segfaults in both modes on clean base 6a5c6fd86e (GDB captures).
Locked full LLVM gates on that clean base and on the fix have identical failures:
48 named tests, 289 corpus failure instances and 24 formatting failures, with
zero added failures. The integration manager authorized delivery on this exact
base comparison while the inherited failures are repaired separately. The
ordinary operand-order program's emitted trees, including source maps, are
byte-identical before and after in both modes. Both new fixtures have run hashes.
