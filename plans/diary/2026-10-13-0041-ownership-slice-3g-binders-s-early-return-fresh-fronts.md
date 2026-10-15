## 2026-10-13 00:41 CEST — Ownership slice 3g: binders, `?`'s early return, fresh fronts, `Result`'s default

**What I did.** Specified and built `ownership-checker.md` §26. Checked whether the Lean model's shadowing defect
has a counterpart in `src/own/`: it does not — the walk keys everything by BIR local index, which lowering never
reuses — and `Walker.bindLocal` now asserts each index is bound once per walk (10 965 dumps, no trap). The binder
review found a real hole instead: `e?` returns `Err x` from its definition and the walk dropped it, so a caller
could write a list a returned `Err` held; the payload now joins the frame's result. A prepend whose front item is
a fresh list the base cannot reach no longer aliases the base. `Result.withDefault (Result.map …)` is two arms;
`andThen` stays refused. Fixtures `Binders`, `Question`, `PrependFresh`, `ResultDefault`; research 86; §26.7
lists every rule since 3b the Lean oracle does not model.

**What I learned.** Research 85 and §25.7 claimed §25.4's argument covers `Maybe.andThen`; it does not — `f` can
edit and then answer `Nothing`, and the default is read after. Bike Wars is now 4 of 15 rejected, 2 correct and
2 position, no limits; nothing else measured moves. The reach check in the fresh-front rule is load-bearing:
without it `List.drop base 1` after storing the item in `base` re-conses for real and would be accepted.
