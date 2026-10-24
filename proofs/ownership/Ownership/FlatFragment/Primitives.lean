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

theorem primitive_literal_run (ctx : Context) (site : List Nat) (t : Ty) (xs : List Abstract)
    (later : List Origin) (before : St) :
    (primitive ctx site (.literal t) xs later).run before =
      .ok (.list [.site site 0] (xs.foldl Abstract.join .bottom)
        ⟨storeExclusive ctx xs later [], storeSpines ctx xs later []⟩, before) := by
  unfold primitive
  rfl

/-! ### The literal expression case -/

def heapAllocated (hs : State) (integers : List Int) : State :=
  {hs with fuel := hs.fuel - 1, heap := hs.heap.push (heapInts integers)}

def heapAllocatedValues (hs : State) (stored : List Value) : State :=
  {hs with fuel := hs.fuel - 1, heap := hs.heap.push stored}

theorem value_literal_run_values (s : ValueSemantics.State) (t : Ty) (os : List Observation) :
    (ValueSemantics.prim (.literal t) os).run s = .ok (.list os, s) := rfl

theorem heap_literal_run_values (hs : State) (t : Ty) (ws : List Value) :
    (prim (.literal t) ws).run (heapTicked hs) = .ok (.ref hs.heap.size, heapAllocatedValues hs ws) := rfl

theorem literal_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {depth : Nat} {t : Ty} {args : List Atom} {os : List Observation} {ws : List Value}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueAtoms : args.mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) = .ok os)
    (heapAtoms : args.mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) = .ok ws)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim (.literal t) args)).run vs =
      .ok (.list os, valueObserved (valueTicked vs)) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim (.literal t) args)).run hs =
      .ok (.ref hs.heap.size, heapObserved (heapAllocatedValues hs ws) vs.kept.toList) := by
  obtain ⟨footprint, represented⟩ := inv.observers
  have valueObservedRun := value_observeKept_run (valueTicked vs) represented
  have heapObservedRun := heap_observeKept_run (heapAllocatedValues hs ws)
    (representsMany_after_alloc (xs := ws) represented)
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, value_literal_run_values, valueObservedRun, Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, heap_literal_run_values, heapObservedRun, Except.bind, Except.pure, bind, pure]

theorem literal_failure {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {depth : Nat} {t : Ty} {args : List Atom} {os : List Observation} {ws : List Value} {message : String}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueAtoms : args.mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) = .ok os)
    (heapAtoms : args.mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) = .ok ws)
    (failed : (ValueSemantics.eval depth declarations none (valueEnv env)
      (.prim (.literal t) args)).run vs = .error message) :
    ∃ actualMessage,
      (InPlaceSemantics.eval depth declarations none (heapEnv env)
        (.prim (.literal t) args)).run hs = .error actualMessage := by
  by_cases noDepth : depth = 0
  · exact ⟨"in-place execution exhausted depth", by
      rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
      simp [noDepth]⟩
  · by_cases noFuel : vs.fuel = 0
    · have heapFuel : hs.fuel = 0 := inv.fuel.symm.trans noFuel
      exact ⟨"in-place execution exhausted fuel", by
        rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
        simp [noDepth, heapFuel]⟩
    · have success := (literal_runtime_success (t := t) inv valueAtoms heapAtoms noDepth noFuel).1
      rw [success] at failed
      contradiction

/-- The relation after an allocation of shaped values at the real address: the
naming extends at the site, every binding keeps its description (slice 2b of #522). -/
theorem alloc_post_invariant {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming}
    {vs' : ValueSemantics.State} {hs' : State}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (stored : List Value) (site : List Nat)
    (heapEq : hs'.heap = hs.heap.push stored) (links : hs'.links = [])
    (storedBounded : ∀ x ∈ stored, ∀ d, Reaches hs'.heap x (.ref d) → d < hs'.heap.size)
    (keptSame : hs'.kept = hs.kept) (valueKeptSame : vs'.kept = vs.kept)
    (reads : vs'.reads = hs'.reads) (external : vs'.externalReads = hs'.externalReads)
    (fuel : vs'.fuel = hs'.fuel) :
    ∃ gamma',
      FlatInvariant declarations vs' hs' env live aenv tenv escapes gamma' ∧
      hs.heap.size ∈ gamma' (.site site 0) ∧
      (∀ origin cell, cell < hs.heap.size → (cell ∈ gamma' origin ↔ cell ∈ gamma origin)) := by
  obtain ⟨gamma', extension, bounded, separating, old⟩ :=
    literal_allocation_naming (gamma := gamma) (heapSize := hs.heap.size)
      (fun origin address member => inv.namingBound origin address member) inv.separating site
  obtain ⟨footprint, represented⟩ := inv.observers
  refine ⟨gamma', ?_, (extension (.site site 0) hs.heap.size).mpr (Or.inr ⟨rfl, rfl⟩), old⟩
  refine flatInvariant_heap_frame inv (hole := hs.heap.size) (footprint := footprint)
    (fun _ member => member) (by rw [heapEq]; simp) ⟨stored, by rw [heapEq]; simp, storedBounded⟩ links ?_ ?_
    represented ?_ keptSame valueKeptSame old ?_ separating reads external fuel (fun _ escaped => escaped)
  · intro c different
    rw [heapEq]
    simp [Array.getElem?_push, different]
  · intro x p _ o w w' binding projected q c located
    have := live_path_below inv x p o w w' binding projected q c located
    omega
  · intro member
    have bound := representsMany_bound represented _ member
    omega
  · rw [heapEq]
    simp only [Array.size_push]
    intro origin address member
    exact bounded origin address member

/-- The relation after a literal: a fresh allocation at the real address, named
by the site. -/
theorem literal_post_invariant {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (integers : List Int) (site : List Nat) :
    ∃ gamma',
      FlatInvariant declarations (valueObserved (valueTicked vs))
        (heapObserved (heapAllocated hs integers) vs.kept.toList) env live aenv tenv escapes gamma' ∧
      hs.heap.size ∈ gamma' (.site site 0) ∧
      (∀ origin cell, cell < hs.heap.size → (cell ∈ gamma' origin ↔ cell ∈ gamma origin)) :=
  alloc_post_invariant inv (heapInts integers) site (by rw [heapObserved_heap]; rfl)
    (by rw [heapObserved_links]; exact inv.links)
    (fun x member d reach => by
      obtain ⟨i, _, rfl⟩ := List.mem_map.mp member
      exact (int_reaches_nothing reach).elim)
    (by rw [heapObserved_kept]; rfl)
    (by rw [valueObserved_kept]; rfl) (by rw [valueObserved_reads, heapObserved_reads]; exact inv.reads)
    (observed_external (valueTicked vs) (heapAllocated hs integers) inv.keptSize inv.external)
    (by rw [valueObserved_fuel, heapObserved_fuel]; simp [valueTicked, heapAllocated, inv.fuel])

/-- The literal expression case over element values (slice 2b of #522): typing
fixes the operand types to the element type, the live uses supply the values,
the fresh array is described by the fold of the items' abstracts, and the
checker's exclusivity and spine certificates hold for its footprint. -/
theorem literal_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {args : List Atom} {self : Decl} {type : Ty} {t : Ty}
    (elemT : ElementType t)
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.prim (.literal t) args) = .ok type)
    (covered : ∀ atom ∈ args, ∀ use ∈ atomUses atom, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim (.literal t) args) after site).run before =
      .ok (result, next)) :
    FlatType type ∧ next.facts.escapes = before.facts.escapes ∧ FlatAbstract type result ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim (.literal t) args)).run vs = .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim (.literal t) args)).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv next.facts.escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧ Describes gamma' hs'.heap result actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        AllocatedFlatValue hs'.heap actual type ∧
        ResultTags type result actual ∧ ChainTags type result value) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim (.literal t) args)).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim (.literal t) args)).run hs = .error actualMessage) := by
  obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
  obtain ⟨listType, allT⟩ := primType_literal_success primTyped
  subst listType
  have typesT : ∀ ty ∈ types, ty = t := fun ty member =>
    ty_equal_flat_right (elementType_flat elemT) (allT ty member)
  obtain ⟨os, ws, as, valueAtoms, heapAtoms, abstractAtoms, lenO, lenW, lenA, fields⟩ :=
    flat_atoms_values inv atomsTyped covered
  have factsAt : ∀ (i : Nat) o w a, os[i]? = some o → ws[i]? = some w → as[i]? = some a →
      Corresponds hs.heap o w ∧ Describes gamma hs.heap a w ∧
      obsTyped declarations o t = true ∧ ValueTyped declarations hs.heap w t ∧
      FlatType t ∧ FlatAbstract t a ∧ AllocatedFlatValue hs.heap w t ∧ ResultTags t a w ∧ ChainTags t a o := by
    intro i o w a os_i ws_i as_i
    obtain ⟨ty, types_i⟩ := index_of_same_length lenO os_i
    have facts := fields i o w a ty os_i ws_i as_i types_i
    rw [typesT ty (List.mem_of_getElem? types_i)] at facts
    exact facts
  have witnesses : ∀ (i : Nat) w, ws[i]? = some w → ∃ o a, os[i]? = some o ∧ as[i]? = some a := by
    intro i w ws_i
    obtain ⟨o, os_i⟩ := index_of_same_length (lenW.trans lenO.symm) ws_i
    obtain ⟨a, as_i⟩ := index_of_same_length (lenW.trans lenA.symm) ws_i
    exact ⟨o, a, os_i, as_i⟩
  have shapesA : ∀ a ∈ as, FlatAbstract t a := by
    intro a member
    obtain ⟨i, as_i⟩ := List.mem_iff_getElem?.mp member
    obtain ⟨o, os_i⟩ := index_of_same_length (lenA.trans lenO.symm) as_i
    obtain ⟨w, ws_i⟩ := index_of_same_length (lenA.trans lenW.symm) as_i
    exact (factsAt i o w a os_i ws_i as_i).2.2.2.2.2.1
  have elemsShaped : ∀ w ∈ ws, AllocatedFlatValue hs.heap w t := by
    intro w member
    obtain ⟨i, ws_i⟩ := List.mem_iff_getElem?.mp member
    obtain ⟨o, a, os_i, as_i⟩ := witnesses i w ws_i
    exact (factsAt i o w a os_i ws_i as_i).2.2.2.2.2.2.1
  have foldShape : FlatAbstract t (as.foldl Abstract.join .bottom) :=
    flatAbstract_fold_join shapesA .bottom (.bottom t)
  obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  rw [primitive_literal_run] at run
  obtain ⟨first, second⟩ := Prod.mk.inj (Except.ok.inj run)
  have resultEq := first.symm
  have nextEscapes : next.facts.escapes = before.facts.escapes := by rw [← second]
  refine ⟨.list t elemT, nextEscapes, by rw [resultEq]; exact .list _ _ _ _ (by simp) foldShape, ?_, ?_⟩
  · intro value vs' run'
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run'
      simp [noDepth] at run'
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run'
        simp [noDepth, noFuel] at run'
      · obtain ⟨valueRun, heapRun⟩ := literal_runtime_success (t := t) inv valueAtoms heapAtoms noDepth noFuel
        rw [valueRun] at run'
        cases run'
        have heapEq : (heapObserved (heapAllocatedValues hs ws) vs.kept.toList).heap = hs.heap.push ws := by
          rw [heapObserved_heap]; rfl
        have lookupNew : (hs.heap.push ws)[hs.heap.size]? = some ws := by simp
        have agree : ∀ w ∈ ws, ∀ c, Reaches hs.heap w (.ref c) → (hs.heap.push ws)[c]? = hs.heap[c]? := by
          intro w member c reach
          have bound := allocated_reach_bound (elemsShaped w member) reach
          simp [Array.getElem?_push, Nat.ne_of_lt bound]
        have shapedZ : ∀ w ∈ ws, AllocatedFlatValue (hs.heap.push ws) w t :=
          fun w member => allocated_of_agree (elemsShaped w member) (agree w member)
        have shapedNew : AllocatedFlatValue (hs.heap.push ws) (.ref hs.heap.size) (.list t) :=
          .list _ ws t lookupNew shapedZ
        obtain ⟨gamma', postInvariant, fresh, old⟩ := alloc_post_invariant inv ws site heapEq
          (by rw [heapObserved_links]; exact inv.links)
          (fun w member d reach => by
            rw [heapEq] at reach ⊢
            exact allocated_reach_bound (shapedZ w member) reach)
          (by rw [heapObserved_kept]; rfl) (by rw [valueObserved_kept]; rfl)
          (by rw [valueObserved_reads, heapObserved_reads]; exact inv.reads)
          (observed_external (valueTicked vs) (heapAllocatedValues hs ws) inv.keptSize inv.external)
          (by rw [valueObserved_fuel, heapObserved_fuel]; simp [valueTicked, heapAllocatedValues, inv.fuel])
        have rootNamed' : named gamma' [.site site 0] hs.heap.size := ⟨.site site 0, by simp, fresh⟩
        have rootApart : ∀ w ∈ ws, ¬ Reaches (hs.heap.push ws) w (.ref hs.heap.size) := by
          intro w member reach
          have := allocated_reach_bound (elemsShaped w member) (reaches_of_agree_rev (agree w member) reach)
          omega
        -- each item, described under the extended naming and in the new heap
        have itemFacts : ∀ (i : Nat) w, ws[i]? = some w → ∃ a, as[i]? = some a ∧ FlatAbstract t a ∧
            Describes gamma' hs.heap a w ∧ Describes gamma' (hs.heap.push ws) a w := by
          intro i w ws_i
          obtain ⟨o, a, os_i, as_i⟩ := witnesses i w ws_i
          have facts := factsAt i o w a os_i ws_i as_i
          have described' : Describes gamma' hs.heap a w :=
            describes_naming_same facts.2.2.2.2.2.2.1 old
              (fun c reach => allocated_reach_bound facts.2.2.2.2.2.2.1 reach) facts.2.1
          exact ⟨a, as_i, facts.2.2.2.2.2.1, described', describes_of_agree (agree w (List.mem_of_getElem? ws_i)) described'⟩
        have elementsDescribed : ∀ w ∈ ws,
            Describes gamma' (hs.heap.push ws) (as.foldl Abstract.join .bottom) w := by
          intro w member
          obtain ⟨i, ws_i⟩ := List.mem_iff_getElem?.mp member
          obtain ⟨a, as_i, shapeA, _, describedNew⟩ := itemFacts i w ws_i
          exact describes_fold_join (shapedZ w member) shapesA .bottom (.bottom t)
            (Or.inr ⟨a, List.mem_of_getElem? as_i, describedNew⟩)
        -- the cross-item apartness the exclusivity test gives, and the container apartness the spine test gives
        have describedNew : Describes gamma' (hs.heap.push ws) result (.ref hs.heap.size) := by
          rw [resultEq]
          refine list_described_of_elements rootNamed' (by simp) lookupNew shapedNew elementsDescribed ?_ ?_
          · intro d
            obtain ⟨deepAll, sepVals, _⟩ := storeExclusive_facts_many d
            obtain ⟨eachSep, cross⟩ := separatedValues_sound sepVals
            refine fresh_footprint_nodup lookupNew rootApart ?_ ?_
            · intro i w ws_i n o fp rep
              obtain ⟨a, as_i, shapeA, described', _⟩ := itemFacts i w ws_i
              have aMember := List.mem_of_getElem? as_i
              exact nodup_of_deepExclusive (elemsShaped w (List.mem_of_getElem? ws_i)) shapeA described'
                (deepAll a aMember) (pathsApart_of_separated postInvariant.separating (eachSep a aMember)) n o fp
                (represents_of_agree_rev (agree w (List.mem_of_getElem? ws_i)) rep)
            · intro i j ne wi wj ws_i ws_j c reachI reachJ
              obtain ⟨ai, as_i, shapeI, describedI, _⟩ := itemFacts i wi ws_i
              obtain ⟨aj, as_j, shapeJ, describedJ, _⟩ := itemFacts j wj ws_j
              have reachI' := reaches_of_agree_rev (agree wi (List.mem_of_getElem? ws_i)) reachI
              have reachJ' := reaches_of_agree_rev (agree wj (List.mem_of_getElem? ws_j)) reachJ
              rcases Nat.lt_or_gt_of_ne ne with lt | gt
              · exact reach_apart_of_covers postInvariant.separating shapeI shapeJ describedI.1.1 describedJ.1.1
                  (cross i j lt ai aj as_i as_j) c reachI' reachJ'
              · exact reach_apart_of_covers postInvariant.separating shapeJ shapeI describedJ.1.1 describedI.1.1
                  (cross j i gt aj ai as_j as_i) c reachJ' reachI'
          · intro sp
            obtain ⟨sepFlat, perItem⟩ := storeSpines_facts_many sp
            refine fresh_footprint_once lookupNew rootApart ?_ ?_
            · intro i w ws_i n o fp rep p c container located
              obtain ⟨a, as_i, shapeA, described', _⟩ := itemFacts i w ws_i
              have aMember := List.mem_of_getElem? as_i
              have wMember := List.mem_of_getElem? ws_i
              exact once_of_separated postInvariant.separating shapeA (elemsShaped w wMember) described'.1.1
                (separatedPaths_sublist (sublist_flatMap_of_mem aMember) sepFlat)
                (fun e eMember f fMember => (perItem a aMember e eMember).2 a aMember f fMember)
                n o fp (represents_of_agree_rev (agree w wMember) rep) p c container
                (atPath_of_agree_rev (agree w wMember) located)
            · intro i j ne wi wj ws_i ws_j p c container located reachJ
              obtain ⟨ai, as_i, shapeI, describedI, _⟩ := itemFacts i wi ws_i
              obtain ⟨aj, as_j, shapeJ, describedJ, _⟩ := itemFacts j wj ws_j
              have located' := atPath_of_agree_rev (agree wi (List.mem_of_getElem? ws_i)) located
              have reachJ' := reaches_of_agree_rev (agree wj (List.mem_of_getElem? ws_j)) reachJ
              obtain ⟨q, locatedJ⟩ := arrayAt_of_reaches reachJ'
              obtain ⟨oI, mI, aI⟩ := describedI.1.1 p c located'
              obtain ⟨oJ, mJ, aJ⟩ := describedJ.1.1 q c locatedJ
              obtain ⟨cs, eI, inI⟩ :=
                mem_namesAt_of_arrayAt shapeI (elemsShaped wi (List.mem_of_getElem? ws_i)) p c oI located' mI
              obtain ⟨ds, eJ, inJ⟩ :=
                mem_namesAt_of_arrayAt shapeJ (elemsShaped wj (List.mem_of_getElem? ws_j)) q c oJ locatedJ mJ
              have cI : (p, cs) ∈ containers ai := List.mem_filter.mpr ⟨eI, container⟩
              rcases (perItem ai (List.mem_of_getElem? as_i) (p, cs) cI).2 aj (List.mem_of_getElem? as_j) (q, ds) eJ
                with containerQ | disjoint
              · have cJ : (q, ds) ∈ containers aj := List.mem_filter.mpr ⟨eJ, containerQ⟩
                rcases Nat.lt_or_gt_of_ne ne with lt | gt
                · exact cellOverlap_sound gamma' postInvariant.separating cs ds
                    (separatedPaths_flatMap_cross sepFlat i j lt ai aj as_i as_j (p, cs) cI (q, ds) cJ) c
                    ⟨oI, inI, aI⟩ ⟨oJ, inJ, aJ⟩
                · exact cellOverlap_sound gamma' postInvariant.separating ds cs
                    (separatedPaths_flatMap_cross sepFlat j i gt aj ai as_j as_i (q, ds) cJ (p, cs) cI) c
                    ⟨oJ, inJ, aJ⟩ ⟨oI, inI, aI⟩
              · exact cellOverlap_sound gamma' postInvariant.separating cs ds disjoint c ⟨oI, inI, aI⟩ ⟨oJ, inJ, aJ⟩
        refine ⟨.ref hs.heap.size, heapObserved (heapAllocatedValues hs ws) vs.kept.toList, gamma',
          heapRun, by rw [nextEscapes]; exact postInvariant, ?_, ?_, ?_, ?_, ?_, ?_,
          by rw [resultEq]; exact .list _ _ _ _ _, .list _ _ _⟩
        · rw [heapEq]; simp
        · rw [heapEq]
          exact corresponds_list_of_elements lookupNew (lenO.trans lenW.symm) (fun i o w os_i ws_i => by
            obtain ⟨o', a, os_i', as_i⟩ := witnesses i w ws_i
            rw [os_i] at os_i'
            cases Option.some.inj os_i'
            exact corresponds_of_agree (agree w (List.mem_of_getElem? ws_i)) (factsAt i o w a os_i ws_i as_i).1)
        · rw [heapEq]; exact describedNew
        · exact obsTyped_list_of_elements (fun o member => by
            obtain ⟨i, os_i⟩ := List.mem_iff_getElem?.mp member
            obtain ⟨w, ws_i⟩ := index_of_same_length (lenO.trans lenW.symm) os_i
            obtain ⟨o', a, os_i', as_i⟩ := witnesses i w ws_i
            rw [os_i] at os_i'
            cases Option.some.inj os_i'
            exact (factsAt i o w a os_i ws_i as_i).2.2.1)
        · rw [heapEq]; exact valueTyped_of_allocated shapedNew
        · rw [heapEq]; exact shapedNew
  · intro message failed
    exact literal_failure (t := t) inv valueAtoms heapAtoms failed

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
    ∃ t, ty = .list t ∧ type = .int := by
  cases flat with
  | int => simp [primType] at run
  | record _ _ => simp [primType] at run
  | result _ _ _ _ => simp [primType] at run
  | chainInt => simp [primType] at run
  | list t _ =>
    simp [primType] at run
    have typeInt : type = .int := by cases run; rfl
    exact ⟨t, rfl, typeInt⟩

