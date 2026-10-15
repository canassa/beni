## 2026-09-26 — R6b: the new checker builds dispatching programs

**What I did**

- P6 elaboration (`check2/Elaborate.zig`, with `Unit.zig` for the DAG writer) builds the §13
  evidence tables from v2's answers, reading only what was recorded when each requirement was
  created; P5 (`Eager.zig`) writes v1's eager derived rows under v1's one-entry-per-parameter rule
  until R8a. `build --checker=v2` works for dispatching programs: every `dispatch/` golden is
  v1's byte for byte, 351 of 351 `run/`/`emit/` builds give identical JavaScript, and 60 pending
  fixtures are claimed (CK-08, 27, 28, 29, 32, 62 and the `run/` halves of CK-30, 31, 66, 67).
- §13.1 now allows shared terms (a DAG); the shared `checkI7` and `Edges` judge each term once,
  which kept CK-80 and CK-101 linear in `check`, and `Lower` binds a shared evidence closure to one
  `const`, which fixed CK-80's `build` half (JavaScript 474 KB → 3 KB at depth 12).
- The adversarial review found no wrong answer at run time across 823 old probe projects and
  hand-written non-structural `eq`/`compare`; v2 builds 91 programs v1 cannot. Both reviews found
  `[ [] ] == [ [] ]` failing `internal` under v2 (the `undetermined` leaf written outside a derived
  ancestor), now fixed, with `checkI7` checking the leaf's placement. New CK-103 (v1 hands an
  `eq` to a `compare` slot; latent, only ever applied to empty values) and CK-104 (a derived row's
  body naming a later declaration was not in emission order, so both checkers built a program
  that threw `ReferenceError` at load; fixed in the shared `Edges`).
- I accepted one change to the frozen v1 through shared code: the placement rule makes v1's
  `check` refuse CK-103's shape, which it used to compile into code that worked by parametricity.
  The fuzz and probe sweeps showed no other v1 result moving, and v1 is deleted at R12.
- Bench: `check` 1.02–1.04× v1, `build` 1.05–1.06×. All seven steps green.

**What I learned**

- "Identical to v1 on every corpus golden" is evidence about the corpus, not the rule: the
  `undetermined` placement bug had no corpus fixture. The fuzzer found it in 17 of 340 programs;
  keep a fuzzer in the adversarial brief.
