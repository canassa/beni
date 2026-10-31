## 2026-10-30 03:35 CET — Worker design revision

**What I did**

Revised PR #1304 on its existing design/browser-workers branch, on Dagon only.
Replaced foreign-only realm maps with checked declaration-local bounds and
native-table/value-flow obligations, source-discovered generic entry contracts,
and per-entry EntryHost proofs. Added complete proposed seven-module APIs,
worker-local init/state/events, Elm-shaped commands and complete page/worker
examples. Relocated dated amendments beside their sections without renumbering.

Recorded all 2,856 candidate access sites and a source-reviewed semantic census
(556 native, 2,130 portable receivers, 170 caller-dependent sites). Compiled a
beni-only layout probe with the owned compiler in development and release,
recorded emitted layout hashes/bytes, and opened owner wire-layout decision
#1305 plus missing suspending browser-command prerequisite #1306. Updated
#1293–#1302 and coordination comments on #1287/#1277/#1278.

A new adversarial reviewer raised eleven findings plus one small correction;
all were fixed and independently rechecked, with no blockers remaining. Fixes
cover schema/endpoint-bound preparations, explicit transferable event targets,
serial-state cancellation, shared-client isolation, root commands, initializer
election, terminal commit after cleanup and honest raw-peer lifecycle semantics.
The expanded census was also rechecked against source and its totals.

Full `nix develop --command zig build gates` returned exit 0 on Dagon. Production
sources are unchanged; later edits are documents/CSV/JSON only. Diff whitespace
checks pass. Relative links added by this revision resolve; existing upstream
reference-submodule links and code-example pseudo-links were not altered.
The previous pushed head's CI passed; final-head CI is awaited after this diary
commit, and its result will be recorded on the PR. The owned worktree, local
branch and scratch/probe files will be removed after the final head is green.
No implementation or browser/performance parity claim was made.

**What I learned**

Current List views contain callable $plain and cannot be cloned directly;
current Dict is still a plain tree, distinct from the specified ordered Map
index. A nominal wrapper or native Map does not itself justify a codec.
Receiver provenance matters even for familiar names such as URL.parse,
Headers.get and native collection iteration. Cancellation of a consuming
state lease cannot safely restore the old state; shared borrowed-state handlers
preserve other clients. Raw peer cleanup must not pretend to be managed remote
finalizer confirmation, and a terminal result reservation is not yet a send.