/-- The single-operand typing equation of a length expression. -/
theorem exprType_length_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {receiver : Atom} {self : Decl} {type : Ty} {escapes : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (typed : exprType declarations self tenv (.prim .length [receiver]) = .ok type) :
    ∃ t, atomType tenv receiver = .ok (.list t) ∧ type = .int := by
  obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
  obtain ⟨headType, rest, headTyped, restTyped, shape⟩ := except_mapM_cons_success atomsTyped
  have restNil := except_mapM_nil_success restTyped
  subst shape
  subst restNil
  obtain ⟨t, listType, intType⟩ := primType_length_success (flat_atom_type inv headTyped) primTyped
  subst listType
  exact ⟨t, headTyped, intType⟩

theorem value_length_run (s : ValueSemantics.State) (os : List Observation) :
    (ValueSemantics.prim .length [.list os]).run s =
      .ok (.int os.length, {s with reads := s.reads.push (.int os.length)}) := by
  simp [ValueSemantics.prim, ValueSemantics.read, ValueSemantics.observable, Observation.depth,
    observationDepth, StateT.run, StateT.bind, StateT.map, StateT.get, StateT.set,
    StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe,
    MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, modify,
    modifyGet, MonadStateOf.modifyGet, StateT.modifyGet]

theorem heap_length_run (s : State) (ys : List Value)
    (lookup : s.heap[root]? = some ys) :
    (prim .length [.ref root]).run s =
      .ok (.int ys.length, {s with reads := s.reads.push (.int ys.length)}) := by
  simp [prim, array, lookup, InPlaceSemantics.read, snapshot, observationDepth,
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
    (valueAtom : ValueSemantics.atom (valueEnv env) receiver = .ok (.list os))
    (heapAtom : InPlaceSemantics.atom (heapEnv env) receiver = .ok (.ref root))
    (lookup : hs.heap[root]? = some ys) (len : os.length = ys.length)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim .length [receiver])).run vs =
      .ok (.int os.length, valueRead vs (.int os.length)) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim .length [receiver])).run hs =
      .ok (.int os.length, heapRead hs (.int os.length) vs.kept.toList) := by
  obtain ⟨footprint, represented⟩ := inv.observers
  have valueObservedRun := value_observeKept_run
    ({vs with fuel := vs.fuel - 1, reads := vs.reads.push (.int os.length)}) represented
  have heapObservedRun := heap_observeKept_run
    ({hs with fuel := hs.fuel - 1, reads := hs.reads.push (.int ys.length)}) represented
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have valueAtoms : [receiver].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.list os] := except_mapM_cons valueAtom rfl
  have heapAtoms : [receiver].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref root] := except_mapM_cons heapAtom rfl
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, valueTicked, value_length_run, valueObservedRun, valueRead,
      Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, heapTicked, heap_length_run {hs with fuel := hs.fuel - 1} ys lookup, len,
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
        AllocatedFlatValue hs'.heap actual type ∧
        ResultTags type result actual ∧ ChainTags type result value) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .length [receiver])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .length [receiver])).run hs = .error actualMessage) := by
  obtain ⟨t, receiverTyped, intType⟩ := exprType_length_success inv typed
  subst intType
  obtain ⟨root, ys, os, roots, element, certificate, lookup, _, _, _, _, _, _, _, len, _, _, _, _,
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
        .ok [.list os] := except_mapM_cons valueAtom rfl
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
      simp [noDepth] at run
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
        simp [noDepth, noFuel] at run
      · obtain ⟨valueRun, heapRun⟩ :=
          length_runtime_success inv valueAtom heapAtom lookup len noDepth noFuel
        rw [valueRun] at run
        cases run
        refine ⟨.int os.length, heapRead hs (.int os.length) vs.kept.toList, gamma,
          heapRun, ?_, ?_, Ownership.FlatFragment.AtomPreservation.integer_corresponds _, ?_, by simp [obsTyped],
          ⟨1, .int os.length, [], .int, by simp [obsTyped]⟩, .int _, by rw [resultScalar]; exact .int _,
          .int _ _⟩
        · rw [nextEscapes]; exact read_post_invariant inv _
        · exact Nat.le_of_eq (by unfold heapRead; rw [heapObserved_heap])
        · rw [resultScalar]; exact Ownership.FlatFragment.AtomPreservation.integer_described _
  · intro message failed
    have valueAtoms : [receiver].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
        .ok [.list os] := except_mapM_cons valueAtom rfl
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
      · have success := (length_runtime_success inv valueAtom heapAtom lookup len noDepth noFuel).1
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
        AllocatedFlatValue hs'.heap actual type ∧
        ResultTags type result actual ∧ ChainTags type result value) ∧
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
          by simp [obsTyped], ⟨1, .int (scalarResult op x y), [], .int, by simp [obsTyped]⟩, .int _,
          by rw [resultScalar]; exact .int _, .int _ _⟩
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
    links := by unfold heapShared; rw [heapObserved_links]; exact inv.links
    abstractKeys := inv.abstractKeys
    typeKeys := inv.typeKeys
    types := inv.types
    abstractShapes := inv.abstractShapes
    bindingsTyped := by simpa only [heapSame] using inv.bindingsTyped
    bindingsBounded := by simpa only [heapSame] using inv.bindingsBounded
    tags := inv.tags
    chains := inv.chains
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
        AllocatedFlatValue hs'.heap actual type ∧
        ResultTags type result actual ∧ ChainTags type result value) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .shared [atom])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .shared [atom])).run hs = .error actualMessage) := by
  have atomTyped := exprType_shared_success typed
  obtain ⟨x, v, a, valueAtom, heapAtom, abstractValue, paired, described, observed, valueTyped,
    flatType, shape, allocated, tags, chains⟩ := flat_atom_values inv atomTyped covered
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
    rw [← first]; exact flatAbstract_mapOrigins sharedMark (fun path cs h => sharedMark_no_unknown path h) shape []
  have resultDescribed : Describes gamma hs.heap result v := by
    rw [← first]; exact describes_mapOrigins_shared allocated shape described []
  have mono : ∀ origin, Escaped before.facts.escapes origin → Escaped next.facts.escapes origin := by
    intro origin escaped
    rw [escapesEq]
    exact escaped_mono _ escaped
  have newEscaped : ∀ c, Reaches hs.heap v (.ref c) → ∀ origin, c ∈ gamma origin →
      Escaped next.facts.escapes origin := by
    intro c reachable origin member
    obtain ⟨q, located⟩ := arrayAt_of_reaches reachable
    have names := named_cells_of_covers shape described.1.1 located
    rw [escapesEq]
    exact named_cell_escaped inv.separating names member (fun o h => h)
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
          Nat.le_of_eq (congrArg Array.size heapSame.symm), ?_, ?_, observed, ?_, ?_, ?_, ?_⟩
        · rw [heapSame]; exact paired
        · rw [heapSame]; exact resultDescribed
        · rw [heapSame]; exact valueTyped
        · rw [heapSame]; exact allocated
        · rw [← first]; exact resultTags_mapOrigins _ tags []
        · rw [← first]; exact chainTags_mapOrigins _ chains []
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

/-- The checker's push result under the default configuration: the item joins
the element, and the certificate records the store tests (slice 2b of #522). -/
theorem primitive_push_result_values {ctx : Context} {site : List Nat} {before next : St} {result : Abstract}
    {roots later : List Origin} {element item : Abstract} {certificate : Certificate}
    (defaultConfig : ctx.config = {})
    (run : (primitive ctx site .push [.list roots element certificate, item] later).run before =
      .ok (result, next)) :
    result = .list roots (element.join item)
      ⟨certificate.deep && storeExclusive ctx [item] later element.cells,
       certificate.spine && storeSpines ctx [item] later element.cells &&
         (containers element).all (fun (_, old) => individuallyOwned ctx old && !cellOverlap old item.cells)⟩ := by
  unfold primitive at run
  obtain ⟨finished, middle, _, returned⟩ := checkM_bind_success run
  cases finished
  have equal := Except.ok.inj returned
  have first : _ = result := congrArg Prod.fst equal
  rw [← first]
  simp [defaultConfig, default_has, Abstract.grantExclusive, show (Prim.push == Prim.put) = false from rfl]

theorem liveCellsWith_default (env : Env Abstract) (l : Live) :
    liveCellsWith ({} : Config) env l = liveCells env l := by
  simp [liveCellsWith, default_has]

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

theorem primType_push_success {type : Ty} {tR : Ty} {tI : Ty} (flatR : FlatType tR)
    (run : primType .push [tR, tI] = .ok type) :
    ∃ t, tR = .list t ∧ tI = t ∧ type = .list t := by
  cases flatR with
  | list t elemT =>
    simp [primType] at run
    split at run
    · rename_i same
      have : t = tI := ty_equal_flat (elementType_flat elemT) (by simpa using same)
      have typeEq : type = .list t := by cases run; rfl
      exact ⟨t, rfl, this.symm, typeEq⟩
    · cases run
  | _ => simp [primType] at run

theorem exprType_push_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {self : Decl} {receiver item : Atom} {type : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (typed : exprType declarations self tenv (.prim .push [receiver, item]) = .ok type) :
    ∃ t, atomType tenv receiver = .ok (.list t) ∧ atomType tenv item = .ok t ∧ type = .list t := by
  obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
  obtain ⟨tR, rest, headTyped, restTyped, shape⟩ := except_mapM_cons_success atomsTyped
  obtain ⟨tI, rest', itemTyped, restTyped', shape'⟩ := except_mapM_cons_success restTyped
  have restNil := except_mapM_nil_success restTyped'
  subst shape
  subst shape'
  subst restNil
  obtain ⟨t, listType, itemType, resultType⟩ := primType_push_success (flat_atom_type inv headTyped) primTyped
  subst listType
  subst tI
  exact ⟨t, headTyped, itemTyped, resultType⟩

/-! ### Runtime -/

def heapPushedValues (hs : State) (root : Nat) (ys : List Value) (item : Value) : State :=
  { hs with
    fuel := hs.fuel - 1
    heap := hs.heap.set! root (ys ++ [item])
    writes := (if ys == ys ++ [item] then hs.writes else hs.writes + 1) }

theorem value_push_run_values (s : ValueSemantics.State) (os : List Observation) (o : Observation) :
    (ValueSemantics.prim .push [.list os, o]).run s = .ok (.list (os ++ [o]), s) := rfl

theorem heap_push_run_values (s : State) (ys : List Value) (item : Value)
    (lookup : s.heap[root]? = some ys) (links : s.links = []) :
    (prim .push [.ref root, item]).run s = .ok (.ref root, {s with heap := s.heap.set! root (ys ++ [item]), writes := if ys == ys ++ [item] then s.writes else s.writes + 1}) := by
  have written := writeCounted_empty_run (root := root) (stored := ys ++ [item]) s lookup links
  simpa [prim, array, lookup, StateT.run, StateT.bind, StateT.get, Option.toExcept, Except.bind, Except.pure,
    bind, pure, get, getThe, MonadStateOf.get, StateT.pure, StateT.lift, liftM, monadLift,
    MonadLift.monadLift] using written

/-- The correspondence of two lists extends to one element appended to each. -/
theorem pointwise_snoc {heap : Heap} {os : List Observation} {ys : List Value} {o : Observation} {w : Value}
    (lenO : os.length = ys.length)
    (pointwise : ∀ (i : Nat) o' y, os[i]? = some o' → ys[i]? = some y → Corresponds heap o' y)
    (paired : Corresponds heap o w) :
    ∀ (i : Nat) o' y, (os ++ [o])[i]? = some o' → (ys ++ [w])[i]? = some y → Corresponds heap o' y := by
  intro i o' y os_i ys_i
  by_cases lt : i < os.length
  · rw [List.getElem?_append_left lt] at os_i
    rw [List.getElem?_append_left (by omega)] at ys_i
    exact pointwise i o' y os_i ys_i
  · have le : os.length ≤ i := Nat.le_of_not_lt lt
    rw [List.getElem?_append_right le] at os_i
    rw [List.getElem?_append_right (by omega)] at ys_i
    cases h : i - os.length with
    | zero =>
      have h' : i - ys.length = 0 := by omega
      rw [h] at os_i
      rw [h'] at ys_i
      simp at os_i ys_i
      subst os_i
      subst ys_i
      exact paired
    | succ k =>
      rw [h] at os_i
      simp at os_i

theorem push_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {receiver item : Atom} {os : List Observation} {ys : List Value} {o : Observation} {w : Value} {root : Nat} {footprint : List Nat} {depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueReceiver : ValueSemantics.atom (valueEnv env) receiver = .ok (.list os))
    (heapReceiver : InPlaceSemantics.atom (heapEnv env) receiver = .ok (.ref root))
    (valueItem : ValueSemantics.atom (valueEnv env) item = .ok o)
    (heapItem : InPlaceSemantics.atom (heapEnv env) item = .ok w)
    (lookup : hs.heap[root]? = some ys)
    (rootOutside : root ∉ footprint)
    (represented : RepresentsMany hs.heap observationDepth hs.kept.toList vs.kept.toList footprint)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim .push [receiver, item])).run vs =
      .ok (.list (os ++ [o]), valueObserved (valueTicked vs)) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim .push [receiver, item])).run hs =
      .ok (.ref root, heapObserved (heapPushedValues hs root ys w) vs.kept.toList) := by
  have valueObservedRun := value_observeKept_run (valueTicked vs) represented
  have framed : RepresentsMany (hs.heap.set! root (ys ++ [w])) observationDepth
      hs.kept.toList vs.kept.toList footprint :=
    representsMany_after_write (xs := ys ++ [w]) represented rootOutside
  have heapObservedRun : InPlaceSemantics.observeKept.run (heapPushedValues hs root ys w) =
      .ok ((), heapObserved (heapPushedValues hs root ys w) vs.kept.toList) :=
    heap_observeKept_run (heapPushedValues hs root ys w) framed
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have valueAtoms : [receiver, item].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.list os, o] := except_mapM_cons valueReceiver (except_mapM_cons valueItem rfl)
  have heapAtoms : [receiver, item].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref root, w] := except_mapM_cons heapReceiver (except_mapM_cons heapItem rfl)
  have pushRun : (prim .push [.ref root, w]).run (heapTicked hs) =
      .ok (.ref root, heapPushedValues hs root ys w) :=
    heap_push_run_values (heapTicked hs) ys w lookup inv.links
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, value_push_run_values, valueObservedRun, Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, pushRun, heapObservedRun, Except.bind, Except.pure, bind, pure]

