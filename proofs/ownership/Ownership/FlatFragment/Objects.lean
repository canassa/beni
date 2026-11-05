import Ownership.FlatFragment.View

/-! The first flat fragment: record objects (#316, slice 2).

A record object is a one-slot array whose element is the record, in both
interpreters and in the checker (`Syntax.lean`, `Ty.object`). A literal
allocates the slot; a field read reads the slot and then the field; a copy
allocates a new slot with the same record. The update, which writes the slot
in place, is `ObjectUpdate.lean`. -/

namespace Ownership.FlatFragment.Objects

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.StateFrame
open Ownership.FlatFragment.Observe Ownership.FlatFragment.Runtime Ownership.FlatFragment.HeapPreservation Ownership.FlatFragment.Description
open Ownership.FlatFragment.Atoms Ownership.FlatFragment.HeapFrame Ownership.FlatFragment.PrimitiveInference Ownership.FlatFragment.PrimitiveRuntime
open Ownership.FlatFragment.Naming Ownership.FlatFragment.Support Ownership.FlatFragment.IntegerCorrespondence Ownership.FlatFragment.Fields
open Ownership.FlatFragment.CheckerExtraction Ownership.FlatFragment.Literal Ownership.FlatFragment.Length Ownership.FlatFragment.Push
open Ownership.FlatFragment.LiveCells Ownership.FlatFragment.Scope Ownership.FlatFragment.NamingFacts
open Ownership.FlatFragment.Static Ownership.FlatFragment.ListPrimitives Ownership.FlatFragment.Let
open Ownership.FlatFragment.VariableFacts Ownership.FlatFragment.Env

/-! ### The record of the atoms' values -/

/-- The record of a list of live atoms: both runtimes read the atoms, and the
record has every fact of its fields, the facts `record_preserved` proves. -/
theorem record_value_facts {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {args : List Atom} {types : List Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (atomsTyped : args.mapM (atomType tenv) = .ok types)
    (covered : ∀ atom ∈ args, ∀ use ∈ atomUses atom, use ∈ live) :
    ∃ (os : List Observation) (ws : List Value) (as : List Abstract),
      args.mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) = .ok os ∧
      args.mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) = .ok ws ∧
      args.mapM (m := Except String) (abstractAtom aenv) = .ok as ∧
      as.length = types.length ∧
      Corresponds hs.heap (.record os) (.record ws) ∧
      Describes gamma hs.heap (entryAbstract declarations (.record types) (.record as)) (.record ws) ∧
      obsTyped declarations (.record os) (.record types) = true ∧
      FlatType (.record types) ∧ FlatAbstract (.record types) (.record as) ∧
      AllocatedFlatValue hs.heap (.record ws) (entryType (.record types)) ∧
      ResultTags (entryType (.record types)) (entryAbstract declarations (.record types) (.record as)) (.record ws) ∧
      ChainTags (entryType (.record types)) (entryAbstract declarations (.record types) (.record as)) (.record os) ∧
      TagsDeep hs.heap (entryType (.record types)) (entryAbstract declarations (.record types) (.record as)) (.record ws) ∧
      (∀ kinds, StateKinded kinds hs env tenv → Kinded kinds (.record types) (.record ws)) := by
  obtain ⟨os, ws, as, valueAtoms, heapAtoms, abstractAtoms, lenO, lenW, lenA, fields⟩ :=
    flat_atoms_values inv atomsTyped covered
  have witnesses : ∀ (i : Nat) (t : Ty), types[i]? = some t →
      ∃ o w a, os[i]? = some o ∧ ws[i]? = some w ∧ as[i]? = some a := by
    intro i t types_i
    obtain ⟨o, os_i⟩ := index_of_same_length lenO.symm types_i
    obtain ⟨w, ws_i⟩ := index_of_same_length lenW.symm types_i
    obtain ⟨a, as_i⟩ := index_of_same_length lenA.symm types_i
    exact ⟨o, w, a, os_i, ws_i, as_i⟩
  refine ⟨os, ws, as, valueAtoms, heapAtoms, abstractAtoms, lenA, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · refine corresponds_record_of_fields (lenO.trans lenW.symm) ?_
    intro i o w os_i ws_i
    obtain ⟨t, types_i⟩ := index_of_same_length lenO os_i
    obtain ⟨a, as_i⟩ := index_of_same_length lenA.symm types_i
    exact (fields i o w a t os_i ws_i as_i types_i).1
  · refine describes_record_of_fields (by rw [entryFields_length]; exact lenA.trans lenW.symm) ?_
    intro i a' w as_i ws_i
    obtain ⟨a, as_i', rfl⟩ := entryFields_index_inv as_i
    obtain ⟨t, types_i⟩ := index_of_same_length lenA as_i'
    obtain ⟨o, os_i⟩ := index_of_same_length lenO.symm types_i
    rw [types_i]
    exact (fields i o w a t os_i ws_i as_i' types_i).2.1
  · refine obsTyped_record_of_fields lenO ?_
    intro i o t os_i types_i
    obtain ⟨w, ws_i⟩ := index_of_same_length lenW.symm types_i
    obtain ⟨a, as_i⟩ := index_of_same_length lenA.symm types_i
    exact (fields i o w a t os_i ws_i as_i types_i).2.2.1
  · refine .record types ?_
    intro t member
    obtain ⟨i, types_i⟩ := List.mem_iff_getElem?.mp member
    obtain ⟨o, w, a, os_i, ws_i, as_i⟩ := witnesses i t types_i
    exact (fields i o w a t os_i ws_i as_i types_i).2.2.2.2.1
  · refine .record types as lenA.symm ?_
    intro i t a types_i as_i
    obtain ⟨o, w, a', os_i, ws_i, as_i'⟩ := witnesses i t types_i
    rw [as_i] at as_i'
    cases Option.some.inj as_i'
    exact (fields i o w a t os_i ws_i as_i types_i).2.2.2.2.2.1
  · refine .record ws (entryTypes types) (by rw [entryTypes_length]; exact lenW) ?_
    intro i w t' ws_i types_i
    obtain ⟨t, types_i', rfl⟩ := entryTypes_index_inv types_i
    obtain ⟨o, os_i⟩ := index_of_same_length lenO.symm types_i'
    obtain ⟨a, as_i⟩ := index_of_same_length lenA.symm types_i'
    exact (fields i o w a t os_i ws_i as_i types_i').2.2.2.2.2.2.1
  · refine .record (entryTypes types) (entryFields declarations types as) ws
      (by rw [entryTypes_length, entryFields_length]; exact lenA.symm) ?_
    intro i t' a' w types_i as_i ws_i
    obtain ⟨t, types_i', rfl⟩ := entryTypes_index_inv types_i
    obtain ⟨a, as_i', rfl⟩ := entryFields_index_inv as_i
    obtain ⟨o, os_i⟩ := index_of_same_length lenO.symm types_i'
    rw [types_i']
    exact (fields i o w a t os_i ws_i as_i' types_i').2.2.2.2.2.2.2.1
  · refine .record (entryTypes types) (entryFields declarations types as) os
      (by rw [entryTypes_length, entryFields_length]; exact lenA.symm) ?_
    intro i t' a' o types_i as_i os_i
    obtain ⟨t, types_i', rfl⟩ := entryTypes_index_inv types_i
    obtain ⟨a, as_i', rfl⟩ := entryFields_index_inv as_i
    obtain ⟨w, ws_i⟩ := index_of_same_length lenW.symm types_i'
    rw [types_i']
    exact (fields i o w a t os_i ws_i as_i' types_i').2.2.2.2.2.2.2.2.1
  · refine .record (entryTypes types) (entryFields declarations types as) ws
      (by rw [entryTypes_length, entryFields_length]; exact lenA.symm) ?_
    intro i t' a' w types_i as_i ws_i
    obtain ⟨t, types_i', rfl⟩ := entryTypes_index_inv types_i
    obtain ⟨a, as_i', rfl⟩ := entryFields_index_inv as_i
    obtain ⟨o, os_i⟩ := index_of_same_length lenO.symm types_i'
    rw [types_i']
    exact (fields i o w a t os_i ws_i as_i' types_i').2.2.2.2.2.2.2.2.2
  · intro kinds state
    exact .record types ws lenW (fun i t w types_i ws_i =>
      kinded_atoms inv state atomsTyped covered heapAtoms i w t ws_i types_i)

/-! ### The record literal -/

theorem value_object_run (s : ValueSemantics.State) (os : List Observation) :
    (ValueSemantics.prim .object os).run s = .ok (.list [.record os], s) := rfl

theorem heap_object_run (hs : State) (ws : List Value) :
    (prim .object ws).run (heapTicked hs) =
      .ok (.ref hs.heap.size, heapAllocatedValues hs [.record ws]) := rfl

theorem object_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {depth : Nat} {args : List Atom} {os : List Observation} {ws : List Value}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueAtoms : args.mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) = .ok os)
    (heapAtoms : args.mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) = .ok ws)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim .object args)).run vs =
      .ok (.list [.record os], valueObserved (valueTicked vs)) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim .object args)).run hs =
      .ok (.ref hs.heap.size, heapObserved (heapAllocatedValues hs [.record ws]) vs.kept.toList) := by
  obtain ⟨footprint, represented⟩ := inv.observers
  have valueObservedRun := value_observeKept_run (valueTicked vs) represented
  have heapObservedRun := heap_observeKept_run (heapAllocatedValues hs [.record ws])
    (representsMany_after_alloc (xs := [.record ws]) represented)
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, value_object_run, valueObservedRun, Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, heap_object_run, heapObservedRun, Except.bind, Except.pure, bind, pure]

