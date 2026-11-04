## 2026-11-03 08:42 CET — Unboxed cell wrappers

**What I did**

Implemented the manager's general rule for a nominal with one constructor and
one Js.Cell field: the cell is the representation in development and release.
Aliases of the field expand before classification. Debug prints <internals>;
Ref, record, multi-field and multi-constructor controls keep their old shapes.
The representation fact participates in the dependency digest.

The new recursion and emission fixtures pass in both modes and fail with the
pre-change compiler. An isolated comparison of run/, browser/tea and emit/
checked 2,681 successful builds and 12 matching refusals. All 68,672 emitted
files, including 25,128 maps, matched byte for byte. The ordinary corpus also
reported golden and ownership failures present in both snapshots; this is not
a claim that the gates pass. Logs are in the lane's worktree-evidence directory.

**What I learned**

Mutually recursive cell aliases need a nominal to stop expansion, but the
ordinary development constructor adds an avoidable object around the cell.
Reusing its existing identity keeps the source type boundary without that cost.
Any capture packets are still WIP until the shared checked-data witness lands.
