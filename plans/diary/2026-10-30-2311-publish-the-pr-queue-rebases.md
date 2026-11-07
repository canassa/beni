## 2026-10-30 23:11 CET — Publish the PR queue rebases

### What I did

- Published the previously local rebases and rebased the other conflicting PR branches with explicit force-with-lease protection. Left the root checkout unchanged and kept rebase auto-merge enabled.
- Resolved documentation conflicts by preserving both changes, including the pointer extractor fix and delegated-event contract. Regenerated conflicting release emission goldens from the rebased compiler.
- Adapted the new prerender harness to #904's digest cache and removed obsolete records from the new base, matching that PR's cache-only contract.
- Preserved the directory-reading API added to master during #1246's lifetime. Its existing JavaScript implementation stays unchanged; the PR's original finish and file-reading implementations move to beni. The directory and file corpus tests both pass, as does release emission and formatting.
- Kept ownership verdict expectations unchanged. Full local gates still report ownership fixtures, WebSocketFaults and macOS case-folding failures; these do not justify weakening the expectations or disabling checks. CI gates the requested auto-merges.

### What I learned

- Completing a local rebase without publishing it does not unblock auto-merge. The user explicitly requested publication after the first attempt stopped at validation failures.
- The base can advance while this queue runs. PRs that were conflict-free after one push can need a second rebase as another PR merges.
- Resolving a modify/delete conflict in generated records by keeping the base can resurrect files a cache-migration PR deliberately removes. Verify the final tracked file set against the PR's contract.
