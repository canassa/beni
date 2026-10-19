import Ownership.FlatFragment.Branch

/-! The first flat fragment: the structural induction and the public trace corollary. -/

/-! generic preservation for the first flat fragment, and its public
trace corollary. The induction is structural over the fragment: no case
calls, so no depth induction is needed. Each case is the checked case lemma.
The corollary starts from the real closed-program acceptance and the real
initial runtime states. No pinned soundness obligation enters.
-/

namespace Ownership.FlatFragment.Preservation

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.Support
open Ownership.FlatFragment.Atoms Ownership.FlatFragment.AtomInteger Ownership.FlatFragment.CheckerExtraction
open Ownership.FlatFragment.Literal Ownership.FlatFragment.Length Ownership.FlatFragment.Shared Ownership.FlatFragment.Push Ownership.FlatFragment.Let
open Ownership.FlatFragment.VariableFacts Ownership.FlatFragment.VariableRuntime Ownership.FlatFragment.VariablePreservation
open Ownership.FlatFragment.AtomPreservation Ownership.FlatFragment.Env Ownership.FlatFragment.LiveSets Ownership.FlatFragment.Liveness Ownership.FlatFragment.AtomRuntime
open Ownership.FlatFragment.Fields Ownership.FlatFragment.Observe Ownership.FlatFragment.AtomInference
open Ownership.FlatFragment.Branch

theorem heapAtomPost_heap (hs : State) (observations : List Observation) :
    (Ownership.FlatFragment.StateFrame.heapAtomPost hs observations).heap = hs.heap := by
  unfold Ownership.FlatFragment.StateFrame.heapAtomPost Ownership.FlatFragment.Observe.heapObserved Ownership.FlatFragment.StateFrame.heapTicked
  split <;> rfl

theorem atomHeapPost_heap (hs : State) (observations : List Observation) :
    (Ownership.FlatFragment.AtomPreservation.heapAtomPost hs observations).heap = hs.heap := by
  unfold Ownership.FlatFragment.AtomPreservation.heapAtomPost Ownership.FlatFragment.Observe.heapObserved
    Ownership.FlatFragment.AtomPreservation.heapTicked
  split <;> rfl

/-- Both real evaluations of an atom expression succeed when their runtime
bounds permit the tick, from the atom's two runs. -/
theorem atom_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {depth : Nat} {a : Atom} {o : Observation} {w : Value}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueAtom : ValueSemantics.atom (valueEnv env) a = .ok o)
    (heapAtom : InPlaceSemantics.atom (heapEnv env) a = .ok w)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.atom a)).run vs =
      .ok (o, Ownership.FlatFragment.StateFrame.valueAtomPost vs) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.atom a)).run hs =
      .ok (w, Ownership.FlatFragment.StateFrame.heapAtomPost hs vs.kept.toList) ∧
    FlatInvariant declarations (Ownership.FlatFragment.StateFrame.valueAtomPost vs)
      (Ownership.FlatFragment.StateFrame.heapAtomPost hs vs.kept.toList) env live aenv tenv escapes gamma := by
  obtain ⟨footprint, represented⟩ := inv.observers
  have valueObservedRun := value_observeKept_run (Ownership.FlatFragment.StateFrame.valueTicked vs) represented
  have heapObservedRun := heap_observeKept_run (Ownership.FlatFragment.StateFrame.heapTicked hs) represented
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  refine ⟨?_, ?_, Ownership.FlatFragment.StateFrame.tick_observer_post_invariant inv⟩
  · rw [value_atom_eval_equation vs (valueEnv env) valueAtom]
    simp [hasDepth, hasFuel, valueObservedRun, Ownership.FlatFragment.StateFrame.valueAtomPost,
      Except.bind, Except.pure]
  · rw [heap_atom_eval_equation hs (heapEnv env) heapAtom]
    simp [hasDepth, heapFuel, heapObservedRun, Ownership.FlatFragment.StateFrame.heapAtomPost,
      Except.bind, Except.pure]

