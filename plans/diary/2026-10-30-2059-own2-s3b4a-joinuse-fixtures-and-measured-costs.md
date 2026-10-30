## 2026-10-30 20:59 CET — own2 slice 4a: joinUse hole, fixtures, measured costs

**What I did.** On `own2-s3b4a`:
- I fixed an unsound join. `Summary.joinUse` made a `union` of two use shapes, and `Calls.marked` never reads a union, so each round's join dropped the writes below a port's root. It now merges path by path with `UseMerge`, which moved from Rows into Summary.
- A spread literal's outer call is now named `<construction>`, as v1 names it.
- I re-blessed the `.v2.unchecked` goldens and added known entries for `InitializationLimit`, which v1 stops at its 32-round limit.
- I wrote `RecursiveGroups` (with `rot` and its dead-`b` twin), `RecursiveGroupsPermuted` and `RecursiveGroupsSharedRead`. All three hold v1's verdicts and fail on master's `src/`.
- I added counted tests for `GroupSelfFold` (4 walks, growth 0 at 10, 100 and 1 000 statements) and `GroupFieldShift` (n = 4 settles in 7 walks; n = 16 is loud), and a failure twin: a group stopped by a limit publishes nothing, and an earlier group still serves its callers.
- I raised four line targets, each with its reason.
- I filed #1366 (`Ref.set` followed by a call that writes the cell), #1367 (a callee that answers the written argument's holder), #1368 (`mergeSort`'s walk cost) and #1372 (a walk costs far more records than the plan's fact count).

**What I learned.** A use shape must never be joined into a `union`. A reader that skips unions loses writes without any error. The plan's per-walk costs count facts, but a walk costs records. At `GroupFieldShift` n = 16, a walk is about 320 000 records, mostly `memo` and `inspection`. And `GroupSelfFold` takes 4 walks, not 2: the call's view adds `π1[*] A`, and then `π1[*] R`.
