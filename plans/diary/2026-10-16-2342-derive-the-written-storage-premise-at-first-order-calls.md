## 2026-10-16 23:42 CEST — Derive the written-storage premise at first-order calls

**What I did**

- #169, third slice: `CallDerivation.linkedWritesCovered_of_applyCall`. At a first-order call without captures, the written-storage premise of the summary theorems follows from the call-site invariant and the call's own demands: `applyCall` demands every published row against the other operand paths, the operands are live and named at every path, `linkNamed` makes a linked input array share the written array's origins, and the Disjoint test refuses the overlap.
- Helper lemmas: bind success and a demand loop's row tests in the checker's monad, a demand keeps the escapes, `AtPath → Reaches`, a parameter row's instantiation, membership in `otherPaths`, and that the names at a path of a first-order, known abstract are recorded at that path.
- Left open and recorded: calls with captures, calls with function-valued inputs, and the wiring from `inferExpr`'s `.app` case.

**What I learned**

- The premise's `canonicalPath` hypotheses are not needed on either side: `Covers` applies at any path with an `ArrayAt`, so the derivation holds for any canonical input list.
- `namesAt` falls back to the root cells only under an `unknown` root, so a "known inputs" hypothesis makes a name at a path exactly a recorded cell at that path.
- A `match` alternative in tactic mode substitutes the scrutinee in the hypotheses too, and `cases` on an equality of pairs may eliminate either variable; leave the state to inference (`_`) when the direction does not matter.
