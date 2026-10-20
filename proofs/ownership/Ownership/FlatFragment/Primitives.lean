import Ownership.FlatFragment.Frame

/-! The first flat fragment: the literal, length, integer primitive, shared, and push expression cases. -/

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
open Ownership.FlatFragment.Naming Ownership.FlatFragment.Support Ownership.FlatFragment.IntegerCorrespondence Ownership.FlatFragment.Fields
open Ownership.FlatFragment.CheckerExtraction

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

/-- The fold of scalars and bottoms (a dead operand) over a scalar or bottom. -/
theorem flat_fold_flat (as : List Abstract) (flatAs : ∀ a ∈ as, a = .bottom ∨ a = .scalar)
    (start : Abstract) (flat : start = .bottom ∨ start = .scalar) :
    as.foldl Abstract.join start = .bottom ∨ as.foldl Abstract.join start = .scalar := by
  induction as generalizing start with
  | nil => simpa using flat
  | cons a rest ih =>
    simp only [List.foldl_cons]
    apply ih (fun x member => flatAs x (List.mem_cons_of_mem _ member))
    rcases flat with rfl | rfl <;> rcases flatAs a (by simp) with rfl | rfl <;> simp [Abstract.join]

/-- The actual literal inference: a fresh site root, a flat element, and an
unchanged checker state. Every operand is a scalar or the bottom of dead code. -/
theorem infer_literal_success {aenv : Env Abstract} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {args : List Atom} {as : List Abstract}
    (defaultConfig : ctx.config = {})
    (argsRun : args.mapM (m := Except String) (abstractAtom aenv) = .ok as)
    (flatAs : ∀ a ∈ as, a = .bottom ∨ a = .scalar)
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim (.literal .int) args) after site).run before =
      .ok (result, next)) :
    next = before ∧ ∃ element certificate,
      result = .list [.site site 0] element certificate ∧
      (element = .bottom ∨ element = .scalar) := by
  obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig argsRun accepted
  rw [primitive_literal_run] at run
  have equal := Except.ok.inj run
  refine ⟨(congrArg Prod.snd equal).symm, _, _, (congrArg Prod.fst equal).symm, ?_⟩
  exact flat_fold_flat as flatAs .bottom (Or.inl rfl)

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
  · intro x p _ o w w' binding projected q c located
    have := live_path_below inv x p o w w' binding projected q c located
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
the live uses supply the operand values (any atoms); acceptance supplies the result. -/
theorem literal_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {args : List Atom} {self : Decl} {type : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
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
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        ResultTags type result actual) ∧
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
    flat_atoms_integers inv atomsTyped allInt covered
  obtain ⟨checkerState, element, certificate, resultShape, elementFlat⟩ :=
    infer_literal_success defaultConfig abstractAtoms
      (fun a member => by obtain ⟨_, _, rfl⟩ := List.mem_map.mp member; exact Or.inr rfl) accepted
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
          heapRun, postInvariant, ?_, ?_, ?_, ?_, ?_, by rw [resultShape]; exact .listInt _ _ _ _⟩
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
open Ownership.FlatFragment.Literal Ownership.FlatFragment.Support Ownership.FlatFragment.Fields
open Ownership.FlatFragment.CheckerExtraction Ownership.FlatFragment.InferBranch

theorem primitive_length_run (ctx : Context) (site : List Nat) (a : Abstract)
    (later : List Origin) (before : St) :
    (primitive ctx site .length [a] later).run before =
      .ok (.scalar, {before with facts :=
        {before.facts with reads := union before.facts.reads (a.roots.filter external)}}) := by
  unfold primitive
  rfl

theorem flat_atom_type {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {atom : Atom} {ty : Ty} {escapes : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (typed : atomType tenv atom = .ok ty) : FlatType ty := by
  cases root : atomRoot atom with
  | none =>
    obtain ⟨n, rfl, rfl⟩ := atom_int_of_root_none typed root
    exact .int
  | some kp =>
    rcases kp with ⟨k, p⟩
    obtain ⟨tk, declared, at_p⟩ := atom_type_of_root typed root
    exact flatType_tyAt (inv.types k tk declared) at_p

theorem primType_length_success {type : Ty} {ty : Ty} (flat : FlatType ty) (run : primType .length [ty] = .ok type) :
    ty = .list .int ∧ type = .int := by
  cases flat with
  | int => simp [primType] at run
  | record _ _ => simp [primType] at run
  | result _ _ _ _ => simp [primType] at run
  | listInt =>
    simp [primType] at run
    change Except.ok Ty.int = Except.ok type at run
    cases Except.ok.inj run
    exact ⟨rfl, rfl⟩

/-- The single-operand typing equation of a length expression. -/
theorem exprType_length_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {receiver : Atom} {self : Decl} {type : Ty} {escapes : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (typed : exprType declarations self tenv (.prim .length [receiver]) = .ok type) :
    atomType tenv receiver = .ok (.list .int) ∧ type = .int := by
  obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
  obtain ⟨headType, rest, headTyped, restTyped, shape⟩ := except_mapM_cons_success atomsTyped
  have restNil := except_mapM_nil_success restTyped
  subst shape
  subst restNil
  obtain ⟨listType, intType⟩ := primType_length_success (flat_atom_type inv headTyped) primTyped
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
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        ResultTags type result actual) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .length [receiver])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .length [receiver])).run hs = .error actualMessage) := by
  obtain ⟨receiverTyped, intType⟩ := exprType_length_success inv typed
  subst intType
  obtain ⟨root, integers, roots, element, certificate, lookup, _, _,
    valueAtom, heapAtom, abstractReceiver⟩ := flat_atom_list_path inv receiverTyped covered
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
          ⟨1, .int integers.length, [], .int, by simp [obsTyped]⟩, by rw [resultScalar]; exact .int _⟩
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

/-! integer primitive case under the generic flat relation.
Both operands are live integer atoms. Both runtimes compute the same integer.
The checker returns a scalar and records nothing. The heap, the observers,
the reads and the naming stay unchanged.
-/

namespace Ownership.FlatFragment.Scalar

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.StateFrame
open Ownership.FlatFragment.Observe Ownership.FlatFragment.Runtime Ownership.FlatFragment.HeapPreservation
open Ownership.FlatFragment.Atoms Ownership.FlatFragment.AtomInteger Ownership.FlatFragment.PrimitiveInference Ownership.FlatFragment.PrimitiveRuntime
open Ownership.FlatFragment.Literal Ownership.FlatFragment.Support Ownership.FlatFragment.Length
open Ownership.FlatFragment Ownership.FlatFragment.Fields Ownership.FlatFragment.CheckerExtraction

