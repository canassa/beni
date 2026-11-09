## 2026-11-09 09:50 CET — negate keeps the sign of zero

**What I did**

- Issue #2247. `negate` and the prefix `-` were `0 - n`. For `n = +0` that is `+0`, so `-0.0`,
  `negate 0.0` and `-x` of a zero were `+0`, and `1 / (-0.0)` printed `Infinity` in both builds.
- `Basics.negate` is now `-n` (core body and the operator `Lower` writes in place).
  `backend.md` §4, *Arithmetic is an operator*, has the amended row.
- The development printer had no guard for `-` before `-`. `-(-0.0)` printed `--0.0`, a syntax
  error at load. `Print.devNegSpace` writes `- -0.0`. Release had the guard already.
- New fixture `run/NegateKeepsSignOfZero`. Red without the fix (four `Infinity` lines, and
  `Debug.toString 0.0` printed `-0.0`), green after, in both builds.
- `run/OperatorsInPlace` pinned the old answer (`1 / negate 0` = `Infinity`); now `-Infinity`.
- Asked the owner (`float-negate-sign-q1`): an `Int`'s `negate 0` is `-0` now. The backend reads
  no type, so `Float` alone cannot change. I went on with the recommended option.

**What I learned**

- `core/Debug.beni`'s `showFloat` tests `Object.is value (-0.0)`. With the old `negate` the
  `-0.0` was `+0`, so `Debug.toString 0.0` printed `-0.0`. One root cause, two wrong answers.
- The release optimiser (`src/js/Spec.zig`) already refuses to fold a `-` of zero, and its
  `exactInteger` refuses `-0`, so release needed no change.
- The worker `fingerprint` in `emit/*/dedicated/*` goldens hashes core, so any change to core's
  output moves them.
