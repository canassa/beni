## 2026-11-04 17:58 CET — Fit Opt's capped walks in half of the small stack

**What I did**

- Issue #1843. `Opt.mayWriteIn`, `Opt.readsTo` and `Opt.height` now call `small_stack.mark()` at their depth caps.
- Added three margin tests in `src/js/Opt.zig`. Each test runs `Opt.run` on `small_stack` twice: with 8 links the fold occurs and no mark is seen, with 512 links the walk stops at its cap. The test fails when `small_stack.deepest()` is more than half of `small_stack.size`.
- Red before the fix: `mayWriteIn` used 554 848 B (52.9 %), and `height` overflowed the stack (SEGV). `readsTo` passed at 31.3 %.
- Fix: `mayWriteIn` and `height` call `JsIr.pushOperands` through `Opt.operands`, a `noinline` function. Their Debug frames went from 4 128 B and 4 224 B to 384 B. The tests now measure 6.9 %, 31.3 % and 11.5 %.
- No cap changed, so development and `--release` output do not change. `nesting.spill` stays at 256.

**What I learned**

- A recursive walk that calls an `inline` helper with a large switch gets the whole switch in its frame. In the self-hosted Debug build each arm's temporaries take their own stack slots. `pushOperands` alone was about 3.7 KB of each frame.
- `-Dllvm` does not change the unit test binary. To measure LLVM frames for one file's tests, build that file alone with `zig test -fllvm`. The root file must be under `src/`, because `Opt.zig` imports `../small_stack.zig`.
- LLVM's Debug frames for these walks are about the same size as the self-hosted ones (3 600 B and 3 632 B before the fix). The self-hosted Debug build is not the only tight one.
