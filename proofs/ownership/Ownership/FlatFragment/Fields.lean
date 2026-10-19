import Ownership.FlatFragment.Reach

/-! The flat fragment: records and field paths. The typed shape of a flat
value with records, its projections, records in correspondence, typing and
description, the frame of a flat value under a heap change, the cells at a
path, and the atom lemmas by root and path. -/

/-! shapes with records.
A flat value is an integer, an allocated integer array, or a record of flat
values; the lemmas below follow the value's structure. The frame lemmas
replace the integer-or-array case split of the first fragment. No theorem
below uses a pinned soundness obligation. -/

namespace Ownership.FlatFragment.Fields

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.Support Ownership.FlatFragment.State
open Ownership.FlatFragment.CheckerExtraction Ownership.FlatFragment.RepresentsDepth
open Ownership.FlatFragment.Observe Ownership.FlatFragment.HeapPreservation
open Ownership.FlatFragment.Description Ownership.FlatFragment.NamingFacts
open Ownership.FlatFragment.AtomPreservation Ownership.FlatFragment.LiveCells
open Ownership.FlatFragment.IntegerCorrespondence Ownership.FlatFragment.Runtime

local instance stepReflBEq : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance stepLawfulBEq : LawfulBEq Step := LawfulBEq.mk (by deriving_LawfulEq_tactic)
local instance originReflBEq : ReflBEq Origin := ⟨by deriving_ReflEq_tactic⟩
local instance originLawfulBEq : LawfulBEq Origin := LawfulBEq.mk (by deriving_LawfulEq_tactic)

/-! ### Projections of typed values -/

