## 2026-11-04 02:39 CET — Private renderer array operations

**What I did**

Added reviewed private native array truncation and a checked element read,
generated Array's existing sequence metadata, and covered direct and shared
first-class emission, runtime values, invalid-index defects, application
privacy and the storage ownership demand. Removed the initial Js.Array
prototype after the manager selected the runtime's native array module.

**What I learned**

The native array's missing sequence metadata made ownership v2 ignore its
storage write. With that metadata generated, v1 and v2 both refuse a later
alias read after truncation. The before/after v2 audit of 2,528 roots found
no new demand or refusal outside the ArrayTruncate fixtures, no missing
demand, and no newly failing root. Core retains 57 demands. The audit uses
the existing root inventory plus positive checking and emission fixtures;
22 roots fail for pre-existing checking or platform setup reasons on both
sides. Raw per-root reports are in worktree-evidence/wd-dom-rows/sequence-audit.