theorem atom_failure {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {depth : Nat} {a : Atom} {o : Observation} {w : Value} {message : String}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueAtom : ValueSemantics.atom (valueEnv env) a = .ok o)
    (heapAtom : InPlaceSemantics.atom (heapEnv env) a = .ok w)
    (failed : (ValueSemantics.eval depth declarations none (valueEnv env) (.atom a)).run vs =
      .error message) :
    ∃ actualMessage,
      (InPlaceSemantics.eval depth declarations none (heapEnv env) (.atom a)).run hs =
        .error actualMessage := by
  by_cases noDepth : depth = 0
  · exact ⟨"in-place execution exhausted depth", by
      rw [heap_atom_eval_equation hs (heapEnv env) heapAtom]
      simp [noDepth]⟩
  · by_cases noFuel : vs.fuel = 0
    · have heapFuel : hs.fuel = 0 := inv.fuel.symm.trans noFuel
      exact ⟨"in-place execution exhausted fuel", by
        rw [heap_atom_eval_equation hs (heapEnv env) heapAtom]
        simp [noDepth, heapFuel]⟩
    · have success := (atom_runtime_success inv valueAtom heapAtom noDepth noFuel).1
      rw [success] at failed
      contradiction

/-- Generic preservation over the fragment. -/
theorem flat_preserved {declarations : List Decl} {self : Decl} {e : Expr} (flat : FlatANF0 e) :
    ∀ (vs : ValueSemantics.State) (hs : State) (env : List (Var × Observation × Value))
      (live : Live) (aenv : Env Abstract) (tenv : Env Ty) (before next : St) (gamma : Naming)
      (type : Ty) (bound : List Var) (after : Live) (site : List Nat) (result : Abstract)
      (inferenceFuel depth : Nat) (ctx : Context),
    FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma →
    exprType declarations self tenv e = .ok type → shadowFree bound e = .ok () →
    (∀ x ∈ env.map Prod.fst, x ∈ bound) → (∀ use ∈ uses e, use ∈ live) →
    (∀ use ∈ after, use ∈ live) → ctx.config = {} →
    (inferExpr inferenceFuel ctx aenv e after site).run before = .ok (result, next) →
    Preserved declarations depth env vs hs e after aenv tenv next.facts.escapes result type := by
  induction flat with
  | @atom a =>
    intro vs hs env live aenv tenv before next gamma type bound after site result inferenceFuel
      depth ctx inv typed _ _ usesLive afterSub defaultConfig accepted
    have atomTyped : atomType tenv a = .ok type := typed
    have covered : ∀ use ∈ atomUses a, use ∈ live :=
      fun use member => usesLive use (by simpa [uses, usesArms] using member)
    obtain ⟨o, w, abs, valueAtom, heapAtom, abstractRun, paired, described, observed, valueTyped,
      _, _, _⟩ := flat_atom_values inv atomTyped covered
    obtain ⟨atomRun, checkerState⟩ := infer_atom_success defaultConfig accepted
    subst checkerState
    rw [abstractRun] at atomRun
    cases Except.ok.inj atomRun
    constructor
    · intro value vs' run
      by_cases noDepth : depth = 0
      · rw [value_atom_eval_equation vs (valueEnv env) valueAtom] at run
        simp [noDepth] at run
      · by_cases noFuel : vs.fuel = 0
        · rw [value_atom_eval_equation vs (valueEnv env) valueAtom] at run
          simp [noDepth, noFuel] at run
        · obtain ⟨valueRun, heapRun, postInvariant⟩ :=
            atom_runtime_success inv valueAtom heapAtom noDepth noFuel
          rw [valueRun] at run
          cases run
          refine ⟨w, Ownership.FlatFragment.StateFrame.heapAtomPost hs vs.kept.toList, gamma, heapRun,
            Ownership.FlatFragment.StateFrame.flatInvariant_restrict_live postInvariant afterSub,
            Nat.le_of_eq (congrArg Array.size (heapAtomPost_heap hs vs.kept.toList).symm), ?_, ?_,
            observed, ?_⟩
          · rw [heapAtomPost_heap]; exact paired
          · rw [heapAtomPost_heap]; exact described
          · rw [heapAtomPost_heap]; exact valueTyped
    · intro message failed
      exact atom_failure inv valueAtom heapAtom failed
  | @letE rhs rest v rhsFlat restFlat ihRhs ihRest =>
    intro vs hs env live aenv tenv before next gamma type bound after site result inferenceFuel
      depth ctx inv typed shadow boundKeys usesLive afterSub defaultConfig accepted
    exact let_preserved rhsFlat restFlat ihRhs ihRest inv typed shadow boundKeys usesLive afterSub
      defaultConfig accepted
  | @branch yes no c yesFlat noFlat ihYes ihNo =>
    intro vs hs env live aenv tenv before next gamma type bound after site result inferenceFuel
      depth ctx inv typed shadow boundKeys usesLive afterSub defaultConfig accepted
    exact branch_preserved yesFlat noFlat ihYes ihNo inv typed shadow boundKeys usesLive afterSub
      defaultConfig accepted
  | @literal args =>
    intro vs hs env live aenv tenv before next gamma type bound after site result inferenceFuel
      depth ctx inv typed _ _ usesLive afterSub defaultConfig accepted
    have covered : ∀ atom ∈ args, ∀ use ∈ atomUses atom, use ∈ live := by
      intro atom member use useMember
      apply usesLive use
      simp only [uses, usesArms, atomsUses, List.mem_flatMap]
      exact ⟨atom, member, useMember⟩
    obtain ⟨_, _, _, success, failure⟩ :=
      literal_preserved (depth := depth) inv typed covered defaultConfig accepted
    constructor
    · intro value vs' run
      obtain ⟨actual, hs', gamma', heapRun, postInvariant, size, paired, described, observed, valueTyped⟩ :=
        success value vs' run
      exact ⟨actual, hs', gamma', heapRun,
        Ownership.FlatFragment.StateFrame.flatInvariant_restrict_live postInvariant afterSub, size, paired,
        described, observed, valueTyped⟩
    · exact failure
  | @push receiver item =>
    intro vs hs env live aenv tenv before next gamma type bound after site result inferenceFuel
      depth ctx inv typed _ _ usesLive afterSub defaultConfig accepted
    have coveredR : ∀ use ∈ atomUses receiver, use ∈ live := by
      intro use useMember
      apply usesLive use
      simp only [uses, usesArms, atomsUses, List.mem_flatMap]
      exact ⟨receiver, by simp, useMember⟩
    have coveredI : ∀ use ∈ atomUses item, use ∈ live := by
      intro use useMember
      apply usesLive use
      simp only [uses, usesArms, atomsUses, List.mem_flatMap]
      exact ⟨item, by simp, useMember⟩
    obtain ⟨_, _, _, success, failure⟩ :=
      push_preserved (depth := depth) inv typed coveredR coveredI afterSub
        defaultConfig accepted
    exact ⟨success, failure⟩
  | @length receiver =>
    intro vs hs env live aenv tenv before next gamma type bound after site result inferenceFuel
      depth ctx inv typed _ _ usesLive afterSub defaultConfig accepted
    have covered : ∀ use ∈ atomUses receiver, use ∈ live := by
      intro use useMember
      apply usesLive use
      simp only [uses, usesArms, atomsUses, List.mem_flatMap]
      exact ⟨receiver, by simp, useMember⟩
    obtain ⟨_, _, _, success, failure⟩ :=
      length_preserved (depth := depth) inv typed covered defaultConfig accepted
    constructor
    · intro value vs' run
      obtain ⟨actual, hs', gamma', heapRun, postInvariant, size, paired, described, observed, valueTyped⟩ :=
        success value vs' run
      exact ⟨actual, hs', gamma', heapRun,
        Ownership.FlatFragment.StateFrame.flatInvariant_restrict_live postInvariant afterSub, size, paired,
        described, observed, valueTyped⟩
    · exact failure
  | @scalar op a b sop =>
    intro vs hs env live aenv tenv before next gamma type bound after site result inferenceFuel
      depth ctx inv typed _ _ usesLive afterSub defaultConfig accepted
    have coveredA : ∀ use ∈ atomUses a, use ∈ live := by
      intro use useMember
      apply usesLive use
      rw [uses_scalar sop]
      simp only [atomsUses, List.mem_flatMap]
      exact ⟨a, by simp, useMember⟩
    have coveredB : ∀ use ∈ atomUses b, use ∈ live := by
      intro use useMember
      apply usesLive use
      rw [uses_scalar sop]
      simp only [atomsUses, List.mem_flatMap]
      exact ⟨b, by simp, useMember⟩
    obtain ⟨_, _, _, success, failure⟩ :=
      Ownership.FlatFragment.Scalar.scalar_preserved (depth := depth) inv sop typed
        coveredA coveredB defaultConfig accepted
    constructor
    · intro value vs' run
      obtain ⟨actual, hs', gamma', heapRun, postInvariant, size, paired, described, observed, valueTyped⟩ :=
        success value vs' run
      exact ⟨actual, hs', gamma', heapRun,
        Ownership.FlatFragment.StateFrame.flatInvariant_restrict_live postInvariant afterSub, size, paired,
        described, observed, valueTyped⟩
    · exact failure
  | @shared value =>
    intro vs hs env live aenv tenv before next gamma type bound after site result inferenceFuel
      depth ctx inv typed _ _ usesLive afterSub defaultConfig accepted
    have covered : ∀ use ∈ atomUses value, use ∈ live := by
      intro use useMember
      apply usesLive use
      simp only [uses, usesArms, atomsUses, List.mem_flatMap]
      exact ⟨value, by simp, useMember⟩
    obtain ⟨_, _, _, success, failure⟩ :=
      shared_preserved (depth := depth) inv typed covered defaultConfig accepted
    constructor
    · intro value' vs' run
      obtain ⟨actual, hs', gamma', heapRun, postInvariant, size, paired, described, observed, valueTyped⟩ :=
        success value' vs' run
      exact ⟨actual, hs', gamma', heapRun,
        Ownership.FlatFragment.StateFrame.flatInvariant_restrict_live postInvariant afterSub, size, paired,
        described, observed, valueTyped⟩
    · exact failure

  | @record args =>
    intro vs hs env live aenv tenv before next gamma type bound after site result inferenceFuel
      depth ctx inv typed _ _ usesLive afterSub defaultConfig accepted
    have covered : ∀ atom ∈ args, ∀ use ∈ atomUses atom, use ∈ live := by
      intro atom member use useMember
      apply usesLive use
      simp only [uses, usesArms, atomsUses, List.mem_flatMap]
      exact ⟨atom, member, useMember⟩
    obtain ⟨_, _, _, success, failure⟩ :=
      Ownership.FlatFragment.Record.record_preserved (depth := depth) inv typed covered defaultConfig
        accepted
    constructor
    · intro value vs' run
      obtain ⟨actual, hs', gamma', heapRun, postInvariant, size, paired, described, observed, valueTyped⟩ :=
        success value vs' run
      exact ⟨actual, hs', gamma', heapRun,
        Ownership.FlatFragment.StateFrame.flatInvariant_restrict_live postInvariant afterSub, size, paired,
        described, observed, valueTyped⟩
    · exact failure