theorem value_scalar_run {op : Prim} (sop : ScalarOp op) (s : ValueSemantics.State) (x y : Int) :
    (ValueSemantics.prim op [.int x, .int y]).run s = .ok (.int (scalarResult op x y), s) := by
  cases sop <;> rfl

theorem heap_scalar_run {op : Prim} (sop : ScalarOp op) (s : State) (x y : Int) :
    (prim op [.int x, .int y]).run s = .ok (.int (scalarResult op x y), s) := by
  cases sop <;> rfl

/-- The typing equation of an integer primitive: both operands and the result are `Int`. -/
theorem exprType_scalar_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {op : Prim} {a b : Atom} {self : Decl} {type : Ty} {escapes : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (sop : ScalarOp op)
    (typed : exprType declarations self tenv (.prim op [a, b]) = .ok type) :
    atomType tenv a = .ok .int ∧ atomType tenv b = .ok .int ∧ type = .int := by
  obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
  obtain ⟨tyA, rest, aTyped, restTyped, shape⟩ := except_mapM_cons_success atomsTyped
  obtain ⟨tyB, rest', bTyped, restTyped', shape'⟩ := except_mapM_cons_success restTyped
  have restNil := except_mapM_nil_success restTyped'
  subst shape
  subst shape'
  subst restNil
  obtain ⟨aInt, bInt, typeInt⟩ := primType_scalar_success sop
    (flat_atom_type inv aTyped) (flat_atom_type inv bTyped) primTyped
  subst aInt
  subst bInt
  exact ⟨aTyped, bTyped, typeInt⟩

theorem scalar_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {op : Prim} {a b : Atom} {x y : Int} {escapes : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (sop : ScalarOp op)
    (valueA : ValueSemantics.atom (valueEnv env) a = .ok (.int x))
    (heapA : InPlaceSemantics.atom (heapEnv env) a = .ok (.int x))
    (valueB : ValueSemantics.atom (valueEnv env) b = .ok (.int y))
    (heapB : InPlaceSemantics.atom (heapEnv env) b = .ok (.int y))
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim op [a, b])).run vs =
      .ok (.int (scalarResult op x y), AtomPreservation.valueAtomPost vs) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim op [a, b])).run hs =
      .ok (.int (scalarResult op x y),
        AtomPreservation.heapAtomPost hs vs.kept.toList) := by
  obtain ⟨footprint, represented⟩ := inv.observers
  have valueObservedRun := value_observeKept_run ({vs with fuel := vs.fuel - 1}) represented
  have heapObservedRun := heap_observeKept_run ({hs with fuel := hs.fuel - 1}) represented
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have valueAtoms : [a, b].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.int x, .int y] := except_mapM_cons valueA (except_mapM_cons valueB rfl)
  have heapAtoms : [a, b].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.int x, .int y] := except_mapM_cons heapA (except_mapM_cons heapB rfl)
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, valueTicked, AtomPreservation.valueAtomPost,
      AtomPreservation.valueTicked, value_scalar_run sop, valueObservedRun,
      Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, heapTicked, AtomPreservation.heapAtomPost,
      AtomPreservation.heapTicked,
      heap_scalar_run sop {hs with fuel := hs.fuel - 1} x y, heapObservedRun,
      Except.bind, Except.pure, bind, pure]

theorem scalar_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {op : Prim} {a b : Atom} {self : Decl} {type : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (sop : ScalarOp op)
    (typed : exprType declarations self tenv (.prim op [a, b]) = .ok type)
    (coveredA : ∀ use ∈ atomUses a, use ∈ live)
    (coveredB : ∀ use ∈ atomUses b, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim op [a, b]) after site).run before =
      .ok (result, next)) :
    type = .int ∧ next.facts.escapes = before.facts.escapes ∧ result = .scalar ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim op [a, b])).run vs = .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim op [a, b])).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv next.facts.escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧ Describes gamma' hs'.heap result actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        ResultTags type result actual) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim op [a, b])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim op [a, b])).run hs = .error actualMessage) := by
  obtain ⟨aTyped, bTyped, intType⟩ := exprType_scalar_success inv sop typed
  subst intType
  obtain ⟨x, valueA, heapA, abstractA⟩ := flat_atom_integer inv aTyped coveredA
  obtain ⟨y, valueB, heapB, abstractB⟩ := flat_atom_integer inv bTyped coveredB
  have abstractAtoms : [a, b].mapM (m := Except String) (abstractAtom aenv) =
      .ok [.scalar, .scalar] := except_mapM_cons abstractA (except_mapM_cons abstractB rfl)
  obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  rw [primitive_scalar_run sop] at run
  have equal := Except.ok.inj run
  have resultScalar : result = .scalar := (congrArg Prod.fst equal).symm
  have nextState : next = before := (congrArg Prod.snd equal).symm
  have nextEscapes : next.facts.escapes = before.facts.escapes := by rw [nextState]
  refine ⟨rfl, nextEscapes, resultScalar, ?_, ?_⟩
  · intro value vs' run
    have valueAtoms : [a, b].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
        .ok [.int x, .int y] := except_mapM_cons valueA (except_mapM_cons valueB rfl)
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
      simp [noDepth] at run
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
        simp [noDepth, noFuel] at run
      · obtain ⟨valueRun, heapRun⟩ :=
          scalar_runtime_success inv sop valueA heapA valueB heapB noDepth noFuel
        rw [valueRun] at run
        cases run
        refine ⟨.int (scalarResult op x y),
          AtomPreservation.heapAtomPost hs vs.kept.toList, gamma,
          heapRun, ?_, ?_, AtomPreservation.integer_corresponds _, ?_,
          by simp [obsTyped], ⟨1, .int (scalarResult op x y), [], .int, by simp [obsTyped]⟩,
          by rw [resultScalar]; exact .int _⟩
        · rw [nextEscapes]; exact AtomPreservation.integer_atom_post_invariant inv
        · exact Nat.le_of_eq (by
            unfold AtomPreservation.heapAtomPost
              AtomPreservation.heapTicked
            rw [heapObserved_heap])
        · rw [resultScalar]; exact AtomPreservation.integer_described _
  · intro message failed
    have valueAtoms : [a, b].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
        .ok [.int x, .int y] := except_mapM_cons valueA (except_mapM_cons valueB rfl)
    have heapAtoms : [a, b].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
        .ok [.int x, .int y] := except_mapM_cons heapA (except_mapM_cons heapB rfl)
    by_cases noDepth : depth = 0
    · exact ⟨"in-place execution exhausted depth", by
        rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
        simp [noDepth]⟩
    · by_cases noFuel : vs.fuel = 0
      · have heapFuel : hs.fuel = 0 := inv.fuel.symm.trans noFuel
        exact ⟨"in-place execution exhausted fuel", by
          rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
          simp [noDepth, heapFuel]⟩
      · have success := (scalar_runtime_success inv sop valueA heapA valueB heapB noDepth noFuel).1
        rw [success] at failed
        contradiction

