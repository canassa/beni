## 2026-10-22 04:03 CEST — Distinguish storage writes from value writes

**What I did**

Specified #670's dated write-extent amendment and implemented storage/deep
extents through ownership rows, normalization, captured writes, callback
write-back and summary blocks (version 20). Precise List slot writers are
storage-only. The keep and supply checks use directional storage overlap;
unclassified and deep writes retain symmetric overlap. Posted the oracle
requirements on #316; left Jayson's proof files unchanged.

Added the borrowed identity/permutation reduction and refused twins for kept
storage and written values, including a value write through a callback. The
new fixture fails against the original checker at the expected borrowed-value
keep edge. Its runtime twin prints the expected result in development and
release; recorded both run hashes. Compared every existing ownership golden:
after stripping the new extent annotations, every report is byte-identical.

All edits and commands ran in the dagon worktree from current origin/master.
No local Zig, LLVM, measurements, caps, weakened checks or budget changes.
The unfiltered self-hosted gate passed on dagon, including the final
unknown-suffix overlap and extent-join tests. No existing verdict changed.

**What I learned**

The recursive send bit already means giving up every cell below a path; it
cannot stand for this distinction. A storage write still conflicts with a
loan of the storage itself. Translating another callback's write back to the
callee's parameter is necessary before comparing it with a kept value loan.
The ordered Dict/Set rows remain in the evidence archive until the runtime
work resumes after this fix lands.
