## 2026-10-29 21:02 CET — Unit tests fit CI's 1 s budget with margin (#1209)

**What I did**

- GitHub's runners are about twice as slow as dagon, so three tests went just over 1 000 ms of
  CPU there. I measured each unit test alone on dagon and shrank or split every one above
  0.3 s (alone, before → after):
  - the interpretations limit: 461 ms → split in two, 81 / 156 ms (200 nodes, allowance 1 000);
  - the codec lane's prefixes in Refine: 445 → 111 ms (a ring of 16);
  - a type's width: 439 → 126 ms (128 × 128);
  - a taken chain: 426 → 217 ms (500 deep);
  - #1141's snapshot codec: 415 → 224 ms (64 / 128 / 256 levels);
  - every truncation: in 20 parts of equal length, at most 193 ms;
  - every mutation: in 12 parts, at most 271 ms;
  - a declaration's growth: 383 → 219 ms (100 nodes);
  - v1's summary limits: 367 → 26 ms (one `apart` atom of weight cap + 1);
  - #1130's call: 350 → 177 ms, and #1138's shapes: 310 → 215 ms (depth and stack halved together);
  - the codec lane's longest prefixes: 347 → 262 ms (32 steps);
  - a list's n log n: 334 → 191 ms (to 512);
  - nested places: 316 → 152 ms (to 1 000);
  - #1149's every-kind sweep: in thirds, about 181 ms each.
- The CI budget stays at 1 000 ms.

**What I learned**

- The old √ cut of the truncation sweep assumed a truncation's cost grows with its length. It
  grows more slowly than that, so the first part, which holds 41 % of the lengths, was the
  heaviest. Equal lengths with more parts balance them.
- "Alone" on a busy dagon still varies by about 15 %. Measure with the budget set to 1 ms, so the
  runner prints every test's CPU time.
