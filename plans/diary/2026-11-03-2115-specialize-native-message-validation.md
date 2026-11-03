## 2026-11-03 21:15 CET — Specialize native message validation

**What I did**

Shared the existing graph-validation fragments between typed conversion and native message data. The native path emits plain validation and returns the same value, without list normalization or copy machinery. Kept the typed converter byte-identical. Added a focused release emit golden and 652 differential graph/identity checks per runtime build, including zero getter calls. Measured the Ready page and worker with one-shot ReleaseFast compilers on the typed-storage commit before and after the change.

**What I learned**

The native adapter's undefined list token left most of its old projection code unreachable. Specializing generation removes that code without weakening any graph check or erasing typed storage. Optional-hook and shared-no-op source trials regressed compressed size; the remaining typed worker work is recorded in the lane's declaration ledger.
