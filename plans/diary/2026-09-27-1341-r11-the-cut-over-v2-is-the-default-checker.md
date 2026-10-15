## 2026-09-27 — R11: the cut-over — v2 is the default checker

**What I did**

- `--checker` defaults to `v2`; the three gates run the new checker. `test-v2` is deleted (it is
  now `test-blackbox`), with its filtered binaries and `v2-expected.md`; the hidden
  `--checker=v1` survives only for scenarios that name it, until R12.
- All 119 claimed fixtures promoted from `tests/pending/` into the corpus; 70 `.codes` turned
  into blessed `.diag`s, each checked line by line against its `.codes` by script. 20 goldens
  re-blessed one at a time, each with its CK or D reason (table in the R11 As built). PERM and
  the nesting scenarios moved to a new `tests/blackbox/ordering_test.zig`.
- `tests/pending/` holds 13 red fixtures: 12 message-quality ones for R13, CK-126 for the schema
  slices; `scenario/CK-88` for R12. Pointer notes in `checker.md` and the spike now say
  "superseded", except the two D5 notes that stay normative until R14.
- Bench check phase 1.01× v1. Committed on my own gate run; the reason table is the review
  evidence the plan asked for.
- `CLAUDE.md` is now stale in five places (v2 as default, the pipeline description, items 3–5 of
  "Owed after the static-dispatch adoption", rule 1's contract list); I asked the owner.

**What I learned**

- Seven black-box scenarios still asserted v1 behaviour because only `test-v2`'s subset ever ran
  them under v2. A parallel harness proves what it runs, not what it skips.
