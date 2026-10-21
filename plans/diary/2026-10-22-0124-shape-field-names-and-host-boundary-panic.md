## 2026-10-22 01:24 CEST — Shape field names and host boundary panic

**What I did**

Resumed #653 after the owner's decision and rebased the existing dagon branch
on origin/master (already current at 63cfc1a17). Added dated amendments to
boundary.md §4 and schema.md §6. Removed shape-specific field pinning and
added a field-name IR leaf resolved through the existing field table by the
printer. Shape entries retain host keys and omit redundant output names.
The shared copy loop and T = 29 remain unchanged. Opened #655 for the new
threshold measurement; made no size or speed measurements.

Added matching release golden and run fixtures with exactly 29 shape runs,
including parse, Json decode, alias keys, field reads and record update.
The initial fixture passed. Extending it with a concrete Js host reader to
check independent boundary pins exposed the fact-3 traversal-order panic
reported in #658 (possibly related to #657). Proved the same panic on master
by setting aside all source changes, running the focused corpus test, then
restoring the patch. Stopped under CLAUDE.md rule 10. Code, fixtures and docs
are uncommitted in the existing dagon worktree. Full gates, final golden
review, run hashes and the PR remain outstanding.

**What I learned**

The shape engine already supports separate input and output names, including
optional and Maybe flags. A printer-resolved field-name leaf can share the
existing deterministic field assignment without changing development output.
The concrete host-reader regression cannot yet pass even on master: release
specialisation panics with 'another fixpoint: local 4'. It needs a compiler
fix rather than a change to the shape or host-boundary contract.
