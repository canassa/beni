# 2026-11-03 06:11 CET

## What I did

Kept named access and static dispatch on the same runtime privacy policy, including root platform authoring. Nested comparisons now report the existing runtime privacy explanation instead of suggesting that an already public export needs `pub`. Removed fences for modules absent from workers; those belong to the Cloudflare migration. Restored the host-free rollout comment.

Added black-box cases for nested list, tuple and record refusals and for `beni check` run inside a platform package. Both regressions fail with the pre-review compiler and pass with the changes. Local fixtures exercise existing core, task and worker fences; a small policy table covers access classes without inventing production modules.

## What I learned

A platform checked as the root project retains app package identities in the graph, so both resolver and checker need the session's effective platform authority. Nested instance failures use a different diagnostic path from direct dispatch and must consult the same explanation policy.