end Ownership.FlatFragment.Scalar

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
open Ownership.FlatFragment.IntegerCorrespondence Ownership.FlatFragment.Support Ownership.FlatFragment.Fields

local instance stepReflBEq : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance stepLawfulBEq : LawfulBEq Step := LawfulBEq.mk (by deriving_LawfulEq_tactic)
local instance originReflBEq : ReflBEq Origin := ⟨by deriving_ReflEq_tactic⟩
local instance originLawfulBEq : LawfulBEq Origin := LawfulBEq.mk (by deriving_LawfulEq_tactic)

/-! ### Origins and escapes -/

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

/-! ### The checker's shared step -/

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
    tags := inv.tags
    liveTyped := inv.liveTyped
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

/-! ### Observing a deep value fails on both sides -/

theorem forM_error_of_mem {α : Type} {f : α → Except String Unit} {l : List α} {a : α} {e : String}
    (member : a ∈ l) (failed : f a = .error e) : ∃ e', l.forM f = .error e' := by
  induction l with
  | nil => simp at member
  | cons x xs ih =>
    change (∃ e', (f x >>= fun _ => xs.forM f) = .error e')
    rcases List.mem_cons.mp member with rfl | later
    · exact ⟨e, by simp [failed, bind, Except.bind]⟩
    · cases hx : f x with
      | error e'' => exact ⟨e'', by simp [hx, bind, Except.bind]⟩
      | ok u =>
        obtain ⟨e', h⟩ := ih later
        exact ⟨e', by simp [hx, h, bind, Except.bind]⟩

