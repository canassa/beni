import Ownership.FlatFragment.Frame

/-! The first flat fragment: the literal, length, shared, and push expression cases. -/

/-! integer literal expression case under the generic flat relation.
The actual accepted inference run supplies the abstract result and the
unchanged checker state. Both real runtimes allocate or build the list from
the actual atom values. The naming extends at the real allocation address.
No final interpreter agreement or separate permission predicate is assumed.
-/

namespace Ownership.FlatFragment.Literal

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.StateFrame
open Ownership.FlatFragment.Observe Ownership.FlatFragment.Runtime Ownership.FlatFragment.HeapPreservation Ownership.FlatFragment.Description
open Ownership.FlatFragment.Atoms Ownership.FlatFragment.HeapFrame Ownership.FlatFragment.PrimitiveInference Ownership.FlatFragment.PrimitiveRuntime
open Ownership.FlatFragment.Naming Ownership.FlatFragment.Support Ownership.FlatFragment.IntegerCorrespondence

/-! ### Epilogue projections -/

theorem valueObserved_kept (s : ValueSemantics.State) : (valueObserved s).kept = s.kept := by
  unfold valueObserved; split <;> rfl

theorem valueObserved_reads (s : ValueSemantics.State) : (valueObserved s).reads = s.reads := by
  unfold valueObserved; split <;> rfl

theorem valueObserved_fuel (s : ValueSemantics.State) : (valueObserved s).fuel = s.fuel := by
  unfold valueObserved; split <;> rfl

theorem heapObserved_heap (s : State) (observations : List Observation) :
    (heapObserved s observations).heap = s.heap := by
  unfold heapObserved; split <;> rfl

theorem heapObserved_kept (s : State) (observations : List Observation) :
    (heapObserved s observations).kept = s.kept := by
  unfold heapObserved; split <;> rfl

theorem heapObserved_links (s : State) (observations : List Observation) :
    (heapObserved s observations).links = s.links := by
  unfold heapObserved; split <;> rfl

theorem heapObserved_reads (s : State) (observations : List Observation) :
    (heapObserved s observations).reads = s.reads := by
  unfold heapObserved; split <;> rfl

theorem heapObserved_fuel (s : State) (observations : List Observation) :
    (heapObserved s observations).fuel = s.fuel := by
  unfold heapObserved; split <;> rfl

/-- Both epilogues extend the external streams in the same way. -/
theorem observed_external (vs : ValueSemantics.State) (hs : State)
    (sizeEq : vs.kept.size = hs.kept.size) (external : vs.externalReads = hs.externalReads) :
    (valueObserved vs).externalReads = (heapObserved hs vs.kept.toList).externalReads := by
  have emptySame : vs.kept.isEmpty = hs.kept.isEmpty := by
    simp only [Array.isEmpty, sizeEq]
  cases empty : vs.kept.isEmpty with
  | false =>
    have heapEmpty : hs.kept.isEmpty = false := emptySame.symm.trans empty
    simp [valueObserved, heapObserved, empty, heapEmpty, external]
  | true =>
    have heapEmpty : hs.kept.isEmpty = true := emptySame.symm.trans empty
    simp [valueObserved, heapObserved, empty, heapEmpty, external]

/-! ### The checker's literal step -/

theorem primitive_literal_run (ctx : Context) (site : List Nat) (xs : List Abstract)
    (later : List Origin) (before : St) :
    (primitive ctx site (.literal .int) xs later).run before =
      .ok (.list [.site site 0] (xs.foldl Abstract.join .bottom)
        ⟨storeExclusive ctx xs later [], storeSpines ctx xs later []⟩, before) := by
  unfold primitive
  rfl

theorem scalar_fold_flat (atoms : List Atom) (start : Abstract)
    (flat : start = .bottom ∨ start = .scalar) :
    (atoms.map fun _ => Abstract.scalar).foldl Abstract.join start = .bottom ∨
      (atoms.map fun _ => Abstract.scalar).foldl Abstract.join start = .scalar := by
  induction atoms generalizing start with
  | nil => simpa using flat
  | cons _ rest ih =>
    simp only [List.map_cons, List.foldl_cons]
    apply ih
    rcases flat with rfl | rfl <;> simp [Abstract.join]

/-- The actual literal inference: a fresh site root, a flat element, and an
unchanged checker state. -/
theorem infer_literal_success {aenv : Env Abstract} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {args : List Atom}
    (defaultConfig : ctx.config = {})
    (argsRun : args.mapM (m := Except String) (abstractAtom aenv) = .ok (args.map fun _ => Abstract.scalar))
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim (.literal .int) args) after site).run before =
      .ok (result, next)) :
    next = before ∧ ∃ element certificate,
      result = .list [.site site 0] element certificate ∧
      (element = .bottom ∨ element = .scalar) := by
  obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig argsRun accepted
  rw [primitive_literal_run] at run
  have equal := Except.ok.inj run
  refine ⟨(congrArg Prod.snd equal).symm, _, _, (congrArg Prod.fst equal).symm, ?_⟩
  exact scalar_fold_flat args .bottom (Or.inl rfl)

/-! ### The literal expression case -/

def heapAllocated (hs : State) (integers : List Int) : State :=
  {hs with fuel := hs.fuel - 1, heap := hs.heap.push (heapInts integers)}

theorem heap_literal_prim_run (hs : State) (integers : List Int) :
    (prim (.literal .int) (heapInts integers)).run (heapTicked hs) =
      .ok (.ref hs.heap.size, heapAllocated hs integers) := rfl

theorem literal_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {args : List Atom}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueAtoms : args.mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok (valueInts integers))
    (heapAtoms : args.mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok (heapInts integers))
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env)
      (.prim (.literal .int) args)).run vs =
      .ok (.list (valueInts integers), valueObserved (valueTicked vs)) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env)
      (.prim (.literal .int) args)).run hs =
      .ok (.ref hs.heap.size, heapObserved (heapAllocated hs integers) vs.kept.toList) := by
  obtain ⟨footprint, represented⟩ := inv.observers
  have valueObservedRun := value_observeKept_run (valueTicked vs) represented
  have heapObservedRun := heap_observeKept_run (heapAllocated hs integers)
    (representsMany_after_alloc (xs := heapInts integers) represented)
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, value_literal_run, valueObservedRun, Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, heap_literal_prim_run, heapObservedRun, Except.bind, Except.pure, bind, pure]

theorem literal_failure {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {args : List Atom}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueAtoms : args.mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok (valueInts integers))
    (heapAtoms : args.mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok (heapInts integers))
    (failed : (ValueSemantics.eval depth declarations none (valueEnv env)
      (.prim (.literal .int) args)).run vs = .error message) :
    ∃ actualMessage,
      (InPlaceSemantics.eval depth declarations none (heapEnv env)
        (.prim (.literal .int) args)).run hs = .error actualMessage := by
  by_cases noDepth : depth = 0
  · exact ⟨"in-place execution exhausted depth", by
      rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
      simp [noDepth]⟩
  · by_cases noFuel : vs.fuel = 0
    · have heapFuel : hs.fuel = 0 := inv.fuel.symm.trans noFuel
      exact ⟨"in-place execution exhausted fuel", by
        rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
        simp [noDepth, heapFuel]⟩
    · have success := (literal_runtime_success inv valueAtoms heapAtoms noDepth noFuel).1
      rw [success] at failed
      contradiction

