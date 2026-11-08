## 2026-11-08 20:38 CET — carry signed negation for literal negative zero

## What I did

- #1651: `1 / -0` printed `Infinity` in development and in `--release`,
  because the prefix `-` lowered to `0 - n`. The owner chose to carry #1292
  (Cesar's sign flip for all negation) into this fix.
- I applied #1292's change on master `d9ad227341`, with Cesar as the author:
  `Lower.zig` writes `-n`, `Print.zig` brackets a nested unary minus in
  development output, `Basics.negate` is `(0 - 1) * n`, the `backend.md`
  correction, the skill note and `run/FloatNegation`. I left out its
  committed run hashes, because master keeps them outside git.
- New fixture `run/LiteralNegativeZero`. Without the fix it prints
  `Infinity` six times in both builds. With the fix it prints
  `-Infinity` five times and `Infinity` once.
- Goldens that move: `run/OperatorsInPlace` (from #1292),
  `emit/OperatorsInPlace.js` (from #1292), `emit/release/inline/StringClass.js`,
  and the build fingerprints of five worker goldens under `emit/dedicated/`
  and `emit/release/dedicated/`.

## What I learned

- `core/Debug.beni`'s `showFloat` compares a value with `-0.0` through
  `Object.is`. That literal was `0 - 0.0`, which is positive zero, so the
  check compared with the wrong zero in both builds (release folded it to
  `0`). The fix corrects that comparison too; `StringClass.js` shows it.
- A worker's same-build fingerprint hashes core, so any change to `core/`
  moves the `emit/*/dedicated/` goldens.
- `run/FloatNegation/_expected.v2.unchecked` from #1292 is not necessary on
  master: ownership v2 now builds all of that fixture, and the harness wants
  no file when no line is unchecked.
- On master, the ownership checker v2 disagrees with v1 on four demands of
  `run/FloatNegation` (its `Ref` counter and a held operand). The same
  differences are already listed for other fixtures, so I added four lines
  to `tests/blackbox/ownership-v2-known.txt` with the same reasons.
- The review asked for a direct check of `showFloat`. `run/DebugToStringShapes`
  pinned `Debug.toString (-0.0)` as `-0.0`, but that passed by a double error:
  both zeros were positive. A new line `Debug.toString 0.0` printed `-0.0`
  without the fix in both builds, and prints `0.0` with it.
