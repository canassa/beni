## 2026-10-09 22:40 CEST — the direct platform's slice S2: rows

**What I did**
- Specified S2 before building it (`browser-direct.md`, `boundary.md` §9.4.6 version 1.8,
  `write-sets.md`'s *which `[*]` is a row's own*), then built it: the pass gives each `For` row's
  item a root of its own and each read a bound depth; the compiler turns write sets into per-key
  edits per `For` (shapes, index visits, every-row visits); `direct.zig` compiles rows, scripts,
  nested lists, a delegated walk per list and own listeners for non-bubbling events; the loops
  live in `Direct.beni`. K3 bakes a constant list's rows into the template.
- Rebuilt `Keyed`, `KeyedInPlace`, `RowItemOnly`, `RowMountOrder`, `ForAtEnds` and the owed
  `ForForms` on `browser-direct`, and added `NestedFor`, `StopInRow`, `RowBlur`,
  `DetachedRowEvent`, `NoOpEdits`, `RowReadsList`, `BakedList`, `DuplicateKeys`, emit goldens and
  three refusals. The fuzzer gained bursts, one task per action.
- Measured every sweep and the table app, and five forms of finding a row (research 67).

**What I learned**
- §14 listed S2 fixtures that need S3's pieces (rotate, reverse, `List.map`); the S3 entry wins,
  and each fixture names what it gave up.
- The verify mode caught a real defect at once: a row whose item no hole shows kept a stale
  item, which a listener body would have sent. An element write must always visit its row.
- Kill criterion 4 fires on the swap, but P3 measures the same in the same batch: the gap is
  `List.swap` on a trie, the model half.
- Keyed scripts are only rank-correct for unique keys; the sweep found it, and the fix is the
  reconciler S3 builds. Pinned, not hidden.
- A burst in one task is a different page history on a batching platform; the fuzzer's bursts
  must be tasks, as a user's clicks are.
- S2's runtime growth pushed three S1 pages over the budget with value fuzzing: every build
  checks the whole runtime module.