theorem push_failure {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {receiver item : Atom} {os : List Observation} {ys : List Value} {o : Observation} {w : Value} {root : Nat} {footprint : List Nat} {depth : Nat} {message : String}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueReceiver : ValueSemantics.atom (valueEnv env) receiver = .ok (.list os))
    (heapReceiver : InPlaceSemantics.atom (heapEnv env) receiver = .ok (.ref root))
    (valueItem : ValueSemantics.atom (valueEnv env) item = .ok o)
    (heapItem : InPlaceSemantics.atom (heapEnv env) item = .ok w)
    (lookup : hs.heap[root]? = some ys)
    (rootOutside : root ∉ footprint)
    (represented : RepresentsMany hs.heap observationDepth hs.kept.toList vs.kept.toList footprint)
    (failed : (ValueSemantics.eval depth declarations none (valueEnv env)
      (.prim .push [receiver, item])).run vs = .error message) :
    ∃ actualMessage,
      (InPlaceSemantics.eval depth declarations none (heapEnv env)
        (.prim .push [receiver, item])).run hs = .error actualMessage := by
  have heapAtoms : [receiver, item].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref root, w] := except_mapM_cons heapReceiver (except_mapM_cons heapItem rfl)
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

theorem push_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {receiver item : Atom} {type : Ty} {self : Decl} {ctx : Context} {after : Live} {site : List Nat} {before next : St} {result : Abstract} {inferenceFuel depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.prim .push [receiver, item]) = .ok type)
    (coveredR : ∀ use ∈ atomUses receiver, use ∈ live)
    (coveredI : ∀ use ∈ atomUses item, use ∈ live)
    (afterSub : ∀ use ∈ after, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim .push [receiver, item]) after site).run before =
      .ok (result, next)) :
    FlatType type ∧ next.facts.escapes = before.facts.escapes ∧ FlatAbstract type result ∧
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
        AllocatedFlatValue hs'.heap actual type ∧
        ResultTags type result actual ∧ ChainTags type result value) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .push [receiver, item])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .push [receiver, item])).run hs = .error actualMessage) := by
  obtain ⟨t, receiverTyped, itemTyped, listType⟩ := exprType_push_success inv typed
  subst listType
  obtain ⟨root, ys, os, roots, element, certificate, lookup, receiverNamed, noUnk, _, elemT, elemShape,
    elemsShaped, elemsDescribed, lenO, elemsTyped, pointwise, pairedList, described,
    valueReceiver, heapReceiver, abstractReceiver⟩ := flat_atom_list_path inv receiverTyped coveredR
  obtain ⟨o, w, aN, valueItem, heapItem, abstractItem, pairedN, describedN, observedN, _, _, shapeN,
    allocatedN, _, _⟩ := flat_atom_values inv itemTyped coveredI
  have abstractAtoms : [receiver, item].mapM (m := Except String) (abstractAtom aenv) =
      .ok [.list roots element certificate, aN] :=
    except_mapM_cons abstractReceiver (except_mapM_cons abstractItem rfl)
  obtain ⟨childFuel, _, scope, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  have demanded := primitive_push_demand_run run
  rw [show ({ctx with escaped := union ctx.escaped before.facts.escapes} : Context).config = {} from
    defaultConfig, liveCellsWith_default] at demanded
  have escapesEq := demand_success_escapes demanded
  have resultEq := primitive_push_result_values
    (show ({ctx with escaped := union ctx.escaped before.facts.escapes} : Context).config = {} from
      defaultConfig) run
  obtain ⟨footprint, represented⟩ := inv.observers
  have rootOutside : root ∉ footprint :=
    demand_success_observer_footprint inv.toInvariant demanded receiverNamed represented
  have separate := demand_success_live_separate inv.separating demanded
  have apart := live_path_apart inv scope afterSub receiverNamed separate
  have itemApartRoot : ¬ Reaches hs.heap w (.ref root) :=
    value_apart_root shapeN describedN.1.1 receiverNamed (demand_success_disjoint inv.separating demanded)
      (fun o' member => mem_union _ _ _ (Or.inr member))
  refine ⟨.list t elemT, escapesEq, by rw [resultEq]; exact .list _ _ _ _ noUnk (flatAbstract_join elemShape shapeN),
    ?_, ?_⟩
  · intro value vs' run'
    have valueAtoms : [receiver, item].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
        .ok [.list os, o] := except_mapM_cons valueReceiver (except_mapM_cons valueItem rfl)
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
        have heapEq : (heapObserved (heapPushedValues hs root ys w) vs.kept.toList).heap =
            hs.heap.set! root (ys ++ [w]) := by
          rw [heapObserved_heap]; rfl
        have lookupNew : (hs.heap.set! root (ys ++ [w]))[root]? = some (ys ++ [w]) := by simp [valid]
        have sizeEq : (hs.heap.set! root (ys ++ [w])).size = hs.heap.size := by simp
        obtain ⟨cs0, represented0⟩ := represents_of_snapshot _ _ _ (pairedList _ (Nat.le_refl _))
        have agreeOld : ∀ y ∈ ys, ∀ c, Reaches hs.heap y (.ref c) →
            (hs.heap.set! root (ys ++ [w]))[c]? = hs.heap[c]? :=
          fun y member => element_agree_after_write represented0 lookup member
        have agreeItem : ∀ c, Reaches hs.heap w (.ref c) → (hs.heap.set! root (ys ++ [w]))[c]? = hs.heap[c]? :=
          fun c reach => lookup_set_other hs.heap root _ (fun same => itemApartRoot (same ▸ reach))
        have shapedZ : ∀ z ∈ ys ++ [w], AllocatedFlatValue (hs.heap.set! root (ys ++ [w])) z t := by
          intro z member
          rcases List.mem_append.mp member with old | new
          · exact allocated_of_agree (elemsShaped z old) (agreeOld z old)
          · rw [List.mem_singleton.mp new]
            exact allocated_of_agree allocatedN agreeItem
        have shapedNew : AllocatedFlatValue (hs.heap.set! root (ys ++ [w])) (.ref root) (.list t) :=
          .list root _ t lookupNew shapedZ
        have rootApart : ∀ z ∈ ys ++ [w], ¬ Reaches (hs.heap.set! root (ys ++ [w])) z (.ref root) := by
          intro z member reach
          rcases List.mem_append.mp member with old | new
          · exact no_element_reaches_root lookup old _ _ (Nat.le_refl _) _ _ represented0
              (reaches_of_agree_rev (agreeOld z old) reach)
          · rw [List.mem_singleton.mp new] at reach
            exact itemApartRoot (reaches_of_agree_rev agreeItem reach)
        have elementsDescribed' : ∀ z ∈ ys ++ [w],
            Describes gamma (hs.heap.set! root (ys ++ [w])) (element.join aN) z := by
          intro z member
          rcases List.mem_append.mp member with old | new
          · exact describes_join (allocated_of_agree (elemsShaped z old) (agreeOld z old)) elemShape shapeN
              (Or.inl (describes_of_agree (agreeOld z old) (elemsDescribed z old)))
          · rw [List.mem_singleton.mp new]
            exact describes_join (allocated_of_agree allocatedN agreeItem) elemShape shapeN
              (Or.inr (describes_of_agree agreeItem describedN))
        have lookup' : hs.heap[root]? = some (ys ++ [] ++ []) := by simpa using lookup
        have agreeOld' : ∀ y ∈ ys ++ [] ++ [], ∀ c, Reaches hs.heap y (.ref c) →
            (hs.heap.set! root (ys ++ [w]))[c]? = hs.heap[c]? :=
          fun y member => agreeOld y (by simpa using member)
        have oldCert := described.1.2 [] roots element certificate (.ref root) rfl (.here _)
        have describedNew : Describes gamma (hs.heap.set! root (ys ++ [w])) result (.ref root) := by
          rw [resultEq]
          refine list_described_of_elements receiverNamed noUnk lookupNew shapedNew elementsDescribed' ?_ ?_
          · intro d
            obtain ⟨oldDeep, exclusive⟩ := Bool.and_eq_true_iff.mp d
            obtain ⟨deepI, sepI, overlapI⟩ := storeExclusive_facts exclusive
            exact inserted_footprint_nodup (mid := []) lookup' lookupNew represented0 agreeOld' agreeItem rootApart
              (fun n o' fp rep => (oldCert n o' fp rep).1 oldDeep)
              (nodup_of_deepExclusive allocatedN shapeN describedN deepI
                (pathsApart_of_separated inv.separating sepI))
              (fun y member c reachI reachY => reach_apart_of_covers inv.separating shapeN elemShape
                describedN.1.1 (elemsDescribed y (by simpa using member)).1.1
                (cellOverlap_union_right_false overlapI).2 c reachI reachY)
          · intro sp
            have h := Bool.and_eq_true_iff.mp sp
            obtain ⟨oldSpine, spines⟩ := Bool.and_eq_true_iff.mp h.1
            have containersOk := h.2
            exact inserted_footprint_once (mid := []) lookup' lookupNew represented0 agreeOld' agreeItem rootApart
              (fun n o' fp rep => (oldCert n o' fp rep).2 oldSpine)
              (once_of_storeSpines inv.separating shapeN allocatedN describedN.1.1 spines)
              (fun p c container located reachI => by
                cases located with
                | element lookup'' yMember inner =>
                  rw [lookup] at lookup''
                  cases lookup''
                  obtain ⟨o', m', a'⟩ := (elemsDescribed _ yMember).1.1 p c inner
                  obtain ⟨cs, entry, inCs⟩ :=
                    mem_namesAt_of_arrayAt elemShape (elemsShaped _ yMember) p c o' inner m'
                  exact cell_apart_of_covers inv.separating shapeN describedN.1.1 ⟨o', inCs, a'⟩
                    (containers_all_facts containersOk (p, cs) (List.mem_filter.mpr ⟨entry, container⟩)) reachI)
              (fun p c container located y yMember reachY => by
                obtain ⟨o', m', a'⟩ := describedN.1.1 p c located
                obtain ⟨cs, entry, inCs⟩ := mem_namesAt_of_arrayAt shapeN allocatedN p c o' located m'
                have disjoint :=
                  ((storeSpines_facts spines).2 (p, cs) (List.mem_filter.mpr ⟨entry, container⟩)).1
                exact cell_apart_of_covers inv.separating elemShape
                  (elemsDescribed y (by simpa using yMember)).1.1 ⟨o', inCs, a'⟩
                  (cellOverlap_union_right_false disjoint).2 reachY)
        refine ⟨.ref root, heapObserved (heapPushedValues hs root ys w) vs.kept.toList, gamma, heapRun, ?_,
          Nat.le_of_eq (by rw [heapEq, sizeEq]), ?_, ?_, ?_, ?_, ?_,
          by rw [resultEq]; exact .list _ _ _ _ _, .list _ _ _⟩
        · rw [escapesEq]
          refine flatInvariant_heap_frame inv (hole := root) (footprint := footprint) afterSub
            (by rw [heapEq, sizeEq]; exact Nat.le_refl _) ⟨ys ++ [w], by rw [heapEq]; exact lookupNew, ?_⟩
            (by rw [heapObserved_links]; exact inv.links) ?_ apart represented rootOutside
            (by rw [heapObserved_kept]; rfl) (by rw [valueObserved_kept]; rfl) (fun _ _ _ => Iff.rfl)
            (by rw [heapEq, sizeEq]; exact inv.namingBound) inv.separating
            (by rw [valueObserved_reads, heapObserved_reads]; exact inv.reads)
            (observed_external (valueTicked vs) (heapPushedValues hs root ys w) inv.keptSize inv.external)
            (by rw [valueObserved_fuel, heapObserved_fuel]; simp [valueTicked, heapPushedValues, inv.fuel])
            (fun _ escaped => escaped)
          · intro z member d reach
            rw [heapEq] at reach ⊢
            exact allocated_reach_bound (shapedZ z member) reach
          · intro c different
            rw [heapEq]
            exact lookup_set_other hs.heap root _ different
        · rw [heapEq]
          exact corresponds_list_of_elements lookupNew (by simp [lenO])
            (pointwise_snoc lenO (fun i o' y os_i ys_i =>
              corresponds_of_agree (agreeOld y (List.mem_of_getElem? ys_i)) (pointwise i o' y os_i ys_i))
              (corresponds_of_agree agreeItem pairedN))
        · rw [heapEq]; exact describedNew
        · exact obsTyped_list_of_elements (fun o' member => by
            rcases List.mem_append.mp member with old | new
            · exact elemsTyped o' old
            · rw [List.mem_singleton.mp new]; exact observedN)
        · rw [heapEq]; exact valueTyped_of_allocated shapedNew
        · rw [heapEq]; exact shapedNew
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
        AllocatedFlatValue hs'.heap actual type ∧
        ResultTags type result actual ∧ ChainTags type result value) ∧
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
          Nat.le_of_eq (congrArg Array.size heapSame.symm), ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
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
        · rw [heapSame]
          refine .record ws types lenW ?_
          intro i w t ws_i types_i
          obtain ⟨o, os_i⟩ := index_of_same_length lenO.symm types_i
          obtain ⟨a, as_i⟩ := index_of_same_length lenA.symm types_i
          exact (fields i o w a t os_i ws_i as_i types_i).2.2.2.2.2.2.1
        · rw [resultEq]
          refine .record types as ws lenA.symm ?_
          intro i t a w types_i as_i ws_i
          obtain ⟨o, os_i⟩ := index_of_same_length lenO.symm types_i
          exact (fields i o w a t os_i ws_i as_i types_i).2.2.2.2.2.2.2.1
        · rw [resultEq]
          refine .record types as os lenA.symm ?_
          intro i t a o types_i as_i os_i
          obtain ⟨w, ws_i⟩ := index_of_same_length lenW.symm types_i
          exact (fields i o w a t os_i ws_i as_i types_i).2.2.2.2.2.2.2.2
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
    (shaped : AllocatedFlatValue hs.heap actual type)
    (tags : ResultTags type result actual) (chains : ChainTags type result value) :
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
        AllocatedFlatValue hs'.heap actual' type ∧
        ResultTags type result actual' ∧ ChainTags type result value') ∧
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
          Nat.le_of_eq (congrArg Array.size heapSame.symm), ?_, ?_, observed, ?_, ?_, tags, chains⟩
        · rw [heapSame]; exact paired
        · rw [heapSame]; exact described
        · rw [heapSame]; exact valueTyped
        · rw [heapSame]; exact shaped
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
        AllocatedFlatValue hs'.heap actual type ∧
        ResultTags type result actual ∧ ChainTags type result value) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim (.ok error) [x])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim (.ok error) [x])).run hs = .error actualMessage) := by
  obtain ⟨t, atomTyped, rfl⟩ := exprType_ok_success typed
  obtain ⟨o, w, a, valueAtom, heapAtom, abstractValue, paired, described, observed, valueTyped,
    flatT, shape, allocated, tags, chains⟩ := flat_atom_values inv atomTyped covered
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
      (valueTyped_of_allocated (.ok error t w allocated)) (.ok error t w allocated)
      (.ok error t _ _ _ w (resultTags_ne_bottom tags) tags) (.ok error t _ _ _ o chains)
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
        AllocatedFlatValue hs'.heap actual type ∧
        ResultTags type result actual ∧ ChainTags type result value) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim (.err success) [x])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim (.err success) [x])).run hs = .error actualMessage) := by
  obtain ⟨t, atomTyped, rfl⟩ := exprType_err_success typed
  obtain ⟨o, w, a, valueAtom, heapAtom, abstractValue, paired, described, observed, valueTyped,
    flatT, shape, allocated, tags, chains⟩ := flat_atom_values inv atomTyped covered
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
      (valueTyped_of_allocated (.err t success w allocated)) (.err t success w allocated)
      (.err t success _ _ _ w (resultTags_ne_bottom tags) tags) (.err t success _ _ _ o chains)
    simpa [obsTyped] using observed

end Ownership.FlatFragment.Result

/-! the chain constructors under the generic flat relation.
`endChain` allocates an empty array; `link` reads a live chain and allocates
a copy with the head in front. Both are allocations at the real address,
like a literal, and the checker names the result by a fresh site root; the
link's element is the scalar. -/

namespace Ownership.FlatFragment.Chain

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.StateFrame
open Ownership.FlatFragment.Observe Ownership.FlatFragment.Runtime Ownership.FlatFragment.HeapPreservation Ownership.FlatFragment.Description
open Ownership.FlatFragment.Atoms Ownership.FlatFragment.HeapFrame Ownership.FlatFragment.PrimitiveInference Ownership.FlatFragment.PrimitiveRuntime
open Ownership.FlatFragment.Naming Ownership.FlatFragment.Support Ownership.FlatFragment.IntegerCorrespondence Ownership.FlatFragment.Fields
open Ownership.FlatFragment.CheckerExtraction Ownership.FlatFragment.Literal Ownership.FlatFragment.Length

/-! ### The checker's steps -/

