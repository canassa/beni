## 2026-10-22 23:00 CEST — a record update costs its written fields

**What I did**

- A record update `{ b | f = e }` was an `equal` of `{ ρ | f : v }` and the
  base, so it ran the full record unification: `ρ` bound to a fresh copy of the
  rest of the base's row, `v ⊓ b.f`, and a merged row of every field written
  back. One update of a w-field record cost O(w), and an `update` with one arm
  per field O(w²): 4 365M instructions for 2 000 updates of a 2 000-field
  record (#800, part of #464).
- Made the requirement its own constraint node, `update_base`
  (`Tree.Generator.updateBase`, used by the update and by markup's spread), and
  gave it `Unify.updateBase`: when the base's row (one segment, through an
  alias) holds every written field, it does only the steps another variable
  can see — each `v` meets the base's field in name-text order, `required`
  merges into the base, an alias base expands — and otherwise runs the full
  unification. checker-v2.md §6.5 records the rule and its four conditions.
- Added `check/bad/RecordUpdateThroughAliasExpands` and a `test-perf` scenario
  of 1 000 and 2 000 updates of a record that wide.

**What I learned**

- The full path's merged row names the written fields' fresh variables, not
  the base's. They are the same classes after the unification in every case but
  one: a field whose type is a generalised alias, which a fresh variable only
  copies (`takeName`). The fast path leaves those to the full path rather than
  argue that the two rows print the same.
- `ρ`'s bind is invisible only while `ρ` is not older than the frame: an older
  `ρ` would record a capture, which §8.3 can pick as an escape's region.
- 2 000 updates went from 4 365M to 45M instructions; the dashboard N=64's
  check from 207.4M to 204.7M.
