## 2026-09-24 — R1: shared-code fixes and v1 one-liners

**What I did**

- R1 of the checker rewrite (`plans/checker-rewrite.md`) closed CK-11, 17, 19, 43, 44, 45, 46,
  47 and 71 on v1, CK-12 by a unit test, and CK-78 as a decision. Each fixture was red with the
  fix stashed and is promoted from `tests/pending/` into `tests/corpus/` with a blessed golden.
  - The record-alias constructor emits a record (D12, `backend.md` §4); an irrefutable alias
    pattern reads the fields in declaration order. I decided that under rule 7 after the review:
    R1 had first refused a pattern that ran correctly on 22daa5f and guarded nothing. Imported
    alias constructors stay refused until interface v3 carries field names (R3).
  - Warnings no longer switch off exhaustiveness; `Session`'s quiet flag counts errors.
  - Symbol ids are input-derived: the per-worker intern pools merge in file-index order. A
    loaded black-box test (one spinner per CPU, 36 runs) differed on 22daa5f and never now.
  - The equatable walk's stack grows instead of answering "yes" at 256. That exposed a runtime
    `RangeError` on derived `==` past ~40 000 fields, so derived record `==`/`compare` is
    refused at check time past a named cap of 4 096 fields (CK-79, lifted in R2a).
  - Frontend artifact format v4 (a new `..` token).
- New findings: CK-78 (decided), CK-79 and CK-81 (a compiler segfault printing a 60 000-field
  derived body; pre-existing) assigned to R2a, CK-80 (exponential `==` on nested tuples) to R6a.
- Gates: 470/470 unit, 292/292 black-box, fmt-check green; `test-pending` 74 RED, 0 GREEN. Bench
  check phase +1.0 % against 7427828.

**What I learned**

- Making one walk honest moves the failure somewhere else: the growable walk turned a false
  refusal into a runtime stack overflow. Every "we now accept more" change needs a probe at the
  new extreme, run to completion in Node, not only through `check`.
- A reviewer's measurement beat the brief twice: capping CK-71's load at 8 spinners made the race
  vanish, and the planner's "silence only T's constructors" was not implementable in lowering.
