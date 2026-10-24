## 2026-10-24 02:14 CEST — A snapshot's widget record from the route table

**What I did.** #915, third slice. S1's `schema Widgets` is a `Value` per widget, with the same keys
and names as the keyed route table's rows. Its shape listed every widget again: `["w5",K,0,"_"]`,
plus a permutation. Now `SchemaLower.shapeOfRoutes` writes that shape from the route table. It
sorts the table into the canonical order at load time and computes `order` from the declaration's
order. So the reads, their order and the record made are the shape run's as before. New fixtures:
`emit/release/inline/SnapshotFromTable`, and `browser/inline/SnapshotFromTable`, with widgets
`zed`/`amy` so the order is permuted. Its expected transcript was made with the compiler before the
change. It covers a missing widget, `null`, an array, an extra key and `__proto__`.

**What I learned.**
- The issue said the permutation "goes where no one can observe the order". `schema.md` §6 says
  otherwise: a getter or a proxy sees the declaration's read order. So the order stays, and the
  bytes come from writing the keys once, not from dropping the order.
- `corpus_test` runs with any binary through `BENI_EXE`. Blessing a new page with the binary from
  before a change gives a transcript oracle for free.
