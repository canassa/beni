## 2026-11-02 20:18 CET — Ratchet fiber costs and repair benchmark entry

### What I did

Replaced the benchmark's JavaScript work thunks with 18 Beni run entries. The
Node and Chrome runners share the repaired helper. The old bridge fails the
small real-workload scenario with Done(sentinel) instead of 3; the new bridge
forwards the resumed answer.

Added public-API Parked, ParkedDeferred, Completed, SpawnJoin, FastPath and Yield
measurement programs. Fresh pinned Node processes run jitless/predictable with
forced GC and a fixed 512 MiB semi-space. Three initial rounds produced identical
raw deltas and each round took 4.2–4.5 seconds. Allocation intervals must have no
GC. Exact integer two-count deltas are ratcheted, and run hashes cover programs,
measurement code, budgets, architecture and Node. No kernel inspection API.

Added S0–S5 release application goldens, runtime answer checks and brotli caps.
bench/size.mjs reports the new rows and enforces the same caps; --fibers-only is
the short measurement path. Brought QueueGrowth over as a public-API run fixture.

The current controlled fast-path allocation is ~208 bytes/point, with zero as
the target. A zero-cap trial fails. A one-byte reduction of S2's cap also fails.
All cost checks are fast and deterministic enough to stay in gates. Time remains
outside gates. Core and platform worker storage were not changed.

### What I learned

JIT tiering can obscure allocation comparisons. Interpreter-only, predictable
processes and two-count slopes gave repeatable integer deltas in both the
measurement tree and the black-box harness's random temporary paths. The result
is a reproducible regression ceiling, not a normal-JIT performance claim.