/-- The public trace corollary for the fragment, with the exact conclusion
of `accepted_traces_agree` and the one extra scope hypothesis. -/
theorem accepted_flat_anf_traces_agree (p : Program) (a : Accepted) (ok : check p = .ok a)
    (flat : FlatANF0 p.main) (fuel : Nat) (t : Trace)
    (run : ValueSemantics.run p fuel = .ok t) :
    ∃ t', InPlaceSemantics.run p fuel = .ok t' ∧ t.reads = t'.reads ∧
      t.externalReads = t'.externalReads ∧ t.finalValue = t'.finalValue := by
  obtain ⟨r, st', accepts, _⟩ := check_accepts_main p a ok
  obtain ⟨type, typed, shadow⟩ := check_main_type_and_shadow ok
  have inv0 := flatInvariant_initial p.declarations fuel (uses p.main) ({} : St).facts.escapes
  have preserved := flat_preserved (self := mainDecl p.main) flat { fuel } { fuel } [] (uses p.main)
    [] [] {} st' emptyNaming type [] [] [] r ({} : Config).inferenceFuel fuel
    { declarations := p.declarations, config := {} } inv0 typed shadow (by simp)
    (fun _ member => member) (by simp) rfl accepts
  unfold ValueSemantics.run at run
  cases hv : (ValueSemantics.eval fuel p.declarations none [] p.main).run { fuel } with
  | error msg => simp [hv] at run; cases run
  | ok res =>
    obtain ⟨v, vs'⟩ := res
    rw [hv] at run
    have valueRun : (ValueSemantics.eval fuel p.declarations none (valueEnv []) p.main).run { fuel } =
        .ok (v, vs') := hv
    obtain ⟨w, hs', _, hrun, inv', _, corr, _⟩ := preserved.success v vs' valueRun
    simp only [bind, Except.bind] at run
    cases hob : ValueSemantics.observable v with
    | error msg => rw [hob] at run; cases run
    | ok u =>
      rw [hob] at run
      simp only [pure, Except.pure, Except.ok.injEq] at run
      subst run
      have shallow : v.depth ≤ observationDepth := by
        unfold ValueSemantics.observable at hob
        split at hob
        · cases hob
        · omega
      refine ⟨{ reads := hs'.reads.toList, finalValue := v, externalReads := hs'.externalReads.toList },
        ?_, by simp [inv'.reads], by simp [inv'.external], rfl⟩
      unfold InPlaceSemantics.run
      simp only [heapEnv, List.map_nil] at hrun
      simp [bind, Except.bind, hrun, corr observationDepth shallow, pure, Except.pure]

/-! ## The reviewer's probe programs (PR #267)

Kernel proofs put each program in `FlatANF0`; the `#guard`s run the real
checker and both interpreters at build time. `every` uses the six forms of
PR #267, is accepted, makes one in-place write, and both runs agree.
`liveAlias` and `observed` are in the fragment and rejected (the Dead and the
Unescaped test), and their two runs differ: the corollary's `check`
hypothesis carries weight. `arith` uses the four integer primitives on
variables and literals before an in-place push; it is accepted and both runs
agree. `fieldWrite` pushes through a field path two levels down while the
record stays live at another field; it is accepted and both runs agree.
`fieldWriteLive` keeps the written field live and is rejected (the Dead
test), and its two runs differ. `branchOps` pushes onto the result of a
branch between two lists; it is accepted and both runs agree. `branchAlias`
keeps one of the two lists live after that push and is rejected (the Dead
test), and its two runs differ. -/

/-- `[5]`, an observer of it, `7`, `[7, 1]`, an in-place push onto it (its
    old binding 3 is dead and stale), a length read, and a variable result. -/
def every : Program := { main :=
  (.letE 0 (.prim (.literal .int) [.int 5])
  (.letE 1 (.prim .shared [.var 0])
  (.letE 2 (.atom (.int 7))
  (.letE 3 (.prim (.literal .int) [.var 2, .int 1])
  (.letE 4 (.prim .push [.var 3, .var 2])
  (.letE 5 (.prim .length [.var 4])
  (.atom (.var 5)))))))) }

theorem every_flat : FlatANF0 every.main :=
  .letE .literal (.letE .shared (.letE .atom (.letE .literal
    (.letE .push (.letE .length .atom)))))

/-- The push target still live afterwards: rejected by the Dead test. -/
def liveAlias : Program := { main :=
  (.letE 0 (.prim (.literal .int) [.int 1])
  (.letE 1 (.prim .push [.var 0, .int 2])
  (.letE 2 (.prim .length [.var 0])
  (.atom (.var 1))))) }

theorem liveAlias_flat : FlatANF0 liveAlias.main :=
  .letE .literal (.letE .push (.letE .length .atom))

/-- A push onto an observed array: rejected by the Unescaped test. -/
def observed : Program := { main :=
  (.letE 0 (.prim (.literal .int) [.int 1])
  (.letE 1 (.prim .shared [.var 0])
  (.letE 2 (.prim .push [.var 0, .int 2])
  (.prim .length [.var 2])))) }

theorem observed_flat : FlatANF0 observed.main :=
  .letE .literal (.letE .shared (.letE .push .length))

/-- `[2]`, its length 1, `1 + 7`, `8 - 3`, `5 == 5`, `1 < 5`, and a push of
    the last result onto the list: the four integer primitives, accepted, one
    in-place write, final value `[2, 1]`. -/
def arith : Program := { main :=
  (.letE 0 (.prim (.literal .int) [.int 2])
  (.letE 1 (.prim .length [.var 0])
  (.letE 2 (.prim .add [.var 1, .int 7])
  (.letE 3 (.prim .sub [.var 2, .int 3])
  (.letE 4 (.prim .eq [.var 3, .int 5])
  (.letE 5 (.prim .lt [.var 4, .var 3])
  (.prim .push [.var 0, .var 5]))))))) }

theorem arith_flat : FlatANF0 arith.main :=
  .letE .literal (.letE .length (.letE (.scalar .add) (.letE (.scalar .sub)
    (.letE (.scalar .eq) (.letE (.scalar .lt) .push)))))

/-- `[1]`, `[2, 3]`, the record `{xs, 7, ys}`, the length of `r.0`, `r.1`
    plus that length, `r.2` bound to a variable and a push of the sum onto it:
    field atoms and a record, accepted, one in-place write, final value
    `[2, 3, 8]`. -/
def recordOps : Program := { main :=
  (.letE 0 (.prim (.literal .int) [.int 1])
  (.letE 1 (.prim (.literal .int) [.int 2, .int 3])
  (.letE 2 (.prim .record [.var 0, .int 7, .var 1])
  (.letE 3 (.prim .length [.field (.var 2) 0])
  (.letE 4 (.prim .add [.field (.var 2) 1, .var 3])
  (.letE 5 (.atom (.field (.var 2) 2))
  (.prim .push [.var 5, .var 4]))))))) }

theorem recordOps_flat : FlatANF0 recordOps.main :=
  .letE .literal (.letE .literal (.letE .record (.letE .length
    (.letE (.scalar .add) (.letE .atom .push)))))

/-- `[1]`, `[2, 3]`, `inner = {xs, 7}`, `outer = {inner, ys}`, a push of
    `outer.0.1` onto `outer.0.0` (a write through a field, two levels down)
    and the record `{pushed, outer.1}`: accepted, one in-place write, final
    value `{[1, 7], [2, 3]}`. -/
def fieldWrite : Program := { main :=
  (.letE 0 (.prim (.literal .int) [.int 1])
  (.letE 1 (.prim (.literal .int) [.int 2, .int 3])
  (.letE 2 (.prim .record [.var 0, .int 7])
  (.letE 3 (.prim .record [.var 2, .var 1])
  (.letE 4 (.prim .push [.field (.field (.var 3) 0) 0, .field (.field (.var 3) 0) 1])
  (.prim .record [.var 4, .field (.var 3) 1])))))) }

theorem fieldWrite_flat : FlatANF0 fieldWrite.main :=
  .letE .literal (.letE .literal (.letE .record (.letE .record (.letE .push .record))))

/-- The same write with the written field's record live afterwards: rejected
    by the Dead test, and the two runs differ. -/
def fieldWriteLive : Program := { main :=
  (.letE 0 (.prim (.literal .int) [.int 1])
  (.letE 1 (.prim (.literal .int) [.int 2, .int 3])
  (.letE 2 (.prim .record [.var 0, .int 7])
  (.letE 3 (.prim .record [.var 2, .var 1])
  (.letE 4 (.prim .push [.field (.field (.var 3) 0) 0, .field (.field (.var 3) 0) 1])
  (.prim .record [.var 4, .field (.var 3) 0])))))) }

theorem fieldWriteLive_flat : FlatANF0 fieldWriteLive.main :=
  .letE .literal (.letE .literal (.letE .record (.letE .record (.letE .push .record))))

/-- `[1]`, `[2]`, the length of the first, a branch on it between the two
    lists (the length is 1, so the second), and a push onto the branch's
    result: accepted, one in-place write, final value `[2, 9]`. The checker's
    result of the branch names both lists; the demand of the push covers
    both. -/
def branchOps : Program := { main :=
  (.letE 0 (.prim (.literal .int) [.int 1])
  (.letE 1 (.prim (.literal .int) [.int 2])
  (.letE 2 (.prim .length [.var 0])
  (.letE 3 (.branch (.var 2) (.atom (.var 0)) (.atom (.var 1)))
  (.prim .push [.var 3, .int 9]))))) }

theorem branchOps_flat : FlatANF0 branchOps.main :=
  .letE .literal (.letE .literal (.letE .length (.letE (.branch .atom .atom) .push)))

/-- The same push with the second list still live afterwards: rejected by
    the Dead test, because the branch's result names both lists; the two
    runs differ. -/
def branchAlias : Program := { main :=
  (.letE 0 (.prim (.literal .int) [.int 1])
  (.letE 1 (.prim (.literal .int) [.int 2])
  (.letE 2 (.prim .length [.var 0])
  (.letE 3 (.branch (.var 2) (.atom (.var 0)) (.atom (.var 1)))
  (.letE 4 (.prim .push [.var 3, .int 9])
  (.prim .length [.var 1])))))) }

theorem branchAlias_flat : FlatANF0 branchAlias.main :=
  .letE .literal (.letE .literal (.letE .length (.letE (.branch .atom .atom)
    (.letE .push .length))))

set_option maxRecDepth 100000

#guard (check every).isOk
#guard match ValueSemantics.run every 100, InPlaceSemantics.run every 100 with
  | .ok t, .ok t' => t.reads == t'.reads && t.externalReads == t'.externalReads &&
      t.finalValue == t'.finalValue && t.finalValue == .int 3 && t.reads == [.int 3] &&
      t.externalReads.length == 12
  | _, _ => false
#guard InPlaceSemantics.writeCount every 100 == 1
#guard match check liveAlias with
  | .error message => message == "Dead: an old holder is live after the demand"
  | .ok _ => false
#guard match ValueSemantics.run liveAlias 100, InPlaceSemantics.run liveAlias 100 with
  | .ok t, .ok t' => t.reads == [.int 1] && t'.reads == [.int 2] && t.finalValue == t'.finalValue
  | _, _ => false
#guard match check observed with
  | .error message => message == "Unescaped: program-lifetime holder"
  | .ok _ => false
#guard match ValueSemantics.run observed 100, InPlaceSemantics.run observed 100 with
  | .ok t, .ok t' => t.reads == t'.reads && t.finalValue == t'.finalValue &&
      t.externalReads != t'.externalReads
  | _, _ => false
#guard (check arith).isOk
#guard match ValueSemantics.run arith 100, InPlaceSemantics.run arith 100 with
  | .ok t, .ok t' => t.reads == t'.reads && t.externalReads == t'.externalReads &&
      t.finalValue == t'.finalValue && t.finalValue == .list [.int 2, .int 1] &&
      t.reads == [.int 1] && t.externalReads.isEmpty
  | _, _ => false
#guard InPlaceSemantics.writeCount arith 100 == 1
#guard (check recordOps).isOk
#guard match ValueSemantics.run recordOps 100, InPlaceSemantics.run recordOps 100 with
  | .ok t, .ok t' => t.reads == t'.reads && t.externalReads == t'.externalReads &&
      t.finalValue == t'.finalValue && t.finalValue == .list [.int 2, .int 3, .int 8] &&
      t.reads == [.int 1] && t.externalReads.isEmpty
  | _, _ => false
#guard InPlaceSemantics.writeCount recordOps 100 == 1
#guard (check fieldWrite).isOk
#guard match ValueSemantics.run fieldWrite 100, InPlaceSemantics.run fieldWrite 100 with
  | .ok t, .ok t' => t.reads == t'.reads && t.externalReads == t'.externalReads &&
      t.finalValue == t'.finalValue &&
      t.finalValue == .record [.list [.int 1, .int 7], .list [.int 2, .int 3]] &&
      t.reads.isEmpty && t.externalReads.isEmpty
  | _, _ => false
#guard InPlaceSemantics.writeCount fieldWrite 100 == 1
#guard (check branchOps).isOk
#guard match ValueSemantics.run branchOps 100, InPlaceSemantics.run branchOps 100 with
  | .ok t, .ok t' => t.reads == t'.reads && t.externalReads == t'.externalReads &&
      t.finalValue == t'.finalValue && t.finalValue == .list [.int 2, .int 9] &&
      t.reads == [.int 1] && t.externalReads.isEmpty
  | _, _ => false
#guard InPlaceSemantics.writeCount branchOps 100 == 1
#guard match check branchAlias with
  | .error message => message == "Dead: an old holder is live after the demand"
  | .ok _ => false
#guard match ValueSemantics.run branchAlias 100, InPlaceSemantics.run branchAlias 100 with
  | .ok t, .ok t' => t.reads == [.int 1, .int 1] && t'.reads == [.int 1, .int 2] &&
      t.finalValue == .int 1 && t'.finalValue == .int 2
  | _, _ => false
#guard match check fieldWriteLive with
  | .error message => message == "Dead: an old holder is live after the demand"
  | .ok _ => false
#guard match ValueSemantics.run fieldWriteLive 100, InPlaceSemantics.run fieldWriteLive 100 with
  | .ok t, .ok t' =>
      t.finalValue == .record [.list [.int 1, .int 7], .record [.list [.int 1], .int 7]] &&
      t'.finalValue == .record [.list [.int 1, .int 7], .record [.list [.int 1, .int 7], .int 7]]
  | _, _ => false

end Ownership.FlatFragment.Preservation
