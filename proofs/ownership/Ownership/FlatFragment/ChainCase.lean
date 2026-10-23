import Ownership.FlatFragment.ResultCase

/-! The first flat fragment: the chain-case evaluation equations and the chain-case case. -/

/-! chain-case composition under the generic flat relation.
A chain case reads a chain and runs the end arm when the chain is empty, or
binds its head and a copy of its tail and runs the link arm. Both runtimes
take the arm of the runtime chain; the heap runtime allocates the copy of
the tail, which the checker names by the input's origins. The checker
infers both arms from the incoming facts, the link arm under the element
abstract for the head and the input's abstract for the tail, and joins the
arms' results and escapes. The chain tags of the relation say that a bottom
element describes an empty chain, so the arm the runtime takes binds a
scalar head. -/

namespace Ownership.FlatFragment.ChainCase

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.StateFrame
open Ownership.FlatFragment.Observe Ownership.FlatFragment.Runtime Ownership.FlatFragment.HeapPreservation Ownership.FlatFragment.Description
open Ownership.FlatFragment.Atoms Ownership.FlatFragment.AtomInteger Ownership.FlatFragment.CheckerExtraction Ownership.FlatFragment.InferChainCase
open Ownership.FlatFragment.Literal Ownership.FlatFragment.Length Ownership.FlatFragment.LiveSets Ownership.FlatFragment.Liveness Ownership.FlatFragment.Scope
open Ownership.FlatFragment.HeapFrame Ownership.FlatFragment.Support Ownership.FlatFragment.NamingFacts Ownership.FlatFragment.VariableFacts
open Ownership.FlatFragment.Static Ownership.FlatFragment.Fields Ownership.FlatFragment.Shared Ownership.FlatFragment.Let
open Ownership.FlatFragment.Naming Ownership.FlatFragment.IntegerCorrespondence Ownership.FlatFragment.Chain

local instance stepReflBEq : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance stepLawfulBEq : LawfulBEq Step := LawfulBEq.mk (by deriving_LawfulEq_tactic)
local instance originReflBEq : ReflBEq Origin := ⟨by deriving_ReflEq_tactic⟩
local instance originLawfulBEq : LawfulBEq Origin := LawfulBEq.mk (by deriving_LawfulEq_tactic)

/-! ### The evaluation equations -/