/-- The post-relation after a real allocation: the naming extends at the
actual new address, the hole is that address, and no old binding or
observer names it. -/
theorem literal_post_invariant {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (integers : List Int) (site : List Nat) :
    ∃ gamma',
      FlatInvariant declarations (valueObserved (valueTicked vs))
        (heapObserved (heapAllocated hs integers) vs.kept.toList) env live aenv tenv escapes gamma' ∧
      hs.heap.size ∈ gamma' (.site site 0) ∧
      (∀ origin cell, cell < hs.heap.size → (cell ∈ gamma' origin ↔ cell ∈ gamma origin)) := by
  obtain ⟨gamma', extension, bounded, separating, old⟩ :=
    literal_allocation_naming (gamma := gamma) (heapSize := hs.heap.size)
      (fun origin address member => inv.namingBound origin address member) inv.separating site
  obtain ⟨footprint, represented⟩ := inv.observers
  refine ⟨gamma', ?_, (extension (.site site 0) hs.heap.size).mpr (Or.inr ⟨rfl, rfl⟩), old⟩
  have heapEq : (heapObserved (heapAllocated hs integers) vs.kept.toList).heap =
      hs.heap.push (heapInts integers) := by
    rw [heapObserved_heap]; rfl
  refine flatInvariant_heap_frame inv (hole := hs.heap.size) (footprint := footprint)
    (fun _ member => member) ?_ ?_ ?_ ?_ ?_ represented ?_ ?_ ?_ old ?_ separating ?_ ?_ ?_
    (fun _ escaped => escaped)
  · rw [heapEq]; exact flatHeap_after_allocation inv.heapInts integers
  · rw [heapEq]; simp
  · rw [heapObserved_links]; exact inv.links
  · intro c _ different
    rw [heapEq]
    simp [Array.getElem?_push, different]
  · intro x p _ o c binding
    have allocated := inv.binding_allocated binding
    omega
  · intro member
    have bound := representsMany_bound represented _ member
    omega
  · rw [heapObserved_kept]; rfl
  · rw [valueObserved_kept]; rfl
  · rw [heapEq]
    simp only [Array.size_push]
    intro origin address member
    exact bounded origin address member
  · rw [valueObserved_reads, heapObserved_reads]; exact inv.reads
  · exact observed_external (valueTicked vs) (heapAllocated hs integers) inv.keptSize inv.external
  · rw [valueObserved_fuel, heapObserved_fuel]; simp [valueTicked, heapAllocated, inv.fuel]

/-- The literal expression case. Typing fixes the operand types to `Int`;
the live uses supply the operand values; acceptance supplies the result. -/
theorem literal_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {args : List Atom} {self : Decl} {type : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (flat : ∀ atom ∈ args, FlatAtom atom)
    (typed : exprType declarations self tenv (.prim (.literal .int) args) = .ok type)
    (covered : ∀ atom ∈ args, ∀ use ∈ atomUses atom, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim (.literal .int) args) after site).run before =
      .ok (result, next)) :
    type = .list .int ∧ next.facts = before.facts ∧
    (∃ element certificate, result = .list [.site site 0] element certificate ∧
      (element = .bottom ∨ element = .scalar)) ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim (.literal .int) args)).run vs = .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim (.literal .int) args)).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv next.facts.escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧ Describes gamma' hs'.heap result actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim (.literal .int) args)).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim (.literal .int) args)).run hs = .error actualMessage) := by
  obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
  obtain ⟨listType, allInt⟩ := primType_literal_int_success primTyped
  subst listType
  obtain ⟨integers, valueAtoms, heapAtoms, abstractAtoms⟩ :=
    flat_atoms_integers inv flat atomsTyped allInt covered
  obtain ⟨checkerState, element, certificate, resultShape, elementFlat⟩ :=
    infer_literal_success defaultConfig abstractAtoms accepted
  subst checkerState
  refine ⟨rfl, rfl, ⟨element, certificate, resultShape, elementFlat⟩, ?_, ?_⟩
  · intro value vs' run
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
      simp [noDepth] at run
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
        simp [noDepth, noFuel] at run
      · obtain ⟨valueRun, heapRun⟩ := literal_runtime_success inv valueAtoms heapAtoms noDepth noFuel
        rw [valueRun] at run
        cases run
        obtain ⟨gamma', postInvariant, fresh, _⟩ := literal_post_invariant inv integers site
        have heapEq : (heapObserved (heapAllocated hs integers) vs.kept.toList).heap =
            hs.heap.push (heapInts integers) := by
          rw [heapObserved_heap]; rfl
        have lookupNew : (heapObserved (heapAllocated hs integers) vs.kept.toList).heap[hs.heap.size]? =
            some (heapInts integers) := by
          rw [heapEq]; simp
        refine ⟨.ref hs.heap.size, heapObserved (heapAllocated hs integers) vs.kept.toList, gamma',
          heapRun, postInvariant, ?_, ?_, ?_, ?_, ?_⟩
        · rw [heapEq]; simp
        · exact corresponds_integer_ref lookupNew
        · rw [resultShape]
          exact allocated_list_described lookupNew ⟨.site site 0, by simp, fresh⟩
        · exact integer_list_observation_typed declarations integers
        · exact allocated_integer_list_typed declarations lookupNew
  · intro message failed
    exact literal_failure inv valueAtoms heapAtoms failed

end Ownership.FlatFragment.Literal

/-! length expression case under the generic flat relation.
The receiver is a live flat list binding. Both runtimes read the same
length. The checker records a read and returns a scalar. The heap, the
observers, and the naming stay unchanged.
-/

namespace Ownership.FlatFragment.Length

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.StateFrame
open Ownership.FlatFragment.Observe Ownership.FlatFragment.Runtime Ownership.FlatFragment.HeapPreservation
open Ownership.FlatFragment.Atoms Ownership.FlatFragment.AtomInteger Ownership.FlatFragment.PrimitiveInference Ownership.FlatFragment.PrimitiveRuntime
open Ownership.FlatFragment.Literal Ownership.FlatFragment.Support

theorem modifyFacts_run (f : Summary → Summary) (before : St) :
    (modifyFacts f).run before = .ok ((), {before with facts := f before.facts}) := rfl

theorem primitive_length_run (ctx : Context) (site : List Nat) (a : Abstract)
    (later : List Origin) (before : St) :
    (primitive ctx site .length [a] later).run before =
      .ok (.scalar, {before with facts :=
        {before.facts with reads := union before.facts.reads (a.roots.filter external)}}) := by
  unfold primitive
  rfl

