Owner-approved reset of the browser workers delivery (2026-11-01). Supersedes the implementation approach on #1304; the ratified contract (`workers.md`, `workers-api.md`, `workers-callback-contracts.md`, decisions #1315 #1305 #1319 #1301 #1302) is unchanged.

Why: after 3 days and 45 commits on #1304, one native binding works and no worker launches; ~12k lines of speculative proof/evidence machinery run on every ordinary build (+13% cold, +25–30% warm check). Review: `plans/pr-1304-review.md`.

## Plan
- **Phase 0 — triage.** Inventory the 19 worker worktrees on dagon for unpushed work, save receipts, delete them. Classify every file/commit of #1304 as keep / drop / separate PR.
- **Phase 1 — fresh base.** New branch from `origin/master` with only the keep set (entryKinds metadata and runtime contract #1293, WebIDL generator/catalogue, alias/suspension fix). Proof machinery, inspectors, tamper flags, sweep fixtures and the unratified specs that serve them are dropped. `Js.Buffer` deferred until the Task lane needs it. Master fixes (#1509 #1337 #1338 #1378 #1539 #1544 #1551) land as separate small PRs. #1304 closed as superseded.
- **Phase 2 — two lanes.** A: multi-entry emission and bootstrap (#1294) plus a dedicated worker launching and exchanging a message in headless Chrome on a test platform only (no public API). B: typed Task continuation storage — short spec for the owner comparing designs, measured, then built.
- **Phase 3** realm check C (#1295). **Phase 4** Wire with shared names (#1296) and the dedicated runtime (#1297) → first public launch. **Phase 5** ports/shared/transfers/pools/streams (#1298–#1300).

Managed by Claude Code (manager/reviewer); implementation by Codex agents on dagon.