theorem primitive_endChain_run (ctx : Context) (site : List Nat) (later : List Origin) (before : St) :
    (primitive ctx site (.endChain .int) [] later).run before =
      .ok (.list [.site site 0] .bottom true, before) := by
  unfold primitive
  rfl

theorem primitive_link_run (ctx : Context) (defaultConfig : ctx.config = {}) (site : List Nat)
    (a : Abstract) (roots : List Origin) (element : Abstract) (certificate : Certificate)
    (later : List Origin) (before : St) :
    (primitive ctx site .link [a, .list roots element certificate] later).run before =
      .ok (.list [.site site 0] (a.join element)
        ⟨certificate.deep && storeExclusive ctx [a] later element.cells,
         certificate.spine && storeSpines ctx [a] later element.cells⟩, before) := by
  unfold primitive
  simp only [defaultConfig, default_has, Bool.false_eq_true, if_false]
  rfl

theorem infer_endChain_success {aenv : Env Abstract} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract}
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim (.endChain .int) []) after site).run before =
      .ok (result, next)) :
    next = before ∧ result = .list [.site site 0] .bottom true := by
  obtain ⟨childFuel, _, _, run⟩ :=
    infer_primitive_success defaultConfig (args := []) (abstracts := []) rfl accepted
  rw [primitive_endChain_run] at run
  have equal := Except.ok.inj run
  exact ⟨(congrArg Prod.snd equal).symm, (congrArg Prod.fst equal).symm⟩

theorem infer_link_success {aenv : Env Abstract} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {head tail : Atom} {roots : List Origin} {element : Abstract} {certificate : Certificate}
    (defaultConfig : ctx.config = {})
    (abstractAtoms : [head, tail].mapM (m := Except String) (abstractAtom aenv) =
      .ok [.scalar, .list roots element certificate])
    (elementFlat : element = .bottom ∨ element = .scalar)
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim .link [head, tail]) after site).run before =
      .ok (result, next)) :
    next = before ∧ ∃ certificate', result = .list [.site site 0] .scalar certificate' := by
  obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  rw [primitive_link_run _ (show ({ctx with escaped := union ctx.escaped before.facts.escapes} :
    Context).config = {} from defaultConfig)] at run
  have equal := Except.ok.inj run
  have joined : Abstract.scalar.join element = .scalar := by
    rcases elementFlat with rfl | rfl <;> simp [Abstract.join]
  have first := congrArg Prod.fst equal
  rw [joined] at first
  exact ⟨(congrArg Prod.snd equal).symm, _, first.symm⟩

/-! ### The runtime steps -/

theorem value_endChain_run (s : ValueSemantics.State) :
    (ValueSemantics.prim (.endChain .int) []).run s = .ok (.list (valueInts []), s) := rfl

theorem heap_endChain_prim_run (hs : State) :
    (prim (.endChain .int) []).run (heapTicked hs) = .ok (.ref hs.heap.size, heapAllocated hs []) := rfl

theorem value_link_run (s : ValueSemantics.State) (n : Int) (integers : List Int) :
    (ValueSemantics.prim .link [.int n, .list (valueInts integers)]).run s =
      .ok (.list (valueInts (n :: integers)), s) := rfl

theorem heap_link_prim_run (hs : State) (n : Int) (integers : List Int)
    (lookup : hs.heap[root]? = some (heapInts integers)) :
    (prim .link [.int n, .ref root]).run (heapTicked hs) =
      .ok (.ref hs.heap.size, heapAllocated hs (n :: integers)) := by
  simp [prim, array, alloc, lookup, heapTicked, heapAllocated, heapInts, Option.toExcept, StateT.run,
    StateT.bind, StateT.map, StateT.get, StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure,
    bind, pure, get, getThe, set, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift]

theorem endChain_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {escapes : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim (.endChain .int) [])).run vs =
      .ok (.list (valueInts []), valueObserved (valueTicked vs)) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim (.endChain .int) [])).run hs =
      .ok (.ref hs.heap.size, heapObserved (heapAllocated hs []) vs.kept.toList) := by
  obtain ⟨footprint, represented⟩ := inv.observers
  have valueObservedRun := value_observeKept_run (valueTicked vs) represented
  have heapObservedRun := heap_observeKept_run (heapAllocated hs [])
    (representsMany_after_alloc (xs := heapInts []) represented)
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) (args := []) rfl]
    simp [hasDepth, hasFuel, value_endChain_run, valueObservedRun, Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) (args := []) rfl]
    simp [hasDepth, heapFuel, heap_endChain_prim_run, heapObservedRun, Except.bind, Except.pure, bind, pure]

theorem link_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {escapes : List Origin} {head tail : Atom} {n : Int} {integers : List Int} {root : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueHead : ValueSemantics.atom (valueEnv env) head = .ok (.int n))
    (heapHead : InPlaceSemantics.atom (heapEnv env) head = .ok (.int n))
    (valueTail : ValueSemantics.atom (valueEnv env) tail = .ok (.list (valueInts integers)))
    (heapTail : InPlaceSemantics.atom (heapEnv env) tail = .ok (.ref root))
    (lookup : hs.heap[root]? = some (heapInts integers))
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim .link [head, tail])).run vs =
      .ok (.list (valueInts (n :: integers)), valueObserved (valueTicked vs)) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim .link [head, tail])).run hs =
      .ok (.ref hs.heap.size, heapObserved (heapAllocated hs (n :: integers)) vs.kept.toList) := by
  obtain ⟨footprint, represented⟩ := inv.observers
  have valueObservedRun := value_observeKept_run (valueTicked vs) represented
  have heapObservedRun := heap_observeKept_run (heapAllocated hs (n :: integers))
    (representsMany_after_alloc (xs := heapInts (n :: integers)) represented)
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have valueAtoms : [head, tail].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.int n, .list (valueInts integers)] := except_mapM_cons valueHead (except_mapM_cons valueTail rfl)
  have heapAtoms : [head, tail].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.int n, .ref root] := except_mapM_cons heapHead (except_mapM_cons heapTail rfl)
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, value_link_run, valueObservedRun, Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, heap_link_prim_run hs n integers lookup, heapObservedRun,
      Except.bind, Except.pure, bind, pure]

/-! ### The expression cases -/

theorem endChain_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {self : Decl} {type : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.prim (.endChain .int) []) = .ok type)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim (.endChain .int) []) after site).run before =
      .ok (result, next)) :
    type = .chain .int ∧ next.facts.escapes = before.facts.escapes ∧ FlatAbstract type result ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim (.endChain .int) [])).run vs = .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim (.endChain .int) [])).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv next.facts.escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧ Describes gamma' hs'.heap result actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        AllocatedFlatValue hs'.heap actual type ∧
        ResultTags type result actual ∧ ChainTags type result value) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim (.endChain .int) [])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim (.endChain .int) [])).run hs = .error actualMessage) := by
  have chainType := exprType_endChain_success typed
  subst chainType
  obtain ⟨checkerState, resultShape⟩ := infer_endChain_success defaultConfig accepted
  subst checkerState
  subst resultShape
  refine ⟨rfl, rfl, .chainBottom _ _, ?_, ?_⟩
  · intro value vs' run
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) (args := []) rfl] at run
      simp [noDepth] at run
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) (args := []) rfl] at run
        simp [noDepth, noFuel] at run
      · obtain ⟨valueRun, heapRun⟩ := endChain_runtime_success inv noDepth noFuel
        rw [valueRun] at run
        cases run
        obtain ⟨gamma', postInvariant, fresh, _⟩ := literal_post_invariant inv [] site
        have heapEq : (heapObserved (heapAllocated hs []) vs.kept.toList).heap =
            hs.heap.push (heapInts []) := by
          rw [heapObserved_heap]; rfl
        have lookupNew : (heapObserved (heapAllocated hs []) vs.kept.toList).heap[hs.heap.size]? =
            some (heapInts []) := by
          rw [heapEq]; simp
        refine ⟨.ref hs.heap.size, heapObserved (heapAllocated hs []) vs.kept.toList, gamma',
          heapRun, postInvariant, ?_, ?_, ?_, ?_, ?_, .chain _ [] lookupNew, .chainInt _ _ _ _, .chainBottom _ _⟩
        · rw [heapEq]; simp
        · exact corresponds_integer_ref lookupNew
        · exact allocated_list_described lookupNew ⟨.site site 0, by simp, fresh⟩
        · exact integer_chain_observation_typed declarations []
        · exact allocated_integer_chain_typed declarations lookupNew
  · intro message failed
    by_cases noDepth : depth = 0
    · exact ⟨"in-place execution exhausted depth", by
        rw [heap_primitive_eval_equation hs (heapEnv env) (args := []) rfl]
        simp [noDepth]⟩
    · by_cases noFuel : vs.fuel = 0
      · have heapFuel : hs.fuel = 0 := inv.fuel.symm.trans noFuel
        exact ⟨"in-place execution exhausted fuel", by
          rw [heap_primitive_eval_equation hs (heapEnv env) (args := []) rfl]
          simp [noDepth, heapFuel]⟩
      · have success := (endChain_runtime_success inv noDepth noFuel).1
        rw [success] at failed
        contradiction

theorem link_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {head tail : Atom} {self : Decl} {type : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.prim .link [head, tail]) = .ok type)
    (coveredH : ∀ use ∈ atomUses head, use ∈ live)
    (coveredT : ∀ use ∈ atomUses tail, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim .link [head, tail]) after site).run before =
      .ok (result, next)) :
    type = .chain .int ∧ next.facts.escapes = before.facts.escapes ∧ FlatAbstract type result ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .link [head, tail])).run vs = .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .link [head, tail])).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv next.facts.escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧ Describes gamma' hs'.heap result actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        AllocatedFlatValue hs'.heap actual type ∧
        ResultTags type result actual ∧ ChainTags type result value) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .link [head, tail])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .link [head, tail])).run hs = .error actualMessage) := by
  obtain ⟨headTyped, tailTyped, chainType⟩ :=
    exprType_link_success (fun _ h => flat_atom_type inv h) typed
  subst chainType
  obtain ⟨n, valueHead, heapHead, abstractHead⟩ := flat_atom_integer inv headTyped coveredH
  obtain ⟨root, integers, roots, element, certificate, lookup, _, elementFlat, _, valueTail, heapTail,
    abstractTail⟩ := flat_atom_chain_path inv tailTyped coveredT
  have abstractAtoms : [head, tail].mapM (m := Except String) (abstractAtom aenv) =
      .ok [.scalar, .list roots element certificate] :=
    except_mapM_cons abstractHead (except_mapM_cons abstractTail rfl)
  obtain ⟨checkerState, certificate', resultShape⟩ :=
    infer_link_success defaultConfig abstractAtoms elementFlat accepted
  subst checkerState
  subst resultShape
  have valueAtoms : [head, tail].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.int n, .list (valueInts integers)] := except_mapM_cons valueHead (except_mapM_cons valueTail rfl)
  have heapAtoms : [head, tail].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.int n, .ref root] := except_mapM_cons heapHead (except_mapM_cons heapTail rfl)
  refine ⟨rfl, rfl, .chainScalar _ _, ?_, ?_⟩
  · intro value vs' run
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
      simp [noDepth] at run
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
        simp [noDepth, noFuel] at run
      · obtain ⟨valueRun, heapRun⟩ :=
          link_runtime_success inv valueHead heapHead valueTail heapTail lookup noDepth noFuel
        rw [valueRun] at run
        cases run
        obtain ⟨gamma', postInvariant, fresh, _⟩ := literal_post_invariant inv (n :: integers) site
        have heapEq : (heapObserved (heapAllocated hs (n :: integers)) vs.kept.toList).heap =
            hs.heap.push (heapInts (n :: integers)) := by
          rw [heapObserved_heap]; rfl
        have lookupNew : (heapObserved (heapAllocated hs (n :: integers)) vs.kept.toList).heap[hs.heap.size]? =
            some (heapInts (n :: integers)) := by
          rw [heapEq]; simp
        refine ⟨.ref hs.heap.size, heapObserved (heapAllocated hs (n :: integers)) vs.kept.toList, gamma',
          heapRun, postInvariant, ?_, ?_, ?_, ?_, ?_, .chain _ (n :: integers) lookupNew, .chainInt _ _ _ _,
          .chainScalar _ _ _⟩
        · rw [heapEq]; simp
        · exact corresponds_integer_ref lookupNew
        · exact allocated_list_described lookupNew ⟨.site site 0, by simp, fresh⟩
        · exact integer_chain_observation_typed declarations (n :: integers)
        · exact allocated_integer_chain_typed declarations lookupNew
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
          (link_runtime_success inv valueHead heapHead valueTail heapTail lookup noDepth noFuel).1
        rw [success] at failed
        contradiction

end Ownership.FlatFragment.Chain

/-! four more primitives on flat integer lists under the generic flat
relation. `at` reads an element, or the fallback, and both runtimes record
the read; `set` is a counted write like a push, unchanged for a negative or
out-of-range index; `copy` allocates a copy at the real address, like a
literal; `prepend` records a read of the base on both sides and allocates
a copy with the item in front, which the checker names by a fresh site root
and the base's origins. -/

namespace Ownership.FlatFragment.ListPrimitives

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.StateFrame
open Ownership.FlatFragment.Observe Ownership.FlatFragment.Runtime Ownership.FlatFragment.HeapPreservation Ownership.FlatFragment.Description
open Ownership.FlatFragment.Atoms Ownership.FlatFragment.HeapFrame Ownership.FlatFragment.PrimitiveInference Ownership.FlatFragment.PrimitiveRuntime
open Ownership.FlatFragment.Naming Ownership.FlatFragment.Support Ownership.FlatFragment.IntegerCorrespondence Ownership.FlatFragment.Fields
open Ownership.FlatFragment.CheckerExtraction Ownership.FlatFragment.Literal Ownership.FlatFragment.Length Ownership.FlatFragment.Push
open Ownership.FlatFragment.LiveCells Ownership.FlatFragment.Scope Ownership.FlatFragment.NamingFacts

local instance stepReflBEq : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance stepLawfulBEq : LawfulBEq Step := LawfulBEq.mk (by deriving_LawfulEq_tactic)
local instance originReflBEq : ReflBEq Origin := ⟨by deriving_ReflEq_tactic⟩
local instance originLawfulBEq : LawfulBEq Origin := LawfulBEq.mk (by deriving_LawfulEq_tactic)

/-! ### The checker's steps -/

theorem primitive_at_run (ctx : Context) (site : List Nat) (roots : List Origin) (element : Abstract)
    (certificate : Certificate) (index fallback : Abstract) (later : List Origin) (before : St) :
    (primitive ctx site .at [.list roots element certificate, index, fallback] later).run before =
      .ok (element.join fallback, {before with facts := {before.facts with
        reads := union before.facts.reads ((union roots element.cells).filter external)}}) := by
  unfold primitive
  rfl

theorem primitive_at_bottom_run (ctx : Context) (site : List Nat) (index fallback : Abstract)
    (later : List Origin) (before : St) :
    (primitive ctx site .at [.bottom, index, fallback] later).run before = .ok (.bottom, before) := by
  unfold primitive
  simp [BEq.beq, Abstract.equal]
  rfl

theorem primitive_set_bottom_run (ctx : Context) (site : List Nat) (index item : Abstract)
    (later : List Origin) (before : St) :
    (primitive ctx site .set [.bottom, index, item] later).run before = .ok (.bottom, before) := by
  unfold primitive
  simp [BEq.beq, Abstract.equal]
  rfl

theorem primitive_set_result {ctx : Context} {site : List Nat} {before : St} {next : St} {result : Abstract} {roots : List Origin} {later : List Origin} {element index item : Abstract} {certificate : Certificate}
    (flatI : item = .bottom ∨ item = .scalar)
    (run : (primitive ctx site .set [.list roots element certificate, index, item] later).run before =
      .ok (result, next)) :
    ∃ certificate', result = .list roots (element.join item) certificate' := by
  rcases flatI with rfl | rfl <;>
  · unfold primitive at run
    obtain ⟨finished, middle, _, returned⟩ := checkM_bind_success run
    cases finished
    have equal := Except.ok.inj returned
    have first : _ = result := congrArg Prod.fst equal
    rw [← first]
    exact ⟨_, by simp [Abstract.grantExclusive] <;> rfl⟩

theorem primitive_copy_run (ctx : Context) (site : List Nat) (roots : List Origin) (element : Abstract)
    (certificate : Certificate) (later : List Origin) (before : St) :
    (primitive ctx site .copy [.list roots element certificate] later).run before =
      .ok (.list [.site site 0] element ((ctx.config.has .copyExclusive : Bool) : Certificate),
        {before with facts := {before.facts with
          reads := union before.facts.reads (roots.filter external)}}) := by
  unfold primitive
  rfl

theorem primitive_copy_bottom_run (ctx : Context) (site : List Nat) (later : List Origin) (before : St) :
    (primitive ctx site .copy [.bottom] later).run before = .ok (.bottom, before) := by
  unfold primitive
  simp [BEq.beq, Abstract.equal]
  rfl

theorem primitive_prepend_run (ctx : Context) (site : List Nat) (item : Abstract) (roots : List Origin)
    (element : Abstract) (certificate : Certificate) (later : List Origin) (before : St) :
    ∃ certificate', (primitive ctx site .prepend [item, .list roots element certificate] later).run before =
      .ok (.list (union [.site site 0] roots) (item.join element) certificate', {before with facts :=
        {before.facts with reads := union before.facts.reads (roots.filter external)}}) :=
  ⟨_, by unfold primitive; rfl⟩

theorem primitive_prepend_bottom_run (ctx : Context) (site : List Nat) (item : Abstract)
    (later : List Origin) (before : St) :
    (primitive ctx site .prepend [item, .bottom] later).run before = .ok (.bottom, before) := by
  unfold primitive
  simp [BEq.beq, Abstract.equal]
  rfl

/-! ### The element read -/