theorem flat_atom_type {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {atom : Atom} {ty : Ty} {escapes : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (flat : FlatAtom atom) (typed : atomType tenv atom = .ok ty) : FlatType ty := by
  cases flat with
  | int _ =>
    change Except.ok Ty.int = Except.ok ty at typed
    cases Except.ok.inj typed
    exact .int
  | var key =>
    have typeRun : lookup tenv key = .ok ty := by simpa only [atomType] using typed
    exact inv.types key ty (lookup_option_of_success typeRun)

theorem primType_length_success {type : Ty} {ty : Ty} (flat : FlatType ty) (run : primType .length [ty] = .ok type) :
    ty = .list .int ∧ type = .int := by
  cases flat with
  | int => simp [primType] at run
  | listInt =>
    simp [primType] at run
    change Except.ok Ty.int = Except.ok type at run
    cases Except.ok.inj run
    exact ⟨rfl, rfl⟩

/-- The single-operand typing equation of a length expression. -/
theorem exprType_length_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {receiver : Atom} {self : Decl} {type : Ty} {escapes : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (flat : FlatAtom receiver)
    (typed : exprType declarations self tenv (.prim .length [receiver]) = .ok type) :
    atomType tenv receiver = .ok (.list .int) ∧ type = .int := by
  obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
  obtain ⟨headType, rest, headTyped, restTyped, shape⟩ := except_mapM_cons_success atomsTyped
  have restNil := except_mapM_nil_success restTyped
  subst shape
  subst restNil
  obtain ⟨listType, intType⟩ := primType_length_success (flat_atom_type inv flat headTyped) primTyped
  subst listType
  exact ⟨headTyped, intType⟩

theorem value_length_run (s : ValueSemantics.State) (integers : List Int) :
    (ValueSemantics.prim .length [.list (valueInts integers)]).run s =
      .ok (.int integers.length, {s with reads := s.reads.push (.int integers.length)}) := by
  simp [ValueSemantics.prim, ValueSemantics.read, ValueSemantics.observable, Observation.depth,
    observationDepth, valueInts, StateT.run, StateT.bind, StateT.map, StateT.get, StateT.set,
    StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe,
    MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, modify,
    modifyGet, MonadStateOf.modifyGet, StateT.modifyGet]

theorem heap_length_run (s : State) (integers : List Int)
    (lookup : s.heap[root]? = some (heapInts integers)) :
    (prim .length [.ref root]).run s =
      .ok (.int integers.length, {s with reads := s.reads.push (.int integers.length)}) := by
  simp [prim, array, lookup, InPlaceSemantics.read, snapshot, observationDepth, heapInts,
    Option.toExcept, StateT.run, StateT.bind, StateT.map, StateT.get, StateT.set,
    StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe,
    MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, modify,
    modifyGet, MonadStateOf.modifyGet, StateT.modifyGet]

def valueRead (vs : ValueSemantics.State) (observation : Observation) : ValueSemantics.State :=
  valueObserved {vs with fuel := vs.fuel - 1, reads := vs.reads.push observation}

def heapRead (hs : State) (observation : Observation) (observations : List Observation) : State :=
  heapObserved {hs with fuel := hs.fuel - 1, reads := hs.reads.push observation} observations

theorem read_post_invariant {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {escapes : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (observation : Observation) :
    FlatInvariant declarations (valueRead vs observation) (heapRead hs observation vs.kept.toList)
      env live aenv tenv escapes gamma := by
  apply flatInvariant_state_frame inv
  · unfold heapRead; rw [heapObserved_heap]
  · unfold heapRead; rw [heapObserved_links]
  · unfold valueRead; rw [valueObserved_kept]
  · unfold heapRead; rw [heapObserved_kept]
  · unfold valueRead heapRead; rw [valueObserved_reads, heapObserved_reads]; simp [inv.reads]
  · exact observed_external _ _ inv.keptSize inv.external
  · unfold valueRead heapRead; rw [valueObserved_fuel, heapObserved_fuel]; simp [inv.fuel]

theorem length_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {receiver : Atom} {escapes : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueAtom : ValueSemantics.atom (valueEnv env) receiver = .ok (.list (valueInts integers)))
    (heapAtom : InPlaceSemantics.atom (heapEnv env) receiver = .ok (.ref root))
    (lookup : hs.heap[root]? = some (heapInts integers))
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim .length [receiver])).run vs =
      .ok (.int integers.length, valueRead vs (.int integers.length)) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim .length [receiver])).run hs =
      .ok (.int integers.length, heapRead hs (.int integers.length) vs.kept.toList) := by
  obtain ⟨footprint, represented⟩ := inv.observers
  have valueObservedRun := value_observeKept_run
    ({vs with fuel := vs.fuel - 1, reads := vs.reads.push (.int integers.length)}) represented
  have heapObservedRun := heap_observeKept_run
    ({hs with fuel := hs.fuel - 1, reads := hs.reads.push (.int integers.length)}) represented
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have valueAtoms : [receiver].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.list (valueInts integers)] := except_mapM_cons valueAtom rfl
  have heapAtoms : [receiver].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref root] := except_mapM_cons heapAtom rfl
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, valueTicked, value_length_run, valueObservedRun, valueRead,
      Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, heapTicked, heap_length_run {hs with fuel := hs.fuel - 1} integers lookup,
      heapObservedRun, heapRead,
      Except.bind, Except.pure, bind, pure]

theorem length_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {receiver : Atom} {self : Decl} {type : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (flat : FlatAtom receiver)
    (typed : exprType declarations self tenv (.prim .length [receiver]) = .ok type)
    (covered : ∀ use ∈ atomUses receiver, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim .length [receiver]) after site).run before =
      .ok (result, next)) :
    type = .int ∧ next.facts.escapes = before.facts.escapes ∧ result = .scalar ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .length [receiver])).run vs = .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .length [receiver])).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv next.facts.escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧ Describes gamma' hs'.heap result actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .length [receiver])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .length [receiver])).run hs = .error actualMessage) := by
  obtain ⟨receiverTyped, intType⟩ := exprType_length_success inv flat typed
  subst intType
  obtain ⟨key, root, integers, roots, element, certificate, _, _, _, _, lookup, _, _,
    valueAtom, heapAtom, abstractReceiver⟩ := flat_atom_list inv flat receiverTyped covered
  have abstractAtoms : [receiver].mapM (m := Except String) (abstractAtom aenv) =
      .ok [.list roots element certificate] := except_mapM_cons abstractReceiver rfl
  obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  rw [primitive_length_run] at run
  have equal := Except.ok.inj run
  have resultScalar : result = .scalar := (congrArg Prod.fst equal).symm
  have nextState : next = {before with facts := {before.facts with
      reads := union before.facts.reads ((Abstract.list roots element certificate).roots.filter external)}} :=
    (congrArg Prod.snd equal).symm
  have nextEscapes : next.facts.escapes = before.facts.escapes := by
    subst nextState; rfl
  refine ⟨rfl, nextEscapes, resultScalar, ?_, ?_⟩
  · intro value vs' run
    have valueAtoms : [receiver].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
        .ok [.list (valueInts integers)] := except_mapM_cons valueAtom rfl
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
      simp [noDepth] at run
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
        simp [noDepth, noFuel] at run
      · obtain ⟨valueRun, heapRun⟩ :=
          length_runtime_success inv valueAtom heapAtom lookup noDepth noFuel
        rw [valueRun] at run
        cases run
        refine ⟨.int integers.length, heapRead hs (.int integers.length) vs.kept.toList, gamma,
          heapRun, ?_, ?_, Ownership.FlatFragment.AtomPreservation.integer_corresponds _, ?_, by simp [obsTyped],
          ⟨1, .int integers.length, [], .int, by simp [obsTyped]⟩⟩
        · rw [nextEscapes]; exact read_post_invariant inv _
        · exact Nat.le_of_eq (by unfold heapRead; rw [heapObserved_heap])
        · rw [resultScalar]; exact Ownership.FlatFragment.AtomPreservation.integer_described _
  · intro message failed
    have valueAtoms : [receiver].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
        .ok [.list (valueInts integers)] := except_mapM_cons valueAtom rfl
    have heapAtoms : [receiver].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
        .ok [.ref root] := except_mapM_cons heapAtom rfl
    by_cases noDepth : depth = 0
    · exact ⟨"in-place execution exhausted depth", by
        rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
        simp [noDepth]⟩
    · by_cases noFuel : vs.fuel = 0
      · have heapFuel : hs.fuel = 0 := inv.fuel.symm.trans noFuel
        exact ⟨"in-place execution exhausted fuel", by
          rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
          simp [noDepth, heapFuel]⟩
      · have success := (length_runtime_success inv valueAtom heapAtom lookup noDepth noFuel).1
        rw [success] at failed
        contradiction

end Ownership.FlatFragment.Length

/-! shared expression case under the generic flat relation.
The checker records the value's cells as escapes and marks the result shared.
Both runtimes register the value as a permanent observer. The heap and the
naming stay unchanged. The new observer's array is named only by origins
that alias one of the value's roots, which the checker now records as
escaped. No final interpreter agreement is assumed.
-/

