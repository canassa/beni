## 2026-10-25 02:26 CEST — record refusals of the research apps, and three holes

**What I did**
- Investigated #879: record enforcement refused reactivity-research's big-table, derived-graph and routed-app
  on browser-inline. I reduced the refusals to four causes and classified each, and an adversarial reviewer
  agent tried to break each classification.
  1. `List.sortWith` loses the record condition. It is a false refusal, fixed as a row in #984.
  2. A run of a schema built at run time is never refined. It is a false refusal, and its obvious fix was
     unsound. It waits for #983.
  3. derived-graph's `serverItems` shares one upsert record between two kept items with one id. That is real,
     so the generator in reactivity-research was fixed with `Record.copy` (its commit 1012209).
  4. `ctorClass` drops record payloads. That was routed-app, and it is also a soundness hole.
- #983 (closes #962) closes three accepted programs that browser-inline miscompiled. Each one was a gate
  that asked only `holdsList`: a constructor passed as a function value, a view message carrying a top-level
  record, and a conversion answering a record the program made (also through `codecRunRow`'s "decoded slot
  empty" refinement). Each now carries the record where only record facts read it, and no list line moves.
  Each has a `build/bad/inline` fixture that miscompiles on master: 11 for 1, a counter that counts 1, 2, 3
  for 1, and 9, 18, 27 for 3.
- Opened #963 (`λv → Pushed v` refused as a shared list), #964 (routed-app's `check` at N=128 does not
  finish in 300 s), #976 (a send gives up its record objects unchecked) and #982 (a callback read out of a
  parameter's record drops its record answer, which also miscompiles on master).

**What I learned**
- §31.2 gave records a cell, but every gate written before it that asks "may this hold a list?" now drops
  record cells silently. Most of them are soundness holes, not precision gaps. `objs` and `nonlistOf` are
  the way to give records back their cell without moving a list line.
- A "no provenance names its base" pending can mean the walk dropped a cell, not that no cell exists. Before
  treating an empty base set as vacuous (#870's B1(ii)), make sure nothing upstream filtered it out.
- An asserted row replaces every walked fact. Write each fact it keeps on purpose: uses, supplies and
  `calls`, and make the record condition conditional (`sortWith [ r, r ]`).
- `git stash` is shared by every worktree of a repo. Prove a fixture red with a separate binary built from
  master instead.
