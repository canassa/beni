## 2026-10-30 02:27 CET — Browser worker design

### What I did

Delivered the design-only worker contract and primary-source research in PR
#1304, tracking #1290. Added dated amendments to the language, frontend,
checker, boundary, backend, ownership, schema, effects and WebGPU contracts,
plus research 48 parity rows. Pinned WebRef/BCD inventory and source hashes;
opened implementation slices #1293–#1300, owner decisions #1301/#1302 and the
MIDIAccess specification gap #1303. Coordinated on #1287/#1277/#1278.

Ran the full unfiltered `nix develop --command zig build gates` on Dagon:
exit 0. Checked diff whitespace, relative documentation links and primary
source section anchors (the ReSpec-generated heading is identified). No
runtime/compiler implementation or browser/performance probe was made.
An independent adversarial reviewer reviewed the PR and confirmed that all
seven findings and both follow-up clarifications are addressed, with no
remaining blocking findings. The review response is recorded on the PR.

All project work after the owner's machine correction ran on Dagon through
SSH, in the task-owned workers-design worktree. The PR retains its remote
branch for review; after this entry is pushed, the owned worktree, local
branch and scratch files will be removed. No unrelated worktree/process/file
is part of cleanup. The PR remains open with owner decisions explicit.

### What I learned

Worker error forwarding deliberately clears ErrorEvent.error; classifying
by missing payload hides initializer defects. OffscreenCanvas native transfer
throws InvalidStateError, and failed transfer can consume earlier resources.
A readiness deadline is insufficient if cleanup waits forever afterward.
IDL scanning misses WebAssembly.Module's prose serialization contract, and
MIDIAccess's transfer attribute alone does not supply an implementation
contract. Current Http/WebSocket URL helpers read document.baseURI, so worker
exposure needs operation-level auditing rather than blanket module labels.