theorem allocated_project {heap : Heap} {w w' : Value} {tk : Ty} {p : Path}
    (shape : AllocatedFlatValue heap w tk) (projected : projectVal w p = some w') :
    ∃ t, tyAt tk p = some t ∧ AllocatedFlatValue heap w' t := by
  induction p generalizing w tk with
  | nil =>
    simp [projectVal] at projected
    subst projected
    exact ⟨tk, rfl, shape⟩
  | cons step rest ih =>
    cases step <;> cases w <;> simp [projectVal] at projected
    rename_i i' ws
    cases h : ws[i']? with
    | none => simp [h] at projected
    | some x =>
      simp [h] at projected
      cases shape with
      | record _ ts len fields =>
        obtain ⟨t', ts_i⟩ := index_of_same_length len h
        obtain ⟨t, at_rest, shape'⟩ := ih (fields i' x t' h ts_i) projected
        exact ⟨t, by simp [tyAt, ts_i, at_rest], shape'⟩

theorem projectVal_of_tyAt {heap : Heap} {w : Value} {tk t : Ty} {p : Path}
    (shape : AllocatedFlatValue heap w tk) (at_p : tyAt tk p = some t) :
    ∃ w', projectVal w p = some w' ∧ AllocatedFlatValue heap w' t := by
  induction p generalizing w tk with
  | nil =>
    simp [tyAt] at at_p
    subst at_p
    exact ⟨w, rfl, shape⟩
  | cons step rest ih =>
    cases step <;> cases tk <;> simp [tyAt] at at_p
    rename_i i' ts
    cases h : ts[i']? with
    | none => simp [h] at at_p
    | some t' =>
      simp [h] at at_p
      cases shape with
      | record ws _ len fields =>
        obtain ⟨x, ws_i⟩ := index_of_same_length len.symm h
        obtain ⟨w', projected, shape'⟩ := ih (fields i' x t' ws_i h) at_p
        exact ⟨w', by simp [projectVal, ws_i, projected], shape'⟩

/-! ### Representations from snapshots -/

theorem representsMany_of_snapshots {heap : Heap} {n : Nat} (ws : List Value) (os : List Observation)
    (pointwise : ∀ w ∈ ws, ∀ o, snapshot heap n w = .ok o → ∃ cs, Represents heap n w o cs)
    (run : ws.mapM (snapshot heap n) = .ok os) :
    ∃ cs, RepresentsMany heap n ws os cs := by
  induction ws generalizing os with
  | nil =>
    have := except_mapM_nil_success run
    subst this
    exact ⟨[], .nil⟩
  | cons w ws ih =>
    obtain ⟨o, rest, headRun, tailRun, rfl⟩ := except_mapM_cons_success run
    obtain ⟨cs, first⟩ := pointwise w (by simp) o headRun
    obtain ⟨ds, more⟩ := ih rest (fun w' member o' h => pointwise w' (by simp [member]) o' h) tailRun
    exact ⟨cs ++ ds, .cons first more⟩

theorem represents_of_snapshot {heap : Heap} :
    ∀ (n : Nat) (w : Value) (o : Observation), snapshot heap n w = .ok o →
      ∃ cs, Represents heap n w o cs := by
  intro n
  induction n with
  | zero => intro w o h; simp [snapshot] at h
  | succ n ih =>
    intro w o h
    cases w with
    | int i =>
      simp only [snapshot] at h
      change Except.ok (Observation.int i) = Except.ok o at h
      cases Except.ok.inj h
      exact ⟨[], .int⟩
    | record ws =>
      simp only [snapshot] at h
      obtain ⟨os, run, returned⟩ := except_bind_success h
      change Except.ok (Observation.record os) = Except.ok o at returned
      cases Except.ok.inj returned
      obtain ⟨cs, many⟩ := representsMany_of_snapshots ws os (fun w _ o h => ih w o h) run
      exact ⟨cs, .record many⟩
    | closure d caps =>
      simp only [snapshot] at h
      obtain ⟨os, run, returned⟩ := except_bind_success h
      change Except.ok (Observation.closure d os) = Except.ok o at returned
      cases Except.ok.inj returned
      obtain ⟨cs, many⟩ := representsMany_of_snapshots caps os (fun w _ o h => ih w o h) run
      exact ⟨cs, .closure many⟩
    | ref c =>
      simp only [snapshot] at h
      cases lookup : heap[c]? with
      | none => simp [lookup, Option.toExcept, Bind.bind, Except.bind] at h
      | some xs =>
        simp only [lookup, Option.toExcept, except_ok_bind] at h
        obtain ⟨os, run, returned⟩ := except_bind_success h
        change Except.ok (Observation.list os) = Except.ok o at returned
        cases Except.ok.inj returned
        obtain ⟨cs, many⟩ := representsMany_of_snapshots xs os (fun w _ o h => ih w o h) run
        exact ⟨c :: cs, .ref lookup many⟩

/-! ### Records in correspondence -/

theorem corresponds_record_fields {heap : Heap} {o : Observation} {ws : List Value}
    (paired : Corresponds heap o (.record ws)) :
    ∃ os, o = .record os ∧ os.length = ws.length ∧
      ∀ (i : Nat) (o' : Observation) (w' : Value), os[i]? = some o' → ws[i]? = some w' →
        Corresponds heap o' w' := by
  have observed := paired o.depth (Nat.le_refl _)
  cases depth : o.depth with
  | zero => rw [depth] at observed; simp [snapshot] at observed
  | succ d =>
    rw [depth] at observed
    obtain ⟨cs, rep⟩ := represents_of_snapshot (d + 1) (.record ws) o observed
    cases rep with
    | record children =>
      refine ⟨_, rfl, (representsMany_length children).symm, ?_⟩
      intro i o' w' os_i ws_i
      obtain ⟨cells, witness⟩ := representsMany_index _ children ws_i os_i
      exact corresponds_of_represents witness

theorem representsMany_of_pointwise {heap : Heap} {n : Nat} {ws : List Value} {os : List Observation}
    (len : ws.length = os.length)
    (fields : ∀ (i : Nat) (w : Value) (o : Observation), ws[i]? = some w → os[i]? = some o →
      ∃ cs, Represents heap n w o cs) :
    ∃ cs, RepresentsMany heap n ws os cs := by
  induction ws generalizing os with
  | nil =>
    cases os with
    | nil => exact ⟨[], .nil⟩
    | cons _ _ => simp at len
  | cons w ws ih =>
    cases os with
    | nil => simp at len
    | cons o os =>
      obtain ⟨cs, first⟩ := fields 0 w o rfl rfl
      obtain ⟨ds, more⟩ := ih (by simpa using len)
        (fun i w' o' at_w at_o => fields (i + 1) w' o' (by simpa using at_w) (by simpa using at_o))
      exact ⟨cs ++ ds, .cons first more⟩

theorem corresponds_record_of_fields {heap : Heap} {os : List Observation} {ws : List Value}
    (len : os.length = ws.length)
    (fields : ∀ (i : Nat) (o : Observation) (w : Value), os[i]? = some o → ws[i]? = some w →
      Corresponds heap o w) :
    Corresponds heap (.record os) (.record ws) := by
  intro n enough
  rw [Observation.depth] at enough
  cases n with
  | zero => omega
  | succ m =>
    have children := container_children_depth os m enough
    obtain ⟨cs, many⟩ := representsMany_of_pointwise len.symm (fun i w o ws_i os_i =>
      represents_of_snapshot m w o
        (fields i o w os_i ws_i m (children o (List.mem_of_getElem? os_i))))
    exact snapshot_of_represents (.record many)

theorem corresponds_project {heap : Heap} {o o' : Observation} {w w' : Value} {p : Path}
    (paired : Corresponds heap o w) (valuePath : projectVal w p = some w')
    (obsPath : projectObs o p = some o') : Corresponds heap o' w' := by
  induction p generalizing o w with
  | nil =>
    simp [projectVal] at valuePath
    simp [projectObs] at obsPath
    subst valuePath; subst obsPath
    exact paired
  | cons step rest ih =>
    cases step <;> cases w <;> simp [projectVal] at valuePath
    rename_i i' ws
    cases h : ws[i']? with
    | none => simp [h] at valuePath
    | some x =>
      simp [h] at valuePath
      obtain ⟨os, rfl, len, fields⟩ := corresponds_record_fields paired
      simp [projectObs] at obsPath
      cases h' : os[i']? with
      | none => simp [h'] at obsPath
      | some y =>
        simp [h'] at obsPath
        exact ih (fields i' y x h' h) valuePath obsPath

/-! ### Records in typing -/

theorem obsTyped_record_fields {ds : List Decl} {os : List Observation} {ts : List Ty}
    (typed : obsTyped ds (.record os) (.record ts) = true) :
    os.length = ts.length ∧
      ∀ (i : Nat) (o : Observation) (t : Ty), os[i]? = some o → ts[i]? = some t →
        obsTyped ds o t = true := by
  rw [obsTyped] at typed
  simp only [Bool.and_eq_true, beq_iff_eq, List.all_eq_true] at typed
  obtain ⟨len, all⟩ := typed
  refine ⟨len, fun i o t os_i ts_i => ?_⟩
  have mem : (⟨o, List.mem_of_getElem? os_i⟩, t) ∈ os.attach.zip ts := by
    apply List.mem_of_getElem? (i := i)
    rw [List.getElem?_zip_eq_some]
    exact ⟨by simp [List.getElem?_attach, os_i], ts_i⟩
  exact all _ mem

theorem obsTyped_record_of_fields {ds : List Decl} {os : List Observation} {ts : List Ty}
    (len : os.length = ts.length)
    (fields : ∀ (i : Nat) (o : Observation) (t : Ty), os[i]? = some o → ts[i]? = some t →
      obsTyped ds o t = true) :
    obsTyped ds (.record os) (.record ts) = true := by
  rw [obsTyped]
  simp only [Bool.and_eq_true, beq_iff_eq, List.all_eq_true]
  refine ⟨len, fun x mem => ?_⟩
  obtain ⟨i, at_i⟩ := List.mem_iff_getElem?.mp mem
  rw [List.getElem?_zip_eq_some] at at_i
  obtain ⟨attach_i, ts_i⟩ := at_i
  rw [List.getElem?_attach] at attach_i
  cases h : os[i]? with
  | none => simp [h] at attach_i
  | some o =>
    simp [h] at attach_i
    rcases x with ⟨⟨o', _⟩, t⟩
    simp only at attach_i ts_i
    cases attach_i
    exact fields i _ _ h ts_i

theorem valueTyped_record_fields {ds : List Decl} {heap : Heap} {ws : List Value} {ts : List Ty}
    (typed : ValueTyped ds heap (.record ws) (.record ts)) :
    ws.length = ts.length ∧
      ∀ (i : Nat) (w : Value) (t : Ty), ws[i]? = some w → ts[i]? = some t →
        ValueTyped ds heap w t := by
  obtain ⟨n, o, fp, rep, obsT⟩ := typed
  cases n with
  | zero => cases rep
  | succ n =>
    cases rep with
    | record children =>
      obtain ⟨len, fields⟩ := obsTyped_record_fields obsT
      have lenWO := representsMany_length children
      refine ⟨lenWO.trans len, ?_⟩
      intro i w t ws_i ts_i
      obtain ⟨o', os_i⟩ := index_of_same_length lenWO ws_i
      obtain ⟨cs, witness⟩ := representsMany_index _ children ws_i os_i
      exact ⟨n, o', cs, witness, fields i o' t os_i ts_i⟩

theorem representsMany_typed_of_fields {ds : List Decl} {heap : Heap} :
    ∀ (ws : List Value) (ts : List Ty), ws.length = ts.length →
      (∀ (i : Nat) (w : Value) (t : Ty), ws[i]? = some w → ts[i]? = some t →
        ValueTyped ds heap w t) →
      ∃ os cs n, RepresentsMany heap n ws os cs ∧ os.length = ts.length ∧
        ∀ (i : Nat) (o : Observation) (t : Ty), os[i]? = some o → ts[i]? = some t →
          obsTyped ds o t = true := by
  intro ws
  induction ws with
  | nil =>
    intro ts len _
    cases ts with
    | nil => exact ⟨[], [], 0, .nil, rfl, fun i o t h => by simp at h⟩
    | cons _ _ => simp at len
  | cons w ws ih =>
    intro ts len fields
    cases ts with
    | nil => simp at len
    | cons t ts =>
      obtain ⟨n0, o0, cs0, rep0, typed0⟩ := fields 0 w t rfl rfl
      obtain ⟨os, cs, n, many, lenO, typedMany⟩ := ih ts (by simpa using len)
        (fun i w' t' at_w at_t => fields (i + 1) w' t' (by simpa using at_w) (by simpa using at_t))
      refine ⟨o0 :: os, cs0 ++ cs, max n0 n, ?_, by simp [lenO], ?_⟩
      · refine .cons (represents_of_depth rep0 ?_) (representsMany_of_depth many ?_)
        · exact Nat.le_trans (represents_depth_bound rep0) (Nat.le_max_left _ _)
        · intro o member
          exact Nat.le_trans (representsMany_depth_bound many o member) (Nat.le_max_right _ _)
      · intro i o t' os_i ts_i
        cases i with
        | zero =>
          simp at os_i ts_i
          subst os_i; subst ts_i
          exact typed0
        | succ i => exact typedMany i o t' (by simpa using os_i) (by simpa using ts_i)

theorem valueTyped_record_of_fields {ds : List Decl} {heap : Heap} {ws : List Value} {ts : List Ty}
    (len : ws.length = ts.length)
    (fields : ∀ (i : Nat) (w : Value) (t : Ty), ws[i]? = some w → ts[i]? = some t →
      ValueTyped ds heap w t) :
    ValueTyped ds heap (.record ws) (.record ts) := by
  obtain ⟨os, cs, n, many, lenO, typedMany⟩ := representsMany_typed_of_fields ws ts len fields
  exact ⟨n + 1, .record os, cs, .record many, obsTyped_record_of_fields lenO typedMany⟩

/-- The shape of a typed flat value: the generalization of `allocated_shape_of_typed`. -/
theorem allocated_of_typed {ds : List Decl} {heap : Heap} {w : Value} {ty : Ty}
    (flat : FlatType ty) (typed : ValueTyped ds heap w ty) : AllocatedFlatValue heap w ty := by
  induction flat generalizing w with
  | int =>
    obtain ⟨depth, observation, footprint, represented, observedType⟩ := typed
    cases represented with
    | int => exact .int _
    | record _ => simp [obsTyped] at observedType
    | closure _ => simp [obsTyped] at observedType
    | ref _ _ => simp [obsTyped] at observedType
  | listInt =>
    obtain ⟨depth, observation, footprint, represented, observedType⟩ := typed
    cases represented with
    | int => simp [obsTyped] at observedType
    | record _ => simp [obsTyped] at observedType
    | closure _ => simp [obsTyped] at observedType
    | ref allocated _ => exact .list _ (Array.getElem?_eq_some_iff.mp allocated).1
  | record ts _ ih =>
    obtain ⟨depth, observation, footprint, represented, observedType⟩ := typed
    cases represented with
    | int => simp [obsTyped] at observedType
    | closure _ => simp [obsTyped] at observedType
    | ref _ _ => simp [obsTyped] at observedType
    | @record _ ws os cs children =>
      obtain ⟨len, fields⟩ :=
        valueTyped_record_fields (ds := ds) ⟨_, _, _, Represents.record children, observedType⟩
      exact .record ws ts len (fun i w t ws_i ts_i =>
        ih t (List.mem_of_getElem? ts_i) (fields i w t ws_i ts_i))

theorem allocated_mono {heap next : Heap} {w : Value} {ty : Ty}
    (shape : AllocatedFlatValue heap w ty) (size : heap.size ≤ next.size) : AllocatedFlatValue next w ty := by
  induction shape with
  | int integer => exact .int integer
  | list root allocated => exact .list root (Nat.lt_of_lt_of_le allocated size)
  | record ws ts len _ ih => exact .record ws ts len (fun i w t ws_i ts_i => ih i w t ws_i ts_i)

/-- Every flat value of a flat heap is typed: the generalization of `valueTyped_after_flat_heap`. -/
theorem valueTyped_of_allocated {ds : List Decl} {heap : Heap} {w : Value} {ty : Ty}
    (shape : AllocatedFlatValue heap w ty) (flat : FlatHeap heap) : ValueTyped ds heap w ty := by
  induction shape with
  | int integer => exact ⟨1, .int integer, [], .int, by simp [obsTyped]⟩
  | list root allocated =>
    have lookup : heap[root]? = some heap[root] := by simp [allocated]
    obtain ⟨integers, payload⟩ := integers_of_flat_values heap[root] (flat root _ lookup)
    rw [payload] at lookup
    exact allocated_integer_list_typed ds lookup
  | record ws ts len _ ih =>
    exact valueTyped_record_of_fields len (fun i w t ws_i ts_i => ih i w t ws_i ts_i)

theorem projectObs_of_tyAt {ds : List Decl} {o : Observation} {tk t : Ty} {p : Path}
    (typed : obsTyped ds o tk = true) (at_p : tyAt tk p = some t) :
    ∃ o', projectObs o p = some o' ∧ obsTyped ds o' t = true := by
  induction p generalizing o tk with
  | nil =>
    simp [tyAt] at at_p
    subst at_p
    exact ⟨o, rfl, typed⟩
  | cons step rest ih =>
    cases step <;> cases tk <;> simp [tyAt] at at_p
    rename_i i' ts
    cases h : ts[i']? with
    | none => simp [h] at at_p
    | some t' =>
      simp [h] at at_p
      cases o with
      | int _ => simp [obsTyped] at typed
      | list _ => simp [obsTyped] at typed
      | closure _ _ => simp [obsTyped] at typed
      | record os =>
        obtain ⟨len, fields⟩ := obsTyped_record_fields typed
        obtain ⟨o1, os_i⟩ := index_of_same_length len.symm h
        obtain ⟨o', projected, typed'⟩ := ih (fields i' o1 t' os_i h) at_p
        exact ⟨o', by simp [projectObs, os_i, projected], typed'⟩

theorem projectObs_typed {ds : List Decl} {o o' : Observation} {tk t : Ty} {p : Path}
    (typed : obsTyped ds o tk = true) (at_p : tyAt tk p = some t)
    (projected : projectObs o p = some o') : obsTyped ds o' t = true := by
  obtain ⟨o'', projected', typed'⟩ := projectObs_of_tyAt typed at_p
  rw [projected] at projected'
  cases Option.some.inj projected'
  exact typed'

/-! ### Records in description -/

theorem covers_field {gamma : Naming} {heap : Heap} {as : List Abstract} {ws : List Value} {i : Nat}
    {a' : Abstract} {w' : Value}
    (covers : Covers gamma heap (.record as) (.record ws))
    (as_i : as[i]? = some a') (ws_i : ws[i]? = some w') : Covers gamma heap a' w' := by
  intro q c located
  have := covers (.field i :: q) c (.field ws_i located)
  simpa [namesAt, as_i] using this

theorem certified_field {heap : Heap} {as : List Abstract} {ws : List Value} {i : Nat}
    {a' : Abstract} {w' : Value}
    (cert : CertifiedExclusive heap (.record as) (.record ws))
    (as_i : as[i]? = some a') (ws_i : ws[i]? = some w') : CertifiedExclusive heap a' w' := by
  intro q cs e ex w'' shape located n o fp rep
  have shape' : (Abstract.record as).atPath (.field i :: q) = .list cs e ex := by
    simpa [Abstract.atPath, as_i] using shape
  exact cert (.field i :: q) cs e ex w'' shape' (.field ws_i located) n o fp rep

theorem closures_field {gamma : Naming} {heap : Heap} {as : List Abstract} {ws : List Value} {i : Nat}
    {a' : Abstract} {w' : Value}
    (agree : ClosureAgreement gamma heap (.record as) (.record ws))
    (as_i : as[i]? = some a') (ws_i : ws[i]? = some w') : ClosureAgreement gamma heap a' w' := by
  cases agree with
  | record fields => simpa [Abstract.atPath, as_i] using fields i w' ws_i

theorem describes_field {gamma : Naming} {heap : Heap} {as : List Abstract} {ws : List Value} {i : Nat}
    {a' : Abstract} {w' : Value}
    (described : Describes gamma heap (.record as) (.record ws))
    (as_i : as[i]? = some a') (ws_i : ws[i]? = some w') : Describes gamma heap a' w' :=
  ⟨⟨covers_field described.1.1 as_i ws_i, certified_field described.1.2 as_i ws_i⟩,
    closures_field described.2 as_i ws_i⟩

theorem describes_project {gamma : Naming} {heap : Heap} {tk t : Ty} {a : Abstract} {w w' : Value}
    {p : Path}
    (shape : FlatAbstract tk a) (at_p : tyAt tk p = some t) (described : Describes gamma heap a w)
    (projected : projectVal w p = some w') : Describes gamma heap (a.atPath p) w' := by
  induction p generalizing tk a w with
  | nil =>
    simp [projectVal] at projected
    subst projected
    simpa [Abstract.atPath] using described
  | cons step rest ih =>
    cases step <;> cases tk <;> simp [tyAt] at at_p
    rename_i i' ts
    cases h : ts[i']? with
    | none => simp [h] at at_p
    | some t' =>
      simp [h] at at_p
      obtain ⟨as, rfl, len, fields⟩ := flatAbstract_record shape
      obtain ⟨a', as_i, shape'⟩ := flatAbstract_record_field len fields h
      cases w <;> simp [projectVal] at projected
      rename_i ws
      cases h' : ws[i']? with
      | none => simp [h'] at projected
      | some w1 =>
        simp [h'] at projected
        simp only [Abstract.atPath, as_i, Option.getD_some]
        exact ih shape' at_p (describes_field described as_i h') projected

theorem describes_record_of_fields {gamma : Naming} {heap : Heap} {as : List Abstract} {ws : List Value}
    (len : as.length = ws.length)
    (fields : ∀ (i : Nat) (a : Abstract) (w : Value), as[i]? = some a → ws[i]? = some w →
      Describes gamma heap a w) :
    Describes gamma heap (.record as) (.record ws) := by
  refine ⟨⟨?_, ?_⟩, ?_⟩
  · intro q c located
    cases located with
    | @field _ i w' q' _ ws_i inner =>
      obtain ⟨a, as_i⟩ := index_of_same_length len.symm ws_i
      have := (fields i a w' as_i ws_i).1.1 q' c inner
      simpa [namesAt, as_i] using this
  · intro q cs e ex w'' shape located n o fp rep
    cases q with
    | nil => simp [Abstract.atPath] at shape
    | cons step q' =>
      cases step with
      | field i =>
        cases located with
        | field ws_i inner =>
          cases h : as[i]? with
          | none =>
            simp only [Abstract.atPath, h, Option.getD_none] at shape
            cases q' with
            | nil => simp [Abstract.atPath] at shape
            | cons s _ => cases s <;> simp [Abstract.atPath] at shape
          | some a =>
            simp only [Abstract.atPath, h, Option.getD_some] at shape
            exact (fields i a _ h ws_i).1.2 q' cs e ex w'' shape inner n o fp rep
      | element => simp [Abstract.atPath] at shape
      | capture _ => simp [Abstract.atPath] at shape
      | env => simp [Abstract.atPath] at shape
  · apply ClosureAgreement.record
    intro i x ws_i
    obtain ⟨a, as_i⟩ := index_of_same_length len.symm ws_i
    simpa [Abstract.atPath, as_i] using (fields i a x as_i ws_i).2

/-! ### Frames of an integer and of a flat array (moved from `Frame`) -/

theorem observation_depth_pos (observation : Observation) : 0 < observation.depth := by
  cases observation <;> simp [Observation.depth] <;> omega

/-- Correspondence of an integer does not depend on the heap. -/
theorem corresponds_int_frame {heap : Heap} {next : Heap} {o : Observation} (paired : Corresponds heap o (.int integer)) :
    Corresponds next o (.int integer) := by
  have observed := paired o.depth (Nat.le_refl _)
  obtain ⟨depth, depthEq⟩ : ∃ depth, o.depth = depth + 1 :=
    ⟨o.depth - 1, by have := observation_depth_pos o; omega⟩
  rw [depthEq] at observed
  simp [snapshot, pure, Except.pure] at observed
  subst observed
  exact integer_corresponds integer

/-- Correspondence of a flat array survives any heap change that keeps its
own cell. -/
theorem corresponds_ref_frame {heap : Heap} {next : Heap} {o : Observation} (flat : FlatHeap heap) (allocated : root < heap.size)
    (paired : Corresponds heap o (.ref root)) (same : next[root]? = heap[root]?) :
    Corresponds next o (.ref root) := by
  have lookupRoot : heap[root]? = some heap[root] := by simp [allocated]
  obtain ⟨integers, payload⟩ := integers_of_flat_values heap[root] (flat root _ lookupRoot)
  rw [payload] at lookupRoot
  have observed := observation_of_integer_ref lookupRoot paired
  subst observed
  exact corresponds_integer_ref (by rw [same]; exact lookupRoot)

theorem named_same_of_naming {gamma : Naming} {gamma' : Naming}
    (namingSame : ∀ origin cell, cell < bound → (cell ∈ gamma' origin ↔ cell ∈ gamma origin))
    (old : root < bound) (names : named gamma roots root) : named gamma' roots root := by
  obtain ⟨origin, member, address⟩ := names
  exact ⟨origin, member, (namingSame origin root old).mpr address⟩

/-! ### Origins, reaching and the default configuration (moved from `Primitives`) -/

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

theorem default_has (mutant : Mutant) : ({} : Config).has mutant = false := by
  simp [Config.has]

theorem lookup_cons_other {α : Type} (entry : Var × α) (rest : Env α) (key : Var)
    (different : key ≠ entry.1) : (entry :: rest).lookup key = rest.lookup key := by
  rcases entry with ⟨name, value⟩
  have different' : key ≠ name := different
  have beqFalse : (key == name) = false := by simpa using different'
  simp [List.lookup_cons, beqFalse]

theorem lookup_cons_same {α : Type} (name : Var) (value : α) (rest : Env α) :
    ((name, value) :: rest).lookup name = some value := by
  simp

/-! ### Arrays of flat values -/

/-- An array of a flat value sits at a field path, below the heap bound, in any heap. -/
theorem arrayAt_flat {heap : Heap} {w : Value} {ty : Ty} {q : Path} {c : Nat}
    (shape : AllocatedFlatValue heap w ty) (flat : FlatHeap heap) (located : ArrayAt heap w q c) :
    c < heap.size ∧ immutablePath q = true ∧ ∀ heap' : Heap, ArrayAt heap' w q c := by
  induction shape generalizing q with
  | int integer => cases located
  | list root allocated =>
    have lookupRoot : heap[root]? = some heap[root] := by simp [allocated]
    obtain ⟨integers, payload⟩ := integers_of_flat_values heap[root] (flat root _ lookupRoot)
    rw [payload] at lookupRoot
    obtain ⟨rfl, rfl⟩ := arrayAt_flat_ref lookupRoot located
    exact ⟨allocated, rfl, fun _ => .here _⟩
  | record ws ts len _ ih =>
    cases located with
    | @field _ i w' q' _ ws_i inner =>
      obtain ⟨t, ts_i⟩ := index_of_same_length len ws_i
      obtain ⟨bound, immutable, everywhere⟩ := ih i w' t ws_i ts_i inner
      refine ⟨bound, ?_, fun heap' => .field ws_i (everywhere heap')⟩
      simp [immutablePath] at immutable ⊢
      exact immutable

theorem reaches_flat {heap : Heap} {w : Value} {ty : Ty} {c : Nat}
    (shape : AllocatedFlatValue heap w ty) (flat : FlatHeap heap) (reachable : Reaches heap w (.ref c)) :
    ∃ q, ArrayAt heap w q c := by
  induction shape with
  | int integer => cases reachable
  | list root allocated =>
    have lookupRoot : heap[root]? = some heap[root] := by simp [allocated]
    obtain ⟨integers, payload⟩ := integers_of_flat_values heap[root] (flat root _ lookupRoot)
    rw [payload] at lookupRoot
    have := flat_ref_reaches lookupRoot reachable
    subst this
    exact ⟨[], .here _⟩
  | record ws ts len _ ih =>
    cases reachable with
    | field member inner =>
      obtain ⟨i, ws_i⟩ := List.mem_iff_getElem?.mp member
      obtain ⟨t, ts_i⟩ := index_of_same_length len ws_i
      obtain ⟨q, located⟩ := ih i _ t ws_i ts_i inner
      exact ⟨.field i :: q, .field ws_i located⟩

/-! ### The frame of a flat value -/

theorem corresponds_flat_frame {heap next : Heap} {w : Value} {ty : Ty} {o : Observation}
    (shape : AllocatedFlatValue heap w ty) (flat : FlatHeap heap)
    (same : ∀ q c, ArrayAt heap w q c → next[c]? = heap[c]?)
    (paired : Corresponds heap o w) : Corresponds next o w := by
  induction shape generalizing o with
  | int integer => exact corresponds_int_frame paired
  | list root allocated => exact corresponds_ref_frame flat allocated paired (same [] root (.here _))
  | record ws ts len _ ih =>
    obtain ⟨os, rfl, lenO, fieldsC⟩ := corresponds_record_fields paired
    refine corresponds_record_of_fields lenO ?_
    intro i o' w' os_i ws_i
    obtain ⟨t, ts_i⟩ := index_of_same_length len ws_i
    exact ih i w' t ws_i ts_i (fun q c located => same (.field i :: q) c (.field ws_i located))
      (fieldsC i o' w' os_i ws_i)

theorem describes_flat_frame {heap next : Heap} {gamma gamma' : Naming} {w : Value} {ty : Ty}
    {a : Abstract}
    (shape : AllocatedFlatValue heap w ty) (abs : FlatAbstract ty a) (_flat : FlatHeap heap)
    (nextFlat : FlatHeap next) (size : heap.size ≤ next.size)
    (namingSame : ∀ origin cell, cell < heap.size → (cell ∈ gamma' origin ↔ cell ∈ gamma origin))
    (described : Describes gamma heap a w) : Describes gamma' next a w := by
  induction shape generalizing a with
  | int integer =>
    cases abs
    exact integer_described integer
  | list root allocated =>
    have nextAllocated : root < next.size := Nat.lt_of_lt_of_le allocated size
    have lookupRoot : next[root]? = some next[root] := by simp [nextAllocated]
    obtain ⟨integers, payload⟩ := integers_of_flat_values next[root] (nextFlat root _ lookupRoot)
    rw [payload] at lookupRoot
    cases abs with
    | listBottom roots certificate =>
      have names := described.1.1 [] root (.here _)
      rw [list_root_names] at names
      exact allocated_list_described lookupRoot
        (named_same_of_naming namingSame allocated (named_union_nil names))
    | listScalar roots certificate =>
      have names := described.1.1 [] root (.here _)
      rw [list_root_names] at names
      exact allocated_list_described lookupRoot
        (named_same_of_naming namingSame allocated (named_union_nil names))
  | record ws ts len _ ih =>
    obtain ⟨as, rfl, lenTA, fieldsA⟩ := flatAbstract_record abs
    refine describes_record_of_fields (lenTA.symm.trans len.symm) ?_
    intro i a' w' as_i ws_i
    obtain ⟨t, ts_i⟩ := index_of_same_length len ws_i
    exact ih i w' t ws_i ts_i (fieldsA i t a' ts_i as_i) (describes_field described as_i ws_i)

/-! ### The cells at a path (moved from `CallDerivation`, which imports this chain) -/

theorem mem_cellsAt_fold (paths : List (Path × List Origin)) (p : Path) (acc : List Origin)
    (o : Origin)
    (member : o ∈ paths.foldl (fun cs (q, xs) => if p == q then union cs xs else cs) acc) :
    o ∈ acc ∨ ∃ cs, (p, cs) ∈ paths ∧ o ∈ cs := by
  induction paths generalizing acc with
  | nil => exact Or.inl member
  | cons entry paths ih =>
    rcases entry with ⟨q, xs⟩
    rw [List.foldl_cons] at member
    rcases ih _ member with inAcc | ⟨cs, path, inCs⟩
    · dsimp only at inAcc
      by_cases same : (p == q) = true
      · rw [if_pos same] at inAcc
        rcases mem_union_cases acc xs o inAcc with old | new
        · exact Or.inl old
        · exact Or.inr ⟨xs, by rw [eq_of_beq same]; simp, new⟩
      · rw [if_neg same] at inAcc
        exact Or.inl inAcc
    · exact Or.inr ⟨cs, List.mem_cons_of_mem _ path, inCs⟩

theorem mem_cellsAt (a : Abstract) (p : Path) (o : Origin) (member : o ∈ a.cellsAt p) :
    ∃ cs, (p, cs) ∈ a.paths ∧ o ∈ cs := by
  unfold Abstract.cellsAt at member
  rcases mem_cellsAt_fold a.paths p [] o member with none | found
  · simp at none
  · exact found

/-- A field path of a record's component is a path of the record. -/
theorem record_path_mem (xs : List Abstract) (i : Nat) (x : Abstract) (p : Path)
    (cs : List Origin) (lookup : xs[i]? = some x) (path : (p, cs) ∈ x.paths) :
    (.field i :: p, cs) ∈ (Abstract.record xs).paths := by
  simp only [Abstract.paths]
  refine List.mem_flatMap.mpr ⟨(⟨x, List.mem_of_getElem? lookup⟩, i), ?_,
    List.mem_map.mpr ⟨(p, cs), path, rfl⟩⟩
  rw [List.mk_mem_zipIdx_iff_getElem?]
  simp [lookup]

/-! ### Names at a path and the cells there -/


theorem mem_cells_fold_of_acc (paths : List (Path × List Origin)) (p : Path) (acc : List Origin)
    (o : Origin) (member : o ∈ acc) :
    o ∈ paths.foldl (fun cs (q, xs) => if p == q then union cs xs else cs) acc := by
  induction paths generalizing acc with
  | nil => exact member
  | cons entry paths ih =>
    rcases entry with ⟨q, xs⟩
    rw [List.foldl_cons]
    apply ih
    dsimp only
    split
    · exact mem_union acc xs o (Or.inl member)
    · exact member

theorem mem_cells_fold_of_path (paths : List (Path × List Origin)) (p : Path) (cs : List Origin)
    (o : Origin) (path : (p, cs) ∈ paths) (member : o ∈ cs) :
    ∀ acc, o ∈ paths.foldl (fun cs (q, xs) => if p == q then union cs xs else cs) acc := by
  induction paths with
  | nil => simp at path
  | cons entry paths ih =>
    intro acc
    rcases entry with ⟨q, xs⟩
    rw [List.foldl_cons]
    rcases List.mem_cons.mp path with same | later
    · cases same
      apply mem_cells_fold_of_acc
      dsimp only
      rw [if_pos (beq_self_eq_true _)]
      exact mem_union acc cs o (Or.inr member)
    · exact ih later _

theorem mem_cellsAt_of_path {a : Abstract} {p : Path} {cs : List Origin} {o : Origin}
    (path : (p, cs) ∈ a.paths) (member : o ∈ cs) : o ∈ a.cellsAt p := by
  unfold Abstract.cellsAt
  exact mem_cells_fold_of_path a.paths p cs o path member []

/-- Covering at every path gives the invariant's `named` clause for a flat value. -/
theorem named_cellsAt_of_covers {heap : Heap} {gamma : Naming} {w : Value} {ty : Ty} {a : Abstract}
    {q : Path} {c : Nat}
    (shape : AllocatedFlatValue heap w ty) (abs : FlatAbstract ty a) (flat : FlatHeap heap)
    (covers : Covers gamma heap a w) (located : ArrayAt heap w q c) :
    named gamma (a.cellsAt q) c := by
  induction shape generalizing a q with
  | int integer => cases located
  | list root allocated =>
    have lookupRoot : heap[root]? = some heap[root] := by simp [allocated]
    obtain ⟨integers, payload⟩ := integers_of_flat_values heap[root] (flat root _ lookupRoot)
    rw [payload] at lookupRoot
    obtain ⟨rfl, rfl⟩ := arrayAt_flat_ref lookupRoot located
    have := covers _ _ (.here _)
    simpa [namesAt] using this
  | record ws ts len _ ih =>
    cases located with
    | @field _ i w' q' _ ws_i inner =>
      obtain ⟨as, rfl, lenTA, fieldsA⟩ := flatAbstract_record abs
      obtain ⟨t, ts_i⟩ := index_of_same_length len ws_i
      obtain ⟨a', as_i, abs'⟩ := flatAbstract_record_field lenTA fieldsA ts_i
      obtain ⟨origin, member, address⟩ :=
        ih i w' t ws_i ts_i abs' (covers_field covers as_i ws_i) inner
      obtain ⟨cs, path, inCs⟩ := mem_cellsAt a' q' origin member
      exact ⟨origin, mem_cellsAt_of_path (record_path_mem as i a' q' cs as_i path) inCs, address⟩

theorem arrayAt_of_project {heap : Heap} {w w' : Value} {p q : Path} {c : Nat}
    (projected : projectVal w p = some w') (located : ArrayAt heap w' q c) :
    ArrayAt heap w (p ++ q) c := by
  induction p generalizing w with
  | nil =>
    simp [projectVal] at projected
    subst projected
    simpa using located
  | cons step rest ih =>
    cases step <;> cases w <;> simp [projectVal] at projected
    rename_i i' ws
    cases h : ws[i']? with
    | none => simp [h] at projected
    | some x =>
      simp [h] at projected
      exact .field h (ih projected)

theorem projectVal_fieldPath {w w' : Value} {p : Path} (projected : projectVal w p = some w') :
    immutablePath p = true := by
  induction p generalizing w with
  | nil => rfl
  | cons step rest ih =>
    cases step <;> cases w <;> simp [projectVal] at projected
    rename_i i' ws
    cases h : ws[i']? with
    | none => simp [h] at projected
    | some x =>
      simp [h] at projected
      have := ih projected
      simp [immutablePath] at this ⊢
      exact this

theorem immutablePath_append (p q : Path) :
    immutablePath (p ++ q) = (immutablePath p && immutablePath q) := by
  simp [immutablePath, List.all_append]

theorem isPrefix_append (p q : Path) : isPrefix p (p ++ q) = true := by
  simp [isPrefix]

/-- The cells of a live path's abstract at any longer path are live cells. -/
theorem cells_in_liveCells (env : Env Abstract) (l : Live) (x : Var) (p p' : Path) (a : Abstract)
    (cs : List Origin) (use : (x, p) ∈ l) (found : env.lookup x = some a)
    (path : (p', cs) ∈ a.paths) (below : isPrefix p p' = true) :
    ∀ o ∈ cs, o ∈ liveCells env l := by
  intro o member
  rw [liveCells_eq_fold]
  apply foldl_member (useStep env) (useStep_mono env) l [] (x, p) use o
  intro acc
  unfold useStep
  simp only [found]
  apply foldl_member (pathStep p) (pathStep_mono p) a.paths acc (p', cs) path o
  intro acc'
  unfold pathStep
  simp only [below, Bool.true_or, if_true]
  exact mem_union acc' cs o (Or.inr member)

/-! ### Cells -/

theorem mem_cells_of_path {a : Abstract} {q : Path} {cs : List Origin} {o : Origin}
    (path : (q, cs) ∈ a.paths) (member : o ∈ cs) : o ∈ a.cells := by
  unfold Abstract.cells
  apply foldl_member (fun cs (entry : Path × List Origin) => union cs entry.2)
    (fun cs entry o present => mem_union cs entry.2 o (Or.inl present)) a.paths [] (q, cs) path o
  intro acc
  exact mem_union acc cs o (Or.inr member)

theorem cellsAt_subset_cells {a : Abstract} {q : Path} {o : Origin} (member : o ∈ a.cellsAt q) :
    o ∈ a.cells := by
  obtain ⟨cs, path, inCs⟩ := mem_cellsAt a q o member
  exact mem_cells_of_path path inCs

/-- An origin that names a cell of an abstract aliases one of its cells, and
every cell is now a recorded escape. -/
theorem named_cell_escaped {gamma : Naming} {escapes : List Origin} {origin : Origin} {root : Nat}
    {cs : List Origin} {a : Abstract} (separating : Separating gamma)
    (names : named gamma cs root) (member : root ∈ gamma origin) (sub : ∀ o ∈ cs, o ∈ a.cells) :
    Escaped (union escapes a.cells) origin := by
  obtain ⟨witness, witnessMember, address⟩ := names
  have alias : aliases origin witness = true := by
    cases equal : aliases origin witness with
    | true => rfl
    | false => exact absurd address (separating origin witness equal root member)
  have baseEqual := aliases_true_base alias
  right
  refine List.any_eq_true.mpr ⟨origin.base, by simp,
    List.any_eq_true.mpr ⟨witness.base, ?_, aliases_of_base baseEqual⟩⟩
  exact List.mem_map.mpr ⟨witness, mem_union escapes _ witness (Or.inr (sub witness witnessMember)), rfl⟩

/-! ### The shared step on a flat shape -/

theorem record_mapOrigins_index (f : Path → List Origin → List Origin) (as : List Abstract)
    (path : Path) (i : Nat) :
    (as.attach.zipIdx.map fun (x, j) => x.val.mapOrigins f (path ++ [.field j]))[i]? =
      as[i]?.map fun a => a.mapOrigins f (path ++ [.field i]) := by
  by_cases lt : i < as.length
  · have attach_i : as.attach[i]? = some ⟨as[i], List.getElem_mem lt⟩ := by
      rw [List.getElem?_eq_getElem (by simpa using lt)]
      simp
    rw [List.getElem?_map, List.getElem?_zipIdx, attach_i, List.getElem?_eq_getElem lt]
    simp
  · have none1 : as[i]? = none := List.getElem?_eq_none (Nat.le_of_not_lt lt)
    have none2 : as.attach[i]? = none :=
      List.getElem?_eq_none (by simpa using Nat.le_of_not_lt lt)
    rw [List.getElem?_map, List.getElem?_zipIdx, none2, none1]
    rfl

theorem flatAbstract_mapOrigins (f : Path → List Origin → List Origin) {ty : Ty} {a : Abstract}
    (shape : FlatAbstract ty a) (path : Path) : FlatAbstract ty (a.mapOrigins f path) := by
  induction shape generalizing path with
  | int => simpa [Abstract.mapOrigins] using FlatAbstract.int
  | listBottom roots certificate =>
    simp only [Abstract.mapOrigins]
    exact .listBottom _ _
  | listScalar roots certificate =>
    simp only [Abstract.mapOrigins]
    exact .listScalar _ _
  | record ts as len _ ih =>
    simp only [Abstract.mapOrigins]
    refine .record ts _ (by simp [len]) ?_
    intro i t a' ts_i at_i
    rw [record_mapOrigins_index] at at_i
    cases h : as[i]? with
    | none => simp [h] at at_i
    | some a0 =>
      simp [h] at at_i
      subst at_i
      exact ih i t a0 ts_i h _

/-- The checker's shared marking: a nonempty cell list keeps its origins. -/
def sharedMark (_ : Path) (cs : List Origin) : List Origin :=
  if cs.isEmpty then [] else union cs [.shared]

theorem named_sharedMark {gamma : Naming} {cs : List Origin} {root : Nat} (path : Path)
    (names : named gamma cs root) : named gamma (sharedMark path cs) root := by
  obtain ⟨witness, member, address⟩ := names
  have nonempty : cs.isEmpty = false := by
    cases cs with
    | nil => simp at member
    | cons _ _ => rfl
  refine ⟨witness, ?_, address⟩
  simp only [sharedMark, nonempty, Bool.false_eq_true, if_false]
  exact mem_union cs [.shared] witness (Or.inl member)

theorem describes_mapOrigins_shared {gamma : Naming} {heap : Heap} {w : Value} {ty : Ty} {a : Abstract}
    (shape : AllocatedFlatValue heap w ty) (abs : FlatAbstract ty a) (flat : FlatHeap heap)
    (described : Describes gamma heap a w) (path : Path) :
    Describes gamma heap (a.mapOrigins sharedMark path) w := by
  induction shape generalizing a path with
  | int integer =>
    cases abs
    simpa [Abstract.mapOrigins] using integer_described (gamma := gamma) (heap := heap) integer
  | list root allocated =>
    have lookupRoot : heap[root]? = some heap[root] := by simp [allocated]
    obtain ⟨integers, payload⟩ := integers_of_flat_values heap[root] (flat root _ lookupRoot)
    rw [payload] at lookupRoot
    cases abs with
    | listBottom roots certificate =>
      have names := described.1.1 [] root (.here _)
      rw [list_root_names] at names
      simp only [Abstract.mapOrigins]
      exact allocated_list_described lookupRoot (named_sharedMark path (named_union_nil names))
    | listScalar roots certificate =>
      have names := described.1.1 [] root (.here _)
      rw [list_root_names] at names
      simp only [Abstract.mapOrigins]
      exact allocated_list_described lookupRoot (named_sharedMark path (named_union_nil names))
  | record ws ts len _ ih =>
    obtain ⟨as, rfl, lenTA, fieldsA⟩ := flatAbstract_record abs
    simp only [Abstract.mapOrigins]
    refine describes_record_of_fields (by simp [lenTA, len]) ?_
    intro i a' w' at_i ws_i
    rw [record_mapOrigins_index] at at_i
    cases h : as[i]? with
    | none => simp [h] at at_i
    | some a0 =>
      simp [h] at at_i
      subst at_i
      obtain ⟨t, ts_i⟩ := index_of_same_length len ws_i
      exact ih i w' t ws_i ts_i (fieldsA i t a0 ts_i h) (describes_field described h ws_i) _

/-! ### The record constructor -/

theorem value_record_run (s : ValueSemantics.State) (os : List Observation) :
    (ValueSemantics.prim .record os).run s = .ok (.record os, s) := rfl

theorem heap_record_run (s : State) (ws : List Value) :
    (prim .record ws).run s = .ok (.record ws, s) := rfl

theorem primitive_record_run (ctx : Context) (defaultConfig : ctx.config = {}) (site : List Nat)
    (xs : List Abstract) (later : List Origin) (before : St) :
    (primitive ctx site .record xs later).run before = .ok (.record xs, before) := by
  unfold primitive
  simp only [defaultConfig, default_has, Bool.false_eq_true, if_false]
  rfl

theorem primType_record (ts : List Ty) : primType .record ts = .ok (.record ts) := rfl

theorem exprType_record_success {declarations : List Decl} {self : Decl} {tenv : Env Ty}
    {args : List Atom} {type : Ty}
    (typed : exprType declarations self tenv (.prim .record args) = .ok type) :
    ∃ ts, args.mapM (atomType tenv) = .ok ts ∧ type = .record ts := by
  obtain ⟨ts, atomsTyped, primTyped⟩ := exprType_prim_success typed
  rw [primType_record] at primTyped
  exact ⟨ts, atomsTyped, (Except.ok.inj primTyped).symm⟩

end Ownership.FlatFragment.Fields

/-! allocation and write preservation for every flat binding (continued from
`Runtime`): the shape of a typed binding and the typing of every binding after
a flat heap change, now with records. -/

namespace Ownership.FlatFragment.HeapPreservation

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.Runtime
open Ownership.FlatFragment.Fields

/-- Finite typed expansions establish the exact runtime shape and exclude
dangling roots even when the binding has no future live use. -/
theorem allocated_shape_of_typed {heap : Heap} (flatType : FlatType type)
    (typed : ValueTyped declarations heap actual type) :
    AllocatedFlatValue heap actual type :=
  allocated_of_typed flatType typed

/-- Any flat heap with enough allocated addresses preserves all flat
binding types. This includes aliases of the address whose contents changed.
The statement retains no correspondence claim for a dead observation. -/
theorem valueTyped_after_flat_heap {heap : Heap} {nextHeap : Heap}
    (flatType : FlatType type) (typed : ValueTyped declarations heap actual type)
    (nextFlat : FlatHeap nextHeap) (size : heap.size ≤ nextHeap.size) :
    ValueTyped declarations nextHeap actual type :=
  valueTyped_of_allocated (allocated_mono (allocated_shape_of_typed flatType typed) size) nextFlat

/-- The complete all-binding typing field survives integer allocation and
integer writes. The caller still proves live correspondence from its demand.
-/
theorem bindingsTyped_after_flat_heap {nextHeap : Heap}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (nextFlat : FlatHeap nextHeap) (size : hs.heap.size ≤ nextHeap.size) :
    ∀ x observation actual,
      env.lookup x = some (observation, actual) →
      ∃ type, tenv.lookup x = some type ∧
        obsTyped declarations observation type = true ∧
        ValueTyped declarations nextHeap actual type := by
  intro x observation actual present
  obtain ⟨type, declared, observedType, actualType⟩ :=
    inv.bindingsTyped x observation actual present
  exact ⟨type, declared, observedType,
    valueTyped_after_flat_heap (inv.types x type declared) actualType nextFlat size⟩

/-- A real counted write retains every binding's current runtime type,
including every dead alias of the written root. Observer and live-value
frames still require the separate permission facts from the actual demand.
-/
theorem counted_write_preserves_binding_types {root : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (allocated : hs.heap[root]? = some previous) (integers : List Int) :
    ∃ post,
      (writeCounted root (heapInts integers)).run hs = .ok (.ref root, post) ∧
      FlatHeap post.heap ∧
      (∀ x observation actual, env.lookup x = some (observation, actual) →
        ∃ type, tenv.lookup x = some type ∧
          obsTyped declarations observation type = true ∧
          ValueTyped declarations post.heap actual type) := by
  let post := {hs with heap := hs.heap.set! root (heapInts integers), writes := if previous == heapInts integers then hs.writes else hs.writes + 1}
  have valid : root < hs.heap.size := (Array.getElem?_eq_some_iff.mp allocated).1
  have nextFlat := flatHeap_after_write inv.heapInts valid integers
  refine ⟨post, writeCounted_empty_run hs allocated inv.links, nextFlat, ?_⟩
  exact bindingsTyped_after_flat_heap inv nextFlat (by simp [post])

/-- Real integer literal allocation also preserves every old binding's
type. Its new result binding and constructed naming enter the expression
preservation case separately. -/
theorem literal_preserves_binding_types
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (integers : List Int) :
    ∃ post,
      (prim (.literal .int) (heapInts integers)).run hs =
        .ok (.ref hs.heap.size, post) ∧
      FlatHeap post.heap ∧
      (∀ x observation actual, env.lookup x = some (observation, actual) →
        ∃ type, tenv.lookup x = some type ∧
          obsTyped declarations observation type = true ∧
          ValueTyped declarations post.heap actual type) := by
  let post := {hs with heap := hs.heap.push (heapInts integers)}
  have nextFlat := flatHeap_after_allocation inv.heapInts integers
  refine ⟨post, rfl, nextFlat, ?_⟩
  exact bindingsTyped_after_flat_heap inv nextFlat (by simp [post])

end Ownership.FlatFragment.HeapPreservation

/-! atoms under the relation: every typed atom whose uses are live evaluates
on both sides from its root binding; the Dead test keeps every array of a live
projected value apart from the written root; the uses of a typed flat
expression are typed paths. No theorem below uses a pinned soundness obligation. -/

namespace Ownership.FlatFragment.Fields

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.Support Ownership.FlatFragment.State
open Ownership.FlatFragment.Env Ownership.FlatFragment.VariableFacts Ownership.FlatFragment.CheckerExtraction
open Ownership.FlatFragment.Scope Ownership.FlatFragment.HeapPreservation Ownership.FlatFragment.Description
open Ownership.FlatFragment.NamingFacts Ownership.FlatFragment.LiveCells Ownership.FlatFragment.Liveness
open Ownership.FlatFragment.AtomPreservation Ownership.FlatFragment.IntegerCorrespondence Ownership.FlatFragment.Runtime

local instance stepReflBEq2 : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance stepLawfulBEq2 : LawfulBEq Step := LawfulBEq.mk (by deriving_LawfulEq_tactic)
local instance originReflBEq2 : ReflBEq Origin := ⟨by deriving_ReflEq_tactic⟩
local instance originLawfulBEq2 : LawfulBEq Origin := LawfulBEq.mk (by deriving_LawfulEq_tactic)

theorem corresponds_int_inv {heap : Heap} {o : Observation} {integer : Int}
    (paired : Corresponds heap o (.int integer)) : o = .int integer := by
  have observed := paired o.depth (Nat.le_refl _)
  cases depth : o.depth with
  | zero => rw [depth] at observed; simp [snapshot] at observed
  | succ d =>
    rw [depth] at observed
    obtain ⟨cs, rep⟩ := represents_of_snapshot (d + 1) (.int integer) o observed
    cases rep
    rfl

/-- Every typed atom whose uses are live evaluates on both sides, and in the
checker, to corresponding, described and typed flat values. -/
theorem flat_atom_values {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {atom : Atom} {ty : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (typed : atomType tenv atom = .ok ty)
    (covered : ∀ use ∈ atomUses atom, use ∈ live) :
    ∃ o w a, ValueSemantics.atom (valueEnv env) atom = .ok o ∧
      InPlaceSemantics.atom (heapEnv env) atom = .ok w ∧
      abstractAtom aenv atom = .ok a ∧
      Corresponds hs.heap o w ∧ Describes gamma hs.heap a w ∧
      obsTyped declarations o ty = true ∧ ValueTyped declarations hs.heap w ty ∧
      FlatType ty ∧ FlatAbstract ty a ∧ AllocatedFlatValue hs.heap w ty := by
  cases root : atomRoot atom with
  | none =>
    obtain ⟨n, rfl, rfl⟩ := atom_int_of_root_none typed root
    exact ⟨.int n, .int n, .scalar, rfl, rfl, rfl, integer_corresponds n, integer_described n,
      by simp [obsTyped], ⟨1, .int n, [], .int, by simp [obsTyped]⟩, .int, .int, .int n⟩
  | some kp =>
    rcases kp with ⟨k, p⟩
    obtain ⟨tk, declared, at_p⟩ := atom_type_of_root typed root
    obtain ⟨pair, binding⟩ := lookup_exists_of_same_keys env tenv inv.typeKeys declared
    rcases pair with ⟨o0, w0⟩
    obtain ⟨a0, abstractBinding⟩ := lookup_exists_of_same_keys aenv env inv.abstractKeys.symm binding
    have use : (k, p) ∈ live := covered (k, p) (by rw [atomUses_of_root root]; simp)
    obtain ⟨o, w, obsPath, valuePath, paired⟩ := inv.bindings k p use o0 w0 binding
    have described := inv.described k p use o0 w0 a0 w binding abstractBinding valuePath
    obtain ⟨tk', declared', observed0, typed0⟩ := inv.bindingsTyped k o0 w0 binding
    have same : tk' = tk := Option.some.inj (declared'.symm.trans declared)
    subst same
    have flatTk := inv.types k tk' declared
    have shape0 := inv.abstractShapes k tk' a0 declared abstractBinding
    have allocated0 := allocated_of_typed flatTk typed0
    obtain ⟨t', at_p', allocated⟩ := allocated_project allocated0 valuePath
    rw [at_p] at at_p'
    cases Option.some.inj at_p'
    exact ⟨o, w, a0.atPath p, value_atom_of_root root (valueEnv_lookup binding) obsPath,
      heap_atom_of_root root (heapEnv_lookup binding) valuePath,
      abstractAtom_of_root root abstractBinding shape0 at_p, paired, described,
      projectObs_typed observed0 at_p obsPath, valueTyped_of_allocated allocated inv.heapInts,
      flatType_tyAt flatTk at_p, flatAbstract_atPath shape0 at_p, allocated⟩

/-- An `Int`-typed atom whose uses are live is an integer on both sides and a
scalar in the checker. -/
theorem flat_atom_integer {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {atom : Atom}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (typed : atomType tenv atom = .ok .int)
    (covered : ∀ use ∈ atomUses atom, use ∈ live) :
    ∃ integer : Int,
      ValueSemantics.atom (valueEnv env) atom = .ok (.int integer) ∧
      InPlaceSemantics.atom (heapEnv env) atom = .ok (.int integer) ∧
      abstractAtom aenv atom = .ok .scalar := by
  obtain ⟨o, w, a, valueRun, heapRun, abstractRun, paired, _, _, _, _, shape, allocated⟩ :=
    flat_atom_values inv typed covered
  cases allocated with
  | int integer =>
    cases shape
    have observed := corresponds_int_inv paired
    subst observed
    exact ⟨integer, valueRun, heapRun, abstractRun⟩

/-- A `List Int`-typed atom whose uses are live is an allocated integer array
on the heap side, its observation on the value side, and a named flat list in
the checker. -/
theorem flat_atom_list_path {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {atom : Atom}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (typed : atomType tenv atom = .ok (.list .int))
    (covered : ∀ use ∈ atomUses atom, use ∈ live) :
    ∃ (root : Nat) (integers : List Int) (roots : List Origin) (element : Abstract)
      (certificate : Certificate),
      hs.heap[root]? = some (heapInts integers) ∧
      named gamma roots root ∧
      (element = .bottom ∨ element = .scalar) ∧
      ValueSemantics.atom (valueEnv env) atom = .ok (.list (valueInts integers)) ∧
      InPlaceSemantics.atom (heapEnv env) atom = .ok (.ref root) ∧
      abstractAtom aenv atom = .ok (.list roots element certificate) := by
  obtain ⟨o, w, a, valueRun, heapRun, abstractRun, paired, described, _, _, _, shape, allocated⟩ :=
    flat_atom_values inv typed covered
  cases allocated with
  | list root lt =>
    have lookupRoot : hs.heap[root]? = some hs.heap[root] := by simp [lt]
    obtain ⟨integers, payload⟩ := integers_of_flat_values hs.heap[root] (inv.heapInts root _ lookupRoot)
    rw [payload] at lookupRoot
    have observed := observation_of_integer_ref lookupRoot paired
    subst observed
    cases shape with
    | listBottom roots certificate =>
      have names := described.1.1 [] root (.here _)
      rw [list_root_names] at names
      exact ⟨root, integers, roots, .bottom, certificate, lookupRoot, named_union_nil names, Or.inl rfl,
        valueRun, heapRun, abstractRun⟩
    | listScalar roots certificate =>
      have names := described.1.1 [] root (.here _)
      rw [list_root_names] at names
      exact ⟨root, integers, roots, .scalar, certificate, lookupRoot, named_union_nil names, Or.inr rfl,
        valueRun, heapRun, abstractRun⟩

/-- The Dead test of a write keeps every array of a live projected value
apart from the written root: the array is named by a cell at the binding's
path, that cell is a live cell, and the test refused any overlap. -/
theorem live_path_apart {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {after : Live} {escapes : List Origin} {roots : List Origin} {root : Nat} {pinned : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (scope : liveScope aenv after = .ok ())
    (receiverNamed : named gamma roots root)
    (separate : ∀ r, named gamma roots r → ¬ named gamma (union (liveCells aenv after) pinned) r) :
    ∀ x p, (x, p) ∈ after → ∀ o w w', env.lookup x = some (o, w) → projectVal w p = some w' →
      ∀ q c, ArrayAt hs.heap w' q c → c ≠ root := by
  intro x p use o w w' binding projected q c located same
  subst same
  obtain ⟨a, abstractBinding⟩ := liveScope_lookup_exists scope use
  obtain ⟨ty, declared, _, actualTyped⟩ := inv.bindingsTyped x o w binding
  have allocated := allocated_of_typed (inv.types x ty declared) actualTyped
  obtain ⟨t, _, allocated'⟩ := allocated_project allocated projected
  obtain ⟨_, immutableQ, _⟩ := arrayAt_flat allocated' inv.heapInts located
  have immutable : immutablePath (p ++ q) = true := by
    rw [immutablePath_append, projectVal_fieldPath projected, immutableQ]; rfl
  have names := inv.named x o w a binding abstractBinding (p ++ q) c immutable
    (arrayAt_of_project projected located)
  obtain ⟨origin, member, address⟩ := names
  obtain ⟨cs, path, inCs⟩ := mem_cellsAt a (p ++ q) origin member
  have inLive := cells_in_liveCells aenv after x p (p ++ q) a cs use abstractBinding path
    (isPrefix_append p q) origin inCs
  exact separate c receiverNamed ⟨origin, mem_union _ _ origin (Or.inl inLive), address⟩

/-- Every array of a flat value sits below the heap bound. -/
theorem live_path_below {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {escapes : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma) :
    ∀ x p o w w', env.lookup x = some (o, w) → projectVal w p = some w' →
      ∀ q c, ArrayAt hs.heap w' q c → c < hs.heap.size := by
  intro x p o w w' binding projected q c located
  obtain ⟨ty, declared, _, actualTyped⟩ := inv.bindingsTyped x o w binding
  have allocated := allocated_of_typed (inv.types x ty declared) actualTyped
  obtain ⟨t, _, allocated'⟩ := allocated_project allocated projected
  exact (arrayAt_flat allocated' inv.heapInts located).1

/-! ### The uses of a typed expression are typed paths -/

theorem atom_use_typed {tenv : Env Ty} {a : Atom} {ty : Ty} {x : Var} {p : Path}
    (typed : atomType tenv a = .ok ty) (use : (x, p) ∈ atomUses a) :
    ∃ tk t, tenv.lookup x = some tk ∧ tyAt tk p = some t := by
  cases root : atomRoot a with
  | none =>
    obtain ⟨n, rfl, _⟩ := atom_int_of_root_none typed root
    simp [atomUses] at use
  | some kp =>
    rcases kp with ⟨k, q⟩
    rw [atomUses_of_root root] at use
    simp at use
    obtain ⟨rfl, rfl⟩ := use
    obtain ⟨tk, declared, at_q⟩ := atom_type_of_root typed root
    exact ⟨tk, ty, declared, at_q⟩

theorem atoms_use_typed {tenv : Env Ty} {args : List Atom} {types : List Ty} {x : Var} {p : Path}
    (typed : args.mapM (atomType tenv) = .ok types) (use : (x, p) ∈ atomsUses args) :
    ∃ tk t, tenv.lookup x = some tk ∧ tyAt tk p = some t := by
  obtain ⟨a, member, atomUse⟩ := List.mem_flatMap.mp use
  obtain ⟨i, at_i⟩ := List.mem_iff_getElem?.mp member
  obtain ⟨len, fields⟩ := mapM_ok_fields typed
  obtain ⟨t, types_i⟩ := index_of_same_length len at_i
  exact atom_use_typed (fields i a t at_i types_i) atomUse

theorem flat_uses_typed {declarations : List Decl} {self : Decl} {e : Expr} (flat : FlatANF0 e) :
    ∀ (tenv : Env Ty) (ty : Ty), exprType declarations self tenv e = .ok ty →
      ∀ x p, (x, p) ∈ uses e → ∃ tk t, tenv.lookup x = some tk ∧ tyAt tk p = some t := by
  induction flat with
  | @atom a =>
    intro tenv ty typed x p use
    exact atom_use_typed (a := a) typed use
  | @letE rhs rest v _ _ ihRhs ihRest =>
    intro tenv ty typed x p use
    obtain ⟨rhsType, rhsTyped, restTyped⟩ := exprType_let_success typed
    change (x, p) ∈ union (uses rhs) (removeVars [v] (uses rest)) at use
    rcases mem_union_cases _ _ (x, p) use with inRhs | inRest
    · exact ihRhs tenv rhsType rhsTyped x p inRhs
    · have filtered := List.mem_filter.mp inRest
      have different : x ≠ v := by
        intro same
        subst same
        simp at filtered
      obtain ⟨tk, t, declared, at_p⟩ := ihRest _ ty restTyped x p filtered.1
      rw [lookup_cons_other _ _ _ different] at declared
      exact ⟨tk, t, declared, at_p⟩
  | @literal args =>
    intro tenv ty typed x p use
    obtain ⟨types, atomsTyped, _⟩ := exprType_prim_success typed
    exact atoms_use_typed atomsTyped use
  | @push receiver item =>
    intro tenv ty typed x p use
    obtain ⟨types, atomsTyped, _⟩ := exprType_prim_success typed
    exact atoms_use_typed atomsTyped use
  | @length receiver =>
    intro tenv ty typed x p use
    obtain ⟨types, atomsTyped, _⟩ := exprType_prim_success typed
    exact atoms_use_typed atomsTyped use
  | @shared value =>
    intro tenv ty typed x p use
    obtain ⟨types, atomsTyped, _⟩ := exprType_prim_success typed
    exact atoms_use_typed atomsTyped use
  | @scalar op a b sop =>
    intro tenv ty typed x p use
    obtain ⟨types, atomsTyped, _⟩ := exprType_prim_success typed
    rw [uses_scalar sop] at use
    exact atoms_use_typed atomsTyped use
  | @record args =>
    intro tenv ty typed x p use
    obtain ⟨types, atomsTyped, _⟩ := exprType_prim_success typed
    exact atoms_use_typed atomsTyped use

end Ownership.FlatFragment.Fields