namespace Ownership.FlatFragment.Shared

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.StateFrame
open Ownership.FlatFragment.Observe Ownership.FlatFragment.Runtime Ownership.FlatFragment.HeapPreservation Ownership.FlatFragment.Description
open Ownership.FlatFragment.Atoms Ownership.FlatFragment.AtomInteger Ownership.FlatFragment.PrimitiveInference Ownership.FlatFragment.PrimitiveRuntime
open Ownership.FlatFragment.Literal Ownership.FlatFragment.Length Ownership.FlatFragment.LiveCells
open Ownership.FlatFragment.RepresentsDepth Ownership.FlatFragment.HeapFrame Ownership.FlatFragment.CheckerExtraction
open Ownership.FlatFragment.IntegerCorrespondence Ownership.FlatFragment.Support

local instance stepReflBEq : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance stepLawfulBEq : LawfulBEq Step := LawfulBEq.mk (by deriving_LawfulEq_tactic)
local instance originReflBEq : ReflBEq Origin := ⟨by deriving_ReflEq_tactic⟩
local instance originLawfulBEq : LawfulBEq Origin := LawfulBEq.mk (by deriving_LawfulEq_tactic)

/-! ### Origins and escapes -/

theorem base_base (origin : Origin) : origin.base.base = origin.base := by
  induction origin with
  | position _ _ inner ih => simpa [Origin.base] using ih
  | _ => rfl

theorem base_not_position (origin : Origin) (scope : List Nat) (current : Bool) (inner : Origin) :
    origin.base ≠ .position scope current inner := by
  induction origin with
  | position _ _ inner ih => simpa [Origin.base] using ih
  | _ => simp [Origin.base]

theorem aliases_true_base {a : Origin} {b : Origin} (equal : aliases a b = true) : (a.base == b.base) = true := by
  unfold aliases at equal
  split at equal
  · split at equal
    · contradiction
    · simpa [Origin.base] using equal
  · exact equal

theorem aliases_of_base {a : Origin} {b : Origin} (equal : (a.base == b.base) = true) : aliases a.base b.base = true := by
  unfold aliases
  split
  · rename_i scope current inner _ _ _ found _
    exact absurd found (base_not_position a scope current inner)
  · simpa [base_base] using equal

theorem escaped_mono {escapes : List Origin} {origin : Origin} (more : List Origin) (escaped : Escaped escapes origin) :
    Escaped (union escapes more) origin := by
  rcases escaped with shared | overlap
  · exact Or.inl shared
  · right
    obtain ⟨x, xMember, inner⟩ := List.any_eq_true.mp overlap
    obtain ⟨y, yMember, same⟩ := List.any_eq_true.mp inner
    obtain ⟨witness, witnessMember, rfl⟩ := List.mem_map.mp yMember
    refine List.any_eq_true.mpr ⟨x, xMember, List.any_eq_true.mpr ⟨witness.base, ?_, same⟩⟩
    exact List.mem_map.mpr ⟨witness, mem_union escapes more witness (Or.inl witnessMember), rfl⟩

theorem roots_in_cells {origin : Origin} {roots : List Origin} {element : Abstract} {certificate : Certificate} (member : origin ∈ roots) :
    origin ∈ (Abstract.list roots element certificate).cells := by
  unfold Abstract.cells
  simp only [Abstract.paths, List.foldl_cons]
  apply foldl_mono (fun cs (entry : Path × List Origin) => union cs entry.2)
    (fun cs entry o present => mem_union cs entry.2 o (Or.inl present))
  exact mem_union [] roots origin (Or.inr member)

/-- An origin that names the shared array aliases one of its abstract
roots, and that root is now a recorded escape. -/
theorem named_root_escaped {gamma : Naming} {escapes : List Origin} {origin : Origin} {roots : List Origin} {element : Abstract} {certificate : Certificate} (separating : Separating gamma)
    (names : named gamma roots root) (member : root ∈ gamma origin) :
    Escaped (union escapes (Abstract.list roots element certificate).cells) origin := by
  obtain ⟨witness, witnessMember, address⟩ := names
  have alias : aliases origin witness = true := by
    cases equal : aliases origin witness with
    | true => rfl
    | false => exact absurd address (separating origin witness equal root member)
  have baseEqual := aliases_true_base alias
  right
  refine List.any_eq_true.mpr ⟨origin.base, by simp, List.any_eq_true.mpr ⟨witness.base, ?_, aliases_of_base baseEqual⟩⟩
  exact List.mem_map.mpr ⟨witness, mem_union escapes _ witness (Or.inr (roots_in_cells witnessMember)), rfl⟩

/-! ### The checker's shared step -/

theorem default_has (mutant : Mutant) : ({} : Config).has mutant = false := by
  simp [Config.has]

theorem primitive_shared_run (ctx : Context) (defaultConfig : ctx.config = {}) (site : List Nat)
    (a : Abstract) (later : List Origin) (before : St) :
    (primitive ctx site .shared [a] later).run before =
      .ok (a.mapOrigins fun _ cs => if cs.isEmpty then [] else union cs [.shared],
        {before with facts := {before.facts with escapes := union before.facts.escapes a.cells}}) := by
  unfold primitive
  simp only [defaultConfig, default_has, Bool.false_eq_true, if_false]
  rfl

theorem scalar_mapOrigins (f : Path → List Origin → List Origin) (path : Path) :
    Abstract.scalar.mapOrigins f path = .scalar := by
  simp [Abstract.mapOrigins]

theorem bottom_mapOrigins (f : Path → List Origin → List Origin) (path : Path) :
    Abstract.bottom.mapOrigins f path = .bottom := by
  simp [Abstract.mapOrigins]

theorem flat_list_shared (roots : List Origin) (element : Abstract) (certificate : Certificate)
    (flat : element = .bottom ∨ element = .scalar) (nonempty : roots ≠ []) :
    (Abstract.list roots element certificate).mapOrigins
        (fun _ cs => if cs.isEmpty then [] else union cs [.shared]) [] =
      .list (union roots [.shared]) element certificate := by
  rcases flat with rfl | rfl <;> simp [Abstract.mapOrigins, nonempty]

/-! ### Runtime -/

theorem value_shared_run (s : ValueSemantics.State) (x : Observation) :
    (ValueSemantics.prim .shared [x]).run s = .ok (x, {s with kept := s.kept.push x}) := rfl

theorem heap_shared_run (s : State) (v : Value) :
    (prim .shared [v]).run s = .ok (v, {s with kept := s.kept.push v}) := rfl

def valueShared (vs : ValueSemantics.State) (x : Observation) : ValueSemantics.State :=
  valueObserved {vs with fuel := vs.fuel - 1, kept := vs.kept.push x}

def heapShared (hs : State) (v : Value) (observations : List Observation) : State :=
  heapObserved {hs with fuel := hs.fuel - 1, kept := hs.kept.push v} observations

theorem shared_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {atom : Atom} {escapes : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueAtom : ValueSemantics.atom (valueEnv env) atom = .ok x)
    (heapAtom : InPlaceSemantics.atom (heapEnv env) atom = .ok v)
    (witness : Represents hs.heap observationDepth v x cells)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim .shared [atom])).run vs =
      .ok (x, valueShared vs x) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim .shared [atom])).run hs =
      .ok (v, heapShared hs v (vs.kept.toList ++ [x])) := by
  obtain ⟨footprint, represented⟩ := inv.observers
  have appended := representsMany_append represented (RepresentsMany.cons witness .nil)
  have valueObservedRun := value_observeKept_run (heap := hs.heap)
    ({vs with fuel := vs.fuel - 1, kept := vs.kept.push x}) (by rw [Array.toList_push]; exact appended)
  have heapObservedRun := heap_observeKept_run
    ({hs with fuel := hs.fuel - 1, kept := hs.kept.push v}) (by rw [Array.toList_push]; exact appended)
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have valueAtoms : [atom].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [x] := except_mapM_cons valueAtom rfl
  have heapAtoms : [atom].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [v] := except_mapM_cons heapAtom rfl
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, valueTicked, value_shared_run, valueObservedRun, valueShared,
      Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, heapTicked, heap_shared_run, heapObservedRun, heapShared,
      Except.bind, Except.pure, bind, pure]