/-- The record literal (#316): a fresh one-slot array that holds the record of
the atoms' values, named by the site, with the checker's certificates of one
stored record. -/
theorem object_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {args : List Atom} {self : Decl} {type : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.prim .object args) = .ok type)
    (covered : ∀ atom ∈ args, ∀ use ∈ atomUses atom, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim .object args) after site).run before =
      .ok (result, next)) :
    FlatType type ∧ next.facts.escapes = before.facts.escapes ∧ FlatAbstract type result ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env) (.prim .object args)).run vs =
        .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim .object args)).run hs =
          .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv next.facts.escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧
        Describes gamma' hs'.heap (entryAbstract declarations type result) actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        AllocatedFlatValue hs'.heap actual (entryType type) ∧
        ResultTags (entryType type) (entryAbstract declarations type result) actual ∧
        ChainTags (entryType type) (entryAbstract declarations type result) value ∧
        TagsDeep hs'.heap (entryType type) (entryAbstract declarations type result) actual ∧
        KindsAt hs' env tenv type actual) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env) (.prim .object args)).run vs =
        .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim .object args)).run hs =
          .error actualMessage) := by
  obtain ⟨types, atomsTyped, rfl⟩ := exprType_object_success typed
  obtain ⟨os, ws, as, valueAtoms, heapAtoms, abstractAtoms, lenA, paired, described, observed,
    flatRecord, shapeRecord, allocated, tags, chains, deep, kinded⟩ := record_value_facts inv atomsTyped covered
  have flatType : FlatType (.object types) := by
    cases flatRecord with
    | record _ fields => exact .object types fields
  obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  rw [primitive_object_run] at run
  obtain ⟨first, second⟩ := Prod.mk.inj (Except.ok.inj run)
  have resultEq := first.symm
  have nextEscapes : next.facts.escapes = before.facts.escapes := by rw [← second]
  -- The checker's result read through the type: the store tests give the same
  -- answers on the record's representation.
  obtain ⟨r, rDef⟩ : ∃ r, r = entryAbstract declarations (.record types) (.record as) := ⟨_, rfl⟩
  have resultRep : entryAbstract declarations (.object types) result =
      .list [.site site 0] r
        ⟨storeExclusive {ctx with escaped := union ctx.escaped before.facts.escapes} [r]
            (union (liveCellsWith ctx.config aenv after) ctx.pinned) [],
          storeSpines {ctx with escaped := union ctx.escaped before.facts.escapes} [r]
            (union (liveCellsWith ctx.config aenv after) ctx.pinned) []⟩ := by
    rw [resultEq, rDef]
    have single : ∀ a ∈ [Abstract.record as], FlatAbstract (.record types) a := by
      intro a member
      simp only [List.mem_singleton] at member
      subst member
      exact shapeRecord
    show Abstract.list [.site site 0] (entryAbstract declarations (.record types) (.record as)) _ = _
    rw [← storeExclusive_entry (ds := declarations) single, ← storeSpines_entry (ds := declarations) single]
    rfl
  simp only [← rDef] at described tags chains deep
  have shapeR : FlatAbstract (entryType (.record types)) r := by
    rw [rDef]; exact flatAbstract_entry shapeRecord
  refine ⟨flatType, nextEscapes, by rw [resultEq]; exact .object _ _ _ _ (by simp) shapeRecord, ?_, ?_⟩
  · intro value vs' run'
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run'
      simp [noDepth] at run'
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run'
        simp [noDepth, noFuel] at run'
      · obtain ⟨valueRun, heapRun⟩ := object_runtime_success inv valueAtoms heapAtoms noDepth noFuel
        rw [valueRun] at run'
        cases run'
        have heapEq : (heapObserved (heapAllocatedValues hs [.record ws]) vs.kept.toList).heap =
            hs.heap.push [.record ws] := by
          rw [heapObserved_heap]; rfl
        have lookupNew : (hs.heap.push [.record ws])[hs.heap.size]? = some [.record ws] := by simp
        have agree : ∀ c, Reaches hs.heap (.record ws) (.ref c) → (hs.heap.push [.record ws])[c]? = hs.heap[c]? := by
          intro c reach
          have bound := allocated_reach_bound allocated reach
          simp [Array.getElem?_push, Nat.ne_of_lt bound]
        have allocatedNew := allocated_of_agree allocated agree
        have shapedNew : AllocatedFlatValue (hs.heap.push [.record ws]) (.ref hs.heap.size)
            (entryType (.object types)) :=
          .object hs.heap.size (.record ws) (entryTypes types) lookupNew allocatedNew
        obtain ⟨kinds, state⟩ := inv.heapKinds
        obtain ⟨kinds', state', _, newTyped⟩ :=
          state.of_alloc (hs' := heapObserved (heapAllocatedValues hs [.record ws]) vs.kept.toList)
            (ContentsKinded.object types (.record ws) (kinded kinds state)) heapEq (by rw [heapObserved_links]; rfl)
        obtain ⟨gamma', postInvariant, fresh, old⟩ := alloc_post_invariant inv [.record ws] site heapEq
          (by rw [heapObserved_links]; rfl)
          (by rw [heapObserved_kept]; rfl) (by rw [valueObserved_kept]; rfl)
          (by rw [valueObserved_reads, heapObserved_reads]; exact inv.reads)
          (observed_external (valueTicked vs) (heapAllocatedValues hs [.record ws]) inv.keptSize inv.external)
          (by rw [valueObserved_fuel, heapObserved_fuel]; simp [valueTicked, heapAllocatedValues, inv.fuel])
          ⟨kinds', state'⟩
        have rootNamed' : named gamma' [.site site 0] hs.heap.size := ⟨.site site 0, by simp, fresh⟩
        have rootApart : ∀ w ∈ [Value.record ws], ¬ Reaches (hs.heap.push [.record ws]) w (.ref hs.heap.size) := by
          intro w member reach
          simp only [List.mem_singleton] at member
          subst member
          have := allocated_reach_bound allocated (reaches_of_agree_rev agree reach)
          omega
        have described' : Describes gamma' hs.heap r (.record ws) :=
          describes_naming_same allocated old (fun c reach => allocated_reach_bound allocated reach) described
        have describedNewRec : Describes gamma' (hs.heap.push [.record ws]) r (.record ws) :=
          describes_of_agree agree described'
        have describedNew : Describes gamma' (hs.heap.push [.record ws])
            (entryAbstract declarations (.object types) result) (.ref hs.heap.size) := by
          rw [resultRep]
          refine list_described_of_elements rootNamed' (by simp) lookupNew shapedNew
            (fun y member => by
              simp only [List.mem_singleton] at member
              subst member
              exact describedNewRec) ?_ ?_
          · intro d
            obtain ⟨deepAll, sepVals, _⟩ := storeExclusive_facts_many d
            obtain ⟨eachSep, _⟩ := separatedValues_sound sepVals
            refine fresh_footprint_nodup lookupNew rootApart ?_ ?_
            · intro i w ws_i n o fp rep
              have rMember : r ∈ [r] := by simp
              cases i with
              | zero =>
                simp only [List.getElem?_cons_zero, Option.some.injEq] at ws_i
                subst ws_i
                exact nodup_of_deepExclusive allocated shapeR described' (deepAll r rMember)
                  (pathsApart_of_separated postInvariant.separating (eachSep r rMember)) n o fp
                  (represents_of_agree_rev agree rep)
              | succ i => simp at ws_i
            · intro i j ne wi wj ws_i ws_j
              cases i with
              | zero =>
                cases j with
                | zero => exact absurd rfl ne
                | succ j => simp at ws_j
              | succ i => simp at ws_i
          · intro sp
            obtain ⟨sepFlat, perItem⟩ := storeSpines_facts_many sp
            refine fresh_footprint_once lookupNew rootApart ?_ ?_
            · intro i w ws_i n o fp rep p c container located
              have rMember : r ∈ [r] := by simp
              cases i with
              | zero =>
                simp only [List.getElem?_cons_zero, Option.some.injEq] at ws_i
                subst ws_i
                exact once_of_separated postInvariant.separating shapeR allocated described'.1.1
                  (separatedPaths_sublist (sublist_flatMap_of_mem rMember) sepFlat)
                  (fun e eMember f fMember => (perItem r rMember e eMember).2 r rMember f fMember)
                  n o fp (represents_of_agree_rev agree rep) p c container
                  (atPath_of_agree_rev agree located)
              | succ i => simp at ws_i
            · intro i j ne wi wj ws_i ws_j
              cases i with
              | zero =>
                cases j with
                | zero => exact absurd rfl ne
                | succ j => simp at ws_j
              | succ i => simp at ws_i
        have pairedNew : Corresponds (hs.heap.push [.record ws]) (.list [.record os]) (.ref hs.heap.size) :=
          corresponds_list_of_elements lookupNew rfl (fun i o w os_i ws_i => by
            cases i with
            | zero =>
              simp only [List.getElem?_cons_zero, Option.some.injEq] at os_i ws_i
              subst os_i; subst ws_i
              exact corresponds_of_agree agree paired
            | succ i => simp at os_i)
        have observedNew : obsTyped declarations (.list [.record os]) (.object types) = true :=
          obsTyped_object_of_slot observed
        refine ⟨.ref hs.heap.size, heapObserved (heapAllocatedValues hs [.record ws]) vs.kept.toList, gamma',
          heapRun, by rw [nextEscapes]; exact postInvariant, by rw [heapEq]; simp, ?_, ?_, observedNew, ?_, ?_,
          by rw [resultRep]; exact .object _ _ _ _ _, .object _ _ _, ?_, ⟨kinds', state', .object types _ newTyped⟩⟩
        · rw [heapEq]; exact pairedNew
        · rw [heapEq]; exact describedNew
        · rw [heapEq]; exact valueTyped_of_corresponds pairedNew observedNew
        · rw [heapEq]; exact shapedNew
        · rw [heapEq, resultRep]
          exact .object hs.heap.size [.record ws] (entryTypes types) _ r _ lookupNew
            (fun w member => by
              simp only [List.mem_singleton] at member
              subst member
              exact tags)
            (fun w member o pairedO => by
              simp only [List.mem_singleton] at member
              subst member
              exact (elementTags_of_corresponds (corresponds_of_agree agree paired) tags chains
                (tagsDeep_of_agree deep agree)).2.1 o pairedO)
            (fun w member => by
              simp only [List.mem_singleton] at member
              subst member
              exact tagsDeep_of_agree deep agree)
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
      · have success := (object_runtime_success inv valueAtoms heapAtoms noDepth noFuel).1
        rw [success] at failed
        contradiction

/-! ### A field read -/

/-- The observation of a field read through a record object's slot. -/
theorem projectObs_slot {o o' : Observation} {q : Path} {i : Nat}
    (projected : projectObs o (q ++ [.element, .field i]) = some o') :
    ∃ os, projectObs o q = some (.list [.record os]) ∧ os[i]? = some o' := by
  rw [projectObs_append] at projected
  cases found : projectObs o q with
  | none => rw [found] at projected; cases projected
  | some oq =>
    rw [found] at projected
    simp only [Option.bind_some] at projected
    cases oq with
    | list items =>
      match items, projected with
      | [x], projected =>
        cases x with
        | record os =>
          simp only [projectObs] at projected
          cases at_i : os[i]? with
          | none => rw [at_i] at projected; cases projected
          | some y =>
            rw [at_i] at projected
            simp only [projectObs, Option.some.injEq] at projected
            subst projected
            exact ⟨os, rfl, at_i⟩
        | _ => simp [projectObs] at projected
      | [], projected => simp [projectObs] at projected
      | _ :: _ :: _, projected => simp [projectObs] at projected
    | _ => simp [projectObs] at projected

theorem value_get_run (s : ValueSemantics.State) (i : Nat) (os : List Observation) {o : Observation}
    (found : os[i]? = some o) :
    (ValueSemantics.prim (.get i) [.list [.record os]]).run s = .ok (o, s) := by
  simp [ValueSemantics.prim, found, Option.toExcept, StateT.run, liftM, monadLift, MonadLift.monadLift,
    StateT.lift, bind, Except.bind, pure, Except.pure]

theorem heap_get_run (hs : State) (i : Nat) (c : Nat) (ws : List Value) {w : Value}
    (slot : hs.heap[c]? = some [.record ws]) (found : ws[i]? = some w) :
    (prim (.get i) [.ref c]).run hs = .ok (w, hs) := by
  simp [prim, array, slot, found, Option.toExcept, StateT.run, StateT.bind, StateT.get, StateT.lift,
    Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, liftM, monadLift,
    MonadLift.monadLift]

theorem get_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {receiver : Atom} {escapes : List Origin} {i : Nat} {os : List Observation} {ws : List Value} {c : Nat} {o : Observation} {w : Value}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueAtom : ValueSemantics.atom (valueEnv env) receiver = .ok (.list [.record os]))
    (heapAtom : InPlaceSemantics.atom (heapEnv env) receiver = .ok (.ref c))
    (slot : hs.heap[c]? = some [.record ws]) (foundO : os[i]? = some o) (foundW : ws[i]? = some w)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim (.get i) [receiver])).run vs =
      .ok (o, AtomPreservation.valueAtomPost vs) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim (.get i) [receiver])).run hs =
      .ok (w, AtomPreservation.heapAtomPost hs vs.kept.toList) := by
  obtain ⟨footprint, represented⟩ := inv.observers
  have valueObservedRun := value_observeKept_run ({vs with fuel := vs.fuel - 1}) represented
  have heapObservedRun := heap_observeKept_run ({hs with fuel := hs.fuel - 1}) represented
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have valueAtoms : [receiver].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.list [.record os]] := except_mapM_cons valueAtom rfl
  have heapAtoms : [receiver].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref c] := except_mapM_cons heapAtom rfl
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, valueTicked, AtomPreservation.valueAtomPost,
      AtomPreservation.valueTicked, value_get_run _ i os foundO, valueObservedRun,
      Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, heapTicked, AtomPreservation.heapAtomPost,
      AtomPreservation.heapTicked, heap_get_run {hs with fuel := hs.fuel - 1} i c ws slot foundW,
      heapObservedRun, Except.bind, Except.pure, bind, pure]

