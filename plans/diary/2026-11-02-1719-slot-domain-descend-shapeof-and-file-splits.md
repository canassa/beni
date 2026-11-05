## 2026-11-02 17:19 CET — slot domain: descend, shapeOf and the file splits

**What I did**

- Found the `Dict.descend` regression of the keys below a prefix (42 942 records, growth 3 999). A key
  below a prefix read each open entry's projection at its base, then read the base again through the
  base's own per-slot key, which projected the same arrival a second time; and every plain `fresh`,
  `⊤` or shared entry went through a per-slot key. Now an open entry's projection is added at its base
  once, and a plain atom is added directly. `Dict.descend` is 24 422 records (it was 30 659 before the
  regression), growth 0.
- The same change brought `Schema.shapeOf` (290 571, its source continuation is 310 272) and
  `shapesOf` (20 418) within `ownership_summary_size`. No limit, allowance or cache changed; no
  declaration is exempt. Every other cost family is unchanged (removeMin 23 539, rotate 60 6 862,
  Fields16 172 419, all growth 0).
- Split four files along real seams, so `rules_test.zig`'s size targets pass: `Walk.zig` (the walk,
  out of `Eval`), `Distinct.zig` (the relation and the distinct check, out of `Relation`),
  `ContractText.zig` (the dump's summary text, out of `Contract`) and `Runs.zig` (interned runs and
  the path column, out of `Slots`). `Walk` and `Distinct` take a new layer between `Relation` and
  `Eval`. Spec §3 and §5 amended in place. Output byte-identical over every root.
- Ledger per position: master's v2 → branch 2 543 same, 0 accepted→refused, 90 refused→accepted;
  against the previous head, the only limit lines that changed are core's madeNode/shapeOf/shapesOf,
  removed.

**What I learned**

- Three earlier compact representations for shapeOf failed because they folded arrivals whose
  projection differs per slot (parameters through `⟲`, opaque mid-paths, callback answers). An atom
  (`fresh`, `⊤`, shared) is the same at every slot, and the open entries already hold atoms
  uniformly. The cost was double work, not representation.
- The summary diffs that come with it (decode, describe, replySchema and Tea's `update` in bike-wars
  gaining `fresh` and losing an escape) are callers of shapeOf reading its real contract instead of the
  pessimistic one.
- `below_min` (16) still pays: with 1, generic removeMin goes from 23 539 to 25 458.