theorem shared_post_invariant {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {escapes : List Origin} {escapes' : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (witness : Represents hs.heap observationDepth v x cells)
    (escapesMono : ∀ origin, Escaped escapes origin → Escaped escapes' origin)
    (newEscaped : ∀ c, Reaches hs.heap v (.ref c) → ∀ origin, c ∈ gamma origin → Escaped escapes' origin) :
    FlatInvariant declarations (valueShared vs x) (heapShared hs v (vs.kept.toList ++ [x]))
      env live aenv tenv escapes' gamma := by
  obtain ⟨footprint, represented⟩ := inv.observers
  have appended := representsMany_append represented (RepresentsMany.cons witness .nil)
  have heapSame : (heapShared hs v (vs.kept.toList ++ [x])).heap = hs.heap := by
    unfold heapShared; rw [heapObserved_heap]
  have heapKept : (heapShared hs v (vs.kept.toList ++ [x])).kept = hs.kept.push v := by
    unfold heapShared; rw [heapObserved_kept]
  have valueKept : (valueShared vs x).kept = vs.kept.push x := by
    unfold valueShared; rw [valueObserved_kept]
  have witnessList : RepresentsMany (heapShared hs v (vs.kept.toList ++ [x])).heap observationDepth
      (heapShared hs v (vs.kept.toList ++ [x])).kept.toList (valueShared vs x).kept.toList
      (footprint ++ (cells ++ [])) := by
    rw [heapSame, heapKept, valueKept, Array.toList_push, Array.toList_push]
    exact appended
  refine {
    toInvariant := {
      reads := by unfold valueShared heapShared; rw [valueObserved_reads, heapObserved_reads]; exact inv.reads
      external := ?_
      fuel := by unfold valueShared heapShared; rw [valueObserved_fuel, heapObserved_fuel]; simp [inv.fuel]
      keptSize := by rw [heapKept, valueKept]; simp [inv.keptSize]
      kept := ?_
      keptEscaped := ?_
      bindings := by simpa only [heapSame] using inv.bindings
      described := by simpa only [heapSame] using inv.described
      named := by simpa only [heapSame] using inv.named
      separating := inv.separating
      linksValid := Soundness.linksValid_of_empty _ (by unfold heapShared; rw [heapObserved_links]; exact inv.links)
      linkNamed := Soundness.linkNamed_of_empty _ _ _ _ (by unfold heapShared; rw [heapObserved_links]; exact inv.links)
    }
    heapInts := by rw [heapSame]; exact inv.heapInts
    links := by unfold heapShared; rw [heapObserved_links]; exact inv.links
    abstractKeys := inv.abstractKeys
    typeKeys := inv.typeKeys
    types := inv.types
    abstractShapes := inv.abstractShapes
    bindingsTyped := by simpa only [heapSame] using inv.bindingsTyped
    namingBound := by rw [heapSame]; exact inv.namingBound
    observers := ⟨_, witnessList⟩
  }
  · unfold valueShared heapShared valueObserved heapObserved
    simp [Array.isEmpty, Array.size_push, inv.external]
  · intro i o w valueAt heapAt
    have valueList : (valueShared vs x).kept.toList[i]? = some o := by simpa using valueAt
    have heapList : (heapShared hs v (vs.kept.toList ++ [x])).kept.toList[i]? = some w := by
      simpa using heapAt
    obtain ⟨cells', found⟩ := representsMany_index _ witnessList heapList valueList
    rw [heapSame] at found
    rw [heapSame]
    exact corresponds_of_represents found
  · intro k member c reachable origin names
    rw [heapKept, Array.toList_push] at member
    rw [heapSame] at reachable
    rcases List.mem_append.mp member with old | new
    · exact escapesMono origin (inv.keptEscaped k old c reachable origin names)
    · have same : k = v := by simpa using new
      subst same
      exact newEscaped c reachable origin names

/-! ### The shared expression case -/

theorem primType_shared_success {type : Ty} {ty : Ty} (run : primType .shared [ty] = .ok type) : type = ty := by
  simp [primType] at run
  change Except.ok ty = Except.ok type at run
  exact (Except.ok.inj run).symm

theorem exprType_shared_success {declarations : List Decl} {tenv : Env Ty} {atom : Atom} {self : Decl} {type : Ty}
    (typed : exprType declarations self tenv (.prim .shared [atom]) = .ok type) :
    atomType tenv atom = .ok type := by
  obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
  obtain ⟨headType, rest, headTyped, restTyped, shape⟩ := except_mapM_cons_success atomsTyped
  have restNil := except_mapM_nil_success restTyped
  subst shape
  subst restNil
  rw [primType_shared_success primTyped]
  exact headTyped

theorem int_reaches_nothing (reachable : Reaches heap (.int integer) (.ref c)) : False := by
  cases reachable

theorem flat_ref_reaches (lookup : heap[root]? = some (heapInts integers))
    (reachable : Reaches heap (.ref root) (.ref c)) : c = root := by
  cases reachable with
  | refl => rfl
  | element found member child =>
    rw [lookup] at found
    cases found
    obtain ⟨integer, _, rfl⟩ := List.mem_map.mp member
    exact (int_reaches_nothing child).elim

theorem shared_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {atom : Atom} {self : Decl} {type : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (flat : FlatAtom atom)
    (typed : exprType declarations self tenv (.prim .shared [atom]) = .ok type)
    (covered : ∀ use ∈ atomUses atom, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim .shared [atom]) after site).run before =
      .ok (result, next)) :
    FlatType type ∧ FlatAbstract type result ∧
    (∀ origin, Escaped before.facts.escapes origin → Escaped next.facts.escapes origin) ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .shared [atom])).run vs = .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .shared [atom])).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv next.facts.escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧ Describes gamma' hs'.heap result actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .shared [atom])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .shared [atom])).run hs = .error actualMessage) := by
  have atomTyped := exprType_shared_success typed
  have flatType := flat_atom_type inv flat atomTyped
  cases flatType with
  | int =>
    obtain ⟨integer, valueAtom, heapAtom, abstractValue⟩ := flat_atom_integer inv flat atomTyped covered
    have abstractAtoms : [atom].mapM (m := Except String) (abstractAtom aenv) = .ok [.scalar] :=
      except_mapM_cons abstractValue rfl
    obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
    rw [primitive_shared_run {ctx with escaped := union ctx.escaped before.facts.escapes} defaultConfig] at run
    have equal := Except.ok.inj run
    have first : Abstract.scalar.mapOrigins (fun _ cs => if cs.isEmpty then [] else union cs [.shared]) =
        result := congrArg Prod.fst equal
    have second : next = {before with facts := {before.facts with
        escapes := union before.facts.escapes Abstract.scalar.cells}} := (congrArg Prod.snd equal).symm
    have resultEq : result = .scalar := by
      rw [← first]; exact scalar_mapOrigins _ _
    have escapesEq : next.facts.escapes = before.facts.escapes := by
      have grown : next.facts.escapes = union before.facts.escapes Abstract.scalar.cells :=
        congrArg (fun s : St => s.facts.escapes) second
      rw [grown]
      simp [Abstract.cells, Abstract.paths, union]
    have witness : Represents hs.heap observationDepth (.int integer) (.int integer) [] := .int
    refine ⟨.int, by rw [resultEq]; exact .int, by rw [escapesEq]; exact fun _ e => e, ?_, ?_⟩
    · intro value vs' run
      have valueAtoms : [atom].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
          .ok [.int integer] := except_mapM_cons valueAtom rfl
      by_cases noDepth : depth = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
        simp [noDepth] at run
      · by_cases noFuel : vs.fuel = 0
        · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
          simp [noDepth, noFuel] at run
        · obtain ⟨valueRun, heapRun⟩ :=
            shared_runtime_success inv valueAtom heapAtom witness noDepth noFuel
          rw [valueRun] at run
          cases run
          refine ⟨.int integer, heapShared hs (.int integer) (vs.kept.toList ++ [.int integer]), gamma,
            heapRun, ?_, ?_, Ownership.FlatFragment.AtomPreservation.integer_corresponds _, ?_, by simp [obsTyped],
            ⟨1, .int integer, [], .int, by simp [obsTyped]⟩⟩
          · rw [escapesEq]
            exact shared_post_invariant inv witness (fun _ e => e)
              (fun c reachable => (int_reaches_nothing reachable).elim)
          · exact Nat.le_of_eq (by unfold heapShared; rw [heapObserved_heap])
          · rw [resultEq]; exact Ownership.FlatFragment.AtomPreservation.integer_described _
    · intro message failed
      have heapAtoms : [atom].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
          .ok [.int integer] := except_mapM_cons heapAtom rfl
      by_cases noDepth : depth = 0
      · exact ⟨"in-place execution exhausted depth", by
          rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
          simp [noDepth]⟩
      · by_cases noFuel : vs.fuel = 0
        · have heapFuel : hs.fuel = 0 := inv.fuel.symm.trans noFuel
          exact ⟨"in-place execution exhausted fuel", by
            rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
            simp [noDepth, heapFuel]⟩
        · have success := (shared_runtime_success inv valueAtom heapAtom witness noDepth noFuel).1
          rw [success] at failed
          contradiction
  | listInt =>
    obtain ⟨key, root, integers, roots, element, certificate, _, _, _, _, lookup, names, elementFlat,
      valueAtom, heapAtom, abstractValue⟩ := flat_atom_list inv flat atomTyped covered
    have abstractAtoms : [atom].mapM (m := Except String) (abstractAtom aenv) =
        .ok [.list roots element certificate] := except_mapM_cons abstractValue rfl
    obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
    rw [primitive_shared_run {ctx with escaped := union ctx.escaped before.facts.escapes} defaultConfig] at run
    have equal := Except.ok.inj run
    have nonempty : roots ≠ [] := by
      obtain ⟨witness, member, _⟩ := names
      intro nil
      subst nil
      simp at member
    have first : (Abstract.list roots element certificate).mapOrigins
        (fun _ cs => if cs.isEmpty then [] else union cs [.shared]) = result := congrArg Prod.fst equal
    have second : next = {before with facts := {before.facts with
        escapes := union before.facts.escapes (Abstract.list roots element certificate).cells}} :=
      (congrArg Prod.snd equal).symm
    have resultEq : result = .list (union roots [.shared]) element certificate := by
      rw [← first]; exact flat_list_shared roots element certificate elementFlat nonempty
    have escapesEq : next.facts.escapes =
        union before.facts.escapes (Abstract.list roots element certificate).cells :=
      congrArg (fun s : St => s.facts.escapes) second
    have witness : Represents hs.heap observationDepth (.ref root) (.list (valueInts integers)) [root] :=
      .ref lookup (integers_represented integers (observationDepth - 2))
    have resultFlat : FlatAbstract (.list .int) result := by
      rw [resultEq]
      rcases elementFlat with rfl | rfl
      · exact .listBottom _ _
      · exact .listScalar _ _
    have mono : ∀ origin, Escaped before.facts.escapes origin → Escaped next.facts.escapes origin := by
      intro origin escaped
      rw [escapesEq]
      exact escaped_mono _ escaped
    have resultNamed : named gamma (union roots [.shared]) root := by
      obtain ⟨witness, member, address⟩ := names
      exact ⟨witness, mem_union roots [.shared] witness (Or.inl member), address⟩
    refine ⟨.listInt, resultFlat, mono, ?_, ?_⟩
    · intro value vs' run
      have valueAtoms : [atom].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
          .ok [.list (valueInts integers)] := except_mapM_cons valueAtom rfl
      by_cases noDepth : depth = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
        simp [noDepth] at run
      · by_cases noFuel : vs.fuel = 0
        · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
          simp [noDepth, noFuel] at run
        · obtain ⟨valueRun, heapRun⟩ :=
            shared_runtime_success inv valueAtom heapAtom witness noDepth noFuel
          rw [valueRun] at run
          cases run
          have heapSame : (heapShared hs (.ref root) (vs.kept.toList ++ [.list (valueInts integers)])).heap = hs.heap := by
            unfold heapShared; rw [heapObserved_heap]
          refine ⟨.ref root, heapShared hs (.ref root) (vs.kept.toList ++ [.list (valueInts integers)]), gamma,
            heapRun, ?_, Nat.le_of_eq (congrArg Array.size heapSame.symm), ?_, ?_,
            integer_list_observation_typed declarations integers, ?_⟩
          · exact shared_post_invariant inv witness mono (fun c reachable origin member => by
              rw [flat_ref_reaches lookup reachable] at member
              rw [escapesEq]
              exact named_root_escaped inv.separating names member)
          · rw [heapSame]; exact corresponds_integer_ref lookup
          · rw [heapSame, resultEq]; exact allocated_list_described lookup resultNamed
          · rw [heapSame]; exact allocated_integer_list_typed declarations lookup
    · intro message failed
      have heapAtoms : [atom].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
          .ok [.ref root] := except_mapM_cons heapAtom rfl
      by_cases noDepth : depth = 0
      · exact ⟨"in-place execution exhausted depth", by
          rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
          simp [noDepth]⟩
      · by_cases noFuel : vs.fuel = 0
        · have heapFuel : hs.fuel = 0 := inv.fuel.symm.trans noFuel
          exact ⟨"in-place execution exhausted fuel", by
            rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
            simp [noDepth, heapFuel]⟩
        · have success := (shared_runtime_success inv valueAtom heapAtom witness noDepth noFuel).1
          rw [success] at failed
          contradiction

