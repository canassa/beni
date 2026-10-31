## 2026-10-30 16:12 CET — The holder index's review round (#1214, PR #1323)

**What I did.** Fixed the review of #1323. An approximate pending winner crashed the message
(it read the operand's instruction as a local): the cause word is condition 5's again
(`held-operand`, `element` only when no note at the winning hold is exact for any cell,
else `later-use`/`alias`), and a base of several cells adds `(approx)` alone. Every
refusal's wording is master's; only a DAG's witness changed. A deep-witness family
(`mk = ( lk, mk-1 )`) ran 2.6 times master's time at n = 400 for the same records; it is
within a fifth now. `keysOf` no longer packs a run into one word. Two counted tests:
opaque holders (k² on master) and the deep family.

**What I learned.**
- Read literally ("only at an unmaterialised `[*]`"), condition 5 would have changed about
  30 refusals in 11 fixtures that master names `element` (casts, `⊤`, a maybe-bit). Master's
  rule, no exact note at the winning hold for any cell, matches the decision and keeps them.
- The cost was not the segment tree: re-searching a local's uses from the root at every
  level, and allocating two lists per node. A child's range inside its parent's, by one step,
  and reused buffers fixed most of it; gdb under `-batch` with SIGINT sampling worked where
  perf was absent and attaching was refused.
- Keeping list slots past `items.len` to reuse their memory is unsafe: a reallocation copies
  only `items`. Keep every slot and a separate live count.
- `@hasDecl` does not see a non-`pub` `deinit`, so a reflective deinit skipped it silently
  (a leak report at exit, 2 s in Debug).
