## 2026-11-01 16:58 CET — The list sanitiser follows v2's verdicts

**What I did.** Built #1547. `--ownership=v2 --sanitize-lists` wrapped nothing,
because the sanitiser read v1's clean bit only. v2 now publishes the list half of
its lowering channel (`ownership-v2.md` §3.7, `src/own2/Hoists.zig`): per
application module R-1.12's clean bit and each accepted `writer`,
`construction` and `append` demand by its instruction. `Ownership.run`
produces it, `Check.channels` keeps it, `Emit` hands it to `Lower` in a build
that enforces, and the sanitiser wraps exactly the listed writes. v1's path is
unchanged. The harness has a v2 twin of the list pass (`.sanitize-lists-v2`,
`BENI_IN_PLACE=lists-v2`, `zig build test-lists-in-place-v2`) whose site check
reads v2's dump. `ListSanitiserHiddenHolderV2` traps, `ListSanitiserV2Writes`
runs clean, and `bench/ownership-v2-sanitiser.mjs` is a generated sweep.

**What I learned.** The first whole-corpus run found one wiring defect: v2
names a spread chain's demand at its root, and when items lead the first
spread the root is the `cons`, not the `List.append` the lowering wraps.
`Lower` now maps a chain's first spread item to its root. After that, all 652
`run/` cases and the browser pages ran clean, and 6,000 generated programs
(1,158 accepted, 1,268 writes wrapped) had no trap. The oracle sees only what
v2 judges: 34 accepted list writes in the 491 single-file `run/` programs
against v1's 164, because most `main`s and many helpers are not built by v2
yet. The sanitiser follows the writes and not the clean bit, or it would see
almost nothing until S9; S8b's stores read the clean bit.
