## 2026-10-23 03:24 CEST — Retain cast occurrence guards

**What I did**

Closed the remaining occurrence-condition review question on #748, Part of
#286. A reduced program cast `(xs, xs)` to a list of lists, then passed it
to `List.map` with a callback that pushed onto each inner array. The checker
accepted that write even though both positions held the same array.

The construction had recorded its value-scoped occurrence guards. Cast
projection retained them at a runtime-unknown path, but spine checks did
not read that path, so the callback requirement became vacuous. Spine and
root-separation checks now include runtime-unknown roots, consistently with
write-root selection. Root condition annotations also survive uncertain
and repeated casts. Conditions stay with their containing value; this fix
does not lower an allocation's global conditions because another view
merges positions. Dated amendments precede the final implementation, and
summary format 33 invalidates the old read semantics.

Added CastOccurrence with the refused duplicate-array case, accepted
separate-allocation twin and both outcomes through a growing cast. Fresh
and cached checks agree. Answered the variable-key question with the
existing ownership cache rule: dependency source keys are folded into
importer hashes transitively, so declaration reorders cannot reuse stale
blocks through an unchanged ordinary interface.

Rebased onto master 2178d22b4. Full condition/canonical cross-checks pass
core, every platform, ownership/core and the changed-consumer cache test.
The complete ownership corpus passes with existing verdicts and snapshots
unchanged. The final locked, unfiltered self-hosted gates pass on dagon.
No local Zig, LLVM builds, measurements, added caps, weakened checks or
raised limits.

The existing cut remains. #820 still blocks its removal in (c); the owner
selected (a), (d) lvl, (e), then (c). The uncut evidence is preserved outside
the worktree. Scratch work stays under zig-out/scratch with TMPDIR set;
the only /tmp path used is the shared gate lock.
