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

/-- The shape of a typed flat value: the generalization of `allocated_shape_of_typed`.
The typing of a result leaves its dead slot open; the tags fix it to the
integer `0`, as both interpreters build it. -/
theorem allocated_of_typed {ds : List Decl} {heap : Heap} {w : Value} {ty : Ty} {a : Abstract}
    (flat : FlatType ty) (typed : ValueTyped ds heap w ty) (tags : ResultTags ty a w) :
    AllocatedFlatValue heap w ty := by
  induction flat generalizing w a with
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
      cases tags with
      | record _ as _ lenA tagFields =>
        refine .record ws ts len (fun i w t ws_i ts_i => ?_)
        obtain ⟨a', as_i⟩ := index_of_same_length lenA ts_i
        exact ih t (List.mem_of_getElem? ts_i) (fields i w t ws_i ts_i) (tagFields i t a' w ts_i as_i ws_i)
  | result e s _ _ ihE ihS =>
    cases tags with
    | ok _ _ _ _ aa w' _ tagsS =>
      obtain ⟨depth, observation, footprint, represented, observedType⟩ := typed
      cases represented with
      | @record _ _ os cs children =>
        have lenO : os.length = 3 := (representsMany_length children).symm
        match os, lenO, observedType, children with
        | [o0, o1, o2], _, observedType, children =>
          obtain ⟨c0, r0⟩ := representsMany_index _ children (rfl : [Value.int 1, .int 0, w'][0]? = some (.int 1))
            (rfl : [o0, o1, o2][0]? = some o0)
          obtain ⟨c2, r2⟩ := representsMany_index _ children (rfl : [Value.int 1, .int 0, w'][2]? = some w')
            (rfl : [o0, o1, o2][2]? = some o2)
          cases r0
          have typedS : obsTyped ds o2 s = true := by simpa [obsTyped] using observedType
          exact .ok e s w' (ihS ⟨_, o2, c2, r2, typedS⟩ tagsS)
    | err _ _ _ ae _ w' _ tagsE =>
      obtain ⟨depth, observation, footprint, represented, observedType⟩ := typed
      cases represented with
      | @record _ _ os cs children =>
        have lenO : os.length = 3 := (representsMany_length children).symm
        match os, lenO, observedType, children with
        | [o0, o1, o2], _, observedType, children =>
          obtain ⟨c0, r0⟩ := representsMany_index _ children (rfl : [Value.int 0, w', .int 0][0]? = some (.int 0))
            (rfl : [o0, o1, o2][0]? = some o0)
          obtain ⟨c1, r1⟩ := representsMany_index _ children (rfl : [Value.int 0, w', .int 0][1]? = some w')
            (rfl : [o0, o1, o2][1]? = some o1)
          cases r0
          have typedE : obsTyped ds o1 e = true := by simpa [obsTyped] using observedType
          exact .err e s w' (ihE ⟨_, o1, c1, r1, typedE⟩ tagsE)

theorem allocated_mono {heap next : Heap} {w : Value} {ty : Ty}
    (shape : AllocatedFlatValue heap w ty) (size : heap.size ≤ next.size) : AllocatedFlatValue next w ty := by
  induction shape with
  | int integer => exact .int integer
  | list root allocated => exact .list root (Nat.lt_of_lt_of_le allocated size)
  | record ws ts len _ ih => exact .record ws ts len (fun i w t ws_i ts_i => ih i w t ws_i ts_i)
  | ok e s w _ ih => exact .ok e s w ih
  | err e s w _ ih => exact .err e s w ih

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
      obtain ⟨as, rfl, len, fields⟩ := flatAbstract_record shape
      obtain ⟨a', as_i, shape'⟩ := flatAbstract_record_field len fields h
      cases w <;> simp [projectVal] at projected
      rename_i ws
      cases h' : ws[i']? with
      | none => simp [h'] at projected
      | some w1 =>
        simp [h'] at projected
        simp only [Abstract.atPath, as_i, Option.getD_some]
        cases tags with
        | record _ _ _ _ tagFields => exact ih (tagFields i' t' a' w1 h as_i h') shape' at_p projected

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

/-! ### The three slots of a result -/

theorem getElem?_three {α : Type} {a b c x : α} {i : Nat} (at_i : [a, b, c][i]? = some x) :
    (i = 0 ∧ x = a) ∨ (i = 1 ∧ x = b) ∨ (i = 2 ∧ x = c) := by
  rcases i with _ | _ | _ | i <;> simp at at_i <;> simp [at_i]

theorem three_pair {α β : Type} {a0 a1 a2 : α} {b0 b1 b2 : β} {i : Nat} {x : α} {y : β}
    (as_i : [a0, a1, a2][i]? = some x) (bs_i : [b0, b1, b2][i]? = some y) :
    (x = a0 ∧ y = b0) ∨ (x = a1 ∧ y = b1) ∨ (x = a2 ∧ y = b2) := by
  rcases i with _ | _ | _ | i <;> simp at as_i bs_i <;> simp [as_i, bs_i]

theorem named_nil {gamma : Naming} {c : Nat} (names : named gamma [] c) : False := by
  obtain ⟨_, member, _⟩ := names
  simp at member

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

theorem flatAbstract_ne_bottom {t : Ty} {a : Abstract} (shape : FlatAbstract t a) : a ≠ .bottom := by
  cases shape <;> simp

/-- The checker's equality test against bottom: `Abstract`'s `BEq` is not lawful, so this is a lemma. -/
theorem eq_bottom_of_beq {a : Abstract} (h : (a == .bottom) = true) : a = .bottom := by
  cases a <;> simp [BEq.beq, Abstract.equal] at h ⊢

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
  | ok e s w' _ ih =>
    cases located with
    | @field _ i w'' q' _ ws_i inner =>
      rcases getElem?_three ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
      · cases inner
      · cases inner
      · obtain ⟨bound, immutable, everywhere⟩ := ih inner
        refine ⟨bound, ?_, fun heap' => .field ws_i (everywhere heap')⟩
        simp [immutablePath] at immutable ⊢
        exact immutable
  | err e s w' _ ih =>
    cases located with
    | @field _ i w'' q' _ ws_i inner =>
      rcases getElem?_three ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
      · cases inner
      · obtain ⟨bound, immutable, everywhere⟩ := ih inner
        refine ⟨bound, ?_, fun heap' => .field ws_i (everywhere heap')⟩
        simp [immutablePath] at immutable ⊢
        exact immutable
      · cases inner

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
  | ok e s w' _ ih =>
    cases reachable with
    | field member inner =>
      simp at member
      rcases member with rfl | rfl | rfl
      · cases inner
      · cases inner
      · obtain ⟨q, located⟩ := ih inner
        exact ⟨.field 2 :: q, .field rfl located⟩
  | err e s w' _ ih =>
    cases reachable with
    | field member inner =>
      simp at member
      rcases member with rfl | rfl | rfl
      · cases inner
      · obtain ⟨q, located⟩ := ih inner
        exact ⟨.field 1 :: q, .field rfl located⟩
      · cases inner

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
  | ok e s w' _ ih =>
    obtain ⟨os, rfl, lenO, fieldsC⟩ := corresponds_record_fields paired
    refine corresponds_record_of_fields lenO ?_
    intro i o' w'' os_i ws_i
    rcases getElem?_three ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
    · exact corresponds_int_frame (fieldsC 0 o' _ os_i rfl)
    · exact corresponds_int_frame (fieldsC 1 o' _ os_i rfl)
    · exact ih (fun q c located => same (.field 2 :: q) c (.field rfl located))
        (fieldsC 2 o' _ os_i rfl)
  | err e s w' _ ih =>
    obtain ⟨os, rfl, lenO, fieldsC⟩ := corresponds_record_fields paired
    refine corresponds_record_of_fields lenO ?_
    intro i o' w'' os_i ws_i
    rcases getElem?_three ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
    · exact corresponds_int_frame (fieldsC 0 o' _ os_i rfl)
    · exact ih (fun q c located => same (.field 1 :: q) c (.field rfl located))
        (fieldsC 1 o' _ os_i rfl)
    · exact corresponds_int_frame (fieldsC 2 o' _ os_i rfl)

theorem describes_flat_frame {heap next : Heap} {gamma gamma' : Naming} {w : Value} {ty : Ty}
    {a : Abstract}
    (shape : AllocatedFlatValue heap w ty) (abs : FlatAbstract ty a) (tags : ResultTags ty a w)
    (_flat : FlatHeap heap)
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
    cases tags with
    | record _ _ _ _ tagFields =>
      refine describes_record_of_fields (lenTA.symm.trans len.symm) ?_
      intro i a' w' as_i ws_i
      obtain ⟨t, ts_i⟩ := index_of_same_length len ws_i
      exact ih i w' t ws_i ts_i (fieldsA i t a' ts_i as_i) (tagFields i t a' w' ts_i as_i ws_i)
        (describes_field described as_i ws_i)
  | ok e s w' _ ih =>
    cases tags with
    | ok _ _ _ ae aa _ neB tagsS =>
      cases abs with
      | result _ _ _ _ hE hS _ =>
        refine describes_record_of_fields rfl ?_
        intro i a' w'' as_i ws_i
        rcases three_pair as_i ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
        · exact integer_described 1
        · exact integer_described_any _ 0
        · exact ih (hS neB) tagsS (describes_field (i := 2) described rfl rfl)
  | err e s w' _ ih =>
    cases tags with
    | err _ _ _ ae aa _ neB tagsE =>
      cases abs with
      | result _ _ _ _ hE hS _ =>
        refine describes_record_of_fields rfl ?_
        intro i a' w'' as_i ws_i
        rcases three_pair as_i ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
        · exact integer_described 0
        · exact ih (hE neB) tagsE (describes_field (i := 1) described rfl rfl)
        · exact integer_described_any _ 0

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
  | ok e s w' _ ih =>
    cases located with
    | @field _ i w'' q' _ ws_i inner =>
      cases abs with
      | result _ _ ae aa hE hS _ =>
        rcases getElem?_three ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
        · cases inner
        · cases inner
        · have coversS : Covers gamma heap aa _ := covers_field (i := 2) covers rfl rfl
          by_cases bottom : aa = .bottom
          · exfalso
            subst bottom
            have names := coversS q' c inner
            cases q' <;> simp [namesAt, Abstract.cellsAt, Abstract.paths, named] at names
          · obtain ⟨origin, member, address⟩ := ih (hS bottom) coversS inner
            obtain ⟨cs, path, inCs⟩ := mem_cellsAt aa q' origin member
            exact ⟨origin, mem_cellsAt_of_path (record_path_mem [.scalar, ae, aa] 2 aa q' cs rfl path) inCs,
              address⟩
  | err e s w' _ ih =>
    cases located with
    | @field _ i w'' q' _ ws_i inner =>
      cases abs with
      | result _ _ ae aa hE hS _ =>
        rcases getElem?_three ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
        · cases inner
        · have coversE : Covers gamma heap ae _ := covers_field (i := 1) covers rfl rfl
          by_cases bottom : ae = .bottom
          · exfalso
            subst bottom
            have names := coversE q' c inner
            cases q' <;> simp [namesAt, Abstract.cellsAt, Abstract.paths, named] at names
          · obtain ⟨origin, member, address⟩ := ih (hE bottom) coversE inner
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
  | result e s ae aa _ _ hLive ihE ihS =>
    rw [mapOrigins_three, mapOrigins_scalar]
    refine .result e s _ _ ?_ ?_ ?_
    · intro ne
      have neE : ae ≠ .bottom := fun bottom => ne (by rw [bottom, mapOrigins_bottom])
      exact ihE neE _
    · intro ne
      have neS : aa ≠ .bottom := fun bottom => ne (by rw [bottom, mapOrigins_bottom])
      exact ihS neS _
    · rcases hLive with ne | ne
      · exact Or.inl (mapOrigins_ne_bottom f _ ne)
      · exact Or.inr (mapOrigins_ne_bottom f _ ne)

/-- The tags survive an origin substitution: it keeps every constructor. -/
theorem resultTags_mapOrigins (f : Path → List Origin → List Origin) {t : Ty} {a : Abstract} {w : Value}
    (tags : ResultTags t a w) (path : Path) : ResultTags t (a.mapOrigins f path) w := by
  induction tags generalizing path with
  | int a w => exact .int _ _
  | listInt a w => exact .listInt _ _
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
    (shape : AllocatedFlatValue heap w ty) (abs : FlatAbstract ty a) (tags : ResultTags ty a w)
    (flat : FlatHeap heap)
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
    cases tags with
    | record _ _ _ _ tagFields =>
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
        exact ih i w' t ws_i ts_i (fieldsA i t a0 ts_i h) (tagFields i t a0 w' ts_i h ws_i)
          (describes_field described h ws_i) _
  | ok e s w' _ ih =>
    cases tags with
    | ok _ _ _ ae aa _ neB tagsS =>
      cases abs with
      | result _ _ _ _ hE hS _ =>
        rw [mapOrigins_three, mapOrigins_scalar]
        refine describes_record_of_fields rfl ?_
        intro i a' w'' as_i ws_i
        rcases three_pair as_i ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
        · exact integer_described 1
        · exact integer_described_any _ 0
        · exact ih (hS neB) tagsS (describes_field (i := 2) described rfl rfl) _
  | err e s w' _ ih =>
    cases tags with
    | err _ _ _ ae aa _ neB tagsE =>
      cases abs with
      | result _ _ _ _ hE hS _ =>
        rw [mapOrigins_three, mapOrigins_scalar]
        refine describes_record_of_fields rfl ?_
        intro i a' w'' as_i ws_i
        rcases three_pair as_i ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
        · exact integer_described 0
        · exact ih (hE neB) tagsE (describes_field (i := 1) described rfl rfl) _
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

/-! allocation and write preservation for every flat binding (continued from
`Runtime`): the shape of a typed binding and the typing of every binding after
a flat heap change, now with records. -/

namespace Ownership.FlatFragment.HeapPreservation

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.Runtime
open Ownership.FlatFragment.Fields

/-- Finite typed expansions establish the exact runtime shape and exclude
dangling roots even when the binding has no future live use. -/
theorem allocated_shape_of_typed {heap : Heap} {a : Abstract} (flatType : FlatType type)
    (typed : ValueTyped declarations heap actual type) (tags : ResultTags type a actual) :
    AllocatedFlatValue heap actual type :=
  allocated_of_typed flatType typed tags

/-- Any flat heap with enough allocated addresses preserves all flat
binding types. This includes aliases of the address whose contents changed.
The statement retains no correspondence claim for a dead observation. -/
theorem valueTyped_after_flat_heap {heap : Heap} {nextHeap : Heap} {a : Abstract}
    (flatType : FlatType type) (typed : ValueTyped declarations heap actual type)
    (tags : ResultTags type a actual)
    (nextFlat : FlatHeap nextHeap) (size : heap.size ≤ nextHeap.size) :
    ValueTyped declarations nextHeap actual type :=
  valueTyped_of_allocated (allocated_mono (allocated_shape_of_typed flatType typed tags) size) nextFlat

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
  obtain ⟨a, abstractBinding⟩ :=
    Ownership.FlatFragment.VariableFacts.lookup_exists_of_same_keys aenv env inv.abstractKeys.symm present
  exact ⟨type, declared, observedType,
    valueTyped_after_flat_heap (inv.types x type declared) actualType
      (inv.tags x type a observation actual declared abstractBinding present) nextFlat size⟩

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
      FlatType ty ∧ FlatAbstract ty a ∧ AllocatedFlatValue hs.heap w ty ∧ ResultTags ty a w := by
  cases root : atomRoot atom with
  | none =>
    obtain ⟨n, rfl, rfl⟩ := atom_int_of_root_none typed root
    exact ⟨.int n, .int n, .scalar, rfl, rfl, rfl, integer_corresponds n, integer_described n,
      by simp [obsTyped], ⟨1, .int n, [], .int, by simp [obsTyped]⟩, .int, .int, .int n, .int _ _⟩
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
    have tags0 := inv.tags k tk' a0 o0 w0 declared abstractBinding binding
    have allocated0 := allocated_of_typed flatTk typed0 tags0
    have allocated := allocated_project allocated0 at_p valuePath
    exact ⟨o, w, a0.atPath p, value_atom_of_root root (valueEnv_lookup binding) obsPath,
      heap_atom_of_root root (heapEnv_lookup binding) valuePath,
      abstractAtom_of_root root abstractBinding shape0 at_p, paired, described,
      projectObs_typed observed0 at_p obsPath, valueTyped_of_allocated allocated inv.heapInts,
      flatType_tyAt flatTk at_p, flatAbstract_atPath shape0 at_p, allocated,
      resultTags_project tags0 shape0 at_p valuePath⟩

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
  obtain ⟨o, w, a, valueRun, heapRun, abstractRun, paired, _, _, _, _, shape, allocated, _⟩ :=
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
  obtain ⟨o, w, a, valueRun, heapRun, abstractRun, paired, described, _, _, _, shape, allocated, _⟩ :=
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
    (afterSub : ∀ use ∈ after, use ∈ live)
    (receiverNamed : named gamma roots root)
    (separate : ∀ r, named gamma roots r → ¬ named gamma (union (liveCells aenv after) pinned) r) :
    ∀ x p, (x, p) ∈ after → ∀ o w w', env.lookup x = some (o, w) → projectVal w p = some w' →
      ∀ q c, ArrayAt hs.heap w' q c → c ≠ root := by
  intro x p use o w w' binding projected q c located same
  subst same
  obtain ⟨a, abstractBinding⟩ := liveScope_lookup_exists scope use
  obtain ⟨ty, declared, _, actualTyped⟩ := inv.bindingsTyped x o w binding
  have allocated := allocated_of_typed (inv.types x ty declared) actualTyped
    (inv.tags x ty a o w declared abstractBinding binding)
  obtain ⟨t, at_p⟩ := inv.liveTyped x p ty (afterSub _ use) declared
  have allocated' := allocated_project allocated at_p projected
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
  obtain ⟨a, abstractBinding⟩ := lookup_exists_of_same_keys aenv env inv.abstractKeys.symm binding
  have allocated := allocated_of_typed (inv.types x ty declared) actualTyped
    (inv.tags x ty a o w declared abstractBinding binding)
  exact (arrayAt_flat allocated inv.heapInts (arrayAt_of_project projected located)).1

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

theorem int_equal_ty (equal : (Ty.int == ty) = true) : ty = .int := by
  cases ty <;> simp [BEq.beq, Ty.equal] at equal ⊢

/-! ### Type equality on flat types -/

theorem ty_equal_flat {t b : Ty} (flat : FlatType t) (equal : Ty.equal t b = true) : t = b := by
  induction flat generalizing b with
  | int => cases b <;> simp [Ty.equal] at equal ⊢
  | listInt =>
    cases b with
    | list e => cases e <;> simp [Ty.equal] at equal ⊢
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
theorem ty_equal_flat_right {t b : Ty} (flat : FlatType b) (equal : Ty.equal t b = true) : t = b := by
  induction flat generalizing t with
  | int => cases t <;> simp [Ty.equal] at equal ⊢
  | listInt =>
    cases t with
    | list e => cases e <;> simp [Ty.equal] at equal ⊢
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

theorem flatAbstract_join {t : Ty} {a b : Abstract} (shapeA : FlatAbstract t a) (shapeB : FlatAbstract t b) :
    FlatAbstract t (a.join b) := by
  induction shapeA generalizing b with
  | int => cases shapeB; rw [join_scalar]; exact .int
  | listBottom roots certificate =>
    cases shapeB with
    | listBottom roots' certificate' => rw [join_list, join_bottom_bottom]; exact .listBottom _ _
    | listScalar roots' certificate' => rw [join_list, join_bottom_scalar]; exact .listScalar _ _
  | listScalar roots certificate =>
    cases shapeB with
    | listBottom roots' certificate' => rw [join_list, join_scalar_bottom]; exact .listScalar _ _
    | listScalar roots' certificate' => rw [join_list, join_scalar]; exact .listScalar _ _
  | record ts as len _ ih =>
    cases shapeB with
    | record _ bs len' fieldsB =>
      rw [join_record]
      refine .record ts _ (by rw [record_join_length as bs (len.symm.trans len')]; exact len) ?_
      intro i t j ts_i at_i
      obtain ⟨x, y, as_i, bs_i, rfl⟩ := record_join_index_inv at_i
      exact ih i t x ts_i as_i (fieldsB i t y ts_i bs_i)
  | result e s ae aa hE hS hLive ihE ihS =>
    cases shapeB with
    | result _ _ be ba hE' hS' hLive' =>
      rw [join_three, join_scalar]
      refine .result e s _ _ ?_ ?_ ?_
      · intro ne
        by_cases bottom : ae = .bottom
        · subst bottom
          rw [join_bottom_left] at ne ⊢
          exact hE' ne
        · by_cases bottom' : be = .bottom
          · subst bottom'
            rw [join_bottom_right]
            exact hE bottom
          · exact ihE bottom (hE' bottom')
      · intro ne
        by_cases bottom : aa = .bottom
        · subst bottom
          rw [join_bottom_left] at ne ⊢
          exact hS' ne
        · by_cases bottom' : ba = .bottom
          · subst bottom'
            rw [join_bottom_right]
            exact hS bottom
          · exact ihS bottom (hS' bottom')
      · rcases hLive with ne | ne
        · left
          by_cases bottom' : be = .bottom
          · subst bottom'; rw [join_bottom_right]; exact ne
          · exact flatAbstract_ne_bottom (ihE ne (hE' bottom'))
        · right
          by_cases bottom' : ba = .bottom
          · subst bottom'; rw [join_bottom_right]; exact ne
          · exact flatAbstract_ne_bottom (ihS ne (hS' bottom'))

/-- A joined slot is bottom only when both slots are. -/
theorem flatAbstract_join_ne_bottom {t : Ty} {a b : Abstract} (ne : a ≠ .bottom)
    (shapeA : a ≠ .bottom → FlatAbstract t a) (shapeB : b ≠ .bottom → FlatAbstract t b) :
    a.join b ≠ .bottom := by
  by_cases bottom : b = .bottom
  · subst bottom
    rw [join_bottom_right]
    exact ne
  · exact flatAbstract_ne_bottom (flatAbstract_join (shapeA ne) (shapeB bottom))

/-- The tags of a value survive a join with another flat abstract of its type. -/
theorem resultTags_join {t : Ty} {a b : Abstract} {w : Value}
    (tags : ResultTags t a w) (shapeA : FlatAbstract t a) (shapeB : FlatAbstract t b) :
    ResultTags t (a.join b) w := by
  induction tags generalizing b with
  | int a w => exact .int _ _
  | listInt a w => exact .listInt _ _
  | record ts as ws len _ ih =>
    cases shapeA with
    | record _ _ lenA fieldsA =>
      cases shapeB with
      | record _ bs lenB fieldsB =>
        rw [join_record]
        refine .record ts _ ws (by rw [record_join_length as bs (lenA.symm.trans lenB)]; exact len) ?_
        intro i t a' w' ts_i at_i ws_i
        obtain ⟨x, y, as_i, bs_i, rfl⟩ := record_join_index_inv at_i
        exact ih i t x w' ts_i as_i ws_i (fieldsA i t x ts_i as_i) (fieldsB i t y ts_i bs_i)
  | ok e s tag ae aa w' ne tagsS ih =>
    cases shapeA with
    | result _ _ _ _ hE hS _ =>
      cases shapeB with
      | result _ _ be ba hE' hS' hLive' =>
        rw [join_three]
        refine .ok e s _ _ _ w' (flatAbstract_join_ne_bottom ne hS hS') ?_
        by_cases bottom : ba = .bottom
        · subst bottom
          rw [join_bottom_right]
          exact tagsS
        · exact ih (hS ne) (hS' bottom)
  | err e s tag ae aa w' ne tagsE ih =>
    cases shapeA with
    | result _ _ _ _ hE hS _ =>
      cases shapeB with
      | result _ _ be ba hE' hS' hLive' =>
        rw [join_three]
        refine .err e s _ _ _ w' (flatAbstract_join_ne_bottom ne hE hE') ?_
        by_cases bottom : be = .bottom
        · subst bottom
          rw [join_bottom_right]
          exact tagsE
        · exact ih (hE ne) (hE' bottom)

/-- The tags of a value survive a join on the other side. -/
theorem resultTags_join_right {t : Ty} {a b : Abstract} {w : Value}
    (tags : ResultTags t b w) (shapeA : FlatAbstract t a) (shapeB : FlatAbstract t b) :
    ResultTags t (a.join b) w := by
  induction tags generalizing a with
  | int a w => exact .int _ _
  | listInt a w => exact .listInt _ _
  | record ts bs ws len _ ih =>
    cases shapeA with
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
    | result _ _ ae aa hE hS _ =>
      cases shapeB with
      | result _ _ _ _ hE' hS' _ =>
        rw [join_three]
        refine .ok e s _ _ _ w' ?_ ?_
        · by_cases bottom : aa = .bottom
          · subst bottom
            rw [join_bottom_left]
            exact ne
          · exact flatAbstract_ne_bottom (flatAbstract_join (hS bottom) (hS' ne))
        · by_cases bottom : aa = .bottom
          · subst bottom
            rw [join_bottom_left]
            exact tagsS
          · exact ih (hS bottom) (hS' ne)
  | err e s tag be ba w' ne tagsE ih =>
    cases shapeA with
    | result _ _ ae aa hE hS _ =>
      cases shapeB with
      | result _ _ _ _ hE' hS' _ =>
        rw [join_three]
        refine .err e s _ _ _ w' ?_ ?_
        · by_cases bottom : ae = .bottom
          · subst bottom
            rw [join_bottom_left]
            exact ne
          · exact flatAbstract_ne_bottom (flatAbstract_join (hE bottom) (hE' ne))
        · by_cases bottom : ae = .bottom
          · subst bottom
            rw [join_bottom_left]
            exact tagsE
          · exact ih (hE bottom) (hE' ne)

/-! ### A join describes what either side describes -/

theorem describes_join {gamma : Naming} {heap : Heap} {t : Ty} {w : Value} {a b : Abstract}
    (allocated : AllocatedFlatValue heap w t) (flatHeap : FlatHeap heap)
    (shapeA : FlatAbstract t a) (shapeB : FlatAbstract t b)
    (side : (Describes gamma heap a w ∧ ResultTags t a w) ∨
      (Describes gamma heap b w ∧ ResultTags t b w)) :
    Describes gamma heap (a.join b) w := by
  induction allocated generalizing a b with
  | int n =>
    cases shapeA; cases shapeB
    rw [join_scalar]
    exact integer_described n
  | list root lt =>
    have lookupRoot : heap[root]? = some heap[root] := by simp [lt]
    obtain ⟨integers, payload⟩ := integers_of_flat_values heap[root] (flatHeap root _ lookupRoot)
    rw [payload] at lookupRoot
    have names : ∀ cs ds, (∃ e ex, a = .list cs e ex) → (∃ e ex, b = .list ds e ex) →
        named gamma (union cs ds) root := by
      intro cs ds ⟨e, ex, ha⟩ ⟨e', ex', hb⟩
      rcases side with ⟨described, _⟩ | ⟨described, _⟩
      · subst ha
        have found := described.1.1 [] root (.here _)
        rw [list_root_names] at found
        obtain ⟨origin, member, address⟩ := named_union_nil found
        exact ⟨origin, mem_union _ _ origin (Or.inl member), address⟩
      · subst hb
        have found := described.1.1 [] root (.here _)
        rw [list_root_names] at found
        obtain ⟨origin, member, address⟩ := named_union_nil found
        exact ⟨origin, mem_union _ _ origin (Or.inr member), address⟩
    cases shapeA with
    | listBottom cs ex =>
      cases shapeB with
      | listBottom ds ex' => rw [join_list]; exact allocated_list_described lookupRoot (names cs ds ⟨_, _, rfl⟩ ⟨_, _, rfl⟩)
      | listScalar ds ex' => rw [join_list]; exact allocated_list_described lookupRoot (names cs ds ⟨_, _, rfl⟩ ⟨_, _, rfl⟩)
    | listScalar cs ex =>
      cases shapeB with
      | listBottom ds ex' => rw [join_list]; exact allocated_list_described lookupRoot (names cs ds ⟨_, _, rfl⟩ ⟨_, _, rfl⟩)
      | listScalar ds ex' => rw [join_list]; exact allocated_list_described lookupRoot (names cs ds ⟨_, _, rfl⟩ ⟨_, _, rfl⟩)
  | record ws ts len _ ih =>
    cases shapeA with
    | record _ as lenA fieldsA =>
      cases shapeB with
      | record _ bs lenB fieldsB =>
        rw [join_record]
        refine describes_record_of_fields (by rw [record_join_length as bs (lenA.symm.trans lenB)]; omega) ?_
        intro i j w' at_i ws_i
        obtain ⟨x, y, as_i, bs_i, rfl⟩ := record_join_index_inv at_i
        obtain ⟨t', ts_i⟩ := index_of_same_length len ws_i
        refine ih i w' t' ws_i ts_i (fieldsA i t' x ts_i as_i) (fieldsB i t' y ts_i bs_i) ?_
        rcases side with ⟨described, tags⟩ | ⟨described, tags⟩
        · cases tags with
          | record _ _ _ _ tagFields =>
            exact Or.inl ⟨describes_field described as_i ws_i, tagFields i t' x w' ts_i as_i ws_i⟩
        · cases tags with
          | record _ _ _ _ tagFields =>
            exact Or.inr ⟨describes_field described bs_i ws_i, tagFields i t' y w' ts_i bs_i ws_i⟩
  | ok e s w' _ ih =>
    cases shapeA with
    | result _ _ ae aa hE hS _ =>
      cases shapeB with
      | result _ _ be ba hE' hS' hLive' =>
        rw [join_three, join_scalar]
        refine describes_record_of_fields rfl ?_
        intro i j w'' at_i ws_i
        rcases three_pair at_i ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
        · exact integer_described 1
        · exact integer_described_any _ 0
        · rcases side with ⟨described, tags⟩ | ⟨described, tags⟩
          · obtain ⟨neB, tagsS⟩ : aa ≠ .bottom ∧ ResultTags s aa w'' := by
              cases tags with
              | ok _ _ _ _ _ _ neB tagsS => exact ⟨neB, tagsS⟩
            by_cases bottom : ba = .bottom
            · subst bottom
              rw [join_bottom_right]
              exact describes_field (i := 2) described rfl rfl
            · exact ih (hS neB) (hS' bottom) (Or.inl ⟨describes_field (i := 2) described rfl rfl, tagsS⟩)
          · obtain ⟨neB, tagsS⟩ : ba ≠ .bottom ∧ ResultTags s ba w'' := by
              cases tags with
              | ok _ _ _ _ _ _ neB tagsS => exact ⟨neB, tagsS⟩
            by_cases bottom : aa = .bottom
            · subst bottom
              rw [join_bottom_left]
              exact describes_field (i := 2) described rfl rfl
            · exact ih (hS bottom) (hS' neB) (Or.inr ⟨describes_field (i := 2) described rfl rfl, tagsS⟩)
  | err e s w' _ ih =>
    cases shapeA with
    | result _ _ ae aa hE hS _ =>
      cases shapeB with
      | result _ _ be ba hE' hS' hLive' =>
        rw [join_three, join_scalar]
        refine describes_record_of_fields rfl ?_
        intro i j w'' at_i ws_i
        rcases three_pair at_i ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
        · exact integer_described 0
        · rcases side with ⟨described, tags⟩ | ⟨described, tags⟩
          · obtain ⟨neB, tagsE⟩ : ae ≠ .bottom ∧ ResultTags e ae w'' := by
              cases tags with
              | err _ _ _ _ _ _ neB tagsE => exact ⟨neB, tagsE⟩
            by_cases bottom : be = .bottom
            · subst bottom
              rw [join_bottom_right]
              exact describes_field (i := 1) described rfl rfl
            · exact ih (hE neB) (hE' bottom) (Or.inl ⟨describes_field (i := 1) described rfl rfl, tagsE⟩)
          · obtain ⟨neB, tagsE⟩ : be ≠ .bottom ∧ ResultTags e be w'' := by
              cases tags with
              | err _ _ _ _ _ _ neB tagsE => exact ⟨neB, tagsE⟩
            by_cases bottom : ae = .bottom
            · subst bottom
              rw [join_bottom_left]
              exact describes_field (i := 1) described rfl rfl
            · exact ih (hE bottom) (hE' neB) (Or.inr ⟨describes_field (i := 1) described rfl rfl, tagsE⟩)
        · exact integer_described_any _ 0

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

end Ownership.FlatFragment.Fields
