## Normalize generic worker messages selectively

**What I did**

Replaced the temporary concrete-Program restriction with variable positions
in the declaration's Wire plan. Runtime shape walking stays inside those
positions and unknown record-row fields. Known stable branches are skipped,
and objects/arrays are copied only when a child changes. Lists inside records,
tags, tuples and nested List elements are materialized before native cloning.
Worker.beni and peer storage are unchanged.

**What I learned**

A declaration's own plan must retain its unknown positions in the worker realm;
launch-site instantiation is not enough. One generic echo declaration now runs
at two concrete message types in Chrome, with config, call, reply and event
round trips, plus nested List and Envelope declarations. A native-send probe
checks identity preservation and that known stable fields are not normalized.
Both compiler and runtime regressions were proved red with fixes stashed.
Generic function and native-value instantiations still receive full Wire
errors, including through warm interfaces.
An unchanged NaN field also needs identity preservation: strict equality would
copy its stable parent. The native-send identity probe includes that case and
failed before switching the comparison to Object.is.