theorem value_observeKept_error (s : ValueSemantics.State) {e : String} (nonempty : s.kept ≠ #[])
    (failed : s.kept.toList.forM ValueSemantics.observable = .error e) :
    ValueSemantics.observeKept.run s = .error e := by
  simp [ValueSemantics.observeKept, StateT.run, StateT.bind, StateT.get, StateT.set, StateT.pure,
    StateT.lift, get, getThe, MonadStateOf.get, MonadStateOf.set, bind, pure, liftM, monadLift,
    MonadLift.monadLift, nonempty, failed, Except.bind, Except.pure]

/-- A successful value epilogue bounds every registered observation. -/
theorem value_observeKept_ok_depth (s : ValueSemantics.State) {r : Unit × ValueSemantics.State}
    (run : ValueSemantics.observeKept.run s = .ok r) :
    ∀ o ∈ s.kept.toList, o.depth ≤ observationDepth := by
  intro o member
  by_cases deep : o.depth ≤ observationDepth
  · exact deep
  · exfalso
    have nonempty : s.kept ≠ #[] := by
      intro empty
      simp [empty] at member
    have failed : ValueSemantics.observable o = .error "snapshot exhausted depth" := by
      simp [ValueSemantics.observable, Nat.lt_of_not_le deep, throw, throwThe, MonadExceptOf.throw]
    obtain ⟨e', forMFailed⟩ := forM_error_of_mem member failed
    rw [value_observeKept_error s nonempty forMFailed] at run
    cases run

theorem corresponds_unique {heap : Heap} {o o' : Observation} {w : Value}
    (first : Corresponds heap o w) (second : Corresponds heap o' w) : o = o' := by
  have a := first (max o.depth o'.depth) (Nat.le_max_left _ _)
  have b := second (max o.depth o'.depth) (Nat.le_max_right _ _)
  exact Except.ok.inj (a.symm.trans b)

/-- A value whose observation is deeper than the observation depth has no
snapshot at that depth. -/
theorem snapshot_deep_error {heap : Heap} {o : Observation} {w : Value}
    (paired : Corresponds heap o w) (deep : observationDepth < o.depth) :
    ∃ e, snapshot heap observationDepth w = .error e := by
  cases h : snapshot heap observationDepth w with
  | error e => exact ⟨e, rfl⟩
  | ok o' =>
    obtain ⟨cs, rep⟩ := represents_of_snapshot _ _ _ h
    have bound := represents_depth_bound rep
    have same := corresponds_unique paired (corresponds_of_represents rep)
    subst same
    omega

theorem mapM_error_of_mem {α β : Type} {f : α → Except String β} {l : List α} {a : α} {e : String}
    (member : a ∈ l) (failed : f a = .error e) : ∃ e', l.mapM f = .error e' := by
  induction l with
  | nil => simp at member
  | cons x xs ih =>
    rw [List.mapM_cons]
    rcases List.mem_cons.mp member with rfl | later
    · exact ⟨e, by simp [failed, bind, Except.bind]⟩
    · cases hx : f x with
      | error e'' => exact ⟨e'', by simp [hx, bind, Except.bind]⟩
      | ok y =>
        obtain ⟨e', h⟩ := ih later
        exact ⟨e', by simp [hx, h, bind, Except.bind]⟩

theorem heap_observeKept_error (s : State) {e : String} (nonempty : s.kept ≠ #[])
    (failed : s.kept.toList.mapM (snapshot s.heap observationDepth) = .error e) :
    InPlaceSemantics.observeKept.run s = .error e := by
  simp [InPlaceSemantics.observeKept, StateT.run, StateT.bind, StateT.get, StateT.set, StateT.pure,
    StateT.lift, get, getThe, MonadStateOf.get, MonadStateOf.set, bind, pure, liftM, monadLift,
    MonadLift.monadLift, nonempty, failed, Except.bind, Except.pure]

/-- Sharing a value deeper than the observation depth fails on the heap side
at the observer epilogue. -/
theorem shared_deep_failure {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {atom : Atom} {escapes : List Origin} {x : Observation} {v : Value}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (heapAtom : InPlaceSemantics.atom (heapEnv env) atom = .ok v)
    (paired : Corresponds hs.heap x v) (deep : observationDepth < x.depth)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    ∃ e, (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim .shared [atom])).run hs =
      .error e := by
  obtain ⟨e, snapshotFailed⟩ := snapshot_deep_error paired deep
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have heapAtoms : [atom].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [v] := except_mapM_cons heapAtom rfl
  obtain ⟨e', mapFailed⟩ := mapM_error_of_mem (l := hs.kept.toList ++ [v]) (by simp) snapshotFailed
  have observeFailed := heap_observeKept_error ({hs with fuel := hs.fuel - 1, kept := hs.kept.push v})
    (by simp) (by rw [Array.toList_push]; exact mapFailed)
  refine ⟨e', ?_⟩
  rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
  simp [hasDepth, heapFuel, heapTicked, heap_shared_run, observeFailed, Except.bind, bind]

/-! ### The shared expression case -/

theorem shared_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {atom : Atom} {self : Decl} {type : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
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
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        ResultTags type result actual) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .shared [atom])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .shared [atom])).run hs = .error actualMessage) := by
  have atomTyped := exprType_shared_success typed
  obtain ⟨x, v, a, valueAtom, heapAtom, abstractValue, paired, described, observed, valueTyped,
    flatType, shape, allocated, tags⟩ := flat_atom_values inv atomTyped covered
  have abstractAtoms : [atom].mapM (m := Except String) (abstractAtom aenv) = .ok [a] :=
    except_mapM_cons abstractValue rfl
  obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  rw [primitive_shared_run {ctx with escaped := union ctx.escaped before.facts.escapes} defaultConfig] at run
  have equal := Except.ok.inj run
  have first : a.mapOrigins (fun _ cs => if cs.isEmpty then [] else union cs [.shared]) = result :=
    congrArg Prod.fst equal
  have second : next = {before with facts := {before.facts with
      escapes := union before.facts.escapes a.cells}} := (congrArg Prod.snd equal).symm
  have escapesEq : next.facts.escapes = union before.facts.escapes a.cells :=
    congrArg (fun s : St => s.facts.escapes) second
  have resultFlat : FlatAbstract type result := by
    rw [← first]; exact flatAbstract_mapOrigins _ shape []
  have resultDescribed : Describes gamma hs.heap result v := by
    rw [← first]; exact describes_mapOrigins_shared allocated shape tags inv.heapInts described []
  have mono : ∀ origin, Escaped before.facts.escapes origin → Escaped next.facts.escapes origin := by
    intro origin escaped
    rw [escapesEq]
    exact escaped_mono _ escaped
  have newEscaped : ∀ c, Reaches hs.heap v (.ref c) → ∀ origin, c ∈ gamma origin →
      Escaped next.facts.escapes origin := by
    intro c reachable origin member
    obtain ⟨q, located⟩ := reaches_flat allocated inv.heapInts reachable
    have names := named_cellsAt_of_covers allocated shape inv.heapInts described.1.1 located
    rw [escapesEq]
    exact named_cell_escaped inv.separating names member (fun o h => cellsAt_subset_cells h)
  have valueAtoms : [atom].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [x] := except_mapM_cons valueAtom rfl
  have heapAtoms : [atom].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [v] := except_mapM_cons heapAtom rfl
  refine ⟨flatType, resultFlat, mono, ?_, ?_⟩
  · intro value vs' run
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
      simp [noDepth] at run
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
        simp [noDepth, noFuel] at run
      · -- The value epilogue succeeded, so the new observation is shallow.
        have shallow : x.depth ≤ observationDepth := by
          have run' := run
          rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run'
          simp only [noDepth, noFuel, if_false, valueTicked, value_shared_run, Except.bind, bind,
            pure, Except.pure] at run'
          cases observeRun : ValueSemantics.observeKept.run
              {vs with fuel := vs.fuel - 1, kept := vs.kept.push x} with
          | error e => rw [observeRun] at run'; cases run'
          | ok r =>
            exact value_observeKept_ok_depth _ observeRun x (by simp)
        obtain ⟨cells, witness⟩ := represents_of_snapshot observationDepth v x (paired _ shallow)
        obtain ⟨valueRun, heapRun⟩ :=
          shared_runtime_success inv valueAtom heapAtom witness noDepth noFuel
        rw [valueRun] at run
        cases run
        have heapSame : (heapShared hs v (vs.kept.toList ++ [x])).heap = hs.heap := by
          unfold heapShared; rw [heapObserved_heap]
        refine ⟨v, heapShared hs v (vs.kept.toList ++ [x]), gamma, heapRun,
          shared_post_invariant inv witness mono newEscaped,
          Nat.le_of_eq (congrArg Array.size heapSame.symm), ?_, ?_, observed, ?_, ?_⟩
        · rw [heapSame]; exact paired
        · rw [heapSame]; exact resultDescribed
        · rw [heapSame]; exact valueTyped
        · rw [← first]; exact resultTags_mapOrigins _ tags []
  · intro message failed
    by_cases noDepth : depth = 0
    · exact ⟨"in-place execution exhausted depth", by
        rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
        simp [noDepth]⟩
    · by_cases noFuel : vs.fuel = 0
      · have heapFuel : hs.fuel = 0 := inv.fuel.symm.trans noFuel
        exact ⟨"in-place execution exhausted fuel", by
          rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
          simp [noDepth, heapFuel]⟩
      · by_cases deep : observationDepth < x.depth
        · exact shared_deep_failure inv heapAtom paired deep noDepth noFuel
        · obtain ⟨cells, witness⟩ :=
            represents_of_snapshot observationDepth v x (paired _ (Nat.le_of_not_lt deep))
          have success := (shared_runtime_success inv valueAtom heapAtom witness noDepth noFuel).1
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
open Ownership.FlatFragment.Scope Ownership.FlatFragment.Shared Ownership.FlatFragment.Fields

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

/-- The same with a dead item (its abstract bottom), for the static facts. -/
theorem primitive_push_result_flat {ctx : Context} {site : List Nat} {before : St} {next : St} {result : Abstract} {roots : List Origin} {later : List Origin} {element item : Abstract} {certificate : Certificate}
    (flatI : item = .bottom ∨ item = .scalar)
    (run : (primitive ctx site .push [.list roots element certificate, item] later).run before =
      .ok (result, next)) :
    ∃ certificate', result = .list roots (element.join item) certificate' := by
  rcases flatI with rfl | rfl
  · unfold primitive at run
    obtain ⟨finished, middle, _, returned⟩ := checkM_bind_success run
    cases finished
    have equal := Except.ok.inj returned
    have first : _ = result := congrArg Prod.fst equal
    rw [← first]
    exact ⟨_, by simp [Abstract.grantExclusive] <;> rfl⟩
  · exact primitive_push_result run

theorem liveCellsWith_default (env : Env Abstract) (l : Live) :
    liveCellsWith ({} : Config) env l = liveCells env l := by
  simp [liveCellsWith, default_has]

theorem flat_join_scalar {element : Abstract} (flat : element = .bottom ∨ element = .scalar) :
    element.join .scalar = .scalar := by
  rcases flat with rfl | rfl <;> simp [Abstract.join]

/-- The element after a push of a scalar or of a dead operand. -/
theorem flat_join_flat {element item : Abstract} (flatE : element = .bottom ∨ element = .scalar)
    (flatI : item = .bottom ∨ item = .scalar) :
    element.join item = .bottom ∨ element.join item = .scalar := by
  rcases flatE with rfl | rfl <;> rcases flatI with rfl | rfl <;> simp [Abstract.join]

/-- A push onto a dead receiver: the checker returns bottom and changes nothing. -/
theorem primitive_push_bottom_run (ctx : Context) (site : List Nat) (item : Abstract)
    (later : List Origin) (before : St) :
    (primitive ctx site .push [.bottom, item] later).run before = .ok (.bottom, before) := by
  unfold primitive
  simp [BEq.beq, Abstract.equal]
  rfl

theorem primType_push_success {type : Ty} {tR : Ty} {tI : Ty} (flatR : FlatType tR) (flatI : FlatType tI)
    (run : primType .push [tR, tI] = .ok type) :
    tR = .list .int ∧ tI = .int ∧ type = .list .int := by
  cases flatR <;> cases flatI <;> simp [primType, BEq.beq, Ty.equal] at run <;>
    (change Except.ok _ = Except.ok type at run; cases Except.ok.inj run; exact ⟨rfl, rfl, rfl⟩)

theorem exprType_push_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {receiver : Atom} {item : Atom} {self : Decl} {type : Ty} {escapes : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
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
    primType_push_success (flat_atom_type inv headTyped) (flat_atom_type inv itemTyped) primTyped
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

/-! ### The push expression case -/

theorem push_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {receiver : Atom} {item : Atom} {self : Decl} {type : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
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
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        ResultTags type result actual) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .push [receiver, item])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .push [receiver, item])).run hs = .error actualMessage) := by
  obtain ⟨receiverTyped, itemTyped, listType⟩ := exprType_push_success inv typed
  subst listType
  obtain ⟨root, xs, roots, element, certificate, lookup, receiverNamed, elementFlat,
    valueReceiver, heapReceiver, abstractReceiver⟩ := flat_atom_list_path inv receiverTyped coveredR
  obtain ⟨n, valueItem, heapItem, abstractItem⟩ := flat_atom_integer inv itemTyped coveredI
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
  have apart := live_path_apart inv scope afterSub receiverNamed separate
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
          allocated_integer_list_typed declarations lookupNew, by rw [resultEq, joined]; exact .listInt _ _ _ _⟩
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

