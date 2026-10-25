## 2026-10-25 02:30 CEST — S2a: Dict positions in the write-set pass

**What I did**

- Built `write-sets.md`'s amendment of 2026-10-25 in the pass: `{κ}`/`{*}` steps, the `Dict`
  tags with their joins and sequences, core rows for the `Dict` functions core has today, and a
  fold row for a `Dict` accumulator. Three `writes/` fixtures, red against the old pass; gates
  green; no emitted output moved.

**What I learned**

- A tag needs to ride on a `node` write, not a `value` one, or a one-key read gains nothing: the
  value writes below the path carry the precision.
- Applying a fold's callback has side effects in the key walk, so the fold row walks it only when
  the accumulator's type is known to be a `Dict`; otherwise a `List` fold would have moved.
- Two reads of the same payload field are two key symbols (§2.3's one-instruction rule), so a
  choice between `remove id` and `insert id` joins to `replaced`, not `at id any`; one
  `Dict.update` gives `any`.
