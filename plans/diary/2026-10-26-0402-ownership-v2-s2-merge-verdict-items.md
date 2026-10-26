## 2026-10-26 04:02 CET — Ownership v2 S2: the merge verdicts' last items

**What I did.** Both S2 PRs have merge verdicts. On #1037:
`Regions.secondOrder` computes `base₂` in one suffix-sum pass per case,
O(regions), and charges each region's `base₂` to its source-settlement
lane (`Regions.build` now takes the account and the phase); the pipeline
form `m ▷ Maybe.map f ▷ Maybe.withDefault d` is pinned as a join with two
virtual arms, the inner call in the f arm and the `withDefault` reference
between the arms as the one point the rank₂ precondition excepts. On
#1036: a positions node's repeat through a side holding a recast anywhere
in its DAG reads `lost`, not only when the recast is the immediate side.

**What I learned.** My previous entry was wrong: the prepass DOES
recognise the pipeline form, because `▷` lowers to the same BIR `call`;
"not recognised" came from the in-process `qualifiedTarget`, which matches
one occurrence's symbol slots, so a second `Maybe.map` in the same test
module was missed. Resolved targets match every occurrence. Each form now
gets its own lowered module in the test. A `-q` that a git subcommand
does not take breaks an `&&` chain exactly where it matters: check each
branch's head before trusting a chained rebase.
