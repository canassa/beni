## 2026-10-24 00:22 CEST — One route table, and Object.assign

**What I did.** #915, first slice. A pushed-state route's row is now written once, as data, in its
keyed site's table: `[key, F, field]`. Before, each row was a constant of its own, `[F, field,
plan]`, named by the table and again by the snapshot's list. A snapshot site whose rows are the
table's rows, in the same order, passes the table. Its raw values are passed as the one object
they are read from (`widgets`), not as a list of reads. When no route has a record field whose
object the copy keeps, a copy is `Object.assign`, and the plan walker is not in the page.
`loadPlanned`/`loadAllPlanned` keep the walker for nested plans. Six `emit/release/inline` goldens
show the shape. `./rr check` passes on unique-components and big-component, sizes 1/16/64/256,
seeds 1–3. Spec: `browser-inline.md` §8.4, amended 2026-10-24.

**What I learned.**
- A loader that takes its copy function as an optional argument costs more than two exports. The
  release optimiser specialises a function argument that each export passes as a constant, and it
  then writes `Object.assign` in the loop. A runtime test on `undefined` stops that, and it also
  stops the two loaders being inlined at their one use.
- A field is spelled by its text in every record (`Fields`). So `widgets.w1` and `model.w1` are
  the same property in release, and the snapshot can read its raw values by the row's field.
- The scratchpad's `w/` directory belongs to another agent. Use a name of your own.
