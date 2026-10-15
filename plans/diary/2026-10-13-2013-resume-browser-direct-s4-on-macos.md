## 2026-10-13 20:13 CEST — Resume browser-direct S4 on macOS

**What I did.** Fetched the pushed S4 branch into a separate worktree and rebased its 12 commits onto current master. Kept master's ownership fixture check and S4's release-refusal check in the corpus harness; kept master's conflicting generated hashes pending a full re-record. Read the S4 amendments and added the specified `Blocks` page as a direct-platform fixture, pending validation.

**What I learned.** This host has 12 logical CPUs and no Linux `taskset`, so it cannot run heavy jobs pinned to cores 8–23 as the session requires. The required zorg builds, hashes, measurements and gates await access to the Linux runner or a changed CPU constraint. The direct `Blocks` fixture was missing despite its place in S4's explicit corpus list.
