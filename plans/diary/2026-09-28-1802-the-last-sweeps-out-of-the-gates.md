## 2026-09-28 18:02 CEST — the last sweeps out of the gates

**What I did**
- `ordering_test`: ran all 73 permutation programs, five orders each, on compilers built
  from before each fix. Most failed in their written order (the corpus walker's own case),
  a few only in the order a twin fixture already holds, some never. Seven failed only
  reversed; each is now one test writing that order, red on the pre-fix compiler.
- `frontend_test`: the identity oracle's tokens/ast/fmt runs never reached the round trip
  (it runs where lowering ends) and its `check` runs loaded the cache instead of
  round-tripping. Replaced by one source filling every artifact section and one type error
  pinning token and line starts, each red with its section corrupted.
- `cutoff_test`: one edit per input of a module's key — own terms, an import's hash, an
  import's digest — instead of nineteen edit classes in four quarters.
- `abuse_test`: 39 → 19 tests; duplicates of `parse/bad`, `check/depth` and
  `run/DerivedDeep*` deleted after breaking each guard showed both went red together. The
  4 096/4 097-parameter recursive types recursed in the last position, looped, and never
  reached the depth limit; they now recurse first and fail when the guard is broken.
- Gates test-process CPU on the self-hosted beni: 607 → 410 CPU-s (loads 12.7 and 8.6 at
  the start).

**What I learned**
- Replaying a regression sweep on the compiler from before each fix is cheap (Debug builds
  of old commits, a probe test) and says exactly which order each program needs.
- A sweep can pass for its whole life without reaching the code it names: check that
  breaking the guard turns it red before trusting it.
