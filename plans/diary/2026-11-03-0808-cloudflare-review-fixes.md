# 2026-11-03 08:08 CET

## What I did

Fixed ordinary Durable Object builds by passing checked Wire scan roots into packed reachability edges. A build-only Reply-free self-post regression and a sweep of every worker fixture now exercise development and release builds without test hooks. The runtime corpus still uses its hooks to drive timers and alarms.

Rebased onto HostFree's shared privacy policy and the merged reply compiler, keeping its Cell/Opt traversal fixes. Removed the duplicate privacy checks and Graph fields. The Cloudflare fixture refuses all eight bridge method names plus the socket chain with `private_method`; the earlier compiler fails that fixture. API references omit private bridges.

Replaced the pending-ask Dict with the approved private typed native string-key Map, preserving element types, callback values and conservative ownership. Tests cover undefined presence, missing keys, insertion order, snapshot isolation, element identity and malformed generic signatures. Removed unreachable plan-interpreter branches from generic-only reply scans and emitted thin native reads directly through the existing recipe path.

All 32 Miniflare runs and the six native fixture runs pass in development and release. Safe compilation, native generation, API generation, reply/cache/fence cases, shape checks and ABI guards pass. Dropped the unrelated bulk run-hash refresh; refreshed only the Cloudflare families.

## What I learned

Test hooks rebuilt platform edges and hid a missing input in the packed-edge builder. Runtime fixtures therefore need a build-only pass through ordinary production options too.

The untyped base used JavaScript Map; introducing Dict retained a tree implementation that typed storage did not require. Restoring a typed Map saved 669–794 brotli bytes in the measured samples. Remaining growth is in typed state/callback initialization and native boundary adapters; the final size table and per-declaration ledger are attached to the PR's evidence, with the residual regression stated explicitly.