end Ownership.FlatFragment.Shared

/-! push expression case under the generic flat relation.
The actual accepted inference runs the real default demand on the receiver's
roots. That demand excludes every live binding of the continuation and every
permanent observer from the written array. Both runtimes append the same
integer. The naming stays unchanged; the written array keeps its names.
No final interpreter agreement or separate permission predicate is assumed.
-/

namespace Ownership.FlatFragment.Push

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.StateFrame
open Ownership.FlatFragment.Observe Ownership.FlatFragment.Runtime Ownership.FlatFragment.HeapPreservation Ownership.FlatFragment.Description
open Ownership.FlatFragment.Atoms Ownership.FlatFragment.AtomInteger Ownership.FlatFragment.PrimitiveInference Ownership.FlatFragment.PrimitiveRuntime
open Ownership.FlatFragment.Literal Ownership.FlatFragment.Length Ownership.FlatFragment.LiveCells
open Ownership.FlatFragment.RepresentsDepth Ownership.FlatFragment.HeapFrame Ownership.FlatFragment.CheckerExtraction
open Ownership.FlatFragment.IntegerCorrespondence Ownership.FlatFragment.Support Ownership.FlatFragment.PushRuntime Ownership.FlatFragment.NamingFacts
open Ownership.FlatFragment.Scope Ownership.FlatFragment.Shared

local instance stepReflBEq : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance stepLawfulBEq : LawfulBEq Step := LawfulBEq.mk (by deriving_LawfulEq_tactic)
local instance originReflBEq : ReflBEq Origin := ⟨by deriving_ReflEq_tactic⟩
local instance originLawfulBEq : LawfulBEq Origin := LawfulBEq.mk (by deriving_LawfulEq_tactic)