/-- The element both runtimes read: the fallback for a negative or out-of-range index. -/
def atObs (os : List Observation) (index : Int) (fallback : Observation) : Observation :=
  if index < 0 then fallback else os[index.toNat]?.getD fallback

def atVal (ys : List Value) (index : Int) (fallback : Value) : Value :=
  if index < 0 then fallback else ys[index.toNat]?.getD fallback

theorem atVal_cases (ys : List Value) (index : Int) (fallback : Value) :
    atVal ys index fallback = fallback ∨ ∃ y ∈ ys, atVal ys index fallback = y := by
  unfold atVal
  split
  · exact Or.inl rfl
  · cases h : ys[index.toNat]? with
    | none => exact Or.inl rfl
    | some y => exact Or.inr ⟨y, List.mem_of_getElem? h, rfl⟩

theorem atObs_cases (os : List Observation) (index : Int) (fallback : Observation) :
    atObs os index fallback = fallback ∨ ∃ o ∈ os, atObs os index fallback = o := by
  unfold atObs
  split
  · exact Or.inl rfl
  · cases h : os[index.toNat]? with
    | none => exact Or.inl rfl
    | some o => exact Or.inr ⟨o, List.mem_of_getElem? h, rfl⟩

/-- The read elements correspond when the lists do, element by element. -/
theorem corresponds_atVal {heap : Heap} {os : List Observation} {ys : List Value} {d : Observation} {w : Value}
    (lenO : os.length = ys.length)
    (pointwise : ∀ (i : Nat) (o : Observation) (y : Value), os[i]? = some o → ys[i]? = some y → Corresponds heap o y)
    (pairedD : Corresponds heap d w) (index : Int) :
    Corresponds heap (atObs os index d) (atVal ys index w) := by
  unfold atObs atVal
  split
  · exact pairedD
  · cases h : os[index.toNat]? with
    | none =>
      have h' : ys[index.toNat]? = none := by
        rw [List.getElem?_eq_none_iff] at h ⊢
        omega
      rw [h']
      exact pairedD
    | some o =>
      obtain ⟨y, h'⟩ := index_of_same_length lenO h
      rw [h']
      exact pointwise _ _ _ h h'

theorem value_at_run (s : ValueSemantics.State) (os : List Observation) (index : Int) (d : Observation)
    (shallow : ¬ (atObs os index d).depth > observationDepth) :
    (ValueSemantics.prim .at [.list os, .int index, d]).run s =
      .ok (atObs os index d, {s with reads := s.reads.push (atObs os index d)}) := by
  by_cases neg : index < 0 <;>
    simp only [atObs, neg, ite_true, ite_false] at shallow ⊢ <;>
    simp [ValueSemantics.prim, ValueSemantics.read, ValueSemantics.observable, neg, shallow, StateT.run,
      StateT.bind, StateT.map, StateT.get, StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind,
      pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, modify,
      modifyGet, MonadStateOf.modifyGet, StateT.modifyGet]

theorem value_at_run_deep (s : ValueSemantics.State) (os : List Observation) (index : Int) (d : Observation)
    (deep : (atObs os index d).depth > observationDepth) :
    (ValueSemantics.prim .at [.list os, .int index, d]).run s = .error "snapshot exhausted depth" := by
  by_cases neg : index < 0 <;>
    simp only [atObs, neg, ite_true, ite_false] at deep ⊢ <;>
    simp [ValueSemantics.prim, ValueSemantics.read, ValueSemantics.observable, neg, deep, StateT.run,
      StateT.bind, StateT.map, StateT.get, StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind,
      pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, modify,
      modifyGet, MonadStateOf.modifyGet, StateT.modifyGet, throw, throwThe, MonadExceptOf.throw, Except.error]

theorem heap_at_run (s : State) (ys : List Value) (index : Int) (w : Value) {o : Observation}
    (lookup : s.heap[root]? = some ys)
    (snap : snapshot s.heap observationDepth (atVal ys index w) = .ok o) :
    (prim .at [.ref root, .int index, w]).run s = .ok (atVal ys index w, {s with reads := s.reads.push o}) := by
  by_cases neg : index < 0 <;>
    simp only [atVal, neg, ite_true, ite_false] at snap ⊢ <;>
    simp [prim, array, lookup, InPlaceSemantics.read, snap, neg, Option.toExcept, StateT.run, StateT.bind,
      StateT.map, StateT.get, StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get,
      getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, modify, modifyGet,
      MonadStateOf.modifyGet, StateT.modifyGet]

theorem heap_at_run_deep (s : State) (ys : List Value) (index : Int) (w : Value) {e : String}
    (lookup : s.heap[root]? = some ys)
    (snap : snapshot s.heap observationDepth (atVal ys index w) = .error e) :
    (prim .at [.ref root, .int index, w]).run s = .error e := by
  by_cases neg : index < 0 <;>
    simp only [atVal, neg, ite_true, ite_false] at snap ⊢ <;>
    simp [prim, array, lookup, InPlaceSemantics.read, snap, neg, Option.toExcept, StateT.run, StateT.bind,
      StateT.map, StateT.get, StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get,
      getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, modify, modifyGet,
      MonadStateOf.modifyGet, StateT.modifyGet]

theorem at_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {receiver index fallback : Atom} {os : List Observation} {ys : List Value} {root : Nat} {i : Int} {d : Observation} {w : Value} {depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueReceiver : ValueSemantics.atom (valueEnv env) receiver = .ok (.list os))
    (heapReceiver : InPlaceSemantics.atom (heapEnv env) receiver = .ok (.ref root))
    (valueIndex : ValueSemantics.atom (valueEnv env) index = .ok (.int i))
    (heapIndex : InPlaceSemantics.atom (heapEnv env) index = .ok (.int i))
    (valueFallback : ValueSemantics.atom (valueEnv env) fallback = .ok d)
    (heapFallback : InPlaceSemantics.atom (heapEnv env) fallback = .ok w)
    (lookup : hs.heap[root]? = some ys)
    (snap : snapshot hs.heap observationDepth (atVal ys i w) = .ok (atObs os i d))
    (shallow : ¬ (atObs os i d).depth > observationDepth)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim .at [receiver, index, fallback])).run vs =
      .ok (atObs os i d, valueRead vs (atObs os i d)) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim .at [receiver, index, fallback])).run hs =
      .ok (atVal ys i w, heapRead hs (atObs os i d) vs.kept.toList) := by
  obtain ⟨footprint, represented⟩ := inv.observers
  have valueObservedRun := value_observeKept_run
    ({vs with fuel := vs.fuel - 1, reads := vs.reads.push (atObs os i d)}) represented
  have heapObservedRun := heap_observeKept_run
    ({hs with fuel := hs.fuel - 1, reads := hs.reads.push (atObs os i d)}) represented
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have valueAtoms : [receiver, index, fallback].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.list os, .int i, d] :=
    except_mapM_cons valueReceiver (except_mapM_cons valueIndex (except_mapM_cons valueFallback rfl))
  have heapAtoms : [receiver, index, fallback].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref root, .int i, w] :=
    except_mapM_cons heapReceiver (except_mapM_cons heapIndex (except_mapM_cons heapFallback rfl))
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, valueTicked, value_at_run (valueTicked vs) os i d shallow,
      value_at_run {vs with fuel := vs.fuel - 1} os i d shallow, valueObservedRun, valueRead,
      Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, heapTicked, heap_at_run {hs with fuel := hs.fuel - 1} ys i w lookup snap,
      heapObservedRun, heapRead, Except.bind, Except.pure, bind, pure]

/-- A read too deep to observe fails on both sides. -/
theorem at_runtime_deep {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {receiver index fallback : Atom} {os : List Observation} {ys : List Value} {root : Nat} {i : Int} {d : Observation} {w : Value} {depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (heapReceiver : InPlaceSemantics.atom (heapEnv env) receiver = .ok (.ref root))
    (heapIndex : InPlaceSemantics.atom (heapEnv env) index = .ok (.int i))
    (heapFallback : InPlaceSemantics.atom (heapEnv env) fallback = .ok w)
    (lookup : hs.heap[root]? = some ys)
    (paired : Corresponds hs.heap (atObs os i d) (atVal ys i w))
    (deep : (atObs os i d).depth > observationDepth)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    ∃ e, (InPlaceSemantics.eval depth declarations none (heapEnv env)
      (.prim .at [receiver, index, fallback])).run hs = .error e := by
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have heapAtoms : [receiver, index, fallback].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref root, .int i, w] :=
    except_mapM_cons heapReceiver (except_mapM_cons heapIndex (except_mapM_cons heapFallback rfl))
  obtain ⟨e, snapErr⟩ := Ownership.FlatFragment.Shared.snapshot_deep_error paired deep
  refine ⟨e, ?_⟩
  rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
  simp [hasDepth, heapFuel, heapTicked, heap_at_run_deep {hs with fuel := hs.fuel - 1} ys i w lookup snapErr,
    Except.bind, bind]

theorem at_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {receiver index fallback : Atom} {type : Ty} {self : Decl} {ctx : Context} {after : Live} {site : List Nat} {before next : St} {result : Abstract} {inferenceFuel depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.prim .at [receiver, index, fallback]) = .ok type)
    (coveredR : ∀ use ∈ atomUses receiver, use ∈ live)
    (coveredI : ∀ use ∈ atomUses index, use ∈ live)
    (coveredD : ∀ use ∈ atomUses fallback, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim .at [receiver, index, fallback]) after site).run before =
      .ok (result, next)) :
    FlatType type ∧ next.facts.escapes = before.facts.escapes ∧ FlatAbstract type result ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .at [receiver, index, fallback])).run vs = .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .at [receiver, index, fallback])).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv next.facts.escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧ Describes gamma' hs'.heap result actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        AllocatedFlatValue hs'.heap actual type ∧
        ResultTags type result actual ∧ ChainTags type result value) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .at [receiver, index, fallback])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .at [receiver, index, fallback])).run hs = .error actualMessage) := by
  obtain ⟨t, receiverTyped, indexTyped, fallbackTyped, typeEq⟩ :=
    exprType_at_success (fun _ _ h => flat_atom_type inv h) typed
  subst type
  obtain ⟨root, ys, os, roots, element, certificate, lookup, _, _, flatT, elemT, elemShape, elemsShaped,
    elemsDescribed, lenO, elemsTyped, pointwise, _, _, valueReceiver, heapReceiver, abstractReceiver⟩ :=
    flat_atom_list_path inv receiverTyped coveredR
  obtain ⟨i, valueIndex, heapIndex, abstractIndex⟩ := flat_atom_integer inv indexTyped coveredI
  obtain ⟨d, w, aD, valueFallback, heapFallback, abstractFallback, pairedD, describedD, observedD, _, _,
    shapeD, allocatedD, tagsD, chainsD⟩ := flat_atom_values inv fallbackTyped coveredD
  have abstractAtoms : [receiver, index, fallback].mapM (m := Except String) (abstractAtom aenv) =
      .ok [.list roots element certificate, .scalar, aD] :=
    except_mapM_cons abstractReceiver (except_mapM_cons abstractIndex (except_mapM_cons abstractFallback rfl))
  obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  rw [primitive_at_run] at run
  have equal := Except.ok.inj run
  have resultEq : result = element.join aD := (congrArg Prod.fst equal).symm
  have nextState : next = {before with facts := {before.facts with
      reads := union before.facts.reads ((union roots element.cells).filter external)}} :=
    (congrArg Prod.snd equal).symm
  have nextEscapes : next.facts.escapes = before.facts.escapes := by
    subst nextState; rfl
  have valueAtoms : [receiver, index, fallback].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.list os, .int i, d] :=
    except_mapM_cons valueReceiver (except_mapM_cons valueIndex (except_mapM_cons valueFallback rfl))
  have heapAtoms : [receiver, index, fallback].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref root, .int i, w] :=
    except_mapM_cons heapReceiver (except_mapM_cons heapIndex (except_mapM_cons heapFallback rfl))
  have paired : Corresponds hs.heap (atObs os i d) (atVal ys i w) := corresponds_atVal lenO pointwise pairedD i
  have allocated : AllocatedFlatValue hs.heap (atVal ys i w) t := by
    rcases atVal_cases ys i w with h | ⟨y, member, h⟩
    · rw [h]; exact allocatedD
    · rw [h]; exact elemsShaped y member
  have described : Describes gamma hs.heap (element.join aD) (atVal ys i w) := by
    rcases atVal_cases ys i w with h | ⟨y, member, h⟩
    · rw [h]; exact describes_join allocatedD elemShape shapeD (Or.inr describedD)
    · rw [h]; exact describes_join (elemsShaped y member) elemShape shapeD (Or.inl (elemsDescribed y member))
  have observed : obsTyped declarations (atObs os i d) t = true := by
    rcases atObs_cases os i d with h | ⟨o, member, h⟩
    · rw [h]; exact observedD
    · rw [h]; exact elemsTyped o member
  refine ⟨flatT, nextEscapes, by rw [resultEq]; exact flatAbstract_join elemShape shapeD, ?_, ?_⟩
  · intro value vs' run
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
      simp [noDepth] at run
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
        simp [noDepth, noFuel] at run
      · by_cases deep : (atObs os i d).depth > observationDepth
        · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
          simp [noDepth, noFuel, valueTicked, value_at_run_deep (valueTicked vs) os i d deep,
            value_at_run_deep {vs with fuel := vs.fuel - 1} os i d deep, Except.bind, bind] at run
        · have snap : snapshot hs.heap observationDepth (atVal ys i w) = .ok (atObs os i d) :=
            paired observationDepth (by omega)
          obtain ⟨valueRun, heapRun⟩ := at_runtime_success inv valueReceiver heapReceiver valueIndex heapIndex
            valueFallback heapFallback lookup snap deep noDepth noFuel
          rw [valueRun] at run
          cases run
          have heapSame : (heapRead hs (atObs os i d) vs.kept.toList).heap = hs.heap := by
            unfold heapRead; rw [heapObserved_heap]
          refine ⟨atVal ys i w, heapRead hs (atObs os i d) vs.kept.toList, gamma, heapRun, ?_,
            Nat.le_of_eq (congrArg Array.size heapSame.symm), by rw [heapSame]; exact paired, by rw [heapSame, resultEq]; exact described,
            observed, by rw [heapSame]; exact valueTyped_of_allocated allocated, by rw [heapSame]; exact allocated,
            ?_, ?_⟩
          · rw [nextEscapes]; exact read_post_invariant inv _
          · rw [resultEq]
            exact resultTags_element elemT element aD (atVal ys i w) w tagsD elemShape allocated allocatedD
          · rw [resultEq]
            exact chainTags_element elemT element aD (atObs os i d) d (atVal ys i w) w chainsD elemShape paired
              allocated pairedD allocatedD
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
      · by_cases deep : (atObs os i d).depth > observationDepth
        · exact at_runtime_deep inv heapReceiver heapIndex heapFallback lookup paired deep noDepth noFuel
        · have snap : snapshot hs.heap observationDepth (atVal ys i w) = .ok (atObs os i d) :=
            paired observationDepth (by omega)
          have success := (at_runtime_success inv valueReceiver heapReceiver valueIndex heapIndex
            valueFallback heapFallback lookup snap deep noDepth noFuel).1
          rw [success] at failed
          contradiction

/-! ### The element write -/

/-- The checker's set result under the default configuration: as a push's. -/
theorem primitive_set_result_values {ctx : Context} {site : List Nat} {before next : St} {result : Abstract}
    {roots later : List Origin} {element index item : Abstract} {certificate : Certificate}
    (defaultConfig : ctx.config = {})
    (run : (primitive ctx site .set [.list roots element certificate, index, item] later).run before =
      .ok (result, next)) :
    result = .list roots (element.join item)
      ⟨certificate.deep && storeExclusive ctx [item] later element.cells,
       certificate.spine && storeSpines ctx [item] later element.cells &&
         (containers element).all (fun (_, old) => individuallyOwned ctx old && !cellOverlap old item.cells)⟩ := by
  unfold primitive at run
  obtain ⟨finished, middle, _, returned⟩ := checkM_bind_success run
  cases finished
  have equal := Except.ok.inj returned
  have first : _ = result := congrArg Prod.fst equal
  rw [← first]
  simp [defaultConfig, default_has, Abstract.grantExclusive, show (Prim.set == Prim.put) = false from rfl]

/-- The list after a `set`: unchanged for a negative or out-of-range index. -/
def setObs (os : List Observation) (index : Int) (o : Observation) : List Observation :=
  if index < 0 then os else os.set index.toNat o

def setVals (ys : List Value) (index : Int) (w : Value) : List Value :=
  if index < 0 then ys else ys.set index.toNat w

theorem mem_setVals {ys : List Value} {index : Int} {w z : Value} (member : z ∈ setVals ys index w) :
    z ∈ ys ∨ z = w := by
  unfold setVals at member
  split at member
  · exact Or.inl member
  · exact List.mem_or_eq_of_mem_set member

theorem value_set_run_values (s : ValueSemantics.State) (os : List Observation) (index : Int) (o : Observation) :
    (ValueSemantics.prim .set [.list os, .int index, o]).run s = .ok (.list (setObs os index o), s) := rfl

theorem heap_set_run_values (s : State) (ys : List Value) (index : Int) (w : Value)
    (lookup : s.heap[root]? = some ys) (links : s.links = []) :
    (prim .set [.ref root, .int index, w]).run s = .ok (.ref root, {s with heap := s.heap.set! root (setVals ys index w), writes := if ys == setVals ys index w then s.writes else s.writes + 1}) := by
  have written := writeCounted_empty_run (root := root) (stored := setVals ys index w) s lookup links
  simpa [prim, array, lookup, setVals, StateT.run, StateT.bind, StateT.get, Option.toExcept, Except.bind,
    Except.pure, bind, pure, get, getThe, MonadStateOf.get, StateT.pure, StateT.lift, liftM, monadLift,
    MonadLift.monadLift] using written

