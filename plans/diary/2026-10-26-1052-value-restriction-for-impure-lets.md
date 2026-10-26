## 2026-10-26 10:52 CET — value restriction for values made by a call

**What I did.** Closed #1048: a block value bound to `Ref.make []`,
`Queue.unbounded ⊤` or `Deferred.make ⊤` was generalised, so one cell was
written as `List String` and read as `List Int`. checker-v2.md §8.4 now has
a dated amendment, and the checker holds, at a `let` frame, every young
variable an expansive value binding reaches at a non-covariant position
(`Generalize.holdExpansive`, `Walk.nonCovariant`). The same hole existed at
the top level (`cells = Ref.make []` was `∀a. Ref (List a)`); there the
evaluation class is solved, so `Generalize.impureValues` refuses an impure
top-level value with such a variable as `impure_polymorphic_value`.

**What I learned.** Effect bits are solved after P5, and a `let`'s
right-hand side has no class of its own, so the `let` rule has to be
syntactic; Garrigue's relaxation keeps `xs = List.reverse []` general.
Without per-type variance (a `foreign type` has none), the top-level rule
is coarser than "makes a cell": `Debug.log` makes a value impure, and
`Navigation.reload : Cmd msg` had to take `⊤`. Core and the platforms cast
with `Js.to` under polymorphic `let` annotations, and fixtures use
`Debug.todo` at polymorphic types, so `Js.to`, `Js.from`, `Debug.log` and
`Debug.todo` count as values when their arguments are. `Js.ref 0` and
`Dict.insert Dict.empty 1 xs` now fix their `number` variable at the first
use, which moved three ownership summary goldens.
