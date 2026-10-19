import Ownership.FlatFragment.Let

/-! The first flat fragment: the branch evaluation equations and the branch case. -/

/-! branch composition under the generic flat relation.
A branch reads an integer condition and runs one of its two arms. The checker
infers both arms from the same facts and joins their results and escapes. The
taken arm's induction hypothesis carries the runtime step; the other arm's
static facts give the join its shape. No final interpreter agreement or
separate permission predicate is assumed.
-/

namespace Ownership.FlatFragment.Branch

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.StateFrame
open Ownership.FlatFragment.Observe Ownership.FlatFragment.Runtime Ownership.FlatFragment.HeapPreservation Ownership.FlatFragment.Description
open Ownership.FlatFragment.Atoms Ownership.FlatFragment.AtomInteger Ownership.FlatFragment.CheckerExtraction Ownership.FlatFragment.InferBranch
open Ownership.FlatFragment.Literal Ownership.FlatFragment.Length Ownership.FlatFragment.LiveSets Ownership.FlatFragment.Liveness Ownership.FlatFragment.Scope
open Ownership.FlatFragment.HeapFrame Ownership.FlatFragment.Support Ownership.FlatFragment.NamingFacts Ownership.FlatFragment.VariableFacts
open Ownership.FlatFragment.Static Ownership.FlatFragment.Fields Ownership.FlatFragment.Shared Ownership.FlatFragment.Let

local instance stepReflBEq : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance stepLawfulBEq : LawfulBEq Step := LawfulBEq.mk (by deriving_LawfulEq_tactic)
local instance originReflBEq : ReflBEq Origin := ⟨by deriving_ReflEq_tactic⟩
local instance originLawfulBEq : LawfulBEq Origin := LawfulBEq.mk (by deriving_LawfulEq_tactic)

/-! ### The evaluation equations -/