def heapSetValues (hs : State) (root : Nat) (ys : List Value) (index : Int) (w : Value) : State :=
  { hs with
    fuel := hs.fuel - 1
    heap := hs.heap.set! root (setVals ys index w)
    writes := (if ys == setVals ys index w then hs.writes else hs.writes + 1) }

/-- The correspondence of two lists extends to one element replaced in each. -/
theorem pointwise_set {heap : Heap} {os : List Observation} {ys : List Value} {o : Observation} {w : Value}
    (lenO : os.length = ys.length)
    (pointwise : ∀ (i : Nat) o' y, os[i]? = some o' → ys[i]? = some y → Corresponds heap o' y)
    (paired : Corresponds heap o w) (index : Int) :
    ∀ (i : Nat) o' y, (setObs os index o)[i]? = some o' → (setVals ys index w)[i]? = some y →
      Corresponds heap o' y := by
  intro i o' y os_i ys_i
  unfold setObs at os_i
  unfold setVals at ys_i
  split at os_i <;> split at ys_i <;> try omega
  · exact pointwise i o' y os_i ys_i
  · by_cases same : index.toNat = i
    · subst same
      by_cases lt : index.toNat < os.length
      · rw [List.getElem?_set_self lt] at os_i
        rw [List.getElem?_set_self (by omega)] at ys_i
        cases os_i
        cases ys_i
        exact paired
      · have none : (os.set index.toNat o)[index.toNat]? = none :=
          List.getElem?_eq_none_iff.mpr (by simp [List.length_set]; omega)
        rw [none] at os_i
        cases os_i
    · rw [List.getElem?_set_ne same] at os_i ys_i
      exact pointwise i o' y os_i ys_i

theorem setObs_length {os : List Observation} {ys : List Value} {o : Observation} {w : Value} (index : Int)
    (lenO : os.length = ys.length) : (setObs os index o).length = (setVals ys index w).length := by
  unfold setObs setVals
  split <;> simp [lenO]

theorem set_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {receiver index item : Atom} {os : List Observation} {ys : List Value} {o : Observation} {w : Value} {root : Nat} {i : Int} {footprint : List Nat} {depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueReceiver : ValueSemantics.atom (valueEnv env) receiver = .ok (.list os))
    (heapReceiver : InPlaceSemantics.atom (heapEnv env) receiver = .ok (.ref root))
    (valueIndex : ValueSemantics.atom (valueEnv env) index = .ok (.int i))
    (heapIndex : InPlaceSemantics.atom (heapEnv env) index = .ok (.int i))
    (valueItem : ValueSemantics.atom (valueEnv env) item = .ok o)
    (heapItem : InPlaceSemantics.atom (heapEnv env) item = .ok w)
    (lookup : hs.heap[root]? = some ys)
    (rootOutside : root ∉ footprint)
    (represented : RepresentsMany hs.heap observationDepth hs.kept.toList vs.kept.toList footprint)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim .set [receiver, index, item])).run vs =
      .ok (.list (setObs os i o), valueObserved (valueTicked vs)) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim .set [receiver, index, item])).run hs =
      .ok (.ref root, heapObserved (heapSetValues hs root ys i w) vs.kept.toList) := by
  have valueObservedRun := value_observeKept_run (valueTicked vs) represented
  have framed : RepresentsMany (hs.heap.set! root (setVals ys i w)) observationDepth
      hs.kept.toList vs.kept.toList footprint :=
    representsMany_after_write (xs := setVals ys i w) represented rootOutside
  have heapObservedRun : InPlaceSemantics.observeKept.run (heapSetValues hs root ys i w) =
      .ok ((), heapObserved (heapSetValues hs root ys i w) vs.kept.toList) :=
    heap_observeKept_run (heapSetValues hs root ys i w) framed
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have valueAtoms : [receiver, index, item].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.list os, .int i, o] :=
    except_mapM_cons valueReceiver (except_mapM_cons valueIndex (except_mapM_cons valueItem rfl))
  have heapAtoms : [receiver, index, item].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref root, .int i, w] :=
    except_mapM_cons heapReceiver (except_mapM_cons heapIndex (except_mapM_cons heapItem rfl))
  have setRun : (prim .set [.ref root, .int i, w]).run (heapTicked hs) =
      .ok (.ref root, heapSetValues hs root ys i w) :=
    heap_set_run_values (heapTicked hs) ys i w lookup inv.links
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, value_set_run_values, valueObservedRun, Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, setRun, heapObservedRun, Except.bind, Except.pure, bind, pure]

theorem set_failure {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {receiver index item : Atom} {os : List Observation} {ys : List Value} {o : Observation} {w : Value} {root : Nat} {i : Int} {footprint : List Nat} {depth : Nat} {message : String}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueReceiver : ValueSemantics.atom (valueEnv env) receiver = .ok (.list os))
    (heapReceiver : InPlaceSemantics.atom (heapEnv env) receiver = .ok (.ref root))
    (valueIndex : ValueSemantics.atom (valueEnv env) index = .ok (.int i))
    (heapIndex : InPlaceSemantics.atom (heapEnv env) index = .ok (.int i))
    (valueItem : ValueSemantics.atom (valueEnv env) item = .ok o)
    (heapItem : InPlaceSemantics.atom (heapEnv env) item = .ok w)
    (lookup : hs.heap[root]? = some ys)
    (rootOutside : root ∉ footprint)
    (represented : RepresentsMany hs.heap observationDepth hs.kept.toList vs.kept.toList footprint)
    (failed : (ValueSemantics.eval depth declarations none (valueEnv env)
      (.prim .set [receiver, index, item])).run vs = .error message) :
    ∃ actualMessage,
      (InPlaceSemantics.eval depth declarations none (heapEnv env)
        (.prim .set [receiver, index, item])).run hs = .error actualMessage := by
  have heapAtoms : [receiver, index, item].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref root, .int i, w] :=
    except_mapM_cons heapReceiver (except_mapM_cons heapIndex (except_mapM_cons heapItem rfl))
  by_cases noDepth : depth = 0
  · exact ⟨"in-place execution exhausted depth", by
      rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
      simp [noDepth]⟩
  · by_cases noFuel : vs.fuel = 0
    · have heapFuel : hs.fuel = 0 := inv.fuel.symm.trans noFuel
      exact ⟨"in-place execution exhausted fuel", by
        rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
        simp [noDepth, heapFuel]⟩
    · have success := (set_runtime_success inv valueReceiver heapReceiver valueIndex heapIndex valueItem
        heapItem lookup rootOutside represented noDepth noFuel).1
      rw [success] at failed
      contradiction

theorem set_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {receiver index item : Atom} {type : Ty} {self : Decl} {ctx : Context} {after : Live} {site : List Nat} {before next : St} {result : Abstract} {inferenceFuel depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.prim .set [receiver, index, item]) = .ok type)
    (coveredR : ∀ use ∈ atomUses receiver, use ∈ live)
    (coveredI : ∀ use ∈ atomUses index, use ∈ live)
    (coveredV : ∀ use ∈ atomUses item, use ∈ live)
    (afterSub : ∀ use ∈ after, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim .set [receiver, index, item]) after site).run before =
      .ok (result, next)) :
    FlatType type ∧ next.facts.escapes = before.facts.escapes ∧ FlatAbstract type result ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .set [receiver, index, item])).run vs = .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .set [receiver, index, item])).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env after aenv tenv next.facts.escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧ Describes gamma' hs'.heap result actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        AllocatedFlatValue hs'.heap actual type ∧
        ResultTags type result actual ∧ ChainTags type result value) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .set [receiver, index, item])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .set [receiver, index, item])).run hs = .error actualMessage) := by
  obtain ⟨t, receiverTyped, indexTyped, itemTyped, listType⟩ :=
    exprType_set_success (fun _ _ h => flat_atom_type inv h) typed
  subst listType
  obtain ⟨root, ys, os, roots, element, certificate, lookup, receiverNamed, noUnk, _, elemT, elemShape,
    elemsShaped, elemsDescribed, lenO, elemsTyped, pointwise, pairedList, described,
    valueReceiver, heapReceiver, abstractReceiver⟩ := flat_atom_list_path inv receiverTyped coveredR
  obtain ⟨i, valueIndex, heapIndex, abstractIndex⟩ := flat_atom_integer inv indexTyped coveredI
  obtain ⟨o, w, aN, valueItem, heapItem, abstractItem, pairedN, describedN, observedN, _, _, shapeN,
    allocatedN, _, _⟩ := flat_atom_values inv itemTyped coveredV
  have abstractAtoms : [receiver, index, item].mapM (m := Except String) (abstractAtom aenv) =
      .ok [.list roots element certificate, .scalar, aN] :=
    except_mapM_cons abstractReceiver (except_mapM_cons abstractIndex (except_mapM_cons abstractItem rfl))
  obtain ⟨childFuel, _, scope, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  have demanded := primitive_set_demand_run run
  rw [show ({ctx with escaped := union ctx.escaped before.facts.escapes} : Context).config = {} from
    defaultConfig, liveCellsWith_default] at demanded
  have escapesEq := demand_success_escapes demanded
  have resultEq := primitive_set_result_values
    (show ({ctx with escaped := union ctx.escaped before.facts.escapes} : Context).config = {} from
      defaultConfig) run
  obtain ⟨footprint, represented⟩ := inv.observers
  have rootOutside : root ∉ footprint :=
    demand_success_observer_footprint inv.toInvariant demanded receiverNamed represented
  have separate := demand_success_live_separate inv.separating demanded
  have apart := live_path_apart inv scope afterSub receiverNamed separate
  have itemApartRoot : ¬ Reaches hs.heap w (.ref root) :=
    value_apart_root shapeN describedN.1.1 receiverNamed (demand_success_disjoint inv.separating demanded)
      (fun o' member => mem_union _ _ _ (Or.inr member))
  refine ⟨.list t elemT, escapesEq, by rw [resultEq]; exact .list _ _ _ _ noUnk (flatAbstract_join elemShape shapeN),
    ?_, ?_⟩
  · intro value vs' run'
    have valueAtoms : [receiver, index, item].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
        .ok [.list os, .int i, o] :=
      except_mapM_cons valueReceiver (except_mapM_cons valueIndex (except_mapM_cons valueItem rfl))
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run'
      simp [noDepth] at run'
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run'
        simp [noDepth, noFuel] at run'
      · obtain ⟨valueRun, heapRun⟩ := set_runtime_success inv valueReceiver heapReceiver valueIndex
          heapIndex valueItem heapItem lookup rootOutside represented noDepth noFuel
        rw [valueRun] at run'
        cases run'
        have valid : root < hs.heap.size := (Array.getElem?_eq_some_iff.mp lookup).1
        have heapEq : (heapObserved (heapSetValues hs root ys i w) vs.kept.toList).heap =
            hs.heap.set! root (setVals ys i w) := by
          rw [heapObserved_heap]; rfl
        have lookupNew : (hs.heap.set! root (setVals ys i w))[root]? = some (setVals ys i w) := by simp [valid]
        have sizeEq : (hs.heap.set! root (setVals ys i w)).size = hs.heap.size := by simp
        obtain ⟨cs0, represented0⟩ := represents_of_snapshot _ _ _ (pairedList _ (Nat.le_refl _))
        have agreeOld : ∀ y ∈ ys, ∀ c, Reaches hs.heap y (.ref c) →
            (hs.heap.set! root (setVals ys i w))[c]? = hs.heap[c]? :=
          fun y member => element_agree_after_write represented0 lookup member
        have agreeItem : ∀ c, Reaches hs.heap w (.ref c) →
            (hs.heap.set! root (setVals ys i w))[c]? = hs.heap[c]? :=
          fun c reach => lookup_set_other hs.heap root _ (fun same => itemApartRoot (same ▸ reach))
        have shapedZ : ∀ z ∈ setVals ys i w, AllocatedFlatValue (hs.heap.set! root (setVals ys i w)) z t := by
          intro z member
          rcases mem_setVals member with old | new
          · exact allocated_of_agree (elemsShaped z old) (agreeOld z old)
          · rw [new]
            exact allocated_of_agree allocatedN agreeItem
        have shapedNew : AllocatedFlatValue (hs.heap.set! root (setVals ys i w)) (.ref root) (.list t) :=
          .list root _ t lookupNew shapedZ
        have rootApart : ∀ z ∈ setVals ys i w, ¬ Reaches (hs.heap.set! root (setVals ys i w)) z (.ref root) := by
          intro z member reach
          rcases mem_setVals member with old | new
          · exact no_element_reaches_root lookup old _ _ (Nat.le_refl _) _ _ represented0
              (reaches_of_agree_rev (agreeOld z old) reach)
          · rw [new] at reach
            exact itemApartRoot (reaches_of_agree_rev agreeItem reach)
        have elementsDescribed' : ∀ z ∈ setVals ys i w,
            Describes gamma (hs.heap.set! root (setVals ys i w)) (element.join aN) z := by
          intro z member
          rcases mem_setVals member with old | new
          · exact describes_join (allocated_of_agree (elemsShaped z old) (agreeOld z old)) elemShape shapeN
              (Or.inl (describes_of_agree (agreeOld z old) (elemsDescribed z old)))
          · rw [new]
            exact describes_join (allocated_of_agree allocatedN agreeItem) elemShape shapeN
              (Or.inr (describes_of_agree agreeItem describedN))
        have oldCert := described.1.2 [] roots element certificate (.ref root) rfl (.here _)
        -- the item's apartness from the old elements, each way the store tests state it
        have deepFacts : ∀ later : List Origin,
            storeExclusive {ctx with escaped := union ctx.escaped before.facts.escapes} [aN] later element.cells = true →
            (∀ n o' fp, Represents hs.heap n w o' fp → fp.Nodup) ∧
            (∀ y ∈ ys, ∀ c, Reaches hs.heap w (.ref c) → ¬ Reaches hs.heap y (.ref c)) := by
          intro later exclusive
          obtain ⟨deepI, sepI, overlapI⟩ := storeExclusive_facts exclusive
          exact ⟨nodup_of_deepExclusive allocatedN shapeN describedN deepI
              (pathsApart_of_separated inv.separating sepI),
            fun y member c reachI reachY => reach_apart_of_covers inv.separating shapeN elemShape
              describedN.1.1 (elemsDescribed y member).1.1 (cellOverlap_union_right_false overlapI).2 c reachI reachY⟩
        have spineFacts : ∀ later : List Origin,
            storeSpines {ctx with escaped := union ctx.escaped before.facts.escapes} [aN] later element.cells = true →
            (containers element).all (fun (_, old) =>
              individuallyOwned {ctx with escaped := union ctx.escaped before.facts.escapes} old &&
                !cellOverlap old aN.cells) = true →
            (∀ n o' fp, Represents hs.heap n w o' fp →
              ∀ p c, containerPath p = true → ArrayAt hs.heap w p c → fp.count c = 1) ∧
            (∀ p c, containerPath p = true → ArrayAt hs.heap (.ref root) (.element :: p) c →
              ¬ Reaches hs.heap w (.ref c)) ∧
            (∀ p c, containerPath p = true → ArrayAt hs.heap w p c →
              ∀ y ∈ ys, ¬ Reaches hs.heap y (.ref c)) := by
          intro later spines containersOk
          refine ⟨once_of_storeSpines inv.separating shapeN allocatedN describedN.1.1 spines, ?_, ?_⟩
          · intro p c container located reachI
            cases located with
            | element lookup'' yMember inner =>
              rw [lookup] at lookup''
              cases lookup''
              obtain ⟨o', m', a'⟩ := (elemsDescribed _ yMember).1.1 p c inner
              obtain ⟨cs, entry, inCs⟩ :=
                mem_namesAt_of_arrayAt elemShape (elemsShaped _ yMember) p c o' inner m'
              exact cell_apart_of_covers inv.separating shapeN describedN.1.1 ⟨o', inCs, a'⟩
                (containers_all_facts containersOk (p, cs) (List.mem_filter.mpr ⟨entry, container⟩)) reachI
          · intro p c container located y yMember reachY
            obtain ⟨o', m', a'⟩ := describedN.1.1 p c located
            obtain ⟨cs, entry, inCs⟩ := mem_namesAt_of_arrayAt shapeN allocatedN p c o' located m'
            have disjoint :=
              ((storeSpines_facts spines).2 (p, cs) (List.mem_filter.mpr ⟨entry, container⟩)).1
            exact cell_apart_of_covers inv.separating elemShape (elemsDescribed y yMember).1.1 ⟨o', inCs, a'⟩
              (cellOverlap_union_right_false disjoint).2 reachY
        have describedNew : Describes gamma (hs.heap.set! root (setVals ys i w)) result (.ref root) := by
          rw [resultEq]
          refine list_described_of_elements receiverNamed noUnk lookupNew shapedNew elementsDescribed' ?_ ?_
          · intro d
            obtain ⟨oldDeep, exclusive⟩ := Bool.and_eq_true_iff.mp d
            obtain ⟨itemNodup, itemApart⟩ := deepFacts _ exclusive
            by_cases inRange : 0 ≤ i ∧ i.toNat < ys.length
            · obtain ⟨nonneg, lt⟩ := inRange
              have decomposed : setVals ys i w = ys.take i.toNat ++ w :: ys.drop (i.toNat + 1) := by
                unfold setVals
                rw [if_neg (by omega), List.set_eq_take_append_cons_drop, if_pos lt]
              have lookup' : hs.heap[root]? = some (ys.take i.toNat ++ [ys[i.toNat]] ++ ys.drop (i.toNat + 1)) := by
                rw [List.append_assoc, List.singleton_append, ← List.drop_eq_getElem_cons lt,
                  List.take_append_drop]
                exact lookup
              have lookupNew' : (hs.heap.set! root (setVals ys i w))[root]? =
                  some (ys.take i.toNat ++ w :: ys.drop (i.toNat + 1)) := by
                rw [lookupNew, decomposed]
              have oldMember : ∀ y ∈ ys.take i.toNat ++ [ys[i.toNat]] ++ ys.drop (i.toNat + 1), y ∈ ys := by
                intro y member
                rwa [List.append_assoc, List.singleton_append, ← List.drop_eq_getElem_cons lt,
                  List.take_append_drop] at member
              have rootApart' : ∀ z ∈ ys.take i.toNat ++ w :: ys.drop (i.toNat + 1),
                  ¬ Reaches (hs.heap.set! root (setVals ys i w)) z (.ref root) := by
                intro z member
                rw [← decomposed] at member
                exact rootApart z member
              exact inserted_footprint_nodup lookup' lookupNew' represented0
                (fun y member => agreeOld y (oldMember y member)) agreeItem rootApart'
                (fun n o' fp rep => (oldCert n o' fp rep).1 oldDeep) itemNodup
                (fun y member => itemApart y (oldMember y member))
            · -- the list is unchanged: every array the root reaches keeps its contents
              have unchanged : setVals ys i w = ys := by
                unfold setVals
                split
                · rfl
                · exact List.set_eq_of_length_le (by omega)
              have agreeAll : ∀ (c : Nat), (hs.heap.set! root (setVals ys i w))[c]? = hs.heap[c]? := by
                intro c
                by_cases same : c = root
                · subst same
                  rw [lookupNew, unchanged, lookup]
                · exact lookup_set_other hs.heap root _ same
              intro n o' fp rep
              exact (oldCert n o' fp (represents_of_agree_rev (fun c _ => agreeAll c) rep)).1 oldDeep
          · intro sp
            have h := Bool.and_eq_true_iff.mp sp
            obtain ⟨oldSpine, spines⟩ := Bool.and_eq_true_iff.mp h.1
            obtain ⟨itemOnce, itemApartOld, oldApartItem⟩ := spineFacts _ spines h.2
            by_cases inRange : 0 ≤ i ∧ i.toNat < ys.length
            · obtain ⟨nonneg, lt⟩ := inRange
              have decomposed : setVals ys i w = ys.take i.toNat ++ w :: ys.drop (i.toNat + 1) := by
                unfold setVals
                rw [if_neg (by omega), List.set_eq_take_append_cons_drop, if_pos lt]
              have lookup' : hs.heap[root]? = some (ys.take i.toNat ++ [ys[i.toNat]] ++ ys.drop (i.toNat + 1)) := by
                rw [List.append_assoc, List.singleton_append, ← List.drop_eq_getElem_cons lt,
                  List.take_append_drop]
                exact lookup
              have lookupNew' : (hs.heap.set! root (setVals ys i w))[root]? =
                  some (ys.take i.toNat ++ w :: ys.drop (i.toNat + 1)) := by
                rw [lookupNew, decomposed]
              have oldMember : ∀ y ∈ ys.take i.toNat ++ [ys[i.toNat]] ++ ys.drop (i.toNat + 1), y ∈ ys := by
                intro y member
                rwa [List.append_assoc, List.singleton_append, ← List.drop_eq_getElem_cons lt,
                  List.take_append_drop] at member
              have rootApart' : ∀ z ∈ ys.take i.toNat ++ w :: ys.drop (i.toNat + 1),
                  ¬ Reaches (hs.heap.set! root (setVals ys i w)) z (.ref root) := by
                intro z member
                rw [← decomposed] at member
                exact rootApart z member
              exact inserted_footprint_once lookup' lookupNew' represented0
                (fun y member => agreeOld y (oldMember y member)) agreeItem rootApart'
                (fun n o' fp rep => (oldCert n o' fp rep).2 oldSpine) itemOnce itemApartOld
                (fun p c container located y member => oldApartItem p c container located y (oldMember y member))
            · have unchanged : setVals ys i w = ys := by
                unfold setVals
                split
                · rfl
                · exact List.set_eq_of_length_le (by omega)
              have agreeAll : ∀ (c : Nat), (hs.heap.set! root (setVals ys i w))[c]? = hs.heap[c]? := by
                intro c
                by_cases same : c = root
                · subst same
                  rw [lookupNew, unchanged, lookup]
                · exact lookup_set_other hs.heap root _ same
              intro n o' fp rep p c container located
              exact (oldCert n o' fp (represents_of_agree_rev (fun c _ => agreeAll c) rep)).2 oldSpine p c
                container (atPath_of_agree_rev (fun c _ => agreeAll c) located)
        refine ⟨.ref root, heapObserved (heapSetValues hs root ys i w) vs.kept.toList, gamma, heapRun, ?_,
          Nat.le_of_eq (by rw [heapEq, sizeEq]), ?_, ?_, ?_, ?_, ?_,
          by rw [resultEq]; exact .list _ _ _ _ _, .list _ _ _⟩
        · rw [escapesEq]
          refine flatInvariant_heap_frame inv (hole := root) (footprint := footprint) afterSub
            (by rw [heapEq, sizeEq]; exact Nat.le_refl _) ⟨setVals ys i w, by rw [heapEq]; exact lookupNew, ?_⟩
            (by rw [heapObserved_links]; exact inv.links) ?_ apart represented rootOutside
            (by rw [heapObserved_kept]; rfl) (by rw [valueObserved_kept]; rfl) (fun _ _ _ => Iff.rfl)
            (by rw [heapEq, sizeEq]; exact inv.namingBound) inv.separating
            (by rw [valueObserved_reads, heapObserved_reads]; exact inv.reads)
            (observed_external (valueTicked vs) (heapSetValues hs root ys i w) inv.keptSize inv.external)
            (by rw [valueObserved_fuel, heapObserved_fuel]; simp [valueTicked, heapSetValues, inv.fuel])
            (fun _ escaped => escaped)
          · intro z member d reach
            rw [heapEq] at reach ⊢
            exact allocated_reach_bound (shapedZ z member) reach
          · intro c different
            rw [heapEq]
            exact lookup_set_other hs.heap root _ different
        · rw [heapEq]
          exact corresponds_list_of_elements lookupNew (setObs_length i lenO)
            (pointwise_set lenO (fun k o' y os_k ys_k =>
              corresponds_of_agree (agreeOld y (List.mem_of_getElem? ys_k)) (pointwise k o' y os_k ys_k))
              (corresponds_of_agree agreeItem pairedN) i)
        · rw [heapEq]; exact describedNew
        · exact obsTyped_list_of_elements (fun o' member => by
            unfold setObs at member
            split at member
            · exact elemsTyped o' member
            · rcases List.mem_or_eq_of_mem_set member with old | new
              · exact elemsTyped o' old
              · rw [new]; exact observedN)
        · rw [heapEq]; exact valueTyped_of_allocated shapedNew
        · rw [heapEq]; exact shapedNew
  · intro message failed
    exact set_failure inv valueReceiver heapReceiver valueIndex heapIndex valueItem heapItem lookup
      rootOutside represented failed

/-! ### The copy -/

theorem value_copy_run (s : ValueSemantics.State) (os : List Observation) :
    (ValueSemantics.prim .copy [.list os]).run s = .ok (.list os, s) := rfl

theorem heap_copy_prim_run (hs : State) (ys : List Value)
    (lookup : hs.heap[root]? = some ys) :
    (prim .copy [.ref root]).run (heapTicked hs) = .ok (.ref hs.heap.size, heapAllocatedValues hs ys) := by
  simp [prim, array, alloc, lookup, heapTicked, heapAllocatedValues, Option.toExcept, StateT.run,
    StateT.bind, StateT.map, StateT.get, StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure,
    bind, pure, get, getThe, set, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift]

theorem copy_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {receiver : Atom} {os : List Observation} {ys : List Value} {root : Nat} {depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueReceiver : ValueSemantics.atom (valueEnv env) receiver = .ok (.list os))
    (heapReceiver : InPlaceSemantics.atom (heapEnv env) receiver = .ok (.ref root))
    (lookup : hs.heap[root]? = some ys)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim .copy [receiver])).run vs =
      .ok (.list os, valueObserved (valueTicked vs)) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim .copy [receiver])).run hs =
      .ok (.ref hs.heap.size, heapObserved (heapAllocatedValues hs ys) vs.kept.toList) := by
  obtain ⟨footprint, represented⟩ := inv.observers
  have valueObservedRun := value_observeKept_run (valueTicked vs) represented
  have heapObservedRun := heap_observeKept_run (heapAllocatedValues hs ys)
    (representsMany_after_alloc (xs := ys) represented)
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have valueAtoms : [receiver].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.list os] := except_mapM_cons valueReceiver rfl
  have heapAtoms : [receiver].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref root] := except_mapM_cons heapReceiver rfl
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, value_copy_run, valueObservedRun, Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, heap_copy_prim_run hs ys lookup, heapObservedRun,
      Except.bind, Except.pure, bind, pure]