/-! record construction under the generic flat relation.
The checker returns the operands' descriptions as a record and changes
nothing; both runtimes build the record of the operand values with no heap
effect and no read. Every clause is pointwise over the fields. -/

namespace Ownership.FlatFragment.Record

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.StateFrame
open Ownership.FlatFragment.Observe Ownership.FlatFragment.Runtime Ownership.FlatFragment.HeapPreservation
open Ownership.FlatFragment.Atoms Ownership.FlatFragment.CheckerExtraction Ownership.FlatFragment.PrimitiveInference
open Ownership.FlatFragment.PrimitiveRuntime Ownership.FlatFragment.Literal Ownership.FlatFragment.Support
open Ownership.FlatFragment.Fields

theorem heapAtomPost_heap (hs : State) (observations : List Observation) :
    (AtomPreservation.heapAtomPost hs observations).heap = hs.heap := by
  unfold AtomPreservation.heapAtomPost heapObserved AtomPreservation.heapTicked
  split <;> rfl

/-- The operands of a record constructor, pointwise. -/
theorem flat_atoms_values {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {args : List Atom} {types : List Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (typed : args.mapM (atomType tenv) = .ok types)
    (covered : ∀ atom ∈ args, ∀ use ∈ atomUses atom, use ∈ live) :
    ∃ (os : List Observation) (ws : List Value) (as : List Abstract),
      args.mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) = .ok os ∧
      args.mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) = .ok ws ∧
      args.mapM (m := Except String) (abstractAtom aenv) = .ok as ∧
      os.length = types.length ∧ ws.length = types.length ∧ as.length = types.length ∧
      ∀ (i : Nat) (o : Observation) (w : Value) (a : Abstract) (t : Ty),
        os[i]? = some o → ws[i]? = some w → as[i]? = some a → types[i]? = some t →
        Corresponds hs.heap o w ∧ Describes gamma hs.heap a w ∧
        obsTyped declarations o t = true ∧ ValueTyped declarations hs.heap w t ∧
        FlatType t ∧ FlatAbstract t a ∧ AllocatedFlatValue hs.heap w t ∧ ResultTags t a w := by
  induction args generalizing types with
  | nil =>
    have := except_mapM_nil_success typed
    subst this
    exact ⟨[], [], [], rfl, rfl, rfl, rfl, rfl, rfl, fun i o w a t h => by simp at h⟩
  | cons atom rest ih =>
    obtain ⟨t, restTypes, headTyped, restTyped, rfl⟩ := except_mapM_cons_success typed
    obtain ⟨os, ws, as, valueRest, heapRest, abstractRest, lenO, lenW, lenA, fields⟩ :=
      ih restTyped (fun atom member => covered atom (by simp [member]))
    obtain ⟨o, w, a, valueHead, heapHead, abstractHead, paired, described, observed, valueTyped,
      flatType, shape, allocated, tags⟩ := flat_atom_values inv headTyped (covered atom (by simp))
    refine ⟨o :: os, w :: ws, a :: as, except_mapM_cons valueHead valueRest,
      except_mapM_cons heapHead heapRest, except_mapM_cons abstractHead abstractRest,
      by simp [lenO], by simp [lenW], by simp [lenA], ?_⟩
    intro i o' w' a' t' os_i ws_i as_i types_i
    cases i with
    | zero =>
      simp at os_i ws_i as_i types_i
      subst os_i; subst ws_i; subst as_i; subst types_i
      exact ⟨paired, described, observed, valueTyped, flatType, shape, allocated, tags⟩
    | succ i =>
      exact fields i o' w' a' t' (by simpa using os_i) (by simpa using ws_i) (by simpa using as_i)
        (by simpa using types_i)

