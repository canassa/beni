## 2026-10-23 12:50 CEST — A leftover finaliser keeps its body's context

**What I did**

- Fixed #811. A command body with no fiber runs on core's record outside
  any fiber. When it throws inside a `bracket`, the teardown runs the
  release in a new fiber with no slots, so the release logged with the
  default context. In a fiber, the same release has the body's context.
- The fixture `browser/tea/LogTeardownContext` comes first. Its body keeps
  the arm's context, opens a `bracket`, then `Log.annotate`, then another
  `bracket`, and throws. The inner release logs with both annotations, the
  outer one with the arm's only. On `master`'s `core/Task.beni`, both
  releases log with no context.
- The fix is in `teardown`: before each finaliser that it moves from the
  record, the teardown fiber takes the record's slots, except the
  scheduler slot. `boundary.md` §9.8.14 (d) step 4 has the amendment.

**What I learned**

- One copy of the slots at the start of the teardown is not enough. A
  restore among the leftovers sets the record's slots, not the slots of
  the fiber that runs it. A mutant with one copy gives the outer release
  the inner annotation too, and the fixture catches it.
- The scheduler slot must not follow. It decides which queue resumes a
  fiber, and the teardown's fiber is the program's.
