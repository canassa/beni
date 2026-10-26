## 2026-10-30 19:46 CET — Merge PR queue and record rebase blockers

### What I did

- Inspected the 19 open PRs authored by the authenticated user and their unresolved review threads (none).
- Requested rebase auto-merge without bypassing checks. Seven PRs merged: #1116 into #1127, #1127 into #1110, #1134 into #918, and #1255, #1155, #925 and #884 into master.
- Enabled rebase auto-merge on all 12 remaining PRs.
- Used two detached temporary worktrees, leaving the user's root checkout unchanged. Probed conflicting branches and attempted full rebases of #912 and #1110; neither was pushed because validation failed.
- Regenerated release emission goldens in those worktrees. Kept the local attempts and their logs for investigation rather than weakening tests or publishing an unverified branch.
- Opened #1355 for the ownership-result changes on #912 and commented on #912, #1110 and #904 with the blockers.

### What I learned

- #912's move of Node and Ssr wrappers changes six ownership fixtures, including `valuesOf` and `firstOf` summaries. These need contract review, not automatic blessing.
- #1110 now contains the merged forwarding-lambda and Hosted-key PRs. Its local rebase could resolve generated conflicts, but hash recording failed on WebSocketFaults and two macOS case-folding tests (related: #90).
- #904's existing CI fails HttpServerBadClients in the release corpus. HTTP/WebSocket failures also appeared during local validation.
- Most remaining conflicts are generated run hashes, but the runtime-port branches also overlap in plan tables and #1246 in Io.js. Auto-merge cannot resolve these conflicts by itself.
- On this arm64 host, zorg is available through `nix develop .#ownership`; Zig must not be used.
