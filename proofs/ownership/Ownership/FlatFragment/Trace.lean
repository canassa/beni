import Ownership.FlatFragment.Let

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

theorem heapAtomPost_heap (hs : State) (observations : List Observation) :
    (Ownership.FlatFragment.StateFrame.heapAtomPost hs observations).heap = hs.heap := by
  unfold Ownership.FlatFragment.StateFrame.heapAtomPost Ownership.FlatFragment.Observe.heapObserved Ownership.FlatFragment.StateFrame.heapTicked
  split <;> rfl

theorem atomHeapPost_heap (hs : State) (observations : List Observation) :
    (Ownership.FlatFragment.AtomPreservation.heapAtomPost hs observations).heap = hs.heap := by
  unfold Ownership.FlatFragment.AtomPreservation.heapAtomPost Ownership.FlatFragment.Observe.heapObserved
    Ownership.FlatFragment.AtomPreservation.heapTicked
  split <;> rfl

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
  | @atom a atomFlat =>
    intro vs hs env live aenv tenv before next gamma type bound after site result inferenceFuel
      depth ctx inv typed _ _ usesLive afterSub defaultConfig accepted
    cases atomFlat with
    | int integer =>
      have atomTyped : atomType tenv (.int integer) = .ok type := typed
      change Except.ok Ty.int = Except.ok type at atomTyped
      cases Except.ok.inj atomTyped
      obtain ⟨scalar, checkerState⟩ := infer_integer_success defaultConfig accepted
      subst scalar
      subst checkerState
      constructor
      · intro value vs' run
        by_cases noDepth : depth = 0
        · rw [value_integer_eval_equation] at run
          simp [noDepth] at run
        · by_cases noFuel : vs.fuel = 0
          · rw [value_integer_eval_equation] at run
            simp [noDepth, noFuel] at run
          · obtain ⟨valueRun, heapRun, postInvariant⟩ :=
              integer_atom_runtime_success (integer := integer) inv noDepth noFuel
            rw [valueRun] at run
            cases run
            refine ⟨.int integer, Ownership.FlatFragment.AtomPreservation.heapAtomPost hs vs.kept.toList, gamma,
              heapRun, Ownership.FlatFragment.StateFrame.flatInvariant_restrict_live postInvariant afterSub,
              Nat.le_of_eq (congrArg Array.size (atomHeapPost_heap hs vs.kept.toList).symm),
              integer_corresponds integer,
              integer_described integer,
              by simp [obsTyped], ⟨1, .int integer, [], .int, by simp [obsTyped]⟩⟩
      · intro message failed
        exact integer_atom_failure inv failed
    | var key =>
      have atomTyped : atomType tenv (.var key) = .ok type := typed
      have typeRun : lookup tenv key = .ok type := by simpa only [atomType] using atomTyped
      have declared := lookup_option_of_success typeRun
      obtain ⟨abstractBinding, checkerState⟩ := infer_variable_lookup defaultConfig accepted
      subst checkerState
      obtain ⟨observation, actual, binding⟩ := runtime_binding_of_abstract inv abstractBinding
      have use : (key, []) ∈ live := usesLive (key, []) (by simp [uses, usesArms, atomUses])
      obtain ⟨_, _, ty', declared', _, _, observed, valueTyped⟩ :=
        live_variable_result inv use binding abstractBinding
      have sameType : ty' = type := Option.some.inj (declared'.symm.trans declared)
      subst sameType
      constructor
      · intro value vs' run
        by_cases noDepth : depth = 0
        · rw [value_atom_eval_equation vs (valueEnv env) (variable_atoms_run binding).1] at run
          simp [noDepth] at run
        · by_cases noFuel : vs.fuel = 0
          · rw [value_atom_eval_equation vs (valueEnv env) (variable_atoms_run binding).1] at run
            simp [noDepth, noFuel] at run
          · obtain ⟨valueRun, heapRun, postInvariant⟩ :=
              variable_runtime_success inv binding noDepth noFuel
            rw [valueRun] at run
            cases run
            have correct := variable_post_correspondence inv use binding abstractBinding
            refine ⟨actual, Ownership.FlatFragment.StateFrame.heapAtomPost hs vs.kept.toList, gamma, heapRun,
              Ownership.FlatFragment.StateFrame.flatInvariant_restrict_live postInvariant afterSub,
              Nat.le_of_eq (congrArg Array.size (heapAtomPost_heap hs vs.kept.toList).symm), correct.1,
              correct.2, observed, ?_⟩
            rw [heapAtomPost_heap]
            exact valueTyped
      · intro message failed
        exact variable_atom_failure inv binding failed
  | @letE rhs rest v rhsFlat restFlat ihRhs ihRest =>
    intro vs hs env live aenv tenv before next gamma type bound after site result inferenceFuel
      depth ctx inv typed shadow boundKeys usesLive afterSub defaultConfig accepted
    exact let_preserved rhsFlat restFlat ihRhs ihRest inv typed shadow boundKeys usesLive afterSub
      defaultConfig accepted
  | @literal args atomsFlat =>
    intro vs hs env live aenv tenv before next gamma type bound after site result inferenceFuel
      depth ctx inv typed _ _ usesLive afterSub defaultConfig accepted
    have covered : ∀ atom ∈ args, ∀ use ∈ atomUses atom, use ∈ live := by
      intro atom member use useMember
      apply usesLive use
      simp only [uses, usesArms, atomsUses, List.mem_flatMap]
      exact ⟨atom, member, useMember⟩
    obtain ⟨_, _, _, success, failure⟩ :=
      literal_preserved (depth := depth) inv atomsFlat typed covered defaultConfig accepted
    constructor
    · intro value vs' run
      obtain ⟨actual, hs', gamma', heapRun, postInvariant, size, paired, described, observed, valueTyped⟩ :=
        success value vs' run
      exact ⟨actual, hs', gamma', heapRun,
        Ownership.FlatFragment.StateFrame.flatInvariant_restrict_live postInvariant afterSub, size, paired,
        described, observed, valueTyped⟩
    · exact failure
  | @push receiver item receiverFlat itemFlat =>
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
      push_preserved (depth := depth) inv receiverFlat itemFlat typed coveredR coveredI afterSub
        defaultConfig accepted
    exact ⟨success, failure⟩
  | @length receiver receiverFlat =>
    intro vs hs env live aenv tenv before next gamma type bound after site result inferenceFuel
      depth ctx inv typed _ _ usesLive afterSub defaultConfig accepted
    have covered : ∀ use ∈ atomUses receiver, use ∈ live := by
      intro use useMember
      apply usesLive use
      simp only [uses, usesArms, atomsUses, List.mem_flatMap]
      exact ⟨receiver, by simp, useMember⟩
    obtain ⟨_, _, _, success, failure⟩ :=
      length_preserved (depth := depth) inv receiverFlat typed covered defaultConfig accepted
    constructor
    · intro value vs' run
      obtain ⟨actual, hs', gamma', heapRun, postInvariant, size, paired, described, observed, valueTyped⟩ :=
        success value vs' run
      exact ⟨actual, hs', gamma', heapRun,
        Ownership.FlatFragment.StateFrame.flatInvariant_restrict_live postInvariant afterSub, size, paired,
        described, observed, valueTyped⟩
    · exact failure
  | @scalar op a b sop aFlat bFlat =>
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
      Ownership.FlatFragment.Scalar.scalar_preserved (depth := depth) inv sop aFlat bFlat typed
        coveredA coveredB defaultConfig accepted
    constructor
    · intro value vs' run
      obtain ⟨actual, hs', gamma', heapRun, postInvariant, size, paired, described, observed, valueTyped⟩ :=
        success value vs' run
      exact ⟨actual, hs', gamma', heapRun,
        Ownership.FlatFragment.StateFrame.flatInvariant_restrict_live postInvariant afterSub, size, paired,
        described, observed, valueTyped⟩
    · exact failure
  | @shared value valueFlat =>
    intro vs hs env live aenv tenv before next gamma type bound after site result inferenceFuel
      depth ctx inv typed _ _ usesLive afterSub defaultConfig accepted
    have covered : ∀ use ∈ atomUses value, use ∈ live := by
      intro use useMember
      apply usesLive use
      simp only [uses, usesArms, atomsUses, List.mem_flatMap]
      exact ⟨value, by simp, useMember⟩
    obtain ⟨_, _, _, success, failure⟩ :=
      shared_preserved (depth := depth) inv valueFlat typed covered defaultConfig accepted
    constructor
    · intro value' vs' run
      obtain ⟨actual, hs', gamma', heapRun, postInvariant, size, paired, described, observed, valueTyped⟩ :=
        success value' vs' run
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
agree. -/

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

