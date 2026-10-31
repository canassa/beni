## 2026-10-31 06:49 CET — split Cond.zig into four files

**What I did**

- Split `src/own2/Cond.zig` (4 615 production lines on master after #1430, #1431 and #1425) into
  four files, a pure move for #1308: `CondAlgebra.zig` (L3: the constants, atoms, `and`, the flat
  form and lattice, the lazy `inst` atoms and `resolved`, `instantiate`, `rely`, the text),
  `Kappa.zig` (L4: κ storage, the radix maps, the trie of positions, `relabelMap`),
  `KappaRead.zig` (L5: the read machine, views and `chainStored`, the crossing, the aggregates,
  `deep`, `sep`, `apart`, `lower`, the frontier, `kappaLeq`) and `Cond.zig` (L6: the columns,
  `init`/`deinit`, `propagate` with its slice and frontier memos, `widenValue`). Production lines:
  578, 679, 2 527, 1 129.
- The three lower files are `Of(comptime Table: type) type` mixins. `Cond.zig` declares the
  columns and binds 169 names from them into `Table`, so no caller changed. The moved code is the
  same text, indented one level more; decls another file calls through the table became `pub`.
- The layers above moved up by two (Summary L5 → L7 … Enforce L14 → L16), in §5, the gate and
  each file's header. §5 has a row and a line target for each new file; Cond's target is 1 160
  (it was 4 620). §2.9 and §2.11 name the new file where they name a function.
- The first cut (PR #1433) was approved, then three PRs touching Cond merged; I redid the split
  on the new master from the same scripts instead of resolving conflicts.
- Dumped the v2 report of every ownership fixture (each `.platform` entry too), every `run/`
  program and core, at `--jobs=1` and `--jobs=8`, before and after: byte-identical.

**What I learned**

- A Zig struct cannot take its methods from several files, and a lower file cannot name the
  table a higher file declares. A mixin over a passed-down table type keeps the text verbatim and
  the callers unchanged; the gate sees only imports, so a script checked that no part calls a part
  above it. Only `leq` → `resolved`, the `inst` code → `canonical`/`expectSame` and `widenValue` →
  `propagate` crossed the old section lines.
- Everything in Cond but the algebra needs `Shape` (L3) and Summary calls `propagate`, so a split
  that keeps the import rule has to renumber the layers above.
- Keeping the split as scripts over line ranges made the redo on a moved master a matter of
  updating the ranges.