theorem record_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {args : List Atom} {os : List Observation} {ws : List Value} {escapes : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueAtoms : args.mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) = .ok os)
    (heapAtoms : args.mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) = .ok ws)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim .record args)).run vs =
      .ok (.record os, AtomPreservation.valueAtomPost vs) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim .record args)).run hs =
      .ok (.record ws, AtomPreservation.heapAtomPost hs vs.kept.toList) := by
  obtain ⟨footprint, represented⟩ := inv.observers
  have valueObservedRun := value_observeKept_run ({vs with fuel := vs.fuel - 1}) represented
  have heapObservedRun := heap_observeKept_run ({hs with fuel := hs.fuel - 1}) represented
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, valueTicked, AtomPreservation.valueAtomPost,
      AtomPreservation.valueTicked, value_record_run, valueObservedRun,
      Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, heapTicked, AtomPreservation.heapAtomPost,
      AtomPreservation.heapTicked, heap_record_run, heapObservedRun,
      Except.bind, Except.pure, bind, pure]

theorem record_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {args : List Atom} {self : Decl} {type : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.prim .record args) = .ok type)
    (covered : ∀ atom ∈ args, ∀ use ∈ atomUses atom, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim .record args) after site).run before =
      .ok (result, next)) :
    next.facts.escapes = before.facts.escapes ∧ FlatType type ∧ FlatAbstract type result ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .record args)).run vs = .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .record args)).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv next.facts.escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧ Describes gamma' hs'.heap result actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        ResultTags type result actual) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .record args)).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .record args)).run hs = .error actualMessage) := by
  obtain ⟨types, atomsTyped, rfl⟩ := exprType_record_success typed
  obtain ⟨os, ws, as, valueAtoms, heapAtoms, abstractAtoms, lenO, lenW, lenA, fields⟩ :=
    flat_atoms_values inv atomsTyped covered
  obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  rw [primitive_record_run _ (show ({ctx with escaped := union ctx.escaped before.facts.escapes} :
    Context).config = {} from defaultConfig)] at run
  have equal := Except.ok.inj run
  have resultEq : result = .record as := (congrArg Prod.fst equal).symm
  have nextState : next = before := (congrArg Prod.snd equal).symm
  have nextEscapes : next.facts.escapes = before.facts.escapes := by rw [nextState]
  have witnesses : ∀ (i : Nat) (t : Ty), types[i]? = some t →
      ∃ o w a, os[i]? = some o ∧ ws[i]? = some w ∧ as[i]? = some a := by
    intro i t types_i
    obtain ⟨o, os_i⟩ := index_of_same_length lenO.symm types_i
    obtain ⟨w, ws_i⟩ := index_of_same_length lenW.symm types_i
    obtain ⟨a, as_i⟩ := index_of_same_length lenA.symm types_i
    exact ⟨o, w, a, os_i, ws_i, as_i⟩
  have flatType : FlatType (.record types) := by
    refine .record types ?_
    intro t member
    obtain ⟨i, types_i⟩ := List.mem_iff_getElem?.mp member
    obtain ⟨o, w, a, os_i, ws_i, as_i⟩ := witnesses i t types_i
    exact (fields i o w a t os_i ws_i as_i types_i).2.2.2.2.1
  have flatAbstract : FlatAbstract (.record types) result := by
    rw [resultEq]
    refine .record types as lenA.symm ?_
    intro i t a types_i as_i
    obtain ⟨o, w, a', os_i, ws_i, as_i'⟩ := witnesses i t types_i
    rw [as_i] at as_i'
    cases Option.some.inj as_i'
    exact (fields i o w a t os_i ws_i as_i types_i).2.2.2.2.2.1
  refine ⟨nextEscapes, flatType, flatAbstract, ?_, ?_⟩
  · intro value vs' run
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
      simp [noDepth] at run
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
        simp [noDepth, noFuel] at run
      · obtain ⟨valueRun, heapRun⟩ := record_runtime_success inv valueAtoms heapAtoms noDepth noFuel
        rw [valueRun] at run
        cases run
        have heapSame := heapAtomPost_heap hs vs.kept.toList
        refine ⟨.record ws, AtomPreservation.heapAtomPost hs vs.kept.toList, gamma, heapRun, ?_,
          Nat.le_of_eq (congrArg Array.size heapSame.symm), ?_, ?_, ?_, ?_, ?_⟩
        · rw [nextEscapes]; exact AtomPreservation.integer_atom_post_invariant inv
        · rw [heapSame]
          refine corresponds_record_of_fields (lenO.trans lenW.symm) ?_
          intro i o w os_i ws_i
          obtain ⟨t, types_i⟩ := index_of_same_length lenO os_i
          obtain ⟨a, as_i⟩ := index_of_same_length lenA.symm types_i
          exact (fields i o w a t os_i ws_i as_i types_i).1
        · rw [heapSame, resultEq]
          refine describes_record_of_fields (lenA.trans lenW.symm) ?_
          intro i a w as_i ws_i
          obtain ⟨t, types_i⟩ := index_of_same_length lenA as_i
          obtain ⟨o, os_i⟩ := index_of_same_length lenO.symm types_i
          exact (fields i o w a t os_i ws_i as_i types_i).2.1
        · refine obsTyped_record_of_fields lenO ?_
          intro i o t os_i types_i
          obtain ⟨w, ws_i⟩ := index_of_same_length lenW.symm types_i
          obtain ⟨a, as_i⟩ := index_of_same_length lenA.symm types_i
          exact (fields i o w a t os_i ws_i as_i types_i).2.2.1
        · rw [heapSame]
          refine valueTyped_record_of_fields lenW ?_
          intro i w t ws_i types_i
          obtain ⟨o, os_i⟩ := index_of_same_length lenO.symm types_i
          obtain ⟨a, as_i⟩ := index_of_same_length lenA.symm types_i
          exact (fields i o w a t os_i ws_i as_i types_i).2.2.2.1
        · rw [resultEq]
          refine .record types as ws lenA.symm ?_
          intro i t a w types_i as_i ws_i
          obtain ⟨o, os_i⟩ := index_of_same_length lenO.symm types_i
          exact (fields i o w a t os_i ws_i as_i types_i).2.2.2.2.2.2.2
  · intro message failed
    by_cases noDepth : depth = 0
    · exact ⟨"in-place execution exhausted depth", by
        rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
        simp [noDepth]⟩
    · by_cases noFuel : vs.fuel = 0
      · have heapFuel : hs.fuel = 0 := inv.fuel.symm.trans noFuel
        exact ⟨"in-place execution exhausted fuel", by
          rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
          simp [noDepth, heapFuel]⟩
      · have success := (record_runtime_success inv valueAtoms heapAtoms noDepth noFuel).1
        rw [success] at failed
        contradiction

end Ownership.FlatFragment.Record

/-! the result constructors under the generic flat relation.
`ok x` and `err x` build a record of a tag and two slots: both runtimes put
the payload in one slot and the integer `0` in the other; the checker puts
the payload's abstract in one slot and bottom in the other, and changes
nothing. The result's tags record which slot is live. -/