theorem every_flat : FlatANF0 every.main := by
  refine .letE (.literal ?_) (.letE (.shared (.var 0)) (.letE (.atom (.int 7))
    (.letE (.literal ?_) (.letE (.push (.var 3) (.var 2)) (.letE (.length (.var 4)) (.atom (.var 5)))))))
  · intro a member; simp at member; subst member; exact .int 5
  · intro a member; simp at member
    rcases member with rfl | rfl
    · exact .var 2
    · exact .int 1

/-- The push target still live afterwards: rejected by the Dead test. -/
def liveAlias : Program := { main :=
  (.letE 0 (.prim (.literal .int) [.int 1])
  (.letE 1 (.prim .push [.var 0, .int 2])
  (.letE 2 (.prim .length [.var 0])
  (.atom (.var 1))))) }

theorem liveAlias_flat : FlatANF0 liveAlias.main :=
  .letE (.literal (by intro a member; simp at member; subst member; exact .int 1))
    (.letE (.push (.var 0) (.int 2)) (.letE (.length (.var 0)) (.atom (.var 1))))

/-- A push onto an observed array: rejected by the Unescaped test. -/
def observed : Program := { main :=
  (.letE 0 (.prim (.literal .int) [.int 1])
  (.letE 1 (.prim .shared [.var 0])
  (.letE 2 (.prim .push [.var 0, .int 2])
  (.prim .length [.var 2])))) }

theorem observed_flat : FlatANF0 observed.main :=
  .letE (.literal (by intro a member; simp at member; subst member; exact .int 1))
    (.letE (.shared (.var 0)) (.letE (.push (.var 0) (.int 2)) (.length (.var 2))))

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
  .letE (.literal (by intro a member; simp at member; subst member; exact .int 2))
    (.letE (.length (.var 0)) (.letE (.scalar .add (.var 1) (.int 7))
      (.letE (.scalar .sub (.var 2) (.int 3)) (.letE (.scalar .eq (.var 3) (.int 5))
        (.letE (.scalar .lt (.var 4) (.var 3)) (.push (.var 0) (.var 5)))))))

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

end Ownership.FlatFragment.Preservation