theorem copy_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {receiver : Atom} {type : Ty} {self : Decl} {ctx : Context} {after : Live} {site : List Nat} {before next : St} {result : Abstract} {inferenceFuel depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.prim .copy [receiver]) = .ok type)
    (covered : ∀ use ∈ atomUses receiver, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim .copy [receiver]) after site).run before =
      .ok (result, next)) :
    FlatType type ∧ next.facts.escapes = before.facts.escapes ∧ FlatAbstract type result ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .copy [receiver])).run vs = .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .copy [receiver])).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv next.facts.escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧ Describes gamma' hs'.heap result actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        AllocatedFlatValue hs'.heap actual type ∧
        ResultTags type result actual ∧ ChainTags type result value) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .copy [receiver])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .copy [receiver])).run hs = .error actualMessage) := by
  obtain ⟨t, receiverTyped, listType⟩ := exprType_copy_success (fun _ _ h => flat_atom_type inv h) typed
  subst listType
  obtain ⟨root, ys, os, roots, element, certificate, lookup, _, _, _, elemT, elemShape, elemsShaped,
    elemsDescribed, lenO, elemsTyped, pointwise, _, _, valueReceiver, heapReceiver, abstractReceiver⟩ :=
    flat_atom_list_path inv receiverTyped covered
  have abstractAtoms : [receiver].mapM (m := Except String) (abstractAtom aenv) =
      .ok [.list roots element certificate] := except_mapM_cons abstractReceiver rfl
  obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  rw [primitive_copy_run] at run
  have equal := Except.ok.inj run
  have resultEq : result = .list [.site site 0] element ⟨false, false⟩ := by
    have h := (congrArg Prod.fst equal).symm
    rw [show ({ctx with escaped := union ctx.escaped before.facts.escapes} : Context).config = {} from
      defaultConfig, default_has] at h
    exact h
  have nextState : next = {before with facts := {before.facts with
      reads := union before.facts.reads (roots.filter external)}} := (congrArg Prod.snd equal).symm
  have nextEscapes : next.facts.escapes = before.facts.escapes := by
    subst nextState; rfl
  have valueAtoms : [receiver].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.list os] := except_mapM_cons valueReceiver rfl
  have heapAtoms : [receiver].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref root] := except_mapM_cons heapReceiver rfl
  refine ⟨.list t elemT, nextEscapes, by rw [resultEq]; exact .list _ _ _ _ (by simp) elemShape, ?_, ?_⟩
  · intro value vs' run
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
      simp [noDepth] at run
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
        simp [noDepth, noFuel] at run
      · obtain ⟨valueRun, heapRun⟩ := copy_runtime_success inv valueReceiver heapReceiver lookup noDepth noFuel
        rw [valueRun] at run
        cases run
        have heapEq : (heapObserved (heapAllocatedValues hs ys) vs.kept.toList).heap = hs.heap.push ys := by
          rw [heapObserved_heap]; rfl
        have agree : ∀ y ∈ ys, ∀ c, Reaches hs.heap y (.ref c) → (hs.heap.push ys)[c]? = hs.heap[c]? := by
          intro y member c reach
          have bound := allocated_reach_bound (elemsShaped y member) reach
          simp [Array.getElem?_push, Nat.ne_of_lt bound]
        obtain ⟨gamma', postInvariant, fresh, old⟩ := alloc_post_invariant inv ys site heapEq
          (by rw [heapObserved_links]; exact inv.links)
          (fun y member d reach => by
            rw [heapEq] at reach ⊢
            simp only [Array.size_push]
            exact Nat.lt_succ_of_lt (allocated_reach_bound (elemsShaped y member)
              (reaches_of_agree_rev (agree y member) reach)))
          (by rw [heapObserved_kept]; rfl)
          (by rw [valueObserved_kept]; rfl) (by rw [valueObserved_reads, heapObserved_reads]; exact inv.reads)
          (observed_external (valueTicked vs) (heapAllocatedValues hs ys) inv.keptSize inv.external)
          (by rw [valueObserved_fuel, heapObserved_fuel]; simp [valueTicked, heapAllocatedValues, inv.fuel])
        have lookupNew : (hs.heap.push ys)[hs.heap.size]? = some ys := by simp
        have shapedNew : AllocatedFlatValue (hs.heap.push ys) (.ref hs.heap.size) (.list t) :=
          .list _ ys t lookupNew (fun y member => allocated_of_agree (elemsShaped y member) (agree y member))
        have rootNamed : named gamma' [.site site 0] hs.heap.size := ⟨.site site 0, by simp, fresh⟩
        refine ⟨.ref hs.heap.size, heapObserved (heapAllocatedValues hs ys) vs.kept.toList, gamma',
          heapRun, by rw [nextEscapes]; exact postInvariant, ?_, ?_, ?_, obsTyped_list_of_elements elemsTyped, ?_,
          by rw [heapEq]; exact shapedNew, by rw [resultEq]; exact .list _ _ _ _ _, .list _ _ _⟩
        · rw [heapEq]; simp
        · rw [heapEq]
          exact corresponds_list_of_elements lookupNew lenO
            (fun i o y os_i ys_i => corresponds_of_agree (agree y (List.mem_of_getElem? ys_i)) (pointwise i o y os_i ys_i))
        · rw [heapEq, resultEq]
          refine list_described_of_elements rootNamed (by simp) lookupNew shapedNew ?_
            (fun h => by simp at h) (fun h => by simp at h)
          intro y member
          exact describes_of_agree (agree y member) (describes_naming_same (elemsShaped y member) old
            (fun c reach => allocated_reach_bound (elemsShaped y member) reach) (elemsDescribed y member))
        · rw [heapEq]
          exact valueTyped_list_of_elements lookupNew
            (fun y member => valueTyped_of_allocated (allocated_of_agree (elemsShaped y member) (agree y member)))
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
      · have success := (copy_runtime_success inv valueReceiver heapReceiver lookup noDepth noFuel).1
        rw [success] at failed
        contradiction

/-! ### The prepend -/

/-- The checker's prepend result under the default configuration: a fresh root
with the old roots, the item joined into the element, and the certificate of
the store tests. -/
theorem primitive_prepend_run_values (ctx : Context) (defaultConfig : ctx.config = {}) (site : List Nat)
    (item : Abstract) (roots : List Origin) (element : Abstract) (certificate : Certificate)
    (later : List Origin) (before : St) :
    (primitive ctx site .prepend [item, .list roots element certificate] later).run before =
      .ok (.list (union [.site site 0] roots) (item.join element)
        ⟨certificate.deep && storeExclusive ctx [item] later element.cells,
         certificate.spine && storeSpines ctx [item] later element.cells &&
           (containers element).all (fun (_, old) => individuallyOwned ctx old && !cellOverlap old item.cells)⟩,
        {before with facts := {before.facts with reads := union before.facts.reads (roots.filter external)}}) := by
  unfold primitive
  simp only [defaultConfig, default_has, Bool.false_or]
  rfl

def valuePrependedValues (vs : ValueSemantics.State) (os : List Observation) : ValueSemantics.State :=
  { vs with fuel := vs.fuel - 1, reads := vs.reads.push (.list os) }

def heapPrependedValues (hs : State) (ys : List Value) (os : List Observation) (item : Value) : State :=
  { hs with fuel := hs.fuel - 1, reads := hs.reads.push (.list os), heap := hs.heap.push (item :: ys) }

theorem value_prepend_run_values (s : ValueSemantics.State) (o : Observation) (os : List Observation)
    (shallow : ¬ (Observation.list os).depth > observationDepth) :
    (ValueSemantics.prim .prepend [o, .list os]).run s =
      .ok (.list (o :: os), {s with reads := s.reads.push (.list os)}) := by
  simp [ValueSemantics.prim, ValueSemantics.read, ValueSemantics.observable, shallow, StateT.run,
    StateT.bind, StateT.map, StateT.get, StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind,
    pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, modify,
    modifyGet, MonadStateOf.modifyGet, StateT.modifyGet]

theorem value_prepend_run_deep (s : ValueSemantics.State) (o : Observation) (os : List Observation)
    (deep : (Observation.list os).depth > observationDepth) :
    (ValueSemantics.prim .prepend [o, .list os]).run s = .error "snapshot exhausted depth" := by
  simp [ValueSemantics.prim, ValueSemantics.read, ValueSemantics.observable, deep, StateT.run,
    StateT.bind, StateT.map, StateT.get, StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind,
    pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, modify,
    modifyGet, MonadStateOf.modifyGet, StateT.modifyGet, throw, throwThe, MonadExceptOf.throw, Except.error]

