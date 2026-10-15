## 2026-10-15 13:41 CEST — Bike Wars promotion awaits page budget

**What I did**

Prepared the move of Bike Wars from pending into the paired browser-direct
corpus on `browser-direct-bike-wars`. Copied its existing tea Chrome transcript
without changing any golden. The unchanged application passes development and
release on both platforms against the existing transcript, plus the separate
value fuzz. The helper-document lowering already handles it; no compiler fix,
visit-invariant change or application edit was needed. Updated the pending
inventory to describe the remaining budget obstacle.

Used Zorg throughout. `zorg build gates` refuses this aarch64 macOS host as
designed. Its constituent checks finished with 1,321 passed, 15 skipped and
only the two known macOS case-folding failures. The app sources and the entire
original tea BikeWars fixture directory have no diff.

Copied the prepared tree to an isolated `/tmp/beni-bike-wars-20261015` on
shoggoth (x86-64 Linux, Intel N100, perf_event_paranoid=2), using the pinned
Zorg 0.17.1+zorg.1 and Node v24.19.0. Ran
`zorg build test-blackbox-corpus -Dcorpus=browser/direct/BikeWars -Dtest-budget=1`
to force hardware instruction counts. With no recorded direct hashes, Node
executed the comparisons. The paired page measured **7,784M instructions**;
the separate value fuzz measured **4,225M**, against the default **4,300M**.
The local measurement log is `/tmp/beni-bike-wars-linux-counts.log`.

Stopped at the over-budget page as explicitly requested. No budget was added,
no commit or PR was made, and no review was requested. The prepared promotion
remains uncommitted for an owner budget decision; full Linux gates and hash
recording remain owed before a PR. The unrelated untracked review note was
left alone.

**What I learned**

Bike Wars no longer exposes a missing lowering shape. Its remaining promotion
obstacle is the cost of the four-build paired page, rather than ownership,
markup lowering, runtime behaviour or the separate value-fuzz budget. A
functional pass on macOS does not establish that this page fits the Linux
instruction limit.
