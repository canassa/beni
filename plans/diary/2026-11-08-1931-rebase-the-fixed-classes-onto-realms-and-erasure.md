## 2026-11-08 19:31 CET — rebase the fixed classes onto realms and erasure

**What I did** (#1662, PR #2128)

- The owner turned on auto-merge for PR #2128, so option A of `toplevel-ref-twin-q1` stays as built. I rebased the branch onto master `e0e59831b0`.
- `src/check/Effects.zig` had a conflict. Master added realm facts and erased types to `summarise`, `dependencies`, `reachesDemand` and `schemeNodes`, and it moved `foreignSummary` to `EffectsForeign.zig`. This branch moved the four summary functions to `EffectsSummary.zig`. I put master's changes into `EffectsSummary.zig`. `Effects.dependencies` is now an alias, because `Realms.dependencies` calls it.
- `fixedReached` skips realm edges, as `reachesDemand` does. A realm edge carries no rung, so it does not make a use's copy flow into a fixed class.
- Corrected the line counts in the dated note of `checker-v2.md` §19.1.

**What I learned**

- When a branch moves functions to a new file and master changes those functions, git shows the conflict only in the old file. Compare each moved function with master's version of it, function by function, before you continue the rebase.
