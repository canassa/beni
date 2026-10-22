## 2026-10-22 11:54 CEST — Inline distant widget handlers

**What I did**

Opened #708 and reproduced a browser-inline widget handler left as a separate
binding after 64 local event registrations. Added a release golden and its
unchanged development twin, and proved the release golden fails with the fix
set aside. Opt now records each expression read's node, statement and list in
its existing counting walk, so a single later read in that same list needs no
forward scan. Updated backend §9. All edits and validation used one dagon
worktree and the self-hosted flake toolchain, with no measurements.

**What I learned**

The emitted `let` was misleading: Spec preserves the handler's `const`, and
Print joins declarations as `let`. The actual obstacle was findAnyUse's
64-statement cutoff. Recording the owning list keeps branch, closure, loop,
try and loop-head exclusions while removing distance from the lookup.