theorem heap_prepend_run_values (hs : State) (w : Value) (ys : List Value) {os : List Observation}
    (lookup : hs.heap[root]? = some ys)
    (snap : snapshot hs.heap observationDepth (.ref root) = .ok (.list os)) :
    (prim .prepend [w, .ref root]).run (heapTicked hs) =
      .ok (.ref hs.heap.size, heapPrependedValues hs ys os w) := by
  simp [prim, array, alloc, InPlaceSemantics.read, lookup, snap, heapTicked, heapPrependedValues,
    Option.toExcept, StateT.run, StateT.bind, StateT.map, StateT.get, StateT.set, StateT.lift, Except.bind,
    Except.pure, StateT.pure, bind, pure, get, getThe, set, MonadStateOf.get, MonadStateOf.set, liftM,
    monadLift, MonadLift.monadLift, modify, modifyGet, MonadStateOf.modifyGet, StateT.modifyGet]

theorem heap_prepend_run_deep (hs : State) (w : Value) (ys : List Value) {e : String}
    (lookup : hs.heap[root]? = some ys)
    (snap : snapshot hs.heap observationDepth (.ref root) = .error e) :
    (prim .prepend [w, .ref root]).run (heapTicked hs) = .error e := by
  simp [prim, array, InPlaceSemantics.read, lookup, snap, heapTicked, Option.toExcept, StateT.run,
    StateT.bind, StateT.map, StateT.get, StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind,
    pure, get, getThe, set, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, modify,
    modifyGet, MonadStateOf.modifyGet, StateT.modifyGet]

theorem prepend_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {item receiver : Atom} {os : List Observation} {ys : List Value} {o : Observation} {w : Value} {root : Nat} {depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueItem : ValueSemantics.atom (valueEnv env) item = .ok o)
    (heapItem : InPlaceSemantics.atom (heapEnv env) item = .ok w)
    (valueReceiver : ValueSemantics.atom (valueEnv env) receiver = .ok (.list os))
    (heapReceiver : InPlaceSemantics.atom (heapEnv env) receiver = .ok (.ref root))
    (lookup : hs.heap[root]? = some ys)
    (snap : snapshot hs.heap observationDepth (.ref root) = .ok (.list os))
    (shallow : ¬ (Observation.list os).depth > observationDepth)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim .prepend [item, receiver])).run vs =
      .ok (.list (o :: os), valueObserved (valuePrependedValues vs os)) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim .prepend [item, receiver])).run hs =
      .ok (.ref hs.heap.size, heapObserved (heapPrependedValues hs ys os w) vs.kept.toList) := by
  obtain ⟨footprint, represented⟩ := inv.observers
  have valueObservedRun := value_observeKept_run (valuePrependedValues vs os) represented
  simp only [valuePrependedValues] at valueObservedRun
  have heapObservedRun := heap_observeKept_run (heapPrependedValues hs ys os w)
    (representsMany_after_alloc (xs := w :: ys) represented)
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have valueAtoms : [item, receiver].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [o, .list os] := except_mapM_cons valueItem (except_mapM_cons valueReceiver rfl)
  have heapAtoms : [item, receiver].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [w, .ref root] := except_mapM_cons heapItem (except_mapM_cons heapReceiver rfl)
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, valueTicked, value_prepend_run_values (valueTicked vs) o os shallow,
      value_prepend_run_values {vs with fuel := vs.fuel - 1} o os shallow, valueObservedRun,
      valuePrependedValues, Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, heap_prepend_run_values hs w ys lookup snap, heapObservedRun,
      Except.bind, Except.pure, bind, pure]

theorem prepend_runtime_deep {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {item receiver : Atom} {os : List Observation} {ys : List Value} {w : Value} {root : Nat} {depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (heapItem : InPlaceSemantics.atom (heapEnv env) item = .ok w)
    (heapReceiver : InPlaceSemantics.atom (heapEnv env) receiver = .ok (.ref root))
    (lookup : hs.heap[root]? = some ys)
    (paired : Corresponds hs.heap (.list os) (.ref root))
    (deep : (Observation.list os).depth > observationDepth)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    ∃ e, (InPlaceSemantics.eval depth declarations none (heapEnv env)
      (.prim .prepend [item, receiver])).run hs = .error e := by
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have heapAtoms : [item, receiver].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [w, .ref root] := except_mapM_cons heapItem (except_mapM_cons heapReceiver rfl)
  obtain ⟨e, snapErr⟩ := Ownership.FlatFragment.Shared.snapshot_deep_error paired deep
  refine ⟨e, ?_⟩
  rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
  simp [hasDepth, heapFuel, heap_prepend_run_deep hs w ys lookup snapErr, Except.bind, bind]

theorem prepend_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {item receiver : Atom} {type : Ty} {self : Decl} {ctx : Context} {after : Live} {site : List Nat} {before next : St} {result : Abstract} {inferenceFuel depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.prim .prepend [item, receiver]) = .ok type)
    (coveredI : ∀ use ∈ atomUses item, use ∈ live)
    (coveredR : ∀ use ∈ atomUses receiver, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim .prepend [item, receiver]) after site).run before =
      .ok (result, next)) :
    FlatType type ∧ next.facts.escapes = before.facts.escapes ∧ FlatAbstract type result ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .prepend [item, receiver])).run vs = .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .prepend [item, receiver])).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv next.facts.escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧ Describes gamma' hs'.heap result actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        AllocatedFlatValue hs'.heap actual type ∧
        ResultTags type result actual ∧ ChainTags type result value) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .prepend [item, receiver])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .prepend [item, receiver])).run hs = .error actualMessage) := by
  obtain ⟨t, itemTyped, receiverTyped, listType⟩ :=
    exprType_prepend_success (fun _ _ h => flat_atom_type inv h) typed
  subst listType
  obtain ⟨o, w, aN, valueItem, heapItem, abstractItem, pairedN, describedN, observedN, _, _, shapeN,
    allocatedN, _, _⟩ := flat_atom_values inv itemTyped coveredI
  obtain ⟨root, ys, os, roots, element, certificate, lookup, receiverNamed, noUnk, _, elemT, elemShape,
    elemsShaped, elemsDescribed, lenO, elemsTyped, pointwise, pairedList, described,
    valueReceiver, heapReceiver, abstractReceiver⟩ := flat_atom_list_path inv receiverTyped coveredR
  have abstractAtoms : [item, receiver].mapM (m := Except String) (abstractAtom aenv) =
      .ok [aN, .list roots element certificate] :=
    except_mapM_cons abstractItem (except_mapM_cons abstractReceiver rfl)
  obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  rw [primitive_prepend_run_values _ (show ({ctx with escaped := union ctx.escaped before.facts.escapes} :
    Context).config = {} from defaultConfig)] at run
  obtain ⟨first, second⟩ := Prod.mk.inj (Except.ok.inj run)
  have resultEq := first.symm
  have nextEscapes : next.facts.escapes = before.facts.escapes := by
    rw [← second]
  have valueAtoms : [item, receiver].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [o, .list os] := except_mapM_cons valueItem (except_mapM_cons valueReceiver rfl)
  have heapAtoms : [item, receiver].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [w, .ref root] := except_mapM_cons heapItem (except_mapM_cons heapReceiver rfl)
  have noUnkNew : Origin.unknown ∉ union [.site site 0] roots := by
    intro member
    rcases mem_union_cases _ _ _ member with fresh | old
    · simp at fresh
    · exact noUnk old
  refine ⟨.list t elemT, nextEscapes,
    by rw [resultEq]; exact .list _ _ _ _ noUnkNew (flatAbstract_join shapeN elemShape), ?_, ?_⟩
  · intro value vs' run
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
      simp [noDepth] at run
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
        simp [noDepth, noFuel] at run
      · by_cases deep : (Observation.list os).depth > observationDepth
        · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
          simp [noDepth, noFuel, valueTicked, value_prepend_run_deep (valueTicked vs) o os deep,
            value_prepend_run_deep {vs with fuel := vs.fuel - 1} o os deep, Except.bind, bind] at run
        · have snap : snapshot hs.heap observationDepth (.ref root) = .ok (.list os) :=
            pairedList observationDepth (by omega)
          obtain ⟨valueRun, heapRun⟩ :=
            prepend_runtime_success inv valueItem heapItem valueReceiver heapReceiver lookup snap deep noDepth noFuel
          rw [valueRun] at run
          cases run
          have heapEq : (heapObserved (heapPrependedValues hs ys os w) vs.kept.toList).heap =
              hs.heap.push (w :: ys) := by
            rw [heapObserved_heap]; rfl
          have lookupNew : (hs.heap.push (w :: ys))[hs.heap.size]? = some (w :: ys) := by simp
          have agreeOld : ∀ y ∈ ys, ∀ c, Reaches hs.heap y (.ref c) → (hs.heap.push (w :: ys))[c]? = hs.heap[c]? := by
            intro y member c reach
            have bound := allocated_reach_bound (elemsShaped y member) reach
            simp [Array.getElem?_push, Nat.ne_of_lt bound]
          have agreeItem : ∀ c, Reaches hs.heap w (.ref c) → (hs.heap.push (w :: ys))[c]? = hs.heap[c]? := by
            intro c reach
            have bound := allocated_reach_bound allocatedN reach
            simp [Array.getElem?_push, Nat.ne_of_lt bound]
          have shapedZ : ∀ z ∈ w :: ys, AllocatedFlatValue (hs.heap.push (w :: ys)) z t := by
            intro z member
            rcases List.mem_cons.mp member with new | old
            · rw [new]; exact allocated_of_agree allocatedN agreeItem
            · exact allocated_of_agree (elemsShaped z old) (agreeOld z old)
          have shapedNew : AllocatedFlatValue (hs.heap.push (w :: ys)) (.ref hs.heap.size) (.list t) :=
            .list _ _ t lookupNew shapedZ
          obtain ⟨gamma', postInvariant, fresh, old⟩ := alloc_post_invariant inv (w :: ys) site heapEq
            (by rw [heapObserved_links]; exact inv.links)
            (fun z member d reach => by
              rw [heapEq] at reach ⊢
              exact allocated_reach_bound (shapedZ z member) reach)
            (by rw [heapObserved_kept]; rfl) (by rw [valueObserved_kept]; rfl)
            (by rw [valueObserved_reads, heapObserved_reads]; simp [valuePrependedValues, heapPrependedValues, inv.reads])
            (observed_external (valuePrependedValues vs os) (heapPrependedValues hs ys os w) inv.keptSize inv.external)
            (by rw [valueObserved_fuel, heapObserved_fuel]; simp [valuePrependedValues, heapPrependedValues, inv.fuel])
          have rootNamed' : named gamma' (union [.site site 0] roots) hs.heap.size :=
            ⟨.site site 0, mem_union _ _ _ (Or.inl (by simp)), fresh⟩
          have rootApart : ∀ z ∈ w :: ys, ¬ Reaches (hs.heap.push (w :: ys)) z (.ref hs.heap.size) := by
            intro z member reach
            have bound := allocated_reach_bound (shapedZ z member) reach
            rcases List.mem_cons.mp member with new | old
            · rw [new] at reach
              have := allocated_reach_bound allocatedN (reaches_of_agree_rev agreeItem reach)
              omega
            · have := allocated_reach_bound (elemsShaped z old) (reaches_of_agree_rev (agreeOld z old) reach)
              omega
          have belowSize : ∀ z ∈ w :: ys, ∀ c, Reaches hs.heap z (.ref c) → c < hs.heap.size := by
            intro z member c reach
            rcases List.mem_cons.mp member with new | old
            · rw [new] at reach; exact allocated_reach_bound allocatedN reach
            · exact allocated_reach_bound (elemsShaped z old) reach
          have describedOld' : ∀ z ∈ ys, Describes gamma' hs.heap element z := fun z member =>
            describes_naming_same (elemsShaped z member) old (fun c reach => allocated_reach_bound (elemsShaped z member) reach)
              (elemsDescribed z member)
          have describedN' : Describes gamma' hs.heap aN w :=
            describes_naming_same allocatedN old (fun c reach => allocated_reach_bound allocatedN reach) describedN
          have elementsDescribed' : ∀ z ∈ w :: ys,
              Describes gamma' (hs.heap.push (w :: ys)) (aN.join element) z := by
            intro z member
            rcases List.mem_cons.mp member with new | old'
            · rw [new]
              exact describes_join (allocated_of_agree allocatedN agreeItem) shapeN elemShape
                (Or.inl (describes_of_agree agreeItem describedN'))
            · exact describes_join (allocated_of_agree (elemsShaped z old') (agreeOld z old')) shapeN elemShape
                (Or.inr (describes_of_agree (agreeOld z old') (describedOld' z old')))
          obtain ⟨cs0, represented0⟩ := represents_of_snapshot _ _ _ (pairedList _ (Nat.le_refl _))
          have lookup' : hs.heap[root]? = some ([] ++ [] ++ ys) := by simpa using lookup
          have lookupNew' : (hs.heap.push (w :: ys))[hs.heap.size]? = some ([] ++ w :: ys) := by
            simpa using lookupNew
          have agreeOld' : ∀ y ∈ [] ++ [] ++ ys, ∀ c, Reaches hs.heap y (.ref c) →
              (hs.heap.push (w :: ys))[c]? = hs.heap[c]? :=
            fun y member => agreeOld y (by simpa using member)
          have rootApart' : ∀ z ∈ [] ++ w :: ys, ¬ Reaches (hs.heap.push (w :: ys)) z (.ref hs.heap.size) :=
            fun z member => rootApart z (by simpa using member)
          have oldCert := described.1.2 [] roots element certificate (.ref root) rfl (.here _)
          have describedNew : Describes gamma' (hs.heap.push (w :: ys)) result (.ref hs.heap.size) := by
            rw [resultEq]
            refine list_described_of_elements rootNamed' noUnkNew lookupNew shapedNew elementsDescribed' ?_ ?_
            · intro d
              obtain ⟨oldDeep, exclusive⟩ := Bool.and_eq_true_iff.mp d
              obtain ⟨deepI, sepI, overlapI⟩ := storeExclusive_facts exclusive
              exact inserted_footprint_nodup lookup' lookupNew' represented0 agreeOld' agreeItem rootApart'
                (fun n o' fp rep => (oldCert n o' fp rep).1 oldDeep)
                (nodup_of_deepExclusive allocatedN shapeN describedN deepI
                  (pathsApart_of_separated inv.separating sepI))
                (fun y member c reachI reachY => reach_apart_of_covers inv.separating shapeN elemShape
                  describedN.1.1 (elemsDescribed y (by simpa using member)).1.1
                  (cellOverlap_union_right_false overlapI).2 c reachI reachY)
            · intro sp
              have h := Bool.and_eq_true_iff.mp sp
              obtain ⟨oldSpine, spines⟩ := Bool.and_eq_true_iff.mp h.1
              have containersOk := h.2
              exact inserted_footprint_once lookup' lookupNew' represented0 agreeOld' agreeItem rootApart'
                (fun n o' fp rep => (oldCert n o' fp rep).2 oldSpine)
                (once_of_storeSpines inv.separating shapeN allocatedN describedN.1.1 spines)
                (fun p c container located reachI => by
                  cases located with
                  | element lookup'' yMember inner =>
                    rw [lookup] at lookup''
                    cases lookup''
                    obtain ⟨o', m', a'⟩ := (elemsDescribed _ yMember).1.1 p c inner
                    obtain ⟨cs, entry, inCs⟩ :=
                      mem_namesAt_of_arrayAt elemShape (elemsShaped _ yMember) p c o' inner m'
                    exact cell_apart_of_covers inv.separating shapeN describedN.1.1 ⟨o', inCs, a'⟩
                      (containers_all_facts containersOk (p, cs) (List.mem_filter.mpr ⟨entry, container⟩)) reachI)
                (fun p c container located y yMember reachY => by
                  obtain ⟨o', m', a'⟩ := describedN.1.1 p c located
                  obtain ⟨cs, entry, inCs⟩ := mem_namesAt_of_arrayAt shapeN allocatedN p c o' located m'
                  have disjoint :=
                    ((storeSpines_facts spines).2 (p, cs) (List.mem_filter.mpr ⟨entry, container⟩)).1
                  exact cell_apart_of_covers inv.separating elemShape
                    (elemsDescribed y (by simpa using yMember)).1.1 ⟨o', inCs, a'⟩
                    (cellOverlap_union_right_false disjoint).2 reachY)
          refine ⟨.ref hs.heap.size, heapObserved (heapPrependedValues hs ys os w) vs.kept.toList, gamma',
            heapRun, by rw [nextEscapes]; exact postInvariant, ?_, ?_, ?_, ?_, ?_, ?_,
            by rw [resultEq]; exact .list _ _ _ _ _, .list _ _ _⟩
          · rw [heapEq]; simp
          · rw [heapEq]
            exact corresponds_list_of_elements lookupNew (by simp [lenO]) (fun i o' y os_i ys_i => by
              cases i with
              | zero =>
                simp at os_i ys_i
                subst os_i; subst ys_i
                exact corresponds_of_agree agreeItem pairedN
              | succ k =>
                simp at os_i ys_i
                exact corresponds_of_agree (agreeOld y (List.mem_of_getElem? ys_i)) (pointwise k o' y os_i ys_i))
          · rw [heapEq]; exact describedNew
          · exact obsTyped_list_of_elements (fun o' member => by
              rcases List.mem_cons.mp member with new | old'
              · rw [new]; exact observedN
              · exact elemsTyped o' old')
          · rw [heapEq]; exact valueTyped_of_allocated shapedNew
          · rw [heapEq]; exact shapedNew
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
      · by_cases deep : (Observation.list os).depth > observationDepth
        · exact prepend_runtime_deep inv heapItem heapReceiver lookup pairedList deep noDepth noFuel
        · have snap : snapshot hs.heap observationDepth (.ref root) = .ok (.list os) :=
            pairedList observationDepth (by omega)
          have success := (prepend_runtime_success inv valueItem heapItem valueReceiver heapReceiver lookup
            snap deep noDepth noFuel).1
          rw [success] at failed
          contradiction

end Ownership.FlatFragment.ListPrimitives
