import Ownership.FlatFragment.Branch

/-! The first flat fragment: the result-case evaluation equations and the result-case case. -/

/-! result-case composition under the generic flat relation.
A result case reads a result and binds its live payload in one of two arms.
Both runtimes take the arm of the runtime tag; the checker infers an arm
when its abstract slot is not bottom, from the incoming facts, and joins the
arms' results and escapes. The result tags of the relation say that the arm
the runtime takes is one the checker inferred. The taken arm's induction
hypothesis carries the runtime step under the extended environment; the
other arm's static facts, or bottom, give the join its shape. -/

namespace Ownership.FlatFragment.ResultCase

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.StateFrame
open Ownership.FlatFragment.Observe Ownership.FlatFragment.Runtime Ownership.FlatFragment.HeapPreservation Ownership.FlatFragment.Description
open Ownership.FlatFragment.Atoms Ownership.FlatFragment.AtomInteger Ownership.FlatFragment.CheckerExtraction Ownership.FlatFragment.InferResultCase
open Ownership.FlatFragment.Literal Ownership.FlatFragment.Length Ownership.FlatFragment.LiveSets Ownership.FlatFragment.Liveness Ownership.FlatFragment.Scope
open Ownership.FlatFragment.HeapFrame Ownership.FlatFragment.Support Ownership.FlatFragment.NamingFacts Ownership.FlatFragment.VariableFacts
open Ownership.FlatFragment.Static Ownership.FlatFragment.Fields Ownership.FlatFragment.Shared Ownership.FlatFragment.Let

local instance stepReflBEq : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance stepLawfulBEq : LawfulBEq Step := LawfulBEq.mk (by deriving_LawfulEq_tactic)
local instance originReflBEq : ReflBEq Origin := ⟨by deriving_ReflEq_tactic⟩
local instance originLawfulBEq : LawfulBEq Origin := LawfulBEq.mk (by deriving_LawfulEq_tactic)

/-! ### The evaluation equations -/

