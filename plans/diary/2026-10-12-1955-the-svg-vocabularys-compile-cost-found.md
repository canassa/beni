## 2026-10-12 19:55 CEST — the SVG vocabulary's compile cost, found

**What I did.** The manager blocked PR #71 on the unexplained +6 ms per markup check in
`Types.build`. Timed its parts with thread CPU clocks: `TypeFacts.settle` went 1.6 → 7.8 ms. Cause:
`Types.build` took every non-value declaration for a type, so each `pub element`/`attribute`/`event`
became a `foreign` type entry, and settling each scanned its module's declarations for a `pub compare`
— quadratic in the vocabulary. Vocabulary declarations now name no type; `Types.build` is 1.4 ms, below
master's 2.5 (master had 145 phantom entries). §9.9 (h) restated.

**What I learned.** The residue is linear: `html`'s load, resolve and digest, ~4 ms CPU spread over
workers; wall time within noise (minimum of 30). The machine ran at load 60 on 32 cores, so medians
were useless; minimums over interleaved runs and thread-CPU clocks were the only stable instruments.
`zig build bench` 100k: check 1.11 M lines/s — its corpus has no markup, so no vocabulary is read.
