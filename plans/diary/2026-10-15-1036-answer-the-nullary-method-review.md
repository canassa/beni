## 2026-10-15 10:36 CEST — Answer the nullary method review

**What I did**

Opened PR #126 and requested `@claude review`, leaving it unmerged. The automatic
review passed without inline findings. Answered the explicit review's concerns
with the `Session.run` / `Artifacts.resize` lifecycle: every run frees and reloads
frontend BIR before resolving and checking, even on the same Session object.
Documented that boundary, the absence of live borrowed extra slices at the
rewrite, allocator ownership, and the coupling to Elaborate.siteRows. Removed
the unused diagnostic parameter. Added a numeric-kind default diagnostic and
a black-box cache regression that changes a dependency's receiver type from a
list to a record and back, comparing warm and cold output trees. Both new program
runs passed and their hashes are recorded. The full checks now finish with
1,302 passed, 15 skipped and only the two known macOS case-folding failures.
Merged master's CI guard and preserved both branches' appended diary entries
after a diary-only conflict; compiler code and validated fixtures were unchanged
by that merge. The x86-64 Linux budgeted gate remains owed.

**What I learned**

The mutable checker input is the resolved session copy, not the persisted
frontend artifact. A future daemon that retains per-file artifacts will need
to keep pristine frontend BIR separately. Direct source dots always start with
parentless callee wanteds, including explicit where requirements; the parent
guard deliberately excludes inherited evidence, covered separately by the
generic-evidence runtime fixture and the explicit-where arity diagnostic.