/-! ### The checker's push step -/

theorem demand_run_none {before : St} {cs : List Origin} {later : List Origin} {others : List Origin}
    (problem : demandProblem ({} : Config) before.facts.escapes cs later others = none) :
    (demand ({} : Config) cs later others).run before =
      .ok ((), {before with facts :=
        {before.facts with writes := union before.facts.writes (cs.filter external)}}) := by
  dsimp [demand, getFacts, StateT.run, StateT.bind, StateT.map, StateT.get]
  simp only [pure_bind]
  rw [problem]
  rfl

theorem demand_success_escapes {before : St} {next : St} {cs : List Origin} {later : List Origin} {others : List Origin}
    (run : (demand ({} : Config) cs later others).run before = .ok ((), next)) :
    next.facts.escapes = before.facts.escapes := by
  rw [demand_run_none (demand_success_problem run)] at run
  have equal := Except.ok.inj run
  have same : next = {before with facts :=
      {before.facts with writes := union before.facts.writes (cs.filter external)}} :=
    (congrArg Prod.snd equal).symm
  subst same
  rfl

theorem primitive_push_result {ctx : Context} {site : List Nat} {before : St} {next : St} {result : Abstract} {roots : List Origin} {later : List Origin} {element : Abstract} {certificate : Certificate}
    (run : (primitive ctx site .push [.list roots element certificate, .scalar] later).run before =
      .ok (result, next)) :
    ∃ certificate', result = .list roots (element.join .scalar) certificate' := by
  unfold primitive at run
  obtain ⟨finished, middle, _, returned⟩ := checkM_bind_success run
  cases finished
  have equal := Except.ok.inj returned
  have first : _ = result := congrArg Prod.fst equal
  rw [← first]
  exact ⟨_, by simp [Abstract.grantExclusive] <;> rfl⟩

theorem liveCellsWith_default (env : Env Abstract) (l : Live) :
    liveCellsWith ({} : Config) env l = liveCells env l := by
  simp [liveCellsWith, default_has]

theorem flat_join_scalar {element : Abstract} (flat : element = .bottom ∨ element = .scalar) :
    element.join .scalar = .scalar := by
  rcases flat with rfl | rfl <;> simp [Abstract.join]

theorem primType_push_success {type : Ty} {tR : Ty} {tI : Ty} (flatR : FlatType tR) (flatI : FlatType tI)
    (run : primType .push [tR, tI] = .ok type) :
    tR = .list .int ∧ tI = .int ∧ type = .list .int := by
  cases flatR <;> cases flatI <;> simp [primType, BEq.beq, Ty.equal] at run <;>
    (change Except.ok _ = Except.ok type at run; cases Except.ok.inj run; exact ⟨rfl, rfl, rfl⟩)

theorem exprType_push_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {receiver : Atom} {item : Atom} {self : Decl} {type : Ty} {escapes : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (flatR : FlatAtom receiver) (flatI : FlatAtom item)
    (typed : exprType declarations self tenv (.prim .push [receiver, item]) = .ok type) :
    atomType tenv receiver = .ok (.list .int) ∧ atomType tenv item = .ok .int ∧ type = .list .int := by
  obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
  obtain ⟨tR, rest, headTyped, restTyped, shape⟩ := except_mapM_cons_success atomsTyped
  obtain ⟨tI, rest', itemTyped, restTyped', shape'⟩ := except_mapM_cons_success restTyped
  have restNil := except_mapM_nil_success restTyped'
  subst shape
  subst shape'
  subst restNil
  obtain ⟨listType, intType, resultType⟩ :=
    primType_push_success (flat_atom_type inv flatR headTyped) (flat_atom_type inv flatI itemTyped) primTyped
  subst listType
  subst intType
  exact ⟨headTyped, itemTyped, resultType⟩

/-! ### Runtime -/

def heapPushed (hs : State) (root : Nat) (xs : List Int) (item : Int) : State :=
  { hs with
    fuel := hs.fuel - 1
    heap := hs.heap.set! root (heapInts xs ++ [.int item])
    writes := (if heapInts xs == heapInts xs ++ [.int item] then hs.writes else hs.writes + 1) }

theorem heapPushed_heap (hs : State) (root : Nat) (xs : List Int) (item : Int) :
    (heapPushed hs root xs item).heap = hs.heap.set! root (heapInts (xs ++ [item])) := by
  simp [heapPushed, heapInts]

theorem push_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {receiver : Atom} {item : Atom} {escapes : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueReceiver : ValueSemantics.atom (valueEnv env) receiver = .ok (.list (valueInts xs)))
    (heapReceiver : InPlaceSemantics.atom (heapEnv env) receiver = .ok (.ref root))
    (valueItem : ValueSemantics.atom (valueEnv env) item = .ok (.int n))
    (heapItem : InPlaceSemantics.atom (heapEnv env) item = .ok (.int n))
    (lookup : hs.heap[root]? = some (heapInts xs))
    (rootOutside : root ∉ footprint)
    (represented : RepresentsMany hs.heap observationDepth hs.kept.toList vs.kept.toList footprint)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim .push [receiver, item])).run vs =
      .ok (.list (valueInts (xs ++ [n])), valueObserved (valueTicked vs)) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim .push [receiver, item])).run hs =
      .ok (.ref root, heapObserved (heapPushed hs root xs n) vs.kept.toList) := by
  have valueObservedRun := value_observeKept_run (valueTicked vs) represented
  have framed : RepresentsMany (hs.heap.set! root (heapInts xs ++ [Value.int n])) observationDepth
      hs.kept.toList vs.kept.toList footprint :=
    representsMany_after_write (xs := heapInts xs ++ [Value.int n]) represented rootOutside
  have heapObservedRun : InPlaceSemantics.observeKept.run (heapPushed hs root xs n) =
      .ok ((), heapObserved (heapPushed hs root xs n) vs.kept.toList) :=
    heap_observeKept_run (heapPushed hs root xs n) framed
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have valueAtoms : [receiver, item].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.list (valueInts xs), .int n] := except_mapM_cons valueReceiver (except_mapM_cons valueItem rfl)
  have heapAtoms : [receiver, item].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref root, .int n] := except_mapM_cons heapReceiver (except_mapM_cons heapItem rfl)
  have pushRun : (prim .push [.ref root, .int n]).run (heapTicked hs) =
      .ok (.ref root, heapPushed hs root xs n) :=
    primitive_push_run (heapTicked hs) xs n lookup inv.links
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, value_primitive_push_run, valueObservedRun, Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, pushRun, heapObservedRun, Except.bind, Except.pure, bind, pure]

theorem push_failure {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {receiver : Atom} {item : Atom} {escapes : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueReceiver : ValueSemantics.atom (valueEnv env) receiver = .ok (.list (valueInts xs)))
    (heapReceiver : InPlaceSemantics.atom (heapEnv env) receiver = .ok (.ref root))
    (valueItem : ValueSemantics.atom (valueEnv env) item = .ok (.int n))
    (heapItem : InPlaceSemantics.atom (heapEnv env) item = .ok (.int n))
    (lookup : hs.heap[root]? = some (heapInts xs))
    (rootOutside : root ∉ footprint)
    (represented : RepresentsMany hs.heap observationDepth hs.kept.toList vs.kept.toList footprint)
    (failed : (ValueSemantics.eval depth declarations none (valueEnv env)
      (.prim .push [receiver, item])).run vs = .error message) :
    ∃ actualMessage,
      (InPlaceSemantics.eval depth declarations none (heapEnv env)
        (.prim .push [receiver, item])).run hs = .error actualMessage := by
  have heapAtoms : [receiver, item].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref root, .int n] := except_mapM_cons heapReceiver (except_mapM_cons heapItem rfl)
  by_cases noDepth : depth = 0
  · exact ⟨"in-place execution exhausted depth", by
      rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
      simp [noDepth]⟩
  · by_cases noFuel : vs.fuel = 0
    · have heapFuel : hs.fuel = 0 := inv.fuel.symm.trans noFuel
      exact ⟨"in-place execution exhausted fuel", by
        rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
        simp [noDepth, heapFuel]⟩
    · have success := (push_runtime_success inv valueReceiver heapReceiver valueItem heapItem lookup
        rootOutside represented noDepth noFuel).1
      rw [success] at failed
      contradiction

