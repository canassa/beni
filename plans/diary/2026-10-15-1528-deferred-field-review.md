## 2026-10-15 15:28 CEST — review of deferred fields

### What I did

Opened PR #140 and requested @claude review. The static review found no blocking
defect and asked about assertions, late wanted metadata/ranks, effect sentinels
and poisoned receivers.

Added safe-build assertions at new/strictly lowered obligation and method edges,
instead of restoring a scan of the entire accumulating owner set at every younger
boundary. Documented late-wrapper rank folding and the two effect-array readers'
sentinel contract. Added diagnostic fixtures for reverse resolution and poisoning,
and a dispatch fixture whose second receiver resolves first in a deeper binding.
Their new goldens come from the #135 compiler and match this implementation.

Built the successful late-resolution fixture cold and warm at jobs 1/8 under
both compilers. Every emitted file matches, and Node returns 14 on all four runs.
Retained its source/output fingerprints. Full self-hosted checks pass using
case-sensitive temporary files, LLVM unit/corpus/ordering/determinism/formatting
checks pass, and the ReleaseFast scaling scenario remains green (7/10 ms CPU,
ratio 1.42). The Linux instruction-budget gate is still owed.

### What I learned

The first TaskBoard annotations made its callbacks' receivers known too soon.
Its helpers now infer their rows before a typed application summary uses them.
An untimed diagnostic counter in an isolated worktree proves all 40 field reads
start flexible, versus all 40 starting as structures in the annotated version.
The patch and counts are retained; no timing uses that binary.

The ad-hoc dump verifier had accepted matching usage errors: dump has no
--no-cache flag, and types needs a file rather than a directory. Added a retained
verifier that rejects usage/I/O exits, checks successful output is nonempty and
requires structured diagnostics on error exits. All 128 unique valid requests
succeed and match, including full-project interface/dispatch/raw dumps and type
dumps for selected benchmark modules. Existing corpus/hash validation was
unaffected. Refreshed timings and final native profiles follow these changes.

Verification refinement: 19 of the initial 128 requests were context-dependent
core/markup fixtures and returned matching diagnostics without their harness's
privileged/platform setup. The final standalone verifier excludes them and
requires exit 0 for all 109 retained requests. Core/markup dumps remain covered
by the complete corpus harness with their proper context. Matching usage errors
or missing-context failures are not counted as successful dump evidence.
