## 2026-10-19 11:42 CEST — admit branch in the flat fragment

**What I did**

- `FlatANF0` contains `branch` over two fragment expressions on an integer condition. Part of #165, after #422. New module `Branch.lean` between `Let` and `Trace` with the evaluation equations and `branch_preserved`; `InferBranch.infer_branch_success` in `Checker.lean` extracts the checker's two arm runs (the facts are restored between them) and the join; `Fields.lean` gets `flatAbstract_join`, `describes_join`, `flatInvariant_more_escapes` and `ty_equal_flat` (`ty_equal_int` moved there from `Frame.lean`). `flat_static`, `flat_uses_typed` and `flatExpr_default_uses` got the arm.
- Folded the #422 review notes 1 and 2 into COVERAGE, README and PROOF-PLAN.
- Probes `branchOps` (a push onto the result of a branch between two lists: accepted, one in-place write, `[2, 9]`) and `branchAlias` (the other list live after that push: refused by the Dead test, the runs differ).
- `lake build`: 10,086 constants, the 4 pinned `sorryAx` dependents, 63 files, 3 sorries, every `#guard` passes. Three draft rounds in scratch, then the integrated build passed first time.

**What I learned**

- The case expressions do not fit a slice of this size: `resultCase` needs the `result` type, `ok`/`err`, and a pairing of the checker's `.bottom` arm with the runtime tag (the checker skips an arm whose payload abstract is bottom); `chainCase` needs the `chain` type, `endChain`/`link`, and a naming for the tail the heap side copies under the input's cells. PROOF-PLAN records both. `branch` alone needs nothing new in the relation.
- `Abstract.join` is defined by well-founded recursion, so its arms do not reduce by `rfl`; equation lemmas proved by `simp [Abstract.join]` (`join_scalar`, `join_list`, `join_record`) carry the proofs.
- `obtain ⟨rfl, rfl⟩` on `a = b ∧ x' = x` eliminates `x`, not `x'`; state the equation as `x = x'` to keep the name the rest of the proof uses.
- `Ty` has no `LawfulBEq` (`Ty.equal` on a nested inductive); on a flat type the equality is provable by induction on `FlatType`.