namespace Ownership.FlatFragment.Result

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.StateFrame
open Ownership.FlatFragment.Observe Ownership.FlatFragment.Runtime Ownership.FlatFragment.HeapPreservation
open Ownership.FlatFragment.Atoms Ownership.FlatFragment.CheckerExtraction Ownership.FlatFragment.PrimitiveInference
open Ownership.FlatFragment.PrimitiveRuntime Ownership.FlatFragment.Literal Ownership.FlatFragment.Support
open Ownership.FlatFragment.Fields Ownership.FlatFragment.Record

theorem value_ok_run (error : Ty) (s : ValueSemantics.State) (o : Observation) :
    (ValueSemantics.prim (.ok error) [o]).run s = .ok (.record [.int 1, .int 0, o], s) := rfl

theorem heap_ok_run (error : Ty) (s : State) (w : Value) :
    (prim (.ok error) [w]).run s = .ok (.record [.int 1, .int 0, w], s) := rfl

theorem value_err_run (success : Ty) (s : ValueSemantics.State) (o : Observation) :
    (ValueSemantics.prim (.err success) [o]).run s = .ok (.record [.int 0, o, .int 0], s) := rfl

theorem heap_err_run (success : Ty) (s : State) (w : Value) :
    (prim (.err success) [w]).run s = .ok (.record [.int 0, w, .int 0], s) := rfl

theorem primitive_ok_run (ctx : Context) (site : List Nat) (error : Ty) (a : Abstract)
    (later : List Origin) (before : St) :
    (primitive ctx site (.ok error) [a] later).run before = .ok (.record [.scalar, .bottom, a], before) := by
  unfold primitive
  rfl

theorem primitive_err_run (ctx : Context) (defaultConfig : ctx.config = {}) (site : List Nat)
    (success : Ty) (a : Abstract) (later : List Origin) (before : St) :
    (primitive ctx site (.err success) [a] later).run before =
      .ok (.record [.scalar, a, .bottom], before) := by
  unfold primitive
  simp only [defaultConfig, default_has, Bool.false_eq_true, if_false]
  rfl

theorem result_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {op : Prim} {x : Atom} {o : Observation} {w : Value} {escapes : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueAtom : ValueSemantics.atom (valueEnv env) x = .ok o)
    (heapAtom : InPlaceSemantics.atom (heapEnv env) x = .ok w)
    (valuePrim : ∀ s, (ValueSemantics.prim op [o]).run s = .ok (value, s))
    (heapPrim : ∀ s, (InPlaceSemantics.prim op [w]).run s = .ok (actual, s))
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim op [x])).run vs =
      .ok (value, AtomPreservation.valueAtomPost vs) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim op [x])).run hs =
      .ok (actual, AtomPreservation.heapAtomPost hs vs.kept.toList) := by
  obtain ⟨footprint, represented⟩ := inv.observers
  have valueObservedRun := value_observeKept_run ({vs with fuel := vs.fuel - 1}) represented
  have heapObservedRun := heap_observeKept_run ({hs with fuel := hs.fuel - 1}) represented
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have valueAtoms : [x].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) = .ok [o] :=
    except_mapM_cons valueAtom rfl
  have heapAtoms : [x].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) = .ok [w] :=
    except_mapM_cons heapAtom rfl
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, valueTicked, AtomPreservation.valueAtomPost,
      AtomPreservation.valueTicked, valuePrim, valueObservedRun,
      Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, heapTicked, AtomPreservation.heapAtomPost,
      AtomPreservation.heapTicked, heapPrim, heapObservedRun,
      Except.bind, Except.pure, bind, pure]

/-- Both runtime directions of a result constructor from the operand's facts:
the record of the tag, the payload and the dead integer. -/
theorem result_preserved_of_parts {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {op : Prim} {x : Atom} {o : Observation} {w : Value} {escapes : List Origin} {type : Ty} {result : Abstract}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueAtom : ValueSemantics.atom (valueEnv env) x = .ok o)
    (heapAtom : InPlaceSemantics.atom (heapEnv env) x = .ok w)
    (valuePrim : ∀ s, (ValueSemantics.prim op [o]).run s = .ok (value, s))
    (heapPrim : ∀ s, (InPlaceSemantics.prim op [w]).run s = .ok (actual, s))
    (paired : Corresponds hs.heap value actual) (described : Describes gamma hs.heap result actual)
    (observed : obsTyped declarations value type = true)
    (valueTyped : ValueTyped declarations hs.heap actual type)
    (tags : ResultTags type result actual) :
    (∀ value' vs',
      (ValueSemantics.eval depth declarations none (valueEnv env) (.prim op [x])).run vs =
        .ok (value', vs') →
      ∃ actual' hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim op [x])).run hs =
          .ok (actual', hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value' actual' ∧ Describes gamma' hs'.heap result actual' ∧
        obsTyped declarations value' type = true ∧ ValueTyped declarations hs'.heap actual' type ∧
        ResultTags type result actual') ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env) (.prim op [x])).run vs =
        .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim op [x])).run hs =
          .error actualMessage) := by
  have valueAtoms : [x].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) = .ok [o] :=
    except_mapM_cons valueAtom rfl
  have heapAtoms : [x].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) = .ok [w] :=
    except_mapM_cons heapAtom rfl
  refine ⟨?_, ?_⟩
  · intro value' vs' run
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
      simp [noDepth] at run
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
        simp [noDepth, noFuel] at run
      · obtain ⟨valueRun, heapRun⟩ :=
          result_runtime_success inv valueAtom heapAtom valuePrim heapPrim noDepth noFuel
        rw [valueRun] at run
        cases run
        have heapSame := heapAtomPost_heap hs vs.kept.toList
        refine ⟨actual, AtomPreservation.heapAtomPost hs vs.kept.toList, gamma, heapRun,
          AtomPreservation.integer_atom_post_invariant inv,
          Nat.le_of_eq (congrArg Array.size heapSame.symm), ?_, ?_, observed, ?_, tags⟩
        · rw [heapSame]; exact paired
        · rw [heapSame]; exact described
        · rw [heapSame]; exact valueTyped
  · intro message failed
    by_cases noDepth : depth = 0
    · exact ⟨"in-place execution exhausted depth", by
        rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
        simp [noDepth]⟩
    · by_cases noFuel : vs.fuel = 0
      · have heapFuel : hs.fuel = 0 := inv.fuel.symm.trans noFuel
        exact ⟨"in-place execution exhausted fuel", by
          rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
          simp [noDepth, heapFuel]⟩
      · have success :=
          (result_runtime_success inv valueAtom heapAtom valuePrim heapPrim noDepth noFuel).1
        rw [success] at failed
        contradiction

