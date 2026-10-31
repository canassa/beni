## 2026-10-31 10:16 CET — own2 5f review: holder runs and cycle ids

**What I did.** I answered the review of #1456.

- **Cost.** `holderOn` read a holder's uses from the start of each range, so every group walked every earlier use: `wall` with `len r` after each write was ×3.5 a doubling. It now reads runs of one path and group (Liveness keeps them contiguous, by point) by their last point. A holder whose value is no leaf is read by its end. 64 → 256 → 1 024 writes: 10 422 / 44 044 / 185 468 records, linear. A counted build test (64 / 256) fails on the previous head (12 438 → 76 684).
- **#1452's verdict.** `CycleComponentApart` pins `holdL1`'s `w1 l`. Master's v2 refused it `alias` because of the id collision; it is accepted now. v1's `level` refusal is a known entry. The caller that shares one list at both positions stays refused.
- **Decoded tables.** `Place.Table.decode` left every component id at 0, so `sameCycle` held for every pair. That is not only imprecise: `Demands.conflict` drops a conflict where `Cell.below` holds, and `below` reads `sameCycle`. Only Place's unit tests decode today. Decode now settles the cycles, and its unit test checks that.

**What I learned.** A per-group scan of anything frame-wide is the quadratic to look for in this design. The groups are as many as the writes, so every read a group does must be bounded by what is on its leaf's line.
