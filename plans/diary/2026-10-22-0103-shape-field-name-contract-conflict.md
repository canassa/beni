## 2026-10-22 01:03 CEST — Shape field name contract conflict

**What I did**

Opened #653 and created the dagon fix-shape-field-names worktree from current
origin/master. Read CLAUDE.md, boundary.md §4, schema.md §6 and A.6, and the
emitter's shape field pinning and field assignment. Reported the explicit
contract conflict in #653 and stopped before changing the contract or code,
as the task required. Removed the in progress label while awaiting the owner.
No builds, tests, output size measurements or speed measurements were run.

**What I learned**

The 2026-10-19 owner decision explicitly requires source field names for every
record a live shape reads, even though it also says nothing outside beni reads
those records. The proposed release renaming therefore requires superseding
that rule. The existing record entry format already separates host keys from
output names, and Emit.pinShapeFields implements the current restriction.