/-- A field read (#316): both runtimes read the object's slot and then the
field, and the checker answers the field's abstract. The use is the live path
through the slot, so the relation gives the field's value, its description,
its type and its tags there. -/
theorem get_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {receiver : Atom} {index : Nat} {self : Decl} {type : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.prim (.get index) [receiver]) = .ok type)
    (covered : ∀ use ∈ fieldUses receiver [index], use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim (.get index) [receiver]) after site).run before =
      .ok (result, next)) :
    FlatType type ∧ next.facts.escapes = before.facts.escapes ∧ FlatAbstract type result ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env) (.prim (.get index) [receiver])).run vs =
        .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim (.get index) [receiver])).run hs =
          .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv next.facts.escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧
        Describes gamma' hs'.heap (entryAbstract declarations type result) actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        AllocatedFlatValue hs'.heap actual (entryType type) ∧
        ResultTags (entryType type) (entryAbstract declarations type result) actual ∧
        ChainTags (entryType type) (entryAbstract declarations type result) value ∧
        TagsDeep hs'.heap (entryType type) (entryAbstract declarations type result) actual ∧
        KindsAt hs' env tenv type actual) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env) (.prim (.get index) [receiver])).run vs =
        .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim (.get index) [receiver])).run hs =
          .error actualMessage) := by
  obtain ⟨ts, receiverTyped, found⟩ := exprType_get_success typed
  cases root : atomRoot receiver with
  | none =>
    obtain ⟨n, rfl, bad⟩ := atom_int_of_root_none receiverTyped root
    cases bad
  | some kp =>
  rcases kp with ⟨k, p0⟩
  obtain ⟨tk, declared, at_p0⟩ := atom_fieldType_of_root receiverTyped root
  have p0Fields := fieldTyAt_fields at_p0
  obtain ⟨pair, binding⟩ := lookup_exists_of_same_keys env tenv inv.typeKeys declared
  rcases pair with ⟨o0, w0⟩
  obtain ⟨a0, abstractBinding⟩ := lookup_exists_of_same_keys aenv env inv.abstractKeys.symm binding
  have use : (k, p0 ++ [.element, .field index]) ∈ live := covered _ (by
    unfold fieldUses
    rw [atomUses_of_root root]
    simp)
  have at_p : tyAt tk (p0 ++ [.element, .field index]) = some type := tyAt_object_field at_p0 found
  obtain ⟨o', w', obsPath, valuePath, paired⟩ := inv.bindings k _ use o0 w0 binding
  obtain ⟨os, obsQ, os_i⟩ := projectObs_slot obsPath
  obtain ⟨c, ws, projQ, slot, ws_i⟩ := projectHeap_slot valuePath
  have valueAtom := value_atom_of_root root (valueEnv_lookup binding) obsQ
  have heapAtom := heap_atom_of_root root (heapEnv_lookup binding) projQ
  have shape0 := inv.abstractShapes k tk a0 declared abstractBinding
  have tags0 := inv.tags k tk a0 o0 w0 declared abstractBinding binding
  have abstractReceiver := abstractAtom_of_root root abstractBinding shape0 tags0 projQ at_p0
  have flatObject : FlatType (.object ts) := flatType_tyAt (inv.types k tk declared) (tyAt_of_fieldTyAt at_p0)
  have flatField : FlatType type := by
    cases flatObject with
    | object _ fs => exact fs type (List.mem_of_getElem? found)
  -- the receiver's abstract is an object: its tags say the binding holds a value there
  have tagsQ := resultTags_project tags0 (flatAbstract_entry shape0) (fieldTyAt_entryType at_p0) projQ
  rw [entryAbstract_atPath shape0 (tyAt_of_fieldTyAt at_p0)] at tagsQ
  have abstractAtoms : [receiver].mapM (m := Except String) (abstractAtom aenv) = .ok [a0.atPath p0] :=
    except_mapM_cons abstractReceiver rfl
  obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  rcases flatAbstract_object (flatAbstract_atPath shape0 (tyAt_of_fieldTyAt at_p0)) with bottom |
    ⟨roots, element, certificate, atQ, _, elementShape⟩
  · rw [bottom, entryAbstract_bottom] at tagsQ
    cases tagsQ
  rw [atQ] at run
  rcases flatAbstract_record elementShape with rfl | ⟨fs, rfl, lenF, fieldsF⟩
  · obtain ⟨message, refused⟩ := primitive_get_slot_bottom_run
      {ctx with escaped := union ctx.escaped before.facts.escapes} site index roots certificate
      (union (liveCellsWith ctx.config aenv after) ctx.pinned) before
    rw [refused] at run
    cases run
  obtain ⟨field, fs_i, fieldShape⟩ := flatAbstract_record_field lenF fieldsF found
  rw [primitive_get_run _ _ _ _ _ _ _ _ fs_i] at run
  obtain ⟨first, second⟩ := Prod.mk.inj (Except.ok.inj run)
  have resultEq : result = field := first.symm
  have nextEscapes : next.facts.escapes = before.facts.escapes := by rw [← second]
  -- the field at the live path is the checker's result
  have atField : a0.atPath (p0 ++ [.element, .field index]) = field := by
    rw [atPath_append_fields p0Fields, atQ]
    simp [Abstract.atPath, fs_i]
  refine ⟨flatField, nextEscapes, by rw [resultEq]; exact fieldShape, ?_, ?_⟩
  · intro value vs' run'
    have valueAtoms : [receiver].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
        .ok [.list [.record os]] := except_mapM_cons valueAtom rfl
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run'
      simp [noDepth] at run'
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run'
        simp [noDepth, noFuel] at run'
      · obtain ⟨valueRun, heapRun⟩ :=
          get_runtime_success inv valueAtom heapAtom slot os_i ws_i noDepth noFuel
        rw [valueRun] at run'
        cases run'
        have heapSame := Ownership.FlatFragment.Record.heapAtomPost_heap hs vs.kept.toList
        have described := inv.described k _ use o0 w0 a0 tk type w' binding abstractBinding declared at_p valuePath
        rw [atField] at described
        obtain ⟨t', o'', w'', at_p', obsPath', valuePath', observedField, allocatedField⟩ :=
          inv.bindingsTyped k _ use o0 w0 tk binding declared
        rw [at_p] at at_p'
        cases Option.some.inj at_p'
        rw [obsPath] at obsPath'
        cases Option.some.inj obsPath'
        rw [valuePath] at valuePath'
        cases Option.some.inj valuePath'
        have deepField := inv.deepTags k _ use o0 w0 tk a0 type w' binding declared abstractBinding at_p valuePath
        rw [atField] at deepField
        obtain ⟨tagsField, chainsField⟩ :=
          inv.liveTags k _ use o0 w0 tk a0 type o' w' binding declared abstractBinding at_p obsPath valuePath
        rw [atField] at tagsField chainsField
        refine ⟨w', AtomPreservation.heapAtomPost hs vs.kept.toList, gamma, heapRun, ?_,
          Nat.le_of_eq (congrArg Array.size heapSame.symm), ?_, ?_, observedField, ?_, ?_, ?_,
          by rw [resultEq]; exact chainsField, ?_,
          inv.kindsAt_of heapSame
            (by unfold AtomPreservation.heapAtomPost AtomPreservation.heapTicked; rw [heapObserved_links])
            (fun _ state => kinded_project state (state.env k tk o0 w0 declared binding) at_p valuePath)⟩
        · rw [nextEscapes]; exact AtomPreservation.integer_atom_post_invariant inv
        · rw [heapSame]; exact paired
        · rw [heapSame, resultEq]; exact described
        · rw [heapSame]; exact valueTyped_of_corresponds paired observedField
        · rw [heapSame]; exact allocatedField
        · rw [resultEq]; exact tagsField
        · rw [heapSame, resultEq]; exact deepField
  · intro message failed
    have valueAtoms : [receiver].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
        .ok [.list [.record os]] := except_mapM_cons valueAtom rfl
    have heapAtoms : [receiver].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
        .ok [.ref c] := except_mapM_cons heapAtom rfl
    by_cases noDepth : depth = 0
    · exact ⟨"in-place execution exhausted depth", by
        rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
        simp [noDepth]⟩
    · by_cases noFuel : vs.fuel = 0
      · have heapFuel : hs.fuel = 0 := inv.fuel.symm.trans noFuel
        exact ⟨"in-place execution exhausted fuel", by
          rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
          simp [noDepth, heapFuel]⟩
      · have success := (get_runtime_success inv valueAtom heapAtom slot os_i ws_i noDepth noFuel).1
        rw [success] at failed
        contradiction

