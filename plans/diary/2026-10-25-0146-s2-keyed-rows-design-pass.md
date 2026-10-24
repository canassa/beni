## 2026-10-25 01:46 CEST — S2 keyed rows: the design pass

**What I did**

- Wrote S2's design as `browser-inline.md` §9 and lifted O3 in `write-sets.md` (positions and
  edit tags in a `Dict`), with an amendment to `plans/direct-rewrite.md` §5's S2. Specified, not
  built; four questions for the owner on #298.
- Priced the target by changing tea-inline's own output one decision at a time, with copies of its
  big-table and unique-components emitters (`plans/inline-s2/`), every variant passing the research
  script check with its same-task pass at seeds 1–3. Big-table's target: 1.08× tea-inline per table,
  1.09× at N = 256, 1.29× at N = 1. Unique-components' list widgets: +3 % per widget.
- Ran the research bench (quick, on a loaded host) against vanilla and tea-inline.

**What I learned**

- Edits from the write set's tag alone are not enough: a loop of `Dict.update` over keys is `{*}`
  to the tag, and repainting every row made `updateEvery` and `serverUpdate` 3–4× vanilla. Following
  each `Dict` write with its row edit, where the lowering writes the call, brought them to tea-inline.
  The tag stays for writes in code the lowering does not write.
- The decided `Dict` index (key → position) rewrites every later position on a removal: 10 µs at
  1 000 rows, 130 µs at 10 000. An index from key to entry pair costs 0.7 µs and is 100 B smaller.
  That is the owner's decision to revisit, so it is a question, not a change.
- S2's mechanism is nearly free per unit; its N = 1 is set by core's `Dict`, the row list, LIS and
  typed pushes (about 630 B), so the N = 1 bar against tea-inline as generated cannot be met while
  those decisions stand. The research numbers also carry Vite's preload polyfill (about 240 B),
  which beni never ships.
- A plan phrase can be wrong in a small way that matters: "the id → row map built lazily" makes an
  append loop O(n²). The row lookup follows the dictionary's index instead.
