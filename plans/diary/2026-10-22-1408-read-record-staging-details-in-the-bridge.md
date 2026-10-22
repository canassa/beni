## 2026-10-22 14:08 CEST — Read record staging details in the bridge

**What I did**

While validating #210's recursive-function precision, the bounded compiler
bridge stopped on a record-read staging detail. Added exact parsing for
`capture` and `hoist` detail lines, including `before` and `after operands`
placements. These lines carry positions, not list or record verdicts. The
existing demand/record count partition checks remain unchanged.

Added a black-box protocol self-test that delegates to the real compiler,
adds each supported detail shape to its dump, and verifies that malformed
detail text still fails the bridge. The bounded CI bridge runs this control
alongside its existing failed-batch and capture controls. Tracked the gap in
#733; no oracle or generator source changes were needed.

**What I learned**

The record-count parser fix from #418 had landed while the O1 worktree was
on an older base. Rebasing supplied that fix and the browser-inline platform
migration. The additional capture/hoist lines are a separate reporting
surface and must be recognized without treating them as demand sites or
silently accepting arbitrary unknown dump lines. Builds and validation stay
on dagon, with the self-hosted compiler and no measurements.

The bounded bridge completed against the recursive precision compiler:
2,139 programs, 1,473 translated and value-checked, zero confirmed unsafe
accepted originals. Its fourteen program leads were runtime-unconfirmed;
other site leads were blocked by existing refusals. The campaign used the
standard CI bound and both generators at all three recorded seeds.