theorem value_resultCase_eval_equation {depth : Nat} {declarations : List Decl} {input : Atom} {err ok : Var} {onError onSuccess : Expr} {n : Int} {e a : Observation}
    (state : ValueSemantics.State) (runtimeEnv : Env Observation)
    (atomRun : ValueSemantics.atom runtimeEnv input = .ok (.record [.int n, e, a])) :
    (ValueSemantics.eval depth declarations none runtimeEnv (.resultCase input err ok onError onSuccess)).run state =
      (if depth = 0 then .error "value execution exhausted depth"
      else if state.fuel = 0 then .error "value execution exhausted fuel"
      else do
        let (y, s2) ← (if n == 0 then
            ValueSemantics.eval (depth - 1) declarations none ((err, e) :: runtimeEnv) onError
          else ValueSemantics.eval (depth - 1) declarations none ((ok, a) :: runtimeEnv) onSuccess).run
            (valueTicked state)
        let (_, s3) ← ValueSemantics.observeKept.run s2
        pure (y, s3)) := by
  by_cases noDepth : depth = 0
  · simp [ValueSemantics.eval, noDepth, StateT.run, StateT.bind, StateT.lift, throw, throwThe, MonadExceptOf.throw, Except.map] <;> rfl
  · by_cases noFuel : state.fuel = 0
    · rw [ValueSemantics.eval]
      simp [ValueSemantics.tick, atomRun, noDepth, noFuel, StateT.run, StateT.bind, StateT.get, StateT.set,
        StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
    · rw [ValueSemantics.eval]
      by_cases zero : n = 0
      · simp [ValueSemantics.tick, atomRun, noDepth, noFuel, zero, valueTicked, StateT.run, StateT.bind, StateT.get, StateT.set,
          StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
      · simp [ValueSemantics.tick, atomRun, noDepth, noFuel, zero, valueTicked, StateT.run, StateT.bind, StateT.get, StateT.set,
          StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]

theorem heap_resultCase_eval_equation {depth : Nat} {declarations : List Decl} {input : Atom} {err ok : Var} {onError onSuccess : Expr} {n : Int} {e a : Value}
    (state : InPlaceSemantics.State) (runtimeEnv : Env Value)
    (atomRun : InPlaceSemantics.atom runtimeEnv input = .ok (.record [.int n, e, a])) :
    (InPlaceSemantics.eval depth declarations none runtimeEnv (.resultCase input err ok onError onSuccess)).run state =
      (if depth = 0 then .error "in-place execution exhausted depth"
      else if state.fuel = 0 then .error "in-place execution exhausted fuel"
      else do
        let (y, s2) ← (if n == 0 then
            InPlaceSemantics.eval (depth - 1) declarations none ((err, e) :: runtimeEnv) onError
          else InPlaceSemantics.eval (depth - 1) declarations none ((ok, a) :: runtimeEnv) onSuccess).run
            (heapTicked state)
        let (_, s3) ← InPlaceSemantics.observeKept.run s2
        pure (y, s3)) := by
  by_cases noDepth : depth = 0
  · simp [InPlaceSemantics.eval, noDepth, StateT.run, StateT.bind, StateT.lift, throw, throwThe, MonadExceptOf.throw, Except.map] <;> rfl
  · by_cases noFuel : state.fuel = 0
    · rw [InPlaceSemantics.eval]
      simp [InPlaceSemantics.tick, atomRun, noDepth, noFuel, StateT.run, StateT.bind, StateT.get, StateT.set,
        StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
    · rw [InPlaceSemantics.eval]
      by_cases zero : n = 0
      · simp [InPlaceSemantics.tick, atomRun, noDepth, noFuel, zero, heapTicked, StateT.run, StateT.bind, StateT.get, StateT.set,
          StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
      · simp [InPlaceSemantics.tick, atomRun, noDepth, noFuel, zero, heapTicked, StateT.run, StateT.bind, StateT.get, StateT.set,
          StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]

/-! ### The observation of a result -/

theorem corresponds_three {heap : Heap} {o : Observation} {w0 w1 w2 : Value}
    (paired : Corresponds heap o (.record [w0, w1, w2])) :
    ∃ o0 o1 o2, o = .record [o0, o1, o2] ∧ Corresponds heap o0 w0 ∧ Corresponds heap o1 w1 ∧
      Corresponds heap o2 w2 := by
  obtain ⟨os, rfl, len, fields⟩ := corresponds_record_fields paired
  match os, len with
  | [o0, o1, o2], _ =>
    exact ⟨o0, o1, o2, rfl, fields 0 o0 w0 rfl rfl, fields 1 o1 w1 rfl rfl, fields 2 o2 w2 rfl rfl⟩

/-! ### The taken arm -/

/-- The taken arm carries the case: both runtimes tick, run the arm under the
binder at the smaller depth, and observe; the checker's result is the join of
the arm's result with the other arm's result or bottom, and its escapes hold
the arm's. -/
theorem resultCase_arm_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {escapes escapes' : List Origin} {depth : Nat} {after : Live} {input : Atom} {err ok binder : Var} {onError onSuccess arm : Expr} {n : Int} {oE oS : Observation} {wE wS : Value} {o' : Observation} {w' : Value} {payload : Abstract} {payloadType : Ty} {armEscapes : List Origin} {armResult other result : Abstract} {type : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueInput : ValueSemantics.atom (valueEnv env) input = .ok (.record [.int n, oE, oS]))
    (heapInput : InPlaceSemantics.atom (heapEnv env) input = .ok (.record [.int n, wE, wS]))
    (valueArm : (if n == 0 then
        ValueSemantics.eval (depth - 1) declarations none ((err, oE) :: valueEnv env) onError
      else ValueSemantics.eval (depth - 1) declarations none ((ok, oS) :: valueEnv env) onSuccess) =
      ValueSemantics.eval (depth - 1) declarations none ((binder, o') :: valueEnv env) arm)
    (heapArm : (if n == 0 then
        InPlaceSemantics.eval (depth - 1) declarations none ((err, wE) :: heapEnv env) onError
      else InPlaceSemantics.eval (depth - 1) declarations none ((ok, wS) :: heapEnv env) onSuccess) =
      InPlaceSemantics.eval (depth - 1) declarations none ((binder, w') :: heapEnv env) arm)
    (armPreserved : Preserved declarations (depth - 1) ((binder, o', w') :: env) (valueTicked vs)
      (heapTicked hs) arm after ((binder, payload) :: aenv) ((binder, payloadType) :: tenv)
      armEscapes armResult type)
    (fresh : binder ∉ env.map Prod.fst) (noUse : ∀ use ∈ after, use.1 ≠ binder)
    (more : ∀ origin, Escaped armEscapes origin → Escaped escapes' origin)
    (flatType : FlatType type) (shapeArm : FlatAbstract type armResult)
    (shapeOther : other = .bottom ∨ FlatAbstract type other)
    (joined : result = armResult.join other ∨ result = other.join armResult) :
    Preserved declarations depth env vs hs (.resultCase input err ok onError onSuccess) after aenv tenv
      escapes' result type := by
  have heapFuelEq : hs.fuel = vs.fuel := inv.fuel.symm
  have valueArmRun : ∀ s, ((if n == 0 then
        ValueSemantics.eval (depth - 1) declarations none ((err, oE) :: valueEnv env) onError
      else ValueSemantics.eval (depth - 1) declarations none ((ok, oS) :: valueEnv env) onSuccess).run s) =
      (ValueSemantics.eval (depth - 1) declarations none (valueEnv ((binder, o', w') :: env)) arm).run s := by
    intro s; rw [valueArm]; rfl
  have heapArmRun : ∀ s, ((if n == 0 then
        InPlaceSemantics.eval (depth - 1) declarations none ((err, wE) :: heapEnv env) onError
      else InPlaceSemantics.eval (depth - 1) declarations none ((ok, wS) :: heapEnv env) onSuccess).run s) =
      (InPlaceSemantics.eval (depth - 1) declarations none (heapEnv ((binder, o', w') :: env)) arm).run s := by
    intro s; rw [heapArm]; rfl
  constructor
  · intro value vs' run
    rw [value_resultCase_eval_equation vs (valueEnv env) valueInput] at run
    by_cases noDepth : depth = 0
    · rw [if_pos noDepth] at run; cases run
    · by_cases noFuel : vs.fuel = 0
      · rw [if_neg noDepth, if_pos noFuel] at run; cases run
      · have heapFuel : hs.fuel ≠ 0 := by rw [heapFuelEq]; exact noFuel
        rw [if_neg noDepth, if_neg noFuel] at run
        simp only [valueArmRun] at run
        obtain ⟨p2, armValueRun, run⟩ := except_bind_success run
        rcases p2 with ⟨y, s2⟩
        obtain ⟨actual, hs2, gamma2, armHeapRun, inv2, size2, paired2, described2, observed2, typed2,
          tags2, chains2⟩ := armPreserved.success y s2 armValueRun
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
        have inv3 := flatInvariant_more_escapes
          (observed_invariant (flatInvariant_unbind inv2 fresh noUse)) more
        have s3Eq : s3 = vs' := congrArg Prod.snd final
        have observed3 : valueObserved s2 = s3 := congrArg Prod.snd observeEq
        have vsEq : vs' = valueObserved s2 := s3Eq.symm.trans observed3.symm
        have valueEq : value = y := (congrArg Prod.fst final).symm
        subst vsEq
        subst valueEq
        have allocated := allocated_of_typed flatType typed2 tags2
        have describedJoin : Describes gamma2 hs2.heap result actual := by
          rcases shapeOther with rfl | shapeOther'
          · rcases joined with rfl | rfl
            · rw [join_bottom_right]; exact described2
            · rw [join_bottom_left]; exact described2
          · rcases joined with rfl | rfl
            · exact describes_join allocated shapeArm shapeOther' (Or.inl ⟨described2, tags2⟩)
            · exact describes_join allocated shapeOther' shapeArm (Or.inr ⟨described2, tags2⟩)
        have tagsJoin : ResultTags type result actual := by
          rcases shapeOther with rfl | shapeOther'
          · rcases joined with rfl | rfl
            · rw [join_bottom_right]; exact tags2
            · rw [join_bottom_left]; exact tags2
          · rcases joined with rfl | rfl
            · exact resultTags_join tags2 shapeArm shapeOther'
            · exact resultTags_join_right tags2 shapeOther' shapeArm
        have chainsJoin : ChainTags type result value := by
          rcases shapeOther with rfl | shapeOther'
          · rcases joined with rfl | rfl
            · rw [join_bottom_right]; exact chains2
            · rw [join_bottom_left]; exact chains2
          · rcases joined with rfl | rfl
            · exact chainTags_join chains2 shapeArm shapeOther'
            · exact chainTags_join_right chains2 shapeOther' shapeArm
        refine ⟨actual, heapObserved hs2 s2.kept.toList, gamma2, ?_, inv3, ?_, ?_, ?_, observed2, ?_,
          tagsJoin, chainsJoin⟩
        · rw [heap_resultCase_eval_equation hs (heapEnv env) heapInput]
          rw [if_neg noDepth, if_neg heapFuel]
          simp only [heapArmRun]
          simp [armHeapRun, heapObserveRun, Except.bind, Except.pure, bind, pure]
        · rw [heapObserved_heap]; exact size2
        · rw [heapObserved_heap]; exact paired2
        · rw [heapObserved_heap]; exact describedJoin
        · rw [heapObserved_heap]; exact typed2
  · intro message run
    rw [value_resultCase_eval_equation vs (valueEnv env) valueInput] at run
    by_cases noDepth : depth = 0
    · exact ⟨"in-place execution exhausted depth", by
        rw [heap_resultCase_eval_equation hs (heapEnv env) heapInput, if_pos noDepth]⟩
    · by_cases noFuel : vs.fuel = 0
      · have heapFuel : hs.fuel = 0 := by rw [heapFuelEq]; exact noFuel
        exact ⟨"in-place execution exhausted fuel", by
          rw [heap_resultCase_eval_equation hs (heapEnv env) heapInput, if_neg noDepth, if_pos heapFuel]⟩
      · have heapFuel : hs.fuel ≠ 0 := by rw [heapFuelEq]; exact noFuel
        rw [if_neg noDepth, if_neg noFuel] at run
        simp only [valueArmRun] at run
        cases armValue : (ValueSemantics.eval (depth - 1) declarations none
            (valueEnv ((binder, o', w') :: env)) arm).run (valueTicked vs) with
        | error m1 =>
          obtain ⟨m1', armHeapError⟩ := armPreserved.failure m1 armValue
          exact ⟨m1', by
            rw [heap_resultCase_eval_equation hs (heapEnv env) heapInput, if_neg noDepth, if_neg heapFuel]
            simp only [heapArmRun]
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

/-! ### The result-case expression case -/

theorem resultCase_preserved {declarations : List Decl} {input : Atom} {err ok : Var} {onError onSuccess : Expr}
    {self : Decl} {ctx : Context} {inferenceFuel : Nat} {after : Live} {site : List Nat}
    {before next : St} {result : Abstract} {type : Ty} {bound : List Var}
    (flatError : FlatANF0 onError) (flatSuccess : FlatANF0 onSuccess)
    (ihError : ∀ (vs : ValueSemantics.State) (hs : State) (env : List (Var × Observation × Value))
      (live : Live) (aenv : Env Abstract) (tenv : Env Ty) (before next : St) (gamma : Naming)
      (type : Ty) (bound : List Var) (after : Live) (site : List Nat) (result : Abstract)
      (inferenceFuel depth : Nat) (ctx : Context),
      FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma →
      exprType declarations self tenv onError = .ok type → shadowFree bound onError = .ok () →
      (∀ x ∈ env.map Prod.fst, x ∈ bound) → (∀ use ∈ uses onError, use ∈ live) →
      (∀ use ∈ after, use ∈ live) → ctx.config = {} →
      (inferExpr inferenceFuel ctx aenv onError after site).run before = .ok (result, next) →
      Preserved declarations depth env vs hs onError after aenv tenv next.facts.escapes result type)
    (ihSuccess : ∀ (vs : ValueSemantics.State) (hs : State) (env : List (Var × Observation × Value))
      (live : Live) (aenv : Env Abstract) (tenv : Env Ty) (before next : St) (gamma : Naming)
      (type : Ty) (bound : List Var) (after : Live) (site : List Nat) (result : Abstract)
      (inferenceFuel depth : Nat) (ctx : Context),
      FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma →
      exprType declarations self tenv onSuccess = .ok type → shadowFree bound onSuccess = .ok () →
      (∀ x ∈ env.map Prod.fst, x ∈ bound) → (∀ use ∈ uses onSuccess, use ∈ live) →
      (∀ use ∈ after, use ∈ live) → ctx.config = {} →
      (inferExpr inferenceFuel ctx aenv onSuccess after site).run before = .ok (result, next) →
      Preserved declarations depth env vs hs onSuccess after aenv tenv next.facts.escapes result type)
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.resultCase input err ok onError onSuccess) = .ok type)
    (shadow : shadowFree bound (.resultCase input err ok onError onSuccess) = .ok ())
    (boundKeys : ∀ x ∈ env.map Prod.fst, x ∈ bound)
    (usesLive : ∀ use ∈ uses (.resultCase input err ok onError onSuccess), use ∈ live)
    (afterSub : ∀ use ∈ after, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.resultCase input err ok onError onSuccess) after site).run
      before = .ok (result, next)) :
    Preserved declarations depth env vs hs (.resultCase input err ok onError onSuccess) after aenv tenv
      next.facts.escapes result type := by
  -- Static facts.
  obtain ⟨e, a, inputTyped, errorTyped, b', successTyped, equalTypes⟩ :=
    exprType_resultCase_success typed
  obtain ⟨errFresh, okFresh, errorShadow, successShadow⟩ := shadowFree_resultCase_success shadow
  have freshErr : err ∉ env.map Prod.fst := fun member => errFresh (boundKeys err member)
  have freshOk : ok ∉ env.map Prod.fst := fun member => okFresh (boundKeys ok member)
  have scope := infer_scope_success defaultConfig accepted
  have outerErr := outer_avoids_fresh_binder inv.abstractKeys freshErr scope
  have outerOk := outer_avoids_fresh_binder inv.abstractKeys freshOk scope
  have noUseErr : ∀ use ∈ after, use.1 ≠ err := by
    intro use member same
    have excluded := List.filter_eq_nil_iff.mp outerErr use member
    simp [same] at excluded
  have noUseOk : ∀ use ∈ after, use.1 ≠ ok := by
    intro use member same
    have excluded := List.filter_eq_nil_iff.mp outerOk use member
    simp [same] at excluded
  rw [uses_resultCase] at usesLive
  have covered : ∀ use ∈ atomUses input, use ∈ live :=
    fun use member => usesLive use (union_left _ _ use member)
  -- The input.
  obtain ⟨o, w, abstract, valueInput, heapInput, abstractRun, paired, described, observed, valueTyped,
    flatInput, shape, allocated, tags, chains⟩ := flat_atom_values inv inputTyped covered
  cases shape with
  | bottom _ => exact absurd rfl (resultTags_ne_bottom tags)
  | result _ _ ae aa hE hS =>
    cases flatInput with
    | result _ _ flatE flatA =>
      obtain ⟨childFuel, left, middle, right, last, _, _, leftRun, rightRun, resultEq, nextEq⟩ :=
        infer_resultCase_success defaultConfig abstractRun accepted
      have escapesEq : next.facts.escapes = union middle.facts.escapes last.facts.escapes := by
        rw [nextEq]; rfl
      have static := FlatStatic.of_invariant inv
      have aenvBound : ∀ x ∈ aenv.map Prod.fst, x ∈ bound := by
        rw [← inv.abstractKeys]; exact boundKeys
      have errorBoundKeys : ∀ (x : Observation) (w : Value),
          ∀ key ∈ ((err, x, w) :: env).map Prod.fst, key ∈ err :: bound := by
        intro x w key member
        simp only [List.map_cons, List.mem_cons] at member
        rcases member with rfl | old
        · simp
        · exact List.mem_cons_of_mem _ (boundKeys key old)
      have successBoundKeys : ∀ (x : Observation) (w : Value),
          ∀ key ∈ ((ok, x, w) :: env).map Prod.fst, key ∈ ok :: bound := by
        intro x w key member
        simp only [List.map_cons, List.mem_cons] at member
        rcases member with rfl | old
        · simp
        · exact List.mem_cons_of_mem _ (boundKeys key old)
      have errorAenvBound : ∀ x ∈ ((err, ae) :: aenv).map Prod.fst, x ∈ err :: bound := by
        intro x member
        simp only [List.map_cons, List.mem_cons] at member
        rcases member with rfl | old
        · simp
        · exact List.mem_cons_of_mem _ (aenvBound x old)
      have successAenvBound : ∀ x ∈ ((ok, aa) :: aenv).map Prod.fst, x ∈ ok :: bound := by
        intro x member
        simp only [List.map_cons, List.mem_cons] at member
        rcases member with rfl | old
        · simp
        · exact List.mem_cons_of_mem _ (aenvBound x old)
      -- The arms' live sets.
      have errorLiveSub : ∀ use ∈ union (uses onError) after,
          use.1 = err ∨ use ∈ live := by
        intro use member
        by_cases same : use.1 = err
        · exact Or.inl same
        · right
          rcases mem_union_cases _ _ use member with inner | outer
          · exact usesLive use (union_right _ _ use (union_left _ _ use
              (List.mem_filter.mpr ⟨inner, by simpa using same⟩)))
          · exact afterSub use outer
      have successLiveSub : ∀ use ∈ union (uses onSuccess) after,
          use.1 = ok ∨ use ∈ live := by
        intro use member
        by_cases same : use.1 = ok
        · exact Or.inl same
        · right
          rcases mem_union_cases _ _ use member with inner | outer
          · exact usesLive use (union_right _ _ use (union_right _ _ use
              (List.mem_filter.mpr ⟨inner, by simpa using same⟩)))
          · exact afterSub use outer
      have errorLiveTyped : ∀ p, (err, p) ∈ union (uses onError) after → ∃ t, tyAt e p = some t := by
        intro p member
        rcases mem_union_cases _ _ (err, p) member with inner | outer
        · obtain ⟨tk, t, declared, at_p⟩ := flat_uses_typed flatError _ _ errorTyped err p inner
          rw [lookup_cons_same] at declared
          cases Option.some.inj declared
          exact ⟨t, at_p⟩
        · exact absurd rfl (noUseErr (err, p) outer)
      have successLiveTyped : ∀ p, (ok, p) ∈ union (uses onSuccess) after → ∃ t, tyAt a p = some t := by
        intro p member
        rcases mem_union_cases _ _ (ok, p) member with inner | outer
        · obtain ⟨tk, t, declared, at_p⟩ := flat_uses_typed flatSuccess _ _ successTyped ok p inner
          rw [lookup_cons_same] at declared
          cases Option.some.inj declared
          exact ⟨t, at_p⟩
        · exact absurd rfl (noUseOk (ok, p) outer)
      -- The static facts of an inferred arm.
      have errorStatic : (ae == .bottom) = false →
          (inferExpr childFuel {ctx with escaped := union ctx.escaped before.facts.escapes}
            ((err, ae) :: aenv) onError after (site ++ [0])).run before = .ok (left, middle) →
          FlatType type ∧ FlatAbstract type left := by
        intro _ armRun
        obtain ⟨flatType, shape, _⟩ := flat_static (self := self) flatError ((err, ae) :: aenv)
          ((err, e) :: tenv) before middle type (err :: bound) after (site ++ [0]) left childFuel _
          (static.bind err flatE hE) errorTyped errorShadow errorAenvBound
          (by exact defaultConfig) armRun
        exact ⟨flatType, shape⟩
      have successStatic : (aa == .bottom) = false →
          (inferExpr childFuel {ctx with escaped := union ctx.escaped before.facts.escapes}
            ((ok, aa) :: aenv) onSuccess after (site ++ [1])).run {middle with facts := before.facts} =
            .ok (right, last) →
          FlatType b' ∧ FlatAbstract b' right := by
        intro _ armRun
        obtain ⟨flatType, shape, _⟩ := flat_static (self := self) flatSuccess ((ok, aa) :: aenv)
          ((ok, a) :: tenv) {middle with facts := before.facts} last b' (ok :: bound) after
          (site ++ [1]) right childFuel _ (static.bind ok flatA hS) successTyped successShadow
          successAenvBound (by exact defaultConfig) armRun
        exact ⟨flatType, shape⟩
      -- The runtime value, by its tag.
      cases allocated with
      | ok _ _ wS allocatedS =>
        cases tags with
        | ok _ _ _ _ _ _ neS tagsS =>
          obtain ⟨o0, o1, o2, rfl, paired0, paired1, paired2⟩ := corresponds_three paired
          have o0Eq := corresponds_int_inv paired0
          subst o0Eq
          have o1Eq := corresponds_int_inv paired1
          subst o1Eq
          have chainsS : ChainTags a aa o2 := by
            cases chains with
            | ok _ _ _ _ _ _ chainsS => exact chainsS
          have observedS : obsTyped declarations o2 a = true := by simpa [obsTyped] using observed
          have describedS : Describes gamma hs.heap aa wS := describes_field (i := 2) described rfl rfl
          have typedS : ValueTyped declarations hs.heap wS a :=
            valueTyped_of_allocated allocatedS
          have bottomS : (aa == .bottom) = false := by
            cases h : (aa == .bottom)
            · rfl
            · exact absurd (eq_bottom_of_beq h) neS
          rcases rightRun with ⟨bottom, _, _⟩ | ⟨_, rightRun⟩
          · rw [bottomS] at bottom; cases bottom
          obtain ⟨flatB, rightShape⟩ := successStatic bottomS rightRun
          -- The invariant under the binder, at the ticked states and the arm's facts.
          have invArm := flatInvariant_bind (ticked_invariant inv) freshOk paired2 describedS flatA hS
            observedS typedS tagsS chainsS successLiveSub successLiveTyped
          have armPreserved := ihSuccess (valueTicked vs) (heapTicked hs) ((ok, o2, wS) :: env)
            (union (uses onSuccess) after) ((ok, aa) :: aenv) ((ok, a) :: tenv)
            {middle with facts := before.facts} last gamma b' (ok :: bound) after (site ++ [1]) right
            childFuel (depth - 1) _ invArm successTyped successShadow (successBoundKeys o2 wS)
            (fun use member => union_left _ _ use member) (fun use member => union_right _ _ use member)
            (by exact defaultConfig) rightRun
          -- The other arm: skipped, or inferred with a flat shape.
          have otherShape : left = .bottom ∨ FlatAbstract type left := by
            rcases leftRun with ⟨_, rfl, _⟩ | ⟨bottomE, leftRun⟩
            · exact Or.inl rfl
            · exact Or.inr (errorStatic bottomE leftRun).2
          have flatType : FlatType type := by
            rcases leftRun with ⟨_, _, _⟩ | ⟨bottomE, leftRun⟩
            · rw [ty_equal_flat_right flatB equalTypes]; exact flatB
            · exact (errorStatic bottomE leftRun).1
          have sameType : type = b' := ty_equal_flat flatType equalTypes
          subst sameType
          refine resultCase_arm_preserved inv valueInput heapInput (binder := ok) (o' := o2) (w' := wS)
            (arm := onSuccess) (by simp) (by simp) armPreserved freshOk noUseOk ?_ flatType rightShape
            otherShape (Or.inr resultEq)
          intro origin escaped
          rw [escapesEq]
          exact escaped_subset (fun x member => mem_union _ _ x (Or.inr member)) escaped
      | err _ _ wE allocatedE =>
        cases tags with
        | err _ _ _ _ _ _ neE tagsE =>
          obtain ⟨o0, o1, o2, rfl, paired0, paired1, paired2⟩ := corresponds_three paired
          have o0Eq := corresponds_int_inv paired0
          subst o0Eq
          have o2Eq := corresponds_int_inv paired2
          subst o2Eq
          have chainsE : ChainTags e ae o1 := by
            cases chains with
            | err _ _ _ _ _ _ chainsE => exact chainsE
          have observedE : obsTyped declarations o1 e = true := by simpa [obsTyped] using observed
          have describedE : Describes gamma hs.heap ae wE := describes_field (i := 1) described rfl rfl
          have typedE : ValueTyped declarations hs.heap wE e :=
            valueTyped_of_allocated allocatedE
          have bottomE : (ae == .bottom) = false := by
            cases h : (ae == .bottom)
            · rfl
            · exact absurd (eq_bottom_of_beq h) neE
          rcases leftRun with ⟨bottom, _, _⟩ | ⟨_, leftRun⟩
          · rw [bottomE] at bottom; cases bottom
          obtain ⟨flatType, leftShape⟩ := errorStatic bottomE leftRun
          have invArm := flatInvariant_bind (ticked_invariant inv) freshErr paired1 describedE flatE hE
            observedE typedE tagsE chainsE errorLiveSub errorLiveTyped
          have armPreserved := ihError (valueTicked vs) (heapTicked hs) ((err, o1, wE) :: env)
            (union (uses onError) after) ((err, ae) :: aenv) ((err, e) :: tenv) before middle gamma type
            (err :: bound) after (site ++ [0]) left childFuel (depth - 1) _ invArm errorTyped errorShadow
            (errorBoundKeys o1 wE) (fun use member => union_left _ _ use member)
            (fun use member => union_right _ _ use member) (by exact defaultConfig) leftRun
          have otherShape : right = .bottom ∨ FlatAbstract type right := by
            rcases rightRun with ⟨_, rfl, _⟩ | ⟨bottomS, rightRun⟩
            · exact Or.inl rfl
            · obtain ⟨_, rightShape⟩ := successStatic bottomS rightRun
              have sameType : type = b' := ty_equal_flat flatType equalTypes
              subst sameType
              exact Or.inr rightShape
          refine resultCase_arm_preserved inv valueInput heapInput (binder := err) (o' := o1) (w' := wE)
            (arm := onError) (by simp) (by simp) armPreserved freshErr noUseErr ?_ flatType leftShape
            otherShape (Or.inl resultEq)
          intro origin escaped
          rw [escapesEq]
          exact escaped_mono _ escaped

end Ownership.FlatFragment.ResultCase
