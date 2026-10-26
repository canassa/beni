## 2026-10-26 03:12 CET — Assign the positions kind to S2

**What I did**

- §8 of `docs/design/ownership-v2.md` now gives each slice its own part of the `positions` work:
  - S2 owns the `positions` node kind and its κ rule (multiset `apart`), now built in #1036.
  - S3a's `Transfer` builds a literal's and a spread's `[*]` with `collect`.
  - S3b's `Shape.map` preserves the kind.

**What I learned**

- When a hole is in a lower slice's code, the plan row moves with the fix, so two slices never claim one piece.
