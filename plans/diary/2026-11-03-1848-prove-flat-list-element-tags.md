## 2026-11-03 18:48 CET — Prove flat list element tags

**What I did**

- Added `TagsDeep` for result and chain tags inside arrays.
- Required deep tags at each live typed path in `FlatInvariant`.
- Added a deep-tag conclusion to every preservation case.
- Proved transport through heap frames, joins, origin substitution, projections and binders.
- Changed list reads to use the selected element's tags.
- Removed `ElementType`; lists now admit every `FlatType`, including results and integer chains.
- Added scope theorems and runtime probes for results, chains, stores and nested arrays.
- Updated the proof scope and the dictionary plan for #932 and #522.

**What I learned**

- Shape and provenance facts do not imply the tags that justify a skipped case arm.
- A live-path clause supplies the missing evidence without a claim about dead aliases.
- Universal chain tags transfer across a heap frame through reverse correspondence.
- The baseline rejects result and chain list types from the proof fragment, although the checker already accepts the probe programs.
- The Lean build replayed 10,932 constants and retained only the existing three general proof gaps.
