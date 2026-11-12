## 2026-11-12 23:24 CET — Ownership v3: the kernel text, and the core rebuilt on it

**What I did**

- Wrote `docs/design/ownership-v3-kernel.md`, the normative text `src/own3/` never had: the facts and their
  kinds, the one principle (a fact a verdict depends on negatively comes from named, positive facts; a
  missing fact is the pessimistic one), the five forms of report 116 as named places in the code, one rule
  per construct with a one-sentence argument, the resource limits, and the checks that run in safe builds.
- Rebuilt the holder side of `src/own3/` on it: `v_shared` is gone (`outside` with its reason, `unknown`
  over what it is made of, or the walk gives up and publishes nothing); a fresh cell has a canonical name;
  `twice` has one test and `linear` one writer, three-valued; no fact by a name (`eq`/`compare` by the
  dispatch table, `sender` as a word on the platform's alias, `Dict.focus` no longer trusted by name,
  worded rows pessimistic where their words are silent); markup holds its holes. Deleted `also`,
  `Src.shared`, `smear`, `sourcesApart` and its hand arguments, the `late` reads, the by-name method check.
- Report 117: the five faults of report 115 refused, every sweep and fault folder at 0 traps, sanitiser 0
  traps, real writes 279 of 308 (13 of the 20 lost are the markup decision, which the owner has; the toggle
  measures 292), speed 879k lines/s on v2's modules (6.6× v2). One Opus reviewer proved two traps on the
  rebuilt core and argued a third; all three fixed and pinned in `check_test.zig`.

**What I learned**

- A fresh cell's name must be canonical, or a recursive group never settles: `List.sortRange` was walked 16
  times in a minute with first-appearance numbering. Name by allocation instruction; by the call and the
  callee alone while the callee's contract is a draft.
- A callee's `linear` claim covers only what its frame saw as atoms. An answer of a function parameter is an
  opaque root there, so the caller tests pairs of result entries that hold one.
- An atom must record the *part* it was read through, not the root: two reads of one element of a list the
  frame made are one cell, and `linear` says nothing about that. Conversely, the operand rule in
  `otherReaches` needs the operand's own root's `linear`, not the first holder's. The reviewer's `[ a, a ]`
  and the old `levelsApart` fixture together pinned both sides.
- An escape of an answer root must carry what the function was handed, and a caller must record a call's
  escapes before it judges the call's writes.
- The word `fresh` on a row named one site for the whole result, so a builder's storage and its elements
  were one cell once names existed. A row's words have to say how many new cells there are.
- The sweeps (60 000 programs) found nothing after the rebuild; a fresh reader found three holes in a day.
  Report 116 §4's point about the testing method stands against this work too.
