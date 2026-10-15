## 2026-09-24 00:17 CEST — row 72: fast path past the applicability probe

**What I did**

- The review measured row 72's cost on programs with no custom method at all.
  `s_tup6000` (`( a, [ b ] ) < ( b, [ a ] )` ×6000) was 1.63x master, and
  mixed `gen` 1.14x. A `sample` over a 400k-function version showed two
  sources, and neither was the cycle check:
  - `List.eq`/`List.compare` are public methods, so every `List` part went
    through `importedMethodAcceptsApplication`'s probe and commit.
  - `derivable`'s probe rebuilt the whole target that `finishDerived`
    builds right after.
- Added `plainMethodMask`: a scheme `T a1 … an, T a1 … an -> Bool|Order`
  over distinct variables whose only constraints are the method's own name
  at the standard type. It is cached per module for imported values
  (`Env.plain_methods`) and skips the copy, the probe and the commit. The
  receiver must match (`UnrelatedEqDoesNotGrantCapability` caught the first
  version). `flagUnansweredParts` stands in for the probe's completeness
  test. `targetNeedsProbe` lets `derivable` skip its probe when the shape
  reaches no non-plain method, no untyped own method, and no nominal type
  that cannot derive.
- ReleaseFast, `--self-profile` check-phase medians of 7, master /
  round-4 tree / now:
  - s_tup6000: 20.1 / 37.5 / 21.7 ms (+8% over master)
  - s_int6000: 15.3 / — / 15.7 ms
  - gen: 73.8 / 94.4 / 76.0 ms (+3%)
  - `zig build bench -- --generate=100000` check phase: master 52.6 ms,
    now 55.2 ms. The `resolve` phase is untouched by row 72 (no file under
    `src/resolve` changed) and read 6.20 ms on master against 4.68 ms now;
    the reported 0.00 → 6.40 was not a real regression.
- No golden changed. Gates: 468/468 unit, 289/289 black-box (33/33 steps),
  fmt-check green. Nothing committed.

**What I learned**

- A speculative check pays for itself only where it can decide something.
  Say when that is (a scheme that can narrow or refuse) and test for it
  before speculating.
- `zig build bench`'s `resolve` line is graph-plus-resolution only. A
  capability or checker change cannot move it, so look for noise before
  looking for code.
