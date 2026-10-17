# 2026-10-16 — Distinguish virtual addresses from RAM and share the size work

Counter/toggle TEA at N6,176 failed with a 24 GiB address-space allowance but
succeeded with 64 GiB of address space inside a 26,000 MiB RAM cgroup, with
swapping disabled. Peak process RSS was 8,074,084 KiB; the normalized rendering
response is 524,741 brotli bytes. Nested, tabs and modal TEA also cross after
larger-address-space retries. The recursive-thread retry reaches 421,104 bytes
at N3,888 and continues at N4,768. A list/direct RAM-bounded sensitivity curve is
pending. Failed attempts remain recorded; the report names both kinds of limit.

The largest observed prototype worker used 9,973.4 MiB RSS. Its scheduling
reservation now caps at 12,500 MiB instead of 14,500, letting two fit the unchanged
26,000 MiB / six-slot pool. A controlled lease check verified the adjustment.
Compiler builds remain isolated; generated sources, minification and compression
are unchanged. This is a scheduling estimate, not an enforced worker RAM cap.

A second host now prices vanilla: one bounded worker on the 16 GiB Mac, using
Node 24.19.0 and Brotli 1.2.0. A N102,416 list control matched the Linux source,
normalized output and rendering hashes and every account field exactly, including
525,088 rendering brotli bytes. The local worker hashes exact generated TEA source
in memory and consumes its spec; it does not invoke the beni compiler. Its host,
protocol and observations are separately retained. The HTML merges only agreeing
outputs and publishes complete report files atomically.

The checkpoint contains 2,465 sizes: 1,043 stress measurements, 35 actual target
crossings and eleven currently capped direct curves. All 1,043 stress artifacts
were audited across the four queues. Chrome checked the RAM-limit and local-host
provenance display, absence of JavaScript errors, and no page overflow at 390 px.
Research 106 remains below 2,000 words. The size sweep continues.

No repository gates or suites, and no new application timings ran. GNU time's
compiler resource log is retained only to establish peak resident memory.
