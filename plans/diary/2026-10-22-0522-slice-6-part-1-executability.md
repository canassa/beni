## 2026-10-22 05:22 CEST — slice 6, part 1: executability

**What I did.** I built the first part of slice 6 of the combined solver (#676). The extraction
now gives every constraint an exec cell: its module's top level, a function body, or an arm of
an `if`, `?:`, `&&` or `||`. The solver evaluates only the constraints whose cell is true.
Bodies become true through fact 3's escapes, `odd_caller`, the host's implicit keys, and the
executable calls that reach their sites. Arms become true through their tests' truthiness. The
rewrite's walks no longer join into the solved facts. A dead `?:` arm behind a test that may do
something is written as `0`. `SpecSelfGuard` (research 52's E2) folds, `PayloadReassign` loses
a dead object, and `SpecDeadArm` is new in both `emit/release` and `run/`.

**What I learned.** The first version left a dead arm unfolded where the old analysis had folded
it with values it never needed (`PayloadReassign` grew by a template). The answer was to write
the dead arm as `0`, not to evaluate it again. Fact 3 already records every caller of a function
site and whether something else calls it (`odd_caller`), so bodies need no new op for `new`.
A property of a site can have no var (`Prop.vals` is `none`), which `SchemaReadKeys` found.