/-! ### The live continuation avoids the written array -/

theorem live_binding_apart {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {after : Live} {escapes : List Origin} {roots : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (scope : liveScope aenv after = .ok ())
    (receiverNamed : named gamma roots root)
    (separate : ∀ r, named gamma roots r → ¬ named gamma (union (liveCells aenv after) pinned) r) :
    ∀ x p, (x, p) ∈ after → ∀ o c, env.lookup x = some (o, .ref c) → c ≠ root := by
  intro x p use o c binding same
  subst same
  obtain ⟨abstract, abstractBinding⟩ := liveScope_lookup_exists scope use
  obtain ⟨ty, declared, _, actualTyped⟩ := inv.bindingsTyped x o (.ref c) binding
  have shape := inv.abstractShapes x ty abstract declared abstractBinding
  cases allocated_shape_of_typed (inv.types x ty declared) actualTyped with
  | list _ _ =>
    have names : named gamma (union (liveCells aenv after) pinned) c := by
      cases shape with
      | listBottom roots' certificate' =>
        obtain ⟨witness, member, address⟩ := named_root_from_invariant inv binding abstractBinding
        exact ⟨witness, mem_union _ _ witness (Or.inl (roots_in_liveCells aenv after x p use abstractBinding witness member)), address⟩
      | listScalar roots' certificate' =>
        obtain ⟨witness, member, address⟩ := named_root_from_invariant inv binding abstractBinding
        exact ⟨witness, mem_union _ _ witness (Or.inl (roots_in_liveCells aenv after x p use abstractBinding witness member)), address⟩
    exact separate c receiverNamed names

/-! ### The push expression case -/

theorem push_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {receiver : Atom} {item : Atom} {self : Decl} {type : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (flatR : FlatAtom receiver) (flatI : FlatAtom item)
    (typed : exprType declarations self tenv (.prim .push [receiver, item]) = .ok type)
    (coveredR : ∀ use ∈ atomUses receiver, use ∈ live)
    (coveredI : ∀ use ∈ atomUses item, use ∈ live)
    (afterSub : ∀ use ∈ after, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim .push [receiver, item]) after site).run before =
      .ok (result, next)) :
    type = .list .int ∧ next.facts.escapes = before.facts.escapes ∧ FlatAbstract type result ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .push [receiver, item])).run vs = .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .push [receiver, item])).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env after aenv tenv next.facts.escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧ Describes gamma' hs'.heap result actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .push [receiver, item])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .push [receiver, item])).run hs = .error actualMessage) := by
  obtain ⟨receiverTyped, itemTyped, listType⟩ := exprType_push_success inv flatR flatI typed
  subst listType
  obtain ⟨key, root, xs, roots, element, certificate, _, _, _, _, lookup, receiverNamed, elementFlat,
    valueReceiver, heapReceiver, abstractReceiver⟩ := flat_atom_list inv flatR receiverTyped coveredR
  obtain ⟨n, valueItem, heapItem, abstractItem⟩ := flat_atom_integer inv flatI itemTyped coveredI
  have abstractAtoms : [receiver, item].mapM (m := Except String) (abstractAtom aenv) =
      .ok [.list roots element certificate, .scalar] :=
    except_mapM_cons abstractReceiver (except_mapM_cons abstractItem rfl)
  obtain ⟨childFuel, _, scope, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  have demanded := primitive_push_demand_run run
  rw [show ({ctx with escaped := union ctx.escaped before.facts.escapes} : Context).config = {} from
    defaultConfig, liveCellsWith_default] at demanded
  have escapesEq := demand_success_escapes demanded
  obtain ⟨certificate', resultEq⟩ := primitive_push_result run
  have joined := flat_join_scalar elementFlat
  have resultFlat : FlatAbstract (.list .int) result := by
    rw [resultEq, joined]; exact .listScalar _ _
  obtain ⟨footprint, represented⟩ := inv.observers
  have rootOutside : root ∉ footprint :=
    demand_success_observer_footprint inv.toInvariant demanded receiverNamed represented
  have separate := demand_success_live_separate inv.separating demanded
  have apart := live_binding_apart inv scope receiverNamed separate
  refine ⟨rfl, escapesEq, resultFlat, ?_, ?_⟩
  · intro value vs' run'
    have valueAtoms : [receiver, item].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
        .ok [.list (valueInts xs), .int n] :=
      except_mapM_cons valueReceiver (except_mapM_cons valueItem rfl)
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run'
      simp [noDepth] at run'
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run'
        simp [noDepth, noFuel] at run'
      · obtain ⟨valueRun, heapRun⟩ := push_runtime_success inv valueReceiver heapReceiver valueItem
          heapItem lookup rootOutside represented noDepth noFuel
        rw [valueRun] at run'
        cases run'
        have valid : root < hs.heap.size := (Array.getElem?_eq_some_iff.mp lookup).1
        have heapEq : (heapObserved (heapPushed hs root xs n) vs.kept.toList).heap =
            hs.heap.set! root (heapInts (xs ++ [n])) := by
          rw [heapObserved_heap, heapPushed_heap]
        have lookupNew : (heapObserved (heapPushed hs root xs n) vs.kept.toList).heap[root]? =
            some (heapInts (xs ++ [n])) := by
          rw [heapEq]; simp [valid]
        have sizeEq : (heapObserved (heapPushed hs root xs n) vs.kept.toList).heap.size = hs.heap.size := by
          rw [heapEq]; simp
        refine ⟨.ref root, heapObserved (heapPushed hs root xs n) vs.kept.toList, gamma, heapRun, ?_,
          Nat.le_of_eq sizeEq.symm, corresponds_integer_ref lookupNew, ?_,
          integer_list_observation_typed declarations (xs ++ [n]),
          allocated_integer_list_typed declarations lookupNew⟩
        · rw [escapesEq]
          refine flatInvariant_heap_frame inv (hole := root) (footprint := footprint) afterSub
            ?_ ?_ ?_ ?_ apart represented rootOutside ?_ ?_ (fun _ _ _ => Iff.rfl) ?_ inv.separating
            ?_ ?_ ?_ (fun _ escaped => escaped)
          · rw [heapEq]; exact flatHeap_after_write inv.heapInts valid (xs ++ [n])
          · exact Nat.le_of_eq sizeEq.symm
          · rw [heapObserved_links]; exact inv.links
          · intro c _ different
            rw [heapEq]
            exact lookup_set_other hs.heap root _ different
          · rw [heapObserved_kept]; rfl
          · rw [valueObserved_kept]; rfl
          · rw [sizeEq]; exact inv.namingBound
          · rw [valueObserved_reads, heapObserved_reads]; exact inv.reads
          · exact observed_external (valueTicked vs) (heapPushed hs root xs n) inv.keptSize inv.external
          · rw [valueObserved_fuel, heapObserved_fuel]; simp [valueTicked, heapPushed, inv.fuel]
        · rw [resultEq, joined]
          exact allocated_list_described lookupNew receiverNamed
  · intro message failed
    exact push_failure inv valueReceiver heapReceiver valueItem heapItem lookup rootOutside
      represented failed

end Ownership.FlatFragment.Push
