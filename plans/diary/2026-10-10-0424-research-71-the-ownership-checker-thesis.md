## 2026-10-10 04:24 CEST — Research 71: the ownership-checker thesis

**What I did.** Wrote `docs/design/research/71-ownership-checker-thesis.md`, the first-principles
design of an inferred uniqueness checker for `List` (editing a list while anything else holds the
old version is a compile error; every list a plain array written in place; `List.copy` the escape
hatch). Eight readers extracted and page-verified the core papers of `references/ownership/`
(Clean and de Vries; Aspinall–Hofmann–Konečný; Lean, Perceus, FP², Brandon 2026; OxCaml and Mode
Crossing; reachability types and Capybara; NLL/Polonius/two-phase/Emre; Futhark, Hylo, Swift and
the error-message literature; usage analysis, Affe, escape analysis). The thesis: uniqueness at
the update site decided by liveness (a dead alias is harmless, a read before the write is never
sharing), a directional cell-flow analysis per function, per-function summaries in the
interface, an optimistic fixpoint per recursive group, ownership classes on function types in the
seats the effect bits already use, and a handoff protocol P1–P6 for `browser-direct`. An
adversarial review found four accepted-but-observable programs (argument/capture aliasing at a
call, the optimiser folding a read across a write, top-level constants as holders, view-event
payloads) plus the entry-aliasing gap and a non-affine `once` closure; each became a rule (K4,
A5 as an optimiser input, escaped constants, P5's entry fixpoint, affine closures) and the
ledger is §4.6. Committed on `research/71-ownership-checker-thesis`; not pushed.

**What I learned.**
- The one hard case the literature leaves open — a closure that only reads a capture, called many
  times — is closed here only because beni's lambdas are in front of the checker and function
  types already carry inferred classes; every type-based system counts a capture as a use.
- No currying removes the case every uniqueness type system called "far from trivial"; strict
  source-order evaluation makes "before" syntactic. These two existing decisions carry most of
  the design.
- The rule as asked touches almost nothing in TodoMVC and Conduit: they edit lists with `map`,
  `filter` and `++`, not `set`/`push`. Widening the demand set to the rebuilds is where both the
  wins and the false errors are, and it cannot be one `map`: the same spelling in `view` becomes
  a derived value recomputed while the page holds the model.
- `core/List`'s writers are beni over `Js`, so their summaries must be asserted (trusted, like the
  rung), not inferred; `boundary.md` §4 does not promise a sibling keeps nothing, so the default
  for an undeclared `foreign` must be pessimistic.
- The release optimiser's single-use folding is sound only while lists are immutable; demands
  must become an input to `Opt`, like the `impure` bit.
- The sandbox refuses heredocs and multi-command pipelines in a worktree; write parts with the
  Write tool and concatenate with `cat`.
