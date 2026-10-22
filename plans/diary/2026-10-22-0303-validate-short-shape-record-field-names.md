## 2026-10-22 03:03 CEST — Validate short shape record field names

**What I did**

Finished #653 after #658's master fix and dagon's filesystem cleanup. The
29-site ShapeRecordNames fixture passes all four compiled/library passes.
With the compiler fix set aside, its release golden fails with GoldenMismatch;
the baseline runtime still matches the same expected output. The new golden
keeps host keys, writes short names in slot 3, and leaves an independently
pinned field's entry compact. Updated ShapeThresholdAt's golden and reviewed
its changes: output-key slots and consistent property spellings only.
ShapeThresholdBelow and all existing run hashes remain unchanged.

Recorded all 2,491 run hashes with zero failures. Compared the new fixture's
before/after hashes: development and both library passes are byte-identical;
only compiled release changes. Fixed a duplicate field_name registration in
the IR verifier exposed by unit-test compilation. The unfiltered default
self-hosted zig build gates then passed on dagon. T stays 29 and #655 tracks
its re-measurement; no size or speed measurements were made.

Prepared PR #659 for owner review of the dated contract amendment. Per the
owner's cleanup instruction, retain the pushed branch and copy validation
logs to ~/worktree-evidence/beni-fix-shape-field-names/ before removing this
worktree, its local branch, and the temporary task files. Cleanup completion
is to be recorded on #653.

**What I learned**

The shared shape engine needs no change: its existing fourth entry slot
already separates host input keys from record output names. A field-name IR
leaf lets the printer use exactly the field table ordinary accesses use.
Concrete host-boundary pins survive removal of shape-specific pinning.