/-! ### A live record object -/

/-- A live object atom: both runtimes read it, the heap holds its one slot,
and the slot has every fact of an element (#316). -/
theorem flat_atom_object {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {atom : Atom} {ts : List Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (typed : atomType tenv atom = .ok (.object ts))
    (covered : ∀ use ∈ atomUses atom, use ∈ live) :
    ∃ (c : Nat) (os : List Observation) (ws : List Value) (roots : List Origin) (element : Abstract)
      (certificate : Certificate),
      ValueSemantics.atom (valueEnv env) atom = .ok (.list [.record os]) ∧
      InPlaceSemantics.atom (heapEnv env) atom = .ok (.ref c) ∧
      abstractAtom aenv atom = .ok (.list roots element certificate) ∧
      hs.heap[c]? = some [.record ws] ∧
      Origin.unknown ∉ roots ∧ FlatAbstract (.record ts) element ∧ FlatType (.object ts) ∧
      named gamma roots c ∧
      Corresponds hs.heap (.record os) (.record ws) ∧
      Describes gamma hs.heap (entryAbstract declarations (.record ts) element) (.record ws) ∧
      Describes gamma hs.heap (entryAbstract declarations (.object ts) (.list roots element certificate)) (.ref c) ∧
      obsTyped declarations (.record os) (.record ts) = true ∧
      AllocatedFlatValue hs.heap (.record ws) (entryType (.record ts)) ∧
      ElementTags hs.heap (entryType (.record ts)) (entryAbstract declarations (.record ts) element) (.record ws) := by
  obtain ⟨o, w, a, valueAtom, heapAtom, abstractRun, paired, described, observed, _, flatT, shape,
    allocated, tags, _, deep⟩ := flat_atom_entry inv typed covered
  rcases flatAbstract_object shape with rfl | ⟨roots, element, certificate, rfl, noUnk, elementShape⟩
  · rw [entryAbstract_bottom] at tags
    cases tags
  cases allocated with
  | object c slot _ lookup slotShape =>
    obtain ⟨o1, rfl, observed1⟩ := obsTyped_object_slot observed
    cases slotShape with
    | record ws _ lenW fieldsW =>
      cases o1 with
      | record os =>
        obtain ⟨os', same, _, pointwise⟩ := corresponds_list_elements lookup paired
        cases same
        have pairedSlot := pointwise 0 (.record os) (.record ws) rfl rfl
        have describedList : Describes gamma hs.heap (.list roots (entryAbstract declarations (.record ts) element)
            certificate) (.ref c) := described
        have rootNamed : named gamma roots c := by
          have names := described.1.1 [] c (.here _)
          simp only [entryAbstract] at names
          rw [list_root_names] at names
          exact named_union_nil names
        have deepList : TagsDeep hs.heap (.object (entryTypes ts))
            (.list roots (entryAbstract declarations (.record ts) element) certificate) (.ref c) := deep
        cases deepList with
        | object _ slotList _ _ _ _ lookup' results chainsSlot deepSlot =>
          rw [lookup] at lookup'
          cases lookup'
          exact ⟨c, os, ws, roots, element, certificate, valueAtom, heapAtom, abstractRun, lookup, noUnk,
            elementShape, flatT, rootNamed, pairedSlot,
            describes_element noUnk lookup (by simp) describedList, described, observed1,
            .record ws _ lenW fieldsW,
            ⟨results _ (by simp), chainsSlot _ (by simp), deepSlot _ (by simp)⟩⟩
      | int _ => simp [obsTyped] at observed1
      | list _ => simp [obsTyped] at observed1
      | closure _ _ => simp [obsTyped] at observed1

/-! ### `Record.copy` -/

theorem value_recordCopy_run (s : ValueSemantics.State) (os : List Observation) :
    (ValueSemantics.prim .recordCopy [.list [.record os]]).run s = .ok (.list [.record os], s) := rfl

theorem heap_recordCopy_run (hs : State) (c : Nat) (ys : List Value) (lookup : hs.heap[c]? = some ys) :
    (prim .recordCopy [.ref c]).run (heapTicked hs) = .ok (.ref hs.heap.size, heapAllocatedValues hs ys) := by
  simp [prim, array, alloc, lookup, heapTicked, heapAllocatedValues, Option.toExcept, StateT.run,
    StateT.bind, StateT.map, StateT.get, StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure,
    bind, pure, get, getThe, set, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift]

theorem recordCopy_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {receiver : Atom} {os : List Observation} {ys : List Value} {c : Nat} {depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueReceiver : ValueSemantics.atom (valueEnv env) receiver = .ok (.list [.record os]))
    (heapReceiver : InPlaceSemantics.atom (heapEnv env) receiver = .ok (.ref c))
    (lookup : hs.heap[c]? = some ys)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim .recordCopy [receiver])).run vs =
      .ok (.list [.record os], valueObserved (valueTicked vs)) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim .recordCopy [receiver])).run hs =
      .ok (.ref hs.heap.size, heapObserved (heapAllocatedValues hs ys) vs.kept.toList) := by
  obtain ⟨footprint, represented⟩ := inv.observers
  have valueObservedRun := value_observeKept_run (valueTicked vs) represented
  have heapObservedRun := heap_observeKept_run (heapAllocatedValues hs ys)
    (representsMany_after_alloc (xs := ys) represented)
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have valueAtoms : [receiver].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.list [.record os]] := except_mapM_cons valueReceiver rfl
  have heapAtoms : [receiver].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref c] := except_mapM_cons heapReceiver rfl
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, value_recordCopy_run, valueObservedRun, Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, heap_recordCopy_run hs c ys lookup, heapObservedRun,
      Except.bind, Except.pure, bind, pure]