theorem value_branch_eval_equation {depth : Nat} {declarations : List Decl} {c : Atom} {yes no : Expr} {n : Int}
    (state : ValueSemantics.State) (runtimeEnv : Env Observation)
    (atomRun : ValueSemantics.atom runtimeEnv c = .ok (.int n)) :
    (ValueSemantics.eval depth declarations none runtimeEnv (.branch c yes no)).run state =
      (if depth = 0 then .error "value execution exhausted depth"
      else if state.fuel = 0 then .error "value execution exhausted fuel"
      else do
        let (y, s2) ← (ValueSemantics.eval (depth - 1) declarations none runtimeEnv
          (if n == 0 then yes else no)).run (valueTicked state)
        let (_, s3) ← ValueSemantics.observeKept.run s2
        pure (y, s3)) := by
  by_cases noDepth : depth = 0
  · simp [ValueSemantics.eval, noDepth, StateT.run, StateT.bind, StateT.lift, throw, throwThe, MonadExceptOf.throw, Except.map] <;> rfl
  · by_cases noFuel : state.fuel = 0
    · rw [ValueSemantics.eval]
      simp [ValueSemantics.tick, atomRun, noDepth, noFuel, StateT.run, StateT.bind, StateT.get, StateT.set,
        StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
    · rw [ValueSemantics.eval]
      simp [ValueSemantics.tick, atomRun, noDepth, noFuel, valueTicked, StateT.run, StateT.bind, StateT.get, StateT.set,
        StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]

theorem heap_branch_eval_equation {depth : Nat} {declarations : List Decl} {c : Atom} {yes no : Expr} {n : Int}
    (state : InPlaceSemantics.State) (runtimeEnv : Env Value)
    (atomRun : InPlaceSemantics.atom runtimeEnv c = .ok (.int n)) :
    (InPlaceSemantics.eval depth declarations none runtimeEnv (.branch c yes no)).run state =
      (if depth = 0 then .error "in-place execution exhausted depth"
      else if state.fuel = 0 then .error "in-place execution exhausted fuel"
      else do
        let (y, s2) ← (InPlaceSemantics.eval (depth - 1) declarations none runtimeEnv
          (if n == 0 then yes else no)).run (heapTicked state)
        let (_, s3) ← InPlaceSemantics.observeKept.run s2
        pure (y, s3)) := by
  by_cases noDepth : depth = 0
  · simp [InPlaceSemantics.eval, noDepth, StateT.run, StateT.bind, StateT.lift, throw, throwThe, MonadExceptOf.throw, Except.map] <;> rfl
  · by_cases noFuel : state.fuel = 0
    · rw [InPlaceSemantics.eval]
      simp [InPlaceSemantics.tick, atomRun, noDepth, noFuel, StateT.run, StateT.bind, StateT.get, StateT.set,
        StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
    · rw [InPlaceSemantics.eval]
      simp [InPlaceSemantics.tick, atomRun, noDepth, noFuel, heapTicked, StateT.run, StateT.bind, StateT.get, StateT.set,
        StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]

/-! ### The branch expression case -/

/-- The taken arm carries the branch: both runtimes tick, run the arm at the
smaller depth, and observe; the checker's result is the join of both arms'
results and its escapes the union of both arms' escapes. -/
theorem branch_arm_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {escapes escapes' : List Origin} {depth : Nat} {after : Live} {c : Atom} {yes no arm : Expr} {n : Int} {armEscapes : List Origin} {armResult other result : Abstract} {type : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueCond : ValueSemantics.atom (valueEnv env) c = .ok (.int n))
    (heapCond : InPlaceSemantics.atom (heapEnv env) c = .ok (.int n))
    (taken : (if n == 0 then yes else no) = arm)
    (armPreserved : Preserved declarations (depth - 1) env (valueTicked vs) (heapTicked hs) arm after
      aenv tenv armEscapes armResult type)
    (more : ∀ origin, Escaped armEscapes origin → Escaped escapes' origin)
    (flatType : FlatType type) (shapeArm : FlatAbstract type armResult)
    (shapeOther : FlatAbstract type other)
    (joined : result = armResult.join other ∨ result = other.join armResult) :
    Preserved declarations depth env vs hs (.branch c yes no) after aenv tenv escapes' result type := by
  have heapFuelEq : hs.fuel = vs.fuel := inv.fuel.symm
  constructor
  · intro value vs' run
    rw [value_branch_eval_equation vs (valueEnv env) valueCond, taken] at run
    by_cases noDepth : depth = 0
    · rw [if_pos noDepth] at run; cases run
    · by_cases noFuel : vs.fuel = 0
      · rw [if_neg noDepth, if_pos noFuel] at run; cases run
      · have heapFuel : hs.fuel ≠ 0 := by rw [heapFuelEq]; exact noFuel
        rw [if_neg noDepth, if_neg noFuel] at run
        obtain ⟨p2, armValueRun, run⟩ := except_bind_success run
        rcases p2 with ⟨y, s2⟩
        obtain ⟨actual, hs2, gamma2, armHeapRun, inv2, size2, paired2, described2, observed2, typed2⟩ :=
          armPreserved.success y s2 armValueRun
        try dsimp only at run
        obtain ⟨p3, observeRun, run⟩ := except_bind_success run
        rcases p3 with ⟨u, s3⟩
        try dsimp only at run
        have final : (y, s3) = (value, vs') := Except.ok.inj run
        obtain ⟨footprint2, represented2⟩ := inv2.observers
        have valueObserveRun := value_observeKept_run s2 represented2
        rw [valueObserveRun] at observeRun
        have observeEq : ((), valueObserved s2) = (u, s3) := Except.ok.inj observeRun
        have heapObserveRun := heap_observeKept_run hs2 represented2
        have inv3 := flatInvariant_more_escapes (observed_invariant inv2) more
        have s3Eq : s3 = vs' := congrArg Prod.snd final
        have observed3 : valueObserved s2 = s3 := congrArg Prod.snd observeEq
        have vsEq : vs' = valueObserved s2 := s3Eq.symm.trans observed3.symm
        have valueEq : value = y := (congrArg Prod.fst final).symm
        subst vsEq
        subst valueEq
        have allocated := allocated_of_typed flatType typed2
        have describedJoin : Describes gamma2 hs2.heap result actual := by
          rcases joined with rfl | rfl
          · exact describes_join allocated inv2.heapInts shapeArm shapeOther (Or.inl described2)
          · exact describes_join allocated inv2.heapInts shapeOther shapeArm (Or.inr described2)
        refine ⟨actual, heapObserved hs2 s2.kept.toList, gamma2, ?_, inv3, ?_, ?_, ?_, observed2, ?_⟩
        · rw [heap_branch_eval_equation hs (heapEnv env) heapCond, taken]
          rw [if_neg noDepth, if_neg heapFuel]
          simp [armHeapRun, heapObserveRun, Except.bind, Except.pure, bind, pure]
        · rw [heapObserved_heap]; exact size2
        · rw [heapObserved_heap]; exact paired2
        · rw [heapObserved_heap]; exact describedJoin
        · rw [heapObserved_heap]; exact typed2
  · intro message run
    rw [value_branch_eval_equation vs (valueEnv env) valueCond, taken] at run
    by_cases noDepth : depth = 0
    · exact ⟨"in-place execution exhausted depth", by
        rw [heap_branch_eval_equation hs (heapEnv env) heapCond, taken, if_pos noDepth]⟩
    · by_cases noFuel : vs.fuel = 0
      · have heapFuel : hs.fuel = 0 := by rw [heapFuelEq]; exact noFuel
        exact ⟨"in-place execution exhausted fuel", by
          rw [heap_branch_eval_equation hs (heapEnv env) heapCond, taken, if_neg noDepth, if_pos heapFuel]⟩
      · have heapFuel : hs.fuel ≠ 0 := by rw [heapFuelEq]; exact noFuel
        rw [if_neg noDepth, if_neg noFuel] at run
        cases armValue : (ValueSemantics.eval (depth - 1) declarations none (valueEnv env) arm).run
            (valueTicked vs) with
        | error m1 =>
          obtain ⟨m1', armHeapError⟩ := armPreserved.failure m1 armValue
          exact ⟨m1', by
            rw [heap_branch_eval_equation hs (heapEnv env) heapCond, taken, if_neg noDepth, if_neg heapFuel]
            simp [armHeapError, Except.bind, bind]⟩
        | ok p2 =>
          rcases p2 with ⟨y, s2⟩
          obtain ⟨actual, hs2, gamma2, _, inv2, _⟩ := armPreserved.success y s2 armValue
          obtain ⟨footprint2, represented2⟩ := inv2.observers
          have valueObserveRun := value_observeKept_run s2 represented2
          rw [armValue] at run
          simp only [bind, Except.bind] at run
          rw [valueObserveRun] at run
          simp [pure, Except.pure] at run

theorem branch_preserved {declarations : List Decl} {c : Atom} {yes no : Expr}
    {self : Decl} {ctx : Context} {inferenceFuel : Nat} {after : Live} {site : List Nat}
    {before next : St} {result : Abstract} {type : Ty} {bound : List Var}
    (flatYes : FlatANF0 yes) (flatNo : FlatANF0 no)
    (ihYes : ∀ (vs : ValueSemantics.State) (hs : State) (env : List (Var × Observation × Value))
      (live : Live) (aenv : Env Abstract) (tenv : Env Ty) (before next : St) (gamma : Naming)
      (type : Ty) (bound : List Var) (after : Live) (site : List Nat) (result : Abstract)
      (inferenceFuel depth : Nat) (ctx : Context),
      FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma →
      exprType declarations self tenv yes = .ok type → shadowFree bound yes = .ok () →
      (∀ x ∈ env.map Prod.fst, x ∈ bound) → (∀ use ∈ uses yes, use ∈ live) →
      (∀ use ∈ after, use ∈ live) → ctx.config = {} →
      (inferExpr inferenceFuel ctx aenv yes after site).run before = .ok (result, next) →
      Preserved declarations depth env vs hs yes after aenv tenv next.facts.escapes result type)
    (ihNo : ∀ (vs : ValueSemantics.State) (hs : State) (env : List (Var × Observation × Value))
      (live : Live) (aenv : Env Abstract) (tenv : Env Ty) (before next : St) (gamma : Naming)
      (type : Ty) (bound : List Var) (after : Live) (site : List Nat) (result : Abstract)
      (inferenceFuel depth : Nat) (ctx : Context),
      FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma →
      exprType declarations self tenv no = .ok type → shadowFree bound no = .ok () →
      (∀ x ∈ env.map Prod.fst, x ∈ bound) → (∀ use ∈ uses no, use ∈ live) →
      (∀ use ∈ after, use ∈ live) → ctx.config = {} →
      (inferExpr inferenceFuel ctx aenv no after site).run before = .ok (result, next) →
      Preserved declarations depth env vs hs no after aenv tenv next.facts.escapes result type)
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.branch c yes no) = .ok type)
    (shadow : shadowFree bound (.branch c yes no) = .ok ())
    (boundKeys : ∀ x ∈ env.map Prod.fst, x ∈ bound)
    (usesLive : ∀ use ∈ uses (.branch c yes no), use ∈ live)
    (afterSub : ∀ use ∈ after, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.branch c yes no) after site).run before =
      .ok (result, next)) :
    Preserved declarations depth env vs hs (.branch c yes no) after aenv tenv next.facts.escapes
      result type := by
  obtain ⟨condTyped, yesTyped, b', noTyped', equalTypes⟩ := exprType_branch_success typed
  obtain ⟨yesShadow, noShadow⟩ := shadowFree_branch_success shadow
  rw [uses_branch] at usesLive
  have covered : ∀ use ∈ atomUses c, use ∈ live :=
    fun use member => usesLive use (union_left _ _ use member)
  have yesUsesLive : ∀ use ∈ uses yes, use ∈ live :=
    fun use member => usesLive use (union_right _ _ use (union_left _ _ use member))
  have noUsesLive : ∀ use ∈ uses no, use ∈ live :=
    fun use member => usesLive use (union_right _ _ use (union_right _ _ use member))
  obtain ⟨n, valueCond, heapCond, _⟩ := flat_atom_integer inv condTyped covered
  obtain ⟨childFuel, a, middle, b, last, _, _, _, yesRun, noRun, resultEq, nextEq⟩ :=
    infer_branch_success defaultConfig accepted
  have static := FlatStatic.of_invariant inv
  have aenvBound : ∀ x ∈ aenv.map Prod.fst, x ∈ bound := by
    rw [← inv.abstractKeys]; exact boundKeys
  obtain ⟨flatType, yesShape, _⟩ :=
    flat_static (self := self) flatYes aenv tenv before middle type bound after (site ++ [0]) a
      childFuel _ static yesTyped yesShadow aenvBound (by exact defaultConfig) yesRun
  have sameType : type = b' := ty_equal_flat flatType equalTypes
  subst sameType
  obtain ⟨_, noShape, _⟩ :=
    flat_static (self := self) flatNo aenv tenv {middle with facts := before.facts} last type bound
      after (site ++ [1]) b childFuel _ static noTyped' noShadow aenvBound (by exact defaultConfig) noRun
  have escapesEq : next.facts.escapes = union middle.facts.escapes last.facts.escapes := by
    rw [nextEq]; rfl
  have yesPreserved := ihYes (valueTicked vs) (heapTicked hs) env live aenv tenv before middle gamma
    type bound after (site ++ [0]) a childFuel (depth - 1) _ (ticked_invariant inv) yesTyped yesShadow
    boundKeys yesUsesLive afterSub (by exact defaultConfig) yesRun
  have noPreserved := ihNo (valueTicked vs) (heapTicked hs) env live aenv tenv
    {middle with facts := before.facts} last gamma type bound after (site ++ [1]) b childFuel
    (depth - 1) _ (ticked_invariant inv) noTyped' noShadow boundKeys noUsesLive afterSub
    (by exact defaultConfig) noRun
  by_cases zero : (n == 0) = true
  · refine branch_arm_preserved inv valueCond heapCond (arm := yes) (by simp [zero]) yesPreserved
      ?_ flatType yesShape noShape (Or.inl resultEq)
    intro origin escaped
    rw [escapesEq]
    exact escaped_mono _ escaped
  · refine branch_arm_preserved inv valueCond heapCond (arm := no) (by simp [zero]) noPreserved
      ?_ flatType noShape yesShape (Or.inr resultEq)
    intro origin escaped
    rw [escapesEq]
    exact escaped_subset (fun x member => mem_union _ _ x (Or.inr member)) escaped

end Ownership.FlatFragment.Branch
