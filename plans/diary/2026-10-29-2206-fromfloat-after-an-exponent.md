## 2026-10-29 22:06 CET — fromFloat after an exponent (#1164)

**What I did.** `String.fromFloat` now adds `.0` to a whole float only when the printed text has no `e`, as `Debug.toString` already did. Fixture `run/FromFloatExponent` covers 1e21, 8.41e21, 1e23, 1e300, -1e21, Number.MAX_VALUE and the round trip through `toFloat`; it printed `1e+21.0 Nothing` before the fix. `language.md` §12 float table amended. Release output of a program reaching `fromFloat` grows 33 bytes raw (341 to 374). Every run-hash changed because core is part of each program.

**What I learned.** `"${text}.0"` needs `text : String` pinned (ambiguous interpolation); `text ++ ".0"` is shorter anyway. One check_test case (tuple DAG) failed once at load average 50 and passed alone.
