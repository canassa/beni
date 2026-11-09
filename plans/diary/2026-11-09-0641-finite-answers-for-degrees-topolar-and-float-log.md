## 2026-11-09 06:41 CET — finite answers for degrees, toPolar and Float.log

**What I did**

- Issue #2021. `degrees` multiplied before it divided, so `degrees 1e308` was
  `Infinity`. It is now `angle * (pi / 180)`.
- `toPolar` squared its sides: a side past about 1e154 overflowed, and a side
  under about 1e-162 underflowed to a radius of 0. A private `hypotenuse` now
  scales both sides by 2^∓600 when the larger side is past 2^500 or under
  2^-500.
- `Float.log` keeps the IEEE answers, but it answers a non-finite `ln` (number
  or base 0 or negative) without the division. Its doc comment names the
  non-finite answers.
- Fixture `run/FloatFiniteAnswers`: red on master, green after. Four worker
  goldens moved only in their fingerprint.
- `language.md` §13.4 is only in the open PR #1999. I asked the owner
  (q1, q2) and did not edit the document.

**What I learned**

- A power-of-two scale is exact, so the scaled hypotenuse gives the old
  formula's answer bit for bit in the middle of the range. `Math.hypot` would
  not: its rounding is the engine's choice.
- `negate 0` is `0 - 0`, which is `+0`. To write `-0` in beni, write
  `0 / (-1)`.
- Any change to `core/` moves the worker fingerprints in the
  `emit/**/dedicated/` goldens. Bless them with `-Dcorpus=dedicated`.
