## 2026-11-02 19:33 CET — Bound the busy Task run queue

### What I did

Compacted master's consumed run-queue prefix at the existing macrotask escape.
The prefix must occupy at least 65,536 slots and be at least as large as the
pending suffix. Each compaction copies at most the work consumed since the
previous one; enqueue and the 64-resumption scheduling budget stay unchanged.

Added QueueGrowth with two yielding fibers and a test-platform GC/heap probe.
After warm-up it asserts a 2 MiB retained-heap ceiling while still busy and
after idle. With the fix stashed, dev and release retain about 7.8 MB and fail.
The fixed fixture passes. The probe reads process memory, not runtime internals.

An interleaved 3-warm/9-measured comparison at 200,000 yields per run measured
126.2 ns/yield before and 103.6 after on dagon. A smaller initial compaction
threshold was discarded after a slower first timing sample. Refreshed release
shapes and all runtime hashes with the default Node heap.

### What I learned

Clearing consumed references is insufficient when an always-busy queue keeps its
array length. A cold-path prefix compaction bounds retained backing storage
without allocating a job record per enqueue or changing FIFO order.

The first unfiltered gate run found the ownership inventory's stale Task source
ranges. Refreshed them and verified the declaration/reason set is unchanged.
