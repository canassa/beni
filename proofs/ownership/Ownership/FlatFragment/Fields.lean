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

/-- The projection of a flat value along a typed path has the path's type.
A result's slots have no typed path, so a projection never enters one. -/
theorem allocated_project {heap : Heap} {w w' : Value} {tk t : Ty} {p : Path}
    (shape : AllocatedFlatValue heap w tk) (at_p : tyAt tk p = some t)
    (projected : projectVal w p = some w') : AllocatedFlatValue heap w' t := by
  obtain ⟨w'', projected', shape'⟩ := projectVal_of_tyAt shape at_p
  rw [projected] at projected'
  cases Option.some.inj projected'
  exact shape'

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

/-! ### Lists of typed elements (slice 2b of #522) -/

/-- An observation whose elements are typed `t` is typed `List t`. -/
theorem obsTyped_list_of_elements {ds : List Decl} {os : List Observation} {t : Ty}
    (elements : ∀ o ∈ os, obsTyped ds o t = true) : obsTyped ds (.list os) (.list t) = true := by
  unfold obsTyped
  change os.attach.all (fun item => obsTyped ds item.val t) = true
  exact List.all_eq_true.mpr (fun item _ => elements item.val item.property)

/-- The elements of an observation typed `List t` are typed `t`. -/
theorem obsTyped_list_elements {ds : List Decl} {os : List Observation} {t : Ty}
    (typed : obsTyped ds (.list os) (.list t) = true) : ∀ o ∈ os, obsTyped ds o t = true := by
  unfold obsTyped at typed
  change os.attach.all (fun item => obsTyped ds item.val t) = true at typed
  intro o member
  exact List.all_eq_true.mp typed ⟨o, member⟩ (List.mem_attach _ _)

/-- An allocated array of values typed `t` is typed `List t`. -/
theorem valueTyped_list_of_elements {ds : List Decl} {heap : Heap} {root : Nat} {ws : List Value} {t : Ty}
    (lookup : heap[root]? = some ws) (elements : ∀ w ∈ ws, ValueTyped ds heap w t) :
    ValueTyped ds heap (.ref root) (.list t) := by
  obtain ⟨os, cs, n, many, lenO, typedMany⟩ :=
    representsMany_typed_of_fields ws (ws.map fun _ => t) (by simp)
      (fun i w t' ws_i ts_i => by
        have : t' = t := by
          rw [List.getElem?_map, ws_i] at ts_i
          exact (Option.some.inj ts_i).symm
        subst this
        exact elements w (List.mem_of_getElem? ws_i))
  refine ⟨n + 1, .list os, root :: cs, .ref lookup many, obsTyped_list_of_elements ?_⟩
  intro o member
  obtain ⟨i, os_i⟩ := List.mem_iff_getElem?.mp member
  have ts_i : (ws.map fun _ => t)[i]? = some t := by
    rw [List.getElem?_map]
    have bound : i < ws.length := by
      have := (List.getElem?_eq_some_iff.mp os_i).1
      rw [lenO, List.length_map] at this
      exact this
    simp [List.getElem?_eq_getElem bound]
  exact typedMany i o t os_i ts_i

/-- The elements of an allocated array typed `List t` are typed `t`. -/
theorem valueTyped_list_elements {ds : List Decl} {heap : Heap} {root : Nat} {ws : List Value} {t : Ty}
    (lookup : heap[root]? = some ws) (typed : ValueTyped ds heap (.ref root) (.list t)) :
    ∀ w ∈ ws, ValueTyped ds heap w t := by
  obtain ⟨n, o, fp, rep, obsT⟩ := typed
  cases n with
  | zero => cases rep
  | succ n =>
    cases rep with
    | ref lookup' children =>
      rw [lookup] at lookup'
      cases lookup'
      intro w member
      obtain ⟨o', cells, witness, _⟩ :=
        Ownership.FlatFragment.FiniteReach.representsMany_member children member
      have typedElements := obsTyped_list_elements obsT
      obtain ⟨i, ws_i⟩ := List.mem_iff_getElem?.mp member
      obtain ⟨o'', os_i⟩ := index_of_same_length (representsMany_length children) ws_i
      obtain ⟨cs', witness'⟩ := representsMany_index _ children ws_i os_i
      exact ⟨n, o'', cs', witness', typedElements o'' (List.mem_of_getElem? os_i)⟩

/-- Every shaped value is typed. -/
theorem valueTyped_of_allocated {ds : List Decl} {heap : Heap} {w : Value} {ty : Ty}
    (shape : AllocatedFlatValue heap w ty) : ValueTyped ds heap w ty := by
  induction shape with
  | int integer => exact ⟨1, .int integer, [], .int, by simp [obsTyped]⟩
  | list root ws t lookup _ ih => exact valueTyped_list_of_elements lookup (fun w member => ih w member)
  | chain root integers lookup => exact allocated_integer_chain_typed ds lookup
  | record ws ts len _ ih =>
    exact valueTyped_record_of_fields len (fun i w t ws_i ts_i => ih i w t ws_i ts_i)
  | ok e s w _ ih =>
    obtain ⟨n, o, fp, rep, typed⟩ := ih
    cases n with
    | zero => cases rep
    | succ m =>
      refine ⟨m + 2, .record [.int 1, .int 0, o], fp, ?_, ?_⟩
      · have many : RepresentsMany heap (m + 1) [.int 1, .int 0, w] [.int 1, .int 0, o]
            ([] ++ ([] ++ (fp ++ []))) := .cons .int (.cons .int (.cons rep .nil))
        simpa using Represents.record many
      · simpa [obsTyped] using typed
  | err e s w _ ih =>
    obtain ⟨n, o, fp, rep, typed⟩ := ih
    cases n with
    | zero => cases rep
    | succ m =>
      refine ⟨m + 2, .record [.int 0, o, .int 0], fp, ?_, ?_⟩
      · have many : RepresentsMany heap (m + 1) [.int 0, w, .int 0] [.int 0, o, .int 0]
            ([] ++ (fp ++ ([] ++ []))) := .cons .int (.cons rep (.cons .int .nil))
        simpa using Represents.record many
      · simpa [obsTyped] using typed

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

theorem named_nil {gamma : Naming} {c : Nat} (names : named gamma [] c) : False := by
  obtain ⟨_, member, _⟩ := names
  simp at member

theorem namesAt_bottom (q : Path) : namesAt .bottom q = [] := by
  cases q with
  | nil => simp [namesAt, Abstract.cellsAt, Abstract.paths]
  | cons step rest => cases step <;> simp [namesAt]

/-- The bottom of dead code describes a value with no array; it describes every field of such a record. -/
theorem describes_bottom_field {gamma : Naming} {heap : Heap} {ws : List Value} {i : Nat} {w1 : Value}
    (described : Describes gamma heap .bottom (.record ws)) (ws_i : ws[i]? = some w1) :
    Describes gamma heap .bottom w1 := by
  refine ⟨⟨?_, ?_⟩, ?_⟩
  · intro q c located
    have names := described.1.1 (.field i :: q) c (.field ws_i located)
    rw [namesAt_bottom] at names
    exact (named_nil names).elim
  · intro q cs e ex w'' shape
    rw [atPath_bottom] at shape
    cases shape
  · cases described.2 with
    | record fields => simpa [atPath_bottom] using fields i w1 ws_i

theorem describes_bottom_project {gamma : Naming} {heap : Heap} {w w' : Value} {p : Path}
    (described : Describes gamma heap .bottom w) (projected : projectVal w p = some w') :
    Describes gamma heap .bottom w' := by
  induction p generalizing w with
  | nil =>
    simp [projectVal] at projected
    subst projected
    exact described
  | cons step rest ih =>
    cases step <;> cases w <;> simp [projectVal] at projected
    rename_i i' ws
    cases h' : ws[i']? with
    | none => simp [h'] at projected
    | some w1 =>
      simp [h'] at projected
      exact ih (describes_bottom_field described h') projected

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
      rcases flatAbstract_record shape with rfl | ⟨as, rfl, len, fields⟩
      · rw [atPath_bottom]
        exact describes_bottom_project described projected
      · obtain ⟨a', as_i, shape'⟩ := flatAbstract_record_field len fields h
        cases w <;> simp [projectVal] at projected
        rename_i ws
        cases h' : ws[i']? with
        | none => simp [h'] at projected
        | some w1 =>
          simp [h'] at projected
          simp only [Abstract.atPath, as_i, Option.getD_some]
          exact ih shape' at_p (describes_field described as_i h') projected

/-- The tags of a projection along a typed path. -/
theorem resultTags_project {tk t : Ty} {a : Abstract} {w w' : Value} {p : Path}
    (tags : ResultTags tk a w) (shape : FlatAbstract tk a) (at_p : tyAt tk p = some t)
    (projected : projectVal w p = some w') : ResultTags t (a.atPath p) w' := by
  induction p generalizing tk a w with
  | nil =>
    simp [tyAt] at at_p
    subst at_p
    simp [projectVal] at projected
    subst projected
    simpa [Abstract.atPath] using tags
  | cons step rest ih =>
    cases step <;> cases tk <;> simp [tyAt] at at_p
    rename_i i' ts
    cases h : ts[i']? with
    | none => simp [h] at at_p
    | some t' =>
      simp [h] at at_p
      cases tags with
      | record _ as ws _ tagFields =>
        cases shape with
        | record _ _ len fields =>
          obtain ⟨a', as_i, shape'⟩ := flatAbstract_record_field len fields h
          simp [projectVal] at projected
          cases h' : ws[i']? with
          | none => simp [h'] at projected
          | some w1 =>
            simp [h'] at projected
            simp only [Abstract.atPath, as_i, Option.getD_some]
            exact ih (tagFields i' t' a' w1 h as_i h') shape' at_p projected

/-- The checker's reading of an atom from its root binding: every record on
the path is one, because the binding holds a value there (its tags). -/
theorem abstractAtom_of_root {aenv : Env Abstract} {a : Atom} {k : Var} {p : Path}
    {a0 : Abstract} {tk ty : Ty} {w w' : Value}
    (root : atomRoot a = some (k, p)) (found : aenv.lookup k = some a0)
    (shape : FlatAbstract tk a0) (tags : ResultTags tk a0 w) (projected : projectVal w p = some w')
    (at_p : tyAt tk p = some ty) :
    abstractAtom aenv a = .ok (a0.atPath p) := by
  induction a generalizing k p ty w' with
  | int n => simp [atomRoot] at root
  | var v =>
    simp [atomRoot] at root
    obtain ⟨rfl, rfl⟩ := root
    simp [abstractAtom, lookup, found, Abstract.atPath]
  | field a i ih =>
    obtain ⟨p0, inner, rfl⟩ := atomRoot_field root
    obtain ⟨fs, at_p0, at_i⟩ := tyAt_snoc_inv at_p
    obtain ⟨ws0, projected0, _⟩ := projectVal_snoc_inv projected
    have run := ih inner found projected0 at_p0
    have shape0 := flatAbstract_atPath shape at_p0
    have tags0 := resultTags_project tags shape at_p0 projected0
    rw [atPath_snoc_of_tyAt shape at_p]
    generalize eq : a0.atPath p0 = v at run shape0 tags0 ⊢
    cases tags0 with
    | record _ as _ _ _ =>
      cases shape0 with
      | record _ _ len fields =>
        obtain ⟨a', as_i, _⟩ := flatAbstract_record_field len fields at_i
        simp [abstractAtom, run, as_i, Option.toExcept, Abstract.atPath]

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
theorem corresponds_ref_frame {heap : Heap} {next : Heap} {o : Observation} {root : Nat} {integers : List Int}
    (lookupRoot : heap[root]? = some (heapInts integers))
    (paired : Corresponds heap o (.ref root)) (same : next[root]? = heap[root]?) :
    Corresponds next o (.ref root) := by
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

/-! ### The three slots of a result -/

theorem getElem?_three {α : Type} {a b c x : α} {i : Nat} (at_i : [a, b, c][i]? = some x) :
    (i = 0 ∧ x = a) ∨ (i = 1 ∧ x = b) ∨ (i = 2 ∧ x = c) := by
  rcases i with _ | _ | _ | i <;> simp at at_i <;> simp [at_i]

theorem three_pair {α β : Type} {a0 a1 a2 : α} {b0 b1 b2 : β} {i : Nat} {x : α} {y : β}
    (as_i : [a0, a1, a2][i]? = some x) (bs_i : [b0, b1, b2][i]? = some y) :
    (x = a0 ∧ y = b0) ∨ (x = a1 ∧ y = b1) ∨ (x = a2 ∧ y = b2) := by
  rcases i with _ | _ | _ | i <;> simp at as_i bs_i <;> simp [as_i, bs_i]

/-- Any abstract describes an integer: it has no array and no closure. -/
theorem integer_described_any {gamma : Naming} {heap : Heap} (a : Abstract) (integer : Int) :
    Describes gamma heap a (.int integer) := by
  refine ⟨⟨?_, ?_⟩, ClosureAgreement.int a integer⟩
  · intro path address located
    cases located
  · intro path roots element certificate value _ located n o fp rep
    cases located with
    | here =>
      cases rep
      exact ⟨fun _ => List.nodup_nil, fun _ p c _ located' => by cases located'⟩

/-- A binding that holds a value is live code: its abstract is not bottom. -/
theorem resultTags_ne_bottom {t : Ty} {a : Abstract} {w : Value} (tags : ResultTags t a w) :
    a ≠ .bottom := by
  cases tags <;> simp

/-- The checker's equality test against bottom: `Abstract`'s `BEq` is not lawful, so this is a lemma. -/
theorem eq_bottom_of_beq {a : Abstract} (h : (a == .bottom) = true) : a = .bottom := by
  cases a <;> simp [BEq.beq, Abstract.equal] at h ⊢

/-! ### Arrays of flat values -/

/-- An array corresponds to the list of its elements' observations. -/
theorem corresponds_list_of_elements {heap : Heap} {root : Nat} {ws : List Value} {os : List Observation}
    (lookup : heap[root]? = some ws) (len : os.length = ws.length)
    (elements : ∀ (i : Nat) (o : Observation) (w : Value), os[i]? = some o → ws[i]? = some w →
      Corresponds heap o w) :
    Corresponds heap (.list os) (.ref root) := by
  intro n enough
  rw [Observation.depth] at enough
  cases n with
  | zero => omega
  | succ m =>
    have children := container_children_depth os m enough
    obtain ⟨cs, many⟩ := representsMany_of_pointwise len.symm (fun i w o ws_i os_i =>
      represents_of_snapshot m w o
        (elements i o w os_i ws_i m (children o (List.mem_of_getElem? os_i))))
    exact snapshot_of_represents (.ref lookup many)

/-- The observation of an array is the list of its elements' observations. -/
theorem corresponds_list_elements {heap : Heap} {root : Nat} {ws : List Value} {o : Observation}
    (lookup : heap[root]? = some ws) (paired : Corresponds heap o (.ref root)) :
    ∃ os, o = .list os ∧ os.length = ws.length ∧
      ∀ (i : Nat) (o' : Observation) (w' : Value), os[i]? = some o' → ws[i]? = some w' →
        Corresponds heap o' w' := by
  have observed := paired o.depth (Nat.le_refl _)
  cases depth : o.depth with
  | zero => rw [depth] at observed; simp [snapshot] at observed
  | succ d =>
    rw [depth] at observed
    obtain ⟨cs, rep⟩ := represents_of_snapshot (d + 1) (.ref root) o observed
    cases rep with
    | ref lookup' children =>
      rw [lookup] at lookup'
      cases lookup'
      refine ⟨_, rfl, (representsMany_length children).symm, ?_⟩
      intro i o' w' os_i ws_i
      obtain ⟨cells, witness⟩ := representsMany_index _ children ws_i os_i
      exact corresponds_of_represents witness

/-! ### Arrays of values: no array reaches itself, and a write at a root
leaves its elements' paths alone (slice 2b of #522) -/

/-- A reference reached inside a finite expansion has a finite expansion of
its own, at most as deep. -/
theorem represents_reach_sub {heap : Heap} {n : Nat} {v w : Value} {o : Observation} {fp : List Nat}
    (represented : Represents heap n v o fp) (reachable : Reaches heap v w) :
    ∃ m, m ≤ n ∧ ∃ o' fp', Represents heap m w o' fp' := by
  induction n generalizing v o fp with
  | zero => cases represented
  | succ n ih =>
    cases reachable with
    | refl => exact ⟨n + 1, Nat.le_refl _, o, fp, represented⟩
    | element lookup member childReach =>
      cases represented with
      | ref lookup' children =>
        rw [lookup'] at lookup
        cases lookup
        obtain ⟨o', fp', child, _⟩ :=
          Ownership.FlatFragment.FiniteReach.representsMany_member children member
        obtain ⟨m, le, o'', fp'', found⟩ := ih child childReach
        exact ⟨m, Nat.le_succ_of_le le, o'', fp'', found⟩
    | field member childReach =>
      cases represented with
      | record children =>
        obtain ⟨o', fp', child, _⟩ :=
          Ownership.FlatFragment.FiniteReach.representsMany_member children member
        obtain ⟨m, le, o'', fp'', found⟩ := ih child childReach
        exact ⟨m, Nat.le_succ_of_le le, o'', fp'', found⟩
    | capture member childReach =>
      cases represented with
      | closure children =>
        obtain ⟨o', fp', child, _⟩ :=
          Ownership.FlatFragment.FiniteReach.representsMany_member children member
        obtain ⟨m, le, o'', fp'', found⟩ := ih child childReach
        exact ⟨m, Nat.le_succ_of_le le, o'', fp'', found⟩

/-- No element of an array with a finite expansion reaches the array: an
expansion of the array inside one of its elements is shallower, and so on
down, which a finite depth refuses. -/
theorem no_element_reaches_root {heap : Heap} {root : Nat} {xs : List Value} {x : Value}
    (lookup : heap[root]? = some xs) (member : x ∈ xs) :
    ∀ n m, m ≤ n → ∀ (o : Observation) (fp : List Nat),
      Represents heap m (.ref root) o fp → ¬ Reaches heap x (.ref root) := by
  intro n
  induction n with
  | zero =>
    intro m le o fp represented
    obtain rfl := Nat.le_zero.mp le
    cases represented
  | succ n ih =>
    intro m le o fp represented reachable
    rcases Nat.lt_or_ge m (n + 1) with lt | ge
    · exact ih m (Nat.le_of_lt_succ lt) o fp represented reachable
    · obtain rfl : m = n + 1 := Nat.le_antisymm le ge
      cases represented with
      | ref lookup' children =>
        rw [lookup'] at lookup
        cases lookup
        obtain ⟨o', fp', child, _⟩ :=
          Ownership.FlatFragment.FiniteReach.representsMany_member children member
        obtain ⟨m', le', o'', fp'', found⟩ := represents_reach_sub child reachable
        exact ih m' le' o'' fp'' found reachable

/-- Reaching survives a write at an address the value does not reach. -/
theorem reaches_frame_of_unreached {heap : Heap} {root : Nat} {stored : List Value} {y w : Value}
    (reach : Reaches heap y w) (apart : ∀ c, Reaches heap y (.ref c) → c ≠ root) :
    Reaches (heap.set! root stored) y w := by
  induction reach with
  | refl v => exact .refl v
  | @element c xs x w' lookup member inner ih =>
    have different : c ≠ root := apart c (.refl _)
    exact .element (by rw [lookup_set_other heap root stored different]; exact lookup) member
      (ih (fun c' r => apart c' (.element lookup member r)))
  | field member inner ih => exact .field member (ih (fun c' r => apart c' (.field member r)))
  | capture member inner ih => exact .capture member (ih (fun c' r => apart c' (.capture member r)))

/-- A path survives a write at an address the value does not reach. -/
theorem atPath_frame_of_unreached {heap : Heap} {root : Nat} {stored : List Value} {y w : Value} {q : Path}
    (located : AtPath heap y q w) (apart : ∀ c, Reaches heap y (.ref c) → c ≠ root) :
    AtPath (heap.set! root stored) y q w := by
  induction located with
  | here v => exact .here v
  | @element c xs x q' w' lookup member inner ih =>
    have different : c ≠ root := apart c (.refl _)
    exact .element (by rw [lookup_set_other heap root stored different]; exact lookup) member
      (ih (fun c' r => apart c' (.element lookup member r)))
  | @field xs i x q' w' xs_i inner ih =>
    exact .field xs_i (ih (fun c' r => apart c' (.field (List.mem_of_getElem? xs_i) r)))
  | @capture d caps i x q' w' caps_i inner ih =>
    exact .capture caps_i (ih (fun c' r => apart c' (.capture (List.mem_of_getElem? caps_i) r)))
  | @env d caps x w' member reach =>
    exact .env member (reaches_frame_of_unreached reach
      (fun c' r => apart c' (.capture member r)))

/-- An element of an array with a finite expansion keeps its paths through a
write at the array's root. -/
theorem atPath_element_after_write {heap : Heap} {root : Nat} {xs stored : List Value} {x w : Value}
    {q : Path} {n : Nat} {o : Observation} {fp : List Nat}
    (represented : Represents heap n (.ref root) o fp) (lookup : heap[root]? = some xs)
    (member : x ∈ xs) (located : AtPath heap x q w) : AtPath (heap.set! root stored) x q w := by
  refine atPath_frame_of_unreached located (fun c reach same => ?_)
  subst same
  exact no_element_reaches_root lookup member n n (Nat.le_refl _) o fp represented reach

/-! ### Heaps that agree on what a value reaches (slice 2b of #522) -/

/-- A reached value sits at some path: every reach step has a path step. -/
theorem atPath_of_reaches {heap : Heap} {y w : Value}
    (reach : Reaches heap y w) : ∃ q, AtPath heap y q w := by
  induction reach with
  | refl v => exact ⟨[], .here _⟩
  | @element c' xs x w lookup member inner ih =>
    obtain ⟨q, located⟩ := ih
    exact ⟨.element :: q, .element lookup member located⟩
  | @field xs x w member inner ih =>
    obtain ⟨q, located⟩ := ih
    obtain ⟨i, xs_i⟩ := List.mem_iff_getElem?.mp member
    exact ⟨.field i :: q, .field xs_i located⟩
  | @capture d caps x w member inner ih =>
    obtain ⟨q, located⟩ := ih
    obtain ⟨i, caps_i⟩ := List.mem_iff_getElem?.mp member
    exact ⟨.capture i :: q, .capture caps_i located⟩

/-- A reached array sits at some path. -/
theorem arrayAt_of_reaches {heap : Heap} {y : Value} {c : Nat}
    (reach : Reaches heap y (.ref c)) : ∃ q, ArrayAt heap y q c :=
  atPath_of_reaches reach

/-- Two heaps that agree on every array a value reaches give it the same
reach, in both directions. -/
theorem reaches_of_agree {heap next : Heap} {y w : Value}
    (agree : ∀ c, Reaches heap y (.ref c) → next[c]? = heap[c]?)
    (reach : Reaches heap y w) : Reaches next y w := by
  induction reach with
  | refl v => exact .refl v
  | @element c xs x w' lookup member inner ih =>
    exact .element (by rw [agree c (.refl _)]; exact lookup) member
      (ih (fun c' r => agree c' (.element lookup member r)))
  | field member inner ih => exact .field member (ih (fun c' r => agree c' (.field member r)))
  | capture member inner ih => exact .capture member (ih (fun c' r => agree c' (.capture member r)))

theorem reaches_of_agree_rev {heap next : Heap} {y w : Value}
    (agree : ∀ c, Reaches heap y (.ref c) → next[c]? = heap[c]?)
    (reach : Reaches next y w) : Reaches heap y w := by
  induction reach with
  | refl v => exact .refl v
  | @element c xs x w' lookup member inner ih =>
    have lookupHeap : heap[c]? = some xs := by rw [← agree c (.refl _)]; exact lookup
    exact .element lookupHeap member
      (ih (fun c' r => agree c' (.element lookupHeap member r)))
  | field member inner ih => exact .field member (ih (fun c' r => agree c' (.field member r)))
  | capture member inner ih => exact .capture member (ih (fun c' r => agree c' (.capture member r)))

theorem atPath_of_agree {heap next : Heap} {y w : Value} {q : Path}
    (agree : ∀ c, Reaches heap y (.ref c) → next[c]? = heap[c]?)
    (located : AtPath heap y q w) : AtPath next y q w := by
  induction located with
  | here v => exact .here v
  | @element c xs x q' w' lookup member inner ih =>
    exact .element (by rw [agree c (.refl _)]; exact lookup) member
      (ih (fun c' r => agree c' (.element lookup member r)))
  | @field xs i x q' w' xs_i inner ih =>
    exact .field xs_i (ih (fun c' r => agree c' (.field (List.mem_of_getElem? xs_i) r)))
  | @capture d caps i x q' w' caps_i inner ih =>
    exact .capture caps_i (ih (fun c' r => agree c' (.capture (List.mem_of_getElem? caps_i) r)))
  | @env d caps x w' member reach =>
    exact .env member (reaches_of_agree (fun c' r => agree c' (.capture member r)) reach)

/-- A reach in the heap after a step at one hole either avoids the hole, and is
a reach before the step, or passes the hole and continues from one of its new
elements. -/
theorem reaches_split_at_hole {heap next : Heap} {hole : Nat} {stored : List Value}
    (holeAt : next[hole]? = some stored)
    (frame : ∀ c, c ≠ hole → next[c]? = heap[c]?)
    {w u : Value} (reach : Reaches next w u) :
    Reaches heap w u ∨ ∃ x ∈ stored, Reaches next x u := by
  induction reach with
  | refl v => exact Or.inl (.refl v)
  | @element c xs x w' lookup member inner ih =>
    rcases ih with before | viaHole
    · by_cases same : c = hole
      · subst same
        rw [holeAt] at lookup
        cases lookup
        exact Or.inr ⟨x, member, inner⟩
      · rw [frame c same] at lookup
        exact Or.inl (.element lookup member before)
    · exact Or.inr viaHole
  | field member _ ih =>
    rcases ih with before | viaHole
    · exact Or.inl (.field member before)
    · exact Or.inr viaHole
  | capture member _ ih =>
    rcases ih with before | viaHole
    · exact Or.inl (.capture member before)
    · exact Or.inr viaHole

theorem atPath_of_agree_rev {heap next : Heap} {y w : Value} {q : Path}
    (agree : ∀ c, Reaches heap y (.ref c) → next[c]? = heap[c]?)
    (located : AtPath next y q w) : AtPath heap y q w := by
  induction located with
  | here v => exact .here v
  | @element c xs x q' w' lookup member inner ih =>
    have lookupHeap : heap[c]? = some xs := by rw [← agree c (.refl _)]; exact lookup
    exact .element lookupHeap member
      (ih (fun c' r => agree c' (.element lookupHeap member r)))
  | @field xs i x q' w' xs_i inner ih =>
    exact .field xs_i (ih (fun c' r => agree c' (.field (List.mem_of_getElem? xs_i) r)))
  | @capture d caps i x q' w' caps_i inner ih =>
    exact .capture caps_i (ih (fun c' r => agree c' (.capture (List.mem_of_getElem? caps_i) r)))
  | @env d caps x w' member reach =>
    exact .env member (reaches_of_agree_rev (fun c' r => agree c' (.capture member r)) reach)

/-- An element of an array with a finite expansion sees the same heap before
and after a write at the array's root. -/
theorem element_agree_after_write {heap : Heap} {root : Nat} {xs stored : List Value} {x : Value}
    {n : Nat} {o : Observation} {fp : List Nat}
    (represented : Represents heap n (.ref root) o fp) (lookup : heap[root]? = some xs)
    (member : x ∈ xs) : ∀ c, Reaches heap x (.ref c) → (heap.set! root stored)[c]? = heap[c]? := by
  intro c reach
  refine lookup_set_other heap root stored (fun same => ?_)
  subst same
  exact no_element_reaches_root lookup member n n (Nat.le_refl _) o fp represented reach

/-- A value whose arrays a write does not touch keeps its finite expansion. -/
theorem represents_of_agree {heap next : Heap} {y : Value} {n : Nat} {o : Observation} {fp : List Nat}
    (agree : ∀ c, Reaches heap y (.ref c) → next[c]? = heap[c]?)
    (represented : Represents heap n y o fp) : Represents next n y o fp :=
  represents_frame represented (fun c member =>
    agree c (Ownership.FlatFragment.Support.represents_footprint_reaches represented c member))

/-- Cells that pass the demand's Known test hold no unknown origin. -/
theorem unknown_not_mem_of_known {cs : List Origin}
    (knownAll : ∀ o ∈ cs, known o = true) : Origin.unknown ∉ cs := by
  intro member
  have := knownAll _ member
  simp [known, Origin.base] at this

/-! ### Descriptions: weaker abstracts, agreeing heaps, a list from its elements (slice 2b of #522) -/

/-- A value at a path is reached. -/
theorem reaches_of_atPath {heap : Heap} {y w : Value} {q : Path}
    (located : AtPath heap y q w) : Reaches heap y w := by
  induction located with
  | here v => exact .refl v
  | element lookup member _ ih => exact .element lookup member ih
  | field xs_i _ ih => exact .field (List.mem_of_getElem? xs_i) ih
  | capture caps_i _ ih => exact .capture (List.mem_of_getElem? caps_i) ih
  | env member reach => exact .capture member reach

/-- Reaching composes. -/
theorem reaches_trans {heap : Heap} {u v w : Value}
    (first : Reaches heap u v) (second : Reaches heap v w) : Reaches heap u w := by
  induction first with
  | refl _ => exact second
  | element lookup member _ ih => exact .element lookup member (ih second)
  | field member _ ih => exact .field member (ih second)
  | capture member _ ih => exact .capture member (ih second)

/-- An abstract that names at least what another names, path by path,
covers what the other covers. -/
theorem covers_mono {gamma : Naming} {heap : Heap} {a b : Abstract} {w : Value}
    (names : ∀ q o, o ∈ namesAt a q → o ∈ namesAt b q)
    (covers : Covers gamma heap a w) : Covers gamma heap b w := by
  intro q c located
  obtain ⟨o, member, address⟩ := covers q c located
  exact ⟨o, names q o member, address⟩

/-- An abstract whose certificates are weaker at every list path certifies
what a stronger one certifies. -/
theorem certified_mono {heap : Heap} {a b : Abstract} {w : Value}
    (weaker : ∀ q cs e ex, b.atPath q = .list cs e ex →
      ∃ cs' e' ex', a.atPath q = .list cs' e' ex' ∧
        (ex.deep = true → ex'.deep = true) ∧ (ex.spine = true → ex'.spine = true))
    (cert : CertifiedExclusive heap a w) : CertifiedExclusive heap b w := by
  intro q cs e ex w' shape located n o fp rep
  obtain ⟨cs', e', ex', shape', deep, spine⟩ := weaker q cs e ex shape
  obtain ⟨nodup, once⟩ := cert q cs' e' ex' w' shape' located n o fp rep
  exact ⟨fun h => nodup (deep h), fun h => once (spine h)⟩

/-- Covering survives a heap change that touches no array the value reaches. -/
theorem covers_of_agree {gamma : Naming} {heap next : Heap} {a : Abstract} {w : Value}
    (agree : ∀ c, Reaches heap w (.ref c) → next[c]? = heap[c]?)
    (covers : Covers gamma heap a w) : Covers gamma next a w := by
  intro q c located
  exact covers q c (atPath_of_agree_rev agree located)

/-- The certificates survive a heap change that touches no array the value reaches. -/
theorem certified_of_agree {heap next : Heap} {a : Abstract} {w : Value}
    (agree : ∀ c, Reaches heap w (.ref c) → next[c]? = heap[c]?)
    (cert : CertifiedExclusive heap a w) : CertifiedExclusive next a w := by
  intro q cs e ex w' shape located n o fp rep
  have locatedHeap : AtPath heap w q w' := atPath_of_agree_rev agree located
  have agree' : ∀ c, Reaches heap w' (.ref c) → next[c]? = heap[c]? :=
    fun c r => agree c (reaches_trans (reaches_of_atPath locatedHeap) r)
  have repHeap : Represents heap n w' o fp :=
    represents_frame rep (fun c member =>
      (agree' c (reaches_of_agree_rev agree'
        (Ownership.FlatFragment.Support.represents_footprint_reaches rep c member))).symm)
  obtain ⟨nodup, once⟩ := cert q cs e ex w' shape locatedHeap n o fp repHeap
  refine ⟨nodup, fun h p c container located' => once h p c container ?_⟩
  exact atPath_of_agree_rev agree' located'

/-- Closure agreement survives a heap change that touches no array the value reaches. -/
theorem closures_of_agree {gamma : Naming} {heap next : Heap} {a : Abstract} {w : Value}
    (agree : ∀ c, Reaches heap w (.ref c) → next[c]? = heap[c]?)
    (agreement : ClosureAgreement gamma heap a w) : ClosureAgreement gamma next a w := by
  induction agreement with
  | int a n => exact .int a n
  | record fields ih =>
    refine .record (fun i x xs_i => ih i x xs_i ?_)
    exact fun c r => agree c (.field (List.mem_of_getElem? xs_i) r)
  | @array a c xs lookup _ ih =>
    refine .array (by rw [agree c (.refl _)]; exact lookup) (fun x member => ih x member ?_)
    exact fun c' r => agree c' (.element lookup member r)
  | @known roots alts id caps abs alt len shallow _ ih =>
    refine .known alt len (fun k => ?_) (fun k => ih k ?_)
    · have agreeK : ∀ c, Reaches heap (caps[k]?.getD (.int 0)) (.ref c) → next[c]? = heap[c]? := by
        intro c r
        cases h : caps[k]? with
        | none => rw [h] at r; simp at r; cases r
        | some x => rw [h] at r; exact agree c (.capture (List.mem_of_getElem? h) r)
      exact ⟨covers_of_agree agreeK (shallow k).1, certified_of_agree agreeK (shallow k).2⟩
    · intro c r
      cases h : caps[k]? with
      | none => rw [h] at r; simp at r; cases r
      | some x => rw [h] at r; exact agree c (.capture (List.mem_of_getElem? h) r)
  | symbolic slot ty roots es id caps => exact .symbolic slot ty roots es id caps
  | unknown elem ex v top => exact .unknown elem ex v top

theorem describes_of_agree {gamma : Naming} {heap next : Heap} {a : Abstract} {w : Value}
    (agree : ∀ c, Reaches heap w (.ref c) → next[c]? = heap[c]?)
    (described : Describes gamma heap a w) : Describes gamma next a w :=
  ⟨⟨covers_of_agree agree described.1.1, certified_of_agree agree described.1.2⟩,
    closures_of_agree agree described.2⟩

/-- A list whose roots are named and whose elements are described covers its
value, when its roots hold no unknown origin. -/
theorem list_covers_of_elements {gamma : Naming} {heap : Heap} {cs : List Origin} {e : Abstract}
    {ex : Certificate} {root : Nat} {ys : List Value}
    (rootNamed : named gamma cs root) (noUnknown : Origin.unknown ∉ cs)
    (lookup : heap[root]? = some ys) (elements : ∀ y ∈ ys, Covers gamma heap e y) :
    Covers gamma heap (.list cs e ex) (.ref root) := by
  intro q c located
  cases located with
  | here => exact named_list_root rootNamed
  | element lookup' member inner =>
    rw [lookup] at lookup'
    cases lookup'
    have := elements _ member _ c inner
    simpa [namesAt, noUnknown] using this

/-- Elements with closure agreement give the array closure agreement. -/
theorem list_closures_of_elements {gamma : Naming} {heap : Heap} {cs : List Origin} {e : Abstract}
    {ex : Certificate} {root : Nat} {ys : List Value}
    (lookup : heap[root]? = some ys) (elements : ∀ y ∈ ys, ClosureAgreement gamma heap e y) :
    ClosureAgreement gamma heap (.list cs e ex) (.ref root) := by
  refine .array lookup (fun y member => ?_)
  simpa [Abstract.atPath] using elements y member

/-- Every array of a shaped value is allocated. -/
theorem arrayAt_bound {heap : Heap} {w : Value} {ty : Ty} {q : Path} {c : Nat}
    (shape : AllocatedFlatValue heap w ty) (located : ArrayAt heap w q c) : c < heap.size :=
  allocated_reach_bound shape (reaches_of_atPath located)

/-- A path through record fields and closure captures reads no heap: the
value at it is the same in every heap. -/
theorem atPath_immutable_everywhere {heap : Heap} {w v : Value} {q : Path}
    (immutable : immutablePath q = true) (located : AtPath heap w q v) :
    ∀ heap' : Heap, AtPath heap' w q v := by
  induction located with
  | here v => intro heap'; exact .here v
  | element _ _ _ _ => simp [immutablePath] at immutable
  | @field xs i x q' w' xs_i _ ih =>
    intro heap'
    exact .field xs_i (ih (by simpa [immutablePath] using immutable) heap')
  | @capture d caps i x q' w' caps_i _ ih =>
    intro heap'
    exact .capture caps_i (ih (by simpa [immutablePath] using immutable) heap')
  | env _ _ => simp [immutablePath] at immutable

theorem arrayAt_immutable_everywhere {heap : Heap} {w : Value} {q : Path} {c : Nat}
    (immutable : immutablePath q = true) (located : ArrayAt heap w q c) :
    ∀ heap' : Heap, ArrayAt heap' w q c :=
  atPath_immutable_everywhere immutable located

/-- Correspondence survives a heap change that touches no array the value reaches. -/
theorem corresponds_of_agree {heap next : Heap} {o : Observation} {w : Value}
    (agree : ∀ c, Reaches heap w (.ref c) → next[c]? = heap[c]?)
    (paired : Corresponds heap o w) : Corresponds next o w := by
  intro n enough
  have observed := paired n enough
  cases n with
  | zero => simp [snapshot] at observed
  | succ m =>
    obtain ⟨cs, rep⟩ := represents_of_snapshot (m + 1) w o observed
    exact snapshot_of_represents (represents_of_agree agree rep)

/-- Covering survives a naming that keeps the names of every allocated array. -/
theorem covers_naming_same {gamma gamma' : Naming} {heap : Heap} {a : Abstract} {w : Value} {bound : Nat}
    (namingSame : ∀ origin cell, cell < bound → (cell ∈ gamma' origin ↔ cell ∈ gamma origin))
    (below : ∀ c, Reaches heap w (.ref c) → c < bound)
    (covers : Covers gamma heap a w) : Covers gamma' heap a w := by
  intro q c located
  exact named_same_of_naming namingSame (below c (reaches_of_atPath located)) (covers q c located)

/-- A shaped value holds no closure, so every abstract agrees with it on closures. -/
theorem closureAgreement_of_allocated {gamma : Naming} {heap : Heap} {w : Value} {ty : Ty}
    (shape : AllocatedFlatValue heap w ty) : ∀ a, ClosureAgreement gamma heap a w := by
  induction shape with
  | int integer => intro a; exact .int a integer
  | list root ws t lookup _ ih => intro a; exact .array lookup (fun w member => ih w member _)
  | chain root integers lookup =>
    intro a
    refine .array lookup (fun w member => ?_)
    obtain ⟨i, _, rfl⟩ := List.mem_map.mp member
    exact .int _ i
  | record ws ts len _ ih =>
    intro a
    refine .record (fun i w ws_i => ?_)
    have bound : i < ts.length := by
      rw [← len]
      exact (List.getElem?_eq_some_iff.mp ws_i).1
    exact ih i w ts[i] ws_i (List.getElem?_eq_getElem bound) _
  | ok e s w _ ih =>
    intro a
    refine .record (fun i x at_i => ?_)
    rcases getElem?_three at_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
    · exact .int _ 1
    · exact .int _ 0
    · exact ih _
  | err e s w _ ih =>
    intro a
    refine .record (fun i x at_i => ?_)
    rcases getElem?_three at_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
    · exact .int _ 0
    · exact ih _
    · exact .int _ 0

/-- A description of a shaped value survives a naming that keeps the names of
every allocated array. -/
theorem describes_naming_same {gamma gamma' : Naming} {heap : Heap} {a : Abstract} {w : Value} {ty : Ty}
    {bound : Nat} (shape : AllocatedFlatValue heap w ty)
    (namingSame : ∀ origin cell, cell < bound → (cell ∈ gamma' origin ↔ cell ∈ gamma origin))
    (below : ∀ c, Reaches heap w (.ref c) → c < bound)
    (described : Describes gamma heap a w) : Describes gamma' heap a w :=
  ⟨⟨covers_naming_same namingSame below described.1.1, described.1.2⟩, closureAgreement_of_allocated shape a⟩

/-! ### The footprint of a list after a push: no array twice (slice 2b of #522) -/

/-- The expansion of an appended list splits at the seam. -/
theorem representsMany_append_split {heap : Heap} {k : Nat} {as bs : List Value} {os : List Observation}
    {cs : List Nat} (represented : RepresentsMany heap k (as ++ bs) os cs) :
    ∃ os1 os2 cs1 cs2, os = os1 ++ os2 ∧ cs = cs1 ++ cs2 ∧
      RepresentsMany heap k as os1 cs1 ∧ RepresentsMany heap k bs os2 cs2 := by
  induction as generalizing os cs with
  | nil => exact ⟨[], os, [], cs, rfl, rfl, .nil, represented⟩
  | cons a as ih =>
    cases represented with
    | cons first rest =>
      obtain ⟨os1, os2, cs1, cs2, rfl, rfl, left, right⟩ := ih rest
      exact ⟨_ :: os1, os2, _ ++ cs1, cs2, rfl, (List.append_assoc _ _ _).symm, .cons first left, right⟩

/-- Values that see the same heap keep their joint expansion, in both directions. -/
theorem representsMany_of_agree {heap next : Heap} {k : Nat} {ys : List Value} {os : List Observation}
    {cs : List Nat} (agree : ∀ y ∈ ys, ∀ c, Reaches heap y (.ref c) → next[c]? = heap[c]?)
    (represented : RepresentsMany heap k ys os cs) : RepresentsMany next k ys os cs :=
  representsMany_frame represented (fun c member => by
    obtain ⟨y, memberY, reach⟩ :=
      Ownership.FlatFragment.Support.representsMany_footprint_reaches represented c member
    exact agree y memberY c reach)

theorem representsMany_of_agree_rev {heap next : Heap} {k : Nat} {ys : List Value} {os : List Observation}
    {cs : List Nat} (agree : ∀ y ∈ ys, ∀ c, Reaches heap y (.ref c) → next[c]? = heap[c]?)
    (represented : RepresentsMany next k ys os cs) : RepresentsMany heap k ys os cs :=
  representsMany_frame represented (fun c member => by
    obtain ⟨y, memberY, reach⟩ :=
      Ownership.FlatFragment.Support.representsMany_footprint_reaches represented c member
    exact (agree y memberY c (reaches_of_agree_rev (agree y memberY) reach)).symm)

theorem represents_of_agree_rev {heap next : Heap} {y : Value} {n : Nat} {o : Observation} {fp : List Nat}
    (agree : ∀ c, Reaches heap y (.ref c) → next[c]? = heap[c]?)
    (represented : Represents next n y o fp) : Represents heap n y o fp :=
  represents_frame represented (fun c member =>
    (agree c (reaches_of_agree_rev agree
      (Ownership.FlatFragment.Support.represents_footprint_reaches represented c member))).symm)

/-- After a push, the list's footprint repeats no array: the old footprint
did not, the item's does not, and the two share no array. -/
theorem pushed_footprint_nodup {heap : Heap} {root : Nat} {xs : List Value} {item : Value}
    {n0 : Nat} {o0 : Observation} {fp0 : List Nat}
    (lookup : heap[root]? = some xs)
    (represented : Represents heap n0 (.ref root) o0 fp0)
    (oldNodup : ∀ n o fp, Represents heap n (.ref root) o fp → fp.Nodup)
    (itemNodup : ∀ n o fp, Represents heap n item o fp → fp.Nodup)
    (apart : ∀ c, Reaches heap (.ref root) (.ref c) → ¬ Reaches heap item (.ref c)) :
    ∀ n o fp, Represents (heap.set! root (xs ++ [item])) n (.ref root) o fp → fp.Nodup := by
  intro n o fp rep
  have agreeOld : ∀ x ∈ xs, ∀ c, Reaches heap x (.ref c) → (heap.set! root (xs ++ [item]))[c]? = heap[c]? :=
    fun x member => element_agree_after_write represented lookup member
  have agreeItem : ∀ c, Reaches heap item (.ref c) → (heap.set! root (xs ++ [item]))[c]? = heap[c]? := by
    intro c reach
    refine lookup_set_other heap root _ (fun same => ?_)
    subst same
    exact apart c (.refl _) reach
  cases rep with
  | ref lookup' children =>
    have bound : root < heap.size := (Array.getElem?_eq_some_iff.mp lookup).1
    have stored : (heap.set! root (xs ++ [item]))[root]? = some (xs ++ [item]) := by simp [bound]
    rw [stored] at lookup'
    cases lookup'
    obtain ⟨os1, os2, cs1, cs2, rfl, rfl, oldChildren, itemChildren⟩ := representsMany_append_split children
    have oldHeap := representsMany_of_agree_rev agreeOld oldChildren
    have oldRoot : Represents heap _ (.ref root) (.list os1) (root :: cs1) := .ref lookup oldHeap
    have oldOk : (root :: cs1).Nodup := oldNodup _ _ _ oldRoot
    cases itemChildren with
    | @cons _ _ _ fp1 _ _ _ itemRep nilRep =>
      cases nilRep
      have itemHeap := represents_of_agree_rev agreeItem itemRep
      have itemOk := itemNodup _ _ _ itemHeap
      rw [List.append_nil]
      -- root :: (cs1 ++ fp1)
      have disjoint : ∀ c, c ∈ root :: cs1 → c ∈ fp1 → False := by
        intro c inOld inItem
        exact apart c (Ownership.FlatFragment.Support.represents_footprint_reaches oldRoot c inOld)
          (Ownership.FlatFragment.Support.represents_footprint_reaches itemHeap c inItem)
      rw [List.nodup_cons] at oldOk ⊢
      refine ⟨fun member => ?_, ?_⟩
      · rcases List.mem_append.mp member with inOld | inItem
        · exact oldOk.1 inOld
        · exact disjoint root List.mem_cons_self inItem
      · exact List.nodup_append.mpr ⟨oldOk.2, itemOk,
          fun c inOld c' inItem same => disjoint c (List.mem_cons_of_mem _ inOld) (same ▸ inItem)⟩

/-! ### The footprint of a list with one item inserted (slice 2b of #522)

A push, a set and a prepend each build a list `as ++ item :: bs` from an old
list `as ++ mid ++ bs` (`mid` is the replaced element of a set, else empty).
The old list's certificates speak of its own footprint; the item's of its
own; the store tests keep the two apart. -/

/-- A representation of a list's elements at a depth that fits them all. -/
theorem representsMany_depth_bound {heap : Heap} {n : Nat} {ys : List Value} {os : List Observation}
    {cs : List Nat} (represented : RepresentsMany heap n ys os cs) : ∀ o ∈ os, o.depth ≤ n := by
  induction ys generalizing os cs with
  | nil => cases represented; intro o member; simp at member
  | cons y ys ih =>
    cases represented with
    | cons first rest =>
      intro o member
      rcases List.mem_cons.mp member with rfl | tail
      · exact represents_depth_bound first
      · exact ih rest o tail

theorem representsMany_raise {heap : Heap} {n target : Nat} {ys : List Value} {os : List Observation}
    {cs : List Nat} (represented : RepresentsMany heap n ys os cs) (le : n ≤ target) :
    RepresentsMany heap target ys os cs :=
  representsMany_of_depth represented
    (fun o member => Nat.le_trans (representsMany_depth_bound represented o member) le)

theorem representsMany_elements_apart {heap next : Heap} {n : Nat} {ys : List Value} {os : List Observation}
    {cs : List Nat} (represented : RepresentsMany next n ys os cs)
    (agree : ∀ y ∈ ys, ∀ c, Reaches heap y (.ref c) → next[c]? = heap[c]?) :
    RepresentsMany heap n ys os cs := representsMany_of_agree_rev agree represented

/-- After the insertion, the list's footprint repeats no array: the old one
did not, the item's does not, and the item shares no array with an old element. -/
theorem inserted_footprint_nodup {heap next : Heap} {root root' : Nat} {as mid bs : List Value} {item : Value}
    {n0 : Nat} {o0 : Observation} {fp0 : List Nat}
    (lookup : heap[root]? = some (as ++ mid ++ bs))
    (lookupNew : next[root']? = some (as ++ item :: bs))
    (represented : Represents heap n0 (.ref root) o0 fp0)
    (agreeOld : ∀ y ∈ as ++ mid ++ bs, ∀ c, Reaches heap y (.ref c) → next[c]? = heap[c]?)
    (agreeItem : ∀ c, Reaches heap item (.ref c) → next[c]? = heap[c]?)
    (rootApart : ∀ z ∈ as ++ item :: bs, ¬ Reaches next z (.ref root'))
    (oldNodup : ∀ n o fp, Represents heap n (.ref root) o fp → fp.Nodup)
    (itemNodup : ∀ n o fp, Represents heap n item o fp → fp.Nodup)
    (apart : ∀ y ∈ as ++ mid ++ bs, ∀ c, Reaches heap item (.ref c) → ¬ Reaches heap y (.ref c)) :
    ∀ n o fp, Represents next n (.ref root') o fp → fp.Nodup := by
  intro n o fp rep
  cases rep with
  | @ref _ _ n' _ _ lookup' children =>
    rw [lookupNew] at lookup'
    cases lookup'
    obtain ⟨os1, os2, cs1, csRest, rfl, rfl, asChildren, restChildren⟩ := representsMany_append_split children
    cases restChildren with
    | @cons _ _ _ fp1 _ _ cs3 itemRep bsChildren =>
      have asHeap := representsMany_elements_apart asChildren
        (fun y member => agreeOld y (by simp [member]))
      have bsHeap := representsMany_elements_apart bsChildren
        (fun y member => agreeOld y (by simp [member]))
      have itemHeap := represents_of_agree_rev agreeItem itemRep
      -- the old list, with the middle part from the given representation
      cases represented with
      | @ref _ _ n1 _ _ lookup0 children0 =>
        rw [lookup] at lookup0
        cases lookup0
        obtain ⟨_, _, _, _, _, _, asMid, _⟩ := representsMany_append_split children0
        obtain ⟨_, osMid, _, csMid, _, _, _, midRep⟩ := representsMany_append_split asMid
        have asRaised := representsMany_raise asHeap (Nat.le_max_left n' n1)
        have bsRaised := representsMany_raise bsHeap (Nat.le_max_left n' n1)
        have midRaised := representsMany_raise midRep (Nat.le_max_right n' n1)
        have oldRep : Represents heap _ (.ref root) _ (root :: ((cs1 ++ csMid) ++ cs3)) :=
          .ref lookup (representsMany_append (representsMany_append asRaised midRaised) bsRaised)
        have oldOk := oldNodup _ _ _ oldRep
        rw [List.nodup_cons] at oldOk
        have partsOk : (cs1 ++ cs3).Nodup :=
          (List.Sublist.append (List.sublist_append_left cs1 csMid) (List.Sublist.refl cs3)).nodup oldOk.2
        have itemOk := itemNodup _ _ _ itemHeap
        have disjointAs : ∀ c, c ∈ cs1 → c ∈ fp1 → False := by
          intro c inAs inItem
          obtain ⟨y, member, reach⟩ :=
            Ownership.FlatFragment.Support.representsMany_footprint_reaches asHeap c inAs
          exact apart y (by simp [member]) c
            (Ownership.FlatFragment.Support.represents_footprint_reaches itemHeap c inItem) reach
        have disjointBs : ∀ c, c ∈ fp1 → c ∈ cs3 → False := by
          intro c inItem inBs
          obtain ⟨y, member, reach⟩ :=
            Ownership.FlatFragment.Support.representsMany_footprint_reaches bsHeap c inBs
          exact apart y (by simp [member]) c
            (Ownership.FlatFragment.Support.represents_footprint_reaches itemHeap c inItem) reach
        rw [List.nodup_cons]
        refine ⟨fun member => ?_, ?_⟩
        · obtain ⟨z, zMember, reach⟩ :=
            Ownership.FlatFragment.Support.representsMany_footprint_reaches children root' member
          exact rootApart z zMember reach
        · rw [List.nodup_append] at partsOk
          obtain ⟨asOk, bsOk, asBs⟩ := partsOk
          refine List.nodup_append.mpr ⟨asOk, ?_, ?_⟩
          · exact List.nodup_append.mpr ⟨itemOk, bsOk, fun c inItem c' inBs same => disjointBs c inItem (same ▸ inBs)⟩
          · intro c inAs c' inRest same
            subst same
            rcases List.mem_append.mp inRest with inItem | inBs
            · exact disjointAs c inAs inItem
            · exact asBs c inAs c inBs rfl

/-- After the insertion, an array at a container position of an element appears
once in the list's footprint: once in the old footprint and not in the item's,
or once in the item's and not in the old one. -/
theorem inserted_footprint_once {heap next : Heap} {root root' : Nat} {as mid bs : List Value} {item : Value}
    {n0 : Nat} {o0 : Observation} {fp0 : List Nat}
    (lookup : heap[root]? = some (as ++ mid ++ bs))
    (lookupNew : next[root']? = some (as ++ item :: bs))
    (represented : Represents heap n0 (.ref root) o0 fp0)
    (agreeOld : ∀ y ∈ as ++ mid ++ bs, ∀ c, Reaches heap y (.ref c) → next[c]? = heap[c]?)
    (agreeItem : ∀ c, Reaches heap item (.ref c) → next[c]? = heap[c]?)
    (rootApart : ∀ z ∈ as ++ item :: bs, ¬ Reaches next z (.ref root'))
    (oldOnce : ∀ n o fp, Represents heap n (.ref root) o fp →
      ∀ p c, containerPath p = true → ArrayAt heap (.ref root) (.element :: p) c → fp.count c = 1)
    (itemOnce : ∀ n o fp, Represents heap n item o fp →
      ∀ p c, containerPath p = true → ArrayAt heap item p c → fp.count c = 1)
    (itemApartOld : ∀ p c, containerPath p = true → ArrayAt heap (.ref root) (.element :: p) c →
      ¬ Reaches heap item (.ref c))
    (oldApartItem : ∀ p c, containerPath p = true → ArrayAt heap item p c →
      ∀ y ∈ as ++ mid ++ bs, ¬ Reaches heap y (.ref c)) :
    ∀ n o fp, Represents next n (.ref root') o fp →
      ∀ p c, containerPath p = true → ArrayAt next (.ref root') (.element :: p) c → fp.count c = 1 := by
  intro n o fp rep p c container located
  cases rep with
  | @ref _ _ n' _ _ lookup' children =>
    rw [lookupNew] at lookup'
    cases lookup'
    obtain ⟨os1, os2, cs1, csRest, rfl, rfl, asChildren, restChildren⟩ := representsMany_append_split children
    cases restChildren with
    | @cons _ _ _ fp1 _ _ cs3 itemRep bsChildren =>
      have asHeap := representsMany_elements_apart asChildren
        (fun y member => agreeOld y (by simp [member]))
      have bsHeap := representsMany_elements_apart bsChildren
        (fun y member => agreeOld y (by simp [member]))
      have itemHeap := represents_of_agree_rev agreeItem itemRep
      cases represented with
      | @ref _ _ n1 _ _ lookup0 children0 =>
        rw [lookup] at lookup0
        cases lookup0
        obtain ⟨_, _, _, _, _, _, asMid, _⟩ := representsMany_append_split children0
        obtain ⟨_, osMid, _, csMid, _, _, _, midRep⟩ := representsMany_append_split asMid
        have asRaised := representsMany_raise asHeap (Nat.le_max_left n' n1)
        have bsRaised := representsMany_raise bsHeap (Nat.le_max_left n' n1)
        have midRaised := representsMany_raise midRep (Nat.le_max_right n' n1)
        have oldRep : Represents heap _ (.ref root) _ (root :: ((cs1 ++ csMid) ++ cs3)) :=
          .ref lookup (representsMany_append (representsMany_append asRaised midRaised) bsRaised)
        -- the root is not below any element
        have notRoot : c ≠ root' := by
          intro same
          subst same
          cases located with
          | element lookup'' member inner =>
            rw [lookupNew] at lookup''
            cases lookup''
            exact rootApart _ member (reaches_of_atPath inner)
        cases located with
        | @element _ _ z _ _ lookup'' member inner =>
          rw [lookupNew] at lookup''
          cases lookup''
          rcases List.mem_append.mp member with inAs | inRest
          · -- an old element of `as`
            have innerHeap : AtPath heap z p (.ref c) :=
              atPath_of_agree_rev (agreeOld z (by simp [inAs])) inner
            have oldCount := oldOnce _ _ _ oldRep p c container (.element lookup (by simp [inAs]) innerHeap)
            have reachZ : Reaches heap z (.ref c) := reaches_of_atPath innerHeap
            have inCs1 : c ∈ cs1 := Ownership.FlatFragment.FiniteReach.representsMany_reach_member asHeap inAs reachZ
            have itemZero : fp1.count c = 0 := List.count_eq_zero_of_not_mem (fun inItem =>
              itemApartOld p c container (.element lookup (by simp [inAs]) innerHeap)
                (Ownership.FlatFragment.Support.represents_footprint_reaches itemHeap c inItem))
            have cRoot : c ≠ root := by
              intro same
              subst same
              exact no_element_reaches_root lookup (by simp [inAs]) _ _ (Nat.le_refl _) _ _ oldRep reachZ
            have pos : 0 < cs1.count c := List.count_pos_iff.mpr inCs1
            rw [List.count_cons, List.count_append, List.count_append] at oldCount
            rw [List.count_cons, List.count_append, List.count_append, itemZero]
            simp only [beq_iff_eq, if_neg (Ne.symm cRoot), if_neg (Ne.symm notRoot), Nat.add_zero] at oldCount ⊢
            omega
          · rcases List.mem_cons.mp inRest with same | inBs
            · -- the item
              subst same
              have innerHeap : AtPath heap z p (.ref c) := atPath_of_agree_rev agreeItem inner
              have itemCount := itemOnce _ _ _ itemHeap p c container innerHeap
              have asZero : cs1.count c = 0 := List.count_eq_zero_of_not_mem (fun inAs => by
                obtain ⟨y, memberY, reach⟩ :=
                  Ownership.FlatFragment.Support.representsMany_footprint_reaches asHeap c inAs
                exact oldApartItem p c container innerHeap y (by simp [memberY]) reach)
              have bsZero : cs3.count c = 0 := List.count_eq_zero_of_not_mem (fun inBs => by
                obtain ⟨y, memberY, reach⟩ :=
                  Ownership.FlatFragment.Support.representsMany_footprint_reaches bsHeap c inBs
                exact oldApartItem p c container innerHeap y (by simp [memberY]) reach)
              rw [List.count_cons, List.count_append, List.count_append, asZero, bsZero, itemCount]
              simp [beq_iff_eq, Ne.symm notRoot]
            · -- an old element of `bs`
              have innerHeap : AtPath heap z p (.ref c) :=
                atPath_of_agree_rev (agreeOld z (by simp [inBs])) inner
              have oldCount := oldOnce _ _ _ oldRep p c container (.element lookup (by simp [inBs]) innerHeap)
              have reachZ : Reaches heap z (.ref c) := reaches_of_atPath innerHeap
              have inCs2 : c ∈ cs3 := Ownership.FlatFragment.FiniteReach.representsMany_reach_member bsHeap inBs reachZ
              have itemZero : fp1.count c = 0 := List.count_eq_zero_of_not_mem (fun inItem =>
                itemApartOld p c container (.element lookup (by simp [inBs]) innerHeap)
                  (Ownership.FlatFragment.Support.represents_footprint_reaches itemHeap c inItem))
              have cRoot : c ≠ root := by
                intro same
                subst same
                exact no_element_reaches_root lookup (by simp [inBs]) _ _ (Nat.le_refl _) _ _ oldRep reachZ
              have pos : 0 < cs3.count c := List.count_pos_iff.mpr inCs2
              rw [List.count_cons, List.count_append, List.count_append] at oldCount
              rw [List.count_cons, List.count_append, List.count_append, itemZero]
              simp only [beq_iff_eq, if_neg (Ne.symm cRoot), if_neg (Ne.symm notRoot), Nat.add_zero] at oldCount ⊢
              omega

/-! ### The footprint of a list after a push: each container position once (slice 2b of #522) -/

/-- After a push, an array at a container position of an element appears once
in the list's footprint: the old footprint held it once and the item's not
at all, or the item's held it once and the old one not at all. -/
theorem pushed_footprint_once {heap : Heap} {root : Nat} {xs : List Value} {item : Value}
    {n0 : Nat} {o0 : Observation} {fp0 : List Nat}
    (lookup : heap[root]? = some xs)
    (represented : Represents heap n0 (.ref root) o0 fp0)
    (oldOnce : ∀ n o fp, Represents heap n (.ref root) o fp →
      ∀ p c, containerPath p = true → ArrayAt heap (.ref root) (.element :: p) c → fp.count c = 1)
    (itemOnce : ∀ n o fp, Represents heap n item o fp →
      ∀ p c, containerPath p = true → ArrayAt heap item p c → fp.count c = 1)
    (apart : ∀ c, Reaches heap (.ref root) (.ref c) → ¬ Reaches heap item (.ref c)) :
    ∀ n o fp, Represents (heap.set! root (xs ++ [item])) n (.ref root) o fp →
      ∀ p c, containerPath p = true →
        ArrayAt (heap.set! root (xs ++ [item])) (.ref root) (.element :: p) c → fp.count c = 1 := by
  intro n o fp rep p c container located
  have agreeOld : ∀ x ∈ xs, ∀ c, Reaches heap x (.ref c) → (heap.set! root (xs ++ [item]))[c]? = heap[c]? :=
    fun x member => element_agree_after_write represented lookup member
  have agreeItem : ∀ c, Reaches heap item (.ref c) → (heap.set! root (xs ++ [item]))[c]? = heap[c]? := by
    intro c reach
    refine lookup_set_other heap root _ (fun same => ?_)
    subst same
    exact apart c (.refl _) reach
  have bound : root < heap.size := (Array.getElem?_eq_some_iff.mp lookup).1
  have stored : (heap.set! root (xs ++ [item]))[root]? = some (xs ++ [item]) := by simp [bound]
  cases rep with
  | ref lookup' children =>
    rw [stored] at lookup'
    cases lookup'
    obtain ⟨os1, os2, cs1, cs2, rfl, rfl, oldChildren, itemChildren⟩ := representsMany_append_split children
    have oldHeap := representsMany_of_agree_rev agreeOld oldChildren
    have oldRoot : Represents heap _ (.ref root) (.list os1) (root :: cs1) := .ref lookup oldHeap
    cases itemChildren with
    | @cons _ _ _ fp1 _ _ _ itemRep nilRep =>
      cases nilRep
      have itemHeap := represents_of_agree_rev agreeItem itemRep
      rw [List.append_nil]
      -- the element the path enters: an old one, or the item
      cases located with
      | @element _ _ x _ _ lookup'' member inner =>
        rw [stored] at lookup''
        cases lookup''
        rcases List.mem_append.mp member with old | new
        · -- an old element: once in the old footprint, absent from the item's
          have innerHeap : AtPath heap _ p (.ref c) := atPath_of_agree_rev (agreeOld _ old) inner
          have oldCount : (root :: cs1).count c = 1 :=
            oldOnce _ _ _ oldRoot p c container (.element lookup old innerHeap)
          have reachRoot : Reaches heap (.ref root) (.ref c) :=
            .element lookup old (reaches_of_atPath innerHeap)
          have itemZero : (List.count c fp1) = 0 :=
            List.count_eq_zero_of_not_mem (fun inItem => apart c reachRoot
              (Ownership.FlatFragment.Support.represents_footprint_reaches itemHeap c inItem))
          rw [List.count_cons, List.count_append] at *
          omega
        · -- the item: once in its footprint, absent from the old one, and not the root
          have same : x = item := List.mem_singleton.mp new
          rw [same] at inner
          have innerHeap : AtPath heap item p (.ref c) := atPath_of_agree_rev agreeItem inner
          have itemCount := itemOnce _ _ _ itemHeap p c container innerHeap
          have reachItem : Reaches heap item (.ref c) := reaches_of_atPath innerHeap
          have oldZero : (root :: cs1).count c = 0 :=
            List.count_eq_zero_of_not_mem (fun inOld => apart c
              (Ownership.FlatFragment.Support.represents_footprint_reaches oldRoot c inOld) reachItem)
          rw [List.count_cons] at oldZero
          rw [List.count_cons, List.count_append]
          omega

/-! ### The frame of a flat value -/

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

/-- Covering at every path gives the invariant's `named` clause for a flat
value, at an immutable path (an array at an element path is not the
clause's). -/
theorem named_cellsAt_of_covers {heap : Heap} {gamma : Naming} {w : Value} {ty : Ty} {a : Abstract}
    {q : Path} {c : Nat}
    (shape : AllocatedFlatValue heap w ty) (abs : FlatAbstract ty a)
    (covers : Covers gamma heap a w) (located : ArrayAt heap w q c) (immutable : immutablePath q = true) :
    named gamma (a.cellsAt q) c := by
  induction shape generalizing a q with
  | int integer => cases located
  | list root ws t lookupRoot _ _ =>
    cases located with
    | here =>
      have := covers _ _ (.here _)
      simpa [namesAt] using this
    | element _ _ _ => simp [immutablePath] at immutable
  | chain root integers lookupRoot =>
    cases located with
    | here =>
      have := covers _ _ (.here _)
      simpa [namesAt] using this
    | element _ _ _ => simp [immutablePath] at immutable
  | record ws ts len _ ih =>
    cases located with
    | @field _ i w' q' _ ws_i inner =>
      rcases flatAbstract_record abs with rfl | ⟨as, rfl, lenTA, fieldsA⟩
      · have names := covers _ c (.field ws_i inner)
        rw [namesAt_bottom] at names
        exact (named_nil names).elim
      · obtain ⟨t, ts_i⟩ := index_of_same_length len ws_i
        obtain ⟨a', as_i, abs'⟩ := flatAbstract_record_field lenTA fieldsA ts_i
        obtain ⟨origin, member, address⟩ :=
          ih i w' t ws_i ts_i abs' (covers_field covers as_i ws_i) inner
            (by simpa [immutablePath] using immutable)
        obtain ⟨cs, path, inCs⟩ := mem_cellsAt a' q' origin member
        exact ⟨origin, mem_cellsAt_of_path (record_path_mem as i a' q' cs as_i path) inCs, address⟩
  | ok e s w' _ ih =>
    cases located with
    | @field _ i w'' q' _ ws_i inner =>
      cases abs with
      | bottom _ =>
        have names := covers _ c (.field ws_i inner)
        rw [namesAt_bottom] at names
        exact (named_nil names).elim
      | result _ _ ae aa hE hS =>
        rcases getElem?_three ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
        · cases inner
        · cases inner
        · have coversS : Covers gamma heap aa _ := covers_field (i := 2) covers rfl rfl
          obtain ⟨origin, member, address⟩ := ih hS coversS inner (by simpa [immutablePath] using immutable)
          obtain ⟨cs, path, inCs⟩ := mem_cellsAt aa q' origin member
          exact ⟨origin, mem_cellsAt_of_path (record_path_mem [.scalar, ae, aa] 2 aa q' cs rfl path) inCs,
            address⟩
  | err e s w' _ ih =>
    cases located with
    | @field _ i w'' q' _ ws_i inner =>
      cases abs with
      | bottom _ =>
        have names := covers _ c (.field ws_i inner)
        rw [namesAt_bottom] at names
        exact (named_nil names).elim
      | result _ _ ae aa hE hS =>
        rcases getElem?_three ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
        · cases inner
        · have coversE : Covers gamma heap ae _ := covers_field (i := 1) covers rfl rfl
          obtain ⟨origin, member, address⟩ := ih hE coversE inner (by simpa [immutablePath] using immutable)
          obtain ⟨cs, path, inCs⟩ := mem_cellsAt ae q' origin member
          exact ⟨origin, mem_cellsAt_of_path (record_path_mem [.scalar, ae, aa] 1 ae q' cs rfl path) inCs,
            address⟩
        · cases inner

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

theorem mem_paths_of_cells_fold (paths : List (Path × List Origin)) (acc : List Origin) (o : Origin)
    (member : o ∈ paths.foldl (fun cs (_, xs) => union cs xs) acc) :
    o ∈ acc ∨ ∃ p cs, (p, cs) ∈ paths ∧ o ∈ cs := by
  induction paths generalizing acc with
  | nil => exact Or.inl member
  | cons entry paths ih =>
    rcases entry with ⟨q, xs⟩
    rw [List.foldl_cons] at member
    rcases ih _ member with inAcc | ⟨p, cs, path, inCs⟩
    · dsimp only at inAcc
      rcases mem_union_cases acc xs o inAcc with old | new
      · exact Or.inl old
      · exact Or.inr ⟨q, xs, by simp, new⟩
    · exact Or.inr ⟨p, cs, List.mem_cons_of_mem _ path, inCs⟩

/-- Every cell of an abstract is on one of its paths. -/
theorem mem_paths_of_mem_cells {a : Abstract} {o : Origin} (member : o ∈ a.cells) :
    ∃ p cs, (p, cs) ∈ a.paths ∧ o ∈ cs := by
  unfold Abstract.cells at member
  rcases mem_paths_of_cells_fold a.paths [] o member with none | found
  · simp at none
  · exact found

/-- An element path of a list's element is a path of the list. -/
theorem list_element_path_mem (roots : List Origin) (x : Abstract) (ex : Certificate) {p : Path}
    {cs : List Origin} (path : (p, cs) ∈ x.paths) :
    (.element :: p, cs) ∈ (Abstract.list roots x ex).paths := by
  simp only [Abstract.paths]
  exact List.mem_cons_of_mem _ (List.mem_map.mpr ⟨(p, cs), path, rfl⟩)

/-- What a flat abstract names at a path is among its cells. -/
theorem namesAt_subset_cells {t : Ty} {a : Abstract} (abs : FlatAbstract t a) :
    ∀ q o, o ∈ namesAt a q → o ∈ a.cells := by
  induction abs with
  | bottom ty =>
    intro q o member
    rw [namesAt_bottom] at member
    simp at member
  | int =>
    intro q o member
    cases q with
    | nil => exact cellsAt_subset_cells member
    | cons s r => cases s <;> simp [namesAt] at member
  | list t roots elem cert noUnk _ ih =>
    intro q o member
    cases q with
    | nil => exact cellsAt_subset_cells member
    | cons s r =>
      cases s with
      | element =>
        simp only [namesAt] at member
        split at member
        · exact absurd (List.contains_iff_mem.mp (by assumption)) noUnk
        · obtain ⟨p, cs, path, inCs⟩ := mem_paths_of_mem_cells (ih r o member)
          exact mem_cells_of_path (list_element_path_mem roots elem cert path) inCs
      | field _ => simp [namesAt] at member; exact absurd member.1 noUnk
      | capture _ => simp [namesAt] at member; exact absurd member.1 noUnk
      | env => simp [namesAt] at member; exact absurd member.1 noUnk
  | chainBottom roots cert =>
    intro q o member
    cases q with
    | nil => exact cellsAt_subset_cells member
    | cons s r =>
      have roots_mem : o ∈ roots → o ∈ (Abstract.list roots .bottom cert).cells :=
        fun h => mem_cells_of_path (a := Abstract.list roots .bottom cert) (q := []) (cs := roots)
          (by simp [Abstract.paths]) h
      cases s with
      | element =>
        simp only [namesAt] at member
        split at member
        · exact roots_mem member
        · rw [namesAt_bottom] at member; simp at member
      | field _ => simp [namesAt] at member; exact roots_mem member.2
      | capture _ => simp [namesAt] at member; exact roots_mem member.2
      | env => simp [namesAt] at member; exact roots_mem member.2
  | chainScalar roots cert =>
    intro q o member
    cases q with
    | nil => exact cellsAt_subset_cells member
    | cons s r =>
      have roots_mem : o ∈ roots → o ∈ (Abstract.list roots .scalar cert).cells :=
        fun h => mem_cells_of_path (a := Abstract.list roots .scalar cert) (q := []) (cs := roots)
          (by simp [Abstract.paths]) h
      cases s with
      | element =>
        simp only [namesAt] at member
        split at member
        · exact roots_mem member
        · cases r with
          | nil => simp [namesAt, Abstract.cellsAt, Abstract.paths] at member
          | cons s' r' => cases s' <;> simp [namesAt] at member
      | field _ => simp [namesAt] at member; exact roots_mem member.2
      | capture _ => simp [namesAt] at member; exact roots_mem member.2
      | env => simp [namesAt] at member; exact roots_mem member.2
  | record ts as len _ ih =>
    intro q o member
    cases q with
    | nil => exact cellsAt_subset_cells member
    | cons s r =>
      cases s with
      | field i =>
        simp only [namesAt] at member
        cases h : as[i]? with
        | none =>
          rw [h] at member
          simp [namesAt_bottom] at member
        | some a' =>
          rw [h] at member
          simp only [Option.getD_some] at member
          obtain ⟨t', ts_i⟩ := index_of_same_length len.symm h
          obtain ⟨p, cs, path, inCs⟩ := mem_paths_of_mem_cells (ih i t' a' ts_i h r o member)
          exact mem_cells_of_path (record_path_mem as i a' p cs h path) inCs
      | element => simp [namesAt] at member
      | capture _ => simp [namesAt] at member
      | env => simp [namesAt] at member
  | result e s ae aa _ _ ihE ihS =>
    intro q o member
    cases q with
    | nil => exact cellsAt_subset_cells member
    | cons st r =>
      cases st with
      | field i =>
        simp only [namesAt] at member
        cases h : [Abstract.scalar, ae, aa][i]? with
        | none =>
          rw [h] at member
          simp [namesAt_bottom] at member
        | some a' =>
          rw [h] at member
          simp only [Option.getD_some] at member
          rcases getElem?_three h with ⟨rfl, h'⟩ | ⟨rfl, h'⟩ | ⟨rfl, h'⟩ <;> rw [h'] at member
          · cases r with
            | nil => simp [namesAt, Abstract.cellsAt, Abstract.paths] at member
            | cons s' r' => cases s' <;> simp [namesAt] at member
          · obtain ⟨p, cs, path, inCs⟩ := mem_paths_of_mem_cells (ihE r o member)
            exact mem_cells_of_path (record_path_mem [.scalar, ae, aa] 1 ae p cs rfl path) inCs
          · obtain ⟨p, cs, path, inCs⟩ := mem_paths_of_mem_cells (ihS r o member)
            exact mem_cells_of_path (record_path_mem [.scalar, ae, aa] 2 aa p cs rfl path) inCs
      | element => simp [namesAt] at member
      | capture _ => simp [namesAt] at member
      | env => simp [namesAt] at member

/-- Covering at a path names the array among the abstract's cells. -/
theorem named_cells_of_covers {heap : Heap} {gamma : Naming} {w : Value} {t : Ty} {a : Abstract}
    {q : Path} {c : Nat} (abs : FlatAbstract t a)
    (covers : Covers gamma heap a w) (located : ArrayAt heap w q c) : named gamma a.cells c := by
  obtain ⟨o, member, address⟩ := covers q c located
  exact ⟨o, namesAt_subset_cells abs q o member, address⟩


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

theorem mapOrigins_scalar (f : Path → List Origin → List Origin) (path : Path) :
    Abstract.scalar.mapOrigins f path = .scalar := by
  simp [Abstract.mapOrigins]

theorem mapOrigins_bottom (f : Path → List Origin → List Origin) (path : Path) :
    Abstract.bottom.mapOrigins f path = .bottom := by
  simp [Abstract.mapOrigins]

theorem mapOrigins_ne_bottom (f : Path → List Origin → List Origin) (path : Path) {a : Abstract}
    (ne : a ≠ .bottom) : a.mapOrigins f path ≠ .bottom := by
  cases a <;> simp [Abstract.mapOrigins] at ne ⊢

theorem mapOrigins_three (f : Path → List Origin → List Origin) (path : Path) (a0 a1 a2 : Abstract) :
    (Abstract.record [a0, a1, a2]).mapOrigins f path =
      .record [a0.mapOrigins f (path ++ [.field 0]), a1.mapOrigins f (path ++ [.field 1]),
        a2.mapOrigins f (path ++ [.field 2])] := by
  simp only [Abstract.mapOrigins]
  rfl

theorem flatAbstract_mapOrigins (f : Path → List Origin → List Origin)
    (keeps : ∀ path cs, Origin.unknown ∉ cs → Origin.unknown ∉ f path cs) {ty : Ty} {a : Abstract}
    (shape : FlatAbstract ty a) (path : Path) : FlatAbstract ty (a.mapOrigins f path) := by
  induction shape generalizing path with
  | bottom ty => rw [mapOrigins_bottom]; exact .bottom _
  | int => simpa [Abstract.mapOrigins] using FlatAbstract.int
  | list t roots element certificate noUnk _ ih =>
    simp only [Abstract.mapOrigins]
    exact .list _ _ _ _ (keeps path roots noUnk) (ih _)
  | chainBottom roots certificate =>
    simp only [Abstract.mapOrigins]
    exact .chainBottom _ _
  | chainScalar roots certificate =>
    simp only [Abstract.mapOrigins]
    exact .chainScalar _ _
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
  | result e s ae aa _ _ ihE ihS =>
    rw [mapOrigins_three, mapOrigins_scalar]
    exact .result e s _ _ (ihE _) (ihS _)

/-- The tags survive an origin substitution: it keeps every constructor. -/
theorem resultTags_mapOrigins (f : Path → List Origin → List Origin) {t : Ty} {a : Abstract} {w : Value}
    (tags : ResultTags t a w) (path : Path) : ResultTags t (a.mapOrigins f path) w := by
  induction tags generalizing path with
  | int n => rw [mapOrigins_scalar]; exact .int _
  | list t roots element certificate w =>
    simp only [Abstract.mapOrigins]
    exact .list _ _ _ _ _
  | chainInt roots element certificate w =>
    simp only [Abstract.mapOrigins]
    exact .chainInt _ _ _ _
  | record ts as ws len _ ih =>
    simp only [Abstract.mapOrigins]
    refine .record ts _ ws (by simp [len]) ?_
    intro i t a' w' ts_i at_i ws_i
    rw [record_mapOrigins_index] at at_i
    cases h : as[i]? with
    | none => simp [h] at at_i
    | some a0 =>
      simp [h] at at_i
      subst at_i
      exact ih i t a0 w' ts_i h ws_i _
  | ok e s tag ae aa w' ne _ ih =>
    rw [mapOrigins_three]
    exact .ok e s _ _ _ w' (mapOrigins_ne_bottom f _ ne) (ih _)
  | err e s tag ae aa w' ne _ ih =>
    rw [mapOrigins_three]
    exact .err e s _ _ _ w' (mapOrigins_ne_bottom f _ ne) (ih _)

/-- The chain tags of a bottom abstract: only an integer or a list carries one. -/
theorem chainTags_of_bottom {t : Ty} {o : Observation} (tags : ChainTags t .bottom o) (b : Abstract) :
    ChainTags t b o := by
  cases tags with
  | int _ _ => exact .int _ _
  | list _ _ _ => exact .list _ _ _

/-- The chain tags survive an origin substitution: it keeps every constructor. -/
theorem chainTags_mapOrigins (f : Path → List Origin → List Origin) {t : Ty} {a : Abstract} {o : Observation}
    (tags : ChainTags t a o) (path : Path) : ChainTags t (a.mapOrigins f path) o := by
  induction tags generalizing path with
  | int a o => exact .int _ _
  | list t a o => exact .list _ _ _
  | chainScalar roots certificate o =>
    simp only [Abstract.mapOrigins]
    exact .chainScalar _ _ _
  | chainBottom roots certificate =>
    simp only [Abstract.mapOrigins]
    exact .chainBottom _ _
  | record ts as os len _ ih =>
    simp only [Abstract.mapOrigins]
    refine .record ts _ os (by simp [len]) ?_
    intro i t a' o' ts_i at_i os_i
    rw [record_mapOrigins_index] at at_i
    cases h : as[i]? with
    | none => simp [h] at at_i
    | some a0 =>
      simp [h] at at_i
      subst at_i
      exact ih i t a0 o' ts_i h os_i _
  | ok e s tag ae aa o' _ ih =>
    rw [mapOrigins_three]
    exact .ok e s _ _ _ o' (ih _)
  | err e s tag ae aa o' _ ih =>
    rw [mapOrigins_three]
    exact .err e s _ _ _ o' (ih _)

/-- The chain tags of a projection along a typed path. -/
theorem chainTags_project {tk t : Ty} {a : Abstract} {o o' : Observation} {p : Path}
    (tags : ChainTags tk a o) (shape : FlatAbstract tk a) (at_p : tyAt tk p = some t)
    (projected : projectObs o p = some o') : ChainTags t (a.atPath p) o' := by
  induction p generalizing tk a o with
  | nil =>
    simp [tyAt] at at_p
    subst at_p
    simp [projectObs] at projected
    subst projected
    simpa [Abstract.atPath] using tags
  | cons step rest ih =>
    cases step <;> cases tk <;> simp [tyAt] at at_p
    rename_i i' ts
    cases h : ts[i']? with
    | none => simp [h] at at_p
    | some t' =>
      simp [h] at at_p
      cases tags with
      | record _ as os _ tagFields =>
        cases shape with
        | record _ _ len fields =>
          obtain ⟨a', as_i, shape'⟩ := flatAbstract_record_field len fields h
          simp [projectObs] at projected
          cases h' : os[i']? with
          | none => simp [h'] at projected
          | some o1 =>
            simp [h'] at projected
            simp only [Abstract.atPath, as_i, Option.getD_some]
            exact ih (tagFields i' t' a' o1 h as_i h') shape' at_p projected

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

/-- A cell stays in the shared marking. -/
theorem mem_sharedMark {cs : List Origin} {o : Origin} (path : Path) (member : o ∈ cs) :
    o ∈ sharedMark path cs := by
  have nonempty : cs.isEmpty = false := by
    cases cs with
    | nil => simp at member
    | cons _ _ => rfl
  simp only [sharedMark, nonempty, Bool.false_eq_true, if_false]
  exact mem_union cs [.shared] o (Or.inl member)

/-- The shared marking adds no unknown origin. -/
theorem sharedMark_no_unknown {cs : List Origin} (path : Path) (noUnk : Origin.unknown ∉ cs) :
    Origin.unknown ∉ sharedMark path cs := by
  intro member
  unfold sharedMark at member
  split at member
  · simp at member
  · rcases mem_union_cases cs [.shared] _ member with inCs | inShared
    · exact noUnk inCs
    · simp at inShared

/-- A described list describes each of its elements by its element abstract,
when its roots hold no unknown origin. -/
theorem describes_element {gamma : Naming} {heap : Heap} {roots : List Origin} {e : Abstract}
    {ex : Certificate} {root : Nat} {ys : List Value} {y : Value}
    (noUnk : Origin.unknown ∉ roots) (lookup : heap[root]? = some ys) (member : y ∈ ys)
    (described : Describes gamma heap (.list roots e ex) (.ref root)) : Describes gamma heap e y := by
  refine ⟨⟨fun q c located => ?_, fun q cs e' ex' w' shape located n o fp rep => ?_⟩, ?_⟩
  · have := described.1.1 (.element :: q) c (.element lookup member located)
    simpa [namesAt, noUnk] using this
  · exact described.1.2 (.element :: q) cs e' ex' w' (by simpa [Abstract.atPath] using shape)
      (.element lookup member located) n o fp rep
  · cases described.2 with
    | array lookup' elements =>
      rw [lookup] at lookup'
      cases lookup'
      simpa [Abstract.atPath] using elements y member
    | unknown _ _ _ top => exact absurd (List.contains_iff_mem.mp top) noUnk

/-- A value that reaches no array has the empty footprint. -/
theorem footprint_nil_of_unreached {heap : Heap} {n : Nat} {w : Value} {o : Observation} {fp : List Nat}
    (rep : Represents heap n w o fp) (none : ∀ c, ¬ Reaches heap w (.ref c)) : fp = [] := by
  cases fp with
  | nil => rfl
  | cons c _ =>
    exact (none c (Ownership.FlatFragment.Support.represents_footprint_reaches rep c (by simp))).elim

/-- A value the bottom abstract covers reaches no array. -/
theorem no_arrays_of_covers_bottom {gamma : Naming} {heap : Heap} {w : Value}
    (covers : Covers gamma heap .bottom w) : ∀ c, ¬ Reaches heap w (.ref c) := by
  intro c reach
  obtain ⟨q, located⟩ := arrayAt_of_reaches reach
  have := covers q c located
  rw [namesAt_bottom] at this
  exact named_nil this

/-- Every abstract describes a shaped value that reaches no array. -/
theorem describes_of_no_arrays {gamma : Naming} {heap : Heap} {w : Value} {ty : Ty}
    (shape : AllocatedFlatValue heap w ty) (none : ∀ c, ¬ Reaches heap w (.ref c)) (b : Abstract) :
    Describes gamma heap b w := by
  refine ⟨⟨fun q c located => (none c (reaches_of_atPath located)).elim,
    fun q cs e ex w' _ located n o fp rep => ?_⟩, closureAgreement_of_allocated shape b⟩
  have none' : ∀ c, ¬ Reaches heap w' (.ref c) :=
    fun c r => none c (reaches_trans (reaches_of_atPath located) r)
  have empty := footprint_nil_of_unreached rep none'
  subst empty
  exact ⟨fun _ => List.nodup_nil, fun _ p c _ found => (none' c (reaches_of_atPath found)).elim⟩

/-! ### The store tests, read through the naming (slice 2b of #522) -/

/-- What `storeExclusive` says of one value: deep exclusivity, separated paths,
and no cell in common with the later holders or the other operand. -/
theorem storeExclusive_facts {ctx : Context} {v : Abstract} {later other : List Origin}
    (h : storeExclusive ctx [v] later other = true) :
    v.deepExclusive = true ∧ separatedPaths v.paths = true ∧ cellOverlap v.cells (union later other) = false := by
  unfold storeExclusive at h
  rw [Bool.and_eq_true, Bool.and_eq_true] at h
  obtain ⟨⟨premise, separated⟩, owned⟩ := h
  refine ⟨?_, ?_, ?_⟩
  · rw [Bool.or_eq_true] at premise
    rcases premise with deep | impossible
    · simpa using deep
    · simp at impossible
  · simpa [separatedValues] using separated
  · simp only [List.all_cons, List.all_nil, Bool.and_true] at owned
    rw [Bool.and_eq_true] at owned
    simpa using owned.2

/-- The scalar abstract names nothing at any path. -/
theorem namesAt_scalar (q : Path) : namesAt .scalar q = [] := by
  cases q with
  | nil => simp [namesAt, Abstract.cellsAt, Abstract.paths]
  | cons step rest => cases step <;> simp [namesAt]

/-- A value an abstract covers while naming nothing reaches no array. -/
theorem no_arrays_of_nameless {gamma : Naming} {heap : Heap} {a : Abstract} {w : Value}
    (nameless : ∀ q, namesAt a q = []) (covers : Covers gamma heap a w) : ∀ c, ¬ Reaches heap w (.ref c) := by
  intro c reach
  obtain ⟨q, located⟩ := arrayAt_of_reaches reach
  have := covers q c located
  rw [nameless q] at this
  exact named_nil this

/-- A cell of a list abstract is a root or a cell of its element. -/
theorem mem_list_cells {roots : List Origin} {e : Abstract} {ex : Certificate} {o : Origin}
    (member : o ∈ (Abstract.list roots e ex).cells) : o ∈ roots ∨ o ∈ e.cells := by
  obtain ⟨p, cs, path, inCs⟩ := mem_paths_of_mem_cells member
  simp only [Abstract.paths, List.mem_cons, List.mem_map] at path
  rcases path with ⟨rfl, rfl⟩ | ⟨⟨p', cs'⟩, path', eq⟩
  · exact Or.inl inCs
  · cases eq
    exact Or.inr (mem_cells_of_path path' inCs)

/-- Two values whose abstracts share no cell reach no array in common. -/
theorem reach_apart_of_covers {gamma : Naming} {heap : Heap} {a b : Abstract} {w v : Value} {ta tb : Ty}
    (separating : Separating gamma) (shapeA : FlatAbstract ta a) (shapeB : FlatAbstract tb b)
    (coversA : Covers gamma heap a w) (coversB : Covers gamma heap b v)
    (disjoint : cellOverlap a.cells b.cells = false) :
    ∀ c, Reaches heap w (.ref c) → ¬ Reaches heap v (.ref c) := by
  intro c rw rv
  obtain ⟨q, lw⟩ := arrayAt_of_reaches rw
  obtain ⟨q', lv⟩ := arrayAt_of_reaches rv
  exact cellOverlap_sound gamma separating a.cells b.cells disjoint c
    (named_cells_of_covers shapeA coversA lw) (named_cells_of_covers shapeB coversB lv)

/-- Separated paths, read through a separating naming: two distinct paths of
an abstract name no array in common. -/
def PathsApart (gamma : Naming) (a : Abstract) : Prop :=
  ∀ x ∈ a.paths, ∀ y ∈ a.paths, x ≠ y → ∀ c, named gamma x.2 c → ¬ named gamma y.2 c

/-- The checker's separation test, by index. -/
theorem separatedPaths_sound {xs : List (Path × List Origin)} (sep : separatedPaths xs = true) :
    ∀ (i j : Nat), i < j → ∀ p cs q ds, xs[i]? = some (p, cs) → xs[j]? = some (q, ds) →
      cellOverlap cs ds = false := by
  intro i j lt p cs q ds xs_i xs_j
  unfold separatedPaths at sep
  have memI : ((p, cs), i) ∈ xs.zipIdx := List.mem_zipIdx_iff_getElem?.mpr xs_i
  have inner := List.all_eq_true.mp sep ((p, cs), i) memI
  dsimp only at inner
  have memJ : (q, ds) ∈ xs.drop (i + 1) := by
    rw [List.mem_iff_getElem?]
    refine ⟨j - (i + 1), ?_⟩
    rw [List.getElem?_drop]
    have : i + 1 + (j - (i + 1)) = j := by omega
    rw [this]
    exact xs_j
  have := List.all_eq_true.mp inner (q, ds) memJ
  simpa using this

theorem pathsApart_of_separated {gamma : Naming} {a : Abstract} (separating : Separating gamma)
    (sep : separatedPaths a.paths = true) : PathsApart gamma a := by
  intro x hx y hy ne c namedX namedY
  obtain ⟨i, at_i⟩ := List.mem_iff_getElem?.mp hx
  obtain ⟨j, at_j⟩ := List.mem_iff_getElem?.mp hy
  rcases Nat.lt_trichotomy i j with lt | eq | gt
  · exact cellOverlap_sound gamma separating x.2 y.2
      (separatedPaths_sound sep i j lt x.1 x.2 y.1 y.2 at_i at_j) c namedX namedY
  · subst eq
    rw [at_i] at at_j
    exact ne (Option.some.inj at_j)
  · exact cellOverlap_sound gamma separating y.2 x.2
      (separatedPaths_sound sep j i gt y.1 y.2 x.1 x.2 at_j at_i) c namedY namedX

/-- Separation passes to a record's field. -/
theorem pathsApart_field {gamma : Naming} {as : List Abstract} {i : Nat} {a' : Abstract}
    (apart : PathsApart gamma (.record as)) (as_i : as[i]? = some a') : PathsApart gamma a' := by
  intro x hx y hy ne c namedX namedY
  exact apart (.field i :: x.1, x.2) (record_path_mem as i a' x.1 x.2 as_i hx)
    (.field i :: y.1, y.2) (record_path_mem as i a' y.1 y.2 as_i hy)
    (fun h => ne (by
      obtain ⟨h1, h2⟩ := Prod.mk.inj h
      exact Prod.ext (List.cons.inj h1).2 h2)) c namedX namedY

/-- Separation passes to a list's element. -/
theorem pathsApart_element {gamma : Naming} {roots : List Origin} {x : Abstract} {ex : Certificate}
    (apart : PathsApart gamma (.list roots x ex)) : PathsApart gamma x := by
  intro a ha b hb ne c namedA namedB
  exact apart (.element :: a.1, a.2) (list_element_path_mem roots x ex ha)
    (.element :: b.1, b.2) (list_element_path_mem roots x ex hb)
    (fun h => ne (by
      obtain ⟨h1, h2⟩ := Prod.mk.inj h
      exact Prod.ext (List.cons.inj h1).2 h2)) c namedA namedB

/-- Deep exclusivity passes to a record's field. -/
theorem deepExclusive_field {as : List Abstract} {i : Nat} {a' : Abstract}
    (deep : (Abstract.record as).deepExclusive = true) (as_i : as[i]? = some a') : a'.deepExclusive = true := by
  simp only [Abstract.deepExclusive] at deep
  exact List.all_eq_true.mp deep ⟨a', List.mem_of_getElem? as_i⟩ (List.mem_attach _ _)

/-- The joint footprint of values that reach no array in common and each have
a footprint without repeats has no repeats. -/
theorem representsMany_nodup_of_apart {heap : Heap} {n : Nat} {ws : List Value} {os : List Observation}
    {cs : List Nat} (children : RepresentsMany heap n ws os cs)
    (each : ∀ (i : Nat) w o c, ws[i]? = some w → os[i]? = some o → Represents heap n w o c → c.Nodup)
    (apart : ∀ (i j : Nat), i ≠ j → ∀ wi wj, ws[i]? = some wi → ws[j]? = some wj →
      ∀ c, Reaches heap wi (.ref c) → ¬ Reaches heap wj (.ref c)) : cs.Nodup := by
  induction ws generalizing os cs with
  | nil =>
    cases children
    exact List.nodup_nil
  | cons w ws ih =>
    cases children with
    | @cons _ _ _ c0 _ _ ds first rest =>
      have headNodup : c0.Nodup := each 0 w _ c0 rfl rfl first
      have restNodup : ds.Nodup :=
        ih rest (fun i w' o' c' ws_i os_i rep => each (i + 1) w' o' c' (by simpa using ws_i) (by simpa using os_i) rep)
          (fun i j ne wi wj ws_i ws_j => apart (i + 1) (j + 1) (by omega) wi wj (by simpa using ws_i) (by simpa using ws_j))
      refine List.nodup_append.mpr ⟨headNodup, restNodup, fun a ha b hb same => ?_⟩
      subst same
      have reachHead : Reaches heap w (.ref a) :=
        Ownership.FlatFragment.Support.represents_footprint_reaches first a ha
      obtain ⟨wj, member, reachJ⟩ :=
        Ownership.FlatFragment.Support.representsMany_footprint_reaches rest a hb
      obtain ⟨j, ws_j⟩ := List.mem_iff_getElem?.mp member
      exact apart 0 (j + 1) (by omega) w wj rfl (by simpa using ws_j) a reachHead reachJ

/-- The footprint of a deeply exclusive, path-separated flat value repeats no
array: a list by its own certificate, a record by its fields' footprints,
which the separated paths keep apart. -/
theorem nodup_of_deepExclusive {gamma : Naming} {heap : Heap} {w : Value} {t : Ty} {a : Abstract}
    (shapeV : AllocatedFlatValue heap w t) (shape : FlatAbstract t a)
    (described : Describes gamma heap a w) (deep : a.deepExclusive = true) (apart : PathsApart gamma a) :
    ∀ n o fp, Represents heap n w o fp → fp.Nodup := by
  induction shapeV generalizing a with
  | int integer =>
    intro n o fp rep
    cases rep
    exact List.nodup_nil
  | list root ys t lookup elements _ =>
    intro n o fp rep
    cases shape with
    | bottom _ =>
      rw [footprint_nil_of_unreached rep (no_arrays_of_covers_bottom described.1.1)]
      exact List.nodup_nil
    | list _ roots x ex noUnk _ =>
      simp [Abstract.deepExclusive] at deep
      exact (described.1.2 [] roots x ex (.ref root) rfl (.here _) n o fp rep).1 deep.1
  | chain root integers lookup =>
    intro n o fp rep
    cases shape with
    | bottom _ =>
      rw [footprint_nil_of_unreached rep (no_arrays_of_covers_bottom described.1.1)]
      exact List.nodup_nil
    | chainBottom roots ex =>
      simp [Abstract.deepExclusive] at deep
      exact (described.1.2 [] roots .bottom ex (.ref root) rfl (.here _) n o fp rep).1 deep
    | chainScalar roots ex =>
      simp [Abstract.deepExclusive] at deep
      exact (described.1.2 [] roots .scalar ex (.ref root) rfl (.here _) n o fp rep).1 deep
  | record ws ts len fields ih =>
    intro n o fp rep
    cases shape with
    | bottom _ =>
      rw [footprint_nil_of_unreached rep (no_arrays_of_covers_bottom described.1.1)]
      exact List.nodup_nil
    | record _ as lenA fieldsA =>
      cases rep with
      | record children =>
        -- an array a field reaches is named at a path of that field
        have fieldPath : ∀ i w' a' (t' : Ty), ws[i]? = some w' → as[i]? = some a' → FlatAbstract t' a' →
            ∀ c, Reaches heap w' (.ref c) →
              ∃ p cs, (.field i :: p, cs) ∈ (Abstract.record as).paths ∧ named gamma cs c := by
          intro i w' a' t' ws_i as_i abs' c reach
          obtain ⟨q, located⟩ := arrayAt_of_reaches reach
          obtain ⟨o', member, address⟩ := covers_field described.1.1 as_i ws_i q c located
          obtain ⟨p, cs, path, inCs⟩ :=
            mem_paths_of_mem_cells (namesAt_subset_cells abs' q o' member)
          exact ⟨p, cs, record_path_mem as i a' p cs as_i path, ⟨o', inCs, address⟩⟩
        refine representsMany_nodup_of_apart children ?_ ?_
        · intro i w' o' c ws_i os_i repI
          obtain ⟨t', ts_i⟩ := index_of_same_length len ws_i
          obtain ⟨a', as_i, abs'⟩ := flatAbstract_record_field lenA fieldsA ts_i
          exact ih i w' t' ws_i ts_i abs' (describes_field described as_i ws_i)
            (deepExclusive_field deep as_i) (pathsApart_field apart as_i) _ o' c repI
        · intro i j ne wi wj ws_i ws_j c reachI reachJ
          obtain ⟨ti, ts_i⟩ := index_of_same_length len ws_i
          obtain ⟨tj, ts_j⟩ := index_of_same_length len ws_j
          obtain ⟨ai, as_i, absI⟩ := flatAbstract_record_field lenA fieldsA ts_i
          obtain ⟨aj, as_j, absJ⟩ := flatAbstract_record_field lenA fieldsA ts_j
          obtain ⟨p, cs, pathI, namedI⟩ := fieldPath i wi ai ti ws_i as_i absI c reachI
          obtain ⟨q, ds, pathJ, namedJ⟩ := fieldPath j wj aj tj ws_j as_j absJ c reachJ
          exact apart (.field i :: p, cs) pathI (.field j :: q, ds) pathJ
            (fun h => ne (Step.field.inj (List.cons.inj (Prod.mk.inj h).1).1)) c namedI namedJ
  | ok e s w' inner ih =>
    intro n o fp rep
    cases shape with
    | bottom _ =>
      rw [footprint_nil_of_unreached rep (no_arrays_of_covers_bottom described.1.1)]
      exact List.nodup_nil
    | result _ _ ae aa hE hS =>
      cases rep with
      | record children =>
        refine representsMany_nodup_of_apart children ?_ ?_
        · intro i w'' o' c at_i os_i repI
          rcases getElem?_three at_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
          · cases repI; exact List.nodup_nil
          · cases repI; exact List.nodup_nil
          · exact ih hS (describes_field (i := 2) described rfl rfl) (deepExclusive_field (i := 2) deep rfl)
              (pathsApart_field (i := 2) apart rfl) _ o' c repI
        · intro i j ne wi wj at_i at_j c reachI reachJ
          rcases getElem?_three at_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ <;>
            rcases getElem?_three at_j with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ <;>
            first | exact (ne rfl).elim | exact int_reaches_nothing reachI | exact int_reaches_nothing reachJ
  | err e s w' inner ih =>
    intro n o fp rep
    cases shape with
    | bottom _ =>
      rw [footprint_nil_of_unreached rep (no_arrays_of_covers_bottom described.1.1)]
      exact List.nodup_nil
    | result _ _ ae aa hE hS =>
      cases rep with
      | record children =>
        refine representsMany_nodup_of_apart children ?_ ?_
        · intro i w'' o' c at_i os_i repI
          rcases getElem?_three at_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
          · cases repI; exact List.nodup_nil
          · exact ih hE (describes_field (i := 1) described rfl rfl) (deepExclusive_field (i := 1) deep rfl)
              (pathsApart_field (i := 1) apart rfl) _ o' c repI
          · cases repI; exact List.nodup_nil
        · intro i j ne wi wj at_i at_j c reachI reachJ
          rcases getElem?_three at_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ <;>
            rcases getElem?_three at_j with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ <;>
            first | exact (ne rfl).elim | exact int_reaches_nothing reachI | exact int_reaches_nothing reachJ

/-! ### The checker's store tests, read through the naming (slice 2b of #522) -/

theorem cellOverlap_false_of_forall {a b : List Origin}
    (h : ∀ x ∈ a, ∀ y ∈ b, aliases x y = false) : cellOverlap a b = false := by
  simpa [cellOverlap, List.any_eq_false] using h

theorem cellOverlap_union_right_false {a b c : List Origin} (h : cellOverlap a (union b c) = false) :
    cellOverlap a b = false ∧ cellOverlap a c = false := by
  have all := cellOverlap_false _ _ h
  exact ⟨cellOverlap_false_of_forall (fun x hx y hy => all x hx y (mem_union _ _ _ (Or.inl hy))),
    cellOverlap_false_of_forall (fun x hx y hy => all x hx y (mem_union _ _ _ (Or.inr hy)))⟩

/-- A name of an array a shaped value reaches sits in the entry of its path:
below a chain there is no array, and a list's roots hold no unknown origin. -/
theorem mem_namesAt_of_arrayAt {heap : Heap} {t : Ty} {a : Abstract} {w : Value}
    (shape : FlatAbstract t a) (allocated : AllocatedFlatValue heap w t) :
    ∀ (q : Path) (c : Nat) (o : Origin), ArrayAt heap w q c → o ∈ namesAt a q →
      ∃ cs, (q, cs) ∈ a.paths ∧ o ∈ cs := by
  induction allocated generalizing a with
  | int integer =>
    intro q c o located _
    cases located
  | list root ys t lookup elements ih =>
    intro q c o located member
    cases shape with
    | bottom _ => cases q <;> simp [namesAt, Abstract.cellsAt, Abstract.paths] at member
    | list _ roots x ex noUnk shapeX =>
      cases located with
      | here =>
        rw [list_root_names] at member
        refine ⟨roots, by simp [Abstract.paths], ?_⟩
        rcases mem_union_cases _ _ _ member with none | inRoots
        · simp at none
        · exact inRoots
      | element lookup' yMember inner =>
        rw [lookup] at lookup'
        cases lookup'
        have noUnkB : roots.contains .unknown = false := by
          cases h : roots.contains .unknown with
          | false => rfl
          | true => exact absurd (List.contains_iff_mem.mp h) noUnk
        simp only [namesAt, noUnkB, Bool.false_eq_true, if_false] at member
        obtain ⟨cs, path, inCs⟩ := ih _ yMember shapeX _ c o inner member
        exact ⟨cs, list_element_path_mem roots x ex path, inCs⟩
  | chain root integers lookup =>
    intro q c o located member
    cases located with
    | here =>
      cases shape with
      | bottom _ => simp [namesAt, Abstract.cellsAt, Abstract.paths] at member
      | chainBottom roots ex =>
        rw [list_root_names] at member
        refine ⟨roots, by simp [Abstract.paths], ?_⟩
        rcases mem_union_cases _ _ _ member with none | inRoots
        · simp at none
        · exact inRoots
      | chainScalar roots ex =>
        rw [list_root_names] at member
        refine ⟨roots, by simp [Abstract.paths], ?_⟩
        rcases mem_union_cases _ _ _ member with none | inRoots
        · simp at none
        · exact inRoots
    | element lookup' yMember inner =>
      rw [lookup] at lookup'
      cases lookup'
      obtain ⟨i, _, rfl⟩ := List.mem_map.mp yMember
      cases inner
  | record ws ts len fields ih =>
    intro q c o located member
    cases located with
    | @field _ i x q' _ xs_i inner =>
      cases shape with
      | bottom _ => simp [namesAt, Abstract.cellsAt, Abstract.paths] at member
      | record _ as lenA fieldsA =>
        have bound : i < ts.length := by
          rw [← len]
          exact (List.getElem?_eq_some_iff.mp xs_i).1
        obtain ⟨a', as_i⟩ := index_of_same_length lenA (List.getElem?_eq_getElem bound)
        simp only [namesAt, as_i, Option.getD_some] at member
        obtain ⟨cs, path, inCs⟩ :=
          ih i x ts[i] xs_i (List.getElem?_eq_getElem bound) (fieldsA i ts[i] a' (List.getElem?_eq_getElem bound) as_i)
            q' c o inner member
        exact ⟨cs, record_path_mem as i a' q' cs as_i path, inCs⟩
  | ok e s w' inner' ih =>
    intro q c o located member
    cases located with
    | @field _ i x q' _ xs_i inner =>
      cases shape with
      | bottom _ => simp [namesAt, Abstract.cellsAt, Abstract.paths] at member
      | result _ _ ae aa hE hS =>
        rcases getElem?_three xs_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
        · cases inner
        · cases inner
        · simp only [namesAt, Option.getD_some] at member
          obtain ⟨cs, path, inCs⟩ := ih hS q' c o inner member
          exact ⟨cs, record_path_mem _ 2 aa q' cs rfl path, inCs⟩
  | err e s w' inner' ih =>
    intro q c o located member
    cases located with
    | @field _ i x q' _ xs_i inner =>
      cases shape with
      | bottom _ => simp [namesAt, Abstract.cellsAt, Abstract.paths] at member
      | result _ _ ae aa hE hS =>
        rcases getElem?_three xs_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
        · cases inner
        · simp only [namesAt, Option.getD_some] at member
          obtain ⟨cs, path, inCs⟩ := ih hE q' c o inner member
          exact ⟨cs, record_path_mem _ 1 ae q' cs rfl path, inCs⟩
        · cases inner

/-- The facts of the checker's spine test for one stored value: its container
positions are separated, none aliases the other operands' cells, and none
aliases a cell of the value at a position that is not a container. -/
theorem storeSpines_facts {ctx : Context} {item : Abstract} {later other : List Origin}
    (h : storeSpines ctx [item] later other = true) :
    separatedPaths (containers item) = true ∧
    ∀ entry ∈ containers item, cellOverlap entry.2 (union later other) = false ∧
      ∀ entry' ∈ item.paths, containerPath entry'.1 = true ∨ cellOverlap entry.2 entry'.2 = false := by
  unfold storeSpines at h
  simp only [List.flatMap_cons, List.flatMap_nil, List.append_nil] at h
  rw [Bool.and_eq_true] at h
  obtain ⟨sep, all⟩ := h
  refine ⟨sep, ?_⟩
  intro entry member
  have h1 := List.all_eq_true.mp all entry member
  obtain ⟨p, cs⟩ := entry
  simp only [List.all_cons, List.all_nil, Bool.and_true, Bool.and_eq_true, Bool.not_eq_true'] at h1
  obtain ⟨⟨_, disjoint⟩, inner⟩ := h1
  refine ⟨disjoint, ?_⟩
  intro entry' member'
  have h2 := List.all_eq_true.mp inner entry' member'
  obtain ⟨q, ds⟩ := entry'
  simp only [Bool.or_eq_true, Bool.not_eq_true'] at h2
  exact h2

/-- The facts of the receiver's container positions at a store: none aliases a
cell of the stored value. -/
theorem containers_all_facts {ctx : Context} {element item : Abstract}
    (h : (containers element).all (fun (_, old) => individuallyOwned ctx old && !cellOverlap old item.cells) = true) :
    ∀ entry ∈ containers element, cellOverlap entry.2 item.cells = false := by
  intro entry member
  have h1 := List.all_eq_true.mp h entry member
  obtain ⟨p, old⟩ := entry
  simp only [Bool.and_eq_true, Bool.not_eq_true'] at h1
  exact h1.2

/-- The Disjoint test of a demand under the default configuration. -/
theorem demand_success_disjoint {gamma : Naming} {before after : St} {result : Unit}
    {cs later others : List Origin} (separating : Separating gamma)
    (run : (demand ({} : Config) cs later others).run before = .ok (result, after)) :
    ∀ c, named gamma cs c → ¬ named gamma others c :=
  (demandProblem_sound gamma separating ({} : Config) before.facts.escapes cs later others
    (demand_success_problem run)).2.2 (default_has _)

/-- A covered value reaches no array named by cells apart from its own. -/
theorem value_apart_root {gamma : Naming} {heap : Heap} {a : Abstract} {w : Value} {t : Ty}
    {roots others : List Origin} {root : Nat}
    (shape : FlatAbstract t a) (covers : Covers gamma heap a w) (rootNamed : named gamma roots root)
    (disjoint : ∀ c, named gamma roots c → ¬ named gamma others c) (sub : ∀ o ∈ a.cells, o ∈ others) :
    ¬ Reaches heap w (.ref root) := by
  intro reach
  obtain ⟨q, located⟩ := arrayAt_of_reaches reach
  obtain ⟨o, member, address⟩ := covers q root located
  exact disjoint root rootNamed ⟨o, sub o (namesAt_subset_cells shape q o member), address⟩

mutual
/-- A container array that one path alone reaches appears at most once in a
footprint: a record's fields are distinct positions, and a container path has
no element step. -/
theorem count_le_one_of_container_unique {heap : Heap} {n : Nat} {w : Value} {o : Observation}
    {fp : List Nat} {c : Nat} (rep : Represents heap n w o fp) :
    ∀ (p : Path), containerPath p = true → (∀ q, ArrayAt heap w q c → q = p) → fp.count c ≤ 1 := by
  intro p container unique
  cases rep with
  | int => simp
  | record children =>
    exact countMany_le_one_of_container_unique children 0 p container
      (fun i x q xs_i locatedX => by rw [Nat.zero_add]; exact unique (.field i :: q) (.field xs_i locatedX))
  | closure children =>
    have zero : List.count c _ = 0 := List.count_eq_zero_of_not_mem (fun member => by
      obtain ⟨x, xMember, reach⟩ :=
        Ownership.FlatFragment.Support.representsMany_footprint_reaches children c member
      obtain ⟨q, locatedX⟩ := arrayAt_of_reaches reach
      obtain ⟨i, caps_i⟩ := List.mem_iff_getElem?.mp xMember
      have eq := unique (.capture i :: q) (.capture caps_i locatedX)
      subst eq
      simp [containerPath] at container)
    rw [zero]
    exact Nat.zero_le _
  | @ref c' _ _ _ _ lookup children =>
    have zero : List.count c _ = 0 := List.count_eq_zero_of_not_mem (fun member => by
      obtain ⟨x, xMember, reach⟩ :=
        Ownership.FlatFragment.Support.representsMany_footprint_reaches children c member
      obtain ⟨q, locatedX⟩ := arrayAt_of_reaches reach
      have eq := unique (.element :: q) (.element lookup xMember locatedX)
      subst eq
      simp [containerPath] at container)
    rw [List.count_cons, zero]
    split <;> simp

theorem countMany_le_one_of_container_unique {heap : Heap} {n : Nat} {ws : List Value}
    {os : List Observation} {cs : List Nat} {c : Nat} (children : RepresentsMany heap n ws os cs) :
    ∀ (k : Nat) (p : Path), containerPath p = true →
      (∀ (i : Nat) x q, ws[i]? = some x → ArrayAt heap x q c → .field (k + i) :: q = p) → cs.count c ≤ 1 := by
  intro k p container unique
  cases children with
  | nil => simp
  | @cons _ _ _ c0 _ _ ds first rest =>
    by_cases headReach : c ∈ c0
    · have tailZero : ds.count c = 0 := List.count_eq_zero_of_not_mem (fun member => by
        obtain ⟨y, yMember, reach⟩ :=
          Ownership.FlatFragment.Support.representsMany_footprint_reaches rest c member
        obtain ⟨q, locatedY⟩ := arrayAt_of_reaches reach
        obtain ⟨j, vs_j⟩ := List.mem_iff_getElem?.mp yMember
        have eq1 := unique (j + 1) y q (by simpa using vs_j) locatedY
        obtain ⟨q0, located0⟩ :=
          arrayAt_of_reaches (Ownership.FlatFragment.Support.represents_footprint_reaches first c headReach)
        have eq0 := unique 0 _ q0 rfl located0
        rw [← eq0] at eq1
        have := Step.field.inj (List.cons.inj eq1).1
        omega)
      obtain ⟨q0, located0⟩ :=
        arrayAt_of_reaches (Ownership.FlatFragment.Support.represents_footprint_reaches first c headReach)
      have eq0 := unique 0 _ q0 rfl located0
      have container0 : containerPath q0 = true := by
        rw [← eq0] at container
        simpa [containerPath] using container
      have headLe : c0.count c ≤ 1 :=
        count_le_one_of_container_unique first q0 container0 (fun q locatedQ => by
          have := unique 0 _ q rfl locatedQ
          rw [← eq0] at this
          exact (List.cons.inj this).2)
      rw [List.count_append, tailZero]
      omega
    · have headZero : c0.count c = 0 := List.count_eq_zero_of_not_mem headReach
      rw [List.count_append, headZero, Nat.zero_add]
      exact countMany_le_one_of_container_unique rest (k + 1) p container
        (fun i x q vs_i locatedX => by
          have := unique (i + 1) x q (by simpa using vs_i) locatedX
          rwa [show k + (i + 1) = k + 1 + i by omega] at this)
end

/-- The stored value's container positions are each once in its footprint
when the spine test passed: two paths to one array would name it twice. -/
theorem once_of_storeSpines {gamma : Naming} {heap : Heap} {ctx : Context} {later other : List Origin}
    {item : Abstract} {w : Value} {t : Ty}
    (separating : Separating gamma) (shapeI : FlatAbstract t item) (allocated : AllocatedFlatValue heap w t)
    (covers : Covers gamma heap item w) (spines : storeSpines ctx [item] later other = true) :
    ∀ n o fp, Represents heap n w o fp →
      ∀ p c, containerPath p = true → ArrayAt heap w p c → fp.count c = 1 := by
  intro n o fp rep p c container located
  obtain ⟨sep, each⟩ := storeSpines_facts spines
  have unique : ∀ q, ArrayAt heap w q c → q = p := by
    intro q locatedQ
    apply Classical.byContradiction
    intro different
    obtain ⟨o1, m1, a1⟩ := covers p c located
    obtain ⟨o2, m2, a2⟩ := covers q c locatedQ
    obtain ⟨cs1, e1, in1⟩ := mem_namesAt_of_arrayAt shapeI allocated p c o1 located m1
    obtain ⟨cs2, e2, in2⟩ := mem_namesAt_of_arrayAt shapeI allocated q c o2 locatedQ m2
    have c1 : (p, cs1) ∈ containers item := List.mem_filter.mpr ⟨e1, container⟩
    by_cases containerQ : containerPath q = true
    · have c2 : (q, cs2) ∈ containers item := List.mem_filter.mpr ⟨e2, containerQ⟩
      obtain ⟨i, at_i⟩ := List.mem_iff_getElem?.mp c1
      obtain ⟨j, at_j⟩ := List.mem_iff_getElem?.mp c2
      have ne : i ≠ j := by
        intro same
        subst same
        rw [at_i] at at_j
        exact different (Prod.mk.inj (Option.some.inj at_j)).1.symm
      rcases Nat.lt_or_gt_of_ne ne with lt | gt
      · exact cellOverlap_sound gamma separating cs1 cs2
          (separatedPaths_sound sep i j lt p cs1 q cs2 at_i at_j) c ⟨o1, in1, a1⟩ ⟨o2, in2, a2⟩
      · exact cellOverlap_sound gamma separating cs2 cs1
          (separatedPaths_sound sep j i gt q cs2 p cs1 at_j at_i) c ⟨o2, in2, a2⟩ ⟨o1, in1, a1⟩
    · rcases (each (p, cs1) c1).2 (q, cs2) e2 with h | h
      · exact containerQ h
      · exact cellOverlap_sound gamma separating cs1 cs2 h c ⟨o1, in1, a1⟩ ⟨o2, in2, a2⟩
  have pos : 0 < fp.count c :=
    List.count_pos_iff.mpr (Ownership.FlatFragment.FiniteReach.represents_reach_member rep (reaches_of_atPath located))
  have le := count_le_one_of_container_unique rep p container unique
  omega

/-! ### The store tests over several stored values (the literal, slice 2b of #522) -/

/-- The index test of separated paths, as a pairwise relation. -/
theorem separatedPaths_iff_pairwise {L : List (Path × List Origin)} :
    separatedPaths L = true ↔ L.Pairwise (fun e f => cellOverlap e.2 f.2 = false) := by
  constructor
  · intro sep
    rw [List.pairwise_iff_getElem]
    intro i j hi hj lt
    exact separatedPaths_sound sep i j lt _ _ _ _ (List.getElem?_eq_getElem hi) (List.getElem?_eq_getElem hj)
  · intro pw
    unfold separatedPaths
    rw [List.all_eq_true]
    intro entry member
    obtain ⟨⟨p, cs⟩, i⟩ := entry
    rw [List.mem_zipIdx_iff_getElem?] at member
    rw [List.all_eq_true]
    intro entry' member'
    obtain ⟨q, ds⟩ := entry'
    obtain ⟨k, at_k⟩ := List.mem_iff_getElem?.mp member'
    rw [List.getElem?_drop] at at_k
    have hi : i < L.length := (List.getElem?_eq_some_iff.mp member).1
    have hj : i + 1 + k < L.length := (List.getElem?_eq_some_iff.mp at_k).1
    have h := List.pairwise_iff_getElem.mp pw i (i + 1 + k) hi hj (by omega)
    rw [List.getElem?_eq_getElem hi] at member
    rw [List.getElem?_eq_getElem hj] at at_k
    have e1 : L[i] = (p, cs) := Option.some.inj member
    have e2 : L[i + 1 + k] = (q, ds) := Option.some.inj at_k
    rw [e1, e2] at h
    simpa using h

/-- Separated paths of a part of a list are separated. -/
theorem separatedPaths_sublist {L L' : List (Path × List Origin)} (sub : List.Sublist L' L)
    (sep : separatedPaths L = true) : separatedPaths L' = true :=
  separatedPaths_iff_pairwise.mpr ((separatedPaths_iff_pairwise.mp sep).sublist sub)

theorem sublist_flatMap_of_mem {α β : Type} {f : α → List β} {xs : List α} {a : α} (member : a ∈ xs) :
    List.Sublist (f a) (xs.flatMap f) := by
  induction xs with
  | nil => simp at member
  | cons x rest ih =>
    rw [List.flatMap_cons]
    rcases List.mem_cons.mp member with rfl | tail
    · exact List.sublist_append_left _ _
    · exact (ih tail).trans (List.sublist_append_right _ _)

/-- Container positions of two stored values at distinct indices are separated. -/
theorem separatedPaths_flatMap_cross {xs : List Abstract}
    (sep : separatedPaths (xs.flatMap containers) = true) :
    ∀ (i j : Nat), i < j → ∀ a b, xs[i]? = some a → xs[j]? = some b →
      ∀ e ∈ containers a, ∀ f ∈ containers b, cellOverlap e.2 f.2 = false := by
  have pw := separatedPaths_iff_pairwise.mp sep
  clear sep
  induction xs with
  | nil => intro i j _ a b at_i; simp at at_i
  | cons x rest ih =>
    rw [List.flatMap_cons, List.pairwise_append] at pw
    intro i j lt a b at_i at_j e eMember f fMember
    cases i with
    | zero =>
      simp at at_i
      subst at_i
      cases j with
      | zero => omega
      | succ j' =>
        simp at at_j
        exact pw.2.2 e eMember f (List.mem_flatMap.mpr ⟨b, List.mem_of_getElem? at_j, fMember⟩)
    | succ i' =>
      cases j with
      | zero => omega
      | succ j' =>
        simp at at_i at_j
        exact ih pw.2.1 _ _ (by omega) a b at_i at_j e eMember f fMember

/-- The checker's exclusivity test over the stored values of a literal. -/
theorem storeExclusive_facts_many {ctx : Context} {xs : List Abstract} {later other : List Origin}
    (h : storeExclusive ctx xs later other = true) :
    (∀ v ∈ xs, v.deepExclusive = true) ∧ separatedValues xs = true ∧
      ∀ v ∈ xs, cellOverlap v.cells (union later other) = false := by
  unfold storeExclusive at h
  rw [Bool.and_eq_true, Bool.and_eq_true] at h
  obtain ⟨⟨premise, separated⟩, owned⟩ := h
  refine ⟨?_, separated, ?_⟩
  · rw [Bool.or_eq_true] at premise
    rcases premise with deep | impossible
    · exact List.all_eq_true.mp deep
    · simp at impossible
  · intro v member
    have h1 := List.all_eq_true.mp owned v member
    rw [Bool.and_eq_true, Bool.not_eq_true'] at h1
    exact h1.2

/-- Separated values: each has separated paths, and two at distinct indices
share no cell. -/
theorem separatedValues_sound {xs : List Abstract} (sep : separatedValues xs = true) :
    (∀ v ∈ xs, separatedPaths v.paths = true) ∧
      ∀ (i j : Nat), i < j → ∀ a b, xs[i]? = some a → xs[j]? = some b →
        cellOverlap a.cells b.cells = false := by
  unfold separatedValues at sep
  rw [List.all_eq_true] at sep
  constructor
  · intro v member
    obtain ⟨i, at_i⟩ := List.mem_iff_getElem?.mp member
    have h := sep (v, i) (List.mem_zipIdx_iff_getElem?.mpr at_i)
    rw [Bool.and_eq_true] at h
    exact h.1
  · intro i j lt a b at_i at_j
    have h := sep (a, i) (List.mem_zipIdx_iff_getElem?.mpr at_i)
    rw [Bool.and_eq_true] at h
    have inner := List.all_eq_true.mp h.2 b (by
      rw [List.mem_iff_getElem?]
      refine ⟨j - (i + 1), ?_⟩
      rw [List.getElem?_drop, show i + 1 + (j - (i + 1)) = j by omega]
      exact at_j)
    simpa using inner

/-- The checker's spine test over the stored values of a literal. -/
theorem storeSpines_facts_many {ctx : Context} {xs : List Abstract} {later other : List Origin}
    (h : storeSpines ctx xs later other = true) :
    separatedPaths (xs.flatMap containers) = true ∧
    ∀ a ∈ xs, ∀ e ∈ containers a, cellOverlap e.2 (union later other) = false ∧
      ∀ b ∈ xs, ∀ f ∈ b.paths, containerPath f.1 = true ∨ cellOverlap e.2 f.2 = false := by
  unfold storeSpines at h
  rw [Bool.and_eq_true] at h
  obtain ⟨sep, all⟩ := h
  refine ⟨sep, ?_⟩
  intro a aMember e eMember
  have h1 := List.all_eq_true.mp all e (List.mem_flatMap.mpr ⟨a, aMember, eMember⟩)
  obtain ⟨p, cs⟩ := e
  simp only [Bool.and_eq_true, Bool.not_eq_true'] at h1
  obtain ⟨⟨_, disjoint⟩, inner⟩ := h1
  refine ⟨disjoint, ?_⟩
  intro b bMember f fMember
  have h2 := List.all_eq_true.mp (List.all_eq_true.mp inner b bMember) f fMember
  obtain ⟨q, ds⟩ := f
  simp only [Bool.or_eq_true, Bool.not_eq_true'] at h2
  exact h2

/-- A container array of a stored value is once in its footprint, from the
separation of its container positions and of each from its other positions. -/
theorem once_of_separated {gamma : Naming} {heap : Heap} {item : Abstract} {w : Value} {t : Ty}
    (separating : Separating gamma) (shapeI : FlatAbstract t item) (allocated : AllocatedFlatValue heap w t)
    (covers : Covers gamma heap item w)
    (sep : separatedPaths (containers item) = true)
    (nonContainer : ∀ e ∈ containers item, ∀ f ∈ item.paths,
      containerPath f.1 = true ∨ cellOverlap e.2 f.2 = false) :
    ∀ n o fp, Represents heap n w o fp →
      ∀ p c, containerPath p = true → ArrayAt heap w p c → fp.count c = 1 := by
  intro n o fp rep p c container located
  have unique : ∀ q, ArrayAt heap w q c → q = p := by
    intro q locatedQ
    apply Classical.byContradiction
    intro different
    obtain ⟨o1, m1, a1⟩ := covers p c located
    obtain ⟨o2, m2, a2⟩ := covers q c locatedQ
    obtain ⟨cs1, e1, in1⟩ := mem_namesAt_of_arrayAt shapeI allocated p c o1 located m1
    obtain ⟨cs2, e2, in2⟩ := mem_namesAt_of_arrayAt shapeI allocated q c o2 locatedQ m2
    have c1 : (p, cs1) ∈ containers item := List.mem_filter.mpr ⟨e1, container⟩
    by_cases containerQ : containerPath q = true
    · have c2 : (q, cs2) ∈ containers item := List.mem_filter.mpr ⟨e2, containerQ⟩
      obtain ⟨i, at_i⟩ := List.mem_iff_getElem?.mp c1
      obtain ⟨j, at_j⟩ := List.mem_iff_getElem?.mp c2
      have ne : i ≠ j := by
        intro same
        subst same
        rw [at_i] at at_j
        exact different (Prod.mk.inj (Option.some.inj at_j)).1.symm
      rcases Nat.lt_or_gt_of_ne ne with lt | gt
      · exact cellOverlap_sound gamma separating cs1 cs2
          (separatedPaths_sound sep i j lt p cs1 q cs2 at_i at_j) c ⟨o1, in1, a1⟩ ⟨o2, in2, a2⟩
      · exact cellOverlap_sound gamma separating cs2 cs1
          (separatedPaths_sound sep j i gt q cs2 p cs1 at_j at_i) c ⟨o2, in2, a2⟩ ⟨o1, in1, a1⟩
    · rcases nonContainer (p, cs1) c1 (q, cs2) e2 with h | h
      · exact containerQ h
      · exact cellOverlap_sound gamma separating cs1 cs2 h c ⟨o1, in1, a1⟩ ⟨o2, in2, a2⟩
  have pos : 0 < fp.count c :=
    List.count_pos_iff.mpr (Ownership.FlatFragment.FiniteReach.represents_reach_member rep (reaches_of_atPath located))
  have le := count_le_one_of_container_unique rep p container unique
  omega

/-- The count of one array in a joint footprint, when one element holds it
and no other reaches it. -/
theorem countMany_eq_of_holder {heap : Heap} {n : Nat} {ws : List Value} {os : List Observation}
    {cs : List Nat} {c k : Nat} (children : RepresentsMany heap n ws os cs) :
    ∀ (i : Nat) w, ws[i]? = some w →
      (∀ (j : Nat) y, ws[j]? = some y → j ≠ i → ¬ Reaches heap y (.ref c)) →
      (∀ o fp, Represents heap n w o fp → fp.count c = k) → cs.count c = k := by
  induction ws generalizing os cs with
  | nil => intro i w at_i; simp at at_i
  | cons y ys ih =>
    intro i w at_i others once
    cases children with
    | @cons _ _ _ c0 _ _ ds first rest =>
      rw [List.count_append]
      cases i with
      | zero =>
        simp at at_i
        subst at_i
        have tailZero : ds.count c = 0 := List.count_eq_zero_of_not_mem (fun member => by
          obtain ⟨z, zMember, reach⟩ :=
            Ownership.FlatFragment.Support.representsMany_footprint_reaches rest c member
          obtain ⟨j, at_j⟩ := List.mem_iff_getElem?.mp zMember
          exact others (j + 1) z (by simpa using at_j) (by omega) reach)
        simp [once _ _ first, tailZero]
      | succ i' =>
        simp at at_i
        have headZero : c0.count c = 0 := List.count_eq_zero_of_not_mem (fun member =>
          others 0 y rfl (by omega)
            (Ownership.FlatFragment.Support.represents_footprint_reaches first c member))
        rw [headZero, Nat.zero_add]
        exact ih rest i' w at_i
          (fun j z at_j ne => others (j + 1) z (by simpa using at_j) (by omega)) once

/-- A fresh list's footprint repeats no array: each element's footprint does
not, two elements share no array, and no element reaches the list. -/
theorem fresh_footprint_nodup {heap : Heap} {root : Nat} {ws : List Value}
    (lookup : heap[root]? = some ws)
    (rootApart : ∀ z ∈ ws, ¬ Reaches heap z (.ref root))
    (each : ∀ (i : Nat) w, ws[i]? = some w → ∀ n o fp, Represents heap n w o fp → fp.Nodup)
    (apart : ∀ (i j : Nat), i ≠ j → ∀ wi wj, ws[i]? = some wi → ws[j]? = some wj →
      ∀ c, Reaches heap wi (.ref c) → ¬ Reaches heap wj (.ref c)) :
    ∀ n o fp, Represents heap n (.ref root) o fp → fp.Nodup := by
  intro n o fp rep
  cases rep with
  | ref lookup' children =>
    rw [lookup] at lookup'
    cases lookup'
    rw [List.nodup_cons]
    refine ⟨fun member => ?_, ?_⟩
    · obtain ⟨z, zMember, reach⟩ :=
        Ownership.FlatFragment.Support.representsMany_footprint_reaches children root member
      exact rootApart z zMember reach
    · exact representsMany_nodup_of_apart children (fun i w o' c' at_i _ rep' => each i w at_i _ o' c' rep') apart

/-- A fresh list holds each container array of an element once: once in that
element's footprint and in no other's. -/
theorem fresh_footprint_once {heap : Heap} {root : Nat} {ws : List Value}
    (lookup : heap[root]? = some ws)
    (rootApart : ∀ z ∈ ws, ¬ Reaches heap z (.ref root))
    (eachOnce : ∀ (i : Nat) w, ws[i]? = some w → ∀ n o fp, Represents heap n w o fp →
      ∀ p c, containerPath p = true → ArrayAt heap w p c → fp.count c = 1)
    (apart : ∀ (i j : Nat), i ≠ j → ∀ wi wj, ws[i]? = some wi → ws[j]? = some wj →
      ∀ p c, containerPath p = true → ArrayAt heap wi p c → ¬ Reaches heap wj (.ref c)) :
    ∀ n o fp, Represents heap n (.ref root) o fp →
      ∀ p c, containerPath p = true → ArrayAt heap (.ref root) (.element :: p) c → fp.count c = 1 := by
  intro n o fp rep p c container located
  cases rep with
  | ref lookup' children =>
    rw [lookup] at lookup'
    cases lookup'
    cases located with
    | @element _ _ z _ _ lookup'' zMember inner =>
      rw [lookup] at lookup''
      cases lookup''
      have notRoot : c ≠ root := by
        intro same
        subst same
        exact rootApart z zMember (reaches_of_atPath inner)
      obtain ⟨i, at_i⟩ := List.mem_iff_getElem?.mp zMember
      rw [List.count_cons, if_neg (by simpa using Ne.symm notRoot), Nat.add_zero]
      exact countMany_eq_of_holder children i z at_i
        (fun j y at_j ne reach => apart i j (Ne.symm ne) z y at_i at_j p c container inner reach)
        (fun o' fp' rep' => eachOnce i z at_i _ o' fp' rep' p c container inner)

theorem describes_mapOrigins_shared {gamma : Naming} {heap : Heap} {w : Value} {ty : Ty} {a : Abstract}
    (shape : AllocatedFlatValue heap w ty) (abs : FlatAbstract ty a)
    (described : Describes gamma heap a w) (path : Path) :
    Describes gamma heap (a.mapOrigins sharedMark path) w := by
  induction shape generalizing a path with
  | int integer => exact integer_described_any _ integer
  | list root ys t lookup elements ih =>
    cases abs with
    | bottom _ =>
      rw [mapOrigins_bottom]
      exact described
    | list _ roots element certificate noUnk elemShape =>
      have rootsNamed : named gamma roots root := by
        have names := described.1.1 [] root (.here _)
        rw [list_root_names] at names
        exact named_union_nil names
      have elementsDescribed : ∀ y ∈ ys, Describes gamma heap (element.mapOrigins sharedMark (path ++ [.element])) y :=
        fun y member => ih y member elemShape (describes_element noUnk lookup member described) _
      simp only [Abstract.mapOrigins]
      refine ⟨⟨list_covers_of_elements (named_sharedMark path rootsNamed) (sharedMark_no_unknown path noUnk)
        lookup (fun y member => (elementsDescribed y member).1.1), ?_⟩,
        list_closures_of_elements lookup (fun y member => (elementsDescribed y member).2)⟩
      intro q cs e ex w' shape' located n o fp rep
      cases located with
      | here =>
        simp [Abstract.atPath] at shape'
        obtain ⟨rfl, rfl, rfl⟩ := shape'
        exact described.1.2 [] roots element certificate (.ref root) rfl (.here _) n o fp rep
      | element lookup' member inner =>
        rw [lookup] at lookup'
        cases lookup'
        exact (elementsDescribed _ member).1.2 _ cs e ex w' (by simpa [Abstract.atPath] using shape') inner n o fp rep
  | chain root integers lookupRoot =>
    cases abs with
    | bottom _ =>
      rw [mapOrigins_bottom]
      exact described
    | chainBottom roots certificate =>
      have names := described.1.1 [] root (.here _)
      rw [list_root_names] at names
      simp only [Abstract.mapOrigins]
      exact allocated_list_described lookupRoot (named_sharedMark path (named_union_nil names))
    | chainScalar roots certificate =>
      have names := described.1.1 [] root (.here _)
      rw [list_root_names] at names
      simp only [Abstract.mapOrigins]
      exact allocated_list_described lookupRoot (named_sharedMark path (named_union_nil names))
  | record ws ts len _ ih =>
    cases abs with
    | bottom _ =>
      rw [mapOrigins_bottom]
      exact described
    | record _ as lenTA fieldsA =>
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
  | ok e s w' _ ih =>
    cases abs with
    | bottom _ =>
      rw [mapOrigins_bottom]
      exact described
    | result _ _ ae aa hE hS =>
      rw [mapOrigins_three, mapOrigins_scalar]
      refine describes_record_of_fields rfl ?_
      intro i a' w'' as_i ws_i
      rcases three_pair as_i ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
      · exact integer_described 1
      · exact integer_described_any _ 0
      · exact ih hS (describes_field (i := 2) described rfl rfl) _
  | err e s w' _ ih =>
    cases abs with
    | bottom _ =>
      rw [mapOrigins_bottom]
      exact described
    | result _ _ ae aa hE hS =>
      rw [mapOrigins_three, mapOrigins_scalar]
      refine describes_record_of_fields rfl ?_
      intro i a' w'' as_i ws_i
      rcases three_pair as_i ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
      · exact integer_described 0
      · exact ih hE (describes_field (i := 1) described rfl rfl) _
      · exact integer_described_any _ 0

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
      FlatType ty ∧ FlatAbstract ty a ∧ AllocatedFlatValue hs.heap w ty ∧ ResultTags ty a w ∧
      ChainTags ty a o := by
  cases root : atomRoot atom with
  | none =>
    obtain ⟨n, rfl, rfl⟩ := atom_int_of_root_none typed root
    exact ⟨.int n, .int n, .scalar, rfl, rfl, rfl, integer_corresponds n, integer_described n,
      by simp [obsTyped], ⟨1, .int n, [], .int, by simp [obsTyped]⟩, .int, .int, .int n, .int _, .int _ _⟩
  | some kp =>
    rcases kp with ⟨k, p⟩
    obtain ⟨tk, declared, at_p⟩ := atom_type_of_root typed root
    obtain ⟨pair, binding⟩ := lookup_exists_of_same_keys env tenv inv.typeKeys declared
    rcases pair with ⟨o0, w0⟩
    obtain ⟨a0, abstractBinding⟩ := lookup_exists_of_same_keys aenv env inv.abstractKeys.symm binding
    have use : (k, p) ∈ live := covered (k, p) (by rw [atomUses_of_root root]; simp)
    obtain ⟨o, w, obsPath, valuePath, paired⟩ := inv.bindings k p use o0 w0 binding
    have described := inv.described k p use o0 w0 a0 w binding abstractBinding valuePath
    obtain ⟨t', o', w', at_p', obsPath', valuePath', observed, allocated⟩ :=
      inv.bindingsTyped k p use o0 w0 tk binding declared
    rw [at_p] at at_p'
    cases Option.some.inj at_p'
    rw [obsPath] at obsPath'
    cases Option.some.inj obsPath'
    rw [valuePath] at valuePath'
    cases Option.some.inj valuePath'
    have flatTk := inv.types k tk declared
    have shape0 := inv.abstractShapes k tk a0 declared abstractBinding
    have tags0 := inv.tags k tk a0 o0 w0 declared abstractBinding binding
    have chains0 := inv.chains k tk a0 o0 w0 declared abstractBinding binding
    exact ⟨o, w, a0.atPath p, value_atom_of_root root (valueEnv_lookup binding) obsPath,
      heap_atom_of_root root (heapEnv_lookup binding) valuePath,
      abstractAtom_of_root root abstractBinding shape0 tags0 valuePath at_p, paired, described,
      observed, valueTyped_of_allocated allocated,
      flatType_tyAt flatTk at_p, flatAbstract_atPath shape0 at_p, allocated,
      resultTags_project tags0 shape0 at_p valuePath, chainTags_project chains0 shape0 at_p obsPath⟩

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
  obtain ⟨o, w, a, valueRun, heapRun, abstractRun, paired, _, _, _, _, _, _, tags, _⟩ :=
    flat_atom_values inv typed covered
  cases tags with
  | int integer =>
    have observed := corresponds_int_inv paired
    subst observed
    exact ⟨integer, valueRun, heapRun, abstractRun⟩

/-- A `List t`-typed atom whose uses are live is an allocated array of shaped
and described elements on the heap side, the list of their observations on the
value side, and a named flat list in the checker. -/
theorem flat_atom_list_path {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {atom : Atom} {t : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (typed : atomType tenv atom = .ok (.list t))
    (covered : ∀ use ∈ atomUses atom, use ∈ live) :
    ∃ (root : Nat) (ys : List Value) (os : List Observation) (roots : List Origin) (element : Abstract)
      (certificate : Certificate),
      hs.heap[root]? = some ys ∧
      named gamma roots root ∧ Origin.unknown ∉ roots ∧
      FlatType t ∧ ElementType t ∧ FlatAbstract t element ∧
      (∀ y ∈ ys, AllocatedFlatValue hs.heap y t) ∧
      (∀ y ∈ ys, Describes gamma hs.heap element y) ∧
      os.length = ys.length ∧
      (∀ o ∈ os, obsTyped declarations o t = true) ∧
      (∀ (i : Nat) (o : Observation) (y : Value), os[i]? = some o → ys[i]? = some y → Corresponds hs.heap o y) ∧
      Corresponds hs.heap (.list os) (.ref root) ∧
      Describes gamma hs.heap (.list roots element certificate) (.ref root) ∧
      ValueSemantics.atom (valueEnv env) atom = .ok (.list os) ∧
      InPlaceSemantics.atom (heapEnv env) atom = .ok (.ref root) ∧
      abstractAtom aenv atom = .ok (.list roots element certificate) := by
  obtain ⟨o, w, a, valueRun, heapRun, abstractRun, paired, described, observed, _, flatList, shape, allocated, tags, _⟩ :=
    flat_atom_values inv typed covered
  cases tags with
  | list _ roots element certificate _ =>
    cases allocated with
    | list root ys _ lookup elements =>
      cases shape with
      | list _ _ _ _ noUnk elemShape =>
        obtain ⟨os, rfl, lenO, pointwise⟩ := corresponds_list_elements lookup paired
        have names := described.1.1 [] root (.here _)
        rw [list_root_names] at names
        have elemT : ElementType t := by
          cases flatList with
          | list _ elemT => exact elemT
        exact ⟨root, ys, os, roots, element, certificate, lookup, named_union_nil names, noUnk,
          elementType_flat elemT, elemT, elemShape,
          elements, fun y member => describes_element noUnk lookup member described, lenO,
          obsTyped_list_elements observed, pointwise, paired,
          described, valueRun, heapRun, abstractRun⟩

/-! ### A list described through its elements (slice 2b of #522) -/

/-- A list whose root is named, whose elements are described and whose own
certificate holds is described. -/
theorem list_described_of_elements {gamma : Naming} {heap : Heap} {cs : List Origin} {e : Abstract}
    {ex : Certificate} {root : Nat} {ys : List Value} {t : Ty}
    (rootNamed : named gamma cs root) (noUnk : Origin.unknown ∉ cs) (lookup : heap[root]? = some ys)
    (shape : AllocatedFlatValue heap (.ref root) (.list t))
    (elements : ∀ y ∈ ys, Describes gamma heap e y)
    (deep : ex.deep = true → ∀ n o fp, Represents heap n (.ref root) o fp → fp.Nodup)
    (spine : ex.spine = true → ∀ n o fp, Represents heap n (.ref root) o fp →
      ∀ p c, containerPath p = true → ArrayAt heap (.ref root) (.element :: p) c → fp.count c = 1) :
    Describes gamma heap (.list cs e ex) (.ref root) := by
  refine ⟨⟨list_covers_of_elements rootNamed noUnk lookup (fun y member => (elements y member).1.1), ?_⟩,
    closureAgreement_of_allocated shape _⟩
  intro q cs' e' ex' w at_q located n o fp rep
  cases q with
  | nil =>
    cases located
    simp only [Abstract.atPath, Abstract.list.injEq] at at_q
    obtain ⟨rfl, rfl, rfl⟩ := at_q
    exact ⟨fun d => deep d n o fp rep, fun sp => spine sp n o fp rep⟩
  | cons step q' =>
    cases step with
    | element =>
      cases located with
      | element lookup' member inner =>
        rw [lookup] at lookup'
        cases lookup'
        simp only [Abstract.atPath] at at_q
        exact (elements _ member).1.2 q' cs' e' ex' w at_q inner n o fp rep
    | field _ => simp [Abstract.atPath] at at_q
    | capture _ => simp [Abstract.atPath] at at_q
    | env => simp [Abstract.atPath] at at_q

/-- A covered value reaches no array its abstract's cells do not alias. -/
theorem cell_apart_of_covers {gamma : Naming} {heap : Heap} {a : Abstract} {w : Value} {t : Ty}
    {cs : List Origin} {root : Nat}
    (separating : Separating gamma) (shape : FlatAbstract t a) (covers : Covers gamma heap a w)
    (rootNamed : named gamma cs root) (disjoint : cellOverlap cs a.cells = false) :
    ¬ Reaches heap w (.ref root) := by
  intro reach
  obtain ⟨q, located⟩ := arrayAt_of_reaches reach
  obtain ⟨o, member, address⟩ := covers q root located
  exact cellOverlap_sound gamma separating cs a.cells disjoint root rootNamed
    ⟨o, namesAt_subset_cells shape q o member, address⟩

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
        FlatType t ∧ FlatAbstract t a ∧ AllocatedFlatValue hs.heap w t ∧ ResultTags t a w ∧
        ChainTags t a o := by
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
      flatType, shape, allocated, tags, chains⟩ := flat_atom_values inv headTyped (covered atom (by simp))
    refine ⟨o :: os, w :: ws, a :: as, except_mapM_cons valueHead valueRest,
      except_mapM_cons heapHead heapRest, except_mapM_cons abstractHead abstractRest,
      by simp [lenO], by simp [lenW], by simp [lenA], ?_⟩
    intro i o' w' a' t' os_i ws_i as_i types_i
    cases i with
    | zero =>
      simp at os_i ws_i as_i types_i
      subst os_i; subst ws_i; subst as_i; subst types_i
      exact ⟨paired, described, observed, valueTyped, flatType, shape, allocated, tags, chains⟩
    | succ i =>
      exact fields i o' w' a' t' (by simpa using os_i) (by simpa using ws_i) (by simpa using as_i)
        (by simpa using types_i)


/-- A `Chain Int`-typed atom whose uses are live is an allocated integer
array on the heap side, its observation on the value side, and a named flat
chain in the checker; a bottom element describes an empty chain. -/
theorem flat_atom_chain_path {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {atom : Atom}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (typed : atomType tenv atom = .ok (.chain .int))
    (covered : ∀ use ∈ atomUses atom, use ∈ live) :
    ∃ (root : Nat) (integers : List Int) (roots : List Origin) (element : Abstract)
      (certificate : Certificate),
      hs.heap[root]? = some (heapInts integers) ∧
      named gamma roots root ∧
      (element = .bottom ∨ element = .scalar) ∧
      (element = .bottom → integers = []) ∧
      ValueSemantics.atom (valueEnv env) atom = .ok (.list (valueInts integers)) ∧
      InPlaceSemantics.atom (heapEnv env) atom = .ok (.ref root) ∧
      abstractAtom aenv atom = .ok (.list roots element certificate) := by
  obtain ⟨o, w, a, valueRun, heapRun, abstractRun, paired, described, _, _, _, shape, allocated, tags,
    chains⟩ := flat_atom_values inv typed covered
  cases tags with
  | chainInt roots element certificate _ =>
    cases allocated with
    | chain root integers lookupRoot =>
      have observed := observation_of_integer_ref lookupRoot paired
      subst observed
      have names := described.1.1 [] root (.here _)
      rw [list_root_names] at names
      cases shape with
      | chainBottom _ _ =>
        have empty : integers = [] := by
          generalize eq : valueInts integers = os at chains
          cases chains with
          | chainBottom _ _ =>
            cases integers with
            | nil => rfl
            | cons _ _ => simp [valueInts] at eq
        exact ⟨root, integers, roots, .bottom, certificate, lookupRoot, named_union_nil names, Or.inl rfl,
          fun _ => empty, valueRun, heapRun, abstractRun⟩
      | chainScalar _ _ =>
        exact ⟨root, integers, roots, .scalar, certificate, lookupRoot, named_union_nil names, Or.inr rfl,
          (fun h => nomatch h), valueRun, heapRun, abstractRun⟩

/-- A path of the abstract at a projection is a path of the abstract, under
the projection. -/
theorem atPath_paths_prefix {tk t : Ty} {a : Abstract} {p : Path}
    (shape : FlatAbstract tk a) (at_p : tyAt tk p = some t) {q' : Path} {cs : List Origin}
    (path : (q', cs) ∈ (a.atPath p).paths) : (p ++ q', cs) ∈ a.paths := by
  induction p generalizing tk a with
  | nil => simpa [Abstract.atPath] using path
  | cons step rest ih =>
    cases step <;> cases tk <;> simp [tyAt] at at_p
    rename_i i ts
    cases h : ts[i]? with
    | none => simp [h] at at_p
    | some t' =>
      simp [h] at at_p
      rcases flatAbstract_record shape with rfl | ⟨as, rfl, lenTA, fieldsA⟩
      · simp [Abstract.atPath, Abstract.paths] at path
      · obtain ⟨a', as_i, abs'⟩ := flatAbstract_record_field lenTA fieldsA h
        simp only [Abstract.atPath, as_i, Option.getD_some] at path
        exact record_path_mem as i a' (rest ++ q') cs as_i (ih abs' at_p path)

/-- The Dead test of a write keeps every array of a live projected value
apart from the written root: the array is named by a cell at the binding's
path, that cell is a live cell, and the test refused any overlap. -/
theorem live_path_apart {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {after : Live} {escapes : List Origin} {roots : List Origin} {root : Nat} {pinned : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (scope : liveScope aenv after = .ok ())
    (afterSub : ∀ use ∈ after, use ∈ live)
    (receiverNamed : named gamma roots root)
    (separate : ∀ r, named gamma roots r → ¬ named gamma (union (liveCells aenv after) pinned) r) :
    ∀ x p, (x, p) ∈ after → ∀ o w w', env.lookup x = some (o, w) → projectVal w p = some w' →
      ∀ q c, ArrayAt hs.heap w' q c → c ≠ root := by
  intro x p use o w w' binding projected q c located same
  subst same
  obtain ⟨a, abstractBinding⟩ := liveScope_lookup_exists scope use
  obtain ⟨ty, declared⟩ := lookup_exists_of_same_keys tenv env inv.typeKeys.symm binding
  obtain ⟨t, at_p⟩ := inv.liveTyped x p ty (afterSub _ use) declared
  have shape0 := inv.abstractShapes x ty a declared abstractBinding
  have described := inv.described x p (afterSub _ use) o w a w' binding abstractBinding projected
  obtain ⟨origin, member, address⟩ := described.1.1 q c located
  obtain ⟨q', cs, path, inCs⟩ :=
    mem_paths_of_mem_cells (namesAt_subset_cells (flatAbstract_atPath shape0 at_p) q origin member)
  have inLive := cells_in_liveCells aenv after x p (p ++ q') a cs use abstractBinding
    (atPath_paths_prefix shape0 at_p path) (isPrefix_append p q') origin inCs
  exact separate c receiverNamed ⟨origin, mem_union _ _ origin (Or.inl inLive), address⟩

/-- Every array of a flat value sits below the heap bound. -/
theorem live_path_below {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {escapes : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma) :
    ∀ x p o w w', env.lookup x = some (o, w) → projectVal w p = some w' →
      ∀ q c, ArrayAt hs.heap w' q c → c < hs.heap.size := by
  intro x p o w w' binding projected q c located
  exact inv.bindingsBounded x o w binding c (reaches_of_atPath (arrayAt_of_project projected located))

/-! ### Branches: type equality, the join of two flat abstracts, more escapes -/

/-! ### The join's equations -/

theorem join_scalar : Abstract.scalar.join .scalar = .scalar := by simp [Abstract.join]
theorem join_bottom_bottom : Abstract.bottom.join .bottom = .bottom := by simp [Abstract.join]
theorem join_bottom_scalar : Abstract.bottom.join .scalar = .scalar := by simp [Abstract.join]
theorem join_scalar_bottom : Abstract.scalar.join .bottom = .scalar := by simp [Abstract.join]
theorem join_list (cs ds : List Origin) (x y : Abstract) (ex ey : Certificate) :
    (Abstract.list cs x ex).join (.list ds y ey) = .list (union cs ds) (x.join y) (ex.meet ey) := by
  simp [Abstract.join]
theorem join_record (xs ys : List Abstract) :
    (Abstract.record xs).join (.record ys) = .record ((xs.attach.zip ys).map fun (x, y) => x.val.join y) := by
  simp [Abstract.join]

theorem ty_equal_int (equal : (ty == Ty.int) = true) : ty = .int := by
  cases ty <;> simp [BEq.beq, Ty.equal] at equal ⊢

/-! ### Type equality on flat types -/

theorem ty_equal_element {t b : Ty} (element : ElementType t) (equal : Ty.equal t b = true) : t = b := by
  induction element generalizing b with
  | int => cases b <;> simp [Ty.equal] at equal ⊢
  | list t _ ih =>
    cases b with
    | list e =>
      simp [Ty.equal] at equal
      rw [ih equal]
    | _ => simp [Ty.equal] at equal
  | record ts _ ih =>
    cases b with
    | record ys =>
      rw [Ty.equal] at equal
      simp only [Bool.and_eq_true, beq_iff_eq, List.all_eq_true] at equal
      obtain ⟨len, all⟩ := equal
      congr 1
      apply List.ext_getElem?
      intro i
      cases ts_i : ts[i]? with
      | none =>
        rw [List.getElem?_eq_none_iff] at ts_i
        exact (List.getElem?_eq_none_iff.mpr (by omega)).symm
      | some x =>
        cases ys_i : ys[i]? with
        | none =>
          rw [List.getElem?_eq_none_iff] at ys_i
          have lt := (List.getElem?_eq_some_iff.mp ts_i).1
          omega
        | some y =>
          have mem : (⟨x, List.mem_of_getElem? ts_i⟩, y) ∈ ts.attach.zip ys := by
            apply List.mem_of_getElem? (i := i)
            rw [List.getElem?_zip_eq_some]
            exact ⟨by simp [List.getElem?_attach, ts_i], ys_i⟩
          rw [ih x (List.mem_of_getElem? ts_i) (all _ mem)]
    | _ => simp [Ty.equal] at equal

theorem ty_equal_flat {t b : Ty} (flat : FlatType t) (equal : Ty.equal t b = true) : t = b := by
  induction flat generalizing b with
  | int => cases b <;> simp [Ty.equal] at equal ⊢
  | list t element =>
    cases b with
    | list e =>
      simp [Ty.equal] at equal
      rw [ty_equal_element element equal]
    | _ => simp [Ty.equal] at equal
  | chainInt =>
    cases b with
    | chain e => cases e <;> simp [Ty.equal] at equal ⊢
    | _ => simp [Ty.equal] at equal
  | record ts _ ih =>
    cases b with
    | record ys =>
      rw [Ty.equal] at equal
      simp only [Bool.and_eq_true, beq_iff_eq, List.all_eq_true] at equal
      obtain ⟨len, all⟩ := equal
      congr 1
      apply List.ext_getElem?
      intro i
      cases ts_i : ts[i]? with
      | none =>
        rw [List.getElem?_eq_none_iff] at ts_i
        exact (List.getElem?_eq_none_iff.mpr (by omega)).symm
      | some x =>
        cases ys_i : ys[i]? with
        | none =>
          rw [List.getElem?_eq_none_iff] at ys_i
          have lt := (List.getElem?_eq_some_iff.mp ts_i).1
          omega
        | some y =>
          have mem : (⟨x, List.mem_of_getElem? ts_i⟩, y) ∈ ts.attach.zip ys := by
            apply List.mem_of_getElem? (i := i)
            rw [List.getElem?_zip_eq_some]
            exact ⟨by simp [List.getElem?_attach, ts_i], ys_i⟩
          rw [ih x (List.mem_of_getElem? ts_i) (all _ mem)]
    | _ => simp [Ty.equal] at equal
  | result e s _ _ ihE ihS =>
    cases b with
    | result f b' =>
      rw [Ty.equal] at equal
      simp only [Bool.and_eq_true] at equal
      rw [ihE equal.1, ihS equal.2]
    | _ => simp [Ty.equal] at equal

/-- Type equality from a flat right side. -/
theorem ty_equal_element_right {t b : Ty} (element : ElementType b) (equal : Ty.equal t b = true) : t = b := by
  induction element generalizing t with
  | int => cases t <;> simp [Ty.equal] at equal ⊢
  | list b _ ih =>
    cases t with
    | list e =>
      simp [Ty.equal] at equal
      rw [ih equal]
    | _ => simp [Ty.equal] at equal
  | record bs _ ih =>
    cases t with
    | record xs =>
      rw [Ty.equal] at equal
      simp only [Bool.and_eq_true, beq_iff_eq, List.all_eq_true] at equal
      obtain ⟨len, all⟩ := equal
      congr 1
      apply List.ext_getElem?
      intro i
      cases xs_i : xs[i]? with
      | none =>
        rw [List.getElem?_eq_none_iff] at xs_i
        exact (List.getElem?_eq_none_iff.mpr (by omega)).symm
      | some x =>
        cases bs_i : bs[i]? with
        | none =>
          rw [List.getElem?_eq_none_iff] at bs_i
          have lt := (List.getElem?_eq_some_iff.mp xs_i).1
          omega
        | some y =>
          have mem : (⟨x, List.mem_of_getElem? xs_i⟩, y) ∈ xs.attach.zip bs := by
            apply List.mem_of_getElem? (i := i)
            rw [List.getElem?_zip_eq_some]
            exact ⟨by simp [List.getElem?_attach, xs_i], bs_i⟩
          have xy : x.equal y = true := all _ mem
          rw [ih y (List.mem_of_getElem? bs_i) xy]
    | _ => simp [Ty.equal] at equal

theorem ty_equal_flat_right {t b : Ty} (flat : FlatType b) (equal : Ty.equal t b = true) : t = b := by
  induction flat generalizing t with
  | int => cases t <;> simp [Ty.equal] at equal ⊢
  | list b element =>
    cases t with
    | list e =>
      simp [Ty.equal] at equal
      rw [ty_equal_element_right element equal]
    | _ => simp [Ty.equal] at equal
  | chainInt =>
    cases t with
    | chain e => cases e <;> simp [Ty.equal] at equal ⊢
    | _ => simp [Ty.equal] at equal
  | record ts _ ih =>
    cases t with
    | record ys =>
      rw [Ty.equal] at equal
      simp only [Bool.and_eq_true, beq_iff_eq, List.all_eq_true] at equal
      obtain ⟨len, all⟩ := equal
      congr 1
      apply List.ext_getElem?
      intro i
      cases ys_i : ys[i]? with
      | none =>
        rw [List.getElem?_eq_none_iff] at ys_i
        exact (List.getElem?_eq_none_iff.mpr (by omega)).symm
      | some y =>
        cases ts_i : ts[i]? with
        | none =>
          rw [List.getElem?_eq_none_iff] at ts_i
          have lt := (List.getElem?_eq_some_iff.mp ys_i).1
          omega
        | some x =>
          have mem : (⟨y, List.mem_of_getElem? ys_i⟩, x) ∈ ys.attach.zip ts := by
            apply List.mem_of_getElem? (i := i)
            rw [List.getElem?_zip_eq_some]
            exact ⟨by simp [List.getElem?_attach, ys_i], ts_i⟩
          have equalYX : y = x := ih x (List.mem_of_getElem? ts_i) (all _ mem)
          rw [equalYX]
    | _ => simp [Ty.equal] at equal
  | result e s _ _ ihE ihS =>
    cases t with
    | result f b' =>
      rw [Ty.equal] at equal
      simp only [Bool.and_eq_true] at equal
      rw [ihE equal.1, ihS equal.2]
    | _ => simp [Ty.equal] at equal

/-! ### The join of two flat abstracts -/

theorem record_join_length (as bs : List Abstract) (len : as.length = bs.length) :
    ((as.attach.zip bs).map fun (x, y) => x.val.join y).length = as.length := by
  simp [len]

theorem record_join_index {as bs : List Abstract} {i : Nat} {a b : Abstract}
    (as_i : as[i]? = some a) (bs_i : bs[i]? = some b) :
    ((as.attach.zip bs).map fun (x, y) => x.val.join y)[i]? = some (a.join b) := by
  rw [List.getElem?_map]
  have zipped : (as.attach.zip bs)[i]? = some (⟨a, List.mem_of_getElem? as_i⟩, b) := by
    rw [List.getElem?_zip_eq_some]
    exact ⟨by simp [List.getElem?_attach, as_i], bs_i⟩
  rw [zipped]
  rfl

theorem record_join_index_inv {as bs : List Abstract} {i : Nat} {j : Abstract}
    (at_i : ((as.attach.zip bs).map fun (x, y) => x.val.join y)[i]? = some j) :
    ∃ a b, as[i]? = some a ∧ bs[i]? = some b ∧ j = a.join b := by
  rw [List.getElem?_map] at at_i
  cases zipped : (as.attach.zip bs)[i]? with
  | none => rw [zipped] at at_i; simp at at_i
  | some pair =>
    rcases pair with ⟨x, y⟩
    rw [zipped] at at_i
    rw [List.getElem?_zip_eq_some] at zipped
    obtain ⟨attach_i, bs_i⟩ := zipped
    have as_i : as[i]? = some x.val := by
      obtain ⟨lt, at_attach⟩ := List.getElem?_eq_some_iff.mp attach_i
      rw [List.getElem_attach] at at_attach
      have value : x.val = as[i]'(by simpa using lt) := (congrArg Subtype.val at_attach).symm
      rw [List.getElem?_eq_getElem (by simpa using lt), value]
    exact ⟨x.val, y, as_i, bs_i, (Option.some.inj at_i).symm⟩

theorem join_bottom_left (x : Abstract) : Abstract.bottom.join x = x := by
  cases x <;> simp [Abstract.join]

theorem join_bottom_right (x : Abstract) : x.join .bottom = x := by
  cases x <;> simp [Abstract.join]

theorem join_three (a0 a1 a2 b0 b1 b2 : Abstract) :
    (Abstract.record [a0, a1, a2]).join (.record [b0, b1, b2]) =
      .record [a0.join b0, a1.join b1, a2.join b2] := by
  rw [join_record]
  rfl

/-- A union of two lists without the unknown origin has none. -/
theorem union_no_unknown {xs ys : List Origin} (hx : Origin.unknown ∉ xs) (hy : Origin.unknown ∉ ys) :
    Origin.unknown ∉ union xs ys := by
  intro member
  rcases mem_union_cases xs ys _ member with inX | inY
  · exact hx inX
  · exact hy inY

theorem flatAbstract_join {t : Ty} {a b : Abstract} (shapeA : FlatAbstract t a) (shapeB : FlatAbstract t b) :
    FlatAbstract t (a.join b) := by
  induction shapeA generalizing b with
  | bottom ty => rw [join_bottom_left]; exact shapeB
  | int =>
    cases shapeB with
    | bottom _ => rw [join_bottom_right]; exact .int
    | int => rw [join_scalar]; exact .int
  | list t roots element certificate noUnk _ ih =>
    cases shapeB with
    | bottom _ => rw [join_bottom_right]; exact .list _ _ _ _ noUnk (by assumption)
    | list _ roots' element' certificate' noUnk' shapeE' =>
      rw [join_list]
      exact .list _ _ _ _ (union_no_unknown noUnk noUnk') (ih shapeE')
  | chainBottom roots certificate =>
    cases shapeB with
    | bottom _ => rw [join_bottom_right]; exact .chainBottom _ _
    | chainBottom roots' certificate' => rw [join_list, join_bottom_bottom]; exact .chainBottom _ _
    | chainScalar roots' certificate' => rw [join_list, join_bottom_scalar]; exact .chainScalar _ _
  | chainScalar roots certificate =>
    cases shapeB with
    | bottom _ => rw [join_bottom_right]; exact .chainScalar _ _
    | chainBottom roots' certificate' => rw [join_list, join_scalar_bottom]; exact .chainScalar _ _
    | chainScalar roots' certificate' => rw [join_list, join_scalar]; exact .chainScalar _ _
  | record ts as len fields ih =>
    cases shapeB with
    | bottom _ => rw [join_bottom_right]; exact .record ts as len fields
    | record _ bs len' fieldsB =>
      rw [join_record]
      refine .record ts _ (by rw [record_join_length as bs (len.symm.trans len')]; exact len) ?_
      intro i t j ts_i at_i
      obtain ⟨x, y, as_i, bs_i, rfl⟩ := record_join_index_inv at_i
      exact ih i t x ts_i as_i (fieldsB i t y ts_i bs_i)
  | result e s ae aa hE hS ihE ihS =>
    cases shapeB with
    | bottom _ => rw [join_bottom_right]; exact .result e s ae aa hE hS
    | result _ _ be ba hE' hS' =>
      rw [join_three, join_scalar]
      exact .result e s _ _ (ihE hE') (ihS hS')

/-- A join is bottom only when both sides are. -/
theorem join_ne_bottom_left {a b : Abstract} (ne : a ≠ .bottom) : a.join b ≠ .bottom := by
  cases a <;> cases b <;> simp [Abstract.join] at ne ⊢ <;> (try split) <;> simp

theorem join_ne_bottom_right {a b : Abstract} (ne : b ≠ .bottom) : a.join b ≠ .bottom := by
  cases a <;> cases b <;> simp [Abstract.join] at ne ⊢ <;> (try split) <;> simp

/-! ### The tags of a list element (slice 2b of #522)

The checker joins the element abstract with the fallback's at an `at`. The
fallback is a binding, so its abstract carries its tags; an element type has
no result and no chain inside, so the join's tags for the element follow from
the fallback's alone, and from the shapes. -/

/-- The tags of a join at an element type, read from one side's tags. -/
theorem resultTags_element {heap : Heap} {t : Ty} (element : ElementType t) (a b : Abstract) (w w' : Value)
    (tagsB : ResultTags t b w') (shapeA : FlatAbstract t a)
    (shapeW : AllocatedFlatValue heap w t) (shapeW' : AllocatedFlatValue heap w' t) :
    ResultTags t (a.join b) w := by
  induction element generalizing a b w w' with
  | int =>
    cases tagsB
    cases shapeW
    cases shapeA with
    | bottom _ => rw [join_bottom_left]; exact .int _
    | int => rw [join_scalar]; exact .int _
  | list t _ _ =>
    cases tagsB
    cases shapeA with
    | bottom _ => rw [join_bottom_left]; exact .list _ _ _ _ _
    | list _ _ _ _ _ _ => rw [join_list]; exact .list _ _ _ _ _
  | record ts _ ih =>
    cases tagsB with
    | record _ bs ws' lenB fieldsB =>
      cases shapeW with
      | record ws _ lenW fieldsW =>
        cases shapeW' with
        | record _ _ lenW' fieldsW' =>
          cases shapeA with
          | bottom _ =>
            rw [join_bottom_left]
            refine .record ts bs ws lenB ?_
            intro i t' b' w'' ts_i bs_i ws_i
            obtain ⟨x', ws'_i⟩ := index_of_same_length lenW'.symm ts_i
            have := ih t' (List.mem_of_getElem? ts_i) .bottom b' w'' x' (fieldsB i t' b' x' ts_i bs_i ws'_i)
              (.bottom t') (fieldsW i w'' t' ws_i ts_i) (fieldsW' i x' t' ws'_i ts_i)
            rwa [join_bottom_left] at this
          | record _ as lenA fieldsA =>
            rw [join_record]
            refine .record ts _ ws (by rw [record_join_length as bs (lenA.symm.trans lenB)]; exact lenA) ?_
            intro i t' j w'' ts_i at_i ws_i
            obtain ⟨x, y, as_i, bs_i, rfl⟩ := record_join_index_inv at_i
            obtain ⟨x', ws'_i⟩ := index_of_same_length lenW'.symm ts_i
            exact ih t' (List.mem_of_getElem? ts_i) x y w'' x' (fieldsB i t' y x' ts_i bs_i ws'_i)
              (fieldsA i t' x ts_i as_i) (fieldsW i w'' t' ws_i ts_i) (fieldsW' i x' t' ws'_i ts_i)

/-- The chain tags of a join at an element type: an element type holds no chain. -/
theorem chainTags_element {heap : Heap} {t : Ty} (element : ElementType t) (a b : Abstract)
    (o o' : Observation) (w w' : Value)
    (tagsB : ChainTags t b o') (shapeA : FlatAbstract t a)
    (paired : Corresponds heap o w) (shapeW : AllocatedFlatValue heap w t)
    (paired' : Corresponds heap o' w') (shapeW' : AllocatedFlatValue heap w' t) :
    ChainTags t (a.join b) o := by
  induction element generalizing a b o o' w w' with
  | int => exact .int _ _
  | list t _ _ => exact .list _ _ _
  | record ts _ ih =>
    cases tagsB with
    | record _ bs os' lenB fieldsB =>
      cases shapeW with
      | record ws _ lenW fieldsW =>
        cases shapeW' with
        | record ws' _ lenW' fieldsW' =>
          obtain ⟨os, rfl, lenO, pointwise⟩ := corresponds_record_fields paired
          obtain ⟨os'', osEq, lenO', pointwise'⟩ := corresponds_record_fields paired'
          cases osEq
          cases shapeA with
          | bottom _ =>
            rw [join_bottom_left]
            refine .record ts bs os lenB ?_
            intro i t' b' o'' ts_i bs_i os_i
            obtain ⟨w'', ws_i⟩ := index_of_same_length lenO os_i
            obtain ⟨x', ws'_i⟩ := index_of_same_length lenW'.symm ts_i
            obtain ⟨ox, os'_i⟩ := index_of_same_length lenO'.symm ws'_i
            have := ih t' (List.mem_of_getElem? ts_i) .bottom b' o'' ox w'' x'
              (fieldsB i t' b' ox ts_i bs_i os'_i) (.bottom t') (pointwise i o'' w'' os_i ws_i)
              (fieldsW i w'' t' ws_i ts_i) (pointwise' i ox x' os'_i ws'_i) (fieldsW' i x' t' ws'_i ts_i)
            rwa [join_bottom_left] at this
          | record _ as lenA fieldsA =>
            rw [join_record]
            refine .record ts _ os (by rw [record_join_length as bs (lenA.symm.trans lenB)]; exact lenA) ?_
            intro i t' j o'' ts_i at_i os_i
            obtain ⟨x, y, as_i, bs_i, rfl⟩ := record_join_index_inv at_i
            obtain ⟨w'', ws_i⟩ := index_of_same_length lenO os_i
            obtain ⟨x', ws'_i⟩ := index_of_same_length lenW'.symm ts_i
            obtain ⟨ox, os'_i⟩ := index_of_same_length lenO'.symm ws'_i
            exact ih t' (List.mem_of_getElem? ts_i) x y o'' ox w'' x'
              (fieldsB i t' y ox ts_i bs_i os'_i) (fieldsA i t' x ts_i as_i) (pointwise i o'' w'' os_i ws_i)
              (fieldsW i w'' t' ws_i ts_i) (pointwise' i ox x' os'_i ws'_i) (fieldsW' i x' t' ws'_i ts_i)

/-- The tags of a value survive a join with another flat abstract of its type. -/
theorem resultTags_join {t : Ty} {a b : Abstract} {w : Value}
    (tags : ResultTags t a w) (shapeA : FlatAbstract t a) (shapeB : FlatAbstract t b) :
    ResultTags t (a.join b) w := by
  induction tags generalizing b with
  | int n =>
    cases shapeB with
    | bottom _ => rw [join_bottom_right]; exact .int _
    | int => rw [join_scalar]; exact .int _
  | list t roots element certificate w =>
    cases shapeB with
    | bottom _ => rw [join_bottom_right]; exact .list _ _ _ _ _
    | list _ _ _ _ _ _ => rw [join_list]; exact .list _ _ _ _ _
  | chainInt roots element certificate w =>
    cases shapeB with
    | bottom _ => rw [join_bottom_right]; exact .chainInt _ _ _ _
    | chainBottom _ _ => rw [join_list]; exact .chainInt _ _ _ _
    | chainScalar _ _ => rw [join_list]; exact .chainInt _ _ _ _
  | record ts as ws len tagFields ih =>
    cases shapeA with
    | record _ _ lenA fieldsA =>
      cases shapeB with
      | bottom _ => rw [join_bottom_right]; exact .record ts as ws len tagFields
      | record _ bs lenB fieldsB =>
        rw [join_record]
        refine .record ts _ ws (by rw [record_join_length as bs (lenA.symm.trans lenB)]; exact len) ?_
        intro i t a' w' ts_i at_i ws_i
        obtain ⟨x, y, as_i, bs_i, rfl⟩ := record_join_index_inv at_i
        exact ih i t x w' ts_i as_i ws_i (fieldsA i t x ts_i as_i) (fieldsB i t y ts_i bs_i)
  | ok e s tag ae aa w' ne tagsS ih =>
    cases shapeA with
    | result _ _ _ _ hE hS =>
      cases shapeB with
      | bottom _ => rw [join_bottom_right]; exact .ok e s _ _ _ w' ne tagsS
      | result _ _ be ba hE' hS' =>
        rw [join_three]
        exact .ok e s _ _ _ w' (join_ne_bottom_left ne) (ih hS hS')
  | err e s tag ae aa w' ne tagsE ih =>
    cases shapeA with
    | result _ _ _ _ hE hS =>
      cases shapeB with
      | bottom _ => rw [join_bottom_right]; exact .err e s _ _ _ w' ne tagsE
      | result _ _ be ba hE' hS' =>
        rw [join_three]
        exact .err e s _ _ _ w' (join_ne_bottom_left ne) (ih hE hE')

/-- The tags of a value survive a join on the other side. -/
theorem resultTags_join_right {t : Ty} {a b : Abstract} {w : Value}
    (tags : ResultTags t b w) (shapeA : FlatAbstract t a) (shapeB : FlatAbstract t b) :
    ResultTags t (a.join b) w := by
  induction tags generalizing a with
  | int n =>
    cases shapeA with
    | bottom _ => rw [join_bottom_left]; exact .int _
    | int => rw [join_scalar]; exact .int _
  | list t roots element certificate w =>
    cases shapeA with
    | bottom _ => rw [join_bottom_left]; exact .list _ _ _ _ _
    | list _ _ _ _ _ _ => rw [join_list]; exact .list _ _ _ _ _
  | chainInt roots element certificate w =>
    cases shapeA with
    | bottom _ => rw [join_bottom_left]; exact .chainInt _ _ _ _
    | chainBottom _ _ => rw [join_list]; exact .chainInt _ _ _ _
    | chainScalar _ _ => rw [join_list]; exact .chainInt _ _ _ _
  | record ts bs ws len tagFields ih =>
    cases shapeA with
    | bottom _ => rw [join_bottom_left]; exact .record ts bs ws len tagFields
    | record _ as lenA fieldsA =>
      cases shapeB with
      | record _ _ lenB fieldsB =>
        rw [join_record]
        refine .record ts _ ws (by rw [record_join_length as bs (lenA.symm.trans lenB)]; exact lenA) ?_
        intro i t b' w' ts_i at_i ws_i
        obtain ⟨x, y, as_i, bs_i, rfl⟩ := record_join_index_inv at_i
        exact ih i t y w' ts_i bs_i ws_i (fieldsA i t x ts_i as_i) (fieldsB i t y ts_i bs_i)
  | ok e s tag be ba w' ne tagsS ih =>
    cases shapeA with
    | bottom _ => rw [join_bottom_left]; exact .ok e s _ _ _ w' ne tagsS
    | result _ _ ae aa hE hS =>
      cases shapeB with
      | result _ _ _ _ hE' hS' =>
        rw [join_three]
        exact .ok e s _ _ _ w' (join_ne_bottom_right ne) (ih hS hS')
  | err e s tag be ba w' ne tagsE ih =>
    cases shapeA with
    | bottom _ => rw [join_bottom_left]; exact .err e s _ _ _ w' ne tagsE
    | result _ _ ae aa hE hS =>
      cases shapeB with
      | result _ _ _ _ hE' hS' =>
        rw [join_three]
        exact .err e s _ _ _ w' (join_ne_bottom_right ne) (ih hE hE')

/-- The chain tags of an observation survive a join with another flat abstract of its type. -/
theorem chainTags_join {t : Ty} {a b : Abstract} {o : Observation}
    (tags : ChainTags t a o) (shapeA : FlatAbstract t a) (shapeB : FlatAbstract t b) :
    ChainTags t (a.join b) o := by
  induction tags generalizing b with
  | int a o => exact .int _ _
  | list t a o => exact .list _ _ _
  | chainScalar roots certificate o =>
    cases shapeB with
    | bottom _ => rw [join_bottom_right]; exact .chainScalar _ _ _
    | chainBottom _ _ => rw [join_list, join_scalar_bottom]; exact .chainScalar _ _ _
    | chainScalar _ _ => rw [join_list, join_scalar]; exact .chainScalar _ _ _
  | chainBottom roots certificate =>
    cases shapeB with
    | bottom _ => rw [join_bottom_right]; exact .chainBottom _ _
    | chainBottom _ _ => rw [join_list, join_bottom_bottom]; exact .chainBottom _ _
    | chainScalar _ _ => rw [join_list, join_bottom_scalar]; exact .chainScalar _ _ _
  | record ts as os len tagFields ih =>
    cases shapeA with
    | record _ _ lenA fieldsA =>
      cases shapeB with
      | bottom _ => rw [join_bottom_right]; exact .record ts as os len tagFields
      | record _ bs lenB fieldsB =>
        rw [join_record]
        refine .record ts _ os (by rw [record_join_length as bs (lenA.symm.trans lenB)]; exact len) ?_
        intro i t a' o' ts_i at_i os_i
        obtain ⟨x, y, as_i, bs_i, rfl⟩ := record_join_index_inv at_i
        exact ih i t x o' ts_i as_i os_i (fieldsA i t x ts_i as_i) (fieldsB i t y ts_i bs_i)
  | ok e s tag ae aa o' tagsS ih =>
    cases shapeA with
    | result _ _ _ _ hE hS =>
      cases shapeB with
      | bottom _ => rw [join_bottom_right]; exact .ok e s _ _ _ o' tagsS
      | result _ _ be ba hE' hS' =>
        rw [join_three]
        exact .ok e s _ _ _ o' (ih hS hS')
  | err e s tag ae aa o' tagsE ih =>
    cases shapeA with
    | result _ _ _ _ hE hS =>
      cases shapeB with
      | bottom _ => rw [join_bottom_right]; exact .err e s _ _ _ o' tagsE
      | result _ _ be ba hE' hS' =>
        rw [join_three]
        exact .err e s _ _ _ o' (ih hE hE')

/-- The chain tags of an observation survive a join on the other side. -/
theorem chainTags_join_right {t : Ty} {a b : Abstract} {o : Observation}
    (tags : ChainTags t b o) (shapeA : FlatAbstract t a) (shapeB : FlatAbstract t b) :
    ChainTags t (a.join b) o := by
  induction tags generalizing a with
  | int a o => exact .int _ _
  | list t a o => exact .list _ _ _
  | chainScalar roots certificate o =>
    cases shapeA with
    | bottom _ => rw [join_bottom_left]; exact .chainScalar _ _ _
    | chainBottom _ _ => rw [join_list, join_bottom_scalar]; exact .chainScalar _ _ _
    | chainScalar _ _ => rw [join_list, join_scalar]; exact .chainScalar _ _ _
  | chainBottom roots certificate =>
    cases shapeA with
    | bottom _ => rw [join_bottom_left]; exact .chainBottom _ _
    | chainBottom _ _ => rw [join_list, join_bottom_bottom]; exact .chainBottom _ _
    | chainScalar _ _ => rw [join_list, join_scalar_bottom]; exact .chainScalar _ _ _
  | record ts bs os len tagFields ih =>
    cases shapeA with
    | bottom _ => rw [join_bottom_left]; exact .record ts bs os len tagFields
    | record _ as lenA fieldsA =>
      cases shapeB with
      | record _ _ lenB fieldsB =>
        rw [join_record]
        refine .record ts _ os (by rw [record_join_length as bs (lenA.symm.trans lenB)]; exact lenA) ?_
        intro i t b' o' ts_i at_i os_i
        obtain ⟨x, y, as_i, bs_i, rfl⟩ := record_join_index_inv at_i
        exact ih i t y o' ts_i bs_i os_i (fieldsA i t x ts_i as_i) (fieldsB i t y ts_i bs_i)
  | ok e s tag be ba o' tagsS ih =>
    cases shapeA with
    | bottom _ => rw [join_bottom_left]; exact .ok e s _ _ _ o' tagsS
    | result _ _ ae aa hE hS =>
      cases shapeB with
      | result _ _ _ _ hE' hS' =>
        rw [join_three]
        exact .ok e s _ _ _ o' (ih hS hS')
  | err e s tag be ba o' tagsE ih =>
    cases shapeA with
    | bottom _ => rw [join_bottom_left]; exact .err e s _ _ _ o' tagsE
    | result _ _ ae aa hE hS =>
      cases shapeB with
      | result _ _ _ _ hE' hS' =>
        rw [join_three]
        exact .err e s _ _ _ o' (ih hE hE')

/-! ### A join describes what either side describes -/

theorem describes_join {gamma : Naming} {heap : Heap} {t : Ty} {w : Value} {a b : Abstract}
    (allocated : AllocatedFlatValue heap w t)
    (shapeA : FlatAbstract t a) (shapeB : FlatAbstract t b)
    (side : Describes gamma heap a w ∨ Describes gamma heap b w) :
    Describes gamma heap (a.join b) w := by
  induction allocated generalizing a b with
  | int n => exact integer_described_any _ n
  | list root ys t lookup elements ih =>
    have rootNamed : ∀ {cs : List Origin} {e : Abstract} {ex : Certificate},
        Describes gamma heap (.list cs e ex) (.ref root) → named gamma cs root := by
      intro cs e ex d
      have names := d.1.1 [] root (.here _)
      rw [list_root_names] at names
      exact named_union_nil names
    cases shapeA with
    | bottom _ =>
      rw [join_bottom_left]
      rcases side with d | d
      · exact describes_of_no_arrays (.list root ys t lookup elements) (no_arrays_of_covers_bottom d.1.1) b
      · exact d
    | list _ cs e ex noUnk shapeE =>
      cases shapeB with
      | bottom _ =>
        rw [join_bottom_right]
        rcases side with d | d
        · exact d
        · exact describes_of_no_arrays (.list root ys t lookup elements) (no_arrays_of_covers_bottom d.1.1) _
      | list _ ds e' ey noUnk' shapeE' =>
        rw [join_list]
        have elementsDescribed : ∀ y ∈ ys, Describes gamma heap (e.join e') y := by
          intro y member
          refine ih y member shapeE shapeE' ?_
          rcases side with d | d
          · exact Or.inl (describes_element noUnk lookup member d)
          · exact Or.inr (describes_element noUnk' lookup member d)
        have named : named gamma (union cs ds) root := by
          rcases side with d | d
          · obtain ⟨o, m, ad⟩ := rootNamed d
            exact ⟨o, mem_union _ _ o (Or.inl m), ad⟩
          · obtain ⟨o, m, ad⟩ := rootNamed d
            exact ⟨o, mem_union _ _ o (Or.inr m), ad⟩
        refine ⟨⟨list_covers_of_elements named (union_no_unknown noUnk noUnk') lookup
          (fun y member => (elementsDescribed y member).1.1), ?_⟩,
          list_closures_of_elements lookup (fun y member => (elementsDescribed y member).2)⟩
        intro q cs' e'' ex'' w' shape' located n o fp rep
        cases located with
        | here =>
          simp [Abstract.atPath] at shape'
          obtain ⟨rfl, rfl, rfl⟩ := shape'
          rcases side with d | d
          · obtain ⟨nodup, once⟩ := d.1.2 [] cs e ex (.ref root) rfl (.here _) n o fp rep
            exact ⟨fun h => nodup (by have h' := h; simp [Certificate.meet] at h'; exact h'.1),
              fun h => once (by have h' := h; simp [Certificate.meet] at h'; exact h'.1)⟩
          · obtain ⟨nodup, once⟩ := d.1.2 [] ds e' ey (.ref root) rfl (.here _) n o fp rep
            exact ⟨fun h => nodup (by have h' := h; simp [Certificate.meet] at h'; exact h'.2),
              fun h => once (by have h' := h; simp [Certificate.meet] at h'; exact h'.2)⟩
        | element lookup' member inner =>
          rw [lookup] at lookup'
          cases lookup'
          exact (elementsDescribed _ member).1.2 _ cs' e'' ex'' w' (by simpa [Abstract.atPath] using shape') inner n o fp rep
  | chain root integers lookupRoot =>
    have rootNamed : ∀ {cs : List Origin} {e : Abstract} {ex : Certificate},
        Describes gamma heap (.list cs e ex) (.ref root) → named gamma cs root := by
      intro cs e ex d
      have names := d.1.1 [] root (.here _)
      rw [list_root_names] at names
      exact named_union_nil names
    have joined : ∀ {cs ds : List Origin} {x y : Abstract} {ex ey : Certificate},
        Describes gamma heap (.list cs x ex) (.ref root) ∨ Describes gamma heap (.list ds y ey) (.ref root) →
        Describes gamma heap ((Abstract.list cs x ex).join (.list ds y ey)) (.ref root) := by
      intro cs ds x y ex ey d
      rw [join_list]
      refine allocated_list_described lookupRoot ?_
      rcases d with d | d
      · obtain ⟨o, m, ad⟩ := rootNamed d
        exact ⟨o, mem_union _ _ o (Or.inl m), ad⟩
      · obtain ⟨o, m, ad⟩ := rootNamed d
        exact ⟨o, mem_union _ _ o (Or.inr m), ad⟩
    cases shapeA with
    | bottom _ =>
      rw [join_bottom_left]
      rcases side with d | d
      · exact describes_of_no_arrays (.chain root integers lookupRoot) (no_arrays_of_covers_bottom d.1.1) b
      · exact d
    | chainBottom cs ex =>
      cases shapeB with
      | bottom _ =>
        rw [join_bottom_right]
        rcases side with d | d
        · exact d
        · exact describes_of_no_arrays (.chain root integers lookupRoot) (no_arrays_of_covers_bottom d.1.1) _
      | chainBottom ds ey => exact joined side
      | chainScalar ds ey => exact joined side
    | chainScalar cs ex =>
      cases shapeB with
      | bottom _ =>
        rw [join_bottom_right]
        rcases side with d | d
        · exact d
        · exact describes_of_no_arrays (.chain root integers lookupRoot) (no_arrays_of_covers_bottom d.1.1) _
      | chainBottom ds ey => exact joined side
      | chainScalar ds ey => exact joined side
  | record ws ts len fields ih =>
    cases shapeA with
    | bottom _ =>
      rw [join_bottom_left]
      rcases side with d | d
      · exact describes_of_no_arrays (.record ws ts len fields) (no_arrays_of_covers_bottom d.1.1) b
      · exact d
    | record _ as lenA fieldsA =>
      cases shapeB with
      | bottom _ =>
        rw [join_bottom_right]
        rcases side with d | d
        · exact d
        · exact describes_of_no_arrays (.record ws ts len fields) (no_arrays_of_covers_bottom d.1.1) _
      | record _ bs lenB fieldsB =>
        rw [join_record]
        refine describes_record_of_fields (by rw [record_join_length as bs (lenA.symm.trans lenB), ← lenA]; exact len.symm) ?_
        intro i j w' at_i ws_i
        obtain ⟨x, y, as_i, bs_i, rfl⟩ := record_join_index_inv at_i
        obtain ⟨t, ts_i⟩ := index_of_same_length len ws_i
        refine ih i w' t ws_i ts_i (fieldsA i t x ts_i as_i) (fieldsB i t y ts_i bs_i) ?_
        rcases side with d | d
        · exact Or.inl (describes_field d as_i ws_i)
        · exact Or.inr (describes_field d bs_i ws_i)
  | ok e s w' inner ih =>
    cases shapeA with
    | bottom _ =>
      rw [join_bottom_left]
      rcases side with d | d
      · exact describes_of_no_arrays (.ok e s w' inner) (no_arrays_of_covers_bottom d.1.1) b
      · exact d
    | result _ _ ae aa hE hS =>
      cases shapeB with
      | bottom _ =>
        rw [join_bottom_right]
        rcases side with d | d
        · exact d
        · exact describes_of_no_arrays (.ok e s w' inner) (no_arrays_of_covers_bottom d.1.1) _
      | result _ _ be ba hE' hS' =>
        rw [join_three, join_scalar]
        refine describes_record_of_fields rfl ?_
        intro i a' w'' as_i ws_i
        rcases three_pair as_i ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
        · exact integer_described 1
        · exact integer_described_any _ 0
        · refine ih hS hS' ?_
          rcases side with d | d
          · exact Or.inl (describes_field (i := 2) d rfl rfl)
          · exact Or.inr (describes_field (i := 2) d rfl rfl)
  | err e s w' inner ih =>
    cases shapeA with
    | bottom _ =>
      rw [join_bottom_left]
      rcases side with d | d
      · exact describes_of_no_arrays (.err e s w' inner) (no_arrays_of_covers_bottom d.1.1) b
      · exact d
    | result _ _ ae aa hE hS =>
      cases shapeB with
      | bottom _ =>
        rw [join_bottom_right]
        rcases side with d | d
        · exact d
        · exact describes_of_no_arrays (.err e s w' inner) (no_arrays_of_covers_bottom d.1.1) _
      | result _ _ be ba hE' hS' =>
        rw [join_three, join_scalar]
        refine describes_record_of_fields rfl ?_
        intro i a' w'' as_i ws_i
        rcases three_pair as_i ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
        · exact integer_described 0
        · refine ih hE hE' ?_
          rcases side with d | d
          · exact Or.inl (describes_field (i := 1) d rfl rfl)
          · exact Or.inr (describes_field (i := 1) d rfl rfl)
        · exact integer_described_any _ 0

/-! ### The fold of a literal's items (slice 2b of #522) -/

/-- The fold of flat abstracts over bottom is flat. -/
theorem flatAbstract_fold_join {t : Ty} {as : List Abstract} (shapes : ∀ a ∈ as, FlatAbstract t a) :
    ∀ start, FlatAbstract t start → FlatAbstract t (as.foldl Abstract.join start) := by
  induction as with
  | nil => intro start shape; simpa using shape
  | cons a rest ih =>
    intro start shape
    simp only [List.foldl_cons]
    exact ih (fun b member => shapes b (List.mem_cons_of_mem _ member)) _
      (flatAbstract_join shape (shapes a (by simp)))

/-- A value one of the folded abstracts describes is described by the fold. -/
theorem describes_fold_join {gamma : Naming} {heap : Heap} {t : Ty} {as : List Abstract} {w : Value}
    (allocated : AllocatedFlatValue heap w t) (shapes : ∀ a ∈ as, FlatAbstract t a) :
    ∀ start, FlatAbstract t start →
      (Describes gamma heap start w ∨ ∃ a ∈ as, Describes gamma heap a w) →
      Describes gamma heap (as.foldl Abstract.join start) w := by
  induction as with
  | nil =>
    intro start _ side
    rcases side with described | ⟨a, member, _⟩
    · simpa using described
    · simp at member
  | cons a rest ih =>
    intro start shapeStart side
    simp only [List.foldl_cons]
    apply ih (fun b member => shapes b (List.mem_cons_of_mem _ member)) _
      (flatAbstract_join shapeStart (shapes a (by simp)))
    rcases side with described | ⟨b, member, describedB⟩
    · exact Or.inl (describes_join allocated shapeStart (shapes a (by simp)) (Or.inl described))
    · rcases List.mem_cons.mp member with rfl | tail
      · exact Or.inl (describes_join allocated shapeStart (shapes b (by simp)) (Or.inr describedB))
      · exact Or.inr ⟨b, tail, describedB⟩

/-! ### More escapes -/

theorem escaped_subset {escapes escapes' : List Origin} {origin : Origin}
    (sub : ∀ o ∈ escapes, o ∈ escapes') (escaped : Escaped escapes origin) :
    Escaped escapes' origin := by
  rcases escaped with shared | overlap
  · exact Or.inl shared
  · right
    obtain ⟨x, xMember, inner⟩ := List.any_eq_true.mp overlap
    obtain ⟨y, yMember, same⟩ := List.any_eq_true.mp inner
    obtain ⟨witness, witnessMember, rfl⟩ := List.mem_map.mp yMember
    refine List.any_eq_true.mpr ⟨x, xMember, List.any_eq_true.mpr ⟨witness.base, ?_, same⟩⟩
    exact List.mem_map.mpr ⟨witness, sub witness witnessMember, rfl⟩

theorem flatInvariant_more_escapes {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {escapes escapes' : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (more : ∀ origin, Escaped escapes origin → Escaped escapes' origin) :
    FlatInvariant declarations vs hs env live aenv tenv escapes' gamma :=
  { inv with
    toInvariant := { inv.toInvariant with
      keptEscaped := fun k member c reaches g named => more g (inv.keptEscaped k member c reaches g named) } }

theorem join_escapes (left right : Summary) :
    (left.join right).escapes = union left.escapes right.escapes := rfl

/-! ### Typing, shadows and uses of a branch -/

theorem exprType_branch_success {declarations : List Decl} {self : Decl} {tenv : Env Ty} {c : Atom} {yes no : Expr} {type : Ty}
    (typed : exprType declarations self tenv (.branch c yes no) = .ok type) :
    atomType tenv c = .ok .int ∧ exprType declarations self tenv yes = .ok type ∧
      ∃ b, exprType declarations self tenv no = .ok b ∧ Ty.equal type b = true := by
  rw [exprType] at typed
  cases condition : atomType tenv c with
  | error problem => rw [condition] at typed; simp [Bind.bind, Except.bind] at typed
  | ok ct =>
    rw [condition] at typed
    simp only [Bind.bind, Except.bind] at typed
    by_cases nonInt : (ct != Ty.int) = true
    · rw [if_pos nonInt] at typed; cases typed
    · rw [if_neg nonInt] at typed
      have isInt : (ct == Ty.int) = true := by
        cases equal : (ct == Ty.int) <;> simp [bne, equal] at nonInt ⊢
      have ctInt : ct = .int := ty_equal_int isInt
      subst ctInt
      cases yesType : exprType declarations self tenv yes with
      | error problem => rw [yesType] at typed; simp [pure, Except.pure] at typed
      | ok a =>
        rw [yesType] at typed
        cases noType : exprType declarations self tenv no with
        | error problem => rw [noType] at typed; simp [pure, Except.pure] at typed
        | ok b =>
          rw [noType] at typed
          simp only [pure, Except.pure] at typed
          by_cases same : (a == b) = true
          · rw [if_pos same] at typed
            cases Except.ok.inj typed
            exact ⟨rfl, rfl, b, rfl, same⟩
          · rw [if_neg same] at typed; cases typed

theorem shadowFree_branch_success {bound : List Var} {c : Atom} {yes no : Expr}
    (shadow : shadowFree bound (.branch c yes no) = .ok ()) :
    shadowFree bound yes = .ok () ∧ shadowFree bound no = .ok () := by
  rw [shadowFree] at shadow
  cases yesShadow : shadowFree bound yes with
  | error problem => rw [yesShadow] at shadow; simp [Bind.bind, Except.bind] at shadow
  | ok unit =>
    cases unit
    rw [yesShadow] at shadow
    simp only [Bind.bind, Except.bind] at shadow
    exact ⟨rfl, shadow⟩

theorem uses_branch (c : Atom) (yes no : Expr) :
    uses (.branch c yes no) = union (atomUses c) (union (uses yes) (uses no)) := rfl

/-! ### Typing and shadows of a result constructor and a result case -/

theorem primType_ok_success {error t type : Ty} (run : primType (.ok error) [t] = .ok type) :
    type = .result error t := by
  simp [primType, pure, Except.pure] at run
  exact run.symm

theorem primType_err_success {success t type : Ty} (run : primType (.err success) [t] = .ok type) :
    type = .result t success := by
  simp [primType, pure, Except.pure] at run
  exact run.symm

theorem exprType_ok_success {declarations : List Decl} {self : Decl} {tenv : Env Ty} {error : Ty} {x : Atom} {type : Ty}
    (typed : exprType declarations self tenv (.prim (.ok error) [x]) = .ok type) :
    ∃ t, atomType tenv x = .ok t ∧ type = .result error t := by
  obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
  obtain ⟨t, rest, headTyped, restTyped, rfl⟩ := except_mapM_cons_success atomsTyped
  have restNil := except_mapM_nil_success restTyped
  subst restNil
  exact ⟨t, headTyped, primType_ok_success primTyped⟩

theorem exprType_err_success {declarations : List Decl} {self : Decl} {tenv : Env Ty} {success : Ty} {x : Atom} {type : Ty}
    (typed : exprType declarations self tenv (.prim (.err success) [x]) = .ok type) :
    ∃ t, atomType tenv x = .ok t ∧ type = .result t success := by
  obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
  obtain ⟨t, rest, headTyped, restTyped, rfl⟩ := except_mapM_cons_success atomsTyped
  have restNil := except_mapM_nil_success restTyped
  subst restNil
  exact ⟨t, headTyped, primType_err_success primTyped⟩

theorem exprType_resultCase_success {declarations : List Decl} {self : Decl} {tenv : Env Ty} {input : Atom} {err ok : Var} {onError onSuccess : Expr} {type : Ty}
    (typed : exprType declarations self tenv (.resultCase input err ok onError onSuccess) = .ok type) :
    ∃ e a, atomType tenv input = .ok (.result e a) ∧
      exprType declarations self ((err, e) :: tenv) onError = .ok type ∧
      ∃ b, exprType declarations self ((ok, a) :: tenv) onSuccess = .ok b ∧ Ty.equal type b = true := by
  rw [exprType] at typed
  cases inputType : atomType tenv input with
  | error problem => rw [inputType] at typed; simp [Bind.bind, Except.bind] at typed
  | ok t =>
    rw [inputType] at typed
    simp only [Bind.bind, Except.bind] at typed
    cases t with
    | result e a =>
      dsimp only at typed
      cases leftType : exprType declarations self ((err, e) :: tenv) onError with
      | error problem => rw [leftType] at typed; simp [pure, Except.pure] at typed
      | ok left =>
        rw [leftType] at typed
        cases rightType : exprType declarations self ((ok, a) :: tenv) onSuccess with
        | error problem => rw [rightType] at typed; simp [pure, Except.pure] at typed
        | ok right =>
          rw [rightType] at typed
          simp only [pure, Except.pure] at typed
          by_cases same : (left == right) = true
          · rw [if_pos same] at typed
            cases Except.ok.inj typed
            exact ⟨e, a, rfl, leftType, right, rightType, same⟩
          · rw [if_neg same] at typed; cases typed
    | _ => simp [pure, Except.pure] at typed

theorem shadowFree_resultCase_success {bound : List Var} {input : Atom} {err ok : Var} {onError onSuccess : Expr}
    (shadow : shadowFree bound (.resultCase input err ok onError onSuccess) = .ok ()) :
    err ∉ bound ∧ ok ∉ bound ∧
      shadowFree (err :: bound) onError = .ok () ∧ shadowFree (ok :: bound) onSuccess = .ok () := by
  cases occupied : (bound.contains err || bound.contains ok) with
  | true =>
    simp only [shadowFree, if_pos occupied] at shadow
    change Except.error _ = Except.ok () at shadow
    contradiction
  | false =>
    simp only [Bool.or_eq_false_iff] at occupied
    have freshErr : err ∉ bound := fun member =>
      by have := List.contains_iff_mem.mpr member; rw [occupied.1] at this; contradiction
    have freshOk : ok ∉ bound := fun member =>
      by have := List.contains_iff_mem.mpr member; rw [occupied.2] at this; contradiction
    have children :
        (shadowFree (err :: bound) onError >>= fun _ => shadowFree (ok :: bound) onSuccess) = .ok () := by
      simpa [shadowFree, freshErr, freshOk] using shadow
    obtain ⟨_, first, second⟩ := except_bind_success children
    exact ⟨freshErr, freshOk, first, second⟩

/-! ### Typing and shadows of the chain constructors and a chain case -/

theorem primType_endChain_success {t type : Ty} (run : primType (.endChain t) [] = .ok type) :
    type = .chain t := by
  simp [primType, pure, Except.pure] at run
  exact run.symm

/-- A link types only at an integer head and an integer chain, and its result is that chain. -/
theorem primType_link_success {ta tb type : Ty} (flatB : FlatType tb)
    (run : primType .link [ta, tb] = .ok type) :
    ta = .int ∧ tb = .chain .int ∧ type = .chain .int := by
  cases flatB with
  | int => simp [primType] at run
  | list _ _ => simp [primType] at run
  | record _ _ => simp [primType] at run
  | result _ _ _ _ => simp [primType] at run
  | chainInt =>
    simp only [primType] at run
    by_cases same : (ta == Ty.int) = true
    · rw [if_pos same] at run
      have taInt := ty_equal_int same
      subst taInt
      simp [pure, Except.pure] at run
      exact ⟨rfl, rfl, run.symm⟩
    · rw [if_neg same] at run
      cases run

theorem exprType_endChain_success {declarations : List Decl} {self : Decl} {tenv : Env Ty} {type : Ty}
    (typed : exprType declarations self tenv (.prim (.endChain .int) []) = .ok type) :
    type = .chain .int := by
  obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
  have restNil := except_mapM_nil_success atomsTyped
  subst restNil
  exact primType_endChain_success primTyped

theorem exprType_link_success {declarations : List Decl} {self : Decl} {tenv : Env Ty} {head tail : Atom} {type : Ty}
    (flatTypes : ∀ t, atomType tenv tail = .ok t → FlatType t)
    (typed : exprType declarations self tenv (.prim .link [head, tail]) = .ok type) :
    atomType tenv head = .ok .int ∧ atomType tenv tail = .ok (.chain .int) ∧ type = .chain .int := by
  obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
  obtain ⟨tH, rest, headTyped, restTyped, rfl⟩ := except_mapM_cons_success atomsTyped
  obtain ⟨tT, rest', tailTyped, restTyped', rfl⟩ := except_mapM_cons_success restTyped
  have restNil := except_mapM_nil_success restTyped'
  subst restNil
  obtain ⟨headInt, tailChain, typeChain⟩ := primType_link_success (flatTypes tT tailTyped) primTyped
  subst headInt
  subst tailChain
  exact ⟨headTyped, tailTyped, typeChain⟩

theorem exprType_chainCase_success {declarations : List Decl} {self : Decl} {tenv : Env Ty} {input : Atom} {head tail : Var} {onEnd onLink : Expr} {type : Ty}
    (typed : exprType declarations self tenv (.chainCase input head tail onEnd onLink) = .ok type) :
    ∃ t, atomType tenv input = .ok (.chain t) ∧
      exprType declarations self tenv onEnd = .ok type ∧
      ∃ b, exprType declarations self ((head, t) :: (tail, .chain t) :: tenv) onLink = .ok b ∧
        Ty.equal type b = true := by
  rw [exprType] at typed
  cases inputType : atomType tenv input with
  | error problem => rw [inputType] at typed; simp [Bind.bind, Except.bind] at typed
  | ok t =>
    rw [inputType] at typed
    simp only [Bind.bind, Except.bind] at typed
    cases t with
    | chain t =>
      dsimp only at typed
      cases leftType : exprType declarations self tenv onEnd with
      | error problem => rw [leftType] at typed; simp [pure, Except.pure] at typed
      | ok left =>
        rw [leftType] at typed
        cases rightType : exprType declarations self ((head, t) :: (tail, .chain t) :: tenv) onLink with
        | error problem => rw [rightType] at typed; simp [pure, Except.pure] at typed
        | ok right =>
          rw [rightType] at typed
          simp only [pure, Except.pure] at typed
          by_cases same : (left == right) = true
          · rw [if_pos same] at typed
            cases Except.ok.inj typed
            first
            | exact ⟨t, rfl, leftType, right, rightType, same⟩
            | exact ⟨t, rfl, rfl, right, rightType, same⟩
            | exact ⟨t, rfl, leftType, right, rfl, same⟩
            | exact ⟨t, rfl, rfl, right, rfl, same⟩
          · rw [if_neg same] at typed; cases typed
    | _ => simp [pure, Except.pure] at typed

theorem shadowFree_chainCase_success {bound : List Var} {input : Atom} {head tail : Var} {onEnd onLink : Expr}
    (shadow : shadowFree bound (.chainCase input head tail onEnd onLink) = .ok ()) :
    head ∉ bound ∧ tail ∉ bound ∧ head ≠ tail ∧
      shadowFree bound onEnd = .ok () ∧ shadowFree (head :: tail :: bound) onLink = .ok () := by
  cases occupied : (bound.contains head || bound.contains tail || head == tail) with
  | true =>
    simp only [shadowFree, if_pos occupied] at shadow
    change Except.error _ = Except.ok () at shadow
    contradiction
  | false =>
    simp only [Bool.or_eq_false_iff] at occupied
    have freshHead : head ∉ bound := fun member =>
      by have := List.contains_iff_mem.mpr member; rw [occupied.1.1] at this; contradiction
    have freshTail : tail ∉ bound := fun member =>
      by have := List.contains_iff_mem.mpr member; rw [occupied.1.2] at this; contradiction
    have different : head ≠ tail := by
      intro same
      subst same
      simp at occupied
    have children :
        (shadowFree bound onEnd >>= fun _ => shadowFree (head :: tail :: bound) onLink) = .ok () := by
      simpa [shadowFree, freshHead, freshTail, different] using shadow
    obtain ⟨_, first, second⟩ := except_bind_success children
    exact ⟨freshHead, freshTail, different, first, second⟩

/-! ### Typing of the remaining list primitives -/

theorem primType_at_success {tR tI tD type : Ty} (flatR : FlatType tR) (flatD : FlatType tD)
    (run : primType .at [tR, tI, tD] = .ok type) :
    ∃ t, tR = .list t ∧ tI = .int ∧ tD = t ∧ type = t := by
  cases flatR with
  | list t flatT =>
    cases tI <;> simp [primType] at run
    split at run
    · rename_i same
      have : t = tD := ty_equal_flat (elementType_flat flatT) (by simpa using same)
      have typeEq : type = t := by cases run; rfl
      exact ⟨t, rfl, rfl, this.symm, typeEq⟩
    · cases run
  | _ => cases tI <;> simp [primType] at run

theorem primType_set_success {tR tI tV type : Ty} (flatR : FlatType tR) (flatV : FlatType tV)
    (run : primType .set [tR, tI, tV] = .ok type) :
    ∃ t, tR = .list t ∧ tI = .int ∧ tV = t ∧ type = .list t := by
  cases flatR with
  | list t flatT =>
    cases tI <;> simp [primType] at run
    split at run
    · rename_i same
      have : t = tV := ty_equal_flat (elementType_flat flatT) (by simpa using same)
      have typeEq : type = .list t := by cases run; rfl
      exact ⟨t, rfl, rfl, this.symm, typeEq⟩
    · cases run
  | _ => cases tI <;> simp [primType] at run

theorem primType_copy_success {tR type : Ty} (flatR : FlatType tR)
    (run : primType .copy [tR] = .ok type) : ∃ t, tR = .list t ∧ type = .list t := by
  cases flatR with
  | list t _ =>
    simp [primType] at run
    have typeEq : type = .list t := by cases run; rfl
    exact ⟨t, rfl, typeEq⟩
  | _ => simp [primType] at run

theorem primType_prepend_success {tI tR type : Ty} (flatI : FlatType tI) (flatR : FlatType tR)
    (run : primType .prepend [tI, tR] = .ok type) :
    ∃ t, tI = t ∧ tR = .list t ∧ type = .list t := by
  cases flatR with
  | list t flatT =>
    simp [primType] at run
    split at run
    · rename_i same
      have : tI = t := ty_equal_flat flatI (by simpa using same)
      have typeEq : type = .list t := by cases run; rw [this]
      exact ⟨t, this, rfl, typeEq⟩
    · cases run
  | _ => simp [primType] at run

theorem exprType_at_success {declarations : List Decl} {self : Decl} {tenv : Env Ty} {receiver index fallback : Atom} {type : Ty}
    (flatTypes : ∀ (atom : Atom) (t : Ty), atomType tenv atom = .ok t → FlatType t)
    (typed : exprType declarations self tenv (.prim .at [receiver, index, fallback]) = .ok type) :
    ∃ t, atomType tenv receiver = .ok (.list t) ∧ atomType tenv index = .ok .int ∧
      atomType tenv fallback = .ok t ∧ type = t := by
  obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
  obtain ⟨tR, rest, receiverTyped, restTyped, rfl⟩ := except_mapM_cons_success atomsTyped
  obtain ⟨tI, rest', indexTyped, restTyped', rfl⟩ := except_mapM_cons_success restTyped
  obtain ⟨tD, rest'', fallbackTyped, restTyped'', rfl⟩ := except_mapM_cons_success restTyped'
  have restNil := except_mapM_nil_success restTyped''
  subst restNil
  obtain ⟨t, hR, hI, hD, typeT⟩ :=
    primType_at_success (flatTypes receiver tR receiverTyped) (flatTypes fallback tD fallbackTyped) primTyped
  subst hR
  subst hI
  subst tD
  exact ⟨t, receiverTyped, indexTyped, fallbackTyped, typeT⟩

theorem exprType_set_success {declarations : List Decl} {self : Decl} {tenv : Env Ty} {receiver index item : Atom} {type : Ty}
    (flatTypes : ∀ (atom : Atom) (t : Ty), atomType tenv atom = .ok t → FlatType t)
    (typed : exprType declarations self tenv (.prim .set [receiver, index, item]) = .ok type) :
    ∃ t, atomType tenv receiver = .ok (.list t) ∧ atomType tenv index = .ok .int ∧
      atomType tenv item = .ok t ∧ type = .list t := by
  obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
  obtain ⟨tR, rest, receiverTyped, restTyped, rfl⟩ := except_mapM_cons_success atomsTyped
  obtain ⟨tI, rest', indexTyped, restTyped', rfl⟩ := except_mapM_cons_success restTyped
  obtain ⟨tV, rest'', itemTyped, restTyped'', rfl⟩ := except_mapM_cons_success restTyped'
  have restNil := except_mapM_nil_success restTyped''
  subst restNil
  obtain ⟨t, hR, hI, hV, typeList⟩ :=
    primType_set_success (flatTypes receiver tR receiverTyped) (flatTypes item tV itemTyped) primTyped
  subst hR
  subst hI
  subst tV
  exact ⟨t, receiverTyped, indexTyped, itemTyped, typeList⟩

theorem exprType_copy_success {declarations : List Decl} {self : Decl} {tenv : Env Ty} {receiver : Atom} {type : Ty}
    (flatTypes : ∀ (atom : Atom) (t : Ty), atomType tenv atom = .ok t → FlatType t)
    (typed : exprType declarations self tenv (.prim .copy [receiver]) = .ok type) :
    ∃ t, atomType tenv receiver = .ok (.list t) ∧ type = .list t := by
  obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
  obtain ⟨tR, rest, receiverTyped, restTyped, rfl⟩ := except_mapM_cons_success atomsTyped
  have restNil := except_mapM_nil_success restTyped
  subst restNil
  obtain ⟨t, hR, typeList⟩ := primType_copy_success (flatTypes receiver tR receiverTyped) primTyped
  subst hR
  exact ⟨t, receiverTyped, typeList⟩

theorem exprType_prepend_success {declarations : List Decl} {self : Decl} {tenv : Env Ty} {item receiver : Atom} {type : Ty}
    (flatTypes : ∀ (atom : Atom) (t : Ty), atomType tenv atom = .ok t → FlatType t)
    (typed : exprType declarations self tenv (.prim .prepend [item, receiver]) = .ok type) :
    ∃ t, atomType tenv item = .ok t ∧ atomType tenv receiver = .ok (.list t) ∧ type = .list t := by
  obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
  obtain ⟨tI, rest, itemTyped, restTyped, rfl⟩ := except_mapM_cons_success atomsTyped
  obtain ⟨tR, rest', receiverTyped, restTyped', rfl⟩ := except_mapM_cons_success restTyped
  have restNil := except_mapM_nil_success restTyped'
  subst restNil
  obtain ⟨t, hI, hR, typeList⟩ :=
    primType_prepend_success (flatTypes item tI itemTyped) (flatTypes receiver tR receiverTyped) primTyped
  subst hR
  subst tI
  exact ⟨t, itemTyped, receiverTyped, typeList⟩

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
  | @literal args _ _ =>
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
  | @branch yes no c _ _ ihYes ihNo =>
    intro tenv ty typed x p use
    obtain ⟨condTyped, yesTyped, b, noTyped, _⟩ := exprType_branch_success typed
    rw [uses_branch] at use
    rcases mem_union_cases _ _ (x, p) use with cond | arms
    · exact atom_use_typed condTyped cond
    · rcases mem_union_cases _ _ (x, p) arms with inYes | inNo
      · exact ihYes tenv ty yesTyped x p inYes
      · exact ihNo tenv b noTyped x p inNo
  | @ok error x' _ =>
    intro tenv ty typed x p use
    obtain ⟨types, atomsTyped, _⟩ := exprType_prim_success typed
    exact atoms_use_typed atomsTyped use
  | @err success x' _ =>
    intro tenv ty typed x p use
    obtain ⟨types, atomsTyped, _⟩ := exprType_prim_success typed
    exact atoms_use_typed atomsTyped use
  | @resultCase onError onSuccess input err ok _ _ ihError ihSuccess =>
    intro tenv ty typed x p use
    obtain ⟨e, a, inputTyped, errorTyped, b, successTyped, _⟩ := exprType_resultCase_success typed
    rw [uses_resultCase] at use
    rcases mem_union_cases _ _ (x, p) use with inInput | arms
    · exact atom_use_typed inputTyped inInput
    · rcases mem_union_cases _ _ (x, p) arms with inError | inSuccess
      · have filtered := List.mem_filter.mp inError
        have different : x ≠ err := by
          intro same
          subst same
          simp at filtered
        obtain ⟨tk, t, declared, at_p⟩ := ihError _ ty errorTyped x p filtered.1
        rw [lookup_cons_other _ _ _ different] at declared
        exact ⟨tk, t, declared, at_p⟩
      · have filtered := List.mem_filter.mp inSuccess
        have different : x ≠ ok := by
          intro same
          subst same
          simp at filtered
        obtain ⟨tk, t, declared, at_p⟩ := ihSuccess _ b successTyped x p filtered.1
        rw [lookup_cons_other _ _ _ different] at declared
        exact ⟨tk, t, declared, at_p⟩
  | @endChain =>
    intro tenv ty typed x p use
    simp [uses, usesArms, atomsUses] at use
  | @link head tail =>
    intro tenv ty typed x p use
    obtain ⟨types, atomsTyped, _⟩ := exprType_prim_success typed
    exact atoms_use_typed atomsTyped use
  | @chainCase onEnd onLink input head tail _ _ ihEnd ihLink =>
    intro tenv ty typed x p use
    obtain ⟨t, inputTyped, endTyped, b, linkTyped, _⟩ := exprType_chainCase_success typed
    rw [uses_chainCase] at use
    rcases mem_union_cases _ _ (x, p) use with inInput | arms
    · exact atom_use_typed inputTyped inInput
    · rcases mem_union_cases _ _ (x, p) arms with inEnd | inLink
      · exact ihEnd tenv ty endTyped x p inEnd
      · have filtered := List.mem_filter.mp inLink
        have notHead : x ≠ head := by
          intro same
          subst same
          simp at filtered
        have notTail : x ≠ tail := by
          intro same
          subst same
          simp at filtered
        obtain ⟨tk, t', declared, at_p⟩ := ihLink _ b linkTyped x p filtered.1
        rw [lookup_cons_other _ _ _ notHead, lookup_cons_other _ _ _ notTail] at declared
        exact ⟨tk, t', declared, at_p⟩
  | @atRead receiver index fallback =>
    intro tenv ty typed x p use
    obtain ⟨types, atomsTyped, _⟩ := exprType_prim_success typed
    exact atoms_use_typed atomsTyped use
  | @set receiver index item =>
    intro tenv ty typed x p use
    obtain ⟨types, atomsTyped, _⟩ := exprType_prim_success typed
    exact atoms_use_typed atomsTyped use
  | @copy receiver =>
    intro tenv ty typed x p use
    obtain ⟨types, atomsTyped, _⟩ := exprType_prim_success typed
    exact atoms_use_typed atomsTyped use
  | @prepend item receiver =>
    intro tenv ty typed x p use
    obtain ⟨types, atomsTyped, _⟩ := exprType_prim_success typed
    exact atoms_use_typed atomsTyped use

end Ownership.FlatFragment.Fields
