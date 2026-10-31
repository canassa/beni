## 2026-10-31 11:10 CET — split Transfer.zig into seven files

**What I did**

- Split `src/own2/Transfer.zig` (3 044 lines after 5f) into seven files, a pure move for #1457,
  the way #1433 split Cond: six `Of(comptime Frame: type) type` mixins on L10 and `Transfer.zig`
  on L11. The parts, in the order their code depends: `TransferFrame` (accessors, value helpers,
  uses; 247 lines), `TransferBeside` (a write's other paths and what is beside it; 936),
  `TransferPattern` (patterns and splits; 330), `TransferConstruct` (constructions; 338),
  `TransferCall` (call application; 160) and `TransferGroups` (a use below a parameter's leaf,
  `Plain`, `Group`, `CallSnap`; 727). `Transfer.zig` keeps the fields, 72 bindings, the
  preliminary passes and the walk (614 lines; target 640, was 3 050).
- The moved text is the same, one level deeper; a method another file calls through `f.` became
  `pub`. A line-multiset check (indentation and `pub ` ignored) finds no line of the original
  gone; the lines added are imports, headers, the mixin wrappers and the bindings.
- Two decls changed sections because of the call graph: `reentries` (called by `readsOf`) went
  down to `TransferFrame`, and `several` (called only by patterns) to `TransferPattern`. A script
  checked that no part calls a part after it.
- The layers above Transfer moved up by one (Walk L11 → L12 … Enforce L16 → L17), in §5, the
  gate and each file's header. §5 has a row, a target and a reason for each new file, and a
  paragraph on the seven files. §2.11 and §4.1 name the new file where they name a function.
- Dumped the v2 report of every ownership fixture (each `.platform` entry), every `run/` program
  and core, at `--jobs=1` and `--jobs=8`, before and after: 4 148 files, byte-identical, and each
  `--jobs=1` dump equals its `--jobs=8` one.

**What I learned**

- The parts import no part (each needs only Calls and below), so all six fit on one layer. The
  gate's table must be non-decreasing in layer, so the L10 rows go before `Transfer.zig`'s.
- The gate also wants an `Obligations kept here:` line in every header, new files included.
- Dead or duplicated code found on the way is listed on #1457; nothing is deleted here.