/-- `Record.copy` (#316): a fresh one-slot array that holds the same record,
named by the site; the checker proves no certificate for it, as for a list copy. -/
theorem recordCopy_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {receiver : Atom} {type : Ty} {self : Decl} {ctx : Context} {after : Live} {site : List Nat} {before next : St} {result : Abstract} {inferenceFuel depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.prim .recordCopy [receiver]) = .ok type)
    (covered : ∀ use ∈ atomUses receiver, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim .recordCopy [receiver]) after site).run before =
      .ok (result, next)) :
    FlatType type ∧ next.facts.escapes = before.facts.escapes ∧ FlatAbstract type result ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .recordCopy [receiver])).run vs = .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .recordCopy [receiver])).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv next.facts.escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧
        Describes gamma' hs'.heap (entryAbstract declarations type result) actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        AllocatedFlatValue hs'.heap actual (entryType type) ∧
        ResultTags (entryType type) (entryAbstract declarations type result) actual ∧
        ChainTags (entryType type) (entryAbstract declarations type result) value ∧
        TagsDeep hs'.heap (entryType type) (entryAbstract declarations type result) actual ∧
        KindsAt hs' env tenv type actual) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .recordCopy [receiver])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .recordCopy [receiver])).run hs = .error actualMessage) := by
  obtain ⟨ts, receiverTyped, rfl⟩ := exprType_recordCopy_success typed
  obtain ⟨c, os, ws, roots, element, certificate, valueReceiver, heapReceiver, abstractReceiver, lookup, noUnk,
    elementShape, flatObject, _, pairedSlot, describedSlot, _, observedSlot, allocatedSlot, slotTags⟩ :=
    flat_atom_object inv receiverTyped covered
  have abstractAtoms : [receiver].mapM (m := Except String) (abstractAtom aenv) =
      .ok [.list roots element certificate] := except_mapM_cons abstractReceiver rfl
  obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  rw [primitive_recordCopy_run] at run
  obtain ⟨first, second⟩ := Prod.mk.inj (Except.ok.inj run)
  have resultEq : result = .list [.site site 0] element false := first.symm
  have resultRep : entryAbstract declarations (.object ts) result =
      .list [.site site 0] (entryAbstract declarations (.record ts) element) false := by
    rw [resultEq]; rfl
  have nextEscapes : next.facts.escapes = before.facts.escapes := by rw [← second]
  have valueAtoms : [receiver].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.list [.record os]] := except_mapM_cons valueReceiver rfl
  have heapAtoms : [receiver].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref c] := except_mapM_cons heapReceiver rfl
  refine ⟨flatObject, nextEscapes, by rw [resultEq]; exact .object _ _ _ _ (by simp) elementShape, ?_, ?_⟩
  · intro value vs' run'
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run'
      simp [noDepth] at run'
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run'
        simp [noDepth, noFuel] at run'
      · obtain ⟨valueRun, heapRun⟩ :=
          recordCopy_runtime_success inv valueReceiver heapReceiver lookup noDepth noFuel
        rw [valueRun] at run'
        cases run'
        have heapEq : (heapObserved (heapAllocatedValues hs [.record ws]) vs.kept.toList).heap =
            hs.heap.push [.record ws] := by
          rw [heapObserved_heap]; rfl
        have agree : ∀ d, Reaches hs.heap (.record ws) (.ref d) → (hs.heap.push [.record ws])[d]? = hs.heap[d]? := by
          intro d reach
          have bound := allocated_reach_bound allocatedSlot reach
          simp [Array.getElem?_push, Nat.ne_of_lt bound]
        obtain ⟨kinds', state', newTyped⟩ := alloc_kinds_of inv (t := .object ts) heapEq
          (by rw [heapObserved_links]; rfl) (fun kinds state => by
            obtain ⟨c', same, rootTyped⟩ :=
              kinded_object_inv (kinded_atom inv state receiverTyped covered heapReceiver)
            cases same
            obtain ⟨x, slot, typedX⟩ := state.object_slot rootTyped
            rw [lookup] at slot
            cases slot
            exact .object ts _ typedX)
        obtain ⟨gamma', postInvariant, fresh, old⟩ := alloc_post_invariant inv [.record ws] site heapEq
          (by rw [heapObserved_links]; rfl)
          (by rw [heapObserved_kept]; rfl)
          (by rw [valueObserved_kept]; rfl) (by rw [valueObserved_reads, heapObserved_reads]; exact inv.reads)
          (observed_external (valueTicked vs) (heapAllocatedValues hs [.record ws]) inv.keptSize inv.external)
          (by rw [valueObserved_fuel, heapObserved_fuel]; simp [valueTicked, heapAllocatedValues, inv.fuel])
          ⟨kinds', state'⟩
        have lookupNew : (hs.heap.push [.record ws])[hs.heap.size]? = some [.record ws] := by simp
        have shapedNew : AllocatedFlatValue (hs.heap.push [.record ws]) (.ref hs.heap.size)
            (entryType (.object ts)) :=
          .object _ (.record ws) (entryTypes ts) lookupNew (allocated_of_agree allocatedSlot agree)
        have rootNamed : named gamma' [.site site 0] hs.heap.size := ⟨.site site 0, by simp, fresh⟩
        have pairedNew : Corresponds (hs.heap.push [.record ws]) (.list [.record os]) (.ref hs.heap.size) :=
          corresponds_list_of_elements lookupNew rfl (fun i o w os_i ws_i => by
            cases i with
            | zero =>
              simp only [List.getElem?_cons_zero, Option.some.injEq] at os_i ws_i
              subst os_i; subst ws_i
              exact corresponds_of_agree agree pairedSlot
            | succ i => simp at os_i)
        have observedNew : obsTyped declarations (.list [.record os]) (.object ts) = true :=
          obsTyped_object_of_slot observedSlot
        have tagsNew := elementTags_of_agree slotTags agree
        refine ⟨.ref hs.heap.size, heapObserved (heapAllocatedValues hs [.record ws]) vs.kept.toList, gamma',
          heapRun, by rw [nextEscapes]; exact postInvariant, by rw [heapEq]; simp, ?_, ?_, observedNew, ?_,
          by rw [heapEq]; exact shapedNew, by rw [resultRep]; exact .object _ _ _ _ _, .object _ _ _, ?_,
          ⟨kinds', state', .object ts _ newTyped⟩⟩
        · rw [heapEq]; exact pairedNew
        · rw [heapEq, resultRep]
          refine list_described_of_elements rootNamed (by simp) lookupNew shapedNew ?_
            (fun h => by simp at h) (fun h => by simp at h)
          intro y member
          simp only [List.mem_singleton] at member
          subst member
          exact describes_of_agree agree (describes_naming_same allocatedSlot old
            (fun d reach => allocated_reach_bound allocatedSlot reach) describedSlot)
        · rw [heapEq]; exact valueTyped_of_corresponds pairedNew observedNew
        · rw [heapEq, resultRep]
          exact .object _ [.record ws] (entryTypes ts) _ _ _ lookupNew
            (fun w member => by
              simp only [List.mem_singleton] at member
              subst member
              exact tagsNew.1)
            (fun w member => by
              simp only [List.mem_singleton] at member
              subst member
              exact tagsNew.2.1)
            (fun w member => by
              simp only [List.mem_singleton] at member
              subst member
              exact tagsNew.2.2)
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
      · have success := (recordCopy_runtime_success inv valueReceiver heapReceiver lookup noDepth noFuel).1
        rw [success] at failed
        contradiction

end Ownership.FlatFragment.Objects