theorem value_chainCase_end_equation {depth : Nat} {declarations : List Decl} {input : Atom} {head tail : Var} {onEnd onLink : Expr}
    (state : ValueSemantics.State) (runtimeEnv : Env Observation)
    (atomRun : ValueSemantics.atom runtimeEnv input = .ok (.list [])) :
    (ValueSemantics.eval depth declarations none runtimeEnv (.chainCase input head tail onEnd onLink)).run state =
      (if depth = 0 then .error "value execution exhausted depth"
      else if state.fuel = 0 then .error "value execution exhausted fuel"
      else do
        let (y, s2) ← (ValueSemantics.eval (depth - 1) declarations none runtimeEnv onEnd).run
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
      simp [ValueSemantics.tick, atomRun, noDepth, noFuel, valueTicked, StateT.run, StateT.bind, StateT.get, StateT.set,
        StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]

theorem value_chainCase_link_equation {depth : Nat} {declarations : List Decl} {input : Atom} {head tail : Var} {onEnd onLink : Expr} {h : Observation} {t : List Observation}
    (state : ValueSemantics.State) (runtimeEnv : Env Observation)
    (atomRun : ValueSemantics.atom runtimeEnv input = .ok (.list (h :: t))) :
    (ValueSemantics.eval depth declarations none runtimeEnv (.chainCase input head tail onEnd onLink)).run state =
      (if depth = 0 then .error "value execution exhausted depth"
      else if state.fuel = 0 then .error "value execution exhausted fuel"
      else do
        let (y, s2) ← (ValueSemantics.eval (depth - 1) declarations none
          ((head, h) :: (tail, .list t) :: runtimeEnv) onLink).run (valueTicked state)
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

theorem heap_chainCase_end_equation {depth : Nat} {declarations : List Decl} {input : Atom} {head tail : Var} {onEnd onLink : Expr} {root : Nat}
    (state : InPlaceSemantics.State) (runtimeEnv : Env Value)
    (atomRun : InPlaceSemantics.atom runtimeEnv input = .ok (.ref root))
    (lookup : state.heap[root]? = some []) :
    (InPlaceSemantics.eval depth declarations none runtimeEnv (.chainCase input head tail onEnd onLink)).run state =
      (if depth = 0 then .error "in-place execution exhausted depth"
      else if state.fuel = 0 then .error "in-place execution exhausted fuel"
      else do
        let (y, s2) ← (InPlaceSemantics.eval (depth - 1) declarations none runtimeEnv onEnd).run
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
      simp [InPlaceSemantics.tick, InPlaceSemantics.array, atomRun, lookup, noDepth, noFuel, heapTicked,
        Option.toExcept, StateT.run, StateT.bind, StateT.get, StateT.set,
        StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]

/-- The heap state after the copy of a tail: the tick and the allocation at the next address. -/
def heapCopied (hs : State) (t : List Value) : State :=
  {hs with fuel := hs.fuel - 1, heap := hs.heap.push t}

theorem heapCopied_ints (hs : State) (integers : List Int) :
    heapCopied hs (heapInts integers) = heapAllocated hs integers := rfl

theorem heap_chainCase_link_equation {depth : Nat} {declarations : List Decl} {input : Atom} {head tail : Var} {onEnd onLink : Expr} {root : Nat} {h : Value} {t : List Value}
    (state : InPlaceSemantics.State) (runtimeEnv : Env Value)
    (atomRun : InPlaceSemantics.atom runtimeEnv input = .ok (.ref root))
    (lookup : state.heap[root]? = some (h :: t)) :
    (InPlaceSemantics.eval depth declarations none runtimeEnv (.chainCase input head tail onEnd onLink)).run state =
      (if depth = 0 then .error "in-place execution exhausted depth"
      else if state.fuel = 0 then .error "in-place execution exhausted fuel"
      else do
        let (y, s2) ← (InPlaceSemantics.eval (depth - 1) declarations none
          ((head, h) :: (tail, .ref state.heap.size) :: runtimeEnv) onLink).run (heapCopied state t)
        let (_, s3) ← InPlaceSemantics.observeKept.run s2
        pure (y, s3)) := by
  by_cases noDepth : depth = 0
  · simp [InPlaceSemantics.eval, noDepth, StateT.run, StateT.bind, StateT.lift, throw, throwThe, MonadExceptOf.throw, Except.map] <;> rfl
  · by_cases noFuel : state.fuel = 0
    · rw [InPlaceSemantics.eval]
      simp [InPlaceSemantics.tick, atomRun, noDepth, noFuel, StateT.run, StateT.bind, StateT.get, StateT.set,
        StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
    · rw [InPlaceSemantics.eval]
      simp [InPlaceSemantics.tick, InPlaceSemantics.array, InPlaceSemantics.alloc, atomRun, lookup, noDepth,
        noFuel, heapCopied, Option.toExcept, StateT.run, StateT.bind, StateT.get, StateT.set,
        StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]

/-! ### The copy of the tail -/

/-- The relation after the copy of a tail: the naming extends at the actual
new address, at an origin that names the input's array, so the copy is
named by the input's origins; the hole is that address, and no old binding
or observer names it. -/
theorem tail_post_invariant {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {escapes : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (integers : List Int) (origin : Origin) :
    ∃ gamma',
      FlatInvariant declarations (valueTicked vs) (heapAllocated hs integers) env live aenv tenv escapes gamma' ∧
      hs.heap.size ∈ gamma' origin ∧
      (∀ o cell, cell < hs.heap.size → (cell ∈ gamma' o ↔ cell ∈ gamma o)) := by
  obtain ⟨gamma', extension, bounded, separating, old⟩ :=
    origin_allocation_naming (gamma := gamma) (heapSize := hs.heap.size)
      (fun o address member => inv.namingBound o address member) inv.separating origin
  obtain ⟨footprint, represented⟩ := inv.observers
  refine ⟨gamma', ?_, (extension origin hs.heap.size).mpr (Or.inr ⟨rfl, rfl⟩), old⟩
  have heapEq : (heapAllocated hs integers).heap = hs.heap.push (heapInts integers) := rfl
  refine flatInvariant_heap_frame inv (hole := hs.heap.size) (footprint := footprint)
    (fun _ member => member) ?_ ?_ ?_ ?_ represented ?_ ?_ ?_ old ?_ separating ?_ ?_ ?_
    (fun _ escaped => escaped)
  · rw [heapEq]; exact integerFrame_after_allocation hs.heap integers
  · exact inv.links
  · intro c _ different
    rw [heapEq]
    simp [Array.getElem?_push, different]
  · intro x p _ o w w' binding projected q c located
    have := live_path_below inv x p o w w' binding projected q c located
    omega
  · intro member
    have bound := representsMany_bound represented _ member
    omega
  · rfl
  · rfl
  · rw [heapEq]
    simp only [Array.size_push]
    intro o address member
    exact bounded o address member
  · exact inv.reads
  · exact inv.external
  · simp [valueTicked, heapAllocated, inv.fuel]

/-! ### The end arm -/

theorem chainCase_end_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {escapes escapes' : List Origin} {depth : Nat} {input : Atom} {head tail : Var} {onEnd onLink : Expr} {root : Nat} {after : Live} {armEscapes : List Origin} {armResult other result : Abstract} {type : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueInput : ValueSemantics.atom (valueEnv env) input = .ok (.list []))
    (heapInput : InPlaceSemantics.atom (heapEnv env) input = .ok (.ref root))
    (lookup : hs.heap[root]? = some [])
    (armPreserved : Preserved declarations (depth - 1) env (valueTicked vs) (heapTicked hs) onEnd after
      aenv tenv armEscapes armResult type)
    (more : ∀ origin, Escaped armEscapes origin → Escaped escapes' origin)
    (flatType : FlatType type) (shapeArm : FlatAbstract type armResult)
    (shapeOther : FlatAbstract type other)
    (joined : result = armResult.join other) :
    Preserved declarations depth env vs hs (.chainCase input head tail onEnd onLink) after aenv tenv
      escapes' result type := by
  have heapFuelEq : hs.fuel = vs.fuel := inv.fuel.symm
  subst joined
  constructor
  · intro value vs' run
    rw [value_chainCase_end_equation vs (valueEnv env) valueInput] at run
    by_cases noDepth : depth = 0
    · rw [if_pos noDepth] at run; cases run
    · by_cases noFuel : vs.fuel = 0
      · rw [if_neg noDepth, if_pos noFuel] at run; cases run
      · have heapFuel : hs.fuel ≠ 0 := by rw [heapFuelEq]; exact noFuel
        rw [if_neg noDepth, if_neg noFuel] at run
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
        have inv3 := flatInvariant_more_escapes (observed_invariant inv2) more
        have s3Eq : s3 = vs' := congrArg Prod.snd final
        have observed3 : valueObserved s2 = s3 := congrArg Prod.snd observeEq
        have vsEq : vs' = valueObserved s2 := s3Eq.symm.trans observed3.symm
        have valueEq : value = y := (congrArg Prod.fst final).symm
        subst vsEq
        subst valueEq
        have allocated := allocated_of_typed flatType typed2 tags2
        refine ⟨actual, heapObserved hs2 s2.kept.toList, gamma2, ?_, inv3, ?_, ?_, ?_, observed2, ?_,
          resultTags_join tags2 shapeArm shapeOther, chainTags_join chains2 shapeArm shapeOther⟩
        · rw [heap_chainCase_end_equation hs (heapEnv env) heapInput lookup]
          rw [if_neg noDepth, if_neg heapFuel]
          simp [armHeapRun, heapObserveRun, Except.bind, Except.pure, bind, pure]
        · rw [heapObserved_heap]; exact size2
        · rw [heapObserved_heap]; exact paired2
        · rw [heapObserved_heap]
          exact describes_join allocated shapeArm shapeOther (Or.inl ⟨described2, tags2⟩)
        · rw [heapObserved_heap]; exact typed2
  · intro message run
    rw [value_chainCase_end_equation vs (valueEnv env) valueInput] at run
    by_cases noDepth : depth = 0
    · exact ⟨"in-place execution exhausted depth", by
        rw [heap_chainCase_end_equation hs (heapEnv env) heapInput lookup, if_pos noDepth]⟩
    · by_cases noFuel : vs.fuel = 0
      · have heapFuel : hs.fuel = 0 := by rw [heapFuelEq]; exact noFuel
        exact ⟨"in-place execution exhausted fuel", by
          rw [heap_chainCase_end_equation hs (heapEnv env) heapInput lookup, if_neg noDepth, if_pos heapFuel]⟩
      · have heapFuel : hs.fuel ≠ 0 := by rw [heapFuelEq]; exact noFuel
        rw [if_neg noDepth, if_neg noFuel] at run
        cases armValue : (ValueSemantics.eval (depth - 1) declarations none (valueEnv env) onEnd).run
            (valueTicked vs) with
        | error m1 =>
          obtain ⟨m1', armHeapError⟩ := armPreserved.failure m1 armValue
          exact ⟨m1', by
            rw [heap_chainCase_end_equation hs (heapEnv env) heapInput lookup, if_neg noDepth, if_neg heapFuel]
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

/-! ### The link arm -/

/-- The link arm: both runtimes tick, the heap runtime copies the tail, both
bind the head and the tail and run the arm at the smaller depth, and
observe; the checker's result is the join of the end arm's result with the
arm's, and its escapes hold the arm's. The arm's induction hypothesis is
taken under the two binders at the states after the copy. -/
theorem chainCase_link_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {escapes escapes' : List Origin} {depth : Nat} {input : Atom} {head tail : Var} {onEnd onLink : Expr} {root : Nat} {n : Int} {integers : List Int} {after : Live} {armEscapes : List Origin} {armResult other result : Abstract} {type : Ty} {element tailAbstract : Abstract}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueInput : ValueSemantics.atom (valueEnv env) input = .ok (.list (valueInts (n :: integers))))
    (heapInput : InPlaceSemantics.atom (heapEnv env) input = .ok (.ref root))
    (lookup : hs.heap[root]? = some (heapInts (n :: integers)))
    (armPreserved : Preserved declarations (depth - 1)
      ((head, .int n, .int n) :: (tail, .list (valueInts integers), .ref hs.heap.size) :: env)
      (valueTicked vs) (heapAllocated hs integers) onLink after
      ((head, element) :: (tail, tailAbstract) :: aenv) ((head, .int) :: (tail, .chain .int) :: tenv)
      armEscapes armResult type)
    (freshHead : head ∉ env.map Prod.fst) (freshTail : tail ∉ env.map Prod.fst) (different : head ≠ tail)
    (noUseHead : ∀ use ∈ after, use.1 ≠ head) (noUseTail : ∀ use ∈ after, use.1 ≠ tail)
    (more : ∀ origin, Escaped armEscapes origin → Escaped escapes' origin)
    (flatType : FlatType type) (shapeArm : FlatAbstract type armResult)
    (shapeOther : FlatAbstract type other)
    (joined : result = other.join armResult) :
    Preserved declarations depth env vs hs (.chainCase input head tail onEnd onLink) after aenv tenv
      escapes' result type := by
  have heapFuelEq : hs.fuel = vs.fuel := inv.fuel.symm
  subst joined
  have freshHead' : head ∉ ((tail, .list (valueInts integers), .ref hs.heap.size) :: env).map Prod.fst := by
    intro member
    simp only [List.map_cons, List.mem_cons] at member
    rcases member with same | old
    · exact different same
    · exact freshHead old
  have valueInputCons : ValueSemantics.atom (valueEnv env) input = .ok (.list (.int n :: valueInts integers)) :=
    valueInput
  have lookupCons : hs.heap[root]? = some (.int n :: heapInts integers) := lookup
  have valueArmRun : ∀ s, (ValueSemantics.eval (depth - 1) declarations none
      ((head, .int n) :: (tail, .list (valueInts integers)) :: valueEnv env) onLink).run s =
      (ValueSemantics.eval (depth - 1) declarations none
        (valueEnv ((head, .int n, .int n) :: (tail, .list (valueInts integers), .ref hs.heap.size) :: env)) onLink).run s := by
    intro s; rfl
  have heapArmRun : ∀ s, (InPlaceSemantics.eval (depth - 1) declarations none
      ((head, .int n) :: (tail, .ref hs.heap.size) :: heapEnv env) onLink).run s =
      (InPlaceSemantics.eval (depth - 1) declarations none
        (heapEnv ((head, .int n, .int n) :: (tail, .list (valueInts integers), .ref hs.heap.size) :: env)) onLink).run s := by
    intro s; rfl
  constructor
  · intro value vs' run
    rw [value_chainCase_link_equation vs (valueEnv env) valueInputCons] at run
    by_cases noDepth : depth = 0
    · rw [if_pos noDepth] at run; cases run
    · by_cases noFuel : vs.fuel = 0
      · rw [if_neg noDepth, if_pos noFuel] at run; cases run
      · have heapFuel : hs.fuel ≠ 0 := by rw [heapFuelEq]; exact noFuel
        rw [if_neg noDepth, if_neg noFuel] at run
        rw [valueArmRun] at run
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
          (observed_invariant (flatInvariant_unbind (flatInvariant_unbind inv2 freshHead' noUseHead)
            freshTail noUseTail)) more
        have s3Eq : s3 = vs' := congrArg Prod.snd final
        have observed3 : valueObserved s2 = s3 := congrArg Prod.snd observeEq
        have vsEq : vs' = valueObserved s2 := s3Eq.symm.trans observed3.symm
        have valueEq : value = y := (congrArg Prod.fst final).symm
        subst vsEq
        subst valueEq
        have allocated := allocated_of_typed flatType typed2 tags2
        refine ⟨actual, heapObserved hs2 s2.kept.toList, gamma2, ?_, inv3, ?_, ?_, ?_, observed2, ?_,
          resultTags_join_right tags2 shapeOther shapeArm, chainTags_join_right chains2 shapeOther shapeArm⟩
        · rw [heap_chainCase_link_equation hs (heapEnv env) heapInput lookupCons]
          rw [if_neg noDepth, if_neg heapFuel, heapCopied_ints, heapArmRun]
          simp [armHeapRun, heapObserveRun, Except.bind, Except.pure, bind, pure]
        · rw [heapObserved_heap]
          exact Nat.le_trans (by simp [heapAllocated]) size2
        · rw [heapObserved_heap]; exact paired2
        · rw [heapObserved_heap]
          exact describes_join allocated shapeOther shapeArm (Or.inr ⟨described2, tags2⟩)
        · rw [heapObserved_heap]; exact typed2
  · intro message run
    rw [value_chainCase_link_equation vs (valueEnv env) valueInputCons] at run
    by_cases noDepth : depth = 0
    · exact ⟨"in-place execution exhausted depth", by
        rw [heap_chainCase_link_equation hs (heapEnv env) heapInput lookupCons, if_pos noDepth]⟩
    · by_cases noFuel : vs.fuel = 0
      · have heapFuel : hs.fuel = 0 := by rw [heapFuelEq]; exact noFuel
        exact ⟨"in-place execution exhausted fuel", by
          rw [heap_chainCase_link_equation hs (heapEnv env) heapInput lookupCons, if_neg noDepth,
            if_pos heapFuel]⟩
      · have heapFuel : hs.fuel ≠ 0 := by rw [heapFuelEq]; exact noFuel
        rw [if_neg noDepth, if_neg noFuel] at run
        rw [valueArmRun] at run
        cases armValue : (ValueSemantics.eval (depth - 1) declarations none
            (valueEnv ((head, .int n, .int n) :: (tail, .list (valueInts integers), .ref hs.heap.size) :: env))
            onLink).run (valueTicked vs) with
        | error m1 =>
          obtain ⟨m1', armHeapError⟩ := armPreserved.failure m1 armValue
          exact ⟨m1', by
            rw [heap_chainCase_link_equation hs (heapEnv env) heapInput lookupCons, if_neg noDepth,
              if_neg heapFuel, heapCopied_ints, heapArmRun]
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

/-! ### The chain-case expression case -/

theorem chainCase_preserved {declarations : List Decl} {input : Atom} {head tail : Var} {onEnd onLink : Expr}
    {self : Decl} {ctx : Context} {inferenceFuel : Nat} {after : Live} {site : List Nat}
    {before next : St} {result : Abstract} {type : Ty} {bound : List Var}
    (flatEnd : FlatANF0 onEnd) (flatLink : FlatANF0 onLink)
    (ihEnd : ∀ (vs : ValueSemantics.State) (hs : State) (env : List (Var × Observation × Value))
      (live : Live) (aenv : Env Abstract) (tenv : Env Ty) (before next : St) (gamma : Naming)
      (type : Ty) (bound : List Var) (after : Live) (site : List Nat) (result : Abstract)
      (inferenceFuel depth : Nat) (ctx : Context),
      FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma →
      exprType declarations self tenv onEnd = .ok type → shadowFree bound onEnd = .ok () →
      (∀ x ∈ env.map Prod.fst, x ∈ bound) → (∀ use ∈ uses onEnd, use ∈ live) →
      (∀ use ∈ after, use ∈ live) → ctx.config = {} →
      (inferExpr inferenceFuel ctx aenv onEnd after site).run before = .ok (result, next) →
      Preserved declarations depth env vs hs onEnd after aenv tenv next.facts.escapes result type)
    (ihLink : ∀ (vs : ValueSemantics.State) (hs : State) (env : List (Var × Observation × Value))
      (live : Live) (aenv : Env Abstract) (tenv : Env Ty) (before next : St) (gamma : Naming)
      (type : Ty) (bound : List Var) (after : Live) (site : List Nat) (result : Abstract)
      (inferenceFuel depth : Nat) (ctx : Context),
      FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma →
      exprType declarations self tenv onLink = .ok type → shadowFree bound onLink = .ok () →
      (∀ x ∈ env.map Prod.fst, x ∈ bound) → (∀ use ∈ uses onLink, use ∈ live) →
      (∀ use ∈ after, use ∈ live) → ctx.config = {} →
      (inferExpr inferenceFuel ctx aenv onLink after site).run before = .ok (result, next) →
      Preserved declarations depth env vs hs onLink after aenv tenv next.facts.escapes result type)
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.chainCase input head tail onEnd onLink) = .ok type)
    (shadow : shadowFree bound (.chainCase input head tail onEnd onLink) = .ok ())
    (boundKeys : ∀ x ∈ env.map Prod.fst, x ∈ bound)
    (usesLive : ∀ use ∈ uses (.chainCase input head tail onEnd onLink), use ∈ live)
    (afterSub : ∀ use ∈ after, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.chainCase input head tail onEnd onLink) after site).run
      before = .ok (result, next)) :
    Preserved declarations depth env vs hs (.chainCase input head tail onEnd onLink) after aenv tenv
      next.facts.escapes result type := by
  -- Static facts.
  obtain ⟨t, inputTyped, endTyped, b', linkTyped, equalTypes⟩ := exprType_chainCase_success typed
  obtain ⟨headFresh, tailFresh, different, endShadow, linkShadow⟩ := shadowFree_chainCase_success shadow
  have freshHead : head ∉ env.map Prod.fst := fun member => headFresh (boundKeys head member)
  have freshTail : tail ∉ env.map Prod.fst := fun member => tailFresh (boundKeys tail member)
  have scope := infer_scope_success defaultConfig accepted
  have outerHead := outer_avoids_fresh_binder inv.abstractKeys freshHead scope
  have outerTail := outer_avoids_fresh_binder inv.abstractKeys freshTail scope
  have noUseHead : ∀ use ∈ after, use.1 ≠ head := by
    intro use member same
    have excluded := List.filter_eq_nil_iff.mp outerHead use member
    simp [same] at excluded
  have noUseTail : ∀ use ∈ after, use.1 ≠ tail := by
    intro use member same
    have excluded := List.filter_eq_nil_iff.mp outerTail use member
    simp [same] at excluded
  rw [uses_chainCase] at usesLive
  have covered : ∀ use ∈ atomUses input, use ∈ live :=
    fun use member => usesLive use (union_left _ _ use member)
  have endUsesLive : ∀ use ∈ uses onEnd, use ∈ live :=
    fun use member => usesLive use (union_right _ _ use (union_left _ _ use member))
  -- The input: a chain of integers.
  have tInt : t = .int := by
    cases flat_atom_type inv inputTyped with
    | chainInt => rfl
  subst tInt
  obtain ⟨root, integers, roots, element, certificate, lookup, rootNamed, elementFlat, emptyIfBottom,
    valueInput, heapInput, abstractInput⟩ := flat_atom_chain_path inv inputTyped covered
  obtain ⟨childFuel, left, middle, right, last, _, _, leftRun, rightRun, resultEq, nextEq⟩ :=
    infer_chainCase_success defaultConfig abstractInput accepted
  have escapesEq : next.facts.escapes = union middle.facts.escapes last.facts.escapes := by
    rw [nextEq]; rfl
  have static := FlatStatic.of_invariant inv
  have aenvBound : ∀ x ∈ aenv.map Prod.fst, x ∈ bound := by
    rw [← inv.abstractKeys]; exact boundKeys
  -- The end arm, statically.
  obtain ⟨flatType, endShape, _⟩ :=
    flat_static (self := self) flatEnd aenv tenv before middle type bound after (site ++ [0]) left
      childFuel _ static endTyped endShadow aenvBound (by exact defaultConfig) leftRun
  have sameType : type = b' := ty_equal_flat flatType equalTypes
  subst sameType
  -- The link arm, statically: the head's element abstract may be the bottom of dead code.
  have elementShape : FlatAbstract .int element := by
    rcases elementFlat with rfl | rfl
    · exact .bottom _
    · exact .int
  have tailShape : FlatAbstract (.chain .int) (.list roots element certificate) := by
    rcases elementFlat with rfl | rfl
    · exact .chainBottom _ _
    · exact .chainScalar _ _
  have linkAenvBound : ∀ x ∈ ((head, element) :: (tail, .list roots element certificate) :: aenv).map Prod.fst,
      x ∈ head :: tail :: bound := by
    intro x member
    simp only [List.map_cons, List.mem_cons] at member
    rcases member with rfl | rfl | old
    · simp
    · simp
    · exact List.mem_cons_of_mem _ (List.mem_cons_of_mem _ (aenvBound x old))
  obtain ⟨_, linkShape, _⟩ :=
    flat_static (self := self) flatLink ((head, element) :: (tail, .list roots element certificate) :: aenv)
      ((head, .int) :: (tail, .chain .int) :: tenv) {middle with facts := before.facts} last type
      (head :: tail :: bound) after (site ++ [1]) right childFuel _
      ((static.bind tail .chainInt tailShape).bind head .int elementShape) linkTyped linkShadow
      linkAenvBound (by exact defaultConfig) rightRun
  -- The runtime chain.
  cases integers with
  | nil =>
    -- Empty: the end arm, under the same environment.
    have endPreserved := ihEnd (valueTicked vs) (heapTicked hs) env live aenv tenv before middle gamma type
      bound after (site ++ [0]) left childFuel (depth - 1) _ (ticked_invariant inv) endTyped endShadow
      boundKeys endUsesLive afterSub (by exact defaultConfig) leftRun
    refine chainCase_end_preserved inv valueInput heapInput lookup endPreserved ?_ flatType endShape
      linkShape resultEq
    intro origin escaped
    rw [escapesEq]
    exact escaped_mono _ escaped
  | cons n integers =>
    -- Nonempty: the element abstract is the scalar, the heap runtime copies the tail.
    have elementScalar : element = .scalar := by
      rcases elementFlat with rfl | rfl
      · exact absurd (emptyIfBottom rfl) (by simp)
      · rfl
    subst elementScalar
    have endBoundKeys : ∀ (x : Observation) (w : Value) (x' : Observation) (w' : Value),
        ∀ key ∈ ((head, x, w) :: (tail, x', w') :: env).map Prod.fst, key ∈ head :: tail :: bound := by
      intro x w x' w' key member
      simp only [List.map_cons, List.mem_cons] at member
      rcases member with rfl | rfl | old
      · simp
      · simp
      · exact List.mem_cons_of_mem _ (List.mem_cons_of_mem _ (boundKeys key old))
    -- The arm's live sets, through the two binders.
    have tailLiveSub : ∀ use ∈ union (removeVars [head] (uses onLink)) after, use.1 = tail ∨ use ∈ live := by
      intro use member
      by_cases same : use.1 = tail
      · exact Or.inl same
      · right
        rcases mem_union_cases _ _ use member with inner | outer
        · have filtered := List.mem_filter.mp inner
          have notHead : use.1 ≠ head := by
            intro same'
            simp [same'] at filtered
          exact usesLive use (union_right _ _ use (union_right _ _ use
            (List.mem_filter.mpr ⟨filtered.1, by simp [notHead, same]⟩)))
        · exact afterSub use outer
    have headLiveSub : ∀ use ∈ union (uses onLink) after,
        use.1 = head ∨ use ∈ union (removeVars [head] (uses onLink)) after := by
      intro use member
      by_cases same : use.1 = head
      · exact Or.inl same
      · right
        rcases mem_union_cases _ _ use member with inner | outer
        · exact union_left _ _ use (List.mem_filter.mpr ⟨inner, by simp [same]⟩)
        · exact union_right _ _ use outer
    have tailLiveTyped : ∀ p, (tail, p) ∈ union (removeVars [head] (uses onLink)) after →
        ∃ t, tyAt (.chain .int) p = some t := by
      intro p member
      rcases mem_union_cases _ _ (tail, p) member with inner | outer
      · obtain ⟨tk, t, declared, at_p⟩ :=
          flat_uses_typed flatLink _ _ linkTyped tail p (List.mem_filter.mp inner).1
        rw [lookup_cons_other _ _ _ (Ne.symm different), lookup_cons_same] at declared
        cases Option.some.inj declared
        exact ⟨t, at_p⟩
      · exact absurd rfl (noUseTail (tail, p) outer)
    have headLiveTyped : ∀ p, (head, p) ∈ union (uses onLink) after → ∃ t, tyAt .int p = some t := by
      intro p member
      rcases mem_union_cases _ _ (head, p) member with inner | outer
      · obtain ⟨tk, t, declared, at_p⟩ := flat_uses_typed flatLink _ _ linkTyped head p inner
        rw [lookup_cons_same] at declared
        cases Option.some.inj declared
        exact ⟨t, at_p⟩
      · exact absurd rfl (noUseHead (head, p) outer)
    -- The copy of the tail, named by an origin of the input.
    obtain ⟨origin, originMember, _⟩ := rootNamed
    obtain ⟨gamma', invCopy, fresh, _⟩ := tail_post_invariant inv integers origin
    have lookupNew : (heapAllocated hs integers).heap[hs.heap.size]? = some (heapInts integers) := by
      simp [heapAllocated]
    have invTail := flatInvariant_bind invCopy freshTail (corresponds_integer_ref lookupNew)
      (allocated_list_described lookupNew ⟨origin, originMember, fresh⟩) .chainInt tailShape
      (integer_chain_observation_typed declarations integers)
      (allocated_integer_chain_typed declarations lookupNew) (.chainInt _ _ _ _) (.chainScalar _ _ _)
      tailLiveSub tailLiveTyped
    have freshHead' : head ∉ ((tail, .list (valueInts integers), .ref hs.heap.size) :: env).map Prod.fst := by
      intro member
      simp only [List.map_cons, List.mem_cons] at member
      rcases member with same | old
      · exact different same
      · exact freshHead old
    have invLink := flatInvariant_bind invTail freshHead' (AtomPreservation.integer_corresponds n)
      (AtomPreservation.integer_described n) .int .int (by simp [obsTyped])
      ⟨1, .int n, [], .int, by simp [obsTyped]⟩ (.int n) (.int _ _)
      headLiveSub headLiveTyped
    have linkPreserved := ihLink (valueTicked vs) (heapAllocated hs integers)
      ((head, .int n, .int n) :: (tail, .list (valueInts integers), .ref hs.heap.size) :: env)
      (union (uses onLink) after) ((head, .scalar) :: (tail, .list roots .scalar certificate) :: aenv)
      ((head, .int) :: (tail, .chain .int) :: tenv) {middle with facts := before.facts} last gamma' type
      (head :: tail :: bound) after (site ++ [1]) right childFuel (depth - 1) _ invLink linkTyped linkShadow
      (endBoundKeys _ _ _ _) (fun use member => union_left _ _ use member)
      (fun use member => union_right _ _ use member) (by exact defaultConfig) rightRun
    refine chainCase_link_preserved inv valueInput heapInput lookup linkPreserved freshHead freshTail
      different noUseHead noUseTail ?_ flatType linkShape endShape resultEq
    intro origin escaped
    rw [escapesEq]
    exact escaped_subset (fun x member => mem_union _ _ x (Or.inr member)) escaped

end Ownership.FlatFragment.ChainCase
