## 2026-11-05 01:53 CET — Native projection tip merge

**What I did**

Merged workers-hostfree 41d030a2f9 into the #1937 branch without rewriting
its reviewed commits. Kept both appended HostFree and build-test sets and
both ownership catalogues. Re-generated every existing native source through
the generator and formatter: byte-exact, with no hand-merged generated code.
Re-read the first-class intrinsic helper after the Browser bridge overlap
and re-pinned its seven cell/Opt entries; the bridge cases return before the
existing core handling. Rebuilt the two conflicting renderer release goldens
from the merged compiler after proving their base output equals the tip's
committed goldens.

Native byte-exact generation, all HostFree cases (unchanged renderer six
refusals and generated-wrapper zero diagnostics), NativeHostResults,
NativeHostProjectionReference, actual private-projection escapes, bridge
fences/behavior, embedded v2 ownership pack, ownership audits, renderer
module goldens and both format checks pass. No full gates rerun, per the
manager's bounded merge-validation request.

Measured against 41d030a2f9 using Part 2's already captured base: 317 emit
JS files, 316099 → 315478 B summed brotli Q11 (-621). Empty browser/tea
pages 1611 → 1563 (-48). Explicit #1923 debt on this base: HTTP +17,
effects +8, NativeMessageData +28 B. Updated only six emit goldens whose
base compiler output exactly equals the committed tip. Existing red goldens
remain. Evidence is in ~/worktree-evidence/wd-size2/host-values/merge/.

**What I learned**

Combining the typed Browser bridge with the native wrapper change improves
the measured size delta; old-base totals cannot describe the merged branch.
Keeping base artifacts and proving byte identity lets the two lanes share
validation and preserves unrelated red goldens.
