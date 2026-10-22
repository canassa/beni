## 2026-10-22 21:44 CEST — fact 3's input, counted, and const copies as aliases

**What I did**

- Counted fact 3's input on N = 64 after #791. I added a temporary census by role and by module, under `--points-to-largest`. 93% of the 117 336 site memberships sit in locals, and 98% in `Main`. 288 `const` copies of one local in the TEA runtime, which `structureFirst` now writes into `main`, each held all 349 sites.
- Built #796. `localVar` gives such a copy its source's var when the name has no other declaration, its read is not narrowed, and its filter is wild or the source's. Joins go 67 007 → 22 596, and instructions fall 2.8% on N = 64 and nowd. The output is identical.

**What I learned**

- Joins were not the cost. Joins fell by two thirds while instructions fell 2.8%. Fact 3's time is mostly in evaluating constraints (`replayWalk`, `combineNow`) and in extraction, not in set work. The next cut has to lower the number of constraints, not the size of sets: #689's reachability, or fewer nodes for the solve to see.
- In Zig 0.17, `[_]T{0} ** n` and `@typeInfo(E).@"enum".fields` no longer compile. Use `@splat` and `std.enums.values`. `std.posix.getenv` is gone too, so a debug switch is a source edit.
