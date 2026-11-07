## 2026-11-07 01:31 CET — Port the release Program wrapper fix (#2176)

**What I did**

Ported #1832 from the deleted workers-hostfree branch. `Emit.closeBoundary` seeded the
manifest Program as a type JavaScript sees only when the app had worker entries, so a
release build of a plain JavaScript-runtime platform pruned or unboxed it and the runtime
crashed on `main.a`. The seed is now `jsRuntimeProgramType`, used by the boundary and by
the specialiser's refinement. Added `run/PlatformProgramUnbox` and
`run/PlatformProgramFields` and the boundary.md §4 note. Both fixtures fail on master
under `--release` (`TypeError: a.a is not a function`) and pass with the fix. Page sizes
from `bench/size.mjs --pages-only` are byte-identical to master.

**What I learned**

The original also changed the golden `emit/release/app/NativeMessageData`, which master
does not have. Its `.v2.unchecked` goldens are empty on master now and were dropped. On
dagon (NixOS) `run/ChildProcessRun` and `run/ChildProcessCancelled` fail in the gates
because `/bin/sh` finds no `sleep`; that is the host, not this change.
