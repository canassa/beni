## 2026-10-16 20:17 CEST — Prove the first flat fragment

**What I did**

I proved the main theorem's conclusion for a first fragment of the ownership model, as a separate theorem.
The fragment contains integer and variable atoms, `let`, integer list literals, `push`, `length`, and `shared`.
The proof carries a strengthened relation through every expression, in both runtime directions, from the actual acceptance, typing, and shadow runs.
The push case derives the written array's separation from the real default demand.
I integrated the 39 checked scratch modules into one import chain under `Ownership/FlatFragment/`.

**What I learned**

The audit rejects an equation lemma that two modules realize, so proof modules must form a chain.
A let needs the right-hand side's static facts before its runtime run; a separate static theorem supplies them.
Most check failures were elaboration details: unreduced pair projections, a dotted constructor postponed past unification, and `rw` on a `≤` goal.
The fragment proves nothing for calls, views, or the three general obligations.
