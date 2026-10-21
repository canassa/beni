## 2026-10-22 01:57 CEST — S1's gap checked, the plan, and the first two fixes measured

**What I did**

- Checked Part 2 of `plans/s1-gap-and-latency-report-2026-10-22.md` on `master`: the slope and the
  quoted output hold; beni's guarantees cost tea-inline's shape about 8 B per widget, so about 100 B
  of the gap is output shape.
- Read the `browser-inline` lowering and the code it calls, and ranked seven fixes by how easy they
  are and what an edit of the real output says they save. Wrote the prompts for #1, #4 and #6, for
  #286 and for #658.
- Measured the merged fixes on the real compiler, 12 builds each: #654 −3.9 B per widget, #656
  +0.2. Draft #659 measured +3.3.
- Added Part 3 to the report as the plan's tracking document (the owner: on `master`, no PR).

**What I learned**

- Editing the output into a fix's shape overestimated both small fixes. Bytes must come from the
  compiler before the next fix is ranked.
- Short field names can cost bytes under brotli: #659's two-letter names and slot-3 entries made
  the output larger, although 6 % smaller raw.