theorem corresponds_ok {heap : Heap} {o : Observation} {w : Value} (paired : Corresponds heap o w) :
    Corresponds heap (.record [.int 1, .int 0, o]) (.record [.int 1, .int 0, w]) := by
  refine corresponds_record_of_fields rfl ?_
  intro i o' w' os_i ws_i
  rcases three_pair os_i ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
  · exact AtomPreservation.integer_corresponds _
  · exact AtomPreservation.integer_corresponds _
  · exact paired

theorem corresponds_err {heap : Heap} {o : Observation} {w : Value} (paired : Corresponds heap o w) :
    Corresponds heap (.record [.int 0, o, .int 0]) (.record [.int 0, w, .int 0]) := by
  refine corresponds_record_of_fields rfl ?_
  intro i o' w' os_i ws_i
  rcases three_pair os_i ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
  · exact AtomPreservation.integer_corresponds _
  · exact paired
  · exact AtomPreservation.integer_corresponds _

theorem describes_ok {gamma : Naming} {heap : Heap} {a : Abstract} {w : Value}
    (described : Describes gamma heap a w) :
    Describes gamma heap (.record [.scalar, .bottom, a]) (.record [.int 1, .int 0, w]) := by
  refine describes_record_of_fields rfl ?_
  intro i a' w' as_i ws_i
  rcases three_pair as_i ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
  · exact AtomPreservation.integer_described 1
  · exact integer_described_any _ 0
  · exact described

theorem describes_err {gamma : Naming} {heap : Heap} {a : Abstract} {w : Value}
    (described : Describes gamma heap a w) :
    Describes gamma heap (.record [.scalar, a, .bottom]) (.record [.int 0, w, .int 0]) := by
  refine describes_record_of_fields rfl ?_
  intro i a' w' as_i ws_i
  rcases three_pair as_i ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
  · exact AtomPreservation.integer_described 0
  · exact described
  · exact integer_described_any _ 0

theorem ok_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {error : Ty} {x : Atom} {self : Decl} {type : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (flatError : FlatType error)
    (typed : exprType declarations self tenv (.prim (.ok error) [x]) = .ok type)
    (covered : ∀ use ∈ atomUses x, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim (.ok error) [x]) after site).run before =
      .ok (result, next)) :
    next.facts.escapes = before.facts.escapes ∧ FlatType type ∧ FlatAbstract type result ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim (.ok error) [x])).run vs = .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim (.ok error) [x])).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv next.facts.escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧ Describes gamma' hs'.heap result actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        ResultTags type result actual) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim (.ok error) [x])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim (.ok error) [x])).run hs = .error actualMessage) := by
  obtain ⟨t, atomTyped, rfl⟩ := exprType_ok_success typed
  obtain ⟨o, w, a, valueAtom, heapAtom, abstractValue, paired, described, observed, valueTyped,
    flatT, shape, allocated, tags⟩ := flat_atom_values inv atomTyped covered
  have abstractAtoms : [x].mapM (m := Except String) (abstractAtom aenv) = .ok [a] :=
    except_mapM_cons abstractValue rfl
  obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  rw [primitive_ok_run] at run
  have equal := Except.ok.inj run
  have resultEq : result = .record [.scalar, .bottom, a] := (congrArg Prod.fst equal).symm
  have nextState : next = before := (congrArg Prod.snd equal).symm
  have nextEscapes : next.facts.escapes = before.facts.escapes := by rw [nextState]
  rw [nextEscapes]
  refine ⟨rfl, .result error t flatError flatT, ?_, ?_⟩
  · rw [resultEq]
    exact .result error t .bottom a (.bottom _) shape
  · rw [resultEq]
    refine result_preserved_of_parts (value := .record [.int 1, .int 0, o])
      (actual := .record [.int 1, .int 0, w]) inv valueAtom heapAtom
      (fun s => value_ok_run error s o) (fun s => heap_ok_run error s w)
      (corresponds_ok paired) (describes_ok described) ?_
      (valueTyped_of_allocated (.ok error t w allocated) inv.heapInts)
      (.ok error t _ _ _ w (resultTags_ne_bottom tags) tags)
    simpa [obsTyped] using observed

theorem err_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {success : Ty} {x : Atom} {self : Decl} {type : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (flatSuccess : FlatType success)
    (typed : exprType declarations self tenv (.prim (.err success) [x]) = .ok type)
    (covered : ∀ use ∈ atomUses x, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim (.err success) [x]) after site).run before =
      .ok (result, next)) :
    next.facts.escapes = before.facts.escapes ∧ FlatType type ∧ FlatAbstract type result ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim (.err success) [x])).run vs = .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim (.err success) [x])).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv next.facts.escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧ Describes gamma' hs'.heap result actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        ResultTags type result actual) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim (.err success) [x])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim (.err success) [x])).run hs = .error actualMessage) := by
  obtain ⟨t, atomTyped, rfl⟩ := exprType_err_success typed
  obtain ⟨o, w, a, valueAtom, heapAtom, abstractValue, paired, described, observed, valueTyped,
    flatT, shape, allocated, tags⟩ := flat_atom_values inv atomTyped covered
  have abstractAtoms : [x].mapM (m := Except String) (abstractAtom aenv) = .ok [a] :=
    except_mapM_cons abstractValue rfl
  obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  rw [primitive_err_run _ (show ({ctx with escaped := union ctx.escaped before.facts.escapes} :
    Context).config = {} from defaultConfig)] at run
  have equal := Except.ok.inj run
  have resultEq : result = .record [.scalar, a, .bottom] := (congrArg Prod.fst equal).symm
  have nextState : next = before := (congrArg Prod.snd equal).symm
  have nextEscapes : next.facts.escapes = before.facts.escapes := by rw [nextState]
  rw [nextEscapes]
  refine ⟨rfl, .result t success flatT flatSuccess, ?_, ?_⟩
  · rw [resultEq]
    exact .result t success a .bottom shape (.bottom _)
  · rw [resultEq]
    refine result_preserved_of_parts (value := .record [.int 0, o, .int 0])
      (actual := .record [.int 0, w, .int 0]) inv valueAtom heapAtom
      (fun s => value_err_run success s o) (fun s => heap_err_run success s w)
      (corresponds_err paired) (describes_err described) ?_
      (valueTyped_of_allocated (.err t success w allocated) inv.heapInts)
      (.err t success _ _ _ w (resultTags_ne_bottom tags) tags)
    simpa [obsTyped] using observed

end Ownership.FlatFragment.Result
