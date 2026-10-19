## 2026-10-19 11:59 CEST — the rebase keeps master's code, and the funnel meets the shapes fork

**What I did**

- Rebased `emit-cache-rows` (the emit rows of #94's step two) from `1e0a6cb68` onto `acccea6a3`,
  113 commits of master. One conflict, `src/js/Lower.zig`, three hunks, because master's schema
  shapes work reworked the same `SchemaValid` call sites the funnel touches. The resolution kept
  master's code — the runtime safety net that cross-checks reachability's validator runs against
  lowering's, `runner`/`shapeRunner`, the `shape_callees`/`shape_args` branches — and re-expressed
  the funnel through it: `.schema_library` asks in both shape branches and in `jsonValidatorCall`,
  and `SchemaLower.zig:162/216` read the accessor instead of the field. `git merge-tree
  --write-tree HEAD origin/master` is clean, so the PR's CI will run.
- Found the hole the rebase exposed: master's `schema_shapes` (`Emit.zig:3805`, `:4460` →
  `Lower.zig:295`, `:659`, `:664`) is build state that reaches printed bytes — it decides a
  module's shape runs over validator workers, and shape runs change call names and a schema
  declaration's body — and `EmitPack.Fact.Question` has no member for it. Filed **#432** with what
  its done needs: §9's fact list amended and the question asked where the answer lands, the maker's
  canonical answer decided (it lowers with the field's default `false` today, so every row records
  the fork's false side), and a program with ≥ 4 shape runs so the differential tests can see the
  boundary. Nothing reads a row, so this cannot miscompile yet; the join would have spliced across
  the fork with every recorded ask matching.
- Proved the re-measure's instrument before trusting it: `pack-stats.mjs` finds the embedded pack
  in a beni binary by magic scan and validates the whole table before it reads a byte of it, and it
  reproduces the pre-rebase branch pack exactly — 6 399 846 bytes, 126 emit rows over 63 keys, 53
  payloads of 2 438 238 — so the numbers come from the compiler that carries them, not from a
  guessing game over a cache of eight packs.
- Re-measured on the new base, one locked job (fresh ReleaseSafe builds of both sides): the three
  `diff -r` pairs empty — 16, 43 and 62 files byte for byte, maps included — the `emit/` goldens
  unchanged, no program ran under Node for want of a run hash, and the medians of 5
  (`perf stat -e instructions:u`) against `acccea6a3`: dict 158.81M → 159.34M (+0.33%), apiitems
  531.97M → 536.51M (+0.85%), corpus 421.97M → 425.21M (+0.77%). The pack: 4 182 851 → 6 672 561
  bytes (2 486 126 of emit payload in the 53 records, plus 3 584 of table) — 128 emit rows over 64
  keys (57 modules plus the seven chain instances). `core/Record.beni`, new on master, is the
  fifth unit-less module: its 25-byte payload is the one the four others already shared, which is
  why 64 keys still collapse to 53 payloads. `zig build gates` is green on the tree, 239/239 steps
  and 1389/1404 tests, and a fresh-cache `--summary all` build times the maker where it really
  ran: compile 9 s, run 1 s.
- Updated the numbers in `backend.md` §9's *As built* note and the 09:58 entry, and added the one
  honest sentence the note was missing — the shapes fork's `schema_shapes` escapes the fact list
  today, with #432 named — then logged this entry: one docs-only commit after the gates, because a
  doc edit is free at any time and a `src/` edit costs a full gates cycle.

**What I learned**

- A normative list is only as complete as the merge stream feeding it. §9's completeness rule named
  the facts a row may carry and called a read that escapes the list a defect; the shapes fork
  landed in `Lower` with no fact, and no gate can see it, because both of its failures — a wrong
  splice and a missed fallback — are invisible until something reads a row. The oracle the spec
  names sees it only when a fixture crosses the fork, which is why #432 asks for one.
- The rebase rule "master's new code stays, re-express the slice through it" resolved cleanly here
  because the funnel's unit is a read: every new read of an old fact (`--schema-library` through
  the shape branches) takes an ask, and the one new fact with no question became an issue instead
  of a redesign inside a rebase.
- A pack has no black-box witness, so its numbers need an instrument that reads what ships: the
  magic-scan extractor turns "which of the cache's packs did the default compiler embed?" into a
  fact of the binary — and validating the table first caught the code's own `"BENIPACK"` string as
  a false positive before the real blob.
